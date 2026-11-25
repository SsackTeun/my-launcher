// 이퀄라이저 (macOS 오디오 탭): 도구함 안 웹 엔진이 내는 소리만 가로채서 10밴드 필터를 거쳐 스피커로
// - 웹 페이지 안의 Web Audio 는 YouTube Music(MSE) 소리를 받지 못해서(계측해 보니 0) 맥 쪽에서 처리
// - 가로챈 소리는 원래 길로는 안 나가게(음소거) 하고, 필터를 거친 소리만 내보냄
// - 처음 켤 때 macOS 가 '오디오 녹음' 권한을 물어봄. 녹음 · 저장 · 전송은 하지 않음
import Cocoa
import CoreAudio
import Accelerate

@_silgen_name("responsibility_get_pid_responsible_for_pid") private func responsiblePid(_ pid: pid_t) -> pid_t

final class TapEQ: @unchecked Sendable {
    nonisolated(unsafe) static let shared = TapEQ()

    static let bands = 10
    /// 필터 자리 (자리를 고정해 두면 값을 바꿔도 소리가 튀지 않음)
    ///   0..<10 10밴드 · 10..<12 저음량 보정 · 12..<43 자동 31밴드 · 43..<59 정밀 EQ 점들
    static let slotLoud = 10, slotAuto = 12, slotParam = 43, maxParam = 16
    static let filters = 59
    /// 저음량 보정으로 올릴 저음 · 고음 (dB)
    private var loud: (bass: Double, treble: Double) = (0, 0)
    /// 자동 31밴드 값 (dB)
    private var auto31 = [Double](repeating: 0, count: 31)
    /// 정밀 EQ 점들
    private var param: [EQFilter] = []
    /// 필터마다 쓰는지 (0 이면 건너뜀)
    private let act = UnsafeMutablePointer<UInt8>.allocate(capacity: filters)
    private let nextAct = UnsafeMutablePointer<UInt8>.allocate(capacity: filters)

    // 소리 그림(스펙트럼)용: 필터를 거친 뒤 왼쪽 소리를 계속 담아 두는 고리 버퍼
    static let specSize = 16384
    private let spec = UnsafeMutablePointer<Float>.allocate(capacity: specSize)
    private var specIdx = 0
    /// 정밀 EQ 창이 열려 있을 때만 담음
    var spectrumOn = false
    /// 가장 최근 n 개 (n 은 2의 거듭제곱)
    func recentSamples(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        let end = specIdx
        for i in 0..<n { out[i] = spec[(end - n + i + Self.specSize * 4) % Self.specSize] }
        return out
    }
    var currentSampleRate: Double { sampleRate }
    private(set) var loudShown: (bass: Double, treble: Double) = (0, 0)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: [pid_t] = []
    private(set) var running = false
    /// 마지막으로 알려 줄 문제 (권한 · 장치)
    private(set) var problem: String?
    /// 진단용 시각 (CACurrentMediaTime): 탭 만듦 · 장치 시작 · 처음 들어온 소리 · 처음 나간 소리
    var tapAt: Double = 0, devStartAt: Double = 0, firstInAt: Double = 0, firstOutAt: Double = 0

    // 실시간 처리용 (할당 없이 미리 잡아 둔 칸)
    private let coef = UnsafeMutablePointer<Double>.allocate(capacity: filters * 5)      // b0 b1 b2 a1 a2
    private let nextCoef = UnsafeMutablePointer<Double>.allocate(capacity: filters * 5)
    private let mem = UnsafeMutablePointer<Double>.allocate(capacity: 2 * filters * 4)   // 채널 · 밴드마다 x1 x2 y1 y2
    private var pre: Double = 1, nextPre: Double = 1
    private var flat = true, nextFlat = true
    private var hasNext = false
    private var lock = os_unfair_lock()
    /// 들어온 소리 크기 (권한이 없으면 계속 0 → 알아채고 끔)
    private var inputPeak: Float = 0
    /// 진단: 나간 소리 최대 크기 · 1 을 넘어 잘린 횟수
    private var outPeak: Float = 0
    private var clips = 0
    /// 나간 소리 세기 (청력 보호 표시용: 제곱 합 · 개수)
    private var sqSum: Double = 0
    private var sqN = 0
    /// 지난번에 꺼낸 뒤로 나간 소리의 RMS (0 ~ 1). 소리가 없으면 nil
    func takeRMS() -> Double? {
        os_unfair_lock_lock(&lock)
        defer { sqSum = 0; sqN = 0; os_unfair_lock_unlock(&lock) }
        guard sqN > 0 else { return nil }
        return sqrt(sqSum / Double(sqN))
    }
    /// 귀가 느끼는 크기로 재기 (A 가중: 사람 귀가 둔한 아주 낮은 · 아주 높은 소리는 덜 셈 — 맥 · 애플 건강 앱의 헤드폰 음량과 같은 방식)
    ///   48kHz 용 6차 필터 계수 (표준 A 가중 곡선을 디지털로 옮긴 것)
    private static let awB: [Double] = [0.234301792299513, -0.468603584599026, -0.234301792299513, 0.937207168598053,
                                        -0.234301792299513, -0.468603584599026, 0.234301792299513]
    private static let awA: [Double] = [1, -4.113043408775871, 6.553121752655047, -4.990849294163381,
                                        1.785737302937573, -0.246190595319487, 0.011224250033231]
    private let awX = UnsafeMutablePointer<Double>.allocate(capacity: 7)
    private let awY = UnsafeMutablePointer<Double>.allocate(capacity: 7)
    private func aWeight(_ x: Double) -> Double {
        var i = 6
        while i > 0 { awX[i] = awX[i - 1]; awY[i] = awY[i - 1]; i -= 1 }
        awX[0] = x
        var y = 0.0
        for k in 0..<7 { y += Self.awB[k] * awX[k] }
        for k in 1..<7 { y -= Self.awA[k] * awY[k] }
        awY[0] = y
        return y
    }

    /// 최대 크기 제한: 이만큼 소리를 줄임 (dB, 0 이하). 바로 바꾸면 '툭' 끊겨서 실시간 쪽에서 부드럽게 따라감
    var limitDB: Double = 0
    private var limitGain: Double = 1
    /// 프레임마다 쓴 크기 (왼쪽 차례에 정하고 오른쪽도 같은 값을 씀 — 좌우가 어긋나지 않게)
    private let gainBuf = UnsafeMutablePointer<Double>.allocate(capacity: 8192)

    /// 효과 없이 그대로 내보내기 (소리 보정은 꺼져 있지만 청력 보호 측정은 할 때)
    var bypass = false

    // MARK: 곡 분석 (필터 거치기 전 소리를 10초쯤 모아서 대역별 세기를 잼)

    private let capMax = 48000 * 12
    private lazy var cap = UnsafeMutablePointer<Float>.allocate(capacity: capMax)
    private var capturing = false
    private var capIndex = 0
    private var capWant = 0

    /// 모으기 시작 (seconds 초 만큼)
    func startCapture(seconds: Double) {
        capIndex = 0
        capWant = min(capMax, Int(sampleRate * seconds))
        capturing = true
    }
    /// 0 ~ 1 (얼마나 모았는지)
    var captureProgress: Double { capWant == 0 ? 0 : min(1, Double(capIndex) / Double(capWant)) }
    var isCapturing: Bool { capturing }
    func cancelCapture() { capturing = false }

    /// 다 모았으면 10밴드 세기(dB, 서로 비교용)를 돌려줌. 아직이면 nil
    func finishCapture(centers: [Double] = YTMusicFreqs, width: Double = sqrt(2)) -> [Double]? {
        guard capturing, capIndex >= capWant, capWant > 0 else { return nil }
        capturing = false
        let n = 16384, log2n = vDSP_Length(14)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: n / 2)
        var frames = 0
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var start = 0
        while start + n <= capWant {
            vDSP_vmul(cap + start, 1, window, 1, &buf, 1, vDSP_Length(n))
            // 너무 조용한 조각(곡 사이 · 쉼)은 빼기
            var rms: Float = 0
            vDSP_rmsqv(buf, 1, &rms, vDSP_Length(n))
            if rms > 1e-4 {
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var sp = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        buf.withUnsafeBufferPointer { b in
                            b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(n / 2)) }
                        }
                        vDSP_fft_zrip(setup, &sp, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
                for k in 1..<(n / 2) { power[k] += Double(re[k] * re[k] + im[k] * im[k]) }
                frames += 1
            }
            start += n / 2
        }
        guard frames >= 4 else { return nil }
        let binHz = sampleRate / Double(n)
        return centers.map { fc in
            let lo = max(1, Int(fc / width / binHz)), hi = min(n / 2 - 1, max(lo, Int(fc * width / binHz)))
            var e = 0.0
            for k in lo...hi { e += power[k] }
            return 10 * log10(max(1e-12, e / Double(frames)))
        }
    }
    private var gains = [Double](repeating: 0, count: bands)
    private var sampleRate: Double = 48000

    private init() {
        mem.initialize(repeating: 0, count: 2 * Self.filters * 4)
        act.initialize(repeating: 0, count: Self.filters)
        nextAct.initialize(repeating: 0, count: Self.filters)
        spec.initialize(repeating: 0, count: Self.specSize)
        awX.initialize(repeating: 0, count: 7); awY.initialize(repeating: 0, count: 7)
        gainBuf.initialize(repeating: 1, count: 8192)
        coef.initialize(repeating: 0, count: Self.filters * 5)
        nextCoef.initialize(repeating: 0, count: Self.filters * 5)
        for b in 0..<Self.filters { coef[b * 5] = 1; nextCoef[b * 5] = 1 }
        // 이어폰을 꽂거나 출력 장치를 바꾸면 다시 연결
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            guard let self, self.running else { return }
            self.stop(); self.start()
        }
    }

    // MARK: 켜기 · 끄기 · 값 바꾸기 (메인 스레드)

    func update(on: Bool, gains g: [Double]) {
        gains = g
        guard on else { stop(); return }
        if !running || currentPids() != tapped { setCoefficients(); stop(); start(); return }
        setCoefficients()
    }

    /// 자동 31밴드 값
    func setAuto(_ g: [Double]) {
        guard g.count == 31, g != auto31 else { return }
        auto31 = g
        if running { setCoefficients() }
    }
    /// 정밀 EQ 점들
    func setParam(_ f: [EQFilter]) {
        let f = Array(f.prefix(Self.maxParam))
        guard f != param else { return }
        param = f
        if running { setCoefficients() }
    }

    /// 지금 켜진 필터 전부 (화면에 반응 곡선 그릴 때도 씀)
    func allFilters() -> [EQFilter] {
        var out: [EQFilter] = []
        for (i, f) in YTMusicFreqs.enumerated() where gains[i] != 0 {
            out.append(EQFilter(kind: i == 0 ? .lowShelf : (i == 9 ? .highShelf : .peak), f: f, g: gains[i], q: i == 0 || i == 9 ? 0.71 : 1.1))
        }
        if abs(loud.bass) > 0.05 { out.append(EQFilter(kind: .lowShelf, f: 100, g: loud.bass, q: 0.71)) }
        if abs(loud.treble) > 0.05 { out.append(EQFilter(kind: .highShelf, f: 10000, g: loud.treble, q: 0.71)) }
        for (i, f) in Self.thirdOctave.enumerated() where auto31[i] != 0 { out.append(EQFilter(kind: .peak, f: f, g: auto31[i], q: 4.3)) }
        return out + param
    }
    /// 1/3 옥타브 31밴드 가운데 주파수
    static let thirdOctave: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                                        1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]

    /// 저음량 보정 값 바꾸기 (조금만 달라졌으면 그대로 — 계수를 자꾸 바꾸지 않게)
    func setLoudness(bass: Double, treble: Double) {
        loudShown = (bass, treble)
        guard abs(bass - loud.bass) > 0.25 || abs(treble - loud.treble) > 0.25 else { return }
        loud = (bass, treble)
        if running { setCoefficients() }
    }

    /// 출력 장치(이어폰 · 스피커) 볼륨 (dB, 0 이 최대). 볼륨 조절이 없는 장치면 0
    static func outputVolumeDB() -> Double {
        guard let dev: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) else { return 0 }
        // 블루투스 이어폰은 dB 값을 늘 0 으로 주고 0 ~ 1 눈금만 맞게 줘서, 눈금으로 어림 (맥 볼륨 눈금은 대략 제곱 곡선: 0.33 → 약 -19dB)
        for el: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(dev, &a) else { continue }
            var v: Float32 = 1, sz = UInt32(4)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr { return 40 * log10(max(0.01, Double(v))) }
        }
        return 0
    }

    /// 몇 초마다: 웹 엔진 소리 프로세스가 바뀌었으면 다시 연결, 소리가 안 들어오면 권한 문제로 보고 끔
    private var silentSince: Date?
    func check(playing: Bool) {
        guard running else { return }
        if currentPids() != tapped { stop(); start(); return }
        os_unfair_lock_lock(&lock); let peak = inputPeak; inputPeak = 0; os_unfair_lock_unlock(&lock)
        if UserDefaults.standard.bool(forKey: "ytmDebug") {   // 진단용
            try? "running=\(running) pids=\(tapped) peak=\(peak) rate=\(sampleRate) flat=\(flat) playing=\(playing) loud=\(loud) outDB=\(Self.outputVolumeDB()) outPeak=\(outPeak) clips=\(clips)".write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-eq.txt", atomically: true, encoding: .utf8)
        }
        outPeak = 0; clips = 0
        if playing && peak == 0 {
            if silentSince == nil { silentSince = Date() }
            if Date().timeIntervalSince(silentSince!) > 3 {
                stop()
                problem = "소리를 가로채지 못했어요. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 '도구함'의 '시스템 오디오 녹음만'을 켜 주세요."
                NotificationCenter.default.post(name: .tapEQProblem, object: nil)
            }
        } else { silentSince = nil }
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); procID = nil
        tapped = []; running = false; silentSince = nil
    }

    // MARK: 연결

    /// 도구함이 띄운 웹 엔진 소리 프로세스들 (com.apple.WebKit.GPU 중 책임 프로세스가 도구함인 것)
    private func currentPids() -> [pid_t] {
        let me = ProcessInfo.processInfo.processIdentifier
        return Self.processObjects().compactMap { o -> pid_t? in
            let pid: pid_t = Self.prop(o, kAudioProcessPropertyPID) ?? 0
            guard pid > 0, pid != me, responsiblePid(pid) == me else { return nil }
            return pid
        }.sorted()
    }

    private func start() {
        problem = nil
        let pids = currentPids()
        guard !pids.isEmpty else { return }    // 아직 소리를 낸 적이 없음 → 다음 확인 때
        var objs: [AudioObjectID] = []
        for p in pids {
            var pid = p, obj = AudioObjectID(kAudioObjectUnknown), sz = UInt32(MemoryLayout<AudioObjectID>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &sz, &obj) == noErr,
               obj != kAudioObjectUnknown { objs.append(obj) }
        }
        guard !objs.isEmpty else { return }

        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        desc.name = "도구함 이퀄라이저"
        desc.isPrivate = true
        desc.muteBehavior = .muted          // 원래 길로는 안 나가게 (필터 거친 소리만)
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != kAudioObjectUnknown else {
            problem = "오디오 탭을 만들지 못했어요"; return
        }
        tapID = tap
        tapAt = CACurrentMediaTime()

        guard let outDev: AudioObjectID = Self.prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              let outUID = Self.uid(outDev) else { stop(); return }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "도구함 이퀄라이저",
            kAudioAggregateDeviceUIDKey: "local.jaeyeong.launcher.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var a = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &a) == noErr else { problem = "출력 장치를 만들지 못했어요"; stop(); return }
        aggID = a
        sampleRate = Self.prop(a, kAudioDevicePropertyNominalSampleRate) ?? 48000
        setCoefficients()
        mem.update(repeating: 0, count: 2 * Self.filters * 4)

        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, a, nil) { [unowned self] _, inData, _, outData, _ in
            self.process(inData, outData)
        }
        guard st == noErr, let pid else { stop(); return }
        procID = pid
        guard AudioDeviceStart(a, pid) == noErr else { stop(); return }
        devStartAt = CACurrentMediaTime()
        tapped = pids
        running = true
    }

    // MARK: 필터 계수 (RBJ 바이쿼드)

    /// 필터 하나의 계수 (b0 b1 b2 a1 a2, a0 로 나눈 것)
    static func coefficients(_ f: EQFilter, fs: Double) -> [Double] {
        let A = pow(10, f.g / 40), w = 2 * Double.pi * min(max(f.f, 10), fs * 0.45) / fs, cw = cos(w), sw = sin(w)
        let q = max(0.1, f.q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch f.kind {
        case .peak:
            let alpha = sw / (2 * q)
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf, .highShelf:
            let alpha = sw / (2 * q), sA = 2 * sqrt(A) * alpha
            if f.kind == .lowShelf {
                b0 = A * ((A + 1) - (A - 1) * cw + sA); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sA)
                a0 = (A + 1) + (A - 1) * cw + sA; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - sA
            } else {
                b0 = A * ((A + 1) + (A - 1) * cw + sA); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sA)
                a0 = (A + 1) - (A - 1) * cw + sA; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - sA
            }
        case .highPass:
            let alpha = sw / (2 * q)
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .lowPass:
            let alpha = sw / (2 * q)
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// 필터들을 합친 세기 변화 (dB) — 화면의 반응 곡선
    static func response(_ fs: [EQFilter], at f: Double, rate: Double = 48000) -> Double {
        let w = 2 * Double.pi * f / rate
        var db = 0.0
        for flt in fs {
            let k = coefficients(flt, fs: rate)
            // |H(e^jw)|
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            let nr = k[0] + k[1] * c1 + k[2] * c2, ni = -(k[1] * s1 + k[2] * s2)
            let dr = 1 + k[3] * c1 + k[4] * c2, di = -(k[3] * s1 + k[4] * s2)
            db += 10 * log10(max(1e-12, (nr * nr + ni * ni) / max(1e-12, dr * dr + di * di)))
        }
        return db
    }

    private func setCoefficients() {
        let fs = sampleRate
        // 자리별 필터 (nil 이면 안 씀)
        var slots = [EQFilter?](repeating: nil, count: Self.filters)
        for (i, f) in YTMusicFreqs.enumerated() where gains[i] != 0 {
            slots[i] = EQFilter(kind: i == 0 ? .lowShelf : (i == 9 ? .highShelf : .peak), f: f, g: gains[i], q: i == 0 || i == 9 ? 0.71 : 1.1)
        }
        // 저음은 겹치면 먹먹해짐: '내 취향'에서 이미 저음을 올렸으면 그만큼 저음량 보정의 저음을 덜 올림
        let tasteBass = max(0, gains[0], gains[1])
        let lb = max(0, loud.bass - tasteBass)
        if lb > 0.05 { slots[Self.slotLoud] = EQFilter(kind: .lowShelf, f: 100, g: lb, q: 0.71) }
        if abs(loud.treble) > 0.05 { slots[Self.slotLoud + 1] = EQFilter(kind: .highShelf, f: 10000, g: loud.treble, q: 0.71) }
        for (i, f) in Self.thirdOctave.enumerated() where auto31[i] != 0 { slots[Self.slotAuto + i] = EQFilter(kind: .peak, f: f, g: auto31[i], q: 4.3) }
        for (i, f) in param.enumerated() where f.kind == .highPass || f.kind == .lowPass || f.g != 0 { slots[Self.slotParam + i] = f }
        // 올린 만큼 전체를 조금 낮춰 찢어지지 않게 (저음량 보정은 작게 들을 때라 빼고 계산)
        var boost: [EQFilter] = []
        for (i, f) in slots.enumerated() where i != Self.slotLoud && i != Self.slotLoud + 1 { if let f { boost.append(f) } }
        var peak = 0.0
        var f = 20.0
        while f < 20000 { peak = max(peak, Self.response(boost, at: f, rate: fs)); f *= 1.12 }
        os_unfair_lock_lock(&lock)
        for (i, flt) in slots.enumerated() {
            if let flt {
                let k = Self.coefficients(flt, fs: fs)
                for j in 0..<5 { nextCoef[i * 5 + j] = k[j] }
                nextAct[i] = 1
            } else {
                nextCoef[i * 5] = 1; for j in 1..<5 { nextCoef[i * 5 + j] = 0 }
                nextAct[i] = 0
            }
        }
        // 전체를 낮추면 고음까지 같이 작아져 먹먹하게 들려서 조금만 낮추고, 넘치는 순간은 부드럽게 눌러 줌(아래 리미터)
        nextPre = pow(10, -max(0, peak) * 0.25 / 20)
        nextFlat = slots.allSatisfy { $0 == nil }
        hasNext = true
        os_unfair_lock_unlock(&lock)
    }

    // MARK: 실시간 처리 (소리 장치 스레드: 할당 · 잠금 대기 없음)

    private func process(_ inList: UnsafePointer<AudioBufferList>, _ outList: UnsafeMutablePointer<AudioBufferList>) {
        if os_unfair_lock_trylock(&lock) {
            if hasNext {
                coef.update(from: nextCoef, count: Self.filters * 5)
                act.update(from: nextAct, count: Self.filters)
                pre = nextPre; flat = nextFlat; hasNext = false
            }
            os_unfair_lock_unlock(&lock)
        }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inList))
        let outs = UnsafeMutableAudioBufferListPointer(outList)
        // 들어온 소리: 보통 버퍼 하나에 2채널이 번갈아(인터리브), 아니면 채널마다 버퍼
        guard let first = ins.first, let inBase = first.mData?.assumingMemoryBound(to: Float.self) else {
            for o in outs { if let d = o.mData { memset(d, 0, Int(o.mDataByteSize)) } }
            return
        }
        let inInter = ins.count == 1 ? max(1, Int(first.mNumberChannels)) : 1
        let inFrames = Int(first.mDataByteSize) / (4 * inInter)
        let right: UnsafeMutablePointer<Float>? = ins.count > 1 ? ins[1].mData?.assumingMemoryBound(to: Float.self) : nil
        var peak: Float = 0
        var sq: Double = 0, sqc = 0
        // 크기 제한: 줄일 땐 빠르게(0.05초), 풀 땐 천천히(0.8초)
        let gTarget = pow(10, min(0, limitDB) / 20)
        let kDown = 1 - exp(-1 / (sampleRate * 0.05)), kUp = 1 - exp(-1 / (sampleRate * 0.8))
        // 나갈 곳: 버퍼마다 채널 수만큼 (왼 · 오른만 채우고 나머지는 0)
        var outCh = 0
        for o in outs {
            guard let d = o.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let nch = max(1, Int(o.mNumberChannels))
            let frames = min(inFrames, Int(o.mDataByteSize) / (4 * nch))
            memset(d, 0, Int(o.mDataByteSize))
            for c in 0..<nch {
                let ch = outCh + c
                guard ch < 2 else { continue }
                let m = mem + ch * Self.filters * 4
                for i in 0..<frames {
                    let xin: Float = inInter >= 2 ? inBase[i * inInter + min(ch, inInter - 1)] : (ch == 1 ? (right?[i] ?? inBase[i]) : inBase[i])
                    if abs(xin) > peak { peak = abs(xin) }
                    // 곡 분석: 필터 거치기 전 왼쪽 소리를 모아 둠
                    if ch == 0, capturing, capIndex < capMax { cap[capIndex] = xin; capIndex += 1 }
                    var x = Double(xin)
                    if !flat && !bypass {
                        x *= pre
                        for b in 0..<Self.filters where act[b] != 0 {
                            let k = coef + b * 5, s = m + b * 4
                            let y = k[0] * x + k[1] * s[0] + k[2] * s[1] - k[3] * s[2] - k[4] * s[3]
                            s[1] = s[0]; s[0] = x; s[3] = s[2]; s[2] = y
                            x = y
                        }
                    }
                    if abs(x) > 1 { clips += 1 }
                    if Float(abs(x)) > outPeak { outPeak = Float(abs(x)) }
                    // 크기 제한 (왼쪽 채널 차례에서 한 번 움직이고, 오른쪽은 같은 값)
                    if ch == 0 {
                        limitGain += (gTarget - limitGain) * (gTarget < limitGain ? kDown : kUp)
                        if i < 8192 { gainBuf[i] = limitGain }
                    }
                    x *= i < 8192 ? gainBuf[i] : limitGain
                    // 부드러운 리미터: 0.8 까지는 그대로, 넘으면 1 을 넘지 않게 둥글게 (딱 잘려 찢어지는 소리 대신)
                    let ax = abs(x)
                    if ax > 0.8 { x = (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((ax - 0.8) / 0.2)) }
                    let yo = Float(x)
                    if ch == 0 { let aw = aWeight(x); sq += aw * aw; sqc += 1 }
                    d[i * nch + c] = yo
                    if ch == 0, spectrumOn { spec[specIdx] = yo; specIdx = (specIdx + 1) % Self.specSize }
                }
            }
            outCh += nch
        }
        // 진단: 처음 소리가 들어온 · 나간 때 (켠 뒤 첫 재생에 소리가 늦는 원인 찾기)
        if firstInAt == 0, peak > 0.0005 { firstInAt = CACurrentMediaTime() }
        if firstOutAt == 0, sq > 1e-7 * Double(max(1, sqc)) { firstOutAt = CACurrentMediaTime() }
        if os_unfair_lock_trylock(&lock) {
            if peak > inputPeak { inputPeak = peak }
            sqSum += sq; sqN += sqc
            os_unfair_lock_unlock(&lock)
        }
    }

    // MARK: Core Audio 도우미

    static func processObjects() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids
    }

    static func uid(_ dev: AudioObjectID) -> CFString? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var u: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &u) == noErr else { return nil }
        return u?.takeRetainedValue()
    }

    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> T? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, p) == noErr else { return nil }
        return p.load(as: T.self)
    }
}

/// 필터 주파수 (YTMusic.eqFreqs 와 같음 — 실시간 스레드에서 MainActor 를 건드리지 않게 따로)
let YTMusicFreqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

extension Notification.Name {
    static let tapEQProblem = Notification.Name("tapEQProblem")
}

/// 정밀 EQ 필터 하나
struct EQFilter: Codable, Equatable {
    enum Kind: Int, Codable, CaseIterable { case peak, lowShelf, highShelf, highPass, lowPass
        var name: String { ["피크", "저음 셸프", "고음 셸프", "저음 자르기", "고음 자르기"][rawValue] }
    }
    var kind: Kind
    var f: Double
    var g: Double
    var q: Double
}
