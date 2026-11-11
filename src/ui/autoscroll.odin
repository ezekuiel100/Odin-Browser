package ui

import "core:c"
import "core:math"
import im "../../vendor/imgui"

// ── Rolagem automática do botão do MEIO (autoscroll) ────────────────────────
// Contrato (o do Chrome/Firefox no Windows):
//   • aperto do meio na página, FORA de link, com `mousedown` não cancelado e
//     algo rolável sob o cursor → entra no modo. Um ícone marca a ÂNCORA (o
//     ponto do aperto) com setas só nos eixos que ROLAM; a velocidade de cada
//     eixo cresce com a distância do cursor à âncora naquele eixo; dentro da
//     zona morta, parado.
//   • soltou SEM ter saído da zona morta → modo "trava" (segue rolando até o
//     próximo clique). Arrastou para fora da zona morta COM o botão apertado →
//     soltar encerra.
//   • qualquer clique (esq./dir./meio) encerra e é ENGOLIDO: não vira clique de
//     link nem evento JS. Esc, troca de aba, navegação e perda de foco da janela
//     também encerram.
// O alvo é o rolável mais INTERNO sob o aperto (`overflow:auto/scroll` com
// conteúdo transbordando em algum eixo rolável) ou, se não houver, a página — e
// fica TRAVADO nele até o fim, mesmo que bata no limite (não encadeia, como no
// Chrome). Os eixos são decididos no APERTO.
//
// Degradações (cada uma DECLARADA):
//   • o rolável interno é identificado pelo PONTEIRO do nó DOM, só COMPARADO,
//     nunca derreferenciado (o nó pode ter sido liberado pelo JS entre frames).
//     Se o paint não o encontra num frame, o modo encerra.
//   • abre o modo também sobre <input>/<textarea> (não distinguimos campo
//     editável no aperto do meio).

AUTOSCROLL_DEAD :: f32(15)   // raio da zona morta (px) — o do Chromium
AUTOSCROLL_VMAX :: f32(6000) // teto da velocidade (px/s)
AUTOSCROLL_DTMAX :: f32(0.1) // um frame travado não vira um salto de página

Autoscroll :: struct {
    on:      bool,
    tab:     u64,     // id da aba onde começou
    anchor:  [2]f32,  // ponto do aperto, em coordenadas de TELA
    axes:    [2]bool, // {X, Y}: que eixos o alvo rola (decidido no aperto)
    held:    bool,    // o meio ainda está apertado desde o início
    dragged: bool,    // saiu da zona morta com o botão apertado ⇒ soltar encerra
    target:  rawptr,  // nó do rolável interno (só comparação); nil = a página
    acc:     [2]f32,  // resto fracionário do deslocamento (px) por eixo
    // a soltura do meio que ENCERROU o modo não pode virar mouseup/auxclick.
    // Sobrevive ao autoscroll_stop (o aperto encerra, a soltura vem frames depois).
    swallow_mid_release: bool,
}

Autoscroll_Input :: struct {
    mouse:        [2]f32,
    clicked:      [3]bool, // apertou NESTE frame: 0 = esquerdo, 1 = direito, 2 = meio
    mid_released: bool,
    escape:       bool,
    tab_ok:       bool,    // a aba ativa ainda é a do início e não está carregando
}

autoscroll_start :: proc(a: ^Autoscroll, tab: u64, anchor: [2]f32, target: rawptr, axes: [2]bool) {
    a^ = Autoscroll{
        on = true, tab = tab, anchor = anchor, axes = axes, held = true, target = target,
        swallow_mid_release = a.swallow_mid_release,
    }
}

autoscroll_stop :: proc(a: ^Autoscroll) {
    a^ = Autoscroll{swallow_mid_release = a.swallow_mid_release}
}

// Um passo da máquina de estados, ANTES de qualquer widget ler o mouse. Devolve
// quais botões engolir neste frame (o chamador tira o aperto deles do ImGui).
autoscroll_step :: proc(a: ^Autoscroll, inp: Autoscroll_Input) -> (swallow: [3]bool) {
    if !a.on do return
    if !inp.tab_ok || inp.escape {
        autoscroll_stop(a)
        return
    }
    d := inp.mouse - a.anchor
    if a.held && d.x*d.x + d.y*d.y > AUTOSCROLL_DEAD*AUTOSCROLL_DEAD do a.dragged = true

    if inp.clicked[0] || inp.clicked[1] || inp.clicked[2] {
        swallow = inp.clicked
        if inp.clicked[2] do a.swallow_mid_release = true
        autoscroll_stop(a)
        return
    }
    if inp.mid_released && a.held {
        a.held = false
        if a.dragged do autoscroll_stop(a)
    }
    return
}

// Velocidade (px/s) para uma distância `d` (px, com sinal) do cursor à âncora,
// num eixo. Parado na zona morta; depois cresce linear+quadrático (controle fino
// perto da âncora, travessia rápida longe) até o teto.
autoscroll_velocity :: proc(d: f32) -> f32 {
    e := abs(d) - AUTOSCROLL_DEAD
    if e <= 0 do return 0
    v := min(4*e + 0.03*e*e, AUTOSCROLL_VMAX)
    return d < 0 ? -v : v
}

// Deslocamento INTEIRO deste frame (px), por eixo; zero nos eixos que o alvo não
// rola. O resto fica em `acc`: texto em posição sub-pixel sai borrado, e truncar
// sem acumular travaria a rolagem lenta (a 30 px/s um frame de 16 ms dá 0,5 px —
// sempre zero).
autoscroll_delta :: proc(a: ^Autoscroll, mouse: [2]f32, dt: f32) -> (d: [2]f32) {
    if !a.on do return
    t := clamp(dt, 0, AUTOSCROLL_DTMAX)
    for i in 0 ..< 2 {
        if !a.axes[i] do continue
        a.acc[i] += autoscroll_velocity(mouse[i] - a.anchor[i]) * t
        d[i] = math.trunc(a.acc[i])
        a.acc[i] -= d[i]
    }
    return
}

// ── Ponte com o paint (layout.odin) ─────────────────────────────────────────
// `g_aux_scroller`/`g_aux_axes`: gravados pelo paint no frame do APERTO do meio —
// o rolável mais interno sob o cursor (paint é pai-primeiro: o último a gravar é
// o de dentro) e os eixos em que ele rola. `g_autoscroll_target/d`: o rolável a
// mover NESTE frame e quanto; `g_autoscroll_hit` diz se o paint o encontrou.
g_aux_scroller:      rawptr
g_aux_axes:          [2]bool
g_autoscroll_target: rawptr
g_autoscroll_d:      [2]f32
g_autoscroll_hit:    bool

// ImGuiInputFlags_LockUntilRelease (imgui_internal.h, 1.91.9b): o enum público
// do binding não tem os bits privados.
@(private = "file")
LOCK_UNTIL_RELEASE :: transmute(im.InputFlags)c.int(1 << 21)

// Shift + roda = rolagem HORIZONTAL (convenção do Windows). Convertida uma vez,
// logo após o NewFrame, para que todo leitor da roda da página (rolável interno
// no paint, a página no viewport) só precise olhar `MouseWheelH`. O ImGui já
// processou a roda dos PRÓPRIOS painéis dentro do NewFrame, então isto não os
// afeta. Sinal do ImGui: MouseWheelH > 0 rola para a ESQUERDA, e Shift+roda
// para cima também — por isso a cópia é direta.
wheel_shift_to_h :: proc() {
    io := im.GetIO()
    if io.KeyShift && !io.KeyCtrl && io.MouseWheelH == 0 && io.MouseWheel != 0 {
        io.MouseWheelH = io.MouseWheel
        io.MouseWheel = 0
    }
}

// Lê o mouse/teclado do frame e avança a máquina. Roda logo depois do
// im.NewFrame(), ANTES de qualquer widget: o clique que encerra o modo é tirado
// de TODO leitor com a trava de posse do ImGui (owner Any + LockUntilRelease faz
// IsMouseClicked/IsMouseDown devolverem false até a soltura, inclusive nos
// botões internos do ImGui).
autoscroll_input :: proc(s: ^State) {
    a := &s.autoscroll
    if !a.on do return
    tab_ok := len(s.tabs) > 0 && s.tabs[s.active].id == a.tab && !s.tabs[s.active].loading
    inp := Autoscroll_Input{
        mouse        = im.GetMousePos(),
        clicked      = {im.IsMouseClicked(.Left), im.IsMouseClicked(.Right), im.IsMouseClicked(.Middle)},
        mid_released = im.IsMouseReleased(.Middle),
        escape       = im.IsKeyPressed(.Escape),
        tab_ok       = tab_ok,
    }
    sw := autoscroll_step(a, inp)
    keys := [3]im.Key{.MouseLeft, .MouseRight, .MouseMiddle}
    for k, i in keys do if sw[i] do im.SetKeyOwner(k, 0, LOCK_UNTIL_RELEASE)
}

// Chamado no viewport ANTES do paint: calcula o deslocamento do frame e o
// entrega ao paint (rolável interno) ou devolve para a página.
autoscroll_prepare :: proc(s: ^State) -> (page_d: [2]f32) {
    g_aux_scroller = nil
    g_aux_axes = {}
    g_autoscroll_target = nil
    g_autoscroll_d = {}
    g_autoscroll_hit = false
    a := &s.autoscroll
    if !a.on do return
    d := autoscroll_delta(a, im.GetMousePos(), im.GetIO().DeltaTime)
    if a.target != nil {
        g_autoscroll_target = a.target
        g_autoscroll_d = d
        return
    }
    return d
}

// Chamado no viewport DEPOIS do paint (dentro do child rolado): aplica o
// deslocamento da página, encerra se o rolável interno sumiu, e desenha o ícone.
// `page_max_x` é o limite HORIZONTAL da página (ver draw_content: o ImGui não
// sabe dele sozinho).
autoscroll_finish :: proc(s: ^State, page_d: [2]f32, page_max_x: f32) {
    a := &s.autoscroll
    target_seen := g_autoscroll_hit
    g_autoscroll_target = nil
    if !a.on do return
    if a.target != nil && !target_seen {
        autoscroll_stop(a) // o rolável saiu da árvore (ou parou de transbordar)
        return
    }
    if a.target == nil {
        if page_d.x != 0 do im.SetScrollX(clamp(im.GetScrollX() + page_d.x, 0, page_max_x))
        if page_d.y != 0 do im.SetScrollY(clamp(im.GetScrollY() + page_d.y, 0, im.GetScrollMaxY()))
    }
    s.scroll_pending = false // o usuário assumiu a rolagem (como a roda)
    switch {
    case a.axes.x && a.axes.y: im.SetMouseCursor(.ResizeAll)
    case a.axes.x:             im.SetMouseCursor(.ResizeEW)
    case:                      im.SetMouseCursor(.ResizeNS)
    }
    draw_autoscroll_icon(a.anchor, a.axes)
}

// Ícone da âncora: disco claro com borda, ponto no centro e setas nos eixos que
// rolam (↑↓, ←→ ou as quatro).
draw_autoscroll_icon :: proc(c: [2]f32, axes: [2]bool) {
    dl := im.GetForegroundDrawList()
    R  :: f32(14)
    ink := col(0x202020)
    im.DrawList_AddCircleFilled(dl, c, R, col(0xF4F4F4))
    im.DrawList_AddCircle(dl, c, R, col(0x606060), 0, 1.5)
    im.DrawList_AddCircleFilled(dl, c, 2, ink)
    if axes.y {
        im.DrawList_AddTriangleFilled(dl, {c.x, c.y - 10}, {c.x + 5, c.y - 4}, {c.x - 5, c.y - 4}, ink)
        im.DrawList_AddTriangleFilled(dl, {c.x, c.y + 10}, {c.x - 5, c.y + 4}, {c.x + 5, c.y + 4}, ink)
    }
    if axes.x {
        im.DrawList_AddTriangleFilled(dl, {c.x - 10, c.y}, {c.x - 4, c.y - 5}, {c.x - 4, c.y + 5}, ink)
        im.DrawList_AddTriangleFilled(dl, {c.x + 10, c.y}, {c.x + 4, c.y + 5}, {c.x + 4, c.y - 5}, ink)
    }
}

// Eixos em que a PÁGINA rola agora (de dentro do child do viewport).
page_axes :: proc(page_max_x: f32) -> [2]bool {
    return {page_max_x > 0, im.GetScrollMaxY() > 0}
}

// Tenta abrir o modo num aperto do meio sobre a página (dispatch_page_aux, de
// dentro do child do viewport). `scroller`/`scroller_axes` = rolável interno sob
// o aperto e os eixos dele.
autoscroll_try_start :: proc(s: ^State, tab: u64, scroller: rawptr, scroller_axes: [2]bool, page_max_x: f32) -> bool {
    if s.autoscroll.on do return false
    if !im.IsWindowHovered({}) do return false
    axes := scroller != nil ? scroller_axes : page_axes(page_max_x)
    if !axes.x && !axes.y do return false // nada a rolar
    autoscroll_start(&s.autoscroll, tab, im.GetMousePos(), scroller, axes)
    return true
}
