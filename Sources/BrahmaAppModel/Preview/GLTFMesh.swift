import Foundation

/// Why a glTF asset is not shown.
public enum GLTFError: Error, Equatable, Sendable {
    /// The document contradicts itself or its buffers (an accessor past its bufferView, an index past the vertices).
    case invalid(String)
    /// Well-formed but outside what the viewer renders (non-triangle modes, sparse accessors, non-float positions,
    /// buffer URIs that are not a bare sibling name or `data:` base64).
    case unsupported(String)
    /// Over a cap: the file (`RendererCaps.maxInProcessModelBytes`), `maxVertices`, `maxIndices`, `maxPrimitives` or
    /// `maxBufferBytes`.
    case tooLarge
}

/// The triangles of a glTF 2.0 asset (`.gltf` JSON or `.glb`), flattened for one `SCNGeometry` (Plan 4a Task 8a).
///
/// **Node transforms are ignored** (an accepted MVP limitation; 9a/9b's UI says "geometry preview, no transforms"): every
/// triangle primitive (mode 4) of every mesh is concatenated in its own coordinates, so a multi-part model positioned by
/// its nodes shows its parts at the origin. Positions and normals are VEC3 float; indices are u8, u16 or u32, re-based
/// onto the concatenated vertices.
///
/// The file is hostile input. Every count, offset and stride is parsed as a non-negative `Int` (never a boolean),
/// combined with overflow-reporting arithmetic, and checked against the bufferView (`byteOffset + (count − 1) × stride +
/// elementSize ≤ byteLength`, glTF 2.0's rule), then the bufferView against its buffer, then the buffer against its bytes,
/// before one byte is read; every index is checked against its primitive's vertex count. The caps bound what is held, not
/// what is declared: `maxBufferBytes` counts the bytes actually loaded (a sibling file is read once however many buffers
/// name it, its size is checked on the open descriptor against the declared `byteLength` before any read, and only
/// `byteLength` bytes are kept); `maxVertices` and `maxIndices` bound the totals across primitives; `maxPrimitives` bounds
/// the walk. Buffer URIs are a bare sibling file name (no path, no scheme, no hidden file, read without following a link)
/// or `data:…;base64,…`.
public struct GLTFMesh: Equatable, Sendable {
    public var positions: [Float]
    public var normals: [Float]?
    public var indices: [UInt32]

    public static let maxVertices = 2_000_000
    /// Three per vertex at the vertex cap: the most indices held across all primitives.
    public static let maxIndices = 3 * maxVertices
    /// The most primitives walked (triangle or not).
    public static let maxPrimitives = 65_536
    public static let maxBufferBytes = 67_108_864

    public init(positions: [Float], normals: [Float]?, indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    public static func load(_ url: URL) throws -> GLTFMesh {
        let data = try read(url, maxBytes: RendererCaps.maxInProcessModelBytes, what: url.lastPathComponent)
        let (json, bin) = try unwrap(data)
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw GLTFError.invalid("not a glTF document")
        }
        guard let asset = root["asset"] as? [String: Any], let version = asset["version"] as? String else {
            throw GLTFError.invalid("no asset version")
        }
        guard version.hasPrefix("2.") else { throw GLTFError.unsupported("glTF \(version)") }
        var document = Document(root: root, bin: bin, directory: url.deletingLastPathComponent())
        return try document.triangles()
    }

    // MARK: Container

    /// The JSON document and, for a .glb, its BIN chunk.
    static func unwrap(_ data: Data) throws -> (json: Data, bin: Data?) {
        let magic: UInt32 = 0x4654_6C67, jsonChunk: UInt32 = 0x4E4F_534A, binChunk: UInt32 = 0x004E_4942
        guard data.count >= 12, data.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) == magic else {
            return (data, nil)
        }
        let (version, length) = data.withUnsafeBytes { raw in
            (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        }
        guard version == 2 else { throw GLTFError.unsupported("glb version \(version)") }
        let total = min(Int(length), data.count)
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= total {
            let (chunkLength, chunkType) = data.withUnsafeBytes { raw in
                (Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))),
                 UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
            }
            offset += 8
            guard chunkLength <= total - offset else { throw GLTFError.invalid("glb chunk past the end of the file") }
            let chunk = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + chunkLength)
            if json == nil {
                guard chunkType == jsonChunk else { throw GLTFError.invalid("glb without a JSON chunk first") }
                json = chunk
            } else if chunkType == binChunk, bin == nil {
                bin = chunk
            }
            offset += chunkLength
        }
        guard let json else { throw GLTFError.invalid("glb without a JSON chunk") }
        return (json, bin)
    }

    // MARK: Files

    /// `url` as a regular file of at most `maxBytes` (checked on the open descriptor before reading); over it → `tooLarge`.
    static func read(_ url: URL, maxBytes: Int, what: String) throws -> Data {
        do {
            return try RendererCaps.readRegularFile(url, maxBytes: maxBytes)
        } catch RendererCaps.FileReadFailure.tooLarge {
            throw GLTFError.tooLarge
        } catch RendererCaps.FileReadFailure.notRegular {
            throw GLTFError.invalid("\(what) is not a regular file")
        } catch {
            throw GLTFError.invalid("\(what) could not be read")
        }
    }

    /// The sibling file name a buffer `uri` names, or nil when it is anything else (a path, a scheme, a hidden file, a
    /// control character, or too long). Percent-encoding is decoded first so `%2F` cannot smuggle a separator.
    static func siblingName(_ uri: String) -> String? {
        guard let name = uri.removingPercentEncoding, !name.isEmpty, name.utf8.count <= 255,
              name != ".", name != "..", !name.hasPrefix("."),
              !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true })
        else { return nil }
        return name
    }

    // MARK: Document

    struct Document {
        let root: [String: Any]
        let bin: Data?
        let directory: URL
        /// Buffer index → its `byteLength` bytes (a prefix of the loaded data).
        var buffers: [Int: Data] = [:]
        /// Sibling file name → the bytes read, once per file however many buffers name it.
        var siblings: [String: Data] = [:]
        /// Bytes actually held, bounded by `GLTFMesh.maxBufferBytes`.
        var loadedBytes = 0

        init(root: [String: Any], bin: Data?, directory: URL) {
            self.root = root
            self.bin = bin
            self.directory = directory
        }

        func array(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }

        /// A non-negative integer field (absent → `default`); anything else (negative, fractional, huge, a string, a
        /// boolean) is invalid.
        static func int(_ dict: [String: Any], _ key: String, default value: Int? = nil, in what: String) throws -> Int {
            guard let raw = dict[key] else {
                if let value { return value }
                throw GLTFError.invalid("\(what) has no \(key)")
            }
            guard !isBoolean(raw), let n = raw as? Int, n >= 0 else { throw GLTFError.invalid("\(what) has a bad \(key)") }
            return n
        }

        /// JSON `true`/`false` arrive as `NSNumber`s that bridge to `Int` 1/0; they are told apart by their CF type.
        static func isBoolean(_ raw: Any) -> Bool {
            guard let number = raw as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        static func times(_ a: Int, _ b: Int, in what: String) throws -> Int {
            let (v, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw GLTFError.invalid("\(what) overflows") }
            return v
        }

        static func plus(_ a: Int, _ b: Int, in what: String) throws -> Int {
            let (v, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw GLTFError.invalid("\(what) overflows") }
            return v
        }

        // MARK: Buffers and views

        /// Counts `count` bytes now held against the cap.
        mutating func hold(_ count: Int) throws {
            guard count <= GLTFMesh.maxBufferBytes - loadedBytes else { throw GLTFError.tooLarge }
            loadedBytes += count
        }

        /// The `byteLength` bytes of buffer `index`, loaded once. The declared length is checked against the remaining
        /// budget before anything is read, the bytes actually loaded are counted, and a sibling file is read at most once
        /// and only when its size (on the open descriptor) is exactly what the buffer declares.
        mutating func buffer(_ index: Int) throws -> Data {
            if let data = buffers[index] { return data }
            let all = array("buffers")
            guard all.indices.contains(index) else { throw GLTFError.invalid("buffer \(index) does not exist") }
            let what = "buffer \(index)"
            let byteLength = try Self.int(all[index], "byteLength", in: what)
            guard byteLength <= GLTFMesh.maxBufferBytes - loadedBytes else { throw GLTFError.tooLarge }
            var data: Data
            if let uri = all[index]["uri"] as? String {
                if uri.hasPrefix("data:") {
                    guard let marker = uri.range(of: ";base64,"),
                          let decoded = Data(base64Encoded: String(uri[marker.upperBound...])) else {
                        throw GLTFError.unsupported("\(what) data URI must be base64")
                    }
                    data = decoded
                    try hold(data.count)
                } else {
                    guard let name = GLTFMesh.siblingName(uri) else {
                        throw GLTFError.unsupported("\(what) uri must be a sibling file name or a data URI")
                    }
                    if let cached = siblings[name] {
                        data = cached
                    } else {
                        do {
                            data = try RendererCaps.readRegularFile(directory.appending(path: name), maxBytes: byteLength)
                        } catch RendererCaps.FileReadFailure.tooLarge {
                            throw GLTFError.invalid("buffer \(name) is larger than its byteLength")
                        } catch RendererCaps.FileReadFailure.notRegular {
                            throw GLTFError.invalid("buffer \(name) is not a regular file")
                        } catch {
                            throw GLTFError.invalid("buffer \(name) could not be read")
                        }
                        try hold(data.count)
                        siblings[name] = data
                    }
                }
            } else {
                guard index == 0, let bin else { throw GLTFError.invalid("\(what) has no uri and no glb BIN chunk") }
                data = bin
                try hold(data.count)
            }
            guard data.count >= byteLength else { throw GLTFError.invalid("\(what) is shorter than its byteLength") }
            data = data.prefix(byteLength)
            buffers[index] = data
            return data
        }

        struct View {
            var buffer: Int
            var byteOffset: Int
            var byteLength: Int
            var byteStride: Int?
        }

        /// bufferView `index`, checked against its buffer's declared length.
        mutating func view(_ index: Int) throws -> View {
            let all = array("bufferViews")
            guard all.indices.contains(index) else { throw GLTFError.invalid("bufferView \(index) does not exist") }
            let what = "bufferView \(index)"
            let dict = all[index]
            let view = View(buffer: try Self.int(dict, "buffer", in: what),
                            byteOffset: try Self.int(dict, "byteOffset", default: 0, in: what),
                            byteLength: try Self.int(dict, "byteLength", in: what),
                            byteStride: dict["byteStride"] == nil ? nil : try Self.int(dict, "byteStride", in: what))
            if let stride = view.byteStride, !(4...252).contains(stride) || stride % 4 != 0 {
                throw GLTFError.invalid("\(what) has a bad byteStride")
            }
            let buffers = array("buffers")
            guard buffers.indices.contains(view.buffer) else { throw GLTFError.invalid("\(what) names a missing buffer") }
            let bufferLength = try Self.int(buffers[view.buffer], "byteLength", in: "buffer \(view.buffer)")
            guard try Self.plus(view.byteOffset, view.byteLength, in: what) <= bufferLength else {
                throw GLTFError.invalid("\(what) overruns its buffer")
            }
            return view
        }

        // MARK: Accessors

        struct Accessor {
            var index: Int
            var view: View
            var byteOffset: Int
            var componentType: Int
            var count: Int
            var type: String
            /// Where the first element starts in the buffer's bytes, and the distance between elements.
            var base: Int
            var stride: Int
            var elementSize: Int
        }

        static let componentSizes = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4]
        static let componentCounts = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]

        /// Accessor `index`, with glTF 2.0's `byteOffset + (count − 1) × stride + elementSize ≤ byteLength` checked against
        /// its bufferView with overflow-reporting arithmetic (interleaved views pass; one element past the view does not).
        /// `maxCount` is checked first, so a count past it is `tooLarge`, not an overrun.
        mutating func accessor(_ index: Int, maxCount: Int) throws -> Accessor {
            let all = array("accessors")
            guard all.indices.contains(index) else { throw GLTFError.invalid("accessor \(index) does not exist") }
            let what = "accessor \(index)"
            let dict = all[index]
            guard dict["sparse"] == nil else { throw GLTFError.unsupported("sparse accessors") }
            guard dict["bufferView"] != nil else { throw GLTFError.unsupported("accessors without a bufferView") }
            let count = try Self.int(dict, "count", in: what)
            guard count <= maxCount else { throw GLTFError.tooLarge }
            guard count > 0 else { throw GLTFError.invalid("\(what) is empty") }
            let componentType = try Self.int(dict, "componentType", in: what)
            guard let type = dict["type"] as? String, let components = Self.componentCounts[type],
                  let componentSize = Self.componentSizes[componentType] else {
                throw GLTFError.invalid("\(what) has a bad type")
            }
            let view = try self.view(try Self.int(dict, "bufferView", in: what))
            let byteOffset = try Self.int(dict, "byteOffset", default: 0, in: what)
            let elementSize = components * componentSize
            let stride = view.byteStride ?? elementSize
            guard stride >= elementSize else { throw GLTFError.invalid("\(what) is wider than its bufferView stride") }
            let span = try Self.plus(try Self.times(count - 1, stride, in: what), elementSize, in: what)
            guard try Self.plus(byteOffset, span, in: what) <= view.byteLength else {
                throw GLTFError.invalid("\(what) overruns its bufferView")
            }
            return Accessor(index: index, view: view, byteOffset: byteOffset, componentType: componentType, count: count,
                            type: type, base: view.byteOffset + byteOffset, stride: stride, elementSize: elementSize)
        }

        /// `count × 3` little-endian floats of a VEC3 FLOAT accessor.
        mutating func floats(_ a: Accessor) throws -> [Float] {
            guard a.type == "VEC3", a.componentType == 5126 else {
                throw GLTFError.unsupported("accessor \(a.index) must be VEC3 float")
            }
            let data = try buffer(a.view.buffer)
            var out: [Float] = []
            out.reserveCapacity(a.count * 3)
            try data.withUnsafeBytes { raw in
                guard a.base + (a.count - 1) * a.stride + a.elementSize <= raw.count else {
                    throw GLTFError.invalid("accessor \(a.index) overruns its buffer")
                }
                for k in 0..<a.count {
                    if k & 0xFFFF == 0, Task.isCancelled { throw CancellationError() }
                    let at = a.base + k * a.stride
                    for c in 0..<3 {
                        let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at + c * 4, as: UInt32.self))
                        let value = Float(bitPattern: bits)
                        guard value.isFinite else { throw GLTFError.invalid("accessor \(a.index) holds a non-finite value") }
                        out.append(value)
                    }
                }
            }
            return out
        }

        /// The indices of a SCALAR u8/u16/u32 accessor, each `< vertexCount`, re-based by `vertexBase`.
        mutating func indices(_ a: Accessor, vertexCount: Int, vertexBase: Int) throws -> [UInt32] {
            guard a.type == "SCALAR", [5121, 5123, 5125].contains(a.componentType) else {
                throw GLTFError.invalid("accessor \(a.index) is not an index accessor")
            }
            guard a.count % 3 == 0 else { throw GLTFError.invalid("index count \(a.count) is not a multiple of 3") }
            let data = try buffer(a.view.buffer)
            var out: [UInt32] = []
            out.reserveCapacity(a.count)
            try data.withUnsafeBytes { raw in
                guard a.base + (a.count - 1) * a.stride + a.elementSize <= raw.count else {
                    throw GLTFError.invalid("accessor \(a.index) overruns its buffer")
                }
                for k in 0..<a.count {
                    if k & 0xFFFF == 0, Task.isCancelled { throw CancellationError() }
                    let at = a.base + k * a.stride
                    let value: Int
                    switch a.componentType {
                    case 5121: value = Int(raw.load(fromByteOffset: at, as: UInt8.self))
                    case 5123: value = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                    default: value = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    }
                    guard value < vertexCount else {
                        throw GLTFError.invalid("index \(value) is out of range for \(vertexCount) vertices")
                    }
                    out.append(UInt32(vertexBase + value))
                }
            }
            return out
        }

        // MARK: Mesh

        /// Every triangle primitive of every mesh, concatenated (no node transforms). Vertices, indices and primitives are
        /// each bounded in total, so a document sharing one accessor across many primitives stays within the caps.
        mutating func triangles() throws -> GLTFMesh {
            var positions: [Float] = []
            var normals: [Float]? = []
            var indices: [UInt32] = []
            var vertices = 0
            var walked = 0
            var triangles = 0
            for mesh in array("meshes") {
                for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                    if Task.isCancelled { throw CancellationError() }
                    walked += 1
                    guard walked <= GLTFMesh.maxPrimitives else { throw GLTFError.tooLarge }
                    let what = "primitive \(walked - 1)"
                    guard try Self.int(primitive, "mode", default: 4, in: what) == 4 else { continue }
                    guard let attributes = primitive["attributes"] as? [String: Any] else {
                        throw GLTFError.invalid("\(what) has no attributes")
                    }
                    let position = try accessor(try Self.int(attributes, "POSITION", in: what), maxCount: GLTFMesh.maxVertices - vertices)
                    positions += try floats(position)
                    if normals != nil, attributes["NORMAL"] != nil {
                        let normal = try accessor(try Self.int(attributes, "NORMAL", in: what), maxCount: GLTFMesh.maxVertices)
                        guard normal.count == position.count else {
                            throw GLTFError.invalid("\(what) has \(normal.count) normals for \(position.count) vertices")
                        }
                        normals! += try floats(normal)
                    } else {
                        normals = nil
                    }
                    let remainingIndices = GLTFMesh.maxIndices - indices.count
                    if primitive["indices"] != nil {
                        let index = try accessor(try Self.int(primitive, "indices", in: what), maxCount: remainingIndices)
                        indices += try self.indices(index, vertexCount: position.count, vertexBase: vertices)
                    } else {
                        guard position.count <= remainingIndices else { throw GLTFError.tooLarge }
                        guard position.count % 3 == 0 else {
                            throw GLTFError.invalid("\(what) has \(position.count) vertices, not whole triangles")
                        }
                        indices += (vertices ..< vertices + position.count).map { UInt32($0) }
                    }
                    vertices += position.count
                    triangles += 1
                }
            }
            guard triangles > 0 else { throw GLTFError.unsupported("no triangle primitives") }
            return GLTFMesh(positions: positions, normals: normals, indices: indices)
        }
    }
}
