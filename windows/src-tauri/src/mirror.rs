// 영역 비추기 (오버레이): 화면에서 끌어 고른 영역 — 그 아래 창의 한 부분 — 을 작은 항상 위 창(mirror-<id>)에 실시간으로
// Windows DWM 썸네일: 화면을 캡처하지 않고 DWM 이 원본 창을 바로 그려 줌 (원본이 다른 창에 가려져 있어도 보임, 최소화하면 안 보임)
// 보기 전용 — 비춘 창을 눌러도 원본엔 안 눌림. 잠금 · 숨기기는 가림막과 같이 (COVER_LOCKED · COVER_HIDDEN)
use serde::Serialize;
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::Mutex;
use windows::Win32::Foundation::{BOOL, HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Dwm::{
    DwmGetWindowAttribute, DwmRegisterThumbnail, DwmUnregisterThumbnail, DwmUpdateThumbnailProperties, DWMWA_CLOAKED, DWM_THUMBNAIL_PROPERTIES,
};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetClientRect, GetCursorPos, GetWindowLongW, GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow,
    IsWindowVisible, GWL_EXSTYLE, WS_EX_LAYERED, WS_EX_TRANSPARENT,
};

// DWM_TNP_* (썸네일 속성 중 바꿀 것)
const TNP_RECTDESTINATION: u32 = 0x1;
const TNP_RECTSOURCE: u32 = 0x2;
const TNP_OPACITY: u32 = 0x4;
const TNP_VISIBLE: u32 = 0x8;
const TNP_SOURCECLIENTAREAONLY: u32 = 0x10;

fn hw(v: isize) -> HWND {
    HWND(v as *mut c_void)
}

/// 비추는 것 하나: 원본 창 · 그 창 안의 영역(원본 창 왼쪽 위 기준, 물리 픽셀) · 원본을 다시 찾을 단서
#[derive(Clone, Serialize, Default)]
pub struct Mirror {
    pub id: String,
    pub cls: String,
    pub title: String,
    pub exe: String,
    pub sx: i32,
    pub sy: i32,
    pub sw: i32,
    pub sh: i32,
    #[serde(skip)]
    pub src: isize,
    #[serde(skip)]
    pub dest: isize,
    #[serde(skip)]
    pub thumb: isize,
}

static MIRRORS: Mutex<Option<HashMap<String, Mirror>>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut HashMap<String, Mirror>) -> R) -> R {
    let mut g = MIRRORS.lock().unwrap();
    f(g.get_or_insert_with(HashMap::new))
}

fn text_of(h: HWND, class: bool) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { if class { GetClassNameW(h, &mut buf) } else { GetWindowTextW(h, &mut buf) } };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn pid_of(h: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    pid
}

fn rect_of(h: HWND) -> Option<RECT> {
    let mut r = RECT::default();
    unsafe { GetWindowRect(h, &mut r).ok()? };
    Some(r)
}

/// 고를 만한 창: 보이고 · 최소화 안 됐고 · 다른 데스크탑에 숨지 않았고 · 도구함 것이 아니고 · 클릭 통과 오버레이가 아닌 것
fn usable(h: HWND, me: u32) -> bool {
    unsafe {
        if !IsWindowVisible(h).as_bool() || IsIconic(h).as_bool() || pid_of(h) == me {
            return false;
        }
        let mut cloaked = 0u32;
        let _ = DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut c_void, 4);
        if cloaked != 0 {
            return false;
        }
        let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
        !(ex & WS_EX_LAYERED.0 != 0 && ex & WS_EX_TRANSPARENT.0 != 0)
    }
}

struct Search<'a> {
    me: u32,
    hit: Option<HWND>,
    test: &'a dyn Fn(HWND) -> bool,
}

unsafe extern "system" fn enum_cb(h: HWND, lp: LPARAM) -> BOOL {
    let s = &mut *(lp.0 as *mut Search);
    if usable(h, s.me) && (s.test)(h) {
        s.hit = Some(h);
        return BOOL(0);
    }
    BOOL(1)
}

/// 맨 위부터(Z 순서) 조건에 맞는 첫 창
fn find(test: &dyn Fn(HWND) -> bool) -> Option<HWND> {
    let mut s = Search { me: std::process::id(), hit: None, test };
    unsafe {
        let _ = EnumWindows(Some(enum_cb), LPARAM(&mut s as *mut Search as isize));
    }
    s.hit
}

/// 이 점(화면 물리 픽셀) 아래 맨 위 창
fn window_at(x: i32, y: i32) -> Option<HWND> {
    find(&|h| rect_of(h).map(|r| x >= r.left && x < r.right && y >= r.top && y < r.bottom).unwrap_or(false))
}

/// 마우스가 있는 모니터 (물리 픽셀: 왼 · 위 · 너비 · 높이)
pub fn cursor_monitor() -> [i32; 4] {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let m = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(m, &mut mi);
        let r = mi.rcMonitor;
        [r.left, r.top, r.right - r.left, r.bottom - r.top]
    }
}

/// 고른 영역(화면 물리 픽셀)에서 비출 것 정하기: 영역 가운데 아래 창 · 그 창 안의 영역
pub fn from_region(id: &str, x: i32, y: i32, w: i32, h: i32) -> Option<Mirror> {
    let src = window_at(x + w / 2, y + h / 2)?;
    let r = rect_of(src)?;
    Some(Mirror {
        id: id.to_string(),
        cls: text_of(src, true),
        title: text_of(src, false),
        exe: crate::win::exe_of(pid_of(src)).unwrap_or_default(),
        sx: x - r.left,
        sy: y - r.top,
        sw: w.max(8),
        sh: h.max(8),
        src: src.0 as isize,
        ..Default::default()
    })
}

/// 다시 켰을 때 · 원본 창이 다시 열렸을 때: 같은 프로그램의 같은 종류 창 (제목까지 같으면 더 좋음)
fn refind(m: &Mirror) -> Option<HWND> {
    let ok = |h: HWND, title: bool| {
        text_of(h, true) == m.cls && (!title || text_of(h, false) == m.title) && crate::win::exe_of(pid_of(h)).unwrap_or_default() == m.exe
    };
    find(&|h| ok(h, true)).or_else(|| find(&|h| ok(h, false)))
}

/// 비추기 시작 (dest = 비출 창). 이미 있으면 바꿔 끼움
pub fn attach(mut m: Mirror, dest: isize) -> Mirror {
    detach(&m.id);
    m.dest = dest;
    if m.src == 0 || unsafe { !IsWindow(hw(m.src)).as_bool() } {
        m.src = refind(&m).map(|h| h.0 as isize).unwrap_or(0);
    }
    if m.src != 0 {
        if let Ok(t) = unsafe { DwmRegisterThumbnail(hw(dest), hw(m.src)) } {
            m.thumb = t;
        }
    }
    with(|all| all.insert(m.id.clone(), m.clone()));
    m
}

pub fn detach(id: &str) {
    if let Some(m) = with(|all| all.remove(id)) {
        if m.thumb != 0 {
            unsafe {
                let _ = DwmUnregisterThumbnail(m.thumb);
            }
        }
    }
}

pub fn info(id: &str) -> Option<Mirror> {
    with(|all| all.get(id).cloned())
}

/// 그리기: 비출 창 안(위쪽 top 픽셀은 비우고)에 영역을 비율 그대로 꽉 차게 · 불투명도 0~255
/// 원본 창이 없어졌으면 다시 찾아 붙임. 비추고 있으면 true
pub fn update(id: &str, top: i32, alpha: u8) -> bool {
    let Some(mut m) = info(id) else { return false };
    let alive = m.src != 0 && unsafe { IsWindow(hw(m.src)).as_bool() };
    if !alive || m.thumb == 0 {
        if m.thumb != 0 {
            unsafe {
                let _ = DwmUnregisterThumbnail(m.thumb);
            }
        }
        m.src = 0;
        m.thumb = 0;
        let dest = m.dest;
        m = attach(m, dest);
        if m.thumb == 0 {
            return false;
        }
    }
    let mut c = RECT::default();
    unsafe {
        let _ = GetClientRect(hw(m.dest), &mut c);
    }
    let (cw, ch) = ((c.right - c.left).max(1), (c.bottom - c.top - top).max(1));
    // 비율 유지: 남는 쪽은 가운데 정렬
    let k = (cw as f64 / m.sw as f64).min(ch as f64 / m.sh as f64);
    let (dw, dh) = ((m.sw as f64 * k).round() as i32, (m.sh as f64 * k).round() as i32);
    let (dx, dy) = ((cw - dw) / 2, top + (ch - dh) / 2);
    let p = DWM_THUMBNAIL_PROPERTIES {
        dwFlags: TNP_RECTDESTINATION | TNP_RECTSOURCE | TNP_OPACITY | TNP_VISIBLE | TNP_SOURCECLIENTAREAONLY,
        rcDestination: RECT { left: dx, top: dy, right: dx + dw, bottom: dy + dh },
        rcSource: RECT { left: m.sx, top: m.sy, right: m.sx + m.sw, bottom: m.sy + m.sh },
        opacity: alpha,
        fVisible: BOOL(1),
        fSourceClientAreaOnly: BOOL(0),
    };
    unsafe { DwmUpdateThumbnailProperties(m.thumb, &p).is_ok() }
}
