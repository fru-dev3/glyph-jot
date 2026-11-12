import AppKit
import SystemConfiguration

/// A thought (talk key + Shift) is a Markdown note with the same frontmatter as Jot on the
/// iPhone's memos. It goes in the notes folder chosen in Settings (any folder: an Obsidian
/// vault works), or `<vault>/data/domains/notes/source/jot` when that folder is a Glyph Bot
/// vault, or `~/Documents/Jot/Thoughts` when none is chosen.
enum Thoughts {
    static var folder: URL {
        DictationLog.vault?.appending(path: "data/domains/notes/source/jot")
            ?? DictationLog.chosen
            ?? URL.documentsDirectory.appending(path: "Jot/Thoughts")
    }

    /// Saves it and returns the file's name. `kind`: voice (Fn+Shift) or typed (New Note on the Mac).
    /// A note that starts with a domain ("Health: ...", "For career, ...") is filed to it:
    /// `domain: health` in its front matter, the words without the lead-in.
    @discardableResult static func save(_ text: String, kind: String = "voice") throws -> String {
        let (domain, text) = VaultDomains.split(text, among: VaultDomains.all)
        let now = Date.now
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss" // the phone's memo names
        let stem = f.string(from: now)
        let date = stem.prefix(10) + "T" + stem.dropFirst(11).replacingOccurrences(of: "-", with: ":")
        let device = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        let md = "---\ndate: \(date)\ntags: []\n" + (domain.map { "domain: \($0)\n" } ?? "") + "kind: \(kind)\ndevice: \(device)\nsource: jot\n---\n\n\(text)\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try md.write(to: folder.appending(path: stem + ".md"), atomically: true, encoding: .utf8)
        return stem + ".md"
    }
}

/// The vault's life domains (`data/domains/<slug>/`), the same list Glyph CRM and Studio use.
enum VaultDomains {
    static var all: [String] {
        guard let vault = DictationLog.vault else { return [] }
        let dir = vault.appending(path: "data/domains")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
    }

    /// "Health: slept badly" or "For real estate, call the agent" -> ("health", "Slept badly").
    /// Only a domain that exists, said first and followed by a colon, comma or full stop.
    static func split(_ text: String, among domains: [String]) -> (String?, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        for lead in ["for the ", "for ", "in ", ""] where lower.hasPrefix(lead) {
            // Longest name first, so "real estate" wins over a shorter one it starts with.
            for slug in domains.sorted(by: { $0.count > $1.count }) {
                let name = slug.replacingOccurrences(of: "-", with: " ")
                let head = lower.dropFirst(lead.count)
                guard head.hasPrefix(name), let mark = head.dropFirst(name.count).first, ":,.".contains(mark) else { continue }
                var rest = String(t.dropFirst(lead.count + name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty else { continue }
                rest = rest.prefix(1).uppercased() + rest.dropFirst()
                return (slug, rest)
            }
        }
        return (nil, t)
    }

    /// Glyph CRM's icon for each domain; others get a plain grid.
    static func symbol(_ slug: String) -> String {
        let s: [String: String] = [
            "health": "heart.fill", "wealth": "chart.line.uptrend.xyaxis", "money": "dollarsign.circle.fill", "tax": "doc.text.fill",
            "insurance": "shield.lefthalf.filled", "career": "briefcase.fill", "business": "building.2.fill", "faith": "sun.max.fill",
            "family": "figure.2.and.child.holdinghands", "growth": "leaf.fill", "homestead": "house.fill", "learning": "book.fill",
            "real-estate": "building.columns.fill", "benefits": "gift.fill", "estate": "scroll.fill", "crm": "person.crop.rectangle.stack.fill",
            "dev": "chevron.left.forwardslash.chevron.right", "content": "play.rectangle.fill", "notes": "note.text", "time": "clock.fill",
            "general": "square.grid.2x2.fill", "explore": "map.fill", "civic": "building.fill", "dreams": "moon.stars.fill",
            "productivity": "checklist", "records": "archivebox.fill", "build": "hammer.fill",
        ]
        // ponytail: copied from Glyph CRM's Domain.symbols (another package); move to GlyphCore if a third app needs it.
        return s[slug] ?? "square.grid.2x2.fill"
    }
}

/// The words of a long dictation so far, saved every 10 seconds while you talk:
/// `<vault>/data/apps/jot/drafts/unfinished.<host>.txt`. Cleared when the dictation lands.
enum Draft {
    static var url: URL {
        DictationLog.folder.deletingLastPathComponent().appending(path: "drafts/unfinished.\(DictationLog.host).txt")
    }

    static func save(_ words: String) {
        guard !words.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? words.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// The draft left by a dictation that never finished, removed as it's read.
    static func take() -> String? {
        defer { clear() }
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Every dictation, one JSON line each: `<YYYY-MM>.<host>.jsonl`, one file per Mac so syncing
/// the folder between Macs never conflicts. Beside it are the Dictionary and the draft. They live
/// in `data/apps/jot/` in a Glyph Bot vault, in a hidden `.jot/` in any other notes folder (so they
/// sync with it but stay out of your notes), and in Application Support when none is chosen.
enum DictationLog {
    /// The notes folder: the one chosen in Settings, else this Mac's own (`LocalVault`).
    static var chosen: URL? {
        guard let path = jotDefaults.string(forKey: "vaultPath") ?? LocalVault.path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// The notes folder when it is a Glyph Bot vault (it has `data/domains`).
    static var vault: URL? {
        chosen.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "data/domains").path) ? $0 : nil }
    }

    static var folder: URL {
        vault?.appending(path: "data/apps/jot/dictations")
            ?? chosen?.appending(path: ".jot/dictations")
            ?? URL.applicationSupportDirectory.appending(path: "Jot/dictations")
    }

    /// Same host naming as Glyph Bot's prompt streams: "Mac-Name.local" -> "mac-name-local".
    /// From the Mac's own Bonjour name, never DNS: `ProcessInfo.hostName` asks the network,
    /// which hung the engine's launch for minutes and gave a second name on the tailnet.
    static let host: String = {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac"
        return (name + ".local").lowercased().replacingOccurrences(of: ".", with: "-")
    }()

    /// `heard` is the transcript before polishing (or the spoken command), so a bad cleanup
    /// can always be undone from the log.
    /// `project` (the repo or folder of a terminal or editor) is left out when unknown; older lines have none.
    static func append(text: String, heard: String, mode: String, app: NSRunningApplication?, project: String?,
                       seconds: Double, finishMs: Int) {
        let now = Date.now
        var entry: [String: Any] = [
            "at": now.ISO8601Format(),
            "text": text,
            "heard": heard,
            "mode": mode,
            "app": app?.localizedName ?? "",
            "bundle": app?.bundleIdentifier ?? "",
            "device": SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac", // the machine it came from
            "seconds": (seconds * 10).rounded() / 10,
            "finish_ms": finishMs,
        ]
        if let project { entry["project"] = project }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let month = now.formatted(.iso8601.year().month())
        add(line, to: folder.appending(path: "\(month).\(host).jsonl"))
    }

    /// Appends a line to a file, making the file and its folder if need be. It says whether the
    /// bytes landed, so a fold-back only lets go of the old copy once the new one has them.
    @discardableResult static func add(_ line: Data, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do { try handle.write(contentsOf: line); return true } catch { return false }
        }
        do { try line.write(to: file); return true } catch { return false }
    }
}

/// What was written while the notes folder was away comes back the first time it is reachable.
/// The folder is away when none has been chosen yet, or when the one chosen is on a volume that
/// is not there: dictations then go to Application Support and thoughts to `~/Documents/Jot`,
/// and until now they stayed there. Nothing is ever overwritten, and a file leaves the old place
/// only once it is safely in the new one.
enum FoldBack {
    static func run() {
        let home = DictationLog.folder.deletingLastPathComponent()
        // There are two places to come back from, not one. The hidden `.jot` is the likelier of the
        // two to hold real work: it means a folder was chosen and the app was being used in
        // earnest, and the day Glyph Bot makes that folder a vault the writes move to
        // `data/apps/jot` and leave it behind. (Found by the Glyph Well tab, 2026-10-31.)
        for away in [URL.applicationSupportDirectory.appending(path: "Jot"),
                     DictationLog.chosen?.appending(path: ".jot")].compactMap({ $0 }) where away != home {
            // The dictation log and the stars are append-only lines, so they fold line by line.
            for log in ["dictations", "stars"] {
                lines(from: away.appending(path: log), to: home.appending(path: log))
            }
            // Everything else is carried whole, and it is named by exclusion rather than by a
            // list on purpose: a shape nobody has thought of yet then waits in the new folder
            // instead of being stranded for good in the old one. The two left out are this Mac's
            // own bookkeeping, so carrying them would mean nothing: `drafts` holds one unfinished
            // dictation that the next one reads and clears, and `link-review.json` is this Mac's
            // place in a review. Anything he asked for by name belongs with him.
            // (The rule is the Glyph Time tab's, 2026-10-31.)
            carry(away, to: home, except: ["dictations", "stars", "drafts", "link-review.json"])
        }
        // Thoughts come back from Jot's own folder only. The chosen folder's root is the other
        // place they can land, and it is not ours to sweep: it may be an Obsidian vault, and its
        // Markdown is the person's own notes, not Jot's.
        notes(from: URL.documentsDirectory.appending(path: "Jot/Thoughts"), to: Thoughts.folder)
    }

    /// Dictation logs: both places name the file for the month and the Mac, so the lines are
    /// appended to the one in use. They are whole JSON lines, so a log never ends up half a line,
    /// and a line already there is left out, so this is safe to run again: should the old file
    /// fail to go, the next launch adds nothing rather than a second copy of every line.
    static func lines(from old: URL, to new: URL) {
        guard old != new, let names = try? FileManager.default.contentsOfDirectory(atPath: old.path) else { return }
        for name in names.sorted() where name.hasSuffix(".jsonl") {
            let file = old.appending(path: name)
            let to = new.appending(path: name)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let already = (try? String(contentsOf: to, encoding: .utf8)) ?? ""
            let adding = text.split(separator: "\n").filter { !Set(already.split(separator: "\n")).contains($0) }
            guard !adding.isEmpty else { try? FileManager.default.removeItem(at: file); continue }
            // A write cut short leaves the log without its last newline. Put it back before adding,
            // or the first line folded in fuses onto it and both lines are lost, not just one.
            let lead = already.isEmpty || already.hasSuffix("\n") ? "" : "\n"
            if DictationLog.add(Data((lead + adding.joined(separator: "\n") + "\n").utf8), to: to) {
                try? FileManager.default.removeItem(at: file)
            } else {
                log.notice("fold-back: \(adding.count) lines of \(name) stay where they were")
            }
        }
    }

    /// Carries whole files across, at any depth. A file is moved only into a name that is free:
    /// never appended to, because it is not a log and appending would make nonsense of it, and
    /// never written over, because what is already in the new folder is his too. `except` holds
    /// back the names handled another way, and only at the top: everything under a folder that is
    /// carried comes with it.
    static func carry(_ old: URL, to new: URL, except: Set<String> = []) {
        let fm = FileManager.default
        guard old != new, let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        for name in names.sorted() where !except.contains(name) {
            let from = old.appending(path: name)
            var folder: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &folder) else { continue }
            if folder.boolValue { carry(from, to: new.appending(path: name)) }
            else { whole(from, to: new.appending(path: name)) }
        }
    }

    /// The Dictionary (his words and his snippets) is one whole file, not a log, so appending
    /// would make nonsense of it. It comes across when there is none to lose, and is otherwise
    /// left where it is: merging two of his dictionaries is a guess, and the wrong guess drops a
    /// word he added. Settings already carries the Dictionary over when he changes the folder
    /// himself; this is for the change he never made.
    static func whole(_ old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        do {
            guard !fm.fileExists(atPath: new.path) else { throw CocoaError(.fileWriteFileExists) }
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
        } catch {
            // Waiting is recoverable; saying nothing about it is not. A file that can never come
            // across would otherwise sit in the old folder for good with nothing pointing at it.
            log.notice("fold-back: \(new.lastPathComponent) stays where it was (\(error.localizedDescription))")
        }
    }

    /// Thoughts: one file each, named for the moment it was said, so they move as they are. A name
    /// already taken in the new folder is left alone rather than written over.
    static func notes(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard old != new, let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in names.sorted() where name.hasSuffix(".md") {
            let to = new.appending(path: name)
            if !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: old.appending(path: name), to: to) }
        }
    }
}
