import AppKit
import SwiftUI

/// The result of Capture & Translate Text: the translation with Copy and Close, the original folded
/// underneath. Esc closes it. One at a time.
@MainActor
enum TranslationPanel {
    private static var current: TranslationPanelController?

    /// Shows `translation` next to `area` (global Cocoa coordinates), where the text was.
    static func show(_ translation: TextTranslation, near area: CGRect) {
        current?.close()
        let controller = TranslationPanelController(translation: translation) { current = nil }
        current = controller
        controller.present(near: area)
    }
}

@MainActor
private final class TranslationPanelController {
    private let translation: TextTranslation
    private let released: () -> Void
    private let panel: FloatingPanel
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var closing = false

    init(translation: TextTranslation, released: @escaping () -> Void) {
        self.translation = translation
        self.released = released
        panel = FloatingPanel(frame: .zero, level: .floating, canBeKey: true, activatesOnClick: true)
    }

    func present(near area: CGRect) {
        previousApp = FocusKeeper.frontmostExternal()
        // The hosting view keeps the panel the size of its content, so unfolding the original grows it.
        let host = NSHostingView(rootView: TranslationView(translation: translation, copy: { [weak self] in self?.copy() },
                                                           close: { [weak self] in self?.close() }))
        panel.contentView = host
        let screen = NSScreen.at(CGPoint(x: area.midX, y: area.midY))
        let frame = Placement.barFrame(size: host.fittingSize, near: area, on: screen)
        panel.setFrame(frame, display: false)
        panel.present(makeKey: true, from: frame.offsetBy(dx: 0, dy: -10))
        FocusKeeper.activateSelf()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            let consumed = MainActor.assumeIsolated {
                guard box.event.window === self.panel, Int(box.event.keyCode) == 53 else { return false } // Esc
                self.close()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func copy() {
        Clipboard.copyText(translation.text)
        Toast.show("Translation copied", symbol: "doc.on.clipboard")
    }

    func close() {
        guard !closing else { return }
        closing = true
        released()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let previousApp = previousApp
        let panel = panel
        panel.dismiss {
            // Only when Screenme still holds focus because of this panel.
            guard NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === panel else { return }
            Task { @MainActor in await FocusKeeper.restore(previousApp) }
        }
    }
}

private struct TranslationView: View {
    let translation: TextTranslation
    let copy: () -> Void
    let close: () -> Void
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(TextTranslator.name(of: translation.source)) → \(TextTranslator.name(of: translation.target))",
                  systemImage: "translate")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(translation.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Original", isExpanded: $showsOriginal) {
                ScrollView {
                    Text(translation.original)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11, weight: .medium))

            HStack {
                Text("Copied to clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close)
                Button("Copy", action: copy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(VisualEffectBackground(material: .popover).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
