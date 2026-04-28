import Foundation

public enum FailureKind: Equatable {
    /// auth fail or host key mismatch or DNS — short-lived, never reached Connected.
    /// UI: red, "重新填凭据"; do NOT auto-reconnect.
    case authOrSetupFail

    /// Remote shell exited with `exit` (status 0). UI: grey "会话结束"; no reconnect.
    case cleanExit

    /// Network drop after Connected. UI: yellow; enter §4.3 reconnect FSM.
    case connectionDropped

    /// Classify exit_code + connected-history into one of the three.
    public static func classify(exitCode: Int32, hadConnected: Bool) -> FailureKind {
        if exitCode == 0 { return .cleanExit }
        if hadConnected { return .connectionDropped }
        // exit != 0 and never reached Connected = auth/setup phase failure.
        return .authOrSetupFail
    }
}
