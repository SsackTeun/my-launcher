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
    private let tabs = NSSegmentedControl(labels: ["다음 트랙", "가사"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var lastTitle = ""
    private var artURL = ""
    private var lastQueueKey = ""
    /// 앨범 밑 재생 버튼 (위 플레이어 줄의 것을 여기로 옮겨 온 것)
    private var ctl: [ActionButton] = []
    private var playBtn: ActionButton!, repBtn: ActionButton!, spkBtn: ScrollButton!
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
        ctl = [prev, playBtn, next, repBtn, spkBtn]
        // 버튼들을 감싸는 옅은 알약 바탕 (앨범 · 목록과 구분)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        pill.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        pill.layer?.borderWidth = 1
        addSubview(pill, positioned: .below, relativeTo: prev)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)
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
    }

    /// 재생 · 반복 · 음소거 모양을 지금 상태로
    private func syncControls() {
        guard let st = music?.state else { return }
        playBtn.image = NSImage(systemSymbolName: st.playing == true ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        repBtn.image = NSImage(systemSymbolName: st.repeatOne ? "repeat.1" : "repeat", accessibilityDescription: nil)
        repBtn.contentTintColor = st.repeatOn ? .launcherAccent : nil
        spkBtn.image = NSImage(systemSymbolName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
    }

    private var ticks = 0
    private func tick() {
        syncControls()
        guard let st = music?.state else { return }
        ticks += 1
        loadArt(st.artURL)
        // 곡이 바뀌었거나 몇 초마다 다음 트랙을 새로 (목록이 늘거나 섞일 수 있어서)
        if tab == 0, st.title != lastTitle || ticks % 4 == 0 { loadQueue() }
        lastTitle = st.title
    }

    @objc private func tabChanged() {
        tab = tabs.selectedSegment
        showTab()
        if tab == 0 { loadQueue() }
    }

    private func showTab() {
        tabs.selectedSegment = tab
        let q = tab == 0
        scroll.isHidden = !q
        status.isHidden = !q || !doc.subviews.isEmpty
        if q { lyricsView.removeFromSuperview() } else if lyricsView.superview !== self { addSubview(lyricsView) }
        needsLayout = true
    }

    // MARK: 배치

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let side = max(80, min(bounds.height - pad * 2 - Self.controlsH, bounds.width * 0.46))
        art.frame = NSRect(x: pad + 2, y: pad, width: side, height: side)
        // 앨범 밑 가운데에 재생 버튼: ◀◀ ▶ ▶▶ 🔁 🔊 — 모두 같은 칸 크기 · 같은 가운데 줄, 옅은 알약 바탕 위에
        let cell: CGFloat = 34, gap: CGFloat = 6
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
        tabs.frame = NSRect(x: x, y: pad - 2, width: min(w, max(tabs.frame.width, 160)), height: 24)
        let body = NSRect(x: x - 6, y: tabs.frame.maxY + 6, width: w + 6, height: bounds.height - tabs.frame.maxY - 6 - 4)
        scroll.frame = body
        status.frame = NSRect(x: body.minX, y: body.midY - 9, width: body.width, height: 18)
        if lyricsView.superview === self { lyricsView.frame = body }
        layoutRows()
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
        for item in items {
            let r = QueueRow(item: item, width: 320) { [weak self] in
                self?.music?.play(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.lastQueueKey = ""; self?.loadQueue() }
            }
            r.translatesAutoresizingMaskIntoConstraints = true
            doc.addSubview(r)
        }
        status.stringValue = items.isEmpty ? "다음 트랙을 찾지 못했어요\n곡을 재생하면 여기에 보여요" : ""
        status.isHidden = tab != 0 || !items.isEmpty
        layoutRows()
        // 지금 곡이 보이게 (위에 한 곡 남기고)
        if let i = items.firstIndex(where: { $0.current }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, CGFloat(i - 1) * QueueRow.rowH)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func layoutRows() {
        let w = scroll.contentSize.width
        for (i, r) in doc.subviews.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * QueueRow.rowH, width: w, height: QueueRow.rowH)
            (r as? QueueRow)?.relayout()
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(doc.subviews.count) * QueueRow.rowH)
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
