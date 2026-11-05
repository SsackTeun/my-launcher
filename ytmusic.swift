// YouTube Music 미니 플레이어: 브라우저에 열린 YouTube Music 페이지의 "플레이어 바"를 읽고 조작
// 곡 정보 · 진행 · 좋아요 · 반복 · 셔플 · 볼륨 · 재생 목록. 읽기/누르기는 "손쉬운 사용" 권한으로 함
import Cocoa
import ScreenCaptureKit
@preconcurrency import ApplicationServices

/// 브라우저가 웹 페이지 내용(버튼·글자)을 손쉬운 사용 쪽에 열어 주도록 요청 (Chrome 은 둘 다 필요할 때가 있음)
func enableWebAccessibility(_ app: AXUIElement) {
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

struct PlayerState {
    var title = ""
    var byline = ""
    var time = ""
    var position: Double = 0
    var duration: Double = 0
    var playing: Bool?
    var liked = false
    var disliked = false
    var repeatLabel = ""
    var volume: Double = 100
    var muted = false
    var pageOpen = false
    var artRect: CGRect?          // 앨범 사진 자리 (화면 왼쪽 위 기준)
    /// 간단 모드: YouTube Music 이 브라우저 뒤쪽 탭에 있어 탭 제목만 읽을 수 있음
    var limited = false
    var repeatOn: Bool { !repeatLabel.isEmpty && !repeatLabel.contains("사용 안함") && !repeatLabel.lowercased().contains("off") }
    var repeatOne: Bool { repeatLabel.contains("한 곡") || repeatLabel.lowercased().contains("one") }
}

struct QueueItem {
    let title: String
    let artist: String
    let duration: String
    let current: Bool
    let button: AXUIElement
}

/// 플레이어 바 안의 조작 대상들 (백그라운드에서 읽고 메인에서 누름)
final class PlayerParts: @unchecked Sendable {
    var buttons: [String: AXUIElement] = [:]
    var progress: AXUIElement?
    var volume: AXUIElement?
}

/// 진단용 기록 (설정값 ytmDebug 가 켜져 있을 때만)
func ytmLog(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "ytmDebug") else { return }
    let path = NSHomeDirectory() + "/MyLauncher/ytm-debug.log"
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

@MainActor
final class YTMusic {
    // 화면에 보이는 이름 (한국어 · 영어)
    nonisolated static let names: [String: [String]] = [
        "prev": ["이전", "Previous"],
        "play": ["재생", "Play"],
        "pause": ["일시중지", "일시정지", "Pause"],
        "next": ["다음", "Next"],
        "shuffle": ["셔플", "Shuffle"],
        "mute": ["음소거", "Mute"],
        "unmute": ["음소거 해제", "Unmute"],
        "open": ["플레이어 페이지 열기", "Open player page"],
        "close": ["플레이어 페이지 닫기", "Close player page"],
    ]
    nonisolated static let barNames = ["플레이어 바", "Player bar"]
    nonisolated static let upNext = ["다음 트랙", "Up next", "UP NEXT"]

    struct Target {
        let pid: pid_t
        let window: AXUIElement
        var tab: AXUIElement? = nil      // 간단 모드일 때 YouTube Music 탭 버튼
    }

    private(set) var target: Target?
    private(set) var state: PlayerState?
    private(set) var art: NSImage?
    var onFoundChange: (() -> Void)?
    var onUpdate: ((PlayerState, NSImage?) -> Void)?

    private var timer: Timer?
    private let axQueue = DispatchQueue(label: "ytmusic.ax")
    private var busy = false
    private var toolbar: AXUIElement?
    private var parts = PlayerParts()
    private var lastScan = Date.distantPast
    private var artKey = ""
    private var openedPageForQueue = false

    static let browserPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "com.brave.Browser",
                                  "company.thebrowser", "org.mozilla.firefox", "com.operasoftware", "com.vivaldi"]

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setTarget(nil)
    }

    // MARK: 창 찾기

    private func isYTM(_ title: String) -> Bool { title.localizedCaseInsensitiveContains("YouTube Music") }

    private func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // 응답 없는 앱 때문에 멈추지 않게
        return AX.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private func setTarget(_ t: Target?) {
        let wasFound = target != nil
        let same = t != nil && target != nil && t!.pid == target!.pid && CFEqual(t!.window, target!.window)
        if !same {
            toolbar = nil
            parts = PlayerParts()
        }
        target = t
        if t == nil { state = nil; art = nil; artKey = "" }
        if wasFound != (t != nil) { onFoundChange?() }
    }

    func poll() {
        guard AX.trusted else { setTarget(nil); return }

        if let t = target, NSRunningApplication(processIdentifier: t.pid) != nil {
            let winIsYTM = isYTM(AX.str(t.window, kAXTitleAttribute) ?? "")
            if t.tab == nil {
                // 이미 찾은 플레이어 바가 살아 있거나 창이 아직 YouTube Music 이면 그대로
                if winIsYTM || (toolbar.map { AX.str($0, kAXRoleAttribute) != nil } ?? false) { read(); return }
            } else {
                // 간단 모드 → 그 탭이 앞으로 오면 전체 모드로
                if winIsYTM { setTarget(Target(pid: t.pid, window: t.window)); read(); return }
                if let tab = t.tab, let title = AX.str(tab, kAXTitleAttribute), isYTM(title) { readTab(title); return }
            }
        }
        // 브라우저 · YouTube Music 앱 전체에서 찾기 (못 찾은 상태면 4초에 한 번만)
        if target == nil && Date().timeIntervalSince(lastScan) < 4 { return }
        lastScan = Date()
        var tabHit: Target?
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            guard Self.browserPrefixes.contains(where: { bid.hasPrefix($0) }) || name.localizedCaseInsensitiveContains("YouTube") else { continue }
            for w in windows(of: app.processIdentifier) {
                if isYTM(AX.str(w, kAXTitleAttribute) ?? "") {
                    setTarget(Target(pid: app.processIdentifier, window: w))
                    read()
                    return
                }
                if tabHit == nil, let tab = Self.findTab(in: w) {
                    tabHit = Target(pid: app.processIdentifier, window: w, tab: tab)
                }
            }
        }
        if let t = tabHit, let title = AX.str(t.tab!, kAXTitleAttribute) {
            setTarget(t)
            readTab(title)
            return
        }
        setTarget(nil)
    }

    /// 브라우저 창의 탭 줄에서 YouTube Music 탭 찾기 (웹 페이지 안쪽은 건너뜀)
    static func findTab(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]; var head = 0
        while head < queue.count && head < 800 {
            let el = queue[head]; head += 1
            let role = AX.str(el, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { continue }
            if AX.str(el, kAXSubroleAttribute) == "AXTabButton" {
                if (AX.str(el, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains("YouTube Music") { return el }
                continue
            }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    /// 간단 모드: 탭 제목 "곡 | YouTube Music - 오디오 재생 - …" 에서 곡과 재생 여부만
    private func readTab(_ title: String) {
        var st = PlayerState()
        st.limited = true
        st.title = Self.songTitle(title)
        st.playing = title.contains("오디오 재생") || title.lowercased().contains("audio playing")
        st.byline = "다른 탭에서 재생 중 · 제목을 누르면 그 탭으로"
        state = st
        onUpdate?(st, nil)
    }

    nonisolated static func songTitle(_ raw: String) -> String {
        guard let r = raw.range(of: "YouTube Music", options: .caseInsensitive) else { return raw }
        var s = String(raw[..<r.lowerBound])
        for sep in [" | ", " - ", " – "] where s.hasSuffix(sep) { s.removeLast(sep.count) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 플레이어 바 읽기 (백그라운드)

    nonisolated static func label(_ el: AXUIElement) -> String {
        let d = AX.str(el, kAXDescriptionAttribute) ?? ""
        return d.isEmpty ? (AX.str(el, kAXTitleAttribute) ?? "") : d
    }

    nonisolated static func rect(_ el: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = AX.attr(el, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = AX.attr(el, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    nonisolated static func number(_ el: AXUIElement, _ name: String) -> Double? {
        (AX.attr(el, name) as? NSNumber)?.doubleValue
    }

    /// 창 전체에서 "플레이어 바" 찾기 (수천 개를 훑으므로 백그라운드에서)
    nonisolated static func findToolbar(pid: pid_t, window: AXUIElement) -> AXUIElement? {
        enableWebAccessibility(AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(window, 0.5)
        var queue = [window]; var head = 0
        while head < queue.count && head < 9000 {
            let el = queue[head]; head += 1
            if AX.str(el, kAXRoleAttribute) == (kAXToolbarRole as String), barNames.contains(label(el)) { return el }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }

    /// 플레이어 바 안을 훑어 상태와 버튼들을 모음 (100개 안팎이라 매초 읽어도 가벼움)
    nonisolated static func readBar(_ bar: AXUIElement) -> (PlayerState, PlayerParts) {
        var st = PlayerState()
        let parts = PlayerParts()
        let barRect = rect(bar)
        var headingRect: CGRect?
        var stack = [bar]
        var n = 0
        func isName(_ l: String, _ key: String) -> Bool { names[key]!.contains(l) }
        while let el = stack.popLast(), n < 600 {
            n += 1
            let role = AX.str(el, kAXRoleAttribute) ?? ""
            let l = label(el)
            switch role {
            case "AXButton":
                if isName(l, "prev") { parts.buttons["prev"] = el }
                else if isName(l, "next") { parts.buttons["next"] = el }
                else if isName(l, "play") { parts.buttons["playPause"] = el; st.playing = false }
                else if isName(l, "pause") { parts.buttons["playPause"] = el; st.playing = true }
                else if isName(l, "shuffle") { parts.buttons["shuffle"] = el }
                else if isName(l, "unmute") { parts.buttons["mute"] = el; st.muted = true }
                else if isName(l, "mute") { parts.buttons["mute"] = el; st.muted = false }
                else if isName(l, "open") { parts.buttons["page"] = el; st.pageOpen = false }
                else if isName(l, "close") { parts.buttons["page"] = el; st.pageOpen = true }
                else if l.contains("반복") || l.lowercased().hasPrefix("repeat") { parts.buttons["repeat"] = el; st.repeatLabel = l }
                continue
            case "AXCheckBox":
                let on = number(el, kAXValueAttribute) == 1
                if l == "좋아요" || l == "Like" { parts.buttons["like"] = el; st.liked = on }
                if l == "싫어요" || l == "Dislike" { parts.buttons["dislike"] = el; st.disliked = on }
                continue
            case "AXSlider":
                if l == "볼륨" || l == "Volume" { parts.volume = el; st.volume = number(el, kAXValueAttribute) ?? 100 }
                continue
            case "AXProgressIndicator":
                parts.progress = el
                st.position = number(el, kAXValueAttribute) ?? 0
                st.duration = number(el, kAXMaxValueAttribute) ?? 0
                continue
            case "AXHeading":
                st.title = AX.str(el, kAXTitleAttribute) ?? ""
                headingRect = rect(el)
                continue
            case "AXStaticText":
                let v = AX.str(el, kAXValueAttribute) ?? ""
                if v.range(of: #"^\d+:\d\d(:\d\d)? / \d+:\d\d(:\d\d)?$"#, options: .regularExpression) != nil { st.time = v }
                continue
            case "AXGroup":
                if st.byline.isEmpty, l.contains(" • ") { st.byline = l; continue }
            default: break
            }
            for c in AX.children(el).reversed() { stack.append(c) }
        }
        // 진행바 최대값이 없으면 "0:21 / 4:55" 에서 계산
        let pieces = st.time.components(separatedBy: " / ")
        if st.duration <= 0, pieces.count == 2 { st.duration = seconds(pieces[1]) }
        if st.position <= 0, pieces.count == 2 { st.position = seconds(pieces[0]) }
        if let h = headingRect, h.width > 0 {
            st.artRect = CGRect(x: h.minX - 56, y: barRect.minY + (barRect.height - 40) / 2, width: 40, height: 40)
        }
        return (st, parts)
    }

    nonisolated static func seconds(_ s: String) -> Double {
        s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private func read() {
        guard let t = target, !busy else { return }
        busy = true
        let pid = t.pid, window = t.window
        let cached = toolbar
        axQueue.async {
            var bar = cached
            if bar == nil || AX.str(bar!, kAXRoleAttribute) == nil { bar = YTMusic.findToolbar(pid: pid, window: window) }
            ytmLog("toolbar found=\(bar != nil)")
            let result = bar.map { YTMusic.readBar($0) }
            if let r = result { ytmLog("read title=\(r.0.title) playing=\(String(describing: r.0.playing)) time=\(r.0.time)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    guard self.target?.pid == pid else { return }
                    self.toolbar = bar
                    guard let (st, parts) = result, !st.title.isEmpty || st.playing != nil else { return }
                    self.parts = parts
                    self.state = st
                    self.onUpdate?(st, self.art)
                    self.refreshArt(st)
                }
            }
        }
    }

    // MARK: 앨범 사진 (곡이 바뀌면 그 자리를 캡처해서 잘라 옴, 화면 기록 권한 필요)

    private func refreshArt(_ st: PlayerState) {
        let key = st.title + "|" + st.byline
        guard key != artKey, let t = target, let r = st.artRect, CGPreflightScreenCaptureAccess() else { return }
        // YouTube Music 탭이 보이고 있을 때만 (다른 탭이면 엉뚱한 곳이 찍힘)
        guard isYTM(AX.str(t.window, kAXTitleAttribute) ?? "") else { return }
        artKey = key
        let winRect = YTMusic.rect(t.window)
        let pid = t.pid
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
                  let w = content.windows.first(where: { $0.owningApplication?.processID == pid
                      && abs($0.frame.minX - winRect.minX) < 4 && abs($0.frame.minY - winRect.minY) < 4
                      && abs($0.frame.width - winRect.width) < 4 }) else { self.artKey = ""; return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            guard let img = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { self.artKey = ""; return }
            let sx = CGFloat(img.width) / w.frame.width, sy = CGFloat(img.height) / w.frame.height
            let crop = CGRect(x: (r.minX - w.frame.minX) * sx, y: (r.minY - w.frame.minY) * sy,
                              width: r.width * sx, height: r.height * sy).integral
            guard let cut = img.cropping(to: crop), key == self.artKey else { return }
            self.art = NSImage(cgImage: cut, size: r.size)
            if let s = self.state { self.onUpdate?(s, self.art) }
        }
    }

    // MARK: 조작

    func press(_ key: String) {
        guard state?.limited != true, let b = parts.buttons[key] else {
            if key == "playPause" { mediaKey(16) } else if key == "next" { mediaKey(17) } else if key == "prev" { mediaKey(18) }
            return
        }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    /// 진행바를 원하는 위치로 (0~1)
    func seek(_ fraction: Double) {
        guard let p = parts.progress, let st = state, st.duration > 0 else { return }
        let sec = max(0, min(st.duration, fraction * st.duration))
        AXUIElementSetAttributeValue(p, kAXValueAttribute as CFString, NSNumber(value: sec))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    func setVolume(_ v: Double) {
        guard let s = parts.volume else { return }
        AXUIElementSetAttributeValue(s, kAXValueAttribute as CFString, NSNumber(value: v.rounded()))
    }

    func showWindow() {
        guard let t = target else { return }
        if let tab = t.tab { AXUIElementPerformAction(tab, kAXPressAction as CFString) }   // 그 탭을 앞으로
        AX.focus(window: t.window, pid: t.pid)
    }

    /// 키보드의 ⏯ ⏭ ⏮ 키를 누른 것과 같은 신호 (페이지 버튼을 못 찾았을 때)
    private func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 재생 목록 ("다음 트랙") — 플레이어 페이지가 열려 있어야 보이므로 필요하면 잠깐 열었다 닫음

    func loadQueue(_ done: @escaping ([QueueItem]) -> Void) {
        guard let t = target else { done([]); return }
        let needOpen = state?.pageOpen == false
        if needOpen, let o = parts.buttons["page"] {
            AXUIElementPerformAction(o, kAXPressAction as CFString)
            openedPageForQueue = true
        }
        let window = t.window
        axQueue.asyncAfter(deadline: .now() + (needOpen ? 1.0 : 0)) {
            let items = YTMusic.readQueue(window: window)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(items) } }
        }
    }

    /// 재생 목록을 닫을 때, 우리가 열었던 플레이어 페이지는 다시 닫아 둠
    func queueClosed() {
        guard openedPageForQueue else { return }
        openedPageForQueue = false
        guard let bar = toolbar else { return }
        axQueue.async {
            let (_, parts) = YTMusic.readBar(bar)
            if let b = parts.buttons["page"], YTMusic.names["close"]!.contains(YTMusic.label(b)) {
                AXUIElementPerformAction(b, kAXPressAction as CFString)
            }
        }
    }

    func play(_ item: QueueItem) {
        AXUIElementPerformAction(item.button, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }

    nonisolated static func readQueue(window: AXUIElement) -> [QueueItem] {
        // "다음 트랙" 탭을 찾고, 그 탭 묶음의 부모 아래에서 곡 줄들을 읽음
        var queue = [window]; var head = 0
        var tab: AXUIElement?
        while head < queue.count && head < 9000 {
            let el = queue[head]; head += 1
            if AX.str(el, kAXRoleAttribute) == (kAXRadioButtonRole as String), upNext.contains(label(el)) { tab = el; break }
            queue.append(contentsOf: AX.children(el))
        }
        // 탭 → 탭 묶음 → 그 부모(패널)
        var panel = tab.flatMap { AX.element($0, kAXParentAttribute) }
        var hops = 0
        while let p = panel, AX.str(p, kAXRoleAttribute) != (kAXTabGroupRole as String), hops < 4 {
            panel = AX.element(p, kAXParentAttribute); hops += 1
        }
        guard let tabGroup = panel, let root = AX.element(tabGroup, kAXParentAttribute) else { return [] }

        var items: [QueueItem] = []
        var stack = [root]
        var n = 0
        while let el = stack.popLast(), n < 6000 {
            n += 1
            if AX.str(el, kAXRoleAttribute) == (kAXButtonRole as String) {
                let l = label(el)
                let playing = l.hasSuffix(" 일시중지") || l.hasSuffix(" 일시정지") || l.hasPrefix("Pause ")
                let isPlay = l.hasSuffix(" 재생") || l.hasPrefix("Play ")
                if (playing || isPlay), let row = rowOf(el) {
                    let texts = staticTexts(row)
                    let dur = texts.last { $0.range(of: #"^\d+:\d\d(:\d\d)?$"#, options: .regularExpression) != nil } ?? ""
                    let rest = texts.filter { $0 != dur }
                    items.append(QueueItem(title: rest.first ?? l, artist: rest.dropFirst().joined(separator: " "),
                                           duration: dur, current: playing, button: el))
                }
                continue
            }
            for c in AX.children(el).reversed() { stack.append(c) }
        }
        return items
    }

    /// 버튼에서 위로 올라가 곡 한 줄(높이 40~90)을 찾음
    nonisolated private static func rowOf(_ el: AXUIElement) -> AXUIElement? {
        var cur = AX.element(el, kAXParentAttribute)
        var steps = 0
        while let c = cur, steps < 8 {
            let r = rect(c)
            if r.height >= 40 && r.height <= 90 && r.width >= 180 { return c }
            cur = AX.element(c, kAXParentAttribute)
            steps += 1
        }
        return nil
    }

    nonisolated private static func staticTexts(_ el: AXUIElement) -> [String] {
        var out: [String] = []
        var stack = [el]
        var n = 0
        while let e = stack.popLast(), n < 200 {
            n += 1
            if AX.str(e, kAXRoleAttribute) == (kAXStaticTextRole as String) {
                let v = (AX.str(e, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && v != "•" && v != "," { out.append(v) }
                continue
            }
            for c in AX.children(e).reversed() { stack.append(c) }
        }
        return out
    }
}
