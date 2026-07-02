import Foundation

/// Commands a remote (a second iOS device) can send to the prompter.
/// nonisolated: these cross isolation boundaries (delegate callbacks,
/// JSON decode on background queues) under MainActor default isolation.
nonisolated enum RemoteCommand: String, Codable, CaseIterable {
    case toggleRecord
    case toggleScroll
    case speedUp
    case speedDown
    case resetScroll
}

/// Latest-wins prompter state pushed to remotes. Elapsed recording time is
/// computed on the remote from `recordingStartedAt` — state is only pushed
/// when something actually changes, never once a second.
nonisolated struct RemoteState: Codable, Equatable {
    var isPrompterActive: Bool
    var isRecording: Bool
    var recordingStartedAt: Date?
    var isScrolling: Bool
    var scrollSpeed: Double

    static let inactive = RemoteState(
        isPrompterActive: false,
        isRecording: false,
        recordingStartedAt: nil,
        isScrolling: false,
        scrollSpeed: 60
    )
}

enum RemoteTransport {
    /// Bonjour service type for MultipeerConnectivity (must stay ≤ 15 chars
    /// and match NSBonjourServices in the app's Info.plist).
    static let serviceType = "inteleprompter"
}
