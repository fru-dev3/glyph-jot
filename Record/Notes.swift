import AppKit
import GlyphCore
import SwiftUI

/// A note: a thought saved with Fn+Shift on the Mac or a memo from the Glyph iPhone app,
/// one Markdown file each in the notes folder (`Thoughts.folder`).
struct JotNote: Identifiable, Hashable {
    var id: String { file }
    let file: String
    let url: URL
    let date: Date
    let text: String
    let device: String?
    let place: String?
    let tags: [String]
    /// Glyph CRM entities (and Studio projects, domains) it is filed under, by permanent id:
    /// front matter `entities: [person/ken-lee]`, the key the CRM reads. Older notes said `links:`.
    var links: [String] = []
    /// The life domain it is filed to (`domain: health`), said first or picked after.
    var domain: String?
    /// Places it is filed to without moving (`links: [data/entities/orgs/acme]`, CrossLink): vault paths.
    var filed: [String] = []

    /// Front matter between `---` lines, then the text. Missing fields stay nil.
    static func read(_ url: URL) -> JotNote? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        var body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { fields[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            body = String(raw[end.upperBound...])
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let date = fields["date"].flatMap(parseDate) ?? stemDate(url.deletingPathExtension().lastPathComponent)
            ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast)
        let list = { (key: String) in (fields[key] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty } }
        return JotNote(file: url.lastPathComponent, url: url, date: date, text: text,
                       device: fields["device"], place: fields["place"], tags: list("tags"),
                       links: (list("entities") + list("links").filter { !$0.hasPrefix("data/") }).reduce(into: []) { out, x in if !out.contains(x) { out.append(x) } },
                       domain: fields["domain"].flatMap { $0.isEmpty ? nil : $0 },
                       filed: list("links").filter { $0.hasPrefix("data/") })
    }

    /// "2026-10-25T12:08:24", local time, as the phone and the Mac write it.
    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    private static func stemDate(_ stem: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.date(from: stem)
    }

    /// `raw` with these front matter lists set (added before the closing `---`, or in a new
    /// front matter); `entities` is left out when empty, and an older `links:` line goes (its ids
    /// are in `entities` now).
    static func withFields(_ raw: String, _ fields: [String: [String]], domain: String?? = .none) -> String {
        var head: [String] = [], body = raw
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            head = raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            body = String(raw[end.upperBound...])
        } else {
            body = "\n\n" + raw
        }
        for key in fields.keys.sorted() {
            let values = fields[key] ?? []
            let line = "\(key): [\(values.joined(separator: ", "))]"
            if key == "entities" { head.removeAll { $0.hasPrefix("links:") } }
            if let i = head.firstIndex(where: { $0.hasPrefix(key + ":") }) {
                if values.isEmpty, key == "entities" { head.remove(at: i) } else { head[i] = line }
            } else if !(values.isEmpty && key == "entities") {
                head.append(line)
            }
        }
        // `domain` is one value: set, replaced, or (nil) taken out; left alone when not passed.
        if case .some(let d) = domain {
            let i = head.firstIndex { $0.hasPrefix("domain:") }
            switch (d, i) {
            case (let d?, let i?): head[i] = "domain: \(d)"
            case (let d?, nil): head.insert("domain: \(d)", at: head.firstIndex { $0.hasPrefix("tags:") }.map { $0 + 1 } ?? head.count)
            case (nil, let i?): head.remove(at: i)
            case (nil, nil): break
            }
        }
        // Filings (vault paths under `links:`) outlive the older CRM ids that line held.
        let filed = CrossLink.links(raw), out = "---\n" + head.joined(separator: "\n") + "\n---" + body
        return filed.isEmpty || fields["entities"] == nil ? out : CrossLink.setLinks(out, filed)
    }

    var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        return first.count > 90 ? String(first.prefix(88)) + "\u{2026}" : first
    }
}

/// Every note, newest first; read again when the window comes forward or a note is saved.
@MainActor @Observable
final class NoteStore {
    static let shared = NoteStore()
    private(set) var notes: [JotNote] = []
    private(set) var dictationCount = 0

    /// Writes a note's entities and tags into its own front matter (`entities: [person/ken-lee]`,
    /// `tags: [knowledge]`), in the vault; every other line stays. Nothing is kept anywhere else.
    func setLinks(_ file: String, links: [String], tags: [String]) throws {
        guard let note = notes.first(where: { $0.file == file }) else { return }
        let raw = try String(contentsOf: note.url, encoding: .utf8)
        let unique = { (xs: [String]) in xs.reduce(into: [String]()) { out, x in if !out.contains(x) { out.append(x) } } }
        // Tags the note already has stay as written (the phone writes "Knowledge"); new ones are tidied.
        let kept = tags.map { t in note.tags.contains(t) ? t : LinkMatcher.tidyTag(t) }.filter { !$0.isEmpty }
        let text = JotNote.withFields(raw, ["entities": unique(links), "tags": unique(kept)])
        try text.write(to: note.url, atomically: true, encoding: .utf8)
        reload()
    }

    /// Files a note to a life domain (`domain: health`), or takes it off (nil). Nothing else changes.
    func setDomain(_ file: String, _ domain: String?) throws {
        guard let note = notes.first(where: { $0.file == file }) else { return }
        let raw = try String(contentsOf: note.url, encoding: .utf8)
        try JotNote.withFields(raw, [:], domain: .some(domain)).write(to: note.url, atomically: true, encoding: .utf8)
        reload()
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var settle: DispatchWorkItem?

    /// Reads the notes again whenever the folder changes: a note the phone sends, or fixes after
    /// it was sent, shows up without waiting for the window to come forward. The folder's own
    /// write event fires when a file in it is added, replaced or removed (the inbox and vault
    /// sync both replace files whole).
    private func watch(_ folder: URL) {
        guard watcher == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.settle?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { self?.reload() } }
            self?.settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func reload() {
        let folder = Thoughts.folder
        watch(folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        notes = files.filter { $0.pathExtension == "md" }.compactMap(JotNote.read).sorted { $0.date > $1.date }
        dictationCount = HistoryView.load().count
    }
}

/// Notes: a list and the open note, in the space the conversations use.
struct NotesPane: View {
    @Environment(AppModel.self) private var model
    @State private var store = NoteStore.shared
    @State private var selected: JotNote.ID?

    private var shown: [JotNote] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.notes : store.notes.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.place ?? "").localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if model.showList {
                    list.frame(width: min(model.listWidth, max(250, geo.size.width * 0.4)))
                    ResizeHandle(width: Binding(get: { model.listWidth }, set: { model.listWidth = $0 }))
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear {
            if let note = model.openNote { selected = note; model.openNote = nil }
            if selected == nil { selected = shown.first?.id }
        }
        .onChange(of: model.openNote) { if let note = model.openNote { selected = note; model.openNote = nil } }
        .sheet(isPresented: Binding(get: { model.writingNote }, set: { model.writingNote = $0 })) {
            NewNoteSheet { file in
                model.writingNote = false
                guard let file else { return }
                store.reload()
                model.searchText = ""
                selected = file
            }
        }
        .onChange(of: model.searchText) { if !shown.contains(where: { $0.id == selected }) { selected = shown.first?.id } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Notes", symbol: "note.text", line: shown.count == 1 ? "1 note" : "\(shown.count) notes") {
                Button { model.writingNote = true } label: { Image(systemName: "plus").font(.system(size: 15, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help("New Note (\u{2318}N)")
                    .accessibilityIdentifier("new-note")
            }
            if shown.isEmpty {
                EmptyState(symbol: "note.text", title: model.searchText.isEmpty ? "No notes yet" : "No matches",
                           message: model.searchText.isEmpty ? "Hold Fn and Shift, say a thought, let go. It lands here." : "No note says \u{201C}\(model.searchText)\u{201D}.")
            } else {
                List(selection: $selected) {
                    ForEach(shown) { note in
                        NoteRow(note: note, linked: model.recordingFor(note: note.file) != nil).tag(note.id)
                            .contextMenu { NoteMenu(note: note) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder private var detail: some View {
        if let note = shown.first(where: { $0.id == selected }) {
            NoteDetail(note: note).id(note.id)
        } else {
            EmptyState(symbol: "note.text", title: "Pick a note") {
                VStack(alignment: .leading, spacing: 10) {
                    KeyHint(keys: "fn \u{21E7}", label: "Hold to say a note, anywhere")
                    KeyHint(keys: "fn", label: "Hold to type what you say, where you are")
                }
            }
        }
    }
}

/// The big title over a list: what it is and how many.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    let line: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11))
                    Text(line)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, symbol: String, line: String) {
        self.init(title: title, symbol: symbol, line: line) { EmptyView() }
    }
}

/// New Note: type a thought (or hold Fn and say it into the field). Saved as a typed note in the
/// notes folder, the vault's notes domain, beside the phone's memos and Fn+Shift's notes.
struct NewNoteSheet: View {
    let done: (String?) -> Void
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Note").font(.system(size: 20, weight: .bold))
            TextEditor(text: $text)
                .font(.system(size: 16))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .focused($focused)
                .accessibilityIdentifier("new-note-text")
            HStack {
                Text(problem ?? "Type it, or hold \(Prefs.shared.talkKey.name) and say it.")
                    .font(.system(size: 12))
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(blank)
                    .accessibilityIdentifier("new-note-save")
            }
        }
        .padding(20)
        .frame(width: 520, height: 340)
        .onAppear { focused = true }
    }

    private func save() {
        guard !blank else { return }
        do {
            done(try Thoughts.save(text.trimmingCharacters(in: .whitespacesAndNewlines), kind: "typed"))
        } catch {
            // Keep the words on screen: a note is never dropped because the folder failed.
            problem = "Couldn't save: \(error.localizedDescription). Your words are still here."
        }
    }
}

struct NoteRow: View {
    let note: JotNote
    let linked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(Format.shortDate(note.date.ISO8601Format()))
                if let device = note.device { Text("\u{00B7}"); Text(device).lineLimit(1) }
                Spacer(minLength: 4)
                if linked {
                    Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(.tint)
                        .help("Said during a recording")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

struct NoteDetail: View {
    let note: JotNote
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()))
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(2)  // wraps like a recording's title; never cut off at the narrowest window
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Menu { NoteMenu(note: note) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden)
                        .help("More")
                }
                NoteSuggestions(note: note)
                FlowLayout(spacing: 6) {
                    DomainPicker(note: note)
                    FilePicker(note: note)
                    ForEach(note.filed, id: \.self) { FiledChip(note: note, place: $0) }
                    if let device = note.device { MetaChip(symbol: note.device?.contains("iPhone") == true ? "iphone" : "laptopcomputer", text: device) }
                    if let place = note.place { MetaChip(symbol: "mappin.and.ellipse", text: place) }
                    if let (id, at) = model.recordingFor(note: note.file), let meta = model.meta(id) {
                        Button {
                            model.sidebar = .recordings
                            model.selectedID = id
                            model.tab = .transcript
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                                Text("\(meta.title) at \(Format.clock(at))").font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open the recording this note was said in")
                    }
                }
                // The domain shows once, as its own chip above.
                LinkEditor(target: .note(note.file), links: note.links.filter { $0 != note.domain.map { "domain/" + $0 } }.map { .object($0) } + note.tags.map { .tag($0) })
                Text(note.text)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { Engine.shared.send(.init(.insert, text: note.text)) } label: { Label("Insert", systemImage: "text.insert") }
                        .help("Type it into the app you were in")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NoteMenu: View {
    let note: JotNote

    var body: some View {
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(NoteFiling.path(note) ?? note.url.path, forType: .string)
        }
        Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
    }
}

/// Dictations: everything you said into other apps, with stats, filters and Ask.
struct DictationsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HistoryView(search: model.searchText)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Notes that name a person or an account (or one of its aliases), for its page.
@MainActor
func notesMentioning(_ names: [String]) -> [JotNote] {
    let words = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
    guard !words.isEmpty else { return [] }
    return NoteStore.shared.notes.filter { note in
        words.contains { w in note.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

/// The life domain a note is filed to: a chip with the domain's icon (Glyph CRM's), and a menu of
/// the vault's domains to pick, change or take off. Saying "Health: ..." first files it too.
struct DomainPicker: View {
    let note: JotNote
    @Environment(AppModel.self) private var model

    var body: some View {
        let domains = VaultDomains.all
        if !domains.isEmpty || note.domain != nil {
            Menu {
                ForEach(domains, id: \.self) { slug in
                    Button { set(slug) } label: { Label(model.studio.name("domain/" + slug), systemImage: VaultDomains.symbol(slug)) }
                }
                if note.domain != nil {
                    Divider()
                    Button("No Domain") { set(nil) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: note.domain.map(VaultDomains.symbol) ?? "square.grid.2x2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(note.domain == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    Text(note.domain.map { model.studio.name("domain/" + $0) } ?? "File to a domain")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(note.domain == nil ? .secondary : .primary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(note.domain == nil ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.accentColor.opacity(0.10)), in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("The life domain this note belongs to, saved as domain: in the note's file. Say \u{201C}Health: ...\u{201D} first to file it as you jot.")
            .accessibilityIdentifier("note-domain")
        }
    }

    private func set(_ slug: String?) {
        do { try NoteStore.shared.setDomain(note.file, slug) } catch { model.show(error.localizedDescription) }
    }
}

/// Filing a note to any place in the vault without moving it (GlyphVault `CrossLink`): an application folder,
/// a CRM page, a project, a domain, Whispers. Suggestions come from Glyph Core Intelligence (the hub's
/// `/understand`, kind "file"), never from a model on this Mac.
@MainActor @Observable
final class NoteFiling {
    static let shared = NoteFiling()
    /// Suggestions per note file, asked once per launch (nil while asking or when the hub is away).
    private(set) var suggested: [String: [FilePlace]] = [:]
    /// The tags Glyph suggests for a note, from his own vocabulary (the tags his notes already carry).
    private(set) var suggestedTags: [String: [String]] = [:]
    private var asked: Set<String> = []
    private(set) var places: [FilePlace] = []

    static var vault: URL? { DictationLog.vault }

    /// The note's path inside the vault ("data/domains/notes/source/jot/2026-10-30 09-00-00.md").
    static func path(_ note: JotNote) -> String? {
        guard let v = vault?.standardizedFileURL.path, note.url.standardizedFileURL.path.hasPrefix(v + "/") else { return nil }
        return String(note.url.standardizedFileURL.path.dropFirst(v.count + 1))
    }

    /// The hub (GLYPH_VAULT_URL, as in ~/.config/glyph/env): where Glyph Core Intelligence answers.
    static let hub: Hub? = {
        let env = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/glyph/env"), encoding: .utf8)) ?? ""
        let line = env.split(separator: "\n").first { $0.hasPrefix("GLYPH_VAULT_URL=") }.map { String($0.dropFirst(16)) }
        let raw = (ProcessInfo.processInfo.environment["GLYPH_VAULT_URL"] ?? line ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return Hub(base: url, model: "Mac", app: "Glyph Jot")
    }()

    func loadPlaces() {
        guard let v = Self.vault else { return }
        Task.detached { let p = CrossLink.places(in: v); await MainActor.run { NoteFiling.shared.places = p } }
    }

    func suggest(_ note: JotNote) {
        guard !asked.contains(note.file), let hub = Self.hub else { return }
        asked.insert(note.file)
        let text = note.text
        Task {
            guard let got = await hub.suggestPlaces(for: text) else { asked.remove(note.file); return }
            suggested[note.file] = got.places
            suggestedTags[note.file] = got.tags
        }
    }

    func label(_ path: String) -> String {
        places.first { $0.path == path }?.label ?? CrossLink.title((path as NSString).lastPathComponent)
    }

    func file(_ note: JotNote, to place: FilePlace) {
        guard let v = Self.vault, let rel = Self.path(note) else { return AppModel.shared.show("Filing needs the notes folder inside a vault.") }
        do {
            try CrossLink.file(note: rel, title: note.title, to: place.path, in: v)
            NoteStore.shared.reload()
            AppModel.shared.show("Filed under \(place.label). The note stays where it is.", fix: .unfile(note: rel, place: place.path))
        } catch { AppModel.shared.show(error.localizedDescription) }
    }

    /// Adds one suggested tag to the note. Its other tags, its entities and its text stay as they are.
    func tag(_ note: JotNote, _ name: String) {
        do { try NoteStore.shared.setLinks(note.file, links: note.links, tags: note.tags + [name]) }
        catch { AppModel.shared.show(error.localizedDescription) }
    }

    func unfile(note rel: String, place: String) {
        guard let v = Self.vault else { return }
        do { try CrossLink.unfile(note: rel, from: place, in: v); NoteStore.shared.reload() } catch { AppModel.shared.show(error.localizedDescription) }
    }
}

/// One line of suggestion chips under the title: where Glyph thinks the note belongs. A click files it.
struct NoteSuggestions: View {
    let note: JotNote
    @State private var filing = NoteFiling.shared

    var body: some View {
        let open = (filing.suggested[note.file] ?? []).filter { !note.filed.contains($0.path) }
        let tags = (filing.suggestedTags[note.file] ?? []).filter { t in !note.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        Group {
            if !open.isEmpty || !tags.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                    ForEach(tags, id: \.self) { t in
                        Button { filing.tag(note, t) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag").font(.system(size: 9, weight: .bold))
                                Text(t).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Tag this note \(t). Nothing else about the note changes.")
                        .accessibilityIdentifier("note-tag-\(t)")
                    }
                    ForEach(open) { p in
                        Button { filing.file(note, to: p) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                                Text(p.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("File it under \(p.label)\(p.reason.map { ": \($0)" } ?? ""). The note stays where it is.")
                        .accessibilityIdentifier("note-suggest-\(p.label)")
                    }
                }
                .lineLimit(1)
            }
        }
        .task(id: note.file) {
            if filing.places.isEmpty { filing.loadPlaces() }
            filing.suggest(note)
        }
    }
}

/// A place the note is filed to; the x takes it back.
struct FiledChip: View {
    let note: JotNote
    let place: String
    @State private var filing = NoteFiling.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tint)
            Text(filing.label(place)).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Button { if let rel = NoteFiling.path(note) { filing.unfile(note: rel, place: place) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Unfile: take the link back (the note never moved)")
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        .help(place)
    }
}

/// "File to..." : search every place in the vault and file the note there.
struct FilePicker: View {
    let note: JotNote
    @State private var filing = NoteFiling.shared
    @State private var open = false
    @State private var query = ""

    var body: some View {
        if NoteFiling.vault != nil {
            Button { filing.loadPlaces(); open = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("File to\u{2026}").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("File it under an application, a person or product, a project, a domain or another place. The note stays where it is; the place links to it.")
            .accessibilityIdentifier("note-file")
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
        }
    }

    private var list: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = filing.places.filter { !note.filed.contains($0.path) && (q.isEmpty || $0.label.lowercased().contains(q) || $0.kind.contains(q)) }.prefix(80)
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Search places", text: $query).textFieldStyle(.roundedBorder).padding(10)
                .accessibilityIdentifier("note-file-search")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown)) { p in
                        Button { filing.file(note, to: p); open = false } label: {
                            HStack {
                                Text(p.label).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text(p.kind.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if shown.isEmpty { Text("No place matches").foregroundStyle(.secondary).padding(12) }
                }
            }
        }
        .frame(width: 320, height: 360)
    }
}
