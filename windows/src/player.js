// 미니 플레이어 + 가사 (도구함 창 · 떼어 낸 플레이어 · 가사 창이 같이 씀)
// - 곡 정보 · 조작: Windows 미디어 컨트롤 (YouTube Music · Spotify · 브라우저 등 무엇이든)
// - 가사: LRCLIB (시간 붙은 가사면 노래 따라 지금 줄 강조)
// - 번역 · 발음: Google 번역 (인터넷, 켤 때만 가사 글자를 보냄) — Mac 판의 Apple 번역 대신
"use strict";

const PI = {
  play: '<svg viewBox="0 0 16 16"><path d="M5 3.5v9l7.5-4.5z" fill="currentColor"/></svg>',
  pause: '<svg viewBox="0 0 16 16"><rect x="4" y="3.5" width="3" height="9" rx=".8" fill="currentColor"/><rect x="9" y="3.5" width="3" height="9" rx=".8" fill="currentColor"/></svg>',
  next: '<svg viewBox="0 0 16 16"><path d="M3 4v8l6-4zM9 4v8l6-4z" fill="currentColor"/></svg>',
  prev: '<svg viewBox="0 0 16 16"><path d="M13 4v8L7 8zM7 4v8L1 8z" fill="currentColor"/></svg>',
  shuffle: '<svg viewBox="0 0 16 16"><path d="M2 4.5h2.5c3 0 4 7 7 7H14M2 11.5h2.5c1.2 0 2-1 2.7-2.3M9 6.5c.6-1.1 1.4-2 2.5-2H14M12 2.5l2 2-2 2M12 9.5l2 2-2 2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  repeat: '<svg viewBox="0 0 16 16"><path d="M3 7V6a2 2 0 012-2h8M11 2l2 2-2 2M13 9v1a2 2 0 01-2 2H3M5 14l-2-2 2-2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  vol: '<svg viewBox="0 0 16 16"><path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor"/><path d="M10.5 5.5a3.5 3.5 0 010 5M12.5 3.5a6 6 0 010 9" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  mute: '<svg viewBox="0 0 16 16"><path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor"/><path d="M10.5 6l4 4M14.5 6l-4 4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  lyrics: '<svg viewBox="0 0 16 16"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/><path d="M5 6h6M5 8h4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>',
  detach: '<svg viewBox="0 0 16 16"><rect x="2" y="5" width="9" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 2h7a1 1 0 011 1v7" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>',
  big: '<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="6" height="6" rx="1" fill="currentColor"/><path d="M9.5 3.5h5M9.5 6.5h5M1.5 11h13M1.5 13.5h9" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  heart: '<svg viewBox="0 0 16 16"><path d="M8 13.5S2 10 2 6a3 3 0 016-1 3 3 0 016 1c0 4-6 7.5-6 7.5z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
  yt: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6.5 5.5v5l4-2.5z" fill="currentColor"/></svg>',
  up: '<svg viewBox="0 0 16 16"><path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  down: '<svg viewBox="0 0 16 16"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};

/// 번역할 언어 (코드, 이름)
const LANGS = [["", "번역 안 함"], ["ko", "한국어"], ["en", "English"], ["ja", "日本語"], ["zh-CN", "中文(简体)"], ["zh-TW", "中文(繁體)"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"], ["vi", "Tiếng Việt"], ["th", "ไทย"], ["id", "Bahasa Indonesia"]];

const Player = (() => {
  let st = { has: false };
  /// 이 재생기만 보기 (크게 보기 창 = "ytmusic"), null 이면 미니 플레이어처럼 ‹ › 재생기
  let fixedSite = null;
  let cfg = {};
  let thumb = "";
  let trackKey = "";
  let polledAt = 0;
  let ytOpen = false;
  let hear = null;
  const subs = [];
  const lyr = { key: "", status: "", synced: false, lines: [], trans: [], roman: [], pron: [], lang: "" };

  const notify = () => subs.forEach((f) => f());
  const pos = () => (st.playing ? Math.min(st.duration || Infinity, st.position + (Date.now() - polledAt) / 1000) : st.position || 0);

  async function poll() {
    let s;
    try { s = await invoke("media_state", fixedSite ? { site: fixedSite } : {}); } catch { return; }
    st = s; polledAt = Date.now();
    const key = s.has ? `${s.title}\u0000${s.artist}` : "";
    if (key !== trackKey) {
      trackKey = key;
      thumb = "";
      if (s.has) {
        // 앨범 사진은 곡이 바뀐 뒤 앱이 조금 늦게 알려 줄 때가 있어 두 번 봄
        const k = key;
        const getThumb = async () => { const t = await invoke("media_thumb", fixedSite ? { site: fixedSite } : {}).catch(() => null); if (k === trackKey && t) { thumb = t; notify(); } };
        getThumb(); setTimeout(getThumb, 1500);
        loadLyrics(s);
      } else Object.assign(lyr, { key: "", status: "", lines: [], trans: [], roman: [], pron: [] });
    }
    notify();
  }

  // MARK: 가사

  const clean = (t) => String(t || "").replace(/\s*[([（【][^)\]）】]*(official|music video|m\/v|mv|lyric|audio|video|visualizer|live|ver\.|version|가사|공식)[^)\]）】]*[)\]）】]/gi, "").replace(/\s+-\s+topic$/i, "").trim();

  function parseLRC(text) {
    const out = [];
    for (const raw of String(text).split(/\r?\n/)) {
      const tags = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
      const words = raw.replace(/\[[^\]]*\]/g, "").trim();
      for (const m of tags) out.push({ t: +m[1] * 60 + +m[2], text: words });
    }
    return out.sort((a, b) => a.t - b.t);
  }

  async function lrclib(path) {
    try { return JSON.parse(await invoke("http_fetch", { url: "https://lrclib.net/api/" + path })); } catch { return null; }
  }

  async function loadLyrics(s) {
    const key = trackKey;
    Object.assign(lyr, { key, status: "가사 찾는 중…", synced: false, lines: [], trans: [], roman: [], pron: [], lang: "" });
    notify();
    let title = s.title, artist = s.artist;
    // YouTube 영상 제목 "가수 - 제목" 꼴
    if (/ - /.test(title) && (!artist || /topic|vevo|official/i.test(artist))) { const [a, ...t] = title.split(" - "); artist = a; title = t.join(" - "); }
    const q = (o) => Object.entries(o).filter(([, v]) => v).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    let hit = await lrclib("get?" + q({ track_name: clean(title), artist_name: clean(artist), album_name: s.album, duration: s.duration ? Math.round(s.duration) : "" }));
    if (!hit || (!hit.syncedLyrics && !hit.plainLyrics)) {
      const list = (await lrclib("search?" + q({ track_name: clean(title), artist_name: clean(artist) }))) || (await lrclib("search?" + q({ q: `${clean(artist)} ${clean(title)}` }))) || [];
      const near = (x) => !s.duration || !x.duration || Math.abs(x.duration - s.duration) < 8;
      hit = list.find((x) => x.syncedLyrics && near(x)) || list.find((x) => x.syncedLyrics) || list.find((x) => x.plainLyrics);
    }
    if (key !== trackKey) return;
    if (hit?.syncedLyrics) { lyr.lines = parseLRC(hit.syncedLyrics); lyr.synced = true; }
    else if (hit?.plainLyrics) { lyr.lines = hit.plainLyrics.split(/\r?\n/).map((text) => ({ t: -1, text: text.trim() })); lyr.synced = false; }
    else if (hit?.instrumental) { lyr.lines = []; lyr.status = "연주곡이에요"; notify(); return; }
    lyr.status = lyr.lines.length ? "" : "가사를 찾지 못했어요";
    notify();
    translate();
  }

  /// 줄마다 번역 · 로마자 (설정이 켜져 있을 때만 — 가사 글자가 Google 로 감)
  async function translate() {
    const key = lyr.key;
    const tl = cfg.transLang || "";
    const wantRoman = (cfg.pron || "off") !== "off";
    lyr.trans = []; lyr.roman = []; lyr.pron = [];
    if (!lyr.lines.length || (!tl && !wantRoman)) { notify(); return; }
    const idx = lyr.lines.map((l, i) => (l.text ? i : -1)).filter((i) => i >= 0);
    const texts = idx.map((i) => lyr.lines[i].text);
    // 너무 길면 나눠서 (한 번에 4000자 정도)
    const chunks = [];
    let cur = [];
    for (const t of texts) { if (cur.join("\n").length + t.length > 3800) { chunks.push(cur); cur = []; } cur.push(t); }
    if (cur.length) chunks.push(cur);
    const tr = [], ro = [];
    let lang = "";
    for (const ch of chunks) {
      const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${encodeURIComponent(tl || "ko")}&dt=t&dt=rm`;
      let data;
      try { data = JSON.parse(await invoke("http_fetch", { url, body: "q=" + encodeURIComponent(ch.join("\n")) })); } catch { return; }
      if (key !== lyr.key) return;
      lang = data[2] || lang;
      let t = "", r = "";
      for (const seg of data[0] || []) {
        if (typeof seg[0] === "string") t += seg[0];
        else if (seg.length >= 4 && typeof seg[3] === "string") r += seg[3];
      }
      const tl1 = t.split("\n"), rl1 = r.split("\n");
      for (let k = 0; k < ch.length; k++) { tr.push(tl1.length === ch.length ? tl1[k] : ""); ro.push(rl1.length === ch.length ? rl1[k] : ""); }
    }
    lyr.lang = lang;
    const sameLang = tl && lang && lang.split("-")[0] === tl.split("-")[0];
    idx.forEach((i, k) => {
      lyr.trans[i] = tl && !sameLang ? (tr[k] || "").trim() : "";
      lyr.roman[i] = (ro[k] || "").trim();
      lyr.pron[i] = Pron.hangul(ro[k], lang);
    });
    notify();
  }

  /// 그 줄 아래에 붙일 발음 (설정: 끔 · 한글 · 로마자)
  function pronOf(i) {
    const p = cfg.pron || "off";
    if (p === "hangul") return lyr.pron[i] || "";
    if (p === "roman") return /^[\x00-ɏ\s]*$/.test(lyr.lines[i]?.text || "") ? "" : lyr.roman[i] || "";
    return "";
  }

  function currentIndex() {
    if (!lyr.synced || !lyr.lines.length) return -1;
    const p = pos() + 0.25;
    let lo = -1;
    for (let i = 0; i < lyr.lines.length; i++) { if (lyr.lines[i].t <= p) lo = i; else break; }
    return lo;
  }

  // MARK: 조작

  /// 재생기 이름 · 여는 주소
  const SITES = { ytmusic: ["YouTube Music", "https://music.youtube.com"], "yt-video": ["YouTube", "https://www.youtube.com"], netflix: ["Netflix", "https://www.netflix.com"] };

  async function control(action, value) {
    // 도구함 재생기(YouTube Music · YouTube · Netflix)는 그 페이지에서 조작 — 숨긴 창이어도 됨
    if (st.site) await invoke("site_control", { site: st.site, action, value: value ?? 0 }).catch(() => false);
    else await invoke("media_control", { action, value }).catch(() => false);
    setTimeout(poll, 350);
  }
  /// ‹ › : 다른 재생기 보기
  async function switchSite(dir) {
    await invoke("media_select", { dir }).catch(() => "");
    thumb = ""; trackKey = "";
    poll();
  }
  function openSite(label) {
    const [name, url] = SITES[label];
    return invoke("open_window", { label, url, title: name, width: label === "ytmusic" ? 1100 : 1100, height: label === "ytmusic" ? 760 : 720 }).catch((e) => toast(String(e)));
  }

  function seek(sec) { st.position = sec; polledAt = Date.now(); control("seek", sec); notify(); }

  async function like() {
    if (st.site !== "ytmusic") return;
    await control("like");
    toast(st.like === "LIKE" ? "좋아요를 취소했어요" : "좋아요를 눌렀어요");
    setTimeout(poll, 400);
  }

  async function openYTMusic() {
    await invoke("open_window", { label: "ytmusic", url: "https://music.youtube.com", title: "YouTube Music", width: 1100, height: 760 }).catch((e) => toast(String(e)));
    ytOpen = true; notify();
  }

  /// opts.site: 그 재생기만 보기 (크게 보기 = "ytmusic" — YouTube · Netflix 가 재생 중이어도 안 넘어감)
  function start(c, opts = {}) {
    cfg = c || {};
    fixedSite = opts.site || null;
    poll();
    setInterval(poll, 1000);
    // 가사 줄 · 진행바는 재생 중이면 더 자주
    setInterval(() => { if (st.playing) subs.forEach((f) => f(true)); }, 250);
    setInterval(async () => {
      ytOpen = await invoke("window_exists", { label: "ytmusic" }).catch(() => false);
      if (cfg.hearing) hear = await invoke("hearing", {}).catch(() => null); else hear = null;
    }, 1000);
  }
  function setCfg(c) {
    const retr = c.transLang !== cfg.transLang || c.pron !== cfg.pron;
    cfg = c;
    if (retr && lyr.lines.length) translate();
    notify();
  }

  // MARK: 그리기

  /// 플레이어 줄 — mode: strip(도구함 안) · detached(떼어 낸 창)
  function renderPlayer(el, opts = {}) {
    if (!el) return;
    const sig = [st.has, st.title, st.artist, st.playing, st.shuffle, st.repeat, st.like, st.app_only, st.site, (st.sites || []).join(","), st.art, thumb.length, ytOpen, !!hear, opts.lyricsOn, Math.round(st.duration || 0)].join("|");
    if (sig === el._sig) {
      tickPlayer(el);
      const h = el.querySelector(".pl-hear");
      if (h && hear) h.outerHTML = hearHTML();
      return;
    }
    el._sig = sig;
    if (!st.has) {
      if (fixedSite) {
        // 한 재생기 전용(크게 보기): 그 재생기를 여는 단추 하나
        el.innerHTML = `<div class="pl-empty"><span>${esc(SITES[fixedSite][0])} 에서 곡을 틀어 주세요</span><button class="pl-open" data-open="${fixedSite}">${esc(SITES[fixedSite][0])} 열기</button></div>`;
        return;
      }
      if (st.app_only) {
        // 재생기가 하나도 안 열려 있으면: 여는 단추
        el.innerHTML = `<div class="pl-empty"><span>재생기를 열어 주세요</span>${Object.entries(SITES).map(([l, [n]]) => `<button class="pl-open" data-open="${l}">${esc(n)}</button>`).join("")}</div>`;
        return;
      }
      el.innerHTML = `<div class="pl-empty"><span>재생 중인 곡이 없어요</span><button class="icon" data-p="yt" title="YouTube Music 열기">${PI.yt}</button>${opts.detached ? "" : `<button class="icon" data-p="detach" title="플레이어 떼어 내기">${PI.detach}</button>`}</div>`;
      return;
    }
    const d = st.duration || 0;
    const rep = st.repeat === "one" ? "1" : "";
    el.innerHTML = `
      <div class="pl-top">
        <div class="pl-art">${thumb || st.art ? `<img src="${esc(thumb || st.art)}" alt="" referrerpolicy="no-referrer">` : ""}</div>
        <div class="pl-meta"><div class="pl-title" title="${esc(st.title)}">${esc(st.title || "제목 없음")}</div><div class="pl-artist">${esc(st.artist || st.app)}</div></div>
        ${st.site === "ytmusic" ? `<button class="icon ${st.like === "LIKE" ? "on liked" : ""}" data-p="like" title="${st.like === "LIKE" ? "좋아요 취소" : "좋아요"}">${PI.heart}</button>` : ""}
        ${st.site && !fixedSite ? `<span class="pl-src" title="재생기 — 새로 재생을 시작한 재생기로 넘어가고 나머지는 일시정지">${(st.sites || []).length > 1 ? `<button data-p="src-prev" title="이전 재생기">‹</button>` : ""}<span>${esc(SITES[st.site]?.[0] || st.app)}</span>${(st.sites || []).length > 1 ? `<button data-p="src-next" title="다음 재생기">›</button>` : ""}</span>` : ""}
      </div>
      <div class="pl-bar"><span class="pl-t" data-pos>${fmtTime(pos())}</span><div class="pl-track" data-p="seek"><div class="pl-fill" style="width:${d ? (pos() / d) * 100 : 0}%"></div></div><span class="pl-t">${fmtTime(d)}</span></div>
      <div class="pl-ctl">
        <button class="icon ${st.shuffle ? "on" : ""}" data-p="shuffle" title="셔플" ${st.shuffle == null && st.site !== "ytmusic" ? "disabled" : ""}>${PI.shuffle}</button>
        <button class="icon" data-p="prev" title="이전">${PI.prev}</button>
        <button class="icon big" data-p="toggle" title="재생 / 일시 정지">${st.playing ? PI.pause : PI.play}</button>
        <button class="icon" data-p="next" title="다음">${PI.next}</button>
        <button class="icon ${st.repeat && st.repeat !== "none" ? "on" : ""}" data-p="repeat" title="반복: ${st.repeat === "one" ? "한 곡" : st.repeat === "all" ? "전체" : "끔"}" ${st.repeat == null ? "disabled" : ""}>${PI.repeat}<sup>${rep}</sup></button>
        <span class="pl-vol"><button class="icon" data-p="mute" title="소리">${PI.vol}</button><input type="range" min="0" max="100" data-p="vol"></span>
        ${hear ? hearHTML() : ""}
        <span class="pl-sp"></span>
        ${opts.noBig ? "" : `<button class="icon" data-p="big" title="크게 보기 — 큰 앨범 · 다음 트랙 · 가사 · 앨범 · 재생목록 · 랜덤 재생목록">${PI.big}</button>`}
        <button class="icon ${opts.lyricsOn ? "on" : ""}" data-p="lyrics" title="가사">${PI.lyrics}</button>
        <button class="icon" data-p="yt" title="YouTube Music 창">${PI.yt}</button>
        ${opts.detached ? "" : `<button class="icon" data-p="detach" title="플레이어 떼어 내기">${PI.detach}</button>`}
      </div>`;
    const vol = el.querySelector('[data-p="vol"]');
    invoke("volume", {}).then((v) => { vol.value = Math.round(Math.abs(v) * 100); vol.closest(".pl-vol").classList.toggle("muted", v < 0); }).catch(() => {});
  }
  function hearHTML() {
    const db = Math.round(hear.db);
    const cls = db >= 90 ? "bad" : db >= 80 ? "warn" : "ok";
    return `<span class="pl-hear ${cls}" title="귀에 들어가는 어림 크기 · 오늘 들은 양 (85dB 로 8시간이 100%)">${db ? db + "dB" : "–"} · ${Math.round(hear.dose)}%</span>`;
  }
  /// 재생 중 0.25초마다: 진행바 · 시간만
  function tickPlayer(el) {
    if (!el || !st.has) return;
    const f = el.querySelector(".pl-fill"), t = el.querySelector("[data-pos]");
    if (f && st.duration) f.style.width = (pos() / st.duration) * 100 + "%";
    if (t) t.textContent = fmtTime(pos());
  }

  function bindPlayer(el, handlers = {}) {
    el.addEventListener("click", (e) => {
      const o = e.target.closest("[data-open]");
      if (o) { openSite(o.dataset.open); return; }
      const b = e.target.closest("[data-p]");
      if (!b) return;
      const a = b.dataset.p;
      if (a === "seek") { const r = b.getBoundingClientRect(); if (st.duration) seek(((e.clientX - r.left) / r.width) * st.duration); return; }
      if (["toggle", "next", "prev"].includes(a)) control(a);
      if (a === "shuffle") control("shuffle", st.shuffle ? 0 : 1);
      if (a === "repeat") control("repeat", st.repeat === "none" ? 2 : st.repeat === "all" ? 1 : 0);
      if (a === "src-prev") switchSite(-1);
      if (a === "src-next") switchSite(1);
      if (a === "mute") invoke("volume", { set: 0 }).then(() => notify());
      if (a === "like") like();
      if (a === "yt") openYTMusic();
      if (a === "big") openBig();
      if (handlers[a]) handlers[a]();
    });
    el.addEventListener("input", (e) => { if (e.target.dataset.p === "vol") invoke("volume", { set: e.target.value / 100 }); });
    el.addEventListener("wheel", (e) => {
      const v = e.target.closest(".pl-vol");
      if (!v) return;
      e.preventDefault(); e.stopPropagation();
      const r = v.querySelector("input");
      r.value = Math.max(0, Math.min(100, +r.value + (e.deltaY < 0 ? 4 : -4)));
      invoke("volume", { set: r.value / 100 });
    }, { passive: false });
  }

  /// 가사 줄: 지금 줄(+번역 · 발음) · 다음 줄
  function renderLine(el, opts = {}) {
    if (!el) return;
    const fs = cfg.lyricsFont || 13;
    el.style.setProperty("--lfs", fs + "px");
    if (!st.has) { el.innerHTML = ""; el._sig = ""; return; }
    const sig = [lyr.key, lyr.status, lyr.lines.length, lyr.trans.length, lyr.pron.length, cfg.pron, fs, cfg.lyricsExpanded, currentIndex()].join("|");
    if (sig === el._sig) return;
    el._sig = sig;
    const tools = `<span class="ly-tools">
        <button class="icon sm" data-l="smaller" title="글자 작게">A−</button><button class="icon sm" data-l="bigger" title="글자 크게">A+</button>
        <button class="icon sm" data-l="expand" title="${cfg.lyricsExpanded ? "접기" : "펼치기"}">${cfg.lyricsExpanded ? PI.up : PI.down}</button>
        <button class="icon sm" data-l="full" title="전체 가사">전체</button>
        ${opts.detached ? "" : `<button class="icon sm" data-l="detach" title="가사 줄 떼어 내기">${PI.detach}</button>`}</span>`;
    if (lyr.status || !lyr.lines.length) { el.innerHTML = `<div class="ly-row"><div class="ly-cur faint">${esc(lyr.status || "가사 없음")}</div>${tools}</div>`; return; }
    if (!lyr.synced) { el.innerHTML = `<div class="ly-row"><div class="ly-cur faint">시간 맞춤 가사가 없어요 — ‘전체’ 로 보기</div>${tools}</div>`; return; }
    const i = currentIndex();
    const lineHTML = (k, cls) => {
      const l = lyr.lines[k];
      if (!l) return "";
      const sub = [pronOf(k), lyr.trans[k]].filter(Boolean).map((x) => `<div class="ly-sub">${esc(x)}</div>`).join("");
      return `<div class="${cls}">${esc(l.text || "♪")}${cls === "ly-cur" ? sub : ""}</div>`;
    };
    const more = cfg.lyricsExpanded ? lineHTML(i - 1, "ly-near") : "";
    const after = cfg.lyricsExpanded ? lineHTML(i + 1, "ly-next") + lineHTML(i + 2, "ly-next") : lineHTML(i + 1, "ly-next");
    el.innerHTML = `<div class="ly-row"><div class="ly-lines">${more}${i < 0 ? `<div class="ly-cur faint">♪</div>` : lineHTML(i, "ly-cur")}${after}</div>${tools}</div>`;
    el.dataset.idx = i;
  }
  function bindLine(el, handlers = {}) {
    el.addEventListener("click", (e) => {
      const b = e.target.closest("[data-l]");
      if (!b) return;
      const a = b.dataset.l;
      if (a === "smaller" || a === "bigger") { cfg.lyricsFont = Math.max(10, Math.min(28, (cfg.lyricsFont || 13) + (a === "bigger" ? 1 : -1))); setConfig("lyricsFont", cfg.lyricsFont); notify(); }
      if (a === "expand") { cfg.lyricsExpanded = !cfg.lyricsExpanded; setConfig("lyricsExpanded", cfg.lyricsExpanded); notify(); }
      if (a === "full") openLyricsWindow();
      if (handlers[a]) handlers[a]();
    });
  }

  /// 전체 가사 (가사 창)
  function renderFull(el) {
    if (!el) return;
    const fs = cfg.lyricsFont || 15;
    el.style.setProperty("--lfs", Math.max(fs, 14) + "px");
    if (!st.has) { el.innerHTML = `<div class="hint">재생 중인 곡이 없어요</div>`; el.dataset.key = ""; return; }
    if (el.dataset.key !== lyr.key + "|" + lyr.trans.length + lyr.pron.length + (cfg.pron || "") + lyr.lines.length + lyr.status) {
      el.dataset.key = lyr.key + "|" + lyr.trans.length + lyr.pron.length + (cfg.pron || "") + lyr.lines.length + lyr.status;
      el.innerHTML = `<div class="lf-head"><b>${esc(st.title)}</b><span>${esc(st.artist)}</span></div>` +
        (lyr.lines.length ? lyr.lines.map((l, k) => {
          const sub = [pronOf(k), lyr.trans[k]].filter(Boolean).map((x) => `<div class="ly-sub">${esc(x)}</div>`).join("");
          return `<div class="lf-line" data-t="${l.t}" data-k="${k}">${esc(l.text) || "&nbsp;"}${sub}</div>`;
        }).join("") : `<div class="hint">${esc(lyr.status || "가사가 없어요")}</div>`) +
        (lyr.lines.length ? `<div class="lf-src">가사: LRCLIB${cfg.transLang || (cfg.pron || "off") !== "off" ? " · 번역/발음: Google 번역" : ""}</div>` : "");
      el._last = -2;
    }
    const i = currentIndex();
    if (i !== el._last) {
      el._last = i;
      el.querySelectorAll(".lf-line.on").forEach((x) => x.classList.remove("on"));
      const cur = el.querySelector(`.lf-line[data-k="${i}"]`);
      if (cur) { cur.classList.add("on"); if (!el.matches(":hover")) cur.scrollIntoView({ block: "center", behavior: "smooth" }); }
    }
  }
  function bindFull(el) {
    el.addEventListener("click", (e) => {
      const l = e.target.closest(".lf-line");
      if (l && lyr.synced && +l.dataset.t >= 0) seek(+l.dataset.t);
    });
  }

  function openLyricsWindow() {
    invoke("open_window", { label: "lyrics", url: "lyrics.html", title: "가사", width: 420, height: 640 }).catch((e) => toast(String(e)));
  }
  /// 크게 보기: 큰 앨범 · 다음 트랙 · 가사 · 앨범 · 재생목록 · 랜덤 재생목록
  function openBig() {
    invoke("open_window", { label: "music", url: "music.html", title: "음악", width: 940, height: 640 }).catch((e) => toast(String(e)));
  }

  return {
    start, setCfg, poll, control, seek, openYTMusic, openLyricsWindow, openBig,
    /// 지금 곡 사진 (Windows 미디어 정보 사진 · 없으면 페이지가 알려 준 주소)
    artUrl: () => thumb || st.art || "",
    on: (f) => subs.push(f),
    state: () => st,
    renderPlayer, tickPlayer, bindPlayer, renderLine, bindLine, renderFull, bindFull,
  };
})();
