import Foundation
import GRDB

/// The settings shapes the 5-lite probe gates are recorded for (`probeGate.shape`). A gate passed for one shape says nothing
/// about another: the sandboxed Task turn, the Ultra turn and the sandboxed plan turn each have their own.
public enum ProbeShape: String, Codable, CaseIterable, Sendable {
    /// A Standard or Deep work turn with forced sub-agents (`BuiltinTools.withTask`).
    case sandboxedTask = "sandboxed-task"
    /// An Ultra turn (`BuiltinTools.ultra`, workflows on).
    case ultra
    /// A Plan-first plan turn under the sandboxed argv.
    case sandboxedPlan = "sandboxed-plan"
}

/// One probe gate's outcome for one shape.
public struct GateResult: Equatable, Sendable {
    public var gate: String
    public var shape: ProbeShape
    public var passed: Bool
    public var detail: String

    public init(gate: String, shape: ProbeShape, passed: Bool, detail: String) {
        self.gate = gate; self.shape = shape; self.passed = passed; self.detail = detail
    }
}

/// A recorded `probeGate` row.
public struct ProbeGateRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "probeGate"
    public var cliFingerprint: String
    public var shape: String
    public var gate: String
    public var passed: Bool
    public var detail: String?
    public var checkedAt: Date
}

/// Runs one live probe gate (haiku, `--max-budget-usd ≤ 0.05`). Tests and the doctor pass their own.
public protocol ProbeGateRunning: Sendable {
    func run(gate: String, shape: ProbeShape) async -> GateResult
}

/// The probe gates 5-lite owns (Task 14u; design §8). 3a's V-10 and V-11 are shape-independent and not re-run.
public enum ProbeGates {
    /// The most a live probe may spend.
    public static let maxBudgetUSD = 0.05

    /// Every gate each shape needs, in the order `brahma mode gates` lists them.
    public static func catalog(_ shape: ProbeShape) -> [String] {
        switch shape {
        // The sub-agent gate (L-2, V-2 or V-8, V-3, V-5), the pre-taint gate (V-1), the web-tools gate (F7-agents), V-9.
        case .sandboxedTask: ["L-2", "V-2", "V-3", "V-5", "V-8", "V-1", "F7-agents", "V-9"]
        // Ultra's gate 1, plus the live Ultra probes; V-7 is U-3.
        case .ultra: ["U-1", "U-2", "U-3", "U-4", "U-5", "U-6", "U-7", "U-8", "U-9", "U-10", "V-1", "V-2", "V-8", "V-9"]
        case .sandboxedPlan: ["V-4", "V-9"]
        }
    }

    /// The gates that are not automated in this build: they stay failing until they are (the owner decides the probe).
    /// V-9 is Task 3's nested-`claude` canary probe (probe 10), pending the owner's ruling on the canary probe design.
    public static let pendingOwner: [String: String] = [
        "V-9": "pending owner decision: nested claude must fail from agent Bash (Task 3 canary probe 10, not built)",
    ]

    /// Runs `gate` for `shape` with `runner` and records the outcome for `fingerprint`. A gate pending the owner is recorded as
    /// failing without running anything. V-1 passing for the sandboxed-Task shape also records Task 10's `hookGate`, which
    /// ends the pre-taint of fan-out turns.
    @discardableResult
    public static func run(gate: String, shape: ProbeShape, runner: any ProbeGateRunning, store: Store, fingerprint: String,
                           now: Date = Store.now()) async -> GateResult {
        let result: GateResult
        if let why = pendingOwner[gate] {
            result = GateResult(gate: gate, shape: shape, passed: false, detail: why)
        } else {
            result = await runner.run(gate: gate, shape: shape)
        }
        try? store.recordProbeGate(result, fingerprint: fingerprint, now: now)
        return result
    }

    /// `brahma mode gates --run`: every gate of every shape that has not passed for `fingerprint`, in catalog order.
    public static func runMissing(runner: any ProbeGateRunning, store: Store, fingerprint: String,
                                  now: @Sendable () -> Date = { Store.now() }) async -> [GateResult] {
        var out: [GateResult] = []
        for shape in ProbeShape.allCases {
            let passed = (try? store.passedProbeGates(fingerprint: fingerprint, shape: shape)) ?? []
            for gate in catalog(shape) where !passed.contains(gate) {
                out.append(await run(gate: gate, shape: shape, runner: runner, store: store, fingerprint: fingerprint, now: now()))
            }
        }
        return out
    }
}

extension Store {
    /// Records one gate's outcome (replacing an earlier one of the same fingerprint, shape and gate).
    public func recordProbeGate(_ r: GateResult, fingerprint: String, now: Date = Store.now()) throws {
        try writer.write { db in
            try ProbeGateRow(cliFingerprint: fingerprint, shape: r.shape.rawValue, gate: r.gate, passed: r.passed,
                             detail: String(Store.flat(r.detail, max: 1000)), checkedAt: now).save(db)
        }
        if r.passed, r.gate == TaintPolicy.postToolGate, r.shape == .sandboxedTask {
            try recordHookGate(TaintPolicy.postToolGate, fingerprint: fingerprint, now: now)
        }
    }

    /// The gates passed for this CLI build and shape.
    public func passedProbeGates(fingerprint: String, shape: ProbeShape) throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT gate FROM probeGate WHERE cliFingerprint = ? AND shape = ? AND passed = 1",
                                    arguments: [fingerprint, shape.rawValue]))
        }
    }

    public func probeGateRows(fingerprint: String) throws -> [ProbeGateRow] {
        try writer.read { db in
            try ProbeGateRow.filter(Column("cliFingerprint") == fingerprint).order(Column("shape"), Column("gate")).fetchAll(db)
        }
    }
}
