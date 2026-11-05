// 가사 창: 노래에 맞춰 지금 줄을 따라가고(시간 붙은 가사가 있을 때), 고른 언어로 줄마다 번역을 아래에 달아 줌
// · 시간 붙은 가사: LRCLIB(lrclib.net, 무료 공개 가사 모음)에서 곡 제목·아티스트·길이로 찾음
// · 없으면 YouTube Music 가사 탭의 가사를 그대로 (따라가기 없음)
// · 번역: macOS 에 들어 있는 Apple 번역(기기 안에서 처리, 처음 한 번 언어 데이터 내려받기)
import Cocoa
import SwiftUI
import Translation
import NaturalLanguage

/// 번역할 언어 목록 (코드, 이름)
let lyricsLanguages: [(String, String)] = [
    ("", "번역 안 함"),
    ("ko", "한국어"),
    ("en", "English"),
    ("ja", "日本語"),
    ("zh-Hans", "中文(简体)"),
    ("zh-Hant", "中文(繁體)"),
    ("es", "Español"),
    ("fr", "Français"),
    ("de", "Deutsch"),
    ("vi", "Tiếng Việt"),
    ("th", "ไทย"),
]

// MARK: - LRCLIB (시간 붙은 가사)

enum LRCLib {
    struct Synced { let lines: [String]; let times: [Double] }

    /// "[01:02.34] 가사" 형식을 줄·시간으로
    static func parse(_ lrc: String) -> Synced? {
        var lines: [String] = [], times: [Double] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {   // 한 줄에 시간이 여러 개 붙은 경우(후렴 반복)
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                times.append(min * 60 + sec)
                lines.append(text)
            }
        }
        guard !times.isEmpty else { return nil }
        let order = times.indices.sorted { times[$0] < times[$1] }
        return Synced(lines: order.map { lines[$0] }, times: order.map { times[$0] })
    }

    /// 제목 후보: "青と夏 - Ao To Natsu" → ["青と夏 - Ao To Natsu", "青と夏"], 괄호 부분 뺀 것도
    static func titleVariants(_ t: String) -> [String] {
        var out = [t]
        for sep in [" - ", " (", "（", " [", " feat", " ft."] {
            if let r = t.range(of: sep) { out.append(String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)) }
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func find(title: String, artist: String, duration: Double) async -> Synced? {
        for t in titleVariants(title) {
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = [URLQueryItem(name: "track_name", value: t)] + (artist.isEmpty ? [] : [URLQueryItem(name: "artist_name", value: artist)])
            var req = URLRequest(url: c.url!)
            req.setValue("MyLauncher/1.0 (macOS launcher)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            // 시간 붙은 가사가 있고, 곡 길이가 가장 비슷한 것 (4초 넘게 차이 나면 다른 버전으로 봄)
            let cands = arr.compactMap { o -> (Double, String)? in
                guard let lrc = o["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
                let d = (o["duration"] as? Double) ?? 0
                return (duration > 0 ? abs(d - duration) : 0, lrc)
            }.sorted { $0.0 < $1.0 }
            if let best = cands.first, duration <= 0 || best.0 <= 4, let s = parse(best.1) { return s }
        }
        return nil
    }
}

// MARK: - 상태

@MainActor
final class LyricsModel: ObservableObject {
    @Published var title = ""
    @Published var status = "loading"          // ok · none · loading
    @Published var lines: [String] = []
    @Published var times: [Double]? = nil       // 있으면 노래 따라가기
    @Published var translations: [Int: String] = [:]
    @Published var source = ""
    @Published var sourceLangName = ""
    @Published var follow = false
    /// 플레이어 아래 가사 줄 펼침 (기본 켜짐)
    @Published var stripExpanded: Bool = UserDefaults.standard.object(forKey: "lyricsStrip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stripExpanded, forKey: "lyricsStrip"); onStripToggle?() }
    }
    var onStripToggle: (() -> Void)?
    /// 가사 글자 크기 배율 (0.8 ~ 1.8)
    @Published var fontScale: Double = UserDefaults.standard.object(forKey: "lyricsFontScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(fontScale, forKey: "lyricsFontScale"); onStripToggle?() }
    }
    func retranslate() { if config != nil { translations = [:]; makeConfig() } }
    func bumpFont(_ d: Double) { fontScale = min(1.8, max(0.8, (fontScale + d) * 10).rounded() / 10) }
    var onOpenFull: (() -> Void)?
    @Published var target: String {
        didSet {
            UserDefaults.standard.set(target, forKey: "lyricsTarget")
            translations = [:]
            makeConfig()
        }
    }
    @Published var config: TranslationSession.Configuration?
    @Published var note = ""
    var onSeek: ((Double) -> Void)?

    // 재생 위치 (1초마다 들어오는 값 사이를 시계로 메움)
    private var position: Double = 0
    private var positionAt = Date()
    private var playing = false
    private(set) var duration: Double = 0

    private var songKey = ""
    private var ytmText = ""
    private(set) var sourceLang: Locale.Language?

    init() {
        let saved = UserDefaults.standard.string(forKey: "lyricsTarget")
        let system = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0).languageCode?.identifier ?? "ko" } ?? "ko"
        target = saved ?? (lyricsLanguages.contains { $0.0 == system } ? system : "ko")
    }

    func setPosition(_ pos: Double, playing: Bool, duration: Double) {
        position = pos
        positionAt = Date()
        self.playing = playing
        self.duration = duration
    }

    var now: Double { position + (playing ? Date().timeIntervalSince(positionAt) : 0) }

    /// 지금 불러야 하는 줄 (조금 일찍 넘어가게 0.3초 당김)
    func currentIndex(at t: Double) -> Int? {
        guard let times, !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t + 0.3 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }

    /// YouTube Music 에서 읽은 가사 + 곡 정보로 갱신
    func update(_ l: YTMusic.Lyrics, player st: PlayerState?) {
        title = l.title
        let artist = st?.byline.components(separatedBy: " • ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = l.title + "|" + artist
        if key != songKey {
            // 곡이 바뀜: 처음부터 다시
            songKey = key
            times = nil
            ytmText = ""
            lines = []
            translations = [:]
            status = "loading"
            source = ""
            let dur = st?.duration ?? 0
            Task { [weak self] in
                let synced = await LRCLib.find(title: l.title, artist: artist, duration: dur)
                await MainActor.run {
                    guard let self, self.songKey == key else { return }
                    if let synced {
                        self.apply(lines: synced.lines, times: synced.times, source: "시간 맞춤 가사: LRCLIB")
                    } else if !self.ytmText.isEmpty {
                        self.apply(lines: self.ytmText.components(separatedBy: "\n"), times: nil, source: self.source)
                    } else if l.status == "none" {
                        self.status = "none"
                    }
                }
            }
        }
        // 시간 맞춤 가사가 없으면 YouTube Music 가사로
        if l.status == "ok", l.text != ytmText {
            ytmText = l.text
            if times == nil { apply(lines: l.text.components(separatedBy: "\n"), times: nil, source: l.source) }
        } else if l.status == "none", times == nil, lines.isEmpty, status != "loading" {
            status = "none"
        }
    }

    private func apply(lines new: [String], times t: [Double]?, source src: String) {
        lines = new
        times = t
        source = src
        status = "ok"
        translations = [:]
        let r = NLLanguageRecognizer()
        r.processString(new.joined(separator: "\n"))
        if let lang = r.dominantLanguage, lang != .undetermined {
            sourceLang = Locale.Language(identifier: lang.rawValue)
            sourceLangName = Locale.current.localizedString(forIdentifier: lang.rawValue) ?? lang.rawValue
        } else {
            sourceLang = nil
            sourceLangName = ""
        }
        makeConfig()
    }

    private var translateTask: Task<Void, Never>?

    /// 원래 언어와 번역 언어가 다를 때만 번역.
    /// 번역 데이터가 깔려 있으면 화면과 상관없이 바로 번역하고, 없을 때만 화면 쪽에서 내려받기를 물어봄
    private func makeConfig() {
        note = ""
        config = nil
        translateTask?.cancel()
        guard !target.isEmpty, !lines.isEmpty, let src = sourceLang else { return }
        let tgt = Locale.Language(identifier: target)
        if src.languageCode == tgt.languageCode && !target.hasPrefix("zh") { return }
        let reqs = requests()
        guard !reqs.isEmpty else { return }
        translateTask = Task { [weak self] in
            let status = await LanguageAvailability().status(from: src, to: tgt)
            guard !Task.isCancelled, let self else { return }
            switch status {
            case .installed:
                do {
                    let session = TranslationSession(installedSource: src, target: tgt)
                    let results = try await session.translations(from: reqs)
                    guard !Task.isCancelled else { return }
                    for r in results {
                        if let id = r.clientIdentifier, let i = Int(id) { self.translations[i] = r.targetText }
                    }
                } catch {
                    if !Task.isCancelled { self.note = "번역하지 못했어요: \(error.localizedDescription)" }
                }
            case .supported:
                // 번역 데이터가 아직 없음 → 화면의 translationTask 가 내려받을지 물어봄
                self.config = TranslationSession.Configuration(source: src, target: tgt)
                self.note = "번역 언어 데이터를 내려받는 중이거나 허용이 필요해요"
            default:
                self.note = "이 언어 조합은 번역할 수 없어요"
            }
        }
    }

    /// 번역할 줄: 빈 줄 · 같은 문장 반복 · 이미 번역 언어로 된 줄은 건너뜀
    func requests() -> [TranslationSession.Request] {
        let tgt = Locale.Language(identifier: target).languageCode?.identifier ?? target
        var seen = Set<String>()
        return lines.enumerated().compactMap { i, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            let r = NLLanguageRecognizer()
            r.processString(t)
            if let d = r.dominantLanguage, d.rawValue.hasPrefix(tgt), t.count > 3 { return nil }
            return TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
        }
    }

    /// 같은 문장이 반복되는 줄(후렴)은 한 번 번역한 걸 같이 씀
    func translation(for i: Int) -> String? {
        if let t = translations[i] { return t }
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        guard let j = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return nil }
        return translations[j]
    }
}

// MARK: - 화면

struct LyricsView: View {
    @ObservedObject var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch model.status {
            case "ok": content
            case "none": placeholder("이 곡은 가사가 없어요", "music.note")
            default: placeholder("가사 불러오는 중…", "ellipsis")
            }
        }
        .frame(minWidth: 320, minHeight: 300)
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title.isEmpty ? "가사" : model.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if model.times != nil { Label("노래 따라가기", systemImage: "waveform").labelStyle(.titleAndIcon) }
                    if !model.sourceLangName.isEmpty && model.status == "ok" { Text("원문: \(model.sourceLangName)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            FontSizeButtons(model: model)
            if model.times != nil {
                Toggle(isOn: $model.follow) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("지금 부르는 줄로 자동 스크롤")
            }
            Picker("번역", selection: $model.target) {
                ForEach(lyricsLanguages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        // 0.2초마다 지금 줄을 다시 계산
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let cur = model.currentIndex(at: model.now)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Spacer().frame(height: 40)
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                            row(i, line, current: cur)
                                .id(i)
                        }
                        if !model.source.isEmpty {
                            Text(model.source).font(.caption2).foregroundStyle(.tertiary).padding(.top, 12)
                        }
                        if !model.note.isEmpty {
                            Text(model.note).font(.caption).foregroundStyle(.orange)
                        }
                        Spacer().frame(height: 120)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: cur) { _, new in
                    guard model.follow, let new else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.35)) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ i: Int, _ line: String, current cur: Int?) -> some View {
        let synced = model.times != nil
        let isCur = synced && cur == i
        let passed = synced && (cur ?? -1) > i
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            // 간주: 시간 맞춤 가사의 빈 줄은 ♪ 로
            Text(synced ? "♪" : " ").font(.system(size: 13)).foregroundStyle(isCur ? .primary : .tertiary)
                .frame(height: synced ? 18 : 6)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .font(.system(size: (isCur ? 17 : 15) * model.fontScale, weight: isCur ? .bold : .medium))
                    .foregroundStyle(isCur ? Color.primary : (synced ? (passed ? Color.secondary.opacity(0.7) : Color.secondary) : Color.primary))
                if let t = model.translation(for: i), t != line {
                    Text(t).font(.system(size: (isCur ? 14 : 13) * model.fontScale))
                        .foregroundStyle(isCur ? Color.accentColor : Color.secondary.opacity(synced ? 0.8 : 1))
                }
            }
            .padding(.vertical, isCur ? 4 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                // 시간 맞춤 가사면 그 줄로 이동
                if let times = model.times, model.duration > 0 { model.onSeek?(times[i] / model.duration) }
            }
            .help(synced ? "이 줄부터 듣기" : "")
            .animation(.easeOut(duration: 0.2), value: isCur)
        }
    }

    private func placeholder(_ text: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A− / A+ 버튼
struct FontSizeButtons: View {
    @ObservedObject var model: LyricsModel
    var body: some View {
        HStack(spacing: 2) {
            Button { model.bumpFont(-0.1) } label: { Text("A−").font(.system(size: 10, weight: .semibold)) }
                .help("가사 글자 작게").disabled(model.fontScale <= 0.8)
            Button { model.bumpFont(0.1) } label: { Text("A+").font(.system(size: 12, weight: .semibold)) }
                .help("가사 글자 크게").disabled(model.fontScale >= 1.8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 플레이어 아래 가사 줄 (지금 줄 + 다음 줄)

struct LyricsStrip: View {
    @ObservedObject var model: LyricsModel
    static let collapsedHeight: CGFloat = 30
    /// 펼쳤을 때 높이: 지금 줄 + 번역 + 다음 줄이 들어가도록 글자 크기에 맞춤
    static func expandedHeight(_ scale: Double) -> CGFloat { collapsedHeight + CGFloat(ceil(66 * scale)) + 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 머리줄: ⌃/⌄ · 접혔을 땐 지금 줄 한 줄 · 전체 가사
            HStack(spacing: 6) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.stripExpanded.toggle() } } label: {
                    Image(systemName: model.stripExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(model.stripExpanded ? "가사 접기" : "가사 펼치기")
                Text("가사").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if !model.stripExpanded {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(currentText(model.currentIndex(at: model.now)) ?? statusText)
                            .font(.system(size: 11)).lineLimit(1).foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: 4)
                if model.stripExpanded { FontSizeButtons(model: model) }
                Button { model.onOpenFull?() } label: {
                    Text("전체 가사").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("전체 가사 창 열기")
            }
            .padding(.horizontal, 14)
            .frame(height: Self.collapsedHeight)

            if model.stripExpanded {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let cur = model.currentIndex(at: model.now)
                    lines(cur)
                }
                .frame(height: Self.expandedHeight(model.fontScale) - Self.collapsedHeight)
                .clipped()
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).padding(.horizontal, 8).padding(.vertical, 2))
        // 번역: 언어 데이터가 없으면 macOS 가 내려받을지 물어봄 (가사 줄과 전체 가사 창이 함께 씀)
        .translationTask(model.config) { session in
            let reqs = await MainActor.run { model.requests() }
            guard !reqs.isEmpty else { return }
            do {
                for try await resp in session.translate(batch: reqs) {
                    guard let id = resp.clientIdentifier, let i = Int(id) else { continue }
                    await MainActor.run { model.translations[i] = resp.targetText }
                }
            } catch {
                await MainActor.run { model.note = "번역하지 못했어요: \(error.localizedDescription)" }
            }
            // 내려받은 뒤엔 바로 번역하는 방식으로 다시
            await MainActor.run { model.retranslate() }
        }
    }

    private var statusText: String {
        switch model.status {
        case "none": return "이 곡은 가사가 없어요"
        case "ok": return model.times == nil ? "시간 맞춤 가사가 없어요 · 전체 가사에서 볼 수 있어요" : "♪"
        default: return "가사 불러오는 중…"
        }
    }

    private func text(_ i: Int) -> String? {
        guard i >= 0, i < model.lines.count else { return nil }
        let t = model.lines[i].trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "♪" : t
    }
    private func currentText(_ cur: Int?) -> String? { cur.flatMap { text($0) } }

    /// 다음에 나올 (빈 줄이 아닌) 줄
    private func nextIndex(after cur: Int?) -> Int? {
        var i = (cur ?? -1) + 1
        while i < model.lines.count {
            if !model.lines[i].trimmingCharacters(in: .whitespaces).isEmpty { return i }
            i += 1
        }
        return nil
    }

    @ViewBuilder
    private func lines(_ cur: Int?) -> some View {
        if model.status != "ok" || model.times == nil {
            Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let next = nextIndex(after: cur)
            VStack(alignment: .leading, spacing: 3) {
                // 지금 줄 + 번역
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentText(cur) ?? "♪")
                        .font(.system(size: 15 * model.fontScale, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    if let c = cur, let t = model.translation(for: c), t != model.lines[c] {
                        Text(t).font(.system(size: 12 * model.fontScale)).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }
                .id(cur ?? -1)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                // 다음 줄 (대기)
                if let n = next {
                    Text(text(n) ?? "")
                        .font(.system(size: 12 * model.fontScale)).foregroundStyle(.secondary).lineLimit(1)
                        .id("next-\(n)")
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.3), value: cur)
            .contentShape(Rectangle())
            .onTapGesture { model.onOpenFull?() }
        }
    }
}

// MARK: - 가사 관리 (플레이어가 켜져 있으면 늘 가사를 불러옴) · 전체 가사 창

@MainActor
final class LyricsController: NSObject, NSWindowDelegate {
    let model = LyricsModel()
    private var window: NSWindow?
    private var timer: Timer?
    private weak var music: YTMusic?

    /// 플레이어 아래에 붙이는 가사 줄
    lazy var stripView: NSView = NSHostingView(rootView: LyricsStrip(model: model))
    var stripHeight: CGFloat { model.stripExpanded ? LyricsStrip.expandedHeight(model.fontScale) : LyricsStrip.collapsedHeight }

    init(music: YTMusic) {
        self.music = music
        super.init()
        model.onSeek = { [weak music] f in music?.seek(f) }
        model.onOpenFull = { [weak self] in self?.show() }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// 전체 가사 창
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "전체 가사"
            w.contentView = NSHostingView(rootView: LyricsView(model: model))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("LyricsWindow")
            if UserDefaults.standard.string(forKey: "NSWindow Frame LyricsWindow") == nil { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        start()
    }

    func toggle() { isVisible ? window?.orderOut(nil) : show() }

    /// 미니 플레이어가 1초마다 주는 재생 위치
    func playerUpdated(_ st: PlayerState) {
        model.setPosition(st.position, playing: st.playing ?? false, duration: st.duration)
    }

    private func refresh() {
        guard let music, music.isActive else { return }
        music.fetchLyrics { [weak self] l in self?.model.update(l, player: music.state) }
    }
}
