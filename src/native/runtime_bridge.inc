// Process-private arbitration: duplicate Lua/DLL loads must share one Y latch and one Lua owner.
// No game object access. Mapping/handles last for this process, never opened from another process.
struct RuntimeChannel {
    PVOID volatile ownerLua;
    volatile LONG yKey, ySerial, inputWanted, inputTick;
};
static RuntimeChannel* g_runtime = nullptr;
static HANDLE g_runtimeMap = nullptr;
static INIT_ONCE g_runtimeOnce = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK InitRuntimeChannel(PINIT_ONCE, PVOID, PVOID*) {
    wchar_t name[96]; swprintf_s(name, L"Local\\WanderingSwordGamepadRuntime_v425_%lu", GetCurrentProcessId());
    g_runtimeMap = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(RuntimeChannel), name);
    if (g_runtimeMap) g_runtime = (RuntimeChannel*)MapViewOfFile(g_runtimeMap, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(RuntimeChannel));
    if (!g_runtime) Log("runtime arbitration unavailable (%lu); native Y remains available", GetLastError());
    return TRUE;
}
static RuntimeChannel* Runtime() {
    InitOnceExecuteOnce(&g_runtimeOnce, InitRuntimeChannel, nullptr, nullptr); return g_runtime;
}
static bool RuntimeOwnsLua(void* lua) {
    auto* r = Runtime(); return r && InterlockedCompareExchangePointer(&r->ownerLua, nullptr, nullptr) == lua;
}
struct RuntimeCaller { void* lua; std::wstring token; };
static std::vector<RuntimeCaller> g_runtimeCallers; // claim/poll run synchronously on the game thread
static void RuntimeReceipt(void* lua) {
    const RuntimeCaller* caller = nullptr;
    for (const auto& c : g_runtimeCallers) if (c.lua == lua) { caller = &c; break; }
    if (!caller) return;
    auto* r = Runtime();
    std::wstring path = DATA_DIR L"runtime_" + caller->token + L".txt";
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"wb") == 0 && f) {
        fprintf(f, "%d|%lu|%llu", RuntimeOwnsLua(lua) ? 1 : 0,
            r ? (unsigned long)(DWORD)InterlockedCompareExchange(&r->ySerial, 0, 0) : 0,
            (unsigned long long)GetTickCount64());
        fclose(f);
    }
}
extern "C" __declspec(dllexport) int wsmod_runtime_claim(void* lua) {
    char token[65] = {}; FILE* f = nullptr;
    if (_wfopen_s(&f, DATA_DIR L"runtime_claim.req", L"rb") != 0 || !f) return 0;
    size_t n = fread(token, 1, 64, f); fclose(f);
    if (!n) return 0;
    for (size_t i = 0; i < n; ++i) if (!((token[i] >= '0' && token[i] <= '9') ||
        (token[i] >= 'a' && token[i] <= 'f') || token[i] == '_')) return 0;
    std::wstring t(token, token + n);
    bool found = false;
    for (auto& c : g_runtimeCallers) if (c.lua == lua) { c.token = t; found = true; break; }
    if (!found) g_runtimeCallers.push_back({lua, t});
    if (auto* r = Runtime()) {
        PVOID previous = InterlockedExchangePointer(&r->ownerLua, lua);
        Log("runtime owner claimed (pid=%lu lua=%p previous=%p)", GetCurrentProcessId(), lua, previous);
    }
    RuntimeReceipt(lua); return 0;
}
extern "C" __declspec(dllexport) int wsmod_runtime_poll(void* lua) { RuntimeReceipt(lua); return 0; }
static void RuntimeInput(void* lua, bool on) {
    if (!RuntimeOwnsLua(lua)) return;
    auto* r = Runtime();
    if (on) InterlockedExchange(&r->inputTick, (LONG)GetTickCount());
    InterlockedExchange(&r->inputWanted, on ? 1 : 0);
}
static void RuntimeBattleY(XINPUT_GAMEPAD& g, bool active) {
    auto* r = Runtime(); if (!r) return;
    bool down = (g.wButtons & XINPUT_GAMEPAD_Y) != 0;
    if (!down) { InterlockedExchange(&r->yKey, 0); return; }
    LONG enabled = InterlockedCompareExchange(&r->inputWanted, 0, 0);
    DWORD heartbeat = (DWORD)InterlockedCompareExchange(&r->inputTick, 0, 0);
    bool ready = active && enabled && GetTickCount() - heartbeat < 500;
    if (!ready) InterlockedCompareExchange(&r->yKey, 2, 1);
    bool single = !(g.wButtons & (XINPUT_GAMEPAD_LEFT_SHOULDER | XINPUT_GAMEPAD_RIGHT_SHOULDER)) &&
        g.bLeftTrigger <= 40 && g.bRightTrigger <= 40;
    LONG choice = ready && single ? 1 : 2;
    if (InterlockedCompareExchange(&r->yKey, choice, 0) == 0 && choice == 1) {
        InterlockedIncrement(&r->ySerial); Log("battle Y -> speed cycle (serial=%lu)", (unsigned long)(DWORD)r->ySerial);
    }
    if (InterlockedCompareExchange(&r->yKey, 0, 0) == 1) g.wButtons &= ~XINPUT_GAMEPAD_Y;
}
