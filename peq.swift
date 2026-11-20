// 정밀 이퀄라이저 창: 주파수 그래프 위의 점을 끌어 필터를 만들고, 뒤에 지금 나오는 소리의 주파수 분포를 실시간으로
// - 더블클릭: 점 추가 · 끌기: 좌우 = 주파수, 위아래 = 세기 · 휠: 폭(Q) · 오른쪽 클릭: 종류 바꾸기 / 빼기
// - '자동 31밴드' 를 켜면 곡마다 들어 보고 1/3 옥타브로 맞춤 (막대로 보여 줌)
import Cocoa
import Accelerate

@MainActor
final class PEQWindow: NSObject, NSWindowDelegate {
    static let shared = PEQWindow()
    private var panel: NSPanel?
    private var graph: PEQGraph?
    weak var music: YTMusic?

    func show(music: YTMusic?) {
        self.music = music
        if panel == nil { build() }
        TapEQ.shared.spectrumOn = true
        graph?.start()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        TapEQ.shared.spectrumOn = false
        graph?.stop()
    }

    private let onBox = NSButton(checkboxWithTitle: "정밀 EQ 켜기", target: nil, action: nil)
    private let autoBox = NSButton(checkboxWithTitle: "곡마다 자동 맞춤 (31칸)", target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")

    private func build() {
        let W: CGFloat = 720, H: CGFloat = 420
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "정밀 이퀄라이저"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: 520, height: 320)
        p.delegate = self
        p.setFrameAutosaveName("PEQWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame PEQWindow") == nil { p.center() }
        p.appearance = NSAppearance(named: .darkAqua)

        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.autoresizingMask = [.width, .height]
        onBox.target = self; onBox.action = #selector(onToggled)
        onBox.state = YTMusic.peqOn ? .on : .off
        onBox.frame = NSRect(x: 14, y: H - 32, width: 120, height: 20)
        onBox.autoresizingMask = [.minYMargin]
        v.addSubview(onBox)
        autoBox.target = self; autoBox.action = #selector(autoToggled)
        autoBox.state = YTMusic.auto31On ? .on : .off
        autoBox.frame = NSRect(x: 140, y: H - 32, width: 190, height: 20)
        autoBox.autoresizingMask = [.minYMargin]
        autoBox.toolTip = "곡이 바뀌면 5초 뒤 8초 동안 듣고 1/3 옥타브(31칸)로 세밀하게 맞춰요"
        v.addSubview(autoBox)
        let now = NSButton(title: "지금 곡 맞추기", target: self, action: #selector(autoNow))
        now.bezelStyle = .rounded; now.controlSize = .small
        now.frame = NSRect(x: 334, y: H - 34, width: 120, height: 24)
        now.autoresizingMask = [.minYMargin]
        v.addSubview(now)
        let reset = NSButton(title: "점 모두 지우기", target: self, action: #selector(clearPoints))
        reset.bezelStyle = .rounded; reset.controlSize = .small
        reset.frame = NSRect(x: W - 14 - 110, y: H - 34, width: 110, height: 24)
        reset.autoresizingMask = [.minXMargin, .minYMargin]
        v.addSubview(reset)

        let g = PEQGraph(frame: NSRect(x: 10, y: 34, width: W - 20, height: H - 76))
        g.autoresizingMask = [.width, .height]
        g.onChange = { [weak self] in self?.pointsChanged() }
        g.onSelect = { [weak self] t in self?.info.stringValue = t }
        v.addSubview(g)
        graph = g

        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 14, y: 10, width: W - 28, height: 16)
        info.autoresizingMask = [.width]
        info.stringValue = "더블클릭: 점 추가 · 끌기: 좌우 주파수 / 위아래 세기 · 휠: 폭 · 오른쪽 클릭: 종류 · 빼기"
        v.addSubview(info)

        p.contentView = v
        panel = p
        NotificationCenter.default.addObserver(forName: .eqChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.graph?.needsDisplay = true; self?.autoBox.state = YTMusic.auto31On ? .on : .off }
        }
    }

    private func pointsChanged() {
        if !YTMusic.peqOn { YTMusic.peqOn = true; onBox.state = .on }
        music?.applyEQ()
    }
    @objc private func onToggled() { YTMusic.peqOn = onBox.state == .on; music?.applyEQ(); graph?.needsDisplay = true }
    @objc private func autoToggled() {
        YTMusic.auto31On = autoBox.state == .on
        if !YTMusic.auto31On { YTMusic.auto31Gains = Array(repeating: 0, count: 31) }
        music?.applyEQ()
        if YTMusic.auto31On { autoNow() }
        graph?.needsDisplay = true
    }
    @objc private func autoNow() {
        info.stringValue = "지금 곡을 듣는 중… (8초)"
        if !YTMusic.auto31On { YTMusic.auto31On = true; autoBox.state = .on }
        music?.runAuto31 { [weak self] ok in
            self?.info.stringValue = ok ? "지금 곡에 맞춰 31칸을 조정했어요 (회색 막대)" : "소리가 충분히 들리지 않았어요 · 재생 중일 때 다시 눌러 주세요"
            self?.graph?.needsDisplay = true
        }
    }
    @objc private func clearPoints() { YTMusic.peqFilters = []; music?.applyEQ(); graph?.needsDisplay = true }
}

/// 그래프: 가로 = 주파수(20Hz ~ 20kHz, 로그), 세로 = 세기(±15dB)
@MainActor
final class PEQGraph: NSView {
    var onChange: (() -> Void)?
    var onSelect: ((String) -> Void)?
    private var timer: Timer?
    private var spectrum: [Double] = []      // 화면 가로 칸마다 dB
    private var selected: Int?
    private var dragging = false
    private let range: Double = 15
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateSpectrum() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }

    // MARK: 좌표

    private var plot: NSRect { bounds.insetBy(dx: 34, dy: 18).offsetBy(dx: 10, dy: 4) }
    private func x(_ f: Double) -> CGFloat { plot.minX + CGFloat(log10(f / 20) / 3) * plot.width }
    private func f(_ x: CGFloat) -> Double { 20 * pow(10, Double((x - plot.minX) / plot.width) * 3) }
    private func y(_ db: Double) -> CGFloat { plot.midY + CGFloat(db / range) * plot.height / 2 }
    private func db(_ y: CGFloat) -> Double { Double((y - plot.midY) / (plot.height / 2)) * range }

    // MARK: 스펙트럼 (필터를 거친 뒤 소리, 4096 점 FFT)

    private var fftSetup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))
    private var smooth: [Double] = []
    private func updateSpectrum() {
        guard TapEQ.shared.running, let setup = fftSetup else {
            if !spectrum.isEmpty { spectrum = []; needsDisplay = true }
            return
        }
        let n = 4096
        var buf = TapEQ.shared.recentSamples(n)
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(buf, 1, win, 1, &buf, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &sp, 1, 12, FFTDirection(FFT_FORWARD))
            }
        }
        let rate = TapEQ.shared.currentSampleRate
        let cols = max(2, Int(plot.width / 3))
        var out = [Double](repeating: -120, count: cols)
        for c in 0..<cols {
            let f0 = f(plot.minX + CGFloat(c) * plot.width / CGFloat(cols)), f1 = f(plot.minX + CGFloat(c + 1) * plot.width / CGFloat(cols))
            let k0 = max(1, Int(f0 / rate * Double(n))), k1 = min(n / 2 - 1, max(k0, Int(f1 / rate * Double(n))))
            var p: Float = 0
            for k in k0...k1 { p = max(p, re[k] * re[k] + im[k] * im[k]) }
            out[c] = 10 * log10(Double(max(p, 1e-14)))
        }
        // 부드럽게 (오를 땐 빨리, 내릴 땐 천천히)
        if smooth.count != cols { smooth = out }
        for i in 0..<cols { smooth[i] = out[i] > smooth[i] ? out[i] : smooth[i] * 0.85 + out[i] * 0.15 }
        spectrum = smooth
        needsDisplay = true
    }

    // MARK: 그리기

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let p = plot
        let grid = NSColor(white: 1, alpha: 0.07), label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor(white: 1, alpha: 0.4)]
        // 세로 눈금 (주파수)
        for fr in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            grid.setFill(); NSRect(x: x(fr), y: p.minY, width: 1, height: p.height).fill()
            let t = fr >= 1000 ? "\(Int(fr / 1000))k" : "\(Int(fr))"
            (t as NSString).draw(at: NSPoint(x: x(fr) - 8, y: p.minY - 15), withAttributes: label)
        }
        // 가로 눈금 (dB)
        for d in stride(from: -12.0, through: 12, by: 6) {
            (d == 0 ? NSColor(white: 1, alpha: 0.18) : grid).setFill()
            NSRect(x: p.minX, y: y(d), width: p.width, height: 1).fill()
            ("\(d > 0 ? "+" : "")\(Int(d))" as NSString).draw(at: NSPoint(x: p.minX - 30, y: y(d) - 6), withAttributes: label)
        }
        // 스펙트럼: 위쪽 -10dBFS ~ 아래 -100dBFS 를 그래프 높이에 맞춰 채움
        if !spectrum.isEmpty {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: p.minX, y: p.minY))
            for (i, v) in spectrum.enumerated() {
                let yy = p.minY + CGFloat(max(0, min(1, (v + 100) / 90))) * p.height
                path.line(to: NSPoint(x: p.minX + CGFloat(i) * p.width / CGFloat(spectrum.count), y: yy))
            }
            path.line(to: NSPoint(x: p.maxX, y: p.minY)); path.close()
            NSColor.systemTeal.withAlphaComponent(0.18).setFill(); path.fill()
            NSColor.systemTeal.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
        }
        // 자동 31밴드 막대
        if YTMusic.auto31On {
            for (i, fr) in TapEQ.thirdOctave.enumerated() {
                let g = YTMusic.auto31Gains[i]
                guard g != 0 else { continue }
                NSColor(white: 1, alpha: 0.22).setFill()
                NSRect(x: x(fr) - 2, y: min(y(0), y(g)), width: 4, height: abs(y(g) - y(0))).fill()
            }
        }
        // 전체 반응 곡선 (10밴드 · 저음량 보정 · 자동 31 · 점들 모두 합친 것)
        let all = TapEQ.shared.allFilters()
        let curve = NSBezierPath()
        var first = true
        var xx = p.minX
        while xx <= p.maxX {
            let pt = NSPoint(x: xx, y: y(max(-range, min(range, TapEQ.response(all, at: f(xx))))))
            if first { curve.move(to: pt); first = false } else { curve.line(to: pt) }
            xx += 2
        }
        NSColor.launcherAccent.setStroke(); curve.lineWidth = 2; curve.stroke()
        // 점들
        let pts = YTMusic.peqFilters
        for (i, flt) in pts.enumerated() {
            let c = NSPoint(x: x(flt.f), y: y(flt.kind == .highPass || flt.kind == .lowPass ? 0 : flt.g))
            let r: CGFloat = i == selected ? 8 : 6.5
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            (YTMusic.peqOn ? NSColor.white : NSColor(white: 1, alpha: 0.4)).setFill(); dot.fill()
            NSColor.launcherAccent.setStroke(); dot.lineWidth = 2; dot.stroke()
            ("\(i + 1)" as NSString).draw(at: NSPoint(x: c.x - 3, y: c.y - 6),
                                         withAttributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.black])
        }
        if !TapEQ.shared.running {
            ("재생하면 소리 그림이 나와요" as NSString).draw(at: NSPoint(x: p.midX - 70, y: p.maxY - 18), withAttributes: label)
        }
    }

    // MARK: 마우스

    private func hit(_ pt: NSPoint) -> Int? {
        let pts = YTMusic.peqFilters
        return pts.indices.min { a, b in
            hypot(x(pts[a].f) - pt.x, y(pts[a].g) - pt.y) < hypot(x(pts[b].f) - pt.x, y(pts[b].g) - pt.y)
        }.flatMap { i in
            let fl = pts[i]
            let yy = fl.kind == .highPass || fl.kind == .lowPass ? y(0) : y(fl.g)
            return hypot(x(fl.f) - pt.x, yy - pt.y) < 12 ? i : nil
        }
    }
    private func describe(_ i: Int) {
        let fl = YTMusic.peqFilters[i]
        let fs = fl.f >= 1000 ? String(format: "%.2fkHz", fl.f / 1000) : String(format: "%.0fHz", fl.f)
        let gs = fl.kind == .highPass || fl.kind == .lowPass ? "" : String(format: " · %+.1fdB", fl.g)
        onSelect?("\(i + 1)번 · \(fl.kind.name) · \(fs)\(gs) · 폭(Q) \(String(format: "%.2f", fl.q))")
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, hit(pt) == nil, plot.contains(pt) {
            var pts = YTMusic.peqFilters
            guard pts.count < TapEQ.maxParam else { onSelect?("점은 \(TapEQ.maxParam)개까지 넣을 수 있어요"); return }
            pts.append(EQFilter(kind: .peak, f: f(pt.x), g: max(-range, min(range, (db(pt.y) * 2).rounded() / 2)), q: 1.4))
            YTMusic.peqFilters = pts
            selected = pts.count - 1
            describe(selected!)
            onChange?(); needsDisplay = true
            return
        }
        selected = hit(pt)
        dragging = selected != nil
        if let s = selected { describe(s) }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragging, let s = selected else { return }
        let pt = convert(e.locationInWindow, from: nil)
        var pts = YTMusic.peqFilters
        pts[s].f = max(20, min(20000, f(max(plot.minX, min(plot.maxX, pt.x)))))
        if pts[s].kind != .highPass && pts[s].kind != .lowPass {
            pts[s].g = max(-range, min(range, (db(pt.y) * 2).rounded() / 2))
        }
        YTMusic.peqFilters = pts
        describe(s)
        onChange?(); needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) { dragging = false }

    override func scrollWheel(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        guard let s = hit(pt) ?? selected else { return }
        var pts = YTMusic.peqFilters
        let step = e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)
        pts[s].q = max(0.2, min(12, pts[s].q * pow(1.15, Double(step))))
        YTMusic.peqFilters = pts
        selected = s
        describe(s)
        onChange?(); needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        guard let s = hit(pt) else { return }
        selected = s; describe(s); needsDisplay = true
        let m = NSMenu()
        for k in EQFilter.Kind.allCases {
            let it = MenuAction(k.name) { [weak self] in
                var pts = YTMusic.peqFilters
                pts[s].kind = k
                if k == .lowShelf || k == .highShelf { pts[s].q = 0.71 }
                if k == .highPass || k == .lowPass { pts[s].q = 0.71 }
                YTMusic.peqFilters = pts
                self?.describe(s); self?.onChange?(); self?.needsDisplay = true
            }
            it.state = YTMusic.peqFilters[s].kind == k ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(MenuAction("이 점 빼기") { [weak self] in
            var pts = YTMusic.peqFilters
            pts.remove(at: s)
            YTMusic.peqFilters = pts
            self?.selected = nil
            self?.onSelect?("점을 뺐어요")
            self?.onChange?(); self?.needsDisplay = true
        })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    // ⌫ 로 고른 점 빼기
    override func keyDown(with e: NSEvent) {
        if let s = selected, e.keyCode == 51 || e.keyCode == 117 {
            var pts = YTMusic.peqFilters
            pts.remove(at: s)
            YTMusic.peqFilters = pts
            selected = nil
            onChange?(); needsDisplay = true
        } else { super.keyDown(with: e) }
    }
}
