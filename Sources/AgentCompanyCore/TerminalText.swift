import Foundation

public enum TerminalText {
    /// Makes agent-controlled text safe to print: every C0 control (including ESC, newline, tab), DEL and C1
    /// control becomes a space, so it cannot move the cursor, clear the screen or inject escape sequences.
    public static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            s.value < 0x20 || (0x7F...0x9F).contains(s.value) ? " " : s
        }))
    }
}
