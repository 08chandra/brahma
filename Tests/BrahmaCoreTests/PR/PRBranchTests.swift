import Foundation
import Testing
@testable import BrahmaCore

/// The PR branch name (Plan X8 Task 2): `brahma/<KEY>-<slug>`, the slug from the item title by a fixed rule, refused when git
/// would refuse the ref.
@Suite(.scratch) struct PRBranchTests {
    private func name(_ key: String, _ title: String) -> String? {
        if case .allowed(let n) = PRBranch.name(key: key, title: title) { return n }
        return nil
    }

    /// Review Focus 2: agent-written titles never put anything but `[a-z0-9-]` after the key.
    @Test func slugIsSafe() throws {
        #expect(name("A-7", "../../x; rm -rf /") == "brahma/A-7-x-rm-rf")
        #expect(name("A-7", "Fix the Login   button!") == "brahma/A-7-fix-the-login-button")
        #expect(name("A-7", "$(touch /tmp/p) `id` @{u} ~^:?*[\\") == "brahma/A-7-touch-tmp-p-id-u")
        #expect(name("A-7", "Ünïcödé — naïve café") == "brahma/A-7-n-c-d-na-ve-caf")
        let long = String(repeating: "abcdefghij ", count: 30)   // 330 characters
        let longName = try #require(name("A-7", long))
        let slug = String(longName.dropFirst("brahma/A-7-".count))
        #expect(slug.count <= PRBranch.maxSlug, "\(slug)")
        #expect(!slug.hasSuffix("-") && !slug.hasPrefix("-"))
        #expect(slug.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" })
        // Nothing left of the title: the key alone.
        #expect(name("A-7", "") == "brahma/A-7")
        #expect(name("A-7", "!!! ///  ...") == "brahma/A-7")
        #expect(name("A-7", "\u{0}\u{7f}\n\t") == "brahma/A-7")
        // The key is the engine's, but a key git would refuse (or one that could climb) is refused, never repaired.
        for bad in ["", "-A-7", "A/7", "A..7", "A 7", "A-7.lock", "@", "A@{7"] {
            guard case .refused = PRBranch.name(key: bad, title: "t") else { Issue.record("accepted key \(bad)"); continue }
        }
        // The whole ref stays within 100 bytes.
        let key = String(repeating: "K", count: 60)
        if case .allowed(let n) = PRBranch.name(key: key, title: long) {
            #expect(PRBranch.ref(n).utf8.count <= PRBranch.maxRefBytes, "\(n)")
        } else {
            Issue.record("a long key with a long title should still name a branch")
        }
        #expect(PRBranch.ref("brahma/A-7") == "refs/heads/brahma/A-7")
    }

    /// Every name `PRBranch` gives is one `git check-ref-format --branch` accepts; the pure check agrees with git on refusals.
    @Test func refIsCheckRefFormatValid() throws {
        let titles = ["../../x; rm -rf /", "", "a.lock", "x..y", "trailing.", ".leading", "@{-1}", "@", "with space", "tab\there",
                      String(repeating: "z", count: 200), "UPPER lower 123", "émoji 🚀 here", "a//b", "-dash-first", "q?x*y[z\\"]
        for title in titles {
            let n = try #require(name("A-7", title), "\(title)")
            #expect(PRBranch.isValidBranchName(n), "\(n)")
            #expect(try checkRefFormat(n), "git refuses \(n)")
        }
        for bad in ["brahma/a..b", "brahma/a.lock", "brahma/.a", "brahma/a/", "brahma//a", "brahma/a.", "brahma/a@{b", "@",
                    "brahma/a b", "brahma/a~b", "brahma/a^b", "brahma/a:b", "brahma/a?b", "brahma/a*b", "brahma/a[b", "brahma/a\\b",
                    "-brahma", "brahma/a\u{7f}"] {
            #expect(!PRBranch.isValidBranchName(bad), "\(bad)")
            // `--branch` reads a lone `@` as HEAD's shorthand and prints it back; as a ref name git refuses it too.
            if bad != "@" { #expect(try !checkRefFormat(bad), "git accepts \(bad)") }
        }
    }

    private func checkRefFormat(_ name: String) throws -> Bool {
        // On success git prints the name back; on a refusal stdout is empty.
        try GitFixture.plainGit(["check-ref-format", "--branch", name], in: try tempDir(), allowFailure: true) == name
    }
}
