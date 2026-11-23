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
      th: ((it.querySelector('img') || {}).src) || '',
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
  bar.innerHTML = n ? `<span>${n}개 고름</span><span class="mz-sp"></span><button class="pl-open" id="barAdd">재생목록에 넣기 ▾</button><button class="pl-open ghost" id="barClear">고르기 취소</button>` : "";
  if (!n) return;
  $("#barAdd").onclick = (e) => { const r = e.target.getBoundingClientRect(); addMenu(r.left, r.top - 8 - 200, [...picked], [...pickedAlbums]); };
  $("#barClear").onclick = () => { picked.clear(); pickedAlbums.clear(); drawBar(); body.querySelectorAll("input.pick").forEach((x) => (x.checked = false)); };
}

// MARK: 다음 트랙

let queueSig = "";
async function loadQueue(quiet) {
  if (!quiet) status("읽는 중…");
  let q;
  try { q = await call("queue", {}, 15); } catch (e) { fail(e); return; }
  status("");
  if (tab !== 0) return;
  const sig = JSON.stringify(q.map((x) => [x.vid, x.cur]));
  if (quiet && sig === queueSig) return;
  queueSig = sig;
  if (!q.length) { body.innerHTML = `<div class="mz-empty">다음 트랙이 비어 있어요<br><small>YouTube Music 에서 곡이나 재생목록을 틀면 여기에 나와요</small></div>`; return; }
  body.innerHTML = q.map((x) => `<div class="mz-row ${x.cur ? "cur" : ""} ${x.auto ? "auto" : ""}" data-i="${x.i}" data-vid="${esc(x.vid)}">
      <input type="checkbox" class="pick" ${picked.has(x.vid) ? "checked" : ""} title="골라서 재생목록에 넣기">
      ${x.th ? `<img src="${esc(x.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(x.title)}</b><small>${esc(x.artist)}</small></span>
      <span class="mz-d">${x.cur ? "▶ " : ""}${esc(x.dur)}</span></div>`).join("");
  body.querySelector(".mz-row.cur")?.scrollIntoView({ block: "center" });
}
body.addEventListener("change", (e) => {
  const c = e.target.closest("input.pick");
  if (!c) return;
  const row = c.closest("[data-vid],[data-album]");
  const set = row.dataset.album ? pickedAlbums : picked;
  const k = row.dataset.album || row.dataset.vid;
  c.checked ? set.add(k) : set.delete(k);
  drawBar();
});
body.addEventListener("click", async (e) => {
  if (e.target.closest("input")) return;
  if (tab === 0) {
    const row = e.target.closest(".mz-row[data-i]");
    if (row) { await call("playQueue", { i: +row.dataset.i }).catch(fail); setTimeout(() => loadQueue(true), 800); }
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
    ]);
  }
  if (tab === 2 && row.dataset.album) albumMenu(e.clientX, e.clientY, row.dataset.album, row.dataset.title);
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
  body.innerHTML = `<div class="mz-albums"><div class="mz-h">${esc(r.name)}</div>` + Object.entries(groups).map(([sec, list]) =>
    `<div class="mz-sec">${esc(sec)}</div><div class="mz-grid">${list.map((a) => `<div class="mz-album mz-row" data-album="${esc(a.id)}" data-title="${esc(a.t)}">
      <input type="checkbox" class="pick" ${pickedAlbums.has(a.id) ? "checked" : ""} title="골라서 재생목록에 넣기">
      <img src="${esc(a.th)}" alt="" referrerpolicy="no-referrer"><b>${esc(a.t)}</b><small>${esc(a.sub)}</small></div>`).join("")}</div>`).join("") + "</div>";
}
body.addEventListener("dblclick", (e) => {
  const a = e.target.closest("[data-album]");
  if (a && tab === 2) playAlbum(a.dataset.album, a.dataset.title);
});
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
    { label: "앨범 재생 (두 번 누르기)", action: () => playAlbum(id, title) },
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
async function drawRandom() {
  const lists = myLists || [];
  body.innerHTML = `<div class="mz-rand">
    <div class="mz-h">랜덤 재생목록</div>
    <p class="mz-note">가수를 고르고(비중 1~5), 곡 수나 시간을 정하면 그 가수들의 인기곡에서 골라 재생목록으로 만들고 바로 재생해요.</p>
    <div class="mz-rand-search"><input type="search" id="rq" placeholder="가수 찾기 (이름 앞부분만 써도 돼요)"><div class="mz-hits" id="rhits"></div></div>
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
      <button class="mz-x" data-del="${i}" title="빼기">✕</button></div>`).join("") : '<div class="mz-note">아직 고른 가수가 없어요</div>';
  el.onclick = (e) => {
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

// MARK: 시작 — 플레이어 · 큰 앨범 · 곡이 바뀌면 다음 트랙 · 앨범 새로

(async function () {
  let cfg = await readConfig();
  await applyTheme(cfg);
  Player.start(cfg);
  onConfigChanged(async () => { cfg = await readConfig(); applyTheme(cfg); Player.setCfg(cfg); });
  const el = $("#player");
  Player.bindPlayer(el, { lyrics: () => { tab = 1; drawTabs(); show(); } });
  let lastTitle = "";
  Player.on((tick) => {
    if (tick) { Player.tickPlayer(el); if (tab === 1) Player.renderFull(body); return; }
    Player.renderPlayer(el, { detached: true, noBig: true });
    const art = Player.artUrl();
    const img = $("#art");
    if (art && img.getAttribute("src") !== art) img.src = art;
    img.hidden = !art;
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
  drawTabs();
  show();
  // 다음 트랙: 가끔 새로 (곡 순서가 바뀌었을 수 있음)
  setInterval(() => { if (tab === 0 && !document.hidden) loadQueue(true); }, 15000);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeMenu(); modal.hidden = true; } });
})();
