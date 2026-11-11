// 앱별 메모리 사용량: 활동 모니터의 '메모리' 칸과 같은 값(phys_footprint)을
// 앱 본체 + 그 앱이 띄운 도우미 프로세스(Chrome 탭, WebKit 웹 콘텐츠 등)까지 합쳐서 셈
import Foundation
import Darwin

enum AppMemory {
    // macOS 가 "이 프로세스의 책임 앱" 을 알려 주는 함수 (공개 헤더는 없지만 시스템에 있음)
    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: RespFn.self)
    }()

    /// 프로세스 하나의 메모리 (바이트). 못 읽으면 nil (다른 사용자 · 시스템 프로세스)
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    private static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = buf.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(buf.prefix(Int(max(0, got)))).filter { $0 > 0 }
    }

    private static func parent(_ pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let r = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        return r > 0 ? pid_t(info.pbsi_ppid) : 0
    }

    /// 앱 pid → 합친 메모리. apps 에 있는 pid 만 결과에 들어감
    static func snapshot(apps: Set<pid_t>) -> [pid_t: UInt64] {
        guard !apps.isEmpty else { return [:] }
        var parents: [pid_t: pid_t] = [:]
        var sizes: [pid_t: UInt64] = [:]
        for pid in allPIDs() {
            guard let f = footprint(pid) else { continue }
            sizes[pid] = f
            parents[pid] = parent(pid)
        }
        var out: [pid_t: UInt64] = [:]
        for (pid, f) in sizes {
            // 1) 책임 앱이 목록에 있으면 그 앱으로 2) 아니면 부모를 타고 올라가며 찾음
            var owner: pid_t? = nil
            if let resp = responsible?(pid), apps.contains(resp) { owner = resp }
            if owner == nil {
                var p = pid, hops = 0
                while p > 1 && hops < 16 {
                    if apps.contains(p) { owner = p; break }
                    p = parents[p] ?? 0
                    hops += 1
                }
            }
            if let o = owner { out[o, default: 0] += f }
        }
        return out
    }

    // MARK: CPU

    /// rusage 의 CPU 시간 단위를 나노초로 (Apple 실리콘에서는 mach 틱으로 나옴)
    private static let timebase: (UInt64, UInt64) = {
        var i = mach_timebase_info_data_t()
        mach_timebase_info(&i)
        return (UInt64(max(1, i.numer)), UInt64(max(1, i.denom)))
    }()

    /// 프로세스 하나의 (메모리, 지금까지 쓴 CPU 시간 ns)
    private static func usageOf(_ pid: pid_t) -> (mem: UInt64, cpu: UInt64)? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return (info.ri_phys_footprint, ticks * timebase.0 / timebase.1)
    }

    /// 앱 pid → (메모리 합계, CPU 시간 합계 ns). 도우미 프로세스까지 합침
    static func usage(apps: Set<pid_t>) -> [pid_t: (mem: UInt64, cpu: UInt64)] {
        guard !apps.isEmpty else { return [:] }
        var out: [pid_t: (mem: UInt64, cpu: UInt64)] = [:]
        var parents: [pid_t: pid_t] = [:]
        var each: [pid_t: (mem: UInt64, cpu: UInt64)] = [:]
        for pid in allPIDs() {
            guard let u = usageOf(pid) else { continue }
            each[pid] = u
            parents[pid] = parent(pid)
        }
        for (pid, u) in each {
            var owner: pid_t? = nil
            if let resp = responsible?(pid), apps.contains(resp) { owner = resp }
            if owner == nil {
                var p = pid, hops = 0
                while p > 1 && hops < 16 {
                    if apps.contains(p) { owner = p; break }
                    p = parents[p] ?? 0
                    hops += 1
                }
            }
            if let o = owner {
                let cur = out[o] ?? (0, 0)
                out[o] = (cur.mem + u.mem, cur.cpu + u.cpu)
            }
        }
        return out
    }

    /// 잠깐(interval 초) 재서 앱 pid → (메모리, CPU %). 100% = 코어 하나를 꽉 씀 (활동 모니터와 같음)
    /// 기다리는 동안 멈추므로 메인 스레드 말고 뒤에서 부를 것
    static func sample(apps: Set<pid_t>, interval: Double = 0.5) -> [pid_t: (mem: UInt64, cpu: Double)] {
        let a = usage(apps: apps)
        let t0 = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: interval)
        let b = usage(apps: apps)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0)
        var out: [pid_t: (mem: UInt64, cpu: Double)] = [:]
        for (pid, u) in b {
            let before = a[pid]?.cpu ?? u.cpu
            let used = u.cpu >= before ? Double(u.cpu - before) : 0
            out[pid] = (u.mem, dt > 0 ? used / dt * 100 : 0)
        }
        return out
    }

    /// 12% · 0.4% · 130% 처럼 짧게
    static func cpuText(_ p: Double) -> String {
        p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    /// 1.2 GB · 340 MB 처럼 짧게
    static func text(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: mb >= 10240 ? "%.0f GB" : "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
