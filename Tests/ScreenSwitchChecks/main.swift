import Foundation
import ScreenSwitchCore

var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// No AppKit, CoreGraphics, or display mutations are linked into this check runner.
for bits in 0..<128 {
    let api = bits & 1 != 0
    let known = bits & 2 != 0
    let active = bits & 4 != 0
    let external = bits & 8 != 0
    let recovery = bits & 16 != 0
    let operation = bits & 32 != 0
    let sleeping = bits & 64 != 0
    let policy = SafetyPolicy(
        apiAvailable: api, builtinKnown: known, builtinActive: active,
        usableExternalCount: external ? 1 : 0, availableExternalCount: external ? 1 : 0,
        recoveryPending: recovery,
        operationPending: operation, sleeping: sleeping
    )
    expect(
        policy.canDisable == (api && known && active && external && !recovery && !operation && !sleeping),
        "Manual disable safety gate, combination \(bits)"
    )
    expect(
        policy.mustRestore == (recovery && (!external || sleeping)),
        "Unplug/sleep restoration, combination \(bits)"
    )
}

for count in [1, 2, 3] {
    let policy = SafetyPolicy(
        apiAvailable: true, builtinKnown: true, builtinActive: true,
        usableExternalCount: count, availableExternalCount: count, recoveryPending: false,
        operationPending: false, sleeping: false
    )
    expect(policy.canDisable, "At least one usable external allows manual operation")
    expect(!policy.mustRestore, "A new external never requests an automatic operation")
}
for enabled in [false, true] {
    for recovery in [false, true] {
        for systemSleep in [false, true] {
            for connected in [false, true] {
                for displaySleep in [false, true] {
                    let policy = SafetyPolicy(
                        apiAvailable: true, builtinKnown: true, builtinActive: true,
                        usableExternalCount: connected && !displaySleep ? 1 : 0,
                        availableExternalCount: connected ? 1 : 0,
                        recoveryPending: recovery, operationPending: false, sleeping: systemSleep,
                        displaySleeping: displaySleep, restoreOnDisplaySleep: enabled
                    )
                    expect(
                        policy.mustRestore == (recovery && (!connected || systemSleep || (enabled && displaySleep))),
                        "Display-sleep restoration is opt-in; unplug/system sleep remain protected"
                    )
                    expect(
                        policy.canDisable == (connected && !displaySleep && !systemSleep && !recovery),
                        "Sleeping displays never authorize a new disable"
                    )
                }
            }
        }
    }
}
print("PASS: \(checks) safety checks; no display configuration APIs called.")
