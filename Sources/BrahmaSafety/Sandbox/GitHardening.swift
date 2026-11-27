import Foundation

/// The hardening every engine git call carries (3a's `GitCommand`, as shipped): the command-line config that switches off
/// whatever git could run or reach, the fixed environment, and the variables a child git never inherits. `GitCommand` reads
/// them from here; the helper (Plan S) does too.
public enum GitHardening {
    /// Applied to every call, before the subcommand: what git may run is switched off whatever any config says (command-line
    /// config outranks every file, and reaches child git processes, such as one in a nested repository, too).
    public static let flags = [
        "-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c", "diff.external=",
        "-c", "core.sshCommand=/usr/bin/false", "-c", "core.gitProxy=", "-c", "core.askPass=/usr/bin/false",
        "-c", "credential.helper=", "-c", "gpg.program=/usr/bin/false", "-c", "gpg.ssh.program=/usr/bin/false",
        "-c", "gpg.x509.program=/usr/bin/false", "-c", "log.showSignature=false", "-c", "merge.verifySignatures=false",
        "-c", "submodule.recurse=false", "-c", "diff.ignoreSubmodules=dirty", "-c", "protocol.allow=never",
        "-c", "protocol.ext.allow=never", "-c", "core.alternateRefsCommand=", "-c", "uploadpack.packObjectsHook=",
        "-c", "core.editor=/usr/bin/false", "-c", "sequence.editor=/usr/bin/false",
        "-c", "core.quotepath=false", "-c", "gc.auto=0",
        "-c", "core.attributesFile=/dev/null", "-c", "advice.graftFileDeprecated=false",
    ]

    /// The fixed environment of every engine git: no global or system config, no replace objects or grafts, no prompts, no
    /// askpass, no optional locks (`GitCommand.environment()`).
    public static let environment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_GRAFT_FILE": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "GIT_OPTIONAL_LOCKS": "0",
    ]

    /// Never inherited by an engine git (the allowlist keeps them out already); named so that no later change lets one through.
    public static let neverInherited = ["GIT_EXTERNAL_DIFF", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_CONFIG_PARAMETERS",
                                        "GIT_CONFIG_COUNT", "GIT_EXEC_PATH", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR"]
}
