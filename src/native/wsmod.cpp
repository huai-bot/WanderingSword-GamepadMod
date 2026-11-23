// Wandering Sword gamepad helper (xinput1_3 proxy)
//  - right stick -> mouse (constant speed) with UI magnetism; A = left click when pointing at a button
//  - game-style sword cursor drawn on top of everything, desktop cursor hidden while game focused
//  - world map: right stick returned to the game (native drag/zoom)
//  - world map: Y (gamepad) / F (keyboard) opens a categorized teleport panel of visited places
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <xinput.h>
#include <wincodec.h>
#include <mmsystem.h>
#include <shobjidl.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#pragma comment(lib, "advapi32.lib")
#include <cmath>
#include <cstdio>
#include <cwchar>
#include <vector>
#include <string>

#define DATA_DIR L"D:\\TOOLS\\AWSdata\\WanderingSword\\"

// ============================================================ logging
static void Log(const char* fmt, ...) {
    FILE* f = nullptr; if (_wfopen_s(&f, DATA_DIR L"wsmod.log", L"a") != 0 || !f) return;
    SYSTEMTIME t; GetLocalTime(&t); fprintf(f, "[%02d:%02d:%02d] ", t.wHour, t.wMinute, t.wSecond);
    va_list a; va_start(a, fmt); vfprintf(f, fmt, a); va_end(a); fputc('\n', f); fclose(f);
}

// ============================================================ quick-battle audio (only this process)
// Keep the user's volume and original mute state. COM objects live only on this worker, not the game thread.
// Lua sends a heartbeat independently of the mask; after 500 ms without it, restore every session we changed.
static volatile LONG g_muteWanted = 0, g_muteTick = 0;
extern "C" __declspec(dllexport) int wsmod_mute_0(void*) { InterlockedExchange(&g_muteWanted, 0); return 0; }
extern "C" __declspec(dllexport) int wsmod_mute_1(void*) {
    InterlockedExchange(&g_muteTick, (LONG)GetTickCount());
    InterlockedExchange(&g_muteWanted, 1); return 0;
}
struct MutedSession { std::wstring id; ISimpleAudioVolume* volume; BOOL original; };
static void MuteGameSessions(IMMDeviceEnumerator* devices, std::vector<MutedSession>& saved) {
    IMMDeviceCollection* outputs = nullptr;
    if (FAILED(devices->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &outputs))) return;
    UINT count = 0; outputs->GetCount(&count);
    for (UINT d = 0; d < count; ++d) {
        IMMDevice* device = nullptr; IAudioSessionManager2* manager = nullptr; IAudioSessionEnumerator* sessions = nullptr;
        if (SUCCEEDED(outputs->Item(d, &device)) &&
            SUCCEEDED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, (void**)&manager)) &&
            SUCCEEDED(manager->GetSessionEnumerator(&sessions))) {
            int n = 0; sessions->GetCount(&n);
            for (int i = 0; i < n; ++i) {
                IAudioSessionControl* control = nullptr; IAudioSessionControl2* info = nullptr;
                ISimpleAudioVolume* volume = nullptr; LPWSTR instance = nullptr; DWORD pid = 0;
                if (SUCCEEDED(sessions->GetSession(i, &control)) &&
                    SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&info))) &&
                    SUCCEEDED(info->GetProcessId(&pid)) && pid == GetCurrentProcessId() &&
                    SUCCEEDED(info->GetSessionInstanceIdentifier(&instance)) && instance &&
                    SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&volume)))) {
                    bool known = false;
                    for (const auto& s : saved) if (s.id == instance) { known = true; break; }
                    if (!known) {
                        BOOL original = FALSE;
                        if (SUCCEEDED(volume->GetMute(&original)) && SUCCEEDED(volume->SetMute(TRUE, nullptr))) {
                            saved.push_back({ instance, volume, original }); volume = nullptr;
                            Log("quick battle audio muted (saved mute=%d)", (int)original);
                        }
                    }
                }
                if (instance) CoTaskMemFree(instance);
                if (volume) volume->Release();
                if (info) info->Release();
                if (control) control->Release();
            }
        }
        if (sessions) sessions->Release();
        if (manager) manager->Release();
        if (device) device->Release();
    }
    outputs->Release();
    // Also hold the mute if the game refreshes its audio session settings during startup.
    for (auto& s : saved) {
        BOOL muted = FALSE;
        if (SUCCEEDED(s.volume->GetMute(&muted)) && !muted) s.volume->SetMute(TRUE, nullptr);
    }
}
static void RestoreGameAudio(std::vector<MutedSession>& saved) {
    for (auto& s : saved) {
        HRESULT hr = s.volume->SetMute(s.original, nullptr);
        if (SUCCEEDED(hr)) Log("quick battle audio restored (mute=%d)", (int)s.original);
        else Log("quick battle audio restore: session unavailable (0x%08lx)", (unsigned long)hr);
        s.volume->Release();
    }
    saved.clear();
}
static DWORD WINAPI AudioThread(LPVOID) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) { Log("audio worker unavailable (0x%08lx)", (unsigned long)hr); return 0; }
    IMMDeviceEnumerator* devices = nullptr;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices));
    if (FAILED(hr)) { Log("audio sessions unavailable (0x%08lx)", (unsigned long)hr); CoUninitialize(); return 0; }
    std::vector<MutedSession> saved; DWORD lastScan = 0; bool active = false;
    for (;;) {
        LONG requested = InterlockedCompareExchange(&g_muteWanted, 0, 0);
        DWORD heartbeat = (DWORD)InterlockedCompareExchange(&g_muteTick, 0, 0);
        // Read the clock after the heartbeat: Lua can publish a newer tick while this thread is pre-empted.
        // Subtracting that newer heartbeat from an older local tick underflows and briefly unmutes the game.
        DWORD tick = GetTickCount();
        bool want = requested != 0 && tick - heartbeat < 500;
        if (want) {
            if (!active || tick - lastScan >= 250) { MuteGameSessions(devices, saved); lastScan = tick; }
        } else if (active) RestoreGameAudio(saved);
        active = want;
        Sleep(25);
    }
}

// ============================================================ real xinput
typedef DWORD (WINAPI *PFN_GetState)(DWORD, XINPUT_STATE*);
typedef DWORD (WINAPI *PFN_SetState)(DWORD, XINPUT_VIBRATION*);
typedef DWORD (WINAPI *PFN_GetCaps)(DWORD, DWORD, XINPUT_CAPABILITIES*);
typedef void  (WINAPI *PFN_Enable)(BOOL);
typedef DWORD (WINAPI *PFN_GetDS)(DWORD, GUID*, GUID*);
typedef DWORD (WINAPI *PFN_GetBat)(DWORD, BYTE, XINPUT_BATTERY_INFORMATION*);
typedef DWORD (WINAPI *PFN_GetKey)(DWORD, DWORD, PXINPUT_KEYSTROKE);
typedef DWORD (WINAPI *PFN_101)(DWORD, DWORD, void*);
typedef DWORD (WINAPI *PFN_1DW)(DWORD);
static HMODULE g_real; static HMODULE g_self;
static PFN_GetState pGetState, pGetStateEx; static PFN_SetState pSetState; static PFN_GetCaps pGetCaps;
static PFN_Enable pEnable; static PFN_GetDS pGetDS; static PFN_GetBat pGetBat; static PFN_GetKey pGetKey;
static PFN_101 p101; static PFN_1DW p102, p103;
static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;

// ============================================================ config
static double CFG_SPEED = 1300.0;   // pixels / second, constant (no acceleration by tilt)
static double CFG_DEADZONE = 3000.0;
static bool   CFG_SNAP = true;      // UI magnetism
static double CFG_SNAP_RADIUS = 40; // px around a button that still snaps
static double CFG_FRICTION = 0.60;  // speed factor while over a button
static void LoadConfig() {
    CFG_SPEED = (double)GetPrivateProfileIntW(L"mouse", L"speed", 1300, DATA_DIR L"wsmod.ini");
    CFG_DEADZONE = (double)GetPrivateProfileIntW(L"mouse", L"deadzone", 3000, DATA_DIR L"wsmod.ini");
    CFG_SNAP = GetPrivateProfileIntW(L"snap", L"enable", 1, DATA_DIR L"wsmod.ini") != 0;
    CFG_SNAP_RADIUS = (double)GetPrivateProfileIntW(L"snap", L"radius", 40, DATA_DIR L"wsmod.ini");
    CFG_FRICTION = GetPrivateProfileIntW(L"snap", L"friction", 60, DATA_DIR L"wsmod.ini") / 100.0;
    if (CFG_SPEED < 100) CFG_SPEED = 100;
}

// ============================================================ shared state
static volatile LONG g_primary = -1;
static volatile LONG g_mapOpen = 0;
static volatile LONG g_battle = 0;    // in battle: everything native, mod pointer off
static volatile LONG g_fight = 0;     // a real fight (fight.flag): Start stays native. battle.flag is also 1 on the overworld / loading
// character screen: Lua tells us (wsmod_nav_* exports, refreshed every tick) which inputs would move the
// focus into 属性/装备 from where it is now. Those presses are hidden from the game and reported to Lua in
// trig.req ("L"/"R" = LT/RT, "<" ">" "^" "v" = d-pad or left stick), Lua then jumps itself -> no flash.
enum { NAV_UP = 1, NAV_DOWN = 2, NAV_LEFT = 4, NAV_RIGHT = 8, NAV_TRIG = 16 };
static volatile LONG g_navMask = 0, g_navStage = 0; static volatile DWORD g_navTime = 0;
static volatile LONG g_ev[6];          // L R < > ^ v
static const char EV_CH[6] = { 'L', 'R', '<', '>', '^', 'v' };
static LONG NavMask() { return (GetTickCount() - g_navTime < 300) ? g_navMask : 0; }   // stale -> nothing blocked
extern "C" __declspec(dllexport) int wsmod_nav_begin(void*) { g_navStage = 0; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_up(void*) { g_navStage |= NAV_UP; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_down(void*) { g_navStage |= NAV_DOWN; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_left(void*) { g_navStage |= NAV_LEFT; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_right(void*) { g_navStage |= NAV_RIGHT; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_trig(void*) { g_navStage |= NAV_TRIG; return 0; }
extern "C" __declspec(dllexport) int wsmod_nav_commit(void*) {
    LONG m = g_navStage;
    if (m != g_navMask) Log("nav mask %s%s%s%s%s", m & NAV_TRIG ? "T" : "-", m & NAV_UP ? "U" : "-", m & NAV_DOWN ? "D" : "-", m & NAV_LEFT ? "L" : "-", m & NAV_RIGHT ? "R" : "-");
    InterlockedExchange(&g_navMask, m); g_navTime = GetTickCount(); return 0;
}
static volatile double g_uiScale = 1.0;   // game client height / 1080
static volatile LONG g_menuOpen = 0;
static HWND g_menuWnd;

static bool GameFocused() {
    HWND fg = GetForegroundWindow(); if (!fg || IsIconic(fg)) return false;
    DWORD pid = 0; GetWindowThreadProcessId(fg, &pid); if (pid != GetCurrentProcessId()) return false;
    wchar_t cls[64] = {}; GetClassNameW(fg, cls, 64);
    return wcscmp(cls, L"UnrealWindow") == 0;
}
static HWND GameWindow() { HWND fg = GetForegroundWindow(); return GameFocused() ? fg : nullptr; }

static std::wstring ReadSmallFile(const wchar_t* name) {
    std::wstring path = std::wstring(DATA_DIR) + name, out;
    FILE* f = nullptr; if (_wfopen_s(&f, path.c_str(), L"rt, ccs=UTF-8") != 0 || !f) return out;
    wchar_t buf[1024]; while (fgetws(buf, 1024, f)) out += buf; fclose(f); return out;
}

// ============================================================ UI targets (button rects, screen pixels)
// The Lua side calls wsmod_scan() on the game thread right after it has validated a list of visible
// buttons and written their addresses to scan_in.txt; we ask each one for its cached geometry through
// the engine's own reflection call (ProcessEvent) and keep the resulting rectangles for snapping.
struct URect { float l, t, r, b; };
static SRWLOCK g_rectLock = SRWLOCK_INIT;
static std::vector<URect> g_rects;
static volatile DWORD g_rectTime = 0;    // tick of last successful scan
static volatile LONG g_scanOk = 0;       // at least one scan produced data
static volatile LONG g_ptrActive = 0;    // pointer recently driven by the right stick (read by Lua)
typedef void (__fastcall *PFN_ProcessEvent)(void* obj, void* fn, void* params);
static PFN_ProcessEvent g_pe; static bool g_peChecked;
static const uintptr_t PE_RVA = 0x179A420;   // UObject::ProcessEvent in JH-Win64-Shipping (v1.24.32)
static bool ResolveProcessEvent(void* anyObj) {
    if (g_peChecked) return g_pe != nullptr;
    g_peChecked = true;
    uintptr_t base = (uintptr_t)GetModuleHandleW(nullptr), want = base + PE_RVA;
    void** vt = *(void***)anyObj;
    for (int i = 0; i < 0x100; i++) if ((uintptr_t)vt[i] == want) { g_pe = (PFN_ProcessEvent)want; Log("ProcessEvent verified at vtable[%d]", i); return true; }
    Log("ProcessEvent not found in vtable: UI snapping disabled (game version changed?)");
    return false;
}
// kept free of C++ objects so it can use SEH
static bool SafeProcessEvent(void* obj, void* fn, unsigned char* buf) {
    __try { g_pe(obj, fn, buf); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// Two-phase scan (both called by Lua on the game thread, back to back in the same tick):
//  wsmod_scan:   scan_in.txt  = GetCachedGeometry fn + every Button address. Reads geometry natively
//                (cheap) and writes scan_mid.txt = addresses that have a real on-screen geometry.
//  wsmod_commit: scan_ok.txt  = subset that Lua confirmed visible through the whole parent chain.
struct GRec { unsigned long long a; URect r; };
static std::vector<GRec> g_pending;
extern "C" __declspec(dllexport) int wsmod_scan(void* /*lua_State*/) {
    FILE* f = nullptr; if (_wfopen_s(&f, DATA_DIR L"scan_in.txt", L"rb") != 0 || !f) return 0;
    unsigned long long fn = 0, a = 0; g_pending.clear();
    if (fscanf_s(f, "%llx", &fn) == 1 && fn) {
        while (fscanf_s(f, "%llx", &a) == 1) {
            if (!a) continue;
            if (!ResolveProcessEvent((void*)a)) break;
            alignas(16) unsigned char buf[512] = {};
            if (!SafeProcessEvent((void*)a, (void*)fn, buf)) continue;
            float sx = *(float*)(buf + 0), sy = *(float*)(buf + 4), sc = *(float*)(buf + 8);
            float ax = *(float*)(buf + 12), ay = *(float*)(buf + 16);
            if (!(sc > 0.05f && sc < 20.f) || !(sx > 0 && sy > 0)) continue;
            float w = sx * sc, h = sy * sc;
            if (w < 6 || h < 6 || w > 4000 || h > 3000 || ax < -20000 || ay < -20000 || ax > 20000 || ay > 20000) continue;
            g_pending.push_back({ a, { ax, ay, ax + w, ay + h } });
        }
    }
    fclose(f);
    FILE* m = nullptr;
    if (_wfopen_s(&m, DATA_DIR L"scan_mid.txt", L"wb") == 0 && m) { for (auto& p : g_pending) fprintf(m, "%llX\n", p.a); fclose(m); }
    return 0;
}
extern "C" __declspec(dllexport) int wsmod_commit(void* /*lua_State*/) {
    std::vector<URect> out; out.reserve(g_pending.size());
    FILE* f = nullptr;
    if (_wfopen_s(&f, DATA_DIR L"scan_ok.txt", L"rb") == 0 && f) {
        unsigned long long a = 0;
        while (fscanf_s(f, "%llx", &a) == 1) for (auto& p : g_pending) if (p.a == a) { out.push_back(p.r); break; }
        fclose(f);
    }
    g_pending.clear();
    AcquireSRWLockExclusive(&g_rectLock); g_rects.swap(out); ReleaseSRWLockExclusive(&g_rectLock);
    g_rectTime = GetTickCount(); if (!g_rects.empty()) g_scanOk = 1;
    if (GetFileAttributesW(DATA_DIR L"scan_debug.flag") != INVALID_FILE_ATTRIBUTES) {
        FILE* d = nullptr;
        if (_wfopen_s(&d, DATA_DIR L"scan_out.txt", L"wb") == 0 && d) {
            AcquireSRWLockShared(&g_rectLock);
            for (auto& r : g_rects) fprintf(d, "%.0f %.0f %.0f %.0f\n", r.l, r.t, r.r - r.l, r.b - r.t);
            ReleaseSRWLockShared(&g_rectLock); fclose(d);
        }
    }
    static int logged = 0;
    if (logged < 3 && !g_rects.empty()) { logged++; URect r = g_rects[0]; Log("scan: %d targets, e.g. %.0f,%.0f %.0fx%.0f", (int)g_rects.size(), r.l, r.t, r.r - r.l, r.b - r.t); }
    return 0;
}
static bool RectsFresh() { return GetTickCount() - g_rectTime < 900; }
// smallest target containing p (margin px), or nearest within radius; returns false if none
static bool FindTarget(POINT p, double radius, URect* hit, bool* inside) {
    if (!RectsFresh()) return false;
    HWND gw = GameWindow(); RECT cr{}; if (gw) { GetClientRect(gw, &cr); }
    double maxW = gw ? (cr.right - cr.left) * 0.7 : 99999, maxH = gw ? (cr.bottom - cr.top) * 0.7 : 99999;
    bool found = false, in = false; double best = 1e18;
    AcquireSRWLockShared(&g_rectLock);
    for (auto& r : g_rects) {
        double w = r.r - r.l, h = r.b - r.t; if (w > maxW || h > maxH) continue;
        double dx = p.x < r.l ? r.l - p.x : (p.x > r.r ? p.x - r.r : 0);
        double dy = p.y < r.t ? r.t - p.y : (p.y > r.b ? p.y - r.b : 0);
        double d = sqrt(dx * dx + dy * dy);
        if (d == 0) { double area = w * h; if (!in || area < best) { best = area; *hit = r; in = true; found = true; } }
        else if (!in && d <= radius && d < best) { best = d; *hit = r; found = true; }
    }
    ReleaseSRWLockShared(&g_rectLock);
    if (inside) *inside = in;
    return found;
}

// ============================================================ menu commands
enum { CMD_OPEN = 1, CMD_CLOSE, CMD_UP, CMD_DOWN, CMD_LEFT, CMD_RIGHT, CMD_TABL, CMD_TABR, CMD_OK, CMD_TOGGLE, CMD_PAGEUP, CMD_PAGEDN };
static void MenuCmd(int c) { if (g_menuWnd) PostMessageW(g_menuWnd, WM_APP + 10, c, 0); }

// ============================================================ desktop cursor hide
static volatile LONG g_sysHidden = 0;
static void HideSysCursor(bool hide) {
    if (hide == (g_sysHidden != 0)) return;
    if (hide) {
        BYTE andm[128], xorm[128]; memset(andm, 0xFF, sizeof(andm)); memset(xorm, 0, sizeof(xorm));
        static const DWORD ids[] = { 32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650,32651 };
        for (DWORD id : ids) { HCURSOR b = CreateCursor(g_self, 0, 0, 32, 32, andm, xorm); if (b) SetSystemCursor(b, id); }
        g_sysHidden = 1;
    } else { SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0); g_sysHidden = 0; }
}

// ============================================================ cursor overlay (game sword cursor)
static HBITMAP g_curBmp; static int g_curW, g_curH; static double g_curScale = 0;
static bool LoadCursorBitmap(double scale) {
    IWICImagingFactory* fac = nullptr; IWICBitmapDecoder* dec = nullptr; IWICBitmapFrameDecode* fr = nullptr;
    IWICBitmapScaler* sc = nullptr; IWICFormatConverter* cv = nullptr; bool ok = false;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&fac)))) return false;
    if (SUCCEEDED(fac->CreateDecoderFromFilename(DATA_DIR L"cursor.png", nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &dec)) &&
        SUCCEEDED(dec->GetFrame(0, &fr))) {
        UINT w = 0, h = 0; fr->GetSize(&w, &h);
        UINT sw = (UINT)(w * scale + 0.5), sh = (UINT)(h * scale + 0.5);
        if (SUCCEEDED(fac->CreateBitmapScaler(&sc)) && SUCCEEDED(sc->Initialize(fr, sw, sh, WICBitmapInterpolationModeFant)) &&
            SUCCEEDED(fac->CreateFormatConverter(&cv)) &&
            SUCCEEDED(cv->Initialize(sc, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) {
            BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(bi.bmiHeader); bi.bmiHeader.biWidth = sw; bi.bmiHeader.biHeight = -(LONG)sh;
            bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
            void* bits = nullptr; HBITMAP bmp = CreateDIBSection(nullptr, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
            if (bmp && SUCCEEDED(cv->CopyPixels(nullptr, sw * 4, sw * sh * 4, (BYTE*)bits))) {
                if (g_curBmp) DeleteObject(g_curBmp);
                g_curBmp = bmp; g_curW = sw; g_curH = sh; ok = true;
            } else if (bmp) DeleteObject(bmp);
        }
    }
    if (cv) cv->Release(); if (sc) sc->Release(); if (fr) fr->Release(); if (dec) dec->Release(); fac->Release();
    return ok;
}
static void PushCursorBitmap(HWND h, POINT pt) {
    if (!g_curBmp) return;
    HDC scr = GetDC(nullptr), mem = CreateCompatibleDC(scr); HGDIOBJ ob = SelectObject(mem, g_curBmp);
    SIZE sz{ g_curW, g_curH }; POINT src{ 0, 0 }; BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(h, scr, &pt, &sz, mem, &src, 0, &bf, ULW_ALPHA);
    SelectObject(mem, ob); DeleteDC(mem); ReleaseDC(nullptr, scr);
}
static LRESULT CALLBACK CurProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    if (m == WM_TIMER) {
        static bool clipped = false, shown = false;
        HWND gw = GameWindow();
        if (gw) {
            RECT r; GetClientRect(gw, &r); POINT a{ r.left, r.top }, b{ r.right, r.bottom };
            ClientToScreen(gw, &a); ClientToScreen(gw, &b);
            RECT cr{ a.x + 2, a.y + 2, b.x - 2, b.y - 2 };
            if (cr.right > cr.left && cr.bottom > cr.top) { ClipCursor(&cr); clipped = true; }
            double sc = (b.y - a.y) / 1080.0; sc = std::floor(sc * 4 + 0.5) / 4; if (sc < 1) sc = 1;
            g_uiScale = std::max(0.5, (b.y - a.y) / 1080.0);
            if (sc != g_curScale && LoadCursorBitmap(sc)) { g_curScale = sc; Log("cursor bitmap %dx%d", g_curW, g_curH); }
            if (g_battle) {
                HideSysCursor(false);
                if (shown) { ShowWindow(h, SW_HIDE); shown = false; }
            } else {
                POINT pt; GetCursorPos(&pt);
                PushCursorBitmap(h, pt);
                SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                HideSysCursor(true); shown = true;
            }
        } else {
            if (clipped) { ClipCursor(nullptr); clipped = false; }
            HideSysCursor(false);
            if (shown) { ShowWindow(h, SW_HIDE); shown = false; }
        }
        return 0;
    }
    if (m == WM_NCHITTEST) return HTTRANSPARENT;
    return DefWindowProcW(h, m, wp, lp);
}
static DWORD WINAPI CursorThread(LPVOID) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    WNDCLASSW wc{}; wc.lpfnWndProc = CurProc; wc.hInstance = g_self; wc.lpszClassName = L"WSModCursor"; RegisterClassW(&wc);
    HWND h = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        wc.lpszClassName, L"", WS_POPUP, 0, 0, 40, 40, nullptr, nullptr, g_self, nullptr);
    if (!h) { Log("ERROR cursor window %lu", GetLastError()); return 0; }
    SetTimer(h, 1, 8, nullptr); Log("cursor overlay ready");
    MSG msg; while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
    return 0;
}

// ============================================================ right stick -> mouse
static volatile DWORD g_lastStick = 0, g_lastNav = 0;   // last right-stick motion / last native navigation input
static bool g_moving, g_glide; static DWORD g_glideT0; static double g_gx0, g_gy0, g_gx1, g_gy1;
// pointer mode (mouse first): the right stick was used more recently than the d-pad / left stick.
// No timeout - it stays on until the player navigates with the d-pad or left stick again.
static volatile LONG g_ptrMode = 0;
static bool PointerMode() { return g_ptrMode != 0; }
static void MouseBtn(bool down) { INPUT in{}; in.type = INPUT_MOUSE; in.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; SendInput(1, &in, sizeof(in)); }
static DWORD WINAPI MouseThread(LPVOID) {
    timeBeginPeriod(1);
    double accX = 0, accY = 0; DWORD last = GetTickCount(); int n = 0;
    for (;;) {
        Sleep(8);
        DWORD now = GetTickCount(); double dt = (now - last) / 1000.0; last = now; if (dt > 0.05) dt = 0.05;
        { LONG any = 0, n[6];
          for (int k = 0; k < 6; k++) { n[k] = InterlockedExchange(&g_ev[k], 0); any |= n[k]; }
          if (any) {
            FILE* tf = nullptr;
            if (_wfopen_s(&tf, DATA_DIR L"trig.req", L"ab") == 0 && tf) { for (int k = 0; k < 6; k++) for (LONG i = 0; i < n[k]; i++) fputc(EV_CH[k], tf); fclose(tf); }
          } }
        if ((++n % 25) == 0) {
            std::wstring s = ReadSmallFile(L"map.flag");
            LONG nm = (!s.empty() && s[0] == L'1') ? 1 : 0;
            if (nm != g_mapOpen) { g_mapOpen = nm; Log("world map %s", nm ? "open" : "closed"); if (!nm && g_menuOpen) MenuCmd(CMD_CLOSE); }
            std::wstring bs = ReadSmallFile(L"battle.flag");
            LONG nb = (!bs.empty() && bs[0] == L'1') ? 1 : 0;
            if (nb != g_battle) { g_battle = nb; Log("battle %s: right stick %s", nb ? "start" : "end", nb ? "native" : "mouse"); }
            std::wstring fs = ReadSmallFile(L"fight.flag");
            LONG nf = (!fs.empty() && fs[0] == L'1') ? 1 : 0;
            if (nf != g_fight) { g_fight = nf; Log("fight %s: Start %s", nf ? "start" : "end", nf ? "native" : "-> character screen"); }
        }
        bool active = GameFocused() && !g_mapOpen && !g_menuOpen && !g_battle;
        LONG idx = g_primary; XINPUT_STATE st{};
        // pointer flag for the Lua scanner (only scan the UI while the pointer is in use)
        { LONG want = (GetTickCount() - g_lastStick < 4000 && active) ? 1 : 0;
          if (want != g_ptrActive) { g_ptrActive = want; FILE* pf = nullptr; if (_wfopen_s(&pf, DATA_DIR L"ptr.flag", L"wb") == 0 && pf) { fputc(want ? '1' : '0', pf); fclose(pf); } } }
        if (!active || idx < 0 || !pGetState || pGetState((DWORD)idx, &st) != ERROR_SUCCESS) {
            accX = accY = 0; g_moving = false; g_glide = false; continue;
        }
        double x = st.Gamepad.sThumbRX, y = st.Gamepad.sThumbRY, mag = sqrt(x * x + y * y);
        POINT cur; GetCursorPos(&cur);
        if (mag <= CFG_DEADZONE) {
            accX = accY = 0;
            if (g_moving) {                                   // stick released: snap onto the nearest button
                g_moving = false; URect t; bool in = false;
                if (CFG_SNAP && FindTarget(cur, CFG_SNAP_RADIUS * g_uiScale, &t, &in)) {
                    g_gx0 = cur.x; g_gy0 = cur.y; g_gx1 = (t.l + t.r) / 2; g_gy1 = (t.t + t.b) / 2;
                    // do not drag the pointer across a big button: only centre it on small/medium ones,
                    // on wide ones (list rows) just pull it inside
                    if (t.r - t.l > 260 * g_uiScale) g_gx1 = std::max<double>(t.l + 12, std::min<double>(t.r - 12, cur.x));
                    if (t.b - t.t > 160 * g_uiScale) g_gy1 = std::max<double>(t.t + 12, std::min<double>(t.b - 12, cur.y));
                    g_glide = true; g_glideT0 = now;
                }
            }
            if (g_glide) {
                double k = (now - g_glideT0) / 90.0; if (k >= 1) { k = 1; g_glide = false; }
                k = 1 - (1 - k) * (1 - k);
                SetCursorPos((int)lround(g_gx0 + (g_gx1 - g_gx0) * k), (int)lround(g_gy0 + (g_gy1 - g_gy0) * k));
            }
            continue;
        }
        g_moving = true; g_glide = false; g_lastStick = now;
        double factor = 1.0;
        if (CFG_SNAP) { URect t; bool in = false; if (FindTarget(cur, 0, &t, &in) && in) factor = CFG_FRICTION; }
        double sp = CFG_SPEED * factor * dt;              // constant speed: tilt only sets direction
        accX += x / mag * sp; accY -= y / mag * sp;
        LONG dx = (LONG)accX, dy = (LONG)accY; accX -= dx; accY -= dy;
        if (dx || dy) { INPUT in{}; in.type = INPUT_MOUSE; in.mi.dx = dx; in.mi.dy = dy; in.mi.dwFlags = MOUSEEVENTF_MOVE; SendInput(1, &in, sizeof(in)); }
    }
}

// ============================================================ teleport data
struct Place {
    std::wstring region, name; std::vector<std::wstring> levels;
    std::wstring stLv; double sx = 0, sy = 0, sz = 0; bool hasSt = false;
    // resolved
    bool visited = false, current = false; std::wstring tLv; double tx = 0, ty = 0, tz = 0;
};
static const wchar_t* REGIONS[6] = { L"中原", L"西域", L"关外", L"南疆", L"北地", L"海外" };
static std::vector<Place> g_all;
static std::vector<int> g_list[6];     // visited places per region (indices into g_all)
static int g_total[6];
static std::wstring g_curLv;

static std::vector<std::wstring> Split(const std::wstring& s, wchar_t d) {
    std::vector<std::wstring> r; size_t a = 0;
    for (;;) { size_t b = s.find(d, a); r.push_back(s.substr(a, b == std::wstring::npos ? std::wstring::npos : b - a)); if (b == std::wstring::npos) break; a = b + 1; }
    return r;
}
static void LoadPlaces() {
    if (g_all.empty()) {
        std::wstring all = ReadSmallFile(L"places.txt");
        for (auto& line : Split(all, L'\n')) {
            if (line.empty()) continue;
            auto c = Split(line, L'\t'); if (c.size() < 3) continue;
            Place p; p.region = c[0]; p.name = c[1]; p.levels = Split(c[2], L',');
            if (c.size() >= 5 && !c[3].empty()) { p.stLv = c[3]; p.hasSt = swscanf_s(c[4].c_str(), L"%lf,%lf,%lf", &p.sx, &p.sy, &p.sz) == 3; }
            g_all.push_back(p);
        }
        Log("places loaded: %d", (int)g_all.size());
    }
    // visited levels with first-entry positions
    struct V { std::wstring lv; double x, y, z; };
    std::vector<V> vis;
    for (auto& line : Split(ReadSmallFile(L"visited.txt"), L'\n')) {
        auto c = Split(line, L'|'); if (c.size() < 4) continue;
        V v{ c[0], _wtof(c[1].c_str()), _wtof(c[2].c_str()), _wtof(c[3].c_str()) }; vis.push_back(v);
    }
    g_curLv = ReadSmallFile(L"cur.txt"); while (!g_curLv.empty() && iswspace(g_curLv.back())) g_curLv.pop_back();
    for (int r = 0; r < 6; r++) { g_list[r].clear(); g_total[r] = 0; }
    for (int i = 0; i < (int)g_all.size(); i++) {
        Place& p = g_all[i]; p.visited = false; p.current = false;
        for (auto& lv : p.levels) if (lv == g_curLv) p.current = true;
        const V* first = nullptr; bool stVisited = false;
        for (auto& lv : p.levels) for (auto& v : vis) if (v.lv == lv) { if (!first) first = &v; if (p.hasSt && lv == p.stLv) stVisited = true; }
        if (first) {
            p.visited = true;
            if (stVisited) { p.tLv = p.stLv; p.tx = p.sx; p.ty = p.sy; p.tz = p.sz; }
            else { p.tLv = first->lv; p.tx = first->x; p.ty = first->y; p.tz = first->z; }
        }
        for (int r = 0; r < 6; r++) if (p.region == REGIONS[r]) { g_total[r]++; if (p.visited) g_list[r].push_back(i); }
    }
}
static int RegionOfCurrent() {
    for (auto& p : g_all) if (p.current) for (int r = 0; r < 6; r++) if (p.region == REGIONS[r]) return r;
    return 0;
}

// ============================================================ teleport panel
static const int COLS = 4, ROWS = 7;
static const int PW = 1000, CELLW = 228, CELLH = 54, GAP = 10, GX = 28, GY = 132, TABY = 70, TABH = 44, TABW = 148;
static const int PH = GY + ROWS * (CELLH + GAP) + 64;
static int g_tab = 0, g_sel = 0, g_top = 0, g_hoverTab = -1;
static std::wstring g_toast; static DWORD g_toastUntil;
static HFONT fTitle, fTab, fCell, fHint;

static RECT TabRect(int i) { RECT r{ GX + i * (TABW + 8), TABY, GX + i * (TABW + 8) + TABW, TABY + TABH }; return r; }
static RECT CellRect(int vis) { int c = vis % COLS, r = vis / COLS; RECT rc{ GX + c * (CELLW + GAP), GY + r * (CELLH + GAP), GX + c * (CELLW + GAP) + CELLW, GY + r * (CELLH + GAP) + CELLH }; return rc; }
static void Fill(HDC dc, RECT r, COLORREF c) { HBRUSH b = CreateSolidBrush(c); FillRect(dc, &r, b); DeleteObject(b); }
static void Frame(HDC dc, RECT r, COLORREF c, int w) { HPEN p = CreatePen(PS_SOLID, w, c); HGDIOBJ op = SelectObject(dc, p), ob = SelectObject(dc, GetStockObject(NULL_BRUSH)); Rectangle(dc, r.left, r.top, r.right, r.bottom); SelectObject(dc, op); SelectObject(dc, ob); DeleteObject(p); }
static void Text(HDC dc, const std::wstring& s, RECT r, COLORREF c, HFONT f, UINT fl) { SelectObject(dc, f); SetTextColor(dc, c); DrawTextW(dc, s.c_str(), -1, &r, fl | DT_SINGLELINE | DT_NOPREFIX); }

static void ClampSel() {
    int n = (int)g_list[g_tab].size();
    if (n == 0) { g_sel = 0; g_top = 0; return; }
    if (g_sel < 0) g_sel = 0; if (g_sel >= n) g_sel = n - 1;
    int row = g_sel / COLS;
    if (row < g_top) g_top = row; if (row >= g_top + ROWS) g_top = row - ROWS + 1;
}
static void DrawPanel(HDC dc) {
    const COLORREF BG = RGB(24, 21, 18), GOLD = RGB(206, 170, 98), INK = RGB(236, 226, 204), DIM = RGB(130, 120, 104);
    RECT all{ 0, 0, PW, PH }; Fill(dc, all, BG); Frame(dc, { 1, 1, PW - 1, PH - 1 }, GOLD, 2); Frame(dc, { 7, 7, PW - 7, PH - 7 }, RGB(90, 74, 46), 1);
    SetBkMode(dc, TRANSPARENT);
    Text(dc, L"驿路传送 · 已到访之地", { GX, 18, PW / 2 + 100, 60 }, GOLD, fTitle, DT_LEFT | DT_VCENTER);
    int visitedAll = 0, totalAll = 0; for (int r = 0; r < 6; r++) { visitedAll += (int)g_list[r].size(); totalAll += g_total[r]; }
    wchar_t buf[96]; swprintf_s(buf, L"已到访 %d / %d", visitedAll, totalAll);
    Text(dc, buf, { PW / 2, 18, PW - GX, 60 }, DIM, fHint, DT_RIGHT | DT_VCENTER);
    for (int i = 0; i < 6; i++) {
        RECT r = TabRect(i); bool on = i == g_tab;
        Fill(dc, r, on ? GOLD : (i == g_hoverTab ? RGB(56, 48, 36) : RGB(38, 33, 27)));
        if (!on) Frame(dc, r, RGB(90, 74, 46), 1);
        swprintf_s(buf, L"%s  %d/%d", REGIONS[i], (int)g_list[i].size(), g_total[i]);
        Text(dc, buf, r, on ? RGB(24, 18, 8) : (g_list[i].empty() ? DIM : INK), fTab, DT_CENTER | DT_VCENTER);
    }
    Text(dc, L"LB", { GX - 26, TABY, GX - 2, TABY + TABH }, DIM, fHint, DT_CENTER | DT_VCENTER);
    Text(dc, L"RB", { TabRect(5).right + 2, TABY, TabRect(5).right + 30, TABY + TABH }, DIM, fHint, DT_CENTER | DT_VCENTER);
    auto& L = g_list[g_tab]; int n = (int)L.size();
    if (n == 0) Text(dc, L"此区域尚未到访任何地点", { GX, GY, PW - GX, GY + 3 * CELLH }, DIM, fCell, DT_CENTER | DT_VCENTER);
    for (int v = 0; v < ROWS * COLS; v++) {
        int i = g_top * COLS + v; if (i >= n) break;
        Place& p = g_all[L[i]]; RECT r = CellRect(v); bool sel = i == g_sel;
        Fill(dc, r, sel ? GOLD : RGB(40, 35, 29));
        Frame(dc, r, sel ? RGB(250, 220, 150) : RGB(84, 70, 46), sel ? 2 : 1);
        RECT tr = r; tr.left += 16; tr.right -= 10;
        COLORREF tc = sel ? RGB(24, 18, 8) : (p.current ? DIM : INK);
        Text(dc, p.name, tr, tc, fCell, DT_LEFT | DT_VCENTER | DT_END_ELLIPSIS);
        if (p.current) Text(dc, L"当前", tr, sel ? RGB(60, 44, 20) : GOLD, fHint, DT_RIGHT | DT_VCENTER);
        else if (p.hasSt && p.tLv == p.stLv) Text(dc, L"驿站", tr, sel ? RGB(60, 44, 20) : DIM, fHint, DT_RIGHT | DT_VCENTER);
    }
    int rowsTotal = (n + COLS - 1) / COLS;
    if (rowsTotal > ROWS) {
        int trackT = GY, trackB = GY + ROWS * (CELLH + GAP) - GAP, x = PW - 16;
        Fill(dc, { x, trackT, x + 4, trackB }, RGB(60, 52, 40));
        int th = (trackB - trackT) * ROWS / rowsTotal, ty = trackT + (trackB - trackT - th) * g_top / (rowsTotal - ROWS);
        Fill(dc, { x, ty, x + 4, ty + th }, GOLD);
    }
    std::wstring hint = (g_toast.size() && GetTickCount() < g_toastUntil) ? g_toast
        : L"手柄：摇杆/十字键 选择   LB/RB 切换区域   A 传送   B 关闭        键鼠：方向键/WASD   Q/E 区域   回车/点击 传送   Esc/F 关闭";
    Text(dc, hint, { GX, PH - 52, PW - GX, PH - 16 }, (g_toast.size() && GetTickCount() < g_toastUntil) ? GOLD : DIM, fHint, DT_CENTER | DT_VCENTER);
}
static void Toast(const wchar_t* s) { g_toast = s; g_toastUntil = GetTickCount() + 2500; }
static void Reposition(HWND h) {
    HWND gw = GameWindow(); RECT r; if (gw) GetWindowRect(gw, &r); else { r = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) }; }
    SetWindowPos(h, HWND_TOPMOST, (r.left + r.right) / 2 - PW / 2, (r.top + r.bottom) / 2 - PH / 2, PW, PH, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}
static void DoTeleport() {
    auto& L = g_list[g_tab]; if (g_sel < 0 || g_sel >= (int)L.size()) return;
    Place& p = g_all[L[g_sel]];
    if (p.current) { Toast(L"你已经在这里了"); InvalidateRect(g_menuWnd, nullptr, FALSE); return; }
    FILE* f = nullptr;
    if (_wfopen_s(&f, DATA_DIR L"teleport.req", L"wb") == 0 && f) {
        char lv[128]; WideCharToMultiByte(CP_UTF8, 0, p.tLv.c_str(), -1, lv, 128, nullptr, nullptr);
        fprintf(f, "%s|%.0f|%.0f|%.0f\n", lv, p.tx, p.ty, p.tz); fclose(f);
        Log("teleport request %s %.0f %.0f %.0f", lv, p.tx, p.ty, p.tz);
    }
    g_menuOpen = 0; ShowWindow(g_menuWnd, SW_HIDE);
}
static void Move(int dx, int dy) {
    int n = (int)g_list[g_tab].size(); if (!n) return;
    int s = g_sel + dx + dy * COLS;
    if (dy && (s < 0 || s >= n)) s = dy < 0 ? g_sel % COLS : std::min(n - 1, (n - 1) / COLS * COLS + g_sel % COLS);
    if (dx && (s < 0 || s >= n)) s = dx < 0 ? n - 1 : 0;
    g_sel = s; ClampSel();
}
static void SetTab(int t) { g_tab = (t + 6) % 6; g_sel = 0; g_top = 0; ClampSel(); }
static int HitCell(POINT pt) {
    for (int v = 0; v < ROWS * COLS; v++) { RECT r = CellRect(v); if (PtInRect(&r, pt)) { int i = g_top * COLS + v; return i < (int)g_list[g_tab].size() ? i : -1; } }
    return -1;
}
static int HitTab(POINT pt) { for (int i = 0; i < 6; i++) { RECT r = TabRect(i); if (PtInRect(&r, pt)) return i; } return -1; }

static LRESULT CALLBACK MenuProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_APP + 10: {
        int c = (int)wp;
        if (c == CMD_TOGGLE) c = g_menuOpen ? CMD_CLOSE : CMD_OPEN;
        if (c == CMD_OPEN) {
            if (!g_mapOpen) return 0;
            LoadPlaces(); SetTab(RegionOfCurrent()); g_toast.clear();
            g_menuOpen = 1; Reposition(h); InvalidateRect(h, nullptr, FALSE); Log("teleport panel open");
            return 0;
        }
        if (!g_menuOpen) return 0;
        switch (c) {
        case CMD_CLOSE: g_menuOpen = 0; ShowWindow(h, SW_HIDE); return 0;
        case CMD_UP: Move(0, -1); break; case CMD_DOWN: Move(0, 1); break;
        case CMD_LEFT: Move(-1, 0); break; case CMD_RIGHT: Move(1, 0); break;
        case CMD_PAGEUP: Move(0, -ROWS); break; case CMD_PAGEDN: Move(0, ROWS); break;
        case CMD_TABL: SetTab(g_tab - 1); break; case CMD_TABR: SetTab(g_tab + 1); break;
        case CMD_OK: DoTeleport(); return 0;
        }
        InvalidateRect(h, nullptr, FALSE); return 0;
    }
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_MOUSEMOVE: {
        POINT pt{ (short)LOWORD(lp), (short)HIWORD(lp) }; int i = HitCell(pt), t = HitTab(pt);
        bool ch = false; if (i >= 0 && i != g_sel) { g_sel = i; ch = true; } if (t != g_hoverTab) { g_hoverTab = t; ch = true; }
        if (ch) InvalidateRect(h, nullptr, FALSE); return 0;
    }
    case WM_LBUTTONDOWN: {
        POINT pt{ (short)LOWORD(lp), (short)HIWORD(lp) }; int t = HitTab(pt), i = HitCell(pt);
        if (t >= 0) { SetTab(t); InvalidateRect(h, nullptr, FALSE); }
        else if (i >= 0) { g_sel = i; DoTeleport(); }
        return 0;
    }
    case WM_RBUTTONDOWN: g_menuOpen = 0; ShowWindow(h, SW_HIDE); return 0;
    case WM_MOUSEWHEEL: Move(0, GET_WHEEL_DELTA_WPARAM(wp) > 0 ? -1 : 1); InvalidateRect(h, nullptr, FALSE); return 0;
    case WM_TIMER: if (g_menuOpen) { if (!GameFocused()) { g_menuOpen = 0; ShowWindow(h, SW_HIDE); } else if (g_toast.size()) InvalidateRect(h, nullptr, FALSE); } return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        HDC mem = CreateCompatibleDC(dc); HBITMAP bmp = CreateCompatibleBitmap(dc, PW, PH); HGDIOBJ ob = SelectObject(mem, bmp);
        DrawPanel(mem); BitBlt(dc, 0, 0, PW, PH, mem, 0, 0, SRCCOPY);
        SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem); EndPaint(h, &ps); return 0;
    }
    case WM_ERASEBKGND: return 1;
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ============================================================ live speed adjust + OSD
static HWND g_osdWnd; static DWORD g_osdUntil; static HFONT fOsd, fOsdS;
static const int OW = 560, OH = 108;
static const double SPEED_MIN = 200, SPEED_MAX = 5000;
static void AdjustSpeed(int delta) {
    double s = CFG_SPEED + delta; if (s < SPEED_MIN) s = SPEED_MIN; if (s > SPEED_MAX) s = SPEED_MAX;
    CFG_SPEED = s;
    wchar_t b[32]; swprintf_s(b, L"%d", (int)s);
    WritePrivateProfileStringW(L"mouse", L"speed", b, DATA_DIR L"wsmod.ini");
    if (g_osdWnd) PostMessageW(g_osdWnd, WM_APP + 20, 0, 0);
}
static LRESULT CALLBACK OsdProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_APP + 20: {
        g_osdUntil = GetTickCount() + 1800;
        HWND gw = GameWindow(); RECT r;
        if (gw) GetWindowRect(gw, &r); else r = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
        SetWindowPos(h, HWND_TOPMOST, (r.left + r.right) / 2 - OW / 2, r.top + 90, OW, OH, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        InvalidateRect(h, nullptr, FALSE); return 0;
    }
    case WM_TIMER: if (IsWindowVisible(h) && GetTickCount() > g_osdUntil) ShowWindow(h, SW_HIDE); return 0;
    case WM_NCHITTEST: return HTTRANSPARENT;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        HDC mem = CreateCompatibleDC(dc); HBITMAP bmp = CreateCompatibleBitmap(dc, OW, OH); HGDIOBJ ob = SelectObject(mem, bmp);
        const COLORREF GOLD = RGB(206, 170, 98), INK = RGB(236, 226, 204), DIM = RGB(130, 120, 104);
        Fill(mem, { 0, 0, OW, OH }, RGB(24, 21, 18)); Frame(mem, { 1, 1, OW - 1, OH - 1 }, GOLD, 2);
        SetBkMode(mem, TRANSPARENT);
        wchar_t b[64]; swprintf_s(b, L"右摇杆鼠标速度   %d", (int)CFG_SPEED);
        Text(mem, b, { 22, 10, OW - 22, 46 }, INK, fOsd, DT_LEFT | DT_VCENTER);
        RECT bar{ 22, 54, OW - 22, 64 }; Fill(mem, bar, RGB(60, 52, 40));
        int w = (int)((bar.right - bar.left) * (CFG_SPEED - SPEED_MIN) / (SPEED_MAX - SPEED_MIN));
        Fill(mem, { bar.left, bar.top, bar.left + w, bar.bottom }, GOLD);
        Text(mem, L"手柄 View+十字键 ↑↓ ±50  ←→ ±200     键盘 [ ] ±50   Shift+[ ] ±200",
            { 22, 70, OW - 22, 100 }, DIM, fOsdS, DT_LEFT | DT_VCENTER);
        BitBlt(dc, 0, 0, OW, OH, mem, 0, 0, SRCCOPY);
        SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem); EndPaint(h, &ps); return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ============================================================ battle speed badge (x3 / x4)
// The game only has x1/x2 icons. While Lua runs the battle at x3/x4 it calls wsmod_speed_<n> every tick;
// we draw a badge in the game's style over the game's own speed icon (top-right of the battle screen).
// The icon is anchored to the top-right and scales with the window height: measured at 1280x720 the centre
// is 87 px from the right edge and 85 px from the top, the diamond about 60 px wide.
static volatile LONG g_spdLevel = 0; static volatile DWORD g_spdTime = 0;
static HWND g_spdWnd; static HFONT fSpd; static int g_spdFontPx = 0; static LONG g_spdPainted = -1;
#define SPD_EXPORT(n) extern "C" __declspec(dllexport) int wsmod_speed_##n(void*) { g_spdLevel = n; g_spdTime = GetTickCount(); return 0; }
SPD_EXPORT(0) SPD_EXPORT(1) SPD_EXPORT(2) SPD_EXPORT(3) SPD_EXPORT(4) SPD_EXPORT(5) SPD_EXPORT(6)   // 5 = 速战 badge, 6 = 速战 mask
static LRESULT CALLBACK SpdProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_TIMER: {
        LONG lv = g_spdLevel;
        HWND gw = GameWindow();
        bool show = lv >= 1 && lv != 6 && GetTickCount() - g_spdTime < 500 && gw && !g_menuOpen;
        if (!show) { if (IsWindowVisible(h)) ShowWindow(h, SW_HIDE); return 0; }
        RECT cr; GetClientRect(gw, &cr); POINT a{ cr.left, cr.top }, b{ cr.right, cr.bottom };
        ClientToScreen(gw, &a); ClientToScreen(gw, &b);
        double H = (double)(b.y - a.y); if (H < 100) return 0;
        int size = (int)(H * 0.092);
        int cx = b.x - (int)(H * 87.0 / 720.0), cy = a.y + (int)(H * 85.0 / 720.0);
        int fpx = (int)(size * (lv == 5 ? 0.27 : 0.40));
        if (fpx != g_spdFontPx) { if (fSpd) DeleteObject(fSpd); fSpd = CreateFontW(-fpx, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Microsoft YaHei"); g_spdFontPx = fpx; g_spdPainted = -1; }
        SetWindowPos(h, HWND_TOPMOST, cx - size / 2, cy - size / 2, size, size, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        if (g_spdPainted != lv) { g_spdPainted = lv; InvalidateRect(h, nullptr, FALSE); }
        return 0;
    }
    case WM_NCHITTEST: return HTTRANSPARENT;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT r; GetClientRect(h, &r); int W = r.right, H = r.bottom;
        HDC mem = CreateCompatibleDC(dc); HBITMAP bmp = CreateCompatibleBitmap(dc, W, H); HGDIOBJ ob = SelectObject(mem, bmp);
        Fill(mem, r, RGB(255, 0, 255));                                   // colour key = transparent
        int c = W / 2, m1 = W / 2 - 2, m2 = W / 2 - 6;
        POINT outer[4] = { { c, c - m1 }, { c + m1, c }, { c, c + m1 }, { c - m1, c } };
        POINT inner[4] = { { c, c - m2 }, { c + m2, c }, { c, c + m2 }, { c - m2, c } };
        HBRUSH bf = CreateSolidBrush(RGB(34, 32, 30)); HPEN pe = CreatePen(PS_SOLID, 2, RGB(214, 208, 196));
        HGDIOBJ obr = SelectObject(mem, bf), op = SelectObject(mem, pe);
        Polygon(mem, outer, 4);
        HPEN pi = CreatePen(PS_SOLID, 1, RGB(120, 114, 104)); SelectObject(mem, pi); SelectObject(mem, GetStockObject(NULL_BRUSH));
        Polygon(mem, inner, 4);
        SelectObject(mem, obr); SelectObject(mem, op); DeleteObject(bf); DeleteObject(pe); DeleteObject(pi);
        SetBkMode(mem, TRANSPARENT);
        wchar_t t[8]; if (g_spdLevel == 5) wcscpy_s(t, L"\u901f\u6218"); else swprintf_s(t, L"\u00d7%ld", (long)g_spdLevel);
        Text(mem, t, { 0, 0, W, H }, RGB(240, 236, 228), fSpd, DT_CENTER | DT_VCENTER);
        BitBlt(dc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
        SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem); EndPaint(h, &ps); return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}

// ============================================================ 速战 mask (level 6)
// At x50 the battle camera, cut-ins and the HUD switch every few frames, which flickers. While Lua runs 速战 with
// quick_mask = 1 it calls wsmod_speed_6 every tick; we cover the game's client area with an opaque ink panel
// ("速战中") until the result screen (Lua then calls wsmod_speed_0). Click-through, never activated.
static HWND g_maskWnd; static HFONT fMaskBig, fMaskSmall; static int g_maskFontH = 0; static DWORD g_maskSince = 0;
static RECT g_maskRect{};
static LRESULT CALLBACK MaskProc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
    switch (m) {
    case WM_TIMER: {
        LONG lv = g_spdLevel;
        HWND gw = GameWindow();
        bool show = lv == 6 && GetTickCount() - g_spdTime < 500 && gw && !g_menuOpen;
        if (!show) { if (IsWindowVisible(h)) { ShowWindow(h, SW_HIDE); Log("quick battle mask off"); } g_maskSince = 0; return 0; }
        RECT cr; GetClientRect(gw, &cr); POINT a{ cr.left, cr.top }, b{ cr.right, cr.bottom };
        ClientToScreen(gw, &a); ClientToScreen(gw, &b);
        RECT r{ a.x, a.y, b.x, b.y };
        int H = r.bottom - r.top; if (H < 100) return 0;
        if (H != g_maskFontH) {
            if (fMaskBig) DeleteObject(fMaskBig); if (fMaskSmall) DeleteObject(fMaskSmall);
            fMaskBig = CreateFontW(-(int)(H * 0.070), 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Microsoft YaHei");
            fMaskSmall = CreateFontW(-(int)(H * 0.024), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Microsoft YaHei");
            g_maskFontH = H;
        }
        if (!g_maskSince) { g_maskSince = GetTickCount(); Log("quick battle mask on (%dx%d)", r.right - r.left, H); }
        if (!EqualRect(&r, &g_maskRect) || !IsWindowVisible(h)) {
            g_maskRect = r;
            SetWindowPos(h, HWND_TOPMOST, r.left, r.top, r.right - r.left, H, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        InvalidateRect(h, nullptr, FALSE);      // dots + seconds
        return 0;
    }
    case WM_NCHITTEST: return HTTRANSPARENT;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT r; GetClientRect(h, &r); int Wd = r.right, H = r.bottom;
        HDC mem = CreateCompatibleDC(dc); HBITMAP bmp = CreateCompatibleBitmap(dc, Wd, H); HGDIOBJ ob = SelectObject(mem, bmp);
        const COLORREF INK = RGB(20, 18, 16), GOLD = RGB(206, 170, 98), PAPER = RGB(236, 226, 204), DIM = RGB(140, 128, 108);
        Fill(mem, r, INK);
        int cx = Wd / 2, cy = H / 2, lw = (int)(H * 0.28);
        Fill(mem, { cx - lw, cy - (int)(H * 0.075), cx + lw, cy - (int)(H * 0.075) + 2 }, GOLD);
        Fill(mem, { cx - lw, cy + (int)(H * 0.075), cx + lw, cy + (int)(H * 0.075) + 2 }, GOLD);
        SetBkMode(mem, TRANSPARENT);
        DWORD el = g_maskSince ? (GetTickCount() - g_maskSince) : 0;
        int dots = (int)((el / 400) % 4);
        wchar_t t[32]; swprintf_s(t, L"\u901f \u6218 \u4e2d%s", dots == 0 ? L"" : dots == 1 ? L"\u00b7" : dots == 2 ? L"\u00b7\u00b7" : L"\u00b7\u00b7\u00b7");
        Text(mem, t, { 0, cy - (int)(H * 0.07), Wd, cy + (int)(H * 0.07) }, PAPER, fMaskBig, DT_CENTER | DT_VCENTER);
        wchar_t s[96]; swprintf_s(s, L"%lu \u79d2   \u00b7   \u518d\u6309\u52a0\u901f\u952e\u9000\u51fa\u901f\u6218", el / 1000);
        Text(mem, s, { 0, cy + (int)(H * 0.10), Wd, cy + (int)(H * 0.15) }, DIM, fMaskSmall, DT_CENTER | DT_VCENTER);
        BitBlt(dc, 0, 0, Wd, H, mem, 0, 0, SRCCOPY);
        SelectObject(mem, ob); DeleteObject(bmp); DeleteDC(mem); EndPaint(h, &ps); return 0;
    }
    }
    return DefWindowProcW(h, m, wp, lp);
}
// test only: render the mask into DATA\mask_snap.bmp (1280x720) without showing it, to check the layout
extern "C" __declspec(dllexport) int wsmod_mask_snap(void*) {
    const int Wd = 1280, H = 720;
    HDC sdc = GetDC(nullptr); HDC mem = CreateCompatibleDC(sdc);
    BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(bi.bmiHeader); bi.bmiHeader.biWidth = Wd; bi.bmiHeader.biHeight = -H; bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 24;
    void* bits = nullptr; HBITMAP bmp = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0); HGDIOBJ ob = SelectObject(mem, bmp);
    HFONT big = CreateFontW(-(int)(H * 0.070), 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Microsoft YaHei");
    HFONT sm = CreateFontW(-(int)(H * 0.024), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, ANTIALIASED_QUALITY, 0, L"Microsoft YaHei");
    RECT r{ 0, 0, Wd, H }; Fill(mem, r, RGB(20, 18, 16));
    int cx = Wd / 2, cy = H / 2, lw = (int)(H * 0.28);
    Fill(mem, { cx - lw, cy - (int)(H * 0.075), cx + lw, cy - (int)(H * 0.075) + 2 }, RGB(206, 170, 98));
    Fill(mem, { cx - lw, cy + (int)(H * 0.075), cx + lw, cy + (int)(H * 0.075) + 2 }, RGB(206, 170, 98));
    SetBkMode(mem, TRANSPARENT);
    Text(mem, L"\u901f \u6218 \u4e2d\u00b7\u00b7", { 0, cy - (int)(H * 0.07), Wd, cy + (int)(H * 0.07) }, RGB(236, 226, 204), big, DT_CENTER | DT_VCENTER);
    Text(mem, L"3 \u79d2   \u00b7   \u518d\u6309\u52a0\u901f\u952e\u9000\u51fa\u901f\u6218", { 0, cy + (int)(H * 0.10), Wd, cy + (int)(H * 0.15) }, RGB(140, 128, 108), sm, DT_CENTER | DT_VCENTER);
    GdiFlush();
    FILE* f = nullptr;
    if (_wfopen_s(&f, DATA_DIR L"mask_snap.bmp", L"wb") == 0 && f) {
        int row = ((Wd * 3 + 3) / 4) * 4; DWORD img = row * H;
        BITMAPFILEHEADER fh{}; fh.bfType = 0x4D42; fh.bfOffBits = sizeof(fh) + sizeof(bi.bmiHeader); fh.bfSize = fh.bfOffBits + img;
        BITMAPINFOHEADER ih = bi.bmiHeader; ih.biHeight = H;               // bottom-up for the file
        fwrite(&fh, sizeof(fh), 1, f); fwrite(&ih, sizeof(ih), 1, f);
        for (int y = H - 1; y >= 0; y--) fwrite((BYTE*)bits + y * row, row, 1, f);
        fclose(f);
    }
    SelectObject(mem, ob); DeleteObject(bmp); DeleteObject(big); DeleteObject(sm); DeleteDC(mem); ReleaseDC(nullptr, sdc);
    return 0;
}

// ============================================================ test instance on another virtual desktop
// If DATA\test_desktop.txt contains N (1-based), the game window is moved to virtual desktop N as soon as it
// exists (IVirtualDesktopManager works for windows of the calling process, and this DLL runs in the game).
// For background testing only; normal starts (no file) are unaffected.
static BOOL CALLBACK FindGameWnd(HWND h, LPARAM lp) {
    DWORD pid = 0; GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    wchar_t cls[64]; GetClassNameW(h, cls, 64);
    if (wcscmp(cls, L"UnrealWindow") != 0) return TRUE;
    *(HWND*)lp = h; return FALSE;
}
static DWORD WINAPI DesktopThread(LPVOID) {
    std::wstring s = ReadSmallFile(L"test_desktop.txt");
    int n = s.empty() ? 0 : _wtoi(s.c_str());
    if (n < 1) return 0;
    BYTE ids[16 * 32]; DWORD sz = sizeof(ids);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VirtualDesktops",
        L"VirtualDesktopIDs", RRF_RT_REG_BINARY, nullptr, ids, &sz) != ERROR_SUCCESS || sz < (DWORD)(16 * n)) { Log("test desktop %d: not found", n); return 0; }
    GUID gd; memcpy(&gd, ids + 16 * (n - 1), 16);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IVirtualDesktopManager* vdm = nullptr;
    if (FAILED(CoCreateInstance(CLSID_VirtualDesktopManager, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&vdm))) || !vdm) { Log("test desktop: no IVirtualDesktopManager"); return 0; }
    DWORD t0 = GetTickCount(); int moved = 0;
    while (GetTickCount() - t0 < 60000 && moved < 3) {
        HWND gw = nullptr; EnumWindows(FindGameWnd, (LPARAM)&gw);
        if (gw) {
            GUID cur{}; BOOL on = FALSE;
            if (SUCCEEDED(vdm->GetWindowDesktopId(gw, &cur)) && memcmp(&cur, &gd, sizeof(GUID)) == 0) moved++;
            else { HRESULT hr = vdm->MoveWindowToDesktop(gw, gd); Log("test desktop %d: move game window hr=0x%08lx", n, (unsigned long)hr); (void)on; }
        }
        Sleep(30);
    }
    vdm->Release();
    return 0;
}

// keyboard: F opens on the world map; while the panel is open its keys are swallowed so the game does not react
static HHOOK g_kbHook;
static LRESULT CALLBACK KbProc(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION && GameFocused()) {
        auto* k = (KBDLLHOOKSTRUCT*)lp; bool down = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN; DWORD vk = k->vkCode;
        if (!g_menuOpen && (vk == VK_OEM_4 || vk == VK_OEM_6)) {   // [ slower, ] faster, Shift = big step
            if (down) { int step = (GetAsyncKeyState(VK_SHIFT) & 0x8000) ? 200 : 50; AdjustSpeed(vk == VK_OEM_6 ? step : -step); }
            return 1;
        }
        if (g_menuOpen) {
            int c = 0;
            switch (vk) {
            case VK_UP: case 'W': c = CMD_UP; break; case VK_DOWN: case 'S': c = CMD_DOWN; break;
            case VK_LEFT: case 'A': c = CMD_LEFT; break; case VK_RIGHT: case 'D': c = CMD_RIGHT; break;
            case 'Q': c = CMD_TABL; break; case 'E': case VK_TAB: c = CMD_TABR; break;
            case VK_PRIOR: c = CMD_PAGEUP; break; case VK_NEXT: c = CMD_PAGEDN; break;
            case VK_RETURN: case VK_SPACE: c = CMD_OK; break;
            case VK_ESCAPE: case 'F': c = CMD_CLOSE; break;
            }
            if (c) { if (down) MenuCmd(c); return 1; }
        } else if (g_mapOpen && vk == 'F') { if (down) MenuCmd(CMD_OPEN); return 1; }
    }
    return CallNextHookEx(g_kbHook, code, wp, lp);
}
static DWORD WINAPI MenuThread(LPVOID) {
    fTitle = CreateFontW(30, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    fTab = CreateFontW(22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    fCell = CreateFontW(24, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    fHint = CreateFontW(17, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    WNDCLASSW wc{}; wc.lpfnWndProc = MenuProc; wc.hInstance = g_self; wc.lpszClassName = L"WSModTeleport"; wc.hCursor = LoadCursor(nullptr, IDC_ARROW); RegisterClassW(&wc);
    g_menuWnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
        wc.lpszClassName, L"", WS_POPUP, 0, 0, PW, PH, nullptr, nullptr, g_self, nullptr);
    SetLayeredWindowAttributes(g_menuWnd, 0, 242, LWA_ALPHA);
    SetTimer(g_menuWnd, 1, 250, nullptr);
    fOsd = CreateFontW(26, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    fOsdS = CreateFontW(16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Microsoft YaHei");
    WNDCLASSW wo{}; wo.lpfnWndProc = OsdProc; wo.hInstance = g_self; wo.lpszClassName = L"WSModOsd"; RegisterClassW(&wo);
    g_osdWnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
        wo.lpszClassName, L"", WS_POPUP, 0, 0, OW, OH, nullptr, nullptr, g_self, nullptr);
    SetLayeredWindowAttributes(g_osdWnd, 0, 238, LWA_ALPHA); SetTimer(g_osdWnd, 1, 100, nullptr);
    WNDCLASSW ws{}; ws.lpfnWndProc = SpdProc; ws.hInstance = g_self; ws.lpszClassName = L"WSModSpeed"; RegisterClassW(&ws);
    g_spdWnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
        ws.lpszClassName, L"", WS_POPUP, 0, 0, 60, 60, nullptr, nullptr, g_self, nullptr);
    SetLayeredWindowAttributes(g_spdWnd, RGB(255, 0, 255), 250, LWA_COLORKEY | LWA_ALPHA); SetTimer(g_spdWnd, 1, 40, nullptr);
    WNDCLASSW wk{}; wk.lpfnWndProc = MaskProc; wk.hInstance = g_self; wk.lpszClassName = L"WSModMask"; RegisterClassW(&wk);
    g_maskWnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT,
        wk.lpszClassName, L"", WS_POPUP, 0, 0, 100, 100, nullptr, nullptr, g_self, nullptr);
    SetLayeredWindowAttributes(g_maskWnd, 0, 250, LWA_ALPHA); SetTimer(g_maskWnd, 1, 40, nullptr);
    g_kbHook = SetWindowsHookExW(WH_KEYBOARD_LL, KbProc, g_self, 0);
    Log("teleport panel ready (kb hook %s)", g_kbHook ? "ok" : "failed");
    MSG msg; while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
    return 0;
}

// ============================================================ gamepad filtering
static WORD g_prevBtn; static int g_repDir; static DWORD g_repT;
static void PadMenu(const XINPUT_GAMEPAD& g) {
    WORD b = g.wButtons, pressed = b & ~g_prevBtn; g_prevBtn = b;
    if (!g_menuOpen) { if (g_mapOpen && (pressed & XINPUT_GAMEPAD_Y)) MenuCmd(CMD_OPEN); return; }
    if (pressed & (XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_Y)) { MenuCmd(CMD_CLOSE); return; }
    if (pressed & XINPUT_GAMEPAD_A) { MenuCmd(CMD_OK); return; }
    if (pressed & XINPUT_GAMEPAD_LEFT_SHOULDER) MenuCmd(CMD_TABL);
    if (pressed & XINPUT_GAMEPAD_RIGHT_SHOULDER) MenuCmd(CMD_TABR);
    if (g.bLeftTrigger > 120 && !(g_repDir == 9)) { MenuCmd(CMD_PAGEUP); }
    int dir = 0;
    if ((b & XINPUT_GAMEPAD_DPAD_UP) || g.sThumbLY > 20000) dir = CMD_UP;
    else if ((b & XINPUT_GAMEPAD_DPAD_DOWN) || g.sThumbLY < -20000) dir = CMD_DOWN;
    else if ((b & XINPUT_GAMEPAD_DPAD_LEFT) || g.sThumbLX < -20000) dir = CMD_LEFT;
    else if ((b & XINPUT_GAMEPAD_DPAD_RIGHT) || g.sThumbLX > 20000) dir = CMD_RIGHT;
    DWORD now = GetTickCount();
    if (dir != g_repDir) { g_repDir = dir; g_repT = now + 320; if (dir) MenuCmd(dir); }
    else if (dir && now >= g_repT) { g_repT = now + 110; MenuCmd(dir); }
}
// View(Back) + D-pad adjusts mouse speed. Back is held back from the game while pressed;
// a plain tap (no D-pad used) is replayed to the game on release, so the world map still opens.
static bool g_backHeld, g_backUsed; static DWORD g_backInjectUntil, g_adjT; static int g_adjDir;
static void PadSpeedCombo(XINPUT_GAMEPAD& g) {
    const WORD DP = XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT;
    DWORD now = GetTickCount(); WORD b = g.wButtons;
    if (b & XINPUT_GAMEPAD_BACK) {
        if (!g_backHeld) { g_backHeld = true; g_backUsed = false; g_adjDir = 0; }
        int dir = 0;
        if (b & XINPUT_GAMEPAD_DPAD_UP) dir = 50; else if (b & XINPUT_GAMEPAD_DPAD_DOWN) dir = -50;
        else if (b & XINPUT_GAMEPAD_DPAD_RIGHT) dir = 200; else if (b & XINPUT_GAMEPAD_DPAD_LEFT) dir = -200;
        if (dir != g_adjDir) { g_adjDir = dir; g_adjT = now + 350; if (dir) { AdjustSpeed(dir); g_backUsed = true; } }
        else if (dir && now >= g_adjT) { g_adjT = now + 90; AdjustSpeed(dir); }
        g.wButtons &= ~(XINPUT_GAMEPAD_BACK | DP);
    } else {
        if (g_backHeld) { g_backHeld = false; g_adjDir = 0; if (!g_backUsed) g_backInjectUntil = now + 120; }
        if (now < g_backInjectUntil) g.wButtons |= XINPUT_GAMEPAD_BACK;
    }
}
// Start opens the character screen (keyboard B) instead of the system menu.
static DWORD WINAPI KeyTapThread(LPVOID p) {
    WORD sc = (WORD)(UINT_PTR)p;
    INPUT in{}; in.type = INPUT_KEYBOARD; in.ki.wScan = sc; in.ki.wVk = (WORD)MapVirtualKeyW(sc, MAPVK_VSC_TO_VK);
    SendInput(1, &in, sizeof(in)); Sleep(60);
    in.ki.dwFlags = KEYEVENTF_KEYUP; SendInput(1, &in, sizeof(in));
    return 0;
}
static bool g_prevStart;
// Start: ask Lua to open the character screen's team tab (no keyboard event, so the game's input mode stays).
// Lua answers in start.ack; "0" or no answer in 0.6 s -> tap B as before.
static volatile LONG g_startBusy = 0;
static DWORD WINAPI StartThread(LPVOID) {
    DeleteFileW(DATA_DIR L"start.ack");
    FILE* f = nullptr;
    if (_wfopen_s(&f, DATA_DIR L"start.req", L"wb") == 0 && f) { fputc('1', f); fclose(f); }
    wchar_t ans = 0;
    for (int i = 0; i < 60 && !ans; i++) {
        Sleep(10);
        std::wstring a = ReadSmallFile(L"start.ack");
        if (!a.empty()) ans = a[0];
    }
    DeleteFileW(DATA_DIR L"start.ack"); DeleteFileW(DATA_DIR L"start.req");
    if (ans == L'1') Log("Start -> character screen (team tab, input mode kept)");
    else { KeyTapThread((LPVOID)(UINT_PTR)0x30); Log("Start -> character screen (B%s)", ans ? "" : ", Lua did not answer"); }   // 0x30 = B
    InterlockedExchange(&g_startBusy, 0);
    return 0;
}
static void PadStartRemap(XINPUT_GAMEPAD& g) {
    bool st = (g.wButtons & XINPUT_GAMEPAD_START) != 0;
    if (st && !g_prevStart && InterlockedCompareExchange(&g_startBusy, 1, 0) == 0) {
        HANDLE t = CreateThread(nullptr, 0, StartThread, nullptr, 0, nullptr);
        if (t) CloseHandle(t); else InterlockedExchange(&g_startBusy, 0);
    }
    g_prevStart = st;
    g.wButtons &= ~XINPUT_GAMEPAD_START;
}
// Mouse first: once the right stick has moved the pointer, A is the left mouse button and the game's
// own A logic stays out of the way - until the player uses the d-pad or the left stick, which hands A
// back to the game (dialogue, options, interact, confirm). No timeout, no hover requirement.
// The decision is taken when A goes down and held until A is released, so one press is never both.
static bool g_prevA, g_aClick;
static void PadPointerClick(XINPUT_GAMEPAD& g) {
    const WORD DP = XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT;
    bool nav = (g.wButtons & DP) || abs(g.sThumbLX) > 12000 || abs(g.sThumbLY) > 12000;
    bool stick = sqrt((double)g.sThumbRX * g.sThumbRX + (double)g.sThumbRY * g.sThumbRY) > CFG_DEADZONE;
    if (nav) { if (g_ptrMode) Log("A -> game (d-pad / left stick used)"); g_ptrMode = 0; g_lastNav = GetTickCount(); }
    else if (stick) { if (!g_ptrMode) Log("A -> mouse (right stick used)"); g_ptrMode = 1; }
    bool a = (g.wButtons & XINPUT_GAMEPAD_A) != 0;
    if (a && !g_prevA && PointerMode()) { g_aClick = true; MouseBtn(true); }
    if (!a && g_prevA && g_aClick) { MouseBtn(false); g_aClick = false; }
    g_prevA = a;
    if (g_aClick) g.wButtons &= ~XINPUT_GAMEPAD_A;
}
// one input = one state machine: 0 idle, 1 pressed while allowed (game sees it), 2 pressed while blocked
// (hidden until released, even if the block is lifted meanwhile - otherwise the game would see a late press)
static int g_in[6];
static bool InputStep(int k, bool down, bool blocked) {
    if (!down) { g_in[k] = 0; return false; }
    if (g_in[k] == 0) { g_in[k] = blocked ? 2 : 1; if (blocked) InterlockedIncrement(&g_ev[k]); }
    return g_in[k] == 2;
}
static void PadPrime(XINPUT_GAMEPAD& g) {
    LONG m = NavMask();
    // triggers (hysteresis)
    bool l = g_in[0] ? g.bLeftTrigger > 40 : g.bLeftTrigger > 120;
    bool r = g_in[1] ? g.bRightTrigger > 40 : g.bRightTrigger > 120;
    if (InputStep(0, l, (m & NAV_TRIG) != 0)) g.bLeftTrigger = 0;
    if (InputStep(1, r, (m & NAV_TRIG) != 0)) g.bRightTrigger = 0;
    // directions: d-pad OR left stick (stick counts from 16000, released below 7000)
    struct D { int k; WORD bit; int axis; int sign; LONG flag; } dirs[4] = {
        { 2, XINPUT_GAMEPAD_DPAD_LEFT, 0, -1, NAV_LEFT }, { 3, XINPUT_GAMEPAD_DPAD_RIGHT, 0, 1, NAV_RIGHT },
        { 4, XINPUT_GAMEPAD_DPAD_UP, 1, 1, NAV_UP },     { 5, XINPUT_GAMEPAD_DPAD_DOWN, 1, -1, NAV_DOWN } };
    for (auto& d : dirs) {
        SHORT& ax = d.axis ? g.sThumbLY : g.sThumbLX;
        int v = ax * d.sign;
        bool stick = g_in[d.k] ? v > 7000 : v > 16000;
        bool down = (g.wButtons & d.bit) || stick;
        if (InputStep(d.k, down, (m & d.flag) != 0)) {
            g.wButtons &= ~d.bit;
            if (v > 0) ax = 0;                  // only the component pointing that way
        }
    }
}
static void ReleaseClick() { if (g_aClick) { MouseBtn(false); g_aClick = false; } }
static DWORD Handle(PFN_GetState fn, DWORD idx, XINPUT_STATE* s) {
    if (!fn) return ERROR_DEVICE_NOT_CONNECTED;
    DWORD r = fn(idx, s);
    if (r != ERROR_SUCCESS || !s) return r;
    if (g_primary < 0) { g_primary = (LONG)idx; Log("controller at index %u", idx); }
    if ((LONG)idx != g_primary) return r;
    XINPUT_GAMEPAD& g = s->Gamepad;
    bool focus = GameFocused();
    if (focus && !g_menuOpen) PadPrime(g);
    // the world map cannot be open during a real fight, but battle.flag is also 1 on the overworld (LV_World):
    // map state wins, so Y / the teleport panel work when the map is opened from the overworld
    if (focus && (!g_battle || g_mapOpen || g_menuOpen)) { if (!g_menuOpen) PadSpeedCombo(g); PadMenu(g); }
    if (g_menuOpen) { ReleaseClick(); ZeroMemory(&g, sizeof(g)); return r; }                    // panel owns the pad
    if (g_mapOpen) { ReleaseClick(); g.wButtons &= ~XINPUT_GAMEPAD_Y; return r; }               // map: native except Y
    if (g_battle) {                                                                              // battle: all native...
        ReleaseClick(); g_ptrMode = 0; g_prevA = false;
        if (focus && !g_fight) PadStartRemap(g);                                                  // ...except Start outside a real fight
        else g_prevStart = (g.wButtons & XINPUT_GAMEPAD_START) != 0;
        return r;
    }
    if (focus) { PadStartRemap(g); PadPointerClick(g); } else ReleaseClick();
    g.sThumbRX = 0; g.sThumbRY = 0;                                     // right stick belongs to the mouse; R3 stays native
    return r;
}

// ============================================================ init + exports
static BOOL CALLBACK InitReal(PINIT_ONCE, PVOID, PVOID*) {
    wchar_t p[MAX_PATH]; GetSystemDirectoryW(p, MAX_PATH); wcscat_s(p, L"\\xinput1_3.dll");
    g_real = LoadLibraryW(p);
    if (!g_real) { Log("ERROR cannot load system xinput1_3.dll"); return TRUE; }
    pGetState = (PFN_GetState)GetProcAddress(g_real, "XInputGetState");
    pGetStateEx = (PFN_GetState)GetProcAddress(g_real, (LPCSTR)100);
    pSetState = (PFN_SetState)GetProcAddress(g_real, "XInputSetState");
    pGetCaps = (PFN_GetCaps)GetProcAddress(g_real, "XInputGetCapabilities");
    pEnable = (PFN_Enable)GetProcAddress(g_real, "XInputEnable");
    pGetDS = (PFN_GetDS)GetProcAddress(g_real, "XInputGetDSoundAudioDeviceGuids");
    pGetBat = (PFN_GetBat)GetProcAddress(g_real, "XInputGetBatteryInformation");
    pGetKey = (PFN_GetKey)GetProcAddress(g_real, "XInputGetKeystroke");
    p101 = (PFN_101)GetProcAddress(g_real, (LPCSTR)101);
    p102 = (PFN_1DW)GetProcAddress(g_real, (LPCSTR)102);
    p103 = (PFN_1DW)GetProcAddress(g_real, (LPCSTR)103);
    LoadConfig();
    Log("wsmod loaded (speed %.0f, deadzone %.0f)", CFG_SPEED, CFG_DEADZONE);
    CreateThread(nullptr, 0, CursorThread, nullptr, 0, nullptr);
    CreateThread(nullptr, 0, MenuThread, nullptr, 0, nullptr);
    CreateThread(nullptr, 0, MouseThread, nullptr, 0, nullptr);
    HANDLE audio = CreateThread(nullptr, 0, AudioThread, nullptr, 0, nullptr);
    if (audio) CloseHandle(audio); else Log("audio worker failed to start (%lu)", GetLastError());
    return TRUE;
}
static void Init() { InitOnceExecuteOnce(&g_once, InitReal, nullptr, nullptr); }

extern "C" {
DWORD WINAPI Proxy_XInputGetState(DWORD i, XINPUT_STATE* s) { Init(); return Handle(pGetState, i, s); }
DWORD WINAPI Proxy_GetStateEx(DWORD i, XINPUT_STATE* s) { Init(); return Handle(pGetStateEx ? pGetStateEx : pGetState, i, s); }
DWORD WINAPI Proxy_XInputSetState(DWORD i, XINPUT_VIBRATION* v) { Init(); return pSetState ? pSetState(i, v) : ERROR_DEVICE_NOT_CONNECTED; }
DWORD WINAPI Proxy_XInputGetCapabilities(DWORD i, DWORD f, XINPUT_CAPABILITIES* c) { Init(); return pGetCaps ? pGetCaps(i, f, c) : ERROR_DEVICE_NOT_CONNECTED; }
void  WINAPI Proxy_XInputEnable(BOOL e) { Init(); if (pEnable) pEnable(e); }
DWORD WINAPI Proxy_XInputGetDSoundAudioDeviceGuids(DWORD i, GUID* a, GUID* b) { Init(); return pGetDS ? pGetDS(i, a, b) : ERROR_DEVICE_NOT_CONNECTED; }
DWORD WINAPI Proxy_XInputGetBatteryInformation(DWORD i, BYTE t, XINPUT_BATTERY_INFORMATION* b) { Init(); return pGetBat ? pGetBat(i, t, b) : ERROR_DEVICE_NOT_CONNECTED; }
DWORD WINAPI Proxy_XInputGetKeystroke(DWORD i, DWORD r, PXINPUT_KEYSTROKE k) { Init(); return pGetKey ? pGetKey(i, r, k) : ERROR_EMPTY; }
DWORD WINAPI Proxy_101(DWORD a, DWORD b, void* c) { Init(); return p101 ? p101(a, b, c) : ERROR_DEVICE_NOT_CONNECTED; }
DWORD WINAPI Proxy_102(DWORD a) { Init(); return p102 ? p102(a) : ERROR_DEVICE_NOT_CONNECTED; }
DWORD WINAPI Proxy_103(DWORD a) { Init(); return p103 ? p103(a) : ERROR_DEVICE_NOT_CONNECTED; }
}
BOOL APIENTRY DllMain(HMODULE h, DWORD r, LPVOID) {
    if (r == DLL_PROCESS_ATTACH) {
        g_self = h; DisableThreadLibraryCalls(h); SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0);
        if (GetFileAttributesW(DATA_DIR L"test_desktop.txt") != INVALID_FILE_ATTRIBUTES) { HANDLE t = CreateThread(nullptr, 0, DesktopThread, nullptr, 0, nullptr); if (t) CloseHandle(t); }
    }
    if (r == DLL_PROCESS_DETACH) { if (g_sysHidden) SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0); ClipCursor(nullptr); }
    return TRUE;
}
