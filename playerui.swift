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

/// 위에서 휠을 굴리면 볼륨이 바뀌는 스피커 버튼
final class ScrollButton: ActionButton {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        if d != 0 { onScroll?(d) } else { super.scrollWheel(with: event) }
    }
}

/// 볼륨 팝업: 슬라이더 · % · 음소거
@MainActor
final class VolumeViewController: NSViewController {
    weak var music: YTMusic?
    let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let label = NSTextField(labelWithString: "100%")
    var muteBtn: ActionButton!

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 40))
        muteBtn = ActionButton(title: "", symbol: "speaker.wave.2.fill") { [weak self] _ in
            self?.music?.press("mute")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.sync() }
        }
        muteBtn.isBordered = false
        muteBtn.toolTip = "음소거 / 해제"
        muteBtn.frame = NSRect(x: 8, y: 8, width: 24, height: 24)
        v.addSubview(muteBtn)
        slider.frame = NSRect(x: 36, y: 10, width: 140, height: 20)
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        v.addSubview(slider)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.frame = NSRect(x: 178, y: 12, width: 42, height: 16)
        v.addSubview(label)
        view = v
        sync()
    }

    @objc private func changed() {
        label.stringValue = "\(Int(slider.doubleValue))%"
        music?.setVolume(slider.doubleValue)
    }

    func sync() {
        guard let st = music?.state else { return }
        if NSEvent.pressedMouseButtons == 0 { slider.doubleValue = st.muted ? 0 : st.volume }
        label.stringValue = st.muted ? "음소거" : "\(Int(st.volume))%"
        muteBtn?.image = NSImage(systemSymbolName: st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
    }
}

@MainActor
final class PlayerBar: NSView {
    /// 도구함 글자 크기 배율 (설정에서 바꿈)
    static var fontScale: CGFloat = 1
    /// 글자가 커지면 곡 정보 줄이 높아지는 만큼 플레이어도 높아짐
    static var extra: CGFloat { max(0, (fontScale - 1) * 36) }
    static var height: CGFloat { compact ? 52 + extra * 0.5 + (narrow ? 30 : 0) : 118 + extra }
    /// 좁은 도구함 창: 한 줄 플레이어를 두 줄로 (위: 사진 · 제목 · 떼어 내기 / 아래: 재생 단추들)
    static var narrow = false
    /// 한 줄 플레이어 (옵션, 처음엔 켬): [사진 · 제목/아티스트 · ⏮ ▶ ⏭ · 가사 · 목록 · 떼어 내기] + 얇은 재생바
    static var compact: Bool {
        get { UserDefaults.standard.object(forKey: "playerCompact") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "playerCompact") }
    }
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
    /// 떼어 낸 상태에서 ☰ : 크게 보기(앨범 · 다음 트랙) 켜고 끄기
    var onBig: (() -> Void)?
    var big = false { didSet { updateDetachIcon() } }
    /// ⧉ 떼어 내기 / 합치기
    var onDetach: (() -> Void)?
    var detached = false { didSet { updateDetachIcon() } }
    private var detachBtn: ActionButton!
    private func updateDetachIcon() {
        detachBtn?.image = NSImage(systemSymbolName: detached ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", accessibilityDescription: nil)
        detachBtn?.toolTip = detached ? "도구함 창으로 합치기" : "플레이어만 따로 떼어 내기"
        queueBtn?.toolTip = detached ? (big ? "크게 보기 끄기" : "크게 보기 (큰 앨범 · 다음 트랙 · 가사)") : "재생 목록"
        queueBtn?.contentTintColor = detached && big ? .launcherAccent : nil
    }
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
        // 스피커: 누르면 볼륨 팝업, 위에서 휠을 굴리면 볼륨 조절
        let sp = ScrollButton(title: "", symbol: "speaker.wave.2.fill") { [weak self] b in self?.showVolume(from: b) }
        sp.isBordered = false
        sp.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        sp.toolTip = "볼륨 (누르면 조절 · 휠로 바로 조절)"
        sp.onScroll = { [weak self] d in self?.nudgeVolume(d) }
        addSubview(sp)
        mute = sp
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

        detachBtn = ActionButton(title: "", symbol: "rectangle.on.rectangle") { [weak self] _ in self?.onDetach?() }
        detachBtn.isBordered = false
        detachBtn.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        detachBtn.contentTintColor = .secondaryLabelColor
        addSubview(detachBtn)
        updateDetachIcon()

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
        bylineLabel.textColor = .launcherAccent
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self, Date() >= self.flashUntil else { return }
            self.bylineLabel.textColor = .secondaryLabelColor
            if let st = self.music?.state { self.bylineLabel.stringValue = st.byline }
        }
    }
    @objc private func volumeChanged() { music?.setVolume(volume.doubleValue) }

    private var volumePopover: NSPopover?
    private var volumeVC: VolumeViewController?

    func showVolume(from b: NSView) {
        if volumePopover?.isShown == true { volumePopover?.close(); return }
        let vc = VolumeViewController()
        vc.music = music
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        volumePopover = p
        volumeVC = vc
    }

    /// 휠 한 칸에 볼륨 조금씩
    func nudgeVolume(_ delta: CGFloat) {
        guard let st = music?.state else { return }
        let step = delta > 0 ? 4.0 : -4.0
        let v = max(0, min(100, (st.muted ? 0 : st.volume) + step))
        music?.setVolume(v)
        volume.doubleValue = v
        mute.toolTip = "볼륨 \(Int(v))% (누르면 조절 · 휠로 바로 조절)"
    }

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
        sym(like, st.liked ? "hand.thumbsup.fill" : "hand.thumbsup", st.liked ? .launcherAccent : nil)
        sym(dislike, st.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", st.disliked ? .launcherAccent : nil)
        sym(rep, st.repeatOne ? "repeat.1" : "repeat", st.repeatOn ? .launcherAccent : nil)
        rep.toolTip = st.repeatLabel.isEmpty ? "반복" : st.repeatLabel
        sym(mute, st.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        if volume.currentEditor() == nil, NSEvent.pressedMouseButtons == 0 { volume.doubleValue = st.volume }
        if volumePopover?.isShown == true { volumeVC?.sync() }
        limited = st.limited
        has = st.limited ? [] : st.has
        narrowHint = !st.limited && !st.has.contains("progress")
        if narrowHint && st.byline.isEmpty { bylineLabel.stringValue = "YouTube Music 창을 넓히면 더 많은 기능이 보여요" }
        needsLayout = true
    }
    /// 한 줄 플레이어 배치
    private func layoutCompact() {
        let w = bounds.width
        let pad: CGFloat = 10
        let fs = PlayerBar.fontScale
        let ex = PlayerBar.extra * 0.5
        let rowH: CGFloat = 32 + ex
        artView.frame = NSRect(x: pad, y: 6, width: rowH, height: rowH)
        if PlayerBar.narrow { layoutNarrow(w: w, pad: pad, fs: fs, rowH: rowH); return }
        // 오른쪽부터: [떼어 내기] [목록] [가사] [🔈 볼륨] [🔁 반복] · [⏭] [▶] [⏮]
        let y0 = 6 + (rowH - 24) / 2
        detachBtn.frame = NSRect(x: w - pad - 22, y: y0 + 1, width: 22, height: 22)
        queueBtn.frame = NSRect(x: detachBtn.frame.minX - 24, y: y0, width: 24, height: 24)
        lyricsBtn.frame = NSRect(x: queueBtn.frame.minX - 24, y: y0, width: 24, height: 24)
        // 스피커: 누르면 볼륨 팝업, 위에서 휠을 굴리면 바로 조절
        mute.frame = NSRect(x: lyricsBtn.frame.minX - 24, y: y0, width: 24, height: 24)
        rep.frame = NSRect(x: mute.frame.minX - 24, y: y0, width: 24, height: 24)
        next.frame = NSRect(x: rep.frame.minX - 30, y: y0, width: 28, height: 24)
        play.frame = NSRect(x: next.frame.minX - 32, y: y0 - 4, width: 32, height: 32)
        prev.frame = NSRect(x: play.frame.minX - 28, y: y0, width: 28, height: 24)
        let textX = artView.frame.maxX + 8
        let textW = max(40, prev.frame.minX - textX - 6)
        titleBtn.font = .boldSystemFont(ofSize: 12 * fs)
        bylineLabel.font = .systemFont(ofSize: 10.5 * fs)
        let th = ceil(17 * fs), bh = ceil(14 * fs)
        let ty = 6 + (rowH - th - bh) / 2
        titleBtn.frame = NSRect(x: textX - 2, y: ty, width: textW, height: th)
        bylineLabel.frame = NSRect(x: textX, y: ty + th, width: textW, height: bh)
        // 얇은 재생바 (아래 한 줄)
        progress.frame = NSRect(x: pad, y: 6 + rowH + 2, width: w - pad * 2, height: 10)
        // 한 줄에서는 숨김: 좋아요 · 싫어요 · 셔플 · 볼륨 막대 · 시간 · YouTube Music 창 열기 (볼륨은 스피커 버튼으로)
        for v in [like, dislike, shuffle, openBtn] as [NSView?] { v?.isHidden = true }
        rep.isHidden = limited || (!has.isEmpty && !has.contains("repeat"))
        mute.isHidden = limited
        volume.isHidden = true
        timeLabel.isHidden = true
        progress.isHidden = !has.isEmpty && !has.contains("progress")
        prev.isHidden = !limited && !has.isEmpty && !has.contains("prev")
        toolTip = nil
    }

    /// 좁은 창용 두 줄 배치
    private func layoutNarrow(w: CGFloat, pad: CGFloat, fs: CGFloat, rowH: CGFloat) {
        // 1줄: 사진 · 제목/아티스트 · 떼어 내기
        detachBtn.frame = NSRect(x: w - pad - 22, y: 6 + (rowH - 22) / 2, width: 22, height: 22)
        let textX = artView.frame.maxX + 8
        let textW = max(40, detachBtn.frame.minX - textX - 6)
        titleBtn.font = .boldSystemFont(ofSize: 12 * fs)
        bylineLabel.font = .systemFont(ofSize: 10.5 * fs)
        let th = ceil(17 * fs), bh = ceil(14 * fs)
        let ty = 6 + (rowH - th - bh) / 2
        titleBtn.frame = NSRect(x: textX - 2, y: ty, width: textW, height: th)
        bylineLabel.frame = NSRect(x: textX, y: ty + th, width: textW, height: bh)
        // 2줄: [⏮ ▶ ⏭] ……… [🔁 🔈 가사 목록]
        let y2 = 6 + rowH + 2
        prev.frame = NSRect(x: pad - 2, y: y2, width: 28, height: 24)
        play.frame = NSRect(x: prev.frame.maxX, y: y2 - 4, width: 32, height: 32)
        next.frame = NSRect(x: play.frame.maxX, y: y2, width: 28, height: 24)
        queueBtn.frame = NSRect(x: w - pad - 24, y: y2, width: 24, height: 24)
        lyricsBtn.frame = NSRect(x: queueBtn.frame.minX - 24, y: y2, width: 24, height: 24)
        mute.frame = NSRect(x: lyricsBtn.frame.minX - 24, y: y2, width: 24, height: 24)
        rep.frame = NSRect(x: mute.frame.minX - 24, y: y2, width: 24, height: 24)
        progress.frame = NSRect(x: pad, y: y2 + 26, width: w - pad * 2, height: 10)
        for v in [like, dislike, shuffle, openBtn] as [NSView?] { v?.isHidden = true }
        rep.isHidden = limited || (!has.isEmpty && !has.contains("repeat"))
        mute.isHidden = limited
        volume.isHidden = true
        timeLabel.isHidden = true
        progress.isHidden = !has.isEmpty && !has.contains("progress")
        prev.isHidden = !limited && !has.isEmpty && !has.contains("prev")
        toolTip = nil
    }

    private var limited = false
    private var has: Set<String> = []
    private var narrowHint = false

    override func layout() {
        super.layout()
        layoutMain()
        // 크게 보기: 재생 버튼은 아래(앨범 밑)로 옮겨 가서 여기선 숨기고, 제목을 그만큼 길게
        let moved: [NSView] = [prev, play, next, rep, mute, progress, timeLabel]
        if detached && big {
            moved.forEach { $0.isHidden = true }
            let right = lyricsBtn.frame.minX - 8
            for v in [titleBtn, bylineLabel] as [NSView] where v.frame.maxX < right {
                v.frame.size.width = right - v.frame.minX
            }
            // 글자 크기를 아래 다음 트랙 목록과 같게 (제목 13 · 아티스트 11.5)
            titleBtn.font = .boldSystemFont(ofSize: QueueRow.titleSize)
            bylineLabel.font = .systemFont(ofSize: QueueRow.subSize)
            let th: CGFloat = 18, bh: CGFloat = 16
            let mid = artView.frame.midY
            titleBtn.frame = NSRect(x: titleBtn.frame.minX, y: mid - (th + bh) / 2, width: titleBtn.frame.width, height: th)
            bylineLabel.frame = NSRect(x: bylineLabel.frame.minX, y: titleBtn.frame.maxY, width: bylineLabel.frame.width, height: bh)
        } else if bigHid {
            moved.forEach { $0.isHidden = false }
            needsLayout = true   // 원래 숨김 규칙대로 한 번 더
        }
        bigHid = detached && big
    }
    private var bigHid = false
    private func layoutMain() {
        if PlayerBar.compact { layoutCompact(); return }
        let w = bounds.width
        let pad: CGFloat = 12
        // 1줄: 사진 · 제목/아티스트 · 좋아요/싫어요
        artView.frame = NSRect(x: pad, y: 8, width: 44, height: 44)
        detachBtn.frame = NSRect(x: w - pad - 22, y: 17, width: 22, height: 22)
        openBtn.frame = NSRect(x: detachBtn.frame.minX - 26, y: 16, width: 24, height: 24)
        dislike.frame = NSRect(x: openBtn.frame.minX - 28, y: 16, width: 24, height: 24)
        like.frame = NSRect(x: dislike.frame.minX - 26, y: 16, width: 24, height: 24)
        let textX = artView.frame.maxX + 10
        let fs = PlayerBar.fontScale
        titleBtn.font = .boldSystemFont(ofSize: 13 * fs)
        bylineLabel.font = .systemFont(ofSize: 11 * fs)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10 * fs, weight: .regular)
        titleBtn.frame = NSRect(x: textX - 2, y: 9, width: like.frame.minX - textX - 4, height: ceil(20 * fs))
        bylineLabel.frame = NSRect(x: textX, y: titleBtn.frame.maxY + 1, width: like.frame.minX - textX - 4, height: ceil(16 * fs))
        let ex = PlayerBar.extra
        // 2줄: 진행바
        progress.frame = NSRect(x: pad, y: 58 + ex, width: w - pad * 2, height: 14)
        // 3줄: 시간 · [셔플 이전 재생 다음 반복] · 볼륨 · 재생 목록
        let rowY: CGFloat = 78 + ex
        timeLabel.sizeToFit()
        timeLabel.frame.origin = NSPoint(x: pad, y: rowY + 12)
        let cw: CGFloat = 30
        // 오른쪽 묶음은 늘 보이게: [🔈 스피커] [💬 가사] [☰ 재생 목록]
        queueBtn.frame = NSRect(x: w - pad - 24, y: rowY + 6, width: 24, height: 24)
        lyricsBtn.frame = NSRect(x: queueBtn.frame.minX - 26, y: rowY + 6, width: 24, height: 24)
        mute.frame = NSRect(x: lyricsBtn.frame.minX - 26, y: rowY + 6, width: 24, height: 24)
        // 가운데 묶음 [셔플 이전 재생 다음 반복]: 창 가운데, 오른쪽 묶음과 겹치면 왼쪽으로 비킴
        let clusterW = cw * 4 + 36
        var center = w / 2
        if center + clusterW / 2 > mute.frame.minX - 6 { center = mute.frame.minX - 6 - clusterW / 2 }
        play.frame = NSRect(x: center - 18, y: rowY + 2, width: 36, height: 32)
        prev.frame = NSRect(x: play.frame.minX - cw, y: rowY + 6, width: cw, height: 24)
        shuffle.frame = NSRect(x: prev.frame.minX - cw, y: rowY + 6, width: cw, height: 24)
        next.frame = NSRect(x: play.frame.maxX, y: rowY + 6, width: cw, height: 24)
        rep.frame = NSRect(x: next.frame.maxX, y: rowY + 6, width: cw, height: 24)
        // 볼륨 슬라이더는 반복 버튼과 스피커 사이에 자리가 있을 때만 (없으면 스피커를 눌러 팝업으로)
        let volW: CGFloat = 56
        volume.frame = NSRect(x: mute.frame.minX - 2 - volW, y: rowY + 10, width: volW, height: 16)
        volume.isHidden = volume.frame.minX < rep.frame.maxX + 6
        mute.isHidden = false
        openBtn.isHidden = false   // 한 줄 플레이어에서 돌아왔을 때 다시 보이게
        timeLabel.isHidden = limited || timeLabel.frame.maxX > shuffle.frame.minX - 2
        // YouTube Music 화면에 없는 조작은 숨김 (창이 좁거나 다른 탭 뒤에 있을 때)
        like.isHidden = !has.contains("like")
        dislike.isHidden = !has.contains("dislike")
        shuffle.isHidden = !has.contains("shuffle")
        rep.isHidden = !has.contains("repeat")
        mute.isHidden = limited
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
        if detached, let onBig { onBig(); return }
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
            let r = QueueRow(item: item, fixed: true) { [weak self] in
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
    static let rowH: CGFloat = 44
    /// 글자 크기 (크게 보기 위 플레이어 줄도 같은 크기로 맞춤)
    static let titleSize: CGFloat = 13, subSize: CGFloat = 11.5
    private let onClick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private let current: Bool
    var isCurrent: Bool { current }
    private let icon = NSImageView()
    /// 곡 번호 (앨범 · 재생목록에서 몇 번째인지), 0 이면 음표
    private let numLabel = NSTextField(labelWithString: "")
    var number = 0 { didSet { syncIcon() } }
    /// 고르기 모드: nil = 보통, true/false = 체크 표시
    var check: Bool? { didSet { syncIcon() } }
    private func syncIcon() {
        if let c = check {
            icon.isHidden = false; numLabel.isHidden = true
            icon.image = NSImage(systemSymbolName: c ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
            icon.contentTintColor = c ? .launcherAccent : .tertiaryLabelColor
        } else if current {
            icon.isHidden = false; numLabel.isHidden = true
            icon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemRed
        } else if number > 0 {
            icon.isHidden = true; numLabel.isHidden = false
            numLabel.stringValue = "\(number)"
        } else {
            icon.isHidden = false; numLabel.isHidden = true
            icon.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            icon.contentTintColor = .tertiaryLabelColor
        }
    }
    private let t: NSTextField, a: NSTextField, d: NSTextField
    /// 오른쪽 클릭 · ⋯ 버튼 메뉴 (크게 보기에서만)
    var makeMenu: (() -> NSMenu)? { didSet { more.isHidden = true; needsLayout = true } }
    private lazy var more: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "더 보기")!, target: self, action: #selector(showMore))
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "이 곡의 앨범 재생 …"
        b.isHidden = true
        addSubview(b)
        return b
    }()
    @objc private func showMore() {
        guard let m = makeMenu?() else { return }
        m.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.minY), in: self)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let m = makeMenu?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    /// width: 팝업에선 고정 폭(320, 줄 세우기용 제약), 크게 보기에선 relayout() 으로 폭에 맞춤
    init(item: QueueItem, width: CGFloat = 320, fixed: Bool = false, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.current = item.current
        t = NSTextField(labelWithString: item.title)
        a = NSTextField(labelWithString: item.artist)
        d = NSTextField(labelWithString: item.duration)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowH))
        if fixed {
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: width).isActive = true
            heightAnchor.constraint(equalToConstant: Self.rowH).isActive = true
        }
        addSubview(icon)
        numLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numLabel.textColor = .tertiaryLabelColor
        numLabel.alignment = .center
        addSubview(numLabel)
        t.font = item.current ? .boldSystemFont(ofSize: Self.titleSize) : .systemFont(ofSize: Self.titleSize)
        t.lineBreakMode = .byTruncatingTail
        addSubview(t)
        a.font = .systemFont(ofSize: Self.subSize)
        a.textColor = .secondaryLabelColor
        a.lineBreakMode = .byTruncatingTail
        addSubview(a)
        d.font = .monospacedDigitSystemFont(ofSize: Self.subSize, weight: .regular)
        d.textColor = .secondaryLabelColor
        d.alignment = .right
        addSubview(d)
        toolTip = item.current ? "지금 재생 중" : "이 곡 재생"
        syncIcon()
        relayout()
    }
    /// 폭에 맞춰 글자 칸 배치 (아래가 0 인 좌표)
    func relayout() {
        let w = bounds.width
        icon.frame = NSRect(x: 12, y: 14, width: 16, height: 16)
        numLabel.frame = NSRect(x: 4, y: 14, width: 30, height: 15)
        d.frame = NSRect(x: w - 54, y: 14, width: 42, height: 15)
        if makeMenu != nil { more.frame = NSRect(x: w - 30, y: 12, width: 20, height: 20) }
        let tw = max(40, d.frame.minX - 36 - 6)
        t.frame = NSRect(x: 36, y: 22, width: tw, height: 18)
        a.frame = NSRect(x: 36, y: 5, width: tw, height: 16)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    // 마우스를 올리면 재생 시간 자리에 ⋯ 버튼
    override func mouseEntered(with event: NSEvent) { hovering = true; if makeMenu != nil { more.isHidden = false; d.isHidden = true } }
    override func mouseExited(with event: NSEvent) { hovering = false; if makeMenu != nil { more.isHidden = true; d.isHidden = false } }
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
