// 도구함 — 내가 만든 앱들을 한곳에 모아 각자 따로 실행하는 런처
import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

let defaultApps = ["local.jaeyeong.excelruler", "com.jaeyeong.listcalendartodo"]

// MARK: - 작은 도우미

/// 클로저로 동작하는 버튼
final class ActionButton: NSButton {
    private var handler: (() -> Void)?
    convenience init(title: String, symbol: String?, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        bezelStyle = .rounded
        controlSize = .regular
        handler = action
        target = self
        self.action = #selector(run)
        sizeToFit()
    }
    func setHandler(_ h: @escaping () -> Void) { handler = h; target = self; action = #selector(run) }
    @objc private func run() { handler?() }
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

// MARK: - 앱 하나를 나타내는 칸

final class Tile: NSView {
    static func size(icon: CGFloat) -> NSSize {
        NSSize(width: max(icon + 32, 76), height: icon + 42)
    }

    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private let editing: Bool

    init(name: String, icon: NSImage, iconSize: CGFloat, running: Bool, found: Bool,
         editing: Bool, menu m: NSMenu?, onRemove: (() -> Void)?) {
        self.editing = editing
        let s = Tile.size(icon: iconSize)
        super.init(frame: NSRect(origin: .zero, size: s))
        menu = m
        toolTip = found ? (running ? "\(name) — 실행 중 (클릭하면 앞으로)" : "\(name) — 클릭해서 실행")
                        : "\(name) — 앱을 찾을 수 없음"

        let iv = NSImageView(frame: NSRect(x: (s.width - iconSize) / 2, y: 30, width: iconSize, height: iconSize))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        if !found { iv.alphaValue = 0.35 }
        addSubview(iv)

        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: 2, y: 10, width: s.width - 4, height: 16)
        label.alignment = .center
        label.font = .systemFont(ofSize: iconSize < 40 ? 10 : 12)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if running {
            let dot = NSView(frame: NSRect(x: s.width / 2 - 3, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
        }

        // 편집 모드: 왼쪽 위에 빨간 ⊖ 버튼
        if editing, let onRemove {
            let b = ActionButton(title: "", symbol: "minus.circle.fill", onRemove)
            b.isBordered = false
            b.contentTintColor = .systemRed
            b.symbolConfiguration = .init(pointSize: 18, weight: .bold)
            b.toolTip = "런처에서 빼기"
            b.frame = NSRect(x: iv.frame.minX - 10, y: iv.frame.maxY - 14, width: 24, height: 24)
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, !editing else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if !editing, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 아이콘 격자. 위에서 아래로 쌓이도록 좌표를 뒤집고, Finder에서 .app 을 끌어다 놓으면 추가
final class GridView: NSView {
    override var isFlipped: Bool { true }
    var onDropApps: (([URL]) -> Void)?
    private var dropHighlight = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func appURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !appURLs(sender).isEmpty
        dropHighlight = ok
        return ok ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = appURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropApps?(urls)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard dropHighlight else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        p.fill()
        NSColor.controlAccentColor.setStroke()
        p.lineWidth = 2
        p.stroke()
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    let d = UserDefaults.standard
    var ids: [String] = []
    var cols = 4
    var rows = 2
    var iconSize: CGFloat = 64
    var editing = false

    var window: NSWindow!
    var statusItem: NSStatusItem!
    var settings: NSPanel?
    var colsField: NSTextField!, rowsField: NSTextField!
    var colsStepper: NSStepper!, rowsStepper: NSStepper!
    var sizeSlider: NSSlider!, sizeLabel: NSTextField!

    let pad: CGFloat = 14, gap: CGFloat = 4, barH: CGFloat = 44

    func applicationDidFinishLaunching(_ n: Notification) {
        ids = d.stringArray(forKey: "apps") ?? defaultApps
        if d.object(forKey: "cols") != nil {
            cols = max(1, d.integer(forKey: "cols"))
            rows = max(1, d.integer(forKey: "rows"))
            iconSize = CGFloat(d.double(forKey: "iconSize"))
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "도구함"
        window.isReleasedWhenClosed = false
        let firstRun = d.string(forKey: "NSWindow Frame LauncherWindow") == nil
        window.setFrameAutosaveName("LauncherWindow")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧰"

        // 앱이 켜지거나 꺼지면 초록 점을 바로 갱신
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }

        refresh()
        if firstRun { window.center() }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 앱 정보

    func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    func running(_ id: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
    func name(_ id: String) -> String {
        guard let u = url(id) else { return id }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    func icon(_ id: String) -> NSImage {
        if let u = url(id) { return NSWorkspace.shared.icon(forFile: u.path) }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: 동작

    func launch(_ id: String) {
        if let r = running(id) { r.activate(); return }
        guard let u = url(id) else {
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
        ids.removeAll { $0 == id }
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + delta
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        save()
    }

    func add(_ urls: [URL]) {
        var skipped: [String] = []
        for u in urls {
            if let id = Bundle(url: u)?.bundleIdentifier {
                if !ids.contains(id) { ids.append(id) }
            } else {
                skipped.append(u.lastPathComponent)
            }
        }
        save()
        if !skipped.isEmpty { alert("앱 정보를 읽지 못해 추가하지 못했어요: \(skipped.joined(separator: ", "))") }
    }

    func addApp() {
        let p = NSOpenPanel()
        p.title = "런처에 넣을 앱 고르기"
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        add(p.urls)
    }

    func save() {
        d.set(ids, forKey: "apps")
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

    func tileMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let isRunning = running(id) != nil
        m.addItem(Item(isRunning ? "앞으로 가져오기" : "실행") { [unowned self] in launch(id) })
        let q = Item("종료") { [unowned self] in quit(id) }
        q.isEnabled = isRunning
        m.addItem(q)
        m.addItem(.separator())
        m.addItem(Item("앞으로 옮기기") { [unowned self] in move(id, by: -1) })
        m.addItem(Item("뒤로 옮기기") { [unowned self] in move(id, by: 1) })
        if let u = url(id) {
            m.addItem(Item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        m.addItem(.separator())
        m.addItem(Item("런처에서 빼기") { [unowned self] in remove(id) })
        return m
    }

    func refresh() {
        let tile = Tile.size(icon: iconSize)
        // 창 크기는 설정한 열 × 행 에 맞춤. 앱이 칸보다 많으면 아래로 스크롤
        let gridW = pad * 2 + CGFloat(cols) * tile.width + CGFloat(cols - 1) * gap
        let gridH = pad * 2 + CGFloat(rows) * tile.height + CGFloat(rows - 1) * gap
        let neededRows = max(rows, Int(ceil(Double(ids.count) / Double(cols))))
        let docH = pad * 2 + CGFloat(neededRows) * tile.height + CGFloat(neededRows - 1) * gap
        let w = max(gridW, 300)
        let h = gridH + barH

        let grid = GridView(frame: NSRect(x: 0, y: 0, width: w, height: max(docH, gridH)))
        grid.onDropApps = { [unowned self] urls in add(urls) }
        let left = (w - gridW) / 2 + pad
        for (i, id) in ids.enumerated() {
            let t = Tile(name: name(id), icon: icon(id), iconSize: iconSize,
                         running: running(id) != nil, found: url(id) != nil,
                         editing: editing, menu: tileMenu(id),
                         onRemove: { [unowned self] in remove(id) })
            let c = i % cols, r = i / cols
            t.setFrameOrigin(NSPoint(x: left + CGFloat(c) * (tile.width + gap),
                                     y: pad + CGFloat(r) * (tile.height + gap)))
            t.onClick = { [unowned self] in launch(id) }
            grid.addSubview(t)
        }
        if ids.isEmpty {
            let hint = NSTextField(labelWithString: "＋ 추가를 누르거나 Finder에서 앱을 끌어다 놓으세요")
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            hint.frame = NSRect(x: 0, y: gridH / 2 - 10, width: w, height: 20)
            grid.addSubview(hint)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: barH, width: w, height: gridH))
        scroll.documentView = grid
        scroll.hasVerticalScroller = docH > gridH
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // 아래쪽 버튼 줄
        let add = ActionButton(title: "추가", symbol: "plus") { [unowned self] in addApp() }
        let edit = ActionButton(title: editing ? "완료" : "빼기", symbol: editing ? "checkmark" : "minus") { [unowned self] in
            editing.toggle()
            refresh()
        }
        if editing { edit.keyEquivalent = "\r" }
        let gear = ActionButton(title: "", symbol: "gearshape") { [unowned self] in openSettings() }
        gear.toolTip = "배치 · 아이콘 크기 설정 (⌘,)"
        let info = NSTextField(labelWithString: editing ? "⊖ 를 눌러 빼기" : "\(ids.count)개 · \(cols)열 × \(rows)행")
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.sizeToFit()

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: w, height: barH))
        let line = NSBox(frame: NSRect(x: 0, y: barH - 1, width: w, height: 1))
        line.boxType = .separator
        bar.addSubview(line)
        var x: CGFloat = 10
        for b in [add, edit] {
            b.setFrameOrigin(NSPoint(x: x, y: (barH - b.frame.height) / 2))
            bar.addSubview(b)
            x += b.frame.width + 6
        }
        gear.setFrameOrigin(NSPoint(x: w - gear.frame.width - 10, y: (barH - gear.frame.height) / 2))
        bar.addSubview(gear)
        info.setFrameOrigin(NSPoint(x: gear.frame.minX - info.frame.width - 8, y: (barH - info.frame.height) / 2))
        if info.frame.minX > x { bar.addSubview(info) }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.addSubview(scroll)
        content.addSubview(bar)

        // 창 크기를 먼저 맞춘 뒤 내용을 넣어야 잘리지 않음. 창 위쪽 위치는 그대로 유지
        let top = window.frame.maxY
        var f = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
        f.origin = NSPoint(x: window.frame.minX, y: top - f.height)
        window.setFrame(f, display: false)
        window.contentView = content
        scroll.contentView.scroll(to: .zero)

        buildStatusMenu()
    }

    // MARK: 메뉴바 메뉴

    func buildStatusMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        for id in ids {
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
        m.addItem(.separator())
        m.addItem(Item("모두 실행") { [unowned self] in ids.forEach(launch) })
        m.addItem(Item("런처 창 열기") { [unowned self] in showWindow() })
        m.addItem(Item("앱 추가…") { [unowned self] in addApp() })
        m.addItem(Item("설정…") { [unowned self] in openSettings() })
        let login = Item("로그인 시 자동 실행") { [unowned self] in toggleLogin() }
        login.state = loginEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(Item("도구함 종료") { NSApp.terminate(nil) })
        statusItem.menu = m
    }

    // MARK: 설정 창 (열 · 행 · 아이콘 크기)

    @objc func openSettings() {
        if settings == nil { buildSettings() }
        syncSettings()
        settings!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildSettings() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 196),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "도구함 설정"
        p.isReleasedWhenClosed = false
        let v = p.contentView!

        func label(_ t: String, y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 10, y: y, width: 90, height: 20)
            v.addSubview(l)
        }
        func numberRow(_ t: String, y: CGFloat, max: Int) -> (NSTextField, NSStepper) {
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
            return (f, s)
        }

        (colsField, colsStepper) = numberRow("열 (가로 칸)", y: 150, max: 12)
        (rowsField, rowsStepper) = numberRow("행 (세로 칸)", y: 116, max: 12)

        label("아이콘 크기", y: 80)
        sizeSlider = NSSlider(value: 64, minValue: 24, maxValue: 128, target: self, action: #selector(sliderChanged(_:)))
        sizeSlider.frame = NSRect(x: 106, y: 78, width: 160, height: 24)
        sizeSlider.numberOfTickMarks = 14
        sizeSlider.allowsTickMarkValuesOnly = true
        v.addSubview(sizeSlider)
        sizeLabel = NSTextField(labelWithString: "64px")
        sizeLabel.frame = NSRect(x: 272, y: 80, width: 56, height: 20)
        v.addSubview(sizeLabel)

        // 자주 쓰는 크기 바로가기
        var x: CGFloat = 108
        for (t, s) in [("작게", 32.0), ("보통", 48.0), ("크게", 64.0), ("아주 크게", 96.0)] {
            let b = ActionButton(title: t, symbol: nil) { [unowned self] in
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

        let hint = NSTextField(labelWithString: "바꾸면 바로 적용돼요. 앱이 칸보다 많으면 아래로 스크롤돼요.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 12, width: 310, height: 16)
        v.addSubview(hint)

        p.center()
        settings = p
    }

    func syncSettings() {
        colsField.integerValue = cols; colsStepper.integerValue = cols
        rowsField.integerValue = rows; rowsStepper.integerValue = rows
        sizeSlider.doubleValue = Double(iconSize)
        sizeLabel.stringValue = "\(Int(iconSize))px"
    }

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

// 기본 메뉴 (⌘Q, ⌘W, ⌘, 가 동작하도록)
func buildMainMenu(_ delegate: AppDelegate) {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    let pref = NSMenuItem(title: "설정…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
    pref.target = delegate
    appMenu.addItem(pref)
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "도구함 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let winItem = NSMenuItem()
    main.addItem(winItem)
    let winMenu = NSMenu(title: "윈도우")
    winMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = winMenu
    NSApp.mainMenu = main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
buildMainMenu(delegate)
app.run()
