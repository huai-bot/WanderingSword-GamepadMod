// One controller sample at a time. Only buffer after an unmodified View tap;
// a Y on the field alone must never open a menu on a later map.
struct MapPress {
    bool back = false, combo = false, y = false, candidate = false, waiting = false;
    DWORD at = 0;
    bool sample(const XINPUT_GAMEPAD& g, bool eligible, bool map, bool menu, DWORD now) {
        const WORD b = g.wButtons;
        bool view = (b & XINPUT_GAMEPAD_BACK) != 0, down = (b & XINPUT_GAMEPAD_Y) != 0, edge = down && !y;
        y = down;
        if (!eligible || menu || (b & (XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_START))) {
            back = view; combo = view; candidate = waiting = false; return false;
        }
        if (view) {
            if (!back) { combo = map; candidate = waiting = false; }
            combo |= (b & (XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT)) != 0;
        } else if (back && !combo && !map) { candidate = true; at = now; }
        back = view;
        if (now - at > 800) candidate = waiting = false;
        if (edge && candidate) waiting = true;
        bool open = map && !view && (edge || waiting);
        if (map) candidate = waiting = false;
        return open;
    }
};
