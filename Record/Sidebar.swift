import GlyphCore
import SwiftUI

/// The captures first (All, Notes, Dictations, Recordings), then what they are filed under in
/// Glyph Bot: Domains, People, Products and Projects, by Studio's names, each with how
/// many captures it has. Only objects something is filed under are listed; Studio keeps the
/// rest. #tags last, plain (Studio has no tags).
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var notes = NoteStore.shared
    @AppStorage("sidebar.closed") private var closed = ""

    var body: some View {
        @Bindable var model = model
        let counts = model.linkCounts
        let recordings = model.library.conversations.count

        VStack(spacing: 0) {
        List(selection: $model.sidebar) {
            Section {
                row("All", "square.stack.3d.up", recordings + notes.notes.count + notes.dictationCount).tag(SidebarItem.all)
                row("Notes", "note.text", notes.notes.count).tag(SidebarItem.notes)
                row("Dictations", "text.cursor", notes.dictationCount).tag(SidebarItem.dictations)
                row("Recordings", "waveform", recordings).tag(SidebarItem.recordings)
            }

            ForEach(sections(counts.objects), id: \.kind) { section in
                Section(isExpanded: open(section.kind.rawValue)) {
                    ForEach(section.rows) { r in
                        row(r.name, section.kind == .domain ? VaultDomains.symbol(String(r.id.dropFirst(7))) : section.kind.symbol, r.count).tag(SidebarItem.object(r.id))
                    }
                } header: {
                    Text(section.kind.label)
                }
            }

            let tags = counts.tags.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            if !tags.isEmpty {
                Section(isExpanded: open("tags")) {
                    ForEach(tags, id: \.key) { t in
                        row(t.key, "number", t.value, tint: CanonicalTags.color(t.key)).tag(SidebarItem.tag(t.key))
                    }
                } header: {
                    Text("Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        // The list ends above the Record card, with a divider: no row ever shows beneath it.
        Divider().padding(.horizontal, 10)
        RecordDock().padding(.top, 10)
        }
    }

    /// Which app this is, at the top: the icon, the name, and the gear. One line, no tagline.
    /// The gear opens Settings here in the window, never as a page floating over the app.
    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 30, height: 30)
            Text("Glyph Jot").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Button { model.sidebar = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.sidebar == .settings ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings: version, where Jot saves, dictation, recording (Command-comma)")
            .accessibilityIdentifier("settings")
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
    }

    struct Row: Identifiable { var id: String; var name: String; var count: Int }

    /// Each kind with the objects something is filed under, most first; empty kinds left out.
    private func sections(_ counts: [String: Int]) -> [(kind: StudioObject.Kind, rows: [Row])] {
        StudioObject.Kind.listed.compactMap { kind in
            let rows: [Row] = counts.compactMap { id, n in
                StudioObject.Kind(id: id) == kind ? Row(id: id, name: model.studio.name(id), count: n) : nil
            }
            let sorted = rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return sorted.isEmpty ? nil : (kind, sorted)
        }
    }

    /// `tint` is a canonical tag's own colour; every other row keeps the sidebar's.
    private func row(_ title: String, _ symbol: String, _ count: Int, tint: Color? = nil) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint ?? Color.accentColor)
        }
        .badge(count)
    }

    /// Whether a section is open, remembered across launches.
    private func open(_ key: String) -> Binding<Bool> {
        Binding(get: { !closed.split(separator: ",").contains(Substring(key)) },
                set: { isOpen in
                    var keys = closed.split(separator: ",").map(String.init).filter { $0 != key }
                    if !isOpen { keys.append(key) }
                    closed = keys.joined(separator: ",")
                })
    }
}
