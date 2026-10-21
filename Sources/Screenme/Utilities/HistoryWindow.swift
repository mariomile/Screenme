import AppKit
import SwiftUI

/// The history browser: a grid of everything captured recently, grouped by day.
@MainActor
enum HistoryWindow {
    static func show() {
        CaptureHistory.shared.prune()
        let window = WindowPresenter.shared.show(
            "history", title: "Capture History", size: CGSize(width: 1000, height: 700),
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        ) {
            HistoryGridView()
        }
        window.minSize = CGSize(width: 640, height: 440)
        window.setFrameAutosaveName("ScreenmeHistoryWindow")
    }
}

// MARK: - Model

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case screenshots = "Screenshots"
    case recordings = "Recordings"
    var id: String { rawValue }

    func includes(_ item: CaptureItem) -> Bool {
        switch self {
        case .all: true
        case .screenshots: item.kind == .image
        case .recordings: item.kind == .video || item.kind == .gif
        }
    }
}

private struct HistoryDayGroup: Identifiable {
    let day: Date
    let items: [CaptureItem]
    var id: Date { day }

    var title: String { HistoryDayGroup.title(for: day) }

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// Text a date search can match: names of the day and month, numbers, the time, the kind of capture.
private func searchText(for item: CaptureItem) -> String {
    let date = item.date
    let kind = switch item.kind {
    case .image: "screenshot image"
    case .video: "recording video"
    case .gif: "recording gif"
    }
    let parts = [
        HistoryDayGroup.title(for: Calendar.current.startOfDay(for: date)),
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)),
        date.formatted(.iso8601.year().month().day()),
        date.formatted(date: .omitted, time: .shortened),
        kind,
        item.url.lastPathComponent,
    ]
    return parts.joined(separator: " ").lowercased()
}

// MARK: - View

private struct HistoryGridView: View {
    @ObservedObject private var history = CaptureHistory.shared
    @State private var filter: HistoryFilter = .all
    @State private var query = ""
    /// Click selects one capture, ⌘-click adds or removes one.
    @State private var selection: Set<UUID> = []

    private var groups: [HistoryDayGroup] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let visible = history.items.filter { item in
            filter.includes(item) && (tokens.isEmpty || { let text = searchText(for: item); return tokens.allSatisfy(text.contains) }())
        }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { HistoryDayGroup(day: $0, items: byDay[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { history.prune() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Room for the traffic lights, which sit over the transparent titlebar.
            Color.clear.frame(width: 64, height: 1)
            Picker("Filter", selection: $filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            Spacer(minLength: 8)
            combineMenu
            searchField
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var selectedImages: [CaptureItem] {
        history.items.filter { selection.contains($0.id) && $0.kind == .image }
    }

    @ViewBuilder
    private var combineMenu: some View {
        let images = selectedImages
        if images.count >= 2 {
            Menu("Combine \(images.count)") {
                Button("Side by Side") { ImageCombiner.combineAndEdit(images, layout: .sideBySide) }
                Button("Stacked") { ImageCombiner.combineAndEdit(images, layout: .stacked) }
            }
            .fixedSize()
            .help("Join the selected screenshots into one image")
        }
    }

    private func select(_ item: CaptureItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.remove(item.id) == nil { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search by date", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 200, height: 26)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = groups
        if history.items.isEmpty {
            ContentUnavailableView {
                Label("No captures yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Screenshots and recordings you take will show up here.")
            }
        } else if groups.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label(filter == .recordings ? "No recordings" : "No screenshots", systemImage: filter == .recordings ? "video" : "photo")
                } description: {
                    Text("Nothing in this category yet.")
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16, alignment: .top)], spacing: 18) {
                                ForEach(group.items) { item in
                                    HistoryGridCell(item: item, revision: history.revision(of: item.url),
                                                isSelected: selection.contains(item.id)) { select(item) }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                        } header: {
                            HistoryDayHeader(title: group.title, count: group.items.count)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = [] }
        }
    }
}

private struct HistoryDayHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: - Cell

private struct HistoryGridCell: View {
    let item: CaptureItem
    let revision: Int
    let isSelected: Bool
    let select: () -> Void

    @State private var thumbnail: Thumbnail?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tile
            HStack(spacing: 5) {
                Image(systemName: item.kind == .video ? "video.fill" : "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onTapGesture(count: 2) { perform(.edit) }
        .onTapGesture { select() }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu { menu }
        .task(id: "\(item.url.path)#\(revision)") {
            if let cached = Thumbnails.cached(for: item, maxPixelSize: Self.thumbnailSize) { thumbnail = cached; return }
            thumbnail = await Thumbnails.make(for: item, maxPixelSize: Self.thumbnailSize)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private var tile: some View {
        Color.clear
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                    if let thumbnail {
                        Image(decorative: thumbnail.image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = thumbnail?.duration, !hovering {
                    Label(Duration.format(duration), systemImage: "play.fill")
                        .labelStyle(HistoryBadgeStyle())
                        .padding(6)
                }
            }
            .overlay { if hovering { hoverActions } }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.10), radius: hovering ? 9 : 4, y: hovering ? 4 : 2)
    }

    private var hoverActions: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 7) {
                ForEach([CaptureAction.copy, .save, .pin, .edit, .trash].filter { $0.isAvailable(for: item.kind) }, id: \.self) { action in
                    HistoryActionButton(symbol: action.symbol(for: item.kind), help: action.title(for: item.kind)) { perform(action) }
                }
                HistoryActionButton(symbol: "square.and.arrow.up", help: "Share") { Share.show(item.url) }
            }
            .padding(.bottom, 9)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var menu: some View {
        ForEach(CaptureAction.allCases.filter { $0.isAvailable(for: item.kind) }, id: \.self) { action in
            if action == .edit || action == .trash { Divider() }
            Button(action.title(for: item.kind), systemImage: action.symbol(for: item.kind),
                   role: action == .trash ? .destructive : nil) { perform(action) }
            if action == .reveal { ShareLink(item: item.url) }
        }
    }

    private func perform(_ action: CaptureAction) {
        Task { await action.perform(item) }
    }

    /// Longest side in pixels: enough for a retina grid cell.
    private static let thumbnailSize = 640
}

private struct HistoryActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(hovering ? 0.8 : 0.58), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

private struct HistoryBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.65), in: Capsule())
    }
}
