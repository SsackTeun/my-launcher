// 미니 플레이어 화면: 앨범 사진 · 곡 정보 · 좋아요 · 진행바 · 셔플/이전/재생/다음/반복 · 볼륨 · 재생 목록
import Cocoa

/// 클릭/끌어서 위치를 옮길 수 있는 얇은 진행바
final class ProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    private var dragging: Double?

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let f = dragging ?? fraction
        var done = track
        done.size.width = track.width * CGFloat(max(0, min(1, f)))
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: done, xRadius: 2, yRadius: 2).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: done.maxX - 5, y: bounds.midY - 5, width: 10, height: 10)).fill()
    }
    private func value(_ e: NSEvent) -> Double {
        Double(max(0, min(1, convert(e.locationInWindow, from: nil).x / max(1, bounds.width))))
    }
    override func mouseDown(with e: NSEvent) { dragging = value(e); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { dragging = value(e); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        if let d = dragging { fraction = d; onSeek?(d) }
        dragging = nil
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class PlayerBar: NSView {
    static let height: CGFloat = 118
    weak var music: YTMusic?

    private let artView = NSImageView()
    private let titleBtn = NSButton(title: "", target: nil, action: nil)
    private let bylineLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let progress = ProgressBar()
    private var like: ActionButton!, dislike: ActionButton!
    private var shuffle: ActionButton!, prev: ActionButton!, play: ActionButton!, next: ActionButton!, rep: ActionButton!
    private var mute: ActionButton!, queueBtn: ActionButton!, openBtn: ActionButton!, lyricsBtn: ActionButton!
    var onLyrics: (() -> Void)?
    private let volume = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var popover: NSPopover?

    override var isFlipped: Bool { true }

    init(music: YTMusic) {
        self.music = music
        super.init(frame: .zero)

        artView.imageScaling = .scaleProportionallyUpOrDown
        artView.wantsLayer = true
        artView.layer?.cornerRadius = 4
        artView.layer?.masksToBounds = true
        artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        artView.contentTintColor = .secondaryLabelColor
        addSubview(artView)

        titleBtn.isBordered = false
        titleBtn.alignment = .left
        titleBtn.lineBreakMode = .byTruncatingTail
        titleBtn.font = .boldSystemFont(ofSize: 13)
        titleBtn.toolTip = "YouTube Music 창으로 가기"
        titleBtn.target = self
        titleBtn.action = #selector(openWindow)
        addSubview(titleBtn)

        bylineLabel.font = .systemFont(ofSize: 11)
        bylineLabel.textColor = .secondaryLabelColor
        bylineLabel.lineBreakMode = .byTruncatingTail
        addSubview(bylineLabel)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        addSubview(timeLabel)

        progress.onSeek = { [weak self] f in self?.music?.seek(f) }
        addSubview(progress)

        func btn(_ symbol: String, _ tip: String, size: CGFloat = 13, _ key: String) -> ActionButton {
            let b = ActionButton(title: "", symbol: symbol) { [weak self] _ in
                self?.music?.press(key)
                // 셔플은 켜짐 표시가 없어서 눌렀다는 걸 잠깐 알려 줌
                if key == "shuffle" { self?.flash("🔀 다음 곡들을 섞었어요") }
            }
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
            b.toolTip = tip
            addSubview(b)
            return b
        }
        like = btn("hand.thumbsup", "좋아요", size: 12, "like")
        dislike = btn("hand.thumbsdown", "싫어요", size: 12, "dislike")
        shuffle = btn("shuffle", "셔플", "shuffle")
        prev = btn("backward.fill", "이전 곡", "prev")
        play = btn("play.fill", "재생 / 일시정지", size: 18, "playPause")
        next = btn("forward.fill", "다음 곡", "next")
        rep = btn("repeat", "반복", "repeat")
        mute = btn("speaker.wave.2.fill", "음소거", size: 11, "mute")
        queueBtn = ActionButton(title: "", symbol: "list.bullet") { [weak self] b in self?.showQueue(from: b) }
        queueBtn.isBordered = false
        queueBtn.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        queueBtn.toolTip = "재생 목록"
        addSubview(queueBtn)

        lyricsBtn = ActionButton(title: "", symbol: "quote.bubble") { [weak self] _ in self?.onLyrics?() }
        lyricsBtn.isBordered = false
        lyricsBtn.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        lyricsBtn.toolTip = "가사 (번역)"
        addSubview(lyricsBtn)

        // YouTube Music 창(내장 브라우저) 열기
        openBtn = ActionButton(title: "", symbol: "macwindow") { [weak self] _ in self?.music?.showWindow() }
        openBtn.isBordered = false
        openBtn.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        openBtn.toolTip = "YouTube Music 창 열기"
        addSubview(openBtn)

        volume.controlSize = .mini
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.toolTip = "볼륨"
        addSubview(volume)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openWindow() { music?.showWindow() }

    private var flashUntil = Date.distantPast
    private func flash(_ msg: String) {
        flashUntil = Date().addingTimeInterval(2)
        bylineLabel.stringValue = msg
        bylineLabel.textColor = .controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self, Date() >= self.flashUntil else { return }
            self.bylineLabel.textColor = .secondaryLabelColor
            if let st = self.music?.state { self.bylineLabel.stringValue = st.byline }
        }
    }
    @objc private func volumeChanged() { music?.setVolume(volume.doubleValue) }

    func update(_ st: PlayerState, art: NSImage?) {
        titleBtn.title = st.title.isEmpty ? "재생 중인 곡 없음" : st.title
        if Date() >= flashUntil { bylineLabel.stringValue = st.byline }
        timeLabel.stringValue = st.time
        progress.fraction = st.duration > 0 ? st.position / st.duration : 0
        if let art {
            artView.image = art
            artView.contentTintColor = nil
        } else {
            artView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artView.contentTintColor = .secondaryLabelColor
        }
        func sym(_ b: ActionButton, _ name: String, _ tint: NSColor? = nil) {
            b.image = NSImage(systemSymbolName: name, accessibilityDescription: b.toolTip)
            b.contentTintColor = tint
        }
        sym(play, st.playing == true ? "pause.fill" : "play.fill")
        sym(like, st.liked ? "hand.thumbsup.fill" : "hand.thumbsup", st.liked ? .controlAccentColor : nil)
        sym(dislike, st.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", st.disliked ? .controlAccentColor : nil)
        sym(rep, st.repeatOne ? "repeat.1" : "repeat", st.repeatOn ? .controlAccentColor : nil)
        rep.toolTip = st.repeatLabel.isEmpty ? "반복" : st.repeatLabel
        sym(mute, st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        if volume.currentEditor() == nil, NSEvent.pressedMouseButtons == 0 { volume.doubleValue = st.volume }
        limited = st.limited
        has = st.limited ? [] : st.has
        narrowHint = !st.limited && !st.has.contains("progress")
        if narrowHint && st.byline.isEmpty { bylineLabel.stringValue = "YouTube Music 창을 넓히면 더 많은 기능이 보여요" }
        needsLayout = true
    }
    private var limited = false
    private var has: Set<String> = []
    private var narrowHint = false

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        // 1줄: 사진 · 제목/아티스트 · 좋아요/싫어요
        artView.frame = NSRect(x: pad, y: 8, width: 44, height: 44)
        openBtn.frame = NSRect(x: w - pad - 24, y: 16, width: 24, height: 24)
        dislike.frame = NSRect(x: openBtn.frame.minX - 28, y: 16, width: 24, height: 24)
        like.frame = NSRect(x: dislike.frame.minX - 26, y: 16, width: 24, height: 24)
        let textX = artView.frame.maxX + 10
        titleBtn.frame = NSRect(x: textX - 2, y: 9, width: like.frame.minX - textX - 4, height: 20)
        bylineLabel.frame = NSRect(x: textX, y: 30, width: like.frame.minX - textX - 4, height: 16)
        // 2줄: 진행바
        progress.frame = NSRect(x: pad, y: 58, width: w - pad * 2, height: 14)
        // 3줄: 시간 · [셔플 이전 재생 다음 반복] · 볼륨 · 재생 목록
        let rowY: CGFloat = 78
        timeLabel.sizeToFit()
        timeLabel.frame.origin = NSPoint(x: pad, y: rowY + 12)
        let cw: CGFloat = 30
        let center = w / 2
        play.frame = NSRect(x: center - 18, y: rowY + 2, width: 36, height: 32)
        prev.frame = NSRect(x: play.frame.minX - cw, y: rowY + 6, width: cw, height: 24)
        shuffle.frame = NSRect(x: prev.frame.minX - cw, y: rowY + 6, width: cw, height: 24)
        next.frame = NSRect(x: play.frame.maxX, y: rowY + 6, width: cw, height: 24)
        rep.frame = NSRect(x: next.frame.maxX, y: rowY + 6, width: cw, height: 24)
        queueBtn.frame = NSRect(x: w - pad - 24, y: rowY + 6, width: 24, height: 24)
        // 볼륨은 자리가 있을 때만
        let volW: CGFloat = 56
        lyricsBtn.frame = NSRect(x: queueBtn.frame.minX - 26, y: rowY + 6, width: 24, height: 24)
        let volX = lyricsBtn.frame.minX - 4 - volW
        let room = volX - rep.frame.maxX
        volume.isHidden = room < 30
        mute.isHidden = room < 4
        volume.frame = NSRect(x: volX, y: rowY + 10, width: volW, height: 16)
        mute.frame = NSRect(x: (volume.isHidden ? lyricsBtn.frame.minX - 4 : volX) - 22, y: rowY + 6, width: 22, height: 24)
        timeLabel.isHidden = limited || timeLabel.frame.maxX > shuffle.frame.minX - 2
        // YouTube Music 화면에 없는 조작은 숨김 (창이 좁거나 다른 탭 뒤에 있을 때)
        like.isHidden = !has.contains("like")
        dislike.isHidden = !has.contains("dislike")
        shuffle.isHidden = !has.contains("shuffle")
        rep.isHidden = !has.contains("repeat")
        mute.isHidden = mute.isHidden || !has.contains("mute")
        volume.isHidden = volume.isHidden || !has.contains("volume")
        progress.isHidden = !has.contains("progress")
        if progress.isHidden { timeLabel.isHidden = true }
        prev.isHidden = !limited && !has.isEmpty && !has.contains("prev")
        toolTip = narrowHint ? "YouTube Music 창을 넓히면 진행바·좋아요·반복·볼륨도 보여요" : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 3), xRadius: 10, yRadius: 10).fill()
    }

    // MARK: 재생 목록

    private func showQueue(from b: NSView) {
        guard let music else { return }
        if limited {
            let a = NSAlert()
            a.messageText = "재생 목록은 YouTube Music 이 보이고 있을 때만 볼 수 있어요"
            a.informativeText = "지금은 다른 탭 뒤에 있어요. 제목을 눌러 그 탭으로 가거나, YouTube Music 을 따로 창(설치형 앱)으로 열어 두면 항상 볼 수 있어요."
            a.addButton(withTitle: "YouTube Music 으로 가기")
            a.addButton(withTitle: "닫기")
            if a.runModal() == .alertFirstButtonReturn { music.showWindow() }
            return
        }
        let vc = QueueViewController(music: music)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.delegate = vc
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        popover = p
        vc.load()
    }
}

/// 재생 목록 팝업
@MainActor
final class QueueViewController: NSViewController, NSPopoverDelegate {
    private weak var music: YTMusic?
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "재생 목록 불러오는 중…")

    init(music: YTMusic) {
        self.music = music
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let head = NSTextField(labelWithString: "다음 트랙")
        head.font = .boldSystemFont(ofSize: 13)
        head.frame = NSRect(x: 14, y: 92, width: 200, height: 18)
        head.autoresizingMask = [.minYMargin]
        v.addSubview(head)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 14, y: 50, width: 292, height: 18)
        v.addSubview(status)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let doc = FlippedView()
        doc.addSubview(list)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.frame = NSRect(x: 0, y: 6, width: 320, height: 80)
        scroll.autoresizingMask = [.height]
        v.addSubview(scroll)
        view = v
    }

    func load() {
        music?.loadQueue { [weak self] items in self?.show(items) }
    }

    private func show(_ items: [QueueItem]) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        status.isHidden = !items.isEmpty
        status.stringValue = "재생 목록을 찾지 못했어요"
        let rowH: CGFloat = 44
        for item in items {
            let r = QueueRow(item: item) { [weak self] in
                self?.music?.play(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.load() }
            }
            r.frame.size = NSSize(width: 320, height: rowH)
            list.addArrangedSubview(r)
        }
        let listH = CGFloat(items.count) * rowH
        list.frame = NSRect(x: 0, y: 0, width: 320, height: listH)
        scroll.documentView?.frame = NSRect(x: 0, y: 0, width: 320, height: listH)
        let viewH = min(420, max(80, listH)) + 40
        preferredContentSize = NSSize(width: 320, height: viewH)
        view.setFrameSize(preferredContentSize)
        // 지금 곡이 보이게 스크롤
        if let i = items.firstIndex(where: { $0.current }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, CGFloat(i) * rowH - rowH)))
        }
    }

    func popoverDidClose(_ notification: Notification) { music?.queueClosed() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class QueueRow: NSView {
    private let onClick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private let current: Bool

    init(item: QueueItem, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.current = item.current
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 320).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        let icon = NSImageView(frame: NSRect(x: 12, y: 14, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: item.current ? "speaker.wave.2.fill" : "music.note", accessibilityDescription: nil)
        icon.contentTintColor = item.current ? .systemRed : .tertiaryLabelColor
        addSubview(icon)

        let t = NSTextField(labelWithString: item.title)
        t.font = item.current ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: 36, y: 22, width: 230, height: 16)
        addSubview(t)
        let a = NSTextField(labelWithString: item.artist)
        a.font = .systemFont(ofSize: 11)
        a.textColor = .secondaryLabelColor
        a.lineBreakMode = .byTruncatingTail
        a.frame = NSRect(x: 36, y: 6, width: 230, height: 15)
        addSubview(a)
        let d = NSTextField(labelWithString: item.duration)
        d.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        d.textColor = .secondaryLabelColor
        d.alignment = .right
        d.frame = NSRect(x: 266, y: 14, width: 42, height: 15)
        addSubview(d)
        toolTip = item.current ? "지금 재생 중" : "이 곡 재생"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if current {
            NSColor.systemRed.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
