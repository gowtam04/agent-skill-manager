import Foundation

struct SyncManifest: Codable, Sendable {
    var lastSyncDate: Date
    var lastSyncDeviceID: String
    var skills: [String: SyncManifestSkillEntry]
}

struct SyncManifestSkillEntry: Codable, Sendable {
    var isEnabled: Bool
    var files: [String: SyncManifestFileEntry]
}

struct SyncManifestFileEntry: Codable, Sendable {
    var contentHash: String
    var size: Int
    var modificationDate: Date
}

struct SyncConflict: Sendable {
    let skillName: String
    let reason: SyncConflictReason
}

enum SyncConflictReason: Sendable {
    case deletedRemotelyButModifiedLocally
    case deletedLocallyButModifiedRemotely
}

struct SyncReport: Sendable {
    var copiedToRemote: [String] = []
    var copiedToLocal: [String] = []
    var deletedFromRemote: [String] = []
    var deletedFromLocal: [String] = []
    var conflicts: [SyncConflict] = []
    var errors: [SyncError] = []
}

struct SyncError: Sendable {
    let skillName: String
    let message: String
}
