// 일반 창 PIP: 다른 앱의 창(게임 등)을 실시간으로 받아 와서 항상 위에 뜨는 작은 창에 비춰 줌.
// macOS 화면 기록 권한이 필요하고, 보기 전용 (작은 창에서 클릭해도 원래 앱이 조작되진 않음)
import Cocoa
import ScreenCaptureKit
import CoreMedia

/// 받아 온 화면 한 장씩을 레이어에 붙이는 곳 (화면 받기는 다른 줄에서 일어남)
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    weak var layer: CALayer?
    var onStop: (() -> Void)?
    /// 원래 창 크기가 바뀌면 (점 단위 크기)
    var onSize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let att = atts.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer,
              let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        var size: CGSize?
        if let d = att[.contentRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
           r.width > 0, abs(r.width - lastSize.width) > 1 || abs(r.height - lastSize.height) > 1 {
            lastSize = r.size
            size = r.size
        }
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = surf
            if let size { self?.onSize?(size) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }
}

/// AX 창 → 창 번호 (macOS 에 공개 함수가 없어 시스템 안의 함수를 찾아 씀)
private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let axGetWindow: GetWindowFn? = {
    guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(s, to: GetWindowFn.self)
}()

/// 창 하나를 비추는 작은 창
@MainActor
final class WindowPiPPanel: NSObject {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    private let panel: NSPanel
    private let overlay: MiniOverlay
    private let screen = CALayer()
    private var stream: SCStream?
    private let sink = FrameSink()
    private let config = SCStreamConfiguration()
    var onClosed: (() -> Void)?
    /// 조작 중: 진짜 창을 작은 창 자리로 불러와 앞에 둔 상태 (작은 창은 잠깐 숨김)
    private(set) var playing = false
    private var originalFrame: CGRect?          // 처음 불러오기 전 진짜 창 자리 (작은 창을 닫으면 되돌림)
    private var activateObs: NSObjectProtocol?

    init(window w: SCWindow) {
        windowID = w.windowID
        pid = w.owningApplication?.processID ?? 0
        title = [w.owningApplication?.applicationName, w.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        let ar = w.frame.height > 0 ? w.frame.width / w.frame.height : 16.0 / 9.0
        let width: CGFloat = ar >= 1 ? 420 : 260
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 여러 개 띄우면 조금씩 비켜서
        let off = CGFloat(WindowPiP.shared.count) * 24
        let rect = NSRect(x: vf.maxX - width - 20 - off, y: vf.minY + 20 + off, width: width, height: (width / ar).rounded())
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay = MiniOverlay(frame: NSRect(origin: .zero, size: rect.size))
        super.init()

        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 160, height: 90)
        panel.sharingType = .none              // 이 작은 창이 다른 화면 받기에 다시 찍히지 않게
        let cv = panel.contentView!
        cv.wantsLayer = true
        cv.layer?.cornerRadius = 10
        cv.layer?.masksToBounds = true
        cv.layer?.backgroundColor = NSColor.black.cgColor

        // 받아 온 화면을 붙일 판
        let host = NSView(frame: cv.bounds)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        screen.contentsGravity = .resizeAspect
        screen.frame = host.bounds
        screen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(screen)
        cv.addSubview(host)

        overlay.autoresizingMask = [.width, .height]
        overlay.aspect = ar
        overlay.useWindowMode(closeTip: "닫기 (원래 창은 처음 자리로)", expandTip: "조작하기 — 원래 창을 이 자리로 불러와요")
        overlay.onClose = { [unowned self] in close() }
        overlay.onExpand = { [unowned self] in play() }
        overlay.onDoubleClick = { [unowned self] in play() }
        overlay.onClick = { [unowned self] in play() }
        cv.addSubview(overlay)

        sink.layer = screen
        sink.onStop = { [weak self] in self?.close() }      // 원래 창이 닫히면 같이 닫힘
        sink.onSize = { [weak self] size in self?.sourceResized(size) }

        // 화면 받기 설정: 창 크기 × 화면 배율 (너무 크면 줄임), 초당 30장, 마우스 커서는 빼고
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        setCaptureSize(w.frame.size, scale: scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 4
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let s = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "windowpip.frames"))
        } catch {
            NSLog("windowpip addStreamOutput: \(error)")
        }
        stream = s
        s.startCapture { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                NSLog("windowpip start: \(err)")
                self?.close()
            } }
        }
        panel.title = title
        panel.orderFrontRegardless()
        OnScreen.fix(panel, animate: false)
    }

    private func setCaptureSize(_ size: CGSize, scale: CGFloat) {
        var w = size.width * scale, h = size.height * scale
        let maxW: CGFloat = 1920
        if w > maxW { h = h * maxW / w; w = maxW }
        config.width = max(2, Int(w))
        config.height = max(2, Int(h))
    }

    /// 원래 창 크기가 바뀌면 받기 크기 · 작은 창 비율도 맞춤
    private func sourceResized(_ size: CGSize) {
        guard size.height > 0 else { return }
        let ar = size.width / size.height
        overlay.aspect = ar
        setCaptureSize(size, scale: NSScreen.main?.backingScaleFactor ?? 2)
        stream?.updateConfiguration(config) { _ in }
        var f = panel.frame
        let top = f.maxY
        f.size.height = (f.width / ar).rounded()
        f.origin.y = top - f.height
        panel.setFrame(OnScreen.clamp(f), display: true)
    }

    /// 원래 창이 있는 앱을 앞으로 (그 창이 다른 데스크탑에 있으면 macOS 가 그쪽으로 넘어감)
    func focusSource() {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: 조작하기 — 입력은 진짜 창이 받고, 보기엔 작은 창 그대로

    /// 이 작은 창이 비추는 진짜 창 (손쉬운 사용으로 옮기고 크기를 바꿀 수 있는 것)
    private func axWindow() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let ws = v as? [AXUIElement] else { return nil }
        if let getWin = axGetWindow {
            for w in ws { var id: CGWindowID = 0; if getWin(w, &id) == .success, id == windowID { return w } }
        }
        return ws.count == 1 ? ws.first : nil
    }
    private func axRect(_ w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success, let pv, let sv else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: p, size: sz)
    }
    private func axSet(_ w: AXUIElement, _ r: CGRect, size: Bool = true) {
        var p = r.origin, sz = r.size
        if size, let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        if size, let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }  // 옮긴 뒤 한 번 더 (화면 끝에서 잘렸을 때)
    }
    /// 화면 좌표(왼쪽 아래 기준) ↔ 손쉬운 사용 좌표(주 화면 왼쪽 위 기준)
    private func toAX(_ f: NSRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }
    private func fromAX(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// 진짜 창을 작은 창 자리 · 크기로 불러와 맨 앞에 → 그대로 조작. 다른 앱을 누르면 다시 작은 창
    func play() {
        guard !playing else { return }
        guard AXIsProcessTrusted() else {
            let a = NSAlert()
            a.messageText = "손쉬운 사용 권한이 필요해요"
            a.informativeText = "시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 ‘도구함’을 켜 주세요."
            a.runModal()
            return
        }
        guard let w = axWindow() else { focusSource(); return }      // 창을 못 찾으면 앱만 앞으로
        if originalFrame == nil { originalFrame = axRect(w) }
        // 작은 창 자리로 (게임처럼 크기가 고정된 창이면 왼쪽 위만 맞춤)
        axSet(w, toAX(panel.frame))
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        playing = true
        panel.orderOut(nil)
        // 다른 앱으로 넘어가면 다시 작은 창을 그 자리에
        activateObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.playing, app?.processIdentifier != self.pid else { return }
                self.backToPiP()
            }
        }
    }

    private func backToPiP() {
        playing = false
        if let o = activateObs { NSWorkspace.shared.notificationCenter.removeObserver(o); activateObs = nil }
        // 조작하다 진짜 창을 옮겼으면 작은 창도 그 자리로 (크기는 작은 창 그대로, 왼쪽 위 맞춤)
        if let w = axWindow(), let r = axRect(w) {
            let real = fromAX(r)
            var f = panel.frame
            f.origin = NSPoint(x: real.minX, y: real.maxY - f.height)
            panel.setFrame(OnScreen.clamp(f), display: false)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        if let o = activateObs { NSWorkspace.shared.notificationCenter.removeObserver(o); activateObs = nil }
        // 불러온 적이 있으면 진짜 창을 처음 자리 · 크기로
        if let r = originalFrame, let w = axWindow() { axSet(w, r) }
        originalFrame = nil
        playing = false
        stream?.stopCapture { _ in }
        stream = nil
        panel.orderOut(nil)
        onClosed?()
        onClosed = nil
    }
}

/// 창 PIP 들을 관리 · 창 고르기 메뉴
@MainActor
final class WindowPiP: NSObject {
    static let shared = WindowPiP()
    private var panels: [WindowPiPPanel] = []
    var count: Int { panels.count }

    /// 화면 기록 권한 안내 (실제로 창 목록을 못 읽었을 때만 — 미리 검사하는 함수는
    /// 권한을 켠 직후에도 '없음' 이라고 하는 경우가 있어서 그것만 믿지 않음)
    private func askPermission() {
        CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "화면 기록 권한이 필요해요"
        a.informativeText = "시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 기록에서 ‘도구함’을 켜 주세요.\n이미 켜져 있다면 macOS 가 도구함을 다시 시작해야 적용돼요 — [다시 시작] 을 눌러 주세요."
        a.addButton(withTitle: "다시 시작")
        a.addButton(withTitle: "설정 열기")
        a.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            (NSApp.delegate as? AppDelegate)?.restartSelf()
        case .alertSecondButtonReturn:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    /// 창 고르기 메뉴를 띄움 (view 가 없으면 마우스 위치에). onlyPID 가 있으면 그 앱 창만
    func showPicker(from view: NSView?, onlyPID: pid_t? = nil) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            let wins = content?.windows ?? []
            // 진단: 권한 상태 · 오류를 파일로 (권한을 줬는데 안 될 때 원인 확인용)
            let info = "time=\(Date()) preflight=\(CGPreflightScreenCaptureAccess()) windows=\(wins.count) error=\(error.map { "\($0) / \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "nil") bundle=\(Bundle.main.bundlePath)\n"
            try? info.write(toFile: NSHomeDirectory() + "/MyLauncher/wpip-debug.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                // 권한이 없으면 목록이 비거나 오류 → 그때만 안내
                if error != nil || (content == nil) { self.askPermission(); return }
                self.popMenu(wins, error: error, from: view, onlyPID: onlyPID)
            } }
        }
    }

    private func popMenu(_ all: [SCWindow], error: Error?, from view: NSView?, onlyPID: pid_t?) {
        let me = ProcessInfo.processInfo.processIdentifier
        // 보통 창만: 맨 아래 층(0), 너무 작지 않은 것, 도구함 자신 · 시스템 조각 제외
        let skipApps: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                     "com.apple.notificationcenterui", "com.apple.Spotlight"]
        let wins = all.filter { w in
            guard let app = w.owningApplication, app.processID != me, w.windowLayer == 0,
                  w.frame.width >= 160, w.frame.height >= 100,
                  !skipApps.contains(app.bundleIdentifier) else { return false }
            if let onlyPID, app.processID != onlyPID { return false }
            return true
        }
        .sorted { ($0.owningApplication?.applicationName ?? "", $0.title ?? "") < ($1.owningApplication?.applicationName ?? "", $1.title ?? "") }

        let m = NSMenu()
        let head = NSMenuItem(title: wins.isEmpty ? (error != nil ? "창 목록을 못 읽었어요 (화면 기록 권한 확인)" : "띄울 수 있는 창이 없어요")
                                                  : "작은 창(PIP)으로 띄울 창", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        var lastApp = ""
        for w in wins {
            let appName = w.owningApplication?.applicationName ?? "?"
            if appName != lastApp && !lastApp.isEmpty { m.addItem(.separator()) }
            lastApp = appName
            let t = (w.title ?? "").isEmpty ? appName : "\(appName) — \(w.title!)"
            let it = MenuAction(t.count > 70 ? String(t.prefix(68)) + "…" : t) { [weak self] in self?.open(w) }
            if let pid = w.owningApplication?.processID, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                it.image = icon
            }
            if !w.isOnScreen { it.toolTip = "지금 안 보이는 창 (다른 데스크탑 · 최소화) — 화면이 멈춰 보일 수 있어요" }
            m.addItem(it)
        }
        if !panels.isEmpty {
            m.addItem(.separator())
            m.addItem(MenuAction("띄운 창 PIP 모두 닫기") { [weak self] in self?.closeAll() })
        }
        if let view {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        } else {
            m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func open(_ w: SCWindow) {
        // 이미 띄운 창이면 그 작은 창을 앞으로
        if panels.contains(where: { $0.windowID == w.windowID }) { return }
        let p = WindowPiPPanel(window: w)
        p.onClosed = { [weak self, weak p] in self?.panels.removeAll { $0 === p } }
        panels.append(p)
    }

    func closeAll() { panels.forEach { $0.close() } }
}
