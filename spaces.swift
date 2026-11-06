// 데스크탑(Space) 별로 실행 중인 앱 묶기
// macOS 가 공개하지 않는 SkyLight 기능으로 읽기만 함 (정리 앱들이 흔히 쓰는 방법, macOS 가 바뀌면 안 될 수 있음)
import Cocoa
import ApplicationServices

enum Spaces {
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
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               (b["Width"] as? Double ?? 0) < 60 || (b["Height"] as? Double ?? 0) < 40 { continue }
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
    private static func grabPoint(pid: pid_t, rect r: CGRect) -> CGPoint {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // 탭 묶음(AXTabGroup)의 빈 공간은 창을 끄는 자리라 괜찮음 — 탭(AXRadioButton) · 버튼만 피함
        let bad: Set<String> = ["AXButton", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton",
                                "AXMenuButton", "AXCheckBox", "AXLink", "AXComboBox", "AXSearchField", "AXImage", "AXStaticText"]
        var xs: [CGFloat] = []
        // 오른쪽 끝(창 버튼 · 프로필 버튼 바로 안쪽)부터 왼쪽으로, 그다음 가운데
        var x = r.maxX - 90
        while x > r.minX + 90 { xs.append(x); x -= 24 }
        var log: [String] = []
        defer { try? log.joined(separator: "\n").write(toFile: NSHomeDirectory() + "/MyLauncher/space-grab.txt", atomically: true, encoding: .utf8) }
        // 맨 위 가장자리(탭 위쪽 여백)부터
        for y in [r.minY + 3, r.minY + 6, r.minY + 12] {
            for x in xs {
                var el: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &el) == .success, let el else { continue }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                let rs = role as? String ?? "?"
                if log.count < 40 { log.append("\(Int(x)),\(Int(y)) \(rs)") }
                if !bad.contains(rs) { log.append("→ 잡음 \(Int(x)),\(Int(y)) \(rs)"); return CGPoint(x: x, y: y) }
            }
        }
        log.append("→ 빈 자리 없음, 가운데")
        return CGPoint(x: r.midX, y: r.minY + 12)
    }

    /// 그 앱의 이 창(위치 · 크기로 맞춤)의 창 번호
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
    static func move(pid: pid_t, to target: Desk, desks: [Desk], retried: Bool = false, done: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { done("손쉬운 사용 권한이 필요해요"); return }
        guard !target.fullscreen else { done("전체 화면 데스크탑으로는 옮길 수 없어요"); return }
        guard let win = mainWindow(pid: pid), var r = axRect(win) else {
            // 다른 데스크탑에 있는 창은 macOS 가 목록에 안 보여 줌 → 앱을 앞으로 불러 그 데스크탑으로 넘어간 뒤 다시
            guard !retried, let app = NSRunningApplication(processIdentifier: pid) else {
                done("옮길 창을 찾지 못했어요. 그 앱 창이 있는 데스크탑으로 가서 다시 해 보세요.")
                return
            }
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                // 넘어간 뒤의 데스크탑 상태로 다시 계산
                move(pid: pid, to: target, desks: load(), retried: true, done: done)
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
        app?.activate()
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        let grab = grabPoint(pid: pid, rect: r)
        let wid = windowID(pid: pid, rect: r)
        let back = CGEvent(source: nil)?.location ?? grab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: grab, mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left))
            let nudge = CGPoint(x: grab.x + 4, y: grab.y)
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: nudge, mouseButton: .left))
            var i = 0
            func next() {
                guard i < abs(steps) else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: nudge, mouseButton: .left))
                        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left))
                        // 정말 옮겨졌는지 확인
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if let wid, !spaces(of: wid).contains(target.id) {
                                done("‘\(app?.localizedName ?? "앱")’ 창을 옮기지 못했어요.\n창 맨 위에 잡을 빈 곳이 없는 앱일 수 있어요. Mission Control 에서 끌어다 놓아 주세요.")
                            } else {
                                done(nil)
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
    }
}
