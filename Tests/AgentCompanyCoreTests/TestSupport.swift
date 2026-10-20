import Foundation

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "agentco-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
