import GlyphCore
import ServiceManagement
import SwiftUI

/// Settings (Command-comma, or the gear beside the app's name): the panes go down the window's
/// own rail, in place of the library's rows, and the one chosen fills the content pane. Vault
/// first, because the first question about a thing that keeps what you say is where it keeps it.
/// It is never a page that floats over the app.
struct JotSettings: View {
    enum Pane: String, CaseIterable, Identifiable {
        case vault, recording, dictation, dictionary, snippets, styles, general, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vault: "Vault"
            case .recording: "Recording"
            case .dictation: "Dictation"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .styles: "Styles"
            case .general: "General"
            case .privacy: "Privacy"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .vault: "externaldrive"
            case .recording: "record.circle"
            case .dictation: "mic"
            case .dictionary: "character.book.closed"
            case .snippets: "text.badge.plus"
            case .styles: "textformat"
            case .general: "gearshape"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
        /// The pane's own mark in the rail, so a glance finds the row again.
        var tint: Color {
            switch self {
            case .vault: .accentColor
            case .recording: .blue
            case .dictation: .purple
            case .dictionary, .snippets, .styles: .teal
            case .general: .indigo
            case .privacy: .orange
            case .about: .secondary
            }
        }
    }
    @AppStorage("settingsPane") private var pane: Pane = .vault

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.system(size: 30, weight: .bold))
                Group {
                    switch pane {
                    case .vault: VaultPane()
                    case .recording: RecordingPane()
                    case .dictation: DictationPane()
                    case .dictionary: DictionaryTab()
                    case .snippets: SnippetsTab()
                    case .styles: StylesTab()
                    case .general: GeneralPane()
                    case .privacy: PrivacyPane()
                    case .about: AboutPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // 760: the measure the rest of the app reads at, so a settings line is no wider
            // than a transcript line.
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The rail while Settings is open: the panes, in place of the library's rows.
struct SettingsPanes: View {
    @AppStorage("settingsPane") private var pane: JotSettings.Pane = .vault

    var body: some View {
        List(JotSettings.Pane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { p in
            Label {
                Text(p.title)
            } icon: {
                Image(systemName: p.symbol).foregroundStyle(p.tint)
            }
            .tag(p)
            .accessibilityIdentifier("settings-\(p.rawValue)")
        }
        .listStyle(.sidebar)
    }
}

// MARK: shared rows

/// A folder: its name big, its path under it, Show in Finder, and Change when it can change.
struct FolderRow: View {
    let title: String
    let url: URL
    var detail: String?
    var change: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let change { Button("Change\u{2026}", action: change) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// The vault Jot saves to: the notes folder (a Glyph Bot vault, or any folder).
struct VaultRow: View {
    @State private var refresh = 0

    var body: some View {
        if let root = DictationLog.chosen {
            FolderRow(title: DictationLog.vault == nil ? "Notes folder" : "Vault", url: root,
                      detail: DictationLog.vault == nil ? "Any folder works; a Glyph Bot vault also gets People, Places, Products and Things" : nil) { change() }
                .id(refresh)
        } else {
            LabeledContent("Vault") { Button("Choose\u{2026}") { change() } }
        }
    }

    private func change() {
        if chooseNotesVault() {
            refresh += 1
            NoteStore.shared.reload()
            Task { await AppModel.shared.reloadStudio() }
        }
    }
}

// MARK: panes

struct GeneralPane: View {
    @Bindable private var prefs = Prefs.shared
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                AppIdentity()
            }
            Section("Your vault") {
                VaultRow()
                Text("Notes, dictations and links are saved as plain files in this folder. Back it up and everything is safe.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open at login", isOn: $atLogin)
                    .onChange(of: atLogin) {
                        try? atLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Toggle("Sounds", isOn: $prefs.sounds)
            }
            Section("Shortcuts") {
                ForEach(RecordingPane.shortcuts, id: \.0) { s in
                    LabeledContent(s.1) {
                        Text(s.0)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 7)
                            .frame(minHeight: 22)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The icon, the name and the version with its build.
struct AppIdentity: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Glyph Jot").font(.system(size: 20, weight: .bold))
                Text("Version \(Version.number), build \(Version.build)")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("version")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Is it safe? Reach first, then the folder in full, then where each kind of capture lands, then
/// how tags and links live in the files, then the version at the foot.
///
/// Nothing here says "upload" or "0 waiting". On a Mac there is no queue to say it about: Glyph
/// Jot writes straight into the folder, and the first line says so.
struct VaultPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VaultReach()
            Form {
            Section("Where each thing is saved") {
                VaultRow()
                FolderRow(title: "Notes", url: Thoughts.folder, detail: "One Markdown file per note")
                FolderRow(title: "Dictations", url: DictationLog.folder, detail: "One line per dictation, a file per month and Mac")
                RecordingsFolderRow()
                if let vault = DictationLog.vault {
                    FolderRow(title: "People, places, products and things", url: vault.appending(path: "data/entities"),
                              detail: "Glyph CRM's entity pages, one folder each; Jot links to them and makes new ones here")
                }
            }
            Section("Tags and links") {
                Text("Tags and links are written into the note itself, in the front matter at the top of its file. There is no database: any app that reads the vault, and Glyph CRM, sees the same thing.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("tags: [knowledge, ideas]\nentities: [person/ken-lee, place/riverside-park]")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
                Text("Each entity is the permanent id of its Glyph CRM page, so a person you record with is one record everywhere. Recordings keep the same lines in notes.md.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Link Older Notes to Glyph CRM\u{2026}") { model.reviewingLinks = true; JotWindow.open() }
            }
            }
            .formStyle(.grouped)
            .frame(height: 620)
            VersionFoot()
        }
    }
}

/// The first line of Settings: whether the folder is there, where it is in full, and where the
/// sound goes. The path is not shortened to a tilde and not truncated in the middle: a path you
/// cannot read is a path you cannot check.
struct VaultReach: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let reachable = model.isVaultPresent
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Vault")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: reachable ? "wifi" : "wifi.slash")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(reachable ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reachable ? "Writing straight into the folder" : "The folder is not there")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text(reachable
                             ? "Nothing is uploaded and nothing waits: a jot is a file in the folder the moment you finish it"
                             : "Nothing is lost. Choose the folder again and what is waiting is written into it")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder").font(.system(size: 14.5))
                        Text(DictationLog.chosen?.path(percentEncoded: false) ?? "Not chosen yet")
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("audio \u{00B7} " + model.vault.root.path(percentEncoded: false))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let root = DictationLog.chosen {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("vault-reach")
        }
    }
}

/// The version at the foot, where a version belongs, with About and Privacy beneath it. No tick
/// anywhere near it: a version is a fact about software on this Mac, not about the vault, and a
/// second green tick here would be promising something it cannot.
struct VersionFoot: View {
    @AppStorage("settingsPane") private var pane: JotSettings.Pane = .vault

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glyph Jot").font(.system(size: 14.5, weight: .semibold))
                    Text("Transcription, who spoke and the summaries all run on this Mac")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Version.text)
                    .font(.system(size: 13.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("version")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 10) {
                Button("About") { pane = .about }
                    .buttonStyle(.plain)
                Text("\u{00B7}").accessibilityHidden(true)
                Button("Privacy") { pane = .privacy }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
    }
}

struct PrivacyPane: View {
    @State private var refresh = 0
    @State private var screen = Permissions.screenRecording

    var body: some View {
        Form {
            Section {
                Label("Nothing leaves this Mac. Speech, cleanup and summaries run on-device; every file stays in your folders.", systemImage: "lock.shield")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("What macOS allows") {
                Grant(name: "Input Monitoring", why: "to hear the talk key", ok: JotPermissions.keys, pane: "Privacy_ListenEvent")
                Grant(name: "Accessibility", why: "to paste where you are", ok: JotPermissions.paste, pane: "Privacy_Accessibility")
                Grant(name: "Microphone", why: "to hear you", ok: JotPermissions.mic, pane: "Privacy_Microphone")
                Grant(name: "Screen & System Audio Recording", why: "only to record the Mac's sound in a meeting", ok: screen == .granted, pane: "Privacy_ScreenCapture")
            }
            .id(refresh)
            Section("Kept out") {
                Text("A jot you say during a recording is kept out of its transcript. With \u{201C}Keep the microphone ready\u{201D} on, under a second of sound is held in memory and never saved.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screen = Permissions.screenRecording
            refresh += 1
        }
    }
}

struct AboutPane: View {
    var body: some View {
        Form {
            Section { AppIdentity() }
            Section {
                Text("Hold Fn to jot anywhere; add Shift to save a note. Click Record for a meeting. One library of notes, dictations and recordings, linked to the people, places, products and things in Glyph CRM.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Part of", value: "Glyph, by fru.dev")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "")
                SwiftUI.Link("glyph.fru.dev/jot", destination: URL(string: "https://glyph.fru.dev/jot")!)
            }
            Section {
                Text("\u{00A9} fru.dev").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
