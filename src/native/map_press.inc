struct MapPress {
    enum Owner { Idle, Mod, Native, Discard } owner = Idle;
    struct Action { int speed = 0; bool nativeTap = false, panel = false; };
    bool wantOpen = false, used = false, tapped = false, yDown = false, candidate = false, waiting = false;
    int adjust = 0;
    DWORD lastTap = 0, repeatAt = 0;
    bool pulse = false, pulseMap = false, havePacket = false, previousView = false;
    DWORD previousRaw = 0, packetOffset = 0;
    Action sample(XINPUT_STATE& state, bool focused, bool fight, bool map, bool menu, DWORD now) {
        constexpr WORD dirs = XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT;
        auto& pad = state.Gamepad;
        const WORD buttons = pad.wButtons;
        bool view = (buttons & XINPUT_GAMEPAD_BACK) != 0, down = (buttons & XINPUT_GAMEPAD_Y) != 0;
        bool yEdge = down && !yDown, eligible = focused && !fight && !menu;
        bool cancel = (buttons & (XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_START)) != 0;
        yDown = down;
        Action result;
        if (pulse && (!eligible || cancel || map != pulseMap || now - lastTap >= 48)) pulse = false;
        if (view && owner == Idle) {
            owner = eligible ? Mod : focused && fight && !menu ? Native : Discard;
            wantOpen = !map; used = false; adjust = 0;
        }
        if (owner == Mod && (!eligible || cancel)) owner = Discard;
        if (owner == Native && (!focused || !fight || menu)) owner = Discard;
        if (view && owner != Native) pad.wButtons &= ~XINPUT_GAMEPAD_BACK;
        if (view && owner == Mod) {
            pad.wButtons &= ~dirs;
            int step = buttons & XINPUT_GAMEPAD_DPAD_UP ? 50 : buttons & XINPUT_GAMEPAD_DPAD_DOWN ? -50 :
                buttons & XINPUT_GAMEPAD_DPAD_RIGHT ? 200 : buttons & XINPUT_GAMEPAD_DPAD_LEFT ? -200 : 0;
            if (step && (step != adjust || (LONG)(now - repeatAt) >= 0)) {
                result.speed = step; used = true; repeatAt = now + (step == adjust ? 90 : 350);
            }
            adjust = step;
        }
        if (!eligible || cancel || view || now - lastTap > 800) candidate = waiting = false;
        if (!view && owner != Idle) {
            if (owner == Mod && !used && (!tapped || now - lastTap >= 280)) {
                tapped = true; lastTap = now;
                if (wantOpen != map) {
                    pulse = true; pulseMap = map; result.nativeTap = true; candidate = wantOpen;
                }
            }
            owner = Idle;
        }
        if (yEdge && candidate) waiting = true;
        result.panel = eligible && map && !view && !cancel && !result.nativeTap && (yEdge || waiting);
        if (map) candidate = waiting = false;
        if (pulse) pad.wButtons |= XINPUT_GAMEPAD_BACK;
        bool visibleView = (pad.wButtons & XINPUT_GAMEPAD_BACK) != 0;
        DWORD raw = state.dwPacketNumber;
        if (havePacket && raw == previousRaw && visibleView != previousView) ++packetOffset;
        state.dwPacketNumber = raw + packetOffset;
        havePacket = true; previousRaw = raw; previousView = visibleView;
        return result;
    }
};
