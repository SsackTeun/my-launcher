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
    static let height: CGFloat = 300
    static let minWidth: CGFloat = 560

    private weak var music: YTMusic?
    /// 가사 탭에 넣을 가사 줄 (도구함이 쓰는 것과 같은 것)
    private let lyricsView: NSView
    private let art = NSImageView()
    private let tabs = NSSegmentedControl(labels: ["다음 트랙", "가사", "앨범", "재생목록"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
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
    static let controlsH: CGFloat = 40
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
        selectBtn.toolTip = "여러 곡 · 앨범을 골라 재생목록에 넣기"
        selectBtn.target = self; selectBtn.action = #selector(toggleSelect)
        addSubview(selectBtn)
        NotificationCenter.default.addObserver(forName: Notification.Name("openEQPopover"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.window != nil { self.showEQ(from: self.eqBtn) } }
        }
        actionBar.isHidden = true
        actionBar.onAdd = { [weak self] b in self?.showAddMenu(from: b, vids: self?.selectedVids() ?? [], albums: self?.selectedAlbums() ?? []) }
        actionBar.onCancel = { [weak self] in self?.setSelecting(false) }
        addSubview(actionBar)
    }

    // MARK: 재생목록 · 고르기

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
        pickedQueue = []; pickedAlbums = []
        selectBtn.contentTintColor = on ? .launcherAccent : nil
        for r in doc.subviews { (r as? QueueRow)?.check = on ? false : nil }
        for r in albumDoc.subviews { (r as? AlbumRow)?.check = on ? false : nil }
        syncBar()
        needsLayout = true
    }
    private func syncBar() {
        let n = pickedQueue.count + pickedAlbums.count
        actionBar.isHidden = !selecting
        actionBar.text = n == 0 ? "곡 · 앨범을 눌러 고르세요" : "\(pickedQueue.count > 0 ? "\(pickedQueue.count)곡" : "")\(pickedQueue.count > 0 && pickedAlbums.count > 0 ? " · " : "")\(pickedAlbums.count > 0 ? "앨범 \(pickedAlbums.count)개" : "") 골랐어요"
        actionBar.canAdd = n > 0
    }
    private func selectedVids() -> [String] { items.filter { pickedQueue.contains($0.index) }.map(\.videoId).filter { !$0.isEmpty } }
    private func selectedAlbums() -> [String] { Array(pickedAlbums) }

    /// 재생목록 고르는 메뉴 (내 재생목록들 + 새 재생목록…)
    private func addMenu(vids: [String], albums: [String]) -> NSMenu {
        let m = NSMenu()
        if plPane.playlists.isEmpty {
            let i = NSMenuItem(title: "재생목록 불러오는 중…", action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
            plPane.reload()
        }
        for pl in plPane.playlists {
            m.addItem(MenuAction(pl.title) { [weak self] in self?.add(to: pl.id, title: pl.title, vids: vids, albums: albums) })
        }
        m.addItem(.separator())
        m.addItem(MenuAction("새 재생목록…") { [weak self] in
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
        plPane.reload()   // 재생목록 탭 · '재생목록에 넣기' 메뉴에 쓸 목록 미리
    }

    /// 재생 · 반복 · 음소거 모양을 지금 상태로
    private func syncControls() {
        guard let st = music?.state else { return }
        playBtn.image = NSImage(systemSymbolName: st.playing == true ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        repBtn.image = NSImage(systemSymbolName: st.repeatOne ? "repeat.1" : "repeat", accessibilityDescription: nil)
        repBtn.contentTintColor = st.repeatOn ? .launcherAccent : nil
        spkBtn.image = NSImage(systemSymbolName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
        eqBtn.contentTintColor = YTMusic.eqOn && YTMusic.eqGains.contains(where: { $0 != 0 }) ? .launcherAccent : nil
    }

    private var ticks = 0
    private func tick() {
        syncControls()
        guard let st = music?.state else { return }
        ticks += 1
        loadArt(st.artURL)
        // 곡이 바뀌었거나 몇 초마다 다음 트랙을 새로 (목록이 늘거나 섞일 수 있어서)
        if tab == 0, st.title != lastTitle || ticks % 4 == 0 { loadQueue() }
        // 앨범 탭: 직접 고른 가수가 아니면 지금 곡의 가수를 따라감
        if tab == 2, st.title != lastTitle, !albumPinned { albumsForCurrent() }
        // 처음 켤 땐 페이지가 덜 떠서 목록을 못 받을 수 있어 몇 번 더
        if plPane.playlists.isEmpty, ticks % 3 == 0, ticks < 40 { plPane.reload() }
        lastTitle = st.title
    }

    @objc private func tabChanged() {
        tab = tabs.selectedSegment
        showTab()
        if tab == 0 { loadQueue() }
        if tab == 2 { albumsForCurrent() }
        if tab == 3 { plPane.reload() }
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
        if selecting && selectBtn.isHidden { setSelecting(false) }
        needsLayout = true
    }

    // MARK: 배치

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let side = max(80, min(bounds.height - pad * 2 - Self.controlsH, bounds.width * 0.46))
        art.frame = NSRect(x: pad + 2, y: pad, width: side, height: side)
        // 앨범 밑 가운데에 재생 버튼: ◀◀ ▶ ▶▶ 🔁 🔊 — 모두 같은 칸 크기 · 같은 가운데 줄, 옅은 알약 바탕 위에
        let cell: CGFloat = 32, gap: CGFloat = 4
        let total = cell * CGFloat(ctl.count) + gap * CGFloat(ctl.count - 1)
        let pillH: CGFloat = 32
        let py = art.frame.maxY + (Self.controlsH - pillH) / 2 + 2
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
        // 고르는 중이면 아래에 '재생목록에 넣기' 줄
        var body = full
        if selecting { body.size.height -= 36; actionBar.frame = NSRect(x: full.minX, y: body.maxY + 4, width: full.width, height: 30) }
        scroll.frame = body
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
        let key = items.map { "\($0.title)|\($0.current)" }.joined(separator: "\n")
        guard key != lastQueueKey else { return }
        lastQueueKey = key
        self.items = items
        doc.subviews.forEach { $0.removeFromSuperview() }
        var autoHead = false
        // 맨 위: 몇 곡 중 몇 번째 (자동재생으로 붙은 곡은 빼고 셈)
        let main = items.filter { !$0.auto }
        if !main.isEmpty {
            let k = main.firstIndex(where: { $0.current }).map { " · 지금 \($0 + 1)번째" } ?? ""
            doc.addSubview(SectionHead("\(main.count)곡\(k)"))
        }
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
            r.makeMenu = { [weak self] in self?.albumMenu(item) ?? NSMenu() }
            if item.auto { r.alphaValue = 0.6 }
            doc.addSubview(r)
        }
        status.stringValue = items.isEmpty ? "다음 트랙을 찾지 못했어요\n곡을 재생하면 여기에 보여요" : ""
        status.isHidden = tab != 0 || !items.isEmpty
        layoutRows()
        // 지금 곡이 보이게 (위에 한 곡 남기고)
        if let r = doc.subviews.first(where: { ($0 as? QueueRow)?.isCurrent == true }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, r.frame.minY - QueueRow.rowH)))
            scroll.reflectScrolledClipView(scroll.contentView)
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
        if !item.videoId.isEmpty {
            m.addItem(.separator())
            let add = NSMenuItem(title: "재생목록에 넣기", action: nil, keyEquivalent: "")
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

    private func loadAlbums(_ id: String) {
        albumArtist = id
        albumDoc.subviews.forEach { $0.removeFromSuperview() }
        status.stringValue = "앨범 불러오는 중…"
        status.isHidden = tab != 2
        music?.artistAlbums(id) { [weak self] name, list in
            guard let self, self.albumArtist == id else { return }
            self.albumDoc.subviews.forEach { $0.removeFromSuperview() }
            let head = SectionHead(name.isEmpty ? "앨범" : name, big: true)
            if self.albumPinned {
                head.action = ("지금 곡 가수로", { [weak self] in self?.albumPinned = false; self?.albumArtist = ""; self?.albumsForCurrent() })
            }
            self.albumDoc.addSubview(head)
            var sec = ""
            for a in list {
                if a.section != sec { sec = a.section; self.albumDoc.addSubview(SectionHead(sec)) }
                var row: AlbumRow!
                row = AlbumRow(a) { [weak self] in
                    guard let self else { return }
                    if self.selecting {
                        if self.pickedAlbums.contains(a.id) { self.pickedAlbums.remove(a.id) } else { self.pickedAlbums.insert(a.id) }
                        row.check = self.pickedAlbums.contains(a.id)
                        self.syncBar()
                        return
                    }
                    self.playAlbumEntry(a)
                }
                row.makeMenu = { [weak self] in
                    let m = NSMenu()
                    m.addItem(MenuAction("처음부터 재생") { self?.playAlbumEntry(a) })
                    let add = NSMenuItem(title: "재생목록에 앨범 넣기", action: nil, keyEquivalent: "")
                    add.submenu = self?.addMenu(vids: [], albums: [a.id])
                    m.addItem(add)
                    return m
                }
                if self.selecting { row.check = self.pickedAlbums.contains(a.id) }
                self.albumDoc.addSubview(row)
            }
            self.status.stringValue = list.isEmpty ? "앨범을 찾지 못했어요" : ""
            self.status.isHidden = self.tab != 2 || !list.isEmpty
            self.layoutAlbums()
            self.albumScroll.contentView.scroll(to: .zero)
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
        let big = url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w600-h600", options: .regularExpression)
        guard !url.isEmpty, let u = URL(string: big) else {
            art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil); return
        }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
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
        toolTip = "‘\(e.title)’ 처음부터 재생 · 오른쪽 클릭: 재생목록에 넣기"
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
        let x: CGFloat = 64, w = bounds.width - x - 10
        t.frame = NSRect(x: x, y: 10, width: w, height: 18)
        s.frame = NSRect(x: x, y: 29, width: w, height: 16)
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}


/// 고르는 중일 때 목록 아래 줄: "3곡 골랐어요  [재생목록에 넣기 ▾] [취소]"
@MainActor
final class SelectBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let addBtn = NSButton(title: "재생목록에 넣기 ▾", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "취소", target: nil, action: nil)
    var onAdd: ((NSView) -> Void)?
    var onCancel: (() -> Void)?
    var text: String { get { label.stringValue } set { label.stringValue = newValue } }
    var canAdd = false { didSet { addBtn.isEnabled = canAdd } }
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
        for b in [addBtn, cancelBtn] { b.controlSize = .small; b.bezelStyle = .rounded; b.target = self; addSubview(b) }
        addBtn.action = #selector(addTapped); cancelBtn.action = #selector(cancelTapped)
        addBtn.keyEquivalent = "\r"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func addTapped() { onAdd?(addBtn) }
    @objc private func cancelTapped() { onCancel?() }
    override func layout() {
        super.layout()
        cancelBtn.sizeToFit(); addBtn.sizeToFit()
        cancelBtn.frame = NSRect(x: bounds.width - cancelBtn.frame.width - 6, y: (bounds.height - 22) / 2, width: cancelBtn.frame.width, height: 22)
        addBtn.frame = NSRect(x: cancelBtn.frame.minX - addBtn.frame.width - 4, y: (bounds.height - 22) / 2, width: addBtn.frame.width, height: 22)
        label.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: max(20, addBtn.frame.minX - 14), height: 16)
    }
}
