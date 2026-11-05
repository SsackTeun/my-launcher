// 가사 발음: 일본어 → 로마자 / 한글 발음, 중국어 → 병음. 모두 macOS 내장 기능으로 기기 안에서 만듦
import Foundation

enum Pronounce {
    enum Style: String, CaseIterable { case off, latin, hangul }

    static func hasKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }
    static func hasHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// 한 줄의 발음. 원문 언어(ja · zh)와 표시 방식에 따라. 해당 없으면 nil
    static func line(_ text: String, lang: String, style: Style) -> String? {
        guard style != .off else { return nil }
        if lang.hasPrefix("ja"), hasKana(text) || hasHan(text) {
            let tokens = japaneseTokens(text)
            var parts: [String] = []
            var pendingTsu = false      // 앞 낱말이 っ 로 끝남 → 이번 낱말 첫 자음을 앞에 겹침
            for tk in tokens {
                // 조사 は · へ · を 는 실제 발음대로 (와 · 에 · 오)
                let particle: (String, String)? = ["は": ("wa", "와"), "へ": ("e", "에"), "を": ("o", "오")][tk.surface]
                var p: String
                switch style {
                case .latin: p = particle?.0 ?? fixLatin(tk.latin)
                case .hangul: p = particle?.1 ?? (tk.kana.map(kanaToHangul) ?? tk.latin)
                case .off: return nil
                }
                // ん · っ 이 따로 떨어진 낱말이면 앞 낱말에 붙임
                if tk.surface == "ん" || tk.surface == "ン", var last = parts.popLast() {
                    if style == .hangul { if !addFinal(&last, 4) { last += "응" } } else { last += "n" }
                    p = ""
                    parts.append(last)
                }
                if style == .latin, pendingTsu, let c = p.first, "bcdfghjkmnpqrstvwxyz".contains(c.lowercased()), var last = parts.popLast() {
                    last += String(c)
                    parts.append(last)
                }
                pendingTsu = tk.latin.hasSuffix("~tsu")
                if !p.isEmpty { parts.append(p) }
            }
            return join(parts)
        }
        if lang.hasPrefix("zh") || (hasHan(text) && !hasKana(text)) {
            guard hasHan(text) else { return nil }
            // 중국어: 로마자면 성조 붙은 병음, 한글이면 병음을 한글로
            let m = NSMutableString(string: text)
            CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
            let pinyin = m as String
            return style == .latin ? pinyin : pinyinToHangul(pinyin)
        }
        // 그 밖에 라틴 문자가 아닌 글자(키릴 · 태국 · 그리스 · 아랍 · 히브리 · 힌디 · 한글 …): 로마자로.
        // 한글 발음 방식은 이 언어들엔 없어서 로마자로 대신 (원래 한글인 가사는 그대로 둠)
        guard hasNonLatinLetters(text) else { return nil }
        if style == .hangul, isMostlyHangul(text) { return nil }
        let out = readableLatin(text)
        return out == text ? nil : out
    }

    /// 읽기 쉬운 로마자: 러시아어 등 키릴 문자는 영어식 표기(BGN), 나머지는 일반 로마자 뒤 기호 빼기
    static func readableLatin(_ text: String) -> String {
        let m = NSMutableString(string: text)
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        if cyrillic, CFStringTransform(m, nil, "Russian-Latin/BGN" as CFString, false) {
            // 됨
        } else {
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        }
        // 학술용 기호(â · ṭ · ạ̉ …)를 빼서 바로 읽을 수 있게
        CFStringTransform(m, nil, "Latin-ASCII" as CFString, false)
        // 키릴 Я → YA 처럼 두 글자가 모두 대문자가 되면 Ya 로
        let words = (m as String).replacingOccurrences(of: "  ", with: " ").components(separatedBy: " ")
        return words.map { w in
            (w.count == 2 && w == w.uppercased() && w != w.lowercased()) ? w.prefix(1) + w.dropFirst().lowercased() : w
        }.joined(separator: " ")
    }

    static func hasNonLatinLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.letters.contains($0) && !($0.isASCII || (0x00C0...0x024F).contains($0.value) || (0x1E00...0x1EFF).contains($0.value)) }
    }

    static func isMostlyHangul(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let hangul = letters.filter { (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
        return hangul.count * 2 >= letters.count
    }

    // MARK: 중국어 병음 → 한글 발음 (zhōng guó → 중궈)

    /// 성모 → 한글 초성 번호 (ㄱ0 ㄲ1 ㄴ2 ㄷ3 ㄸ4 ㄹ5 ㅁ6 ㅂ7 ㅃ8 ㅅ9 ㅆ10 ㅇ11 ㅈ12 ㅉ13 ㅊ14 ㅋ15 ㅌ16 ㅍ17 ㅎ18)
    private static let initials: [(String, Int)] = [
        ("zh", 12), ("ch", 14), ("sh", 9),
        ("b", 7), ("p", 17), ("m", 6), ("f", 17), ("d", 3), ("t", 16), ("n", 2), ("l", 5),
        ("g", 0), ("k", 15), ("h", 18), ("j", 12), ("q", 14), ("x", 9), ("r", 5), ("z", 13), ("c", 14), ("s", 10),
    ]
    /// 운모 → 한글 (ㅇ으로 시작, 앞 글자에 성모를 얹음)
    private static let finals: [String: String] = [
        "a": "아", "o": "오", "e": "어", "ai": "아이", "ei": "에이", "ao": "아오", "ou": "어우",
        "an": "안", "en": "언", "ang": "앙", "eng": "엉", "ong": "웅", "er": "얼",
        "i": "이", "ia": "야", "ie": "예", "iao": "야오", "iu": "유", "iou": "유", "ian": "옌", "in": "인",
        "iang": "양", "ing": "잉", "iong": "융",
        "u": "우", "ua": "와", "uo": "워", "uai": "와이", "ui": "웨이", "uei": "웨이", "uan": "완", "un": "운",
        "uen": "원", "uang": "왕", "ueng": "웡",
        "v": "위", "ve": "웨", "van": "위안", "vn": "윈",
    ]
    /// y · w 로 시작하는 음절은 표준 운모로 바꿔서
    private static let yw: [String: String] = [
        "yi": "i", "ya": "ia", "ye": "ie", "yao": "iao", "you": "iu", "yan": "ian", "yin": "in",
        "yang": "iang", "ying": "ing", "yong": "iong", "yu": "v", "yue": "ve", "yuan": "van", "yun": "vn",
        "wu": "u", "wa": "ua", "wo": "uo", "wai": "uai", "wei": "ui", "wan": "uan", "wen": "uen",
        "wang": "uang", "weng": "ueng",
    ]

    static func pinyinSyllableToHangul(_ syl: String) -> String? {
        let s0 = syl.lowercased()
        if let f = yw[s0] { return finals[f] }
        var cho = 11
        var rest = s0
        for (ini, c) in initials where s0.hasPrefix(ini) && s0.count > ini.count {
            cho = c
            rest = String(s0.dropFirst(ini.count))
            let ini0 = ini
            // j · q · x 뒤의 u 는 ü
            if ["j", "q", "x"].contains(ini0), rest.hasPrefix("u") { rest = "v" + rest.dropFirst() }
            // zh · ch · sh · r · z · c · s 뒤의 i 는 '으' 소리 (즈 · 츠 · 스 · 르 · 쯔 · 쓰)
            if ["zh", "ch", "sh", "r", "z", "c", "s"].contains(ini0), rest == "i" {
                return compose(cho, jung: 18, jong: 0).map { String($0) }
            }
            guard let fin = finals[rest], var scalars = Optional(Array(fin.unicodeScalars)), let first = scalars.first else { return nil }
            let idx = Int(first.value) - 0xAC00
            var jung = (idx / 28) % 21
            let jong = idx % 28
            // j · q 뒤에서는 ㅑㅕㅛㅠㅒㅖ 를 ㅏㅓㅗㅜㅐㅔ 로 (jia 자 · jiu 주 · qian 첸)
            if ["j", "q"].contains(ini0) {
                jung = [2: 0, 3: 1, 6: 4, 7: 5, 12: 8, 17: 13][jung] ?? jung
            }
            guard let c = compose(cho, jung: jung, jong: jong) else { return nil }
            scalars[0] = c
            var out = String.UnicodeScalarView()
            out.append(contentsOf: scalars)
            return String(out)
        }
        return cho == 11 ? finals[rest] : nil
    }

    private static func compose(_ cho: Int, jung: Int, jong: Int) -> Unicode.Scalar? {
        Unicode.Scalar(UInt32(0xAC00 + (cho * 21 + jung) * 28 + jong))
    }

    static func pinyinToHangul(_ pinyin: String) -> String {
        // ü 를 v 로 바꾼 뒤 성조 표시를 지움 (lǚ → lv)
        // 글자 단위로 비교해야 uā · uó 같은 다른 글자가 같이 바뀌지 않음
        let uu: Set<Character> = ["ǖ", "ǘ", "ǚ", "ǜ", "ü"]
        let p = String(pinyin.precomposedStringWithCanonicalMapping.map { uu.contains($0) ? "v" : $0 })
        let m = NSMutableString(string: p)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let words = (m as String).components(separatedBy: " ")
        return words.map { w -> String in
            // 문장부호가 붙어 있으면 떼어서
            let core = w.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard !core.isEmpty, let h = pinyinSyllableToHangul(core) else { return w }
            return w.replacingOccurrences(of: core, with: h)
        }.joined(separator: " ")
    }

    // MARK: 일본어 읽기

    struct Token { let surface: String; let latin: String; let kana: String? }

    /// 로마자 다듬기: 작은 っ("~tsu")는 다음 자음을 겹쳐서 (dara~tsu to → darat to)
    static func fixLatin(_ s: String) -> String {
        var r = s.replacingOccurrences(of: #"~tsu(\s*)([bcdfghjkmnpqrstvwxyz])"#, with: "$2$1$2", options: [.regularExpression, .caseInsensitive])
        r = r.replacingOccurrences(of: "~tsu", with: "")
        r = r.replacingOccurrences(of: "~", with: "")
        return r
    }

    /// 낱말마다 읽기(로마자)와 히라가나. 한자는 macOS 일본어 분석기가 읽는 법을 알려 줌
    static func japaneseTokens(_ text: String) -> [Token] {
        let cf = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        let tok = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var out: [Token] = []
        var t = CFStringTokenizerAdvanceToNextToken(tok)
        while t != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let piece = (text as NSString).substring(with: NSRange(location: r.location, length: r.length))
            if piece.trimmingCharacters(in: .whitespaces).isEmpty {
                t = CFStringTokenizerAdvanceToNextToken(tok); continue
            }
            if hasKana(piece) || hasHan(piece) {
                var latin = (CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String) ?? ""
                if latin.isEmpty {
                    let m = NSMutableString(string: piece)
                    CFStringTransform(m, nil, kCFStringTransformToLatin, false)
                    latin = m as String
                }
                // 히라가나: 가나만 있으면 그대로, 한자가 섞였으면 로마자 읽기에서 되돌림
                let kana: String
                if !hasHan(piece) {
                    let m = NSMutableString(string: piece)
                    CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)   // 가타카나 → 히라가나
                    kana = m as String
                } else {
                    let m = NSMutableString(string: latin)
                    CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
                    kana = m as String
                }
                out.append(Token(surface: piece, latin: latin, kana: kana))
            } else {
                out.append(Token(surface: piece, latin: piece, kana: nil))   // 영어 · 숫자 · 문장부호는 그대로
            }
            t = CFStringTokenizerAdvanceToNextToken(tok)
        }
        return out
    }

    /// 낱말 사이는 띄우고, 문장부호 앞은 붙이고, 여는 따옴표·괄호 뒤도 붙임
    static func join(_ parts: [String]) -> String {
        let opening: Set<String> = ["“", "「", "『", "(", "（", "【", "‘", "["]
        var s = ""
        var quoteOpen = false
        var glueNext = false
        for p in parts where !p.isEmpty {
            let isPunct = p.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            if p == "\"" {
                // " 는 여는 쪽이면 앞을 띄우고 뒤를 붙임, 닫는 쪽이면 앞을 붙임
                if quoteOpen { s += p } else { s += s.isEmpty ? p : " " + p; glueNext = true }
                quoteOpen.toggle()
                continue
            }
            if s.isEmpty || glueNext || (isPunct && !opening.contains(p)) { s += p }
            else { s += " " + p }
            glueNext = opening.contains(p)
        }
        return s
    }

    // MARK: 가나 → 한글 발음

    private static let single: [Character: String] = [
        "あ": "아", "い": "이", "う": "우", "え": "에", "お": "오",
        "か": "카", "き": "키", "く": "쿠", "け": "케", "こ": "코",
        "が": "가", "ぎ": "기", "ぐ": "구", "げ": "게", "ご": "고",
        "さ": "사", "し": "시", "す": "스", "せ": "세", "そ": "소",
        "ざ": "자", "じ": "지", "ず": "즈", "ぜ": "제", "ぞ": "조",
        "た": "타", "ち": "치", "つ": "츠", "て": "테", "と": "토",
        "だ": "다", "ぢ": "지", "づ": "즈", "で": "데", "ど": "도",
        "な": "나", "に": "니", "ぬ": "누", "ね": "네", "の": "노",
        "は": "하", "ひ": "히", "ふ": "후", "へ": "헤", "ほ": "호",
        "ば": "바", "び": "비", "ぶ": "부", "べ": "베", "ぼ": "보",
        "ぱ": "파", "ぴ": "피", "ぷ": "푸", "ぺ": "페", "ぽ": "포",
        "ま": "마", "み": "미", "む": "무", "め": "메", "も": "모",
        "や": "야", "ゆ": "유", "よ": "요",
        "ら": "라", "り": "리", "る": "루", "れ": "레", "ろ": "로",
        "わ": "와", "ゐ": "이", "ゑ": "에", "を": "오", "ゔ": "부",
        "ぁ": "아", "ぃ": "이", "ぅ": "우", "ぇ": "에", "ぉ": "오",
        "ゃ": "야", "ゅ": "유", "ょ": "요", "ゎ": "와",
    ]
    /// 두 글자 묶음 (きゃ · ふぁ · てぃ …)
    private static let pairs: [String: String] = [
        "きゃ": "캬", "きゅ": "큐", "きょ": "쿄", "ぎゃ": "갸", "ぎゅ": "규", "ぎょ": "교",
        "しゃ": "샤", "しゅ": "슈", "しょ": "쇼", "しぇ": "셰", "じゃ": "자", "じゅ": "주", "じょ": "조", "じぇ": "제",
        "ちゃ": "차", "ちゅ": "추", "ちょ": "초", "ちぇ": "체", "ぢゃ": "자", "ぢゅ": "주", "ぢょ": "조",
        "にゃ": "냐", "にゅ": "뉴", "にょ": "뇨", "ひゃ": "햐", "ひゅ": "휴", "ひょ": "효",
        "びゃ": "뱌", "びゅ": "뷰", "びょ": "뵤", "ぴゃ": "퍄", "ぴゅ": "퓨", "ぴょ": "표",
        "みゃ": "먀", "みゅ": "뮤", "みょ": "묘", "りゃ": "랴", "りゅ": "류", "りょ": "료",
        "ふぁ": "화", "ふぃ": "휘", "ふぇ": "훼", "ふぉ": "훠", "ふゅ": "퓨",
        "てぃ": "티", "でぃ": "디", "とぅ": "투", "どぅ": "두", "てゅ": "튜", "でゅ": "듀",
        "うぃ": "위", "うぇ": "웨", "うぉ": "워", "つぁ": "차", "つぇ": "체", "つぉ": "초",
        "ゔぁ": "바", "ゔぃ": "비", "ゔぇ": "베", "ゔぉ": "보", "いぇ": "예",
    ]

    /// 앞 글자에 받침 붙이기 (ㄴ=4, ㅅ=19)
    static func addFinal(_ s: inout String, _ jong: UInt32) -> Bool {
        guard let last = s.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value),
              (last.value - 0xAC00) % 28 == 0, let new = Unicode.Scalar(last.value + jong) else { return false }
        s.unicodeScalars.removeLast()
        s.unicodeScalars.append(new)
        return true
    }

    static func kanaToHangul(_ kana: String) -> String {
        let m = NSMutableString(string: kana)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)   // 가타카나도 히라가나로
        let chars = Array(m as String)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if i + 1 < chars.count, let p = pairs[String([c, chars[i + 1]])] {
                out += p; i += 2; continue
            }
            switch c {
            case "っ", "ッ":
                if !addFinal(&out, 19) { }          // 작은 つ: 앞 글자에 ㅅ 받침
            case "ん", "ン":
                if !addFinal(&out, 4) { out += "응" } // ん: 앞 글자에 ㄴ 받침
            case "ー", "〜", "～":
                break                                // 길게 늘이는 표시는 생략
            default:
                out += single[c].map { $0 } ?? String(c)
            }
            i += 1
        }
        return out
    }
}
