// 다음 트랙에서 내 플레이리스트 고치기: 지금 듣는 플레이리스트가 내 것이면, 다음 트랙에서 빼고 · 옮기고 · 넣은 게 플레이리스트에도 바로 반영
// - 플레이리스트: browse/edit_playlist (플레이리스트 탭과 같은 방법)
// - 지금 듣는 대기열: YouTube Music 페이지의 대기열을 직접 고침 (YouTube Music 이 자기 화면에서 할 때와 같은 함수 · 동작)
import Cocoa

extension QueueItem {
    /// 자리 번호만 바꾼 것 (화면에서 먼저 옮기거나 뺄 때)
    func with(index: Int) -> QueueItem {
        var q = QueueItem(title: title, artist: artist, duration: duration, current: current, index: index, auto: auto, artistId: artistId, videoId: videoId)
        q.setId = setId; q.ownVideoId = ownVideoId
        return q
    }
}

extension YTMusic {
    /// 페이지 대기열 손잡이 (QQ: 대기열, QC: 대기열 화면, R: 곡 정보 꺼내기)
    private static let queueCtl = """
    const QEL = document.querySelector('ytmusic-player-queue');
    const QC = QEL && QEL.polymerController;
    const QQ = QC && QC.queue;
    const R = x => x && (x.playlistPanelVideoWrapperRenderer ? x.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer : x.playlistPanelVideoRenderer);

    """

    /// 대기열에서 index 번째 곡 빼기 (그 자리 곡의 플레이리스트 자리 ID 가 sid 일 때만)
    func queueRemove(index: Int, setId: String, done: @escaping (Bool) -> Void) {
        runAPIPublic(Self.queueCtl + """
        if (!QQ) return false;
        const items = QQ.getItems(), r = R(items[i]);
        if (!r || (sid && r.playlistSetVideoId !== sid)) return false;   // 지금 곡이면 YouTube Music 이 다음 곡으로 넘김
        const ix = r.navigationEndpoint && r.navigationEndpoint.watchEndpoint && r.navigationEndpoint.watchEndpoint.index;
        if (typeof ix === 'number') QQ.removeItem(String(ix)); else QQ.store.dispatch({type: 'REMOVE_ITEM', payload: i});
        return QQ.getItems().length === items.length - 1;
        """, ["i": index, "sid": setId]) { done($0 as? Bool ?? false) }
    }

    /// 섞어 듣는 중인지 (그러면 다음 트랙 순서 ≠ 플레이리스트 순서)
    func queueShuffled(_ done: @escaping (Bool) -> Void) {
        runAPIPublic(Self.queueCtl + "return !!(QQ && QQ.store.getState().queue.shuffleEnabled);", [:]) { done($0 as? Bool ?? false) }
    }

    /// 대기열에서 from 번째 곡을 to 번째 곡 앞으로 (to == 개수면 맨 끝) — YouTube Music 화면에서 끌어 옮길 때와 같은 방법
    func queueMove(from: Int, to: Int, setId: String, done: @escaping (Bool) -> Void) {
        runAPIPublic(Self.queueCtl + """
        if (!QQ || !QC.onDrop) return false;
        const ct = QEL.querySelector('#contents'), kids = [...ct.children], items = QQ.getItems();
        if (kids.length !== items.length || !kids[from]) return false;
        const r = R(items[from]); if (!r || (sid && r.playlistSetVideoId !== sid)) return false;
        const el = kids[from];
        ct.insertBefore(el, kids[to] || null);
        QC.onDrop({detail: {dragEl: el}});
        return R(QQ.getItems()[to > from ? to - 1 : to]) === r;
        """, ["from": from, "to": to, "sid": setId]) { done($0 as? Bool ?? false) }
    }

    /// 곡들을 대기열 at 번째 자리에 넣기 (nil 이면 맨 끝 · 자동재생 곡 앞). setIds 가 있으면 플레이리스트 자리 ID 도 붙여 둠 (나중에 뺄 수 있게)
    func queueInsert(_ vids: [String], setIds: [String] = [], at: Int? = nil, done: @escaping (Int) -> Void) {
        runAPIPublic(Self.queueCtl + """
        if (!QQ || !vids.length) return 0;
        const j = await api('music/get_queue', {videoIds: vids});
        const items = (j.queueDatas || []).map(q => q.content).filter(Boolean);
        items.forEach((c, k) => { const r = R(c); if (r && sids[k]) r.playlistSetVideoId = sids[k]; });
        if (!items.length) return 0;
        const n = QQ.getItems().length;
        const idx = (at === null || at < 0 || at > n) ? n : at;
        QQ.store.dispatch({type: 'ADD_ITEMS', payload: {nextQueueItemId: QQ.store.getState().queue.nextQueueItemId, index: idx, items, shouldAssignIds: true}});
        return QQ.getItems().length - n;
        """, ["vids": vids, "sids": setIds, "at": at.map { $0 as Any } ?? NSNull()]) { done(($0 as? Int) ?? Int(($0 as? Double) ?? 0)) }
    }

    /// 다음 트랙에 붙인 곡(자리 ID 없는 것)에 플레이리스트 자리 ID 를 붙여 둠 (나중에 빼기 · 옮기기용)
    func queueSetSid(_ vid: String, sid: String) {
        runAPIPublic(Self.queueCtl + """
        if (!QQ) return false;
        const it = QQ.getItems().map(R).reverse().find(r => r && r.videoId === vid && !r.playlistSetVideoId);
        if (it) it.playlistSetVideoId = sid;
        return !!it;
        """, ["vid": vid, "sid": sid]) { _ in }
    }

    /// 플레이리스트에서 여러 곡을 한 번에 빼기 (자리 ID · 곡 ID)
    func removeManyFromPlaylist(_ id: String, _ list: [(setId: String, videoId: String)], done: @escaping (Bool) -> Void) {
        runAPIPublic("""
        const j = await api('browse/edit_playlist', {playlistId: pid, actions: sids.map((s, k) => ({action: 'ACTION_REMOVE_VIDEO', setVideoId: s, removedVideoId: vids[k]}))});
        return j.status === 'STATUS_SUCCEEDED';
        """, ["pid": id, "sids": list.map(\.setId), "vids": list.map(\.videoId)]) { done($0 as? Bool ?? false) }
    }

    /// 플레이리스트에 넣고, 새로 생긴 자리 ID 를 곡 ID 별로 (이미 있던 곡은 건너뛰어서 빠짐)
    func addToPlaylistIds(_ id: String, videoIds: [String], done: @escaping ([String: String]?) -> Void) {
        runAPIPublic("""
        const j = await api('browse/edit_playlist', {playlistId: pid,
          actions: vids.map(v => ({action: 'ACTION_ADD_VIDEO', addedVideoId: v, dedupeOption: 'DEDUPE_OPTION_SKIP'}))});
        if (j.status !== 'STATUS_SUCCEEDED') return null;
        const m = {};
        for (const r of (j.playlistEditResults || [])) { const d = r.playlistEditVideoAddedResultData; if (d && d.videoId) m[d.videoId] = d.setVideoId || ''; }
        return JSON.stringify(m);
        """, ["pid": id, "vids": videoIds]) { v in
            guard let s = v as? String, let d = s.data(using: .utf8) else { done(nil); return }
            done((try? JSONSerialization.jsonObject(with: d)) as? [String: String] ?? [:])
        }
    }

    /// 노래 검색 (YouTube Music '노래' 칸만)
    func searchSongs(_ q: String, done: @escaping ([PlaylistTrack]) -> Void) {
        runAPIPublic("""
        let j = await api('search', {query: q});
        let p = null;
        for (const c of collect(j, 'chipCloudChipRenderer')) {
          const t = ((c.text || {}).runs || [{}])[0].text || '';
          const e = c.navigationEndpoint && c.navigationEndpoint.searchEndpoint;
          if (e && e.params && /^(노래|Songs|曲|歌曲)$/i.test(t.trim())) { p = decodeURIComponent(e.params); break; }
        }
        if (p) j = await api('search', {query: q, params: p});
        const txt = c => ((c && c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map(x => x.text).join('');
        const out = [];
        for (const i of collect(j, 'musicResponsiveListItemRenderer')) {
          const v = (i.playlistItemData && i.playlistItemData.videoId) || '';
          if (!v || out.some(o => o.v === v)) continue;
          const runs = ((i.flexColumns[1] && i.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map(x => x.text);
          const parts = runs.join('').split(' • ').map(s => s.trim()).filter(Boolean);
          const dur = parts.length && /^\\d+(:\\d\\d)+$/.test(parts[parts.length - 1]) ? parts.pop() : '';
          if (parts.length > 1 && /^(노래|Song|曲|歌曲)$/i.test(parts[0])) parts.shift();
          const th = ((i.thumbnail && i.thumbnail.musicThumbnailRenderer && i.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
          out.push({t: txt(i.flexColumns[0]), a: parts.join(' · '), d: dur, v, th: th ? th.url : ''});
          if (out.length >= 20) break;
        }
        return JSON.stringify(out);
        """, ["q": q]) { v in
            guard let s = v as? String, let d = s.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { done([]); return }
            done(arr.map { PlaylistTrack(title: $0["t"] as? String ?? "", artist: $0["a"] as? String ?? "", duration: $0["d"] as? String ?? "",
                                         videoId: $0["v"] as? String ?? "", setId: "", thumb: $0["th"] as? String ?? "") })
        }
    }
}

// MARK: - 검색해서 넣기 (다음 트랙 🔍 → 작은 창)

@MainActor
final class SongSearchVC: NSViewController, NSSearchFieldDelegate {
    private weak var music: YTMusic?
    private let target: String
    /// 곡 하나 넣기 (넣었으면 true)
    var onAdd: ((PlaylistTrack, @escaping (Bool) -> Void) -> Void)?
    private let field = NSSearchField()
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private var seq = 0
    private var added = Set<String>()

    init(music: YTMusic?, target: String) {
        self.music = music; self.target = target
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let W: CGFloat = 380, H: CGFloat = 420
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let head = NSTextField(labelWithString: "‘\(target)’에 넣을 노래 찾기")
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        head.frame = NSRect(x: 12, y: H - 26, width: W - 24, height: 16)
        v.addSubview(head)
        field.placeholderString = "노래 · 가수 이름"
        field.frame = NSRect(x: 10, y: H - 56, width: W - 20, height: 24)
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.target = self; field.action = #selector(search)
        v.addSubview(field)
        scroll.frame = NSRect(x: 4, y: 6, width: W - 8, height: H - 68)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        v.addSubview(scroll)
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.frame = NSRect(x: 10, y: H / 2 - 30, width: W - 20, height: 18)
        status.stringValue = "검색어를 넣고 return"
        v.addSubview(status)
        view = v
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func search() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        seq += 1
        let my = seq
        status.stringValue = "찾는 중…"; status.isHidden = false
        doc.subviews.forEach { $0.removeFromSuperview() }
        music?.searchSongs(q) { [weak self] ts in
            guard let self, self.seq == my else { return }
            self.show(ts)
        }
    }

    private func show(_ ts: [PlaylistTrack]) {
        doc.subviews.forEach { $0.removeFromSuperview() }
        status.stringValue = ts.isEmpty ? "찾지 못했어요" : ""
        status.isHidden = !ts.isEmpty
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        for t in ts {
            let r = SearchRow(track: t, width: w, done: added.contains(t.videoId))
            r.onAdd = { [weak self, weak r] in
                guard let self, let r else { return }
                r.state = .working
                self.onAdd?(t) { ok in
                    r.state = ok ? .done : .idle
                    if ok { self.added.insert(t.videoId) }
                }
            }
            r.frame.origin.y = y
            y += SearchRow.rowH
            doc.addSubview(r)
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
        scroll.contentView.scroll(to: .zero)
    }
}

/// 검색 결과 한 줄: 제목 · 가수 · 시간 · ＋ (넣으면 ✓)
@MainActor
final class SearchRow: NSView {
    static let rowH: CGFloat = 42
    enum State { case idle, working, done }
    var onAdd: (() -> Void)?
    var state: State = .idle { didSet { sync() } }
    private let btn = NSButton()
    private let spin = NSProgressIndicator()
    init(track t: PlaylistTrack, width w: CGFloat, done: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: Self.rowH))
        let title = NSTextField(labelWithString: t.title)
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 12, y: 21, width: w - 100, height: 17)
        addSubview(title)
        let sub = NSTextField(labelWithString: t.artist)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 12, y: 4, width: w - 100, height: 15)
        addSubview(sub)
        let d = NSTextField(labelWithString: t.duration)
        d.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        d.textColor = .secondaryLabelColor
        d.alignment = .right
        d.frame = NSRect(x: w - 84, y: 13, width: 42, height: 15)
        addSubview(d)
        btn.isBordered = false
        btn.frame = NSRect(x: w - 36, y: 9, width: 24, height: 24)
        btn.target = self; btn.action = #selector(tapped)
        addSubview(btn)
        spin.style = .spinning
        spin.controlSize = .small
        spin.frame = NSRect(x: w - 32, y: 13, width: 16, height: 16)
        spin.isHidden = true
        addSubview(spin)
        state = done ? .done : .idle
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func sync() {
        btn.image = NSImage(systemSymbolName: state == .done ? "checkmark.circle.fill" : "plus.circle.fill", accessibilityDescription: nil)
        btn.contentTintColor = state == .done ? .systemGreen : .launcherAccent
        btn.toolTip = state == .done ? "넣었어요" : "플레이리스트 · 다음 트랙에 넣기"
        btn.isEnabled = state == .idle
        btn.isHidden = state == .working
        spin.isHidden = state != .working
        if state == .working { spin.startAnimation(nil) } else { spin.stopAnimation(nil) }
    }
    @objc private func tapped() { if state == .idle { onAdd?() } }
}
