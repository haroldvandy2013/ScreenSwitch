# ScreenSwitch

[简体中文](README.md) | **English**

Keep your MacBook open and work on an external monitor while continuing to use the built-in keyboard and trackpad.

A simple switch attempts to disable the built-in display's desktop output—not just dim it or cover it with a black window. A control window and Dock entry keep the app accessible even when the menu bar is full. **The UI supports Simplified Chinese and English, defaulting to Chinese.**

<img src="docs/images/screenswitch.png" alt="ScreenSwitch v0.2.2 with a state-aware display action, Refresh, a top-right version label, and language selection" width="520">

*Actual v0.2.2 screenshot: a state-aware display action, read-only Refresh, and live language switching.*

> **Experimental:** ScreenSwitch uses an unsupported macOS interface. Compatibility and recovery are not guaranteed. Build, UI, and simulated checks have passed, but this does not establish compatibility with every machine. Read the recovery steps before first use.

## Download and install

Download **ScreenSwitch-v0.2.9-macos-arm64.zip** from [Releases](https://github.com/haroldvandy2013/ScreenSwitch/releases/latest). Extract it and copy **ScreenSwitch.app** to your Applications folder. Disabling and recovery are integrated into this single app; no separate restore app is needed.

Before updating, confirm that the built-in display is active, then quit the old version and replace it. Do not force-quit a stuck old version while the built-in display is off.

When upgrading from v0.1.0, quit the old app normally before replacing it. Once you confirm that the new app restores the panel on normal quit, you may remove the old `恢复内置屏幕.app`.

The download is for **Apple Silicon Macs running macOS 13 or later**. Development used an M3 Max on macOS 15.8.1; this is not a claim of verified display-control compatibility.

The app is **not Apple-notarized**. If launch is blocked, try Finder's right-click → Open or Open Anyway in System Settings. **Do not disable system security protections.**

## Use

1. Keep the lid open. Connect and wake an external monitor, and confirm that it displays a usable desktop.
2. Open ScreenSwitch, click **关闭内置屏幕** (“Turn off built-in display”), read the warning, and confirm. The action is unavailable without a usable external display.
3. Click **恢复内置屏幕** (“Restore built-in display”) when you want the panel back.

Use **语言 / Language** in the window or menu to select “简体中文” or “English”. Changes apply immediately and are remembered. A fresh installation defaults to Chinese.

The version appears in the top-right corner. **Refresh** only rechecks display state, without disabling or restoring a display. The single action reads “Turn off built-in display” while the panel is on, and “Restore built-in display” while it is off. An already active panel does not receive redundant restore transactions.

Menu-bar and option tooltips, and automatic expansion tips on window labels, are disabled to prevent lingering floating text after display changes. Status and errors remain in the window and menu; option details remain in Usage and safety.

The current version is **v0.2.9**. The current recovery record and a persistent manual-disable guard are separate. Two seconds of stable internal activity finishes a recovery, but automatic recovery does not erase the guard history. If the panel later stays inactive for five seconds while awake, not in display sleep, and without an external monitor, guarded recovery starts again. Normal sleep does not trigger restoration solely from inactivity. Confirmed explicit user restoration clears the guard. Records already lost by an older version cannot be reconstructed.

Recovery confirmation cross-checks the online list, active list and valid per-display state. Invalid values such as `-1` never count as an active panel or clear recovery intent. v0.2.8 permits enabling a previously verified historical internal ID with a recovery record or guard, even when unplug makes its queries invalid. This exception is offline-only and never permits disabling or targeting a recognized external/virtual display. A successful API return still requires stable internal activity before recovery is confirmed. Failed enabling with no available external monitor retains the saved-configuration fallback. The recognized macOS fallback virtual display (`unkn/virt` device identity) neither authorizes disabling nor prevents unplug recovery. Other virtual-display implementations are not guaranteed to be recognized; keep a physical monitor available.

Recovery starts immediately, followed by up to **five retries** separated by **1, 3, 5, 10 and 15 seconds** (approximately 1, 4, 9, 19 and 34 seconds after the initial attempt when API calls return promptly). Stable success cancels the remaining retries. If the panel is still inactive five seconds after the final attempt, the app warns once and stops retrying, retaining recovery intent. Reconnect the external monitor and manually select **Restore built-in display** to start a new round. Sleep/wake notifications do not reset the attempt count. Restore-only mode and normal quit allow approximately 40 seconds for the sequence.

**Optional: Restore built-in display on screen sleep.** Unchecked by default. When enabled, display sleep triggers an attempt to restore the panel disabled by this app; the choice is remembered. This means actual display sleep, not just locking the screen or starting a screensaver. It does not reboot the Mac or send wake commands; screen illumination depends on macOS. Waking never automatically disables the panel again.

The app attempts restoration when the last usable external display disconnects, before sleep, and on normal quit. Reconnecting a monitor or waking the Mac **never automatically disables the panel**.

System-sleep, unplug and quit recovery remain enabled regardless of the screen-sleep option.

Removal of the last external monitor requests immediate restoration, with continued active-state checks. If normal recovery fails with no external monitor available, the app also requests macOS's saved display configuration. **This may reset display arrangements.** Restoration is still not guaranteed on every machine or after driver failures.
Closing the window keeps the app running. Clicking the running app's Dock icon or opening it again only shows the window and refreshes state without display transactions or resetting retry counts. A fresh launch after a crash still attempts recovery using the saved record. To restore manually, click **Refresh** and select **Restore built-in display**. Quit using **恢复屏幕并退出** (“Restore and quit”), rather than force-quitting.

## If the screen goes black

Before first use, locate ScreenSwitch. If you plan to find it through Spotlight, confirm that Spotlight has indexed it in advance.

1. Reconnect and wake the external monitor, then try **恢复内置屏幕**.
2. Open **ScreenSwitch.app**, directly or through Spotlight, and select **Restore built-in display**. If the app previously crashed, a fresh launch attempts recovery using the saved record. Reopening may not help if the process is hung; continue to the next step.
3. Try closing and reopening the lid. If recovery still fails, restart the Mac, keeping unsaved work in mind.

**Automatic recovery is not guaranteed after a crash, force quit, or system failure.** For the first attempt, use a directly connected physical monitor—not a virtual display or remote desktop as your only fallback. Avoid running other display-disabling utilities at the same time. Stop trying if disabling or restoration fails.

### Diagnostic logs

v0.2.7 adds independent rolling logs in `~/Library/Logs/ScreenSwitch/`: `ScreenSwitch.log` and up to two archives, `ScreenSwitch.1.log` and `ScreenSwitch.2.log`, about 1 MiB each. They record state changes, callbacks, sleep/wake, recovery and guard changes, retries, display calls before/after execution and return codes, plus a one-minute state heartbeat. Each entry is synchronized to disk, interprocess writes are locked, and files are owner-only. No screen contents are recorded or logs uploaded. Write failures are reported through the system log and standard error without blocking recovery.

The logs and read-only diagnostics also include online/active lists, raw display-state return values, device identities and ignored virtual displays, distinguishing actual recovery from invalid queries without recording screen contents.

v0.2.7 build 10 additionally captures IORegistry display-service snapshots at startup/topology changes and while recovery intent exists with persistently invalid queries. It records framebuffer/DCP service classes, registry IDs, parent relationships, allowlisted numeric connection/power properties and lid state—not serial numbers, EDID, arbitrary property text or the full registry. Captures run on a serial background queue at most once every five seconds, without accumulating tasks, using the same rolling logs. A capture ID, reason, associated CoreGraphics state and duration correlate each snapshot. Observation is not atomic with display state; failures and truncation are explicitly recorded. Logging does not change recovery policy.

Run `./dist/update/ScreenSwitch.app/Contents/MacOS/ScreenSwitch --diagnose-hardware` for a manual read-only, filtered hardware snapshot without display transactions.

If an issue recurs, note the time and whether you reconnected the external monitor, preserve all three files, and keep the app running if possible. **Copy read-only diagnostics** includes current state, the guard and log directory. The macOS unified log remains available as supplementary evidence:

```bash
/usr/bin/log show --last 1d --style compact --predicate 'subsystem == "local.ScreenSwitch"' > ~/Desktop/ScreenSwitch.log
```

macOS controls retention. A healthy current state does not establish what happened during the incident.

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
