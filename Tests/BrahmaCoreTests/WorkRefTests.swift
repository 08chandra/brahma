import Testing
import Foundation
@testable import BrahmaCore

/// Plan C Task C1b: the `WorkRef` text grammar (design §1.2), its hidden-character and bounds refusals, and its agreement
/// with ML's `MemoryRefs`.
@Suite(.scratch) struct WorkRefTests {
    let ctx = RefContext(companyId: "C", keyPrefixes: ["ENG"])

    @Test(arguments: ["ENG-142", "ENG-142:diff", "ENG-142:diff/src/a.ts", "ENG-142:diff@worktree", "ENG-142:src/checkout.tsx:40-88",
      "ENG-142:src/checkout.tsx@worktree", "src/checkout.tsx:40-88", "src/checkout.tsx@a1b2c3d", "commit:a1b2c3d", "AR-3", "F-12", "A-31",
      "kb:Engineering/Auth#Sessions", "mem:88", "preview:web/checkout@iphone", "preview:web@1280x800", "run:551", "ENG-142:run", "rel:4", "sprint:3",
      "msg:m-9", "thread:m-9", "@cto", "#eng"])
    func canonicalRoundTrips(_ s: String) throws {
        let r = try #require(WorkRef.parse(s, context: ctx))
        #expect(r.canonical == s)
        #expect(WorkRef.parse(r.canonical, context: ctx) == r)
    }

    @Test(arguments: ["ENG\u{2011}142", "ENG-142\u{202E}", "src/a\u{200B}.ts", "src/a.ts\u{7}"])
    func hiddenCharactersRejected(_ s: String) {
        #expect(WorkRef.parse(s, context: ctx) == nil)
    }

    @Test func nfcNormalized() throws {
        let r = try #require(WorkRef.parse("docs/cafe\u{301}.md", context: ctx))
        #expect(r.kind == .file)
        #expect(r.canonical == "docs/caf\u{E9}.md")
        #expect(r.canonical.unicodeScalars.count == "docs/caf\u{E9}.md".unicodeScalars.count)
        #expect(RefText.normalize("cafe\u{301}") == "caf\u{E9}")
        #expect(RefText.normalize("a\nb\tc") == "a\nb\tc")
        #expect(RefText.normalize("a\u{85}") == nil)
        #expect(RefText.normalize("a\u{2066}") == nil)
        #expect(RefText.normalize("a\u{FEFF}") == nil)
    }

    @Test(arguments: ["src/a.ts:40-30", "src/a.ts:1-2002", "src/a.ts@main", "preview:web//evil.com", "preview:web/a@5000x800", "preview:web/a%0d%0a"])
    func boundsRefused(_ s: String) {
        #expect(WorkRef.parse(s, context: ctx) == nil)
    }

    @Test func rangeBounds() throws {
        let r = try #require(WorkRef.parse("src/a.ts:1-2000", context: ctx))
        #expect(r.range == LineRange(start: 1, end: 2000))
        #expect(WorkRef.parse("src/a.ts:0-3", context: ctx) == nil)
        #expect(WorkRef.parse("src/a.ts:7", context: ctx)?.range == LineRange(start: 7, end: 7))
        #expect(WorkRef.parse("src/a.ts@A1B2C3D", context: ctx) == nil)                     // revs are lowercase hex only
        #expect(WorkRef.parse("src/a.ts@a1b2c3", context: ctx) == nil)                      // 6 digits
        #expect(WorkRef.parse("commit:main", context: ctx) == nil)
        #expect(WorkRef.parse("../etc/passwd", context: ctx) == nil)
        #expect(WorkRef.parse("/etc/passwd", context: ctx) == nil)
        #expect(WorkRef.parse("src/a.ts@worktree", context: ctx) == nil)                    // @worktree needs an item
        #expect(WorkRef.parse("BAD-1", context: ctx) == nil)                                // not a company key prefix
    }

    @Test func factRefIsInternalOnly() throws {
        #expect(WorkRef.parse("fact:what's blocked", context: ctx) == nil)
        var internalCtx = ctx
        internalCtx.allowInternal = true
        let r = try #require(WorkRef.parse("fact:what's blocked", context: internalCtx))
        #expect(r.kind == .fact)
        #expect(r.id == "what's blocked")
        #expect(r.canonical == "fact:what's blocked")
        // The scanner never chips one, even in a context that allows them.
        #expect(RefScanner.scan("see fact:blocked", context: internalCtx).isEmpty)
        #expect(RefScanner.scan("see fact:blocked", context: ctx).isEmpty)
    }

    @Test func colonDiffUsesCurrentItem() throws {
        var c = ctx
        c.currentItemKey = "ENG-7"
        let r = try #require(WorkRef.parse(":diff", context: c))
        #expect(r.kind == .diff)
        #expect(r.id == "ENG-7")
        #expect(r.canonical == "ENG-7:diff")
        #expect(WorkRef.parse(":diff", context: ctx) == nil)                                // no current item
    }

    @Test func askAliasParsesToAsk() throws {
        let alias = try #require(WorkRef.parse("ask:31", context: ctx))
        #expect(alias.kind == .ask)
        #expect(alias.id == "31")
        #expect(alias.canonical == "A-31")
        #expect(WorkRef.parse("A-31", context: ctx) == alias)
        let artifact = try #require(WorkRef.parse("AR-3", context: ctx))
        #expect(artifact.kind == .artifact)
        #expect(artifact.id == "3")
    }

    @Test(arguments: ["A", "AR", "F"]) func reservedKeyPrefixesRefused(_ p: String) {
        #expect(throws: PackError.invalid(pack: "software", reason: "key prefixes A, AR and F are reserved")) {
            try IndustryPack.validateKeyPrefix(p, pack: "software")
        }
        #expect(throws: Never.self) { try IndustryPack.validateKeyPrefix("ENG", pack: "software") }
    }

    @Test func grammarAgreesWithMemoryRefs() throws {
        func source(_ kind: WorkRefKind) -> MemorySource? {
            switch kind {
            case .item: .item
            case .ask: .ask
            case .artifact: MemoryRefs.artifactSource
            case .resource: .resource
            case .memory: .memory
            case .kb: .kb
            case .message: .message
            case .sprint: .retro
            default: nil
            }
        }
        let forms = ["ENG-142", "ENG-142:diff", "ENG-142:diff/src/a.ts", "ENG-142:diff@worktree", "ENG-142:src/checkout.tsx:40-88",
                     "ENG-142:src/checkout.tsx@worktree", "src/checkout.tsx:40-88", "src/checkout.tsx@a1b2c3d", "commit:a1b2c3d", "AR-3",
                     "F-12", "A-31", "kb:Engineering/Auth#Sessions", "mem:88", "preview:web/checkout@iphone", "preview:web@1280x800",
                     "run:551", "ENG-142:run", "rel:4", "sprint:3", "msg:m-9", "thread:m-9", "@cto", "#eng", "ask:31", "item:ENG-142"]
        for form in forms {
            let ref = try #require(WorkRef.parse(form, context: ctx))
            let implied = MemoryRefs.implied(form)
            guard let memorySource = implied.source else { continue }
            #expect(source(ref.kind) == memorySource, "\(form)")
            #expect(ref.canonical == implied.canonical, "\(form)")
        }
        func kind(_ s: String) -> WorkRefKind? { WorkRef.parse(s, context: ctx)?.kind }
        #expect(kind("A-31") == .ask && MemoryRefs.implied("A-31").source == .ask)
        #expect(kind("ask:31") == .ask && MemoryRefs.implied("ask:31").canonical == "A-31")
        #expect(kind("AR-3") == .artifact && MemoryRefs.implied("AR-3").source == MemoryRefs.artifactSource)
        #expect(kind("F-12") == .resource && MemoryRefs.implied("F-12").source == .resource)
        #expect(kind("mem:88") == .memory && MemoryRefs.implied("mem:88").source == .memory)
        #expect(kind("kb:Engineering/Auth#Sessions") == .kb && MemoryRefs.implied("kb:Engineering/Auth#Sessions").source == .kb)
        #expect(kind("msg:m-9") == .message && MemoryRefs.implied("msg:m-9").source == .message)
        #expect(kind("ENG-142") == .item && MemoryRefs.implied("ENG-142").source == .item)
        #expect(kind("item:ENG-142") == .item && MemoryRefs.implied("item:ENG-142").source == .item)
        #expect(WorkRef.parse("item:ENG-142", context: ctx)?.canonical == "ENG-142")
        // A company whose prefix collides with a bare form cites its items as `item:<KEY>`, as ML does.
        let f = RefContext(companyId: "C", keyPrefixes: ["F"])
        #expect(WorkRef.parse("F-1", context: f)?.kind == .resource)
        let item = try #require(WorkRef.parse("item:F-1", context: f))
        #expect(item.kind == .item && item.canonical == "item:F-1" && item.canonical == MemoryRefs.implied("item:F-1").canonical)
    }

    @Test func labelDerivation() {
        #expect(RefAccessLabel.label(access: .agent("cto"), sensitivity: .normal, restrictions: [], readerSet: ["cto"]) == .privateToAgent)
        #expect(RefAccessLabel.label(access: .agent("eng-1"), sensitivity: .normal, restrictions: [], readerSet: ["eng-1", "cto"]) == .agent)
        #expect(RefAccessLabel.label(access: .company, sensitivity: .restricted, restrictions: [["@executive"]], readerSet: nil) == .restricted)
        #expect(RefAccessLabel.label(access: .company, sensitivity: .normal, restrictions: [["cto"]], readerSet: nil) == .restricted)
        #expect(RefAccessLabel.label(access: .role("cto"), sensitivity: .normal, restrictions: [], readerSet: nil) == .restricted)
        #expect(RefAccessLabel.label(access: .ownerOnly, sensitivity: .normal, restrictions: [], readerSet: nil) == .owner)
        #expect(RefAccessLabel.label(access: .company, sensitivity: .hrPerf, restrictions: [], readerSet: nil) == .hrPerf)
        #expect(RefAccessLabel.label(access: .company, sensitivity: .secret, restrictions: [], readerSet: nil) == .secret)
        #expect(RefAccessLabel.label(access: .company, sensitivity: .normal, restrictions: [], readerSet: nil) == .company)
        #expect(RefAccessLabel.label(access: .channel("c"), sensitivity: .normal, restrictions: [], readerSet: nil) == .channel)
        #expect(RefAccessLabel.label(access: .dm("d"), sensitivity: .normal, restrictions: [], readerSet: nil) == .dm)
        #expect(RefAccessLabel.label(access: .team("t"), sensitivity: .normal, restrictions: [], readerSet: nil) == .team)
        #expect(RefAccessLabel.label(access: .item("i"), sensitivity: .normal, restrictions: [], readerSet: nil) == .item)
    }

    @Test func safeTitle() {
        let bidi = SafeTitle.make("Pay\u{202E}lacoL")
        #expect(bidi.text == "PaylacoL")
        #expect(!bidi.confusable)
        #expect(SafeTitle.make("\u{0420}ay").confusable)                                  // Cyrillic Er + Latin
        #expect(SafeTitle.make("\u{03B1}lpha").confusable)                                // Greek alpha + Latin
        #expect(!SafeTitle.make("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}").confusable)  // Cyrillic only
        let long = SafeTitle.make(String(repeating: "x", count: 300))
        #expect(long.text.count == SafeTitle.max)
        #expect(long.text.hasSuffix("\u{2026}"))
        #expect(SafeTitle.make("  a \n\t b\u{200B}c\u{7}  ").text == "a bc")
        #expect(SafeTitle.make("cafe\u{301}").text == "caf\u{E9}")
    }
}
