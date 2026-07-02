import Foundation

/// Hand-off between the share extension and the app: the extension can't
/// touch the app's Documents, so it stages imported scripts as JSON in the
/// shared App Group container; the app drains the box on launch, whenever it
/// becomes active, and when its URL scheme is opened.
enum PendingScripts {

    static let appGroupID = "group.jack.InTeleprompter"

    /// The shared container. Mutable and internal so tests can point it at a
    /// plain temp directory — simulator builds have no registered App Group,
    /// so the container doesn't exist there. (On device, automatic signing
    /// registers the group and this is always non-nil.)
    static var containerURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent("pending-scripts.json")
    }

    /// Called by the share extension: stage a script for the main app.
    /// Returns false when the shared container is unavailable.
    @discardableResult
    static func stage(_ script: Script) -> Bool {
        guard let url = fileURL else { return false }
        var pending = (try? JSONDecoder().decode([Script].self, from: Data(contentsOf: url))) ?? []
        pending.append(script)
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        // Scripts are user content; keep them encrypted at rest.
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    /// Called by the main app: take out everything the extension staged.
    static func drain() -> [Script] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode([Script].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return pending
    }
}
