// 자주 쓰는 앱 막대: 화면 가장자리(왼 · 오른 · 위 · 아래 어디든)에 붙는 작은 막대
// - 아이콘을 누르면 실행 / 앞으로, 오른쪽 클릭은 메뉴
// - 맨 끝 [+] (점선 둥근 사각형) 을 누르면 실행 중 · 도구함 앱 · 다른 앱에서 골라 넣음
// - 도구함의 전체 · 실행 중 · 개발자 앱 · 데스크탑 탭에서 아이콘을 끌어다 놓아도 들어감 (Finder 의 .app 도)
// - 막대 안에서 끌면 순서 바꾸기, 막대 밖으로 끌어내 놓으면 빠짐
// - 빈 곳(손잡이)을 잡고 끌어 다른 가장자리에 놓으면 그쪽에 붙음
// - ‹ 버튼으로 접으면 얇은 손잡이만 남고, 누르면 다시 펴짐
import Cocoa
import UniformTypeIdentifiers

@MainActor
final class FavBar {
    enum Edge: String {
        case left, right, top, bottom
        var vertical: Bool { self == .left || self == .right }
    }

    // MARK: 막대 여러 개 (첫 막대는 예전 설정 이름 그대로 써서 기존 막대가 그대로 남음)

    private static let d = UserDefaults.standard
    /// 막대 번호들 ("" = 첫 막대)
    private static var keys: [String] {
        get { d.stringArray(forKey: "favBarIDs") ?? [""] }
        set { d.set(newValue, forKey: "favBarIDs") }
    }
    private static var bars: [String: FavBar] = [:]
    static func bar(_ key: String) -> FavBar {
        if let b = bars[key] { return b }
        let b = FavBar(key: key)
        bars[key] = b
        return b
    }
    /// 모든 막대 (순서대로)
    static var all: [FavBar] { keys.map(bar) }
    /// 첫 막대 (도구함 메뉴 등에서 막대를 고르지 않을 때)
    static var shared: FavBar { all.first ?? bar("") }

    /// 도구함이 넣어 주는 것 (모든 막대가 같이 씀): 실행(Dock 클릭과 같음) · 도구함에 넣어 둔 앱 목록 · 메뉴 갱신
    nonisolated(unsafe) static var openFn: (String) -> Void = { _ in }
    nonisolated(unsafe) static var launcherAppsFn: () -> [String] = { [] }
    nonisolated(unsafe) static var onChangeFn: () -> Void = {}
    var open: (String) -> Void { get { Self.openFn } set { Self.openFn = newValue } }
    var launcherApps: () -> [String] { get { Self.launcherAppsFn } set { Self.launcherAppsFn = newValue } }
    var onChange: () -> Void { get { Self.onChangeFn } set { Self.onChangeFn = newValue } }

    /// 모든 막대 켜기 / 끄기
    var enabled: Bool {
        get { Self.d.object(forKey: "favBar") as? Bool ?? true }
        set {
            Self.d.set(newValue, forKey: "favBar")
            for b in Self.all { newValue ? b.show() : b.hide() }
            onChange()
        }
    }

    /// 새 막대: 아직 막대가 없는 가장자리에 빈 막대로
    @discardableResult
    static func addBar() -> FavBar {
        var n = 2
        while keys.contains(String(n)) { n += 1 }
        let key = String(n)
        keys = keys + [key]
        let b = bar(key)
        let used = Set(all.filter { $0 !== b }.map(\.edge))
        b.edge = [Edge.right, .bottom, .left, .top].first { !used.contains($0) } ?? .right
        b.pos = 0.5
        b.name = "막대 \(n)"
        b.editing = true
        if b.enabledAll { b.show() } else { b.enabled = true }
        onChangeFn()
        return b
    }

    /// 이 막대 지우기 (마지막 하나는 못 지움 → 대신 막대 끄기)
    func delete() {
        guard Self.keys.count > 1 else { enabled = false; return }
        hide()
        Self.keys = Self.keys.filter { $0 != key }
        Self.bars[key] = nil
        for k in ["favApps", "favEdge", "favPos", "favCollapsed", "favScreen", "favName"] { Self.d.removeObject(forKey: k + "." + key) }
        onChange()
    }

    // MARK: 이 막대의 설정

    let key: String
    private init(key: String) { self.key = key }
    /// 설정 이름: 첫 막대는 예전 이름 그대로, 그 밖은 "이름.번호"
    private func k(_ s: String) -> String { key.isEmpty ? s : s + "." + key }
    private var d: UserDefaults { Self.d }
    private var enabledAll: Bool { enabled }
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    var name: String {
        get { d.string(forKey: k("favName")) ?? (key.isEmpty ? "자주 쓰는 앱" : "막대 \(key)") }
        set { d.set(newValue, forKey: k("favName")); rebuild(animate: false); onChange() }
    }
    var favs: [String] {
        get { d.stringArray(forKey: k("favApps")) ?? [] }
        set { d.set(newValue, forKey: k("favApps")); rebuild(); onChange() }
    }
    var edge: Edge {
        get { Edge(rawValue: d.string(forKey: k("favEdge")) ?? "") ?? .left }
        set { d.set(newValue.rawValue, forKey: k("favEdge")) }
    }
    /// 가장자리를 따라 어디쯤 (0 = 아래/왼쪽 끝, 1 = 위/오른쪽 끝)
    var pos: CGFloat {
        get { CGFloat(d.object(forKey: k("favPos")) as? Double ?? 0.5) }
        set { d.set(Double(newValue), forKey: k("favPos")) }
    }
    var collapsed: Bool {
        get { d.bool(forKey: k("favCollapsed")) }
        set { d.set(newValue, forKey: k("favCollapsed")); rebuild() }
    }

    // MARK: 넣기 · 빼기 · 순서

    func contains(_ id: String) -> Bool { favs.contains(id) }
    /// 편집 모드: [+] 와 빼기(✕) 가 보임. 막대가 비어 있으면 [+] 는 늘 보임
    var editing = false { didSet { if editing != oldValue { rebuild(animate: false) } } }
    var showsPlus: Bool { editing || favs.isEmpty }
    /// 막대가 넘쳐 스크롤될 때 보던 자리 · 방금 넣어서 보여 줄 앱
    var scrollOffset: CGFloat = 0
    var revealID: String?

    /// 넣기 (이미 있으면 그 자리로 옮기기). at 이 없으면 맨 뒤
    func insert(_ id: String, at index: Int? = nil) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return }
        var f = favs
        var i = index ?? f.count
        if let old = f.firstIndex(of: id) {
            f.remove(at: old)
            if old < i { i -= 1 }
        }
        f.insert(id, at: min(max(0, i), f.count))
        revealID = id
        favs = f
        if collapsed { collapsed = false }
        if !enabled { enabled = true }
    }
    func remove(_ id: String) { favs = favs.filter { $0 != id } }
    func toggle(_ id: String) { contains(id) ? remove(id) : insert(id) }

    // MARK: 창

    func start() { if enabled { for b in Self.all { b.show() } } }

    func show() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.identifier = NSUserInterfaceItemIdentifier("favbar")   // 화면 안으로 밀어 넣기(OnScreen) 대상에서 빠짐
        panel = p
        rebuild(animate: false)
        p.orderFrontRegardless()
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { (self?.panel?.contentView as? FavBarView)?.refreshRunning() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(animate: false) }
        })
    }

    func hide() {
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        panel?.orderOut(nil)
        panel = nil
    }

    func rebuild(animate: Bool = true) {
        guard let p = panel else { return }
        let vf = screen.visibleFrame
        p.contentView = collapsed ? FavHandleView(edge: edge, bar: self)
            : FavBarView(edge: edge, bar: self, ids: favs, maxMain: edge.vertical ? vf.height : vf.width)
        place(animate: animate)
    }

    private var screen: NSScreen {
        let n = d.integer(forKey: k("favScreen"))
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == n }
            ?? NSScreen.screens.first ?? NSScreen.main!
    }

    func place(animate: Bool) {
        guard let p = panel, let v = p.contentView as? FavBase else { return }
        p.setFrame(frame(edge: edge, pos: pos, size: v.wantSize, vf: screen.visibleFrame), display: true, animate: animate)
    }

    /// 가장자리 · 자리 · 크기로 막대가 놓일 곳
    private func frame(edge: Edge, pos: CGFloat, size: NSSize, vf: NSRect) -> NSRect {
        var sz = size
        if edge.vertical { sz.height = min(sz.height, vf.height) } else { sz.width = min(sz.width, vf.width) }
        var f = NSRect(origin: .zero, size: sz)
        switch edge {
        case .left: f.origin.x = vf.minX
        case .right: f.origin.x = vf.maxX - sz.width
        case .top: f.origin.y = vf.maxY - sz.height
        case .bottom: f.origin.y = vf.minY
        }
        if edge.vertical {
            f.origin.y = min(max(vf.minY + pos * vf.height - sz.height / 2, vf.minY), vf.maxY - sz.height)
        } else {
            f.origin.x = min(max(vf.minX + pos * vf.width - sz.width / 2, vf.minX), vf.maxX - sz.width)
        }
        return f
    }

    /// 막대 가운데점 → 붙을 가장자리 · 자리 · 모니터 · 그 방향의 막대 크기
    /// 가장자리마다 세 자리 (시작 · 가운데 · 끝) 중 막대 가운데가 가장 가까운 자리에 착 붙음
    private func target(_ c: NSPoint, size cur: NSSize) -> (Edge, CGFloat, NSScreen, NSSize) {
        let s = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? screen
        let vf = s.visibleFrame
        let dist: [(Edge, CGFloat)] = [(.left, c.x - vf.minX), (.right, vf.maxX - c.x), (.top, vf.maxY - c.y), (.bottom, c.y - vf.minY)]
        let e = dist.min { $0.1 < $1.1 }!.0
        var sz = cur
        if e.vertical != edge.vertical { sz = NSSize(width: sz.height, height: sz.width) }
        let ps = [CGFloat(0), 0.5, 1].min { a, b in
            let fa = frame(edge: e, pos: a, size: sz, vf: vf), fb = frame(edge: e, pos: b, size: sz, vf: vf)
            return e.vertical ? abs(fa.midY - c.y) < abs(fb.midY - c.y) : abs(fa.midX - c.x) < abs(fb.midX - c.x)
        }!
        return (e, ps, s, sz)
    }

    // MARK: 막대 옮기기 (손잡이를 잡고 끌어 놓으면 가장 가까운 가장자리에 붙음)

    private var grab: (mouse: NSPoint, origin: NSPoint)?
    func beginMove() {
        guard let p = panel else { return }
        grab = (NSEvent.mouseLocation, p.frame.origin)
    }
    func moving() {
        guard let p = panel, let g = grab else { return }
        let m = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: g.origin.x + m.x - g.mouse.x, y: g.origin.y + m.y - g.mouse.y))
        // 놓으면 붙을 가장자리 · 자리 미리 보여 주기 (막대 방향이 바뀌면 가로세로를 바꿔서)
        guard let v = p.contentView as? FavBase else { return }
        let (e, ps, s, sz) = target(NSPoint(x: p.frame.midX, y: p.frame.midY), size: v.wantSize)
        let ghost = frame(edge: e, pos: ps, size: sz, vf: s.visibleFrame)
        let slots = [0, 0.5, 1].map { frame(edge: e, pos: $0, size: sz, vf: s.visibleFrame) }
        let ie: EdgeIndicator.Edge = e == .left ? .left : e == .right ? .right : e == .top ? .top : .bottom
        EdgeIndicator.shared.show(screen: s, edge: ie, zone: 0, active: true, ghost: ghost, slots: slots)
    }
    func endMove() {
        guard grab != nil else { return }
        grab = nil
        EdgeIndicator.shared.hide()
        guard let p = panel, let v = p.contentView as? FavBase else { return }
        let (e, ps, s, _) = target(NSPoint(x: p.frame.midX, y: p.frame.midY), size: v.wantSize)
        edge = e
        pos = ps
        d.set((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0, forKey: k("favScreen"))
        rebuild()
    }

    // MARK: [+] 메뉴

    func showAddMenu(from v: NSView) { FavPicker.shared.show(near: v, bar: self) }

    /// 도구함 아이콘 메뉴용: 막대가 하나면 넣기/빼기, 여러 개면 막대를 고르는 하위 메뉴
    static func menuItem(for id: String) -> NSMenuItem {
        let bs = all
        if bs.count == 1 {
            let b = bs[0]
            return MenuAction(b.contains(id) ? "자주 쓰는 앱 막대에서 빼기" : "자주 쓰는 앱 막대에 넣기") { b.toggle(id) }
        }
        let i = NSMenuItem(title: "자주 쓰는 앱 막대", action: nil, keyEquivalent: "")
        let m = NSMenu()
        for b in bs {
            let it = MenuAction(b.name) { b.toggle(id) }
            it.state = b.contains(id) ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(MenuAction("새 막대 만들어 넣기") { FavBar.addBar().insert(id) })
        i.submenu = m
        return i
    }

    /// 이름 바꾸기 창
    func askRename() {
        let a = NSAlert()
        a.messageText = "막대 이름"
        let f = NSTextField(string: name)
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "바꾸기")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn {
            let t = f.stringValue.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { name = t }
        }
    }

    func confirmDelete() {
        guard !favs.isEmpty else { delete(); return }
        let a = NSAlert()
        a.messageText = "'\(name)' 막대를 지울까요?"
        a.informativeText = "막대에 넣어 둔 앱 \(favs.count)개 목록도 같이 지워져요. 앱 자체는 지워지지 않아요."
        a.addButton(withTitle: "지우기")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { delete() }
    }

    func pickApps() {
        let o = NSOpenPanel()
        o.allowedContentTypes = [.application]
        o.allowsMultipleSelection = true
        o.directoryURL = URL(fileURLWithPath: "/Applications")
        o.message = "자주 쓰는 앱 막대에 넣을 앱을 골라 주세요"
        NSApp.activate(ignoringOtherApps: true)
        guard o.runModal() == .OK else { return }
        for u in o.urls { if let id = Bundle(url: u)?.bundleIdentifier { insert(id) } }
    }

    /// 끌어 놓은 것에서 앱 ID 꺼내기 (도구함 아이콘 · Finder 의 .app)
    static func ids(from pb: NSPasteboard) -> [String] {
        var out: [String] = []
        for item in pb.pasteboardItems ?? [] {
            if let id = item.string(forType: .launcherApp) { out.append(id); continue }
            if let s = item.string(forType: .fileURL), let u = URL(string: s), u.pathExtension == "app",
               let id = Bundle(url: u)?.bundleIdentifier { out.append(id) }
        }
        return out
    }
}

// MARK: - 막대 · 손잡이 공통: 빈 곳을 끌면 막대가 옮겨지고, 그냥 누르면 clicked()

@MainActor
class FavBase: NSView {
    let edge: FavBar.Edge
    let bar: FavBar
    var wantSize: NSSize { .zero }
    private var down: NSPoint?
    private var moved = false

    init(edge: FavBar.Edge, bar: FavBar) {
        self.edge = edge
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.launcherApp, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func clicked() {}

    override func mouseDown(with e: NSEvent) {
        down = NSEvent.mouseLocation
        moved = false
        bar.beginMove()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d0 = down else { return }
        let m = NSEvent.mouseLocation
        if !moved && hypot(m.x - d0.x, m.y - d0.y) < 4 { return }
        moved = true
        NSCursor.closedHand.set()
        bar.moving()
    }
    override func mouseUp(with e: NSEvent) {
        defer { down = nil }
        if moved { NSCursor.arrow.set(); bar.endMove() } else { clicked() }
    }

    override func rightMouseDown(with e: NSEvent) {
        let bar = self.bar
        let m = NSMenu()
        m.addItem(NSMenuItem(title: bar.name, action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        let side = NSMenuItem(title: "붙일 곳", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (t, eg) in [("왼쪽", FavBar.Edge.left), ("오른쪽", .right), ("위", .top), ("아래", .bottom)] {
            let i = MenuAction(t) { bar.edge = eg; bar.rebuild() }
            i.state = bar.edge == eg ? .on : .off
            sm.addItem(i)
        }
        side.submenu = sm
        m.addItem(side)
        let al = NSMenuItem(title: "정렬", action: nil, keyEquivalent: "")
        let am = NSMenu()
        let names = bar.edge.vertical ? ["아래", "가운데", "위"] : ["왼쪽", "가운데", "오른쪽"]
        for (t, v) in zip(names, [0.0, 0.5, 1.0]) {
            let i = MenuAction(t) { bar.pos = CGFloat(v); bar.rebuild() }
            i.state = abs(bar.pos - CGFloat(v)) < 0.01 ? .on : .off
            am.addItem(i)
        }
        al.submenu = am
        m.addItem(al)
        m.addItem(MenuAction(bar.collapsed ? "펴기" : "접기") { bar.collapsed.toggle() })
        m.addItem(MenuAction(bar.editing ? "편집 끝내기" : "편집 (넣기 · 빼기)") { bar.editing.toggle() })
        m.addItem(.separator())
        m.addItem(MenuAction("막대 추가") { FavBar.addBar() })
        m.addItem(MenuAction("이 막대 이름 바꾸기…") { [bar] in bar.askRename() })
        if FavBar.all.count > 1 { m.addItem(MenuAction("이 막대 지우기…") { [bar] in bar.confirmDelete() }) }
        m.addItem(MenuAction("자주 쓰는 앱 막대 모두 끄기") { [bar] in bar.enabled = false })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    // 접혀 있을 때 끌어 오면 펴짐 (막대에서는 FavBarView 가 다시 정의)
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard !FavBar.ids(from: s.draggingPasteboard).isEmpty else { return [] }
        if bar.collapsed { bar.collapsed = false }
        return .copy
    }
}

// MARK: - 접힌 손잡이

@MainActor
final class FavHandleView: FavBase {
    override var wantSize: NSSize { edge.vertical ? NSSize(width: 14, height: 64) : NSSize(width: 64, height: 14) }

    override init(edge: FavBar.Edge, bar: FavBar) {
        super.init(edge: edge, bar: bar)
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.92).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        layer?.borderWidth = 1
        toolTip = "\(bar.name) — 누르면 펴져요"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        // 펴지는 방향 화살표 (가장자리에서 안쪽으로)
        let name: String
        switch edge {
        case .left: name = "chevron.right"
        case .right: name = "chevron.left"
        case .top: name = "chevron.down"
        case .bottom: name = "chevron.up"
        }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rr in
            img.draw(in: rr)
            NSColor(white: 1, alpha: 0.8).set()
            rr.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }

    override func clicked() { bar.collapsed = false }
}

// MARK: - 펴진 막대

@MainActor
final class FavBarView: FavBase {
    static let thick: CGFloat = 52, cell: CGFloat = 44, pad: CGFloat = 6, grip: CGFloat = 12, chev: CGFloat = 24
    /// 손잡이 · [+] · 접기 버튼이 차지하는 길이 (앱 칸 말고)
    private let showPlus: Bool
    private let editing: Bool
    private var fixedLen: CGFloat { Self.pad * 2 + Self.grip + (showPlus ? Self.cell : 0) + Self.chev }
    let ids: [String]
    private let maxMain: CGFloat
    private var cells: [FavAppCell] = []
    private let plus = FavPlusCell()
    private let chevron = NSButton()
    // 앱 칸들만 스크롤 (화면보다 길어지면), 손잡이 · [+] · 접기는 양 끝에 고정
    private let scroll = FavScroll()
    private let doc = FavDocView()
    private let marker = NSView()     // 끌어 놓을 자리 표시
    private let fade = CAGradientLayer()

    /// 앱 칸 영역 길이 (넘치면 화면에 맞게 줄이고 스크롤)
    private var listLen: CGFloat { min(CGFloat(ids.count) * Self.cell, max(Self.cell, maxMain - fixedLen)) }
    private var overflow: Bool { CGFloat(ids.count) * Self.cell > listLen + 0.5 }

    override var wantSize: NSSize {
        let main = fixedLen + listLen
        return edge.vertical ? NSSize(width: Self.thick, height: main) : NSSize(width: main, height: Self.thick)
    }

    init(edge: FavBar.Edge, bar: FavBar, ids: [String], maxMain: CGFloat) {
        self.ids = ids
        self.maxMain = maxMain
        showPlus = bar.showsPlus
        editing = bar.editing
        super.init(edge: edge, bar: bar)
        plus.bar = bar
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.92).cgColor
        layer?.cornerRadius = 13
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = 1
        scroll.horizontal = !edge.vertical
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = false     // 스크롤바는 숨기고 (휠로 스크롤), 넘친 끝은 흐리게 보여 줌
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = edge.vertical ? .allowed : .none
        scroll.horizontalScrollElasticity = edge.vertical ? .none : .allowed
        scroll.contentView.drawsBackground = false
        scroll.documentView = doc
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        for id in ids {
            let c = FavAppCell(id: id, edge: edge, bar: bar, editing: editing)
            cells.append(c)
            doc.addSubview(c)
        }
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        marker.layer?.cornerRadius = 1.5
        marker.isHidden = true
        doc.addSubview(marker)
        plus.isHidden = !showPlus
        addSubview(plus)
        let name: String
        switch edge {   // 접는 방향 = 가장자리 쪽
        case .left: name = "chevron.left"
        case .right: name = "chevron.right"
        case .top: name = "chevron.up"
        case .bottom: name = "chevron.down"
        }
        chevron.image = NSImage(systemSymbolName: name, accessibilityDescription: "접기")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        chevron.isBordered = false
        chevron.contentTintColor = NSColor(white: 1, alpha: 0.6)
        chevron.toolTip = "접기"
        chevron.target = self
        chevron.action = #selector(collapse)
        if editing {
            // 편집 중에는 접기 대신 완료(✓)
            chevron.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "편집 끝내기")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            chevron.contentTintColor = .controlAccentColor
            chevron.toolTip = "편집 끝내기"
            chevron.action = #selector(endEdit)
        }
        addSubview(chevron)
        toolTip = ids.isEmpty ? "[+] 를 누르거나 도구함의 아이콘을 끌어다 놓으세요 · 빈 곳을 끌면 다른 가장자리로 옮겨요" : nil
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func collapse() { bar.collapsed = true }
    @objc private func endEdit() { bar.editing = false }

    private var restored = false
    override func layout() {
        super.layout()
        let a0 = Self.pad + Self.grip
        let L = listLen
        let off = (Self.thick - Self.cell) / 2
        scroll.frame = edge.vertical ? NSRect(x: 0, y: a0, width: Self.thick, height: L) : NSRect(x: a0, y: 0, width: L, height: Self.thick)
        let docLen = CGFloat(cells.count) * Self.cell
        doc.frame = edge.vertical ? NSRect(x: 0, y: 0, width: Self.thick, height: docLen) : NSRect(x: 0, y: 0, width: docLen, height: Self.thick)
        for (i, c) in cells.enumerated() {
            let a = CGFloat(i) * Self.cell
            c.frame = edge.vertical ? NSRect(x: off, y: a, width: Self.cell, height: Self.cell) : NSRect(x: a, y: off, width: Self.cell, height: Self.cell)
        }
        let pa = a0 + L
        plus.frame = edge.vertical ? NSRect(x: off, y: pa, width: Self.cell, height: Self.cell) : NSRect(x: pa, y: off, width: Self.cell, height: Self.cell)
        let ca = pa + (showPlus ? Self.cell : 0)
        chevron.frame = edge.vertical ? NSRect(x: 0, y: ca, width: Self.thick, height: Self.chev)
                                      : NSRect(x: ca, y: 0, width: Self.chev, height: Self.thick)
        if !restored {
            restored = true
            // 방금 넣은 앱이 보이게, 아니면 전에 보던 자리로
            if let id = bar.revealID, let i = ids.firstIndex(of: id) {
                doc.scrollToVisible(cells[i].frame)
                bar.revealID = nil
            } else if overflow {
                let o = bar.scrollOffset
                scroll.contentView.scroll(to: edge.vertical ? NSPoint(x: 0, y: o) : NSPoint(x: o, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        updateFade()
    }

    @objc private func scrolled() {
        let o = scroll.contentView.bounds.origin
        bar.scrollOffset = edge.vertical ? o.y : o.x
        updateFade()
    }

    /// 넘칠 때만, 더 있는 쪽 끝을 살짝 흐리게 (더 있다는 표시)
    private func updateFade() {
        guard let sl = scroll.layer else { return }
        guard overflow else { sl.mask = nil; return }
        let b = scroll.contentView.bounds
        let docLen = edge.vertical ? doc.frame.height : doc.frame.width
        let pos = edge.vertical ? b.origin.y : b.origin.x
        let len = edge.vertical ? b.height : b.width
        let more0 = pos > 1, more1 = pos + len < docLen - 1
        let f = min(0.25, 18 / max(len, 1))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = sl.bounds
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        fade.colors = [more0 ? clear : solid, solid, solid, more1 ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        if edge.vertical {
            // 레이어 좌표는 아래가 0 → 위(시작)가 1
            fade.startPoint = CGPoint(x: 0.5, y: 1); fade.endPoint = CGPoint(x: 0.5, y: 0)
        } else {
            fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        }
        sl.mask = fade
        CATransaction.commit()
    }

    override func draw(_ r: NSRect) {
        // 손잡이: 점 세 개 (여기를 잡고 끌면 막대가 옮겨짐)
        NSColor(white: 1, alpha: 0.35).setFill()
        for k in -1...1 {
            let c = edge.vertical ? NSPoint(x: bounds.midX + CGFloat(k) * 6, y: Self.pad + Self.grip / 2)
                                  : NSPoint(x: Self.pad + Self.grip / 2, y: bounds.midY + CGFloat(k) * 6)
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
        }
    }

    func refreshRunning() { cells.forEach { $0.needsDisplay = true } }

    // 끌어 놓기: 놓을 자리 계산 + 표시 (스크롤된 만큼 반영)
    private func dropIndex(_ s: NSDraggingInfo) -> Int {
        let p = doc.convert(s.draggingLocation, from: nil)
        let a = edge.vertical ? p.y : p.x
        return min(max(0, Int((a / Self.cell).rounded())), ids.count)
    }
    private func showMarker(_ i: Int?) {
        guard let i else { marker.isHidden = true; return }
        let a = CGFloat(i) * Self.cell
        marker.frame = edge.vertical ? NSRect(x: 8, y: a - 1.5, width: Self.thick - 16, height: 3)
                                     : NSRect(x: a - 1.5, y: 8, width: 3, height: Self.thick - 16)
        marker.isHidden = false
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard !FavBar.ids(from: s.draggingPasteboard).isEmpty else { return [] }
        autoScroll(s)
        showMarker(dropIndex(s))
        if let c = s.draggingSource as? FavAppCell, c.bar === bar || !NSEvent.modifierFlags.contains(.option) { return .move }
        return .copy
    }
    /// 끄는 중 목록 끝 가까이 가면 그쪽으로 스크롤
    private func autoScroll(_ s: NSDraggingInfo) {
        guard overflow else { return }
        let p = scroll.convert(s.draggingLocation, from: nil)
        let a = edge.vertical ? p.y : p.x
        let len = edge.vertical ? scroll.bounds.height : scroll.bounds.width
        var step: CGFloat = 0
        if a < 24 { step = -8 } else if a > len - 24 { step = 8 }
        guard step != 0 else { return }
        var o = scroll.contentView.bounds.origin
        let docLen = edge.vertical ? doc.frame.height : doc.frame.width
        if edge.vertical { o.y = min(max(0, o.y + step), docLen - len) } else { o.x = min(max(0, o.x + step), docLen - len) }
        scroll.contentView.scroll(to: o)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func draggingExited(_ s: NSDraggingInfo?) { showMarker(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        showMarker(nil)
        let new = FavBar.ids(from: s.draggingPasteboard)
        guard !new.isEmpty else { return false }
        var at = dropIndex(s)
        let bar = self.bar
        // 다른 막대에서 끌어 왔으면 원래 막대에서 빼서 옮김 (⌥ 를 누르고 놓으면 복사)
        let from = (s.draggingSource as? FavAppCell).flatMap { $0.bar !== bar ? $0.bar : nil }
        let copy = NSEvent.modifierFlags.contains(.option)
        let apply = {
            for id in new { bar.insert(id, at: at); at += 1 }
            if let from, !copy { for id in new { from.remove(id) } }
        }
        // 끌기가 끝난 뒤에 막대를 다시 만듦 (끌던 칸이 아직 화면에 있을 때 지우지 않게)
        DispatchQueue.main.async { MainActor.assumeIsolated { apply() } }
        return true
    }
}

/// 앱 칸을 담는 판 (위에서부터 / 왼쪽부터 쌓임)
final class FavDocView: NSView {
    override var isFlipped: Bool { true }
}

/// 가로 막대에서는 마우스 휠(위아래)도 옆으로 스크롤
final class FavScroll: NSScrollView {
    var horizontal = false
    override func scrollWheel(with e: NSEvent) {
        guard horizontal, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX), let doc = documentView else { super.scrollWheel(with: e); return }
        var o = contentView.bounds.origin
        let d = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 10)
        o.x = min(max(0, o.x - d), max(0, doc.frame.width - contentView.bounds.width))
        contentView.scroll(to: o)
        reflectScrolledClipView(contentView)
    }
}

// MARK: - 앱 칸

@MainActor
final class FavAppCell: NSView, NSDraggingSource {
    let id: String
    let edge: FavBar.Edge
    private let icon: NSImage
    private var hovering = false { didSet { needsDisplay = true } }
    private var down: NSPoint?
    private var dragging = false
    private let name: String

    let editing: Bool
    let bar: FavBar
    init(id: String, edge: FavBar.Edge, bar: FavBar, editing: Bool = false) {
        self.id = id
        self.edge = edge
        self.bar = bar
        self.editing = editing
        let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        icon = u.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)!
        name = u.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        hovering = true
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        if editing { HoverTip.shared.schedule("\(name) — 누르면 빠져요", for: self); return }
        HoverTip.shared.schedule(running ? "\(name)\n메모리 · CPU 재는 중…" : "\(name)\n꺼져 있음", for: self)
        if running { measure() }
    }
    override func mouseExited(with e: NSEvent) {
        hovering = false
        measureTimer?.invalidate(); measureTimer = nil
        HoverTip.shared.hide(for: self)
    }

    // 마우스를 올려 둔 동안 메모리 · CPU 를 재서 말풍선에 (1.5초마다 새로)
    private var measureTimer: Timer?
    private var measuring = false
    private func measure() {
        guard hovering, !measuring, let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        measuring = true
        let pid = r.processIdentifier, nm = name
        DispatchQueue.global(qos: .userInitiated).async {
            let u = AppMemory.sample(apps: [pid])[pid]
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.measuring = false
                guard self.hovering else { return }
                if let u {
                    HoverTip.shared.update("\(nm)\n메모리 \(AppMemory.text(u.mem)) · CPU \(AppMemory.cpuText(u.cpu))", for: self)
                }
                if self.measureTimer == nil {
                    let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.measure() } }
                    RunLoop.main.add(t, forMode: .common)
                    self.measureTimer = t
                }
            } }
        }
    }

    private var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    override func draw(_ r: NSRect) {
        if hovering {
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
        icon.draw(in: bounds.insetBy(dx: 6, dy: 6), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if running {
            // 실행 중 점: 화면 가장자리 쪽에
            NSColor(white: 1, alpha: 0.85).setFill()
            let c: NSPoint
            switch edge {
            case .left: c = NSPoint(x: 2.5, y: bounds.midY)
            case .right: c = NSPoint(x: bounds.maxX - 2.5, y: bounds.midY)
            case .top: c = NSPoint(x: bounds.midX, y: 2.5)
            case .bottom: c = NSPoint(x: bounds.midX, y: bounds.maxY - 2.5)
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
        }
        if editing {
            // 빼기 단추 (왼쪽 위 ✕)
            let r = removeRect
            NSColor(white: 0.25, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(white: 1, alpha: 0.9).setStroke()
            let x = NSBezierPath()
            x.lineWidth = 1.6
            x.lineCapStyle = .round
            let k: CGFloat = 3.2
            x.move(to: NSPoint(x: r.midX - k, y: r.midY - k)); x.line(to: NSPoint(x: r.midX + k, y: r.midY + k))
            x.move(to: NSPoint(x: r.midX + k, y: r.midY - k)); x.line(to: NSPoint(x: r.midX - k, y: r.midY + k))
            x.stroke()
        }
    }
    private var removeRect: NSRect { NSRect(x: 1, y: 1, width: 16, height: 16) }

    override func mouseDown(with e: NSEvent) {
        HoverTip.shared.hide(for: self)
        down = e.locationInWindow
        dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard !dragging, let d0 = down else { return }
        let p = e.locationInWindow
        guard hypot(p.x - d0.x, p.y - d0.y) > 4 else { return }
        dragging = true
        hovering = false
        let item = NSPasteboardItem()
        item.setString(id, forType: .launcherApp)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: bounds.size).insetBy(dx: 6, dy: 6))
        img.unlockFocus()
        di.setDraggingFrame(bounds, contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }
    override func mouseUp(with e: NSEvent) {
        defer { down = nil }
        let pt = convert(e.locationInWindow, from: nil)
        if editing {
            // 편집 중: ✕ (또는 아이콘) 을 누르면 빠짐
            if !dragging, bounds.contains(pt) {
                NSAnimationEffect.poof.show(centeredAt: NSEvent.mouseLocation, size: NSSize(width: 32, height: 32))
                bar.remove(id)
            }
            return
        }
        if !dragging, bounds.contains(pt) {
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [1, 0.85, 1]; a.duration = 0.2
            layer?.add(a, forKey: "press")
            bar.open(id)
        }
    }

    // 막대 안 → 순서 바꾸기, 도구함 창 → 도구함에 넣기, 그 밖으로 놓으면 막대에서 빠짐
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation.isEmpty {
            NSAnimationEffect.poof.show(centeredAt: screenPoint, size: NSSize(width: 40, height: 40))
            bar.remove(id)
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let bar = self.bar
        let m = NSMenu()
        m.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(MenuAction("열기") { [id] in bar.open(id) })
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            m.addItem(MenuAction(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
            m.addItem(MenuAction("종료") { r.terminate() })
        }
        m.addItem(.separator())
        let f = bar.favs
        if let i = f.firstIndex(of: id) {
            let back = bar.edge.vertical ? "위로" : "왼쪽으로"
            let fwd = bar.edge.vertical ? "아래로" : "오른쪽으로"
            if i > 0 { m.addItem(MenuAction("\(back) 옮기기") { [id] in bar.insert(id, at: i - 1) }) }
            if i < f.count - 1 { m.addItem(MenuAction("\(fwd) 옮기기") { [id] in bar.insert(id, at: i + 2) }) }
        }
        m.addItem(MenuAction("자주 쓰는 앱에서 빼기") { [id] in bar.remove(id) })
        m.addItem(.separator())
        m.addItem(MenuAction(bar.editing ? "편집 끝내기" : "편집 (넣기 · 빼기)") { bar.editing.toggle() })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
}

// MARK: - [+] 칸: 점선 둥근 사각형

@MainActor
final class FavPlusCell: NSView {
    var bar: FavBar = .shared
    private var hovering = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; HoverTip.shared.schedule("자주 쓰는 앱 넣기", for: self) }
    override func mouseExited(with e: NSEvent) { hovering = false; HoverTip.shared.hide(for: self) }

    override func draw(_ r: NSRect) {
        let box = bounds.insetBy(dx: 8, dy: 8)
        let p = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        p.lineWidth = 1.5
        p.setLineDash([4, 3], count: 2, phase: 0)
        NSColor(white: 1, alpha: hovering ? 0.85 : 0.45).setStroke()
        if hovering { NSColor(white: 1, alpha: 0.08).setFill(); p.fill() }
        p.stroke()
        let plus = NSBezierPath()
        plus.lineWidth = 2
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: box.midX - 6, y: box.midY)); plus.line(to: NSPoint(x: box.midX + 6, y: box.midY))
        plus.move(to: NSPoint(x: box.midX, y: box.midY - 6)); plus.line(to: NSPoint(x: box.midX, y: box.midY + 6))
        plus.stroke()
    }

    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        HoverTip.shared.hide(for: self)
        if bounds.contains(convert(e.locationInWindow, from: nil)) { bar.showAddMenu(from: self) }
    }
}

// MARK: - 앱 여러 개 골라 넣기 창 (체크하고 [넣기] 한 번)

@MainActor
final class FavPicker: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    static let shared = FavPicker()
    private var panel: NSPanel?
    private let search = NSSearchField()
    private let stack = NSStackView()
    private let addButton = NSButton(title: "넣기", target: nil, action: nil)
    private var rows: [PickRow] = []
    private var bar: FavBar = .shared

    func show(near v: NSView, bar: FavBar) {
        self.bar = bar
        let p = panel ?? make()
        p.title = "'\(bar.name)' 막대에 앱 넣기"
        reload()
        // 막대 옆에 띄움 (화면 안으로)
        if let w = v.window {
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            let s = w.screen ?? NSScreen.main!
            let vf = s.visibleFrame
            var f = p.frame
            f.origin.x = r.maxX + 12 + f.width > vf.maxX ? r.minX - f.width - 12 : r.maxX + 12
            f.origin.y = r.midY - f.height / 2
            f.origin.x = min(max(f.origin.x, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = min(max(f.origin.y, vf.minY + 8), vf.maxY - f.height - 8)
            p.setFrame(f, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(search)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "자주 쓰는 앱 넣기"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.minSize = NSSize(width: 280, height: 300)
        let content = NSView()
        search.placeholderString = "앱 찾기"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        let doc = FavDocView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.documentView = doc
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addChecked)
        let finder = NSButton(title: "Finder에서 고르기…", target: self, action: #selector(fromFinder))
        finder.translatesAutoresizingMaskIntoConstraints = false
        finder.bezelStyle = .rounded
        for v in [search, sv, addButton, finder] as [NSView] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            sv.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            sv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),
            doc.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: sv.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            addButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            finder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            finder.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
        p.contentView = content
        panel = p
        return p
    }

    /// 실행 중 → 도구함 앱 → 설치된 앱 순서, 이미 막대에 있는 앱은 뺌
    private func reload() {
        rows.forEach { $0.removeFromSuperview() }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        search.stringValue = ""
        var seen = Set(bar.favs)
        let me = ProcessInfo.processInfo.processIdentifier
        let run = NSWorkspace.shared.runningApplications.compactMap { a -> String? in
            guard a.activationPolicy == .regular, a.processIdentifier != me, let id = a.bundleIdentifier else { return nil }
            return id
        }
        func section(_ title: String, _ ids: [String]) {
            var list: [(String, String, URL)] = []
            for id in ids where !seen.contains(id) {
                guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                seen.insert(id)
                list.append((id, FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), u))
            }
            guard !list.isEmpty else { return }
            list.sort { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            let h = NSTextField(labelWithString: title)
            h.font = .systemFont(ofSize: 11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            stack.addArrangedSubview(h)
            stack.setCustomSpacing(4, after: h)
            for (id, name, u) in list {
                let r = PickRow(id: id, name: name, url: u) { [weak self] in self?.updateButton() }
                rows.append(r)
                stack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        }
        section("실행 중인 앱", run)
        section("도구함 앱", bar.launcherApps())
        section("설치된 앱", Self.installed())
        updateButton()
    }

    static func installed() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
                if let id = Bundle(path: dir + "/" + f)?.bundleIdentifier { out.append(id) }
            }
        }
        return out
    }

    private func updateButton() {
        let n = rows.filter(\.checked).count
        addButton.title = n > 0 ? "넣기 (\(n))" : "넣기"
        addButton.isEnabled = n > 0
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        for r in rows { r.isHidden = !(q.isEmpty || r.name.localizedCaseInsensitiveContains(q) || r.id.localizedCaseInsensitiveContains(q)) }
        // 아래 앱이 하나도 안 보이는 제목은 숨김
        var header: NSView?
        var any = false
        for v in stack.arrangedSubviews {
            if v is PickRow { if !v.isHidden { any = true } }
            else { header?.isHidden = !any; header = v; any = false }
        }
        header?.isHidden = !any
    }

    @objc private func addChecked() {
        let ids = rows.filter(\.checked).map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { bar.insert(id) }
        panel?.orderOut(nil)
    }

    @objc private func fromFinder() {
        panel?.orderOut(nil)
        bar.pickApps()
    }
}

/// 체크 목록 한 줄: [체크] 아이콘 이름 — 줄 아무 데나 눌러도 체크
@MainActor
private final class PickRow: NSView {
    let id: String, name: String
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let onChange: () -> Void
    var checked: Bool { box.state == .on }

    init(id: String, name: String, url: URL, onChange: @escaping () -> Void) {
        self.id = id; self.name = name; self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        box.target = self
        box.action = #selector(changed)
        let img = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        let label = NSTextField(labelWithString: name)
        label.lineBreakMode = .byTruncatingTail
        for v in [box, img, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 20), img.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange() }
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        box.state = box.state == .on ? .off : .on
        onChange()
    }
}
