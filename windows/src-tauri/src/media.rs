// 미니 플레이어 · 볼륨 · 청력 보호
// - 곡 정보 · 조작: Windows 의 '미디어 컨트롤'(SMTC). 브라우저의 YouTube Music, Spotify, 도구함 안 YouTube Music 창 등
//   Windows 볼륨 팝업에 곡이 뜨는 앱이면 무엇이든 됨. 권한 필요 없음
// - 볼륨: 기본 스피커의 마스터 볼륨
// - 청력 보호: 스피커로 나가는 소리 세기(피크 미터)와 볼륨으로 귀에 들어가는 크기를 어림하고, 오늘 들은 양을 셈
use base64::Engine;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session, GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::DataReader;
use windows::Win32::Media::Audio::Endpoints::{IAudioEndpointVolume, IAudioMeterInformation};
use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

fn com() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
}

/// 미디어 · 오디오 API 는 다중 스레드 COM 에서 불러야 함 — 같은 스레드가 이미 단일 스레드(STA)로
/// 잡혀 있으면 .get() 이 영원히 기다리므로, 늘 새 스레드에서 돌림
fn on_mta<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> Option<R> {
    std::thread::spawn(move || {
        com();
        f()
    })
    .join()
    .ok()
}

// MARK: 재생 정보

#[derive(Serialize, Default, Clone)]
pub struct MediaState {
    pub has: bool,
    /// 재생하는 앱 (예: YouTube Music, Chrome, Spotify.exe)
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    /// 초
    pub position: f64,
    pub duration: f64,
    pub shuffle: Option<bool>,
    /// none · one · all
    pub repeat: Option<String>,
    pub can_prev: bool,
    pub can_next: bool,
    pub can_seek: bool,
    /// 도구함 재생기 (ytmusic · yt-video · netflix) — 비어 있으면 Windows 미디어 정보의 다른 앱
    pub site: String,
    /// 열려 있는 도구함 재생기들 (‹ › 로 넘기기)
    pub sites: Vec<String>,
    /// 페이지가 알려 준 앨범 · 영상 사진 주소 (Windows 미디어 정보에 사진이 없을 때)
    pub art: String,
    /// LIKE · DISLIKE · INDIFFERENT (YouTube Music)
    pub like: String,
    /// 미니 플레이어가 도구함 재생기만 보는지
    pub app_only: bool,
}

/// 도구함 재생기(사이트 창)가 알려 준 지금 재생
#[derive(Clone)]
pub struct Now {
    pub title: String,
    pub artist: String,
    pub art: String,
    pub playing: bool,
    /// NONE · ALL · ONE (YouTube Music, 모르면 빈칸)
    pub repeat: String,
    pub like: String,
    pub pos: f64,
    pub dur: f64,
    pub at: Instant,
}

/// 재생기 순서 (‹ › 로 넘길 때)
const ORDER: [&str; 3] = ["ytmusic", "yt-video", "netflix"];
static SITES: Mutex<Vec<(String, Now)>> = Mutex::new(Vec::new());
/// 지금 보여 주는 재생기
static ACTIVE: Mutex<String> = Mutex::new(String::new());
/// 미니 플레이어를 도구함 재생기 전용으로 (기본) / 모든 앱
static APP_ONLY: AtomicBool = AtomicBool::new(true);

pub fn set_app_only(on: bool) {
    APP_ONLY.store(on, Ordering::Relaxed);
}

/// 재생기 페이지의 알림. 새로 재생을 시작했으면(started) 그 재생기로 넘어가고,
/// 일시정지시킬 다른 재생기 이름들을 돌려줌
pub fn site_update(label: &str, now: Now, started: bool) -> Vec<String> {
    let mut list = SITES.lock().unwrap();
    // '시작' 알림이 다른 알림에 덮여 빠져도: 안 나오다가 소리 나게 재생되기 시작하면 시작으로
    let was = list.iter().find(|(l, _)| l == label).map(|(_, n)| n.playing).unwrap_or(false);
    let started = started || (now.playing && !was);
    match list.iter_mut().find(|(l, _)| l == label) {
        Some(x) => x.1 = now,
        None => list.push((label.to_string(), now)),
    }
    let mut act = ACTIVE.lock().unwrap();
    if started || act.is_empty() || !list.iter().any(|(l, _)| *l == *act) {
        *act = label.to_string();
    }
    if started {
        // 다른 재생기는 모두 일시정지 (알려 준 상태가 늦었을 수 있어서, 재생 중이라고 알려 온 것만이 아니라 전부.
        // 이미 멈춰 있으면 페이지가 아무것도 안 함)
        for (l, n) in list.iter_mut() {
            if l != label {
                n.playing = false;
            }
        }
        ORDER.iter().filter(|o| **o != label).map(|s| s.to_string()).collect()
    } else {
        Vec::new()
    }
}

/// 재생기 창을 닫으면 목록에서 빼고, 보고 있던 거면 다른 재생기로
pub fn site_remove(label: &str) {
    let mut list = SITES.lock().unwrap();
    list.retain(|(l, _)| l != label);
    let mut act = ACTIVE.lock().unwrap();
    if *act == label {
        *act = list.iter().find(|(_, n)| n.playing).or(list.first()).map(|(l, _)| l.clone()).unwrap_or_default();
    }
}

/// ‹ › : dir 이 -1 이면 앞, 1 이면 다음 재생기
pub fn site_select(dir: i32) -> String {
    let list = SITES.lock().unwrap();
    let have: Vec<&str> = ORDER.iter().copied().filter(|o| list.iter().any(|(l, _)| l == o)).collect();
    let mut act = ACTIVE.lock().unwrap();
    if have.is_empty() {
        return String::new();
    }
    let i = have.iter().position(|x| *x == act.as_str()).unwrap_or(0) as i32;
    let n = have.len() as i32;
    *act = have[((i + dir) % n + n) as usize % n as usize].to_string();
    act.clone()
}

/// want 가 있으면 그 재생기만 (크게 보기 = YouTube Music 전용), 없으면 지금 보여 주는 재생기
fn pick_site(want: Option<&str>) -> Option<(String, Now, Vec<String>)> {
    let list = SITES.lock().unwrap();
    let have: Vec<String> = ORDER.iter().filter(|o| list.iter().any(|(l, _)| l == *o)).map(|s| s.to_string()).collect();
    let (l, n) = match want {
        Some(w) => list.iter().find(|(l, _)| l == w)?,
        None => {
            let act = ACTIVE.lock().unwrap().clone();
            list.iter().find(|(l, _)| *l == act).or(list.first())?
        }
    };
    Some((l.clone(), n.clone(), have))
}

fn norm(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn site_name(label: &str) -> &'static str {
    match label {
        "ytmusic" => "YouTube Music",
        "yt-video" => "YouTube",
        "netflix" => "Netflix",
        _ => "",
    }
}

/// 지금 플레이어가 따라가는 곡 (앱 · 제목 · 가수) — 다른 앱이 새로 열려도 이걸 먼저 찾음 ('모든 앱' 일 때)
static STICKY: Mutex<String> = Mutex::new(String::new());

fn key_of(s: &Session) -> String {
    let app = s.SourceAppUserModelId().map(|h| h.to_string()).unwrap_or_default();
    let (t, a) = s
        .TryGetMediaPropertiesAsync()
        .ok()
        .and_then(|op| op.get().ok())
        .map(|p| (p.Title().map(|h| h.to_string()).unwrap_or_default(), p.Artist().map(|h| h.to_string()).unwrap_or_default()))
        .unwrap_or_default();
    format!("{app}\u{1}{t}\u{1}{a}")
}

fn is_playing(s: &Session) -> bool {
    s.GetPlaybackInfo().and_then(|p| p.PlaybackStatus()).map(|x| x == Status::Playing).unwrap_or(false)
}

/// 어느 Windows 미디어 정보를 따라갈지
/// - 도구함 재생기 전용: 지금 재생기가 알려 준 제목과 같은 것 (사이트 창들은 Windows 에 모두 같은 앱으로 보여서 제목으로 구분)
/// - 모든 앱: Windows 는 가장 최근에 나타난 앱을 '현재' 로 삼아서 플레이어가 넘어가 버림. 그래서
///   1) 따라가던 곡이 아직 재생 중이면 그대로  2) 아니면 재생 중인 다른 것  3) 아무것도 재생 중이 아니면 따라가던 곡
fn session() -> Option<Session> {
    session_for(None)
}

fn session_for(want: Option<&str>) -> Option<Session> {
    com();
    let mgr = Manager::RequestAsync().ok()?.get().ok()?;
    let list: Vec<Session> = mgr.GetSessions().ok().map(|v| v.into_iter().collect()).unwrap_or_default();
    if APP_ONLY.load(Ordering::Relaxed) || want.is_some() {
        let (_, now, _) = pick_site(want)?;
        let want = norm(&now.title);
        let title_of = |s: &Session| s.TryGetMediaPropertiesAsync().ok().and_then(|op| op.get().ok()).and_then(|p| p.Title().ok()).map(|h| norm(&h.to_string())).unwrap_or_default();
        let same: Vec<Session> = list.into_iter().filter(|s| !want.is_empty() && title_of(s) == want).collect();
        return same.iter().find(|s| is_playing(s) == now.playing).cloned().or_else(|| same.first().cloned());
    }
    let current = mgr.GetCurrentSession().ok();
    if list.is_empty() {
        return current;
    }
    let mut sticky = STICKY.lock().unwrap();
    let keyed: Vec<(String, bool, Session)> = list.into_iter().map(|s| (key_of(&s), is_playing(&s), s)).collect();
    let mine = keyed.iter().find(|(k, _, _)| !sticky.is_empty() && *k == *sticky);
    let chosen = match mine {
        Some((_, true, s)) => Some(s.clone()),
        _ => keyed
            .iter()
            .find(|(_, p, _)| *p)
            .map(|(_, _, s)| s.clone())
            .or_else(|| mine.map(|(_, _, s)| s.clone()))
            .or_else(|| current.clone())
            .or_else(|| keyed.first().map(|(_, _, s)| s.clone())),
    };
    if let Some(s) = &chosen {
        *sticky = key_of(s);
    }
    chosen
}

const TICKS_1601_TO_1970: i64 = 116_444_736_000_000_000;

fn now_ticks() -> i64 {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    TICKS_1601_TO_1970 + (d.as_nanos() / 100) as i64
}

/// want: 그 재생기만 보기 (크게 보기 창 = "ytmusic"), None 이면 미니 플레이어처럼
pub fn state(want: Option<String>) -> MediaState {
    on_mta(move || state_inner(want.as_deref())).unwrap_or_default()
}

fn state_inner(want: Option<&str>) -> MediaState {
    let app_only = APP_ONLY.load(Ordering::Relaxed) || want.is_some();
    let site = if app_only { pick_site(want) } else { None };
    if app_only && site.is_none() {
        return MediaState { app_only, ..Default::default() };
    }
    let Some(s) = session_for(want) else {
        // 재생기가 알려 준 것만으로 (Windows 미디어 정보에 아직 없거나 · Netflix 처럼 안 알리는 사이트)
        // ('모든 앱' 모드에서 재생 중인 앱이 하나도 없으면 site 도 없음 → 빈 상태)
        let Some((label, n, sites)) = site else { return MediaState { app_only, ..Default::default() } };
        let mut pos = n.pos;
        if n.playing {
            pos += n.at.elapsed().as_secs_f64();
        }
        return MediaState {
            has: !n.title.is_empty() || n.playing,
            app: site_name(&label).into(),
            title: if n.title.is_empty() { site_name(&label).into() } else { n.title },
            artist: n.artist,
            playing: n.playing,
            position: if n.dur > 0.0 { pos.min(n.dur) } else { pos },
            duration: n.dur,
            repeat: if label == "ytmusic" { rep_of(&n.repeat) } else { None },
            like: n.like,
            art: n.art,
            can_prev: true,
            can_next: true,
            can_seek: n.dur > 0.0,
            site: label,
            sites,
            app_only,
            ..Default::default()
        };
    };
    let mut m = MediaState { has: true, app_only, ..Default::default() };
    m.app = s.SourceAppUserModelId().map(|h| h.to_string()).unwrap_or_default();
    if let Ok(op) = s.TryGetMediaPropertiesAsync() {
        if let Ok(p) = op.get() {
            m.title = p.Title().map(|h| h.to_string()).unwrap_or_default();
            m.artist = p.Artist().map(|h| h.to_string()).unwrap_or_default();
            m.album = p.AlbumTitle().map(|h| h.to_string()).unwrap_or_default();
        }
    }
    if let Ok(pb) = s.GetPlaybackInfo() {
        m.playing = pb.PlaybackStatus().map(|x| x == Status::Playing).unwrap_or(false);
        m.shuffle = pb.IsShuffleActive().ok().and_then(|r| r.Value().ok());
        m.repeat = pb.AutoRepeatMode().ok().and_then(|r| r.Value().ok()).map(|r| {
            match r {
                MediaPlaybackAutoRepeatMode::Track => "one",
                MediaPlaybackAutoRepeatMode::List => "all",
                _ => "none",
            }
            .to_string()
        });
        if let Ok(c) = pb.Controls() {
            m.can_prev = c.IsPreviousEnabled().unwrap_or(false);
            m.can_next = c.IsNextEnabled().unwrap_or(false);
            m.can_seek = c.IsPlaybackPositionEnabled().unwrap_or(false);
        }
    }
    if let Ok(tl) = s.GetTimelineProperties() {
        let start = tl.StartTime().map(|t| t.Duration).unwrap_or(0);
        let end = tl.EndTime().map(|t| t.Duration).unwrap_or(0);
        let mut pos = tl.Position().map(|t| t.Duration).unwrap_or(0) - start;
        // 앱은 위치를 가끔만 알려 줘서, 재생 중이면 마지막으로 알려 준 뒤 흐른 시간을 더함
        if m.playing {
            if let Ok(upd) = tl.LastUpdatedTime() {
                let diff = now_ticks() - upd.UniversalTime;
                if diff > 0 && diff < 10_000_000 * 60 * 60 {
                    pos += diff;
                }
            }
        }
        m.duration = (end - start).max(0) as f64 / 1e7;
        m.position = (pos.max(0) as f64 / 1e7).min(if m.duration > 0.0 { m.duration } else { f64::MAX });
    }
    if let Some((label, n, sites)) = site {
        // 도구함 재생기: 조작은 그 페이지에서 (셔플 · 반복 · 좋아요는 YouTube Music 페이지 단추)
        m.app = site_name(&label).into();
        m.art = n.art;
        m.can_prev = true;
        m.can_next = true;
        if m.duration <= 0.0 && n.dur > 0.0 {
            m.duration = n.dur;
            m.position = if n.playing { n.pos + n.at.elapsed().as_secs_f64() } else { n.pos }.min(n.dur);
            m.can_seek = true;
        }
        if label == "ytmusic" {
            m.repeat = rep_of(&n.repeat);
            m.like = n.like;
        } else {
            m.shuffle = None;
            m.repeat = None;
        }
        m.site = label;
        m.sites = sites;
    }
    m
}

fn rep_of(r: &str) -> Option<String> {
    match r {
        "ONE" => Some("one".into()),
        "ALL" => Some("all".into()),
        "NONE" => Some("none".into()),
        _ => None,
    }
}

/// 앨범 사진 (PNG/JPEG, base64 data URL)
pub fn thumbnail(want: Option<String>) -> Option<String> {
    on_mta(move || thumbnail_inner(want.as_deref())).flatten()
}

fn thumbnail_inner(want: Option<&str>) -> Option<String> {
    let s = session_for(want)?;
    let p = s.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let r = p.Thumbnail().ok()?;
    let stream = r.OpenReadAsync().ok()?.get().ok()?;
    let ct = stream.ContentType().map(|h| h.to_string()).unwrap_or_else(|_| "image/png".into());
    let size = stream.Size().ok()? as u32;
    if size == 0 {
        return None;
    }
    let reader = DataReader::CreateDataReader(&stream).ok()?;
    reader.LoadAsync(size).ok()?.get().ok()?;
    let mut buf = vec![0u8; size as usize];
    reader.ReadBytes(&mut buf).ok()?;
    Some(format!("data:{};base64,{}", if ct.is_empty() { "image/png" } else { &ct }, base64::engine::general_purpose::STANDARD.encode(buf)))
}

pub fn control(action: &str, value: f64) -> bool {
    let a = action.to_string();
    on_mta(move || control_inner(&a, value)).unwrap_or(false)
}

fn control_inner(action: &str, value: f64) -> bool {
    let Some(s) = session() else { return false };
    let r = match action {
        "toggle" => s.TryTogglePlayPauseAsync(),
        "play" => s.TryPlayAsync(),
        "pause" => s.TryPauseAsync(),
        "next" => s.TrySkipNextAsync(),
        "prev" => s.TrySkipPreviousAsync(),
        "seek" => {
            let start = s.GetTimelineProperties().and_then(|t| t.StartTime()).map(|t| t.Duration).unwrap_or(0);
            s.TryChangePlaybackPositionAsync(start + (value * 1e7) as i64)
        }
        "shuffle" => s.TryChangeShuffleActiveAsync(value > 0.5),
        "repeat" => s.TryChangeAutoRepeatModeAsync(match value as i32 {
            1 => MediaPlaybackAutoRepeatMode::Track,
            2 => MediaPlaybackAutoRepeatMode::List,
            _ => MediaPlaybackAutoRepeatMode::None,
        }),
        _ => return false,
    };
    r.and_then(|op| op.get()).unwrap_or(false)
}

// MARK: 볼륨 · 소리 세기

fn endpoint<T: windows::core::Interface>() -> Option<T> {
    com();
    unsafe {
        let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let dev = en.GetDefaultAudioEndpoint(eRender, eConsole).ok()?;
        dev.Activate::<T>(CLSCTX_ALL, None).ok()
    }
}

/// 0~1, 음소거면 음수로
pub fn volume(set: Option<f64>) -> f64 {
    on_mta(move || volume_inner(set)).unwrap_or(0.0)
}

fn volume_inner(set: Option<f64>) -> f64 {
    let Some(v) = endpoint::<IAudioEndpointVolume>() else { return 0.0 };
    unsafe {
        if let Some(x) = set {
            let _ = v.SetMasterVolumeLevelScalar(x.clamp(0.0, 1.0) as f32, std::ptr::null());
            if x > 0.0 {
                let _ = v.SetMute(false, std::ptr::null());
            }
        }
        let lvl = v.GetMasterVolumeLevelScalar().unwrap_or(0.0) as f64;
        let mute = v.GetMute().map(|b| b.as_bool()).unwrap_or(false);
        if mute {
            -lvl.max(0.0001)
        } else {
            lvl
        }
    }
}

// MARK: 청력 보호

#[derive(Serialize, Clone, Default)]
pub struct Hearing {
    /// 지금 귀에 들어가는 어림 크기 (dB)
    pub db: f64,
    /// 오늘 들은 양 (%, 100 이 하루 허용량)
    pub dose: f64,
    /// 오늘 날짜 (YYYY-MM-DD)
    pub day: String,
    /// 크기 제한 (dB, 0 이면 끔)
    pub limit: f64,
}

static HEARING: Mutex<Option<Hearing>> = Mutex::new(None);
static HEARING_ON: AtomicBool = AtomicBool::new(false);
/// 이어폰 최대 크기 (볼륨 100% · 가장 큰 소리일 때 dB) — 이어폰마다 달라서 설정으로 바꿈
static EAR_MAX: Mutex<f64> = Mutex::new(100.0);

fn today() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!("{:04}-{:02}-{:02}", t.wYear, t.wMonth, t.wDay)
}

fn hearing_file(dir: &PathBuf) -> PathBuf {
    dir.join("hearing.json")
}

/// 0.1초마다 소리 세기를 재서 1초마다 크기 · 오늘 들은 양을 고침 (켜져 있을 때만)
pub fn start_hearing(config_dir: PathBuf) {
    let saved: Option<Hearing> = std::fs::read_to_string(hearing_file(&config_dir))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .map(|v| Hearing {
            db: 0.0,
            dose: v["dose"].as_f64().unwrap_or(0.0),
            day: v["day"].as_str().unwrap_or("").to_string(),
            limit: v["limit"].as_f64().unwrap_or(0.0),
        });
    *HEARING.lock().unwrap() = Some(saved.unwrap_or_default());
    std::thread::spawn(move || {
        com();
        let mut meter: Option<IAudioMeterInformation> = None;
        let mut vol: Option<IAudioEndpointVolume> = None;
        let mut energy = 0.0f64;
        let mut n = 0;
        let mut over = 0;
        let mut ticks = 0u64;
        loop {
            std::thread::sleep(Duration::from_millis(100));
            if !HEARING_ON.load(Ordering::Relaxed) {
                continue;
            }
            ticks += 1;
            // 스피커가 바뀔 수 있어 30초마다 다시 잡음
            if meter.is_none() || ticks % 300 == 0 {
                meter = endpoint::<IAudioMeterInformation>();
                vol = endpoint::<IAudioEndpointVolume>();
            }
            let peak = meter.as_ref().and_then(|m| unsafe { m.GetPeakValue().ok() }).unwrap_or(0.0) as f64;
            energy += peak * peak;
            n += 1;
            if n < 10 {
                continue;
            }
            let rms = (energy / n as f64).sqrt();
            energy = 0.0;
            n = 0;
            let (vol_db, muted, scalar) = match &vol {
                Some(v) => unsafe {
                    (
                        v.GetMasterVolumeLevel().unwrap_or(0.0) as f64,
                        v.GetMute().map(|b| b.as_bool()).unwrap_or(false),
                        v.GetMasterVolumeLevelScalar().unwrap_or(0.0) as f64,
                    )
                },
                None => (0.0, false, 0.0),
            };
            let ear = *EAR_MAX.lock().unwrap();
            let db = if muted || rms < 1e-5 { 0.0 } else { (ear + 20.0 * rms.log10() + vol_db).max(0.0) };
            let mut g = HEARING.lock().unwrap();
            let Some(hs) = g.as_mut() else { continue };
            let day = today();
            if hs.day != day {
                hs.day = day;
                hs.dose = 0.0;
            }
            hs.db = db;
            // 하루 허용량: 85dB 로 8시간, 3dB 커질 때마다 절반 (NIOSH)
            if db >= 70.0 {
                let allowed = 8.0 * 3600.0 / 2f64.powf((db - 85.0) / 3.0);
                hs.dose += 100.0 / allowed;
            }
            // 크기 제한: 2초 넘게 넘으면 볼륨을 조금씩 내림
            if hs.limit > 0.0 && db > hs.limit {
                over += 1;
                if over >= 2 {
                    if let Some(v) = &vol {
                        unsafe {
                            let _ = v.SetMasterVolumeLevelScalar((scalar * 0.9) as f32, std::ptr::null());
                        }
                    }
                    over = 0;
                }
            } else {
                over = 0;
            }
            if ticks % 300 == 0 {
                let _ = std::fs::write(
                    hearing_file(&config_dir),
                    serde_json::json!({ "day": hs.day, "dose": hs.dose, "limit": hs.limit }).to_string(),
                );
            }
        }
    });
}

pub fn hearing(on: Option<bool>, limit: Option<f64>, ear_max: Option<f64>) -> Hearing {
    if let Some(on) = on {
        HEARING_ON.store(on, Ordering::Relaxed);
    }
    if let Some(e) = ear_max {
        *EAR_MAX.lock().unwrap() = e.clamp(80.0, 120.0);
    }
    let mut g = HEARING.lock().unwrap();
    let hs = g.get_or_insert_with(Hearing::default);
    if let Some(l) = limit {
        hs.limit = l;
    }
    if !HEARING_ON.load(Ordering::Relaxed) {
        hs.db = 0.0;
    }
    hs.clone()
}

#[cfg(test)]
mod site_tests {
    use super::*;
    fn now(t: &str, playing: bool) -> Now {
        Now { title: t.into(), artist: String::new(), art: String::new(), playing, repeat: String::new(), like: String::new(), pos: 0.0, dur: 0.0, at: Instant::now() }
    }
    #[test]
    fn newest_player_pauses_the_rest() {
        // YouTube Music 재생 중
        assert!(site_update("ytmusic", now("song", false), false).is_empty());
        let p = site_update("ytmusic", now("song", true), false);
        assert_eq!(p, vec!["yt-video", "netflix"], "music starting counts as a start even without s=1");
        // Netflix 첫 화면의 소리 없는 예고편: 재생 중이 아님 → 아무것도 안 멈춤
        assert!(site_update("netflix", now("", false), false).is_empty());
        // Netflix 에서 소리 나게 재생 시작 ('시작' 알림이 빠졌어도) → YouTube Music 멈춤, Netflix 로 넘어감
        let p = site_update("netflix", now("Show", true), false);
        assert!(p.contains(&"ytmusic".to_string()), "{p:?}");
        assert_eq!(pick_site(None).unwrap().0, "netflix");
        // 계속 재생 중인 알림은 다시 멈추지 않음
        assert!(site_update("netflix", now("Show", true), false).is_empty());
        // ‹ › 로 돌아가기
        assert_eq!(site_select(-1), "ytmusic");
    }
}
