import Foundation

struct SyncSettings: Sendable {

    private static let syncFolderBookmarkKey = "syncFolderBookmark"
    private static let syncEnabledKey = "syncEnabled"
    private static let syncDeviceIDKey = "syncDeviceID"

    var syncFolderURL: URL? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.syncFolderBookmarkKey) else {
                return nil
            }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            if isStale {
                // Re-save the bookmark if stale
                if let freshData = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(freshData, forKey: Self.syncFolderBookmarkKey)
                }
            }
            return url
        }
        nonmutating set {
            if let url = newValue {
                if let data = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(data, forKey: Self.syncFolderBookmarkKey)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.syncFolderBookmarkKey)
            }
        }
    }

    var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.syncEnabledKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.syncEnabledKey) }
    }

    var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: Self.syncDeviceIDKey) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: Self.syncDeviceIDKey)
        return newID
    }
}
