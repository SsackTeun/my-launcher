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
