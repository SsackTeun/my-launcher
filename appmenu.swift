// 앱 아이콘 우클릭 메뉴를 Dock 처럼: 열린 창 목록 · 새 창 · 그 앱의 메뉴 막대 · 가리기 · 종료
// 앱의 창과 메뉴는 "손쉬운 사용" 권한으로 읽고 누름
import Cocoa
import ApplicationServices

/// 열릴 때마다 내용을 새로 만드는 메뉴 (우클릭 순간의 창·메뉴 상태를 반영)
final class LiveMenu: NSMenu, NSMenuDelegate {
    private let build: (NSMenu) -> Void
    init(title: String = "", _ build: @escaping (NSMenu) -> Void) {
        self.build = build
        super.init(title: title)
        delegate = self
        autoenablesItems = false
    }
    required init(coder: NSCoder) { fatalError() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        build(menu)
    }
}

// MARK: - 손쉬운 사용 도우미

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attr(el, name) as? NSNumber)?.boolValue }
    static func int(_ el: AXUIElement, _ name: String) -> Int? { (attr(el, name) as? NSNumber)?.intValue }
    static func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static var trusted: Bool { AXIsProcessTrusted() }
    static func askTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func bringToFront(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.unhide()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    static func focus(window w: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        bringToFront(pid: pid)
    }

    /// 앱 메뉴 항목 누르기 (앱을 먼저 앞으로 가져와야 새 창 등이 제대로 뜸)
    static func press(_ item: AXUIElement, pid: pid_t) {
        bringToFront(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }
}

// MARK: - 메뉴 만들기

/// 실행 중인 앱의 Dock 스타일 메뉴 항목들을 m 에 채움
@MainActor
func fillAppMenu(_ m: NSMenu, pid: pid_t) {
    guard AX.trusted else {
        m.addItem(Item("창 목록 · 앱 메뉴를 보려면 ‘손쉬운 사용’ 권한 허용…") { AX.askTrust() })
        m.addItem(.separator())
        return
    }
    let app = AXUIElementCreateApplication(pid)

    // 1) 열린 창 목록 (지금 앞에 있는 창에 ✓, 최소화된 창은 ◇)
    let windows = (AX.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        .filter { (AX.str($0, kAXSubroleAttribute) ?? "") == (kAXStandardWindowSubrole as String) }
    let main = AX.element(app, kAXMainWindowAttribute)
    for w in windows {
        let title = AX.str(w, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? "(제목 없음)"
        let minimized = AX.bool(w, kAXMinimizedAttribute) == true
        let it = Item((minimized ? "◇ " : "") + title) { AX.focus(window: w, pid: pid) }
        if let main, CFEqual(main, w) { it.state = .on }
        m.addItem(it)
    }
    if !windows.isEmpty { m.addItem(.separator()) }

    // 2) 그 앱 메뉴 막대에서 "새 창" 같은 항목을 찾아 바로가기로
    let bar = AX.element(app, kAXMenuBarAttribute)
    let topMenus = bar.map { AX.children($0) } ?? []
    let wanted = ["새 창", "새로운 창", "새 윈도우", "새로운 윈도우", "New Window"]
    var quick: [AXUIElement] = []
    for top in topMenus.dropFirst() {          // 첫 번째는  메뉴
        for menu in AX.children(top) {
            for item in AX.children(menu) {
                guard let t = AX.str(item, kAXTitleAttribute), AX.bool(item, kAXEnabledAttribute) != false else { continue }
                if wanted.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) || t.hasPrefix("새 시크릿") || t.hasPrefix("새로운 시크릿") {
                    quick.append(item)
                }
            }
        }
        if !quick.isEmpty { break }
    }
    for item in quick {
        let t = AX.str(item, kAXTitleAttribute) ?? ""
        m.addItem(Item(t) { AX.press(item, pid: pid) })
    }
    if !quick.isEmpty { m.addItem(.separator()) }

    // 3) 앱의 메뉴 막대 전체 (파일·편집·보기·프로필 … 을 하위 메뉴로)
    let names = topMenus.dropFirst().compactMap { top -> (String, AXUIElement)? in
        guard let t = AX.str(top, kAXTitleAttribute), !t.isEmpty, let menu = AX.children(top).first else { return nil }
        return (t, menu)
    }
    if !names.isEmpty {
        let menus = NSMenuItem(title: "앱 메뉴", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (t, menu) in names {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.submenu = LiveMenu { mirror(menu, into: $0, pid: pid, depth: 0) }
            sub.addItem(it)
        }
        menus.submenu = sub
        m.addItem(menus)
        m.addItem(.separator())
    }
}

/// 앱의 메뉴(AXMenu)를 그대로 따라 그리기. 누르면 원래 앱의 그 메뉴를 누른 것과 같음
@MainActor
func mirror(_ axMenu: AXUIElement, into m: NSMenu, pid: pid_t, depth: Int) {
    var lastWasSeparator = true
    for item in AX.children(axMenu) {
        let title = AX.str(item, kAXTitleAttribute) ?? ""
        if title.isEmpty {
            if !lastWasSeparator { m.addItem(.separator()); lastWasSeparator = true }
            continue
        }
        lastWasSeparator = false
        let enabled = AX.bool(item, kAXEnabledAttribute) ?? true
        if let sub = AX.children(item).first, depth < 4, !AX.children(sub).isEmpty {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = LiveMenu { mirror(sub, into: $0, pid: pid, depth: depth + 1) }
            it.isEnabled = enabled
            m.addItem(it)
            continue
        }
        let it = Item(title) { AX.press(item, pid: pid) }
        it.isEnabled = enabled
        if let mark = AX.str(item, kAXMenuItemMarkCharAttribute), !mark.isEmpty { it.state = .on }
        // 단축키 표시 (이 메뉴 안에서만 보이는 안내용)
        if let ch = AX.str(item, kAXMenuItemCmdCharAttribute), !ch.isEmpty, ch.count == 1 {
            it.keyEquivalent = ch.lowercased()
            let mods = AX.int(item, kAXMenuItemCmdModifiersAttribute) ?? 0
            var flags: NSEvent.ModifierFlags = []
            if mods & 8 == 0 { flags.insert(.command) }
            if mods & 1 != 0 { flags.insert(.shift) }
            if mods & 2 != 0 { flags.insert(.option) }
            if mods & 4 != 0 { flags.insert(.control) }
            it.keyEquivalentModifierMask = flags
        }
        m.addItem(it)
    }
    if m.items.last?.isSeparatorItem == true { m.removeItem(at: m.items.count - 1) }
}

// MARK: - 열린 창 한꺼번에 정리 (도구함 자신은 빼고)

enum BulkWindows {
    enum Kind { case close, minimize, quit }

    /// 도구함을 뺀, 화면에 창이 있는 일반 앱들
    static func apps(includeFinder: Bool) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && (includeFinder || $0.bundleIdentifier != "com.apple.finder")
        }
    }

    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        return (AX.attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .filter { (AX.str($0, kAXSubroleAttribute) ?? "") == (kAXStandardWindowSubrole as String) }
    }

    /// 몇 개의 창/앱이 대상인지 (확인 창에 보여 주려고)
    @MainActor
    static func count(_ kind: Kind) -> Int {
        switch kind {
        case .quit: return apps(includeFinder: false).count
        case .close, .minimize: return apps(includeFinder: true).reduce(0) { $0 + windows($1).count }
        }
    }

    @MainActor
    static func run(_ kind: Kind) {
        switch kind {
        case .quit:
            apps(includeFinder: false).forEach { $0.terminate() }
        case .close:
            for app in apps(includeFinder: true) {
                for w in windows(app) {
                    if let b = AX.element(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
                }
            }
        case .minimize:
            for app in apps(includeFinder: true) {
                for w in windows(app) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            }
        }
    }

    /// 확인을 받고 실행
    @MainActor
    static func confirmAndRun(_ kind: Kind) {
        if kind != .quit && !AX.trusted {
            AX.askTrust()
            return
        }
        let n = count(kind)
        guard n > 0 else {
            let a = NSAlert(); a.messageText = kind == .quit ? "종료할 앱이 없어요." : "열린 창이 없어요."; a.runModal()
            return
        }
        if kind != .minimize {
            let a = NSAlert()
            a.messageText = kind == .quit ? "앱 \(n)개를 모두 종료할까요?" : "열린 창 \(n)개를 모두 닫을까요?"
            a.informativeText = kind == .quit
                ? "도구함과 Finder 는 빼고 종료해요. 저장 안 한 문서가 있으면 각 앱이 저장할지 물어봐요."
                : "앱은 켜 둔 채 창만 닫아요. 저장 안 한 문서가 있으면 각 앱이 저장할지 물어봐요."
            a.addButton(withTitle: kind == .quit ? "모두 종료" : "모두 닫기")
            a.addButton(withTitle: "취소")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        run(kind)
    }

    @MainActor
    static func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(Item("열린 창 모두 닫기") { confirmAndRun(.close) })
        m.addItem(Item("열린 창 모두 최소화") { confirmAndRun(.minimize) })
        m.addItem(.separator())
        m.addItem(Item("앱 모두 종료 (도구함·Finder 제외)") { confirmAndRun(.quit) })
        return m
    }
}
