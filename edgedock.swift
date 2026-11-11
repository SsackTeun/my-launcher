// 도구함 창을 화면 왼쪽 · 오른쪽 끝에 붙이면 옆에 작은 서랍 손잡이가 생김
// - 손잡이 ‹ 를 누르면 창이 가장자리 밖으로 쏙 들어가 접히고, 손잡이만 남음
// - 접힌 손잡이 › 를 누르면 (또는 끌어 온 앱을 올리면) 창이 다시 미끄러져 나옴
// - 창을 가장자리에서 떼어 놓으면 손잡이도 사라짐
import Cocoa

@MainActor
final class EdgeDock {
    static let shared = EdgeDock()
    enum Side: String { case left, right }
    private let d = UserDefaults.standard
    private weak var window: NSWindow?
    private var tab: NSPanel?
    private var tabView: DockTabView?
    private var timer: Timer?
    private var moveCheck: DispatchWorkItem?
    private var animating = false
    private var observer: NSObjectProtocol?

    /// 지금 붙은 쪽 (없으면 nil)
    private(set) var side: Side? {
        get { Side(rawValue: d.string(forKey: "dockSide") ?? "") }
        set { d.set(newValue?.rawValue, forKey: "dockSide") }
    }
    private(set) var collapsed: Bool {
        get { d.bool(forKey: "dockCollapsed") }
        set { d.set(newValue, forKey: "dockCollapsed") }
    }
    /// 창을 다시 보여 줄 때 쓰는 동작 (일반 창은 앞으로 가져오며 활성화)
    var present: (NSWindow) -> Void = { $0.orderFrontRegardless() }

    /// 접히는 중 · 접혀 있는 창은 화면 안으로 밀어 넣지 않게 (OnScreen 이 물어봄)
    func ignores(_ w: NSWindow) -> Bool { w === window && (animating || collapsed) }

    /// 도구함 창이 새로 만들어질 때마다 붙임
    func attach(_ w: NSWindow) {
        window = w
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { EdgeDock.shared.windowMoved() }
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.3, repeats: true) { _ in MainActor.assumeIsolated { EdgeDock.shared.sync() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        // 접힌 채로 껐다 켰으면 접힌 상태로 시작
        if collapsed, side != nil {
            DispatchQueue.main.async { MainActor.assumeIsolated { w.orderOut(nil); self.sync() } }
        }
        sync()
    }

    // MARK: 끄는 동안 붙을 자리 보여 주기

    /// 가장자리에서 이만큼 안에 놓으면 붙음 (점) = 도구함에 보이는 앱 아이콘 한 개 크기
    var appSize: () -> CGFloat = { 32 }
    static var zone: CGFloat { max(16, EdgeDock.shared.appSize()) }
    private var watch: Timer?
    private var dragStart: (frame: NSRect, mouse: NSPoint)?

    /// 창을 끌기 시작할 때 (도구함 손잡이 · 빈 곳에서 부름)
    func beginWatch() {
        guard let w = window, watch == nil, !collapsed else { return }
        dragStart = (w.frame, NSEvent.mouseLocation)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated { EdgeDock.shared.watchTick() } }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    private func watchTick() {
        guard let w = window, let st = dragStart, NSEvent.pressedMouseButtons != 0 else { stopWatch(); return }
        let m = NSEvent.mouseLocation
        // 끄는 동안 창 자리가 늦게 갱신될 수 있어서 마우스가 움직인 만큼으로 계산
        var f = st.frame
        f.origin = NSPoint(x: st.frame.minX + m.x - st.mouse.x, y: st.frame.minY + m.y - st.mouse.y)
        let s = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? screen(of: w)
        let vf = s.visibleFrame
        var cands: [(Side, CGFloat)] = []
        if !otherScreen(beyond: .left, of: s) { cands.append((.left, f.minX - vf.minX)) }
        if !otherScreen(beyond: .right, of: s) { cands.append((.right, vf.maxX - f.maxX)) }
        guard let (e, dist) = cands.min(by: { $0.1 < $1.1 }), dist < 240 else { EdgeIndicator.shared.hide(); return }
        let active = dist <= Self.zone
        var ghost = f
        ghost.origin.x = e == .left ? vf.minX : vf.maxX - f.width
        ghost.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        EdgeIndicator.shared.show(screen: s, edge: e == .left ? .left : .right, zone: Self.zone, active: active,
                                  ghost: active ? ghost : nil, text: "놓으면 여기에 붙어요 · 손잡이로 접을 수 있어요")
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
        dragStart = nil
        EdgeIndicator.shared.hide()
    }

    // MARK: 붙었는지 판단 (창을 옮기고 마우스를 놓은 뒤)

    private func windowMoved() {
        guard !animating else { return }
        if watch == nil, NSEvent.pressedMouseButtons != 0 { beginWatch() }   // 제목 막대로 끄는 일반 창
        moveCheck?.cancel()
        let job = DispatchWorkItem { MainActor.assumeIsolated { EdgeDock.shared.checkDock() } }
        moveCheck = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: job)
    }

    private func checkDock() {
        guard let w = window, !animating, !collapsed else { return }
        if NSEvent.pressedMouseButtons != 0 { windowMoved(); return }   // 아직 끄는 중
        let s = screen(of: w)
        let vf = s.visibleFrame, f = w.frame
        var new: Side?
        if f.minX <= vf.minX + Self.zone, !otherScreen(beyond: .left, of: s) { new = .left }
        else if f.maxX >= vf.maxX - Self.zone, !otherScreen(beyond: .right, of: s) { new = .right }
        if new != side { side = new }
        if let new {
            // 가장자리에 딱 붙임
            let x = new == .left ? vf.minX : vf.maxX - f.width
            if abs(f.minX - x) > 0.5 { animating = true; w.setFrameOrigin(NSPoint(x: x, y: f.minY)); animating = false }
        }
        sync()
    }

    private func screen(of w: NSWindow) -> NSScreen {
        w.screen ?? NSScreen.screens.first { $0.frame.intersects(w.frame) } ?? NSScreen.screens.first!
    }

    /// 그 가장자리 너머에 다른 모니터가 이어져 있으면 접을 수 없음 (손잡이가 화면 가운데에 떠 버림)
    private func otherScreen(beyond side: Side, of s: NSScreen) -> Bool {
        let f = s.frame
        let probe = side == .left ? NSRect(x: f.minX - 20, y: f.minY, width: 10, height: f.height)
                                  : NSRect(x: f.maxX + 10, y: f.minY, width: 10, height: f.height)
        return NSScreen.screens.contains { $0 !== s && $0.frame.intersects(probe) }
    }

    // MARK: 접기 · 펴기

    func toggle() { collapsed ? expand() : collapse() }

    func collapse() {
        guard let w = window, let side, !collapsed else { return }
        let s = screen(of: w)
        let docked = w.frame
        var out = docked
        out.origin.x = side == .left ? s.frame.minX - docked.width - 2 : s.frame.maxX + 2
        collapsed = true
        animating = true
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(out, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                w.orderOut(nil)
                w.setFrame(docked, display: false)   // 숨긴 채 원래 자리로 (다음에 펼 때 · 저장되는 자리)
                self.animating = false
                self.sync()
            }
        })
        sync()
    }

    func expand() {
        guard let w = window, collapsed else { return }
        collapsed = false
        guard let side else { present(w); sync(); return }
        let s = screen(of: w)
        let docked = w.frame
        var out = docked
        out.origin.x = side == .left ? s.frame.minX - docked.width - 2 : s.frame.maxX + 2
        animating = true
        w.setFrame(out, display: false)
        present(w)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(docked, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { self.animating = false; self.sync() }
        })
        sync()
    }

    /// 다른 길(메뉴 · 단축키)로 창을 띄우면 접힘을 풂
    func windowShown() {
        guard collapsed else { return }
        collapsed = false
        sync()
    }

    /// 접혔는지 · 붙었는지에 맞춰 손잡이 자리 · 모양 · 보이기를 맞춤 (0.3초마다, 창 크기가 바뀌어도 따라감)
    func sync() {
        guard let w = window else { tab?.orderOut(nil); return }
        // 붙은 채로 창이 커지거나 작아지면 가장자리에 다시 맞춤
        if let side, !collapsed, !animating, NSEvent.pressedMouseButtons == 0, w.isVisible {
            let vf = screen(of: w).visibleFrame
            let x = side == .left ? vf.minX : vf.maxX - w.frame.width
            if abs(w.frame.minX - x) > 0.5 { animating = true; w.setFrameOrigin(NSPoint(x: x, y: w.frame.minY)); animating = false }
        }
        guard let side, collapsed || w.isVisible else { tab?.orderOut(nil); return }
        let t = makeTab()
        tabView?.update(side: side, collapsed: collapsed)
        let sz = NSSize(width: 16, height: 72)
        let s = screen(of: w)
        let vf = s.visibleFrame
        let wf = w.frame
        var x: CGFloat
        if collapsed && !animating {
            x = side == .left ? vf.minX : vf.maxX - sz.width
        } else {
            // 창 바깥쪽 옆 (가장자리 반대편) 에 서랍 손잡이처럼
            x = side == .left ? wf.maxX - 2 : wf.minX - sz.width + 2
        }
        let y = min(max(wf.midY - sz.height / 2, vf.minY), vf.maxY - sz.height)
        t.level = collapsed ? .floating : w.level
        t.setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        if !t.isVisible { t.orderFrontRegardless() }
        // 펼친 상태면 창 바로 위에 (다른 창 사이로 손잡이만 뜨지 않게)
        if !collapsed, w.isVisible { t.order(.above, relativeTo: w.windowNumber) }
    }

    private func makeTab() -> NSPanel {
        if let t = tab { return t }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.identifier = NSUserInterfaceItemIdentifier("edgedock")   // 화면 안으로 밀어 넣기(OnScreen) 대상에서 빠짐
        let v = DockTabView()
        p.contentView = v
        tab = p
        tabView = v
        return p
    }
}

/// 서랍 손잡이: 누르면 접기 / 펴기
@MainActor
private final class DockTabView: NSView {
    private var side: EdgeDock.Side = .left
    private var collapsed = false
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverOpen: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.launcherApp, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(side: EdgeDock.Side, collapsed: Bool) {
        guard side != self.side || collapsed != self.collapsed else { return }
        self.side = side
        self.collapsed = collapsed
        needsDisplay = true
        toolTip = collapsed ? "도구함 펴기" : "도구함 접기 (가장자리로 넣기)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func draw(_ r: NSRect) {
        // 가장자리 쪽은 각지고 안쪽은 둥근 손잡이
        let b = bounds
        let path = NSBezierPath(roundedRect: b, xRadius: 7, yRadius: 7)
        NSColor(white: hovering ? 0.22 : 0.14, alpha: 0.95).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        // 접혀 있으면 펴지는 쪽(안쪽), 펴져 있으면 접히는 쪽(가장자리)
        let pointsLeft = (side == .left) != collapsed
        guard let img = NSImage(systemSymbolName: pointsLeft ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rr in
            img.draw(in: rr)
            NSColor(white: 1, alpha: self.hovering ? 0.95 : 0.7).set()
            rr.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: b.midX - s.width / 2, y: b.midY - s.height / 2, width: s.width, height: s.height))
    }

    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        if bounds.contains(convert(e.locationInWindow, from: nil)) { EdgeDock.shared.toggle() }
    }

    // 접혀 있을 때 앱 아이콘을 끌어 올리면 펴짐
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if collapsed { EdgeDock.shared.expand() }
        return []
    }
}

/// 끄는 동안 화면 가장자리에 "여기에 붙어요" 를 그려 주는 투명한 판 (마우스는 통과)
/// - 붙는 구역(폭)은 옅은 띠 + 점선, 구역 안에 들어오면 가장자리 선이 밝아지고 붙을 자리가 테두리로 보임
@MainActor
final class EdgeIndicator {
    static let shared = EdgeIndicator()
    enum Edge { case left, right, top, bottom }
    private var panel: NSPanel?
    private let view = EdgeIndicatorView()

    func show(screen s: NSScreen, edge: Edge, zone: CGFloat, active: Bool, ghost: NSRect?, text: String? = nil) {
        let p = panel ?? make()
        if p.frame != s.frame { p.setFrame(s.frame, display: false) }
        let o = s.frame.origin
        view.edge = edge
        view.zone = zone
        view.active = active
        view.vf = s.visibleFrame.offsetBy(dx: -o.x, dy: -o.y)
        view.ghost = ghost?.offsetBy(dx: -o.x, dy: -o.y)
        view.text = text
        view.needsDisplay = true
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.identifier = NSUserInterfaceItemIdentifier("edgedock")
        p.contentView = view
        panel = p
        return p
    }
}

final class EdgeIndicatorView: NSView {
    var edge: EdgeIndicator.Edge = .left
    var zone: CGFloat = 0
    var active = false
    var vf = NSRect.zero
    var ghost: NSRect?
    var text: String?

    override func draw(_ r: NSRect) {
        let accent = NSColor.controlAccentColor
        // 붙는 구역 띠
        if zone > 0 {
            var band = vf
            switch edge {
            case .left: band.size.width = zone
            case .right: band.origin.x = vf.maxX - zone; band.size.width = zone
            case .top: band.origin.y = vf.maxY - zone; band.size.height = zone
            case .bottom: band.size.height = zone
            }
            accent.withAlphaComponent(active ? 0.20 : 0.08).setFill()
            band.fill()
            // 구역 경계 점선
            let line = NSBezierPath()
            switch edge {
            case .left: line.move(to: NSPoint(x: band.maxX, y: band.minY)); line.line(to: NSPoint(x: band.maxX, y: band.maxY))
            case .right: line.move(to: NSPoint(x: band.minX, y: band.minY)); line.line(to: NSPoint(x: band.minX, y: band.maxY))
            case .top: line.move(to: NSPoint(x: band.minX, y: band.minY)); line.line(to: NSPoint(x: band.maxX, y: band.minY))
            case .bottom: line.move(to: NSPoint(x: band.minX, y: band.maxY)); line.line(to: NSPoint(x: band.maxX, y: band.maxY))
            }
            line.lineWidth = 1.5
            line.setLineDash([6, 5], count: 2, phase: 0)
            accent.withAlphaComponent(active ? 0.8 : 0.45).setStroke()
            line.stroke()
        }
        // 가장자리 선
        var strip = vf
        let t: CGFloat = active ? 5 : 3
        switch edge {
        case .left: strip.size.width = t
        case .right: strip.origin.x = vf.maxX - t; strip.size.width = t
        case .top: strip.origin.y = vf.maxY - t; strip.size.height = t
        case .bottom: strip.size.height = t
        }
        accent.withAlphaComponent(active ? 0.95 : 0.4).setFill()
        NSBezierPath(roundedRect: strip, xRadius: t / 2, yRadius: t / 2).fill()
        // 붙을 자리 미리보기
        if let g = ghost {
            let p = NSBezierPath(roundedRect: g.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
            accent.withAlphaComponent(0.14).setFill()
            p.fill()
            p.lineWidth = 2
            accent.withAlphaComponent(0.9).setStroke()
            p.stroke()
            if let text, g.width > 120 {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
                let s = NSAttributedString(string: text, attributes: a)
                let sz = s.size()
                let box = NSRect(x: g.midX - sz.width / 2 - 10, y: g.midY - sz.height / 2 - 5, width: sz.width + 20, height: sz.height + 10)
                guard box.width < g.width - 8 else { return }
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                s.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5))
            }
        }
    }
}
