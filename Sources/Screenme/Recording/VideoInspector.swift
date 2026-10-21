import AppKit
import SwiftUI

/// The bar under the timeline with what the editor draws on the video, one group at a time, like the image
/// editor's inspector bar.
struct VideoInspector: View {
    @ObservedObject var model: VideoEditorModel
    @AppStorage("videoInspectorTab") private var tab = Tab.background

    enum Tab: String, CaseIterable, Identifiable {
        case background = "Background"
        var id: String { rawValue }

        var help: String {
            switch self {
            case .background: "Background\nPuts the video on a gradient, color, wallpaper or image, with padding, rounded corners and a shadow."
            }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0).help($0.help) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What to change on the video")

            Divider().frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    switch tab {
                    case .background: BackgroundControls(model: model)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }
}

// MARK: - Background

private struct BackgroundControls: View {
    @ObservedObject var model: VideoEditorModel
    @State private var choosingFill = false

    private var canvas: Binding<BackgroundSettings> { $model.edit.canvas }

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Background", isOn: canvas.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Background\nWraps the video in a background. Off exports the recording's own picture.")

            Group {
                Button { choosingFill = true } label: {
                    FillSwatch(fill: model.edit.canvas.fill)
                        .frame(width: 40, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("Fill\nPick a gradient, a color, your wallpaper or an image.")
                .popover(isPresented: $choosingFill, arrowEdge: .top) { FillPicker(fill: canvas.fill).padding(14) }

                slider("Padding", value: canvas.padding, in: VideoCanvas.paddingRange, label: "\(Int(model.edit.canvas.padding))%",
                       help: "Padding\nSpace around the video, as a share of its shorter side.")
                slider("Corners", value: canvas.cornerRadius, in: VideoCanvas.cornerRange, label: "\(Int(model.edit.canvas.cornerRadius))",
                       help: "Corners\nRounds the corners of the video.")
                slider("Shadow", value: canvas.shadow, in: 0...1, label: "\(Int(model.edit.canvas.shadow * 100))%",
                       help: "Shadow\nHow strong the shadow under the video is.")

                Picker("Aspect", selection: canvas.aspect) {
                    ForEach(VideoCanvas.aspects) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                .help("Aspect ratio\nThe shape of the exported video. Auto follows the recording; 9:16 suits phones, 1:1 and 4:3 social posts. The video is fitted inside.")
            }
            .disabled(!model.edit.canvas.enabled)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, label: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(width: 90).controlSize(.small)
            Text(label).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        }
        .help(help)
    }
}

/// The background fills of the image editor, in a popover: gradients, colors, the wallpaper, an image.
private struct FillPicker: View {
    @Binding var fill: BackgroundFill

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 5), spacing: 8) {
                ForEach(GradientSpec.all) { spec in
                    swatch(.gradient(spec.id), help: spec.name)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(SolidSwatches.all.enumerated()), id: \.offset) { _, color in
                    Button { fill = .solid(color) } label: {
                        Circle().fill(color.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(fill == .solid(color) ? 1 : 0))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Wallpaper") { fill = .wallpaper }
                    .help("Wallpaper\nUses your current desktop picture.")
                Button("Choose Image…") { chooseImage() }
                    .help("Choose Image\nUses a picture from your Mac.")
            }
            .controlSize(.small)
        }
        .frame(width: 236)
    }

    private func swatch(_ value: BackgroundFill, help: String) -> some View {
        Button { fill = value } label: {
            FillSwatch(fill: value)
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(fill == value ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BackgroundImages.forget(url.path)
        fill = .image(url.path)
    }
}
