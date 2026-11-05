// YouTube Music 미니 컨트롤러: 브라우저에 열려 있는 YouTube Music 창을 찾아 곡 제목을 보여 주고 재생을 조절
// 창 찾기·버튼 누르기는 "손쉬운 사용" 권한으로 함
import Cocoa
@preconcurrency import ApplicationServices

@MainActor
final class YTMusic {
    struct Target {
        let pid: pid_t
        let window: AXUIElement
        let rawTitle: String
    }
    enum Kind: String { case playPause, next, prev }

    private(set) var target: Target?
    private(set) var playing: Bool?
    /// 찾음 ↔ 못 찾음 이 바뀔 때 (줄을 보이거나 숨기려고)
    var onFoundChange: (() -> Void)?
    /// 곡 제목·재생 상태가 바뀔 때
    var onUpdate: ((String, Bool?) -> Void)?

    private var timer: Timer?
    private var buttons: [Kind: AXUIElement] = [:]
    private var buttonsPID: pid_t = 0
    private var lastScan = Date.distantPast
    private var scanning = false
    private var waiting: [() -> Void] = []   // 찾는 중에 누른 버튼은 찾은 뒤에 처리

    static let browserPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "com.brave.Browser",
                                  "company.thebrowser", "org.mozilla.firefox", "com.operasoftware", "com.vivaldi"]

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setTarget(nil)
    }

    // MARK: 찾기

    private func isYTM(_ title: String) -> Bool { title.localizedCaseInsensitiveContains("YouTube Music") }

    private func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // 응답 없는 앱 때문에 멈추지 않게
        return AX.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    func poll() {
        guard AX.trusted else { setTarget(nil); return }

        // 1) 지난번 창이 아직 YouTube Music 이면 그대로 (제목만 새로 읽기)
        if let t = target, NSRunningApplication(processIdentifier: t.pid) != nil,
           let title = AX.str(t.window, kAXTitleAttribute), isYTM(title) {
            setTarget(Target(pid: t.pid, window: t.window, rawTitle: title))
            return
        }
        // 2) 같은 앱의 다른 창
        if let t = target, let w = windows(of: t.pid).first(where: { isYTM(AX.str($0, kAXTitleAttribute) ?? "") }) {
            setTarget(Target(pid: t.pid, window: w, rawTitle: AX.str(w, kAXTitleAttribute) ?? ""))
            return
        }
        // 3) 브라우저·YouTube Music 앱 전체에서 찾기 (못 찾은 상태면 6초에 한 번만)
        if target == nil && Date().timeIntervalSince(lastScan) < 6 { return }
        lastScan = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            guard Self.browserPrefixes.contains(where: { bid.hasPrefix($0) }) || name.localizedCaseInsensitiveContains("YouTube") else { continue }
            if let w = windows(of: app.processIdentifier).first(where: { isYTM(AX.str($0, kAXTitleAttribute) ?? "") }) {
                setTarget(Target(pid: app.processIdentifier, window: w, rawTitle: AX.str(w, kAXTitleAttribute) ?? ""))
                return
            }
        }
        setTarget(nil)
    }

    private func setTarget(_ t: Target?) {
        let wasFound = target != nil
        target = t
        if t == nil { buttons = [:]; playing = nil }
        if wasFound != (t != nil) { onFoundChange?() }
        guard let t else { return }
        if t.pid != buttonsPID { buttons = [:]; buttonsPID = t.pid; scanButtons(then: nil) }
        readPlaying()
        onUpdate?(Self.songTitle(t.rawTitle), playing)
        dumpIfAsked()
    }

    /// "곡 | YouTube Music" → "곡"
    static func songTitle(_ raw: String) -> String {
        var s = raw
        for sep in [" | YouTube Music", " - YouTube Music", " – YouTube Music"] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        s = s.replacingOccurrences(of: "🔊", with: "").trimmingCharacters(in: .whitespaces)
        return (s.isEmpty || s == "YouTube Music") ? "재생 중인 곡 없음" : s
    }

    // MARK: 웹 페이지 안의 플레이어 버튼 찾기

    nonisolated private static let labels: [Kind: [String]] = [
        .playPause: ["재생", "일시중지", "일시정지", "Play", "Pause"],
        .next: ["다음", "Next"],
        .prev: ["이전", "Previous"],
    ]
    private static let pauseLabels = ["일시중지", "일시정지", "Pause"]

    nonisolated private static func label(_ el: AXUIElement) -> String {
        let d = AX.str(el, kAXDescriptionAttribute) ?? ""
        return d.isEmpty ? (AX.str(el, kAXTitleAttribute) ?? "") : d
    }

    nonisolated private static func y(_ el: AXUIElement) -> CGFloat {
        guard let v = AX.attr(el, kAXPositionAttribute) else { return 0 }
        var p = CGPoint.zero
        AXValueGetValue(v as! AXValue, .cgPoint, &p)
        return p.y
    }

    /// 웹 페이지 안을 훑어 재생·다음·이전 버튼을 찾음 (오래 걸릴 수 있어 백그라운드에서)
    nonisolated private static func scan(pid: pid_t, window: AXUIElement) -> [Kind: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // 브라우저가 웹 페이지 내용을 손쉬운 사용 쪽에 열어 주도록 요청
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(window, 0.5)
        var found: [Kind: (AXUIElement, CGFloat)] = [:]
        var queue = [window]
        var head = 0
        while head < queue.count && head < 6000 {
            let el = queue[head]
            head += 1
            if AX.str(el, kAXRoleAttribute) == (kAXButtonRole as String) {
                let l = label(el)
                if !l.isEmpty && l.count <= 14 {
                    for (kind, words) in labels where words.contains(where: { l == $0 || l.hasPrefix($0 + " ") || l.hasPrefix($0 + "(") }) {
                        // 같은 이름 버튼이 여럿이면 화면 맨 아래(플레이어 줄)에 있는 것
                        let yy = y(el)
                        if found[kind] == nil || yy > found[kind]!.1 { found[kind] = (el, yy) }
                    }
                }
                continue
            }
            queue.append(contentsOf: AX.children(el))
        }
        return found.mapValues(\.0)
    }

    private func scanButtons(then done: (() -> Void)?) {
        if let done { waiting.append(done) }
        guard let t = target, !scanning else { return }
        scanning = true
        let pid = t.pid, window = t.window
        DispatchQueue.global(qos: .userInitiated).async {
            let result = YTMusic.scan(pid: pid, window: window)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    if self.target?.pid == pid { self.buttons = result }
                    self.readPlaying()
                    if let t = self.target { self.onUpdate?(YTMusic.songTitle(t.rawTitle), self.playing) }
                    let w = self.waiting
                    self.waiting = []
                    w.forEach { $0() }
                }
            }
        }
    }

    private func validButton(_ kind: Kind) -> AXUIElement? {
        guard let b = buttons[kind], AX.str(b, kAXRoleAttribute) != nil else { return nil }
        return b
    }

    private func readPlaying() {
        guard let b = buttons[.playPause] else { playing = nil; return }
        let l = YTMusic.label(b)
        if l.isEmpty { buttons[.playPause] = nil; playing = nil; return }
        playing = Self.pauseLabels.contains { l.hasPrefix($0) }
    }

    // MARK: 진단 (설정값 dumpYTM 이 켜져 있으면 창 구조를 파일로 저장)

    nonisolated static func dump(pid: pid_t, window: AXUIElement, to path: String) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(window, 0.5)
        var out = ""
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var n = 0
        while let (el, depth) = stack.popLast(), n < 12000 {
            n += 1
            let role = AX.str(el, kAXRoleAttribute) ?? "?"
            let sub = AX.str(el, kAXSubroleAttribute) ?? ""
            let desc = AX.str(el, kAXDescriptionAttribute) ?? ""
            let title = AX.str(el, kAXTitleAttribute) ?? ""
            var value = ""
            if let v = AX.attr(el, kAXValueAttribute) { value = String(String(describing: v).prefix(60)) }
            let yy = y(el)
            var size = CGSize.zero
            if let sv = AX.attr(el, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
            out += String(repeating: " ", count: min(depth, 40)) + "\(role) \(sub) d=\"\(desc)\" t=\"\(title)\" v=\"\(value)\" y=\(Int(yy)) h=\(Int(size.height))\n"
            for c in AX.children(el).reversed() { stack.append((c, depth + 1)) }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func dumpIfAsked() {
        guard UserDefaults.standard.bool(forKey: "dumpYTM"), let t = target else { return }
        UserDefaults.standard.set(false, forKey: "dumpYTM")
        let pid = t.pid, w = t.window
        DispatchQueue.global().async {
            YTMusic.dump(pid: pid, window: w, to: NSHomeDirectory() + "/MyLauncher/ytm-ax-dump.txt")
        }
    }

    // MARK: 조작

    func press(_ kind: Kind) {
        if let b = validButton(kind) {
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
            return
        }
        // 버튼을 다시 찾아보고, 그래도 없으면 키보드 미디어 키로 대신
        scanButtons { [weak self] in
            guard let self else { return }
            if let b = self.validButton(kind) {
                AXUIElementPerformAction(b, kAXPressAction as CFString)
            } else {
                switch kind {
                case .playPause: self.mediaKey(16)
                case .next: self.mediaKey(17)
                case .prev: self.mediaKey(18)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
        }
    }

    func showWindow() {
        guard let t = target else { return }
        AX.focus(window: t.window, pid: t.pid)
    }

    /// 키보드의 ⏯ ⏭ ⏮ 키를 누른 것과 같은 신호
    private func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - 미니 플레이어 줄

@MainActor
final class PlayerBar: NSView {
    private let iconView = NSImageView()
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private var playBtn: ActionButton!
    private var prevBtn: ActionButton!
    private var nextBtn: ActionButton!
    weak var music: YTMusic?

    init(music: YTMusic) {
        self.music = music
        super.init(frame: .zero)

        iconView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "YouTube Music")
        iconView.contentTintColor = .systemRed
        addSubview(iconView)

        titleButton.isBordered = false
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.font = .systemFont(ofSize: 12, weight: .medium)
        titleButton.toolTip = "YouTube Music 창으로 가기"
        titleButton.target = self
        titleButton.action = #selector(openWindow)
        addSubview(titleButton)

        func control(_ symbol: String, _ tip: String, _ kind: YTMusic.Kind) -> ActionButton {
            let b = ActionButton(title: "", symbol: symbol) { [weak self] _ in self?.music?.press(kind) }
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            b.toolTip = tip
            addSubview(b)
            return b
        }
        prevBtn = control("backward.fill", "이전 곡", .prev)
        playBtn = control("playpause.fill", "재생 / 일시정지", .playPause)
        nextBtn = control("forward.fill", "다음 곡", .next)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openWindow() { music?.showWindow() }

    func update(title: String, playing: Bool?) {
        titleButton.title = title
        let sym = playing == true ? "pause.fill" : (playing == false ? "play.fill" : "playpause.fill")
        playBtn.image = NSImage(systemSymbolName: sym, accessibilityDescription: "재생 / 일시정지")
        iconView.contentTintColor = playing == true ? .systemRed : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        let bw: CGFloat = 26
        nextBtn.frame = NSRect(x: bounds.width - 10 - bw, y: (h - 22) / 2, width: bw, height: 22)
        playBtn.frame = NSRect(x: nextBtn.frame.minX - bw, y: nextBtn.frame.minY, width: bw, height: 22)
        prevBtn.frame = NSRect(x: playBtn.frame.minX - bw, y: nextBtn.frame.minY, width: bw, height: 22)
        titleButton.frame = NSRect(x: 34, y: (h - 20) / 2, width: prevBtn.frame.minX - 40, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}
