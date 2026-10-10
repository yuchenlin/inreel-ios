import SwiftUI

enum Theme {
    static let background = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    /// Warm off-white / pale amber accent — not neon, not "cleaner tool" green/red.
    static let accent = Color(red: 0.96, green: 0.76, blue: 0.62)
    /// Soft bottom veil — content-first, not a heavy chrome slab.
    static let overlayGradient = LinearGradient(
        colors: [.clear, .black.opacity(0.28), .black.opacity(0.62)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Floating control plate (date / side actions).
    static let floatingFill = Color.black.opacity(0.32)
    /// Lift above the home-indicator baseline (safe-area bottom) to clear the pill.
    /// Layout: FloatingTabBar bottom pad 8 + capsule (~52) + content gap 20 ≈ 80.
    /// Gap was 8 in b40 — Feed 64pt side-action circles still sat in the pill band (~8pt).
    /// Shared by Basket delete CTA / empty hint and non-feed list insets — no double-count.
    static let floatingTabClearance: CGFloat = 80
    /// Full-bleed (ignoresSafeArea .bottom) chrome when the pill is visible:
    /// home-indicator (~34) + floatingTabClearance → meta/actions clear pill by ~20pt.
    static var floatingTabChromeBottomPad: CGFloat { 34 + floatingTabClearance }
}
