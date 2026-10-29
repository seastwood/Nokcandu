// Nokcandu presentation probe: a fullscreen Windows program with click targets and readouts.
// probe.exe [WxH]   - optionally asks for a display mode change first (ChangeDisplaySettings).
// Keys: Esc quits, C toggles ClipCursor, H toggles FPS-style hidden cursor with re-centering, M cycles modes.
#include <windows.h>
#include <stdio.h>

static FILE *logf;
static int W, H, lastX = -1, lastY = -1; static char lastHit[32] = "-";
static long rawX, rawY, rawN; static BOOL clip, fps; static char modeMsg[96] = "no mode change";
static void lg(const char *fmt, ...) { va_list a; va_start(a, fmt); vfprintf(logf, fmt, a); va_end(a); fputc('\n', logf); fflush(logf); }

static const char *hit(int x, int y) {
    int t = 80;
    if (x < t && y < t) return "top-left";
    if (x >= W - t && y < t) return "top-right";
    if (x < t && y >= H - t) return "bottom-left";
    if (x >= W - t && y >= H - t) return "bottom-right";
    if (abs(x - W / 2) < t / 2 && abs(y - H / 2) < t / 2) return "center";
    return "none";
}

static void paint(HWND h) {
    PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps); RECT r; GetClientRect(h, &r);
    HBRUSH bg = CreateSolidBrush(RGB(20, 24, 32)); FillRect(dc, &r, bg); DeleteObject(bg);
    HPEN grid = CreatePen(PS_SOLID, 1, RGB(60, 70, 90)); SelectObject(dc, grid);
    for (int x = 0; x < r.right; x += 100) { MoveToEx(dc, x, 0, NULL); LineTo(dc, x, r.bottom); }
    for (int y = 0; y < r.bottom; y += 100) { MoveToEx(dc, 0, y, NULL); LineTo(dc, r.right, y); }
    DeleteObject(grid);
    HBRUSH red = CreateSolidBrush(RGB(220, 60, 60)), grn = CreateSolidBrush(RGB(60, 200, 90)), yel = CreateSolidBrush(RGB(230, 200, 40));
    int t = 80; RECT c[4] = {{0,0,t,t},{r.right-t,0,r.right,t},{0,r.bottom-t,t,r.bottom},{r.right-t,r.bottom-t,r.right,r.bottom}};
    for (int i = 0; i < 4; i++) FillRect(dc, &c[i], i % 2 ? grn : red);
    RECT ce = {W/2 - t/2, H/2 - t/2, W/2 + t/2, H/2 + t/2}; FillRect(dc, &ce, yel);
    DeleteObject(red); DeleteObject(grn); DeleteObject(yel);
    HPEN border = CreatePen(PS_SOLID, 3, RGB(255, 255, 255)); SelectObject(dc, border); SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, 1, 1, r.right - 1, r.bottom - 1); DeleteObject(border);
    POINT p; GetCursorPos(&p);
    char s[512]; SetBkMode(dc, TRANSPARENT); SetTextColor(dc, RGB(240, 240, 240));
    snprintf(s, sizeof s, "Screen %dx%d  client %ldx%ld  %s", GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), r.right, r.bottom, modeMsg);
    TextOutA(dc, 100, 100, s, strlen(s));
    snprintf(s, sizeof s, "Last click %d,%d -> %s   cursor %ld,%ld", lastX, lastY, lastHit, p.x, p.y);
    TextOutA(dc, 100, 124, s, strlen(s));
    snprintf(s, sizeof s, "Raw mouse total %ld,%ld (%ld reports)  clip %s  fps-cursor %s   [Esc quit, C clip, H fps, M mode]", rawX, rawY, rawN, clip ? "on" : "off", fps ? "on" : "off");
    TextOutA(dc, 100, 148, s, strlen(s));
    EndPaint(h, &ps);
}

static void clipTo(HWND h, BOOL on) {
    if (on) { RECT r; GetClientRect(h, &r); MapWindowPoints(h, NULL, (POINT *)&r, 2); ClipCursor(&r); lg("clip %ld,%ld-%ld,%ld", r.left, r.top, r.right, r.bottom); }
    else ClipCursor(NULL);
}

static void setMode(int w, int h) {
    DEVMODEA dm = { .dmSize = sizeof dm, .dmPelsWidth = w, .dmPelsHeight = h, .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT };
    LONG r = ChangeDisplaySettingsA(&dm, CDS_FULLSCREEN);
    snprintf(modeMsg, sizeof modeMsg, "mode %dx%d -> %ld", w, h, r);
    lg("%s; screen now %dx%d", modeMsg, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
}

static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_PAINT: paint(h); return 0;
    case WM_LBUTTONDOWN: case WM_RBUTTONDOWN:
        lastX = (short)LOWORD(l); lastY = (short)HIWORD(l); snprintf(lastHit, sizeof lastHit, "%s", hit(lastX, lastY));
        lg("click %s %d,%d %s", m == WM_LBUTTONDOWN ? "L" : "R", lastX, lastY, lastHit); InvalidateRect(h, NULL, FALSE); return 0;
    case WM_MOUSEMOVE:
        if (fps) { POINT c = { W / 2, H / 2 }; ClientToScreen(h, &c); POINT p; GetCursorPos(&p); if (p.x != c.x || p.y != c.y) SetCursorPos(c.x, c.y); }
        InvalidateRect(h, NULL, FALSE); return 0;
    case WM_INPUT: {
        RAWINPUT ri; UINT sz = sizeof ri;
        if (GetRawInputData((HRAWINPUT)l, RID_INPUT, &ri, &sz, sizeof(RAWINPUTHEADER)) != (UINT)-1 && ri.header.dwType == RIM_TYPEMOUSE) {
            rawX += ri.data.mouse.lLastX; rawY += ri.data.mouse.lLastY; rawN++;
            if (rawN % 50 == 0) lg("raw %ld,%ld n=%ld", rawX, rawY, rawN);
        }
        return DefWindowProcA(h, m, w, l);
    }
    case WM_SIZE: lg("WM_SIZE %dx%d", LOWORD(l), HIWORD(l)); InvalidateRect(h, NULL, FALSE); return 0;
    case WM_MOVE: lg("WM_MOVE %d,%d", (short)LOWORD(l), (short)HIWORD(l)); return 0;
    case WM_DISPLAYCHANGE: lg("WM_DISPLAYCHANGE %dx%d", LOWORD(l), HIWORD(l)); return 0;
    case WM_ACTIVATEAPP: lg("WM_ACTIVATEAPP %d", (int)w); if (clip) clipTo(h, (BOOL)w); return 0;
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) { DestroyWindow(h); return 0; }
        if (w == 'C') { clip = !clip; clipTo(h, clip); }
        if (w == 'H') { fps = !fps; ShowCursor(!fps); lg("fps %d", fps); }
        if (w == 'M') { static int i; int ms[][2] = {{1280,720},{1024,768},{1920,1080}}; setMode(ms[i][0], ms[i][1]); i = (i + 1) % 3;
            W = GetSystemMetrics(SM_CXSCREEN); H = GetSystemMetrics(SM_CYSCREEN); SetWindowPos(h, HWND_TOP, 0, 0, W, H, SWP_SHOWWINDOW); }
        InvalidateRect(h, NULL, FALSE); return 0;
    case WM_DESTROY: ClipCursor(NULL); ChangeDisplaySettingsA(NULL, 0); PostQuitMessage(0); return 0;
    }
    return DefWindowProcA(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show) {
    char path[MAX_PATH]; GetModuleFileNameA(NULL, path, MAX_PATH); char *s = strrchr(path, '\\'); if (s) strcpy(s + 1, "probe.log");
    logf = fopen(path, "a"); lg("--- start, cmdline '%s'", cmd);
    int mw, mh; if (sscanf(cmd, "%dx%d", &mw, &mh) == 2) setMode(mw, mh);
    W = GetSystemMetrics(SM_CXSCREEN); H = GetSystemMetrics(SM_CYSCREEN); lg("screen %dx%d", W, H);
    WNDCLASSA wc = { .lpfnWndProc = proc, .hInstance = inst, .lpszClassName = "NokProbe", .hCursor = LoadCursor(NULL, IDC_CROSS) };
    RegisterClassA(&wc);
    HWND h = CreateWindowExA(WS_EX_TOPMOST, "NokProbe", "Nokcandu Probe", WS_POPUP | WS_VISIBLE, 0, 0, W, H, NULL, NULL, inst, NULL);
    RAWINPUTDEVICE rid = { 1, 2, 0, h }; RegisterRawInputDevices(&rid, 1, sizeof rid);
    RECT wr; GetWindowRect(h, &wr); lg("window %ld,%ld-%ld,%ld", wr.left, wr.top, wr.right, wr.bottom);
    MSG msg; while (GetMessageA(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageA(&msg); }
    lg("--- exit"); fclose(logf); return 0;
}
