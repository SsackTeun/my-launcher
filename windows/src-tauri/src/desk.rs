// 창 · 데스크탑 · 작업 표시줄 기능 (Mac 판의 창 정리 · 앱별 창 메뉴 · 데스크탑 탭 · Dock 가리기 · 메모리 · 막대 자리 비우기)
use crate::win::{exe_of, file_description, wide, windows_list_all, WinRec};
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use windows::core::{GUID, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND};
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX};
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegGetValueW, RegOpenKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE,
    REG_SZ, RRF_RT_REG_BINARY, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ};
use windows::Win32::UI::Shell::{
    SHAppBarMessage, ABE_BOTTOM, ABE_LEFT, ABE_RIGHT, ABE_TOP, ABM_GETSTATE, ABM_NEW, ABM_QUERYPOS, ABM_REMOVE,
    ABM_SETPOS, ABM_SETSTATE, APPBARDATA,
};
use windows::Win32::UI::WindowsAndMessaging::{
    IsIconic, PostMessageW, SetForegroundWindow, SetWindowPos, ShowWindow, SWP_NOACTIVATE, SWP_NOZORDER, SW_MINIMIZE,
    SW_RESTORE, WM_CLOSE, WM_NCACTIVATE, WM_SIZING, WM_USER,
};

const ABS_AUTOHIDE: u32 = 0x1;
const ABS_ALWAYSONTOP: u32 = 0x2;

fn h(v: isize) -> HWND {
    HWND(v as *mut c_void)
}

// MARK: 창 하나

#[derive(Serialize, Clone)]
pub struct WinInfo {
    pub hwnd: isize,
    pub pid: u32,
    pub title: String,
    pub minimized: bool,
    /// 이 창이 있는 데스크탑 (GUID 문자열, 모르면 빈칸)
    pub desktop: String,
}

fn info(r: &WinRec) -> WinInfo {
    WinInfo {
        hwnd: r.hwnd.0 as isize,
        pid: r.pid,
        title: r.title.clone(),
        minimized: unsafe { IsIconic(r.hwnd).as_bool() },
        desktop: r.desktop.clone(),
    }
}

/// 그 앱(같은 실행 파일)의 창 목록 — 다른 데스크탑에 있는 창까지
pub fn app_windows(pid: u32) -> Vec<WinInfo> {
    let Some(exe) = exe_of(pid) else { return Vec::new() };
    let exe = exe.to_lowercase();
    let mut cache: HashMap<u32, String> = HashMap::new();
    windows_list_all()
        .iter()
        .filter(|r| {
            let e = cache.entry(r.pid).or_insert_with(|| exe_of(r.pid).unwrap_or_default().to_lowercase());
            *e == exe
        })
        .map(info)
        .collect()
}

pub fn window_action(hwnd: isize, action: &str) -> bool {
    let w = h(hwnd);
    unsafe {
        match action {
            "focus" => {
                if IsIconic(w).as_bool() {
                    let _ = ShowWindow(w, SW_RESTORE);
                }
                SetForegroundWindow(w).as_bool()
            }
            "minimize" => ShowWindow(w, SW_MINIMIZE).as_bool(),
            "restore" => ShowWindow(w, SW_RESTORE).as_bool(),
            "close" => PostMessageW(w, WM_CLOSE, WPARAM(0), LPARAM(0)).is_ok(),
            _ => false,
        }
    }
}

// MARK: 창 정리 (지금 데스크탑의 창만, 도구함 · 바탕화면 제외)

pub fn tidy(action: &str) -> usize {
    let me = std::process::id();
    let mut n = 0;
    for r in windows_list_all() {
        if r.pid == me || !r.on_current {
            continue;
        }
        let minimized = unsafe { IsIconic(r.hwnd).as_bool() };
        let ok = unsafe {
            match action {
                "close_all" => PostMessageW(r.hwnd, WM_CLOSE, WPARAM(0), LPARAM(0)).is_ok(),
                "minimize_all" if !minimized => {
                    let _ = ShowWindow(r.hwnd, SW_MINIMIZE);
                    true
                }
                "restore_all" if minimized => {
                    let _ = ShowWindow(r.hwnd, SW_RESTORE);
                    true
                }
                _ => false,
            }
        };
        if ok {
            n += 1;
        }
    }
    n
}

// MARK: 데스크탑 (가상 데스크톱) — 목록 · 이름은 레지스트리에서 읽기만

#[derive(Serialize)]
pub struct Desktop {
    pub id: String,
    pub name: String,
}

#[derive(Serialize)]
pub struct DeskApp {
    pub pid: u32,
    pub hwnd: isize,
    pub exe: String,
    pub name: String,
    pub title: String,
}

#[derive(Serialize)]
pub struct Desktops {
    pub current: String,
    pub list: Vec<Desktop>,
    /// 데스크탑 id → 그 데스크탑의 앱 (실행 파일 단위)
    pub apps: HashMap<String, Vec<DeskApp>>,
}

pub fn guid_str(g: &GUID) -> String {
    format!("{:?}", g).to_lowercase()
}

fn reg_binary(key: &str, value: &str) -> Option<Vec<u8>> {
    unsafe {
        let k = wide(key);
        let v = wide(value);
        let mut size = 0u32;
        RegGetValueW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), PCWSTR(v.as_ptr()), RRF_RT_REG_BINARY, None, None, Some(&mut size)).ok().ok()?;
        let mut buf = vec![0u8; size as usize];
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(k.as_ptr()),
            PCWSTR(v.as_ptr()),
            RRF_RT_REG_BINARY,
            None,
            Some(buf.as_mut_ptr() as *mut c_void),
            Some(&mut size),
        )
        .ok()
        .ok()?;
        buf.truncate(size as usize);
        Some(buf)
    }
}

fn reg_string(key: &str, value: &str) -> Option<String> {
    unsafe {
        let k = wide(key);
        let v = wide(value);
        let mut size = 0u32;
        RegGetValueW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), PCWSTR(v.as_ptr()), RRF_RT_REG_SZ, None, None, Some(&mut size)).ok().ok()?;
        let mut buf = vec![0u16; size as usize / 2 + 1];
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(k.as_ptr()),
            PCWSTR(v.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut c_void),
            Some(&mut size),
        )
        .ok()
        .ok()?;
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..end]))
    }
}

fn guid_from_bytes(b: &[u8]) -> GUID {
    GUID::from_values(
        u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
        u16::from_le_bytes([b[4], b[5]]),
        u16::from_le_bytes([b[6], b[7]]),
        [b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]],
    )
}

const VD_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";

pub fn desktops() -> Desktops {
    let ids: Vec<GUID> = reg_binary(VD_KEY, "VirtualDesktopIDs")
        .map(|b| b.chunks_exact(16).map(guid_from_bytes).collect())
        .unwrap_or_default();
    let current = reg_binary(VD_KEY, "CurrentVirtualDesktop").filter(|b| b.len() >= 16).map(|b| guid_str(&guid_from_bytes(&b)));
    let list: Vec<Desktop> = ids
        .iter()
        .enumerate()
        .map(|(i, g)| {
            let id = guid_str(g);
            let key = format!(r"{}\Desktops\{{{}}}", VD_KEY, format!("{:?}", g).to_uppercase());
            let name = reg_string(&key, "Name").filter(|s| !s.is_empty()).unwrap_or_else(|| format!("데스크탑 {}", i + 1));
            Desktop { id, name }
        })
        .collect();

    let me = std::process::id();
    let mut apps: HashMap<String, Vec<DeskApp>> = HashMap::new();
    let mut exe_cache: HashMap<u32, Option<String>> = HashMap::new();
    let mut name_cache: HashMap<String, String> = HashMap::new();
    let mut cur_guess = None;
    for r in windows_list_all() {
        if r.pid == me || r.desktop.is_empty() {
            continue;
        }
        if r.on_current && cur_guess.is_none() {
            cur_guess = Some(r.desktop.clone());
        }
        let Some(exe) = exe_cache.entry(r.pid).or_insert_with(|| exe_of(r.pid)).clone() else { continue };
        let lower = exe.to_lowercase();
        if lower.ends_with(r"\explorer.exe") && r.title == "Program Manager" {
            continue;
        }
        let list = apps.entry(r.desktop.clone()).or_default();
        if list.iter().any(|a| a.exe.to_lowercase() == lower) {
            continue;
        }
        let name = name_cache
            .entry(lower.clone())
            .or_insert_with(|| {
                file_description(&exe)
                    .or_else(|| Path::new(&exe).file_stem().map(|s| s.to_string_lossy().to_string()))
                    .unwrap_or_else(|| r.title.clone())
            })
            .clone();
        list.push(DeskApp { pid: r.pid, hwnd: r.hwnd.0 as isize, exe, name, title: r.title.clone() });
    }
    let current = current.or(cur_guess).unwrap_or_default();
    let mut list = list;
    if list.is_empty() {
        // 레지스트리에 목록이 없으면(데스크탑을 한 번도 안 만든 경우) 지금 데스크탑 하나
        list.push(Desktop { id: current.clone(), name: "데스크탑 1".into() });
    }
    Desktops { current, list, apps }
}

// MARK: 작업 표시줄

pub fn taskbar_autohide(set: Option<bool>) -> bool {
    unsafe {
        let mut abd = APPBARDATA { cbSize: std::mem::size_of::<APPBARDATA>() as u32, ..Default::default() };
        let state = SHAppBarMessage(ABM_GETSTATE, &mut abd) as u32;
        if let Some(on) = set {
            let keep = state & ABS_ALWAYSONTOP;
            abd.lParam = LPARAM(if on { (keep | ABS_AUTOHIDE) as isize } else { keep as isize });
            SHAppBarMessage(ABM_SETSTATE, &mut abd);
            return on;
        }
        state & ABS_AUTOHIDE != 0
    }
}

/// 작업 표시줄에 고정된 앱 (바로가기 폴더)
pub fn taskbar_pinned() -> Vec<crate::InstalledApp> {
    let Ok(appdata) = std::env::var("APPDATA") else { return Vec::new() };
    let dir = PathBuf::from(appdata).join(r"Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar");
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<crate::InstalledApp> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x.eq_ignore_ascii_case("lnk")).unwrap_or(false))
        .map(|p| {
            let id = p.to_string_lossy().to_string();
            let name = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let target = crate::win::lnk_target(&id).unwrap_or_default();
            crate::InstalledApp { id, name, target }
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

// MARK: 메모리 (실행 파일마다 개인 메모리 합 — 크롬처럼 여러 프로세스인 앱은 모두 더함)

pub fn memory_usage() -> HashMap<String, u64> {
    let mut out: HashMap<String, u64> = HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
        let mut pe = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut ok = Process32FirstW(snap, &mut pe).is_ok();
        while ok {
            let pid = pe.th32ProcessID;
            if pid != 0 {
                if let Ok(hp) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, pid)
                    .or_else(|_| OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid))
                {
                    let mut pmc = PROCESS_MEMORY_COUNTERS_EX::default();
                    let got = GetProcessMemoryInfo(
                        hp,
                        &mut pmc as *mut _ as *mut PROCESS_MEMORY_COUNTERS,
                        std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
                    )
                    .is_ok();
                    let _ = CloseHandle(hp);
                    if got {
                        if let Some(exe) = exe_of(pid) {
                            *out.entry(exe.to_lowercase()).or_insert(0) += pmc.PrivateUsage as u64;
                        }
                    }
                }
            }
            ok = Process32NextW(snap, &mut pe).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    out
}

// MARK: 로그인 시 자동 실행 (HKCU\...\Run)

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_NAME: &str = "MyLauncher";

pub fn autostart(set: Option<bool>) -> bool {
    unsafe {
        if let Some(on) = set {
            let k = wide(RUN_KEY);
            let mut key = HKEY::default();
            if RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), 0, KEY_SET_VALUE, &mut key).is_err() {
                return false;
            }
            let name = wide(RUN_NAME);
            if on {
                let exe = std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
                let val = wide(&format!("\"{}\"", exe));
                let bytes = std::slice::from_raw_parts(val.as_ptr() as *const u8, val.len() * 2);
                let _ = RegSetValueExW(key, PCWSTR(name.as_ptr()), 0, REG_SZ, Some(bytes));
            } else {
                let _ = RegDeleteValueW(key, PCWSTR(name.as_ptr()));
            }
            let _ = RegCloseKey(key);
        }
        reg_string(RUN_KEY, RUN_NAME).is_some()
    }
}

#[allow(dead_code)]
fn reg_dword(key: &str, value: &str) -> Option<u32> {
    unsafe {
        let k = wide(key);
        let v = wide(value);
        let mut d = 0u32;
        let mut size = 4u32;
        RegGetValueW(
            HKEY_CURRENT_USER,
            PCWSTR(k.as_ptr()),
            PCWSTR(v.as_ptr()),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut d as *mut _ as *mut c_void),
            Some(&mut size),
        )
        .ok()
        .ok()?;
        Some(d)
    }
}

// MARK: 모니터 작업 영역 (작업 표시줄 뺀 자리, 물리 픽셀)

#[derive(Serialize)]
pub struct Area {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    /// 모니터 전체
    pub mx: i32,
    pub my: i32,
    pub mw: i32,
    pub mh: i32,
}

pub fn work_area_at(x: i32, y: i32) -> Option<Area> {
    unsafe {
        let mon = MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(mon, &mut mi).as_bool() {
            return None;
        }
        let (r, m) = (mi.rcWork, mi.rcMonitor);
        Some(Area {
            x: r.left,
            y: r.top,
            w: r.right - r.left,
            h: r.bottom - r.top,
            mx: m.left,
            my: m.top,
            mw: m.right - m.left,
            mh: m.bottom - m.top,
        })
    }
}

// MARK: 자주 쓰는 앱 막대의 자리 비우기 — Windows 는 '앱 바' 로 화면 자리를 정식으로 예약할 수 있음

static APPBARS: Mutex<Vec<isize>> = Mutex::new(Vec::new());

fn appbar_data(hwnd: HWND) -> APPBARDATA {
    APPBARDATA { cbSize: std::mem::size_of::<APPBARDATA>() as u32, hWnd: hwnd, uCallbackMessage: WM_USER + 77, ..Default::default() }
}

/// edge: left · right · top · bottom, thick: 막대 두께(물리 픽셀), reserve 가 false 면 예약을 풀고 그냥 가장자리에 둠
/// length: 예약하지 않을 때 막대 길이(물리 픽셀, 0 이면 가장자리 전체) — 가장자리 가운데에 둠
pub fn appbar_set(hwnd: isize, edge: &str, thick: i32, length: i32, reserve: bool) -> Option<[i32; 4]> {
    let w = h(hwnd);
    unsafe {
        let mut list = APPBARS.lock().ok()?;
        let registered = list.contains(&hwnd);
        if !reserve {
            if registered {
                let mut abd = appbar_data(w);
                SHAppBarMessage(ABM_REMOVE, &mut abd);
                list.retain(|&x| x != hwnd);
            }
        } else if !registered {
            let mut abd = appbar_data(w);
            if SHAppBarMessage(ABM_NEW, &mut abd) == 0 {
                return None;
            }
            list.push(hwnd);
        }
        let mon = MonitorFromWindow(w, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(mon, &mut mi);
        let base = if reserve { mi.rcMonitor } else { mi.rcWork };
        let (uedge, mut rc) = match edge {
            "left" => (ABE_LEFT, RECT { left: base.left, top: base.top, right: base.left + thick, bottom: base.bottom }),
            "top" => (ABE_TOP, RECT { left: base.left, top: base.top, right: base.right, bottom: base.top + thick }),
            "bottom" => (ABE_BOTTOM, RECT { left: base.left, top: base.bottom - thick, right: base.right, bottom: base.bottom }),
            _ => (ABE_RIGHT, RECT { left: base.right - thick, top: base.top, right: base.right, bottom: base.bottom }),
        };
        if reserve {
            let mut abd = appbar_data(w);
            abd.uEdge = uedge;
            abd.rc = rc;
            SHAppBarMessage(ABM_QUERYPOS, &mut abd);
            // 시스템이 다른 막대(작업 표시줄)와 겹치지 않게 고쳐 준 자리에서 두께만 다시 맞춤
            let r = abd.rc;
            rc = match edge {
                "left" => RECT { left: r.left, top: r.top, right: r.left + thick, bottom: r.bottom },
                "top" => RECT { left: r.left, top: r.top, right: r.right, bottom: r.top + thick },
                "bottom" => RECT { left: r.left, top: r.bottom - thick, right: r.right, bottom: r.bottom },
                _ => RECT { left: r.right - thick, top: r.top, right: r.right, bottom: r.bottom },
            };
            abd.rc = rc;
            SHAppBarMessage(ABM_SETPOS, &mut abd);
            rc = abd.rc;
        }
        if !reserve && length > 0 {
            let vertical = matches!(edge, "left" | "right");
            if vertical {
                let len = length.min(rc.bottom - rc.top);
                rc.top += (rc.bottom - rc.top - len) / 2;
                rc.bottom = rc.top + len;
            } else {
                let len = length.min(rc.right - rc.left);
                rc.left += (rc.right - rc.left - len) / 2;
                rc.right = rc.left + len;
            }
        }
        let _ = SetWindowPos(w, None, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, SWP_NOZORDER | SWP_NOACTIVATE);
        Some([rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top])
    }
}

/// 끝날 때 예약한 자리를 모두 돌려줌 (안 그러면 탐색기를 다시 켤 때까지 자리가 비어 있음)
pub fn appbar_remove_all() {
    if let Ok(mut list) = APPBARS.lock() {
        for &hw in list.iter() {
            let mut abd = appbar_data(h(hw));
            unsafe {
                SHAppBarMessage(ABM_REMOVE, &mut abd);
            }
        }
        list.clear();
    }
}

// MARK: 창 모양 — 흐림(아크릴)이 다른 창을 눌러도 회색으로 안 바뀌게 · 둥근 모서리

/// 창이 비활성이 되면 Windows 11 은 아크릴 배경을 회색으로 바꿈. WM_NCACTIVATE 를 늘 '활성' 으로 넘겨서
/// 배경이 계속 흐린 반투명으로 남게 함 (키보드 포커스 · 다른 창 동작은 그대로)
unsafe extern "system" fn keep_active_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM, _id: usize, _data: usize) -> LRESULT {
    if msg == WM_NCACTIVATE {
        return DefSubclassProc(hwnd, msg, WPARAM(1), lp);
    }
    DefSubclassProc(hwnd, msg, wp, lp)
}

pub fn keep_backdrop_active(hwnd: isize) {
    unsafe {
        let _ = SetWindowSubclass(h(hwnd), Some(keep_active_proc), 0x4d4c, 0);
    }
}

/// 제목 막대가 없는 창도 Windows 11 처럼 둥근 모서리
pub fn round_corners(hwnd: isize) {
    unsafe {
        let pref = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(h(hwnd), DWMWA_WINDOW_CORNER_PREFERENCE, &pref as *const _ as *const c_void, std::mem::size_of_val(&pref) as u32);
    }
}

/// 제목 막대 없는 창의 가장자리 끌기 → Windows 의 크기 조절 시작 (마우스를 누르고 있을 때)
pub fn start_resize(hwnd: isize, dir: &str) {
    let ht: usize = match dir {
        "West" => 10,
        "East" => 11,
        "North" => 12,
        "NorthWest" => 13,
        "NorthEast" => 14,
        "South" => 15,
        "SouthWest" => 16,
        _ => 17,
    };
    unsafe {
        let _ = windows::Win32::UI::Input::KeyboardAndMouse::ReleaseCapture();
        let _ = PostMessageW(h(hwnd), windows::Win32::UI::WindowsAndMessaging::WM_NCLBUTTONDOWN, WPARAM(ht), LPARAM(0));
    }
}

// MARK: 작은 창(PIP) 비율 잠금 — 가장자리 · 모서리를 끌어도 영상 비율 그대로 (검은 여백 없음)

/// Windows 가 크기 조절 중에 보내는 WM_SIZING 에서 새 크기를 영상 비율로 고침.
/// 어느 쪽을 끄는지(wParam)에 따라 반대쪽을 맞춤: 좌우 가장자리 → 높이, 위아래 → 폭, 모서리 → 폭 기준 높이
unsafe extern "system" fn aspect_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM, _id: usize, data: usize) -> LRESULT {
    if msg == WM_SIZING && data > 0 {
        let ar = data as f64 / 10000.0;
        let r = &mut *(lp.0 as *mut RECT);
        let [l, t, rr, b] = aspect_fix(wp.0, [r.left, r.top, r.right, r.bottom], ar);
        *r = RECT { left: l, top: t, right: rr, bottom: b };
        return LRESULT(1);
    }
    DefSubclassProc(hwnd, msg, wp, lp)
}

/// 끄는 쪽(edge: Windows WMSZ_*)에 따라 [왼, 위, 오른, 아래] 를 비율에 맞게 고침
fn aspect_fix(edge: usize, r: [i32; 4], ar: f64) -> [i32; 4] {
    let [l, t, rt, b] = r;
    let (w, h) = ((rt - l) as f64, (b - t) as f64);
    match edge {
        1 | 2 => [l, t, rt, t + (w / ar).round() as i32],          // 왼 · 오른 가장자리 → 높이
        3 | 6 => [l, t, l + (h * ar).round() as i32, b],           // 위 · 아래 가장자리 → 폭
        4 | 5 => [l, b - (w / ar).round() as i32, rt, b],          // 위쪽 모서리 → 아래 고정, 위를 맞춤
        _ => [l, t, rt, t + (w / ar).round() as i32],              // 아래쪽 모서리 → 위 고정, 아래를 맞춤
    }
}

#[cfg(test)]
mod aspect_tests {
    use super::aspect_fix;
    #[test]
    fn keeps_ratio_for_every_edge() {
        let ar = 16.0 / 9.0;
        // 오른쪽을 끌어 폭 1600 → 높이 900
        assert_eq!(aspect_fix(2, [100, 100, 1700, 500], ar), [100, 100, 1700, 1000]);
        // 아래를 끌어 높이 450 → 폭 800
        assert_eq!(aspect_fix(6, [0, 0, 300, 450], ar), [0, 0, 800, 450]);
        // 왼쪽 위 모서리: 아래(1000) 고정, 폭 800 → 위 = 1000 - 450
        assert_eq!(aspect_fix(4, [200, 0, 1000, 1000], ar), [200, 550, 1000, 1000]);
        // 오른쪽 아래 모서리: 위 고정
        assert_eq!(aspect_fix(8, [0, 0, 960, 10], ar), [0, 0, 960, 540]);
        // 세로 영상(쇼츠 9:16): 오른쪽 끌어 폭 450 → 높이 800
        assert_eq!(aspect_fix(2, [0, 0, 450, 100], 9.0 / 16.0), [0, 0, 450, 800]);
        for edge in 1..=8 {
            let [l, t, r, b] = aspect_fix(edge, [10, 20, 650, 300], ar);
            let got = (r - l) as f64 / (b - t) as f64;
            assert!((got - ar).abs() < 0.01, "edge {edge}: {got}");
        }
    }
}

/// ar: 영상 가로/세로 비율 (None 이면 잠금 풀기)
pub fn lock_aspect(hwnd: isize, ar: Option<f64>) {
    unsafe {
        match ar {
            Some(a) if a > 0.2 && a < 6.0 => {
                let _ = SetWindowSubclass(h(hwnd), Some(aspect_proc), 0x4d41, (a * 10000.0) as usize);
            }
            _ => {
                let _ = RemoveWindowSubclass(h(hwnd), Some(aspect_proc), 0x4d41);
            }
        }
    }
}
