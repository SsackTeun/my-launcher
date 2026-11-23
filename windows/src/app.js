// 도구함 (Windows) 화면 — 앱 목록 · 카테고리 · 실행 중 · 개발자 앱 · 데스크탑 · 위젯 모드 · 플레이어 · 창 정리
// (T · invoke · $ · esc · toast 는 common.js)
"use strict";

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
  tidy: '<svg viewBox="0 0 16 16"><rect x="1.5" y="2.5" width="9" height="7" rx="1.2" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="5.5" y="6.5" width="9" height="7" rx="1.2" fill="currentColor"/></svg>',
  video: '<svg viewBox="0 0 16 16"><rect x="1.5" y="3" width="13" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6.5 5.8v4.4L10.3 8z" fill="currentColor"/></svg>',
  gear: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="2.2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
  handleL: '<svg viewBox="0 0 16 16"><path d="M10 3L5 8l5 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  handleR: '<svg viewBox="0 0 16 16"><path d="M6 3l5 5-5 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
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
  // 플레이어 · 가사
  showPlayer: true,
  playerAppOnly: true,   // 미니 플레이어: 도구함 재생기(YouTube Music · YouTube · Netflix)만 (끄면 Windows 볼륨 창에 뜨는 모든 앱)
  lyricsLine: true,
  lyricsExpanded: false,
  lyricsFont: 13,
  transLang: "",         // 번역 언어 ("" 끔)
  pron: "off",           // 발음: off · hangul · roman
  detachPlayer: false,
  detachLyrics: false,
  // 청력 보호
  hearing: false,
  hearLimit: 0,          // dB, 0 끔
  earMax: 100,
  // 모양 · 동작
  theme: "default",      // default · bear · light
  themeImage: false,
  fontScale: 1,
  confirmQuit: true,
  closeToTray: true,
  hideTaskbar: false,    // 켜져 있는 동안 작업 표시줄 자동 숨기기
  edgeDock: true,        // 위젯을 화면 끝에 붙이면 서랍처럼 접기
  keepOnScreen: true,
  showDeskTab: false,    // 데스크탑 탭 (가상 데스크톱별 앱) — 기본은 숨김, 설정에서 켬    // 창이 화면 밖으로 나가지 않게
  docked: null,          // 접혀 있는 쪽 (left · right)
  dockedW: 0,
  // 자주 쓰는 앱 막대
  bar: { on: false, edge: "left", reserve: false, size: 44, items: [] },
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
let desk = null;         // 데스크탑 탭: { current, list, apps }
let mem = {};            // 실행 파일 → 메모리 (바이트)
const pip = {};          // 영상 창 → PIP 켜짐
const icons = new Map(); // 경로 → data URL

let saveTimer = null;
function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    invoke("write_config", { json: JSON.stringify(S) }).catch(() => {});
    syncTray();
  }, 250);
}
/// 트레이 메뉴의 앱 목록 = 도구함 앱 모두
let lastTray = "";
function syncTray() {
  const apps = S.cats.flatMap((c) => c.items).map((i) => ({ name: i.name, id: i.id }));
  const sig = JSON.stringify(apps);
  if (sig !== lastTray) { lastTray = sig; invoke("tray_apps", { apps }).catch(() => {}); }
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

async function quitApp(r, force, ask = true) {
  if (ask && S.confirmQuit && !(await confirmBox(`‘${r.name}’ 을 ${force ? "강제 " : ""}종료할까요?`, force ? "저장 안 한 내용은 사라져요." : "저장 안 한 문서가 있으면 앱이 저장할지 물어봐요."))) return;
  await invoke("quit_app", { pid: r.pid, force }).catch(() => {});
  setTimeout(pollRunning, 600);
}
/// 여러 앱 종료: 닫기를 부탁하고, 5초 뒤에도 남아 있으면 강제 종료를 권함
async function quitMany(list) {
  for (const r of list) await invoke("quit_app", { pid: r.pid, force: false }).catch(() => {});
  setTimeout(async () => {
    const left = [];
    for (const r of list) if (await invoke("is_alive", { pid: r.pid }).catch(() => false)) left.push(r);
    pollRunning();
    if (left.length && (await confirmBox(`${left.length}개 앱이 아직 안 꺼졌어요`, left.map((r) => r.name).join(", ") + " — 강제 종료할까요? (저장 안 한 내용은 사라져요)"))) {
      for (const r of left) await invoke("quit_app", { pid: r.pid, force: true }).catch(() => {});
      setTimeout(pollRunning, 600);
    }
  }, 5000);
}
/// 앱 다시 시작: 끄고, 꺼지면 다시 실행
async function restartApp(r, path) {
  await invoke("quit_app", { pid: r.pid, force: false }).catch(() => {});
  for (let k = 0; k < 20; k++) {
    await new Promise((d) => setTimeout(d, 500));
    if (!(await invoke("is_alive", { pid: r.pid }).catch(() => false))) { invoke("launch", { path }).catch((e) => toast(String(e))); return; }
  }
  toast(`‘${r.name}’ 이 꺼지지 않아서 다시 시작하지 못했어요`);
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
  if (S.tab === 3) {
    if (!desk) return [{ title: "데스크탑", cat: null, items: [] }];
    return desk.list.map((d) => ({
      title: d.name + (d.id === desk.current ? " (지금)" : ""),
      cat: null,
      items: (desk.apps[d.id] || []).map((a) => ({ id: `desk:${d.id}:${a.exe}`, name: a.name, target: a.exe, other: true, hwnd: a.hwnd, pid: a.pid })),
    }));
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
  renderPlayerArea();
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
  $("#tidyBtn").innerHTML = I.tidy;
  // 위쪽 줄을 잡고 창 옮기기 (위치 고정한 위젯은 빼고)
  $("#top").toggleAttribute("data-tauri-drag-region", !(S.widget && S.locked));
  $("#gearBtn").innerHTML = I.gear;
  $("#grip").toggleAttribute("data-tauri-drag-region", S.widget && !S.locked);
  $("#grip").title = S.locked ? "위치 고정됨 — 🔒 를 눌러 풀 수 있어요" : "잡고 끌어서 옮기기";
}

function renderTabs() {
  const ups = devCatalog.filter((a) => hasUpdate(a)).length;
  const labels = ["전체", `실행 중 ${running.length}`, ups ? `개발자 앱 ●${ups}` : "개발자 앱", "데스크탑"];
  // 데스크탑 탭은 설정에서 켰을 때만
  if (!S.showDeskTab && S.tab === 3) S.tab = 0;
  $("#seg").innerHTML = labels.map((l, i) => (i === 3 && !S.showDeskTab ? "" : `<button data-tab="${i}" class="${i === S.tab ? "on" : ""}">${esc(l)}</button>`)).join("");
  const tools = [];
  if (S.tab === 1) tools.push(`<button class="icon" data-tool="quitall" title="모두 종료 (도구함 제외)">${I.power}</button>`);
  if (S.tab === 3) tools.push(`<button class="icon" data-tool="deskrefresh" title="새로 고침">${I.refresh}</button>`);
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
  const iconPath = item.dev ? (devPath(item.dev) || "") : item.other ? item.target : (item.id || "");
  const m = S.tab === 1 && r && !query ? mem[norm(r.exe)] : null;
  const memHTML = m ? `<span class="mem" title="메모리 (그 앱의 모든 프로세스 합)">${fmtBytes(m)}</span>` : "";
  const badge = item.dev ? devBadge(item.dev) : null;
  const focus = item.id === focusId ? " focus" : "";
  const missing = item.dev && !devPath(item.dev) ? " missing" : "";
  const quit = S.tab === 1 && r && !query ? `<button class="quit" data-quit="${r.pid}" title="종료 · Shift(또는 Alt) 누르고 누르면 강제 종료">${I.x}</button>` : "";
  const attrs = `data-id="${esc(item.id)}" data-cat="${ctx.cat ?? ""}" ${ctx.cat != null ? 'draggable="true"' : ""}`;
  const img = `<img data-icon="${esc(iconPath)}" alt="">`;
  const badgeHTML = badge ? `<span class="badge ${badge === "업데이트" ? "update" : ""}">${esc(badge)}</span>` : "";
  const dot = r ? '<span class="dot"></span>' : "";
  const tip = m ? ` title="${esc(item.name)} · 메모리 ${fmtBytes(m)}"` : "";
  if (S.view === "list") return `<div class="row${focus}${missing}" ${attrs}>${img}<span class="name">${esc(item.name)}</span>${memHTML}${badgeHTML}${quit}${dot}</div>`;
  return `<div class="tile${focus}${missing}" ${attrs}${tip}>${img}<span class="name">${esc(item.name)}</span>${badgeHTML}${quit}${dot}</div>`;
}

let visible = []; // 지금 보이는 앱 (스크롤 강조 이동용)
function renderList(secs, headers) {
  visible = [];
  const html = secs.map((s) => {
    const body = s.items.length
      ? `<div class="${S.view === "list" ? "rows" : "grid"}" data-sec-cat="${s.cat ?? ""}">${s.items.map((i) => { visible.push({ item: i, installed: !!s.installed }); return itemHTML(i, s); }).join("")}</div>`
      : `<div class="hint" data-sec-cat="${s.cat ?? ""}">${query ? `‘${esc(query)}’ 와 맞는 앱이 없어요` : S.tab === 1 ? `실행 중인 ${esc(s.title)}이 없어요` : S.tab === 2 ? "목록이 비어 있어요" : S.tab === 3 ? (desk ? "창이 열린 앱이 없어요" : "읽는 중…") : "비어 있음 — ＋ 로 앱을 추가하거나 다른 카테고리에서 끌어다 놓으세요"}</div>`;
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
let memAt = 0;
async function pollRunning() {
  try { running = await invoke("running_apps"); } catch { running = []; }
  let sig = running.map((r) => r.pid + r.exe).join("|");
  if (S.tab === 1 && !S.collapsed && Date.now() - memAt > 5000) {
    memAt = Date.now();
    try { mem = await invoke("memory_usage"); } catch { /* 건너뜀 */ }
    sig += JSON.stringify(Object.values(mem).map((b) => Math.round(b / (64 << 20))));
  } else if (S.tab === 1) sig += JSON.stringify(Object.values(mem).map((b) => Math.round(b / (64 << 20))));
  if (S.tab === 3) { await loadDesk(); sig += JSON.stringify(desk); }
  if (sig !== lastRunSig) { lastRunSig = sig; if (!menuOpen() && !document.querySelector(".dragging")) render(); }
}
async function loadDesk() {
  try { desk = await invoke("desktops"); } catch { desk = null; }
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

async function itemMenu(item, installedOnly) {
  if (item.dev) {
    const a = item.dev;
    return [
      a.path ? { label: "실행", action: () => invoke("launch", { path: a.path }) } : null,
      { label: !a.path ? "받기 (설치)" : hasUpdate(a) ? `업데이트 → ${devLatest[a.folder]?.version}` : "다시 받기", action: () => installDev(a) },
      "-",
      { label: "GitHub 에서 보기", action: () => invoke("launch", { path: `https://github.com/${a.repo}` }) },
    ].filter(Boolean);
  }
  const r = item.other ? running.find((x) => norm(x.exe) === norm(item.target)) || (item.pid ? { pid: item.pid, exe: item.target, name: item.name } : null) : runningOf(item);
  const mine = !!locate(item.id);
  const path = item.other ? item.target : item.id;
  const out = [{ label: r ? "앞으로 가져오기" : "실행", action: () => (item.hwnd ? invoke("window_action", { hwnd: item.hwnd, action: "focus" }) : item.other ? invoke("focus_app", { pid: r.pid }) : launchItem(item)) }];
  if (r) {
    // Dock 처럼: 열린 창 목록 · 새 창 · 최소화
    const wins = await invoke("app_windows", { pid: r.pid }).catch(() => []);
    if (wins.length) {
      out.push("-", { label: "열린 창", header: true });
      for (const w of wins.slice(0, 12)) {
        const t = (w.title || r.name).length > 46 ? (w.title || r.name).slice(0, 45) + "…" : (w.title || r.name);
        const where = desk && w.desktop && w.desktop !== desk.current ? ` — ${desk.list.find((d) => d.id === w.desktop)?.name || "다른 데스크탑"}` : "";
        out.push({ label: (w.minimized ? "◦ " : "") + t + where, action: () => invoke("window_action", { hwnd: w.hwnd, action: "focus" }) });
      }
      out.push("-",
        { label: "새 창", action: () => invoke("launch", { path }).catch((e) => toast(String(e))) },
        { label: "모든 창 최소화", action: () => wins.forEach((w) => invoke("window_action", { hwnd: w.hwnd, action: "minimize" })) },
        { label: "모든 창 닫기", action: () => wins.forEach((w) => invoke("window_action", { hwnd: w.hwnd, action: "close" })) });
    }
  }
  if (installedOnly || item.other) out.push("-", { label: "도구함에 넣기", children: addToMenu(item) });
  out.push({ label: "자주 쓰는 앱 막대에 넣기", disabled: S.bar.items.some((b) => norm(b.target || b.id) === norm(item.target || item.id)), action: () => addToBar(item) });
  if (mine) {
    out.push("-", { label: "카테고리 옮기기", children: moveToMenu(item.id) });
    const [c, i] = locate(item.id);
    out.push({ label: "앞으로 옮기기", disabled: i === 0, action: () => moveItem(item.id, c, i - 1) });
    out.push({ label: "뒤로 옮기기", disabled: i === S.cats[c].items.length - 1, action: () => moveItem(item.id, c, i + 2) });
  }
  out.push("-", { label: "파일 위치 열기", action: () => invoke("reveal", { path }) });
  if (r) out.push("-", { label: "다시 시작", action: () => restartApp(r, path) }, { label: "종료", action: () => quitApp(r, false) }, { label: "강제 종료", action: () => quitApp(r, true) });
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
    { label: "작업 표시줄 앱 가져오기", action: importTaskbar },
    "-",
    { label: "영상 창", children: videoMenu() },
    { label: "자주 쓰는 앱 막대", checked: S.bar.on, action: () => { S.bar.on = !S.bar.on; save(); syncBar(); } },
    { label: "플레이어", checked: S.showPlayer, action: () => { S.showPlayer = !S.showPlayer; save(); render(); } },
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
    "-",
    { label: "설정…  Ctrl+,", action: settingsDialog },
    { label: "도구함 다시 시작  Ctrl+R", action: () => invoke("restart_self") },
  ];
}

// MARK: 창 정리 (맨 위 버튼)

function tidyMenu() {
  return [
    { label: "열린 창 모두 닫기", action: async () => { if (await confirmBox("지금 데스크탑의 창을 모두 닫을까요?", "저장 안 한 문서가 있으면 앱이 저장할지 물어봐요.")) toast(`창 ${await invoke("tidy", { action: "close_all" })}개를 닫았어요`); } },
    { label: "모두 최소화", action: async () => toast(`창 ${await invoke("tidy", { action: "minimize_all" })}개를 최소화했어요`) },
    { label: "최소화한 창 모두 되살리기", action: async () => toast(`창 ${await invoke("tidy", { action: "restore_all" })}개를 되살렸어요`) },
    "-",
    { label: "앱 모두 종료 (도구함 · 탐색기 제외)", action: async () => {
      const list = running.filter((r) => !/\\explorer\.exe$/i.test(r.exe));
      if (list.length && (await confirmBox(`앱 ${list.length}개를 모두 종료할까요?`, list.map((r) => r.name).join(", ")))) quitMany(list);
    } },
    { label: "앱 골라서 종료…", action: pickQuitDialog },
  ];
}
function pickQuitDialog() {
  const list = running.filter((r) => !/\\explorer\.exe$/i.test(r.exe));
  modal.innerHTML = `<div class="box"><h3>종료할 앱 고르기</h3><div class="pick" id="pick">${list.map((r, i) => `<label class="row"><input type="checkbox" data-k="${i}"><img data-icon="${esc(r.exe)}" alt=""><span class="name">${esc(r.name)}</span>${mem[norm(r.exe)] ? `<span class="mem">${fmtBytes(mem[norm(r.exe)])}</span>` : ""}</label>`).join("") || '<div class="hint">실행 중인 앱이 없어요</div>'}</div><div class="btns"><button data-r="all">모두 고르기</button><span style="flex:1"></span><button data-r="0">취소</button><button class="primary" data-r="1">종료</button></div></div>`;
  modal.hidden = false;
  modal.querySelectorAll("img[data-icon]").forEach(loadIcon);
  modal.onclick = (e) => {
    const b = e.target.closest("[data-r]");
    if (!b && e.target !== modal) return;
    if (b?.dataset.r === "all") { const boxes = [...modal.querySelectorAll("input[data-k]")]; const on = !boxes.every((x) => x.checked); boxes.forEach((x) => (x.checked = on)); return; }
    const chosen = [...modal.querySelectorAll("input[data-k]:checked")].map((x) => list[+x.dataset.k]);
    modal.hidden = true;
    if (b?.dataset.r === "1" && chosen.length) quitMany(chosen);
  };
}

// MARK: 작업 표시줄 · 영상 창 · 막대

async function importTaskbar() {
  const apps = await invoke("taskbar_pinned").catch(() => []);
  if (!apps.length) { toast("작업 표시줄에 고정된 앱을 찾지 못했어요"); return; }
  let ci = S.cats.findIndex((c) => c.name === "작업 표시줄");
  if (ci < 0) { S.cats.push({ name: "작업 표시줄", items: [] }); ci = S.cats.length - 1; }
  let n = 0;
  for (const a of apps) if (!inLauncher(a.target || a.id)) { S.cats[ci].items.push({ id: a.id, name: a.name, target: a.target }); n++; }
  save(); render();
  toast(n ? `${n}개를 ‘작업 표시줄’ 카테고리에 넣었어요` : "새로 넣을 앱이 없어요");
}

const VIDEO = [["yt-video", "YouTube", "https://www.youtube.com"], ["netflix", "Netflix", "https://www.netflix.com"]];
function videoMenu() {
  const out = [];
  for (const [label, name, url] of VIDEO) {
    out.push({ label: `${name} 열기`, action: () => invoke("open_window", { label, url, title: name, width: 1100, height: 720 }).catch((e) => toast(String(e))) });
    out.push({ label: `${name} PIP (항상 위 작은 창)`, checked: !!pip[label], action: async () => {
      if (!(await invoke("window_exists", { label }))) { await invoke("open_window", { label, url, title: name, width: 1100, height: 720 }); toast("영상을 연 뒤 PIP 를 눌러 주세요"); return; }
      pip[label] = await invoke("web_pip", { label, on: !pip[label] });
    } });
    if (openNow[label]) out.push({ label: `${name} 끄기`, action: () => invoke("close_window", { label }) });
  }
  out.push("-", { label: "YouTube Music 열기", action: () => Player.openYTMusic() },
    { label: "YouTube Music 끄기 (노래 멈춤)", disabled: !ytOpenNow, action: () => invoke("close_window", { label: "ytmusic" }) });
  return out;
}

function addToBar(item) {
  S.bar.items.push({ id: item.other ? item.target : item.id, name: item.name, target: item.target || item.id });
  if (!S.bar.on) S.bar.on = true;
  save(); syncBar();
  toast(`‘${item.name}’ 을 막대에 넣었어요`);
}
async function syncBar() {
  if (S.bar.on) {
    invoke("open_window", { label: "bar", url: "bar.html", title: "자주 쓰는 앱", width: 60, height: 300, frameless: true, onTop: true }).catch((e) => toast(String(e)));
  } else if (await invoke("window_exists", { label: "bar" }).catch(() => false)) {
    await invoke("appbar_release").catch(() => {});
    invoke("close_window", { label: "bar" });
  }
}
/// 떼어 낸 플레이어 · 가사 줄 창
async function syncDetached() {
  for (const [key, label, url, w, h] of [["detachPlayer", "player", "player.html", 340, 166], ["detachLyrics", "line", "line.html", 420, 90]]) {
    const pos = S[label + "Pos"];
    if (S[key]) invoke("open_window", { label, url, title: label === "player" ? "플레이어" : "가사 줄", width: w, height: h, x: pos?.[0], y: pos?.[1], frameless: true, onTop: true }).catch(() => {});
    else if (await invoke("window_exists", { label }).catch(() => false)) invoke("close_window", { label });
  }
}

// MARK: 설정

function settingsDialog() {
  const opt = (v, cur, t) => `<option value="${esc(v)}" ${String(v) === String(cur) ? "selected" : ""}>${esc(t)}</option>`;
  const chk = (k, t, sub) => `<label class="set-ck"><input type="checkbox" data-k="${k}" ${S[k] ? "checked" : ""}><span>${t}${sub ? `<small>${sub}</small>` : ""}</span></label>`;
  modal.innerHTML = `<div class="box wide"><h3>설정</h3><div class="settings">
    <h4>모양</h4>
    <label class="set-row">테마 <select data-k="theme">${opt("default", S.theme, "기본 (어두운 반투명)")}${opt("light", S.theme, "밝게")}${opt("bear", S.theme, "곰 (우유색 · 갈색 · 분홍)")}</select></label>
    <label class="set-row">배경 그림 <span><button data-act="pickimg">고르기…</button> ${S.themeImage ? '<button data-act="clearimg">지우기</button>' : ""}</span></label>
    <label class="set-row">글자 크기 <select data-k="fontScale">${[0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4].map((v) => opt(v, S.fontScale, Math.round(v * 100) + "%")).join("")}</select></label>
    <label class="set-row">아이콘 크기 <select data-k="iconSize">${[24, 32, 40, 56, 72, 96, 128].map((v) => opt(v, S.iconSize, v + "px")).join("")}</select></label>
    <h4>동작</h4>
    ${chk("closeToTray", "창을 닫으면 트레이로 (알림 영역 🧰 에서 다시 열기)")}
    ${chk("confirmQuit", "앱을 종료하기 전에 물어보기")}
    ${chk("hideTaskbar", "도구함이 켜져 있는 동안 작업 표시줄 자동 숨기기", "끄면 · 도구함을 끝내면 원래대로")}
    ${chk("edgeDock", "위젯을 화면 왼쪽 · 오른쪽 끝에 붙이면 서랍 손잡이로 접기")}
    ${chk("keepOnScreen", "창이 화면 밖으로 나가지 않게")}
    ${chk("showDeskTab", "데스크탑 탭 보이기", "가상 데스크톱마다 창이 열린 앱 — 데스크톱을 여러 개 쓸 때")}
    <label class="set-ck"><input type="checkbox" data-act="autostart" id="autoChk"><span>로그인 시 자동 실행</span></label>
    <h4>플레이어 · 가사</h4>
    ${chk("showPlayer", "미니 플레이어 보이기")}
    ${chk("playerAppOnly", "도구함 재생기만 (YouTube Music · YouTube · Netflix)", "‹ › 로 넘기고, 새로 재생을 시작하면 그 재생기로 넘어가며 나머지는 일시정지. 끄면 Windows 볼륨 창에 곡이 뜨는 앱이면 무엇이든")}
    ${chk("lyricsLine", "플레이어 아래 가사 줄")}
    <label class="set-row">번역 <select data-k="transLang">${LANGS.map(([c, n]) => opt(c, S.transLang, n)).join("")}</select></label>
    <label class="set-row">발음 <select data-k="pron">${opt("off", S.pron, "끔")}${opt("hangul", S.pron, "한글 발음 (일본어 · 중국어)")}${opt("roman", S.pron, "로마자 (라틴 문자가 아닌 가사)")}</select></label>
    <p class="set-note">번역 · 발음을 켜면 가사 글자가 Google 번역으로 보내져요 (Mac 판은 기기 안 Apple 번역).</p>
    <h4>청력 보호</h4>
    ${chk("hearing", "귀에 들어가는 크기 · 오늘 들은 양 보이기", "85dB 로 8시간이 하루 허용량 (3dB 커질 때마다 절반)")}
    <label class="set-row">이어폰 최대 크기 <select data-k="earMax">${[90, 95, 100, 105, 110].map((v) => opt(v, S.earMax, v + " dB")).join("")}</select></label>
    <label class="set-row">크기 제한 <select data-k="hearLimit">${opt(0, S.hearLimit, "끔")}${[75, 80, 85, 90].map((v) => opt(v, S.hearLimit, v + " dB 넘으면 볼륨 낮춤")).join("")}</select></label>
    <h4>자주 쓰는 앱 막대</h4>
    <label class="set-ck"><input type="checkbox" data-bar="on" ${S.bar.on ? "checked" : ""}><span>막대 켜기</span></label>
    <label class="set-row">위치 <select data-bar="edge">${opt("left", S.bar.edge, "왼쪽")}${opt("right", S.bar.edge, "오른쪽")}${opt("top", S.bar.edge, "위")}${opt("bottom", S.bar.edge, "아래")}</select></label>
    <label class="set-ck"><input type="checkbox" data-bar="reserve" ${S.bar.reserve ? "checked" : ""}><span>막대 자리 비워 두기<small>다른 창이 막대 자리를 덮지 않게 (최대화한 창도 막대 옆까지)</small></span></label>
    <label class="set-row">아이콘 크기 <select data-bar="size">${[32, 40, 44, 52, 64].map((v) => opt(v, S.bar.size, v + "px")).join("")}</select></label>
  </div><div class="btns"><button class="primary" data-r="1">닫기</button></div></div>`;
  modal.hidden = false;
  invoke("autostart", {}).then((v) => ($("#autoChk").checked = v)).catch(() => {});
  modal.onclick = async (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "pickimg") { e.preventDefault(); pickImage(); return; }
    if (act === "clearimg") { e.preventDefault(); await invoke("theme_image", { set: "" }); S.themeImage = false; save(); applySettings(); settingsDialog(); return; }
    if (e.target.closest("[data-r]") || e.target === modal) modal.hidden = true;
  };
  modal.onchange = (e) => {
    const t = e.target;
    if (t.dataset.act === "autostart") { invoke("autostart", { on: t.checked }).then(() => syncTray()); return; }
    if (t.dataset.bar) {
      const k = t.dataset.bar;
      S.bar = { ...S.bar, [k]: t.type === "checkbox" ? t.checked : k === "size" ? +t.value : t.value };
      save(); syncBar(); return;
    }
    const k = t.dataset.k;
    if (!k) return;
    S[k] = t.type === "checkbox" ? t.checked : typeof DEFAULT[k] === "number" ? +t.value : t.value;
    save(); render(); applySettings();
  };
}
function pickImage() {
  const inp = document.createElement("input");
  inp.type = "file"; inp.accept = "image/*";
  inp.onchange = () => {
    const f = inp.files[0];
    if (!f) return;
    if (f.size > 8 << 20) { toast("8MB 보다 작은 그림을 골라 주세요"); return; }
    const rd = new FileReader();
    rd.onload = async () => { await invoke("theme_image", { set: rd.result }); S.themeImage = true; save(); applySettings(); settingsDialog(); };
    rd.readAsDataURL(f);
  };
  inp.click();
}
let taskbarSet = null;
function applySettings() {
  invoke("set_close_to_tray", { on: !!S.closeToTray }).catch(() => {});
  invoke("media_mode", { appOnly: S.playerAppOnly !== false }).catch(() => {});
  if (taskbarSet !== S.hideTaskbar && (S.hideTaskbar || taskbarSet)) invoke("taskbar_autohide", { on: !!S.hideTaskbar }).catch(() => {});
  taskbarSet = S.hideTaskbar;
  invoke("hearing", { on: !!S.hearing, limit: +S.hearLimit || 0, earMax: +S.earMax || 100 }).catch(() => {});
  applyTheme(S);
  Player.setCfg(S);
  syncDetached();
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
    await w.setDecorations(false); // 제목 막대는 늘 숨기고, 일반 창일 때는 위쪽 줄에 창 버튼
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
      const h = $("#app").querySelector("#grip").offsetHeight + $("#top").offsetHeight + $("#player").offsetHeight + $("#lyline").offsetHeight + 6;
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
  if (it.hwnd) { invoke("window_action", { hwnd: it.hwnd, action: "focus" }); return; }
  if (it.other) { const r = running.find((x) => norm(x.exe) === norm(it.target)); if (r) invoke("focus_app", { pid: r.pid }); return; }
  launchItem(it);
}

$("#lockBtn").onclick = () => { S.locked = !S.locked; save(); render(); };
$("#collapseBtn").onclick = () => setCollapsed(!S.collapsed);
$("#explorerBtn").onclick = () => invoke("launch", { path: "explorer.exe" });
$("#tidyBtn").onclick = (e) => { const r = e.currentTarget.getBoundingClientRect(); showMenu(r.left, r.bottom + 4, tidyMenu()); };
$("#gearBtn").onclick = settingsDialog;
let ytOpenNow = false;
const openNow = {};
async function refreshOpen() { for (const [l] of VIDEO) openNow[l] = await invoke("window_exists", { label: l }).catch(() => false); }
// MARK: 재생기 단추 (맨 위 줄) — sites.js (떼어 낸 플레이어와 같이 씀)
Sites.mount($("#sites"), showMenu);
Sites.onChange(() => { Object.assign(pip, Sites.pip); Object.assign(openNow, Sites.open); ytOpenNow = !!Sites.open.ytmusic; });
$("#minBtn").onclick = () => win()?.minimize();
$("#maxBtn").onclick = () => win()?.toggleMaximize();
$("#closeBtn").onclick = () => win()?.close();

$("#seg").onclick = (e) => {
  const b = e.target.closest("[data-tab]");
  if (!b) return;
  S.tab = +b.dataset.tab; focusId = null; save(); render();
  if (S.tab === 2) loadDev(true);
  if (S.tab === 1) { memAt = 0; pollRunning(); }
  if (S.tab === 3) loadDesk().then(render);
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
  if (t === "quitall" && (await confirmBox(`실행 중인 앱 ${running.length}개를 모두 종료할까요?`, "저장 안 한 문서가 있으면 각 앱이 저장할지 물어봐요. 5초 안에 안 꺼지면 강제 종료를 물어봐요."))) quitMany(running);
  if (t === "deskrefresh") { await loadDesk(); render(); }
};

// 클릭 · 우클릭
$("#list").addEventListener("click", (e) => {
  const q = e.target.closest("[data-quit]");
  if (q) { e.stopPropagation(); const r = running.find((x) => x.pid === +q.dataset.quit); if (r) quitApp(r, e.shiftKey || e.altKey); return; }
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
document.addEventListener("contextmenu", async (e) => {
  e.preventDefault();
  if (e.target.closest("#player, #lyline, #modal")) return;
  for (const [l] of VIDEO) pip[l] = await invoke("web_pip_state", { label: l }).catch(() => false);
  ytOpenNow = await invoke("window_exists", { label: "ytmusic" }).catch(() => false);
  await refreshOpen();
  const item = e.target.closest("[data-id]");
  if (item) { const v = visible.find((x) => x.item.id === item.dataset.id); if (v) showMenu(e.clientX, e.clientY, await itemMenu(v.item, v.installed)); return; }
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
  const app = e.target.closest("[data-id]");
  if (app && !app.hasAttribute("draggable")) { // 실행 중 · 데스크탑 탭 앱: 막대로만 끌기
    const v = visible.find((x) => x.item.id === app.dataset.id);
    if (v) { e.dataTransfer.setData("text/plain", "mylauncher:" + JSON.stringify({ id: v.item.other ? v.item.target : v.item.id, name: v.item.name, target: v.item.target || v.item.id })); e.dataTransfer.effectAllowed = "copy"; }
    return;
  }
  const cat = e.target.closest("[data-cat][draggable]:not([data-id])");
  if (app) drag = { kind: "app", id: app.dataset.id };
  else if (cat) drag = { kind: "cat", cat: +cat.dataset.cat };
  else return;
  e.dataTransfer.effectAllowed = "copyMove";
  const v = app && visible.find((x) => x.item.id === app.dataset.id);
  e.dataTransfer.setData("text/plain", v ? "mylauncher:" + JSON.stringify({ id: v.item.other ? v.item.target : v.item.id, name: v.item.name, target: v.item.target || v.item.id }) : "x");
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
  S.bar = { ...DEFAULT.bar, ...(S.bar || {}) };
  if (S.docked && S.widget) {
    document.body.classList.add("docked");
    document.body.dataset.edge = S.docked;
    $("#edgeHandle").innerHTML = S.docked === "left" ? I.handleR : I.handleL;
    win()?.setMinSize(new T.dpi.LogicalSize(16, 100)).catch(() => {});
  } else S.docked = null;
  render();
  applyWindow();
  Player.start(S);
  applySettings();
  syncTray();
  syncBar();
  pollRunning();
  setInterval(pollRunning, 2000);
  loadDev(false);
  loadInstalled();
  // 다른 창(떼어 낸 플레이어 · 가사 · 막대)이 설정을 바꿔 달라고 할 때
  T.event.listen("cfg-set", (e) => {
    const { key, value } = e.payload || {};
    if (!key) return;
    S[key] = value;
    save(); render(); applySettings();
    if (key === "bar") syncBar();
  });
  // 위치 기억 · 화면 밖으로 안 나가게 · 화면 끝 서랍
  const w = win();
  let moveTimer = null;
  w.onMoved(() => { clearTimeout(moveTimer); moveTimer = setTimeout(afterMove, 450); });
  setTimeout(afterMove, 600);
})();

// MARK: 플레이어 · 가사 줄 (도구함 창 안)

function renderPlayerArea() {
  const showP = S.showPlayer && !S.detachPlayer;
  const showL = showP && S.lyricsLine && !S.detachLyrics;
  $("#player").hidden = !showP;
  $("#lyline").hidden = !showL;
  if (showP) Player.renderPlayer($("#player"), { lyricsOn: S.lyricsLine });
  if (showL) Player.renderLine($("#lyline"));
}
Player.on((tick) => {
  if (tick) { if (S.showPlayer && !S.detachPlayer) { Player.tickPlayer($("#player")); if (S.lyricsLine && !S.detachLyrics) Player.renderLine($("#lyline")); } return; }
  renderPlayerArea();
});
Player.bindPlayer($("#player"), {
  lyrics: () => { S.lyricsLine = !S.lyricsLine; save(); renderPlayerArea(); },
  detach: () => { S.detachPlayer = true; save(); renderPlayerArea(); syncDetached(); },
});
Player.bindLine($("#lyline"), {
  detach: () => { S.detachLyrics = true; save(); renderPlayerArea(); syncDetached(); },
});

// MARK: 단축키

document.addEventListener("keydown", (e) => {
  if (e.ctrlKey && !e.shiftKey && !e.altKey) {
    if (e.key === "f" || e.key === "F") { e.preventDefault(); $("#q").focus(); $("#q").select(); }
    if (e.key === "r" || e.key === "R") { e.preventDefault(); invoke("restart_self"); }
    if (e.key === ",") { e.preventDefault(); settingsDialog(); }
  }
  if (e.key === "Escape" && menuOpen()) closeMenu();
});

// MARK: 화면 끝 서랍 · 화면 안으로

async function afterMove() {
  const w = win();
  if (!w || S.docked) return;
  const p = await w.outerPosition(), sz = await w.outerSize();
  const a = await invoke("work_area_at", { x: Math.round(p.x + sz.width / 2), y: Math.round(p.y + Math.min(40, sz.height / 2)) }).catch(() => null);
  if (!a) return;
  // 화면 밖으로 나갔으면 가장 가까운 화면 안으로 밀어 넣기
  if (S.keepOnScreen) {
    const nx = Math.max(a.x, Math.min(p.x, a.x + a.w - sz.width));
    const ny = Math.max(a.y, Math.min(p.y, a.y + a.h - Math.min(sz.height, a.h)));
    if (nx !== p.x || ny !== p.y) { await w.setPosition(new T.dpi.PhysicalPosition(nx, ny)); return; }
  }
  // 위젯이 왼쪽 · 오른쪽 끝에 붙어 있으면 서랍 손잡이
  let side = "";
  if (S.edgeDock && S.widget) {
    if (Math.abs(p.x - a.x) <= 14) side = "left";
    else if (Math.abs(p.x + sz.width - (a.x + a.w)) <= 14) side = "right";
  }
  document.body.dataset.edge = side;
  $("#edgeHandle").innerHTML = side === "left" ? I.handleL : I.handleR;
}
async function setDocked(side) {
  const w = win();
  const f = await w.scaleFactor();
  const p = await w.outerPosition(), sz = await w.outerSize();
  const a = await invoke("work_area_at", { x: Math.round(p.x + sz.width / 2), y: Math.round(p.y + 20) });
  if (side) {
    S.dockedW = sz.width / f;
    S.docked = side;
    document.body.classList.add("docked");
    $("#edgeHandle").innerHTML = side === "left" ? I.handleR : I.handleL;
    await w.setMinSize(new T.dpi.LogicalSize(16, 100)).catch(() => {});
    await w.setSize(new T.dpi.LogicalSize(18, sz.height / f));
    await w.setPosition(new T.dpi.PhysicalPosition(side === "left" ? a.x : a.x + a.w - Math.round(18 * f), p.y));
  } else {
    const was = S.docked;
    S.docked = null;
    document.body.classList.remove("docked");
    const wd = S.dockedW || 420;
    await w.setSize(new T.dpi.LogicalSize(wd, sz.height / f));
    await w.setPosition(new T.dpi.PhysicalPosition(was === "left" ? a.x : a.x + a.w - Math.round(wd * f), p.y));
    await w.setMinSize(new T.dpi.LogicalSize(300, 200)).catch(() => {});
    afterMove();
  }
  save();
}
$("#edgeHandle").addEventListener("click", () => setDocked(S.docked ? null : document.body.dataset.edge));
$("#edgeHandle").addEventListener("dragenter", () => { if (S.docked) setDocked(null); });

