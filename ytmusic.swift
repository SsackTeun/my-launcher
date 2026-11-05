// YouTube Music 내장 플레이어: 도구함 안의 브라우저 창(WKWebView)에서 music.youtube.com 을 열고,
// 그 페이지를 직접 읽고 눌러서 미니 플레이어를 움직임. 별도 권한이 필요 없고 창 크기·탭과 상관없이 동작
import Cocoa
import WebKit

struct PlayerState {
    var title = ""
    var byline = ""
    var time = ""
    var position: Double = 0
    var duration: Double = 0
    var playing: Bool?
    var liked = false
    var disliked = false
    var repeatLabel = ""
    var volume: Double = 100
    var muted = false
    var pageOpen = false
    var artURL = ""
    var limited = false
    var has: Set<String> = ["prev", "playPause", "next", "like", "dislike", "shuffle", "repeat", "mute", "progress", "volume"]
    var repeatOn: Bool { repeatLabel == "ALL" || repeatLabel == "ONE" }
    var repeatOne: Bool { repeatLabel == "ONE" }
}

struct QueueItem {
    let title: String
    let artist: String
    let duration: String
    let current: Bool
    let index: Int
}

@MainActor
final class YTMusic: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private(set) var state: PlayerState?
    private(set) var art: NSImage?
    var onFoundChange: (() -> Void)?
    var onUpdate: ((PlayerState, NSImage?) -> Void)?
    /// 미니 플레이어를 보여 줄지 (브라우저가 켜져 있으면 true)
    private(set) var isActive = false

    private var webView: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?
    private var artURL = ""

    // 일반 Safari 처럼 보이게 해서 Google 로그인이 막히지 않도록
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let home = URL(string: "https://music.youtube.com/")!

    // MARK: 켜기 · 끄기

    func start() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                     // 로그인 상태(쿠키) 유지
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: cfg)
        wv.customUserAgent = Self.userAgent
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: Self.home))
        webView = wv

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "YouTube Music"
        w.contentView = wv
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("YouTubeMusicWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame YouTubeMusicWindow") == nil { w.center() }
        window = w

        isActive = true
        onFoundChange?()
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        webView?.pauseAllMediaPlayback()
        window?.orderOut(nil)
        webView = nil
        window = nil
        state = nil
        art = nil
        artURL = ""
        isActive = false
        onFoundChange?()
    }

    /// YouTube Music 창 보이기 (처음엔 여기서 로그인)
    func showWindow() {
        if webView == nil { start() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 창을 닫아도 음악은 계속 (숨기기만)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // 로그인 등 새 창을 여는 링크는 같은 창에서
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    // MARK: 상태 읽기 (페이지 안에서 매초)

    private static let stateJS = """
    (() => {
      const bar = document.querySelector('ytmusic-player-bar');
      const v = document.querySelector('video');
      const mp = document.getElementById('movie_player');
      if (!bar) return JSON.stringify({ready:false});
      const q = s => bar.querySelector(s);
      const txt = el => el ? el.textContent.replace(/\\s+/g,' ').trim() : '';
      const img = q('.middle-controls img') || q('img.image') || q('img');
      const like = q('ytmusic-like-button-renderer');
      let vol = 100, muted = false;
      try { if (mp && mp.getVolume) { vol = mp.getVolume(); muted = mp.isMuted(); } else if (v) { vol = v.volume*100; muted = v.muted; } } catch(e) {}
      return JSON.stringify({
        ready: true,
        title: txt(q('.title')),
        byline: txt(q('.byline')),
        art: img ? (img.currentSrc || img.src || '') : '',
        time: txt(q('.time-info')),
        pos: v ? v.currentTime : 0,
        dur: v && isFinite(v.duration) ? v.duration : 0,
        playing: v ? !v.paused : false,
        hasVideo: !!v && !!(v.currentSrc || v.src),
        like: like ? (like.getAttribute('like-status') || '') : '',
        repeat: bar.getAttribute('repeat-mode') || (() => {
          const r = [...bar.querySelectorAll('button')].map(b => b.getAttribute('aria-label') || '').find(a => a.includes('반복') || a.toLowerCase().includes('repeat')) || '';
          return r.includes('한 곡') || r.toLowerCase().includes('one') ? 'ONE' : (r.includes('모두') || r.toLowerCase().includes('all') ? 'ALL' : (r ? 'NONE' : ''));
        })(),
        vol: vol, muted: muted,
        page: document.querySelector('ytmusic-app-layout')?.getAttribute('player-page-open') !== null
      });
    })()
    """

    private func poll() {
        guard let wv = webView else { return }
        // 진단: 설정값 ytmEvalJS 에 넣은 코드를 페이지에서 한 번 실행하고 결과를 파일로
        if let js = UserDefaults.standard.string(forKey: "ytmEvalJS"), !js.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ytmEvalJS")
            wv.evaluateJavaScript(js) { r, e in
                let out = r.map { String(describing: $0) } ?? "error: \(String(describing: e))"
                try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-eval.txt", atomically: true, encoding: .utf8)
            }
        }
        // 진단: 설정값 ytmLyricsTest 가 켜져 있으면 가사를 한 번 읽어 파일로
        if UserDefaults.standard.bool(forKey: "ytmLyricsTest") {
            UserDefaults.standard.set(false, forKey: "ytmLyricsTest")
            fetchLyrics { l in
                let out = "title=\(l.title)\nstatus=\(l.status)\nsource=\(l.source)\n---\n\(l.text.prefix(600))"
                try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-lyrics-test.txt", atomically: true, encoding: .utf8)
            }
        }
        if UserDefaults.standard.bool(forKey: "ytmWebDump") {
            UserDefaults.standard.set(false, forKey: "ytmWebDump")
            debugDump()
            wv.evaluateJavaScript(Self.queueJS) { r, _ in
                try? ((r as? String) ?? "nil").write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-queue-debug.txt", atomically: true, encoding: .utf8)
            }
        }
        wv.evaluateJavaScript(Self.stateJS) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                var st = PlayerState()
                if o["ready"] as? Bool == true, o["hasVideo"] as? Bool == true {
                    st.title = o["title"] as? String ?? ""
                    st.byline = o["byline"] as? String ?? ""
                    st.time = o["time"] as? String ?? ""
                    st.position = o["pos"] as? Double ?? 0
                    st.duration = o["dur"] as? Double ?? 0
                    st.playing = o["playing"] as? Bool
                    let like = o["like"] as? String ?? ""
                    st.liked = like == "LIKE"
                    st.disliked = like == "DISLIKE"
                    st.repeatLabel = o["repeat"] as? String ?? ""
                    st.volume = o["vol"] as? Double ?? 100
                    st.muted = o["muted"] as? Bool ?? false
                    st.pageOpen = o["page"] as? Bool ?? false
                    st.artURL = o["art"] as? String ?? ""
                } else {
                    // 아직 곡을 틀지 않았거나 로그인 전
                    st.byline = "제목을 눌러 YouTube Music 열기"
                    st.has = []
                }
                self.state = st
                self.onUpdate?(st, self.art)
                self.loadArt(st.artURL)
            }
        }
    }

    // MARK: 앨범 사진 (페이지에 있는 이미지 주소로 바로 받음)

    private func loadArt(_ url: String) {
        guard url != artURL else { return }
        artURL = url
        // 페이지엔 60px 짜리 주소가 있어 큰 사진으로 바꿔 받음
        let big = url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w240-h240", options: .regularExpression)
        guard !url.isEmpty, let u = URL(string: big) else { art = nil; return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.artURL == url else { return }
                    self.art = img
                    if let s = self.state { self.onUpdate?(s, img) }
                }
            }
        }.resume()
    }

    // MARK: 조작

    private func run(_ js: String, then: (() -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { [weak self] _, _ in
            MainActor.assumeIsolated {
                then?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
            }
        }
    }

    /// 플레이어 줄에서 이름표(aria-label)로 버튼 찾아 누르기. 클래스 이름이 바뀌어도 동작하도록
    private static func clickJS(_ labels: [String], prefix: Bool = false, scope: String = "ytmusic-player-bar") -> String {
        let arr = labels.map { "'\($0)'" }.joined(separator: ",")
        return """
        (() => { const L = [\(arr)];
          const bs = [...document.querySelectorAll('\(scope) button, \(scope) tp-yt-paper-icon-button')];
          const ok = b => { const a = (b.getAttribute('aria-label') || b.getAttribute('title') || '').trim();
                            return \(prefix ? "L.some(x => a.includes(x))" : "L.includes(a)"); };
          const b = bs.find(b => ok(b) && b.offsetParent !== null) || bs.find(ok);
          if (b) b.click(); return !!b; })()
        """
    }

    private static let actions: [String: String] = [
        "playPause": clickJS(["재생", "일시중지", "일시정지", "Play", "Pause"]),
        "next": clickJS(["다음", "Next"]),
        "prev": clickJS(["이전", "Previous"]),
        "like": clickJS(["좋아요", "Like"]),
        "dislike": clickJS(["싫어요", "Dislike"]),
        "repeat": clickJS(["반복", "Repeat"], prefix: true),
        "shuffle": clickJS(["셔플", "Shuffle"]),
        "mute": "(() => { const mp = document.getElementById('movie_player'); if (mp && mp.isMuted) { mp.isMuted() ? mp.unMute() : mp.mute(); } else { const v = document.querySelector('video'); if (v) v.muted = !v.muted; } })()",
    ]

    func press(_ key: String) {
        guard let js = Self.actions[key] else { return }
        run(js)
    }

    /// 진행바를 원하는 위치로 (0~1)
    func seek(_ fraction: Double) {
        guard let st = state, st.duration > 0 else { return }
        let sec = max(0, min(st.duration, fraction * st.duration))
        run("(() => { const mp = document.getElementById('movie_player'); if (mp && mp.seekTo) mp.seekTo(\(sec), true); else { const v = document.querySelector('video'); if (v) v.currentTime = \(sec); } })()")
    }

    func setVolume(_ v: Double) {
        let n = Int(v.rounded())
        run("(() => { const mp = document.getElementById('movie_player'); if (mp && mp.setVolume) { mp.setVolume(\(n)); if (mp.isMuted && mp.isMuted() && \(n) > 0) mp.unMute(); } const s = document.querySelector('ytmusic-player-bar #volume-slider'); if (s) { s.value = \(n); } })()")
    }

    // MARK: 가사 (플레이어 페이지의 "가사" 탭 — 숨은 창 안에서 열기 때문에 화면엔 변화 없음)

    struct Lyrics: Equatable {
        var title = ""
        var status = "loading"     // ok · none · loading
        var text = ""
        var source = ""
    }

    private static let lyricsJS = """
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const title = ((document.querySelector('ytmusic-player-bar .title') || {}).textContent || '').trim();
    const layout = document.querySelector('ytmusic-app-layout');
    if (layout && !layout.hasAttribute('player-page-open')) {
      const b = [...document.querySelectorAll('ytmusic-player-bar button, ytmusic-player-bar tp-yt-paper-icon-button')]
        .find(b => ['플레이어 페이지 열기', 'Open player page'].includes((b.getAttribute('aria-label') || '').trim()));
      if (b) { b.click(); await sleep(800); }
    }
    const tab = [...document.querySelectorAll('ytmusic-player-page tp-yt-paper-tab')]
      .find(t => ['가사', 'Lyrics', 'LYRICS'].includes(t.textContent.trim()));
    if (!tab || tab.hasAttribute('disabled') || tab.getAttribute('aria-disabled') === 'true') return {title, status: 'none'};
    if (tab.getAttribute('aria-selected') !== 'true') { tab.click(); await sleep(1200); }
    const tr = document.querySelector('ytmusic-player-page ytmusic-tab-renderer[page-type="MUSIC_PAGE_TYPE_TRACK_LYRICS"]');
    const sh = tr && tr.querySelector('ytmusic-description-shelf-renderer');
    const text = sh ? ((sh.querySelector('.description') || {}).innerText || '') : '';
    const source = sh ? ((sh.querySelector('.footer') || {}).innerText || '') : '';
    if (!text.trim()) return {title, status: (tr && tr.innerText.trim()) ? 'none' : 'loading'};
    return {title, status: 'ok', text, source};
    """

    func fetchLyrics(_ done: @escaping (Lyrics) -> Void) {
        guard let wv = webView else { done(Lyrics(status: "none")); return }
        wv.callAsyncJavaScript(Self.lyricsJS, arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                guard case .success(let v) = result, let o = v as? [String: Any] else { done(Lyrics(status: "loading")); return }
                done(Lyrics(title: o["title"] as? String ?? "", status: o["status"] as? String ?? "none",
                            text: o["text"] as? String ?? "", source: o["source"] as? String ?? ""))
            }
        }
    }

    // MARK: 재생 목록 ("다음 트랙")

    private static let queueJS = """
    (() => {
      const txt = el => el ? el.textContent.replace(/\\s+/g,' ').trim() : '';
      // 곡마다 노래·뮤직비디오 두 버전이 들어 있어서, 뮤직비디오 쪽(counterpart)은 빼고
      const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter(i => !i.closest('#counterpart-renderer'));
      return JSON.stringify(list.map((it, i) => ({
        title: txt(it.querySelector('.song-title')),
        artist: txt(it.querySelector('.byline')),
        dur: txt(it.querySelector('.duration')),
        cur: it.hasAttribute('selected') || ['playing','paused'].includes(it.getAttribute('play-button-state') || '')
      })));
    })()
    """

    func loadQueue(_ done: @escaping ([QueueItem]) -> Void) {
        guard let wv = webView else { done([]); return }
        wv.evaluateJavaScript(Self.queueJS) { result, _ in
            MainActor.assumeIsolated {
                guard let json = result as? String, let data = json.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { done([]); return }
                done(arr.enumerated().compactMap { i, o in
                    let t = o["title"] as? String ?? ""
                    guard !t.isEmpty else { return nil }
                    return QueueItem(title: t, artist: o["artist"] as? String ?? "", duration: o["dur"] as? String ?? "",
                                     current: o["cur"] as? Bool ?? false, index: i)
                })
            }
        }
    }

    func queueClosed() {}

    func play(_ item: QueueItem) {
        run("""
        (() => {
          const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter(i => !i.closest('#counterpart-renderer'));
          const it = list[\(item.index)];
          if (!it) return;
          const b = it.querySelector('ytmusic-play-button-renderer #play-button, ytmusic-play-button-renderer, .song-info');
          (b || it).click();
        })()
        """)
    }

    // MARK: 진단 (설정값 ytmDebug 가 켜져 있으면 페이지 상태를 파일로)

    func debugDump() {
        webView?.evaluateJavaScript("""
        JSON.stringify({url: location.href,
          bar: !!document.querySelector('ytmusic-player-bar'),
          buttons: [...document.querySelectorAll('ytmusic-player-bar tp-yt-paper-icon-button, ytmusic-player-bar button')].map(b => (b.className||'') + ' | ' + (b.id||'') + ' | ' + (b.getAttribute('aria-label')||'')).slice(0,40),
          queue: document.querySelectorAll('ytmusic-player-queue-item').length})
        """) { r, e in
            let s = (r as? String) ?? "error: \(String(describing: e))"
            try? s.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-web-debug.txt", atomically: true, encoding: .utf8)
        }
    }
}
