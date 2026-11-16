import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Final-review I-1, in the app: a file dragged in from a company workspace or the data home shows the EXTERNAL chip (the
/// owner vouches explicitly), an ordinary file shows FROM YOU, and a pasted image (written by the app under the data home's
/// tmp folder) stays FROM YOU (`ResourceDropModelTests.pasteImageWritesPNGToHomeTmp`).
@MainActor @Suite(.scratch) struct ResourceDropAgentAreaTests {
    typealias W = ResourceDropModelTests.W

    private func write(_ text: String, _ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func workspaceAndHomeFilesShowExternalChip() async throws {
        let w = try await W()
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        let m = w.model(.library)
        await m.add(urls: [try write("# eng's design\n", ws.appending(path: "docs/design.md"))])
        await m.add(urls: [try write("notes\n", w.paths.home.appending(path: "exports/notes.md"))])
        await m.add(urls: [try w.file("mine.md", "# mine\n")])
        #expect(m.pending.map(\.name) == ["design.md", "notes.md", "mine.md"])
        #expect(m.pending[0].chip == .external(reason: DropTrust.agentAreaReason))
        #expect(m.pending[1].chip == .external(reason: DropTrust.agentAreaReason))
        #expect(m.pending[2].chip == .fromYou)

        // Sent as detected, it is stored tainted and never mirrored; the owner's explicit vouch clears it.
        let first = m.pending[0].id
        m.remove(m.pending[2].id); m.remove(m.pending[1].id)
        #expect(m.pending.map(\.id) == [first])
        w.ackAdvisory()
        #expect(await m.commit(message: ""))
        let row = try #require(try w.rows().first)
        #expect(row.tainted); #expect(row.mirrorPath == nil); #expect(row.taintReason == DropTrust.agentAreaReason)
        await m.add(urls: [ws.appending(path: "docs/design.md")])
        let id = try #require(m.pending.first?.id)
        m.setTrust(id, .vouched)
        #expect(m.pending[0].chip == .fromYou)
        #expect(await m.commit(message: ""))
        #expect(try w.rows().last?.tainted == false)
    }
}
