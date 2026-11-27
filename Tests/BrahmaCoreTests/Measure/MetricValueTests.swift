import Foundation
import Testing
@testable import BrahmaCore

/// `MetricValue` (Plan X6a Task 1): a number is never shown without its denominator, a rate with fewer than
/// `MetricValue.minEvents` events is `insufficient data`, counts are never insufficient, and every refusal to show a number
/// carries its reason.
@Suite(.scratch) struct MetricValueTests {
    @Test func neverDividesByZero() throws {
        let v = MetricValue.rate(.greenMain, numerator: 0, denominator: 0, unit: .ratio, basis: "landings in the window")
        #expect(v.status == .insufficient(n: 0))
        #expect(v.display == "insufficient data (n=0)")
        // A hand-built `ok` rate over nothing still never divides: it displays as insufficient.
        let forced = MetricValue(id: .usagePerLanded, label: "x", numerator: 3, denominator: 0, unit: .usd, basis: "", detail: [],
                                 status: .ok, target: nil)
        #expect(forced.display == "insufficient data (n=0)")
        for unit in [MetricUnit.ratio, .usd] {
            let z = MetricValue.rate(.revertRate, numerator: 5, denominator: 0, unit: unit, basis: "")
            #expect(z.status == .insufficient(n: 0), "\(unit)")
            #expect(!z.display.contains("inf") && !z.display.contains("nan"), "\(unit): \(z.display)")
        }
        // The inverted units count their numerator as events, and still never divide by a zero denominator.
        for unit in [MetricUnit.perUSD, .perHour] {
            let z = MetricValue.rate(.itemsPerDollar, numerator: 25, denominator: 0, unit: unit, basis: "")
            #expect(z.status == .insufficient(n: 0), "\(unit)")
            #expect(z.display == "insufficient data (n=0)", "\(unit): \(z.display)")
        }
    }

    /// `perItem` (Task 5: turns, tokens, touches, rework rounds per landed item): a rate over landed items, shown with its pair.
    @Test func perItemShowsItsPair() throws {
        let v = MetricValue.rate(.ownerTouches, numerator: 5, denominator: 20, unit: .perItem, basis: "")
        #expect(v.status == .ok && v.display == "0.25 per landed item (5/20)")
        #expect(MetricValue.rate(.ownerTouches, numerator: 5, denominator: 19, unit: .perItem, basis: "").status == .insufficient(n: 19))
        #expect(MetricValue.rate(.ownerTouches, numerator: 5, denominator: 0, unit: .perItem, basis: "").display == "insufficient data (n=0)")
        #expect(MetricUnit.perItem.isRate)
    }

    /// A denominator of zero or less is `insufficient(n: 0)` for every rate unit, so the status always agrees with the display —
    /// even when the event count (the numerator for `perUSD`/`perHour`, or an explicit `events:`) is 20 or more.
    @Test func nonPositiveDenominatorIsInsufficientForEveryRateUnit() throws {
        for unit in [MetricUnit.ratio, .usd, .perUSD, .perHour] {
            for denominator in [0.0, -1, -40] {
                let v = MetricValue.rate(.itemsPerDollar, numerator: 40, denominator: denominator, unit: unit, basis: "")
                #expect(v.status == .insufficient(n: 0), "\(unit) over \(denominator)")
                #expect(v.display == "insufficient data (n=0)", "\(unit) over \(denominator): \(v.display)")
                let forced = MetricValue.rate(.itemsPerDollar, numerator: 40, denominator: denominator, unit: unit, basis: "", events: 40)
                #expect(forced.status == .insufficient(n: 0), "\(unit) over \(denominator) with events: 40")
            }
            // The same rate over a positive denominator is measured.
            #expect(MetricValue.rate(.itemsPerDollar, numerator: 40, denominator: 20, unit: unit, basis: "", events: 20).status == .ok, "\(unit)")
        }
    }

    @Test func insufficientUsesEventCountForInvertedRates() throws {
        // 25 landed items over $12.50: 25 events, not 12.
        let perUSD = MetricValue.rate(.itemsPerDollar, numerator: 25, denominator: 12.5, unit: .perUSD, basis: "")
        #expect(perUSD.status == .ok)
        #expect(perUSD.display == "2.00 per $LE (25/12.50)")
        let fewItems = MetricValue.rate(.itemsPerDollar, numerator: 19, denominator: 400, unit: .perUSD, basis: "")
        #expect(fewItems.status == .insufficient(n: 19))
        let perHour = MetricValue.rate(.itemsPerPlanHour, numerator: 20, denominator: 3.5, unit: .perHour, basis: "")
        #expect(perHour.status == .ok && perHour.display == "5.71 per plan-hour (20/3.50)")
        #expect(MetricValue.rate(.itemsPerPlanHour, numerator: 7, denominator: 1000, unit: .perHour, basis: "").status == .insufficient(n: 7))
        // ratio and usd still count the denominator.
        #expect(MetricValue.rate(.usagePerLanded, numerator: 400, denominator: 19, unit: .usd, basis: "").status == .insufficient(n: 19))
        #expect(MetricValue.rate(.firstPass, numerator: 7, denominator: 1000, unit: .ratio, basis: "").status == .ok)
        // An explicit event count wins.
        #expect(MetricValue.rate(.firstPass, numerator: 7, denominator: 1000, unit: .ratio, basis: "", events: 3).status == .insufficient(n: 3))
    }

    @Test func nonFiniteNumbersNeverTrap() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(MetricValue.rate(.greenMain, numerator: bad, denominator: 40, unit: .ratio, basis: "").display == "insufficient data (n=0)")
            #expect(MetricValue.rate(.greenMain, numerator: 30, denominator: bad, unit: .ratio, basis: "").display == "insufficient data (n=0)")
            #expect(MetricValue.rate(.itemsPerDollar, numerator: bad, denominator: 40, unit: .perUSD, basis: "").display == "insufficient data (n=0)")
            #expect(MetricValue.count(.safety, label: "x", bad, basis: "").display == "0")
            #expect(MetricValue.count(.safety, label: "x", 2, basis: "", target: bad).display == "2 (target 0)")
            #expect(MetricValue.seconds(.queueHealth, label: "x", bad, basis: "").display == "0 s")
            let forced = MetricValue(id: .greenMain, label: "x", numerator: bad, denominator: bad, unit: .ratio, basis: "", status: .ok)
            #expect(forced.display == "insufficient data (n=0)")
        }
    }

    @Test func insufficientBelowTwenty() throws {
        #expect(MetricValue.minEvents == 20)
        let nineteen = MetricValue.rate(.firstPass, numerator: 18, denominator: 19, unit: .ratio, basis: "landed items")
        #expect(nineteen.status == .insufficient(n: 19))
        #expect(nineteen.display == "insufficient data (n=19)")
        let twenty = MetricValue.rate(.firstPass, numerator: 19, denominator: 20, unit: .ratio, basis: "landed items")
        #expect(twenty.status == .ok)
        #expect(twenty.display == "95.0% (19/20)")
    }

    @Test func displayShowsDenominator() throws {
        let ratio = MetricValue.rate(.greenMain, numerator: 38, denominator: 39, unit: .ratio, basis: "")
        #expect(ratio.display == "97.4% (38/39)")
        let usd = MetricValue.rate(.usagePerLanded, numerator: 24, denominator: 20, unit: .usd, basis: "")
        #expect(usd.display == "$1.20 per landed item (24.00/20)")
        let perUSD = MetricValue.rate(.itemsPerDollar, numerator: 20, denominator: 24, unit: .perUSD, basis: "")
        #expect(perUSD.display == "0.83 per $LE (20/24.00)")
        let perHour = MetricValue.rate(.itemsPerPlanHour, numerator: 30, denominator: 24.5, unit: .perHour, basis: "")
        #expect(perHour.display == "1.22 per plan-hour (30/24.50)")
        // Every `ok` rate display carries its raw pair.
        for (n, d) in [(38.0, 39.0), (20.0, 20.0), (0.0, 25.0), (999.0, 1000.0)] {
            let v = MetricValue.rate(.escapeRate, numerator: n, denominator: d, unit: .ratio, basis: "")
            #expect(v.status == .ok)
            #expect(v.display.hasSuffix("(\(Int(n))/\(Int(d)))"), "\(v.display)")
        }
        // A fractional pair prints both sides with two decimals.
        let frac = MetricValue.rate(.escapeRate, numerator: 1.5, denominator: 30, unit: .ratio, basis: "")
        #expect(frac.display == "5.0% (1.50/30.00)")
    }

    @Test func notApplicableHasReason() throws {
        let v = MetricValue.notApplicable(.nonCode, reason: "landGate items and rubric checks absent")
        #expect(v.status == .notApplicable(reason: "landGate items and rubric checks absent"))
        #expect(v.display == "not applicable: landGate items and rubric checks absent")
        #expect(v.numerator == 0 && v.denominator == 0)
    }

    @Test func notMeasuredHasReason() throws {
        let v = MetricValue.notMeasured(.idleActionable, reason: "recorder not running")
        #expect(v.status == .notMeasured(reason: "recorder not running"))
        #expect(v.display == "not measured: recorder not running")
    }

    @Test func countsAreNeverInsufficient() throws {
        // A safety count of zero with a target prints the count and the target, never `insufficient data`.
        let overruns = MetricValue.count(.safety, label: "cap overruns", 0, basis: "ticks in the window", target: 0)
        #expect(overruns.status == .ok)
        #expect(overruns.display == "0 (target 0)")
        let hits = MetricValue.count(.safety, label: "DLP hits", 3, basis: "merge requests bounced for a secret")
        #expect(hits.status == .ok)
        #expect(hits.display == "3")
        #expect(hits.target == nil)
        // A duration with no denominator is a plain number of seconds.
        let secs = MetricValue.seconds(.queueHealth, label: "approval → land", 20.5, basis: "merged requests")
        #expect(secs.status == .ok)
        #expect(secs.display == "20.5 s")
        #expect(MetricValue.seconds(.queueHealth, label: "x", 90, basis: "").display == "90 s")
        // Only rates obey `minEvents`.
        #expect(MetricUnit.count.isRate == false && MetricUnit.seconds.isRate == false)
        let rates = [MetricUnit.ratio, .usd, .perUSD, .perHour].allSatisfy { $0.isRate }
        #expect(rates)
    }

    @Test func fifteenIdsInAFixedOrder() throws {
        #expect(MetricId.all.count == 15)
        #expect(MetricId.all.map(\.rawValue) == ["greenMain", "revertRate", "reviewCatch", "escapeRate", "usagePerLanded", "ownerTouches",
                                                  "firstPass", "queueHealth", "safety", "nonCode", "modelRanking", "idleActionable",
                                                  "itemsPerDollar", "itemsPerPlanHour", "ownerMinutes"])
        #expect(Set(MetricId.all.map(\.label)).count == 15, "every id has its own label")
    }

    @Test func codableRoundTrip() throws {
        var v = MetricValue.rate(.reviewCatch, numerator: 21, denominator: 25, unit: .ratio, basis: "confirmed catches + escapes")
        v.detail = [MetricValue.count(.reviewCatch, label: "unconfirmed change requests", 4, basis: "not in the rate"),
                    MetricValue.notMeasured(.reviewCatch, reason: "no links yet"),
                    MetricValue.rate(.reviewCatch, numerator: 1, denominator: 3, unit: .ratio, basis: "too few")]
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(MetricValue.self, from: data)
        #expect(back == v)
    }
}
