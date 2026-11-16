// 테마: 도구함 창 · 떼어 낸 플레이어의 바탕색 · 강조색 · 배경 그림 · 스티커
// - 기본: 지금처럼 뒤가 비치는 어두운 반투명
// - 곰: 따뜻한 우유색 바탕 + 갈색 글씨 + 분홍 강조색, 고른 그림을 배경 · 구석 스티커로
// 그림은 ~/Library/Application Support/도구함/theme 에 복사해 두고 씀 (이 맥 안에서만)
import Cocoa

enum Theme {
    enum Kind: String { case standard, bear }

    nonisolated static var kind: Kind {
        get { Kind(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }
    nonisolated static var isBear: Bool { kind == .bear }

    /// 배경 그림 진하기 (0 ~ 1)
    static var backgroundAlpha: Double {
        get { UserDefaults.standard.object(forKey: "themeBgAlpha") as? Double ?? 0.35 }
        set { UserDefaults.standard.set(newValue, forKey: "themeBgAlpha") }
    }
    /// 스티커 크기
    static var stickerSize: Double {
        get { UserDefaults.standard.object(forKey: "themeStickerSize") as? Double ?? 84 }
        set { UserDefaults.standard.set(newValue, forKey: "themeStickerSize") }
    }

    // MARK: 색

    /// 곰 테마 바탕 (우유색)
    static let milk = NSColor(srgbRed: 1.0, green: 0.96, blue: 0.89, alpha: 1)
    /// 곰 테마 글씨 · 강조 (갈색 · 분홍)
    nonisolated static let brown = NSColor(srgbRed: 0.42, green: 0.29, blue: 0.20, alpha: 1)
    nonisolated static let pink = NSColor(srgbRed: 0.86, green: 0.40, blue: 0.47, alpha: 1)

    /// 테마에 맞는 창 모양 (곰은 밝은 모양으로 고정 → 글씨가 짙게)
    static var appearance: NSAppearance? { isBear ? NSAppearance(named: .aqua) : nil }

    // MARK: 그림

    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("도구함/theme", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    enum Slot: String { case background, sticker }

    private static var cache: [Slot: (Date, NSImage)] = [:]

    static func file(_ s: Slot) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == s.rawValue }
    }

    static func image(_ s: Slot) -> NSImage? {
        guard let u = file(s) else { cache[s] = nil; return nil }
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let c = cache[s], c.0 == m { return c.1 }
        guard let img = NSImage(contentsOf: u) else { return nil }
        cache[s] = (m, img)
        return img
    }

    /// 파일을 골라 테마 폴더로 복사
    @MainActor
    static func choose(_ s: Slot, done: @escaping () -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.message = s == .background ? "배경으로 쓸 그림을 골라 주세요" : "구석에 둘 스티커 그림을 골라 주세요 (배경이 투명한 PNG 가 잘 어울려요)"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let src = p.url else { return }
        set(s, from: src)
        done()
    }

    static func set(_ s: Slot, from src: URL) {
        clear(s)
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased()
        try? FileManager.default.copyItem(at: src, to: folder.appendingPathComponent("\(s.rawValue).\(ext)"))
        cache[s] = nil
    }

    static func clear(_ s: Slot) {
        if let u = file(s) { try? FileManager.default.removeItem(at: u) }
        cache[s] = nil
    }

    // MARK: 붙이기

    /// 창 바탕 맨 아래에 테마 판을 깔기 (기본 테마면 떼어 냄)
    @MainActor
    static func attach(to v: NSView, corner: CGFloat, sticker: Bool) {
        let old = v.subviews.first { $0 is ThemeBackdrop } as? ThemeBackdrop
        guard isBear else { old?.removeFromSuperview(); return }
        let b = old ?? ThemeBackdrop()
        b.corner = corner
        b.showSticker = sticker
        b.frame = v.bounds
        b.autoresizingMask = [.width, .height]
        if b.superview !== v || v.subviews.first !== b {
            b.removeFromSuperview()
            v.addSubview(b, positioned: .below, relativeTo: v.subviews.first)
        }
        b.needsDisplay = true
    }
}

/// 테마 판: 우유색 바탕 + 배경 그림(꽉 채움, 흐리게) + 오른쪽 아래 스티커. 마우스는 그대로 통과
final class ThemeBackdrop: NSView {
    var corner: CGFloat = 20
    var showSticker = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ r: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner)
        clip.addClip()
        Theme.milk.withAlphaComponent(0.88).setFill()
        bounds.fill()
        if let img = Theme.image(.background), img.size.width > 0, img.size.height > 0 {
            // 비율 그대로 꽉 채우고 가운데 맞춤
            let k = max(bounds.width / img.size.width, bounds.height / img.size.height)
            let sz = NSSize(width: img.size.width * k, height: img.size.height * k)
            let rect = NSRect(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2, width: sz.width, height: sz.height)
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(Theme.backgroundAlpha))
        }
        if showSticker, let st = Theme.image(.sticker), st.size.width > 0, st.size.height > 0 {
            let side = CGFloat(Theme.stickerSize)
            let k = min(side / st.size.width, side / st.size.height)
            let sz = NSSize(width: st.size.width * k, height: st.size.height * k)
            let y = isFlipped ? bounds.maxY - sz.height - 14 : 14
            st.draw(in: NSRect(x: bounds.maxX - sz.width - 14, y: y, width: sz.width, height: sz.height),
                    from: .zero, operation: .sourceOver, fraction: 0.95)
        }
    }
}
