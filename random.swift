// 랜덤 재생목록 만들기: 가수를 고르고(비중 조절), 곡 수나 시간(분 · 시간)을 정하면 그 가수들의 인기곡에서 골라 새 재생목록으로 만들고 바로 재생
// - 가수 곡 목록: 가수 페이지의 '인기곡' 모두 보기 (같은 곡 다른 버전 · 1분 안 되는 짧은 클립은 뺌)
// - 비중: 가수마다 1 ~ 5. 곡을 하나 고를 때마다 비중만큼의 확률로 가수를 정하고, 그 가수 곡 중 아직 안 넣은 걸 고름
import Cocoa

struct ArtistHit: Equatable { let id: String; let name: String }
struct SongPick: Equatable { let title: String; let artist: String; let videoId: String; let secs: Int }

extension YTMusic {
    /// 가수 찾기 (이름으로)
    func searchArtists(_ q: String, done: @escaping ([ArtistHit]) -> Void) {
        runAPIPublic("""
        const isArtist = e => e && e.browseEndpoint && /^UC/.test(e.browseEndpoint.browseId || '') &&
          (((e.browseEndpoint.browseEndpointContextSupportedConfigs || {}).browseEndpointContextMusicConfig || {}).pageType === 'MUSIC_PAGE_TYPE_ARTIST');
        // 1) 자동완성(추천 검색어): 이름 앞부분만 쳐도 그 가수가 나옴 (검색은 낱말이 다 맞아야 나와서 'Pompa' 로는 Pompadolls 가 안 나왔음)
        const sg = await api('music/get_search_suggestions', {input: q});
        const firstSug = ((JSON.stringify(sg).match(/"searchSuggestionRenderer":\\{"suggestion":\\{"runs":\\[(.*?)\\]\\}/) || [])[1] || '')
          .replace(/.*?"text":"([^"]*)"/g, '$1');
        const r = await api('search', {query: q});
        const out = [], seen = new Set();
        const pushLinks = (o) => JSON.stringify(o, (k, x) => {
          if (x && typeof x === 'object' && typeof x.text === 'string' && x.navigationEndpoint && isArtist(x.navigationEndpoint)) {
            const id = x.navigationEndpoint.browseEndpoint.browseId; if (!seen.has(id)) { seen.add(id); out.push({id, name: x.text}); } }
          return x; });
        // 가수 줄 · 가수 카드만 (노래 · 앨범 줄에 붙은 가수 링크는 엉뚱한 이름이 섞여서 뺌)
        for (const v of collect(r, 'musicResponsiveListItemRenderer')) {
          if (!isArtist(v.navigationEndpoint)) continue;
          const id = v.navigationEndpoint.browseEndpoint.browseId;
          let name = ''; try { name = v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text; } catch (e) {}
          if (name && !seen.has(id)) { seen.add(id); out.push({id, name}); }
        }
        for (const v of collect(r, 'musicCardShelfRenderer')) {
          const t = v.title && v.title.runs && v.title.runs[0];
          if (!t || !isArtist(t.navigationEndpoint)) continue;
          const id = t.navigationEndpoint.browseEndpoint.browseId;
          if (!seen.has(id)) { seen.add(id); out.unshift({id, name: t.text}); }
        }
        // 자동완성에 나온 가수를 맨 앞에 (가수 줄 · 가수 링크 글자)
        const sugOut = [];
        for (const v of collect(sg, 'musicResponsiveListItemRenderer')) {
          let id = isArtist(v.navigationEndpoint) ? v.navigationEndpoint.browseEndpoint.browseId : null, name = '';
          if (id) { try { name = v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text; } catch (e) {} }
          else JSON.stringify(v, (k, x) => { if (!id && x && typeof x === 'object' && typeof x.text === 'string' && x.navigationEndpoint && isArtist(x.navigationEndpoint)) { id = x.navigationEndpoint.browseEndpoint.browseId; name = x.text; } return x; });
          if (id && name && !sugOut.some(a => a.id === id)) sugOut.push({id, name});
        }
        for (const a of sugOut.reverse()) { const i = out.findIndex(o => o.id === a.id); if (i >= 0) out.splice(i, 1); out.unshift(a); seen.add(a.id); }
        // 그래도 없으면 첫 추천 검색어로 한 번 더
        if (out.length === 0 && firstSug && firstSug.toLowerCase() !== q.toLowerCase()) {
          const r2 = await api('search', {query: firstSug});
          for (const v of collect(r2, 'musicResponsiveListItemRenderer')) {
            if (!isArtist(v.navigationEndpoint)) continue;
            const id = v.navigationEndpoint.browseEndpoint.browseId;
            let name = ''; try { name = v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text; } catch (e) {}
            if (name && !seen.has(id)) { seen.add(id); out.push({id, name}); }
          }
        }
        return JSON.stringify(out);
        """, ["q": q]) { v in
            guard let s = v as? String, let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { done([]); return }
            done(arr.compactMap { o in o["id"].map { ArtistHit(id: $0, name: o["name"] ?? "") } })
        }
    }

    /// 가수의 인기곡 전부 (같은 제목 · 1분 안 되는 클립은 뺌)
    func artistSongs(_ a: ArtistHit, done: @escaping ([SongPick]) -> Void) {
        runAPIPublic("""
        const r = await api('browse', {browseId: aid});
        let list = null;
        for (const sh of collect(r, 'musicShelfRenderer')) {
          const m = JSON.stringify(sh.bottomEndpoint || sh.title || {}).match(/"browseId":"(VL[^"]+)"/);
          if (m) { list = m[1]; break; }
        }
        const out = [];
        const secs = t => (t || '').split(':').reduce((a, x) => a * 60 + (parseInt(x) || 0), 0);
        const take = (o) => { for (const v of collect(o, 'musicResponsiveListItemRenderer')) {
          if (!v.playlistItemData) continue;
          const fx = v.fixedColumns && v.fixedColumns[0] && v.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
          out.push({t: v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text, v: v.playlistItemData.videoId,
                    s: fx ? secs(fx.text.runs[0].text) : 0});
        } };
        if (list) {
          let j = await api('browse', {browseId: list});
          for (let p = 0; p < 20; p++) { take(j); const tok = nextToken(j); if (!tok) break; j = await api('browse', {continuation: tok}); }
        } else take(r);
        return JSON.stringify(out);
        """, ["aid": a.id]) { v in
            guard let s = v as? String, let d = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { done([]); return }
            var seen = Set<String>()
            done(arr.compactMap { o in
                let t = o["t"] as? String ?? "", vid = o["v"] as? String ?? "", sec = o["s"] as? Int ?? 0
                // 같은 곡 다른 버전(괄호 뒤 · 대소문자) 하나만, 1분 안 되는 짧은 클립 · 시간 모르는 건 빼기
                let key = t.lowercased().replacingOccurrences(of: #"\s*[\(\[].*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                guard !vid.isEmpty, sec >= 60, seen.insert(key).inserted else { return nil }
                return SongPick(title: t, artist: a.name, videoId: vid, secs: sec)
            })
        }
    }

    /// playlists.swift 의 api 도우미를 다른 파일에서도 쓰게
    func runAPIPublic(_ body: String, _ args: [String: Any], done: @escaping (Any?) -> Void) {
        guard let wv = webView else { done(nil); return }
        wv.callAsyncJavaScript(Self.apiPrelude + body, arguments: args, in: nil, in: .page) { r in
            MainActor.assumeIsolated { if case .success(let v) = r { done(v) } else { done(nil) } }
        }
    }
}

/// 곡 고르기: 비중대로 가수를 뽑고, 그 가수의 아직 안 넣은 곡을 뽑음. 인기곡 위주면 목록 앞쪽일수록 잘 뽑힘
enum RandomMix {
    enum Limit { case count(Int), minutes(Int) }

    static func make(_ pools: [(songs: [SongPick], weight: Double)], limit: Limit, popular: Bool) -> [SongPick] {
        var left = pools.map { $0.songs }
        var out: [SongPick] = []
        var total = 0
        func done() -> Bool {
            switch limit {
            case .count(let n): return out.count >= n
            case .minutes(let m): return total >= m * 60
            }
        }
        while !done() {
            let avail = left.indices.filter { !left[$0].isEmpty && pools[$0].weight > 0 }
            guard !avail.isEmpty else { break }
            let sum = avail.reduce(0) { $0 + pools[$1].weight }
            var r = Double.random(in: 0..<sum)
            var pick = avail[0]
            for i in avail { r -= pools[i].weight; if r < 0 { pick = i; break } }
            // 인기곡 위주: 앞쪽(인기 많은 곡)에 무게
            let n = left[pick].count
            let idx: Int
            if popular {
                let w = (0..<n).map { 1.0 / Double($0 + 3) }
                var x = Double.random(in: 0..<w.reduce(0, +)); var k = 0
                for (j, wj) in w.enumerated() { x -= wj; if x < 0 { k = j; break } }
                idx = k
            } else { idx = Int.random(in: 0..<n) }
            let s = left[pick].remove(at: idx)
            // 시간 기준: 넣으면 목표를 5분 넘게 넘어가는 곡은 건너뜀 (마지막에 너무 길어지지 않게)
            if case .minutes(let m) = limit, total + s.secs > m * 60 + 300, total > 0 { continue }
            out.append(s); total += s.secs
        }
        // 같은 가수가 연달아 너무 몰리지 않게 한 번 섞음
        return out.shuffled()
    }

    static func describe(_ s: [SongPick]) -> String {
        let secs = s.reduce(0) { $0 + $1.secs }
        let h = secs / 3600, m = secs % 3600 / 60
        return "\(s.count)곡 · " + (h > 0 ? "\(h)시간 \(m)분" : "\(m)분")
    }
}

// MARK: - 창

@MainActor
final class RandomPlaylistWindow: NSObject, NSWindowDelegate {
    static let shared = RandomPlaylistWindow()
    private var panel: NSPanel?
    private weak var music: YTMusic?
    var onCreated: ((String) -> Void)?

    private struct Pick { let artist: ArtistHit; var weight: Double; var songs: [SongPick]?; }
    private var picks: [Pick] = []

    private let search = NSSearchField()
    private let results = NSPopUpButton()
    private let list = FlippedView()
    private let listScroll = NSScrollView()
    private let mode = NSSegmentedControl(labels: ["곡 수", "시간"], trackingMode: .selectOne, target: nil, action: nil)
    private let amount = NSTextField()
    private let unit = NSPopUpButton()
    private let popular = NSButton(checkboxWithTitle: "인기곡 위주", target: nil, action: nil)
    private let name = NSTextField()
    /// 어디에: 맨 위 '새 재생목록', 그 아래 내 재생목록들 (고르면 거기에 덧붙임)
    private let target = NSPopUpButton()
    private var myLists: [PlaylistInfo] = []
    private let makeBtn = NSButton(title: "만들고 재생", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var hits: [ArtistHit] = []

    func show(music: YTMusic?, start: ArtistHit? = nil) {
        self.music = music
        if panel == nil { build() }
        loadTargets()
        if let a = start, !picks.contains(where: { $0.artist.id == a.id }) { add(a) }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let W: CGFloat = 440, H: CGFloat = 470
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.title = "랜덤 재생목록 만들기"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.delegate = self
        p.center()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        func label(_ t: String, y: CGFloat, bold: Bool = true) {
            let l = NSTextField(labelWithString: t)
            l.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 11)
            l.textColor = bold ? .labelColor : .secondaryLabelColor
            l.frame = NSRect(x: 16, y: y, width: W - 32, height: 16)
            v.addSubview(l)
        }
        label("① 가수 고르기", y: H - 32)
        search.placeholderString = "가수 이름으로 찾기 (엔터)"
        search.target = self; search.action = #selector(doSearch)
        search.sendsSearchStringImmediately = false
        search.frame = NSRect(x: 16, y: H - 62, width: 200, height: 24)
        v.addSubview(search)
        results.target = self; results.action = #selector(pickResult)
        results.frame = NSRect(x: 222, y: H - 63, width: W - 238, height: 26)
        results.addItem(withTitle: "찾은 가수가 여기 나와요")
        results.isEnabled = false
        v.addSubview(results)
        label("가수마다 비중: 많이 듣고 싶은 가수일수록 크게 (1 ~ 5)", y: H - 84, bold: false)
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listScroll.frame = NSRect(x: 12, y: 206, width: W - 24, height: H - 84 - 206 - 6)
        v.addSubview(listScroll)

        label("② 얼마나", y: 176)
        mode.selectedSegment = 0
        mode.target = self; mode.action = #selector(modeChanged)
        mode.frame = NSRect(x: 16, y: 146, width: 120, height: 24)
        v.addSubview(mode)
        amount.stringValue = "30"
        amount.alignment = .right
        amount.frame = NSRect(x: 146, y: 147, width: 60, height: 22)
        v.addSubview(amount)
        unit.frame = NSRect(x: 212, y: 145, width: 90, height: 26)
        v.addSubview(unit)
        modeChanged()
        popular.state = .on
        popular.toolTip = "켜면 많이 들은 곡이 더 자주 뽑혀요 · 끄면 모든 곡이 같은 확률"
        popular.frame = NSRect(x: 310, y: 148, width: 120, height: 20)
        v.addSubview(popular)

        label("③ 어디에", y: 112)
        target.target = self; target.action = #selector(targetChanged)
        target.frame = NSRect(x: 14, y: 80, width: 170, height: 26)
        v.addSubview(target)
        let f = DateFormatter(); f.dateFormat = "M월 d일"
        name.stringValue = "랜덤 · \(f.string(from: Date()))"
        name.placeholderString = "새 재생목록 이름"
        name.frame = NSRect(x: 190, y: 82, width: W - 206, height: 24)
        v.addSubview(name)

        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 52, width: W - 32, height: 16)
        v.addSubview(status)
        makeBtn.bezelStyle = .rounded
        makeBtn.keyEquivalent = "\r"
        makeBtn.target = self; makeBtn.action = #selector(make)
        makeBtn.frame = NSRect(x: W - 16 - 130, y: 14, width: 130, height: 30)
        v.addSubview(makeBtn)
        let hint = NSTextField(labelWithString: "내 유튜브 뮤직 계정에 '나만 보기' 재생목록으로 만들어요")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 16, y: 22, width: W - 170, height: 14)
        v.addSubview(hint)
        p.contentView = v
        panel = p
        relist()
    }

    /// '어디에' 칸 채우기: 새 재생목록 + 내 재생목록들
    private func loadTargets() {
        let keep = target.indexOfSelectedItem > 0 ? myLists[safe: target.indexOfSelectedItem - 2]?.id : nil
        target.removeAllItems()
        target.addItem(withTitle: "새 재생목록 만들기")
        music?.myPlaylists { [weak self] ls in
            guard let self else { return }
            self.myLists = ls.filter { !PlaylistPane.recentlyDeleted.contains($0.id) }
            self.target.removeAllItems()
            self.target.addItem(withTitle: "새 재생목록 만들기")
            if !self.myLists.isEmpty { self.target.menu?.addItem(.separator()) }
            for l in self.myLists { self.target.menu?.addItem(NSMenuItem(title: "‘\(l.title)’에 덧붙이기", action: nil, keyEquivalent: "")) }
            if let k = keep, let i = self.myLists.firstIndex(where: { $0.id == k }) { self.target.selectItem(at: i + 2) }
            self.targetChanged()
        }
    }
    @objc private func targetChanged() {
        let new = target.indexOfSelectedItem <= 0
        name.isEnabled = new
        name.alphaValue = new ? 1 : 0.4
        makeBtn.title = new ? "만들고 재생" : "덧붙이고 재생"
        // 기존 재생목록을 고르면 그 목록에 든 가수들을 비중(곡 수 비율)대로 불러옴
        if !new, let pl = myLists[safe: target.indexOfSelectedItem - 2], pl.id != loadedFrom { loadArtists(of: pl) }
    }

    /// 이미 불러온 재생목록 (같은 걸 다시 고르면 또 불러오지 않게)
    private var loadedFrom = ""
    private func loadArtists(of pl: PlaylistInfo) {
        loadedFrom = pl.id
        status.stringValue = "‘\(pl.title)’에 든 가수 불러오는 중…"
        music?.playlistTracks(pl.id) { [weak self] ts in
            guard let self, let ts else { return }
            // 가수별 곡 수 (가수 링크 있는 곡만, 많은 순)
            var count: [String: (name: String, n: Int)] = [:]
            for t in ts where !t.artistId.isEmpty {
                let name = t.artist.components(separatedBy: " • ").first?.components(separatedBy: " & ").first ?? t.artist
                count[t.artistId, default: (name, 0)].n += 1
            }
            let sorted = count.sorted { $0.value.n > $1.value.n }
            guard let top = sorted.first?.value.n else { self.relist(); return }
            for (id, v) in sorted {
                // 비중: 가장 많은 가수를 5로 놓고 곡 수 비율대로 (최소 1)
                let w = max(1, (5 * Double(v.n) / Double(top)).rounded())
                if let i = self.picks.firstIndex(where: { $0.artist.id == id }) { self.picks[i].weight = w }
                else { self.add(ArtistHit(id: id, name: v.name), weight: w) }
            }
            self.relist()
            self.status.stringValue = "‘\(pl.title)’의 가수 \(sorted.count)명을 곡 수 비율대로 불러왔어요"
        }
    }

    @objc private func modeChanged() {
        unit.removeAllItems()
        if mode.selectedSegment == 0 { unit.addItem(withTitle: "곡"); if Int(amount.stringValue) ?? 0 > 500 { amount.stringValue = "30" } }
        else { unit.addItems(withTitles: ["분", "시간"]); unit.selectItem(withTitle: "시간"); amount.stringValue = "1" }
    }

    @objc private func doSearch() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        results.removeAllItems(); results.addItem(withTitle: "찾는 중…"); results.isEnabled = false
        music?.searchArtists(q) { [weak self] hs in
            guard let self else { return }
            self.hits = hs
            self.results.removeAllItems()
            if hs.isEmpty { self.results.addItem(withTitle: "찾지 못했어요"); return }
            self.results.addItem(withTitle: "\(hs.count)명 찾음 — 골라서 넣기")
            for h in hs { self.results.menu?.addItem(NSMenuItem(title: h.name, action: nil, keyEquivalent: "")) }
            self.results.isEnabled = true
            // 저절로 넣지 않고, 찾은 목록을 펼쳐서 직접 고르게 (이름이 딱 맞는 가수를 맨 위 칸에 미리 가리킴)
            let exact = hs.firstIndex(where: { $0.name.lowercased() == q.lowercased() })
            DispatchQueue.main.async {
                if let i = exact { self.results.selectItem(at: i + 1) }
                self.results.performClick(nil)
            }
        }
    }
    @objc private func pickResult() {
        let i = results.indexOfSelectedItem - 1
        guard hits.indices.contains(i) else { return }
        add(hits[i])
        results.selectItem(at: 0)
    }

    private func add(_ a: ArtistHit, weight: Double = 3) {
        guard !picks.contains(where: { $0.artist.id == a.id }) else { return }
        picks.append(Pick(artist: a, weight: weight, songs: nil))
        relist()
        music?.artistSongs(a) { [weak self] songs in
            guard let self, let i = self.picks.firstIndex(where: { $0.artist.id == a.id }) else { return }
            self.picks[i].songs = songs
            self.relist()
        }
    }

    /// 고른 가수 줄: 이름 · 곡 수 · 비중 슬라이더 · ✕
    private func relist() {
        list.subviews.forEach { $0.removeFromSuperview() }
        let w = listScroll.contentSize.width, rh: CGFloat = 34
        for (i, p) in picks.enumerated() {
            let y = CGFloat(i) * rh
            let n = NSTextField(labelWithString: p.artist.name)
            n.font = .systemFont(ofSize: 12.5, weight: .medium); n.lineBreakMode = .byTruncatingTail
            n.frame = NSRect(x: 6, y: y + 4, width: 150, height: 17)
            list.addSubview(n)
            let c = NSTextField(labelWithString: p.songs.map { $0.isEmpty ? "곡을 못 찾음" : "\($0.count)곡" } ?? "불러오는 중…")
            c.font = .systemFont(ofSize: 10.5); c.textColor = .secondaryLabelColor
            c.frame = NSRect(x: 6, y: y + 19, width: 150, height: 13)
            list.addSubview(c)
            let s = NSSlider(value: p.weight, minValue: 1, maxValue: 5, target: self, action: #selector(weightChanged(_:)))
            s.numberOfTickMarks = 5; s.allowsTickMarkValuesOnly = true
            s.controlSize = .small
            s.tag = i
            s.frame = NSRect(x: 160, y: y + 6, width: w - 160 - 70, height: 20)
            list.addSubview(s)
            let pct = NSTextField(labelWithString: "\(Int((p.weight / max(1, picks.reduce(0) { $0 + $1.weight }) * 100).rounded()))%")
            pct.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold); pct.alignment = .right
            pct.frame = NSRect(x: w - 66, y: y + 8, width: 36, height: 15)
            list.addSubview(pct)
            let x = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "빼기")!, target: self, action: #selector(removePick(_:)))
            x.isBordered = false; x.contentTintColor = .tertiaryLabelColor; x.tag = i
            x.frame = NSRect(x: w - 26, y: y + 7, width: 18, height: 18)
            list.addSubview(x)
        }
        if picks.isEmpty {
            let e = NSTextField(labelWithString: "위에서 가수를 찾아 넣어 주세요")
            e.font = .systemFont(ofSize: 12); e.textColor = .tertiaryLabelColor; e.alignment = .center
            e.frame = NSRect(x: 0, y: 40, width: w, height: 18)
            list.addSubview(e)
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(listScroll.contentSize.height, CGFloat(picks.count) * rh))
        let ready = picks.compactMap { $0.songs }.reduce(0) { $0 + $1.count }
        status.stringValue = picks.isEmpty ? "" : "고를 수 있는 곡 \(ready)개"
        makeBtn.isEnabled = ready > 0
    }
    @objc private func weightChanged(_ s: NSSlider) { picks[s.tag].weight = s.doubleValue.rounded(); relist() }
    @objc private func removePick(_ b: NSButton) { picks.remove(at: b.tag); relist() }

    @objc private func make() {
        let n = max(1, Int(amount.stringValue) ?? 0)
        let limit: RandomMix.Limit = mode.selectedSegment == 0 ? .count(min(n, 500)) : .minutes(unit.titleOfSelectedItem == "시간" ? min(n, 24) * 60 : min(n, 1440))
        let pools = picks.compactMap { p in p.songs.map { (songs: $0, weight: p.weight) } }
        let mix = RandomMix.make(pools, limit: limit, popular: popular.state == .on)
        guard !mix.isEmpty else { status.stringValue = "곡을 고르지 못했어요"; return }
        let title = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "랜덤 재생목록" : name.stringValue
        makeBtn.isEnabled = false
        // 기존 재생목록에 덧붙이기
        if target.indexOfSelectedItem > 1, let pl = myLists[safe: target.indexOfSelectedItem - 2] {
            status.stringValue = "‘\(pl.title)’에 덧붙이는 중… (\(RandomMix.describe(mix)))"
            music?.addToPlaylist(pl.id, videoIds: mix.map(\.videoId)) { [weak self] ok in
                guard let self else { return }
                self.makeBtn.isEnabled = true
                guard ok else { self.status.stringValue = "덧붙이지 못했어요"; return }
                self.status.stringValue = "‘\(pl.title)’에 덧붙였어요 · \(RandomMix.describe(mix)) (이미 있던 곡은 건너뜀)"
                PlaylistPane.selectedId = pl.id
                // 서버에 반영되기 전에 틀면 덧붙인 곡이 빠진 채로 시작해서 조금 기다렸다가
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.music?.playList(pl.id) }
                self.onCreated?(pl.id)
                self.panel?.orderOut(nil)
            }
            return
        }
        status.stringValue = "만드는 중… (\(RandomMix.describe(mix)))"
        music?.createPlaylist(title, videoIds: mix.map(\.videoId)) { [weak self] id in
            guard let self else { return }
            self.makeBtn.isEnabled = true
            guard let id else { self.status.stringValue = "만들지 못했어요 (로그인 확인)"; return }
            self.status.stringValue = "‘\(title)’ 만들었어요 · \(RandomMix.describe(mix))"
            PlaylistPane.selectedId = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.music?.playList(id) }
            self.onCreated?(id)
            self.panel?.orderOut(nil)
        }
    }
}
