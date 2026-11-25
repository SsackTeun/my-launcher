// 사이트 창 (YouTube Music · YouTube · Netflix): 도구함 안의 브라우저 창
// - 모든 사이트 창이 같은 브라우저 저장소(쿠키)를 써서 한 번 로그인하면 유지됨
// - 작은 창(PIP, Mac 판과 같은 방식): 같은 창을 제목 막대 없는 항상 위 작은 창으로 바꾸고 영상만 꽉 채움
//   조작 화면 · 단추는 페이지에 넣은 page.js 가 그림
// - 페이지 → 도구함 알림: https://mylauncher.invalid/<명령> 으로 이동하려 하면 막고 명령으로 처리
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

pub const MSG_HOST: &str = "mylauncher.invalid";
/// page.js 가 제목으로 알릴 때 붙이는 표시 (보이지 않는 글자 U+2063 + 이름)
const TITLE_MARK: &str = "\u{2063}mylauncher:";
const PAGE_JS: &str = include_str!("page.js");

#[derive(Clone, Copy, Default)]
struct PipState {
    on: bool,
    /// 작은 창으로 바꾸기 전 창 자리 (물리 픽셀 x, y, 폭, 높이)
    prev: Option<[i32; 4]>,
}

static PIP: Mutex<Option<HashMap<String, PipState>>> = Mutex::new(None);

fn with_state<R>(label: &str, f: impl FnOnce(&mut PipState) -> R) -> R {
    let mut g = PIP.lock().unwrap();
    f(g.get_or_insert_with(HashMap::new).entry(label.to_string()).or_default())
}

// MARK: 작은 창 자리 기억 (사이트마다, 다음에 켜도 그 자리)

fn pos_file(app: &tauri::AppHandle) -> Option<PathBuf> {
    Some(app.path().app_config_dir().ok()?.join("pip.json"))
}

fn saved_rect(app: &tauri::AppHandle, label: &str) -> Option<[i32; 4]> {
    let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(pos_file(app)?).ok()?).ok()?;
    let a = v.get(label)?.as_array()?;
    let n: Vec<i32> = a.iter().filter_map(|x| x.as_i64().map(|x| x as i32)).collect();
    (n.len() == 4 && n[2] > 100 && n[3] > 60).then(|| [n[0], n[1], n[2], n[3]])
}

fn save_rect(app: &tauri::AppHandle, label: &str, r: [i32; 4]) {
    let Some(p) = pos_file(app) else { return };
    let mut v: serde_json::Value = std::fs::read_to_string(&p).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_else(|| serde_json::json!({}));
    v[label] = serde_json::json!(r);
    let _ = std::fs::write(p, v.to_string());
}

fn rect_of(w: &tauri::WebviewWindow) -> Option<[i32; 4]> {
    let p = w.outer_position().ok()?;
    // 크기는 안쪽 크기로 저장 (되돌릴 때 set_size 가 안쪽 크기라서, 바깥 크기로 저장하면 창이 조금씩 커짐)
    let s = w.inner_size().ok()?;
    Some([p.x, p.y, s.width as i32, s.height as i32])
}

fn set_rect(w: &tauri::WebviewWindow, r: [i32; 4]) {
    let _ = w.set_size(tauri::PhysicalSize::new(r[2] as u32, r[3] as u32));
    let _ = w.set_position(tauri::PhysicalPosition::new(r[0], r[1]));
}

// MARK: 창 열기

/// 열려 있으면 앞으로, 없으면 새로 염
/// hidden: 창을 띄우지 않고 뒤에서만 열기 (크게 보기가 YouTube Music 을 쓸 때 — Mac 판의 숨은 페이지처럼)
pub fn open_site(app: &tauri::AppHandle, label: &str, url: &str, title: &str, width: f64, height: f64, hidden: bool) -> Result<(), String> {
    if let Some(w) = app.get_webview_window(label) {
        if hidden {
            return Ok(());
        }
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        return Ok(());
    }
    let target = WebviewUrl::External(url.parse().map_err(|e| format!("{e}"))?);
    let lbl = label.to_string();
    let app2 = app.clone();
    WebviewWindowBuilder::new(app, label, target)
        .title(title)
        .inner_size(width, height)
        .min_inner_size(200.0, 112.0)
        .visible(!hidden)
        .focused(!hidden)
        .initialization_script(PAGE_JS)
        .on_document_title_changed(move |w, title| {
            // page.js 가 보낸 알림: 제목 = 표시 + "명령?값=..."
            if let Some(rest) = title.strip_prefix(TITLE_MARK) {
                // 받았다고 바로 알려 줘야 페이지가 다음 알림을 보냄
                let _ = w.eval("window.__mlAck && window.__mlAck()");
                let rest = rest.split_once('|').map(|(_, r)| r).unwrap_or(rest);
                if let Ok(u) = format!("https://{MSG_HOST}/{rest}").parse::<tauri::Url>() {
                    let cmd = u.path().trim_start_matches('/').to_string();
                    let arg: HashMap<String, String> = u.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
                    let app3 = w.app_handle().clone();
                    let l = w.label().to_string();
                    let _ = app3.clone().run_on_main_thread(move || handle(&app3, &l, &cmd, &arg));
                }
            }
        })
        .on_navigation(move |u| {
            if u.host_str() == Some(MSG_HOST) {
                let cmd = u.path().trim_start_matches('/').to_string();
                let arg: HashMap<String, String> = u.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
                let (app3, l) = (app2.clone(), lbl.clone());
                // 끌기 · 크기 조절은 마우스를 누르고 있는 동안 시작해야 해서 바로 처리
                let _ = app3.clone().run_on_main_thread(move || handle(&app3, &l, &cmd, &arg));
                return false;
            }
            #[cfg(debug_assertions)]
            eprintln!("[{}] 이동 {}", lbl, u);
            true
        })
        .build()
        .map_err(|e| e.to_string())?;
    // 트레이 메뉴에 'YouTube Music 끄기' 가 생기게
    crate::refresh_tray(app);
    Ok(())
}

fn handle(app: &tauri::AppHandle, label: &str, cmd: &str, arg: &HashMap<String, String>) {
    let Some(w) = app.get_webview_window(label) else { return };
    let ar = arg.get("ar").and_then(|x| x.parse::<f64>().ok()).filter(|x| *x > 0.2 && *x < 6.0);
    match cmd {
        // 재생기 페이지의 지금 재생 (미니 플레이어 ‹ ›). 새로 재생을 시작했으면 다른 재생기는 일시정지
        "np" => {
            let g = |k: &str| arg.get(k).cloned().unwrap_or_default();
            let f = |k: &str| arg.get(k).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
            let now = crate::media::Now {
                title: g("t"),
                artist: g("a"),
                art: g("art"),
                playing: g("p") == "1",
                repeat: g("r"),
                like: g("l"),
                pos: f("pos"),
                dur: f("dur"),
                at: std::time::Instant::now(),
            };
            for other in crate::media::site_update(label, now, g("s") == "1") {
                if let Some(o) = app.get_webview_window(&other) {
                    let _ = o.eval("window.__mlCtl && window.__mlCtl('pause')");
                }
            }
        }
        // 함수 결과 조각 (site_call)
        "rpc" => {
            let g = |k: &str| arg.get(k).cloned().unwrap_or_default();
            let n = |k: &str| arg.get(k).and_then(|x| x.parse::<usize>().ok()).unwrap_or(0);
            rpc_piece(g("id").parse().unwrap_or(0), n("i"), n("n"), g("d"));
        }
        "pip-on" => enter(app, &w, label, ar.unwrap_or(16.0 / 9.0)),
        "pip-off" => exit(app, &w, label, true),
        // 작은 창의 ✕: 영상은 페이지가 멈추고, 창은 원래 모양으로 돌려서 숨김 (다시 열면 그대로)
        "pip-close" => {
            exit(app, &w, label, false);
            let _ = w.hide();
        }
        "pip-aspect" => {
            if let (Some(ar), Some(r)) = (ar, rect_of(&w)) {
                fit_aspect(&w, r, ar);
            }
        }
        "drag" => {
            let _ = w.start_dragging();
        }
        "resize" => {
            if let Ok(h) = w.hwnd() {
                crate::desk::start_resize(h.0 as isize, arg.get("d").map(String::as_str).unwrap_or("SouthEast"));
            }
        }
        _ => {
            #[cfg(debug_assertions)]
            eprintln!("[{}] 페이지 알림 {}", label, cmd);
        }
    }
}

/// 영상 비율로 높이 맞춤 (폭 그대로, 위쪽 고정). 세로 영상(쇼츠) ↔ 가로 영상이 바뀌면 긴 변 유지
fn fit_aspect(w: &tauri::WebviewWindow, r: [i32; 4], ar: f64) {
    let (mut cw, mut ch) = (r[2] as f64, r[3] as f64);
    if (ar < 1.0) != (cw < ch) {
        let long = cw.max(ch);
        if ar < 1.0 {
            cw = long * ar;
            ch = long;
        } else {
            cw = long;
            ch = long / ar;
        }
    } else {
        ch = cw / ar;
    }
    set_rect(w, [r[0], r[1], cw.round() as i32, ch.round() as i32]);
    // 끌어서 크기를 바꿔도 이 비율 그대로 (검은 여백 없게)
    if let Ok(h) = w.hwnd() {
        crate::desk::lock_aspect(h.0 as isize, Some(ar));
    }
}

fn enter(app: &tauri::AppHandle, w: &tauri::WebviewWindow, label: &str, ar: f64) {
    if with_state(label, |s| s.on) {
        return;
    }
    let prev = rect_of(w);
    with_state(label, |s| {
        s.on = true;
        s.prev = prev;
    });
    let _ = w.set_decorations(false);
    let _ = w.set_always_on_top(true);
    let _ = w.set_shadow(true);
    let rect = saved_rect(app, label).unwrap_or_else(|| {
        // 처음: 화면 오른쪽 아래, 폭 480 (논리 픽셀)
        let sf = w.scale_factor().unwrap_or(1.0);
        let (cw, ch) = ((480.0 * sf) as i32, (480.0 * sf / ar) as i32);
        let p = prev.unwrap_or([0, 0, 0, 0]);
        match crate::desk::work_area_at(p[0] + 40, p[1] + 40) {
            Some(a) => [a.x + a.w - cw - (20.0 * sf) as i32, a.y + a.h - ch - (20.0 * sf) as i32, cw, ch],
            None => [100, 100, cw, ch],
        }
    });
    fit_aspect(w, rect, ar);
    if let Ok(h) = w.hwnd() {
        crate::desk::round_corners(h.0 as isize);
    }
    let _ = w.show();
    let _ = w.eval("window.__mlSetPip && window.__mlSetPip(true)");
}

fn exit(app: &tauri::AppHandle, w: &tauri::WebviewWindow, label: &str, focus: bool) {
    let Some(prev) = with_state(label, |s| {
        if !s.on {
            return None;
        }
        s.on = false;
        Some(s.prev.take())
    }) else {
        return;
    };
    if let Some(r) = rect_of(w) {
        save_rect(app, label, r);
    }
    let _ = w.eval("window.__mlSetPip && window.__mlSetPip(false)");
    if let Ok(h) = w.hwnd() {
        crate::desk::lock_aspect(h.0 as isize, None);
    }
    let _ = w.set_always_on_top(false);
    let _ = w.set_decorations(true);
    if let Some(r) = prev {
        set_rect(w, r);
    }
    if focus {
        let _ = w.set_focus();
    }
}

/// 도구함 메뉴에서: 켜기는 페이지가 영상 비율을 재서 알려 줌, 끄기는 바로
pub fn set_pip(app: &tauri::AppHandle, label: &str, on: bool) -> bool {
    let Some(w) = app.get_webview_window(label) else { return false };
    if on {
        let _ = w.show();
        let _ = w.eval("window.__mlEnterPip && window.__mlEnterPip()");
    } else {
        exit(app, &w, label, true);
    }
    on
}

pub fn is_pip(label: &str) -> bool {
    PIP.lock().unwrap().as_ref().and_then(|m| m.get(label)).map(|s| s.on).unwrap_or(false)
}

/// YouTube · Netflix 창을 닫으면 (Mac 판처럼) 영상을 멈추고 숨기기만 — 다시 열면 보던 그대로
pub fn close_requested(app: &tauri::AppHandle, label: &str) -> bool {
    if label != "yt-video" && label != "netflix" {
        return false;
    }
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.eval("window.__mlPause && window.__mlPause()");
        crate::media::site_remove(label);
        exit(app, &w, label, false);
        let _ = w.hide();
    }
    true
}

/// 창을 닫으면 작은 창 상태도 잊음
pub fn forget(label: &str) {
    crate::media::site_remove(label);
    if let Some(m) = PIP.lock().unwrap().as_mut() {
        m.remove(label);
    }
}

// MARK: 페이지 함수 부르기 (도구함 → 페이지 → 결과)

use base64::Engine;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;

static RPC_ID: AtomicU64 = AtomicU64::new(1);
static RPC: Mutex<Option<HashMap<u64, (Vec<Option<String>>, mpsc::Sender<String>)>>> = Mutex::new(None);

fn rpc_piece(id: u64, i: usize, n: usize, d: String) {
    let mut g = RPC.lock().unwrap();
    let map = g.get_or_insert_with(HashMap::new);
    let Some((parts, _)) = map.get_mut(&id) else { return };
    if parts.len() != n.max(1) {
        *parts = vec![None; n.max(1)];
    }
    if i < parts.len() {
        parts[i] = Some(d);
    }
    if parts.iter().all(|p| p.is_some()) {
        let (parts, tx) = map.remove(&id).unwrap();
        let joined: String = parts.into_iter().map(|p| p.unwrap()).collect();
        let text = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(joined.as_bytes())
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .unwrap_or_else(|| r#"{"ok":false,"e":"결과를 못 읽음"}"#.into());
        let _ = tx.send(text);
    }
}

/// 사이트 창 페이지에서 body(비동기 함수 본문)를 돌려 결과를 받음. body 안에서 args · api · collect · nextToken · albumList 를 씀
pub fn call(app: &tauri::AppHandle, label: &str, body: &str, args: &serde_json::Value, timeout_s: u64) -> Result<serde_json::Value, String> {
    let w = app.get_webview_window(label).ok_or("창이 없어요")?;
    let id = RPC_ID.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel();
    RPC.lock().unwrap().get_or_insert_with(HashMap::new).insert(id, (vec![None], tx));
    let js = format!(
        "window.__mlRun ? window.__mlRun({id}, async (args) => {{ const {{ api, collect, nextToken, albumList }} = window.__mlApi || {{}}; {body}\n}}, {args}) : document.title = '\\u2063mylauncher:0|rpc?id={id}&i=0&n=1&d=' + btoa(unescape(encodeURIComponent(JSON.stringify({{ok:false,e:'페이지가 아직 준비 안 됨'}})))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'')"
    );
    w.eval(&js).map_err(|e| e.to_string())?;
    let r = rx.recv_timeout(std::time::Duration::from_secs(timeout_s));
    if r.is_err() {
        RPC.lock().unwrap().as_mut().map(|m| m.remove(&id));
    }
    let text = r.map_err(|_| "시간 안에 답이 없어요".to_string())?;
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    if v["ok"].as_bool() == Some(true) {
        Ok(v["v"].clone())
    } else {
        Err(v["e"].as_str().unwrap_or("실패").to_string())
    }
}
