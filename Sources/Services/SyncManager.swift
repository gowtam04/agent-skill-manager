import Foundation
import CryptoKit

struct SyncManager: Sendable {

    let localSkillsURL: URL
    let localDisabledURL: URL
    let syncSettings: SyncSettings

    func isSyncConfigured() -> Bool {
        syncSettings.isSyncEnabled && syncSettings.syncFolderURL != nil
    }

    // MARK: - Perform Sync

    func performSync() async throws -> SyncReport {
        guard let syncFolderURL = syncSettings.syncFolderURL else {
            throw SyncManagerError.syncFolderNotConfigured
        }

        let accessGranted = syncFolderURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { syncFolderURL.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        let remoteSkillsURL = syncFolderURL.appendingPathComponent("skills", isDirectory: true)
        let remoteDisabledURL = syncFolderURL.appendingPathComponent("skills-disabled", isDirectory: true)
        let manifestURL = syncFolderURL.appendingPathComponent(".sync-manifest.json")

        // Ensure remote directories exist
        try ensureDirectory(remoteSkillsURL)
        try ensureDirectory(remoteDisabledURL)

        // Load manifest
        let manifest = loadManifest(at: manifestURL)

        // Scan local and remote
        let localSkills = scanSkillsDirectory(localSkillsURL, isEnabled: true)
        let localDisabled = scanSkillsDirectory(localDisabledURL, isEnabled: false)
        let remoteSkills = scanSkillsDirectory(remoteSkillsURL, isEnabled: true)
        let remoteDisabled = scanSkillsDirectory(remoteDisabledURL, isEnabled: false)

        var localMap: [String: ScannedSkill] = [:]
        for s in localSkills + localDisabled { localMap[s.name] = s }

        var remoteMap: [String: ScannedSkill] = [:]
        for s in remoteSkills + remoteDisabled { remoteMap[s.name] = s }

        // Gather all skill names
        var allNames = Set(localMap.keys)
        allNames.formUnion(remoteMap.keys)
        if let manifestKeys = manifest?.skills.keys {
            allNames.formUnion(manifestKeys)
        }

        var report = SyncReport()
        var newManifestSkills: [String: SyncManifestSkillEntry] = [:]

        for name in allNames {
            let manifestEntry = manifest?.skills[name]
            let local = localMap[name]
            let remote = remoteMap[name]

            do {
                let result = try syncSkill(
                    name: name,
                    local: local,
                    remote: remote,
                    manifestEntry: manifestEntry,
                    remoteSkillsURL: remoteSkillsURL,
                    remoteDisabledURL: remoteDisabledURL
                )

                switch result.action {
                case .copiedToRemote:
                    report.copiedToRemote.append(name)
                case .copiedToLocal:
                    report.copiedToLocal.append(name)
                case .deletedFromRemote:
                    report.deletedFromRemote.append(name)
                case .deletedFromLocal:
                    report.deletedFromLocal.append(name)
                case .conflict(let conflict):
                    report.conflicts.append(conflict)
                case .noChange:
                    break
                case .removed:
                    // Don't add to new manifest
                    continue
                }

                if let entry = result.manifestEntry {
                    newManifestSkills[name] = entry
                }
            } catch {
                report.errors.append(SyncError(skillName: name, message: error.localizedDescription))
            }
        }

        // Save updated manifest
        let newManifest = SyncManifest(
            lastSyncDate: Date(),
            lastSyncDeviceID: syncSettings.deviceID,
            skills: newManifestSkills
        )
        try saveManifest(newManifest, to: manifestURL)

        return report
    }

    // MARK: - Three-Way Merge per Skill

    private func syncSkill(
        name: String,
        local: ScannedSkill?,
        remote: ScannedSkill?,
        manifestEntry: SyncManifestSkillEntry?,
        remoteSkillsURL: URL,
        remoteDisabledURL: URL
    ) throws -> SyncSkillResult {
        let fm = FileManager.default

        switch (manifestEntry != nil, local != nil, remote != nil) {

        // New local skill, not yet synced
        case (false, true, false):
            let local = local!
            let remoteDir = local.isEnabled
                ? remoteSkillsURL.appendingPathComponent(name)
                : remoteDisabledURL.appendingPathComponent(name)
            try copySkillDirectory(from: local.url, to: remoteDir)
            let entry = try buildManifestEntry(from: local.url, isEnabled: local.isEnabled)
            return SyncSkillResult(action: .copiedToRemote, manifestEntry: entry)

        // New remote skill, not yet local
        case (false, false, true):
            let remote = remote!
            let localDir = remote.isEnabled
                ? localSkillsURL.appendingPathComponent(name)
                : localDisabledURL.appendingPathComponent(name)
            try ensureDirectory(localSkillsURL)
            try ensureDirectory(localDisabledURL)
            try copySkillDirectory(from: remote.url, to: localDir)
            let entry = try buildManifestEntry(from: remote.url, isEnabled: remote.isEnabled)
            return SyncSkillResult(action: .copiedToLocal, manifestEntry: entry)

        // Both exist but no manifest — first sync with existing skills on both sides
        case (false, true, true):
            let local = local!
            let remote = remote!
            // Per-file merge with last-write-wins; local enabled state wins
            let entry = try mergeSkill(
                name: name,
                local: local,
                remote: remote,
                manifestEntry: nil,
                remoteSkillsURL: remoteSkillsURL,
                remoteDisabledURL: remoteDisabledURL
            )
            return SyncSkillResult(action: .noChange, manifestEntry: entry)

        // In manifest, local present, remote deleted
        case (true, true, false):
            let local = local!
            let localFiles = hashDirectory(local.url)
            let manifestFiles = manifestEntry!.files
            let localModified = filesModifiedSinceManifest(localFiles: localFiles, manifestFiles: manifestFiles)

            if localModified {
                // Conflict: deleted remotely but modified locally
                let entry = try buildManifestEntry(from: local.url, isEnabled: local.isEnabled)
                return SyncSkillResult(
                    action: .conflict(SyncConflict(skillName: name, reason: .deletedRemotelyButModifiedLocally)),
                    manifestEntry: entry
                )
            } else {
                // Delete local
                try fm.removeItem(at: local.url)
                return SyncSkillResult(action: .deletedFromLocal, manifestEntry: nil)
            }

        // In manifest, remote present, local deleted
        case (true, false, true):
            let remote = remote!
            let remoteFiles = hashDirectory(remote.url)
            let manifestFiles = manifestEntry!.files
            let remoteModified = filesModifiedSinceManifest(localFiles: remoteFiles, manifestFiles: manifestFiles)

            if remoteModified {
                // Conflict: deleted locally but modified remotely
                let entry = try buildManifestEntry(from: remote.url, isEnabled: remote.isEnabled)
                return SyncSkillResult(
                    action: .conflict(SyncConflict(skillName: name, reason: .deletedLocallyButModifiedRemotely)),
                    manifestEntry: entry
                )
            } else {
                // Delete remote
                try fm.removeItem(at: remote.url)
                return SyncSkillResult(action: .deletedFromRemote, manifestEntry: nil)
            }

        // Both gone — remove from manifest
        case (true, false, false):
            return SyncSkillResult(action: .removed, manifestEntry: nil)

        // In manifest, both present — compare and sync changes
        case (true, true, true):
            let local = local!
            let remote = remote!
            let entry = try mergeSkill(
                name: name,
                local: local,
                remote: remote,
                manifestEntry: manifestEntry,
                remoteSkillsURL: remoteSkillsURL,
                remoteDisabledURL: remoteDisabledURL
            )
            return SyncSkillResult(action: .noChange, manifestEntry: entry)

        // Neither in manifest nor present anywhere — shouldn't happen
        case (false, false, false):
            return SyncSkillResult(action: .removed, manifestEntry: nil)
        }
    }

    // MARK: - Per-File Merge

    private func mergeSkill(
        name: String,
        local: ScannedSkill,
        remote: ScannedSkill,
        manifestEntry: SyncManifestSkillEntry?,
        remoteSkillsURL: URL,
        remoteDisabledURL: URL
    ) throws -> SyncManifestSkillEntry {
        let localFiles = hashDirectory(local.url)
        let remoteFiles = hashDirectory(remote.url)
        let manifestFiles = manifestEntry?.files ?? [:]

        // Gather all file relative paths
        var allPaths = Set(localFiles.keys)
        allPaths.formUnion(remoteFiles.keys)
        allPaths.formUnion(manifestFiles.keys)

        let fm = FileManager.default

        for relativePath in allPaths {
            let localFile = localFiles[relativePath]
            let remoteFile = remoteFiles[relativePath]
            let manifestFile = manifestFiles[relativePath]

            let localSrcPath = local.url.appendingPathComponent(relativePath)
            let remoteSrcPath = remote.url.appendingPathComponent(relativePath)

            switch (manifestFile != nil, localFile != nil, remoteFile != nil) {
            // New local file
            case (false, true, false):
                try ensureParentDirectory(remoteSrcPath)
                try fm.copyItem(at: localSrcPath, to: remoteSrcPath)

            // New remote file
            case (false, false, true):
                try ensureParentDirectory(localSrcPath)
                try fm.copyItem(at: remoteSrcPath, to: localSrcPath)

            // Both new — last-write-wins by file modification date
            case (false, true, true):
                if localFile!.hash != remoteFile!.hash {
                    if localFile!.modificationDate >= remoteFile!.modificationDate {
                        try fm.removeItem(at: remoteSrcPath)
                        try fm.copyItem(at: localSrcPath, to: remoteSrcPath)
                    } else {
                        try fm.removeItem(at: localSrcPath)
                        try fm.copyItem(at: remoteSrcPath, to: localSrcPath)
                    }
                }

            // In manifest, local present, remote gone → delete local
            case (true, true, false):
                if localFile!.hash != manifestFile!.contentHash {
                    // Local modified but remote deleted — keep local, re-copy to remote
                    try ensureParentDirectory(remoteSrcPath)
                    try fm.copyItem(at: localSrcPath, to: remoteSrcPath)
                } else {
                    try fm.removeItem(at: localSrcPath)
                }

            // In manifest, remote present, local gone → delete remote
            case (true, false, true):
                if remoteFile!.hash != manifestFile!.contentHash {
                    // Remote modified but local deleted — keep remote, re-copy to local
                    try ensureParentDirectory(localSrcPath)
                    try fm.copyItem(at: remoteSrcPath, to: localSrcPath)
                } else {
                    try fm.removeItem(at: remoteSrcPath)
                }

            // Both gone
            case (true, false, false), (false, false, false):
                break

            // Both present — compare hashes
            case (_, true, true):
                let localChanged = manifestFile.map { localFile!.hash != $0.contentHash } ?? false
                let remoteChanged = manifestFile.map { remoteFile!.hash != $0.contentHash } ?? false

                if localFile!.hash == remoteFile!.hash {
                    // Already in sync
                } else if localChanged && !remoteChanged {
                    // Local changed → push to remote
                    try fm.removeItem(at: remoteSrcPath)
                    try fm.copyItem(at: localSrcPath, to: remoteSrcPath)
                } else if !localChanged && remoteChanged {
                    // Remote changed → pull to local
                    try fm.removeItem(at: localSrcPath)
                    try fm.copyItem(at: remoteSrcPath, to: localSrcPath)
                } else {
                    // Both changed — last-write-wins
                    if localFile!.modificationDate >= remoteFile!.modificationDate {
                        try fm.removeItem(at: remoteSrcPath)
                        try fm.copyItem(at: localSrcPath, to: remoteSrcPath)
                    } else {
                        try fm.removeItem(at: localSrcPath)
                        try fm.copyItem(at: remoteSrcPath, to: localSrcPath)
                    }
                }
            }
        }

        // Handle enabled/disabled state — local wins
        let isEnabled = local.isEnabled
        if remote.isEnabled != isEnabled {
            let fm = FileManager.default
            let newRemoteDir = isEnabled
                ? remoteSkillsURL.appendingPathComponent(name)
                : remoteDisabledURL.appendingPathComponent(name)
            if remote.url != newRemoteDir {
                try fm.moveItem(at: remote.url, to: newRemoteDir)
            }
        }

        return try buildManifestEntry(from: local.url, isEnabled: isEnabled)
    }

    // MARK: - Scanning

    private struct ScannedSkill {
        let name: String
        let url: URL
        let isEnabled: Bool
    }

    private func scanSkillsDirectory(_ directoryURL: URL, isEnabled: Bool) -> [ScannedSkill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [ScannedSkill] = []
        for itemURL in contents {
            let skillMD = itemURL.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMD.path) else { continue }
            // Skip .icloud placeholder files
            if itemURL.lastPathComponent.hasPrefix(".") && itemURL.lastPathComponent.hasSuffix(".icloud") {
                continue
            }
            results.append(ScannedSkill(
                name: itemURL.lastPathComponent,
                url: itemURL,
                isEnabled: isEnabled
            ))
        }
        return results
    }

    // MARK: - Hashing

    private struct HashedFile {
        let hash: String
        let size: Int
        let modificationDate: Date
    }

    private func hashDirectory(_ directoryURL: URL) -> [String: HashedFile] {
        let fm = FileManager.default
        var results: [String: HashedFile] = [:]

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ),
            values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(
                of: directoryURL.path + "/",
                with: ""
            )

            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let hash = SHA256.hash(data: data)
            let hashString = hash.map { String(format: "%02x", $0) }.joined()

            results[relativePath] = HashedFile(
                hash: hashString,
                size: values.fileSize ?? 0,
                modificationDate: values.contentModificationDate ?? Date.distantPast
            )
        }

        return results
    }

    private func filesModifiedSinceManifest(
        localFiles: [String: HashedFile],
        manifestFiles: [String: SyncManifestFileEntry]
    ) -> Bool {
        // Check if any file has a different hash from the manifest
        if localFiles.count != manifestFiles.count { return true }
        for (path, file) in localFiles {
            guard let manifestFile = manifestFiles[path] else { return true }
            if file.hash != manifestFile.contentHash { return true }
        }
        return false
    }

    // MARK: - Manifest I/O

    private func loadManifest(at url: URL) -> SyncManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncManifest.self, from: data)
    }

    private func saveManifest(_ manifest: SyncManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func buildManifestEntry(from directoryURL: URL, isEnabled: Bool) throws -> SyncManifestSkillEntry {
        let files = hashDirectory(directoryURL)
        var manifestFiles: [String: SyncManifestFileEntry] = [:]
        for (path, file) in files {
            manifestFiles[path] = SyncManifestFileEntry(
                contentHash: file.hash,
                size: file.size,
                modificationDate: file.modificationDate
            )
        }
        return SyncManifestSkillEntry(isEnabled: isEnabled, files: manifestFiles)
    }

    // MARK: - File Operations

    private func copySkillDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default

        // Resolve symlinks — copy actual files
        let resolvedSource: URL
        let attrs = try fm.attributesOfItem(atPath: source.path)
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            let resolved = try fm.destinationOfSymbolicLink(atPath: source.path)
            if resolved.hasPrefix("/") {
                resolvedSource = URL(fileURLWithPath: resolved)
            } else {
                resolvedSource = source.deletingLastPathComponent().appendingPathComponent(resolved)
            }
        } else {
            resolvedSource = source
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        try fm.copyItem(at: resolvedSource, to: destination)
    }

    private func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func ensureParentDirectory(_ fileURL: URL) throws {
        try ensureDirectory(fileURL.deletingLastPathComponent())
    }
}

// MARK: - Result Types

private struct SyncSkillResult {
    let action: SyncSkillAction
    let manifestEntry: SyncManifestSkillEntry?
}

private enum SyncSkillAction {
    case copiedToRemote
    case copiedToLocal
    case deletedFromRemote
    case deletedFromLocal
    case conflict(SyncConflict)
    case noChange
    case removed
}

// MARK: - Errors

enum SyncManagerError: Error, LocalizedError {
    case syncFolderNotConfigured
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .syncFolderNotConfigured:
            return "Sync folder is not configured. Open Settings to set up iCloud sync."
        case .syncInProgress:
            return "A sync operation is already in progress."
        }
    }
}
