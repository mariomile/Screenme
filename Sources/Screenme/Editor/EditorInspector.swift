import AppKit
import SwiftUI

/// The bar under the canvas: style controls for the selection or the active tool, crop controls, and
/// actions on the selection.
struct InspectorBar: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let session = c.mode.crop {
                    CropControls(c: c, session: session)
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
            if c.mode.crop == nil, c.selection.count == 1, let annotation = c.selectedAnnotations.first {
                NoteField(c: c, annotation: annotation)
            }
            if !c.selection.isEmpty && c.mode.crop == nil { SelectionActions(c: c) }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }
}

/// The note on the selected annotation: what the user wants done there. Copy for AI lists it; it is not drawn.
private struct NoteField: View {
    @ObservedObject var c: EditorController
    let annotation: Annotation

    var body: some View {
        TextField("Note for AI", text: Binding(get: { annotation.note }, set: setNote))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .frame(width: 200)
            .onSubmit { c.focusCanvas() }
            .help(title: "Note for AI", "What you want changed here. Copy for AI lists every note with what it points at; the note is not drawn on the image.")
    }

    /// Typing in one note is one undo step.
    private func setNote(_ note: String) {
        let id = annotation.id
        let before = c.checkpoint()
        c.update { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i].note = note }
        }
        c.commit(since: before, coalesce: "note \(id)")
    }
}

private struct SelectionActions: View {
    @ObservedObject var c: EditorController

    var body: some View {
        HStack(spacing: 2) {
            SymbolButton("Bring forward (⌘])", symbol: "square.3.layers.3d.top.filled",
                         help: "Puts the selected item above the ones it overlaps.") { c.arrange(.forward) }
            SymbolButton("Send backward (⌘[)", symbol: "square.3.layers.3d.bottom.filled",
                         help: "Puts the selected item below the ones it overlaps.") { c.arrange(.backward) }
            SymbolButton("Duplicate (⌘D)", symbol: "plus.square.on.square", help: "Makes a copy of the selected item.") { c.duplicateSelection() }
            SymbolButton("Delete (⌫)", symbol: "trash", help: "Removes the selected item.") { c.deleteSelection() }
        }
    }
}

private struct CropControls: View {
    @ObservedObject var c: EditorController
    let session: CropSession

    var body: some View {
        HStack(spacing: 14) {
            Text("Aspect")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Aspect", selection: Binding(get: { session.aspect }, set: { c.setCropAspect($0) })) {
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
        EditSlider(c: c, value: style[keyPath: keyPath], range: range) { value in c.applyStyle { $0[keyPath: keyPath] = value } }
            .frame(width: 120)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var traits: ToolKind.Traits { kind.traits }
    /// Outlined shapes pick a stroke size; filled ones have none.
    private var showsSize: Bool { !traits.sizes.isEmpty && !style.filled }

    var body: some View {
        HStack(spacing: 14) {
            if traits.hasColor {
                ColorSwatches(c: c, selected: style.color)
            }
            if showsSize {
                divider
                SizePicker(selection: bind(\.sizeIndex))
            }
            if !traits.options.isEmpty {
                if traits.hasColor { divider }
                ForEach(traits.options, id: \.self) { option($0) }
            }
            if traits.hasShadow {
                divider
                toggle("Shadow", symbol: "shadow", isOn: bind(\.shadow))
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func option(_ option: StyleOption) -> some View {
        switch option {
        case .curved:
            Picker("Style", selection: bind(\.curved)) {
                Text("Straight").tag(false)
                Text("Curved").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .outline:
            toggle("Outline", symbol: "square.dashed", isOn: bind(\.outline))
        case .dashed:
            toggle("Dashed", symbol: "line.3.horizontal", isOn: bind(\.dashed))
        case .fill:
            Picker("Fill", selection: bind(\.filled)) {
                Text("Outline").tag(false)
                Text("Filled").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .rounded:
            toggle("Rounded", symbol: "rectangle.roundedtop", isOn: bind(\.rounded))
        case .opacity(let range):
            HStack(spacing: 6) { caption("Opacity"); slider(\.opacity, in: range) }
        case .fontSize:
            HStack(spacing: 6) {
                caption("Size")
                Text("\(Int(style.fontSize))")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 26, alignment: .trailing)
                Stepper("", value: bind(\.fontSize), in: 8...200, step: 2).labelsHidden()
            }
        case .weight:
            Picker("Weight", selection: bind(\.weight)) {
                ForEach(FontWeightChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        case .backdrop:
            Picker("Backdrop", selection: bind(\.backdrop)) {
                ForEach(TextBackdrop.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .intensity(let title):
            HStack(spacing: 8) {
                caption(title)
                slider(\.intensity, in: 0...1)
            }
        case .spotShape:
            Picker("Shape", selection: bind(\.ellipseSpot)) {
                Text("Rectangle").tag(false)
                Text("Ellipse").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case .dim:
            HStack(spacing: 6) {
                caption("Dim")
                EditSlider(c: c, value: c.state.spotlightDim, range: 0.15...0.95) { c.applySpotlightDim($0) }
                    .frame(width: 120)
            }
        }
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
                set: { new in c.setColor(RGBA(NSColor(new)).with(alpha: 1)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Custom color")
        }
    }

    private func isSelected(_ color: RGBA) -> Bool {
        abs(color.r - selected.r) < 0.004 && abs(color.g - selected.g) < 0.004 && abs(color.b - selected.b) < 0.004
    }
}
