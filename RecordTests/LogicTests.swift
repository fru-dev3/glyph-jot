import Foundation
import GlyphCore
import SwiftUI
import Testing
@testable import GlyphJot

@MainActor
struct LogicTests {
    let studio = StudioDirectory(objects: [
        StudioObject(id: "person/ken-lee", name: "Ken Lee", aliases: ["Kenny"], kind: .person),
        StudioObject(id: "person/kim-park", name: "Kim Park", kind: .person),
        StudioObject(id: "org/acme", name: "Acme", kind: .org),
        StudioObject(id: "org/globex", name: "Globex", kind: .org),
        StudioObject(id: "domain/career", name: "Career", kind: .domain),
    ])
    let counts = (objects: ["person/ken-lee": 3, "org/acme": 1], tags: ["pricing": 2, "q4-planning": 1])

    @Test func findsStudioObjectsByNameAliasAndWord() {
        #expect(LinkMatcher.candidates("ken", studio: studio, counts: counts).first?.link == .object("person/ken-lee"))
        #expect(LinkMatcher.candidates("kenny", studio: studio, counts: counts).first?.link == .object("person/ken-lee"))
        #expect(LinkMatcher.candidates("park", studio: studio, counts: counts).first?.link == .object("person/kim-park"))
        #expect(LinkMatcher.candidates("glob", studio: studio, counts: counts).first?.link == .object("org/globex"))
        #expect(LinkMatcher.candidates("care", studio: studio, counts: counts).first?.link == .object("domain/career"))
        #expect(LinkMatcher.candidates("ken", studio: studio, counts: counts).first?.count == 3)
    }

    @Test func hashMeansTag() {
        let c = LinkMatcher.candidates("#pri", studio: studio, counts: counts)
        #expect(c.first?.link == .tag("pricing"))
        #expect(c.allSatisfy { if case .tag = $0.link { true } else { false } })
        #expect(LinkMatcher.candidates("#Q4 Budget", studio: studio, counts: counts).last == Candidate(link: .tag("q4-budget"), isNew: true))
    }

    @Test func offersNewPersonOrProductOnlyWhenNotExact() {
        #expect(!LinkMatcher.candidates("Acme", studio: studio, counts: counts).contains { $0.isNew })
        #expect(!LinkMatcher.candidates("kenny", studio: studio, counts: counts).contains { $0.isNew }, "an alias is exact too")
        let new = LinkMatcher.candidates("Pat Doe", studio: studio, counts: counts).filter(\.isNew)
        #expect(new.map { $0.newKind?.singular ?? $0.link.kindName } == ["Person", "Place", "Org", "Thing", "tag"], "the CRM's four kinds, then a tag")
        #expect(new.last?.link == .tag("pat-doe"))
    }

    @Test func excludesLinked() {
        #expect(!LinkMatcher.candidates("ken", studio: studio, counts: counts, excluding: [.object("person/ken-lee")]).contains { $0.link == .object("person/ken-lee") })
    }

    @Test func notesKeepTheirFrontMatterWhenFiled() {
        let raw = "---\ndate: 2026-10-25T12:08:24\ntags: []\nkind: voice\ndevice: iPhone\n---\n\nCall Ken about Acme.\n"
        let filed = JotNote.withFields(raw, ["entities": ["person/ken-lee", "org/acme"], "tags": ["pricing"]])
        #expect(filed == "---\ndate: 2026-10-25T12:08:24\ntags: [pricing]\nkind: voice\ndevice: iPhone\nentities: [person/ken-lee, org/acme]\n---\n\nCall Ken about Acme.\n")
        #expect(JotNote.withFields(filed, ["entities": [], "tags": []]) == raw, "taking every link off leaves the note as it was")
        #expect(JotNote.withFields("Just text", ["entities": ["domain/career"], "tags": []]) == "---\nentities: [domain/career]\ntags: []\n---\n\nJust text")
        let older = "---\ntags: []\nlinks: [person/ken-lee]\n---\n\nx"
        #expect(JotNote.withFields(older, ["entities": ["person/ken-lee"], "tags": []]) == "---\ntags: []\nentities: [person/ken-lee]\n---\n\nx", "an older links: line becomes entities:")
        let url = FileManager.default.temporaryDirectory.appending(path: "jot-note-\(UUID().uuidString).md")
        try? filed.write(to: url, atomically: true, encoding: .utf8)
        let note = JotNote.read(url)
        #expect(note?.links == ["person/ken-lee", "org/acme"] && note?.tags == ["pricing"] && note?.text == "Call Ken about Acme.")
    }

    @Test func entityPagesAreTheCRMsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jot-crm-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(EntityPage.create(.place, "River Walk", in: root, now: now) == "place/river-walk")
        #expect(EntityPage.create(.place, "River Walk", in: root, now: now) == "place/river-walk-2", "a taken slug gets -2")
        #expect(EntityPage.create(.project, "Launch", in: root) == nil, "projects are Studio's")
        let page = try String(contentsOf: root.appending(path: "data/entities/places/river-walk/entity.md"), encoding: .utf8)
        #expect(page == "---\nname: River Walk\nkind: place\naliases: []\nsaved: true\ncreated: 2026-10-26T07:33:20Z\nupdated: 2026-10-26T07:33:20Z\nmention_count: 0\nid: place/river-walk\n---\n\n## Your notes\n\n\n## Conversations\n\n_No conversations yet._\n")
        #expect(EntityPage.yamlStr("Acme: West") == "\"Acme: West\"")
        #expect(StudioDirectory(root: root).object("place/river-walk-2")?.name == "River Walk")
    }

    @Test func jotToADomain() {
        let d = ["career", "health", "real-estate", "real"]
        #expect(VaultDomains.split("Health: slept badly, knee sore", among: d) == ("health", "Slept badly, knee sore"))
        #expect(VaultDomains.split("For career, ask about the promotion", among: d) == ("career", "Ask about the promotion"))
        #expect(VaultDomains.split("real estate: call the agent", among: d) == ("real-estate", "Call the agent"), "the longer name wins")
        #expect(VaultDomains.split("Healthy lunch today", among: d) == (nil, "Healthy lunch today"), "a word that only starts like one")
        #expect(VaultDomains.split("Gardening: plant tomatoes", among: d).0 == nil, "only domains that exist")
        let raw = "---\ndate: 2026-10-25T12:08:24\ntags: []\nkind: voice\n---\n\nx"
        let filed = JotNote.withFields(raw, [:], domain: .some("health"))
        #expect(filed == "---\ndate: 2026-10-25T12:08:24\ntags: []\ndomain: health\nkind: voice\n---\n\nx")
        #expect(JotNote.withFields(filed, [:], domain: .some(nil)) == raw)
        #expect(JotNote.withFields(filed, ["tags": ["a"]]).contains("domain: health"), "other edits keep the domain")
    }

    @Test func markdownExport() {
        var meta = Conversation(id: "Work/2026-10-20-sync", title: "Sync", created: "2026-10-20T15:00:00Z")
        meta.durationSec = 1_500
        meta.links = ["person/ken-lee"]
        meta.tags = ["pricing"]
        let notes = Notes(summary: "We held the price.", decisions: ["Hold it"], actions: [ActionItem(text: "Send the form", owner: "Ken Lee", due: "2026-10-24")])
        let md = Markdown.export(meta, notes: notes, transcript: Transcript(), studio: studio)
        #expect(md.hasPrefix("# Sync\n\n"))
        #expect(md.contains("Filed under Ken Lee\n#pricing\n"))
        #expect(md.contains("## Decisions\n\n- Hold it\n"))
        #expect(md.contains("- [ ] Send the form (Ken Lee, due 2026-10-24)\n"))
        #expect(!md.contains("\u{2014}"))
    }

    /// A summarized recording still carries its words. The export used to add the transcript only
    /// when there was no summary and no action items, so the moment a recording had been
    /// summarized the transcript vanished from "Copy as Markdown": a 33 minute conversation copied
    /// as a few lines of summary (Fru, 2026-11-03). The test above passes an empty `Transcript()`,
    /// which is why it never caught this.
    @Test func exportKeepsTheTranscriptAlongsideTheSummary() {
        var meta = Conversation(id: "Work/2026-10-20-sync", title: "Sync", created: "2026-10-20T15:00:00Z")
        meta.durationSec = 1_980
        var t = Transcript()
        // `nameSpeaker` stores the display name and links the person separately by id
        // (`save(p.name, p)`), so this is what is really on disk after naming a voice. My first
        // version of this fixture put a vault id here and the test failed on its own mistake.
        t.speakers = ["S1": "Ken Lee"]
        t.segments = [
            .init(start: 0, end: 4, speaker: "S1", text: "Did he ask you to walk through it?"),
            .init(start: 19, end: 21, speaker: "S2", text: "Oh yes, yes."),
            .init(start: 1_975, end: 1_979, speaker: "S1", text: "That is the last thing said."),
        ]
        let notes = Notes(summary: "We held the price.", decisions: [], actions: [ActionItem(text: "Send the form")])
        let md = Markdown.export(meta, notes: notes, transcript: t, studio: studio)

        #expect(md.contains("## Summary\n\nWe held the price.\n"), "the summary is still there")
        #expect(md.contains("## Transcript\n\n"), "and so is the transcript, which used to be dropped")
        #expect(md.contains("[00:00]"), "from the first segment")
        #expect(md.contains("That is the last thing said."), "to the last one, 33 minutes in")
        #expect(md.contains("[32:55]"), "with its timestamp")
        #expect(md.contains("Ken Lee:"), "and the speaker named where the voice is known")

        // Every segment, not a sample of them.
        for seg in t.segments { #expect(md.contains(seg.text), "segment at \(seg.start) is in the copy") }

        // The transcript on its own is what `copyTranscript` puts on the pasteboard.
        #expect(t.plainText.contains("[00:00] Ken Lee: Did he ask you to walk through it?\n"))
        #expect(t.plainText.split(separator: "\n").count == 3, "one line per segment, all of them")
    }

    @Test func durations() {
        #expect(Format.duration(48) == "48 s")
        #expect(Format.duration(25 * 60) == "25 min")
        #expect(Format.duration(65 * 60) == "1 h 5 min")
        #expect(Format.clock(187) == "3:07")
        #expect(Format.clock(3727) == "1:02:07")
    }
}

/// What was written while the notes folder was away has to come back, and come back whole.
struct FoldBackTests {
    private func temp() -> URL {
        let dir = URL.temporaryDirectory.appending(path: "foldback-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let name = "2026-10.a-mac-local.jsonl"
    private let away = #"{"at":"2026-10-25T20:49:02Z","text":"away"}"#
    private let home = #"{"at":"2026-10-31T09:00:00Z","text":"home"}"#

    /// Every line in the file is still a line, and every line is still JSON.
    private func lines(_ file: URL) throws -> [String] {
        let got = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        for line in got { #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil, "not JSON: \(line)") }
        return got
    }

    @Test func strandedDictationLinesAreAppendedWholeAndTheOldFileGoes() throws {
        let old = temp(), new = temp()
        // The stranded file ends without a newline: its line must not run into the one before it.
        try away.write(to: old.appending(path: name), atomically: true, encoding: .utf8)
        try (home + "\n").write(to: new.appending(path: name), atomically: true, encoding: .utf8)
        FoldBack.lines(from: old, to: new)
        #expect(try lines(new.appending(path: name)) == [home, away])
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: name).path))
    }

    /// A write cut short leaves the log without its last newline. Folding in must not fuse onto it:
    /// that would lose the line folded in and the line already there.
    @Test func aLogLeftWithoutItsLastNewlineIsNotFusedOnto() throws {
        let old = temp(), new = temp()
        try away.write(to: old.appending(path: name), atomically: true, encoding: .utf8)
        try home.write(to: new.appending(path: name), atomically: true, encoding: .utf8) // no newline
        FoldBack.lines(from: old, to: new)
        #expect(try lines(new.appending(path: name)) == [home, away])
    }

    /// Run again and nothing is written twice, so an old file that would not go is not a doubling.
    @Test func foldingTheSameLinesAgainAddsNothing() throws {
        let old = temp(), new = temp()
        try (away + "\n" + home + "\n").write(to: old.appending(path: name), atomically: true, encoding: .utf8)
        try (home + "\n").write(to: new.appending(path: name), atomically: true, encoding: .utf8)
        FoldBack.lines(from: old, to: new)
        #expect(try lines(new.appending(path: name)) == [home, away])
        try (away + "\n" + home + "\n").write(to: old.appending(path: name), atomically: true, encoding: .utf8)
        FoldBack.lines(from: old, to: new) // the same file, folded a second time
        #expect(try lines(new.appending(path: name)) == [home, away])
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: name).path))
    }

    @Test func strandedThoughtsMoveAndANameAlreadyTakenIsLeftAlone() throws {
        let old = temp(), new = temp()
        try "away\n".write(to: old.appending(path: "2026-10-25 20-49-02.md"), atomically: true, encoding: .utf8)
        try "away too\n".write(to: old.appending(path: "2026-10-25 21-00-00.md"), atomically: true, encoding: .utf8)
        try "the one already here\n".write(to: new.appending(path: "2026-10-25 21-00-00.md"), atomically: true, encoding: .utf8)
        FoldBack.notes(from: old, to: new)
        #expect(try String(contentsOf: new.appending(path: "2026-10-25 20-49-02.md"), encoding: .utf8) == "away\n")
        #expect(try String(contentsOf: new.appending(path: "2026-10-25 21-00-00.md"), encoding: .utf8) == "the one already here\n")
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "2026-10-25 21-00-00.md").path)) // kept, not written over
    }

    /// The Dictionary is a whole file. It comes across when there is nothing to lose, and his
    /// words are never written over when there is.
    @Test func theDictionaryComesAcrossOnlyWhenThereIsNoneToLose() throws {
        let old = temp(), new = temp()
        let words = #"{"dictionary":[{"heard":"jad","write":"Jot"}],"snippets":[]}"#
        try words.write(to: old.appending(path: "words.json"), atomically: true, encoding: .utf8)
        FoldBack.whole(old.appending(path: "words.json"), to: new.appending(path: "words.json"))
        #expect(try String(contentsOf: new.appending(path: "words.json"), encoding: .utf8) == words)
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: "words.json").path))

        // A Dictionary already in the new folder is his too: it is not written over.
        let other = temp()
        try words.write(to: old.appending(path: "words.json"), atomically: true, encoding: .utf8)
        try #"{"dictionary":[],"snippets":[]}"#.write(to: other.appending(path: "words.json"), atomically: true, encoding: .utf8)
        FoldBack.whole(old.appending(path: "words.json"), to: other.appending(path: "words.json"))
        #expect(try String(contentsOf: other.appending(path: "words.json"), encoding: .utf8) == #"{"dictionary":[],"snippets":[]}"#)
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "words.json").path)) // kept, not dropped
    }

    /// A shape nobody wrote the fold-back for still comes across, at whatever depth, and never
    /// over the top of something already there.
    @Test func whateverElseIsInTheFolderIsCarriedWholeAndNeverOverAnything() throws {
        let old = temp(), new = temp()
        let fm = FileManager.default
        try fm.createDirectory(at: old.appending(path: "something/new"), withIntermediateDirectories: true)
        try "a shape nobody has written yet\n".write(to: old.appending(path: "something/new/file.txt"), atomically: true, encoding: .utf8)
        try "his\n".write(to: old.appending(path: "words.json"), atomically: true, encoding: .utf8)
        try "this Mac's own\n".write(to: old.appending(path: "link-review.json"), atomically: true, encoding: .utf8)

        FoldBack.carry(old, to: new, except: ["link-review.json"])

        #expect(try String(contentsOf: new.appending(path: "something/new/file.txt"), encoding: .utf8) == "a shape nobody has written yet\n")
        #expect(try String(contentsOf: new.appending(path: "words.json"), encoding: .utf8) == "his\n")
        #expect(fm.fileExists(atPath: old.appending(path: "link-review.json").path)) // left out, left alone
        #expect(!fm.fileExists(atPath: new.appending(path: "link-review.json").path))

        // Run it against a folder that already holds that name and his newer copy stays.
        let other = temp()
        try "his\n".write(to: old.appending(path: "words.json"), atomically: true, encoding: .utf8)
        try "the one already here\n".write(to: other.appending(path: "words.json"), atomically: true, encoding: .utf8)
        FoldBack.carry(old, to: other)
        #expect(try String(contentsOf: other.appending(path: "words.json"), encoding: .utf8) == "the one already here\n")
        #expect(fm.fileExists(atPath: old.appending(path: "words.json").path)) // kept, not dropped
    }

    /// A name that is a folder on one side and a file on the other is a taken name like any
    /// other: both are left alone, and the fold carries on past it. The last check is the one
    /// that matters, because a clash that stops the fold strands everything behind it.
    @Test func aNameThatIsAFolderOnOneSideAndAFileOnTheOtherDoesNotStopTheFold() throws {
        let old = temp(), new = temp(), fm = FileManager.default
        try fm.createDirectory(at: old.appending(path: "clash.json"), withIntermediateDirectories: true)
        try "inside\n".write(to: old.appending(path: "clash.json/inside.txt"), atomically: true, encoding: .utf8)
        try "a file, not a folder\n".write(to: new.appending(path: "clash.json"), atomically: true, encoding: .utf8)
        // Sorts after the clash, so it is only reached if the clash did not stop the walk.
        try "behind it\n".write(to: old.appending(path: "zzz.json"), atomically: true, encoding: .utf8)

        FoldBack.carry(old, to: new)

        #expect(try String(contentsOf: new.appending(path: "clash.json"), encoding: .utf8) == "a file, not a folder\n")
        #expect(fm.fileExists(atPath: old.appending(path: "clash.json/inside.txt").path)) // still waiting
        #expect(try String(contentsOf: new.appending(path: "zzz.json"), encoding: .utf8) == "behind it\n")
    }

    @Test func thereIsNothingToDoWhenTheFolderIsTheOneInUse() throws {
        let one = temp()
        try "x\n".write(to: one.appending(path: "2026-10-25 20-49-02.md"), atomically: true, encoding: .utf8)
        FoldBack.notes(from: one, to: one)
        FoldBack.lines(from: one, to: one)
        #expect(FileManager.default.fileExists(atPath: one.appending(path: "2026-10-25 20-49-02.md").path))
    }
}

/// Fru's canonical tag set and the one-time fold of his old names into it.
struct CanonicalTagsTests {
    private static let oldToNew = [
        ("Knowledge", "Learning"), ("Books", "Learning"), ("Whisper", "Content"),
        ("Word", "Vocabulary"), ("Renewal", "Business"), ("Meetings", "Career"),
        ("Jot", "Systems"), ("Names", "Names"), ("Daily", "Daily"),
    ]

    @Test func foldsEveryOldName() {
        for (old, new) in Self.oldToNew {
            #expect(CanonicalTags.fold(old) == new, "\(old) should fold to \(new)")
        }
    }

    @Test func leavesATagFruMadeAlone() {
        #expect(CanonicalTags.fold("Borumi") == "Borumi")
        #expect(CanonicalTags.fold(["Knowledge", "Borumi"]) == ["Learning", "Borumi"])
        // The Mac spells them as slugs; same tag, same fold.
        #expect(CanonicalTags.fold("real-estate") == "Real Estate")
    }

    @Test func mergesTwinsAndKeepsOrder() {
        #expect(CanonicalTags.fold(["Books", "Daily", "Knowledge"]) == ["Learning", "Daily"])
    }

    @Test func foldingTwiceChangesNothing() {
        let before = Self.oldToNew.map(\.0) + ["Borumi"]
        let once = CanonicalTags.fold(before)
        #expect(once == ["Learning", "Content", "Vocabulary", "Business", "Career", "Systems", "Names", "Daily", "Borumi"])
        #expect(CanonicalTags.fold(once) == once)
    }

    @Test func everyCanonicalTagHasACoversLine() {
        #expect(CanonicalTags.all.count == 23)
        for tag in CanonicalTags.all {
            #expect(!tag.covers.isEmpty)
            #expect(CanonicalTags.covers(tag.name) == tag.covers)
            #expect(CanonicalTags.covers(tag.slug) == tag.covers)
        }
        #expect(CanonicalTags.covers("Borumi") == nil)
    }

    @Test func everyCanonicalTagKeepsItsOwnColour() {
        // One fixed hue each, by name or by slug, and no two of the 23 collide.
        #expect(CanonicalTags.hex("Daily") == "#3ac8b4")
        #expect(CanonicalTags.hex("Real Estate") == "#983ac8")
        #expect(CanonicalTags.hex("real-estate") == "#983ac8")
        #expect(CanonicalTags.hex("Systems") == "#98c83a")
        #expect(Set(CanonicalTags.all.map(\.hex)).count == CanonicalTags.all.count)
        for tag in CanonicalTags.all { #expect(CanonicalTags.color(tag.slug) != nil) }
        #expect(CanonicalTags.color("Daily") == Color(red: 0x3a / 255, green: 0xc8 / 255, blue: 0xb4 / 255))

        // A tag Fru made himself has no colour of its own, and its hashed one is stable.
        #expect(CanonicalTags.hex("Borumi") == nil)
        #expect(CanonicalTags.color("Borumi") == nil)
        let index = CanonicalTags.fallbackIndex("Borumi", of: 10)
        #expect(index == CanonicalTags.fallbackIndex("borumi", of: 10))
        #expect((0..<10).contains(index))
    }
}
