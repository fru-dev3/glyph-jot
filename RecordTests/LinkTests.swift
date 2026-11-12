import Foundation
import GlyphCore
import Testing
@testable import GlyphJot

/// The pipe between Glyph Jot and its dictation engine.
struct LinkTests {
    @Test func messagesSurviveTheLineAndStrayOutputIsIgnored() {
        let m = LinkMessage(.jot, mode: "thought", on: true, at: 1_792_958_000.25)
        var buffer = LineBuffer()
        let half = Data(m.line.utf8)
        // A log line, then the message split across two reads.
        var lines = buffer.feed(Data("speech: ready\n".utf8) + half.prefix(10))
        #expect(lines.compactMap(LinkMessage.parse).isEmpty)
        lines = buffer.feed(half.dropFirst(10))
        #expect(lines.compactMap(LinkMessage.parse) == [m])
        #expect(LinkMessage.parse("{\"kind\":\"quit\"}") == nil) // no marker, not a message
    }

    /// Jot while recording: the jot's stretch and its note land in the conversation, and the
    /// transcript loses what was said in it (must-pass, decision d-mvo8wkr4).
    @MainActor @Test func jotsDuringARecordingAreRecordedAndKeptPrivate() async throws {
        let model = AppModel.shared
        let setting = savedRecordingsPath()
        defer { #expect(savedRecordingsPath() == setting, "a test changed the installed app's recordings folder") }
        let root = FileManager.default.temporaryDirectory.appending(path: "glyph-jot-tests-\(UUID().uuidString)")
        model.switchVault(to: root, remember: false)
        model.debugFeed = nil
        // A recording fed silence through the test path, so no microphone is needed.
        let meta = try model.vault.createConversation(in: "Recordings", title: "Sync")
        try model.testBegin(meta.id)
        model.engineSaid(.init(.jot, mode: "dictate", on: true))
        model.engineSaid(.init(.jot, on: false))
        model.engineSaid(.init(.jot, mode: "thought", on: true))
        model.engineSaid(.init(.thought, text: "2026-10-25 10-00-02.md"))
        model.engineSaid(.init(.jot, on: false))
        #expect(model.jots.count == 2)
        #expect(model.jots[1].note == "2026-10-25 10-00-02.md" && model.jots[1].kind == "thought")
        await model.stopRecording()
        await model.library.settle()
        let saved = try model.vault.conversation(meta.id)
        #expect(saved.jots.count == 2)
        #expect(model.recordingFor(note: "2026-10-25 10-00-02.md")?.0 == meta.id)
        try? FileManager.default.removeItem(at: root)
    }

    /// The test host is Jot.app with the installed app's settings (one bundle id): pointing it
    /// at a test folder must never reach them. Once it did, and real recordings went to /tmp.
    @MainActor @Test func switchingVaultsInATestNeverSavesTheFolder() {
        let saved = savedRecordingsPath()
        let root = FileManager.default.temporaryDirectory.appending(path: "glyph-jot-tests-\(UUID().uuidString)")
        AppModel.shared.switchVault(to: root) // even asked to remember
        #expect(AppModel.testHost)
        #expect(savedRecordingsPath() == saved)
    }

    /// The vault invariant: taking the vault away wipes in-memory conversations,
    /// wipes AppModel.studio, clears selectedID, prevents silent fallback in vaultRoot(),
    /// renders honest NoVault state, and restores cleanly when the vault returns.
    @MainActor @Test func vaultGoneWipesMemoryAndRecovers() async throws {
        let model = AppModel.shared
        let tmp = FileManager.default.temporaryDirectory.appending(path: "jot-test-vault-\(UUID().uuidString)")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date.now)
        let convID = "Recordings/\(today)-test-sync"
        let recordings = tmp.appending(path: convID)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        
        let meta = """
        {"id":"\(convID)","title":"Test Sync","created":"2026-10-31T10:00:00Z","durationSec":60,"audio":"audio.m4a","speakers":[],"tags":[],"links":[],"jots":[],"device":"Mac"}
        """
        try meta.write(to: recordings.appending(path: "meta.json"), atomically: true, encoding: .utf8)

        let domainDir = tmp.appending(path: "data/domains/technology")
        try FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)
        let manifest = """
        {"id":"technology","identity":{"label":"Technology"}}
        """
        try manifest.write(to: domainDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        
        let oldNotesPath = jotDefaults.string(forKey: "vaultPath")
        jotDefaults.set(tmp.path, forKey: "vaultPath")
        defer {
            if let oldNotesPath {
                jotDefaults.set(oldNotesPath, forKey: "vaultPath")
            } else {
                jotDefaults.removeObject(forKey: "vaultPath")
            }
        }

        model.switchVault(to: tmp, remember: false)
        await model.library.settle()
        await model.reloadStudio()

        model.selectedID = convID
        model.sidebar = .all
        
        #expect(!model.library.conversations.isEmpty)
        #expect(model.isVaultPresent)
        #expect(!model.studio.objects(.domain).isEmpty)
        #expect(model.selectedID == convID)

        // 1. Move vault away (simulate unmount / folder moved)
        let moved = tmp.deletingLastPathComponent().appending(path: tmp.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: tmp, to: moved)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        
        // 2. Reload: snapshot wiped and state is honestly absent
        model.reload()
        await model.library.settle()
        
        #expect(!model.isVaultPresent)
        #expect(model.library.conversations.isEmpty)
        #expect(model.studio.objects(.domain).isEmpty)
        #expect(model.selectedID == nil)

        // 3. Assert AppModel.vaultRoot() never silently falls back to another folder
        let oldSetting = UserDefaults.standard.string(forKey: "recordingsPath")
        defer {
            if let oldSetting {
                UserDefaults.standard.set(oldSetting, forKey: "recordingsPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "recordingsPath")
            }
        }
        UserDefaults.standard.set(tmp.path, forKey: "recordingsPath")
        #expect(AppModel.vaultRoot().path == tmp.path, "vaultRoot must not substitute alternative directory when absent")

        // 4. Assert NoVault view interaction
        let noVault = NoVault()
        noVault.openSettings(model)
        #expect(model.sidebar == .settings)
        
        // 5. Restore vault: verify clean recovery
        try FileManager.default.moveItem(at: moved, to: tmp)
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        
        model.reload()
        await model.library.settle()
        await model.reloadStudio()
        
        #expect(model.isVaultPresent)
        #expect(!model.library.conversations.isEmpty)
        #expect(!model.studio.objects(.domain).isEmpty)
        
        try? FileManager.default.removeItem(at: tmp)
    }
}

/// The saved setting itself (not the -recordingsPath argument a test may pass).
func savedRecordingsPath() -> String? {
    UserDefaults.standard.persistentDomain(forName: "dev.fru.jot.mac")?["recordingsPath"] as? String
}
