// 도구함 — 내가 만든 앱들을 카테고리별로 모아 각자 따로 실행하는 런처
import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

let defaultApps = ["local.jaeyeong.excelruler", "com.jaeyeong.listcalendartodo"]

struct Category: Codable {
    var name: String
    var ids: [String]
}

// MARK: - 작은 도우미

/// 클로저로 동작하는 버튼
final class ActionButton: NSButton {
    private var handler: ((ActionButton) -> Void)?
    convenience init(title: String, symbol: String?, _ action: @escaping (ActionButton) -> Void) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        bezelStyle = .rounded
        handler = action
        target = self
        self.action = #selector(run)
        sizeToFit()
    }
    @objc private func run() { handler?(self) }
}

final class Item: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", _ action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

func headerItem(_ t: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: t) }
    let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

func popUp(_ menu: NSMenu, under view: NSView) {
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
}

// MARK: - 앱 하나를 나타내는 칸

final class Tile: NSView {
    static func size(icon: CGFloat) -> NSSize {
        NSSize(width: max(icon + 32, 76), height: icon + 42)
    }

    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private let editing: Bool

    init(name: String, icon: NSImage, iconSize: CGFloat, running: Bool, found: Bool,
         editing: Bool, menu m: NSMenu?, onRemove: (() -> Void)?) {
        self.editing = editing
        let s = Tile.size(icon: iconSize)
        super.init(frame: NSRect(origin: .zero, size: s))
        menu = m
        toolTip = found ? (running ? "\(name) — 실행 중 (클릭하면 앞으로)" : "\(name) — 클릭해서 실행")
                        : "\(name) — 앱을 찾을 수 없음"

        // 칸 안쪽은 아래에서 위로: 초록 점 → 이름 → 아이콘
        let iv = NSImageView(frame: NSRect(x: (s.width - iconSize) / 2, y: 30, width: iconSize, height: iconSize))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        if !found { iv.alphaValue = 0.35 }
        addSubview(iv)

        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: 2, y: 10, width: s.width - 4, height: 16)
        label.alignment = .center
        label.font = .systemFont(ofSize: iconSize < 40 ? 10 : 12)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if running {
            let dot = NSView(frame: NSRect(x: s.width / 2 - 3, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
        }

        // 편집 모드: 왼쪽 위에 빨간 ⊖ 버튼
        if editing, let onRemove {
            let b = ActionButton(title: "", symbol: "minus.circle.fill") { _ in onRemove() }
            b.isBordered = false
            b.contentTintColor = .systemRed
            b.symbolConfiguration = .init(pointSize: 18, weight: .bold)
            b.toolTip = "런처에서 빼기"
            b.frame = NSRect(x: iv.frame.minX - 10, y: iv.frame.maxY - 14, width: 24, height: 24)
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    /// 위젯을 끌어 옮길 때 앱 아이콘 위에서 누르면 창이 아니라 클릭으로 처리
    override var mouseDownCanMoveWindow: Bool { false }

    // 클릭은 실행, 조금 끌면 아이콘을 다른 자리·카테고리로 옮기기
    var appID = ""
    private var downPoint: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = downPoint, !appID.isEmpty else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragged = true
        hovering = false
        let item = NSPasteboardItem()
        item.setString(appID, forType: .launcherApp)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [di], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, !editing else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        if !editing, !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

extension Tile: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

extension NSPasteboard.PasteboardType {
    static let launcherApp = NSPasteboard.PasteboardType("local.jaeyeong.launcher.app")
}

/// 끌어다 놓을 자리: 어느 카테고리의 몇 번째에 들어갈지 + 화면에 그릴 위치
struct DropTarget {
    var cat: Int
    var index: Int
    var section: NSRect
    var caret: NSRect
}

/// 아이콘 격자. 위에서 아래로 쌓이도록 좌표를 뒤집음.
/// 앱 아이콘을 끌어 다른 자리·카테고리로 옮기거나, Finder에서 .app 을 끌어다 놓으면 추가
final class GridView: NSView {
    override var isFlipped: Bool { true }
    var target: ((NSPoint) -> DropTarget?)?
    var onDropApps: (([URL], DropTarget) -> Void)?
    var onMoveApp: ((String, DropTarget) -> Void)?
    private var current: DropTarget? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .launcherApp])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func appURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }
    }
    private func movingID(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .launcherApp)
    }
    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let isMove = movingID(info) != nil
        guard isMove || !appURLs(info).isEmpty else { current = nil; return [] }
        current = target?(convert(info.draggingLocation, from: nil))
        return current == nil ? [] : (isMove ? .move : .copy)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { current = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { current = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let t = target?(convert(sender.draggingLocation, from: nil)) else { current = nil; return false }
        current = nil
        if let id = movingID(sender) {
            // 화면을 다시 그리는 건 끌기가 완전히 끝난 다음에
            DispatchQueue.main.async { self.onMoveApp?(id, t) }
            return true
        }
        let urls = appURLs(sender)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDropApps?(urls, t) }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let t = current else { return }
        // 들어갈 카테고리 영역은 옅게, 들어갈 자리는 세로 막대로
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        let p = NSBezierPath(roundedRect: t.section, xRadius: 10, yRadius: 10)
        p.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        p.lineWidth = 1.5
        p.stroke()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: t.caret, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// 위젯 모드 창: 제목 막대가 없어도 키 입력(이름 입력 등)을 받을 수 있게
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 둥근 모서리 마스크 (위젯 카드 모양)
func roundedMask(_ r: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

/// 위젯 높이: 0 바탕화면(다른 창 뒤) · 1 일반 창처럼 · 2 항상 위
let widgetLevels: [(String, NSWindow.Level)] = [
    ("바탕화면에 붙이기 (다른 창 뒤)", NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)),
    ("일반 창처럼", .normal),
    ("항상 위에", .floating),
]

/// 카테고리 제목 줄 (이름 + 구분선). 우클릭하면 카테고리 메뉴
final class HeaderView: NSView {
    var onClick: (() -> Void)?

    init(frame: NSRect, title: String, count: Int, menu m: NSMenu, lineStart: CGFloat, folded: Bool? = nil) {
        super.init(frame: frame)
        menu = m
        var x = lineStart
        // 접을 수 있는 카테고리면 ▸ / ▾ 표시
        if let folded {
            let chev = NSImageView(frame: NSRect(x: x - 2, y: (frame.height - 12) / 2, width: 12, height: 12))
            chev.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            chev.symbolConfiguration = .init(pointSize: 10, weight: .bold)
            chev.contentTintColor = .secondaryLabelColor
            addSubview(chev)
            x += 14
        }
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.sizeToFit()
        l.setFrameOrigin(NSPoint(x: x, y: (frame.height - l.frame.height) / 2))
        addSubview(l)
        let c = NSTextField(labelWithString: "\(count)")
        c.font = .systemFont(ofSize: 11)
        c.textColor = .tertiaryLabelColor
        c.sizeToFit()
        c.setFrameOrigin(NSPoint(x: l.frame.maxX + 6, y: (frame.height - c.frame.height) / 2))
        addSubview(c)
        let lineX = c.frame.maxX + 8
        let line = NSBox(frame: NSRect(x: lineX, y: frame.height / 2, width: max(0, frame.width - lineStart - lineX), height: 1))
        line.boxType = .separator
        addSubview(line)
        toolTip = folded == nil ? "우클릭: 이름 바꾸기 · 순서 · 삭제 · 여기에 앱 추가"
                                : "클릭: 접기/펼치기 · 우클릭: 이름 바꾸기 · 순서 · 삭제 · 여기에 앱 추가"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { onClick == nil }
    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - 앱

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let d = UserDefaults.standard
    var cats: [Category] = []
    var cols = 4
    var rows = 1
    var iconSize: CGFloat = 64
    var editing = false
    var widget = false
    var widgetLevel = 0
    var locked = false
    /// 드롭 위치로 카테고리를 찾기 위한 각 카테고리의 세로 범위
    var sectionYs: [(cat: Int, top: CGFloat, tilesTop: CGFloat, bottom: CGFloat)] = []

    var window: NSWindow!
    var statusItem: NSStatusItem!
    var settings: NSPanel?
    var colsField: NSTextField!, rowsField: NSTextField!
    var colsStepper: NSStepper!, rowsStepper: NSStepper!
    var sizeSlider: NSSlider!, sizeLabel: NSTextField!
    var widgetCheck: NSButton!
    var dockCheck: NSButton!
    var hideDock = false
    // 검색 · 위쪽 줄 (창을 다시 그려도 검색칸은 그대로 유지해 입력이 끊기지 않게)
    var query = ""
    var root: NSView?
    lazy var searchField: NSSearchField = {
        let f = NSSearchField(frame: .zero)
        f.placeholderString = "앱 찾기"
        f.delegate = self
        f.sendsSearchStringImmediately = true
        f.focusRingType = .none
        return f
    }()
    lazy var finderButton: ActionButton = {
        let b = ActionButton(title: "Finder", symbol: nil) { [unowned self] _ in launch("com.apple.finder") }
        let img = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        img.size = NSSize(width: 16, height: 16)
        b.image = img
        b.imagePosition = .imageLeading
        b.toolTip = "Finder 열기"
        b.sizeToFit()
        return b
    }()
    // 앱 목록 접기 (전체 / 카테고리별)
    var listCollapsed = false
    var foldedCats: Set<String> = []
    lazy var collapseButton: ActionButton = {
        let b = ActionButton(title: "", symbol: "chevron.up") { [unowned self] _ in
            listCollapsed.toggle()
            d.set(listCollapsed, forKey: "listCollapsed")
            refresh()
        }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var bulkButton: ActionButton = {
        let b = ActionButton(title: "", symbol: "rectangle.stack.badge.minus") { b in popUp(BulkWindows.menu(), under: b) }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.toolTip = "열린 창 모두 닫기 · 최소화 · 앱 모두 종료"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var topBar: NSView = {
        let v = NSView(frame: .zero)
        v.addSubview(searchField)
        v.addSubview(finderButton)
        v.addSubview(collapseButton)
        v.addSubview(bulkButton)
        return v
    }()
    var installed: [(id: String, name: String)]?
    // YouTube Music 미니 플레이어
    var playerEnabled = true
    var playerCheck: NSButton!
    let playerH: CGFloat = PlayerBar.height
    var lastSong = ""
    lazy var music: YTMusic = {
        let m = YTMusic()
        m.onFoundChange = { [unowned self] in refresh() }
        m.onUpdate = { [unowned self] st, art in
            playerBar.update(st, art: art)
            lyrics.playerUpdated(st)
            if d.bool(forKey: "ytmDebug") {   // 진단용: 읽은 상태를 파일로
                let line = "title=\(st.title) | byline=\(st.byline) | time=\(st.time) | pos=\(st.position)/\(st.duration) | playing=\(String(describing: st.playing)) | like=\(st.liked) | repeat=\(st.repeatLabel) | vol=\(st.volume) | muted=\(st.muted) | page=\(st.pageOpen) | art=\(art != nil) | artURL=\(st.artURL)\n"
                try? line.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-status.txt", atomically: true, encoding: .utf8)
            }
            // 곡이 바뀌면 메뉴바 메뉴의 곡 제목도 새로
            if st.title != lastSong { lastSong = st.title; buildStatusMenu() }
        }
        return m
    }()
    lazy var lyrics: LyricsController = {
        let c = LyricsController(music: music)
        c.model.onStripToggle = { [unowned self] in refresh() }   // 가사 줄 펼치기/접기 → 창 높이 다시
        return c
    }()
    lazy var playerBar: PlayerBar = {
        let b = PlayerBar(music: music)
        b.onLyrics = { [unowned self] in lyrics.toggle() }
        return b
    }()
    var showPlayer: Bool { playerEnabled && music.isActive }
    let topH: CGFloat = 40

    let pad: CGFloat = 14, gap: CGFloat = 4, barH: CGFloat = 44, headerH: CGFloat = 28, sectionGap: CGFloat = 10

    func applicationDidFinishLaunching(_ n: Notification) {
        if let data = d.data(forKey: "categories"), let c = try? JSONDecoder().decode([Category].self, from: data), !c.isEmpty {
            cats = c
        } else {
            // 예전 버전(카테고리 없음)에서 넘어오면 전부 "기본" 카테고리로
            cats = [Category(name: "기본", ids: d.stringArray(forKey: "apps") ?? defaultApps)]
        }
        if d.object(forKey: "cols") != nil {
            cols = max(1, d.integer(forKey: "cols"))
            rows = max(1, d.integer(forKey: "rows"))
            iconSize = CGFloat(d.double(forKey: "iconSize"))
        }
        widget = d.bool(forKey: "widget")
        widgetLevel = min(d.integer(forKey: "widgetLevel"), widgetLevels.count - 1)
        locked = d.bool(forKey: "locked")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧰"

        // 앱이 켜지거나 꺼지면 초록 점을 바로 갱신
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }

        makeWindow()

        if d.object(forKey: "player") != nil { playerEnabled = d.bool(forKey: "player") }
        listCollapsed = d.bool(forKey: "listCollapsed")
        foldedCats = Set(d.stringArray(forKey: "foldedCats") ?? [])
        if playerEnabled { music.start(); lyrics.start() }
        hideDock = d.bool(forKey: "hideDock")
        if hideDock {
            applyDockHiding()
        } else {
            restoreDock()   // 지난번에 비정상 종료돼 못 되돌린 경우
        }
        buildStatusMenu()
    }

    // MARK: 창 / 위젯 모드

    /// 모드에 맞는 창을 새로 만든다. 일반 창과 위젯은 각자 마지막 위치를 따로 기억
    func makeWindow() {
        // 모드를 바꿀 때는 새 창을 직전 창의 왼쪽 위 자리에 띄움 (위젯이 엉뚱한 모니터에 뜨지 않게)
        var carryTopLeft: NSPoint?
        if let old = window {
            carryTopLeft = NSPoint(x: old.frame.minX, y: old.frame.maxY)
            old.setFrameAutosaveName("")
            old.orderOut(nil)
        }
        let autosave = "LauncherWindow"
        let firstRun = carryTopLeft == nil && d.string(forKey: "NSWindow Frame \(autosave)") == nil
        let rect = NSRect(x: 0, y: 0, width: 300, height: 150)
        let w: NSWindow
        if widget {
            w = WidgetWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false   // 그림자를 켜면 가장자리에 검은 테두리 선이 생김
            w.isMovableByWindowBackground = !locked
            w.isMovable = !locked
            w.level = widgetLevels[widgetLevel].1
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        } else {
            w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
            w.title = "도구함"
        }
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(autosave)
        window = w
        topBar.removeFromSuperview()
        root = nil

        // 위젯은 Dock 에 안 보이게, 일반 창은 Dock 에 보이게
        NSApp.setActivationPolicy(widget ? .accessory : .regular)
        refresh()
        if let p = carryTopLeft {
            w.setFrameTopLeftPoint(p)
        } else if firstRun {
            w.center()
        }
        if widget { w.orderFrontRegardless() } else { showWindow() }
    }

    func setWidget(_ on: Bool) {
        widget = on
        editing = false
        d.set(widget, forKey: "widget")
        makeWindow()
        if settings != nil { syncSettings() }
    }

    @objc func toggleWidgetAction() { setWidget(!widget) }

    func setWidgetLevel(_ l: Int) {
        widgetLevel = l
        d.set(l, forKey: "widgetLevel")
        window.level = widgetLevels[l].1
        window.orderFrontRegardless()
        buildStatusMenu()
    }

    func toggleLocked() {
        locked.toggle()
        d.set(locked, forKey: "locked")
        window.isMovableByWindowBackground = !locked
        window.isMovable = !locked
        buildStatusMenu()
    }

    /// 위젯 관련 메뉴 항목들 (메뉴바 메뉴와 위젯 우클릭 메뉴에서 같이 씀)
    func widgetItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let toggle = Item(widget ? "위젯 모드 끄기 (일반 창으로)" : "위젯 모드로 바꾸기") { [unowned self] in setWidget(!widget) }
        items.append(toggle)
        if widget {
            for (i, l) in widgetLevels.enumerated() {
                let it = Item("    " + l.0) { [unowned self] in setWidgetLevel(i) }
                it.state = i == widgetLevel ? .on : .off
                items.append(it)
            }
            let lock = Item("    위치 고정") { [unowned self] in toggleLocked() }
            lock.state = locked ? .on : .off
            items.append(lock)
        }
        return items
    }

    /// 위젯 빈 곳을 우클릭했을 때 나오는 메뉴 (위젯엔 아래 버튼 줄이 없으므로)
    func backgroundMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        if cats.count == 1 {
            m.addItem(Item("앱 추가…") { [unowned self] in addApp(to: 0) })
        } else {
            let add = NSMenuItem(title: "앱 추가", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (c, cat) in cats.enumerated() { sub.addItem(Item(cat.name) { [unowned self] in addApp(to: c) }) }
            add.submenu = sub
            m.addItem(add)
        }
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(Item(editing ? "빼기 끝내기" : "앱 빼기 (편집)") { [unowned self] in editing.toggle(); refresh() })
        let cat = NSMenuItem(title: "카테고리", action: nil, keyEquivalent: "")
        cat.submenu = categoriesMenu()
        m.addItem(cat)
        m.addItem(Item("설정…") { [unowned self] in openSettings() })
        let bulk = NSMenuItem(title: "창 정리", action: nil, keyEquivalent: "")
        bulk.submenu = BulkWindows.menu()
        m.addItem(bulk)
        m.addItem(.separator())
        widgetItems().forEach(m.addItem)
        return m
    }

    func categoriesMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(Item("새 카테고리…") { [unowned self] in newCategory() })
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(.separator())
        for (c, cat) in cats.enumerated() {
            let i = NSMenuItem(title: cat.name, action: nil, keyEquivalent: "")
            i.submenu = categoryMenu(c)
            m.addItem(i)
        }
        return m
    }

    // MARK: Dock 가리기 (도구함이 켜져 있는 동안만 Dock 자동 가리기)

    /// 시스템 Dock 의 "자동으로 가리기" 를 읽고/바꿈. 처음 한 번 macOS 가 System Events 제어 허용을 물어봄
    @discardableResult
    func dockAutohide(set value: Bool? = nil) -> Bool? {
        let src = value.map { "tell application \"System Events\" to set autohide of dock preferences to \($0)" }
            ?? "tell application \"System Events\" to get autohide of dock preferences"
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { return nil }
        return value ?? r?.booleanValue
    }

    func applyDockHiding() {
        guard hideDock else { return }
        // 원래 설정을 한 번만 기억해 두고(앱이 비정상 종료돼도 다음에 되돌릴 수 있게) 자동 가리기 켜기
        if d.object(forKey: "dockWasAutohide") == nil {
            guard let was = dockAutohide() else { dockPermissionFailed(); return }
            d.set(was, forKey: "dockWasAutohide")
        }
        if dockAutohide(set: true) == nil { dockPermissionFailed() }
    }

    func restoreDock() {
        guard d.object(forKey: "dockWasAutohide") != nil else { return }
        let was = d.bool(forKey: "dockWasAutohide")
        if !was { dockAutohide(set: false) }
        d.removeObject(forKey: "dockWasAutohide")
    }

    func dockPermissionFailed() {
        hideDock = false
        d.set(false, forKey: "hideDock")
        d.removeObject(forKey: "dockWasAutohide")
        if settings != nil { syncSettings() }
        buildStatusMenu()
        alert("Dock 을 가리지 못했어요.\n시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 ‘도구함’이 ‘System Events’를 제어하도록 허용한 뒤 다시 켜 주세요.")
    }

    func setHideDock(_ on: Bool) {
        hideDock = on
        d.set(on, forKey: "hideDock")
        if on { applyDockHiding() } else { restoreDock() }
        if settings != nil { syncSettings() }
        buildStatusMenu()
    }

    @objc func dockChecked(_ b: NSButton) { setHideDock(b.state == .on) }

    func setPlayer(_ on: Bool) {
        playerEnabled = on
        d.set(on, forKey: "player")
        if on {
            music.showWindow()     // 처음 켜면 YouTube Music 창을 열어 로그인할 수 있게
            lyrics.start()
        } else {
            music.stop()
            lyrics.stop()
        }
        refresh()
        if settings != nil { syncSettings() }
    }

    @objc func playerChecked(_ b: NSButton) { setPlayer(b.state == .on) }

    func applicationWillTerminate(_ notification: Notification) {
        if hideDock { restoreDock() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 앱 정보

    var allIds: [String] { cats.flatMap(\.ids) }
    func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
    func name(_ id: String) -> String {
        guard let u = url(id) else { return id }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    func icon(_ id: String) -> NSImage {
        if let u = url(id) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
    }
    func locate(_ id: String) -> (Int, Int)? {
        for (c, cat) in cats.enumerated() {
            if let i = cat.ids.firstIndex(of: id) { return (c, i) }
        }
        return nil
    }

    // MARK: 앱 동작

    /// Dock 아이콘 클릭과 같은 동작: 꺼져 있으면 실행, 켜져 있으면 "다시 열기" 신호를 보내
    /// 닫았거나 최소화·가린 창을 다시 보여 주고 앞으로 가져옴
    func launch(_ id: String) {
        let r = running(id)
        r?.unhide()
        guard let u = url(id) ?? r?.bundleURL else {
            alert("\(id) 앱을 찾을 수 없어요. 앱을 다시 설치하거나 런처에서 빼 주세요.")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: u, configuration: cfg) { [weak self] _, err in
            if let err { DispatchQueue.main.async { self?.alert("실행하지 못했어요: \(err.localizedDescription)") } }
        }
    }

    func quit(_ id: String) { running(id)?.terminate() }

    func remove(_ id: String) {
        guard let (c, i) = locate(id) else { return }
        cats[c].ids.remove(at: i)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let (c, i) = locate(id) else { return }
        let j = i + delta
        guard cats[c].ids.indices.contains(j) else { return }
        cats[c].ids.swapAt(i, j)
        save()
    }

    func moveApp(_ id: String, toCategory target: Int) {
        guard let (c, _) = locate(id), c != target else { return }
        moveApp(id, toCategory: target, at: cats[target].ids.count)
    }

    /// 끌어다 놓기: target 카테고리의 index 자리에 넣기 (같은 카테고리면 순서만 바뀜)
    func moveApp(_ id: String, toCategory target: Int, at index: Int) {
        guard let (c, i) = locate(id) else { return }
        var dest = index
        if c == target {
            if dest == i || dest == i + 1 { return }   // 제자리
            if i < dest { dest -= 1 }
        }
        cats[c].ids.remove(at: i)
        cats[target].ids.insert(id, at: min(max(0, dest), cats[target].ids.count))
        save()
    }

    /// 마우스 위치 → 어느 카테고리의 몇 번째 자리인지
    func dropTarget(at p: NSPoint, left: CGFloat, gridW: CGFloat, tile: NSSize) -> DropTarget? {
        guard !sectionYs.isEmpty else { return nil }
        let sec = sectionYs.first { p.y < $0.bottom + sectionGap / 2 } ?? sectionYs.last!
        let count = cats[sec.cat].ids.count
        let stepX = tile.width + gap, stepY = tile.height + gap
        let row = max(0, Int((p.y - sec.tilesTop) / stepY))
        let col = min(cols, max(0, Int(((p.x - left) / stepX).rounded())))
        let index = min(count, row * cols + col)
        // 막대 위치: 줄 오른쪽 끝에 놓을 땐 다음 줄 맨 앞 대신 그 줄 끝에 그림
        let atRowEnd = index > 0 && index % cols == 0 && (col == cols || index == count)
        let r = atRowEnd ? (index - 1) / cols : index / cols
        let cIn = atRowEnd ? cols : index % cols
        let caretX = left + CGFloat(cIn) * stepX - gap / 2 - 1.5
        let caret = NSRect(x: caretX, y: sec.tilesTop + CGFloat(r) * stepY + 4, width: 3, height: tile.height - 8)
        let section = NSRect(x: left - 8, y: sec.top - 2, width: gridW - pad * 2 + 16, height: sec.bottom - sec.top + 6)
        return DropTarget(cat: sec.cat, index: index, section: section, caret: caret)
    }

    func add(_ urls: [URL], to c: Int) {
        var skipped: [String] = []
        for u in urls {
            guard let id = Bundle(url: u)?.bundleIdentifier else { skipped.append(u.lastPathComponent); continue }
            if locate(id) == nil { cats[c].ids.append(id) }
        }
        save()
        if !skipped.isEmpty { alert("앱 정보를 읽지 못해 추가하지 못했어요: \(skipped.joined(separator: ", "))") }
    }

    func addApp(to c: Int) {
        let p = NSOpenPanel()
        p.title = "‘\(cats[c].name)’에 넣을 앱 고르기"
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        add(p.urls, to: c)
    }

    // MARK: 검색

    /// /Applications 등에 설치된 앱 목록 (처음 검색할 때 한 번 읽음)
    func installedApps() -> [(id: String, name: String)] {
        if let installed { return installed }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var list: [(String, String)] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = dir + "/" + item
                guard let id = Bundle(path: path)?.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                list.append((id, fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")))
            }
        }
        list.sort { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        installed = list
        return list
    }

    func matches(_ id: String, _ q: String) -> Bool {
        name(id).localizedCaseInsensitiveContains(q) || id.localizedCaseInsensitiveContains(q)
    }

    /// 화면에 보여 줄 묶음들. 검색 중이면 "도구함에서" + "설치된 앱"
    func displaySections() -> [(title: String, cat: Int?, ids: [String])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return cats.enumerated().map { ($0.element.name, $0.offset, $0.element.ids) } }
        let mine = allIds.filter { matches($0, q) }
        let others = installedApps().filter { locate($0.id) == nil && ($0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)) }
            .prefix(40).map(\.id)
        var out: [(String, Int?, [String])] = [("도구함에서", nil, mine)]
        if !others.isEmpty { out.append(("설치된 앱", nil, Array(others))) }
        return out
    }

    func installedTileMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.addItem(Item("실행") { [unowned self] in launch(id) })
        let addTo = NSMenuItem(title: "도구함에 넣기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (c, cat) in cats.enumerated() {
            sub.addItem(Item(cat.name) { [unowned self] in
                if let u = url(id) { add([u], to: c) }
            })
        }
        addTo.submenu = sub
        m.addItem(addTo)
        if let u = url(id) {
            m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        return m
    }

    // MARK: Dock 앱 가져오기

    /// Dock 에 고정된 앱들의 번들 ID (Dock 순서 그대로)
    func dockAppIDs() -> [String] {
        guard let items = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
                as? [[String: Any]] else { return [] }
        var result: [String] = []
        for item in items {
            guard let tile = item["tile-data"] as? [String: Any] else { continue }
            var id = tile["bundle-identifier"] as? String
            if id == nil, let file = tile["file-data"] as? [String: Any],
               let str = file["_CFURLString"] as? String, let u = URL(string: str) {
                id = Bundle(url: u)?.bundleIdentifier
            }
            if let id, !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// Dock 앱들을 "Dock" 카테고리에 넣기. 이미 런처에 있는 앱은 건너뜀 (여러 번 눌러도 새로 생긴 것만 추가)
    func importDock() {
        let dock = dockAppIDs()
        guard !dock.isEmpty else { alert("Dock 앱 목록을 읽지 못했어요."); return }
        let c: Int
        if let i = cats.firstIndex(where: { $0.name == "Dock" }) {
            c = i
        } else {
            cats.append(Category(name: "Dock", ids: []))
            c = cats.count - 1
        }
        var added = 0, skipped = 0
        for id in dock {
            if locate(id) != nil { skipped += 1 } else { cats[c].ids.append(id); added += 1 }
        }
        if cats[c].ids.isEmpty && added == 0 { cats.remove(at: c) }
        save()
        alert("Dock 앱 \(added)개를 ‘Dock’ 카테고리에 넣었어요." + (skipped > 0 ? "\n이미 런처에 있던 \(skipped)개는 건너뛰었어요." : ""))
    }

    // MARK: 카테고리 동작

    func newCategory(thenMove id: String? = nil) {
        guard let n = ask("새 카테고리 이름", value: "") else { return }
        cats.append(Category(name: n, ids: []))
        if let id { moveApp(id, toCategory: cats.count - 1) } else { save() }
    }

    func renameCategory(_ c: Int) {
        guard let n = ask("카테고리 이름 바꾸기", value: cats[c].name) else { return }
        if foldedCats.remove(cats[c].name) != nil {   // 접어 둔 상태는 새 이름으로 옮김
            foldedCats.insert(n)
            d.set(Array(foldedCats), forKey: "foldedCats")
        }
        cats[c].name = n
        save()
    }

    func moveCategory(_ c: Int, by delta: Int) {
        let j = c + delta
        guard cats.indices.contains(j) else { return }
        cats.swapAt(c, j)
        save()
    }

    func deleteCategory(_ c: Int) {
        guard cats.count > 1 else { alert("카테고리는 최소 하나는 있어야 해요."); return }
        let dest = c == 0 ? 1 : c - 1
        if !cats[c].ids.isEmpty {
            let a = NSAlert()
            a.messageText = "‘\(cats[c].name)’ 카테고리를 삭제할까요?"
            a.informativeText = "안에 있는 앱 \(cats[c].ids.count)개는 ‘\(cats[dest].name)’로 옮겨져요. 앱 자체는 지워지지 않아요."
            a.addButton(withTitle: "삭제")
            a.addButton(withTitle: "취소")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        cats[dest].ids.append(contentsOf: cats[c].ids)
        cats.remove(at: c)
        save()
    }

    func categoryMenu(_ c: Int) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(Item("여기에 앱 추가…") { [unowned self] in addApp(to: c) })
        m.addItem(Item("이름 바꾸기…") { [unowned self] in renameCategory(c) })
        m.addItem(.separator())
        let up = Item("위로 옮기기") { [unowned self] in moveCategory(c, by: -1) }
        up.isEnabled = c > 0
        m.addItem(up)
        let down = Item("아래로 옮기기") { [unowned self] in moveCategory(c, by: 1) }
        down.isEnabled = c < cats.count - 1
        m.addItem(down)
        m.addItem(.separator())
        let del = Item("카테고리 삭제…") { [unowned self] in deleteCategory(c) }
        del.isEnabled = cats.count > 1
        m.addItem(del)
        return m
    }

    // MARK: 저장 · 알림

    func save() {
        if let data = try? JSONEncoder().encode(cats) { d.set(data, forKey: "categories") }
        d.set(cols, forKey: "cols")
        d.set(rows, forKey: "rows")
        d.set(Double(iconSize), forKey: "iconSize")
        refresh()
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = msg
        a.runModal()
    }

    func ask(_ title: String, value: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = value
        f.placeholderString = "예: 업무, 개인, 개발"
        a.accessoryView = f
        a.addButton(withTitle: "확인")
        a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let t = f.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: 로그인 시 자동 실행

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            alert("로그인 항목을 바꾸지 못했어요: \(error.localizedDescription)\n시스템 설정 → 일반 → 로그인 항목에서 직접 추가할 수 있어요.")
        }
        refresh()
    }

    // MARK: 메인 창 그리기

    /// 앱 아이콘 우클릭: Dock 처럼 [열린 창들 · 새 창 · 앱 메뉴] + [도구함 정리] + [가리기 · 종료]
    func tileMenu(_ id: String) -> NSMenu {
        LiveMenu { [unowned self] m in
            let r = running(id)
            if let r { fillAppMenu(m, pid: r.processIdentifier) }
            else { m.addItem(Item("열기") { [unowned self] in launch(id) }); m.addItem(.separator()) }

            let tools = NSMenuItem(title: "도구함", action: nil, keyEquivalent: "")
            tools.submenu = launcherMenu(id)
            m.addItem(tools)
            if let u = url(id) {
                m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
            }
            if let r {
                m.addItem(.separator())
                m.addItem(Item(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
                m.addItem(Item("종료") { r.terminate() })
            }
        }
    }

    /// 도구함 안에서의 정리 (카테고리 · 순서 · 빼기)
    func launcherMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let moveTo = NSMenuItem(title: "카테고리 옮기기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let here = locate(id)?.0
        for (c, cat) in cats.enumerated() {
            let i = Item(cat.name) { [unowned self] in moveApp(id, toCategory: c) }
            i.state = c == here ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(Item("새 카테고리…") { [unowned self] in newCategory(thenMove: id) })
        moveTo.submenu = sub
        m.addItem(moveTo)
        m.addItem(Item("앞으로 옮기기") { [unowned self] in move(id, by: -1) })
        m.addItem(Item("뒤로 옮기기") { [unowned self] in move(id, by: 1) })
        m.addItem(.separator())
        m.addItem(Item("런처에서 빼기") { [unowned self] in remove(id) })
        return m
    }

    func refresh() {
        let tile = Tile.size(icon: iconSize)
        let gridW = pad * 2 + CGFloat(cols) * tile.width + CGFloat(cols - 1) * gap
        // 위젯에선 아래 버튼 줄을 숨기고(빼기 편집 중일 때만 보임) 우클릭 메뉴로 대신함
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // 전체 접기: 검색 중이 아니면 앱 목록과 아래 버튼 줄을 숨겨 검색 줄 + 플레이어만
        let allFolded = listCollapsed && !searching && !editing
        let showBar = (!widget || editing) && !allFolded
        let bottom = showBar ? barH : 0
        let w = max(gridW, (showBar || allFolded) ? 340 : 0)
        let left = (w - gridW) / 2 + pad
        let sections = allFolded ? [] : displaySections()
        let showHeaders = searching || cats.count > 1

        // 1) 카테고리마다: 제목 줄 → 열 × 행 격자(앱이 많으면 행이 늘어남)
        var views: [NSView] = []
        sectionYs = []
        var y = pad
        for sec in sections {
            let top = y
            let foldable = showHeaders && !searching && sec.cat != nil
            let folded = foldable && foldedCats.contains(sec.title)
            if showHeaders {
                let hm = sec.cat.map { categoryMenu($0) } ?? NSMenu()
                let hv = HeaderView(frame: NSRect(x: 0, y: y, width: w, height: headerH),
                                    title: sec.title, count: sec.ids.count,
                                    menu: hm, lineStart: left, folded: foldable ? folded : nil)
                if foldable {
                    let name = sec.title
                    hv.onClick = { [unowned self] in
                        if foldedCats.contains(name) { foldedCats.remove(name) } else { foldedCats.insert(name) }
                        d.set(Array(foldedCats), forKey: "foldedCats")
                        refresh()
                    }
                }
                views.append(hv)
                y += headerH
            }
            let tilesTop = y
            if folded {
                // 접힌 카테고리: 제목 줄만
                if let c = sec.cat { sectionYs.append((c, top, tilesTop, y)) }
                y += sectionGap
                continue
            }
            let minRows = searching ? 1 : rows
            let catRows = max(minRows, Int(ceil(Double(sec.ids.count) / Double(cols))))
            for (i, id) in sec.ids.enumerated() {
                let mine = locate(id) != nil
                let t = Tile(name: name(id), icon: icon(id), iconSize: iconSize,
                             running: running(id) != nil, found: url(id) != nil,
                             editing: editing && mine, menu: mine ? tileMenu(id) : installedTileMenu(id),
                             onRemove: { [unowned self] in remove(id) })
                // GridView 는 위→아래 좌표라 칸의 위쪽 모서리 기준으로 놓음
                t.setFrameOrigin(NSPoint(x: left + CGFloat(i % cols) * (tile.width + gap),
                                         y: y + CGFloat(i / cols) * (tile.height + gap)))
                t.onClick = { [unowned self] in launch(id) }
                t.appID = (mine && !searching) ? id : ""   // 검색 결과에선 끌어 옮기기 안 함
                views.append(t)
            }
            if sec.ids.isEmpty {
                let hint = NSTextField(labelWithString: searching ? "‘\(query)’와 맞는 앱이 없어요" : "비어 있음 — 다른 카테고리의 앱을 여기로 끌어다 놓으세요")
                hint.font = .systemFont(ofSize: 11)
                hint.textColor = .tertiaryLabelColor
                hint.frame = NSRect(x: left, y: y + tile.height / 2 - 8, width: gridW - pad * 2, height: 16)
                hint.lineBreakMode = .byTruncatingTail
                views.append(hint)
            }
            y += CGFloat(catRows) * tile.height + CGFloat(catRows - 1) * gap
            if let c = sec.cat { sectionYs.append((c, top, tilesTop, y)) }
            y += sectionGap
        }
        let docH = allFolded ? 0 : y - sectionGap + pad

        // 2) 창 높이: 전부 보이게 하되 화면보다 크면 스크롤
        let screenH = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        // 플레이어 + 그 아래 가사 줄
        let lh = showPlayer ? lyrics.stripHeight : 0
        let ph = showPlayer ? playerH + lh : 0
        let viewH = min(docH, screenH - bottom - topH - ph - 80)
        let h = viewH + bottom + topH + ph

        let grid = GridView(frame: NSRect(x: 0, y: 0, width: w, height: max(docH, viewH)))
        grid.target = { [unowned self] p in dropTarget(at: p, left: left, gridW: gridW, tile: tile) }
        grid.onDropApps = { [unowned self] urls, t in add(urls, to: t.cat) }
        grid.onMoveApp = { [unowned self] id, t in moveApp(id, toCategory: t.cat, at: t.index) }
        views.forEach(grid.addSubview)
        if widget { grid.menu = backgroundMenu() }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: bottom, width: w, height: viewH))
        scroll.documentView = grid
        scroll.hasVerticalScroller = docH > viewH
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // 3) 아래쪽 버튼 줄
        let add = ActionButton(title: "추가", symbol: "plus") { [unowned self] b in
            let m = NSMenu()
            if cats.count == 1 {
                m.addItem(Item("앱 고르기…") { [unowned self] in addApp(to: 0) })
            } else {
                m.addItem(headerItem("어느 카테고리에 넣을까요?"))
                for (c, cat) in cats.enumerated() { m.addItem(Item(cat.name) { [unowned self] in addApp(to: c) }) }
            }
            m.addItem(.separator())
            m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
            popUp(m, under: b)
        }
        let edit = ActionButton(title: editing ? "완료" : "빼기", symbol: editing ? "checkmark" : "minus") { [unowned self] _ in
            editing.toggle()
            refresh()
        }
        if editing { edit.keyEquivalent = "\r" }
        let catBtn = ActionButton(title: "카테고리", symbol: "folder") { [unowned self] b in
            popUp(categoriesMenu(), under: b)
        }
        let gear = ActionButton(title: "", symbol: "gearshape") { [unowned self] _ in openSettings() }
        gear.toolTip = "열 · 행 · 아이콘 크기 설정 (⌘,)"
        let widgetBtn = ActionButton(title: widget ? "창으로" : "위젯", symbol: widget ? "macwindow" : "rectangle.on.rectangle") { [unowned self] _ in
            setWidget(!widget)
        }
        widgetBtn.toolTip = widget ? "일반 창으로 돌아가기" : "바탕화면 위젯으로 바꾸기 (⌘⇧W)"
        let total = allIds.count
        let info = NSTextField(labelWithString: editing ? "⊖ 를 눌러 빼기"
                               : "\(total)개" + (showHeaders ? " · \(cats.count)카테고리" : "") + " · \(cols)열")
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.sizeToFit()

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: w, height: barH))
        let line = NSBox(frame: NSRect(x: 0, y: barH - 1, width: w, height: 1))
        line.boxType = .separator
        bar.addSubview(line)
        var x: CGFloat = 10
        for b in [add, edit, catBtn] {
            b.setFrameOrigin(NSPoint(x: x, y: (barH - b.frame.height) / 2))
            bar.addSubview(b)
            x += b.frame.width + 6
        }
        gear.setFrameOrigin(NSPoint(x: w - gear.frame.width - 10, y: (barH - gear.frame.height) / 2))
        bar.addSubview(gear)
        widgetBtn.setFrameOrigin(NSPoint(x: gear.frame.minX - widgetBtn.frame.width - 4, y: (barH - widgetBtn.frame.height) / 2))
        bar.addSubview(widgetBtn)
        info.setFrameOrigin(NSPoint(x: widgetBtn.frame.minX - info.frame.width - 8, y: (barH - info.frame.height) / 2))
        if info.frame.minX > x { bar.addSubview(info) }

        // 바깥 틀(위젯 카드/일반 창 배경)과 위쪽 검색 줄은 한 번만 만들고, 아이콘 영역만 갈아 끼움
        let content: NSView
        if let r = root {
            content = r
        } else if widget {
            // 위젯 카드: 뒤 배경이 비치는 반투명 + 둥근 모서리
            let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.maskImage = roundedMask(20)
            content = fx
        } else {
            content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        }
        if widget { content.menu = backgroundMenu() }
        content.subviews.filter { $0 !== topBar }.forEach { $0.removeFromSuperview() }

        // 창 크기를 먼저 맞춘 뒤 내용을 배치. 창 위쪽 위치는 그대로 유지
        let topEdge = window.frame.maxY
        var f = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
        f.origin = NSPoint(x: window.frame.minX, y: topEdge - f.height)
        window.setFrame(f, display: false)
        if root == nil {
            window.contentView = content
            content.addSubview(topBar)
            root = content
        }
        content.frame = NSRect(x: 0, y: 0, width: w, height: h)
        content.addSubview(scroll)
        if showBar { content.addSubview(bar) }
        if ph > 0 {
            playerBar.frame = NSRect(x: 0, y: h - topH - playerH, width: w, height: playerH)
            content.addSubview(playerBar)
            playerBar.needsLayout = true
            lyrics.stripView.frame = NSRect(x: 0, y: h - topH - ph, width: w, height: lh)
            content.addSubview(lyrics.stripView)
        }

        // 위쪽 줄: [🔍 앱 찾기 ........] [Finder]
        topBar.frame = NSRect(x: 0, y: h - topH, width: w, height: topH)
        let fb = finderButton.frame.size
        finderButton.setFrameOrigin(NSPoint(x: w - fb.width - 10, y: (topH - fb.height) / 2))
        collapseButton.image = NSImage(systemSymbolName: allFolded ? "chevron.down" : "chevron.up", accessibilityDescription: nil)
        collapseButton.toolTip = allFolded ? "앱 목록 펼치기" : "앱 목록 접기"
        collapseButton.setFrameOrigin(NSPoint(x: finderButton.frame.minX - 28, y: (topH - 24) / 2))
        bulkButton.setFrameOrigin(NSPoint(x: collapseButton.frame.minX - 26, y: (topH - 24) / 2))
        searchField.frame = NSRect(x: 10, y: (topH - 24) / 2, width: bulkButton.frame.minX - 14, height: 24)
        scroll.contentView.scroll(to: .zero)

        buildStatusMenu()
    }

    // MARK: 메뉴바 메뉴

    func buildStatusMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        for cat in cats {
            if cats.count > 1 { m.addItem(headerItem(cat.name)) }
            for id in cat.ids {
                let r = running(id) != nil
                let i = Item((r ? "● " : "    ") + name(id)) { [unowned self] in launch(id) }
                let img = icon(id).copy() as! NSImage
                img.size = NSSize(width: 16, height: 16)
                i.image = img
                i.isEnabled = url(id) != nil
                if r {
                    let sub = NSMenu()
                    sub.addItem(Item("앞으로 가져오기") { [unowned self] in launch(id) })
                    sub.addItem(Item("종료") { [unowned self] in quit(id) })
                    i.submenu = sub
                }
                m.addItem(i)
            }
            if cats.count > 1 { m.addItem(.separator()) }
        }
        if cats.count == 1 { m.addItem(.separator()) }
        m.addItem(Item("모두 실행") { [unowned self] in allIds.forEach(launch) })
        let bulk = NSMenuItem(title: "창 정리", action: nil, keyEquivalent: "")
        bulk.submenu = BulkWindows.menu()
        m.addItem(bulk)
        m.addItem(Item("런처 창 열기") { [unowned self] in showWindow() })
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(Item("설정…") { [unowned self] in openSettings() })
        m.addItem(.separator())
        widgetItems().forEach(m.addItem)
        m.addItem(.separator())
        if showPlayer, let st = music.state {
            m.addItem(headerItem("♪ " + (st.title.isEmpty ? "YouTube Music" : st.title)))
            m.addItem(Item("    재생 / 일시정지") { [unowned self] in music.press("playPause") })
            m.addItem(Item("    다음 곡") { [unowned self] in music.press("next") })
            m.addItem(Item("    이전 곡") { [unowned self] in music.press("prev") })
            m.addItem(Item("    전체 가사 보기") { [unowned self] in lyrics.show() })
            m.addItem(Item("    YouTube Music 창 열기") { [unowned self] in music.showWindow() })
            m.addItem(.separator())
        }
        let pl = Item("YouTube Music 미니 플레이어") { [unowned self] in setPlayer(!playerEnabled) }
        pl.state = playerEnabled ? .on : .off
        m.addItem(pl)
        let dockItem = Item("켜져 있는 동안 Dock 가리기") { [unowned self] in setHideDock(!hideDock) }
        dockItem.state = hideDock ? .on : .off
        m.addItem(dockItem)
        let login = Item("로그인 시 자동 실행") { [unowned self] in toggleLogin() }
        login.state = loginEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(Item("도구함 종료") { NSApp.terminate(nil) })
        statusItem.menu = m
    }

    // MARK: 설정 창 (열 · 행 · 아이콘 크기)

    @objc func openSettings() {
        if settings == nil { buildSettings() }
        syncSettings()
        settings!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettings() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 292),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "도구함 설정"
        p.isReleasedWhenClosed = false
        let v = p.contentView!

        func label(_ t: String, y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 10, y: y, width: 90, height: 20)
            v.addSubview(l)
        }
        func numberRow(_ t: String, y: CGFloat, max: Int, note: String) -> (NSTextField, NSStepper) {
            label(t, y: y)
            let f = NSTextField(frame: NSRect(x: 108, y: y - 1, width: 50, height: 22))
            let nf = NumberFormatter()
            nf.minimum = 1
            nf.maximum = NSNumber(value: max)
            nf.allowsFloats = false
            f.formatter = nf
            f.alignment = .center
            f.target = self
            f.action = #selector(fieldChanged(_:))
            v.addSubview(f)
            let s = NSStepper(frame: NSRect(x: 162, y: y - 2, width: 20, height: 24))
            s.minValue = 1
            s.maxValue = Double(max)
            s.increment = 1
            s.valueWraps = false
            s.target = self
            s.action = #selector(stepperChanged(_:))
            v.addSubview(s)
            let n = NSTextField(labelWithString: note)
            n.font = .systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: 190, y: y + 1, width: 160, height: 16)
            v.addSubview(n)
            return (f, s)
        }

        label("음악", y: 252)
        playerCheck = NSButton(checkboxWithTitle: "YouTube Music 미니 플레이어", target: self, action: #selector(playerChecked(_:)))
        playerCheck.frame = NSRect(x: 106, y: 251, width: 250, height: 22)
        v.addSubview(playerCheck)

        label("Dock", y: 222)
        dockCheck = NSButton(checkboxWithTitle: "켜져 있는 동안 Dock 가리기", target: self, action: #selector(dockChecked(_:)))
        dockCheck.frame = NSRect(x: 106, y: 221, width: 240, height: 22)
        v.addSubview(dockCheck)

        label("모양", y: 192)
        widgetCheck = NSButton(checkboxWithTitle: "바탕화면 위젯으로 쓰기", target: self, action: #selector(widgetChecked(_:)))
        widgetCheck.frame = NSRect(x: 106, y: 191, width: 240, height: 22)
        v.addSubview(widgetCheck)

        (colsField, colsStepper) = numberRow("열 (가로 칸)", y: 150, max: 12, note: "한 줄에 놓을 앱 수")
        (rowsField, rowsStepper) = numberRow("행 (세로 칸)", y: 116, max: 12, note: "카테고리마다 최소 줄 수")

        label("아이콘 크기", y: 80)
        sizeSlider = NSSlider(value: 64, minValue: 24, maxValue: 128, target: self, action: #selector(sliderChanged(_:)))
        sizeSlider.frame = NSRect(x: 106, y: 78, width: 170, height: 24)
        sizeSlider.numberOfTickMarks = 14
        sizeSlider.allowsTickMarkValuesOnly = true
        v.addSubview(sizeSlider)
        sizeLabel = NSTextField(labelWithString: "64px")
        sizeLabel.frame = NSRect(x: 282, y: 80, width: 60, height: 20)
        v.addSubview(sizeLabel)

        // 자주 쓰는 크기 바로가기
        var x: CGFloat = 108
        for (t, s) in [("작게", 32.0), ("보통", 48.0), ("크게", 64.0), ("아주 크게", 96.0)] {
            let b = ActionButton(title: t, symbol: nil) { [unowned self] _ in
                iconSize = CGFloat(s)
                syncSettings()
                save()
            }
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.sizeToFit()
            b.setFrameOrigin(NSPoint(x: x, y: 44))
            v.addSubview(b)
            x += b.frame.width + 2
        }

        let hint = NSTextField(labelWithString: "바꾸면 바로 적용돼요. 앱이 칸보다 많으면 그 카테고리의 줄이 늘어나요.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 12, width: 330, height: 16)
        v.addSubview(hint)

        p.center()
        settings = p
    }

    func syncSettings() {
        widgetCheck.state = widget ? .on : .off
        dockCheck.state = hideDock ? .on : .off
        playerCheck.state = playerEnabled ? .on : .off
        colsField.integerValue = cols; colsStepper.integerValue = cols
        rowsField.integerValue = rows; rowsStepper.integerValue = rows
        sizeSlider.doubleValue = Double(iconSize)
        sizeLabel.stringValue = "\(Int(iconSize))px"
    }

    @objc func widgetChecked(_ b: NSButton) { setWidget(b.state == .on) }

    @objc func fieldChanged(_ f: NSTextField) {
        let v = max(1, min(12, f.integerValue))
        if f === colsField { cols = v } else { rows = v }
        syncSettings()
        save()
    }

    @objc func stepperChanged(_ s: NSStepper) {
        if s === colsStepper { cols = s.integerValue } else { rows = s.integerValue }
        syncSettings()
        save()
    }

    @objc func sliderChanged(_ s: NSSlider) {
        iconSize = CGFloat(s.doubleValue.rounded())
        sizeLabel.stringValue = "\(Int(iconSize))px"
        save()
    }
}

// MARK: - 검색칸 입력

extension AppDelegate: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        if query.isEmpty { installed = nil }     // 새로 찾기 시작할 때 설치된 앱 목록을 새로 읽음
        query = searchField.stringValue
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchField else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            // Enter: 첫 번째 결과 실행
            if let first = displaySections().flatMap(\.ids).first {
                launch(first)
                clearSearch()
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            clearSearch()
            return true
        }
        return false
    }

    func clearSearch() {
        searchField.stringValue = ""
        query = ""
        refresh()
    }

    @objc func focusSearch() {
        showWindow()
        window.makeFirstResponder(searchField)
    }
}

// 기본 메뉴 (⌘Q, ⌘W, ⌘, 가 동작하도록)
@MainActor
func buildMainMenu(_ delegate: AppDelegate) {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    let pref = NSMenuItem(title: "설정…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
    pref.target = delegate
    appMenu.addItem(pref)
    let find = NSMenuItem(title: "앱 찾기", action: #selector(AppDelegate.focusSearch), keyEquivalent: "f")
    find.target = delegate
    appMenu.addItem(find)
    let wid = NSMenuItem(title: "위젯 모드로 바꾸기", action: #selector(AppDelegate.toggleWidgetAction), keyEquivalent: "W")
    wid.target = delegate
    appMenu.addItem(wid)
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "도구함 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "편집")   // 이름 입력 칸에서 ⌘C/⌘V 가 되도록
    editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    let winItem = NSMenuItem()
    main.addItem(winItem)
    let winMenu = NSMenu(title: "윈도우")
    winMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = winMenu
    NSApp.mainMenu = main
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    buildMainMenu(delegate)
    app.run()
}
