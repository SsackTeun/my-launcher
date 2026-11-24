// 크게 보기: 떼어 낸 플레이어 아래에 큰 앨범 사진(왼쪽) + 다음 트랙 · 가사 탭(오른쪽)
// YouTube Music 웹 화면을 여는 대신, 숨은 페이지에서 읽은 정보로 도구함이 직접 그림
import Cocoa

@MainActor
final class BigPlayerView: NSView {
    /// 켜져 있으면 떼어 낸 플레이어가 크게 보기 모양
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "playerBig") }
        set { UserDefaults.standard.set(newValue, forKey: "playerBig") }
    }
    /// 아래 칸 높이 · 크게 보기일 때 가장 좁은 창 폭
    static let height: CGFloat = 326
    /// 아래 가장자리를 끌어서 늘린 높이 (가장 작게는 기본 높이)
    static var userHeight: CGFloat {
        get { max(height, CGFloat(UserDefaults.standard.double(forKey: "bigPlayerH"))) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "bigPlayerH") }
    }
    static let minWidth: CGFloat = 560

    private weak var music: YTMusic?
    /// 가사 탭에 넣을 가사 줄 (도구함이 쓰는 것과 같은 것)
    private let lyricsView: NSView
    private let art = NSImageView()
    private let tabs = NSSegmentedControl(labels: ["다음 트랙", "가사", "앨범", "플레이리스트"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = WheelScrollView()
    private let doc = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var lastTitle = ""
    private var artURL = ""
    private var lastQueueKey = ""
    /// 앨범 밑 재생 버튼 (위 플레이어 줄의 것을 여기로 옮겨 온 것)
    private var ctl: [ActionButton] = []
    private var playBtn: ActionButton!, repBtn: ActionButton!, spkBtn: ScrollButton!, eqBtn: ActionButton!
    private var eqPopover: NSPopover?
    private func showEQ(from b: NSView) {
        if eqPopover?.isShown == true { eqPopover?.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = EQViewController(music: music)
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        eqPopover = p
    }
    /// 스피커: 누르면 볼륨 팝업 · 휠로 조절 (플레이어 줄의 것을 그대로 씀)
    var onVolume: ((NSView) -> Void)?
    var onNudge: ((CGFloat) -> Void)?
    /// 앨범 밑: 재생바 줄(시간 · 바) + 재생 버튼 알약
    static let controlsH: CGFloat = 66
    private let bar = ProgressBar()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let pill = NSView()

    private var tab: Int {
        get { UserDefaults.standard.integer(forKey: "playerBigTab") }
        set { UserDefaults.standard.set(newValue, forKey: "playerBigTab") }
    }

    override var isFlipped: Bool { true }

    init(music: YTMusic, lyricsView: NSView) {
        self.music = music
        self.lyricsView = lyricsView
        super.init(frame: .zero)

        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 10
        art.layer?.masksToBounds = true
        art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        art.contentTintColor = .tertiaryLabelColor
        addSubview(art)
        addSubview(hearing)
        HearingMeter.shared.onWarn = { [weak self] m in self?.toast(m) }

        tabs.segmentStyle = .rounded
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = tab
        addSubview(tabs)

        scroll.documentView = doc
        // 스크롤 막대는 숨김 ('스크롤 막대 항상 보기' 설정이면 검은 띠가 생겨서) — 휠 · 트랙패드로 스크롤
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        addSubview(scroll)

        func btn(_ sym: String, _ tip: String, _ size: CGFloat, _ key: String) -> ActionButton {
            let b = ActionButton(title: "", symbol: sym) { [weak self] _ in
                self?.music?.press(key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.syncControls() }
            }
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.toolTip = tip
            addSubview(b)
            return b
        }
        let prev = btn("backward.fill", "이전 곡", 15, "prev")
        playBtn = btn("play.fill", "재생 / 일시정지", 17, "playPause")
        let next = btn("forward.fill", "다음 곡", 15, "next")
        repBtn = btn("repeat", "반복", 14, "repeat")
        spkBtn = ScrollButton(title: "", symbol: "speaker.wave.2.fill") { [weak self] b in self?.onVolume?(b) }
        spkBtn.isBordered = false
        spkBtn.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        spkBtn.toolTip = "볼륨 (누르면 조절 · 휠로 바로 조절)"
        spkBtn.onScroll = { [weak self] d in self?.onNudge?(d) }
        addSubview(spkBtn)
        eqBtn = ActionButton(title: "", symbol: "slider.vertical.3") { [weak self] b in self?.showEQ(from: b) }
        eqBtn.isBordered = false
        eqBtn.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        eqBtn.toolTip = "이퀄라이저"
        addSubview(eqBtn)
        ctl = [prev, playBtn, next, repBtn, spkBtn, eqBtn]
        // 버튼들을 감싸는 옅은 알약 바탕 (앨범 · 목록과 구분)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        pill.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        pill.layer?.borderWidth = 1
        addSubview(pill, positioned: .below, relativeTo: prev)
        // 재생바는 재생 버튼 바로 위에 (위 플레이어 줄의 것은 크게 보기에서 숨김)
        bar.onSeek = { [weak self] f in self?.music?.seek(f); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.syncControls() } }
        addSubview(bar)
        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            l.textColor = .secondaryLabelColor
            addSubview(l)
        }
        total.alignment = .right

        albumScroll.documentView = albumDoc
        albumScroll.hasVerticalScroller = false
        albumScroll.drawsBackground = false
        albumScroll.isHidden = true
        addSubview(albumScroll)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)

        plPane.toast = { [weak self] m in self?.toast(m) }
        plPane.isHidden = true
        addSubview(plPane)

        selectBtn.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "고르기")
        selectBtn.isBordered = false
        selectBtn.toolTip = "여러 곡 · 앨범을 골라 플레이리스트에 넣기"
        selectBtn.target = self; selectBtn.action = #selector(toggleSelect)
        addSubview(selectBtn)
        searchBtn.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "검색해서 넣기")
        searchBtn.isBordered = false
        searchBtn.toolTip = "노래를 검색해서 지금 플레이리스트에 넣기 (다음 트랙에도 붙어요)"
        searchBtn.target = self; searchBtn.action = #selector(openSearch)
        searchBtn.isHidden = true
        addSubview(searchBtn)
        followBtn.isBordered = false
        followBtn.target = self; followBtn.action = #selector(toggleFollow)
        syncFollowBtn()
        addSubview(followBtn)
        headLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        headLabel.textColor = .secondaryLabelColor
        headLabel.lineBreakMode = .byTruncatingTail
        addSubview(headLabel)
        NotificationCenter.default.addObserver(forName: Notification.Name("openEQPopover"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.window != nil { self.showEQ(from: self.eqBtn) } }
        }
        actionBar.isHidden = true
        actionBar.onAdd = { [weak self] b in
            guard let self else { return }
            self.showAddMenu(from: b, vids: self.selectedVids() + self.pickedTracks, albums: self.selectedAlbums())
        }
        actionBar.onPlay = { [weak self] in
            self?.pickedVids { vids in self?.playVideos(vids) }
        }
        actionBar.onCancel = { [weak self] in self?.setSelecting(false) }
        actionBar.onRemove = { [weak self] in
            guard let self, let link = self.linked else { return }
            let sel = self.items.filter { !$0.auto && self.pickedQueue.contains($0.index) && !$0.setId.isEmpty }
            self.setSelecting(false)
            self.removeMany(sel, from: link)
        }
        addSubview(actionBar)
    }

    // MARK: 플레이리스트 · 고르기

    private lazy var plPane = PlaylistPane(music: music)
    private let selectBtn = NSButton()
    private let actionBar = SelectBar()
    private var selecting = false
    private var pickedQueue = Set<Int>()
    private var pickedAlbums = Set<String>()
    private var albumEntries: [AlbumEntry] = []

    @objc private func toggleSelect() { setSelecting(!selecting) }
    private func setSelecting(_ on: Bool) {
        selecting = on
        pickedQueue = []; pickedAlbums = []; pickedTracks = []
        selectBtn.contentTintColor = on ? .launcherAccent : nil
        for r in doc.subviews { (r as? QueueRow)?.check = on ? false : nil }
        for r in albumDoc.subviews { (r as? AlbumRow)?.check = on ? false : nil; (r as? QueueRow)?.check = on ? false : nil }
        syncBar()
        needsLayout = true
    }
    private func syncBar() {
        let songs = pickedQueue.count + pickedTracks.count
        let n = songs + pickedAlbums.count
        actionBar.isHidden = !selecting
        actionBar.text = n == 0 ? "곡 · 앨범을 눌러 고르세요" : [songs > 0 ? "\(songs)곡" : "", pickedAlbums.count > 0 ? "앨범 \(pickedAlbums.count)개" : ""].filter { !$0.isEmpty }.joined(separator: " · ") + " 골랐어요"
        actionBar.canAdd = n > 0
        actionBar.canRemove = tab == 0 && linked != nil && !pickedQueue.isEmpty && pickedTracks.isEmpty && pickedAlbums.isEmpty
    }
    private func selectedVids() -> [String] { items.filter { pickedQueue.contains($0.index) }.map(\.videoId).filter { !$0.isEmpty } }
    private func selectedAlbums() -> [String] { Array(pickedAlbums) }

    /// 플레이리스트 고르는 메뉴 (내 플레이리스트들 + 새 플레이리스트…)
    private func addMenu(vids: [String], albums: [String]) -> NSMenu {
        let m = NSMenu()
        if plPane.playlists.isEmpty {
            let i = NSMenuItem(title: "플레이리스트 불러오는 중…", action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
            plPane.reload()
        }
        for pl in plPane.playlists {
            m.addItem(MenuAction(pl.title) { [weak self] in self?.add(to: pl.id, title: pl.title, vids: vids, albums: albums) })
        }
        m.addItem(.separator())
        m.addItem(MenuAction("새 플레이리스트…") { [weak self] in
            PlaylistPane.askName { name in
                self?.music?.createPlaylist(name) { id in
                    guard let id else { self?.toast("만들지 못했어요"); return }
                    self?.add(to: id, title: name, vids: vids, albums: albums, fresh: true)
                }
            }
        })
        return m
    }
    private func showAddMenu(from b: NSView, vids: [String], albums: [String]) {
        addMenu(vids: vids, albums: albums).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
    private func add(to id: String, title: String, vids: [String], albums: [String], fresh: Bool = false) {
        // 지금 듣는 내 플레이리스트면 다음 트랙 끝에도 붙임 (곡만 · 앨범은 플레이리스트에만)
        if let link = linked, link.id == id, albums.isEmpty, !vids.isEmpty {
            toast("‘\(title)’에 넣는 중…", stay: true)
            addLinked(vids, link: link) { [weak self] n in
                guard let self else { return }
                if n >= 0, self.selecting { self.setSelecting(false) }
            }
            return
        }
        toast("‘\(title)’에 넣는 중…", stay: true)
        music?.addToPlaylist(id, videoIds: vids, albumIds: albums) { [weak self] ok in
            guard let self else { return }
            self.toast(ok ? "‘\(title)’에 넣었어요" : "넣지 못했어요")
            if ok {
                if self.selecting { self.setSelecting(false) }
                if fresh { PlaylistPane.selectedId = id }
                self.plPane.reload(lists: fresh)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 켜고 끄기 (창에 붙어 있는 동안만 1초마다 확인)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTitle = ""; lastQueueKey = ""
        showTab()
        tick()
        plPane.reload()   // 플레이리스트 탭 · '플레이리스트에 넣기' 메뉴에 쓸 목록 미리
        // 스크롤하면 마우스 아래 줄이 바뀌므로 다시 맞춤
        if scrollObs == nil {
            scroll.onWheel = { [weak self] in self?.lastUserTouch = Date() }
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncQueueHover() }
            }
        }
    }
    private var scrollObs: NSObjectProtocol?

    /// 재생 · 반복 · 음소거 모양을 지금 상태로
    private func syncControls() {
        guard let st = music?.state else { return }
        playBtn.image = NSImage(systemSymbolName: st.playing == true ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        func mmss(_ t: Double) -> String { let s = Int(max(0, t)); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
        bar.fraction = st.duration > 0 ? st.position / st.duration : 0
        elapsed.stringValue = mmss(st.position)
        total.stringValue = mmss(st.duration)
        repBtn.image = NSImage(systemSymbolName: st.repeatOne ? "repeat.1" : "repeat", accessibilityDescription: nil)
        repBtn.contentTintColor = st.repeatOn ? .launcherAccent : nil
        spkBtn.image = NSImage(systemSymbolName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
        eqBtn.contentTintColor = YTMusic.eqOn && YTMusic.eqGains.contains(where: { $0 != 0 }) ? .launcherAccent : nil
    }

    private let hearing = HearingBadge()
    private var ticks = 0
    private func tick() {
        syncControls()
        hearing.update()
        if hearing.frame.width != (HearingMeter.limitOn ? 98 : 78) { needsLayout = true }
        guard let st = music?.state else { return }
        ticks += 1
        loadArt(st.artURL)
        // 곡이 바뀌었거나 몇 초마다 다음 트랙을 새로 (목록이 늘거나 섞일 수 있어서)
        if tab == 0, st.title != lastTitle || ticks % 4 == 0 { loadQueue() }
        // 앨범 탭: 직접 고른 가수가 아니면 지금 곡의 가수를 따라감
        if tab == 2, st.title != lastTitle, !albumPinned { albumsForCurrent() }
        if tab == 3 { plPane.tickPlaying() }
        if tab == 0 { syncQueueHover() }
        // 처음 켤 땐 페이지가 덜 떠서 목록을 못 받을 수 있어 몇 번 더
        if plPane.playlists.isEmpty, ticks % 3 == 0, ticks < 40 { plPane.reload() }
        lastTitle = st.title
    }

    @objc private func tabChanged() {
        tab = tabs.selectedSegment
        showTab()
        if tab == 0 { loadQueue() }
        if tab == 2 { albumsForCurrent() }
        if tab == 3 { plPane.reload(); plPane.followPlaying() }
    }

    private func showTab() {
        tabs.selectedSegment = tab
        scroll.isHidden = tab != 0
        albumScroll.isHidden = tab != 2
        status.isHidden = !(tab == 0 && doc.subviews.isEmpty) && !(tab == 2 && albumDoc.subviews.isEmpty)
        if tab == 0 { status.stringValue = items.isEmpty ? "다음 트랙을 찾지 못했어요\n곡을 재생하면 여기에 보여요" : "" }
        if tab == 1 { if lyricsView.superview !== self { addSubview(lyricsView) } } else { lyricsView.removeFromSuperview() }
        plPane.isHidden = tab != 3
        selectBtn.isHidden = !(tab == 0 || tab == 2)
        searchBtn.isHidden = tab != 0 || linked == nil
        followBtn.isHidden = tab != 0
        if selecting && selectBtn.isHidden { setSelecting(false) }
        needsLayout = true
    }

    // MARK: 배치

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let side = max(80, min(bounds.height - pad * 2 - Self.controlsH, bounds.width * 0.46))
        art.frame = NSRect(x: pad + 2, y: pad, width: side, height: side)
        hearing.frame = NSRect(x: art.frame.minX + 8, y: art.frame.minY + 8, width: HearingMeter.limitOn ? 98 : 78, height: 20)
        // 앨범 밑 가운데에 재생 버튼: ◀◀ ▶ ▶▶ 🔁 🔊 — 모두 같은 칸 크기 · 같은 가운데 줄, 옅은 알약 바탕 위에
        let cell: CGFloat = 32, gap: CGFloat = 4
        let total = cell * CGFloat(ctl.count) + gap * CGFloat(ctl.count - 1)
        let pillH: CGFloat = 32
        // 재생바 줄: 0:42 ━━━●──── 3:24
        let by = art.frame.maxY + 8
        elapsed.frame = NSRect(x: art.frame.minX, y: by, width: 44, height: 14)
        self.total.frame = NSRect(x: art.frame.maxX - 44, y: by, width: 44, height: 14)
        bar.frame = NSRect(x: elapsed.frame.maxX + 2, y: by, width: art.frame.width - 92, height: 14)
        let py = art.frame.maxY + Self.controlsH - pillH - 2
        pill.frame = NSRect(x: art.frame.minX, y: py, width: art.frame.width, height: pillH)
        pill.layer?.cornerRadius = pillH / 2
        var bx = art.frame.midX - total / 2
        for b in ctl {
            b.frame = NSRect(x: bx, y: py + (pillH - 28) / 2, width: cell, height: 28)
            bx += cell + gap
        }
        let x = art.frame.maxX + 14
        let w = max(120, bounds.width - x - pad)
        tabs.sizeToFit()
        tabs.frame = NSRect(x: x, y: pad - 2, width: min(w - 28, max(tabs.frame.width, 160)), height: 24)
        selectBtn.frame = NSRect(x: x + w - 24, y: pad - 1, width: 24, height: 22)

        let full = NSRect(x: x - 6, y: tabs.frame.maxY + 6, width: w + 6, height: bounds.height - tabs.frame.maxY - 6 - 4)
        // 고르는 중이면 아래에 '플레이리스트에 넣기' 줄
        var body = full
        if selecting { body.size.height -= 36; actionBar.frame = NSRect(x: full.minX, y: body.maxY + 4, width: full.width, height: 30) }
        // 다음 트랙: 맨 위 고정 줄 + 그 아래 목록
        let hb = NSRect(x: body.minX + 8, y: body.minY, width: body.width - 8, height: Self.headH)
        searchBtn.frame = NSRect(x: hb.maxX - 24, y: hb.minY, width: 22, height: Self.headH)
        followBtn.frame = NSRect(x: (searchBtn.isHidden ? hb.maxX : searchBtn.frame.minX) - 24, y: hb.minY, width: 22, height: Self.headH)
        headLabel.frame = NSRect(x: hb.minX, y: hb.minY + 3, width: max(20, followBtn.frame.minX - hb.minX - 4), height: 16)
        headLabel.isHidden = tab != 0
        var qb = body; qb.origin.y += Self.headH; qb.size.height -= Self.headH
        scroll.frame = qb
        albumScroll.frame = body
        plPane.frame = full
        status.frame = NSRect(x: body.minX, y: body.midY - 9, width: body.width, height: 18)
        if lyricsView.superview === self { lyricsView.frame = body }
        layoutRows()
        layoutAlbums()
    }

    // MARK: 다음 트랙

    private var items: [QueueItem] = []
    private func loadQueue() {
        music?.loadQueue { [weak self] items in self?.show(items) }
    }

    private func show(_ items: [QueueItem]) {
        let link = linked
        let key = items.map { "\($0.title)|\($0.current)|\($0.setId)" }.joined(separator: "\n") + "|\(link?.id ?? "")|\(undoInfo?.entries.count ?? 0)"
        guard key != lastQueueKey else { return }
        lastQueueKey = key
        self.items = items
        doc.subviews.forEach { $0.removeFromSuperview() }
        var autoHead = false
        // 맨 위: 몇 곡 중 몇 번째 (자동재생으로 붙은 곡은 빼고 셈)
        let main = items.filter { !$0.auto }
        headLabel.stringValue = ""
        if !main.isEmpty {
            let cur = main.firstIndex(where: { $0.current })
            // 남은 시간: 지금 곡의 남은 부분 + 그 뒤 곡들 (자동재생 곡은 빼고)
            var left = ""
            if let c = cur {
                let pos = music?.state?.position ?? 0
                let rest = max(0, Double(Self.secs(main[c].duration)) - pos) + Double(main[(c + 1)...].reduce(0) { $0 + Self.secs($1.duration) })
                left = " · 남은 시간 \(Self.hms(Int(rest)))"
            }
            let k = cur.map { " · 지금 \($0 + 1)번째\(left)" } ?? ""
            // 플레이리스트 · 앨범이면 전체 곡 수도 (다음 트랙은 50곡씩만 불러오고, 나머지는 재생하며 이어서 불러옴)
            var head = cur != nil ? "\(main.count)곡 중 \(cur! + 1)번째\(left)" : "\(main.count)곡"
            if let l = music?.state?.listId, l.hasPrefix("PL") || l.hasPrefix("OLAK"),
               let total = PlaylistCount.get(l, music: music, changed: { [weak self] in self?.lastQueueKey = ""; self?.loadQueue() }),
               total > main.count {
                head = "전체 \(total)곡 중 \(main.count)곡 불러옴\(k) · 나머지는 재생하며 이어서 불러와요"
                head = head.replacingOccurrences(of: " · 남은 시간", with: " · 불러온 곡 남은 시간")
            }
            headLabel.stringValue = head
            headLabel.toolTip = head
            partial = head.hasPrefix("전체 ")
            if let link {
                // 내 플레이리스트와 연결: 여기서 고치면 플레이리스트에도 반영
                if let u = undoInfo {
                    let what = u.entries.count == 1 ? "‘\(u.entries[0].item.title.prefix(16))’을" : "\(u.entries.count)곡을"
                    let h = SectionHead("\(what) ‘\(link.title)’에서 뺐어요")
                    h.action = ("되돌리기", { [weak self] in self?.undoRemove() })
                    doc.addSubview(h)
                } else {
                    doc.addSubview(SectionHead("‘\(link.title)’과 연결됨 · ⊖ 빼기 · 끌어서 옮기기 · 🔍 검색해서 넣기 — 플레이리스트에도 반영돼요"))
                }
            }
        }
        searchBtn.isHidden = tab != 0 || link == nil
        needsLayout = true
        var no = 0
        for item in items {
            if item.auto && !autoHead {
                autoHead = true
                doc.addSubview(SectionHead("자동재생 · 위 목록이 끝나면 이어서 나오는 곡"))
            }
            var row: QueueRow!
            row = QueueRow(item: item, width: 320) { [weak self] in
                guard let self else { return }
                if self.selecting {
                    if self.pickedQueue.contains(item.index) { self.pickedQueue.remove(item.index) } else { self.pickedQueue.insert(item.index) }
                    row.check = self.pickedQueue.contains(item.index)
                    self.syncBar()
                    return
                }
                self.music?.play(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.lastQueueKey = ""; self?.loadQueue() }
            }
            let r: QueueRow = row
            if !item.auto { no += 1; r.number = no }
            if selecting { r.check = pickedQueue.contains(item.index) }
            r.translatesAutoresizingMaskIntoConstraints = true
            r.hoverByParent = true
            r.makeMenu = { [weak self] in self?.albumMenu(item) ?? NSMenu() }
            if let link, !item.auto, !item.setId.isEmpty, !selecting {
                r.onRemove = { [weak self] in self?.removeMany([item], from: link) }
                r.onDrag = { [weak self] row, y, done in self?.draggingQueue(row, item: item, y: y, done: done, link: link) }
            }
            if item.auto { r.alphaValue = 0.6 }
            doc.addSubview(r)
        }
        // 맨 아래: 전체 곡 수 · 재생시간 (자동재생 곡은 따로)
        if !main.isEmpty {
            let autos = items.filter { $0.auto }
            var foot = "전체 \(main.count)곡 · \(Self.hms(main.reduce(0) { $0 + Self.secs($1.duration) }))"
            if !autos.isEmpty { foot += "  |  자동재생 \(autos.count)곡 · \(Self.hms(autos.reduce(0) { $0 + Self.secs($1.duration) }))" }
            doc.addSubview(SectionHead(foot))
        }
        status.stringValue = items.isEmpty ? "다음 트랙을 찾지 못했어요\n곡을 재생하면 여기에 보여요" : ""
        status.isHidden = tab != 0 || !items.isEmpty
        layoutRows()
        // 지금 곡이 보이게 (위에 한 곡 남기고) — 곡이 바뀌었을 때만 (고치는 중엔 보던 자리 그대로)
        let curTitle = items.first(where: { $0.current })?.title ?? ""
        // 따라가기를 끈 경우, 또는 방금(8초 안) 직접 고치거나 스크롤했으면 그대로 둠
        let quiet = !Self.followCurrent || Date().timeIntervalSince(lastUserTouch) < 8
        if curTitle != scrolledFor, quiet, !scrolledFor.isEmpty { scrolledFor = curTitle }
        if curTitle != scrolledFor, let r = doc.subviews.first(where: { ($0 as? QueueRow)?.isCurrent == true }) {
            scrolledFor = curTitle
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, r.frame.minY - QueueRow.rowH)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// '3:45' · '1:02:03' → 초
    static func secs(_ t: String) -> Int { t.split(separator: ":").reduce(0) { $0 * 60 + (Int($1.trimmingCharacters(in: .whitespaces)) ?? 0) } }
    /// 초 → '3:45' · '1:02:03'
    static func hms(_ s: Int) -> String {
        let h = s / 3600, m = s % 3600 / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }

    // MARK: 내 플레이리스트와 연결된 다음 트랙 (빼기 · 옮기기 · 넣기 · 검색)

    private let searchBtn = NSButton()
    private var scrolledFor = ""
    /// 곡이 바뀌면 지금 곡 자리로 목록을 저절로 옮길지 (취향 · 기본 켬)
    static var followCurrent: Bool {
        get { UserDefaults.standard.object(forKey: "queueFollow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "queueFollow") }
    }
    private let followBtn = NSButton()
    /// 다음 트랙 맨 위 고정 줄: 몇 곡 중 몇 번째 · 남은 시간 (오른쪽에 따라가기 · 검색)
    private let headLabel = NSTextField(labelWithString: "")
    private static let headH: CGFloat = 22
    /// 마지막으로 직접 고치거나 스크롤한 때
    private var lastUserTouch = Date.distantPast
    private func syncFollowBtn() {
        followBtn.image = NSImage(systemSymbolName: Self.followCurrent ? "scope" : "scope", accessibilityDescription: "지금 곡 따라가기")
        followBtn.contentTintColor = Self.followCurrent ? .launcherAccent : .tertiaryLabelColor
        followBtn.toolTip = Self.followCurrent ? "지금 곡 따라가기: 켬 — 곡이 바뀌면 목록이 지금 곡 자리로 (누르면 끔)" : "지금 곡 따라가기: 끔 — 목록이 저절로 움직이지 않아요 (누르면 켬)"
    }
    @objc private func toggleFollow() {
        Self.followCurrent.toggle()
        syncFollowBtn()
        toast(Self.followCurrent ? "곡이 바뀌면 지금 곡으로 따라가요" : "목록이 저절로 움직이지 않아요")
        if Self.followCurrent { scrolledFor = ""; lastUserTouch = .distantPast; lastQueueKey = ""; loadQueue() }
    }
    /// 불러온 다음 트랙이 플레이리스트의 일부뿐인지 (긴 플레이리스트)
    private var partial = false
    /// 방금 뺀 곡 (되돌리기: 그 곡 · 원래 다음 곡 자리 ID · 대기열 자리)
    private var undoInfo: (entries: [(item: QueueItem, after: String?)], list: String)?

    /// 지금 듣는 플레이리스트가 내 플레이리스트(고칠 수 있는 것)이면 그것
    private var linked: PlaylistInfo? {
        guard let l = music?.state?.listId, l.hasPrefix("PL") else { return nil }
        if let p = plPane.playlists.first(where: { $0.id == l }) { return p }
        // 방금 만든 플레이리스트일 수 있어서 목록을 한 번 다시 받음 (플레이리스트마다 한 번만)
        if !plPane.playlists.isEmpty, linkChecked != l {
            linkChecked = l
            plPane.reload()
            refreshQueue(after: 2.5)
        }
        return nil
    }
    private var linkChecked = ""

    private func refreshQueue(after t: Double = 0.4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.lastQueueKey = ""; self?.loadQueue() }
    }

    /// 화면 목록을 바로 바꿈 (다음 트랙 줄 순서 · 번호), 서버 일은 뒤에서
    private func applyLocal(_ newMain: [QueueItem]) {
        let autos = items.filter { $0.auto }
        let all = (newMain + autos).enumerated().map { $0.element.with(index: $0.offset) }
        lastQueueKey = ""
        show(all)
    }
    private var queueRows: [QueueRow] { doc.subviews.compactMap { $0 as? QueueRow } }

    // 마우스가 올라간 다음 트랙 줄: 목록 전체가 마우스 위치를 보고 그 아래 한 줄만 켬 (줄마다 감지하면 빨리 지나갈 때 자국이 남았음)
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); syncQueueHover() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); syncQueueHover() }
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); syncQueueHover() }
    private func syncQueueHover() {
        guard let w = window else { return }
        let inWin = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inScroll = !scroll.isHidden && scroll.bounds.contains(scroll.convert(inWin, from: nil)) && w.frame.contains(NSEvent.mouseLocation)
        let p = doc.convert(inWin, from: nil)
        let under = (inScroll && dragRow == nil) ? queueRows.first(where: { $0.frame.contains(p) }) : nil
        for r in queueRows { r.setHover(r === under) }
    }

    /// 고른 곡들(하나도 됨)을 다음 트랙 · 플레이리스트에서 빼기 — 화면은 바로, 서버는 뒤에서. 지금 곡을 빼면 다음 곡으로 넘어감
    private func removeMany(_ sel: [QueueItem], from link: PlaylistInfo) {
        lastUserTouch = Date()
        let main = items.filter { !$0.auto }
        let gone = Set(sel.map(\.index))
        guard !gone.isEmpty else { return }
        // 되돌리기용: 각 곡 바로 뒤에 남는 곡 (같이 빠지는 곡은 건너뜀 · 되돌릴 때 그 곡도 돌아오므로 원래 바로 뒤 곡)
        let entries: [(item: QueueItem, after: String?)] = main.enumerated().compactMap { k, it in
            guard gone.contains(it.index) else { return nil }
            return (it, k + 1 < main.count ? main[k + 1].setId : nil)
        }
        let keep = main.filter { !gone.contains($0.index) }
        // 1) 화면: 빠지는 줄은 흐려지고 남은 줄은 제자리로 미끄러짐
        let rows = queueRows
        let h = QueueRow.rowH
        if let base = rows.first?.frame.minY, rows.count >= main.count {
            var y = base
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.18
                for (k, it) in main.enumerated() {
                    if gone.contains(it.index) { rows[k].animator().alphaValue = 0; continue }
                    rows[k].animator().setFrameOrigin(NSPoint(x: rows[k].frame.minX, y: y)); y += h
                }
                let shift = CGFloat(main.count - keep.count) * h
                let lastMain = rows[main.count - 1].frame.maxY
                for v in doc.subviews where v.frame.minY >= lastMain { v.animator().setFrameOrigin(NSPoint(x: v.frame.minX, y: v.frame.minY - shift)) }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.undoInfo = (entries, link.id)
                    self.applyLocal(keep)
                }
            })
        } else { undoInfo = (entries, link.id); applyLocal(keep) }
        // 2) 뒤에서: 다음 트랙(뒤 곡부터 빼야 번호가 안 밀림) · 플레이리스트(한 번에)
        for it in sel.sorted(by: { $0.index > $1.index }) { music?.queueRemove(index: it.index, setId: it.setId) { _ in } }
        music?.removeManyFromPlaylist(link.id, sel.map { ($0.setId, $0.ownVideoId) }) { [weak self] ok in
            PlaylistCount.cache[link.id] = nil
            if !ok { self?.undoInfo = nil; self?.toast("플레이리스트에서 빼지 못했어요"); self?.refreshQueue() }
            else { self?.refreshQueue(after: 1) }
        }
    }

    private func undoRemove() {
        lastUserTouch = Date()
        guard let u = undoInfo else { return }
        undoInfo = nil
        // 화면엔 바로 원래 자리에 다시 (앞 곡부터)
        var main = items.filter { !$0.auto }
        let back = u.entries.sorted { $0.item.index < $1.item.index }
        for e in back { main.insert(e.item, at: min(e.item.index, main.count)) }
        applyLocal(main)
        // 다음 트랙: 앞 곡부터 원래 자리에
        @MainActor func insertQ(_ i: Int) {
            guard i < back.count else { return }
            let it = back[i].item
            music?.queueInsert([it.ownVideoId], setIds: [it.setId], at: it.index) { _ in insertQ(i + 1) }
        }
        insertQ(0)
        // 플레이리스트: 다시 넣으면 맨 끝에 붙어서, 뒤 곡부터 원래 자리(뒤에 있던 곡 앞)로
        let vids = back.map(\.item.ownVideoId)
        music?.addToPlaylistIds(u.list, videoIds: vids) { [weak self] m in
            guard let self else { return }
            guard let m, !m.isEmpty else { self.toast("되돌리지 못했어요"); self.refreshQueue(); return }
            var newSid: [String: String] = [:]   // 옛 자리 ID → 새 자리 ID
            for e in back { if let s = m[e.item.ownVideoId] { newSid[e.item.setId] = s; self.music?.queueSetSid(e.item.ownVideoId, sid: s) } }
            let order = back.reversed().map { $0 }
            @MainActor func move(_ i: Int) {
                guard i < order.count else { PlaylistCount.cache[u.list] = nil; self.refreshQueue(after: 0.3); return }
                let e = order[i]
                guard let sid = newSid[e.item.setId] else { move(i + 1); return }
                let before = e.after.map { newSid[$0] ?? $0 }
                self.music?.moveInPlaylist(u.list, setId: sid, before: before) { _ in move(i + 1) }
            }
            move(0)
        }
    }

    /// 곡들을 지금 플레이리스트 끝 + 다음 트랙 끝에 (넣은 곡 수, 실패면 -1) — 다음 트랙엔 먼저 붙이고 플레이리스트는 뒤에서
    private func addLinked(_ vids: [String], link: PlaylistInfo, done: @escaping (Int) -> Void) {
        lastUserTouch = Date()
        // 이미 있는 곡은 빼고 (불러온 다음 트랙 기준)
        let have = Set(items.filter { !$0.auto }.flatMap { [$0.videoId, $0.ownVideoId] })
        let fresh = vids.filter { !have.contains($0) }
        if fresh.isEmpty { toast("이미 ‘\(link.title)’에 있어요"); done(0); return }
        // 긴 플레이리스트를 일부만 불러온 중이면 다음 트랙엔 안 붙임 (나머지를 불러올 때 같이 와서 두 번 나오지 않게)
        if !partial { music?.queueInsert(fresh) { [weak self] _ in self?.refreshQueue(after: 0.2) } }
        done(fresh.count)
        music?.addToPlaylistIds(link.id, videoIds: fresh) { [weak self] m in
            guard let self else { return }
            guard let m else { self.toast("‘\(link.title)’에 넣지 못했어요"); return }
            for (v, sid) in m where !sid.isEmpty { self.music?.queueSetSid(v, sid: sid) }
            PlaylistCount.cache[link.id] = nil
            if self.partial { self.toast("‘\(link.title)’ 끝에 넣었어요 (다음 트랙엔 나머지를 불러올 때 보여요)") }
            self.refreshQueue(after: 0.3)
        }
    }
    private func addToLinked(_ t: PlaylistTrack, link: PlaylistInfo, done: @escaping (Bool) -> Void) {
        addLinked([t.videoId], link: link) { n in done(n > 0) }
    }

    private var searchPop: NSPopover?
    @objc private func openSearch() {
        guard let link = linked else { return }
        if let p = searchPop, p.isShown { p.close(); return }
        let vc = SongSearchVC(music: music, target: link.title)
        vc.onAdd = { [weak self] t, done in
            guard let self, let l = self.linked, l.id == link.id else { done(false); return }
            self.addToLinked(t, link: l, done: done)
        }
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.appearance = window?.appearance
        p.show(relativeTo: searchBtn.bounds, of: searchBtn, preferredEdge: .maxY)
        searchPop = p
    }

    // 끌어서 옮기기: 잡은 줄이 마우스를 따라오고 다른 줄들이 비켜 줌, 놓으면 화면은 바로 · 플레이리스트 · 다음 트랙은 뒤에서
    private var dragBase: CGFloat = 0
    private var dragFrom = -1
    private var dragTo = -1
    private weak var dragRow: QueueRow?
    private func draggingQueue(_ row: QueueRow, item: QueueItem, y: CGFloat, done: Bool, link: PlaylistInfo) {
        lastUserTouch = Date()
        let p = doc.convert(NSPoint(x: 0, y: y), from: nil)
        let main = items.filter { !$0.auto }
        let mainRows = Array(queueRows.prefix(main.count))
        let h = QueueRow.rowH
        if dragRow !== row {
            guard let k = mainRows.firstIndex(where: { $0 === row }) else { return }
            dragRow = row; dragFrom = k; dragTo = k
            dragBase = mainRows[0].frame.minY
            row.wantsLayer = true
            row.layer?.zPosition = 10
            row.layer?.shadowOpacity = 0.25; row.layer?.shadowRadius = 6; row.layer?.shadowOffset = .zero
        }
        let n = mainRows.count
        let to = max(0, min(n - 1, Int(((p.y - dragBase) / h).rounded(.down))))
        if !done {
            row.setFrameOrigin(NSPoint(x: row.frame.minX, y: max(dragBase, min(dragBase + CGFloat(n - 1) * h, p.y - h / 2))))
            if to != dragTo {
                dragTo = to
                let others = mainRows.filter { $0 !== row }
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.12
                    for (i, r) in others.enumerated() {
                        let slot = i < to ? i : i + 1
                        r.animator().setFrameOrigin(NSPoint(x: r.frame.minX, y: dragBase + CGFloat(slot) * h))
                    }
                }
            }
            let vis = scroll.contentView.bounds
            if p.y < vis.minY + 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, vis.minY - 12))) }
            if p.y > vis.maxY - 20 { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, doc.frame.height - vis.height), vis.minY + 12))) }
            return
        }
        // 놓음
        let from = dragFrom
        dragRow = nil
        row.layer?.zPosition = 0; row.layer?.shadowOpacity = 0
        let revert = { [weak self] (msg: String) in self?.toast(msg); self?.applyLocal(main) }
        guard from >= 0, to != from else { applyLocal(main); return }
        if to == n - 1 && partial { revert("긴 플레이리스트는 불러온 곡 맨 끝으로는 못 옮겨요"); return }
        var m = main
        let moved = m.remove(at: from)
        m.insert(moved, at: to)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            row.animator().setFrameOrigin(NSPoint(x: row.frame.minX, y: dragBase + CGFloat(to) * h))
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.applyLocal(m) } })
        let before = to + 1 < m.count ? m[to + 1].setId : nil
        // 대기열은 '그 곡 앞에 꽂기' 자리로 (원래 순서 기준)
        let insertAt = to > from ? to + 1 : to
        music?.queueShuffled { [weak self] shuffled in
            guard let self else { return }
            // 섞어 듣는 중이면 다음 트랙 순서가 플레이리스트 순서와 달라서 못 옮김
            if shuffled { revert("섞어 듣기 중엔 순서를 바꿀 수 없어요"); return }
            self.music?.queueMove(from: item.index, to: insertAt, setId: item.setId) { _ in }
            self.music?.moveInPlaylist(link.id, setId: item.setId, before: before) { ok in
                if !ok { self.toast("플레이리스트 순서를 바꾸지 못했어요"); self.refreshQueue() }
            }
        }
    }

    // MARK: 이 곡의 앨범 재생

    private func albumMenu(_ item: QueueItem) -> NSMenu {
        let m = NSMenu()
        let head = NSMenuItem(title: "‘\(item.title)’ · \(item.artist)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())
        m.addItem(MenuAction("이 곡의 앨범, 이 곡부터 재생") { [weak self] in self?.playAlbum(item, fromSong: true) })
        m.addItem(MenuAction("이 곡의 앨범, 처음부터 재생") { [weak self] in self?.playAlbum(item, fromSong: false) })
        if !item.artistId.isEmpty {
            m.addItem(.separator())
            m.addItem(MenuAction("‘\(item.artist)’ 앨범 모두 보기") { [weak self] in self?.showAlbums(artistId: item.artistId) })
        }
        let who = RandomPlaylistWindow.mainArtist(item.artist)
        if !who.isEmpty {
            m.addItem(MenuAction("‘\(who)’를 랜덤 플레이리스트 가수에 넣기") { [weak self] in
                let w = RandomPlaylistWindow.shared
                w.show(music: self?.music)
                w.addArtists([(item.artistId, who)])
            })
        }
        if !item.videoId.isEmpty, let link = linked, item.auto || item.setId.isEmpty {
            m.addItem(.separator())
            m.addItem(MenuAction("‘\(link.title)’에 넣기 (지금 플레이리스트 · 다음 트랙 끝에)") { [weak self] in
                self?.addToLinked(PlaylistTrack(title: item.title, artist: item.artist, duration: item.duration, videoId: item.videoId, setId: "", thumb: ""), link: link) { _ in }
            })
        }
        if !item.videoId.isEmpty {
            m.addItem(.separator())
            let add = NSMenuItem(title: "플레이리스트에 넣기", action: nil, keyEquivalent: "")
            add.submenu = addMenu(vids: [item.videoId], albums: [])
            m.addItem(add)
        }
        return m
    }

    private func playAlbum(_ item: QueueItem, fromSong: Bool) {
        toast("‘\(item.title)’ 앨범 찾는 중…", stay: true)
        music?.findAlbum(item) { [weak self] a in
            guard let self else { return }
            guard let a else { self.toast("이 곡은 앨범을 찾지 못했어요 (라이브 · 커버 영상 등)"); return }
            self.music?.playAlbum(a, fromSong: fromSong)
            self.toast(a.name.isEmpty ? "앨범을 재생해요" : "‘\(a.name)’ 앨범을 재생해요")
            self.lastQueueKey = ""
            for t in [2.0, 4.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.loadQueue() } }
        }
    }

    /// 목록 아래쪽에 잠깐 뜨는 안내
    private let toastLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.alignment = .center
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        l.layer?.cornerRadius = 10
        l.textColor = .white
        l.isHidden = true
        return l
    }()
    private var toastID = 0
    private func toast(_ msg: String, stay: Bool = false) {
        if toastLabel.superview == nil { addSubview(toastLabel) }
        toastLabel.stringValue = "  \(msg)  "
        toastLabel.sizeToFit()
        let w = min(scroll.frame.width - 12, toastLabel.frame.width + 8)
        toastLabel.frame = NSRect(x: scroll.frame.midX - w / 2, y: scroll.frame.maxY - 34, width: w, height: 24)
        toastLabel.isHidden = false
        toastID += 1
        let id = toastID
        if !stay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.toastID == id else { return }
                self.toastLabel.isHidden = true
            }
        }
    }

    private func layoutRows() { Self.stack(doc, width: scroll.contentSize.width) }
    private func layoutAlbums() { Self.stack(albumDoc, width: albumScroll.contentSize.width) }
    /// 줄들을 위에서부터 차례로 (머리줄 · 곡 줄 · 앨범 줄 높이가 달라서)
    private static func stack(_ doc: NSView, width w: CGFloat) {
        var y: CGFloat = 0
        for r in doc.subviews {
            let h: CGFloat = r is SectionHead ? (r as! SectionHead).height : (r is AlbumRow ? AlbumRow.rowH : QueueRow.rowH)
            r.frame = NSRect(x: 0, y: y, width: w, height: h)
            (r as? QueueRow)?.relayout()
            r.needsLayout = true
            y += h
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: y)
    }

    // MARK: 가수 앨범 (앨범 탭)

    private let albumScroll = NSScrollView()
    private let albumDoc = FlippedView()
    private var albumArtist = ""
    /// 다음 트랙 메뉴에서 직접 고른 가수면 곡이 바뀌어도 그대로
    private var albumPinned = false

    private func albumsForCurrent() {
        music?.currentArtistId { [weak self] id in
            guard let self, let id, id != self.albumArtist else { return }
            self.loadAlbums(id)
        }
    }

    func showAlbums(artistId: String) {
        albumPinned = true
        tab = 2
        showTab()
        loadAlbums(artistId)
    }

    /// 불러온 가수 앨범 · 펼친 앨범 · 펼친 앨범의 수록곡 (앨범 ID → OLAK 목록 · 곡들)
    private var albumName = ""
    private var albumList: [AlbumEntry] = []
    private var expanded = Set<String>()
    private var albumTracks: [String: (list: String?, tracks: [QueueItem])] = [:]
    /// 고르기: 앨범 수록곡 (고른 순서대로)
    private var pickedTracks: [String] = []

    private func loadAlbums(_ id: String) {
        albumArtist = id
        albumDoc.subviews.forEach { $0.removeFromSuperview() }
        status.stringValue = "앨범 불러오는 중…"
        status.isHidden = tab != 2
        music?.artistAlbums(id) { [weak self] name, list in
            guard let self, self.albumArtist == id else { return }
            self.albumName = name
            self.albumList = list
            self.expanded = []
            self.drawAlbums()
            self.status.stringValue = list.isEmpty ? "앨범을 찾지 못했어요" : ""
            self.status.isHidden = self.tab != 2 || !list.isEmpty
            self.albumScroll.contentView.scroll(to: .zero)
        }
    }

    /// 앨범 줄들 (펼친 앨범은 아래에 수록곡)
    private func drawAlbums() {
        let keep = albumScroll.contentView.bounds.origin
        albumDoc.subviews.forEach { $0.removeFromSuperview() }
        let head = SectionHead(albumName.isEmpty ? "앨범" : albumName, big: true)
        if albumPinned {
            head.action = ("지금 곡 가수로", { [weak self] in self?.albumPinned = false; self?.albumArtist = ""; self?.albumsForCurrent() })
        }
        albumDoc.addSubview(head)
        var sec = ""
        for a in albumList {
            if a.section != sec { sec = a.section; albumDoc.addSubview(SectionHead(sec)) }
            var row: AlbumRow!
            row = AlbumRow(a) { [weak self] in self?.toggleExpand(a) }
            // 고르기 모드: 자켓 위 동그라미를 눌러야 앨범 통째로 고름 (줄의 나머지는 펼치기 · 접기)
            row.onCheck = { [weak self] in
                guard let self else { return }
                if self.pickedAlbums.contains(a.id) { self.pickedAlbums.remove(a.id) } else { self.pickedAlbums.insert(a.id) }
                row.check = self.pickedAlbums.contains(a.id)
                self.syncBar()
            }
            row.expanded = expanded.contains(a.id)
            row.onPlay = { [weak self] in self?.playAlbumEntry(a) }
            row.onExpand = { [weak self] in self?.toggleExpand(a) }
            row.makeMenu = { [weak self] in
                let m = NSMenu()
                m.addItem(MenuAction("처음부터 재생") { self?.playAlbumEntry(a) })
                m.addItem(MenuAction(self?.expanded.contains(a.id) == true ? "수록곡 접기" : "수록곡 보기") { self?.toggleExpand(a) })
                let add = NSMenuItem(title: "플레이리스트에 앨범 넣기", action: nil, keyEquivalent: "")
                add.submenu = self?.addMenu(vids: [], albums: [a.id])
                m.addItem(add)
                return m
            }
            if selecting { row.check = pickedAlbums.contains(a.id) }
            albumDoc.addSubview(row)
            guard expanded.contains(a.id) else { continue }
            guard let got = albumTracks[a.id] else { albumDoc.addSubview(SectionHead("   수록곡 불러오는 중…")); continue }
            if got.tracks.isEmpty { albumDoc.addSubview(SectionHead("   수록곡을 찾지 못했어요")); continue }
            for (k, t) in got.tracks.enumerated() {
                var tr: QueueRow!
                tr = QueueRow(item: t, width: 320) { [weak self] in
                    guard let self else { return }
                    if self.selecting {
                        if let i = self.pickedTracks.firstIndex(of: t.videoId) { self.pickedTracks.remove(at: i) } else { self.pickedTracks.append(t.videoId) }
                        tr.check = self.pickedTracks.contains(t.videoId)
                        self.syncBar()
                        return
                    }
                    // 이 곡부터 앨범 재생
                    if let l = got.list { self.music?.playList(l, from: t.videoId); self.toast("‘\(t.title)’부터 앨범을 재생해요") }
                    else { self.playVideos([t.videoId], title: t.title) }
                    self.lastQueueKey = ""
                }
                tr.translatesAutoresizingMaskIntoConstraints = true
                tr.number = k + 1
                if selecting { tr.check = pickedTracks.contains(t.videoId) }
                tr.makeMenu = { [weak self] in
                    let m = NSMenu()
                    m.addItem(MenuAction("이 곡만 재생") { self?.playVideos([t.videoId], title: t.title) })
                    if let l = got.list { m.addItem(MenuAction("이 곡부터 앨범 재생") { self?.music?.playList(l, from: t.videoId) }) }
                    let add = NSMenuItem(title: "플레이리스트에 넣기", action: nil, keyEquivalent: "")
                    add.submenu = self?.addMenu(vids: [t.videoId], albums: [])
                    m.addItem(add)
                    return m
                }
                albumDoc.addSubview(tr)
            }
        }
        layoutAlbums()
        albumScroll.contentView.scroll(to: keep)
        albumScroll.reflectScrolledClipView(albumScroll.contentView)
    }

    private func toggleExpand(_ a: AlbumEntry) {
        if expanded.contains(a.id) { expanded.remove(a.id); drawAlbums(); return }
        expanded.insert(a.id)
        drawAlbums()
        guard albumTracks[a.id] == nil else { return }
        music?.albumTracks(id: a.id) { [weak self] list, tracks in
            guard let self else { return }
            self.albumTracks[a.id] = (list, tracks)
            if self.expanded.contains(a.id) { self.drawAlbums() }
        }
    }

    /// 고른 곡만 재생: '고른 곡 (도구함)' 플레이리스트 하나를 새로 만들어 틀고, 전에 만든 건 지움
    /// (YouTube Music 은 곡 몇 개만으로 바로 재생 목록을 만드는 주소가 없어서)
    private func playVideos(_ vids: [String], title: String? = nil) {
        var seen = Set<String>()
        let vids = vids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard let first = vids.first else { return }
        if vids.count == 1 {
            // 한 곡이면 그 곡만 (자동재생 끔)
            music?.playVideo(first)
            toast("‘\(title ?? "고른 곡")’을 재생해요")
            return
        }
        toast("고른 \(vids.count)곡 준비 중…", stay: true)
        let key = "ytmPickedListId"
        if let old = UserDefaults.standard.string(forKey: key) {
            music?.deletePlaylist(old) { _ in }
            PlaylistPane.recentlyDeleted.insert(old)
        }
        music?.createPlaylist("고른 곡 (도구함)", videoIds: vids) { [weak self] id in
            guard let self else { return }
            guard let id else { self.toast("재생하지 못했어요 (로그인 확인)"); return }
            UserDefaults.standard.set(id, forKey: key)
            if self.selecting { self.setSelecting(false) }
            // 서버에 반영되기 전에 틀면 곡이 빠진 채로 시작해서 조금 기다렸다가
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.music?.playList(id)
                self?.toast("고른 \(vids.count)곡을 재생해요")
                self?.lastQueueKey = ""
                self?.plPane.reload(lists: true)
            }
        }
    }

    /// 고른 것 모두 → 곡 ID 들 (다음 트랙 곡 · 앨범 수록곡 · 고른 앨범의 모든 곡, 고른 순서대로)
    private func pickedVids(_ done: @escaping ([String]) -> Void) {
        var vids = selectedVids() + pickedTracks
        let albums = albumList.filter { pickedAlbums.contains($0.id) }
        var left = albums.count
        guard left > 0 else { done(vids); return }
        var got: [String: [String]] = [:]
        for a in albums {
            let finish = { (ts: [QueueItem]) in
                got[a.id] = ts.map(\.videoId)
                left -= 1
                if left == 0 { for a in albums { vids += got[a.id] ?? [] }; done(vids) }
            }
            if let c = albumTracks[a.id] { finish(c.tracks) }
            else { music?.albumTracks(id: a.id) { [weak self] l, ts in self?.albumTracks[a.id] = (l, ts); finish(ts) } }
        }
    }

    private func playAlbumEntry(_ a: AlbumEntry) {
        toast("‘\(a.title)’ 재생 준비 중…", stay: true)
        music?.playAlbum(id: a.id) { [weak self] ok in
            self?.toast(ok ? "‘\(a.title)’ 앨범을 재생해요" : "이 앨범은 재생 목록을 찾지 못했어요")
            self?.lastQueueKey = ""
        }
    }

    // MARK: 큰 앨범 사진

    /// 가운데를 정사각형으로 잘라 냄 (뮤직비디오 썸네일은 가로로 길어서 위아래가 비어 보였음)
    static func square(_ img: NSImage) -> NSImage {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
        let w = cg.width, h = cg.height
        guard abs(w - h) > 2 else { return img }
        let side = min(w, h)
        let r = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let c = cg.cropping(to: r) else { return img }
        return NSImage(cgImage: c, size: NSSize(width: side, height: side))
    }

    private func loadArt(_ url: String) {
        guard url != artURL else { return }
        artURL = url
        let big = url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w1200-h1200", options: .regularExpression)
        guard !url.isEmpty, let u = URL(string: big) else {
            art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil); return
        }
        fetchArt(u, fallback: URL(string: url), for: url)
    }
    /// 큰 사진(1200px)을 받고, 안 되면 원래 사진으로
    private func fetchArt(_ u: URL, fallback: URL?, for url: String) {
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let img = NSImage(data: data) else {
                if let f = fallback, f != u { DispatchQueue.main.async { MainActor.assumeIsolated { self.fetchArt(f, fallback: nil, for: url) } } }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.artURL == url else { return }
                    self.art.image = Self.square(img)
                }
            }
        }.resume()
    }
}

// MARK: - 소리 보정 팝업 — 켜 둬도 서로 부딪히지 않는 네 가지를 위에서부터 차례로
//   ① 소리 보정 (전체 켜기 · 끄기: 눌러서 바로 비교)
//   ② 내 취향: 프리셋 · 10밴드 (저음 강조 · 보컬 …)
//   ③ 곡마다 자동 맞춤: 곡마다 다른 녹음 상태를 들어 보고 고르게 (31칸)
//   ④ 작게 들을 때 보정: 볼륨이 작을수록 약해지는 저음 · 고음을 채움
//   + 정밀 EQ… : 그래프에서 직접 (고급)

@MainActor
final class EQViewController: NSViewController {
    private weak var music: YTMusic?
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    private let master = NSSwitch()
    private let masterLabel = NSTextField(labelWithString: "소리 보정")
    private let tasteBox = NSButton(checkboxWithTitle: "내 취향", target: nil, action: nil)
    private let preset = NSPopUpButton()
    private let autoBox = NSButton(checkboxWithTitle: "곡마다 자동 맞춤", target: nil, action: nil)
    private let autoInfo = NSTextField(labelWithString: "")
    private let loudBox = NSButton(checkboxWithTitle: "작게 들을 때 보정", target: nil, action: nil)
    private let loudSlider = NSSlider()
    private let loudInfo = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(music: YTMusic?) { self.music = music; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    private func small(_ t: String, _ size: CGFloat = 10.5) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: size); l.textColor = .secondaryLabelColor
        return l
    }
    private func line(_ v: NSView, y: CGFloat, w: CGFloat) {
        let b = NSBox(frame: NSRect(x: 14, y: y, width: w - 28, height: 1)); b.boxType = .separator; v.addSubview(b)
    }

    override func loadView() {
        let W: CGFloat = 440, H: CGFloat = 400
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // ① 맨 위: 소리 보정 전체 켜기 · 정밀 EQ
        masterLabel.font = .boldSystemFont(ofSize: 13)
        masterLabel.frame = NSRect(x: 14, y: H - 32, width: 80, height: 18)
        v.addSubview(masterLabel)
        master.target = self; master.action = #selector(masterToggled)
        master.controlSize = .small
        master.frame = NSRect(x: 92, y: H - 33, width: 40, height: 20)
        v.addSubview(master)
        let mh = small("끄면 원래 소리 (눌러서 비교)")
        mh.frame = NSRect(x: 136, y: H - 31, width: 170, height: 15)
        v.addSubview(mh)
        let precise = NSButton(title: "정밀 EQ…", target: self, action: #selector(openPrecise))
        precise.controlSize = .small; precise.bezelStyle = .rounded
        precise.toolTip = "그래프에서 점을 끌어 세밀하게 · 실시간 소리 그림 (고급)"
        precise.frame = NSRect(x: W - 14 - 84, y: H - 35, width: 84, height: 24)
        v.addSubview(precise)
        line(v, y: H - 46, w: W)

        // ② 내 취향 (10밴드)
        tasteBox.target = self; tasteBox.action = #selector(tasteToggled)
        tasteBox.frame = NSRect(x: 14, y: H - 74, width: 80, height: 20)
        v.addSubview(tasteBox)
        preset.addItems(withTitles: YTMusic.eqPresets.map(\.0) + ["직접 설정"])
        preset.target = self; preset.action = #selector(presetPicked)
        preset.controlSize = .small
        preset.frame = NSRect(x: 96, y: H - 76, width: 130, height: 24)
        v.addSubview(preset)
        let th = small("좋아하는 소리 고르기")
        th.lineBreakMode = .byTruncatingTail
        th.frame = NSRect(x: 232, y: H - 72, width: W - 14 - 60 - 6 - 232, height: 15)
        v.addSubview(th)
        let reset = NSButton(title: "초기화", target: self, action: #selector(resetAll))
        reset.controlSize = .small; reset.bezelStyle = .rounded
        reset.frame = NSRect(x: W - 14 - 60, y: H - 76, width: 60, height: 24)
        v.addSubview(reset)

        let n = YTMusic.eqFreqs.count
        let colW = (W - 28) / CGFloat(n)
        let top: CGFloat = H - 86, bottom: CGFloat = 176
        let zero = NSBox(frame: NSRect(x: 14, y: bottom + (top - bottom - 30) / 2 + 8, width: W - 28, height: 1))
        zero.boxType = .custom; zero.borderWidth = 0; zero.fillColor = NSColor.labelColor.withAlphaComponent(0.12)
        v.addSubview(zero)
        for (i, f) in YTMusic.eqFreqs.enumerated() {
            let x = 14 + CGFloat(i) * colW
            let s = NSSlider(value: 0, minValue: -12, maxValue: 12, target: self, action: #selector(slid(_:)))
            s.isVertical = true; s.tag = i; s.isContinuous = true
            s.frame = NSRect(x: x + colW / 2 - 11, y: bottom, width: 22, height: top - bottom - 30)
            v.addSubview(s); sliders.append(s)
            let val = NSTextField(labelWithString: "0")
            val.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            val.textColor = .secondaryLabelColor; val.alignment = .center
            val.frame = NSRect(x: x, y: top - 26, width: colW, height: 14)
            v.addSubview(val); values.append(val)
            let lab = small(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", 10)
            lab.alignment = .center
            lab.frame = NSRect(x: x, y: bottom - 16, width: colW, height: 14)
            v.addSubview(lab)
        }
        line(v, y: 150, w: W)

        // ③ 곡마다 자동 맞춤
        autoBox.target = self; autoBox.action = #selector(autoToggled)
        autoBox.frame = NSRect(x: 14, y: 122, width: 150, height: 20)
        v.addSubview(autoBox)
        let now = NSButton(title: "지금 곡 맞추기", target: self, action: #selector(autoNow))
        now.controlSize = .small; now.bezelStyle = .rounded
        now.frame = NSRect(x: W - 14 - 100, y: 120, width: 100, height: 24)
        v.addSubview(now)
        autoInfo.font = .systemFont(ofSize: 10.5); autoInfo.textColor = .secondaryLabelColor
        autoInfo.lineBreakMode = .byTruncatingTail
        autoInfo.frame = NSRect(x: 34, y: 104, width: W - 48, height: 15)
        v.addSubview(autoInfo)
        line(v, y: 94, w: W)

        // ④ 작게 들을 때 보정
        loudBox.target = self; loudBox.action = #selector(loudToggled)
        loudBox.frame = NSRect(x: 14, y: 66, width: 150, height: 20)
        v.addSubview(loudBox)
        let sl = small("세기", 11)
        sl.frame = NSRect(x: 170, y: 68, width: 30, height: 15)
        v.addSubview(sl)
        loudSlider.minValue = 0; loudSlider.maxValue = 1.5
        loudSlider.controlSize = .small
        loudSlider.target = self; loudSlider.action = #selector(loudStrength)
        loudSlider.frame = NSRect(x: 200, y: 66, width: W - 214, height: 20)
        v.addSubview(loudSlider)
        loudInfo.font = .systemFont(ofSize: 10.5); loudInfo.textColor = .secondaryLabelColor
        loudInfo.frame = NSRect(x: 34, y: 48, width: W - 48, height: 15)
        v.addSubview(loudInfo)
        line(v, y: 38, w: W)

        // 맨 아래: 한 줄 요약 · 문제 안내
        note.font = .systemFont(ofSize: 10.5)
        note.maximumNumberOfLines = 2
        note.frame = NSRect(x: 14, y: 6, width: W - 28, height: 28)
        v.addSubview(note)

        view = v
        preferredContentSize = v.frame.size
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncInfo() } }
        for n in [Notification.Name.tapEQProblem, .eqChanged] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        }
    }
    override func viewDidDisappear() { super.viewDidDisappear(); timer?.invalidate() }

    private func sync() {
        let on = YTMusic.masterOn
        master.state = on ? .on : .off
        tasteBox.state = YTMusic.eqOn ? .on : .off
        autoBox.state = YTMusic.auto31On ? .on : .off
        loudBox.state = YTMusic.loudOn ? .on : .off
        loudSlider.doubleValue = YTMusic.loudStrength
        let g = YTMusic.eqGains
        for (i, s) in sliders.enumerated() {
            s.doubleValue = g[i]
            s.isEnabled = on && YTMusic.eqOn
            values[i].stringValue = g[i] == 0 ? "0" : String(format: "%+.0f", g[i])
        }
        preset.selectItem(withTitle: YTMusic.eqPreset)
        preset.isEnabled = on && YTMusic.eqOn
        for c in [tasteBox, autoBox, loudBox] as [NSControl] { c.isEnabled = on }
        loudSlider.isEnabled = on && YTMusic.loudOn
        syncInfo()
    }

    /// 상태 글 (1초마다: 저음량 보정 값이 볼륨 따라 바뀌어서)
    private func syncInfo() {
        autoInfo.stringValue = !YTMusic.auto31On ? "곡마다 다른 녹음 상태(저음이 많은 곡 · 쨍한 곡)를 들어 보고 고르게 맞춰요"
            : (YTMusic.auto31Gains.allSatisfy { $0 == 0 } ? "곡이 바뀌면 8초 듣고 맞춰요 · 지금 곡은 '지금 곡 맞추기'" : "지금 곡에 맞춰 놓았어요 (곡이 바뀌면 다시 맞춰요)")
        if !YTMusic.loudOn { loudInfo.stringValue = "볼륨을 작게 할수록 약하게 들리는 저음 · 고음을 채워요" }
        else {
            let l = TapEQ.shared.loudShown
            loudInfo.stringValue = l.bass < 0.3 ? "지금 볼륨에선 보정할 필요가 없어요" :
                String(format: "지금 볼륨에 맞춰 저음 +%.1f · 고음 +%.1fdB 채우는 중", l.bass, l.treble)
        }
        if let p = TapEQ.shared.problem { note.textColor = .systemOrange; note.stringValue = p }
        else {
            note.textColor = .secondaryLabelColor
            let peq = YTMusic.peqOn && !YTMusic.peqFilters.isEmpty
            let n = [YTMusic.eqOn, YTMusic.auto31On, YTMusic.loudOn, peq].filter { $0 }.count
            note.stringValue = !YTMusic.masterOn ? "소리 보정이 꺼져 있어요 — 원래 소리 그대로예요"
                : (n == 0 ? "켜진 보정이 없어요 · 다 켜 둬도 서로 부딪히지 않아요"
                   : "켜진 것들이 모두 합쳐져 적용돼요 · 다 켜 둬도 괜찮아요" + (peq ? " (정밀 EQ 포함)" : ""))
        }
    }

    private func apply() { music?.applyEQ(); sync() }
    @objc private func masterToggled() { YTMusic.masterOn = master.state == .on; apply() }
    @objc private func tasteToggled() { YTMusic.eqOn = tasteBox.state == .on; apply() }
    @objc private func autoToggled() {
        YTMusic.auto31On = autoBox.state == .on
        if !YTMusic.auto31On { YTMusic.auto31Gains = Array(repeating: 0, count: 31) }
        apply()
        if YTMusic.auto31On { autoNow() }
    }
    @objc private func autoNow() {
        if !YTMusic.auto31On { YTMusic.auto31On = true; apply() }
        autoInfo.stringValue = "지금 곡을 듣는 중… (8초)"
        music?.runAuto31 { [weak self] ok in
            if !ok { self?.autoInfo.stringValue = "소리가 충분히 들리지 않았어요 · 재생 중일 때 다시 눌러 주세요" } else { self?.syncInfo() }
        }
    }
    @objc private func loudToggled() { YTMusic.loudOn = loudBox.state == .on; apply() }
    @objc private func loudStrength() { YTMusic.loudStrength = loudSlider.doubleValue; music?.updateLoudness(); syncInfo() }
    @objc private func openPrecise() { PEQWindow.shared.show(music: music) }
    @objc private func presetPicked() {
        guard let t = preset.titleOfSelectedItem, let p = YTMusic.eqPresets.first(where: { $0.0 == t }) else { return }
        YTMusic.eqPreset = t; YTMusic.eqGains = p.1
        apply()
    }
    @objc private func slid(_ s: NSSlider) {
        var g = YTMusic.eqGains
        g[s.tag] = s.doubleValue.rounded()
        YTMusic.eqGains = g
        YTMusic.eqPreset = YTMusic.eqPresets.first(where: { $0.1 == g })?.0 ?? "직접 설정"
        apply()
    }
    @objc private func resetAll() {
        YTMusic.eqGains = Array(repeating: 0, count: 10); YTMusic.eqPreset = "기본"
        apply()
    }
}

/// 목록 사이 머리줄 (자동재생 · 앨범 · 싱글 및 EP · 가수 이름)
final class SectionHead: NSView {
    let height: CGFloat
    private let label: NSTextField
    private var button: NSButton?
    var action: (String, () -> Void)? {
        didSet {
            button?.removeFromSuperview()
            guard let (t, _) = action else { return }
            let b = NSButton(title: t, target: self, action: #selector(tapped))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .launcherAccent
            addSubview(b); button = b
        }
    }
    @objc private func tapped() { action?.1() }
    override var isFlipped: Bool { true }
    init(_ text: String, big: Bool = false) {
        height = big ? 34 : 26
        label = NSTextField(labelWithString: text)
        label.font = big ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = big ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        super.init(frame: .zero)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        button?.sizeToFit()
        let bw = button?.frame.width ?? 0
        button?.frame = NSRect(x: bounds.width - bw - 10, y: (height - 18) / 2, width: bw, height: 18)
        label.frame = NSRect(x: 12, y: height - 20 - 3, width: bounds.width - 24 - bw, height: 20)
    }
}

/// 앨범 한 줄: 표지 · 이름 · (싱글 • 2023년). 누르면 그 앨범 처음부터
@MainActor
final class AlbumRow: NSView {
    static let rowH: CGFloat = 56
    private let entry: AlbumEntry
    private let onClick: () -> Void
    private let cover = NSImageView()
    private let t: NSTextField, s: NSTextField
    private var hovering = false { didSet { needsDisplay = true } }
    private static var cache: [String: NSImage] = [:]
    var makeMenu: (() -> NSMenu)?
    private let badge = NSImageView()
    /// 펼침 표시 ▸ / ▾ 와 ▶ 재생 단추
    var onPlay: (() -> Void)?
    var onExpand: (() -> Void)?
    var onCheck: (() -> Void)?
    var expanded = false { didSet { chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil) } }
    private let chevron = NSImageView()
    private lazy var playBtn: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "처음부터 재생")!, target: self, action: #selector(playTapped))
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "처음부터 재생"
        addSubview(b)
        return b
    }()
    @objc private func playTapped() { onPlay?() }
    /// 고르기 모드 체크 (nil = 보통)
    var check: Bool? {
        didSet {
            badge.isHidden = check == nil
            badge.image = NSImage(systemSymbolName: check == true ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
            badge.contentTintColor = check == true ? .launcherAccent : .white
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let m = makeMenu?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
    override var isFlipped: Bool { true }

    init(_ e: AlbumEntry, onClick: @escaping () -> Void) {
        entry = e; self.onClick = onClick
        t = NSTextField(labelWithString: e.title)
        s = NSTextField(labelWithString: e.sub)
        super.init(frame: .zero)
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 5
        cover.layer?.masksToBounds = true
        cover.imageScaling = .scaleProportionallyUpOrDown
        addSubview(cover)
        t.font = .systemFont(ofSize: QueueRow.titleSize, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        addSubview(t)
        s.font = .systemFont(ofSize: QueueRow.subSize)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingTail
        addSubview(s)
        toolTip = "눌러서 수록곡 보기 · ▶ 처음부터 재생 · 오른쪽 클릭: 플레이리스트에 넣기"
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        addSubview(chevron)
        badge.isHidden = true
        badge.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        addSubview(badge)
        loadCover()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func loadCover() {
        if let c = Self.cache[entry.thumb] { cover.image = c; return }
        guard let u = URL(string: entry.thumb) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] d, _, _ in
            guard let d, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Self.cache[self.entry.thumb] = img
                    self.cover.image = img
                }
            }
        }.resume()
    }

    override func layout() {
        super.layout()
        cover.frame = NSRect(x: 10, y: 6, width: 44, height: 44)
        badge.frame = NSRect(x: 34, y: 28, width: 20, height: 20)
        let x: CGFloat = 64, w = bounds.width - x - 10 - 52
        t.frame = NSRect(x: x, y: 10, width: w, height: 18)
        s.frame = NSRect(x: x, y: 29, width: w, height: 16)
        playBtn.frame = NSRect(x: bounds.width - 58, y: 14, width: 28, height: 28)
        chevron.frame = NSRect(x: bounds.width - 24, y: 21, width: 14, height: 14)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        // 고르기 모드에서 자켓(동그라미) 쪽을 누르면 고르기, 나머지는 펼치기 · 접기
        if check != nil, p.x < 60, let c = onCheck { c(); return }
        onClick()
    }
}


/// 고르는 중일 때 목록 아래 줄: "3곡 골랐어요  [플레이리스트에 넣기 ▾] [취소]"
@MainActor
final class SelectBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let addBtn = NSButton(title: "플레이리스트에 넣기 ▾", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "취소", target: nil, action: nil)
    private let playBtn = NSButton(title: "▶ 재생", target: nil, action: nil)
    private let removeBtn = NSButton(title: "빼기", target: nil, action: nil)
    /// 내 플레이리스트와 연결된 다음 트랙에서 고른 곡 빼기 (nil 이면 버튼 없음)
    var onRemove: (() -> Void)?
    var canRemove = false { didSet { removeBtn.isHidden = !canRemove; needsLayout = true } }
    var onPlay: (() -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onCancel: (() -> Void)?
    var text: String { get { label.stringValue } set { label.stringValue = newValue } }
    var canAdd = false { didSet { addBtn.isEnabled = canAdd; playBtn.isEnabled = canAdd } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 10
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        for b in [removeBtn, playBtn, addBtn, cancelBtn] { b.controlSize = .small; b.bezelStyle = .rounded; b.target = self; addSubview(b) }
        removeBtn.action = #selector(removeTapped)
        removeBtn.contentTintColor = .systemRed
        removeBtn.toolTip = "고른 곡을 지금 플레이리스트와 다음 트랙에서 빼기"
        removeBtn.isHidden = true
        addBtn.action = #selector(addTapped); cancelBtn.action = #selector(cancelTapped); playBtn.action = #selector(playTapped)
        playBtn.toolTip = "고른 곡만 바로 재생 (앨범을 고르면 그 앨범의 모든 곡)"
        addBtn.keyEquivalent = "\r"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func addTapped() { onAdd?(addBtn) }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func playTapped() { onPlay?() }
    @objc private func removeTapped() { onRemove?() }
    override func layout() {
        super.layout()
        cancelBtn.sizeToFit(); addBtn.sizeToFit(); playBtn.sizeToFit(); removeBtn.sizeToFit()
        cancelBtn.frame = NSRect(x: bounds.width - cancelBtn.frame.width - 6, y: (bounds.height - 22) / 2, width: cancelBtn.frame.width, height: 22)
        addBtn.frame = NSRect(x: cancelBtn.frame.minX - addBtn.frame.width - 4, y: (bounds.height - 22) / 2, width: addBtn.frame.width, height: 22)
        playBtn.frame = NSRect(x: addBtn.frame.minX - playBtn.frame.width - 4, y: (bounds.height - 22) / 2, width: playBtn.frame.width, height: 22)
        removeBtn.frame = NSRect(x: playBtn.frame.minX - (removeBtn.isHidden ? 0 : removeBtn.frame.width + 4), y: (bounds.height - 22) / 2, width: removeBtn.frame.width, height: 22)
        let left = removeBtn.isHidden ? playBtn.frame.minX : removeBtn.frame.minX
        label.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: max(20, left - 14), height: 16)
    }
}

/// 손으로 스크롤한 걸 알려 주는 스크롤 칸 (그동안엔 목록을 저절로 옮기지 않게)
final class WheelScrollView: NSScrollView {
    var onWheel: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { onWheel?(); super.scrollWheel(with: event) }
}
