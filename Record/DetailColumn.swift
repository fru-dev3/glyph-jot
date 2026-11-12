import GlyphCore
import SwiftUI

/// The open conversation, or a quiet welcome when none is.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let meta = model.selected {
            ConversationDetail(meta: meta)
                .id(meta.id)
        } else {
            let first = model.library.conversations.isEmpty
            EmptyState(symbol: "waveform", title: first ? "Record your first conversation" : "Pick a conversation") {
                if first {
                    VStack(spacing: 18) {
                        Button { model.toggleRecording() } label: {
                            Label("Record", systemImage: "record.circle").padding(.horizontal, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                        KeyHint(keys: "\u{21E7}\u{2318}I", label: "Import audio, or drop a file here")
                    }
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    KeyHint(keys: "\u{2318}R", label: "Record")
                    KeyHint(keys: "\u{2318}K", label: "Quick open")
                    KeyHint(keys: "\u{21E7}\u{2318}I", label: "Import audio, or drop a file here")
                }
                }
            }
        }
    }
}

struct ConversationDetail: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var notes = Notes()
    @State private var transcript = Transcript()
    @State private var player = AudioPlayer()
    @State private var peaks: [Float] = []
    @FocusState private var titleFocused: Bool

    private var audioURL: URL { model.vault.url(meta.id).appending(path: meta.audio) }
    private var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }

    /// Recording now: the words are arriving and the second pass has not happened yet.
    private var isLive: Bool { model.recordingID == meta.id }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                let rail = showRail(geo.size.width)
                words(rail: rail)
                if rail {
                    Divider()
                    SecondPassRail(meta: meta, transcript: transcript)
                        .frame(width: 292)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.glyph(reduceMotion), value: model.tab)
        .task(id: "\(meta.id)|\(model.library.generation)") { load() }
        .onAppear {
            title = meta.title
            if hasAudio { player.load(audioURL) }
        }
        .onDisappear { player.stop() }
        .task(id: meta.id) {
            guard hasAudio else { return }
            let url = audioURL
            peaks = (try? await Task.detached(priority: .utility) { try Waveform.peaks(of: url, count: 480) }.value) ?? []
        }
        .onChange(of: meta.title) { if !titleFocused { title = meta.title } }
        .onChange(of: model.renameRequest) { titleFocused = true }
        .onChange(of: titleFocused) { if !titleFocused { model.rename(meta.id, to: title) } }
    }

    private func load() {
        let vault = model.vault
        notes = vault.notes(meta.id)
        transcript = vault.transcript(meta.id)
    }

    /// The Mac has room for the second pass to sit beside the words instead of above them, but
    /// only once there is a second pass (never while recording) and only while the column left
    /// over still holds a readable measure.
    private func showRail(_ width: CGFloat) -> Bool { !isLive && width >= 820 }

    @ViewBuilder private func words(rail: Bool) -> some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(rail: rail)
                    .padding(.bottom, 22)
                ForEach(model.banners.filter { $0.conversation == meta.id }) { b in
                    BannerView(banner: b).padding(.bottom, 16)
                }
                TabBar(selection: $model.tab)
                    .padding(.bottom, 20)
                Group {
                    switch model.tab {
                    case .summary: SummaryTab(meta: meta, notes: notes, hasTranscript: !transcript.segments.isEmpty)
                    case .transcript: TranscriptTab(meta: meta, transcript: transcript, player: player, hasAudio: hasAudio)
                    case .speakers: WhoSpokeTab(meta: meta, transcript: transcript)
                    }
                }
                .transition(.opacity)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // While the words arrive the newest line is the one worth seeing, so the view holds the foot.
        .defaultScrollAnchor(isLive && model.tab == .transcript ? .bottom : .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { foot(rail: rail) }
    }

    /// While it records, the level and the tag: the tag sits by the waveform, where it is true
    /// and changeable. Afterwards, the player.
    @ViewBuilder private func foot(rail: Bool) -> some View {
        if isLive {
            LiveFoot(meta: meta)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.tab == .transcript, hasAudio {
            PlayerBar(player: player, peaks: peaks, segments: transcript.segments)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: header

    private func header(rail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .onExitCommand { title = meta.title; titleFocused = false }
                    .accessibilityLabel("Title")
                Spacer(minLength: 8)
                if isLive {
                    LiveChip(live: model.live)
                } else {
                    VaultTicks(kept: !transcript.segments.isEmpty)
                }
                MoreMenu(id: meta.id)
            }

            // Plain words, no icons: a calendar glyph beside a date says nothing the date does not.
            FlowLayout(spacing: 16, lineSpacing: 6) {
                Text(Format.shortDate(meta.created))
                if isLive {
                    Text(Format.clock(model.recorder.elapsed)).monospacedDigit()
                } else if meta.durationSec > 0 {
                    Text(Format.duration(meta.durationSec))
                }
                if spokenWords > 0 { Text("\(spokenWords.formatted()) words").monospacedDigit() }
                if let device = meta.device { Text(device) }
                // The rail says what the second pass is doing; saying it twice is saying it worse.
                if !rail, let stage = model.stage(meta.id) { Text(stage.help) }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)

            // The tag sits at the waveform while it records and in the rail when there is one;
            // with neither, it belongs here.
            if !isLive, !rail { LinkRow(meta: meta) }
        }
    }

    private var spokenWords: Int {
        transcript.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

/// While it records: that the words are arriving, which is the one thing the words themselves
/// cannot say. Green, never red: red is the running recording, and the sidebar's Stop card is it.
struct LiveChip: View {
    let live: LiveTranscript

    private var label: String {
        if live.on { return "Transcribing as you speak" }
        if live.problem != nil { return "Written when you stop" }
        return "Reaching the speech model"
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(live.on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(live.on ? Color.glyphGreenText : Color.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.accentColor.opacity(live.on ? 0.14 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(live.on ? 0.35 : 0.15)))
        .help(live.problem ?? "The words are written on this Mac as you speak; the voices are told apart when you stop")
    }
}

/// The foot of a running recording: how loud it is, and what it is being filed as.
struct LiveFoot: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model
    @State private var history: [Float] = Array(repeating: 0, count: 48)

    var body: some View {
        HStack(spacing: 13) {
            LevelMeter(history: history, paused: model.recorder.state == .paused)
                .frame(height: 30)
            LinkRow(meta: meta).fixedSize()
        }
        .padding(.horizontal, 30)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: model.recorder.levels) {
            history.removeFirst()
            history.append(model.recorder.levels.values.max() ?? 0)
        }
    }
}

/// What a recording is filed under (Studio objects and #tags), the add field, then the AI's guesses.
struct LinkRow: View {
    let meta: Conversation
    @Environment(AppModel.self) private var model

    var body: some View {
        LinkEditor(target: .recording(meta.id),
                   links: meta.links.map { .object($0) } + meta.tags.map { .tag($0) },
                   suggestions: meta.suggested.links.map { .object($0) } + meta.suggested.people.map { .person($0) } + meta.suggested.tags.map { .tag($0) },
                   onAnswer: { link, yes in model.answer(link, for: meta.id, accept: yes) })
    }
}

/// Links on a recording or a note: chips that open their page, the + field, and guesses.
struct LinkEditor: View {
    let target: LinkTarget
    let links: [Link]
    var suggestions: [Link] = []
    var onAnswer: ((Link, Bool) -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 8) {
            ForEach(links, id: \.self) { link in
                LinkChip(link: link, onOpen: { if let item = link.sidebarItem { model.sidebar = item } }, onRemove: {
                    animate { model.removeLink(link, from: target) }
                })
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            LinkAddField(excluding: Set(links), request: model.addLinkRequest) { link in
                model.addLink(link, to: target)
            }
            ForEach(suggestions, id: \.self) { link in
                SuggestionChip(link: link,
                               onAccept: { animate { onAnswer?(link, true) } },
                               onDismiss: { animate { onAnswer?(link, false) } })
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.glyph(false), value: links)
        .animation(.glyph(false), value: suggestions)
        .zIndex(5)
    }
}

/// Every other action, behind one button.
struct MoreMenu: View {
    let id: String

    var body: some View {
        Menu {
            ConversationMenu(id: id)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("More")
    }
}

/// Transcript, Summary, Who spoke: the words first, because they are what a recording is for.
/// Underlined rather than a pill, so three of them read as one row instead of a crowded switch,
/// and the chosen one is marked in the accent.
struct TabBar: View {
    @Binding var selection: DetailTab
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 26) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    withAnimation(.glyph(reduceMotion)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: selection == tab ? .semibold : .regular))
                        .fixedSize()
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            if selection == tab {
                                Rectangle()
                                    .fill(.tint)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "indicator", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: tabs

struct SummaryTab: View {
    let meta: Conversation
    let notes: Notes
    let hasTranscript: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if !notes.summary.isEmpty || !notes.decisions.isEmpty || !notes.actions.isEmpty {
            VStack(alignment: .leading, spacing: 26) {
                if !notes.summary.isEmpty {
                    Text(notes.summary)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !notes.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Decisions", systemImage: "signpost.right.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .labelStyle(TintedIconLabel())
                        ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                Text(d).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                            }
                        }
                    }
                }
                // Read here only: tasks live in Glyph Bot, not in Glyph Jot.
                if !notes.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Action items", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .labelStyle(TintedIconLabel())
                        ForEach(Array(notes.actions.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.text).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                                    if item.owner != nil || item.due != nil {
                                        HStack(spacing: 14) {
                                            if let o = item.owner { MetaChip(symbol: "person", text: o) }
                                            if let d = item.due { MetaChip(symbol: "calendar", text: Format.due(d)) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if let stage = model.stage(meta.id) {
            Working(stage: stage)
        } else if hasTranscript {
            EmptyState(symbol: "sparkles", title: "No summary yet") {
                Button("Summarize") { Task { await model.summarizeAndLink(meta.id) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 260)
        } else if model.recordingID == meta.id {
            EmptyState(symbol: "record.circle", title: "Recording", message: "The summary is written when you stop.")
                .frame(minHeight: 260)
        } else {
            EmptyState(symbol: "waveform", title: "Not transcribed yet") {
                Button("Transcribe and Summarize") { Task { await model.process(meta.id) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 260)
        }
    }
}

struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(.tint).font(.system(size: 14))
            configuration.title
        }
    }
}

/// Background work in progress, in place of a tab's content.
struct Working: View {
    let stage: Stage

    var body: some View {
        VStack(spacing: 14) {
            if case .transcribing(let p) = stage {
                ProgressView(value: p).frame(width: 180)
            } else if case .downloadingModel(let p) = stage {
                ProgressView(value: p).frame(width: 180)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(stage.help).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct TranscriptTab: View {
    let meta: Conversation
    let transcript: Transcript
    let player: AudioPlayer
    let hasAudio: Bool
    @Environment(AppModel.self) private var model

    /// The words heard live belong to this recording and the kept transcript has not replaced
    /// them yet: either it is still recording, or the second pass is running.
    private var live: LiveTranscript? {
        guard transcript.segments.isEmpty, model.live.conversation == meta.id else { return nil }
        return model.recordingID == meta.id || model.live.hasWords ? model.live : nil
    }

    var body: some View {
        if let live {
            LiveWords(live: live, finished: model.recordingID != meta.id)
        } else if transcript.segments.isEmpty {
            if let stage = model.stage(meta.id) {
                Working(stage: stage)
            } else {
                EmptyState(symbol: "text.quote", title: "No transcript yet") {
                    if hasAudio, model.recordingID != meta.id {
                        Button("Transcribe") { Task { await model.process(meta.id) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(minHeight: 260)
            }
        } else {
            let current = transcript.segments.lastIndex { $0.start <= player.time + 0.05 }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { i, s in
                    // Jots that began before this segment (and after the one before) show above it.
                    ForEach(meta.jots.filter { j in j.start < s.start && (i == 0 || j.start >= transcript.segments[i - 1].start) }, id: \.start) { JotMarker(jot: $0) }
                    SegmentRow(conversation: meta.id,
                               segment: s,
                               speaker: s.speaker.isEmpty ? "" : transcript.name(of: s.speaker),
                               showSpeaker: i == 0 || transcript.segments[i - 1].speaker != s.speaker,
                               isCurrent: hasAudio && player.started && current == i) {
                        guard hasAudio else { return }
                        player.seek(s.start, play: true)
                    }
                }
                ForEach(meta.jots.filter { $0.start >= (transcript.segments.last?.start ?? 0) }, id: \.start) { JotMarker(jot: $0) }
            }
        }
    }
}

/// Where you jotted during the recording: kept out of the transcript, or a note linked here.
struct JotMarker: View {
    let jot: Jot
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: jot.note != nil ? "note.text" : "lock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            if let note = jot.note {
                Button {
                    model.sidebar = .notes
                    model.openNote = note
                } label: {
                    let title = NoteStore.shared.notes.first { $0.file == note }?.title
                    Text("\(Text("Note at \(Format.clock(jot.start))").underline())\(title.map { ": \($0)" } ?? "")")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open the note you said here")
            } else {
                Text("You jotted from \(Format.clock(jot.start)) to \(Format.clock(jot.end)), kept out of the transcript")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .padding(.vertical, 6)
        .padding(.leading, 40) // under the timestamps' column
    }
}

struct SegmentRow: View {
    let conversation: String
    let segment: Transcript.Segment
    let speaker: String
    let showSpeaker: Bool
    let isCurrent: Bool
    var onTap: () -> Void
    @State private var hover = false
    @State private var naming = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Format.clock(segment.start))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                if showSpeaker, !speaker.isEmpty {
                    Button { naming = true } label: {
                        HStack(spacing: 7) {
                            Circle().fill(SpeakerColor.of(segment.speaker)).frame(width: 7, height: 7)
                            Text(speaker)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Say who \(speaker) is")
                    .popover(isPresented: $naming, arrowEdge: .bottom) {
                        SpeakerNamer(id: conversation, speaker: segment.speaker, current: speaker)
                    }
                }
                Text(segment.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : hover ? Color.secondary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, showSpeaker ? 8 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .help("Play from \(Format.clock(segment.start))")
    }
}


/// The words as they arrive: the timestamp they were said at, then the line. The guess at what is
/// being said now sits quiet under the last finished line, with a caret where it is still writing.
///
/// These are not the kept transcript. They say nothing about who spoke, because one running line
/// cannot know; once the second pass has split the audio by voice this view is replaced by it.
struct LiveWords: View {
    let live: LiveTranscript
    /// Stopped: the second pass is running and these words are waiting to be replaced.
    let finished: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            if live.lines.isEmpty, live.partial.isEmpty {
                Text(live.problem ?? (live.on ? "Listening." : "Reaching the speech model."))
                    .font(.system(size: 15.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(live.lines) { line in
                row(at: line.at, text: line.text, said: true)
            }
            if !live.partial.isEmpty {
                row(at: nil, text: live.partial, said: false)
            }
            if let problem = live.problem, !live.lines.isEmpty {
                Text(problem).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if finished, !live.lines.isEmpty {
                Text("Who spoke is being worked out; these words are replaced by the kept transcript.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript, arriving as you speak")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func row(at: Double?, text: String, said: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(at.map(Format.clock) ?? "")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Group {
                if said {
                    Text(text)
                } else {
                    // The caret says the sentence is not finished, which is why it is still grey.
                    Text("\(text)\(Text(" \u{258C}").foregroundColor(.accentColor))")
                }
            }
            .font(.system(size: 15.5))
            .lineSpacing(5)
            .foregroundStyle(said ? AnyShapeStyle(.primary.opacity(0.92)) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Who spoke, in full: every voice with its share of the talking, and the ones still unnamed
/// said so plainly. The rail beside the words carries the one action; this is the whole list.
struct WhoSpokeTab: View {
    let meta: Conversation
    let transcript: Transcript
    @Environment(AppModel.self) private var model

    var body: some View {
        let talk = transcript.talkTime
        if talk.isEmpty {
            if let stage = model.stage(meta.id) {
                Working(stage: stage)
            } else {
                EmptyState(symbol: "person.2.wave.2", title: "No voices yet",
                           message: transcript.segments.isEmpty
                               ? "The voices are told apart when the recording is transcribed."
                               : "This recording came through as one voice.")
                    .frame(minHeight: 260)
            }
        } else {
            let total = max(talk.reduce(0) { $0 + $1.seconds }, 0.01)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: talk.count == 1 ? "1 voice" : "\(talk.count) voices")
                ForEach(talk, id: \.speaker) { t in
                    VoiceRow(id: meta.id, speaker: t.speaker, name: transcript.name(of: t.speaker),
                             seconds: t.seconds, turns: transcript.turns(of: t.speaker), share: t.seconds / total)
                }
            }
        }
    }
}

extension Transcript {
    /// How many times a voice took over. Counted in one place, so the rail beside the words and
    /// the tab cannot say two different numbers about the same recording.
    func turns(of speaker: String) -> Int {
        var n = 0
        var last = ""
        for s in segments {
            if s.speaker == speaker, last != speaker { n += 1 }
            last = s.speaker
        }
        return n
    }
}

/// One voice: its colour, its name (or that it has none yet), how much it said, and Name.
struct VoiceRow: View {
    let id: String
    let speaker: String
    let name: String
    let seconds: Double
    let turns: Int
    let share: Double
    @State private var naming = false

    private var unnamed: Bool { name.hasPrefix("Speaker ") }

    var body: some View {
        Button { naming = true } label: {
            HStack(spacing: 11) {
                Circle().fill(SpeakerColor.of(speaker)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13.5, weight: .semibold))
                    Text("\(turns) turn\(turns == 1 ? "" : "s") \u{00B7} \(Format.clock(seconds))")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if unnamed {
                    Text("Name")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.glyphGreenText)
                } else {
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(unnamed ? "Say who this voice is" : "\(name) talked \(Int((share * 100).rounded()))% of the time. Click to rename")
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            SpeakerNamer(id: id, speaker: speaker, current: name)
        }
    }
}

/// The second pass, beside the words rather than above them: how far it has got, the voices it
/// found with a Name for the one it cannot place, and what the recording is filed as.
struct SecondPassRail: View {
    let meta: Conversation
    let transcript: Transcript
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let stage = model.stage(meta.id) { PassCard(stage: stage, duration: meta.durationSec) }
                voices
                tagged
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 26)
        }
        .background(.quaternary.opacity(0.22))
    }

    @ViewBuilder private var voices: some View {
        let talk = transcript.talkTime
        if !talk.isEmpty {
            let total = max(talk.reduce(0) { $0 + $1.seconds }, 0.01)
            VStack(alignment: .leading, spacing: 11) {
                SectionHeading(title: "Voices")
                ForEach(talk, id: \.speaker) { t in
                    VoiceRow(id: meta.id, speaker: t.speaker, name: transcript.name(of: t.speaker),
                             seconds: t.seconds, turns: transcript.turns(of: t.speaker), share: t.seconds / total)
                }
            }
        }
    }

    private var tagged: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeading(title: "Tagged")
            LinkRow(meta: meta)
        }
    }
}

/// What the second pass is doing, and how far through: green, because it is working, not failing.
struct PassCard: View {
    let stage: Stage
    let duration: Int

    /// "4 of 12 min" while there is a fraction to say it with; nothing invented when there is not.
    private var through: String? {
        guard duration > 0 else { return nil }
        let minutes = Double(duration) / 60
        switch stage {
        case .transcribing(let p), .downloadingModel(let p):
            return "\(Int((p * minutes).rounded())) of \(Int(minutes.rounded())) min"
        default: return nil
        }
    }

    private var fraction: Double? {
        switch stage {
        case .transcribing(let p), .downloadingModel(let p): return p
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Circle().fill(.tint).frame(width: 6, height: 6)
                Text(stage.help)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.glyphGreenText)
                if let through {
                    Spacer(minLength: 6)
                    Text(through)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.glyphGreenText)
                }
            }
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.32)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stage.help + (through.map { ", \($0)" } ?? ""))
    }
}
