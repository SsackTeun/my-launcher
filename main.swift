// 도구함 — 내가 만든 앱들을 한곳에 모아 각자 따로 실행하는 런처
import Cocoa
import ServiceManagement

let defaultApps = ["local.jaeyeong.excelruler", "com.jaeyeong.listcalendartodo"]

// MARK: - 앱 하나를 나타내는 칸

final class Tile: NSView {
    static let size = NSSize(width: 104, height: 112)
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(name: String, icon: NSImage, running: Bool, found: Bool, menu m: NSMenu?) {
        super.init(frame: NSRect(origin: .zero, size: Tile.size))
        menu = m
        toolTip = found ? (running ? "\(name) — 실행 중 (클릭하면 앞으로)" : "\(name) — 클릭해서 실행") : "\(name) — 앱을 찾을 수 없음"

        let iv = NSImageView(frame: NSRect(x: 20, y: 36, width: 64, height: 64))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        if !found { iv.alphaValue = 0.35 }
        addSubview(iv)

        let label = NSTextField(labelWithString: name)
        label.frame = NSRect(x: 4, y: 10, width: Tile.size.width - 8, height: 18)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if running {
            let dot = NSView(frame: NSRect(x: Tile.size.width / 2 - 3, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
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
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var ids: [String] = []
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        ids = UserDefaults.standard.stringArray(forKey: "apps") ?? defaultApps

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "도구함"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LauncherWindow")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧰"

        // 앱이 켜지거나 꺼지면 초록 점을 바로 갱신
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }

        refresh()
        if UserDefaults.standard.object(forKey: "NSWindow Frame LauncherWindow") == nil { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        if let r = running(id) {
            r.activate()
            return
        }
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

    @objc func addApp() {
        let p = NSOpenPanel()
        p.title = "런처에 넣을 앱 고르기"
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            if let id = Bundle(url: u)?.bundleIdentifier, !ids.contains(id) { ids.append(id) }
        }
        save()
    }

    @objc func launchAll() { ids.forEach(launch) }

    func save() {
        UserDefaults.standard.set(ids, forKey: "apps")
        refresh()
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = msg
        a.runModal()
    }

    // MARK: 로그인 시 자동 실행

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            alert("로그인 항목을 바꾸지 못했어요: \(error.localizedDescription)\n시스템 설정 → 일반 → 로그인 항목에서 직접 추가할 수 있어요.")
        }
        refresh()
    }

    // MARK: 화면 그리기

    func tileMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        let isRunning = running(id) != nil
        m.addItem(Item(isRunning ? "앞으로 가져오기" : "실행") { [unowned self] in launch(id) })
        let q = Item("종료") { [unowned self] in quit(id) }
        q.isEnabled = isRunning
        m.autoenablesItems = false
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
        // 창: 앱 칸 + 맨 끝 "추가" 칸
        let pad: CGFloat = 16, gap: CGFloat = 4
        let count = ids.count + 1
        let w = pad * 2 + CGFloat(count) * Tile.size.width + CGFloat(count - 1) * gap
        let h = pad * 2 + Tile.size.height
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        for (i, id) in ids.enumerated() {
            let t = Tile(name: name(id), icon: icon(id), running: running(id) != nil, found: url(id) != nil, menu: tileMenu(id))
            t.setFrameOrigin(NSPoint(x: pad + CGFloat(i) * (Tile.size.width + gap), y: pad))
            t.onClick = { [unowned self] in launch(id) }
            content.addSubview(t)
        }
        let plus = NSImage(systemSymbolName: "plus.app", accessibilityDescription: "앱 추가") ?? NSImage()
        plus.isTemplate = true
        let add = Tile(name: "앱 추가", icon: plus, running: false, found: true, menu: nil)
        add.toolTip = "런처에 앱 추가"
        add.setFrameOrigin(NSPoint(x: pad + CGFloat(ids.count) * (Tile.size.width + gap), y: pad))
        add.onClick = { [unowned self] in addApp() }
        content.addSubview(add)

        let top = window.frame.maxY
        window.contentView = content
        window.setContentSize(content.frame.size)
        var f = window.frame
        f.origin.y = top - f.height   // 크기가 바뀌어도 창 위쪽 위치는 그대로
        window.setFrame(f, display: true)

        // 메뉴바 메뉴
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
        m.addItem(Item("모두 실행") { [unowned self] in launchAll() })
        m.addItem(Item("런처 창 열기") { [unowned self] in showWindow() })
        m.addItem(Item("앱 추가…") { [unowned self] in addApp() })
        let login = Item("로그인 시 자동 실행") { [unowned self] in toggleLogin() }
        login.state = loginEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(Item("도구함 종료") { NSApp.terminate(nil) })
        statusItem.menu = m
    }
}

final class Item: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

// 기본 메뉴 (⌘Q, ⌘W 가 동작하도록)
func buildMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
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
buildMainMenu()
app.run()
