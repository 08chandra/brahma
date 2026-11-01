import Foundation

/// The engine-written site a rollback deploys when there is no previous release: one `index.html` in
/// `EngineLayout.placeholderDir`. Its content is engine-fixed (so a plan's hash covers its `cwdPath`, not the file), and it
/// is rewritten before each placeholder rollback, through `EngineFiles` (no link under `.brahma` is ever followed).
public enum Placeholder {
    static let relative = ".brahma/releases/placeholder"

    /// Replaces `layout.placeholderDir` with a folder holding only `index.html`; returns the folder.
    @discardableResult
    public static func write(to layout: EngineLayout, companyName: String) throws -> URL {
        try EngineFiles.remove(workspace: layout.workspace, dir: ".brahma/releases", name: "placeholder")
        try EngineFiles.directory(workspace: layout.workspace, relative)
        try EngineFiles.replace(Data(html(companyName: companyName).utf8), workspace: layout.workspace, dir: relative, name: "index.html")
        return layout.placeholderDir
    }

    /// The page: title `<companyName>`, body "This site is being updated.".
    public static func html(companyName: String) -> String {
        let name = escape(companyName)
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(name)</title></head>
        <body><p>This site is being updated.</p></body>
        </html>

        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}
