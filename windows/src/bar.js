// 자주 쓰는 앱 막대: 화면 가장자리(왼 · 오른 · 위 · 아래)에 붙는 작은 막대
// - 아이콘 클릭 → 실행 / 앞으로, 오른쪽 클릭 → 메뉴
// - 맨 끝 [+] → 실행 중 · 도구함 앱에서 골라 넣기, 도구함 창에서 아이콘을 끌어다 놓아도 들어감
// - 막대 안에서 끌면 순서 바꾸기, 막대 밖으로 끌어내 놓으면 빠짐
// - '자리 비워 두기' 를 켜면 Windows 앱 바로 등록해서 다른 창(최대화 포함)이 막대 자리를 덮지 않음
"use strict";

(async function () {
  const M = T.menu;
  let cfg = await readConfig();
  let bar = { on: true, edge: "left", reserve: false, size: 44, items: [], ...(cfg.bar || {}) };
  let running = [];
  const icons = new Map();
  const norm = (p) => String(p || "").toLowerCase();
  const vertical = () => bar.edge === "left" || bar.edge === "right";
  const setBar = (b) => { bar = b; setConfig("bar", b); };

  async function layout() {
    const f = await win().scaleFactor();
    const n = bar.items.length + 1;
    // 막대 = 안쪽 여백 10 × 2 + 테두리 1 × 2 + 아이콘들(사이 8)
    const thick = bar.size + 22;
    const length = n * bar.size + (n - 1) * 8 + 22;
    document.documentElement.style.setProperty("--bsize", bar.size + "px");
    await invoke("appbar", { edge: bar.edge, thick: Math.round(thick * f), length: Math.round(length * f), reserve: !!bar.reserve }).catch((e) => console.warn(e));
  }

  function render() {
    document.body.className = `bar ${vertical() ? "v" : "h"} edge-${bar.edge}`;
    $("#bar").innerHTML = bar.items.map((it, i) => {
      const r = running.find((x) => norm(x.exe) === norm(it.target));
      return `<div class="b-it" data-i="${i}" draggable="true" title="${esc(it.name)}"><img data-icon="${esc(it.id)}" alt="">${r ? '<span class="dot"></span>' : ""}</div>`;
    }).join("") + `<div class="b-add" title="앱 넣기"><span>+</span></div>`;
    $("#bar").querySelectorAll("img[data-icon]").forEach(async (img) => {
      const p = img.dataset.icon;
      if (!icons.has(p)) icons.set(p, invoke("icon", { path: p }).then((b) => (b ? `data:image/png;base64,${b}` : "")).catch(() => ""));
      const url = await icons.get(p);
      if (url) img.src = url;
    });
  }

  async function poll() {
    try { running = await invoke("running_apps"); } catch { running = []; }
    render();
  }

  async function open(it) {
    const r = running.find((x) => norm(x.exe) === norm(it.target));
    if (r && (await invoke("focus_app", { pid: r.pid }).catch(() => false))) return;
    invoke("launch", { path: it.id }).catch(() => {});
  }

  // MARK: 메뉴 (막대 창이 좁아서 Windows 기본 메뉴로)

  const item = (text, action, enabled = true) => M.MenuItem.new({ text, action, enabled });
  const check = (text, checked, action) => M.CheckMenuItem.new({ text, checked, action });
  const sep = () => M.PredefinedMenuItem.new({ item: "Separator" });
  const popup = async (items) => (await M.Menu.new({ items: await Promise.all(items) })).popup();

  function settingsItems() {
    const edges = [["left", "왼쪽"], ["right", "오른쪽"], ["top", "위"], ["bottom", "아래"]];
    return [
      sub("막대 위치", edges.map(([e, n]) => check(n, bar.edge === e, () => setBar({ ...bar, edge: e })))),
      sub("아이콘 크기", [32, 40, 44, 52, 64].map((s) => check(`${s}px`, bar.size === s, () => setBar({ ...bar, size: s })))),
      check("막대 자리 비워 두기", !!bar.reserve, () => setBar({ ...bar, reserve: !bar.reserve })),
      sep(),
      item("막대 끄기", () => setBar({ ...bar, on: false })),
    ];
  }
  // Submenu.new 는 items 를 배열로 받아야 해서 풀어 줌
  async function sub(text, list) { return M.Submenu.new({ text, items: await Promise.all(list) }); }

  async function itemMenu(i) {
    const it = bar.items[i];
    const r = running.find((x) => norm(x.exe) === norm(it.target));
    const list = [item(r ? "앞으로 가져오기" : "실행", () => open(it))];
    if (r) {
      const wins = await invoke("app_windows", { pid: r.pid }).catch(() => []);
      if (wins.length) list.push(sub("열린 창", wins.slice(0, 12).map((w) => item((w.title || it.name).slice(0, 50), () => invoke("window_action", { hwnd: w.hwnd, action: "focus" })))));
      list.push(item("새 창", () => invoke("launch", { path: it.id })));
    }
    list.push(sep());
    if (i > 0) list.push(item(vertical() ? "위로" : "왼쪽으로", () => move(i, i - 1)));
    if (i < bar.items.length - 1) list.push(item(vertical() ? "아래로" : "오른쪽으로", () => move(i, i + 1)));
    list.push(item("파일 위치 열기", () => invoke("reveal", { path: it.id })));
    if (r) list.push(sep(), item("종료", () => invoke("quit_app", { pid: r.pid, force: false })), item("강제 종료", () => invoke("quit_app", { pid: r.pid, force: true })));
    list.push(sep(), item("막대에서 빼기", () => setBar({ ...bar, items: bar.items.filter((_, k) => k !== i) })));
    list.push(sep(), ...(await Promise.all(settingsItems().map((x) => x))));
    popup(list);
  }

  async function addMenu() {
    const has = (t) => bar.items.some((b) => norm(b.target) === norm(t));
    const add = (a) => setBar({ ...bar, items: [...bar.items, a] });
    const runList = running.filter((r) => !has(r.exe)).map((r) => item(r.name, () => add({ id: r.exe, name: r.name, target: r.exe })));
    const cats = (cfg.cats || []).map((c) => sub(c.name, c.items.filter((a) => !has(a.target || a.id)).map((a) => item(a.name, () => add({ id: a.id, name: a.name, target: a.target || a.id })))));
    popup([sub("실행 중", runList.length ? runList : [item("(없음)", null, false)]), ...(cats.length ? [sep(), ...cats] : [])]);
  }

  function move(from, to) {
    const items = [...bar.items];
    const [x] = items.splice(from, 1);
    items.splice(to, 0, x);
    setBar({ ...bar, items });
  }

  // MARK: 이벤트

  const root = $("#bar");
  root.addEventListener("click", (e) => {
    if (e.target.closest(".b-add")) { addMenu(); return; }
    const el = e.target.closest(".b-it");
    if (el) open(bar.items[+el.dataset.i]);
  });
  document.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const el = e.target.closest(".b-it");
    if (el) itemMenu(+el.dataset.i);
    else popup([item("앱 넣기…", addMenu), sep(), ...settingsItems()]);
  });

  // 끌기: 막대 안 → 순서, 막대 밖 → 빼기, 도구함 창에서 → 넣기
  let dragFrom = null;
  root.addEventListener("dragstart", (e) => {
    const el = e.target.closest(".b-it");
    if (!el) return;
    dragFrom = +el.dataset.i;
    e.dataTransfer.setData("text/plain", "bar:" + dragFrom);
    e.dataTransfer.effectAllowed = "move";
  });
  root.addEventListener("dragend", (e) => {
    const out = e.clientX < 0 || e.clientY < 0 || e.clientX > innerWidth || e.clientY > innerHeight;
    if (dragFrom != null && out && e.dataTransfer.dropEffect === "none") setBar({ ...bar, items: bar.items.filter((_, k) => k !== dragFrom) });
    dragFrom = null;
  });
  document.addEventListener("dragover", (e) => { e.preventDefault(); e.dataTransfer.dropEffect = dragFrom != null ? "move" : "copy"; });
  document.addEventListener("drop", (e) => {
    e.preventDefault();
    const data = e.dataTransfer.getData("text/plain") || "";
    const el = e.target.closest(".b-it");
    const at = el ? +el.dataset.i : bar.items.length;
    if (data.startsWith("bar:")) { const from = +data.slice(4); if (from !== at) move(from, Math.min(at, bar.items.length - 1)); return; }
    if (data.startsWith("mylauncher:")) {
      try {
        const a = JSON.parse(data.slice(11));
        if (bar.items.some((b) => norm(b.target) === norm(a.target))) return;
        const items = [...bar.items];
        items.splice(at, 0, a);
        setBar({ ...bar, items });
      } catch { /* 모르는 것 */ }
    }
  });

  onConfigChanged(async () => {
    cfg = await readConfig();
    const nb = { ...bar, ...(cfg.bar || {}) };
    const relayout = nb.edge !== bar.edge || nb.size !== bar.size || nb.reserve !== bar.reserve || nb.items.length !== bar.items.length;
    bar = nb;
    applyTheme(cfg);
    render();
    if (relayout) layout();
  });

  await applyTheme(cfg);
  render();
  await layout();
  poll();
  setInterval(poll, 3000);
})();
