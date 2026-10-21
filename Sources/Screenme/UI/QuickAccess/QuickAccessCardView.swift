import AppKit
import SwiftUI

/// What a card shows: the capture, its preview, and whether the pointer or a drag is on it.
@MainActor
final class CardModel: ObservableObject {
    let item: CaptureItem
    @Published var thumbnail: NSImage?
    @Published var duration: String?
    @Published var hovering = false
    @Published var dragging = false
    /// False while the capture file is still being written. The card shows the in-memory preview meanwhile,
    /// actions wait for the file and a drag out starts once it is there.
    private(set) var isWritten: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(item: CaptureItem, preview: CGImage? = nil) {
        self.item = item
        isWritten = preview == nil
        thumbnail = preview.map { NSImage(cgImage: $0, size: .zero) }
    }

    func untilWritten() async {
        guard !isWritten else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func fileWritten() {
        isWritten = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }

    func reload() async {
        let preview = await Thumbnails.make(for: item, maxPixelSize: 720)
        thumbnail = preview.map { NSImage(cgImage: $0.image, size: .zero) }
        if item.kind == .video { duration = preview?.duration.map { Duration.format($0) } }
    }
}

/// The card's face: the preview, and on hover Copy, Save, Close, Pin, Edit and Share.
struct QuickAccessCardView: View {
    @ObservedObject var model: CardModel
    let size: CGSize
    weak var card: QuickAccessCard?

    private var showsControls: Bool { model.hovering && !model.dragging }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }

            CardInputSurface(model: model, card: card)

            if showsControls { controls }

            if model.item.kind == .video, let duration = model.duration {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label(duration, systemImage: "video.fill")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
                .opacity(showsControls ? 0 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
        .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
        .opacity(model.dragging ? 0.4 : 1)
        .padding(QuickAccess.inset)
        .animation(.easeOut(duration: 0.15), value: showsControls)
        .animation(.easeOut(duration: 0.2), value: model.thumbnail == nil)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                pill(.copy)
                pill(.save)
            }

            VStack {
                HStack {
                    SymbolButton(symbol: "xmark", help: "Close\nHides this card. The capture stays in History.", style: .circle,
                                 label: "Close") { card?.dismiss() }
                    Spacer()
                    circle(.copyForAI)
                    circle(.reportForAI)
                    Spacer()
                    circle(.pin)
                }
                Spacer()
                HStack {
                    circle(.edit)
                    Spacer()
                    circle(.share)
                }
            }
            .padding(8)
        }
        .transition(.opacity)
    }

    private func pill(_ action: CaptureAction) -> some View {
        Button { card?.perform(action) } label: {
            Label(action.title(for: model.item.kind), systemImage: action.symbol(for: model.item.kind))
        }
        .buttonStyle(HUDButtonStyle(.pill))
        .help(action.tooltip(for: model.item.kind))
    }

    @ViewBuilder
    private func circle(_ action: CaptureAction) -> some View {
        if action.isAvailable(for: model.item.kind) {
            SymbolButton(symbol: action.symbol(for: model.item.kind), help: action.tooltip(for: model.item.kind), style: .circle,
                         label: action.title(for: model.item.kind)) { card?.perform(action) }
        }
    }
}
