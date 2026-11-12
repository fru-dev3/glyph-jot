import GlyphCore
import SwiftUI
import UniformTypeIdentifiers

/// Chat: ask across everything you captured, and keep the thread. One question used to live in an
/// ask bar on Home and be replaced by the next one; here the earlier threads are in the rail and a
/// question can be followed up.
///
/// Every answer is read off your own jots and nothing else. The jots it was read from are shown
/// beside it, so an answer is checkable rather than believed.
@MainActor @Observable
final class JotChat {
    static let shared = JotChat()

    /// One jot an answer was read from, and where in it.
    struct Source: Identifiable, Hashable {
        var capture: Capture
        /// The words of it the answer leant on, one line.
        var line: String
        var id: String { capture.id }
    }

    struct Turn: Identifiable {
        var id: Int
        var mine: Bool
        var text: String
        var sources: [Source] = []
    }

    private(set) var turns: [Turn] = []
    private(set) var threads: [Chat] = []
    private(set) var busy = false
    /// What the answer may read: nil is everything, a tag is that tag's jots.
    var scope: String?
    private(set) var thread = ChatLog.newID()

    private var log: ChatLog?

    /// Threads live beside the recordings, in the vault, as one append-only file each.
    func open(in vault: Vault) {
        guard log == nil else { return }
        log = ChatLog(folder: vault.root.appending(path: "chats", directoryHint: .isDirectory), app: "jot")
        reload()
    }

    func reload() { threads = log?.chats().sorted { $0.started > $1.started } ?? [] }

    /// A fresh thread. Nothing is thrown away: the one before it is a file, and in the rail.
    func start() {
        turns = []
        thread = ChatLog.newID()
        reload()
    }

    /// Reads an earlier thread back. Its words are kept; the jots an answer came from were its
    /// own moment and are not re-guessed here, because a re-guess could name a different jot
    /// from the one the answer was actually read off.
    func show(_ chat: Chat) {
        thread = chat.id
        turns = chat.lines.map { Turn(id: $0.n, mine: $0.mine, text: $0.text) }
    }

    func ask(_ question: String, over corpus: [(capture: Capture, text: String)], tags: [String: [String]]) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        add(Turn(id: turns.count, mine: true, text: q))

        let inScope = scope.map { tag in corpus.filter { tags[$0.capture.id]?.contains(tag) == true } } ?? corpus
        let found = Ask.rank(q, inScope, text: \.text, when: { $0.capture.date })
        guard !found.isEmpty else {
            add(Turn(id: turns.count, mine: false,
                     text: scope == nil ? "Nothing you captured says that." : "Nothing under #\(scope!) says that."))
            return
        }
        let entries = found.map {
            HistoryView.Entry(at: $0.capture.date, text: $0.text, heard: nil, mode: $0.capture.kind.rawValue,
                              app: "Jot", project: nil, device: nil, seconds: $0.capture.seconds)
        }
        let answer: String
        do { answer = try await AI.ask(q, from: entries) } catch { answer = error.localizedDescription }
        add(Turn(id: turns.count, mine: false, text: answer,
                 sources: found.prefix(2).map { Source(capture: $0.capture, line: first(of: $0.text)) }))
    }

    /// The first sentence of a jot: what the source card shows under its title.
    private func first(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard let stop = flat.firstIndex(where: { ".!?".contains($0) }) else { return String(flat.prefix(90)) }
        return String(flat[..<stop])
    }

    private func add(_ turn: Turn) {
        turns.append(turn)
        guard let log else { return }
        if turn.id == 0 { try? log.start(thread, device: Host.current().localizedName) }
        try? log.append(ChatLine(n: turn.id, mine: turn.mine, text: turn.text), to: thread)
        reload()
    }
}

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var chat = JotChat.shared
    @State private var store = NoteStore.shared
    @State private var dictations: [HistoryView.Entry] = []
    @State private var question = ""
    @State private var attached: [String] = []
    @FocusState private var asking: Bool

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if chat.turns.isEmpty { welcome }
                    ForEach(chat.turns) { turn in
                        if turn.mine { mine(turn) } else { theirs(turn) }
                    }
                    if chat.busy { ProgressView().controlSize(.small).padding(.top, 4) }
                }
                // 760: the answer column is held to a readable measure however wide the window is.
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .top)
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            chat.open(in: model.vault)
            dictations = HistoryView.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dictations = HistoryView.load()
        }
    }

    // MARK: head

    private var head: some View {
        HStack(spacing: 16) {
            Text("Chat").font(.system(size: 30, weight: .bold))
            scopeChip
            Spacer(minLength: 8)
            Button { chat.start(); question = ""; attached = [] } label: {
                Label("New", systemImage: "plus")
                    .font(.system(size: 12.5))
            }
            .help("Start a new thread. The one you are in is kept, in the rail")
            .accessibilityIdentifier("chat-new")
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .frame(maxWidth: .infinity)
    }

    /// What the answer is allowed to read. It is a control, not a label: the scope goes out with
    /// the question.
    private var scopeChip: some View {
        let counts = model.linkCounts.tags
        let all = captures.count
        return Menu {
            Button("All \(all.formatted()) jots") { chat.scope = nil }
            if !counts.isEmpty {
                Divider()
                ForEach(counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { tag, n in
                    Button("#\(tag) \u{00B7} \(n)") { chat.scope = tag }
                }
            }
        } label: {
            Text(chat.scope.map { "#\($0)" } ?? "All \(all.formatted()) jots")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("What the answer may read")
        .accessibilityIdentifier("chat-scope")
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask across everything you captured.")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["What did I decide about the renewal, and when did I first say it?",
                         "Everything I have said about the ship script",
                         "Who was in the meeting on Thursday?"], id: \.self) { example in
                    Button(example) { question = example; asking = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.glyphGreenText)
                }
            }
            Text("Answers are read off your own jots, on this Mac, and the jots they came from are shown beside them.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    // MARK: turns

    private func mine(_ turn: JotChat.Turn) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(turn.text)
                .font(.system(size: 15.5))
                .lineSpacing(5)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.quaternary.opacity(0.7), in: UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 6, topTrailing: 18)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func theirs(_ turn: JotChat.Turn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(turn.text))
                .font(.system(size: 15.5))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !turn.sources.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(turn.sources) { SourceCard(source: $0) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: composer

    private var composer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Attach a File\u{2026}") { attach() }
                Button("Import Audio\u{2026}") { importAudio() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach a file whose words go with the question, or import audio as a jot")
            .accessibilityLabel("Attach a file, or import audio")

            VStack(alignment: .leading, spacing: 6) {
                if !attached.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attached.indices, id: \.self) { i in
                            AttachedChip(name: attached[i]) { attachedText.remove(at: i); attached.remove(at: i) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Ask across your jots", text: $question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                        .focused($asking)
                        .onSubmit(run)
                        .accessibilityIdentifier("chat-field")
                    DictateButton(text: $question)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.quaternary.opacity(0.4), in: Capsule())
                .overlay(Capsule().strokeBorder(asking ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
            }

            Button(action: run) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || chat.busy)
            .help("Ask")
            .accessibilityLabel("Ask")
            .accessibilityIdentifier("chat-ask")
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @State private var attachedText: [String] = []

    private func run() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let asked = attachedText.isEmpty ? q : q + "\n\n" + attachedText.joined(separator: "\n\n")
        question = ""
        attached = []
        attachedText = []
        let corpus = self.corpus
        let tags = self.tags
        Task { await chat.ask(asked, over: corpus, tags: tags) }
    }

    /// A file's words go with the question. Plain text and Markdown only: a PDF or a photo would
    /// need reading, and a chip claiming a file was read when it was not is worse than no chip.
    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType("net.daringfireball.markdown") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            attached.append(url.lastPathComponent)
            attachedText.append("From \(url.lastPathComponent):\n" + text.prefix(8000))
        }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.importAudio(panel.urls) }
    }

    // MARK: what an answer may read

    private var captures: [Capture] { AllPane.captures(model, notes: store.notes, dictations: dictations) }

    /// Each jot with the words to search it by. A recording's are its summary, which is what the
    /// recording says about itself; its transcript is behind the card the answer links to.
    private var corpus: [(capture: Capture, text: String)] {
        let vault = model.vault
        return captures.map { c in
            switch c.kind {
            case .recording:
                let summary = vault.notes(c.id).summary
                return (c, [c.title, summary].filter { !$0.isEmpty }.joined(separator: ". "))
            default:
                return (c, c.snippet.isEmpty ? c.title : c.title + " " + c.snippet)
            }
        }
    }

    private var tags: [String: [String]] {
        Dictionary(captures.map { ($0.id, $0.tags) }, uniquingKeysWith: { a, _ in a })
    }
}

/// A jot an answer was read from: its kind's colour, its title, and the line it leant on. Click
/// opens the jot itself.
struct SourceCard: View {
    let source: JotChat.Source
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.open(source.capture) } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: source.capture.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.capture.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(source.line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(AnyShapeStyle(.quaternary.opacity(hover ? 0.7 : 0.4)))
                shape.strokeBorder(Color(nsColor: .separatorColor))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open this \(source.capture.kind.rawValue)")
    }
}

/// A file waiting to go with the question.
struct AttachedChip: View {
    let name: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 10.5))
            Text(name).font(.system(size: 12)).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Take \(name) off the question")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// The rail while Chat is open: the two modes, then the threads before this one.
struct ChatThreads: View {
    @Environment(AppModel.self) private var model
    @State private var chat = JotChat.shared

    var body: some View {
        List {
            Section {
                Button { model.sidebar = .all } label: {
                    Label("Jots", systemImage: "mic")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Label("Chat", systemImage: "bubble.left")
                    .foregroundStyle(.tint)
                    .fontWeight(.semibold)
            }
            if !chat.threads.isEmpty {
                Section {
                    ForEach(chat.threads) { thread in
                        Button { chat.show(thread) } label: {
                            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .fontWeight(thread.id == chat.thread ? .semibold : .regular)
                                .foregroundStyle(thread.id == chat.thread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionHeading(title: "Earlier")
                }
            }
        }
        .listStyle(.sidebar)
        .task { chat.open(in: model.vault) }
    }
}
