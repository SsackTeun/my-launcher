// 사이트 창(YouTube · Netflix · YouTube Music)에 넣는 스크립트 — Mac 판 youtube.swift 의 작은 창(PIP)을 Windows 로
// - 보통 창: 오른쪽 아래 [PIP] 단추 (영상이 있을 때)
// - 작은 창: 제목 막대 없는 항상 위 창에 영상만 꽉 (자막은 보임), 마우스를 올리면 조작 단추
//   누르면 재생/멈춤 · 두 번 누르면 원래 창 · 끌면 옮기기 · 가장자리 끌면 크기 · 휠은 볼륨(쇼츠는 다음 · 이전 쇼츠, 볼륨은 Shift + 휠) · Esc 원래 창
// - 도구함에 알릴 때: https://mylauncher.invalid/<명령> 으로 이동하려 하면 도구함이 막고 처리
(function () {
  if (window.top !== window || window.__ml) return;
  window.__ml = true;

  // '사이트에서 나갈까요?' 안 띄우기: 사이트가 떠나기 전 확인(beforeunload)을 걸어도 무시
  // (도구함이 다른 플레이리스트로 넘기거나 창을 닫을 때 막히지 않게. 이 사이트들엔 저장 안 한 문서 같은 게 없음)
  try {
    const add = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (type, fn, opt) {
      if (type === 'beforeunload' && (this === window || this === document)) return;
      return add.call(this, type, fn, opt);
    };
    Object.defineProperty(window, 'onbeforeunload', { configurable: true, get() { return null; }, set() {} });
  } catch (e) {}

  // 로그인 안 한 채 YouTube Music 을 열면 YouTube 가 Premium 안내 페이지로 보냄 → 로그인 페이지로 (로그인하면 YouTube Music 으로 돌아옴)
  if (location.hostname === 'www.youtube.com' && location.pathname.startsWith('/musicpremium') && !document.cookie.includes('SAPISID=') && !sessionStorage.__mlLoginTried) {
    sessionStorage.__mlLoginTried = '1';
    location.replace('https://accounts.google.com/ServiceLogin?service=youtube&hl=ko&continue=' + encodeURIComponent('https://music.youtube.com/'));
    return;
  }

  // YouTube 는 Trusted Types 로 그냥 글자를 innerHTML 에 넣는 걸 막음 → 이름 붙인 정책으로 넣음
  let tt = null;
  try { tt = window.trustedTypes && trustedTypes.createPolicy('mylauncher', { createHTML: (x) => x }); } catch (e) { tt = null; }
  const H = (x) => (tt ? tt.createHTML(x) : x);
  // Netflix: 하드웨어 보호 재생(PlayReady SL3000 · 하드웨어 Widevine)은 그래픽 카드가 직접 그려서 도구함 창 안에서는 화면이 검게 나옴
  // → Netflix 에 그 방식은 없다고 알려 줘서 소프트웨어 보호 재생(SL2000, HD)을 고르게 함
  if (location.hostname.includes('netflix') && navigator.requestMediaKeySystemAccess) {
    const orig = navigator.requestMediaKeySystemAccess.bind(navigator);
    const hw = (r) => /3000|HW_SECURE/i.test(r || '');
    const no = () => Promise.reject(new DOMException('하드웨어 보호 재생은 쓰지 않아요', 'NotSupportedError'));
    navigator.requestMediaKeySystemAccess = function (ks, cfgs) {
      if (/hardware|\.3000/i.test(ks)) return no();
      const out = [];
      for (const c of cfgs || []) {
        const v = (c.videoCapabilities || []).filter((x) => !hw(x.robustness));
        const a = (c.audioCapabilities || []).filter((x) => !hw(x.robustness));
        if ((c.videoCapabilities || []).length && !v.length) continue;
        if ((c.audioCapabilities || []).length && !a.length) continue;
        out.push(Object.assign({}, c, c.videoCapabilities ? { videoCapabilities: v } : {}, c.audioCapabilities ? { audioCapabilities: a } : {}));
      }
      return out.length ? orig(ks, out) : no();
    };
  }

  // 도구함에 알리기: 페이지 제목을 표시가 붙은 글로 바꾸면 도구함이 읽고 '받았음'(__mlAck)을 돌려줌 → 다음 알림 → 다 보내면 원래 제목
  // (가짜 페이지 이동으로 알리면 Netflix 가 '떠나는 중' 으로 알고 앱을 멈춰서 로딩 화면에 멈춤 → 제목으로)
  // 타이머로 기다리지 않아서 숨긴 창(타이머가 느려짐)에서도 빠름. 창 제목 · 작업 표시줄에는 도구함이 정한 이름이 보여서 안 보임
  const MARK = '\u2063mylauncher:';
  const queue = [];
  let waiting = false, seq = 0, orig = null, ackTimer = 0;
  function pump() {
    if (waiting) return;
    if (!queue.length) {
      if (orig !== null) { if (document.title.startsWith(MARK)) document.title = orig; orig = null; }
      return;
    }
    if (orig === null) orig = document.title.startsWith(MARK) ? '' : document.title;
    waiting = true;
    // 같은 글을 두 번 넣으면 제목이 안 바뀐 걸로 쳐서 알림이 안 가므로 번호를 붙임
    document.title = MARK + (++seq) + '|' + queue.shift();
    clearTimeout(ackTimer);
    ackTimer = setTimeout(() => { waiting = false; pump(); }, 1500); // 혹시 답이 없으면
  }
  window.__mlAck = () => { clearTimeout(ackTimer); waiting = false; pump(); };
  const send = (cmd) => { queue.push(cmd); pump(); };

  // 도구함이 이 페이지에서 함수를 돌리고 결과를 받아 감 (Mac 판의 callAsyncJavaScript 대신)
  // 결과(JSON)는 UTF-8 → base64url 로 바꿔 3000자씩 나눠 보냄 (페이지 제목은 4000자쯤까지)
  const b64url = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  window.__mlRun = async (id, fn, args) => {
    let out;
    try { out = { ok: true, v: await fn(args) }; } catch (e) { out = { ok: false, e: String((e && e.message) || e) }; }
    let json;
    try { json = JSON.stringify(out); } catch (e) { json = JSON.stringify({ ok: false, e: 'JSON 로 못 바꿈' }); }
    const d = b64url(new TextEncoder().encode(json));
    const N = 3000, n = Math.max(1, Math.ceil(d.length / N));
    for (let i = 0; i < n; i++) send(`rpc?id=${id}&i=${i}&n=${n}&d=${d.slice(i * N, (i + 1) * N)}`);
  };
  // YouTube · Netflix 페이지에서만 (Google 로그인 페이지 등에는 아무것도 안 넣음)
  if (!/(^|\.)(youtube\.com|netflix\.com)$/.test(location.hostname)) return;
  const site = location.hostname.includes('netflix') ? 'netflix' : location.hostname.startsWith('music.') ? 'music' : 'youtube';

  // MARK: YouTube Music 계정 요청 (로그인 쿠키로 서명 — 쿠키 · 서명은 페이지 밖으로 안 나감, Mac 판과 같음)
  if (site === 'music') {
    const api = async (path, body) => {
      const ck = document.cookie.split('; ');
      const c = ck.find((x) => x.startsWith('SAPISID=')) || ck.find((x) => x.startsWith('__Secure-3PAPISID='));
      const origin = 'https://music.youtube.com';
      const h = { 'Content-Type': 'application/json', 'X-Origin': origin, 'X-Goog-AuthUser': String(ytcfg.get('SESSION_INDEX') || 0) };
      if (c) {
        const ts = Math.floor(Date.now() / 1000);
        const buf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + c.split('=')[1] + ' ' + origin));
        h['Authorization'] = 'SAPISIDHASH ' + ts + '_' + [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
      }
      const r = await fetch('/youtubei/v1/' + path + '?prettyPrint=false', { method: 'POST', headers: h,
        body: JSON.stringify(Object.assign({ context: ytcfg.get('INNERTUBE_CONTEXT') }, body)) });
      return r.json();
    };
    const collect = (o, key) => { const out = []; JSON.stringify(o, (k, v) => { if (k === key) out.push(v); return v; }); return out; };
    const nextToken = (o) => { const s = JSON.stringify(o);
      return (s.match(/"continuationCommand":\{"token":"([^"]+)"/) || s.match(/"nextContinuationData":\{"continuation":"([^"]+)"/) || [])[1]; };
    const albumList = async (id) => { const b = JSON.stringify(await api('browse', { browseId: id }));
      return (b.match(/"urlCanonical":"[^"]*list=(OLAK[^"&\\]+)/) || b.match(/"playlistId":"(OLAK[^"]+)"/) || [])[1] || null; };
    window.__mlApi = { api, collect, nextToken, albumList };
  }
  const q = (s) => document.querySelector(s);
  const shorts = () => location.pathname.startsWith('/shorts');

  // MARK: 영상 · 플레이어

  const nfPlayer = () => { try { const vp = netflix.appContext.state.playerApp.getAPI().videoPlayer; const ids = vp.getAllPlayerSessionIds(); return ids.length ? vp.getVideoPlayerBySessionId(ids[ids.length - 1]) : null; } catch (e) { return null; } };
  const ytPlayer = () => (shorts() ? document.getElementById('shorts-player') : document.getElementById('movie_player'));
  function video() {
    if (site === 'netflix') return q('.watch-video video') || q('video');
    return (shorts() ? q('#shorts-player video') : q('#movie_player video.html5-main-video')) || [...document.querySelectorAll('video')].find((x) => x.readyState > 0) || null;
  }
  const P = {
    toggle() {
      const p = site === 'netflix' && nfPlayer();
      if (p && p.isPaused) return p.isPaused() ? p.play() : p.pause();
      const v = video(); if (v) v.paused ? v.play() : v.pause();
    },
    pause() { const p = site === 'netflix' && nfPlayer(); if (p && p.pause) p.pause(); else video()?.pause(); },
    /// 실시간 방송에서 지금(실시간 끝)으로
    toLive() { const mp = ytPlayer(); if (mp?.seekToLiveHead) mp.seekToLiveHead(); else { const st = P.state(); if (st) P.seek(st.e); } },
    seek(t) {
      const p = site === 'netflix' && nfPlayer();
      if (p && p.seek) return p.seek(Math.round(t * 1000)); // Netflix 는 영상 위치를 직접 바꾸면 오류
      const v = video(); if (v) v.currentTime = t;
    },
    state() {
      const v = video();
      if (!v) return null;
      if (site === 'netflix') {
        const p = nfPlayer();
        return { t: p?.getCurrentTime ? p.getCurrentTime() / 1000 : v.currentTime, s: 0, e: p?.getDuration ? p.getDuration() / 1000 : (isFinite(v.duration) ? v.duration : 0),
          paused: p?.isPaused ? p.isPaused() : v.paused, vol: (p?.getVolume ? p.getVolume() : v.volume) * 100, muted: p?.isMuted ? p.isMuted() : v.muted, live: false };
      }
      let s = 0, e = v.duration, head = false;
      const mp = ytPlayer();
      // 실시간 방송: YouTube 가 영상 길이를 보통 숫자로 줄 때가 있어서(그러면 '1:28 / 2:27' 처럼 남아 보였음) 플레이어에게 직접 물어봄
      let live = !isFinite(v.duration);
      try { if (mp?.getVideoData?.()?.isLive) live = true; } catch (x) {}
      if (live) {
        e = NaN;
        try {
          const ps = mp?.getProgressState?.();
          if (ps && isFinite(ps.seekableEnd) && ps.seekableEnd > 0) { s = ps.seekableStart || 0; e = ps.seekableEnd; head = !!ps.isAtLiveHead; }
        } catch (x) {}
        if (!isFinite(e)) { const r = v.seekable; if (r && r.length) { s = r.start(0); e = r.end(r.length - 1); } else { s = 0; e = v.currentTime; } }
        // 실시간 끝에서 몇 초 안이면 '실시간' (버퍼만큼 늘 조금 뒤에 있음)
        if (e - v.currentTime < 12) head = true;
      }
      return { t: v.currentTime, s, e, head, paused: v.paused, vol: mp?.getVolume ? mp.getVolume() : v.volume * 100, muted: mp?.isMuted ? mp.isMuted() : v.muted, live };
    },
    volume(n) {
      n = Math.max(0, Math.min(100, Math.round(n)));
      if (site === 'netflix') { const p = nfPlayer(); if (p?.setVolume) { p.setVolume(n / 100); if (n > 0 && p.isMuted?.()) p.setMuted(false); } return; }
      const mp = ytPlayer(); if (mp?.setVolume) { mp.setVolume(n); if (n > 0 && mp.isMuted()) mp.unMute(); }
    },
    mute() {
      if (site === 'netflix') { const p = nfPlayer(); if (p?.setMuted) p.setMuted(!p.isMuted()); return; }
      const mp = ytPlayer(); if (mp?.isMuted) mp.isMuted() ? mp.unMute() : mp.mute();
    },
  };


  // MARK: 지금 재생 알림 (도구함 미니 플레이어의 ‹ › 재생기)
  // 바뀔 때마다 + 재생 중엔 5초마다 위치를 알림. 창을 숨기면 타이머가 느려져서 영상 이벤트로 알림
  // 새로 재생을 시작하면 s=1 → 도구함이 이 재생기로 넘어가고 다른 재생기는 일시정지
  const isMain = (v) => {
    if (!v) return false;
    if (site === 'youtube') return !!v.closest('#movie_player, #shorts-player') && !v.closest('ytd-video-preview, #inline-preview-player, ytd-thumbnail');
    return true;
  };
  function meta() {
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    let t = (md && md.title) || '', a = (md && md.artist) || '', art = '';
    try { const w = md && md.artwork; if (w && w.length) art = w[w.length - 1].src || ''; } catch (e) {}
    if (site === 'netflix' && !t) {
      const el = q('[data-uia="video-title"]');
      if (el) { const h = el.querySelector('h4'); t = (h ? h.textContent : el.textContent || '').trim(); a = h ? [...el.querySelectorAll('span')].map((x) => x.textContent).join(' ').trim() : ''; }
      if (!t && location.pathname.startsWith('/watch')) t = (document.title || 'Netflix').replace(/\s*[|-]\s*Netflix\s*$/i, '') || 'Netflix';
    }
    if (site === 'youtube' && !t) {
      t = (q('#title h1') || {}).textContent || document.title.replace(/\s*-\s*YouTube\s*$/, '');
      a = ((q('#owner #channel-name a') || q('ytd-channel-name a') || {}).textContent || '').trim();
    }
    return { t: String(t).trim(), a: String(a).trim(), art };
  }
  let lastKey = '', lastPosAt = 0;
  function report(started) {
    const v = video();
    const s0 = P.state();
    const m = meta();
    // 재생 중 = 소리 나게 재생 중 (Netflix 첫 화면 · YouTube 미리 보기처럼 소리 없이 도는 영상은 아님)
    const o = { t: m.t, a: m.a, art: m.art, p: v && isMain(v) && !v.paused && !v.muted && v.volume > 0 ? 1 : 0 };
    if (site === 'music') {
      const b = q('ytmusic-player-bar');
      let rep = b ? b.getAttribute('repeat-mode') || '' : '';
      if (!rep && b) {
        const r = [...b.querySelectorAll('button')].map((x) => x.getAttribute('aria-label') || '').find((x) => x.includes('반복') || x.toLowerCase().includes('repeat')) || '';
        rep = r.includes('한 곡') || r.toLowerCase().includes('one') ? 'ONE' : r.includes('모두') || r.toLowerCase().includes('all') ? 'ALL' : r ? 'NONE' : '';
      }
      const like = q('ytmusic-player-bar ytmusic-like-button-renderer');
      o.r = rep; o.l = like ? like.getAttribute('like-status') || '' : '';
    }
    const key = JSON.stringify(o);
    const now = Date.now();
    // 바뀌었거나 · 새로 시작했거나 · 재생 중이면 5초마다(위치)
    if (key === lastKey && !started && !(o.p && now - lastPosAt > 5000)) return;
    lastKey = key; lastPosAt = now;
    if (s0) { o.pos = (s0.t - s0.s).toFixed(1); o.dur = (s0.e - s0.s).toFixed(1); }
    if (started) o.s = 1;
    send('np?' + new URLSearchParams(o).toString());
  }
  const later = (started) => setTimeout(() => report(started), 80);
  // 새로 재생 시작: 소리 나는 본 영상만 (YouTube 첫 화면의 소리 없는 미리 보기는 빼기)
  // 타이머를 거치지 않고 바로 알림 (숨긴 창은 타이머가 느려짐). 소리 없이 돌다가 소리를 켜도 '시작'
  const startNow = (e) => { const v = e.target; if (isMain(v) && !v.paused && !v.muted && v.volume > 0) report(true); };
  for (const ev of ['play', 'playing', 'volumechange']) document.addEventListener(ev, startNow, true);
  for (const ev of ['pause', 'ended', 'loadedmetadata', 'seeked', 'volumechange']) document.addEventListener(ev, () => later(false), true);
  document.addEventListener('timeupdate', () => report(false), true);

  // YouTube: 늘 그 영상의 가장 높은 화질로 (영상이 열릴 때마다 · 다음 영상 · 쇼츠도)
  if (site === 'youtube') {
    let maxFor = '';
    const maxQuality = () => {
      const mp = ytPlayer();
      if (!mp || !mp.getAvailableQualityLevels) return;
      const best = mp.getAvailableQualityLevels().filter((q) => q && q !== 'auto')[0];
      if (!best) return;
      const key = location.pathname + location.search + best;
      if (maxFor === key && mp.getPlaybackQuality && mp.getPlaybackQuality() === best) return;
      maxFor = key;
      try { if (mp.setPlaybackQualityRange) mp.setPlaybackQualityRange(best, best); if (mp.setPlaybackQuality) mp.setPlaybackQuality(best); } catch (e) {}
    };
    for (const ev of ['loadedmetadata', 'playing']) document.addEventListener(ev, (e) => { if (isMain(e.target)) setTimeout(maxQuality, 300); }, true);
  }
  try {
    const d = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
    Object.defineProperty(navigator.mediaSession, 'metadata', { configurable: true, get() { return d.get.call(this); }, set(x) { d.set.call(this, x); later(false); } });
  } catch (e) {}
  if (site === 'music') {
    const watch = () => {
      const b = q('ytmusic-player-bar');
      if (!b) return setTimeout(watch, 1000);
      new MutationObserver(() => later(false)).observe(b, { attributes: true, subtree: true, attributeFilter: ['repeat-mode', 'like-status', 'aria-label'] });
      report(false);
    };
    if (document.readyState === 'loading') addEventListener('DOMContentLoaded', watch); else watch();
  }

  // 도구함 미니 플레이어의 단추 → 이 페이지에서 실행
  // YouTube Music 은 플레이어 줄 단추를 이름표(aria-label)로 찾아 누름 (Mac 판과 같은 방식)
  const YM_BTN = { toggle: ['재생', '일시중지', '일시정지', 'Play', 'Pause'], next: ['다음', 'Next'], prev: ['이전', 'Previous'],
    like: ['좋아요', 'Like'], shuffle: ['셔플', 'Shuffle'], repeat: ['반복', 'Repeat'] };
  function ymClick(name) {
    const L = YM_BTN[name];
    const bs = [...document.querySelectorAll('ytmusic-player-bar button, ytmusic-player-bar tp-yt-paper-icon-button')];
    const ok = (b) => { const a = (b.getAttribute('aria-label') || b.getAttribute('title') || '').trim(); return name === 'repeat' ? L.some((x) => a.includes(x)) : L.includes(a); };
    const b = bs.find((b) => ok(b) && b.offsetParent !== null) || bs.find(ok);
    if (b) b.click();
    return !!b;
  }
  window.__mlCtl = (action, value) => {
    const v = video();
    if (action === 'pause') { if (v && !v.paused) { if (site === 'music') ymClick('toggle') || v.pause(); else P.pause(); } }
    else if (action === 'seek') P.seek(+value);
    else if (site === 'music') ymClick(action);
    else if (action === 'toggle') P.toggle();
    else if (action === 'next') {
      if (site === 'netflix') { const b = q('[data-uia="control-next"]') || q('[data-uia="next-episode-seamless-button"]'); if (b) b.click(); }
      else { const mp = ytPlayer(); if (mp && mp.nextVideo) mp.nextVideo(); }
    } else if (action === 'prev') {
      const mp = site === 'youtube' && ytPlayer();
      const s = P.state();
      if (mp && mp.previousVideo && s && s.t - s.s < 3) mp.previousVideo(); else P.seek(s ? s.s : 0);
    } else if (action === 'volume') P.volume(+value);
    setTimeout(() => report(false), 250);
  };
  // YouTube Music 은 PIP 화면이 없음
  if (site === 'music') return;

  // MARK: 영상만 꽉 채우는 모양 (Mac 판과 같은 CSS)

  const YT_CSS = `
  html.ytmini, html.ytmini body { overflow: hidden !important; background: #000 !important; }
  html.ytmini body * { visibility: hidden !important; }
  html.ytmini:not(.ytmini-s) #movie_player video.html5-main-video, html.ytmini.ytmini-s #shorts-player video {
    visibility: visible !important; position: fixed !important; inset: 0 !important; left: 0 !important; top: 0 !important;
    width: 100vw !important; height: 100vh !important; object-fit: contain !important; z-index: 2147483646 !important; background: #000 !important; transform: none !important; }
  html.ytmini:not(.ytmini-s) #movie_player, html.ytmini.ytmini-s #shorts-player {
    position: fixed !important; inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
    z-index: 2147483645 !important; background: #000 !important; }
  html.ytmini:not(.ytmini-s) body *:has(#movie_player), html.ytmini.ytmini-s body *:has(#shorts-player),
  html.ytmini:not(.ytmini-s) #movie_player, html.ytmini.ytmini-s #shorts-player, html.ytmini .html5-video-container {
    clip-path: none !important; transform: none !important; contain: none !important; filter: none !important; will-change: auto !important; }
  /* 쇼츠는 스크롤 상자로 넘기므로 overflow 를 건드리면 다음 쇼츠로 안 넘어감 (fixed 영상은 overflow 에 안 잘림) */
  html.ytmini:not(.ytmini-s) body *:has(#movie_player), html.ytmini:not(.ytmini-s) #movie_player, html.ytmini:not(.ytmini-s) .html5-video-container { overflow: visible !important; }
  html.ytmini .ytp-caption-window-container { visibility: visible !important; z-index: 2147483646 !important; position: absolute !important; inset: 0 !important; pointer-events: none !important; }
  html.ytmini .ytp-caption-window-container * { visibility: visible !important; }`;
  const NF_CSS = `
  html.ytmini, html.ytmini body { overflow: hidden !important; background: #000 !important; }
  html.ytmini body * { visibility: hidden !important; }
  html.ytmini video[data-mini-v] { visibility: visible !important; position: fixed !important; inset: 0 !important; left: 0 !important; top: 0 !important;
    width: 100vw !important; height: 100vh !important; object-fit: contain !important; z-index: 2147483646 !important; background: #000 !important; transform: none !important; }
  html.ytmini [data-mini-a] { overflow: visible !important; clip-path: none !important; transform: none !important; contain: none !important; filter: none !important; will-change: auto !important; }
  html.ytmini .player-timedtext { visibility: visible !important; position: fixed !important; inset: 0 !important; z-index: 2147483646 !important; pointer-events: none !important; }
  html.ytmini .player-timedtext * { visibility: visible !important; }`;

  function applyCss(on) {
    let st = document.getElementById('__ytmini');
    if (on && !st) { st = document.createElement('style'); st.id = '__ytmini'; st.textContent = site === 'netflix' ? NF_CSS : YT_CSS; document.documentElement.appendChild(st); }
    if (!on && st) st.remove();
    document.documentElement.classList.toggle('ytmini', on);
    document.documentElement.classList.toggle('ytmini-s', on && shorts());
    document.querySelectorAll('[data-mini-v],[data-mini-a]').forEach((e) => { e.removeAttribute('data-mini-v'); e.removeAttribute('data-mini-a'); });
    const v = video();
    if (on && v) { v.setAttribute('data-mini-v', ''); for (let e = v.parentElement; e && e !== document.body; e = e.parentElement) e.setAttribute('data-mini-a', ''); }
    window.dispatchEvent(new Event('resize'));
  }
  const aspect = () => { const v = video(); return v && v.videoWidth && v.videoHeight ? v.videoWidth / v.videoHeight : 16 / 9; };

  // MARK: 단추 · 조작 화면 (페이지 CSS 와 안 섞이게 shadow DOM)

  let mini = false;
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = H(`<style>
    *{box-sizing:border-box;font:600 12px "Segoe UI","Malgun Gothic",sans-serif}
    .pipbtn{position:fixed;right:16px;bottom:16px;pointer-events:auto;display:none;align-items:center;gap:6px;border:0;border-radius:9px;padding:7px 12px;
      background:rgba(20,20,24,.88);color:#fff;cursor:pointer;opacity:.55;transition:opacity .15s;box-shadow:0 4px 14px rgba(0,0,0,.35)}
    .pipbtn:hover{opacity:1;background:#e00030}
    .pipbtn svg{width:15px;height:15px}
    .mini{position:fixed;inset:0;pointer-events:auto;display:none;cursor:default}
    .mini .ui{opacity:0;transition:opacity .18s}
    .mini:hover .ui,.mini.show .ui{opacity:1}
    .shade{position:absolute;left:0;right:0;bottom:0;height:64px;background:linear-gradient(transparent,rgba(0,0,0,.7));pointer-events:none}
    .top{position:absolute;top:8px;left:8px;right:8px;display:flex;justify-content:space-between;gap:6px}
    .top button,.ctl button{border:0;background:rgba(0,0,0,.55);color:#fff;width:28px;height:28px;border-radius:7px;display:grid;place-items:center;cursor:pointer;padding:0}
    .top button:hover,.ctl button:hover{background:#e00030}
    .top button svg,.ctl button svg{width:14px;height:14px}
    .ctl{position:absolute;left:8px;right:8px;bottom:8px;display:flex;align-items:center;gap:8px}
    .ctl button{background:transparent;width:26px;height:26px}
    .bar{flex:1;height:14px;display:flex;align-items:center;cursor:pointer}
    .bar i{display:block;height:4px;width:100%;border-radius:2px;background:rgba(255,255,255,.3);position:relative;overflow:hidden}
    .bar b{position:absolute;left:0;top:0;bottom:0;background:#e00030;border-radius:2px}
    .bar:hover i{height:6px}
    .t{color:#fff;font-weight:500;font-size:11px;min-width:76px;text-align:right;font-variant-numeric:tabular-nums;text-shadow:0 1px 2px #000}
    .t.golive{cursor:pointer;text-decoration:underline dotted}
    .vol{width:60px;accent-color:#fff}
    .edge{position:absolute;pointer-events:auto}
    .n{top:0;left:8px;right:8px;height:5px;cursor:ns-resize}.s{bottom:0;left:8px;right:8px;height:5px;cursor:ns-resize}
    .w{left:0;top:8px;bottom:8px;width:5px;cursor:ew-resize}.e{right:0;top:8px;bottom:8px;width:5px;cursor:ew-resize}
    .nw{left:0;top:0;width:9px;height:9px;cursor:nwse-resize}.se{right:0;bottom:0;width:9px;height:9px;cursor:nwse-resize}
    .ne{right:0;top:0;width:9px;height:9px;cursor:nesw-resize}.sw{left:0;bottom:0;width:9px;height:9px;cursor:nesw-resize}
    .msg{position:fixed;left:50%;bottom:70px;transform:translateX(-50%);background:rgba(20,20,24,.92);color:#fff;padding:8px 14px;border-radius:8px;pointer-events:none;display:none}
  </style>
  <button class="pipbtn" title="보던 영상을 항상 위에 뜨는 작은 창으로 (끌어서 옮기고, 가장자리로 크기 조절)">
    <svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><rect x="8" y="8" width="5" height="4" rx=".8" fill="currentColor"/></svg>PIP</button>
  <div class="mini">
    <div class="ui shade"></div>
    <div class="ui top">
      <button data-a="expand" title="원래 창으로 (두 번 누르기 · Esc)"><svg viewBox="0 0 16 16"><path d="M2 6V2h4M14 6V2h-4M2 10v4h4M14 10v4h-4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></button>
      <button data-a="close" title="닫기 (영상 멈춤)"><svg viewBox="0 0 16 16"><path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg></button>
    </div>
    <div class="ui ctl">
      <button data-a="play" title="재생 / 멈춤 (스페이스)"></button>
      <div class="bar" data-a="seek"><i><b></b></i></div>
      <span class="t"></span>
      <button data-a="mute" title="소리 끄기 / 켜기"></button>
      <input class="vol" type="range" min="0" max="100" title="볼륨 (휠 · 쇼츠는 Shift + 휠)">
    </div>
    <div class="edge n" data-r="North"></div><div class="edge s" data-r="South"></div><div class="edge w" data-r="West"></div><div class="edge e" data-r="East"></div>
    <div class="edge nw" data-r="NorthWest"></div><div class="edge ne" data-r="NorthEast"></div><div class="edge sw" data-r="SouthWest"></div><div class="edge se" data-r="SouthEast"></div>
  </div>
  <div class="msg"></div>`);
  const $ = (s) => root.querySelector(s);
  const ICON = {
    play: '<svg viewBox="0 0 16 16"><path d="M4.5 3v10l8.5-5z" fill="currentColor"/></svg>',
    pause: '<svg viewBox="0 0 16 16"><rect x="4" y="3" width="3" height="10" rx=".8" fill="currentColor"/><rect x="9" y="3" width="3" height="10" rx=".8" fill="currentColor"/></svg>',
    vol: '<svg viewBox="0 0 16 16"><path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor"/><path d="M10.5 5.5a3.5 3.5 0 010 5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
    mute: '<svg viewBox="0 0 16 16"><path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor"/><path d="M10.5 6l4 4M14.5 6l-4 4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  };
  function say(t) { const m = $('.msg'); m.textContent = t; m.style.display = 'block'; clearTimeout(say.t); say.t = setTimeout(() => (m.style.display = 'none'), 2200); }
  const fmt = (s) => { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = String(s % 60).padStart(2, '0'); return h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`; };

  let last = null;
  function tick() {
    $('.pipbtn').style.display = !mini && video() ? 'flex' : 'none';
    if (!mini) return;
    const s = P.state();
    last = s;
    if (!s) return;
    $('[data-a=play]').innerHTML = H(s.paused ? ICON.play : ICON.pause);
    $('[data-a=mute]').innerHTML = H(s.muted || s.vol === 0 ? ICON.mute : ICON.vol);
    const len = s.e - s.s;
    // 실시간: 지금 보고 있으면 막대 끝까지 · '● 실시간', 뒤로 돌려 봤으면 얼마나 늦었는지 (누르면 실시간으로)
    $('.bar b').style.width = s.live && s.head ? '100%' : len > 0 ? Math.min(100, ((s.t - s.s) / len) * 100) + '%' : '0';
    $('.t').textContent = !s.live ? `${fmt(s.t)} / ${fmt(s.e)}` : s.head ? '● 실시간' : `실시간 −${fmt(s.e - s.t)}`;
    $('.t').classList.toggle('golive', s.live && !s.head);
    $('.t').title = s.live && !s.head ? '누르면 실시간으로' : '';
    if (document.activeElement !== host && !$('.vol').matches(':active')) $('.vol').value = s.muted ? 0 : s.vol;
  }

  // 도구함이 부름: 들어가기 · 나오기 · 멈춤
  window.__mlEnterPip = () => {
    if (!video()) { say('먼저 영상을 하나 열어 주세요'); return; }
    send('pip-on?ar=' + aspect().toFixed(4));
  };
  window.__mlSetPip = (on) => {
    mini = on;
    applyCss(on);
    $('.mini').style.display = on ? 'block' : 'none';
    if (on) { $('.mini').classList.add('show'); setTimeout(() => $('.mini').classList.remove('show'), 1800); }
    tick();
  };
  window.__mlPause = () => P.pause();

  $('.pipbtn').addEventListener('click', () => window.__mlEnterPip());
  // 작은 창 조작
  const ov = $('.mini');
  let down = null, clickTimer = null;
  ov.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    const r = e.target.closest('[data-r]');
    if (r) { e.preventDefault(); send('resize?d=' + r.dataset.r); return; }
    if (e.target.closest('button,input,.bar')) return;
    down = { x: e.screenX, y: e.screenY, moved: false };
  });
  ov.addEventListener('mousemove', (e) => {
    if (!down || down.moved || !(e.buttons & 1)) return;
    if (Math.abs(e.screenX - down.x) + Math.abs(e.screenY - down.y) > 4) { down.moved = true; send('drag'); }
  });
  ov.addEventListener('mouseup', (e) => {
    if (!down) return;
    const wasDrag = down.moved;
    down = null;
    if (wasDrag || e.target.closest('button,input,.bar,[data-r],.t.golive')) return;
    // 한 번 = 재생/멈춤, 두 번 = 원래 창
    if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; send('pip-off'); return; }
    clickTimer = setTimeout(() => { clickTimer = null; P.toggle(); setTimeout(tick, 120); }, 260);
  });
  ov.addEventListener('click', (e) => {
    const a = e.target.closest('[data-a]')?.dataset.a;
    if (a === 'play') { P.toggle(); setTimeout(tick, 120); }
    if (a === 'mute') { P.mute(); setTimeout(tick, 120); }
    if (a === 'expand') send('pip-off');
    if (e.target.closest('.t.golive')) { P.toLive(); setTimeout(tick, 300); }
    if (a === 'close') { P.pause(); send('pip-close'); }
    if (a === 'seek' && last && last.e > last.s) {
      const r = e.target.closest('.bar').getBoundingClientRect();
      P.seek(last.s + ((e.clientX - r.left) / r.width) * (last.e - last.s));
      setTimeout(tick, 150);
    }
  });
  $('.vol').addEventListener('input', (e) => P.volume(+e.target.value));
  // 휠: 볼륨 — 쇼츠에서는 다음 · 이전 쇼츠 (볼륨은 Shift + 휠)
  let wheelAt = 0, wheelSum = 0;
  function shortsStep(down) {
    const b = document.querySelector(down ? '#navigation-button-down button' : '#navigation-button-up button');
    if (b && !b.disabled) { b.click(); return; }
    // 단추가 없으면 YouTube 쇼츠의 키보드 이동 (↓ · ↑)
    const k = down ? 'ArrowDown' : 'ArrowUp';
    const t = document.querySelector('ytd-shorts') || document.body;
    for (const type of ['keydown', 'keyup']) t.dispatchEvent(new KeyboardEvent(type, { key: k, code: k, keyCode: down ? 40 : 38, which: down ? 40 : 38, bubbles: true }));
  }
  ov.addEventListener('wheel', (e) => {
    e.preventDefault();
    if (location.pathname.startsWith('/shorts') && !e.shiftKey) {
      // 터치패드처럼 잘게 오는 휠은 모아서, 한 번 넘긴 뒤 잠깐은 무시 (한 번에 여러 개 넘어가지 않게)
      const now = Date.now();
      if (now - wheelAt < 450) return;
      wheelSum += e.deltaY;
      if (Math.abs(wheelSum) < 40) return;
      wheelAt = now;
      shortsStep(wheelSum > 0);
      wheelSum = 0;
      return;
    }
    const s = P.state(); if (!s) return;
    P.volume((s.muted ? 0 : s.vol) + ((e.deltaY || e.deltaX) < 0 ? 5 : -5));
    tick();
  }, { passive: false });
  addEventListener('keydown', (e) => {
    if (!mini) return;
    if (e.key === 'Escape') { e.preventDefault(); send('pip-off'); }
    if (e.key === ' ') { e.preventDefault(); e.stopPropagation(); P.toggle(); setTimeout(tick, 120); }
  }, true);

  // 작은 창에서 다른 영상 · 쇼츠로 넘어가면 다시 맞춤
  let lastPath = location.pathname;
  setInterval(() => {
    if (mini && location.pathname !== lastPath) { applyCss(true); send('pip-aspect?ar=' + aspect().toFixed(4)); }
    lastPath = location.pathname;
  }, 800);

  function mount() { document.documentElement.appendChild(host); tick(); setInterval(tick, 500); }
  if (document.documentElement) mount(); else addEventListener('DOMContentLoaded', mount);
})();
