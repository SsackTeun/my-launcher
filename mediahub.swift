// 재생기 사이 정책 (Windows 판과 같게)
// - 재생기: YouTube Music · YouTube · Netflix
// - 새로 재생을 시작한 재생기가 '지금 재생기'가 되고, 나머지 재생 중인 재생기는 일시정지
// - 스페이스(플레이어 창): 지금 재생기를 재생 / 멈춤
import Cocoa

@MainActor
final class MediaHub {
    static let shared = MediaHub()
    enum Source: String, CaseIterable { case music, youtube, netflix }

    weak var music: YTMusic?
    /// 지금 재생기 (마지막으로 재생을 시작한 것)
    private(set) var current: Source = .music
    private var playing: [Source: Bool] = [:]
    private var timer: Timer?
    /// 우리가 멈추게 한 직후엔 그 변화를 '새로 재생'으로 착각하지 않게
    private var quietUntil = Date.distantPast

    func start(music: YTMusic) {
        self.music = music
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func video(_ s: Source) -> VideoWindow? {
        switch s {
        case .youtube: return VideoWindow.shared.isOpen ? VideoWindow.shared : nil
        case .netflix: return VideoWindow.netflix.isOpen ? VideoWindow.netflix : nil
        case .music: return nil
        }
    }

    /// 지금 각 재생기가 재생 중인지 모아서
    private func states(_ done: @escaping ([Source: Bool]) -> Void) {
        var out: [Source: Bool] = [:]
        if music?.isActive == true, let p = music?.state?.playing { out[.music] = p }
        let vids = [Source.youtube, .netflix].filter { video($0) != nil }
        var left = vids.count
        guard left > 0 else { done(out); return }
        for s in vids {
            video(s)?.queryPlaying { p in
                if let p { out[s] = p }
                left -= 1
                if left == 0 { done(out) }
            }
        }
    }

    private func poll() {
        states { [weak self] now in
            guard let self else { return }
            let before = self.playing
            self.playing = now
            guard Date() > self.quietUntil else { return }
            // 멈춰 있다가 재생을 시작한 재생기 → 지금 재생기, 나머지는 일시정지
            if let started = Source.allCases.first(where: { now[$0] == true && before[$0] != true }) {
                self.current = started
                for s in Source.allCases where s != started && now[s] == true { self.set(s, false) }
            } else if now[self.current] != true, let other = Source.allCases.first(where: { now[$0] == true }) {
                self.current = other
            }
        }
    }

    private func set(_ s: Source, _ on: Bool) {
        quietUntil = Date().addingTimeInterval(1.5)
        playing[s] = on
        switch s {
        case .music:
            if music?.state?.playing != on { music?.press("playPause") }
        case .youtube, .netflix:
            video(s)?.setPlaying(on)
        }
    }

    /// 진단: 지금 상태를 파일로
    func debugDump() {
        states { [weak self] now in
            let out = "current=\(self?.current.rawValue ?? "")\nnow=\(now.map { "\($0.key.rawValue)=\($0.value)" }.sorted())\nytOpen=\(VideoWindow.shared.isOpen) nfOpen=\(VideoWindow.netflix.isOpen) musicActive=\(self?.music?.isActive == true)"
            try? out.write(toFile: NSHomeDirectory() + "/MyLauncher/ytm-analyze.txt", atomically: true, encoding: .utf8)
        }
    }

    /// 스페이스: 재생 중인 게 있으면 그걸 멈춤, 없으면 지금 재생기를 다시 재생
    func toggle() {
        states { [weak self] now in
            guard let self else { return }
            let on = Source.allCases.filter { now[$0] == true }
            if !on.isEmpty {
                if let c = on.first(where: { $0 == self.current }) ?? on.first { self.current = c }
                on.forEach { self.set($0, false) }
                return
            }
            // 지금 재생기가 닫혀 있으면 열려 있는 다른 재생기
            let open = Source.allCases.filter { now[$0] != nil }
            let target = open.contains(self.current) ? self.current : (open.first ?? .music)
            self.current = target
            self.set(target, true)
        }
    }
}
