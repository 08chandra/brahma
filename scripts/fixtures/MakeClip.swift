// The Swift fallback of make-clip.sh (Plan 4a Task 9b): a 2 s 1080×1920 H.264 MP4 of solid frames at 1 fps, written with
// AVAssetWriter. Usage: swift MakeClip.swift <out.mp4>. The color is the theme's bg2 (0x1A2129).
import AVFoundation
import CoreVideo
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "clip-9x16.mp4")
let width = 1080, height = 1920, seconds = 2, fps: Int32 = 1
try? FileManager.default.removeItem(at: out)

let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else { fatalError("startWriting: \(writer.error.map { "\($0)" } ?? "unknown")") }
writer.startSession(atSourceTime: .zero)

guard let pool = adaptor.pixelBufferPool else { fatalError("no pixel buffer pool") }
for frame in 0..<(seconds * Int(fps)) {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            row[x * 4] = 0x29      // B
            row[x * 4 + 1] = 0x21  // G
            row[x * 4 + 2] = 0x1A  // R
            row[x * 4 + 3] = 0xFF  // A
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
        fatalError("append: \(writer.error.map { "\($0)" } ?? "unknown")")
    }
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("finishWriting: \(writer.error.map { "\($0)" } ?? "unknown")") }
