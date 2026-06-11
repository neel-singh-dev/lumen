import SwiftUI

/// The design system, prototype-scale: one grid, two radii, one accent,
/// fixed opacity steps, two curves. Every surface draws from here.
enum DT {
    static let radiusPanel: CGFloat = 18
    static let radiusWell: CGFloat = 10
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.25)

    static let accent = LinearGradient(
        colors: [.teal, .mint], startPoint: .top, endPoint: .bottom
    )

    enum Ink {
        static let primary = Color.white.opacity(0.92)
        static let secondary = Color.white.opacity(0.55)
        static let tertiary = Color.white.opacity(0.35)
        static let well = Color.white.opacity(0.06)
        static let hairline = Color.white.opacity(0.09)
    }
}
