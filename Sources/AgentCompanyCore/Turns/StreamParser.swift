import Foundation

public struct RateLimitInfo: Codable, Equatable, Sendable {
    public var status: String
    public var resetsAt: Date?
    public var rateLimitType: String?
    public var isUsingOverage: Bool
    public var fiveHourUtilization: Double?
    public var sevenDayUtilization: Double?
    public var observedAt: Date

    public init(status: String, resetsAt: Date?, rateLimitType: String?, isUsingOverage: Bool,
                fiveHourUtilization: Double?, sevenDayUtilization: Double?, observedAt: Date) {
        self.status = status
        self.resetsAt = resetsAt
        self.rateLimitType = rateLimitType
        self.isUsingOverage = isUsingOverage
        self.fiveHourUtilization = fiveHourUtilization
        self.sevenDayUtilization = sevenDayUtilization
        self.observedAt = observedAt
    }
}

public struct TurnResult: Equatable, Sendable {
    public var isError: Bool
    public var subtype: String
    public var text: String?
    public var costUSD: Double?
    public var apiErrorStatus: Int?
    public var sessionId: String

    public init(isError: Bool, subtype: String, text: String?, costUSD: Double?,
                apiErrorStatus: Int?, sessionId: String) {
        self.isError = isError
        self.subtype = subtype
        self.text = text
        self.costUSD = costUSD
        self.apiErrorStatus = apiErrorStatus
        self.sessionId = sessionId
    }
}

public enum StreamEvent: Equatable, Sendable {
    case initialized(sessionId: String, model: String)
    case assistantText(String)
    case toolUse(name: String)
    case rateLimit(RateLimitInfo)
    case result(TurnResult)
    case other(type: String)
}

/// Turns one line of `claude -p --output-format stream-json --verbose` output into a typed event.
public enum StreamParser {
    public static func parse(line: String, now: Date = .now) -> StreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "system":
            return parseSystem(object)
        case "assistant":
            return parseAssistant(object)
        case "rate_limit_event":
            return parseRateLimit(object, now: now)
        case "result":
            return parseResult(object)
        default:
            return .other(type: type)
        }
    }

    private static func parseSystem(_ object: [String: Any]) -> StreamEvent {
        guard object["subtype"] as? String == "init",
              let sessionId = object["session_id"] as? String,
              let model = object["model"] as? String else {
            return .other(type: "system")
        }
        return .initialized(sessionId: sessionId, model: model)
    }

    private static func parseAssistant(_ object: [String: Any]) -> StreamEvent {
        let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        if let toolUse = blocks.first(where: { $0["type"] as? String == "tool_use" }),
           let name = toolUse["name"] as? String {
            return .toolUse(name: name)
        }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? .other(type: "assistant") : .assistantText(text)
    }

    private static func parseRateLimit(_ object: [String: Any], now: Date) -> StreamEvent {
        let info = object["rate_limit_info"] as? [String: Any] ?? [:]
        let windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        let fiveHour = windows["five_hour"] as? [String: Any]
        let sevenDay = windows["seven_day"] as? [String: Any]
        return .rateLimit(RateLimitInfo(
            status: info["status"] as? String ?? "unknown",
            resetsAt: number(info["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            rateLimitType: info["rateLimitType"] as? String,
            isUsingOverage: info["isUsingOverage"] as? Bool ?? false,
            fiveHourUtilization: number(fiveHour?["utilization"]),
            sevenDayUtilization: number(sevenDay?["utilization"]),
            observedAt: now
        ))
    }

    private static func parseResult(_ object: [String: Any]) -> StreamEvent {
        .result(TurnResult(
            isError: object["is_error"] as? Bool ?? false,
            subtype: object["subtype"] as? String ?? "",
            text: object["result"] as? String,
            costUSD: number(object["total_cost_usd"]),
            apiErrorStatus: (object["api_error_status"] as? NSNumber)?.intValue,
            sessionId: object["session_id"] as? String ?? ""
        ))
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
