import Foundation
import BrahmaCore
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum OwnerKeyRotationError: Error, Equatable {
    case notAuthorized
}

/// Replaces the owner key from the app. Unlike `brahma owner init --rotate` (which needs the current key to be
/// valid), the app may rotate a lost or invalid key after the owner proves presence (Touch ID or password).
public struct OwnerKeyRotation: Sendable {
    public typealias Authenticate = @Sendable (_ reason: String) async -> Bool
    private let authenticate: Authenticate

    public init(authenticate: @escaping Authenticate = OwnerKeyRotation.userPresence) {
        self.authenticate = authenticate
    }

    @discardableResult
    public func rotate(paths: BrahmaPaths, store: any OwnerKeyStore) async throws -> URL {
        guard await authenticate("Replace the Brahma owner key") else { throw OwnerKeyRotationError.notAuthorized }
        return try OwnerKey.create(paths: paths, store: store, rotate: true)
    }

    /// `LAContext` user-presence check; without LocalAuthentication nothing is authorized.
    public static let userPresence: Authenticate = { reason in
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        #else
        return false
        #endif
    }
}
