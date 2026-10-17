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
public nonisolated func connectionFailureDescription(_ error: any Error) -> String {
    #if canImport(Citadel)
    switch error {
    case SSHClientError.allAuthenticationOptionsFailed:
        return String(localized: "The machine turned the login down: the password is wrong, or the key isn't in that account's ~/.ssh/authorized_keys.", bundle: .shepherdKit)
    case SSHClientError.unsupportedPasswordAuthentication:
        return String(localized: "The machine doesn't accept password logins. Set the machine up with a key instead.", bundle: .shepherdKit)
    case SSHClientError.unsupportedPrivateKeyAuthentication:
        return String(localized: "The machine doesn't accept key logins.", bundle: .shepherdKit)
    case SSHClientError.unsupportedHostBasedAuthentication:
        return String(localized: "The machine doesn't accept this kind of login.", bundle: .shepherdKit)
    case SSHClientError.channelCreationFailed:
        return String(localized: "Logged in, but the machine wouldn't open a channel to herdr.", bundle: .shepherdKit)
    case let error as NIOConnectionError:
        return describe(error)
    case let error as IOError:
        return systemErrorDescription(error.errnoCode)
    case let error as ChannelError:
        if case .connectTimeout = error {
            return String(localized: "The machine didn't answer in time.", bundle: .shepherdKit)
        }
        return String(localized: "The connection to the machine closed unexpectedly.", bundle: .shepherdKit)
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
            return String(localized: "Couldn't connect to \(target): \(systemErrorDescription(ioError.errnoCode)).", bundle: .shepherdKit)
        }
        return String(localized: "Couldn't connect to \(target).", bundle: .shepherdKit)
    }
    if error.dnsAError != nil || error.dnsAAAAError != nil {
        return String(localized: "Couldn't find \(error.host): the name doesn't resolve.", bundle: .shepherdKit)
    }
    return String(localized: "Couldn't connect to \(target).", bundle: .shepherdKit)
}
#endif

/// The system's reason for a failed socket call. `strerror` only speaks
/// English, so the ones a connection actually runs into are given here in
/// the app's own words, and the rest fall back to the system's text.
public nonisolated func systemErrorDescription(_ code: Int32) -> String {
    switch code {
    case ECONNREFUSED: String(localized: "Connection refused", bundle: .shepherdKit)
    case ETIMEDOUT: String(localized: "Timed out", bundle: .shepherdKit)
    case EHOSTUNREACH: String(localized: "Host unreachable", bundle: .shepherdKit)
    case ENETUNREACH: String(localized: "Network unreachable", bundle: .shepherdKit)
    case ECONNRESET: String(localized: "Connection reset", bundle: .shepherdKit)
    case EPIPE: String(localized: "Connection closed", bundle: .shepherdKit)
    case ENOENT: String(localized: "No such file or directory", bundle: .shepherdKit)
    case EACCES: String(localized: "Permission denied", bundle: .shepherdKit)
    case EMFILE: String(localized: "Too many open files", bundle: .shepherdKit)
    default: String(cString: strerror(code))
    }
}
