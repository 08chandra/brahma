import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 4 (spec §8.2.2): the doctor names a Claude auth variable in the engine's own environment, which turns now ignore.
// The environment is injected: these tests never read the real process environment.

@Suite(.scratch) struct DoctorAmbientAuthTests {
    @Test func warnsAndNamesVariable() {
        let key = ["sk", "ant", "real"].joined(separator: "-")
        let api = Doctor.ambientAuthItem(environment: ["PATH": "/bin", "ANTHROPIC_API_KEY": key])
        #expect(api == DoctorItem(name: "ambient-claude-auth", status: .warn,
                                  detail: "ignored (ANTHROPIC_API_KEY is set in your environment; Brahma uses only the company key; see brahma billing)"))
        #expect(!api.detail.contains(key))

        let oauth = Doctor.ambientAuthItem(environment: ["CLAUDE_CODE_OAUTH_TOKEN": "owner-oauth"])
        #expect(oauth.status == .warn)
        #expect(oauth.detail == "ignored (CLAUDE_CODE_OAUTH_TOKEN is set in your environment; Brahma uses only the company key; see brahma billing)")

        let both = Doctor.ambientAuthItem(environment: ["ANTHROPIC_API_KEY": key, "CLAUDE_CODE_OAUTH_TOKEN": "owner-oauth"])
        #expect(both.status == .warn)
        #expect(both.detail == "ignored (ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN are set in your environment; Brahma uses only the company key; see brahma billing)")
    }

    @Test func passesWhenAbsent() {
        let expected = DoctorItem(name: "ambient-claude-auth", status: .pass, detail: "none in the engine's environment")
        #expect(Doctor.ambientAuthItem(environment: [:]) == expected)
        // Other Anthropic names (the gateway's, which only Brahma sets per turn) and empty values are not an ambient login.
        #expect(Doctor.ambientAuthItem(environment: ["PATH": "/bin", "ANTHROPIC_BASE_URL": "https://x", "ANTHROPIC_API_KEY": "",
                                                     "CLAUDE_CONFIG_DIR": "/c"]) == expected)
    }
}
