import UIKit

/// Light UIKit haptics. Generators are reused + prepared for snappy feedback.
/// UIFeedbackGenerator is main-thread only → the whole namespace is main-actor isolated.
@MainActor
enum Haptics {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notifyGen = UINotificationFeedbackGenerator()

    /// Call early (e.g. feed appear) so the first swipe isn’t laggy.
    static func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        softImpact.prepare()
        rigidImpact.prepare()
        selectionGen.prepare()
        notifyGen.prepare()
    }

    static func light() {
        lightImpact.impactOccurred()
        lightImpact.prepare()
    }

    static func medium() {
        mediumImpact.impactOccurred()
        mediumImpact.prepare()
    }

    static func soft() {
        softImpact.impactOccurred()
        softImpact.prepare()
    }

    /// Vertical page tick (next / back).
    static func selection() {
        selectionGen.selectionChanged()
        selectionGen.prepare()
    }

    /// Double-tap / heart favorite.
    static func like() {
        mediumImpact.impactOccurred(intensity: 0.9)
        mediumImpact.prepare()
    }

    /// Rigid tick when left-swipe crosses the basket threshold (once per drag).
    static func basketThreshold() {
        rigidImpact.impactOccurred(intensity: 1.0)
        rigidImpact.prepare()
    }

    /// Left-swipe / trash into basket commit.
    static func basket() {
        mediumImpact.impactOccurred(intensity: 1.0)
        mediumImpact.prepare()
    }

    /// System delete confirmed → Recently Deleted.
    static func deleteSuccess() {
        notifyGen.notificationOccurred(.success)
        notifyGen.prepare()
    }

    /// User cancelled system dialog or soft failure.
    static func warning() {
        notifyGen.notificationOccurred(.warning)
        notifyGen.prepare()
    }
}
