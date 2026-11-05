// 앱 아이콘에 마우스를 올리면 그 앱의 열린 창들을 썸네일로 보여 주고, 누르면 그 창만 앞으로
import Cocoa
import ScreenCaptureKit
import ApplicationServices

struct WinInfo {
    let id: CGWindowID
    let title: String
    let frame: CGRect        // 화면 왼쪽 위 기준 좌표 (손쉬운 사용 API 와 같은 기준)
    let onScreen: Bool
}

// MARK: - 썸네일 하나

final class ThumbView: NSView {
    static let box = NSSize(width: 220, height: 138)
    static let size = NSSize(width: box.width + 12, height: box.height + 34)

    var onClick: (() -> Void)?
    private let imageView = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }

    init(info: WinInfo, appIcon: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: ThumbView.size))
        toolTip = info.title.isEmpty ? "(제목 없음)" : info.title

        imageView.frame = NSRect(x: 6, y: 28, width: ThumbView.box.width, height: ThumbView.box.height)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = appIcon          // 캡처가 끝나기 전·실패 시엔 앱 아이콘
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        let title = NSTextField(labelWithString: (info.onScreen ? "" : "◦ ") + (info.title.isEmpty ? "(제목 없음)" : info.title))
        title.frame = NSRect(x: 6, y: 6, width: ThumbView.box.width, height: 16)
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingMiddle
        title.alignment = .center
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ img: NSImage) { imageView.image = img }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - 미리보기 패널

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class PreviewController {
    private let panel: PreviewPanel
    private var showTimer: Timer?
    private var watchTimer: Timer?
    private var currentID: String?
    private var anchor: NSRect = .zero
    private var generation = 0
    /// 썸네일에서 창을 못 찾았을 때 대신 할 일 (앱 다시 열기)
    var fallbackLaunch: ((String) -> Void)?

    init() {
        panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
    }

    // 마우스가 아이콘에 올라감 → 잠깐 머무르면 표시
    func hoverBegan(id: String, pid: pid_t, name: String, icon: NSImage, anchor rect: NSRect) {
        if currentID == id && panel.isVisible { anchor = rect; return }
        showTimer?.invalidate()
        let t = Timer(timeInterval: panel.isVisible ? 0.05 : 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(id: id, pid: pid, name: name, icon: icon, anchor: rect) }
        }
        RunLoop.main.add(t, forMode: .common)
        showTimer = t
    }

    func hoverEnded() {
        showTimer?.invalidate()
        showTimer = nil
        // 실제 숨김은 감시 타이머가 판단 (아이콘 → 패널로 마우스를 옮기는 동안 사라지지 않게)
    }

    func hide() {
        showTimer?.invalidate()
        watchTimer?.invalidate()
        watchTimer = nil
        panel.orderOut(nil)
        currentID = nil
        generation += 1
    }

    // MARK: 표시

    private func show(id: String, pid: pid_t, name: String, icon: NSImage, anchor rect: NSRect) {
        generation += 1
        let g = generation
        currentID = id
        anchor = rect
        startWatching()

        guard CGPreflightScreenCaptureAccess() else {
            layoutMessage(name: name, text: "창 미리보기를 보려면 ‘화면 기록’ 권한이 필요해요.",
                          button: ("권한 설정 열기", {
                              CGRequestScreenCaptureAccess()
                              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                          }))
            return
        }

        Task { @MainActor in
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                guard g == generation else { return }
                layoutMessage(name: name, text: "창 목록을 읽지 못했어요: \(error.localizedDescription)", button: nil)
                return
            }
            guard g == generation else { return }
            let wins = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0
                    && $0.frame.width > 80 && $0.frame.height > 60 }
                .sorted { ($0.isOnScreen ? 0 : 1, $0.windowID) < ($1.isOnScreen ? 0 : 1, $1.windowID) }
            if wins.isEmpty {
                layoutMessage(name: name, text: "열린 창이 없어요 · 아이콘을 누르면 새로 열어요", button: nil)
                return
            }
            let infos = wins.map { WinInfo(id: $0.windowID, title: $0.title ?? "", frame: $0.frame, onScreen: $0.isOnScreen) }
            let views = layoutThumbs(id: id, pid: pid, name: name, icon: icon, infos: infos)

            // 썸네일은 하나씩 찍어서 도착하는 대로 채움
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            for (w, v) in zip(wins, views) {
                Task { @MainActor in
                    let cfg = SCStreamConfiguration()
                    let fit = min(ThumbView.box.width / w.frame.width, ThumbView.box.height / w.frame.height)
                    cfg.width = max(1, Int(w.frame.width * fit * scale))
                    cfg.height = max(1, Int(w.frame.height * fit * scale))
                    cfg.showsCursor = false
                    cfg.ignoreShadowsSingleWindow = true
                    guard let cg = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg),
                          g == self.generation else { return }
                    v.setImage(NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                                                  height: CGFloat(cg.height) / scale)))
                }
            }
        }
    }

    private func card(size: NSSize) -> NSVisualEffectView {
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(14)
        return fx
    }

    private func titleLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.sizeToFit()
        return l
    }

    @discardableResult
    private func layoutThumbs(id: String, pid: pid_t, name: String, icon: NSImage, infos: [WinInfo]) -> [ThumbView] {
        let pad: CGFloat = 10, gap: CGFloat = 6, headH: CGFloat = 24
        let screen = screenFor(anchor)
        let perRow = max(1, min(5, Int((screen.width - 40 - pad * 2 + gap) / (ThumbView.size.width + gap))))
        let cols = min(perRow, infos.count)
        let rows = Int(ceil(Double(infos.count) / Double(cols)))
        let w = pad * 2 + CGFloat(cols) * ThumbView.size.width + CGFloat(cols - 1) * gap
        let h = pad * 2 + headH + CGFloat(rows) * ThumbView.size.height + CGFloat(rows - 1) * gap
        let root = card(size: NSSize(width: w, height: h))

        let head = titleLabel("\(name) — 창 \(infos.count)개")
        head.setFrameOrigin(NSPoint(x: pad + 4, y: h - pad - head.frame.height))
        root.addSubview(head)

        var views: [ThumbView] = []
        for (i, info) in infos.enumerated() {
            let v = ThumbView(info: info, appIcon: icon)
            let c = i % cols, r = i / cols
            v.setFrameOrigin(NSPoint(x: pad + CGFloat(c) * (ThumbView.size.width + gap),
                                     y: h - pad - headH - CGFloat(r + 1) * ThumbView.size.height - CGFloat(r) * gap))
            v.onClick = { [weak self] in
                self?.hide()
                if !focus(pid: pid, window: info) { self?.fallbackLaunch?(id) }
            }
            root.addSubview(v)
            views.append(v)
        }
        present(root)
        return views
    }

    private func layoutMessage(name: String, text: String, button: (String, () -> Void)?) {
        let pad: CGFloat = 12
        let head = titleLabel(name)
        let msg = NSTextField(labelWithString: text)
        msg.font = .systemFont(ofSize: 12)
        msg.sizeToFit()
        var btn: ActionButton?
        if let button { btn = ActionButton(title: button.0, symbol: nil) { _ in button.1() } }
        let w = max(head.frame.width, msg.frame.width, btn?.frame.width ?? 0) + pad * 2
        let h = pad * 2 + head.frame.height + 6 + msg.frame.height + (btn.map { $0.frame.height + 8 } ?? 0)
        let root = card(size: NSSize(width: w, height: h))
        var y = h - pad - head.frame.height
        head.setFrameOrigin(NSPoint(x: pad, y: y)); root.addSubview(head)
        y -= 6 + msg.frame.height
        msg.setFrameOrigin(NSPoint(x: pad, y: y)); root.addSubview(msg)
        if let btn {
            y -= 8 + btn.frame.height
            btn.setFrameOrigin(NSPoint(x: pad, y: y)); root.addSubview(btn)
        }
        present(root)
    }

    /// 아이콘 위쪽(자리가 없으면 아래쪽)에, 화면 밖으로 나가지 않게
    private func present(_ root: NSView) {
        let size = root.frame.size
        let vis = screenFor(anchor)
        var x = anchor.midX - size.width / 2
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        var y = anchor.maxY + 6
        if y + size.height > vis.maxY - 4 { y = anchor.minY - size.height - 6 }
        y = max(y, vis.minY + 4)
        panel.contentView = root
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func screenFor(_ r: NSRect) -> NSRect {
        let p = NSPoint(x: r.midX, y: r.midY)
        return (NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 마우스가 아이콘과 패널 둘 다에서 벗어나면 숨김
    private func startWatching() {
        watchTimer?.invalidate()
        var outside = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let m = NSEvent.mouseLocation
                // 아이콘과 패널 사이 틈(아이콘 폭만큼)을 지나가는 동안에도 유지
                let a = self.anchor, f = self.panel.frame
                let gapRect = f.minY >= a.maxY
                    ? NSRect(x: a.minX, y: a.maxY, width: a.width, height: f.minY - a.maxY)
                    : NSRect(x: a.minX, y: f.maxY, width: a.width, height: a.minY - f.maxY)
                let inside = a.insetBy(dx: -4, dy: -4).contains(m)
                    || (self.panel.isVisible && (f.insetBy(dx: -4, dy: -4).contains(m) || gapRect.insetBy(dx: 0, dy: -4).contains(m)))
                outside = inside ? 0 : outside + 1
                if outside >= 3 { self.hide() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }
}

// MARK: - 고른 창 하나만 앞으로 (손쉬운 사용 권한 필요)

/// 성공하면 true. 권한이 없거나 창을 못 찾으면 false (그땐 앱 다시 열기로 대신)
@MainActor
func focus(pid: pid_t, window info: WinInfo) -> Bool {
    guard AXIsProcessTrusted() else {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return false
    }
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement], !windows.isEmpty else { return false }

    func title(_ w: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v)
        return v as? String ?? ""
    }
    func frame(_ w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 6 && abs(a.minY - b.minY) < 6 && abs(a.width - b.width) < 6 && abs(a.height - b.height) < 6
    }

    let target = windows.first { title($0) == info.title && frame($0).map { close($0, info.frame) } == true }
        ?? windows.first { frame($0).map { close($0, info.frame) } == true }
        ?? windows.first { !info.title.isEmpty && title($0) == info.title }
    guard let w = target else { return false }

    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    NSRunningApplication(processIdentifier: pid)?.unhide()
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return true
}
