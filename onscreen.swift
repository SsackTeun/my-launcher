// 창이 모니터 밖(안 보이는 곳)으로 나가지 않게: 끌기를 마치면 · 모니터 구성이 바뀌면
// 가장 가까운 모니터의 보이는 영역(메뉴 막대 · Dock 제외) 안으로 밀어 넣음
import Cocoa

@MainActor
enum OnScreen {
    /// 창 frame 을 한 모니터 안으로. prefer 가 있으면 그 점이 있는 모니터 우선 (끌고 있는 마우스 위치)
    static func clamp(_ f: NSRect, prefer: NSPoint? = nil) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return f }
        let s: NSScreen
        if let p = prefer, let hit = screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
            s = hit
        } else {
            // 가장 많이 겹치는 모니터, 하나도 안 겹치면 가장 가까운 모니터
            func overlap(_ s: NSScreen) -> CGFloat { let r = s.visibleFrame.intersection(f); return r.isNull ? 0 : r.width * r.height }
            func dist(_ s: NSScreen) -> CGFloat { hypot(s.frame.midX - f.midX, s.frame.midY - f.midY) }
            s = screens.max(by: { overlap($0) < overlap($1) }).flatMap { overlap($0) > 0 ? $0 : nil }
                ?? screens.min(by: { dist($0) < dist($1) })!
        }
        let vf = s.visibleFrame
        var r = f
        // 화면보다 크면 크기는 그대로 두고 왼쪽 위를 맞춤
        r.origin.x = r.width >= vf.width ? vf.minX : min(max(r.minX, vf.minX), vf.maxX - r.width)
        r.origin.y = r.height >= vf.height ? vf.maxY - r.height : min(max(r.minY, vf.minY), vf.maxY - r.height)
        return r
    }

    /// 창 하나를 화면 안으로 (이미 안이면 그대로)
    static func fix(_ w: NSWindow, animate: Bool = true) {
        guard w.isVisible, !w.styleMask.contains(.fullScreen), !EdgeDock.shared.ignores(w) else { return }
        let r = clamp(w.frame)
        guard abs(r.minX - w.frame.minX) > 0.5 || abs(r.minY - w.frame.minY) > 0.5 else { return }
        w.setFrame(r, display: true, animate: animate)
    }

    /// 도구함의 보이는 창들 (메뉴 · 말풍선 · 메뉴 막대 아이콘 같은 건 빼고)
    static func fixAll(animate: Bool = true) {
        for w in NSApp.windows where w.isVisible && w.frame.width >= 150 && w.frame.height >= 60
            && w.level.rawValue < NSWindow.Level.statusBar.rawValue
            && !["sushi", "favbar", "edgedock"].contains(w.identifier?.rawValue ?? "")
            && !w.className.contains("Menu") && !w.className.contains("StatusBar") && !w.className.contains("Tool") {
            fix(w, animate: animate)
        }
    }

    private static var monitor: Any?
    /// 마우스를 놓을 때마다 · 모니터 구성이 바뀔 때마다 검사
    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in
            DispatchQueue.main.async { MainActor.assumeIsolated { fixAll() } }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            // 모니터가 빠진 직후엔 화면 정보가 늦게 바뀌기도 해서 조금 뒤에 한 번 더
            MainActor.assumeIsolated { fixAll(animate: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { fixAll(animate: false) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { fixAll(animate: false) } }
    }
}
