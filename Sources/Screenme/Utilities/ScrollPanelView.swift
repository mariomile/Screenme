import AppKit
import SwiftUI

/// The scrolling capture panel: live preview on the left, message and controls on the right.
struct ScrollPanelView: View {
    @ObservedObject var session: ScrollSession

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
            Divider().opacity(0.5)
            controls
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: Preview

    private var previewColumn: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if let preview = session.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 22, weight: .light))
                    Text("Live preview")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if session.rows > 0 {
                Text("\(session.rows.formatted()) px")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(12)
        .frame(width: 136)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .foregroundStyle(Color.accentColor)
                Text("Scrolling Capture").font(.system(size: 13, weight: .semibold))
                if session.phase == .capturing {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 14)

            Text(session.status)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: session.status)

            Spacer(minLength: 8)

            VStack(spacing: 7) {
                Button { Task { await session.toggleAutoScroll() } } label: {
                    Label(session.isAutoScrolling ? "Stop Auto-scroll" : "Auto-scroll",
                          systemImage: session.isAutoScrolling ? "stop.fill" : "arrow.down.to.line")
                }
                .buttonStyle(ScrollPanelButtonStyle(kind: .secondary))
                .disabled(session.phase != .capturing)

                Button { Task { await session.done() } } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(ScrollPanelButtonStyle(kind: .primary))
                .disabled(session.phase != .capturing)

                Button("Cancel") { Task { await session.cancel() } }
                    .buttonStyle(ScrollPanelButtonStyle(kind: .plain))
                    .disabled(session.phase == .finishing)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScrollPanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .primary
        case .plain: .secondary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Color.accentColor.opacity(pressed ? 0.75 : 1)
        case .secondary: Color.primary.opacity(pressed ? 0.16 : 0.09)
        case .plain: Color.primary.opacity(pressed ? 0.08 : 0)
        }
    }
}
