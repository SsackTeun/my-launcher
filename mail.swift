// 메일 (IMAP 읽기 · 읽음 표시, SMTP 답장 보내기)
// 처음 지원: 네이버 웍스 메일 (imap.worksmobile.com:993 · smtp.worksmobile.com:465). 다른 서버도 주소만 바꾸면 됨
// 비밀번호는 맥 키체인에만 저장하고, 메일 내용은 이 맥 밖으로 보내지 않음
import Cocoa
import Network
import Security

// MARK: - 계정 설정

struct MailAccount: Equatable {
    var host: String
    var port: Int
    var user: String
    /// 웹에서 메일 열 주소 (메일을 누르면 여기로)
    var webURL: String
    /// 보내는 서버 (SSL)
    var smtpHost = "smtp.worksmobile.com"
    var smtpPort = 465

    static let naverWorks = MailAccount(host: "imap.worksmobile.com", port: 993, user: "", webURL: "https://mail.worksmobile.com/")
    /// 메일을 열면 읽음으로 표시 (기본 켬)
    static var markReadOnOpen: Bool {
        get { UserDefaults.standard.object(forKey: "mailMarkRead") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mailMarkRead") }
    }

    private static var d: UserDefaults { .standard }
    /// 저장된 계정 (메일 주소가 비어 있으면 없음)
    static var saved: MailAccount? {
        get {
            guard let u = d.string(forKey: "mailUser"), !u.isEmpty else { return nil }
            var a = MailAccount(host: d.string(forKey: "mailHost") ?? naverWorks.host,
                                port: (d.object(forKey: "mailPort") as? Int) ?? naverWorks.port,
                                user: u,
                                webURL: d.string(forKey: "mailWeb") ?? naverWorks.webURL)
            if let h = d.string(forKey: "mailSmtpHost"), !h.isEmpty { a.smtpHost = h }
            if let p = d.object(forKey: "mailSmtpPort") as? Int { a.smtpPort = p }
            return a
        }
        set {
            if let a = newValue {
                d.set(a.host, forKey: "mailHost"); d.set(a.port, forKey: "mailPort")
                d.set(a.user, forKey: "mailUser"); d.set(a.webURL, forKey: "mailWeb")
                d.set(a.smtpHost, forKey: "mailSmtpHost"); d.set(a.smtpPort, forKey: "mailSmtpPort")
            } else {
                for k in ["mailHost", "mailPort", "mailUser", "mailWeb", "mailSmtpHost", "mailSmtpPort"] { d.removeObject(forKey: k) }
            }
        }
    }
}

/// 비밀번호는 키체인에 (도구함 · 메일 주소별로 하나)
enum MailKeychain {
    private static let service = "local.jaeyeong.launcher.mail"
    private static func query(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
    }
    static func save(_ password: String, for user: String) -> Bool {
        SecItemDelete(query(user) as CFDictionary)
        var q = query(user)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func load(_ user: String) -> String? {
        var q = query(user)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ user: String) { SecItemDelete(query(user) as CFDictionary) }
}

// MARK: - IMAP

struct MailItem: Equatable, Identifiable {
    let uid: Int
    let from: String
    let subject: String
    let date: Date?
    var seen = false
    /// 보낸 사람 주소까지 (메일 창 머리글용)
    var fromFull = ""
    var id: Int { uid }
}

enum MailError: LocalizedError {
    case connect(String), login(String), server(String), timeout
    var errorDescription: String? {
        switch self {
        case .connect(let s): return "서버에 연결하지 못했어요 (\(s))"
        case .login(let s): return "로그인하지 못했어요 — 메일 주소 · 비밀번호, IMAP 사용 설정을 확인해 주세요 (\(s))"
        case .server(let s): return "서버가 거절했어요 (\(s))"
        case .timeout: return "서버 응답이 없어요 (시간 초과)"
        }
    }
}

/// 아주 작은 IMAP 대화 상대: 한 번 연결해서 몇 가지 묻고 끊음
final class IMAPSession: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "launcher.imap")
    private var buffer = [UInt8]()
    private var waiter: (([UInt8]?) -> Bool)?    // 버퍼를 보고 다 왔으면 true
    private var tag = 0
    private var closed = false

    /// 서버 인사 첫머리 (IMAP "* OK", SMTP "220")
    private let greet: String
    init(host: String, port: Int, greet: String = "* OK") {
        self.greet = greet
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: params)
    }

    /// 연결하고 서버 인사(* OK)까지
    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            final class Flag: @unchecked Sendable { var done = false }
            let f = Flag()    // 모두 같은 줄(queue)에서만 만짐
            conn.stateUpdateHandler = { [weak self] st in
                guard let self, !f.done else { return }
                switch st {
                case .ready:
                    f.done = true
                    self.receive()
                    c.resume()
                case .failed(let e), .waiting(let e):
                    f.done = true
                    c.resume(throwing: MailError.connect(e.localizedDescription))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { if !f.done { f.done = true; c.resume(throwing: MailError.timeout) } }
        }
        let hello = try await waitFor { buf in IMAPParse.lineEnd(buf, from: 0) != nil }
        guard String(decoding: hello, as: UTF8.self).hasPrefix(greet) else { throw MailError.connect("인사가 이상해요") }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(contentsOf: data) }
            if isComplete || error != nil { self.closed = true }
            self.check()
            if !self.closed { self.receive() }
        }
    }

    private func check() {
        if let w = waiter, w(closed && buffer.isEmpty ? nil : buffer) { waiter = nil }
    }

    /// 조건이 맞을 때까지 버퍼를 기다렸다가 통째로 꺼냄
    private func waitFor(_ ready: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            queue.async {
                var finished = false
                let w: ([UInt8]?) -> Bool = { [weak self] buf in
                    guard let self, !finished else { return true }
                    guard let buf else { finished = true; c.resume(throwing: MailError.connect("연결이 끊겼어요")); return true }
                    guard ready(buf) else { return false }
                    finished = true
                    let out = self.buffer
                    self.buffer = []
                    c.resume(returning: out)
                    return true
                }
                self.waiter = w
                self.check()
                self.queue.asyncAfter(deadline: .now() + 20) {
                    if !finished { finished = true; self.waiter = nil; c.resume(throwing: MailError.timeout) }
                }
            }
        }
    }

    /// 명령 하나 보내고 끝(태그 OK/NO/BAD)까지 받은 응답 바이트
    @discardableResult
    func command(_ cmd: String, hideInErrors: Bool = false) async throws -> [UInt8] {
        tag += 1
        let t = "A\(tag)"
        let line = "\(t) \(cmd)\r\n"
        conn.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
        let resp = try await waitFor { buf in IMAPParse.taggedLine(buf, tag: t) != nil }
        let status = IMAPParse.taggedLine(resp, tag: t) ?? ""
        guard status.hasPrefix("OK") else {
            let shown = hideInErrors ? String(status.prefix(80)) : status
            throw cmd.hasPrefix("LOGIN") ? MailError.login(shown) : MailError.server(shown)
        }
        return resp
    }

    func close() {
        conn.send(content: Data("Z LOGOUT\r\n".utf8), completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    // MARK: SMTP (같은 연결 방식으로)

    /// 한 줄 보내고 (nil 이면 안 보내고) 응답 코드가 expect 인지 확인. "250-..." 여러 줄은 마지막 "250 " 까지
    @discardableResult
    func smtp(_ line: String?, expect: Int, hide: Bool = false) async throws -> String {
        if let line { conn.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in }) }
        let resp = try await waitFor { buf in IMAPParse.smtpDone(buf) }
        let text = String(decoding: resp, as: UTF8.self)
        let last = text.components(separatedBy: "\r\n").last { $0.count >= 4 } ?? ""
        guard Int(last.prefix(3)) == expect else {
            let shown = hide ? String(last.prefix(80)) : last
            throw (line?.hasPrefix("AUTH") ?? false) ? MailError.login(shown) : MailError.server(shown)
        }
        return text
    }

    func quit() {
        conn.send(content: Data("QUIT\r\n".utf8), completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}

/// IMAP 응답 읽기 (바이트 그대로 — 중간에 {길이} 로 붙어 오는 덩어리가 있어서)
enum IMAPParse {
    /// from 부터 줄 끝(\r\n) 위치
    static func lineEnd(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 13 && b[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// 응답을 줄 단위로 나누되, {n} 덩어리는 줄 안에 같이 붙여 둠: (줄 글자, 그 줄에 딸린 덩어리들)
    static func lines(_ b: [UInt8]) -> [(text: String, literals: [[UInt8]])] {
        var out: [(String, [[UInt8]])] = []
        var i = 0
        var text = [UInt8](), lits: [[UInt8]] = []
        while i < b.count {
            guard let e = lineEnd(b, from: i) else { break }
            let seg = Array(b[i..<e])
            text += seg
            // 줄 끝이 {n} 이면 그 다음 n 바이트는 덩어리
            if let n = literalSize(seg), e + 2 + n <= b.count {
                lits.append(Array(b[(e + 2)..<(e + 2 + n)]))
                i = e + 2 + n
                continue
            }
            out.append((String(decoding: text, as: UTF8.self), lits))
            text = []; lits = []
            i = e + 2
        }
        return out
    }

    static func literalSize(_ seg: [UInt8]) -> Int? {
        guard seg.last == UInt8(ascii: "}"), let open = seg.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        return Int(String(decoding: seg[(open + 1)..<(seg.count - 1)], as: UTF8.self))
    }

    /// 태그 붙은 마지막 줄 ("A3 OK ..." → "OK ...")
    static func taggedLine(_ b: [UInt8], tag: String) -> String? {
        for l in lines(b).reversed() where l.text.hasPrefix(tag + " ") {
            return String(l.text.dropFirst(tag.count + 1))
        }
        return nil
    }

    /// SMTP 응답이 다 왔는지: 마지막 완성된 줄이 "250 ..." 꼴 (네 번째 글자가 공백)
    static func smtpDone(_ b: [UInt8]) -> Bool {
        guard b.count >= 2, b[b.count - 2] == 13, b[b.count - 1] == 10 else { return false }
        let lines = String(decoding: b, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let l = lines.last, l.count >= 4 else { return false }
        let a = Array(l.utf8)
        return a[0...2].allSatisfy { (48...57).contains($0) } && a[3] == 32
    }

    /// "* SEARCH 3 8 12" → [3, 8, 12]
    static func searchUIDs(_ b: [UInt8]) -> [Int] {
        lines(b).flatMap { l -> [Int] in
            guard l.text.hasPrefix("* SEARCH") else { return [] }
            return l.text.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }
    }

    /// FETCH 응답 → 메일들 (UID 와 머리글 덩어리)
    static func items(_ b: [UInt8]) -> [MailItem] {
        lines(b).compactMap { l in
            guard l.text.hasPrefix("* "), l.text.contains("FETCH"), let head = l.literals.first,
                  let r = l.text.range(of: #"UID (\d+)"#, options: .regularExpression) else { return nil }
            let uid = Int(l.text[r].dropFirst(4)) ?? 0
            let h = headers(head)
            let seen = l.text.range(of: #"FLAGS \([^)]*\\Seen"#, options: .regularExpression) != nil
            let subj = (h["subject"] ?? "").trimmingCharacters(in: .whitespaces)
            return MailItem(uid: uid, from: displayName(h["from"] ?? ""), subject: subj.isEmpty ? "(제목 없음)" : subj,
                            date: date(h["date"] ?? ""), seen: seen, fromFull: h["from"] ?? "")
        }
    }

    /// 머리글 덩어리 → 이름별 값 (접힌 줄 펴고, =?..?= 풀고)
    static func headers(_ raw: [UInt8]) -> [String: String] {
        let s = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var out: [String: String] = [:]
        var key: String?
        for line in s.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", let k = key {
                out[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                let k = line[..<c].lowercased()
                key = k
                out[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return out.mapValues(decodeWords)
    }

    /// =?UTF-8?B?...?= / =?EUC-KR?Q?...?= 풀기 (이어진 조각 사이 공백은 지움)
    static func decodeWords(_ s: String) -> String {
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        var prevWasWord = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1)).lowercased()
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            var bytes: Data?
            if mode == "B" {
                var t = text
                while t.count % 4 != 0 { t += "=" }
                bytes = Data(base64Encoded: t)
            } else {
                var d = Data()
                var i = text.startIndex
                while i < text.endIndex {
                    let ch = text[i]
                    if ch == "_" { d.append(0x20); i = text.index(after: i) }
                    else if ch == "=", let j = text.index(i, offsetBy: 3, limitedBy: text.endIndex), let v = UInt8(text[text.index(after: i)..<j], radix: 16) {
                        d.append(v); i = j
                    } else { d.append(contentsOf: Array(String(ch).utf8)); i = text.index(after: i) }
                }
                bytes = d
            }
            if let bytes { out += decode(bytes, charset: charset) } else { out += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
            prevWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    static func decode(_ d: Data, charset: String) -> String {
        let name = ["ks_c_5601-1987": "euc-kr", "ks_c_5601": "euc-kr"][charset] ?? charset
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf != kCFStringEncodingInvalidId, let s = String(data: d, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    /// "홍길동 <a@b.com>" → 홍길동, 이름이 없으면 주소
    static func displayName(_ from: String) -> String {
        let f = from.trimmingCharacters(in: .whitespaces)
        if let lt = f.firstIndex(of: "<") {
            let name = f[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            return String(f[f.index(after: lt)...]).trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return f
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let clean = s.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: clean) { return d }
        }
        return nil
    }

    /// IMAP 따옴표 글자 ("와 \ 앞에 \)
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - 주기적으로 확인

@MainActor
final class MailWatch {
    static let shared = MailWatch()
    private(set) var unread: [MailItem] = []
    private(set) var unreadCount = 0
    private(set) var lastError: String?
    private(set) var lastCheck: Date?
    private(set) var checking = false
    private var fetchedOnce = false
    var onChange: () -> Void = {}
    private var timer: Timer?
    /// 확인 간격 (초)
    static let interval: TimeInterval = 120

    var configured: Bool { MailAccount.saved != nil }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { MailWatch.shared.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 지금 확인 (끝나면 onChange)
    func check(done: ((String?) -> Void)? = nil) {
        guard let acc = MailAccount.saved, let pw = MailKeychain.load(acc.user) else {
            unread = []; unreadCount = 0; lastError = nil; fetchedOnce = false; maxUID = 0
            onChange(); done?("계정이 없어요"); return
        }
        guard !checking else { done?(nil); return }
        checking = true
        Task {
            let result: Result<(Int, [MailItem]), Error>
            do { result = .success(try await Self.fetch(acc, password: pw)) } catch { result = .failure(error) }
            await MainActor.run {
                self.checking = false
                self.lastCheck = Date()
                switch result {
                case .success(let (n, items)):
                    // 처음 확인한 뒤로 새로 들어온 메일이 있으면 반짝
                    // 지난번에 본 가장 큰 메일 번호보다 큰 = 새로 온 메일 (처음 확인 때는 알리지 않음)
                    let newOnes = self.fetchedOnce ? items.filter { $0.uid > self.maxUID } : []
                    let fresh = !newOnes.isEmpty
                    self.maxUID = max(self.maxUID, items.map(\.uid).max() ?? 0)
                    self.fetchedOnce = true
                    self.unreadCount = n
                    self.unread = items
                    self.lastError = nil
                    if fresh { self.onNew?(); self.onNewItems?(newOnes) }
                    done?(nil)
                case .failure(let e):
                    self.lastError = e.localizedDescription
                    done?(e.localizedDescription)
                }
                self.onChange()
            }
        }
    }
    /// 새 메일이 왔을 때 (배지 반짝임 등)
    var onNew: (() -> Void)?
    /// 새로 온 메일들 (토스트 알림용)
    var onNewItems: (([MailItem]) -> Void)?
    private var maxUID = 0
    /// 새 메일 오면 토스트 (기본 켬)
    static var toast: Bool {
        get { UserDefaults.standard.object(forKey: "mailToast") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mailToast") }
    }

    /// 한 번 연결해서: 로그인 → 받은 편지함 읽기 전용으로 열기 → 안 읽은 메일 찾기 → 최근 것 머리글만
    nonisolated static func fetch(_ a: MailAccount, password: String, limit: Int = 10) async throws -> (Int, [MailItem]) {
        let s = IMAPSession(host: a.host, port: a.port)
        try await s.open()
        defer { s.close() }
        try await s.command("LOGIN \(IMAPParse.quote(a.user)) \(IMAPParse.quote(password))", hideInErrors: true)
        try await s.command("EXAMINE INBOX")          // 읽기 전용: 메일을 열어도 읽음 표시가 안 생김
        let uids = IMAPParse.searchUIDs(try await s.command("UID SEARCH UNSEEN"))
        guard !uids.isEmpty else { return (0, []) }
        let recent = uids.sorted().suffix(limit)
        let set = recent.map(String.init).joined(separator: ",")
        let resp = try await s.command("UID FETCH \(set) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        let items = IMAPParse.items(resp).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (uids.count, items)
    }

    /// 받은 편지함 첫 쪽: 전체 메일 번호(최신순)와 그중 앞 limit 통 (읽은 것 포함)
    nonisolated static func fetchList(_ a: MailAccount, password: String, limit: Int = 50) async throws -> (items: [MailItem], uids: [Int]) {
        let s = try await login(a, password: password)
        defer { s.close() }
        try await s.command("EXAMINE INBOX")
        let uids = IMAPParse.searchUIDs(try await s.command("UID SEARCH ALL")).sorted(by: >)
        let items = try await headers(s, Array(uids.prefix(limit)))
        return (items, uids)
    }

    /// 다음 쪽: 고른 메일 번호들의 머리글만
    nonisolated static func fetchPage(_ a: MailAccount, password: String, uids: [Int]) async throws -> [MailItem] {
        guard !uids.isEmpty else { return [] }
        let s = try await login(a, password: password)
        defer { s.close() }
        try await s.command("EXAMINE INBOX")
        return try await headers(s, uids)
    }

    private nonisolated static func headers(_ s: IMAPSession, _ uids: [Int]) async throws -> [MailItem] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let resp = try await s.command("UID FETCH \(set) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        // 서버가 주는 순서와 상관없이 메일 번호 큰 것(최신) 먼저
        return IMAPParse.items(resp).sorted { $0.uid > $1.uid }
    }

    /// markSeen 이면 읽음 표시도
    nonisolated static func fetchRaw(_ a: MailAccount, password: String, uid: Int, markSeen: Bool = false) async throws -> [UInt8] {
        let s = try await login(a, password: password)
        defer { s.close() }
        try await s.command(markSeen ? "SELECT INBOX" : "EXAMINE INBOX")
        let resp = try await s.command("UID FETCH \(uid) (UID BODY.PEEK[])")
        if markSeen { try await s.command("UID STORE \(uid) +FLAGS.SILENT (\\Seen)") }
        return IMAPParse.lines(resp).first { $0.text.hasPrefix("* ") && $0.text.contains("FETCH") }?.literals.first ?? []
    }

    /// 받은 편지함 모두 읽음
    nonisolated static func markAllRead(_ a: MailAccount, password: String) async throws {
        let s = try await login(a, password: password)
        defer { s.close() }
        try await s.command("SELECT INBOX")
        let uids = IMAPParse.searchUIDs(try await s.command("UID SEARCH UNSEEN"))
        guard !uids.isEmpty else { return }
        // 한 번에 너무 길지 않게 500개씩
        for chunk in stride(from: 0, to: uids.count, by: 500).map({ Array(uids[$0..<min($0 + 500, uids.count)]) }) {
            try await s.command("UID STORE \(chunk.map(String.init).joined(separator: ",")) +FLAGS.SILENT (\\Seen)")
        }
    }

    /// 모두 읽음 (확인 창을 띄우고, 끝나면 배지 · 메일 창 새로)
    func confirmMarkAllRead() {
        guard let a = MailAccount.saved, let pw = MailKeychain.load(a.user) else { return }
        let n = unreadCount
        let al = NSAlert()
        al.messageText = "받은 편지함 메일을 모두 읽음으로 할까요?"
        al.informativeText = n > 0 ? "안 읽은 메일 \(n)개가 읽음으로 바뀌어요. 나중에 메일마다 다시 '안 읽음'으로 바꿀 수 있어요." : "안 읽은 메일이 없어요."
        al.addButton(withTitle: "모두 읽음")
        al.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard n > 0, al.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await Self.markAllRead(a, password: pw)
                self.check()
                MailWindow.shared.refreshIfOpen()
            } catch {
                self.lastError = "모두 읽음 처리를 못 했어요: " + error.localizedDescription
                self.onChange()
            }
        }
    }

    /// 읽음 / 안 읽음 바꾸기
    nonisolated static func setSeen(_ a: MailAccount, password: String, uid: Int, seen: Bool) async throws {
        let s = try await login(a, password: password)
        defer { s.close() }
        try await s.command("SELECT INBOX")
        try await s.command("UID STORE \(uid) \(seen ? "+" : "-")FLAGS.SILENT (\\Seen)")
    }

    nonisolated static func login(_ a: MailAccount, password: String) async throws -> IMAPSession {
        let s = IMAPSession(host: a.host, port: a.port)
        try await s.open()
        do { try await s.command("LOGIN \(IMAPParse.quote(a.user)) \(IMAPParse.quote(password))", hideInErrors: true) }
        catch { s.close(); throw error }
        return s
    }

    /// 메일 보내기 (SMTP) → 보낸 편지함에도 넣기 (IMAP APPEND). 보낸 편지함에 못 넣어도 보내기는 성공으로
    nonisolated static func send(_ a: MailAccount, password: String, rcpts: [String], message: String) async throws {
        let s = IMAPSession(host: a.smtpHost, port: a.smtpPort, greet: "220")
        try await s.open()
        defer { s.quit() }
        try await s.smtp("EHLO launcher.local", expect: 250)
        let auth = Data("\u{0}\(a.user)\u{0}\(password)".utf8).base64EncodedString()
        try await s.smtp("AUTH PLAIN \(auth)", expect: 235, hide: true)
        try await s.smtp("MAIL FROM:<\(a.user)>", expect: 250)
        for r in rcpts { try await s.smtp("RCPT TO:<\(r)>", expect: 250) }
        try await s.smtp("DATA", expect: 354)
        // 점으로 시작하는 줄은 점을 하나 더 (SMTP 규칙)
        let body = message.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        try await s.smtp(body + "\r\n.", expect: 250)
        try? await appendSent(a, password: password, message: message)
    }

    /// 보낸 편지함(\Sent 표시가 붙은 곳, 없으면 이름으로) 에 넣기
    nonisolated static func appendSent(_ a: MailAccount, password: String, message: String) async throws {
        let s = try await login(a, password: password)
        defer { s.close() }
        let list = IMAPParse.lines(try await s.command("LIST \"\" \"*\"")).map(\.text)
        func name(_ l: String) -> String? {
            // * LIST (\HasNoChildren \Sent) "/" "Sent Messages"
            guard let r = l.range(of: #"\) (?:"[^"]*"|NIL) "#, options: .regularExpression) else { return nil }
            return String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        let sent = list.first { $0.contains("\\Sent") }.flatMap(name)
            ?? list.compactMap(name).first { ["sent", "sent messages", "sent items", "보낸메일함", "보낸 편지함"].contains($0.lowercased()) }
        guard let box = sent else { return }
        let n = message.utf8.count
        try await s.command("APPEND \(IMAPParse.quote(box)) (\\Seen) {\(n)+}\r\n" + message)
    }

    /// 웹 메일 열기
    func openWeb() {
        if let s = MailAccount.saved?.webURL, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - 위쪽 줄 ✉︎ 단추 (안 읽은 수 배지)

final class MailButton: NSButton {
    var count = 0 { didSet { if count != oldValue { refreshLook() } } }
    var failed = false { didSet { if failed != oldValue { refreshLook() } } }
    var onClick: ((MailButton) -> Void)?
    var onRightClick: ((MailButton) -> Void)?
    override func rightMouseDown(with event: NSEvent) { onRightClick?(self) }
    override func mouseEntered(with event: NSEvent) { updateTip(); super.mouseEntered(with: event) }
    /// 숫자 배지 (아이콘 오른쪽 위 모서리에 걸치게, 단추 밖으로 조금 나가도 보이게)
    private let badge = BadgeView()

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        clipsToBounds = false
        target = self
        action = #selector(tap)
        addSubview(badge)
        refreshLook()
    }
    @objc private func tap() { onClick?(self) }

    private func refreshLook() {
        // 안 읽은 메일이 있으면 채운 봉투를 파란 강조색으로, 없으면 흐린 빈 봉투
        image = NSImage(systemSymbolName: count > 0 ? "envelope.fill" : "envelope", accessibilityDescription: "메일")
        symbolConfiguration = .init(pointSize: 13, weight: .medium)
        contentTintColor = failed ? .systemOrange : count > 0 ? .launcherAccent : .secondaryLabelColor
        badge.text = failed ? "!" : count > 0 ? (count > 999 ? "999+" : "\(count)") : ""
        badge.color = failed ? .systemOrange : .systemBlue
        badge.isHidden = badge.text.isEmpty
        let w = badge.fit()
        // 단추는 위아래가 뒤집힌 좌표일 수 있어서 둘 다 오른쪽 위로
        badge.frame = NSRect(x: bounds.maxX - min(w, 18) + 4, y: isFlipped ? -4 : bounds.maxY - 8, width: w, height: 12)
        updateTip()
    }
    override func layout() { super.layout(); refreshLook() }

    private func updateTip() {
        toolTip = !MainActor.assumeIsolated({ MailWatch.shared.configured }) ? "메일 연결하기 (네이버 웍스 메일)"
            : failed ? "메일 확인이 안 돼요 — 눌러서 자세히" : count > 0 ? "안 읽은 메일 \(count)개 · 오른쪽 클릭: 모두 읽음 등" : "안 읽은 메일 없음"
    }

    /// 새 메일이 오면 잠깐 반짝
    func pulse() {
        wantsLayer = true
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1.0; a.toValue = 1.25; a.duration = 0.18; a.autoreverses = true; a.repeatCount = 2
        layer?.add(a, forKey: "pulse")
    }
}

/// 작은 알약 모양 숫자
final class BadgeView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    private var attrs: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white] }
    func fit() -> CGFloat { max(12, ceil((text as NSString).size(withAttributes: attrs).width) + 6) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }    // 누르면 단추가 받게
    override func draw(_ r: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}

// MARK: - 새 메일 토스트 (화면 오른쪽 위, 누르면 그 메일 열기)

@MainActor
final class MailToast {
    static let shared = MailToast()
    private var panels: [NSPanel] = []
    /// 누르면 (메일 번호)
    var onOpen: ((Int) -> Void)?
    static let width: CGFloat = 320, height: CGFloat = 68, gap: CGFloat = 8

    /// 여러 통이면 최근 3통까지 각각, 그 이상은 "외 n통" 한 장 더
    func show(_ items: [MailItem]) {
        let list = items.sorted { $0.uid > $1.uid }
        for it in list.prefix(3) { add(title: it.from, body: it.subject, uid: it.uid) }
        if list.count > 3 { add(title: "새 메일 \(list.count - 3)통 더", body: "눌러서 메일 창 열기", uid: nil) }
    }

    private func add(title: String, body: String, uid: Int?) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.identifier = NSUserInterfaceItemIdentifier("mailtoast")
        let v = ToastView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height), title: title, body: body)
        v.onClick = { [weak self, weak p] in
            if let uid { self?.onOpen?(uid) } else { self?.onOpen?(-1) }
            if let p { self?.dismiss(p) }
        }
        v.onClose = { [weak self, weak p] in if let p { self?.dismiss(p) } }
        p.contentView = v
        panels.insert(p, at: 0)
        layout(animated: false, new: p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; p.animator().alphaValue = 1 }
        layout(animated: true)
        // 7초 뒤 사라짐 (마우스를 올려 두면 기다림)
        scheduleHide(p, after: 7)
    }

    private func scheduleHide(_ p: NSPanel, after t: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self, weak p] in
            guard let self, let p, self.panels.contains(p) else { return }
            if p.frame.contains(NSEvent.mouseLocation) { self.scheduleHide(p, after: 2); return }
            self.dismiss(p)
        }
    }

    private func dismiss(_ p: NSPanel) {
        guard let i = panels.firstIndex(of: p) else { return }
        panels.remove(at: i)
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; p.animator().alphaValue = 0 },
                                            completionHandler: { p.orderOut(nil) })
        layout(animated: true)
    }

    /// 마우스가 있는 화면 오른쪽 위부터 아래로 쌓기
    private func layout(animated: Bool, new: NSPanel? = nil) {
        let m = NSEvent.mouseLocation
        let s = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = s.visibleFrame
        for (i, p) in panels.enumerated() {
            let f = NSRect(x: vf.maxX - Self.width - 12, y: vf.maxY - 12 - CGFloat(i + 1) * Self.height - CGFloat(i) * Self.gap,
                           width: Self.width, height: Self.height)
            if animated && p !== new { p.animator().setFrame(f, display: true) } else { p.setFrame(f, display: true) }
        }
    }
}

private final class ToastView: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private let close = NSButton()

    init(frame: NSRect, title: String, body: String) {
        super.init(frame: frame)
        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(14)
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)
        let icon = NSImageView(frame: NSRect(x: 14, y: (frame.height - 26) / 2, width: 26, height: 26))
        icon.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = .launcherAccent
        addSubview(icon)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: 50, y: frame.height - 28, width: frame.width - 50 - 30, height: 17)
        addSubview(t)
        let b = NSTextField(labelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = .secondaryLabelColor
        b.lineBreakMode = .byTruncatingTail
        b.maximumNumberOfLines = 2
        b.cell?.wraps = true
        b.frame = NSRect(x: 50, y: 8, width: frame.width - 50 - 14, height: 32)
        addSubview(b)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기")
        close.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        close.contentTintColor = .tertiaryLabelColor
        close.frame = NSRect(x: frame.width - 26, y: frame.height - 24, width: 18, height: 18)
        close.target = self
        close.action = #selector(closeTap)
        addSubview(close)
        toolTip = "눌러서 메일 보기"
    }
    required init?(coder: NSCoder) { nil }
    @objc private func closeTap() { onClose?() }
    override func mouseUp(with event: NSEvent) {
        if close.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        onClick?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
