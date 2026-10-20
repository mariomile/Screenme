import AppKit
import AVFoundation
import SwiftUI

struct CaptureItem: Identifiable {
    enum Kind { case image, video }

    let id = UUID()
    var url: URL
    let kind: Kind
}

/// The overlay shown after every capture: drag it into any app, or copy, save, trim, export.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    private var panels: [(UUID, NSPanel)] = []
    private let size = CGSize(width: 240, height: 150)
    private let margin: CGFloat = 16

    func show(_ item: CaptureItem) {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickAccessView(item: item, close: { [weak self] in self?.close(item.id) }))
        panels.append((item.id, panel))
        layout()
        panel.orderFrontRegardless()
    }

    func close(_ id: UUID) {
        guard let index = panels.firstIndex(where: { $0.0 == id }) else { return }
        panels.remove(at: index).1.orderOut(nil)
        layout()
    }

    /// Stacks overlays bottom-left on the screen under the mouse, newest at the bottom.
    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let area = screen.visibleFrame
        for (offset, (_, panel)) in panels.reversed().enumerated() {
            let origin = CGPoint(x: area.minX + margin, y: area.minY + margin + CGFloat(offset) * (size.height + 10))
            panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: false)
        }
    }
}

private struct QuickAccessView: View {
    @State var item: CaptureItem
    let close: () -> Void
    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            }
            if hovering && !busy { controls }
            if busy { ProgressView().controlSize(.small).tint(.white) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .task(id: item.url) { thumbnail = await Thumbnail.make(for: item) }
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    pill("Copy") { copy() }
                    pill("Save") { save() }
                }
                if item.kind == .video {
                    HStack(spacing: 8) {
                        pill("Trim") { Trimmer.open(item.url) { item.url = $0 } }
                        pill("GIF") { exportGIF() }
                    }
                }
            }
            VStack {
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        item.kind == .image ? Clipboard.copyImage(at: item.url) : Clipboard.copyFile(at: item.url)
        close()
    }

    private func save() {
        if let saved = try? Storage.save(item.url) {
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        }
        close()
    }

    private func exportGIF() {
        busy = true
        Task {
            if let gif = try? await GIFExporter.export(item.url) {
                QuickAccess.shared.show(CaptureItem(url: gif, kind: .image))
            }
            busy = false
        }
    }
}

enum Thumbnail {
    static func make(for item: CaptureItem) async -> NSImage? {
        switch item.kind {
        case .image:
            return NSImage(contentsOf: item.url)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 300)
            guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
            return NSImage(cgImage: image, size: .zero)
        }
    }
}
