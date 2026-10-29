import Foundation

/// Small, local vocabulary bridge for Clinton's shared markdown knowledge vault.
/// It extracts note titles from the high-signal people/company/domain areas; it
/// never reads note bodies or sends email/swipe-file prose to an ASR provider.
enum ForkKnowledgeVocabulary {
    static func keyterms(limit: Int = 100, fileManager: FileManager = .default) -> [String] {
        guard limit > 0 else { return [] }
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("knowledge", isDirectory: true)
        let roots = ["people", "companies", "domains/work", "projects"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        var terms: [String] = []
        var seen = Set<String>()

        for searchRoot in roots where fileManager.fileExists(atPath: searchRoot.path) {
            guard let enumerator = fileManager.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                guard url.lastPathComponent != "AGENTS.md",
                      url.lastPathComponent != "_index.md",
                      let term = noteTitle(at: url),
                      term.count >= 2,
                      term.count <= 100 else { continue }
                let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard seen.insert(key).inserted else { continue }
                terms.append(term)
                if terms.count == limit { return terms }
            }
        }
        return terms
    }

    private static func noteTitle(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let prefix = String(data: data, encoding: .utf8) else { return nil }
        if let heading = prefix.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("# ") }) {
            return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let slug = url.deletingPathExtension().lastPathComponent
        guard !slug.isEmpty else { return nil }
        return slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}
