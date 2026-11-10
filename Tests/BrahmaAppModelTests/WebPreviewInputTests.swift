import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// The view-level inputs of the embedded preview (Plan L Task 11): the path the owner types and the viewport preset.
/// `LoopbackURL.withPath` itself is covered in PreviewModelTests (PR-18); here only the view entry points.
@MainActor @Suite(.scratch) struct WebPreviewInputTests {
    static let origin = URL(string: "http://127.0.0.1:47100/")!
    static let pathRefusal = "preview paths start with one / and stay on the preview"
    static let viewportRefusal = "viewport is desktop, ipad, iphone or WxH up to 4096"

    @Test(arguments: ["//evil.com/x", "/a//b", "\\x", "/@evil.com", "http://evil.com/", "javascript:alert(1)", "/a%0d%0aSet-Cookie:x",
                      "/a%0A", "/\u{0007}", ""])
    func previewPathCannotLeaveLoopback(path: String) {
        #expect(throws: WorkError.invalid(Self.pathRefusal)) {
            try WebPreviewInput.url(origin: Self.origin, path: path, port: 47100)
        }
    }

    @Test func validPathsStayOnOrigin() throws {
        for path in ["/", "/pricing?plan=a b", "/a/ü"] {
            let url = try WebPreviewInput.url(origin: Self.origin, path: path, port: 47100)
            #expect(url.scheme == "http")
            #expect(url.host == "127.0.0.1")
            #expect(url.port == 47100)
        }
        #expect(try WebPreviewInput.url(origin: Self.origin, path: "/pricing?plan=a b", port: 47100).absoluteString
            == "http://127.0.0.1:47100/pricing?plan=a%20b")
        #expect(try WebPreviewInput.url(origin: Self.origin, path: "/a/ü", port: 47100).absoluteString == "http://127.0.0.1:47100/a/%C3%BC")
        #expect(throws: WorkError.invalid(Self.pathRefusal)) {
            try WebPreviewInput.url(origin: URL(string: "http://127.0.0.1:47101/")!, path: "/", port: 47100)
        }
    }

    @Test func livePathsStayOnTheProductionOrigin() throws {
        let live = URL(string: "https://initech-demo.pages.dev/")!
        let url = try WebPreviewInput.liveURL(origin: live, path: "/pricing?plan=a b")
        #expect(url.absoluteString == "https://initech-demo.pages.dev/pricing?plan=a%20b")
        #expect(try WebPreviewInput.liveURL(origin: live, path: "/").absoluteString == "https://initech-demo.pages.dev/")
        #expect(throws: WorkError.invalid(Self.pathRefusal)) { try WebPreviewInput.liveURL(origin: live, path: "//evil.com/x") }
        #expect(throws: WorkError.invalid(Self.pathRefusal)) { try WebPreviewInput.liveURL(origin: live, path: "") }
    }

    @Test func viewportPresets() throws {
        #expect(try PreviewViewport.parse("desktop") == .desktop)
        #expect(try PreviewViewport.parse("ipad") == .ipad)
        #expect(try PreviewViewport.parse("iphone") == .iphone)
        #expect(PreviewViewport.ipad.size.map { [$0.width, $0.height] } == [820, 1180])
        #expect(PreviewViewport.iphone.size.map { [$0.width, $0.height] } == [390, 844])
        #expect(PreviewViewport.desktop.size == nil)
        #expect(try PreviewViewport.parse("1280x800") == .custom(width: 1280, height: 800))
        #expect(try PreviewViewport.parse(" IPAD ") == .ipad)
        for bad in ["5000x800", "100x100", "big", "800x", "x800", "-1x900", ""] {
            #expect(throws: WorkError.invalid(Self.viewportRefusal), "\(bad)") { try PreviewViewport.parse(bad) }
        }
        #expect(PreviewViewport.desktop.title == "DESKTOP")
        #expect(PreviewViewport.ipad.title == "IPAD 820×1180")
        #expect(PreviewViewport.iphone.title == "IPHONE 390×844")
        #expect(PreviewViewport.custom(width: 1280, height: 800).title == "CUSTOM 1280×800")
    }

    @Test func viewportRoundTripsThroughJSON() throws {
        for v in [PreviewViewport.desktop, .ipad, .iphone, .custom(width: 1280, height: 800)] {
            let data = try JSONEncoder().encode(v)
            #expect(try JSONDecoder().decode(PreviewViewport.self, from: data) == v)
        }
    }
}
