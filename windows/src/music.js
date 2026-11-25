// 크게 보기 (Mac 판 bigplayer.swift · playlists.swift · random.swift 를 Windows 로)
// 왼쪽: 큰 앨범 · 곡 · 조작 / 오른쪽 탭: 다음 트랙 · 가사 · 앨범 · 플레이리스트 · 랜덤 플레이리스트
// YouTube Music 창(숨겨져 있어도 됨) 페이지 안에서 로그인한 계정으로 요청 — 쿠키 · 서명은 페이지 밖으로 안 나감
"use strict";

// MARK: 페이지 함수 (YouTube Music 창에서 돌림 — args · api · collect · nextToken · albumList 를 씀)

/// 페이지 대기열 손잡이 (QQ: 대기열, QC: 대기열 화면, R: 곡 정보 꺼내기) — YouTube Music 이 자기 화면에서 고칠 때와 같은 함수
const QCTL = `
    const QEL = document.querySelector('ytmusic-player-queue');
    const QC = QEL && QEL.polymerController;
    const QQ = QC && QC.queue;
    const R = (x) => x && (x.playlistPanelVideoWrapperRenderer ? x.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer : x.playlistPanelVideoRenderer);
`;

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
      // 플레이리스트 자리 ID · 대기열에 든 곡 ID (내 플레이리스트에서 빼기 · 옮기기용)
      sid: (it.data && it.data.playlistSetVideoId) || '',
      pvid: (it.data && it.data.videoId) || '',
      aid: ((it.data && it.data.longBylineText && it.data.longBylineText.runs || []).map((r) => r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId).find((x) => x && x.startsWith('UC'))) || '',
    })).filter((x) => x.title && (autoOn || !x.auto));`,
  playQueue: `
    const list = [...document.querySelectorAll('ytmusic-player-queue-item')].filter((i) => !i.closest('#counterpart-renderer'));
    const it = list[args.i]; if (!it) return false;
    const b = it.querySelector('ytmusic-play-button-renderer #play-button, ytmusic-play-button-renderer, .song-info');
    (b || it).click(); return true;`,
  autoplay: `const t = document.querySelector('#automix'); if (t && !!t.checked !== args.on) t.click(); return t ? t.checked : null;`,
  autoplayState: `const t = document.querySelector('#automix'); return t ? !!t.checked : null;`,
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
  // 앨범 수록곡 (앨범 페이지 MPREb… → 플레이리스트 OLAK… · 곡들). 앨범 페이지엔 곡마다 가수가 없어서 a 는 비는 경우가 많음
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
  // 플레이리스트 (Mac 판 playlists.swift)
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
        // 앨범 (세 번째 칸 · 앨범 페이지 MPRE… 링크) — 영상이면 비어 있음
        const alr = ((i.flexColumns[2] && i.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs) || []).find((x) => x.navigationEndpoint && x.navigationEndpoint.browseEndpoint && /^MPRE/.test(x.navigationEndpoint.browseEndpoint.browseId || ''));
        out.push({ t: txt(i.flexColumns[0]), a: txt(i.flexColumns[1]), d: fx ? (fx.text.runs || [{}])[0].text || '' : '', v: d.videoId, s: d.playlistSetVideoId, th: th ? th.url : '',
          al: alr ? alr.text : '', alid: alr ? alr.navigationEndpoint.browseEndpoint.browseId : '' });
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
  rename: `const j = await api('browse/edit_playlist', { playlistId: args.pid, actions: [{ action: 'ACTION_SET_PLAYLIST_NAME', playlistName: args.name }] }); return j.status === 'STATUS_SUCCEEDED';`,
  // 다음 트랙에서 내 플레이리스트 고치기 (Mac 판 queueedit.swift) — 플레이리스트는 edit_playlist, 대기열은 YouTube Music 페이지의 대기열을 직접
  // 지금 듣는 플레이리스트: 주소의 list=, 없으면(도구함을 다시 켜서 이어 재생 등) 대기열 곡들에 붙은 플레이리스트
  currentList: QCTL + `
    const u = new URLSearchParams(location.search).get('list');
    if (u) return u;
    const n = {};
    for (const x of (QQ ? QQ.getItems() : [])) { const r = R(x), w = r && r.navigationEndpoint && r.navigationEndpoint.watchEndpoint; if (w && w.playlistId) n[w.playlistId] = (n[w.playlistId] || 0) + 1; }
    return Object.keys(n).sort((a, b) => n[b] - n[a])[0] || '';`,
  removeMany: `const j = await api('browse/edit_playlist', { playlistId: args.pid, actions: args.sids.map((s, k) => ({ action: 'ACTION_REMOVE_VIDEO', setVideoId: s, removedVideoId: args.vids[k] })) }); return j.status === 'STATUS_SUCCEEDED';`,
  moveBefore: `
    const a = { action: 'ACTION_MOVE_VIDEO_BEFORE', setVideoId: args.sid };
    if (args.before) a.movedSetVideoIdSuccessor = args.before;
    const j = await api('browse/edit_playlist', { playlistId: args.pid, actions: [a] });
    return j.status === 'STATUS_SUCCEEDED';`,
  // 넣고 새로 생긴 자리 ID 를 곡 ID 별로 (이미 있던 곡은 건너뛰어서 빠짐)
  addIds: `
    const j = await api('browse/edit_playlist', { playlistId: args.pid, actions: args.vids.map((v) => ({ action: 'ACTION_ADD_VIDEO', addedVideoId: v, dedupeOption: 'DEDUPE_OPTION_SKIP' })) });
    if (j.status !== 'STATUS_SUCCEEDED') return null;
    const m = {};
    for (const r of (j.playlistEditResults || [])) { const d = r.playlistEditVideoAddedResultData; if (d && d.videoId) m[d.videoId] = d.setVideoId || ''; }
    return m;`,
  qRemove: QCTL + `
    if (!QQ) return false;
    const items = QQ.getItems(), r = R(items[args.i]);
    if (!r || (args.sid && r.playlistSetVideoId !== args.sid)) return false;
    const ix = r.navigationEndpoint && r.navigationEndpoint.watchEndpoint && r.navigationEndpoint.watchEndpoint.index;
    if (typeof ix === 'number') QQ.removeItem(String(ix)); else QQ.store.dispatch({ type: 'REMOVE_ITEM', payload: args.i });
    return QQ.getItems().length === items.length - 1;`,
  qShuffled: QCTL + `return !!(QQ && QQ.store.getState().queue.shuffleEnabled);`,
  qMove: QCTL + `
    if (!QQ || !QC.onDrop) return false;
    const ct = QEL.querySelector('#contents'), kids = [...ct.children], items = QQ.getItems();
    if (kids.length !== items.length || !kids[args.from]) return false;
    const r = R(items[args.from]); if (!r || (args.sid && r.playlistSetVideoId !== args.sid) || (args.vid && r.videoId !== args.vid)) return false;
    const el = kids[args.from];
    ct.insertBefore(el, kids[args.to] || null);
    QC.onDrop({ detail: { dragEl: el } });
    return true;`,
  qInsert: QCTL + `
    const vids = args.vids || [], sids = args.sids || [];
    if (!QQ || !vids.length) return 0;
    const j = await api('music/get_queue', { videoIds: vids });
    const items = (j.queueDatas || []).map((q) => q.content).filter(Boolean);
    items.forEach((c, k) => { const r = R(c); if (r && sids[k]) r.playlistSetVideoId = sids[k]; });
    if (!items.length) return 0;
    const n = QQ.getItems().length;
    const cur = args.afterCurrent && QQ.getCurrentItemIndex ? QQ.getCurrentItemIndex() : -1;
    const idx = cur >= 0 ? Math.min(n, cur + 1) : (args.at == null || args.at < 0 || args.at > n) ? n : args.at;
    QQ.store.dispatch({ type: 'ADD_ITEMS', payload: { nextQueueItemId: QQ.store.getState().queue.nextQueueItemId, index: idx, items, shouldAssignIds: true } });
    return QQ.getItems().length - n;`,
  qSetSid: QCTL + `
    if (!QQ) return false;
    const it = QQ.getItems().map(R).reverse().find((r) => r && r.videoId === args.vid && (!r.playlistSetVideoId || (args.old && r.playlistSetVideoId === args.old)));
    if (it) it.playlistSetVideoId = args.sid;
    return !!it;`,
  // 곡의 앨범 (앨범 페이지 ID MPRE… · 이름) — 다음 트랙 곡 오른쪽 클릭 '이 곡의 앨범을 …'
  songAlbum: `
    for (const v of (args.vids || []).filter(Boolean)) {
      const s = JSON.stringify(await api('next', { videoId: v, isAudioOnly: true }));
      const m = s.match(/"text":"([^"]+)","navigationEndpoint":\{"clickTrackingParams":"[^"]*","browseEndpoint":\{"browseId":"(MPRE[^"]+)"/) || s.match(/()"browseId":"(MPRE[^"]+)"/);
      if (m) return { id: m[2], name: m[1] || '' };
    }
    return null;`,
  // 다음 트랙 나머지 다 불러오기 (YouTube Music 은 50곡씩만 불러옴 — 플레이리스트 · 앨범만, 섞어 듣기 · 라디오는 그대로)
  qLoadAll: QCTL + `
    if (!QQ || !QQ.continuation || QQ.pendingFetchItemsRequest) return 0;
    if (QQ.store.getState().queue.shuffleEnabled) return 0;
    // 플레이리스트 · 앨범만 (라디오 · 믹스 RD… 는 끝이 없어서 그대로)
    const ids = {}; for (const x of QQ.getItems()) { const r = R(x), w = r && r.navigationEndpoint && r.navigationEndpoint.watchEndpoint; if (w && w.playlistId) ids[w.playlistId] = (ids[w.playlistId] || 0) + 1; }
    const pl = Object.keys(ids).sort((a, b) => ids[b] - ids[a])[0] || '';
    if (!/^(PL|OLAK|VL)/.test(pl)) return 0;
    let added = 0;
    for (let p = 0; p < 20 && QQ.continuation; p++) {
      const tok = QQ.continuation;
      const j = await api('next', { continuation: tok, enablePersistentPlaylistPanel: true, isAudioOnly: true });
      const pc = (j.continuationContents || {}).playlistPanelContinuation;
      if (!pc || QQ.continuation !== tok) break;   // YouTube Music 이 그사이 직접 불러왔으면 그만
      const items = (pc.contents || []).filter((x) => x.playlistPanelVideoRenderer || x.playlistPanelVideoWrapperRenderer);
      const nx = (pc.continuations || [])[0] || {};
      QQ.continuation = (nx.nextContinuationData || {}).continuation || null;
      if (!items.length) break;
      QQ.store.dispatch({ type: 'ADD_ITEMS', payload: { nextQueueItemId: QQ.store.getState().queue.nextQueueItemId, index: QQ.getItems().length, items, shouldAssignIds: true } });
      added += items.length;
    }
    return added;`,
  // 노래 검색 (YouTube Music '노래' 칸만)
  searchSongs: `
    let j = await api('search', { query: args.q });
    let p = null;
    for (const c of collect(j, 'chipCloudChipRenderer')) {
      const t = ((c.text || {}).runs || [{}])[0].text || '';
      const e = c.navigationEndpoint && c.navigationEndpoint.searchEndpoint;
      if (e && e.params && /^(노래|Songs|曲|歌曲)$/i.test(t.trim())) { p = decodeURIComponent(e.params); break; }
    }
    if (p) j = await api('search', { query: args.q, params: p });
    const txt = (c) => ((c && c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map((x) => x.text).join('');
    const out = [];
    for (const i of collect(j, 'musicResponsiveListItemRenderer')) {
      const v = (i.playlistItemData && i.playlistItemData.videoId) || '';
      if (!v || out.some((o) => o.v === v)) continue;
      const runs = ((i.flexColumns[1] && i.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs) || []).map((x) => x.text);
      const parts = runs.join('').split(' • ').map((s) => s.trim()).filter(Boolean);
      const dur = parts.length && /^\\d+(:\\d\\d)+$/.test(parts[parts.length - 1]) ? parts.pop() : '';
      if (parts.length > 1 && /^(노래|Song|曲|歌曲)$/i.test(parts[0])) parts.shift();
      const th = ((i.thumbnail && i.thumbnail.musicThumbnailRenderer && i.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails) || []).slice(-1)[0];
      out.push({ t: txt(i.flexColumns[0]), a: parts.join(' · '), d: dur, v, th: th ? th.url : '' });
      if (out.length >= 20) break;
    }
    return out;`,
  // 랜덤 플레이리스트 (Mac 판 random.swift)
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
  // 장르에서 가수 추천: 그 장르의 대표 플레이리스트 몇 개를 열어 가장 많이 나오는 가수
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
    // 무작위로 섞어서 (이미 읽은 건 빼고) 몇 개만 — 누를 때마다 다른 플레이리스트에서 모음
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

/// YouTube Music 창에서 플레이리스트(또는 앨범 OLAK…)을 재생. 자동재생은 끔 (목록이 끝나면 섞인 곡이 이어 붙지 않게)
async function playList(list, from) {
  const u = `https://music.youtube.com/watch?${from ? `v=${encodeURIComponent(from)}&` : ""}list=${encodeURIComponent(list)}`;
  await invoke("web_eval", { label: "ytmusic", js: `location.href = ${JSON.stringify(u)}` });
  for (const t of [4000, 8000, 12000]) setTimeout(() => call("autoplay", { on: autoPref() ?? false }).catch(() => {}), t);
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

// MARK: 플레이리스트 캐시 · 넣기 메뉴 (다음 트랙 · 앨범 · 플레이리스트 탭이 같이 씀)

let myLists = null;
const renamed = {}; // 플레이리스트 id → 바꾼 이름
async function loadMyLists(force) {
  if (myLists && !force) return myLists;
  myLists = await call("myPlaylists").catch(() => null);
  if (myLists) for (const k of Object.keys(qDelta)) delete qDelta[k]; // 새로 받은 곡 수엔 고친 게 들어 있음
  // 방금 이름을 바꾼 건 서버 목록에 늦게 반영될 수 있어서 바꾼 이름으로
  for (const l of myLists || []) if (renamed[l.id]) l.t = renamed[l.id];
  return myLists || [];
}
/// "플레이리스트에 넣기" 메뉴: 내 플레이리스트들 + 새 플레이리스트
async function addMenu(x, y, vids, albums) {
  if (!vids.length && !albums.length) { toast("넣을 곡을 골라 주세요"); return; }
  status("플레이리스트 읽는 중…");
  const lists = await loadMyLists();
  status("");
  showMenu(x, y, [{ label: "플레이리스트에 넣기", header: true },
    ...lists.map((l) => ({ label: l.t, action: () => addTo(l.id, l.t, vids, albums) })),
    "-", { label: "새 플레이리스트…", action: async () => {
      const name = await ask("새 플레이리스트 이름", "", "예: 드라이브");
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

let drawSide = () => {}; // 왼쪽 아래 가사 칸 (시작할 때 채움)
let applyLevel = async () => {}; // 창 위치 (시작할 때 채움)
let drawNext = () => {};          // 작게 볼 때 다음 곡 줄
const TABS = ["다음 트랙", "가사", "앨범", "플레이리스트", "랜덤"];
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
  drawSide();
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
/// 아래 줄: 고른 것이 있으면 [플레이리스트에 넣기] [고르기 취소]
function drawBar() {
  const n = picked.size + pickedAlbums.size;
  const bar = $("#mzBar");
  bar.hidden = !n || (tab !== 0 && tab !== 2);
  const label = [picked.size ? `${picked.size}곡` : "", pickedAlbums.size ? `앨범 ${pickedAlbums.size}개` : ""].filter(Boolean).join(" · ");
  // 지금 플레이리스트와 연결된 다음 트랙에서 고른 곡이면 [빼기]도
  const rm = tab === 0 && qLink && !pickedAlbums.size ? qItems.filter((x) => !x.auto && x.sid && picked.has(x.vid)) : [];
  const canRemove = rm.length && rm.length === picked.size;
  bar.innerHTML = n ? `<span>${label} 고름</span><span class="mz-sp"></span>${canRemove ? `<button class="pl-open danger" id="barRemove" title="‘${esc(qLink.t)}’ · 다음 트랙에서 빼기">빼기</button>` : ""}<button class="pl-open" id="barPlay" title="고른 곡만 바로 재생 (앨범을 고르면 그 앨범의 모든 곡)">▶ 재생</button><button class="pl-open" id="barAdd">플레이리스트에 넣기 ▾</button><button class="pl-open ghost" id="barClear">고르기 취소</button>` : "";
  if (!n) return;
  $("#barPlay").onclick = async () => {
    const vids = [...picked];
    for (const id of pickedAlbums) {
      try { const r = albumTrackCache.get(id) || await call("albumTracks", { id }, 30); albumTrackCache.set(id, r); vids.push(...r.out.map((x) => x.v)); } catch (e) { /* 건너뜀 */ }
    }
    await playVideos(vids);
  };
  $("#barAdd").onclick = (e) => { const r = e.target.getBoundingClientRect(); addMenu(r.left, r.top - 8 - 200, [...picked], [...pickedAlbums]); };
  if (canRemove) $("#barRemove").onclick = () => { picked.clear(); body.classList.remove("picking"); removeMany(rm); drawBar(); };
  $("#barClear").onclick = () => { picked.clear(); pickedAlbums.clear(); drawBar(); body.querySelectorAll("input.pick").forEach((x) => (x.checked = false)); };
}

// MARK: 다음 트랙

let queueSig = "";
let qLeft = null; // { dur: 지금 곡 길이, after: 그 뒤 곡들 합, title }
function queueLeft() {
  if (!qLeft) return 0;
  const st = Player.state();
  const p = Player.position ? Player.position() : st.position || 0;
  return Math.max(0, qLeft.dur - p) + qLeft.after;
}
function queueLeftTick() {
  const el = document.getElementById("qLeft");
  if (el && qLeft) el.textContent = hms(queueLeft());
}
// 내 플레이리스트와 연결: 지금 듣는 플레이리스트가 내 것이면, 여기서 빼고 · 옮기고 · 넣은 게 플레이리스트에도 반영 (Mac 판과 같음)
let qItems = [];        // 지금 보이는 다음 트랙 (자동재생 곡 포함, 화면 순서)
let qLink = null;       // { id, t, total } — 지금 듣는 내 플레이리스트
let qLinkChecked = "";  // 새로 만든 플레이리스트일 수 있어 목록을 한 번 다시 받은 플레이리스트
const qDelta = {};      // 플레이리스트 id → 여기서 넣고 뺀 곡 수 (목록의 'N곡' 이 늦게 바뀌어서)
let qUndo = null;       // { entries: [{ it, after }], pid } — 방금 뺀 곡 되돌리기
let qTouch = 0;         // 마지막으로 목록을 직접 만진 때 (8초 동안은 지금 곡으로 저절로 스크롤 안 함)
let qScrolledFor = "";  // 마지막으로 스크롤해 맞춘 지금 곡
let qJustDragged = 0;
let qFollow = true;     // 곡이 바뀌면 지금 곡으로 스크롤 (취향 — 켜고 끌 수 있음)
try { qFollow = localStorage.getItem("mzQueueFollow") !== "0"; } catch { /* 없음 */ }
const touched = () => { qTouch = Date.now(); };
/// 자동재생 (YouTube Music '유사한 콘텐츠를 현재 재생목록 끝에 추가'): 직접 고른 값 (null: 아직 안 고름 — 틀 때 끔)
function autoPref() { try { const v = localStorage.getItem("mzAutoplay"); return v === null ? null : v === "1"; } catch { return null; } }
let qAuto = null; // 페이지의 지금 자동재생 상태
let loadAllTried = "";
const ICON_SEARCH = '<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10.4 10.4 14 14" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
const ICON_FOLLOW = '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.5" fill="none" stroke="currentColor" stroke-width="1.4"/><circle cx="8" cy="8" r="2" fill="currentColor"/><path d="M8 .8v2.4M8 12.8v2.4M.8 8h2.4M12.8 8h2.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';

async function findLink() {
  const l = await call("currentList", {}, 10).catch(() => "");
  if (!l || !l.startsWith("PL")) return null;
  let p = (await loadMyLists()).find((x) => x.id === l);
  if (!p && myLists && qLinkChecked !== l) { qLinkChecked = l; p = (await loadMyLists(true)).find((x) => x.id === l); }
  if (!p) return null;
  // 목록 부제 '싹튼 • 트랙 27개' (영어면 '27 tracks') 에서 전체 곡 수
  const m = String(p.sub || "").match(/트랙\s*([\d,]+)\s*개|([\d,]+)\s*(?:곡|tracks?|songs?)/i);
  const n = m ? +(m[1] || m[2]).replace(/,/g, "") : 0;
  return { id: p.id, t: p.t, total: n ? n + (qDelta[p.id] || 0) : 0 };
}
function refreshQueue(ms = 400) { setTimeout(() => { if (tab === 0) { queueSig = ""; loadQueue(true, true); } }, ms); }

async function loadQueue(quiet, force) {
  // 방금 고친 직후엔 YouTube Music 이 아직 옛 목록을 줄 수 있어서 잠깐 쉼 (고친 쪽에서 refreshQueue 로 다시 읽음)
  if (quiet && !force && Date.now() - qTouch < 2500) return;
  if (!quiet) { status("읽는 중…"); qScrolledFor = ""; }
  let q, link;
  let auto;
  try { [q, link, auto] = await Promise.all([call("queue", {}, 15), findLink(), call("autoplayState").catch(() => null)]); } catch (e) { fail(e); return; }
  // 직접 고른 자동재생 값은 어떤 목록이든 지킴
  const want = autoPref();
  if (want !== null && auto !== null && auto !== want) { call("autoplay", { on: want }).catch(() => {}); auto = want; }
  q = Array.isArray(q) ? q : [];
  status("");
  if (tab !== 0 || drag?.on) return;
  if (link?.id !== qLink?.id) qUndo = null;
  qLink = link;
  qAuto = auto;
  // 일부만 불러온 긴 플레이리스트 · 앨범이면 나머지를 한 번에 (곡 수가 바뀔 때마다 한 번)
  const mainN = q.filter((x) => !x.auto).length, lk = `${q[0]?.vid}|${mainN}`;
  if (mainN >= 20 && lk !== loadAllTried) { loadAllTried = lk; call("qLoadAll", {}, 60).then((n) => { if (n > 0) refreshQueue(300); }).catch(() => {}); }
  const sig = JSON.stringify([q.map((x) => [x.vid, x.cur, x.sid]), link?.id, link?.t, !!qUndo, auto]);
  if (quiet && sig === queueSig) return;
  renderQueue(q, sig);
}

function renderQueue(q, sig = "") {
  queueSig = sig;
  qItems = q;
  if (!q.length) { qLeft = null; body.innerHTML = `<div class="mz-empty">다음 트랙이 비어 있어요<br><small>YouTube Music 에서 곡이나 플레이리스트를 틀면 여기에 나와요</small></div>`; return; }
  // 몇 곡 중 몇 번째 · 남은 시간 (위) / 전체 재생시간 (아래). 자동재생으로 붙은 곡은 따로 셈
  const main = q.filter((x) => !x.auto);
  const curK = q.findIndex((x) => x.cur);
  const total = main.reduce((a, x) => a + secsOf(x.dur), 0);
  const autoTotal = q.filter((x) => x.auto).reduce((a, x) => a + secsOf(x.dur), 0);
  const after = curK >= 0 ? main.filter((x) => q.indexOf(x) > curK).reduce((a, x) => a + secsOf(x.dur), 0) : total;
  // 남은 시간 = 지금 곡의 남은 부분 + 그 뒤 곡들 (재생 위치를 따라 1초마다 줄어듦 — queueLeftTick)
  qLeft = curK >= 0 && !q[curK].auto ? { dur: secsOf(q[curK].dur), after, title: q[curK].title } : null;
  const link = qLink;
  const partial = !!(link && link.total > main.length);
  let head = qLeft
    ? `<b>${main.length}곡 중 ${main.indexOf(q[curK]) + 1}번째</b> · 남은 시간 <span id="qLeft">${hms(queueLeft())}</span>`
    : `<b>${main.length}곡</b>`;
  if (partial) head = `<b>전체 ${link.total}곡 중 ${main.length}곡 불러옴</b>${qLeft ? ` · 지금 ${main.indexOf(q[curK]) + 1}번째 · 불러온 곡 남은 시간 <span id="qLeft">${hms(queueLeft())}</span>` : ""}`;
  // 위 고정 줄 오른쪽: 🔍 검색해서 넣기(연결됐을 때) · ◎ 지금 곡 따라가기
  const autoOn = qAuto ?? autoPref() ?? false;
  const icons = `<span class="mz-auto"><button class="mz-qbtn mz-info" id="qAutoInfo" title="자동재생이 뭔가요?">ⓘ</button><span>자동재생</span>
      <label class="mz-switch" title="자동재생: 유사한 콘텐츠를 지금 목록 끝에 추가 — ${autoOn ? "켬" : "끔"}"><input type="checkbox" id="qAuto" ${autoOn ? "checked" : ""}><i></i></label></span>` + `${link ? `<button class="mz-qbtn" id="qSearch" title="‘${esc(link.t)}’에 넣을 노래 찾기 (플레이리스트 · 다음 트랙 끝에)">${ICON_SEARCH}</button>` : ""}` +
    `<button class="mz-qbtn ${qFollow ? "on" : ""}" id="qFollow" title="${qFollow ? "곡이 바뀌면 지금 곡으로 스크롤해요 — 누르면 끔" : "목록이 저절로 움직이지 않아요 — 누르면 지금 곡 따라가기"}">${ICON_FOLLOW}</button>`;
  let note = "";
  if (link) {
    if (qUndo) {
      const u = qUndo.entries;
      const what = u.length === 1 ? `‘${esc(u[0].it.title.slice(0, 16))}’을` : `${u.length}곡을`;
      note = `<div class="mz-qlink">${what} ‘${esc(link.t)}’에서 뺐어요<span class="mz-sp"></span><button class="pl-open ghost" id="qUndo">되돌리기</button></div>`;
    } else note = `<div class="mz-qlink">‘${esc(link.t)}’과 연결됨 · ⊖ 빼기 · 끌어서 옮기기 · 🔍 검색해서 넣기 — 플레이리스트에도 반영돼요</div>`;
  }
  const editable = (x) => link && !x.auto && x.sid;
  // 끌어서 순서 바꾸기: 내 플레이리스트면 플레이리스트에도, 아니면(앨범 · 라디오 · 남의 플레이리스트) 다음 트랙에서만
  const movable = (x) => !x.auto && (!link || x.sid);
  body.innerHTML = `<div class="mz-qhead"><span class="mz-qtext">${head}</span><span class="mz-sp"></span>${icons}</div>${note}` + q.map((x, k) => `<div class="mz-row ${x.cur ? "cur" : ""} ${x.auto ? "auto" : ""} ${editable(x) ? "edit" : ""} ${movable(x) ? "mov" : ""}" data-k="${k}" data-i="${x.i}" data-vid="${esc(x.vid)}" data-aid="${esc(x.aid)}" data-artist="${esc(artistOf(x.artist))}">
      <span class="mz-num">${x.auto ? "" : main.indexOf(x) + 1}<input type="checkbox" class="pick" ${picked.has(x.vid) ? "checked" : ""} title="골라서 플레이리스트에 넣기${link ? " · 빼기" : ""}"></span>
      ${x.th ? `<img src="${esc(x.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(x.title)}</b><small>${esc(x.artist)}</small></span>
      <span class="mz-d">${esc(x.dur)}</span>${editable(x) ? `<button class="mz-x" data-qx="1" title="‘${esc(link.t)}’에서 빼기${x.cur ? " (지금 곡 — 다음 곡으로 넘어가요)" : ""}">⊖</button>` : ""}</div>`).join("") +
    `<div class="mz-qfoot">전체 ${main.length}곡 · ${hms(total)}${autoTotal ? ` <small>+ 자동재생 ${q.length - main.length}곡 · ${hms(autoTotal)}</small>` : ""}</div>`;
  body.classList.toggle("picking", picked.size > 0);
  drawBar();
  // 지금 곡으로 스크롤: 따라가기를 켰고, 곡이 바뀌었고, 8초 안에 직접 만지지 않았을 때만
  const cur = q[curK];
  const curKey = cur ? `${cur.vid}|${cur.i}` : "";
  if (qFollow && curKey && curKey !== qScrolledFor && Date.now() - qTouch > 8000) {
    body.querySelector(".mz-row.cur")?.scrollIntoView({ block: "center" });
    qScrolledFor = curKey;
  }
}

/// ⓘ: 자동재생이 무엇인지 짧게 (바깥을 누르면 닫힘)
function autoInfo(btn) {
  const r = btn.getBoundingClientRect();
  menuEl.innerHTML = `<div class="tipbox">YouTube Music 의 ‘자동재생’과 같아요.<br>유사한 콘텐츠를 지금 목록 끝에 추가해요 — 켜면 목록이 끝난 뒤 비슷한 곡이 이어서 나오고, 끄면 목록이 끝나면 멈춰요.</div>`;
  menuEl.onclick = null;
  menuEl.hidden = false;
  const m = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.max(4, Math.min(r.left - m.width / 2, innerWidth - m.width - 6)) + "px";
  menuEl.style.top = Math.min(r.bottom + 6, innerHeight - m.height - 6) + "px";
}

/// 화면 목록을 바로 바꿈 (순서 · 번호), 서버 일은 뒤에서
function applyLocal(newMain) {
  const all = [...newMain, ...qItems.filter((x) => x.auto)].map((x, k) => ({ ...x, i: k }));
  renderQueue(all, "");
}

/// 고른 곡들(하나도 됨)을 다음 트랙 · 플레이리스트에서 빼기 — 화면은 바로, 서버는 뒤에서. 지금 곡을 빼면 다음 곡으로 넘어감
function removeMany(sel) {
  const link = qLink;
  sel = sel.filter((x) => x && !x.auto && x.sid);
  if (!link || !sel.length) return;
  touched();
  const main = qItems.filter((x) => !x.auto);
  const gone = new Set(sel.map((x) => x.i));
  // 되돌리기용: 각 곡 바로 뒤 곡 (원래 순서 기준)
  const entries = main.map((it, k) => (gone.has(it.i) ? { it, after: k + 1 < main.length ? main[k + 1].sid : null } : null)).filter(Boolean);
  const keep = main.filter((x) => !gone.has(x.i));
  // 1) 화면: 빠지는 줄은 접히며 흐려지고, 남은 줄이 올라옴
  for (const r of body.querySelectorAll(".mz-row[data-k]")) {
    if (!gone.has(qItems[+r.dataset.k]?.i)) continue;
    r.style.height = r.offsetHeight + "px";
    void r.offsetHeight;
    r.classList.add("gone");
  }
  setTimeout(() => { qUndo = { entries, pid: link.id }; applyLocal(keep); }, 180);
  // 2) 뒤에서: 다음 트랙(뒤 곡부터 빼야 번호가 안 밀림) · 플레이리스트(한 번에)
  (async () => { for (const it of [...sel].sort((a, b) => b.i - a.i)) await call("qRemove", { i: it.i, sid: it.sid }).catch(() => {}); })();
  qDelta[link.id] = (qDelta[link.id] || 0) - sel.length;
  if (link.total) link.total -= sel.length;
  call("removeMany", { pid: link.id, sids: sel.map((x) => x.sid), vids: sel.map((x) => x.pvid || x.vid) }, 30)
    .then((ok) => { if (!ok) throw 0; refreshQueue(1000); })
    .catch(() => { qUndo = null; qDelta[link.id] += sel.length; toast("플레이리스트에서 빼지 못했어요"); refreshQueue(); });
}

async function undoRemove() {
  const u = qUndo;
  if (!u) return;
  touched();
  qUndo = null;
  // 화면엔 바로 원래 자리에 (앞 곡부터)
  const main = qItems.filter((x) => !x.auto);
  const back = [...u.entries].sort((a, b) => a.it.i - b.it.i);
  for (const e of back) main.splice(Math.min(e.it.i, main.length), 0, e.it);
  applyLocal(main);
  qDelta[u.pid] = (qDelta[u.pid] || 0) + back.length;
  if (qLink?.id === u.pid && qLink.total) qLink.total += back.length;
  // 다음 트랙: 앞 곡부터 원래 자리에
  const ins = (async () => { for (const e of back) await call("qInsert", { vids: [e.it.pvid || e.it.vid], sids: [e.it.sid], at: e.it.i }, 30).catch(() => {}); })();
  // 플레이리스트: 다시 넣으면 맨 끝에 붙어서, 뒤 곡부터 원래 자리(뒤에 있던 곡 앞)로
  const m = await call("addIds", { pid: u.pid, vids: back.map((e) => e.it.pvid || e.it.vid) }, 30).catch(() => null);
  if (!m || !Object.keys(m).length) { qDelta[u.pid] -= back.length; toast("되돌리지 못했어요"); refreshQueue(); return; }
  await ins;
  const newSid = {}; // 옛 자리 ID → 새 자리 ID
  for (const e of back) {
    const s = m[e.it.pvid || e.it.vid];
    if (!s) continue;
    newSid[e.it.sid] = s;
    call("qSetSid", { vid: e.it.pvid || e.it.vid, sid: s, old: e.it.sid }).catch(() => {});
  }
  for (const e of [...back].reverse()) {
    const sid = newSid[e.it.sid];
    if (!sid) continue;
    await call("moveBefore", { pid: u.pid, sid, before: e.after ? newSid[e.after] || e.after : null }, 30).catch(() => {});
  }
  refreshQueue(300);
}

/// 곡들을 지금 플레이리스트 끝 + 다음 트랙 끝에 — 넣을 곡 수를 바로 돌려주고 서버 일은 뒤에서 (이미 있으면 0)
function addLinked(vids) {
  const link = qLink;
  if (!link) return 0;
  touched();
  const main = qItems.filter((x) => !x.auto);
  const have = new Set(main.flatMap((x) => [x.vid, x.pvid]));
  const fresh = [...new Set(vids)].filter((v) => v && !have.has(v));
  if (!fresh.length) { toast(`이미 ‘${link.t}’에 있어요`); return 0; }
  // 긴 플레이리스트를 일부만 불러온 중이면 다음 트랙엔 안 붙임 (나머지를 불러올 때 같이 와서 두 번 나오지 않게)
  const partial = link.total > main.length;
  const ins = partial ? Promise.resolve(0) : call("qInsert", { vids: fresh }, 30).catch(() => 0);
  if (!partial) ins.then(() => refreshQueue(200));
  (async () => {
    const m = await call("addIds", { pid: link.id, vids: fresh }, 30).catch(() => null);
    if (!m) { toast(`‘${link.t}’에 넣지 못했어요`); refreshQueue(); return; }
    await ins;
    for (const [v, s] of Object.entries(m)) if (s) call("qSetSid", { vid: v, sid: s }).catch(() => {});
    const n = Object.keys(m).length;
    qDelta[link.id] = (qDelta[link.id] || 0) + n;
    if (link.total) link.total += n;
    if (partial) toast(`‘${link.t}’ 끝에 넣었어요 (다음 트랙엔 나머지를 불러올 때 보여요)`);
    refreshQueue(300);
  })();
  return fresh.length;
}

/// 🔍 검색해서 넣기: 노래를 찾아 ＋ 를 누르면 지금 플레이리스트 · 다음 트랙 끝에 (넣으면 ✓)
function openSongSearch() {
  const link = qLink;
  if (!link) return;
  const added = new Set();
  let hits = [], seq = 0;
  modal.innerHTML = `<div class="box mz-search"><h3>‘${esc(link.t)}’에 넣을 노래 찾기</h3>
    <input type="search" id="sq" placeholder="노래 · 가수 이름 (Enter)">
    <div class="mz-sres" id="sres"><div class="mz-note">검색어를 넣고 Enter</div></div>
    <div class="btns"><button data-r="0">닫기</button></div></div>`;
  modal.hidden = false;
  const inp = $("#sq");
  inp.focus();
  const draw = () => {
    $("#sres").innerHTML = hits.length ? hits.map((t, i) => `<div class="mz-row" title="${esc(t.t)} · ${esc(t.a)}">
      ${t.th ? `<img src="${esc(t.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(t.t)}</b><small>${esc(t.a)}</small></span><span class="mz-d">${esc(t.d)}</span>
      <button class="mz-add ${added.has(t.v) ? "done" : ""}" data-add="${i}" title="${added.has(t.v) ? "넣었어요" : "플레이리스트 · 다음 트랙에 넣기"}">${added.has(t.v) ? "✓" : "＋"}</button></div>`).join("")
      : '<div class="mz-note">찾지 못했어요</div>';
  };
  inp.onkeydown = async (e) => {
    if (e.key !== "Enter") return;
    const q = inp.value.trim();
    if (!q) return;
    const my = ++seq;
    $("#sres").innerHTML = '<div class="mz-note">찾는 중…</div>';
    let r = [];
    try { r = await call("searchSongs", { q }, 25); } catch { r = []; }
    if (my !== seq || modal.hidden) return;
    hits = Array.isArray(r) ? r : [];
    draw();
  };
  modal.onclick = (e) => {
    const b = e.target.closest("[data-add]");
    if (b) {
      const t = hits[+b.dataset.add];
      if (!t || added.has(t.v)) return;
      if (qLink?.id !== link.id) { toast("지금 듣는 플레이리스트가 바뀌었어요"); return; }
      if (addLinked([t.v]) > 0) { added.add(t.v); b.classList.add("done"); b.textContent = "✓"; b.title = "넣었어요"; }
      return;
    }
    if (e.target.closest("[data-r]") || e.target === modal) modal.hidden = true;
  };
}

// 끌어서 옮기기: 잡은 줄이 마우스를 따라오고 다른 줄들이 비켜 줌, 놓으면 화면은 바로 · 플레이리스트 · 다음 트랙은 뒤에서
let drag = null;
body.addEventListener("pointerdown", (e) => {
  if (tab !== 0 || e.button !== 0 || e.target.closest("input, button")) return;
  const row = e.target.closest(".mz-row.mov[data-k]");
  if (row) drag = { row, y0: e.clientY, on: false };
});
window.addEventListener("pointermove", (e) => {
  if (!drag) return;
  if (!drag.on) {
    if (Math.abs(e.clientY - drag.y0) < 5) return;
    const rows = [...body.querySelectorAll(".mz-row[data-k]:not(.auto)")];
    const from = rows.indexOf(drag.row);
    if (from < 0 || rows.length < 2) { drag = null; return; }
    Object.assign(drag, { on: true, rows, from, to: from, top0: drag.row.offsetTop, h: rows[1].offsetTop - rows[0].offsetTop,
      grab: e.clientY - body.getBoundingClientRect().top + body.scrollTop - drag.row.offsetTop });
    drag.row.classList.add("dragging");
    body.classList.add("qdrag");
    touched();
  }
  const d = drag, rect = body.getBoundingClientRect();
  // 위아래 끝 가까이 가면 목록을 굴림
  if (e.clientY < rect.top + 28) body.scrollTop -= 14;
  if (e.clientY > rect.bottom - 28) body.scrollTop += 14;
  const n = d.rows.length;
  const first = d.rows[0].offsetTop;
  const y = Math.max(first, Math.min(first + (n - 1) * d.h, e.clientY - rect.top + body.scrollTop - d.grab));
  d.row.style.transform = `translateY(${y - d.top0}px)`;
  const to = Math.max(0, Math.min(n - 1, Math.round((y - first) / d.h)));
  if (to === d.to) return;
  d.to = to;
  d.rows.forEach((r, j) => {
    if (r === d.row) return;
    const shift = d.from < to && j > d.from && j <= to ? -d.h : to < d.from && j >= to && j < d.from ? d.h : 0;
    r.style.transform = shift ? `translateY(${shift}px)` : "";
  });
});
window.addEventListener("pointerup", async () => {
  const d = drag;
  drag = null;
  if (!d?.on) return;
  qJustDragged = Date.now();
  touched();
  const link = qLink;
  const main = qItems.filter((x) => !x.auto);
  const { from, to } = d;
  const item = main[from];
  const done = () => body.classList.remove("qdrag");
  if (!item || to === from) { done(); renderQueue(qItems, queueSig); return; }
  // 내 플레이리스트가 아니면 다음 트랙에서만 (섞어 듣는 중이어도 됨)
  if (!link) {
    const m = main.slice();
    m.splice(to, 0, m.splice(from, 1)[0]);
    d.row.style.transform = `translateY(${d.rows[to].offsetTop - d.top0}px)`;
    setTimeout(() => { done(); applyLocal(m); }, 120);
    call("qMove", { from: item.i, to: to > from ? to + 1 : to, sid: "", vid: item.pvid || item.vid }).then((ok) => { if (!ok) throw 0; })
      .catch(() => { toast("다음 트랙 순서를 바꾸지 못했어요"); refreshQueue(); });
    return;
  }
  if (to === main.length - 1 && link.total > main.length) { done(); toast("긴 플레이리스트는 불러온 곡 맨 끝으로는 못 옮겨요"); renderQueue(qItems, queueSig); return; }
  // 섞어 듣는 중이면 다음 트랙 순서가 플레이리스트 순서와 달라서 못 옮김
  if (await call("qShuffled").catch(() => false)) { done(); toast("섞어 듣기 중엔 순서를 바꿀 수 없어요"); renderQueue(qItems, queueSig); return; }
  const m = main.slice();
  m.splice(to, 0, m.splice(from, 1)[0]);
  d.row.style.transform = `translateY(${d.rows[to].offsetTop - d.top0}px)`;
  setTimeout(() => { done(); applyLocal(m); }, 120);
  // 그 곡 뒤에 올 곡 (자리 ID 가 있는 곡) 앞으로 — 없으면 맨 끝
  const before = m.slice(to + 1).find((x) => x.sid)?.sid || null;
  // 대기열은 '그 곡 앞에 꽂기' 자리로 (원래 순서 기준)
  const insertAt = to > from ? to + 1 : to;
  call("qMove", { from: item.i, to: insertAt, sid: item.sid }).catch(() => {});
  call("moveBefore", { pid: link.id, sid: item.sid, before }, 30).then((ok) => { if (!ok) throw 0; }).catch(() => { toast("플레이리스트 순서를 바꾸지 못했어요"); refreshQueue(); });
});
body.addEventListener("wheel", () => { if (tab === 0) touched(); }, { passive: true });

/// 앨범과 펼친 수록곡 체크 맞추기: 앨범째 고르면 수록곡도 모두 체크, 한 곡을 빼면 나머지 곡만, 곡을 다 고르면 앨범째
function syncAlbumPick(id) {
  const panel = body.querySelector(`.mz-tracks[data-for="${CSS.escape(id)}"]`);
  const card = body.querySelector(`.mz-album[data-album="${CSS.escape(id)}"] input.pick`);
  if (card) card.checked = pickedAlbums.has(id);
  panel?.querySelectorAll(".mz-row[data-vid] input.pick").forEach((c) => { c.checked = pickedAlbums.has(id) || picked.has(c.closest("[data-vid]").dataset.vid); });
}
body.addEventListener("change", (e) => {
  const c0 = e.target.closest("input.pick");
  const panel = c0?.closest(".mz-tracks[data-for]");
  if (c0 && panel) {
    // 펼친 수록곡 체크
    const id = panel.dataset.for, vid = c0.closest("[data-vid]").dataset.vid;
    const vids = [...panel.querySelectorAll(".mz-row[data-vid]")].map((r) => r.dataset.vid);
    if (pickedAlbums.has(id)) { pickedAlbums.delete(id); for (const v of vids) if (v !== vid) picked.add(v); }
    else {
      c0.checked ? picked.add(vid) : picked.delete(vid);
      if (vids.length && vids.every((v) => picked.has(v))) { vids.forEach((v) => picked.delete(v)); pickedAlbums.add(id); }
    }
    syncAlbumPick(id);
    body.classList.toggle("picking", picked.size + pickedAlbums.size > 0);
    drawBar();
    return;
  }
  if (c0 && c0.closest(".mz-album[data-album]")) {
    // 앨범째 체크: 따로 고른 그 앨범 곡은 앨범에 합침
    const id = c0.closest("[data-album]").dataset.album;
    if (c0.checked) { pickedAlbums.add(id); (albumTrackCache.get(id)?.out || []).forEach((x) => picked.delete(x.v)); } else pickedAlbums.delete(id);
    syncAlbumPick(id);
    body.classList.toggle("picking", picked.size + pickedAlbums.size > 0);
    drawBar();
    return;
  }
  if (e.target.id === "qAuto") {
    const on = e.target.checked;
    try { localStorage.setItem("mzAutoplay", on ? "1" : "0"); } catch { /* 없음 */ }
    qAuto = on;
    call("autoplay", { on }).catch(fail);
    toast(on ? "자동재생 켬 — 목록이 끝나면 비슷한 곡을 이어서 틀어요" : "자동재생 끔 — 목록이 끝나면 멈춰요");
    refreshQueue(1200);
    return;
  }
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
    if (e.target.closest("#qFollow")) {
      qFollow = !qFollow;
      try { localStorage.setItem("mzQueueFollow", qFollow ? "1" : "0"); } catch { /* 없음 */ }
      toast(qFollow ? "곡이 바뀌면 지금 곡으로 스크롤해요" : "목록이 저절로 움직이지 않아요");
      if (qFollow) { qTouch = 0; qScrolledFor = ""; }
      renderQueue(qItems, queueSig);
      return;
    }
    if (e.target.closest("#qSearch")) { openSongSearch(); return; }
    if (e.target.closest("#qAutoInfo")) { autoInfo(e.target.closest("#qAutoInfo")); return; }
    if (e.target.closest("#qUndo")) { undoRemove(); return; }
    const row = e.target.closest(".mz-row[data-k]");
    if (!row || Date.now() - qJustDragged < 300) return;
    if (e.target.closest("[data-qx]")) { removeMany([qItems[+row.dataset.k]]); return; }
    await call("playQueue", { i: +row.dataset.i }).catch(fail);
    refreshQueue(800);
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
    const it = qItems[+row.dataset.k], link = qLink;
    const linkItems = !link || !it ? [] : it.auto || !it.sid
      ? ["-", { label: `‘${link.t}’에 넣기 (지금 플레이리스트 · 다음 트랙 끝에)`, action: () => addLinked([it.vid]) }]
      : ["-", { label: `‘${link.t}’에서 빼기${it.cur ? " (다음 곡으로 넘어가요)" : ""}`, action: () => removeMany([it]) }];
    showMenu(e.clientX, e.clientY, [
      { label: "이 곡 재생", action: () => call("playQueue", { i: +row.dataset.i }).catch(fail) },
      { label: "이 곡의 앨범을 지금 곡 다음에 넣기", disabled: !it, action: () => queueAlbumOf(it, true) },
      { label: "이 곡의 앨범을 다음 트랙 끝에 이어 붙이기", disabled: !it, action: () => queueAlbumOf(it, false) },
      ...linkItems,
      { label: "플레이리스트에 넣기…", action: () => addMenu(e.clientX, e.clientY, [row.dataset.vid], []) },
      { label: `‘${row.dataset.artist}’ 를 랜덤 가수에 넣기`, disabled: !row.dataset.artist, action: () => addArtistsToRandom([{ aid: row.dataset.aid, name: row.dataset.artist }]) },
    ]);
  }
  if (tab === 2 && row.dataset.album) albumMenu(e.clientX, e.clientY, row.dataset.album, row.dataset.title);
  if (tab === 2 && !row.dataset.album && row.dataset.vid) {
    showMenu(e.clientX, e.clientY, [
      { label: "이 곡만 재생", action: () => playVideos([row.dataset.vid]) },
      { label: "이 곡부터 앨범 재생", disabled: !row.dataset.list, action: () => playList(row.dataset.list, row.dataset.vid) },
      { label: "플레이리스트에 넣기…", action: () => addMenu(e.clientX, e.clientY, [row.dataset.vid], []) },
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
    `<div class="mz-sec">${esc(sec)}</div>${list.map((a) => `<div class="mz-album mz-row" data-album="${esc(a.id)}" data-title="${esc(a.t)}" title="눌러서 수록곡 보기 · ▶ 처음부터 재생 · 오른쪽 클릭: 플레이리스트에 넣기">
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
      <span class="mz-num">${k + 1}<input type="checkbox" class="pick" ${picked.has(x.v) || pickedAlbums.has(id) ? "checked" : ""} title="골라서 재생 · 플레이리스트에 넣기"></span>
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

/// 고른 곡만 재생: 한 곡이면 그 곡만, 여러 곡이면 '고른 곡 (도구함)' 플레이리스트를 새로 만들어 틀고 전에 만든 건 지움
/// (YouTube Music 은 곡 몇 개로 바로 재생 목록을 만드는 주소가 없어서)
async function playVideos(vids) {
  vids = [...new Set(vids.filter(Boolean))];
  if (!vids.length) { toast("재생할 곡을 골라 주세요"); return; }
  if (vids.length === 1) {
    await invoke("web_eval", { label: "ytmusic", js: `location.href = ${JSON.stringify("https://music.youtube.com/watch?v=" + encodeURIComponent(vids[0]))}` });
    for (const t of [4000, 8000, 12000]) setTimeout(() => call("autoplay", { on: autoPref() ?? false }).catch(() => {}), t);
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
    if (!list) throw "앨범 플레이리스트를 찾지 못했어요";
    await playList(list);
    status("");
    toast(`‘${title}’ 재생`);
  } catch (e) { fail(e); }
}
/// 앨범 수록곡을 다음 트랙에 (지금 곡 다음 · 끝에) — 지금 듣는 목록에만, 플레이리스트엔 안 들어감
async function queueAlbum(id, title, next) {
  status(`‘${title}’ 수록곡 읽는 중…`);
  try {
    const r = albumTrackCache.get(id) || await call("albumTracks", { id }, 30);
    albumTrackCache.set(id, r);
    const vids = (r.out || []).map((x) => x.v).filter(Boolean);
    if (!vids.length) throw "수록곡을 찾지 못했어요";
    const n = await call("qInsert", { vids, afterCurrent: next }, 30);
    status("");
    toast(n > 0 ? `‘${title}’ ${n}곡을 ${next ? "지금 곡 다음에" : "다음 트랙 끝에"} 넣었어요` : "다음 트랙에 넣지 못했어요");
    if (tab === 0) refreshQueue(300);
  } catch (e) { fail(e); }
}
async function queueAlbumOf(it, next) {
  status(`‘${it.title}’ 앨범 찾는 중…`);
  const a = await call("songAlbum", { vids: [it.vid, it.pvid] }, 30).catch(() => null);
  status("");
  if (!a?.id) { toast("이 곡은 앨범을 찾지 못했어요 (라이브 · 커버 영상 등)"); return; }
  queueAlbum(a.id, a.name || "앨범", next);
}
function albumMenu(x, y, id, title) {
  showMenu(x, y, [
    { label: "처음부터 재생", action: () => playAlbum(id, title) },
    { label: openAlbums.has(id) ? "수록곡 접기" : "수록곡 보기", action: () => toggleAlbum(id) },
    "-",
    { label: "지금 곡 다음에 넣기 (다음 트랙)", action: () => queueAlbum(id, title, true) },
    { label: "다음 트랙 끝에 이어 붙이기", action: () => queueAlbum(id, title, false) },
    { label: "플레이리스트에 넣기…", action: () => addMenu(x, y, [], [id]) },
  ]);
}

// MARK: 플레이리스트 (내 계정 — 휴대폰 앱에도 그대로 보임)

let plSel = null;
let plTracks = [];
let plDelMode = false;
const plDel = new Set();
async function loadPlaylists(force) {
  status("플레이리스트 읽는 중…");
  const lists = await loadMyLists(force);
  status("");
  if (tab !== 3) return;
  if (!myLists) { body.innerHTML = `<div class="mz-empty">플레이리스트를 읽지 못했어요<br><small>YouTube Music 창에서 로그인했는지 확인해 주세요</small></div>`; return; }
  if (plSel && !lists.some((l) => l.id === plSel)) plSel = null;
  body.innerHTML = `<div class="mz-pl">
    <div class="mz-pl-side">
      <div class="mz-pl-tools">
        <button class="pl-open" id="plNew" title="새 플레이리스트 (비공개)">＋ 새로</button>
        <button class="pl-open ghost" id="plRename" title="고른 플레이리스트 이름 바꾸기" ${plSel && !plDelMode ? "" : "disabled"}>✏️ 이름</button>
        <button class="pl-open ${plDelMode ? "danger" : "ghost"}" id="plDel" title="플레이리스트 지우기 (여러 개 골라서)">${plDelMode ? `${plDel.size}개 지우기` : "지우기…"}</button>
        ${plDelMode ? '<button class="pl-open ghost" id="plDelCancel">취소</button>' : ""}
        <button class="icon sm" id="plReload" title="새로 고침">↻</button>
      </div>
      <div class="mz-pl-list">${lists.map((l) => `<div class="mz-pl-item ${l.id === plSel ? "on" : ""}" data-pl="${esc(l.id)}">
        ${plDelMode ? `<input type="checkbox" class="del" ${plDel.has(l.id) ? "checked" : ""}>` : ""}
        ${l.th ? `<img src="${esc(l.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
        <span class="mz-t"><b>${esc(l.t)}</b><small>${esc(l.sub)}</small></span></div>`).join("") || '<div class="mz-empty">플레이리스트가 없어요</div>'}</div>
    </div>
    <div class="mz-pl-main" id="plMain">${plSel ? "" : '<div class="mz-empty">왼쪽에서 플레이리스트를 골라 주세요</div>'}</div></div>`;
  $("#plNew").onclick = async () => {
    const name = await ask("새 플레이리스트 이름", "", "예: 드라이브");
    if (!name) return;
    status("만드는 중…");
    try { const id = await call("create", { name, vids: [] }); if (!id) throw "만들지 못했어요"; plSel = id; myLists = null; await loadPlaylists(true); toast(`‘${name}’을 만들었어요`); } catch (e) { fail(e); }
  };
  $("#plReload").onclick = () => loadPlaylists(true);
  $("#plRename").onclick = async () => {
    const l = lists.find((x) => x.id === plSel);
    if (!l) { toast("이름을 바꿀 플레이리스트를 골라 주세요"); return; }
    const name = await ask("플레이리스트 이름 바꾸기", l.t);
    if (!name || name === l.t) return;
    status("이름 바꾸는 중…");
    try {
      if (!(await call("rename", { pid: l.id, name }))) throw "이름을 바꾸지 못했어요";
      status("");
      renamed[l.id] = name; l.t = name;
      toast(`‘${name}’으로 바꿨어요`);
      loadPlaylists();
    } catch (e) { fail(e); }
  };
  $("#plDel").onclick = async () => {
    if (!plDelMode) { plDelMode = true; plDel.clear(); loadPlaylists(); return; }
    if (!plDel.size) { toast("지울 플레이리스트를 골라 주세요"); return; }
    const names = lists.filter((l) => plDel.has(l.id)).map((l) => l.t);
    if (!(await confirmBox(`플레이리스트 ${names.length}개를 지울까요?`, names.join(", ") + " — YouTube Music 계정에서도 지워지고 되돌릴 수 없어요.", "지우기"))) return;
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
    $("#plRename").disabled = false;
    loadTracks();
  };
  if (plSel) loadTracks();
}
let plGroup = false; // 앨범별로 묶어 보기
try { plGroup = localStorage.getItem("mzPlGroup") === "1"; } catch { /* 없음 */ }
let plUndo = null;   // { pid, entries: [{ t, after }], label } — 방금 뺀 곡 · 앨범 되돌리기
// ✎ 빠진 곡 보기를 켜 둔 앨범 묶음 (플레이리스트 | 앨범, 기억) — 켜면 앨범의 빠진 곡이 묶음 안 제자리에 투명한 줄로
let plGhost = new Set();
try { plGhost = new Set(JSON.parse(localStorage.getItem("mzPlGhost") || "[]")); } catch { /* 없음 */ }
const saveGhost = () => { try { localStorage.setItem("mzPlGhost", JSON.stringify([...plGhost])); } catch { /* 없음 */ } };
const ghostLoading = new Set(); // 수록곡 읽는 중인 앨범
const ghostFailed = new Set();  // 수록곡을 못 읽은 앨범
// 앨범 수록곡 읽기 줄: 앨범이 많은 플레이리스트에서 요청이 한꺼번에 몰리지 않게 2개씩
const albumQueue = [];
let albumBusy = 0, albumRedraw = 0;
function pumpAlbums() {
  while (albumBusy < 2 && albumQueue.length) {
    const aid = albumQueue.shift();
    albumBusy++;
    // 못 읽으면 캐시는 비워 두고(다른 곳에서 다시 읽게) 여기서만 '찾지 못했어요'
    call("albumTracks", { id: aid }, 30).then((r) => albumTrackCache.set(aid, r)).catch(() => ghostFailed.add(aid))
      .finally(() => {
        albumBusy--; ghostLoading.delete(aid); pumpAlbums();
        clearTimeout(albumRedraw);
        albumRedraw = setTimeout(() => { if (tab === 3) drawTracks(); }, 200);
      });
  }
}
let plGroups = [];   // 화면의 앨범 묶음들 (곡 번호 목록)
let plAuto = false;  // 재생 중인 앨범만 펼치기
const plFlip = new Set(); // 재생 중인 앨범만 펼치기에서 머리줄을 눌러 반대로 둔 묶음 (곡이 바뀌면 비움)
let plCollapsed = new Set(); // 접어 둔 앨범 묶음 (플레이리스트 | 앨범)
try { plAuto = localStorage.getItem("mzPlAuto") === "1"; plCollapsed = new Set(JSON.parse(localStorage.getItem("mzPlCollapsed") || "[]")); } catch { /* 없음 */ }
const saveCollapsed = () => { try { localStorage.setItem("mzPlCollapsed", JSON.stringify([...plCollapsed])); localStorage.setItem("mzPlAuto", plAuto ? "1" : "0"); localStorage.setItem("mzPlGroup", plGroup ? "1" : "0"); } catch { /* 없음 */ } };
const groupKey = (t) => `${plSel}|${t.alid || "n:" + t.al}`;
const plAdding = new Set(); // 넣는 중인 곡 ID

async function loadTracks() {
  const main = $("#plMain");
  if (!main || !plSel) return;
  const id = plSel;
  main.innerHTML = `<div class="mz-empty">곡 읽는 중…</div>`;
  let ts;
  try { ts = await call("tracks", { pid: id }, 60); } catch (e) { fail(e); return; }
  if (plSel !== id || !$("#plMain")) return;
  plTracks = ts;
  drawTracks();
}
function drawTracks() {
  const main = $("#plMain");
  if (!main || !plSel) return;
  const l = (myLists || []).find((x) => x.id === plSel);
  const curT = Player.state().title;
  const keep = main.querySelector(".mz-pl-tracks")?.scrollTop || 0;
  const row = (t, i) => `<div class="mz-row ${t.t === curT ? "cur" : ""}" data-k="${i}" data-sid="${esc(t.s)}">
      ${t.th ? `<img src="${esc(t.th)}" alt="" referrerpolicy="no-referrer">` : '<span class="mz-noimg"></span>'}
      <span class="mz-t"><b>${esc(t.t)}</b><small>${esc(t.a)}</small></span><span class="mz-d">${esc(t.d)}</span>
      <button class="mz-x" title="플레이리스트에서 빼기">⊖</button></div>`;
  let rows = "";
  if (plGroup) {
    // 앨범별: 같은 앨범은 떨어져 있어도 한 묶음 (처음 나온 자리 순서), 묶음 안은 플레이리스트 순서
    plGroups = [];
    const order = [], mem = {};
    plTracks.forEach((t, k) => { const g = t.alid || "n:" + t.al; if (!mem[g]) { mem[g] = []; order.push(g); } mem[g].push(k); });
    for (const g of order) {
      const idx = mem[g], gi = plGroups.push(idx) - 1, t0 = plTracks[idx[0]];
      const scattered = idx[idx.length - 1] - idx[0] + 1 !== idx.length;
      const ck = groupKey(t0), playing = idx.some((k) => plTracks[k].t === curT);
      const collapsed = plAuto ? playing === plFlip.has(ck) : plCollapsed.has(ck);
      const list = idx.map((k) => plTracks[k]);
      const ghostOn = !!t0.alid && plGhost.has(ck);
      // 앨범 정보가 있으면 늘 수록곡 수를 읽어 '앨범 9곡 중 7곡' (✎ 를 안 눌러도) — 빠진 곡 줄은 ✎ 켠 앨범만
      const G = t0.alid ? albumGhosts(gi) : null;
      const known = G && !G.loading && G.songs.length;
      const cnt = !known ? `${list.length}곡` : G.missing.length ? `<span class="mz-miss">앨범 ${G.songs.length}곡 중 ${G.songs.length - G.missing.length}곡</span>` : `앨범 ${G.songs.length}곡 모두`;
      const gnote = !ghostOn || !G ? "" : G.loading ? " · 수록곡 읽는 중…" : !G.songs.length ? " · 수록곡을 찾지 못했어요" : G.swap.length ? ` · <span class="mz-miss">다른 앨범 버전 ${G.swap.length}곡</span>` : "";
      const gbtn = !ghostOn || !G || G.loading ? "" : G.missing.length ? `<button class="pl-open ghost mz-gather" data-eadd="${gi}:-1" title="빠진 곡 ${G.missing.length}개를 앨범 순서 자리에 모두 넣기">＋ 모두 넣기</button>`
        : G.swap.length ? `<button class="pl-open ghost mz-gather" data-eswap="${gi}:-1" title="다른 앨범 버전으로 들어 있는 곡을 이 앨범 버전으로 모두 바꾸기 (되돌리기 가능)">⇄ 모두 바꾸기</button>` : "";
      rows += `<div class="mz-ahead ${playing ? "playing" : ""}" data-g="${gi}" title="누르면 접거나 펼쳐요"><span class="mz-chev2">${collapsed ? "▸" : "▾"}</span><b title="${esc(t0.al)}">${playing ? "🔊 " : ""}${esc(t0.al || "앨범 정보 없음 (영상 등)")}</b><small title="플레이리스트에 든 이 앨범 곡 ${list.length}개">${cnt} · ${hms(list.reduce((a, x) => a + secsOf(x.d), 0))}${gnote}</small>
        <span class="mz-sp"></span>${gbtn}${scattered && t0.al ? '<button class="pl-open ghost mz-gather" data-ggather="1" title="이 앨범 곡들이 플레이리스트에서 떨어져 있어요 — 누르면 첫 곡 자리에 한데 모아요">모으기</button>' : ""}${t0.alid ? `<button class="mz-aplay ${ghostOn ? "on" : ""}" data-gedit="1" title="${ghostOn ? "빠진 곡 숨기기" : "빠진 곡 보기 — 이 앨범에서 플레이리스트에 없는 곡을 제자리에 흐리게 보여 줘요"}">✎</button>` : ""}<button class="mz-aplay" data-gplay="1" title="이 앨범부터 재생">▶</button><button class="mz-x" data-gx="1" title="이 앨범 곡을 모두 플레이리스트에서 빼기 — 두 번 눌러요 (되돌리기 가능)">⊖</button></div>`;
      if (!collapsed) {
        // 빠진 곡: 앨범 순서에서 바로 앞 곡 뒤에 투명한 줄로 (앞 곡이 없으면 묶음 맨 위)
        const gh = ghostOn && G && !G.loading ? ghostRows(G, gi, t0) : null;
        rows += (gh?.get(-1) || "") + idx.map((k) => row(plTracks[k], k) + (gh?.get(k) || "")).join("");
      }
    }
  } else rows = plTracks.map(row).join("");
  const undo = plUndo && plUndo.pid === plSel ? `<button class="pl-open ghost" id="plUndo">${esc(plUndo.label)} 되돌리기</button>` : "";
  const albumN = new Set(plTracks.map((t) => t.alid || "n:" + t.al)).size;
  main.innerHTML = `<div class="mz-pl-head"><b>${esc(l?.t || "")}</b><small>${plTracks.length}곡 · ${hms(plTracks.reduce((a, x) => a + secsOf(x.d), 0))}${plGroup ? ` · 앨범 ${albumN}개` : ""}</small><span class="mz-sp"></span>${undo}
      ${plGroup ? (() => {
        const keys = new Set(plTracks.map(groupKey)), allClosed = !plAuto && keys.size && [...keys].every((k) => plCollapsed.has(k));
        return `<button class="pl-open ghost" id="plFold" title="${allClosed ? "모두 펼치기" : "모두 접기"}">${allClosed ? "모두 펼치기" : "모두 접기"}</button>`;
      })() : ""}
      <button class="pl-open ${plGroup ? "" : "ghost"}" id="plGroup" title="${!plGroup ? "보기: 곡만 — 누르면 앨범별" : plAuto ? "보기: 앨범별 · 재생 중인 앨범만 펼치기 — 누르면 곡만" : "보기: 앨범별 — 누르면 재생 중인 앨범만 펼치기"}">${plGroup ? (plAuto ? "앨범별 · 재생 중만" : "앨범별") : "곡만"}</button>
      <button class="pl-open" id="plPlay">▶ 재생</button><button class="pl-open ghost" id="plAddCur" title="지금 듣는 곡을 이 플레이리스트에">＋ 지금 곡</button></div>
    <div class="mz-pl-tracks">${rows || '<div class="mz-empty">비어 있어요 — ＋ 지금 곡 으로 넣어 보세요</div>'}</div>`;
  main.querySelector(".mz-pl-tracks").scrollTop = keep;
  $("#plPlay").onclick = () => { playList(plSel); toast(`‘${l?.t}’ 재생`); };
  // 보기 단추: 누를 때마다 곡만 → 앨범별 → 앨범별 · 재생 중인 앨범만 펼치기 → 곡만 …
  $("#plGroup").onclick = () => {
    if (!plGroup) { plGroup = true; plAuto = false; }
    else if (!plAuto) { plAuto = true; plFlip.clear(); }
    else { plGroup = false; plAuto = false; }
    saveCollapsed(); drawTracks();
  };

  if (undo) $("#plUndo").onclick = undoTracks;
  if (plGroup) {
    $("#plFold").onclick = () => {
      const keys = [...new Set(plTracks.map(groupKey))];
      const anyOpen = plAuto || keys.some((k) => !plCollapsed.has(k));
      keys.forEach((k) => (anyOpen ? plCollapsed.add(k) : plCollapsed.delete(k)));
      plAuto = false; saveCollapsed(); drawTracks();
    };
  }
  $("#plAddCur").onclick = async () => {
    const v = await call("currentVideo").catch(() => "");
    if (!v) { toast("지금 듣는 곡이 없어요"); return; }
    addTo(plSel, l?.t || "", [v], []);
  };
  main.querySelector(".mz-pl-tracks").onclick = (e) => {
    if (ghostClick(e)) return;
    const h = e.target.closest("[data-g]");
    if (h) {
      const idx = plGroups[+h.dataset.g] || [], t0 = plTracks[idx[0]];
      if (!t0) return;
      if (e.target.closest("[data-gplay]")) playList(plSel, t0.v);
      else if (e.target.closest("[data-gedit]")) { const ck = groupKey(t0); plGhost.has(ck) ? plGhost.delete(ck) : plGhost.add(ck); saveGhost(); drawTracks(); }
      else if (e.target.closest("[data-gx]")) {
        // 두 번 누르기: 한 번 누르면 '한 번 더 누르면 빼요' (3초), 그 안에 다시 누르면 앨범째 뺌 — 묻는 창 없이 실수 방지
        const b = e.target.closest("[data-gx]");
        if (!b.classList.contains("armed")) {
          b.classList.add("armed"); b.textContent = "한 번 더 누르면 빼요";
          setTimeout(() => { if (b.isConnected) { b.classList.remove("armed"); b.textContent = "⊖"; } }, 3000);
          return;
        }
        removeTracks(idx.map((k) => plTracks[k]), t0.al ? `‘${t0.al.slice(0, 12)}’` : `${idx.length}곡`);
      }
      else if (e.target.closest("[data-ggather]")) gatherGroup(idx);
      else {
        // 머리줄을 누르면 접기 · 펼치기
        const ck = groupKey(t0);
        if (plAuto) plFlip.has(ck) ? plFlip.delete(ck) : plFlip.add(ck);
        else { plCollapsed.has(ck) ? plCollapsed.delete(ck) : plCollapsed.add(ck); saveCollapsed(); }
        drawTracks();
      }
      return;
    }
    const row = e.target.closest("[data-k]");
    if (!row) return;
    const t = plTracks[+row.dataset.k];
    if (e.target.closest(".mz-x")) { removeTrack(t); return; }
    playList(plSel, t.v);
  };
}
// 앨범 편집: 전체 수록곡 중 빠진 곡을 ＋ 로 그 앨범 묶음 끝에 (이미 있는 곡은 ✓ — 곡 ID 가 같거나 제목이 같으면)
const normT = (t) => String(t || "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
function inPlaylist(x) { return plTracks.some((t) => t.v === x.v || normT(t.t) === normT(x.t)); }
/// 다른 앨범 버전으로 들어 있는 곡 (제목만 같고 곡 · 앨범이 다름)
function otherVersions(x, aid) { return plTracks.filter((t) => t.v !== x.v && normT(t.t) === normT(x.t) && t.alid !== aid && !t.s.startsWith("pending-")); }
/// 앨범의 빠진 곡 · 다른 앨범 버전으로 들어 있는 곡, 그리고 각 곡이 들어갈 자리 (앞 곡의 플레이리스트 번호, -1 = 묶음 맨 위)
function albumGhosts(gi) {
  const idx = plGroups[gi] || [];
  const t0 = plTracks[idx[0]];
  const aid = t0 && t0.alid;
  const got = aid && albumTrackCache.get(aid);
  if (!got) {
    if (ghostFailed.has(aid)) return { songs: [], missing: [], swap: [], anchor: new Map() };
    if (aid && !ghostLoading.has(aid)) { ghostLoading.add(aid); albumQueue.push(aid); pumpAlbums(); }
    return { loading: true };
  }
  const songs = got.out || [];
  const match = (t, x) => t.v === x.v || normT(t.t) === normT(x.t);
  const missing = [], swap = [], anchor = new Map();
  songs.forEach((x, j) => {
    const other = plTracks.some((t) => t.v === x.v) ? [] : otherVersions(x, aid);
    const miss = !inPlaylist(x);
    if (!miss && !other.length) return;
    (miss ? missing : swap).push(x);
    let at = -1;
    for (let p = j - 1; p >= 0 && at < 0; p--) { const k = idx.find((k) => match(plTracks[k], songs[p])); if (k !== undefined) at = k; }
    anchor.set(x.v, at);
  });
  return { songs, missing, swap, anchor };
}
/// 빠진 곡 줄들: 앞 곡 번호 → 그 뒤에 붙일 투명한 줄 HTML
function ghostRows(G, gi, t0) {
  const m = new Map();
  G.songs.forEach((x, j) => {
    if (!G.anchor.has(x.v)) return;
    const at = G.anchor.get(x.v);
    const other = G.swap.includes(x) ? otherVersions(x, t0.alid) : [];
    const html = `<div class="mz-row ghost" data-eplay="${gi}:${j}" title="앨범 ${j + 1}번 곡 · 플레이리스트에 없어요 — 줄을 누르면 이 곡만 들어 보기">
      <span class="mz-noimg">${j + 1}</span><span class="mz-t"><b>${esc(trimAlbum(x.t, t0.al))}</b><small>${other.length ? `다른 앨범 버전(‘${esc(other[0].al)}’)으로 들어 있어요` : "빠진 곡"}</small></span><span class="mz-d">${esc(x.d)}</span>
      ${other.length ? `<button class="mz-add swap" data-eswap="${gi}:${j}" title="이 앨범 버전으로 바꿔 이 자리에 넣기 (원래 버전은 빼요 · 되돌리기 가능)">⇄</button>` : `<button class="mz-add" data-eadd="${gi}:${j}" title="이 자리에 넣기">＋</button>`}</div>`;
    m.set(at, (m.get(at) || "") + html);
  });
  return m;
}
/// 빠진 곡 줄 · 머리줄의 ＋ / ⇄ / 들어 보기. 처리했으면 true
function ghostClick(e) {
  const ed = e.target.closest("[data-eadd],[data-eplay],[data-eswap]");
  if (!ed) return false;
  const [gi, k] = (ed.dataset.eadd || ed.dataset.eswap || ed.dataset.eplay).split(":").map(Number);
  const t0 = plTracks[(plGroups[gi] || [])[0]];
  const G = t0 ? albumGhosts(gi) : null;
  if (!G || G.loading) return true;
  const songs = G.songs;
  if (ed.dataset.eswap) {
    // ⇄ 이 앨범 버전으로: 제자리에 넣고 원래 버전은 뺌 (되돌리기로 원래 버전 되살림)
    const list = k < 0 ? G.swap : [songs[k]];
    const olds = list.flatMap((x) => otherVersions(x, t0.alid));
    if (list.length) { addToGroup(list, gi, G.anchor); removeTracks(olds, olds.length === 1 ? `‘${olds[0].t.slice(0, 12)}’` : `${olds.length}곡`); }
  } else if (ed.dataset.eadd) addToGroup(k < 0 ? G.missing : [songs[k]], gi, G.anchor);
  else if (songs[k]) playVideos([songs[k].v]);
  return true;
}
/// 곡들을 플레이리스트에 넣고 제자리로 옮김 — anchor(곡 ID → 앞 곡 번호, -1 = 묶음 맨 위)가 있으면 그 뒤, 없으면 묶음 끝
/// 화면엔 바로 (임시 자리 ID 'pending-…' 로 끼워 둠), 서버는 뒤에서 — 끝나면 진짜 자리 ID 로 바꿈
async function addToGroup(songs, gi, anchor) {
  const pid = plSel;
  const idx = plGroups[gi] || [];
  const t0 = plTracks[idx[0]];
  const add = songs.filter((x) => x && x.v && !plTracks.some((t) => t.v === x.v));
  if (!t0 || !add.length) return;
  const last = idx[idx.length - 1];
  const pend = add.map((x) => ({ t: x.t, a: t0.a, d: x.d, v: x.v, s: "pending-" + x.v, th: "", al: t0.al, alid: t0.alid }));
  // 뒤 자리부터 끼워야 앞 번호가 안 밀림 (같은 자리면 앨범 순서가 되게 뒤 곡부터)
  const at = (x) => (anchor && anchor.has(x.v) ? (anchor.get(x.v) < 0 ? idx[0] : anchor.get(x.v) + 1) : last + 1);
  pend.map((t, n) => ({ t, n, pos: at(add[n]) })).sort((p, q) => q.pos - p.pos || q.n - p.n).forEach((p) => plTracks.splice(p.pos, 0, p.t));
  // 각 곡을 옮길 기준: 바로 뒤의 진짜 곡 (없으면 맨 끝이라 안 옮김)
  const before = pend.map((t) => plTracks.slice(plTracks.indexOf(t) + 1).find((x) => !x.s.startsWith("pending-"))?.s || null);
  drawTracks();
  let m = null;
  try { m = await call("addIds", { pid, vids: add.map((x) => x.v) }, 30); } catch (e) { /* 아래에서 */ }
  if (plSel !== pid) return;
  if (!m) { toast("넣지 못했어요"); plTracks = plTracks.filter((t) => !pend.includes(t)); drawTracks(); return; }
  // 임시 자리 ID → 진짜 자리 ID (이미 있던 곡이라 안 들어간 건 뺌)
  plTracks = plTracks.filter((t) => !pend.includes(t) || m[t.v]);
  pend.forEach((t) => { if (m[t.v]) t.s = m[t.v]; });
  drawTracks();
  for (let n = 0; n < add.length; n++) if (m[add[n].v] && before[n]) await call("moveBefore", { pid, sid: m[add[n].v], before: before[n] }, 30).catch(() => {});
}
/// 모으기: 흩어진 앨범 곡들을 첫 곡 자리에 한데 모음 (실제 플레이리스트 순서) — 화면은 바로, 서버는 뒤에서
async function gatherGroup(idx) {
  const pid = plSel;
  const group = idx.map((k) => plTracks[k]);
  const sids = new Set(group.map((t) => t.s));
  const rest = plTracks.filter((t) => !sids.has(t.s));
  const at = plTracks.slice(0, idx[0]).filter((t) => !sids.has(t.s)).length;
  rest.splice(at, 0, ...group);
  const after = rest[at + group.length]?.s || null;
  plTracks = rest;
  drawTracks();
  // 뒤 곡부터: 마지막 곡을 '뒤에 오는 곡' 앞으로, 그 앞 곡을 그 곡 앞으로 … (첫 곡은 그대로)
  let before = after;
  for (const t of group.slice(1).reverse()) {
    if (!(await call("moveBefore", { pid, sid: t.s, before }, 30).catch(() => false))) { toast("모으지 못했어요"); break; }
    before = t.s;
  }
  if (plSel === pid) loadTracks();
}
function trackMenu(x, y, row) {
  const t = plTracks[+row.dataset.k];
  showMenu(x, y, [
    { label: "여기부터 재생", action: () => playList(plSel, t.v) },
    { label: "다른 플레이리스트에도 넣기…", action: () => addMenu(x, y, [t.v], []) },
    "-", { label: "이 플레이리스트에서 빼기", action: () => removeTrack(t) },
  ]);
}
function removeTrack(t) { removeTracks([t], `‘${t.t.slice(0, 12)}’`); }
/// 곡들(한 곡 · 앨범째)을 플레이리스트에서 빼기 — 화면은 바로, 서버는 한 번에, 되돌리기 가능
async function removeTracks(list, label) {
  const pid = plSel;
  const gone = new Set(list.map((t) => t.s));
  const entries = plTracks.map((t, k) => (gone.has(t.s) ? { t, after: k + 1 < plTracks.length ? plTracks[k + 1].s : null } : null)).filter(Boolean);
  plTracks = plTracks.filter((t) => !gone.has(t.s));
  plUndo = null;
  drawTracks();
  try {
    if (!(await call("removeMany", { pid, sids: list.map((t) => t.s), vids: list.map((t) => t.v) }, 30))) throw "빼지 못했어요";
    if (plSel !== pid) return;
    plUndo = { pid, entries, label };
    drawTracks();
  } catch (e) { fail(e); if (plSel === pid) loadTracks(); }
}
/// 되돌리기: 다시 넣으면 맨 끝에 붙어서, 새 자리 ID 로 뒤 곡부터 원래 자리(뒤에 있던 곡 앞)로
async function undoTracks() {
  const u = plUndo;
  if (!u) return;
  plUndo = null;
  status("되돌리는 중…");
  try {
    const m = await call("addIds", { pid: u.pid, vids: u.entries.map((e) => e.t.v) }, 30);
    if (!m || !Object.keys(m).length) throw "되돌리지 못했어요";
    const newSid = {};
    for (const e of u.entries) if (m[e.t.v]) newSid[e.t.s] = m[e.t.v];
    for (const e of [...u.entries].reverse()) {
      const sid = newSid[e.t.s];
      if (sid) await call("moveBefore", { pid: u.pid, sid, before: e.after ? newSid[e.after] || e.after : null }, 30).catch(() => {});
    }
    status("");
  } catch (e) { fail(e); }
  if (plSel === u.pid) loadTracks();
}

// MARK: 랜덤 플레이리스트 — 가수 고르기(비중 1~5) · 곡 수나 시간 · 인기곡 위주 · 새로 만들기 또는 덧붙이기

const R = { picks: [], mode: "count", amount: 30, unit: "min", popular: true, target: "new", name: "" };
try { Object.assign(R, JSON.parse(localStorage.getItem("mzRandom") || "{}"), { picks: (JSON.parse(localStorage.getItem("mzRandom") || "{}").picks || []).map((p) => ({ ...p, songs: null })) }); } catch { /* 없음 */ }
const saveR = () => { try { localStorage.setItem("mzRandom", JSON.stringify({ ...R, picks: R.picks.map(({ id, name, w }) => ({ id, name, w })) })); } catch { /* 없음 */ } };
let searchHits = [];
let genreCache = null; // 장르 목록 (한 번 읽으면 기억)
let recHits = [];       // 장르 추천 가수 (지금 보여 주는 것)
let recGenre = null;    // { g: 장르, pool: 모은 가수, shown: 보여 준 가수 id, usedLists: 읽은 플레이리스트 }
async function drawRandom() {
  const lists = myLists || [];
  body.innerHTML = `<div class="mz-rand">
    <div class="mz-h">랜덤 플레이리스트</div>
    <p class="mz-note">가수를 고르고(비중 1~5), 곡 수나 시간을 정하면 그 가수들의 인기곡에서 골라 플레이리스트로 만들고 바로 재생해요.</p>
    <div class="mz-rand-search"><div class="mz-rand-row"><input type="search" id="rq" placeholder="가수 찾기 (이름 앞부분만 써도 돼요)"><button class="pl-open ghost" id="rFromQueue" title="지금 다음 트랙 목록에 있는 가수들을 한 번에">다음 트랙에서 가수 가져오기</button></div><div class="mz-hits" id="rhits"></div></div>
    <div class="mz-genre">
      <button class="mz-gbtn" id="rGenreBtn" title="YouTube Music 의 장르별 대표 플레이리스트에서 많이 나오는 가수를 추천">${genreBtnLabel()}</button>
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
      <select id="rtarget"><option value="new">새 플레이리스트</option>${lists.map((l) => `<option value="${esc(l.id)}" ${R.target === l.id ? "selected" : ""}>‘${esc(l.t)}’에 덧붙이기</option>`).join("")}</select>
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
  onConfigChanged(async () => { cfg = await readConfig(); applyTheme(cfg); Player.setCfg(cfg); drawLock(); drawPlayer(); drawSide(); });
  const el = $("#player");
  const line = $("#lyline");
  const showLine = () => !big && cfg.lyricsLine !== false && !cfg.detachLyrics;
  // 왼쪽 아래 가사 칸: 크게 볼 때 · 가사 탭이 아닐 때 · 떼어 내지 않았을 때 (떼어 내면 '가사 줄' 창으로)
  const side = $("#lyside");
  let sideN = 2;
  try { const v = localStorage.getItem("sideLyricsLines"); if (v !== null) sideN = +v; } catch { /* 없음 */ }
  const showSide = () => big && tab !== 1;
  drawSide = () => {
    side.hidden = !showSide();
    if (side.hidden) return;
    // 떼어 냈으면 그 자리에 '여기로 되돌리기'
    side.classList.toggle("away", !!cfg.detachLyrics);
    if (cfg.detachLyrics) {
      if (side._sig !== "away") { side._sig = "away"; side.innerHTML = `<button class="pl-open ghost ls-back" data-s="back" title="떼어 낸 가사 줄 창을 닫고 이 칸으로 되돌려요">가사를 따로 띄워 뒀어요 · 여기로 되돌리기</button>`; }
      return;
    }
    if (side._sig === "away") side._sig = "";
    Player.renderSide(side, sideN);
  };
  side.addEventListener("click", (e) => { if (e.target.closest('[data-s="back"]')) setConfig("detachLyrics", false); });
  Player.bindSide(side, {
    count: (n) => { sideN = n; try { localStorage.setItem("sideLyricsLines", String(n)); } catch { /* 없음 */ } side._sig = ""; drawSide(); },
    detach: () => setConfig("detachLyrics", true),
  });

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
      if (big && tab === 0) queueLeftTick();
      drawSide();
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
    drawSide();
    if (!big) return;
    if (tab === 1) Player.renderFull(body);
    const t = Player.state().title || "";
    if (t !== lastTitle) {
      lastTitle = t;
      if (tab === 0) setTimeout(() => loadQueue(true), 1200);
      if (tab === 2) loadAlbums();
      if (tab === 3 && plSel) {
        if (plGroup && plAuto) { plFlip.clear(); drawTracks(); }
        else body.querySelectorAll(".mz-pl-tracks .mz-row").forEach((r) => r.classList.toggle("cur", plTracks[+r.dataset.k]?.t === t));
      }
    }
  });
  body.dataset.tools = "1"; // 가사 탭 제목 옆에 번역 · 발음 고르기
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
    $("#bigBtn").title = big ? "작게 보기" : "크게 보기 — 큰 앨범 · 다음 트랙 · 가사 · 앨범 · 플레이리스트 · 랜덤 (YouTube Music)";
    lastH = 0;
    try {
      if (big) {
        const [bw, bh] = getSize("playerBigSize", [940, 640]);
        await w.setMinSize(new T.dpi.LogicalSize(760, 420)); // 왼쪽(340) + 오른쪽 탭 줄이 한 줄로 들어가는 폭
        await w.setSize(new T.dpi.LogicalSize(bw, bh));
      } else {
        await w.setMinSize(new T.dpi.LogicalSize(260, 60));
        const [sw] = getSize("playerSmallW", [360, 100]);
        const f = await w.scaleFactor();
        const s = (await w.innerSize()).toLogical(f);
        await w.setSize(new T.dpi.LogicalSize(sw, s.height));
      }
    } catch (e) { console.warn(e); }
    applyLevel();
    drawPlayer();
    drawSide();
    drawNext();
    if (big) { drawTabs(); show(); } else fit();
  }
  if (T) T.event.listen("player-big", () => { if (!big) setBig(true); else w.setFocus(); });

  // 작게: 창 높이 = 위쪽 줄 + 플레이어 + 가사 줄 (가사를 펼치거나 곡이 바뀌어 높이가 달라지면 따라감)
  let fitT = null, lastH = 0;
  function fit() {
    if (big) return;
    clearTimeout(fitT);
    fitT = setTimeout(async () => {
      const h = Math.ceil(["#app > .ptool", "#player", "#lyline", "#nextline"].reduce((a, s) => { const e = $(s); return a + (e && !e.hidden ? e.getBoundingClientRect().height : 0); }, 0) + 12);
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
  // 왼쪽 아래 모서리도 (Mac 판처럼 아래 두 모서리)
  $("#mzResizeSW").addEventListener("mousedown", (e) => { if (e.button === 0 && big) w.startResizeDragging("SouthWest").catch(() => {}); });
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
  w.onResized(async () => {
    // 최소 크기에 닿으면 테두리를 붉게 (잠깐)
    try {
      const f = await w.scaleFactor(), sz = (await w.innerSize()).toLogical(f);
      const atMin = big ? sz.width <= 601 || sz.height <= 401 : sz.width <= 261;
      if (atMin) { document.body.classList.add("atmin"); clearTimeout(minT); minT = setTimeout(() => document.body.classList.remove("atmin"), 700); }
    } catch { /* 없음 */ }
    if (!big) return; clearTimeout(sizeT); sizeT = setTimeout(rememberSize, 500);
  });
  let minT = null;

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
  // 업데이트 단추: 새 버전이 있으면 주황색 점 · 누르면 바로 업데이트, 없으면 누르면 확인
  let upd = null, ver = "";
  T.app?.getVersion?.().then((v) => { ver = v; drawUpd(); }).catch(() => {});
  function drawUpd() {
    const b = $("#updBtn");
    b.classList.toggle("has-upd", !!upd);
    $("#hubBtn").classList.toggle("has-upd", !!upd);
    b.title = upd ? `새 버전 ${upd.version} 으로 업데이트 (지금 ${upd.current}) — 누르면 받아서 다시 켜요` : `업데이트 확인${ver ? ` (지금 ${ver})` : ""}`;
  }
  T.event.listen("update-available", (e) => { upd = e.payload; drawUpd(); });
  invoke("update_info").then((u) => { upd = u || null; drawUpd(); }).catch(() => {});
  $("#updBtn").onclick = async () => {
    const b = $("#updBtn");
    if (!upd) { toast("새 버전 확인 중…"); invoke("check_update").catch(() => {}); return; }
    if (b.classList.contains("busy")) return;
    b.classList.add("busy");
    toast(`새 버전 ${upd.version} 받는 중… 다 받으면 도구함이 잠깐 꺼졌다가 다시 켜져요`);
    try { await invoke("self_update"); } catch (err) { b.classList.remove("busy"); toast(`업데이트하지 못했어요: ${err}`); }
  };
  drawUpd();
  // MARK: ☰ 판 — 창 위치 · 배치 프리셋 · 투명도(평소 / 조작할 때) · 뒤쪽 클릭 · 다른 프로그램 · 도구
  const hub = $("#hub");
  const ls = (k, d) => { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } };
  const lsSet = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* 없음 */ } };
  $("#hubBtn").onclick = (e) => { e.stopPropagation(); hub.hidden = !hub.hidden; if (!hub.hidden) drawHub(); };
  document.addEventListener("mousedown", (e) => { if (!hub.hidden && !hub.contains(e.target) && !e.target.closest("#hubBtn") && !e.target.closest("#menu")) hub.hidden = true; });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") hub.hidden = true; });
  // 창 위치: 0 다른 창 뒤 · 1 일반 · 2 다른 창 위 (-1: 예전처럼 작게면 위, 크게면 일반)
  let level = ls("mzLevel", -1);
  function curLevel() { return level >= 0 ? level : (big ? 1 : 2); }
  applyLevel = async () => {
    const lv = curLevel();
    try { await w.setAlwaysOnBottom(lv === 0); await w.setAlwaysOnTop(lv === 2); } catch { /* 없음 */ }
  };
  // 투명도 (40 ~ 100): 평소 / 조작할 때 — 마우스가 창 위에 있으면(뒤쪽 클릭이면 🔒 를 풀었을 때) '조작할 때'
  // 100% 는 완전히 불투명 (바탕까지), 그 아래는 창 전체를 그만큼 비침 — 처음 값 99 는 예전 모양(반투명 유리)
  let alpha = ls("mzAlpha", 99), alphaA = ls("mzAlphaA", 99), ct = ls("mzClickThrough", false), unlocked = false, hovering = false;
  function applyAlpha() {
    const v = hovering && (!ct || unlocked) ? alphaA : alpha;
    document.documentElement.classList.toggle("solid", v >= 100);
    document.documentElement.style.opacity = v >= 100 ? "1" : String(v / 100);
  }
  document.documentElement.addEventListener("mouseenter", () => { hovering = true; applyAlpha(); });
  document.documentElement.addEventListener("mouseleave", () => { hovering = false; applyAlpha(); });
  // 뒤쪽 클릭: 창 전체가 마우스를 통과, 위쪽 가운데 🔒 작은 창만 눌림 → 풀면 마우스가 창 밖으로 나갈 때까지 조작
  async function lockPos() {
    const f = await w.scaleFactor(), p = (await w.outerPosition()).toLogical(f), sz = (await w.outerSize()).toLogical(f);
    return { x: Math.round(p.x + sz.width / 2 - 22), y: Math.round(p.y + 6) };
  }
  async function showLock() {
    const p = await lockPos();
    await invoke("open_window", { label: "unlock", url: "unlock.html", title: "잠금", width: 44, height: 20, x: p.x, y: p.y, frameless: true, onTop: true }).catch(() => {});
  }
  const hideLock = () => invoke("close_window", { label: "unlock" }).catch(() => {});
  let ctTimer = null;
  async function applyClickThrough() {
    clearInterval(ctTimer); ctTimer = null;
    if (!ct) { unlocked = false; await w.setIgnoreCursorEvents(false).catch(() => {}); hideLock(); applyAlpha(); return; }
    if (!unlocked) { await w.setIgnoreCursorEvents(true).catch(() => {}); showLock(); }
    // 0.2초마다: 풀린 상태에서 마우스가 창 밖이면 다시 잠금, 잠긴 동안엔 🔒 를 창 위쪽 가운데에
    ctTimer = setInterval(async () => {
      try {
        const c = await T.window.cursorPosition(), p = await w.outerPosition(), sz = await w.outerSize();
        const inside = c.x >= p.x - 6 && c.x <= p.x + sz.width + 6 && c.y >= p.y - 6 && c.y <= p.y + sz.height + 6;
        if (unlocked && !inside) { unlocked = false; await w.setIgnoreCursorEvents(true); showLock(); applyAlpha(); }
        else if (!unlocked) { const lp = await lockPos(); const lw = await T.webviewWindow?.WebviewWindow?.getByLabel?.("unlock"); lw?.setPosition(new T.dpi.LogicalPosition(lp.x, lp.y)).catch(() => {}); }
      } catch { /* 없음 */ }
    }, 200);
  }
  T.event.listen("player-unlock", async () => { unlocked = true; hovering = true; await w.setIgnoreCursorEvents(false).catch(() => {}); hideLock(); applyAlpha(); });
  // 배치 프리셋: 자리 · 크기 · 크게/작게 · 창 위치 · 투명도 · 뒤쪽 클릭 (눌러서 적용)
  async function capture(name) {
    const f = await w.scaleFactor(), p = (await w.outerPosition()).toLogical(f), sz = (await w.innerSize()).toLogical(f);
    return { name, x: Math.round(p.x), y: Math.round(p.y), w: Math.round(sz.width), h: Math.round(sz.height), big, level, alpha, alphaA, ct };
  }
  async function applyPreset(pr) {
    if (pr.big !== big) await setBig(pr.big);
    level = pr.level; lsSet("mzLevel", level); await applyLevel();
    alpha = pr.alpha; alphaA = pr.alphaA; lsSet("mzAlpha", alpha); lsSet("mzAlphaA", alphaA);
    ct = pr.ct; lsSet("mzClickThrough", ct);
    try { await w.setSize(new T.dpi.LogicalSize(pr.w, pr.h)); await w.setPosition(new T.dpi.LogicalPosition(pr.x, pr.y)); } catch { /* 없음 */ }
    applyAlpha(); applyClickThrough();
  }
  function drawHub() {
    const lv = curLevel();
    hub.querySelectorAll("[data-lv]").forEach((b) => b.classList.toggle("on", +b.dataset.lv === lv));
    const list = ls("mzPresets", []);
    $("#hubPresets").innerHTML = list.map((p, i) => `<div class="hub-pr"><button class="pl-open ghost" data-pr="${i}" title="이 배치로">${esc(p.name)}</button><button class="icon sm" data-prx="${i}" title="지우기">✕</button></div>`).join("") +
      `<button class="pl-open ghost" id="hubSave">＋ 지금 배치 저장</button>`;
    $("#hubA").value = alpha; $("#hubAv").textContent = alpha >= 100 ? "불투명" : alpha + "%";
    $("#hubAA").value = alphaA; $("#hubAAv").textContent = alphaA >= 100 ? "불투명" : alphaA + "%";
    $("#hubCT").checked = ct;
    drawCover();
  }
  // 가림막: ＋ 추가 · 잠금 · 숨기기 (모든 가림막 같이, 트레이 🧰 에도 있음)
  let cov = { locked: true, hidden: false };
  function drawCover() {
    const cnt = (k) => { try { return Object.keys(JSON.parse(localStorage.getItem(k) || "{}")).length; } catch { return 0; } };
    const n = cnt("covers") + cnt("mirrors");
    $("#covLock").hidden = $("#covHide").hidden = !n;
    $("#covLock").textContent = cov.locked ? "🔓 풀기" : "🔒 잠그기";
    $("#covLock").title = cov.locked ? "가림막 · 비추기 잠금 풀기 — 옮기고 크기 · 색 · 투명도를 바꿀 수 있어요" : "가림막 · 비추기 잠그기 — 클릭이 아래 창(게임)으로 통과해요";
    $("#covHide").textContent = cov.hidden ? "보이기" : "숨기기";
  }
  invoke("cover_state").then((s) => { cov = s; drawCover(); }).catch(() => {});
  T.event.listen("cover-state", (e) => { cov = e.payload; drawCover(); });
  hub.addEventListener("click", async (e) => {
    const lb = e.target.closest("[data-lv]");
    if (lb) { level = +lb.dataset.lv; lsSet("mzLevel", level); await applyLevel(); drawHub(); return; }
    const pb = e.target.closest("[data-pr]");
    if (pb) { hub.hidden = true; applyPreset(ls("mzPresets", [])[+pb.dataset.pr]); return; }
    const px = e.target.closest("[data-prx]");
    if (px) { const l = ls("mzPresets", []); l.splice(+px.dataset.prx, 1); lsSet("mzPresets", l); drawHub(); return; }
    if (e.target.closest("#hubSave")) {
      const l = ls("mzPresets", []);
      const name = await ask("배치 프리셋 이름", `배치 ${l.length + 1}`);
      if (!name) return;
      l.push(await capture(name)); lsSet("mzPresets", l); drawHub(); toast(`‘${name}’ 저장했어요`);
      return;
    }
    if (e.target.closest("#hubShorts")) {
      hub.hidden = true;
      await invoke("open_window", { label: "yt-video", url: "https://www.youtube.com/shorts", title: "YouTube", width: 1100, height: 720 }).catch(() => {});
      invoke("web_eval", { label: "yt-video", js: "if (!location.pathname.startsWith('/shorts')) location.href = 'https://www.youtube.com/shorts'" }).catch(() => {});
      return;
    }
    if (e.target.closest("#lineBtn")) { setConfig("lyricsLine", !(cfg.lyricsLine !== false)); return; }
    if (e.target.closest("#covAdd")) { invoke("cover_add").then(() => setTimeout(drawCover, 600)).catch((err) => toast(`가림막을 만들지 못했어요: ${err}`)); return; }
    if (e.target.closest("#mirAdd")) { hub.hidden = true; invoke("mirror_pick").then(() => setTimeout(drawCover, 600)).catch((err) => toast(`영역을 고를 수 없어요: ${err}`)); return; }
    if (e.target.closest("#covLock")) { invoke("cover_set", { locked: !cov.locked }).catch(() => {}); return; }
    if (e.target.closest("#covHide")) { invoke("cover_set", { hidden: !cov.hidden }).catch(() => {}); return; }
  });
  hub.addEventListener("input", (e) => {
    if (e.target.id === "hubA") { alpha = +e.target.value; lsSet("mzAlpha", alpha); $("#hubAv").textContent = alpha >= 100 ? "불투명" : alpha + "%"; hovering = false; applyAlpha(); }
    if (e.target.id === "hubAA") { alphaA = +e.target.value; lsSet("mzAlphaA", alphaA); $("#hubAAv").textContent = alphaA >= 100 ? "불투명" : alphaA + "%"; hovering = true; applyAlpha(); }
  });
  hub.addEventListener("change", (e) => {
    if (e.target.id === "hubCT") { ct = e.target.checked; lsSet("mzClickThrough", ct); $("#hubBtn").classList.toggle("on", ct); applyClickThrough(); }
  });
  $("#hubBtn").classList.toggle("on", ct);
  applyAlpha();
  applyClickThrough();
  // 작게 볼 때 다음 곡 한 줄 (6초마다 다음 트랙을 읽음, 누르면 크게 보기)
  const nextEl = $("#nextline");
  drawNext = () => { nextEl.hidden = big || !nextEl.textContent; };
  nextEl.onclick = () => setBig(true);
  setInterval(async () => {
    if (big || document.hidden) return;
    let q; try { q = await call("queue", {}, 15); } catch { return; }
    const main = (q || []).filter((x) => !x.auto), c = main.findIndex((x) => x.cur);
    let t = "";
    if (c >= 0 && c + 1 < main.length) { const n = main[c + 1], left = main.length - c - 2; t = `${n.title} — ${artistOf(n.artist)}${n.dur ? ` · ${n.dur}` : ""}${left > 0 ? `  (+${left}곡)` : ""}`; }
    else { const a = (q || []).find((x) => x.auto && !x.cur); if (a) t = `${a.title} — ${artistOf(a.artist)} · 자동재생`; }
    const had = !nextEl.hidden;
    nextEl.innerHTML = t ? `<span class="nx-k">⏭ 다음 곡</span> ${esc(t)}` : "";
    drawNext();
    if (had !== !nextEl.hidden) fit();
  }, 6000);

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
/// 랜덤 플레이리스트 가수에 넣기: 가수 페이지 ID 가 있으면 그대로, 없으면 이름으로 찾아 첫 가수 (비중 3, 이미 있으면 건너뜀)
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
  // 남은 가수가 적으면 다른 플레이리스트를 더 읽어서 채움
  if (fresh().length < 8) {
    rec.innerHTML = `<div class="mz-note">‘${esc(st.g.t)}’ 플레이리스트에서 가수 모으는 중…</div>`;
    let r;
    try { r = await call("genreArtists", { id: st.g.id, params: st.g.params, lists: 8, max: 80, skip: st.usedLists }, 90); } catch (err) { rec.innerHTML = ""; fail(err); return; }
    if (recGenre !== st) return;
    st.usedLists.push(...(r.used || []));
    for (const a of r.artists || []) {
      const have = st.pool.find((x) => x.id === a.id);
      if (have) have.n += a.n; else st.pool.push(a);
    }
    // 장르 플레이리스트를 다 읽었는데도 다 보여 줬으면 처음부터 다시
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
    <div class="mz-recgrid">${pick.map((a, i) => `<button class="mz-recit" data-rec="${i}" title="눌러서 랜덤 가수에 넣기 · 이 장르 플레이리스트에 ${a.n}번 나옴">
      <span class="mz-av" style="--h:${hueOf(a.name)}">${esc([...a.name.trim()][0] || "?")}</span>
      <span class="mz-t"><b>${esc(a.name)}</b><small>플레이리스트에 ${a.n}번</small></span><span class="mz-plus">＋</span></button>`).join("")}</div>`;
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
