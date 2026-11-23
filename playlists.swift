// 재생목록 편집: 로그인된 YouTube Music 계정의 재생목록을 도구함에서 바로 고침 (휴대폰 앱에도 그대로 보임)
// 숨은 페이지 안에서 로그인 쿠키로 서명한 요청(SAPISIDHASH)을 보냄 — 쿠키 · 서명은 페이지 밖으로 안 나감
import Cocoa
import WebKit

struct PlaylistInfo: Equatable {
    let id: String      // PL… (앞의 VL 뺀 것)
    let title: String
    let sub: String
}

struct PlaylistTrack: Equatable {
    let title: String
    let artist: String
    let duration: String
    let videoId: String
    let setId: String   // 재생목록 안 자리 ID (빼기 · 옮기기에 씀)
    let thumb: String
    /// 가수 페이지 ID (UC…) — 가수 링크가 있을 때만
    var artistId = ""
}

/// 재생목록 전체 곡 수 (다음 트랙이 50곡씩만 불러와서, 전체가 몇 곡인지 보여 줄 때 씀)
@MainActor enum PlaylistCount {
    static var cache: [String: (n: Int, at: Date)] = [:]
    static var loading = Set<String>()
    static func get(_ id: String, music: YTMusic?, changed: @escaping () -> Void) -> Int? {
        if let c = cache[id], Date().timeIntervalSince(c.at) < 60 { return c.n }
        if !loading.contains(id), let music {
            loading.insert(id)
            music.playlistTracks(id) { ts in
                loading.remove(id)
                if let ts { cache[id] = (ts.count, Date()); changed() }
            }
        }
        return cache[id]?.n
    }
}

extension YTMusic {
    /// 페이지 안 요청 도우미 (매번 앞에 붙여 실행)
    static let apiPrelude = """
    const api = async (path, body) => {
      const ck = document.cookie.split('; ');
      const c = ck.find(x => x.startsWith('SAPISID=')) || ck.find(x => x.startsWith('__Secure-3PAPISID='));
      const origin = 'https://music.youtube.com';
      const h = {'Content-Type': 'application/json', 'X-Origin': origin, 'X-Goog-AuthUser': String(ytcfg.get('SESSION_INDEX') || 0)};
      if (c) {
        const ts = Math.floor(Date.now() / 1000);
        const buf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + c.split('=')[1] + ' ' + origin));
        h['Authorization'] = 'SAPISIDHASH ' + ts + '_' + [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
      }
      const r = await fetch('/youtubei/v1/' + path + '?prettyPrint=false', {method: 'POST', headers: h,
        body: JSON.stringify(Object.assign({context: ytcfg.get('INNERTUBE_CONTEXT')}, body))});
      return r.json();
    };
    const collect = (o, key) => { const out = []; JSON.stringify(o, (k, v) => { if (k === key) out.push(v); return v; }); return out; };
    const nextToken = (o) => { const s = JSON.stringify(o);
      return (s.match(/"continuationCommand":\\{"token":"([^"]+)"/) || s.match(/"nextContinuationData":\\{"continuation":"([^"]+)"/) || [])[1]; };
    const albumList = async (id) => { const b = JSON.stringify(await api('browse', {browseId: id}));
      return (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1] || null; };
    """

    private func runAPI(_ body: String, _ args: [String: Any] = [:], done: @escaping (Any?) -> Void) {
        guard let wv = webView else { done(nil); return }
        wv.callAsyncJavaScript(Self.apiPrelude + body, arguments: args, in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                if case .success(let v) = r { done(v) } else { done(nil) }
            }
        }
    }
    private func json(_ v: Any?) -> Any? {
        guard let s = v as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// 내 재생목록 (좋아요 표시한 음악 등 자동 목록은 뺌 — 고칠 수 없어서)
    func myPlaylists(_ done: @escaping ([PlaylistInfo]) -> Void) {
        runAPI("""
        const j = await api('browse', {browseId: 'FEmusic_liked_playlists'});
        return JSON.stringify(collect(j, 'musicTwoRowItemRenderer').map(i => ({
          t: (i.title.runs || [])[0].text, id: (i.navigationEndpoint && i.navigationEndpoint.browseEndpoint || {}).browseId || '',
          sub: (i.subtitle && i.subtitle.runs || []).map(x => x.text).join('')
        })).filter(x => x.id.startsWith('VLPL')));
        """) { [weak self] v in
            let arr = self?.json(v) as? [[String: Any]] ?? []
            done(arr.map { PlaylistInfo(id: String(($0["id"] as? String ?? "").dropFirst(2)), title: $0["t"] as? String ?? "", sub: $0["sub"] as? String ?? "") })
        }
    }

    /// 재생목록 곡 전부 (100곡 넘으면 다음 쪽까지)
    func playlistTracks(_ id: String, done: @escaping ([PlaylistTrack]?) -> Void) {
        runAPI("""
        let j = await api('browse', {browseId: 'VL' + pid});
        const out = [];
        const txt = c => ((c && c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map(x => x.text).join('');
        for (let page = 0; page < 30; page++) {
          for (const i of collect(j, 'musicResponsiveListItemRenderer')) {
            const d = i.playlistItemData; if (!d || !d.playlistSetVideoId) continue;
            const fx = i.fixedColumns && i.fixedColumns[0] && i.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
            const th = ((i.thumbnail && i.thumbnail.musicThumbnailRenderer && i.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
            const ar = ((i.flexColumns[1] && i.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs) || [])
              .map(x => x.navigationEndpoint && x.navigationEndpoint.browseEndpoint && x.navigationEndpoint.browseEndpoint.browseId).find(x => x && x.startsWith('UC')) || '';
            out.push({t: txt(i.flexColumns[0]), a: txt(i.flexColumns[1]), d: fx ? (fx.text.runs || [{}])[0].text || '' : '',
                      v: d.videoId, s: d.playlistSetVideoId, th: th ? th.url : '', ar});
          }
          const tok = nextToken(j); if (!tok) break;
          j = await api('browse', {continuation: tok});
        }
        return JSON.stringify(out);
        """, ["pid": id]) { [weak self] v in
            guard let arr = self?.json(v) as? [[String: Any]] else { done(nil); return }
            var seen = Set<String>()
            done(arr.compactMap {
                let s = $0["s"] as? String ?? ""
                guard seen.insert(s).inserted else { return nil }
                return PlaylistTrack(title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "", duration: $0["d"] as? String ?? "",
                                     videoId: $0["v"] as? String ?? "", setId: s, thumb: $0["th"] as? String ?? "",
                                     artistId: $0["ar"] as? String ?? "")
            })
        }
    }

    /// 새 재생목록 (비공개). 곡을 같이 넣을 수 있음
    func createPlaylist(_ title: String, videoIds: [String] = [], done: @escaping (String?) -> Void) {
        runAPI("""
        const j = await api('playlist/create', {title: name, description: '', privacyStatus: 'PRIVATE', videoIds: vids});
        return j.playlistId || null;
        """, ["name": title, "vids": videoIds]) { v in done(v as? String) }
    }

    /// 재생목록 통째로 지우기 (유튜브 뮤직 계정에서도 지워짐 · 되돌릴 수 없음)
    func deletePlaylist(_ id: String, done: @escaping (Bool) -> Void) {
        runAPI("""
        const j = await api('playlist/delete', {playlistId: pid});
        return !j.error;
        """, ["pid": id]) { v in done(v as? Bool ?? false) }
    }

    /// 곡 넣기 (이미 있는 곡은 건너뜀). videoIds 와 앨범(MPREb…) 을 섞어 넣을 수 있음
    func addToPlaylist(_ id: String, videoIds: [String], albumIds: [String] = [], done: @escaping (Bool) -> Void) {
        runAPI("""
        const actions = vids.map(v => ({action: 'ACTION_ADD_VIDEO', addedVideoId: v, dedupeOption: 'DEDUPE_OPTION_SKIP'}));
        for (const a of albums) { const l = await albumList(a); if (l) actions.push({action: 'ACTION_ADD_PLAYLIST', addedFullListId: l, dedupeOption: 'DEDUPE_OPTION_SKIP'}); }
        if (!actions.length) return false;
        const j = await api('browse/edit_playlist', {playlistId: pid, actions});
        return j.status === 'STATUS_SUCCEEDED';
        """, ["pid": id, "vids": videoIds, "albums": albumIds]) { v in done(v as? Bool ?? false) }
    }

    func removeFromPlaylist(_ id: String, _ t: PlaylistTrack, done: @escaping (Bool) -> Void) {
        runAPI("""
        const j = await api('browse/edit_playlist', {playlistId: pid, actions: [{action: 'ACTION_REMOVE_VIDEO', setVideoId: sid, removedVideoId: vid}]});
        return j.status === 'STATUS_SUCCEEDED';
        """, ["pid": id, "sid": t.setId, "vid": t.videoId]) { v in done(v as? Bool ?? false) }
    }

    /// 곡을 before 곡 앞으로 (before 가 nil 이면 맨 끝으로)
    func moveInPlaylist(_ id: String, setId: String, before: String?, done: @escaping (Bool) -> Void) {
        runAPI("""
        const a = {action: 'ACTION_MOVE_VIDEO_BEFORE', setVideoId: sid};
        if (before) a.movedSetVideoIdSuccessor = before;
        const j = await api('browse/edit_playlist', {playlistId: pid, actions: [a]});
        return j.status === 'STATUS_SUCCEEDED';
        """, ["pid": id, "sid": setId, "before": before ?? NSNull()]) { v in done(v as? Bool ?? false) }
    }
}

// MARK: - 재생목록 탭: 고르기 · 재생 · 끌어서 순서 바꾸기 · ⊖ 빼기 · 되돌리기 · 새 재생목록

@MainActor
final class PlaylistPane: NSView {
    private weak var music: YTMusic?
    private let picker = NSPopUpButton()
    private let playBtn = NSButton()
    private let newBtn = NSButton()
    private let delBtn = NSButton()
    private let randBtn = NSButton()
    private let undoBtn = NSButton(title: "되돌리기", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private var lists: [PlaylistInfo] = []
    private(set) var tracks: [PlaylistTrack] = []
    /// 방금 뺀 곡 (되돌리기용: 그 곡 · 원래 뒤에 있던 곡)
    private var removed: (PlaylistTrack, String?)?
    var toast: ((String) -> Void)?

    static var selectedId: String {
        get { UserDefaults.standard.string(forKey: "ytmPlaylist") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ytmPlaylist") }
    }
    var current: PlaylistInfo? { lists.first { $0.id == Self.selectedId } }
    var playlists: [PlaylistInfo] { lists }

    override var isFlipped: Bool { true }

    init(music: YTMusic?) {
        self.music = music
        super.init(frame: .zero)
        picker.controlSize = .small
        picker.target = self; picker.action = #selector(picked)
        addSubview(picker)
        for (b, sym, tip, act) in [(playBtn, "play.circle.fill", "이 재생목록 재생", #selector(playAll)),
                                   (newBtn, "plus.circle", "새 재생목록", #selector(newList)),
                                   (delBtn, "trash", "재생목록 지우기 (여러 개 골라서)", #selector(deleteList)),
                                   (randBtn, "dice", "랜덤 재생목록 만들기 (가수 · 비중 · 곡 수 · 시간)", #selector(openRandom))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.isBordered = false; b.toolTip = tip; b.target = self; b.action = act
            b.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            addSubview(b)
        }
        undoBtn.isBordered = false
        undoBtn.font = .systemFont(ofSize: 11, weight: .medium)
        undoBtn.contentTintColor = .launcherAccent
        undoBtn.target = self; undoBtn.action = #selector(undo)
        undoBtn.isHidden = true
        addSubview(undoBtn)
        scroll.documentView = doc
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        addSubview(scroll)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        undoBtn.sizeToFit()
        let uw = undoBtn.isHidden ? 0 : undoBtn.frame.width + 6
        delBtn.frame = NSRect(x: w - 26, y: 2, width: 24, height: 24)
        newBtn.frame = NSRect(x: delBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        randBtn.frame = NSRect(x: newBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        playBtn.frame = NSRect(x: randBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        undoBtn.frame = NSRect(x: playBtn.frame.minX - uw, y: 5, width: uw - 6, height: 18)
        picker.frame = NSRect(x: 4, y: 2, width: max(80, playBtn.frame.minX - uw - 10), height: 24)
        scroll.frame = NSRect(x: 0, y: 32, width: w, height: bounds.height - 32)
        status.frame = NSRect(x: 0, y: scroll.frame.midY - 9, width: w, height: 18)
        stack()
    }

    // MARK: 불러오기

    private var loading = false
    /// 방금 지운 재생목록 (서버 목록에 잠깐 남아 있어도 숨김)
    static var recentlyDeleted = Set<String>()

    /// 고르기 칸 · 곡 목록을 이 목록으로
    private func applyLists(_ ls: [PlaylistInfo]) {
        lists = ls
        picker.removeAllItems()
        for l in ls { picker.menu?.addItem(NSMenuItem(title: l.title, action: nil, keyEquivalent: "")) }
        if !ls.contains(where: { $0.id == Self.selectedId }) { Self.selectedId = ls.first?.id ?? "" }
        if let i = ls.firstIndex(where: { $0.id == Self.selectedId }) { picker.selectItem(at: i) }
        if ls.isEmpty { status.stringValue = "재생목록이 없어요 · ⊕ 로 새로 만들어요"; status.isHidden = false }
        loadTracks()
    }
    /// 재생목록 탭을 열 때: 내 재생목록 중 하나를 듣는 중이면 그 목록을 보여 줌 (보는 목록과 나오는 곡이 달라 헷갈리지 않게)
    func followPlaying() {
        guard let l = music?.state?.listId, l.hasPrefix("PL"), l != Self.selectedId, lists.contains(where: { $0.id == l }) else { return }
        Self.selectedId = l
        if let i = lists.firstIndex(where: { $0.id == l }) { picker.selectItem(at: i) }
        loadTracks()
    }
    /// 곡이 바뀌면 '지금 재생 중' 표시를 옮김
    private var lastVid = ""
    func tickPlaying() {
        let v = music?.state?.videoId ?? ""
        guard v != lastVid else { return }
        lastVid = v
        if !tracks.isEmpty { show(tracks) }
    }

    func reload(lists again: Bool = true) {
        if again || lists.isEmpty {
            guard !loading else { return }
            loading = true
            if tracks.isEmpty { status.stringValue = "재생목록 불러오는 중…"; status.isHidden = false }
            music?.myPlaylists { [weak self] all in
                guard let self else { return }
                let ls = all.filter { !Self.recentlyDeleted.contains($0.id) }
                self.loading = false
                // 실패(페이지가 아직 덜 떠서 빈 응답)면 고른 목록을 지우지 않고 다음 시도를 기다림
                if ls.isEmpty { return }
                self.lists = ls
                // 이름이 같은 재생목록이 있어도 하나로 합쳐지지 않게 한 줄씩 (addItems 는 같은 이름을 합쳐 순서가 밀렸음)
                self.picker.removeAllItems()
                for l in ls { self.picker.menu?.addItem(NSMenuItem(title: l.title, action: nil, keyEquivalent: "")) }
                if !ls.contains(where: { $0.id == Self.selectedId }) { Self.selectedId = ls.first?.id ?? "" }
                // 내 재생목록 중 하나를 듣는 중이면 그 목록부터
                if let l = self.music?.state?.listId, ls.contains(where: { $0.id == l }) { Self.selectedId = l }
                if let i = ls.firstIndex(where: { $0.id == Self.selectedId }) { self.picker.selectItem(at: i) }
                if ls.isEmpty { self.status.stringValue = "재생목록이 없어요 · ⊕ 로 새로 만들어요" }
                self.loadTracks()
            }
        } else { loadTracks() }
    }

    private func loadTracks() {
        guard !Self.selectedId.isEmpty else { show([]); return }
        let id = Self.selectedId
        music?.playlistTracks(id) { [weak self] ts in
            guard let self, Self.selectedId == id else { return }
            guard let ts else { self.status.stringValue = "불러오지 못했어요 (로그인 확인)"; self.status.isHidden = false; return }
            self.show(ts)
        }
    }

    private func show(_ ts: [PlaylistTrack]) {
        tracks = ts
        doc.subviews.forEach { $0.removeFromSuperview() }
        let playingHere = music?.state?.listId == Self.selectedId
        let nowVid = music?.state?.videoId ?? ""
        for (i, t) in ts.enumerated() {
            let r = PlaylistRow(t, index: i)
            if playingHere && t.videoId == nowVid { r.markPlaying() }
            r.onPlay = { [weak self] in self?.play(from: t) }
            r.onRemove = { [weak self] in self?.remove(t) }
            r.onDrag = { [weak self] row, y, done in self?.dragging(row, y: y, done: done) }
            doc.addSubview(r)
        }
        status.stringValue = ts.isEmpty ? "빈 재생목록이에요\n다음 트랙 · 앨범에서 곡을 넣어 보세요" : ""
        status.isHidden = !ts.isEmpty
        stack()
    }

    private func stack() {
        let w = scroll.contentSize.width
        let rows = doc.subviews.compactMap { $0 as? PlaylistRow }   // 끌 때 나오는 선은 빼고
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * PlaylistRow.rowH, width: w, height: PlaylistRow.rowH)
            r.needsLayout = true
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(rows.count) * PlaylistRow.rowH)
    }

    // MARK: 조작

    @objc private func picked() {
        guard picker.indexOfSelectedItem >= 0, picker.indexOfSelectedItem < lists.count else { return }
        Self.selectedId = lists[picker.indexOfSelectedItem].id
        removed = nil; undoBtn.isHidden = true
        loadTracks()
    }

    @objc private func playAll() {
        guard !Self.selectedId.isEmpty else { return }
        music?.playList(Self.selectedId)
        toast?("‘\(current?.title ?? "재생목록")’ 재생")
    }
    private func play(from t: PlaylistTrack) { music?.playList(Self.selectedId, from: t.videoId) }

    @objc private func newList() {
        Self.askName { [weak self] name in
            self?.music?.createPlaylist(name) { id in
                guard let self, let id else { self?.toast?("만들지 못했어요"); return }
                Self.selectedId = id
                self.toast?("‘\(name)’ 재생목록을 만들었어요")
                self.reload()
            }
        }
    }

    /// 🎲 랜덤 재생목록 창 (지금 곡의 가수를 먼저 넣어 둠)
    @objc private func openRandom() {
        let w = RandomPlaylistWindow.shared
        // 만들거나 덧붙인 뒤: 서버 목록이 늦게 바뀌어서 바로 · 3초 · 8초 뒤에 다시 받음
        w.onCreated = { [weak self] _ in
            self?.reload()
            for t in [3.0, 8.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.reload() } }
        }
        music?.currentArtistId { [weak self] id in
            let name = self?.music?.state?.byline.components(separatedBy: " • ").first ?? ""
            w.show(music: self?.music, start: id.map { ArtistHit(id: $0, name: name) })
        }
    }

    /// 지금 고른 재생목록을 통째로 지우기 (한 번 물어봄)
    /// 재생목록 지우기: 체크해서 여러 개 한 번에 (지금 보고 있는 목록은 미리 체크)
    @objc private func deleteList() {
        guard !lists.isEmpty else { return }
        // 1) 고르기: 체크 목록 (+ 모두 선택 · 모두 해제)
        let rowH: CGFloat = 22, w: CGFloat = 320
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: CGFloat(lists.count) * rowH))
        var boxes: [NSButton] = []
        for (i, pl) in lists.enumerated() {
            let b = NSButton(checkboxWithTitle: pl.sub.isEmpty ? pl.title : "\(pl.title)  ·  \(pl.sub)", target: nil, action: nil)
            b.state = pl.id == Self.selectedId ? .on : .off
            b.lineBreakMode = .byTruncatingTail
            b.frame = NSRect(x: 4, y: CGFloat(i) * rowH, width: w - 8, height: rowH)
            doc.addSubview(b); boxes.append(b)
        }
        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: min(300, CGFloat(lists.count) * rowH)))
        sc.documentView = doc; sc.hasVerticalScroller = true; sc.borderType = .bezelBorder
        let pick = NSAlert()
        pick.messageText = "지울 재생목록을 골라 주세요"
        pick.informativeText = "여러 개를 체크하면 한 번에 지워요"
        pick.accessoryView = sc
        pick.addButton(withTitle: "고른 것 지우기…")
        pick.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard pick.runModal() == .alertFirstButtonReturn else { return }
        let chosen = zip(lists, boxes).filter { $0.1.state == .on }.map(\.0)
        guard !chosen.isEmpty else { return }
        // 2) 한 번 더 확인 (되돌릴 수 없어서)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = chosen.count == 1 ? "‘\(chosen[0].title)’ 재생목록을 지울까요?" : "재생목록 \(chosen.count)개를 지울까요?"
        let names = chosen.prefix(8).map { "· \($0.title)" }.joined(separator: "\n") + (chosen.count > 8 ? "\n… 외 \(chosen.count - 8)개" : "")
        a.informativeText = names + "\n\n유튜브 뮤직 계정에서도 지워져요 (휴대폰 앱 포함). 되돌릴 수 없어요."
        a.addButton(withTitle: chosen.count == 1 ? "지우기" : "\(chosen.count)개 지우기")
        a.addButton(withTitle: "취소")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // 3) 차례로 지우기
        var left = chosen, okCount = 0
        func next() {
            guard let pl = left.first else {
                toast?(okCount == chosen.count ? "재생목록 \(okCount)개를 지웠어요" : "\(chosen.count)개 중 \(okCount)개를 지웠어요")
                let gone = Set(chosen.map(\.id))
                // 유튜브 뮤직 목록이 몇 초 늦게 바뀌어서, 지운 건 바로 빼고(1분 동안 다시 받아도 숨김) 조금 뒤 새로 받음
                Self.recentlyDeleted.formUnion(gone)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Self.recentlyDeleted.subtract(gone) }
                if gone.contains(Self.selectedId) { Self.selectedId = lists.first(where: { !gone.contains($0.id) })?.id ?? ""; tracks = [] }
                applyLists(lists.filter { !gone.contains($0.id) })
                for t in [2.0, 6.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.reload() } }
                return
            }
            left.removeFirst()
            toast?("지우는 중… \(chosen.count - left.count)/\(chosen.count)")
            music?.deletePlaylist(pl.id) { ok in if ok { okCount += 1 }; next() }
        }
        next()
    }

    /// 새 재생목록 이름 묻기
    static func askName(_ done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "새 재생목록"
        a.informativeText = "이름을 정해 주세요 (나만 보기로 만들어요)"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.placeholderString = "재생목록 이름"
        a.accessoryView = f
        a.addButton(withTitle: "만들기"); a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        done(name.isEmpty ? "새 재생목록" : name)
    }

    private func remove(_ t: PlaylistTrack) {
        let id = Self.selectedId
        guard let i = tracks.firstIndex(of: t) else { return }
        let after = i + 1 < tracks.count ? tracks[i + 1].setId : nil
        // 바로 목록에서 빼고(기다리지 않게), 실패하면 다시 불러옴
        var ts = tracks; ts.remove(at: i); show(ts)
        music?.removeFromPlaylist(id, t) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.removed = (t, after)
                self.undoBtn.title = "‘\(t.title.prefix(12))’ 되돌리기"
                self.undoBtn.isHidden = false
                self.needsLayout = true
            } else { self.toast?("빼지 못했어요"); self.loadTracks() }
        }
    }

    @objc private func undo() {
        guard let (t, after) = removed else { return }
        let id = Self.selectedId
        removed = nil; undoBtn.isHidden = true; needsLayout = true
        // 다시 넣으면 맨 끝에 붙어서, 새 자리 ID 를 찾아 원래 자리(뒤에 있던 곡 앞)로 옮김
        music?.addToPlaylist(id, videoIds: [t.videoId]) { [weak self] ok in
            guard let self, ok else { self?.toast?("되돌리지 못했어요"); return }
            self.music?.playlistTracks(id) { ts in
                guard let ts, let back = ts.last(where: { $0.videoId == t.videoId }) else { self.loadTracks(); return }
                self.music?.moveInPlaylist(id, setId: back.setId, before: after) { _ in self.loadTracks() }
            }
        }
    }

    // MARK: 끌어서 순서 바꾸기

    private let line: NSView = {
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.launcherAccent.cgColor
        v.layer?.cornerRadius = 1
        return v
    }()
    private var dropAt = 0

    /// 줄을 잡고 위아래로 끌면 넣을 자리에 선, 놓으면 그 자리로
    private func dragging(_ row: PlaylistRow, y: CGFloat, done: Bool) {
        let p = doc.convert(NSPoint(x: 0, y: y), from: nil)
        let n = tracks.count
        dropAt = max(0, min(n, Int((p.y / PlaylistRow.rowH).rounded())))
        if !done {
            if line.superview == nil { doc.addSubview(line) }
            line.frame = NSRect(x: 8, y: CGFloat(dropAt) * PlaylistRow.rowH - 1, width: doc.bounds.width - 16, height: 2)
            row.alphaValue = 0.5
            // 가장자리 근처면 저절로 스크롤
            let vis = scroll.contentView.bounds
            if p.y < vis.minY + 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, vis.minY - 12))) }
            if p.y > vis.maxY - 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, doc.frame.height - vis.height), vis.minY + 12))) }
            return
        }
        line.removeFromSuperview()
        row.alphaValue = 1
        let from = row.index
        guard dropAt != from && dropAt != from + 1 else { return }
        let t = tracks[from]
        let before = dropAt < n ? tracks[dropAt].setId : nil
        var ts = tracks
        ts.remove(at: from)
        ts.insert(t, at: dropAt > from ? dropAt - 1 : dropAt)
        show(ts)
        music?.moveInPlaylist(Self.selectedId, setId: t.setId, before: before) { [weak self] ok in
            if !ok { self?.toast?("순서를 바꾸지 못했어요"); self?.loadTracks() }
        }
    }
}

/// 재생목록 한 줄: 번호 · 제목 · 가수 · 시간, 마우스를 올리면 ⊖. 누르면 여기부터 재생, 끌면 순서 바꾸기
@MainActor
final class PlaylistRow: NSView {
    static let rowH: CGFloat = 44
    let index: Int
    var onPlay: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDrag: ((PlaylistRow, CGFloat, Bool) -> Void)?
    private let num: NSTextField, t: NSTextField, a: NSTextField, d: NSTextField
    private let minus = NSButton()
    private var hovering = false { didSet { needsDisplay = true; minus.isHidden = !hovering; d.isHidden = hovering } }
    private var downY: CGFloat?
    private var moved = false
    override var isFlipped: Bool { true }

    /// 지금 나오는 곡: 번호 대신 빨간 스피커 · 굵게 · 옅은 빨간 바탕
    private var playing = false
    func markPlaying() {
        playing = true
        num.stringValue = "🔊"
        t.font = .boldSystemFont(ofSize: QueueRow.titleSize)
        needsDisplay = true
    }

    init(_ tr: PlaylistTrack, index: Int) {
        self.index = index
        num = NSTextField(labelWithString: "\(index + 1)")
        t = NSTextField(labelWithString: tr.title)
        a = NSTextField(labelWithString: tr.artist)
        d = NSTextField(labelWithString: tr.duration)
        super.init(frame: .zero)
        num.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        num.textColor = .tertiaryLabelColor
        num.alignment = .right
        t.font = .systemFont(ofSize: QueueRow.titleSize)
        a.font = .systemFont(ofSize: QueueRow.subSize); a.textColor = .secondaryLabelColor
        d.font = .monospacedDigitSystemFont(ofSize: QueueRow.subSize, weight: .regular); d.textColor = .secondaryLabelColor; d.alignment = .right
        for f in [t, a] { f.lineBreakMode = .byTruncatingTail }
        for v in [num, t, a, d] { addSubview(v) }
        minus.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "빼기")
        minus.contentTintColor = .systemRed
        minus.isBordered = false
        minus.toolTip = "재생목록에서 빼기"
        minus.target = self; minus.action = #selector(removeTapped)
        minus.isHidden = true
        addSubview(minus)
        toolTip = "누르면 여기부터 재생 · 끌어서 순서 바꾸기"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func removeTapped() { onRemove?() }

    override func layout() {
        super.layout()
        let w = bounds.width
        num.frame = NSRect(x: 4, y: 14, width: 24, height: 15)
        d.frame = NSRect(x: w - 54, y: 14, width: 42, height: 15)
        minus.frame = NSRect(x: w - 30, y: 12, width: 20, height: 20)
        let tw = max(40, w - 36 - 60)
        t.frame = NSRect(x: 36, y: 5, width: tw, height: 18)
        a.frame = NSRect(x: 36, y: 23, width: tw, height: 16)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if playing {
            NSColor.systemRed.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    override func mouseDown(with event: NSEvent) { downY = event.locationInWindow.y; moved = false }
    override func mouseDragged(with event: NSEvent) {
        guard let y0 = downY else { return }
        if !moved && abs(event.locationInWindow.y - y0) < 4 { return }
        moved = true
        NSCursor.closedHand.set()
        onDrag?(self, event.locationInWindow.y, false)
    }
    override func mouseUp(with event: NSEvent) {
        defer { downY = nil }
        if moved { NSCursor.arrow.set(); onDrag?(self, event.locationInWindow.y, true) }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onPlay?() }
    }
}
