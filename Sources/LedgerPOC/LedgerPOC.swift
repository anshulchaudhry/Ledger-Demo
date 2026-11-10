import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

#if !LEDGER_TESTING
@main
struct LedgerPOC {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.count == 2 && args[0] == "--db" {
                try printJSON(Importer.summarize(MessagesReader.read(path: args[1])))
            } else if args.count == 3 && args[0] == "--review" && args[1] == "--db" {
                try printJSON(PrivateReview.run(databasePath: args[2]))
            } else if args.count == 3 && args[0] == "--review-more" && args[1] == "--db" {
                try printJSON(PrivateReview.run(databasePath: args[2], extended: true))
            } else if args.count == 1 && args[0] == "--review-report" {
                try printJSON(PrivateReview.report())
            } else {
                print("Usage: ledger-poc --db /path/to/chat.db")
                print("       ledger-poc --review --db /path/to/chat.db  (private local Terminal only)")
                print("       ledger-poc --review-more --db /path/to/chat.db  (optional extended review)")
                print("       ledger-poc --review-report                (aggregate counts only)")
            }
        } catch DatabaseError.unavailable {
            fputs("Database unavailable. Check its path and Full Disk Access for the launching app.\n", stderr)
            exit(1)
        } catch DatabaseError.unsupportedSchema {
            fputs("Unsupported Messages schema; no data was imported.\n", stderr)
            exit(1)
        } catch ReviewError.terminalRequired {
            fputs("Private review requires local Terminal.app or iTerm with no output redirection or SSH.\n", stderr)
            exit(1)
        } catch ReviewError.noState {
            fputs("No private review has been started in this folder.\n", stderr)
            exit(1)
        } catch {
            fputs("Operation failed. Check local review file permissions and try again.\n", stderr)
            exit(1)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let output = String(data: try encoder.encode(value), encoding: .utf8) { print(output) }
    }
}
#endif
