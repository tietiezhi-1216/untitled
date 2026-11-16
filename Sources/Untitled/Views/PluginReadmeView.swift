import SwiftUI

/// Native, selectable Markdown. No HTML, scripts or remote images execute when a README opens.
struct PluginReadmeView: View {
    let blocks: [PluginReadmeBlock]
    let repository: URL
    let readmeURL: URL

    init(markdown: String, repository: URL, readmeURL: URL? = nil) {
        blocks = PluginReadmeBlock.parse(markdown)
        self.repository = repository
        self.readmeURL = readmeURL ?? repository.appendingPathComponent("blob/main/README.md")
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    inline(block.text)
                        .font(.system(size: level == 1 ? 22 : (level == 2 ? 17 : 14), weight: .semibold))
                        .padding(.top, level < 3 ? 12 : 4).accessibilityAddTraits(.isHeader)
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(size: 12, design: .monospaced)).padding(14)
                    }
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                case .list(let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                        inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote:
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                        inline(block.text).foregroundStyle(.secondary)
                    }
                case .table:
                    let rows = block.text.components(separatedBy: "\n").map { line in
                        line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                            .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    }.filter { !$0.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil } }
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                                            .frame(width: (rows.first?.count ?? 0) > 3 ? 170 : 240, alignment: .leading)
                                    }
                                }
                            }
                        }.padding(14)
                    }
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                case .paragraph:
                    inline(block.text)
                }
            }
        }
        .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
            baseURL: readmeURL)) ?? AttributedString(text)
        return Text(attributed)
    }
}

struct PluginReadmeBlock: Identifiable, Equatable {
    enum Kind: Equatable { case heading(Int), paragraph, code, list(String), quote, table }
    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ markdown: String) -> [Self] {
        let bounded = String(decoding: markdown.utf8.prefix(PluginArchive.maximumReadmeSize), as: UTF8.self)
        var result: [Self] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var table: [String] = []
        func append(_ kind: Kind, _ text: String) { result.append(Self(id: result.count, kind: kind, text: text)) }
        func flush() {
            if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph.removeAll() }
            if !table.isEmpty {
                // Keep large documents readable without constructing thousands of eager Grid cells.
                let oversized = table.count > 200 || table.contains { $0.split(separator: "|", maxSplits: 10).count > 8 }
                append(oversized ? .code : .table, table.joined(separator: "\n"))
                table.removeAll()
            }
        }
        for line in bounded.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let contents = code { append(.code, contents.joined(separator: "\n")); code = nil }
                else { flush(); code = [] }
            } else if code != nil { code?.append(line) }
            else if trimmed.isEmpty { flush() }
            else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                if !paragraph.isEmpty { flush() }
                table.append(trimmed)
            } else if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                append(.heading(trimmed.prefix { $0 == "#" }.count), String(trimmed[range.upperBound...]))
            } else if let range = trimmed.range(of: #"^([-*+] |[0-9]+\. )"#, options: .regularExpression) {
                flush()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                append(.list(["-", "*", "+"].contains(marker) ? "•" : marker), String(trimmed[range.upperBound...]))
            } else if trimmed.hasPrefix("> ") {
                flush(); append(.quote, String(trimmed.dropFirst(2)))
            } else if ["---", "***", "___"].contains(trimmed) { flush() }
            else {
                if !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        if let code { append(.code, code.joined(separator: "\n")) }
        return result
    }
}
