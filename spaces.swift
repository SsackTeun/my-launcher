// 데스크탑(Space) 별로 실행 중인 앱 묶기
// macOS 가 공개하지 않는 SkyLight 기능으로 읽기만 함 (정리 앱들이 흔히 쓰는 방법, macOS 가 바뀌면 안 될 수 있음)
import Cocoa
import ApplicationServices

enum Spaces {
    struct Desk {
        let id: Int
        let label: String
        let current: Bool
        var pids: [pid_t]
    }

    private typealias MainConn = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ name: String, _ t: T.Type) -> T? {
        guard let sky, let p = dlsym(sky, name) else { return nil }
        return unsafeBitCast(p, to: t)
    }
    private static let mainConn = fn("SLSMainConnectionID", MainConn.self)
    private static let copyDisplays = fn("SLSCopyManagedDisplaySpaces", CopyDisplaySpaces.self)
    private static let copyForWindows = fn("SLSCopySpacesForWindows", CopySpacesForWindows.self)

    static var available: Bool { mainConn != nil && copyDisplays != nil && copyForWindows != nil }

    /// 모니터 UUID → 짧은 이름 (맥북 · 외부 모니터 이름)
    private static func displayNames() -> [String: String] {
        var out: [String: String] = [:]
        for s in NSScreen.screens {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue(),
                  let str = CFUUIDCreateString(nil, u) as String? else { continue }
            let n = s.localizedName
            out[str.uppercased()] = n.localizedCaseInsensitiveContains("Built-in") || n.contains("내장") ? "맥북" : n
        }
        return out
    }

    /// 데스크탑 목록과 각 데스크탑에 창이 있는 앱(pid)
    static func load() -> [Desk] {
        guard let mainConn, let copyDisplays, let copyForWindows else { return [] }
        let cid = mainConn()
        guard let displays = copyDisplays(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let names = displayNames()
        let multi = displays.count > 1

        // 1) 데스크탑 순서 (Mission Control 순서, 모니터마다 1부터)
        var desks: [Desk] = []
        var index: [Int: Int] = [:]
        var fullscreen: [Int] = []
        for disp in displays {
            let uuid = (disp["Display Identifier"] as? String ?? "").uppercased()
            let dname = names[uuid] ?? (names.count == 1 ? names.values.first : nil) ?? "모니터"
            let cur = (disp["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            var n = 0
            for sp in disp["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = sp["ManagedSpaceID"] as? Int else { continue }
                let type = sp["type"] as? Int ?? 0
                let label: String
                if type == 4 {
                    label = "전체 화면"
                    fullscreen.append(desks.count)
                } else {
                    n += 1
                    label = multi ? "데스크탑 \(n) · \(dname)" : "데스크탑 \(n)"
                }
                index[id] = desks.count
                desks.append(Desk(id: id, label: label + (id == cur ? " (지금)" : ""), current: id == cur, pids: []))
            }
        }

        // 2) 창마다 어느 데스크탑에 있는지 → 앱을 그 데스크탑에
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let wins = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var fsOwner: [Int: String] = [:]
        for w in wins {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, regular.contains(pid),
                  let wid = w[kCGWindowNumber as String] as? Int else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
            if let b = w[kCGWindowBounds as String] as? [String: Any],
               (b["Width"] as? Double ?? 0) < 60 || (b["Height"] as? Double ?? 0) < 40 { continue }
            let sps = copyForWindows(cid, 7, [wid] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            for sp in sps {
                guard let k = index[sp] else { continue }
                if !desks[k].pids.contains(pid) { desks[k].pids.append(pid) }
                if fsOwner[k] == nil { fsOwner[k] = w[kCGWindowOwnerName as String] as? String }
            }
        }
        // 전체 화면 데스크탑은 그 앱 이름으로
        for k in fullscreen {
            let d = desks[k]
            desks[k] = Desk(id: d.id, label: "전체 화면 · \(fsOwner[k] ?? "앱")" + (d.current ? " (지금)" : ""), current: d.current, pids: d.pids)
        }
        return desks
    }
}
