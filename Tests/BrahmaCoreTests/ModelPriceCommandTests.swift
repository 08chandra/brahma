import Foundation
import Testing
@testable import BrahmaCore

/// Plan X1 Task 6: `brahma settings model-price` sets an owner price and lists the pinned and owner rows; it refuses bad
/// values, zero prices (no `local` adapter yet, Ruling 36) and any use inside an agent turn (Ruling 21).
@Suite(.scratch) struct ModelPriceCommandTests {
    private let unit = "USD per million tokens"

    @Test func setsAndLists() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        let fresh = try runBrahma(["settings", "model-price"], home: home)
        #expect(fresh.status == 0, "\(fresh.stderr)")
        #expect(fresh.stdout.contains(unit), "\(fresh.stdout)")
        #expect(fresh.stdout.contains("anthropic/claude-opus-5-5  in $4  out $20  cache read $0.2  cache write $8  pinned 2026-10-06\n"), "\(fresh.stdout)")
        #expect(fresh.stdout.contains("anthropic/claude-haiku-5-5  in $0.5  out $2.5  cache read $0.05  cache write $1  pinned 2026-10-06\n"), "\(fresh.stdout)")
        #expect(!fresh.stdout.contains("owner"), "\(fresh.stdout)")

        let set = try runBrahma(["settings", "model-price", "openai/gpt-x", "1.5", "6", "--cache-read", "0.4"], home: home)
        #expect(set.status == 0, "\(set.stderr)")
        #expect(set.stdout == "openai/gpt-x  in $1.5  out $6  cache read $0.4  cache write $1.5  owner\n", "\(set.stdout)")
        let over = try runBrahma(["settings", "model-price", "anthropic/claude-opus-5-5", "7", "30", "--cache-read", "0.5",
                                  "--cache-write", "9"], home: home)
        #expect(over.status == 0, "\(over.stderr)")
        // A slash inside the model id belongs to the model (OpenRouter's `vendor/model`).
        #expect(try runBrahma(["settings", "model-price", "openrouter/acme/model-1", "3", "4"], home: home).status == 0)

        let list = try runBrahma(["settings", "model-price"], home: home).stdout
        #expect(list.contains("openai/gpt-x  in $1.5  out $6  cache read $0.4  cache write $1.5  owner\n"), "\(list)")
        #expect(list.contains("openrouter/acme/model-1  in $3  out $4  cache read $3  cache write $3  owner\n"), "\(list)")
        #expect(list.contains("anthropic/claude-opus-5-5  in $7  out $30  cache read $0.5  cache write $9  owner\n"), "\(list)")
        #expect(list.contains("anthropic/claude-opus-5-5  in $4  out $20  cache read $0.2  cache write $8  pinned 2026-10-06, overridden by owner\n"), "\(list)")

        // Setting again replaces the row; the store holds exactly the owner's rows.
        #expect(try runBrahma(["settings", "model-price", "openai/gpt-x", "2", "8"], home: home).status == 0)
        let store = try Store(path: ownerPaths(home).database.path)
        let rows = try store.priceRows()
        #expect(rows.map { "\($0.provider)/\($0.model)" } == ["anthropic/claude-opus-5-5", "openai/gpt-x", "openrouter/acme/model-1"])
        #expect(rows.first { $0.model == "gpt-x" } == PriceRow(provider: "openai", model: "gpt-x", inPerMTok: 2, outPerMTok: 8, setBy: "owner"))
        #expect(PriceBook(owner: rows).price(provider: "anthropic", model: "claude-opus-5-5")?.cacheWritePerMTok == 9)

        let help = try runBrahma(["settings", "model-price", "--help"], home: home)
        #expect(help.stdout.contains("EXAMPLES:"), "\(help.stdout)")
        #expect(help.stdout.contains("brahma settings model-price openai/"), "\(help.stdout)")
    }

    @Test func refusesNegativeAndNaN() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        let message = "prices must be finite and zero or more dollars per million tokens"
        for args in [["--", "-1", "2"], ["nan", "2"], ["1", "inf"], ["1", "2", "--cache-read=-0.5"], ["1", "2", "--cache-write", "nan"]] {
            let r = try runBrahma(["settings", "model-price", "openai/gpt-x"] + args, home: home)
            #expect(r.status == 1, "\(args)")
            #expect(r.stderr == "brahma: \(message)\n", "\(args): \(r.stderr)")
        }
        for (args, why) in [(["gpt-x", "1", "2"], "name a model as <provider>/<model>"), (["openai/", "1", "2"], "name a model as <provider>/<model>"),
                            (["/gpt-x", "1", "2"], "name a model as <provider>/<model>"), (["nobody/gpt-x", "1", "2"], "no such provider: nobody")] {
            let r = try runBrahma(["settings", "model-price"] + args, home: home)
            #expect(r.status == 1, "\(args)"); #expect(r.stderr.contains(why), "\(args): \(r.stderr)")
        }
        #expect(try runBrahma(["settings", "model-price", "openai/gpt-x", "abc", "2"], home: home).status != 0)
        #expect(try runBrahma(["settings", "model-price", "openai/gpt-x", "1"], home: home).status != 0, "both rates are required")
        #expect(!(try runBrahma(["settings", "model-price"], home: home).stdout.contains("owner")), "nothing was written")
    }

    @Test func refusesZeroForRemote() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        for args in [["openai/gpt-x", "0", "2"], ["anthropic/claude-opus-5-5", "4", "0"], ["groq/m", "1", "2", "--cache-read", "0"],
                     ["openrouter/acme/m", "1", "2", "--cache-write", "0"]] {
            let r = try runBrahma(["settings", "model-price"] + args, home: home)
            #expect(r.status == 1, "\(args)")
            #expect(r.stderr == "brahma: zero prices are only for local providers\n", "\(args): \(r.stderr)")
        }
        #expect(!(try runBrahma(["settings", "model-price"], home: home).stdout.contains("owner")), "nothing was written")
    }

    @Test func refusedInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        for args in [["settings", "model-price"], ["settings", "model-price", "openai/gpt-x", "1", "2"]] {
            let r = try runBrahma(args, home: home, extra: ["BRAHMA_AGENT_ID": "a1"])
            #expect(r.status == 1, "\(args)")
            #expect(r.stdout.isEmpty, "\(args): \(r.stdout)")
            #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(r.stderr)")
        }
        #expect(!(try runBrahma(["settings", "model-price"], home: home).stdout.contains("owner")), "nothing was written")
        // Setting needs the owner key; listing does not.
        let nokey = try OwnerTestHome(initOwner: false)
        let r = try runBrahma(["settings", "model-price", "openai/gpt-x", "1", "2"], home: nokey.url)
        #expect(r.status == 1); #expect(r.stderr.contains("owner key missing or invalid"), "\(r.stderr)")
        #expect(try runBrahma(["settings", "model-price"], home: nokey.url).status == 0)
    }
}
