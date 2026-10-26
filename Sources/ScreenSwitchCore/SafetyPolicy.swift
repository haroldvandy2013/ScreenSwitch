public struct SafetyPolicy {
    public let apiAvailable: Bool
    public let builtinKnown: Bool
    public let builtinActive: Bool
    public let usableExternalCount: Int
    public let recoveryPending: Bool
    public let operationPending: Bool
    public let sleeping: Bool

    public init(
        apiAvailable: Bool, builtinKnown: Bool, builtinActive: Bool,
        usableExternalCount: Int, recoveryPending: Bool,
        operationPending: Bool, sleeping: Bool
    ) {
        self.apiAvailable = apiAvailable
        self.builtinKnown = builtinKnown
        self.builtinActive = builtinActive
        self.usableExternalCount = usableExternalCount
        self.recoveryPending = recoveryPending
        self.operationPending = operationPending
        self.sleeping = sleeping
    }

    public var canDisable: Bool {
        apiAvailable && builtinKnown && builtinActive && usableExternalCount > 0
            && !recoveryPending && !operationPending && !sleeping
    }

    public var mustRestore: Bool {
        recoveryPending && (usableExternalCount == 0 || sleeping)
    }
}
