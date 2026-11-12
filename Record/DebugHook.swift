#if DEBUG
import AppKit
import GlyphCore
import SwiftUI

/// Debug builds only: drive the app from a script without touching the screen, so it
/// can be tested while nobody uses the Mac. Post the distributed notification
/// `dev.fru.jot.mac.app.check` with a command as the object, like `side:object:person/ken-lee`,
/// `tab:transcript`, `size:900x600`, `look:dark`, `windows:/tmp/w.json`.
@MainActor
enum DebugHook {
    static func install(_ model: AppModel) {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.fru.jot.mac.app.check"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command, model) }
        }
    }

    static func run(_ command: String, _ model: AppModel) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        let window = NSApp.windows.first { $0.identifier?.rawValue.contains("library") == true } ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 600 }
        NSLog("GlyphJot check: %@", command)

        func link(_ s: String) -> Link? {
            let kv = s.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            return switch kv[0] { case "object": .object(kv[1]); case "person": .person(kv[1]); case "product": .account(kv[1]); case "tag": .tag(kv[1]); default: nil }
        }

        switch verb {
        case "side":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch kv.first ?? "" {
            case "all": model.sidebar = .all
            case "notes": model.sidebar = .notes
            case "dictations": model.sidebar = .dictations
            case "recordings": model.sidebar = .recordings
            default: if let item = link(arg)?.sidebarItem { model.sidebar = item }
            }
        case "conv": model.selectedID = arg.isEmpty ? nil : arg
        case "tab": animate { model.tab = DetailTab(rawValue: arg) ?? .summary }
        case "sidebar": model.columns = arg == "hide" ? .detailOnly : .all
        case "list": animate { model.showList = arg != "hide" }
        case "listwidth": if let w = Double(arg) { model.listWidth = w }
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            guard wh.count == 2, let window else { return }
            var frame = window.frame
            frame.origin.y += frame.height - wh[1]
            frame.size = NSSize(width: wh[0], height: wh[1])
            window.setFrame(frame, display: true, animate: false)
        case "look":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "windows":
            let list = NSApp.windows.filter(\.isVisible).map { w in
                ["number": w.windowNumber, "title": w.title, "panel": w is NSPanel, "w": Int(w.frame.width), "h": Int(w.frame.height)] as [String: Any]
            }
            if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
                try? data.write(to: URL(filePath: arg))
            }
        // "snap:<png path>" draws the library (or "snap:other:<path>", the first other window)
        // into a picture from inside the app: no Screen Recording permission needed.
        case "snap":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let other = kv.first == "other" && kv.count == 2
            let target = other ? NSApp.windows.first { $0.isVisible && $0 !== window && !($0 is NSPanel) && $0.frame.width > 300 } : window
            // An app may picture its own windows; the call is gone from the SDK, so look it up.
            typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let target, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Grab.self)(.null, 1 << 3, UInt32(target.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(filePath: other ? kv[1] : arg))
            }
        case "library": JotWindow.open(activate: false)
        case "front":
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        case "closesettings": model.sidebar = .all
        // "addfield:<text>" opens the + field on the open recording or note with that text typed.
        case "addfield": model.addLinkRequest = (model.addLinkRequest.id + 1, arg)
        // "notenew:<file>|place:River Walk" makes a CRM entity, as picking "New place" does, and links it.
        case "notenew":
            let kv = arg.split(separator: "|", maxSplits: 1).map(String.init)
            let kn = kv.count == 2 ? kv[1].split(separator: ":", maxSplits: 1).map(String.init) : []
            if kn.count == 2, let kind = StudioObject.Kind.entities.first(where: { $0.prefix == kn[0] }) {
                Task { if let id = await model.createEntity(kind, kn[1]) { model.addLink(.object(id), to: .note(kv[0])) } }
            }
        // "notedomain:<file>|health" files a note to a domain ("notedomain:<file>|" takes it off).
        case "notedomain":
            let kv = arg.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if kv.count == 2 { try? NoteStore.shared.setDomain(kv[0], kv[1].isEmpty ? nil : kv[1]) }
        // "thought:<text>" saves a note as Fn+Shift does (domain lead-in and all).
        case "thought": _ = try? Thoughts.save(arg); NoteStore.shared.reload()
        case "settingspane": UserDefaults.standard.set(arg, forKey: "settingsPane")
        case "review": model.reviewingLinks = arg != "off"
        case "reviewlink": model.reviewApply += 1
        case "quickopen": model.quickOpen = arg != "off"
        case "search": model.searchText = arg
        case "settings": model.showSettings()
        case "record":
            Task { arg == "stop" ? await model.stopRecording() : await model.startRecording() }
        case "feed": model.debugFeed = arg.isEmpty ? nil : URL(filePath: arg)
        case "pause": arg == "off" ? model.recorder.resume() : model.recorder.pause()
        case "systemaudio": model.includeSystemAudio = arg == "on"
        case "rename": if let id = model.selectedID { model.rename(id, to: arg) }
        case "trash": if let id = model.selectedID { model.trash(id) }
        case "copymd": if let id = model.selectedID { model.copyMarkdown(id) }
        case "add": if let id = model.recordingID ?? model.selectedID, let l = link(arg) { model.addLink(l, to: .recording(id)) }
        case "remove": if let id = model.selectedID, let l = link(arg) { model.removeLink(l, from: .recording(id)) }
        // "notelink:<file>|object:<id>" files a note; "noteunlink:..." takes it off.
        case "notelink", "noteunlink":
            let kv = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if kv.count == 2, let l = link(kv[1]) {
                verb == "notelink" ? model.addLink(l, to: .note(kv[0])) : model.removeLink(l, from: .note(kv[0]))
            }
        // "open:<n>" opens the n-th row of All's Recent list, as a click does.
        case "open":
            let all = AllPane.captures(model, notes: NoteStore.shared.notes, dictations: HistoryView.load())
            if let n = Int(arg), all.indices.contains(n) { model.open(all[n]) }
        case "ask": Task { await Ask.shared.run(arg, over: AllPane.askSources(model), show: false) }
        case "accept", "dismiss": if let id = model.selectedID, let l = link(arg) { model.answer(l, for: id, accept: verb == "accept") }
        case "process": if let id = model.selectedID { Task { await model.process(id) } }
        case "speaker": // speaker:S2=Ken Lee (a Studio person's name links them)
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if let id = model.selectedID, kv.count == 2 {
                model.nameSpeaker(kv[0], in: id, to: kv[1], person: model.studio.objects(.person).first { $0.name == kv[1] })
            }
        case "import": model.importAudio([URL(filePath: arg)])
        case "banner": model.show(arg.isEmpty ? AIError.unavailable(.appleIntelligenceOff).localizedDescription : arg,
                                  fix: .settings("AppleIntelligence"), for: model.selectedID)
        // A plain text window for the engine to type into (the jot-while-recording test).
        case "scratch": Scratch.show()
        case "scratchtext": try? Scratch.text.write(to: URL(filePath: arg), atomically: true, encoding: .utf8)
        // What the engine would say: "jot:on[:mode]", "jot:off", "jot:thought:<file>".
        case "jot":
            let kv = arg.split(separator: ":", maxSplits: 1).map(String.init)
            switch kv.first ?? "" {
            case "on": model.engineSaid(.init(.jot, mode: kv.count > 1 ? kv[1] : "dictate", on: true))
            case "thought": model.engineSaid(.init(.thought, text: kv.count > 1 ? kv[1] : nil))
            default: model.engineSaid(.init(.jot, on: false))
            }
        case "note": model.openNote = arg; model.sidebar = .notes
        case "state":
            let state: [String: Any] = [
                "sidebar": String(describing: model.sidebar), "selected": model.selectedID ?? "",
                "listed": model.listed.map(\.id), "recording": model.recordingID ?? "",
                "studio": model.studio.objects.count, "counts": model.linkCounts.objects, "tags": model.linkCounts.tags,
                "links": model.selected?.links ?? [], "suggested": model.selected.map { $0.suggested.links + $0.suggested.people } ?? [],
                "notes": NoteStore.shared.notes.map { ["file": $0.file, "links": $0.links, "tags": $0.tags] as [String: Any] },
                "ask": Ask.shared.answer,
                "elapsed": model.recorder.elapsed, "stages": model.stages.mapValues(\.help),
                "banners": model.banners.map(\.message), "pasteboard": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(filePath: arg))
            }
        default: break
        }
    }
}
/// The test's typing target: a window with a text view, in focus.
@MainActor
enum Scratch {
    private static var window: NSWindow?
    private static var view: NSTextView?
    static var text: String { view?.string ?? "" }

    static func show() {
        if window == nil {
            let scroll = NSTextView.scrollableTextView()
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Jot test target"
            w.contentView = scroll
            w.isReleasedWhenClosed = false
            window = w
            view = scroll.documentView as? NSTextView
            view?.font = .systemFont(ofSize: 15)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }
}
#endif
