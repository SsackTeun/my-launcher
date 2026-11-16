// 데스크탑(Space) 별로 실행 중인 앱 묶기
// macOS 가 공개하지 않는 SkyLight 기능으로 읽기만 함 (정리 앱들이 흔히 쓰는 방법, macOS 가 바뀌면 안 될 수 있음)
import Cocoa
import ApplicationServices

enum Spaces {
    /// 창을 다른 데스크탑으로 옮기는 중 (그동안 창을 건드리는 다른 기능은 쉼)
    nonisolated(unsafe) static var moving = false
    struct Desk {
        let id: Int
        let label: String
        let current: Bool
        var pids: [pid_t]
        var display = ""          // 모니터 UUID
        var order = 0             // 그 모니터 안에서 몇 번째 데스크탑 (0부터, 전체 화면 포함)
        var fullscreen = false
    }

    private typealias MainConn = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ name: String, _ t: T.Type) -> T? {
        guard let sky, let p = dlsym(sky, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }
    private static let mainConn = fn("SLSMainConnectionID", MainConn.self)
    private static let copyDisplays = fn("SLSCopyManagedDisplaySpaces", CopyDisplaySpaces.self)
    private static let copyForWindows = fn("SLSCopySpacesForWindows", CopySpacesForWindows.self)

    static var available: Bool { mainConn != nil && copyDisplays != nil && copyForWindows != nil }

    /// 모니터 UUID → 짧은 이름 (맥북 · 외부 모니터 이름)
    private static func displayNames() -> [String: String] {
        var out: [String: String] = [:]
        for s in NSScreen.screens {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue(),
                  let str = CFUUIDCreateString(nil, u) as String? else { continue }
            let n = s.localizedName
            out[str.uppercased()] = n.localizedCaseInsensitiveContains("Built-in") || n.contains("내장") ? "맥북" : n
        }
        return out
    }

    /// 데스크탑 목록과 각 데스크탑에 창이 있는 앱(pid)
    /// 가벼운 데스크탑 목록: (번호 1, 2, 3… · 이름) + 지금 보이는 데스크탑 번호들 (모니터마다 하나)
    /// 전체 화면 앱 공간은 번호가 없어서 빠짐. 번호는 Mission Control 순서라 재부팅해도 같은 데스크탑을 가리킴
    static func numbered() -> (desks: [(n: Int, label: String, display: String, id: Int)], current: Set<Int>) {
        guard let mainConn, let copyDisplays,
              let displays = copyDisplays(mainConn())?.takeRetainedValue() as? [[String: Any]] else { return ([], []) }
        let names = displayNames()
        let multi = displays.count > 1
        var out: [(Int, String, String, Int)] = []
        var cur = Set<Int>()
        var n = 0
        for disp in displays {
            let uuid = (disp["Display Identifier"] as? String ?? "").uppercased()
            let dname = names[uuid] ?? (names.count == 1 ? names.values.first : nil) ?? "모니터"
            let now = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            for sp in disp["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = sp["ManagedSpaceID"] as? Int, (sp["type"] as? Int ?? 0) != 4 else { continue }
                n += 1
                out.append((n, multi ? "데스크탑 \(n) · \(dname)" : "데스크탑 \(n)", uuid, id))
                if id == now { cur.insert(n) }
            }
        }
        return (out, cur)
    }

    /// 모니터의 UUID (데스크탑 목록의 display 와 같은 형식)
    static func uuid(of screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return "" }
        return (CFUUIDCreateString(nil, u) as String).uppercased()
    }

    /// 데스크탑 번호(1, 2, 3…, 전체 화면 공간은 빼고 센 번호) 에 창이 열려 있는 앱 (번들 ID, 겹치지 않게)
    static func apps(onDesktop n: Int) -> [String] {
        let ds = load().filter { !$0.fullscreen }
        guard ds.indices.contains(n - 1) else { return [] }
        var seen = Set<String>()
        return ds[n - 1].pids.compactMap { pid in
            guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// 데스크탑 번호(1, 2, 3…) 로 넘어가기
    /// - 같은 모니터: ⌃← / ⌃→ 를 칸 수만큼 (macOS 기본 단축키)
    /// - 다른 모니터: 그 데스크탑에 열린 앱을 앞으로 (없으면 마우스를 잠깐 그 모니터로 옮겨 넘김)
    static func switchTo(_ n: Int, apps: [String] = []) {
        let desks = load()
        let normal = desks.filter { !$0.fullscreen }
        guard normal.indices.contains(n - 1) else { return }
        let target = normal[n - 1]
        guard !target.current else { return }
        guard let cur = desks.first(where: { $0.display == target.display && $0.current }) else { return }
        let steps = target.order - cur.order
        let mouse = NSEvent.mouseLocation
        let mouseDisplay = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.map(Spaces.uuid(of:)) ?? ""
        func press(_ count: Int, then: @escaping () -> Void) {
            var i = 0
            func next() {
                guard i < abs(count) else { then(); return }
                i += 1
                let key: CGKeyCode = count > 0 ? 124 : 123   // → / ←
                let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
                down?.flags = [.maskControl, .maskSecondaryFn]
                let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
                up?.flags = [.maskControl, .maskSecondaryFn]
                post(down); post(up)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { next() }
            }
            next()
        }
        if mouseDisplay == target.display {
            press(steps) {}
            return
        }
        // 다른 모니터: ⌃← / ⌃→ 는 '지금 활성인 모니터' 에 먹어서 그대로는 안 됨
        // 1) 그 데스크탑에 앱 창이 있으면 그 앱을 앞으로 → macOS 가 그 데스크탑으로 넘어감
        let me = ProcessInfo.processInfo.processIdentifier
        //    (그 앱이 지금 데스크탑에도 창이 있으면 macOS 가 안 넘어가서 — 예: VMware 창이 1 · 2 에 다 있을 때 — 그 데스크탑에만 있는 앱만)
        //    지금 보이는 데스크탑 (모든 모니터) 에 창이 없는 앱이 제일 확실함
        //    (앱이 지금 보이는 데스크탑 — 어느 모니터든 — 에도 창이 있으면 macOS 가 안 넘어감. 예: VMware 창이 1 · 4 에 나뉨 → 2) 로)
        let visible = Set(desks.filter(\.current).flatMap(\.pids))
        if let pid = target.pids.first(where: { $0 != me && !visible.contains($0) }), let app = NSRunningApplication(processIdentifier: pid) {
            MainActor.assumeIsolated { bringToFront(app) }
            return
        }
        // 2) 빈 데스크탑 · 다른 데스크탑에도 창이 있는 앱뿐: 그 모니터 메뉴 막대 빈 곳을 한 번 눌러 그 모니터를 활성으로 만든 뒤 넘기고, 마우스는 제자리로
        guard let scr = screen(forUUID: target.display) else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let back = CGPoint(x: mouse.x, y: primaryTop - mouse.y)
        let menuSpot = CGPoint(x: scr.frame.midX, y: primaryTop - scr.frame.maxY + 6)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: menuSpot, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: menuSpot, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: menuSpot, mouseButton: .left))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            press(steps) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left))
                }
            }
        }
    }

    /// 지금 데스크탑에서 데스크탑 n 까지 같은 모니터 안 칸 수 (다른 모니터면 nil, 이미 거기면 0)
    static func steps(to n: Int) -> (steps: Int, display: String, target: Desk, desks: [Desk])? {
        let desks = load()
        let normal = desks.filter { !$0.fullscreen }
        guard normal.indices.contains(n - 1) else { return nil }
        let target = normal[n - 1]
        guard let cur = desks.first(where: { $0.display == target.display && $0.current }) else { return nil }
        return (target.order - cur.order, target.display, target, desks)
    }
    /// ⌃← / ⌃→ 를 count 만큼 (양수 = 오른쪽)
    static func pressArrows(_ count: Int, gap: Double = 0.35, then: @escaping () -> Void = {}) {
        var i = 0
        func next() {
            guard i < abs(count) else { then(); return }
            i += 1
            let key: CGKeyCode = count > 0 ? 124 : 123
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
            down?.flags = [.maskControl, .maskSecondaryFn]
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
            up?.flags = [.maskControl, .maskSecondaryFn]
            post(down); post(up)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { next() }
        }
        next()
    }

    /// 다른 앱을 앞으로 (macOS 14+ 는 맨 앞 앱만 다른 앱에 차례를 넘길 수 있어서: 도구함이 잠깐 앞에 나온 뒤 넘겨줌)
    /// 그 앱 창이 다른 데스크탑에 있으면 macOS 가 그 데스크탑으로 넘어감
    @MainActor static func bringToFront(_ app: NSRunningApplication) {
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
    }

    static func load() -> [Desk] {
        guard let mainConn, let copyDisplays, let copyForWindows else { return [] }
        let cid = mainConn()
        guard let displays = copyDisplays(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let names = displayNames()
        let multi = displays.count > 1

        // 1) 데스크탑 순서: Mission Control 처럼 모니터를 다 합쳐서 1, 2, 3 … 이어서
        var desks: [Desk] = []
        var n = 0
        var index: [Int: Int] = [:]
        var fullscreen: [Int] = []
        for disp in displays {
            let uuid = (disp["Display Identifier"] as? String ?? "").uppercased()
            let dname = names[uuid] ?? (names.count == 1 ? names.values.first : nil) ?? "모니터"
            let cur = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            var order = 0
            for sp in disp["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = sp["ManagedSpaceID"] as? Int else { continue }
                let type = sp["type"] as? Int ?? 0
                let label: String
                if type == 4 {
                    label = "전체 화면"
                    fullscreen.append(desks.count)
                } else {
                    n += 1
                    label = multi ? "데스크탑 \(n) · \(dname)" : "데스크탑 \(n)"
                }
                index[id] = desks.count
                desks.append(Desk(id: id, label: label + (id == cur ? " (지금)" : ""), current: id == cur, pids: [],
                                  display: uuid, order: order, fullscreen: type == 4))
                order += 1
            }
        }

        // 2) 창마다 어느 데스크탑에 있는지 → 앱을 그 데스크탑에
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let wins = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var fsOwner: [Int: String] = [:]
        for w in wins {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, regular.contains(pid),
                  let wid = w[kCGWindowNumber as String] as? Int else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
            // 진짜 창만 (주소창 추천 목록 · 알림 풍선 같은 숨은 작은 창은 빼기)
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               (b["Width"] as? Double ?? 0) < 200 || (b["Height"] as? Double ?? 0) < 150 { continue }
            let sps = copyForWindows(cid, 7, [wid] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            for sp in sps {
                guard let k = index[sp] else { continue }
                if !desks[k].pids.contains(pid) { desks[k].pids.append(pid) }
                if fsOwner[k] == nil { fsOwner[k] = w[kCGWindowOwnerName as String] as? String }
            }
        }
        // 전체 화면 데스크탑은 그 앱 이름으로
        for k in fullscreen {
            let d = desks[k]
            desks[k] = Desk(id: d.id, label: "전체 화면 · \(fsOwner[k] ?? "앱")" + (d.current ? " (지금)" : ""), current: d.current, pids: d.pids,
                            display: d.display, order: d.order, fullscreen: true)
        }
        return desks
    }
}

// MARK: - 다른 데스크탑으로 옮기기
// macOS 가 다른 앱 창을 데스크탑으로 바로 보내는 걸 막아서, 사람이 하는 방법을 흉내 냄:
// · 다른 모니터면: 창을 그 모니터로 옮김 (손쉬운 사용으로 위치 바꾸기)
// · 같은 모니터의 다른 데스크탑이면: 창 제목 막대를 잡은 채 Ctrl+← / → 로 데스크탑을 넘김 (창이 따라옴)

extension Spaces {
    private static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue() else { return false }
            return (CFUUIDCreateString(nil, u) as String).uppercased() == uuid
        } ?? (NSScreen.screens.count == 1 ? NSScreen.screens.first : nil)
    }

    private static func axRect(_ w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success, let pv, let sv else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: p, size: sz)
    }

    /// 앱의 (보이는) 표준 창 중 첫 번째
    private static func mainWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let ws = v as? [AXUIElement] else { return nil }
        return ws.first { w in
            var sub: CFTypeRef?, mini: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini)
            return (sub as? String) == (kAXStandardWindowSubrole as String) && (mini as? Bool) != true
        } ?? ws.first
    }

    private static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    /// 창 맨 위에서 잡고 끌 수 있는 빈 자리 찾기 (탭 · 버튼 · 입력칸은 피함 — Chrome 처럼 맨 위가 탭 줄인 앱)
    /// 창을 끌 수 있을 것 같은 자리 후보들 (버튼 · 탭 · 글자 같은 누르면 일이 생기는 곳은 뺌)
    private static func grabCandidates(pid: pid_t, rect r: CGRect) -> [CGPoint] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let bad: Set<String> = ["AXButton", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton",
                                "AXCheckBox", "AXLink", "AXComboBox", "AXSearchField", "AXImage", "AXStaticText", "AXMenuItem", "AXCell", "AXRow"]
        var xs: [CGFloat] = []
        var x = r.maxX - 90
        while x > r.minX + 90 { xs.append(x); x -= 40 }
        xs.append(contentsOf: [r.minX + 80, r.minX + 72, r.minX + 90, r.midX])
        var out: [CGPoint] = []
        var log: [String] = []
        defer { try? log.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/MyLauncher/space-grab.txt", atomically: true, encoding: .utf8) }
        // 제목 막대 높이 안에서만 (게임처럼 화면 안쪽을 누르면 안 되는 앱이 있어서)
        for y in [r.minY + 4, r.minY + 10, r.minY + 16] {
            for x in xs {
                var el: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &el) == .success, let el else { continue }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                let rs = role as? String ?? "?"
                if !bad.contains(rs) {
                    out.append(CGPoint(x: x, y: y))
                    log.append("후보 \(Int(x)),\(Int(y)) \(rs)")
                    if out.count >= 8 { return out }
                }
            }
        }
        return out
    }

    /// 화면에 그려진 창의 왼쪽 위 (CG 좌표)
    private static func cgOrigin(_ wid: Int) -> CGPoint? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return r.origin
    }

    private static func windowID(pid: pid_t, rect r: CGRect) -> Int? {
        let wins = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return wins.first { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { return false }
            let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0, wd = b["Width"] as? Double ?? 0, h = b["Height"] as? Double ?? 0
            return abs(x - r.minX) < 3 && abs(y - r.minY) < 3 && abs(wd - r.width) < 3 && abs(h - r.height) < 3
        }?[kCGWindowNumber as String] as? Int
    }

    private static func spaces(of wid: Int) -> [Int] {
        guard let mainConn, let copyForWindows else { return [] }
        return copyForWindows(mainConn(), 7, [wid] as CFArray)?.takeRetainedValue() as? [Int] ?? []
    }

    /// 결과: nil 이면 성공, 아니면 안내 문구
    @MainActor
    static func move(pid: pid_t, to target: Desk, desks: [Desk], tries: Int = 0, done: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { done("손쉬운 사용 권한이 필요해요"); return }
        guard !target.fullscreen else { done("전체 화면 데스크탑으로는 옮길 수 없어요"); return }
        guard let win = mainWindow(pid: pid), var r = axRect(win) else {
            // 다른 데스크탑에 있는 창은 macOS 가 목록에 안 보여 줌 → 앱을 앞으로 불러 그 데스크탑으로 넘어간 뒤 다시
            guard tries < 2, let app = NSRunningApplication(processIdentifier: pid) else {
                done("옮길 창을 찾지 못했어요. 그 앱 창이 있는 데스크탑으로 가서 다시 해 보세요.")
                return
            }
            if tries == 0 { Spaces.bringToFront(app) }
            // 데스크탑이 넘어가는 애니메이션이 끝난 뒤 다시 (그래도 없으면 한 번 더 기다림)
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 1.3 : 1.0)) {
                move(pid: pid, to: target, desks: load(), tries: tries + 1, done: done)
            }
            return
        }
        let app = NSRunningApplication(processIdentifier: pid)

        // 1) 다른 모니터면 창을 그 모니터 가운데로 (그 모니터의 '지금 데스크탑'에 놓임)
        let cur = desks.first { $0.display == target.display && $0.current }
        // 창이 지금 어느 모니터에 있는지 (AX 는 왼쪽 위 기준 → 화면 좌표로)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let center = NSPoint(x: r.midX, y: primaryTop - r.midY)
        let srcScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        let srcDisplay = srcScreen.flatMap { s -> String? in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, u) as String).uppercased()
        }
        if NSScreen.screens.count > 1, srcDisplay != target.display {
            if let scr = screen(forUUID: target.display) {
                // AX 좌표는 왼쪽 위 기준
                let top = NSScreen.screens.first.map { $0.frame.maxY } ?? scr.frame.maxY
                let vf = scr.visibleFrame
                var p = CGPoint(x: vf.midX - r.width / 2, y: top - vf.maxY + 40)
                p.x = max(vf.minX, p.x)
                var pv = p
                if let val = AXValueCreate(.cgPoint, &pv) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, val)
                }
                if let nr = axRect(win) { r = nr }
            }
        }

        // 2) 같은 모니터 안에서 몇 칸 넘겨야 하는지
        guard let cur, cur.id != target.id else { done(nil); return }
        let steps = target.order - cur.order
        guard steps != 0 else { done(nil); return }

        // 창을 앞으로 가져온 뒤 제목 막대를 잡고 데스크탑 넘기기
        if let app { Spaces.bringToFront(app) }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        // 옮기는 동안엔 다른 기능(막대 자리 비워 두기 등)이 창을 건드리지 않게
        moving = true
        func finish(_ m: String?) { moving = false; done(m) }
        let cands = grabCandidates(pid: pid, rect: r)
        let wid = windowID(pid: pid, rect: r)
        let back = CGEvent(source: nil)?.location ?? CGPoint(x: r.midX, y: r.minY + 10)
        func release(_ p: CGPoint) {
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
        }
        // 1) 후보 자리를 하나씩 살짝 끌어 보고, 창이 따라 움직이는 자리를 찾음
        func probe(_ i: Int) {
            guard i < cands.count else {
                post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left))
                finish("‘\(app?.localizedName ?? "앱")’ 창을 잡을 자리를 찾지 못했어요.\nMission Control (⌃↑) 에서 창을 원하는 데스크탑으로 끌어다 놓아 주세요.")
                return
            }
            let g = cands[i]
            let nudge = CGPoint(x: g.x + 6, y: g.y)
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: g, mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: g, mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: g.x + 3, y: g.y), mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: nudge, mouseButton: .left))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // 창이 따라왔는지: 화면에 실제로 그려진 위치로 (위치 정보가 늦게 바뀌는 앱이 있어서 AX 는 보조로)
                let cgMoved = wid.flatMap { cgOrigin($0) }.map { abs($0.x - r.minX) >= 3 } ?? false
                let axMoved = axRect(win).map { abs($0.minX - r.minX) >= 3 } ?? false
                if cgMoved || axMoved {
                    switchDesks(holding: nudge)      // 잡혔음 → 누른 채로 데스크탑 넘기기
                } else {
                    release(nudge)                   // 안 따라옴 → 놓고 다음 자리
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { probe(i + 1) }
                }
            }
        }
        // 2) 창을 잡은 채로 ⌃← / ⌃→ 를 칸 수만큼
        func switchDesks(holding p: CGPoint) {
            var i = 0
            func next() {
                guard i < abs(steps) else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        release(p)
                        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left))
                        // 정말 옮겨졌는지 확인
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if let wid, !spaces(of: wid).contains(target.id) {
                                finish("‘\(app?.localizedName ?? "앱")’ 창을 옮기지 못했어요.\nMission Control (⌃↑) 에서 창을 원하는 데스크탑으로 끌어다 놓아 주세요.")
                            } else {
                                finish(nil)
                            }
                        }
                    }
                    return
                }
                i += 1
                let key: CGKeyCode = steps > 0 ? 124 : 123   // → / ←
                let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
                down?.flags = [.maskControl, .maskSecondaryFn]
                let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
                up?.flags = [.maskControl, .maskSecondaryFn]
                post(down); post(up)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { probe(0) }
    }
}


// MARK: - 진단: Mission Control 이 열렸을 때 Dock 의 손쉬운 사용 구조를 파일로

extension Spaces {
    @MainActor
    static func dumpMissionControl() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var out = ""
            var stack: [(AXUIElement, Int)] = [(app, 0)]
            var n = 0
            while let (el, depth) = stack.popLast(), n < 800 {
                n += 1
                func str(_ k: String) -> String {
                    var v: CFTypeRef?
                    AXUIElementCopyAttributeValue(el, k as CFString, &v)
                    return (v as? String) ?? ""
                }
                var pv: CFTypeRef?, sv: CFTypeRef?
                var p = CGPoint.zero, sz = CGSize.zero
                if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success, let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
                if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success, let sv { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
                var acts: CFArray?
                AXUIElementCopyActionNames(el, &acts)
                out += String(repeating: " ", count: depth) + "\(str(kAXRoleAttribute)) \(str(kAXSubroleAttribute)) t=\"\(str(kAXTitleAttribute))\" d=\"\(str(kAXDescriptionAttribute))\" id=\"\(str("AXIdentifier"))\" \(Int(p.x)),\(Int(p.y)) \(Int(sz.width))x\(Int(sz.height)) acts=\((acts as? [String] ?? []).joined(separator: ","))\n"
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
                for c in ((kids as? [AXUIElement]) ?? []).reversed() { stack.append((c, depth + 1)) }
            }
            try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/mc-dump.txt", atomically: true, encoding: .utf8)
            // Mission Control 닫기 (Esc)
            let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
            esc?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
