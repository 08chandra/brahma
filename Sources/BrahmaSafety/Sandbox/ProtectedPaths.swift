import Foundation

/// What no turn may read or write under the owner's home, whatever the company's settings.
public enum ProtectedPaths {
    static let credentials = [
        ".ssh", ".aws", ".config/gh", ".gnupg", ".netrc", ".docker", ".kube", ".claude", ".claude.json", ".npmrc", ".pypirc",
        ".git-credentials", ".gitconfig", ".cargo/credentials", ".cargo/credentials.toml", ".m2", ".gem", ".zsh_history",
        ".bash_history", ".zshrc",
    ]
    static let library = [
        "Library/Keychains", "Library/Cookies", "Library/Safari", "Library/Messages", "Library/Mail", "Library/Containers",
        "Library/Group Containers",
    ]
    static let applicationSupport = ["Google/Chrome", "BraveSoftware", "Firefox", "Microsoft Edge", "Arc", "Claude", "Slack",
                                     "1Password", "Code"]

    public static func defaults(userHome: URL) -> [URL] {
        (credentials + library + applicationSupport.map { "Library/Application Support/\($0)" })
            .map { userHome.appending(path: $0) }
    }
}
