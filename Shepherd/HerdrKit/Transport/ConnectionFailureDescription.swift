import Foundation
#if canImport(Citadel)
import Citadel
import NIOCore
import NIOPosix
#endif

/// What to tell the person about a failed connection or attach.
///
/// The errors that matter most here come from Citadel and SwiftNIO, and none
/// of them is a `LocalizedError`, so `localizedDescription` turns each into
/// "The operation couldn't be completed. (Citadel.SSHClientError error 4.)" —
/// which, for a rejected password, is all the board would show while it
/// waits for the person to fix the credential and press Retry. Errors of the
/// app's own, and anything not recognised below, keep their own
/// description.
nonisolated func connectionFailureDescription(_ error: any Error) -> String {
    #if canImport(Citadel)
    switch error {
    case SSHClientError.allAuthenticationOptionsFailed:
        return String(localized: "The machine turned the login down: the password is wrong, or the key isn't in that account's ~/.ssh/authorized_keys.")
    case SSHClientError.unsupportedPasswordAuthentication:
        return String(localized: "The machine doesn't accept password logins. Set the machine up with a key instead.")
    case SSHClientError.unsupportedPrivateKeyAuthentication:
        return String(localized: "The machine doesn't accept key logins.")
    case SSHClientError.unsupportedHostBasedAuthentication:
        return String(localized: "The machine doesn't accept this kind of login.")
    case SSHClientError.channelCreationFailed:
        return String(localized: "Logged in, but the machine wouldn't open a channel to herdr.")
    case let error as NIOConnectionError:
        return describe(error)
    case let error as IOError:
        return systemErrorDescription(error.errnoCode)
    case let error as ChannelError:
        if case .connectTimeout = error {
            return String(localized: "The machine didn't answer in time.")
        }
        return String(localized: "The connection to the machine closed unexpectedly.")
    default:
        break
    }
    #endif
    return error.localizedDescription
}

#if canImport(Citadel)
/// A failed TCP connect is reported as one error that holds a failure per
/// address tried (and per DNS lookup). Usually they all say the same thing,
/// so the first one is reason enough.
private nonisolated func describe(_ error: NIOConnectionError) -> String {
    let target = "\(error.host):\(error.port)"
    if let failure = error.connectionErrors.first {
        if let ioError = failure.error as? IOError {
            return String(localized: "Couldn't connect to \(target): \(systemErrorDescription(ioError.errnoCode)).")
        }
        return String(localized: "Couldn't connect to \(target).")
    }
    if error.dnsAError != nil || error.dnsAAAAError != nil {
        return String(localized: "Couldn't find \(error.host): the name doesn't resolve.")
    }
    return String(localized: "Couldn't connect to \(target).")
}
#endif

/// The system's reason for a failed socket call. `strerror` only speaks
/// English, so the ones a connection actually runs into are given here in
/// the app's own words, and the rest fall back to the system's text.
nonisolated func systemErrorDescription(_ code: Int32) -> String {
    switch code {
    case ECONNREFUSED: String(localized: "Connection refused")
    case ETIMEDOUT: String(localized: "Timed out")
    case EHOSTUNREACH: String(localized: "Host unreachable")
    case ENETUNREACH: String(localized: "Network unreachable")
    case ECONNRESET: String(localized: "Connection reset")
    case EPIPE: String(localized: "Connection closed")
    case ENOENT: String(localized: "No such file or directory")
    case EACCES: String(localized: "Permission denied")
    case EMFILE: String(localized: "Too many open files")
    default: String(cString: strerror(code))
    }
}
