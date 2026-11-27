import ArgumentParser
import Foundation
import BrahmaCore

extension SettingsGroup {
    /// Plan X1 Task 6: the owner's model prices. Both forms refuse inside an agent turn (Ruling 21); setting needs the owner key.
    struct ModelPrice: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "model-price",
            abstract: "List the model prices the gateway meters with, or set the price of one provider's model.",
            discussion: """
                Prices are USD per million tokens. Pinned prices cover the Anthropic models Brahma runs; the gateway refuses \
                any other model until it is priced here. A price you set replaces a pinned one. Every price must be above \
                zero, and an unset cache rate is the input rate.

                EXAMPLES:
                  brahma settings model-price
                  brahma settings model-price openai/example-model 1.25 10 --cache-read 0.125
                  brahma settings model-price openrouter/vendor/model-1 0.5 1.5
                """)

        @Argument(help: ArgumentHelp("<provider>/<model>, e.g. openai/example-model; omit to list every price.", valueName: "provider/model"))
        var model: String?
        @Argument(help: ArgumentHelp("USD per million input tokens.", valueName: "usd-in")) var inPerMTok: Double?
        @Argument(help: ArgumentHelp("USD per million output tokens.", valueName: "usd-out")) var outPerMTok: Double?
        @Option(name: .customLong("cache-read"), help: ArgumentHelp("USD per million cache-read tokens (default: the input price).", valueName: "usd"))
        var cacheRead: Double?
        @Option(name: .customLong("cache-write"), help: ArgumentHelp("USD per million cache-write tokens (default: the input price).", valueName: "usd"))
        var cacheWrite: Double?

        func run() throws {
            guard let model else {
                guard cacheRead == nil, cacheWrite == nil else { throw fail("--cache-read and --cache-write need a model and its prices") }
                try refuseInsideAgentTurn()
                let (store, _) = try openStore()
                list(owner: try store.priceRows())
                return
            }
            guard let slash = model.firstIndex(of: "/"), slash != model.startIndex, model.index(after: slash) != model.endIndex else {
                throw fail("name a model as <provider>/<model>, e.g. openai/example-model")
            }
            guard let inPerMTok, let outPerMTok else {
                throw fail("give the input and output prices: brahma settings model-price <provider>/<model> <in> <out>")
            }
            let row = PriceRow(provider: String(model[..<slash]), model: String(model[model.index(after: slash)...]),
                               inPerMTok: inPerMTok, outPerMTok: outPerMTok, cacheReadPerMTok: cacheRead,
                               cacheWritePerMTok: cacheWrite, setBy: "owner")
            if let why = PriceBook.refusal(for: row) { throw fail(why) }
            try requireOwnerShell()
            let (store, _) = try openStore()
            guard try store.provider(id: row.provider) != nil else { throw fail("no such provider: \(row.provider)") }
            do { try store.setPriceRow(row) } catch { throw fail("\(error)") }
            print(Self.line(PriceBook.key(provider: row.provider, model: row.model), Price(row), "owner"))
        }

        /// Every owner row and every pinned row, by key; a pinned row an owner row replaces says so.
        private func list(owner rows: [PriceRow]) {
            let ownerKeys = Set(rows.map { PriceBook.key(provider: $0.provider, model: $0.model) })
            var entries = rows.map { (key: PriceBook.key(provider: $0.provider, model: $0.model), rank: 0, price: Price($0), source: "owner") }
            for (key, price) in PriceBook.pinned {
                let source = "pinned \(PriceBook.pinnedOn)" + (ownerKeys.contains(key) ? ", overridden by owner" : "")
                entries.append((key: key, rank: 1, price: price, source: source))
            }
            print("USD per million tokens; pinned prices as of \(PriceBook.pinnedOn); an unset cache rate is the input rate")
            for e in entries.sorted(by: { ($0.key, $0.rank) < ($1.key, $1.rank) }) { print(Self.line(e.key, e.price, e.source)) }
        }

        static func line(_ key: String, _ p: Price, _ source: String) -> String {
            func usd(_ v: Double) -> String { "$" + String(format: "%g", v) }
            return "\(safe(key))  in \(usd(p.inPerMTok))  out \(usd(p.outPerMTok))  cache read \(usd(p.cacheReadRate))  "
                + "cache write \(usd(p.cacheWriteRate))  \(source)"
        }
    }
}
