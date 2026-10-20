import AppKit
import SwiftUI

// MARK: - Small views

/// A keyboard shortcut drawn as separate keycaps: "⇧ ⌘ 4".
struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.parts(combo).enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .frame(minWidth: size * 1.7)
                    .padding(.horizontal, part.count > 1 ? 4 : 0)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.display)
    }

    static func parts(_ combo: KeyCombo) -> [String] {
        let display = combo.display
        let modifiers = display.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = String(display.dropFirst(modifiers.count))
        return modifiers.map(String.init) + [key]
    }
}

/// A rounded-square symbol tile, like the icons in System Settings.
struct SymbolTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// "Granted", "Not allowed", etc. as a colored label.
struct StatusLabel: View {
    enum Tone { case good, warning, neutral }
    let text: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var symbol: String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "circle.dashed"
        }
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

/// One permission: icon, what it is for, live status, and one button titled from the status.
struct PermissionRow: View {
    let permission: Permission
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: permission.symbol, color: permission.color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.body.weight(.medium))
                Text(permission.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if permissions.isGranted(permission) {
                StatusLabel(text: permission.statusText, tone: .good)
            } else {
                HStack(spacing: 8) {
                    StatusLabel(text: permission.statusText, tone: .neutral)
                    Button(permission.requestTitle) { permission.request() }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Live polling while a view is on screen.
struct PollingModifier: ViewModifier {
    let interval: TimeInterval
    let tick: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: tick)
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in tick() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick() }
    }
}

extension View {
    func polling(every interval: TimeInterval = 1, _ tick: @escaping () -> Void) -> some View {
        modifier(PollingModifier(interval: interval, tick: tick))
    }
}
