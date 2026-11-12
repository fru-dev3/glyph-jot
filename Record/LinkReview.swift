import GlyphCore
import SwiftUI

/// Older notes that say a Glyph CRM name but aren't linked to it: proposals you accept in
/// batches, never a silent rewrite. A name two entities share ("John") is a question, not a
/// guess. Skipped proposals are remembered in the vault (`data/apps/jot/link-review.json`).
struct LinkProposal: Identifiable, Hashable {
    var id: String { file }
    let file: String
    let title: String
    let date: Date
    /// Ids it names without doubt.
    var sure: [String]
    /// Each a set of namesakes the note could mean ("Which John?").
    var which: [[String]]
}

@MainActor
enum LinkReview {
    static let batch = 25

    static var url: URL { DictationLog.folder.deletingLastPathComponent().appending(path: "link-review.json") }

    static func skipped() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(json["skipped"] as? [String] ?? [])
    }

    static func skip(_ keys: [String]) {
        let all = (skipped().union(keys)).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: ["skipped": all], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Newest notes first. Names under four letters are left out ("Mac" is not a proposal).
    static func proposals(_ notes: [JotNote], studio: StudioDirectory, skipped: Set<String>) -> [LinkProposal] {
        notes.compactMap { note in
            let said = studio.mentioned(in: note.text, kinds: StudioObject.Kind.entities)
                .filter { o in ([o.name] + o.aliases).contains { $0.count >= 4 && mentions(note.text, $0) } }
                .filter { !note.links.contains($0.id) && !skipped.contains(note.file + "|" + $0.id) }
            guard !said.isEmpty else { return nil }
            var sure: [String] = [], which: [[String]] = []
            for o in said {
                let twins = studio.namesakes(o).map(\.id).filter { id in said.contains { $0.id == id } }
                if twins.isEmpty { sure.append(o.id); continue }
                let group = ([o.id] + twins).sorted()
                if !which.contains(group) { which.append(group) }
            }
            return LinkProposal(file: note.file, title: note.title, date: note.date, sure: sure, which: which)
        }
    }

    private static func mentions(_ text: String, _ name: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// The review sheet: a batch of notes with the entities each one names, ticked; "Which John?"
/// asks. Link writes `entities:` into each note's front matter; Skip remembers the no.
struct LinkReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var all: [LinkProposal] = []
    @State private var off: Set<String> = []       // "file|id" unticked
    @State private var chosen: [String: String] = [:] // "file|group" -> id picked
    @State private var linked = 0

    private var shown: [LinkProposal] { Array(all.prefix(LinkReview.batch)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Link older notes").font(.system(size: 22, weight: .bold))
                Text(all.isEmpty
                     ? (linked > 0 ? "Done. \(linked) notes now carry their Glyph CRM links." : "Every note that names someone or something in Glyph CRM is linked.")
                     : "\(all.count == 1 ? "1 note names" : "\(all.count) notes name") people, places, products or things in Glyph CRM. Nothing changes until you link \(all.count == 1 ? "it" : "them"); each note keeps the ids in its own file.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            List {
                ForEach(shown) { p in row(p) }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
            Divider()
            HStack {
                if !all.isEmpty {
                    Text(all.count > LinkReview.batch ? "Showing \(LinkReview.batch) of \(all.count)" : "")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(all.isEmpty ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !all.isEmpty {
                    Button("Skip These") { skipBatch() }
                        .help("Don't propose these again")
                        .accessibilityIdentifier("review-skip")
                    Button(shown.count == 1 ? "Link 1 Note" : "Link \(shown.count) Notes") { linkBatch() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("review-link")
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: load)
        .onChange(of: model.reviewApply) { linkBatch() } // debug hook: the Link button, without a click
    }

    private func row(_ p: LinkProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Text(Format.shortDate(p.date.ISO8601Format())).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(p.sure, id: \.self) { id in
                    let key = p.file + "|" + id
                    Toggle(isOn: Binding(get: { !off.contains(key) }, set: { if $0 { off.remove(key) } else { off.insert(key) } })) {
                        Label(model.studio.name(id), systemImage: StudioObject.Kind(id: id)?.symbol ?? "link")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
                ForEach(p.which, id: \.self) { group in
                    let key = p.file + "|" + group.joined(separator: ",")
                    Picker(selection: Binding(get: { chosen[key] ?? "" }, set: { chosen[key] = $0 })) {
                        Text("Neither").tag("")
                        ForEach(group, id: \.self) { id in Text("\(model.studio.name(id)), \(id.split(separator: "/").last ?? "")").tag(id) }
                    } label: {
                        Text("Which \(model.studio.name(group[0]).split(separator: " ").first.map(String.init) ?? "one")?")
                    }
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func load() {
        all = LinkReview.proposals(NoteStore.shared.notes, studio: model.studio, skipped: LinkReview.skipped())
        off = []
        chosen = [:]
    }

    private func linkBatch() {
        var skip: [String] = []
        for p in shown {
            guard let note = NoteStore.shared.notes.first(where: { $0.file == p.file }) else { continue }
            var ids = p.sure.filter { !off.contains(p.file + "|" + $0) }
            skip += p.sure.filter { off.contains(p.file + "|" + $0) }.map { p.file + "|" + $0 }
            for group in p.which {
                if let pick = chosen[p.file + "|" + group.joined(separator: ",")], !pick.isEmpty { ids.append(pick) }
                else { skip += group.map { p.file + "|" + $0 } }
            }
            if !ids.isEmpty {
                do { try NoteStore.shared.setLinks(p.file, links: note.links + ids, tags: note.tags); linked += 1 }
                catch { model.show(error.localizedDescription) }
            }
        }
        LinkReview.skip(skip)
        load()
    }

    private func skipBatch() {
        LinkReview.skip(shown.flatMap { p in (p.sure + p.which.flatMap { $0 }).map { p.file + "|" + $0 } })
        load()
    }
}
