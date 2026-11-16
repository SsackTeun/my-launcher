// 메일 창: 왼쪽에 받은 편지함 목록, 오른쪽에 고른 메일 본문
// 읽기 전용 (열어 봐도 읽음 표시가 안 바뀜). 바깥 이미지 · 스크립트는 막아 두고, 원하면 그 메일만 이미지 불러오기
import Cocoa
import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - 메일 원본 → 보여 줄 HTML

enum MIME {
    /// 원본 바이트를 1:1 글자로 (ISO-8859-1) 바꿔서 다루고, 풀 때 다시 바이트로
    static func latin(_ b: [UInt8]) -> String { String(bytes: b, encoding: .isoLatin1) ?? "" }
    static func bytes(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }

    /// 머리글과 본문 나누기 (머리글 이름은 소문자, 값은 접힌 줄 편 그대로)
    static func split(_ s: String) -> (headers: [String: String], body: String) {
        let sep = s.range(of: "\r\n\r\n") ?? s.range(of: "\n\n")
        let head = sep.map { String(s[..<$0.lowerBound]) } ?? s
        let body = sep.map { String(s[$0.upperBound...]) } ?? ""
        var h: [String: String] = [:]
        var key: String?
        for line in head.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", let k = key {
                h[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                let k = line[..<c].lowercased()
                key = k
                if h[k] == nil { h[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
            }
        }
        return (h, body)
    }

    /// `text/html; charset="utf-8"` → ("text/html", ["charset": "utf-8"])
    static func params(_ v: String) -> (String, [String: String]) {
        let parts = v.components(separatedBy: ";")
        var p: [String: String] = [:]
        for x in parts.dropFirst() {
            guard let eq = x.firstIndex(of: "=") else { continue }
            let k = x[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            p[k] = x[x.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
        }
        return ((parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased(), p)
    }

    /// 전송 인코딩 풀고 글자로
    static func decodeBody(_ body: String, cte: String, charset: String) -> String {
        var data: Data
        switch cte.lowercased() {
        case "base64":
            let clean = body.filter { !$0.isWhitespace }
            data = Data(base64Encoded: clean, options: .ignoreUnknownCharacters) ?? bytes(body)
        case "quoted-printable":
            data = quotedPrintable(body)
        default:
            data = bytes(body)
        }
        return IMAPParse.decode(data, charset: charset.isEmpty ? "utf-8" : charset.lowercased())
    }

    static func quotedPrintable(_ s: String) -> Data {
        let u = Array(bytes(s))
        var out = Data()
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == UInt8(ascii: "=") {
                // = 줄 끝: 이어 쓰기
                if i + 1 < u.count, u[i + 1] == 13 || u[i + 1] == 10 {
                    i += (i + 2 < u.count && u[i + 1] == 13 && u[i + 2] == 10) ? 3 : 2
                    continue
                }
                if i + 2 < u.count, let a = hex(u[i + 1]), let b = hex(u[i + 2]) { out.append(a << 4 | b); i += 3; continue }
            }
            out.append(u[i]); i += 1
        }
        return out
    }

    /// 첨부 파일 · 끼워 넣은 이미지
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let type: String
        let data: Data
        var size: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
        static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }
    }
    struct Parsed {
        var html: String?
        var text: String?
        var attachments: [Attachment] = []
        /// Content-ID → (형식, 데이터) — 본문의 cid: 그림
        var inline: [String: (String, Data)] = [:]
    }

    /// 파일 이름 (filename*=UTF-8''%EC.. · =?UTF-8?B?..?= · 그냥 이름 모두)
    static func fileName(_ disp: [String: String], _ ct: [String: String]) -> String? {
        for src in [disp, ct] {
            for k in ["filename*", "name*"] {
                if let v = src[k] {
                    let parts = v.components(separatedBy: "'")
                    let raw = parts.count >= 3 ? parts[2...].joined(separator: "'") : v
                    if let dec = raw.removingPercentEncoding { return dec }
                }
            }
            // filename*0*=… 처럼 나뉜 것
            let pieces = src.keys.filter { $0.hasPrefix("filename*") || $0.hasPrefix("name*") }.sorted { a, b in
                (Int(a.split(separator: "*")[safe: 1] ?? "") ?? 0) < (Int(b.split(separator: "*")[safe: 1] ?? "") ?? 0)
            }
            if !pieces.isEmpty {
                var joined = pieces.map { src[$0] ?? "" }.joined()
                if let q = joined.range(of: "''") { joined = String(joined[q.upperBound...]) }
                return joined.removingPercentEncoding ?? joined
            }
            for k in ["filename", "name"] { if let v = src[k], !v.isEmpty { return IMAPParse.decodeWords(latinToUTF8(v)) } }
        }
        return nil
    }
    /// 머리글에 날 바이트(UTF-8)로 들어온 이름 살리기
    static func latinToUTF8(_ s: String) -> String { String(data: bytes(s), encoding: .utf8) ?? s }

    static func rawData(_ body: String, cte: String) -> Data {
        switch cte.lowercased() {
        case "base64": return Data(base64Encoded: body.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable": return quotedPrintable(body)
        default: return bytes(body)
        }
    }

    /// 한 덩어리(파트) 풀기: HTML 이 있으면 HTML, 없으면 글. 첨부 · 끼워 넣은 그림도 모음
    static func parse(_ s: String) -> Parsed {
        var out = Parsed()
        walk(s, into: &out)
        return out
    }

    private static func walk(_ s: String, into out: inout Parsed, alternative: Bool = false) {
        let (h, body) = split(s)
        let (type, p) = params(h["content-type"] ?? "text/plain")
        let cte = (h["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespaces)
        let (dispType, dp) = params(h["content-disposition"] ?? "")
        let name = fileName(dp, p)
        let cid = h["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        if type.hasPrefix("multipart/"), let b = p["boundary"], !b.isEmpty {
            let alt = type == "multipart/alternative"
            var sub = Parsed()
            for part in parts(body, boundary: b) {
                var one = Parsed()
                walk(part, into: &one, alternative: alt)
                // alternative 는 마지막(가장 풍부한) 본문, 나머지는 처음 나온 본문
                if alt { sub.html = one.html ?? sub.html; sub.text = one.text ?? sub.text }
                else { if sub.html == nil { sub.html = one.html }; if sub.text == nil { sub.text = one.text } }
                sub.attachments += one.attachments
                sub.inline.merge(one.inline) { a, _ in a }
            }
            if out.html == nil { out.html = sub.html }
            if out.text == nil { out.text = sub.text }
            out.attachments += sub.attachments
            out.inline.merge(sub.inline) { a, _ in a }
            return
        }
        if type == "message/rfc822" && dispType != "attachment" { walk(body, into: &out); return }
        let isBodyText = (type == "text/html" || type == "text/plain" || type.isEmpty) && dispType != "attachment" && name == nil
        if isBodyText {
            let t = decodeBody(body, cte: cte, charset: p["charset"] ?? "")
            if type == "text/html" { if out.html == nil { out.html = t } } else if out.text == nil { out.text = t }
            return
        }
        let data = rawData(body, cte: cte)
        // 본문에 끼워 넣는 그림 (cid) — 첨부 목록에는 이름 있고 inline 이 아닐 때만
        if let cid, type.hasPrefix("image/") { out.inline[cid] = (type, data) }
        if dispType == "attachment" || (name != nil && !(cid != nil && dispType == "inline")) {
            out.attachments.append(Attachment(name: name ?? "첨부 파일", type: type, data: data))
        }
    }

    /// --경계 줄로 나누기
    static func parts(_ body: String, boundary: String) -> [String] {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let open = "--" + boundary, close = "--" + boundary + "--"
        var out: [String] = []
        var cur: [String]?
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t == close { if let c = cur { out.append(c.joined(separator: "\r\n")) }; cur = nil; break }
            if t == open { if let c = cur { out.append(c.joined(separator: "\r\n")) }; cur = []; continue }
            cur?.append(l)
        }
        if let c = cur { out.append(c.joined(separator: "\r\n")) }
        return out
    }

    /// 보여 줄 HTML (글뿐이면 글을 HTML 로 감쌈). cid: 그림은 메일 안 데이터로 바꿔 넣음
    static func page(_ r: Parsed) -> String {
        let style = """
        <meta charset="utf-8"><meta name="color-scheme" content="light">
        <style>body{font:14px -apple-system,sans-serif;margin:16px;color:#1d1d1f;background:#fff;word-wrap:break-word}
        pre{white-space:pre-wrap;font:13px -apple-system,sans-serif}img{max-width:100%;height:auto}</style>
        """
        if var html = r.html {
            for (cid, (type, data)) in r.inline {
                let uri = "data:\(type);base64,\(data.base64EncodedString())"
                html = html.replacingOccurrences(of: "cid:" + cid, with: uri, options: .caseInsensitive)
            }
            return style + html
        }
        if let t = r.text { return style + "<pre>" + escape(t) + "</pre>" }
        return style + "<p style='color:#888'>보여 줄 본문이 없어요 (첨부 파일만 있는 메일일 수 있어요)</p>"
    }
    static func page(_ raw: [UInt8]) -> String { page(parse(latin(raw))) }

    static func escape(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 답장에 인용할 글 (글 본문, 없으면 HTML 에서 태그를 걷어 냄)
    static func plainText(_ r: Parsed) -> String {
        if let t = r.text { return t }
        guard let h = r.html, let d = h.data(using: .utf8),
              let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return "" }
        return a.string.replacingOccurrences(of: "\u{FFFC}", with: "")   // 그림 자리 표시는 빼고
    }

    /// 주소만 뽑기 ("홍길동 <a@b.com>, c@d.com" → [a@b.com, c@d.com])
    static func addresses(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) else { return [] }
        let ns = s as NSString
        var seen = Set<String>()
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
extension ArraySlice {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - 상태

@MainActor
final class MailBox: ObservableObject {
    @Published var items: [MailItem] = []
    /// 받은 편지함 전체 메일 번호 (최신순) — 이걸로 다음 쪽을 정함
    @Published var allUIDs: [Int] = []
    @Published var loadingMore = false
    /// 목록을 다 불러오면 고를 메일 (토스트에서 눌렀을 때)
    var pendingSelect: Int?
    static let pageSize = 50
    var hasMore: Bool { items.count < allUIDs.count }
    @Published var loading = false
    @Published var error: String?
    @Published var selected: Int? { didSet { if selected != oldValue { openSelected() } } }
    @Published var html = ""
    @Published var bodyLoading = false
    /// 이 메일의 바깥 이미지 불러오기 (메일을 바꾸면 다시 막음)
    @Published var allowRemote = false
    @Published var attachments: [MIME.Attachment] = []
    @Published var note: String?
    /// 답장에 쓸 원본 정보
    @Published var headers: [String: String] = [:]
    private(set) var quoteText = ""
    private struct Opened { let page: String; let parsed: MIME.Parsed; let headers: [String: String] }
    private var cache: [Int: Opened] = [:]

    var current: MailItem? { items.first { $0.uid == selected } }

    private var account: (MailAccount, String)? {
        guard let a = MailAccount.saved, let pw = MailKeychain.load(a.user) else { return nil }
        return (a, pw)
    }

    func reload() {
        guard let (a, pw) = account else { error = "메일 계정이 없어요 — 옵션 › 메일에서 연결해 주세요"; return }
        guard !loading else { return }
        loading = true
        Task {
            do {
                // 이미 여러 쪽을 봤으면 그만큼 다시 (새로 고침해도 보던 곳이 안 사라지게)
                let want = max(Self.pageSize, items.count)
                let (list, uids) = try await MailWatch.fetchList(a, password: pw, limit: want)
                items = list
                allUIDs = uids
                error = nil
                if let p = pendingSelect, list.contains(where: { $0.uid == p }) { selected = p; pendingSelect = nil }
                else if selected == nil || !list.contains(where: { $0.uid == selected }) { selected = list.first?.uid }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    /// 이전 메일 한 쪽 더
    func loadMore() {
        guard hasMore, !loadingMore, !loading, let (a, pw) = account else { return }
        let have = Set(items.map(\.uid))
        let next = Array(allUIDs.filter { !have.contains($0) }.prefix(Self.pageSize))
        guard !next.isEmpty else { return }
        loadingMore = true
        Task {
            do {
                let more = try await MailWatch.fetchPage(a, password: pw, uids: next)
                let seen = Set(items.map(\.uid))
                items += more.filter { !seen.contains($0.uid) }
                // 서버에서 지워져 머리글이 안 온 번호는 목록에서 빼서 '더 보기' 가 끝나게
                let got = Set(more.map(\.uid))
                allUIDs.removeAll { next.contains($0) && !got.contains($0) }
            } catch { self.error = error.localizedDescription }
            loadingMore = false
        }
    }

    private func show(_ o: Opened) {
        html = o.page
        attachments = o.parsed.attachments
        headers = o.headers
        quoteText = MIME.plainText(o.parsed)
    }

    private func openSelected() {
        allowRemote = false
        note = nil
        guard let uid = selected else { html = ""; attachments = []; return }
        let markSeen = MailAccount.markReadOnOpen && current?.seen == false
        if let c = cache[uid] {
            show(c)
            if markSeen { setSeen(true) }
            return
        }
        guard let (a, pw) = account else { return }
        bodyLoading = true
        html = ""; attachments = []
        Task {
            do {
                let raw = try await MailWatch.fetchRaw(a, password: pw, uid: uid, markSeen: markSeen)
                let parsed = MIME.parse(MIME.latin(raw))
                let o = Opened(page: MIME.page(parsed), parsed: parsed, headers: MIME.split(MIME.latin(raw)).headers)
                cache[uid] = o
                if markSeen { markLocal(uid, seen: true) }
                if selected == uid { show(o) }
            } catch {
                if selected == uid { html = "<p style='font:13px -apple-system;color:#c00;margin:16px'>메일을 불러오지 못했어요: \(MIME.escape(error.localizedDescription))</p>" }
            }
            if selected == uid { bodyLoading = false }
        }
    }

    private func markLocal(_ uid: Int, seen: Bool) {
        if let i = items.firstIndex(where: { $0.uid == uid }) { items[i].seen = seen }
        MailWatch.shared.check()      // ✉︎ 배지 숫자도
    }

    /// 읽음 / 안 읽음 바꾸기
    func setSeen(_ seen: Bool) {
        guard let uid = selected, let (a, pw) = account else { return }
        markLocal(uid, seen: seen)
        Task {
            do { try await MailWatch.setSeen(a, password: pw, uid: uid, seen: seen) }
            catch { note = "읽음 표시를 바꾸지 못했어요: " + error.localizedDescription; markLocal(uid, seen: !seen) }
        }
    }

    /// 첨부 파일을 다운로드 폴더에 저장하고 Finder 에서 보여 줌 (open 이면 바로 열기)
    func save(_ att: MIME.Attachment, open: Bool = false) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let safe = att.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var url = dir.appendingPathComponent(safe)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try att.data.write(to: url)
            if open { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            note = "다운로드 폴더에 저장했어요: " + url.lastPathComponent
        } catch { note = "저장하지 못했어요: " + error.localizedDescription }
    }

    /// 첨부 모두 다운로드 폴더에
    func saveAll() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let urls = attachments.compactMap { write($0, to: dir) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        note = "다운로드 폴더에 \(urls.count)개 저장했어요"
    }

    /// 미리보기 (임시 폴더에 두고 훑어보기)
    func preview(_ att: MIME.Attachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-mail-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let url = write(att, to: dir) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// 같은 이름이 있으면 "이름 (2).확장자"
    private func write(_ att: MIME.Attachment, to dir: URL) -> URL? {
        let safe = att.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var url = dir.appendingPathComponent(safe)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do { try att.data.write(to: url); return url } catch { note = "저장하지 못했어요: " + error.localizedDescription; return nil }
    }

    /// 답장 창 열기 (all: 전체 답장)
    func reply(all: Bool) {
        guard let it = current, let me = MailAccount.saved?.user else { return }
        let h = headers
        let to = MIME.addresses(h["reply-to"] ?? h["from"] ?? it.fromFull)
        var cc: [String] = []
        if all {
            let mine = me.lowercased()
            cc = MIME.addresses((h["to"] ?? "") + "," + (h["cc"] ?? ""))
                .filter { $0.lowercased() != mine && !to.map { $0.lowercased() }.contains($0.lowercased()) }
        }
        let subj = it.subject.lowercased().hasPrefix("re:") ? it.subject : "Re: " + it.subject
        let when = MailBrowser.long(it.date)
        let who = IMAPParse.decodeWords(h["from"] ?? it.fromFull)
        let quoted = quoteText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let body = "\n\n\(when), \(who) 작성:\n" + quoted
        let msgID = h["message-id"]?.trimmingCharacters(in: .whitespaces)
        let refs = [h["references"], msgID].compactMap { $0 }.joined(separator: " ")
        ComposeWindow.open(to: to.joined(separator: ", "), cc: cc.joined(separator: ", "), subject: subj, body: body,
                           inReplyTo: msgID, references: refs.isEmpty ? nil : refs)
    }
}

// MARK: - 화면

struct MailBrowser: View {
    @ObservedObject var box: MailBox

    var body: some View {
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 290, maxWidth: 420)
            detail.frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { box.reload() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("받은 편지함").font(.headline)
                if !box.allUIDs.isEmpty {
                    Text("\(box.items.count) / \(box.allUIDs.count)통").font(.caption).foregroundStyle(.secondary)
                        .help("지금 불러온 메일 / 받은 편지함 전체")
                }
                Spacer()
                if box.loading { ProgressView().controlSize(.small) }
                Button { MailWatch.shared.confirmMarkAllRead() } label: { Image(systemName: "envelope.open") }
                    .buttonStyle(.borderless).help("모두 읽음으로")
                Button { box.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("새로 고침")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let e = box.error {
                Text("⚠︎ " + e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            List(selection: $box.selected) {
                ForEach(box.items) { it in row(it).tag(it.uid) }
                // 맨 아래: 이전 메일 더 (보이면 저절로 불러옴)
                if box.hasMore {
                    HStack {
                        Spacer()
                        if box.loadingMore { ProgressView().controlSize(.small) }
                        Button(box.loadingMore ? "불러오는 중…" : "이전 메일 \(min(MailBox.pageSize, box.allUIDs.count - box.items.count))통 더 보기") { box.loadMore() }
                            .buttonStyle(.link).disabled(box.loadingMore)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .selectionDisabled()
                    .onAppear { box.loadMore() }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ it: MailItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(it.seen ? Color.clear : Color.lyricTranslation).frame(width: 7, height: 7)
                Text(it.from).fontWeight(it.seen ? .regular : .semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.short(it.date)).font(.caption).foregroundStyle(.secondary)
            }
            Text(it.subject).font(.callout).lineLimit(2)
                .foregroundStyle(it.seen ? .secondary : .primary)
                .padding(.leading, 13)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var detail: some View {
        if let it = box.current {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    // 제목 · 오른쪽 위 동작 단추
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(it.subject).font(.title2.bold()).textSelection(.enabled).lineLimit(3)
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            iconButton("arrowshape.turn.up.left", "답장") { box.reply(all: false) }
                            iconButton("arrowshape.turn.up.left.2", "전체 답장") { box.reply(all: true) }
                            iconButton(it.seen ? "envelope.badge" : "envelope.open", it.seen ? "안 읽음으로" : "읽음으로") { box.setSeen(!it.seen) }
                            iconButton(box.allowRemote ? "photo.fill" : "photo", box.allowRemote ? "바깥 이미지 다시 막기" : "바깥 이미지 불러오기 (보낸 사람이 열람 여부를 알 수 있어요)") { box.allowRemote.toggle() }
                            iconButton("safari", "웹 메일에서 열기") { MailWatch.shared.openWeb() }
                        }
                    }
                    HStack(spacing: 6) {
                        Text(Self.dateLine(it.date)).font(.callout).foregroundStyle(.secondary)
                        if box.bodyLoading { ProgressView().controlSize(.small) }
                    }
                    // 보낸사람 · 받는사람 · 참조
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        personRow("보낸사람", IMAPParse.decodeWords(box.headers["from"] ?? it.fromFull))
                        if let to = box.headers["to"], !to.isEmpty { personRow("받는사람", IMAPParse.decodeWords(to)) }
                        if let cc = box.headers["cc"], !cc.isEmpty { personRow("참조", IMAPParse.decodeWords(cc)) }
                    }
                    if !box.attachments.isEmpty { attachmentBox }
                    if let n = box.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Divider()
                MailHTMLView(html: box.html, allowRemote: box.allowRemote)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "envelope.open").font(.largeTitle).foregroundStyle(.tertiary)
                Text(box.loading ? "불러오는 중…" : "메일을 고르세요").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 24) }
            .buttonStyle(.borderless).help(tip)
    }

    @ViewBuilder private func personRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(value.replacingOccurrences(of: "\"", with: "")).font(.callout).textSelection(.enabled).lineLimit(3)
        }
    }

    @State private var attachOpen = true

    /// 첨부 상자: [⌄ 첨부파일 N개 | 모두 저장] + 파일마다 [아이콘 이름 크기 · 미리보기 저장 열기]
    private var attachmentBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { attachOpen.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(attachOpen ? 0 : -90))
                        Text("첨부파일").fontWeight(.semibold)
                        Text("\(box.attachments.count)개").fontWeight(.semibold).foregroundStyle(Color.lyricTranslation)
                    }
                }.buttonStyle(.plain)
                Text("|").foregroundStyle(.tertiary)
                Button("모두 저장") { box.saveAll() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 9)
            if attachOpen {
                ForEach(box.attachments) { att in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (att.name as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 18, height: 18)
                        Text(att.name).lineLimit(1).truncationMode(.middle)
                        Text(att.size).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 8)
                        iconButton("eye", "미리보기") { box.preview(att) }
                        iconButton("arrow.down.to.line", "다운로드 폴더에 저장") { box.save(att) }
                        iconButton("arrow.up.forward.app", "열기") { box.save(att, open: true) }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                Spacer().frame(height: 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
    }

    /// "2026. 11. 12. (목) 15:07"
    static func dateLine(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy. M. d. (E) HH:mm"
        return f.string(from: d)
    }

    static func short(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M/d" : "yy/M/d"
        return f.string(from: d)
    }
    static func long(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E) a h:mm"
        return f.string(from: d)
    }
}

/// 본문 (자바스크립트 끔, 바깥 이미지는 허락할 때만, 링크는 기본 브라우저로)
struct MailHTMLView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        let c = context.coordinator
        guard c.html != html || c.allowRemote != allowRemote else { return }
        c.html = html; c.allowRemote = allowRemote
        let load = { [html] in w.loadHTMLString(html, baseURL: nil) }
        let ucc = w.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if allowRemote { load(); return }
        MailBlocker.list { list in
            if let list { ucc.add(list) }
            load()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        var allowRemote = false
        func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // 링크를 누르면 기본 브라우저로 (메일 창 안에서 다른 페이지로 가지 않게)
            if a.navigationType == .linkActivated, let u = a.request.url {
                NSWorkspace.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// 바깥(http · https) 불러오기를 막는 규칙 (한 번만 만들어 둠)
@MainActor
enum MailBlocker {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var started = false
    static func list(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { done(compiled); return }
        waiting.append(done)
        guard !started else { return }
        started = true
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mailBlockRemote", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated {
                compiled = list
                let w = waiting
                waiting = []
                w.forEach { $0(list) }
            }
        }
    }
}

// MARK: - 창

@MainActor
final class MailWindow: NSObject, NSWindowDelegate {
    static let shared = MailWindow()
    private var window: NSWindow?
    let box = MailBox()

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: MailBrowser(box: box))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("MailWindow")
            if UserDefaults.standard.string(forKey: "NSWindow Frame MailWindow") == nil { w.center() }
            window = w
        } else {
            box.reload()
        }
        window?.title = "메일 — " + (MailAccount.saved?.user ?? "")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 그 메일 고르기 (목록에 아직 없으면 목록을 불러온 뒤)
    func select(_ uid: Int) {
        if box.items.contains(where: { $0.uid == uid }) { box.selected = uid; return }
        box.pendingSelect = uid
        box.reload()
    }

    /// 새 메일이 왔을 때 창이 열려 있으면 목록 새로 고침
    func refreshIfOpen() { if isVisible { box.reload() } }
}

// MARK: - 답장 쓰기

@MainActor
final class Compose: ObservableObject {
    @Published var to: String
    @Published var cc: String
    @Published var subject: String
    @Published var body: String
    @Published var sending = false
    @Published var status: String?
    let inReplyTo: String?
    let references: String?
    var onSent: (() -> Void)?

    init(to: String, cc: String, subject: String, body: String, inReplyTo: String?, references: String?) {
        self.to = to; self.cc = cc; self.subject = subject; self.body = body
        self.inReplyTo = inReplyTo; self.references = references
    }

    /// 보낼 메일 원본 (UTF-8, 본문은 base64 — 한글 · 긴 줄 모두 안전)
    nonisolated static func message(from: String, to: String, cc: String, subject: String, body: String,
                        inReplyTo: String?, references: String?, date: Date = Date()) -> String {
        func enc(_ s: String) -> String {
            s.allSatisfy { $0.isASCII } ? s : "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last.map(String.init) ?? "launcher.local"
        var h = [
            "From: \(from)",
            "To: \(MIME.addresses(to).joined(separator: ", "))",
        ]
        let ccs = MIME.addresses(cc)
        if !ccs.isEmpty { h.append("Cc: \(ccs.joined(separator: ", "))") }
        h += [
            "Subject: \(enc(subject))",
            "Date: \(df.string(from: date))",
            "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>",
        ]
        if let r = inReplyTo { h.append("In-Reply-To: \(r)") }
        if let r = references { h.append("References: \(r)") }
        h += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        let b64 = Data(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return h.joined(separator: "\r\n") + "\r\n\r\n" + b64 + "\r\n"
    }

    func send() {
        guard let a = MailAccount.saved, let pw = MailKeychain.load(a.user) else { status = "메일 계정이 없어요"; return }
        let rcpts = MIME.addresses(to + "," + cc)
        guard !rcpts.isEmpty else { status = "받는 사람을 넣어 주세요"; return }
        sending = true
        status = "보내는 중…"
        let msg = Self.message(from: a.user, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references)
        Task {
            do {
                try await MailWatch.send(a, password: pw, rcpts: rcpts, message: msg)
                status = "보냈어요"
                onSent?()
            } catch {
                status = "⚠︎ 보내지 못했어요: " + error.localizedDescription
            }
            sending = false
        }
    }
}

struct ComposeView: View {
    @ObservedObject var c: Compose

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("받는 사람").foregroundStyle(.secondary); TextField("a@company.com", text: $c.to) }
                GridRow { Text("참조").foregroundStyle(.secondary); TextField("", text: $c.cc) }
                GridRow { Text("제목").foregroundStyle(.secondary); TextField("", text: $c.subject) }
            }
            TextEditor(text: $c.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                if let s = c.status { Text(s).font(.caption).foregroundStyle(s.hasPrefix("⚠︎") ? .orange : .secondary).lineLimit(2) }
                Spacer()
                Button { c.send() } label: { Label("보내기", systemImage: "paperplane.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(c.sending)
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 360)
    }
}

@MainActor
enum ComposeWindow {
    private static var open: [NSWindow] = []
    static func open(to: String, cc: String, subject: String, body: String, inReplyTo: String?, references: String?) {
        let c = Compose(to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo, references: references)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = subject
        w.contentView = NSHostingView(rootView: ComposeView(c: c))
        w.isReleasedWhenClosed = false
        w.center()
        c.onSent = { [weak w] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { w?.close() }
        }
        open.append(w)
        open.removeAll { !$0.isVisible && $0 !== w }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
