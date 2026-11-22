// wspad.dll - test-only gamepad input injector for Wandering Sword (no game restart needed).
// Loaded at runtime from Lua (package.loadlib + wspad_install). The game reads the pad through our
// xinput1_3 proxy, which keeps pointers to the SYSTEM XInputGetState / #100 in its data section.
// install swaps exactly those pointers for HookGetState(Ex): system XInput -> + script buttons -> proxy
// logic -> game. No code bytes are patched; uninstall puts the pointers back.
// (v1 patched the game's import table instead; the game does not import XInput that way -> 0 slots.)
// Script: DATA\pad.req, one step per line:  "<BTN[+BTN...]> <ms>"  (hold, then release)  or  "- <ms>" (wait)
//   buttons: A B X Y LB RB LT RT UP DOWN LEFT RIGHT START BACK LS RS
// Finishes by writing DATA\pad_out.txt ("done ..." or "ABORT ..."). Aborts as soon as DATA\pad_abort.flag
// exists (the driver creates it when a real fight starts or the target screen closes).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>
#include <delayimp.h>
#include <psapi.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define DATA L"D:\\TOOLS\\AWSdata\\WanderingSword\\"
typedef DWORD (WINAPI *PFN_GetState)(DWORD, XINPUT_STATE*);

static void Log(const char* fmt, ...) {
    FILE* f = nullptr; if (_wfopen_s(&f, DATA L"wspad.log", L"a") != 0 || !f) return;
    SYSTEMTIME t; GetLocalTime(&t); fprintf(f, "[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list a; va_start(a, fmt); vfprintf(f, fmt, a); va_end(a); fputc('\n', f); fclose(f);
}

struct Patch { void** slot; void* old; };
static std::vector<Patch> g_patches;
static PFN_GetState g_orig = nullptr, g_origEx = nullptr;
static volatile LONG g_btn = 0, g_lt = 0, g_rt = 0, g_active = 0, g_pk = 0, g_calls = 0, g_running = 0;
// while DATA\pad_connect.flag exists, pad 0 reports "connected" even if the real controller is asleep
// (UE stops polling a disconnected pad until it gets WM_DEVICECHANGE; the driver posts one after creating the flag)
static volatile LONG g_hold = 0;
static HANDLE g_thread = nullptr;

static void Apply(DWORD i, XINPUT_STATE* s, DWORD& r) {
    InterlockedIncrement(&g_calls);
    if (!(g_active || g_hold) || i != 0 || !s) return;
    if (r != ERROR_SUCCESS) { ZeroMemory(s, sizeof(XINPUT_STATE)); r = ERROR_SUCCESS; }
    s->Gamepad.wButtons |= (WORD)g_btn;
    if (g_lt) s->Gamepad.bLeftTrigger = 255;
    if (g_rt) s->Gamepad.bRightTrigger = 255;
    s->dwPacketNumber += (DWORD)g_pk;
}
static DWORD WINAPI HookGetState(DWORD i, XINPUT_STATE* s) {
    DWORD r = g_orig ? g_orig(i, s) : ERROR_DEVICE_NOT_CONNECTED; Apply(i, s, r); return r;
}
static DWORD WINAPI HookGetStateEx(DWORD i, XINPUT_STATE* s) {
    PFN_GetState f = g_origEx ? g_origEx : g_orig;
    DWORD r = f ? f(i, s) : ERROR_DEVICE_NOT_CONNECTED; Apply(i, s, r); return r;
}

// 1 = XInputGetState, 2 = ordinal 100 (GetStateEx), 0 = other
static int Kind(BYTE* base, ULONGLONG thunk) {
    if (IMAGE_SNAP_BY_ORDINAL64(thunk)) return IMAGE_ORDINAL64(thunk) == 100 ? 2 : 0;
    auto ibn = (IMAGE_IMPORT_BY_NAME*)(base + (DWORD)thunk);
    return strcmp((const char*)ibn->Name, "XInputGetState") == 0 ? 1 : 0;
}
static void PatchSlot(void** slot, void* hook) {
    DWORD old;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old)) return;
    g_patches.push_back({ slot, *slot });
    InterlockedExchangePointer(slot, hook);
    VirtualProtect(slot, sizeof(void*), old, &old);
}
static void ResolveOrig(const char* dll) {
    if (g_orig) return;
    HMODULE h = GetModuleHandleA(dll); if (!h) h = LoadLibraryA(dll);
    if (!h) return;
    g_orig = (PFN_GetState)GetProcAddress(h, "XInputGetState");
    g_origEx = (PFN_GetState)GetProcAddress(h, (LPCSTR)100);
    char p[MAX_PATH] = ""; GetModuleFileNameA(h, p, MAX_PATH);
    Log("chain target %s (GetState %p, ord100 %p)", p, g_orig, g_origEx);
}
static int PatchModule(HMODULE m) {
    BYTE* base = (BYTE*)m;
    auto nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
    int n = 0;
    auto& imp = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (imp.VirtualAddress) {
        for (auto d = (IMAGE_IMPORT_DESCRIPTOR*)(base + imp.VirtualAddress); d->Name; d++) {
            const char* dn = (const char*)(base + d->Name);
            if (_strnicmp(dn, "xinput", 6) != 0) continue;
            ResolveOrig(dn);
            auto oft = (IMAGE_THUNK_DATA*)(base + (d->OriginalFirstThunk ? d->OriginalFirstThunk : d->FirstThunk));
            auto ft = (IMAGE_THUNK_DATA*)(base + d->FirstThunk);
            for (; oft->u1.AddressOfData; oft++, ft++) {
                int k = Kind(base, oft->u1.Ordinal);
                if (k) { PatchSlot((void**)&ft->u1.Function, k == 1 ? (void*)HookGetState : (void*)HookGetStateEx); n++; Log("patched import %s %s", dn, k == 1 ? "XInputGetState" : "#100"); }
            }
        }
    }
    auto& dly = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (dly.VirtualAddress) {
        for (auto d = (PCImgDelayDescr)(base + dly.VirtualAddress); d->rvaDLLName; d++) {
            const char* dn = (const char*)(base + d->rvaDLLName);
            if (_strnicmp(dn, "xinput", 6) != 0) continue;
            ResolveOrig(dn);
            auto nameT = (IMAGE_THUNK_DATA*)(base + d->rvaINT);
            auto iat = (IMAGE_THUNK_DATA*)(base + d->rvaIAT);
            for (; nameT->u1.AddressOfData; nameT++, iat++) {
                int k = Kind(base, nameT->u1.Ordinal);
                if (k) { PatchSlot((void**)&iat->u1.Function, k == 1 ? (void*)HookGetState : (void*)HookGetStateEx); n++; Log("patched delay-import %s %s", dn, k == 1 ? "XInputGetState" : "#100"); }
            }
        }
    }
    return n;
}

static WORD BtnBit(const std::string& t, bool& lt, bool& rt) {
    if (t == "A") return XINPUT_GAMEPAD_A; if (t == "B") return XINPUT_GAMEPAD_B;
    if (t == "X") return XINPUT_GAMEPAD_X; if (t == "Y") return XINPUT_GAMEPAD_Y;
    if (t == "LB") return XINPUT_GAMEPAD_LEFT_SHOULDER; if (t == "RB") return XINPUT_GAMEPAD_RIGHT_SHOULDER;
    if (t == "UP") return XINPUT_GAMEPAD_DPAD_UP; if (t == "DOWN") return XINPUT_GAMEPAD_DPAD_DOWN;
    if (t == "LEFT") return XINPUT_GAMEPAD_DPAD_LEFT; if (t == "RIGHT") return XINPUT_GAMEPAD_DPAD_RIGHT;
    if (t == "START") return XINPUT_GAMEPAD_START; if (t == "BACK") return XINPUT_GAMEPAD_BACK;
    if (t == "LS") return XINPUT_GAMEPAD_LEFT_THUMB; if (t == "RS") return XINPUT_GAMEPAD_RIGHT_THUMB;
    if (t == "LT") { lt = true; return 0; } if (t == "RT") { rt = true; return 0; }
    return 0;
}
static bool InBattle() {
    return GetFileAttributesW(DATA L"pad_abort.flag") != INVALID_FILE_ATTRIBUTES;
}
static void WriteOut(const char* s) {
    FILE* f = nullptr; if (_wfopen_s(&f, DATA L"pad_out.txt", L"wb") != 0 || !f) return;
    fputs(s, f); fclose(f);
}
static void RunScript(const std::string& text) {
    LONG c0 = g_calls; int steps = 0; char msg[160];
    InterlockedExchange(&g_active, 1);
    size_t p = 0;
    while (p < text.size()) {
        size_t e = text.find('\n', p); if (e == std::string::npos) e = text.size();
        std::string line = text.substr(p, e - p); p = e + 1;
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        size_t sp = line.find(' ');
        std::string keys = line.substr(0, sp); int ms = sp == std::string::npos ? 120 : atoi(line.c_str() + sp + 1);
        if (ms < 10) ms = 10; if (ms > 5000) ms = 5000;
        if (InBattle()) { InterlockedExchange(&g_btn, 0); g_lt = g_rt = 0; InterlockedExchange(&g_active, 0); sprintf_s(msg, "ABORT flag at step %d", steps); WriteOut(msg); Log("%s", msg); return; }
        bool lt = false, rt = false; WORD b = 0;
        if (keys != "-") { size_t q = 0; while (q <= keys.size()) { size_t z = keys.find('+', q); if (z == std::string::npos) z = keys.size(); b |= BtnBit(keys.substr(q, z - q), lt, rt); q = z + 1; } }
        InterlockedExchange(&g_btn, b); InterlockedExchange(&g_lt, lt); InterlockedExchange(&g_rt, rt); InterlockedIncrement(&g_pk);
        Sleep(ms);
        InterlockedExchange(&g_btn, 0); InterlockedExchange(&g_lt, 0); InterlockedExchange(&g_rt, 0); InterlockedIncrement(&g_pk);
        if (keys != "-") Sleep(40);
        steps++;
    }
    InterlockedExchange(&g_active, 0);
    sprintf_s(msg, "done %d steps, %ld polls", steps, g_calls - c0);
    WriteOut(msg); Log("%s", msg);
}
static DWORD WINAPI Worker(LPVOID) {
    while (g_running) {
        Sleep(30);
        InterlockedExchange(&g_hold, GetFileAttributesW(DATA L"pad_connect.flag") != INVALID_FILE_ATTRIBUTES ? 1 : 0);
        FILE* f = nullptr;
        if (_wfopen_s(&f, DATA L"pad.req", L"rb") != 0 || !f) continue;
        std::string s; char buf[4096]; size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
        fclose(f); DeleteFileW(DATA L"pad.req");
        RunScript(s);
    }
    return 0;
}

static int PatchProxyPointers() {
    wchar_t sys[MAX_PATH]; GetSystemDirectoryW(sys, MAX_PATH); wcscat_s(sys, L"\\xinput1_3.dll");
    HMODULE mods[512]; DWORD need = 0; HMODULE hsys = nullptr, hproxy = nullptr;
    if (!K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &need)) { Log("EnumProcessModules failed"); return 0; }
    for (DWORD i = 0; i < need / sizeof(HMODULE) && i < 512; i++) {
        wchar_t p[MAX_PATH] = L""; GetModuleFileNameW(mods[i], p, MAX_PATH);
        const wchar_t* bn = wcsrchr(p, L'\\'); bn = bn ? bn + 1 : p;
        if (_wcsicmp(bn, L"xinput1_3.dll") != 0) continue;
        if (_wcsicmp(p, sys) == 0) hsys = mods[i]; else hproxy = mods[i];
        Log("module %ls", p);
    }
    if (!hsys || !hproxy) { Log("system or proxy xinput1_3.dll not found (sys %p proxy %p)", hsys, hproxy); return 0; }
    void* fGet = (void*)GetProcAddress(hsys, "XInputGetState");
    void* fEx = (void*)GetProcAddress(hsys, (LPCSTR)100);
    g_orig = (PFN_GetState)fGet; g_origEx = (PFN_GetState)fEx;
    Log("system GetState %p, #100 %p", fGet, fEx);
    BYTE* base = (BYTE*)hproxy;
    auto nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    int n = 0;
    for (WORD s = 0; s < nt->FileHeader.NumberOfSections; s++, sec++) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_WRITE)) continue;
        void** p = (void**)(base + sec->VirtualAddress);
        size_t cnt = sec->Misc.VirtualSize / sizeof(void*);
        for (size_t k = 0; k < cnt; k++) {
            if (fGet && p[k] == fGet) { PatchSlot(&p[k], (void*)HookGetState); n++; Log("swapped GetState pointer at %p (%.8s)", &p[k], sec->Name); }
            else if (fEx && p[k] == fEx) { PatchSlot(&p[k], (void*)HookGetStateEx); n++; Log("swapped #100 pointer at %p (%.8s)", &p[k], sec->Name); }
        }
    }
    return n;
}

extern "C" __declspec(dllexport) int wspad_install(void* /*lua_State*/) {
    if (!g_patches.empty()) { Log("install: already installed (%zu slots)", g_patches.size()); return 0; }
    int n = PatchProxyPointers();
    Log("install: %d pointers swapped", n);
    if (n == 0) return 0;
    if (!g_thread) { InterlockedExchange(&g_running, 1); g_thread = CreateThread(nullptr, 0, Worker, nullptr, 0, nullptr); }
    return 0;
}
extern "C" __declspec(dllexport) int wspad_uninstall(void* /*lua_State*/) {
    InterlockedExchange(&g_running, 0); InterlockedExchange(&g_active, 0); InterlockedExchange(&g_hold, 0);
    if (g_thread) { WaitForSingleObject(g_thread, 2000); CloseHandle(g_thread); g_thread = nullptr; }
    for (auto& p : g_patches) { DWORD old; if (VirtualProtect(p.slot, sizeof(void*), PAGE_READWRITE, &old)) { InterlockedExchangePointer(p.slot, p.old); VirtualProtect(p.slot, sizeof(void*), old, &old); } }
    Log("uninstall: restored %zu slots", g_patches.size());
    g_patches.clear();
    return 0;
}
BOOL APIENTRY DllMain(HMODULE h, DWORD r, LPVOID) { if (r == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(h); return TRUE; }
