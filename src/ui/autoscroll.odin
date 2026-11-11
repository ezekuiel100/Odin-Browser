package ui

import "core:c"
import "core:math"
import im "../../vendor/imgui"

// ── Rolagem automática do botão do MEIO (autoscroll) ────────────────────────
// Contrato (o do Chrome/Firefox no Windows):
//   • aperto do meio na página, FORA de link, com `mousedown` não cancelado e
//     algo rolável sob o cursor → entra no modo. Um ícone marca a ÂNCORA (o
//     ponto do aperto) e a velocidade cresce com a distância vertical do cursor
//     a ela; dentro da zona morta, parado.
//   • soltou SEM ter saído da zona morta → modo "trava" (segue rolando até o
//     próximo clique). Arrastou para fora da zona morta COM o botão apertado →
//     soltar encerra.
//   • qualquer clique (esq./dir./meio) encerra e é ENGOLIDO: não vira clique de
//     link nem evento JS. Esc, troca de aba, navegação e perda de foco da janela
//     também encerram.
// O alvo é o rolável mais INTERNO sob o aperto (`overflow:auto/scroll` com
// conteúdo transbordando) ou, se não houver, a página — e fica TRAVADO nele até
// o fim, mesmo que bata no limite (não encadeia, como no Chrome).
//
// Degradações (cada uma DECLARADA):
//   • só o eixo VERTICAL: a página não tem rolagem horizontal nem pela roda, e o
//     rolável interno só guarda `scroll_y`.
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
    held:    bool,    // o meio ainda está apertado desde o início
    dragged: bool,    // saiu da zona morta com o botão apertado ⇒ soltar encerra
    target:  rawptr,  // nó do rolável interno (só comparação); nil = a página
    acc:     f32,     // resto fracionário do deslocamento (px)
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

autoscroll_start :: proc(a: ^Autoscroll, tab: u64, anchor: [2]f32, target: rawptr) {
    a^ = Autoscroll{
        on = true, tab = tab, anchor = anchor, held = true, target = target,
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

// Velocidade (px/s) para uma distância `d` (px, com sinal) do cursor à âncora.
// Parado na zona morta; depois cresce linear+quadrático (controle fino perto da
// âncora, travessia rápida longe) até o teto.
autoscroll_velocity :: proc(d: f32) -> f32 {
    e := abs(d) - AUTOSCROLL_DEAD
    if e <= 0 do return 0
    v := min(4*e + 0.03*e*e, AUTOSCROLL_VMAX)
    return d < 0 ? -v : v
}

// Deslocamento INTEIRO deste frame (px). O resto fica em `acc`: texto em
// posição sub-pixel sai borrado, e truncar sem acumular travaria a rolagem lenta
// (a 30 px/s um frame de 16 ms dá 0,5 px — sempre zero).
autoscroll_delta :: proc(a: ^Autoscroll, mouse_y, dt: f32) -> f32 {
    if !a.on do return 0
    a.acc += autoscroll_velocity(mouse_y - a.anchor.y) * clamp(dt, 0, AUTOSCROLL_DTMAX)
    whole := math.trunc(a.acc)
    a.acc -= whole
    return whole
}

// ── Ponte com o paint (layout.odin) ─────────────────────────────────────────
// `g_aux_scroller`: gravado pelo paint no frame do APERTO do meio — o rolável
// mais interno sob o cursor (paint é pai-primeiro: o último a gravar é o de
// dentro). `g_autoscroll_target/dy`: o rolável a mover NESTE frame e quanto;
// `g_autoscroll_hit` diz se o paint o encontrou.
g_aux_scroller:      rawptr
g_autoscroll_target: rawptr
g_autoscroll_dy:     f32
g_autoscroll_hit:    bool

// ImGuiInputFlags_LockUntilRelease (imgui_internal.h, 1.91.9b): o enum público
// do binding não tem os bits privados.
@(private = "file")
LOCK_UNTIL_RELEASE :: transmute(im.InputFlags)c.int(1 << 21)

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
autoscroll_prepare :: proc(s: ^State) -> (page_dy: f32) {
    g_aux_scroller = nil
    g_autoscroll_target = nil
    g_autoscroll_dy = 0
    g_autoscroll_hit = false
    a := &s.autoscroll
    if !a.on do return 0
    dy := autoscroll_delta(a, im.GetMousePos().y, im.GetIO().DeltaTime)
    if a.target != nil {
        g_autoscroll_target = a.target
        g_autoscroll_dy = dy
        return 0
    }
    return dy
}

// Chamado no viewport DEPOIS do paint (dentro do child rolado): aplica o
// deslocamento da página, encerra se o rolável interno sumiu, e desenha o ícone.
autoscroll_finish :: proc(s: ^State, page_dy: f32) {
    a := &s.autoscroll
    target_seen := g_autoscroll_hit
    g_autoscroll_target = nil
    if !a.on do return
    if a.target != nil && !target_seen {
        autoscroll_stop(a) // o rolável saiu da árvore (ou parou de transbordar)
        return
    }
    if a.target == nil && page_dy != 0 {
        im.SetScrollY(clamp(im.GetScrollY() + page_dy, 0, im.GetScrollMaxY()))
    }
    s.scroll_pending = false // o usuário assumiu a rolagem (como a roda)
    im.SetMouseCursor(.ResizeNS)
    draw_autoscroll_icon(a.anchor)
}

// Ícone da âncora: disco claro com borda, ponto no centro e setas ↑↓.
draw_autoscroll_icon :: proc(c: [2]f32) {
    dl := im.GetForegroundDrawList()
    R  :: f32(14)
    im.DrawList_AddCircleFilled(dl, c, R, col(0xF4F4F4))
    im.DrawList_AddCircle(dl, c, R, col(0x606060), 0, 1.5)
    im.DrawList_AddCircleFilled(dl, c, 2, col(0x202020))
    im.DrawList_AddTriangleFilled(dl, {c.x, c.y - 10}, {c.x + 5, c.y - 4}, {c.x - 5, c.y - 4}, col(0x202020))
    im.DrawList_AddTriangleFilled(dl, {c.x, c.y + 10}, {c.x - 5, c.y + 4}, {c.x + 5, c.y + 4}, col(0x202020))
}

// Tenta abrir o modo num aperto do meio sobre a página (dispatch_page_aux, de
// dentro do child do viewport). `scroller` = rolável interno sob o aperto.
autoscroll_try_start :: proc(s: ^State, tab: u64, scroller: rawptr) -> bool {
    if s.autoscroll.on do return false
    if !im.IsWindowHovered({}) do return false
    if scroller == nil && im.GetScrollMaxY() <= 0 do return false // nada a rolar
    autoscroll_start(&s.autoscroll, tab, im.GetMousePos(), scroller)
    return true
}
