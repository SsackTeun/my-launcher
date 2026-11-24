// 도구함 자체 업데이트: GitHub Releases 에 새 버전(v1.2 같은 태그 · Launcher.zip)이 올라오면 알려 주고, 누르면 받아서 바꿔 끼운 뒤 다시 켬
// - 켤 때(20초 뒤)와 6시간마다 확인. Windows 판 릴리스(win-v…)는 건너뜀
// - 알림: 메뉴 막대 🧰 옆 점 · 🧰 빠른 막대의 ⬇︎ 칸 · 오른쪽 클릭 메뉴 맨 위
import Cocoa

@MainActor
final class SelfUpdate {
    static let shared = SelfUpdate()
    nonisolated static let repo = "SsackTeun/my-launcher"
    nonisolated static let asset = "Launcher.zip"

    struct Release { let version: String; let url: URL; let notes: String; let page: String }
    /// 새 버전 (지금보다 높을 때만)
    private(set) var available: Release?
    /// "받는 중…" 같은 진행 상태
    private(set) var status = ""
    var onChange: (() -> Void)?
    private var timer: Timer?

    var current: String { AppVersion.release }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 확인 (manual: 메뉴에서 직접 눌렀으면 결과를 알려 줌)
    func check(manual: Bool = false) {
        Task {
            let rel = await Self.newest()
            if let rel, DevApps.isNewer(rel.version, than: current) { available = rel } else { available = nil }
            onChange?()
            if manual {
                let al = NSAlert()
                if let a = available {
                    al.messageText = "새 버전 \(a.version) 이 있어요"
                    al.informativeText = "지금 \(current) · 업데이트하면 도구함이 다시 켜져요.\(a.notes.isEmpty ? "" : "\n\n\(a.notes.prefix(400))")"
                    al.addButton(withTitle: "업데이트")
                    al.addButton(withTitle: "나중에")
                    NSApp.activate(ignoringOtherApps: true)
                    if al.runModal() == .alertFirstButtonReturn { install() }
                } else {
                    al.messageText = rel == nil ? "새 버전을 확인하지 못했어요" : "최신 버전이에요 (\(current))"
                    al.informativeText = rel == nil ? "인터넷 연결을 확인해 주세요." : ""
                    NSApp.activate(ignoringOtherApps: true)
                    al.runModal()
                }
            }
        }
    }

    /// Mac 판 릴리스 중 가장 높은 버전 (태그 v1.2 · Launcher.zip 이 있는 것)
    nonisolated static func newest() async -> Release? {
        guard let (data, resp) = try? await URLSession.shared.data(for: DevApps.api("\(repo)/releases?per_page=30")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: Release?
        for r in arr {
            guard let tag = r["tag_name"] as? String, tag.hasPrefix("v"), r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
                  let assets = r["assets"] as? [[String: Any]],
                  let a = assets.first(where: { ($0["name"] as? String) == asset }),
                  let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
            let v = String(tag.dropFirst())
            if best == nil || DevApps.isNewer(v, than: best!.version) {
                best = Release(version: v, url: u, notes: r["body"] as? String ?? "", page: r["html_url"] as? String ?? "")
            }
        }
        return best
    }

    /// 받아서 지금 앱 자리에 바꿔 넣고 다시 켬
    func install() {
        guard let rel = available, status.isEmpty else { return }
        status = "받는 중…"; onChange?()
        Task {
            do {
                let (zip, _) = try await URLSession.shared.download(from: rel.url)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, work.path]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw DevApps.Failure("압축을 풀지 못했어요.") }
                guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                    throw DevApps.Failure("압축 안에 앱이 없어요.")
                }
                // 받은 게 정말 도구함인지 (번들 ID)
                guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw DevApps.Failure("받은 앱이 도구함이 아니에요.") }
                status = "바꾸는 중…"; onChange?()
                let dest = Bundle.main.bundleURL
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: newApp)
                try? FileManager.default.removeItem(at: work)
                // 끄고 1초 뒤 새 버전으로 켬
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                sh.arguments = ["-c", "sleep 1; open \"$0\"", dest.path]
                try sh.run()
                NSApp.terminate(nil)
            } catch {
                status = ""; onChange?()
                let al = NSAlert()
                al.messageText = "업데이트하지 못했어요"
                al.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                al.runModal()
            }
        }
    }
}
