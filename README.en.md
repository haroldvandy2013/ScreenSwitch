# ScreenSwitch

[简体中文](README.md) | **English**

Keep your MacBook open and work on an external monitor while continuing to use the built-in keyboard and trackpad.

A simple switch attempts to disable the built-in display's desktop output—not just dim it or cover it with a black window. A control window and Dock entry keep the app accessible even when the menu bar is full. **The app UI is currently in Simplified Chinese.**

<img src="docs/images/screenswitch.png" alt="ScreenSwitch control window with the disable action unavailable because no external monitor is connected" width="440">

*Actual app screenshot: disabling the built-in display is unavailable without an external monitor.*

> **Experimental:** ScreenSwitch uses an unsupported macOS interface. Compatibility and recovery are not guaranteed. Build, UI, and simulated checks have passed, but **actual display disabling and restoration have not been hardware-tested**. Read the recovery steps before first use.

## Download and install

Download `ScreenSwitch-v0.1.0-macos-arm64.zip` from [Releases](https://github.com/haroldvandy2013/ScreenSwitch/releases/latest). Extract it and copy both apps to your Applications folder:

- **ScreenSwitch.app**: the main app.
- **恢复内置屏幕.app** (“Restore built-in display”): a standalone recovery app. Keep it available in case the main app stops running.

The release is for **Apple Silicon Macs running macOS 13 or later**. Development used an M3 Max on macOS 15.8.1; this is not a claim of verified display-control compatibility.

The apps are **not Apple-notarized**. If launch is blocked, try Finder's right-click → Open or Open Anyway in System Settings. **Do not disable system security protections.**

## Use

1. Keep the lid open. Connect and wake an external monitor, and confirm that it displays a usable desktop.
2. Open ScreenSwitch, click **关闭内置屏幕** (“Turn off built-in display”), read the warning, and confirm. The action is unavailable without a usable external display.
3. Click **恢复内置屏幕** (“Restore built-in display”) when you want the panel back.

The app attempts restoration when the last usable external display disconnects, before sleep, and on normal quit. Reconnecting a monitor or waking the Mac **never automatically disables the panel**.

Closing the window keeps the app running; click its Dock icon to reopen it. Quit using **恢复屏幕并退出** (“Restore display and quit”), rather than force-quitting.

## If the screen goes black

Before first use, locate the restore app. If you plan to find it through Spotlight, confirm that Spotlight has indexed its Chinese name in advance.

1. Reconnect and wake the external monitor, then try **恢复内置屏幕**.
2. Launch **恢复内置屏幕.app**, directly or through Spotlight.
3. Try closing and reopening the lid. If recovery still fails, restart the Mac, keeping unsaved work in mind.

**Automatic recovery is not guaranteed after a crash, force quit, or system failure.** For the first attempt, use a directly connected physical monitor—not a virtual display or remote desktop as your only fallback. Avoid running other display-disabling utilities at the same time. Stop trying if disabling or restoration fails.

<details>
<summary>Build from source</summary>

Requires Swift 6.0 or later and Xcode Command Line Tools.

```bash
git clone https://github.com/haroldvandy2013/ScreenSwitch.git
cd ScreenSwitch
./build.sh
```

Both apps are generated in `dist/`, using the host Mac's processor architecture.

</details>
