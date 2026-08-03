package ui

// Custom frame nativo (Windows): mantém os estilos nativos da janela
// (WS_THICKFRAME etc.) para ganhar Aero Snap, sombra e animações de
// maximizar/minimizar — mas esconde a barra de título do SO via
// WM_NCCALCSIZE e define nossas próprias zonas de arrastar/redimensionar
// via WM_NCHITTEST. É a mesma técnica usada por Chrome, Edge e VS Code.

import sdl2 "vendor:sdl2"
import win  "core:sys/windows"

g_hwnd:          win.HWND
g_orig_wndproc:  win.WNDPROC

// Configura o frame customizado a partir da janela SDL.
setup_custom_frame :: proc(window: ^sdl2.Window) {
    info: sdl2.SysWMinfo
    sdl2.GetVersion(&info.version)
    if !sdl2.GetWindowWMInfo(window, &info) do return

    g_hwnd = win.HWND(info.info.win.window)

    // subclassa a janela: nosso wndproc intercepta, o resto vai pro SDL
    old := win.SetWindowLongPtrW(g_hwnd, win.GWLP_WNDPROC, transmute(win.LONG_PTR)(custom_wndproc))
    g_orig_wndproc = transmute(win.WNDPROC)(old)

    // força recálculo do frame (dispara WM_NCCALCSIZE)
    win.SetWindowPos(g_hwnd, nil, 0, 0, 0, 0,
        win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
}

frame_is_maximized :: proc() -> bool {
    if g_hwnd == nil do return false
    return win.IsZoomed(g_hwnd) != win.FALSE
}

// Quando maximizada, o Windows posiciona a janela um pouco fora da tela;
// encolhemos o retângulo do cliente para não cobrir a barra de tarefas
// nem cortar o conteúdo.
adjust_maximized :: proc "contextless" (rect: ^win.RECT) {
    if win.IsZoomed(g_hwnd) == win.FALSE do return
    cx := win.GetSystemMetrics(win.SM_CXFRAME) + win.GetSystemMetrics(win.SM_CXPADDEDBORDER)
    cy := win.GetSystemMetrics(win.SM_CYFRAME) + win.GetSystemMetrics(win.SM_CXPADDEDBORDER)
    rect.left   += cx
    rect.right  -= cx
    rect.top    += cy
    rect.bottom -= cy
}

custom_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
    switch msg {
    case win.WM_NCCALCSIZE:
        // wparam != 0: removemos a área não-cliente (barra de título + bordas
        // visuais), mas a moldura funcional continua (resize/snap nativos).
        if wparam != 0 {
            p := cast(^win.NCCALCSIZE_PARAMS)(rawptr(uintptr(lparam)))
            adjust_maximized(&p.rgrc[0])
            return 0
        }

    case win.WM_NCHITTEST:
        return frame_hit_test(hwnd, lparam)
    }

    return win.CallWindowProcW(g_orig_wndproc, hwnd, msg, wparam, lparam)
}

// Define as zonas: bordas = redimensionar, faixa de abas (vão vazio) =
// arrastar (HTCAPTION dá snap + duplo-clique nativos), resto = cliente.
frame_hit_test :: proc "system" (hwnd: win.HWND, lparam: win.LPARAM) -> win.LRESULT {
    sx := i32(i16(u16(lparam & 0xFFFF)))
    sy := i32(i16(u16((lparam >> 16) & 0xFFFF)))

    rect: win.RECT
    win.GetWindowRect(hwnd, &rect)
    rx := sx - rect.left
    ry := sy - rect.top
    w  := rect.right - rect.left
    h  := rect.bottom - rect.top

    B : i32 = 8
    if win.IsZoomed(hwnd) == win.FALSE {
        left   := rx < B
        right  := rx >= w - B
        top    := ry < B
        bottom := ry >= h - B
        if top    && left  do return win.LRESULT(win.HTTOPLEFT)
        if top    && right do return win.LRESULT(win.HTTOPRIGHT)
        if bottom && left  do return win.LRESULT(win.HTBOTTOMLEFT)
        if bottom && right do return win.LRESULT(win.HTBOTTOMRIGHT)
        if left   do return win.LRESULT(win.HTLEFT)
        if right  do return win.LRESULT(win.HTRIGHT)
        if top    do return win.LRESULT(win.HTTOP)
        if bottom do return win.LRESULT(win.HTBOTTOM)
    }

    // faixa de abas arrastável (definida a cada frame em draw_tabstrip)
    if f32(ry) < g_titlebar_h && f32(rx) >= g_drag_x0 && f32(rx) < g_drag_x1 {
        return win.LRESULT(win.HTCAPTION)
    }

    return win.LRESULT(win.HTCLIENT)
}
