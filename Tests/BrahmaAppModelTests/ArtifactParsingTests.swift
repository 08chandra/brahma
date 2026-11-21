import Foundation
import Testing
@testable import BrahmaAppModel

/// The bounded parsers behind artifact previews (Plan 4a Task 8a): `RendererCaps`, `CSVTable`, `OpenAPISummary`,
/// `GLTFMesh`, `VideoLayout` and the Simulator frame source. Hostile input is refused or cut, never trapped on.
@MainActor @Suite(.scratch) struct ArtifactParsingTests {
    // MARK: CSV

    @Test func csvQuotesAndCaps() {
        let csv = "name,qty,\"note, with comma\"\r\n\"Widget \"\"A\"\"\",3,\"multi\nline\"\r\nBolt,10,\n"
        let table = CSVTable.parse(csv)
        #expect(table.header == ["name", "qty", "note, with comma"])
        #expect(table.rows == [["Widget \"A\"", "3", "multi\nline"], ["Bolt", "10", ""]])
        #expect(!table.truncated)

        let tsv = CSVTable.parse("a\tb\n1\t2\n", separator: "\t")
        #expect(tsv.header == ["a", "b"] && tsv.rows == [["1", "2"]] && !tsv.truncated)

        let many = CSVTable.parse("h1,h2\n" + (1...3000).map { "\($0),x" }.joined(separator: "\n"))
        #expect(many.rows.count == CSVTable.maxRows)
        #expect(many.rows.last == ["2000", "x"])
        #expect(many.truncated)

        let wideCell = CSVTable.parse("h\n" + String(repeating: "a", count: 5000) + "\nshort")
        #expect(wideCell.rows[0][0].count == CSVTable.maxCellChars)
        #expect(wideCell.rows[1] == ["short"])
        #expect(wideCell.truncated)

        let wideHeader = CSVTable.parse((1...150).map { "c\($0)" }.joined(separator: ",") + "\n" + (1...150).map(String.init).joined(separator: ","))
        #expect(wideHeader.header.count == CSVTable.maxColumns)
        #expect(wideHeader.rows[0].count == CSVTable.maxColumns)
        #expect(wideHeader.truncated)

        // A physical line over 4 KB is cut: the row keeps its structure (later cells empty), and the next line parses.
        let longLine = (1...100).map { _ in String(repeating: "z", count: 60) }.joined(separator: ",")
        let cut = CSVTable.parse("h\n" + longLine + "\nnext")
        #expect(cut.rows[0].count == 100)
        #expect(cut.rows[0][0] == String(repeating: "z", count: 60))
        #expect(cut.rows[0][99] == "")
        #expect(cut.rows[1] == ["next"])
        #expect(cut.truncated)

        // A quoted cell over 4 KB still closes, so the row keeps its shape and the rows after it parse (RFC 4180 kept).
        // The cell beside it sits past the 4 KB cut of the same physical line, so its text is not kept.
        let quoted = CSVTable.parse("h1,h2\n\"" + String(repeating: "x", count: 5000) + "\",b\nr2a,r2b\nr3a,r3b\n")
        #expect(quoted.rows.count == 3)
        #expect(quoted.rows[0].count == 2 && quoted.rows[0][0].count == CSVTable.maxCellChars && quoted.rows[0][1] == "")
        #expect(quoted.rows[1] == ["r2a", "r2b"] && quoted.rows[2] == ["r3a", "r3b"])
        #expect(quoted.truncated)
        // The same with the cell's closing quote escaped inside the cut region, and a newline inside the quotes.
        let tricky = CSVTable.parse("h\n\"" + String(repeating: "y", count: 4500) + "\"\"q\"\"\nz\",after\nnext,row\n")
        #expect(tricky.rows == [[String(repeating: "y", count: CSVTable.maxCellChars), "after"], ["next", "row"]])

        let empty = CSVTable.parse("")
        #expect(empty.header.isEmpty && empty.rows.isEmpty && !empty.truncated)
    }

    // MARK: RendererCaps

    /// Off the main actor: the elapsed time must not include waiting for it behind the other @MainActor suites.
    @Test nonisolated func rendererCaps() async throws {
        let text = String(repeating: "日本語テキスト", count: 477)   // 10 017 bytes of 3-byte scalars
        #expect(text.utf8.count > 10_000)
        let cut = RendererCaps.truncateLine(Substring(text))
        #expect(cut.hasSuffix("…"))
        #expect(cut.utf8.count <= RendererCaps.maxLineBytes + "…".utf8.count)
        #expect(cut.utf8.count > RendererCaps.maxLineBytes - 3)
        #expect(!cut.contains("\u{FFFD}"))
        #expect(text.hasPrefix(String(cut.dropLast())))
        #expect(RendererCaps.truncateLine(Substring("short")) == "short")
        #expect(RendererCaps.truncateLine(Substring(String(repeating: "a", count: RendererCaps.maxLineBytes))).utf8.count == RendererCaps.maxLineBytes)

        #expect(try await RendererCaps.parse { 42 } == 42)

        // The timeout on a manual clock: deterministic whatever the load. The body sleeps until it is cancelled (it would
        // run for 10 s of wall time otherwise); the clock is moved past `parseTimeout` and the caller gets `timedOut`.
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        let clock = ManualClock()
        let running = Gate()
        let waiting = Task.detached { () async throws -> Int in   // scope-escape: awaits parse off the main actor; makes no files
            try await RendererCaps.parse(clock: clock) { () -> Int in
                running.openUp()
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if Task.isCancelled { flag.cancelled = true; return 0 }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return 1
            }
        }
        await running.wait()
        clock.advance(by: RendererCaps.parseTimeout - .milliseconds(1))
        #expect(!flag.cancelled, "short of the timeout nothing fires")
        clock.advance(by: .milliseconds(1))
        await #expect(throws: RendererError.timedOut) { try await waiting.value }
        let settle = SuspendingClock.now + .seconds(10)
        while !flag.cancelled, SuspendingClock.now < settle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(flag.cancelled)
    }

    /// A clock that moves only when told to; `Task.sleep(for:clock:)` on it waits for `advance`.
    final class ManualClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol, Hashable {
            typealias Duration = Swift.Duration
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
        }
        private let lock = NSLock()
        private var current = Instant(offset: .zero)
        private var waiting: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []
        var now: Instant { lock.withLock { current } }
        var minimumResolution: Duration { .zero }
        var sleepers: Int { lock.withLock { waiting.count } }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let due: Bool = lock.withLock {
                    if deadline <= current { return true }
                    waiting.append((deadline, c))
                    return false
                }
                if due { c.resume() }
            }
        }
        func advance(by duration: Duration) {
            let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
                current = current.advanced(by: duration)
                let fired = waiting.filter { $0.deadline <= current }.map(\.continuation)
                waiting.removeAll { $0.deadline <= current }
                return fired
            }
            due.forEach { $0.resume() }
        }
    }

    // MARK: OpenAPI

    static func openAPI(paths: [String: Any], extra: [String: Any] = [:]) -> Data {
        var doc: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Pets", "version": "1"], "paths": paths]
        for (k, v) in extra { doc[k] = v }
        return try! JSONSerialization.data(withJSONObject: doc)
    }

    @Test func openAPIOperations() {
        let data = Self.openAPI(paths: [
            "/pets/{id}": ["get": ["summary": "One pet"], "delete": [:], "parameters": [["name": "id", "in": "path"]]],
            "/pets": ["post": ["summary": "Add a\npet"], "get": ["summary": "List pets", "operationId": "listPets"]],
        ])
        let ops = OpenAPISummary.parse(data)
        #expect(ops == [
            OpenAPIOperation(method: "GET", path: "/pets", summary: "List pets"),
            OpenAPIOperation(method: "POST", path: "/pets", summary: "Add a pet"),
            OpenAPIOperation(method: "GET", path: "/pets/{id}", summary: "One pet"),
            OpenAPIOperation(method: "DELETE", path: "/pets/{id}", summary: nil),
        ])

        var many: [String: Any] = [:]
        for i in 0..<600 { many["/r\(i)"] = ["get": [:]] }
        #expect(OpenAPISummary.parse(Self.openAPI(paths: many))?.count == OpenAPISummary.maxOperations)

        // A path key is agent text too: a newline in it cannot forge a second row.
        let forged = OpenAPISummary.parse(Self.openAPI(paths: ["/pets\nDELETE /admin": ["get": [:]]]))
        #expect(forged == [OpenAPIOperation(method: "GET", path: "/pets DELETE /admin", summary: nil)])

        #expect(OpenAPISummary.parse(Self.openAPI(paths: [:])) == [])
        #expect(OpenAPISummary.parse(Data("openapi: 3.0.0\npaths: {}\n".utf8)) == nil)
        #expect(OpenAPISummary.parse(Data("[1, 2]".utf8)) == nil)
        #expect(OpenAPISummary.parse(Data("{\"openapi\": \"3.0.0\"}".utf8)) == nil)
        #expect(OpenAPISummary.parse(Data("{\"paths\": [\"/a\"]}".utf8)) == nil)
    }

    @Test func openAPITooLargeIsNil() throws {
        let small = Self.openAPI(paths: ["/a": ["get": [:]]])
        let exact = small + Data(repeating: 0x20, count: OpenAPISummary.maxBytes - small.count)
        #expect(exact.count == OpenAPISummary.maxBytes)
        #expect(OpenAPISummary.parse(exact)?.count == 1)
        #expect(OpenAPISummary.parse(exact + Data([0x20])) == nil)

        let dir = try tempDir()
        let okFile = dir.appending(path: "openapi.json")
        try exact.write(to: okFile)
        #expect(OpenAPISummary.load(okFile)?.count == 1)
        let bigFile = dir.appending(path: "big.json")
        try (exact + Data([0x20])).write(to: bigFile)
        #expect(OpenAPISummary.load(bigFile) == nil)
        let link = dir.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: okFile)
        #expect(OpenAPISummary.load(link) == nil)
        #expect(OpenAPISummary.load(dir.appending(path: "missing.json")) == nil)
    }

    // MARK: glTF

    /// A one-triangle glTF asset: positions (3 × VEC3 float), optional normals, u16 indices, in one buffer. `mutate` edits
    /// the JSON before it is written; `uri` replaces the data URI.
    struct Asset {
        var positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        var normals: [Float]? = [0, 0, 1, 0, 0, 1, 0, 0, 1]
        var indices: [UInt16] = [0, 1, 2]

        var buffer: Data {
            var d = Data()
            positions.forEach { d.append(contentsOf: withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init)) }
            (normals ?? []).forEach { d.append(contentsOf: withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init)) }
            indices.forEach { d.append(contentsOf: withUnsafeBytes(of: $0.littleEndian, Array.init)) }
            while d.count % 4 != 0 { d.append(0) }
            return d
        }

        func json(uri: String?) -> [String: Any] {
            let posBytes = positions.count * 4, normBytes = (normals?.count ?? 0) * 4, idxBytes = indices.count * 2
            var views: [[String: Any]] = [["buffer": 0, "byteOffset": 0, "byteLength": posBytes]]
            var accessors: [[String: Any]] = [["bufferView": 0, "componentType": 5126, "count": positions.count / 3, "type": "VEC3"]]
            var attributes: [String: Any] = ["POSITION": 0]
            if normals != nil {
                views.append(["buffer": 0, "byteOffset": posBytes, "byteLength": normBytes])
                accessors.append(["bufferView": views.count - 1, "componentType": 5126, "count": positions.count / 3, "type": "VEC3"])
                attributes["NORMAL"] = accessors.count - 1
            }
            views.append(["buffer": 0, "byteOffset": posBytes + normBytes, "byteLength": idxBytes])
            accessors.append(["bufferView": views.count - 1, "componentType": 5123, "count": indices.count, "type": "SCALAR"])
            var buf: [String: Any] = ["byteLength": buffer.count]
            if let uri { buf["uri"] = uri }
            return [
                "asset": ["version": "2.0"],
                "buffers": [buf], "bufferViews": views, "accessors": accessors,
                "meshes": [["primitives": [["attributes": attributes, "indices": accessors.count - 1, "mode": 4]]]],
                "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
            ]
        }

        func writeGLTF(to dir: URL, name: String = "tri.gltf", uri: String? = nil,
                       mutate: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            var doc = json(uri: uri ?? "data:application/octet-stream;base64," + buffer.base64EncodedString())
            mutate(&doc)
            let url = dir.appending(path: name)
            try JSONSerialization.data(withJSONObject: doc).write(to: url)
            return url
        }

        func writeGLB(to dir: URL, name: String = "tri.glb") throws -> URL {
            var json = try JSONSerialization.data(withJSONObject: self.json(uri: nil))
            while json.count % 4 != 0 { json.append(0x20) }
            let bin = buffer
            var d = Data()
            func u32(_ v: Int) { d.append(contentsOf: withUnsafeBytes(of: UInt32(v).littleEndian, Array.init)) }
            u32(0x4654_6C67); u32(2); u32(12 + 8 + json.count + 8 + bin.count)
            u32(json.count); u32(0x4E4F_534A); d.append(json)
            u32(bin.count); u32(0x004E_4942); d.append(bin)
            let url = dir.appending(path: name)
            try d.write(to: url)
            return url
        }
    }

    static func accessor(_ doc: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
        var accessors = doc["accessors"] as! [[String: Any]]
        edit(&accessors[index])
        doc["accessors"] = accessors
    }

    static func bufferView(_ doc: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
        var views = doc["bufferViews"] as! [[String: Any]]
        edit(&views[index])
        doc["bufferViews"] = views
    }

    static func gltfError(_ url: URL) -> GLTFError? {
        do { _ = try GLTFMesh.load(url); return nil } catch let e as GLTFError { return e } catch { Issue.record("not a GLTFError: \(error)"); return nil }
    }

    @Test func gltfTriangle() throws {
        let dir = try tempDir()
        let asset = Asset()
        for url in [try asset.writeGLTF(to: dir), try asset.writeGLB(to: dir)] {
            let mesh = try GLTFMesh.load(url)
            #expect(mesh.positions == asset.positions, "\(url.lastPathComponent)")
            #expect(mesh.normals == asset.normals, "\(url.lastPathComponent)")
            #expect(mesh.indices == [0, 1, 2], "\(url.lastPathComponent)")
        }
        // A sibling .bin by bare name works; a primitive without normals gives no normals; no indices → sequential.
        var plain = asset
        plain.normals = nil
        try plain.buffer.write(to: dir.appending(path: "tri.bin"))
        let sibling = try plain.writeGLTF(to: dir, name: "sib.gltf", uri: "tri.bin")
        let mesh = try GLTFMesh.load(sibling)
        #expect(mesh.positions == asset.positions && mesh.normals == nil && mesh.indices == [0, 1, 2])
        let unindexed = try plain.writeGLTF(to: dir, name: "noidx.gltf") { doc in
            var meshes = doc["meshes"] as! [[String: Any]]
            var prims = meshes[0]["primitives"] as! [[String: Any]]
            prims[0]["indices"] = nil
            meshes[0]["primitives"] = prims
            doc["meshes"] = meshes
        }
        #expect(try GLTFMesh.load(unindexed).indices == [0, 1, 2])
        // Lines (mode 1) are not shown.
        let lines = try asset.writeGLTF(to: dir, name: "lines.gltf") { doc in
            var meshes = doc["meshes"] as! [[String: Any]]
            var prims = meshes[0]["primitives"] as! [[String: Any]]
            prims[0]["mode"] = 1
            meshes[0]["primitives"] = prims
            doc["meshes"] = meshes
        }
        #expect(Self.gltfError(lines) == .unsupported("no triangle primitives"))
        // Not glTF at all.
        let junk = dir.appending(path: "junk.glb")
        try Data("not a model".utf8).write(to: junk)
        #expect(Self.gltfError(junk) != nil)
    }

    @Test func gltfRefusesPathURIs() throws {
        let dir = try tempDir()
        let asset = Asset()
        try asset.buffer.write(to: dir.appending(path: "tri.bin"))
        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        try asset.buffer.write(to: dir.appending(path: "sub/tri.bin"))
        for uri in ["../tri.bin", "sub/tri.bin", "/etc/passwd", "file:///etc/passwd", "http://example.com/tri.bin",
                    "sub%2Ftri.bin", "..", ".", "", "data:application/octet-stream,notbase64", "tri.bin\u{0}",
                    "C:\\tri.bin", ".hidden.bin"] {
            let url = try asset.writeGLTF(to: dir, name: "u.gltf", uri: uri)
            guard case .unsupported = Self.gltfError(url) else { Issue.record("accepted uri \(uri.debugDescription)"); continue }
        }
        // A sibling that is a symlink is refused too.
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "link.bin"), withDestinationURL: dir.appending(path: "tri.bin"))
        #expect(Self.gltfError(try asset.writeGLTF(to: dir, name: "l.gltf", uri: "link.bin")) == .invalid("buffer link.bin is not a regular file"))
        // A missing sibling is invalid, not a crash.
        #expect(Self.gltfError(try asset.writeGLTF(to: dir, name: "m.gltf", uri: "missing.bin")) != nil)
        // A sibling of the right name still works, so the refusals above are about the name.
        _ = try GLTFMesh.load(try asset.writeGLTF(to: dir, name: "ok.gltf", uri: "tri.bin"))
    }

    @Test func gltfVertexCap() throws {
        let dir = try tempDir()
        let url = try Asset().writeGLTF(to: dir) { doc in
            Self.accessor(&doc, 0) { $0["count"] = GLTFMesh.maxVertices + 1 }
        }
        #expect(Self.gltfError(url) == .tooLarge)
        // Buffers over the cap are refused before they are read.
        let bigBuffer = try Asset().writeGLTF(to: dir, name: "b.gltf") { doc in
            doc["buffers"] = [["byteLength": GLTFMesh.maxBufferBytes + 1, "uri": "tri.bin"]]
        }
        #expect(Self.gltfError(bigBuffer) == .tooLarge)
        // A model file over the in-process cap is refused without being parsed.
        let huge = dir.appending(path: "huge.glb")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let h = try FileHandle(forWritingTo: huge)
        try h.truncate(atOffset: UInt64(RendererCaps.maxInProcessModelBytes + 1))
        try h.close()
        #expect(Self.gltfError(huge) == .tooLarge)
    }

    @Test func gltfIndexOutOfRangeRefused() throws {
        let dir = try tempDir()
        var asset = Asset()
        asset.indices = [0, 1, 7]
        #expect(Self.gltfError(try asset.writeGLTF(to: dir)) == .invalid("index 7 is out of range for 3 vertices"))
        // Index counts that are not whole triangles are refused as well.
        asset.indices = [0, 1, 2, 0]
        #expect(Self.gltfError(try asset.writeGLTF(to: dir)) == .invalid("index count 4 is not a multiple of 3"))
    }

    @Test func gltfAccessorOverrunRefused() throws {
        let dir = try tempDir()
        // count × stride past the bufferView.
        let overCount = try Asset().writeGLTF(to: dir) { doc in Self.accessor(&doc, 0) { $0["count"] = 4 } }
        #expect(Self.gltfError(overCount) == .invalid("accessor 0 overruns its bufferView"))
        // A stride that pushes the last element past the view.
        let overStride = try Asset().writeGLTF(to: dir) { doc in Self.bufferView(&doc, 0) { $0["byteStride"] = 16 } }
        #expect(Self.gltfError(overStride) == .invalid("accessor 0 overruns its bufferView"))
        // An accessor byteOffset inside the view, but the span past it.
        let offset = try Asset().writeGLTF(to: dir) { doc in Self.accessor(&doc, 0) { $0["byteOffset"] = 4 } }
        #expect(Self.gltfError(offset) == .invalid("accessor 0 overruns its bufferView"))
        // A bufferView past its buffer.
        let view = try Asset().writeGLTF(to: dir) { doc in Self.bufferView(&doc, 0) { $0["byteLength"] = 1_000_000 } }
        #expect(Self.gltfError(view) == .invalid("bufferView 0 overruns its buffer"))
        // A buffer declaring more than the data holds.
        let buffer = try Asset().writeGLTF(to: dir) { doc in
            var buffers = doc["buffers"] as! [[String: Any]]
            buffers[0]["byteLength"] = 1_000_000
            doc["buffers"] = buffers
        }
        #expect(Self.gltfError(buffer) == .invalid("buffer 0 is shorter than its byteLength"))
        // The index accessor is checked the same way.
        let indices = try Asset().writeGLTF(to: dir) { doc in Self.accessor(&doc, 2) { $0["count"] = 6 } }
        #expect(Self.gltfError(indices) == .invalid("accessor 2 overruns its bufferView"))
    }

    @Test func gltfOverflowRefused() throws {
        let dir = try tempDir()
        for (label, mutate) in [
            ("count Int.max", { (doc: inout [String: Any]) in Self.accessor(&doc, 0) { $0["count"] = Int.max } }),
            ("index count Int.max", { doc in Self.accessor(&doc, 2) { $0["count"] = Int.max } }),
            ("accessor byteOffset Int.max", { doc in Self.accessor(&doc, 0) { $0["byteOffset"] = Int.max } }),
            ("view byteOffset Int.max", { doc in Self.bufferView(&doc, 0) { $0["byteOffset"] = Int.max } }),
            ("view byteLength Int.max", { doc in Self.bufferView(&doc, 0) { $0["byteLength"] = Int.max } }),
            ("stride Int.max", { doc in Self.bufferView(&doc, 0) { $0["byteStride"] = Int.max } }),
            ("boolean count", { doc in Self.accessor(&doc, 0) { $0["count"] = true } }),
            ("boolean offset", { doc in Self.accessor(&doc, 0) { $0["byteOffset"] = false } }),
            ("negative count", { doc in Self.accessor(&doc, 0) { $0["count"] = -1 } }),
            ("negative offset", { doc in Self.accessor(&doc, 0) { $0["byteOffset"] = -4 } }),
            ("fractional count", { doc in Self.accessor(&doc, 0) { $0["count"] = 2.5 } }),
            ("huge count", { doc in Self.accessor(&doc, 0) { $0["count"] = 1e30 } }),
            ("bad view index", { doc in Self.accessor(&doc, 0) { $0["bufferView"] = 99 } }),
            ("negative view index", { doc in Self.accessor(&doc, 0) { $0["bufferView"] = -1 } }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            let url = try Asset().writeGLTF(to: dir, mutate: mutate)
            #expect(Self.gltfError(url) != nil, "\(label)")
        }
    }

    /// Fix round 1 (M6): the aggregate caps are on what is held, and a FIFO cannot hang the reader.
    @Test func gltfAggregateCapsAndFIFO() throws {
        let dir = try tempDir()
        let asset = Asset()
        let binSize = asset.buffer.count
        try asset.buffer.write(to: dir.appending(path: "tri.bin"))

        // An oversized sibling is refused on its size, before any read.
        try (asset.buffer + Data(repeating: 0, count: 64)).write(to: dir.appending(path: "big.bin"))
        let oversized = try asset.writeGLTF(to: dir, name: "big.gltf", uri: "big.bin")
        #expect(Self.gltfError(oversized) == .invalid("buffer big.bin is larger than its byteLength"))

        // Many buffers on one sibling: the file is read once and counted once.
        var doc = asset.json(uri: "tri.bin")
        doc["buffers"] = (0..<50).map { _ in ["byteLength": binSize, "uri": "tri.bin"] as [String: Any] }
        var document = GLTFMesh.Document(root: doc, bin: nil, directory: dir)
        for i in 0..<50 { #expect(try document.buffer(i).count == binSize) }
        #expect(document.loadedBytes == binSize)
        #expect(document.siblings.count == 1)

        // Total indices are capped across primitives sharing one accessor: 3 × 3 000 000 u8 indices > maxIndices.
        let indexCount = 3_000_000
        let zeros = Data(count: indexCount)
        let shared: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": zeros.count, "uri": "zeros.bin"], ["byteLength": binSize, "uri": "tri.bin"]],
            "bufferViews": [["buffer": 0, "byteLength": zeros.count], ["buffer": 1, "byteOffset": 0, "byteLength": 36]],
            "accessors": [["bufferView": 0, "componentType": 5121, "count": indexCount, "type": "SCALAR"],
                          ["bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"]],
            "meshes": [["primitives": (0..<3).map { _ in ["attributes": ["POSITION": 1], "indices": 0] as [String: Any] }]],
        ]
        try zeros.write(to: dir.appending(path: "zeros.bin"))
        let sharedURL = dir.appending(path: "shared.gltf")
        try JSONSerialization.data(withJSONObject: shared).write(to: sharedURL)
        #expect(Self.gltfError(sharedURL) == .tooLarge)
        // Two of them fit exactly (6 000 000 indices), so the cap is the total, not the primitive.
        var two = shared
        two["meshes"] = [["primitives": (0..<2).map { _ in ["attributes": ["POSITION": 1], "indices": 0] as [String: Any] }]]
        let twoURL = dir.appending(path: "two.gltf")
        try JSONSerialization.data(withJSONObject: two).write(to: twoURL)
        #expect(try GLTFMesh.load(twoURL).indices.count == GLTFMesh.maxIndices)

        // The primitive walk is capped.
        var many = asset.json(uri: "tri.bin")
        many["meshes"] = [["primitives": (0...GLTFMesh.maxPrimitives).map { _ in ["attributes": ["POSITION": 0], "mode": 0] as [String: Any] }]]
        let manyURL = dir.appending(path: "many.gltf")
        try JSONSerialization.data(withJSONObject: many).write(to: manyURL)
        #expect(Self.gltfError(manyURL) == .tooLarge)

        // A FIFO as the model or as a sibling is refused at once instead of blocking the open.
        let fifo = dir.appending(path: "pipe.glb")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let began = SuspendingClock.now
        #expect(Self.gltfError(fifo) == .invalid("pipe.glb is not a regular file"))
        #expect(Self.gltfError(try asset.writeGLTF(to: dir, name: "f.gltf", uri: "pipe.glb")) == .invalid("buffer pipe.glb is not a regular file"))
        #expect(OpenAPISummary.load(fifo) == nil)
        #expect(SuspendingClock.now - began < .seconds(2))
    }

    /// Fix round 1 (I2): glTF 2.0's accessor rule admits the usual interleaved layout.
    @Test func gltfInterleavedStride() throws {
        let dir = try tempDir()
        let asset = Asset()
        // One view, stride 24: position (12 bytes) then normal (12 bytes) per vertex; indices in a second view.
        var buffer = Data()
        for v in 0..<3 {
            for c in 0..<3 { buffer.append(contentsOf: withUnsafeBytes(of: asset.positions[v * 3 + c].bitPattern.littleEndian, Array.init)) }
            for c in 0..<3 { buffer.append(contentsOf: withUnsafeBytes(of: asset.normals![v * 3 + c].bitPattern.littleEndian, Array.init)) }
        }
        asset.indices.forEach { buffer.append(contentsOf: withUnsafeBytes(of: $0.littleEndian, Array.init)) }
        buffer.append(contentsOf: [0, 0])
        let doc: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": buffer.count, "uri": "data:application/octet-stream;base64," + buffer.base64EncodedString()]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 72, "byteStride": 24],
                            ["buffer": 0, "byteOffset": 72, "byteLength": 6]],
            "accessors": [["bufferView": 0, "byteOffset": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
                          ["bufferView": 0, "byteOffset": 12, "componentType": 5126, "count": 3, "type": "VEC3"],
                          ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "indices": 2]]]],
        ]
        let url = dir.appending(path: "interleaved.gltf")
        try JSONSerialization.data(withJSONObject: doc).write(to: url)
        let mesh = try GLTFMesh.load(url)
        #expect(mesh.positions == asset.positions && mesh.normals == asset.normals && mesh.indices == [0, 1, 2])
        // One element past the view (count 4 at stride 24 needs 12 + 3 × 24 + 12 = 96 > 72) is still an overrun.
        var over = doc
        var accessors = over["accessors"] as! [[String: Any]]
        accessors[1]["count"] = 4
        over["accessors"] = accessors
        let overURL = dir.appending(path: "over.gltf")
        try JSONSerialization.data(withJSONObject: over).write(to: overURL)
        #expect(Self.gltfError(overURL) == .invalid("accessor 1 overruns its bufferView"))
    }

    // MARK: Video

    @Test func videoLayout() {
        #expect(VideoLayout.layout(width: 1080, height: 1920, rotationDegrees: 0) == .phone)
        #expect(VideoLayout.layout(width: 1920, height: 1080, rotationDegrees: 0) == .plain)
        #expect(VideoLayout.layout(width: 1920, height: 1080, rotationDegrees: 90) == .phone)
        #expect(VideoLayout.layout(width: 1920, height: 1080, rotationDegrees: -90) == .phone)
        #expect(VideoLayout.layout(width: 1920, height: 1080, rotationDegrees: 270) == .phone)
        #expect(VideoLayout.layout(width: 1080, height: 1920, rotationDegrees: 180) == .phone)
        #expect(VideoLayout.layout(width: 1080, height: 1920, rotationDegrees: 90) == .plain)
        #expect(VideoLayout.layout(width: 1080, height: 1350, rotationDegrees: 0) == .plain)
        #expect(VideoLayout.layout(width: 1080, height: 1800, rotationDegrees: 0) == .phone)   // exactly 0.6
        #expect(VideoLayout.layout(width: 0, height: 0, rotationDegrees: 0) == .plain)
        #expect(VideoLayout.layout(width: 1080, height: .nan, rotationDegrees: 0) == .plain)
    }

    // MARK: Frames

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var calls = 0
        private(set) var frames: [Data] = []
        func enter() { lock.withLock { active += 1; calls += 1; maxActive = max(maxActive, active) } }
        func leave() { lock.withLock { active -= 1 } }
        func frame(_ d: Data) { lock.withLock { frames.append(d) } }
        var frameCount: Int { lock.withLock { frames.count } }
    }

    /// Holds callers until opened; open, it lets everyone through at once.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let passes: Bool = lock.withLock {
                    if open { return true }
                    waiting.append(c)
                    return false
                }
                if passes { c.resume() }
            }
        }
        func openUp() {
            let held = lock.withLock { open = true; let w = waiting; waiting = []; return w }
            held.forEach { $0.resume() }
        }
    }

    /// The loop is sequential, so the property holds whatever the load; the test is driven by a gate, not by timing: the
    /// first capture is held open while the interval passes many times over, and no second capture may start.
    @Test func frameSourceNeverOverlaps() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let counter = Counter()
        let gate = Gate()
        let udid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        let source = SimulatorScreenshotSource(udid: udid, interval: .milliseconds(10)) { argv in
            counter.enter()
            defer { counter.leave() }
            #expect(argv.prefix(5) == ["xcrun", "simctl", "io", udid, "screenshot"])
            await gate.wait()
            try png.write(to: URL(fileURLWithPath: argv[5]))
        }
        // Progress waits are generous: the main actor and the cooperative pool are shared with every other suite.
        func waitUntil(_ done: () -> Bool) async throws {
            let deadline = SuspendingClock.now + .seconds(60)
            while !done(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        source.start { counter.frame($0) }
        try await waitUntil { counter.calls >= 1 }
        try await Task.sleep(for: .milliseconds(200))   // twenty intervals with the first capture still open
        #expect(counter.calls == 1, "a second capture started while the first was running")
        #expect(counter.frameCount == 0)
        gate.openUp()
        try await waitUntil { counter.frameCount >= 3 }
        source.stop()
        let atStop = counter.frameCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.maxActive == 1)
        #expect(counter.calls >= 3)
        #expect(atStop >= 3)
        #expect(counter.frameCount == atStop, "no frame after stop")
        #expect(counter.frames.allSatisfy { $0 == png })

        // A udid that is not a device id never runs the shell.
        let bad = Counter()
        let refused = SimulatorScreenshotSource(udid: "booted; rm -rf /", interval: .milliseconds(10)) { _ in bad.enter(); bad.leave() }
        refused.start { _ in }
        try await Task.sleep(for: .milliseconds(50))
        refused.stop()
        #expect(bad.calls == 0)
    }
}
