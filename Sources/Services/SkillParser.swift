import Foundation

enum SkillParserError: Error {
    case noFrontmatter
    case missingClosingDelimiter
    case missingName
    case missingDescription
}

struct SkillParseResult: Sendable {
    let name: String
    let description: String
    let body: String
}

enum SkillParser {

    static func parse(content: String) throws -> SkillParseResult {
        let lines = content.components(separatedBy: "\n")

        // Find opening ---
        guard let openIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillParserError.noFrontmatter
        }

        // Find closing --- after the opening one
        let searchStart = openIndex + 1
        guard searchStart < lines.count,
              let closeIndex = lines[searchStart...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillParserError.missingClosingDelimiter
        }

        // Extract frontmatter lines
        let frontmatterLines = Array(lines[searchStart..<closeIndex])

        // Parse YAML fields
        let fields = parseYAMLFields(frontmatterLines)

        guard let name = fields["name"], !name.isEmpty else {
            throw SkillParserError.missingName
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParserError.missingDescription
        }

        // Body is everything after the closing delimiter
        let bodyStartIndex = closeIndex + 1
        let body: String
        if bodyStartIndex < lines.count {
            body = lines[bodyStartIndex...].joined(separator: "\n")
        } else {
            body = ""
        }

        return SkillParseResult(name: name, description: description, body: body)
    }

    private static func parseYAMLFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""
        var isMultiLine = false
        var multiLineStyle: Character?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check if this is a new top-level key (not indented continuation)
            if !trimmed.isEmpty, !trimmed.hasPrefix(" "), !trimmed.hasPrefix("\t"),
               let colonRange = trimmed.range(of: ":") {
                // Save previous key if any
                if let key = currentKey {
                    fields[key] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let key = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let afterColon = String(trimmed[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)

                if afterColon == ">" || afterColon == "|" {
                    // Multi-line scalar
                    currentKey = key
                    currentValue = ""
                    isMultiLine = true
                    multiLineStyle = afterColon.first
                } else {
                    currentKey = key
                    currentValue = normalizeScalarValue(afterColon)
                    isMultiLine = false
                    multiLineStyle = nil
                }
            } else if isMultiLine, let _ = currentKey {
                // Continuation line for multi-line value
                let stripped = trimmed
                if currentValue.isEmpty {
                    currentValue = stripped
                } else {
                    if multiLineStyle == "|" {
                        currentValue += "\n" + stripped
                    } else {
                        // Folded scalar: join with space
                        currentValue += " " + stripped
                    }
                }
            }
        }

        // Save the last key
        if let key = currentKey {
            fields[key] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return fields
    }

    private static func normalizeScalarValue(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
