// 개발자 앱: my-launcher 저장소의 apps.json 에 적힌 앱들을 GitHub Releases 에서 받아 설치 · 업데이트
import Cocoa

struct DevApp: Codable {
    let name: String
    let bundleId: String
    let repo: String          // "SsackTeun/excel-ruler"
    let asset: String         // Releases 에 올린 zip 이름
    let app: String           // zip 안의 .app 이름
    let summary: String?
}

@MainActor
final class DevApps {
    static let catalogURL = URL(string: "https://raw.githubusercontent.com/SsackTeun/my-launcher/main/apps.json")!

    private(set) var apps: [DevApp] = []
    /// 번들 ID → Releases 최신 버전
    private(set) var latest: [String: String] = [:]
    /// 번들 ID → "받는 중…" 같은 진행 상태
    private(set) var status: [String: String] = [:]
    var onChange: (() -> Void)?
    private var loadedAt = Date.distantPast

    init() {
        // 지난번에 받아 둔 목록부터 (인터넷이 안 될 때도 보이게)
        if let data = UserDefaults.standard.data(forKey: "devAppsCatalog"),
           let list = try? JSONDecoder().decode([DevApp].self, from: data) { apps = list }
        latest = UserDefaults.standard.dictionary(forKey: "devAppsLatest") as? [String: String] ?? [:]
    }

    var ids: [String] { apps.map(\.bundleId) }
    func app(_ id: String) -> DevApp? { apps.first { $0.bundleId == id } }

    // MARK: 목록 · 최신 버전 불러오기

    /// 너무 자주 묻지 않도록 10분에 한 번 (force 면 바로)
    func load(force: Bool = false) {
        guard force || Date().timeIntervalSince(loadedAt) > 600 else { return }
        loadedAt = Date()
        Task {
            var req = URLRequest(url: Self.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData)
            req.timeoutInterval = 10
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let list = try? JSONDecoder().decode([DevApp].self, from: data) {
                apps = list
                UserDefaults.standard.set(data, forKey: "devAppsCatalog")
                onChange?()
            }
            for a in apps {
                if let v = await Self.latestVersion(repo: a.repo) { latest[a.bundleId] = v }
            }
            UserDefaults.standard.set(latest, forKey: "devAppsLatest")
            onChange?()
        }
    }

    nonisolated static func api(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MyLauncher/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        return req
    }

    nonisolated static func latestRelease(repo: String) async -> [String: Any]? {
        guard let (data, resp) = try? await URLSession.shared.data(for: api("\(repo)/releases/latest")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o
    }

    nonisolated static func latestVersion(repo: String) async -> String? {
        guard let tag = await latestRelease(repo: repo)?["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: 설치 상태

    func installedURL(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    func installedVersion(_ id: String) -> String? {
        guard let u = installedURL(id) else { return nil }
        return Bundle(url: u)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// "1.10" > "1.9" 처럼 숫자로 비교
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func hasUpdate(_ id: String) -> Bool {
        guard let have = installedVersion(id), let new = latest[id] else { return false }
        return Self.isNewer(new, than: have)
    }

    /// 칸 위에 붙일 표시: 받기 · 업데이트 · 받는 중…
    func badge(_ id: String) -> String? {
        if let s = status[id] { return s }
        if installedURL(id) == nil { return "받기" }
        if hasUpdate(id) { return "업데이트" }
        return nil
    }

    var updateCount: Int { ids.filter { hasUpdate($0) }.count }

    // MARK: 받기 · 설치

    func install(_ id: String) {
        guard let a = app(id), status[id] == nil else { return }
        status[id] = "받는 중…"
        onChange?()
        Task {
            do {
                try await doInstall(a)
                status[id] = nil
                onChange?()
            } catch {
                status[id] = nil
                onChange?()
                let al = NSAlert()
                al.messageText = "\(a.name) 을(를) 받지 못했어요"
                al.informativeText = error.localizedDescription
                al.runModal()
            }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func doInstall(_ a: DevApp) async throws {
        // 1) 최신 릴리스에서 zip 주소 찾기
        guard let rel = await Self.latestRelease(repo: a.repo),
              let assets = rel["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == a.asset }),
              let dl = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure("GitHub Releases 에서 \(a.asset) 을 찾지 못했어요.")
        }
        if let tag = rel["tag_name"] as? String { latest[a.bundleId] = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

        // 2) 내려받아서 임시 폴더에 풀기
        let (zip, _) = try await URLSession.shared.download(from: dl)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("devapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, work.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("압축을 풀지 못했어요.") }
        let newApp = work.appendingPathComponent(a.app)
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw Failure("압축 안에 \(a.app) 이 없어요.") }

        // 3) 설치 위치: 이미 깔려 있으면 그 자리, 아니면 ~/Applications
        let userApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        try? FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
        var dest = userApps.appendingPathComponent(a.app)
        if let old = installedURL(a.bundleId), FileManager.default.isWritableFile(atPath: old.deletingLastPathComponent().path) { dest = old }

        let isSelf = a.bundleId == Bundle.main.bundleIdentifier
        // 실행 중이면 먼저 끔 (도구함 자신은 바꾼 뒤 다시 켬)
        if !isSelf {
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleId) {
                r.terminate()
                for _ in 0..<30 where !r.isTerminated { try await Task.sleep(nanoseconds: 100_000_000) }
                if !r.isTerminated { r.forceTerminate() }
            }
        }

        // 4) 바꿔 넣기
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: newApp)
        } else {
            try FileManager.default.moveItem(at: newApp, to: dest)
        }

        // 5) 실행 (도구함 자신이면 다시 시작)
        if isSelf {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", "sleep 1; open \"\(dest.path)\""]
            try? sh.run()
            NSApp.terminate(nil)
        } else {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: dest, configuration: cfg)
        }
    }

    func openRepo(_ id: String) {
        guard let a = app(id), let u = URL(string: "https://github.com/\(a.repo)") else { return }
        NSWorkspace.shared.open(u)
    }
}
