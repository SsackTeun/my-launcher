// 영역 비추기 창 (mirror-<id>): 원본 · 영역 · 자리 · 크기 · 투명도를 localStorage 'mirrors' 에 기억
// 실제 그림은 Rust(mirror.rs)가 DWM 썸네일로 — 여기서는 조작 줄 · 잠금 · 자리 기억, 크기가 바뀌면 다시 그리기만
"use strict";
(() => {
  const T = window.__TAURI__;
  if (!T) { document.body.classList.add("edit"); return; } // 미리 보기 (브라우저)
  const w = T.window.getCurrentWindow();
  const id = w.label.replace(/^mirror-/, "");
  const invoke = T.core.invoke;
  const all = () => { try { return JSON.parse(localStorage.getItem("mirrors") || "{}"); } catch { return {}; } };
  const me = Object.assign({ a: 100 }, all()[id] || {});
  function save(patch) {
    Object.assign(me, patch);
    const ms = all();
    ms[id] = Object.assign(ms[id] || {}, me);
    try { localStorage.setItem("mirrors", JSON.stringify(ms)); } catch { /* 없음 */ }
  }
  let edit = false;

  // 다시 그리기: 잠금 풀림이면 위쪽 조작 줄 자리는 비움 · 원본이 없으면 '찾는 중'
  async function draw() {
    const top = edit ? Math.round(30 * devicePixelRatio) : 0;
    const ok = await invoke("mirror_update", { id, top, alpha: Math.round(me.a / 100 * 255) }).catch(() => false);
    document.body.classList.toggle("lost", !ok);
  }
  function paintAlpha() {
    document.getElementById("a").value = me.a;
    document.getElementById("av").textContent = me.a >= 100 ? "불투명" : me.a + "%";
  }
  document.getElementById("a").oninput = (e) => { save({ a: +e.target.value }); paintAlpha(); draw(); };
  paintAlpha();

  // 원본 정보 기억 (다시 켰을 때 같은 창을 찾게)
  invoke("mirror_info", { id }).then((m) => {
    if (!m) return;
    save({ cls: m.cls, title: m.title, exe: m.exe, sx: m.sx, sy: m.sy, sw: m.sw, sh: m.sh });
    const exe = (m.exe || "").split(/[\\/]/).pop();
    document.getElementById("name").textContent = m.title || exe || "비추기";
    document.getElementById("name").title = `${m.title} (${exe})`;
  }).catch(() => {});

  // 잠금 · 숨기기 (가림막과 같이)
  async function apply(st) {
    edit = !st.locked;
    document.body.classList.toggle("edit", edit);
    await w.setIgnoreCursorEvents(!!st.locked).catch(() => {});
    if (st.hidden) await w.hide().catch(() => {}); else await w.show().catch(() => {});
    draw();
  }
  invoke("cover_state").then(apply).catch(() => {});
  T.event.listen("cover-state", (e) => apply(e.payload));
  document.getElementById("lock").onclick = () => invoke("cover_set", { locked: true }).catch(() => {});
  document.getElementById("del").onclick = () => {
    const ms = all(); delete ms[id];
    try { localStorage.setItem("mirrors", JSON.stringify(ms)); } catch { /* 없음 */ }
    invoke("mirror_close", { id }).catch(() => {});
  };
  document.getElementById("grip").onmousedown = (e) => { e.preventDefault(); w.startResizeDragging("SouthEast").catch(() => {}); };

  // 자리 · 크기 기억 (물리 픽셀), 크기가 바뀌면 다시 그리기
  let t = 0;
  async function remember() {
    try {
      const p = await w.outerPosition(), s = await w.innerSize();
      save({ x: p.x, y: p.y, w: s.width, h: s.height });
    } catch { /* 없음 */ }
  }
  w.onMoved(() => { clearTimeout(t); t = setTimeout(remember, 300); });
  w.onResized(() => { draw(); clearTimeout(t); t = setTimeout(remember, 300); });
  remember();
  // 원본 창이 다시 열리거나 바뀌면 다시 붙도록 가끔
  setInterval(draw, 1500);
  draw();
})();
