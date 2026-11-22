import Testing
import Foundation
@testable import BrahmaCore

/// Plan C Task C4c: cited answers, checked by plain code.
@Suite(.scratch) struct CitationTests {
    @Test(arguments: [
        ("Checkout waits on the cart API [1]. The last run failed [2].", 2, true),
        ("Checkout waits on the cart API [1]. The last run failed.", 2, false),
        ("Checkout waits on the cart API [3].", 2, false),
        ("Yes [1].", 1, true),                       // < 3 words: not a claim, nothing uncited
        ("It is the cart API.", 0, false),
        ("Line one cites [1]\nline two does not cite", 1, false)])
    func citationRules(_ note: String, _ n: Int, _ ok: Bool) { #expect(CitationCheck.verify(note: note, refCount: n).verified == ok) }

    @Test func claimsCarryTheirMarkers() {
        let r = CitationCheck.verify(note: "Checkout waits on the cart API [1]. The last run failed on a timeout [2][1]. Ok [2].", refCount: 2)
        #expect(r.verified)
        #expect(r.claims.map(\.cites) == [[1], [2, 1]])
        #expect(r.uncited.isEmpty)
        let bad = CitationCheck.verify(note: "The cart API is slow. It times out at night [1]!", refCount: 1)
        #expect(!bad.verified)
        #expect(bad.uncited == ["The cart API is slow."])
        // A decimal point is no sentence end; a marker out of range anywhere unverifies, even in a short sentence.
        #expect(CitationCheck.verify(note: "Latency went from 2.5 s to 4 s [1].", refCount: 1).verified)
        #expect(!CitationCheck.verify(note: "The cart API is slow [1]. Yes [4].", refCount: 1).verified)
    }
}
