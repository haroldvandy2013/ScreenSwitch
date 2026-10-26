public struct SafetyPolicy {
    public let apiAvailable: Bool
    public let builtinKnown: Bool
    public let builtinActive: Bool
    public let usableExternalCount: Int
    public let availableExternalCount: Int
    public let recoveryPending: Bool
    public let operationPending: Bool
    public let sleeping: Bool
    public let displaySleeping: Bool
    public let restoreOnDisplaySleep: Bool

    public init(
        apiAvailable: Bool, builtinKnown: Bool, builtinActive: Bool,
        usableExternalCount: Int, availableExternalCount: Int,
        recoveryPending: Bool, operationPending: Bool, sleeping: Bool,
        displaySleeping: Bool = false, restoreOnDisplaySleep: Bool = false
    ) {
        self.apiAvailable = apiAvailable
        self.builtinKnown = builtinKnown
        self.builtinActive = builtinActive
        self.usableExternalCount = usableExternalCount
        self.availableExternalCount = availableExternalCount
        self.recoveryPending = recoveryPending
        self.operationPending = operationPending
        self.sleeping = sleeping
        self.displaySleeping = displaySleeping
        self.restoreOnDisplaySleep = restoreOnDisplaySleep
    }

    public var canDisable: Bool {
        apiAvailable && builtinKnown && builtinActive && usableExternalCount > 0
            && !recoveryPending && !operationPending && !sleeping && !displaySleeping
    }

    public var mustRestore: Bool {
        recoveryPending && (
            availableExternalCount == 0 || sleeping
                || (displaySleeping && restoreOnDisplaySleep)
        )
    }
}
