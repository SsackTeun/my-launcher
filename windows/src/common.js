// 모든 창이 같이 쓰는 도우미 (도구함 · 떼어 낸 플레이어 · 가사 창 · 자주 쓰는 앱 막대)
"use strict";

const T = window.__TAURI__;
const invoke = (cmd, args) => (T ? T.core.invoke(cmd, args) : Promise.reject("Tauri 밖에서 열림"));
const win = () => (T ? T.window.getCurrentWindow() : null);
const $ = (s) => document.querySelector(s);
// 화면 오류를 개발 콘솔로 (npx tauri dev)
if (T) {
  addEventListener("error", (e) => invoke("js_log", { msg: `${e.message} @ ${e.filename}:${e.lineno}` }).catch(() => {}));
  addEventListener("unhandledrejection", (e) => invoke("js_log", { msg: "promise: " + (e.reason?.stack || e.reason) }).catch(() => {}));
}
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2200);
}

/// 직접 그린 창 단추 (최소화 · 최대화 · 닫기) — 제목 막대 없는 창들
document.addEventListener("click", (e) => {
  const b = e.target.closest && e.target.closest("[data-win]");
  if (!b || !T) return;
  const w = win();
  if (b.dataset.win === "min") w.minimize();
  if (b.dataset.win === "max") w.toggleMaximize();
  if (b.dataset.win === "close") w.close();
});

/// 다른 창 → 도구함 창에 설정 바꾸기 부탁 (설정 파일은 도구함 창만 씀)
function setConfig(key, value) {
  if (T) T.event.emit("cfg-set", { key, value });
}
/// 설정이 바뀌면 (도구함 창이 저장할 때마다) 다시 읽음
async function readConfig() {
  try { return JSON.parse((await invoke("read_config")) || "{}"); } catch { return {}; }
}
function onConfigChanged(fn) {
  if (T) T.event.listen("config-changed", fn);
}

/// 테마: 기본(어두운 반투명) · 곰(우유색 + 갈색 + 분홍) · 밝게, 배경 그림
async function applyTheme(cfg) {
  const t = cfg.theme || "default";
  document.documentElement.dataset.theme = t;
  // 배경 투명도 (설정 → 모양): 0 이면 테마 기본값
  const BASE = { default: [32, 32, 36, 0.62], light: [246, 246, 248, 0.8], bear: [255, 245, 227, 0.94] };
  const b = BASE[t] || BASE.default;
  const a = cfg.bgOpacity ? Math.max(0.1, Math.min(1, cfg.bgOpacity / 100)) : b[3];
  document.documentElement.style.setProperty("--bg", `rgba(${b[0]}, ${b[1]}, ${b[2]}, ${a})`);
  // 플레이어 창 투명도를 끝(100%)까지 올리면 바탕도 불투명 (html.solid)
  document.documentElement.style.setProperty("--bg-solid", `rgb(${b[0]}, ${b[1]}, ${b[2]})`);
  let img = null;
  if (cfg.themeImage) { try { img = await invoke("theme_image", {}); } catch { /* 없음 */ } }
  document.documentElement.style.setProperty("--bgimg", img ? `url("${img}")` : "none");
  document.documentElement.classList.toggle("has-bgimg", !!img);
  document.documentElement.style.setProperty("--fs", Math.round(13 * (cfg.fontScale || 1) * 10) / 10 + "px");
}

const fmtTime = (s) => {
  if (!isFinite(s) || s < 0) s = 0;
  s = Math.floor(s);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};
const fmtBytes = (b) => (b >= 1 << 30 ? (b / (1 << 30)).toFixed(1) + " GB" : Math.round(b / (1 << 20)) + " MB");

// MARK: 새 버전 알림 (도구함 · 플레이어 · 음악 창 위쪽 띠) — 누르면 받아서 바꿔 끼우고 다시 켬
(() => {
  if (!T || /\/(bar|lyrics)\.html/.test(location.pathname)) return;
  const key = (v) => `updSkip:${v}`;
  function show(u) {
    if (!u || !u.version) return;
    try { if (localStorage.getItem(key(u.version))) return; } catch { /* 없음 */ }
    document.querySelector(".upd-bar")?.remove();
    const b = document.createElement("div");
    b.className = "upd-bar";
    b.innerHTML = `<span>⬆ 도구함 새 버전 <b>${esc(u.version)}</b> <small>(지금 ${esc(u.current)})</small></span>
      <button class="upd-go">업데이트</button><button class="upd-later" title="이 버전은 다시 알리지 않기 (트레이 메뉴에서는 계속 업데이트할 수 있어요)">나중에</button>`;
    if (u.notes) b.title = u.notes;
    b.querySelector(".upd-go").onclick = async (e) => {
      e.target.disabled = true;
      e.target.textContent = "받는 중…";
      try { await invoke("self_update"); } catch (err) { e.target.disabled = false; e.target.textContent = "업데이트"; toast(`업데이트하지 못했어요: ${err}`); }
    };
    b.querySelector(".upd-later").onclick = () => { try { localStorage.setItem(key(u.version), "1"); } catch { /* 없음 */ } T.event.emit("update-hide", {}); };
    document.body.appendChild(b);
  }
  T.event.listen("update-available", (e) => show(e.payload));
  T.event.listen("update-hide", () => document.querySelector(".upd-bar")?.remove());
  T.event.listen("update-none", (e) => { if (document.hasFocus()) toast(e.payload); });
  invoke("update_info").then(show).catch(() => {});
})();

// 가림막 되살리기: 도구함 · 플레이어 창이 켜질 때 (이미 떠 있으면 그대로) — 다시 켜면 잠긴 채로
if (T && ["main", "music"].includes(win().label)) {
  try {
    const cs = JSON.parse(localStorage.getItem("covers") || "{}");
    for (const [id, c] of Object.entries(cs)) if (c && c.w && c.h) invoke("cover_open", { id, x: c.x, y: c.y, w: c.w, h: c.h }).catch(() => {});
    // 영역 비추기도 (원본 창은 같은 프로그램 · 같은 종류 창으로 다시 찾음)
    const ms = JSON.parse(localStorage.getItem("mirrors") || "{}");
    for (const [id, m] of Object.entries(ms)) {
      if (m && m.cls && m.w && m.h) invoke("mirror_restore", { id, cls: m.cls, title: m.title || "", exe: m.exe || "", sx: m.sx, sy: m.sy, sw: m.sw, sh: m.sh, x: m.x, y: m.y, w: m.w, h: m.h }).catch(() => {});
    }
  } catch { /* 없음 */ }
}
