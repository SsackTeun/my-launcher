// 막대 자리 비워 두기 (옵션): 다른 앱 창이 자주 쓰는 앱 막대 자리를 침범하면 막대 옆까지 밀거나 줄임
// macOS 는 Dock · 메뉴 막대만 화면 자리를 예약할 수 있어서, 창 정리 앱처럼 손쉬운 사용(AX) 으로 창을 옮기는 방식
// - 0.4초마다 맨 앞 앱의 창을 보고, 막대 자리와 겹치면 고침 (마우스로 끄는 중엔 기다림)
// - 창이 남은 자리에 들어가면 옆으로 밀고, 더 크면(최대화 등) 남은 자리 크기로 줄임
// - 전체 화면 창 · 크기를 못 바꾸는 창 · 도구함 자신의 창은 건드리지 않음
// - 접어 둔 막대는 자리를 비우지 않음
import Cocoa

@MainActor
enum BarReserve {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "favReserve") }
        set {
            UserDefaults.standard.set(newValue, forKey: "favReserve")
            newValue ? start() : stop()
            FavBar.shared.onChange()
        }
    }
    static let gap: CGFloat = 8
    private static var timer: Timer?

    static func start() {
        guard enabled, timer == nil else { return }
        let t = Timer(timeInterval: 0.4, repeats: true) { _ in MainActor.assumeIsolated { BarReserve.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 데스크탑을 넘기면 (그 데스크탑 창들은 그때서야 보이므로) 보이는 창 모두 한 번 검사
        if spaceObs == nil {
            spaceObs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                for d in [0.3, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { MainActor.assumeIsolated { BarReserve.fixVisible() } }
                }
            }
        }
        fixAll()
    }
    private static var spaceObs: NSObjectProtocol?
    private static var ticks = 0

    /// 지금 화면에 보이는 창 중 막대 자리와 겹치는 창의 앱만 골라 고침 (맨 앞 앱이 아니어도)
    static func fixVisible() {
        guard enabled, !Spaces.moving, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0 else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids = Set<pid_t>()
        for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, !pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 120, r.height > 80 else { continue }
            let f = NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            if fitted(f) != nil { pids.insert(pid) }
        }
        pids.forEach(fix(pid:))
        fixOwn()
    }

    /// 도구함 창 · 떼어 낸 플레이어 창도 (화면 끝에 붙어 있지 않을 때) 막대 자리를 피해서
    static func fixOwn() {
        // 자유 모드면 도구함 창은 놓은 자리 그대로 (막대 위라도)
        guard enabled, EdgeDock.magnet, NSEvent.pressedMouseButtons == 0 else { return }
        for d in EdgeDock.all {
            guard let w = d.managedWindow, w.isVisible, d.side == nil, !d.ignores(w),
                  let nf = fitted(w.frame), nf.size == w.frame.size else { continue }   // 크기는 안 바꾸고 옮기기만
            w.setFrame(nf, display: true, animate: true)
        }
    }
    static func stop() { timer?.invalidate(); timer = nil }

    // MARK: 비워 둘 자리 (모니터마다 왼 · 오른 · 위 · 아래 두께)

    struct Insets { var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0 }

    /// 모니터 → 비워 둘 두께 (막대 두께 + 간격)
    static func insets() -> [(screen: NSScreen, ins: Insets)] {
        var out: [(NSScreen, Insets)] = []
        for s in NSScreen.screens {
            let vf = s.visibleFrame
            var ins = Insets()
            for b in FavBar.all {
                guard let p = b.panel, p.isVisible, !b.collapsed, vf.intersects(p.frame) else { continue }
                let f = p.frame
                switch b.edge {
                case .left: ins.left = max(ins.left, f.maxX - vf.minX + gap)
                case .right: ins.right = max(ins.right, vf.maxX - f.minX + gap)
                case .top: ins.top = max(ins.top, vf.maxY - f.minY + gap)
                case .bottom: ins.bottom = max(ins.bottom, f.maxY - vf.minY + gap)
                }
            }
            out.append((s, ins))
        }
        return out
    }

    /// 그 창이 쓸 수 있는 영역: 보이는 영역에서 막대 자리(켜져 있으면) 를 뺀 곳
    static func room(for f: NSRect) -> NSRect? {
        let all = insets()
        let c = NSPoint(x: f.midX, y: f.midY)
        guard let (s, ins0) = all.first(where: { NSMouseInRect(c, $0.screen.frame, false) }) ?? all.first else { return nil }
        let ins = enabled ? ins0 : Insets()
        let vf = s.visibleFrame
        return NSRect(x: vf.minX + ins.left, y: vf.minY + ins.bottom, width: vf.width - ins.left - ins.right, height: vf.height - ins.top - ins.bottom)
    }

    /// 창 frame (Cocoa 좌표) 을 막대 자리 밖으로. 고칠 필요 없으면 nil
    static func fitted(_ f: NSRect) -> NSRect? {
        let all = insets()
        // 창 가운데가 있는 모니터 (없으면 가장 많이 겹치는 모니터)
        let c = NSPoint(x: f.midX, y: f.midY)
        guard let (s, ins) = all.first(where: { NSMouseInRect(c, $0.screen.frame, false) })
                ?? all.max(by: { $0.screen.frame.intersection(f).width * $0.screen.frame.intersection(f).height
                                < $1.screen.frame.intersection(f).width * $1.screen.frame.intersection(f).height }) else { return nil }
        let vf = s.visibleFrame
        let room = NSRect(x: vf.minX + ins.left, y: vf.minY + ins.bottom,
                          width: vf.width - ins.left - ins.right, height: vf.height - ins.top - ins.bottom)
        guard room.width > 200, room.height > 150 else { return nil }
        var r = f
        // 가로: 막대 자리에 걸치면 — 들어가면 밀고, 크면 남은 폭으로
        if (ins.left > 0 && r.minX < room.minX) || (ins.right > 0 && r.maxX > room.maxX) {
            if r.width <= room.width {
                if ins.left > 0 && r.minX < room.minX { r.origin.x = room.minX }
                if ins.right > 0 && r.maxX > room.maxX { r.origin.x = room.maxX - r.width }
            } else {
                r.origin.x = room.minX; r.size.width = room.width
            }
        }
        // 세로도 같은 방식
        if (ins.bottom > 0 && r.minY < room.minY) || (ins.top > 0 && r.maxY > room.maxY) {
            if r.height <= room.height {
                if ins.bottom > 0 && r.minY < room.minY { r.origin.y = room.minY }
                if ins.top > 0 && r.maxY > room.maxY { r.origin.y = room.maxY - r.height }
            } else {
                r.origin.y = room.minY; r.size.height = room.height
            }
        }
        return r.equalTo(f) ? nil : r
    }

    // MARK: 창 고치기 (손쉬운 사용)

    /// 맨 앞 앱의 창들
    private static func tick() {
        guard enabled, !Spaces.moving, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        fix(pid: app.processIdentifier)
        // 1.6초마다 화면에 보이는 다른 창들도
        ticks += 1
        if ticks % 4 == 0 { fixVisible() }
    }

    /// 켤 때 · 막대가 바뀔 때: 켜져 있는 모든 앱의 창
    static func fixAll() {
        guard enabled, !Spaces.moving, AXIsProcessTrusted() else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && a.processIdentifier != me {
            fix(pid: a.processIdentifier)
        }
    }

    /// 게임은 건드리지 않기 (옵션, 기본 켬): 게임 창을 밀거나 줄이면 화면이 깨지거나 클릭 자리가 어긋남
    static var skipGames: Bool {
        get { UserDefaults.standard.object(forKey: "reserveSkipGames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "reserveSkipGames"); exemptCache.removeAll() }
    }
    private static var exemptCache: [pid_t: Bool] = [:]
    /// 게임 앱인지: 라이엇(롤 클라이언트 · 게임) 이거나, 앱 분류가 게임이거나 (앱 안에 든 도우미 앱이면 바깥 앱의 분류)
    static func isGame(pid: pid_t) -> Bool {
        if let c = exemptCache[pid] { return c }
        var game = false
        if let a = NSRunningApplication(processIdentifier: pid) {
            let id = (a.bundleIdentifier ?? "").lowercased()
            if id.hasPrefix("com.riotgames") || id.hasPrefix("com.blizzard") || id.contains("steam") { game = true }
            var u = a.bundleURL
            while !game, let url = u {
                if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                   let cat = info["LSApplicationCategoryType"] as? String, cat.contains("games") { game = true }
                // 바깥쪽 .app 으로 올라가 봄
                var up = url.deletingLastPathComponent()
                while up.path != "/" && up.pathExtension != "app" { up = up.deletingLastPathComponent() }
                u = up.pathExtension == "app" ? up : nil
            }
        }
        exemptCache[pid] = game
        return game
    }
    /// 화면 전체를 덮는 창 (테두리 없는 전체 화면 게임 · 영상 등) 은 건드리지 않음
    private static func coversScreen(_ f: NSRect) -> Bool {
        NSScreen.screens.contains { s in abs(f.width - s.frame.width) < 2 && abs(f.height - s.frame.height) < 2 }
    }

    private static func fix(pid: pid_t) {
        if skipGames && isGame(pid: pid) { return }
        let ax = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for w in wins {
            guard let f = frame(w, primaryH: primaryH), f.width > 120, f.height > 80,
                  !flag(w, "AXFullScreen"), !flag(w, kAXMinimizedAttribute as String), !coversScreen(f),
                  (role(w) ?? "") == (kAXStandardWindowSubrole as String),
                  let nf = fitted(f) else { continue }
            // 크기를 바꿔야 하는데 못 바꾸는 창이면 위치만
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
            var target = nf
            if nf.size != f.size && !settable.boolValue { target.size = f.size }
            set(w, target, primaryH: primaryH)
        }
    }

    private static func role(_ w: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private static func flag(_ w: AXUIElement, _ k: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, k as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    /// AX 좌표(주 모니터 왼쪽 위 기준) → Cocoa 좌표(왼쪽 아래 기준)
    static func frame(_ w: AXUIElement, primaryH: CGFloat) -> NSRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return NSRect(x: p.x, y: primaryH - p.y - s.height, width: s.width, height: s.height)
    }

    static func set(_ w: AXUIElement, _ f: NSRect, primaryH: CGFloat) {
        var p = CGPoint(x: f.minX, y: primaryH - f.maxY)
        var s = CGSize(width: f.width, height: f.height)
        // 줄일 때는 크기 먼저 (밀다가 화면 밖으로 튀지 않게), 키울 때는 위치 먼저
        if let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        }
    }
}

// MARK: - 초록 버튼 = 최대화 (옵션)
// 창의 초록 버튼을 그냥 누르면 전체 화면 대신 "막대 자리를 뺀 크기" 로 최대화, 한 번 더 누르면 원래 크기로
// (⌥ 등 보조 키를 누른 채 누르면 macOS 원래 동작 그대로. 진짜 전체 화면은 앱 메뉴 · ⌃⌘F)

@MainActor
enum GreenZoom {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "greenZoom") }
        set {
            UserDefaults.standard.set(newValue, forKey: "greenZoom")
            newValue ? start() : stop()
            FavBar.shared.onChange()
        }
    }
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var source: CFRunLoopSource?
    /// 누르기를 삼켰으면 짝이 되는 떼기도 삼킴
    nonisolated(unsafe) fileprivate static var swallowUp = false
    /// 최대화하기 전 크기 (창마다) — 다시 누르면 되돌림
    private static var before: [String: NSRect] = [:]

    static func start() {
        guard enabled, tap == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: greenTapCallback, userInfo: nil) else { return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        CGEvent.tapEnable(tap: t, enable: true)
    }
    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }
    nonisolated fileprivate static func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// 그 자리가 다른 앱 창의 초록(전체 화면) 버튼이면 그 창
    nonisolated fileprivate static func greenButtonWindow(at p: CGPoint) -> AXUIElement? {
        // 먼저 가볍게 거름: 그 자리 맨 위 창의 왼쪽 위 (신호등 버튼 자리) 를 누른 게 아니면 바로 통과
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let top = wins.first(where: { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
            return r.contains(p)
        }), let b = top[kCGWindowBounds as String] as? [String: CGFloat],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              p.x - r.minX < 110, p.y - r.minY < 50 else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return nil }
        var sub: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub) == .success,
              (sub as? String) == (kAXFullScreenButtonSubrole as String) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == getpid() { return nil }   // 도구함 자신의 창은 그대로
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &w) == .success else { return nil }
        return (w as! AXUIElement)
    }

    /// 최대화 ↔ 되돌리기
    static func toggle(_ w: AXUIElement) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard let f = BarReserve.frame(w, primaryH: primaryH), let room = BarReserve.room(for: f) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
        let key = "\(pid)|\(t as? String ?? "")"
        let isMax = abs(f.minX - room.minX) < 4 && abs(f.minY - room.minY) < 4 && abs(f.width - room.width) < 6 && abs(f.height - room.height) < 6
        if isMax, let old = before[key] {
            BarReserve.set(w, old, primaryH: primaryH)
            before[key] = nil
        } else {
            before[key] = f
            BarReserve.set(w, room, primaryH: primaryH)
        }
    }
}

/// 이벤트 탭: 보조 키 없이 초록 버튼을 누르면 삼키고 최대화
private func greenTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        GreenZoom.reenable()
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp {
        if GreenZoom.swallowUp { GreenZoom.swallowUp = false; return nil }
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown, !Spaces.moving,
          event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]).isEmpty,
          let w = GreenZoom.greenButtonWindow(at: event.location) else { return Unmanaged.passUnretained(event) }
    GreenZoom.swallowUp = true
    DispatchQueue.main.async { MainActor.assumeIsolated { GreenZoom.toggle(w) } }
    return nil
}
