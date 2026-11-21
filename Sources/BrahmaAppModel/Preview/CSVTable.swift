import Foundation

/// A bounded RFC 4180 table (Plan 4a Task 8a): the first record is the header, then at most `maxRows` rows of at most
/// `maxColumns` cells of at most `maxCellChars` scalars each, and no physical line adds to a cell past
/// `RendererCaps.maxLineBytes`. Quoted fields may hold the separator, doubled quotes and newlines; CRLF and LF both end a
/// record; blank lines are skipped. Past the line cut the quote, separator and record state machine keeps running (so a
/// long quoted cell still closes and the records after it still parse); only the appending of text stops. `truncated`
/// says something was left out (rows, columns, the tail of a cell or of a line).
public struct CSVTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    public var truncated: Bool

    public static let maxRows = 2000
    public static let maxColumns = 100
    public static let maxCellChars = 1000

    public init(header: [String], rows: [[String]], truncated: Bool) {
        self.header = header
        self.rows = rows
        self.truncated = truncated
    }

    public static func parse(_ text: String, separator: Character = ",") -> CSVTable {
        let sep = separator.unicodeScalars.first ?? ","
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var fieldScalars = 0
        var inQuotes = false
        var truncated = false
        var lineBytes = 0
        /// Set once the physical line passed the cap: structure is still tracked, text is no longer kept.
        var lineCut = false

        func append(_ c: Unicode.Scalar) {
            if lineCut {
                truncated = true
            } else if fieldScalars < maxCellChars {
                field.append(c)
                fieldScalars += 1
            } else {
                truncated = true
            }
        }
        func endField() {
            if record.count < maxColumns { record.append(String(field)) } else { truncated = true }
            field = String.UnicodeScalarView()
            fieldScalars = 0
        }
        func endRecord() {
            if field.last == "\r", !inQuotes {
                field.removeLast()
                fieldScalars -= 1
            }
            endField()
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }   // a blank line is not a row
            record = []
        }

        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let c = scalars[i]
            if records.count > maxRows {
                // The header and `maxRows` rows are in; anything but line ends after them is left out.
                if c != "\n", c != "\r" { truncated = true; break }
                i = scalars.index(after: i)
                continue
            }
            if c == "\n" {
                lineBytes = 0
                lineCut = false
            } else if !lineCut {
                lineBytes += c.utf8.count
                if lineBytes > RendererCaps.maxLineBytes {
                    truncated = true
                    lineCut = true
                }
            }
            if inQuotes {
                if c == "\"" {
                    let next = scalars.index(after: i)
                    if next < scalars.endIndex, scalars[next] == "\"" {
                        append("\"")
                        i = scalars.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    append(c)
                }
            } else if c == "\"", fieldScalars == 0 {
                inQuotes = true
            } else if c == sep {
                endField()
            } else if c == "\n" {
                endRecord()
            } else {
                append(c)
            }
            i = scalars.index(after: i)
        }
        if inQuotes || fieldScalars > 0 || !record.isEmpty { endRecord() }
        return CSVTable(header: records.first ?? [], rows: Array(records.dropFirst()), truncated: truncated)
    }
}
