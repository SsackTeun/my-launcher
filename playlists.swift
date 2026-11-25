// 플레이리스트 편집: 로그인된 YouTube Music 계정의 플레이리스트를 도구함에서 바로 고침 (휴대폰 앱에도 그대로 보임)
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
    let setId: String   // 플레이리스트 안 자리 ID (빼기 · 옮기기에 씀)
    let thumb: String
    /// 가수 페이지 ID (UC…) — 가수 링크가 있을 때만
    var artistId = ""
    /// 앨범 이름 · 앨범 페이지 ID (MPRE…) — 노래일 때만 (영상은 비어 있음)
    var album = ""
    var albumId = ""
}

/// 플레이리스트 전체 곡 수 (다음 트랙이 50곡씩만 불러와서, 전체가 몇 곡인지 보여 줄 때 씀)
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

    /// 내 플레이리스트 (좋아요 표시한 음악 등 자동 목록은 뺌 — 고칠 수 없어서)
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

    /// 플레이리스트 곡 전부 (100곡 넘으면 다음 쪽까지)
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
            const alRuns = (i.flexColumns[2] && i.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs) || [];
            const al = alRuns.find(x => x.navigationEndpoint && x.navigationEndpoint.browseEndpoint && /^MPRE/.test(x.navigationEndpoint.browseEndpoint.browseId || ''));
            out.push({t: txt(i.flexColumns[0]), a: txt(i.flexColumns[1]), d: fx ? (fx.text.runs || [{}])[0].text || '' : '',
                      v: d.videoId, s: d.playlistSetVideoId, th: th ? th.url : '', ar,
                      al: al ? al.text : '', alid: al ? al.navigationEndpoint.browseEndpoint.browseId : ''});
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
                                     artistId: $0["ar"] as? String ?? "", album: $0["al"] as? String ?? "", albumId: $0["alid"] as? String ?? "")
            })
        }
    }

    /// 새 플레이리스트 (비공개). 곡을 같이 넣을 수 있음
    func createPlaylist(_ title: String, videoIds: [String] = [], done: @escaping (String?) -> Void) {
        runAPI("""
        const j = await api('playlist/create', {title: name, description: '', privacyStatus: 'PRIVATE', videoIds: vids});
        return j.playlistId || null;
        """, ["name": title, "vids": videoIds]) { v in done(v as? String) }
    }

    /// 플레이리스트 이름 바꾸기
    func renamePlaylist(_ id: String, _ name: String, done: @escaping (Bool) -> Void) {
        runAPI("""
        const j = await api('browse/edit_playlist', {playlistId: pid, actions: [{action: 'ACTION_SET_PLAYLIST_NAME', playlistName: name}]});
        return j.status === 'STATUS_SUCCEEDED';
        """, ["pid": id, "name": name]) { v in done(v as? Bool ?? false) }
    }

    /// 플레이리스트 통째로 지우기 (유튜브 뮤직 계정에서도 지워짐 · 되돌릴 수 없음)
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

// MARK: - 플레이리스트 탭: 고르기 · 재생 · 끌어서 순서 바꾸기 · ⊖ 빼기 · 되돌리기 · 새 플레이리스트

@MainActor
final class PlaylistPane: NSView {
    private weak var music: YTMusic?
    private let picker = NSPopUpButton()
    private let playBtn = NSButton()
    private let newBtn = NSButton()
    private let renameBtn = NSButton()
    private let delBtn = NSButton()
    private let groupBtn = NSButton()
    /// 앨범별로 볼 때만: 모두 접기 · 펼치기 / 재생 중인 앨범만 펼치기
    private let foldBtn = NSButton()
    private let autoBtn = NSButton()
    /// 앨범별로 묶어 보기 (이어진 같은 앨범 곡들 위에 머리줄)
    static var groupByAlbum: Bool {
        get { UserDefaults.standard.bool(forKey: "plGroupAlbum") }
        set { UserDefaults.standard.set(newValue, forKey: "plGroupAlbum") }
    }
    private let undoBtn = NSButton(title: "되돌리기", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private var lists: [PlaylistInfo] = []
    private(set) var tracks: [PlaylistTrack] = []
    /// 방금 뺀 곡 (되돌리기용: 그 곡 · 원래 뒤에 있던 곡)
    private var removed: [(track: PlaylistTrack, after: String?)]?
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
        for (b, sym, tip, act) in [(playBtn, "play.circle.fill", "이 플레이리스트 재생", #selector(playAll)),
                                   (newBtn, "plus.circle", "새 플레이리스트", #selector(newList)),
                                   (renameBtn, "pencil", "이 플레이리스트 이름 바꾸기", #selector(renameList)),
                                   (delBtn, "trash", "플레이리스트 지우기 (여러 개 골라서)", #selector(deleteList)),
                                   (groupBtn, "square.stack.3d.up", "앨범별로 묶어 보기", #selector(toggleGroup)),
                                   (foldBtn, "rectangle.compress.vertical", "모두 접기", #selector(foldAll)),
                                   (autoBtn, "play.square.stack", "재생 중인 앨범만 펼치기", #selector(toggleAuto))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.isBordered = false; b.toolTip = tip; b.target = self; b.action = act
            b.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            addSubview(b)
        }
        syncGroupBtn()
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
        renameBtn.frame = NSRect(x: delBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        newBtn.frame = NSRect(x: renameBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        groupBtn.frame = NSRect(x: newBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        autoBtn.frame = NSRect(x: groupBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        foldBtn.frame = NSRect(x: autoBtn.frame.minX - 26, y: 2, width: 24, height: 24)
        playBtn.frame = NSRect(x: (Self.groupByAlbum ? foldBtn.frame.minX : groupBtn.frame.minX) - 26, y: 2, width: 24, height: 24)
        undoBtn.frame = NSRect(x: playBtn.frame.minX - uw, y: 5, width: uw - 6, height: 18)
        picker.frame = NSRect(x: 4, y: 2, width: max(80, playBtn.frame.minX - uw - 10), height: 24)
        scroll.frame = NSRect(x: 0, y: 32, width: w, height: bounds.height - 32)
        status.frame = NSRect(x: 0, y: scroll.frame.midY - 9, width: w, height: 18)
        stack()
    }

    // MARK: 불러오기

    private var loading = false
    /// 방금 지운 플레이리스트 (서버 목록에 잠깐 남아 있어도 숨김)
    static var recentlyDeleted = Set<String>()

    /// 고르기 칸 · 곡 목록을 이 목록으로
    private func applyLists(_ ls: [PlaylistInfo]) {
        lists = ls
        picker.removeAllItems()
        for l in ls { picker.menu?.addItem(NSMenuItem(title: l.title, action: nil, keyEquivalent: "")) }
        if !ls.contains(where: { $0.id == Self.selectedId }) { Self.selectedId = ls.first?.id ?? "" }
        if let i = ls.firstIndex(where: { $0.id == Self.selectedId }) { picker.selectItem(at: i) }
        if ls.isEmpty { status.stringValue = "플레이리스트가 없어요 · ⊕ 로 새로 만들어요"; status.isHidden = false }
        loadTracks()
    }
    /// 플레이리스트 탭을 열 때: 내 플레이리스트 중 하나를 듣는 중이면 그 목록을 보여 줌 (보는 목록과 나오는 곡이 달라 헷갈리지 않게)
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
        guard v != lastVid, dragRow == nil else { return }
        lastVid = v
        autoFlip = []
        if !tracks.isEmpty { show(tracks) }
    }

    func reload(lists again: Bool = true) {
        if again || lists.isEmpty {
            guard !loading else { return }
            loading = true
            if tracks.isEmpty { status.stringValue = "플레이리스트 불러오는 중…"; status.isHidden = false }
            music?.myPlaylists { [weak self] all in
                guard let self else { return }
                // 방금 지운 건 숨기고, 방금 바꾼 이름은 서버 목록이 늦게 바뀌어도 새 이름으로
                let ls = all.filter { !Self.recentlyDeleted.contains($0.id) }.map { p in
                    Self.renamed[p.id].map { PlaylistInfo(id: p.id, title: $0, sub: p.sub) } ?? p
                }
                self.loading = false
                // 실패(페이지가 아직 덜 떠서 빈 응답)면 고른 목록을 지우지 않고 다음 시도를 기다림
                if ls.isEmpty { return }
                self.lists = ls
                // 이름이 같은 플레이리스트가 있어도 하나로 합쳐지지 않게 한 줄씩 (addItems 는 같은 이름을 합쳐 순서가 밀렸음)
                self.picker.removeAllItems()
                for l in ls { self.picker.menu?.addItem(NSMenuItem(title: l.title, action: nil, keyEquivalent: "")) }
                if !ls.contains(where: { $0.id == Self.selectedId }) { Self.selectedId = ls.first?.id ?? "" }
                // 내 플레이리스트 중 하나를 듣는 중이면 그 목록부터
                if let l = self.music?.state?.listId, ls.contains(where: { $0.id == l }) { Self.selectedId = l }
                if let i = ls.firstIndex(where: { $0.id == Self.selectedId }) { self.picker.selectItem(at: i) }
                if ls.isEmpty { self.status.stringValue = "플레이리스트가 없어요 · ⊕ 로 새로 만들어요" }
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
        // 줄을 끌어 옮기는 중엔 다시 그리지 않음 (잡은 줄이 사라져 끌기가 끊겼음) — 놓은 뒤 새로 읽음
        if dragRow != nil { pendingReload = true; return }
        tracks = ts
        doc.subviews.forEach { $0.removeFromSuperview() }
        let playingHere = music?.state?.listId == Self.selectedId
        let nowVid = music?.state?.videoId ?? ""
        let grouped = Self.groupByAlbum
        if grouped {
            // 앨범별: 같은 앨범은 떨어져 있어도 한 묶음 (처음 나온 자리 순서), 묶음 안은 플레이리스트 순서
            var order: [String] = [], members: [String: [Int]] = [:]
            for (k, t) in ts.enumerated() {
                let g = t.albumId.isEmpty ? "n:" + t.album : t.albumId
                if members[g] == nil { order.append(g) }
                members[g, default: []].append(k)
            }
            for g in order {
                let idx = members[g]!
                let group = idx.map { ts[$0] }
                // 흩어짐: 플레이리스트에서 이 앨범 곡들 사이에 다른 곡이 끼어 있음
                let scattered = idx.last! - idx.first! + 1 != idx.count
                let h = AlbumGroupHead(title: group[0].album.isEmpty ? "앨범 정보 없음 (영상 등)" : group[0].album,
                                       detail: "\(group.count)곡 · \(Self.total(group))")
                h.onPlay = { [weak self] in self?.play(from: group[0]) }
                h.onRemove = { [weak self] in self?.removeGroup(group) }
                if scattered, !group[0].album.isEmpty { h.onGather = { [weak self] in self?.gather(group) } }
                // 앨범 편집: 이 앨범의 전체 수록곡을 펼쳐 빠진 곡을 넣기 (앨범 정보가 있을 때만)
                let key = group[0].setId
                if !group[0].albumId.isEmpty {
                    h.editing = editKey == key
                    h.onEdit = { [weak self] in
                        guard let self else { return }
                        self.editKey = self.editKey == key ? nil : key
                        self.show(self.tracks)
                    }
                }
                // 접기: 머리줄을 누르면 그 앨범 곡들을 접거나 펼침 (기억함)
                let ck = Self.collapseKey(group[0])
                if Self.autoExpand {
                    // 재생 중인 앨범만 펼치기: 지금 곡이 든 묶음만 펼침 (머리줄을 누르면 곡이 바뀔 때까지 반대로)
                    let playing = playingHere && group.contains { $0.videoId == nowVid }
                    h.collapsed = playing == autoFlip.contains(ck)
                    h.onToggle = { [weak self] in
                        guard let self else { return }
                        if self.autoFlip.contains(ck) { self.autoFlip.remove(ck) } else { self.autoFlip.insert(ck) }
                        self.show(self.tracks)
                    }
                } else {
                    h.collapsed = Self.collapsed.contains(ck)
                    h.onToggle = { [weak self] in
                        guard let self else { return }
                        if Self.collapsed.contains(ck) { Self.collapsed.remove(ck) } else { Self.collapsed.insert(ck) }
                        self.show(self.tracks)
                    }
                }
                doc.addSubview(h)
                if !h.collapsed {
                    for k in idx { addRow(ts[k], k, drag: false) }
                    if editKey == key, !group[0].albumId.isEmpty { addEditor(group) }
                }
            }
        } else { for (k, t) in ts.enumerated() { addRow(t, k, drag: true) } }
        func addRow(_ t: PlaylistTrack, _ k: Int, drag: Bool) {
            let r = PlaylistRow(t, index: k)
            if playingHere && t.videoId == nowVid { r.markPlaying() }
            r.onPlay = { [weak self] in self?.play(from: t) }
            r.onRemove = { [weak self] in self?.remove(t) }
            // 묶어 볼 땐 끌어서 옮기기 끔 (머리줄이 섞여 자리 계산이 어긋남)
            if drag { r.onDrag = { [weak self] row, y, done in self?.dragging(row, y: y, done: done) } }
            doc.addSubview(r)
        }
        if grouped { syncGroupBtn() }
        status.stringValue = ts.isEmpty ? "빈 플레이리스트예요\n다음 트랙 · 앨범에서 곡을 넣어 보세요" : ""
        status.isHidden = !ts.isEmpty
        stack()
    }

    private func stack() {
        guard dragRow == nil else { return }   // 끄는 중엔 줄 자리를 되돌리지 않음
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        for v in doc.subviews {
            let h: CGFloat = v is AlbumGroupHead ? AlbumGroupHead.height : v is AlbumEditRow ? AlbumEditRow.height : PlaylistRow.rowH
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            v.needsLayout = true
            y += h
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: y)
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
        toast?("‘\(current?.title ?? "플레이리스트")’ 재생")
    }
    private func play(from t: PlaylistTrack) { music?.playList(Self.selectedId, from: t.videoId) }

    /// 방금 바꾼 이름 (서버 목록에 잠깐 옛 이름이 남아 있어도 새 이름으로)
    static var renamed: [String: String] = [:]

    @objc private func renameList() {
        guard let cur = current else { return }
        Self.askName(title: "플레이리스트 이름 바꾸기", initial: cur.title, button: "바꾸기") { [weak self] name in
            guard let self, name != cur.title else { return }
            self.music?.renamePlaylist(cur.id, name) { ok in
                guard ok else { self.toast?("이름을 바꾸지 못했어요"); return }
                Self.renamed[cur.id] = name
                self.lists = self.lists.map { $0.id == cur.id ? PlaylistInfo(id: $0.id, title: name, sub: $0.sub) : $0 }
                if let i = self.lists.firstIndex(where: { $0.id == cur.id }) { self.picker.item(at: i)?.title = name; self.picker.selectItem(at: i) }
                self.toast?("‘\(name)’으로 바꿨어요")
                NotificationCenter.default.post(name: Notification.Name("playlistRenamed"), object: nil)
            }
        }
    }

    @objc private func newList() {
        Self.askName { [weak self] name in
            self?.music?.createPlaylist(name) { id in
                guard let self, let id else { self?.toast?("만들지 못했어요"); return }
                Self.selectedId = id
                self.toast?("‘\(name)’ 플레이리스트를 만들었어요")
                self.reload()
            }
        }
    }

    /// 지금 고른 플레이리스트를 통째로 지우기 (한 번 물어봄)
    /// 플레이리스트 지우기: 체크해서 여러 개 한 번에 (지금 보고 있는 목록은 미리 체크)
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
        pick.messageText = "지울 플레이리스트를 골라 주세요"
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
        a.messageText = chosen.count == 1 ? "‘\(chosen[0].title)’ 플레이리스트를 지울까요?" : "플레이리스트 \(chosen.count)개를 지울까요?"
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
                toast?(okCount == chosen.count ? "플레이리스트 \(okCount)개를 지웠어요" : "\(chosen.count)개 중 \(okCount)개를 지웠어요")
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

    /// 새 플레이리스트 이름 묻기
    static func askName(title: String = "새 플레이리스트", initial: String = "", button: String = "만들기", _ done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = initial.isEmpty ? "이름을 정해 주세요 (나만 보기로 만들어요)" : "새 이름을 적어 주세요 (휴대폰 앱에도 바뀌어 보여요)"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.placeholderString = "플레이리스트 이름"
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: button); a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { if initial.isEmpty { done("새 플레이리스트") }; return }
        done(name)
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
                self.removed = [(t, after)]
                self.undoBtn.title = "‘\(t.title.prefix(12))’ 되돌리기"
                self.undoBtn.isHidden = false
                self.needsLayout = true
            } else { self.toast?("빼지 못했어요"); self.loadTracks() }
        }
    }

    /// 앨범째 빼기: 화면에서 바로 빼고 플레이리스트에선 한 번에 (되돌리기 가능)
    private func removeGroup(_ group: [PlaylistTrack]) {
        let id = Self.selectedId
        let gone = Set(group.map(\.setId))
        let entries: [(track: PlaylistTrack, after: String?)] = tracks.enumerated().compactMap { k, t in
            gone.contains(t.setId) ? (t, k + 1 < tracks.count ? tracks[k + 1].setId : nil) : nil
        }
        show(tracks.filter { !gone.contains($0.setId) })
        music?.removeManyFromPlaylist(id, group.map { ($0.setId, $0.videoId) }) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.toast?("빼지 못했어요"); self.loadTracks(); return }
            self.removed = entries
            let name = group[0].album.isEmpty ? "\(group.count)곡" : "‘\(group[0].album.prefix(12))’"
            self.undoBtn.title = "\(name) 되돌리기"
            self.undoBtn.isHidden = false
            self.needsLayout = true
        }
    }

    @objc private func undo() {
        guard let entries = removed, !entries.isEmpty else { return }
        let id = Self.selectedId
        removed = nil; undoBtn.isHidden = true; needsLayout = true
        // 다시 넣으면 맨 끝에 붙어서, 새 자리 ID 로 뒤 곡부터 원래 자리(뒤에 있던 곡 앞)로 옮김
        music?.addToPlaylistIds(id, videoIds: entries.map(\.track.videoId)) { [weak self] m in
            guard let self else { return }
            guard let m, !m.isEmpty else { self.toast?("되돌리지 못했어요"); self.loadTracks(); return }
            var newSid: [String: String] = [:]   // 옛 자리 ID → 새 자리 ID
            for e in entries { if let s = m[e.track.videoId] { newSid[e.track.setId] = s } }
            let order = Array(entries.reversed())
            @MainActor func move(_ i: Int) {
                guard i < order.count else { self.loadTracks(); return }
                let e = order[i]
                guard let sid = newSid[e.track.setId] else { move(i + 1); return }
                self.music?.moveInPlaylist(id, setId: sid, before: e.after.map { newSid[$0] ?? $0 }) { _ in move(i + 1) }
            }
            move(0)
        }
    }

    /// 모으기: 흩어진 앨범 곡들을 첫 곡 자리에 한데 모음 (실제 플레이리스트 순서) — 화면은 바로, 서버는 뒤에서
    private func gather(_ group: [PlaylistTrack]) {
        let id = Self.selectedId
        let sids = Set(group.map(\.setId))
        guard let first = tracks.firstIndex(where: { sids.contains($0.setId) }) else { return }
        var final = tracks.filter { !sids.contains($0.setId) }
        let at = tracks[..<first].filter { !sids.contains($0.setId) }.count
        final.insert(contentsOf: group, at: at)
        // 묶음 뒤에 오는 곡 (첫 곡 뒤로 처음 나오는 다른 곡)
        let after: String? = at + group.count < final.count ? final[at + group.count].setId : nil
        show(final)
        // 뒤 곡부터: 마지막 곡을 '뒤에 오는 곡' 앞으로, 그 앞 곡을 그 곡 앞으로 … (첫 곡은 그대로)
        let order = Array(group.dropFirst().reversed())
        @MainActor func move(_ i: Int, before: String?) {
            guard i < order.count else { if Self.selectedId == id { self.loadTracks() }; return }
            music?.moveInPlaylist(id, setId: order[i].setId, before: before) { [weak self] ok in
                guard let self else { return }
                if !ok { self.toast?("모으지 못했어요"); self.loadTracks(); return }
                move(i + 1, before: order[i].setId)
            }
        }
        move(0, before: after)
    }

    /// 재생 중인 앨범만 펼치기 (나머지는 접음)
    static var autoExpand: Bool {
        get { UserDefaults.standard.bool(forKey: "plAutoExpand") }
        set { UserDefaults.standard.set(newValue, forKey: "plAutoExpand") }
    }
    /// 재생 중인 앨범만 펼치기에서 머리줄을 눌러 반대로 둔 묶음 (곡이 바뀌면 비움)
    private var autoFlip = Set<String>()

    /// 접어 둔 앨범 묶음 (플레이리스트 · 앨범별로 기억)
    static var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "plCollapsed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "plCollapsed") }
    }
    static func collapseKey(_ t: PlaylistTrack) -> String { "\(selectedId)|\(t.albumId.isEmpty ? t.album : t.albumId)" }

    // MARK: 앨범 편집 (앨범별로 묶어 볼 때 머리줄 ✎) — 전체 수록곡 중 빠진 곡을 그 앨범 묶음 끝에 넣기

    /// 편집 중인 앨범 묶음 (그 묶음 첫 곡의 자리 ID)
    private var editKey: String?
    private var albumSongs: [String: [QueueItem]] = [:]
    private var adding = Set<String>()

    private func addEditor(_ group: [PlaylistTrack]) {
        let aid = group[0].albumId
        guard let songs = albumSongs[aid] else {
            doc.addSubview(AlbumEditRow(note: "수록곡 불러오는 중…"))
            music?.albumTracks(id: aid) { [weak self] _, ts in
                guard let self else { return }
                self.albumSongs[aid] = ts
                self.show(self.tracks)
            }
            return
        }
        if songs.isEmpty { doc.addSubview(AlbumEditRow(note: "수록곡을 찾지 못했어요")); return }
        // 이미 플레이리스트에 있는 곡: 곡 ID 가 같거나 (버전이 달라도) 제목이 같으면
        func norm(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let haveV = Set(tracks.map(\.videoId)), haveT = Set(tracks.map { norm($0.title) })
        let isIn = { (q: QueueItem) in haveV.contains(q.videoId) || haveT.contains(norm(q.title)) }
        /// 이 수록곡에 해당하는 플레이리스트 곡들 (✓ 를 누르면 뺌)
        let inList = { (q: QueueItem) in self.tracks.filter { $0.videoId == q.videoId || norm($0.title) == norm(q.title) } }
        let missing = songs.filter { !isIn($0) && !$0.videoId.isEmpty }
        // 다른 앨범 버전으로 들어 있는 곡 (제목만 같고 곡 · 앨범이 다름) → ⇄ 이 앨범 버전으로 바꾸기
        let others = { (q: QueueItem) in self.tracks.filter { $0.videoId != q.videoId && norm($0.title) == norm(q.title) && $0.albumId != aid && !$0.setId.hasPrefix("pending-") } }
        let swap = songs.filter { !haveV.contains($0.videoId) && !others($0).isEmpty }
        var note = missing.isEmpty ? "앨범 \(songs.count)곡이 모두 들어 있어요" : "앨범 \(songs.count)곡 중 \(missing.count)곡이 빠져 있어요 — ＋ 로 넣기"
        if !swap.isEmpty { note += " · 다른 앨범 버전 \(swap.count)곡 ⇄" }
        let head = AlbumEditRow(note: note, button: !missing.isEmpty ? "모두 넣기" : !swap.isEmpty ? "모두 바꾸기" : nil)
        head.onButton = { [weak self] in
            guard let self else { return }
            if !missing.isEmpty { self.addToGroup(missing, group: group) } else { self.swapVersions(swap.map { ($0, others($0)) }, group: group) }
        }
        doc.addSubview(head)
        for (k, q) in songs.enumerated() {
            let pending = inList(q).contains { $0.setId.hasPrefix("pending-") }
            let other = others(q)
            let isSwap = !haveV.contains(q.videoId) && !other.isEmpty
            let r = AlbumEditRow(number: k + 1, song: q, state: pending ? .working : isSwap ? .other : isIn(q) ? .have : .add,
                                 otherAlbum: other.first?.album ?? "")
            r.onButton = { [weak self] in
                guard let self else { return }
                if isSwap { self.swapVersions([(q, other)], group: group) }
                else if isIn(q) { let ts = inList(q).filter { !$0.setId.hasPrefix("pending-") }; if !ts.isEmpty { self.removeGroup(ts) } }
                else { self.addToGroup([q], group: group) }
            }
            // 줄을 누르면 그 곡만 들어 보기
            r.onPlay = { [weak self] in self?.music?.playVideo(q.videoId); self?.toast?("‘\(q.title)’ 들어 보기") }
            doc.addSubview(r)
        }
    }

    /// 곡들을 플레이리스트에 넣고 그 앨범 묶음 바로 뒤(다음 묶음 앞)로 옮김 (앨범 순서대로)
    /// 화면엔 바로 ✓ (임시 자리 ID 'pending-…' 로 끼워 둠), 서버는 뒤에서 — 끝나면 진짜 자리 ID 로 바꿈
    private func addToGroup(_ songs: [QueueItem], group: [PlaylistTrack]) {
        let id = Self.selectedId
        let have = Set(tracks.map(\.videoId))
        let add = songs.filter { !$0.videoId.isEmpty && !have.contains($0.videoId) }
        guard !add.isEmpty, let first = group.first else { return }
        // 묶음 끝 (같은 앨범이 이어지는 마지막 자리 — 방금 끼운 임시 곡 포함)
        guard var end = tracks.firstIndex(where: { $0.setId == first.setId }) else { return }
        while end + 1 < tracks.count && tracks[end + 1].albumId == first.albumId && tracks[end + 1].album == first.album { end += 1 }
        let before: String? = tracks[(end + 1)...].first(where: { !$0.setId.hasPrefix("pending-") })?.setId
        let temp = add.map { q in PlaylistTrack(title: q.title, artist: first.artist, duration: q.duration, videoId: q.videoId,
                                                setId: "pending-\(q.videoId)", thumb: "", artistId: first.artistId, album: first.album, albumId: first.albumId) }
        var ts = tracks; ts.insert(contentsOf: temp, at: end + 1); show(ts)
        music?.addToPlaylistIds(id, videoIds: add.map(\.videoId)) { [weak self] m in
            guard let self else { return }
            guard let m else {
                self.toast?("넣지 못했어요")
                let temps = Set(add.map { "pending-\($0.videoId)" })
                if Self.selectedId == id { self.show(self.tracks.filter { !temps.contains($0.setId) }) }
                return
            }
            // 임시 자리 ID → 진짜 자리 ID (화면은 그대로, 다시 불러오지 않음)
            if Self.selectedId == id {
                self.show(self.tracks.compactMap { t in
                    guard t.setId.hasPrefix("pending-") else { return t }
                    let v = String(t.setId.dropFirst(8))
                    guard add.contains(where: { $0.videoId == v }) else { return t }
                    guard let sid = m[v], !sid.isEmpty else { return nil }   // 이미 있던 곡이라 안 들어감
                    return PlaylistTrack(title: t.title, artist: t.artist, duration: t.duration, videoId: t.videoId, setId: sid, thumb: t.thumb,
                                         artistId: t.artistId, album: t.album, albumId: t.albumId)
                })
            }
            let sids = add.compactMap { m[$0.videoId] }.filter { !$0.isEmpty }
            @MainActor func move(_ i: Int) {
                guard i < sids.count, before != nil else { return }
                self.music?.moveInPlaylist(id, setId: sids[i], before: before) { _ in move(i + 1) }
            }
            move(0)
        }
    }

    /// 겹친 상자: 보기 고르기 메뉴 (곡만 · 앨범별 · 재생 중인 앨범만 펼치기 · 모두 접기 / 펼치기)
    /// ⇄ 다른 앨범 버전을 이 앨범 버전으로: 이 앨범 묶음에 넣고 원래 버전은 뺌 (되돌리기로 원래 버전 되살림)
    private func swapVersions(_ pairs: [(QueueItem, [PlaylistTrack])], group: [PlaylistTrack]) {
        guard !pairs.isEmpty else { return }
        addToGroup(pairs.map(\.0), group: group)
        removeGroup(pairs.flatMap(\.1))
    }

    @objc private func toggleGroup() {
        let m = NSMenu()
        func item(_ t: String, on: Bool, _ f: @escaping () -> Void) { let i = MenuAction(t, f); i.state = on ? .on : .off; m.addItem(i) }
        let g = Self.groupByAlbum, a = Self.autoExpand
        item("곡만 보기 (끌어서 순서 바꾸기)", on: !g) { [weak self] in Self.groupByAlbum = false; self?.regroup() }
        item("앨범별로 묶어 보기", on: g && !a) { [weak self] in Self.groupByAlbum = true; Self.autoExpand = false; self?.regroup() }
        item("앨범별 · 재생 중인 앨범만 펼치기", on: g && a) { [weak self] in Self.groupByAlbum = true; Self.autoExpand = true; self?.autoFlip = []; self?.regroup() }
        m.addItem(.separator())
        // 모두 접기 · 펼치기 (재생 중인 앨범만 펼치기는 끔)
        let keys = Set(tracks.map { Self.collapseKey($0) })
        let all = MenuAction("모두 접기") { [weak self] in Self.groupByAlbum = true; Self.autoExpand = false; Self.collapsed.formUnion(keys); self?.regroup() }
        let none = MenuAction("모두 펼치기") { [weak self] in Self.groupByAlbum = true; Self.autoExpand = false; Self.collapsed.subtract(keys); self?.regroup() }
        m.addItem(all); m.addItem(none)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: groupBtn.bounds.height + 2), in: groupBtn)
    }
    private func regroup() { syncGroupBtn(); show(tracks) }
    /// 모두 접기 ↔ 모두 펼치기 (하나라도 펼쳐져 있으면 접기) — 재생 중인 앨범만 펼치기는 끔
    @objc private func foldAll() {
        let keys = Set(tracks.map { Self.collapseKey($0) })
        let anyOpen = Self.autoExpand || !keys.isSubset(of: Self.collapsed)
        if anyOpen { Self.collapsed.formUnion(keys) } else { Self.collapsed.subtract(keys) }
        Self.autoExpand = false
        regroup()
    }
    @objc private func toggleAuto() { Self.autoExpand.toggle(); autoFlip = []; regroup() }
    private func syncGroupBtn() {
        foldBtn.isHidden = !Self.groupByAlbum
        autoBtn.isHidden = !Self.groupByAlbum
        autoBtn.contentTintColor = Self.autoExpand ? .launcherAccent : nil
        autoBtn.toolTip = Self.autoExpand ? "재생 중인 앨범만 펼치는 중 — 누르면 끔" : "재생 중인 앨범만 펼치기 (나머지는 접음)"
        let keys = Set(tracks.map { Self.collapseKey($0) })
        let allClosed = !Self.autoExpand && !keys.isEmpty && keys.isSubset(of: Self.collapsed)
        foldBtn.image = NSImage(systemSymbolName: allClosed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", accessibilityDescription: nil)
        foldBtn.toolTip = allClosed ? "모두 펼치기" : "모두 접기"
        needsLayout = true
        groupBtn.contentTintColor = Self.groupByAlbum ? .launcherAccent : nil
        groupBtn.toolTip = !Self.groupByAlbum ? "보기: 곡만 — 누르면 앨범별로 묶어 보기 등 고르기" : Self.autoExpand ? "보기: 앨범별 · 재생 중인 앨범만 펼치기" : "보기: 앨범별로 묶어 보기"
    }
    /// 곡들 길이 합 '1:02:03' · '23:45'
    static func total(_ ts: [PlaylistTrack]) -> String {
        let s = ts.reduce(0) { a, t in a + t.duration.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) } }
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 끌어서 순서 바꾸기 (다음 트랙과 같은 방식: 잡은 줄이 마우스를 따라오고 다른 줄이 비켜 줌)

    private weak var dragRow: PlaylistRow?
    private var dragFrom = -1
    private var dragTo = -1
    private var pendingReload = false

    private func dragging(_ row: PlaylistRow, y: CGFloat, done: Bool) {
        let p = doc.convert(NSPoint(x: 0, y: y), from: nil)
        let rows = doc.subviews.compactMap { $0 as? PlaylistRow }.sorted { $0.index < $1.index }
        let n = rows.count
        let h = PlaylistRow.rowH
        if dragRow !== row {
            guard let k = rows.firstIndex(where: { $0 === row }) else { return }
            dragRow = row; dragFrom = k; dragTo = k
            row.wantsLayer = true
            row.layer?.zPosition = 10
            row.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            row.layer?.cornerRadius = 6
            row.layer?.shadowOpacity = 0.25; row.layer?.shadowRadius = 6; row.layer?.shadowOffset = .zero
        }
        let to = max(0, min(n - 1, Int((p.y / h).rounded(.down))))
        if !done {
            row.setFrameOrigin(NSPoint(x: row.frame.minX, y: max(0, min(CGFloat(n - 1) * h, p.y - h / 2))))
            if to != dragTo {
                dragTo = to
                let others = rows.filter { $0 !== row }
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.12
                    for (i, r) in others.enumerated() {
                        let slot = i < to ? i : i + 1
                        r.animator().setFrameOrigin(NSPoint(x: r.frame.minX, y: CGFloat(slot) * h))
                    }
                }
            }
            // 가장자리 근처면 저절로 스크롤
            let vis = scroll.contentView.bounds
            if p.y < vis.minY + 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, vis.minY - 12))) }
            if p.y > vis.maxY - 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, doc.frame.height - vis.height), vis.minY + 12))) }
            return
        }
        // 놓음
        let from = dragFrom
        dragRow = nil
        row.layer?.zPosition = 0; row.layer?.shadowOpacity = 0; row.layer?.backgroundColor = nil
        let reloadAfter = pendingReload
        pendingReload = false
        guard from >= 0, from < tracks.count, to != from else { show(tracks); if reloadAfter { loadTracks() }; return }
        var ts = tracks
        let t = ts.remove(at: from)
        ts.insert(t, at: to)
        // 그 곡 뒤에 오는 곡 앞으로 (맨 끝이면 nil)
        let before = to + 1 < ts.count ? ts[to + 1].setId : nil
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            row.animator().setFrameOrigin(NSPoint(x: row.frame.minX, y: CGFloat(to) * h))
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.show(ts) } })
        music?.moveInPlaylist(Self.selectedId, setId: t.setId, before: before) { [weak self] ok in
            if !ok { self?.toast?("순서를 바꾸지 못했어요"); self?.loadTracks() }
        }
    }
}

/// 플레이리스트 한 줄: 번호 · 제목 · 가수 · 시간, 마우스를 올리면 ⊖. 누르면 여기부터 재생, 끌면 순서 바꾸기
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
        minus.toolTip = "플레이리스트에서 빼기"
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

/// 앨범별로 묶어 볼 때 앨범 머리줄: 앨범 이름 · 곡 수 · 시간 · ▶ 여기부터 재생 · ⊖ 앨범째 빼기
@MainActor
final class AlbumGroupHead: NSView {
    static let height: CGFloat = 30
    var onPlay: (() -> Void)?
    var onRemove: (() -> Void)?
    /// ✎ 앨범 편집 (앨범 정보가 있을 때만 보임)
    var onEdit: (() -> Void)? { didSet { edit.isHidden = onEdit == nil } }
    var editing = false { didSet { edit.contentTintColor = editing ? .launcherAccent : .secondaryLabelColor } }
    /// 접힘 (▸) / 펼침 (▾) — 머리줄을 누르면 바뀜
    var collapsed = false { didSet { chev.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil) } }
    var onToggle: (() -> Void)?
    /// 흩어진 앨범이면 '모으기' (실제 순서도 한데 모음)
    var onGather: (() -> Void)? { didSet { gatherBtn.isHidden = onGather == nil } }
    private let gatherBtn = NSButton(title: "모으기", target: nil, action: nil)
    private let chev = NSImageView()
    private let name: NSTextField, info: NSTextField
    private let play = NSButton(), minus = NSButton(), edit = NSButton()
    override var isFlipped: Bool { true }
    init(title: String, detail: String) {
        name = NSTextField(labelWithString: title)
        info = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = title
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        for v in [name, info] { addSubview(v) }
        for (b, sym, tip, act) in [(edit, "square.and.pencil", "앨범 편집 — 이 앨범의 전체 수록곡을 보고 빠진 곡 넣기", #selector(editTapped)),
                                   (play, "play.circle", "이 앨범부터 재생", #selector(playTapped)),
                                   (minus, "minus.circle", "이 앨범 곡을 모두 플레이리스트에서 빼기 (되돌리기 가능)", #selector(removeTapped))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.isBordered = false; b.toolTip = tip; b.target = self; b.action = act
            b.contentTintColor = b === minus ? .systemRed : .secondaryLabelColor
            addSubview(b)
        }
        edit.isHidden = true
        gatherBtn.bezelStyle = .recessed; gatherBtn.controlSize = .small; gatherBtn.font = .systemFont(ofSize: 10.5)
        gatherBtn.toolTip = "이 앨범 곡들이 플레이리스트에서 떨어져 있어요 — 누르면 첫 곡 자리에 한데 모아요"
        gatherBtn.target = self; gatherBtn.action = #selector(gatherTapped)
        gatherBtn.isHidden = true
        addSubview(gatherBtn)
        chev.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chev.contentTintColor = .secondaryLabelColor
        chev.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        addSubview(chev)
        toolTip = "누르면 이 앨범 곡들을 접거나 펼쳐요"
    }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() } }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width
        minus.frame = NSRect(x: w - 30, y: 6, width: 20, height: 20)
        play.frame = NSRect(x: w - 54, y: 6, width: 20, height: 20)
        edit.frame = NSRect(x: w - 78, y: 6, width: 20, height: 20)
        info.sizeToFit()
        var left = edit.isHidden ? play.frame.minX : edit.frame.minX
        if !gatherBtn.isHidden {
            gatherBtn.sizeToFit()
            gatherBtn.frame = NSRect(x: left - 6 - gatherBtn.frame.width, y: 6, width: gatherBtn.frame.width, height: 19)
            left = gatherBtn.frame.minX
        }
        info.frame = NSRect(x: left - 6 - info.frame.width, y: 9, width: info.frame.width, height: 15)
        chev.frame = NSRect(x: 8, y: 9, width: 12, height: 13)
        name.frame = NSRect(x: 24, y: 8, width: max(40, info.frame.minX - 32), height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: 6, yRadius: 6).fill()
    }
    @objc private func playTapped() { onPlay?() }
    @objc private func editTapped() { onEdit?() }
    @objc private func gatherTapped() { onGather?() }
    @objc private func removeTapped() { onRemove?() }
}

/// 앨범 편집 줄: 안내(＋ 모두 넣기) 또는 수록곡 한 곡 (번호 · 제목 · 시간 · ✓ 들어 있음 / ＋ 넣기)
@MainActor
final class AlbumEditRow: NSView {
    static let height: CGFloat = 28
    enum State { case have, add, working, other }
    var onButton: (() -> Void)?
    /// 줄을 누르면 (수록곡 들어 보기)
    var onPlay: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }
    private let btn = NSButton()
    override var isFlipped: Bool { true }
    private var labels: [NSTextField] = []
    private var state: State?

    /// 안내 줄 (button 이 있으면 오른쪽에 글자 단추)
    init(note: String, button: String? = nil) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: note)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; l.lineBreakMode = .byTruncatingTail
        addSubview(l); labels = [l]
        if let b = button {
            btn.title = b; btn.bezelStyle = .rounded; btn.controlSize = .small; btn.font = .systemFont(ofSize: 11)
            btn.target = self; btn.action = #selector(tapped)
            addSubview(btn)
        }
    }
    /// 수록곡 한 곡
    init(number: Int, song q: QueueItem, state: State, otherAlbum: String = "") {
        self.state = state
        super.init(frame: .zero)
        let n = NSTextField(labelWithString: "\(number)")
        n.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular); n.textColor = .tertiaryLabelColor; n.alignment = .right
        let t = NSTextField(labelWithString: q.title)
        t.font = .systemFont(ofSize: 12); t.lineBreakMode = .byTruncatingTail
        t.textColor = state == .have ? .secondaryLabelColor : .labelColor
        let d = NSTextField(labelWithString: q.duration)
        d.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular); d.textColor = .tertiaryLabelColor; d.alignment = .right
        for v in [n, t, d] { addSubview(v) }
        labels = [n, t, d]
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: state == .have ? "checkmark.circle.fill" : state == .working ? "ellipsis.circle" : state == .other ? "arrow.triangle.2.circlepath.circle.fill" : "plus.circle.fill", accessibilityDescription: nil)
        btn.contentTintColor = state == .have ? .systemGreen : state == .other ? .systemOrange : .launcherAccent
        btn.toolTip = state == .have ? "들어 있어요 — 누르면 플레이리스트에서 빼기 (되돌리기 가능)" : state == .working ? "넣는 중…"
            : state == .other ? "다른 앨범 버전(‘\(otherAlbum)’)으로 들어 있어요 — 누르면 이 앨범 버전으로 바꿔 이 묶음에 넣기" : "이 플레이리스트의 앨범 묶음 끝에 넣기"
        btn.isEnabled = state != .working
        toolTip = "누르면 이 곡만 들어 보기"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        btn.target = self; btn.action = #selector(tapped)
        addSubview(btn)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let w = bounds.width
        if state == nil {
            btn.sizeToFit()
            btn.frame = NSRect(x: w - 12 - btn.frame.width, y: 3, width: btn.frame.width, height: 22)
            labels[0].frame = NSRect(x: 30, y: 6, width: (btn.superview == nil ? w - 12 : btn.frame.minX - 6) - 30, height: 15)
        } else {
            labels[0].frame = NSRect(x: 14, y: 6, width: 22, height: 14)
            btn.frame = NSRect(x: w - 32, y: 4, width: 20, height: 20)
            labels[2].frame = NSRect(x: btn.frame.minX - 48, y: 6, width: 42, height: 14)
            labels[1].frame = NSRect(x: 42, y: 5, width: labels[2].frame.minX - 48, height: 16)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        // 펼친 편집 칸: 왼쪽에 옅은 세로 줄
        NSColor.launcherAccent.withAlphaComponent(0.35).setFill()
        NSRect(x: 10, y: 0, width: 2, height: bounds.height).fill()
        if hover && state != nil {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 14, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if state != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onPlay?() }
    }
    @objc private func tapped() { onButton?() }
}
