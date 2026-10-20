import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand panel that wraps the screenshot in a background.
struct BackgroundPanel: View {
    @ObservedObject var c: EditorController
    @State private var namingPreset = false
    @State private var presetName = ""

    private var settings: BackgroundSettings { c.state.background }

    private enum FillTab: String, CaseIterable, Identifiable {
        case gradient = "Gradient", color = "Color", wallpaper = "Wallpaper", image = "Image"
        var id: String { rawValue }
    }

    private var tab: FillTab {
        switch settings.fill {
        case .gradient: .gradient
        case .solid: .color
        case .wallpaper: .wallpaper
        case .image: .image
        }
    }

    private var tabBinding: Binding<FillTab> {
        Binding(get: { tab }, set: { selectTab($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Background").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { settings.enabled }, set: { _ in c.toggleBackground() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    presets
                    fill
                    spacing
                    aspect
                    alignment
                }
                .padding(16)
            }
        }
        .background(.regularMaterial)
        .alert("Save Preset", isPresented: $namingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                c.savePreset(named: name.isEmpty ? "Preset \(c.presets.count + 1)" : name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current background settings.")
        }
    }

    // MARK: Presets

    private var presets: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        presetName = ""
                        namingPreset = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 44, height: 32)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    .buttonStyle(.plain)
                    .help("Save the current settings as a preset")

                    ForEach(c.presets) { preset in
                        Button { c.applyPreset(preset) } label: {
                            FillSwatch(fill: preset.settings.fill)
                                .frame(width: 44, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                        .contextMenu { Button("Delete Preset", role: .destructive) { c.deletePreset(preset) } }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            header("Presets")
        }
    }

    // MARK: Fill

    private var fill: some View {
        Section {
            Picker("Fill", selection: tabBinding) {
                ForEach(FillTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .gradient: gradientGrid
            case .color: colorGrid
            case .wallpaper: wallpaperPreview
            case .image: imageChooser
            }
        } header: {
            header("Fill")
        }
    }

    private var gradientGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(GradientSpec.all) { spec in
                let selected = settings.fill == .gradient(spec.id)
                Button { c.updateBackground { $0.fill = .gradient(spec.id) } } label: {
                    FillSwatch(fill: .gradient(spec.id))
                        .aspectRatio(1.3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(spec.name)
            }
        }
    }

    private var colorGrid: some View {
        let current: RGBA = { if case .solid(let color) = settings.fill { return color } else { return .white } }()
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Array(SolidSwatches.all.enumerated()), id: \.offset) { _, color in
                    Button { c.updateBackground { $0.fill = .solid(color) } } label: {
                        Circle()
                            .fill(color.color)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            .padding(2)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(current == color ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Custom").font(.system(size: 12)).foregroundStyle(.secondary)
                ColorPicker("Custom background color", selection: Binding(
                    get: { current.color },
                    set: { new in c.setBackgroundColor(RGBA(NSColor(new)).with(alpha: 1)) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }

    private var wallpaperPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            FillSwatch(fill: .wallpaper)
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            Text("Uses your current desktop picture.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var imageChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .image(let path) = settings.fill {
                FillSwatch(fill: .image(path))
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            }
            Button("Choose Image…") { chooseImage() }
        }
    }

    // MARK: Layout sliders

    private var spacing: some View {
        Section {
            VStack(spacing: 12) {
                sliderRow("Padding", value: settings.padding, range: 0...40, label: "\(Int(settings.padding))%") { v in
                    c.applyBackground { $0.padding = v }
                }
                sliderRow("Corners", value: settings.cornerRadius, range: 0...48, label: "\(Int(settings.cornerRadius))") { v in
                    c.applyBackground { $0.cornerRadius = v }
                }
                sliderRow("Shadow", value: settings.shadow, range: 0...1, label: "\(Int(settings.shadow * 100))%") { v in
                    c.applyBackground { $0.shadow = v }
                }
            }
        } header: {
            header("Image")
        }
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, label: String,
                           apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).frame(width: 56, alignment: .leading)
            EditSlider(c: c, value: value, range: range, apply: apply)
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: Aspect ratio and alignment

    private var aspect: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(AspectPreset.allCases) { preset in
                    let selected = settings.aspect == preset
                    Button { c.updateBackground { $0.aspect = preset } } label: {
                        Text(preset.title)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            header("Aspect ratio")
        }
    }

    private var alignment: some View {
        Section {
            AlignmentGrid(selection: settings.alignment) { value in c.updateBackground { $0.alignment = value } }
        } header: {
            header("Alignment")
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    // MARK: Actions

    private func selectTab(_ tab: FillTab) {
        switch tab {
        case .gradient:
            if case .gradient = settings.fill { return }
            c.updateBackground { $0.fill = .gradient("sunset") }
        case .color:
            if case .solid = settings.fill { return }
            c.updateBackground { $0.fill = .solid(RGBA(hex: 0xF2F2F7)) }
        case .wallpaper:
            c.updateBackground { $0.fill = .wallpaper }
        case .image:
            if case .image = settings.fill { return }
            chooseImage()
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BackgroundImages.forget(url.path)
        c.updateBackground { $0.fill = .image(url.path) }
    }
}

// MARK: - Pieces

/// A small rendering of a background fill.
struct FillSwatch: View {
    let fill: BackgroundFill

    var body: some View {
        switch fill {
        case .gradient(let id):
            let spec = GradientSpec.spec(id)
            let a = spec.angle * .pi / 180
            LinearGradient(colors: spec.colors.map(\.color),
                           startPoint: UnitPoint(x: 0.5 - cos(a) / 2, y: 0.5 - sin(a) / 2),
                           endPoint: UnitPoint(x: 0.5 + cos(a) / 2, y: 0.5 + sin(a) / 2))
        case .solid(let color):
            color.color
        case .wallpaper, .image:
            if let image = BackgroundImages.image(for: fill) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
    }
}

private struct AlignmentGrid: View {
    let selection: Alignment9
    let onPick: (Alignment9) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 3), spacing: 6) {
            ForEach(Alignment9.allCases, id: \.rawValue) { value in
                let selected = selection == value
                Button { onPick(value) } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                        .frame(width: 34, height: 26)
                        .overlay(
                            Circle()
                                .fill(selected ? Color.accentColor : Color.primary.opacity(0.35))
                                .frame(width: 7, height: 7)
                                .offset(x: (value.fx - 0.5) * 16, y: (value.fy - 0.5) * 10)
                        )
                }
                .buttonStyle(.plain)
                .help("Align \(value.title)")
            }
        }
    }
}

extension Alignment9 {
    var title: String {
        ["top left", "top", "top right", "left", "center", "right", "bottom left", "bottom", "bottom right"][rawValue]
    }
}
