# ScreenSwitch

**English** | [简体中文](README.zh-CN.md)

Work on an external monitor with your MacBook open, while keeping its built-in keyboard and trackpad available. ScreenSwitch provides a manual switch that attempts to disable the built-in display's desktop output, rather than lowering its brightness or covering it with a black window.

The app has a small control window, a Dock entry, and a menu-bar shortcut. **The application UI is currently in Simplified Chinese; this README is the English documentation.**

> **Experimental, unsupported display control.** macOS has no publicly supported API for this operation. ScreenSwitch dynamically resolves the private `CGSConfigureDisplayEnabled` function and uses a session-scoped CoreGraphics display-configuration transaction. Finding the symbol or receiving a successful return value does **not** establish hardware compatibility, backlight behavior, or reliable restoration. Do not use this app if a temporary black screen or a restart is unacceptable.

## Download and install

Download **`ScreenSwitch-v0.1.0-macos-arm64.zip`** from [Releases](https://github.com/haroldvandy2013/ScreenSwitch/releases). The initial release contains:

| File | Purpose |
| --- | --- |
| `ScreenSwitch.app` | Main app, with a control window, Dock entry, and menu-bar item |
| `恢复内置屏幕.app` | Standalone emergency restore app; its name means “Restore built-in display” |
| `README.md` / `README.zh-CN.md` | English / Simplified Chinese instructions |

The downloadable apps are **Apple Silicon (arm64) only**, require macOS 13 or later, and use local ad-hoc signatures. They are **not notarized by Apple**. If macOS blocks launch, use Finder's right-click → **Open**, or the **Open Anyway** option in System Settings when available. Do not disable Gatekeeper or SIP.

Extract the ZIP and copy **both apps** to `/Applications` or `~/Applications`. Keep the restore app accessible before attempting to disable the built-in screen. ScreenSwitch does not automatically install itself or configure login items.

`SHA256SUMS.txt` is available alongside the ZIP. With both downloads in the same directory, verify the archive with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

GitHub's automatically generated “Source code” archives contain source, not the built apps.

## Use

1. Keep the MacBook lid open. Connect and wake a real external monitor, and verify that it displays a usable desktop. A native HDMI, USB-C, or DisplayPort connection and extended-desktop mode are recommended for the first attempt.
2. Open `ScreenSwitch.app`. In the control window, click **关闭内置屏幕** (“Turn off built-in display”), read the warning, and manually confirm. The same action is available from the menu bar.
3. When the app confirms the panel is inactive, the switch becomes **恢复内置屏幕** (“Restore built-in display”). A separate restore action remains accessible.
4. If the last usable external display disconnects or becomes inactive, the app attempts to restore the built-in panel. With multiple external displays, one remaining usable external display is sufficient to keep working.
5. Reconnecting an external display or waking the Mac never automatically disables the built-in display. The app attempts restoration before sleep and on normal quit. If restoration cannot be confirmed, normal quit is cancelled and retries continue.

The disable action is unavailable when there is no usable external display, the built-in panel cannot be identified, the private API is unavailable, or a display operation is in progress. The app does not change keyboard or trackpad settings, display brightness, SIP, global power settings, or administrator privileges, and installs no root daemon.

### If the menu bar is full

Use the control window instead. Closing the window keeps the app and its recovery checks running. Click the Dock icon, open the app again in Finder, or select **显示控制窗口** (“Show control window”) from its menu to reopen it. With ScreenSwitch active, `Command + 0` also shows the window.

Quit using **恢复屏幕并退出** (“Restore display and quit”) or `Command + Q`, rather than force-quitting.

## Emergency recovery

Before the first attempt, locate `恢复内置屏幕.app`. If you want to use Spotlight during a black screen, copy it to an Applications folder and verify that Spotlight can find its Chinese name in advance.

If you lose visible output:

1. Reconnect and wake the original external monitor, then choose **恢复内置屏幕**.
2. Launch `恢复内置屏幕.app`. If Spotlight has indexed it, press `Command + Space`, type `恢复内置屏幕`, and press Return. It sends only enable requests, retries up to five times, and reports failure instead of claiming success.
3. Try closing and reopening the lid so macOS can re-enumerate displays. This is not a guaranteed recovery method.
4. If recovery still fails, restart the Mac. The display configuration is session-scoped, not a permanent display setting. Forced shutdown can lose unsaved work and should be a last resort for an unresponsive system.

You can also restore from Terminal:

```bash
# This command DOES send display-enable requests.
./dist/ScreenSwitch.app/Contents/MacOS/ScreenSwitch --restore
```

Adjust the path if you installed the app elsewhere. Exit status is `0` on confirmed restoration and `1` on failure. There is intentionally **no command-line disable option**.

### Recovery limitations

Recovery uses a CoreGraphics display-reconfiguration callback, AppKit screen-change notifications, and a one-second watchdog. Detection and reconfiguration take time. The external display check and disable transaction cannot be atomic with a physical cable disconnection.

Force quit, crashes, system hangs, driver failures, or changes to the private API can prevent automatic restoration. There is no always-running privileged service to guarantee recovery. Before disabling, the app persists the built-in display ID and a recovery marker; the remembered ID is accepted only if CoreGraphics still identifies it as built-in. On a later launch, an unfinished recovery takes priority over disabling.

Do not run other display-disabling utilities at the same time. ScreenSwitch does not fight macOS or another utility by automatically disabling a panel they have restored.

“Usable external display” means CoreGraphics reports it as online, active, awake, and having valid dimensions. This cannot prove that it is a physical monitor, that you can see its desktop, or that its cable/adapter works. Do not rely on AirPlay, virtual displays, remote desktops, or DisplayLink as your sole recovery path. Mirroring and docks need separate hardware testing.

## Build from source

Requirements: macOS 13 or later, Swift 6.0 or later, and Xcode Command Line Tools or Xcode. No third-party dependencies.

```bash
git clone https://github.com/haroldvandy2013/ScreenSwitch.git
cd ScreenSwitch
./build.sh
```

The script builds the release executable, packages both apps into `dist/`, and applies ad-hoc signatures. It builds for the host architecture, **not** a Universal binary. The restore app uses the same executable with a separate bundle identifier selecting its restore-only entry point.

### Safe checks

```bash
# Pure safety-policy combinations; no display-control code is linked.
swift run --quiet ScreenSwitchChecks

# Actual controller lifecycle with simulated displays; no real driver is created.
swift run --quiet ScreenSwitch --check-controller

# Opens, closes, and reopens the UI without clicking disable.
# An existing pending-recovery marker can trigger normal startup restoration.
swift run --quiet ScreenSwitch --check-ui

# Enumerates displays and resolves the private symbol; no display transaction.
./dist/ScreenSwitch.app/Contents/MacOS/ScreenSwitch --diagnose

codesign --verify --deep --strict dist/ScreenSwitch.app
codesign --verify --deep --strict 'dist/恢复内置屏幕.app'
```

`--check-controller` and `--check-ui` exist only in Debug builds. These checks use a dependency-free Swift runner, including on Command Line Tools installations without XCTest. Simulations cover manual toggling, removal of the last external display, one remaining external display, reconnection, sleep/wake, delayed effects, no-op APIs, failed restoration with continued retries, crash markers, and OS-initiated restoration. They are not hardware tests.

**复制只读诊断** (“Copy read-only diagnostics”) in the menu provides basic system and display information. Errors use the macOS unified log subsystem `local.ScreenSwitch`. Recovery state is stored in the current user's `local.ScreenSwitch.recovery` preferences domain; do not delete it while the panel is disabled.

## Verification and compatibility

The development machine was an **Apple M3 Max (Mac15,11), macOS 15.8.1 (24H32), Swift 6.1.2**. Read-only inspection confirmed that the private symbol could be resolved and the active built-in panel identified. No external display was online during those checks.

The app passed **262 safety-policy checks**, **26 simulated controller lifecycle checks**, and UI checks covering launch, shared safety state, closing, and reopening. Both arm64 apps were built and their signatures verified. The main app was launched with a visible control window and Dock entry; the built-in panel remained active.

**No real disable or restore transaction was executed as part of this verification.** Users still need to manually confirm on their own hardware:

- Actual removal of the built-in desktop output, backlight behavior, and pointer/window placement on the external display.
- Continued operation of the built-in keyboard and trackpad.
- Manual restoration, last-external unplug recovery, sleep/wake, and quit recovery.
- The emergency restore app, specific adapters/docks, mirrored setups, additional external displays, and other M3 Pro / Max machines.

Known limitations of base M3 Macs must not be generalized to all M3 Pro / Max devices. Conversely, resolving a private symbol does not establish compatibility on those devices. If the first attempt fails, stop trying to disable the panel, retain diagnostics, and do not change system security settings.

## Implementation references

This implementation was written independently. Research references: [clamOpen's private API description](https://github.com/Attiv/clamOpen) and [BetterDisplay's open-lid external-monitor guidance](https://betterdisplay.pro/guide/tutorials/external-monitors-with-open-macbook/). Their source code was not copied. ScreenSwitch does not include automatic-disable modes or power-management modifications.
