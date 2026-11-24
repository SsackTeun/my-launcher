// 크게 보기 (Mac 판 bigplayer.swift · playlists.swift · random.swift 를 Windows 로)
// 왼쪽: 큰 앨범 · 곡 · 조작 / 오른쪽 탭: 다음 트랙 · 가사 · 앨범 · 재생목록 · 랜덤 재생목록
// YouTube Music 창(숨겨져 있어도 됨) 페이지 안에서 로그인한 계정으로 요청 — 쿠키 · 서명은 페이지 밖으로 안 나감
"use strict";

// MARK: 페이지 함수 (YouTube Music 창에서 돌림 — args · api · collect · nextToken · albumList 를 씀)

const JS = {
  // 다음 트랙 (Mac 판 queueJS)
  queue: `
    const txt = (el) => el ? el.textContent.replace(/\\s+/g, ' ').trim() : '';
    const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter((i) => !i.closest('#counterpart-renderer'));
    const autoOn = !!(document.querySelector('#automix') || {}).checked;
    return list.map((it, i) => ({
      i, title: txt(it.querySelector('.song-title')), artist: txt(it.querySelector('.byline')), dur: txt(it.querySelector('.duration')),
      cur: it.hasAttribute('selected') || ['playing', 'paused'].includes(it.getAttribute('play-button-state') || ''),
      auto: !!it.closest('#automix-contents'),
      // 사진: 화면에 안 보인 곡은 아직 빈 그림이라, 곡 정보(data)에 든 사진 주소를 먼저 씀
      th: (() => {
        const fromData = (d) => { const t = d && d.thumbnail && (d.thumbnail.thumbnails || (d.thumbnail.musicThumbnailRenderer && d.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails)); return t && t.length ? t[t.length - 1].url : ''; };
        const img = it.querySelector('img');
        const src = img ? (img.currentSrc || img.src || '') : '';
        return fromData(it.data) || (src.startsWith('http') ? src : '');
      })(),
      vid: (() => { const w = it.closest('ytmusic-playlist-panel-video-wrapper-renderer');
        const cp = w && w.querySelector('#counterpart-renderer ytmusic-player-queue-item');
        return (cp && cp.data && cp.data.videoId) || (it.data && it.data.videoId) || ''; })(),
      aid: ((it.data && it.data.longBylineText && it.data.longBylineText.runs || []).map((r) => r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId).find((x) => x && x.startsWith('UC'))) || '',
    })).filter((x) => x.title && (autoOn || !x.auto));`,
  playQueue: `
    const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter((i) => !i.closest('#counterpart-renderer'));
    const it = list[args.i]; if (!it) return false;
    const b = it.querySelector('ytmusic-play-button-renderer #play-button, ytmusic-play-button-renderer, .song-info');
    (b || it).click(); return true;`,
  autoplay: `const t = document.querySelector('#automix'); if (t && !!t.checked !== args.on) t.click(); return t ? t.checked : null;`,
  currentVideo: `return new URLSearchParams(location.search).get('v') || '';`,
  // 지금 곡 가수의 앨범 · 싱글 (Mac 판 currentArtistId + artistAlbums)
  albums: `
    let aid = args.aid;
    if (!aid) { const a = [...document.querySelectorAll('ytmusic-player-bar .byline a')].find((a) => (a.getAttribute('href') || '').includes('channel/UC'));
      aid = a ? a.getAttribute('href').split('channel/')[1].split(/[?&]/)[0] : null; }
    if (!aid) return { name: '', out: [] };
    const r = await api('browse', { browseId: aid });
    const s = JSON.stringify(r);
    const name = (s.match(/"musicImmersiveHeaderRenderer":\\{"title":\\{"runs":\\[\\{"text":"([^"]+)"/) || s.match(/"musicVisualHeaderRenderer":\\{"title":\\{"runs":\\[\\{"text":"([^"]+)"/) || [])[1] || '';
    const conv = (i, sec) => {
      const id = i.navigationEndpoint && i.navigationEndpoint.browseEndpoint && i.navigationEndpoint.browseEndpoint.browseId;
      const th = ((i.thumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
      return { t: (i.title.runs || [])[0].text, sub: (i.subtitle && i.subtitle.runs || []).map((x) => x.text).join(''), id, th: th ? th.url : '', sec };
    };
    const out = [];
    for (const sh of collect(r, 'musicCarouselShelfRenderer')) {
      const h = sh.header && sh.header.musicCarouselShelfBasicHeaderRenderer;
      const title = h && h.title && h.title.runs && h.title.runs[0].text || '';
      if (!/^(앨범|싱글|Albums|Singles)/.test(title)) continue;
      const more = (h.title.runs[0].navigationEndpoint && h.title.runs[0].navigationEndpoint.browseEndpoint) || (h.moreContentButton && h.moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint);
      let items = collect(sh.contents, 'musicTwoRowItemRenderer');
      if (more) { try { const m = collect(await api('browse', { browseId: more.browseId, params: more.params }), 'musicTwoRowItemRenderer'); if (m.length) items = m; } catch (e) {} }
      for (const i of items) { const c = conv(i, title); if (c.id && c.id.startsWith('MPRE')) out.push(c); }
    }
    return { name, aid, out };`,
  albumList: `return await albumList(args.id);`,
  // 앨범 수록곡 (앨범 페이지 MPREb… → 재생목록 OLAK… · 곡들). 앨범 페이지엔 곡마다 가수가 없어서 a 는 비는 경우가 많음
  albumTracks: `
    const j = await api('browse', { browseId: args.id });
    const b = JSON.stringify(j);
    const list = (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1] || null;
    const txt = (c) => ((c && c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map((x) => x.text).join('');
    const out = [];
    for (const v of collect(j, 'musicResponsiveListItemRenderer')) {
      const vid = v.playlistItemData && v.playlistItemData.videoId;
      if (!vid) continue;
      const fx = v.fixedColumns && v.fixedColumns[0] && v.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
      out.push({ t: txt((v.flexColumns || [])[0]), a: txt((v.flexColumns || [])[1]), d: fx && fx.text && fx.text.runs ? fx.text.runs[0].text : '', v: vid });
    }
    return { list, out };`,
  // 재생목록 (Mac 판 playlists.swift)
  myPlaylists: `
    const j = await api('browse', { browseId: 'FEmusic_liked_playlists' });
    return collect(j, 'musicTwoRowItemRenderer').map((i) => ({
      t: (i.title.runs || [])[0].text, id: (i.navigationEndpoint && i.navigationEndpoint.browseEndpoint || {}).browseId || '',
      sub: (i.subtitle && i.subtitle.runs || []).map((x) => x.text).join(''),
      th: (((i.thumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer && i.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0] || {}).url || '',
    })).filter((x) => x.id.startsWith('VLPL')).map((x) => Object.assign(x, { id: x.id.slice(2) }));`,
  tracks: `
    let j = await api('browse', { browseId: 'VL' + args.pid });
    const out = [], seen = new Set();
    const txt = (c) => ((c && c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map((x) => x.text).join('');
    for (let page = 0; page < 30; page++) {
      for (const i of collect(j, 'musicResponsiveListItemRenderer')) {
        const d = i.playlistItemData; if (!d || !d.playlistSetVideoId || seen.has(d.playlistSetVideoId)) continue;
        seen.add(d.playlistSetVideoId);
        const fx = i.fixedColumns && i.fixedColumns[0] && i.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
        const th = ((i.thumbnail && i.thumbnail.musicThumbnailRenderer && i.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
        out.push({ t: txt(i.flexColumns[0]), a: txt(i.flexColumns[1]), d: fx ? (fx.text.runs || [{}])[0].text || '' : '', v: d.videoId, s: d.playlistSetVideoId, th: th ? th.url : '' });
      }
      const tok = nextToken(j); if (!tok) break;
      j = await api('browse', { continuation: tok });
    }
    return out;`,
  create: `const j = await api('playlist/create', { title: args.name, description: '', privacyStatus: 'PRIVATE', videoIds: args.vids || [] }); return j.playlistId || null;`,
  del: `const j = await api('playlist/delete', { playlistId: args.pid }); return !j.error;`,
  add: `
    const actions = (args.vids || []).map((v) => ({ action: 'ACTION_ADD_VIDEO', addedVideoId: v, dedupeOption: 'DEDUPE_OPTION_SKIP' }));
    for (const a of args.albums || []) { const l = await albumList(a); if (l) actions.push({ action: 'ACTION_ADD_PLAYLIST', addedFullListId: l, dedupeOption: 'DEDUPE_OPTION_SKIP' }); }
    if (!actions.length) return false;
    const j = await api('browse/edit_playlist', { playlistId: args.pid, actions });
    return j.status === 'STATUS_SUCCEEDED';`,
  remove: `const j = await api('browse/edit_playlist', { playlistId: args.pid, actions: [{ action: 'ACTION_REMOVE_VIDEO', setVideoId: args.sid, removedVideoId: args.vid }] }); return j.status === 'STATUS_SUCCEEDED';`,
  // 랜덤 재생목록 (Mac 판 random.swift)
  searchArtists: `
    const q = args.q;
    const isArtist = (e) => e && e.browseEndpoint && /^UC/.test(e.browseEndpoint.browseId || '') &&
      (((e.browseEndpoint.browseEndpointContextSupportedConfigs || {}).browseEndpointContextMusicConfig || {}).pageType === 'MUSIC_PAGE_TYPE_ARTIST');
    const sg = await api('music/get_search_suggestions', { input: q });
    const firstSug = ((JSON.stringify(sg).match(/"searchSuggestionRenderer":\\{"suggestion":\\{"runs":\\[(.*?)\\]\\}/) || [])[1] || '').replace(/.*?"text":"([^"]*)"/g, '$1');
    const out = [], seen = new Set();
    const fromList = (r) => { for (const v of collect(r, 'musicResponsiveListItemRenderer')) {
      if (!isArtist(v.navigationEndpoint)) continue;
      const id = v.navigationEndpoint.browseEndpoint.browseId;
      let name = ''; try { name = v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text; } catch (e) {}
      if (name && !seen.has(id)) { seen.add(id); out.push({ id, name }); } } };
    const r = await api('search', { query: q });
    fromList(r);
    for (const v of collect(r, 'musicCardShelfRenderer')) {
      const t = v.title && v.title.runs && v.title.runs[0];
      if (!t || !isArtist(t.navigationEndpoint)) continue;
      const id = t.navigationEndpoint.browseEndpoint.browseId;
      if (!seen.has(id)) { seen.add(id); out.unshift({ id, name: t.text }); }
    }
    const sugOut = [];
    for (const v of collect(sg, 'musicResponsiveListItemRenderer')) {
      let id = isArtist(v.navigationEndpoint) ? v.navigationEndpoint.browseEndpoint.browseId : null, name = '';
      if (id) { try { name = v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text; } catch (e) {} }
      else JSON.stringify(v, (k, x) => { if (!id && x && typeof x === 'object' && typeof x.text === 'string' && x.navigationEndpoint && isArtist(x.navigationEndpoint)) { id = x.navigationEndpoint.browseEndpoint.browseId; name = x.text; } return x; });
      if (id && name && !sugOut.some((a) => a.id === id)) sugOut.push({ id, name });
    }
    for (const a of sugOut.reverse()) { const i = out.findIndex((o) => o.id === a.id); if (i >= 0) out.splice(i, 1); out.unshift(a); seen.add(a.id); }
    if (out.length === 0 && firstSug && firstSug.toLowerCase() !== q.toLowerCase()) fromList(await api('search', { query: firstSug }));
    return out.slice(0, 12);`,
  // 장르 목록: YouTube Music '분위기 및 장르' 페이지 (묶음 이름 · 단추 이름 · 여는 값)
  genres: `
    const r = await api('browse', { browseId: 'FEmusic_moods_and_genres' });
    const out = [];
    const btn = (b, sec) => {
      const e = b.clickCommand && b.clickCommand.browseEndpoint;
      const t = b.buttonText && b.buttonText.runs && b.buttonText.runs[0].text;
      if (e && t && e.params) out.push({ sec, t, id: e.browseId, params: e.params });
    };
    const grids = collect(r, 'gridRenderer');
    for (const g of grids) {
      const sec = (((g.header || {}).gridHeaderRenderer || {}).title || {}).runs?.[0]?.text || '';
      for (const b of collect(g.items || [], 'musicNavigationButtonRenderer')) btn(b, sec);
    }
    if (!out.length) for (const b of collect(r, 'musicNavigationButtonRenderer')) btn(b, '');
    return out;`,
  // 장르에서 가수 추천: 그 장르의 대표 재생목록 몇 개를 열어 가장 많이 나오는 가수
  genreArtists: `
    const r = await api('browse', { browseId: args.id || 'FEmusic_moods_and_genres_category', params: args.params });
    const lists = [];
    for (const i of collect(r, 'musicTwoRowItemRenderer')) {
      const id = i.navigationEndpoint && i.navigationEndpoint.browseEndpoint && i.navigationEndpoint.browseEndpoint.browseId;
      if (id && id.startsWith('VL') && !lists.includes(id)) lists.push(id);
    }
    const isArtist = (e) => e && e.browseEndpoint && /^UC/.test(e.browseEndpoint.browseId || '') &&
      (((e.browseEndpoint.browseEndpointContextSupportedConfigs || {}).browseEndpointContextMusicConfig || {}).pageType === 'MUSIC_PAGE_TYPE_ARTIST');
    const count = new Map();
    // 앨범 · 가수 카드가 장르 페이지에 바로 있으면 그것도 (가중치 2)
    for (const i of collect(r, 'musicTwoRowItemRenderer')) {
      const e = i.navigationEndpoint;
      if (isArtist(e)) { const id = e.browseEndpoint.browseId, name = (i.title.runs || [])[0].text; const c = count.get(id) || { id, name, n: 0 }; c.n += 2; count.set(id, c); }
      for (const run of (i.subtitle && i.subtitle.runs) || []) if (isArtist(run.navigationEndpoint)) {
        const id = run.navigationEndpoint.browseEndpoint.browseId; const c = count.get(id) || { id, name: run.text, n: 0 }; c.n += 1; count.set(id, c);
      }
    }
    // 무작위로 섞어서 (이미 읽은 건 빼고) 몇 개만 — 누를 때마다 다른 재생목록에서 모음
    const skip = new Set(args.skip || []);
    const pool = lists.filter((x) => !skip.has(x));
    for (let i = pool.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [pool[i], pool[j]] = [pool[j], pool[i]]; }
    const used = pool.slice(0, args.lists || 8);
    for (const vl of used) {
      let j;
      try { j = await api('browse', { browseId: vl }); } catch (e) { continue; }
      for (const v of collect(j, 'musicResponsiveListItemRenderer')) {
        const runs = (v.flexColumns && v.flexColumns[1] && v.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs) || [];
        for (const run of runs) if (isArtist(run.navigationEndpoint)) {
          const id = run.navigationEndpoint.browseEndpoint.browseId;
          const c = count.get(id) || { id, name: run.text, n: 0 }; c.n += 1; count.set(id, c);
        }
      }
    }
    return { artists: [...count.values()].sort((a, b) => b.n - a.n).slice(0, args.max || 80), used, total: lists.length };`,
  artistSongs: `
    const r = await api('browse', { browseId: args.aid });
    let list = null;
    for (const sh of collect(r, 'musicShelfRenderer')) { const m = JSON.stringify(sh.bottomEndpoint || sh.title || {}).match(/"browseId":"(VL[^"]+)"/); if (m) { list = m[1]; break; } }
    const out = [];
    const secs = (t) => (t || '').split(':').reduce((a, x) => a * 60 + (parseInt(x) || 0), 0);
    const take = (o) => { for (const v of collect(o, 'musicResponsiveListItemRenderer')) {
      if (!v.playlistItemData) continue;
      const fx = v.fixedColumns && v.fixedColumns[0] && v.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer;
      out.push({ t: v.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text, v: v.playlistItemData.videoId, s: fx ? secs(fx.text.runs[0].text) : 0 });
    } };
    if (list) { let j = await api('browse', { browseId: list }); for (let p = 0; p < 20; p++) { take(j); const tok = nextToken(j); if (!tok) break; j = await api('browse', { continuation: tok }); } }
    else take(r);
    return out;`,
};

const call = (name, args, timeout) => invoke("site_call", { site: "ytmusic", body: JS[name], args: args ?? {}, timeout: timeout ?? 30 });
const ytOpen = () => invoke("window_exists", { label: "ytmusic" }).catch(() => false);

/// YouTube Music 창에서 재생목록(또는 앨범 OLAK…)을 재생. 자동재생은 끔 (목록이 끝나면 섞인 곡이 이어 붙지 않게)
async function playList(list, from) {
  const u = `https://music.youtube.com/watch?${from ? `v=${encodeURIComponent(from)}&` : ""}list=${encodeURIComponent(list)}`;
  await invoke("web_eval", { label: "ytmusic", js: `location.href = ${JSON.stringify(u)}` });
  for (const t of [4000, 8000, 12000]) setTimeout(() => call("autoplay", { on: false }).catch(() => {}), t);
  setTimeout(() => { if (tab === 0) loadQueue(); }, 5000);
}

// MARK: 화면 도우미 (메뉴 · 대화 상자)

const menuEl = $("#menu");
function closeMenu() { menuEl.hidden = true; }
function showMenu(x, y, items) {
  menuEl.innerHTML = items.map((it, i) => it === "-" ? '<div class="sep"></div>' : it.header ? `<div class="lab">${esc(it.label)}</div>`
    : `<div class="it ${it.disabled ? "off" : ""}" data-i="${i}"><span class="ck">${it.checked ? "✓" : ""}</span>${esc(it.label)}</div>`).join("");
  menuEl.onclick = (e) => { const el = e.target.closest(".it"); if (!el) return; closeMenu(); items[+el.dataset.i].action?.(); };
  menuEl.hidden = false;
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 6)) + "px";
  menuEl.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 6)) + "px";
}
document.addEventListener("mousedown", (e) => { if (!menuEl.hidden && !menuEl.contains(e.target)) closeMenu(); });
const modal = $("#modal");
function ask(title, value = "", ph = "") {
  return new Promise((done) => {
    modal.innerHTML = `<div class="box"><h3>${esc(title)}</h3><input type="text" id="askIn" value="${esc(value)}" placeholder="${esc(ph)}"><div class="btns"><button data-r="0">취소</button><button class="primary" data-r="1">확인</button></div></div>`;
    modal.hidden = false;
    const inp = $("#askIn"); inp.focus(); inp.select();
    const finish = (ok) => { modal.hidden = true; done(ok ? inp.value.trim() || null : null); };
    modal.onclick = (e) => { const b = e.target.closest("[data-r]"); if (b) finish(b.dataset.r === "1"); else if (e.target === modal) finish(false); };
    inp.onkeydown = (e) => { if (e.key === "Enter") finish(true); if (e.key === "Escape") finish(false); };
  });
}
function confirmBox(title, body, ok = "확인") {
  return new Promise((done) => {
    modal.innerHTML = `<div class="box"><h3>${esc(title)}</h3><p>${esc(body)}</p><div class="btns"><button data-r="0">취소</button><button class="primary danger" data-r="1">${esc(ok)}</button></div></div>`;
    modal.hidden = false;
    modal.onclick = (e) => { const b = e.target.closest("[data-r]"); if (b || e.target === modal) { modal.hidden = true; done(b?.dataset.r === "1"); } };
  });
}
const status = (t) => { $("#mzStatus").textContent = t || ""; };
const fail = (e) => { status(""); toast(String(e).includes("창이 없어요") ? "YouTube Music 창을 먼저 열어 주세요" : `실패했어요: ${e}`); };

// MARK: 재생목록 캐시 · 넣기 메뉴 (다음 트랙 · 앨범 · 재생목록 탭이 같이 씀)

let myLists = null;
async function loadMyLists(force) {
  if (myLists && !force) return myLists;
  myLists = await call("myPlaylists").catch(() => null);
  return myLists || [];
}
/// "재생목록에 넣기" 메뉴: 내 재생목록들 + 새 재생목록
async function addMenu(x, y, vids, albums) {
  if (!vids.length && !albums.length) { toast("넣을 곡을 골라 주세요"); return; }
  status("재생목록 읽는 중…");
  const lists = await loadMyLists();
  status("");
  showMenu(x, y, [{ label: "재생목록에 넣기", header: true },
    ...lists.map((l) => ({ label: l.t, action: () => addTo(l.id, l.t, vids, albums) })),
    "-", { label: "새 재생목록…", action: async () => {
      const name = await ask("새 재생목록 이름", "", "예: 드라이브");
      if (!name) return;
      status("만드는 중…");
      try {
        const id = await call("create", { name, vids: [] });
        if (!id) throw "만들지 못했어요";
        myLists = null;
        await addTo(id, name, vids, albums);
      } catch (e) { fail(e); }
    } }]);
}
async function addTo(pid, title, vids, albums) {
  status("넣는 중…");
  try {
    const ok = await call("add", { pid, vids, albums }, 60);
    status("");
    toast(ok ? `‘${title}’에 넣었어요` : "넣지 못했어요 (이미 있는 곡이었을 수도)");
    if (ok) { picked.clear(); pickedAlbums.clear(); drawBar(); if (tab === 3 && plSel === pid) loadTracks(); }
  } catch (e) { fail(e); }
}

// MARK: 탭

const TABS = ["다음 트랙", "가사", "앨범", "재생목록", "랜덤"];
let tab = 0;
try { tab = Math.min(4, +localStorage.getItem("mzTab") || 0); } catch { /* 없음 */ }
const picked = new Set();      // 다음 트랙에서 고른 videoId
const pickedAlbums = new Set(); // 앨범 탭에서 고른 앨범 id
function drawTabs() {
  $("#mzTabs").innerHTML = TABS.map((t, i) => `<button data-tab="${i}" class="${i === tab ? "on" : ""}">${t}</button>`).join("");
}
$("#mzTabs").onclick = (e) => {
  const b = e.target.closest("[data-tab]");
  if (!b) return;
  tab = +b.dataset.tab;
  try { localStorage.setItem("mzTab", tab); } catch { /* 없음 */ }
  picked.clear(); pickedAlbums.clear();
  drawTabs(); show();
};
const body = $("#mzBody");
async function show() {
  if (!big) return;
  drawBar();
  body.className = "mz-body";
  if (tab === 1) { body.classList.add("lyfull"); body.dataset.key = ""; Player.renderFull(body); return; }
  if (!(await ytOpen())) {
    body.innerHTML = `<div class="mz-empty">YouTube Music 창이 꺼져 있어요<br><button class="pl-open" id="openYm">YouTube Music 열기</button></div>`;
    $("#openYm").onclick = () => { Player.openYTMusic(); setTimeout(show, 4000); };
    return;
  }
  if (tab === 0) loadQueue();
  if (tab === 2) loadAlbums();
  if (tab === 3) loadPlaylists();
  if (tab === 4) drawRandom();
}
/// 아래 줄: 고른 것이 있으면 [재생목록에 넣기] [고르기 취소]
function drawBar() {
  const n = picked.size + pickedAlbums.size;
  const bar = $("#mzBar");
  bar.hidden = !n || (tab !== 0 && tab !== 2);
  const label = [picked.size ? `${picked.size}곡` : "", pickedAlbums.size ? `앨범 ${pickedAlbums.size}개` : ""].filter(Boolean).join(" · ");
  bar.innerHTML = n ? `<span>${label} 고름</span><span class="mz-sp"></span><button class="pl-open" id="barPlay" title="고른 곡만 바로 재생 (앨범을 고르면 그 앨범의 모든 곡)">▶ 재생</button><button class="pl-open" id="barAdd">재생목록에 넣기 ▾</button><button class="pl-open ghost" id="barClear">고르기 취소</button>` : "";
  if (!n) return;
  $("#barPlay").onclick = async () => {
    const vids = [...picked];
    for (const id of pickedAlbums) {
      try { const r = albumTrackCache.get(id) || await call("albumTracks", { id }, 30); albumTrackCache.set(id, r); vids.push(...r.out.map((x) => x.v)); } catch (e) { /* 건너뜀 */ }
    }
    await playVideos(vids);
  };
  $("#barAdd").onclick = (e) => { const r = e.target.getBoundingClientRect(); addMenu(r.left, r.top - 8 - 200, [...picked], [...pickedAlbums]); };
  $("#barClear").onclick = () => { picked.clear(); pickedAlbums.clear(); drawBar(); body.querySelectorAll("input.pick").forEach((x) => (x.checked = false)); };
}

// MARK: 다음 트랙

let queueSig = "";
async function loadQueue(quiet) {
  if (!quiet) status("읽는 중…");
  let q;
  try { q = await call("queue", {}, 15); } catch (e) { fail(e); return; }
  q = Array.isArray(q) ? q : [];
  status("");
  if (tab !== 0) return;
  const sig = JSON.stringify(q.map((x) => [x.vid, x.cur]));
  if (quiet && sig === queueSig) return;
  queueSig = sig;
  if (!q.length) { body.innerHTML = `<div class="mz-empty">다음 트랙이 비어 있어요<br><small>YouTube Music 에서 곡이나 재생목록을 틀면 여기에 나와요</small></div>`; return; }
  // 몇 곡 중 몇 번째 · 남은 시간 (위) / 전체 재생시간 (아래). 자동재생으로 붙은 곡은 따로 셈
  const main = q.filter((x) => !x.auto);
  const curK = q.findIndex((x) => x.cur);
  const total = main.reduce((a, x) => a + secsOf(x.dur), 0);
  const autoTotal = q.filter((x) => x.auto).reduce((a, x) => a + secsOf(x.dur), 0);
  const st = Player.state();
  const leftNow = curK >= 0 ? Math.max(0, secsOf(q[curK].dur) - (st.position || 0)) : 0;
  const after = curK >= 0 ? main.filter((x, k) => q.indexOf(x) > curK).reduce((a, x) => a + secsOf(x.dur), 0) : total;
  const head = curK >= 0 && !q[curK].auto
    ? `<b>${main.length}곡 중 ${main.indexOf(q[curK]) + 1}번째</b> · 남은 시간 ${hms(leftNow + after)}`
    : `<b>${main.length}곡</b>`;
  body.innerHTML = `<div class="mz-qhead">${head}</div>` + q.map((x, k) => `<div class="mz-row ${x.cur ? "cur" : ""} ${x.auto ? "auto" : ""}" data-i="${x.i}" data-vid="${esc(x.vid)}" data-aid="${esc(x.aid)}" data-artist="${esc(artistOf(x.artist))}">
      <span class="mz-num">${k + 1}<input type="checkbox" class="pick" ${picked.has(x.vid) ? "checked" : ""} title="골라서 재생목록에 넣기"></span>
      ${x.th ? `<img src="${esc(x.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(x.title)}</b><small>${esc(x.artist)}</small></span>
      <span class="mz-d">${esc(x.dur)}</span></div>`).join("") +
    `<div class="mz-qfoot">전체 ${main.length}곡 · ${hms(total)}${autoTotal ? ` <small>+ 자동재생 ${q.length - main.length}곡 · ${hms(autoTotal)}</small>` : ""}</div>`;
  body.classList.toggle("picking", picked.size > 0);
  body.querySelector(".mz-row.cur")?.scrollIntoView({ block: "center" });
}
body.addEventListener("change", (e) => {
  const c = e.target.closest("input.pick");
  if (!c) return;
  const row = c.closest("[data-vid],[data-album]");
  const set = row.dataset.album ? pickedAlbums : picked;
  const k = row.dataset.album || row.dataset.vid;
  c.checked ? set.add(k) : set.delete(k);
  body.classList.toggle("picking", picked.size + pickedAlbums.size > 0);
  drawBar();
});
body.addEventListener("click", async (e) => {
  if (e.target.closest("input")) return;
  if (tab === 0) {
    const row = e.target.closest(".mz-row[data-i]");
    if (row) { await call("playQueue", { i: +row.dataset.i }).catch(fail); setTimeout(() => loadQueue(true), 800); }
  }
  if (tab === 2) {
    const card = e.target.closest(".mz-album[data-album]");
    if (card && e.target.closest(".mz-aplay")) { playAlbum(card.dataset.album, card.dataset.title); return; }
    if (card) { toggleAlbum(card.dataset.album); return; }
    const tr = e.target.closest(".mz-tracks .mz-row[data-vid]");
    if (tr) {
      if (tr.dataset.list) { await playList(tr.dataset.list, tr.dataset.vid); toast(`‘${tr.dataset.title}’부터 앨범 재생`); }
      else playVideos([tr.dataset.vid]);
    }
  }
});
body.addEventListener("contextmenu", (e) => {
  const row = e.target.closest(".mz-row");
  if (!row) return;
  e.preventDefault();
  if (tab === 0 && row.dataset.vid) {
    showMenu(e.clientX, e.clientY, [
      { label: "이 곡 재생", action: () => call("playQueue", { i: +row.dataset.i }).catch(fail) },
      { label: "재생목록에 넣기…", action: () => addMenu(e.clientX, e.clientY, [row.dataset.vid], []) },
      { label: `‘${row.dataset.artist}’ 를 랜덤 가수에 넣기`, disabled: !row.dataset.artist, action: () => addArtistsToRandom([{ aid: row.dataset.aid, name: row.dataset.artist }]) },
    ]);
  }
  if (tab === 2 && row.dataset.album) albumMenu(e.clientX, e.clientY, row.dataset.album, row.dataset.title);
  if (tab === 2 && !row.dataset.album && row.dataset.vid) {
    showMenu(e.clientX, e.clientY, [
      { label: "이 곡만 재생", action: () => playVideos([row.dataset.vid]) },
      { label: "이 곡부터 앨범 재생", disabled: !row.dataset.list, action: () => playList(row.dataset.list, row.dataset.vid) },
      { label: "재생목록에 넣기…", action: () => addMenu(e.clientX, e.clientY, [row.dataset.vid], []) },
    ]);
  }
  if (tab === 3 && row.dataset.sid) trackMenu(e.clientX, e.clientY, row);
});

// MARK: 앨범 (지금 곡 가수의 앨범 · 싱글)

let albumsFor = "";
async function loadAlbums(force) {
  const st = Player.state();
  if (!force && albumsFor && albumsFor === st.artist && body.querySelector(".mz-albums")) return;
  status("가수 앨범 읽는 중…");
  let r;
  try { r = await call("albums", {}, 40); } catch (e) { fail(e); return; }
  status("");
  if (tab !== 2) return;
  albumsFor = st.artist;
  if (!r.out.length) { body.innerHTML = `<div class="mz-empty">지금 곡 가수의 앨범을 찾지 못했어요</div>`; return; }
  const groups = {};
  for (const a of r.out) (groups[a.sec] = groups[a.sec] || []).push(a);
  // Mac 판처럼 세로 목록: 작은 자켓 · 제목 · 종류/연도 · ▸ · ▶ — 누르면 바로 아래에 수록곡
  body.innerHTML = `<div class="mz-albums"><div class="mz-h">${esc(r.name)}</div>` + Object.entries(groups).map(([sec, list]) =>
    `<div class="mz-sec">${esc(sec)}</div>${list.map((a) => `<div class="mz-album mz-row" data-album="${esc(a.id)}" data-title="${esc(a.t)}" title="눌러서 수록곡 보기 · ▶ 처음부터 재생 · 오른쪽 클릭: 재생목록에 넣기">
      <span class="mz-acover"><img src="${esc(a.th)}" alt="" referrerpolicy="no-referrer"><input type="checkbox" class="pick" ${pickedAlbums.has(a.id) ? "checked" : ""} title="앨범 통째로 고르기"></span>
      <span class="mz-t"><b>${esc(a.t)}</b><small>${esc(a.sub)}</small></span>
      <span class="mz-chev">›</span>
      <button class="mz-aplay" title="처음부터 재생">▶</button></div>`).join("")}`).join("") + "</div>";
  for (const id of [...openAlbums]) if (body.querySelector(`[data-album="${CSS.escape(id)}"]`)) { openAlbums.delete(id); toggleAlbum(id); } else openAlbums.delete(id);
}

// MARK: 앨범 수록곡 펼치기 — 누르면 그 줄 아래에 수록곡, 곡을 누르면 그 곡부터 앨범 재생

const albumTrackCache = new Map(); // 앨범 id → { list, out }
const openAlbums = new Set();
async function toggleAlbum(id) {
  const card = body.querySelector(`.mz-album[data-album="${CSS.escape(id)}"]`);
  if (!card) return;
  const old = body.querySelector(`.mz-tracks[data-for="${CSS.escape(id)}"]`);
  if (old) { old.remove(); card.classList.remove("open"); openAlbums.delete(id); return; }
  openAlbums.add(id);
  card.classList.add("open");
  // 그 앨범 줄 바로 아래에
  const last = card;
  const panel = document.createElement("div");
  panel.className = "mz-tracks";
  panel.dataset.for = id;
  panel.innerHTML = `<div class="mz-note">‘${esc(card.dataset.title)}’ 수록곡 읽는 중…</div>`;
  last.after(panel);
  let r = albumTrackCache.get(id);
  if (!r) {
    try { r = await call("albumTracks", { id }, 30); albumTrackCache.set(id, r); } catch (e) { panel.innerHTML = `<div class="mz-note">수록곡을 읽지 못했어요</div>`; return; }
  }
  if (!panel.isConnected) return;
  if (!r.out.length) { panel.innerHTML = `<div class="mz-note">수록곡을 찾지 못했어요</div>`; return; }
  const total = r.out.reduce((a, x) => a + secsOf(x.d), 0);
  panel.innerHTML = `<div class="mz-note">${r.out.length}곡 · ${hms(total)} <small>— 곡을 누르면 그 곡부터 재생 · 번호 칸을 체크해서 골라 재생</small></div>` +
    r.out.map((x, k) => `<div class="mz-row" data-vid="${esc(x.v)}" data-list="${esc(r.list || "")}" data-title="${esc(x.t)}">
      <span class="mz-num">${k + 1}<input type="checkbox" class="pick" ${picked.has(x.v) ? "checked" : ""} title="골라서 재생 · 재생목록에 넣기"></span>
      <span class="mz-t"><b>${esc(trimAlbum(x.t, card.dataset.title))}</b>${x.a ? `<small>${esc(x.a)}</small>` : ""}</span>
      <span class="mz-d">${esc(x.d)}</span></div>`).join("");
}
/// '곡 (앨범 이름)' → '곡' (앨범 아래에 펼친 거라 앨범 이름은 이미 보임)
function trimAlbum(t, album) {
  const a = String(album || "").trim();
  if (!a) return t;
  for (const [o, c] of [["(", ")"], ["[", "]"]]) {
    const tail = ` ${o}${a}${c}`;
    if (t.endsWith(tail) && t.length > tail.length) return t.slice(0, -tail.length);
  }
  return t;
}

/// 고른 곡만 재생: 한 곡이면 그 곡만, 여러 곡이면 '고른 곡 (도구함)' 재생목록을 새로 만들어 틀고 전에 만든 건 지움
/// (YouTube Music 은 곡 몇 개로 바로 재생 목록을 만드는 주소가 없어서)
async function playVideos(vids) {
  vids = [...new Set(vids.filter(Boolean))];
  if (!vids.length) { toast("재생할 곡을 골라 주세요"); return; }
  if (vids.length === 1) {
    await invoke("web_eval", { label: "ytmusic", js: `location.href = ${JSON.stringify("https://music.youtube.com/watch?v=" + encodeURIComponent(vids[0]))}` });
    for (const t of [4000, 8000, 12000]) setTimeout(() => call("autoplay", { on: false }).catch(() => {}), t);
    toast("고른 곡을 재생해요");
    return;
  }
  status(`고른 ${vids.length}곡 준비 중…`);
  try {
    let old = null;
    try { old = localStorage.getItem("mzPickedList"); } catch { /* 없음 */ }
    if (old) call("del", { pid: old }).catch(() => {});
    const id = await call("create", { name: "고른 곡 (도구함)", vids }, 60);
    if (!id) throw "만들지 못했어요 (로그인 확인)";
    try { localStorage.setItem("mzPickedList", id); } catch { /* 없음 */ }
    myLists = null;
    picked.clear(); pickedAlbums.clear(); drawBar();
    body.querySelectorAll("input.pick").forEach((x) => (x.checked = false));
    body.classList.remove("picking");
    // 서버에 반영되기 전에 틀면 곡이 빠진 채로 시작해서 조금 기다렸다가
    setTimeout(async () => { await playList(id); status(""); toast(`고른 ${vids.length}곡을 재생해요`); }, 2000);
  } catch (e) { fail(e); }
}
async function playAlbum(id, title) {
  status("앨범 여는 중…");
  try {
    const list = await call("albumList", { id });
    if (!list) throw "앨범 재생목록을 찾지 못했어요";
    await playList(list);
    status("");
    toast(`‘${title}’ 재생`);
  } catch (e) { fail(e); }
}
function albumMenu(x, y, id, title) {
  showMenu(x, y, [
    { label: "처음부터 재생", action: () => playAlbum(id, title) },
    { label: openAlbums.has(id) ? "수록곡 접기" : "수록곡 보기", action: () => toggleAlbum(id) },
    { label: "재생목록에 넣기…", action: () => addMenu(x, y, [], [id]) },
  ]);
}

// MARK: 재생목록 (내 계정 — 휴대폰 앱에도 그대로 보임)

let plSel = null;
let plTracks = [];
let plDelMode = false;
const plDel = new Set();
async function loadPlaylists(force) {
  status("재생목록 읽는 중…");
  const lists = await loadMyLists(force);
  status("");
  if (tab !== 3) return;
  if (!myLists) { body.innerHTML = `<div class="mz-empty">재생목록을 읽지 못했어요<br><small>YouTube Music 창에서 로그인했는지 확인해 주세요</small></div>`; return; }
  if (plSel && !lists.some((l) => l.id === plSel)) plSel = null;
  body.innerHTML = `<div class="mz-pl">
    <div class="mz-pl-side">
      <div class="mz-pl-tools">
        <button class="pl-open" id="plNew" title="새 재생목록 (비공개)">＋ 새로</button>
        <button class="pl-open ${plDelMode ? "danger" : "ghost"}" id="plDel" title="재생목록 지우기 (여러 개 골라서)">${plDelMode ? `${plDel.size}개 지우기` : "지우기…"}</button>
        ${plDelMode ? '<button class="pl-open ghost" id="plDelCancel">취소</button>' : ""}
        <button class="icon sm" id="plReload" title="새로 고침">↻</button>
      </div>
      <div class="mz-pl-list">${lists.map((l) => `<div class="mz-pl-item ${l.id === plSel ? "on" : ""}" data-pl="${esc(l.id)}">
        ${plDelMode ? `<input type="checkbox" class="del" ${plDel.has(l.id) ? "checked" : ""}>` : ""}
        ${l.th ? `<img src="${esc(l.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
        <span class="mz-t"><b>${esc(l.t)}</b><small>${esc(l.sub)}</small></span></div>`).join("") || '<div class="mz-empty">재생목록이 없어요</div>'}</div>
    </div>
    <div class="mz-pl-main" id="plMain">${plSel ? "" : '<div class="mz-empty">왼쪽에서 재생목록을 골라 주세요</div>'}</div></div>`;
  $("#plNew").onclick = async () => {
    const name = await ask("새 재생목록 이름", "", "예: 드라이브");
    if (!name) return;
    status("만드는 중…");
    try { const id = await call("create", { name, vids: [] }); if (!id) throw "만들지 못했어요"; plSel = id; myLists = null; await loadPlaylists(true); toast(`‘${name}’을 만들었어요`); } catch (e) { fail(e); }
  };
  $("#plReload").onclick = () => loadPlaylists(true);
  $("#plDel").onclick = async () => {
    if (!plDelMode) { plDelMode = true; plDel.clear(); loadPlaylists(); return; }
    if (!plDel.size) { toast("지울 재생목록을 골라 주세요"); return; }
    const names = lists.filter((l) => plDel.has(l.id)).map((l) => l.t);
    if (!(await confirmBox(`재생목록 ${names.length}개를 지울까요?`, names.join(", ") + " — YouTube Music 계정에서도 지워지고 되돌릴 수 없어요.", "지우기"))) return;
    let ok = 0;
    for (const id of plDel) { status(`지우는 중… ${ok + 1}/${plDel.size}`); if (await call("del", { pid: id }).catch(() => false)) ok++; }
    toast(`${ok}개를 지웠어요${ok < plDel.size ? ` (${plDel.size - ok}개는 못 지움)` : ""}`);
    plDelMode = false; plDel.clear(); if (!lists.some((l) => l.id === plSel)) plSel = null;
    loadPlaylists(true);
  };
  if (plDelMode) $("#plDelCancel").onclick = () => { plDelMode = false; plDel.clear(); loadPlaylists(); };
  body.querySelector(".mz-pl-list").onclick = (e) => {
    const it = e.target.closest("[data-pl]");
    if (!it) return;
    if (plDelMode) {
      const c = it.querySelector("input.del");
      if (e.target !== c) c.checked = !c.checked;
      c.checked ? plDel.add(it.dataset.pl) : plDel.delete(it.dataset.pl);
      $("#plDel").textContent = `${plDel.size}개 지우기`;
      return;
    }
    plSel = it.dataset.pl;
    body.querySelectorAll(".mz-pl-item").forEach((x) => x.classList.toggle("on", x === it));
    loadTracks();
  };
  if (plSel) loadTracks();
}
async function loadTracks() {
  const main = $("#plMain");
  if (!main || !plSel) return;
  const l = (myLists || []).find((x) => x.id === plSel);
  main.innerHTML = `<div class="mz-empty">곡 읽는 중…</div>`;
  try { plTracks = await call("tracks", { pid: plSel }, 60); } catch (e) { fail(e); return; }
  if (plSel !== l?.id || !$("#plMain")) return;
  const curT = Player.state().title;
  main.innerHTML = `<div class="mz-pl-head"><b>${esc(l?.t || "")}</b><small>${plTracks.length}곡</small><span class="mz-sp"></span>
      <button class="pl-open" id="plPlay">▶ 재생</button><button class="pl-open ghost" id="plAddCur" title="지금 듣는 곡을 이 재생목록에">＋ 지금 곡</button></div>
    <div class="mz-pl-tracks">${plTracks.map((t, i) => `<div class="mz-row ${t.t === curT ? "cur" : ""}" data-k="${i}" data-sid="${esc(t.s)}">
      ${t.th ? `<img src="${esc(t.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(t.t)}</b><small>${esc(t.a)}</small></span><span class="mz-d">${esc(t.d)}</span>
      <button class="mz-x" title="재생목록에서 빼기">⊖</button></div>`).join("") || '<div class="mz-empty">비어 있어요 — ＋ 지금 곡 으로 넣어 보세요</div>'}</div>`;
  $("#plPlay").onclick = () => { playList(plSel); toast(`‘${l?.t}’ 재생`); };
  $("#plAddCur").onclick = async () => {
    const v = await call("currentVideo").catch(() => "");
    if (!v) { toast("지금 듣는 곡이 없어요"); return; }
    addTo(plSel, l?.t || "", [v], []);
  };
  main.querySelector(".mz-pl-tracks").onclick = (e) => {
    const row = e.target.closest("[data-k]");
    if (!row) return;
    const t = plTracks[+row.dataset.k];
    if (e.target.closest(".mz-x")) { removeTrack(t); return; }
    playList(plSel, t.v);
  };
}
function trackMenu(x, y, row) {
  const t = plTracks[+row.dataset.k];
  showMenu(x, y, [
    { label: "여기부터 재생", action: () => playList(plSel, t.v) },
    { label: "다른 재생목록에도 넣기…", action: () => addMenu(x, y, [t.v], []) },
    "-", { label: "이 재생목록에서 빼기", action: () => removeTrack(t) },
  ]);
}
async function removeTrack(t) {
  status("빼는 중…");
  try {
    const ok = await call("remove", { pid: plSel, sid: t.s, vid: t.v });
    status("");
    if (!ok) throw "빼지 못했어요";
    toast(`‘${t.t}’을 뺐어요`, 2600);
    loadTracks();
  } catch (e) { fail(e); }
}

// MARK: 랜덤 재생목록 — 가수 고르기(비중 1~5) · 곡 수나 시간 · 인기곡 위주 · 새로 만들기 또는 덧붙이기

const R = { picks: [], mode: "count", amount: 30, unit: "min", popular: true, target: "new", name: "" };
try { Object.assign(R, JSON.parse(localStorage.getItem("mzRandom") || "{}"), { picks: (JSON.parse(localStorage.getItem("mzRandom") || "{}").picks || []).map((p) => ({ ...p, songs: null })) }); } catch { /* 없음 */ }
const saveR = () => { try { localStorage.setItem("mzRandom", JSON.stringify({ ...R, picks: R.picks.map(({ id, name, w }) => ({ id, name, w })) })); } catch { /* 없음 */ } };
let searchHits = [];
let genreCache = null; // 장르 목록 (한 번 읽으면 기억)
let recHits = [];       // 장르 추천 가수 (지금 보여 주는 것)
let recGenre = null;    // { g: 장르, pool: 모은 가수, shown: 보여 준 가수 id, usedLists: 읽은 재생목록 }
async function drawRandom() {
  const lists = myLists || [];
  body.innerHTML = `<div class="mz-rand">
    <div class="mz-h">랜덤 재생목록</div>
    <p class="mz-note">가수를 고르고(비중 1~5), 곡 수나 시간을 정하면 그 가수들의 인기곡에서 골라 재생목록으로 만들고 바로 재생해요.</p>
    <div class="mz-rand-search"><div class="mz-rand-row"><input type="search" id="rq" placeholder="가수 찾기 (이름 앞부분만 써도 돼요)"><button class="pl-open ghost" id="rFromQueue" title="지금 다음 트랙 목록에 있는 가수들을 한 번에">다음 트랙에서 가수 가져오기</button></div><div class="mz-hits" id="rhits"></div></div>
    <div class="mz-genre">
      <button class="mz-gbtn" id="rGenreBtn" title="YouTube Music 의 장르별 대표 재생목록에서 많이 나오는 가수를 추천">${genreBtnLabel()}</button>
      <div class="mz-gpanel" id="rGenres" hidden></div>
      <div class="mz-recbox" id="rRec"></div>
    </div>
    <div class="mz-rand-picks" id="rpicks"></div>
    <div class="mz-rand-opts">
      <div class="seg" id="rmode"><button data-m="count" class="${R.mode === "count" ? "on" : ""}">곡 수</button><button data-m="time" class="${R.mode === "time" ? "on" : ""}">시간</button></div>
      <input type="number" id="ramount" min="1" max="500" value="${R.amount}">
      <span id="runit">${R.mode === "count" ? "곡" : `<select id="runitSel"><option value="min" ${R.unit === "min" ? "selected" : ""}>분</option><option value="hour" ${R.unit === "hour" ? "selected" : ""}>시간</option></select>`}</span>
      <label class="set-ck"><input type="checkbox" id="rpop" ${R.popular ? "checked" : ""}><span>인기곡 위주<small>많이 들은 곡이 더 자주 뽑혀요</small></span></label>
    </div>
    <div class="mz-rand-opts">
      <select id="rtarget"><option value="new">새 재생목록</option>${lists.map((l) => `<option value="${esc(l.id)}" ${R.target === l.id ? "selected" : ""}>‘${esc(l.t)}’에 덧붙이기</option>`).join("")}</select>
      <input type="text" id="rname" placeholder="이름 (비우면 자동)" value="${esc(R.name)}" ${R.target !== "new" ? "hidden" : ""}>
      <span class="mz-sp"></span>
      <button class="pl-open" id="rgo">${R.target === "new" ? "만들고 재생" : "덧붙이고 재생"}</button>
    </div>
    <div class="mz-note" id="rstatus"></div>
  </div>`;
  drawPicks();
  if (recGenre && recHits.length) drawRec(recGenre, recHits);
  if (!myLists) loadMyLists().then(() => { if (tab === 4 && myLists?.length) drawRandom(); });
  let t = null;
  $("#rq").oninput = (e) => {
    clearTimeout(t);
    const q = e.target.value.trim();
    if (!q) { $("#rhits").innerHTML = ""; return; }
    t = setTimeout(async () => {
      $("#rhits").innerHTML = '<div class="mz-note">찾는 중…</div>';
      try { searchHits = await call("searchArtists", { q }, 20); } catch (err) { $("#rhits").innerHTML = ""; fail(err); return; }
      if ($("#rq").value.trim() !== q) return;
      $("#rhits").innerHTML = searchHits.length ? searchHits.map((a, i) => `<button class="pl-open ghost" data-hit="${i}">＋ ${esc(a.name)}</button>`).join("") : '<div class="mz-note">못 찾았어요</div>';
    }, 350);
  };
  // 장르로 가수 추천: 장르 단추 → 그 장르에서 많이 나오는 가수 → ＋ 로 넣기 · 모두 넣기
  $("#rGenreBtn").onclick = async () => {
    const box = $("#rGenres");
    if (!box.hidden) { box.hidden = true; return; }
    box.hidden = false;
    if (!genreCache) {
      box.innerHTML = '<div class="mz-note">장르 읽는 중…</div>';
      try { genreCache = await call("genres", {}, 25); } catch (err) { box.innerHTML = ""; fail(err); return; }
    }
    if (!genreCache.length) { box.innerHTML = '<div class="mz-note">장르를 못 읽었어요</div>'; return; }
    drawGenrePanel();
  };
  $("#rGenres").onclick = async (e) => {
    const s = e.target.closest("[data-gsec]");
    if (s) { genreSec = s.dataset.gsec; drawGenrePanel(); return; }
    const b = e.target.closest("[data-genre]");
    if (!b) return;
    const g = genreCache[+b.dataset.genre];
    // 고르면 접고, 단추에 고른 장르를 보여 줌
    $("#rGenres").hidden = true;
    recGenre = { g, pool: [], shown: new Set(), usedLists: [] };
    $("#rGenreBtn").innerHTML = genreBtnLabel();
    await moreRec();
  };
  $("#rRec").onclick = (e) => {
    if (e.target.closest("[data-more]")) { moreRec(); return; }
    const b = e.target.closest("[data-rec]");
    if (!b) return;
    const add = b.dataset.rec === "all" ? recHits : [recHits[+b.dataset.rec]];
    let n = 0;
    for (const a of add) if (a && !R.picks.some((p) => p.id === a.id)) { R.picks.push({ id: a.id, name: a.name, w: 3, songs: null }); n++; }
    saveR(); drawPicks();
    markRecAdded();
    toast(n ? `가수 ${n}명을 넣었어요` : "이미 넣은 가수예요");
  };
  $("#rFromQueue").onclick = async () => {
    status("다음 트랙 읽는 중…");
    let q;
    try { q = await call("queue", {}, 15); } catch (err) { fail(err); return; }
    const seen = new Set();
    const list = [];
    for (const x of q) {
      const name = artistOf(x.artist);
      const key = x.aid || name.toLowerCase();
      if (!name || seen.has(key)) continue;
      seen.add(key);
      list.push({ aid: x.aid, name });
    }
    if (!list.length) { status(""); toast("다음 트랙이 비어 있어요"); return; }
    addArtistsToRandom(list);
  };
  $("#rhits").onclick = (e) => {
    const b = e.target.closest("[data-hit]");
    if (!b) return;
    const a = searchHits[+b.dataset.hit];
    if (!R.picks.some((p) => p.id === a.id)) { R.picks.push({ id: a.id, name: a.name, w: 3, songs: null }); saveR(); drawPicks(); }
    $("#rq").value = ""; $("#rhits").innerHTML = "";
  };
  $("#rmode").onclick = (e) => { const b = e.target.closest("[data-m]"); if (!b) return; R.mode = b.dataset.m; if (R.mode === "time" && R.amount > 300) R.amount = 60; saveR(); drawRandom(); };
  $("#ramount").onchange = (e) => { R.amount = Math.max(1, Math.min(500, +e.target.value || 1)); saveR(); };
  $("#runitSel") && ($("#runitSel").onchange = (e) => { R.unit = e.target.value; saveR(); });
  $("#rpop").onchange = (e) => { R.popular = e.target.checked; saveR(); };
  $("#rtarget").onchange = (e) => { R.target = e.target.value; saveR(); drawRandom(); };
  $("#rname").oninput = (e) => { R.name = e.target.value; saveR(); };
  $("#rgo").onclick = makeRandom;
}
function drawPicks() {
  const el = $("#rpicks");
  if (!el) return;
  el.innerHTML = R.picks.length ? R.picks.map((p, i) => `<div class="mz-pick"><b>${esc(p.name)}</b>
      <span class="mz-w" title="비중: 높을수록 이 가수 곡이 많이 들어가요">${[1, 2, 3, 4, 5].map((n) => `<button data-w="${i}:${n}" class="${p.w >= n ? "on" : ""}">●</button>`).join("")}</span>
      <button class="mz-x" data-del="${i}" title="빼기">✕</button></div>`).join("") +
      `<div class="mz-picks-foot"><span class="mz-note">가수 ${R.picks.length}명</span><button class="pl-open ghost" data-clear="1" title="고른 가수를 모두 빼기">모두 비우기</button></div>`
    : '<div class="mz-note">아직 고른 가수가 없어요</div>';
  el.onclick = async (e) => {
    if (e.target.closest("[data-clear]")) {
      if (R.picks.length > 2 && !(await confirmBox(`고른 가수 ${R.picks.length}명을 모두 뺄까요?`, R.picks.map((p) => p.name).join(", "), "모두 비우기"))) return;
      R.picks = []; saveR(); drawPicks(); return;
    }
    const w = e.target.closest("[data-w]");
    if (w) { const [i, n] = w.dataset.w.split(":").map(Number); R.picks[i].w = n; saveR(); drawPicks(); return; }
    const d = e.target.closest("[data-del]");
    if (d) { R.picks.splice(+d.dataset.del, 1); saveR(); drawPicks(); }
  };
}
/// Mac 판 RandomMix: 비중대로 가수를 뽑고 그 가수의 아직 안 넣은 곡을 뽑음 (인기곡 위주면 앞쪽 곡일수록 잘 뽑힘)
function mix(pools, limitSecs, limitCount, popular) {
  const left = pools.map((p) => p.songs.slice());
  const out = [];
  let total = 0;
  const done = () => (limitCount ? out.length >= limitCount : total >= limitSecs);
  while (!done()) {
    const avail = left.map((l, i) => i).filter((i) => left[i].length && pools[i].w > 0);
    if (!avail.length) break;
    let r = Math.random() * avail.reduce((a, i) => a + pools[i].w, 0);
    let pick = avail[0];
    for (const i of avail) { r -= pools[i].w; if (r < 0) { pick = i; break; } }
    const n = left[pick].length;
    let idx;
    if (popular) {
      const w = Array.from({ length: n }, (_, j) => 1 / (j + 3));
      let x = Math.random() * w.reduce((a, b) => a + b, 0);
      idx = 0;
      for (let j = 0; j < n; j++) { x -= w[j]; if (x < 0) { idx = j; break; } }
    } else idx = Math.floor(Math.random() * n);
    const s = left[pick].splice(idx, 1)[0];
    // 시간 기준: 넣으면 목표를 5분 넘게 넘어가는 곡은 건너뜀
    if (!limitCount && total + s.s > limitSecs + 300 && total > 0) continue;
    out.push(s); total += s.s;
  }
  for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [out[i], out[j]] = [out[j], out[i]]; }
  return out;
}
const describe = (s) => { const secs = s.reduce((a, x) => a + x.s, 0), h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60); return `${s.length}곡 · ${h ? `${h}시간 ${m}분` : `${m}분`}`; };
async function makeRandom() {
  const st = (t) => { const el = $("#rstatus"); if (el) el.textContent = t; status(t); };
  if (!R.picks.length) { toast("가수를 먼저 골라 주세요"); return; }
  $("#rgo").disabled = true;
  try {
    // 가수마다 인기곡 (같은 곡 다른 버전 · 1분 안 되는 클립은 빼기)
    for (const [k, p] of R.picks.entries()) {
      if (p.songs) continue;
      st(`곡 모으는 중… ${p.name} (${k + 1}/${R.picks.length})`);
      const raw = await call("artistSongs", { aid: p.id }, 60);
      const seen = new Set();
      p.songs = raw.filter((x) => {
        const key = x.t.toLowerCase().replace(/\s*[([].*$/, "").trim();
        if (!x.v || x.s < 60 || seen.has(key)) return false;
        seen.add(key); return true;
      }).map((x) => ({ ...x, a: p.name }));
    }
    const limitCount = R.mode === "count" ? R.amount : 0;
    const limitSecs = R.mode === "time" ? R.amount * (R.unit === "hour" ? 3600 : 60) : 0;
    const songs = mix(R.picks.map((p) => ({ songs: p.songs || [], w: p.w })), limitSecs, limitCount, R.popular);
    if (!songs.length) throw "고를 곡이 없어요";
    const vids = songs.map((s) => s.v);
    if (R.target === "new") {
      const d = new Date();
      const name = R.name.trim() || `랜덤 · ${R.picks.map((p) => p.name).slice(0, 3).join(", ")} · ${d.getMonth() + 1}/${d.getDate()}`;
      st(`만드는 중… (${describe(songs)})`);
      const id = await call("create", { name, vids }, 60);
      if (!id) throw "만들지 못했어요";
      myLists = null;
      st(`‘${name}’ 을 만들었어요 — ${describe(songs)} · 곧 재생해요`);
      setTimeout(() => playList(id), 1500);
    } else {
      const l = (myLists || []).find((x) => x.id === R.target);
      st(`‘${l?.t}’에 덧붙이는 중… (${describe(songs)})`);
      if (!(await call("add", { pid: R.target, vids }, 60))) throw "덧붙이지 못했어요";
      st(`‘${l?.t}’에 ${describe(songs)} 을 덧붙였어요 · 곧 재생해요`);
      setTimeout(() => playList(R.target), 1500);
    }
    status("");
  } catch (e) { st(""); fail(e); }
  finally { const b = $("#rgo"); if (b) b.disabled = false; }
}

// MARK: 시작 — 플레이어 창 (작게 · 크게), 위쪽 줄 단추, 곡이 바뀌면 다음 트랙 · 앨범 새로

let big = false;
try { big = localStorage.getItem("playerBig") === "1"; } catch { /* 없음 */ }

(async function () {
  let cfg = await readConfig();
  await applyTheme(cfg);
  // 크게 볼 때는 YouTube Music 전용, 작게 볼 때는 ‹ › 로 세 재생기
  Player.start(cfg, { site: big ? "ytmusic" : null });
  onConfigChanged(async () => { cfg = await readConfig(); applyTheme(cfg); Player.setCfg(cfg); drawLock(); drawPlayer(); });
  const el = $("#player");
  const line = $("#lyline");
  const showLine = () => !big && cfg.lyricsLine !== false && !cfg.detachLyrics;

  // MARK: 플레이어 · 가사 줄 · 큰 앨범
  function drawPlayer() {
    el._sig = "";
    Player.renderPlayer(el, { detached: true, noBig: true, lyricsOn: big ? tab === 1 : showLine() });
    line.hidden = !showLine();
    if (showLine()) { line._sig = ""; Player.renderLine(line, { detached: true }); }
  }
  Player.bindPlayer(el, {
    big: () => setBig(!big),
    lyrics: () => { if (big) { tab = 1; drawTabs(); show(); } else setConfig("lyricsLine", !showLine()); },
  });
  Player.bindLine(line, { detach: () => setConfig("detachLyrics", true) });
  let lastTitle = "";
  Player.on((tick) => {
    if (tick) {
      Player.tickPlayer(el);
      if (showLine()) Player.renderLine(line, { detached: true });
      if (big && tab === 1) Player.renderFull(body);
      return;
    }
    Player.renderPlayer(el, { detached: true, noBig: true, lyricsOn: big ? tab === 1 : showLine() });
    line.hidden = !showLine();
    if (showLine()) Player.renderLine(line, { detached: true });
    const art = Player.artUrl();
    const img = $("#art");
    if (art && img.dataset.want !== art) {
      img.dataset.want = art;
      // 큰 사진이 없으면(404 등) 원래 사진으로
      img.onerror = () => { const fb = Player.artFallback(); if (fb && img.src !== fb) img.src = fb; };
      img.src = art;
    }
    img.hidden = !art;
    if (!big) return;
    if (tab === 1) Player.renderFull(body);
    const t = Player.state().title || "";
    if (t !== lastTitle) {
      lastTitle = t;
      if (tab === 0) setTimeout(() => loadQueue(true), 1200);
      if (tab === 2) loadAlbums();
      if (tab === 3 && plSel) body.querySelectorAll(".mz-pl-tracks .mz-row").forEach((r) => r.classList.toggle("cur", plTracks[+r.dataset.k]?.t === t));
    }
  });
  Player.bindFull(body);

  // MARK: 작게 ↔ 크게
  const w = win();
  const getSize = (k, d) => { try { const v = JSON.parse(localStorage.getItem(k) || "null"); return v && v[0] > 100 && v[1] > 50 ? v : d; } catch { return d; } };
  async function rememberSize() {
    try {
      const f = await w.scaleFactor();
      const s = (await w.innerSize()).toLogical(f);
      localStorage.setItem(big ? "playerBigSize" : "playerSmallW", JSON.stringify(big ? [Math.round(s.width), Math.round(s.height)] : [Math.round(s.width), 100]));
    } catch { /* 없음 */ }
  }
  async function setBig(on, first) {
    if (!first) await rememberSize();
    big = on;
    try { localStorage.setItem("playerBig", big ? "1" : "0"); } catch { /* 없음 */ }
    document.body.classList.toggle("compact", !big);
    Player.setSite(big ? "ytmusic" : null);
    $("#bigBtn").innerHTML = big ? ICON_SMALL : ICON_BIG;
    $("#bigBtn").title = big ? "작게 보기" : "크게 보기 — 큰 앨범 · 다음 트랙 · 가사 · 앨범 · 재생목록 · 랜덤 (YouTube Music)";
    lastH = 0;
    try {
      if (big) {
        const [bw, bh] = getSize("playerBigSize", [940, 640]);
        await w.setAlwaysOnTop(false);
        await w.setMinSize(new T.dpi.LogicalSize(600, 400));
        await w.setSize(new T.dpi.LogicalSize(bw, bh));
      } else {
        await w.setAlwaysOnTop(true);
        await w.setMinSize(new T.dpi.LogicalSize(260, 60));
        const [sw] = getSize("playerSmallW", [360, 100]);
        const f = await w.scaleFactor();
        const s = (await w.innerSize()).toLogical(f);
        await w.setSize(new T.dpi.LogicalSize(sw, s.height));
      }
    } catch (e) { console.warn(e); }
    drawPlayer();
    if (big) { drawTabs(); show(); } else fit();
  }
  if (T) T.event.listen("player-big", () => { if (!big) setBig(true); else w.setFocus(); });

  // 작게: 창 높이 = 위쪽 줄 + 플레이어 + 가사 줄 (가사를 펼치거나 곡이 바뀌어 높이가 달라지면 따라감)
  let fitT = null, lastH = 0;
  function fit() {
    if (big) return;
    clearTimeout(fitT);
    fitT = setTimeout(async () => {
      const h = Math.ceil(["#app > .ptool", "#player", "#lyline"].reduce((a, s) => { const e = $(s); return a + (e && !e.hidden ? e.getBoundingClientRect().height : 0); }, 0) + 12);
      if (Math.abs(h - lastH) < 2) return;
      lastH = h;
      try {
        const f = await w.scaleFactor();
        const s = (await w.innerSize()).toLogical(f);
        await w.setSize(new T.dpi.LogicalSize(s.width, h));
      } catch { /* 없음 */ }
    }, 60);
  }
  new ResizeObserver(fit).observe(el);
  new ResizeObserver(fit).observe(line);
  // 크게: 오른쪽 아래 모서리를 끌어 크기 조절 (제목 막대가 없는 창)
  $("#mzResize").addEventListener("mousedown", (e) => { if (e.button === 0 && big) w.startResizeDragging("SouthEast").catch(() => {}); });
  // 아래 가장자리: 높이만 (위 끝은 그대로) · 더블클릭하면 기본 높이
  $("#mzResizeS").addEventListener("mousedown", (e) => { if (e.button === 0 && e.detail === 1 && big) w.startResizeDragging("South").catch(() => {}); });
  $("#mzResizeS").addEventListener("dblclick", async () => {
    if (!big) return;
    try {
      const f = await w.scaleFactor();
      const s = (await w.innerSize()).toLogical(f);
      await w.setSize(new T.dpi.LogicalSize(s.width, 640));
    } catch (e) { console.warn(e); }
  });
  // 크게 볼 때 바꾼 크기는 바로 기억 (다시 켜도 그대로)
  let sizeT = null;
  w.onResized(() => { if (!big) return; clearTimeout(sizeT); sizeT = setTimeout(rememberSize, 500); });

  // MARK: 위쪽 줄 — 재생기 아이콘 · 위치 고정 · 창 정리 · 크게 보기 · 설정 · 숨기기
  Sites.mount($("#sites"));
  const tool = $(".ptool");
  function drawLock() {
    const on = !!cfg.playerLocked;
    $("#lockBtn").innerHTML = on ? ICON_LOCK : ICON_UNLOCK;
    $("#lockBtn").classList.toggle("on", on);
    $("#lockBtn").title = on ? "위치 고정됨 — 누르면 풀려요" : "누르면 창 위치를 고정해요";
    for (const x of [tool, ...tool.querySelectorAll(".ptool-grip, .ptool-grip i")]) x.toggleAttribute("data-tauri-drag-region", !on);
  }
  drawLock();
  $("#lockBtn").onclick = () => { cfg.playerLocked = !cfg.playerLocked; drawLock(); setConfig("playerLocked", cfg.playerLocked); };
  $("#bigBtn").onclick = () => setBig(!big);
  $("#gearBtn").onclick = () => T.event.emit("ui", { open: "settings" });
  $("#tidyBtn").onclick = async () => {
    // 작게 볼 땐 창이 작아서 Windows 기본 메뉴로
    const M = T.menu;
    const item = (text, action) => M.MenuItem.new({ text, action });
    const done = (n, what) => toast(`창 ${n}개를 ${what}`);
    const menu = await M.Menu.new({ items: await Promise.all([
      item("열린 창 모두 닫기", async () => { if (confirm("지금 데스크탑의 창을 모두 닫을까요? 저장 안 한 문서가 있으면 앱이 저장할지 물어봐요.")) done(await invoke("tidy", { action: "close_all" }), "닫았어요"); }),
      item("모두 최소화", async () => done(await invoke("tidy", { action: "minimize_all" }), "최소화했어요")),
      item("최소화한 창 모두 되살리기", async () => done(await invoke("tidy", { action: "restore_all" }), "되살렸어요")),
      M.PredefinedMenuItem.new({ item: "Separator" }),
      item("앱 모두 종료 (도구함 · 탐색기 제외)…", () => T.event.emit("ui", { open: "quitall" })),
      item("앱 골라서 종료…", () => T.event.emit("ui", { open: "pickquit" })),
    ]) });
    menu.popup();
  };
  // 숨기기: 플레이어 창만 쓰면 트레이로, 아니면 도구함 창으로 되돌림
  $("#close").onclick = async () => {
    await rememberSize();
    if (cfg.playerMode !== false) w.hide(); else setConfig("detachPlayer", false);
  };

  // 위치 기억 (작게 볼 때 위치)
  let moveT = null;
  w.onMoved(({ payload }) => {
    clearTimeout(moveT);
    moveT = setTimeout(async () => {
      const f = await w.scaleFactor();
      const p = payload.toLogical ? payload.toLogical(f) : { x: payload.x / f, y: payload.y / f };
      setConfig("playerPos", [Math.round(p.x), Math.round(p.y)]);
    }, 500);
  });

  drawTabs();
  await setBig(big, true);
  setInterval(() => { if (big && tab === 0 && !document.hidden) loadQueue(true); }, 15000);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeMenu(); modal.hidden = true; }
    // 스페이스: 재생 / 멈춤 (글자 입력 칸에서는 그냥 띄어쓰기)
    if (e.key === " " && !e.repeat && !e.target.closest("input, textarea, select, [contenteditable]")) {
      e.preventDefault();
      Player.control("toggle");
    }
  });
  document.addEventListener("contextmenu", (e) => { if (!e.target.closest(".mz-row, input, textarea")) e.preventDefault(); });
})();

const ICON_BIG = '<svg viewBox="0 0 16 16"><path d="M9.5 2.5h4v4M6.5 13.5h-4v-4M13.5 2.5L9 7M2.5 13.5L7 9" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const ICON_SMALL = '<svg viewBox="0 0 16 16"><path d="M13 7H9V3M3 9h4v4M9 7l4.5-4.5M7 9l-4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const ICON_LOCK = '<svg viewBox="0 0 16 16"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="currentColor"/><path d="M5 7V5a3 3 0 016 0v2" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>';
const ICON_UNLOCK = '<svg viewBox="0 0 16 16"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M5 7V5a3 3 0 015.6-1.5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>';

// MARK: 다음 트랙 → 랜덤 가수

/// 다음 트랙의 가수 글자 '가수 • 앨범 • 조회수' 에서 가수만 (여럿이면 '&' · ',' 앞 첫 가수)
function artistOf(byline) {
  return String(byline || "").split(" • ")[0].split(/\s*(?:,|&|feat\.|ft\.)\s*/i)[0].trim();
}
/// 랜덤 재생목록 가수에 넣기: 가수 페이지 ID 가 있으면 그대로, 없으면 이름으로 찾아 첫 가수 (비중 3, 이미 있으면 건너뜀)
async function addArtistsToRandom(list) {
  let added = 0, missed = 0;
  for (const [i, a] of list.entries()) {
    status(`가수 넣는 중… ${i + 1}/${list.length}`);
    let id = a.aid, name = a.name;
    if (!id) {
      try { const hit = (await call("searchArtists", { q: name }, 20))[0]; if (hit) { id = hit.id; name = hit.name; } } catch { /* 건너뜀 */ }
    }
    if (!id) { missed++; continue; }
    if (R.picks.some((p) => p.id === id)) continue;
    R.picks.push({ id, name, w: 3, songs: null });
    added++;
  }
  saveR();
  status("");
  toast(added ? `가수 ${added}명을 랜덤에 넣었어요${missed ? ` (${missed}명은 못 찾음)` : ""}` : "새로 넣을 가수가 없어요");
  if (tab === 4) drawPicks(); else { tab = 4; drawTabs(); show(); }
}

// MARK: 장르 추천 — 모아 둔 가수 중 아직 안 보여 준 가수를 무작위로 (많이 나온 가수가 조금 더 잘 뽑힘)

/// 모은 가수에서 n명 뽑기: 무게 = √(나온 횟수) 라서 인기 가수만 몰리지 않음
function sampleArtists(pool, n) {
  const left = pool.slice();
  const out = [];
  while (out.length < n && left.length) {
    let r = Math.random() * left.reduce((a, x) => a + Math.sqrt(x.n || 1), 0);
    let k = 0;
    for (; k < left.length - 1; k++) { r -= Math.sqrt(left[k].n || 1); if (r < 0) break; }
    out.push(left.splice(k, 1)[0]);
  }
  return out;
}
async function moreRec() {
  const st = recGenre;
  if (!st) return;
  const rec = $("#rRec");
  const fresh = () => st.pool.filter((a) => !st.shown.has(a.id) && !R.picks.some((p) => p.id === a.id));
  // 남은 가수가 적으면 다른 재생목록을 더 읽어서 채움
  if (fresh().length < 8) {
    rec.innerHTML = `<div class="mz-note">‘${esc(st.g.t)}’ 재생목록에서 가수 모으는 중…</div>`;
    let r;
    try { r = await call("genreArtists", { id: st.g.id, params: st.g.params, lists: 8, max: 80, skip: st.usedLists }, 90); } catch (err) { rec.innerHTML = ""; fail(err); return; }
    if (recGenre !== st) return;
    st.usedLists.push(...(r.used || []));
    for (const a of r.artists || []) {
      const have = st.pool.find((x) => x.id === a.id);
      if (have) have.n += a.n; else st.pool.push(a);
    }
    // 장르 재생목록을 다 읽었는데도 다 보여 줬으면 처음부터 다시
    if (!fresh().length && st.pool.length) { st.shown.clear(); st.usedLists = []; }
  }
  const pick = sampleArtists(fresh(), 16);
  if (!pick.length) { rec.innerHTML = `<div class="mz-note">‘${esc(st.g.t)}’ 에서 새로 추천할 가수가 없어요</div>`; return; }
  pick.forEach((a) => st.shown.add(a.id));
  recHits = pick;
  drawRec(st, pick);
}

let genreSec = null; // 장르 펼침 칸에서 보고 있는 묶음 (장르 · 맞춤 · 분위기 …)
function genreBtnLabel() {
  return recGenre ? `<span class="mz-gk">장르</span><b>${esc(recGenre.g.t)}</b><span class="mz-gv">▾</span>` : `장르로 가수 추천<span class="mz-gv">▾</span>`;
}
function drawGenrePanel() {
  const box = $("#rGenres");
  if (!box || !genreCache) return;
  const groups = {};
  for (const [i, g] of genreCache.entries()) (groups[g.sec || "장르"] = groups[g.sec || "장르"] || []).push([i, g]);
  // '장르' 묶음을 먼저 (분위기 · 상황은 뒤에)
  const order = Object.keys(groups).sort((a, b) => (/장르|genre/i.test(b) ? 1 : 0) - (/장르|genre/i.test(a) ? 1 : 0));
  if (!groups[genreSec]) genreSec = order[0];
  const cur = recGenre && recGenre.g;
  box.innerHTML = (order.length > 1 ? `<div class="seg mz-gtabs">${order.map((s) => `<button data-gsec="${esc(s)}" class="${s === genreSec ? "on" : ""}">${esc(s)} <small>${groups[s].length}</small></button>`).join("")}</div>` : "") +
    `<div class="mz-gchips">${groups[genreSec].map(([i, g]) => `<button class="mz-gchip ${cur && cur.t === g.t && cur.params === g.params ? "on" : ""}" data-genre="${i}">${esc(g.t)}</button>`).join("")}</div>`;
}
/// 이름 → 같은 색 (가수 동그라미)
function hueOf(s) { let h = 0; for (const c of String(s)) h = (h * 31 + c.codePointAt(0)) % 360; return h; }
function drawRec(st, pick) {
  const rec = $("#rRec");
  if (!rec) return;
  rec.innerHTML = `<div class="mz-rechead"><b>‘${esc(st.g.t)}’ 추천 가수</b><small>${pick.length}명 · 모은 가수 ${st.pool.length}명</small><span class="mz-sp"></span>
      <button class="pl-open ghost" data-more="1" title="아직 안 보여 준 가수">↻ 다른 가수</button><button class="pl-open" data-rec="all">＋ 모두 넣기</button></div>
    <div class="mz-recgrid">${pick.map((a, i) => `<button class="mz-recit" data-rec="${i}" title="눌러서 랜덤 가수에 넣기 · 이 장르 재생목록에 ${a.n}번 나옴">
      <span class="mz-av" style="--h:${hueOf(a.name)}">${esc([...a.name.trim()][0] || "?")}</span>
      <span class="mz-t"><b>${esc(a.name)}</b><small>재생목록에 ${a.n}번</small></span><span class="mz-plus">＋</span></button>`).join("")}</div>`;
  markRecAdded();
}
/// 이미 랜덤 가수에 들어간 추천은 ✓
function markRecAdded() {
  const rec = $("#rRec");
  if (!rec) return;
  let left = 0;
  rec.querySelectorAll(".mz-recit[data-rec]").forEach((b) => {
    const a = recHits[+b.dataset.rec];
    const on = !!a && R.picks.some((p) => p.id === a.id);
    b.classList.toggle("added", on);
    b.querySelector(".mz-plus").textContent = on ? "✓" : "＋";
    if (!on) left++;
  });
  const all = rec.querySelector('[data-rec="all"]');
  if (all) all.disabled = !left;
}

/// '3:45' · '1:02:03' → 초
function secsOf(t) { return String(t || "").split(":").reduce((a, x) => a * 60 + (parseInt(x, 10) || 0), 0); }
/// 초 → '3:45' · '1:02:03'
function hms(s) { s = Math.max(0, Math.round(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = String(s % 60).padStart(2, "0"); return h ? `${h}:${String(m).padStart(2, "0")}:${x}` : `${m}:${x}`; }
