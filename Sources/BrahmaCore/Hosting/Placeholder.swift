import Foundation

/// The engine-written site a rollback deploys when there is no previous release: one `index.html` in
/// `ReleaseLayout.placeholderDir`, under the data home (I3). Its content is engine-fixed (so a plan's hash covers its
/// `cwdPath`, not the file), and it is rewritten before each placeholder rollback, through `EngineFiles` (no link is ever
/// followed).
public enum Placeholder {
    /// Replaces `layout.placeholderDir` with a folder holding only `index.html`; returns the folder.
    @discardableResult
    public static func write(to layout: ReleaseLayout, companyName: String) throws -> URL {
        try BrahmaPaths.ensurePrivateDirectory(layout.root)
        try EngineFiles.remove(workspace: layout.root, dir: "", name: "placeholder")
        try EngineFiles.directory(workspace: layout.root, "placeholder")
        try EngineFiles.replace(Data(html(companyName: companyName).utf8), workspace: layout.root, dir: "placeholder", name: "index.html")
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
