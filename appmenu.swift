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
