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
    @Published var follow = true
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

    /// 원래 언어와 번역 언어가 다를 때만 번역 준비
    private func makeConfig() {
        note = ""
        guard !target.isEmpty, !lines.isEmpty, let src = sourceLang else { config = nil; return }
        let tgt = Locale.Language(identifier: target)
        if src.languageCode == tgt.languageCode && !target.hasPrefix("zh") { config = nil; return }
        if config?.source == src && config?.target == tgt { config?.invalidate() }
        else { config = TranslationSession.Configuration(source: src, target: tgt) }
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
        // 번역: 언어 데이터가 없으면 macOS 가 내려받을지 물어봄
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
        }
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
                    .font(.system(size: isCur ? 17 : 15, weight: isCur ? .bold : .medium))
                    .foregroundStyle(isCur ? Color.primary : (synced ? (passed ? Color.secondary.opacity(0.7) : Color.secondary) : Color.primary))
                if let t = model.translation(for: i), t != line {
                    Text(t).font(.system(size: isCur ? 14 : 13))
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

// MARK: - 창

/// 가사 창 (닫으면 숨기기만, 곡이 바뀌면 자동으로 새 가사)
@MainActor
final class LyricsWindow: NSObject, NSWindowDelegate {
    private let model = LyricsModel()
    private var window: NSWindow?
    private var timer: Timer?
    private weak var music: YTMusic?

    init(music: YTMusic) {
        self.music = music
        super.init()
        model.onSeek = { [weak music] f in music?.seek(f) }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "가사"
            w.contentView = NSHostingView(rootView: LyricsView(model: model))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("LyricsWindow")
            if UserDefaults.standard.string(forKey: "NSWindow Frame LyricsWindow") == nil { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func toggle() { isVisible ? window?.orderOut(nil) : show() }

    /// 미니 플레이어가 1초마다 주는 재생 위치
    func playerUpdated(_ st: PlayerState) {
        guard isVisible else { return }
        model.setPosition(st.position, playing: st.playing ?? false, duration: st.duration)
    }

    private func refresh() {
        guard isVisible, let music else { return }
        music.fetchLyrics { [weak self] l in self?.model.update(l, player: music.state) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
