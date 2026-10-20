import AppKit
import SwiftUI

/// Resize the exported picture, keeping its proportions by default.
struct ResizeImageSheet: View {
    @ObservedObject var c: EditorController
    @Environment(\.dismiss) private var dismiss
    @State private var width: Int
    @State private var height: Int
    @State private var lockRatio = true
    private let original: CGSize

    init(c: EditorController) {
        self.c = c
        let size = c.outputSize
        original = size
        _width = State(initialValue: Int(size.width))
        _height = State(initialValue: Int(size.height))
    }

    private var ratio: Double { original.height > 0 ? Double(original.width / original.height) : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Image").font(.headline)
            Text("Current size: \(Int(original.width)) × \(Int(original.height)) px")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: Binding(get: { width }, set: { setWidth($0) }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: Binding(get: { height }, set: { setHeight($0) }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("px").foregroundStyle(.secondary)
                }
            }
            Toggle("Keep proportions", isOn: $lockRatio)

            HStack(spacing: 8) {
                ForEach([25, 50, 75, 200], id: \.self) { percent in
                    Button("\(percent)%") { setWidth(Int((Double(original.width) * Double(percent) / 100).rounded())) }
                        .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    c.resizeImage(toWidth: CGFloat(width))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 1 || height < 1)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func setWidth(_ value: Int) {
        width = max(1, min(value, 30_000))
        if lockRatio { height = max(1, Int((Double(width) / ratio).rounded())) }
    }

    private func setHeight(_ value: Int) {
        height = max(1, min(value, 30_000))
        if lockRatio { width = max(1, Int((Double(height) * ratio).rounded())) }
    }
}

/// Grow or shrink the canvas around the image without scaling it.
struct ResizeCanvasSheet: View {
    @ObservedObject var c: EditorController
    @Environment(\.dismiss) private var dismiss
    @State private var width: Int
    @State private var height: Int
    @State private var anchor = Alignment9.center
    @State private var transparent = false
    @State private var fill: Color

    init(c: EditorController) {
        self.c = c
        _width = State(initialValue: Int(c.state.cropRect.width))
        _height = State(initialValue: Int(c.state.cropRect.height))
        _fill = State(initialValue: c.state.canvasFill.a > 0 ? c.state.canvasFill.color : .white)
        _transparent = State(initialValue: c.state.canvasFill.a == 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Canvas").font(.headline)
            Text("Adds or removes space around the image. The image itself is not scaled.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Width")
                        TextField("Width", value: $width, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    GridRow {
                        Text("Height")
                        TextField("Height", value: $height, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anchor").font(.system(size: 11)).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 3), spacing: 4) {
                        ForEach(Alignment9.allCases, id: \.rawValue) { value in
                            Button { anchor = value } label: {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(anchor == value ? Color.accentColor : Color.primary.opacity(0.12))
                                    .frame(width: 26, height: 20)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Text("New area")
                Toggle("Transparent", isOn: $transparent)
                ColorPicker("Fill color", selection: $fill, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(transparent)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    c.resizeCanvas(width: CGFloat(width), height: CGFloat(height), anchor: anchor,
                                   fill: transparent ? RGBA.clear : RGBA(NSColor(fill)).with(alpha: 1))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 4 || height < 4)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
