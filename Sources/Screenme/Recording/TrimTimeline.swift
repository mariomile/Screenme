import AppKit
import SwiftUI

/// The filmstrip with the trim handles and the playhead, and under it the lane of zooms.
struct TrimTimeline: View {
    @ObservedObject var model: VideoEditorModel
    private let handleWidth: CGFloat = 14
    private let height: CGFloat = 58
    private let laneGap: CGFloat = 6
    private let laneHeight: CGFloat = 20

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

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: inner, height: laneHeight)
                    .offset(x: handleWidth, y: height + laneGap)
                    .allowsHitTesting(false)
                ForEach(model.edit.zooms) { zoom in
                    ZoomBlock(model: model, zoom: zoom, pointsPerSecond: inner / CGFloat(duration))
                        .frame(width: max(x(zoom.end) - x(zoom.start), 6), height: laneHeight)
                        .offset(x: x(zoom.start), y: height + laneGap)
                }
            }
            .frame(height: height + laneGap + laneHeight, alignment: .top)
            .padding(.top, 8)
            .coordinateSpace(name: "strip")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                model.scrub(to: time(value.location.x))
            }.onEnded { _ in model.endScrub() })
        }
        .frame(height: height + 8 + laneGap + laneHeight)
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

/// One zoom on the timeline: drag it to move it, click to select it, the x or Delete to remove it.
private struct ZoomBlock: View {
    @ObservedObject var model: VideoEditorModel
    let zoom: ZoomSegment
    let pointsPerSecond: CGFloat
    @State private var dragStart: Double?
    @State private var hovering = false

    private var selected: Bool { model.selectedZoom == zoom.id }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.purple.opacity(selected ? 0.95 : 0.65))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
            HStack(spacing: 3) {
                Image(systemName: zoom.isAuto ? "cursorarrow.click" : "plus.magnifyingglass")
                Text(String(format: "%.1fx", zoom.zoom ?? model.edit.zoomStrength))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if hovering {
                    Button { model.deleteZoom(zoom.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Delete Zoom")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .lineLimit(1)
        }
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("strip")).onChanged { value in
            if dragStart == nil {
                dragStart = zoom.start
                model.selectedZoom = zoom.id
            }
            model.moveZoom(zoom.id, to: (dragStart ?? zoom.start) + Double(value.translation.width / max(pointsPerSecond, 0.001)))
        }.onEnded { _ in dragStart = nil })
        .simultaneousGesture(TapGesture().onEnded { model.selectedZoom = selected ? nil : zoom.id })
        .contextMenu {
            Button("Delete Zoom") { model.deleteZoom(zoom.id) }
            Button("Remove All Zooms") { model.removeAllZooms() }
        }
        .help(title: zoom.isAuto ? "Zoom on a click" : "Zoom",
              zoom.isAuto ? "Follows the cursor. Drag to move it, Delete or the x to remove it."
                          : "Stays on the region you picked. Drag to move it, Delete or the x to remove it.")
    }
}
