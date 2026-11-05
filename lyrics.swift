// 가사 창: YouTube Music 가사를 보여 주고, 고른 언어로 줄마다 번역을 아래에 달아 줌
// 번역은 macOS 에 들어 있는 Apple 번역(기기 안에서 처리, 처음 한 번 언어 데이터 내려받기)
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

@MainActor
final class LyricsModel: ObservableObject {
    @Published var title = ""
    @Published var status = "loading"          // ok · none · loading
    @Published var lines: [String] = []
    @Published var translations: [Int: String] = [:]
    @Published var source = ""
    @Published var sourceLangName = ""
    @Published var target: String {
        didSet {
            UserDefaults.standard.set(target, forKey: "lyricsTarget")
            translations = [:]
            makeConfig()
        }
    }
    @Published var config: TranslationSession.Configuration?
    @Published var note = ""
    private var text = ""
    private(set) var sourceLang: Locale.Language?

    init() {
        // 처음엔 Mac 의 주 언어로
        let saved = UserDefaults.standard.string(forKey: "lyricsTarget")
        let system = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0).languageCode?.identifier ?? "ko" } ?? "ko"
        target = saved ?? (lyricsLanguages.contains { $0.0 == system } ? system : "ko")
    }

    func update(_ l: YTMusic.Lyrics) {
        title = l.title
        status = l.status
        source = l.source
        guard l.text != text || l.status != "ok" else { return }
        text = l.status == "ok" ? l.text : ""
        lines = text.components(separatedBy: "\n")
        translations = [:]
        // 가사 전체에서 원래 언어 알아내기
        let r = NLLanguageRecognizer()
        r.processString(text)
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
        if src.languageCode == tgt.languageCode && (target.hasPrefix("zh") == false) { config = nil; return }
        if config?.source == src && config?.target == tgt { config?.invalidate() }   // 같은 언어쌍이면 다시 번역
        else { config = TranslationSession.Configuration(source: src, target: tgt) }
    }

    /// 번역할 줄: 빈 줄 · 이미 번역 언어로 된 줄은 건너뜀
    func requests() -> [TranslationSession.Request] {
        let tgt = Locale.Language(identifier: target).languageCode?.identifier ?? target
        return lines.enumerated().compactMap { i, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let r = NLLanguageRecognizer()
            r.processString(t)
            if let d = r.dominantLanguage, d.rawValue.hasPrefix(tgt), t.count > 3 { return nil }
            return TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
        }
    }
}

struct LyricsView: View {
    @ObservedObject var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 위: 곡 제목 · 번역 언어
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title.isEmpty ? "가사" : model.title).font(.headline).lineLimit(1)
                    if !model.sourceLangName.isEmpty && model.status == "ok" {
                        Text("원문: \(model.sourceLangName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("번역", selection: $model.target) {
                    ForEach(lyricsLanguages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            switch model.status {
            case "ok":
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { i, line in
                            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                                Spacer().frame(height: 8)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                                    if let t = model.translations[i], t != line {
                                        Text(t).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if !model.source.isEmpty {
                            Text(model.source).font(.caption2).foregroundStyle(.tertiary).padding(.top, 12)
                        }
                        if !model.note.isEmpty {
                            Text(model.note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case "none":
                placeholder("이 곡은 가사가 없어요", "music.note")
            default:
                placeholder("가사 불러오는 중…", "ellipsis")
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

    private func placeholder(_ text: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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

    private func refresh() {
        guard isVisible, let music else { return }
        music.fetchLyrics { [weak self] l in self?.model.update(l) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
