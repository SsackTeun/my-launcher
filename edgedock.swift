// 도구함 창을 화면 왼쪽 · 오른쪽 끝에 붙이면 옆에 작은 서랍 손잡이가 생김
// - 손잡이 ‹ 를 누르면 창이 가장자리 밖으로 쏙 들어가 접히고, 손잡이만 남음
// - 접힌 손잡이 › 를 누르면 (또는 끌어 온 앱을 올리면) 창이 다시 미끄러져 나옴
// - 창을 가장자리에서 떼어 놓으면 손잡이도 사라짐
import Cocoa

/// 도구함의 메뉴(오른쪽 클릭 · 🧰 메뉴)가 지금 열려 있는지 — macOS 가 보내는 메뉴 열림 · 닫힘 신호로
@MainActor
enum MenuWatch {
    private static var depth = 0
    private static var started = false
    static var open: Bool { start(); return depth > 0 }
    static func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuWatch.depth += 1 }
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuWatch.depth = max(0, MenuWatch.depth - 1) }
        }
    }
}

/// 접고 펴는 속도 (도구함 · 플레이어 창, 자주 쓰는 앱 막대 모두 같이 씀)
enum Motion {
    private static var d: UserDefaults { .standard }
    /// 접히고 펴지는 움직임 시간 (초). 0 이면 움직임 없이 바로
    static var duration: Double {
        get { d.object(forKey: "motionDuration") as? Double ?? 0.22 }
        set { d.set(newValue, forKey: "motionDuration") }
    }
    /// 마우스를 대고 펴질 때까지 기다리는 시간 (초)
    static var openDelay: Double {
        get { d.object(forKey: "motionOpenDelay") as? Double ?? 0.2 }
        set { d.set(newValue, forKey: "motionOpenDelay") }
    }
    /// 마우스가 벗어나고 접힐 때까지 기다리는 시간 (초)
    static var closeDelay: Double {
        get { d.object(forKey: "motionCloseDelay") as? Double ?? 1.0 }
        set { d.set(newValue, forKey: "motionCloseDelay") }
    }
}

@MainActor
final class EdgeDock {
    /// 도구함 창 (예전 설정 이름 그대로) · 떼어 낸 플레이어 창
    static let shared = EdgeDock(key: "")
    static let player = EdgeDock(key: "player")
    static var all: [EdgeDock] { [shared, player] }
    /// 이 창을 맡은 것
    static func dock(for w: NSWindow?) -> EdgeDock? { all.first { $0.window != nil && $0.window === w } }
    /// 접히는 중 · 접혀 있는 창은 화면 안으로 밀어 넣지 않게 (OnScreen 이 물어봄)
    static func ignoresAny(_ w: NSWindow) -> Bool { all.contains { $0.ignores(w) } }

    let key: String
    init(key: String) { self.key = key }
    private func k(_ s: String) -> String { key.isEmpty ? s : s + "." + key }
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
        get { Side(rawValue: d.string(forKey: k("dockSide")) ?? "") }
        set { d.set(newValue?.rawValue, forKey: k("dockSide")) }
    }
    private(set) var collapsed: Bool {
        get { d.bool(forKey: k("dockCollapsed")) }
        set { d.set(newValue, forKey: k("dockCollapsed")) }
    }
    /// 자동 접기: 붙은 창에서 마우스가 벗어나면 저절로 접고, 접힌 손잡이에 마우스를 올리면 저절로 폄
    var autoCollapse: Bool {
        get { UserDefaults.standard.bool(forKey: "dockAutoCollapse") }
        set { d.set(newValue, forKey: "dockAutoCollapse"); EdgeDock.all.forEach { $0.outSince = nil }; EdgeDock.shared.onChange() }
    }
    var onChange: () -> Void = {}
    /// 접힌 손잡이에 마우스를 대면 펴기 (도구함 · 플레이어 창 · 자주 쓰는 앱 막대 모두). 그렇게 편 건 마우스가 벗어나면 다시 접힘
    /// 창 놓는 방식: 자석 (앱 아이콘 크기 격자에 맞추고 화면 끝에 붙음) · 자유 (놓은 자리 그대로)
    static var magnet: Bool {
        get { UserDefaults.standard.object(forKey: "windowMagnet") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowMagnet"); shared.onChange() }
    }
    /// 창 서버가 아는 지금 창 자리 (끄는 중에도 정확함). 화면 좌표(왼쪽 아래 기준)로 바꿔 돌려줌
    static func liveFrame(_ w: NSWindow) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
              let b = info.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
              let main = NSScreen.screens.first else { return nil }
        return NSRect(x: x, y: main.frame.maxY - y - ht, width: wd, height: ht)
    }
    /// 격자 한 칸 = 앱 아이콘 크기
    static var cell: CGFloat { max(16, shared.appSize()) }
    /// 격자에 맞춘 자리 (보이는 영역 왼쪽 위 기준, 영역 밖으로 안 나가게)
    static func snapped(_ f: NSRect, in vf: NSRect) -> NSRect {
        let c = cell
        var x = vf.minX + ((f.minX - vf.minX) / c).rounded() * c
        var top = vf.maxY - ((vf.maxY - f.maxY) / c).rounded() * c
        x = min(max(x, vf.minX), max(vf.minX, vf.maxX - f.width))
        top = max(min(top, vf.maxY), min(vf.maxY, vf.minY + f.height))
        return NSRect(x: x, y: top - f.height, width: f.width, height: f.height)
    }

    /// 자석: 다른 도구함 창(도구함 · 떼어 낸 플레이어) 가까이 놓으면 옆 · 위 · 아래에 딱 붙임 (끝도 맞춤). 없으면 격자
    static func magnetFrame(_ f: NSRect, in vf: NSRect, except me: NSWindow) -> NSRect {
        let c = cell
        var best: (d: CGFloat, r: NSRect)?
        for o in all {
            guard let ow = o.window, ow !== me, ow.isVisible, !o.collapsed else { continue }
            let g = ow.frame
            var cands: [NSRect] = []
            let vOverlap = f.maxY > g.minY - c && f.minY < g.maxY + c
            let hOverlap = f.maxX > g.minX - c && f.minX < g.maxX + c
            // 옆에 붙이기 (위 끝을 맞추거나, 가까우면 아래 끝)
            func alignY(_ r: NSRect) -> NSRect {
                var r = r
                if abs(f.maxY - g.maxY) < c { r.origin.y = g.maxY - f.height }
                else if abs(f.minY - g.minY) < c { r.origin.y = g.minY }
                return r
            }
            func alignX(_ r: NSRect) -> NSRect {
                var r = r
                if abs(f.minX - g.minX) < c { r.origin.x = g.minX }
                else if abs(f.maxX - g.maxX) < c { r.origin.x = g.maxX - f.width }
                return r
            }
            if vOverlap {
                cands.append(alignY(NSRect(x: g.maxX, y: f.minY, width: f.width, height: f.height)))          // 오른쪽에
                cands.append(alignY(NSRect(x: g.minX - f.width, y: f.minY, width: f.width, height: f.height))) // 왼쪽에
            }
            if hOverlap {
                cands.append(alignX(NSRect(x: f.minX, y: g.minY - f.height, width: f.width, height: f.height))) // 아래에
                cands.append(alignX(NSRect(x: f.minX, y: g.maxY, width: f.width, height: f.height)))            // 위에
            }
            for r in cands {
                let d = hypot(r.minX - f.minX, r.minY - f.minY)
                if d <= c, d < (best?.d ?? .infinity), !r.intersects(g.insetBy(dx: 1, dy: 1)) { best = (d, r) }
            }
        }
        return best?.r ?? snapped(f, in: vf)
    }

    static var hoverExpand: Bool {
        get { UserDefaults.standard.bool(forKey: "hoverExpand") }
        set { UserDefaults.standard.set(newValue, forKey: "hoverExpand"); shared.onChange() }
    }
    /// 마우스를 대서 잠깐 편 상태 (벗어나면 다시 접음)
    private var peek = false
    func expandByHover() {
        expand()
        peek = true
        grace = Date().addingTimeInterval(0.3)
    }
    private var outSince: Date?
    /// 막 펼친 직후엔 잠깐 자동 접기를 쉼 (메뉴 · 단축키로 띄웠을 때 마우스가 멀리 있어도 바로 접히지 않게)
    private var grace = Date.distantPast
    /// 창을 다시 보여 줄 때 쓰는 동작 (일반 창은 앞으로 가져오며 활성화)
    var present: (NSWindow) -> Void = { $0.orderFrontRegardless() }

    /// 접히는 중 · 접혀 있는 창은 화면 안으로 밀어 넣지 않게 (OnScreen 이 물어봄)
    func ignores(_ w: NSWindow) -> Bool { w === window && (animating || collapsed) }

    /// 도구함 창이 새로 만들어질 때마다 붙임
    func attach(_ w: NSWindow) {
        window = w
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowMoved() }
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
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

    /// 화면 끝 손잡이 폭 (붙은 창은 이만큼 떨어져서 손잡이 옆에 놓임)
    static let tabW: CGFloat = 16
    /// 붙은 창과 화면 끝 사이 간격 (0 = 화면 끝에 딱 붙고, 손잡이는 창 안쪽 가장자리에 얹힘)
    static let inset: CGFloat = 0
    /// 가장자리에서 이만큼 안에 놓으면 붙음 (점) = 도구함에 보이는 앱 아이콘 한 개 크기
    var appSize: () -> CGFloat = { 32 }
    static var zone: CGFloat { max(16, EdgeDock.shared.appSize()) }
    private var watch: Timer?
    private var dragStart: (frame: NSRect, mouse: NSPoint)?

    /// 창을 끌기 시작할 때 (도구함 손잡이 · 빈 곳에서 부름)
    func beginWatch() {
        guard let w = window, watch == nil, !collapsed else { return }
        userDragging = true
        dragStart = (w.frame, NSEvent.mouseLocation)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchTick() } }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    private func watchTick() {
        guard let w = window, let st = dragStart else { stopWatch(); return }
        if NSEvent.pressedMouseButtons == 0 {
            // 손을 뗐음 → 창 자리가 자리 잡은 뒤 붙을지 판단
            stopWatch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in MainActor.assumeIsolated { self?.checkDock() } }
            return
        }
        let m = NSEvent.mouseLocation
        // 끄는 동안 앱이 아는 창 자리는 늦게 갱신되므로 창 서버에 지금 자리를 물어봄
        // (모니터를 넘을 때 시스템이 창을 메뉴 막대 아래로 밀어 넣는 등 마우스와 어긋나는 경우도 그대로 반영)
        var f = st.frame
        f.origin = NSPoint(x: st.frame.minX + m.x - st.mouse.x, y: st.frame.minY + m.y - st.mouse.y)
        if let live = Self.liveFrame(w) { f = live }
        let mid = NSPoint(x: f.midX, y: f.midY)
        let s = NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? screen(of: w)
        let vf = Self.area(s, f)
        var cands: [(Side, CGFloat)] = []
        if !otherScreen(beyond: .left, of: s) { cands.append((.left, f.minX - vf.minX)) }
        if !otherScreen(beyond: .right, of: s) { cands.append((.right, vf.maxX - f.maxX)) }
        // 자유: 붙이기 · 격자 표시 없음
        guard Self.magnet else { EdgeIndicator.shared.hide(); return }
        let near = cands.min(by: { $0.1 < $1.1 })
        guard let (e, dist) = near, dist <= Self.zone + Self.inset else {
            // 자석: 놓으면 맞춰질 격자 자리를 보여 줌
            EdgeIndicator.shared.showGrid(screen: s, cell: Self.cell, ghost: Self.magnetFrame(f, in: vf, except: w), area: vf)
            return
        }
        let active = dist <= Self.zone + Self.inset
        var ghost = f
        ghost.origin.x = e == .left ? vf.minX + Self.inset : vf.maxX - Self.inset - f.width
        ghost.origin.y = alignY(f, vf: vf)
        let slots = slotYs(h: f.height, vf: vf).map { NSRect(x: ghost.minX, y: $0, width: f.width, height: f.height) }
        EdgeIndicator.shared.show(screen: s, edge: e == .left ? .left : .right, zone: Self.zone + Self.inset, active: active,
                                  ghost: active ? ghost : nil, slots: active ? slots : [],
                                  text: "놓으면 여기에 붙어요 · 손잡이로 접을 수 있어요")
    }

    /// 가장자리를 따라 세 자리 (아래 · 가운데 · 위) 중 창 가운데에 가장 가까운 곳의 y
    private func slotYs(h: CGFloat, vf: NSRect) -> [CGFloat] {
        guard h < vf.height else { return [vf.maxY - h] }
        return [vf.minY, vf.midY - h / 2, vf.maxY - h]
    }
    private func alignY(_ f: NSRect, vf: NSRect) -> CGFloat {
        slotYs(h: f.height, vf: vf).min { abs($0 + f.height / 2 - f.midY) < abs($1 + f.height / 2 - f.midY) }!
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
        dragStart = nil
        EdgeIndicator.shared.hide()
    }

    // MARK: 붙었는지 판단 (창을 옮기고 마우스를 놓은 뒤)

    /// 사람이 창을 끌고 있는 중인지 (프로그램이 옮긴 건 붙이기 · 떼기 판단을 안 함)
    private var userDragging = false
    /// 마지막으로 본 창 크기 (붙은 채로 크기가 바뀔 때만 가장자리에 다시 맞춤)
    private var lastSize = NSSize.zero
    /// 마지막으로 계산한 붙일 x (막대 접힘 · 펴짐으로 바뀌면 다시 맞춤)
    private var lastEdgeX: CGFloat = .nan

    private func windowMoved() {
        guard !animating else { return }
        if watch == nil, NSEvent.pressedMouseButtons != 0 { beginWatch() }   // 제목 막대로 끄는 일반 창
        guard userDragging else { return }
        moveCheck?.cancel()
        let job = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkDock() } }
        moveCheck = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: job)
    }

    private func checkDock() {
        guard let w = window, !animating, !collapsed, userDragging else { return }
        if NSEvent.pressedMouseButtons != 0 { windowMoved(); return }   // 아직 끄는 중
        userDragging = false
        let f = w.frame
        let mid = NSPoint(x: f.midX, y: f.midY)
        let s = NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) } ?? screen(of: w)
        let vf = Self.area(s, f)
        var new: Side?
        if Self.magnet {
            if f.minX <= vf.minX + Self.zone + Self.inset, !otherScreen(beyond: .left, of: s) { new = .left }
            else if f.maxX >= vf.maxX - Self.zone - Self.inset, !otherScreen(beyond: .right, of: s) { new = .right }
        }
        if new != side { side = new }
        // 자석인데 가장자리가 아니면: 앱 아이콘 크기 격자에 맞춤
        if Self.magnet, new == nil {
            let g = Self.magnetFrame(f, in: vf, except: w)
            if abs(g.minX - f.minX) > 0.5 || abs(g.minY - f.minY) > 0.5 {
                animating = true
                w.setFrame(g, display: true, animate: true)
                animating = false
            }
        }
        if let new {
            // 가장자리에 딱 붙이고, 위 · 가운데 · 아래 중 가까운 자리로 맞춤
            let x = new == .left ? vf.minX + Self.inset : vf.maxX - Self.inset - f.width
            let y = alignY(f, vf: vf)
            if abs(f.minX - x) > 0.5 || abs(f.minY - y) > 0.5 {
                animating = true
                w.setFrame(NSRect(x: x, y: y, width: f.width, height: f.height), display: true, animate: true)
                animating = false
            }
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

    /// 붙일 수 있는 영역: 보이는 영역에서 (켜져 있으면) 자주 쓰는 앱 막대 자리를 뺀 곳
    static func area(_ s: NSScreen, _ f: NSRect) -> NSRect {
        guard BarReserve.enabled, let r = BarReserve.room(for: NSRect(x: s.frame.midX - f.width / 2, y: s.frame.midY - f.height / 2,
                                                                         width: f.width, height: f.height)) else { return s.visibleFrame }
        return r
    }
    /// 이 창 (막대 자리 비워 두기가 도구함 창도 비키게 할 때 씀)
    var managedWindow: NSWindow? { window }

    // MARK: 접기 · 펴기

    func toggle() { collapsed ? expand() : collapse() }

    func collapse() {
        guard let w = window, let side, !collapsed else { return }
        peek = false
        let s = screen(of: w)
        let docked = w.frame
        var out = docked
        out.origin.x = side == .left ? s.frame.minX - docked.width - 2 : s.frame.maxX + 2
        collapsed = true
        animating = true
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Motion.duration
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
        grace = Date().addingTimeInterval(2.5)
        guard let side else { present(w); sync(); return }
        let s = screen(of: w)
        let docked = w.frame
        var out = docked
        out.origin.x = side == .left ? s.frame.minX - docked.width - 2 : s.frame.maxX + 2
        animating = true
        w.setFrame(out, display: false)
        present(w)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Motion.duration
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
        grace = Date().addingTimeInterval(2.5)
        sync()
    }

    /// 접혔는지 · 붙었는지에 맞춰 손잡이 자리 · 모양 · 보이기를 맞춤 (0.3초마다, 창 크기가 바뀌어도 따라감)
    func sync() {
        guard let w = window else { tab?.orderOut(nil); return }
        // 붙은 채로 창 크기가 바뀌었을 때만 가장자리에 다시 맞춤 (위치만 옮긴 건 건드리지 않음)
        let sizeChanged = w.frame.size != lastSize
        lastSize = w.frame.size
        // 막대를 접거나 펴서 붙일 자리가 달라졌을 때도 따라감 (막대가 접히면 화면 끝까지, 펴지면 막대 옆으로)
        if let side, !collapsed, !animating, !userDragging, NSEvent.pressedMouseButtons == 0, w.isVisible {
            let vf = Self.area(screen(of: w), w.frame)
            let x = side == .left ? vf.minX + Self.inset : vf.maxX - Self.inset - w.frame.width
            let areaChanged = abs(x - lastEdgeX) > 0.5
            lastEdgeX = x
            if (sizeChanged || areaChanged), abs(w.frame.minX - x) > 0.5 {
                if sizeChanged {
                    animating = true; w.setFrameOrigin(NSPoint(x: x, y: w.frame.minY)); animating = false
                } else {
                    animating = true
                    NSAnimationContext.runAnimationGroup({ c in
                        c.duration = Motion.duration
                        c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        w.animator().setFrameOrigin(NSPoint(x: x, y: w.frame.minY))
                    }, completionHandler: { MainActor.assumeIsolated { self.animating = false; self.sync() } })
                }
            }
        }
        guard let side, collapsed || w.isVisible else { tab?.orderOut(nil); return }
        let m = NSEvent.mouseLocation
        // 자동 접기: 창 밖으로 마우스가 나가고 1초 지나면 접음 (끄는 중 · 메뉴가 열려 있을 때 · 글자 입력 중엔 안 함)
        if autoCollapse || peek, !collapsed, !animating, !userDragging, w.isVisible {
            let inside = w.frame.insetBy(dx: -6, dy: -6).contains(m) || (tab?.isVisible == true && tab!.frame.contains(m))
            let typing = w.isKeyWindow && ((w.firstResponder as? NSTextView)?.string.isEmpty == false)   // 검색칸에 글자를 쓰는 중
            let menuOpen = MenuWatch.open
            if inside || typing || menuOpen || NSEvent.pressedMouseButtons != 0 || Date() < grace {
                outSince = nil
            } else {
                if outSince == nil { outSince = Date() }
                if Date().timeIntervalSince(outSince!) > Motion.closeDelay { outSince = nil; collapse(); return }
            }
        }
        let t = makeTab()
        tabView?.update(side: side, collapsed: collapsed)
        let sz = NSSize(width: Self.tabW, height: 72)
        let s = screen(of: w)
        let vf = Self.area(s, w.frame)
        let wf = w.frame
        // 손잡이는 접었을 때나 폈을 때나 늘 화면 끝에 (창은 그 바로 옆에 붙음)
        let x = side == .left ? vf.minX : vf.maxX - sz.width
        let y = min(max(wf.midY - sz.height / 2, vf.minY), vf.maxY - sz.height)
        t.level = collapsed ? .floating : w.level
        let tf = NSRect(x: x, y: y, width: sz.width, height: sz.height)
        // 펼쳐져 있을 땐 창 안 버튼을 가리지 않게, 마우스가 그 가장자리 근처에 올 때만 손잡이를 보여 줌
        if !collapsed && !animating {
            let near = side == .left ? m.x <= wf.minX + 28 : m.x >= wf.maxX - 28
            let show = (near && m.y >= wf.minY && m.y <= wf.maxY) || tf.contains(m)
            if !show { if t.isVisible { t.orderOut(nil) }; return }
        }
        t.setFrame(tf, display: true)
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
        v.dock = self
        p.contentView = v
        tab = p
        tabView = v
        return p
    }
}

/// 서랍 손잡이: 누르면 접기 / 펴기
@MainActor
private final class DockTabView: NSView {
    weak var dock: EdgeDock?
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
    override func mouseEntered(with e: NSEvent) {
        hovering = true
        // 자동 접기를 켰으면 접힌 손잡이에 마우스를 올리기만 해도 펴짐
        guard collapsed, dock?.autoCollapse == true || EdgeDock.hoverExpand else { return }
        hoverOpen?.cancel()
        let job = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.hovering == true { self?.dock?.expandByHover() } }
        }
        hoverOpen = job
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.openDelay, execute: job)
    }
    override func mouseExited(with e: NSEvent) { hovering = false; hoverOpen?.cancel() }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        m.addItem(MenuAction(collapsed ? "펴기" : "접기") { [weak self] in self?.dock?.toggle() })
        let a = MenuAction("자동 접기 (마우스가 벗어나면 접고, 올리면 펴기)") { [weak self] in self?.dock?.autoCollapse.toggle() }
        a.state = dock?.autoCollapse == true ? .on : .off
        m.addItem(a)
        let h = MenuAction("손잡이에 마우스를 대면 펴기") { EdgeDock.hoverExpand.toggle() }
        h.state = EdgeDock.hoverExpand ? .on : .off
        m.addItem(h)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

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
        if bounds.contains(convert(e.locationInWindow, from: nil)) { dock?.toggle() }
    }

    // 접혀 있을 때 앱 아이콘을 끌어 올리면 펴짐
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if collapsed { dock?.expand() }
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

    func show(screen s: NSScreen, edge: Edge, zone: CGFloat, active: Bool, ghost: NSRect?, slots: [NSRect] = [], text: String? = nil) {
        let p = panel ?? make()
        if p.frame != s.frame { p.setFrame(s.frame, display: false) }
        let o = s.frame.origin
        view.edge = edge
        view.grid = 0
        view.zone = zone
        view.active = active
        view.vf = s.visibleFrame.offsetBy(dx: -o.x, dy: -o.y)
        view.ghost = ghost?.offsetBy(dx: -o.x, dy: -o.y)
        view.text = text
        view.slots = slots.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
        view.needsDisplay = true
        if !p.isVisible { p.orderFrontRegardless() }
    }

    /// 자석 격자: 화면에 점 격자와 놓일 자리
    func showGrid(screen s: NSScreen, cell: CGFloat, ghost: NSRect, area: NSRect) {
        let p = panel ?? make()
        if p.frame != s.frame { p.setFrame(s.frame, display: false) }
        let o = s.frame.origin
        view.zone = 0
        view.grid = cell
        view.vf = area.offsetBy(dx: -o.x, dy: -o.y)
        view.ghost = ghost.offsetBy(dx: -o.x, dy: -o.y)
        view.text = nil
        view.slots = []
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
    var slots: [NSRect] = []
    /// 0 보다 크면 자석 격자 모드 (한 칸 크기)
    var grid: CGFloat = 0

    override func draw(_ r: NSRect) {
        let accent = NSColor.launcherAccent
        if grid > 0 {
            // 격자 점 (놓일 자리 근처만 진하게)
            let g = ghost ?? .zero
            let near = g.insetBy(dx: -grid * 4, dy: -grid * 4)
            var y = vf.maxY
            while y >= vf.minY - 0.5 {
                var x = vf.minX
                while x <= vf.maxX + 0.5 {
                    let pt = NSPoint(x: x, y: y)
                    let a: CGFloat = near.contains(pt) ? 0.55 : 0.18
                    accent.withAlphaComponent(a).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
                    x += grid
                }
                y -= grid
            }
            if let gh = ghost {
                let path = NSBezierPath(roundedRect: gh, xRadius: 14, yRadius: 14)
                accent.withAlphaComponent(0.12).setFill(); path.fill()
                path.lineWidth = 2
                path.setLineDash([7, 5], count: 2, phase: 0)
                accent.withAlphaComponent(0.85).setStroke(); path.stroke()
            }
            return
        }
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
        // 정렬 자리들 (위 · 가운데 · 아래 또는 왼 · 가운데 · 오른) 은 옅은 점선
        for sl in slots where ghost.map({ !$0.equalTo(sl) }) ?? true {
            let p = NSBezierPath(roundedRect: sl.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            p.lineWidth = 1.5
            p.setLineDash([6, 5], count: 2, phase: 0)
            accent.withAlphaComponent(0.5).setStroke()
            accent.withAlphaComponent(0.05).setFill()
            p.fill()
            p.stroke()
        }
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
