// 도구함 — 내가 만든 앱들을 카테고리별로 모아 각자 따로 실행하는 런처
import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

let defaultApps = ["local.jaeyeong.excelruler", "com.jaeyeong.listcalendartodo"]

struct Category: Codable {
    var name: String
    var ids: [String]
}

// MARK: - 작은 도우미

/// 클로저로 동작하는 버튼
class ActionButton: NSButton {
    private var handler: ((ActionButton) -> Void)?
    convenience init(title: String, symbol: String?, _ action: @escaping (ActionButton) -> Void) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        bezelStyle = .rounded
        handler = action
        target = self
        self.action = #selector(run)
        sizeToFit()
    }
    @objc private func run() { handler?(self) }
}

final class Item: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", _ action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

func headerItem(_ t: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: t) }
    let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

func popUp(_ menu: NSMenu, under view: NSView) {
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
}

// MARK: - 앱 칸 말풍선 (macOS 기본 말풍선 대신)
// 기본 말풍선은 도구함이 앞에 있지 않을 때 '마우스가 나갔다'는 신호를 놓쳐 한동안 남아 있었다.
// 이 말풍선은 마우스가 칸을 벗어나거나, 칸이 사라지거나, 누르거나 스크롤하면 바로 사라진다.

final class HoverTip {
    static let shared = HoverTip()
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private weak var owner: NSView?
    private var showTimer: Timer?
    private var watchTimer: Timer?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let bg = NSVisualEffectView()
        bg.material = .toolTip
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        bg.addSubview(label)
        panel.contentView = bg
    }

    /// 마우스가 칸에 들어왔을 때: 잠깐 머물면 보여 준다
    func schedule(_ text: String?, for view: NSView) {
        hide()
        guard let text, !text.isEmpty else { return }
        owner = view
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.show(text)
        }
    }

    /// view 가 주인일 때만 숨긴다 (nil 이면 무조건)
    func hide(for view: NSView? = nil) {
        if let view, view !== owner { return }
        showTimer?.invalidate(); showTimer = nil
        watchTimer?.invalidate(); watchTimer = nil
        owner = nil
        panel.orderOut(nil)
    }

    private func ownerContainsMouse() -> Bool {
        guard let v = owner, let w = v.window, w.isVisible, !v.isHiddenOrHasHiddenAncestor else { return false }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        return r.contains(NSEvent.mouseLocation)
    }

    private func show(_ text: String) {
        guard ownerContainsMouse() else { return hide() }
        label.stringValue = text
        let maxW: CGFloat = 320
        let size = label.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude))
        let pad = NSSize(width: 8, height: 5)
        label.frame = NSRect(x: pad.width, y: pad.height, width: ceil(size.width), height: ceil(size.height))
        let w = ceil(size.width) + pad.width * 2, h = ceil(size.height) + pad.height * 2
        // 마우스 오른쪽 아래, 화면 밖으로 나가지 않게
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        var o = NSPoint(x: m.x + 10, y: m.y - h - 18)
        if let f = screen?.visibleFrame {
            o.x = min(max(o.x, f.minX + 4), f.maxX - w - 4)
            if o.y < f.minY + 4 { o.y = m.y + 18 }
        }
        panel.setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
        // 보이는 동안 0.15초마다 마우스가 아직 칸 위에 있는지 확인 (나갔다는 신호를 놓쳐도 사라지게)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.ownerContainsMouse() { self.hide() }
        }
    }
}

// MARK: - 앱 하나를 나타내는 칸

final class Tile: NSView {
    /// 앱 이름 글자 크기 배율 (설정에서 바꿈)
    static var fontScale: CGFloat = 1

    static func size(icon: CGFloat) -> NSSize {
        NSSize(width: max(icon + 32, 76 * min(1.2, fontScale)), height: icon + 26 + ceil(16 * fontScale))
    }

    var onClick: (() -> Void)?
    private var hovering = false {
        didSet {
            needsDisplay = true
            quitButton?.isHidden = !hovering
            if quitButton != nil { runDot?.isHidden = hovering }   // ⓧ 가 나오면 초록 점은 가림
        }
    }
    private var runDot: NSView?
    private var quitButton: ActionButton?

    // MARK: 메모리 사용량 표시
    /// 설정: 실행 중인 앱에 메모리 사용량 표시
    static var showMemory = UserDefaults.standard.object(forKey: "showMemory") as? Bool ?? true
    /// 가장 최근에 잰 값 (새로 그린 칸도 바로 숫자가 보이게)
    static var memCache: [pid_t: UInt64] = [:]
    /// 지금 화면에 있는, 메모리를 보여 주는 칸들
    static let memTiles = NSHashTable<Tile>.weakObjects()
    private(set) var memPID: pid_t = 0
    private var memLabel: NSTextField?
    private var iconFrame: NSRect = .zero
    private var memRight: CGFloat = 0
    private var isRow = false

    /// 실행 중인 앱 칸에 메모리 숫자 달기
    func trackMemory(pid: pid_t) {
        guard Tile.showMemory, pid > 0 else { return }
        memPID = pid
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: isRow ? 11 * Tile.fontScale : 9, weight: isRow ? .regular : .medium)
        l.alignment = isRow ? .right : .left
        l.textColor = .secondaryLabelColor
        addSubview(l)
        memLabel = l
        Tile.memTiles.add(self)
        setMemory(Tile.memCache[pid])
    }

    func setMemory(_ bytes: UInt64?) {
        guard let l = memLabel else { return }
        guard let bytes, bytes > 0 else {
            l.isHidden = true
            if !isRow { runDot?.frame = NSRect(x: frame.width / 2 - 3, y: 1, width: 6, height: 6) }
            return
        }
        l.isHidden = false
        l.stringValue = AppMemory.text(bytes)
        l.toolTip = "메모리 \(AppMemory.text(bytes)) (도우미 프로세스 포함, 활동 모니터 '메모리' 기준)"
        if isRow {
            l.frame = NSRect(x: memRight - 56, y: (frame.height - 15) / 2, width: 56, height: 15)
        } else {
            // 이름 아래 초록 점 줄에 "● 110 MB" 로 (이름 · 아이콘과 안 겹치게)
            l.sizeToFit()
            let tw = ceil(l.frame.width), total = 6 + 4 + tw
            let x0 = max(1, (frame.width - total) / 2)
            runDot?.frame = NSRect(x: x0, y: 3, width: 6, height: 6)
            l.frame = NSRect(x: x0 + 10, y: 0, width: tw, height: 12)
        }
    }

    /// 실행 중인 앱 종료 버튼 (마우스를 올렸을 때만 보임). ⌥ 누르고 누르면 강제 종료
    func addQuitButton(_ quit: @escaping (_ force: Bool) -> Void) {
        let b = ActionButton(title: "", symbol: "xmark.circle.fill") { _ in
            quit(NSEvent.modifierFlags.contains(.option))
        }
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        b.toolTip = "종료 · ⌥ 누르고 누르면 강제 종료"
        let rowHeight = Tile.rowHeight(icon: 0)
        if frame.height <= rowHeight + 20 && frame.width > frame.height * 2 {
            // 목록 보기: 줄 오른쪽 끝 (초록 점 자리)
            let c = runDot.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: frame.width - 19, y: frame.height / 2)
            b.frame = NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)
        } else {
            // 격자 보기: 칸 오른쪽 위
            b.frame = NSRect(x: frame.width - 24, y: frame.height - 24, width: 22, height: 22)
        }
        b.isHidden = !hovering
        addSubview(b)
        quitButton = b
    }
    private let editing: Bool

    /// 목록 보기 한 줄 높이
    static func rowHeight(icon: CGFloat) -> CGFloat { max(listIcon(icon), ceil(16 * fontScale)) + 10 }
    static func listIcon(_ icon: CGFloat) -> CGFloat { min(max(icon, 18), 32) }

    init(name: String, icon: NSImage, iconSize: CGFloat, running: Bool, found: Bool,
         editing: Bool, menu m: NSMenu?, onRemove: (() -> Void)?, badge: String? = nil, listWidth: CGFloat? = nil) {
        self.editing = editing
        let s = listWidth.map { NSSize(width: $0, height: Tile.rowHeight(icon: iconSize)) } ?? Tile.size(icon: iconSize)
        super.init(frame: NSRect(origin: .zero, size: s))
        menu = m
        toolTip = found ? (running ? "\(name) — 실행 중 (클릭하면 앞으로)" : "\(name) — 클릭해서 실행")
                        : "\(name) — 앱을 찾을 수 없음"
        if listWidth != nil {
            buildRow(name: name, icon: icon, iconSize: iconSize, running: running, found: found, onRemove: onRemove, badge: badge)
            return
        }

        // 칸 안쪽은 아래에서 위로: 초록 점 → 이름 → 아이콘
        let iv = NSImageView(frame: NSRect(x: (s.width - iconSize) / 2, y: 14 + ceil(16 * Tile.fontScale), width: iconSize, height: iconSize))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        if !found { iv.alphaValue = 0.35 }
        addSubview(iv)
        iconFrame = iv.frame

        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: 2, y: 10, width: s.width - 4, height: ceil(16 * Tile.fontScale))
        label.alignment = .center
        label.font = .systemFont(ofSize: (iconSize < 40 ? 10 : 12) * Tile.fontScale)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if let badge {
            let b = NSTextField(labelWithString: badge)
            b.font = .systemFont(ofSize: 10, weight: .semibold)
            b.textColor = .white
            b.alignment = .center
            b.wantsLayer = true
            b.drawsBackground = false
            b.layer?.backgroundColor = (badge == "업데이트" ? NSColor.systemOrange : NSColor.controlAccentColor).cgColor
            b.layer?.cornerRadius = 7
            b.sizeToFit()
            let bw = b.frame.width + 10
            b.frame = NSRect(x: min(s.width - bw - 2, (s.width + iconSize) / 2 - bw / 2), y: s.height - 18, width: bw, height: 15)
            addSubview(b)
        }
        if running {
            let dot = NSView(frame: NSRect(x: s.width / 2 - 3, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
            runDot = dot
        }

        // 편집 모드: 왼쪽 위에 빨간 ⊖ 버튼
        if editing, let onRemove {
            let b = ActionButton(title: "", symbol: "minus.circle.fill") { _ in onRemove() }
            b.isBordered = false
            b.contentTintColor = .systemRed
            b.symbolConfiguration = .init(pointSize: 18, weight: .bold)
            b.toolTip = "런처에서 빼기"
            b.frame = NSRect(x: iv.frame.minX - 10, y: iv.frame.maxY - 14, width: 24, height: 24)
            addSubview(b)
        }
    }

    /// 목록 보기: [아이콘] 이름 ………… [표시] ● (편집 중이면 맨 오른쪽 ⊖)
    private func buildRow(name: String, icon: NSImage, iconSize: CGFloat, running: Bool, found: Bool,
                          onRemove: (() -> Void)?, badge: String?) {
        let s = frame.size
        let li = Tile.listIcon(iconSize)
        let iv = NSImageView(frame: NSRect(x: 8, y: (s.height - li) / 2, width: li, height: li))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        if !found { iv.alphaValue = 0.35 }
        addSubview(iv)

        var right = s.width - 8
        if editing, let onRemove {
            let b = ActionButton(title: "", symbol: "minus.circle.fill") { _ in onRemove() }
            b.isBordered = false
            b.contentTintColor = .systemRed
            b.symbolConfiguration = .init(pointSize: 15, weight: .bold)
            b.toolTip = "런처에서 빼기"
            b.frame = NSRect(x: right - 22, y: (s.height - 22) / 2, width: 22, height: 22)
            addSubview(b)
            right -= 26
        }
        if running {
            let dot = NSView(frame: NSRect(x: right - 7, y: (s.height - 7) / 2, width: 7, height: 7))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.toolTip = "실행 중"
            addSubview(dot)
            runDot = dot
            right -= 14
            // 메모리 숫자 자리 (trackMemory 가 채움)
            isRow = true
            if Tile.showMemory { memRight = right; right -= 60 }
        }
        if let badge {
            let b = NSTextField(labelWithString: badge)
            b.font = .systemFont(ofSize: 10, weight: .semibold)
            b.textColor = .white
            b.alignment = .center
            b.wantsLayer = true
            b.layer?.backgroundColor = (badge == "업데이트" ? NSColor.systemOrange : NSColor.controlAccentColor).cgColor
            b.layer?.cornerRadius = 7
            b.sizeToFit()
            let bw = b.frame.width + 10
            b.frame = NSRect(x: right - bw, y: (s.height - 15) / 2, width: bw, height: 15)
            addSubview(b)
            right -= bw + 6
        }
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13 * Tile.fontScale)
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        let lx = iv.frame.maxX + 10
        label.frame = NSRect(x: lx, y: (s.height - label.frame.height) / 2, width: max(10, right - lx - 4), height: label.frame.height)
        if !found { label.textColor = .secondaryLabelColor }
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    /// 위젯을 끌어 옮길 때 앱 아이콘 위에서 누르면 창이 아니라 클릭으로 처리
    override var mouseDownCanMoveWindow: Bool { false }

    // 클릭은 실행, 조금 끌면 아이콘을 다른 자리·카테고리로 옮기기
    var appID = ""
    private var downPoint: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        HoverTip.shared.hide()
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = downPoint, !appID.isEmpty else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragged = true
        hovering = false
        let item = NSPasteboardItem()
        item.setString(appID, forType: .launcherApp)
        let di = NSDraggingItem(pasteboardWriter: item)
        di.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [di], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    /// 스크롤로 옮겨 다니는 강조 (마우스를 떼도 남음)
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var onHoverIn: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { hovering = true; onHoverIn?(); HoverTip.shared.schedule(tip, for: self) }
    override func mouseExited(with event: NSEvent) { hovering = false; HoverTip.shared.hide(for: self) }

    /// 말풍선 글: macOS 기본 말풍선 대신 HoverTip 으로 보여 준다
    private var tip: String?
    override var toolTip: String? {
        get { tip }
        set { tip = newValue }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { HoverTip.shared.hide(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func scrollWheel(with event: NSEvent) {
        HoverTip.shared.hide(for: self)
        super.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || focused, !editing else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        if !editing, !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

extension Tile: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

extension NSPasteboard.PasteboardType {
    static let launcherApp = NSPasteboard.PasteboardType("local.jaeyeong.launcher.app")
    static let launcherCategory = NSPasteboard.PasteboardType("local.jaeyeong.launcher.category")
}

/// 카테고리(왼쪽 목록 칸 · 제목 줄)를 끌어서 순서 바꾸기
final class CategoryDragSource: NSObject, NSDraggingSource {
    static let shared = CategoryDragSource()
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    @MainActor
    static func begin(from view: NSView, event: NSEvent, cat: Int) {
        let item = NSPasteboardItem()
        item.setString(String(cat), forType: .launcherCategory)
        let di = NSDraggingItem(pasteboardWriter: item)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        di.setDraggingFrame(view.bounds, contents: img)
        view.beginDraggingSession(with: [di], event: event, source: CategoryDragSource.shared)
    }
}

/// 끌어다 놓을 자리: 어느 카테고리의 몇 번째에 들어갈지 + 화면에 그릴 위치
struct DropTarget {
    var cat: Int
    var index: Int
    var section: NSRect
    var caret: NSRect
}

/// 아이콘 격자. 위에서 아래로 쌓이도록 좌표를 뒤집음.
/// 앱 아이콘을 끌어 다른 자리·카테고리로 옮기거나, Finder에서 .app 을 끌어다 놓으면 추가
final class GridView: NSView {
    override var isFlipped: Bool { true }
    /// 마우스가 움직일 때 위치 (밖으로 나가면 nil) — 호버로 펼친 카테고리를 다시 접을 때 씀
    var onMouseMoved: ((NSPoint?) -> Void)?
    /// 스크롤을 먼저 가져가 볼 곳 (true 를 돌려주면 목록 스크롤은 하지 않음)
    var onScrollFirst: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if let f = onScrollFirst, f(event) { return }
        super.scrollWheel(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouseMoved?(nil) }
    var target: ((NSPoint) -> DropTarget?)?
    var onDropApps: (([URL], DropTarget) -> Void)?
    var onMoveApp: ((String, DropTarget) -> Void)?
    var categoryTarget: ((NSPoint) -> DropTarget?)?
    var onMoveCategory: ((Int, Int) -> Void)?
    private var current: DropTarget? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .launcherApp, .launcherCategory])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func appURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }
    }
    private func movingID(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .launcherApp)
    }
    private func movingCategory(_ info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: .launcherCategory).flatMap { Int($0) }
    }
    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        if movingCategory(info) != nil {
            current = categoryTarget?(convert(info.draggingLocation, from: nil))
            return current == nil ? [] : .move
        }
        let isMove = movingID(info) != nil
        guard isMove || !appURLs(info).isEmpty else { current = nil; return [] }
        current = target?(convert(info.draggingLocation, from: nil))
        return current == nil ? [] : (isMove ? .move : .copy)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { current = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { current = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let from = movingCategory(sender) {
            current = nil
            guard let t = categoryTarget?(convert(sender.draggingLocation, from: nil)) else { return false }
            DispatchQueue.main.async { self.onMoveCategory?(from, t.index) }
            return true
        }
        guard let t = target?(convert(sender.draggingLocation, from: nil)) else { current = nil; return false }
        current = nil
        if let id = movingID(sender) {
            // 화면을 다시 그리는 건 끌기가 완전히 끝난 다음에
            DispatchQueue.main.async { self.onMoveApp?(id, t) }
            return true
        }
        let urls = appURLs(sender)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDropApps?(urls, t) }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let t = current else { return }
        // 들어갈 카테고리 영역은 옅게, 들어갈 자리는 세로 막대로
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        let p = NSBezierPath(roundedRect: t.section, xRadius: 10, yRadius: 10)
        p.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        p.lineWidth = 1.5
        p.stroke()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: t.caret, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// 위젯 모드 창: 제목 막대가 없어도 키 입력(이름 입력 등)을 받을 수 있게
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 둥근 모서리 마스크 (위젯 카드 모양)
func roundedMask(_ r: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

/// 위젯 높이: 0 바탕화면(다른 창 뒤) · 1 일반 창처럼 · 2 항상 위
let widgetLevels: [(String, NSWindow.Level)] = [
    ("바탕화면에 붙이기 (다른 창 뒤)", NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)),
    ("일반 창처럼", .normal),
    ("항상 위에", .floating),
]

/// 빈 곳을 잡고 끌면 창이 움직이는 판 (검색 줄 · 탭 줄 바탕). 위치 고정이면 안 움직임
final class DragArea: NSView {
    var isLocked: () -> Bool = { false }
    var flippedLayout = false
    override var isFlipped: Bool { flippedLayout }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard !isLocked(), let w = window else { return }
        EdgeDock.shared.beginWatch()   // 끄는 동안 붙을 자리 보여 주기
        w.performDrag(with: event)
        OnScreen.fix(w)        // 모니터 밖으로 끌었으면 다시 안으로
    }
}

/// 위젯 맨 위 손잡이: 잡고 끌면 창이 움직이고, 더블클릭하면 화면 위쪽 가운데로
final class DragHandle: NSView {
    var isLocked: () -> Bool = { false }
    var onDoubleClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = hovering ? 44 : 36
        let r = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - 5) / 2, width: w, height: 5)
        NSColor.labelColor.withAlphaComponent(hovering ? (isLocked() ? 0.2 : 0.45) : 0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        toolTip = isLocked() ? "위치 고정됨 — 🔒 를 눌러 풀 수 있어요" : "잡고 끌어서 옮기기"
    }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) {
        (isLocked() ? NSCursor.arrow : NSCursor.openHand).set()
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        // 끌어서 옮기기만 (여러 번 눌러도 다른 동작 없음)
        guard !isLocked(), let w = window else { return }
        NSCursor.closedHand.set()
        EdgeDock.shared.beginWatch()   // 끄는 동안 붙을 자리 보여 주기
        w.performDrag(with: event)
        NSCursor.openHand.set()
        OnScreen.fix(w)
    }
}

/// 아래 손잡이: 위아래로 끌면 앱 목록 높이 조절, 더블클릭하면 자동 높이
final class ResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?      // 처음 누른 곳에서 아래로 움직인 거리
    var onReset: (() -> Void)?
    private var startY: CGFloat?
    private var hovering = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = hovering ? 44 : 36
        let r = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - 5) / 2, width: w, height: 5)
        NSColor.labelColor.withAlphaComponent(hovering ? 0.45 : 0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        toolTip = "위아래로 끌어서 목록 높이 조절 · 더블클릭하면 내용에 맞춤"
    }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        guard let w = window else { return }
        let start = NSEvent.mouseLocation.y
        startY = start
        onBegin?()
        NSCursor.resizeUpDown.push()
        // 손을 뗄 때까지 마우스를 직접 따라감 (끄는 동안 창 크기가 바뀌어도 끊기지 않게)
        w.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { stop.pointee = true; return }
            if ev.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.onDrag?(start - NSEvent.mouseLocation.y)
        }
        NSCursor.pop()
        startY = nil
        OnScreen.fix(w)
    }
}

/// 탭 모드의 카테고리 탭: 글자 + 작은 개수, 고르면 진하게 + 밑줄 (앱을 끌어다 놓으면 그 카테고리로)
/// 휠 · 트랙패드 스크롤을 받아서 넘겨 주는 투명한 판 (카테고리 탭 줄 빈 곳용)
final class ScrollCatcher: NSView {
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) }
}

final class CategoryTab: NSView {
    var onClick: (() -> Void)?
    /// 끌어서 순서 바꿀 카테고리 번호 (도구함 카테고리일 때만)
    var dragCat: Int?
    private var downAt: NSPoint?
    private var dragged = false
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { if let onScroll { onScroll(event) } else { super.scrollWheel(with: event) } }
    private let selected: Bool
    private var hovering = false { didSet { updateColors(); needsDisplay = true } }
    private let label: NSTextField
    private let countLabel: NSTextField
    static let height: CGFloat = 26

    private var vertical = false

    init(title: String, count: Int?, selected: Bool, menu m: NSMenu?, fontScale: CGFloat, sidebarWidth: CGFloat? = nil) {
        self.selected = selected
        label = NSTextField(labelWithString: title)
        countLabel = NSTextField(labelWithString: count.map { "\($0)" } ?? "")
        super.init(frame: .zero)
        menu = m
        let fs = min(fontScale, 1.2)
        label.font = .systemFont(ofSize: 13 * fs, weight: selected ? .semibold : .regular)
        countLabel.font = .systemFont(ofSize: 10 * fs, weight: .medium)
        label.sizeToFit()
        countLabel.sizeToFit()
        let gapW: CGFloat = count == nil ? 0 : 3
        let w = ceil(label.frame.width + gapW + countLabel.frame.width)
        let ty = (CategoryTab.height - label.frame.height) / 2 + 1
        if let sw = sidebarWidth {
            // 세로 사이드바: [▌ 이름 ......... 개수]
            vertical = true
            frame.size = NSSize(width: sw, height: CategoryTab.height)
            countLabel.alignment = .right
            countLabel.setFrameOrigin(NSPoint(x: sw - countLabel.frame.width - 8, y: ty + 1))
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 11, y: ty, width: max(10, countLabel.frame.minX - 15), height: label.frame.height)
        } else {
            frame.size = NSSize(width: w, height: CategoryTab.height)
            label.setFrameOrigin(NSPoint(x: 0, y: ty))
            countLabel.setFrameOrigin(NSPoint(x: label.frame.maxX + gapW, y: ty + 1))
        }
        addSubview(label)
        addSubview(countLabel)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        label.textColor = selected || hovering ? .labelColor : .secondaryLabelColor
        countLabel.textColor = selected ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        if vertical {
            if selected || hovering {
                NSColor.labelColor.withAlphaComponent(selected ? 0.10 : 0.06).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            if selected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return
        }
        guard selected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: bounds.width, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let c = dragCat, let a = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - a.x, p.y - a.y) > 4 else { return }
        dragged = true
        CategoryDragSource.begin(from: self, event: event, cat: c)
    }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 카테고리 제목 줄 (이름 + 구분선). 우클릭하면 카테고리 메뉴
final class HeaderView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }

    init(frame: NSRect, title: String, count: Int, menu m: NSMenu, lineStart: CGFloat, folded: Bool? = nil) {
        super.init(frame: frame)
        menu = m
        var x = lineStart
        // 접을 수 있는 카테고리면 ▸ / ▾ 표시
        if let folded {
            let chev = NSImageView(frame: NSRect(x: x - 2, y: (frame.height - 12) / 2, width: 12, height: 12))
            chev.image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            chev.symbolConfiguration = .init(pointSize: 10, weight: .bold)
            chev.contentTintColor = .secondaryLabelColor
            addSubview(chev)
            x += 14
        }
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 12 * Tile.fontScale)
        l.textColor = .secondaryLabelColor
        l.sizeToFit()
        l.setFrameOrigin(NSPoint(x: x, y: (frame.height - l.frame.height) / 2))
        addSubview(l)
        let c = NSTextField(labelWithString: "\(count)")
        c.font = .systemFont(ofSize: 11)
        c.textColor = .tertiaryLabelColor
        c.sizeToFit()
        c.setFrameOrigin(NSPoint(x: l.frame.maxX + 6, y: (frame.height - c.frame.height) / 2))
        addSubview(c)
        let lineX = c.frame.maxX + 8
        let line = NSBox(frame: NSRect(x: lineX, y: frame.height / 2, width: max(0, frame.width - lineStart - lineX), height: 1))
        line.boxType = .separator
        addSubview(line)
        toolTip = folded == nil ? "우클릭: 이름 바꾸기 · 순서 · 삭제 · 여기에 앱 추가"
                                : "클릭: 접기/펼치기 · 우클릭: 이름 바꾸기 · 순서 · 삭제 · 여기에 앱 추가"
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 끌어서 순서 바꿀 카테고리 번호
    var dragCat: Int?
    private var downAt: NSPoint?
    private var dragged = false
    override var mouseDownCanMoveWindow: Bool { onClick == nil && dragCat == nil }
    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow; dragged = false
        if onClick == nil && dragCat == nil { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let c = dragCat, let a = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - a.x, p.y - a.y) > 4 else { return }
        dragged = true
        CategoryDragSource.begin(from: self, event: event, cat: c)
    }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        if !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - 앱

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let d = UserDefaults.standard
    var cats: [Category] = []
    var cols = 4
    /// 앱 보기 방식: 격자(아이콘) / 목록(세로 한 줄씩)
    var listMode = false
    var rows = 1
    var iconSize: CGFloat = 64
    var editing = false
    var widget = false
    var widgetLevel = 0
    /// 위젯일 때도 Dock 아이콘 · 메뉴 막대에 도구함 표시
    var widgetShowsInDock = true
    var locked = false
    /// 드롭 위치로 카테고리를 찾기 위한 각 카테고리의 세로 범위
    var sectionYs: [(cat: Int, top: CGFloat, tilesTop: CGFloat, bottom: CGFloat)] = []

    var window: NSWindow!
    var statusItem: NSStatusItem!
    var settings: NSPanel?
    var colsField: NSTextField!, rowsField: NSTextField!
    var colsStepper: NSStepper!, rowsStepper: NSStepper!
    var sizeSlider: NSSlider!, sizeLabel: NSTextField!
    var widgetCheck: NSButton!
    var dockCheck: NSButton!
    var hideDock = false
    // 검색 · 위쪽 줄 (창을 다시 그려도 검색칸은 그대로 유지해 입력이 끊기지 않게)
    var query = ""
    var root: NSView?
    lazy var searchField: NSSearchField = {
        let f = NSSearchField(frame: .zero)
        f.placeholderString = "앱 찾기"
        f.delegate = self
        f.sendsSearchStringImmediately = true
        f.focusRingType = .none
        return f
    }()
    lazy var finderButton: ActionButton = {
        // 글자 없이 Finder 아이콘만, 다른 아이콘 버튼들과 같은 크기로
        let b = ActionButton(title: "", symbol: nil) { [unowned self] _ in launch("com.apple.finder") }
        let img = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        img.size = NSSize(width: 18, height: 18)
        b.image = img
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.toolTip = "Finder 열기"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var youtubeButton: ActionButton = {
        // YouTube 영상 창 (PIP 버튼이 있음). 누르면 창, 클립보드에 YouTube 링크가 있으면 바로 그 영상
        let b = ActionButton(title: "", symbol: "play.rectangle.fill") { _ in
            YouTubeWindow.shared.show(YouTubeWindow.shared.isOpen ? nil : YouTubeWindow.clipboardLink())
        }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        b.contentTintColor = .systemRed
        b.toolTip = "YouTube 열기 (영상을 PIP 로 띄울 수 있어요)"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var windowPiPButton: ActionButton = {
        // 일반 창(게임 등)을 작은 창으로 비춰 보기
        let b = ActionButton(title: "", symbol: "rectangle.on.rectangle") { b in WindowPiP.shared.showPicker(from: b) }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "창 PIP: 다른 앱 창(게임 등)을 항상 위 작은 창으로 띄우기"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var netflixButton: ActionButton = {
        // Netflix 영상 창 (YouTube 와 같은 작은 창 PIP)
        let b = ActionButton(title: "N", symbol: nil) { _ in VideoWindow.netflix.show() }
        b.isBordered = false
        b.font = .systemFont(ofSize: 15, weight: .heavy)
        b.contentTintColor = NSColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)
        b.attributedTitle = NSAttributedString(string: "N", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .heavy),
            .foregroundColor: NSColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)])
        b.toolTip = "Netflix 열기 (영상을 작은 창으로 띄울 수 있어요)"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    // 앱 목록 접기 (전체 / 카테고리별)
    var listCollapsed = false
    /// 앱 목록 탭: 0 전체 · 1 실행 중 · 2 개발자 앱
    var tab = 0
    lazy var devApps: DevApps = {
        let a = DevApps()
        a.onChange = { [unowned self] in refresh() }
        return a
    }()
    var foldedCats: Set<String> = []
    /// 카테고리 보기: 모두 펼치기(세로) / 모두 접기(가로 탭)
    var catTabMode = false
    var catTabSel = 0
    var runTabSel = 0
    var devTabSel = 0
    var deskTabSel = 0
    /// 데스크탑 탭: 마지막으로 읽은 데스크탑 목록
    var desks: [Spaces.Desk] = []
    /// 지금 탭에서 왼쪽 세로 목록에 고른 항목 (탭마다 따로 기억)
    var curSel: Int {
        get { tab == 1 ? runTabSel : (tab == 2 ? devTabSel : (tab == 3 ? deskTabSel : catTabSel)) }
        set {
            switch tab {
            case 1: runTabSel = newValue; d.set(newValue, forKey: "runTabSel")
            case 2: devTabSel = newValue; d.set(newValue, forKey: "devTabSel")
            case 3: deskTabSel = newValue; d.set(newValue, forKey: "deskTabSel")
            default: catTabSel = newValue; d.set(newValue, forKey: "catTabSel")
            }
        }
    }
    var sideCount = 0
    /// 지금 화면에 놓인 앱 칸들 (스크롤 포커스 이동용) · 강조된 앱
    var visibleTiles: [(id: String, tile: Tile)] = []
    var focusedID: String?
    private var focusAcc: CGFloat = 0
    /// 끝까지 스크롤하면 다음 카테고리로 넘어가기 (설정)
    var scrollCrossesCategory = true
    var crossCheck: NSButton!
    /// ⓧ 로 끌 때 물어보기 (설정)
    // MARK: 앱별 메모리 (2초마다 다시 잼, 화면에 숫자가 있을 때만)
    var memTimer: Timer?
    private var memBusy = false
    func startMemoryWatch() {
        memTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateMemory() } }
        RunLoop.main.add(t, forMode: .common)
        memTimer = t
        updateMemory()
    }
    func updateMemory() {
        guard Tile.showMemory, !memBusy, window?.isVisible == true else { return }
        let tiles = Tile.memTiles.allObjects
        let pids = Set(tiles.map(\.memPID).filter { $0 > 0 })
        guard !pids.isEmpty else { return }
        memBusy = true
        DispatchQueue.global(qos: .utility).async {
            let m = AppMemory.snapshot(apps: pids)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.memBusy = false
                    Tile.memCache = m
                    Tile.memTiles.allObjects.forEach { $0.setMemory(m[$0.memPID]) }
                }
            }
        }
    }
    var memoryCheck: NSButton!
    @objc func memoryChecked(_ b: NSButton) {
        Tile.showMemory = b.state == .on
        d.set(Tile.showMemory, forKey: "showMemory")
        refresh()
        updateMemory()
    }

    var confirmQuit: Bool = UserDefaults.standard.object(forKey: "confirmQuit") as? Bool ?? true
    var confirmCheck: NSButton!
    /// 도구함 다시 시작: 1초 뒤 다시 켜도록 맡겨 두고 끔
    @objc func restartSelf() {
        let path = Bundle.main.bundlePath
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? sh.run()
        NSApp.terminate(nil)
    }

    /// 앱 다시 시작: 정상 종료 → 완전히 꺼지면 다시 켬 (10초 안에 안 꺼지면 그만둠)
    func restartApp(_ r: NSRunningApplication) {
        guard let url = r.bundleURL else { return }
        r.terminate()
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            tries += 1
            if r.isTerminated {
                t.invalidate()
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            } else if tries > 40 {
                t.invalidate()   // 저장할지 묻는 중이거나 응답 없음
            }
        }
    }

    /// 데스크탑 탭: 앱 창을 다른 데스크탑으로 (제목 막대 잡고 넘기는 방식이라 잠깐 화면이 넘어감)
    func moveToDesk(_ id: String, _ k: Int) {
        guard desks.indices.contains(k), let r = running(id) else { return }
        Spaces.move(pid: r.processIdentifier, to: desks[k], desks: desks) { [weak self] msg in
            if let msg {
                let a = NSAlert(); a.messageText = msg; a.runModal()
            }
            // 창 정보가 늦게 바뀌는 앱도 있어 한 번 더
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self?.refresh() }
        }
    }

    func setConfirmQuit(_ on: Bool) {
        confirmQuit = on
        d.set(on, forKey: "confirmQuit")
        if settings != nil { syncSettings() }
    }
    @objc func confirmChecked(_ b: NSButton) { setConfirmQuit(b.state == .on) }
    enum FocusEdge { case first, last }
    var pendingFocusEdge: FocusEdge?
    var lastTabMode = false

    func setFocus(_ id: String?, reveal: Bool = false) {
        focusedID = id
        for (tid, t) in visibleTiles { t.focused = tid == id }
        if reveal, let t = visibleTiles.first(where: { $0.id == id })?.tile {
            // 강조가 화면 밖이면 목록을 따라 스크롤
            t.scrollToVisible(t.bounds.insetBy(dx: 0, dy: -10))
        }
    }

    /// 앱 영역에서 스크롤: 아래 · 왼쪽으로 쓸면 다음 앱, 위 · 오른쪽이면 이전 앱으로 강조를 옮김
    func focusScroll(_ e: NSEvent) {
        guard !visibleTiles.isEmpty, e.momentumPhase.isEmpty else { return }
        if e.phase == .began { focusAcc = 0 }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let delta = abs(dx) > abs(dy) ? dx : dy
        var steps = 0
        if isWheelNotch(e) {
            // 마우스 휠: 한 칸 굴리면 한 칸 (값이 작게 들어오는 첫 칸도 바로 반응)
            if delta != 0 { steps = delta < 0 ? 1 : -1 }
            focusAcc = 0
        } else {
            // 트랙패드: 손가락 움직인 만큼
            focusAcc += delta
            let unit: CGFloat = 16
            while abs(focusAcc) >= unit { steps += focusAcc < 0 ? 1 : -1; focusAcc += focusAcc < 0 ? unit : -unit }
        }
        guard steps != 0 else { return }
        let cur = visibleTiles.firstIndex { $0.id == focusedID } ?? (steps > 0 ? -1 : visibleTiles.count)
        let want = cur + steps
        // 끝을 넘어서 스크롤하면 다음 · 이전 카테고리로 (설정에서 켜고 끔, 왼쪽 목록 보기일 때)
        if scrollCrossesCategory, lastTabMode, want >= visibleTiles.count || want < 0 {
            let to = curSel + (want < 0 ? -1 : 1)
            if to >= 0 && to < sideCount {
                curSel = to
                pendingFocusEdge = want < 0 ? .last : .first
                focusAcc = 0
                refresh()
                if let t = visibleTiles.first(where: { $0.id == focusedID })?.tile { t.scrollToVisible(t.bounds.insetBy(dx: 0, dy: -10)) }
                return
            }
        }
        let next = min(visibleTiles.count - 1, max(0, want))
        setFocus(visibleTiles[next].id, reveal: true)
    }
    /// 탭 모드에서 카테고리 탭들이 놓인 자리 (끌어다 놓기용)
    var pillRects: [(cat: Int, rect: NSRect)] = []
    private var tabScrollAcc: CGFloat = 0
    private var tabScrollAt = Date.distantPast

    /// 마우스 휠 한 칸인지 (트랙패드 · 매직 마우스는 phase 가 붙어 옴). 휠은 값 크기와 상관없이 한 칸 = 한 칸
    func isWheelNotch(_ e: NSEvent) -> Bool { e.phase.isEmpty && e.momentumPhase.isEmpty }

    /// 카테고리 탭 줄 위에서 스크롤: 아래 · 왼쪽으로 쓸면 다음, 위 · 오른쪽이면 이전
    func tabScroll(_ e: NSEvent) {
        guard e.momentumPhase.isEmpty else { return }          // 관성 스크롤은 무시
        if e.phase == .began { tabScrollAcc = 0 }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let delta = abs(dx) > abs(dy) ? dx : dy
        if isWheelNotch(e) {
            // 마우스 휠: 한 칸에 하나씩 (첫 칸도 바로)
            guard delta != 0, Date().timeIntervalSince(tabScrollAt) > 0.08 else { return }
            tabScrollAcc = delta
        } else {
            tabScrollAcc += delta
            guard abs(tabScrollAcc) >= 28, Date().timeIntervalSince(tabScrollAt) > 0.18 else { return }
        }
        let step = tabScrollAcc < 0 ? 1 : -1
        tabScrollAcc = 0
        tabScrollAt = Date()
        let next = min(sideCount - 1, max(0, curSel + step))
        guard next != curSel else { return }
        curSel = next
        refresh()
    }

    lazy var collapseButton: ActionButton = {
        let b = ActionButton(title: "", symbol: "chevron.up") { [unowned self] _ in
            listCollapsed.toggle()
            d.set(listCollapsed, forKey: "listCollapsed")
            refresh()
        }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    /// 위치 고정 자물쇠 (🔒 고정 · 🔓 풀림)
    lazy var lockButton: ActionButton = {
        let b = ActionButton(title: "", symbol: "lock.open") { [unowned self] _ in toggleLocked() }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    func updateLockButton() {
        lockButton.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)
        lockButton.contentTintColor = locked ? .controlAccentColor : nil
        lockButton.toolTip = locked ? "창 위치 고정됨 — 누르면 풀려요" : "누르면 창 위치를 고정해요"
    }
    lazy var bulkButton: ActionButton = {
        let b = ActionButton(title: "", symbol: "rectangle.stack.badge.minus") { b in popUp(BulkWindows.menu(), under: b) }
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.toolTip = "열린 창 모두 닫기 · 최소화 · 앱 모두 종료"
        b.frame.size = NSSize(width: 24, height: 24)
        return b
    }()
    lazy var topBar: NSView = {
        let v = DragArea(frame: .zero)
        v.isLocked = { [unowned self] in locked }
        v.addSubview(searchField)
        v.addSubview(finderButton)
        v.addSubview(youtubeButton)
        v.addSubview(netflixButton)
        v.addSubview(windowPiPButton)
        v.addSubview(collapseButton)
        v.addSubview(bulkButton)
        v.addSubview(lockButton)
        return v
    }()
    var installed: [(id: String, name: String)]?
    // YouTube Music 미니 플레이어
    var playerEnabled = true
    var playerCheck: NSButton!
    var playerH: CGFloat { PlayerBar.height }
    /// 도구함 글자 크기 배율 (앱 이름 · 카테고리 제목 · 플레이어 곡 정보)
    var uiScale: CGFloat = 1 {
        didSet { Tile.fontScale = uiScale; PlayerBar.fontScale = uiScale }
    }
    var lockCheck: NSButton!
    var uiScaleLabel: NSTextField!
    var lastSong = ""
    lazy var music: YTMusic = {
        let m = YTMusic()
        m.onFoundChange = { [unowned self] in refresh() }
        m.onUpdate = { [unowned self] st, art in
            playerBar.update(st, art: art)
            lyrics.playerUpdated(st)
            if d.bool(forKey: "ytmDebug") {   // 진단용: 읽은 상태를 파일로
                let line = "title=\(st.title) | byline=\(st.byline) | time=\(st.time) | pos=\(st.position)/\(st.duration) | playing=\(String(describing: st.playing)) | like=\(st.liked) | repeat=\(st.repeatLabel) | vol=\(st.volume) | muted=\(st.muted) | page=\(st.pageOpen) | art=\(art != nil) | artURL=\(st.artURL)\n"
                try? line.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-status.txt", atomically: true, encoding: .utf8)
            }
            // 곡이 바뀌면 메뉴바 메뉴의 곡 제목도 새로
            if st.title != lastSong { lastSong = st.title; buildStatusMenu() }
        }
        return m
    }()
    // ⧉ 떼어 낸 창: 플레이어 · 가사 줄
    enum Part { case player, lyrics }
    var playerDetached = UserDefaults.standard.bool(forKey: "playerDetached") || UserDefaults.standard.bool(forKey: "lyricsDetached")
    var lyricsDetached = UserDefaults.standard.bool(forKey: "lyricsDetached") || UserDefaults.standard.bool(forKey: "playerDetached")
    var playerPanel: NSWindow?
    var lyricsPanel: NSWindow?

    /// 플레이어와 가사 줄은 늘 함께 떼어 내고 함께 합침 (어느 쪽 ⧉ 를 눌러도)
    func toggleDetach(_ part: Part) {
        let on = !(playerDetached || lyricsDetached)
        playerDetached = on; lyricsDetached = on
        d.set(on, forKey: "playerDetached"); d.set(on, forKey: "lyricsDetached")
        playerBar.detached = on
        lyrics.model.stripDetached = on
        lyricsPanel?.orderOut(nil)
        refresh()
    }

    /// 떼어 낸 창 하나 (위젯과 같은 카드 모양, 맨 위 손잡이로 옮김, 위치 기억)
    func detachedPanel(_ part: Part) -> NSWindow {
        if let p = part == .player ? playerPanel : lyricsPanel { return p }
        let p = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        let name = part == .player ? "DetachedPlayer" : "DetachedLyrics"
        let first = d.string(forKey: "NSWindow Frame \(name)") == nil
        p.setFrameAutosaveName(name)
        if first, let main = window {
            // 처음엔 도구함 창 옆에
            let off: CGFloat = part == .player ? 0 : 140
            p.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX + 12, y: main.frame.maxY - off))
        }
        if part == .player { playerPanel = p } else { lyricsPanel = p }
        return p
    }

    /// 떼어 낸 창에 그 부분을 넣고 크기 · 높이를 맞춤
    func showDetached(_ part: Part, view: NSView, width: CGFloat, height: CGFloat, below: (NSView, CGFloat)? = nil) {
        let p = detachedPanel(part)
        let handle: CGFloat = 20
        let belowH = below?.1 ?? 0
        let size = NSSize(width: width, height: height + belowH + handle)
        let fx: NSVisualEffectView
        if let cur = p.contentView as? NSVisualEffectView { fx = cur } else {
            fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.maskImage = roundedMask(16)
            p.contentView = fx
        }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: false)
        fx.frame = NSRect(origin: .zero, size: size)
        let grip = fx.subviews.first(where: { $0 is DragHandle }) as? DragHandle ?? {
            let g = DragHandle(frame: .zero)
            g.isLocked = { [unowned self] in locked }
            fx.addSubview(g)
            return g
        }()
        grip.frame = NSRect(x: 0, y: size.height - handle, width: size.width, height: handle)
        if view.superview !== fx { fx.addSubview(view) }
        view.frame = NSRect(x: 0, y: belowH, width: width, height: height)
        view.needsLayout = true
        // 아래에 같이 붙일 것 (플레이어 밑의 가사 줄)
        if let (bv, bh) = below {
            if bv.superview !== fx { fx.addSubview(bv) }
            bv.frame = NSRect(x: 0, y: 0, width: width, height: bh)
        }
        p.level = widget ? widgetLevels[widgetLevel].1 : .floating
        p.collectionBehavior = widget ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone] : []
        p.orderFrontRegardless()
    }

    lazy var lyrics: LyricsController = {
        let c = LyricsController(music: music)
        c.model.onStripToggle = { [unowned self] in refresh() }   // 가사 줄 펼치기/접기 → 창 높이 다시
        c.model.onDetach = { [unowned self] in toggleDetach(.lyrics) }
        c.model.stripDetached = lyricsDetached
        return c
    }()
    lazy var playerBar: PlayerBar = {
        let b = PlayerBar(music: music)
        b.onLyrics = { [unowned self] in lyrics.toggle() }
        b.onDetach = { [unowned self] in toggleDetach(.player) }
        b.detached = playerDetached
        return b
    }()
    var showPlayer: Bool { playerEnabled && music.isActive }
    /// 위쪽 줄 높이 (위젯이면 맨 위 손잡이 자리만큼 더)
    let barRowH: CGFloat = 40
    var handleH: CGFloat { widget ? 20 : 0 }
    var topH: CGFloat { barRowH + handleH }
    /// 사용자가 아래 손잡이로 정한 앱 목록 높이 (nil 이면 내용에 맞춤)
    var userListH: CGFloat? = {
        let v = UserDefaults.standard.double(forKey: "userListH")
        return v > 0 ? CGFloat(v) : nil
    }()
    var lastViewH: CGFloat = 0
    var lastDocH: CGFloat = 0
    private var resizeStartH: CGFloat = 0
    let gripH: CGFloat = 12
    lazy var resizeHandle: ResizeHandle = {
        let r = ResizeHandle(frame: .zero)
        r.onBegin = { [unowned self] in resizeStartH = lastViewH }
        r.onDrag = { [unowned self] dy in
            let v = max(40, min(lastDocH, resizeStartH + dy)).rounded()
            guard abs(v - (userListH ?? lastViewH)) >= 2 else { return }
            userListH = v
            d.set(Double(v), forKey: "userListH")
            refresh()
        }
        r.onReset = { [unowned self] in
            userListH = nil
            d.removeObject(forKey: "userListH")
            refresh()
        }
        return r
    }()
    lazy var dragHandle: DragHandle = {
        let h = DragHandle(frame: .zero)
        h.isLocked = { [unowned self] in locked }
        h.onDoubleClick = { [unowned self] in
            guard !locked, let s = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            window.setFrameTopLeftPoint(NSPoint(x: s.midX - window.frame.width / 2, y: s.maxY - 8))
        }
        return h
    }()

    let pad: CGFloat = 14, gap: CGFloat = 4, barH: CGFloat = 44, headerH: CGFloat = 28, sectionGap: CGFloat = 10

    func applicationDidFinishLaunching(_ n: Notification) {
        YouTubeWindow.shared.onChange = { [unowned self] in buildStatusMenu() }
        VideoWindow.netflix.onChange = { [unowned self] in buildStatusMenu() }
        startMemoryWatch()
        OnScreen.start()
        SushiBelt.shared.open = { [unowned self] id in launch(id) }
        SushiBelt.shared.quit = { [unowned self] id in quit(id) }
        SushiBelt.shared.nowPlaying = { [unowned self] in showPlayer ? music.state?.title : nil }
        SushiBelt.shared.start()
        FavBar.shared.open = { [unowned self] id in launch(id) }
        FavBar.shared.launcherApps = { [unowned self] in allIds }
        FavBar.shared.onChange = { [unowned self] in buildStatusMenu() }
        FavBar.shared.start()
        if let data = d.data(forKey: "categories"), let c = try? JSONDecoder().decode([Category].self, from: data), !c.isEmpty {
            cats = c
        } else {
            // 예전 버전(카테고리 없음)에서 넘어오면 전부 "기본" 카테고리로
            cats = [Category(name: "기본", ids: d.stringArray(forKey: "apps") ?? defaultApps)]
        }
        listMode = d.bool(forKey: "listMode")
        scrollCrossesCategory = d.object(forKey: "scrollCross") as? Bool ?? true
        if d.object(forKey: "cols") != nil {
            cols = max(1, d.integer(forKey: "cols"))
            rows = max(1, d.integer(forKey: "rows"))
            iconSize = CGFloat(d.double(forKey: "iconSize"))
        }
        widget = d.bool(forKey: "widget")
        widgetShowsInDock = d.object(forKey: "widgetShowsInDock") as? Bool ?? true
        widgetLevel = min(d.integer(forKey: "widgetLevel"), widgetLevels.count - 1)
        locked = d.bool(forKey: "locked")
        // 글자 크기: 기본은 '자동'(화면 · 아이콘 크기에 맞춤). 직접 정한 적이 있을 때만 그 값
        uiScaleAuto = d.object(forKey: "uiScaleAuto") as? Bool ?? true
        if !uiScaleAuto, d.object(forKey: "uiScale") != nil { uiScale = CGFloat(d.double(forKey: "uiScale")) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧰"

        // 앱이 켜지거나 꺼지면 초록 점을 바로 갱신
        let nc = NSWorkspace.shared.notificationCenter
        // 진단: 설정값 spaceMoveTest 에 "pid,데스크탑순번" 을 넣으면 그 앱 창을 옮겨 봄
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.d.bool(forKey: "mcDump") { self.d.removeObject(forKey: "mcDump"); Spaces.dumpMissionControl() }
                guard let v = self.d.string(forKey: "spaceMoveTest") else { return }
                self.d.removeObject(forKey: "spaceMoveTest")
                let parts = v.split(separator: ",").compactMap { Int($0) }
                guard parts.count == 2 else { return }
                let ds = Spaces.load()
                guard ds.indices.contains(parts[1]) else { return }
                Spaces.move(pid: pid_t(parts[0]), to: ds[parts[1]], desks: ds) { msg in
                    try? ((msg ?? "ok") + "\n").write(toFile: NSHomeDirectory() + "/MyLauncher/space-test.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // 데스크탑을 옮기면 데스크탑 탭을 새로
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.tab == 3 { self?.refresh() } }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }

        // 창을 다른 모니터로 옮기거나 화면 설정이 바뀌면 글자 크기 자동 다시 맞춤
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? NSWindow) === self.window else { return }
                self.refresh()
            }
        }

        makeWindow()

        if d.object(forKey: "player") != nil { playerEnabled = d.bool(forKey: "player") }
        listCollapsed = d.bool(forKey: "listCollapsed")
        tab = d.integer(forKey: "listTab")
        catTabMode = d.bool(forKey: "catTabMode")
        catTabSel = d.integer(forKey: "catTabSel")
        runTabSel = d.integer(forKey: "runTabSel")
        devTabSel = d.integer(forKey: "devTabSel")
        deskTabSel = d.integer(forKey: "deskTabSel")
        devApps.load()
        foldedCats = Set(d.stringArray(forKey: "foldedCats") ?? [])
        if playerEnabled { music.start(); lyrics.start() }
        hideDock = d.bool(forKey: "hideDock")
        if hideDock {
            applyDockHiding()
        } else {
            restoreDock()   // 지난번에 비정상 종료돼 못 되돌린 경우
        }
        buildStatusMenu()
    }

    // MARK: 창 / 위젯 모드

    /// 모드에 맞는 창을 새로 만든다. 일반 창과 위젯은 각자 마지막 위치를 따로 기억
    func makeWindow() {
        // 모드를 바꿀 때는 새 창을 직전 창의 왼쪽 위 자리에 띄움 (위젯이 엉뚱한 모니터에 뜨지 않게)
        var carryTopLeft: NSPoint?
        if let old = window {
            carryTopLeft = NSPoint(x: old.frame.minX, y: old.frame.maxY)
            old.setFrameAutosaveName("")
            old.orderOut(nil)
        }
        let autosave = "LauncherWindow"
        let firstRun = carryTopLeft == nil && d.string(forKey: "NSWindow Frame \(autosave)") == nil
        let rect = NSRect(x: 0, y: 0, width: 300, height: 150)
        let w: NSWindow
        if widget {
            w = WidgetWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false   // 그림자를 켜면 가장자리에 검은 테두리 선이 생김
            w.isMovableByWindowBackground = !locked
            w.isMovable = !locked
            w.level = widgetLevels[widgetLevel].1
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        } else {
            w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
            w.title = "도구함"
            w.isMovable = !locked      // 위치 고정이면 제목 막대를 끌어도 안 움직임
        }
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(autosave)
        window = w
        topBar.removeFromSuperview()
        resizeHandle.removeFromSuperview()
        root = nil

        // 위젯은 Dock 에 안 보이게, 일반 창은 Dock 에 보이게
        // 위젯이어도 '표시' 옵션이 켜져 있으면 Dock 아이콘 · 메뉴 막대에 도구함이 뜸 (누르면 앞에 있는 앱이 됨)
        NSApp.setActivationPolicy(widget && !widgetShowsInDock ? .accessory : .regular)
        refresh()
        if let p = carryTopLeft {
            w.setFrameTopLeftPoint(p)
        } else if firstRun {
            w.center()
        }
        if widget { w.orderFrontRegardless() } else { showWindow() }
        EdgeDock.shared.present = { [unowned self] w in if widget { w.orderFrontRegardless() } else { showWindow() } }
        EdgeDock.shared.appSize = { [unowned self] in listMode ? Tile.listIcon(iconSize) : iconSize }
        EdgeDock.shared.attach(w)
    }

    func setWidget(_ on: Bool) {
        widget = on
        editing = false
        d.set(widget, forKey: "widget")
        makeWindow()
        if settings != nil { syncSettings() }
    }

    @objc func toggleWidgetAction() { setWidget(!widget) }

    func setWidgetLevel(_ l: Int) {
        widgetLevel = l
        d.set(l, forKey: "widgetLevel")
        window.level = widgetLevels[l].1
        window.orderFrontRegardless()
        buildStatusMenu()
    }

    /// 글자 크기 자동: 창이 있는 화면이 작을수록, 아이콘이 작을수록 글자도 작게
    var uiScaleAuto = true

    func autoUIScale() -> CGFloat {
        let h = (window?.screen ?? NSScreen.main)?.frame.height ?? 1080
        var s: CGFloat = h <= 900 ? 0.8 : (h <= 1000 ? 0.85 : (h <= 1200 ? 0.95 : 1.05))
        if iconSize <= 32 { s -= 0.05 } else if iconSize >= 80 { s += 0.1 }
        return min(1.4, max(0.8, (s * 20).rounded() / 20))
    }

    /// 자동이면 지금 화면에 맞는 값으로 (화면이 바뀌거나 아이콘 크기를 바꿀 때마다)
    func applyAutoScale() {
        guard uiScaleAuto else { return }
        let v = autoUIScale()
        if v != uiScale { uiScale = v; playerBar.needsLayout = true }
    }

    func setUIScaleAuto() {
        uiScaleAuto = true
        d.set(true, forKey: "uiScaleAuto")
        applyAutoScale()
        if settings != nil { syncSettings() }
        refresh()
    }

    func setUIScale(_ v: CGFloat) {
        uiScaleAuto = false
        d.set(false, forKey: "uiScaleAuto")
        uiScale = min(1.4, max(0.8, (v * 10).rounded() / 10))
        d.set(Double(uiScale), forKey: "uiScale")
        if settings != nil { syncSettings() }
        playerBar.needsLayout = true
        refresh()
    }

    @objc func crossChecked(_ b: NSButton) {
        scrollCrossesCategory = b.state == .on
        d.set(scrollCrossesCategory, forKey: "scrollCross")
    }

    @objc func lockChecked(_ b: NSButton) { if (b.state == .on) != locked { toggleLocked() } }

    func toggleLocked() {
        locked.toggle()
        updateLockButton()
        dragHandle.needsDisplay = true
        if settings != nil { syncSettings() }
        d.set(locked, forKey: "locked")
        window.isMovableByWindowBackground = !locked
        window.isMovable = !locked
        buildStatusMenu()
    }

    /// 위젯 관련 메뉴 항목들 (메뉴바 메뉴와 위젯 우클릭 메뉴에서 같이 씀)
    func widgetItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let toggle = Item(widget ? "위젯 모드 끄기 (일반 창으로)" : "위젯 모드로 바꾸기") { [unowned self] in setWidget(!widget) }
        items.append(toggle)
        if widget {
            for (i, l) in widgetLevels.enumerated() {
                let it = Item("    " + l.0) { [unowned self] in setWidgetLevel(i) }
                it.state = i == widgetLevel ? .on : .off
                items.append(it)
            }
        }
        if widget {
            let dock = Item("    Dock · 메뉴 막대에 표시") { [unowned self] in
                widgetShowsInDock.toggle()
                d.set(widgetShowsInDock, forKey: "widgetShowsInDock")
                NSApp.setActivationPolicy(widgetShowsInDock ? .regular : .accessory)
                window.orderFrontRegardless()
                buildStatusMenu()
            }
            dock.state = widgetShowsInDock ? .on : .off
            items.append(dock)
        }
        let lock = Item(widget ? "    위치 고정" : "창 위치 고정") { [unowned self] in toggleLocked() }
        lock.state = locked ? .on : .off
        items.append(lock)
        return items
    }

    /// 위젯 빈 곳을 우클릭했을 때 나오는 메뉴 (위젯엔 아래 버튼 줄이 없으므로)
    /// 열 때마다 새로 만들어서 체크 표시(위젯 높이 · 위치 고정 등)가 늘 지금 상태와 맞게
    func backgroundMenu() -> NSMenu {
        LiveMenu { [unowned self] m in fillBackgroundMenu(m) }
    }

    func fillBackgroundMenu(_ m: NSMenu) {
        if cats.count == 1 {
            m.addItem(Item("앱 추가…") { [unowned self] in addApp(to: 0) })
        } else {
            let add = NSMenuItem(title: "앱 추가", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (c, cat) in cats.enumerated() { sub.addItem(Item(cat.name) { [unowned self] in addApp(to: c) }) }
            add.submenu = sub
            m.addItem(add)
        }
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(Item(editing ? "빼기 끝내기" : "앱 빼기 (편집)") { [unowned self] in editing.toggle(); refresh() })
        let cat = NSMenuItem(title: "카테고리", action: nil, keyEquivalent: "")
        cat.submenu = categoriesMenu()
        m.addItem(cat)
        m.addItem(Item("설정…") { [unowned self] in openSettings() })
        let bulk = NSMenuItem(title: "창 정리", action: nil, keyEquivalent: "")
        bulk.submenu = BulkWindows.menu()
        m.addItem(bulk)
        m.addItem(.separator())
        widgetItems().forEach(m.addItem)
        m.addItem(.separator())
        m.addItem(Item("도구함 다시 시작") { [unowned self] in restartSelf() })
    }

    func categoriesMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(Item("새 카테고리…") { [unowned self] in newCategory() })
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(.separator())
        for (c, cat) in cats.enumerated() {
            let i = NSMenuItem(title: cat.name, action: nil, keyEquivalent: "")
            i.submenu = categoryMenu(c)
            m.addItem(i)
        }
        return m
    }

    // MARK: Dock 가리기 (도구함이 켜져 있는 동안만 Dock 자동 가리기)

    /// 시스템 Dock 의 "자동으로 가리기" 를 읽고/바꿈. 처음 한 번 macOS 가 System Events 제어 허용을 물어봄
    @discardableResult
    func dockAutohide(set value: Bool? = nil) -> Bool? {
        let src = value.map { "tell application \"System Events\" to set autohide of dock preferences to \($0)" }
            ?? "tell application \"System Events\" to get autohide of dock preferences"
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { return nil }
        return value ?? r?.booleanValue
    }

    func applyDockHiding() {
        guard hideDock else { return }
        // 원래 설정을 한 번만 기억해 두고(앱이 비정상 종료돼도 다음에 되돌릴 수 있게) 자동 가리기 켜기
        if d.object(forKey: "dockWasAutohide") == nil {
            guard let was = dockAutohide() else { dockPermissionFailed(); return }
            d.set(was, forKey: "dockWasAutohide")
        }
        if dockAutohide(set: true) == nil { dockPermissionFailed() }
    }

    func restoreDock() {
        guard d.object(forKey: "dockWasAutohide") != nil else { return }
        let was = d.bool(forKey: "dockWasAutohide")
        if !was { dockAutohide(set: false) }
        d.removeObject(forKey: "dockWasAutohide")
    }

    func dockPermissionFailed() {
        hideDock = false
        d.set(false, forKey: "hideDock")
        d.removeObject(forKey: "dockWasAutohide")
        if settings != nil { syncSettings() }
        buildStatusMenu()
        alert("Dock 을 가리지 못했어요.\n시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 ‘도구함’이 ‘System Events’를 제어하도록 허용한 뒤 다시 켜 주세요.")
    }

    func setHideDock(_ on: Bool) {
        hideDock = on
        d.set(on, forKey: "hideDock")
        if on { applyDockHiding() } else { restoreDock() }
        if settings != nil { syncSettings() }
        buildStatusMenu()
    }

    @objc func dockChecked(_ b: NSButton) { setHideDock(b.state == .on) }

    func setPlayer(_ on: Bool) {
        playerEnabled = on
        d.set(on, forKey: "player")
        if on {
            music.showWindow()     // 처음 켜면 YouTube Music 창을 열어 로그인할 수 있게
            lyrics.start()
        } else {
            music.stop()
            lyrics.stop()
        }
        refresh()
        if settings != nil { syncSettings() }
    }

    @objc func playerChecked(_ b: NSButton) { setPlayer(b.state == .on) }

    func applicationWillTerminate(_ notification: Notification) {
        if hideDock { restoreDock() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        EdgeDock.shared.windowShown()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 앱 정보

    var allIds: [String] { cats.flatMap(\.ids) }
    func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
    func name(_ id: String) -> String {
        guard let u = url(id) else { return devApps.app(id)?.name ?? id }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    func icon(_ id: String) -> NSImage {
        if let u = url(id) { return NSWorkspace.shared.icon(forFile: u.path) }
        if devApps.app(id) != nil { return NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil) ?? NSImage() }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
    }
    func locate(_ id: String) -> (Int, Int)? {
        for (c, cat) in cats.enumerated() {
            if let i = cat.ids.firstIndex(of: id) { return (c, i) }
        }
        return nil
    }

    // MARK: 앱 동작

    /// Dock 아이콘 클릭과 같은 동작: 꺼져 있으면 실행, 켜져 있으면 "다시 열기" 신호를 보내
    /// 닫았거나 최소화·가린 창을 다시 보여 주고 앞으로 가져옴
    func launch(_ id: String) {
        let r = running(id)
        r?.unhide()
        guard let u = url(id) ?? r?.bundleURL else {
            alert("\(id) 앱을 찾을 수 없어요. 앱을 다시 설치하거나 런처에서 빼 주세요.")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: u, configuration: cfg) { [weak self] _, err in
            if let err { DispatchQueue.main.async { self?.alert("실행하지 못했어요: \(err.localizedDescription)") } }
        }
    }

    func quit(_ id: String) { running(id)?.terminate() }

    func remove(_ id: String) {
        guard let (c, i) = locate(id) else { return }
        cats[c].ids.remove(at: i)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let (c, i) = locate(id) else { return }
        let j = i + delta
        guard cats[c].ids.indices.contains(j) else { return }
        cats[c].ids.swapAt(i, j)
        save()
    }

    func moveApp(_ id: String, toCategory target: Int) {
        guard let (c, _) = locate(id), c != target else { return }
        moveApp(id, toCategory: target, at: cats[target].ids.count)
    }

    /// 끌어다 놓기: target 카테고리의 index 자리에 넣기 (같은 카테고리면 순서만 바뀜)
    func moveApp(_ id: String, toCategory target: Int, at index: Int) {
        guard let (c, i) = locate(id) else { return }
        var dest = index
        if c == target {
            if dest == i || dest == i + 1 { return }   // 제자리
            if i < dest { dest -= 1 }
        }
        cats[c].ids.remove(at: i)
        cats[target].ids.insert(id, at: min(max(0, dest), cats[target].ids.count))
        save()
    }

    /// 마우스 위치 → 어느 카테고리의 몇 번째 자리인지
    func dropTarget(at p: NSPoint, left: CGFloat, gridW: CGFloat, tile: NSSize, cols: Int) -> DropTarget? {
        if let pill = pillRects.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) {
            return DropTarget(cat: pill.cat, index: cats[pill.cat].ids.count, section: pill.rect.insetBy(dx: -3, dy: -3),
                              caret: NSRect(x: pill.rect.maxX + 2, y: pill.rect.minY, width: 3, height: pill.rect.height))
        }
        guard !sectionYs.isEmpty else { return nil }
        let sec = sectionYs.first { p.y < $0.bottom + sectionGap / 2 } ?? sectionYs.last!
        let count = cats[sec.cat].ids.count
        let stepX = tile.width + gap, stepY = tile.height + gap
        let section = NSRect(x: left - 8, y: sec.top - 2, width: gridW - pad * 2 + 16, height: sec.bottom - sec.top + 6)
        if cols == 1 {
            // 목록 보기: 줄과 줄 사이에 가로선
            let index = min(count, max(0, Int(((p.y - sec.tilesTop) / stepY).rounded())))
            let caret = NSRect(x: left + 4, y: sec.tilesTop + CGFloat(index) * stepY - gap / 2 - 1.5, width: tile.width - 8, height: 3)
            return DropTarget(cat: sec.cat, index: index, section: section, caret: caret)
        }
        let row = max(0, Int((p.y - sec.tilesTop) / stepY))
        let col = min(cols, max(0, Int(((p.x - left) / stepX).rounded())))
        let index = min(count, row * cols + col)
        // 막대 위치: 줄 오른쪽 끝에 놓을 땐 다음 줄 맨 앞 대신 그 줄 끝에 그림
        let atRowEnd = index > 0 && index % cols == 0 && (col == cols || index == count)
        let r = atRowEnd ? (index - 1) / cols : index / cols
        let cIn = atRowEnd ? cols : index % cols
        let caretX = left + CGFloat(cIn) * stepX - gap / 2 - 1.5
        let caret = NSRect(x: caretX, y: sec.tilesTop + CGFloat(r) * stepY + 4, width: 3, height: tile.height - 8)
        return DropTarget(cat: sec.cat, index: index, section: section, caret: caret)
    }

    func add(_ urls: [URL], to c: Int) {
        var skipped: [String] = []
        for u in urls {
            guard let id = Bundle(url: u)?.bundleIdentifier else { skipped.append(u.lastPathComponent); continue }
            if locate(id) == nil { cats[c].ids.append(id) }
        }
        save()
        if !skipped.isEmpty { alert("앱 정보를 읽지 못해 추가하지 못했어요: \(skipped.joined(separator: ", "))") }
    }

    func addApp(to c: Int) {
        let p = NSOpenPanel()
        p.title = "‘\(cats[c].name)’에 넣을 앱 고르기"
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        add(p.urls, to: c)
    }

    // MARK: 검색

    /// /Applications 등에 설치된 앱 목록 (처음 검색할 때 한 번 읽음)
    func installedApps() -> [(id: String, name: String)] {
        if let installed { return installed }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var list: [(String, String)] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = dir + "/" + item
                guard let id = Bundle(path: path)?.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                list.append((id, fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")))
            }
        }
        list.sort { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        installed = list
        return list
    }

    func matches(_ id: String, _ q: String) -> Bool {
        name(id).localizedCaseInsensitiveContains(q) || id.localizedCaseInsensitiveContains(q)
    }

    /// 화면에 보여 줄 묶음들. 검색 중이면 "도구함에서" + "설치된 앱"
    /// 실행 중인 일반 앱 (도구함 자신은 빼고)
    func runningIDs() -> [String] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { a in
            guard a.activationPolicy == .regular, a.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = a.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    func displaySections() -> [(title: String, cat: Int?, ids: [String])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty && tab == 3 {
            // 데스크탑 탭: 데스크탑마다 창이 열려 있는 앱
            guard Spaces.available else { return [("데스크탑 정보를 읽을 수 없어요", nil, [])] }
            desks = Spaces.load()
            let me = ProcessInfo.processInfo.processIdentifier
            return desks.map { dk in
                var seen = Set<String>()
                let ids = dk.pids.compactMap { pid -> String? in
                    guard pid != me, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
                    return id
                }
                return (dk.label, nil, ids)
            }
        }
        if q.isEmpty && tab == 2 {
            return [("GitHub 앱", nil, devApps.ids)]
        }
        if q.isEmpty && tab == 1 {
            // 실행 중 탭: 도구함 앱 중 켜진 것 + 그 밖에 켜진 앱
            let run = runningIDs()
            let mine = allIds.filter { run.contains($0) }
            let others = run.filter { locate($0) == nil }
            return [("도구함 앱", nil, mine), ("다른 앱", nil, others)]
        }
        if q.isEmpty { return cats.enumerated().map { ($0.element.name, $0.offset, $0.element.ids) } }
        let mine = allIds.filter { matches($0, q) }
        let others = installedApps().filter { locate($0.id) == nil && ($0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)) }
            .prefix(40).map(\.id)
        var out: [(String, Int?, [String])] = [("도구함에서", nil, mine)]
        if !others.isEmpty { out.append(("설치된 앱", nil, Array(others))) }
        return out
    }

    /// 도구함에 없는 실행 중 앱: Dock 처럼 [창 · 앱 메뉴] + 도구함에 넣기 + 가리기 · 종료
    func otherRunningMenu(_ id: String) -> NSMenu {
        LiveMenu { [unowned self] m in
            guard let r = running(id) else { return }
            fillAppMenu(m, pid: r.processIdentifier)
            m.addItem(Item("이 앱 창을 PIP로 띄우기…") { WindowPiP.shared.showPicker(from: nil, onlyPID: r.processIdentifier) })
            let addTo = NSMenuItem(title: "도구함에 넣기", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (c, cat) in cats.enumerated() {
                sub.addItem(Item(cat.name) { [unowned self] in if let u = url(id) { add([u], to: c) } })
            }
            addTo.submenu = sub
            m.addItem(addTo)
            m.addItem(Item(FavBar.shared.contains(id) ? "자주 쓰는 앱 막대에서 빼기" : "자주 쓰는 앱 막대에 넣기") { FavBar.shared.toggle(id) })
            if let u = url(id) { m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) }) }
            m.addItem(.separator())
            m.addItem(Item(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
            m.addItem(Item("다시 시작") { [unowned self] in restartApp(r) })
            m.addItem(Item("종료") { r.terminate() })
        }
    }

    func installedTileMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.addItem(Item("실행") { [unowned self] in launch(id) })
        let addTo = NSMenuItem(title: "도구함에 넣기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (c, cat) in cats.enumerated() {
            sub.addItem(Item(cat.name) { [unowned self] in
                if let u = url(id) { add([u], to: c) }
            })
        }
        addTo.submenu = sub
        m.addItem(addTo)
        m.addItem(Item(FavBar.shared.contains(id) ? "자주 쓰는 앱 막대에서 빼기" : "자주 쓰는 앱 막대에 넣기") { FavBar.shared.toggle(id) })
        if let u = url(id) {
            m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        return m
    }

    // MARK: Dock 앱 가져오기

    /// Dock 에 고정된 앱들의 번들 ID (Dock 순서 그대로)
    func dockAppIDs() -> [String] {
        guard let items = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
                as? [[String: Any]] else { return [] }
        var result: [String] = []
        for item in items {
            guard let tile = item["tile-data"] as? [String: Any] else { continue }
            var id = tile["bundle-identifier"] as? String
            if id == nil, let file = tile["file-data"] as? [String: Any],
               let str = file["_CFURLString"] as? String, let u = URL(string: str) {
                id = Bundle(url: u)?.bundleIdentifier
            }
            if let id, !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// Dock 앱들을 "Dock" 카테고리에 넣기. 이미 런처에 있는 앱은 건너뜀 (여러 번 눌러도 새로 생긴 것만 추가)
    func importDock() {
        let dock = dockAppIDs()
        guard !dock.isEmpty else { alert("Dock 앱 목록을 읽지 못했어요."); return }
        let c: Int
        if let i = cats.firstIndex(where: { $0.name == "Dock" }) {
            c = i
        } else {
            cats.append(Category(name: "Dock", ids: []))
            c = cats.count - 1
        }
        var added = 0, skipped = 0
        for id in dock {
            if locate(id) != nil { skipped += 1 } else { cats[c].ids.append(id); added += 1 }
        }
        if cats[c].ids.isEmpty && added == 0 { cats.remove(at: c) }
        save()
        alert("Dock 앱 \(added)개를 ‘Dock’ 카테고리에 넣었어요." + (skipped > 0 ? "\n이미 런처에 있던 \(skipped)개는 건너뛰었어요." : ""))
    }

    // MARK: 카테고리 동작

    func newCategory(thenMove id: String? = nil) {
        guard let n = ask("새 카테고리 이름", value: "") else { return }
        cats.append(Category(name: n, ids: []))
        if let id { moveApp(id, toCategory: cats.count - 1) } else { save() }
    }

    func renameCategory(_ c: Int) {
        guard let n = ask("카테고리 이름 바꾸기", value: cats[c].name) else { return }
        if foldedCats.remove(cats[c].name) != nil {   // 접어 둔 상태는 새 이름으로 옮김
            foldedCats.insert(n)
            d.set(Array(foldedCats), forKey: "foldedCats")
        }
        cats[c].name = n
        save()
    }

    /// 끌어다 놓기: from 카테고리를 to 자리(0…개수) 앞으로
    func moveCategory(from: Int, to: Int) {
        guard cats.indices.contains(from) else { return }
        var dest = to
        if dest == from || dest == from + 1 { return }
        if dest > from { dest -= 1 }
        let selName = cats.indices.contains(catTabSel) ? cats[catTabSel].name : nil
        let c = cats.remove(at: from)
        cats.insert(c, at: min(max(0, dest), cats.count))
        if let selName, let i = cats.firstIndex(where: { $0.name == selName }) { catTabSel = i; d.set(i, forKey: "catTabSel") }
        save()
    }

    /// 카테고리를 끌 때 놓일 자리: 왼쪽 목록이면 칸 사이, 펼친 목록이면 제목 줄 사이 가로선
    func categoryDropTarget(at p: NSPoint, left: CGFloat, width: CGFloat) -> DropTarget? {
        let rows: [(cat: Int, rect: NSRect)] = !pillRects.isEmpty
            ? pillRects
            : sectionYs.map { ($0.cat, NSRect(x: left, y: $0.top, width: width, height: $0.bottom - $0.top)) }
        guard !rows.isEmpty else { return nil }
        let k = rows.firstIndex { p.y < $0.rect.midY } ?? rows.count
        let index = k < rows.count ? rows[k].cat : cats.count
        let y = k < rows.count ? rows[k].rect.minY - 2 : rows[rows.count - 1].rect.maxY + 1
        let r = rows[min(k, rows.count - 1)].rect
        return DropTarget(cat: index, index: index, section: .zero,
                          caret: NSRect(x: r.minX + 4, y: y - 1, width: r.width - 8, height: 3))
    }

    func moveCategory(_ c: Int, by delta: Int) {
        let j = c + delta
        guard cats.indices.contains(j) else { return }
        cats.swapAt(c, j)
        save()
    }

    func deleteCategory(_ c: Int) {
        guard cats.count > 1 else { alert("카테고리는 최소 하나는 있어야 해요."); return }
        let dest = c == 0 ? 1 : c - 1
        if !cats[c].ids.isEmpty {
            let a = NSAlert()
            a.messageText = "‘\(cats[c].name)’ 카테고리를 삭제할까요?"
            a.informativeText = "안에 있는 앱 \(cats[c].ids.count)개는 ‘\(cats[dest].name)’로 옮겨져요. 앱 자체는 지워지지 않아요."
            a.addButton(withTitle: "삭제")
            a.addButton(withTitle: "취소")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        cats[dest].ids.append(contentsOf: cats[c].ids)
        cats.remove(at: c)
        save()
    }

    func categoryMenu(_ c: Int) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(Item("여기에 앱 추가…") { [unowned self] in addApp(to: c) })
        m.addItem(Item("이름 바꾸기…") { [unowned self] in renameCategory(c) })
        m.addItem(.separator())
        let up = Item("위로 옮기기") { [unowned self] in moveCategory(c, by: -1) }
        up.isEnabled = c > 0
        m.addItem(up)
        let down = Item("아래로 옮기기") { [unowned self] in moveCategory(c, by: 1) }
        down.isEnabled = c < cats.count - 1
        m.addItem(down)
        m.addItem(.separator())
        let del = Item("카테고리 삭제…") { [unowned self] in deleteCategory(c) }
        del.isEnabled = cats.count > 1
        m.addItem(del)
        return m
    }

    // MARK: 저장 · 알림

    func save() {
        if let data = try? JSONEncoder().encode(cats) { d.set(data, forKey: "categories") }
        d.set(cols, forKey: "cols")
        d.set(rows, forKey: "rows")
        d.set(Double(iconSize), forKey: "iconSize")
        refresh()
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = msg
        a.runModal()
    }

    func ask(_ title: String, value: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = value
        f.placeholderString = "예: 업무, 개인, 개발"
        a.accessoryView = f
        a.addButton(withTitle: "확인")
        a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let t = f.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: 로그인 시 자동 실행

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            alert("로그인 항목을 바꾸지 못했어요: \(error.localizedDescription)\n시스템 설정 → 일반 → 로그인 항목에서 직접 추가할 수 있어요.")
        }
        refresh()
    }

    // MARK: 메인 창 그리기

    /// 앱 아이콘 우클릭: Dock 처럼 [열린 창들 · 새 창 · 앱 메뉴] + [도구함 정리] + [가리기 · 종료]
    func tileMenu(_ id: String) -> NSMenu {
        LiveMenu { [unowned self] m in
            let r = running(id)
            if let r { fillAppMenu(m, pid: r.processIdentifier) }
            else { m.addItem(Item("열기") { [unowned self] in launch(id) }); m.addItem(.separator()) }

            let tools = NSMenuItem(title: "도구함", action: nil, keyEquivalent: "")
            tools.submenu = launcherMenu(id)
            m.addItem(tools)
            m.addItem(Item(FavBar.shared.contains(id) ? "자주 쓰는 앱 막대에서 빼기" : "자주 쓰는 앱 막대에 넣기") { FavBar.shared.toggle(id) })
            if let u = url(id) {
                m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
            }
            if let r {
                m.addItem(.separator())
                m.addItem(Item("이 앱 창을 PIP로 띄우기…") { WindowPiP.shared.showPicker(from: nil, onlyPID: r.processIdentifier) })
                m.addItem(Item(r.isHidden ? "가리기 해제" : "가리기") { if r.isHidden { r.unhide() } else { r.hide() } })
                m.addItem(Item("다시 시작") { [unowned self] in restartApp(r) })
                m.addItem(Item("종료") { r.terminate() })
            }
        }
    }

    /// 도구함 안에서의 정리 (카테고리 · 순서 · 빼기)
    func launcherMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let moveTo = NSMenuItem(title: "카테고리 옮기기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let here = locate(id)?.0
        for (c, cat) in cats.enumerated() {
            let i = Item(cat.name) { [unowned self] in moveApp(id, toCategory: c) }
            i.state = c == here ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(Item("새 카테고리…") { [unowned self] in newCategory(thenMove: id) })
        moveTo.submenu = sub
        m.addItem(moveTo)
        m.addItem(Item("앞으로 옮기기") { [unowned self] in move(id, by: -1) })
        m.addItem(Item("뒤로 옮기기") { [unowned self] in move(id, by: 1) })
        m.addItem(.separator())
        m.addItem(Item("런처에서 빼기") { [unowned self] in remove(id) })
        return m
    }

    func refresh() {
        applyAutoScale()
        let gridTile = Tile.size(icon: iconSize)
        let gridW = pad * 2 + CGFloat(cols) * gridTile.width + CGFloat(cols - 1) * gap
        // 목록 보기: 폭은 격자와 같게, 한 열로 한 줄씩
        let tile = listMode ? NSSize(width: gridW - pad * 2, height: Tile.rowHeight(icon: iconSize)) : gridTile
        let lc = listMode ? 1 : cols
        // 위젯에선 아래 버튼 줄을 숨기고(빼기 편집 중일 때만 보임) 우클릭 메뉴로 대신함
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // 전체 접기: 검색 중이 아니면 앱 목록과 아래 버튼 줄을 숨겨 검색 줄 + 플레이어만
        let allFolded = listCollapsed && !searching && !editing
        let showBar = (!widget || editing) && !allFolded
        let bottom = showBar ? barH : 0
        // 모두 접기 = 탭 모드: 왼쪽에 카테고리 세로 목록, 오른쪽에 고른 카테고리 앱
        let tabMode = catTabMode && query.trimmingCharacters(in: .whitespaces).isEmpty && !allFolded && (tab != 0 || cats.count > 1)
        // 왼쪽 목록 폭은 탭과 상관없이 같게 (탭을 바꿔도 창이 흔들리지 않게)
        let sideNames = cats.map(\.name) + ["도구함 앱", "다른 앱", "GitHub 앱", "데스크탑 10 (지금)"]
        let sbW: CGFloat = tabMode ? min(150, max(84, sideNames.map { name -> CGFloat in
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 13 * min(Tile.fontScale, 1.2), weight: .semibold)
            l.sizeToFit()
            return ceil(l.frame.width) + 44
        }.max() ?? 84)) : 0
        let side: CGFloat = tabMode ? sbW + 12 : 0
        // 폭은 접든 펴든 같게 (접으면 높이만 줄어듦). 위쪽 줄 버튼들이 들어갈 최소 폭은 보장
        // 탭 줄(탭 + 아이콘 버튼들)이 늘 다 들어가는 폭은 보장 (좁으면 버튼이 사라져 되돌릴 수 없었음)
        let w = max(gridW + side, 440)
        let left = (w - gridW - side) / 2 + pad
        let tilesLeft = left + side
        let rowRight = tilesLeft + gridW - pad * 2
        var sections = allFolded ? [] : displaySections()
        let runningTab = (tab == 1 || tab == 2 || tab == 3) && !searching
        let devTab = tab == 2 && !searching
        // 탭 모드: 왼쪽 목록에서 고른 묶음 하나만, 제목 줄 없이
        let allSections = sections
        sideCount = allSections.count
        if tabMode, !allSections.isEmpty {
            if curSel < 0 || curSel >= allSections.count { curSel = 0 }
            sections = [allSections[curSel]]
        }
        let showHeaders = !tabMode && (searching || runningTab || cats.count > 1)
        pillRects = []
        visibleTiles = []

        // 1) 카테고리마다: 제목 줄 → 열 × 행 격자(앱이 많으면 행이 늘어남)
        var views: [NSView] = []
        sectionYs = []
        var y = pad
        // 위쪽 탭 줄은 스크롤 밖 고정 영역에 (목록을 내려도 그대로)
        var headerViews: [NSView] = []
        var hdrH: CGFloat = 0
        // 탭: [전체 | 실행 중 N]
        if !allFolded && !searching {
            let ups = devApps.updateCount
            let seg = NSSegmentedControl(labels: ["전체", "실행 중 \(runningIDs().count)", ups > 0 ? "개발자 앱 ●\(ups)" : "개발자 앱", "데스크탑"], trackingMode: .selectOne,
                                         target: self, action: #selector(tabChanged(_:)))
            seg.selectedSegment = tab
            seg.controlSize = .small
            seg.sizeToFit()
            // 탭 줄은 앱 격자 폭이 아니라 창 전체 폭을 씀
            let hdrLeft: CGFloat = 12, hdrRight = w - 12
            seg.setFrameOrigin(NSPoint(x: hdrLeft, y: y))
            headerViews.append(seg)
            // 오른쪽 끝에서부터 같은 모양의 아이콘 버튼: [탭별 버튼…] [접기/펼치기] [⊞/☰]
            var bx = hdrRight
            func iconButton(_ symbol: String, _ tip: String, tint: NSColor? = nil, _ action: @escaping () -> Void) {
                let b = ActionButton(title: "", symbol: symbol) { _ in action() }
                b.isBordered = false
                b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
                b.contentTintColor = tint ?? .secondaryLabelColor
                b.toolTip = tip
                b.frame = NSRect(x: bx - 22, y: y + (seg.frame.height - 22) / 2, width: 22, height: 22)
                guard b.frame.minX >= seg.frame.maxX + 4 else { return }
                headerViews.append(b)
                bx -= 26
            }
            iconButton(listMode ? "square.grid.2x2" : "list.bullet", listMode ? "아이콘 격자로 보기" : "세로 목록으로 보기") { [unowned self] in
                listMode.toggle()
                d.set(listMode, forKey: "listMode")
                refresh()
            }
            if tab != 0 || cats.count > 1 {
                // 같은 사이드바 아이콘, 켜져 있으면 파란색 (모양이 바뀌면 다른 버튼으로 착각하기 쉬워서)
                iconButton("sidebar.left",
                           catTabMode ? "왼쪽 목록 켜짐 — 누르면 끄고 모두 펼쳐 보기" : "왼쪽 목록으로 보기 (하나씩 골라 보기)",
                           tint: catTabMode ? .controlAccentColor : nil) { [unowned self] in
                    catTabMode.toggle()
                    d.set(catTabMode, forKey: "catTabMode")
                    refresh()
                }
            }
            if tab == 1 {
                iconButton("power", "모두 종료 (도구함 · Finder 제외)") { BulkWindows.confirmAndRun(.quit) }
                iconButton("checklist", "골라서 종료…") { QuitPicker.shared.show() }
            }
            if tab == 2 {
                iconButton("arrow.clockwise", "새로 고침") { [unowned self] in devApps.load(force: true) }
                if ups > 0 {
                    iconButton("arrow.down.circle.fill", "모두 업데이트 (\(ups)개)", tint: .systemOrange) { [unowned self] in
                        // 도구함 자신은 맨 마지막에 (다시 시작되므로)
                        let me = Bundle.main.bundleIdentifier
                        devApps.ids.filter { devApps.hasUpdate($0) && $0 != me }.forEach { devApps.install($0) }
                        if let me, devApps.hasUpdate(me) { devApps.install(me) }
                    }
                }
            }
            y += seg.frame.height + 8
            if tabMode {
                // 위는 '보기 종류', 아래는 '카테고리' — 얇은 선과 여백으로 나눔
                let sep = NSBox(frame: NSRect(x: hdrLeft, y: y, width: hdrRight - hdrLeft, height: 1))
                sep.boxType = .separator
                sep.alphaValue = 0.6
                headerViews.append(sep)
                y += 9
            }
        }
        if !headerViews.isEmpty {
            hdrH = y
            y = 6       // 아래 스크롤 영역은 처음부터
        }
        // 왼쪽 세로 목록도 스크롤 밖 고정 영역에
        var sideViews: [NSView] = []
        var sidebarBottom: CGFloat = 0
        var sidebarTop: CGFloat = 0
        var sideCatcher: ScrollCatcher?
        if tabMode {
            // 왼쪽 세로 카테고리 목록 (스크롤로 위아래 이동, 앱을 끌어다 놓으면 그 카테고리로)
            let rowH = CategoryTab.height + 2
            let catcher = ScrollCatcher(frame: NSRect(x: left, y: y, width: sbW, height: CGFloat(allSections.count) * rowH))
            sideCatcher = catcher
            sidebarTop = y
            catcher.onScroll = { [unowned self] e in tabScroll(e) }
            sideViews.append(catcher)
            for (k, sec) in allSections.enumerated() {
                let t = CategoryTab(title: sec.title, count: sec.ids.count, selected: k == curSel,
                                    menu: sec.cat.map { categoryMenu($0) }, fontScale: Tile.fontScale, sidebarWidth: sbW)
                t.setFrameOrigin(NSPoint(x: left, y: y + CGFloat(k) * rowH))
                t.onClick = { [unowned self] in
                    curSel = k
                    refresh()
                }
                t.onScroll = { [unowned self] e in tabScroll(e) }
                t.dragCat = sec.cat
                t.toolTip = sec.cat != nil ? "누르면 ‘\(sec.title)’ 보기 · 끌어서 순서 바꾸기 · 스크롤로 위아래 이동 · 앱을 끌어다 놓으면 이 카테고리로"
                                           : "누르면 ‘\(sec.title)’ 보기 · 스크롤로 위아래 이동"
                sideViews.append(t)
                if let c = sec.cat { pillRects.append((c, t.frame)) }
                else if tab == 3 { pillRects.append((k, t.frame)) }   // 데스크탑: 앱을 끌어다 놓으면 그 데스크탑으로
            }
            sidebarBottom = y + CGFloat(allSections.count) * rowH
            // 목록과 앱 사이 세로 구분선
            let vline = NSBox(frame: NSRect(x: left + sbW + 5, y: y, width: 1, height: sidebarBottom - y))
            vline.boxType = .separator
            vline.alphaValue = 0.6
            sideViews.append(vline)
        }
        for sec in sections {
            let top = y
            if showHeaders {
                let hm = sec.cat.map { categoryMenu($0) } ?? NSMenu()
                let hv = HeaderView(frame: NSRect(x: 0, y: y, width: w, height: headerH),
                                    title: sec.title, count: sec.ids.count,
                                    menu: hm, lineStart: left)
                hv.dragCat = sec.cat
                if sec.cat != nil { hv.toolTip = "끌어서 카테고리 순서 바꾸기 · 우클릭: 이름 바꾸기 · 순서 · 삭제 · 여기에 앱 추가" }
                views.append(hv)
                y += headerH
            }
            let tilesTop = y
            let minRows = (searching || runningTab) ? 1 : rows
            let catRows = max(listMode ? 1 : minRows, Int(ceil(Double(sec.ids.count) / Double(lc))))
            for (i, id) in sec.ids.enumerated() {
                let mine = locate(id) != nil
                let t = Tile(name: name(id), icon: icon(id), iconSize: iconSize,
                             running: running(id) != nil, found: url(id) != nil,
                             editing: editing && mine && !devTab,
                             menu: devTab ? devTileMenu(id) : (mine ? tileMenu(id) : (running(id) != nil ? otherRunningMenu(id) : installedTileMenu(id))),
                             onRemove: { [unowned self] in remove(id) },
                             badge: devTab ? devApps.badge(id) : nil,
                             listWidth: listMode ? tile.width : nil)
                if let r = running(id) { t.trackMemory(pid: r.processIdentifier) }
                // 실행 중 탭: 마우스를 올리면 개별 종료 버튼
                if (tab == 1 || tab == 3) && !searching, let r = running(id), r.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    t.addQuitButton { [unowned self] force in
                        if confirmQuit {
                            let a = NSAlert()
                            a.messageText = "‘\(r.localizedName ?? "앱")’을(를) \(force ? "강제 종료" : "종료")할까요?"
                            a.informativeText = force ? "저장하지 않은 내용은 사라져요." : "저장 안 한 문서가 있으면 그 앱이 저장할지 물어봐요."
                            a.addButton(withTitle: force ? "강제 종료" : "종료")
                            a.addButton(withTitle: "취소")
                            let sup = NSButton(checkboxWithTitle: "다음부터 묻지 않기", target: nil, action: nil)
                            a.accessoryView = sup
                            NSApp.activate(ignoringOtherApps: true)
                            guard a.runModal() == .alertFirstButtonReturn else { return }
                            if sup.state == .on { setConfirmQuit(false) }
                        }
                        if force { r.forceTerminate() } else { r.terminate() }
                    }
                }
                if devTab, let a = devApps.app(id) {
                    let have = devApps.installedVersion(id).map { "설치된 버전 \($0)" } ?? "아직 안 받음"
                    let new = devApps.latest[id].map { " · 최신 \($0)" } ?? ""
                    t.toolTip = "\(a.name) — \(a.summary ?? a.repo)\n\(have)\(new)"
                }
                // GridView 는 위→아래 좌표라 칸의 위쪽 모서리 기준으로 놓음
                t.setFrameOrigin(NSPoint(x: tilesLeft + CGFloat(i % lc) * (tile.width + gap),
                                         y: y + CGFloat(i / lc) * (tile.height + gap)))
                t.onClick = { [unowned self] in
                    // 개발자 앱 탭에서 아직 안 받은 앱은 누르면 받기
                    if devTab && url(id) == nil { devApps.install(id) } else { launch(id) }
                }
                t.appID = ((mine || tab == 3) && !searching) ? id : ""   // 검색 결과에선 끌어 옮기기 안 함 (데스크탑 탭은 데스크탑 옮기기용)
                t.onHoverIn = { [unowned self] in setFocus(id) }
                t.focused = id == focusedID
                visibleTiles.append((id, t))
                views.append(t)
            }
            if sec.ids.isEmpty {
                let hint = NSTextField(labelWithString: searching ? "‘\(query)’와 맞는 앱이 없어요" : (devTab ? "목록이 비어 있어요 — 새로 고침을 눌러 보세요" : (runningTab ? (tab == 3 ? "이 데스크탑에는 열린 창이 없어요" : "실행 중인 \(sec.title)이 없어요") : "비어 있음 — 다른 카테고리의 앱을 여기로 끌어다 놓으세요")))
                hint.font = .systemFont(ofSize: 11)
                hint.textColor = .tertiaryLabelColor
                hint.frame = NSRect(x: tilesLeft, y: y + tile.height / 2 - 8, width: gridW - pad * 2, height: 16)
                hint.lineBreakMode = .byTruncatingTail
                views.append(hint)
            }
            y += CGFloat(catRows) * tile.height + CGFloat(catRows - 1) * gap
            if let c = sec.cat { sectionYs.append((c, top, tilesTop, y)) }
            y += sectionGap
        }
        if tabMode { y = max(y, sidebarBottom + sectionGap) }   // 사이드바가 앱보다 길면 그만큼
        let docH = allFolded ? 0 : y - sectionGap + pad

        // 2) 창 높이: 전부 보이게 하되 화면보다 크면 스크롤
        let screenH = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        // 플레이어 + 그 아래 가사 줄
        // 플레이어 · 가사 줄 중 떼어 낸 건 원래 창에서 빠짐
        let pH = showPlayer && !playerDetached ? playerH : 0
        let lh = showPlayer && !lyricsDetached ? lyrics.stripHeight : 0
        let ph = pH + lh
        // 목록 높이: 내용에 맞추되 화면을 넘지 않게
        let maxViewH = screenH - bottom - topH - ph - gripH - hdrH - 80
        // 아래 손잡이로 정한 높이가 있으면 그대로 (내용보다 길면 아래가 비고, 카테고리를 바꿔도 창 크기가 유지됨)
        var viewH = min(docH, maxViewH)
        if let u = userListH, docH > 0 { viewH = min(maxViewH, max(40, u)) }
        // 왼쪽 목록이 잘리지 않을 만큼은 높게
        if tabMode { viewH = max(viewH, min(maxViewH, sidebarBottom + 6)) }
        lastViewH = viewH
        lastDocH = maxViewH
        let grip = allFolded ? 0 : gripH
        let h = viewH + bottom + topH + ph + grip + hdrH

        let grid = GridView(frame: NSRect(x: 0, y: 0, width: w, height: max(docH, viewH)))
        // 고정 영역들: 위 탭 줄, 왼쪽 세로 목록
        let headerBar = DragArea(frame: NSRect(x: 0, y: 0, width: w, height: hdrH))
        headerBar.flippedLayout = true
        headerBar.isLocked = { [unowned self] in locked }
        headerViews.forEach(headerBar.addSubview)
        if widget { headerBar.menu = backgroundMenu() }
        let sidePane = GridView(frame: NSRect(x: 0, y: 0, width: max(0, tilesLeft - 4), height: viewH))
        if tabMode {
            // 스크롤로 카테고리 넘기기: 왼쪽 칸 전체
            sideCatcher?.frame = NSRect(x: 0, y: sidebarTop, width: sidePane.frame.width, height: viewH - sidebarTop)
            sideViews.forEach(sidePane.addSubview)
            sidePane.onScrollFirst = { [unowned self] e in tabScroll(e); return true }
            // 왼쪽 목록 위에 놓기: 앱은 그 카테고리로, 카테고리는 순서 바꾸기
            sidePane.target = { [unowned self] p in
                if tab == 3 {
                    guard let pill = pillRects.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) else { return nil }
                    return DropTarget(cat: pill.cat, index: 0, section: pill.rect.insetBy(dx: -3, dy: -3), caret: .zero)
                }
                return pillRects.contains { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }
                    ? dropTarget(at: p, left: tilesLeft, gridW: gridW, tile: tile, cols: lc) : nil
            }
            sidePane.onDropApps = { [unowned self] urls, t in add(urls, to: t.cat) }
            sidePane.onMoveApp = { [unowned self] id, t in
                if tab == 3 { moveToDesk(id, t.cat) } else { moveApp(id, toCategory: t.cat, at: t.index) }
            }
            sidePane.categoryTarget = { [unowned self] p in categoryDropTarget(at: p, left: left, width: sbW) }
            sidePane.onMoveCategory = { [unowned self] from, to in moveCategory(from: from, to: to) }
        }
        lastTabMode = tabMode
        if let edge = pendingFocusEdge {
            pendingFocusEdge = nil
            let pick = edge == .first ? visibleTiles.first : visibleTiles.last
            focusedID = pick?.id
            for (tid, t) in visibleTiles { t.focused = tid == focusedID }
        }
        // 앱 영역에서 스크롤하면 강조(포커스)가 앱을 한 칸씩 옮겨 감 (필요하면 목록도 따라 스크롤)
        grid.onScrollFirst = { [unowned self] e in
            // 빈 카테고리에서는 그냥 카테고리를 넘김 (끝까지 스크롤 옵션이 켜져 있을 때)
            if visibleTiles.isEmpty {
                guard lastTabMode, scrollCrossesCategory else { return false }
                tabScroll(e)
                return true
            }
            focusScroll(e)
            return true
        }
        grid.target = { [unowned self] p in dropTarget(at: p, left: tilesLeft, gridW: gridW, tile: tile, cols: lc) }
        grid.onDropApps = { [unowned self] urls, t in add(urls, to: t.cat) }
        grid.onMoveApp = { [unowned self] id, t in moveApp(id, toCategory: t.cat, at: t.index) }
        if !tabMode { grid.categoryTarget = { [unowned self] p in categoryDropTarget(at: p, left: left, width: rowRight - left) } }
        grid.onMoveCategory = { [unowned self] from, to in moveCategory(from: from, to: to) }
        views.forEach(grid.addSubview)
        if widget { grid.menu = backgroundMenu() }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: bottom + grip, width: w, height: viewH))
        scroll.documentView = grid
        scroll.hasVerticalScroller = docH > viewH
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // 3) 아래쪽 버튼 줄
        let add = ActionButton(title: "추가", symbol: "plus") { [unowned self] b in
            let m = NSMenu()
            if cats.count == 1 {
                m.addItem(Item("앱 고르기…") { [unowned self] in addApp(to: 0) })
            } else {
                m.addItem(headerItem("어느 카테고리에 넣을까요?"))
                for (c, cat) in cats.enumerated() { m.addItem(Item(cat.name) { [unowned self] in addApp(to: c) }) }
            }
            m.addItem(.separator())
            m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
            popUp(m, under: b)
        }
        let edit = ActionButton(title: editing ? "완료" : "빼기", symbol: editing ? "checkmark" : "minus") { [unowned self] _ in
            editing.toggle()
            refresh()
        }
        if editing { edit.keyEquivalent = "\r" }
        let catBtn = ActionButton(title: "카테고리", symbol: "folder") { [unowned self] b in
            popUp(categoriesMenu(), under: b)
        }
        let gear = ActionButton(title: "", symbol: "gearshape") { [unowned self] _ in openSettings() }
        gear.toolTip = "열 · 행 · 아이콘 크기 설정 (⌘,)"
        let widgetBtn = ActionButton(title: widget ? "창으로" : "위젯", symbol: widget ? "macwindow" : "rectangle.on.rectangle") { [unowned self] _ in
            setWidget(!widget)
        }
        widgetBtn.toolTip = widget ? "일반 창으로 돌아가기" : "바탕화면 위젯으로 바꾸기 (⌘⇧W)"
        let total = allIds.count
        let info = NSTextField(labelWithString: editing ? "⊖ 를 눌러 빼기"
                               : "\(total)개" + (showHeaders ? " · \(cats.count)카테고리" : "") + " · \(cols)열")
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.sizeToFit()

        let bar = NSView(frame: NSRect(x: 0, y: grip, width: w, height: barH))
        let line = NSBox(frame: NSRect(x: 0, y: barH - 1, width: w, height: 1))
        line.boxType = .separator
        bar.addSubview(line)
        var x: CGFloat = 10
        for b in [add, edit, catBtn] {
            b.setFrameOrigin(NSPoint(x: x, y: (barH - b.frame.height) / 2))
            bar.addSubview(b)
            x += b.frame.width + 6
        }
        gear.setFrameOrigin(NSPoint(x: w - gear.frame.width - 10, y: (barH - gear.frame.height) / 2))
        bar.addSubview(gear)
        widgetBtn.setFrameOrigin(NSPoint(x: gear.frame.minX - widgetBtn.frame.width - 4, y: (barH - widgetBtn.frame.height) / 2))
        bar.addSubview(widgetBtn)
        info.setFrameOrigin(NSPoint(x: widgetBtn.frame.minX - info.frame.width - 8, y: (barH - info.frame.height) / 2))
        if info.frame.minX > x { bar.addSubview(info) }

        // 바깥 틀(위젯 카드/일반 창 배경)과 위쪽 검색 줄은 한 번만 만들고, 아이콘 영역만 갈아 끼움
        let content: NSView
        if let r = root {
            content = r
        } else if widget {
            // 위젯 카드: 뒤 배경이 비치는 반투명 + 둥근 모서리
            let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.maskImage = roundedMask(20)
            content = fx
        } else {
            content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        }
        if widget { content.menu = backgroundMenu() }
        content.subviews.filter { $0 !== topBar }.forEach { $0.removeFromSuperview() }

        // 창 크기를 먼저 맞춘 뒤 내용을 배치. 창 위쪽 위치는 그대로 유지
        let topEdge = window.frame.maxY
        var f = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
        f.origin = NSPoint(x: window.frame.minX, y: topEdge - f.height)
        window.setFrame(f, display: false)
        if root == nil {
            window.contentView = content
            content.addSubview(topBar)
            root = content
        }
        content.frame = NSRect(x: 0, y: 0, width: w, height: h)
        content.addSubview(scroll)
        if hdrH > 0 {
            headerBar.setFrameOrigin(NSPoint(x: 0, y: bottom + grip + viewH))
            content.addSubview(headerBar)
        }
        if tabMode {
            sidePane.setFrameOrigin(NSPoint(x: 0, y: bottom + grip))
            content.addSubview(sidePane)
        }
        if showBar { content.addSubview(bar) }
        // 맨 아래 손잡이 (목록을 접었을 땐 숨김)
        if grip > 0 {
            resizeHandle.frame = NSRect(x: 0, y: 0, width: w, height: grip)
            content.addSubview(resizeHandle)
            resizeHandle.needsDisplay = true
        }
        if pH > 0 {
            playerBar.frame = NSRect(x: 0, y: h - topH - pH, width: w, height: pH)
            content.addSubview(playerBar)
            playerBar.needsLayout = true
        }
        if lh > 0 {
            lyrics.stripView.frame = NSRect(x: 0, y: h - topH - ph, width: w, height: lh)
            content.addSubview(lyrics.stripView)
        }
        // 떼어 낸 창
        // 떼어 낸 음악 창: 위에 플레이어, 아래에 가사 줄
        if showPlayer && playerDetached {
            showDetached(.player, view: playerBar, width: max(300, w), height: playerH,
                         below: (lyrics.stripView, lyrics.stripHeight))
        } else { playerPanel?.orderOut(nil) }
        lyricsPanel?.orderOut(nil)

        // 위쪽 줄: [🔍 앱 찾기 ........] [Finder]
        topBar.frame = NSRect(x: 0, y: h - topH, width: w, height: topH)
        // 위젯: 맨 위 손잡이
        if widget {
            if dragHandle.superview !== topBar { topBar.addSubview(dragHandle) }
            dragHandle.frame = NSRect(x: 0, y: barRowH, width: w, height: handleH)
            dragHandle.needsDisplay = true
        } else {
            dragHandle.removeFromSuperview()
        }
        let fb = finderButton.frame.size
        finderButton.setFrameOrigin(NSPoint(x: w - fb.width - 8, y: (barRowH - fb.height) / 2))
        collapseButton.image = NSImage(systemSymbolName: allFolded ? "chevron.down" : "chevron.up", accessibilityDescription: nil)
        collapseButton.toolTip = allFolded ? "앱 목록 펼치기" : "앱 목록 접기"
        youtubeButton.setFrameOrigin(NSPoint(x: finderButton.frame.minX - 26, y: (barRowH - 24) / 2))
        netflixButton.setFrameOrigin(NSPoint(x: youtubeButton.frame.minX - 26, y: (barRowH - 24) / 2))
        windowPiPButton.setFrameOrigin(NSPoint(x: netflixButton.frame.minX - 26, y: (barRowH - 24) / 2))
        collapseButton.setFrameOrigin(NSPoint(x: windowPiPButton.frame.minX - 26, y: (barRowH - 24) / 2))
        bulkButton.setFrameOrigin(NSPoint(x: collapseButton.frame.minX - 26, y: (barRowH - 24) / 2))
        updateLockButton()
        lockButton.setFrameOrigin(NSPoint(x: bulkButton.frame.minX - 26, y: (barRowH - 24) / 2))
        searchField.frame = NSRect(x: 10, y: (barRowH - 24) / 2, width: lockButton.frame.minX - 14, height: 24)
        scroll.contentView.scroll(to: .zero)

        buildStatusMenu()
    }

    // MARK: 메뉴바 메뉴

    func buildStatusMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        // 맨 위: 버전 (누르면 그 커밋 페이지)
        let ver = Item("도구함 \(AppVersion.text)") {
            if !AppVersion.commit.isEmpty, let u = URL(string: "https://github.com/SsackTeun/my-launcher/commit/\(AppVersion.commit)") {
                NSWorkspace.shared.open(u)
            }
        }
        ver.toolTip = "빌드 번호 = 커밋 수 · 괄호 = 커밋 ID\(AppVersion.date.isEmpty ? "" : " · 빌드한 때 \(AppVersion.date)")\(AppVersion.dirty ? "\n+수정: 커밋하지 않은 수정이 들어 있는 빌드" : "")\n누르면 GitHub 에서 그 커밋을 열어요"
        m.addItem(ver)
        m.addItem(.separator())
        for cat in cats {
            if cats.count > 1 { m.addItem(headerItem(cat.name)) }
            for id in cat.ids {
                let r = running(id) != nil
                let i = Item((r ? "● " : "    ") + name(id)) { [unowned self] in launch(id) }
                let img = icon(id).copy() as! NSImage
                img.size = NSSize(width: 16, height: 16)
                i.image = img
                i.isEnabled = url(id) != nil
                if r {
                    let sub = NSMenu()
                    sub.addItem(Item("앞으로 가져오기") { [unowned self] in launch(id) })
                    sub.addItem(Item("종료") { [unowned self] in quit(id) })
                    i.submenu = sub
                }
                m.addItem(i)
            }
            if cats.count > 1 { m.addItem(.separator()) }
        }
        if cats.count == 1 { m.addItem(.separator()) }
        m.addItem(Item("모두 실행") { [unowned self] in allIds.forEach(launch) })
        let bulk = NSMenuItem(title: "창 정리", action: nil, keyEquivalent: "")
        bulk.submenu = BulkWindows.menu()
        m.addItem(bulk)
        m.addItem(Item("런처 창 열기") { [unowned self] in showWindow() })
        m.addItem(Item("Dock 앱 가져오기") { [unowned self] in importDock() })
        m.addItem(Item("설정…") { [unowned self] in openSettings() })
        m.addItem(.separator())
        widgetItems().forEach(m.addItem)
        m.addItem(.separator())
        if showPlayer, let st = music.state {
            m.addItem(headerItem("♪ " + (st.title.isEmpty ? "YouTube Music" : st.title)))
            m.addItem(Item("    재생 / 일시정지") { [unowned self] in music.press("playPause") })
            m.addItem(Item("    다음 곡") { [unowned self] in music.press("next") })
            m.addItem(Item("    이전 곡") { [unowned self] in music.press("prev") })
            m.addItem(Item("    전체 가사 보기") { [unowned self] in lyrics.show() })
            m.addItem(Item("    YouTube Music 창 열기") { [unowned self] in music.showWindow() })
            m.addItem(.separator())
        }
        let yt = YouTubeWindow.shared
        m.addItem(Item("YouTube 창 열기") { yt.show() })
        if yt.isOpen {
            m.addItem(Item(yt.inMini ? "    큰 창으로 돌아가기" : "    작은 창으로 보기 (PIP)") { yt.toggleMini() })
            m.addItem(Item(yt.inPiP ? "    macOS PIP 끄기" : "    macOS PIP 로 보기 (구석 고정)") { yt.togglePiP() })
            m.addItem(Item("    YouTube 끄기") { yt.quit() })
        }
        do {
            let ap = Item("    영상 누르면 바로 PIP") { yt.autoPiP.toggle() }
            ap.state = yt.autoPiP ? .on : .off
            m.addItem(ap)
            let an = Item("    쇼츠 끝나면 자동 넘김") { yt.autoNextShorts.toggle() }
            an.state = yt.autoNextShorts ? .on : .off
            m.addItem(an)
        }
        let nf = VideoWindow.netflix
        m.addItem(Item("창 PIP로 띄우기…") { WindowPiP.shared.showPicker(from: nil) })
        m.addItem(Item("Netflix 창 열기") { nf.show() })
        if nf.isOpen {
            m.addItem(Item(nf.inMini ? "    큰 창으로 돌아가기" : "    작은 창으로 보기 (PIP)") { nf.toggleMini() })
            m.addItem(Item("    Netflix 끄기") { nf.quit() })
        }
        let pl = Item("YouTube Music 미니 플레이어") { [unowned self] in setPlayer(!playerEnabled) }
        pl.state = playerEnabled ? .on : .off
        m.addItem(pl)
        let fav = Item("자주 쓰는 앱 막대") { FavBar.shared.enabled.toggle() }
        fav.state = FavBar.shared.enabled ? .on : .off
        m.addItem(fav)
        let sushi = Item("화면 아래 회전 초밥 (실행 중인 앱)") { [unowned self] in
            SushiBelt.shared.enabled.toggle()
            buildStatusMenu()
        }
        sushi.state = SushiBelt.shared.enabled ? .on : .off
        m.addItem(sushi)
        let dockItem = Item("켜져 있는 동안 Dock 가리기") { [unowned self] in setHideDock(!hideDock) }
        dockItem.state = hideDock ? .on : .off
        m.addItem(dockItem)
        let login = Item("로그인 시 자동 실행") { [unowned self] in toggleLogin() }
        login.state = loginEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(Item("도구함 다시 시작") { [unowned self] in restartSelf() })
        m.addItem(Item("도구함 종료") { NSApp.terminate(nil) })
        statusItem.menu = m
    }

    // MARK: 설정 창 (열 · 행 · 아이콘 크기)

    /// 개발자 앱 우클릭: 실행 · 받기/업데이트 · 다시 받기 · GitHub · 도구함에 넣기
    func devTileMenu(_ id: String) -> NSMenu {
        LiveMenu { [unowned self] m in
            let installed = url(id) != nil
            if installed { m.addItem(Item("실행") { [unowned self] in launch(id) }) }
            if !installed {
                m.addItem(Item("받기 (설치)") { [unowned self] in devApps.install(id) })
            } else if devApps.hasUpdate(id) {
                m.addItem(Item("업데이트 → \(devApps.latest[id] ?? "")") { [unowned self] in devApps.install(id) })
            } else {
                m.addItem(Item("다시 받기") { [unowned self] in devApps.install(id) })
            }
            m.addItem(.separator())
            m.addItem(Item("GitHub 에서 보기") { [unowned self] in devApps.openRepo(id) })
            if installed, locate(id) == nil {
                let addTo = NSMenuItem(title: "도구함에 넣기", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for (c, cat) in cats.enumerated() {
                    sub.addItem(Item(cat.name) { [unowned self] in if let u = url(id) { add([u], to: c) } })
                }
                addTo.submenu = sub
                m.addItem(addTo)
            }
            if let u = url(id) { m.addItem(Item("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) }) }
        }
    }

    @objc func tabChanged(_ s: NSSegmentedControl) {
        tab = s.selectedSegment
        if tab == 2 { devApps.load(force: true) }
        d.set(tab, forKey: "listTab")
        refresh()
    }

    @objc func openSettings() {
        if settings == nil { buildSettings() }
        syncSettings()
        settings!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettings() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 442),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "도구함 설정 — \(AppVersion.text)"
        p.isReleasedWhenClosed = false
        let v = p.contentView!

        func label(_ t: String, y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 10, y: y, width: 90, height: 20)
            v.addSubview(l)
        }
        func numberRow(_ t: String, y: CGFloat, max: Int, note: String) -> (NSTextField, NSStepper) {
            label(t, y: y)
            let f = NSTextField(frame: NSRect(x: 108, y: y - 1, width: 50, height: 22))
            let nf = NumberFormatter()
            nf.minimum = 1
            nf.maximum = NSNumber(value: max)
            nf.allowsFloats = false
            f.formatter = nf
            f.alignment = .center
            f.target = self
            f.action = #selector(fieldChanged(_:))
            v.addSubview(f)
            let s = NSStepper(frame: NSRect(x: 162, y: y - 2, width: 20, height: 24))
            s.minValue = 1
            s.maxValue = Double(max)
            s.increment = 1
            s.valueWraps = false
            s.target = self
            s.action = #selector(stepperChanged(_:))
            v.addSubview(s)
            let n = NSTextField(labelWithString: note)
            n.font = .systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: 190, y: y + 1, width: 160, height: 16)
            v.addSubview(n)
            return (f, s)
        }

        label("메모리", y: 402)
        memoryCheck = NSButton(checkboxWithTitle: "실행 중인 앱에 메모리 사용량 표시", target: self, action: #selector(memoryChecked(_:)))
        memoryCheck.frame = NSRect(x: 106, y: 401, width: 250, height: 22)
        memoryCheck.toolTip = "도우미 프로세스까지 합친 값 (활동 모니터의 '메모리' 칸과 같은 기준), 2초마다 새로"
        v.addSubview(memoryCheck)

        label("앱 종료", y: 372)
        confirmCheck = NSButton(checkboxWithTitle: "ⓧ 로 끌 때 먼저 물어보기", target: self, action: #selector(confirmChecked(_:)))
        confirmCheck.frame = NSRect(x: 106, y: 371, width: 250, height: 22)
        v.addSubview(confirmCheck)

        label("스크롤", y: 342)
        crossCheck = NSButton(checkboxWithTitle: "끝까지 스크롤하면 다음 카테고리로", target: self, action: #selector(crossChecked(_:)))
        crossCheck.frame = NSRect(x: 106, y: 341, width: 250, height: 22)
        crossCheck.toolTip = "왼쪽 목록 보기에서, 마지막 앱보다 더 내리면 다음 카테고리 첫 앱으로 (위로는 이전 카테고리 마지막 앱으로)"
        v.addSubview(crossCheck)

        label("창 위치", y: 312)
        lockCheck = NSButton(checkboxWithTitle: "위치 고정 (끌어도 안 움직임)", target: self, action: #selector(lockChecked(_:)))
        lockCheck.frame = NSRect(x: 106, y: 311, width: 250, height: 22)
        v.addSubview(lockCheck)

        label("글자 크기", y: 282)
        var fx: CGFloat = 108
        for (t, d) in [("A−", -0.1), ("A+", 0.1)] {
            let b = ActionButton(title: t, symbol: nil) { [unowned self] _ in setUIScale(uiScale + CGFloat(d)) }
            b.controlSize = .small
            b.sizeToFit()
            b.setFrameOrigin(NSPoint(x: fx, y: 280))
            v.addSubview(b)
            fx = b.frame.maxX + 4
        }
        uiScaleLabel = NSTextField(labelWithString: "100%")
        uiScaleLabel.frame = NSRect(x: fx + 4, y: 283, width: 70, height: 16)
        v.addSubview(uiScaleLabel)
        let reset = ActionButton(title: "자동", symbol: nil) { [unowned self] _ in setUIScaleAuto() }
        reset.toolTip = "화면 크기와 아이콘 크기에 맞춰 자동으로"
        reset.controlSize = .small
        reset.sizeToFit()
        reset.setFrameOrigin(NSPoint(x: fx + 76, y: 280))
        v.addSubview(reset)

        label("음악", y: 252)
        playerCheck = NSButton(checkboxWithTitle: "YouTube Music 미니 플레이어", target: self, action: #selector(playerChecked(_:)))
        playerCheck.frame = NSRect(x: 106, y: 251, width: 250, height: 22)
        v.addSubview(playerCheck)

        label("Dock", y: 222)
        dockCheck = NSButton(checkboxWithTitle: "켜져 있는 동안 Dock 가리기", target: self, action: #selector(dockChecked(_:)))
        dockCheck.frame = NSRect(x: 106, y: 221, width: 240, height: 22)
        v.addSubview(dockCheck)

        label("모양", y: 192)
        widgetCheck = NSButton(checkboxWithTitle: "바탕화면 위젯으로 쓰기", target: self, action: #selector(widgetChecked(_:)))
        widgetCheck.frame = NSRect(x: 106, y: 191, width: 240, height: 22)
        v.addSubview(widgetCheck)

        (colsField, colsStepper) = numberRow("열 (가로 칸)", y: 150, max: 12, note: "한 줄에 놓을 앱 수")
        (rowsField, rowsStepper) = numberRow("행 (세로 칸)", y: 116, max: 12, note: "카테고리마다 최소 줄 수")

        label("아이콘 크기", y: 80)
        sizeSlider = NSSlider(value: 64, minValue: 24, maxValue: 128, target: self, action: #selector(sliderChanged(_:)))
        sizeSlider.frame = NSRect(x: 106, y: 78, width: 170, height: 24)
        sizeSlider.numberOfTickMarks = 14
        sizeSlider.allowsTickMarkValuesOnly = true
        v.addSubview(sizeSlider)
        sizeLabel = NSTextField(labelWithString: "64px")
        sizeLabel.frame = NSRect(x: 282, y: 80, width: 60, height: 20)
        v.addSubview(sizeLabel)

        // 자주 쓰는 크기 바로가기
        var x: CGFloat = 108
        for (t, s) in [("작게", 32.0), ("보통", 48.0), ("크게", 64.0), ("아주 크게", 96.0)] {
            let b = ActionButton(title: t, symbol: nil) { [unowned self] _ in
                iconSize = CGFloat(s)
                syncSettings()
                save()
            }
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.sizeToFit()
            b.setFrameOrigin(NSPoint(x: x, y: 44))
            v.addSubview(b)
            x += b.frame.width + 2
        }

        let hint = NSTextField(labelWithString: "바꾸면 바로 적용돼요. 앱이 칸보다 많으면 그 카테고리의 줄이 늘어나요.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 12, width: 330, height: 16)
        v.addSubview(hint)

        p.center()
        settings = p
    }

    func syncSettings() {
        widgetCheck.state = widget ? .on : .off
        dockCheck.state = hideDock ? .on : .off
        playerCheck.state = playerEnabled ? .on : .off
        lockCheck.state = locked ? .on : .off
        crossCheck.state = scrollCrossesCategory ? .on : .off
        confirmCheck.state = confirmQuit ? .on : .off
        memoryCheck.state = Tile.showMemory ? .on : .off
        uiScaleLabel.stringValue = (uiScaleAuto ? "자동 " : "") + "\(Int((uiScale * 100).rounded()))%"
        colsField.integerValue = cols; colsStepper.integerValue = cols
        rowsField.integerValue = rows; rowsStepper.integerValue = rows
        sizeSlider.doubleValue = Double(iconSize)
        sizeLabel.stringValue = "\(Int(iconSize))px"
    }

    @objc func widgetChecked(_ b: NSButton) { setWidget(b.state == .on) }

    @objc func fieldChanged(_ f: NSTextField) {
        let v = max(1, min(12, f.integerValue))
        if f === colsField { cols = v } else { rows = v }
        syncSettings()
        save()
    }

    @objc func stepperChanged(_ s: NSStepper) {
        if s === colsStepper { cols = s.integerValue } else { rows = s.integerValue }
        syncSettings()
        save()
    }

    @objc func sliderChanged(_ s: NSSlider) {
        iconSize = CGFloat(s.doubleValue.rounded())
        sizeLabel.stringValue = "\(Int(iconSize))px"
        save()
    }
}

// MARK: - 검색칸 입력

extension AppDelegate: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        if query.isEmpty { installed = nil }     // 새로 찾기 시작할 때 설치된 앱 목록을 새로 읽음
        query = searchField.stringValue
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchField else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            // 검색칸이 비어 있으면 강조된 앱 실행
            if query.trimmingCharacters(in: .whitespaces).isEmpty, let id = focusedID {
                launch(id)
                return true
            }
            // Enter: 첫 번째 결과 실행
            if let first = displaySections().flatMap(\.ids).first {
                launch(first)
                clearSearch()
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            clearSearch()
            return true
        }
        return false
    }

    func clearSearch() {
        searchField.stringValue = ""
        query = ""
        refresh()
    }

    @objc func focusSearch() {
        showWindow()
        window.makeFirstResponder(searchField)
    }
}

/// 버전 표시: 1.1 · 빌드 75 (bfa3091) — 빌드 번호는 커밋 수, 괄호는 커밋 ID (build.sh 가 넣음)
enum AppVersion {
    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var release: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { info["CFBundleVersion"] as? String ?? "?" }
    static var commit: String { info["GitCommit"] as? String ?? "" }
    static var dirty: Bool { info["GitDirty"] as? Bool ?? false }
    static var date: String { info["BuildDate"] as? String ?? "" }
    /// 짧게: "1.1 · 빌드 75 (bfa3091)" — 커밋 안 한 수정이 들어 있으면 "+수정"
    static var text: String {
        var s = "\(release) · 빌드 \(build)"
        if !commit.isEmpty { s += " (\(commit)\(dirty ? "+수정" : ""))" }
        return s
    }
}

// 기본 메뉴 (⌘Q, ⌘W, ⌘, 가 동작하도록)
@MainActor
func buildMainMenu(_ delegate: AppDelegate) {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    let pref = NSMenuItem(title: "설정…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
    pref.target = delegate
    appMenu.addItem(pref)
    let find = NSMenuItem(title: "앱 찾기", action: #selector(AppDelegate.focusSearch), keyEquivalent: "f")
    find.target = delegate
    appMenu.addItem(find)
    let wid = NSMenuItem(title: "위젯 모드로 바꾸기", action: #selector(AppDelegate.toggleWidgetAction), keyEquivalent: "W")
    wid.target = delegate
    appMenu.addItem(wid)
    appMenu.addItem(.separator())
    let rs = NSMenuItem(title: "도구함 다시 시작", action: #selector(AppDelegate.restartSelf), keyEquivalent: "r")
    rs.target = delegate
    appMenu.addItem(rs)
    appMenu.addItem(withTitle: "도구함 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "편집")   // 이름 입력 칸에서 ⌘C/⌘V 가 되도록
    editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    let winItem = NSMenuItem()
    main.addItem(winItem)
    let winMenu = NSMenu(title: "윈도우")
    winMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = winMenu
    NSApp.mainMenu = main
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    buildMainMenu(delegate)
    app.run()
}
