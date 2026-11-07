import SwiftUI
import AppKit

extension View {
    /// Remembers how far this Table/List was scrolled under `key` (for this run of the app) and
    /// scrolls back there when a list with the same key is shown again. When `resetOn` (the search
    /// text) differs from last time, the remembered spot is forgotten and the list starts at the top.
    func rememberScroll(_ key: String, resetOn token: String = "") -> some View {
        background(ScrollMemoryProbe(key: key, token: token))
    }
}

/// Scroll offsets by list key.
enum ScrollMemory {
    fileprivate static var offsets: [String: CGFloat] = [:]
    /// The search text each key's offset belongs to.
    fileprivate static var tokens: [String: String] = [:]
    /// "Scroll this row into view" requests for lists that aren't on screen yet.
    fileprivate static var pendingRows: [String: Int] = [:]
    fileprivate static let probes = NSMapTable<NSString, ProbeView>.strongToWeakObjects()

    /// Scroll the list with this key so `row` is in the middle (now, or as soon as it's shown).
    static func scrollToRow(_ row: Int, key: String) {
        // Kept until a probe has actually scrolled, in case the list on screen is about to be replaced.
        pendingRows[key] = row
        if let p = probes.object(forKey: key as NSString), p.isAttached { p.reveal(row) }
    }

    /// Forget the saved offset if the search changed since it was saved.
    fileprivate static func check(_ key: String, _ token: String) {
        if tokens[key] != token { offsets[key] = nil; tokens[key] = token }
    }
}

/// SwiftUI on macOS 14 doesn't expose a Table's or List's scroll offset, so this invisible view
/// finds the NSScrollView behind the list it sits behind and reads and sets its clip view.
private struct ScrollMemoryProbe: NSViewRepresentable {
    let key: String
    let token: String
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ v: ProbeView, context: Context) { v.update(key: key, token: token) }
}

fileprivate final class ProbeView: NSView {
    private var key = ""
    private var token = ""
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private var generation = 0
    /// After a restore, SwiftUI may still move the list while rows load or update. Until this time
    /// (or until the user scrolls), such moves are undone instead of saved.
    private var hold: (y: CGFloat, until: TimeInterval)?
    var isAttached: Bool { scrollView != nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(key: String, token: String) {
        let changed = key != self.key || token != self.token
        let reset = ScrollMemory.tokens[key] != token
        self.key = key; self.token = token
        ScrollMemory.check(key, token)
        ScrollMemory.probes.setObject(self, forKey: key as NSString)
        if (changed || reset) && isAttached {
            // The list stays alive while its rows change, so this must not undo the coming move to the top.
            hold = nil
            generation += 1
            // After SwiftUI's update pass, so a table sharing it has already reloaded its new rows.
            DispatchQueue.main.async { [weak self] in self?.listChanged() }
        }
    }

    /// Different rows in the same list: go to the requested row, the remembered spot, or the top.
    private func listChanged() {
        guard let sv = scrollView else { return }
        if let row = ScrollMemory.pendingRows[key] { reveal(row) }
        else if ScrollMemory.offsets[key] != nil { restore() }
        else { scroll(sv, to: -sv.contentView.contentInsets.top) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { DispatchQueue.main.async { [weak self] in self?.attach() } }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func attach() {
        guard window != nil, scrollView == nil, let sv = findScrollView() else { return }
        UserScrollTracker.start()
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: sv.contentView, queue: .main) { [weak self] _ in
            self?.boundsChanged()
        }
        if let row = ScrollMemory.pendingRows[key] { reveal(row) } else { restore() }
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scrollView = nil
        hold = nil
        generation += 1
    }

    /// Only scrolling the user did is remembered; the table moving by itself (rows loading,
    /// the list being replaced) is ignored, or undone right after a restore.
    private func boundsChanged() {
        guard let sv = scrollView else { return }
        let y = sv.contentView.bounds.origin.y
        if UserScrollTracker.recentlyScrolled(sv) {
            hold = nil
            generation += 1   // stop any restore still waiting for rows
            record(y)
        } else if let h = hold {
            if ProcessInfo.processInfo.systemUptime > h.until { hold = nil }
            else if abs(y - h.y) > 1, h.y <= maxOffset(sv) { scroll(sv, to: h.y) }
        }
    }

    private func record(_ y: CGFloat) {
        guard ScrollMemory.tokens[key] == token else { return }
        ScrollMemory.offsets[key] = y
    }

    /// Rows arrive a moment after the table appears, so keep trying until the list is tall enough
    /// to scroll to the saved spot (or give up after a few seconds and go as far as it can).
    private func restore() {
        guard let sv = scrollView else { return }
        guard let target = ScrollMemory.offsets[key] else { hold = nil; return }   // new list: leave it at the top
        _ = sv
        retry { sv in target <= self.maxOffset(sv) ? target : nil }
    }

    /// Scroll so `row` sits in the middle of the list.
    func reveal(_ row: Int) {
        let key = self.key
        retry(done: { ScrollMemory.pendingRows[key] = nil }) { sv in
            guard let table = sv.documentView as? NSTableView, row < table.numberOfRows else { return nil }
            let r = table.rect(ofRow: row)
            let y = r.midY - sv.contentView.bounds.height / 2
            return min(max(y, -sv.contentView.contentInsets.top), self.maxOffset(sv))
        }
    }

    /// Calls `target` until it gives an offset (up to ~3 s), scrolls there, and holds it for a moment.
    private func retry(done: @escaping () -> Void = {}, _ target: @escaping (NSScrollView) -> CGFloat?) {
        generation += 1
        let gen = generation
        func attempt(_ triesLeft: Int) {
            guard gen == generation, let sv = scrollView else { return }
            let y: CGFloat
            if let t = target(sv) { y = t }
            else if triesLeft == 0 { y = maxOffset(sv) }
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(triesLeft - 1) }
                return
            }
            hold = (y, ProcessInfo.processInfo.systemUptime + 1.5)
            scroll(sv, to: y)
            record(y)
            done()
        }
        attempt(60)
    }

    private func maxOffset(_ sv: NSScrollView) -> CGFloat {
        (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height + sv.contentView.contentInsets.bottom
    }

    private func scroll(_ sv: NSScrollView, to y: CGFloat) {
        let clip = sv.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(-sv.contentView.contentInsets.top, min(y, maxOffset(sv)))))
        sv.reflectScrolledClipView(clip)
    }

    /// The table/outline scroll view that covers the same area as this view.
    private func findScrollView() -> NSScrollView? {
        let mine = convert(bounds, to: nil)
        let center = NSPoint(x: mine.midX, y: mine.midY)
        var ancestor = superview
        while let a = ancestor {
            if let sv = Self.scrollViews(in: a).first(where: { $0.convert($0.bounds, to: nil).contains(center) }) { return sv }
            ancestor = a.superview
        }
        return nil
    }

    private static func scrollViews(in v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        for s in v.subviews {
            if let sv = s as? NSScrollView, sv.documentView is NSTableView { out.append(sv) } else { out += scrollViews(in: s) }
        }
        return out
    }
}

/// Notes which list the user last scrolled (wheel/trackpad incl. momentum, scroller drags,
/// keyboard in the list), so programmatic moves can be told apart from the user's.
private enum UserScrollTracker {
    private static var monitor: Any?
    private static var last: (sv: ObjectIdentifier, time: TimeInterval)?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { e in
            if let sv = scrollView(for: e) { last = (ObjectIdentifier(sv), ProcessInfo.processInfo.systemUptime) }
            return e
        }
    }

    static func recentlyScrolled(_ sv: NSScrollView) -> Bool {
        guard let l = last, l.sv == ObjectIdentifier(sv) else { return false }
        return ProcessInfo.processInfo.systemUptime - l.time < 1
    }

    private static func scrollView(for e: NSEvent) -> NSScrollView? {
        guard let w = e.window else { return nil }
        var v: NSView?
        if e.type == .keyDown {
            v = w.firstResponder as? NSView
        } else if let cv = w.contentView {
            let p = cv.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
            v = cv.hitTest(p)
        }
        while let cur = v {
            if let sv = cur as? NSScrollView, sv.documentView is NSTableView { return sv }
            v = cur.superview
        }
        return nil
    }
}
