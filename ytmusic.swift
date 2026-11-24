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
    /// 지금 틀고 있는 재생목록 ID (주소의 list=…) · 곡 ID (v=…)
    var listId = ""
    var videoId = ""
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
    /// 자동재생(재생목록이 끝난 뒤 YouTube Music 이 붙이는 곡)
    var auto = false
    /// 가수 페이지 ID (UC…), 링크가 있을 때만
    var artistId = ""
    /// 재생목록에 넣을 곡 ID (노래 버전이 있으면 그것)
    var videoId = ""
}

/// 가수의 앨범 · 싱글 한 줄
struct AlbumEntry {
    let title: String
    let sub: String
    let id: String       // MPREb…
    let thumb: String
    let section: String  // 앨범 · 싱글 및 EP
}

@MainActor
final class YTMusic: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private(set) var state: PlayerState?
    private(set) var art: NSImage?
    var onFoundChange: (() -> Void)?
    var onUpdate: ((PlayerState, NSImage?) -> Void)?
    /// 미니 플레이어를 보여 줄지 (브라우저가 켜져 있으면 true)
    private(set) var isActive = false

    var webView: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?
    private var artURL = ""

    // 일반 Safari 처럼 보이게 해서 Google 로그인이 막히지 않도록
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let home = URL(string: "https://music.youtube.com/")!
    /// 휴대폰 크기 창: YouTube Music 은 따로 모바일 웹이 없고(아이폰 이름표 · 터치 흉내를 해도 같은 화면), 좁은 창에 맞춰 화면이 접힘
    ///   → 이름표는 그대로 두고 창만 휴대폰 크기로 (로그인 · 가사 · 조작 모두 그대로)
    nonisolated static var mobile: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmMobile") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmMobile") }
    }
    nonisolated(unsafe) static weak var shared: YTMusic?
    /// 휴대폰 크기 창 켜고 끄기: 창을 휴대폰 / 넓은 크기로 (위쪽 모서리는 그대로)
    func setMobile(_ on: Bool) {
        Self.mobile = on
        if let w = window {
            let size = on ? NSSize(width: 420, height: 820) : NSSize(width: 1100, height: 760)
            var f = w.frame
            f.origin.y += f.height - size.height
            f.size = size
            w.setFrame(f, display: true, animate: w.isVisible)
        }
    }

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
        if UserDefaults.standard.string(forKey: "NSWindow Frame YouTubeMusicWindow") == nil {
            if Self.mobile { w.setContentSize(NSSize(width: 420, height: 820)) }
            w.center()
        }
        window = w

        isActive = true
        onFoundChange?()
        HearingMeter.shared.start()
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
        volumeRestored = false
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
      if (!bar) {
        // 모바일 화면: 플레이어 줄 모양이 달라서 브라우저 공통 '재생 정보'(mediaSession)와 video 로 읽음
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        if (!v || !md) return JSON.stringify({ready:false});
        const aw = (md.artwork || []).slice(-1)[0];
        const fmt = s => { s = Math.floor(s || 0); return Math.floor(s/60) + ':' + String(s%60).padStart(2,'0'); };
        return JSON.stringify({
          ready: true, mobile: true,
          title: md.title || '', byline: [md.artist, md.album].filter(x => x).join(' • '),
          art: aw ? aw.src : '',
          time: fmt(v.currentTime) + ' / ' + fmt(v.duration),
          pos: v.currentTime, dur: isFinite(v.duration) ? v.duration : 0,
          playing: !v.paused, hasVideo: !!(v.currentSrc || v.src),
          like: '', repeat: '', vol: v.volume*100, muted: v.muted, page: false
        });
      }
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
        page: document.querySelector('ytmusic-app-layout')?.getAttribute('player-page-open') !== null,
        list: new URLSearchParams(location.search).get('list') || '',
        vid: new URLSearchParams(location.search).get('v') || ''
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
        // 이퀄라이저: 페이지를 다시 불러오거나 영상 칸이 바뀌면 필터가 빠지므로 3초마다 확인
        eqTick += 1
        if (Self.masterOn && (Self.eqOn || Self.loudOn || Self.peqOn || Self.auto31On)) || HearingMeter.on, eqTick % 3 == 0 {
            // 아직 연결 전(소리를 낸 적이 없음)이면 다시 시도, 연결돼 있으면 소리가 들어오는지 확인
            if TapEQ.shared.running { TapEQ.shared.check(playing: state?.playing == true) }
            else if TapEQ.shared.problem == nil { applyEQ() }
        }
        autoSuggestTick()
        auto31Tick()
        // 내 재생목록 · 앨범을 듣는 중이면 자동재생을 계속 꺼 둠 (목록이 끝난 뒤 다른 가수 곡이 이어지지 않게)
        //   — 처음 틀 때 한 번만 껐더니, 중간에 다시 켜지면 목록 뒤에 섞인 곡이 붙었음. 믹스(RD…)는 원래 이어지는 거라 그대로
        if eqTick % 5 == 0, let l = state?.listId, l.hasPrefix("PL") || l.hasPrefix("OLAK") { setAutoplay(false) }
        // 진단: 소리 보정 팝업 열기
        if UserDefaults.standard.bool(forKey: "ytmOpenEQ") {
            UserDefaults.standard.set(false, forKey: "ytmOpenEQ")
            NotificationCenter.default.post(name: Notification.Name("openEQPopover"), object: nil)
        }
        // 진단: 곡마다 자동 맞춤을 지금 한 번 (결과를 파일로)
        if UserDefaults.standard.bool(forKey: "ytmAuto31Now") {
            UserDefaults.standard.set(false, forKey: "ytmAuto31Now")
            runAuto31 { ok in
                try? "ok=\(ok) gains=\(Self.auto31Gains)".write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8)
            }
        }
        // 진단: 랜덤 재생목록 고르기만 (만들지는 않음) — ytmRandomTest 에 가수 이름
        if let q = UserDefaults.standard.string(forKey: "ytmRandomTest"), !q.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ytmRandomTest")
            searchArtists(q) { [weak self] hs in
                guard let a = hs.first else { try? "no artist".write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8); return }
                self?.artistSongs(a) { songs in
                    let mix = RandomMix.make([(songs, 1)], limit: .minutes(30), popular: true)
                    let out = "artists=\(hs.map(\.name))\nsongs=\(songs.count)\nmix=\(RandomMix.describe(mix))\n" + mix.map { "\($0.title) \($0.secs)s" }.joined(separator: "\n")
                    try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // 진단: 장르 목록 · 첫 장르(또는 이름이 맞는 장르)의 추천 가수 — ytmGenreTest 에 장르 이름(빈칸이면 첫 장르)
        if let q = UserDefaults.standard.string(forKey: "ytmGenreTest") {
            UserDefaults.standard.removeObject(forKey: "ytmGenreTest")
            genres { [weak self] gs in
                guard let g = gs.first(where: { $0.title == q }) ?? gs.first else { try? "no genres".write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8); return }
                self?.genreArtists(g, skip: []) { arts, used in
                    let out = "genres=\(gs.count) \(gs.prefix(30).map { "[\($0.section)]\($0.title)" })\npicked=\(g.title) lists=\(used.count)\nartists=\(arts.count)\n" + arts.prefix(20).map { "\($0.0.name) \($0.1)" }.joined(separator: "\n")
                    try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // 진단: 랜덤 재생목록 창 열고 n번째 장르 고르기 (ytmOpenRandom = 장르 번호, 0 이면 열기만)
        if UserDefaults.standard.object(forKey: "ytmOpenRandom") != nil {
            let n = UserDefaults.standard.integer(forKey: "ytmOpenRandom")
            UserDefaults.standard.removeObject(forKey: "ytmOpenRandom")
            RandomPlaylistWindow.shared.show(music: self)
            if n > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 10) { RandomPlaylistWindow.shared.debugPickGenre(n) } }
        }
        // 진단: 재생기 상태 (mediaHubTest = 1 이면 상태만, 2 면 스페이스처럼 토글 후 상태)
        if UserDefaults.standard.object(forKey: "mediaHubTest") != nil {
            let n = UserDefaults.standard.integer(forKey: "mediaHubTest")
            UserDefaults.standard.removeObject(forKey: "mediaHubTest")
            if n == 2 { MediaHub.shared.toggle(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MediaHub.shared.debugDump() } }
            else { MediaHub.shared.debugDump() }
        }
        // 진단: 정밀 EQ 창 열기
        if UserDefaults.standard.bool(forKey: "ytmOpenPEQ") {
            UserDefaults.standard.set(false, forKey: "ytmOpenPEQ")
            PEQWindow.shared.show(music: self)
        }
        // 진단: ytmAnalyzeTest 가 켜져 있으면 한 번 분석해서 결과만 파일로 (적용은 안 함)
        if UserDefaults.standard.bool(forKey: "ytmAnalyzeTest"), TapEQ.shared.running, !TapEQ.shared.isCapturing {
            UserDefaults.standard.set(false, forKey: "ytmAnalyzeTest")
            TapEQ.shared.startCapture(seconds: 10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let prog = TapEQ.shared.captureProgress; let m = TapEQ.shared.finishCapture()
                let out = m.map { "measured=\($0.map { Int($0.rounded()) })\nsuggest=\(Self.suggest(from: $0))\n\(Self.describe(Self.suggest(from: $0)))" } ?? "nil progress=\(prog) running=\(TapEQ.shared.running) playing=\(String(describing: self.state?.playing))"
                try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8)
            }
        }
        // 볼륨을 바꾸면 보정도 따라감
        if Self.loudOn, eqTick % 2 == 0 { updateLoudness() }
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
                    // 도구함을 다시 켜면 주소에 list= 가 없이 이어 재생돼서, 마지막으로 튼 재생목록으로 봄
                    let l = o["list"] as? String ?? ""
                    st.listId = l.isEmpty ? (UserDefaults.standard.string(forKey: "ytmLastList") ?? "") : l
                    if !l.isEmpty { UserDefaults.standard.set(l, forKey: "ytmLastList") }
                    st.videoId = o["vid"] as? String ?? ""
                    // 모바일 화면에선 좋아요 · 반복 · 셔플 버튼을 못 찾을 수 있어서 기본 조작만
                    if o["mobile"] as? Bool == true { st.has = ["prev", "playPause", "next", "mute", "progress", "volume"] }
                } else {
                    // 아직 곡을 틀지 않았거나 로그인 전
                    st.byline = "제목을 눌러 YouTube Music 열기"
                    st.has = []
                }
                if st.has.contains("volume") { self.rememberVolume(st) }
                self.state = st
                self.onUpdate?(st, self.art)
                self.loadArt(st.artURL)
            }
        }
    }

    // MARK: 볼륨 기억 (껐다 켜도 마지막 볼륨 · 음소거 그대로)

    private var volumeRestored = false
    private func rememberVolume(_ st: PlayerState) {
        let ud = UserDefaults.standard
        if !volumeRestored {
            volumeRestored = true
            guard ud.object(forKey: "ytmVolume") != nil else { return }
            let vol = ud.double(forKey: "ytmVolume"), muted = ud.bool(forKey: "ytmMuted")
            if abs(vol - st.volume) > 0.5 { setVolume(vol) }
            if muted != st.muted { press("mute") }
            return
        }
        ud.set(st.volume, forKey: "ytmVolume")
        ud.set(st.muted, forKey: "ytmMuted")
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
          let bs = [...document.querySelectorAll('\(scope) button, \(scope) tp-yt-paper-icon-button')];
          if (!bs.length) bs = [...document.querySelectorAll('button, tp-yt-paper-icon-button')];   // 모바일 화면: 플레이어 줄이 없음
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
    // 플레이어 화면이 닫혀 있으면 잠깐 열어서 가사를 읽고, 다 읽으면 다시 닫음 (보던 검색 · 목록 화면 그대로)
    let opened = false;
    const toggleBtn = () => [...document.querySelectorAll('ytmusic-player-bar button, ytmusic-player-bar tp-yt-paper-icon-button')]
      .find(b => { const a = (b.getAttribute('aria-label') || '').trim().toLowerCase(); return a.includes('플레이어 페이지') || a.includes('player page'); })
      || document.querySelector('ytmusic-player-bar .toggle-player-page-button');
    // 가사 탭으로 바꿨으면 보던 탭(다음 트랙 · 댓글 · 관련 항목)으로 되돌림
    let prevTab = null;
    const closeAgain = () => {
      if (prevTab && prevTab.isConnected && prevTab.getAttribute('aria-selected') !== 'true') prevTab.click();
      if (opened && layout && layout.hasAttribute('player-page-open')) { const b = toggleBtn(); if (b) b.click(); }
    };
    if (layout && !layout.hasAttribute('player-page-open')) {
      if (!mayOpen) return {title, status: 'skip'};
      const b = toggleBtn();
      if (b) { b.click(); opened = true; await sleep(800); }
    }
    try {
    const tab = [...document.querySelectorAll('ytmusic-player-page tp-yt-paper-tab')]
      .find(t => ['가사', 'Lyrics', 'LYRICS'].includes(t.textContent.trim()));
    if (!tab || tab.hasAttribute('disabled') || tab.getAttribute('aria-disabled') === 'true') return {title, status: 'none'};
    if (tab.getAttribute('aria-selected') !== 'true') {
      // YouTube Music 창을 보는 중이면 탭을 건드리지 않음 (댓글 등을 누르면 가사로 끌려가지 않게)
      if (!mayOpen) return {title, status: 'skip'};
      prevTab = [...document.querySelectorAll('ytmusic-player-page tp-yt-paper-tab')].find(t => t.getAttribute('aria-selected') === 'true') || null;
      tab.click(); await sleep(1200);
    }
    const tr = document.querySelector('ytmusic-player-page ytmusic-tab-renderer[page-type="MUSIC_PAGE_TYPE_TRACK_LYRICS"]');
    const sh = tr && tr.querySelector('ytmusic-description-shelf-renderer');
    const text = sh ? ((sh.querySelector('.description') || {}).innerText || '') : '';
    const source = sh ? ((sh.querySelector('.footer') || {}).innerText || '') : '';
    if (!text.trim()) return {title, status: (tr && tr.innerText.trim()) ? 'none' : 'loading'};
    return {title, status: 'ok', text, source};
    } finally { closeAgain(); }
    """

    func fetchLyrics(_ done: @escaping (Lyrics) -> Void) {
        guard let wv = webView else { done(Lyrics(status: "none")); return }
        // YouTube Music 창을 보고 있으면 플레이어 화면을 열지 않음 (검색 결과 등을 가리지 않게)
        let watching = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        wv.callAsyncJavaScript(Self.lyricsJS, arguments: ["mayOpen": !watching], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                guard case .success(let v) = result, let o = v as? [String: Any] else { done(Lyrics(status: "loading")); return }
                // YouTube Music 창을 보고 있어서 가사 탭을 못 읽음: 가사는 다음에 다시 읽되, 곡이 바뀐 건 알려 줌
                // (예전엔 여기서 그냥 끝내서, 창을 보는 동안 곡이 바뀌면 이전 곡 가사가 계속 남았음)
                if o["status"] as? String == "skip" { done(Lyrics(title: o["title"] as? String ?? "", status: "skip")); return }
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
      // 자동재생이 꺼져 있으면 이미 받아 둔 자동재생 곡은 안 나오므로 빼고 보여 줌 (맨 뒤에 있어서 앞 곡 번호는 그대로)
      const autoOn = !!(document.querySelector('#automix') || {}).checked;
      return JSON.stringify(list.map((it, i) => ({
        title: txt(it.querySelector('.song-title')),
        artist: txt(it.querySelector('.byline')),
        dur: txt(it.querySelector('.duration')),
        cur: it.hasAttribute('selected') || ['playing','paused'].includes(it.getAttribute('play-button-state') || ''),
        auto: !!it.closest('#automix-contents'),
        vid: (() => { const w = it.closest('ytmusic-playlist-panel-video-wrapper-renderer');
          const cp = w && w.querySelector('#counterpart-renderer ytmusic-player-queue-item');
          return (cp && cp.data && cp.data.videoId) || (it.data && it.data.videoId) || ''; })(),
        aid: ((it.data && it.data.longBylineText && it.data.longBylineText.runs || []).map(r => r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId).find(x => x && x.startsWith('UC'))) || ''
      })).filter(x => autoOn || !x.auto));
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
                                     current: o["cur"] as? Bool ?? false, index: i,
                                     auto: o["auto"] as? Bool ?? false, artistId: o["aid"] as? String ?? "",
                                     videoId: o["vid"] as? String ?? "")
                })
            }
        }
    }

    func queueClosed() {}

    // MARK: 이퀄라이저 (숨은 페이지의 소리를 Web Audio 필터 10개에 통과시킴 — 도구함에서 나오는 YouTube Music 소리에만)

    static let eqFreqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static var eqOn: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmEQOn") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmEQOn") }
    }
    static var eqGains: [Double] {
        get { (UserDefaults.standard.array(forKey: "ytmEQ") as? [Double]).flatMap { $0.count == 10 ? $0 : nil } ?? Array(repeating: 0, count: 10) }
        set { UserDefaults.standard.set(newValue, forKey: "ytmEQ") }
    }
    /// 고른 프리셋 이름 (직접 바꾸면 "직접 설정")
    static var eqPreset: String {
        get { UserDefaults.standard.string(forKey: "ytmEQPreset") ?? "기본" }
        set { UserDefaults.standard.set(newValue, forKey: "ytmEQPreset") }
    }
    static let eqPresets: [(String, [Double])] = [
        ("기본", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        // 저음 강조: 둥둥 울리는 아래쪽(32 · 64Hz)만 올리고, 먹먹해지는 125 · 250Hz 는 거의 그대로 · 고음을 살짝 살려 또렷하게
        ("저음 강조", [5, 4, 1, 0, -1, 0, 0, 0, 1, 1]),
        ("저음 줄이기", [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        ("고음 강조", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("보컬", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("록", [5, 4, 2, -1, -2, -1, 2, 3, 4, 4]),
        ("팝", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        ("어쿠스틱", [3, 3, 2, 1, 1, 1, 2, 2, 2, 1]),
        ("일렉트로닉", [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        ("작은 스피커", [-4, -2, 1, 3, 3, 2, 1, 1, 0, -1]),
    ]

    /// 켜기 · 끄기 · 값 바꾸기를 오디오 탭에 전달 (웹 페이지 안 Web Audio 로는 YouTube Music 소리를 받지 못해서 맥 쪽에서 처리)
    /// 이퀄라이저나 저음량 보정 중 하나라도 켜져 있으면 탭을 씀
    func applyEQ() {
        Self.migrateEQ()
        updateLoudness()
        TapEQ.shared.setParam(Self.peqOn ? Self.peqFilters : [])
        // 예전에 저장된 값도 같은 규칙으로 (250Hz 아래 올리기 없음)
        let a31 = zip(Self.auto31Gains, TapEQ.thirdOctave).map { $1 < 250 ? min($0, 0) : $0 }
        TapEQ.shared.setAuto(Self.auto31On ? a31 : Array(repeating: 0, count: 31))
        // 청력 보호 표시가 켜져 있으면 소리 크기를 재려고 탭은 켜 두되, 보정이 꺼져 있으면 소리는 그대로 통과
        let effects = Self.masterOn && (Self.eqOn || Self.loudOn || Self.peqOn || Self.auto31On)
        TapEQ.shared.bypass = !effects
        TapEQ.shared.update(on: effects || HearingMeter.on,
                            gains: Self.eqOn ? Self.eqGains : Array(repeating: 0, count: 10))
    }

    /// 소리 보정 전체 (끄면 원래 소리 — 눌러서 비교)
    static var masterOn: Bool {
        get { UserDefaults.standard.object(forKey: "ytmEQMaster") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ytmEQMaster") }
    }

    /// 예전 설정 정리: 곡 분석은 '곡마다 자동 맞춤'(31칸) 하나로 합침
    /// - 10밴드에 들어 있던 '추천' 값은 곡 보정이 두 번 되지 않게 0 으로, 10밴드 자동 추천을 쓰던 사람은 31칸 자동으로
    static func migrateEQ() {
        let d = UserDefaults.standard
        // 프리셋 모양을 바꾼 경우: 그 프리셋을 쓰고 있으면 새 모양으로
        if let p = eqPresets.first(where: { $0.0 == eqPreset }), p.1 != eqGains, !d.bool(forKey: "ytmEQMigrated3") { eqGains = p.1 }
        d.set(true, forKey: "ytmEQMigrated3")
        guard !d.bool(forKey: "ytmEQMigrated2") else { return }
        d.set(true, forKey: "ytmEQMigrated2")
        if autoSuggest { autoSuggest = false; auto31On = true }
        if eqPreset == "추천" { eqGains = Array(repeating: 0, count: 10); eqPreset = "기본" }
    }

    // MARK: 정밀 EQ (점 필터) · 자동 31밴드

    static var peqOn: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmPEQOn") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmPEQOn") }
    }
    static var peqFilters: [EQFilter] {
        get { (UserDefaults.standard.data(forKey: "ytmPEQ")).flatMap { try? JSONDecoder().decode([EQFilter].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "ytmPEQ") }
    }
    static var auto31On: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmAuto31") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmAuto31") }
    }
    static var auto31Gains: [Double] {
        get { (UserDefaults.standard.array(forKey: "ytmAuto31Gains") as? [Double]).flatMap { $0.count == 31 ? $0 : nil } ?? Array(repeating: 0, count: 31) }
        set { UserDefaults.standard.set(newValue, forKey: "ytmAuto31Gains") }
    }

    /// 기준 곡선을 아무 주파수에서나 (10점 사이는 로그 눈금으로 잇고, 양 끝 밖은 기울기대로 늘림)
    static func target(at f: Double) -> Double {
        let fs = YTMusicFreqs, t = targetCurve
        if f <= fs[0] { return t[0] - 4 * log2(fs[0] / f) }
        if f >= fs[fs.count - 1] { return t[t.count - 1] - 6 * log2(f / fs[fs.count - 1]) }
        let i = fs.lastIndex { $0 <= f }!
        let r = log2(f / fs[i]) / log2(fs[i + 1] / fs[i])
        return t[i] + (t[i + 1] - t[i]) * r
    }

    /// 31밴드 추천 — 곡의 성격은 살리고 크게 치우친 곳만 살짝 다듬음
    /// - 기준: 보컬 · 악기가 있는 가운데(250Hz ~ 4kHz)를 0 으로 맞춤 (예전엔 전체 중앙값이라 가운데를 -6dB 까지 파 버려 소리가 텅 비었음)
    /// - 차이의 1/3 만 따라감, 줄이기는 -4dB · 올리기는 +3dB 까지
    /// - 120Hz 아래는 +2dB 까지만 (작게 들을 때 보정이 저음을 따로 채움 — 겹치면 웅웅거림)
    /// - 40Hz 아래 · 12.5kHz 위는 건드리지 않음 (이어폰 · 압축 음원의 끝자락)
    static func suggest31(from measured: [Double]) -> [Double] {
        let fs = TapEQ.thirdOctave
        let d = zip(measured, fs).map { $0 - target(at: $1) }
        let mids = fs.indices.filter { fs[$0] >= 250 && fs[$0] <= 4000 }.map { d[$0] }
        let ref = mids.reduce(0, +) / Double(max(1, mids.count))
        let raw = d.map { -($0 - ref) / 3 }
        let w = [1.0, 2, 3, 2, 1]
        let smooth = raw.indices.map { i -> Double in
            var sum = 0.0, ws = 0.0
            for (j, wj) in w.enumerated() { let k = i + j - 2; if k >= 0 && k < raw.count { sum += raw[k] * wj; ws += wj } }
            return sum / ws
        }
        return smooth.enumerated().map { i, v in
            if fs[i] < 40 || fs[i] > 12500 { return 0 }
            var g = max(-4, min(3, (v * 2).rounded() / 2))
            // 250Hz 아래는 줄이기만 (올리면 먹먹해짐 — 저음은 '내 취향' · '작게 들을 때 보정'이 맡음)
            if fs[i] < 250 { g = min(g, 0) }
            return g == 0 ? 0 : g
        }
    }

    /// 지금 곡을 들어 31밴드 자동 값을 만들고 적용
    func runAuto31(seconds: Double = 8, done: ((Bool) -> Void)? = nil) {
        if !TapEQ.shared.running { applyEQ() }
        let started = Date()
        var began = false
        func step() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let tap = TapEQ.shared
                    if !began {
                        guard tap.running, !tap.isCapturing else {
                            if Date().timeIntervalSince(started) > 8 { done?(false) } else { step() }
                            return
                        }
                        tap.startCapture(seconds: seconds); began = true
                    }
                    if let m = tap.finishCapture(centers: TapEQ.thirdOctave, width: pow(2, 1.0 / 6)) {
                        Self.auto31Gains = Self.suggest31(from: m)
                        self.applyEQ()
                        NotificationCenter.default.post(name: .eqChanged, object: nil)
                        done?(true); return
                    }
                    if Date().timeIntervalSince(started) > seconds + 15 { tap.cancelCapture(); done?(false); return }
                    step()
                }
            }
        }
        step()
    }
    private var auto31Title = ""
    private func auto31Tick() {
        guard Self.auto31On, let st = state, st.playing == true, !st.title.isEmpty, st.title != auto31Title else { return }
        auto31Title = st.title
        let t = st.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state?.title == t else { return }
            self.runAuto31()
        }
    }

    // MARK: 곡 분석 추천 — 지금 곡의 대역별 세기를 '보통 잘 섞인 곡' 기준과 비교해서, 튀는 곳은 줄이고 빈 곳은 채움

    /// 잘 섞인 대중음악의 옥타브별 평균 세기 (1kHz 기준 dB, 32Hz ~ 16kHz)
    static let targetCurve: [Double] = [-5, -1.5, 0, 0.5, 0.5, 0, -1, -2.5, -4.5, -8]

    /// 잰 세기 → 추천 EQ (반만 따라가고 ±6dB 안에서, 이웃 밴드와 부드럽게)
    static func suggest(from measured: [Double]) -> [Double] {
        let d = zip(measured, targetCurve).map { $0 - $1 }
        let mid = d.sorted()[d.count / 2]   // 전체 크기 차이는 빼고 모양만 봄
        let raw = d.map { -($0 - mid) * 0.5 }
        let smooth = raw.indices.map { i -> Double in
            let l = raw[max(0, i - 1)], r = raw[min(raw.count - 1, i + 1)]
            return (l + 2 * raw[i] + r) / 4
        }
        var g = smooth.map { max(-6, min(6, ($0 * 2).rounded() / 2)) }
        // 스트리밍 음원은 16kHz 위를 압축하며 많이 깎아서 비어 보이는 것 — 크게 올리면 잡음만 커짐
        g[9] = min(g[9], 2)
        // 이어폰이 잘 못 내는 아주 낮은 저음도 조금만
        g[0] = min(g[0], 3)
        return g.map { $0 == 0 ? 0 : $0 }
    }

    /// 추천 결과를 한 줄로 (가장 많이 바꾼 곳 위주)
    static func describe(_ g: [Double]) -> String {
        let low = (g[0] + g[1] + g[2]) / 3, mid = (g[4] + g[5] + g[6]) / 3, high = (g[7] + g[8] + g[9]) / 3
        var parts: [String] = []
        if low < -1 { parts.append("저음이 많아 줄이고") } else if low > 1 { parts.append("저음이 약해 채우고") }
        if mid < -1 { parts.append("중음이 두꺼워 덜고") } else if mid > 1 { parts.append("보컬 쪽을 살리고") }
        if high < -1 { parts.append("고음이 날카로워 누그러뜨렸어요") } else if high > 1 { parts.append("고음을 밝게 했어요") }
        if parts.isEmpty { return "이미 고르게 섞인 곡이라 거의 바꾸지 않았어요" }
        // 마지막 말을 끝맺음으로 (줄이고 → 줄였어요)
        let ends = ["줄이고": "줄였어요", "채우고": "채웠어요", "덜고": "덜었어요", "살리고": "살렸어요"]
        if let last = parts.last, let k = ends.keys.first(where: { last.hasSuffix($0) }) {
            parts[parts.count - 1] = String(last.dropLast(k.count)) + ends[k]!
        }
        return parts.joined(separator: " ")
    }

    /// 지금 곡을 seconds 초 듣고 추천 EQ 를 만듦 (탭이 꺼져 있으면 켬). progress 0~1
    func analyzeSong(seconds: Double = 10, progress: @escaping (Double) -> Void, done: @escaping ([Double]?) -> Void) {
        if !TapEQ.shared.running {
            Self.eqOn = true
            applyEQ()
        }
        let started = Date()
        var began = false
        func step() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let tap = TapEQ.shared
                    if !began {
                        guard tap.running else {
                            if Date().timeIntervalSince(started) > 6 { done(nil) } else { step() }
                            return
                        }
                        tap.startCapture(seconds: seconds); began = true
                    }
                    if let m = tap.finishCapture() { done(Self.suggest(from: m)); return }
                    if Date().timeIntervalSince(started) > seconds + 15 { tap.cancelCapture(); done(nil); return }
                    progress(tap.captureProgress)
                    step()
                }
            }
        }
        step()
    }

    /// 추천을 적용 (원래 값은 eqBeforeSuggest 에 기억 → '원래대로')
    func applySuggestion(_ g: [Double]) {
        if Self.eqPreset != "추천" { UserDefaults.standard.set(Self.eqGains, forKey: "ytmEQBefore"); UserDefaults.standard.set(Self.eqPreset, forKey: "ytmEQBeforePreset") }
        Self.eqGains = g
        Self.eqPreset = "추천"
        Self.eqOn = true
        applyEQ()
        NotificationCenter.default.post(name: .eqChanged, object: nil)
    }
    func revertSuggestion() {
        guard let g = UserDefaults.standard.array(forKey: "ytmEQBefore") as? [Double], g.count == 10 else { return }
        Self.eqGains = g
        Self.eqPreset = UserDefaults.standard.string(forKey: "ytmEQBeforePreset") ?? "기본"
        applyEQ()
        NotificationCenter.default.post(name: .eqChanged, object: nil)
    }

    /// 자동 추천: 곡이 바뀌고 5초 뒤(앞부분 조용한 곳을 지나서) 8초 듣고 적용
    private func autoSuggestTick() {
        guard Self.autoSuggest, let st = state, st.playing == true, !st.title.isEmpty else { return }
        guard st.title != autoTitle else { return }
        autoTitle = st.title
        let t = st.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state?.title == t, !TapEQ.shared.isCapturing else { return }
            self.analyzeSong(seconds: 8, progress: { _ in }) { [weak self] g in
                guard let self, let g, self.state?.title == t else { return }
                self.applySuggestion(g)
                self.lastSuggestNote = "‘\(t)’ · " + Self.describe(g)
            }
        }
    }
    private var autoTitle = ""
    /// 마지막 자동 추천 설명 (팝업에 보여 줌)
    var lastSuggestNote = ""

    /// 곡이 바뀔 때마다 자동으로 분석 · 적용
    static var autoSuggest: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmEQAuto") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmEQAuto") }
    }

    // MARK: 저음량 보정 — 작게 들을수록 귀가 저음 · 고음을 덜 느끼는 만큼 채워 줌

    static var loudOn: Bool {
        get { UserDefaults.standard.bool(forKey: "ytmLoudOn") }
        set { UserDefaults.standard.set(newValue, forKey: "ytmLoudOn") }
    }
    /// 세기 (0 ~ 1.5, 기본 1)
    static var loudStrength: Double {
        get { UserDefaults.standard.object(forKey: "ytmLoudStrength") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "ytmLoudStrength") }
    }

    /// 지금 얼마나 작게 듣는지(YouTube Music 볼륨 + 이어폰 · 스피커 볼륨)로 올릴 저음 · 고음을 정함
    /// - 기준: 둘 다 합쳐 -10dB 정도까지는 보정 없음, 그보다 작을수록 저음은 0.35배 · 고음은 0.15배씩 (최대 +12 · +6dB)
    ///   (사람 귀의 등청감 곡선을 단순하게 맞춘 값)
    func updateLoudness() {
        guard Self.loudOn else { TapEQ.shared.setLoudness(bass: 0, treble: 0); return }
        let vol = max(0.5, (state?.muted == true ? 0 : (state?.volume ?? 100)))
        let pageDB = 20 * log10(vol / 100)
        let atten = -(pageDB + TapEQ.outputVolumeDB())
        let over = max(0, atten - 10) * Self.loudStrength
        TapEQ.shared.setLoudness(bass: min(12, over * 0.35), treble: min(6, over * 0.15))
    }
    private var eqTick = 0

    // MARK: 이 곡의 앨범 재생 (섞인 다음 트랙에서 마음에 드는 곡 → 그 앨범으로)
    // 다음 트랙 곡엔 앨범 정보가 없어서: 그 곡의 '노래' 버전 → YouTube Music 이 주는 앨범 → 앨범 재생목록(OLAK…) 순서로 찾음

    struct AlbumInfo { let videoId: String; let albumId: String; let name: String; let playlist: String }

    private static let albumJS = """
    const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter(i => !i.closest('#counterpart-renderer'));
    const it = list[idx];
    if (!it) return null;
    const w = it.closest('ytmusic-playlist-panel-video-wrapper-renderer');
    const cp = w && w.querySelector('#counterpart-renderer ytmusic-player-queue-item');
    const cands = [cp && cp.data && cp.data.videoId, it.data && it.data.videoId].filter(Boolean);
    const ctx = ytcfg.get('INNERTUBE_CONTEXT');
    const post = async (p, b) => (await fetch('/youtubei/v1/' + p + '?prettyPrint=false', {method: 'POST',
      headers: {'Content-Type': 'application/json'}, body: JSON.stringify(Object.assign({context: ctx}, b))})).text();
    for (const v of cands) {
      const s = await post('next', {videoId: v, isAudioOnly: true});
      const m = s.match(/"text":"([^"]+)","navigationEndpoint":\\{"clickTrackingParams":"[^"]*","browseEndpoint":\\{"browseId":"(MPRE[^"]+)"/)
             || s.match(/()"browseId":"(MPRE[^"]+)"/);
      if (!m) continue;
      const b = await post('browse', {browseId: m[2]});
      const pl = (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1];
      if (pl) return {vid: v, album: m[2], name: m[1] || '', list: pl};
    }
    return null;
    """

    func findAlbum(_ item: QueueItem, done: @escaping (AlbumInfo?) -> Void) {
        guard let wv = webView else { done(nil); return }
        wv.callAsyncJavaScript(Self.albumJS, arguments: ["idx": item.index], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let o = v as? [String: Any],
                      let vid = o["vid"] as? String, let al = o["album"] as? String, let pl = o["list"] as? String else { done(nil); return }
                done(AlbumInfo(videoId: vid, albumId: al, name: o["name"] as? String ?? "", playlist: pl))
            }
        }
    }

    /// 앨범 재생: fromSong 이면 그 곡부터, 아니면 첫 곡부터 (지금 다음 트랙은 그 앨범으로 바뀜)
    func playAlbum(_ a: AlbumInfo, fromSong: Bool) {
        playList(a.playlist, from: fromSong ? a.videoId : nil)
    }

    /// 재생목록(OLAK…) 재생 + 자동재생 끄기 (앨범이 끝나면 섞인 곡이 이어 붙지 않게)
    func playList(_ list: String, from video: String? = nil) {
        guard let wv = webView else { return }
        var c = URLComponents(string: "https://music.youtube.com/watch")!
        c.queryItems = (video.map { [URLQueryItem(name: "v", value: $0)] } ?? []) + [URLQueryItem(name: "list", value: list)]
        guard let u = c.url else { return }
        wv.load(URLRequest(url: u))
        // 페이지가 다 뜨는 시간이 들쭉날쭉해서 몇 번 확인
        for t in [3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.setAutoplay(false) }
        }
    }

    /// 한 곡만 재생 (자동재생 끔 — 끝나면 엉뚱한 곡이 이어지지 않게)
    func playVideo(_ vid: String) {
        guard let wv = webView, let u = URL(string: "https://music.youtube.com/watch?v=\(vid)") else { return }
        wv.load(URLRequest(url: u))
        for t in [3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.setAutoplay(false) }
        }
    }

    /// 다음 트랙 아래 '자동재생' 스위치
    func setAutoplay(_ on: Bool) {
        webView?.evaluateJavaScript("(() => { const t = document.querySelector('#automix'); if (t && !!t.checked !== \(on)) t.click(); return t ? t.checked : null; })()")
    }

    /// 앨범 페이지 ID(MPREb…) 로 재생 (첫 곡부터)
    func playAlbum(id: String, done: @escaping (Bool) -> Void) {
        guard let wv = webView else { done(false); return }
        wv.callAsyncJavaScript("""
        const ctx = ytcfg.get('INNERTUBE_CONTEXT');
        const b = await (await fetch('/youtubei/v1/browse?prettyPrint=false', {method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({context: ctx, browseId: id})})).text();
        return (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1] || null;
        """, arguments: ["id": id], in: nil, in: .page) { [weak self] r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let list = v as? String else { done(false); return }
                self?.playList(list)
                done(true)
            }
        }
    }

    /// 앨범 수록곡 (앨범 페이지 ID MPREb… → 재생목록 OLAK… · 곡들)
    func albumTracks(id: String, done: @escaping (_ list: String?, _ tracks: [QueueItem]) -> Void) {
        guard let wv = webView else { done(nil, []); return }
        wv.callAsyncJavaScript("""
        const ctx = ytcfg.get('INNERTUBE_CONTEXT');
        const j = await (await fetch('/youtubei/v1/browse?prettyPrint=false', {method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({context: ctx, browseId: id})})).json();
        const b = JSON.stringify(j);
        const list = (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1] || null;
        const out = [];
        const all = []; JSON.stringify(j, (k, v) => { if (k === 'musicResponsiveListItemRenderer') all.push(v); return v; });
        for (const v of all) {
          const vid = v.playlistItemData && v.playlistItemData.videoId;
          if (!vid) continue;
          const col = i => ((v.flexColumns || [])[i] || {}).musicResponsiveListItemFlexColumnRenderer;
          const t = ((col(0) || {}).text || {}).runs; const ar = ((col(1) || {}).text || {}).runs;
          const fx = v.fixedColumns && v.fixedColumns[0] && v.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
          out.push({title: t ? t.map(r => r.text).join('') : '', artist: ar ? ar.map(r => r.text).join('') : '',
                    dur: fx && fx.text && fx.text.runs ? fx.text.runs[0].text : '', vid});
        }
        return JSON.stringify({list, out});
        """, arguments: ["id": id], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let s = v as? String, let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { done(nil, []); return }
                let arr = o["out"] as? [[String: String]] ?? []
                done(o["list"] as? String, arr.enumerated().map { i, t in
                    QueueItem(title: t["title"] ?? "", artist: t["artist"] ?? "", duration: t["dur"] ?? "", current: false, index: i, videoId: t["vid"] ?? "")
                })
            }
        }
    }

    /// 지금 곡의 가수 페이지 ID (플레이어 줄 아티스트 링크)
    func currentArtistId(_ done: @escaping (String?) -> Void) {
        webView?.evaluateJavaScript("""
        (() => { const a = [...document.querySelectorAll('ytmusic-player-bar .byline a')].find(a => (a.getAttribute('href') || '').includes('channel/UC'));
          return a ? a.getAttribute('href').split('channel/')[1].split(/[?&]/)[0] : null; })()
        """) { r, _ in MainActor.assumeIsolated { done(r as? String) } }
    }

    /// 가수의 앨범 · 싱글 및 EP 전부 (더 보기 링크가 있으면 그 목록까지)
    func artistAlbums(_ artistId: String, done: @escaping (String, [AlbumEntry]) -> Void) {
        guard let wv = webView else { done("", []); return }
        wv.callAsyncJavaScript("""
        const ctx = ytcfg.get('INNERTUBE_CONTEXT');
        const post = async (b) => (await fetch('/youtubei/v1/browse?prettyPrint=false', {method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(Object.assign({context: ctx}, b))})).json();
        const r = await post({browseId: aid});
        const name = (JSON.stringify(r).match(/"musicImmersiveHeaderRenderer":\\{"title":\\{"runs":\\[\\{"text":"([^"]+)"/) ||
                      JSON.stringify(r).match(/"musicVisualHeaderRenderer":\\{"title":\\{"runs":\\[\\{"text":"([^"]+)"/) || [])[1] || '';
        const shelves = []; JSON.stringify(r, (k, v) => { if (k === 'musicCarouselShelfRenderer') shelves.push(v); return v; });
        const pick = (o) => { const out = []; JSON.stringify(o, (k, v) => { if (k === 'musicTwoRowItemRenderer') out.push(v); return v; }); return out; };
        const conv = (i, sec) => {
          const id = i.navigationEndpoint && i.navigationEndpoint.browseEndpoint && i.navigationEndpoint.browseEndpoint.browseId;
          const th = ((i.thumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
          return {t: (i.title.runs || [])[0].text, sub: (i.subtitle && i.subtitle.runs || []).map(x => x.text).join(''), id, th: th ? th.url : '', sec};
        };
        const out = [];
        for (const s of shelves) {
          const h = s.header && s.header.musicCarouselShelfBasicHeaderRenderer;
          const title = h && h.title && h.title.runs && h.title.runs[0].text || '';
          if (!/^(앨범|싱글|Albums|Singles)/.test(title)) continue;
          const more = (h.title.runs[0].navigationEndpoint && h.title.runs[0].navigationEndpoint.browseEndpoint)
                    || (h.moreContentButton && h.moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint);
          let items = pick(s.contents);
          if (more) { try { const m = pick(await post({browseId: more.browseId, params: more.params})); if (m.length) items = m; } catch (e) {} }
          for (const i of items) { const c = conv(i, title); if (c.id && c.id.startsWith('MPRE')) out.push(c); }
        }
        return JSON.stringify({name, out});
        """, arguments: ["aid": artistId], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let json = v as? String, let data = json.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { done("", []); return }
                let arr = (o["out"] as? [[String: Any]] ?? []).map {
                    AlbumEntry(title: $0["t"] as? String ?? "", sub: $0["sub"] as? String ?? "", id: $0["id"] as? String ?? "",
                               thumb: $0["th"] as? String ?? "", section: $0["sec"] as? String ?? "")
                }
                done(o["name"] as? String ?? "", arr)
            }
        }
    }

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

extension Notification.Name {
    static let eqChanged = Notification.Name("eqChanged")
}
