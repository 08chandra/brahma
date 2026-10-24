import Foundation

/// The one way phone-alert settings and their vault credentials change together (the CLI today, the app's notifications
/// panel later). Everything is validated before anything is stored, and a credential never outlives what it was for:
///
/// - An ntfy token is stored bound to its server (`OwnerCredential.boundNtfyToken`), and is deleted when the server or the
///   provider changes without a new token. A token is never sent to another server.
/// - Switching provider deletes the old provider's credentials; `turnOff` deletes all of them.
/// - Every change bumps `Store.pushCredentialsVersion()`, so the engine rebuilds its cached channel once.
public enum PushSettings {
    public static func setNtfy(store: Store, vault: any SecretVault, topic: String, server: String?, token: String?,
                               now: Date = Store.now()) throws {
        let before = try store.ownerPrefs()
        let newServer = server ?? before.pushServer
        if let token, !OwnerCredential.valid(token) { throw PushError.badCredential("ntfy token") }
        _ = try NtfyChannel(server: newServer, topic: topic, token: nil)
        var next = before
        next.pushProvider = .ntfy; next.pushTopic = topic; next.pushServer = newServer
        try next.validate()

        let newNormalized = try PushURL.normalized(server: newServer)
        let sameServer = before.pushProvider == .ntfy && (try? PushURL.normalized(server: before.pushServer)) == newNormalized
        if let token {
            try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken,
                          value: try OwnerCredential.boundNtfyToken(token, server: newServer))
        } else if !sameServer {
            try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken)
        }
        if before.pushProvider != .ntfy { try deletePushover(vault) }
        try store.setPush(provider: .ntfy, topic: topic, server: newServer, credentialsChanged: true, now: now)
    }

    public static func setPushover(store: Store, vault: any SecretVault, appToken: String, userKey: String,
                                   now: Date = Store.now()) throws {
        guard OwnerCredential.valid(appToken) else { throw PushError.badCredential("Pushover app token") }
        guard OwnerCredential.valid(userKey) else { throw PushError.badCredential("Pushover user key") }
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken, value: appToken)
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey, value: userKey)
        try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken)
        try store.setPush(provider: .pushover, credentialsChanged: true, now: now)
    }

    public static func turnOff(store: Store, vault: any SecretVault, now: Date = Store.now()) throws {
        try store.setPush(provider: nil, credentialsChanged: true, now: now)
        try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken)
        try deletePushover(vault)
    }

    private static func deletePushover(_ vault: any SecretVault) throws {
        try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken)
        try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey)
    }
}
