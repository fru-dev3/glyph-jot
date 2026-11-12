import GlyphCore
import SwiftUI
import UniformTypeIdentifiers

/// The library: sidebar | list | detail. The sidebar is the split view's own (it
/// collapses natively); the list collapses with its own toggle and can be resized.
struct LibraryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropping = false
    @FocusState private var searchFocus: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300) // 232: the canvas's rail
        } detail: {
            Group {
            if !model.isVaultPresent && model.sidebar != .settings {
                NoVault()
            } else {
            switch model.sidebar {
            case .all: AllPane()
            case .chat: ChatPane()
            case .notes: NotesPane()
            case .dictations: DictationsPane()
            case .settings: JotSettings()
            default:
            GeometryReader { geo in
            HStack(spacing: 0) {
                if model.showList {
                    // A small window keeps the list from crowding the conversation.
                    ConversationList()
                        .frame(width: min(model.listWidth, max(250, geo.size.width * 0.4)))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ResizeHandle(width: $model.listWidth)
                }
                DetailColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            }
            }
            }
            }
            .overlay(alignment: .top) { appBanners }
        }
        .navigationTitle("Glyph Jot") // the window's name in the Window menu and Mission Control
        .toolbar(removing: .title)
        .toolbar {
            // One control per corner: with the sidebar hidden its toggle owns the corner, and
            // Settings has no list to show, so nothing stands there offering to show one.
            if model.columns != .detailOnly, model.sidebar != .settings, model.sidebar != .chat {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.glyph(reduceMotion)) { model.showList.toggle() }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .symbolVariant(model.showList ? .fill : .none)
                }
                .help(model.showList ? "Hide the list (Control-Command-L)" : "Show the list (Control-Command-L)")
            }
            } else {
            // Record lives at the foot of the sidebar; with the sidebar hidden it comes up here.
            ToolbarItem(placement: .primaryAction) { ToolbarRecordButton() }
            }
        }
        // The system's search: it sits at the toolbar's trailing edge, clear of the columns,
        // and folds into a magnifier when the window is narrow, so nothing ever overlaps.
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocus)
        .onChange(of: model.searchFocused) {
            if model.searchFocused { searchFocus = true; model.searchFocused = false }
        }
        .sheet(isPresented: $model.reviewingLinks) { LinkReviewSheet().environment(model) }
        .overlay {
            if model.quickOpen {
                QuickOpen()
                    .transition(.opacity)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        Label("Drop to import", systemImage: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importAudio(urls)
            return true
        } isTargeted: { dropping = $0 }
        .animation(.glyph(reduceMotion), value: model.columns)
        .animation(.glyph(reduceMotion), value: model.quickOpen)
        .task { NoteStore.shared.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            NoteStore.shared.reload()
            Task { await model.reloadStudio() }
        }
    }

    @ViewBuilder private var appBanners: some View {
        let banners = model.banners.filter { $0.conversation == nil }
        if !banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(banners) { BannerView(banner: $0) }
            }
            .frame(maxWidth: 560)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
            .padding(.top, 10)
            .padding(.horizontal, 16)
        }
    }
}

/// A thin divider that resizes the list when dragged.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            let s = start ?? width
                            start = s
                            width = min(440, max(260, s + g.translation.width))
                        }
                        .onEnded { _ in start = nil })
            }
    }
}



/// The honest state when the vault is absent or removed.
struct NoVault: View {
    @Environment(AppModel.self) private var model

    func openSettings(_ target: AppModel) {
        target.sidebar = .settings
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Choose your vault").font(.system(size: 26, weight: .bold))
            Text("Glyph Jot needs your vault to store recordings, notes, and dictations.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open Settings") {
                openSettings(model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("novault.settings")
        }
        .padding(40)
        .accessibilityIdentifier("novault")
    }
}
