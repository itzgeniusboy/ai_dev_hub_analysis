# Android setup (proxy, SAF, APK install)

Add to `android/app/src/main/AndroidManifest.xml`.

Permissions (above `<application>`):
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```

Inside `<application>`:
```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="specialUse"
    android:exported="false">
  <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
            android:value="Local OpenAI-compatible proxy server"/>
</service>
```

`<application android:usesCleartextTraffic="true" ...>` is NOT needed for the
server itself (it accepts connections), but IS needed if the app calls a
self-hosted gateway over plain http on your LAN (e.g. http://192.168.1.10:20128/v1).
Prefer a network-security-config limited to private ranges over a global flag.

Call `ProxyController.initForegroundService()` once in `main()` before `runApp`.

Notes:
- Play Store policy reviews `specialUse` foreground services; fine for sideloading.
- Some OEMs (Xiaomi, Samsung, Huawei) kill background apps aggressively; the user
  may need to exempt the app from battery optimization.
- APK install: `open_filex` needs a FileProvider; follow its README. The user must
  allow "Install unknown apps" for your app once.
- Verify `flutter_foreground_task` option names against the installed version (v8.x API).

Build config (`android/app/build.gradle` or `build.gradle.kts`):
- Set `minSdk` to 23 or higher. `flutter_secure_storage` 9.x requires it and
  Flutter's default is lower, so the build fails at manifest merge otherwise.

## Required: INTERNET permission (release builds)
`flutter create` adds INTERNET only to the debug/profile manifests, so release
APKs get "Operation not permitted" on every socket (chat AND local proxy).
`.github/workflows/build_apk.yml` now patches the manifest automatically. If you
build locally, add the permissions above to `android/app/src/main/AndroidManifest.xml`
(plus ACCESS_NETWORK_STATE) and rebuild.

## Device file tools
Settings > "Device file access" uses MANAGE_EXTERNAL_STORAGE ("All files access") so the model can work on any
path under /storage/emulated/0. Fine for sideloading; Google Play restricts this permission. Deletes go to
`<app documents>/fs_trash` (30 days, `fs_restore` brings them back); /data, /system and other apps' private
folders are blocked.

## Terminal tools (Termux + Shizuku)
Native code lives in `android_overlay/MainActivity.kt`; CI copies it over the generated MainActivity and adds the
Shizuku dependencies/provider and the `com.termux.permission.RUN_COMMAND` permission. Local builds: do the same.
Setup on the phone: install Termux (F-Droid/GitHub build), run the command shown in Settings > Terminal inside Termux
(`allow-external-apps=true`) and restart it, start Shizuku, then grant both permissions in the Terminal screen.
