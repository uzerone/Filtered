import SwiftUI
import AppKit

/// Central motion + spacing tokens so the whole app moves as one system.
/// Spring values follow Apple's shipped params (Designing Fluid Interfaces):
/// default UI is critically damped (no overshoot); momentum interactions get a
/// little bounce. response = how fast it reaches target; dampingFraction = overshoot.
enum Motion {
    /// Default UI transition — snappy, no overshoot. (response 0.35, damping 1.0)
    static let ui = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Selection / small state changes — quick.
    static let quick = Animation.spring(response: 0.26, dampingFraction: 1.0)
    /// Momentum / add-remove — slight bounce so it feels physical. (damping ~0.82)
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.82)
    /// Content fade for reduced-motion fallback.
    static let fade = Animation.easeOut(duration: 0.2)
}

extension EnvironmentValues {
    /// Reduced-motion-aware default UI animation: springs become a gentle fade
    /// when the user has "Reduce Motion" on (Apple §14).
    var uiMotion: Animation {
        accessibilityReduceMotion ? Motion.fade : Motion.ui
    }
    var quickMotion: Animation {
        accessibilityReduceMotion ? Motion.fade : Motion.quick
    }
    var bouncyMotion: Animation {
        accessibilityReduceMotion ? Motion.fade : Motion.bouncy
    }
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let card: CGFloat = 10
    static let control: CGFloat = 8
    static let chip: CGFloat = 6
}

/// Genuine macOS vibrancy (NSVisualEffectView) — the authentic translucent
/// material behind sidebars/inspectors, not a flat gray approximation.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

extension View {
    /// Card surface used for layers and filters — a light translucent material
    /// with a subtle border; highlighted when selected.
    func cardSurface(selected: Bool = false, cornerRadius: CGFloat = Radius.card) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                   : AnyShapeStyle(.quaternary.opacity(0.35)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.9)
                                           : Color.primary.opacity(0.06),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: selected ? .accentColor.opacity(0.12) : .clear, radius: 6, y: 2)
    }

    /// A pressable scale effect that responds on press-down (Apple §1: feedback on
    /// pointer-down, not release), critically damped.
    func pressable() -> some View {
        buttonStyle(PressableButtonStyle())
    }
}

/// Button style that scales down instantly on press and springs back — the
/// "respond on pointer-down" rule.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1.0), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Section header per Apple typography guidance (§15): uppercase, tight tracking,
/// secondary weight — builds hierarchy from weight, not just size.
struct SectionHeader: View {
    let title: String
    var accessory: AnyView? = nil
    init(_ title: String, accessory: AnyView? = nil) {
        self.title = title; self.accessory = accessory
    }
    var body: some View {
        HStack {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .tracking(0.6)                 // small text → slight positive tracking
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let accessory { accessory }
        }
    }
}
