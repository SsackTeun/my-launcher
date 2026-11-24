// 도구함 (Windows) — 화면은 src/ 의 웹 화면, 시스템 기능은 여기서
// win.rs   : 시작 메뉴 앱 · 아이콘 · 실행 · 실행 중 · 종료
// desk.rs  : 창 정리 · 앱별 창 · 작업 표시줄 · 메모리 · 자동 실행 · 막대 자리 비우기
// media.rs : 미니 플레이어(미디어 컨트롤) · 볼륨 · 청력 보호
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

#[cfg(windows)]
mod desk;
#[cfg(windows)]
mod media;
#[cfg(windows)]
mod update;
mod web;
#[cfg(windows)]
mod win;

/// 콘솔 창 없이 실행 (curl 같은 명령줄 도구를 부를 때 검은 창이 번쩍이지 않게)
#[cfg(windows)]
pub(crate) fn quiet(cmd: &mut std::process::Command) -> &mut std::process::Command {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000)
}

/// 시작 메뉴에 있는 앱 하나
#[derive(Serialize, Clone)]
pub struct InstalledApp {
    /// 바로가기(.lnk) 경로 — 도구함 안에서 앱을 가리키는 이름표
    pub id: String,
    pub name: String,
    /// 바로가기가 가리키는 실제 실행 파일 (실행 중인지 맞춰 볼 때 씀)
    pub target: String,
}

/// 실행 중인 앱 (창이 있는 것만, 실행 파일 단위로 묶음)
#[derive(Serialize, Clone)]
pub struct RunningApp {
    pub pid: u32,
    pub exe: String,
    pub name: String,
    pub title: String,
}

struct IconCache(Mutex<HashMap<String, String>>);

/// 트레이 메뉴의 앱 목록 (화면이 알려 줌)
#[derive(Deserialize, Clone)]
struct TrayApp {
    name: String,
    id: String,
}
struct TrayApps(Mutex<Vec<TrayApp>>);

static CLOSE_TO_TRAY: AtomicBool = AtomicBool::new(true);
/// 대표 창: 트레이 아이콘 · '도구함 열기' 가 띄우는 창. 플레이어 창만 쓰면 "player", 아니면 "main"
static FACE: Mutex<String> = Mutex::new(String::new());

fn face_label() -> String {
    let f = FACE.lock().unwrap().clone();
    if f.is_empty() { "main".into() } else { f }
}
/// 도구함이 작업 표시줄 자동 숨기기를 켰으면, 끌 때 원래대로 돌려놓음
static TASKBAR_RESTORE: Mutex<Option<bool>> = Mutex::new(None);

// MARK: 앱 · 아이콘 · 실행

#[tauri::command]
async fn installed_apps() -> Vec<InstalledApp> {
    tauri::async_runtime::spawn_blocking(win::installed_apps).await.unwrap_or_default()
}

/// 아이콘을 PNG(base64)로. 같은 경로는 한 번만 만듦
#[tauri::command]
fn icon(path: String, cache: tauri::State<IconCache>) -> Option<String> {
    if let Some(v) = cache.0.lock().ok()?.get(&path) {
        return Some(v.clone());
    }
    let png = win::icon_png_base64(&path);
    if let Some(v) = &png {
        cache.0.lock().ok()?.insert(path, v.clone());
    }
    png
}

#[tauri::command]
fn launch(path: String) -> Result<(), String> {
    win::open(&path)
}

#[tauri::command]
fn running_apps() -> Vec<RunningApp> {
    win::running_apps()
}

/// 실행 중인 앱의 창을 앞으로 (최소화돼 있으면 되살림)
#[tauri::command]
fn focus_app(pid: u32) -> bool {
    win::focus(pid)
}

/// 종료: 보통은 창을 닫으라고 부탁(저장 물어봄), force 면 바로 끔
#[tauri::command]
fn quit_app(pid: u32, force: bool) -> bool {
    win::quit(pid, force)
}

/// 아직 살아 있는지 (종료를 부탁한 뒤 응답 없으면 강제 종료를 권할 때)
#[tauri::command]
fn is_alive(pid: u32) -> bool {
    win::exe_of(pid).is_some()
}

/// 파일 탐색기에서 그 파일 위치 보기
#[tauri::command]
fn reveal(path: String) {
    let _ = quiet(std::process::Command::new("explorer").arg(format!("/select,{}", path))).spawn();
}

// MARK: 창 · 데스크탑 · 작업 표시줄

#[tauri::command]
fn app_windows(pid: u32) -> Vec<desk::WinInfo> {
    desk::app_windows(pid)
}

#[tauri::command]
fn window_action(hwnd: isize, action: String) -> bool {
    desk::window_action(hwnd, &action)
}

/// close_all · minimize_all · restore_all
#[tauri::command]
fn tidy(action: String) -> usize {
    desk::tidy(&action)
}


#[tauri::command]
fn taskbar_autohide(on: Option<bool>) -> bool {
    if let Some(v) = on {
        let mut r = TASKBAR_RESTORE.lock().unwrap();
        if v && r.is_none() {
            *r = Some(desk::taskbar_autohide(None));
        }
        if !v {
            *r = None;
        }
    }
    desk::taskbar_autohide(on)
}

#[tauri::command]
fn taskbar_pinned() -> Vec<InstalledApp> {
    desk::taskbar_pinned()
}

#[tauri::command]
async fn memory_usage() -> HashMap<String, u64> {
    tauri::async_runtime::spawn_blocking(desk::memory_usage).await.unwrap_or_default()
}

#[tauri::command]
fn autostart(on: Option<bool>) -> bool {
    desk::autostart(on)
}

#[tauri::command]
fn work_area_at(x: i32, y: i32) -> Option<desk::Area> {
    desk::work_area_at(x, y)
}

/// 자주 쓰는 앱 막대를 화면 가장자리에 붙임 (reserve 면 다른 창이 그 자리를 못 쓰게 예약)
#[tauri::command]
fn appbar(window: tauri::WebviewWindow, edge: String, thick: i32, length: Option<i32>, reserve: bool) -> Option<[i32; 4]> {
    let hwnd = window.hwnd().ok()?.0 as isize;
    desk::appbar_set(hwnd, &edge, thick, length.unwrap_or(0), reserve)
}

#[tauri::command]
fn appbar_release() {
    desk::appbar_remove_all();
}

// MARK: 미니 플레이어 · 볼륨 · 청력

#[tauri::command]
async fn media_state(site: Option<String>) -> media::MediaState {
    tauri::async_runtime::spawn_blocking(move || media::state(site)).await.unwrap_or_default()
}

#[tauri::command]
async fn media_thumb(site: Option<String>) -> Option<String> {
    tauri::async_runtime::spawn_blocking(move || media::thumbnail(site)).await.ok().flatten()
}

/// toggle · play · pause · next · prev · seek(초) · shuffle(0/1) · repeat(0 끔 / 1 한 곡 / 2 전체)
#[tauri::command]
async fn media_control(action: String, value: Option<f64>) -> bool {
    tauri::async_runtime::spawn_blocking(move || media::control(&action, value.unwrap_or(0.0))).await.unwrap_or(false)
}

/// 미니 플레이어: 도구함 재생기만(YouTube Music · YouTube · Netflix, 기본) / 모든 앱
#[tauri::command]
fn media_mode(app_only: bool) {
    media::set_app_only(app_only);
}

/// 사이트 창 페이지에서 함수를 돌려 결과 받기 (재생목록 · 다음 트랙 · 랜덤 재생목록 등)
#[tauri::command]
async fn site_call(app: tauri::AppHandle, site: String, body: String, args: Option<serde_json::Value>, timeout: Option<u64>) -> Result<serde_json::Value, String> {
    let a = args.unwrap_or(serde_json::Value::Null);
    tauri::async_runtime::spawn_blocking(move || web::call(&app, &site, &body, &a, timeout.unwrap_or(30)))
        .await
        .map_err(|e| e.to_string())?
}

/// 창 크기 바꾸기 (YouTube Music 휴대폰 크기 등, 논리 픽셀)
#[tauri::command]
fn window_resize(app: tauri::AppHandle, label: String, width: f64, height: f64) -> bool {
    app.get_webview_window(&label).map(|w| w.set_size(tauri::LogicalSize::new(width, height)).is_ok()).unwrap_or(false)
}

/// 미니 플레이어의 ‹ › — 다른 재생기 보기
#[tauri::command]
fn media_select(dir: i32) -> String {
    media::site_select(dir)
}

/// 지금 재생기 페이지에서 조작 (toggle · next · prev · seek · shuffle · repeat · like · pause · volume)
#[tauri::command]
fn site_control(app: tauri::AppHandle, site: String, action: String, value: Option<f64>) -> bool {
    let js = format!("window.__mlCtl && window.__mlCtl({:?}, {})", action, value.unwrap_or(0.0));
    app.get_webview_window(&site).map(|w| w.eval(&js).is_ok()).unwrap_or(false)
}

#[tauri::command]
async fn volume(set: Option<f64>) -> f64 {
    tauri::async_runtime::spawn_blocking(move || media::volume(set)).await.unwrap_or(0.0)
}

#[tauri::command]
fn hearing(on: Option<bool>, limit: Option<f64>, ear_max: Option<f64>) -> media::Hearing {
    media::hearing(on, limit, ear_max)
}

// MARK: 설정 파일

fn config_dir(app: &tauri::AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

#[tauri::command]
fn read_config(app: tauri::AppHandle) -> Option<String> {
    std::fs::read_to_string(config_dir(&app)?.join("config.json")).ok()
}

/// 저장하고 다른 창(떼어 낸 플레이어 · 막대)에도 알림
#[tauri::command]
fn write_config(app: tauri::AppHandle, json: String) -> bool {
    let ok = match config_dir(&app) {
        Some(p) => std::fs::write(p.join("config.json"), &json).is_ok(),
        None => false,
    };
    let _ = app.emit("config-changed", ());
    ok
}

/// 테마 배경 그림 (data URL 글자). set 이 빈칸이면 지움
#[tauri::command]
fn theme_image(app: tauri::AppHandle, set: Option<String>) -> Option<String> {
    let p = config_dir(&app)?.join("theme-image.txt");
    if let Some(v) = set {
        if v.is_empty() {
            let _ = std::fs::remove_file(&p);
        } else {
            let _ = std::fs::write(&p, v);
        }
        let _ = app.emit("config-changed", ());
    }
    std::fs::read_to_string(p).ok()
}

/// 가사(LRCLIB) · 번역을 받아 옴 — https 만. body 가 있으면 POST(폼)
#[tauri::command]
async fn http_fetch(url: String, body: Option<String>) -> Result<String, String> {
    if !url.starts_with("https://") {
        return Err("https 주소만 돼요".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let mut cmd = std::process::Command::new("curl.exe");
        quiet(&mut cmd).args(["-L", "-f", "-s", "--max-time", "15", "-A", "MyLauncher/1.0 (Windows)"]);
        if body.is_some() {
            cmd.args(["-H", "Content-Type: application/x-www-form-urlencoded;charset=utf-8", "--data-binary", "@-"]);
        }
        cmd.arg(&url).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        if let Some(b) = body {
            if let Some(mut si) = child.stdin.take() {
                let _ = si.write_all(b.as_bytes());
            }
        } else {
            drop(child.stdin.take());
        }
        let out = child.wait_with_output().map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(format!("받지 못했어요 ({})", out.status.code().unwrap_or(-1)));
        }
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

// MARK: 다른 창 (떼어 낸 플레이어 · 가사 · 막대 · YouTube Music · 영상)

/// url 이 http 로 시작하면 바깥 사이트, 아니면 도구함 화면(music.html 등)
#[tauri::command]
async fn open_window(
    app: tauri::AppHandle,
    label: String,
    url: String,
    title: String,
    width: f64,
    height: f64,
    x: Option<f64>,
    y: Option<f64>,
    frameless: Option<bool>,
    on_top: Option<bool>,
) -> Result<(), String> {
    // 거의 동시에 두 번 불려도 창이 둘 생기지 않게: '있나 보고 → 만들기' 를 한 번에 하나씩
    static OPENING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _guard = OPENING.lock().await;
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        return Ok(());
    }
    // 바깥 사이트(YouTube Music · YouTube · Netflix)는 사이트 창으로 (작은 창 단추 · 로그인 유지)
    if url.starts_with("https://") {
        return web::open_site(&app, &label, &url, &title, width, height);
    }
    let target = WebviewUrl::App(url.into());
    let frameless = frameless.unwrap_or(false);
    // 음악 · 가사 창: 도구함 창처럼 Windows 제목 막대 없이 (화면 위쪽 줄에 직접 그린 창 단추), 작업 표시줄엔 보임
    let app_style = !frameless && (label == "music" || label == "lyrics");
    let mut b = WebviewWindowBuilder::new(&app, &label, target)
        .title(title)
        .inner_size(width, height)
        .min_inner_size(if app_style { 360.0 } else { 120.0 }, if app_style { 260.0 } else { 40.0 })
        .decorations(!frameless && !app_style)
        .always_on_top(on_top.unwrap_or(false));
    if frameless {
        b = b.transparent(true).skip_taskbar(true).shadow(false);
    }
    if app_style {
        // 도구함 · 떼어 낸 플레이어와 같은 반투명 유리 (흐림)
        b = b.shadow(true).transparent(true).effects(
            tauri::window::EffectsBuilder::new().effect(tauri::window::Effect::Acrylic).build(),
        );
    }
    if let (Some(x), Some(y)) = (x, y) {
        b = b.position(x, y);
    }
    let w = b.build().map_err(|e| e.to_string())?;
    if app_style {
        if let Ok(h) = w.hwnd() {
            desk::round_corners(h.0 as isize);
            // 다른 창을 눌러도 흐린 배경 그대로 (도구함 창과 같게)
            desk::keep_backdrop_active(h.0 as isize);
        }
    }
    Ok(())
}

/// 창을 정말로 닫음 (숨기기로 바꿔 둔 YouTube Music 창도)
#[tauri::command]
fn close_window(app: tauri::AppHandle, label: String) {
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.destroy();
    }
}

#[tauri::command]
fn window_exists(app: tauri::AppHandle, label: String) -> bool {
    app.get_webview_window(&label).is_some()
}

/// 재생기 창 상태: 없음 · 보임 · 숨김(백그라운드에서 재생)
#[tauri::command]
fn window_state(app: tauri::AppHandle, label: String) -> &'static str {
    match app.get_webview_window(&label) {
        None => "none",
        Some(w) if w.is_visible().unwrap_or(false) && !w.is_minimized().unwrap_or(false) => "shown",
        Some(_) => "hidden",
    }
}

/// 재생기 단추 누르기: 없으면 열기 · 보이면 숨기기(백그라운드, 재생은 계속) · 숨겨져 있으면 앞으로
#[tauri::command]
fn window_toggle(app: tauri::AppHandle, label: String) -> &'static str {
    let Some(w) = app.get_webview_window(&label) else { return "none" };
    if w.is_visible().unwrap_or(false) && !w.is_minimized().unwrap_or(false) {
        let _ = w.hide();
        "hidden"
    } else {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        "shown"
    }
}

/// 바깥 사이트 창(YouTube Music 등)의 페이지에서 스크립트 실행 — 좋아요 누르기 같은 조작
#[tauri::command]
fn web_eval(app: tauri::AppHandle, label: String, js: String) -> bool {
    app.get_webview_window(&label).map(|w| w.eval(&js).is_ok()).unwrap_or(false)
}

/// 사이트 창을 항상 위 작은 창으로 / 원래대로
#[tauri::command]
fn web_pip(app: tauri::AppHandle, label: String, on: bool) -> bool {
    web::set_pip(&app, &label, on)
}

#[tauri::command]
fn web_pip_state(label: String) -> bool {
    web::is_pip(&label)
}

// MARK: 트레이 (Mac 판 메뉴 막대 🧰)

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window(&face_label()).or_else(|| app.get_webview_window("main")) {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn build_tray_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let apps = app.state::<TrayApps>().0.lock().unwrap().clone();
    let menu = Menu::new(app)?;
    if let Some(u) = app.state::<update::UpdateState>().0.lock().unwrap().clone() {
        menu.append(&MenuItem::with_id(app, "update", format!("⬆ 새 버전 {} 으로 업데이트", u.version), true, None::<&str>)?)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    menu.append(&MenuItem::with_id(app, "open", "도구함 열기", true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    if !apps.is_empty() {
        let sub = Submenu::new(app, "앱", true)?;
        for (i, a) in apps.iter().enumerate().take(60) {
            sub.append(&MenuItem::with_id(app, format!("app:{i}"), &a.name, true, None::<&str>)?)?;
        }
        menu.append(&sub)?;
        menu.append(&MenuItem::with_id(app, "launchall", "모두 실행", true, None::<&str>)?)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    if app.get_webview_window("ytmusic").is_some() {
        menu.append(&MenuItem::with_id(app, "ytmusic-show", "YouTube Music 창 보기", true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(app, "ytmusic-quit", "YouTube Music 끄기", true, None::<&str>)?)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    menu.append(&CheckMenuItem::with_id(app, "autostart", "로그인 시 자동 실행", true, desk::autostart(None), None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "checkupdate", format!("업데이트 확인 (지금 {})", app.package_info().version), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "restart", "도구함 다시 시작", true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "quit", "도구함 끝내기", true, None::<&str>)?)?;
    Ok(menu)
}

pub(crate) fn refresh_tray(app: &tauri::AppHandle) {
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("main"), build_tray_menu(app)) {
        let _ = tray.set_menu(Some(menu));
    }
}

#[tauri::command]
fn tray_apps(app: tauri::AppHandle, apps: Vec<TrayApp>) {
    *app.state::<TrayApps>().0.lock().unwrap() = apps;
    refresh_tray(&app);
}

/// 화면 쪽 오류를 개발 콘솔에 (npx tauri dev 로 켰을 때 보임)
#[tauri::command]
fn js_log(window: tauri::WebviewWindow, msg: String) {
    eprintln!("[{}] {}", window.label(), msg);
}

/// 대표 창 정하기 (플레이어 창만 쓰기 = "player")
#[tauri::command]
fn set_face(label: String) {
    *FACE.lock().unwrap() = label;
}

#[tauri::command]
fn set_close_to_tray(on: bool) {
    CLOSE_TO_TRAY.store(on, Ordering::Relaxed);
}

#[tauri::command]
fn restart_self(app: tauri::AppHandle) {
    cleanup();
    app.restart();
}

#[tauri::command]
fn quit_self(app: tauri::AppHandle) {
    cleanup();
    app.exit(0);
}

/// 끝날 때: 예약한 화면 자리 돌려주기 · 작업 표시줄 원래대로
pub(crate) fn cleanup() {
    desk::appbar_remove_all();
    if let Some(prev) = TASKBAR_RESTORE.lock().unwrap().take() {
        desk::taskbar_autohide(Some(prev));
    }
}

// MARK: 개발자 앱

/// 개발자 앱 받기: zip 을 내려받아 %LOCALAPPDATA%\Programs\<폴더> 에 풀고, 안의 exe 경로를 돌려줌
#[tauri::command]
async fn install_dev_app(url: String, folder: String, exe: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let base = std::env::var("LOCALAPPDATA").map_err(|_| "LOCALAPPDATA 를 찾지 못했어요".to_string())?;
        let dest = PathBuf::from(base).join("Programs").join(&folder);
        // Windows 10 이상에 기본으로 있는 curl.exe 로 내려받기
        let tmp = std::env::temp_dir().join(format!("mylauncher-{}.zip", std::process::id()));
        let st = quiet(&mut std::process::Command::new("curl.exe"))
            .args(["-L", "-f", "-s", "-A", "MyLauncher/1.0", "-o"])
            .arg(&tmp)
            .arg(&url)
            .status()
            .map_err(|e| format!("curl 을 실행하지 못했어요: {}", e))?;
        if !st.success() {
            return Err("내려받지 못했어요".into());
        }
        let bytes = std::fs::read(&tmp).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&tmp);
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|e| e.to_string())?;
        if dest.exists() {
            let _ = std::fs::remove_dir_all(&dest);
        }
        std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
        zip.extract(&dest).map_err(|e| e.to_string())?;
        let exe_path = dest.join(&exe);
        if !exe_path.exists() {
            return Err(format!("압축 안에 {} 이 없어요", exe));
        }
        Ok(exe_path.to_string_lossy().to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// 내려받은 개발자 앱의 버전 (같은 폴더의 version.txt)
#[tauri::command]
fn dev_app_version(folder: String) -> Option<String> {
    let base = std::env::var("LOCALAPPDATA").ok()?;
    let p = PathBuf::from(base).join("Programs").join(folder).join("version.txt");
    std::fs::read_to_string(p).ok().map(|s| s.trim().to_string())
}

#[tauri::command]
fn dev_app_path(folder: String, exe: String) -> Option<String> {
    let base = std::env::var("LOCALAPPDATA").ok()?;
    let p = PathBuf::from(base).join("Programs").join(folder).join(exe);
    p.exists().then(|| p.to_string_lossy().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // 하나만 켜지게: 이미 켜져 있으면 새로 켜지 않고, 켜져 있던 도구함의 대표 창(플레이어 창 등)을 앞으로
        // (맨 먼저 등록해야 두 번째 실행이 다른 일을 하기 전에 끝남)
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app);
        }))
        .manage(IconCache(Mutex::new(HashMap::new())))
        .manage(TrayApps(Mutex::new(Vec::new())))
        .manage(update::UpdateState(Mutex::new(None)))
        .setup(|app| {
            if let Some(dir) = config_dir(app.handle()) {
                media::start_hearing(dir);
            }
            // 제목 막대 없는 창: 둥근 모서리 · 다른 창을 눌러도 흐린 배경 그대로
            if let Some(w) = app.get_webview_window("main") {
                if let Ok(hw) = w.hwnd() {
                    desk::round_corners(hw.0 as isize);
                    desk::keep_backdrop_active(hw.0 as isize);
                }
            }
            let menu = build_tray_menu(app.handle())?;
            let mut tb = TrayIconBuilder::with_id("main")
                .tooltip("도구함")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, e| {
                    let id = e.id().as_ref().to_string();
                    match id.as_str() {
                        "open" => show_main(app),
                        "update" => {
                            let h = app.clone();
                            tauri::async_runtime::spawn(async move {
                                if let Err(e) = update::self_update(h.clone()).await {
                                    let _ = h.emit("update-none", format!("업데이트하지 못했어요: {e}"));
                                }
                            });
                        }
                        "checkupdate" => update::check(app, true),
                        "restart" => {
                            cleanup();
                            app.restart();
                        }
                        "quit" => {
                            cleanup();
                            app.exit(0);
                        }
                        "autostart" => {
                            desk::autostart(Some(!desk::autostart(None)));
                            refresh_tray(app);
                        }
                        "ytmusic-show" => {
                            if let Some(w) = app.get_webview_window("ytmusic") {
                                let _ = w.show();
                                let _ = w.unminimize();
                                let _ = w.set_focus();
                            }
                        }
                        "ytmusic-quit" => {
                            if let Some(w) = app.get_webview_window("ytmusic") {
                                let _ = w.destroy();
                            }
                        }
                        "launchall" => {
                            for a in app.state::<TrayApps>().0.lock().unwrap().iter() {
                                let _ = win::open(&a.id);
                            }
                        }
                        _ => {
                            if let Some(i) = id.strip_prefix("app:").and_then(|s| s.parse::<usize>().ok()) {
                                if let Some(a) = app.state::<TrayApps>().0.lock().unwrap().get(i) {
                                    let _ = win::open(&a.id);
                                }
                            }
                        }
                    }
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        let app = tray.app_handle();
                        if let Some(w) = app.get_webview_window(&face_label()).or_else(|| app.get_webview_window("main")) {
                            if w.is_visible().unwrap_or(false) && w.is_focused().unwrap_or(false) {
                                let _ = w.hide();
                            } else {
                                show_main(app);
                            }
                        }
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tb = tb.icon(icon.clone());
            }
            tb.build(app)?;
            update::start(app.handle());
            Ok(())
        })
        .on_window_event(|w, e| {
            if let tauri::WindowEvent::Destroyed = e {
                web::forget(w.label());
                if w.label() == "ytmusic" {
                    let h = w.app_handle().clone();
                    // 창이 다 없어진 뒤에 메뉴를 다시 만듦
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_millis(200));
                        refresh_tray(&h);
                    });
                }
            }
            if let tauri::WindowEvent::CloseRequested { api, .. } = e {
                if w.label() == "main" && (CLOSE_TO_TRAY.load(Ordering::Relaxed) || face_label() != "main") {
                    api.prevent_close();
                    let _ = w.hide();
                }
                // YouTube · Netflix 창: 영상 멈추고 숨기기 (다시 열면 보던 그대로, 끄기는 영상 메뉴)
                if web::close_requested(w.app_handle(), w.label()) {
                    api.prevent_close();
                }
                // YouTube Music 창은 닫아도 숨기기만 해서 노래가 계속 나옴 (끄기는 메뉴의 'YouTube Music 끄기')
                if w.label() == "ytmusic" {
                    api.prevent_close();
                    let _ = w.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            update::update_info,
            update::check_update,
            update::self_update,
            installed_apps,
            icon,
            launch,
            running_apps,
            focus_app,
            quit_app,
            is_alive,
            reveal,
            app_windows,
            window_action,
            tidy,
            taskbar_autohide,
            taskbar_pinned,
            memory_usage,
            autostart,
            work_area_at,
            appbar,
            appbar_release,
            media_state,
            media_thumb,
            media_control,
            media_mode,
            media_select,
            site_control,
            site_call,
            window_resize,
            volume,
            hearing,
            read_config,
            write_config,
            theme_image,
            http_fetch,
            open_window,
            close_window,
            window_exists,
            window_state,
            window_toggle,
            web_eval,
            web_pip,
            web_pip_state,
            tray_apps,
            js_log,
            set_close_to_tray,
            set_face,
            restart_self,
            quit_self,
            install_dev_app,
            dev_app_version,
            dev_app_path
        ])
        .build(tauri::generate_context!())
        .expect("도구함을 시작하지 못했어요")
        .run(|_app, e| {
            if let tauri::RunEvent::Exit = e {
                cleanup();
            }
        });
}
