import GlyphCore
import SwiftUI

/// Home: a day at a time. The fortnight on a rail with a dot on the days you jotted, what the
/// chosen day holds, then the captures themselves grouped by their day, newest first.
///
/// The three counting tiles that used to sit here are gone: the sidebar already counts Notes,
/// Dictations and Recordings, and one count system across every screen means saying it once.
/// Asking moved to Chat, where a question keeps its thread.
struct AllPane: View {
    @Environment(AppModel.self) private var model
    @State private var store = NoteStore.shared
    @State private var dictations: [HistoryView.Entry] = []
    @State private var day = Calendar.current.startOfDay(for: .now)

    /// How many rows the window holds at once. It is a window onto the vault, not the vault.
    private static let rows = 120

    var body: some View {
        let search = model.searchText.trimmingCharacters(in: .whitespaces)
        let all = captures
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .padding(.bottom, 18)
                    DayStrip(days: strip(all), selected: $day)
                        .padding(.bottom, 14)
                    dayLine(all)
                        .padding(.bottom, 16)
                    if search.isEmpty {
                        groups(upTo(all), wide: wide)
                    } else {
                        found(matches(all, search), search, wide: wide)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 40)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { dictations = HistoryView.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dictations = HistoryView.load() }
    }

    // MARK: the day

    private var calendar: Calendar { .current }
    private var isToday: Bool { calendar.isDateInToday(day) }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(dayName(day))
                .font(.system(size: 30, weight: .bold))
            SectionHeading(title: day.formatted(.dateTime.month(.wide).year()))
            Spacer(minLength: 8)
            if streak >= 2 { StreakChip(days: streak) }
        }
    }

    private func dayName(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        // Inside the week it is enough to say the weekday; beyond it, say the date.
        let days = calendar.dateComponents([.day], from: date, to: .now).day ?? 0
        return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The chosen day in one line: how much of it there is. Nothing is invented: a Mac does not
    /// move, so there are no places to count here as there are on the phone.
    private func dayLine(_ all: [Capture]) -> some View {
        let today = all.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let seconds = today.reduce(0) { $0 + $1.seconds }
        return HStack(spacing: 16) {
            Text("\(today.count) jot\(today.count == 1 ? "" : "s")")
            if seconds > 0 { Text("\(Format.duration(Int(seconds))) recorded") }
            if today.isEmpty { Text(isToday ? "Hold Fn to jot, or press Record" : "Nothing this day") }
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    /// The fortnight ending today, each day with how many captures it holds.
    private func strip(_ all: [Capture]) -> [DayStrip.Day] {
        var counts: [Date: Int] = [:]
        for c in all { counts[calendar.startOfDay(for: c.date), default: 0] += 1 }
        let today = calendar.startOfDay(for: .now)
        return (0..<14).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DayStrip.Day(date: date, count: counts[date] ?? 0)
        }
    }

    /// Days in a row, ending today or yesterday, with something captured on each.
    private var streak: Int {
        let days = Set(captures.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: .now)
        guard let start = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today),
              days.contains(start) else { return 0 }
        var n = 0
        var cursor = start
        while days.contains(cursor) {
            n += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = before
        }
        return n
    }

    // MARK: the captures

    var captures: [Capture] { Self.captures(model, notes: store.notes, dictations: dictations) }

    static func captures(_ model: AppModel, notes: [JotNote], dictations: [HistoryView.Entry]) -> [Capture] {
        let recordings = model.library.conversations.map { c in
            Capture(kind: .recording, id: c.id, title: c.title, date: Format.date(c.created) ?? .distantPast,
                    links: c.links, tags: c.tags, seconds: Double(c.durationSec),
                    kept: model.stage(c.id) == nil)
        }
        let written = notes.map {
            Capture(kind: .note, id: $0.file, title: $0.title, date: $0.date, links: $0.links, tags: $0.tags,
                    snippet: snippet($0.text, after: $0.title))
        }
        let said = dictations.filter { $0.mode != "ask" }.map {
            Capture(kind: .dictation, id: $0.id, title: String($0.text.prefix(120)), date: $0.at,
                    seconds: $0.seconds)
        }
        return (recordings + written + said).sorted { $0.date > $1.date }
    }

    /// The words after the title: what the row's second column shows.
    private static func snippet(_ text: String, after title: String) -> String {
        let body = text.hasPrefix(title) ? String(text.dropFirst(title.count)) : text
        return body.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }

    /// From the chosen day backwards: the days under it are still there, which is what a rail over
    /// a list means.
    private func upTo(_ all: [Capture]) -> [Capture] {
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return Array(all.filter { $0.date < end }.prefix(Self.rows))
    }

    private func matches(_ all: [Capture], _ search: String) -> [Capture] {
        let hits = model.searchHits ?? []
        let q = search.lowercased()
        let text = Dictionary(store.notes.map { ($0.file, $0.text) }, uniquingKeysWith: { a, _ in a })
            .merging(dictations.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        return Array(all.filter { c in
            switch c.kind {
            case .recording: hits.contains(c.id)
            default: (text[c.id] ?? c.title).lowercased().contains(q) || c.links.contains { model.studio.name($0).lowercased().contains(q) }
            }
        }.prefix(50))
    }

    @ViewBuilder private func found(_ shown: [Capture], _ search: String, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeading(title: "Matches", detail: search, trailing: shown.count.formatted())
                .padding(.bottom, 7)
            if shown.isEmpty {
                Text("Nothing you captured says that.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(shown) { CaptureRow(capture: $0, wide: wide) }
            }
        }
    }

    /// One block a day, with the day said once at its head. The chosen day needs no head: the
    /// title and the line above it have already said which day it is and how much it holds.
    @ViewBuilder private func groups(_ shown: [Capture], wide: Bool) -> some View {
        let blocks = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
        if shown.isEmpty {
            EmptyState(symbol: "waveform", title: "Nothing captured yet",
                       message: "Hold Fn to jot where you are, Fn and Shift to save a note, or press Record.")
                .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks, id: \.key) { date, items in
                    VStack(alignment: .leading, spacing: 2) {
                        if !calendar.isDate(date, inSameDayAs: day) {
                            SectionHeading(title: dayName(date),
                                           detail: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                           trailing: items.count.formatted())
                                .padding(.top, 10)
                                .padding(.bottom, 7)
                        }
                        ForEach(items) { CaptureRow(capture: $0, wide: wide) }
                    }
                }
            }
        }
    }

    /// What Ask reads: every dictation, note and recording (its title, links and summary).
    static func askSources(_ model: AppModel, dictations: [HistoryView.Entry]? = nil) -> [HistoryView.Entry] {
        let notes = NoteStore.shared.notes.map {
            HistoryView.Entry(at: $0.date, text: $0.text, heard: nil, mode: "note", app: "Notes", project: nil, device: $0.device, seconds: 0)
        }
        let recordings = model.library.conversations.prefix(200).map { c in
            let summary = model.vault.notes(c.id).summary
            let filed = c.links.map(model.studio.name).joined(separator: ", ")
            return HistoryView.Entry(at: Format.date(c.created) ?? .distantPast, text: [c.title, filed, summary].filter { !$0.isEmpty }.joined(separator: ". "),
                                     heard: nil, mode: "recording", app: "Recording", project: nil, device: c.device, seconds: Double(c.durationSec))
        }
        return (dictations ?? HistoryView.load()) + notes + recordings
    }
}

/// The fortnight: a weekday letter, the date, and a dot on the days you jotted. Today is filled
/// with the accent. Never a shade that deepens with the count: a shade does not say whether a day
/// happened, and green shading would fight a red waveform.
struct DayStrip: View {
    struct Day: Identifiable, Hashable {
        var date: Date
        var count: Int
        var id: Date { date }
    }

    let days: [Day]
    @Binding var selected: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var calendar: Calendar { .current }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days) { day in
                cell(day)
            }
            Spacer(minLength: 0)
        }
    }

    private func cell(_ day: Day) -> some View {
        let today = calendar.isDateInToday(day.date)
        let chosen = calendar.isDate(day.date, inSameDayAs: selected)
        return Button {
            withAnimation(.glyph(reduceMotion)) { selected = calendar.startOfDay(for: day.date) }
        } label: {
            VStack(spacing: 2) {
                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(today ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                Text(day.date.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(today ? AnyShapeStyle(.white) : day.count > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Circle()
                    .fill(today ? AnyShapeStyle(.white) : day.count > 0 ? AnyShapeStyle(Color.glyphGreenText) : AnyShapeStyle(.clear))
                    .frame(width: 4, height: 4)
            }
            // 46 x 58 drawn; the hit area is the 44 the finger and the pointer both need.
            .frame(width: 46, height: 58)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                if today {
                    shape.fill(Color.accentColor)
                } else {
                    shape.fill(day.count > 0 ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.quaternary.opacity(0.3)))
                    shape.strokeBorder(.separator.opacity(0.7))
                }
                if chosen, !today { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .overlay {
                if chosen, today {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
                            + ", " + (day.count > 0 ? "\(day.count) jots" : "nothing"))
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
        .help(day.count > 0 ? "\(day.count) captured" : "Nothing captured")
    }
}

/// Days in a row with something captured. Not a tick: a run of days is not vault state.
struct StreakChip: View {
    let days: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            Text("\(days) days")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.glyphGreenText)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(days) days in a row")
        .help("\(days) days in a row with something captured")
    }
}

/// One capture: what kind it is, its title, its first words, the tag it is filed under, when, and
/// its vault state as ticks. Click opens it.
struct CaptureRow: View {
    let capture: Capture
    var wide = true
    @Environment(AppModel.self) private var model
    @State private var hover = false
    @State private var summary = ""

    var body: some View {
        Button { model.open(capture) } label: {
            HStack(spacing: 14) {
                Image(systemName: capture.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(capture.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: wide ? 320 : nil, alignment: .leading)
                    .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                if wide {
                    Text(snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let tag = capture.tags.first {
                    HStack(spacing: 2) {
                        Text("#")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(CanonicalTags.color(tag) ?? .secondary)
                            .accessibilityHidden(true)
                        Text(tag).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                Text(capture.date.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                VaultTicks(kept: capture.kept)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(hover ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open this \(capture.kind.rawValue)")
        // A recording's own words are in its summary file: read for the rows on screen only.
        .task(id: capture.id) {
            guard capture.kind == .recording, wide else { return }
            let vault = model.vault
            let id = capture.id
            summary = await Task.detached(priority: .utility) { vault.notes(id).summary }.value
        }
    }

    /// A recording says its words when it has them, and what it is still doing when it does not.
    private var snippet: String {
        if !capture.snippet.isEmpty { return capture.snippet }
        if !summary.isEmpty { return summary }
        var parts: [String] = []
        if capture.seconds > 0 { parts.append(Format.duration(Int(capture.seconds))) }
        if let stage = model.stage(capture.id) { parts.append(stage.help.lowercased()) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A Studio object with how many captures it has; click opens its page.
struct CountChip: View {
    let link: Link
    let count: Int
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { if let item = link.sidebarItem { model.sidebar = item } } label: {
            HStack(spacing: 6) {
                Image(systemName: link.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tint)
                Text(link.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(count.formatted()).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.accentColor.opacity(hover ? 0.16 : 0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .help("Show everything filed under \(link.label)")
    }
}
