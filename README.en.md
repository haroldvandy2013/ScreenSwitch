# ScreenSwitch

[简体中文](README.md) | **English**

Keep your MacBook open and work on an external monitor while continuing to use the built-in keyboard and trackpad.

A simple switch attempts to disable the built-in display's desktop output—not just dim it or cover it with a black window. A control window and Dock entry keep the app accessible even when the menu bar is full. **The UI supports Simplified Chinese and English, defaulting to Chinese.**

<img src="docs/images/screenswitch.png" alt="ScreenSwitch control window with built-in display controls and a Chinese/English language selector" width="520">

*Actual app screenshot: disable and restore controls in one app, with live language switching.*

> **Experimental:** ScreenSwitch uses an unsupported macOS interface. Compatibility and recovery are not guaranteed. Build, UI, and simulated checks have passed, but **actual display disabling and restoration have not been hardware-tested**. Read the recovery steps before first use.

## Download and install

The current source and local build are **v0.2.0**. Disabling and recovery are integrated into a single **ScreenSwitch.app**; no separate restore app is needed. Build using the instructions below, then copy `dist/ScreenSwitch.app` to your Applications folder.

The existing **v0.1.0** on [Releases](https://github.com/haroldvandy2013/ScreenSwitch/releases/latest) is the older two-app package and does not include these changes. Once you update and confirm normal quit restores the panel, you may remove the old `恢复内置屏幕.app`.

Requires **macOS 13 or later**. Development used an Apple Silicon M3 Max on macOS 15.8.1; this is not a claim of verified display-control compatibility.

The apps are **not Apple-notarized**. If launch is blocked, try Finder's right-click → Open or Open Anyway in System Settings. **Do not disable system security protections.**

## Use

1. Keep the lid open. Connect and wake an external monitor, and confirm that it displays a usable desktop.
2. Open ScreenSwitch, click **关闭内置屏幕** (“Turn off built-in display”), read the warning, and confirm. The action is unavailable without a usable external display.
3. Click **恢复内置屏幕** (“Restore built-in display”) when you want the panel back.

Use **语言 / Language** in the window or menu to select “简体中文” or “English”. Changes apply immediately and are remembered. A fresh installation defaults to Chinese.

The app attempts restoration when the last usable external display disconnects, before sleep, and on normal quit. Reconnecting a monitor or waking the Mac **never automatically disables the panel**.

Closing the window keeps the app running. Clicking its Dock icon or reopening the app first attempts restoration if the panel is inactive or recovery is pending. Quit using **恢复屏幕并退出** (“Restore and quit”), rather than force-quitting.

## If the screen goes black

Before first use, locate ScreenSwitch. If you plan to find it through Spotlight, confirm that Spotlight has indexed it in advance.

1. Reconnect and wake the external monitor, then try **恢复内置屏幕**.
2. Reopen **ScreenSwitch.app**, directly or through Spotlight, to attempt recovery first. Reopening may not help if the process is hung; continue to the next step.
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

Only `dist/ScreenSwitch.app` is generated, using the host Mac's processor architecture. You can also run `./dist/ScreenSwitch.app/Contents/MacOS/ScreenSwitch --restore` from Terminal to attempt restoration only, without disabling the panel.

</details>
