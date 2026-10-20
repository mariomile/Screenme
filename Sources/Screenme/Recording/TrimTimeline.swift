import AppKit
import SwiftUI

/// The filmstrip with the trim handles and the playhead.
struct TrimTimeline: View {
    @ObservedObject var model: VideoEditorModel
    private let handleWidth: CGFloat = 14
    private let height: CGFloat = 58

    var body: some View {
        GeometryReader { geometry in
            let inner = max(geometry.size.width - handleWidth * 2, 1)
            let duration = max(model.duration, 0.001)
            let x = { (time: Double) -> CGFloat in handleWidth + CGFloat(time / duration) * inner }
            let time = { (position: CGFloat) -> Double in Double((position - handleWidth) / inner) * duration }

            ZStack(alignment: .topLeading) {
                filmstrip(width: inner)
                    .offset(x: handleWidth)

                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(x(model.trimStart) - handleWidth, 0), height: height)
                    .offset(x: handleWidth)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(handleWidth + inner - x(model.trimEnd), 0), height: height)
                    .offset(x: x(model.trimEnd))

                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(x(model.trimEnd) - x(model.trimStart), 0), height: height)
                    .offset(x: x(model.trimStart))
                    .allowsHitTesting(false)

                handle(leading: true)
                    .offset(x: x(model.trimStart) - handleWidth)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        model.setTrimStart(time(value.location.x + handleWidth / 2))
                    }.onEnded { _ in model.endScrub() })
                handle(leading: false)
                    .offset(x: x(model.trimEnd))
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        model.setTrimEnd(time(value.location.x - handleWidth / 2))
                    }.onEnded { _ in model.endScrub() })

                playhead
                    .offset(x: x(min(max(model.currentTime, model.trimStart), model.trimEnd)) - 1)
                    .allowsHitTesting(false)
            }
            .frame(height: height, alignment: .top)
            .padding(.top, 8)
            .coordinateSpace(name: "strip")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                model.scrub(to: time(value.location.x))
            }.onEnded { _ in model.endScrub() })
        }
        .frame(height: height + 8)
    }

    private func filmstrip(width: CGFloat) -> some View {
        let aspect = model.videoSize.height > 0 ? model.videoSize.width / model.videoSize.height : 1.6
        let count = max(Int((width / max(height * aspect, 20)).rounded(.up)), 1)
        let total = model.thumbnails.count
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let source = min(Int((Double(index) + 0.5) / Double(count) * Double(total)), total - 1)
                ZStack {
                    Color.primary.opacity(0.08)
                    if let image = model.thumbnails[source] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: width / CGFloat(count), height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(leading: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: leading ? 6 : 0, bottomLeadingRadius: leading ? 6 : 0,
                                   bottomTrailingRadius: leading ? 0 : 6, topTrailingRadius: leading ? 0 : 6)
                .fill(Color.yellow)
            Capsule().fill(.black.opacity(0.55)).frame(width: 2.5, height: 20)
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle())
        .modifier(ResizeCursorOnHover())
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 9, height: 9)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
            Rectangle().fill(.white).frame(width: 2, height: height - 1)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
        }
        .frame(width: 9)
        .offset(x: -3.5, y: -4)
    }
}

/// The resize cursor over a trim handle. Pops on disappear too, so closing the window mid-hover
/// does not leave the cursor stack unbalanced.
private struct ResizeCursorOnHover: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.resizeLeftRight.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop() }
                pushed = false
            }
    }
}
