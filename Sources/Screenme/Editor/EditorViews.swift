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
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", enabled: c.canUndo) { c.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: c.canRedo) { c.redo() }
        }
        .padding(.horizontal, 2)
    }
}

struct ToolPalette: View {
    @ObservedObject var c: EditorController

    private static let groups: [[ToolKind]] = [
        [.select], [.arrow, .line, .rectangle, .ellipse], [.text, .pen, .highlighter, .counter],
        [.pixelate, .blur, .spotlight], [.crop],
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 18) }
                HStack(spacing: 1) {
                    ForEach(group) { tool in
                        ToolButton(tool: tool, selected: c.tool == tool) { c.tool = tool }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct ToolButton: View {
    let tool: ToolKind
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
            .help("Wrap the screenshot in a background (padding, gradient, shadow)")

            Menu {
                Button("Save As…") { c.saveAs() }
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
            .help("Image options")

            DragThumb(controller: c)
                .frame(width: 44, height: 30)

            IconButton(symbol: "doc.on.doc", help: "Copy to clipboard (⌘C)", enabled: true) { c.copyImage() }

            Button("Done") { c.save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Save and close (⌘S or Return)")
        }
        .padding(.horizontal, 2)
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
            IconButton(symbol: "minus", help: "Zoom out (⌘-)") { c.zoomOut() }
            Button { c.zoomFit() } label: {
                Text("\(c.zoomPercent)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to window (⌘0)")
            IconButton(symbol: "plus", help: "Zoom in (⌘+)") { c.zoomIn() }
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
        toolTip = "Drag the finished image into any app"
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

// MARK: - Inspector

struct InspectorBar: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if c.tool == .crop {
                    CropControls(c: c)
                } else if let kind = c.contextKind, let style = c.contextStyle {
                    ScrollView(.horizontal, showsIndicators: false) {
                        StyleControls(c: c, kind: kind, style: style)
                            .padding(.vertical, 8)
                    }
                } else if c.selection.count > 1 {
                    Text("\(c.selection.count) items selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pick a tool, or click an annotation to edit its style.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if !c.selection.isEmpty && c.tool != .crop { SelectionActions(c: c) }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }
}

private struct SelectionActions: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "square.3.layers.3d.top.filled", help: "Bring forward (⌘])") { c.arrange(.forward) }
            IconButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send backward (⌘[)") { c.arrange(.backward) }
            IconButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)") { c.duplicateSelection() }
            IconButton(symbol: "trash", help: "Delete (⌫)") { c.deleteSelection() }
        }
    }
}

private struct CropControls: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 14) {
            Text("Aspect")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Aspect", selection: Binding(get: { c.cropAspect }, set: { c.setCropAspect($0) })) {
                ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            Button("Reset") { c.resetCropSelection() }
            Spacer()
            Button("Cancel") { c.cancelCrop() }
                .keyboardShortcut(.cancelAction)
            Button("Apply Crop") { c.applyCrop() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct StyleControls: View {
    @ObservedObject var c: EditorController
    let kind: ToolKind
    let style: ToolStyle

    private func bind<T>(_ keyPath: WritableKeyPath<ToolStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: keyPath] }, set: { value in c.updateStyle { $0[keyPath: keyPath] = value } })
    }

    private func slider(_ keyPath: WritableKeyPath<ToolStyle, Double>, in range: ClosedRange<Double>) -> some View {
        Slider(value: Binding(get: { style[keyPath: keyPath] }, set: { value in c.updateStyle(live: true) { $0[keyPath: keyPath] = value } }),
               in: range) { editing in
            if editing { c.beginChange() } else { c.endChange() }
        }
        .frame(width: 120)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var hasColor: Bool { !(kind.isRedaction || kind == .spotlight) }
    private var hasSize: Bool {
        switch kind {
        case .arrow, .line, .pen, .highlighter, .counter: true
        case .rectangle, .ellipse: !style.filled
        default: false
        }
    }
    private var hasShadow: Bool { [.arrow, .line, .rectangle, .ellipse, .text, .pen, .counter].contains(kind) }

    var body: some View {
        HStack(spacing: 14) {
            if hasColor {
                ColorSwatches(c: c, selected: style.color)
            }
            if hasSize {
                divider
                SizePicker(selection: bind(\.sizeIndex))
            }

            switch kind {
            case .arrow:
                divider
                Picker("Style", selection: bind(\.curved)) {
                    Text("Straight").tag(false)
                    Text("Curved").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                toggle("Outline", symbol: "square.dashed", isOn: bind(\.outline))
            case .line:
                divider
                toggle("Dashed", symbol: "line.3.horizontal", isOn: bind(\.dashed))
            case .rectangle, .ellipse:
                divider
                Picker("Fill", selection: bind(\.filled)) {
                    Text("Outline").tag(false)
                    Text("Filled").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if kind == .rectangle { toggle("Rounded", symbol: "rectangle.roundedtop", isOn: bind(\.rounded)) }
                HStack(spacing: 6) { caption("Opacity"); slider(\.opacity, in: 0.1...1) }
            case .text:
                divider
                HStack(spacing: 6) {
                    caption("Size")
                    Text("\(Int(style.fontSize))")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 26, alignment: .trailing)
                    Stepper("", value: bind(\.fontSize), in: 8...200, step: 2).labelsHidden()
                }
                Picker("Weight", selection: bind(\.weight)) {
                    ForEach(FontWeightChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                Picker("Backdrop", selection: bind(\.backdrop)) {
                    ForEach(TextBackdrop.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            case .highlighter:
                divider
                HStack(spacing: 6) { caption("Opacity"); slider(\.opacity, in: 0.2...1) }
            case .pixelate, .blur:
                HStack(spacing: 8) {
                    caption(kind == .pixelate ? "Pixel size" : "Blur")
                    slider(\.intensity, in: 0...1)
                }
            case .spotlight:
                Picker("Shape", selection: bind(\.ellipseSpot)) {
                    Text("Rectangle").tag(false)
                    Text("Ellipse").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack(spacing: 6) { caption("Dim"); slider(\.dim, in: 0.15...0.95) }
            default:
                EmptyView()
            }

            if hasShadow {
                divider
                toggle("Shadow", symbol: "shadow", isOn: bind(\.shadow))
            }
        }
        .padding(.horizontal, 2)
    }

    private var divider: some View { Divider().frame(height: 22) }

    private func toggle(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol).labelStyle(.titleOnly)
        }
        .toggleStyle(.button)
        .controlSize(.regular)
    }
}

private struct SizePicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("Size", selection: $selection) {
            Text("S").tag(0)
            Text("M").tag(1)
            Text("L").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
    }
}

private struct ColorSwatches: View {
    @ObservedObject var c: EditorController
    let selected: RGBA

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(Palette.presets.enumerated()), id: \.offset) { _, color in
                Button {
                    c.updateStyle { $0.color = color }
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                .opacity(isSelected(color) ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help("Color")
            }
            ColorPicker("Custom color", selection: Binding(
                get: { selected.color },
                set: { new in c.setColorLive(RGBA(NSColor(new)).with(alpha: 1)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Custom color")
        }
    }

    private func isSelected(_ color: RGBA) -> Bool {
        abs(color.r - selected.r) < 0.004 && abs(color.g - selected.g) < 0.004 && abs(color.b - selected.b) < 0.004
    }
}
