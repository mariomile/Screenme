import AppKit
import SwiftUI

// MARK: - Color bridging

extension RGBA {
    var color: Color { Color(nsColor: nsColor) }
}

// MARK: - Root

struct EditorRootView: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CanvasHost(controller: c)
                    .overlay(alignment: .bottomTrailing) { ZoomControls(c: c).padding(12) }
                Divider()
                InspectorBar(c: c)
            }
            if c.state.background.enabled {
                Divider()
                BackgroundPanel(c: c)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: c.state.background.enabled)
        .frame(minWidth: 980, minHeight: 600)
        .sheet(item: $c.sheet) { sheet in
            switch sheet {
            case .resizeImage: ResizeImageSheet(c: c)
            case .resizeCanvas: ResizeCanvasSheet(c: c)
            }
        }
    }
}

struct CanvasHost: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> CanvasView { CanvasView(controller: controller) }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

// MARK: - Toolbar groups

struct ToolbarLeading: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)\nTakes back your last change.", enabled: c.canUndo) { c.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)\nBrings back what you undid.", enabled: c.canRedo) { c.redo() }
        }
        .padding(.horizontal, 2)
    }
}

struct ToolPalette: View {
    @ObservedObject var c: EditorController

    private static let groups: [[ToolChoice]] = [
        [.select], [.draw(.arrow), .draw(.line), .draw(.rectangle), .draw(.ellipse)],
        [.draw(.text), .draw(.pen), .draw(.highlighter), .draw(.counter)],
        [.draw(.pixelate), .draw(.blur), .draw(.spotlight)], [.crop],
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 18) }
                HStack(spacing: 1) {
                    ForEach(group) { tool in
                        ToolButton(tool: tool, selected: c.mode.choice == tool) { c.choose(tool) }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct ToolButton: View {
    let tool: ToolChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tool.tooltip)
        .accessibilityLabel(tool.title)
    }
}

struct ToolbarTrailing: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "eye.slash", help: "Redact Sensitive Info: pixelate emails, phone numbers, cards, IBANs, keys, IPs and faces",
                       enabled: !c.isRedacting) { c.redactSensitiveInfo() }

            Button {
                c.toggleBackground()
            } label: {
                Label("Background", systemImage: "photo.artframe")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .foregroundStyle(c.state.background.enabled ? Color.accentColor : Color.primary.opacity(0.85))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(c.state.background.enabled ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Background\nWraps the screenshot in padding, a gradient or wallpaper, rounded corners and a shadow, ready to post.")

            Menu {
                Button("Save As…") { c.saveAs() }
                Divider()
                Button("Redact Sensitive Info") { c.redactSensitiveInfo() }
                    .disabled(c.isRedacting)
                Divider()
                Button("Resize Image…") { c.sheet = .resizeImage }
                Button("Resize Canvas…") { c.sheet = .resizeCanvas }
                Button("Reset Crop") { c.resetCrop() }
                    .disabled(c.state.cropRect == c.source.bounds)
                Divider()
                Button("Zoom In") { c.zoomIn() }
                Button("Zoom Out") { c.zoomOut() }
                Button("Fit to Window") { c.zoomFit() }
                Button("Actual Size") { c.zoomActual() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More\nSave As, resize the image or canvas, reset the crop, zoom.")

            DragThumb(controller: c)
                .frame(width: 44, height: 30)

            IconButton(symbol: "doc.on.doc", help: Prefs[Pref.editorCloseAfterCopy] ? "Copy (⌘C)\nPuts the edited image on the clipboard, saves it and closes the editor." : "Copy (⌘C)\nPuts the edited image on the clipboard without closing the editor.", enabled: true) { c.copyImage() }
            IconButton(symbol: "sparkles", help: "Copy for AI (⇧⌘C)\nCopies the edited image with its context for Claude, ChatGPT or Cursor: the app and page it came from, your notes on annotations and the text in it. Hides sensitive info first if Settings > Screenshots says so.", enabled: true) { c.copyForAI() }
            IconButton(symbol: "square.and.arrow.up", help: "Share\nSends the edited image with AirDrop, Messages, Mail and more. Hides sensitive info first if Settings > Screenshots says so.", enabled: true) { if let url = c.dragFile() { Share.show(url) } }

            Button("Done") { c.save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Done (⌘S or Return)\nSaves your edits into the capture and closes the editor.")
        }
        .padding(.horizontal, 2)
    }
}

/// A slider whose whole drag is one undo step. `apply` changes the document without committing.
struct EditSlider: View {
    @ObservedObject var c: EditorController
    let value: Double
    let range: ClosedRange<Double>
    let apply: (Double) -> Void
    @State private var before: EditorController.Checkpoint?

    var body: some View {
        Slider(value: Binding(get: { value }, set: change), in: range) { editing in
            if editing {
                before = c.checkpoint()
            } else if let before {
                self.before = nil
                c.commit(since: before)
                c.focusCanvas()
            }
        }
    }

    /// A change outside a drag (the keyboard, a click on the track) is a step of its own.
    private func change(_ newValue: Double) {
        guard before == nil else { return apply(newValue) }
        let start = c.checkpoint()
        apply(newValue)
        c.commit(since: start)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(Color.primary.opacity(enabled ? 0.85 : 0.28))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Zoom

struct ZoomControls: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", help: "Zoom out (⌘-)\nShows more of the image. Edits are unaffected.") { c.zoomOut() }
            Button { c.zoomFit() } label: {
                Text("\(c.zoomPercent)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to window (⌘0)\nShows the whole image. Click to reset the zoom.")
            IconButton(symbol: "plus", help: "Zoom in (⌘+)\nFor precise placement. Edits are unaffected.") { c.zoomIn() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Drag out

struct DragThumb: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> DragThumbView { DragThumbView(controller: controller) }
    func updateNSView(_ nsView: DragThumbView, context: Context) {}
}

/// A small preview of the image. Dragging it out hands the flattened picture to any app as a file.
@MainActor
final class DragThumbView: NSView, NSDraggingSource {
    private let controller: EditorController
    private let thumbnail: NSImage
    private var dragging = false

    init(controller: EditorController) {
        self.controller = controller
        thumbnail = controller.source.thumbnail(maxPixels: 160)
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
        toolTip = "Drag out\nDrag the finished image straight into any app, chat or folder."
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 1, dy: 1)
        let size = thumbnail.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(area.width / size.width, area.height / size.height)
        let target = NSRect(x: area.midX - size.width * scale / 2, y: area.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        let path = NSBezierPath(roundedRect: target, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        thumbnail.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let url = controller.dragFile() else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
