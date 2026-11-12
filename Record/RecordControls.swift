import GlyphCore
import SwiftUI

/// Record, at the foot of the sidebar (as Voice Memos keeps it): one calm card that is the
/// button when idle and the live recording while it runs (time, level, pause, stop).
/// Command-R and the menu bar work from anywhere; the floating panel still shows over other apps.
struct RecordDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        Group {
            if model.isRecording { live } else { idle }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if model.isRecording, model.recorder.state != .paused {
                // Red means live, and this is the one live thing: the running recording.
                shape.fill(Color.red.opacity(0.14))
                shape.strokeBorder(Color.red.opacity(0.45))
            } else {
                shape.fill(.background)
                shape.fill(.quaternary.opacity(hover && !model.isRecording ? 0.9 : 0.5))
                shape.strokeBorder(.separator.opacity(0.6))
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.glyph(reduceMotion), value: model.isRecording)
    }

    private var idle: some View {
        Button { model.toggleRecording() } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Circle().fill(.white).frame(width: 10, height: 10)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Record").font(.system(size: 14, weight: .semibold))
                    Text(model.includeSystemAudio ? "Mic and the Mac's sound" : "Microphone")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\u{2318}R").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Record a meeting or a conversation (Command-R)")
        .accessibilityIdentifier("record")
        .contextMenu {
            Toggle("Record the Mac's Sound Too", isOn: Binding(get: { model.includeSystemAudio }, set: { model.includeSystemAudio = $0 }))
        }
    }

    /// Running: the card is Stop, and says in one line what it is stopping and how long it has
    /// been going. The loudness lives at the foot of the recording itself, where the words are,
    /// so the level is drawn once and not twice.
    private var live: some View {
        let recorder = model.recorder
        let paused = recorder.state == .paused
        return HStack(spacing: 8) {
            Button { Task { await model.stopRecording() } } label: {
                HStack(spacing: 11) {
                    Image(systemName: paused ? "pause.circle.fill" : "circle.fill")
                        .font(.system(size: paused ? 13 : 10))
                        .foregroundStyle(paused ? Color.secondary : Color.red)
                        .symbolEffect(.pulse, options: .repeating, isActive: !paused && !reduceMotion)
                        .frame(width: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stop").font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 7) {
                            Text((paused ? "Paused" : "Recording") + " \u{00B7} " + Format.clock(recorder.elapsed))
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("record-time")
                            // What it is being filed as, while it runs: the one place the tag is
                            // visible when the window is showing something else.
                            if let tag = model.recording?.tags.first {
                                HStack(spacing: 1) {
                                    Text("#")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(CanonicalTags.color(tag) ?? .secondary)
                                        .accessibilityHidden(true)
                                    Text(tag).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop and save (Command-R)")
            .accessibilityIdentifier("stop")
            PanelButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume (Shift-Command-P)" : "Pause (Shift-Command-P)") {
                paused ? recorder.resume() : recorder.pause()
            }
            .accessibilityIdentifier(paused ? "resume" : "pause")
        }
        .accessibilityElement(children: .contain)
    }
}

/// Record in the toolbar, only while the sidebar (and its Record card) is hidden: a plain
/// toolbar symbol when idle, the time with a red dot while recording.
struct ToolbarRecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.toggleRecording() } label: {
            if model.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: model.recorder.state == .paused ? "pause.circle.fill" : "stop.circle.fill")
                        .foregroundStyle(model.recorder.state == .paused ? Color.secondary : Color.red)
                    Text(Format.clock(model.recorder.elapsed)).monospacedDigit()
                }
            } else {
                Image(systemName: "record.circle")
            }
        }
        .help(model.isRecording ? "Stop recording (Command-R)" : "Record (Command-R)")
    }
}
