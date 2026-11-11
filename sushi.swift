// 회전 초밥 띠: 화면 아래에 실행 중인 앱이 접시에 올라 경기장 트랙 모양 레일을 돌아감
// - 마우스를 올리면 띠가 멈추고 그 접시가 커지며 이름 · 메모리 · 안 쓴 시간을 보여 줌
// - 누르면 그 앱을 앞으로, 오른쪽 클릭은 메뉴, 스크롤은 띠를 직접 돌림
// - 접시 색 = 메모리 사용량 (초밥집 접시 가격처럼): 흰 < 300MB < 초록 < 1GB < 노랑 < 2GB < 빨강 < 4GB < 금
// 켜고 끌 수 있는 기능 (오른쪽 클릭 → 기능):
//   숨었다 올라오기 · 창 미리보기 · 식은 접시(오래 안 쓴 앱) · 알림 뚜껑(Dock 숫자) · 끌어서 정리 · 계산서 · 들어오고 나가는 연출
import Cocoa
import ScreenCaptureKit

@MainActor
final class SushiBelt {
    static let shared = SushiBelt()
    private let d = UserDefaults.standard
    private var panel: NSPanel?
    private var belt: BeltView?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var slowTimer: Timer?
    private var edgeTimer: Timer?

    /// 도구함이 넣어 주는 동작 (Dock 클릭과 같은 열기 · 종료) · 지금 듣는 곡
    var open: (String) -> Void = { _ in }
    var quit: (String) -> Void = { _ in }
    var nowPlaying: () -> String? = { nil }

    var enabled: Bool {
        get { d.bool(forKey: "sushiBelt") }
        set { d.set(newValue, forKey: "sushiBelt"); newValue ? show() : hide() }
    }
    /// 띠 크기 (1 = 처음 만든 크기). 바꾸면 띠를 새로 만듦
    var size: Double {
        get { d.object(forKey: "sushiSize") as? Double ?? 0.6 }
        set { d.set(newValue, forKey: "sushiSize"); if panel != nil { hide(); show() } }
    }
    /// 1 초에 움직이는 거리 (점)
    var speed: CGFloat {
        get { d.object(forKey: "sushiSpeed") as? CGFloat ?? 40 }
        set { d.set(newValue, forKey: "sushiSpeed"); belt?.speed = newValue }
    }

    // MARK: 기능 스위치 (기본은 모두 켬)
    enum Feature: String, CaseIterable {
        case autoHide, preview, stale, badge, drag, bill, entrance
        var title: String {
            switch self {
            case .autoHide: return "평소엔 숨기 (화면 맨 아래에 마우스를 대면 올라옴)"
            case .preview: return "마우스 올리면 창 미리보기"
            case .stale: return "오래 안 쓴 앱은 식은 접시 · 방금 쓴 앱은 김"
            case .badge: return "알림 뚜껑 (Dock 의 빨간 숫자)"
            case .drag: return "접시 끌기: 위로 = 열기 · 아래로 = 종료"
            case .bill: return "트랙 안쪽 계산서 (메모리 합계 · 듣는 곡)"
            case .entrance: return "앱 켜고 끌 때 접시 나오고 들어가는 연출"
            }
        }
    }
    func on(_ f: Feature) -> Bool { d.object(forKey: "sushi." + f.rawValue) as? Bool ?? true }
    func toggle(_ f: Feature) {
        d.set(!on(f), forKey: "sushi." + f.rawValue)
        if f == .autoHide { on(f) ? hideBelt() : reveal() }
        belt?.featuresChanged()
        refreshSlow()
    }

    func start() { if enabled { show() } }

    func show() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.identifier = NSUserInterfaceItemIdentifier("sushi")   // 화면 안으로 밀어 넣기(OnScreen) 대상에서 빠짐
        let v = BeltView(frame: .zero)
        v.speed = speed
        v.owner = self
        p.contentView = v
        panel = p
        belt = v
        let now = Date()
        for a in NSWorkspace.shared.runningApplications { lastUsed[a.processIdentifier] = lastUsed[a.processIdentifier] ?? now }
        shown = !on(.autoHide)
        place()
        reload()
        if shown { p.orderFrontRegardless() }
        v.startMoving()

        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append((ws, ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SushiBelt.shared.reload() }
            }))
        }
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let a { SushiBelt.shared.lastUsed[a.processIdentifier] = Date() }
                SushiBelt.shared.refreshSlow()
            }
        }))
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SushiBelt.shared.place() }
        }))
        let t = Timer(timeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { SushiBelt.shared.refreshSlow() } }
        RunLoop.main.add(t, forMode: .common)
        slowTimer = t
        let e = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { SushiBelt.shared.checkEdge() } }
        RunLoop.main.add(e, forMode: .common)
        edgeTimer = e
        refreshSlow()
    }

    func hide() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        slowTimer?.invalidate(); slowTimer = nil
        edgeTimer?.invalidate(); edgeTimer = nil
        belt?.stopMoving()
        preview.hide()
        panel?.orderOut(nil)
        panel = nil
        belt = nil
    }

    // MARK: 자리 · 숨었다 올라오기

    private var shown = true
    private var outSince: Date?
    var menuOpen = false
    var dragging = false

    private var screen: NSScreen? { NSScreen.screens.first }
    private func frame(shown s: Bool) -> NSRect {
        guard let vf = screen?.visibleFrame else { return .zero }
        let h = BeltView.height * BeltView.scale
        return NSRect(x: vf.minX, y: s ? vf.minY : vf.minY - h, width: vf.width, height: h)
    }

    /// 주 모니터의 보이는 영역 맨 아래 (Dock 이 있으면 그 위)
    func place() {
        guard let p = panel else { return }
        p.setFrame(frame(shown: true), display: true)
        belt?.layoutBelt()
        if !shown { p.orderOut(nil) }
    }

    func reveal() {
        guard let p = panel, !shown else { return }
        shown = true
        outSince = nil
        p.setFrame(frame(shown: false), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame(shown: true), display: true)
        }
    }

    func hideBelt() {
        guard let p = panel, shown else { return }
        shown = false
        preview.hide()
        belt?.mouseLeft()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(frame(shown: false), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.shown else { return }
                p.orderOut(nil)
                p.setFrame(self.frame(shown: true), display: false)
            }
        })
    }

    var isShown: Bool { shown && panel != nil }

    /// 0.1 초마다: 숨어 있을 때 마우스가 화면 맨 아래에 닿으면 올라오고, 띠를 벗어나 잠시 지나면 내려감
    private func checkEdge() {
        guard panel != nil, on(.autoHide), let s = screen else { return }
        let m = NSEvent.mouseLocation
        if !shown {
            if m.y <= s.frame.minY + 1.5, m.x >= s.frame.minX, m.x <= s.frame.maxX { reveal() }
            return
        }
        let area = frame(shown: true).insetBy(dx: 0, dy: -12)
        if area.contains(m) || menuOpen || dragging { outSince = nil; return }
        if outSince == nil { outSince = Date() }
        if Date().timeIntervalSince(outSince!) > 0.7 { hideBelt() }
    }

    // MARK: 접시 목록 · 3초마다 갱신 (메모리 · 안 쓴 시간 · 알림 숫자 · 계산서)

    var lastUsed: [pid_t: Date] = [:]

    func reload() {
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        let apps = NSWorkspace.shared.runningApplications.filter { a in
            guard a.activationPolicy == .regular, a.processIdentifier != me,
                  let id = a.bundleIdentifier, seen.insert(id).inserted else { return false }
            return true
        }
        for a in apps where lastUsed[a.processIdentifier] == nil { lastUsed[a.processIdentifier] = Date() }
        belt?.setApps(apps)
        refreshSlow()
    }

    private var memBusy = false
    func refreshSlow() {
        guard let b = belt else { return }
        if let f = NSWorkspace.shared.frontmostApplication { lastUsed[f.processIdentifier] = Date() }
        b.setAges(lastUsed)
        b.setBadges(on(.badge) ? Self.dockBadges() : [:])
        b.setBill(nowPlaying())
        let pids = Set(b.pids)
        guard !pids.isEmpty, !memBusy else { return }
        memBusy = true
        DispatchQueue.global(qos: .utility).async {
            let m = AppMemory.snapshot(apps: pids)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.memBusy = false
                self.belt?.setMemory(m)
            } }
        }
    }

    /// Dock 아이콘의 빨간 숫자 (앱 이름 → 숫자). 손쉬운 사용 권한이 있을 때만
    static func dockBadges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        func kids(_ e: AXUIElement) -> [AXUIElement] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
            return v as? [AXUIElement] ?? []
        }
        func str(_ e: AXUIElement, _ k: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success else { return nil }
            return v as? String
        }
        var out: [String: String] = [:]
        for list in kids(AXUIElementCreateApplication(dock.processIdentifier)) {
            for item in kids(list) {
                if let t = str(item, kAXTitleAttribute), let b = str(item, "AXStatusLabel"), !b.isEmpty { out[t] = b }
            }
        }
        return out
    }

    // MARK: 창 미리보기

    let preview = SushiPreview()
}

/// 접시 위에 뜨는 창 미리보기 (작은 떠 있는 창, 마우스는 통과)
@MainActor
final class SushiPreview {
    private var panel: NSPanel?
    private let img = CALayer()
    private var cache: [pid_t: (Date, CGImage)] = [:]
    private var want: pid_t?

    /// pid 앱의 가장 큰 창을 찍어서 screenPt(가운데 아래) 위에 띄움
    func show(pid: pid_t, at screenPt: NSPoint) {
        want = pid
        if let c = cache[pid], Date().timeIntervalSince(c.0) < 4 { present(c.1, at: screenPt); return }
        Task { @MainActor in
            let image = await Self.capture(pid: pid)
            if let image { self.cache[pid] = (Date(), image) }
            guard self.want == pid, let image else { return }
            self.present(image, at: screenPt)
        }
    }

    func hide() {
        want = nil
        panel?.orderOut(nil)
    }

    private func present(_ image: CGImage, at pt: NSPoint) {
        let maxW: CGFloat = 300, maxH: CGFloat = 190
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = min(maxW / iw, maxH / ih)
        let size = NSSize(width: max(60, iw * k), height: max(40, ih * k))
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
            v.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            img.contentsGravity = .resizeAspect
            v.layer?.addSublayer(img)
            p.contentView = v
            panel = p
        }
        guard let p = panel else { return }
        var f = NSRect(x: pt.x - size.width / 2, y: pt.y, width: size.width, height: size.height)
        if let s = NSScreen.screens.first(where: { NSMouseInRect(pt, $0.frame, false) }) ?? NSScreen.screens.first {
            f.origin.x = min(max(f.minX, s.frame.minX + 6), s.frame.maxX - f.width - 6)
        }
        p.setFrame(f, display: true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        img.frame = CGRect(origin: .zero, size: size)
        img.contents = image
        CATransaction.commit()
        p.orderFrontRegardless()
    }

    static func capture(pid: pid_t) async -> CGImage? {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ws = c.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80 }
            guard let w = ws.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
            let cfg = SCStreamConfiguration()
            let k = min(1, 600 / w.frame.width)
            cfg.width = Int(w.frame.width * k)
            cfg.height = Int(w.frame.height * k)
            cfg.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        } catch {
            return nil
        }
    }
}

/// 접시 하나 = 앱 하나
@MainActor
private final class Plate {
    let app: NSRunningApplication
    let root = CALayer()          // 위치 · 크기(원근)는 이 층으로
    let body = CALayer()          // 나오고 들어가는 연출 · 끌기 흔들기는 이 층으로
    let rim = CAShapeLayer()      // 접시 테두리 (색 = 메모리)
    let dish = CAShapeLayer()     // 접시 안쪽
    let icon = CALayer()
    let steam = CAEmitterLayer()  // 방금 쓴 앱: 김
    let badge = CALayer()         // 알림 뚜껑
    let badgeText = CATextLayer()
    var bytes: UInt64?
    var idleMin: Double = 0       // 안 쓴 지 몇 분
    var staleOn = true
    var depthScale: CGFloat = 1   // 뒤쪽일수록 작게
    var s: CGFloat?               // 트랙 위 지금 자리 (목표 자리로 부드럽게 따라감)

    init(app: NSRunningApplication, scale: CGFloat) {
        self.app = app
        let w = BeltView.plateW, h = BeltView.plateH
        root.bounds = CGRect(x: 0, y: 0, width: w, height: BeltView.rootH)
        root.anchorPoint = CGPoint(x: 0.5, y: (BeltView.plateY + h / 2) / BeltView.rootH)
        body.frame = root.bounds
        root.addSublayer(body)
        // 비스듬히 본 둥근 접시
        let plateRect = CGRect(x: 0, y: BeltView.plateY, width: w, height: h)
        rim.path = CGPath(ellipseIn: plateRect, transform: nil)
        rim.shadowColor = NSColor.black.cgColor
        rim.shadowOpacity = 0.35
        rim.shadowRadius = 2
        rim.shadowOffset = CGSize(width: 0, height: -1.5)
        dish.path = CGPath(ellipseIn: plateRect.insetBy(dx: 7, dy: 4), transform: nil)
        dish.fillColor = NSColor(white: 0.97, alpha: 1).cgColor
        dish.strokeColor = NSColor(white: 0, alpha: 0.12).cgColor
        dish.lineWidth = 0.6
        let sz = BeltView.iconSize
        icon.frame = CGRect(x: (w - sz) / 2, y: BeltView.plateY + h * 0.38, width: sz, height: sz)
        icon.contentsScale = scale
        if let img = app.icon { icon.contents = img.layerContents(forContentsScale: scale) }
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.3
        icon.shadowRadius = 2
        icon.shadowOffset = CGSize(width: 0, height: -2)
        // 김: 아이콘 위에서 하얀 연기가 천천히 올라감
        steam.emitterPosition = CGPoint(x: w / 2, y: icon.frame.maxY - 4)
        steam.emitterShape = .line
        steam.emitterSize = CGSize(width: sz * 0.6, height: 1)
        let c = CAEmitterCell()
        c.contents = Self.puff
        c.birthRate = 3
        c.lifetime = 1.6
        c.velocity = 12
        c.velocityRange = 4
        c.emissionLongitude = .pi / 2
        c.emissionRange = 0.3
        c.scale = 0.5
        c.scaleSpeed = 0.35
        c.alphaSpeed = -0.45
        c.color = NSColor(white: 0.8, alpha: 0.6).cgColor
        steam.emitterCells = [c]
        steam.birthRate = 0
        // 알림 뚜껑: 아이콘 오른쪽 위 빨간 알약
        badge.backgroundColor = NSColor.systemRed.cgColor
        badge.borderColor = NSColor.white.cgColor
        badge.borderWidth = 1.5
        badge.isHidden = true
        badgeText.fontSize = 11
        badgeText.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badgeText.contentsScale = scale
        badge.addSublayer(badgeText)
        body.addSublayer(rim)
        body.addSublayer(dish)
        body.addSublayer(icon)
        body.addSublayer(steam)
        body.addSublayer(badge)
        setColor()
    }

    static let puff: CGImage? = {
        let n = 24
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                                 locations: [0, 1]) else { return nil }
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()
    }()

    /// 메모리에 따라 접시 색 (모르면 흰 접시). 오래 안 쓴 앱은 색이 바램
    func setColor() {
        let mb = Double(bytes ?? 0) / 1_048_576
        var c: NSColor
        switch mb {
        case ..<300: c = NSColor(white: 0.88, alpha: 1)
        case ..<1024: c = NSColor(red: 0.30, green: 0.70, blue: 0.40, alpha: 1)
        case ..<2048: c = NSColor(red: 0.96, green: 0.78, blue: 0.20, alpha: 1)
        case ..<4096: c = NSColor(red: 0.88, green: 0.25, blue: 0.22, alpha: 1)
        default: c = NSColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1)
        }
        let cold = staleOn ? min(1, max(0, (idleMin - 10) / 40)) : 0   // 10분부터 식기 시작, 50분이면 다 식음
        if cold > 0 { c = c.blended(withFraction: cold * 0.6, of: NSColor(white: 0.55, alpha: 1)) ?? c }
        rim.fillColor = c.cgColor
        rim.strokeColor = c.shadow(withLevel: 0.25)?.cgColor
        rim.lineWidth = 1
        icon.opacity = Float(1 - cold * 0.5)
        steam.birthRate = staleOn && idleMin < 2 ? 1 : 0
    }

    func setBadge(_ text: String?) {
        guard let text, !text.isEmpty else { badge.isHidden = true; return }
        let t = text.count > 3 ? "99+" : text
        // 띠를 줄여도 숫자는 읽히게: 줄인 만큼 조금 키움
        let f = min(1.6, max(1, 0.8 / BeltView.scale))
        let font = NSFont.systemFont(ofSize: 11 * f, weight: .bold)
        let w = max(18 * f, ceil(t.size(withAttributes: [.font: font]).width) + 10 * f)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        badgeText.fontSize = 11 * f
        badge.bounds = CGRect(x: 0, y: 0, width: w, height: 18 * f)
        badge.cornerRadius = 9 * f
        badge.position = CGPoint(x: icon.frame.maxX - 2, y: icon.frame.maxY - 3)
        badgeText.frame = CGRect(x: 0, y: 2 * f, width: w, height: 14 * f)
        badgeText.string = t
        let wasHidden = badge.isHidden
        badge.isHidden = false
        CATransaction.commit()
        if wasHidden {
            let a = CASpringAnimation(keyPath: "transform.scale")
            a.fromValue = 0.2; a.toValue = 1; a.damping = 9
            a.duration = a.settlingDuration
            badge.add(a, forKey: "pop")
        }
    }

    var plateName: String { app.localizedName ?? app.bundleIdentifier ?? "" }

    /// "23분 안 씀" 같은 말 (10분 아래면 빈칸)
    var idleText: String {
        guard idleMin >= 10 else { return "" }
        if idleMin < 60 { return " · \(Int(idleMin))분 안 씀" }
        return String(format: " · %.0f시간 안 씀", idleMin / 60)
    }
}

@MainActor
private final class BeltView: NSView {
    static let height: CGFloat = 190   // 창 높이 (트랙 + 뒤쪽 접시 + 이름표)
    static let rootH: CGFloat = 84     // 접시 한 장 층 높이
    static let ringW: CGFloat = 34     // 띠 폭
    static let plateW: CGFloat = 76
    static let plateH: CGFloat = 30
    static let plateY: CGFloat = 16
    static let iconSize: CGFloat = 46
    static let gap: CGFloat = 28
    /// 띠 전체를 줄이는 배율 (글자 · 이름표는 그대로 읽히게 안 줄임)
    static var scale: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "sushiSize") as? Double ?? 0.6) }
    private var k: CGFloat { Self.scale }
    /// 줄이기 전 크기로 본 이 뷰의 영역 (트랙 · 접시는 이 좌표로 계산)
    private var lb: CGRect { CGRect(x: 0, y: 0, width: bounds.width / k, height: bounds.height / k) }
    private let stage = CALayer()
    private func lp(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: p.x / k, y: p.y / k)
    }

    weak var owner: SushiBelt?
    var speed: CGFloat = 40
    private var plates: [Plate] = []
    private var offset: CGFloat = 0
    private var hovered: Plate?
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    // 트랙: 옆면(두께) · 윗면 · 흘러가는 마디 무늬
    private let side = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let slats = CAShapeLayer()
    // 경기장 트랙: 앞 · 뒤는 곧은 길(길이 half*2), 양 끝은 눕힌 반원(가로 rx, 세로 rb)
    private var center = CGPoint.zero, half: CGFloat = 0, rx: CGFloat = 0, rb: CGFloat = 0
    private var arc: [(t: CGFloat, s: CGFloat)] = []   // 위치 t(0~4) → 둘레 길이 표 (일정한 속도로 돌게)
    private var perimeter: CGFloat = 1
    private let plateLayer = CALayer()
    private let label = CATextLayer()
    private let labelBG = CALayer()
    private let bill = CATextLayer()   // 트랙 안쪽 계산서
    private let billBG = CALayer()

    var pids: [pid_t] { plates.map(\.app.processIdentifier) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let L = layer!
        side.fillColor = NSColor(white: 0.07, alpha: 0.95).cgColor
        side.fillRule = .evenOdd
        ring.fillColor = NSColor(white: 0.20, alpha: 0.95).cgColor
        ring.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
        ring.lineWidth = 1
        ring.fillRule = .evenOdd
        slats.fillColor = nil
        slats.strokeColor = NSColor(white: 1, alpha: 0.07).cgColor
        slats.lineWidth = Self.ringW - 6
        slats.lineDashPattern = [2, 18]
        bill.fontSize = 12
        bill.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        bill.foregroundColor = NSColor(white: 1, alpha: 0.85).cgColor
        bill.alignmentMode = .center
        bill.shadowColor = NSColor.black.cgColor
        bill.shadowOpacity = 0.8
        bill.shadowRadius = 2
        bill.shadowOffset = .zero
        L.addSublayer(billBG)   // 계산서는 접시 아래에 (지나가는 접시가 위로 지나감)
        L.addSublayer(stage)
        stage.addSublayer(side)
        stage.addSublayer(ring)
        stage.addSublayer(slats)
        billBG.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        billBG.cornerRadius = 9
        billBG.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        billBG.borderWidth = 1
        billBG.addSublayer(bill)
        stage.addSublayer(plateLayer)
        labelBG.backgroundColor = NSColor(white: 0.08, alpha: 0.9).cgColor
        labelBG.cornerRadius = 7
        labelBG.isHidden = true
        label.fontSize = 12
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        labelBG.addSublayer(label)
        L.addSublayer(labelBG)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        label.contentsScale = s
        bill.contentsScale = s
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func layoutBelt() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.frame = bounds
        stage.anchorPoint = .zero
        stage.bounds = lb
        stage.position = .zero
        stage.transform = CATransform3DMakeScale(k, k, 1)
        // 띠 가운데 선 = 경기장 트랙
        let w = Self.ringW, wy = w * 0.4
        rx = 64
        rb = 40
        half = max(20, lb.width / 2 - rx - w / 2 - 8)
        center = CGPoint(x: lb.midX, y: 14 + wy + rb)
        // 둥근 모서리 사각형의 모서리를 반원 크기로 = 양 끝이 눕힌 반원인 트랙
        func track(_ c: CGPoint, grow gx: CGFloat, _ gy: CGFloat) -> CGPath {
            let r = CGRect(x: c.x - half - rx - gx, y: c.y - rb - gy, width: (half + rx + gx) * 2, height: (rb + gy) * 2)
            return CGPath(roundedRect: r, cornerWidth: rx + gx, cornerHeight: rb + gy, transform: nil)
        }
        func band(_ c: CGPoint) -> CGPath {
            let p = CGMutablePath()
            p.addPath(track(c, grow: w / 2, wy))
            p.addPath(track(c, grow: -w / 2, -wy))
            return p
        }
        for l in [side, ring, slats, plateLayer] as [CALayer] { l.frame = lb }
        side.path = band(CGPoint(x: center.x, y: center.y - 8))   // 아래로 조금 내린 그림자 = 띠 두께
        ring.path = band(center)
        // 위치별 둘레 길이 표 + 마디 무늬 길 (접시와 같은 방향으로 그려야 무늬도 같이 흐름)
        arc = []
        let line = CGMutablePath()
        var acc: CGFloat = 0, prev = point(0)
        line.move(to: prev)
        let n = 2000
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 4
            let q = point(t)
            line.addLine(to: q)
            acc += hypot(q.x - prev.x, q.y - prev.y)
            arc.append((t, acc))
            prev = q
        }
        line.closeSubpath()
        slats.path = line
        perimeter = max(1, acc)
        CATransaction.commit()
        positionPlates(ease: 1)
    }

    func featuresChanged() {
        let staleOn = owner?.on(.stale) ?? true
        for p in plates { p.staleOn = staleOn; p.setColor() }
        billBG.isHidden = !(owner?.on(.bill) ?? true)
    }

    func setApps(_ apps: [NSRunningApplication]) {
        let scale = window?.backingScaleFactor ?? 2
        let animate = owner?.on(.entrance) ?? true
        let firstLoad = plates.isEmpty
        // 이미 있는 접시는 그대로 두고 (흘러가던 자리 유지) 새 앱만 추가 · 꺼진 앱만 뺌
        let keep = Set(apps.map(\.processIdentifier))
        for p in plates where !keep.contains(p.app.processIdentifier) { leave(p, animate: animate) }
        plates.removeAll { !keep.contains($0.app.processIdentifier) }
        let have = Set(plates.map(\.app.processIdentifier))
        var added = 0
        for a in apps where !have.contains(a.processIdentifier) {
            let p = Plate(app: a, scale: scale)
            p.staleOn = owner?.on(.stale) ?? true
            plates.append(p)
            plateLayer.addSublayer(p.root)
            if animate { enter(p, delay: firstLoad ? Double(added) * 0.06 : 0) }
            added += 1
        }
        if let h = hovered, !plates.contains(where: { $0 === h }) { hovered = nil; labelBG.isHidden = true }
        positionPlates(ease: firstLoad ? 1 : 0)
        updateBill()
    }

    /// 새 접시: 위(주방)에서 내려와 통 튀며 놓임
    private func enter(_ p: Plate, delay: Double) {
        let t = CACurrentMediaTime() + delay
        let drop = CASpringAnimation(keyPath: "transform.translation.y")
        drop.fromValue = 60; drop.toValue = 0; drop.damping = 11; drop.stiffness = 180
        drop.duration = drop.settlingDuration; drop.beginTime = t; drop.fillMode = .backwards
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25; fade.beginTime = t; fade.fillMode = .backwards
        p.body.add(drop, forKey: "drop")
        p.body.add(fade, forKey: "fade")
    }

    /// 꺼진 앱 접시: 위로 들려 사라짐
    private func leave(_ p: Plate, animate: Bool) {
        if p === hovered { hovered = nil; labelBG.isHidden = true }
        guard animate else { p.root.removeFromSuperlayer(); return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setCompletionBlock { p.root.removeFromSuperlayer() }
        p.body.opacity = 0
        p.body.transform = CATransform3DMakeTranslation(0, 50, 0)
        CATransaction.commit()
    }

    func setMemory(_ m: [pid_t: UInt64]) {
        for p in plates { p.bytes = m[p.app.processIdentifier]; p.setColor() }
        if let h = hovered { showLabel(h) }
        updateBill()
    }

    func setAges(_ used: [pid_t: Date]) {
        let now = Date()
        for p in plates {
            p.idleMin = used[p.app.processIdentifier].map { now.timeIntervalSince($0) / 60 } ?? 0
            p.setColor()
        }
    }

    private var badgeNames: [String: String] = [:]
    func setBadges(_ b: [String: String]) {
        badgeNames = b
        for p in plates { p.setBadge(b[p.plateName]) }
    }

    private var song: String?
    func setBill(_ s: String?) { song = s; updateBill() }
    private func updateBill() {
        billBG.isHidden = !(owner?.on(.bill) ?? true)
        let total = plates.compactMap(\.bytes).reduce(0, +)
        var t = "🧾 계산서 · 접시 \(plates.count)개" + (total > 0 ? " · 합계 \(AppMemory.text(total))" : "")
        let unread = plates.filter { !$0.badge.isHidden }.count
        if unread > 0 { t += " · 알림 \(unread)곳" }
        if let s = song, !s.isEmpty { t += "   ♪ " + s }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bill.string = t
        let lines = t.split(separator: "\n")
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = min(half * 2 * k, (lines.map { ceil(String($0).size(withAttributes: [.font: font]).width) }.max() ?? 0) + 24)
        let h = CGFloat(lines.count) * 16 + 4
        billBG.frame = CGRect(x: center.x * k - w / 2, y: center.y * k - h / 2, width: w, height: h)
        bill.frame = CGRect(x: 0, y: 2, width: w, height: h - 4)
        CATransaction.commit()
    }

    /// 트랙 위 위치 t (0~4): 0~1 앞 곧은 길 왼→오, 1~2 오른쪽 반원, 2~3 뒤 곧은 길 오→왼, 3~4 왼쪽 반원
    private func point(_ t: CGFloat) -> CGPoint {
        let t = t.truncatingRemainder(dividingBy: 4)
        switch t {
        case ..<1: return CGPoint(x: center.x - half + 2 * half * t, y: center.y - rb)
        case ..<2: let a = -CGFloat.pi / 2 + .pi * (t - 1)
            return CGPoint(x: center.x + half + rx * cos(a), y: center.y + rb * sin(a))
        case ..<3: return CGPoint(x: center.x + half - 2 * half * (t - 2), y: center.y + rb)
        default: let a = CGFloat.pi / 2 + .pi * (t - 3)
            return CGPoint(x: center.x - half + rx * cos(a), y: center.y + rb * sin(a))
        }
    }
    /// 둘레 길이 s → 트랙 위치
    private func angle(_ s: CGFloat) -> CGFloat {
        guard arc.count > 1 else { return 0 }
        var lo = 0, hi = arc.count - 1
        while lo < hi { let m = (lo + hi) / 2; if arc[m].s < s { lo = m + 1 } else { hi = m } }
        return arc[lo].t
    }

    /// ease: 목표 자리로 얼마나 다가갈지 (1 = 바로, 작을수록 천천히 → 접시가 늘고 줄 때 부드럽게 다시 벌어짐)
    private func positionPlates(ease: CGFloat) {
        guard !plates.isEmpty else { return }
        // 한 바퀴에 고르게 놓음. 너무 많으면 접시를 조금 줄임
        let sp = perimeter / CGFloat(plates.count)
        let fit = min(1, sp / (Self.plateW + Self.gap * 0.4))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, p) in plates.enumerated() {
            var target = (CGFloat(i) * sp + offset).truncatingRemainder(dividingBy: perimeter)
            if target < 0 { target += perimeter }
            if let cur = p.s {
                var diff = (target - cur).truncatingRemainder(dividingBy: perimeter)
                if diff > perimeter / 2 { diff -= perimeter } else if diff < -perimeter / 2 { diff += perimeter }
                var nxt = (cur + diff * ease).truncatingRemainder(dividingBy: perimeter)
                if nxt < 0 { nxt += perimeter }
                p.s = nxt
            } else {
                p.s = target
            }
            guard p !== dragPlate else { continue }
            let q = point(angle(p.s ?? target))
            let back = (q.y - (center.y - rb)) / (2 * rb)      // 0 = 맨 앞, 1 = 맨 뒤
            p.depthScale = (1 - 0.3 * back) * fit
            p.root.position = q
            let k = p.depthScale * (p === hovered ? 1.18 : 1)
            p.root.transform = CATransform3DMakeScale(k, k, 1)
            p.root.zPosition = p === hovered ? 1000 : 500 - q.y   // 앞(아래) 접시가 위에 그려짐
        }
        // 띠 마디도 같은 속도로
        slats.lineDashPhase = -offset
        if let h = hovered { placeLabel(h) }
        CATransaction.commit()
    }

    func startMoving() {
        timer?.invalidate()
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stopMoving() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.1)
        last = now
        guard window?.isVisible == true else { return }   // 숨어 있을 땐 쉼
        if hovered == nil && dragPlate == nil && speed > 0 { offset += speed * CGFloat(dt) }
        positionPlates(ease: min(1, CGFloat(dt) * 5))
    }

    // MARK: 마우스

    private func plate(at pt: NSPoint) -> Plate? {
        // 앞에 그려진 접시부터
        for p in plates.sorted(by: { $0.root.zPosition > $1.root.zPosition }) where p !== dragPlate {
            let f = p.root.frame.insetBy(dx: 6 * p.depthScale, dy: 0)
            let top = f.minY + (Self.plateY + Self.plateH * 0.38 + Self.iconSize + 4) * p.depthScale * (p === hovered ? 1.18 : 1)
            if f.contains(pt) && pt.y <= top { return p }
        }
        return nil
    }

    private var previewWork: DispatchWorkItem?

    private func setHover(_ p: Plate?) {
        guard p !== hovered else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if let h = hovered {
            h.root.transform = CATransform3DMakeScale(h.depthScale, h.depthScale, 1)
            h.root.zPosition = 500 - h.root.position.y
        }
        hovered = p
        if let p {
            p.root.transform = CATransform3DMakeScale(p.depthScale * 1.18, p.depthScale * 1.18, 1)
            p.root.zPosition = 1000
            showLabel(p)
        } else {
            labelBG.isHidden = true
        }
        CATransaction.commit()
        if p == nil { last = CACurrentMediaTime() }
        // 창 미리보기: 잠깐 머물면 띄움
        previewWork?.cancel()
        owner?.preview.hide()
        if let p, owner?.on(.preview) == true {
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovered === p, self.dragPlate == nil, let win = self.window else { return }
                    let local = CGPoint(x: self.labelBG.position.x, y: self.labelBG.frame.maxY + 4)
                    let sp = win.convertPoint(toScreen: self.convert(local, to: nil))
                    self.owner?.preview.show(pid: p.app.processIdentifier, at: sp)
                }
            }
            previewWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        }
    }

    func mouseLeft() { setHover(nil) }

    private func showLabel(_ p: Plate, text: String? = nil, color: NSColor? = nil) {
        let mem = p.bytes.map { " · " + AppMemory.text($0) } ?? ""
        let idle = (owner?.on(.stale) ?? true) ? p.idleText : ""
        let cold = (owner?.on(.stale) ?? true) && p.idleMin >= 30 && (p.bytes ?? 0) >= 1 << 30 ? "🧊 " : ""
        label.string = text ?? (cold + p.plateName + mem + idle)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let w = ceil((label.string as! String).size(withAttributes: [.font: font]).width) + 18
        CATransaction.begin(); CATransaction.setDisableActions(true)
        labelBG.backgroundColor = (color ?? NSColor(white: 0.08, alpha: 0.9)).cgColor
        labelBG.bounds = CGRect(x: 0, y: 0, width: w, height: 20)
        label.frame = CGRect(x: 0, y: 2, width: w, height: 16)
        labelBG.isHidden = false
        labelBG.zPosition = 2000
        placeLabel(p)
        CATransaction.commit()
    }

    private func placeLabel(_ p: Plate) {
        let w = labelBG.bounds.width
        let x = min(max(p.root.position.x * k, w / 2 + 4), bounds.width - w / 2 - 4)
        let top = (p.root.frame.minY + (Self.plateY + Self.plateH * 0.38 + Self.iconSize) * p.depthScale * 1.18) * k
        labelBG.position = CGPoint(x: x, y: min(top + 13, bounds.height - 11))
    }

    override func mouseMoved(with e: NSEvent) {
        guard dragPlate == nil else { return }
        setHover(plate(at: lp(e)))
    }
    override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseExited(with e: NSEvent) { if dragPlate == nil { setHover(nil) } }

    // 끌기: 위로 올려 놓으면 열기, 아래 끝으로 내려 놓으면 종료
    private var downPt: NSPoint?
    private var downPlate: Plate?
    private var dragPlate: Plate?
    private enum DropAction { case none, open, quit }
    private func dropAction(_ pt: NSPoint) -> DropAction {
        if pt.y >= lb.height - 24 { return .open }
        if pt.y <= 6 { return .quit }
        return .none
    }

    override func mouseDown(with e: NSEvent) {
        downPt = lp(e)
        downPlate = plate(at: downPt!)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let p = downPlate, let d0 = downPt, owner?.on(.drag) == true else { return }
        let pt = lp(e)
        if dragPlate == nil {
            guard hypot(pt.x - d0.x, pt.y - d0.y) > 5 else { return }
            dragPlate = p
            owner?.dragging = true
            previewWork?.cancel()
            owner?.preview.hide()
        }
        let y = min(max(pt.y - 20, 10), lb.height - 60)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        p.root.position = CGPoint(x: min(max(pt.x, 30), lb.width - 30), y: y)
        p.root.transform = CATransform3DMakeScale(1.15, 1.15, 1)
        p.root.zPosition = 1500
        CATransaction.commit()
        switch dropAction(pt) {
        case .open: showLabel(p, text: "놓으면 열기 · \(p.plateName)", color: NSColor.systemBlue.withAlphaComponent(0.9))
        case .quit: showLabel(p, text: "놓으면 종료 · \(p.plateName)", color: NSColor.systemRed.withAlphaComponent(0.9))
        case .none: showLabel(p, text: "위로 올리면 열기 · 아래 끝으로 내리면 종료")
        }
    }

    override func mouseUp(with e: NSEvent) {
        let pt = lp(e)
        defer { downPlate = nil; downPt = nil }
        if let p = dragPlate {
            dragPlate = nil
            owner?.dragging = false
            let id = p.app.bundleIdentifier
            switch dropAction(pt) {
            case .open: if let id { owner?.open(id) }
            case .quit:
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                a.values = [0, -8, 8, -6, 6, 0]; a.duration = 0.3
                p.body.add(a, forKey: "shake")
                if let id { owner?.quit(id) }
            case .none: break
            }
            // 원래 자리로 미끄러져 돌아감
            let from = p.root.position
            positionPlates(ease: 0)
            let to = p.root.position
            let back = CABasicAnimation(keyPath: "position")
            back.fromValue = NSValue(point: NSPoint(x: from.x - to.x, y: from.y - to.y))
            back.toValue = NSValue(point: .zero)
            back.isAdditive = true
            back.duration = 0.25
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.root.add(back, forKey: "back")
            hovered = nil
            setHover(plate(at: pt))
            return
        }
        guard let p = plate(at: pt), p === downPlate, let id = p.app.bundleIdentifier else { return }
        // 살짝 튀어 오르는 느낌
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, 8, 0]; a.duration = 0.25
        p.body.add(a, forKey: "bump")
        owner?.open(id)
    }

    override func rightMouseDown(with e: NSEvent) {
        let pt = lp(e)
        let m = NSMenu()
        if let p = plate(at: pt), let id = p.app.bundleIdentifier {
            m.addItem(NSMenuItem(title: p.plateName + (p.bytes.map { " · " + AppMemory.text($0) } ?? "") + p.idleText, action: nil, keyEquivalent: ""))
            if p.idleMin >= 30 && (p.bytes ?? 0) >= 1 << 30 {
                m.addItem(NSMenuItem(title: "🧊 오래 안 썼는데 메모리를 많이 써요 — 꺼도 될 것 같아요", action: nil, keyEquivalent: ""))
            }
            m.addItem(.separator())
            m.addItem(MenuAction("앞으로 가져오기") { [weak self] in self?.owner?.open(id) })
            m.addItem(MenuAction("가리기") { p.app.hide() })
            m.addItem(MenuAction("이 앱 창을 PIP로 띄우기…") { WindowPiP.shared.showPicker(from: nil, onlyPID: p.app.processIdentifier) })
            m.addItem(MenuAction("종료") { [weak self] in self?.owner?.quit(id) })
            m.addItem(.separator())
        }
        let sp = NSMenuItem(title: "도는 속도", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, v) in [("멈춤", 0.0), ("느리게", 20.0), ("보통", 40.0), ("빠르게", 80.0)] as [(String, CGFloat)] {
            let i = MenuAction(t) { SushiBelt.shared.speed = v }
            i.state = abs((owner?.speed ?? 40) - v) < 0.5 ? .on : .off
            sub.addItem(i)
        }
        sp.submenu = sub
        m.addItem(sp)
        let sz = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
        let szm = NSMenu()
        for (t, v) in [("아주 작게", 0.45), ("작게", 0.6), ("보통", 0.8), ("크게", 1.0)] {
            let i = MenuAction(t) { SushiBelt.shared.size = v }
            i.state = abs(SushiBelt.shared.size - v) < 0.01 ? .on : .off
            szm.addItem(i)
        }
        sz.submenu = szm
        m.addItem(sz)
        let feat = NSMenuItem(title: "기능", action: nil, keyEquivalent: "")
        let fm = NSMenu()
        for f in SushiBelt.Feature.allCases {
            let i = MenuAction(f.title) { SushiBelt.shared.toggle(f) }
            i.state = (owner?.on(f) ?? true) ? .on : .off
            fm.addItem(i)
        }
        feat.submenu = fm
        m.addItem(feat)
        let legend = NSMenuItem(title: "접시 색 = 메모리", action: nil, keyEquivalent: "")
        let lg = NSMenu()
        for t in ["흰 접시 · 300MB 아래", "초록 · 1GB 아래", "노랑 · 2GB 아래", "빨강 · 4GB 아래", "금색 · 4GB 넘음",
                  "색이 바래고 흐림 · 오래 안 씀", "김이 남 · 방금 씀"] {
            lg.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: ""))
        }
        legend.submenu = lg
        m.addItem(legend)
        m.addItem(MenuAction("회전 초밥 끄기") { SushiBelt.shared.enabled = false })
        owner?.menuOpen = true
        previewWork?.cancel()
        owner?.preview.hide()
        NSMenu.popUpContextMenu(m, with: e, for: self)
        owner?.menuOpen = false
    }

    override func scrollWheel(with e: NSEvent) {
        // 스크롤로 띠를 직접 돌림 (가로 · 세로 둘 다)
        let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : -e.scrollingDeltaY
        offset += dx * (e.hasPreciseScrollingDeltas ? 1 : 8)
        positionPlates(ease: 1)
        setHover(plate(at: lp(e)))
    }
}
