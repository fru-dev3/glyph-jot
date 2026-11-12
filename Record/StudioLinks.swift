import Foundation
import GlyphCore

/// A new Glyph CRM entity, written as the page the CRM and Glyph Bot's engine read and
/// write (`data/entities/<kind>/<slug>/entity.md`, the CRM's `Page.new(...).render()`), with its
/// permanent `id:` line. Files only: no command, no database. An entity that already answers
/// to the name is used instead of making a second one.
enum EntityPage {
    /// Makes `name` as a `kind` in the vault at `root`; returns its id, or nil when it can't.
    static func create(_ kind: StudioObject.Kind, _ name: String, notes: String = "", in root: URL, now: Date = .now) -> String? {
        let clean = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard let folder = kind.folder, !clean.isEmpty else { return nil }
        let dir = root.appending(path: "data/entities/\(folder)")
        var slug = StudioDirectory.slug(clean)
        if slug.isEmpty { slug = "\(kind.prefix)-\(Int(now.timeIntervalSince1970))" }
        let base = slug
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: dir.appending(path: slug).path) || fm.fileExists(atPath: dir.appending(path: slug + ".md").path) {
            slug = "\(base)-\(n)"; n += 1
        }
        let id = "\(kind.prefix)/\(slug)"
        let file = dir.appending(path: slug).appending(path: "entity.md")
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try render(name: clean, kind: kind, id: id, notes: notes, now: now).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            jotLog.error("crm: could not make \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        jotLog.notice("crm: made \(id, privacy: .public)")
        return id
    }

    static func render(name: String, kind: StudioObject.Kind, id: String, notes: String, now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        let at = f.string(from: now)
        let day = String(at.prefix(10))
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = ["---", "name: \(yamlStr(name))", "kind: \(kind.prefix)", "aliases: []", "saved: true", "created: \(at)", "updated: \(at)",
                     "mention_count: 0", "id: \(id)", "---", "", "## Your notes", "", note.isEmpty ? "" : "\(day): \(note)\n",
                     "## Conversations", "", "_No conversations yet._", ""]
        return lines.joined(separator: "\n")
    }

    /// The engine's `yamlStr`: plain when safe, else a JSON string.
    static func yamlStr(_ s: String) -> String {
        let plain = s.range(of: #"^[\w .,'()&+-]*$"#, options: .regularExpression) != nil
        let risky = s.range(of: #"^[\s-]|:\s|\s$"#, options: .regularExpression) != nil
            || s.range(of: #"^(true|false|null|\d)"#, options: [.regularExpression, .caseInsensitive]) != nil
        if plain, !risky, !s.isEmpty { return s }
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One thing Glyph Jot captured, of any kind, for the All view.
struct Capture: Identifiable, Hashable {
    enum Kind: String { case note, dictation, recording }
    var kind: Kind
    var id: String
    var title: String
    var date: Date
    var links: [String] = []
    /// The #tags it is filed under; the first one is the one a row shows.
    var tags: [String] = []
    /// The words after the title, when they are already in memory (a note, a dictation). A
    /// recording's are in its summary file and are read by the row that shows them.
    var snippet: String = ""
    /// How long it ran. Zero for anything typed.
    var seconds: Double = 0
    /// Vault state, and nothing else: everything of it is in the vault, words and sound. False
    /// while a recording is still being transcribed, which is the grey tick.
    var kept = true

    var symbol: String {
        switch kind {
        case .note: "note.text"
        case .dictation: "text.cursor"
        case .recording: "waveform"
        }
    }
}

extension Link {
    /// The Studio kind of an object link, or of a new name (`.person` a person, `.account` a product).
    var studioKind: StudioObject.Kind? {
        switch self {
        case .object(let id): StudioObject.Kind(id: id)
        case .person: .person
        case .account: .org
        case .tag: nil
        }
    }
}

extension StudioObject.Kind {
    /// The sidebar's and the chips' icon (SF Symbols close to the CRM's).
    var symbol: String {
        switch self {
        case .person: "person.fill"
        case .org: "building.2.fill"
        case .project: "flag.fill"
        case .domain: "square.grid.2x2.fill"
        case .place: "mappin.and.ellipse"
        case .thing: "applewatch"
        }
    }

    /// The order Glyph Jot lists them in.
    static let listed: [StudioObject.Kind] = [.person, .place, .org, .thing, .project, .domain]
}
