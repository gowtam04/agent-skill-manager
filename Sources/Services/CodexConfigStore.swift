import Foundation

struct CodexConfigStore: Sendable {

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func disabledSkillMDPaths() throws -> Set<String> {
        let config = try loadConfig()
        return Set(config.blocks.compactMap { block in
            guard block.enabled == false, let path = block.path else {
                return nil
            }
            return normalizePath(path)
        })
    }

    func disableSkill(at skillMDURL: URL, alternateSkillMDURLs: [URL] = []) throws {
        try upsertDisabledOverride(
            primarySkillMDURL: skillMDURL,
            matchingSkillMDURLs: [skillMDURL] + alternateSkillMDURLs
        )
    }

    func enableSkill(at skillMDURL: URL, alternateSkillMDURLs: [URL] = []) throws {
        try removeOverrides(for: [skillMDURL] + alternateSkillMDURLs)
    }

    func removeOverrides(for skillMDURLs: [URL]) throws {
        var config = try loadConfig()
        let matchingPaths = Set(skillMDURLs.map(normalizePath))
        let matchingBlockIndices = config.blocks
            .enumerated()
            .compactMap { pair -> Int? in
                let (index, block) = pair
                guard let path = block.path else { return nil }
                return matchingPaths.contains(normalizePath(path)) ? index : nil
            }

        guard !matchingBlockIndices.isEmpty else { return }

        removeBlocks(at: matchingBlockIndices, from: &config)
        try saveConfig(config)
    }

    // MARK: - Config Parsing

    private func loadConfig() throws -> ParsedCodexConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ParsedCodexConfig(lines: [])
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return ParsedCodexConfig(lines: lines, blocks: parseBlocks(lines))
    }

    private func parseBlocks(_ lines: [String]) -> [CodexSkillsConfigBlock] {
        var blocks: [CodexSkillsConfigBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "[[skills.config]]" {
                let startLine = index
                var endLineExclusive = lines.count
                var cursor = index + 1

                while cursor < lines.count {
                    let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") && !trimmed.isEmpty {
                        endLineExclusive = cursor
                        break
                    }
                    if trimmed.isEmpty {
                        if let nextNonEmptyIndex = nextNonEmptyLineIndex(after: cursor, in: lines) {
                            let nextTrimmed = lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces)
                            if nextTrimmed.hasPrefix("[") || !isSkillsConfigLine(nextTrimmed) {
                                endLineExclusive = cursor + 1
                                break
                            }
                        } else {
                            endLineExclusive = cursor + 1
                            break
                        }
                    }
                    cursor += 1
                }

                var path: String?
                var enabled: Bool?

                for line in lines[startLine..<endLineExclusive] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if path == nil, let parsedPath = parseQuotedValue(for: "path", in: trimmed) {
                        path = parsedPath
                    } else if enabled == nil, let parsedEnabled = parseBooleanValue(for: "enabled", in: trimmed) {
                        enabled = parsedEnabled
                    }
                }

                blocks.append(CodexSkillsConfigBlock(
                    startLine: startLine,
                    endLineExclusive: endLineExclusive,
                    path: path,
                    enabled: enabled
                ))
                index = endLineExclusive
            } else {
                index += 1
            }
        }

        return blocks
    }

    private func nextNonEmptyLineIndex(after index: Int, in lines: [String]) -> Int? {
        var cursor = index + 1
        while cursor < lines.count {
            if !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private func isSkillsConfigLine(_ line: String) -> Bool {
        line.hasPrefix("#")
            || parseQuotedValue(for: "path", in: line) != nil
            || parseBooleanValue(for: "enabled", in: line) != nil
    }

    private func parseQuotedValue(for key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key)") else { return nil }
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard value.first == "\"", value.last == "\"", value.count >= 2 else {
            return nil
        }
        return String(value.dropFirst().dropLast())
    }

    private func parseBooleanValue(for key: String, in line: String) -> Bool? {
        guard line.hasPrefix("\(key)") else { return nil }
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        switch value {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    // MARK: - Updates

    private func upsertDisabledOverride(primarySkillMDURL: URL, matchingSkillMDURLs: [URL]) throws {
        var config = try loadConfig()
        let matchingPaths = Set(matchingSkillMDURLs.map(normalizePath))
        let matchingBlockIndices = config.blocks
            .enumerated()
            .compactMap { pair -> Int? in
                let (index, block) = pair
                guard let path = block.path else { return nil }
                return matchingPaths.contains(normalizePath(path)) ? index : nil
            }

        removeBlocks(at: matchingBlockIndices, from: &config)

        if !config.lines.isEmpty && !(config.lines.last?.isEmpty ?? true) {
            config.lines.append("")
        }

        config.lines.append("[[skills.config]]")
        config.lines.append("path = \"\(primarySkillMDURL.standardizedFileURL.path)\"")
        config.lines.append("enabled = false")
        config.lines.append("")
        config.blocks = parseBlocks(config.lines)

        try saveConfig(config)
    }

    private func removeBlocks(at indices: [Int], from config: inout ParsedCodexConfig) {
        guard !indices.isEmpty else { return }

        for index in indices.sorted(by: >) {
            let block = config.blocks[index]
            config.lines.removeSubrange(block.startLine..<block.endLineExclusive)
        }

        config.blocks = parseBlocks(config.lines)
    }

    private func saveConfig(_ config: ParsedCodexConfig) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        let content = config.lines.joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func normalizePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private struct ParsedCodexConfig {
    var lines: [String]
    var blocks: [CodexSkillsConfigBlock]

    init(lines: [String], blocks: [CodexSkillsConfigBlock] = []) {
        self.lines = lines
        self.blocks = blocks
    }
}

private struct CodexSkillsConfigBlock {
    let startLine: Int
    let endLineExclusive: Int
    let path: String?
    let enabled: Bool?
}
