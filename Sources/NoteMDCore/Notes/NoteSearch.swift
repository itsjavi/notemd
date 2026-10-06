import Foundation

enum SearchFolding {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// A parsed search query: free-text terms plus `tag:x` / `#x` filters. Quoted phrases stay together.
public struct SearchQuery: Sendable, Equatable {
    public var terms: [String]
    public var tags: [String]

    public init(_ query: String) {
        var terms: [String] = []
        var tags: [String] = []
        for token in Self.tokenize(query) {
            let lower = token.lowercased()
            if lower.hasPrefix("tag:"), token.count > 4 {
                tags.append(SearchFolding.fold(String(token.dropFirst(4))))
            } else if token.hasPrefix("#"), token.count > 1, !token.dropFirst().hasPrefix("#") {
                tags.append(SearchFolding.fold(String(token.dropFirst())))
            } else {
                terms.append(SearchFolding.fold(token))
            }
        }
        self.terms = terms
        self.tags = tags
    }

    public var isEmpty: Bool { terms.isEmpty && tags.isEmpty }

    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                if quoted, !current.isEmpty { tokens.append(current); current = "" }
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append(current.trimmingCharacters(in: .whitespaces)) }
        return tokens
    }
}

public struct SearchResult: Sendable, Identifiable, Hashable {
    public var id: String { note.id }
    public let note: Note
    public let score: Int
    /// Body context around the first match (nil when only the title/tags matched).
    public let snippet: String?
}

public enum NoteSearch {
    /// Notes matching every term (in title, path, tags or body) and every tag filter, best first.
    public static func search(_ query: SearchQuery, in notes: [Note]) -> [SearchResult] {
        guard !query.isEmpty else { return notes.map { SearchResult(note: $0, score: 0, snippet: nil) } }
        var results: [SearchResult] = []
        for note in notes {
            let foldedTags = note.tags.map(SearchFolding.fold)
            guard query.tags.allSatisfy({ tag in foldedTags.contains(where: { $0 == tag || $0.hasPrefix(tag + "/") }) }) else { continue }
            var score = 0
            var firstBodyTerm: String?
            var firstBodyOffset = Int.max
            var matchedAll = true
            for term in query.terms {
                var termScore = 0
                if note.searchTitle.hasPrefix(term) { termScore += 30 }
                if note.searchTitle.contains(term) { termScore += 20 }
                if foldedTags.contains(where: { $0.contains(term) }) { termScore += 12 }
                if SearchFolding.fold(note.folderPath).contains(term) { termScore += 4 }
                if let range = note.searchBody.range(of: term) {
                    termScore += 2 + min(occurrences(of: term, in: note.searchBody, cap: 8), 8)
                    let offset = note.searchBody.distance(from: note.searchBody.startIndex, to: range.lowerBound)
                    if offset < firstBodyOffset { firstBodyOffset = offset; firstBodyTerm = term }
                }
                if termScore == 0 { matchedAll = false; break }
                score += termScore
            }
            guard matchedAll else { continue }
            let snippet = firstBodyTerm.flatMap { term in
                note.body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]).map { snippetText(in: note.body, around: $0) }
            }
            results.append(SearchResult(note: note, score: score, snippet: snippet))
        }
        return results.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.note.modified > rhs.note.modified
        }
    }

    private static func occurrences(of term: String, in text: String, cap: Int) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while count < cap, let range = text.range(of: term, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    /// One line of body text around a match, trimmed to ~120 characters.
    static func snippetText(in text: String, around range: Range<String.Index>, radius: Int = 50) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        snippet = snippet.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + snippet + (end < text.endIndex ? "…" : "")
    }
}
