// 옵션 창의 탭들: 막대 · 접기 / 영상 · PIP
// (기본 탭은 main.swift 의 예전 설정 화면 그대로)
// 바꾸면 바로 적용되고, 창을 열 때마다 지금 값으로 다시 그림
import Cocoa

@MainActor
enum Options {
    /// 새로 만든 탭들 (열 때마다 지금 값으로)
    static func tabs() -> [NSTabViewItem] {
        [item("막대 · 접기", barTab()), item("테마", themeTab()), item("영상 · PIP", videoTab()), item("메일", mailTab())]
    }

    private static func item(_ title: String, _ v: NSView) -> NSTabViewItem {
        let i = NSTabViewItem(identifier: title)
        i.label = title
        i.view = v
        return i
    }

    // MARK: 탭 내용

    private static func barTab() -> NSView {
        let f = Form()
        f.header("도구함 창")
        f.check("한 줄 플레이어 (음악 플레이어를 한 줄로 작게)", PlayerBar.compact) { PlayerBar.compact = $0; Options.relayout?() }
        f.check("컴팩트하게 (창 폭 · 여백 · 간격 줄이기)", UserDefaults.standard.object(forKey: "compactUI") as? Bool ?? true) {
            UserDefaults.standard.set($0, forKey: "compactUI"); Options.relayout?()
        }
        f.check("좁게 (폭 약 280 · 플레이어 두 줄 · 앱 2~3칸)", UserDefaults.standard.object(forKey: "narrowUI") as? Bool ?? false) {
            UserDefaults.standard.set($0, forKey: "narrowUI"); Options.relayout?()
        }
        f.check("스크롤하면 앱을 하나씩 골라 가며 내려가기 (끄면 목록만 부드럽게 스크롤)", UserDefaults.standard.object(forKey: "scrollFocusApps") as? Bool ?? false) {
            UserDefaults.standard.set($0, forKey: "scrollFocusApps")
        }
        f.header("자주 쓰는 앱 막대")
        f.check("막대 보이기", FavBar.shared.enabled) { FavBar.shared.enabled = $0 }
        f.buttons([("막대 추가", { FavBar.addBar() })] +
                  Spaces.numbered().desks.map { dk in ("데스크탑 \(dk.n) 막대 추가", { FavBar.addDesktopBar(dk.n); Options.reload?() }) },
                  disabled: Set(Spaces.numbered().desks.filter { FavBar.hasBar(forDesktop: $0.n) }.map { "데스크탑 \($0.n) 막대 추가" }))
        f.check("막대 자리 비워 두기 (다른 앱 창이 막대를 덮지 않게 옆으로 밀거나 줄임)", BarReserve.enabled) { BarReserve.enabled = $0 }
        f.check("초록 버튼을 누르면 전체 화면 대신 최대화 (막대 자리는 빼고, 다시 누르면 원래대로)", GreenZoom.enabled) { GreenZoom.enabled = $0 }
        f.note("막대마다 이름 · 붙는 곳 · 앱 · 종류는 막대를 오른쪽 클릭해서 바꿔요. 자리 비워 두기는 손쉬운 사용 권한이 있어야 해요.")

        f.header("도구함 · 떼어 낸 플레이어 창")
        f.popup("놓는 방식", [("자석", 1), ("자유", 0)], EdgeDock.magnet ? 1 : 0) { EdgeDock.magnet = $0 > 0.5 }
        f.note("자석: 끌어서 놓으면 앱 아이콘 크기 격자에 맞고, 화면 끝 가까이 놓으면 붙어요 · 자유: 놓은 자리 그대로 (끝에 붙지도, 막대를 비키지도 않음)")
        f.check("화면 끝에 붙였을 때 자동 접기 (벗어나면 접힘)", EdgeDock.shared.autoCollapse) { EdgeDock.shared.autoCollapse = $0 }
        f.check("접힌 손잡이에 마우스를 대면 펴기 (막대도 같이)", EdgeDock.hoverExpand) { EdgeDock.hoverExpand = $0 }

        f.header("열리고 닫히는 속도")
        f.slider("움직임", value: Motion.duration, min: 0, max: 0.6, text: { $0 < 0.01 ? "바로" : String(format: "%.2f초", $0) }) { Motion.duration = $0 }
        f.slider("펴기까지", value: Motion.openDelay, min: 0, max: 1.0, text: { $0 < 0.01 ? "바로" : String(format: "%.1f초", $0) }) { Motion.openDelay = $0 }
        f.slider("접기까지", value: Motion.closeDelay, min: 0.2, max: 3.0, text: { String(format: "%.1f초", $0) }) { Motion.closeDelay = $0 }
        f.note("움직임: 접히고 펴질 때 미끄러지는 시간 · 펴기까지: 손잡이에 마우스를 대고 기다리는 시간 · 접기까지: 마우스가 벗어나고 접힐 때까지 시간 (자동 접기에도 적용)")
        f.buttons([("기본값으로", {
            Motion.duration = 0.22; Motion.openDelay = 0.2; Motion.closeDelay = 1.0
            Options.reload?()
        })])
        return f.view
    }

    private static func themeTab() -> NSView {
        let f = Form()
        f.header("테마")
        f.popup("모양", [("기본", 0), ("곰 (우유색)", 1)], Theme.isBear ? 1 : 0) {
            Theme.kind = $0 > 0.5 ? .bear : .standard
            Options.relayout?()
        }
        f.note("곰: 따뜻한 우유색 바탕에 갈색 글씨, 분홍 강조색. 도구함 창과 떼어 낸 플레이어에 적용돼요.")
        f.header("그림 (곰 테마에서 보여요)")
        let bg = f.status("배경 그림: " + (Theme.file(.background)?.lastPathComponent ?? "없음"))
        f.buttons([
            ("배경 그림 고르기…", { Theme.choose(.background) { bg.stringValue = "배경 그림: 골랐어요"; Options.relayout?() } }),
            ("배경 지우기", { Theme.clear(.background); bg.stringValue = "배경 그림: 없음"; Options.relayout?() }),
        ])
        f.slider("진하기", value: Theme.backgroundAlpha, min: 0.05, max: 1, text: { "\(Int($0 * 100))%" }) {
            Theme.backgroundAlpha = $0; Options.relayout?()
        }
        let st = f.status("스티커: " + (Theme.file(.sticker)?.lastPathComponent ?? "없음"))
        f.buttons([
            ("스티커 고르기…", { Theme.choose(.sticker) { st.stringValue = "스티커: 골랐어요"; Options.relayout?() } }),
            ("스티커 지우기", { Theme.clear(.sticker); st.stringValue = "스티커: 없음"; Options.relayout?() }),
            ("그림 폴더 열기", { NSWorkspace.shared.open(Theme.folder) }),
        ])
        f.slider("스티커 크기", value: Theme.stickerSize, min: 40, max: 160, text: { "\(Int($0))" }) {
            Theme.stickerSize = $0; Options.relayout?()
        }
        f.note("인터넷에서 마음에 드는 그림을 받아 두고 여기서 골라 주세요. 그림 폴더에 background · sticker 라는 이름으로 넣어도 돼요. 스티커는 창 오른쪽 아래 앱 아이콘 뒤에 깔려요.")
        return f.view
    }

    private static func videoTab() -> NSView {
        let f = Form()
        let yt = YouTubeWindow.shared, nf = VideoWindow.netflix
        f.header("YouTube")
        f.check("영상을 누르면 바로 작은 창(PIP)으로", yt.autoPiP) { yt.autoPiP = $0 }
        f.check("항상 가장 높은 화질로", yt.bestQuality) { yt.bestQuality = $0 }
        f.check("쇼츠가 끝나면 다음 쇼츠로 자동 넘김", yt.autoNextShorts) { yt.autoNextShorts = $0 }
        f.header("Netflix")
        f.check("영상을 누르면 바로 작은 창(PIP)으로", nf.autoPiP) { nf.autoPiP = $0 }
        return f.view
    }

    private static func mailTab() -> NSView {
        let f = Form()
        let saved = MailAccount.saved
        f.header("네이버 웍스 메일 (IMAP)")
        let user = f.field("메일 주소", saved?.user ?? "", placeholder: "name@company.com")
        let pass = f.field("비밀번호", saved.flatMap { MailKeychain.load($0.user) } ?? "", placeholder: "웍스 비밀번호 (2단계 인증이면 앱 비밀번호)", secure: true)
        let host = f.field("받는 서버", saved?.host ?? MailAccount.naverWorks.host, placeholder: "imap.worksmobile.com")
        let smtp = f.field("보내는 서버", saved?.smtpHost ?? MailAccount.naverWorks.smtpHost, placeholder: "smtp.worksmobile.com (SSL 465)")
        let status = f.status(saved == nil ? "아직 연결 안 함" : MailWatch.shared.lastError.map { "⚠︎ " + $0 }
                              ?? "연결됨 · 안 읽은 메일 \(MailWatch.shared.unreadCount)개")
        f.buttons([
            ("저장하고 연결 확인", {
                let u = user.stringValue.trimmingCharacters(in: .whitespaces)
                let h = host.stringValue.trimmingCharacters(in: .whitespaces)
                guard !u.isEmpty, !pass.stringValue.isEmpty else { status.stringValue = "메일 주소와 비밀번호를 넣어 주세요"; return }
                if let old = MailAccount.saved, old.user != u { MailKeychain.delete(old.user) }
                guard MailKeychain.save(pass.stringValue, for: u) else { status.stringValue = "⚠︎ 키체인에 저장하지 못했어요"; return }
                var a = MailAccount.naverWorks
                a.user = u
                if !h.isEmpty { a.host = h }
                let sh = smtp.stringValue.trimmingCharacters(in: .whitespaces)
                if !sh.isEmpty { a.smtpHost = sh }
                MailAccount.saved = a
                status.stringValue = "확인하는 중…"
                MailWatch.shared.check { err in status.stringValue = err.map { "⚠︎ " + $0 } ?? "연결됨 · 안 읽은 메일 \(MailWatch.shared.unreadCount)개" }
            }),
            ("연결 끊기", {
                if let a = MailAccount.saved { MailKeychain.delete(a.user) }
                MailAccount.saved = nil
                user.stringValue = ""; pass.stringValue = ""
                status.stringValue = "연결을 끊었어요 (비밀번호도 지움)"
                MailWatch.shared.check()
            }),
        ])
        f.check("메일을 열면 읽음으로 표시", MailAccount.markReadOnOpen) { MailAccount.markReadOnOpen = $0 }
        f.check("새 메일이 오면 화면 오른쪽 위에 알림 (보낸 사람 · 제목)", MailWatch.toast) { MailWatch.toast = $0 }
        f.note("웍스 메일에서 먼저 IMAP 을 켜 주세요: 메일 › 환경 설정 › IMAP/SMTP › 사용 (보내기도 쓰려면 SMTP 도). 회사 관리자가 막아 두었으면 관리자에게 허용을 부탁해야 해요.")
        f.note("2분마다 안 읽은 메일을 확인해요. 답장은 보내는 서버(SMTP)로 보내고 보낸 편지함에도 넣어요. 비밀번호는 이 맥의 키체인에만 저장되고, 메일 내용은 이 맥 밖으로 보내지 않아요.")
        return f.view
    }

    /// 창을 다시 그리는 동작 (기본값으로 되돌릴 때 등)
    static var reload: (() -> Void)?
    /// 도구함 창 배치를 다시 (컴팩트 옵션을 바꿨을 때)
    static var relayout: (() -> Void)?
}

/// 위에서부터 한 줄씩 쌓는 간단한 설정 화면
@MainActor
private final class Form {
    let view = FlippedForm(frame: NSRect(x: 0, y: 0, width: 440, height: 480))
    private var y: CGFloat = 14
    private let left: CGFloat = 20, width: CGFloat = 400

    func header(_ t: String) {
        if y > 20 { y += 8 }
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: left, y: y, width: width, height: 18)
        view.addSubview(l)
        y += 24
    }

    func note(_ t: String) {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        let h = ceil(l.sizeThatFits(NSSize(width: width - 12, height: 200)).height)
        l.frame = NSRect(x: left + 4, y: y, width: width - 12, height: h)
        view.addSubview(l)
        y += h + 6
    }

    /// 이름 + 글자 칸 (secure 면 비밀번호 칸)
    func field(_ t: String, _ value: String, placeholder: String = "", secure: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.frame = NSRect(x: left + 4, y: y + 3, width: 70, height: 18)
        view.addSubview(l)
        let tf: NSTextField = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        tf.stringValue = value
        tf.placeholderString = placeholder
        tf.frame = NSRect(x: left + 80, y: y, width: width - 84, height: 22)
        view.addSubview(tf)
        y += 30
        return tf
    }

    /// 상태 한 줄 (나중에 글자를 바꿈)
    func status(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: left + 4, y: y, width: width - 8, height: 32)
        view.addSubview(l)
        y += 36
        return l
    }

    func check(_ t: String, _ on: Bool, _ set: @escaping (Bool) -> Void) {
        let a = Act { b in set((b as! NSButton).state == .on) }
        let b = NSButton(checkboxWithTitle: t, target: a, action: #selector(Act.fire(_:)))
        b.state = on ? .on : .off
        b.frame = NSRect(x: left + 4, y: y, width: width, height: 20)
        view.addSubview(b)
        view.keep.append(a)
        y += 26
    }

    func slider(_ t: String, value: Double, min: Double, max: Double, text: @escaping (Double) -> String, _ set: @escaping (Double) -> Void) {
        let l = NSTextField(labelWithString: t)
        l.frame = NSRect(x: left + 4, y: y + 2, width: 70, height: 18)
        view.addSubview(l)
        let v = NSTextField(labelWithString: text(value))
        v.alignment = .right
        v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        v.frame = NSRect(x: left + width - 70, y: y + 2, width: 66, height: 18)
        view.addSubview(v)
        let a = Act { s in
            let x = (s as! NSSlider).doubleValue
            v.stringValue = text(x)
            set(x)
        }
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: a, action: #selector(Act.fire(_:)))
        s.frame = NSRect(x: left + 80, y: y, width: width - 160, height: 22)
        s.isContinuous = true
        view.addSubview(s)
        view.keep.append(a)
        y += 28
    }

    func popup(_ t: String, _ items: [(String, Double)], _ current: Double, _ set: @escaping (Double) -> Void) {
        let l = NSTextField(labelWithString: t)
        l.frame = NSRect(x: left + 4, y: y + 3, width: 70, height: 18)
        view.addSubview(l)
        let a = Act { p in set(items[(p as! NSPopUpButton).indexOfSelectedItem].1) }
        let p = NSPopUpButton(frame: NSRect(x: left + 80, y: y, width: 160, height: 24), pullsDown: false)
        p.addItems(withTitles: items.map(\.0))
        if let i = items.firstIndex(where: { abs($0.1 - current) < 0.01 }) { p.selectItem(at: i) }
        p.target = a
        p.action = #selector(Act.fire(_:))
        view.addSubview(p)
        view.keep.append(a)
        y += 30
    }

    func buttons(_ list: [(String, () -> Void)], disabled: Set<String> = []) {
        var x = left + 4
        for (t, run) in list {
            let a = Act { _ in run() }
            let b = NSButton(title: t, target: a, action: #selector(Act.fire(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.sizeToFit()
            if disabled.contains(t) { b.isEnabled = false; b.toolTip = "이미 이 데스크탑 막대가 있어요" }
            if x + b.frame.width > left + width { x = left + 4; y += 26 }
            b.setFrameOrigin(NSPoint(x: x, y: y))
            view.addSubview(b)
            view.keep.append(a)
            x += b.frame.width + 6
        }
        y += 30
    }

    deinit {}
}

/// 설정 화면 판 (위에서부터 쌓기) — 단추 동작들을 붙잡아 둠
final class FlippedForm: NSView {
    override var isFlipped: Bool { true }
    var keep: [AnyObject] = []
}

/// 단추 · 체크 · 슬라이더 하나의 동작
final class Act: NSObject {
    private let run: (Any) -> Void
    init(_ run: @escaping (Any) -> Void) { self.run = run }
    @objc func fire(_ sender: Any) { run(sender) }
}
