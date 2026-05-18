import Foundation

struct DiscoveredSkill: Sendable {
    let directoryURL: URL
    let isEnabled: Bool
    let isReadOnly: Bool
    let isSymlink: Bool
    let symlinkTarget: URL?
    let skillMDContent: String
    let fileTree: [FileTreeNode]
}

struct FileSystemManager: Sendable {

    let skillsDirectoryURL: URL
    let disabledDirectoryURL: URL?
    let additionalSkillsDirectoryURLs: [URL]
    let readOnlySkillsDirectoryURLs: [URL]

    init(
        skillsDirectoryURL: URL,
        disabledDirectoryURL: URL? = nil,
        additionalSkillsDirectoryURLs: [URL] = [],
        readOnlySkillsDirectoryURLs: [URL] = []
    ) {
        self.skillsDirectoryURL = skillsDirectoryURL
        self.disabledDirectoryURL = disabledDirectoryURL
        self.additionalSkillsDirectoryURLs = additionalSkillsDirectoryURLs
        self.readOnlySkillsDirectoryURLs = readOnlySkillsDirectoryURLs
    }

    // MARK: - Scanning

    func scanSkills() throws -> [DiscoveredSkill] {
        var results: [DiscoveredSkill] = []

        for directoryURL in skillScanDirectoryURLs {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                let enabledSkills = try scanDirectory(directoryURL, isEnabled: true, isReadOnly: false)
                results.append(contentsOf: enabledSkills)
            }
        }

        if let disabledDirectoryURL,
           FileManager.default.fileExists(atPath: disabledDirectoryURL.path) {
            let disabledSkills = try scanDirectory(disabledDirectoryURL, isEnabled: false, isReadOnly: false)
            results.append(contentsOf: disabledSkills)
        }

        for directoryURL in readOnlySkillScanDirectoryURLs {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                let readOnlySkills = try scanDirectory(directoryURL, isEnabled: true, isReadOnly: true)
                results.append(contentsOf: readOnlySkills)
            }
        }

        return results
    }

    var skillScanDirectoryURLs: [URL] {
        let urls = [skillsDirectoryURL] + additionalSkillsDirectoryURLs
        var seenPaths: Set<String> = []
        var uniqueURLs: [URL] = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else { continue }
            uniqueURLs.append(standardizedURL)
        }

        return uniqueURLs
    }

    var readOnlySkillScanDirectoryURLs: [URL] {
        uniqueURLs(readOnlySkillsDirectoryURLs)
    }

    var allSkillScanDirectoryURLs: [URL] {
        uniqueURLs(skillScanDirectoryURLs + readOnlySkillScanDirectoryURLs)
    }

    var anySkillsDirectoryExists: Bool {
        allSkillScanDirectoryURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func scanDirectory(_ directoryURL: URL, isEnabled: Bool, isReadOnly: Bool) throws -> [DiscoveredSkill] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var results: [DiscoveredSkill] = []

        for itemURL in contents {
            let skillMDURL = itemURL.appendingPathComponent("SKILL.md")

            // Only include directories that contain a SKILL.md
            guard fm.fileExists(atPath: skillMDURL.path) else { continue }

            let content = try String(contentsOf: skillMDURL, encoding: .utf8)
            let symlink = isSymlink(at: itemURL)
            let target: URL? = symlink ? (try? resolveSymlink(at: itemURL)) : nil

            let fileTree = enumerateSkillFiles(at: itemURL)

            results.append(DiscoveredSkill(
                directoryURL: itemURL,
                isEnabled: isEnabled,
                isReadOnly: isReadOnly,
                isSymlink: symlink,
                symlinkTarget: target,
                skillMDContent: content,
                fileTree: fileTree
            ))
        }

        return results
    }

    // MARK: - File Tree Enumeration

    func enumerateSkillFiles(at directoryURL: URL) -> [FileTreeNode] {
        enumerateDirectory(at: directoryURL, relativeTo: directoryURL)
    }

    private func enumerateDirectory(at url: URL, relativeTo root: URL) -> [FileTreeNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var nodes: [FileTreeNode] = []

        for itemURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = itemURL.lastPathComponent

            // Skip SKILL.md since it's already shown in the editor
            if name == "SKILL.md" { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: itemURL.path, isDirectory: &isDir)

            let relativePath = itemURL.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )

            if isDir.boolValue {
                let children = enumerateDirectory(at: itemURL, relativeTo: root)
                nodes.append(FileTreeNode(
                    id: relativePath,
                    name: name,
                    isDirectory: true,
                    children: children
                ))
            } else {
                nodes.append(FileTreeNode(
                    id: relativePath,
                    name: name,
                    isDirectory: false,
                    children: []
                ))
            }
        }

        return nodes
    }

    // MARK: - Existence Check

    func skillExists(named name: String) -> Bool {
        let fm = FileManager.default
        for directoryURL in allSkillScanDirectoryURLs {
            if fm.fileExists(atPath: directoryURL.appendingPathComponent(name).path) {
                return true
            }
        }

        if let disabledDirectoryURL {
            return fm.fileExists(atPath: disabledDirectoryURL.appendingPathComponent(name).path)
        }

        return false
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        var uniqueURLs: [URL] = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else { continue }
            uniqueURLs.append(standardizedURL)
        }

        return uniqueURLs
    }

    // MARK: - Copy

    func copySkill(from sourceURL: URL, to name: String) throws {
        let fm = FileManager.default
        let destinationURL = skillsDirectoryURL.appendingPathComponent(name)

        try ensureDirectoryExists(at: skillsDirectoryURL)

        // Remove existing if present
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    // MARK: - Move

    func moveSkill(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default

        // Check for naming conflict
        if fm.fileExists(atPath: destinationURL.path) {
            throw FileSystemManagerError.nameConflict(destinationURL.lastPathComponent)
        }

        try fm.moveItem(at: sourceURL, to: destinationURL)
    }

    // MARK: - Delete

    func deleteSkill(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Symlink Operations

    func isSymlink(at url: URL) -> Bool {
        let fm = FileManager.default
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            return attrs[.type] as? FileAttributeType == .typeSymbolicLink
        } catch {
            return false
        }
    }

    func resolveSymlink(at url: URL) throws -> URL {
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let resolvedURL: URL
        if resolved.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: resolved)
        } else {
            resolvedURL = url.deletingLastPathComponent().appendingPathComponent(resolved)
        }
        return resolvedURL.standardizedFileURL
    }

    func createSymlink(at symlinkURL: URL, pointingTo targetURL: URL) throws {
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
    }

    // MARK: - Export (Zip)

    func zipSkill(at sourceURL: URL, to destinationURL: URL) throws {
        // Resolve symlinks so the zip contains actual files
        let resolvedSource: URL
        if isSymlink(at: sourceURL) {
            resolvedSource = try resolveSymlink(at: sourceURL)
        } else {
            resolvedSource = sourceURL
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            resolvedSource.path, destinationURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw FileSystemManagerError.exportFailed(errorString)
        }
    }

    // MARK: - Directory Helpers

    func ensureDirectoryExists(at url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum FileSystemManagerError: Error, LocalizedError {
    case nameConflict(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .nameConflict(let name):
            return "A skill named '\(name)' already exists in the target directory."
        case .exportFailed(let detail):
            return "Failed to export skill: \(detail)"
        }
    }
}
