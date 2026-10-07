import Foundation
import UniformTypeIdentifiers

/// Tells text files (opened as documents) from other files (attached to notes).
public enum TextDetection {
    /// Whether `data` looks like text: no NUL bytes in the first 8 KB, unless it starts with a UTF-16/32 BOM.
    public static func isText(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return true }
        return !data.prefix(8192).contains(0)
    }

    /// Whether the file at `url` is text, by its type when that's conclusive, else by its first bytes.
    public static func isText(at url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
            if [.image, .audiovisualContent, .pdf, .archive, .executable, .font, .presentation, .spreadsheet]
                .contains(where: { type.conforms(to: $0) }) { return false }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isText((try? handle.read(upToCount: 8192)) ?? Data())
    }
}
