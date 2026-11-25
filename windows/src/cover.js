// 가림막 창 (cover-<id>): 자리 · 크기 · 색 · 투명도를 localStorage 'covers' 에 기억, 잠금 · 숨기기는 도구함(Rust)이 모든 가림막에 같이
"use strict";
(() => {
  const T = window.__TAURI__;
  const w = T?.window.getCurrentWindow();
  const id = w ? w.label.replace(/^cover-/, "") : "preview";
  const COLORS = [["검정", "0,0,0"], ["짙은 회색", "30,31,34"], ["회색", "70,72,78"], ["남색", "24,32,58"], ["흰색", "242,242,242"]];
  const all = () => { try { return JSON.parse(localStorage.getItem("covers") || "{}"); } catch { return {}; } };
  const me = Object.assign({ c: "30,31,34", a: 100 }, all()[id] || {});
  function save(patch) {
    Object.assign(me, patch);
    const cs = all();
    cs[id] = Object.assign(cs[id] || {}, me);
    try { localStorage.setItem("covers", JSON.stringify(cs)); } catch { /* 없음 */ }
  }

  // 모양: 색 · 투명도 (100 = 불투명)
  function paint() {
    document.getElementById("box").style.setProperty("--c", `rgba(${me.c}, ${me.a / 100})`);
    document.getElementById("a").value = me.a;
    document.getElementById("av").textContent = me.a >= 100 ? "불투명" : me.a + "%";
    document.querySelectorAll(".sw").forEach((b) => b.classList.toggle("on", b.dataset.c === me.c));
  }
  document.getElementById("sws").innerHTML = COLORS.map(([n, c]) => `<button class="sw" data-c="${c}" title="${n}" style="background: rgb(${c})"></button>`).join(" ");
  document.getElementById("sws").onclick = (e) => { const b = e.target.closest(".sw"); if (b) { save({ c: b.dataset.c }); paint(); } };
  document.getElementById("a").oninput = (e) => { save({ a: +e.target.value }); paint(); };
  paint();

  if (!w) { document.body.classList.add("edit"); return; } // 미리 보기 (브라우저)

  // 잠금 · 숨기기 (모든 가림막 같이)
  async function apply(st) {
    document.body.classList.toggle("edit", !st.locked);
    await w.setIgnoreCursorEvents(!!st.locked).catch(() => {});
    if (st.hidden) await w.hide().catch(() => {}); else await w.show().catch(() => {});
  }
  T.core.invoke("cover_state").then(apply).catch(() => {});
  T.event.listen("cover-state", (e) => apply(e.payload));
  document.getElementById("lock").onclick = () => T.core.invoke("cover_set", { locked: true }).catch(() => {});
  document.getElementById("del").onclick = () => {
    const cs = all(); delete cs[id];
    try { localStorage.setItem("covers", JSON.stringify(cs)); } catch { /* 없음 */ }
    T.core.invoke("close_window", { label: w.label }).catch(() => {});
  };

  // 크기: 오른쪽 아래 손잡이
  document.getElementById("grip").onmousedown = (e) => { e.preventDefault(); w.startResizeDragging("SouthEast").catch(() => {}); };

  // 자리 · 크기 기억 (옮기거나 크기를 바꾸면 잠깐 뒤에)
  let t = 0;
  async function remember() {
    try {
      const f = await w.scaleFactor();
      const p = (await w.outerPosition()).toLogical(f), s = (await w.innerSize()).toLogical(f);
      save({ x: Math.round(p.x), y: Math.round(p.y), w: Math.round(s.width), h: Math.round(s.height) });
    } catch { /* 없음 */ }
  }
  const later = () => { clearTimeout(t); t = setTimeout(remember, 300); };
  w.onMoved(later);
  w.onResized(later);
  remember();
})();
