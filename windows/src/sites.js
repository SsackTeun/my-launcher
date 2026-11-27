// 재생기 단추 (YouTube Music · YouTube · Netflix 실제 아이콘) — 도구함 창 맨 위 줄 · 떼어 낸 플레이어가 같이 씀
// 누르기: 열기 · 보이면 숨기기(백그라운드에서 계속 재생) · 숨겨져 있으면 앞으로
// Shift+누르기: PIP · 오른쪽 클릭: 메뉴 · 초록 점: 보이는 중 · 빈 고리: 백그라운드 · PIP 표시: 작은 창
"use strict";

const Sites = (() => {
  const LIST = [
    { label: "ytmusic", name: "YouTube Music", url: "https://music.youtube.com", w: 1100, h: 760, icon: "https://music.youtube.com/img/favicon_144.png", letter: "♪", color: "#ff0033" },
    { label: "yt-video", name: "YouTube", url: "https://www.youtube.com", w: 1100, h: 720, icon: "https://www.youtube.com/favicon.ico", letter: "▶", color: "#ff0033" },
    { label: "netflix", name: "Netflix", url: "https://www.netflix.com", w: 1100, h: 720, icon: "https://assets.nflxext.com/us/ffe/siteui/common/icons/nficon2016.png", letter: "N", color: "#e50914" },
  ];
  const open = {};
  const pip = {};
  /// 숨겨져(백그라운드) 있는지
  const hidden = {};
  const mounts = [];
  const subs = [];

  function html() {
    return LIST.map((s) => {
      const o = open[s.label], p = pip[s.label], hd = hidden[s.label];
      const now = !o ? "" : hd ? " — 백그라운드에서 재생 중" : p ? " — 작은 창(PIP)" : " — 보이는 중";
      const tip = `${s.name}${now}\n누르기: ${!o ? "열기" : hd ? "앞으로 가져오기" : "숨기기 (백그라운드에서 계속 재생)"}${s.label === "ytmusic" ? "" : " · Shift+누르기: PIP"} · 오른쪽 클릭: 메뉴`;
      return `<button class="site ${o ? "open" : ""} ${hd ? "bg" : ""}" data-site="${s.label}" title="${esc(tip)}">
        <img src="${s.icon}" alt="" referrerpolicy="no-referrer" data-letter="${s.letter}" data-color="${s.color}">
        ${o ? '<span class="site-dot"></span>' : ""}${p ? '<span class="site-pip">PIP</span>' : ""}</button>`;
    }).join("");
  }
  function draw() {
    for (const { el } of mounts) {
      el.innerHTML = html();
      // 아이콘을 못 받으면 (인터넷 안 됨) 색 글자로
      el.querySelectorAll("img[data-letter]").forEach((img) => {
        img.onerror = () => {
          const s = document.createElement("span");
          s.className = "site-l";
          s.textContent = img.dataset.letter;
          s.style.background = img.dataset.color;
          img.replaceWith(s);
        };
      });
    }
  }

  async function poll() {
    let changed = false;
    for (const s of LIST) {
      const st = await invoke("window_state", { label: s.label }).catch(() => "none");
      const o = st !== "none", hd = st === "hidden";
      const p = o && s.label !== "ytmusic" ? await invoke("web_pip_state", { label: s.label }).catch(() => false) : false;
      if (o !== !!open[s.label] || p !== !!pip[s.label] || hd !== !!hidden[s.label]) changed = true;
      open[s.label] = o;
      pip[s.label] = p;
      hidden[s.label] = hd;
    }
    if (changed || mounts.some(({ el }) => !el.children.length)) { draw(); subs.forEach((f) => f()); }
  }

  const find = (label) => LIST.find((x) => x.label === label);
  // 켜진 배치 프리셋의 YouTube · Netflix 자리 (music.js 가 저장) — 나중에 연 창 · PIP 로 바꾼 창도 그 자리로 (Mac 과 같음)
  function presetRect(label, mini) {
    try {
      const key = JSON.parse(localStorage.getItem("mzActivePr") || "null");
      if (!key || (label !== "yt-video" && label !== "netflix")) return null;
      const pr = JSON.parse(localStorage.getItem("mzPresets") || "[]").find((p) => (p.id || p.name) === key);
      const v = pr && pr[label === "yt-video" ? "yt" : "nf"];
      return (v && (mini ? v.mini : v.main)) || null;
    } catch { return null; }
  }
  async function placeAt(label, r) {
    if (!r) return;
    try {
      const w = await window.__TAURI__?.webviewWindow?.WebviewWindow?.getByLabel?.(label);
      const dpi = window.__TAURI__.dpi;
      await w?.setSize(new dpi.LogicalSize(r.w, r.h)); await w?.setPosition(new dpi.LogicalPosition(r.x, r.y));
    } catch { /* 없음 */ }
  }
  function openWin(s) {
    const isNew = !open[s.label];
    return invoke("open_window", { label: s.label, url: s.url, title: s.name, width: s.w, height: s.h })
      .then(() => { if (isNew) placeAt(s.label, presetRect(s.label, false)); setTimeout(poll, 500); })
      .catch((e) => toast(String(e)));
  }
  async function togglePip(s) {
    if (s.label === "ytmusic") { toast("YouTube Music 은 PIP 가 없어요"); return; }
    if (!open[s.label]) { await openWin(s); toast("영상을 연 뒤 다시 Shift+누르기 하면 PIP 예요"); return; }
    const on = !pip[s.label];
    await invoke("web_pip", { label: s.label, on });
    if (on) setTimeout(() => placeAt(s.label, presetRect(s.label, true)), 400);   // 작은 창이 된 뒤 프리셋 자리로
    setTimeout(poll, 600);
  }
  function closeWin(s) { return invoke("close_window", { label: s.label }).then(() => setTimeout(poll, 300)); }

  /// 오른쪽 클릭 메뉴 항목 (도구함 창 메뉴 · Windows 기본 메뉴 둘 다 이 모양을 씀)
  function menuItems(s) {
    const o = open[s.label];
    const items = [{ label: o ? `${s.name} 앞으로` : `${s.name} 열기`, action: () => openWin(s) }];
    if (o && !hidden[s.label]) items.push({ label: "숨기기 (백그라운드에서 계속 재생)", action: () => invoke("window_toggle", { label: s.label }).then(() => setTimeout(poll, 200)) });
    if (s.label !== "ytmusic") items.push({ label: "PIP (항상 위 작은 창)", checked: !!pip[s.label], action: () => togglePip(s) });
    // YouTube Music: 휴대폰 크기 창 (Mac 판 옵션) — 좁은 화면 모양으로 바뀜
    if (s.label === "ytmusic" && o) {
      let phone = false;
      try { phone = localStorage.getItem("ymPhone") === "1"; } catch { /* 없음 */ }
      items.push({ label: "휴대폰 크기 창", checked: phone, action: () => {
        try { localStorage.setItem("ymPhone", phone ? "0" : "1"); } catch { /* 없음 */ }
        invoke("window_resize", { label: "ytmusic", width: phone ? 1100 : 420, height: phone ? 760 : 820 });
      } });
    }
    if (o) items.push("-", { label: s.label === "ytmusic" ? `${s.name} 끄기 (노래 멈춤)` : `${s.name} 끄기`, action: () => closeWin(s) });
    return items;
  }

  /// Windows 기본 메뉴로 띄우기 (작은 창이라 화면 안 메뉴가 안 들어갈 때)
  async function nativeMenu(items) {
    const M = T.menu;
    const made = await Promise.all(items.map((it) =>
      it === "-" ? M.PredefinedMenuItem.new({ item: "Separator" })
        : it.checked !== undefined ? M.CheckMenuItem.new({ text: it.label, checked: it.checked, action: it.action })
          : M.MenuItem.new({ text: it.label, action: it.action })));
    (await M.Menu.new({ items: made })).popup();
  }

  /// el 안에 단추를 그림. showMenu(x, y, items) 가 없으면 Windows 기본 메뉴
  function mount(el, showMenu) {
    mounts.push({ el });
    el.addEventListener("click", (e) => {
      const b = e.target.closest("[data-site]");
      if (!b) return;
      const s = find(b.dataset.site);
      if (e.shiftKey) togglePip(s);
      else if (!open[s.label]) openWin(s);
      // 열려 있으면: 보이면 숨기기 · 숨겨져 있으면 앞으로
      else invoke("window_toggle", { label: s.label }).then(() => setTimeout(poll, 200));
    });
    el.addEventListener("contextmenu", (e) => {
      const b = e.target.closest("[data-site]");
      if (!b) return;
      e.preventDefault();
      e.stopPropagation();
      const items = menuItems(find(b.dataset.site));
      if (showMenu) { const r = b.getBoundingClientRect(); showMenu(r.left, r.bottom + 4, items); } else nativeMenu(items);
    });
    draw();
    if (mounts.length === 1) { poll(); setInterval(poll, 2000); }
  }

  return { mount, poll, open, pip, onChange: (f) => subs.push(f) };
})();
