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
        if ((++n % 25) == 0) {
            std::wstring s = ReadSmallFile(L"map.flag");
            LONG nm = (!s.empty() && s[0] == L'1') ? 1 : 0;
            if (nm != g_mapOpen) { g_mapOpen = nm; Log("world map %s", nm ? "open" : "closed"); if (!nm && g_menuOpen) MenuCmd(CMD_CLOSE); }
            std::wstring bs = ReadSmallFile(L"battle.flag");
            LONG nb = (!bs.empty() && bs[0] == L'1') ? 1 : 0;
            if (nb != g_battle) { g_battle = nb; Log("battle %s: right stick %s", nb ? "start" : "end", nb ? "native" : "mouse"); }
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
static void PadStartRemap(XINPUT_GAMEPAD& g) {
    bool st = (g.wButtons & XINPUT_GAMEPAD_START) != 0;
    if (st && !g_prevStart) {
        HANDLE t = CreateThread(nullptr, 0, KeyTapThread, (LPVOID)(UINT_PTR)0x30, 0, nullptr);   // 0x30 = B
        if (t) CloseHandle(t);
        Log("Start -> character screen (B)");
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
static void ReleaseClick() { if (g_aClick) { MouseBtn(false); g_aClick = false; } }
static DWORD Handle(PFN_GetState fn, DWORD idx, XINPUT_STATE* s) {
    if (!fn) return ERROR_DEVICE_NOT_CONNECTED;
    DWORD r = fn(idx, s);
    if (r != ERROR_SUCCESS || !s) return r;
    if (g_primary < 0) { g_primary = (LONG)idx; Log("controller at index %u", idx); }
    if ((LONG)idx != g_primary) return r;
    XINPUT_GAMEPAD& g = s->Gamepad;
    bool focus = GameFocused();
    if (focus && !g_battle) { if (!g_menuOpen) PadSpeedCombo(g); PadMenu(g); }
    if (g_menuOpen) { ReleaseClick(); ZeroMemory(&g, sizeof(g)); return r; }                    // panel owns the pad
    if (g_battle) { ReleaseClick(); g_ptrMode = 0; g_prevA = false; g_prevStart = (g.wButtons & XINPUT_GAMEPAD_START) != 0; return r; } // battle: all native
    if (g_mapOpen) { ReleaseClick(); g.wButtons &= ~XINPUT_GAMEPAD_Y; return r; }               // map: native except Y
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
    if (r == DLL_PROCESS_ATTACH) { g_self = h; DisableThreadLibraryCalls(h); SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0); }
    if (r == DLL_PROCESS_DETACH) { if (g_sysHidden) SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0); ClipCursor(nullptr); }
    return TRUE;
}
