import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The canonical tags: the set Glyph Jot starts with, each with the one line it covers.
/// A default set, never a closed one: a tag the owner makes themselves lives beside these and is
/// never folded away. The iPhone uses the names as written; the Mac uses `slug`, which is
/// what `LinkMatcher.tidyTag` makes of the same name.
enum CanonicalTags {
    struct Tag: Hashable {
        let name: String
        /// One line: what belongs under this tag. Shown under the name in the tag picker.
        let covers: String
        /// The tag's own colour, "#rrggbb". One fixed hue each, so no two of the 23 collide.
        let hex: String
        /// "Real Estate" -> "real-estate": the Mac's spelling of the same tag.
        var slug: String {
            name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        }
    }

    static let all: [Tag] = [
        Tag(name: "Daily", covers: "The day as it goes: what happened, what is next, the running log.", hex: "#3ac8b4"),
        Tag(name: "Personal", covers: "Your own life, the things that belong to nobody else.", hex: "#3a9ec8"),
        Tag(name: "Career", covers: "The job: work, meetings, interviews, reviews, pay, colleagues.", hex: "#3a62c8"),
        Tag(name: "Business", covers: "fru.dev and the companies: products, customers, pricing, renewals.", hex: "#5c3ac8"),
        Tag(name: "Real Estate", covers: "Houses and land: deals, tenants, repairs, closings.", hex: "#983ac8"),
        Tag(name: "Property", covers: "Things owned: cars, tools, gear, what needs fixing or replacing.", hex: "#c83ab4"),
        Tag(name: "Wealth", covers: "Money overall: accounts, balances, holdings, net worth, taxes.", hex: "#c83a62"),
        Tag(name: "Health", covers: "Body and mind: training, food, sleep, doctors, medication.", hex: "#c85c3a"),
        Tag(name: "Relationships", covers: "People: family, friends, who said what, who to reach.", hex: "#c8983a"),
        Tag(name: "Names", covers: "Names for anything: projects, products, places, people.", hex: "#b4c83a"),
        Tag(name: "Learning", covers: "What you are studying: books, courses, notes, what you now know.", hex: "#62c83a"),
        Tag(name: "Vocabulary", covers: "Single words and phrases worth keeping, in any language.", hex: "#3ac85c"),
        Tag(name: "Ideas", covers: "Something new to make or try, before it is a decision.", hex: "#3ac898"),
        Tag(name: "Decisions", covers: "A call made and why, so it is not re-argued later.", hex: "#3a7ec8"),
        Tag(name: "Dreams", covers: "Dreams and what they felt like, written down on waking.", hex: "#3ab4c8"),
        Tag(name: "Faith", covers: "God, prayer, scripture, church, what you believe.", hex: "#463ac8"),
        Tag(name: "African", covers: "Cameroon and Africa: home, culture, language, what is happening there.", hex: "#7e3ac8"),
        Tag(name: "Travel", covers: "Trips: where, when, what it cost, what to see again.", hex: "#b43ac8"),
        Tag(name: "Content", covers: "What goes out: videos, posts, whispers, the channel, the writing.", hex: "#c83a98"),
        Tag(name: "Comedy", covers: "Jokes, bits, funny lines, what made you laugh.", hex: "#c83a46"),
        Tag(name: "Hunting", covers: "Hunting and fishing: seasons, land, gear, the day out.", hex: "#c87e3a"),
        Tag(name: "Recreation", covers: "Time off: riding, hiking, music, games, what is just for fun.", hex: "#c8b43a"),
        Tag(name: "Systems", covers: "How things run: the vault, the agents, the Macs, the tools, the setup.", hex: "#98c83a"),
    ]

    static let names: [String] = all.map(\.name)

    /// The "covers" line for a tag, by name or by slug. nil for a tag the owner made themselves.
    static func covers(_ name: String) -> String? {
        all.first { $0.slug == slug(name) }?.covers
    }

    /// A canonical tag's own colour as "#rrggbb", by name or by slug. nil for a tag the owner
    /// made themselves, which falls back to a colour hashed from its name.
    static func hex(_ name: String) -> String? {
        all.first { $0.slug == slug(name) }?.hex
    }

    /// Where a tag the owner made themselves lands in a palette of `count`: a stable hash of its name,
    /// the same every launch and on both the iPhone and the Mac.
    static func fallbackIndex(_ name: String, of count: Int) -> Int {
        let hash = name.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff }
        return hash % max(count, 1)
    }

    /// Old tag names folded into the canonical set. A name not in here keeps its own:
    /// Names and Daily are already canonical, and anything the owner made stays as it is.
    static let folded: [String: String] = [
        "knowledge": "Learning",
        "books": "Learning",
        "whisper": "Content",
        "word": "Vocabulary",
        "renewal": "Business",
        "meetings": "Career",
        "jot": "Systems",
    ]

    /// One tag's canonical name: its mapping, the canonical spelling if it is one of the
    /// 23 in another case, else the name untouched.
    static func fold(_ tag: String) -> String {
        let key = slug(tag)
        return folded[key] ?? all.first { $0.slug == key }?.name ?? tag
    }

    /// A memo's tags folded into the canonical set: order kept, twins merged (Knowledge and
    /// Books both become Learning), nothing dropped. Idempotent: folding twice changes nothing.
    static func fold(_ tags: [String]) -> [String] {
        var out: [String] = []
        for name in tags.map(fold) where !out.contains(name) { out.append(name) }
        return out
    }

    /// Any spelling of a tag reduced to its slug, so a name and its slug look the same up.
    private static func slug(_ name: String) -> String { Tag(name: name, covers: "", hex: "").slug }
}

#if canImport(SwiftUI)
extension CanonicalTags {
    /// A canonical tag's own colour. nil for a tag the owner made themselves, so the caller can fall
    /// back to its own palette.
    static func color(_ name: String) -> Color? {
        guard let hex = hex(name), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255,
                     green: Double(v >> 8 & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
#endif
