package ui

// ── Pintura do <canvas> 2D (M232) ───────────────────────────────────────────
//
// A METADE DE DESENHO do canvas. A outra metade — estado, matriz, achatamento de
// curvas — mora em `src/js/canvas.odin` e sai de lá como uma lista de comandos
// com os pontos JÁ transformados para o espaço do bitmap. Aqui só se converte
// para coordenadas de tela e se emite no painter.
//
// Essa divisão é o que permite testar a geometria do canvas sem janela nenhuma
// (`odin test src/js`) e deixa este arquivo com uma responsabilidade só.
//
// A ESCALA: o bitmap tem o tamanho dos atributos `width`/`height` e a CAIXA tem o
// tamanho do CSS. Quando diferem, o navegador ESTICA o bitmap na caixa — é o que
// `sx`/`sy` fazem aqui (e é por isso que um canvas com CSS `width:100%` fica
// borrado no navegador de verdade também).

import "core:strings"
import im     "../../vendor/imgui"
import csspkg "../css"
import jspkg "../js"

// Chamado pelo paint_box no ramo de conteúdo substituído (kind .Image + is_canvas).
// `origin` é o canto superior-esquerdo do conteúdo em coordenadas de TELA;
// dw/dh são as dimensões da caixa já resolvidas pelo layout.
paint_canvas :: proc(pt: ^Painter, s: ^State, b: ^Box, origin: im.Vec2, dw, dh: f32, eff: f32) {
    if b == nil || b.node == nil || len(s.tabs) == 0 do return
    vm := s.tabs[s.active].vm
    if vm == nil do return
    draw, ok := jspkg.canvas_draw_of(vm, rawptr(b.node))
    if !ok || draw.w <= 0 || draw.h <= 0 do return

    sx := dw / draw.w
    sy := dh / draw.h
    // O desenho é recortado pela caixa: o canvas não vaza (é a superfície dele).
    emit(pt, PC_PushClip{{origin.x, origin.y}, {origin.x + dw, origin.y + dh}})
    defer emit(pt, PC_PopClip{})

    for cmd in draw.cmds {
        switch cmd.op {
        case .Fill_Path, .Stroke_Path:
            n := cmd.n1 - cmd.n0
            if n < 2 do continue
            pts := make([]im.Vec2, n, context.temp_allocator)
            for i in 0 ..< n {
                p := draw.pts[cmd.n0 + i]
                pts[i] = {origin.x + p.x * sx, origin.y + p.y * sy}
            }
            fill := cmd.op == .Fill_Path
            // AddConcavePolyFilled exige ao menos 3 pontos; com 2 não há área.
            if fill && n < 3 do continue
            th := cmd.lw * sx
            if th < 0.5 do th = 0.5 // traço mais fino que meio pixel some no AA
            emit(pt, PC_Polyline{pts, col_o(cmd.color, eff), th, false, fill, false})

        case .Fill_Text:
            if cmd.text == "" do continue
            px := cmd.font_px * sy
            font, fscale, _ := l_pick_font(px, FW_NORMAL, 0, .Sans, false)
            if font == nil do continue
            emit(pt, PC_InlineText{
                font    = font,
                size    = font.FontSize * fscale,
                pos     = {origin.x + cmd.x * sx, origin.y + cmd.y * sy},
                col     = col_o(cmd.color, eff),
                text    = cmd.text,
                spacing = 0,
                kerning = .None, // canvas mede pelo avanço do atlas, sem kerning
            })

        case .Draw_Image:
            n := cmd.n1 - cmd.n0
            if n < 4 do continue
            // O quadrilátero já transformado: usamos a CAIXA dele (uma imagem
            // rotacionada sai alinhada aos eixos — degradação nomeada).
            lo := draw.pts[cmd.n0]
            hi := lo
            for i in 1 ..< n {
                p := draw.pts[cmd.n0 + i]
                lo = {min(lo.x, p.x), min(lo.y, p.y)}
                hi = {max(hi.x, p.x), max(hi.y, p.y)}
            }
            w := (hi.x - lo.x) * sx
            h := (hi.y - lo.y) * sy
            if cmd.x == 0 && cmd.y == 0 { // forma de 3 args: tamanho NATURAL da imagem
                if img := image_get(cmd.text); img.state == .Ready {
                    w = f32(img.w) * sx
                    h = f32(img.h) * sy
                }
            }
            if w <= 0 || h <= 0 do continue
            // deco=false: `drawImage` de imagem quebrada mantém o esqueleto que já
            // havia. Não há medida que justifique mudar o canvas junto — a regra
            // nova é do `<img alt="">`, e aqui não existe elemento nem `alt`.
            emit(pt, PC_Image{cmd.text, {origin.x + lo.x * sx, origin.y + lo.y * sy}, w, h,
                              .Fill, eff, 0.5, 0.5, false})
        }
    }
}

// ── Hooks que o pacote js usa (instalados no @(init) do style.odin) ─────────

// Cor CSS → ARGB: o MESMO parser do resto do motor. Sem isto o canvas teria uma
// tabela de cores própria, que é o começo de duas verdades sobre `red`.
js_canvas_color :: proc(sp: string) -> (u32, bool) {
    return csspkg.parse_color(strings.trim_space(sp))
}

// measureText com a fonte REAL (a mesma escada de tamanhos do texto da página).
js_canvas_measure :: proc(text: string, px: f32) -> f32 {
    aprox := f32(len(text)) * px * 0.5
    font, fscale, _ := l_pick_font(px, FW_NORMAL, 0, .Sans, false)
    if font == nil do return aprox
    cs := strings.clone_to_cstring(text, context.temp_allocator)
    sz := im.Font_CalcTextSizeA(font, font.FontSize * fscale, 1e9, 0, cs)
    // ⚠️ ZERO é uma resposta POSSÍVEL e ERRADA: o atlas de fontes só é construído
    // no 1º frame, e o script de CARGA da página roda antes disso (é a mesma
    // armadilha que o --dumplayout pagou no FIX #4). Um measureText 0 faria todo
    // layout de rótulo colapsar em silêncio — então caímos na aproximação.
    if sz.x <= 0 do return aprox
    return sz.x
}
