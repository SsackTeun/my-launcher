// 도구함 자체 업데이트 (Mac 판 update.swift 와 같은 일)
// - 켤 때(20초 뒤)와 6시간마다 GitHub Releases 에서 win-v… 중 가장 높은 버전을 확인
// - 새 버전이 있으면 트레이 메뉴 맨 위 '새 버전 … 업데이트' + 창들에 'update-available' 알림
// - 업데이트: 설치판(Setup)으로 깐 거면 새 Setup.exe 를 조용히(/P) 실행, zip 으로 받은 거면 새 zip 을 풀어 덮어씀.
//   도구함이 꺼진 뒤에 바꿔야 해서 작은 배치 파일이 끝나기를 기다렸다가 바꾸고 다시 켬
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Emitter, Manager};

const REPO: &str = "SsackTeun/my-launcher";
const SETUP: &str = "Launcher-Windows-Setup.exe";
const ZIP: &str = "Launcher-Windows.zip";

#[derive(Serialize, Clone, Default)]
pub struct UpdateInfo {
    pub version: String,
    pub current: String,
    pub notes: String,
    #[serde(skip)]
    pub setup_url: String,
    #[serde(skip)]
    pub zip_url: String,
}

pub struct UpdateState(pub Mutex<Option<UpdateInfo>>);

/// "0.10.1" > "0.9.3" 처럼 숫자로
fn newer(a: &str, b: &str) -> bool {
    let p = |s: &str| s.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (x, y) = (p(a), p(b));
    for i in 0..x.len().max(y.len()) {
        let (m, n) = (*x.get(i).unwrap_or(&0), *y.get(i).unwrap_or(&0));
        if m != n {
            return m > n;
        }
    }
    false
}

fn curl_text(url: &str) -> Option<String> {
    let out = crate::quiet(&mut std::process::Command::new("curl.exe"))
        .args(["-L", "-f", "-s", "--max-time", "20", "-A", "MyLauncher/1.0", "-H", "Accept: application/vnd.github+json", url])
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

/// win-v… 릴리스 중 가장 높은 버전 (설치 파일 · zip 주소 포함)
fn newest(current: &str) -> Option<UpdateInfo> {
    let body = curl_text(&format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))?;
    let arr: Vec<serde_json::Value> = serde_json::from_str(&body).ok()?;
    let mut best: Option<UpdateInfo> = None;
    for r in arr {
        let tag = r["tag_name"].as_str().unwrap_or("");
        let Some(ver) = tag.strip_prefix("win-v") else { continue };
        if r["draft"].as_bool() == Some(true) || r["prerelease"].as_bool() == Some(true) {
            continue;
        }
        let url_of = |name: &str| {
            r["assets"].as_array().and_then(|a| a.iter().find(|x| x["name"].as_str() == Some(name)))
                .and_then(|x| x["browser_download_url"].as_str()).unwrap_or("").to_string()
        };
        let (setup_url, zip_url) = (url_of(SETUP), url_of(ZIP));
        if setup_url.is_empty() && zip_url.is_empty() {
            continue;
        }
        if best.as_ref().map_or(true, |b| newer(ver, &b.version)) {
            best = Some(UpdateInfo {
                version: ver.to_string(),
                current: current.to_string(),
                notes: r["body"].as_str().unwrap_or("").chars().take(400).collect(),
                setup_url,
                zip_url,
            });
        }
    }
    best
}

/// 확인해서 상태 · 트레이 메뉴를 바꾸고 창들에 알림 (manual: 직접 눌렀으면 '최신이에요'도 알림)
pub fn check(app: &tauri::AppHandle, manual: bool) {
    let app = app.clone();
    std::thread::spawn(move || {
        let current = app.package_info().version.to_string();
        let found = newest(&current);
        let avail = found.clone().filter(|u| newer(&u.version, &current));
        *app.state::<UpdateState>().0.lock().unwrap() = avail.clone();
        crate::refresh_tray(&app);
        if let Some(tray) = app.tray_by_id("main") {
            let tip = avail.as_ref().map_or("도구함".to_string(), |u| format!("도구함 — 새 버전 {} 이 있어요", u.version));
            let _ = tray.set_tooltip(Some(tip));
        }
        match &avail {
            Some(u) => {
                let _ = app.emit("update-available", u.clone());
            }
            None if manual => {
                let msg = if found.is_some() { format!("최신 버전이에요 ({current})") } else { "새 버전을 확인하지 못했어요 (인터넷 확인)".into() };
                let _ = app.emit("update-none", msg);
            }
            None => {}
        }
    });
}

/// 켤 때 20초 뒤, 그다음 6시간마다
pub fn start(app: &tauri::AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(20));
        loop {
            check(&app, false);
            std::thread::sleep(std::time::Duration::from_secs(6 * 3600));
        }
    });
}

#[tauri::command]
pub fn update_info(app: tauri::AppHandle) -> Option<UpdateInfo> {
    app.state::<UpdateState>().0.lock().unwrap().clone()
}

#[tauri::command]
pub fn check_update(app: tauri::AppHandle) {
    check(&app, true);
}

fn download(url: &str, to: &PathBuf) -> Result<(), String> {
    let st = crate::quiet(&mut std::process::Command::new("curl.exe"))
        .args(["-L", "-f", "-s", "-A", "MyLauncher/1.0", "-o"])
        .arg(to)
        .arg(url)
        .status()
        .map_err(|e| format!("curl 을 실행하지 못했어요: {e}"))?;
    if st.success() { Ok(()) } else { Err("내려받지 못했어요".into()) }
}

/// 받아서 바꿔 끼우고 다시 켬 (도구함은 바로 꺼짐)
#[tauri::command]
pub async fn self_update(app: tauri::AppHandle) -> Result<(), String> {
    let info = app.state::<UpdateState>().0.lock().unwrap().clone().ok_or("새 버전이 없어요")?;
    let app2 = app.clone();
    tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let dir = exe.parent().ok_or("설치 폴더를 찾지 못했어요")?.to_path_buf();
        let tmp = std::env::temp_dir().join(format!("mylauncher-update-{}", info.version));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
        // zip 으로 받은 도구함(같은 폴더에 version.txt)이면 zip, 아니면 설치 파일
        let zip_mode = dir.join("version.txt").exists() && !info.zip_url.is_empty() || info.setup_url.is_empty();
        let pid = std::process::id();
        // 경로는 배치 파일에 직접 쓰지 않고 환경 변수로 넘김: cmd 는 배치 파일을 한국어 코드 페이지(949)로 읽어서
        // UTF-8 로 쓴 '도구함' 같은 한글 경로가 깨짐 (환경 변수는 유니코드 그대로 전달됨)
        let mut vars: Vec<(&str, std::ffi::OsString)> = vec![("ML_EXE", exe.clone().into_os_string())];
        let step = if zip_mode {
            let zip_path = tmp.join(ZIP);
            download(&info.zip_url, &zip_path)?;
            let bytes = std::fs::read(&zip_path).map_err(|e| e.to_string())?;
            let out = tmp.join("files");
            zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|e| e.to_string())?
                .extract(&out).map_err(|e| e.to_string())?;
            vars.push(("ML_SRC", out.into_os_string()));
            vars.push(("ML_DIR", dir.clone().into_os_string()));
            "robocopy \"%ML_SRC%\" \"%ML_DIR%\" /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP >nul".to_string()
        } else {
            let setup = tmp.join(SETUP);
            download(&info.setup_url, &setup)?;
            vars.push(("ML_SETUP", setup.into_os_string()));
            // /P: 묻지 않고 진행 막대만 보이게
            "\"%ML_SETUP%\" /P".to_string()
        };
        let script = tmp.join("update.cmd");
        let body = format!(
            "@echo off\r\n:wait\r\ntasklist /FI \"PID eq {pid}\" 2>nul | find \"{pid}\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n{step}\r\nstart \"\" \"%ML_EXE%\"\r\n"
        );
        std::fs::write(&script, body).map_err(|e| e.to_string())?;
        crate::quiet(&mut std::process::Command::new("cmd"))
            .envs(vars)
            .arg("/C")
            .arg(&script)
            .spawn()
            .map_err(|e| format!("업데이트를 시작하지 못했어요: {e}"))?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())??;
    crate::cleanup();
    app2.exit(0);
    Ok(())
}
