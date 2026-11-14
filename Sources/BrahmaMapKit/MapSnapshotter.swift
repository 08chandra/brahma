import AppKit
import CoreGraphics
import ImageIO
import Metal
import SpriteKit
import UniformTypeIdentifiers

/// Renders an `SKScene` offscreen through `SKRenderer` so scene tests can measure pixels without a window, and
/// `scripts/map-snapshots.sh` can save PNGs for a human to look at.
///
/// Pipeline: the scene is stepped `steps` times (`update(atTime:)` advances `SKAction`s) and each step is drawn into
/// a reused private BGRA8 render target; after the last step the target is blitted into a `.shared` buffer
/// (buffers are shareable on every Mac, `.shared` textures are not) and wrapped as a `CGImage`. The pixel format
/// is `bgra8Unorm`, the one `SKView` uses: an `_srgb` format would re-encode SpriteKit's already-sRGB output and
/// brighten every color.
@MainActor
public enum MapSnapshotter {
    /// The render target and readback buffer, reused while the size stays the same.
    private struct Targets {
        let size: (Int, Int)
        let texture: MTLTexture
        let buffer: MTLBuffer
        let bytesPerRow: Int
    }

    private static var device: MTLDevice?
    private static var queue: MTLCommandQueue?
    private static var targets: Targets?

    /// `nil` when there is no Metal device (CI without a GPU) or the size is empty.
    public static func render(scene: SKScene, size: CGSize, steps: Int = 30, dt: TimeInterval = 1 / 60) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        Self.device = device
        guard let queue = queue ?? device.makeCommandQueue() else { return nil }
        Self.queue = queue
        guard let targets = targets(width: width, height: height, device: device) else { return nil }

        // `SKRenderer` treats the viewport as a 2× backing store: a `.resizeFill` scene (what a live `SKView` wants) would be
        // resized to half the size and drawn twice as large. The scene keeps its own size and fills the target 1:1 instead.
        let scaleMode = scene.scaleMode
        scene.scaleMode = .aspectFill
        defer { scene.scaleMode = scaleMode }
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        let viewport = CGRect(x: 0, y: 0, width: width, height: height)
        let clear = clearColor(scene.backgroundColor)

        var time: TimeInterval = 0
        for step in 0..<max(1, steps) {
            time += dt
            renderer.update(atTime: time)
            guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targets.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clear
            renderer.render(withViewport: viewport, commandBuffer: commandBuffer, renderPassDescriptor: pass)
            let last = step == max(1, steps) - 1
            if last, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: targets.texture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: targets.buffer, destinationOffset: 0,
                          destinationBytesPerRow: targets.bytesPerRow,
                          destinationBytesPerImage: targets.bytesPerRow * height)
                blit.endEncoding()
            }
            commandBuffer.commit()
            if last { commandBuffer.waitUntilCompleted() }
        }
        return image(from: targets, width: width, height: height)
    }

    /// PNG bytes of a snapshot.
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The share of pixels whose red, green and blue are each within `tolerance` of the `0xRRGGBB` color. Alpha is
    /// ignored. The image is re-read through a known RGBA8 context, so the answer does not depend on the source's
    /// byte order.
    public static func fraction(_ image: CGImage, near hex: UInt32, tolerance: Int = 24) -> Double {
        guard let pixels = rgba(image) else { return 0 }
        let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
        let total = image.width * image.height
        guard total > 0 else { return 0 }
        var hits = 0
        pixels.withUnsafeBytes { raw in
            var i = 0
            while i + 3 < raw.count {
                if abs(Int(raw[i]) - r) <= tolerance, abs(Int(raw[i + 1]) - g) <= tolerance, abs(Int(raw[i + 2]) - b) <= tolerance {
                    hits += 1
                }
                i += 4
            }
        }
        return Double(hits) / Double(total)
    }

    /// Writes `$BRAHMA_MAP_SNAPSHOT_DIR/<name>.png` when that variable is set; a no-op otherwise.
    public static func writeIfRequested(_ image: CGImage, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["BRAHMA_MAP_SNAPSHOT_DIR"], !dir.isEmpty,
              let data = png(image) else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("map snapshot \(name) not written: \(error)\n".utf8))
        }
    }

    // MARK: - Internals

    private static func targets(width: Int, height: Int, device: MTLDevice) -> Targets? {
        if let t = targets, t.size == (width, height) { return t }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else { return nil }
        let t = Targets(size: (width, height), texture: texture, buffer: buffer, bytesPerRow: bytesPerRow)
        targets = t
        return t
    }

    private static func clearColor(_ color: NSColor) -> MTLClearColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                             alpha: Double(c.alphaComponent))
    }

    /// Wraps the BGRA8 readback as a `CGImage`: 32-bit little-endian ARGB words are B, G, R, A bytes in memory.
    private static func image(from targets: Targets, width: Int, height: Int) -> CGImage? {
        let data = Data(bytes: targets.buffer.contents(), count: targets.bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: targets.bytesPerRow,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// The image's pixels as R, G, B, A bytes, top row first.
    static func rgba(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }
}
