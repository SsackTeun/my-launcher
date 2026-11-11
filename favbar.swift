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
    static let shared = FavBar()
    enum Edge: String {
        case left, right, top, bottom
        var vertical: Bool { self == .left || self == .right }
    }
    private let d = UserDefaults.standard
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    /// 도구함이 넣어 주는 것: 실행(Dock 클릭과 같음) · 도구함에 넣어 둔 앱 목록 · 메뉴 갱신
    var open: (String) -> Void = { _ in }
    var launcherApps: () -> [String] = { [] }
    var onChange: () -> Void = {}

    var enabled: Bool {
        get { d.object(forKey: "favBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "favBar"); newValue ? show() : hide(); onChange() }
    }
    var favs: [String] {
        get { d.stringArray(forKey: "favApps") ?? [] }
        set { d.set(newValue, forKey: "favApps"); rebuild(); onChange() }
    }
    var edge: Edge {
        get { Edge(rawValue: d.string(forKey: "favEdge") ?? "") ?? .left }
        set { d.set(newValue.rawValue, forKey: "favEdge") }
    }
    /// 가장자리를 따라 어디쯤 (0 = 아래/왼쪽 끝, 1 = 위/오른쪽 끝)
    var pos: CGFloat {
        get { CGFloat(d.object(forKey: "favPos") as? Double ?? 0.5) }
        set { d.set(Double(newValue), forKey: "favPos") }
    }
    var collapsed: Bool {
        get { d.bool(forKey: "favCollapsed") }
        set { d.set(newValue, forKey: "favCollapsed"); rebuild() }
    }

    // MARK: 넣기 · 빼기 · 순서

    func contains(_ id: String) -> Bool { favs.contains(id) }

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
        favs = f
        if collapsed { collapsed = false }
        if !enabled { enabled = true }
    }
    func remove(_ id: String) { favs = favs.filter { $0 != id } }
    func toggle(_ id: String) { contains(id) ? remove(id) : insert(id) }

    // MARK: 창

    func start() { if enabled { show() } }

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
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { (FavBar.shared.panel?.contentView as? FavBarView)?.refreshRunning() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FavBar.shared.place(animate: false) }
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
        p.contentView = collapsed ? FavHandleView(edge: edge) : FavBarView(edge: edge, ids: favs)
        place(animate: animate)
    }

    private var screen: NSScreen {
        let n = d.integer(forKey: "favScreen")
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

    /// 마우스 자리 → 붙을 가장자리 · 자리 · 모니터
    private func target(_ m: NSPoint) -> (Edge, CGFloat, NSScreen) {
        let s = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? screen
        let vf = s.visibleFrame
        let dist: [(Edge, CGFloat)] = [(.left, m.x - vf.minX), (.right, vf.maxX - m.x), (.top, vf.maxY - m.y), (.bottom, m.y - vf.minY)]
        let e = dist.min { $0.1 < $1.1 }!.0
        let ps = e.vertical ? (m.y - vf.minY) / vf.height : (m.x - vf.minX) / vf.width
        return (e, min(max(ps, 0), 1), s)
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
        let (e, ps, s) = target(m)
        var sz = v.wantSize
        if e.vertical != edge.vertical { sz = NSSize(width: sz.height, height: sz.width) }
        let ghost = frame(edge: e, pos: ps, size: sz, vf: s.visibleFrame)
        let ie: EdgeIndicator.Edge = e == .left ? .left : e == .right ? .right : e == .top ? .top : .bottom
        EdgeIndicator.shared.show(screen: s, edge: ie, zone: 0, active: true, ghost: ghost)
    }
    func endMove() {
        guard grab != nil else { return }
        grab = nil
        EdgeIndicator.shared.hide()
        let m = NSEvent.mouseLocation
        let s = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? screen
        let vf = s.visibleFrame
        let dist: [(Edge, CGFloat)] = [(.left, m.x - vf.minX), (.right, vf.maxX - m.x), (.top, vf.maxY - m.y), (.bottom, m.y - vf.minY)]
        let e = dist.min { $0.1 < $1.1 }!.0
        edge = e
        pos = e.vertical ? (m.y - vf.minY) / vf.height : (m.x - vf.minX) / vf.width
        pos = min(max(pos, 0), 1)
        d.set((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0, forKey: "favScreen")
        rebuild()
    }

    // MARK: [+] 메뉴

    func showAddMenu(from v: NSView) {
        let m = NSMenu()
        func item(_ id: String) -> NSMenuItem? {
            guard !contains(id), let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let i = MenuAction(FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")) { FavBar.shared.insert(id) }
            let img = NSWorkspace.shared.icon(forFile: u.path)
            img.size = NSSize(width: 16, height: 16)
            i.image = img
            return i
        }
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        let run = NSWorkspace.shared.runningApplications.compactMap { a -> String? in
            guard a.activationPolicy == .regular, a.processIdentifier != me, let id = a.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return id
        }
        let runItems = run.compactMap(item)
        if !runItems.isEmpty {
            m.addItem(NSMenuItem(title: "실행 중인 앱", action: nil, keyEquivalent: ""))
            runItems.forEach(m.addItem)
            m.addItem(.separator())
        }
        let mine = launcherApps().filter { !seen.contains($0) }.compactMap(item)
        if !mine.isEmpty {
            let sub = NSMenu()
            mine.forEach(sub.addItem)
            let t = NSMenuItem(title: "도구함 앱", action: nil, keyEquivalent: "")
            t.submenu = sub
            m.addItem(t)
        }
        m.addItem(MenuAction("다른 앱 고르기…") { FavBar.shared.pickApps() })
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "도구함의 아이콘을 여기로 끌어다 놓아도 돼요", action: nil, keyEquivalent: ""))
        m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: v.bounds.midY), in: v)
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
    var wantSize: NSSize { .zero }
    private var down: NSPoint?
    private var moved = false

    init(edge: FavBar.Edge) {
        self.edge = edge
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
        FavBar.shared.beginMove()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d0 = down else { return }
        let m = NSEvent.mouseLocation
        if !moved && hypot(m.x - d0.x, m.y - d0.y) < 4 { return }
        moved = true
        NSCursor.closedHand.set()
        FavBar.shared.moving()
    }
    override func mouseUp(with e: NSEvent) {
        defer { down = nil }
        if moved { NSCursor.arrow.set(); FavBar.shared.endMove() } else { clicked() }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let side = NSMenuItem(title: "붙일 곳", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (t, eg) in [("왼쪽", FavBar.Edge.left), ("오른쪽", .right), ("위", .top), ("아래", .bottom)] {
            let i = MenuAction(t) { FavBar.shared.edge = eg; FavBar.shared.rebuild() }
            i.state = FavBar.shared.edge == eg ? .on : .off
            sm.addItem(i)
        }
        side.submenu = sm
        m.addItem(side)
        m.addItem(MenuAction(FavBar.shared.collapsed ? "펴기" : "접기") { FavBar.shared.collapsed.toggle() })
        m.addItem(MenuAction("앱 넣기…") { [weak self] in if let self { FavBar.shared.showAddMenu(from: self) } })
        m.addItem(.separator())
        m.addItem(MenuAction("자주 쓰는 앱 막대 끄기") { FavBar.shared.enabled = false })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    // 접혀 있을 때 끌어 오면 펴짐 (막대에서는 FavBarView 가 다시 정의)
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard !FavBar.ids(from: s.draggingPasteboard).isEmpty else { return [] }
        if FavBar.shared.collapsed { FavBar.shared.collapsed = false }
        return .copy
    }
}

// MARK: - 접힌 손잡이

@MainActor
final class FavHandleView: FavBase {
    override var wantSize: NSSize { edge.vertical ? NSSize(width: 14, height: 64) : NSSize(width: 64, height: 14) }

    override init(edge: FavBar.Edge) {
        super.init(edge: edge)
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.92).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        layer?.borderWidth = 1
        toolTip = "자주 쓰는 앱 — 누르면 펴져요"
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

    override func clicked() { FavBar.shared.collapsed = false }
}

// MARK: - 펴진 막대

@MainActor
final class FavBarView: FavBase {
    static let thick: CGFloat = 52, cell: CGFloat = 44, pad: CGFloat = 6, grip: CGFloat = 12, chev: CGFloat = 24
    let ids: [String]
    private var cells: [FavAppCell] = []
    private let plus = FavPlusCell()
    private let chevron = NSButton()
    private let marker = CALayer()   // 끌어 놓을 자리 표시

    override var wantSize: NSSize {
        let main = Self.pad * 2 + Self.grip + CGFloat(ids.count + 1) * Self.cell + Self.chev
        return edge.vertical ? NSSize(width: Self.thick, height: main) : NSSize(width: main, height: Self.thick)
    }

    init(edge: FavBar.Edge, ids: [String]) {
        self.ids = ids
        super.init(edge: edge)
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.92).cgColor
        layer?.cornerRadius = 13
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = 1
        for id in ids {
            let c = FavAppCell(id: id, edge: edge)
            cells.append(c)
            addSubview(c)
        }
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
        addSubview(chevron)
        marker.backgroundColor = NSColor.controlAccentColor.cgColor
        marker.cornerRadius = 1.5
        marker.isHidden = true
        layer?.addSublayer(marker)
        toolTip = ids.isEmpty ? "[+] 를 누르거나 도구함의 아이콘을 끌어다 놓으세요 · 빈 곳을 끌면 다른 가장자리로 옮겨요" : nil
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func collapse() { FavBar.shared.collapsed = true }

    /// 순서대로 칸 자리 (막대 방향을 따라)
    private func slot(_ i: Int) -> NSRect {
        let size = Self.cell
        let a = Self.pad + Self.grip + CGFloat(i) * Self.cell
        let off = (Self.thick - size) / 2
        return edge.vertical ? NSRect(x: off, y: a, width: size, height: size) : NSRect(x: a, y: off, width: size, height: size)
    }

    override func layout() {
        super.layout()
        for (i, c) in cells.enumerated() { c.frame = slot(i) }
        plus.frame = slot(cells.count)
        let a = Self.pad + Self.grip + CGFloat(cells.count + 1) * Self.cell
        chevron.frame = edge.vertical ? NSRect(x: 0, y: a, width: Self.thick, height: Self.chev)
                                      : NSRect(x: a, y: 0, width: Self.chev, height: Self.thick)
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

    // 끌어 놓기: 놓을 자리 계산 + 표시
    private func dropIndex(_ s: NSDraggingInfo) -> Int {
        let p = convert(s.draggingLocation, from: nil)
        let a = (edge.vertical ? p.y : p.x) - Self.pad - Self.grip
        return min(max(0, Int((a / Self.cell).rounded())), ids.count)
    }
    private func showMarker(_ i: Int?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let i {
            let a = Self.pad + Self.grip + CGFloat(i) * Self.cell
            // 뒤집힌 좌표(isFlipped)라 레이어 좌표는 아래에서부터
            marker.frame = edge.vertical ? CGRect(x: 8, y: bounds.height - a - 1.5, width: Self.thick - 16, height: 3)
                                         : CGRect(x: a - 1.5, y: 8, width: 3, height: Self.thick - 16)
            marker.isHidden = false
        } else { marker.isHidden = true }
        CATransaction.commit()
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard !FavBar.ids(from: s.draggingPasteboard).isEmpty else { return [] }
        showMarker(dropIndex(s))
        return s.draggingSource is FavAppCell ? .move : .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { showMarker(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        showMarker(nil)
        let new = FavBar.ids(from: s.draggingPasteboard)
        guard !new.isEmpty else { return false }
        var at = dropIndex(s)
        let apply = {
            for id in new { FavBar.shared.insert(id, at: at); at += 1 }
        }
        // 끌기가 끝난 뒤에 막대를 다시 만듦 (끌던 칸이 아직 화면에 있을 때 지우지 않게)
        DispatchQueue.main.async { MainActor.assumeIsolated { apply() } }
        return true
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

    init(id: String, edge: FavBar.Edge) {
        self.id = id
        self.edge = edge
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
    override func mouseEntered(with e: NSEvent) { hovering = true; HoverTip.shared.schedule(name, for: self) }
    override func mouseExited(with e: NSEvent) { hovering = false; HoverTip.shared.hide(for: self) }

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
    }

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
        if !dragging, bounds.contains(convert(e.locationInWindow, from: nil)) {
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [1, 0.85, 1]; a.duration = 0.2
            layer?.add(a, forKey: "press")
            FavBar.shared.open(id)
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
            FavBar.shared.remove(id)
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(MenuAction("열기") { [id] in FavBar.shared.open(id) })
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            m.addItem(MenuAction(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
            m.addItem(MenuAction("종료") { r.terminate() })
        }
        m.addItem(.separator())
        let f = FavBar.shared.favs
        if let i = f.firstIndex(of: id) {
            let back = FavBar.shared.edge.vertical ? "위로" : "왼쪽으로"
            let fwd = FavBar.shared.edge.vertical ? "아래로" : "오른쪽으로"
            if i > 0 { m.addItem(MenuAction("\(back) 옮기기") { [id] in FavBar.shared.insert(id, at: i - 1) }) }
            if i < f.count - 1 { m.addItem(MenuAction("\(fwd) 옮기기") { [id] in FavBar.shared.insert(id, at: i + 2) }) }
        }
        m.addItem(MenuAction("자주 쓰는 앱에서 빼기") { [id] in FavBar.shared.remove(id) })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
}

// MARK: - [+] 칸: 점선 둥근 사각형

@MainActor
final class FavPlusCell: NSView {
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
        if bounds.contains(convert(e.locationInWindow, from: nil)) { FavBar.shared.showAddMenu(from: self) }
    }
}
