import GlyphCore
import SwiftUI

// MARK: motion

extension Animation {
    /// The one spring the app moves with; a quick fade when Reduce Motion is on.
    static func glyph(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.84) }
}

/// `withAnimation` that honours Reduce Motion.
@MainActor func animate(_ body: () -> Void) {
    withAnimation(.glyph(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), body)
}

// MARK: links

extension Link {
    /// One of Fru's canonical tags wears its own colour, the same hue the iPhone draws.
    /// nil for anything else, which keeps the window's tint.
    var tagColor: Color? {
        if case .tag(let t) = self { return CanonicalTags.color(t) }
        return nil
    }

    var symbol: String {
        if case .tag = self { return "number" }
        if case .object(let id) = self, id.hasPrefix("domain/") { return VaultDomains.symbol(String(id.dropFirst(7))) }
        return studioKind?.symbol ?? "link"
    }

    /// What a chip says: the Studio object's name, the new name, or the tag.
    /// Two entities of one name (two Johns) read with their page's name beside them.
    @MainActor var label: String {
        if case .object(let id) = self {
            let studio = AppModel.shared.studio
            if let o = studio.object(id), !studio.namesakes(o).isEmpty { return "\(o.name) \u{00B7} \(id.split(separator: "/").last ?? "")" }
            return studio.name(id)
        }
        return name
    }

    /// Studio's word for it, for help text and "New ..." rows.
    var kindName: String {
        if case .tag = self { return "tag" }
        return studioKind?.singular.lowercased() ?? "link"
    }

    var sidebarItem: SidebarItem? {
        switch self {
        case .object(let id): .object(id)
        case .tag(let t): .tag(t)
        default: nil
        }
    }
}

// MARK: chips

/// A link on a conversation. Click opens its page; hovering reveals the remove button.
struct LinkChip: View {
    let link: Link
    var size: ChipSize = .regular
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: link.symbol)
                .font(size.iconFont)
                .foregroundStyle(.tint)
            Text(link.label)
                .font(size.font)
                .lineLimit(1)
            if let onRemove, hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove \(link.label)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, size.hPad)
        .frame(height: size.height)
        .background(Color.accentColor.opacity(hover ? 0.16 : 0.10), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onOpen?() }
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .help(onOpen == nil ? "" : "Show everything filed under \(link.label)")
    }
}

enum ChipSize {
    case small, regular
    var font: Font { self == .small ? .system(size: 11.5, weight: .medium) : .system(size: 13, weight: .medium) }
    var iconFont: Font { self == .small ? .system(size: 9, weight: .semibold) : .system(size: 10.5, weight: .semibold) }
    var height: CGFloat { self == .small ? 20 : 26 }
    var hPad: CGFloat { self == .small ? 7 : 10 }
}

/// An AI guess: dashed until accepted. Click accepts; hovering reveals accept and dismiss.
struct SuggestionChip: View {
    let link: Link
    var onAccept: () -> Void
    var onDismiss: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: link.symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(link.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if hover {
                HStack(spacing: 2) {
                    Button(action: onAccept) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Circle())
                    }
                    .help("Add \(link.label)")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(.quaternary, in: Circle())
                    }
                    .help("Not \(link.label)")
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(hover ? Color.accentColor : Color.secondary.opacity(0.6))
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onAccept)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .help("Suggested \(link.kindName). Click to add.")
    }
}

/// A fact about a conversation: an icon and a short value.
struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 13)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: the add field

/// "+" that opens into a field which finds a Glyph CRM person, place, product or thing (or a
/// Studio project or domain), or a #tag, or makes a new entity in the CRM. Two of one name show
/// what tells them apart, so the pick is never the wrong John.
struct LinkAddField: View {
    enum Style { case overlay, inline }

    var style: Style = .overlay
    var placeholder = "Link a person, place, product, thing or #tag"
    var excluding: Set<Link> = []
    /// Opens with this text (from a request), when it changes.
    var request: (id: Int, prefix: String) = (0, "")
    var alwaysOpen = false
    var onAdd: (Link) -> Void

    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var candidates: [Candidate] {
        LinkMatcher.candidates(text, studio: model.studio, counts: model.linkCounts, excluding: excluding)
    }

    var body: some View {
        Group {
            if open || alwaysOpen {
                field
                    .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
            } else {
                Button {
                    animate { open = true }
                    focused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary.opacity(0.7), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Link a person, place, product or thing from Glyph CRM, or add a #tag. Saved in the file itself.")
                .accessibilityIdentifier("add-link")
            }
        }
        .onChange(of: request.id) {
            text = request.prefix
            animate { open = true }
            focused = true
        }
    }

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .frame(width: style == .inline ? nil : 220)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.background, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
            .onSubmit(commit)
            .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, candidates.count - 1)); return .handled }
            .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onChange(of: text) { highlighted = 0 }
            .onChange(of: focused) { if !focused && text.isEmpty { close() } }
            .onAppear { if !alwaysOpen { focused = true } }
            .overlay(alignment: .topLeading) {
                if style == .overlay, !candidates.isEmpty, focused {
                    list.frame(width: 320).offset(y: 32)
                }
            }
            .zIndex(10)
            .safeAreaInset(edge: .bottom, spacing: 6) {
                if style == .inline, !candidates.isEmpty, focused { list }
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(candidates.enumerated()), id: \.element) { i, c in
                Button { add(c) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: c.isNew ? "plus.circle" : c.newKind?.symbol ?? c.link.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(i == highlighted ? AnyShapeStyle(.white)
                                             : c.link.tagColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.isNew ? "New \((c.newKind?.singular.lowercased()) ?? c.link.kindName) \u{201C}\(c.link.label)\u{201D}"
                                 : c.detail != nil ? model.studio.name(c.link.name) : c.link.label)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            // One of Fru's canonical tags says what it covers, under its name.
                            if case .tag(let t) = c.link, let covers = CanonicalTags.covers(t) {
                                Text(covers)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(i == highlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                            }
                        }
                        if let detail = c.detail {
                            Text(detail).font(.system(size: 11.5)).lineLimit(1)
                                .foregroundStyle(i == highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        }
                        Spacer(minLength: 8)
                        if !c.isNew, c.count > 0 {
                            Text("\(c.count)").font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(i == highlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(minHeight: 26)
                    .foregroundStyle(i == highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(i == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = i } }
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private func commit() {
        guard candidates.indices.contains(highlighted) else { close(); return }
        add(candidates[highlighted])
    }

    private func add(_ c: Candidate) {
        if let kind = c.newKind {
            let name = c.link.name
            Task { if let id = await model.createEntity(kind, name) { animate { onAdd(.object(id)) } } }
        } else {
            animate { onAdd(c.link) }
        }
        text = ""
        highlighted = 0
        focused = true
    }

    private func close() {
        text = ""
        animate { open = false }
        focused = false
    }
}

// MARK: layout

/// Lays children out in rows, wrapping like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            // Centre each child on the row's line (chips and the round + differ a little).
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

// MARK: empty states

/// An empty state that teaches: a symbol, one line, and the one thing to do.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            actions.padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A key cap for teaching a shortcut.
struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7)
                .frame(minWidth: 28, minHeight: 22)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

// MARK: banners

/// A calm inline message with the fix.
struct BannerView: View {
    let banner: Banner
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(banner.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            fixButton
            Button { model.dismiss(banner) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.22)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private var fixButton: some View {
        switch banner.fix {
        case .none: EmptyView()
        case .retry(let id):
            Button("Try Again") {
                model.dismiss(banner)
                Task { await model.process(id) }
            }
            .controlSize(.small)
        case .settings(let pane):
            Button("Open Settings") { AppModel.openSettingsPane(pane) }
                .controlSize(.small)
        case .relaunch:
            Button("Relaunch") { AppModel.relaunch() }
                .controlSize(.small)
        case .unfile(let note, let place):
            Button("Undo") {
                model.dismiss(banner)
                NoteFiling.shared.unfile(note: note, place: place)
            }
            .controlSize(.small)
        }
    }
}

/// The small icon for background work on a conversation.
struct StageIcon: View {
    let stage: Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: stage.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            .help(stage.help)
            .accessibilityLabel(stage.help)
    }
}

// MARK: the family's green, and the two marks it wears

extension Color {
    /// Green that is legible as words in both appearances. The accent `#008000` is a fill: on
    /// near-black it fails 4.5:1, so headings, ticks and action labels take this instead, and the
    /// accent keeps the shapes. `#4aa96c` on dark, a darker office green on white.
    static let glyphGreenText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.290, green: 0.663, blue: 0.424, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.400, blue: 0, alpha: 1)
    })
    /// The same green, one step quieter: the date beside a section heading.
    static let glyphGreenQuiet = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.416, green: 0.620, blue: 0.478, alpha: 1)
            : NSColor(srgbRed: 0.145, green: 0.420, blue: 0.231, alpha: 1)
    })
}

/// A section's name: small, uppercase and green, because grey reads as "less important words"
/// rather than "a different kind of thing". Its date, when it has one, sits beside it.
struct SectionHeading: View {
    let title: String
    var detail: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.glyphGreenText)
            if let detail {
                Text(detail.uppercased())
                    .font(.system(size: 11.5, weight: .medium))
                    .kerning(0.4)
                    .foregroundStyle(Color.glyphGreenQuiet)
            }
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Vault state, and nothing else. One grey tick is waiting, two green are in the vault, words and
/// audio. It is never words, and nothing that is not vault state is ever allowed to borrow it.
struct VaultTicks: View {
    /// The words are in the vault too, not only the sound.
    let kept: Bool

    var body: some View {
        Canvas { ctx, _ in
            let colour = kept ? Color.glyphGreenText : Color.secondary
            var first = Path()
            first.move(to: CGPoint(x: kept ? 1 : 4, y: 6.5))
            first.addLine(to: CGPoint(x: kept ? 4.2 : 7.2, y: 9.7))
            first.addLine(to: CGPoint(x: kept ? 10.5 : 13.5, y: 3))
            ctx.stroke(first, with: .color(colour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            guard kept else { return }
            var second = Path()
            second.move(to: CGPoint(x: 8.2, y: 9.7))
            second.addLine(to: CGPoint(x: 9.4, y: 11))
            second.addLine(to: CGPoint(x: 15.7, y: 3.6))
            ctx.stroke(second, with: .color(colour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 14)
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(kept ? "In the vault, words and audio" : "In the vault; the words are still coming")
        .help(kept ? "In the vault, words and audio" : "The sound is in the vault; the words are still coming")
    }
}
