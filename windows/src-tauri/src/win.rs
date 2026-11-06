// Windows 전용 기능: 시작 메뉴 앱 찾기 · 바로가기 대상 · 아이콘 · 실행 · 창 목록 · 앞으로 · 종료
use crate::{InstalledApp, RunningApp};
use base64::Engine;
use std::collections::HashMap;
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use windows::core::{Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{BOOL, CloseHandle, HWND, LPARAM, MAX_PATH, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HDC, HGDIOBJ,
};
use windows::Win32::Storage::FileSystem::{
    GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW, FILE_FLAGS_AND_ATTRIBUTES, WIN32_FIND_DATAW,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, STGM_READ,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, TerminateProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    PROCESS_TERMINATE,
};
use windows::Win32::UI::Shell::{IShellLinkW, SHGetFileInfoW, ShellExecuteW, ShellLink, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON};
use windows::Win32::UI::WindowsAndMessaging::{
    DestroyIcon, EnumWindows, GetIconInfo, GetWindow, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, PostMessageW, SetForegroundWindow, ShowWindow, GWL_EXSTYLE,
    GW_OWNER, ICONINFO, SW_RESTORE, SW_SHOWNORMAL, WM_CLOSE, WS_EX_TOOLWINDOW,
};

fn wide(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

// MARK: 시작 메뉴 앱

fn start_menu_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(p) = std::env::var("ProgramData") {
        v.push(PathBuf::from(p).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    if let Ok(p) = std::env::var("APPDATA") {
        v.push(PathBuf::from(p).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    v
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 4 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out, depth + 1);
        } else if p.extension().map(|x| x.eq_ignore_ascii_case("lnk")).unwrap_or(false) {
            out.push(p);
        }
    }
}

/// 바로가기(.lnk)가 가리키는 실제 파일
fn lnk_target(path: &str) -> Option<String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        let pf: IPersistFile = link.cast().ok()?;
        let w = wide(path);
        pf.Load(PCWSTR(w.as_ptr()), STGM_READ).ok()?;
        let mut buf = [0u16; MAX_PATH as usize];
        let mut fd = WIN32_FIND_DATAW::default();
        link.GetPath(&mut buf, &mut fd, 0).ok()?;
        let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        let s = String::from_utf16_lossy(&buf[..len]);
        (!s.is_empty()).then_some(s)
    }
}

pub fn installed_apps() -> Vec<InstalledApp> {
    let mut files = Vec::new();
    for d in start_menu_dirs() {
        walk(&d, &mut files, 0);
    }
    // 제거 · 도움말 같은 바로가기는 빼고, 이름이 같으면 하나만
    let skip = ["uninstall", "제거", "readme", "help", "도움말", "license", "website", "웹 사이트"];
    let mut seen = HashMap::new();
    let mut out = Vec::new();
    for f in files {
        let name = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let lower = name.to_lowercase();
        if name.is_empty() || skip.iter().any(|k| lower.contains(k)) || seen.contains_key(&lower) {
            continue;
        }
        seen.insert(lower, ());
        let id = f.to_string_lossy().to_string();
        let target = lnk_target(&id).unwrap_or_default();
        out.push(InstalledApp { id, name, target });
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

// MARK: 아이콘 → PNG

pub fn icon_png_base64(path: &str) -> Option<String> {
    unsafe {
        let w = wide(path);
        let mut sfi = SHFILEINFOW::default();
        let r = SHGetFileInfoW(
            PCWSTR(w.as_ptr()),
            FILE_FLAGS_AND_ATTRIBUTES(0),
            Some(&mut sfi),
            std::mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON,
        );
        if r == 0 || sfi.hIcon.is_invalid() {
            return None;
        }
        let hicon = sfi.hIcon;
        let mut ii = ICONINFO::default();
        if GetIconInfo(hicon, &mut ii).is_err() || ii.hbmColor.is_invalid() {
            let _ = DestroyIcon(hicon);
            return None;
        }
        let mut bm = BITMAP::default();
        GetObjectW(HGDIOBJ(ii.hbmColor.0), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as *mut c_void));
        let (wpx, hpx) = (bm.bmWidth, bm.bmHeight);
        let mut bi = BITMAPINFO::default();
        bi.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: wpx,
            biHeight: -hpx, // 위에서 아래로
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut buf = vec![0u8; (wpx * hpx * 4).max(0) as usize];
        let dc = CreateCompatibleDC(HDC::default());
        GetDIBits(dc, ii.hbmColor, 0, hpx as u32, Some(buf.as_mut_ptr() as *mut c_void), &mut bi, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        let _ = DeleteObject(HGDIOBJ(ii.hbmColor.0));
        if !ii.hbmMask.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(ii.hbmMask.0));
        }
        let _ = DestroyIcon(hicon);
        // BGRA → RGBA (알파가 전부 0인 옛 아이콘은 불투명으로)
        let no_alpha = buf.chunks(4).all(|p| p[3] == 0);
        for p in buf.chunks_mut(4) {
            p.swap(0, 2);
            if no_alpha {
                p[3] = 255;
            }
        }
        let mut png_bytes = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut png_bytes, wpx as u32, hpx as u32);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut wr = enc.write_header().ok()?;
            wr.write_image_data(&buf).ok()?;
        }
        Some(base64::engine::general_purpose::STANDARD.encode(png_bytes))
    }
}

// MARK: 실행

pub fn open(path: &str) -> Result<(), String> {
    unsafe {
        let f = wide(path);
        let op = wide("open");
        let r = ShellExecuteW(HWND::default(), PCWSTR(op.as_ptr()), PCWSTR(f.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
        if r.0 as isize <= 32 {
            return Err(format!("실행하지 못했어요 ({})", r.0 as isize));
        }
    }
    Ok(())
}

// MARK: 실행 중인 앱 (보이는 창 기준)

struct Found {
    windows: Vec<(HWND, u32, String)>,
}

unsafe extern "system" fn enum_cb(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let found = &mut *(lparam.0 as *mut Found);
    if !IsWindowVisible(hwnd).as_bool() {
        return BOOL(1);
    }
    // 작업 표시줄에 안 나오는 창(도구 창 · 다른 창에 딸린 창 · 숨겨진 UWP 창)은 빼기
    let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
    if ex & WS_EX_TOOLWINDOW.0 != 0 {
        return BOOL(1);
    }
    if let Ok(owner) = GetWindow(hwnd, GW_OWNER) {
        if !owner.is_invalid() {
            return BOOL(1);
        }
    }
    let mut cloaked: u32 = 0;
    let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut c_void, 4);
    if cloaked != 0 {
        return BOOL(1);
    }
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return BOOL(1);
    }
    let mut buf = vec![0u16; len as usize + 1];
    let n = GetWindowTextW(hwnd, &mut buf);
    let title = String::from_utf16_lossy(&buf[..n.max(0) as usize]);
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    found.windows.push((hwnd, pid, title));
    BOOL(1)
}

fn windows_list() -> Vec<(HWND, u32, String)> {
    let mut f = Found { windows: Vec::new() };
    unsafe {
        let _ = EnumWindows(Some(enum_cb), LPARAM(&mut f as *mut _ as isize));
    }
    f.windows
}

fn exe_of(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(h);
        r.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// 실행 파일에 적힌 이름 (예: chrome.exe → "Google Chrome")
fn file_description(exe: &str) -> Option<String> {
    unsafe {
        let w = wide(exe);
        let size = GetFileVersionInfoSizeW(PCWSTR(w.as_ptr()), None);
        if size == 0 {
            return None;
        }
        let mut data = vec![0u8; size as usize];
        GetFileVersionInfoW(PCWSTR(w.as_ptr()), 0, size, data.as_mut_ptr() as *mut c_void).ok()?;
        // 첫 번째 언어 · 코드페이지로 FileDescription 찾기
        let mut ptr: *mut c_void = std::ptr::null_mut();
        let mut len = 0u32;
        let q = wide(r"\VarFileInfo\Translation");
        if !VerQueryValueW(data.as_ptr() as *const c_void, PCWSTR(q.as_ptr()), &mut ptr, &mut len).as_bool() || len < 4 {
            return None;
        }
        let lang = *(ptr as *const u16);
        let cp = *((ptr as *const u16).add(1));
        let key = wide(&format!(r"\StringFileInfo\{:04x}{:04x}\FileDescription", lang, cp));
        if !VerQueryValueW(data.as_ptr() as *const c_void, PCWSTR(key.as_ptr()), &mut ptr, &mut len).as_bool() || len == 0 {
            return None;
        }
        let s = std::slice::from_raw_parts(ptr as *const u16, len as usize);
        let end = s.iter().position(|&c| c == 0).unwrap_or(s.len());
        let v = String::from_utf16_lossy(&s[..end]).trim().to_string();
        (!v.is_empty()).then_some(v)
    }
}

pub fn running_apps() -> Vec<RunningApp> {
    let me = std::process::id();
    let mut by_exe: HashMap<String, RunningApp> = HashMap::new();
    let mut order = Vec::new();
    for (_, pid, title) in windows_list() {
        if pid == me {
            continue;
        }
        let Some(exe) = exe_of(pid) else { continue };
        let key = exe.to_lowercase();
        if key.ends_with(r"\explorer.exe") && title == "Program Manager" {
            continue;
        }
        if !by_exe.contains_key(&key) {
            let name = file_description(&exe)
                .or_else(|| Path::new(&exe).file_stem().map(|s| s.to_string_lossy().to_string()))
                .unwrap_or_else(|| title.clone());
            order.push(key.clone());
            by_exe.insert(key, RunningApp { pid, exe, name, title });
        }
    }
    order.into_iter().filter_map(|k| by_exe.remove(&k)).collect()
}

fn windows_of(pid: u32) -> Vec<HWND> {
    windows_list().into_iter().filter(|(_, p, _)| *p == pid).map(|(h, _, _)| h).collect()
}

pub fn focus(pid: u32) -> bool {
    let ws = windows_of(pid);
    let Some(&h) = ws.first() else { return false };
    unsafe {
        if IsIconic(h).as_bool() {
            let _ = ShowWindow(h, SW_RESTORE);
        }
        SetForegroundWindow(h).as_bool()
    }
}

pub fn quit(pid: u32, force: bool) -> bool {
    unsafe {
        if force {
            let Ok(h) = OpenProcess(PROCESS_TERMINATE, false, pid) else { return false };
            let ok = TerminateProcess(h, 1).is_ok();
            let _ = CloseHandle(h);
            return ok;
        }
        // 창마다 닫기 요청 → 앱이 저장할지 물어봄
        let ws = windows_of(pid);
        for h in &ws {
            let _ = PostMessageW(*h, WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        !ws.is_empty()
    }
}
