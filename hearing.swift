// 청력 보호: 지금 귀에 들어가는 소리 크기(dB)를 어림해서 안전 · 주의 · 위험으로 보여 주고, 오늘 들은 양을 셈
// - 소리 크기 = 이어폰 최대 크기(약 100dB) + 나간 소리 세기(dBFS) + 맥 볼륨(dB)  → 이어폰마다 달라서 '어림값'
// - 하루 허용량: 85dB 로 8시간, 3dB 커질 때마다 절반 (미국 NIOSH 기준 — WHO 권고와 비슷)
import Cocoa
import CoreAudio

@MainActor
final class HearingMeter {
    static let shared = HearingMeter()

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "hearingOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hearingOn") }
    }

    /// 최대 크기 제한 (켜면 이 dB 를 넘지 않게 플레이어 소리를 줄임)
    static var limitOn: Bool {
        get { UserDefaults.standard.bool(forKey: "hearingLimitOn") }
        set { UserDefaults.standard.set(newValue, forKey: "hearingLimitOn"); if !newValue { TapEQ.shared.limitDB = 0; shared.cut = 0 } }
    }
    static var limitMax: Double {
        get { UserDefaults.standard.object(forKey: "hearingLimitMax") as? Double ?? 75 }
        set { UserDefaults.standard.set(newValue, forKey: "hearingLimitMax") }
    }
    /// 지금 줄이고 있는 양 (dB, 0 이하)
    private(set) var cut: Double = 0
    /// 제한 걸기 전 크기의 긴 평균 (에너지)
    private var longE: Double = 0

    /// 지금 크기 (최근 5초 평균, dB). 재생 중이 아니거나 잴 수 없으면 nil
    private(set) var level: Double?
    /// 이어폰 · 헤드폰이면 true, 스피커면 false (스피커는 거리 따라 달라 참고만)
    private(set) var headphones = true
    private(set) var deviceName = ""
    /// 오늘 들은 양 (1 = 하루 허용량 100%)
    private(set) var dose: Double = 0
    private var recent: [Double] = []      // 최근 5초 에너지
    private var loudSince: Date?
    private var lastWarn = Date.distantPast
    private var timer: Timer?
    /// 크게 들을 때 경고 (도구함이 안내 풍선으로 보여 줌)
    var onWarn: ((String) -> Void)?

    private init() {
        let d = UserDefaults.standard
        if d.string(forKey: "hearingDate") == Self.today { dose = d.double(forKey: "hearingDose") }
    }
    private static var today: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard Self.on, TapEQ.shared.running, let rms = TapEQ.shared.takeRMS(), rms > 1e-5 else {
            level = nil; recent = []; loudSince = nil; return
        }
        readDevice()
        // 최대 크기: 이어폰 · 헤드폰 약 100dB, 스피커는 책상 거리에서 약 85dB
        let maxSPL: Double = headphones ? 100 : 85
        let spl = maxSPL + 20 * log10(rms * sqrt(2)) + TapEQ.outputVolumeDB() + calibration
        // 크기 제한: 1초마다 크기에 맞춰 올렸다 내렸다 하면 노래 강약에 따라 볼륨이 출렁여서(펌핑),
        //   '곡 전체의 평균 크기'(약 15초 평균, 제한 걸기 전 크기)로 정하고 아주 천천히 움직임
        //   — 귀 건강은 순간보다 평균 크기가 중요해서, 잠깐 큰 부분은 그대로 두고 곡이 통째로 크면 줄임
        if Self.limitOn {
            let pre = spl - cut                         // 제한 걸기 전 크기
            let e = pow(10, pre / 10)
            longE = longE == 0 ? e : longE * (1 - 1.0 / 15) + e / 15
            let want = min(0, Self.limitMax - 10 * log10(longE))
            // 줄이기: 1초에 0.5dB (한도보다 6dB 넘게 크면 2dB) · 풀기: 1초에 0.3dB
            let step = want < cut ? -(cut - want > 6 ? 2.0 : 0.5) : 0.3
            cut = step < 0 ? max(want, cut + step) : min(want, cut + step)
            TapEQ.shared.limitDB = cut
        } else { longE = 0 }
        recent.append(pow(10, spl / 10))
        if recent.count > 5 { recent.removeFirst() }
        let l = 10 * log10(recent.reduce(0, +) / Double(recent.count))
        level = l
        // 하루 허용량 (75dB 아래는 셈하지 않음, 스피커는 귀에서 떨어져 있어 셈하지 않음)
        if headphones && l >= 75 {
            let allowed = 8 * 3600 / pow(2, (l - 85) / 3)
            let d = UserDefaults.standard
            if d.string(forKey: "hearingDate") != Self.today { dose = 0; d.set(Self.today, forKey: "hearingDate") }
            dose += 1 / allowed
            d.set(dose, forKey: "hearingDose")
        }
        // 크게 10초 넘게 들으면 한 번 알림 (5분에 한 번까지)
        if headphones && l >= 92 {
            if loudSince == nil { loudSince = Date() }
            if Date().timeIntervalSince(loudSince!) > 10, Date().timeIntervalSince(lastWarn) > 300 {
                lastWarn = Date()
                let mins = Int(8 * 60 / pow(2, (l - 85) / 3))
                onWarn?("🎧 약 \(Int(l))dB — 이 크기는 하루 \(mins)분까지만 괜찮아요. 볼륨을 조금 줄여 주세요")
            }
        } else { loudSince = nil }
    }

    private var lastDevice = AudioObjectID(0)
    private func readDevice() {
        guard let dev: AudioObjectID = TapEQ.prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              dev != lastDevice else { return }
        lastDevice = dev
        let transport: UInt32 = TapEQ.prop(dev, kAudioDevicePropertyTransportType) ?? 0
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &name)
        deviceName = (name?.takeRetainedValue() as String?) ?? ""
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            headphones = true
        case kAudioDeviceTransportTypeBuiltIn:
            // 내장: 이어폰 단자에 꽂았으면 헤드폰, 아니면 스피커
            var ds = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var src: UInt32 = 0, s2 = UInt32(4)
            AudioObjectGetPropertyData(dev, &ds, 0, nil, &s2, &src)
            headphones = src == 0x6864706E   // 'hdpn'
        default:
            headphones = false   // 모니터 · HDMI · 그 밖의 스피커
        }
    }

    // MARK: 맥 표시와 맞추기 (기기마다 보정값 기억)
    // 맥 제어 센터 → 사운드 → 헤드폰 음량(애플 · 비츠 이어폰이면 보임) 숫자를 넣으면 그 차이만큼 이 기기 값을 고쳐 둠

    private var calKey: String { "hearingCal." + deviceName }
    var calibration: Double {
        get { UserDefaults.standard.double(forKey: calKey) }
        set { UserDefaults.standard.set(newValue, forKey: calKey) }
    }
    /// 맥이 보여 주는 값을 넣으면 지금 값과의 차이를 저장
    func calibrate(toMac mac: Double) {
        guard let l = level else { return }
        calibration += mac - l
        recent = recent.map { $0 * pow(10, (mac - l) / 10) }
        level = mac
    }
    func resetCalibration() { calibration = 0; recent = [] }

    // MARK: 표시용

    enum Zone { case safe, ok, caution, danger
        var color: NSColor { [.systemGreen, .systemYellow, .systemOrange, .systemRed][[Zone.safe, .ok, .caution, .danger].firstIndex(of: self)!] }
        var name: String { ["안전", "괜찮음", "주의", "위험"][[Zone.safe, .ok, .caution, .danger].firstIndex(of: self)!] }
    }
    static func zone(_ l: Double) -> Zone { l < 80 ? .safe : (l < 85 ? .ok : (l < 92 ? .caution : .danger)) }

    /// 이 크기로 하루 들어도 되는 시간 (글)
    static func allowedText(_ l: Double) -> String {
        if l < 80 { return "오래 들어도 괜찮아요" }
        let m = 8 * 60 / pow(2, (l - 85) / 3)
        return m >= 120 ? "하루 \(Int(m / 60))시간까지 괜찮아요" : "하루 \(Int(m))분까지만 괜찮아요"
    }
}

/// 앨범 사진 왼쪽 위의 작은 알약: "🎧 72dB" (색으로 안전 · 주의 · 위험). 누르면 자세히
@MainActor
final class HearingBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var popover: NSPopover?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        toolTip = "지금 귀에 들어가는 소리 크기 (어림값) · 누르면 자세히"
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let m = HearingMeter.shared
        guard HearingMeter.on, let l = m.level else { isHidden = true; return }
        isHidden = false
        let z = HearingMeter.zone(l)
        label.stringValue = (m.headphones ? "🎧 " : "🔈 ") + "\(Int(l.rounded()))dB" + (HearingMeter.limitOn ? " 🔒" : "")
        layer?.backgroundColor = (m.headphones ? z.color : NSColor.gray).withAlphaComponent(0.85).cgColor
        label.textColor = z == .ok && m.headphones ? .black : .white
        if popover?.isShown == true, let vc = popover?.contentViewController as? HearingInfoVC { vc.sync() }
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 15) / 2, width: bounds.width, height: 15)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if popover?.isShown == true { popover?.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = HearingInfoVC()
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = p
    }
}

/// 자세히: 지금 크기 · 하루 괜찮은 시간 · 오늘 들은 양 · 기준표
@MainActor
final class HearingInfoVC: NSViewController {
    private let now = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let doseText = NSTextField(labelWithString: "")
    private let onBox = NSButton(checkboxWithTitle: "소리 크기 표시 (청력 보호)", target: nil, action: nil)

    override func loadView() {
        let W: CGFloat = 300, H: CGFloat = 350
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        now.font = .systemFont(ofSize: 22, weight: .bold)
        now.frame = NSRect(x: 14, y: H - 42, width: W - 28, height: 28)
        v.addSubview(now)
        sub.font = .systemFont(ofSize: 12); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 14, y: H - 62, width: W - 28, height: 16)
        v.addSubview(sub)
        // 최대 크기 제한
        limitBox.target = self; limitBox.action = #selector(limitToggled)
        limitBox.state = HearingMeter.limitOn ? .on : .off
        limitBox.frame = NSRect(x: 14, y: H - 92, width: 120, height: 18)
        v.addSubview(limitBox)
        limitSlider.minValue = 55; limitSlider.maxValue = 90
        limitSlider.doubleValue = HearingMeter.limitMax
        limitSlider.controlSize = .small
        limitSlider.target = self; limitSlider.action = #selector(limitChanged)
        limitSlider.frame = NSRect(x: 134, y: H - 92, width: 110, height: 18)
        v.addSubview(limitSlider)
        limitValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        limitValue.frame = NSRect(x: 248, y: H - 91, width: 44, height: 15)
        v.addSubview(limitValue)
        limitInfo.font = .systemFont(ofSize: 10.5); limitInfo.textColor = .secondaryLabelColor
        limitInfo.frame = NSRect(x: 32, y: H - 110, width: W - 46, height: 15)
        v.addSubview(limitInfo)
        let t = NSTextField(labelWithString: "오늘 들은 양 (하루 허용량 기준)")
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.frame = NSRect(x: 14, y: H - 136, width: W - 28, height: 15)
        v.addSubview(t)
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100; bar.style = .bar
        bar.frame = NSRect(x: 14, y: H - 156, width: W - 28, height: 14)
        v.addSubview(bar)
        doseText.font = .systemFont(ofSize: 11); doseText.textColor = .secondaryLabelColor
        doseText.frame = NSRect(x: 14, y: H - 174, width: W - 28, height: 15)
        v.addSubview(doseText)
        let table = NSTextField(wrappingLabelWithString: """
        🟢 80dB 아래: 안전 — 오래 들어도 괜찮아요
        🟡 80 ~ 85dB: 괜찮음 — 쉬어 가며 듣기
        🟠 85 ~ 92dB: 주의 — 하루 1 ~ 8시간까지
        🔴 92dB 넘음: 위험 — 하루 1시간 안쪽
        """)
        table.font = .systemFont(ofSize: 11)
        table.frame = NSRect(x: 14, y: 86, width: W - 28, height: 66)
        v.addSubview(table)
        let note = NSTextField(wrappingLabelWithString: "귀가 느끼는 크기(A 가중)로 어림한 값이에요. 맥 제어 센터 → 사운드의 '헤드폰 음량'과 다르면 아래에 그 숫자를 넣어 맞춰 주세요.")
        note.font = .systemFont(ofSize: 10); note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 14, y: 54, width: W - 28, height: 28)
        v.addSubview(note)
        calField.placeholderString = "맥 숫자"
        calField.controlSize = .small
        calField.frame = NSRect(x: 14, y: 28, width: 70, height: 20)
        v.addSubview(calField)
        let cb = NSButton(title: "맥 표시와 맞추기", target: self, action: #selector(calibrate))
        cb.controlSize = .small; cb.bezelStyle = .rounded
        cb.frame = NSRect(x: 88, y: 26, width: 120, height: 24)
        v.addSubview(cb)
        let rb = NSButton(title: "되돌리기", target: self, action: #selector(resetCal))
        rb.controlSize = .small; rb.bezelStyle = .rounded
        rb.frame = NSRect(x: 210, y: 26, width: 76, height: 24)
        v.addSubview(rb)
        onBox.target = self; onBox.action = #selector(toggled)
        onBox.state = HearingMeter.on ? .on : .off
        onBox.controlSize = .small
        onBox.frame = NSRect(x: 14, y: 6, width: W - 28, height: 18)
        v.addSubview(onBox)
        view = v
        preferredContentSize = v.frame.size
        sync()
    }
    func sync() {
        let m = HearingMeter.shared
        if let l = m.level {
            let z = HearingMeter.zone(l)
            now.stringValue = "약 \(Int(l.rounded()))dB · \(m.headphones ? z.name : "스피커")"
            now.textColor = m.headphones ? z.color : .labelColor
            let cal = m.calibration == 0 ? "" : String(format: " · 맞춤 %+.0f", m.calibration)
            sub.stringValue = m.headphones ? "\(m.deviceName)\(cal) · \(HearingMeter.allowedText(l))" : "\(m.deviceName) · 스피커는 거리에 따라 달라 참고만 해요"
        } else {
            now.stringValue = "재생 중이 아니에요"; now.textColor = .secondaryLabelColor; sub.stringValue = ""
        }
        limitValue.stringValue = "\(Int(HearingMeter.limitMax))dB"
        limitSlider.isEnabled = HearingMeter.limitOn
        limitInfo.stringValue = !HearingMeter.limitOn ? "켜면 곡의 평균 크기가 이 값을 넘지 않게 천천히 줄여요"
            : (m.cut < -0.5 ? String(format: "넘지 않게 %.0fdB 줄이는 중", -m.cut) : "한도 안이라 그대로 들려요")
        let pct = m.dose * 100
        bar.doubleValue = min(100, pct)
        doseText.stringValue = pct < 1 ? "아직 거의 안 들었어요" : String(format: "%.0f%% 사용 — %@", pct, pct >= 100 ? "오늘은 귀를 쉬게 해 주세요" : "괜찮아요")
    }
    private let calField = NSTextField()
    private let limitBox = NSButton(checkboxWithTitle: "최대 크기 제한", target: nil, action: nil)
    private let limitSlider = NSSlider()
    private let limitValue = NSTextField(labelWithString: "")
    private let limitInfo = NSTextField(labelWithString: "")
    @objc private func limitToggled() {
        HearingMeter.limitOn = limitBox.state == .on
        if HearingMeter.limitOn { HearingMeter.on = true }
        YTMusic.shared?.applyEQ()
        sync()
    }
    @objc private func limitChanged() { HearingMeter.limitMax = limitSlider.doubleValue.rounded(); sync() }
    @objc private func calibrate() {
        guard let v = Double(calField.stringValue.trimmingCharacters(in: .whitespaces)), v > 30, v < 130 else { NSSound.beep(); return }
        HearingMeter.shared.calibrate(toMac: v)
        calField.stringValue = ""
        sync()
    }
    @objc private func resetCal() { HearingMeter.shared.resetCalibration(); sync() }
    @objc private func toggled() { HearingMeter.on = onBox.state == .on; YTMusic.shared?.applyEQ() }
}
