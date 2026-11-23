// 떼어 낸 플레이어 · 떼어 낸 가사 줄 · 전체 가사 창 (body 의 data-view 로 나눔)
"use strict";

(async function () {
  const VIEW = document.body.dataset.view; // player · line · lyrics
  const el = $("#view");
  let cfg = await readConfig();
  await applyTheme(cfg);
  Player.start(cfg);
  onConfigChanged(async () => { cfg = await readConfig(); applyTheme(cfg); Player.setCfg(cfg); });

  if (VIEW === "player") {
    Player.on((tick) => (tick ? Player.tickPlayer(el) : Player.renderPlayer(el, { detached: true, lyricsOn: false })));
    Player.bindPlayer(el, { lyrics: () => Player.openLyricsWindow() });
    // 재생기 단추 (YouTube Music · YouTube · Netflix) — 창이 작아서 오른쪽 클릭은 Windows 기본 메뉴
    Sites.mount($("#sites"));
  } else if (VIEW === "line") {
    Player.on(() => Player.renderLine(el, { detached: true }));
    Player.bindLine(el);
  } else {
    Player.on(() => Player.renderFull(el));
    Player.bindFull(el);
    // 가사 창의 글자 크기 · 번역 · 발음 바꾸기
    const bar = $("#lyTools");
    const drawTools = () => {
      bar.innerHTML = `<button class="icon sm" data-a="smaller" title="글자 작게">A−</button><button class="icon sm" data-a="bigger" title="글자 크게">A+</button>
        <select data-a="trans" title="번역">${LANGS.map(([c, n]) => `<option value="${c}" ${c === (cfg.transLang || "") ? "selected" : ""}>${esc(n)}</option>`).join("")}</select>
        <select data-a="pron" title="발음">${[["off", "발음 끔"], ["hangul", "한글 발음"], ["roman", "로마자"]].map(([c, n]) => `<option value="${c}" ${c === (cfg.pron || "off") ? "selected" : ""}>${n}</option>`).join("")}</select>`;
    };
    drawTools();
    onConfigChanged(() => setTimeout(drawTools, 50));
    bar.addEventListener("click", (e) => {
      const a = e.target.closest("[data-a]")?.dataset.a;
      if (a === "smaller" || a === "bigger") setConfig("lyricsFont", Math.max(10, Math.min(32, (cfg.lyricsFont || 15) + (a === "bigger" ? 1 : -1))));
    });
    bar.addEventListener("change", (e) => {
      if (e.target.dataset.a === "trans") setConfig("transLang", e.target.value);
      if (e.target.dataset.a === "pron") setConfig("pron", e.target.value);
    });
  }

  // 닫기: 떼어 낸 창은 도구함 창으로 되돌림
  $("#close")?.addEventListener("click", () => {
    if (VIEW === "player") setConfig("detachPlayer", false);
    else if (VIEW === "line") setConfig("detachLyrics", false);
    else win().close();
  });

  // 위치 기억
  const w = win();
  let t = null;
  w.onMoved(async ({ payload }) => {
    clearTimeout(t);
    t = setTimeout(async () => {
      const f = await w.scaleFactor();
      const p = payload.toLogical ? payload.toLogical(f) : { x: payload.x / f, y: payload.y / f };
      if (VIEW !== "lyrics") setConfig(VIEW + "Pos", [Math.round(p.x), Math.round(p.y)]);
    }, 500);
  });
  document.addEventListener("contextmenu", (e) => e.preventDefault());
})();
