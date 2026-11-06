// 도구함 (Windows) — 화면은 src/ 의 웹 화면, 시스템 기능(앱 찾기 · 아이콘 · 실행 · 실행 중 · 종료)은 여기서
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::Manager;

#[cfg(windows)]
mod win;

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

#[tauri::command]
fn installed_apps() -> Vec<InstalledApp> {
    #[cfg(windows)]
    {
        win::installed_apps()
    }
    #[cfg(not(windows))]
    {
        Vec::new()
    }
}

/// 아이콘을 PNG(base64)로. 같은 경로는 한 번만 만듦
#[tauri::command]
fn icon(path: String, cache: tauri::State<IconCache>) -> Option<String> {
    if let Some(v) = cache.0.lock().ok()?.get(&path) {
        return Some(v.clone());
    }
    #[cfg(windows)]
    let png = win::icon_png_base64(&path);
    #[cfg(not(windows))]
    let png: Option<String> = None;
    if let Some(v) = &png {
        cache.0.lock().ok()?.insert(path, v.clone());
    }
    png
}

#[tauri::command]
fn launch(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        win::open(&path)
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        Err("Windows 에서만 돼요".into())
    }
}

#[tauri::command]
fn running_apps() -> Vec<RunningApp> {
    #[cfg(windows)]
    {
        win::running_apps()
    }
    #[cfg(not(windows))]
    {
        Vec::new()
    }
}

/// 실행 중인 앱의 창을 앞으로 (최소화돼 있으면 되살림)
#[tauri::command]
fn focus_app(pid: u32) -> bool {
    #[cfg(windows)]
    {
        win::focus(pid)
    }
    #[cfg(not(windows))]
    {
        let _ = pid;
        false
    }
}

/// 종료: 보통은 창을 닫으라고 부탁(저장 물어봄), force 면 바로 끔
#[tauri::command]
fn quit_app(pid: u32, force: bool) -> bool {
    #[cfg(windows)]
    {
        win::quit(pid, force)
    }
    #[cfg(not(windows))]
    {
        let _ = (pid, force);
        false
    }
}

/// 파일 탐색기에서 그 파일 위치 보기
#[tauri::command]
fn reveal(path: String) {
    let _ = std::process::Command::new("explorer").arg(format!("/select,{}", path)).spawn();
}

fn config_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    let dir = app.path().app_config_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("config.json"))
}

#[tauri::command]
fn read_config(app: tauri::AppHandle) -> Option<String> {
    std::fs::read_to_string(config_path(&app)?).ok()
}

#[tauri::command]
fn write_config(app: tauri::AppHandle, json: String) -> bool {
    match config_path(&app) {
        Some(p) => std::fs::write(p, json).is_ok(),
        None => false,
    }
}

/// 개발자 앱 받기: zip 을 내려받아 %LOCALAPPDATA%\Programs\<폴더> 에 풀고, 안의 exe 경로를 돌려줌
#[tauri::command]
async fn install_dev_app(url: String, folder: String, exe: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let base = std::env::var("LOCALAPPDATA").map_err(|_| "LOCALAPPDATA 를 찾지 못했어요".to_string())?;
        let dest = PathBuf::from(base).join("Programs").join(&folder);
        // Windows 10 이상에 기본으로 있는 curl.exe 로 내려받기
        let tmp = std::env::temp_dir().join(format!("mylauncher-{}.zip", std::process::id()));
        let st = std::process::Command::new("curl.exe")
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
        .manage(IconCache(Mutex::new(HashMap::new())))
        .invoke_handler(tauri::generate_handler![
            installed_apps,
            icon,
            launch,
            running_apps,
            focus_app,
            quit_app,
            reveal,
            read_config,
            write_config,
            install_dev_app,
            dev_app_version,
            dev_app_path
        ])
        .run(tauri::generate_context!())
        .expect("도구함을 시작하지 못했어요");
}
