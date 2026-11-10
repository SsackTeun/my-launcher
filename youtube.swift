// 영상 창 (YouTube · Netflix): 도구함 안의 브라우저 창(WKWebView)에서 사이트를 열고,
// [PIP] 버튼을 누르면 보던 영상을 항상 위에 뜨는 작은 창으로 띄움.
// 사이트마다 다른 것(영상 요소 · 플레이어 조작 · 저장 이름)은 site 로 나눔
import Cocoa
import WebKit

/// 페이지 → 앱 메시지 (WKUserContentController 가 대상을 강하게 잡아서 약한 참조로 감쌈)
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: VideoWindow?
    init(_ t: VideoWindow) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? String ?? ""
        MainActor.assumeIsolated { target?.received(body) }
    }
}

/// 작은 창에서는 페이지가 마우스 움직임을 못 받게 (페이지가 커서를 화살표로 되돌려 버려서
/// 가장자리 크기 조절 커서가 안 바뀌던 문제)
final class YTWebView: WKWebView {
    var mouseOff = false
    override func mouseMoved(with e: NSEvent) { if !mouseOff { super.mouseMoved(with: e) } }
    override func mouseEntered(with e: NSEvent) { if !mouseOff { super.mouseEntered(with: e) } }
    override func mouseExited(with e: NSEvent) { if !mouseOff { super.mouseExited(with: e) } }
    override func cursorUpdate(with e: NSEvent) { if !mouseOff { super.cursorUpdate(with: e) } }
}

/// 예전 이름 (도구함 다른 곳에서 YouTube 창을 이 이름으로 부름)
typealias YouTubeWindow = VideoWindow

@MainActor
final class VideoWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, NSTextFieldDelegate {
    enum Site { case youtube, netflix }
    let site: Site
    static let shared = VideoWindow(site: .youtube)
    static let netflix = VideoWindow(site: .netflix)
    init(site: Site) { self.site = site; super.init() }

    var name: String { site == .youtube ? "YouTube" : "Netflix" }
    var home: URL { URL(string: site == .youtube ? "https://www.youtube.com/" : "https://www.netflix.com/browse")! }
    /// 설정 이름 앞머리 (YouTube 는 예전 그대로 yt…)
    private func k(_ s: String) -> String { (site == .youtube ? "yt" : "nf") + s }

    private var webView: YTWebView?
    private var window: NSWindow?
    private var address: NSTextField!
    private var pipButton: ActionButton!
    private var qualityButton: ActionButton!
    private var autoCheck: NSButton!

    /// 옵션: 영상을 누르면 바로 작은 창(PIP)으로
    var autoPiP: Bool {
        get { UserDefaults.standard.bool(forKey: k("AutoPiP")) }
        set { UserDefaults.standard.set(newValue, forKey: k("AutoPiP")); autoCheck?.state = newValue ? .on : .off; onChange?() }
    }
    /// 이미 자동으로 작은 창에 띄운 영상 (큰 창으로 돌아온 뒤 같은 영상으로 또 들어가지 않게)
    private var autoDoneFor: String?

    /// 주소에서 영상 ID (YouTube watch?v=… · shorts/… , Netflix watch/숫자)
    static func videoID(_ u: URL?) -> String? {
        guard let u, let c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        if u.path.hasPrefix("/watch/") { return String(u.path.dropFirst("/watch/".count)) }
        if u.path == "/watch" { return c.queryItems?.first { $0.name == "v" }?.value }
        if u.path.hasPrefix("/shorts/") { return String(u.path.dropFirst("/shorts/".count)) }
        return nil
    }
    private var backButton: ActionButton!
    private var forwardButton: ActionButton!
    private var urlWatch: NSKeyValueObservation?
    private var mainContent: NSView?
    private let barH: CGFloat = 36
    /// 도구함이 직접 만든 작은 창 (마음대로 옮기고 크기 조절)
    private var mini: NSPanel?
    private var miniOverlay: MiniOverlay?
    private(set) var inMini = false
    /// 지금 화면 속 화면으로 보고 있는지
    private(set) var inPiP = false
    /// 상태가 바뀌면 (메뉴 다시 그리기 등)
    var onChange: (() -> Void)?

    var isOpen: Bool { webView != nil }

    // PIP 시작 · 끝을 알려 주는 스크립트 (영상 요소에서 생기는 이벤트를 문서에서 가로챔)
    private static let watchJS = """
    (() => {
      const send = on => { try { webkit.messageHandlers.yt.postMessage(on ? 'pip:1' : 'pip:0'); } catch(e) {} };
      document.addEventListener('enterpictureinpicture', () => send(true), true);
      document.addEventListener('leavepictureinpicture', () => send(false), true);
      // 영상 크기(비율)를 알게 되거나 바뀌면 알려 줌 → 작은 창 비율 맞춤
      const ratio = e => { const v = e.target;
        if (v && v.tagName === 'VIDEO' && v.videoWidth && v.videoHeight && (v.classList.contains('html5-main-video') || v.closest('#shorts-player') || v.closest('.watch-video')))
          try { webkit.messageHandlers.yt.postMessage('ar:' + (v.videoWidth / v.videoHeight)); } catch(_) {} };
      document.addEventListener('loadedmetadata', ratio, true);
      document.addEventListener('resize', ratio, true);
      // 쇼츠가 끝났는지: 쇼츠는 끝나면 처음으로 되감기며 반복되므로 '끝 근처 → 처음' 을 끝으로 봄
      let lastT = 0;
      document.addEventListener('timeupdate', e => { const v = e.target;
        if (!v || v.tagName !== 'VIDEO' || !v.closest('#shorts-player')) return;
        const d = v.duration;
        if (isFinite(d) && d > 1.5 && lastT > d - 1.2 && v.currentTime < 0.8) { try { webkit.messageHandlers.yt.postMessage('shortEnd'); } catch(_) {} }
        lastT = v.currentTime; }, true);
      document.addEventListener('ended', e => { const v = e.target;
        if (v && v.closest && v.closest('#shorts-player')) { try { webkit.messageHandlers.yt.postMessage('shortEnd'); } catch(_) {} } }, true);
      document.addEventListener('webkitpresentationmodechanged',
        e => send(e.target && e.target.webkitPresentationMode === 'picture-in-picture'), true);
    })();
    """

    // 보이는 영상을 PIP 로 (이미 PIP 면 원래대로). 결과: on / off / novideo / err:…
    private static let toggleJS = """
    const vids = [...document.querySelectorAll('video')];
    const v = document.querySelector('#movie_player video')
           || vids.find(x => !x.paused) || vids.find(x => x.readyState > 0) || vids[0];
    if (!v) return 'novideo';
    try {
      if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return 'off'; }
      if (v.webkitPresentationMode === 'picture-in-picture') { v.webkitSetPresentationMode('inline'); return 'off'; }
      v.disablePictureInPicture = false;
      if (v.paused) { try { await v.play(); } catch(e) {} }
      if (v.requestPictureInPicture) { await v.requestPictureInPicture(); return 'on'; }
      v.webkitSetPresentationMode('picture-in-picture'); return 'on';
    } catch (e) {
      try { v.webkitSetPresentationMode('picture-in-picture'); return 'on'; } catch (e2) { return 'err:' + (e2.message || e.message); }
    }
    """

    // MARK: 창

    func show(_ url: URL? = nil) {
        if webView == nil { build() }
        if inMini { exitMini(showMain: false) }
        if let url { webView?.load(URLRequest(url: url)) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                     // 로그인 상태(쿠키) 유지
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.isElementFullscreenEnabled = true
        // macOS 의 PIP 허용 (공개 설정이 없어서, 있으면 켬)
        let pipSel = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if cfg.preferences.responds(to: pipSel) { cfg.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback") }
        let uc = WKUserContentController()
        uc.add(WeakHandler(self), name: "yt")
        uc.addUserScript(WKUserScript(source: Self.watchJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = uc

        let wv = YTWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = YTMusic.userAgent
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        webView = wv

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wv.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - barH)
        wv.autoresizingMask = [.width, .height]
        content.addSubview(wv)
        mainContent = content

        let bar = NSView(frame: NSRect(x: 0, y: content.bounds.height - barH, width: content.bounds.width, height: barH))
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)

        func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> ActionButton {
            let b = ActionButton(title: "", symbol: symbol) { _ in action() }
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            b.frame.size = NSSize(width: 26, height: 26)
            return b
        }
        backButton = button("chevron.left", "뒤로") { [unowned self] in webView?.goBack() }
        forwardButton = button("chevron.right", "앞으로") { [unowned self] in webView?.goForward() }
        let homeB = button("house", "\(name) 홈") { [unowned self] in webView?.load(URLRequest(url: home)) }
        let reload = button("arrow.clockwise", "새로 고침") { [unowned self] in webView?.reload() }
        var x: CGFloat = 8
        for b in [backButton!, forwardButton!, homeB, reload] {
            b.setFrameOrigin(NSPoint(x: x, y: (barH - 26) / 2))
            bar.addSubview(b)
            x += 28
        }

        // 오른쪽: [PIP] 버튼 (글자 + 아이콘, 눈에 잘 띄게)
        pipButton = ActionButton(title: " PIP", symbol: "pip.enter") { [unowned self] _ in enterMini() }
        pipButton.bezelStyle = .rounded
        pipButton.controlSize = .regular
        pipButton.imagePosition = .imageLeading
        pipButton.toolTip = "보던 영상을 항상 위에 뜨는 작은 창으로 (끌어서 옮기고, 가장자리로 크기 조절)"
        pipButton.sizeToFit()
        pipButton.frame.size.width += 8
        pipButton.setFrameOrigin(NSPoint(x: bar.bounds.width - pipButton.frame.width - 8,
                                         y: (barH - pipButton.frame.height) / 2))
        pipButton.autoresizingMask = [.minXMargin]
        bar.addSubview(pipButton)

        // [화질] 버튼: 누르면 화질 고르기 메뉴
        qualityButton = ActionButton(title: "", symbol: "slider.horizontal.3") { [unowned self] b in showQualityMenu(from: b) }
        qualityButton.isBordered = false
        qualityButton.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        qualityButton.contentTintColor = .secondaryLabelColor
        qualityButton.toolTip = "화질 · 재생 옵션"
        qualityButton.frame.size = NSSize(width: 26, height: 26)
        qualityButton.autoresizingMask = [.minXMargin]
        bar.addSubview(qualityButton)

        // [☐ 자동 PIP] 체크: 영상을 누르면 바로 작은 창으로
        autoCheck = NSButton(checkboxWithTitle: "자동 PIP", target: self, action: #selector(autoChecked))
        autoCheck.controlSize = .small
        autoCheck.font = .systemFont(ofSize: 11)
        autoCheck.sizeToFit()
        autoCheck.state = autoPiP ? .on : .off
        autoCheck.toolTip = "켜면 영상을 누르자마자 항상 위에 뜨는 작은 창으로 봐요"
        autoCheck.autoresizingMask = [.minXMargin]
        bar.addSubview(autoCheck)

        // 가운데: 주소 / 검색 칸 (링크를 붙여 넣거나 검색어 입력 후 ⏎)
        address = NSTextField(frame: NSRect(x: x + 6, y: (barH - 24) / 2,
                                            width: pipButton.frame.minX - x - 120, height: 24))
        address.autoresizingMask = [.width]
        address.placeholderString = "\(name) 링크 붙여 넣기 또는 검색"
        address.bezelStyle = .roundedBezel
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.delegate = self
        address.target = self
        address.action = #selector(go)
        bar.addSubview(address)

        let line = NSBox(frame: NSRect(x: 0, y: 0, width: bar.bounds.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]
        bar.addSubview(line)

        let w = NSWindow(contentRect: content.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = name
        w.contentView = content
        w.contentMinSize = NSSize(width: 480, height: 320)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("\(name)VideoWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(name)VideoWindow") == nil { w.center() }
        window = w

        urlWatch = wv.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncBar()
                // 작은 창에서 다른 영상 · 쇼츠로 넘어가면 그 플레이어로 다시 맞춤
                if self.inMini {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, self.inMini else { return }
                        self.applyMiniCSS(true) { [weak self] ar in if ar > 0 { self?.setAspect(ar) } }
                    }
                }
            }
        }
        let start = resumeURL()
        autoDoneFor = Self.videoID(start)       // 이어 보기로 연 영상은 자동 PIP 안 함 (누른 게 아니라서)
        wv.load(URLRequest(url: start ?? home))     // 마지막에 보던 영상 · 위치부터
        saveBlockedUntil = Date().addingTimeInterval(8)   // 첫 영상이 저장값으로 맞춰지기 전엔 저장 안 함
        startStateWatch(true)
        syncBar()
        onChange?()
    }

    /// 창을 닫으면: PIP 로 보는 중이면 숨기기만, 아니면 영상 멈추고 숨기기 (다음에 열 때 그대로)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !inPiP { webView?.pauseAllMediaPlayback() }
        sender.orderOut(nil)
        return false
    }

    /// 완전히 끄기 (메모리 정리)
    func quit() {
        if inPiP { togglePiP() }
        if inMini { exitMini(showMain: false) }
        webView?.pauseAllMediaPlayback()
        startStateWatch(false)
        window?.orderOut(nil)
        urlWatch = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        webView = nil
        window = nil
        inPiP = false
        onChange?()
    }

    // MARK: PIP

    func togglePiP() {
        guard let wv = webView else { show(); return }
        wv.callAsyncJavaScript(Self.toggleJS, arguments: [:], in: nil, in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let r = (try? result.get()) as? String ?? "err"
                if UserDefaults.standard.bool(forKey: "ytDebug") {
                    try? ("pip=" + r + "\n").write(toFile: NSHomeDirectory() + "/MyLauncher/yt-pip.txt",
                                                    atomically: true, encoding: .utf8)
                }
                switch r {
                case "on": self.setPiP(true)
                case "off": self.setPiP(false)
                case "novideo": self.tell("먼저 영상을 하나 열어 주세요.")
                default: self.tell("PIP 를 켜지 못했어요. 영상을 한 번 재생한 뒤 다시 눌러 주세요.")
                }
            }
        }
    }

    func received(_ body: String) {
        if body == "pip:1" { setPiP(true) } else if body == "pip:0" { setPiP(false) }
        else if body == "shortEnd" { shortEnded() }
        else if body.hasPrefix("ar:"), let r = Double(body.dropFirst(3)) {
            if inMini { setAspect(r) }
            // 새 영상(광고 → 본편 포함)이 시작될 때마다 최고 화질로
            if site == .youtube && bestQuality { applyBestSoon() }
            applySavedSoon()
            // 자동 PIP: 새로 누른 영상이 재생 준비되면 작은 창으로
            if autoPiP, !inMini, let id = Self.videoID(webView?.url), id != autoDoneFor {
                autoDoneFor = id
                enterMini()
            }
        }
    }

    private func setPiP(_ on: Bool) {
        guard inPiP != on else { return }
        inPiP = on
        syncBar()
        onChange?()
    }

    private func tell(_ text: String) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = text
        a.beginSheetModal(for: window)
    }

    // MARK: 주소 칸

    @objc private func go() {
        let s = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let wv = webView else { return }
        if let url = Self.url(from: s) {
            wv.load(URLRequest(url: url))
        } else {
            var c = URLComponents(string: site == .youtube ? "https://www.youtube.com/results" : "https://www.netflix.com/search")!
            c.queryItems = [URLQueryItem(name: site == .youtube ? "search_query" : "q", value: s)]
            if let u = c.url { wv.load(URLRequest(url: u)) }
        }
        window?.makeFirstResponder(wv)
    }

    /// 링크처럼 보이면 URL 로 (youtu.be/…, youtube.com/…, http…)
    static func url(from s: String) -> URL? {
        if s.contains(" ") { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("youtu.be/") || s.hasPrefix("youtube.com/") || s.hasPrefix("www.youtube.com/")
            || s.hasPrefix("m.youtube.com/") { return URL(string: "https://" + s) }
        return nil
    }

    /// 클립보드에 YouTube 링크가 있으면
    static func clipboardLink() -> URL? {
        guard let s = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let u = url(from: s), let h = u.host?.lowercased(),
              h.hasSuffix("youtube.com") || h == "youtu.be" else { return nil }
        return u
    }

    private func syncBar() {
        guard let wv = webView else { return }
        if window?.firstResponder !== address.currentEditor() {
            address.stringValue = wv.url?.absoluteString ?? ""
        }
        backButton.isEnabled = wv.canGoBack
        forwardButton.isEnabled = wv.canGoForward
        pipButton.title = " PIP"
        pipButton.image = NSImage(systemSymbolName: "pip.enter", accessibilityDescription: nil)
        pipButton.sizeToFit()
        pipButton.frame.size.width += 8
        if let bar = pipButton.superview {
            pipButton.setFrameOrigin(NSPoint(x: bar.bounds.width - pipButton.frame.width - 8,
                                             y: (bar.bounds.height - pipButton.frame.height) / 2))
            qualityButton.setFrameOrigin(NSPoint(x: pipButton.frame.minX - 30, y: (bar.bounds.height - 26) / 2))
            autoCheck.setFrameOrigin(NSPoint(x: qualityButton.frame.minX - autoCheck.frame.width - 6,
                                             y: (bar.bounds.height - autoCheck.frame.height) / 2))
            address.frame.size.width = autoCheck.frame.minX - address.frame.minX - 8
        }
        window?.title = (wv.title?.isEmpty == false) ? wv.title! : name
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncBar()
        if inMini { applyMiniCSS(true) { _ in } }   // 새로 고침돼도 작은 창 모양 유지
    }

    // 새 창으로 여는 링크는 같은 창에서
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    // MARK: 작은 창 (도구함의 PIP)

    // 영상만 창 전체에 꽉 차게 (나머지는 숨김). 결과: 영상 가로/세로 비율, 영상이 없으면 0
    private var miniCSS: String { site == .youtube ? Self.ytMiniCSS : Self.nfMiniCSS }

    /// Netflix: 영상과 그 위 상자들에 표시(data-mini-v / data-mini-a)를 달아서 같은 방식으로 꽉 채움
    private static let nfMiniCSS = """
    html.ytmini, html.ytmini body { overflow: hidden !important; background: #000 !important; }
    html.ytmini body * { visibility: hidden !important; }
    html.ytmini video[data-mini-v] {
      visibility: visible !important; position: fixed !important; inset: 0 !important;
      left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
      object-fit: contain !important; z-index: 2147483647 !important; background: #000 !important; transform: none !important; }
    html.ytmini [data-mini-a] { overflow: visible !important; clip-path: none !important; transform: none !important;
      contain: none !important; filter: none !important; will-change: auto !important; }
    /* 자막: Netflix 는 영상 위에 따로 글자 층(.player-timedtext)을 얹음 → 그 층은 보이게, 영상보다 위에 */
    html.ytmini .player-timedtext { visibility: visible !important; position: fixed !important; inset: 0 !important;
      z-index: 2147483647 !important; pointer-events: none !important; }
    html.ytmini .player-timedtext * { visibility: visible !important; }
    """

    private static let ytMiniCSS = """
    html.ytmini, html.ytmini body { overflow: hidden !important; background: #000 !important; }
    html.ytmini body * { visibility: hidden !important; }
    /* 일반 영상은 #movie_player, 쇼츠는 #shorts-player (쇼츠 페이지에도 빈 #movie_player 가 숨어 있어서 나눔) */
    html.ytmini:not(.ytmini-s) #movie_player video.html5-main-video, html.ytmini.ytmini-s #shorts-player video {
      visibility: visible !important; position: fixed !important; inset: 0 !important;
      left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
      object-fit: contain !important; z-index: 2147483647 !important; background: #000 !important; transform: none !important; }
    /* 영상을 감싼 플레이어 상자도 창 전체로 (안 그러면 그 상자 크기로 잘려서 위아래가 검게 보임) */
    html.ytmini:not(.ytmini-s) #movie_player, html.ytmini.ytmini-s #shorts-player {
      position: fixed !important; inset: 0 !important; left: 0 !important; top: 0 !important;
      width: 100vw !important; height: 100vh !important; z-index: 2147483646 !important; background: #000 !important; }
    html.ytmini:not(.ytmini-s) body *:has(#movie_player), html.ytmini.ytmini-s body *:has(#shorts-player),
    html.ytmini:not(.ytmini-s) #movie_player, html.ytmini.ytmini-s #shorts-player, html.ytmini .html5-video-container {
      overflow: visible !important; clip-path: none !important; transform: none !important; contain: none !important;
      filter: none !important; will-change: auto !important; }
    /* 자막: YouTube 도 영상 위 글자 층(.ytp-caption-window-container) → 보이게, 영상보다 위에 */
    html.ytmini .ytp-caption-window-container { visibility: visible !important; z-index: 2147483647 !important;
      position: absolute !important; inset: 0 !important; pointer-events: none !important; }
    html.ytmini .ytp-caption-window-container * { visibility: visible !important; }
    """

    private func applyMiniCSS(_ on: Bool, _ done: @escaping (Double) -> Void) {
        let js = """
        const css = \(Self.jsString(miniCSS));
        let st = document.getElementById('__ytmini');
        if (\(on) && !st) { st = document.createElement('style'); st.id = '__ytmini'; st.textContent = css; document.documentElement.appendChild(st); }
        if (!\(on) && st) st.remove();
        document.documentElement.classList.toggle('ytmini', \(on));
        document.documentElement.classList.toggle('ytmini-s', \(on) && location.pathname.startsWith('/shorts'));
        window.dispatchEvent(new Event('resize'));
        const v = \(jsV) || [...document.querySelectorAll('video')].find(x => x.readyState > 0);
        document.querySelectorAll('[data-mini-v],[data-mini-a]').forEach(e => { e.removeAttribute('data-mini-v'); e.removeAttribute('data-mini-a'); });
        if (\(on) && v) { v.setAttribute('data-mini-v', ''); for (let e = v.parentElement; e && e !== document.body; e = e.parentElement) e.setAttribute('data-mini-a', ''); }
        if (!v) return 0;
        return v.videoWidth && v.videoHeight ? v.videoWidth / v.videoHeight : -1;
        """
        webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            let ar = (try? r.get()) as? Double ?? Double((try? r.get()) as? Int ?? 0)
            MainActor.assumeIsolated { done(ar) }
        }
    }

    private static func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let a = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(a.dropFirst().dropLast())
    }

    func toggleMini() { inMini ? exitMini(showMain: true) : enterMini() }

    func enterMini() {
        guard let wv = webView, !inMini else { if webView == nil { show() }; return }
        if inPiP { togglePiP() }
        applyMiniCSS(true) { [weak self] ar in
            guard let self else { return }
            guard ar != 0 else {      // 0 = 영상 없음, -1 = 아직 크기 모름 (일단 16:9)
                self.applyMiniCSS(false) { _ in }
                self.tell("먼저 영상을 하나 열어 주세요.")
                return
            }
            let p = self.mini ?? self.makeMini()
            wv.removeFromSuperview()
            wv.frame = p.contentView!.bounds
            wv.autoresizingMask = [.width, .height]
            p.contentView!.addSubview(wv, positioned: .below, relativeTo: self.miniOverlay)
            self.inMini = true
            wv.mouseOff = true
            self.window?.orderOut(nil)
            // 영상 크기를 아직 모르면(-1) 일단 16:9, 알게 되면 'ar:' 메시지로 다시 맞춤
            self.setAspect(ar > 0 ? ar : 16.0 / 9.0)
            p.orderFrontRegardless()
            OnScreen.fix(p, animate: false)     // 저장된 위치가 빠진 모니터에 있었으면
            self.startTimePoll(true)
            self.onChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.logMini() }
        }
    }

    /// 작은 창을 영상 비율로 맞춤 (폭은 그대로, 위쪽 모서리 고정). 비율을 잠그진 않음 —
    /// 사용자가 다른 모양으로 늘리면 영상이 창을 꽉 채우고 넘치는 가장자리만 잘림
    private func setAspect(_ ar: Double) {
        guard let p = mini, ar > 0.2, ar < 6 else { return }
        miniOverlay?.aspect = CGFloat(ar)
        var f = p.frame
        let top = f.maxY
        if (ar < 1) != (f.width < f.height) {
            // 가로 ↔ 세로가 바뀌면 (일반 영상 ↔ 쇼츠) 긴 변 길이를 유지
            let long = max(f.width, f.height)
            f.size = ar < 1 ? NSSize(width: (long * ar).rounded(), height: long) : NSSize(width: long, height: (long / ar).rounded())
        } else {
            f.size.height = (f.width / ar).rounded()
        }
        if f.width < p.minSize.width { f.size = NSSize(width: p.minSize.width, height: (p.minSize.width / ar).rounded()) }
        f.origin.y = top - f.height
        if abs(f.height - p.frame.height) > 1 || abs(f.width - p.frame.width) > 1 {
            p.setFrame(OnScreen.clamp(f), display: true, animate: false)
        }
    }

    /// 진단: 작은 창 · 영상 크기를 파일로 (검정 여백 원인 확인용)
    private func logMini() {
        guard inMini, let p = mini, let wv = webView else { return }
        let js = """
        (() => { const v = \(jsV);
          if (!v) return 'novideo'; const r = v.getBoundingClientRect();
          return JSON.stringify({rect: [r.x, r.y, r.width, r.height], inner: [innerWidth, innerHeight], video: [v.videoWidth, v.videoHeight], url: location.href}); })()
        """
        wv.evaluateJavaScript(js) { r, _ in
            let line = "panel=\(p.frame.size) web=\(wv.frame) js=\(r ?? "nil")\n"
            try? line.write(toFile: NSHomeDirectory() + "/MyLauncher/yt-mini.txt", atomically: true, encoding: .utf8)
        }
    }

    /// 작은 창 → 원래 창 (showMain: false 면 원래 창은 숨긴 채로)
    func exitMini(showMain: Bool) {
        guard inMini, let wv = webView, let content = mainContent else { return }
        inMini = false
        wv.mouseOff = false
        startTimePoll(false)
        applyMiniCSS(false) { _ in }
        wv.removeFromSuperview()
        wv.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - barH)
        wv.autoresizingMask = [.width, .height]
        content.addSubview(wv, positioned: .below, relativeTo: nil)
        mini?.orderOut(nil)
        if showMain {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        onChange?()
    }

    private func makeMini() -> NSPanel {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 480, height: 270)
        let p = NSPanel(contentRect: NSRect(x: vf.maxX - size.width - 20, y: vf.minY + 20, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel],     // 제목줄 없이 영상만 (크기 조절은 MiniOverlay 가 직접)
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.contentView!.wantsLayer = true
        p.contentView!.layer?.cornerRadius = 10
        p.contentView!.layer?.masksToBounds = true
        p.contentView!.layer?.backgroundColor = NSColor.black.cgColor
        p.minSize = NSSize(width: 200, height: 112)
        p.setFrameAutosaveName(site == .youtube ? "YouTubeMiniWindow" : "\(name)MiniWindow")
        let o = MiniOverlay(frame: p.contentView!.bounds)
        o.autoresizingMask = [.width, .height]
        o.accent = site == .youtube ? NSColor(red: 1, green: 0, blue: 0.2, alpha: 1)       // YouTube 빨강
                                    : NSColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)  // Netflix 빨강
        o.onClick = { [unowned self] in playPause() }
        o.onDoubleClick = { [unowned self] in exitMini(showMain: true) }
        o.onSeekTo = { [unowned self] t in seek(t) }
        o.onPlayPause = o.onClick
        o.onExpand = o.onDoubleClick
        o.onQuality = { [unowned self] v in showQualityMenu(from: v) }
        o.onVolume = { [unowned self] v in setVolume(v) }
        o.onMute = { [unowned self] in toggleMute() }
        o.onScrollStep = { [unowned self] down in shortsStep(down) }
        o.onClose = { [unowned self] in
            webView?.pauseAllMediaPlayback()
            exitMini(showMain: false)
        }
        p.contentView!.addSubview(o)
        miniOverlay = o
        mini = p
        return p
    }

    // 재생바용: 지금 시간 · 길이 · 멈춤 여부 (생방송이면 되감을 수 있는 범위)
    private var timeJS: String { site == .youtube ? Self.ytTimeJS : Self.nfTimeJS }
    private static let nfTimeJS = """
    (() => { const p = \(nfPlayer); const v = \(nfVideo); if (!v) return null;
      const t = p && p.getCurrentTime ? p.getCurrentTime() / 1000 : v.currentTime;
      const d = p && p.getDuration ? p.getDuration() / 1000 : (isFinite(v.duration) ? v.duration : 0);
      const paused = p && p.isPaused ? p.isPaused() : v.paused;
      const vol = (p && p.getVolume ? p.getVolume() : v.volume) * 100, muted = p && p.isMuted ? p.isMuted() : v.muted;
      return [t, 0, d, paused ? 1 : 0, 0, vol, muted ? 1 : 0]; })()
    """
    private static let ytTimeJS = """
    (() => { const v = (location.pathname.startsWith('/shorts') ? document.querySelector('#shorts-player video') : document.querySelector('#movie_player video.html5-main-video'));
      if (!v) return null;
      let s = 0, e = v.duration;
      if (!isFinite(e)) { const r = v.seekable; if (r && r.length) { s = r.start(0); e = r.end(r.length - 1); } else e = 0; }
      const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player'));
      const vol = mp && mp.getVolume ? mp.getVolume() : v.volume * 100, muted = mp && mp.isMuted ? mp.isMuted() : v.muted;
      return [v.currentTime, s, e, v.paused ? 1 : 0, isFinite(v.duration) ? 0 : 1, vol, muted ? 1 : 0]; })()
    """

    private var timeTimer: Timer?
    private func startTimePoll(_ on: Bool) {
        timeTimer?.invalidate()
        timeTimer = nil
        guard on else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.inMini, let o = self.miniOverlay else { return }
                self.webView?.evaluateJavaScript(self.timeJS) { r, _ in
                    guard let a = r as? [NSNumber], a.count == 7 else { return }
                    MainActor.assumeIsolated {
                        o.update(time: a[0].doubleValue, start: a[1].doubleValue, end: a[2].doubleValue,
                                 paused: a[3].boolValue, live: a[4].boolValue, volume: a[5].doubleValue, muted: a[6].boolValue)
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timeTimer = t
    }

    // MARK: 마지막 상태 기억 (볼륨 · 음소거 · 재생 속도 · 보던 영상과 위치)

    private var keyVol: String { k("Volume") }
    private var keyMuted: String { k("Muted") }
    private var keyRate: String { k("Rate") }
    private var keyURL: String { k("LastURL") }
    private var keyTime: String { k("LastTime") }
    private var stateTimer: Timer?
    /// 새 영상이 막 시작된 직후엔 YouTube 기본값이 잠깐 보이므로 저장하지 않음
    private var saveBlockedUntil = Date.distantPast

    private var stateJS: String { site == .youtube ? Self.ytStateJS : Self.nfStateJS }
    private static let nfStateJS = """
    (() => { const p = \(nfPlayer); const v = \(nfVideo); if (!p || !v || !p.getVolume) return null;
      return JSON.stringify({ vol: p.getVolume() * 100, muted: p.isMuted(), t: p.getCurrentTime() / 1000,
        live: false, url: location.href, ad: false }); })()
    """
    private static let ytStateJS = """
    (() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player'));
      const v = (location.pathname.startsWith('/shorts') ? document.querySelector('#shorts-player video') : document.querySelector('#movie_player video.html5-main-video'));
      if (!mp || !mp.getVolume || !v) return null;
      return JSON.stringify({ vol: mp.getVolume(), muted: mp.isMuted(),
        rate: mp.getPlaybackRate ? mp.getPlaybackRate() : v.playbackRate, t: v.currentTime,
        live: !isFinite(v.duration), url: location.href, ad: !!document.querySelector('#movie_player.ad-showing') }); })()
    """

    private func startStateWatch(_ on: Bool) {
        stateTimer?.invalidate()
        stateTimer = nil
        guard on else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.saveState() } }
        RunLoop.main.add(t, forMode: .common)
        stateTimer = t
    }

    private func saveState() {
        webView?.evaluateJavaScript(stateJS) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let str = r as? String, let d = str.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["ad"] as? Bool != true else { return }
                let ud = UserDefaults.standard
                if Date() > self.saveBlockedUntil {
                    if let v = o["vol"] as? Double { ud.set(v, forKey: self.keyVol) }
                    if let m = o["muted"] as? Bool { ud.set(m, forKey: self.keyMuted) }
                    if let r = o["rate"] as? Double, r > 0 { ud.set(r, forKey: self.keyRate) }
                }
                if let u = o["url"] as? String, u.contains("/watch") || u.contains("/shorts/") {   // Netflix 도 /watch/숫자
                    ud.set(u, forKey: self.keyURL)
                    let live = o["live"] as? Bool ?? false
                    ud.set(live ? 0 : (o["t"] as? Double ?? 0), forKey: self.keyTime)
                }
            }
        }
    }

    /// 새 영상마다 저장해 둔 볼륨 · 음소거 · 속도로 맞춤
    private func applySavedSoon() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: keyVol) != nil else { return }
        let vol = Int(ud.double(forKey: keyVol).rounded())
        let muted = ud.bool(forKey: keyMuted)
        let rate = ud.object(forKey: keyRate) as? Double ?? 1
        saveBlockedUntil = Date().addingTimeInterval(5)
        let js = site == .netflix ? """
        (() => { const p = \(Self.nfPlayer); if (!p || !p.setVolume) return 0;
          p.setVolume(\(Double(vol) / 100)); if (p.setMuted) p.setMuted(\(muted)); return 1; })()
        """ : """
        (() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player')); if (!mp || !mp.setVolume) return 0;
          mp.setVolume(\(vol)); \(muted ? "mp.mute();" : "mp.unMute();")
          if (mp.setPlaybackRate && mp.getPlaybackRate && mp.getPlaybackRate() !== \(rate)) mp.setPlaybackRate(\(rate));
          return 1; })()
        """
        for t in [0.3, 1.5, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.webView?.evaluateJavaScript(js) }
        }
    }

    /// 마지막에 보던 영상 주소 (보던 위치 t= 붙여서)
    private func resumeURL() -> URL? {
        let ud = UserDefaults.standard
        guard let s = ud.string(forKey: keyURL), var c = URLComponents(string: s) else { return nil }
        let t = Int(ud.double(forKey: keyTime))
        if s.contains("/watch") {
            var items = (c.queryItems ?? []).filter { $0.name != "t" }
            if t > 5 { items.append(URLQueryItem(name: "t", value: site == .youtube ? "\(t)s" : "\(t)")) }
            c.queryItems = items
        }
        return c.url
    }

    /// 쇼츠: 작은 창에서 스크롤하면 다음 · 이전 쇼츠로.
    /// 작은 창 모양 그대로는 YouTube 가 '지금 쇼츠' 를 못 바꿔서, 잠깐 원래 페이지로 돌려 ↓ · ↑ 를 누르고
    /// 새 쇼츠가 열리면 다시 작은 창 모양으로. 그 사이엔 마지막 장면을 정지 화면으로 덮어 깜빡임을 숨김
    private var shortsStepping = false
    private func shortsStep(_ down: Bool) {
        guard let wv = webView, let p = mini, wv.url?.path.hasPrefix("/shorts") == true, !shortsStepping else { return }
        shortsStepping = true
        let before = wv.url?.path
        wv.takeSnapshot(with: nil) { [weak self] img, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var cover: NSImageView?
                if let img, let cv = p.contentView {
                    let iv = NSImageView(frame: cv.bounds)
                    iv.image = img
                    iv.imageScaling = .scaleAxesIndependently
                    iv.autoresizingMask = [.width, .height]
                    cv.addSubview(iv, positioned: .above, relativeTo: wv)
                    cover = iv
                }
                let dir = down ? "down" : "up"
                wv.evaluateJavaScript("""
                (() => { document.documentElement.classList.remove('ytmini', 'ytmini-s');
                  setTimeout(() => { const b = document.querySelector('#navigation-button-\(dir) button');
                    if (b) b.click(); else document.dispatchEvent(new KeyboardEvent('keydown',
                      {bubbles: true, key: '\(down ? "ArrowDown" : "ArrowUp")', keyCode: \(down ? 40 : 38)})); }, 60); })()
                """)
                // 주소가 바뀔 때까지(최대 4초) 기다렸다가 다시 작은 창 모양으로
                var tries = 0
                func check() {
                    tries += 1
                    let changed = wv.url?.path != before
                    if changed || tries > 16 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + (changed ? 0.35 : 0)) { [weak self] in
                            guard let self else { return }
                            self.applyMiniCSS(true) { [weak self] ar in
                                if ar > 0 { self?.setAspect(ar) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; cover?.animator().alphaValue = 0 },
                                                                          completionHandler: { cover?.removeFromSuperview() })
                                    self?.shortsStepping = false
                                }
                            }
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
            }
        }
    }

    // 작은 창의 볼륨 조절
    private func setVolume(_ v: Double) {
        let n = Int(v.rounded())
        if site == .netflix {
            webView?.evaluateJavaScript("(() => { const p = \(Self.nfPlayer); if (p && p.setVolume) { p.setVolume(\(Double(n) / 100)); if (\(n) > 0 && p.isMuted && p.isMuted()) p.setMuted(false); } })()")
            return
        }
        webView?.evaluateJavaScript("(() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player')); if (mp && mp.setVolume) { mp.setVolume(\(n)); if (\(n) > 0 && mp.isMuted()) mp.unMute(); } })()")
    }
    private func toggleMute() {
        if site == .netflix {
            webView?.evaluateJavaScript("(() => { const p = \(Self.nfPlayer); if (p && p.setMuted) p.setMuted(!p.isMuted()); })()")
            return
        }
        webView?.evaluateJavaScript("(() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player')); if (mp && mp.isMuted) { mp.isMuted() ? mp.unMute() : mp.mute(); } })()")
    }

    @objc private func autoChecked() { autoPiP = autoCheck.state == .on }

    // MARK: 쇼츠 자동 넘김

    /// 옵션: 쇼츠가 끝나면 다음 쇼츠로
    var autoNextShorts: Bool {
        get { UserDefaults.standard.bool(forKey: "ytAutoNextShorts") }
        set { UserDefaults.standard.set(newValue, forKey: "ytAutoNextShorts"); onChange?() }
    }
    private var lastShortEnd = Date.distantPast

    private func shortEnded() {
        guard autoNextShorts, webView?.url?.path.hasPrefix("/shorts") == true,
              Date().timeIntervalSince(lastShortEnd) > 2 else { return }
        lastShortEnd = Date()
        if inMini {
            shortsStep(true)
        } else {
            webView?.evaluateJavaScript("(() => { const b = document.querySelector('#navigation-button-down button'); if (b) b.click(); })()")
        }
    }

    // MARK: 화질

    /// 항상 최고 화질 (기본 켜짐: YouTube 는 이 창에서 보통 480p 로 시작함)
    var bestQuality: Bool {
        get { UserDefaults.standard.object(forKey: "ytBestQuality") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ytBestQuality"); if newValue { applyBestSoon() } }
    }

    private static let qualityName: [String: String] = [
        "highres": "4320p (8K)", "hd2160": "2160p (4K)", "hd1440": "1440p", "hd1080": "1080p", "hd720": "720p",
        "large": "480p", "medium": "360p", "small": "240p", "tiny": "144p", "auto": "자동",
    ]

    private static let qualityInfoJS = """
    (() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player'));
      if (!mp || !mp.getAvailableQualityLevels) return null;
      return JSON.stringify({ levels: mp.getAvailableQualityLevels(), cur: mp.getPlaybackQuality(),
        labels: (mp.getAvailableQualityData ? mp.getAvailableQualityData() : []).map(x => [x.quality, x.qualityLabel]) }); })()
    """

    private static func setQualityJS(_ q: String) -> String {
        """
        (() => { const mp = (location.pathname.startsWith('/shorts') ? document.getElementById('shorts-player') : document.getElementById('movie_player')); if (!mp || !mp.getAvailableQualityLevels) return '';
          let q = '\(q)';
          if (q === 'best') q = mp.getAvailableQualityLevels().find(x => x !== 'auto') || '';
          if (!q) return '';
          if (q === 'auto') { mp.setPlaybackQualityRange('auto'); return q; }
          mp.setPlaybackQualityRange(q, q); if (mp.setPlaybackQuality) mp.setPlaybackQuality(q); return q; })()
        """
    }

    func setQuality(_ q: String) { webView?.evaluateJavaScript(Self.setQualityJS(q)) }

    /// 화질 목록이 늦게 채워지기도 해서 몇 번 나눠서 시도
    private func applyBestSoon() {
        for t in [0.3, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.bestQuality else { return }
                self.setQuality("best")
            }
        }
    }

    /// 화질 메뉴: 지금 영상이 지원하는 화질 + '항상 최고 화질' 체크
    func showQualityMenu(from view: NSView) {
        guard let wv = webView else { return }
        if site == .netflix {
            let m = NSMenu()
            let it = NSMenuItem(title: "화질은 Netflix 가 인터넷 속도에 맞춰 자동으로 골라요", action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            return
        }
        wv.evaluateJavaScript(Self.qualityInfoJS) { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var levels: [String] = [], cur = "", labels: [String: String] = [:]
                if let s = r as? String, let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    levels = o["levels"] as? [String] ?? []
                    cur = o["cur"] as? String ?? ""
                    for pair in o["labels"] as? [[String]] ?? [] where pair.count == 2 { labels[pair[0]] = pair[1] }
                }
                let m = NSMenu()
                let head = NSMenuItem(title: levels.isEmpty ? "영상을 재생하면 화질을 고를 수 있어요" : "화질", action: nil, keyEquivalent: "")
                head.isEnabled = false
                m.addItem(head)
                for q in levels {
                    let title = q == "auto" ? "자동" : (labels[q] ?? Self.qualityName[q] ?? q)
                    let it = MenuAction(title) { [weak self] in self?.setQuality(q) }
                    if q == cur && !self.bestQuality { it.state = .on }
                    if q == cur && self.bestQuality { it.state = .mixed }
                    m.addItem(it)
                }
                m.addItem(.separator())
                let best = MenuAction("항상 최고 화질로 자동 선택") { [weak self] in
                    guard let self else { return }
                    self.bestQuality.toggle()
                }
                best.state = self.bestQuality ? .on : .off
                best.toolTip = "새 영상을 열 때마다 그 영상이 지원하는 가장 높은 화질로"
                m.addItem(best)
                let next = MenuAction("쇼츠 끝나면 다음 쇼츠로 자동 넘김") { [weak self] in self?.autoNextShorts.toggle() }
                next.state = self.autoNextShorts ? .on : .off
                next.toolTip = "쇼츠는 원래 끝나면 다시 처음부터 반복돼요. 켜면 다음 쇼츠로 넘어가요"
                m.addItem(next)
                m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            }
        }
    }

    private static func mediaJS(_ body: String) -> String {
        "(() => { const v = (location.pathname.startsWith('/shorts') ? document.querySelector('#shorts-player video') : document.querySelector('#movie_player video.html5-main-video')) || document.querySelector('video'); if (v) { \(body); } })()"
    }

    // MARK: 사이트별 영상 · 플레이어

    /// 지금 보고 있는 영상 요소 (JS 식)
    private var jsV: String {
        site == .youtube
            ? "(location.pathname.startsWith('/shorts') ? document.querySelector('#shorts-player video') : document.querySelector('#movie_player video.html5-main-video'))"
            : Self.nfVideo
    }
    private static let nfVideo = "(document.querySelector('.watch-video video') || document.querySelector('video'))"
    /// Netflix 플레이어 (영상 위치를 직접 바꾸면 Netflix 가 오류를 내서, 재생 · 이동 · 볼륨은 이걸로)
    private static let nfPlayer = "(() => { try { const vp = netflix.appContext.state.playerApp.getAPI().videoPlayer; const ids = vp.getAllPlayerSessionIds(); return ids.length ? vp.getVideoPlayerBySessionId(ids[ids.length - 1]) : null; } catch (e) { return null; } })()"

    private func playPause() {
        if site == .netflix {
            webView?.evaluateJavaScript("(() => { const p = \(Self.nfPlayer); if (p && p.isPaused) { p.isPaused() ? p.play() : p.pause(); } else { const v = \(Self.nfVideo); if (v) v.paused ? v.play() : v.pause(); } })()")
        } else {
            webView?.evaluateJavaScript(Self.mediaJS("v.paused ? v.play() : v.pause()"))
        }
    }
    private func seek(_ t: Double) {
        if site == .netflix {
            webView?.evaluateJavaScript("(() => { const p = \(Self.nfPlayer); if (p && p.seek) p.seek(\(Int(t * 1000))); })()")
        } else {
            webView?.evaluateJavaScript(Self.mediaJS("v.currentTime = \(t)"))
        }
    }
}

/// 작은 창 위에 덮는 판: 끌면 창이 움직이고, 한 번 누르면 재생/멈춤, 두 번 누르면 큰 창.
/// 마우스를 올리면 버튼이 나타남
@MainActor
final class MiniOverlay: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSeekTo: ((Double) -> Void)?
    var onExpand: (() -> Void)?
    var onQuality: ((NSView) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onMute: (() -> Void)?
    /// 스크롤 한 번(true = 아래로) — 쇼츠 넘기기
    var onScrollStep: ((Bool) -> Void)?
    private var scrollSum: CGFloat = 0
    private var scrollLockUntil = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        // 트랙패드는 작은 움직임이 여러 번 오므로 모아서 한 번만, 넘긴 직후 관성 스크롤은 무시
        if event.phase == .began { scrollSum = 0 }
        guard Date() > scrollLockUntil else { return }
        if !event.momentumPhase.isEmpty && scrollSum == 0 { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        scrollSum += dy
        guard abs(scrollSum) > 40 else { return }
        onScrollStep?(scrollSum < 0)    // 손가락을 위로 밀면(내용이 위로) 다음 쇼츠
        scrollSum = 0
        scrollLockUntil = Date().addingTimeInterval(0.7)
    }
    private var volButton: NSButton!
    private let volSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    var onClose: (() -> Void)?
    /// 일반 창 PIP 처럼 영상이 아닐 때: 재생바 · 화질 · 가운데 재생 버튼 없이 이동 · 크기 · 닫기만
    func useWindowMode(closeTip: String, expandTip: String) {
        bar.isHidden = true
        controls[3].isHidden = true          // 화질 버튼
        centerButton?.isHidden = true
        dimView.isHidden = true
        controls[0].toolTip = closeTip
        controls[1].toolTip = expandTip
    }
    private var controls: [NSView] = []
    private let bar = NSView()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let curLabel = NSTextField(labelWithString: "0:00")
    private let endLabel = NSTextField(labelWithString: "0:00")
    private var playButton: NSButton!
    private var live = false
    /// 마우스가 올라와 있는지 (재생바를 그릴 때만 시간을 읽음)
    private(set) var showing = false
    private var downAt: NSPoint = .zero
    private var originAt: NSPoint = .zero
    private var dragged = false
    /// 가장자리를 잡으면 크기 조절 (어느 쪽을 잡았는지)
    private var edges: (l: Bool, r: Bool, b: Bool, t: Bool) = (false, false, false, false)
    private var frameAt: NSRect = .zero
    private let grip: CGFloat = 14
    /// 영상 가로/세로 비율. 크기를 바꿔도 이 비율 유지 (영상이 잘리거나 검은 여백이 안 생기게)
    var aspect: CGFloat = 16.0 / 9.0
    private var onEdge: Bool { edges.l || edges.r || edges.b || edges.t }
    /// 위쪽 가운데 손잡이: 여기를 잡아야만 창이 움직임 (가장자리는 크기 조절, 가운데는 재생/멈춤)
    private let gripBar = NSView()
    private var gripRect: NSRect {
        let w = min(140, max(40, min(bounds.width * 0.3, bounds.width - 180)))   // 좁으면 양옆 버튼과 안 겹치게
        return NSRect(x: bounds.midX - w / 2, y: bounds.height - 44, width: w, height: 28)
    }
    private var moving = false
    private var overGrip = false {
        didSet {
            guard overGrip != oldValue else { return }
            layoutGrip()
        }
    }
    private func layoutGrip() {
        let g = gripRect
        let w: CGFloat = overGrip || moving ? 56 : 44, h: CGFloat = 5
        gripBar.frame = NSRect(x: g.midX - w / 2, y: g.midY - h / 2, width: w, height: h)
        gripBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(overGrip || moving ? 0.95 : 0.6).cgColor
    }
    /// 가장자리 강조 선 (왼 · 오 · 아래 · 위)
    private var edgeBars: [NSView] = []
    private var shownEdges: (l: Bool, r: Bool, b: Bool, t: Bool) = (false, false, false, false)
    private var strongEdges = false

    private func layoutEdgeBars() {
        guard edgeBars.count == 4 else { return }
        let th: CGFloat = strongEdges ? 4 : 3, inset: CGFloat = 9   // 둥근 모서리만큼 안쪽에서 시작
        edgeBars[0].frame = NSRect(x: 1, y: inset, width: th, height: bounds.height - inset * 2)
        edgeBars[1].frame = NSRect(x: bounds.width - th - 1, y: inset, width: th, height: bounds.height - inset * 2)
        edgeBars[2].frame = NSRect(x: inset, y: 1, width: bounds.width - inset * 2, height: th)
        edgeBars[3].frame = NSRect(x: inset, y: bounds.height - th - 1, width: bounds.width - inset * 2, height: th)
        edgeBars.forEach { $0.layer?.cornerRadius = th / 2 }
    }

    /// 잡을 수 있는 가장자리를 밝게 (strong: 잡고 끄는 중이면 더 진하게)
    private func highlight(_ e: (l: Bool, r: Bool, b: Bool, t: Bool), strong: Bool) {
        guard edgeBars.count == 4 else { return }
        let same = e == shownEdges && strong == strongEdges
        guard !same else { return }
        shownEdges = e
        strongEdges = strong
        layoutEdgeBars()
        let on = [e.l, e.r, e.b, e.t]
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.15
            for (i, v) in edgeBars.enumerated() { v.animator().alphaValue = on[i] ? (strong ? 1 : 0.6) : 0 }
        }
    }

    // 가장자리는 버튼 · 재생바보다 우선 (크기 조절이 잘 잡히게)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        let e = edgesAt(p)
        if e.l || e.r || e.b || e.t { return self }
        return super.hitTest(point)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        func pill(_ symbol: String, _ tip: String, size: CGFloat = 15, _ action: @escaping () -> Void) -> NSButton {
            let b = ActionButton(title: "", symbol: symbol) { _ in action() }
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.contentTintColor = .white
            b.toolTip = tip
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            b.layer?.cornerRadius = 15
            b.frame.size = NSSize(width: 30, height: 30)
            return b
        }
        let close = pill("xmark", "닫기 (영상 멈춤)", size: 12) { [unowned self] in onClose?() }
        let expand = pill("arrow.up.left.and.arrow.down.right", "큰 창으로", size: 12) { [unowned self] in onExpand?() }
        close.autoresizingMask = [.minYMargin]
        expand.autoresizingMask = [.minXMargin, .minYMargin]

        // 아래 재생바: [▶︎] 1:23 ━━━●━━━ 4:56  (끌어서 원하는 곳으로)
        bar.wantsLayer = true
        let g = CAGradientLayer()
        g.colors = [NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        g.startPoint = CGPoint(x: 0.5, y: 0); g.endPoint = CGPoint(x: 0.5, y: 1)
        bar.layer = g
        bar.autoresizingMask = [.width, .maxYMargin]
        let pb = ActionButton(title: "", symbol: "play.fill") { [unowned self] _ in onPlayPause?(); flipPaused() }
        pb.isBordered = false
        pb.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        pb.contentTintColor = .white
        pb.toolTip = "재생 / 멈춤"
        pb.frame.size = NSSize(width: 26, height: 26)
        playButton = pb
        for l in [curLabel, endLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            l.textColor = .white
            l.shadow = { let s = NSShadow(); s.shadowColor = .black; s.shadowBlurRadius = 2; return s }()
        }
        endLabel.alignment = .right
        let pc = ProgressCell()
        pc.fill = accent
        slider.cell = pc
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(scrub)
        let vb = ActionButton(title: "", symbol: "speaker.wave.2.fill") { [unowned self] _ in onMute?() }
        vb.isBordered = false
        vb.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        vb.contentTintColor = .white
        vb.toolTip = "소리 끄기 / 켜기"
        vb.frame.size = NSSize(width: 22, height: 22)
        volButton = vb
        volSlider.controlSize = .mini
        volSlider.isContinuous = true
        volSlider.target = self
        volSlider.action = #selector(volumeChanged)
        volSlider.toolTip = "볼륨"
        [pb, curLabel, slider, endLabel, vb, volSlider].forEach(bar.addSubview)
        var qv: NSView?
        let quality = pill("slider.horizontal.3", "화질 · 재생 옵션", size: 12) { [unowned self] in if let qv { onQuality?(qv) } }
        qv = quality
        quality.autoresizingMask = [.minXMargin, .minYMargin]
        gripBar.wantsLayer = true
        gripBar.layer?.cornerRadius = 2.5
        gripBar.layer?.shadowColor = NSColor.black.cgColor
        gripBar.layer?.shadowOpacity = 0.6
        gripBar.layer?.shadowRadius = 2
        gripBar.layer?.shadowOffset = .zero
        gripBar.toolTip = "잡고 끌어서 옮기기"
        controls = [close, expand, bar, quality, gripBar]
        for _ in 0..<4 {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.cgColor
            v.layer?.shadowColor = NSColor.black.cgColor
            v.layer?.shadowOpacity = 0.5
            v.layer?.shadowRadius = 2
            v.layer?.shadowOffset = .zero
            v.alphaValue = 0
            edgeBars.append(v)
        }
        // 멈춤 표시: 화면을 살짝 어둡게 (컨트롤보다 아래)
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        dimView.frame = bounds
        dimView.autoresizingMask = [.width, .height]
        addSubview(dimView)
        // 가운데 큰 재생 / 멈춤 버튼
        let cb = ActionButton(title: "", symbol: "play.fill") { [unowned self] _ in onPlayPause?(); flipPaused() }
        cb.isBordered = false
        cb.symbolConfiguration = .init(pointSize: 24, weight: .bold)
        cb.contentTintColor = .white
        cb.toolTip = "재생 / 멈춤"
        cb.wantsLayer = true
        cb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        cb.layer?.cornerRadius = 30
        cb.frame.size = NSSize(width: 60, height: 60)
        cb.alphaValue = 0
        centerButton = cb
        addSubview(cb)
        controls.forEach { $0.alphaValue = 0; addSubview($0) }
        edgeBars.forEach { addSubview($0) }
        layoutControls()
        layoutCenter()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutControls() {
        guard controls.count == 5 else { return }
        layoutGrip()
        controls[3].setFrameOrigin(NSPoint(x: bounds.width - 84, y: bounds.height - 46))
        controls[0].setFrameOrigin(NSPoint(x: 16, y: bounds.height - 46))
        controls[1].setFrameOrigin(NSPoint(x: bounds.width - 46, y: bounds.height - 46))
        let h: CGFloat = 48
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        playButton.setFrameOrigin(NSPoint(x: 14, y: 15))
        let lw: CGFloat = live ? 46 : 52
        // 오른쪽 끝: [🔊][━━ 볼륨] (좁으면 볼륨 막대는 숨기고 🔊 만)
        let wide = bounds.width >= 340
        volSlider.isHidden = !wide
        var right = bounds.width - 16
        if wide { volSlider.frame = NSRect(x: right - 64, y: 18, width: 64, height: 20); right -= 68 }
        volButton.setFrameOrigin(NSPoint(x: right - 22, y: 16))
        right -= 26
        curLabel.frame = NSRect(x: 42, y: 20, width: lw, height: 15)
        endLabel.frame = NSRect(x: right - lw, y: 20, width: lw, height: 15)
        slider.frame = NSRect(x: curLabel.frame.maxX + 4, y: 18, width: max(20, endLabel.frame.minX - curLabel.frame.maxX - 8), height: 20)
    }

    private static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 재생바 새로 그리기 (끄는 중이면 손대지 않음)
    func update(time: Double, start: Double, end: Double, paused: Bool, live: Bool, volume: Double, muted: Bool) {
        if paused != self.paused { setPaused(paused) }
        let vs = muted || volume == 0 ? "speaker.slash.fill" : (volume < 34 ? "speaker.wave.1.fill" : (volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        volButton.image = NSImage(systemSymbolName: vs, accessibilityDescription: nil)
        if NSEvent.pressedMouseButtons & 1 == 0 { volSlider.doubleValue = muted ? 0 : volume }
        if self.live != live { self.live = live; layoutControls() }
        guard NSEvent.pressedMouseButtons & 1 == 0 || !isScrubbing else { return }
        isScrubbing = false
        slider.isEnabled = end > start
        slider.minValue = start
        slider.maxValue = max(end, start + 0.001)
        slider.doubleValue = time
        curLabel.stringValue = live ? "-" + Self.clock(end - time) : Self.clock(time)
        endLabel.stringValue = live ? "LIVE" : Self.clock(end)
    }

    @objc private func volumeChanged() { onVolume?(volSlider.doubleValue) }

    private var isScrubbing = false
    @objc private func scrub() {
        isScrubbing = true
        let t = slider.doubleValue
        curLabel.stringValue = live ? "-" + Self.clock(slider.maxValue - t) : Self.clock(t)
        onSeekTo?(t)
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutControls(); layoutEdgeBars(); layoutCenter() }

    // MARK: 가운데 재생 버튼 · 멈춤 어둡게

    private let dimView = NSView()
    private var centerButton: NSButton!
    private(set) var paused = false
    /// 재생바에서 이미 본 부분 색 (YouTube 빨강 · Netflix 빨강)
    var accent: NSColor = .systemRed { didSet { (slider.cell as? ProgressCell)?.fill = accent; slider.needsDisplay = true } }
    private func layoutCenter() {
        guard let cb = centerButton else { return }
        let d: CGFloat = min(60, max(40, min(bounds.width, bounds.height) * 0.22))
        cb.frame = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        cb.layer?.cornerRadius = d / 2
        cb.symbolConfiguration = .init(pointSize: d * 0.4, weight: .bold)
    }
    /// 재생 상태 반영: 멈추면 어둡게 + 가운데 ▶ 항상, 재생 중이면 가운데 ⏸ 는 마우스 올렸을 때만
    func setPaused(_ p: Bool, animated: Bool = true) {
        let changed = p != paused
        paused = p
        centerButton?.image = NSImage(systemSymbolName: p ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        playButton?.image = NSImage(systemSymbolName: p ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        guard changed || !animated else { refreshCenter(); return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = animated ? 0.2 : 0
            dimView.animator().alphaValue = p ? 0.35 : 0
        }
        refreshCenter()
    }
    private func refreshCenter() {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            centerButton?.animator().alphaValue = (paused || showing) ? 1 : 0
        }
    }
    /// 누른 순간 바로 바뀐 것처럼 보이게 (실제 상태는 0.5초마다 다시 맞춤) + 살짝 커졌다 돌아오는 효과
    func flipPaused() {
        setPaused(!paused)
        guard let l = centerButton?.layer else { return }
        let b = l.bounds
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: centerButton.frame.midX, y: centerButton.frame.midY)
        l.bounds = b
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.18, 1]
        a.keyTimes = [0, 0.4, 1]
        a.duration = 0.25
        l.add(a, forKey: "pulse")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    private func fade(_ a: CGFloat) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            controls.forEach { $0.animator().alphaValue = a }
        }
        refreshCenter()
    }
    override func mouseEntered(with event: NSEvent) { showing = true; fade(1) }
    override func mouseExited(with event: NSEvent) {
        showing = false; fade(0); NSCursor.arrow.set()
        if !(dragged && onEdge) { highlight((false, false, false, false), strong: false) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func edgesAt(_ p: NSPoint) -> (l: Bool, r: Bool, b: Bool, t: Bool) {
        (p.x < grip, p.x > bounds.width - grip, p.y < grip, p.y > bounds.height - grip)
    }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    private func updateCursor(_ event: NSEvent) {
        if dragged && (onEdge || moving) { return }       // 끄는 중엔 커서 그대로
        let p = convert(event.locationInWindow, from: nil)
        let e = edgesAt(p)
        overGrip = !(e.l || e.r || e.b || e.t) && gripRect.contains(p)
        setCursor(e)
    }
    private func setCursor(_ e: (l: Bool, r: Bool, b: Bool, t: Bool)) {
        highlight(e, strong: dragged && onEdge || (NSEvent.pressedMouseButtons & 1 != 0 && onEdge))
        if (e.l || e.r) && (e.b || e.t) {
            NSCursor.frameResize(position: e.t ? (e.l ? .topLeft : .topRight) : (e.l ? .bottomLeft : .bottomRight),
                                 directions: .all).set()
        } else if e.l || e.r {
            NSCursor.frameResize(position: e.l ? .left : .right, directions: .all).set()
        } else if e.b || e.t {
            NSCursor.frameResize(position: e.t ? .top : .bottom, directions: .all).set()
        } else if overGrip || moving {
            (moving ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        originAt = window?.frame.origin ?? .zero
        frameAt = window?.frame ?? .zero
        let lp = convert(event.locationInWindow, from: nil)
        edges = edgesAt(lp)
        dragged = false
        moving = !onEdge && gripRect.contains(lp)
        if moving { layoutGrip() }
        if onEdge || moving { setCursor(edges) }
        if event.clickCount == 2 && !onEdge && !moving { onDoubleClick?() }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downAt.x, dy = p.y - downAt.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        guard let w = window else { return }
        if onEdge {
            // 비율 고정 크기 조절: 끈 방향으로 폭(또는 높이)을 정하고 나머지는 비율로.
            // 잡은 쪽의 반대편 모서리는 제자리
            let ar = max(0.2, aspect)
            var wNew = frameAt.width
            let byW = (edges.l || edges.r) ? (edges.r ? frameAt.width + dx : frameAt.width - dx) : nil
            let byH = (edges.t || edges.b) ? ((edges.t ? frameAt.height + dy : frameAt.height - dy) * ar) : nil
            switch (byW, byH) {
            case let (a?, b?): wNew = abs(a - frameAt.width) >= abs(b - frameAt.width) ? a : b   // 모서리: 더 많이 끈 쪽
            case let (a?, nil): wNew = a
            case let (nil, b?): wNew = b
            default: break
            }
            let minW = max(w.minSize.width, w.minSize.height * ar)
            wNew = max(minW, wNew)
            if let vf = (w.screen ?? NSScreen.main)?.visibleFrame { wNew = min(wNew, vf.width, vf.height * ar) }
            let hNew = (wNew / ar).rounded()
            var f = NSRect(x: frameAt.minX, y: frameAt.minY, width: wNew.rounded(), height: hNew)
            if edges.l { f.origin.x = frameAt.maxX - f.width }
            // 위쪽을 잡았으면 아래 모서리 고정, 아니면 위쪽 모서리 고정
            f.origin.y = edges.t && !edges.b ? frameAt.minY : frameAt.maxY - f.height
            w.setFrame(f, display: true)
        } else if moving {
            // 끄는 동안에도 마우스가 있는 모니터 밖으로는 안 나감
            let f = NSRect(origin: NSPoint(x: originAt.x + dx, y: originAt.y + dy), size: w.frame.size)
            w.setFrameOrigin(OnScreen.clamp(f, prefer: p).origin)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if let w = window { OnScreen.fix(w) }
        let wasHandle = onEdge || moving
        edges = (false, false, false, false)
        moving = false
        let p = convert(event.locationInWindow, from: nil)
        let e = edgesAt(p)
        overGrip = !(e.l || e.r || e.b || e.t) && gripRect.contains(p)
        layoutGrip()
        setCursor(e)
        // 가운데를 한 번 누르면 재생/멈춤 (손잡이 · 가장자리를 누른 건 제외)
        if !dragged && !wasHandle && event.clickCount == 1 { onClick?(); flipPaused() }
    }
}

/// 누르면 바로 실행되는 메뉴 항목
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// 작은 창 재생바: 본 부분은 빨강, 남은 부분은 반투명 흰색, 손잡이는 작은 흰 동그라미 (YouTube 처럼)
final class ProgressCell: NSSliderCell {
    var fill: NSColor = .systemRed
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let r = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        let span = maxValue - minValue
        let frac = span > 0 ? max(0, min(1, (doubleValue - minValue) / span)) : 0
        var f = r
        f.size.width = r.width * frac
        if f.width > 0 {
            fill.setFill()
            NSBezierPath(roundedRect: f, xRadius: 2, yRadius: 2).fill()
        }
    }
    override func knobRect(flipped: Bool) -> NSRect {
        guard let cv = controlView else { return super.knobRect(flipped: flipped) }
        let b = barRect(flipped: flipped)
        let span = maxValue - minValue
        let frac = span > 0 ? max(0, min(1, (doubleValue - minValue) / span)) : 0
        let d: CGFloat = 12
        _ = cv
        return NSRect(x: b.minX + b.width * frac - d / 2, y: b.midY - d / 2, width: d, height: d)
    }
    override func drawKnob(_ knobRect: NSRect) {
        let r = NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12)
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.5)
        sh.shadowBlurRadius = 2
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func barRect(flipped: Bool) -> NSRect {
        guard let cv = controlView else { return super.barRect(flipped: flipped) }
        return cv.bounds.insetBy(dx: 7, dy: 0)
    }
}
