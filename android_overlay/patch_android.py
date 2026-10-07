"""Patches the flutter-generated android/ project. Run from the repo root after
`flutter create` and before `flutter build`. Idempotent."""
import glob, shutil, os

# ---- manifest ----------------------------------------------------------------
p = "android/app/src/main/AndroidManifest.xml"
s = open(p).read()

perms = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    "android.permission.RECORD_AUDIO",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "android.permission.REQUEST_INSTALL_PACKAGES",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.READ_EXTERNAL_STORAGE",
    "com.termux.permission.RUN_COMMAND",
]
add = "".join('    <uses-permission android:name="%s"/>\n' % x for x in perms if x not in s)
s = s.replace("<application", add + "    <application", 1)

if "usesCleartextTraffic" not in s:
    s = s.replace("<application", '<application android:usesCleartextTraffic="true"', 1)

pk = '<intent><action android:name="android.speech.RecognitionService"/></intent><package android:name="com.termux"/><package android:name="moe.shizuku.privileged.api"/>'
if "com.termux\"/>" not in s:
    if "<queries>" in s:
        s = s.replace("<queries>", "<queries>" + pk, 1)
    else:
        s = s.replace("<application", "<queries>" + pk + "</queries>\n    <application", 1)

svc = "\n".join([
    '        <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"',
    '            android:foregroundServiceType="specialUse" android:exported="false">',
    '            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"',
    '                android:value="Local OpenAI-compatible proxy server"/>',
    '        </service>',
    '',
])
prov = "\n".join([
    '        <provider android:name="rikka.shizuku.ShizukuProvider"',
    '            android:authorities="${applicationId}.shizuku"',
    '            android:multiprocess="false" android:enabled="true" android:exported="true"',
    '            android:permission="android.permission.INTERACT_ACROSS_USERS_FULL"/>',
    '',
])
extra = ""
if "ForegroundService" not in s:
    extra += svc
if "ShizukuProvider" not in s:
    extra += prov
s = s.replace("</application>", extra + "    </application>", 1)
open(p, "w").write(s)
print(s)

# ---- native bridge -----------------------------------------------------------
kt = glob.glob("android/app/src/main/**/MainActivity.kt", recursive=True)[0]
shutil.copy("android_overlay/MainActivity.kt", kt)

# ---- gradle deps -------------------------------------------------------------
g = (glob.glob("android/app/build.gradle.kts") + glob.glob("android/app/build.gradle"))[0]
t = open(g).read()
if "dev.rikka.shizuku" not in t:
    q = '"' if g.endswith(".kts") else '"'
    call = "implementation(%s)" if g.endswith(".kts") else "implementation %s"
    t += "\ndependencies {\n    " + (call % '"dev.rikka.shizuku:api:13.1.5"') + "\n    " + (call % '"dev.rikka.shizuku:provider:13.1.5"') + "\n}\n"
    open(g, "w").write(t)
