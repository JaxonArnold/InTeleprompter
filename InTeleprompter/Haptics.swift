import UIKit

/// Centralized haptic feedback, with one generator per style so repeated
/// triggers stay cheap.
enum Haptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notifier = UINotificationFeedbackGenerator()

    /// Small UI acknowledgements: play/pause, toggles, countdown ticks.
    static func tap() { light.impactOccurred() }

    /// Significant moments: recording starts or stops.
    static func action() { medium.impactOccurred() }

    /// Gentle background cue: voice tracking locked back onto the script.
    static func lock() { soft.impactOccurred(intensity: 0.7) }

    /// Something needs attention: interruptions, failures.
    static func warning() { notifier.notificationOccurred(.warning) }
}
