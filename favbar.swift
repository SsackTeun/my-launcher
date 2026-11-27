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

    /// 데스크탑 막대 추가: 그 데스크탑에 열린 앱이 저절로 채워지는 막대
    @discardableResult
    static func addDesktopBar(_ n: Int) -> FavBar {
        // 같은 데스크탑 막대는 하나만 (이미 있으면 그 막대를 펴서 돌려줌)
        if let have = all.first(where: { $0.desktop == n }) { if have.collapsed { have.collapsed = false }; return have }
        let b = addBar()
        b.editing = false
        b.desktop = n
        b.name = "데스크탑 \(n)"
        return b
    }

    // MARK: 데스크탑 막대 (그 데스크탑에 창이 열린 앱을 저절로 보여 줌)

    /// 이 막대가 보여 줄 데스크탑 번호 (nil = 앱을 직접 넣는 일반 막대)
    var desktop: Int? {
        get { d.object(forKey: k("favDesktop")) as? Int }
        set {
            if let n = newValue { d.set(n, forKey: k("favDesktop")) } else { d.removeObject(forKey: k("favDesktop")) }
            desktopID = newValue.flatMap { n in Spaces.numbered().desks.first { $0.n == n }?.id }
            if let id = desktopID { Self.ignoredDesks.remove(id) }
            editing = false
            let c = newValue.map(Spaces.deskContent)
            deskCache = stableOrder(c?.ids ?? [])
            deskMin = c?.minimized ?? []
            deskMinWins = c?.minWins ?? []
            rebuild(animate: false)
            onChange()
            Self.watchDesktops()
        }
    }
    var isDesktop: Bool { desktop != nil }
    #if DEBUG
    /// 시험용: 데스크탑 막대 내용을 직접 정함
    func _testSetDeskCache(_ ids: [String]) { deskCache = ids; rebuild(animate: false) }
    #endif
    /// 이미 막대가 있는 데스크탑인지 (그 번호로는 더 못 만듦)
    static func hasBar(forDesktop n: Int) -> Bool { all.contains { $0.desktop == n } }
    /// 그 데스크탑의 고유 ID (데스크탑을 지우면 막대도 닫고, 번호가 당겨지면 막대 번호도 따라 바꿈)
    var desktopID: Int? {
        get { d.object(forKey: k("favDesktopID")) as? Int }
        set { if let v = newValue { d.set(v, forKey: k("favDesktopID")) } else { d.removeObject(forKey: k("favDesktopID")) } }
    }
    fileprivate(set) var deskCache: [String] = []
    /// 이 데스크탑에서 Dock 으로 내려 둔 창만 있는 앱 (막대에 점선 테두리) · 그 창 번호
    fileprivate(set) var deskMin: Set<String> = []
    fileprivate(set) var deskMinWins: [Int] = []

    /// 데스크탑 안 앱 순서를 고정: 처음 본 순서대로, 새 앱은 끝에 (누르거나 창을 올리고 내려도 자리가 그대로)
    /// (예전엔 창이 겹친 순서대로라 누를 때마다 앞으로 나온 앱이 맨 앞으로 옮겨 갔음)
    func stableOrder(_ now: [String]) -> [String] {
        let key = "favDeskOrder.\(desktopID ?? desktop ?? 0)"
        var known = Self.d.stringArray(forKey: key) ?? []
        for id in now where !known.contains(id) { known.append(id) }
        if known.count > 60 { known = known.filter(now.contains) + known.filter { !now.contains($0) }.suffix(30) }
        if known != Self.d.stringArray(forKey: key) { Self.d.set(known, forKey: key) }
        return known.filter(now.contains)
    }
    /// 누른 직후: 점선 표시를 바로 바꿔 둠 (실제 상태는 조금 뒤 다시 확인)
    private func markMinimized(_ id: String, _ on: Bool) {
        if on { deskMin.insert(id) } else { deskMin.remove(id) }
        (panel?.contentView as? FavBarView)?.refreshState()
        Spaces.forgetMinimized()
    }

    /// 데스크탑 막대의 앱 누르기: 내려 둔 창이면 그 데스크탑으로 가서 올리고, 지금 앞에 떠 있는 앱이면 내림, 아니면 평소처럼
    func toggleDeskApp(_ id: String) {
        guard let n = desktop, let r = mainApp(id) else { open(id); return }
        let pid = r.processIdentifier
        // X 로 창을 닫아 둔 앱 (내려 둔 창도 없음): 지금 데스크탑에 창을 다시 열기 (Dock 아이콘 누르기와 같음)
        if deskMin.contains(id), !FavBar.hasMinimizedWindow(pid: pid) {
            markMinimized(id, false)
            open(id)
            for t in [0.6, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { FavBar.refreshDesktops() } } }
            return
        }
        if deskMin.contains(id) {
            let wins = Set(deskMinWins)
            let restore = { [weak self] in
                FavBar.setMinimized(pid: pid, false, only: wins)
                _ = self
                Spaces.bringToFront(r)
                for t in [0.4, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { FavBar.refreshDesktops() } } }
            }
            if FavBar.currentDesks.contains(n) { restore() }
            else {
                Spaces.switchTo(n, apps: favs)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { MainActor.assumeIsolated { restore() } }
            }
            return
        }
        if FavBar.currentDesks.contains(n), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            FavBar.setMinimized(pid: pid, true, only: nil)
            for t in [0.4, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { FavBar.refreshDesktops() } } }
            return
        }
        open(id)
    }
    /// 그 앱에 Dock 으로 내려 둔 창이 있는지 (없으면 X 로 닫아 둔 것)
    static func hasMinimizedWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else { return false }
        return ws.contains { w in
            var m: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success && (m as? Bool) == true
        }
    }
    /// 창 내리기(앞 창 하나) · 올리기(only 에 든 창들, 못 찾으면 내려 둔 첫 창)
    static func setMinimized(pid: pid_t, _ on: Bool, only: Set<Int>?) {
        guard AXIsProcessTrusted() else { return }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        if on {
            var f: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &f) == .success, let fw = f else { return }
            AXUIElementSetAttributeValue(fw as! AXUIElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else { return }
        let mins = ws.filter { w in
            var m: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m) == .success && (m as? Bool) == true
        }
        var picked = mins.filter { w in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(w, &id) == .success && (only?.contains(Int(id)) ?? false)
        }
        if picked.isEmpty, let f = mins.first { picked = [f] }
        for w in picked { AX.focus(window: w, pid: pid) }
    }

    /// 창을 열고 닫거나 옮기거나 데스크탑을 넘기면 데스크탑 막대 내용을 새로 (2초마다 + 바로 알 수 있는 때)
    private static var deskTimer: Timer?
    private static var deskObservers: [NSObjectProtocol] = []
    /// 지금 모니터에 보이고 있는 데스크탑 번호들 · 지금 화면에 창이 보이는 앱
    static var currentDesks: Set<Int> = []
    /// 데스크탑 번호 → (모니터 짧은 이름, 모니터 순번). 모니터가 2대 이상일 때만 막대에 표시
    static var deskMonitor: [Int: (name: String, index: Int)] = [:]
    static var multiMonitor: Bool { Set(deskMonitor.values.map(\.index)).count > 1 }
    /// 모니터마다 배지 색 (지금 보이는 데스크탑일 때)
    static func monitorColor(_ i: Int) -> NSColor {
        [NSColor.launcherAccent, .systemGreen, .systemOrange, .systemPurple, .systemPink][i % 5]
    }
    private static func updateMonitors(_ desks: [(n: Int, label: String, display: String, id: Int)]) -> Bool {
        var order: [String] = []
        var m: [Int: (String, Int)] = [:]
        for dk in desks {
            if !order.contains(dk.display) { order.append(dk.display) }
            // "데스크탑 3 · L27i-30" → "L27i" (짧게)
            let full = dk.label.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            var short = full.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "(" }).first.map(String.init) ?? full
            if short.count > 5 { short = String(short.prefix(5)) }
            m[dk.n] = (short, order.firstIndex(of: dk.display)!)
        }
        let changed = m.count != deskMonitor.count || m.contains { deskMonitor[$0.key]?.name != $0.value.0 || deskMonitor[$0.key]?.index != $0.value.1 }
        deskMonitor = m.mapValues { (name: $0.0, index: $0.1) }
        return changed
    }
    static var onScreenApps: Set<String> = []
    static func watchDesktops() {
        if deskTimer == nil {
            // 창을 내리고 올리는 순간 바로 막대에 반영 (점선 표시가 실제와 어긋나지 않게)
            MinimizeWatch.onChange = { FavBar.refreshDesktops() }
            MinimizeWatch.start()
            let t = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { FavBar.refreshDesktops() } }
            RunLoop.main.add(t, forMode: .common)
            deskTimer = t
            let ws = NSWorkspace.shared.notificationCenter
            for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
                      NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                deskObservers.append(ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                    // 창이 자리 잡을 시간을 조금 주고
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { FavBar.refreshDesktops() } }
                })
            }
        }
        // 도구함이 다 켜진 뒤에 (켜지는 도중에 막대를 만들면 아직 없는 메뉴를 건드릴 수 있어서)
        DispatchQueue.main.async { MainActor.assumeIsolated { refreshDesktops() } }
    }
    /// 켜져 있고 그 데스크탑에 아직 없는 앱만 옮길 수 있음
    static func movable(_ id: String, toDesktop n: Int) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return false }
        return !(all.first { $0.desktop == n }?.deskCache.contains(id) ?? false)
    }

    /// 앱 창을 데스크탑 n 으로 (제목 막대를 잡고 넘기는 방식이라 잠깐 화면이 넘어감)
    static func moveApp(_ id: String, toDesktop n: Int) {
        guard let r = mainApp(id) else { return }
        let desks = Spaces.load()
        let normal = desks.filter { !$0.fullscreen }
        guard normal.indices.contains(n - 1) else { return }
        Spaces.move(pid: r.processIdentifier, to: normal[n - 1], desks: desks) { msg in
            if let msg, msg.contains("Mission Control") {
                // 잡지 못한 창(롤 · 게임처럼 직접 그린 머리)은 Mission Control 에서 한 번만 손으로
                Spaces.guideMissionControl(app: r.localizedName ?? "앱", desk: n)
            } else if let msg {
                let a = NSAlert(); a.messageText = msg
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
            // 창 정보가 늦게 바뀌는 앱도 있어 몇 번 더
            for t in [0.5, 1.2, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { FavBar.refreshDesktops() } }
            }
        }
    }

    /// 아이콘 메뉴: 데스크탑으로 옮기기 ▸ 데스크탑 n
    static func moveMenu(for id: String, except: Int? = nil) -> NSMenuItem? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return nil }
        let desks = Spaces.numbered()
        guard desks.desks.count > 1 else { return nil }
        let i = NSMenuItem(title: "데스크탑으로 옮기기", action: nil, keyEquivalent: "")
        let m = NSMenu()
        for dk in desks.desks where dk.n != except {
            m.addItem(MenuAction(dk.label) { FavBar.moveApp(id, toDesktop: dk.n) })
        }
        i.submenu = m
        return i
    }

    private static var missing: [ObjectIdentifier: Int] = [:]

    /// 막대를 직접 지운 데스크탑 ID (다시 만들지 않음)
    static var ignoredDesks: Set<Int> {
        get { Set((d.array(forKey: "favIgnoredDesks") as? [Int]) ?? []) }
        set { d.set(Array(newValue), forKey: "favIgnoredDesks") }
    }
    /// 데스크탑 막대를 쓰고 있으면: 막대가 없는 데스크탑마다 막대를 만듦 (직접 지운 데스크탑은 빼고)
    private static func addBarsForNewDesks(_ desks: [(n: Int, label: String, display: String, id: Int)]) {
        let ids = Set(desks.map(\.id))
        ignoredDesks = ignoredDesks.intersection(ids)   // 없어진 데스크탑은 잊음
        let ignored = ignoredDesks
        let deskBars = all.filter { $0.isDesktop }
        guard let ref = deskBars.last else { return }   // 데스크탑 막대를 안 쓰면 만들지 않음
        for dk in desks where !ignored.contains(dk.id) && !deskBars.contains(where: { $0.desktopID == dk.id }) {
            let b = addDesktopBar(dk.n)
            // 다른 데스크탑 막대와 같은 모니터 · 가장자리에, 맨 끝 순서로
            b.d.set(ref.d.integer(forKey: ref.k("favScreen")), forKey: b.k("favScreen"))
            b.edge = ref.edge
            b.pos = ref.pos
            // 번호가 커지는 방향의 끝에 (예: 위→아래로 1, 2, 3 이면 맨 아래)
            let withOrder = deskBars.compactMap { b -> (n: Int, o: Double)? in
                guard let n = b.desktop, let o = b.order ?? b.panel.map({ p in
                    Double(b.edge.vertical ? p.frame.midY : p.frame.midX) / 10000 }) else { return nil }
                return (n, o)
            }
            let lo = withOrder.min { $0.n < $1.n }, hi = withOrder.max { $0.n < $1.n }
            let rising = (lo?.o ?? 0) <= (hi?.o ?? 0)
            let orders = withOrder.map(\.o)
            // 번호 사이에 들어가는 데스크탑이면 앞뒤 번호 막대 사이에, 아니면 끝에
            let before = withOrder.filter { $0.n < dk.n }.max { $0.n < $1.n }
            let after = withOrder.filter { $0.n > dk.n }.min { $0.n < $1.n }
            if let before, let after {
                b.order = (before.o + after.o) / 2
            } else if let before {
                b.order = before.o + (rising ? 0.01 : -0.01)
            } else if let after {
                b.order = after.o + (rising ? -0.01 : 0.01)
            } else {
                b.order = rising ? (orders.max() ?? 0.5) + 0.01 : (orders.min() ?? 0.5) - 0.01
            }
            b.rebuild(animate: false)
        }
    }
    static func refreshDesktops() {
        // 메뉴가 열려 있는 동안 막대를 새로 그리면 메뉴가 엉뚱한 줄을 가리킬 수 있어서 미룸
        if MenuWatch.open { return }
        // 지금 보이는 데스크탑 · 화면에 창이 보이는 앱이 바뀌었으면 표시를 다시 그림
        let cur = Spaces.numbered().current
        let me = getpid()
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var shown = Set<String>()
        for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 40,
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            shown.insert(id)
        }
        if cur != currentDesks || shown != onScreenApps {
            currentDesks = cur
            onScreenApps = shown
            for b in all { (b.panel?.contentView as? FavBarView)?.refreshState() }
        }
        // 데스크탑이 지워졌으면 그 막대도 닫고, 번호가 당겨졌으면 막대 번호도 따라감
        let info = Spaces.numbered()
        if !info.desks.isEmpty {
            for b in all where b.isDesktop {
                guard let old = b.desktop else { continue }
                guard let id = b.desktopID else {
                    // 예전에 만든 막대: 지금 번호의 ID 를 기억 (없는 번호면 닫음)
                    if let dk = info.desks.first(where: { $0.n == old }) { b.desktopID = dk.id } else { b.delete(auto: true) }
                    continue
                }
                if let dk = info.desks.first(where: { $0.id == id }) {
                    missing[ObjectIdentifier(b)] = nil
                    if dk.n != old {
                        let renamed = b.name == "데스크탑 \(old)"
                        b.d.set(dk.n, forKey: b.k("favDesktop"))
                        if renamed { b.d.set("데스크탑 \(dk.n)", forKey: b.k("favName")) }
                        b.rebuild(animate: false)
                        onChangeFn()
                    }
                } else {
                    // 잠깐 안 보이는 것일 수 있어서 두 번 연속 (약 2초) 없을 때만 닫음
                    let c = (missing[ObjectIdentifier(b)] ?? 0) + 1
                    missing[ObjectIdentifier(b)] = c
                    if c >= 2 { missing[ObjectIdentifier(b)] = nil; b.delete(auto: true) }
                }
            }
        }
        // 같은 데스크탑 막대가 여러 개면 하나만: 다른 데스크탑 막대들과 같은 가장자리 · 모니터에 있는 쪽을 남김
        let deskBars = all.filter { $0.isDesktop }
        func spot(_ b: FavBar) -> String { "\(b.edge.rawValue)|\(b.d.integer(forKey: b.k("favScreen")))" }
        var counts: [String: Int] = [:]
        for b in deskBars { counts[spot(b), default: 0] += 1 }
        let common = counts.max { $0.value < $1.value }?.key
        for n in Set(deskBars.compactMap(\.desktop)) {
            let same = deskBars.filter { $0.desktop == n }
            guard same.count > 1 else { continue }
            let keep = same.first { spot($0) == common } ?? same[0]
            for b in same where b !== keep { b.delete(auto: true) }
        }
        // 새 데스크탑이 생겼으면 (데스크탑 막대를 쓰고 있을 때) 그 막대도 추가
        if !info.desks.isEmpty { addBarsForNewDesks(info.desks) }
        // 모니터 구성이 바뀌었으면 막대 다시 (모니터 이름 칸 길이가 달라짐)
        if !info.desks.isEmpty, updateMonitors(info.desks) {
            for b in all where b.isDesktop { b.rebuild(animate: false) }
        }
        for b in all {
            guard let n = b.desktop else { continue }
            let c = Spaces.deskContent(n)
            let now = b.stableOrder(c.ids)
            b.deskMinWins = c.minWins
            // 앱은 그대로이고 내려 둠 여부만 바뀌었으면: 막대를 갈아 끼우지 않고 그 자리에서 다시 그림 (마우스가 위에 있어도)
            if now == b.deskCache {
                if c.minimized != b.deskMin { b.deskMin = c.minimized; (b.panel?.contentView as? FavBarView)?.refreshState() }
                continue
            }
            // 마우스가 그 막대 위에 있거나 누르고 있으면 미룸 (누르는 도중에 막대를 갈아 끼우면 클릭이 사라진 옛 막대로 가서 안 먹는 일이 생김)
            if NSEvent.pressedMouseButtons != 0 { continue }
            if let p = b.panel, p.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { continue }
            b.deskCache = now
            b.deskMin = c.minimized
            b.rebuild(animate: false)
        }
    }

    /// 이 막대 지우기 (마지막 하나는 못 지움 → 대신 막대 끄기)
    /// auto = 데스크탑이 없어져서 저절로 지움. 직접 지운 데스크탑 막대는 기억해서 다시 만들지 않음
    func delete(auto: Bool = false) {
        if !auto, let id = desktopID { Self.ignoredDesks.insert(id) }
        guard Self.keys.count > 1 else { enabled = false; return }
        hide()
        Self.keys = Self.keys.filter { $0 != key }
        Self.bars[key] = nil
        for k in ["favApps", "favEdge", "favPos", "favCollapsed", "favScreen", "favName", "favDesktop", "favOrder", "favDesktopID", "favLane"] { Self.d.removeObject(forKey: k + "." + key) }
        onChange()
    }

    // MARK: 이 막대의 설정

    let key: String
    private init(key: String) { self.key = key }
    /// 설정 이름: 첫 막대는 예전 이름 그대로, 그 밖은 "이름.번호"
    fileprivate func k(_ s: String) -> String { key.isEmpty ? s : s + "." + key }
    fileprivate var d: UserDefaults { Self.d }
    private var enabledAll: Bool { enabled }
    private(set) var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    var name: String {
        get { d.string(forKey: k("favName")) ?? (desktop.map { "데스크탑 \($0)" } ?? (key.isEmpty ? "자주 쓰는 앱" : "막대 \(key)")) }
        set { d.set(newValue, forKey: k("favName")); rebuild(animate: false); onChange() }
    }
    /// 막대에 보이는 앱: 일반 막대는 넣어 둔 앱, 데스크탑 막대는 그 데스크탑에 열린 앱
    /// 직접 넣는 막대: 넣지 않은 앱도 켜져 있으면 뒤쪽에 구분선과 함께 보여 줌 (Dock 가운데 칸처럼)
    var showRunning: Bool {
        get { d.object(forKey: k("favShowRunning")) as? Bool ?? true }
        set { d.set(newValue, forKey: k("favShowRunning")); rebuild() }
    }
    /// 켜져 있지만 막대에 넣지 않은 앱들 (켠 순서)
    func runningExtras() -> [String] {
        guard !isDesktop, showRunning else { return [] }
        let me = Bundle.main.bundleIdentifier
        let f = Set(favs)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .compactMap { $0.bundleIdentifier }
            .filter { $0 != me && !f.contains($0) && seen.insert($0).inserted }
    }
    fileprivate var lastExtras: [String] = []

    var favs: [String] {
        get { isDesktop ? deskCache : (d.stringArray(forKey: k("favApps")) ?? []) }
        set { guard !isDesktop else { return }; d.set(newValue, forKey: k("favApps")); rebuild(); onChange() }
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
    /// 같은 가장자리에 있는 막대들 사이 순서 (가장자리를 따라 0 = 아래/왼쪽 … 1 = 위/오른쪽). 없으면 자리(pos) 대로
    var order: Double? {
        get { d.object(forKey: k("favOrder")) as? Double }
        set { if let v = newValue { d.set(v, forKey: k("favOrder")) } else { d.removeObject(forKey: k("favOrder")) } }
    }

    /// 같은 모니터 · 같은 가장자리의 막대들, 지금 화면 순서대로 (아래/왼쪽부터)
    func neighbors() -> [FavBar] {
        guard let me = panel else { return [self] }
        let vert = edge.vertical
        return Self.all.filter { b in
            guard let p = b.panel, b.edge == edge else { return false }
            return p.screen == me.screen
        }.sorted { a, b in
            let fa = a.panel!.frame, fb = b.panel!.frame
            return vert ? fa.midY < fb.midY : fa.midX < fb.midX
        }
    }
    /// 한 칸 앞 / 뒤로 (by: -1 = 아래/왼쪽, +1 = 위/오른쪽)
    func moveOrder(by step: Int) {
        var list = neighbors()
        guard let i = list.firstIndex(where: { $0 === self }) else { return }
        let j = i + step
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        // 지금 순서대로 고르게 번호를 다시 매기고, 같은 자리에 모이게 해서 순서만 바뀌도록
        for (n, b) in list.enumerated() { b.order = (Double(n) + 0.5) / Double(list.count) }
        let p = list[i].pos
        list[i].pos = list[j].pos
        list[j].pos = p
        Self.layoutAll(animate: true)
    }

    /// 가장자리에서 몇 번째 줄 (0 = 화면 끝에 붙은 줄, 1 = 그 옆 줄 …). 같은 가장자리에 막대를 옆으로 나란히 놓을 때
    var lane: Int {
        get { d.integer(forKey: k("favLane")) }
        set { d.set(newValue, forKey: k("favLane")) }
    }
    /// 줄 사이 간격
    static let laneGap: CGFloat = 6

    /// 끄는 막대 가운데 c 가 가장자리에서 얼마나 떨어졌는지로 몇 번째 줄인지 (있는 줄 + 1 까지만)
    private func laneAt(_ c: NSPoint, edge e: Edge, screen s: NSScreen, size sz: NSSize) -> Int {
        let vf = s.visibleFrame
        let thick = e.vertical ? sz.width : sz.height
        let dist: CGFloat
        switch e {
        case .left: dist = c.x - vf.minX
        case .right: dist = vf.maxX - c.x
        case .top: dist = vf.maxY - c.y
        case .bottom: dist = c.y - vf.minY
        }
        let unit = FavBarView.thick + Self.laneGap
        let n = Int((max(0, dist - thick / 2) / unit + 0.5).rounded(.down))
        let others = Self.all.filter { $0 !== self && $0.edge == e && $0.screen == s }
        let top = (others.map(\.lane).max() ?? -1) + 1
        return min(max(n, 0), top)
    }
    /// 줄 번호를 0 부터 빈틈없이 다시 매김 (가운데 줄이 비면 바깥 줄을 안으로 당김)
    static func compactLanes() {
        var groups: [String: [FavBar]] = [:]
        for b in all { groups["\(b.edge.rawValue)|\(NSStringFromRect(b.screen.frame))", default: []].append(b) }
        for g in groups.values {
            let used = Set(g.map(\.lane)).sorted()
            for b in g { b.lane = used.firstIndex(of: b.lane) ?? 0 }
        }
    }

    var collapsed: Bool {
        get { d.bool(forKey: k("favCollapsed")) }
        set { d.set(newValue, forKey: k("favCollapsed")); if newValue { peek = false }; rebuild() }
    }

    // MARK: 손잡이에 마우스를 대면 잠깐 펴기 (옵션) — 벗어나면 다시 접음
    /// 직접 접었으면 마우스가 손잡이에서 한 번 벗어날 때까지 '마우스를 대면 펴기' 를 쉼
    /// (메뉴에서 접어 두기를 누르면 마우스가 바로 손잡이 위라 곧장 다시 펴졌음)
    var noPeekUntilLeave = false
    func collapseByUser() {
        noPeekUntilLeave = true
        collapsed = true
        // 손잡이가 마우스 밑에 안 생겼으면 바로 풀어 줌
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noPeekUntilLeave else { return }
                if !(self.panel?.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) ?? false) { self.noPeekUntilLeave = false }
            }
        }
    }
    private var peek = false
    private var peekTimer: Timer?
    private var outSince: Date?
    func peekOpen() {
        guard collapsed else { return }
        collapsed = false
        peek = true
        outSince = nil
        peekTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.peekTick() } }
        RunLoop.main.add(t, forMode: .common)
        peekTimer = t
    }
    private func peekTick() {
        guard peek, !collapsed, let p = panel else { peekTimer?.invalidate(); peekTimer = nil; peek = false; return }
        let inside = p.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        let busy = editing || NSEvent.pressedMouseButtons != 0 || MenuWatch.open
        if inside || busy { outSince = nil; return }
        if outSince == nil { outSince = Date() }
        if Date().timeIntervalSince(outSince!) > Motion.closeDelay {
            peekTimer?.invalidate(); peekTimer = nil
            collapsed = true
        }
    }

    // MARK: 넣기 · 빼기 · 순서

    func contains(_ id: String) -> Bool { favs.contains(id) }
    /// 편집 모드: [+] 와 빼기(✕) 가 보임. 막대가 비어 있으면 [+] 는 늘 보임
    var editing = false { didSet { if editing != oldValue { rebuild(animate: false) } } }
    var showsPlus: Bool { !isDesktop && (editing || favs.isEmpty) }
    /// 막대가 넘쳐 스크롤될 때 보던 자리 · 방금 넣어서 보여 줄 앱
    var scrollOffset: CGFloat = 0
    var revealID: String?

    /// 넣기 (이미 있으면 그 자리로 옮기기). at 이 없으면 맨 뒤
    func insert(_ id: String, at index: Int? = nil) {
        guard !isDesktop, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return }
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

    func start() {
        if enabled { for b in Self.all { b.show() } }
        Self.watchDesktops()
        BarReserve.start()
        GreenZoom.start()
        WindowDeskDrop.start()
    }

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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 켜진 앱 칸이 바뀌었으면 막대를 다시 그림, 아니면 점만
                    if !self.isDesktop, self.showRunning, !self.collapsed, self.runningExtras() != self.lastExtras { self.rebuild(animate: true) }
                    else { (self.panel?.contentView as? FavBarView)?.refreshRunning() }
                }
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
            : FavBarView(edge: edge, bar: self, ids: favs, extras: { lastExtras = runningExtras(); return lastExtras }(), maxMain: edge.vertical ? vf.height : vf.width)
        place(animate: animate)
    }

    var screen: NSScreen {
        let n = d.integer(forKey: k("favScreen"))
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == n }
            ?? NSScreen.screens.first ?? NSScreen.main!
    }

    func place(animate: Bool) { Self.layoutAll(animate: animate) }

    private static var reserveJob: DispatchWorkItem?
    /// 모든 막대 자리 정하기: 같은 모니터 · 같은 가장자리의 막대들은 겹치지 않게 가장자리를 따라 나란히
    /// (원래 가려던 자리 순서는 지키고, 겹치면 옆으로 밀고, 화면 끝을 넘으면 반대로 당김)
    static func layoutAll(animate: Bool) {
        compactLanes()
        defer {
            // 막대 자리가 바뀌었으면 다른 앱 창도 다시 비켜 줌 (옵션)
            if BarReserve.enabled {
                reserveJob?.cancel()
                let j = DispatchWorkItem { MainActor.assumeIsolated { BarReserve.fixAll() } }
                reserveJob = j
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration + 0.3, execute: j)
            }
        }
        for it in computeFrames() {
            if animate, Motion.duration > 0, let p = it.bar.panel, p.isVisible {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = Motion.duration
                    p.animator().setFrame(it.f, display: true)
                }
            } else {
                it.bar.panel?.setFrame(it.f, display: true)
            }
        }
    }

    /// 막대가 놓일 자리 계산값 (끌고 있는 막대가 있으면 그 막대를 '지금 놓으면' 자리로 넣어서)
    struct Plan { var edge: Edge; var pos: CGFloat; var order: Double?; var size: NSSize; var screen: NSScreen; var lane = 0 }
    static func computeFrames(override: (bar: FavBar, plan: Plan)? = nil, orders: [ObjectIdentifier: Double] = [:]) -> [(bar: FavBar, f: NSRect)] {
        var out: [(bar: FavBar, f: NSRect)] = []
        // 막대마다: 가장자리 · 자리 · 순서 · 크기 · 모니터 (끌고 있는 막대는 지금 놓으면 될 값으로)
        typealias It = (bar: FavBar, f: NSRect, edge: Edge, order: Double?, vf: NSRect)
        var groups: [String: [It]] = [:]
        // 먼저 막대마다 놓일 값을 정하고, 줄마다 두께(가장 두꺼운 막대)를 잼
        var plans: [(b: FavBar, pl: Plan)] = []
        var laneThick: [String: CGFloat] = [:]
        for b in all {
            guard let p = b.panel, let v = p.contentView as? FavBase else { continue }
            var pl = override?.bar === b ? override!.plan : Plan(edge: b.edge, pos: b.pos, order: b.order, size: v.wantSize, screen: b.screen, lane: b.lane)
            if let o = orders[ObjectIdentifier(b)] { pl.order = o }
            plans.append((b, pl))
            let side = "\(pl.edge.rawValue)|\(NSStringFromRect(pl.screen.visibleFrame))"
            let t = pl.edge.vertical ? pl.size.width : pl.size.height
            laneThick["\(side)|\(pl.lane)"] = max(laneThick["\(side)|\(pl.lane)"] ?? 0, t)
        }
        for (b, pl) in plans {
            let vf = pl.screen.visibleFrame
            var f = b.frame(edge: pl.edge, pos: pl.pos, size: pl.size, vf: vf)
            // 안쪽 줄들의 두께만큼 화면 안쪽으로 비켜 놓음
            let side = "\(pl.edge.rawValue)|\(NSStringFromRect(vf))"
            var off: CGFloat = 0
            if pl.lane > 0 { for l in 0..<pl.lane { if let t = laneThick["\(side)|\(l)"] { off += t + laneGap } } }
            switch pl.edge {
            case .left: f.origin.x += off
            case .right: f.origin.x -= off
            case .top: f.origin.y -= off
            case .bottom: f.origin.y += off
            }
            groups["\(side)|\(pl.lane)", default: []].append((b, f, pl.edge, pl.order, vf))
        }
        let gap: CGFloat = 8
        // 왼쪽 · 오른쪽 막대를 먼저 놓고, 위 · 아래 막대는 그 막대들을 피해서 (모서리에서 겹치지 않게)
        var placed: [(edge: Edge, f: NSRect)] = []
        let ordered = groups.values.sorted { ($0[0].edge.vertical ? 0 : 1) < ($1[0].edge.vertical ? 0 : 1) }
        for g in ordered {
            let edge = g[0].edge
            let vert = edge.vertical
            let vf = g[0].vf
            func lo(_ f: NSRect) -> CGFloat { vert ? f.minY : f.minX }
            func mid(_ f: NSRect) -> CGFloat { vert ? f.midY : f.midX }
            func len(_ f: NSRect) -> CGFloat { vert ? f.height : f.width }
            func shift(_ f: inout NSRect, to v: CGFloat) { if vert { f.origin.y = v } else { f.origin.x = v } }
            // 쓸 수 있는 구간: 위 · 아래 막대는 같은 높이에 걸치는 왼쪽 · 오른쪽 막대 안쪽으로
            var minB = vert ? vf.minY : vf.minX
            var maxB = vert ? vf.maxY : vf.maxX
            if !vert, let band = g.first?.f {
                for o in placed where o.f.minY < band.maxY && o.f.maxY > band.minY && vf.intersects(o.f) {
                    if o.edge == .left { minB = max(minB, o.f.maxX + gap) }
                    if o.edge == .right { maxB = min(maxB, o.f.minX - gap) }
                }
            }
            // 순서: 막대마다 정해 둔 순서(끌어 놓은 자리) → 없으면 가려던 자리
            let span = vert ? vf.height : vf.width, start = vert ? vf.minY : vf.minX
            func key(_ it: It) -> Double { it.order ?? Double((mid(it.f) - start) / span) }
            var items = g.enumerated().sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
            // 같은 가장자리에 막대가 여럿이면: 순서대로 붙여 한 줄로 세우고, 그 줄을 가장자리 가운데에
            // (막대마다의 시작 · 가운데 · 끝 자리는 무시 — 순서를 바꾸다가 한 막대만 모서리로 튕겨 나가지 않게)
            if items.count > 1 {
                let total = items.map { len($0.f) }.reduce(0, +) + gap * CGFloat(items.count - 1)
                var at = min(max((minB + maxB) / 2 - total / 2, minB), max(minB, maxB - total))
                for it in items {
                    var f = it.f
                    shift(&f, to: at)
                    at += len(f) + gap
                    out.append((it.bar, f))
                    placed.append((edge, f))
                }
                continue
            }
            // 먼저 쓸 수 있는 구간 안으로
            for k in items.indices {
                var f = items[k].f
                shift(&f, to: min(max(lo(f), minB), maxB - len(f)))
                items[k].f = f
            }
            let want = items.map(\.f)
            // 앞에서부터: 앞 막대와 겹치면 뒤로 밈
            func push() {
                var end = minB - gap
                for k in items.indices {
                    var f = items[k].f
                    shift(&f, to: max(lo(f), end + gap))
                    end = lo(f) + len(f)
                    items[k].f = f
                }
            }
            // 뒤에서부터: 구간 끝을 넘으면 앞으로 당김
            func pull() {
                var limit = maxB
                for k in items.indices.reversed() {
                    var f = items[k].f
                    if lo(f) + len(f) > limit { shift(&f, to: limit - len(f)) }
                    limit = lo(f) - gap
                    items[k].f = f
                }
            }
            push()
            // 밀려서 이어진 묶음은 원래 가려던 자리를 가운데로 두도록 통째로 당김 (한쪽으로 쏠리지 않게)
            var i = 0
            while i < items.count {
                var j = i
                while j + 1 < items.count && abs(lo(items[j + 1].f) - (lo(items[j].f) + len(items[j].f) + gap)) < 0.5 && lo(items[j + 1].f) > lo(want[j + 1]) + 0.5 { j += 1 }
                if j > i {
                    let delta = (i...j).map { mid(want[$0]) - mid(items[$0].f) }.reduce(0, +) / CGFloat(j - i + 1)
                    for k in i...j { var f = items[k].f; shift(&f, to: lo(f) + delta); items[k].f = f }
                }
                i = j + 1
            }
            push()
            pull()
            push()   // 당기다가 시작 쪽을 넘었으면 다시 안으로
            for it in items {
                out.append((it.bar, it.f))
                placed.append((edge, it.f))
            }
        }
        return out
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
    /// 끌기 시작할 때 다른 막대들이 있던 자리 (끼어들 순서를 이 위치 가운데 기준으로 정함 — 위 · 아래 같은 기준)
    private static var restFrames: [(bar: FavBar, f: NSRect)] = []
    /// 끄는 동안 정한 순서 (놓을 때 저장)
    private static var liveOrders: [ObjectIdentifier: Double] = [:]
    func beginMove() {
        guard let p = panel else { return }
        grab = (NSEvent.mouseLocation, p.frame.origin)
        Self.restFrames = Self.all.compactMap { b in b === self ? nil : b.panel.map { (b, $0.frame) } }
        Self.liveOrders = [:]
    }
    /// 끄는 동안 다른 막대들이 가 있을 자리 (같은 자리로 애니메이션을 다시 걸지 않게)
    private static var liveTargets: [ObjectIdentifier: NSRect] = [:]
    func moving() {
        guard let p = panel, let g = grab else { return }
        let m = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: g.origin.x + m.x - g.mouse.x, y: g.origin.y + m.y - g.mouse.y))
        guard let v = p.contentView as? FavBase else { return }
        // 지금 놓으면: 가장자리 · 자리 · 순서 (막대 방향이 바뀌면 가로세로를 바꿔서)
        let c = NSPoint(x: p.frame.midX, y: p.frame.midY)
        let (e, ps, s, sz) = target(c, size: v.wantSize)
        let vf = s.visibleFrame
        let ln = laneAt(c, edge: e, screen: s, size: sz)
        // 같은 가장자리 · 모니터 · 같은 줄의 다른 막대들을 끌기 전 자리 순서대로 세우고, 끄는 막대 가운데가 몇 개를 넘었는지로 끼어들 자리
        let mine = Self.restFrames.filter { $0.bar.edge == e && $0.bar.lane == ln && vf.intersects($0.f) }
            .sorted { e.vertical ? $0.f.midY < $1.f.midY : $0.f.midX < $1.f.midX }
        // 이웃 막대에 '닿으면' 바로 자리를 바꿈 (예전엔 가운데를 넘어야 해서 한참 끌어야 했음)
        // 끄는 방향 쪽 끝이 이웃 막대 안으로 touch 만큼 들어가면 전환
        let me = p.frame, touch: CGFloat = 10
        let startMid = e.vertical ? g.origin.y + me.height / 2 : g.origin.x + me.width / 2
        let forward = e.vertical ? me.midY > startMid : me.midX > startMid   // 위(가로면 오른쪽)로 끄는 중
        func before(_ o: NSRect) -> Bool {   // o 가 끄는 막대보다 앞(아래/왼쪽)에 놓이는지
            if e.vertical { return forward ? me.maxY > o.minY + touch : me.minY > o.maxY - touch }
            return forward ? me.maxX > o.minX + touch : me.minX > o.maxX - touch
        }
        let at = mine.filter { before($0.f) }.count
        // 자리를 바꿀 막대들 (끌기 전과 앞뒤가 달라진 막대): 밝게 표시하고 안내
        let swapped = e == edge && ln == lane ? mine.filter { it in
            let wasBefore = e.vertical ? it.f.midY < startMid : it.f.midX < startMid
            return wasBefore != before(it.f)
        }.map(\.bar) : []
        for b in Self.all where b !== self { (b.panel?.contentView as? FavBarView)?.setDropGlow(swapped.contains { $0 === b }) }
        var orders: [ObjectIdentifier: Double] = [:]
        let n = Double(mine.count + 1)
        for (i, it) in mine.enumerated() { orders[ObjectIdentifier(it.bar)] = (Double(i < at ? i : i + 1) + 0.5) / n }
        let ord = mine.isEmpty ? Double(e.vertical ? (c.y - vf.minY) / vf.height : (c.x - vf.minX) / vf.width) : (Double(at) + 0.5) / n
        orders[ObjectIdentifier(self)] = ord
        Self.liveOrders = orders
        let frames = Self.computeFrames(override: (self, Plan(edge: e, pos: ps, order: ord, size: sz, screen: s, lane: ln)), orders: orders)
        // 다른 막대들은 그 자리로 미끄러져 비켜 줌 (사이에 끼어들 빈자리가 생김)
        for it in frames where it.bar !== self {
            guard let bp = it.bar.panel, bp.isVisible else { continue }
            let id = ObjectIdentifier(it.bar)
            if let t = Self.liveTargets[id], t.equalTo(it.f) { continue }
            Self.liveTargets[id] = it.f
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = max(0.12, Motion.duration * 0.8)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bp.animator().setFrame(it.f, display: true)
            }
        }
        // 놓일 빈자리를 파란 테두리로
        let ghost = frames.first { $0.bar === self }?.f ?? frame(edge: e, pos: ps, size: sz, vf: vf)
        let ie: EdgeIndicator.Edge = e == .left ? .left : e == .right ? .right : e == .top ? .top : .bottom
        let names = swapped.map { $0.desktop.map { "\($0)번" } ?? $0.name }.joined(separator: " · ")
        EdgeIndicator.shared.show(screen: s, edge: ie, zone: 0, active: true, ghost: ghost,
                                  text: swapped.isEmpty ? nil : "놓으면 \(names) 막대와 자리를 바꿔요")
    }
    func endMove() {
        guard grab != nil else { return }
        grab = nil
        Self.liveTargets = [:]
        EdgeIndicator.shared.hide()
        for b in Self.all { (b.panel?.contentView as? FavBarView)?.setDropGlow(false) }
        guard let p = panel, let v = p.contentView as? FavBase else { return }
        let c = NSPoint(x: p.frame.midX, y: p.frame.midY)
        let (e, ps, s, sz) = target(c, size: v.wantSize)
        lane = laneAt(c, edge: e, screen: s, size: sz)
        edge = e
        pos = ps
        // 끄는 동안 보여 준 순서 그대로 저장 (그 사이에 끼어 들어감)
        if Self.liveOrders.isEmpty {
            let vf = s.visibleFrame
            order = Double(e.vertical ? (c.y - vf.minY) / vf.height : (c.x - vf.minX) / vf.width)
        } else {
            for b in Self.all { if let o = Self.liveOrders[ObjectIdentifier(b)] { b.order = o } }
        }
        Self.liveOrders = [:]
        Self.restFrames = []
        d.set((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0, forKey: k("favScreen"))
        rebuild()
    }

    /// 데스크탑 막대들을 한꺼번에 한 가장자리로 (위 · 아래면 가로로 늘어섬). 순서는 지금 늘어선 차례 그대로
    static func setEdgeForAll(_ e: Edge) {
        let sorted = all.filter(\.isDesktop).sorted { a, b in
            let fa = a.panel?.frame ?? .zero, fb = b.panel?.frame ?? .zero
            return a.edge.vertical ? fa.midY > fb.midY : fa.minX < fb.minX   // 세로였으면 위에서부터 → 가로에선 왼쪽부터
        }
        let n = Double(max(1, sorted.count))
        for (i, b) in sorted.enumerated() {
            b.edge = e
            // 세로(아래가 0)는 위에 있던 게 위로 · 가로는 왼쪽부터
            b.order = e.vertical ? 1 - (Double(i) + 0.5) / n : (Double(i) + 0.5) / n
        }
        for b in all { b.rebuild(animate: true) }
        shared.onChange()
    }

    /// 막대들을 한꺼번에 다른 모니터로 (가장자리 · 순서 · 줄은 그대로). desktopOnly 면 데스크탑 막대만
    static func setScreenForAll(_ scr: NSScreen, bars: [FavBar]) {
        let num = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        for b in bars { b.d.set(num, forKey: b.k("favScreen")) }
        for b in all { b.rebuild(animate: true) }
        shared.onChange()
    }
    /// 지금 데스크탑 막대들이 놓인 모니터 (여럿이면 첫 막대 기준)
    static var desktopBarsScreen: NSScreen? { all.first(where: \.isDesktop)?.screen }
    /// 우클릭 메뉴용: 다른 모니터로 옮기기 (데스크탑 막대면 전부, 아니면 이 막대만)
    func screenMenuItem() -> NSMenuItem? {
        guard NSScreen.screens.count > 1 else { return nil }
        let targets = isDesktop ? Self.all.filter(\.isDesktop) : [self]
        let it = NSMenuItem(title: isDesktop ? "데스크탑 막대 전부 다른 모니터로" : "다른 모니터로", action: nil, keyEquivalent: "")
        let m = NSMenu()
        for scr in NSScreen.screens {
            let a = MenuAction(scr.localizedName) { FavBar.setScreenForAll(scr, bars: targets) }
            a.state = scr == screen ? .on : .off
            m.addItem(a)
        }
        it.submenu = m
        return it
    }

    // MARK: [+] 메뉴

    func showAddMenu(from v: NSView) { FavPicker.shared.show(near: v, bar: self) }

    /// 도구함 아이콘 메뉴용: 막대가 하나면 넣기/빼기, 여러 개면 막대를 고르는 하위 메뉴
    static func menuItem(for id: String) -> NSMenuItem {
        var bs = all.filter { !$0.isDesktop }
        if bs.isEmpty { bs = [all.first ?? bar("")] }
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

    /// 데스크탑 닫기: macOS 가 프로그램으로 지우는 걸 막아서, Mission Control 을 열고 어디를 누를지 안내
    /// (사용자가 ✕ 를 누르면 데스크탑이 없어지고, 그 막대도 저절로 닫힘)
    static func closeDesktopHelp(_ n: Int) {
        let label = Spaces.numbered().desks.first { $0.n == n }?.label ?? "데스크탑 \(n)"
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        // 안내 말풍선 (Mission Control 위, 화면 위쪽 가운데) — 몇 초 뒤 사라짐
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let t = NSTextField(labelWithString: "‘\(label.replacingOccurrences(of: " · ", with: " ("))\(label.contains(" · ") ? ")" : "")’ 에 마우스를 올리고 왼쪽 위 ✕ 를 누르세요 · 막대도 같이 닫혀요")
            t.font = .systemFont(ofSize: 14, weight: .semibold)
            t.textColor = .white
            t.sizeToFit()
            let w = t.frame.width + 32, h: CGFloat = 40
            let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.launcherAccent.withAlphaComponent(0.92).cgColor
            v.layer?.cornerRadius = 12
            t.setFrameOrigin(NSPoint(x: 16, y: (h - t.frame.height) / 2))
            v.addSubview(t)
            p.contentView = v
            let disp = Spaces.numbered().desks.first { $0.n == n }?.display
            let scr = NSScreen.screens.first { Spaces.uuid(of: $0) == disp } ?? NSScreen.main ?? NSScreen.screens[0]
            p.setFrame(NSRect(x: scr.frame.midX - w / 2, y: scr.frame.maxY - 150, width: w, height: h), display: true)
            p.orderFrontRegardless()
            closeHint = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { closeHint?.orderOut(nil); closeHint = nil } }
        }
    }
    private static var closeHint: NSPanel?

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
        // 붙일 곳 · 정렬 · 순서는 막대를 끌어서 바꿈
        let cl = MenuAction("접어 두기") { if bar.collapsed { bar.collapsed = false } else { bar.collapseByUser() } }
        cl.state = bar.collapsed ? .on : .off
        m.addItem(cl)
        let hv = MenuAction("접힌 손잡이에 마우스를 대면 펴기") { EdgeDock.hoverExpand.toggle() }
        hv.state = EdgeDock.hoverExpand ? .on : .off
        m.addItem(hv)
        let rs = MenuAction("막대 자리 비워 두기 (다른 앱 창이 침범하지 않게)") { BarReserve.enabled.toggle() }
        rs.state = BarReserve.enabled ? .on : .off
        m.addItem(rs)
        if !bar.isDesktop {
            m.addItem(MenuAction(bar.editing ? "편집 끝내기" : "편집 (넣기 · 빼기)") { bar.editing.toggle() })
            let sr = MenuAction("켜진 앱도 보이기 (Dock 처럼 구분선 뒤에)") { bar.showRunning.toggle() }
            sr.state = bar.showRunning ? .on : .off
            m.addItem(sr)
        }
        if let sm = bar.screenMenuItem() { m.addItem(sm) }
        // 막대 종류: 직접 넣는 막대 / 데스크탑 n 에 열린 앱
        let desks = Spaces.numbered().desks
        let kind = NSMenuItem(title: "막대 종류", action: nil, keyEquivalent: "")
        let km = NSMenu()
        km.autoenablesItems = false
        let manual = MenuAction("자주 쓰는 앱 (직접 넣기)") { bar.desktop = nil }
        manual.state = bar.isDesktop ? .off : .on
        km.addItem(manual)
        km.addItem(.separator())
        for dk in desks {
            let taken = bar.desktop != dk.n && FavBar.hasBar(forDesktop: dk.n)
            let it = MenuAction("\(dk.label)에 열린 앱" + (taken ? " (막대 있음)" : "")) { bar.desktop = dk.n; if bar.name.hasPrefix("막대 ") { bar.name = "데스크탑 \(dk.n)" } }
            it.state = bar.desktop == dk.n ? .on : .off
            it.isEnabled = !taken
            km.addItem(it)
        }
        kind.submenu = km
        m.addItem(kind)
        m.addItem(.separator())
        let add = NSMenuItem(title: "막대 추가", action: nil, keyEquivalent: "")
        let addm = NSMenu()
        addm.addItem(MenuAction("자주 쓰는 앱 막대") { FavBar.addBar() })
        addm.autoenablesItems = false
        for dk in desks {
            let taken = FavBar.hasBar(forDesktop: dk.n)
            let it = MenuAction("\(dk.label) 막대 (열린 앱 자동)" + (taken ? " — 이미 있음" : "")) { FavBar.addDesktopBar(dk.n) }
            it.isEnabled = !taken
            addm.addItem(it)
        }
        add.submenu = addm
        m.addItem(add)
        m.addItem(MenuAction("이 막대 이름 바꾸기…") { [bar] in bar.askRename() })
        if FavBar.all.count > 1 { m.addItem(MenuAction("이 막대 지우기…") { [bar] in bar.confirmDelete() }) }
        if let n = bar.desktop {
            m.addItem(MenuAction("데스크탑 \(n) 닫기… (Mission Control 열기)") { FavBar.closeDesktopHelp(n) })
        }
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

    // 옵션: 마우스를 대면 펴기
    private var hoverJob: DispatchWorkItem?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        guard EdgeDock.hoverExpand, !bar.noPeekUntilLeave else { return }
        hoverJob?.cancel()
        let bar = self.bar
        let job = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, w.frame.contains(NSEvent.mouseLocation) else { return }
                bar.peekOpen()
            }
        }
        hoverJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.openDelay, execute: job)
    }
    override func mouseExited(with e: NSEvent) { hoverJob?.cancel(); bar.noPeekUntilLeave = false }
}

// MARK: - 펴진 막대

@MainActor
final class FavBarView: FavBase {
    static let thick: CGFloat = 52, cell: CGFloat = 44, pad: CGFloat = 6, grip: CGFloat = 12, chev: CGFloat = 24
    /// 손잡이 · [+] · 접기 버튼이 차지하는 길이 (앱 칸 말고)
    private let showPlus: Bool
    private let editing: Bool
    /// 손잡이 칸 길이 (데스크탑 막대는 번호 배지가 들어가서 조금 길게)
    private var gripLen: CGFloat { bar.isDesktop ? (FavBar.multiMonitor ? (edge.vertical ? 38 : 36) : 24) : Self.grip }
    private var fixedLen: CGFloat { Self.pad * 2 + gripLen + (showPlus ? Self.cell : 0) + Self.chev }
    let ids: [String]
    /// 켜져 있지만 넣지 않은 앱 (구분선 뒤)
    let extras: [String]
    private var extraCells: [FavAppCell] = []
    private let divider = NSView()
    static let divGap: CGFloat = 12
    private var docLength: CGFloat { CGFloat(ids.count) * Self.cell + (extras.isEmpty ? 0 : Self.divGap + CGFloat(extras.count) * Self.cell) }
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
    private var listLen: CGFloat { min(docLength, max(Self.cell, maxMain - fixedLen)) }
    private var overflow: Bool { docLength > listLen + 0.5 }

    override var wantSize: NSSize {
        let main = fixedLen + listLen
        return edge.vertical ? NSSize(width: Self.thick, height: main) : NSSize(width: main, height: Self.thick)
    }

    init(edge: FavBar.Edge, bar: FavBar, ids: [String], extras: [String] = [], maxMain: CGFloat) {
        self.ids = ids
        self.extras = extras
        self.maxMain = maxMain
        showPlus = bar.showsPlus
        editing = bar.editing
        super.init(edge: edge, bar: bar)
        plus.bar = bar
        layer?.backgroundColor = (bar.isDesktop ? NSColor(red: 0.10, green: 0.14, blue: 0.24, alpha: 0.93)
                                                : NSColor(white: 0.13, alpha: 0.92)).cgColor
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
        // 구분선 뒤: 켜진 앱 (넣지 않은 것)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        divider.layer?.cornerRadius = 0.5
        divider.isHidden = extras.isEmpty
        doc.addSubview(divider)
        for id in extras {
            let c = FavAppCell(id: id, edge: edge, bar: bar, editing: false)
            c.isExtra = true
            extraCells.append(c)
            doc.addSubview(c)
        }
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.launcherAccent.cgColor
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
            chevron.contentTintColor = .launcherAccent
            chevron.toolTip = "편집 끝내기"
            chevron.action = #selector(endEdit)
        }
        addSubview(chevron)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshState() } }
        if let n = bar.desktop {
            toolTip = (ids.isEmpty ? "데스크탑 \(n)에 열린 앱이 없어요" : "데스크탑 \(n)에 열린 앱 (저절로 바뀌어요)") + " · 번호를 누르면 데스크탑 \(n)으로"
        } else {
            toolTip = ids.isEmpty ? "[+] 를 누르거나 도구함의 아이콘을 끌어다 놓으세요 · 빈 곳을 끌면 다른 가장자리로 옮겨요" : nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func collapse() { bar.collapseByUser() }

    /// 데스크탑 막대: 번호 배지 (막대 빈 곳) 를 누르면 그 데스크탑으로
    override func clicked() {
        guard let n = bar.desktop else { return }
        Spaces.switchTo(n, apps: bar.favs)
    }
    @objc private func endEdit() { bar.editing = false }

    private var restored = false
    override func layout() {
        super.layout()
        let a0 = Self.pad + gripLen
        let L = listLen
        let off = (Self.thick - Self.cell) / 2
        scroll.frame = edge.vertical ? NSRect(x: 0, y: a0, width: Self.thick, height: L) : NSRect(x: a0, y: 0, width: L, height: Self.thick)
        let docLen = docLength
        doc.frame = edge.vertical ? NSRect(x: 0, y: 0, width: Self.thick, height: docLen) : NSRect(x: 0, y: 0, width: docLen, height: Self.thick)
        for (i, c) in cells.enumerated() {
            let a = CGFloat(i) * Self.cell
            c.frame = edge.vertical ? NSRect(x: off, y: a, width: Self.cell, height: Self.cell) : NSRect(x: a, y: off, width: Self.cell, height: Self.cell)
        }
        if !extras.isEmpty {
            let d0 = CGFloat(ids.count) * Self.cell + Self.divGap / 2
            let dl = Self.thick * 0.55
            divider.frame = edge.vertical ? NSRect(x: (Self.thick - dl) / 2, y: d0 - 0.5, width: dl, height: 1)
                                          : NSRect(x: d0 - 0.5, y: (Self.thick - dl) / 2, width: 1, height: dl)
            for (i, c) in extraCells.enumerated() {
                let a = CGFloat(ids.count) * Self.cell + Self.divGap + CGFloat(i) * Self.cell
                c.frame = edge.vertical ? NSRect(x: off, y: a, width: Self.cell, height: Self.cell) : NSRect(x: a, y: off, width: Self.cell, height: Self.cell)
            }
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
        // 데스크탑 막대: 손잡이 자리에 데스크탑 번호 배지
        if let n = bar.desktop {
            let mon = FavBar.multiMonitor ? FavBar.deskMonitor[n] : nil
            // 모니터 이름을 아래에 붙일 땐 배지를 조금 위로
            var c = edge.vertical ? NSPoint(x: bounds.midX, y: Self.pad + gripLen / 2) : NSPoint(x: Self.pad + gripLen / 2, y: bounds.midY)
            if mon != nil { c.y -= 6 }
            let box = NSRect(x: c.x - 10, y: c.y - 9, width: 20, height: 18)
            // 지금 모니터에 보이고 있는 데스크탑이면 모니터 색 배지 (모니터가 하나면 파랑), 아니면 회색
            let col = FavBar.monitorColor(mon?.index ?? 0)
            (FavBar.currentDesks.contains(n) ? col : NSColor(white: 0.42, alpha: 1)).withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            let t = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
            let sz = t.size()
            t.draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
            // 배지 아래 모니터 이름 (모니터 색으로 살짝)
            if let mon {
                let mt = NSAttributedString(string: mon.name, attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                                                                           .foregroundColor: col.blended(withFraction: 0.45, of: .white) ?? col])
                let ms = mt.size()
                mt.draw(at: NSPoint(x: c.x - ms.width / 2, y: c.y + 10))
            }
            return
        }
        // 손잡이: 점 세 개 (여기를 잡고 끌면 막대가 옮겨짐)
        NSColor(white: 1, alpha: 0.35).setFill()
        for k in -1...1 {
            let c = edge.vertical ? NSPoint(x: bounds.midX + CGFloat(k) * 6, y: Self.pad + gripLen / 2)
                                  : NSPoint(x: Self.pad + gripLen / 2, y: bounds.midY + CGFloat(k) * 6)
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
        }
    }

    func refreshRunning() { (cells + extraCells).forEach { $0.needsDisplay = true } }

    /// 지금 보이는 데스크탑인지에 따라 막대 모양 · 아이콘 점 다시
    func refreshState() {
        (cells + extraCells).forEach { $0.needsDisplay = true }
        needsDisplay = true
        guard let n = bar.desktop else { return }
        let now = FavBar.currentDesks.contains(n)
        alphaValue = now ? 1 : 0.72
        layer?.borderColor = now ? NSColor.launcherAccent.withAlphaComponent(0.7).cgColor : NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = now ? 1.5 : 1
    }

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
        // 데스크탑 막대: 켜져 있는 앱을 놓으면 그 데스크탑으로 창을 옮김 (막대 테두리를 밝혀서 알려 줌)
        if let n = bar.desktop {
            let ids = FavBar.ids(from: s.draggingPasteboard).filter { FavBar.movable($0, toDesktop: n) }
            setDropGlow(!ids.isEmpty)
            return ids.isEmpty ? [] : .move
        }
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
    override func draggingExited(_ s: NSDraggingInfo?) { showMarker(nil); setDropGlow(false) }
    func setDropGlow(_ on: Bool) {
        layer?.borderColor = on ? NSColor.launcherAccent.cgColor : NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = on ? 2 : 1
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        showMarker(nil)
        setDropGlow(false)
        if let n = bar.desktop {
            let ids = FavBar.ids(from: s.draggingPasteboard).filter { FavBar.movable($0, toDesktop: n) }
            guard let id = ids.first else { return false }
            DispatchQueue.main.async { MainActor.assumeIsolated { FavBar.moveApp(id, toDesktop: n) } }
            return true
        }
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
    /// 막대에 넣지 않았지만 켜져 있어서 보이는 칸 (구분선 뒤)
    var isExtra = false { didSet { toolTip = isExtra ? "\(name) · 켜져 있는 앱 (오른쪽 클릭: 막대에 고정)" : toolTip } }
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
        if bar.isDesktop && bar.deskMin.contains(id) { HoverTip.shared.schedule("\(name)\n내려 두거나 닫아 둔 창 · 누르면 올라와요", for: self); return }
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
        guard hovering, !measuring, let r = mainApp(id) else { return }
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
        // Dock 으로 내려 둔 창만 있는 앱: 흐린 아이콘 + 점선 테두리 (누르면 올라옴)
        let min = bar.isDesktop && bar.deskMin.contains(id)
        icon.draw(in: bounds.insetBy(dx: 6, dy: 6), from: .zero, operation: .sourceOver, fraction: min ? 0.5 : 1, respectFlipped: true, hints: nil)
        if min {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
            p.lineWidth = 1.5
            p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(white: 1, alpha: 0.7).setStroke()
            p.stroke()
        }
        if running && !min {
            // 실행 중 점: 화면 가장자리 쪽에
            NSColor(white: 1, alpha: 0.85).setFill()
            let c: NSPoint
            switch edge {
            case .left: c = NSPoint(x: 2.5, y: bounds.midY)
            case .right: c = NSPoint(x: bounds.maxX - 2.5, y: bounds.midY)
            case .top: c = NSPoint(x: bounds.midX, y: 2.5)
            case .bottom: c = NSPoint(x: bounds.midX, y: bounds.maxY - 2.5)
            }
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            if FavBar.onScreenApps.contains(id) {
                dot.fill()                                  // ● 지금 화면에 창이 보임
            } else {
                NSColor(white: 1, alpha: 0.55).setStroke()  // ○ 켜져 있지만 지금 화면엔 안 보임
                dot.lineWidth = 1
                dot.stroke()
            }
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
            if bar.isDesktop { bar.toggleDeskApp(id) } else { bar.open(id) }
        }
    }

    // 막대 안 → 순서 바꾸기, 도구함 창 → 도구함에 넣기, 그 밖으로 놓으면 막대에서 빠짐
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation.isEmpty, !bar.isDesktop, !isExtra {
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
        if let r = mainApp(id) {
            m.addItem(MenuAction(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
            m.addItem(MenuAction("종료") { r.terminate() })
        }
        m.addItem(.separator())
        if let mv = FavBar.moveMenu(for: id, except: bar.desktop) { m.addItem(mv); m.addItem(.separator()) }
        if bar.isDesktop {
            m.addItem(FavBar.menuItem(for: id))
            NSMenu.popUpContextMenu(m, with: e, for: self)
            return
        }
        if isExtra {
            m.addItem(MenuAction("이 막대에 고정") { [id] in bar.insert(id, at: bar.favs.count) })
            m.addItem(MenuAction("켜진 앱 보이지 않기 (이 막대)") { bar.showRunning = false })
            NSMenu.popUpContextMenu(m, with: e, for: self)
            return
        }
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
    private(set) var panel: NSPanel?
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

// MARK: - 다른 앱 창을 데스크탑 막대 위로 끌어 오면 그 데스크탑으로
// 창을 잡고 끄는 중에 데스크탑 막대 위에 0.3초 머무르면, ⌃← / ⌃→ 를 대신 눌러 잡고 있는 창째로 그 데스크탑으로 넘어감
// (macOS 에서 창을 잡은 채 데스크탑을 넘기면 창이 따라가는 것과 같은 원리). 다른 모니터 데스크탑이면 놓을 때 옮김

@MainActor
enum WindowDeskDrop {
    private static var monitors: [Any] = []
    /// 누른 자리에 있던 다른 앱 창 (번호 · 자리 · 앱)
    private static var held: (wid: Int, origin: CGPoint, pid: pid_t)?
    private static var over: FavBar?
    private static var dwell: DispatchWorkItem?
    private static var doneFor: Int?

    static func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { WindowDeskDrop.down() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { _ in
            MainActor.assumeIsolated { WindowDeskDrop.dragged() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            MainActor.assumeIsolated { WindowDeskDrop.up() }
        }) { monitors.append(m) }
    }

    /// 화면 좌표(왼쪽 위 기준) 마우스 자리
    private static var cgMouse: CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - m.y)
    }

    private static func windowAt(_ p: CGPoint) -> (wid: Int, origin: CGPoint, pid: pid_t)? {
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in wins {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p) else { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let wid = w[kCGWindowNumber as String] as? Int else { return nil }
            return (wid, r.origin, pid)
        }
        return nil
    }
    private static func origin(of wid: Int) -> CGPoint? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return r.origin
    }

    private static func down() {
        held = windowAt(cgMouse)
        doneFor = nil
    }

    private static func dragged() {
        guard let h = held, doneFor != h.wid else { return }
        let m = NSEvent.mouseLocation
        // 마우스 아래 데스크탑 막대 (펼쳐져 있는 것)
        let bar = FavBar.all.first { b in
            guard b.isDesktop, !b.collapsed, let p = b.panel, p.isVisible else { return false }
            return p.frame.insetBy(dx: -6, dy: -6).contains(m)
        }
        if bar !== over {
            (over?.panel?.contentView as? FavBarView)?.setDropGlow(false)
            dwell?.cancel()
            over = bar
            guard let bar, let n = bar.desktop else { return }
            // 창을 끄는 중일 때만 (글자 고르기 같은 끌기는 무시)
            guard let o = origin(of: h.wid), abs(o.x - h.origin.x) + abs(o.y - h.origin.y) > 2 else { over = nil; return }
            (bar.panel?.contentView as? FavBarView)?.setDropGlow(true)
            let job = DispatchWorkItem {
                MainActor.assumeIsolated {
                    guard WindowDeskDrop.over === bar, NSEvent.pressedMouseButtons & 1 == 1,
                          let st = Spaces.steps(to: n), st.steps != 0 else { return }
                    let here = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }.map(Spaces.uuid(of:)) ?? ""
                    guard here == st.display else { return }   // 다른 모니터 데스크탑은 놓을 때
                    WindowDeskDrop.doneFor = h.wid
                    Spaces.pressArrows(st.steps)
                }
            }
            dwell = job
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: job)
        }
    }

    private static func up() {
        defer {
            (over?.panel?.contentView as? FavBarView)?.setDropGlow(false)
            dwell?.cancel()
            over = nil; held = nil
        }
        // 다른 모니터 데스크탑 막대 위에서 놓았으면 그때 옮김
        guard let bar = over, let n = bar.desktop, let h = held, doneFor != h.wid,
              let st = Spaces.steps(to: n), st.steps != 0 || !st.target.current else { return }
        Spaces.move(pid: h.pid, to: st.target, desks: st.desks) { _ in
            for t in [0.5, 1.2, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { FavBar.refreshDesktops() } }
            }
        }
    }
}
