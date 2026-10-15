// Writes the third-party license notices shown in the About panel (Credits.html).
//   swift scripts/acknowledgements.swift <Package.resolved> <checkouts dir> <output .html>
// Every pinned package must have a license file in its checkout, or this fails (and so does
// the build that runs it), so a new dependency can't ship without its notice.
import Foundation

struct Pin: Decodable {
    struct State: Decodable { let version: String?; let revision: String? }
    let identity: String
    let location: String
    let state: State
}
struct Resolved: Decodable { let pins: [Pin] }

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: acknowledgements.swift <Package.resolved> <checkouts> <out.html>\n".utf8))
    exit(64)
}
let resolvedURL = URL(fileURLWithPath: args[1])
let checkouts = URL(fileURLWithPath: args[2], isDirectory: true)
let output = URL(fileURLWithPath: args[3])
let fm = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ Acknowledgements: \(message)\n".utf8))
    exit(1)
}

let resolved: Resolved
do { resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolvedURL)) }
catch { fail("can't read \(resolvedURL.path): \(error)") }

/// A pin's checkout folder is named after the last part of its URL (SwiftPM's rule).
func checkoutFolder(for pin: Pin) -> URL? {
    let repo = URL(string: pin.location)?.deletingPathExtension().lastPathComponent ?? pin.identity
    let names = (try? fm.contentsOfDirectory(atPath: checkouts.path)) ?? []
    let match = names.first { $0 == repo } ?? names.first { $0.lowercased() == pin.identity.lowercased() }
    return match.map { checkouts.appendingPathComponent($0, isDirectory: true) }
}

func licenseFile(in folder: URL) -> URL? {
    let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    let name = names.first { name in
        let upper = name.uppercased()
        return ["LICENSE", "LICENCE", "COPYING"].contains { upper == $0 || upper.hasPrefix($0 + ".") }
    }
    return name.map { folder.appendingPathComponent($0) }
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// License files are hard-wrapped at ~78 columns; the About panel is narrow, so paragraphs are
/// rejoined. List items, copyright lines and indented blocks keep their own lines, and rules
/// (`-----`, `=====`) become separators.
func html(forLicense text: String) -> String {
    let isRule = { (line: String) in line.count >= 2 && line.allSatisfy { "-=_*".contains($0) } }
    let startsOwnLine = { (line: String) in
        line.range(of: #"^\s*(\d+\.|\*|-|•|\([a-z0-9]\)|Copyright|\([cC]\)|©)"#, options: .regularExpression) != nil
    }
    var blocks: [String] = []
    let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n").split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    for paragraph in paragraphs {
        let lines = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !isRule($0) }
        if lines.isEmpty { blocks.append("<hr>"); continue }
        var rendered = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { rendered += startsOwnLine(line) ? "<br>" : " " }
            rendered += escape(line)
        }
        blocks.append("<p>\(rendered)</p>")
    }
    return blocks.joined(separator: "\n")
}

var sections: [String] = []
var missing: [String] = []
for pin in resolved.pins.sorted(by: { $0.identity < $1.identity }) {
    guard let folder = checkoutFolder(for: pin), let license = licenseFile(in: folder),
          let text = try? String(contentsOf: license, encoding: .utf8) else {
        missing.append(pin.identity)
        continue
    }
    let name = folder.lastPathComponent
    let version = pin.state.version.map { " \($0)" } ?? ""
    let link = pin.location.hasSuffix(".git") ? String(pin.location.dropLast(4)) : pin.location
    sections.append("""
        <h2>\(escape(name))\(escape(version))</h2>
        <p class="link"><a href="\(escape(link))">\(escape(link))</a></p>
        \(html(forLicense: text))
        """)
}
if !missing.isEmpty {
    fail("no license file (LICENSE, LICENCE or COPYING) in the checkout of: \(missing.joined(separator: ", ")). Resolve packages first, or add the notice by hand.")
}

let page = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Acknowledgements</title>
    <style>
    body { font: 11px -apple-system, sans-serif; }
    h2 { font-size: 12px; font-weight: 600; margin: 14px 0 2px; }
    p { margin: 0 0 6px; }
    p.link { margin-bottom: 8px; }
    </style></head><body>
    <p>NoteMD is built with these open-source packages:</p>
    \(sections.joined(separator: "\n"))
    </body></html>

    """
do {
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(page.utf8).write(to: output, options: .atomic)
} catch { fail("can't write \(output.path): \(error)") }
