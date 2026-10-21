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

    init(item: CaptureItem) { self.item = item }

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
                    HUDCircle(symbol: "xmark", label: "Close", help: "Close\nHides this card. The capture stays in History.") { card?.dismiss() }
                    Spacer()
                    circle(.pin)
                }
                Spacer()
                HStack {
                    circle(.edit)
                    Spacer()
                    HUDCircle(symbol: "square.and.arrow.up", label: "Share",
                              help: "Share\nSends it with AirDrop, Messages, Mail and more.") { Share.show(model.item.url) }
                }
            }
            .padding(8)
        }
        .transition(.opacity)
    }

    private func pill(_ action: CaptureAction) -> some View {
        HUDPill(title: action.title(for: model.item.kind), symbol: action.symbol(for: model.item.kind),
                help: action.tooltip(for: model.item.kind)) { card?.perform(action) }
    }

    @ViewBuilder
    private func circle(_ action: CaptureAction) -> some View {
        if action.isAvailable(for: model.item.kind) {
            HUDCircle(symbol: action.symbol(for: model.item.kind), label: action.title(for: model.item.kind),
                      help: action.tooltip(for: model.item.kind)) { card?.perform(action) }
        }
    }
}

private struct HUDPill: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 84, height: 28)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(HUDPressStyle())
        .help(help)
    }
}

private struct HUDCircle: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(HUDPressStyle())
        .help(help)
        .accessibilityLabel(label)
    }
}

private struct HUDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
