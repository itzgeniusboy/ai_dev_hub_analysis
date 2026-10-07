package com.example.ai_dev_hub

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Bridge between the Dart agent and
 *  - Termux (RUN_COMMAND intent sent from THIS app; the shell user cannot send it), and
 *  - Shizuku (commands as the adb "shell" user).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "ai_dev_hub/terminal"
    private val termuxPkg = "com.termux"
    private val termuxPerm = "com.termux.permission.RUN_COMMAND"
    private val shizukuPkg = "moe.shizuku.privileged.api"
    private val io = Executors.newCachedThreadPool()
    private val ui = Handler(Looper.getMainLooper())
    private val ids = AtomicInteger(1000)
    private val outCap = 200_000

    private var termuxPermResult: MethodChannel.Result? = null
    private var shizukuPermResult: MethodChannel.Result? = null

    private val shizukuListener = Shizuku.OnRequestPermissionResultListener { _, grant ->
        val r = shizukuPermResult
        shizukuPermResult = null
        r?.success(grant == PackageManager.PERMISSION_GRANTED)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try { Shizuku.addRequestPermissionResultListener(shizukuListener) } catch (_: Throwable) {}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status())
                "shizukuRequest" -> shizukuRequest(result)
                "termuxRequestPermission" -> {
                    if (checkSelfPermission(termuxPerm) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        termuxPermResult = result
                        ActivityCompat.requestPermissions(this, arrayOf(termuxPerm), 7001)
                    }
                }
                "grantTermuxViaShizuku" -> io.execute {
                    val r = runShizuku("pm grant $packageName $termuxPerm", 15_000)
                    ui.post { result.success(r) }
                }
                "shizukuShell" -> {
                    val cmd = call.argument<String>("command") ?: ""
                    val t = (call.argument<Number>("timeoutMs") ?: 60_000).toLong()
                    io.execute { val r = runShizuku(cmd, t); ui.post { result.success(r) } }
                }
                "termuxRun" -> {
                    val cmd = call.argument<String>("command") ?: ""
                    val dir = call.argument<String>("workdir")
                    val t = (call.argument<Number>("timeoutMs") ?: 60_000).toLong()
                    termuxRun(cmd, dir, t, result)
                }
                "openTermux" -> {
                    val i = packageManager.getLaunchIntentForPackage(termuxPkg)
                    if (i == null) result.success(false) else { startActivity(i); result.success(true) }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { Shizuku.removeRequestPermissionResultListener(shizukuListener) } catch (_: Throwable) {}
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7001) {
            val r = termuxPermResult
            termuxPermResult = null
            r?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        }
    }

    // ---- status ---------------------------------------------------------------

    private fun installed(pkg: String) = try { packageManager.getPackageInfo(pkg, 0); true } catch (_: Exception) { false }

    private fun status(): Map<String, Any?> {
        val running = try { Shizuku.pingBinder() } catch (_: Throwable) { false }
        val granted = running && try { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED } catch (_: Throwable) { false }
        return mapOf(
            "shizukuInstalled" to installed(shizukuPkg),
            "shizukuRunning" to running,
            "shizukuGranted" to granted,
            "termuxInstalled" to installed(termuxPkg),
            "termuxPermission" to (checkSelfPermission(termuxPerm) == PackageManager.PERMISSION_GRANTED),
        )
    }

    // ---- Shizuku --------------------------------------------------------------

    private fun shizukuRequest(result: MethodChannel.Result) {
        try {
            if (!Shizuku.pingBinder()) { result.success(false); return }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) { result.success(true); return }
            if (Shizuku.shouldShowRequestPermissionRationale()) { result.success(false); return } // denied permanently
            shizukuPermResult = result
            Shizuku.requestPermission(4242)
        } catch (_: Throwable) { result.success(false) }
    }

    /** Shizuku.newProcess is private in API 13.x; call it reflectively. */
    private fun shizukuProcess(cmd: Array<String>): Process {
        val m = Shizuku::class.java.getDeclaredMethod(
            "newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java)
        m.isAccessible = true
        return m.invoke(null, *arrayOf<Any?>(cmd, null, null)) as Process
    }

    private fun runShizuku(command: String, timeoutMs: Long): Map<String, Any?> {
        try {
            if (!Shizuku.pingBinder()) return err("Shizuku is not running. Start it from the Shizuku app.")
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) return err("Shizuku permission not granted to this app.")
            val proc = shizukuProcess(arrayOf("sh", "-c", command))
            val out = StringBuilder(); val er = StringBuilder()
            val t1 = thread { drain(proc.inputStream, out) }
            val t2 = thread { drain(proc.errorStream, er) }
            val fut = io.submit<Int> { proc.waitFor() }
            var code: Int? = null; var timedOut = false
            try { code = fut.get(timeoutMs, TimeUnit.MILLISECONDS) }
            catch (_: TimeoutException) { timedOut = true; try { proc.destroy() } catch (_: Throwable) {} }
            t1.join(2000); t2.join(2000)
            return mapOf("stdout" to out.toString(), "stderr" to er.toString(), "exitCode" to code, "timedOut" to timedOut)
        } catch (e: Throwable) {
            return err("Shizuku command failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun drain(s: java.io.InputStream, sb: StringBuilder) {
        val buf = ByteArray(4096)
        try {
            while (true) {
                val n = s.read(buf); if (n < 0) break
                if (sb.length < outCap) sb.append(String(buf, 0, n, Charsets.UTF_8))
            }
        } catch (_: Exception) {}
    }

    private fun err(msg: String): Map<String, Any?> =
        mapOf("stdout" to "", "stderr" to "", "exitCode" to null, "timedOut" to false, "error" to msg)

    // ---- Termux ---------------------------------------------------------------

    private fun termuxRun(command: String, workdir: String?, timeoutMs: Long, result: MethodChannel.Result) {
        if (!installed(termuxPkg)) { result.success(err("Termux is not installed (use the F-Droid or GitHub build).")); return }
        if (checkSelfPermission(termuxPerm) != PackageManager.PERMISSION_GRANTED) {
            result.success(err("Permission \"Run commands in Termux environment\" is not granted to AI Dev Hub.")); return
        }
        val id = ids.incrementAndGet()
        val action = "$packageName.TERMUX_RESULT.$id"
        var done = false
        lateinit var receiver: BroadcastReceiver
        fun finish(map: Map<String, Any?>) {
            if (done) return
            done = true
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
            result.success(map)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val b = i.getBundleExtra("result")
                if (b == null) { finish(err("Termux returned no result bundle.")); return }
                val ec: Int? = if (b.containsKey("exitCode")) b.getInt("exitCode") else null
                val internalErr = b.getInt("err", -1)
                finish(mapOf(
                    "stdout" to (b.getString("stdout") ?: ""),
                    "stderr" to (b.getString("stderr") ?: ""),
                    "exitCode" to ec,
                    "timedOut" to false,
                    "error" to (if (internalErr > 0 || (ec == null && !b.getString("errmsg").isNullOrEmpty())) b.getString("errmsg") else null),
                ))
            }
        }
        ContextCompat.registerReceiver(this, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)

        val cb = Intent(action).setPackage(packageName)
        val pi = PendingIntent.getBroadcast(this, id, cb, PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_MUTABLE)
        val home = "/data/data/com.termux/files/home"
        val i = Intent("com.termux.RUN_COMMAND").apply {
            setClassName(termuxPkg, "com.termux.app.RunCommandService")
            putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", command))
            putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir ?: home)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "AI Dev Hub")
            putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pi)
        }
        try {
            startService(i)
        } catch (e: Exception) {
            finish(err("Could not start Termux service: ${e.javaClass.simpleName}: ${e.message}. Is allow-external-apps=true set in ~/.termux/termux.properties?"))
            return
        }
        ui.postDelayed({
            finish(mapOf("stdout" to "", "stderr" to "", "exitCode" to null, "timedOut" to true,
                "error" to "No result from Termux within ${timeoutMs / 1000}s (command still running, or allow-external-apps is not enabled)."))
        }, timeoutMs)
    }
}
