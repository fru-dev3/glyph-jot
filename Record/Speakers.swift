import GlyphCore
import SwiftUI

/// One color per voice, in the order they first speak: Speaker 1 is Glyph's green.
enum SpeakerColor {
    static let palette: [Color] = [.accentColor, .blue, .purple, .teal, .pink, .indigo]

    static func of(_ speaker: String) -> Color {
        if speaker.hasPrefix("S"), let n = Int(speaker.dropFirst()), n > 0 { return palette[(n - 1) % palette.count] }
        return palette[abs(speaker.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
    }
}

/// Who spoke, how much, under the tab bar. Click a voice to say who it is.
struct SpeakerLegend: View {
    let id: String
    let transcript: Transcript

    var body: some View {
        let talk = transcript.talkTime
        let total = max(talk.reduce(0) { $0 + $1.seconds }, 0.01)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(talk.count == 1 ? "1 speaker" : "\(talk.count) speakers")
                    .font(.system(size: 17, weight: .semibold))
                if talk.contains(where: { transcript.speakers[$0.speaker] == nil }) {
                    Text("Click a voice to say who it is")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(talk, id: \.speaker) { t in
                    SpeakerChip(id: id, speaker: t.speaker, name: transcript.name(of: t.speaker),
                                share: t.seconds / total)
                }
            }
        }
        .padding(.bottom, 18)
    }
}

struct SpeakerChip: View {
    let id: String
    let speaker: String
    let name: String
    let share: Double
    @State private var naming = false

    var body: some View {
        Button { naming = true } label: {
            HStack(spacing: 7) {
                Circle().fill(SpeakerColor.of(speaker)).frame(width: 9, height: 9)
                Text(name).font(.system(size: 13, weight: .semibold))
                Text("\(Int((share * 100).rounded()))%")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(SpeakerColor.of(speaker).opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(name) talked \(Int((share * 100).rounded()))% of the time. Click to name")
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            SpeakerNamer(id: id, speaker: speaker, current: name)
        }
    }
}

/// "Who is Speaker 2?": type a name, or pick a person (who is then linked to the recording).
struct SpeakerNamer: View {
    let id: String
    let speaker: String
    let current: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var people: [StudioObject] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return model.studio.objects(.person)
            .filter { p in ([p.name] + p.aliases).contains { $0.localizedCaseInsensitiveContains(q) } }
            .prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is \(current)?").font(.system(size: 17, weight: .semibold))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit {
                    let exact = model.studio.objects(.person).first { $0.name.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespaces)) == .orderedSame }
                    save(text, exact)
                }
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(people) { p in
                        Button { save(p.name, p) } label: {
                            Label(p.name, systemImage: "person.crop.circle")
                                .labelStyle(TintedIconLabel())
                                .font(.system(size: 13.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Name this voice \(p.name) and link the recording to them")
                    }
                }
            }
            if !current.hasPrefix("Speaker ") {
                Button("Forget the name") { save("", nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5))
            }
        }
        .padding(18)
        .frame(width: 280)
        .onAppear { text = current.hasPrefix("Speaker ") ? "" : current }
    }

    private func save(_ name: String, _ person: StudioObject?) {
        model.nameSpeaker(speaker, in: id, to: name, person: person)
        dismiss()
    }
}

/// The recording's loudness, colored by who is speaking, with the playhead. Click or drag
/// anywhere to play from there.
struct SpeakerWaveform: View {
    let peaks: [Float]
    let segments: [Transcript.Segment]
    let time: Double
    let duration: Double
    var onScrub: (Double?) -> Void
    var onSeek: (Double) -> Void

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, duration > 0 else { return }
            let step = size.width / CGFloat(peaks.count)
            let bar = max(1, step * 0.62)
            let played = time / duration
            var k = 0
            for (i, peak) in peaks.enumerated() {
                let t = (Double(i) + 0.5) / Double(peaks.count) * duration
                // Segments are in order, so one sweep finds the speaker of every bar.
                while k < segments.count, segments[k].end < t { k += 1 }
                let speaker = k < segments.count && segments[k].start <= t ? segments[k].speaker : ""
                let base: Color = speaker.isEmpty ? .secondary : SpeakerColor.of(speaker)
                let h = max(2, CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: bar, height: h)
                let past = Double(i) / Double(peaks.count) <= played
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                         with: .color(base.opacity(speaker.isEmpty ? (past ? 0.5 : 0.25) : (past ? 1 : 0.4))))
            }
            let x = CGFloat(played) * size.width
            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.primary.opacity(0.75)))
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .gesture(drag)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue(Format.clock(time))
        .accessibilityAdjustableAction { direction in
            onSeek(min(max(0, time + (direction == .increment ? 15 : -15)), duration))
        }
    }

    @State private var width: CGFloat = 1

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { onScrub(seconds($0.location.x)) }
            .onEnded { onScrub(nil); onSeek(seconds($0.location.x)) }
    }

    private func seconds(_ x: CGFloat) -> Double { min(max(0, Double(x / max(width, 1))), 1) * duration }
}
