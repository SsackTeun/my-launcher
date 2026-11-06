// 도구함 (Windows) 화면 — 앱 목록 · 카테고리 · 실행 중 · 개발자 앱 · 위젯 모드
"use strict";

const T = window.__TAURI__;
const invoke = (cmd, args) => (T ? T.core.invoke(cmd, args) : Promise.reject("Tauri 밖에서 열림"));
const win = () => (T ? T.window.getCurrentWindow() : null);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// 아이콘 (SVG)
const I = {
  lock: '<svg viewBox="0 0 16 16"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="currentColor"/><path d="M5 7V5a3 3 0 016 0v2" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
  unlock: '<svg viewBox="0 0 16 16"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M5 7V5a3 3 0 015.6-1.5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>',
  up: '<svg viewBox="0 0 16 16"><path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  down: '<svg viewBox="0 0 16 16"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  folder: '<svg viewBox="0 0 16 16"><path d="M1.5 4.5a1 1 0 011-1H6l1.5 1.5h6a1 1 0 011 1v6.5a1 1 0 01-1 1h-11a1 1 0 01-1-1z" fill="currentColor"/></svg>',
  sidebar: '<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="13" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6 2.5v11" stroke="currentColor" stroke-width="1.4"/></svg>',
  grid: '<svg viewBox="0 0 16 16"><rect x="2" y="2" width="5" height="5" rx="1" fill="currentColor"/><rect x="9" y="2" width="5" height="5" rx="1" fill="currentColor"/><rect x="2" y="9" width="5" height="5" rx="1" fill="currentColor"/><rect x="9" y="9" width="5" height="5" rx="1" fill="currentColor"/></svg>',
  list: '<svg viewBox="0 0 16 16"><circle cx="3" cy="4" r="1.2" fill="currentColor"/><circle cx="3" cy="8" r="1.2" fill="currentColor"/><circle cx="3" cy="12" r="1.2" fill="currentColor"/><path d="M6 4h8M6 8h8M6 12h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
  power: '<svg viewBox="0 0 16 16"><path d="M8 2v6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><path d="M4.6 4.4a5 5 0 106.8 0" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  refresh: '<svg viewBox="0 0 16 16"><path d="M13 8a5 5 0 11-1.5-3.5M13 2.5v3h-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  download: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.5" fill="currentColor"/><path d="M8 4.5v5M5.5 7.5L8 10l2.5-2.5" fill="none" stroke="#202024" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  plus: '<svg viewBox="0 0 16 16"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
  x: '<svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="7" fill="currentColor"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="#202024" stroke-width="1.6" stroke-linecap="round"/></svg>',
};

// MARK: 상태

const DEFAULT = {
  cats: [{ name: "기본", items: [] }],
  view: "grid",          // grid · list
  sidebar: true,         // 왼쪽 세로 목록
  tab: 0,                // 0 전체 · 1 실행 중 · 2 개발자 앱
  sel: [0, 0, 0],        // 탭마다 왼쪽 목록에서 고른 항목
  iconSize: 40,
  widget: false,
  level: "bottom",       // bottom 바탕화면에 붙이기 · normal · top 항상 위
  locked: false,
  collapsed: false,
  crossCategory: true,   // 끝까지 스크롤하면 다음 카테고리로
};
let S = structuredClone(DEFAULT);
let installed = [];      // 시작 메뉴 앱
let installedLoaded = false;
let running = [];        // 실행 중인 앱
let query = "";
let focusId = null;      // 스크롤로 옮겨 다니는 강조
let devCatalog = [];     // 개발자 앱 목록 (apps.json 에서 windows 정보가 있는 것)
let devLatest = {};      // 폴더 → { version, url }
let devStatus = {};      // 폴더 → "받는 중…"
let expandedH = null;    // 접기 전 창 높이
const icons = new Map(); // 경로 → data URL

let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => invoke("write_config", { json: JSON.stringify(S) }).catch(() => {}), 250);
}

// MARK: 도우미

const norm = (p) => String(p || "").toLowerCase();
function runningOf(item) {
  const t = norm(item.target);
  return t ? running.find((r) => norm(r.exe) === t) : null;
}
function inLauncher(target) {
  const t = norm(target);
  return S.cats.some((c) => c.items.some((i) => norm(i.target) === t || norm(i.id) === t));
}
function locate(id) {
  for (let c = 0; c < S.cats.length; c++) {
    const i = S.cats[c].items.findIndex((x) => x.id === id);
    if (i >= 0) return [c, i];
  }
  return null;
}
function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 2200);
}

async function loadIcon(img) {
  const p = img.dataset.icon;
  if (!p) return;
  if (icons.has(p)) { img.src = icons.get(p); return; }
  try {
    const b64 = await invoke("icon", { path: p });
    const url = b64 ? `data:image/png;base64,${b64}` : "";
    icons.set(p, url);
    if (url) img.src = url;
  } catch { /* 아이콘 없음 */ }
}

async function loadInstalled() {
  if (installedLoaded) return installed;
  try { installed = await invoke("installed_apps"); } catch { installed = []; }
  installedLoaded = true;
  return installed;
}

// MARK: 실행 · 종료

async function launchItem(item) {
  const r = runningOf(item);
  if (r) {
    // 이미 켜져 있으면 그 창을 앞으로 (최소화돼 있으면 되살림)
    if (await invoke("focus_app", { pid: r.pid }).catch(() => false)) return;
  }
  invoke("launch", { path: item.id }).catch((e) => toast(String(e)));
}

async function quitApp(r, force) {
  await invoke("quit_app", { pid: r.pid, force }).catch(() => {});
  setTimeout(pollRunning, 600);
}

// MARK: 화면에 보여 줄 묶음

function sections() {
  const q = query.trim().toLowerCase();
  if (q) {
    const mine = S.cats.flatMap((c) => c.items).filter((i) => i.name.toLowerCase().includes(q));
    const others = installed.filter((a) => a.name.toLowerCase().includes(q) && !inLauncher(a.target || a.id)).slice(0, 40);
    const out = [{ title: "도구함에서", cat: null, items: mine }];
    if (others.length) out.push({ title: "설치된 앱", cat: null, items: others, installed: true });
    return out;
  }
  if (S.tab === 1) {
    const mine = S.cats.flatMap((c) => c.items).filter((i) => runningOf(i));
    const seen = new Set(mine.map((i) => norm(i.target)));
    const others = running.filter((r) => !seen.has(norm(r.exe))).map((r) => ({ id: r.exe, name: r.name, target: r.exe, other: true }));
    return [{ title: "도구함 앱", cat: null, items: dedupe(mine) }, { title: "다른 앱", cat: null, items: others }];
  }
  if (S.tab === 2) {
    return [{ title: "GitHub 앱", cat: null, items: devCatalog.map((a) => ({ id: "dev:" + a.folder, name: a.name, dev: a })) }];
  }
  return S.cats.map((c, i) => ({ title: c.name, cat: i, items: c.items }));
}
function dedupe(items) {
  const seen = new Set();
  return items.filter((i) => { const k = norm(i.target); if (seen.has(k)) return false; seen.add(k); return true; });
}

// MARK: 그리기

function render() {
  document.body.classList.toggle("widget", S.widget);
  document.body.classList.toggle("locked", S.locked);
  document.body.classList.toggle("collapsed", S.collapsed && !query);
  document.documentElement.style.setProperty("--icon", S.iconSize + "px");
  renderTop();
  renderTabs();
  const secs = sections();
  const searching = !!query.trim();
  const sideMode = S.sidebar && !searching && (S.tab !== 0 || S.cats.length > 1);
  document.body.classList.toggle("sidebar", sideMode);
  let sel = S.sel[S.tab] ?? 0;
  if (sel >= secs.length) sel = S.sel[S.tab] = 0;
  renderSide(sideMode ? secs : [], sel);
  renderList(sideMode ? [secs[sel]].filter(Boolean) : secs, !sideMode && secs.length > 1);
}

function renderTop() {
  $("#lockBtn").innerHTML = S.locked ? I.lock : I.unlock;
  $("#lockBtn").classList.toggle("on", S.locked);
  $("#lockBtn").title = S.locked ? "창 위치 고정됨 — 누르면 풀려요" : "누르면 창 위치를 고정해요";
  $("#collapseBtn").innerHTML = S.collapsed ? I.down : I.up;
  $("#collapseBtn").title = S.collapsed ? "앱 목록 펼치기" : "앱 목록 접기";
  $("#explorerBtn").innerHTML = I.folder;
  $("#grip").toggleAttribute("data-tauri-drag-region", S.widget && !S.locked);
  $("#grip").title = S.locked ? "위치 고정됨 — 🔒 를 눌러 풀 수 있어요" : "잡고 끌어서 옮기기";
}

function renderTabs() {
  const ups = devCatalog.filter((a) => hasUpdate(a)).length;
  const labels = ["전체", `실행 중 ${running.length}`, ups ? `개발자 앱 ●${ups}` : "개발자 앱"];
  $("#seg").innerHTML = labels.map((l, i) => `<button data-tab="${i}" class="${i === S.tab ? "on" : ""}">${esc(l)}</button>`).join("");
  const tools = [];
  if (S.tab === 1) tools.push(`<button class="icon" data-tool="quitall" title="모두 종료 (도구함 제외)">${I.power}</button>`);
  if (S.tab === 2) {
    if (ups) tools.push(`<button class="icon on" style="color:var(--orange)" data-tool="updateall" title="모두 업데이트">${I.download}</button>`);
    tools.push(`<button class="icon" data-tool="devrefresh" title="새로 고침">${I.refresh}</button>`);
  }
  if (S.tab === 0) tools.push(`<button class="icon" data-tool="add" title="앱 추가">${I.plus}</button>`);
  tools.push(`<button class="icon ${S.sidebar ? "on" : ""}" data-tool="sidebar" title="${S.sidebar ? "왼쪽 목록 켜짐 — 누르면 끄고 모두 펼쳐 보기" : "왼쪽 목록으로 보기"}">${I.sidebar}</button>`);
  tools.push(`<button class="icon" data-tool="view" title="${S.view === "list" ? "아이콘 격자로 보기" : "세로 목록으로 보기"}">${S.view === "list" ? I.grid : I.list}</button>`);
  $("#tools").innerHTML = tools.join("");
}

function renderSide(secs, sel) {
  $("#side").innerHTML = secs.map((s, i) =>
    `<div class="cat ${i === sel ? "on" : ""}" data-side="${i}" ${s.cat != null ? `data-cat="${s.cat}" draggable="true"` : ""}>
       <span class="t">${esc(s.title)}</span><span class="n">${s.items.length}</span></div>`).join("");
}

function itemHTML(item, ctx) {
  const r = item.dev ? null : (item.other ? running.find((x) => norm(x.exe) === norm(item.target)) : runningOf(item));
  const iconPath = item.dev ? (devPath(item.dev) || "") : (item.id || "");
  const badge = item.dev ? devBadge(item.dev) : null;
  const focus = item.id === focusId ? " focus" : "";
  const missing = item.dev && !devPath(item.dev) ? " missing" : "";
  const quit = S.tab === 1 && r && !query ? `<button class="quit" data-quit="${r.pid}" title="종료 · Shift 누르고 누르면 강제 종료">${I.x}</button>` : "";
  const attrs = `data-id="${esc(item.id)}" data-cat="${ctx.cat ?? ""}" ${ctx.cat != null ? 'draggable="true"' : ""}`;
  const img = `<img data-icon="${esc(iconPath)}" alt="">`;
  const badgeHTML = badge ? `<span class="badge ${badge === "업데이트" ? "update" : ""}">${esc(badge)}</span>` : "";
  const dot = r ? '<span class="dot"></span>' : "";
  if (S.view === "list") return `<div class="row${focus}${missing}" ${attrs}>${img}<span class="name">${esc(item.name)}</span>${badgeHTML}${quit}${dot}</div>`;
  return `<div class="tile${focus}${missing}" ${attrs}>${img}<span class="name">${esc(item.name)}</span>${badgeHTML}${quit}${dot}</div>`;
}

let visible = []; // 지금 보이는 앱 (스크롤 강조 이동용)
function renderList(secs, headers) {
  visible = [];
  const html = secs.map((s) => {
    const body = s.items.length
      ? `<div class="${S.view === "list" ? "rows" : "grid"}" data-sec-cat="${s.cat ?? ""}">${s.items.map((i) => { visible.push({ item: i, installed: !!s.installed }); return itemHTML(i, s); }).join("")}</div>`
      : `<div class="hint" data-sec-cat="${s.cat ?? ""}">${query ? `‘${esc(query)}’ 와 맞는 앱이 없어요` : S.tab === 1 ? `실행 중인 ${esc(s.title)}이 없어요` : S.tab === 2 ? "목록이 비어 있어요" : "비어 있음 — ＋ 로 앱을 추가하거나 다른 카테고리에서 끌어다 놓으세요"}</div>`;
    return (headers ? `<div class="head" ${s.cat != null ? `data-cat="${s.cat}" draggable="true"` : ""}>${esc(s.title)} <span class="n">${s.items.length}</span></div>` : "") + body;
  }).join("");
  $("#list").innerHTML = html;
  $("#list").querySelectorAll("img[data-icon]").forEach(loadIcon);
}

// MARK: 개발자 앱

const CATALOG = "https://raw.githubusercontent.com/SsackTeun/my-launcher/main/apps.json";
let devLoadedAt = 0;
async function loadDev(force) {
  if (!force && Date.now() - devLoadedAt < 10 * 60 * 1000) return;
  devLoadedAt = Date.now();
  try {
    const list = await (await fetch(CATALOG, { cache: "no-store" })).json();
    devCatalog = list.filter((a) => a.windows).map((a) => ({ name: a.name, summary: a.summary, ...a.windows }));
  } catch { /* 인터넷 안 됨 */ }
  for (const a of devCatalog) {
    try {
      const rels = await (await fetch(`https://api.github.com/repos/${a.repo}/releases?per_page=20`)).json();
      const rel = rels.find((r) => (r.assets || []).some((x) => x.name === a.asset));
      if (rel) {
        const asset = rel.assets.find((x) => x.name === a.asset);
        devLatest[a.folder] = { version: rel.tag_name.replace(/^(win-)?v/, ""), url: asset.browser_download_url };
      }
    } catch { /* 건너뜀 */ }
    a.installedVersion = await invoke("dev_app_version", { folder: a.folder }).catch(() => null);
    a.path = await invoke("dev_app_path", { folder: a.folder, exe: a.exe }).catch(() => null);
  }
  render();
}
const devPath = (a) => a.path || null;
function newer(x, y) {
  const a = String(x).split(".").map(Number), b = String(y).split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) { if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0); }
  return false;
}
function hasUpdate(a) { const l = devLatest[a.folder]; return !!(l && a.installedVersion && newer(l.version, a.installedVersion)); }
function devBadge(a) {
  if (devStatus[a.folder]) return devStatus[a.folder];
  if (!a.path) return devLatest[a.folder] ? "받기" : "준비 중";
  if (hasUpdate(a)) return "업데이트";
  return null;
}
async function installDev(a) {
  const l = devLatest[a.folder];
  if (!l) { toast("아직 Windows 용 파일이 올라와 있지 않아요"); return; }
  devStatus[a.folder] = "받는 중…"; render();
  try {
    const path = await invoke("install_dev_app", { url: l.url, folder: a.folder, exe: a.exe });
    a.path = path;
    a.installedVersion = await invoke("dev_app_version", { folder: a.folder }).catch(() => l.version);
    delete devStatus[a.folder]; render();
    invoke("launch", { path });
  } catch (e) {
    delete devStatus[a.folder]; render();
    toast(`받지 못했어요: ${e}`);
  }
}

// MARK: 실행 중 (2초마다)

let lastRunSig = "";
async function pollRunning() {
  try { running = await invoke("running_apps"); } catch { running = []; }
  const sig = running.map((r) => r.pid + r.exe).join("|");
  if (sig !== lastRunSig) { lastRunSig = sig; if (!menuOpen()) render(); }
}

// MARK: 우클릭 메뉴

const menuEl = $("#menu");
const menuOpen = () => !menuEl.hidden;
function closeMenu() { menuEl.hidden = true; }
function showMenu(x, y, items) {
  const draw = (list, back) => {
    menuEl.innerHTML = (back ? '<div class="it" data-back="1">‹ 뒤로</div><div class="sep"></div>' : "") + list.map((it, i) => {
      if (it === "-") return '<div class="sep"></div>';
      if (it.label && it.header) return `<div class="lab">${esc(it.label)}</div>`;
      return `<div class="it ${it.disabled ? "off" : ""}" data-i="${i}"><span class="ck">${it.checked ? "✓" : ""}</span>${esc(it.label)}${it.children ? '<span class="more">›</span>' : ""}</div>`;
    }).join("");
    menuEl.onclick = (e) => {
      const el = e.target.closest(".it");
      if (!el) return;
      if (el.dataset.back) { draw(items, false); return; }
      const it = list[+el.dataset.i];
      if (it.children) { draw(it.children, true); return; }
      closeMenu();
      it.action?.();
    };
  };
  draw(items, false);
  menuEl.hidden = false;
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.min(x, innerWidth - r.width - 6) + "px";
  menuEl.style.top = Math.min(y, innerHeight - r.height - 6) + "px";
}
document.addEventListener("mousedown", (e) => { if (menuOpen() && !menuEl.contains(e.target)) closeMenu(); });

function moveToMenu(id) {
  const here = locate(id)?.[0];
  return [...S.cats.map((c, ci) => ({ label: c.name, checked: ci === here, action: () => moveItem(id, ci, S.cats[ci].items.length) })),
    "-", { label: "새 카테고리…", action: async () => { const n = await ask("새 카테고리 이름"); if (n) { S.cats.push({ name: n, items: [] }); moveItem(id, S.cats.length - 1, 0); } } }];
}
function addToMenu(app) {
  return S.cats.map((c, ci) => ({ label: c.name, action: () => { S.cats[ci].items.push({ id: app.id, name: app.name, target: app.target }); save(); render(); toast(`‘${app.name}’ 을 ${c.name} 에 넣었어요`); } }));
}

function itemMenu(item, installedOnly) {
  if (item.dev) {
    const a = item.dev;
    return [
      a.path ? { label: "실행", action: () => invoke("launch", { path: a.path }) } : null,
      { label: !a.path ? "받기 (설치)" : hasUpdate(a) ? `업데이트 → ${devLatest[a.folder]?.version}` : "다시 받기", action: () => installDev(a) },
      "-",
      { label: "GitHub 에서 보기", action: () => invoke("launch", { path: `https://github.com/${a.repo}` }) },
    ].filter(Boolean);
  }
  const r = item.other ? running.find((x) => norm(x.exe) === norm(item.target)) : runningOf(item);
  const mine = !!locate(item.id);
  const out = [{ label: r ? "앞으로 가져오기" : "실행", action: () => (item.other ? invoke("focus_app", { pid: r.pid }) : launchItem(item)) }];
  if (installedOnly || item.other) out.push({ label: "도구함에 넣기", children: addToMenu(item) });
  if (mine) {
    out.push("-", { label: "카테고리 옮기기", children: moveToMenu(item.id) });
    const [c, i] = locate(item.id);
    out.push({ label: "앞으로 옮기기", disabled: i === 0, action: () => moveItem(item.id, c, i - 1) });
    out.push({ label: "뒤로 옮기기", disabled: i === S.cats[c].items.length - 1, action: () => moveItem(item.id, c, i + 2) });
  }
  out.push("-", { label: "파일 위치 열기", action: () => invoke("reveal", { path: item.id }) });
  if (r) out.push("-", { label: "종료", action: () => quitApp(r, false) }, { label: "강제 종료", action: () => quitApp(r, true) });
  if (mine) out.push("-", { label: "도구함에서 빼기", action: () => { const [c, i] = locate(item.id); S.cats[c].items.splice(i, 1); save(); render(); } });
  return out;
}

function catMenu(ci) {
  return [
    { label: "여기에 앱 추가…", action: () => addDialog(ci) },
    { label: "이름 바꾸기…", action: async () => { const n = await ask("카테고리 이름 바꾸기", S.cats[ci].name); if (n) { S.cats[ci].name = n; save(); render(); } } },
    "-",
    { label: "위로 옮기기", disabled: ci === 0, action: () => moveCat(ci, ci - 1) },
    { label: "아래로 옮기기", disabled: ci === S.cats.length - 1, action: () => moveCat(ci, ci + 2) },
    "-",
    { label: "카테고리 삭제…", disabled: S.cats.length < 2, action: () => deleteCat(ci) },
  ];
}

function bgMenu() {
  return [
    { label: "앱 추가…", action: () => addDialog(S.sel[0] ?? 0) },
    { label: "새 카테고리…", action: async () => { const n = await ask("새 카테고리 이름"); if (n) { S.cats.push({ name: n, items: [] }); save(); render(); } } },
    "-",
    { label: S.widget ? "위젯 모드 끄기 (일반 창으로)" : "위젯 모드로 바꾸기", action: () => setWidget(!S.widget) },
    ...(S.widget ? [
      { label: "바탕화면에 붙이기 (다른 창 뒤)", checked: S.level === "bottom", action: () => setLevel("bottom") },
      { label: "일반 창처럼", checked: S.level === "normal", action: () => setLevel("normal") },
      { label: "항상 위에", checked: S.level === "top", action: () => setLevel("top") },
    ] : []),
    { label: "위치 고정", checked: S.locked, action: () => { S.locked = !S.locked; save(); render(); } },
    "-",
    { label: "아이콘 크기", children: [24, 32, 40, 56, 72].map((n) => ({ label: `${n}px`, checked: S.iconSize === n, action: () => { S.iconSize = n; save(); render(); } })) },
    { label: "끝까지 스크롤하면 다음 카테고리로", checked: S.crossCategory, action: () => { S.crossCategory = !S.crossCategory; save(); } },
  ];
}

// MARK: 카테고리 · 순서

function moveItem(id, toCat, toIndex) {
  const at = locate(id);
  if (!at) return;
  const [c, i] = at;
  let dest = toIndex;
  if (c === toCat && i < dest) dest--;
  const [it] = S.cats[c].items.splice(i, 1);
  S.cats[toCat].items.splice(Math.max(0, Math.min(dest, S.cats[toCat].items.length)), 0, it);
  save(); render();
}
function moveCat(from, to) {
  if (to === from || to === from + 1) return;
  const selName = S.cats[S.sel[0]]?.name;
  const [c] = S.cats.splice(from, 1);
  S.cats.splice(to > from ? to - 1 : to, 0, c);
  const ni = S.cats.findIndex((x) => x.name === selName);
  if (ni >= 0) S.sel[0] = ni;
  save(); render();
}
async function deleteCat(ci) {
  const dest = ci === 0 ? 1 : ci - 1;
  if (S.cats[ci].items.length && !(await confirmBox(`‘${S.cats[ci].name}’ 카테고리를 삭제할까요?`, `안의 앱 ${S.cats[ci].items.length}개는 ‘${S.cats[dest].name}’ 로 옮겨져요.`))) return;
  S.cats[dest].items.push(...S.cats[ci].items);
  S.cats.splice(ci, 1);
  S.sel[0] = Math.min(S.sel[0], S.cats.length - 1);
  save(); render();
}

// MARK: 대화 상자

const modal = $("#modal");
function ask(title, value = "") {
  return new Promise((done) => {
    modal.innerHTML = `<div class="box"><h3>${esc(title)}</h3><input type="text" id="askIn" value="${esc(value)}" placeholder="예: 업무, 개인, 개발"><div class="btns"><button data-r="0">취소</button><button class="primary" data-r="1">확인</button></div></div>`;
    modal.hidden = false;
    const inp = $("#askIn");
    inp.focus(); inp.select();
    const finish = (ok) => { modal.hidden = true; done(ok ? inp.value.trim() || null : null); };
    modal.onclick = (e) => { const b = e.target.closest("[data-r]"); if (b) finish(b.dataset.r === "1"); else if (e.target === modal) finish(false); };
    inp.onkeydown = (e) => { if (e.key === "Enter") finish(true); if (e.key === "Escape") finish(false); };
  });
}
function confirmBox(title, body) {
  return new Promise((done) => {
    modal.innerHTML = `<div class="box"><h3>${esc(title)}</h3><p>${esc(body)}</p><div class="btns"><button data-r="0">취소</button><button class="primary" data-r="1">확인</button></div></div>`;
    modal.hidden = false;
    modal.onclick = (e) => { const b = e.target.closest("[data-r]"); if (b || e.target === modal) { modal.hidden = true; done(b?.dataset.r === "1"); } };
  });
}
async function addDialog(ci) {
  ci = Math.min(ci, S.cats.length - 1);
  modal.innerHTML = `<div class="box"><h3>‘${esc(S.cats[ci].name)}’ 에 넣을 앱</h3><input type="search" id="addQ" placeholder="이름으로 찾기"><div class="pick" id="pick"><div class="hint">시작 메뉴 앱을 읽는 중…</div></div><div class="btns"><button data-r="0">닫기</button></div></div>`;
  modal.hidden = false;
  modal.onclick = (e) => { if (e.target.closest("[data-r]") || e.target === modal) modal.hidden = true; };
  const apps = await loadInstalled();
  const draw = () => {
    const q = $("#addQ").value.trim().toLowerCase();
    const list = apps.filter((a) => !q || a.name.toLowerCase().includes(q)).slice(0, 200);
    $("#pick").innerHTML = list.length ? list.map((a) => `<div class="row" data-add="${esc(a.id)}"><img data-icon="${esc(a.id)}" alt=""><span class="name">${esc(a.name)}</span>${inLauncher(a.target || a.id) ? '<span class="badge">있음</span>' : ""}</div>`).join("") : '<div class="hint">찾는 앱이 없어요</div>';
    $("#pick").querySelectorAll("img[data-icon]").forEach(loadIcon);
  };
  $("#addQ").oninput = draw;
  $("#pick").onclick = (e) => {
    const r = e.target.closest("[data-add]");
    if (!r) return;
    const a = apps.find((x) => x.id === r.dataset.add);
    if (a && !S.cats[ci].items.some((i) => i.id === a.id)) {
      S.cats[ci].items.push({ id: a.id, name: a.name, target: a.target });
      save(); render(); draw();
      toast(`‘${a.name}’ 을 넣었어요`);
    }
  };
  draw();
  $("#addQ").focus();
}

// MARK: 위젯 모드 · 창

async function applyWindow() {
  const w = win();
  if (!w) return;
  try {
    await w.setDecorations(!S.widget);
    await w.setSkipTaskbar(S.widget);
    await w.setAlwaysOnTop(S.widget && S.level === "top");
    await w.setAlwaysOnBottom(S.widget && S.level === "bottom");
  } catch (e) { console.warn(e); }
}
function setWidget(on) { S.widget = on; save(); render(); applyWindow(); }
function setLevel(l) { S.level = l; save(); render(); applyWindow(); }

async function setCollapsed(on) {
  const w = win();
  S.collapsed = on; save();
  if (w) {
    const f = await w.scaleFactor();
    const size = (await w.innerSize()).toLogical(f);
    if (on) {
      expandedH = size.height;
      render();
      const h = $("#app").querySelector("#grip").offsetHeight + $("#top").offsetHeight + 4;
      await w.setSize(new T.dpi.LogicalSize(size.width, h));
    } else {
      render();
      await w.setSize(new T.dpi.LogicalSize(size.width, expandedH || 560));
    }
  } else render();
}

// MARK: 이벤트

$("#q").addEventListener("input", async (e) => {
  query = e.target.value;
  if (query && !installedLoaded) { await loadInstalled(); }
  render();
});
$("#q").addEventListener("keydown", (e) => {
  if (e.key === "Escape") { e.target.value = ""; query = ""; render(); }
  if (e.key === "Enter") {
    const first = query.trim() ? visible[0] : visible.find((v) => v.item.id === focusId);
    if (first) openVisible(first);
    if (query.trim()) { e.target.value = ""; query = ""; render(); }
  }
  if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); stepFocus(e.key === "ArrowDown" ? 1 : -1); }
});
function openVisible(v) {
  const it = v.item;
  if (it.dev) { it.dev.path ? invoke("launch", { path: it.dev.path }) : installDev(it.dev); return; }
  if (it.other) { const r = running.find((x) => norm(x.exe) === norm(it.target)); if (r) invoke("focus_app", { pid: r.pid }); return; }
  launchItem(it);
}

$("#lockBtn").onclick = () => { S.locked = !S.locked; save(); render(); };
$("#collapseBtn").onclick = () => setCollapsed(!S.collapsed);
$("#explorerBtn").onclick = () => invoke("launch", { path: "explorer.exe" });

$("#seg").onclick = (e) => {
  const b = e.target.closest("[data-tab]");
  if (!b) return;
  S.tab = +b.dataset.tab; focusId = null; save(); render();
  if (S.tab === 2) loadDev(true);
};
$("#tools").onclick = async (e) => {
  const b = e.target.closest("[data-tool]");
  if (!b) return;
  const t = b.dataset.tool;
  if (t === "sidebar") { S.sidebar = !S.sidebar; save(); render(); }
  if (t === "view") { S.view = S.view === "list" ? "grid" : "list"; save(); render(); }
  if (t === "add") addDialog(S.sel[0] ?? 0);
  if (t === "devrefresh") loadDev(true);
  if (t === "updateall") devCatalog.filter(hasUpdate).forEach(installDev);
  if (t === "quitall" && (await confirmBox(`실행 중인 앱 ${running.length}개를 모두 종료할까요?`, "저장 안 한 문서가 있으면 각 앱이 저장할지 물어봐요."))) running.forEach((r) => quitApp(r, false));
};

// 클릭 · 우클릭
$("#list").addEventListener("click", (e) => {
  const q = e.target.closest("[data-quit]");
  if (q) { e.stopPropagation(); const r = running.find((x) => x.pid === +q.dataset.quit); if (r) quitApp(r, e.shiftKey); return; }
  const el = e.target.closest("[data-id]");
  if (!el) return;
  const v = visible.find((x) => x.item.id === el.dataset.id);
  if (v) openVisible(v);
});
$("#side").addEventListener("click", (e) => {
  const el = e.target.closest("[data-side]");
  if (!el) return;
  S.sel[S.tab] = +el.dataset.side; focusId = null; save(); render();
});
document.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  const item = e.target.closest("[data-id]");
  if (item) { const v = visible.find((x) => x.item.id === item.dataset.id); if (v) showMenu(e.clientX, e.clientY, itemMenu(v.item, v.installed)); return; }
  const cat = e.target.closest("[data-cat]");
  if (cat && cat.dataset.cat !== "") { showMenu(e.clientX, e.clientY, catMenu(+cat.dataset.cat)); return; }
  showMenu(e.clientX, e.clientY, bgMenu());
});

// 마우스를 올린 앱에 강조
$("#list").addEventListener("mouseover", (e) => {
  const el = e.target.closest("[data-id]");
  if (el && el.dataset.id !== focusId) setFocus(el.dataset.id, false);
});
function setFocus(id, reveal) {
  focusId = id;
  $("#list").querySelectorAll("[data-id]").forEach((el) => el.classList.toggle("focus", el.dataset.id === id));
  if (reveal) $("#list").querySelector(`[data-id="${CSS.escape(id)}"]`)?.scrollIntoView({ block: "nearest" });
}

// 스크롤: 왼쪽 목록 → 카테고리 넘기기, 앱 영역 → 강조를 한 칸씩
let acc = 0, lastStep = 0;
function wheelSteps(e, unit) {
  // 마우스 휠은 한 칸에 한 칸, 트랙패드(작은 값)는 움직인 만큼
  const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
  if (e.deltaMode === 1 || Math.abs(d) >= 50) return d > 0 ? 1 : d < 0 ? -1 : 0;
  acc += d;
  let n = 0;
  while (Math.abs(acc) >= unit) { n += acc > 0 ? 1 : -1; acc -= acc > 0 ? unit : -unit; }
  return n;
}
function sideStep(n) {
  const secs = sections();
  const cur = S.sel[S.tab] ?? 0;
  const next = Math.max(0, Math.min(secs.length - 1, cur + n));
  if (next === cur) return false;
  S.sel[S.tab] = next; save(); render();
  return true;
}
$("#side").addEventListener("wheel", (e) => {
  e.preventDefault();
  const n = wheelSteps(e, 40);
  if (n && Date.now() - lastStep > 120) { lastStep = Date.now(); focusId = null; sideStep(n > 0 ? 1 : -1); }
}, { passive: false });
function stepFocus(n) {
  if (!visible.length) { if (document.body.classList.contains("sidebar") && S.crossCategory) sideStep(n); return; }
  const cur = visible.findIndex((v) => v.item.id === focusId);
  const want = cur < 0 ? (n > 0 ? 0 : visible.length - 1) : cur + n;
  if ((want >= visible.length || want < 0) && document.body.classList.contains("sidebar") && S.crossCategory && cur >= 0) {
    if (sideStep(want < 0 ? -1 : 1)) {
      const v = want < 0 ? visible[visible.length - 1] : visible[0];
      if (v) setFocus(v.item.id, true);
    }
    return;
  }
  const v = visible[Math.max(0, Math.min(visible.length - 1, want))];
  if (v) setFocus(v.item.id, true);
}
$("#list").addEventListener("wheel", (e) => {
  if (!visible.length && !document.body.classList.contains("sidebar")) return;
  e.preventDefault();
  const n = wheelSteps(e, 20);
  if (n) stepFocus(n);
}, { passive: false });

// 끌어다 놓기: 앱 → 자리 · 카테고리, 카테고리 → 순서
let drag = null;
document.addEventListener("dragstart", (e) => {
  const app = e.target.closest("[data-id][draggable]");
  const cat = e.target.closest("[data-cat][draggable]:not([data-id])");
  if (app) drag = { kind: "app", id: app.dataset.id };
  else if (cat) drag = { kind: "cat", cat: +cat.dataset.cat };
  else return;
  e.dataTransfer.effectAllowed = "move";
  e.dataTransfer.setData("text/plain", "x");
  (app || cat).classList.add("dragging");
});
document.addEventListener("dragend", () => {
  drag = null;
  document.querySelectorAll(".dragging,.drop,.drop-before").forEach((el) => el.classList.remove("dragging", "drop", "drop-before"));
});
function dropTarget(e) {
  if (!drag) return null;
  if (drag.kind === "cat") {
    const c = e.target.closest("[data-cat]:not([data-id])");
    return c && c.dataset.cat !== "" ? { el: c, cat: +c.dataset.cat, cls: "drop-before" } : null;
  }
  const tile = e.target.closest("[data-id][data-cat]");
  if (tile && tile.dataset.cat !== "") {
    const [c, i] = locate(tile.dataset.id) || [];
    return c != null ? { el: tile, cat: c, index: i, cls: "drop-before" } : null;
  }
  const side = e.target.closest(".cat[data-cat]");
  if (side) return { el: side, cat: +side.dataset.cat, index: S.cats[+side.dataset.cat].items.length, cls: "drop" };
  const sec = e.target.closest("[data-sec-cat]");
  if (sec && sec.dataset.secCat !== "") { const c = +sec.dataset.secCat; return { el: sec, cat: c, index: S.cats[c].items.length, cls: "" }; }
  return null;
}
document.addEventListener("dragover", (e) => {
  const t = dropTarget(e);
  document.querySelectorAll(".drop,.drop-before").forEach((el) => el.classList.remove("drop", "drop-before"));
  if (!t) return;
  e.preventDefault();
  if (t.cls) t.el.classList.add(t.cls);
});
document.addEventListener("drop", (e) => {
  const t = dropTarget(e);
  if (!t) return;
  e.preventDefault();
  if (drag.kind === "cat") moveCat(drag.cat, t.cat);
  else moveItem(drag.id, t.cat, t.index);
});

// 아래 손잡이: 크기 조절 (위젯 모드)
$("#resize").addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  win()?.startResizeDragging("South").catch(() => {});
});

// MARK: 시작

(async function start() {
  if (!T) {
    // 브라우저에서 화면 모양만 미리 볼 때 쓰는 예시 데이터
    S.cats = [
      { name: "기본", items: [{ id: "a", name: "Chrome", target: "chrome.exe" }, { id: "b", name: "메모장", target: "notepad.exe" }, { id: "c", name: "계산기", target: "calc.exe" }] },
      { name: "개발", items: [{ id: "d", name: "Visual Studio Code", target: "code.exe" }, { id: "e", name: "Windows Terminal", target: "wt.exe" }] },
      { name: "게임", items: [{ id: "f", name: "Steam", target: "steam.exe" }] },
    ];
    running = [{ pid: 1, exe: "chrome.exe", name: "Google Chrome", title: "" }, { pid: 2, exe: "code.exe", name: "VS Code", title: "" }, { pid: 3, exe: "kakaotalk.exe", name: "카카오톡", title: "" }];
    render();
    return;
  }
  try {
    const raw = await invoke("read_config");
    if (raw) S = { ...structuredClone(DEFAULT), ...JSON.parse(raw) };
  } catch { /* 처음 */ }
  if (!S.cats.length) S.cats = structuredClone(DEFAULT.cats);
  render();
  applyWindow();
  pollRunning();
  setInterval(pollRunning, 2000);
  loadDev(false);
  loadInstalled();
})();
