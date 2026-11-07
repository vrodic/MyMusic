import SwiftUI
import AppKit

/// The song list, as a plain `NSTableView`. SwiftUI's `Table` hosts a SwiftUI view per cell and has to
/// be torn down and rebuilt when its rows change wholesale, which made every search keystroke cost
/// well over 100 ms. Here one table stays alive, `reloadData()` only touches the visible rows, and
/// cells draw their own text instead of holding a text field.
struct TrackTableView: NSViewRepresentable {
    let rows: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var sortOrder: [KeyPathComparator<Track>]
    /// The playing song, shown in bold.
    let currentPath: String?
    /// The up-to-date copy of a song: `rows` can be a stale snapshot (e.g. `FolderNode.tracks`), but hearts must be live.
    let liveTrack: (String) -> Track?
    let onToggleFavorite: (Track) -> Void
    /// The ♥ header is a "favorite everything shown" button, not a sort.
    let onFavoriteHeaderClicked: () -> Void
    /// Double-click or Return.
    let onPlay: (Track) -> Void
    let onDeleteKey: () -> Void
    let onTypeToSearch: (Character) -> Void
    /// Context menu for these songs (the clicked one, or the whole selection if it's part of it).
    let menuItems: (Set<Track.ID>) -> [NSMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = TrackNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.allowsTypeSelect = false   // letters start a search instead
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for field in TrackSortField.allCases { table.addTableColumn(field.makeColumn()) }
        TrackColumnLayout.applySavedLayout(to: table)

        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onHeartClick = { [weak c] row in c?.heartClicked(row: row) }
        table.onPlayKey = { [weak c] in c?.playSelected() }
        table.onDeleteKey = { [weak c] in c?.parent.onDeleteKey() }
        table.onTypeToSearch = { [weak c] ch in c?.parent.onTypeToSearch(ch) }

        let rowMenu = NSMenu()
        rowMenu.delegate = c
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = c
        table.headerView?.menu = headerMenu
        c.table = table
        c.rowMenu = rowMenu
        c.headerMenu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        c.update(from: self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TrackTableView
        weak var table: TrackNSTableView?
        weak var rowMenu: NSMenu?
        weak var headerMenu: NSMenu?
        private var rows: [Track] = []
        private var appliedSort: String?
        /// True while code (not the user) changes the table, so its callbacks don't write back to SwiftUI.
        private var applying = false

        init(parent: TrackTableView) { self.parent = parent }

        func update(from new: TrackTableView) {
            parent = new
            guard let table else { return }
            applying = true
            defer { applying = false }

            let sort = new.sortOrder.serialize()
            if sort != appliedSort {
                appliedSort = sort
                table.sortDescriptors = new.sortOrder.compactMap { comp in
                    TrackSortField.from(keyPath: comp.keyPath).map { NSSortDescriptor(key: $0.rawValue, ascending: comp.order == .forward) }
                }
            }
            if new.rows != rows {
                rows = new.rows
                table.reloadData()
            } else {
                refreshVisibleCells()
            }
            applySelection()
        }

        /// Selection is by row number in AppKit and by song in SwiftUI. Selected songs hidden by a
        /// search stay in the binding, so they're selected again when the search is cleared.
        private func applySelection() {
            guard let table else { return }
            let wanted = parent.selection
            var indexes = IndexSet()
            if !wanted.isEmpty {
                for (i, t) in rows.enumerated() where wanted.contains(t.id) { indexes.insert(i) }
            }
            if indexes != table.selectedRowIndexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        }

        /// Hearts and the bold title can change while the rows stay the same.
        private func refreshVisibleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for column in [TrackSortField.favorite, .title] {
                let c = table.column(withIdentifier: column.identifier)
                guard c >= 0 else { continue }
                for row in visible.lowerBound..<visible.upperBound where rows.indices.contains(row) {
                    if let cell = table.view(atColumn: c, row: row, makeIfNecessary: false) as? TrackCell {
                        configure(cell, column, rows[row])
                    }
                }
            }
        }

        private func configure(_ cell: TrackCell, _ field: TrackSortField, _ t: Track) {
            switch field {
            case .favorite:
                let live = parent.liveTrack(t.relPath) ?? t
                cell.showHeart(live.favorite) { [weak self] in self?.parent.onToggleFavorite(self?.parent.liveTrack(t.relPath) ?? t) }
            case .title:
                cell.show(t.title, style: parent.currentPath == t.relPath ? .bold : .plain, label: field.header)
            default:
                cell.show(field.text(for: t), style: field.isNumeric ? .digits : .plain, label: field.header)
            }
        }

        // MARK: data source & delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let field = TrackSortField(rawValue: id.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TrackCell ?? TrackCell(identifier: id)
            configure(cell, field, rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying else { return }
            let order: [KeyPathComparator<Track>] = tableView.sortDescriptors.compactMap { d in
                d.key.flatMap(TrackSortField.init(rawValue:))?.comparator(order: d.ascending ? .forward : .reverse)
            }
            appliedSort = order.serialize()
            parent.sortOrder = order
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            if tableColumn.identifier == TrackSortField.favorite.identifier { parent.onFavoriteHeaderClicked() }
        }

        // MARK: actions

        @objc func doubleClicked() {
            guard let row = table?.clickedRow, rows.indices.contains(row) else { return }
            parent.onPlay(rows[row])
        }

        func playSelected() {
            guard let row = table?.selectedRowIndexes.first, rows.indices.contains(row) else { return }
            parent.onPlay(rows[row])
        }

        func heartClicked(row: Int) {
            guard rows.indices.contains(row) else { return }
            parent.onToggleFavorite(parent.liveTrack(rows[row].relPath) ?? rows[row])
        }

        // MARK: menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === headerMenu {
                TrackColumnLayout.fillHeaderMenu(menu, table: table)
            } else if rows.indices.contains(table.clickedRow) {
                let clicked = table.clickedRow
                let ids: Set<Track.ID> = table.selectedRowIndexes.contains(clicked)
                    ? Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
                    : [rows[clicked].id]
                parent.menuItems(ids).forEach(menu.addItem)
            }
        }
    }
}

/// `TrackTableView`'s table: handles what SwiftUI's `Table` used to route for us.
final class TrackNSTableView: NSTableView {
    var onHeartClick: ((Int) -> Void)?
    var onPlayKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onTypeToSearch: ((Character) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = row(at: p), col = column(at: p)
        // A click on a heart toggles it without changing the selection.
        if row >= 0, col >= 0, tableColumns[col].identifier == TrackSortField.favorite.identifier {
            onHeartClick?(row)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 36, 76 where mods.isEmpty:   // Return, Enter
            onPlayKey?()
            return
        case 51 where mods.isEmpty:   // Delete
            onDeleteKey?()
            return
        default: break
        }
        // Typing a letter or digit in the list starts a search.
        if mods.isEmpty || mods == .shift, let s = event.characters, s.count == 1, let ch = s.first, ch.isLetter || ch.isNumber {
            onTypeToSearch?(ch)
            return
        }
        super.keyDown(with: event)
    }
}

/// One cell. Draws its own text or heart: fewer views per row is most of what makes reloading cheap.
final class TrackCell: NSTableCellView {
    enum Style { case plain, bold, digits }

    private var text = ""
    private var style = Style.plain
    private var heart: Bool?
    private var label = ""
    private var onPress: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, style: Style, label: String) {
        self.label = label
        guard text != self.text || style != self.style || heart != nil else { return }
        self.text = text; self.style = style; heart = nil; onPress = nil
        needsDisplay = true
    }

    func showHeart(_ favorite: Bool, onPress: @escaping () -> Void) {
        self.onPress = onPress
        guard heart != favorite else { return }
        heart = favorite
        needsDisplay = true
    }

    /// Set by the row view: white text and icons on the blue of a selected row.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { if backgroundStyle != oldValue { needsDisplay = true } } }

    private var selected: Bool { backgroundStyle == .emphasized }

    override func draw(_ dirtyRect: NSRect) {
        if let heart {
            let image = heart ? Self.heartOn : selected ? Self.heartOffSelected : Self.heartOff
            let s = image.size
            image.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            return
        }
        guard !text.isEmpty else { return }
        let font = Self.font(style)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let rect = NSRect(x: 2, y: floor((bounds.height - lineHeight) / 2), width: max(bounds.width - 4, 0), height: lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .paragraphStyle: Self.truncating,
                                             .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor])
    }

    // Drawing text isn't visible to VoiceOver, so describe the cell by hand.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { heart == nil ? .staticText : .button }
    override func accessibilityLabel() -> String? { heart.map { $0 ? "Remove from favorites" : "Add to favorites" } ?? label }
    override func accessibilityValue() -> Any? { heart == nil ? text : nil }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    private static let plainFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    private static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static func font(_ style: Style) -> NSFont {
        switch style { case .plain: plainFont; case .bold: boldFont; case .digits: digitsFont }
    }
    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
    private static func heartImage(_ name: String, _ color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    }
    private static let heartOn = heartImage("heart.fill", .systemPink)
    private static let heartOff = heartImage("heart", .secondaryLabelColor)
    private static let heartOffSelected = heartImage("heart", .alternateSelectedControlTextColor)
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension TrackSortField {
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    var header: String {
        switch self {
        case .favorite: "♥"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .time: "Time"
        case .plays: "Plays"
        case .format: "Format"
        case .favorited: "Favorited"
        case .added: "Added"
        case .lastPlayed: "Last played"
        }
    }

    /// nil: the column shares the free space and the user can resize it.
    var fixedWidth: CGFloat? {
        switch self {
        case .favorite: 22
        case .time: 55
        case .plays: 45
        case .format: 50
        case .favorited, .added, .lastPlayed: 90
        case .title, .artist, .album: nil
        }
    }

    var isNumeric: Bool {
        switch self {
        case .time, .plays, .favorited, .added, .lastPlayed: true
        default: false
        }
    }

    @MainActor func text(for t: Track) -> String {
        switch self {
        case .favorite: ""
        case .title: t.title
        case .artist: t.displayArtist
        case .album: t.displayAlbum
        case .time: (t.duration ?? 0).durationString
        case .plays: String(t.playCount)
        case .format: t.fileExtension
        case .favorited: t.favorite && (t.favoriteAt ?? 0) > 0 ? FastDateFormatter.string(from: t.favoriteAt ?? 0) : ""
        case .added: FastDateFormatter.string(from: t.addedAt)
        case .lastPlayed: FastDateFormatter.string(from: t.lastPlayed ?? 0)
        }
    }

    func makeColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = header
        if let w = fixedWidth {
            column.width = w
            column.minWidth = w
            column.maxWidth = w
            column.resizingMask = []
        } else {
            column.width = 220
            column.minWidth = 60
            column.resizingMask = [.autoresizingMask, .userResizingMask]
        }
        if self != .favorite { column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: true) }
        return column
    }
}

/// Column order, widths and hidden columns, remembered across launches by `NSTableView` itself.
enum TrackColumnLayout {
    private static let autosaveName = "TrackTable"
    /// Where SwiftUI's `Table` kept these. Only read, and only once.
    private static let legacyKey = "mac.trackTableColumns"
    private static let migratedKey = "mac.trackTableColumnsMigrated"

    static func applySavedLayout(to table: NSTableView) {
        table.autosaveName = autosaveName
        table.autosaveTableColumns = true   // first: restores the saved layout and saves what follows
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            UserDefaults.standard.set(true, forKey: migratedKey)
            applyLegacyLayout(to: table)
        }
    }

    /// `TableColumnCustomization` stores `[id, state, id, state…]` as JSON.
    private static func applyLegacyLayout(to table: NSTableView) {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["perColumnState"] as? [[String: Any]] else { return }
        for i in stride(from: 0, to: entries.count - 1, by: 2) {
            guard let base = entries[i]["base"] as? [String: Any],
                  let explicit = base["explicit"] as? [String: Any],
                  let id = explicit["_0"] as? String,
                  let column = table.tableColumn(withIdentifier: .init(id)) else { continue }
            let state = entries[i + 1]
            if let visibility = state["visibility"] as? [String: Any], visibility["hidden"] != nil { column.isHidden = true }
            if let width = state["currentWidth"] as? Double, TrackSortField(rawValue: id)?.fixedWidth == nil { column.width = width }
        }
    }

    /// Right-clicking a header shows or hides columns.
    @MainActor static func fillHeaderMenu(_ menu: NSMenu, table: NSTableView) {
        let shown = table.tableColumns.filter { !$0.isHidden }.count
        for field in TrackSortField.allCases {
            guard let column = table.tableColumn(withIdentifier: field.identifier) else { continue }
            let item = ClosureMenuItem(field.header) { column.isHidden.toggle() }
            item.state = column.isHidden ? .off : .on
            item.isEnabled = column.isHidden || shown > 1   // keep at least one column
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }
}

/// Lets a song list hand typed letters to the toolbar search field (see `ContentView`).
private struct TypeToSearchKey: EnvironmentKey {
    static let defaultValue: (Character) -> Void = { _ in }
}

extension EnvironmentValues {
    var typeToSearch: (Character) -> Void {
        get { self[TypeToSearchKey.self] }
        set { self[TypeToSearchKey.self] = newValue }
    }
}
