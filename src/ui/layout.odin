package ui

// Layout engine (v2): árvore de caixas com BLOCK e INLINE formatting.
//
// - Block context: caixas empilhadas verticalmente (box model).
// - Inline context: itens (palavras, imagens, quebras) fluem da esquerda
//   p/ a direita, quebrando em linhas dentro da largura — cada trecho com
//   sua própria fonte/cor/link (negrito, links clicáveis, imagens ao lado
//   de texto).
//
// Também há floats, flex, grid (colunas), tabelas e position (exceto sticky).

import "core:strings"
import "base:runtime"
import "core:strconv"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:c"
import "core:time"
import "core:unicode/utf8"
import "core:unicode"
import im         "../../vendor/imgui"
import imgui_sdlr "../../vendor/imgui/imgui_impl_sdlrenderer2"
import sdl2       "vendor:sdl2"
import dompkg  "../dom"
import netpkg  "../net"
import csspkg  "../css"

FLT_MAX :: f32(3.4028235e38)

// Correção em-square: o ImGui interpreta o "tamanho" da fonte como a altura
// ascent→descent (stbtt_ScaleForPixelHeight), mas o `font-size` do CSS é o EM
// (unitsPerEm). Passar o px do CSS direto ao ImGui renderiza o texto menor que
// num navegador real. Multiplicamos o tamanho de RENDER/MEDIÇÃO pela razão
// (ascent−descent)/em p/ o em bater com o CSS; a altura de linha e o box
// continuam em px CSS (só o glifo cresce).
//
// ⚠️⚠️ M244: esta razão é DE CADA FACE, não uma constante. Era `1.36` fixo — a
// da Segoe UI — aplicado a todas: com Georgia (~1.14) e Consolas (~1.17) o
// serif saía ~19% e o mono ~22% MAIORES que no Chrome. Como texto maior quebra
// em mais linhas, a página inteira crescia (tailwindcss.com: 14721px contra
// 11635px do Chrome). Medido com fixture por família contra o Chrome headless.
//
// FONT_EM segue como FALLBACK: é o que vale quando não se sabe a face (ex.: um
// tamanho pedido fora do fluxo de texto medido).
FONT_EM :: f32(1.36)

// Tamanho a passar ao ImGui p/ um font-size CSS, dada a razão em-square da face.
// ⚠️ a razão é argumento OBRIGATÓRIO de propósito: quando ela era global, todo
// call-site herdava silenciosamente o valor errado para serif/mono. Assim o
// compilador enumera quem precisa dela.
@(private="file")
render_px :: proc(css: f32, em: f32) -> f32 { return css * (em > 0 ? em : FONT_EM) }

// Cor OPACA imediatamente atrás da caixa sendo pintada (o ancestral com fundo, ou
// o fundo da página). Usada p/ "recortar" os cantos arredondados de um container
// com overflow:hidden — o ImGui só tem clip retangular, então preenchemos o entalhe
// de cada canto (fora do arco) com esta cor. Atualizada (save/restore) em paint_box.
g_bg_behind: u32 = 0xffffff

// Hit-test de clique por ORDEM DE PINTURA. `g_hit_seq` é incrementado uma vez por
// caixa, NA ENTRADA de paint_box (antes dos filhos), e `g_click_seq` guarda a
// ordem da caixa que hoje é o alvo. Vence a MAIOR ordem = a pintada por último =
// a que está por cima.
//
// ⚠️ Antes disto o critério era "o primeiro a gravar vence". Isso acerta o
// aninhamento (filho pintado depois do fundo do pai, mas registrado antes) e
// ERRA entre IRMÃOS sobrepostos: os irmãos são visitados de trás para frente
// (stack_sort por z-index), então o primeiro a gravar é o de BAIXO. Era por isso
// que o ✕ de fechar um modal não funcionava — o botão `absolute z-10` fica SOBRE
// o card, e o clique era creditado ao card. Como o card não tem handler, o evento
// subia até o overlay com target≠currentTarget, e nenhum dos dois caminhos de
// fechar disparava.
g_hit_seq:   int
g_click_seq: int = -1
g_aux_seq:   int = -1 // idem, p/ o alvo do botão do MEIO (s.aux_node)

// Frame em que o botão do meio APERTOU ou SOLTOU: só nesses o paint grava o alvo
// do meio (s.aux_node/s.aux_href).
aux_frame :: #force_inline proc() -> bool {
    return im.IsMouseClicked(.Middle) || im.IsMouseReleased(.Middle)
}

// ── Fase 2: compositing de layers offscreen (group-opacity) ──────────────────
// O renderer SDL, setado no init (browser_ui/headless) — replay_paint precisa
// dele p/ criar/renderizar as texturas de layer. nil = sem compositing (fallback
// desenha o conteúdo inline, sem dimming de grupo).
g_renderer: ^sdl2.Renderer = nil
// Texturas de layer criadas ESTE frame; vivem até o próximo paint_layout (o
// AddImage do dl principal as lê no RenderDrawData de fim-de-frame). Destruídas
// e zeradas no começo de cada paint_layout.
g_layer_textures: [dynamic]^sdl2.Texture
// Every group keeps its compositing semantics, regardless of paint order.
// composite_layer allocates only the visible bounding box and reuses cached
// textures; a frame-wide count must not disable masks or group opacity.
BACKDROP_BUDGET :: 12 // cada backdrop-filter re-renderiza o dl inteiro num target (caro)
g_backdrop_count: int = 0 // backdrop-filters aplicados neste frame (reset em paint_layout)

// Cache de layers por NÓ DOM: reusa a textura compositada entre frames quando o
// conteúdo (hash dos vértices) e os parâmetros (blend/filtros) não mudaram — pula
// o render offscreen + readback + processamento de filtro. O nó é estável entre
// frames (a Box é reconstruída, o nó não). Chave = ^Node como rawptr.
Layer_Cache :: struct {
    tex:    ^sdl2.Texture, // textura FINAL compositada (persiste entre frames)
    hash:   u64,           // hash de (vértices locais + blend + filtros)
    fx, fy: f32,           // origem de tela onde compositar (reposiciona no scroll)
    iw, ih: i32,           // tamanho do bbox
    custom: bool,          // true se a tex tem BlendMode custom (mix-blend) → tint branco
    premul: bool,          // true se a tex compõe em alpha PREMULTIPLICADO → tint premul_tint
    used:   int,           // g_frame em que foi usada por último (p/ eviction)
}
g_layer_cache: map[rawptr]Layer_Cache
g_round_clip_cache: map[rawptr]Layer_Cache
g_frame: int = 0 // contador de frames (incrementa em paint_layout)

// Geometry-only shadow masks can be shared by cards and tinted at draw time.
Shadow_Key :: struct { w, h, radius, dx, dy, blur, spread: f32 }
Shadow_Mask :: struct { tex: ^sdl2.Texture, x, y: f32, w, h, used: int }
g_shadow_masks: map[Shadow_Key]Shadow_Mask

@(private="file")
fnv :: proc(h: u64, v: u32) -> u64 { return (h ~ u64(v)) * 1099511628211 }

// ── Transições genéricas ─────────────────────────────────────────────────────
// CSS transitions animam props de PINTURA (opacity/background/border/transform)
// quando o valor-alvo muda — por :hover, :focus/:active OU por re-layout (troca
// de classe via JS). O estado persiste keyed pelo NÓ DOM (a Box é reconstruída a
// cada layout; o nó sobrevive), então é guardado num mapa global e não na Box.
// Cada canal guarda (start, target, prog): quando o alvo muda, snapshota o valor
// exibido como novo start e reinicia prog — o que dá reversão suave no meio da
// animação. Limpo em transitions_clear() quando um DOM é liberado (evita nó solto).
// `wait` acumula o transition-delay: enquanto < delay o canal SEGURA o valor
// inicial (o relógio de progresso só começa depois).
Trans_CChan :: struct { start, tgt: u32, prog, wait: f32 } // canal de cor (lerp em u32)
Trans_FChan :: struct { start, tgt, prog, wait: f32 }      // canal escalar
Trans_State :: struct {
    xform:XChan,
    init:    bool,      // 1º frame: assume o alvo sem animar (evita flash inicial)
    hoverp:  Trans_FChan, // progresso do blend de cor de TEXTO rumo ao :hover
    bg:      Trans_CChan,
    border:  Trans_CChan,
    opacity: Trans_FChan,
    rot, sx, sy: Trans_FChan, // transform rotate/scale (translate é resolvido no layout)
}
g_trans: map[^dompkg.Node]Trans_State

// ── resize (css-ui): tamanho arrastado pelo usuário ──────────────────────────
// Mesmo padrão do g_trans acima: o tamanho vive num mapa keyed pelo NÓ DOM, não
// na Box, porque a Box é reconstruída a cada restyle (zoom, container query,
// mutação de DOM por JS) e o arraste do usuário tem de sobreviver a isso.
// GRAVADO só no paint (arraste do mouse, caminho de app), LIDO no layout_box.
// ⇒ nenhum teste escreve neste mapa; ver a nota de threads em resize_apply_size.
Resize_Size :: struct { w, h: f32, has_w, has_h: bool } // valores no espaço do box-sizing
g_resize: map[^dompkg.Node]Resize_Size
// arraste em andamento (um por vez): nó + mouse e tamanho no início do arraste.
g_resize_drag: struct { node: ^dompkg.Node, active: bool, mx, my, w0, h0: f32 }

// Esquece todas as transições em andamento (chamado ao liberar um DOM — as chaves
// são ponteiros de nó que vão deixar de existir).
transitions_clear :: proc() {
    for _,st in g_trans { delete(st.xform.start.ops); delete(st.xform.target.ops) }
    clear(&g_trans); svg_css_clear(); clear(&g_resize); g_resize_drag = {}
} // hook de "DOM liberado": limpa também o fill/stroke de CSS por nó e o tamanho arrastado

// Aplica um tamanho arrastado como se fosse `width`/`height` do AUTOR — mesmos
// campos, mesmo espaço de box-sizing. Consequência desejada: min/max-width,
// aspect-ratio e o clamp do flex continuam valendo por cima, sem código novo.
// Só toca o eixo efetivamente arrastado (resize:horizontal não congela a altura).
resize_apply_size :: proc(b: ^Box, st: Resize_Size) {
    if st.has_w {
        b.has_width = true; b.width = st.w
        b.width_pct = false; b.width_mc = false; b.def_w = true
    }
    if st.has_h {
        b.has_height = true; b.height = st.h
        b.has_height_pct = false; b.height_mc = false
    }
}

// Aplica o tamanho arrastado a TODA a subárvore, ANTES de qualquer medida.
// Por que uma varredura e não só o hook dentro do layout_box do item: quem
// dimensiona um item de flex/grid é o CONTAINER, e ele lê `has_width`/`def_w`
// do filho ANTES de chamá-lo (base do flex, "estica na trilha?") — depois impõe
// o resultado por `force_w`, que vence a width. Aplicar dentro do layout_box do
// item chegava tarde: o tamanho só valia da passada SEGUINTE em diante (o campo
// mutado sobrevivia na Box), então dependia de quantos passes o chamador faz —
// o app faz 1 por frame, o --dumplayout faz 1, os testes faziam 1.
// Varrer a partir da raiz da passada resolve por CONSTRUÇÃO, sem espalhar hooks
// pelos algoritmos de flex/grid/inline. Custo zero quando ninguém arrastou nada
// (o mapa vazio nem chega aqui) — e um arraste é um nó só.
@(private="file")
resize_pull_tree :: proc(b: ^Box) {
    if b == nil do return
    if b.resize != .None && b.node != nil {
        if st, ok := g_resize[b.node]; ok do resize_apply_size(b, st)
    }
    for c in b.children do resize_pull_tree(c)
    for it in b.inlines { // <textarea> é átomo INLINE: mora aqui, não em children
        if it.kind == .InlineBox do resize_pull_tree(it.box)
    }
}

// Avança um canal de cor rumo a `target` por dt/dur; devolve a cor exibida.
@(private="file")
trans_step_c :: proc(ch: ^Trans_CChan, target: u32, tr: Transition, dt: f32, init: bool) -> u32 {
    if init || !tr.on { ch^ = {target, target, 1, 0}; return target }
    cur := lerp_color(ch.start, ch.tgt, timing_eval(tr.timing, clamp(ch.prog, 0, 1)))
    if target != ch.tgt { ch.start = cur; ch.tgt = target; ch.prog = 0; ch.wait = 0 }
    if ch.wait < tr.delay { ch.wait += dt; return ch.start } // ainda no atraso
    ch.prog = tr.dur > 0 ? min(1, ch.prog + dt / tr.dur) : 1
    return lerp_color(ch.start, ch.tgt, timing_eval(tr.timing, clamp(ch.prog, 0, 1)))
}

// Idem p/ um escalar (opacity, componentes de transform).
@(private="file")
trans_step_f :: proc(ch: ^Trans_FChan, target: f32, tr: Transition, dt: f32, init: bool) -> f32 {
    ev :: proc(ch: ^Trans_FChan, tm: Timing) -> f32 { return ch.start + (ch.tgt - ch.start) * timing_eval(tm, clamp(ch.prog, 0, 1)) }
    if init || !tr.on { ch^ = {target, target, 1, 0}; return target }
    cur := ev(ch, tr.timing)
    if abs(target - ch.tgt) > 1e-6 { ch.start = cur; ch.tgt = target; ch.prog = 0; ch.wait = 0 }
    if ch.wait < tr.delay { ch.wait += dt; return ch.start } // ainda no atraso
    ch.prog = tr.dur > 0 ? min(1, ch.prog + dt / tr.dur) : 1
    return ev(ch, tr.timing)
}

Rect :: struct { x, y, w, h: f32 }

Box_Kind :: enum { Block, Image }

// Controle de formulário tratado no paint. None = caixa comum.
//   Checkbox/Radio: marca desenhada + clique alterna o estado.
//   Text/Password:  campo editável (InputText do ImGui sobreposto).
//   Textarea:       campo multi-linha (InputTextMultiline sobreposto).
Form_Control :: enum u8 { None, Checkbox, Radio, Text, Password, Textarea, Select }

// Capacidade do buffer editável de um campo de texto (bytes, com terminador).
EDIT_CAP :: 256

Box :: struct {
    // Root-only cache, shared by the frame loop and synchronous CSSOM reads.
    geometry_valid: bool,
    geometry_w, geometry_h: f32,
    geometry_resources: u64,

    x_world: matrix[4,4]f64,
    x_hovered: bool,
    x_view_origin, x_paint_origin: im.Vec2,
    node: ^dompkg.Node,
    kind: Box_Kind,

    // box model (do estilo computado)
    margin:  [4]f32,
    has_margin: bool,
    padding: [4]f32,
    // padding/margin em %: fração+offset (base = LARGURA do bloco contenedor),
    // resolvidos no início do layout_box, que recebe avail_w.
    padding_pct: [4]bool, padding_frac: [4]f32, padding_off: [4]f32,
    margin_pct:  [4]bool, margin_frac:  [4]f32, margin_off:  [4]f32,
    border_w: [4]f32, // larguras por lado (t r b l)
    border_c: [4]u32, // cores por lado (t r b l)
    border_style_none: [4]bool,
    has_border: bool,
    outline_w: f32,   // outline: traço fora da caixa (não afeta layout)
    outline_c: u32,
    outline_off: f32,
    bg: u32,
    has_bg: bool,
    grad: csspkg.Gradient,
    grad_clip_text: bool, // `background-clip:text`: o grad colore os GLIFOS, não a caixa
    // Gradientes clipados ao texto de elementos INLINE (o `<span class=gradient-text>`
    // do Tailwind, que é a forma comum): os itens de texto do span pertencem a ESTA
    // caixa, não à do span, então a atribuição vai por `ibg_grp`. Fora da linha
    // (vazio no caso comum) porque um Gradient tem ~350 B — a lição do M162/M29.
    inline_grads: [dynamic]Inline_Grad,
    bimg: Border_Image, // border-image; `src`/`grad` resolvidos e OWNED aqui
    bg_img: string, // background-image: url() resolvida (owned)
    bg_extra: []Bg_Layer, // camadas 1..N-1 (owned: slice + urls); vazia no caso comum
    bg_canvas: bool, // fonte do fundo do CANVAS: pinta o fundo sobre a página toda
    bg_size: Bg_Size,
    bg_origin: Bg_Clip, // background-origin: área de posicionamento da imagem
    bg_clip: Bg_Clip,
    bg_pos_x, bg_pos_y: f32,
    bg_repeat: bool,
    obj_fit: Obj_Fit,
    obj_pos_x, obj_pos_y: f32,
    cursor: Cursor_Kind,
    accent_color: u32, has_accent: bool, // accent-color de checkbox/radio marcado
    scroll_smooth: bool,   // scroll-behavior:smooth (âncoras animam)
    scroll_margin_top:  f32, // desloca o alvo do scroll de âncora (compensa header fixo)
    scroll_padding_top: f32, // recuo do topo do container de scroll (raiz → scroll de página)
    overscroll_contain: bool, // overscroll-behavior contain/none — não encadeia a roda ao pai/página
    appearance_none: bool, // appearance:none — sem marca nativa de controle
    pe_none: bool,         // pointer-events:none — transparente a cliques/hover (herda)
    invisible: bool,       // visibility:hidden — não pinta o próprio conteúdo (mantém layout)
    overflow_hidden: bool,
    ovf_clip_x: bool, ovf_clip_y: bool, // clip por eixo (overflow-x/-y independentes)
    overflow_scroll: bool, // container rolável (overflow:scroll/auto)
    ovf_scroll_x: bool,    // e o eixo X rola (overflow-x scroll/auto); hidden só clipa
    ovf_scroll_y: bool,    // idem no eixo Y
    scroll_container: bool, // hidden/scroll/auto (NÃO clip) — min-size:auto de flex item
    resize: Resize_Dir,    // resize — alça de arraste no canto inferior direito.
                           // JÁ FILTRADO pela aplicabilidade (ver apply_box): aqui
                           // != None significa "esta caixa tem alça", sem mais guardas.
    break_all, min_break: bool,
    break_word: bool,      // overflow-wrap/word-break: quebra dentro de palavras longas
    ellipsis:   bool,      // text-overflow:ellipsis (efetivo com overflow_hidden)
    line_clamp: int,       // -webkit-line-clamp: N (0 = sem clamp)
    text_balance:    bool, // text-wrap: balance (reequilibra as linhas)
    text_indent:     f32,  // recuo da 1ª linha (px OU fração do content-w se _pct)
    indent_each_line, indent_hanging: bool,
    unicode_bidi: Unicode_Bidi,
    writing_mode: Writing_Mode,
    text_orientation: Text_Orientation,
    vertical_block_extent: f32,
    direction: Directionality,
    text_indent_pct: bool,
    word_spacing:    f32,  // px extra em cada espaço entre palavras (nível de bloco)
    scroll_y:        f32,  // deslocamento de scroll do elemento (estado; persiste)
    scroll_max:      f32,  // scroll máximo = altura natural - altura visível
    scroll_x:        f32,  // idem no eixo X (só com ovf_scroll_x)
    scroll_max_x:    f32,  // quanto o conteúdo em fluxo passa da borda direita
    wheel:          [2]Wheel_Axis, // animação local; preservada no restyle
    float:  Float_Side,    // float:left/right (fora do fluxo vertical normal)
    clear:  Clear_Side,    // clear:left/right/both
    has_maxw: bool, maxw: f32, maxw_pct: bool,
    has_minw: bool, minw: f32, minw_pct: bool,
    has_width: bool, width: f32, width_pct: bool,
    def_w: bool, // width DEFINIDA no CSS (comp.has_width) — estável; NÃO é mutado
                 // pela síntese de largura-default de controles/contain-intrinsic
                 // como has_width. É o sinal correto de "não esticar em grid/flex".
    has_height: bool, height: f32,
    has_height_pct: bool, height_pct: f32, // height:N% (fração; resolvida contra a altura DEFINIDA do pai)
    // px somado DEPOIS de resolver a fração: `calc(100% - 40px)` (base só no layout)
    width_pct_off: f32, height_pct_off: f32,
    minw_pct_off: f32, maxw_pct_off: f32,
    // limites absolutos de min()/max()/clamp() MISTO — aplicados por pct_resolve
    // no MESMO ponto em que a fração é resolvida (ver Len_Bounds em style.odin)
    width_bd, height_bd, minw_bd, maxw_bd, minh_bd, maxh_bd: Len_Bounds,
    // min/max-height em %: o PAI resolve p/ px em minh/maxh antes de dispor o filho
    minh_pct: f32, has_minh_pct: bool, minh_pct_off: f32,
    maxh_pct: f32, has_maxh_pct: bool, maxh_pct_off: f32,
    height_mc: bool, // height:min/max/fit-content (intrínseca; não estica em flex/grid)
    width_mc: bool,  // width:min/max/fit-content (largura intrínseca = measure_intrinsic_w)
    width_fit: bool,
    width_minc: bool, // ...e era especificamente `min-content` (muda a fr num grid; ver grid_intrinsic_w)
    aspect: f32, // aspect-ratio (largura/altura); deriva a dimensão auto
    has_maxh: bool, maxh: f32,
    has_minh: bool, minh: f32, minh_mc: bool,
    box_sizing: Box_Sizing,
    margin_x_auto: bool,
    margin_left_auto: bool, margin_right_auto: bool, // auto-margins de flex (empurram no eixo principal)
    margin_top_auto: bool, margin_bottom_auto: bool, // auto-margins verticais (centram abspos)
    border_radius: [4]f32, border_radius_pct: [4]bool, // por canto (tl tr br bl)

    // posicionamento
    pos: Position,
    z_index: int,
    z_index_set, stacking_hint, stacking_item: bool,
    inset: [4]f32, inset_pct: [4]bool, inset_has: [4]bool,
    inset_off: [4]f32, // px somado após a fração: top:calc(50% - 10px)
    rel_dx, rel_dy: f32, // deslocamento de position:relative + transform (px)
    sticky_max_dy: f32,  // sticky: teto do deslocamento (até a base do pai)
    // posição estática (onde a caixa cairia no fluxo) — usada por absolutos sem
    // inset no eixo. Gravada quando o fluxo pula a caixa; coords absolutas.
    static_x, static_y: f32, has_static: bool,
    // abspos filho de container FLEX: a posição estática é ALINHADA pela
    // justify-content (eixo principal) / align-items (cruzado) do flex, não o canto
    // do container (CSS Align §4). static_x/y = origem do content box do flex;
    // static_cw/ch = tamanho do content box; static_ax/ay = tipo de alinhamento por
    // eixo (0=start,1=center,2=end). place_absolute centraliza a MARGIN box.
    static_flex: bool,
    static_cw, static_ch: f32,
    static_ax, static_ay: u8,
    // IÇAMENTO (layout_absolutes): a caixa foi movida p/ os filhos do bloco
    // contenedor, logo APÓS o âncora. A partir daí ela não pode mais reler a
    // posição estática do fluxo — na lista nova ela está depois do âncora, e o
    // cursor já passou por ele. Guardamos o deslocamento em relação ao âncora
    // (que é re-layoutado a cada passe) p/ recompor a estática sem desandar.
    hoisted: bool,
    hoist_anchor: ^Box,
    hoist_dx, hoist_dy: f32,

    // visual
    opacity: f32,  // 1.0 = opaco
    isolate: bool, // isolation:isolate — força grupo de composição
    clip_path: Clip_Shape, // clip-path — recorta a subárvore (máscara CPU na layer)
    mask_image: Mask_Image,
    mask_grad: csspkg.Gradient, // mask-image: <gradient> — máscara alpha na layer
    blend_mode: Blend_Mode, // mix-blend-mode (Normal = sem blend)
    filters: [MAX_FILTERS]Filter_Op, n_filters: int, // filter (aplicados em ordem)
    backdrop_filters: [MAX_FILTERS]Filter_Op, n_backdrop: int, // backdrop-filter (frosted glass)
    hover: Hover_Style, // overrides de :hover aplicados quando o mouse está sobre
    trans: [Trans_Chan]Transition, // transition por canal (dur/delay/curva); ver transition.odin
    hover_t: f32,        // progresso da animação 0..1 (estado; persiste entre frames)
    animations: []Animation_Player,

    // transform: translate (offset visual sem afetar o layout)
    transform_tx, transform_ty:         f32,
    transform_tx_pct, transform_ty_pct: bool,
    motion_rotation:f32,
    xform:^XList,
    perspective, perspective_ox, perspective_oy:f32,
    perspective_opx,perspective_opy,transform_opx,transform_opy,transform_opz:f32,
    xf_percent: [4]f32,
    transform_rot:                      f32, // radianos
    transform_sx, transform_sy:         f32, // escala (1 = sem)
    transform_ox, transform_oy:         f32, // transform-origin (fração 0..1)
    xf_a, xf_b, xf_c, xf_d:             f32, // parte linear 2×2 (skew/matrix)
    has_xform_matrix:                   bool,
    // 3D achatado (ver Computed): lado que o transform próprio mostra, e as duas
    // props que decidem se a caixa some quando o lado é o de trás.
    xf_back, backface_hidden, preserve_3d, in_p3d: bool,
    has_transform:                      bool,
    // offset-path (CSS Motion Path) — ver Computed
    has_offset_path:      bool,
    offset_path:          string,
    offset_distance:      f32,
    offset_distance_pct:  bool,
    offset_rotate_auto:   bool,
    offset_rotate_angle:  f32,
    cb_abs:   bool, // will-change: estabelece containing block p/ absolute
    cb_fixed: bool, // will-change: estabelece containing block p/ fixed

    // box-shadow (externas)
    shadows:  [MAX_SHADOWS]Shadow,
    shadow_n: int,

    // text-shadow (herda; pintada atrás do texto em paint_inline)
    text_shadows:  [MAX_SHADOWS]Shadow,
    text_shadow_n: int,

    // flex container
    is_flex:  bool,
    flex_dir: Flex_Dir,
    flex_reverse: bool, // row-reverse / column-reverse
    flex_wrap: bool,
    flex_wrap_reverse: bool,
    justify:  Flex_Just,
    align_items: Flex_Align,
    align_content: Flex_Just,  // distribuição das linhas (flex-wrap)
    ac_stretch: bool,          // align-content stretch → estica trilhas auto (grid)
    justify_items: Flex_Align, // grid: alinhamento horizontal na célula
    align_self: Flex_Align, has_align_self: bool,
    justify_self: Flex_Align, has_justify_self: bool, // grid item
    // `safe`/`unsafe` das seis propriedades de alinhamento (ver Overflow_Pos)
    justify_ovf, align_content_ovf: Overflow_Pos,
    align_items_ovf, justify_items_ovf: Overflow_Pos,
    align_self_ovf, justify_self_ovf: Overflow_Pos,
    gap:      f32,
    // gap em %: fração+offset resolvidos no layout (base = conteúdo do container)
    gap_pct: bool, gap_frac: f32, gap_off: f32,
    row_gap_pct: bool, row_gap_frac: f32, row_gap_off: f32,
    // flex item
    flex_grow: f32, flex_shrink: f32,
    flex_basis: f32, flex_basis_pct: bool, has_flex_basis: bool, flex_basis_auto: bool,
    flex_basis_pct_off: f32,
    flex_basis_bd: Len_Bounds,
    order: int, // ordem visual em flex/grid

    // grid container
    is_grid: bool,
    grid_auto_fill: bool,
    grid_track_n: int,
    grid_tracks: [GRID_MAX_TRACKS]Grid_Track,
    grid_row_track_n: int,                       // grid-template-rows explícitas
    grid_row_tracks: [GRID_MAX_TRACKS]Grid_Track,
    grid_auto_row_n: int, grid_auto_rows: [GRID_MAX_AUTO]Grid_Track, // trilhas IMPLÍCITAS (ciclam)
    grid_auto_col_n: int, grid_auto_cols: [GRID_MAX_AUTO]Grid_Track,
    grid_flow_col: bool, grid_flow_dense: bool,  // grid-auto-flow
    // ── subgrid (CSS Grid 2) ──
    grid_sub_cols, grid_sub_rows: bool, // trilhas do eixo vêm do grid pai
    has_gap_col, has_gap_row: bool,     // gap declarado (normal = gutter do pai)
    // Trilhas IMPOSTAS pelo pai: [lo, hi] de cada trilha coberta, relativas ao
    // início da área. Slices TEMPORÁRIOS: o pai grava antes de cada layout_box do
    // filho e o layout_grid do filho os CONSOME (zera) — nunca sobrevivem ao frame.
    sg_cols, sg_rows: [][2]f32,
    sg_pgap: [2]f32,            // gutter efetivo do pai (coluna, linha)
    // Contribuições de altura dos itens às linhas do pai (saída do passe de
    // medida de um subgrid de linhas; lida e zerada pelo pai).
    sg_contrib: []Grid_Contrib,
    container_inline: bool, // container-type: inline-size — a largura é medida p/ @container
    content_hidden: bool,   // content-visibility: hidden — não constrói/pinta o conteúdo
    bg_fixed: bool,         // background-attachment: fixed — fundo ancorado no VIEWPORT
    row_gap: f32,
    // grid item (linha 1-based; 0 = auto-place)
    grid_col_start: int, grid_col_span: int,
    grid_row_start: int, grid_row_span: int,
    grid_col_start_auto, grid_col_end_auto: bool, // linha `auto` (só p/ o filho absoluto)
    grid_row_start_auto, grid_row_end_auto: bool,
    // Filho ABSOLUTO de um grid (CSS Grid §9.1): bordas da ÁREA do grid que lhe
    // servem de bloco contenedor, RELATIVAS ao content box do grid (assim não
    // precisam acompanhar translate_subtree). `gabs_has[i]` falso = linha auto →
    // vale a borda do próprio container. Ordem: 0=esq 1=topo 2=dir 3=base.
    // Gravadas por layout_grid, lidas por layout_absolutes.
    gabs: [4]f32, gabs_has: [4]bool,
    // Caixa IÇADA para outro pai pelo layout_absolutes: deixou de ser filha (de
    // árvore de caixas) do container onde nasceu, e o novo pai não pode tratá-la
    // como filha DELE (ex.: aplicar grid-area de um grid que não é o pai no DOM).
    reparented: bool,

    // geometria (border box), coords locais do viewport
    x, y, w, h:                      f32,
    content_x, content_y, content_w: f32,

    // ── BBOX DE SUBÁRVORE (preenchido por compute_subtree_bbox, pós-layout) ────
    // União de TUDO que a subárvore pinta, no espaço local de paint desta caixa —
    // isto é, as coordenadas que `paint_box(b, 0, 0)` produziria. Inclui a própria
    // border box expandida por outline e box-shadow, e os filhos EM FLUXO
    // deslocados de `rel_dx/rel_dy` (que é o que o paint faz via ox2).
    //
    // ⚠️ `sub_safe` é o que autoriza usar isto para CULLAR, e é falso sempre que
    // algo na subárvore quebra a premissa "extensão = bbox + offset":
    //   • Absolute/Fixed/Sticky — pintados com offset (0,0) ou compensados por
    //     scroll no PRÓPRIO filho, então não acompanham o offset do pai;
    //   • qualquer transform — os vértices são movidos no REPLAY, depois da decisão;
    //   • bg_canvas — pinta a página inteira a partir de uma caixa pequena;
    //   • transition/animação — pular a caixa CONGELA o relógio dela (o avanço
    //     acontece dentro do paint_box), e ela reapareceria no tempo errado.
    // O bit é propagado para CIMA: um pai só é seguro se todos os filhos são.
    sub_x0, sub_y0, sub_x1, sub_y1: f32,
    // Segundo retângulo: descendentes FORA DE FLUXO (position:absolute). Eles são
    // pintados com offset (0,0), logo o `sub_*` deles já está em espaço GLOBAL e
    // NÃO acompanha o offset do ancestral — misturar os dois num retângulo só é o
    // que fazia `sub_safe` cair em 95–100% das layers (out-of-flow é 13% das
    // caixas em site real, então uma subárvore grande sempre tem uma).
    abs_x0, abs_y0, abs_x1, abs_y1: f32,
    has_abs: bool,
    sub_safe: bool,

    // Image (block-level)
    img_url: string, img_dw, img_dh: f32,
    img_deco: bool,           // <img alt=""> / aria-hidden: se falhar, não pinta NADA (ver img_is_decorative)
    img_src_node: ^dompkg.Node, // <source> de <picture> que venceu: é dele que sai a PROPORÇÃO até carregar
    is_svg: bool, svg_fg: u32, // <svg> inline: renderiza os filhos gráficos (currentColor = svg_fg)
    is_canvas: bool,          // <canvas>: o conteúdo é a lista de comandos 2D do JS (canvas2d.odin)

    href: string, // link clicável (caixa inteira)

    // controle de formulário. checkbox/radio: marca desenhada + clique alterna.
    // text/password: buffer editável (pointer estável) mostrado via InputText.
    ctrl:          Form_Control,
    ctrl_checked:  bool,
    ctrl_disabled: bool,
    ctrl_readonly: bool,
    edit_buf:      [EDIT_CAP]u8, // valor editável (text/password), null-terminado
    edit_hint:     string,       // placeholder (owned)
    // ::placeholder (M218). `hint_color == 0` = sem regra de COR → segue o padrão
    // antigo (cor do texto a 50%). `hint_alpha` é a `opacity` do pseudo (1 = sem
    // regra); `opacity:0` é o idioma do rótulo flutuante, que ESCONDE a dica.
    hint_color:    u32,
    hint_alpha:    f32,
    edit_color:    u32,          // cor do texto do campo (do CSS)
    caret_color:   u32,          // caret-color; has_caret=false = a cor do texto
    has_caret:     bool,
    edit_font:     ^im.Font,     // fonte do conteúdo (mesma da página), no tamanho do CSS
    edit_em:       f32,          // razão em-square da face do edit_font (ver render_px)

    // inline formatting context
    font_kerning: Font_Kerning,
    is_inline: bool,
    strut:     f32, // altura mínima da caixa-linha (fonte própria do bloco × line-height)
    is_table:  bool,
    is_table_row:    bool, // display:table-row (ou <tr>)
    is_table_cell:   bool, // display:table-cell (ou <td>/<th>)
    is_table_rowgrp: bool, // display:table-*-group (ou <thead>/<tbody>/<tfoot>)
    is_caption:      bool, // <caption> (ou display:table-caption)
    table_fixed:         bool, // table-layout:fixed
    empty_cells_hide:    bool, // empty-cells:hide (célula vazia não pinta fundo/borda)
    caption_side_bottom: bool, // caption-side:bottom
    is_multicol: bool,     // container multi-coluna (column-count/column-width)
    mc_count: int, mc_width: f32, mc_gap: f32,
    break_before_avoid: bool, break_after_avoid: bool, // break-before/after:avoid (fragmentação)
    border_collapse: bool,
    align:     Text_Align,
    align_last: Text_Align, has_align_last: bool, // text-align-last (última linha)
    inlines:   [dynamic]Inline_Item,
    inline_sources: [dynamic]^Inline_Source, // immutable provenance shared by split/coalesced words
    inline_effects: [dynamic]^Inline_Effect, // owned scopes, shared by word fragments
    inline_parent_effect: ^Inline_Effect, // out-of-flow descendants retain inline opacity

    children: [dynamic]^Box,
}

Inline_Source :: struct {
    node: ^dompkg.Node,
    left, right: ^Inline_Source,
    length: int,
    owner: ^Box,
}

Inline_Item :: struct {
    source: ^Inline_Source,
    source_start: int,
    line_id: int,

    kind:  enum { Word, Image, Break, InlineBox },
    effect: ^Inline_Effect,
    invisible: bool, // independent of line-clamp/ellipsis
    ibg_invisible: bool,
    box:   ^Box,   // InlineBox: caixa (display:inline-block) que flui na linha (owned)
                   // ⚠️ p/ InlineBox, x/y/w/h descrevem a MARGIN box (a border-box
                   // é bx.w/bx.h, deslocada por bx.x/bx.y = margem esq/topo).
    text:  string, // Word (owned)
    font:  ^im.Font, fsize: f32, scale: f32, color: u32,
    // razão em-square DA FACE deste item (ver render_px). Viaja junto do
    // ponteiro de fonte porque a medição acontece longe da escolha da face,
    // e usar a razão de outra família dá texto do tamanho errado.
    em: f32,
    lh: f32, // multiplicador de altura de linha
    letter_spacing: f32, // px extra entre glifos (0 = normal)
    font_kerning: Font_Kerning,
    deco: Deco, // text-decoration (line/color/style/thickness) que cobre este item
    valign: V_Align,    // vertical-align dentro da linha
    space_before: bool, // havia whitespace antes deste item no fluxo?
    nowrap: bool,       // white-space:nowrap — não quebra linha antes deste item
    pad_before, pad_after: f32, // margem/padding/borda HORIZONTAL do elemento inline
                                // (acumulada no 1º/último item do elemento)
    // Fundo/borda de um elemento INLINE que os envolve (ex.: <a class=button>,
    // badges/pílulas). Itens consecutivos com o mesmo `ibg_grp` e na mesma linha
    // formam uma caixa; pintada ATRÁS do texto em paint_inline. igrp=0 = sem caixa.
    ibg_grp: u32,
    ibg_has: bool,   // o elemento tem background-color?
    ibg:  u32,       // background-color (has_bg do elemento)
    ibd:  u32, ibw: f32, // cor e largura de borda (lado superior, aprox. uniforme)
    irad: f32,       // border-radius (canto sup-esq, aprox.)
    ipt, ipb: f32,   // padding+borda vertical (expande a caixa acima/abaixo do texto)
    ibl, ibr: f32,   // padding+borda horizontal (só nas pontas do elemento; exclui margin)
    href:  string, // Word clicável (owned)
    // Identidade do <a> que gerou este item. Um link de várias palavras rende um
    // item por palavra; sem isto o realce de hover só via a palavra sob o cursor.
    // 0 = item fora de link (ou link sem grupo atribuído).
    link_grp: u32,
    // Idem para o elemento INLINE cujo `:hover` do AUTOR muda a text-decoration
    // (`a:hover{text-decoration:underline}`): o grupo é a região de hover (o
    // elemento inteiro, não a palavra) e `hov_deco` é a decoração enquanto o
    // mouse estiver sobre ele. 0 = nenhuma regra dessas cobre este item.
    hov_grp:  u32,
    hov_deco: Deco,
    img_url: string, // Image (owned)
    img_deco: bool,  // idem Box.img_deco
    img_radius: [4]f32,
    img_radius_pct: [4]bool,
    img_fit: Obj_Fit,
    img_pos_x, img_pos_y: f32,
    req_w, req_h: f32, // Image: width/height do CSS (0 = auto → tamanho intrínseco)
    // medida/posição
    text_w: f32,        // largura intrínseca (medida 1x)
    x, y, w, h: f32,    // posição na linha (por frame)
    // overflow-wrap/text-overflow (recalculados a cada layout)
    break_all, min_break: bool, // regular character breaks / min-content opportunities
    split_tail: bool, // generated by layout; rejoin before measuring or reflow
    vertical_sideways: bool,
    orientation_set: bool,
    orientation: Text_Orientation,
    bidi_scopes: [8]Bidi_Scope,
    bidi_scope_n: u8,
    bidi_level, bidi_space_level: u8,
    bidi_override: bool,
    tab_columns: int, // 0 = ordinary item; -1 = zero-width tab
    preserved_space: bool,
    hanging_space: bool, // preserved pre-wrap spaces hang at the end of a line
    can_break:  bool, // overflow-wrap/word-break: pode quebrar dentro da palavra
    hidden:     bool, // text-overflow:ellipsis cortou este item (não pinta)
    ellipsized: bool, // pinta só text[:draw_bytes] + "…"
    draw_bytes: int,
}

Inline_Style :: struct { size: f32, weight: Font_Weight, italic: bool, color: u32, href: string, deco: Deco, lh: f32, family: Font_Family, fam_id: u8, letter_spacing: f32, ttx: Text_Transform, valign: V_Align, break_word: bool, tab_size: int, font_kerning: Font_Kerning, break_all, min_break: bool, effect: ^Inline_Effect, invisible: bool }

// ── Construção da árvore ─────────────────────────────────────────────────────

// Aloca um Box zerado mas com opacity=1.0 (padrão CSS; zero em Odin seria invisível).
@(private="file")
new_box :: proc() -> ^Box {
    b := new(Box)
    b.opacity = 1.0
    b.transform_sx = 1; b.transform_sy = 1 // escala neutra (senão do_xform escala por 0)
    return b
}

build_layout :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed, base: string) -> ^Box {
    #partial switch node.kind {
    case .Document:
        b := new_box(); b.kind = .Block
        // HTML5 sempre tem um <body> (explícito ou implícito). Quando o documento
        // não traz <body>, não existe nó com tag=="body" p/ receber a margem
        // default de 8px do body (aplicada em node_margins/inline). Recuamos o
        // próprio box do documento, deslocando o conteúdo de nível superior como
        // um body implícito. (Com <body> explícito, ele já recebe a margem.)
        if dompkg.find_first(node, "body") == nil {
            b.padding = {8 * g_zoom, 8 * g_zoom, 8 * g_zoom, 8 * g_zoom}
        }
        build_block_children(node, b, styles, base, 16, FW_NORMAL, false, DEFAULT_TEXT, .Left, Deco{}, .Normal, 1.3, .Sans, 0, 0, .None)
        return b

    case .Element:
        if l_is_skip(node.tag) do return nil
        comp := styles[node]
        if comp.display_none do return nil

        if node.tag == "img" {
            b := new_box(); b.kind = .Image; b.node = node
            apply_box(b, comp, base)
            // `data:` NÃO é excluído aqui (M192): a URI é a própria fonte, e quem a
            // decodifica é `netpkg.fetch` (net.odin, `fetch_data_uri`) — o mesmo
            // caminho de qualquer imagem. `resolve_url` já a devolve intacta de
            // propósito. Antes havia um `&& !has_prefix(src, "data:")` que a
            // descartava, e o `<img>` caía no placeholder cinza.
            // <picture>: o <source> vencedor SUBSTITUI o src do fallback, e é dele
            // que sai a proporção intrínseca até a imagem chegar (ver image_dims).
            b.img_url, b.img_src_node = image_source_for(node, base)
            b.img_deco = img_is_decorative(node)
            return b
        }

        // <svg> inline: elemento SUBSTITUÍDO (como img) — não layouta os filhos
        // gráficos como fluxo; guarda o nó p/ o paint parsear/rasterizar. currentColor
        // = a cor computada do próprio svg.
        if node.tag == "svg" {
            b := new_box(); b.kind = .Image; b.node = node
            b.is_svg = true; b.svg_fg = comp.color
            apply_box(b, comp, base)
            return b
        }

        // <canvas>: elemento SUBSTITUÍDO cujo conteúdo quem desenha é o JS
        // (getContext('2d')). Como o <svg>, os filhos NÃO são fluxo — são o
        // conteúdo de fallback. O tamanho intrínseco vem dos atributos
        // width/height (default 300×150 da spec, em image_dims).
        if node.tag == "canvas" {
            b := new_box(); b.kind = .Image; b.node = node
            b.is_canvas = true
            apply_box(b, comp, base)
            return b
        }

        // <textarea>: campo multi-linha. O conteúdo textual é o valor INICIAL (não
        // é layout de fluxo) — vira caixa própria com InputTextMultiline sobreposto.
        if node.tag == "textarea" {
            b := new_box(); b.kind = .Block; b.node = node
            apply_box(b, comp, base)
            set_textarea_control(b, node, comp)
            return b
        }

        // <select>: combobox. Como o textarea, é elemento de CONTROLE — os
        // <option>/<optgroup> NÃO entram no fluxo (antes entravam, e o select
        // virava um bloco que DESPEJAVA toda a lista como linhas de texto). A
        // caixa mostra o rótulo da opção selecionada; a lista só existe no
        // popup do paint.
        if node.tag == "select" {
            b := new_box(); b.kind = .Block; b.node = node
            apply_box(b, comp, base)
            set_select_control(b, node, comp)
            return b
        }

        b := new_box(); b.kind = .Block; b.node = node
        apply_box(b, comp, base)
        if comp.bg_img != "" do b.bg_img = netpkg.resolve_url(base, comp.bg_img, context.allocator)
        adopt_bimg(b, comp.bimg, base)
        adopt_bg_extra(b, comp, base)
        b.href = l_block_link_href(node)

        // ul/ol recebem recuo à esquerda p/ acomodar os marcadores (escala c/ zoom)
        if (node.tag == "ul" || node.tag == "ol") && b.padding[3] < 24 * g_zoom do b.padding[3] = 24 * g_zoom

        // tabela: marca p/ layout próprio — pela TAG HTML ou pelo display CSS.
        if node.tag == "table" || comp.display_table {
            b.is_table = true; b.border_collapse = comp.border_collapse
            b.table_fixed = comp.table_fixed
        }
        b.is_table_row    = comp.display_table_row    || node.tag == "tr"
        b.is_table_cell   = comp.display_table_cell   || node.tag == "td" || node.tag == "th"
        b.is_table_rowgrp = comp.display_table_rowgrp  ||
            node.tag == "thead" || node.tag == "tbody" || node.tag == "tfoot"
        b.is_caption      = node.tag == "caption"
        b.empty_cells_hide    = comp.empty_cells_hide
        b.caption_side_bottom = comp.caption_side_bottom
        // células: padding padrão p/ respiro quando o CSS não define (escala c/ zoom).
        // Só p/ <td>/<th> (o UA-stylesheet); display:table-cell em divs usa o CSS puro.
        if node.tag == "td" || node.tag == "th" {
            no_pad := b.padding[0] == 0 && b.padding[1] == 0 && b.padding[2] == 0 && b.padding[3] == 0
            if no_pad do b.padding = {3 * g_zoom, 5 * g_zoom, 3 * g_zoom, 5 * g_zoom}
        }
        // multi-coluna: só num container de BLOCO (não flex/grid/table).
        if (comp.col_count > 0 || comp.col_width > 0) && !comp.display_flex && !comp.display_grid && !b.is_table {
            b.is_multicol = true
            b.mc_count = comp.col_count
            b.mc_width = comp.col_width
            b.mc_gap = comp.col_gap >= 0 ? comp.col_gap : comp.font_size // normal ≈ 1em
        }

        eff_size  := comp.has_font_size ? comp.font_size : l_default_size(node.tag)
        // o negrito de heading agora vem do UA (apply_ua_defaults), ANTES das
        // declarações do autor — então `h3{font-weight:500}` vence, como no Chrome
        eff_weight := comp.weight
        eff_ital  := comp.italic
        // cor: autor (color próprio) vence; senão azul de link se for <a href>; senão
        // a cor HERDADA — comp.color já a carrega (compute_node faz comp := inherit).
        // Antes caíamos em DEFAULT_TEXT aqui, ignorando a herança: um bloco que só
        // herda `color` (ex.: <p>/<h2> sob `body{color:var(--light)}`) saía escuro.
        eff_color : u32 = (!comp.has_color && b.href != "") ? COL_LINK : comp.color
        // <pre> sem família explícita assume monospace (stylesheet do UA)
        eff_family := comp.font_family
        if node.tag == "pre" && eff_family == .Sans do eff_family = .Mono
        // UA defaults are already in Computed; an explicit normal must win.
        eff_ws := comp.white_space

        if comp.display_flex {
            b.is_flex = true
            build_item_children(node, b, styles, base, eff_size, eff_weight, eff_ital, eff_color, comp.text_align, deco_of(comp), eff_family, comp.font_fam_id, comp.letter_spacing, comp.text_transform, eff_ws)
        } else if comp.display_grid {
            b.is_grid = true
            build_item_children(node, b, styles, base, eff_size, eff_weight, eff_ital, eff_color, comp.text_align, deco_of(comp), eff_family, comp.font_fam_id, comp.letter_spacing, comp.text_transform, eff_ws)
        } else if comp.content_hidden {
            // content-visibility:hidden — a CAIXA existe (ao contrário de
            // display:none), mas o conteúdo não é construído nem pintado.
            // O tamanho vem de contain-intrinsic-size (aplicado acima) ou fica 0.
        } else if !b.is_table && is_inline_ctx(node, styles) {
            b.is_inline = true
            b.align = comp.text_align
            b.align_last = comp.text_align_last; b.has_align_last = comp.has_text_align_last
            // strut: caixa-linha tem no mínimo a altura da fonte PRÓPRIA do bloco ×
            // line-height (CSS §10.8), mesmo que o conteúdo seja menor (ex.: font-size:0).
            b.strut = eff_size * (comp.line_height > 0 ? comp.line_height : 1.3)
            st := Inline_Style{eff_size, eff_weight, eff_ital, eff_color, "", deco_of(comp), comp.line_height, eff_family, comp.font_fam_id, comp.letter_spacing, comp.text_transform, .Baseline, comp.break_word || comp.break_all, comp.tab_size, comp.font_kerning, comp.break_all, comp.break_all || comp.wrap_anywhere, nil, comp.invisible}
            pending, started := false, false
            build_inline_items(node, &b.inlines, styles, st, base, &pending, &started, eff_ws, root = true, grads = &b.inline_grads, owner = b)
            coalesce_words(&b.inlines)
        } else {
            build_block_children(node, b, styles, base, eff_size, eff_weight, eff_ital, eff_color, comp.text_align, deco_of(comp), eff_ws, comp.line_height, eff_family, comp.font_fam_id, comp.letter_spacing, comp.text_transform)
        }

        if node.tag == "li" do inject_list_marker(b, node, eff_size, comp.color != 0 ? comp.color : DEFAULT_TEXT, eff_family, comp.font_fam_id, comp.list_style)
        // input é void: marca checkbox/radio (desenhados no paint) e injeta o
        // rótulo textual (submit/reset/button e campos de texto).
        if node.tag == "input" {
            set_input_control(b, node)
            if b.ctrl == .Text || b.ctrl == .Password {
                b.edit_color = eff_color // cor do texto do CSS (herdada/definida)
                b.caret_color = comp.caret_color; b.has_caret = comp.has_caret
                apply_placeholder_style(b, comp)
                b.edit_font, _, b.edit_em = l_pick_font(eff_size, FW_NORMAL, comp.font_fam_id, eff_family) // fonte da página
                // altura de uma linha com a fonte REAL (pós-CSS); CSS height sobrescreve.
                // Com box-sizing:border-box a altura inclui padding+borda — soma-os,
                // senão o conteúdo colapsa a 0 (campo achatado).
                if !comp.has_height {
                    line := eff_size * 1.35
                    if b.box_sizing == .Border {
                        line += b.padding[0] + b.padding[2] + b.border_w[0] + b.border_w[2]
                    }
                    b.has_height = true; b.height = line
                }
            }
            inject_input_label(b, node, eff_size, eff_color, eff_family, comp.font_fam_id)
        }

        // pseudo-elementos ::before / ::after (gerados a partir de `content`)
        if comp.before != nil || comp.after != nil {
            // display:contents num pseudo NÃO gera caixa própria (sem borda/fundo):
            // o `content` entra no fluxo inline do elemento como se fosse filho
            // direto. Tratado ANTES da conversão p/ anon — mantém `b` inline e o
            // texto na MESMA linha (ex.: ::before "P" + "A" + ::after "S" = "PAS…").
            bc := comp.before != nil && comp.before.display_contents && b.is_inline
            ac := comp.after  != nil && comp.after.display_contents  && b.is_inline
            if bc do inject_at(&b.inlines, 0, pseudo_inline_word(comp.before^))
            if ac do append(&b.inlines, pseudo_inline_word(comp.after^))
            // pseudos com caixa própria (o caso comum): before/after que NÃO são
            // display:contents viram caixas-filhas normais.
            before_box := comp.before != nil && !bc
            after_box  := comp.after  != nil && !ac
            if before_box || after_box {
                // se o box era inline (só texto), move o texto p/ uma caixa anônima
                // e vira bloco, para conviver com os pseudos como filhos normais.
                if b.is_inline {
                    anon := new_box(); anon.kind = .Block; anon.is_inline = true; anon.align = b.align
                    anon.align_last = b.align_last; anon.has_align_last = b.has_align_last
                    anon.inlines = b.inlines
                    anon.inline_effects = b.inline_effects; b.inline_effects = nil
                    anon.invisible = b.invisible
                    b.inlines = nil
                    b.is_inline = false
                    append(&b.children, anon)
                }
                if before_box {
                    inject_at(&b.children, 0, build_pseudo_box(comp.before, base))
                }
                if after_box {
                    append(&b.children, build_pseudo_box(comp.after, base))
                }
            }
            // clearfix idiomático: um ::before com `clear` num bloco SEM BFC próprio
            // limpa os floats do BFC do PAI (o pseudo participa do fluxo do pai, não
            // dos floats internos deste bloco — que não tem). Propagamos o clear ao
            // BLOCO p/ que o loop de floats do AVÔ o posicione abaixo dos floats.
            // Ex.: sqlite `.menu::before{clear:both}` põe a nav abaixo do logo/tagline
            // (float). Só p/ bloco de fluxo normal (flex/grid/float/abs estabelecem
            // BFC próprio → o clear do pseudo seria escopado a eles).
            if b.kind == .Block && b.clear == .None && !b.is_flex && !b.is_grid && b.float == .None && b.pos == .Static {
                // só quando o ::before NÃO é float (um pseudo flutuado limpa a SI
                // mesmo, não empurra o bloco) e tem content vazio-ish (clearfix).
                if comp.before != nil && comp.before.clear != .None && comp.before.float == .None {
                    b.clear = comp.before.clear
                }
            }
        }

        // ::first-letter — v1: só o caso drop-cap (float). Extrai a 1ª letra do
        // fluxo e a transforma numa caixa flutuante estilizada (mesma estrutura
        // que um <span float:left> ao redor da letra). O caso sem-float (colorir
        // a letra inline) fica pro futuro.
        if comp.first_letter != nil && comp.first_letter.float != .None {
            // conteúdo inline direto vira caixa anônima (como before/after), p/ a
            // inicial flutuante conviver como irmã → [floatbox, anon] = igual ao ref.
            if b.is_inline {
                anon := new_box(); anon.kind = .Block; anon.is_inline = true; anon.align = b.align
                anon.align_last = b.align_last; anon.has_align_last = b.has_align_last
                anon.inlines = b.inlines
                anon.inline_effects = b.inline_effects; b.inline_effects = nil
                anon.invisible = b.invisible
                b.inlines = nil
                b.is_inline = false
                append(&b.children, anon)
            }
            inject_first_letter(b, comp.first_letter, base)
        }
        return b
    }
    return nil
}

// Extrai a primeira letra do fluxo inline de `b` e injeta uma caixa flutuante
// estilizada por ::first-letter (drop-cap). Encurta o Word original.
@(private="file")
inject_first_letter :: proc(b: ^Box, flc: ^Computed, base: string) {
    target: ^Box = nil
    wi := -1
    for c in b.children {
        for it, i in c.inlines {
            if it.kind == .Word && len(it.text) > 0 { target = c; wi = i; break }
        }
        if target != nil do break
    }
    if target == nil do return

    it := &target.inlines[wi]
    _, sz := utf8.decode_rune_in_string(it.text)
    if sz <= 0 do return
    // constrói a caixa (clona a letra internamente) ANTES de mexer em it.text
    fb := build_first_letter_box(flc, it.text[:sz], base)
    // encurta o Word original (remove a 1ª letra); it.text é owned (xform_word)
    rest := strings.clone(it.text[sz:])
    delete(it.text)
    it.text = rest

    inject_at(&b.children, 0, fb)
}

// Caixa de ::first-letter: como build_pseudo_box mas com texto explícito (a
// letra extraída) em vez de `content`.
@(private="file")
build_first_letter_box :: proc(pc: ^Computed, text: string, base: string) -> ^Box {
    pb := new_box(); pb.kind = .Block
    apply_box(pb, pc^, base)
    pb.is_inline = true
    font, scale, fem := l_pick_font(pc.font_size, pc.weight, pc.font_fam_id, pc.font_family, pc.italic)
    it := Inline_Item{
        kind = .Word, text = strings.clone(text), invisible = pc.invisible,
        font = font, fsize = pc.font_size, scale = scale, em = fem,
        color = pc.color != 0 ? pc.color : DEFAULT_TEXT,
        lh = pc.line_height > 0 ? pc.line_height : 1.3,
        letter_spacing = pc.letter_spacing, font_kerning = pc.font_kerning,
    }
    append(&pb.inlines, it)
    return pb
}

// Item inline (Word) com o `content` do pseudo, usando sua fonte/cor. Usado
// quando o pseudo é display:contents (não gera caixa própria — o texto entra
// direto no fluxo inline do elemento, na mesma linha).
@(private="file")
pseudo_inline_word :: proc(pc: Computed) -> Inline_Item {
    font, scale, fem := l_pick_font(pc.font_size, pc.weight, pc.font_fam_id, pc.font_family, pc.italic)
    return Inline_Item{
        kind = .Word, text = strings.clone(pc.content), invisible = pc.invisible,
        font = font, fsize = pc.font_size, scale = scale, em = fem,
        color = pc.color != 0 ? pc.color : DEFAULT_TEXT,
        lh = pc.line_height > 0 ? pc.line_height : 1.3,
        letter_spacing = pc.letter_spacing, font_kerning = pc.font_kerning,
    }
}

// Constrói a caixa de um pseudo-elemento ::before/::after a partir do seu estilo
// computado. Se tiver texto (content != ""), vira uma caixa inline com a palavra.
@(private="file")
build_pseudo_box :: proc(pc: ^Computed, base: string) -> ^Box {
    pb := new_box(); pb.kind = .Block
    apply_box(pb, pc^, base)
    if pc.bg_img != "" do pb.bg_img = netpkg.resolve_url(base, pc.bg_img, context.allocator)
    adopt_bimg(pb, pc.bimg, base)
    adopt_bg_extra(pb, pc^, base)
    if pc.content != "" {
        pb.is_inline = true
        font, scale, fem := l_pick_font(pc.font_size, pc.weight, pc.font_fam_id, pc.font_family, pc.italic)
        it := Inline_Item{
            kind = .Word, text = strings.clone(pc.content), invisible = pc.invisible,
            font = font, fsize = pc.font_size, scale = scale, em = fem,
            color = pc.color != 0 ? pc.color : DEFAULT_TEXT,
            lh = pc.line_height > 0 ? pc.line_height : 1.3,
            letter_spacing = pc.letter_spacing, font_kerning = pc.font_kerning,
        }
        append(&pb.inlines, it)
    }
    return pb
}

// Um filho participa do fluxo inline (átomo inline ou texto)? display:block e
// display:inline do CSS sobrepõem o padrão da tag; inline-block/img/br são
// sempre átomos inline.
@(private="file")
l_flows_inline :: proc(tag: string, cc: Computed) -> bool {
    // display:flex/grid/table são de nível BLOCO — inclusive numa tag que é inline
    // por padrão (<label>, <span>, <a>, <button>): geram caixa própria e rodam o
    // formatador interno. As variantes inline-* (display_inline_level) fluem como
    // ÁTOMO na linha, igual inline-block. Sem este caso, `<label class="flex">`
    // (padrão onipresente em Tailwind/React) virava item de texto: o formatador
    // flex nunca rodava, `gap` sumia e width/height dos filhos era ignorada.
    if cc.display_flex || cc.display_grid || cc.display_table do return cc.display_inline_level
    if cc.display_block       do return false // block forçado numa tag inline
    if cc.display_inline_block do return true // inline-block: átomo inline
    if cc.display_inline      do return true  // inline forçado numa tag de bloco
    if tag == "img" || tag == "br" || tag == "svg" do return true
    return l_is_inline(tag)
}

// Verdadeiro quando o elemento contém somente conteúdo inline (texto/inline/img/br).
// display:contents é achatado (o elemento é transparente: contam os filhos dele).
@(private="file")
is_inline_ctx :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed) -> bool {
    kids := make([dynamic]^dompkg.Node, context.temp_allocator)
    flow_children(node, styles, &kids)
    for c in kids {
        if c.kind != .Element do continue
        cc := styles[c]
        if l_is_skip(c.tag) do continue // display:none já foi filtrado por flow_children
        // um filho FLOAT não flui inline (é fora-de-fluxo): o nó NÃO é contexto
        // inline puro → vai p/ build_block_children, que posiciona o float. Sem
        // isto, build_inline_items DESCARTAVA o float (sumia sob o fundo do pai).
        if cc.float != .None do return false
        if !l_flows_inline(c.tag, cc) do return false
        // float ANINHADO num filho inline (ex.: <a><img float:left></a>): o
        // container precisa do posicionamento de float → NÃO é inline puro. Sem
        // isto, o float ficava no fluxo inline (avançava o cy) e desalinhava outros
        // floats (o logo linkado do sqlite empurrava a tagline float:right p/ baixo).
        // MAS um filho que estabelece BFC próprio (inline-block/flex/grid/table)
        // CONTÉM seu float — não conta aqui (senão o <p> vira bloco e o float do
        // inline-block vaza/acumula: cascata dos "projetos-irmãos" da wikipedia).
        if !establishes_bfc(cc) && has_float_descendant(c, styles) do return false
        // filho inline que EMBRULHA blocos (ex.: <code><span style=display:block>):
        // a caixa inline tem de ser dividida em caixas anônimas, então este nó NÃO
        // é contexto inline puro — vai p/ build_block_children, que empilha.
        if in_preformatted_ctx(c, styles) && !establishes_bfc(cc) && inline_subtree_has_block(c, styles) do return false
    }
    return true
}

// Um filho que estabelece um CONTEXTO DE FORMATAÇÃO próprio (inline-block/flex/
// grid/table) CONTÉM seus floats — eles NÃO sobem para o bloco ancestral. Sem
// parar aqui, o `float:left;margin-left:-40px` DENTRO de um `inline-block` vazava
// para o <p> e ACUMULAVA -10px por item (avanço líquido do float = -40+30) →
// cascata diagonal dos ícones dos "Projetos-irmãos" da wikipedia. O próprio
// build_layout do inline-block já haste/posiciona o float no BFC dele.
@(private="file")
establishes_bfc :: proc(cc: Computed) -> bool {
    return cc.display_inline_block || cc.display_flex || cc.display_grid || cc.display_table
}

// Há um float em algum ponto da subárvore de `node` (ex.: <a><img float:left></a>)?
// NÃO desce dentro de um float nem de um BFC próprio (os floats deles são contidos,
// não deste container). Usado p/ decidir que um container com float ANINHADO num
// filho inline é contexto de BLOCO (o float precisa ser hasteado/posicionado).
@(private="file")
has_float_descendant :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed) -> bool {
    for c in node.children {
        if c.kind != .Element do continue
        cc := styles[c]
        if cc.display_none do continue
        if cc.float != .None && cc.position != .Absolute && cc.position != .Fixed do return true
        if establishes_bfc(cc) do continue // BFC próprio: seus floats são contidos
        if has_float_descendant(c, styles) do return true
    }
    return false
}

// A subárvore INLINE de `node` contém algum elemento de nível BLOCO em fluxo?
// Desce SÓ por filhos que fluem inline (para no 1º nível de bloco) — é o espelho
// descendente do `under_inline_anchor`, que sobe.
//
// Por que existe: CSS manda dividir uma caixa inline que contenha blocos em caixas
// anônimas (CSS 2.1 §9.2.1.1). Sem isso, um elemento inline que embrulha blocos
// achatava a subárvore inteira num run de texto e TODOS os blocos saíam na MESMA
// linha. O caso real é o bloco de código de site de documentação: Shiki/Prism
// emitem `<pre><code><code><span class="line">…</span><span class="line">…` SEM
// nenhum `\n`, e é o CSS (`.line{display:block}`) que faz cada linha ser uma linha.
// O `<pre>` sozinho já funcionava (tag de bloco) — quem engolia era o `<code>`,
// que é tag INLINE; e note o `<code>` DUPLO do markup real, por isso a busca tem
// de ser recursiva e não só nos filhos diretos.
//
// ⚠️ ESCOPADO a contexto PRÉ-FORMATADO (ver `ws_preformatted`), e a razão é
// medida, não estética: aplicar a divisão em TODO contexto inline custa 3 FAILs
// nomeados no WPT — `css-cascade/all-prop-002` (o teste depende de `all:inherit`
// levar `display:inherit`, que NÃO suportamos: os `<div>` deveriam virar inline e,
// como não viram, empilham e o vermelho aparece), `css-pseudo/first-letter-
// exclude-inline-child-marker` (usa `display:inline list-item`, sintaxe de display
// de 2 palavras que não parseamos) e `css-transforms/3d-rendering-context-and-
// inline`. Os três passavam por ACHATAMENTO, não por acerto — mas trocar 1 defeito
// real por 3 regressões nomeadas é pior negócio. Contido ao `pre`, o corpus WPT
// inteiro (0 testes usam `<pre>` ou `white-space:pre`) fica intocado e o defeito
// que se vê em site real some. Quando `all:inherit` e display de 2 palavras
// existirem, dá p/ tirar o escopo e re-medir.
//
// Fora-de-fluxo (float/absolute/fixed) NÃO conta: não divide a caixa inline.
@(private="file")
inline_subtree_has_block :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed) -> bool {
    // Elemento SUBSTITUÍDO/atômico: os filhos não são caixas CSS deste fluxo (num
    // <svg> são <path>/<g>, que quem desenha é o paint_svg; em <canvas>/<video>/
    // <picture> são fallback/metadata). Descer aqui fazia todo ícone inline ser
    // lido como "contém bloco" — foi o golden svg-inline-fluxo-normal caindo.
    if l_is_atomic_content(node.tag) do return false
    for c in node.children {
        if c.kind != .Element do continue
        cc := styles[c]
        if l_is_skip(c.tag) || cc.display_none do continue
        if cc.float != .None || cc.position == .Absolute || cc.position == .Fixed do continue
        if !l_flows_inline(c.tag, cc) do return true // achou bloco em fluxo
        if establishes_bfc(cc) do continue // átomo inline (inline-block/-flex/…): contém o próprio conteúdo
        if inline_subtree_has_block(c, styles) do return true // desce só por inline
    }
    return false
}

// Preserve block boundaries under preformatted ancestors rather than flattening
// them into one line. Keep the legacy <pre> ancestry guard as well as the
// computed modes that preserve spaces and segment breaks.
@(private="file")
in_preformatted_ctx :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed) -> bool {
    for p := node; p != nil; p = p.parent {
        if p.kind != .Element do continue
        if p.tag == "pre" do return true
        if c, ok := styles[p]; ok && (c.white_space == .Pre || c.white_space == .Pre_Wrap || c.white_space == .Break_Spaces) do return true
    }
    return false
}

// Tags cujo conteúdo NÃO é fluxo CSS normal (gráfico, fallback ou metadata).
@(private="file")
l_is_atomic_content :: proc(tag: string) -> bool {
    switch tag {
    case "svg", "canvas", "video", "audio", "picture", "math", "select", "textarea":
        return true
    }
    return false
}

// Coleta os floats de topo da subárvore inline de `node` (p/ hastear ao bloco pai).
// Igual ao has_float_descendant mas acumula os NÓS; não desce dentro de float nem BFC.
@(private="file")
collect_floats :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed, out: ^[dynamic]^dompkg.Node) {
    for c in node.children {
        if c.kind != .Element do continue
        cc := styles[c]
        if cc.display_none do continue
        if cc.float != .None && cc.position != .Absolute && cc.position != .Fixed {
            append(out, c) // não desce: floats internos são BFC deste float
        } else if establishes_bfc(cc) {
            // não desce: floats internos pertencem ao BFC do próprio filho
        } else {
            collect_floats(c, styles, out)
        }
    }
}

// Filhos "de fluxo" de um nó, com display:contents ACHATADO: um elemento
// contents não gera caixa, então seus próprios filhos entram no lugar dele (recur-
// sivamente). display:none é pulado. Usado pelos construtores de bloco/flex/grid e
// pela detecção de contexto inline, p/ que o elemento contents seja transparente.
@(private="file")
flow_children :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed, out: ^[dynamic]^dompkg.Node) {
    // SHADOW DOM: um host com shadow root renderiza a ÁRVORE SOMBRA no lugar dos
    // seus filhos de luz. Os filhos de luz só aparecem se um <slot> os projetar.
    src := node
    if sr := shadow_root_child(node); sr != nil do src = sr

    // <slot>: projeta os filhos de luz do HOST que foram atribuídos a ele. Sem nós
    // atribuídos, valem os filhos do próprio <slot> (conteúdo de fallback, spec).
    if node.tag == "slot" {
        if host := slot_host(node); host != nil {
            want := node.attrs["name"] // "" = slot default
            n_assigned := 0
            for c in host.children {
                if is_pseudo_node(c) do continue
                got := ""
                if c.kind == .Element do got = c.attrs["slot"]
                if got != want do continue
                if c.kind == .Element {
                    cc := styles[c]
                    if cc.display_none do continue
                    if cc.display_contents { flow_children(c, styles, out); n_assigned += 1; continue }
                }
                append(out, c)
                n_assigned += 1
            }
            if n_assigned > 0 do return // houve projeção: o fallback não entra
        }
    }

    for c in src.children {
        if is_pseudo_node(c) do continue // #shadow/#content nunca entram no fluxo
        if c.kind == .Element {
            cc := styles[c]
            if cc.display_none do continue
            // <slot> é `display:contents` por padrão no UA-stylesheet: ele não gera
            // caixa, só projeta. Achatar aqui evita um bloco extra que quebraria
            // flex/grid do componente.
            if cc.display_contents || c.tag == "slot" {
                flow_children(c, styles, out)
                continue
            }
        }
        append(out, c)
    }
}

// Nós de estrutura que não fazem parte do fluxo: a shadow root e o document-fragment
// de <template>. Ver [[js-engine-roadmap]] M129.
is_pseudo_node :: proc(n: ^dompkg.Node) -> bool {
    return n != nil && (n.tag == "#shadow" || n.tag == "#content")
}

shadow_root_child :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    if n == nil do return nil
    for c in n.children {
        if c.tag == "#shadow" do return c
    }
    return nil
}

// O host de um <slot>: sobe até a #shadow que o contém; o pai dela é o host.
@(private = "file")
slot_host :: proc(slot: ^dompkg.Node) -> ^dompkg.Node {
    for a := slot.parent; a != nil; a = a.parent {
        if a.tag == "#shadow" do return a.parent
    }
    return nil
}

// Dois Words ADJACENTES (sem whitespace entre eles) e de estilo IDÊNTICO podem
// ser fundidos num só. Isso reproduz uma única "caixa decoradora" e — crucial —
// um único AddText: o ImGui ancora a caneta de cada AddText no pixel, então
// `foo<span>bar</span>baz` (3 chamadas) desloca "barbaz" em sub-pixel vs. o
// "foobarbaz" de uma chamada só. Fundir elimina o desvio e torna underline
// pontilhado/tracejado contínuo através das fronteiras de <span>.
@(private="file")
words_mergeable :: proc(a, b: ^Inline_Item) -> bool {
    return a.kind == .Word && b.kind == .Word &&
        !b.space_before &&                          // sem espaço colapsável entre eles
        a.effect == b.effect && a.invisible == b.invisible &&
        a.href == "" && b.href == "" &&             // não funde links (hit-test por palavra)
        a.hov_grp == b.hov_grp &&                   // nem palavras de elementos :hover distintos
                                                    // (fundir moveria a região de hover)
        b.pad_before == 0 && a.pad_after == 0 &&    // sem margem/padding/borda inline no meio
        a.font == b.font && a.fsize == b.fsize && a.scale == b.scale &&
        a.color == b.color && a.lh == b.lh &&
        a.letter_spacing == b.letter_spacing && a.font_kerning == b.font_kerning && a.valign == b.valign &&
        a.nowrap == b.nowrap && a.can_break == b.can_break &&
        a.break_all == b.break_all && a.min_break == b.min_break &&
        !a.preserved_space && !b.preserved_space && a.deco == b.deco
}

// Compacta a lista fundindo Words adjacentes de mesmo estilo (ver words_mergeable).
// Chamado logo após a construção dos itens, ANTES da medição/quebra de linha.
@(private="file")
coalesce_words :: proc(items: ^[dynamic]Inline_Item) {
    if len(items) < 2 do return
    w := 0
    for r := 0; r < len(items); r += 1 {
        cur := items[r]
        if w > 0 && words_mergeable(&items[w - 1], &cur) {
            a := &items[w - 1]
            if a.source!=nil && cur.source!=nil {
                source:=new(Inline_Source)
                source^={left=a.source,right=cur.source,length=len(a.text)+len(cur.text),owner=a.source.owner}
                append(&source.owner.inline_sources,source)
                a.source=source
            }
            merged := strings.concatenate({a.text, cur.text})
            delete(a.text); delete(cur.text)
            a.text = merged
            a.text_w = 0          // força remedição do texto combinado
            a.pad_after = cur.pad_after
            continue              // não avança w: cur foi absorvido
        }
        items[w] = cur
        w += 1
    }
    resize(items, w)
}

// Contexto de bloco: agrupa runs inline em caixas anônimas e blocos em caixas próprias.
@(private="file")
build_block_children :: proc(node: ^dompkg.Node, b: ^Box, styles: map[^dompkg.Node]Computed, base: string, size: f32, weight: Font_Weight, italic: bool, color: u32, align: Text_Align, deco: Deco, ws: White_Space, lh: f32, family: Font_Family, fam_id: u8, ls: f32, ttx: Text_Transform) {
    run: [dynamic]^dompkg.Node
    defer delete(run)

    flush :: proc(b: ^Box, run: ^[dynamic]^dompkg.Node, styles: map[^dompkg.Node]Computed, base: string, size: f32, weight: Font_Weight, italic: bool, color: u32, align: Text_Align, deco: Deco, ws: White_Space, lh: f32, family: Font_Family, fam_id: u8, ls: f32, ttx: Text_Transform) {
        if len(run) == 0 do return
        ibox := new_box(); ibox.kind = .Block; ibox.is_inline = true; ibox.align = align; ibox.invisible = b.invisible
        ibox.direction = b.direction; ibox.writing_mode=b.writing_mode; ibox.text_orientation=b.text_orientation; ibox.text_indent = b.text_indent; ibox.text_indent_pct = b.text_indent_pct
        ibox.indent_each_line = b.indent_each_line; ibox.indent_hanging = b.indent_hanging
        ibox.align_last = b.align_last; ibox.has_align_last = b.has_align_last
        st := Inline_Style{size, weight, italic, color, "", deco, lh, family, fam_id, ls, ttx, .Baseline, b.break_word, 0, b.font_kerning, b.break_all, b.min_break, nil, b.invisible}
        pending, started := false, false
        for inode in run do build_inline_items(inode, &ibox.inlines, styles, st, base, &pending, &started, ws, grads = &ibox.inline_grads, owner = ibox)
        coalesce_words(&ibox.inlines)
        if len(ibox.inlines) > 0 || len(ibox.children) > 0 {
            append(&b.children, ibox)
        } else {
            free_layout(ibox)
        }
        clear(run)
    }

    kids := make([dynamic]^dompkg.Node, context.temp_allocator) // display:contents achatado
    flow_children(node, styles, &kids)
    for c in kids {
        #partial switch c.kind {
        case .Text:
            append(&run, c)
        case .Element:
            cc := styles[c]
            if l_is_skip(c.tag) || cc.display_none do continue
            // float ou position:absolute/fixed tiram do fluxo inline: viram
            // caixa fora-de-fluxo (mesmo sendo inline por tag, ex.: <span>).
            out_of_flow := cc.position == .Absolute || cc.position == .Fixed
            // Um filho inline que EMBRULHA blocos não entra no run: vira caixa
            // própria (build_layout → build_block_children empilha os blocos de
            // dentro). É a divisão em caixas anônimas do CSS 2.1 §9.2.1.1, e sem
            // ela todo o `<code>` de um bloco de código saía numa linha só.
            inline_child := !out_of_flow && cc.float == .None && l_flows_inline(c.tag, cc) &&
                            !(in_preformatted_ctx(c, styles) && !establishes_bfc(cc) && inline_subtree_has_block(c, styles))
            if inline_child {
                // HASTEIA floats aninhados neste filho inline (ex.: <a><img float></a>):
                // navegadores tiram o float do fluxo inline e o posicionam no BFC do
                // bloco. Fecha o run pendente ANTES (preserva a ordem: conteúdo inline
                // anterior vem antes do float), constrói cada float como caixa própria
                // e a anexa; build_inline_items PULA esses nós (não os layouta inline).
                floats := make([dynamic]^dompkg.Node, context.temp_allocator)
                if !establishes_bfc(cc) do collect_floats(c, styles, &floats) // BFC próprio contém seus floats
                if len(floats) > 0 {
                    flush(b, &run, styles, base, size, weight, italic, color, align, deco, ws, lh, family, fam_id, ls, ttx)
                    for fnode in floats {
                        if fb := build_layout(fnode, styles, base); fb != nil do append(&b.children, fb)
                    }
                }
                append(&run, c)
            } else {
                flush(b, &run, styles, base, size, weight, italic, color, align, deco, ws, lh, family, fam_id, ls, ttx)
                if cb := build_layout(c, styles, base); cb != nil do append(&b.children, cb)
            }
        }
    }
    flush(b, &run, styles, base, size, weight, italic, color, align, deco, ws, lh, family, fam_id, ls, ttx)
}

// Filhos de um container flex/grid: cada ELEMENTO vira um item próprio (mesmo
// inline, ex.: cada <a> de uma navbar); texto solto contíguo vira item anônimo.
// ⚠️ `ws` é PARÂMETRO pela mesma razão que em build_block_children: texto solto
// dentro de um container flex/grid vira uma caixa anônima, e ela herda o
// `white-space` do container. Aqui estava `.Normal` FIXO — então
// `<button style="display:flex; white-space:nowrap">Open Source</button>` deixava
// os itens inline sem `nowrap`, o min-content quebrava no espaço e o item flex
// encolhia até caber só "Source". Era a nav do github.com espremida, com o texto
// de um item vazando por cima do próximo. Com `<span>` em volta do texto o bug
// sumia (o span tem Computed próprio, com o nowrap herdado) — foi essa assimetria
// que localizou a linha.
@(private="file")
build_item_children :: proc(node: ^dompkg.Node, b: ^Box, styles: map[^dompkg.Node]Computed, base: string, size: f32, weight: Font_Weight, italic: bool, color: u32, align: Text_Align, deco: Deco, family: Font_Family, fam_id: u8, ls: f32, ttx: Text_Transform, ws: White_Space) {
    run: [dynamic]^dompkg.Node
    defer delete(run)

    flush :: proc(b: ^Box, run: ^[dynamic]^dompkg.Node, styles: map[^dompkg.Node]Computed, base: string, size: f32, weight: Font_Weight, italic: bool, color: u32, align: Text_Align, deco: Deco, family: Font_Family, fam_id: u8, ls: f32, ttx: Text_Transform, ws: White_Space) {
        if len(run) == 0 do return
        ibox := new_box(); ibox.kind = .Block; ibox.is_inline = true; ibox.align = align; ibox.invisible = b.invisible
        ibox.direction = b.direction; ibox.writing_mode=b.writing_mode; ibox.text_orientation=b.text_orientation; ibox.text_indent = b.text_indent; ibox.text_indent_pct = b.text_indent_pct
        ibox.indent_each_line = b.indent_each_line; ibox.indent_hanging = b.indent_hanging
        ibox.align_last = b.align_last; ibox.has_align_last = b.has_align_last
        st := Inline_Style{size, weight, italic, color, "", deco, 1.3, family, fam_id, ls, ttx, .Baseline, b.break_word, 0, b.font_kerning, b.break_all, b.min_break, nil, b.invisible}
        pending, started := false, false
        for inode in run do build_inline_items(inode, &ibox.inlines, styles, st, base, &pending, &started, ws, grads = &ibox.inline_grads, owner = ibox)
        coalesce_words(&ibox.inlines)
        if len(ibox.inlines) > 0 || len(ibox.children) > 0 do append(&b.children, ibox)
        else                     do free_layout(ibox)
        clear(run)
    }

    kids := make([dynamic]^dompkg.Node, context.temp_allocator) // display:contents achatado
    flow_children(node, styles, &kids)
    for c in kids {
        #partial switch c.kind {
        case .Text:
            append(&run, c)
        case .Element:
            cc := styles[c]
            if l_is_skip(c.tag) || cc.display_none do continue
            flush(b, &run, styles, base, size, weight, italic, color, align, deco, family, fam_id, ls, ttx, ws)
            if cb := build_layout(c, styles, base); cb != nil {
                cb.stacking_item = (b.is_flex || b.is_grid) && cb.pos != .Absolute && cb.pos != .Fixed
                append(&b.children, cb)
            }
        }
    }
    flush(b, &run, styles, base, size, weight, italic, color, align, deco, family, fam_id, ls, ttx, ws)
}

// Profundidade de aninhamento de <q> (nº de ancestrais <q>). open-quote e
// close-quote do MESMO <q> usam este nível → sem estado global.
@(private="file")
q_depth :: proc(node: ^dompkg.Node) -> int {
    d := 0
    for p := node.parent; p != nil; p = p.parent {
        if p.kind == .Element && p.tag == "q" do d += 1
    }
    return d
}

// Um bloco no fluxo inline está sob um <a> (link)? Sobe a cadeia de ancestrais
// enquanto forem tags inline; para no 1º ancestral de bloco. Usado p/ escopar o
// tratamento block-in-inline ao padrão real-world (<a><div>…</div></a>).
@(private="file")
under_inline_anchor :: proc(node: ^dompkg.Node) -> bool {
    p := node.parent
    for p != nil {
        if p.tag == "a" do return true
        if !l_is_inline(p.tag) do return false // saiu do contexto inline
        p = p.parent
    }
    return false
}

// Empty positioned inlines need an anchor even when all their children are out of flow.
@(private="file")
inline_flow_presence :: proc(node: ^dompkg.Node, styles: map[^dompkg.Node]Computed) -> (flow, positioned: bool) {
    kids := make([dynamic]^dompkg.Node, context.temp_allocator)
    flow_children(node, styles, &kids)
    if c, ok := &styles[node]; ok {
        flow = (c.before != nil && c.before.has_content) || (c.after != nil && c.after.has_content)
    }
    for child in kids {
        if child.kind == .Text {
            if strings.trim_space(child.text) != "" do flow = true
            continue
        }
        if child.kind != .Element || l_is_skip(child.tag) do continue
        c, ok := &styles[child]
        if !ok || c.display_none do continue
        if c.position == .Absolute || c.position == .Fixed { positioned = true; continue }
        if child.tag == "br" || child.tag == "img" || child.tag == "svg" ||
           c.display_inline_block || c.display_inline_level || !l_flows_inline(child.tag, c^) {
            flow = true
        }
        f, p := inline_flow_presence(child, styles)
        flow = flow || f; positioned = positioned || p
    }
    return
}

// Generated inline content must keep its own style and geometric boxes.
@(private="file")
build_inline_pseudo :: proc(pc: ^Computed, items: ^[dynamic]Inline_Item, st: Inline_Style,
                            base: string, pending, started: ^bool, ws: White_Space, owner: ^Box) {
    if pc.display_none do return
    positioned := pc.position == .Absolute || pc.position == .Fixed
    boxed := !pc.display_contents && (positioned || pc.display_inline_block || pc.display_block ||
        pc.has_width || pc.has_height || pc.has_bg || pc.has_border || pc.bg_img != "" ||
        pc.has_transform || pc.opacity != 1)
    if boxed {
        pb := build_pseudo_box(pc, base)
        if positioned && owner != nil {
            pb.inline_parent_effect = st.effect
            append(&owner.children, pb)
            if st.effect != nil {
                append(&st.effect.absolutes, pb)
                append(items, Inline_Item{kind = .InlineBox, effect = st.effect})
            }
        } else {
            append(items, Inline_Item{kind = .InlineBox, box = pb, effect = st.effect,
                valign = pc.valign, nowrap = ws == .Pre || ws == .Nowrap,
                space_before = pending^ && started^})
            started^ = true; pending^ = false
        }
        return
    }
    ps := st
    ps.size = pc.font_size; ps.weight = pc.weight; ps.italic = pc.italic
    ps.family = pc.font_family; ps.fam_id = pc.font_fam_id; ps.color = pc.color
    ps.invisible = pc.invisible; ps.lh = pc.line_height
    ps.letter_spacing = pc.letter_spacing; ps.font_kerning = pc.font_kerning
    ps.ttx = pc.text_transform
    add_words(items, pc.content, ps, pending, started, pc.white_space)
}

// Flatten inline content into words without losing paint scopes or out-of-flow boxes.
@(private="file")
build_inline_items :: proc(node: ^dompkg.Node, items: ^[dynamic]Inline_Item, styles: map[^dompkg.Node]Computed, st: Inline_Style, base: string, pending, started: ^bool, ws: White_Space, root := false, grads: ^[dynamic]Inline_Grad = nil, owner: ^Box = nil) {
    first:=len(items)
    defer if owner!=nil {
        for i in first..<len(items) {
            if items[i].source!=nil do continue
            source:=new(Inline_Source)
            source^={node=node,length=len(items[i].text),owner=owner}
            append(&owner.inline_sources,source)
            items[i].source=source
        }
    }
    #partial switch node.kind {
    case .Text:
        add_words(items, node.text, st, pending, started, ws)
    case .Element:
        // pula elementos sem render (style/script/head/svg…) e display:none —
        // senão o texto cru deles (ex.: CSS de <style> TemplateStyles embutido
        // num <span> inline) vaza como palavras no fluxo. Os contextos de bloco
        // já filtram; aqui é o filtro do contexto inline. `root` nunca é skip/none.
        if l_is_skip(node.tag) do return
        if comp, ok := &styles[node]; ok && comp.display_none && !root do return
        if comp, ok := &styles[node]; ok && !root && owner != nil &&
           (comp.position == .Absolute || comp.position == .Fixed) {
            if cb := build_layout(node, styles, base); cb != nil {
                cb.inline_parent_effect = st.effect
                append(&owner.children, cb)
                if st.effect != nil {
                    append(&st.effect.absolutes, cb)
                    // A zero-width paint anchor keeps an otherwise empty opacity
                    // scope alive without contributing a word or line break.
                    append(items, Inline_Item{kind = .InlineBox, effect = st.effect})
                }
            }
            return
        }
        // float: NÃO é conteúdo inline — o bloco pai o hasteia e posiciona (ver
        // collect_floats/build_block_children). Pular aqui evita laytá-lo no fluxo
        // (o que avançava o cy e desalinhava). `root` = este nó É o float sendo
        // construído por build_layout → não pular (senão a caixa ficaria vazia).
        if comp, ok := &styles[node]; ok && comp.float != .None && !root do return
        // display:inline-block: constrói uma caixa própria (bg/borda/padding/
        // width/height) que flui na linha como um item atômico (feito antes de
        // achatar o conteúdo, senão o span viraria texto solto). `root` = este nó
        // é o próprio inline-block que build_layout está montando → NÃO recursar
        // (senão build_layout→build_inline_items→build_layout… = stack overflow).
        // (idem p/ inline-flex/inline-grid/inline-table: `display_inline_level`
        // é átomo inline COM formatador próprio dentro — a caixa é construída por
        // build_layout, que já liga is_flex/is_grid/is_table.)
        if comp, ok := &styles[node]; ok && (comp.display_inline_block || comp.display_inline_level) && !root {
            if cb := build_layout(node, styles, base); cb != nil {
                append(items, Inline_Item{kind = .InlineBox, box = cb, effect = st.effect, valign = comp.valign, nowrap = ws == .Pre || ws == .Nowrap, space_before = pending^ && started^})
                started^ = true; pending^ = false
            }
            return
        }
        // block-in-inline: um filho de BLOCO dentro de um contexto inline (o pai
        // agrupou este ramo como run inline por ser tag inline). O modelo CSS
        // quebraria o inline em caixas anônimas; aproximamos tratando o bloco como
        // um ÁTOMO inline (InlineBox), preservando seu tamanho/background em vez de
        // descartá-lo (o div vazio sumia: build_inline_items só criava caixa p/
        // inline-block/img/br/texto). ESCOPADO ao padrão real: um bloco sob um <a>
        // (link), ex.: HN <a><div class=votearrow></div></a> ou cards clicáveis.
        // Fora disso (div display:inline com filho bloco, li com inline-list-item)
        // mantemos o comportamento antigo — atomizar aqueles casos exóticos regride
        // reftests de 3D-rendering-context e de ::first-letter+::marker que só
        // "passavam" porque a caixa era descartada. `!has_transform`: defesa extra
        // (um bloco 3D-transformado sob link seria mostrado sem a rotação).
        if comp, ok := &styles[node]; ok && !root && comp.float == .None && !comp.has_transform && !l_flows_inline(node.tag, comp^) && under_inline_anchor(node) {
            if cb := build_layout(node, styles, base); cb != nil {
                append(items, Inline_Item{kind = .InlineBox, box = cb, effect = st.effect, valign = comp.valign, nowrap = ws == .Pre || ws == .Nowrap, space_before = pending^ && started^})
                started^ = true; pending^ = false
            }
            return
        }
        // An empty positioned inline still establishes an absolute containing
        // block. Keep a zero-size anchor at the top of its line; this does not
        // atomize spans containing flowing text or change their wrapping.
        if comp, ok := &styles[node]; ok && !root && comp.position == .Relative && l_flows_inline(node.tag, comp^) {
            flow, positioned := inline_flow_presence(node, styles)
            if !flow && positioned {
                if cb := build_layout(node, styles, base); cb != nil {
                    append(items, Inline_Item{kind = .InlineBox, box = cb, effect = st.effect,
                        valign = .Top, nowrap = ws == .Pre || ws == .Nowrap})
                }
                return
            }
        }
        // Preserve an otherwise empty block wrapper around positioned children.
        // Flattening this wrapper would lose its margins and the static position.
        if comp, ok := &styles[node]; ok && !root && comp.float == .None &&
           !comp.has_transform && !l_flows_inline(node.tag, comp^) {
            flow, positioned := inline_flow_presence(node, styles)
            if !flow && positioned {
                if cb := build_layout(node, styles, base); cb != nil {
                    append(items, Inline_Item{kind = .InlineBox, box = cb, effect = st.effect, valign = .Top})
                }
                return
            }
        }
        // <svg> INLINE em fluxo de texto: sem isto o ícone SUMIA por completo.
        // `l_flows_inline` já dizia que <svg> flui inline, mas NÃO havia caso p/ ele
        // aqui — o walk descia nos <path> (que não têm texto) e nada era emitido.
        // Só aparecia quando algum ancestral era flex/grid (aí vira ITEM, com Box
        // próprio). Vira ÁTOMO inline com a caixa do próprio <svg>, que já sabe se
        // dimensionar (width/height do CSS, atributos, ou razão do viewBox).
        if node.tag == "svg" {
            if cb := build_layout(node, styles, base); cb != nil {
                va := V_Align.Baseline
                if comp, ok := &styles[node]; ok do va = comp.valign
                append(items, Inline_Item{kind = .InlineBox, box = cb, effect = st.effect, valign = va, nowrap = ws == .Pre || ws == .Nowrap, space_before = pending^ && started^})
                started^ = true; pending^ = false
            }
            return
        }
        inline_st := st
        if comp, ok := &styles[node]; ok {
            inline_st.invisible = comp.invisible
            if !root && owner != nil && (comp.opacity != 1 || comp.hover.has_opacity) {
                effect := new(Inline_Effect)
                effect^ = Inline_Effect{parent = st.effect, opacity = comp.opacity,
                    hover_opacity = comp.hover.opacity, has_hover = comp.hover.has_opacity,
                    node = node}
                append(&owner.inline_effects, effect)
                inline_st.effect = effect
            }
        }
        if node.tag == "img" {
            it := Inline_Item{kind = .Image, effect = inline_st.effect, invisible = inline_st.invisible, nowrap = ws == .Pre || ws == .Nowrap, space_before = pending^ && started^, img_pos_x = 0.5, img_pos_y = 0.5}
            if comp, ok := &styles[node]; ok {
                it.valign = comp.valign
                it.img_radius = comp.border_radius; it.img_radius_pct = comp.border_radius_pct
                it.img_fit = comp.obj_fit; it.img_pos_x = comp.obj_pos_x; it.img_pos_y = comp.obj_pos_y
                // width/height do CSS dimensionam o replaced inline (senão usa o
                // intrínseco — comum: logos sized por CSS que ficariam gigantes).
                if comp.has_width  && !comp.width_pct do it.req_w = comp.width
                if comp.has_height                    do it.req_h = comp.height
            }
            // atributos HTML width/height como fallback (sem CSS)
            if it.req_w == 0 { if v := attr_num(node, "width");  v > 0 do it.req_w = v }
            if it.req_h == 0 { if v := attr_num(node, "height"); v > 0 do it.req_h = v }
            // idem ao <img> de bloco: `data:` segue pelo caminho normal (M192)
            it.img_url, _ = image_source_for(node, base)
            it.img_deco = img_is_decorative(node)
            append(items, it)
            started^ = true; pending^ = false
            return
        }
        if node.tag == "br" {
            append(items, Inline_Item{kind = .Break, fsize = st.size, lh = st.lh})
            started^ = false; pending^ = false // apara espaço no início da nova linha
            return
        }
        s2 := inline_st
        ws2 := ws
        // estilo COMPUTADO do próprio elemento inline: color/font-family só quando
        // explicitamente definidos (senão herda — preserva cor de link e mono do
        // <pre>); text-transform/letter-spacing/font-size/decorações herdam direto.
        if comp, ok := &styles[node]; ok {
            ws2 = comp.white_space // já veio herdado do compute_styles
            if comp.has_color       do s2.color  = comp.color
            if comp.has_font_family { s2.family = comp.font_family; s2.fam_id = comp.font_fam_id }
            s2.ttx            = comp.text_transform
            s2.letter_spacing = comp.letter_spacing; s2.font_kerning = comp.font_kerning
            s2.tab_size       = comp.tab_size // tab-size herda/redefine no aninhado
            if comp.has_font_size do s2.size = comp.font_size
            s2.break_word = comp.break_word || comp.break_all
            s2.break_all = comp.break_all; s2.min_break = comp.break_all || comp.wrap_anywhere
            s2.weight = comp.weight
            s2.italic = comp.italic
            // Decoração PROPAGA da caixa decoradora p/ os descendentes: o filho
            // acumula (OR) sobre o que já herdou no run — `text-decoration:none`
            // num descendente NÃO apaga a linha de um ancestral (CSS Text Decor §2).
            if comp.underline do s2.deco.underline = true
            if comp.overline  do s2.deco.overline  = true
            if comp.strike    do s2.deco.strike    = true
            if comp.deco_color != DECO_UNSET do s2.deco.color = comp.deco_color
            s2.deco.style = comp.deco_style
            if comp.deco_thick != 0 do s2.deco.thick = comp.deco_thick
            s2.valign = comp.valign // vertical-align do próprio inline (não herda)
        }
        // em/i/cite/dfn/var NÃO entram aqui: o itálico deles vem do default do
        // UA em compute_styles (comp.italic acima) — forçar pela tag ignoraria
        // um font-style:normal do autor.
        switch node.tag {
        case "u", "ins":               s2.deco.underline = true
        case "s", "del", "strike":     s2.deco.strike = true
        case "code", "kbd", "samp", "tt": if s2.family == .Sans do s2.family = .Mono
        }
        if node.tag == "a" {
            if h, ok := node.attrs["href"]; ok && h != "" {
                s2.href = h
                // Defaults do UA-stylesheet para links, mas o AUTOR sobrepõe:
                //   cor de link só quando o autor não definiu `color` no link;
                //   sublinhado só quando o autor não definiu `text-decoration`.
                lc := &styles[node]
                if !lc.has_color do s2.color = COL_LINK
                if !lc.deco_set  do s2.deco.underline = true
            }
        }
        // ::before de um elemento INLINE achatado no run (ex.: `span::before{content:
        // counter(c)}` num <span> vazio). Elementos de bloco/inline-block já injetam
        // os pseudos em build_layout; aqui é o caso inline puro. `root` = já tratado.
        if !root {
            if pc, ok := &styles[node]; ok && pc.before != nil && pc.before.has_content {
                build_inline_pseudo(pc.before, items, s2, base, pending, started, ws2, owner)
            }
        }
        // <q>: aspas geradas (UA `q::before{content:open-quote}` / `::after{close-quote}`).
        // Profundidade = nº de <q> ancestrais; marca vem de `quotes` ou default por idioma.
        q_lvl := node.tag == "q" ? q_depth(node) : -1
        if q_lvl >= 0 {
            if qc, ok := &styles[node]; ok {
                if m := quote_mark(qc.quotes_raw, qc.lang, q_lvl, true); m != "" {
                    add_words(items, m, s2, pending, started, ws2)
                }
            }
        }
        start_idx := len(items)
        // flow_children (não node.children): é ele que resolve shadow root e <slot>.
        // Sem isto o conteúdo projetado só aparecia quando o componente caía no
        // caminho de BLOCO — um <slot> cercado de texto ficava no fallback.
        ikids := make([dynamic]^dompkg.Node, context.temp_allocator)
        flow_children(node, styles, &ikids)
        for c in ikids do build_inline_items(c, items, styles, s2, base, pending, started, ws2, grads = grads, owner = owner)
        // Keep empty inline boxes in the provenance tree. A zero-length word can
        // coalesce with its neighbours without interrupting shaping or wrapping.
        if !root && len(items)==first {
            if ec,ok:=styles[node]; ok && !ec.display_contents && l_flows_inline(node.tag,ec) {
                add_words(items,"",s2,pending,started,ws2,emit_empty=true)
            }
        }
        if bc,ok:=styles[node]; ok {
            for k in start_idx..<len(items^) do if !items[k].orientation_set { items[k].orientation=bc.text_orientation; items[k].orientation_set=true }
        }
        // Todos os itens deste <a> (palavras próprias e as de elementos aninhados)
        // ganham o MESMO grupo: o realce de hover vale o link INTEIRO, não só a
        // palavra sob o cursor. Mesmo esquema do `ibg_grp` — o guarda `== 0` faz o
        // <a> mais INTERNO vencer se houver aninhamento (HTML inválido, mas o
        // parser pode produzir). Vale também com `root` (o <a> é o container).
        if node.tag == "a" && s2.href != "" && len(items) > start_idx {
            lgrp := u32(start_idx) + 1
            for k in start_idx ..< len(items) do if items[k].link_grp == 0 do items[k].link_grp = lgrp
        }
        // `:hover` do AUTOR que muda a text-decoration num elemento INLINE. Mesmo
        // agrupamento: a região de hover é o ELEMENTO, e a decoração-alvo viaja no
        // item porque quem pinta a linha é o item, não a caixa.
        if hv, ok := &styles[node]; ok && hv.hover.active && hv.hover.has_deco && len(items) > start_idx {
            hd := hv.hover.deco
            // O sublinhado de link nasce aqui (`!deco_set` logo acima), então o
            // estado :hover precisa do MESMO default: `a:hover{color:red}` não
            // pode apagar a linha do link só por ter uma regra de hover.
            if node.tag == "a" && s2.href != "" && !hv.hover.deco_set do hd.underline = true
            // linha de ANCESTRAL não se apaga (CSS Text Decor §2): o que o
            // elemento herdou no run continua valendo sob o mouse. Só quando o
            // elemento é ANINHADO — em `root` o `st` é a decoração do PRÓPRIO
            // elemento, e ORar ela desfaria um `:hover{text-decoration:none}`.
            if !root {
                hd.underline |= st.deco.underline
                hd.overline  |= st.deco.overline
                hd.strike    |= st.deco.strike
            }
            hgrp := u32(start_idx) + 1
            for k in start_idx ..< len(items) {
                if items[k].hov_grp != 0 do continue // o elemento mais INTERNO vence
                items[k].hov_grp = hgrp; items[k].hov_deco = hd
            }
        }
        if !root {
            if bc,ok:=styles[node]; ok && bc.unicode_bidi!=.Normal {
                for k in start_idx..<len(items^) {
                    it:= &items[k]
                    if int(it.bidi_scope_n)<len(it.bidi_scopes) {
                        for q:=int(it.bidi_scope_n);q>0;q-=1 do it.bidi_scopes[q]=it.bidi_scopes[q-1]
                        it.bidi_scopes[0]=Bidi_Scope{node,bc.unicode_bidi,bc.direction}; it.bidi_scope_n+=1
                    }
                }
            }
        }
        // margem/padding/borda HORIZONTAL de um elemento inline (ex.: nav a{margin-right}
        // ou um badge com padding-x): avanço extra antes do 1º e depois do último item
        // do elemento. Vertical não se aplica a inline NÃO-substituído. `root` = o
        // próprio container. ⚠️ ÁTOMO inline (inline-block/inline-flex/svg) NÃO passa
        // por aqui — os ramos acima dão `return`; a margem dele, nos QUATRO lados, é
        // tratada no case .InlineBox do layout da linha (CSS 2.1 §10.8.1).
        if !root && len(items) > start_idx {
            if lc, ok := &styles[node]; ok {
                left  := lc.margin[3] + lc.padding[3] + lc.border_w[3]
                right := lc.margin[1] + lc.padding[1] + lc.border_w[1]
                if left  != 0 do items[start_idx].pad_before += left
                if right != 0 do items[len(items) - 1].pad_after += right
                // Fundo/borda de um elemento inline (não bloco): pinta uma caixa
                // atrás do run (ex.: <a class=button>). Marca os itens do elemento
                // que ainda não pertencem a um filho aninhado (igrp==0 → o mais
                // interno vence). Ignora display:none (não chega aqui) e replaced.
                bw_top := lc.border_w[0]
                has_border := (bw_top + lc.border_w[1] + lc.border_w[2] + lc.border_w[3]) > 0 && !lc.border_style_none[0]
                // `background-clip:text` num elemento INLINE (o `<span class=gradient-text>`)
                // reusa o MESMO agrupamento: o run de palavras do span vira um grupo,
                // e o gradiente vai p/ a lista fora-de-linha da caixa que possui os
                // itens. Sem isto o span não tinha como ser identificado no paint (os
                // itens são do BLOCO) e o texto saía na cor sólida de fallback.
                grad_txt := lc.grad_clip_text && lc.grad.active && grads != nil
                if lc.has_bg || has_border || grad_txt {
                    grp := u32(start_idx) + 1
                    for k in start_idx ..< len(items) {
                        if items[k].ibg_grp != 0 do continue // um filho aninhado já pegou
                        items[k].ibg_grp = grp
                        items[k].ibg_invisible = lc.invisible
                        items[k].ibg_has = lc.has_bg
                        items[k].ibg  = lc.has_bg ? lc.bg : 0
                        items[k].ibd  = lc.border_c[0]
                        items[k].ibw  = has_border ? bw_top : 0
                        items[k].irad = lc.border_radius[0]
                        items[k].ipt  = lc.padding[0] + lc.border_w[0]
                        items[k].ipb  = lc.padding[2] + lc.border_w[2]
                    }
                    if lc.has_bg || has_border {
                        // inset horizontal só nas pontas do elemento (exclui margin).
                        items[start_idx].ibl     = lc.padding[3] + lc.border_w[3]
                        items[len(items) - 1].ibr = lc.padding[1] + lc.border_w[1]
                    }
                    if grad_txt do append(grads, Inline_Grad{grp, lc.grad})
                }
            }
        }
        if q_lvl >= 0 {
            if qc, ok := &styles[node]; ok {
                if m := quote_mark(qc.quotes_raw, qc.lang, q_lvl, false); m != "" {
                    add_words(items, m, s2, pending, started, ws2)
                }
            }
        }
        // ::after de um elemento inline achatado no run (ver ::before acima).
        if !root {
            if pc, ok := &styles[node]; ok && pc.after != nil && pc.after.has_content {
                build_inline_pseudo(pc.after, items, s2, base, pending, started, ws2, owner)
            }
        }
    }
}

// Aplica text-transform a uma palavra, devolvendo string própria (context.allocator,
// igual ao strings.clone que substitui). Capitalize = 1ª letra da palavra.
@(private="file")
xform_word :: proc(s: string, tt: Text_Transform) -> string {
    switch tt {
    case .Upper: return strings.to_upper(s)
    case .Lower: return strings.to_lower(s)
    case .Capitalize:
        if s == "" do return strings.clone(s)
        _, sz := utf8.decode_rune_in_string(s)
        head := strings.to_upper(s[:sz])
        out  := strings.concatenate({head, s[sz:]})
        delete(head)
        return out
    case .None:
        return strings.clone(s)
    }
    return strings.clone(s)
}

// Emite um item de texto, quebrando-o nos emoji que precisam virar TEXTURA (os
// de fora do BMP — ver emoji.odin, que explica por que só esses). SEM emoji
// emite exatamente um Word, e o caminho comum fica idêntico ao de antes.
//
// `txt` chega JÁ ALOCADO (é o retorno de xform_word) e este procedimento assume
// a posse: se houver quebra, cada peça ganha cópia própria e o original morre —
// `free_inlines` libera `text` item a item, então fatias do mesmo bloco dariam
// free no meio de uma alocação.
@(private="file")
append_text_pieces :: proc(items: ^[dynamic]Inline_Item, txt: string, proto: Inline_Item, href: string) {
    pieces := emoji_split(txt)
    if len(pieces) == 0 || (len(pieces) == 1 && pieces[0].emoji == 0) {
        it := proto
        it.text = txt
        if href != "" do it.href = strings.clone(href)
        append(items, it)
        return
    }
    for p, i in pieces {
        it := proto
        if i > 0 do it.space_before = false // o espaço colapsado pertence ao 1º pedaço
        if p.emoji != 0 {
            // Vira uma imagem inline: altura = tamanho da fonte, largura pelo
            // aspecto real da textura (inline_img_dims preserva quando só a
            // altura é pedida).
            it.kind    = .Image
            it.text    = ""
            it.img_url = emoji_key(p.emoji)
            it.req_h   = proto.fsize
            it.req_w   = 0
        } else {
            it.text = strings.clone(p.text)
        }
        if href != "" do it.href = strings.clone(href)
        append(items, it)
    }
    delete(txt)
}

@(private="file")
add_words :: proc(items: ^[dynamic]Inline_Item, text: string, st: Inline_Style, pending, started: ^bool, ws: White_Space, emit_empty := false) {
    font, scale, fem := l_pick_font(st.size, st.weight, st.fam_id, st.family, st.italic)

    preserve := ws == .Pre || ws == .Pre_Wrap || ws == .Break_Spaces
    no_wrap := ws == .Nowrap || ws == .Pre
    proto := Inline_Item{
        kind = .Word, font = font, fsize = st.size, scale = scale, em = fem, color = st.color,
        lh = st.lh, deco = st.deco, letter_spacing = st.letter_spacing,
        font_kerning = st.font_kerning, valign = st.valign, nowrap = no_wrap,
        can_break = st.break_word, break_all = st.break_all, min_break = st.min_break,
        effect = st.effect, invisible = st.invisible,
    }
    if emit_empty && len(text)==0 {
        proto.space_before=pending^ && started^
        if proto.space_before do pending^=false
        append(items,proto)
    }
    i := 0
    for i < len(text) {
        c := text[i]
        if (preserve || ws == .Pre_Line) && (c == '\n' || c == '\r' || c == '\f') {
            if c == '\r' && i + 1 < len(text) && text[i+1] == '\n' do i += 1
            append(items, Inline_Item{kind = .Break, fsize = st.size, lh = st.lh})
            pending^ = false; started^ = false
            i += 1
            continue
        }
        if preserve && (c == ' ' || c == '\t') {
            start := i
            i += 1
            if ws != .Break_Spaces && c != '\t' {
                for i < len(text) && text[i] == ' ' do i += 1
            }
            it := proto
            // break-spaces permits a break AFTER each space, including the
            // last one. The first space stays attached to the preceding word.
            it.nowrap = ws != .Break_Spaces || (started^ && len(items^) > 0 && !items[len(items^)-1].preserved_space)
            it.preserved_space = true
            it.hanging_space = ws == .Pre_Wrap
            it.can_break = false; it.break_all = false; it.min_break = false
            if c == '\t' {
                it.tab_columns = st.tab_size == 0 ? 8 : st.tab_size
                append_text_pieces(items, strings.clone(""), it, st.href)
            } else {
                append_text_pieces(items, xform_word(text[start:i], st.ttx), it, st.href)
            }
            started^ = true; pending^ = false
            continue
        }
        if is_ws(c) {
            pending^ = true
            i += 1
            continue
        }
        start := i
        for i < len(text) && !is_ws(text[i]) do i += 1
        it := proto
        it.space_before = pending^ && started^
        append_text_pieces(items, xform_word(text[start:i], st.ttx), it, st.href)
        started^ = true; pending^ = false
    }
}

restore_text_fragments :: proc(b: ^Box) {
    w := 0
    for r := 0; r < len(b.inlines); r += 1 {
        cur := b.inlines[r]
        if cur.split_tail && w > 0 {
            head := &b.inlines[w-1]
            joined := strings.concatenate({head.text, cur.text})
            delete(head.text); delete(cur.text); delete(cur.href)
            head.text = joined; head.text_w = 0
            head.pad_after = cur.pad_after
            continue
        }
        b.inlines[w] = cur
        w += 1
    }
    resize(&b.inlines, w)
}
// Insere o marcador (• ou número) como primeiro item inline de um <li>.
@(private="file")
inject_list_marker :: proc(b: ^Box, node: ^dompkg.Node, size: f32, color: u32, family: Font_Family = .Sans, fam_id: u8 = 0, ls: List_Style = .Auto) {
    if ls == .None do return // list-style:none — sem marcador
    marker, ok := list_marker(node, ls)
    if !ok do return
    font, scale, fem := l_pick_font(size, FW_NORMAL, fam_id, family)
    it := Inline_Item{
        kind = .Word, text = strings.clone(marker), invisible = b.invisible,
        font = font, fsize = size, scale = scale, em = fem, color = color,
    }
    if b.is_inline {
        inject_at(&b.inlines, 0, it)
    } else if len(b.children) > 0 && b.children[0].is_inline {
        // bloco cujo 1º filho é uma linha inline (ex.: <li><a>x</a><ul>…</ul></li>):
        // prepende o marcador À ESSA 1ª linha, senão o marcador virava um bullet
        // numa linha vazia própria e o texto descia SEM marcador (bug do sidebar
        // do sqlite: "SQL Syntax"/"C/C++ Interface Spec" com nested <ul>).
        inject_at(&b.children[0].inlines, 0, it)
    } else {
        ibox := new_box(); ibox.kind = .Block; ibox.is_inline = true
        append(&ibox.inlines, it)
        inject_at(&b.children, 0, ibox)
    }
}

// Rótulo estático de um input-BOTÃO (submit/reset/button): vem do `value`, com um
// padrão sensato. "" = sem rótulo. (Campos de texto usam o buffer editável.)
@(private="file")
input_button_label :: proc(node: ^dompkg.Node) -> string {
    switch node.attrs["type"] {
    case "submit", "reset", "button":
        if v, ok := node.attrs["value"]; ok && v != "" do return v
        switch node.attrs["type"] {
        case "submit": return "Enviar"
        case "reset":  return "Redefinir"
        }
    }
    return ""
}

// Copia da regra `::placeholder` o que a pintura consome: COR e OPACIDADE.
// `hint_alpha` nasce em 1 (sem regra) para o caminho antigo continuar idêntico.
@(private="file")
apply_placeholder_style :: proc(b: ^Box, comp: Computed) {
    b.hint_alpha = 1
    ph := comp.placeholder
    if ph == nil do return
    b.hint_alpha = ph.opacity
    if ph.has_color do b.hint_color = ph.color
}

// Configura o controle de formulário da caixa a partir do <input> (void, sem
// filhos): checkbox/radio, ou campo de texto editável (copia value/placeholder).
@(private="file")
set_input_control :: proc(b: ^Box, node: ^dompkg.Node) {
    dis := "disabled" in node.attrs
    b.ctrl_readonly = "readonly" in node.attrs
    switch node.attrs["type"] {
    case "checkbox":
        b.ctrl = .Checkbox
        b.ctrl_checked  = "checked" in node.attrs
        b.ctrl_disabled = "disabled" in node.attrs
    case "radio":
        b.ctrl = .Radio
        b.ctrl_checked  = "checked" in node.attrs
        b.ctrl_disabled = "disabled" in node.attrs
    case "password":
        b.ctrl = .Password
        b.ctrl_disabled = dis
        init_edit_buf(b, node.attrs["value"])
        if p, ok := node.attrs["placeholder"]; ok && p != "" do b.edit_hint = strings.clone(p)
    case "", "text", "search", "email", "url", "tel", "number":
        b.ctrl = .Text
        b.ctrl_disabled = dis
        init_edit_buf(b, node.attrs["value"])
        if p, ok := node.attrs["placeholder"]; ok && p != "" do b.edit_hint = strings.clone(p)
    }
}

// ── <select> ────────────────────────────────────────────────────────────────
// Largura reservada para a setinha nativa do combobox (só quando o autor NÃO
// pediu appearance:none — nesse caso ele desenha o próprio indicador).
SELECT_ARROW_W :: f32(1.2)  // × font-size

// Os <option> em ordem de documento, recursando em <optgroup>.
select_options :: proc(node: ^dompkg.Node, out: ^[dynamic]^dompkg.Node) {
    if node == nil do return
    for c in node.children {
        if c.kind != .Element do continue
        switch c.tag {
        case "option":   append(out, c)
        case "optgroup": select_options(c, out)
        }
    }
}

// Rótulo visível de um <option>: o atributo `label` vence o texto (spec), e o
// espaço em volta é aparado — senão o recuo do HTML fonte entra no rótulo.
option_label :: proc(node: ^dompkg.Node) -> string {
    if node == nil do return ""
    if l, ok := node.attrs["label"]; ok && l != "" do return strings.trim_space(l)
    sb := strings.builder_make(context.temp_allocator)
    dompkg.text_content(node, &sb)
    return strings.trim_space(strings.to_string(sb))
}

// Valor de um <option>: atributo `value`, senão o texto (spec) — a MESMA regra do
// `.value` no dom_bindings, para que o rótulo mostrado e o valor visto pelo JS
// não divirjam.
option_value :: proc(node: ^dompkg.Node) -> string {
    if node == nil do return ""
    if v, ok := node.attrs["value"]; ok do return v
    return option_label(node)
}

// Índice da opção selecionada. Ordem de precedência:
//   1. atributo `value` do <select> — é onde `el.value = x` do JS aterra neste
//      motor (ver a nota em dom_bindings), então é o caminho do React controlado;
//   2. o primeiro <option selected> (HTML estático);
//   3. a primeira opção (comportamento do UA quando nada foi escolhido).
// -1 = sem nenhuma opção.
select_selected_index :: proc(node: ^dompkg.Node, opts: []^dompkg.Node) -> int {
    if len(opts) == 0 do return -1
    if want, ok := node.attrs["value"]; ok {
        for o, i in opts do if option_value(o) == want do return i
    }
    for o, i in opts {
        if s, ok := o.attrs["selected"]; ok && !strings.equal_fold(s, "false") do return i
    }
    return 0
}

// Configura o <select>: fonte/cor do CSS, altura de uma linha e largura padrão =
// a MAIOR opção + a setinha (é o dimensionamento do Chrome), tudo só quando o CSS
// não definiu. Os <option> não geram caixa — quem os desenha é o popup do paint.
@(private="file")
set_select_control :: proc(b: ^Box, node: ^dompkg.Node, comp: Computed) {
    b.ctrl = .Select
    b.ctrl_disabled = "disabled" in node.attrs

    size := comp.has_font_size ? comp.font_size : 16
    b.edit_color = comp.color != 0 ? comp.color : DEFAULT_TEXT
    b.edit_font, _, b.edit_em = l_pick_font(size, FW_NORMAL, comp.font_fam_id, comp.font_family)

    // altura de UMA linha, como no campo de texto de linha única; com
    // box-sizing:border-box a altura inclui padding+borda, senão o conteúdo
    // colapsa a 0 e o controle fica achatado.
    if !b.has_height {
        line := size * 1.35
        if b.box_sizing == .Border {
            line += b.padding[0] + b.padding[2] + b.border_w[0] + b.border_w[2]
        }
        b.has_height = true; b.height = line
    }

    if !b.has_width {
        opts := make([dynamic]^dompkg.Node, context.temp_allocator)
        select_options(node, &opts)
        widest: f32
        for o in opts {
            lbl := option_label(o)
            if lbl == "" do continue
            w := f32(0)
            if b.edit_font != nil {
                cs := strings.clone_to_cstring(lbl, context.temp_allocator)
                w = im.Font_CalcTextSizeA(b.edit_font, render_px(size, b.edit_em), FLT_MAX, FLT_MAX, cs).x
            }
            // sem atlas de fontes (odin test) a medição devolve 0 — estimativa por
            // contagem de bytes, senão o controle nasceria com largura zero.
            if w <= 0 do w = f32(len(lbl)) * size * 0.5
            if w > widest do widest = w
        }
        b.has_width = true
        b.width = widest + (b.appearance_none ? 0 : size * SELECT_ARROW_W)
    }
}

// Configura o <textarea>: valor inicial (conteúdo textual, com um '\n' líder
// removido conforme a spec), fonte/cor do CSS e dimensões padrão a partir de
// cols/rows (o CSS width/height sobrescreve). Limitado a EDIT_CAP-1 bytes, como
// os demais campos.
@(private="file")
set_textarea_control :: proc(b: ^Box, node: ^dompkg.Node, comp: Computed) {
    b.ctrl = .Textarea
    b.ctrl_disabled = "disabled" in node.attrs
    b.ctrl_readonly = "readonly" in node.attrs

    // valor inicial = conteúdo textual do elemento (RCDATA no parser)
    sb := strings.builder_make(context.temp_allocator)
    dompkg.text_content(node, &sb)
    val := strings.to_string(sb)
    if len(val) > 0 && val[0] == '\n' do val = val[1:] // spec: 1 '\n' líder é ignorado
    init_edit_buf(b, val)

    if p, ok := node.attrs["placeholder"]; ok && p != "" do b.edit_hint = strings.clone(p)
    apply_placeholder_style(b, comp)

    eff_size   := comp.has_font_size ? comp.font_size : 16
    eff_family := comp.font_family
    b.edit_color = comp.color != 0 ? comp.color : DEFAULT_TEXT
    b.edit_font, _, b.edit_em = l_pick_font(eff_size, FW_NORMAL, comp.font_fam_id, eff_family)

    // dimensões padrão (cols=20, rows=2 na spec), só se o CSS não definiu. São
    // content-box (largura ≈ cols × 0.5em; altura ≈ rows × line_height); o layout
    // soma padding/borda conforme o box_sizing (não mexemos nele, p/ respeitar o
    // CSS quando ele fixa só um dos eixos).
    if !b.has_width {
        cols := 20
        if v, ok := node.attrs["cols"]; ok { if k, kk := strconv.parse_int(v); kk && k > 0 do cols = k }
        b.has_width = true
        b.width = f32(cols) * eff_size * 0.5
    }
    if !b.has_height {
        rows := 2
        if v, ok := node.attrs["rows"]; ok { if k, kk := strconv.parse_int(v); kk && k > 0 do rows = k }
        b.has_height = true
        b.height = f32(rows) * eff_size * 1.35
    }
}

// Preenche o buffer editável com o valor inicial (truncado à capacidade),
// deixando-o null-terminado para o InputText do ImGui.
@(private="file")
init_edit_buf :: proc(b: ^Box, value: string) {
    n := min(len(value), EDIT_CAP - 1)
    copy(b.edit_buf[:n], value[:n])
    b.edit_buf[n] = 0
}

// Insere o rótulo estático (input-botão) como item inline; no-op para os demais.
@(private="file")
inject_input_label :: proc(b: ^Box, node: ^dompkg.Node, size: f32, color: u32, family: Font_Family, fam_id: u8) {
    label := input_button_label(node)
    if label == "" do return
    if !b.is_inline { b.is_inline = true }
    font, scale, fem := l_pick_font(size, FW_NORMAL, fam_id, family)
    append(&b.inlines, Inline_Item{
        kind = .Word, text = strings.clone(label), invisible = b.invisible,
        font = font, fsize = size, scale = scale, em = fem, color = color,
    })
}

// Texto do marcador de um <li>. `ls` é o list-style-type computado; Auto usa o
// padrão da tag pai (ol = decimal, ul/menu = disc).
@(private="file")
list_marker :: proc(node: ^dompkg.Node, ls: List_Style) -> (string, bool) {
    parent_tag := node.parent != nil ? node.parent.tag : "ul"

    // resolve Auto → tipo concreto conforme a tag pai
    kind := ls
    if kind == .Auto {
        if parent_tag == "ol" {
            kind = .Decimal
        } else {
            // ul sem list-style-type: o UA-stylesheet cicla o marcador pela
            // PROFUNDIDADE de <ul> aninhados — nível 1 disc, 2 circle, 3+ square
            // (ex.: a sidebar do sqlite: nível 2 = ◦, não •).
            depth := 0
            for a := node.parent; a != nil; a = a.parent {
                if a.tag == "ul" do depth += 1
            }
            switch {
            case depth >= 3: kind = .Square
            case depth == 2: kind = .Circle
            case:            kind = .Disc
            }
        }
    }

    // marcadores de bullet (ul); os numéricos/alfabéticos caem adiante
    #partial switch kind {
    case .Disc:   return "•  ", true
    case .Circle: return "◦  ", true
    case .Square: return "▪  ", true
    case .None, .Auto: return "", false
    }

    idx := 1
    if node.parent != nil {
        for c in node.parent.children {
            if c == node do break
            if c.kind == .Element && c.tag == "li" do idx += 1
        }
    }
    body := int_to_str(idx) // padrão: decimal
    #partial switch kind {
    case .Decimal_Zero: if idx < 10 do body = strings.concatenate({"0", body}, context.temp_allocator)
    case .Lower_Alpha:  body = alpha_marker(idx, 'a')
    case .Upper_Alpha:  body = alpha_marker(idx, 'A')
    case .Lower_Roman:  body = roman_marker(idx, false)
    case .Upper_Roman:  body = roman_marker(idx, true)
    }
    return strings.concatenate({body, ".  "}, context.temp_allocator), true
}

@(private="file")
int_to_str :: proc(n: int) -> string {
    buf: [8]byte
    return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}

// Marcador alfabético bijetivo (a..z, aa, ab…), base = 'a' ou 'A'.
@(private="file")
alpha_marker :: proc(n: int, base: u8) -> string {
    if n < 1 do return ""
    tmp: [8]u8
    i := len(tmp)
    v := n
    for v > 0 {
        v -= 1
        i -= 1
        tmp[i] = base + u8(v % 26)
        v /= 26
    }
    return strings.clone(string(tmp[i:]), context.temp_allocator)
}

// Numeral romano (1..3999); acima disso cai no decimal.
@(private="file")
roman_marker :: proc(n: int, upper: bool) -> string {
    if n < 1 || n > 3999 do return int_to_str(n)
    vals := [?]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
    syms := [?]string{"m","cm","d","cd","c","xc","l","xl","x","ix","v","iv","i"}
    sb := strings.builder_make(context.temp_allocator)
    v := n
    for i in 0 ..< len(vals) {
        for v >= vals[i] { strings.write_string(&sb, syms[i]); v -= vals[i] }
    }
    s := strings.to_string(sb)
    return upper ? strings.to_upper(s, context.temp_allocator) : s
}

// Emite UMA camada de gradiente de fundo. `gb0/gb1` = caixa de POSICIONAMENTO
// (onde a rampa é medida); `cl0/cl1` = área de PINTURA (o recorte). Iguais no
// caso comum; diferentes quando o elemento é a fonte do fundo do canvas.
@(private="file")
emit_grad_one :: proc(pt: ^Painter, g: csspkg.Gradient, b: ^Box, screen: im.Vec2,
                      gb0, gb1, cl0, cl1: im.Vec2, force_clip: bool, radius, eff: f32, in_xform: bool) {
    kind: Grad_Kind = .Flat
    if g.conic           do kind = .Conic
    else if g.radial     do kind = .Radial
    else if radius > 0.5 do kind = g.diagonal ? .RoundDiag : .Rounded
    // repeating diagonal: o caminho arredondado tessela em LEQUE a partir do
    // centro (exato só p/ rampa afim de 2 stops) → vira estrela p/ faixas
    // repetidas. Usa a grade diagonal (faixas corretas); cantos ficam retos.
    if g.repeating && g.diagonal && kind == .RoundDiag do kind = .Flat
    // background-attachment: fixed — posiciona no viewport, recorta na caixa
    gp0, gp1 := gb0, gb1
    gclip := force_clip
    if b.bg_fixed && !in_xform && !b.has_transform && !b.has_xform_matrix {
        page_ox := screen.x - b.x
        page_oy := screen.y - b.y
        gp0 = im.Vec2{page_ox + im.GetScrollX(), page_oy + im.GetScrollY()}
        gp1 = im.Vec2{gp0.x + im.GetIO().DisplaySize.x, gp0.y + im.GetIO().DisplaySize.y}
        gclip = true
    }
    emit(pt, PC_Gradient{gp0, gp1, g, radius, eff, kind, cl0, cl1, gclip})
}

// Camada de gradiente de fundo, com o caso do CANVAS: a área de pintura vira a
// página inteira mas a de posicionamento continua sendo a caixa do elemento —
// então, com o `background-repeat: repeat` default, a rampa LADRILHA pelo
// canvas (é o que o Chrome faz com `body{background:linear-gradient(…)}` numa
// página curta; verificado lado a lado).
@(private="file")
emit_grad_bg :: proc(pt: ^Painter, g: csspkg.Gradient, b: ^Box, screen: im.Vec2,
                     ip0, ip1, cv0, cv1: im.Vec2, is_canvas, repeat: bool,
                     radius, eff: f32, in_xform: bool) {
    if !is_canvas {
        emit_grad_one(pt, g, b, screen, ip0, ip1, ip0, ip1, false, radius, eff, in_xform)
        return
    }
    tw, th := ip1.x - ip0.x, ip1.y - ip0.y
    if !repeat || tw < 1 || th < 1 {
        // sem repeat: pinta uma vez na caixa, recortado ao canvas
        emit_grad_one(pt, g, b, screen, ip0, ip1, cv0, cv1, true, radius, eff, in_xform)
        return
    }
    nx := int(math.ceil((cv1.x - cv0.x) / tw)) + 1
    ny := int(math.ceil((cv1.y - cv0.y) / th)) + 1
    // ⚠️ cada ladrilho é uma tesselagem inteira: com caixa minúscula o custo
    // explode (e o índice u16 do ImGui estoura). Acima do teto, degrada p/ UMA
    // rampa esticada no canvas — pior que o Chrome, mas melhor que não pintar.
    if nx * ny > 64 {
        emit_grad_one(pt, g, b, screen, cv0, cv1, cv0, cv1, true, radius, eff, in_xform)
        return
    }
    startx := ip0.x - tw * math.ceil((ip0.x - cv0.x) / tw)
    starty := ip0.y - th * math.ceil((ip0.y - cv0.y) / th)
    for y := starty; y < cv1.y; y += th {
        for x := startx; x < cv1.x; x += tw {
            emit_grad_one(pt, g, b, screen, {x, y}, {x + tw, y + th}, cv0, cv1, true, radius, eff, in_xform)
        }
    }
}

// background-origin: caixa de POSICIONAMENTO da imagem de fundo (default
// padding-box), separada da de CLIP (background-clip). A imagem é dimensionada e
// posicionada nesta caixa, mas o desenho é recortado à de clip.
//
// background-attachment: fixed — a caixa de posicionamento passa a ser o
// VIEWPORT (o recorte segue na caixa, então só aparece dentro dela). A origem da
// PÁGINA em coords de tela é (screen − b.x/b.y); somar o scroll dá o topo do
// viewport — a mesma conversão que position:fixed usa.
@(private="file")
bg_origin_box :: proc(b: ^Box, screen: im.Vec2, bwl, bwt, bwr, bwb: f32, in_xform: bool) -> (op0, op1: im.Vec2) {
    ol, ot, or_, ob: f32 = 0, 0, 0, 0
    switch b.bg_origin {
    case .Border:  // sem recuo
    case .Padding: ol, ot, or_, ob = bwl, bwt, bwr, bwb
    case .Content:
        ol = bwl + b.padding[3]; ot = bwt + b.padding[0]
        or_ = bwr + b.padding[1]; ob = bwb + b.padding[2]
    }
    op0 = im.Vec2{screen.x + ol, screen.y + ot}
    op1 = im.Vec2{screen.x + b.w - or_, screen.y + b.h - ob}
    if b.bg_fixed && !in_xform && !b.has_transform && !b.has_xform_matrix {
        page_ox := screen.x - b.x
        page_oy := screen.y - b.y
        vw, vh := im.GetIO().DisplaySize.x, im.GetIO().DisplaySize.y
        op0 = im.Vec2{page_ox + im.GetScrollX(), page_oy + im.GetScrollY()}
        op1 = im.Vec2{op0.x + vw, op0.y + vh}
    }
    return
}

// Copia as camadas EXTRAS de background do Computed (temp) p/ a Box (owned),
// resolvendo as urls contra a base da página — o mesmo que o bg_img da camada 0
// faz. Só aloca quando existe camada extra, que é o caso raro.
@(private="file")
// Copia o border-image para a Box, resolvendo a url contra a folha e tomando
// POSSE das duas strings (liberadas no destrutor da Box, junto do bg_img).
adopt_bimg :: proc(b: ^Box, bi: Border_Image, base: string) {
    if !bi.active do return
    b.bimg = bi
    b.bimg.src  = bi.src  != "" ? netpkg.resolve_url(base, bi.src, context.allocator) : ""
    b.bimg.grad = bi.grad != "" ? strings.clone(bi.grad) : ""
}

adopt_bg_extra :: proc(b: ^Box, comp: Computed, base: string) {
    if len(comp.bg_extra) == 0 do return
    b.bg_extra = make([]Bg_Layer, len(comp.bg_extra))
    for lay, i in comp.bg_extra {
        b.bg_extra[i] = lay
        b.bg_extra[i].img = lay.img != "" ? netpkg.resolve_url(base, lay.img, context.allocator) : ""
    }
}

@(private="file")
apply_box :: proc(b: ^Box, comp: Computed, base: string = "") {
    b.margin     = comp.margin
    b.has_margin = comp.has_margin
    b.padding    = comp.padding
    b.padding_pct = comp.padding_pct; b.padding_frac = comp.padding_frac; b.padding_off = comp.padding_off
    b.margin_pct = comp.margin_pct; b.margin_frac = comp.margin_frac; b.margin_off = comp.margin_off
    b.border_w   = comp.border_w
    b.border_c   = comp.border_c
    b.border_style_none = comp.border_style_none
    b.has_border = comp.has_border
    b.outline_w   = comp.outline_w
    b.outline_c   = comp.outline_c
    b.outline_off = comp.outline_off
    b.bg         = comp.bg
    b.has_bg     = comp.has_bg
    b.grad       = comp.grad
    b.grad_clip_text = comp.grad_clip_text
    b.bg_size    = comp.bg_size
    b.bg_origin  = comp.bg_origin
    b.bg_clip    = comp.bg_clip
    b.bg_pos_x   = comp.bg_pos_x; b.bg_pos_y = comp.bg_pos_y
    b.bg_repeat  = comp.bg_repeat
    b.bg_canvas  = comp.bg_canvas
    b.obj_fit        = comp.obj_fit
    b.obj_pos_x = comp.obj_pos_x; b.obj_pos_y = comp.obj_pos_y
    b.cursor         = comp.cursor
    b.accent_color   = comp.accent_color; b.has_accent = comp.has_accent
    b.scroll_smooth  = comp.scroll_smooth
    b.clip_path      = comp.clip_path
    b.mask_grad      = comp.mask_grad
    b.mask_image = comp.mask_image
    if comp.mask_image.url != "" do b.mask_image.url = netpkg.resolve_url(base, comp.mask_image.url, context.allocator)
    b.scroll_margin_top  = comp.scroll_margin_top
    b.scroll_padding_top = comp.scroll_padding_top
    b.overscroll_contain = comp.overscroll_contain
    b.appearance_none = comp.appearance_none
    b.isolate        = comp.isolate
    b.pe_none        = comp.pe_none
    b.invisible = comp.invisible
    b.overflow_hidden = comp.overflow_hidden
    b.ovf_clip_x = comp.ovf_clip_x
    b.ovf_clip_y = comp.ovf_clip_y
    b.overflow_scroll = comp.overflow_scroll
    b.ovf_scroll_x = comp.ovf_scroll_x
    b.ovf_scroll_y = comp.ovf_scroll_y
    b.scroll_container = comp.scroll_container
    // APLICABILIDADE de `resize` (css-ui §5.2): só vale em elemento que estabelece
    // contexto de rolagem (overflow ≠ visible) — mais os controles de formulário,
    // que a UA já trata assim (<textarea> não declara overflow no nosso UA style).
    // Sem esta guarda, `resize:both` numa <div> comum ganharia alça, que é
    // justamente o que nenhum navegador faz.
    b.resize = comp.resize
    if b.resize != .None && !comp.overflow_hidden && !comp.overflow_scroll {
        if b.node == nil || b.node.tag != "textarea" do b.resize = .None
    }
    b.break_before_avoid = comp.break_before_avoid
    b.break_after_avoid = comp.break_after_avoid
    b.break_word = comp.break_word || comp.break_all
    b.break_all = comp.break_all; b.min_break = comp.break_all || comp.wrap_anywhere
    b.ellipsis   = comp.ellipsis
    b.line_clamp = comp.line_clamp
    b.text_balance = comp.text_balance
    b.text_indent = comp.text_indent; b.text_indent_pct = comp.text_indent_pct
    b.indent_each_line = comp.indent_each_line; b.indent_hanging = comp.indent_hanging
    b.direction = comp.direction
    b.unicode_bidi=comp.unicode_bidi
    b.writing_mode=comp.writing_mode; b.text_orientation=comp.text_orientation
    b.word_spacing = comp.word_spacing
    b.float = comp.float
    b.clear = comp.clear
    b.has_maxw   = comp.has_maxw; b.maxw = comp.maxw; b.maxw_pct = comp.maxw_pct
    b.has_minw   = comp.has_minw; b.minw = comp.minw; b.minw_pct = comp.minw_pct
    b.has_width  = comp.has_width; b.width = comp.width; b.width_pct = comp.width_pct
    b.def_w      = comp.has_width
    b.has_height = comp.has_height; b.height = comp.height
    b.has_height_pct = comp.has_height_pct; b.height_pct = comp.height_pct
    b.width_pct_off = comp.width_pct_off; b.height_pct_off = comp.height_pct_off
    b.minw_pct_off = comp.minw_pct_off; b.maxw_pct_off = comp.maxw_pct_off
    b.width_bd = comp.width_bd; b.height_bd = comp.height_bd
    b.minw_bd  = comp.minw_bd;  b.maxw_bd  = comp.maxw_bd
    b.minh_bd  = comp.minh_bd;  b.maxh_bd  = comp.maxh_bd
    b.minh_pct = comp.minh_pct; b.has_minh_pct = comp.has_minh_pct; b.minh_pct_off = comp.minh_pct_off
    b.maxh_pct = comp.maxh_pct; b.has_maxh_pct = comp.has_maxh_pct; b.maxh_pct_off = comp.maxh_pct_off
    b.height_mc  = comp.height_mc
    b.width_mc   = comp.width_mc
    b.font_kerning = comp.font_kerning
    b.width_minc = comp.width_minc
    b.width_fit  = comp.width_fit
    b.aspect     = comp.aspect
    b.has_maxh   = comp.has_maxh; b.maxh = comp.maxh
    b.has_minh   = comp.has_minh; b.minh = comp.minh; b.minh_mc = comp.minh_mc
    b.box_sizing = comp.box_sizing
    b.margin_x_auto = comp.margin_x_auto
    b.margin_left_auto = comp.margin_left_auto; b.margin_right_auto = comp.margin_right_auto
    b.margin_top_auto = comp.margin_top_auto; b.margin_bottom_auto = comp.margin_bottom_auto
    b.border_radius = comp.border_radius; b.border_radius_pct = comp.border_radius_pct
    for s in 0 ..< 4 do if comp.border_style_none[s] do b.border_w[s] = 0 // none/hidden zera o lado

    b.pos = comp.position
    b.z_index = comp.z_index
    b.z_index_set = comp.z_index_set; b.stacking_hint = comp.stacking_hint
    b.inset = comp.inset; b.inset_pct = comp.inset_pct; b.inset_has = comp.inset_has; b.inset_off = comp.inset_off
    b.opacity = comp.opacity
    b.blend_mode = comp.blend_mode
    b.filters = comp.filters; b.n_filters = comp.n_filters
    b.backdrop_filters = comp.backdrop_filters; b.n_backdrop = comp.n_backdrop
    b.hover = comp.hover
    b.trans = comp.trans
    if comp.anim.active || len(comp.anim_more) > 0 {
        b.animations = make([]Animation_Player, 1 + len(comp.anim_more))
        b.animations[0].anim = comp.anim
        for a, i in comp.anim_more do b.animations[i + 1].anim = a
        for &p in b.animations {
            p.anim.name = strings.clone(p.anim.name)
            stops := make([]Anim_Stop, len(p.anim.stops))
            copy(stops, p.anim.stops)
            p.anim.stops = stops
        }
    }
    b.transform_opx=comp.transform_opx; b.transform_opy=comp.transform_opy; b.transform_opz=comp.transform_opz
    b.perspective_opx=comp.perspective_opx; b.perspective_opy=comp.perspective_opy
    b.xform=comp.xform
    b.perspective=comp.perspective; b.perspective_ox=comp.perspective_ox; b.perspective_oy=comp.perspective_oy
    b.xf_percent = comp.xf_percent
    b.transform_tx = comp.transform_tx; b.transform_ty = comp.transform_ty
    b.transform_tx_pct = comp.transform_tx_pct; b.transform_ty_pct = comp.transform_ty_pct
    b.transform_rot = comp.transform_rot
    b.transform_sx = comp.transform_sx; b.transform_sy = comp.transform_sy
    b.transform_ox = comp.transform_ox; b.transform_oy = comp.transform_oy
    b.xf_a = comp.xf_a; b.xf_b = comp.xf_b; b.xf_c = comp.xf_c; b.xf_d = comp.xf_d
    b.has_xform_matrix = comp.has_xform_matrix
    b.has_transform = comp.has_transform
    b.xf_back = comp.xf_back; b.backface_hidden = comp.backface_hidden
    b.preserve_3d = comp.preserve_3d; b.in_p3d = comp.in_p3d
    // offset_path e DONO (clone no heap), diferente do resto que vem do Computed.
    // O Computed guarda uma fatia da arena TEMP (apply_decls faz
    // strings.clone(inner, context.temp_allocator)), e layout_box le b.offset_path
    // a CADA frame — depois do free_all(temp) do topo do frame. Aliasar era
    // use-after-free: no navegador interativo, que ja reciclava a arena por frame,
    // toda pagina com offset-path lia memoria liberada. Ficava invisivel no
    // headless so porque ele nunca reciclava. Achado pelos 9
    // css/motion/offset-distance-*.html do WPT ao por o free_all no headless.
    b.has_offset_path = comp.has_offset_path
    b.offset_path = comp.has_offset_path ? strings.clone(comp.offset_path) : ""
    b.offset_distance = comp.offset_distance; b.offset_distance_pct = comp.offset_distance_pct
    b.offset_rotate_auto = comp.offset_rotate_auto; b.offset_rotate_angle = comp.offset_rotate_angle
    b.cb_abs = comp.cb_abs; b.cb_fixed = comp.cb_fixed
    b.shadows = comp.shadows; b.shadow_n = comp.shadow_n
    b.text_shadows = comp.text_shadows; b.text_shadow_n = comp.text_shadow_n

    b.flex_dir = comp.flex_dir
    b.flex_reverse = comp.flex_reverse
    b.flex_wrap = comp.flex_wrap
    b.flex_wrap_reverse = comp.flex_wrap_reverse
    b.justify = comp.justify
    b.align_items = comp.align_items
    b.align_content = comp.align_content
    b.ac_stretch = comp.ac_stretch
    b.justify_items = comp.justify_items
    b.align_self = comp.align_self; b.has_align_self = comp.has_align_self
    b.justify_self = comp.justify_self; b.has_justify_self = comp.has_justify_self
    b.justify_ovf = comp.justify_ovf; b.align_content_ovf = comp.align_content_ovf
    b.align_items_ovf = comp.align_items_ovf; b.justify_items_ovf = comp.justify_items_ovf
    b.align_self_ovf = comp.align_self_ovf; b.justify_self_ovf = comp.justify_self_ovf
    b.gap = comp.gap
    b.gap_pct = comp.gap_pct; b.gap_frac = comp.gap_frac; b.gap_off = comp.gap_off
    b.row_gap_pct = comp.row_gap_pct; b.row_gap_frac = comp.row_gap_frac; b.row_gap_off = comp.row_gap_off
    b.flex_grow = comp.flex_grow
    b.flex_shrink = comp.flex_shrink
    b.flex_basis = comp.flex_basis; b.flex_basis_pct = comp.flex_basis_pct; b.flex_basis_pct_off = comp.flex_basis_pct_off
    b.flex_basis_bd = comp.flex_basis_bd
    b.has_flex_basis = comp.has_flex_basis; b.flex_basis_auto = comp.flex_basis_auto
    b.order = comp.order

    b.grid_auto_fill = comp.grid_auto_fill
    b.grid_track_n = comp.grid_track_n
    b.grid_tracks = comp.grid_tracks
    b.grid_row_track_n = comp.grid_row_track_n
    b.grid_row_tracks = comp.grid_row_tracks
    b.grid_auto_row_n = comp.grid_auto_row_n; b.grid_auto_rows = comp.grid_auto_rows
    b.grid_auto_col_n = comp.grid_auto_col_n; b.grid_auto_cols = comp.grid_auto_cols
    b.grid_flow_col = comp.grid_flow_col; b.grid_flow_dense = comp.grid_flow_dense
    b.grid_sub_cols = comp.grid_sub_cols; b.grid_sub_rows = comp.grid_sub_rows
    b.has_gap_col = comp.has_gap_col; b.has_gap_row = comp.has_gap_row
    b.container_inline = comp.container_inline
    b.content_hidden = comp.content_hidden
    b.bg_fixed = comp.bg_fixed
    // contain-intrinsic-size: tamanho de RESERVA do conteúdo pulado. Vira
    // width/height só quando o autor não deu os próprios — assim a caixa não
    // colapsa p/ 0 (que é o ponto da prop).
    if comp.content_hidden {
        if comp.has_cis_w && !b.has_width  { b.has_width = true;  b.width = comp.cis_w; b.width_pct = false }
        if comp.has_cis_h && !b.has_height { b.has_height = true; b.height = comp.cis_h }
    }
    b.row_gap = comp.row_gap
    b.grid_col_start = comp.grid_col_start; b.grid_col_span = comp.grid_col_span
    b.grid_row_start = comp.grid_row_start; b.grid_row_span = comp.grid_row_span
    b.grid_col_start_auto = comp.grid_col_start_auto; b.grid_col_end_auto = comp.grid_col_end_auto
    b.grid_row_start_auto = comp.grid_row_start_auto; b.grid_row_end_auto = comp.grid_row_end_auto
}

// Somas de borda por eixo (esq+dir / topo+base). Substituem o antigo 2*border_w.
@(private="file") bw_x :: proc(b: ^Box) -> f32 { return b.border_w[3] + b.border_w[1] }
@(private="file") bw_y :: proc(b: ^Box) -> f32 { return b.border_w[0] + b.border_w[2] }

// ── Layout (posições/tamanhos — por frame) ───────────────────────────────────

// force_w/force_h (>=0): largura/altura border-box impostas externamente (flex),
// ignorando width/height/max-width do CSS, sem alterar os campos do nó.
// Guardas anti-hang do layout. Dois modos de patologia travam/fecham o navegador:
//  (1) PROFUNDIDADE: uma árvore com ciclo (ex.: nó DOM que virou descendente de
//      si mesmo) recursiona até estourar a stack.
//  (2) TRABALHO TOTAL: o flex mede E posiciona cada filho (dois layout_box por
//      filho); como align-items:stretch (default) re-dispõe a subárvore, o custo
//      vira ~2^profundidade. O app real do Facebook aninha flex fundo → bilhões
//      de chamadas → congela mesmo com profundidade modesta.
// Ambos viram "aborta o ramo" (best-effort), como os watchdogs do motor JS.
LAYOUT_MAX_DEPTH :: 2000
LAYOUT_MAX_CALLS :: 8_000_000 // teto de chamadas por passada de layout de página
g_layout_depth: int
g_layout_calls: u64
g_layout_overflow_warned: bool

// Desloca uma subárvore já disposta por (dx,dy) — usado pelo flex para
// REPOSICIONAR um item na "pass B" em vez de re-dispô-lo. Sem isto o flex chama
// layout_box duas vezes por filho (medir + posicionar); com flex aninhado isso
// vira O(2^profundidade) e congela o app real do Facebook. Translada só desloca
// coordenadas absolutas — O(tamanho da subárvore), não re-flui nada.
@(private = "file")
translate_subtree :: proc(b: ^Box, dx, dy: f32) {
    if dx == 0 && dy == 0 do return
    b.x += dx; b.y += dy
    b.content_x += dx; b.content_y += dy
    if b.has_static || b.static_flex { b.static_x += dx; b.static_y += dy }
    // NÃO transladamos os inline items (Word/InlineBox): eles são pintados em
    // `content_x + it.x` (it.x é RELATIVO ao content_x), então mover content_x
    // acima JÁ os desloca. Somar dx em it.x também contava o deslocamento DUAS
    // vezes — bug que jogava o texto de um item de flex/absolute movido para
    // longe da sua caixa (ex.: texto centralizado ia parar na borda direita).
    for c in b.children do translate_subtree(c, dx, dy)
}

// A disposição interna deste box depende da ALTURA que ele recebe? Se sim, o flex
// precisa RE-dispô-lo quando o esticar (não basta transladar): grid distribui
// linhas fr, flex-column distribui flex-grow na altura, tabela idem. Já um
// flex-row de linha única usa a altura do CONTEÚDO (não a imposta), e um bloco
// comum só ganha espaço vazio embaixo — esses só transladam (barato, não recursa).
@(private = "file")
height_sensitive :: proc(c: ^Box) -> bool {
    return c.is_grid || c.is_table || (c.is_flex && c.flex_dir == .Column)
}

// cb_h = altura do containing block (content box do pai), passada pelo pai quando
// DEFINIDA — usada só p/ resolver top/bottom em % de position:relative/absolute. -1 =
// indefinida (top/bottom % → 0, per spec). left/right % usam avail_w (largura do CB).
layout_box :: proc(b: ^Box, x, y, avail_w: f32, force_w: f32 = -1, force_h: f32 = -1, cb_h: f32 = -1) {
    if g_layout_depth == 0 {
        g_layout_calls = 0 // nova passada de topo: zera o contador
        // ... e a subárvore recebe o tamanho arrastado ANTES de qualquer container
        // medir os filhos (ver resize_pull_tree).
        if len(g_resize) > 0 do resize_pull_tree(b)
    }
    g_layout_depth += 1
    defer g_layout_depth -= 1
    g_layout_calls += 1
    if g_layout_depth > LAYOUT_MAX_DEPTH || g_layout_calls > LAYOUT_MAX_CALLS {
        if !g_layout_overflow_warned {
            fmt.eprintfln("[layout] teto excedido (prof=%d, chamadas=%d) — árvore cíclica/flex-exponencial; ramo abortado", g_layout_depth, g_layout_calls)
            g_layout_overflow_warned = true
        }
        return
    }
    // Tamanho arrastado pela alça de `resize`: reaplicado a CADA passada de layout
    // (o mapa sobrevive ao restyle que refaz a Box). Vem antes de tudo que lê
    // has_width/has_height abaixo. A varredura de topo (resize_pull_tree) já cobre
    // toda a árvore da passada; este hook é a garantia para uma caixa disposta
    // FORA dela (construída durante o próprio layout). ⚠️ `force_w/force_h` continua
    // vencendo — mas agora o container já mediu o item COM o tamanho arrastado, que
    // é o que faz a alça valer em flex/grid.
    if b.resize != .None && b.node != nil {
        if st, ok := g_resize[b.node]; ok do resize_apply_size(b, st)
    }
    // padding/margin em %: a base é a LARGURA do bloco contenedor (= avail_w) — pela
    // spec vale p/ os QUATRO lados, inclusive topo/base (é o truque `padding-top:56.25%`
    // p/ caixas de proporção fixa). Resolvido aqui, antes de qualquer leitura abaixo.
    for i in 0 ..< 4 {
        if b.padding_pct[i] do b.padding[i] = max(0, b.padding_frac[i] * avail_w + b.padding_off[i])
        if b.margin_pct[i]  do b.margin[i]  = b.margin_frac[i] * avail_w + b.margin_off[i]
    }
    m := b.margin; p := b.padding
    bwt, bwr, bwb, bwl := b.border_w[0], b.border_w[1], b.border_w[2], b.border_w[3]

    // margens efetivas (esq/dir/topo/base). Sem margin no CSS → padrões da UA:
    // a maioria das tags só tem vertical (block_style); <body> tem 8px nos 4 lados.
    ml, mr := m[3], m[1]
    mt, mb := m[0], m[2]
    if !b.has_margin && b.node != nil && b.node.kind == .Element {
        if b.node.tag == "body" {
            ml, mr, mt, mb = 8*g_zoom, 8*g_zoom, 8*g_zoom, 8*g_zoom
        } else {
            st := block_style(b.node.tag)
            mt = st.before; mb = st.after
        }
    }

    // extra de borda+padding que o box-sizing:border-box embute na largura/altura
    extra_w := p[3] + p[1] + bwl + bwr
    extra_h := p[0] + p[2] + bwt + bwb

    // largura do conteúdo: imposta (flex), explícita (width) ou o disponível
    cw: f32
    if force_w >= 0 {
        cw = force_w - extra_w
    } else {
        if b.has_width {
            wpx := b.width_pct ? pct_resolve(b.width, b.width_pct_off, avail_w, b.width_bd) : b.width
            cw = b.box_sizing == .Border ? wpx - extra_w : wpx
        } else if b.width_mc {
            cw = intrinsic_used_width(b, avail_w - ml - mr) - extra_w
        } else {
            cw = avail_w - ml - mr - extra_w
        }
        if b.has_maxw {
            lim := b.maxw_pct ? pct_resolve(b.maxw, b.maxw_pct_off, avail_w, b.maxw_bd) : b.maxw
            if b.box_sizing == .Border do lim -= extra_w
            if lim < cw do cw = lim
        }
        if b.has_minw {
            lo := b.minw_pct ? pct_resolve(b.minw, b.minw_pct_off, avail_w, b.minw_bd) : b.minw
            if b.box_sizing == .Border do lo -= extra_w
            if lo > cw do cw = lo // min vence o max (igual ao CSS)
        }
    }
    // piso de 1px p/ caixas de largura AUTO (evita degenerar o layout). Largura
    // FORÇADA pelo pai (flex/grid) ou INTRÍNSECA (max/min/fit-content) que resolve a
    // 0 é legitimamente 0 — ex.: grid item `width:max-content` vazio (vermelho de
    // largura 0 → some), ou item flex que encolheu a 0. Não floorar esses.
    cw_floor: f32 = (force_w >= 0 || b.width_mc) ? 0 : 1
    if cw < cw_floor do cw = cw_floor

    // margem horizontal: "auto" centraliza no espaço livre (vale p/ width E
    // max-width — só age quando a largura usada é menor que a disponível).
    left := ml
    border_box_w := cw + extra_w
    if b.margin_x_auto && force_w < 0 {
        free := avail_w - border_box_w - ml - mr
        if free > 0 do left = ml + free / 2
    }

    b.x = x + left
    b.y = y + mt
    b.content_w = cw
    // container queries: publica a largura de conteúdo MEDIDA deste contêiner p/
    // a próxima resolução de estilo (ver g_container_w em style.odin).
    if b.container_inline do container_w_record(b.node, cw)
    b.content_x = b.x + bwl + p[3]
    b.content_y = b.y + bwt + p[0]
    b.w = border_box_w

    // multi-coluna: os filhos fluem numa ÚNICA coluna estreita (col_w), depois são
    // redistribuídos (redistribute_columns) balanceando por altura. Aqui só reduz
    // content_w p/ col_w — o resto do fluxo de bloco roda igual. mc_full/n/gap são
    // usados depois de content_h. (b.w continua a largura total.)
    mc_full_w := cw
    mc_n := 1
    mc_col_w := cw
    if b.is_multicol && cw > 1 {
        mc_n, mc_col_w = multicol_geometry(cw, b.mc_count, b.mc_width, b.mc_gap)
        b.content_w = mc_col_w
    }

    // aspect-ratio: com height auto e largura já definida, deriva a altura de
    // conteúdo pela razão (aplica à content-box; force_h do flex e height
    // explícita têm prioridade). min/max-height clampam depois, como na spec.
    aspect_h: f32 = -1
    if b.aspect > 0 && !b.has_height && force_h < 0 {
        aspect_h = cw / b.aspect
        if aspect_h < 0 do aspect_h = 0
    }

    // position:relative — deslocamento aplicado só na pintura (não no fluxo). Em %:
    // left/right resolvem contra a LARGURA do CB (avail_w), top/bottom contra a ALTURA
    // do CB (cb_h; -1 = indefinida → 0, per spec). Para %, inset[i] guarda a FRAÇÃO.
    b.rel_dx, b.rel_dy = 0, 0
    if b.pos == .Relative {
        rel_h := proc(v, off, dim: f32, pct: bool) -> f32 { return pct ? (dim >= 0 ? v * dim + off : 0) : v }
        if      b.inset_has[3] do b.rel_dx =  rel_h(b.inset[3], b.inset_off[3], avail_w, b.inset_pct[3]) // left
        else if b.inset_has[1] do b.rel_dx = -rel_h(b.inset[1], b.inset_off[1], avail_w, b.inset_pct[1]) // right
        if      b.inset_has[0] do b.rel_dy =  rel_h(b.inset[0], b.inset_off[0], cb_h,   b.inset_pct[0]) // top
        else if b.inset_has[2] do b.rel_dy = -rel_h(b.inset[2], b.inset_off[2], cb_h,   b.inset_pct[2]) // bottom
    }

    content_h: f32 = 0
    // altura de conteúdo disponível p/ os filhos flex/grid: imposta pelo pai
    // (force_h — ex.: item esticado por align-items:stretch) ou height explícita.
    // Precisa ser resolvida ANTES de dispor os filhos: um container flex/grid
    // aninhado sem height própria depende dela p/ distribuir flex:1, fr e
    // align-content. Sem isto, uma coluna flex esticada colapsa os filhos.
    avail_h: f32 = -1
    if force_h >= 0 {
        avail_h = max(0, force_h - extra_h)
    } else if b.has_height {
        avail_h = max(0, b.box_sizing == .Border ? b.height - extra_h : b.height)
    } else if aspect_h >= 0 {
        avail_h = aspect_h
    }
    // gap em %: resolve contra o tamanho de CONTEÚDO deste container no eixo —
    // inline (largura) p/ gap/column-gap, bloco (altura DEFINIDA) p/ row-gap. Com o
    // eixo de bloco indefinido a % resolve p/ zero (spec css-align §8.1), sobrando
    // só o offset do calc. Feito aqui porque flex/grid leem b.gap/b.row_gap abaixo.
    if b.gap_pct {
        // An intrinsic flex width cannot provide a definite basis for its own gap.
        b.gap = b.is_flex && b.width_mc ? 0 : max(0, b.gap_frac * b.content_w + b.gap_off)
    }
    if b.row_gap_pct {
        b.row_gap = avail_h >= 0 ? max(0, b.row_gap_frac * avail_h + b.row_gap_off) : max(0, b.row_gap_off)
    }
    if b.is_flex {
        content_h = layout_flex(b, avail_h)
        // posição estática dos abspos filhos, alinhada pelo flex (o content box do
        // container é a caixa de alinhamento; usa a altura definida se houver).
        set_flex_static(b, avail_h >= 0 ? avail_h : content_h)
    } else if b.is_grid {
        content_h = layout_grid(b, avail_h)
    } else if b.is_table && table_has_structure(b) {
        content_h = layout_table(b)
    } else if !b.is_inline && b.kind==.Block && b.writing_mode!=.Horizontal {
        content_h=layout_vertical_blocks(b,avail_h>=0 ? avail_h : (cb_h>=0 ? cb_h : max(1,g_viewport_h)),b.has_width || force_w>=0)
        if !b.has_width && force_w<0 { cw=b.vertical_block_extent; b.content_w=cw; b.w=cw+extra_w }
    } else if b.is_inline && b.writing_mode != .Horizontal {
        content_h=layout_vertical_inline(b,avail_h>=0 ? avail_h : (cb_h>=0 ? cb_h : max(1,g_viewport_h)),b.has_width || force_w>=0)
        if !b.has_width && force_w<0 {
            cw=b.vertical_block_extent; b.content_w=cw; b.w=cw+extra_w
        }
    } else if b.is_inline {
        content_h = layout_inline(b)
    } else {
        switch b.kind {
        case .Image:
            iw, ih := image_dims(b) // intrínseco (natural / atributos width/height)
            // CSS width/height sobrepõem o intrínseco; a dimensão `auto` escala pela
            // razão de aspecto (ex.: logo `height:120px; width:auto` — antes o img de
            // BLOCO ignorava o CSS e renderizava no tamanho natural, gigante).
            css_w: f32 = -1
            // cw is the USED content width, after flex/grid and min/max-width.
            // Re-reading the CSS width here scales the image's height a second
            // time when flex shrinks its width, separating the paint and clip boxes.
            if b.has_width || force_w >= 0 do css_w = cw
            // A altura da caixa pode vir de TRÊS lugares: `height:<px>` (b.height),
            // `height:<%>` — que quem resolve é o PAI, entregando por force_h — e os
            // INSETS de um absoluto (top+bottom), resolvidos em place_absolute, também
            // por force_h. Os dois últimos chegam aqui só dentro de `avail_h`.
            //
            // ⚠️ Olhar apenas `b.has_height` ignorava os dois: um `<img>` com
            // `absolute inset-0 w-full h-full` (o comparador do ultra-photo) caía no
            // ramo "largura definida, altura auto" e ganhava a altura do ASPECTO
            // natural — 670x864 numa caixa de 670x560. Como esse retângulo é também o
            // destino do paint, o `object-fit:contain` passava a caber dentro da caixa
            // ERRADA e a foto saía esticada, sem o letterbox que o Chrome desenha.
            css_h: f32 = avail_h >= 0 ? avail_h : (b.has_height ? b.height : -1)
            if css_w >= 0 && css_h >= 0 {
                iw = css_w; ih = css_h
            } else if css_h >= 0 {
                if ih > 0 do iw = iw * (css_h / ih)
                ih = css_h
            } else if css_w >= 0 {
                if iw > 0 do ih = ih * (css_w / iw)
                iw = css_w
            }
            if iw > cw && iw > 0 { ih = ih * cw / iw; iw = cw }
            b.img_dw = iw; b.img_dh = ih
            content_h = ih
        case .Block:
            cx := b.content_x
            cxr := b.content_x + b.content_w
            cy := b.content_y
            prev_mb: f32 = 0
            seen := false
            // Bandas de float (coords absolutas). cl/cr = bordas disponíveis na
            // linha de float atual; fl_y/fr_y = topo dessa linha; *_bottom = base
            // de TODOS os floats do lado (p/ quebra, clear e altura do container).
            cl, cr := cx, cxr
            fl_y, fr_y := cy, cy
            fl_bottom, fr_bottom := cy, cy
            floats_bottom := cy
            for child in b.children {
                if child.pos == .Absolute || child.pos == .Fixed {
                    // Caixa IÇADA: neste passe ela já é irmã, DEPOIS do âncora, então
                    // `cy` aqui é a base do âncora, não o ponto onde ela cairia no
                    // fluxo — ler daqui empurra o abspos uma "linha" a cada relayout.
                    // Recompõe pelo âncora (re-layoutado todo passe). Só o --render
                    // mostrava: o --dumplayout faz UM passe e acertava.
                    if child.hoisted && child.hoist_anchor != nil {
                        child.static_x = child.hoist_anchor.x + child.hoist_dx
                        child.static_y = child.hoist_anchor.y + child.hoist_dy
                    } else {
                        child.static_x = cx; child.static_y = cy
                    }
                    child.has_static = true
                    continue
                }

                if child.float == .Left {
                    // largura: % resolve contra a largura TOTAL do container (cxr-cx),
                    // NÃO o espaço restante — senão floats consecutivos encolheriam.
                    fw := child.has_width ? -1 : float_fit_width(child, b.content_w)
                    py := max(cy, fl_y)
                    layout_box(child, cl, py, b.content_w, force_w = fw)
                    occ := child.w + child.margin[3] + child.margin[1]
                    if cl + occ > cr + 0.5 && cl > cx { // não cabe → nova linha de floats
                        cl = cx; fl_y = fl_bottom
                        layout_box(child, cl, fl_y, b.content_w, force_w = child.w)
                    } else {
                        fl_y = py
                    }
                    cl = child.x + child.w + child.margin[1]
                    fl_bottom = max(fl_bottom, child.y + child.h + child.margin[2])
                    floats_bottom = max(floats_bottom, fl_bottom)
                    continue
                }
                if child.float == .Right {
                    fw := child.has_width ? -1 : float_fit_width(child, b.content_w)
                    py := max(cy, fr_y)
                    layout_box(child, cl, py, b.content_w, force_w = fw) // 1ª: obtém a largura
                    occ := child.w + child.margin[3] + child.margin[1]
                    rx := cr - occ
                    if rx < cl - 0.5 && cr < cxr { // não cabe → nova linha de floats
                        cr = cxr; fr_y = fr_bottom; rx = cr - occ
                    } else {
                        fr_y = py
                    }
                    layout_box(child, rx, fr_y, b.content_w, force_w = child.w)
                    cr = child.x - child.margin[3]
                    fr_bottom = max(fr_bottom, child.y + child.h + child.margin[2])
                    floats_bottom = max(floats_bottom, fr_bottom)
                    continue
                }

                // conteúdo em fluxo: expira as bandas cuja base já passou pelo y atual
                if cy >= fl_bottom { cl = cx }
                if cy >= fr_bottom { cr = cxr }
                // clear: desce abaixo da base dos floats do lado indicado
                if child.clear == .Left  || child.clear == .Both { if fl_bottom > cy { cy = fl_bottom }; cl = cx }
                if child.clear == .Right || child.clear == .Both { if fr_bottom > cy { cy = fr_bottom }; cr = cxr }

                // colapsa a margem entre irmãos adjacentes. O fluxo já embutiu
                // prev_mb em cy e vai somar cmt em b.y=cy+mt; corrige p/ o valor
                // COLAPSADO (não a soma). Para margens positivas isto é idêntico
                // a subtrair min(prev_mb,cmt); difere só com margens negativas
                // (ex.: margin-top:-50 puxa o irmão p/ cima, sobrepondo).
                if seen {
                    cmt, _ := node_margins(child)
                    comb := collapse_margins(prev_mb, cmt)
                    cy -= (prev_mb + cmt) - comb
                }
                // height:N% do filho resolve contra a altura DEFINIDA deste pai
                // (avail_h>=0 = veio de height/aspect/force_h; auto = -1 → não resolve).
                ch_fh: f32 = -1
                if avail_h >= 0 && child.has_height_pct do ch_fh = max(0, pct_resolve(child.height_pct, child.height_pct_off, avail_h, child.height_bd))
                resolve_child_minmax_h(child, avail_h) // min/max-height em % (mesma base)
                // avail_h (altura DEFINIDA deste pai) é o CB p/ top/bottom % do filho relativo
                layout_box(child, cl, cy, cr - cl, force_h = ch_fh, cb_h = avail_h)
                cy = child.y + child.h + child_bottom_margin(child)
                prev_mb = child.margin[2]
                seen = true
            }
            // o container engloba os floats (aproxima o comportamento de BFC/clearfix)
            content_h = max(cy, floats_bottom) - b.content_y
        }
    }

    // multi-coluna: os filhos foram empilhados numa coluna de largura col_w; agora
    // reparte-os em mc_n colunas (balanceando por altura) e devolve a altura da
    // coluna mais alta. Restaura content_w p/ a largura TOTAL.
    if b.is_multicol && mc_n > 1 && content_h > 0 {
        content_h = redistribute_columns(b, mc_col_w, mc_n, b.mc_gap, content_h)
    }
    if b.is_multicol do b.content_w = mc_full_w

    nat_h := content_h // altura natural do conteúdo (antes de height/max-height)

    // altura imposta (flex) ou explícita (height) substitui a do conteúdo
    if force_h >= 0 {
        content_h = force_h - extra_h
        if content_h < 0 do content_h = 0
    } else if b.has_height {
        content_h = b.box_sizing == .Border ? b.height - extra_h : b.height
        if content_h < 0 do content_h = 0
    } else if aspect_h >= 0 {
        content_h = aspect_h // altura derivada da razão (height auto)
    }
    // min/max-height clampam a altura de conteúdo (min vence o max, igual ao CSS).
    // Não se aplicam quando a altura é imposta pelo flex/grid (force_h).
    if force_h < 0 {
        if b.has_maxh {
            lim := b.box_sizing == .Border ? b.maxh - extra_h : b.maxh
            if lim < content_h do content_h = lim
        }
        if b.has_minh {
            lo := b.box_sizing == .Border ? b.minh - extra_h : b.minh
            if lo > content_h do content_h = lo
        }
        // min-height: min/max-content → piso = altura natural do conteúdo. Ex.:
        // height:0 + min-height:max-content mantém a caixa alta o bastante p/ o
        // conteúdo (nat_h capturado antes de height/min/max sobrescreverem).
        if b.minh_mc && nat_h > content_h do content_h = nat_h
        if content_h < 0 do content_h = 0
    }
    b.h = content_h + p[0] + p[2] + bwt + bwb
    if b.kind == .Image {
        // min/max-height and aspect-ratio can change the used height after the
        // intrinsic-size calculation. object-fit and border-radius use this box.
        b.img_dh = content_h
    }

    // position:sticky — teto do deslocamento p/ baixo dos filhos sticky: podem
    // descer até a base do conteúdo DESTE pai (bloco contendor), nunca além.
    for child in b.children {
        if child.pos == .Sticky {
            child.sticky_max_dy = max(0, (b.content_y + content_h) - (child.y + child.h))
        }
    }

    // scroll de elemento: quanto o conteúdo natural excede a altura visível.
    if b.overflow_scroll {
        // só o eixo que ROLA: `overflow: auto hidden` (carrossel) clipa o Y sem
        // deixar a roda rolá-lo.
        b.scroll_max = b.ovf_scroll_y ? max(0, nat_h - content_h) : 0
        b.scroll_y = clamp(b.scroll_y, 0, b.scroll_max) // reclampa (conteúdo pode mudar)
        // eixo X: o quanto o conteúdo EM FLUXO passa da borda direita da padding
        // box. Medido RELATIVO a b.x (deslocar a subárvore inteira depois não muda
        // nada). Degradação: abs/fixed ficam de fora — ainda não foram posicionados
        // aqui (layout_absolutes roda depois), a mesma lacuna do nat_h vertical.
        b.scroll_max_x = 0
        if b.ovf_scroll_x {
            inner_r := b.x + b.w - bwr
            b.scroll_max_x = max(0, content_right_extent(b) + p[1] - inner_r)
        }
        b.scroll_x = clamp(b.scroll_x, 0, b.scroll_max_x)
    }

    b.margin[2] = mb // guarda a margem inferior efetiva para o irmão

    // transform: translate — acumulado em rel_dx/rel_dy (só visual, não afeta o fluxo)
    if b.has_transform {
        b.rel_dx += (b.transform_tx_pct ? b.transform_tx * b.w : b.transform_tx) + b.xf_percent[0]*b.w + b.xf_percent[1]*b.h
        b.rel_dy += (b.transform_ty_pct ? b.transform_ty * b.h : b.transform_ty) + b.xf_percent[2]*b.w + b.xf_percent[3]*b.h
    }
    // offset-path (CSS Motion Path): posiciona a caixa ao longo do path. O ponto
    // computado recebe a ÂNCORA da caixa (offset-anchor auto = transform-origin);
    // a caixa translada de modo que a âncora caia no ponto, e gira pela tangente.
    if b.has_offset_path {
        px, py, ang, ok := eval_motion_path(b.offset_path, b.offset_distance, b.offset_distance_pct)
        if ok {
            anchor_x := b.transform_ox * b.w
            anchor_y := b.transform_oy * b.h
            b.rel_dx += px - anchor_x
            b.rel_dy += py - anchor_y
            rot := (b.offset_rotate_auto ? ang : 0) + b.offset_rotate_angle
            b.motion_rotation=rot
            if rot != 0 { b.transform_rot += rot; b.has_transform = true }
        }
    }
}

// eval_motion_path: avalia um path() de offset-path (só segmentos RETOS: M/L/H/V/Z)
// e devolve o ponto e o ângulo da tangente à DISTÂNCIA dada. `dist` é fração do
// comprimento (se _pct) ou px. Path FECHADO (z) → distância dá a volta (módulo);
// ABERTO → distância grampeada a [0, comprimento]. Sem curvas (Bézier/arc) — os
// testes de WPT motion usam só linhas; um comando desconhecido aborta (ok=false).
@(private="file")
eval_motion_path :: proc(path: string, dist: f32, is_pct: bool) -> (x, y, angle: f32, ok: bool) {
    pts := make([dynamic][2]f32, context.temp_allocator)
    // tokeniza: comandos (letras) e números (com sinal/decimal)
    toks := make([dynamic]string, context.temp_allocator)
    i := 0
    for i < len(path) {
        c := path[i]
        if c == ' ' || c == ',' || c == '\t' || c == '\n' || c == '\r' { i += 1; continue }
        if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
            append(&toks, path[i:i+1]); i += 1; continue
        }
        // número: [-+]?[0-9.]+
        j := i
        if path[j] == '-' || path[j] == '+' do j += 1
        for j < len(path) && ((path[j] >= '0' && path[j] <= '9') || path[j] == '.') do j += 1
        if j == i do return // caractere inesperado
        append(&toks, path[i:j]); i = j
    }
    cx, cy: f32 = 0, 0
    start_x, start_y: f32 = 0, 0
    closed := false
    num :: proc(toks: [dynamic]string, k: ^int) -> (f32, bool) {
        if k^ >= len(toks) do return 0, false
        v, o := strconv.parse_f32(toks[k^]); k^ += 1
        return v, o
    }
    k := 0
    for k < len(toks) {
        cmd := toks[k]; k += 1
        if len(cmd) != 1 do return
        ch := cmd[0]
        switch ch {
        case 'M', 'm':
            dx, o1 := num(toks, &k); dy, o2 := num(toks, &k)
            if !o1 || !o2 do return
            cx = (ch == 'm' && len(pts) > 0) ? cx + dx : dx
            cy = (ch == 'm' && len(pts) > 0) ? cy + dy : dy
            start_x, start_y = cx, cy
            append(&pts, [2]f32{cx, cy})
        case 'L', 'l':
            dx, o1 := num(toks, &k); dy, o2 := num(toks, &k)
            if !o1 || !o2 do return
            cx = ch == 'l' ? cx + dx : dx; cy = ch == 'l' ? cy + dy : dy
            append(&pts, [2]f32{cx, cy})
        case 'H', 'h':
            dx, o1 := num(toks, &k); if !o1 do return
            cx = ch == 'h' ? cx + dx : dx
            append(&pts, [2]f32{cx, cy})
        case 'V', 'v':
            dy, o1 := num(toks, &k); if !o1 do return
            cy = ch == 'v' ? cy + dy : dy
            append(&pts, [2]f32{cx, cy})
        case 'Z', 'z':
            closed = true
            if cx != start_x || cy != start_y do append(&pts, [2]f32{start_x, start_y})
            cx, cy = start_x, start_y
        case:
            return // comando com curva/arco não suportado
        }
    }
    if len(pts) == 0 do return
    // comprimento total
    total: f32 = 0
    for idx in 1 ..< len(pts) {
        total += math.hypot(pts[idx].x - pts[idx-1].x, pts[idx].y - pts[idx-1].y)
    }
    // path degenerado (comprimento 0): fica no ponto inicial
    if total < 0.001 { return pts[0].x, pts[0].y, 0, true }
    // distância alvo em px
    d := is_pct ? dist * total : dist
    if closed {
        d = d - math.floor(d / total) * total // módulo em [0, total)
    } else {
        d = clamp(d, 0, total)
    }
    // caminha os segmentos
    acc: f32 = 0
    for idx in 1 ..< len(pts) {
        seg := math.hypot(pts[idx].x - pts[idx-1].x, pts[idx].y - pts[idx-1].y)
        if seg < 0.0001 do continue
        if acc + seg >= d || idx == len(pts) - 1 {
            t := (d - acc) / seg
            t = clamp(t, 0, 1)
            px := pts[idx-1].x + (pts[idx].x - pts[idx-1].x) * t
            py := pts[idx-1].y + (pts[idx].y - pts[idx-1].y) * t
            ang := math.atan2(pts[idx].y - pts[idx-1].y, pts[idx].x - pts[idx-1].x)
            return px, py, ang, true
        }
        acc += seg
    }
    return pts[len(pts)-1].x, pts[len(pts)-1].y, 0, true
}

// a margem inferior efetiva foi gravada em b.margin[2] por layout_box
@(private="file")
child_bottom_margin :: proc(child: ^Box) -> f32 { return child.margin[2] }

// Colapso de duas margens verticais adjacentes (CSS 2.1 §8.3.1):
//   ambas >= 0 → a maior ; ambas < 0 → a mais negativa ; sinais mistos → soma.
@(private="file")
collapse_margins :: proc(a, b: f32) -> f32 {
    if a >= 0 && b >= 0 do return max(a, b)
    if a < 0  && b < 0  do return min(a, b)
    return a + b
}

// Margens (topo, base) efetivas de uma caixa — mesma lógica de layout_box,
// usada para colapsar margens antes de posicionar o filho.
@(private="file")
node_margins :: proc(b: ^Box) -> (mt, mb: f32) {
    mt, mb = b.margin[0], b.margin[2]
    if !b.has_margin && b.node != nil && b.node.kind == .Element {
        if b.node.tag == "body" {
            mt = 8*g_zoom; mb = 8*g_zoom
        } else {
            st := block_style(b.node.tag)
            mt = st.before; mb = st.after
        }
    }
    return
}

// Mede a largura de um Word (cacheada em text_w), somando o letter-spacing
// (px extra por glifo). Sem fonte carregada (testes) devolve 0, como antes.
@(private="file")
// Avanço do ESPAÇO entre palavras, MEDIDO na fonte do item.
//
// ⚠️⚠️ Era `fsize * 0.28`: uma fração fixa, calibrada no sans e aplicada a
// qualquer face — a irmã exata da constante FONT_EM. Numa monoespaçada o espaço
// vale 0,55 em (Consolas 8,8px a 16px) contra os 4,5px que a fração dava, e uma
// linha de código com 9 espaços saía 40px curta. Medido contra o Chrome: 10 'M'
// de Consolas JUNTOS batiam exato (87×87), com espaços davam 126 contra 166.
//
// Cache de UMA entrada: itens vizinhos quase sempre compartilham fonte+tamanho,
// então o custo amortizado é uma comparação por palavra.
g_sp_font: ^im.Font
g_sp_size: f32
g_sp_w:    f32

// Um rebuild pode mudar os avanços sem mudar o ponteiro da fonte.
text_metrics_clear :: proc() {
    shaped_text_clear()
    g_sp_font = nil
    g_kern_cache = {}
}

space_adv :: proc(it: ^Inline_Item) -> f32 {
    if it.font == nil || it.fsize <= 0 do return it.fsize * 0.28
    if it.font == g_sp_font && it.fsize == g_sp_size do return g_sp_w
    w := im.Font_CalcTextSizeA(it.font, render_px(it.fsize, it.em), FLT_MAX, FLT_MAX, " ").x
    if w <= 0 do w = it.fsize * 0.28 // face sem glifo de espaço: mantém o antigo
    g_sp_font, g_sp_size, g_sp_w = it.font, it.fsize, w
    return w
}

word_width :: proc(it: ^Inline_Item) -> f32 {
    if it.fsize <= 0 { it.text_w = 0; return 0 } // font-size:0 → sem largura (invisível)
    if it.text_w == 0 && it.font != nil {
        if text_needs_shaping(it.text) || it.bidi_override {
            if shaped := shaped_text(it.font, render_px(it.fsize,it.em),bidi_display_text(it.text,it.bidi_level,it.bidi_override)); shaped != nil {
                it.text_w = shaped.advance
                return it.text_w
            }
        }
        w := im.Font_CalcTextSizeA(it.font, render_px(it.fsize, it.em), FLT_MAX, FLT_MAX, strings.clone_to_cstring(it.text, context.temp_allocator)).x
        if it.letter_spacing != 0 {
            w += it.letter_spacing * f32(utf8.rune_count_in_string(it.text))
        }
        it.text_w = max(0, w + text_kerning_width(it.font, render_px(it.fsize, it.em), it.text, it.font_kerning))
    }
    return it.text_w
}

// Maior prefixo (em bytes) de text cujos glifos somados cabem em avail px.
// Devolve o corte e a largura acumulada. min_runes garante progresso (p/ a
// quebra intra-palavra: pelo menos 1 runa mesmo que não caiba).
@(private="file")
rune_prefix_fitting :: proc(text: string, font: ^im.Font, fsize: f32, fem: f32, letter_spacing: f32, avail: f32, min_runes := 0, kerning: Font_Kerning = .Auto) -> (cut: int, w: f32) {
    count := 0
    prev: rune
    off := 0
    for off < len(text) {
        end := text_cluster_end(text, off)
        seg := Inline_Item{kind = .Word, text = text[off:end], font = font,
            fsize = fsize, em = fem, letter_spacing = letter_spacing, font_kerning = kerning}
        first, _ := utf8.decode_rune_in_string(seg.text)
        rw := word_width(&seg) + text_pair_kerning(font, render_px(fsize, fem), prev, first, kerning)
        if w + rw > avail && count >= min_runes do return
        cut = end; w += rw; count += 1
        for r in seg.text do prev = r
        off = end
    }
    return
}

// Keep combining accents, variation selectors, emoji modifiers, ZWJ sequences
// and regional-indicator pairs together. This is not full UAX #29 shaping.
text_cluster_end :: proc(text: string, start: int) -> int {
    first, n := utf8.decode_rune_in_string(text[start:])
    end := start + n
    prev := first
    regional := first >= 0x1f1e6 && first <= 0x1f1ff
    for end < len(text) {
        r, sz := utf8.decode_rune_in_string(text[end:])
        attached := unicode.is_combining(r) || (r >= 0xfe00 && r <= 0xfe0f) ||
            (r >= 0xe0100 && r <= 0xe01ef) || (r >= 0x1f3fb && r <= 0x1f3ff) ||
            r == 0x200d || prev == 0x200d || (regional && r >= 0x1f1e6 && r <= 0x1f1ff)
        if !attached do break
        end += sz; prev = r; regional = false
    }
    return end
}
// text-overflow:ellipsis — a linha [start,end) estoura cw: esconde do primeiro
// item que não cabe inteiro em diante e anexa "…" à última palavra visível
// (truncada se preciso p/ o "…" caber). Chamado antes do alinhamento em
// finalize_line; estado resetado a cada layout.
@(private="file")
apply_ellipsis :: proc(b: ^Box, start, end: int, cw: f32) {
    // primeiro item que não cabe inteiro na largura
    k := -1
    for i in start ..< end {
        it := &b.inlines[i]
        if it.kind == .Break || it.hidden do continue
        if it.x + it.w > cw { k = i; break }
    }
    if k < 0 do return // linha cabe

    for i in k ..< end {
        if b.inlines[i].kind != .Break do b.inlines[i].hidden = true
    }
    // alvo do "…": o próprio item estourado (se for palavra ainda visível) ou a
    // última palavra anterior. Trunca o texto p/ prefixo + "…" caberem em cw.
    for j := k; j >= start; j -= 1 {
        it := &b.inlines[j]
        if it.kind != .Word || it.font == nil || it.x >= cw do continue
        ell_w := im.Font_CalcTextSizeA(it.font, render_px(it.fsize, it.em), FLT_MAX, FLT_MAX, "…").x
        cut, pw := rune_prefix_fitting(it.text, it.font, it.fsize, it.em, it.letter_spacing, cw - ell_w - it.x, kerning = it.font_kerning)
        it.hidden = false
        it.ellipsized = true
        it.draw_bytes = cut
        it.w = pw + ell_w
        return
    }
}

// Distância do topo do item até a baseline (p/ alinhamento vertical na linha).
// Texto: baseline do glifo (centrado em it.h pelo line-height). Caixa/imagem:
// a baseline default fica na base (item todo acima). sub/super deslocam.
@(private="file")
item_ascent :: proc(it: ^Inline_Item) -> f32 {
    base: f32
    #partial switch it.kind {
    case .Word:                base = (it.h - it.fsize) * 0.5 + it.fsize * 0.8
    case .Image, .InlineBox:   base = it.h
    }
    ref := it.fsize > 0 ? it.fsize : it.h
    #partial switch it.valign {
    case .Sub:   base -= ref * 0.15
    case .Super: base += ref * 0.30
    }
    return base
}

// Finaliza uma linha [start,end): resolve a baseline, posiciona cada item em y
// conforme seu vertical-align e aplica o text-align horizontal. Devolve a altura.
@(private="file")
finalize_line :: proc(b: ^Box, start, end: int, line_top, cw: f32, align: Text_Align) -> f32 {
    if start >= end do return 0
    for j in start..<end do b.inlines[j].line_id=start
    for j := end - 1; j >= start && b.inlines[j].hanging_space; j -= 1 {
        b.inlines[j].w = 0
        b.inlines[j].hidden = true
    }
    // text-overflow:ellipsis (só tem efeito com overflow escondido, como na spec)
    if b.ellipsis && b.overflow_hidden do apply_ellipsis(b, start, end, cw)
    max_asc, max_desc, box_h: f32 = 0, 0, 0
    for i in start ..< end {
        it := &b.inlines[i]
        if it.kind == .Break || (it.hanging_space && it.hidden) do continue
        // top/bottom/middle não entram no cálculo da baseline (alinham à caixa-linha)
        if it.valign == .Top || it.valign == .Bottom || it.valign == .Middle {
            if it.h > box_h do box_h = it.h
            continue
        }
        a := item_ascent(it)
        d := it.h - a
        if a > max_asc  do max_asc = a
        if d > max_desc do max_desc = d
    }
    line_h := max_asc + max_desc
    if box_h > line_h do line_h = box_h
    // linha sem altura própria (só conteúdo font-size:0) mantém o strut do bloco
    if line_h <= 0 && b.strut > 0 do line_h = b.strut
    baseline := max_asc

    for i in start ..< end {
        it := &b.inlines[i]
        if it.kind == .Break { it.y = line_top; continue }
        switch it.valign {
        case .Top:    it.y = line_top
        case .Bottom: it.y = line_top + (line_h - it.h)
        case .Middle: it.y = line_top + (line_h - it.h) * 0.5 // centra na caixa-linha
        case .Baseline, .Sub, .Super:
            it.y = line_top + (baseline - item_ascent(it))
        }
    }

    leading_indent := b.inlines[start].x - b.inlines[start].pad_before
    bidi_line(b, start, end)
    physical := align_physical(align, b.direction)
    if physical == .Center || physical == .Right {
        right: f32 = 0
        for i in start ..< end {
            if b.inlines[i].hidden do continue
            r := b.inlines[i].x + b.inlines[i].w
            if r > right do right = r
        }
        off := physical == .Center ? (cw - right) / 2 : cw - right
        if b.direction == .Rtl do off -= leading_indent
        if off > 0 do for i in start ..< end do b.inlines[i].x += off
    }
    // CSS empty line boxes do not increase the block height. Their inline
    // rectangles still retain the font metrics and insertion position above.
    empty:=true
    for i in start..<end {
        it:=&b.inlines[i]
        if it.kind!=.Word || len(it.text)>0 || it.w>0 || it.pad_before!=0 || it.pad_after!=0 || it.ipt!=0 || it.ipb!=0 { empty=false; break }
    }
    return empty ? 0 : line_h
}

// Folga sub-pixel na quebra de linha: conteúdo que "estoura" por menos que isto
// cabe (absorve erro de arredondamento f32 entre medição e layout; texto é
// snapado a pixel na pintura, então <0.5px é imperceptível).
// text-wrap: balance — teto de linhas (acima disso os navegadores desistem, por
// custo) e nº de passos da busca binária (12 ≈ precisão sub-pixel em 800px).
BALANCE_MAX_LINES :: 10
BALANCE_STEPS     :: 12
WRAP_EPS :: f32(0.5)

// "…" forçado no fim da última linha VISÍVEL de um -webkit-line-clamp (o conteúdo
// continua nas linhas escondidas, então marca truncamento mesmo se a linha coube).
@(private="file")
apply_clamp_ellipsis :: proc(b: ^Box, start, end: int, cw: f32) {
    for j := end - 1; j >= start; j -= 1 {
        it := &b.inlines[j]
        if it.kind != .Word || it.font == nil do continue
        ell_w := im.Font_CalcTextSizeA(it.font, render_px(it.fsize, it.em), FLT_MAX, FLT_MAX, "…").x
        avail := cw - it.x - ell_w
        if avail < 0 do avail = 0
        cut, pw := rune_prefix_fitting(it.text, it.font, it.fsize, it.em, it.letter_spacing, avail, kerning = it.font_kerning)
        it.hidden = false
        it.ellipsized = true
        it.draw_bytes = cut
        it.w = pw + ell_w
        return
    }
}

@(private="file")
// `wrap_w` = largura usada só p/ decidir a QUEBRA (text-wrap:balance a encolhe);
// o ALINHAMENTO segue no content_w real, senão o texto centralizado sairia do
// centro da caixa. `nlines` devolve o nº de linhas (a busca binária do balance).
layout_inline :: proc(b: ^Box, wrap_w: f32 = -1, nlines: ^int = nil) -> f32 {
    restore_text_fragments(b)
    bidi_paragraph(b)
    for child in b.children {
        if child.pos == .Absolute || child.pos == .Fixed {
            child.static_x = b.content_x; child.static_y = b.content_y
            child.has_static = true
        }
    }
    cw := b.content_w
    ww := wrap_w >= 0 ? wrap_w : cw
    // text-wrap: balance — procura a MENOR largura de quebra que ainda produz o
    // mesmo nº de linhas; as linhas ficam parelhas em vez de uma órfã curta.
    if wrap_w < 0 && b.text_balance && cw > 0 {
        n0 := 0
        h := layout_inline(b, cw, &n0)
        if n0 >= 2 && n0 <= BALANCE_MAX_LINES {
            lo, hi := f32(1), cw
            for _ in 0 ..< BALANCE_STEPS {
                if hi - lo < 1 do break
                mid := (lo + hi) * 0.5
                n := 0
                layout_inline(b, mid, &n)
                if n > n0 do lo = mid; else do hi = mid
            }
            return layout_inline(b, hi)
        }
        return h
    }
    nl := 1                 // linhas fechadas + a corrente
    x, y: f32 = 0, 0        // x na linha atual; y = topo da linha atual
    line_start := 0         // índice do 1º item da linha atual
    // text-indent: recua a 1ª linha. % é relativo ao content-width do bloco.
    // x reseta a 0 em cada wrap/break, então só a 1ª linha fica recuada.
    indent := b.text_indent_pct ? b.text_indent * cw : b.text_indent
    if !b.indent_hanging do x = indent

    // -webkit-line-clamp: grava [start,end) e o topo de cada linha p/ truncar
    // depois. Só aloca quando há clamp (custo zero no caminho comum).
    clamping := b.line_clamp > 0
    spans: [dynamic][2]int
    tops:  [dynamic]f32
    sp_p: ^[dynamic][2]int = nil
    tp_p: ^[dynamic]f32    = nil
    if clamping {
        spans = make([dynamic][2]int, context.temp_allocator)
        tops  = make([dynamic]f32,    context.temp_allocator)
        sp_p = &spans; tp_p = &tops
    }

    wrap :: proc(b: ^Box, line_start: ^int, i: int, x, y: ^f32, cw: f32, spans: ^[dynamic][2]int, tops: ^[dynamic]f32, nl: ^int) {
        if spans != nil { append(spans, [2]int{line_start^, i}); append(tops, y^) }
        lh := finalize_line(b, line_start^, i, y^, cw, b.align)
        y^ += lh; x^ = b.indent_hanging ? (b.text_indent_pct ? b.text_indent * cw : b.text_indent) : 0; line_start^ = i; nl^ += 1
    }

    for i := 0; i < len(b.inlines); i += 1 {
        it := &b.inlines[i]
        it.hidden = false; it.ellipsized = false; it.draw_bytes = 0 // estado por layout
        switch it.kind {
        case .Break:
            it.x = x
            if clamping { append(&spans, [2]int{line_start, i}); append(&tops, y) }
            lh := finalize_line(b, line_start, i, y, cw, b.align) // itens antes da quebra
            y += max(lh, max(b.strut, it.fsize * (it.lh > 0 ? it.lh : 1.3)))
            x = (b.indent_each_line != b.indent_hanging) ? indent : 0; line_start = i + 1; nl += 1

        case .Word:
            word_width(it)
            if it.tab_columns != 0 do it.text_w = tab_advance(it, x + it.pad_before, b.word_spacing)
            ih := it.fsize * (it.lh > 0 ? it.lh : 1.3)
            // word-spacing (nível de bloco): px extra no espaço que separa palavras.
            sp := (it.space_before ? space_adv(it) + b.word_spacing : 0) + it.pad_before
            // WRAP_EPS: tolerância sub-pixel. A caixa é dimensionada pela largura
            // intrínseca (soma dos itens); a não-associatividade do f32 faz a soma
            // aqui diferir por ~1 ULP, o que sem folga quebraria uma linha que
            // "cabe exatamente" (ex.: item flex medido no seu max-content).
            if x > 0 && x + sp + it.text_w > ww + WRAP_EPS && !it.nowrap && !it.break_all { wrap(b, &line_start, i, &x, &y, cw, sp_p, tp_p, &nl); sp = it.pad_before; if it.tab_columns != 0 do it.text_w = tab_advance(it, x + sp, b.word_spacing) }
            // overflow-wrap/word-break: a palavra sozinha não cabe na linha
            // inteira → corta o prefixo que cabe e reinjeta o resto como item
            // seguinte (que quebra pra próxima linha e pode ser cortado de novo).
            if it.can_break && !it.nowrap && it.font != nil && ww > 0 && x + sp + it.text_w > ww + WRAP_EPS {
                cut, head_w := rune_prefix_fitting(it.text, it.font, it.fsize, it.em, it.letter_spacing, ww - x - sp, x > 0 ? 0 : 1, it.font_kerning)
                if cut == 0 && x > 0 {
                    wrap(b, &line_start, i, &x, &y, cw, sp_p, tp_p, &nl); sp = it.pad_before
                    cut, head_w = rune_prefix_fitting(it.text, it.font, it.fsize, it.em, it.letter_spacing, ww - sp, 1, it.font_kerning)
                }
                if cut > 0 && cut < len(it.text) {
                    rest := it^
                    rest.text = strings.clone(it.text[cut:])
                    rest.href = it.href != "" ? strings.clone(it.href) : ""
                    rest.text_w = 0
                    rest.split_tail = true
                    rest.source_start += cut
                    rest.space_before = false
                    rest.pad_before = 0 // pad_before fica no 1º fragmento (head)
                    it.pad_after = 0    // pad_after vai p/ o último fragmento (rest)
                    head := strings.clone(it.text[:cut])
                    delete(it.text)
                    it.text = head
                    it.text_w = head_w
                    inject_at(&b.inlines, i + 1, rest)
                    it = &b.inlines[i] // inject pode realocar o array
                }
            }
            it.x = x + sp; it.w = it.text_w; it.h = ih
            x = it.x + it.text_w + it.pad_after

        case .Image:
            iw, ih := inline_img_dims(it, cw)
            sp: f32 = (it.space_before ? 4 : 0) + it.pad_before
            if x > 0 && x + sp + iw > ww && !it.nowrap { wrap(b, &line_start, i, &x, &y, cw, sp_p, tp_p, &nl); sp = it.pad_before }
            it.x = x + sp; it.w = iw; it.h = ih
            x = it.x + iw + it.pad_after

        case .InlineBox:
            if it.box == nil do continue
            bx := it.box
            // shrink-to-fit (max-content) limitado ao container; width explícita honrada
            iw := measure_intrinsic_w(bx)
            // width em PORCENTAGEM: `measure_intrinsic_w` a ignora DE PROPÓSITO (uma
            // % não contribui p/ max-content) — mas aqui, onde o container `cw` é
            // conhecido, ela TEM de ser resolvida. Sem isto todo `width:100%` de
            // átomo inline caía no intrínseco, e um campo de texto VAZIO mede só o
            // próprio padding: era o `<input class="w-full">` do tradebig virando um
            // campo de ~58px no lugar de 512. Atinge todo formulário moderno —
            // `w-full` do Tailwind e `.form-control` do Bootstrap são width:100%.
            if bx.has_width && bx.width_pct {
                iw = pct_resolve(bx.width, bx.width_pct_off, cw, bx.width_bd)
                if bx.box_sizing != .Border do iw += bx.padding[3] + bx.padding[1] + bw_x(bx)
            }
            // ⚠️ o clamp abaixo é PRÉ-EXISTENTE e vale também p/ a %: com box-sizing
            // content-box, `width:100%` + padding passaria do container e o Chrome
            // deixaria TRANSBORDAR; aqui encolhe. Degradação anotada, não regressão
            // (todo CSS moderno usa border-box, onde 100% dá exatamente `cw`).
            if iw > cw do iw = cw
            // ...e por ÚLTIMO min/max-width (CSS §10.4: o shrink-to-fit é clampado
            // depois). Sem isto um `inline-block` com `max-width` saía no intrínseco
            // — o mesmo buraco do stretch de flex/grid: quem impõe por `force_w` tem
            // de clampar, porque o layout_box só clampa o que ele mesmo calcula.
            // min MAIOR que o container transborda de propósito (min vence max).
            iw = stretch_clamp(bx, .Row, iw, cw)
            layout_box(bx, 0, 0, cw, force_w = iw) // dispõe a subárvore a partir de (0,0)
            // MARGEM do átomo inline. CSS 2.1 §10.8.1: o que ocupa a linha é a
            // MARGIN BOX, nos quatro lados — ao contrário do inline NÃO-substituído,
            // cuja margem vertical é ignorada. O bloco de `pad_before/pad_after` em
            // build_inline_items trata aquele outro caso e nunca chega aqui (o ramo
            // de átomo dá `return` antes dele), então até 2026-08-02 o átomo inline
            // não contribuía margem NENHUMA: `mb-6` num `inline-flex` (o toggle
            // Brasil/EUA do tradebig) sumia, e a `margin-right` colava as caixas.
            // ⚠️ as margens EFETIVAS se leem de `bx.x`/`bx.y`, não de `bx.margin[0]`
            // e `bx.margin[3]`: `layout_box` foi chamado com (0,0) e faz `b.x = x+ml`
            // / `b.y = y+mt`, e o default de UA (block_style, ex.: <p>) entra nesse
            // `mt` SEM ser gravado de volta em `b.margin[0]`. A inferior é a única
            // que layout_box devolve (`b.margin[2] = mb`, p/ o colapso com o irmão).
            ml_eff, mt_eff := bx.x, bx.y
            outer_w := ml_eff + bx.w + bx.margin[1]
            sp: f32 = (it.space_before ? 4 : 0) + it.pad_before
            if x > 0 && x + sp + outer_w > ww && !it.nowrap { wrap(b, &line_start, i, &x, &y, cw, sp_p, tp_p, &nl); sp = it.pad_before }
            // it.x/it.y passam a ser o canto da MARGIN box. O paint reencontra a
            // border-box sozinho: `paint_box` recebe it.x/it.y como OFFSET e soma
            // bx.x/bx.y (= ml/mt) por dentro. Idem finalize_line/item_ascent, que
            // medem a linha por it.h — agora a altura da margin box, como na spec.
            it.x = x + sp; it.w = outer_w; it.h = mt_eff + bx.h + bx.margin[2]
            x = it.x + outer_w + it.pad_after
        }
    }
    if clamping { append(&spans, [2]int{line_start, len(b.inlines)}); append(&tops, y) }
    // text-align-last: a ÚLTIMA linha do bloco usa align_last (se definido).
    last_align := b.has_align_last ? b.align_last : b.align
    lh := finalize_line(b, line_start, len(b.inlines), y, cw, last_align)
    if nlines != nil do nlines^ = nl

    // -webkit-line-clamp: passa de N linhas → esconde o excedente, força "…" na
    // última visível e devolve a altura só das N primeiras.
    if clamping && len(spans) > b.line_clamp {
        keep := b.line_clamp
        hide_from := spans[keep][0]
        for i in hide_from ..< len(b.inlines) do if b.inlines[i].kind != .Break do b.inlines[i].hidden = true
        last := spans[keep - 1]
        apply_clamp_ellipsis(b, last[0], last[1], cw)
        return tops[keep] // topo da 1ª linha escondida = base da última visível
    }
    return y + lh
}

// ── <picture> / srcset ───────────────────────────────────────────────────────
// Share source selection between block images and replaced inline items.
// Otherwise an inline avatar always loads src, even when srcset has a sharper image.
image_source_for :: proc(node: ^dompkg.Node, base: string) -> (string, ^dompkg.Node) {
    target := g_viewport_w > 0 ? g_viewport_w : 1280
    source := picture_source_for(node)
    candidate := source != nil ? source : node
    url := ""
    if ss, ok := candidate.attrs["srcset"]; ok do url = srcset_pick(ss, target)
    if url == "" { if src, ok := candidate.attrs["src"]; ok do url = strings.trim_space(src) }
    if url == "" && candidate != node { if src, ok := node.attrs["src"]; ok do url = strings.trim_space(src) }
    if url == "" do return "", nil
    return netpkg.resolve_url(base, url, context.allocator), source
}

//
// O `<img>` dentro de um `<picture>` é só o FALLBACK: quem manda são os `<source>`
// irmãos ANTERIORES, em ordem de documento — vence o primeiro cujo `type` a gente
// sabe decodificar E cujo `media` casa. Pular o que não se decodifica é para isso
// que o `type` existe; sem essa checagem escolheríamos o AVIF (que preferimos NÃO
// ter) e trocaríamos uma imagem que aparece por uma que falha.
//
// Origem: a svelte.dev. O `<img>` aponta para a arte MOBILE e os `<source>` de
// desktop declaram 3795×993 (proporção 3,82). Usando o fallback, a ilustração do
// hero nascia com a proporção errada, estourava o `.hero` e empurrava a página
// inteira para baixo.

// Formatos que o pipeline decodifica: stb (png/jpeg/gif/bmp) + libwebp.
// ⚠️ AVIF fora DE PROPÓSITO — não temos decoder (ver images.odin).
@(private="file")
img_type_decodable :: proc(t: string) -> bool {
    s := strings.to_lower(strings.trim_space(t), context.temp_allocator)
    switch s {
    case "": return true // sem `type`: só dá para saber baixando; aceita
    case "image/png", "image/jpeg", "image/jpg", "image/gif", "image/bmp", "image/webp", "image/x-icon":
        return true
    }
    return false
}

// Escolhe uma URL de um `srcset`. Descritor `Nw` = largura do arquivo; `Nx` = DPR.
// Pegamos o MENOR candidato que ainda cobre a largura do viewport (e o maior se
// nenhum cobrir): baixar o de 3795w para desenhar 1280 é desperdício de rede que
// se paga em segundos de render.
//
// ⚠️ `sizes` é IGNORADO (degradação declarada): sem ele a spec manda assumir
// 100vw, que é o que fazemos. Erra para imagem que ocupa uma fração da largura —
// aí escolhemos um arquivo maior que o necessário, nunca menor.
@(private="file")
srcset_pick :: proc(srcset: string, alvo_w: f32) -> string {
    melhor: string; melhor_w: f32 = 0
    maior:  string; maior_w:  f32 = 0
    it := srcset
    for len(it) > 0 {
        virg := strings.index_byte(it, ',')
        cand: string
        if virg < 0 { cand = it; it = "" } else { cand = it[:virg]; it = it[virg + 1:] }
        cand = strings.trim_space(cand)
        if cand == "" do continue
        url := cand
        desc := ""
        if sp := strings.index_byte(cand, ' '); sp >= 0 {
            url = strings.trim_space(cand[:sp])
            desc = strings.trim_space(cand[sp + 1:])
        }
        if url == "" do continue
        // largura efetiva do candidato: `Nw` direto; `Nx` = alvo × N; sem descritor = 1x
        w := alvo_w
        if len(desc) > 0 {
            n, _ := strconv.parse_f64(desc[:len(desc) - 1])
            if strings.has_suffix(desc, "w") do w = f32(n)
            else if strings.has_suffix(desc, "x") do w = alvo_w * f32(n)
        }
        if w > maior_w { maior_w = w; maior = url }
        if w >= alvo_w && (melhor_w == 0 || w < melhor_w) { melhor_w = w; melhor = url }
    }
    if melhor != "" do return melhor
    return maior
}

// Devolve o `<source>` vencedor para um `<img>` dentro de `<picture>`, ou nil.
@(private="file")
picture_source_for :: proc(img: ^dompkg.Node) -> ^dompkg.Node {
    if img == nil || img.parent == nil || img.parent.tag != "picture" do return nil
    vw := g_viewport_w > 0 ? g_viewport_w : 1280
    vh := g_viewport_h > 0 ? g_viewport_h : 720
    for c in img.parent.children {
        if c == img do break // só os <source> ANTERIORES ao <img> contam
        if c.kind != .Element || c.tag != "source" do continue
        if t, ok := c.attrs["type"]; ok && !img_type_decodable(t) do continue
        if m, ok := c.attrs["media"]; ok && strings.trim_space(m) != "" {
            if !csspkg.media_query_matches(m, vw, vh, g_prefers_dark) do continue
        }
        if ss, ok := c.attrs["srcset"]; ok && strings.trim_space(ss) != "" do return c
        if s, ok := c.attrs["src"]; ok && strings.trim_space(s) != "" do return c
    }
    return nil
}

// `<img alt="">` (ou `aria-hidden="true"`) é DECORATIVA: pelo HTML o elemento
// "não representa nada", e o Chrome não desenha nada por ela quando a imagem
// quebra. `alt` AUSENTE não conta — aí o autor esqueceu, não declarou.
//
// A distinção não é purismo, é MEDIDA: no theguardian 104 de 106 `<img>` têm alt
// com texto, e lá o esqueleto cinza aproxima melhor a foto que o Chrome carrega e
// nós não (`--imgdiff` 50,8 → 52,7 quando apaguei o esqueleto de todas). Já o
// poster do hero da cloudflare — AVIF, sem decoder aqui — tem `alt=""` e vinha
// virando 1256x760 de cinza sobre o laranja (11,7 → 25,2). Apagar só o decorativo
// atende os dois: quem DECLAROU que a imagem não carrega conteúdo não ganha
// invenção nenhuma; quem tem conteúdo mantém o esqueleto.
@(private="file")
img_is_decorative :: proc(node: ^dompkg.Node) -> bool {
    if node == nil do return false
    if a, ok := node.attrs["alt"]; ok && a == "" do return true
    if h, ok := node.attrs["aria-hidden"]; ok && h == "true" do return true
    return false
}

@(private="file")
inline_img_dims :: proc(it: ^Inline_Item, cw: f32) -> (f32, f32) {
    iw, ih: f32 = 32, 32
    nat_w, nat_h: f32 = 0, 0
    if it.img_url != "" {
        img := image_get(it.img_url)
        if img.state == .Ready {
            iw = f32(img.w); ih = f32(img.h)
            nat_w = iw; nat_h = ih
        } else if img.state == .Failed {
            // Emoji que a fonte não tem (ou rune não-BMP que nem é emoji):
            // COLAPSA. Antes do M188 o parser apagava esses runes e não sobrava
            // vão nenhum; reservar um quadrado vazio seria pior que o que havia.
            if _, ok := emoji_key_rune(it.img_url); ok do return 0, 0
        }
    }
    // width/height do CSS/HTML vencem o intrínseco; um só dado preserva o aspecto.
    if it.req_w > 0 && it.req_h > 0 {
        iw = it.req_w; ih = it.req_h
    } else if it.req_w > 0 {
        iw = it.req_w
        ih = nat_w > 0 ? nat_h * (it.req_w / nat_w) : it.req_w
    } else if it.req_h > 0 {
        ih = it.req_h
        iw = nat_h > 0 ? nat_w * (it.req_h / nat_h) : it.req_h
    }
    if iw > cw && iw > 0 { ih = ih * cw / iw; iw = cw } // não estoura o container
    return iw, ih
}

@(private="file")
image_dims :: proc(b: ^Box) -> (f32, f32) {
    if b.img_url != "" {
        if img := image_get(b.img_url); img.state == .Ready do return f32(img.w), f32(img.h)
    }
    aw := attr_num(b.node, "width"); ah := attr_num(b.node, "height")
    // Sem width/height no próprio <img>, valem os do <source> que venceu: é o que
    // dá a PROPORÇÃO antes de a imagem chegar. Na svelte.dev o <img> não tem
    // nenhum dos dois e o <source> traz 3795×993 — sem isto a ilustração do hero
    // caía no default 320×180 (16:9) e saía 1280×720 no lugar de 1280×335.
    if (aw <= 0 || ah <= 0) && b.img_src_node != nil {
        aw = attr_num(b.img_src_node, "width"); ah = attr_num(b.img_src_node, "height")
    }
    if aw > 0 && ah > 0 do return aw, ah
    if b.is_canvas do return 300, 150 // default da spec do <canvas>
    if b.is_svg {
        // sem width/height explícitos: usa a razão do viewBox (ícones lucide = 24×24,
        // dimensionados por CSS w-4/h-4 → a caixa CSS clampa; aqui é só o intrínseco).
        if _, _, vw, vh, ok := svg_viewbox(b.node); ok && vw > 0 && vh > 0 do return vw, vh
        return 24, 24
    }
    return 320, 180
}

// ── Flex layout ──────────────────────────────────────────────────────────────
// Row/column, wrapping in both directions, order, alignment and flexible lengths.
// Intrinsic sizing, baseline and orthogonal writing modes remain partial.

// Children de um container flex/grid na ordem VISUAL: ordena por `order` (estável,
// mantendo a ordem do DOM entre iguais) e, em flex, inverte se row/column-reverse.
// Devolve um array temp de ponteiros; o b.children original (ordem do DOM) fica
// intacto — só o posicionamento segue esta sequência (paint lê x/y já corretos).
@(private="file")
flex_ordered_children :: proc(b: ^Box, reverse: bool) -> []^Box {
    n := len(b.children)
    kids := make([]^Box, n, context.temp_allocator)
    for c, i in b.children do kids[i] = c
    // insertion sort estável por order
    for i in 1 ..< n {
        j := i
        for j > 0 && kids[j - 1].order > kids[j].order {
            kids[j - 1], kids[j] = kids[j], kids[j - 1]
            j -= 1
        }
    }
    if reverse {
        for i in 0 ..< n / 2 do kids[i], kids[n - 1 - i] = kids[n - 1 - i], kids[i]
    }
    return kids
}

// min/max-height em % (ou calc com %) do FILHO resolvem contra a altura DEFINIDA
// do pai — que só o pai conhece. Converte a fração para px nos campos minh/maxh,
// que o layout do próprio filho já consome. No-op se o pai não tem altura definida
// (avail_h<0): pela spec a porcentagem então não resolve.
@(private="file")
resolve_child_minmax_h :: proc(child: ^Box, avail_h: f32) {
    if avail_h < 0 do return
    if child.has_minh_pct {
        child.minh = max(0, pct_resolve(child.minh_pct, child.minh_pct_off, avail_h, child.minh_bd))
        child.has_minh = true
    }
    if child.has_maxh_pct {
        child.maxh = max(0, pct_resolve(child.maxh_pct, child.maxh_pct_off, avail_h, child.maxh_bd))
        child.has_maxh = true
    }
}

@(private="file")
layout_flex :: proc(b: ^Box, avail_h: f32 = -1) -> f32 {
    n := len(b.children)
    if n == 0 do return 0
    if b.flex_dir == .Column do return layout_flex_column(b, avail_h)

    cw := b.content_w
    gap := b.gap

    kids := flex_ordered_children(b, false) // collect lines in order-modified document order
    bases   := make([]f32, n, context.temp_allocator)
    grows   := make([]f32, n, context.temp_allocator)
    shrinks := make([]f32, n, context.temp_allocator)
    mins    := make([]f32, n, context.temp_allocator)
    maxs    := make([]f32, n, context.temp_allocator)
    for child, i in kids {
        resolve_child_minmax_h(child, avail_h) // min/max-height em % (eixo cruzado da row)
        bases[i], grows[i], shrinks[i] = flex_base_main(child, cw, avail_h)
        mins[i], maxs[i] = box_min_max_axis(child, .Row, cw)
        // TAMANHO MÍNIMO AUTOMÁTICO (CSS Flexbox §4.5) — metade INLINE do bloco que
        // o layout_flex_column já fazia no eixo de bloco. `min-width` inicial de um
        // item flex é `auto`, que resolve p/ o mínimo BASEADO EM CONTEÚDO, não 0:
        // uma linha que não cabe deve TRANSBORDAR, não espremer os itens abaixo do
        // min-content. Sem isto a navbar do GitHub saía com os botões a 53px sobre
        // um texto de 61px, um por cima do outro (o Chrome transborda e preserva).
        // ⚠️ No eixo de bloco min-content == max-content e a altura natural já servia;
        // aqui NÃO — min-content é o maior átomo, não a soma. Daí o medidor separado.
        // Vira 0 só p/ SCROLL CONTAINER (hidden/auto/scroll); `overflow:clip` não é
        // scroll container, então o mínimo vale — mesma regra da coluna.
        if !child.has_minw && !child.scroll_container {
            mins[i] = max(mins[i], min(flex_auto_min_w(child, cw, avail_h), maxs[i]))
        }
    }

    // quebra em linhas (flex-wrap); sem wrap = uma única linha
    lines: [dynamic][2]int
    defer delete(lines)
    if b.flex_wrap {
        i := 0
        for i < n {
            ls := i
            acc: f32 = 0
            for i < n {
                c := kids[i]
                outer := clamp_main(bases[i], mins[i], maxs[i]) + c.margin[3] + c.margin[1]
                add := i == ls ? outer : outer + gap
                if i > ls && acc + add > cw do break
                acc += add
                i += 1
            }
            append(&lines, [2]int{ls, i})
        }
    } else {
        append(&lines, [2]int{0, n})
    }

    if !b.flex_wrap do return flex_row_line(b, kids, 0, n, cw, gap, b.content_y, bases, grows, shrinks, mins, maxs, avail_h, avail_h)

    // A wrapping container remains multi-line even if only ONE line is collected.
    // Measure once; pure align-content positioning only translates subtrees.
    line_h := make([]f32, len(lines), context.temp_allocator)
    for ln, idx in lines {
        line_h[idx] = flex_row_line(b, kids, ln[0], ln[1], cw, gap, b.content_y, bases, grows, shrinks, mins, maxs, -1, avail_h)
    }
    total := b.row_gap * f32(len(lines) - 1)
    for h in line_h do total += h
    cross_h := avail_h >= 0 ? avail_h : total
    free := max(0, cross_h - total)
    extra := b.ac_stretch ? free / f32(len(lines)) : 0
    ac_unsafe := !b.ac_stretch && b.align_content_ovf == .Unsafe
    off, between := flex_justify(b.align_content, b.ac_stretch ? 0 : (ac_unsafe ? cross_h - total : free), b.row_gap, len(lines), ac_unsafe)
    cy := off
    for ln, idx in lines {
        h := line_h[idx] + extra
        py := b.flex_wrap_reverse ? cross_h - cy - h : cy
        if extra > 0 {
            flex_row_line(b, kids, ln[0], ln[1], cw, gap, b.content_y + py, bases, grows, shrinks, mins, maxs, h, avail_h)
        } else {
            for i in ln[0] ..< ln[1] do translate_subtree(kids[i], 0, py)
        }
        cy += h + between
    }
    return cross_h
}

// Distribui, mede e posiciona os itens [s,e) de uma linha flex row em cross_y.
// Devolve a altura (cross) usada pela linha.
// Baseline offset in border-box coordinates; empty boxes synthesize at the bottom.
@(private="file")
box_baseline :: proc(b: ^Box, last: bool = false) -> f32 {
    if b.writing_mode != .Horizontal do return b.h
    found := false
    result := b.h
    for &it in b.inlines {
        if it.kind != .Word && it.kind != .Image && it.kind != .InlineBox do continue
        v := b.content_y - b.y + it.y + item_ascent(&it)
        if !found || last { result = v; found = true }
    }
    if found do return result
    for c in b.children {
        if c.pos == .Absolute || c.pos == .Fixed do continue
        v := c.y - b.y + box_baseline(c, last)
        if !found || last { result = v; found = true }
    }
    return result
}

// Vertical text exports a central baseline along the physical horizontal axis.
@(private="file")
box_vertical_baseline :: proc(b: ^Box, last: bool = false) -> f32 {
    if b.writing_mode == .Horizontal do return b.w*0.5
    found := false
    result := b.w*0.5
    for &it in b.inlines {
        if it.kind != .Word && it.kind != .Image && it.kind != .InlineBox do continue
        if !found || last { result = b.content_x-b.x+it.x+it.w*0.5; found = true }
    }
    if found do return result
    for c in b.children {
        if c.pos == .Absolute || c.pos == .Fixed do continue
        if !found || last { result = c.x-b.x+box_vertical_baseline(c,last); found = true }
    }
    return result
}

@(private="file")
flex_row_line :: proc(b: ^Box, kids: []^Box, s, e: int, cw, gap, cross_y: f32, bases, grows, shrinks, mins, maxs: []f32, cross_h: f32 = -1, percent_h: f32 = -1) -> f32 {
    cnt := e - s
    if cnt <= 0 do return 0

    // espaço para os itens = largura de conteúdo menos gaps e margens
    avail := cw - gap * f32(cnt - 1)
    for i in s ..< e { c := kids[i]; avail -= c.margin[3] + c.margin[1] }
    // resolve grow/shrink COM clamp de min/max por item (redistribui ao congelar)
    finals := resolve_flex_lengths(bases[s:e], grows[s:e], shrinks[s:e], mins[s:e], maxs[s:e], avail) // índice local k = i - s

    // pass A: mede a altura de cada item já com a largura final
    line: f32 = 0
    for i in s ..< e {
        c := kids[i]; f := finals[i - s]
        // A percentage height resolves against the definite CONTENT height of
        // the flex container, even with align-items:center. It is not the line's
        // cross size (especially with wrap). Without this, an img falls back to
        // its HTML height: Famosos-BR's 80x90 photo inside an 80x80 avatar.
        fh: f32 = -1
        if c.has_height_pct && percent_h >= 0 {
            fh = max(0, pct_resolve(c.height_pct, c.height_pct_off, percent_h, c.height_bd))
            if c.box_sizing == .Content do fh += c.padding[0] + c.padding[2] + bw_y(c)
            fh = stretch_clamp(c, .Column, fh, percent_h)
        }
        layout_box(c, b.content_x, cross_y, f, f, fh)
        cmt, cmb := node_margins(c)
        oc := c.h + cmt + cmb
        if oc > line do line = oc
    }
    first_asc, first_desc, last_asc, last_desc: f32
    for i in s ..< e {
        c := kids[i]
        ai := item_cross_align(b, c)
        if ai != .Baseline && ai != .LastBaseline do continue
        mt, mb := node_margins(c)
        asc := box_baseline(c, ai == .LastBaseline)
        if ai == .Baseline {
            first_asc = max(first_asc, asc + mt)
            first_desc = max(first_desc, c.h - asc + mb)
        } else {
            last_asc = max(last_asc, asc + mt)
            last_desc = max(last_desc, c.h - asc + mb)
        }
    }
    line = max(line, max(first_asc + first_desc, last_asc + last_desc))
    // height definida do container manda no tamanho cruzado (p/ stretch)
    if cross_h >= 0 do line = cross_h

    used := gap * f32(cnt - 1)
    for i in s ..< e { c := kids[i]; used += finals[i - s] + c.margin[3] + c.margin[1] }
    jfree := max(0, cw - used) // sobra após o flex (0 se grow preencheu; >0 se limitou no max)

    // auto-margins no eixo principal absorvem a sobra e IGNORAM justify-content
    // (padrão navbar: margin-left:auto empurra o item para a direita).
    n_autos := 0
    for i in s ..< e { c := kids[i]; if c.margin_left_auto do n_autos += 1; if c.margin_right_auto do n_autos += 1 }
    soff, between: f32
    auto_share: f32 = 0
    if n_autos > 0 {
        auto_share = jfree / f32(n_autos)
        soff = 0; between = gap
    } else {
        j_unsafe := b.justify_ovf == .Unsafe
        soff, between = flex_justify(b.justify, j_unsafe ? cw - used : jfree, gap, cnt, j_unsafe)
    }

    // pass B: posiciona. A pass A já dispôs cada item em (b.content_x, cross_y) na
    // largura final f; aqui só TRANSLADAMOS a subárvore até o x/y final em vez de
    // re-dispor (que dobraria o custo por nível → exponencial no flex aninhado do
    // Facebook). O stretch cruzado só cresce a altura da caixa; conteúdo interno
    // top-aligned fica igual (aproximação aceitável vs. congelar).
    cx := b.content_x + soff
    for i in s ..< e {
        c := kids[i]; f := finals[i - s]
        if (b.flex_reverse ? c.margin_right_auto : c.margin_left_auto) do cx += auto_share
        cmt, cmb := node_margins(c)
        oc := c.h + cmt + cmb
        ai := item_cross_align(b, c) // align-self sobrescreve align-items
        ai = safe_align(ai, item_cross_safe(b, c), line, oc)
        if b.flex_wrap_reverse {
            if ai == .Start { ai = .End } else if ai == .End { ai = .Start }
        }
        yoff := flex_align(ai, line, oc)
        if ai == .Baseline do yoff = first_asc - box_baseline(c) - cmt
        if ai == .LastBaseline do yoff = line - last_desc - box_baseline(c, true) - cmt
        // stretch só se aplica quando o cross-size (altura, numa row) é AUTO;
        // com altura definida OU intrínseca (min/max/fit-content) o stretch é
        // ignorado (o item fica no flex-start com sua altura própria).
        pct_resolved := c.has_height_pct && percent_h >= 0
        fh: f32 = (ai == .Stretch && !c.has_height && !c.height_mc && !pct_resolved) ? line - cmt - cmb : -1
        // min/max-height limitam o esticado — e o limite pode DIMINUIR a caixa
        // (max-height menor que a linha), não só aumentá-la.
        // ⚠️ `limitou` estreita a mudança de propósito: fora do caso em que o limite
        // agiu, vale a regra ANTIGA de que o stretch só CRESCE a caixa. Um item mais
        // alto que um container de altura definida continua transbordando como antes
        // — encolhê-lo seria mais próximo da spec, mas é outra mudança e outro risco.
        limitou := false
        if fh >= 0 {
            fh_cl := stretch_clamp(c, .Column, fh, 0)
            limitou = fh_cl < fh - 0.5
            fh = fh_cl
        }
        px := b.flex_reverse ? b.content_x + cw - (cx-b.content_x) - f - c.margin[3] - c.margin[1] : cx
        if fh >= 0 && (fh > c.h + 0.5 || limitou) && height_sensitive(c) {
            layout_box(c, px, cross_y + yoff, f, f, fh) // grid/coluna: re-dispõe p/ redistribuir a altura
        } else {
            translate_subtree(c, px - b.content_x, yoff)
            if fh >= 0 && (fh > c.h || limitou) do c.h = fh // stretch cresce; o limite pode reduzir
        }
        cx += f + c.margin[3] + c.margin[1] + between
        if (b.flex_reverse ? c.margin_left_auto : c.margin_right_auto) do cx += auto_share
    }
    return line
}

@(private="file")
layout_flex_column :: proc(b: ^Box, avail_h: f32 = -1) -> f32 {
    n := len(b.children)
    cw := b.content_w
    // A zero row-gap is meaningful; column-gap only separates wrapped columns.
    gap := b.row_gap

    // altura disponível na direção principal: imposta pelo pai (item esticado)
    // ou height explícita. Só há espaço "livre" p/ flex-grow quando > 0.
    main_avail: f32 = avail_h >= 0 ? avail_h : 0

    kids := flex_ordered_children(b, false) // reverse changes placement, not line collection
    wrapping := b.flex_wrap && avail_h >= 0
    cross   := make([]f32, n, context.temp_allocator) // largura (cross) de cada item
    bases   := make([]f32, n, context.temp_allocator)
    grows   := make([]f32, n, context.temp_allocator)
    shrinks := make([]f32, n, context.temp_allocator)
    mins    := make([]f32, n, context.temp_allocator)
    maxs    := make([]f32, n, context.temp_allocator)

    // pass A: mede a altura natural de cada item na largura cross
    for child, i in kids {
        resolve_child_minmax_h(child, avail_h) // zero is also a definite height
        istr := flex_col_stretch_w(b, child) // align-self por item, e só p/ largura AUTO
        // Item com width PRÓPRIA (o único caso novo aqui) resolve a largura ELE
        // MESMO: force_w = -1 e avail = a largura do container. É o que o grid já
        // faz com `it.def_w`, e é obrigatório — `measure_intrinsic_w` ignora % de
        // propósito, então forçar o intrínseco encolheria todo `width:100%`/`50%`
        // (que antes acertava por acidente, esticando). Nunca coincide com `istr`:
        // com def_w o stretch não se aplica.
        propria := child.def_w || child.width_mc
        cs := ((istr && !wrapping) || propria) ? cw : min(measure_intrinsic_w(child), cw)
        // esticar preenche o container, mas o tamanho USADO é limitado por
        // min/max-width (css-align §4.2). Só no caminho FORÇADO: com width própria
        // quem clampa é o layout_box, que aí calcula a largura ele mesmo.
        if !propria do cs = stretch_clamp(child, .Row, cs, cw)
        fw: f32 = propria ? -1 : cs
        initial_h: f32 = -1
        if child.has_height_pct && avail_h >= 0 {
            initial_h = max(0, pct_resolve(child.height_pct,child.height_pct_off,avail_h,child.height_bd))
            if child.box_sizing == .Content do initial_h += child.padding[0]+child.padding[2]+bw_y(child)
        }
        layout_box(child, b.content_x, b.content_y, propria ? cw : cs, fw, initial_h)
        if propria do cs = child.w // largura USADA (pós-%, pós-min/max) p/ a pass B
        cross[i] = cs
        grows[i] = child.flex_grow
        shrinks[i] = child.flex_shrink
        if child.has_flex_basis && !child.flex_basis_auto {
            // basis em coluna = ALTURA. A fração resolve contra a altura definida do
            // container (main_avail); antes a % era ignorada e `flex-basis:50%` virava
            // 0.5 PIXEL.
            bases[i] = child.flex_basis_pct ? (avail_h >= 0 ? max(0, pct_resolve(child.flex_basis, child.flex_basis_pct_off, main_avail, child.flex_basis_bd)) : child.h) : child.flex_basis
            if child.box_sizing == .Content && (!child.flex_basis_pct || avail_h >= 0) {
                bases[i] += child.padding[0] + child.padding[2] + bw_y(child)
            }
        } else {
            bases[i] = child.h
        }
        mins[i], maxs[i] = box_min_max_axis(child, .Column, main_avail)
        // TAMANHO MÍNIMO AUTOMÁTICO (CSS Flexbox §4.5): o valor inicial de min-height
        // num flex item é `auto`, que resolve para o mínimo BASEADO EM CONTEÚDO — não
        // 0. Vira 0 só p/ SCROLL CONTAINER (hidden/auto/scroll). ⚠️ `overflow:clip` NÃO
        // é scroll container (clipa mas não rola) → o mínimo de conteúdo VALE, igual a
        // visible (min-size-auto-overflow-clip). Antes usava overflow_hidden, que inclui
        // clip. No eixo de bloco min-content == max-content, então a altura natural
        // medida logo acima na pass A É o mínimo. Sem isto, um item `flex:1`
        // (flex-basis:0) numa linha que já transborda encolhe a shrink×base = 0 e SOME
        // — era o colapso do bandcamp (`main.app` h=0) e da coingecko.
        if !child.has_minh && !child.scroll_container {
            cbm := child.h // altura de conteúdo natural (pass A, force_h=-1)
            // "specified size suggestion": com height definida, ela limita o mínimo.
            if child.has_height do cbm = min(cbm, child.height)
            if child.aspect > 0 && child.def_w {
                ew := child.padding[3] + child.padding[1] + bw_x(child)
                eh := child.padding[0] + child.padding[2] + bw_y(child)
                transferred := child.box_sizing == .Border ? cs / child.aspect : max(0, cs-ew) / child.aspect + eh
                if child.kind == .Image { cbm = min(cbm, transferred) } else { cbm = max(cbm, transferred) }
                if child.has_height do cbm = min(cbm, child.box_sizing == .Border ? child.height : child.height + eh)
            }
            mins[i] = max(mins[i], min(cbm, maxs[i]))
        }
    }

    // Collect columns using OUTER hypothetical main sizes, before flexing.
    // An indefinite height never creates additional columns.
    lines := make([dynamic][2]int, context.temp_allocator)
    for s := 0; s < n; {
        e := s
        used: f32 = 0
        for e < n {
            mt, mb := node_margins(kids[e])
            add := clamp_main(bases[e], mins[e], maxs[e]) + mt + mb
            if e > s do add += gap
            if wrapping && e > s && used + add > main_avail do break
            used += add
            e += 1
        }
        append(&lines, [2]int{s, e})
        s = e
    }
    line_w := make([]f32, len(lines), context.temp_allocator)
    cross_used := b.gap * f32(max(0, len(lines)-1))
    for ln, j in lines {
        for i in ln[0] ..< ln[1] do line_w[j] = max(line_w[j], cross[i] + kids[i].margin[3] + kids[i].margin[1])
        if !b.flex_wrap do line_w[j] = cw
        cross_used += line_w[j]
    }
    cross_free := max(0, cw - cross_used)
    if b.flex_wrap && b.ac_stretch {
        for j in 0 ..< len(lines) do line_w[j] += cross_free / f32(len(lines))
        cross_free = 0
    }
    ac_unsafe := b.flex_wrap && !b.ac_stretch && b.align_content_ovf == .Unsafe
    xoff, cross_between := flex_justify(b.align_content, ac_unsafe ? cw - cross_used : cross_free, b.gap, len(lines), ac_unsafe)
    result: f32 = 0
    for ln, j in lines {
        px := b.flex_wrap_reverse ? cw - xoff - line_w[j] : xoff
        result = max(result, flex_column_line(b, kids[ln[0]:ln[1]], cross[ln[0]:ln[1]], bases[ln[0]:ln[1]], grows[ln[0]:ln[1]], shrinks[ln[0]:ln[1]], mins[ln[0]:ln[1]], maxs[ln[0]:ln[1]], line_w[j], px, main_avail, avail_h >= 0, gap))
        xoff += line_w[j] + cross_between
    }
    return result
}

// Resolve each column independently, then align it in its cross-axis line.
@(private="file")
flex_column_line :: proc(b: ^Box, kids: []^Box, cross, bases, grows, shrinks, mins, maxs: []f32, cw, column_x, main_avail: f32, definite: bool, gap: f32) -> f32 {
    n := len(kids)
    finals: []f32
    if definite {
        avail := main_avail - gap * f32(n - 1)
        for child in kids { cmt, cmb := node_margins(child); avail -= cmt + cmb }
        finals = resolve_flex_lengths(bases, grows, shrinks, mins, maxs, avail)
    } else {
        // sem altura explícita. Mas se o container tem MIN-HEIGHT definida (px) e o
        // conteúdo base não a alcança, o excedente (min-height − base) é espaço livre
        // p/ flex-grow: o container fica NO min-height e os itens `flex:1` o preenchem.
        // Antes o min-height só clampava a CAIXA depois do flex, e um item flex:1
        // (base 0) saía h=0 (grid-within-flexbox-indefinite). % de min-height fica de
        // fora (resolve contra a altura do pai, indefinida aqui).
        min_main: f32 = 0
        if b.has_minh {
            eh := b.padding[0] + b.padding[2] + bw_y(b)
            min_main = b.box_sizing == .Border ? b.minh - eh : b.minh
        }
        base_used := gap * f32(n - 1)
        for child, i in kids {
            cmt, cmb := node_margins(child)
            base_used += clamp_main(bases[i], mins[i], maxs[i]) + cmt + cmb
        }
        if min_main > base_used {
            avail := min_main - gap * f32(n - 1)
            for child in kids { cmt, cmb := node_margins(child); avail -= cmt + cmb }
            finals = resolve_flex_lengths(bases, grows, shrinks, mins, maxs, avail)
        } else {
            // sem espaço a distribuir, só limita cada base a min/max
            finals = make([]f32, n, context.temp_allocator)
            for i in 0 ..< n do finals[i] = clamp_main(bases[i], mins[i], maxs[i])
        }
    }

    used := gap * f32(n - 1)
    for child, i in kids {
        cmt, cmb := node_margins(child)
        used += finals[i] + cmt + cmb
    }
    jfree := definite ? main_avail - used : 0
    soff, between := flex_justify(b.justify, jfree, gap, n, b.justify_ovf == .Unsafe)

    // origem da margin-box. Como no flex-row: a pass A já dispôs cada item; aqui
    // TRANSLADAMOS até (x, cy) em vez de re-dispor (evita o custo exponencial do
    // flex aninhado). O tamanho principal resolvido (finals[i]) vira a altura da
    // caixa; conteúdo interno fica top-aligned (aproximação vs. congelar).
    first_base, last_descent: f32
    for child in kids {
        ai := item_cross_align(b, child)
        if child.writing_mode == .Horizontal do continue
        if ai == .Baseline do first_base = max(first_base, box_vertical_baseline(child)+child.margin[3])
        if ai == .LastBaseline do last_descent = max(last_descent, child.w-box_vertical_baseline(child,true)+child.margin[1])
    }
    cy := soff
    for child, i in kids {
        cmt, cmb := node_margins(child)
        ai := item_cross_align(b, child) // align-self sobrescreve align-items
        ai = safe_align(ai, item_cross_safe(b, child), cw, cross[i] + child.margin[3] + child.margin[1])
        if b.flex_wrap_reverse {
            if ai == .Start { ai = .End } else if ai == .End { ai = .Start }
        }
        xoff := flex_align(ai, cw, cross[i] + child.margin[3] + child.margin[1])
        if ai == .Baseline && child.writing_mode != .Horizontal do xoff = first_base-box_vertical_baseline(child)-child.margin[3]
        if ai == .LastBaseline {
            xoff = cw-cross[i]-child.margin[3]-child.margin[1]
            if child.writing_mode != .Horizontal do xoff = cw-last_descent-box_vertical_baseline(child,true)-child.margin[3]
        }
        fw: f32 = cross[i] // largura já resolvida na pass A (stretch, % e min/max)
        if flex_col_stretch_w(b, child) {
            fw = stretch_clamp(child, .Row, max(0, cw-child.margin[3]-child.margin[1]), b.content_w)
            xoff = 0
        }
        py := b.flex_reverse ? (definite ? main_avail : used) - cy - finals[i] - cmt - cmb : cy
        if abs(fw - child.w) > 0.5 || (abs(finals[i] - child.h) > 0.5 && height_sensitive(child)) {
            layout_box(child, b.content_x + column_x + xoff, b.content_y + py, b.content_w, fw, finals[i])
        } else {
            translate_subtree(child, column_x + xoff, py)
            child.h = finals[i] // tamanho principal (altura) resolvido pelo flex
        }
        cy += finals[i] + cmt + cmb + between
    }
    return definite ? main_avail : used
}

// ── Grid layout ──────────────────────────────────────────────────────────────
// Subconjunto de CSS Grid: grid-template-columns E grid-template-rows (px/%/fr/
// auto, repeat(), repeat(auto-fill, minmax()), minmax()), posicionamento
// explícito (grid-column/grid-row: a/b, a/span N) + auto-placement por linha com
// matriz de ocupação, span de coluna E linha, gap/row-gap/column-gap, order.
// SEM áreas nomeadas, dense packing, grid-auto-rows explícito.

@(private="file")
layout_grid :: proc(b: ^Box, avail_h: f32 = -1) -> f32 {
    // itens em fluxo (absolute/fixed são posicionados no passe pós-layout), na
    // ordem visual (order)
    kids := flex_ordered_children(b, false)
    items := make([dynamic]^Box, context.temp_allocator)
    for c in kids {
        if c.pos == .Absolute || c.pos == .Fixed do continue
        append(&items, c)
    }
    n := len(items)
    // Sem item em fluxo o grid ainda tem as trilhas EXPLÍCITAS: elas dão altura
    // ao container e são as linhas contra as quais um filho absoluto se posiciona.
    // Só não há nada a fazer quando não existe nem trilha de linha nem absoluto.
    n_abs := 0
    for c in b.children do if (c.pos == .Absolute || c.pos == .Fixed) && !c.reparented do n_abs += 1
    if n == 0 && n_abs == 0 && b.grid_row_track_n == 0 do return 0

    cw      := b.content_w
    col_gap := b.gap
    row_gap := b.row_gap
    // subgrid: consome as trilhas impostas pelo pai (ver Box.sg_cols). Sem elas
    // (passe de medida das linhas, ou layout fora do pai) o eixo cai nas trilhas
    // `auto` que o compute_node deixou.
    imp_c := b.grid_sub_cols ? b.sg_cols : nil
    imp_r := b.grid_sub_rows ? b.sg_rows : nil
    b.sg_cols = nil; b.sg_rows = nil; b.sg_contrib = nil
    if b.grid_sub_cols && !b.has_gap_col do col_gap = b.sg_pgap[0]
    if b.grid_sub_rows && !b.has_gap_row do row_gap = b.sg_pgap[1]

    // altura de conteúdo do container: imposta pelo pai (item esticado) ou height
    // explícita. Governa % de linha, distribuição de fr e align-content.
    has_h := avail_h >= 0
    ch: f32 = has_h ? avail_h : 0

    // tracks de coluna primeiro (expande auto-fill); o placement precisa só do
    // nº de colunas, e a largura das colunas Auto depende de quais itens caem nelas.
    tracks := grid_track_list(b, cw, col_gap)
    if imp_c != nil {
        tracks = make([]Grid_Track, len(imp_c), context.temp_allocator)
        for &t in tracks do t = Grid_Track{kind = .Auto}
    }
    nc := len(tracks)
    // No fluxo por COLUNA sem grid-template-columns, TODA coluna é implícita —
    // o default de grid_track_list (1 trilha 1fr) engoliria a largura e deixaria
    // as implícitas com a sobra. Começa vazio e cresce no placement.
    if b.grid_flow_col && b.grid_track_n == 0 { tracks = tracks[:0]; nc = 0 }

    // grid-auto-flow: em `column` o fluxo desce pelas LINHAS do template e são as
    // COLUNAS que crescem (eixos trocados dentro de grid_place).
    n_primary := nc
    if b.grid_flow_col {
        n_primary = b.grid_row_track_n
        if n_primary < 1 do n_primary = 1
    }
    col_of, row_of, cspan_of, rspan_of := grid_place(items[:], n_primary, b.grid_flow_col, b.grid_flow_dense)
    grid_sub_clamp(b, nc, col_of, row_of, cspan_of, rspan_of)

    // colunas IMPLÍCITAS (só no fluxo por coluna, onde são a razão de ser da
    // prop): estendem a lista de trilhas ciclando grid-auto-columns. No fluxo por
    // linha o placement segue CLAMPANDO na grade explícita, como antes.
    if b.grid_flow_col && !b.grid_sub_cols {
        maxc := nc
        for i in 0 ..< n do maxc = max(maxc, col_of[i] + cspan_of[i])
        if maxc > nc {
            ext := make([]Grid_Track, maxc, context.temp_allocator)
            copy(ext, tracks)
            for c in nc ..< maxc {
                ext[c] = b.grid_auto_col_n > 0 ? b.grid_auto_cols[(c - nc) % b.grid_auto_col_n] : Grid_Track{kind = .Auto}
            }
            tracks = ext; nc = maxc
        }
    }

    nrows := b.grid_row_track_n
    for i in 0 ..< n do nrows = max(nrows, row_of[i] + rspan_of[i])
    // (sem item em fluxo não nasce linha implícita: grid-auto-rows não se aplica)
    if nrows < 1 && n > 0 do nrows = 1
    if imp_r != nil do nrows = len(imp_r)

    widths, xs: []f32
    if imp_c != nil {
        // colunas do pai: só desconta as bordas do próprio subgrid e o gutter
        xs, widths = grid_sub_tracks(imp_c, b.margin[3]+b.border_w[3]+b.padding[3], b.margin[1]+b.border_w[1]+b.padding[1], b.gap, b.has_gap_col)
    } else {
        // itens de um filho subgrid de COLUNAS dimensionam as trilhas DESTE grid
        // como se fossem itens dele (css-grid-2 §9); sem subgrid é a lista crua.
        fi, fc, fs, fx := grid_flatten_cols(items[:], col_of, cspan_of, col_gap)
        widths = grid_col_widths(tracks, cw, col_gap, fi, fc, fs, fx)
        // posições x das colunas — justify-content distribui a sobra horizontal
        xs = grid_track_positions(widths, col_gap, cw, b.justify, true, b.justify_ovf == .Unsafe)
    }

    row_h: []f32
    virt := make([dynamic]Grid_Contrib, context.temp_allocator)
    if imp_r != nil {
        _, row_h = grid_sub_tracks(imp_r, b.margin[0]+b.border_w[0]+b.padding[0], b.margin[2]+b.border_w[2]+b.padding[2], b.row_gap, b.has_gap_row)
    } else {
        row_h = grid_row_heights(b, items[:], widths, xs, col_of, cspan_of, row_of, rspan_of, nrows, col_gap, row_gap, ch, has_h, &virt)
    }
    column_first := make([]f32, nc, context.temp_allocator)
    column_last := make([]f32, nc, context.temp_allocator)
    baseline_first := make([]f32, nrows, context.temp_allocator)
    baseline_last := make([]f32, nrows, context.temp_allocator)
    baseline_descent := make([]f32, nrows, context.temp_allocator)
    last_ascent := make([]f32, nrows, context.temp_allocator)
    for it, i in items {
        if imp_r != nil do break // linhas impostas: nada cresce (e os itens ainda não foram dispostos)
        _, ai := grid_item_align(b, it)
        if ai != .Baseline && ai != .LastBaseline do continue
        r := row_of[i]
        asc := box_baseline(it, ai == .LastBaseline)
        if ai == .Baseline {
            baseline_first[r] = max(baseline_first[r], asc+it.margin[0])
            if rspan_of[i] == 1 do baseline_descent[r] = max(baseline_descent[r], it.h-asc+it.margin[2])
        } else {
            end := r+rspan_of[i]-1
            baseline_last[end] = max(baseline_last[end], it.h-asc+it.margin[2])
            if rspan_of[i] == 1 do last_ascent[end] = max(last_ascent[end], asc+it.margin[0])
        }
    }
    for r in 0 ..< nrows {
        fixed := imp_r != nil || (r < b.grid_row_track_n && (b.grid_row_tracks[r].kind == .Fixed || (has_h && b.grid_row_tracks[r].kind == .Pct)))
        if !fixed do row_h[r] = max(row_h[r], max(baseline_first[r]+baseline_descent[r], last_ascent[r]+baseline_last[r]))
    }
    // Cyclic percentages contribute as auto, then resolve against the intrinsic
    // content height without feeding the result back into that height.
    intrinsic_h := row_gap * f32(max(0, nrows-1))
    for h in row_h do intrinsic_h += h
    if !has_h && imp_r == nil {
        if b.row_gap_pct do row_gap = max(0, b.row_gap_frac*intrinsic_h+b.row_gap_off)
        for r in 0 ..< nrows {
            t := Grid_Track{kind = .Auto}
            if r < b.grid_row_track_n { t = b.grid_row_tracks[r] }
            else if b.grid_auto_row_n > 0 { t = b.grid_auto_rows[(r-b.grid_row_track_n) % b.grid_auto_row_n] }
            if t.kind == .Pct do row_h[r] = max(t.min_px, t.value * intrinsic_h)
        }
    }
    // posições y das linhas — align-content distribui a sobra vertical (só se height definida)
    row_y := grid_track_positions(row_h, row_gap, ch, b.align_content, has_h, b.align_content_ovf == .Unsafe)
    if imp_r != nil {
        row_y, row_h = grid_sub_tracks(imp_r, b.margin[0]+b.border_w[0]+b.padding[0], b.margin[2]+b.border_w[2]+b.padding[2], b.row_gap, b.has_gap_row)
    } else if b.grid_sub_rows {
        // passe de MEDIDA de um subgrid de linhas: publica o que cada item pede
        // às linhas, p/ o pai dimensionar as trilhas DELE (que são as nossas).
        out := make([dynamic]Grid_Contrib, context.temp_allocator)
        for it, i in items {
            if grid_is_sub(it, .Column) do continue // já expandido em `virt`
            append(&out, Grid_Contrib{row_of[i], rspan_of[i], it.h + it.margin[0] + it.margin[2]})
        }
        for v in virt do append(&out, v)
        b.sg_contrib = out[:]
    }

    // posiciona cada item na sua célula. Padrão = stretch (preenche a célula);
    // justify-items/align-items (ou -self por item) alinham dentro da célula.
    for it, i in items {
        sw := grid_extent(xs, widths, col_of[i], cspan_of[i])
        sh := grid_extent(row_y, row_h, row_of[i], rspan_of[i])
        cx := b.content_x + xs[col_of[i]]
        cy := b.content_y + row_y[row_of[i]]
        ji, ai := grid_item_align(b, it)
        // stretch (nos DOIS eixos) só quando o tamanho do item é AUTO — com width/
        // height definida ou intrínseca (min/max/fit-content) o item mantém o
        // próprio tamanho e é alinhado ao início da célula (stretch degrada p/ start),
        // como na spec. ⚠️ ANTES a largura era esticada SEMPRE (sem o guarda de
        // has_width que a altura já tinha) → item com width explícita colapsava à
        // trilha; e a força de largura ia como force_w=avail_w, forçando o tamanho
        // da célula por cima da width própria.
        // ⚠️ def_w (width do CSS), NÃO has_width: controles (input/textarea) ganham
        // has_width sintético (20 cols default) mesmo com width:auto — e DEVEM esticar.
        stretch_w := ji == .Stretch && !it.def_w && !it.width_mc
        stretch_h := ai == .Stretch && !it.has_height && !it.has_height_pct && !it.height_mc
        // subgrid: SEMPRE esticado no eixo subgridado — alinhamento e width/height
        // do item são ignorados ali (css-grid-2 §9), e a área inteira (margens
        // inclusive) é dele. As trilhas vão junto, antes do layout_box.
        sub_w, sub_h := grid_is_sub(it, .Row), grid_is_sub(it, .Column)
        if sub_w || sub_h {
            grid_sub_impose(it, sub_w ? xs : nil, widths, col_of[i], cspan_of[i], sub_h ? row_y : nil, row_h, row_of[i], rspan_of[i], col_gap, row_gap)
            sfw: f32 = sub_w ? max(0, sw - it.margin[3] - it.margin[1]) : ((it.def_w || it.width_mc) ? -1 : (stretch_w ? sw : min(measure_intrinsic_w(it), sw)))
            sfh: f32 = sub_h ? max(0, sh - it.margin[0] - it.margin[2]) : (stretch_h ? sh : -1)
            if !sub_w && sfw >= 0 do sfw = stretch_clamp(it, .Row, sfw, sw)
            if !sub_h && sfh >= 0 do sfh = stretch_clamp(it, .Column, sfh, sh)
            layout_box(it, cx, cy, sfw >= 0 ? sfw : sw, sfw, sfh, cb_h=sh)
            continue
        }
        // fw = largura FORÇADA: item com width definida → -1 (o box usa a própria
        // width e pode transbordar a célula); stretch → preenche a célula; senão
        // shrink-to-fit (max-content ∩ célula). avail_w é SEMPRE a célula (sw), p/
        // % de largura e filhos resolverem contra a trilha.
        fw: f32 = (it.def_w || it.width_mc) ? -1 : (stretch_w ? sw : min(measure_intrinsic_w(it), sw))
        fh: f32 = stretch_h ? sh : -1
        resolve_child_minmax_h(it, sh)
        if it.has_height_pct {
            fh = max(0,pct_resolve(it.height_pct,it.height_pct_off,sh,it.height_bd))
            if it.box_sizing == .Content do fh += it.padding[0]+it.padding[2]+bw_y(it)
        }
        // tamanho imposto pela célula é limitado por min/max (o caminho force_* do
        // layout_box não clampa). ⚠️ % de min/max-HEIGHT não chega resolvida aqui
        // (o grid não tem o resolve_child_minmax_h da linha flex) — px vale, % não.
        if fw >= 0 do fw = stretch_clamp(it, .Row, fw, sw)
        if fh >= 0 do fh = stretch_clamp(it, .Column, fh, sh)
        // assinatura: layout_box(b, x, y, avail_w, force_w, force_h). Para item de
        // tamanho DEFINIDO (fw=-1) o avail_w é a célula (sw), p/ % resolver contra a
        // trilha; para os demais o avail_w = a própria largura forçada (preserva o
        // comportamento base — controles de formulário dependem dele p/ o intrínseco).
        aw: f32 = (it.def_w || it.width_mc) ? sw : fw
        layout_box(it, cx, cy, aw, fw, fh, cb_h=sh)
    }
    // Rebuild baseline sharing groups after percentages and shrink-to-fit sizes
    // resolve. The measuring pass may have had different item dimensions.
    for r in 0 ..< nrows { baseline_first[r] = 0; baseline_last[r] = 0 }
    for c in 0 ..< nc { column_first[c] = 0; column_last[c] = 0 }
    for it, i in items {
        ji, ai := grid_item_align(b, it)
        if ai == .Baseline do baseline_first[row_of[i]] = max(baseline_first[row_of[i]],box_baseline(it)+it.margin[0])
        if ai == .LastBaseline {
            r := row_of[i]+rspan_of[i]-1
            baseline_last[r] = max(baseline_last[r],it.h-box_baseline(it,true)+it.margin[2])
        }
        if ji == .Baseline do column_first[col_of[i]] = max(column_first[col_of[i]],box_vertical_baseline(it)+it.margin[3])
        if ji == .LastBaseline {
            c := col_of[i]+cspan_of[i]-1
            column_last[c] = max(column_last[c],it.w-box_vertical_baseline(it,true)+it.margin[1])
        }
    }
    for it, i in items {
        sw := grid_extent(xs, widths, col_of[i], cspan_of[i])
        sh := grid_extent(row_y, row_h, row_of[i], rspan_of[i])
        ji, ai := grid_item_align(b, it)
        ji = safe_align(ji, (it.has_justify_self ? it.justify_self_ovf : b.justify_items_ovf) == .Safe, sw, it.w)
        ai = safe_align(ai, item_cross_safe(b, it), sh, it.h)
        stretch_w := ji == .Stretch && !it.def_w && !it.width_mc
        stretch_h := ai == .Stretch && !it.has_height && !it.has_height_pct && !it.height_mc
        if grid_is_sub(it, .Row)    { stretch_w = true; ji = .Stretch }
        if grid_is_sub(it, .Column) { stretch_h = true; ai = .Stretch }
        xoff: f32 = stretch_w ? 0 : flex_align(ji, sw, it.w)
        if ji == .Baseline do xoff = column_first[col_of[i]]-box_vertical_baseline(it)-it.margin[3]
        if ji == .LastBaseline do xoff = sw-column_last[col_of[i]+cspan_of[i]-1]-box_vertical_baseline(it,true)-it.margin[3]
        yoff: f32 = stretch_h ? 0 : flex_align(ai, sh, it.h)
        if ai == .Baseline do yoff = baseline_first[row_of[i]] - box_baseline(it) - it.margin[0]
        if ai == .LastBaseline do yoff = sh - baseline_last[row_of[i]+rspan_of[i]-1] - box_baseline(it, true) - it.margin[0]
        if xoff != 0 || yoff != 0 do translate_subtree(it, xoff, yoff)
    }

    total: f32 = 0
    for r in 0 ..< nrows do total += row_h[r]
    total += row_gap * f32(max(0, nrows - 1))

    // Filhos ABSOLUTOS (CSS Grid §9): não ocupam célula nem criam trilha, mas
    // grid-column/grid-row escolhem a ÁREA que lhes serve de bloco contenedor, e a
    // posição estática é alinhada por justify-self/align-self dentro dela.
    if n_abs > 0 {
        cont_h := has_h ? ch : intrinsic_h
        for c in b.children {
            if c.pos != .Absolute && c.pos != .Fixed do continue
            c.gabs_has = {}
            if c.reparented do continue // içada de um descendente: não é filha deste grid
            x0, x1, hx0, hx1 := grid_abs_axis(c.grid_col_start, c.grid_col_span, c.grid_col_start_auto, c.grid_col_end_auto, xs, widths)
            y0, y1, hy0, hy1 := grid_abs_axis(c.grid_row_start, c.grid_row_span, c.grid_row_start_auto, c.grid_row_end_auto, row_y, row_h)
            // a área só vale como bloco contenedor se o grid É o bloco contenedor
            // desta caixa (mesma regra de layout_absolutes_rec)
            is_cb := c.pos == .Absolute ? (b.pos != .Static || b.cb_abs) : b.cb_fixed
            if !is_cb { hx0 = false; hx1 = false; hy0 = false; hy1 = false }
            c.gabs = {x0, y0, x1, y1}
            c.gabs_has = {hx0, hy0, hx1, hy1}
            // posição estática: como item único de uma área — a área acima, ou o
            // content box do grid no lado em que a linha é auto.
            sx0: f32 = hx0 ? x0 : 0;  sx1: f32 = hx1 ? x1 : cw
            sy0: f32 = hy0 ? y0 : 0;  sy1: f32 = hy1 ? y1 : cont_h
            ji, ai := grid_item_align(b, c)
            c.has_static = true; c.static_flex = true
            c.static_x = b.content_x + sx0; c.static_y = b.content_y + sy0
            c.static_cw = max(0, sx1 - sx0); c.static_ch = max(0, sy1 - sy0)
            c.static_ax = align_off(ji); c.static_ay = align_off(ai)
        }
    }
    return has_h ? total : intrinsic_h
}

// ── subgrid (CSS Grid Level 2 §9) ────────────────────────────────────────────
// Um item de grid que é ele mesmo grid e declara `grid-template-columns/rows:
// subgrid` não tem trilhas próprias naquele eixo: usa as do pai que ele cobre.
// Duas metades: (1) os itens DELE dimensionam as trilhas do PAI (colunas:
// grid_flatten_cols; linhas: Grid_Contrib via passe de medida); (2) o pai IMPÕE
// a geometria pronta (grid_sub_impose → grid_sub_tracks no filho).
// `axis`: .Row = eixo inline (colunas), .Column = eixo de bloco (linhas).
Grid_Contrib :: struct { start, span: int, size: f32 }

@(private="file")
grid_is_sub :: proc(it: ^Box, axis: Flex_Dir) -> bool {
    if !it.is_grid || it.pos == .Absolute || it.pos == .Fixed do return false
    return axis == .Row ? it.grid_sub_cols : it.grid_sub_rows
}

// Subgrid não cria trilha implícita no eixo subgridado: o que passar é clampado.
@(private="file")
grid_sub_clamp :: proc(b: ^Box, nc: int, col_of, row_of, cspan_of, rspan_of: []int) {
    if b.grid_sub_cols && nc > 0 do for i in 0 ..< len(col_of) {
        cspan_of[i] = clamp(cspan_of[i], 1, nc)
        col_of[i] = clamp(col_of[i], 0, nc - cspan_of[i])
    }
    if nr := b.grid_row_track_n; b.grid_sub_rows && nr > 0 do for i in 0 ..< len(row_of) {
        rspan_of[i] = clamp(rspan_of[i], 1, nr)
        row_of[i] = clamp(row_of[i], 0, nr - rspan_of[i])
    }
}

// Itens em fluxo de `b` e o placement deles — o MESMO que o layout_grid de `b`
// vai calcular quando tiver `nc` colunas (é o que mantém pai e filho de acordo).
@(private="file")
grid_sub_place :: proc(b: ^Box, nc: int) -> (items: []^Box, col_of, cspan_of: []int) {
    list := make([dynamic]^Box, context.temp_allocator)
    for c in flex_ordered_children(b, false) {
        if c.pos == .Absolute || c.pos == .Fixed do continue
        append(&list, c)
    }
    n_primary := nc
    if b.grid_flow_col { n_primary = max(1, b.grid_row_track_n) }
    row_of, rspan_of: []int
    col_of, row_of, cspan_of, rspan_of = grid_place(list[:], n_primary, b.grid_flow_col, b.grid_flow_dense)
    grid_sub_clamp(b, nc, col_of, row_of, cspan_of, rspan_of)
    return list[:], col_of, cspan_of
}

// Troca cada filho subgrid-de-colunas pelos itens DELE (recursivo), nas colunas
// do grid de fora. `extra` = margem a mais por item: borda+padding+margem do
// subgrid nas pontas e meia diferença de gutter no miolo (pode ser negativa).
// Sem nenhum subgrid devolve as listas de entrada e extra=nil (caminho antigo).
@(private="file")
grid_flatten_cols :: proc(items: []^Box, col_of, cspan_of: []int, gap: f32) -> (fi: []^Box, fc, fs: []int, fx: []f32) {
    any := false
    for it in items do if grid_is_sub(it, .Row) { any = true; break }
    if !any do return items, col_of, cspan_of, nil
    oi := make([dynamic]^Box, context.temp_allocator)
    oc := make([dynamic]int, context.temp_allocator)
    os := make([dynamic]int, context.temp_allocator)
    ox := make([dynamic]f32, context.temp_allocator)
    for it, i in items do grid_flatten_rec(&oi, &oc, &os, &ox, it, col_of[i], cspan_of[i], 0, 0, gap, gap, 0)
    return oi[:], oc[:], os[:], ox[:]
}

@(private="file")
grid_flatten_rec :: proc(oi: ^[dynamic]^Box, oc, os: ^[dynamic]int, ox: ^[dynamic]f32, it: ^Box, c0, span: int, acc_l, acc_r, root_gap, parent_gap: f32, depth: int) {
    if !grid_is_sub(it, .Row) || depth > 8 {
        append(oi, it); append(oc, c0); append(os, span); append(ox, acc_l + acc_r)
        return
    }
    eff := it.has_gap_col ? it.gap : parent_gap
    half := (eff - root_gap) / 2
    el := acc_l + it.margin[3] + it.border_w[3] + it.padding[3]
    er := acc_r + it.margin[1] + it.border_w[1] + it.padding[1]
    kids, kc, ks := grid_sub_place(it, span)
    for k, i in kids {
        l := kc[i] == 0 ? el : half
        r := kc[i] + ks[i] >= span ? er : half
        grid_flatten_rec(oi, oc, os, ox, k, c0 + kc[i], ks[i], l, r, root_gap, eff, depth + 1)
    }
}

// Pai → filho: [lo, hi] de cada trilha coberta, relativas ao início da área.
// pos nil num eixo = não impõe aquele eixo.
@(private="file")
grid_sub_impose :: proc(it: ^Box, xs, widths: []f32, c0, cs: int, ys, heights: []f32, r0, rs: int, col_gap, row_gap: f32) {
    cut :: proc(pos, sizes: []f32, i0, span: int) -> [][2]f32 {
        e := min(i0 + span, len(sizes))
        if pos == nil || e <= i0 do return nil
        out := make([][2]f32, e - i0, context.temp_allocator)
        for k in i0 ..< e do out[k - i0] = {pos[k] - pos[i0], pos[k] - pos[i0] + sizes[k]}
        return out
    }
    it.sg_pgap = {col_gap, row_gap}
    it.sg_cols = cut(xs, widths, c0, cs)
    it.sg_rows = cut(ys, heights, r0, rs)
}

// Filho: trilhas do pai → posições/tamanhos no content box do subgrid. As pontas
// perdem margem+borda+padding do subgrid; no miolo, um gutter próprio diferente
// do do pai fica CENTRADO no gutter do pai (a trilha ganha/perde meia diferença).
@(private="file")
grid_sub_tracks :: proc(imp: [][2]f32, edge_lo, edge_hi, own_gap: f32, has_gap: bool) -> (pos, sizes: []f32) {
    n := len(imp)
    pos = make([]f32, n + 1, context.temp_allocator)
    sizes = make([]f32, n, context.temp_allocator)
    if n == 0 do return
    area := imp[n - 1][1]
    for k in 0 ..< n {
        lo := edge_lo
        if k > 0 {
            g := has_gap ? own_gap : imp[k][0] - imp[k - 1][1]
            lo = (imp[k - 1][1] + imp[k][0]) / 2 + g / 2
        }
        hi := area - edge_hi
        if k < n - 1 {
            g := has_gap ? own_gap : imp[k + 1][0] - imp[k][1]
            hi = (imp[k][1] + imp[k + 1][0]) / 2 - g / 2
        }
        pos[k] = lo - edge_lo
        sizes[k] = max(0, hi - lo)
    }
    pos[n] = pos[n - 1] + sizes[n - 1]
    return
}

// Bordas de um eixo da área de um filho ABSOLUTO do grid, relativas ao content
// box. `has_*` falso = linha auto (ou que não existe na grade) → quem chama usa a
// borda do container. `pos`/`sizes` = posição e tamanho de cada trilha do eixo.
// A linha k vista como FIM de área fica ANTES do gap (fim da trilha k-1); como
// INÍCIO fica depois dele (início da trilha k).
@(private="file")
grid_abs_axis :: proc(start, span: int, start_auto, end_auto: bool, pos, sizes: []f32) -> (lo, hi: f32, has_lo, has_hi: bool) {
    n := len(sizes)
    if start <= 0 || n == 0 do return // auto, ou só `span N`: as duas bordas são do container
    s := start - 1         // linha de início, 0-based (0..n)
    e := s + max(1, span)  // linha de fim
    if !start_auto && s <= n { lo = s == n ? pos[n - 1] + sizes[n - 1] : pos[s]; has_lo = true }
    if !end_auto && e <= n   { hi = pos[e - 1] + sizes[e - 1]; has_hi = true }
    if has_lo && has_hi && hi < lo do hi = lo
    return
}

// Coloca os itens numa grade de nc colunas: honra grid-column/grid-row explícitos
// (start 1-based) e auto-posiciona o resto por linha (row flow, packing esparso)
// usando uma matriz de ocupação p/ não sobrepor. Devolve col/row/colspan/rowspan.
@(private="file")
grid_place :: proc(items: []^Box, n_primary: int, flow_col := false, dense := false) -> (col_of, row_of, cspan_of, rspan_of: []int) {
    n := len(items)
    col_of  = make([]int, n, context.temp_allocator)
    row_of  = make([]int, n, context.temp_allocator)
    cspan_of = make([]int, n, context.temp_allocator)
    rspan_of = make([]int, n, context.temp_allocator)
    // Eixos GENÉRICOS: `a` = eixo do fluxo (limitado a n_primary), `b` = o que
    // cresce. Fluxo por linha: a=coluna, b=linha. Por coluna: TROCADOS — assim o
    // mesmo algoritmo de packing serve aos dois, sem duplicar a matriz de ocupação.
    nc := n_primary

    occ := make(map[[2]int]bool, 0, context.temp_allocator)
    fits := proc(occ: ^map[[2]int]bool, r, c, cs, rs: int) -> bool {
        for rr in r ..< r + rs do for cc in c ..< c + cs do if occ[{rr, cc}] do return false
        return true
    }
    mark := proc(occ: ^map[[2]int]bool, r, c, cs, rs: int) {
        for rr in r ..< r + rs do for cc in c ..< c + cs do occ[{rr, cc}] = true
    }

    cur_r, cur_c := 0, 0
    for it, i in items {
        cs := (flow_col ? it.grid_row_span : it.grid_col_span); if cs < 1 do cs = 1; if cs > nc do cs = nc
        rs := (flow_col ? it.grid_col_span : it.grid_row_span); if rs < 1 do rs = 1
        ec := flow_col ? it.grid_row_start : it.grid_col_start // 1-based; 0 = auto
        er := flow_col ? it.grid_col_start : it.grid_row_start
        c, r: int

        if ec > 0 { // coluna explícita
            c = clamp(ec - 1, 0, max(0, nc - cs))
            if er > 0 {
                r = er - 1
            } else { // coluna fixa, linha automática: 1ª linha livre nessa coluna
                r = 0
                for !fits(&occ, r, c, cs, rs) do r += 1
            }
        } else if er > 0 { // linha explícita, coluna automática
            r = er - 1
            c = 0
            for c + cs <= nc && !fits(&occ, r, c, cs, rs) do c += 1
            if c + cs > nc do c = max(0, nc - cs)
        } else { // ambos automáticos: avança a partir do cursor
            // `dense` recomeça a busca na ORIGEM a cada item, tampando os buracos
            // deixados por itens posicionados/de span grande (packing denso).
            r = dense ? 0 : cur_r; c = dense ? 0 : cur_c
            for {
                if c + cs > nc { r += 1; c = 0 }
                if fits(&occ, r, c, cs, rs) do break
                c += 1
            }
        }

        mark(&occ, r, c, cs, rs)
        if flow_col { col_of[i] = r; row_of[i] = c; cspan_of[i] = rs; rspan_of[i] = cs }
        else        { col_of[i] = c; row_of[i] = r; cspan_of[i] = cs; rspan_of[i] = rs }
        // packing esparso: o cursor só avança (dense não o usa)
        if ec == 0 && er == 0 && !dense { cur_r = r; cur_c = c + cs }
    }
    when GRID_DEBUG {
        if nc >= 4 do for it, i in items {
            fmt.eprintf("[gplace] nc=%d item%d col_start=%d span=%d -> col=%d\n", nc, i, it.grid_col_start, it.grid_col_span, col_of[i])
        }
    }
    return
}

// Altura de cada linha: base das grid-template-rows (px/%/min de minmax), depois
// o conteúdo dos itens (nas linhas auto/implícitas), depois distribui fr se o
// container tem altura explícita.
@(private="file")
grid_row_heights :: proc(b: ^Box, items: []^Box, widths, xs: []f32, col_of, cspan_of, row_of, rspan_of: []int, nrows: int, col_gap, row_gap: f32, ch: f32, has_h: bool, virt: ^[dynamic]Grid_Contrib = nil) -> []f32 {
    row_h := make([]f32, nrows, context.temp_allocator)
    is_fr := make([]bool, nrows, context.temp_allocator)

    // Trilha efetiva de cada linha: explícita (grid-template-rows) enquanto houver,
    // depois IMPLÍCITA ciclando grid-auto-rows. Sem grid-auto-rows a implícita fica
    // .Auto — exatamente o comportamento anterior (linha cresce pelo conteúdo).
    trk := make([]Grid_Track, nrows, context.temp_allocator)
    for r in 0 ..< nrows {
        // ⚠️ o DEFAULT tem de ser .Auto EXPLÍCITO: o zero-value do enum é .Fixed,
        // e uma linha implícita "fixa" nunca é engordada pelo conteúdo → grid sem
        // grid-template-rows/grid-auto-rows (o caso MAIS comum) colapsava p/ h=0.
        trk[r] = Grid_Track{kind = .Auto}
        if r < b.grid_row_track_n do trk[r] = b.grid_row_tracks[r]
        else if b.grid_auto_row_n > 0 do trk[r] = b.grid_auto_rows[(r - b.grid_row_track_n) % b.grid_auto_row_n]
    }

    // base pelas trilhas
    fr_total: f32 = 0
    for r in 0 ..< nrows {
        t := trk[r]
        switch t.kind {
        case .Fixed: row_h[r] = t.value
        case .Pct:   row_h[r] = t.value * ch
        case .Fr:    is_fr[r] = true; fr_total += t.value
        case .Auto:
        }
        if t.min_px > row_h[r] do row_h[r] = t.min_px
    }

    // conteúdo: mede cada item e engorda as linhas auto/implícitas até caber
    sub_spans := make([dynamic]Grid_Contrib, context.temp_allocator) // itens de subgrid com span > 1
    for it, i in items {
        sw := grid_extent(xs, widths, col_of[i], cspan_of[i])
        // A linha precisa da altura na largura USADA do item. Forçar a trilha
        // em width:min-content media uma linha só; na pintura o item estreitava,
        // quebrava em várias linhas e sobrepunha a próxima linha do grid.
        fw: f32 = (it.def_w || it.width_mc) ? -1 : sw
        r0 := row_of[i]; rs := rspan_of[i]
        if sub_w, sub_h := grid_is_sub(it, .Row), grid_is_sub(it, .Column); sub_w || sub_h {
            // colunas impostas já aqui (a altura dos itens depende delas); linhas
            // ainda não existem — o filho mede e devolve o que cada item pede.
            grid_sub_impose(it, sub_w ? xs : nil, widths, col_of[i], cspan_of[i], nil, nil, 0, 0, col_gap, row_gap)
            if sub_w do fw = max(0, sw - it.margin[3] - it.margin[1])
            layout_box(it, b.content_x, b.content_y, fw >= 0 ? fw : sw, fw, -1)
            if sub_h {
                eff := it.has_gap_row ? it.row_gap : row_gap
                half := (eff - row_gap) / 2
                for c in it.sg_contrib {
                    top := c.start == 0 ? it.margin[0] + it.border_w[0] + it.padding[0] : half
                    bot := c.start + c.span >= rs ? it.margin[2] + it.border_w[2] + it.padding[2] : half
                    v := Grid_Contrib{r0 + c.start, min(c.span, nrows - r0 - c.start), c.size + top + bot}
                    if v.start >= nrows || v.span < 1 do continue
                    if virt != nil do append(virt, v)
                    if v.span == 1 {
                        t := trk[v.start]
                        fixed := t.kind == .Fixed || (t.kind == .Pct && has_h)
                        if !fixed do row_h[v.start] = max(row_h[v.start], v.size)
                    } else {
                        append(&sub_spans, v)
                    }
                }
                it.sg_contrib = nil
                continue
            }
        } else {
            layout_box(it, b.content_x, b.content_y, sw, fw, -1)
        }
        if rs > 1 do continue
        if rs == 1 && is_fr[r0] && has_h {
            t := trk[r0]
            floor: f32 = 0
            switch t.min_kind {
            case .Auto:
                if it.has_minh { floor = it.minh } else if !it.scroll_container { floor = it.h }
            case .MinContent, .MaxContent: floor = it.h
            case .Fixed, .FitContent:
            }
            row_h[r0] = max(row_h[r0], floor + it.margin[0] + it.margin[2])
        }
        cur := grid_span_gap(row_h, r0, rs, row_gap)
        if it.h + it.margin[0] + it.margin[2] > cur {
            // Definite fixed/flexible tracks retain their sizes. Intrinsic tracks
            // share the spanning contribution after shorter spans have settled.
            count := 0
            for rr := r0; rr < min(r0 + rs, nrows); rr += 1 {
                fixed := trk[rr].kind == .Fixed || (trk[rr].kind == .Pct && has_h) || (is_fr[rr] && has_h)
                if !fixed do count += 1
            }
            if count > 0 {
                deficit := (it.h + it.margin[0] + it.margin[2] - cur) / f32(count)
                for rr := r0; rr < min(r0 + rs, nrows); rr += 1 {
                    fixed := trk[rr].kind == .Fixed || (trk[rr].kind == .Pct && has_h) || (is_fr[rr] && has_h)
                    if !fixed do row_h[rr] += max(0, deficit)
                }
            }
        }
    }

    // §12.7.1 "Find the Size of an fr", ramo de espaço livre INDEFINIDO: a fração
    // usada é o MAIOR (base ÷ fator) entre as trilhas flexíveis (fator ≤ 1 usa a
    // base crua), e cada `fr` fica em fração×fator, com piso na própria base. Com
    // uma única linha `fr` isto é a identidade (ela já cresceu pelo conteúdo);
    // com `1fr 2fr` é o que faz a segunda ficar o dobro da primeira.
    for span in 2 ..= nrows {
        planned := make([]f32,nrows,context.temp_allocator)
        for it, i in items {
            if rspan_of[i] != span do continue
            start := row_of[i]
            count := min(span,nrows-start)
            values := make([]f32,count,context.temp_allocator)
            limits := make([]f32,count,context.temp_allocator)
            weights := make([]f32,count,context.temp_allocator)
            has_fr := false
            for r in start ..< start+count do has_fr = has_fr || is_fr[r]
            for j in 0 ..< count {
                r := start+j; t := trk[r]
                values[j] = row_h[r]; limits[j] = values[j]
                eligible := has_fr ? is_fr[r] && !has_h && t.min_kind != .Fixed : t.kind == .Auto || (t.kind == .Pct && !has_h)
                if eligible { limits[j] = FLT_MAX; weights[j] = has_fr ? t.value : 1 }
            }
            need := it.h+it.margin[0]+it.margin[2]-row_gap*f32(count-1)
            grid_grow_span(values,limits,weights,need)
            for j in 0 ..< count do planned[start+j] = max(planned[start+j],values[j]-row_h[start+j])
        }
        for r in 0 ..< nrows do row_h[r] += planned[r]
    }

    // itens de SUBGRID que atravessam linhas: o que faltar é repartido por igual
    // entre as linhas não fixas cobertas (depois dos spans dos itens diretos).
    for v in sub_spans {
        cur := grid_span_gap(row_h, v.start, v.span, row_gap)
        if v.size <= cur do continue
        count := 0
        for rr in v.start ..< v.start + v.span {
            if !(trk[rr].kind == .Fixed || (trk[rr].kind == .Pct && has_h) || (is_fr[rr] && has_h)) do count += 1
        }
        if count == 0 do continue
        for rr in v.start ..< v.start + v.span {
            if !(trk[rr].kind == .Fixed || (trk[rr].kind == .Pct && has_h) || (is_fr[rr] && has_h)) do row_h[rr] += (v.size - cur) / f32(count)
        }
    }

    if !has_h && fr_total > 0 {
        frac: f32 = 0
        for r in 0 ..< nrows do if is_fr[r] {
            f := trk[r].value
            frac = max(frac, f > 1 ? row_h[r] / f : row_h[r])
        }
        for r in 0 ..< nrows do if is_fr[r] {
            row_h[r] = max(row_h[r], frac * trk[r].value)
        }
    }

    // Definite rows use the same frozen-base fraction calculation as columns.
    if has_h && fr_total > 0 {
        grid_resolve_fr(trk, row_h, ch - row_gap * f32(max(0, nrows - 1)))
    }

    // §11.8 "Stretch auto Tracks": com altura DEFINIDA e align-content normal/stretch,
    // as trilhas de max-sizing AUTO dividem a sobra positiva igualmente (preenchem o
    // container). Sem isso, um grid com altura definida e linha `auto` deixava a linha
    // no tamanho do conteúdo e a sobra vazia embaixo (o item não preenchia). Fr já
    // consumiu a sobra acima, então quando há fr o leftover aqui é 0 (não colidem).
    if has_h && b.ac_stretch {
        used := row_gap * f32(max(0, nrows - 1))
        n_auto := 0
        for r in 0 ..< nrows {
            used += row_h[r]
            if trk[r].kind == .Auto do n_auto += 1
        }
        if leftover := ch - used; leftover > 0 && n_auto > 0 {
            add := leftover / f32(n_auto)
            for r in 0 ..< nrows do if trk[r].kind == .Auto do row_h[r] += add
        }
    }
    return row_h
}

// Alinhamento efetivo de um item de grid na célula: justify-self/align-self do
// item (se definidos) sobrescrevem justify-items/align-items do container.
@(private="file")
grid_item_align :: proc(b, it: ^Box) -> (ji, ai: Flex_Align) {
    ji = it.has_justify_self ? it.justify_self : b.justify_items
    ai = it.has_align_self   ? it.align_self   : b.align_items
    return
}

// Soma dos tamanhos de [i, i+span) com os gaps internos (base p/ dimensionar linhas
// antes de saber a distribuição de align-content).
@(private="file")
grid_span_gap :: proc(sizes: []f32, i, span: int, gap: f32) -> f32 {
    s: f32 = 0
    e := min(i + span, len(sizes))
    for k in i ..< e do s += sizes[k]
    s += gap * f32(max(0, e - i - 1))
    return s
}

// Extensão (border-box) de uma célula que ocupa [i, i+span) trilhas, a partir das
// POSIÇÕES já resolvidas (inclui os gaps reais entre trilhas, mesmo com
// justify/align-content). pos[k] = início da trilha k.
@(private="file")
grid_extent :: proc(pos, sizes: []f32, i, span: int) -> f32 {
    e := min(i + span, len(sizes))
    if e <= i do return 0
    return pos[e - 1] + sizes[e - 1] - pos[i]
}

// Offsets de cada trilha aplicando justify-content (colunas) / align-content
// (linhas) quando há sobra no eixo. Devolve pos[n+1] (pos[i] = início da trilha i).
@(private="file")
grid_track_positions :: proc(sizes: []f32, gap, container: f32, dist: Flex_Just, distribute: bool, unsafe := false) -> []f32 {
    n := len(sizes)
    pos := make([]f32, n + 1, context.temp_allocator)
    off, between: f32 = 0, gap
    if distribute && n > 0 {
        used := gap * f32(max(0, n - 1))
        for s in sizes do used += s
        free := container - used
        if free > 0 || unsafe do off, between = flex_justify(dist, free, gap, n, unsafe)
    }
    pos[0] = off
    for i in 0 ..< n do pos[i + 1] = pos[i] + sizes[i] + between
    return pos
}

// Lista de tracks de coluna: expande repeat(auto-fill/auto-fit) conforme cabe na
// Piso efetivo de uma trilha: o maior entre o mínimo em px e o mínimo em % já
// resolvido contra a largura do container.
@(private="file")
track_min :: proc(t: Grid_Track, cw: f32) -> f32 {
    m := t.min_px
    if t.min_pct > 0 && cw > 0 {
        if p := t.min_pct * cw; p > m do m = p
    }
    return m
}

// largura. Sem colunas explícitas => uma única coluna flexível (1fr => cw).
@(private="file")
grid_track_list :: proc(b: ^Box, cw, col_gap: f32) -> []Grid_Track {
    if b.grid_track_n == 0 {
        t := make([]Grid_Track, 1, context.temp_allocator)
        t[0] = Grid_Track{kind = .Fr, value = 1}
        return t
    }
    if b.grid_auto_fill {
        pat   := b.grid_tracks[0]
        minsz := track_min(pat, cw) // inclui o mínimo em % (auto-fit responsivo)
        if minsz <= 0 do minsz = pat.kind == .Fixed ? pat.value : 120
        count := int((cw + col_gap) / (minsz + col_gap))
        if count < 1  do count = 1
        if count > 64 do count = 64
        t := make([]Grid_Track, count, context.temp_allocator)
        for i in 0 ..< count do t[i] = pat
        return t
    }
    return b.grid_tracks[:b.grid_track_n]
}

// Water-fill a spanning contribution, freezing tracks at growth limits.
@(private="file")
grid_grow_span :: proc(values, limits, weights: []f32, need: f32) {
    for pass in 0 ..= len(values) {
        used, weight: f32
        for v in values do used += v
        for w, i in weights do if values[i]+0.001 < limits[i] do weight += w
        remaining := need-used
        if remaining <= 0.001 || weight <= 0 do break
        for w, i in weights {
            if values[i]+0.001 < limits[i] do values[i] = min(limits[i], values[i]+remaining*w/weight)
        }
    }
}

// Resolve a largura de cada coluna. Sempre ao menos 1 coluna.
@(private="file")
grid_col_widths :: proc(tracks: []Grid_Track, cw, col_gap: f32, items: []^Box, col_of, cspan_of: []int, extra: []f32 = nil) -> []f32 {
    nc := len(tracks)
    widths := make([]f32, nc, context.temp_allocator)

    // Intrinsic maxima and minima are independent. An fr track starts at its
    // content-based automatic minimum; minmax(0,fr) explicitly disables it.
    auto_w := make([]f32, nc, context.temp_allocator)
    floors := make([]f32, nc, context.temp_allocator)
    for t, i in tracks do floors[i] = track_min(t, cw)
    for it, k in items {
        c := col_of[k]
        if c < 0 || c >= nc do continue
        if cspan_of[k] == 1 {
            t := tracks[c]
            margins := it.margin[3] + it.margin[1] + (extra != nil ? extra[k] : 0)
            minimum := grid_item_min_w(it, t, cw) + margins
            if t.kind == .Fr || t.kind == .Auto || t.de_minmax do floors[c] = max(floors[c], minimum)
            if t.kind == .Auto {
                w := measure_intrinsic_w(it, t.max_kind == .MinContent) + margins
                if t.max_kind == .FitContent {
                    cap := t.fit_pct ? t.value * cw : t.value
                    w = min(w, cap)
                }
                auto_w[c] = max(auto_w[c], max(w, floors[c]))
            }
        }
    }

    // Spans of equal length read the same bases, so DOM order cannot change
    // the result. Flexible spans grow only fr tracks, in their factor ratios.
    for span in 2 ..= nc {
        planned_min := make([]f32, nc, context.temp_allocator)
        planned_max := make([]f32, nc, context.temp_allocator)
        for it, k in items {
            if cspan_of[k] != span do continue
            start := col_of[k]
            if start < 0 || start+span > nc do continue
            has_fr := false
            for j in start ..< start+span do has_fr = has_fr || tracks[j].kind == .Fr
            for maximum in 0 ..< 2 {
                values := make([]f32, span, context.temp_allocator)
                limits := make([]f32, span, context.temp_allocator)
                weights := make([]f32, span, context.temp_allocator)
                for j in 0 ..< span {
                    idx := start+j; t := tracks[idx]
                    values[j] = maximum == 1 ? max(auto_w[idx], floors[idx]) : floors[idx]
                    limits[j] = values[j]
                    if t.kind == .Fixed { values[j] = max(t.value, floors[idx]); limits[j] = values[j] }
                    if t.kind == .Pct { values[j] = max(t.value*cw, floors[idx]); limits[j] = values[j] }
                    eligible := has_fr ? t.kind == .Fr && t.min_kind != .Fixed : t.kind == .Auto && (maximum == 1 || t.min_kind != .Fixed)
                    if eligible {
                        weights[j] = has_fr ? max(0, t.value) : 1
                        limits[j] = FLT_MAX
                        if maximum == 1 && t.max_kind == .FitContent do limits[j] = max(values[j], t.fit_pct ? t.value*cw : t.value)
                    }
                }
                need := measure_intrinsic_w(it, maximum == 0) + it.margin[3]+it.margin[1] + (extra != nil ? extra[k] : 0) - col_gap*f32(span-1)
                // Automatic minimum vanishes for multi-track flexible spans.
                if has_fr && maximum == 0 && !it.has_minw do continue
                if has_fr && maximum == 1 do continue // definite fr space is resolved below
                before := make([]f32, span, context.temp_allocator); copy(before, values)
                grid_grow_span(values, limits, weights, need)
                for j in 0 ..< span {
                    idx := start+j
                    if maximum == 0 { planned_min[idx] = max(planned_min[idx], values[j]-before[j]) }
                    else { planned_max[idx] = max(planned_max[idx], values[j]-before[j]) }
                }
            }
        }
        for j in 0 ..< nc {
            floors[j] += planned_min[j]
            auto_w[j] = max(floors[j], auto_w[j]+planned_max[j])
        }
    }

    fixed_sum, fr_total: f32 = 0, 0
    for t, i in tracks {
        switch t.kind {
        case .Fixed: fixed_sum += t.value
        case .Pct:   fixed_sum += t.value * cw
        case .Auto:  aw := max(auto_w[i], track_min(t, cw)); widths[i] = aw; fixed_sum += aw
        case .Fr:    fr_total  += t.value
        }
    }
    leftover := cw - fixed_sum - col_gap * f32(nc - 1)
    if leftover < 0 do leftover = 0

    for t, i in tracks {
        switch t.kind {
        case .Fixed: widths[i] = t.value
        case .Pct:   widths[i] = t.value * cw
        case .Fr:    widths[i] = fr_total > 0 ? leftover * t.value / fr_total : 0
        case .Auto:  // já dimensionado pelo conteúdo acima
        }
        if m := floors[i]; widths[i] < m do widths[i] = m
        if widths[i] < 0        do widths[i] = 0
    }

    // Trilhas .Auto (auto/min-content/max-content e o lado MAX de um minmax) eram
    // fixadas no max-content SEM teto: um título longo dava uma trilha de 610px num
    // container de 579 e o item vazava. A spec resolve isso em duas etapas — a base é
    // a função de MÍNIMO e o max-content é só um LIMITE DE CRESCIMENTO, alcançável
    // apenas com espaço livre. Sem espaço livre a trilha fica na base.
    //
    // Aqui o efeito é o mesmo pelo outro lado: se o total estoura, devolve o excesso
    // das trilhas .Auto proporcionalmente ao quanto cada uma pode ceder (do
    // max-content até seu piso). Texto reflui na largura menor; não há corte.
    total := col_gap * f32(nc - 1)
    for w in widths do total += w
    if excess := total - cw; excess > 0.01 && cw > 0 {
        give := make([]f32, nc, context.temp_allocator)
        give_total: f32 = 0
        for t, i in tracks {
            // .Auto: o max-content é limite de crescimento (ver acima).
            // de_minmax: o `max` de um minmax() é limite de crescimento pela MESMA
            // razão (Grid §12.6) — a trilha nasce na função de MÍNIMO e só cresce
            // com espaço livre. Sem isto, `minmax(0, 1536px)` numa grade de 1280
            // virava 1536 fixos e transbordava (tailwindcss.com).
            // ⚠️ trilha de tamanho ÚNICO (`500px`, `40%`) NÃO cede: ali o autor
            // pediu a largura, e transbordar é o comportamento certo.
            if t.kind != .Auto && !t.de_minmax do continue
            if g := widths[i] - floors[i]; g > 0 { give[i] = g; give_total += g }
        }
        if give_total > 0 {
            cut := min(excess, give_total)
            for i in 0 ..< nc {
                if give[i] > 0 do widths[i] -= cut * give[i] / give_total
            }
        }
    }
    // Recompute the flex fraction after non-flex tracks have settled. Floors
    // freeze tracks before distributing the remainder, rather than adding overflow.
    for t, i in tracks do if t.kind == .Fr do widths[i] = floors[i]
    grid_resolve_fr(tracks, widths, cw - col_gap * f32(nc - 1))
    when GRID_DEBUG {
        if nc >= 4 {
            fmt.eprintf("[grid] cw=%.0f nc=%d gap=%.0f leftover=%.0f tracks=[", cw, nc, col_gap, leftover)
            for t in tracks do fmt.eprintf("%v:%.2f(min%.0f) ", t.kind, t.value, t.min_px)
            fmt.eprintf("] widths=[")
            for w in widths do fmt.eprintf("%.0f ", w)
            fmt.eprintln("]")
        }
    }
    return widths
}

// Single-track minimum contribution. Explicit intrinsic minima apply even with
// overflow:hidden; only the automatic minimum is disabled by scrollability.
@(private="file")
grid_item_min_w :: proc(it: ^Box, t: Grid_Track, cw: f32) -> f32 {
    if (t.kind == .Fixed || t.kind == .Pct) && !t.de_minmax do return 0
    switch t.min_kind {
    case .Fixed, .FitContent: return 0
    case .MinContent: return measure_intrinsic_w(it, true)
    case .MaxContent: return measure_intrinsic_w(it)
    case .Auto:
        lo, hi := box_min_max_axis(it, .Row, cw)
        if it.has_minw do return lo
        if it.scroll_container do return 0
        cbm := flex_auto_min_w(it, cw)
        if it.has_width && !it.width_pct {
            ew := it.padding[3] + it.padding[1] + bw_x(it)
            cbm = it.box_sizing == .Border ? it.width : it.width + ew
        }
        if t.de_minmax && t.kind == .Fixed do hi = min(hi, max(t.value, track_min(t, cw)))
        return min(cbm, hi)
    }
    return 0
}
// Grid §12.7.1: find an fr size, freezing tracks whose base exceeds their share.
// widths contains the resolved bases/non-flex sizes. Gaps are already excluded.
@(private="file")
grid_resolve_fr :: proc(tracks: []Grid_Track, widths: []f32, available: f32) {
    frozen := make([]bool, len(tracks), context.temp_allocator)
    for t, i in tracks do frozen[i] = t.kind != .Fr || t.value <= 0
    for pass in 0 ..= len(tracks) {
        remaining := available
        factors: f32 = 0
        for t, i in tracks {
            if frozen[i] { remaining -= widths[i] } else { factors += t.value }
        }
        fraction := max(0, remaining) / max(1, factors)
        changed := false
        for t, i in tracks {
            if frozen[i] do continue
            floor := widths[i]
            if floor > fraction * t.value {
                frozen[i] = true
                changed = true
            }
        }
        if changed do continue
        for t, i in tracks do if !frozen[i] do widths[i] = fraction * t.value
        break
    }
}

GRID_DEBUG :: #config(GRID_DEBUG, false)
// Sonda da posição ESTÁTICA de absolutos (-define:ABS_DEBUG=true). Custo zero off.
ABS_DEBUG :: #config(ABS_DEBUG, false)

// Sonda de vazamento do lado C no laço de render (ver headless.odin). Off por padrão.
LEAK_PROBE :: #config(LEAK_PROBE, false)

// ── perfil do laço de FRAME (compile-gated: `-define:UIPROF=true`) ───────────
// Irmão do JSPROF do lado do motor de JS. O JSPROF mostrou que a interpretação
// explica ~11,7s de uma execução de 28,5s no spotify; isto mede o RESTO — e
// separa TRABALHO de ESPERA, que é a distinção que decide onde otimizar.
UIPROF :: #config(UIPROF, false)

when UIPROF {
    Ui_Prof :: struct {
        frames:      int,
        ms_jobs:     f64, // poll_jobs (rede/fetch)
        ms_imagens:  f64, // images_poll (decode + upload de textura)
        ms_js:       f64, // vm_pump_timers: callbacks de timer
        ms_fp:       f64, // fingerprint do DOM (roda TODO frame, é O(nós))
        ms_restyle:  f64, // compute_styles + build_layout quando o DOM mudou
        ms_layout:   f64, // layout_box + layout_absolutes
        ms_paint:    f64, // paint_layout (monta a lista de comandos)
        ms_render:   f64, // im.Render + RenderDrawData + Present (lado SDL/GPU)
        ms_delay:    f64, // sdl2.Delay: ESPERA pura, não trabalho
        restyles:    int,
        // ── S1: dissecção do paint (a linha nº 1 medida em 2026-08-02) ──────
        // `ms_paint` acima é a soma dos dois abaixo. A pergunta que eles
        // respondem: o custo está em MONTAR a lista de comandos (record) ou em
        // GERAR os vértices a partir dela (replay)? A resposta decide onde o
        // culling é barato e se o tamanho da união Paint_Cmd importa.
        ms_record:   f64, // paint_box: percorre a árvore e emite Paint_Cmd
        ms_replay:   f64, // replay_paint: transforma comandos em vértices ImGui
        n_cmds:      int, // len(pt.cmds) do ÚLTIMO frame
        max_cmds:    int, // maior len(pt.cmds) visto
        n_reallocs:  int, // vezes que cap(pt.cmds) cresceu (tese do arena)
        // ── S3: split do restyle (534 ms no github, indivisos até agora) ────
        ms_compute:  f64, // compute_styles
        ms_buildlay: f64, // build_layout
        // ── culling de texto no replay: PROVA de que a sonda dispara ────────
        n_txt_total: int, // comandos PC_InlineText que chegaram ao replay
        n_txt_cull:  int, // ... descartados por estarem fora do clip
        n_txt_cull_xf: int, // ... descartados DENTRO de transform (só é > 0 no
                            // binário sabotado; no correto TEM de ser 0)
        // ── composite_layer: 87% do paint do github vive aqui (medido) ──────
        // Cinco custos distintos, e a ordem atual paga os quatro primeiros ANTES
        // de descobrir se o cache acerta. Estes campos dizem qual deles pesa.
        lay_n:       int, // chamadas de composite_layer
        lay_hit:     int, // ... que acertaram o cache
        // POR QUE o cache erra — a resposta decide se dá para consertar
        lay_m_nonode: int, // node == nil (nem tenta cachear)
        lay_m_new:    int, // não havia entrada para este node
        lay_m_hash:   int, // havia, mas o conteúdo mudou
        lay_m_size:   int, // havia e o conteúdo bate, mas o bbox mudou de tamanho
        // saídas ANTES do cache — a contabilidade tem de fechar com lay_n
        lay_e_vn0:    int, // replay não gerou vértice nenhum (layer vazia OU fora da tela)
        lay_e_bbox:   int, // bbox degenerado / fora do viewport
        lay_tex_built:int, // texturas efetivamente construídas
        // validação do bbox de subárvore (previsto × real). bb_viola TEM de ser 0
        // antes de qualquer culling se apoiar nele.
        bb_check:  int,
        bb_viola:  int,
        bb_unsafe: int,
        bb_pior:   f32, // pior estouro em px
        bb_v_abs:  int, // violações em layers que TÊM conteúdo fora de fluxo
        bb_v_grande: int, // violações > 1000 px (erro estrutural, não arredondamento)
        bb_c_abs:  int, // conferidas que têm conteúdo fora de fluxo
        bb_desalinho: int, // fila consumida FORA DE ORDEM (node != o do PC_LayerBegin)
        area_crua: f64, // área do bbox de vértices CRU (soma)
        area_vis:  f64, // ... intersectada com o clip (o que de fato aparece)
        cmd_lbegin: int, // PC_LayerBegin GRAVADOS no stream
        cmd_lend:   int, // PC_LayerEnd GRAVADOS no stream
        // qual PERIGO derruba sub_safe, contado por CAIXA (não propagado) — diz
        // qual deles vale a pena tratar de verdade em vez de envenenar a árvore
        hz_boxes:  int,
        hz_pos:    int, // abs/fixed/sticky
        hz_xform:  int, // transform
        hz_canvas: int, // bg_canvas
        hz_trans:  int, // transition/animação
        lay_vtx:     int, // vértices processados (soma)
        ms_lay_replay: f64, // replay_seg do conteúdo da layer
        ms_lay_bbox:   f64, // varredura 1: bbox
        ms_lay_shift:  f64, // varredura 2: vértices p/ espaço local + clips
        ms_lay_hash:   f64, // varredura 3: fnv por vértice
        ms_lay_tex:    f64, // MISS: textura + render + filtro + leitura
    }
    g_uiprof: Ui_Prof

    uiprof_report :: proc() {
        p := g_uiprof
        if p.frames == 0 { fmt.eprintfln("[uiprof] nenhum frame"); return }
        soma := p.ms_jobs + p.ms_imagens + p.ms_js + p.ms_fp + p.ms_restyle +
                p.ms_layout + p.ms_paint + p.ms_render + p.ms_delay
        fmt.eprintfln("\n[uiprof] %d frames | soma das fases = %.0f ms (%d restyles)", p.frames, soma, p.restyles)
        linha :: proc(nome: string, ms, soma: f64, frames: int) {
            fmt.eprintfln("   %-10s %8.0f ms  %5.1f%%   %6.3f ms/frame", nome, ms, 100 * ms / max(soma, 0.001), ms / f64(frames))
        }
        linha("jobs",    p.ms_jobs,    soma, p.frames)
        linha("imagens", p.ms_imagens, soma, p.frames)
        linha("js",      p.ms_js,      soma, p.frames)
        linha("fingerpr",p.ms_fp,      soma, p.frames)
        linha("restyle", p.ms_restyle, soma, p.frames)
        linha("layout",  p.ms_layout,  soma, p.frames)
        linha("paint",   p.ms_paint,   soma, p.frames)
        linha("render",  p.ms_render,  soma, p.frames)
        linha("DELAY",   p.ms_delay,   soma, p.frames)
        // S1. `size_of(Paint_Cmd)` é impresso porque os "~750 B" que motivaram o
        // achado da união eram SOMA DE CAMPOS À MÃO — nunca medidos.
        fmt.eprintfln("\n[uiprof/S1] size_of(Paint_Cmd) = %d B | cmds: %d (último) %d (máx) | reallocs = %d",
            size_of(Paint_Cmd), p.n_cmds, p.max_cmds, p.n_reallocs)
        pa := p.ms_record + p.ms_replay
        fmt.eprintfln("   record   %8.0f ms  %5.1f%% do paint   %6.3f ms/frame", p.ms_record, 100 * p.ms_record / max(pa, 0.001), p.ms_record / f64(p.frames))
        fmt.eprintfln("   replay   %8.0f ms  %5.1f%% do paint   %6.3f ms/frame", p.ms_replay, 100 * p.ms_replay / max(pa, 0.001), p.ms_replay / f64(p.frames))
        fmt.eprintfln("   bytes de comando no último frame = %d KB", (p.n_cmds * size_of(Paint_Cmd)) / 1024)
        fmt.eprintfln("   texto no replay: %d total | %d culados (%.1f%%) | %d culados DENTRO de transform (tem de ser 0)",
            p.n_txt_total, p.n_txt_cull, 100 * f64(p.n_txt_cull) / max(f64(p.n_txt_total), 1), p.n_txt_cull_xf)
        if p.lay_n > 0 {
            lt := p.ms_lay_replay + p.ms_lay_bbox + p.ms_lay_shift + p.ms_lay_hash + p.ms_lay_tex
            fmt.eprintfln("\n[uiprof/LAYER] %d chamadas (%.1f/frame) | %d hits (%.1f%%) | %d vértices (%.0f/chamada) | %.0f ms (%.1f%% do paint)",
                p.lay_n, f64(p.lay_n) / f64(p.frames), p.lay_hit, 100 * f64(p.lay_hit) / f64(p.lay_n),
                p.lay_vtx, f64(p.lay_vtx) / f64(p.lay_n), lt, 100 * lt / max(p.ms_paint, 0.001))
            ll :: proc(nome: string, ms, tot: f64, frames: int) {
                fmt.eprintfln("   %-8s %8.0f ms  %5.1f%%   %6.3f ms/frame", nome, ms, 100 * ms / max(tot, 0.001), ms / f64(frames))
            }
            ll("replay", p.ms_lay_replay, lt, p.frames)
            ll("bbox",   p.ms_lay_bbox,   lt, p.frames)
            ll("shift",  p.ms_lay_shift,  lt, p.frames)
            ll("hash",   p.ms_lay_hash,   lt, p.frames)
            ll("textura",p.ms_lay_tex,    lt, p.frames)
            soma := p.lay_hit + p.lay_e_vn0 + p.lay_e_bbox + p.lay_m_nonode + p.lay_m_new + p.lay_m_hash + p.lay_m_size
            fmt.eprintfln("   MISS por: sem node %d | entrada nova %d | conteúdo mudou %d | bbox mudou de tamanho %d",
                p.lay_m_nonode, p.lay_m_new, p.lay_m_hash, p.lay_m_size)
            fmt.eprintfln("   SAÍDA ANTES DO CACHE: %d sem vértice (vazia ou fora da tela) | %d bbox degenerado", p.lay_e_vn0, p.lay_e_bbox)
            fmt.eprintfln("   texturas construídas: %d (%.1f ms cada)", p.lay_tex_built, p.ms_lay_tex / max(f64(p.lay_tex_built), 1))
            fmt.eprintfln("   BBOX de subárvore: %d conferidos | %d VIOLAÇÕES (pior %.1f px) | %d marcados inseguros (%.0f%%)",
                p.bb_check, p.bb_viola, p.bb_pior, p.bb_unsafe,
                100 * f64(p.bb_unsafe) / max(f64(p.bb_check + p.bb_unsafe), 1))
            when SUBBBOX {
                fmt.eprintfln("   DESALINHO da fila: %d (node da fila != node do PC_LayerBegin) — se >0, TODA comparação é suspeita", p.bb_desalinho)
                fmt.eprintfln("   TEXTURA: área crua %.0f Mpx | área visível %.0f Mpx | desperdício %.0f%% (composite_layer dimensiona pelo CRU)",
                    p.area_crua/1e6, p.area_vis/1e6, 100*(1 - p.area_vis/max(p.area_crua,1)))
                fmt.eprintfln("   STREAM: %d PC_LayerBegin gravados | %d PC_LayerEnd gravados | %d composite_layer chamados%s",
                    p.cmd_lbegin, p.cmd_lend, p.lay_n,
                    p.cmd_lbegin == p.lay_n ? " (todo Begin foi replayado)" : " ⚠️ Begin != chamadas: o replay PULA comandos")
                fmt.eprintfln("   CORRELAÇÃO: conferidas com out-of-flow %d/%d | violações com out-of-flow %d/%d | violações > 1000px %d",
                    p.bb_c_abs, p.bb_check, p.bb_v_abs, p.bb_viola, p.bb_v_grande)
                fmt.eprintfln("   FILA: %d empurrados (último frame) | %d consumidos | %d chamadas de layer%s",
                    len(g_pred_bbox), g_pred_i, p.lay_n, len(g_pred_bbox) == g_pred_i ? " (fecha no frame)" : " ⚠️ NÃO FECHA")
                if g_bb_worst_n > 0 {
                    fmt.eprintfln("   PIOR violador: %s", string(g_bb_worst[:g_bb_worst_n]))
                    fmt.eprintfln("      previsto [%.0f,%.0f .. %.0f,%.0f]  real [%.0f,%.0f .. %.0f,%.0f]",
                        g_bb_wp[0], g_bb_wp[1], g_bb_wp[2], g_bb_wp[3], g_bb_wr[0], g_bb_wr[1], g_bb_wr[2], g_bb_wr[3])
                    fmt.eprintfln("      estouro: esq %.0f  topo %.0f  dir %.0f  base %.0f",
                        g_bb_wp[0]-g_bb_wr[0], g_bb_wp[1]-g_bb_wr[1], g_bb_wr[2]-g_bb_wp[2], g_bb_wr[3]-g_bb_wp[3])
                    fmt.eprintfln("      filhos=%d  vértices=%d  out-of-flow=%v", g_bb_wn, g_bb_wv, g_bb_wa)
                    fmt.eprintfln("      n_filters=%d amount=%.1f (spread=%.1f)  b.w=%.0f  grad=%v bg_img=%v bg_fixed=%v camadas_extra=%d",
                        g_bb_wf, g_bb_wfa, g_bb_wfa*3, g_bb_wbw, g_bb_wg, g_bb_wi, g_bb_wx, g_bb_wnb)
                }
            }
            hb := max(f64(p.hz_boxes), 1)
            fmt.eprintfln("   PERIGO por caixa (%d caixas·frame): pos %d (%.2f%%) | transform %d (%.2f%%) | canvas %d (%.2f%%) | transition %d (%.2f%%)",
                p.hz_boxes, p.hz_pos, 100*f64(p.hz_pos)/hb, p.hz_xform, 100*f64(p.hz_xform)/hb,
                p.hz_canvas, 100*f64(p.hz_canvas)/hb, p.hz_trans, 100*f64(p.hz_trans)/hb)
            fmt.eprintfln("   CONTABILIDADE: %d de %d chamadas classificadas%s", soma, p.lay_n,
                soma == p.lay_n ? " (fecha)" : " ⚠️ NÃO FECHA — falta caminho")
            fmt.eprintfln("   ⚠️ ms_lay_replay conta ANINHADO (layer dentro de layer) e por isso a soma passa de 100%% do paint;")
            fmt.eprintfln("      bbox/shift/hash NÃO são aninhados e valem como fração absoluta.")
        }
        // S3.
        if p.restyles > 0 {
            fmt.eprintfln("\n[uiprof/S3] %d restyles | compute_styles %.0f ms (%.1f ms cada) | build_layout %.0f ms (%.1f ms cada)",
                p.restyles, p.ms_compute, p.ms_compute / f64(p.restyles), p.ms_buildlay, p.ms_buildlay / f64(p.restyles))
        }
    }
}

// ── S2: razão caixas VISITADAS ÷ caixas VISÍVEIS (`-define:CULLPROBE=true`) ──
// Mede o teto do culling por viewport, que não existe hoje (paint_box não compara
// a caixa com retângulo de tela nenhum). Fica em define SEPARADO do UIPROF de
// propósito: o teste por caixa custa, e contaminaria o `ms_record` que o S1 mede.
//
// ⚠️ O clip vem de `im.DrawList_GetClipRectMin/Max` (o padrão que `paint_image` já
// usa), NUNCA de `g_viewport_clip`: aquela global só é escrita pelo laço
// interativo e vale {0,0,0,0} no headless — que é quem roda os 481 reftests.
CULLPROBE :: #config(CULLPROBE, false)

when CULLPROBE {
    Cull_Prof :: struct {
        frames:    int,
        visitadas: int, // caixas em que paint_box entrou
        visiveis:  int, // ... cujo border-box intersecta o clip corrente
        txt_emit:  int, // PC_InlineText emitidos
        txt_vis:   int, // ... com a linha dentro do clip
        txt_space: int, // ... com letter_spacing != 0 (caminho por CARACTERE)
    }
    g_cullprof: Cull_Prof

    cullprobe_report :: proc() {
        p := g_cullprof
        if p.visitadas == 0 { fmt.eprintfln("[cullprobe] nenhuma caixa visitada"); return }
        razao := f64(p.visitadas) / max(f64(p.visiveis), 1)
        fmt.eprintfln("\n[cullprobe] %d frames | visitadas %d | visíveis %d | razão %.1f:1 | desperdício %.1f%%",
            p.frames, p.visitadas, p.visiveis, razao, 100 * f64(p.visitadas - p.visiveis) / f64(p.visitadas))
        fmt.eprintfln("   PC_InlineText: emitidos %d | dentro do clip %d | com letter-spacing %d",
            p.txt_emit, p.txt_vis, p.txt_space)
    }
}

// ── Sonda do RECORD por trecho (`-define:PAINTPROF=true`) ────────────────────
// Tempo PRÓPRIO de cada paint_box (descontados os paint_box filhos), fatiado por
// trecho, + o paint_inline à parte. Existe para achar o termo que cresce com o
// nº de IRMÃOS (medido 11/11: record 0,4 → 0,9 → 10 → 774 ms/frame para 500 →
// 4.000 divs irmãos; altura da página não influi).
PAINTPROF :: #config(PAINTPROF, false)

when PAINTPROF {
    PP_SEGS :: [?]string{"entrada+geom", "hover", "roda+trans+anim", "xform+layer", "fundo+borda", "resto"}
    Paint_Prof :: struct {
        frames:      int,
        calls:       int,
        self_ms:     f64,
        seg:         [len(PP_SEGS)]f64,
        inline_ms:   f64, // paint_inline, próprio (sem os paint_box de InlineBox)
        inline_n:    int,
        append_fail: int,    // emit cujo append NÃO entrou no buffer
        append_fail_info: [2]int, // {cap no 1º fracasso, Allocator_Error}
    }
    g_pp: Paint_Prof
    g_pp_child: f64 // ms gastos em paint_box FILHOS do paint_box corrente

    paintprof_report :: proc() {
        p := g_pp
        if p.calls == 0 { fmt.eprintfln("[paintprof] nada"); return }
        f := f64(max(p.frames, 1))
        fmt.eprintfln("\n[paintprof] %d frames | %d paint_box (%.0f/frame) | próprio %.2f ms/frame | %.2f µs/caixa",
            p.frames, p.calls, f64(p.calls) / f, p.self_ms / f, 1000 * p.self_ms / f64(p.calls))
        segs := PP_SEGS
        soma: f64 = 0
        for k in 0 ..< len(segs) - 1 do soma += p.seg[k]
        for k in 0 ..< len(segs) {
            ms := k == len(segs) - 1 ? p.self_ms - soma - p.inline_ms : p.seg[k]
            fmt.eprintfln("   %-16s %9.2f ms/frame  %5.1f%%", segs[k], ms / f, 100 * ms / max(p.self_ms, 0.001))
        }
        fmt.eprintfln("   %-16s %9.2f ms/frame  %5.1f%%  (%d chamadas)", "paint_inline", p.inline_ms / f, 100 * p.inline_ms / max(p.self_ms, 0.001), p.inline_n)
        // err: 0 None, 1 Out_Of_Memory, 2 Invalid_Pointer, 3 Invalid_Argument, 4 Mode_Not_Implemented
        fmt.eprintfln("   emit PERDIDO: %d (%.0f/frame) | 1º com cap=%d err=%d | size_of=%d align_of=%d",
            p.append_fail, f64(p.append_fail) / f, p.append_fail_info[0], p.append_fail_info[1],
            size_of(Paint_Cmd), align_of(Paint_Cmd))
    }
}

// ── Table layout ─────────────────────────────────────────────────────────────
// ── Multi-coluna ─────────────────────────────────────────────────────────────
// Nº de colunas e largura de cada uma, a partir da largura disponível, do
// column-count, column-width e gap (algoritmo simplificado da spec).
@(private="file")
multicol_geometry :: proc(avail: f32, count: int, width, gap: f32) -> (n: int, col_w: f32) {
    if count > 0 && width > 0 {
        fit := int((avail + gap) / (width + gap)) // quantas cabem pela largura
        if fit < 1 do fit = 1
        n = min(count, fit)
    } else if count > 0 {
        n = count
    } else if width > 0 {
        n = int((avail + gap) / (width + gap))
        if n < 1 do n = 1
    } else {
        n = 1
    }
    if n < 1 do n = 1
    col_w = (avail - f32(n - 1) * gap) / f32(n)
    if col_w < 1 do col_w = 1
    return
}

// Reparte os filhos (já empilhados numa coluna de largura col_w) em n colunas,
// balanceando por altura (~total/n) na granularidade de BLOCO — cada filho vai
// INTEIRO p/ uma coluna (não fragmenta linhas). Desloca cada subárvore com
// translate_subtree. Devolve a altura da coluna mais alta.
@(private="file")
redistribute_columns :: proc(b: ^Box, col_w: f32, n: int, gap, total_h: f32) -> f32 {
    target := total_h / f32(n)
    col := 0
    col_start: f32 = 0 // rel_y (relativo a content_y) onde a coluna atual começou
    first_in_col := true
    new_h: f32 = 0
    prev: ^Box = nil
    for child in b.children {
        if child.pos == .Absolute || child.pos == .Fixed do continue
        rel_y := child.y - b.content_y
        // break-*:avoid impede a quebra entre este bloco e o anterior (ficam juntos
        // na mesma coluna, mesmo estourando o alvo — como manda o CSS Fragmentation).
        avoid := (prev != nil && prev.break_after_avoid) || child.break_before_avoid
        // quebra p/ a próxima coluna quando a atual já atingiu o alvo (nunca antes
        // do 1º filho da coluna, p/ garantir ≥1 por coluna; nem além da última).
        if !first_in_col && !avoid && col < n - 1 && (rel_y - col_start) >= target {
            col += 1
            col_start = rel_y
            first_in_col = true
        }
        translate_subtree(child, f32(col) * (col_w + gap), -col_start)
        first_in_col = false
        if bottom := (rel_y - col_start) + child.h; bottom > new_h do new_h = bottom
        prev = child
    }
    return new_h
}

// Tabela "auto": largura de coluna pelo conteúdo (max-content), com colspan.
// SEM rowspan (tratado como 1), sem border-spacing/caption.

@(private="file")
layout_table :: proc(b: ^Box) -> f32 {
    rows: [dynamic][dynamic]^Box
    defer { for r in rows do delete(r); delete(rows) }
    collect_rows(b, &rows)
    if len(rows) == 0 do return 0

    // nº de colunas (considerando colspan)
    ncols := 0
    for row in rows {
        c := 0
        for cell in row do c += cell_colspan(cell)
        if c > ncols do ncols = c
    }
    if ncols == 0 do return 0

    col_w := make([]f32, ncols, context.temp_allocator)
    avail := b.content_w
    table_cw: f32

    if b.table_fixed {
        // table-layout:fixed: as larguras vêm da 1ª linha (largura explícita das
        // células), IGNORANDO o conteúdo; colunas sem largura dividem o resto. A
        // largura da tabela = a disponível (fixed costuma vir com width:100%).
        table_cw = avail
        assigned := make([]bool, ncols, context.temp_allocator)
        if len(rows) > 0 {
            ci := 0
            for cell in rows[0] {
                span := cell_colspan(cell)
                if ci < ncols && cell.has_width {
                    w := cell.width_pct ? pct_resolve(cell.width, cell.width_pct_off, table_cw, cell.width_bd) : cell.width
                    per := w / f32(span)
                    for k in ci ..< min(ci + span, ncols) { col_w[k] = per; assigned[k] = true }
                }
                ci += span
            }
        }
        used: f32 = 0; n_auto := 0
        for k in 0 ..< ncols { if assigned[k] { used += col_w[k] } else { n_auto += 1 } }
        rem := table_cw - used; if rem < 0 do rem = 0
        if n_auto > 0 {
            per := rem / f32(n_auto)
            for k in 0 ..< ncols do if !assigned[k] do col_w[k] = per
        } else if used > 1 {
            sc := table_cw / used // sem colunas auto: escala p/ preencher
            for k in 0 ..< ncols do col_w[k] *= sc
        }
    } else {
        // table-layout:auto — largura intrínseca: células de colspan 1 definem a coluna
        for row in rows {
            ci := 0
            for cell in row {
                span := cell_colspan(cell)
                if span == 1 && ci < ncols {
                    iw := measure_intrinsic_w(cell)
                    if iw > col_w[ci] do col_w[ci] = iw
                }
                ci += span
            }
        }
        // células com colspan: garante que a soma das colunas as comporte
        for row in rows {
            ci := 0
            for cell in row {
                span := cell_colspan(cell)
                if span > 1 && ci + span <= ncols {
                    iw := measure_intrinsic_w(cell)
                    cur: f32 = 0
                    for k in ci ..< ci + span do cur += col_w[k]
                    if iw > cur {
                        add := (iw - cur) / f32(span)
                        for k in ci ..< ci + span do col_w[k] += add
                    }
                }
                ci += span
            }
        }

        total: f32 = 0
        for w in col_w do total += w
        if total < 1 do total = 1

        if b.has_width {
            table_cw = avail // largura explícita: distribui proporcionalmente
            sc := table_cw / total
            for i in 0 ..< ncols do col_w[i] *= sc
        } else if total > avail {
            sc := avail / total // estoura: encolhe p/ caber
            for i in 0 ..< ncols do col_w[i] *= sc
            table_cw = avail
        } else {
            table_cw = total // shrink-to-fit
        }
    }

    // ajusta a caixa da tabela à largura usada
    b.content_w = table_cw
    b.w = table_cw + b.padding[3] + b.padding[1] + bw_x(b)

    // offset x acumulado por coluna
    col_x := make([]f32, ncols + 1, context.temp_allocator)
    for i in 0 ..< ncols do col_x[i + 1] = col_x[i] + col_w[i]

    // border-collapse: zera bordas internas p/ evitar linhas duplas
    if b.border_collapse {
        nrows_t := len(rows)
        for row, ri in rows {
            ci := 0
            for cell in row {
                span := cell_colspan(cell)
                if ci + span < ncols do cell.border_w[1] = 0 // não é última col: zera direita
                if ri < nrows_t - 1  do cell.border_w[2] = 0 // não é última linha: zera inferior
                if ci > 0            do cell.border_w[3] = 0 // não é primeira col: zera esquerda
                if ri > 0            do cell.border_w[0] = 0 // não é primeira linha: zera superior
                ci += span
            }
        }
    }

    // <caption>: fora do fluxo de linhas. Medida em largura de tabela; posição
    // topo/rodapé por caption-side. cap_top_h empurra as linhas p/ baixo.
    captions := make([dynamic]^Box, context.temp_allocator)
    for ch in b.children do if ch != nil && ch.is_caption do append(&captions, ch)
    cap_top_h, cap_bot_h: f32 = 0, 0
    for cap in captions {
        layout_box(cap, b.content_x, b.content_y, table_cw, table_cw, -1)
        if cap.caption_side_bottom { cap_bot_h += cap.h } else { cap_top_h += cap.h }
    }

    cy := b.content_y + cap_top_h
    for row in rows {
        // pass A: mede a altura da linha
        row_h: f32 = 0
        ci := 0
        for cell in row {
            span := cell_colspan(cell)
            cw := span_width(col_w, col_x, ci, span, ncols)
            layout_box(cell, b.content_x + col_x[min(ci, ncols)], cy, cw, cw, -1)
            if cell.h > row_h do row_h = cell.h
            ci += span
        }
        // pass B: estica todas as células à altura da linha
        ci = 0
        for cell in row {
            span := cell_colspan(cell)
            cw := span_width(col_w, col_x, ci, span, ncols)
            layout_box(cell, b.content_x + col_x[min(ci, ncols)], cy, cw, cw, row_h)
            ci += span
        }
        cy += row_h
    }
    // posiciona as captions: topo empilha a partir de content_y; rodapé após as linhas.
    top_y := b.content_y
    bot_y := cy
    for cap in captions {
        if cap.caption_side_bottom {
            translate_subtree(cap, 0, bot_y - cap.y)
            bot_y += cap.h
        } else {
            translate_subtree(cap, 0, top_y - cap.y)
            top_y += cap.h
        }
    }
    return (cy - b.content_y) + cap_bot_h
}

// Largura (border-box) de uma célula que ocupa [ci, ci+span).
@(private="file")
span_width :: proc(col_w, col_x: []f32, ci, span, ncols: int) -> f32 {
    a := min(ci, ncols)
    b := min(ci + span, ncols)
    return col_x[b] - col_x[a]
}

// Coleta as linhas da tabela — reconhecidas por flag (is_table_row, ou <tr>) ou
// dentro de um grupo de linhas (thead/tbody/tfoot ou display:table-*-group) — e,
// por linha, as células (is_table_cell / <td>/<th>). Células SOLTAS direto na
// tabela viram uma LINHA ANÔNIMA (comportamento CSS: geração de linha anônima).
@(private="file")
// Este `display:table` tem MESMO estrutura de tabela (alguma linha/célula/grupo)?
// `display:table` num div SEM linhas é idioma antigo de shrink-to-fit/centralizar
// (`#intro .container{display:table;margin:0 auto}` no php.net). Per-spec ele
// geraria linha+célula ANÔNIMAS em volta dos filhos; como não fazemos isso,
// `layout_table` batia no `len(rows)==0 do return 0` e os filhos NUNCA eram
// layoutados — todo `width:100%` dentro dele colapsava p/ ZERO (o hero do php.net
// inteiro sumia). Sem estrutura, cai no caminho de BLOCO, que é o que o autor quer.
table_has_structure :: proc(b: ^Box) -> bool {
    for ch in b.children {
        if ch == nil do continue
        if ch.is_table_row || ch.is_table_cell || ch.is_table_rowgrp do return true
        if ch.node != nil {
            switch ch.node.tag {
            case "tr", "td", "th", "thead", "tbody", "tfoot", "caption": return true
            }
        }
        // wrapper anônimo (ex.: <tbody> implícito criado pelo parser)
        if ch.node == nil && table_has_structure(ch) do return true
    }
    return false
}

collect_rows :: proc(box: ^Box, rows: ^[dynamic][dynamic]^Box) {
    anon := make([dynamic]^Box, context.temp_allocator) // acumulador de células soltas
    flush :: proc(anon: ^[dynamic]^Box, rows: ^[dynamic][dynamic]^Box) {
        if len(anon) > 0 {
            row := make([dynamic]^Box, context.temp_allocator)
            append(&row, ..anon[:])
            append(rows, row)
            clear(anon)
        }
    }
    for ch in box.children {
        if ch == nil do continue
        if ch.is_table_row {
            flush(&anon, rows)
            row := make([dynamic]^Box, context.temp_allocator)
            for cell in ch.children {
                if cell != nil && cell.is_table_cell do append(&row, cell)
            }
            append(rows, row)
        } else if ch.is_table_rowgrp {
            flush(&anon, rows)
            collect_rows(ch, rows)
        } else if ch.is_table_cell {
            append(&anon, ch) // célula solta → linha anônima
        }
    }
    flush(&anon, rows)
}

@(private="file")
cell_colspan :: proc(cell: ^Box) -> int {
    if cell.node == nil do return 1
    if v, ok := cell.node.attrs["colspan"]; ok {
        if n, k := strconv.parse_int(v); k && n >= 1 do return n
    }
    return 1
}

// Limites min/max da caixa no eixo pedido, em border-box (mesma convenção das
// bases do flex). `.Row` = eixo INLINE (min/max-width), `.Column` = eixo de BLOCO
// (min/max-height). lo=0 e hi=FLT_MAX quando ausentes. min vence max (clamp
// aplica max antes, min depois). Serve ao eixo principal do flex E aos sítios de
// STRETCH (ver stretch_clamp) — por isso o nome não fala em "main".
@(private="file")
box_min_max_axis :: proc(c: ^Box, dir: Flex_Dir, container_main: f32) -> (lo, hi: f32) {
    lo = 0; hi = FLT_MAX
    if dir == .Row {
        ex := c.padding[3] + c.padding[1] + bw_x(c)
        if c.has_minw { m := c.minw_pct ? pct_resolve(c.minw, c.minw_pct_off, container_main, c.minw_bd) : c.minw; lo = c.box_sizing == .Border ? m : m + ex }
        if c.has_maxw { m := c.maxw_pct ? pct_resolve(c.maxw, c.maxw_pct_off, container_main, c.maxw_bd) : c.maxw; hi = c.box_sizing == .Border ? m : m + ex }
    } else {
        ex := c.padding[0] + c.padding[2] + bw_y(c)
        if c.has_minh { lo = c.box_sizing == .Border ? c.minh : c.minh + ex }
        if c.has_maxh { hi = c.box_sizing == .Border ? c.maxh : c.maxh + ex }
    }
    return
}

@(private="file")
clamp_main :: proc(v, lo, hi: f32) -> f32 {
    return max(lo, min(v, hi)) // aplica max (min(v,hi)) e depois min (max(...,lo)): min vence
}

// Tamanho IMPOSTO a um item, limitado por min/max. Existe porque o tamanho vai
// ao filho por `force_w`/`force_h`, e ESSE caminho do layout_box não clampa —
// ele só aplica min/max quando calcula a largura ele mesmo. Mesmo buraco que o
// `float_fit_width` já compensava nos floats; aqui a compensação é uma função
// só, para todos os sítios que impõem tamanho: coluna flex (eixo cruzado), eixo
// cruzado da linha flex, célula do grid (2 eixos), átomo inline (inline-block) e
// absoluto esticado entre insets. ⚠️ o eixo PRINCIPAL do flex NÃO passa por aqui:
// lá o clamp é do `resolve_flex_lengths`, que também conhece o mínimo automático
// baseado em conteúdo (que PODE ultrapassar o max-width, e re-clampar quebraria).
// `basis` = tamanho do bloco contenedor no eixo, p/ % de min/max-width (no eixo
// de bloco os % já chegam resolvidos por resolve_child_minmax_h; no grid, não —
// lá px vale e % não).
@(private="file")
stretch_clamp :: proc(c: ^Box, axis: Flex_Dir, size, basis: f32) -> f32 {
    lo, hi := box_min_max_axis(c, axis, basis)
    return clamp_main(size, lo, hi)
}

// Algoritmo de "resolving flexible lengths" (CSS Flexbox §9.7) com congelamento:
// distribui o espaço livre por grow/shrink, mas quando um item bate no seu
// min/max ele é CONGELADO no valor limitado e o restante é redistribuído entre
// os demais. `avail` = espaço principal para os itens (gaps e margens já fora).
// Devolve os tamanhos finais (border-box) indexados como as entradas.
@(private="file")
resolve_flex_lengths :: proc(bases, grows, shrinks, mins, maxs: []f32, avail: f32) -> []f32 {
    n := len(bases)
    finals := make([]f32, n, context.temp_allocator)
    frozen := make([]bool, n, context.temp_allocator)

    // tamanho hipotético = base limitado por min/max; decide crescer vs encolher
    sum_hypo: f32 = 0
    for i in 0 ..< n { finals[i] = clamp_main(bases[i], mins[i], maxs[i]); sum_hypo += finals[i] }
    growing := sum_hypo < avail

    // congela os inflexíveis (fator 0) e os já limitados na direção do fluxo
    for i in 0 ..< n {
        factor := growing ? grows[i] : shrinks[i]
        if factor == 0 { frozen[i] = true; continue }
        if growing && bases[i] > finals[i] do frozen[i] = true       // limitado p/ baixo (max)
        if !growing && bases[i] < finals[i] do frozen[i] = true      // limitado p/ cima (min)
    }

    initial_free := avail
    for i in 0 ..< n do initial_free -= frozen[i] ? finals[i] : bases[i]

    for iter := 0; iter < n + 1; iter += 1 {
        any := false
        for f in frozen do if !f { any = true; break }
        if !any do break

        used: f32 = 0
        for i in 0 ..< n do used += frozen[i] ? finals[i] : bases[i]
        remaining := avail - used
        // Factors below one request only that fraction of the INITIAL free space.
        // Shrink uses unscaled factors here; distribution still uses scaled bases.
        factor_sum: f32 = 0
        for i in 0 ..< n do if !frozen[i] do factor_sum += growing ? grows[i] : shrinks[i]
        if factor_sum < 1 {
            partial := initial_free * factor_sum
            if abs(partial) < abs(remaining) do remaining = partial
        }

        if growing {
            sumf: f32 = 0; for i in 0 ..< n do if !frozen[i] do sumf += grows[i]
            if sumf <= 0 do break
            for i in 0 ..< n do if !frozen[i] do finals[i] = bases[i] + remaining * grows[i] / sumf
        } else {
            sums: f32 = 0; for i in 0 ..< n do if !frozen[i] do sums += shrinks[i] * bases[i]
            if sums <= 0 do break
            for i in 0 ..< n do if !frozen[i] do finals[i] = bases[i] + remaining * (shrinks[i] * bases[i]) / sums
        }

        // limita cada item flexível; a soma das violações decide quem congelar
        total_viol: f32 = 0
        viol := make([]f32, n, context.temp_allocator)
        for i in 0 ..< n {
            if frozen[i] do continue
            c := clamp_main(finals[i], mins[i], maxs[i])
            viol[i] = c - finals[i]
            finals[i] = c
            total_viol += viol[i]
        }
        if total_viol == 0 {
            for i in 0 ..< n do frozen[i] = true
        } else if total_viol > 0 {
            for i in 0 ..< n do if viol[i] > 0 do frozen[i] = true // subiu (min): congela
        } else {
            for i in 0 ..< n do if viol[i] < 0 do frozen[i] = true // desceu (max): congela
        }
    }
    return finals
}

// Tamanho-base principal de um item flex em row (border-box) + grow/shrink.
@(private="file")
flex_base_main :: proc(c: ^Box, cw: f32, cross_h: f32 = -1) -> (base, grow, shrink: f32) {
    grow = c.flex_grow
    shrink = c.flex_shrink
    extra := c.padding[3] + c.padding[1] + bw_x(c)
    if c.has_flex_basis && !c.flex_basis_auto {
        bv := c.flex_basis_pct ? pct_resolve(c.flex_basis, c.flex_basis_pct_off, cw, c.flex_basis_bd) : c.flex_basis
        base = c.box_sizing == .Border ? bv : bv + extra
        return
    }
    if c.has_width {
        w := c.width_pct ? pct_resolve(c.width, c.width_pct_off, cw, c.width_bd) : c.width
        base = c.box_sizing == .Border ? w : w + extra
        return
    }
    if transferred, ok := flex_transferred_w(c, cross_h); ok { base = transferred; return }
    base = measure_intrinsic_w(c)
    return
}

// Largura (border-box) shrink-to-fit de um float SEM width explícito: o intrínseco
// limitado ao container E a min/max-width. O caminho force_w do layout_box pula o
// clamp de max/min-width (só o aplica quando calcula a largura ele mesmo), então um
// float como `<div style="float:right; max-width:10em">` (sidebar de sponsors do
// curl.se) usava a largura intrínseca (logos grandes) e esmagava o conteúdo à esq.
@(private="file")
float_fit_width :: proc(child: ^Box, avail: f32) -> f32 {
    w := min(measure_intrinsic_w(child), max(measure_intrinsic_w(child, true), avail))
    extra := child.padding[3] + child.padding[1] + bw_x(child)
    if child.has_maxw {
        lim := child.maxw_pct ? pct_resolve(child.maxw, child.maxw_pct_off, avail, child.maxw_bd) : child.maxw
        if child.box_sizing != .Border do lim += extra // max-width content-box → border-box
        if lim < w do w = lim
    }
    if child.has_minw {
        lo := child.minw_pct ? pct_resolve(child.minw, child.minw_pct_off, avail, child.minw_bd) : child.minw
        if child.box_sizing != .Border do lo += extra
        if lo > w do w = lo // min vence max (igual ao CSS)
    }
    return w
}

// Largura "min-content" (border-box): o maior ÁTOMO INDIVISÍVEL do conteúdo — a
// palavra mais larga, a imagem mais larga — ao contrário do max-content, que SOMA.
// `ignore_specified` mede só o conteúdo, ignorando a `width` própria (é o que a
// §4.5 chama de "content size suggestion"); na recursão os filhos usam o default,
// porque a largura definida de um filho É a contribuição dele.
//
// ⚠️ Onde decompor exatamente é caro ou incerto (grid, % de replaced), este medidor
// SUBESTIMA DE PROPÓSITO. O valor é um PISO: subestimar degrada para o
// comportamento antigo (encolhe demais), enquanto SUPERESTIMAR inventa um overflow
// que o Chrome não tem — que é o erro caro.
@(private="file")
measure_min_content_w :: proc(b: ^Box, ignore_specified := false) -> f32 {
    extra := b.padding[3] + b.padding[1] + bw_x(b)
    if !ignore_specified && b.has_width && !b.width_pct {
        return b.box_sizing == .Border ? b.width : b.width + extra
    }
    content: f32 = 0
    if b.is_inline && b.writing_mode != .Horizontal {
        // Physical width is the vertical block extent, for both intrinsic constraints.
        layout_vertical_inline(b, orthogonal_inline_limit(b), false)
        content = b.vertical_block_extent
    } else if b.is_inline {
        content = inline_min_width(b)
    } else if b.is_flex && b.flex_dir == .Row && !b.flex_wrap {
        // linha flex que NÃO quebra: os itens não podem empilhar, então o
        // min-content dela é a SOMA dos min-contents dos itens (+ gaps) — mesma
        // razão pela qual o max-content de uma row soma em vez de maximizar.
        nvis := 0
        for c in b.children {
            if c.pos == .Absolute || c.pos == .Fixed do continue
            content += measure_min_content_w(c) + c.margin[3] + c.margin[1]
            nvis += 1
        }
        if nvis > 1 do content += (b.gap_pct ? f32(0) : b.gap) * f32(nvis - 1)
    } else if b.kind == .Image {
        // `width` em % resolve contra o container: como contribuição intrínseca ela
        // é 0 (a imagem PODE encolher). Sem esta guarda, um logo de 1920px com
        // `width:100%` viraria um piso de 1920px e transbordaria a linha inteira.
        if !b.width_pct {
            iw, _ := image_dims(b)
            content = iw
        }
    } else if b.is_grid {
        content = grid_intrinsic_w(b, true)
    } else {
        // Bloco, flex com wrap e coluna: a maior contribuição mínima dos filhos.
        for c in b.children {
            if c.pos == .Absolute || c.pos == .Fixed do continue
            w := measure_min_content_w(c) + c.margin[3] + c.margin[1]
            if w > content do content = w
        }
    }
    return content + extra
}

// Tamanho mínimo automático de um item flex no eixo INLINE (CSS Flexbox §4.5):
// o menor entre a "specified size suggestion" (a width definida, se houver) e a
// "content size suggestion" (o min-content do conteúdo).
@(private="file")
flex_auto_min_w :: proc(c: ^Box, cw: f32 = -1, cross_h: f32 = -1) -> f32 {
    cbm := measure_min_content_w(c, true)
    // Cross-axis constraints also clamp the content-size suggestion through the
    // ratio, even when the preferred cross-size itself is auto.
    if c.aspect > 0 {
        lo, hi := box_min_max_axis(c, .Column, max(0, cross_h))
        ew := c.padding[3] + c.padding[1] + bw_x(c)
        eh := c.padding[0] + c.padding[2] + bw_y(c)
        if c.box_sizing == .Content {
            lo = max(0, lo-eh) * c.aspect + ew
            if hi < FLT_MAX do hi = max(0, hi-eh) * c.aspect + ew
        } else {
            lo *= c.aspect
            if hi < FLT_MAX do hi *= c.aspect
        }
        cbm = clamp_main(cbm, lo, hi)
    }
    if transferred, ok := flex_transferred_w(c, cross_h); ok {
        cbm = c.kind == .Image ? min(cbm, transferred) : max(cbm, transferred)
    }
    if c.has_width && (!c.width_pct || cw >= 0) {
        extra := c.padding[3] + c.padding[1] + bw_x(c)
        w := c.width_pct ? pct_resolve(c.width, c.width_pct_off, cw, c.width_bd) : c.width
        sw := c.box_sizing == .Border ? w : w + extra
        cbm = min(cbm, sw)
    }
    return cbm
}

// Transfer a definite preferred cross-size through the preferred aspect ratio.
// The CSS ratio uses the box selected by box-sizing; a natural image ratio uses
// content dimensions. Never transfer an unresolved percentage height.
@(private="file")
flex_transferred_w :: proc(c: ^Box, cross_h: f32) -> (f32, bool) {
    if !c.has_height && !(c.has_height_pct && cross_h >= 0) do return 0, false
    ratio := c.aspect
    natural := ratio <= 0 && c.kind == .Image
    if natural {
        w, h := image_dims(c)
        if h > 0 do ratio = w / h
    }
    if ratio <= 0 do return 0, false
    h := c.has_height_pct ? pct_resolve(c.height_pct, c.height_pct_off, cross_h, c.height_bd) : c.height
    eh := c.padding[0] + c.padding[2] + bw_y(c)
    ew := c.padding[3] + c.padding[1] + bw_x(c)
    if c.box_sizing == .Content do h += eh
    h = stretch_clamp(c, .Column, h, max(0, cross_h))
    if c.box_sizing == .Border && !natural do return max(ew, h * ratio), true
    return max(0, h - eh) * ratio + ew, true
}

// Contribuição intrínseca em border-box, sem executar layout nem alterar estilos.
@(private="file")
measure_intrinsic_w :: proc(b: ^Box, min_content := false) -> f32 {
    if min_content || b.width_minc do return measure_min_content_w(b)
    extra := b.padding[3] + b.padding[1] + bw_x(b)
    if b.has_width && !b.width_pct {
        return b.box_sizing == .Border ? b.width : b.width + extra
    }
    content: f32 = 0
    if b.is_inline && b.writing_mode!=.Horizontal {
        layout_vertical_inline(b,orthogonal_inline_limit(b),false)
        content=b.vertical_block_extent
    } else if b.is_inline {
        content = inline_max_width(b)
    } else if b.is_flex && b.flex_dir == .Row {
        // linha flex: max-content é a SOMA dos itens (+ gaps), não o máximo — senão
        // uma navbar flex aninhada é medida como um item só e encolhe/sobrepõe.
        visible := 0
        for c in b.children {
            if c.pos == .Absolute || c.pos == .Fixed do continue
            content += measure_intrinsic_w(c) + c.margin[3] + c.margin[1]
            visible += 1
        }
        if visible > 1 do content += (b.gap_pct ? f32(0) : b.gap) * f32(visible - 1)
    } else if b.kind == .Image {
        iw, _ := image_dims(b)
        content = iw
    } else if b.is_grid {
        // grid: max-content = SOMA das larguras de coluna (cada coluna = max-content
        // dos itens span-1 nela; trilhas px fixam; fr/auto/fit-content usam conteúdo).
        content = grid_intrinsic_w(b, min_content)
    } else {
        for c in b.children {
            if c.pos == .Absolute || c.pos == .Fixed do continue
            w := measure_intrinsic_w(c) + c.margin[3] + c.margin[1]
            if w > content do content = w
        }
    }
    return content + extra
}

// CSS Sizing 3: fit-content = min(max-content, max(min-content, disponível)).
// As três medidas são border-box; padding/borda não podem ser somados duas vezes.
@(private="file")
intrinsic_used_width :: proc(b: ^Box, available: f32) -> f32 {
    if b.width_minc do return measure_intrinsic_w(b, true)
    preferred := measure_intrinsic_w(b)
    if b.width_fit do return min(preferred, max(measure_intrinsic_w(b, true), available))
    return preferred
}

// Largura intrínseca (max-content) de um container de grid = soma das colunas.
// Reusa o placement de grid_place; cada coluna = max-content dos itens span-1, e
// depois os itens que fazem SPAN distribuem o que falta (spec §12.5).
//
// ⚠️ A distribuição de span existe porque a aproximação anterior ("item com span
// não contribui") tinha um caso degenerado nada raro: um grid cujo ÚNICO item
// span TODAS as colunas media **só a soma dos gaps** — as trilhas ficavam em 0.
// Era o hero do github.com (`grid-column: auto / span 12`, 12 trilhas, gap 48):
// o grid saía com 528 = 11×48 em vez de 1168, e o `<h1>` de 64px quebrava em 3
// linhas dentro de uma coluna estreita demais. Repro mínimo em
// `tests/manual/hero-grid-intrinsic.html`.
// A trilha EFETIVA da coluna `c`: do template quando existe, senão a implícita
// (grid-auto-columns) e, na falta das duas, `auto`. Extraída porque a soma final
// e a distribuição de span precisam da MESMA resposta.
@(private="file")
grid_track_at :: proc(b: ^Box, c: int) -> Grid_Track {
    if c < b.grid_track_n do return b.grid_tracks[c]
    if b.grid_flow_col && b.grid_auto_col_n > 0 {
        return b.grid_auto_cols[(c - b.grid_track_n) % b.grid_auto_col_n]
    }
    return Grid_Track{kind = .Auto}
}

// `min_content`: a restrição sob a qual o container está sendo medido. Ela muda
// UMA coisa — se as trilhas FLEXÍVEIS (fr) recebem a contribuição de um item que
// faz span. Sob max-content recebem (é o que dá 12×33 no hero do github); sob
// min-content NÃO (a base de uma fr é 0, e o WPT
// `css-grid/grid-flex-spanning-items-001` mede exatamente isso: `width:min-content`
// num grid `1fr 30px` com item span-2 tem de dar 30, com o item transbordando).
@(private="file")
grid_intrinsic_w :: proc(b: ^Box, min_content := false) -> f32 {
    items := make([dynamic]^Box, context.temp_allocator)
    for c in b.children {
        if c.pos == .Absolute || c.pos == .Fixed do continue
        append(&items, c)
    }
    n := len(items)
    if n == 0 do return 0
    col_gap := b.gap_pct ? max(0, b.gap_off) : b.gap

    // nº de colunas primárias do template (max-content ignora auto-fill: mede o
    // conteúdo real, não uma grade responsiva contra largura desconhecida).
    n_primary := b.grid_track_n
    if b.grid_flow_col {
        n_primary = b.grid_row_track_n
        if n_primary < 1 do n_primary = 1
    } else if n_primary < 1 {
        n_primary = 1
    }
    col_of, _, cspan_of, _ := grid_place(items[:], n_primary, b.grid_flow_col, b.grid_flow_dense)

    ncols := b.grid_track_n
    for i in 0 ..< n do ncols = max(ncols, col_of[i] + cspan_of[i])
    if ncols < 1 do ncols = 1

    // max-content de cada coluna (border-box do item + margens), só span-1
    colw := make([]f32, ncols, context.temp_allocator)
    for it, i in items {
        if cspan_of[i] != 1 do continue
        c := col_of[i]
        if c < 0 || c >= ncols do continue
        t := grid_track_at(b, c)
        w := measure_intrinsic_w(it, min_content || t.max_kind == .MinContent) + it.margin[3] + it.margin[1]
        if min_content && t.min_kind == .MaxContent do w = measure_intrinsic_w(it) + it.margin[3] + it.margin[1]
        if min_content && t.de_minmax && t.min_kind == .Fixed do w = t.min_px
        if t.max_kind == .FitContent && !t.fit_pct {
            floor := measure_intrinsic_w(it, true) + it.margin[3] + it.margin[1]
            w = max(floor, min(w, t.value))
        }
        if w > colw[c] do colw[c] = w
    }

    // Itens com SPAN, em ordem CRESCENTE de span (spec §12.5: os spans menores
    // resolvem primeiro, e os maiores só distribuem o que ainda falta). O item
    // paga os gaps que ele mesmo atravessa e as trilhas de px FIXO; o resto é
    // repartido igualmente entre as trilhas intrínsecas que ele cobre.
    for span in 2 ..= ncols {
        planned := make([]f32, ncols, context.temp_allocator)
        for it, i in items {
            s := cspan_of[i]
            if s != span do continue
            c0 := col_of[i]
            if c0 < 0 || c0 + s > ncols do continue
            need := measure_intrinsic_w(it, min_content) + it.margin[3] + it.margin[1] - col_gap * f32(s - 1)
            if !min_content {
                span_tracks := make([]Grid_Track, s, context.temp_allocator)
                span_widths := make([]f32, s, context.temp_allocator)
                has_fr := false
                for k in 0 ..< s {
                    t := grid_track_at(b, c0 + k)
                    span_tracks[k] = t
                    span_widths[k] = max(colw[c0+k], t.min_px)
                    if t.kind == .Fixed do span_widths[k] = max(t.value, t.min_px)
                    has_fr = has_fr || t.kind == .Fr
                }
                if has_fr {
                    grid_resolve_fr(span_tracks, span_widths, need)
                    for k in 0 ..< s do if span_tracks[k].kind == .Fr do planned[c0+k] = max(planned[c0+k], span_widths[k]-colw[c0+k])
                    continue
                }
            }
            have: f32 = 0
            n_flex := 0
            for c in c0 ..< c0 + s {
                t := grid_track_at(b, c)
                if t.kind == .Fixed {
                    need -= t.value // trilha fixa não cresce: sai da conta
                } else if min_content && t.kind == .Fr {
                    // fr sob min-content fica na base (0) e não come da conta
                } else {
                    have += colw[c]
                    n_flex += 1
                }
            }
            if n_flex == 0 || need <= have do continue
            extra := (need - have) / f32(n_flex)
            for c in c0 ..< c0 + s {
                t := grid_track_at(b, c)
                if t.kind == .Fixed do continue
                if min_content && t.kind == .Fr do continue
                planned[c] = max(planned[c], extra)
            }
        }
        for c in 0 ..< ncols do colw[c] += planned[c]
    }

    // In an indefinite axis, all flexible tracks share one fraction. A wide
    // item in a 1fr track therefore also enlarges its 2fr neighbour.
    if !min_content {
        fraction: f32 = 0
        for c in 0 ..< ncols {
            t := grid_track_at(b, c)
            if t.kind == .Fr && t.value > 0 do fraction = max(fraction, max(colw[c], t.min_px) / max(t.value, 1))
        }
        for c in 0 ..< ncols {
            t := grid_track_at(b, c)
            if t.kind == .Fr do colw[c] = max(colw[c], fraction * t.value)
        }
    }

    total: f32 = 0
    for c in 0 ..< ncols {
        t := grid_track_at(b, c)
        w := colw[c]
        // px fixo sobrepõe o conteúdo; fr/auto/fit-content (→ .Auto)/% usam o conteúdo.
        // O piso de minmax (min_px/min_pct→px) ainda vale.
        if t.kind == .Fixed do w = t.value
        if m := t.min_px; m > w do w = m
        total += w
    }
    total += col_gap * f32(max(0, ncols - 1))
    return total
}

// Margem HORIZONTAL de um ÁTOMO inline (inline-block/inline-flex/…), para as três
// medições intrínsecas abaixo. O layout da linha lê as margens efetivas de
// `bx.x`/`bx.margin[1]` (ver o case .InlineBox), mas aqui `layout_box` ainda não
// rodou — sobram os valores do CSS, que para o eixo horizontal bastam: os defaults
// de UA (block_style) só têm margem VERTICAL. Sem isto o intrínseco ficaria menor
// que o avanço real da linha e um pai shrink-to-fit quebraria a linha à toa.
@(private="file")
atom_margin_x :: proc(bx: ^Box) -> f32 {
    if bx == nil do return 0
    return bx.margin[3] + bx.margin[1]
}

// Espelho do inline_max_width: em vez de SOMAR a linha inteira, devolve o maior
// TRECHO INDIVISÍVEL — o que sobra quando se quebra em toda oportunidade.
//
// ⚠️ O que define o trecho NÃO é "uma palavra": é o mesmo teste que o laço de
// quebra do layout_inline faz — só há oportunidade de quebra ANTES de um item com
// `!it.nowrap`. Com `white-space:nowrap` todos os itens vêm com `nowrap=true`, o
// trecho engole a linha toda e min-content == max-content. Medir "a palavra mais
// larga" ali SUBESTIMA: era o que deixava o `Open Source` do menu do GitHub
// recortado (o botão tem `white-space:nowrap` e ficava do tamanho de "Source").
// O espaço entre palavras É a oportunidade de quebra, então ele só conta DENTRO
// de um trecho que não pode quebrar.
@(private="file")
inline_min_width :: proc(b: ^Box) -> f32 {
    restore_text_fragments(b)
    maxw, run: f32 = 0, 0
    for &it in b.inlines {
        if it.kind == .Break {
            if run > maxw do maxw = run
            run = 0
            continue
        }
        w, sp: f32 = 0, 0
        #partial switch it.kind {
        case .Word:
            word_width(&it)
            if it.tab_columns != 0 do it.text_w = tab_advance(&it, it.nowrap ? run : 0, b.word_spacing)
            text_w := it.text_w
            if it.min_break && !it.nowrap && it.font != nil {
                text_w = 0
                off := 0
                for off < len(it.text) {
                    end := text_cluster_end(it.text, off)
                    seg := it
                    seg.text = it.text[off:end]; seg.text_w = 0
                    text_w = max(text_w, word_width(&seg))
                    off = end
                }
            }
            w = it.pad_before + (it.hanging_space ? 0 : text_w) + it.pad_after
            sp = it.space_before ? space_adv(&it) + b.word_spacing : 0
        case .Image:
            iw, _ := inline_img_dims(&it, FLT_MAX)
            w = it.pad_before + iw + it.pad_after
            sp = it.space_before ? 4 : 0
        case .InlineBox:
            w = it.pad_before + (it.box != nil ? measure_min_content_w(it.box) + atom_margin_x(it.box) : 0) + it.pad_after
            sp = it.space_before ? 4 : 0
        }
        if it.nowrap {
            run += sp + w // não pode quebrar antes: continua o MESMO trecho
        } else {
            if run > maxw do maxw = run
            run = w // quebra aqui: o espaço anterior some com a quebra
        }
        if run > maxw do maxw = run
    }
    return maxw
}

@(private="file")
inline_max_width :: proc(b: ^Box) -> f32 {
    restore_text_fragments(b)
    maxl, cur, trailing: f32 = 0, 0, 0
    for &it in b.inlines {
        switch it.kind {
        case .Break:
            maxl = max(maxl, cur - trailing)
            cur = 0; trailing = 0
        case .Word:
            word_width(&it)
            if it.tab_columns != 0 do it.text_w = tab_advance(&it, cur + it.pad_before, b.word_spacing)
            cur += (it.space_before ? space_adv(&it) + b.word_spacing : 0) + it.pad_before + it.text_w + it.pad_after
            if it.hanging_space do trailing += it.text_w; else do trailing = 0
        case .Image:
            trailing = 0
            iw, _ := inline_img_dims(&it, FLT_MAX)
            cur += (it.space_before ? 4 : 0) + it.pad_before + iw + it.pad_after
        case .InlineBox:
            trailing = 0
            cur += (it.space_before ? 4 : 0) + it.pad_before + (it.box != nil ? measure_intrinsic_w(it.box) + atom_margin_x(it.box) : 0) + it.pad_after
        }
    }
    maxl = max(maxl, cur - trailing)
    return maxl
}

// Deslocamento inicial e espaçamento entre itens conforme justify-content.
// Posição estática ALINHADA de filhos abspos de um container flex: grava na caixa
// o content box do flex + o tipo de alinhamento por eixo, p/ place_absolute
// centralizar/ancorar a margin box (usado quando o abspos não tem inset no eixo).
// cont_h = altura do content box do container (definida) p/ o eixo cruzado (row).
@(private="file")
just_off :: proc(j: Flex_Just) -> u8 {
    switch j {
    case .Center, .Around, .Evenly: return 1
    case .End:                      return 2
    case .Start, .Between:          return 0
    }
    return 0
}
@(private="file")
align_off :: proc(a: Flex_Align) -> u8 {
    #partial switch a {
    case .Center: return 1
    case .End:    return 2
    }
    return 0 // Stretch/Start → início (abspos não estica)
}
@(private="file")
set_flex_static :: proc(b: ^Box, cont_h: f32) {
    row := b.flex_dir == .Row
    jo := just_off(b.justify)
    ao := align_off(b.align_items)
    for child in b.children {
        if child.pos != .Absolute && child.pos != .Fixed do continue
        child.static_flex = true
        child.static_x = b.content_x; child.static_y = b.content_y
        child.static_cw = b.content_w; child.static_ch = cont_h
        // eixo principal = justify; cruzado = align. row: main=x; column: main=y.
        child.static_ax = row ? jo : ao
        child.static_ay = row ? ao : jo
    }
}

@(private="file")
flex_justify :: proc(j: Flex_Just, free, gap: f32, n: int, unsafe := false) -> (start, between: f32) {
    if free <= 0 || n <= 0 {
        // `unsafe center|end`: honra o alinhamento mesmo TRANSBORDANDO (o conteúdo
        // sai pelo lado do início). Quem chama passa a sobra CRUA (negativa). Os
        // space-* têm fallback seguro na própria spec e ficam no início.
        if unsafe && free < 0 {
            #partial switch j {
            case .Center: return free / 2, gap
            case .End:    return free, gap
            }
        }
        return 0, gap
    }
    switch j {
    case .Start:   return 0, gap
    case .Center:  return free / 2, gap
    case .End:     return free, gap
    case .Between: return 0, n > 1 ? gap + free / f32(n - 1) : gap
    case .Around:  u := free / f32(n);     return u / 2, gap + u
    case .Evenly:  u := free / f32(n + 1); return u, gap + u
    }
    return 0, gap
}

// row-reverse/column-reverse invertem o eixo principal: main-start passa p/ o
// fim, então flex-start empacota no fim e vice-versa (center/space-* são
// simétricos e não mudam). Os itens já vêm reordenados por flex_ordered_children.
@(private="file")
justify_for_reverse :: proc(j: Flex_Just, reverse: bool) -> Flex_Just {
    if !reverse do return j
    #partial switch j {
    case .Start: return .End
    case .End:   return .Start
    }
    return j
}

// Alinhamento cruzado efetivo de um item: align-self (se definido) sobrescreve
// o align-items do container.
@(private="file")
item_cross_align :: proc(b, c: ^Box) -> Flex_Align {
    return c.align_self if c.has_align_self else b.align_items
}
// ...e o `safe` que acompanha esse alinhamento (vem do MESMO lugar que o valor).
@(private="file")
item_cross_safe :: proc(b, c: ^Box) -> bool {
    return (c.has_align_self ? c.align_self_ovf : b.align_items_ovf) == .Safe
}
// `safe center|end`: se o item TRANSBORDA o espaço de alinhamento, cai p/ start
// (CSS Align §4.4) — em vez de sair pelo lado do início, onde não há rolagem.
@(private="file")
safe_align :: proc(a: Flex_Align, safe: bool, space, sz: f32) -> Flex_Align {
    if safe && sz > space && (a == .Center || a == .End) do return .Start
    return a
}

// Estica o item no eixo CRUZADO de uma COLUNA flex (= a largura)? `stretch` só
// vale para tamanho AUTO: com width do CSS ou intrínseca (min/max/fit-content) o
// item mantém a própria largura e fica no início da linha (stretch degrada p/
// start, como na spec). Os outros dois containers já faziam isto no eixo deles —
// `stretch_w` no grid e `!c.has_height` no flex_row_line —, só a coluna esticava
// SEMPRE: uma width definida (e, com ela, o tamanho arrastado pela alça de
// `resize`) era simplesmente atropelada pela largura do container.
// ⚠️ def_w (width do CSS), NÃO has_width: controle de formulário ganha has_width
// SINTÉTICO (cols/rows) mesmo com width:auto e DEVE esticar — mesma nota do grid.
// Usado nas DUAS passadas da coluna (mede e posiciona); é uma função só de
// propósito, porque as duas divergirem é o bug de novo, calado.
@(private="file")
flex_col_stretch_w :: proc(b, c: ^Box) -> bool {
    return item_cross_align(b, c) == .Stretch && !c.def_w && !c.width_mc
}

// Deslocamento no eixo cruzado conforme align-items (line = tamanho da linha).
@(private="file")
flex_align :: proc(a: Flex_Align, line, sz: f32) -> f32 {
    switch a {
    case .Center: return (line - sz) / 2
    case .End:    return line - sz
    case .Start, .Stretch, .Baseline, .LastBaseline:
    }
    return 0
}

// ── Posicionamento absoluto (passe pós-layout) ───────────────────────────────
// Coloca caixas position:absolute/fixed (já fora do fluxo) relativo ao bloco
// contendor: o ancestral posicionado mais próximo (absolute) ou a página (fixed).

Reparent :: struct { child, from, to, anchor: ^Box }

// Um box AGRUPA a pintura dos descendentes (layer/contexto de empilhamento que o
// içamento NÃO pode atravessar): opacity<1, filter, mix-blend-mode, transform. Se
// existir um grupo desses entre o abspos e seu CB, o abspos deve pintar DENTRO do
// grupo (ex.: abspos sob opacity:0.5 recebe a opacidade), então não içamos.
@(private="file")
forms_group :: proc(b: ^Box) -> bool {
    return b.inline_parent_effect != nil || creates_stacking_context(b) || b.hover.has_opacity || b.hover.has_transform || b.trans[.Opacity].on || b.trans[.Transform].on
}

// ── BBOX DE SUBÁRVORE ────────────────────────────────────────────────────────
// COMPILE-GATED (`-define:SUBBBOX=true`) e DESLIGADO por padrão: medido em
// 2026-08-02, a passada custa **9%** do tempo de render numa página de 8.000
// caixas, e HOJE não há consumidor — nada cula por ela ainda. Ligar só junto com
// `-define:UIPROF=true`, que é quem imprime a validação.
//
// VEREDITO DA VALIDAÇÃO (github + w3.org + wikipedia): o bbox está CORRETO —
// **0 violações** de contenção contra o bbox real dos vértices. O que o inviabiliza
// é o PREDICADO DE SEGURANÇA: `sub_safe` é falso em 95–100% das layers, porque um
// único descendente fora de fluxo envenena toda a cadeia de ancestrais, e
// out-of-flow é **13% de TODAS as caixas** nos dois sites (transform 12% e
// transition 9% no github; ZERO nos dois no w3.org, onde posição sozinha já
// derruba 100%).
// ⇒ Para o culling virar realidade, `pos` tem de ser TRATADO em vez de envenenar:
//   um segundo retângulo para o conteúdo fora de fluxo (que é pintado com offset
//   (0,0), logo já está em espaço global e não acompanha o offset do ancestral).
SUBBBOX :: #config(SUBBBOX, false)

when SUBBBOX {
    // `node` existe para PROVAR o pareamento: o PC_LayerBegin carrega o mesmo
    // ponteiro, então consumir a fila fora de ordem é detectável — contagem
    // igual dos dois lados NÃO prova ordem igual.
    Pred_BBox :: struct { x0, y0, x1, y1: f32, safe: bool, has_abs: bool, ncmd: int, node: rawptr, desc: string,
                          nf: int, famt: f32, bw: f32, grad: bool, bgimg: bool, bgfix: bool, nbg: int }
    g_pred_bbox: [dynamic]Pred_BBox // fila por frame, em ordem de emissão
    g_pred_i:    int
    g_bb_worst:  [256]u8 // descrição do PIOR violador (buffer fixo: o report sai no exit)
    g_bb_worst_n: int
    g_bb_wp: [4]f32 // retângulo PREVISTO do pior violador
    g_bb_wr: [4]f32 // retângulo REAL (vértices) do pior violador
    g_bb_wn: int    // nº de filhos do pior violador (a subárvore tinha o que somar?)
    g_bb_wv: int    // nº de vértices que o segmento dele gerou
    g_bb_wa: bool   // tinha conteúdo fora de fluxo?
    g_bb_wf: int; g_bb_wfa: f32; g_bb_wbw: f32
    g_bb_wg, g_bb_wi, g_bb_wx: bool; g_bb_wnb: int
}

// Preenche b.sub_* e b.sub_safe para a subárvore inteira. Bottom-up, O(nós).
// TEM de rodar DEPOIS de layout_absolutes (que posiciona os out-of-flow) e a cada
// frame, porque `scroll_y` de container rolável muda sem relayout.
//
// O invariante que ele promete, e que a sonda de validação confere:
//   se sub_safe, então tudo que `paint_box(b, ox, oy)` pinta cai dentro de
//   [sub_x0+ox, sub_x1+ox] × [sub_y0+oy, sub_y1+oy].
//
// ⚠️ São QUATRO fórmulas de offset diferentes no paint, e cada uma é uma chance de
// errar em silêncio:
//   filho em fluxo    → ox2 = ox + rel_dx           (e oy2 − scroll_y se rolável)
//   filho abs/fixed   → (0, 0)                       ⇒ NÃO acompanha o offset
//   item InlineBox    → b.content_x + ox + it.x
//   fixed/sticky      → compensado por scroll no PRÓPRIO filho
// Só a primeira e a terceira são expressáveis como "bbox + offset"; as outras
// derrubam sub_safe.
compute_subtree_bbox :: proc(b: ^Box) {
    // extensão PRÓPRIA. Com ox=0 temos ox2 = rel_dx, então a border box cai em
    // (x + rel_dx, y + rel_dy).
    bx := b.x + b.rel_dx
    by := b.y + b.rel_dy
    x0, y0, x1, y1 := bx, by, bx + b.w, by + b.h

    // outline pinta FORA da border box (não afeta layout, afeta pixel)
    if b.outline_w > 0 {
        o := b.outline_w + max(b.outline_off, 0)
        x0 = min(x0, bx - o); y0 = min(y0, by - o)
        x1 = max(x1, bx + b.w + o); y1 = max(y1, by + b.h + o)
    }
    // box-shadow externa: deslocamento + spread + ALCANCE do blur (~3σ). Usa o
    // mesmo blur_spread que composite_layer usa na margem de filtro — se um dia
    // divergirem, a sombra é cortada numa borda reta (a armadilha já anotada lá).
    // Include both states: hover can introduce ink outside the idle bounds.
    for i in 0 ..< b.shadow_n + b.hover.shadow_n {
        sh := i < b.shadow_n ? b.shadows[i] : b.hover.shadows[i - b.shadow_n]
        if sh.inset do continue
        sp := sh.spread + blur_spread(sh.blur)
        x0 = min(x0, bx + sh.dx - sp);          y0 = min(y0, by + sh.dy - sp)
        x1 = max(x1, bx + b.w + sh.dx + sp);    y1 = max(y1, by + b.h + sh.dy + sp)
    }

    // acumulador do 2º retângulo (espaço GLOBAL, não acompanha offset)
    ax0, ay0, ax1, ay1 := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
    hasa := false
    ac :: proc(ax0, ay0, ax1, ay1: ^f32, hasa: ^bool, x0, y0, x1, y1: f32) {
        ax0^ = min(ax0^, x0); ay0^ = min(ay0^, y0)
        ax1^ = max(ax1^, x1); ay1^ = max(ay1^, y1)
        hasa^ = true
    }

    // Fixed/Sticky continuam envenenando: o scroll é compensado no PRÓPRIO filho
    // (paint_box soma GetScrollY ao oy2 dele), então nem o espaço local nem o
    // global os descrevem. São muito mais raros que Absolute — que agora é tratado.
    // FILTRO da própria caixa. Quando ela vira layer, `composite_layer` compõe a
    // textura num retângulo EXPANDIDO por (mx,my) — e é esse AddImage que gera os
    // vértices vistos pelo pai. Sem espelhar a mesma conta aqui, o bbox do pai
    // fica menor que o desenho: medido no `.glow` do github, 212 px na horizontal
    // e 81 na vertical, simétricos nos quatro lados.
    // ⚠️ Tem de usar o MESMO blur_spread do composite_layer (~3σ); se divergirem,
    // um corta o que o outro previu.
    for i in 0 ..< b.n_filters {
        f := b.filters[i]
        #partial switch f.kind {
        case .Blur:
            sp := blur_spread(f.amount)
            x0 -= sp; y0 -= sp; x1 += sp; y1 += sp
        case .DropShadow:
            sp := blur_spread(f.amount * 0.5)
            x0 -= abs(f.dx) + sp; y0 -= abs(f.dy) + sp
            x1 += abs(f.dx) + sp; y1 += abs(f.dy) + sp
        }
    }

    safe := b.pos != .Fixed && b.pos != .Sticky
    when UIPROF {
        g_uiprof.hz_boxes += 1
        if !safe do g_uiprof.hz_pos += 1
        if b.has_transform || b.has_xform_matrix do g_uiprof.hz_xform += 1
        if b.bg_canvas do g_uiprof.hz_canvas += 1
        if trans_any(b.trans) && b.node != nil do g_uiprof.hz_trans += 1
    }
    if b.has_transform || b.has_xform_matrix do safe = false
    if b.bg_canvas do safe = false
    // <svg>/<canvas> pintam a partir do DOM / da lista de comandos 2D, e
    // `background-attachment:fixed` emite um gradiente do tamanho do VIEWPORT —
    // nada disso está em b.children nem em b.inlines, então este passeio não vê.
    // ⚠️ MEDIDO 2026-08-02: marcar os três NÃO reduziu as violações (w3 672→638,
    // github 516→435, wiki 1716→1962) ⇒ NÃO são a causa do erro atual. Ficam por
    // conservadorismo (a lacuna é real), mas a causa é OUTRA — ver o comentário
    // do bloco de itens inline abaixo.
    if b.is_svg || b.is_canvas || b.bg_fixed do safe = false
    // transition/animação avança DENTRO do paint_box: pular a caixa congelaria o
    // relógio e ela reapareceria no tempo errado ao voltar para a tela.
    if trans_any(b.trans) && b.node != nil do safe = false

    // O deslocamento que o paint aplica ao conteúdo em fluxo é (rel_dx, rel_dy),
    // menos o scroll próprio quando esta caixa é um container rolável. Vale para
    // os filhos E para os itens inline (paint_inline recebe ox2/child_oy).
    dy := b.rel_dy - (b.overflow_scroll ? b.scroll_y : 0)
    dx := b.rel_dx - (b.overflow_scroll ? b.scroll_x : 0)

    // itens inline. Palavras/imagens ficam na content box; um InlineBox é uma
    // caixa própria pintada em (content_x + ox2 + it.x, content_y + child_oy + it.y).
    //
    // ⚠️⚠️ AQUI ESTÁ A LACUNA ABERTA (medida, não suposta). Os piores violadores
    // nos três sites são caixas inline MINÚSCULAS que viraram layer:
    //   w3      <span .visuallyhidden>          w=0 h=1  → estoura 32,0 px
    //   wiki    <span .vector-dropdown-label>   w=1 h=1  → estoura 23,7 px
    //   github  <div .lp-HeroCarousel-background> 1920×809 → estoura 1634 px
    // O item inline pertence ao BLOCO que o contém, não ao elemento inline de onde
    // o texto veio (ver [[inline-element-identity]]): um <span> com opacity vira
    // Box de 1px cujo TEXTO mora na lista `inlines` do bloco PAI. Logo o passeio
    // por b.children/b.inlines não descreve o que o segmento da layer desenha.
    // ⇒ Enquanto isso não for resolvido, o bbox NÃO pode autorizar culling.
    for &it in b.inlines {
        ix := b.content_x + it.x + dx
        iy := b.content_y + it.y + dy
        x0 = min(x0, ix); y0 = min(y0, iy)
        x1 = max(x1, ix + it.w); y1 = max(y1, iy + it.h)
        if it.kind == .InlineBox && it.box != nil {
            compute_subtree_bbox(it.box)
            if !it.box.sub_safe do safe = false
            x0 = min(x0, ix + it.box.sub_x0); y0 = min(y0, iy + it.box.sub_y0)
            x1 = max(x1, ix + it.box.sub_x1); y1 = max(y1, iy + it.box.sub_y1)
            // o out-of-flow de dentro dele já é global: entra sem deslocamento
            if it.box.has_abs do ac(&ax0, &ay0, &ax1, &ay1, &hasa, it.box.abs_x0, it.box.abs_y0, it.box.abs_x1, it.box.abs_y1)
        }
    }

    for child in b.children {
        compute_subtree_bbox(child)
        if !child.sub_safe do safe = false
        // O out-of-flow de qualquer filho já está em espaço global — sobe sem
        // deslocamento nenhum, seja o filho em fluxo ou não.
        if child.has_abs do ac(&ax0, &ay0, &ax1, &ay1, &hasa, child.abs_x0, child.abs_y0, child.abs_x1, child.abs_y1)

        if child.pos == .Absolute {
            // Pintado por emit_stacked com offset (0,0) ⇒ o sub_* dele JÁ é a
            // extensão global. Vai para o 2º retângulo, sem deslocamento.
            ac(&ax0, &ay0, &ax1, &ay1, &hasa, child.sub_x0, child.sub_y0, child.sub_x1, child.sub_y1)
            continue
        }
        if child.pos == .Fixed || child.pos == .Sticky {
            safe = false // já derrubado pelo próprio filho, mas explícito
            continue
        }
        x0 = min(x0, child.sub_x0 + dx); y0 = min(y0, child.sub_y0 + dy)
        x1 = max(x1, child.sub_x1 + dx); y1 = max(y1, child.sub_y1 + dy)
    }

    b.sub_x0, b.sub_y0, b.sub_x1, b.sub_y1 = x0, y0, x1, y1
    b.abs_x0, b.abs_y0, b.abs_x1, b.abs_y1 = ax0, ay0, ax1, ay1
    b.has_abs  = hasa
    b.sub_safe = safe
}

layout_absolutes :: proc(b: ^Box, cb, page: Rect) {
    rep := make([dynamic]Reparent, context.temp_allocator)
    layout_absolutes_rec(b, cb, page, b, b, false, false, b, b, &rep)
    // IÇAMENTO DE EMPILHAMENTO: um abspos cujo bloco contenedor é um ancestral
    // NÃO-pai (ex.: abspos dentro de um flex/bloco estático, mas contido por um
    // `position:relative` acima) pinta, no nosso modelo por-caixa, DENTRO da subárvore
    // do pai em-fluxo → um irmão posicionado do CB pintaria por cima. Move a caixa p/
    // os filhos do box-CB (coords já são absolutas). INSERE logo após o ÂNCORA (o
    // filho direto do CB que o contém) p/ preservar a ordem de árvore relativa aos
    // outros filhos do CB. Processa em ordem REVERSA p/ que vários içados sob o mesmo
    // âncora fiquem na ordem de árvore (cada um inserido em âncora+1).
    #reverse for r in rep {
        r.child.reparented = true
        for c, idx in r.from.children {
            if c == r.child { ordered_remove(&r.from.children, idx); break }
        }
        ai := -1
        for c, idx in r.to.children {
            if c == r.anchor { ai = idx; break }
        }
        if ai >= 0 do inject_at(&r.to.children, ai + 1, r.child)
        else       do append(&r.to.children, r.child)
    }
}

// Registra, no momento do IÇAMENTO, onde a posição estática fica em relação ao
// ÂNCORA (o filho direto do bloco contenedor que continha esta caixa). Depois do
// içamento a caixa some do fluxo do pai original, e o passe seguinte só sabe
// recompor a estática por aqui. Sem `has_static` não há o que preservar (ex.:
// abspos dentro de caixa de formatação inline, que nunca grava estática).
@(private="file")
mark_hoisted :: proc(child, anchor: ^Box) {
    if anchor == nil || anchor == child || !child.has_static do return
    if child.hoisted do return // já registrado num passe anterior: o delta é o mesmo
    child.hoisted = true
    child.hoist_anchor = anchor
    child.hoist_dx = child.static_x - anchor.x
    child.hoist_dy = child.static_y - anchor.y
}

// `anchor` é a âncora de içamento para ABSOLUTE (filho direto de cb_box) e
// `anchor_fix` a de FIXED (filho direto de page_box). São DUAS porque os dois têm
// blocos contenedores diferentes: `position:relative` estabelece CB para absolute e
// NÃO para fixed. Enquanto havia só uma, um `position:fixed` sob um ancestral
// relative recebia como âncora ELE MESMO — `mark_hoisted` desiste nesse caso
// (`anchor == child`), a caixa era içada SEM registro, e no 2º passe de layout a
// posição estática era relida de onde a caixa foi PARAR (fim do documento). Sintoma:
// o hero do github.com aparecia em y=164 no 1º frame e em y=13601 do 2º em diante —
// invisível. Só o `--render` mostrava; o `--dumplayout` faz um passe só e acertava
// (mesma assinatura do M196).
@(private="file")
layout_absolutes_rec :: proc(b: ^Box, cb, page: Rect, cb_box, page_box: ^Box, grouped, grouped_fixed: bool, anchor, anchor_fix: ^Box, rep: ^[dynamic]Reparent) {
    my := Rect{b.x, b.y, b.w, b.h}
    // bloco contenedor p/ ABSOLUTE: ancestral posicionado (position!=static) OU que
    // estabelece CB via will-change (position/transform/filter/…). Para FIXED: só os
    // gatilhos transform-like (cb_fixed), NÃO `position` — daí os dois níveis separados.
    est_abs := b.pos != .Static || b.cb_abs
    child_cb  := est_abs ? my : cb
    child_fix := b.cb_fixed ? my : page
    ccb_box := est_abs ? b : cb_box
    cfx_box := b.cb_fixed ? b : page_box
    // grupo de pintura no caminho CB→este box (reseta quando este box VIRA o CB).
    cgroup := est_abs ? false : (grouped || forms_group(b))
    // Fixed has a different containing block: a positioned ancestor can still
    // be a stacking barrier between it and the viewport.
    cgroup_fixed := b.cb_fixed ? false : (grouped_fixed || forms_group(b))
    for child in b.children {
        // âncora do içamento = o filho DIRETO do box-CB na cadeia até este filho.
        // Uma por eixo de contenção (ver o cabeçalho): `ccb_box` p/ absolute,
        // `cfx_box` p/ fixed. Usar a de absolute nos dois era o bug do M212.
        canchor     := (b == ccb_box) ? child : anchor
        canchor_fix := (b == cfx_box) ? child : anchor_fix
        switch child.pos {
        case .Static, .Relative, .Sticky: // sticky fica no fluxo (desloca só na pintura)
            layout_absolutes_rec(child, child_cb, child_fix, ccb_box, cfx_box, cgroup, cgroup_fixed, canchor, canchor_fix, rep)
        case .Absolute:
            place_absolute(child, grid_abs_cb(b, child, child_cb, est_abs))
            if ccb_box != b && ccb_box != nil && !cgroup && child.inline_parent_effect == nil {
                mark_hoisted(child, canchor)
                append(rep, Reparent{child, b, ccb_box, canchor})
            }
            layout_absolutes_rec(child, Rect{child.x, child.y, child.w, child.h}, child_fix, child, cfx_box, false, cgroup_fixed, child, canchor_fix, rep)
        case .Fixed:
            place_absolute(child, grid_abs_cb(b, child, child_fix, b.cb_fixed))
            if cfx_box != b && cfx_box != nil && !cgroup_fixed && child.inline_parent_effect == nil {
                mark_hoisted(child, canchor_fix)
                append(rep, Reparent{child, b, cfx_box, canchor_fix})
            }
            layout_absolutes_rec(child, Rect{child.x, child.y, child.w, child.h}, child_fix, child, cfx_box, false, cgroup_fixed, child, child, rep)
        }
    }
    // Inline atoms use local coordinates. Visit their out-of-flow descendants
    // with containing rectangles translated into that space; keep them there
    // rather than hoisting into a tree with a different coordinate origin.
    for it in b.inlines {
        if it.kind != .InlineBox || it.box == nil do continue
        dx := b.content_x + it.x; dy := b.content_y + it.y
        local_cb := Rect{child_cb.x-dx, child_cb.y-dy, child_cb.w, child_cb.h}
        local_fix := Rect{child_fix.x-dx, child_fix.y-dy, child_fix.w, child_fix.h}
        layout_absolutes_rec(it.box, local_cb, local_fix, ccb_box, cfx_box,
                             true, true, it.box, it.box, rep)
    }

}

// Bloco contenedor de um filho absoluto de GRID: a área que grid-column/grid-row
// escolheram (CSS Grid §9.1), gravada por layout_grid em `gabs`. Linha auto = a
// borda do bloco contenedor normal. `is_cb` = o grid `b` é o bloco contenedor.
@(private="file")
grid_abs_cb :: proc(b, c: ^Box, cb: Rect, is_cb: bool) -> Rect {
    if !is_cb || !b.is_grid || c.reparented do return cb
    if c.gabs_has == ([4]bool{}) do return cb
    x0, y0, x1, y1 := cb.x, cb.y, cb.x + cb.w, cb.y + cb.h
    if c.gabs_has[0] do x0 = b.content_x + c.gabs[0]
    if c.gabs_has[1] do y0 = b.content_y + c.gabs[1]
    if c.gabs_has[2] do x1 = b.content_x + c.gabs[2]
    if c.gabs_has[3] do y1 = b.content_y + c.gabs[3]
    return Rect{x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

@(private="file")
place_absolute :: proc(c: ^Box, cb: Rect) {
    has_t := c.inset_has[0]; has_r := c.inset_has[1]
    has_b := c.inset_has[2]; has_l := c.inset_has[3]
    ti := resolve_inset(c, 0, cb.h); ri := resolve_inset(c, 1, cb.w)
    bi := resolve_inset(c, 2, cb.h); li := resolve_inset(c, 3, cb.w)

    // largura: se ambos os lados opostos setados e sem tamanho explícito, a caixa
    // estica entre eles; senão (largura auto) faz shrink-to-fit no conteúdo — sem
    // isso, todo absoluto vira uma faixa de largura total e tudo se sobrepõe.
    // Tabelas (display:table) NUNCA esticam entre insets: fazem shrink-to-fit e as
    // auto-margens centralizam (CSS2.1 §10.3.7 — usado no centering left:0;right:0;margin:auto).
    shrink := c.is_table
    fw: f32 = -1
    fh: f32 = -1
    if !c.has_width && !c.width_mc {
        if has_l && has_r && !shrink {
            fw = cb.w - li - ri - c.margin[3] - c.margin[1]
        } else {
            available := cb.w - (has_l ? li : 0) - (has_r ? ri : 0) - c.margin[3] - c.margin[1]
            fw = min(measure_intrinsic_w(c), max(measure_intrinsic_w(c, true), available))
        }
    }
    if c.width_fit {
        available := cb.w - (has_l ? li : 0) - (has_r ? ri : 0) - c.margin[3] - c.margin[1]
        fw = intrinsic_used_width(c, available)
    }
    // height:N% de um ABSOLUTO resolve contra a altura do bloco contenedor, que é
    // exatamente o `cb.h` daqui — e que só ESTE sítio conhece. O layout_box não
    // resolve fração de altura sozinho: no fluxo normal quem a converte em px é o
    // PAI, que a manda por `force_h` (ver a chamada com ch_fh). No caminho do
    // absoluto ninguém fazia isso, `fh` ficava -1 e a caixa saía com ALTURA ZERO —
    // e o idioma atingido é dos mais comuns da web: `position:absolute; top:0;
    // left:0; width:100%; height:100%` (overlay, mídia que preenche o pai). A
    // largura escapou porque `width:N%` grava has_width=true+width_pct e o
    // layout_box a resolve contra o avail_w que já recebe; a altura usa a
    // convenção OPOSTA (has_height=false + has_height_pct).
    // Mesma lição do M228/M229: quem IMPÕE tamanho tem de resolvê-lo por INTEIRO.
    //
    // Precede o esticar entre insets porque com `height` não-auto a spec ignora o
    // `bottom` (CSS2.1 §10.6.4: o over-constrained resolve descartando bottom).
    if c.has_height_pct {
        fh = max(0, pct_resolve(c.height_pct, c.height_pct_off, cb.h, c.height_bd))
    } else if !c.has_height && has_t && has_b && !shrink {
        fh = cb.h - ti - bi - c.margin[0] - c.margin[2]
    }
    // min/max-height em % têm a MESMA base e também só o CB a conhece; sem isto o
    // stretch_clamp logo abaixo compararia contra um limite nunca resolvido (o
    // comentário dele já avisa que no eixo de bloco os % chegam prontos daqui).
    resolve_child_minmax_h(c, cb.h)
    // Mais um sítio que IMPÕE tamanho e por isso tem de clampar (ver stretch_clamp):
    // esticar entre `left:0;right:0` ignorava max-width, e é justamente aí que mora
    // o idioma `left:0;right:0;max-width:Npx;margin:auto` (o centrado da página).
    if fw >= 0 do fw = stretch_clamp(c, .Row, fw, cb.w)
    if fh >= 0 do fh = stretch_clamp(c, .Column, fh, cb.h)

    layout_box(c, 0, 0, cb.w, fw, fh) // dimensiona (e posiciona a subárvore em ~0,0)

    // x/y: com AMBOS os insets opostos + margens auto, centraliza no vão livre
    // (dialog centrado); um lado com inset ancora nele; sem inset usa a posição
    // estática (onde a caixa cairia no fluxo), não o canto do contêiner.
    // offset de alinhamento da posição estática de flex: centraliza/ancora a MARGIN
    // box (margem-líder + border-box + margem-final) no content box do flex, e a
    // caixa fica APÓS a margem-líder (CSS Align — bate com center-003/004).
    salign :: proc(kind: u8, container, mbox: f32) -> f32 {
        switch kind { case 1: return (container - mbox) / 2; case 2: return container - mbox }
        return 0
    }
    x: f32
    if has_l && has_r && (c.margin_left_auto || c.margin_right_auto) {
        ml := c.margin_left_auto ? f32(0) : c.margin[3]
        mr := c.margin_right_auto ? f32(0) : c.margin[1]
        free := cb.w - li - ri - c.w - ml - mr
        if c.margin_left_auto {
            ml = c.margin_right_auto ? max(0, free / 2) : free
        }
        x = cb.x + li + ml
    } else if has_l {
        x = cb.x + li + (c.margin_left_auto ? 0 : c.margin[3])
    } else if has_r {
        x = cb.x + cb.w - ri - c.w - (c.margin_right_auto ? 0 : c.margin[1])
    } else if c.static_flex {
        mbw := c.margin[3] + c.w + c.margin[1]
        x = c.static_x + salign(c.static_ax, c.static_cw, mbw) + c.margin[3]
    } else {
        x = c.has_static ? c.static_x : cb.x
    }
    y: f32
    if has_t && has_b && (c.margin_top_auto || c.margin_bottom_auto) {
        mt := c.margin_top_auto ? f32(0) : c.margin[0]
        mb := c.margin_bottom_auto ? f32(0) : c.margin[2]
        free := cb.h - ti - bi - c.h - mt - mb
        if c.margin_top_auto do mt = c.margin_bottom_auto ? free / 2 : free
        y = cb.y + ti + mt
    } else if has_t {
        y = cb.y + ti + (c.margin_top_auto ? 0 : c.margin[0])
    } else if has_b {
        y = cb.y + cb.h - bi - c.h - (c.margin_bottom_auto ? 0 : c.margin[2])
    } else if c.static_flex {
        mbh := c.margin[0] + c.h + c.margin[2]
        y = c.static_y + salign(c.static_ay, c.static_ch, mbh) + c.margin[0]
    } else {
        y = c.has_static ? c.static_y : cb.y
    }

    when ABS_DEBUG {
        fmt.eprintf("[abs] tag=%s has_static=%v static_y=%.1f -> y=%.1f (cb.y=%.1f h=%.1f)\n",
            c.node != nil ? c.node.tag : "(pseudo)", c.has_static, c.static_y, y, cb.y, c.h)
    }
    // A estática do PRÓPRIO `c` é "onde ele cairia no fluxo": ela ORIGINOU o `y`
    // acima e não pode ser somada de volta nele (o abspos desceria um degrau por
    // passe de layout). A dos DESCENDENTES, ao contrário, é coordenada absoluta e
    // tem de acompanhar a subárvore — daí salvar/restaurar só a do topo.
    sx, sy := c.static_x, c.static_y
    translate_box(c, x - c.x, y - c.y)
    c.static_x, c.static_y = sx, sy
}

// Largura intrínseca (max-content) da border-box: a maior largura que o conteúdo
// pede sem quebrar além de <br>. Não chama layout_box (que encheria a largura);
// percorre a árvore direto. Usada no shrink-to-fit de absolutos com largura auto.
@(private="file")
intrinsic_border_w :: proc(b: ^Box) -> f32 {
    extra := b.padding[3] + b.padding[1] + bw_x(b)
    if b.has_width && !b.width_pct {
        return b.box_sizing == .Border ? b.width : b.width + extra
    }
    inner: f32 = 0
    if b.is_inline {
        line, mx: f32 = 0, 0
        for &it in b.inlines {
            switch it.kind {
            case .Break:
                if line > mx do mx = line
                line = 0
            case .Word:
                word_width(&it)
                if it.tab_columns != 0 do it.text_w = tab_advance(&it, line + it.pad_before, b.word_spacing)
                line += it.text_w + (it.space_before ? space_adv(&it) + b.word_spacing : 0) + it.pad_before + it.pad_after
            case .Image:
                line += (it.w > 0 ? it.w : 32) + it.pad_before + it.pad_after
            case .InlineBox:
                line += (it.space_before ? 4 : 0) + it.pad_before + (it.box != nil ? measure_intrinsic_w(it.box) + atom_margin_x(it.box) : 0) + it.pad_after
            }
        }
        if line > mx do mx = line
        inner = mx
    } else if b.is_flex && b.flex_dir == .Row {
        // linha flex: max-content é a soma dos itens (+ gaps)
        for c in b.children {
            inner += intrinsic_border_w(c) + c.margin[3] + c.margin[1]
        }
        if len(b.children) > 1 do inner += b.gap * f32(len(b.children) - 1)
    } else if b.kind == .Image {
        iw, _ := image_dims(b)
        inner = iw
    } else {
        // bloco / coluna flex / grid / tabela: a maior largura intrínseca dos filhos
        for c in b.children {
            if c.pos == .Absolute || c.pos == .Fixed do continue
            w := intrinsic_border_w(c) + c.margin[3] + c.margin[1]
            if w > inner do inner = w
        }
    }
    return inner + extra
}

@(private="file")
resolve_inset :: proc(b: ^Box, i: int, dim: f32) -> f32 {
    return b.inset_pct[i] ? b.inset[i] * dim + b.inset_off[i] : b.inset[i]
}

// Desloca a caixa e toda a subárvore (coords absolutas) por dx,dy.
//
// DELEGA para `translate_subtree` (M212): as duas eram cópias, e a de cá tinha
// esquecido de mover `static_x/static_y`. O efeito: `place_absolute` dimensiona a
// caixa em (0,0) — o que grava a estática dos DESCENDENTES absolutos em ~0 — e só
// depois translada para o lugar final; sem mover a estática junto, um absoluto SEM
// `top` dentro de outro absoluto ficava ancorado em y≈0. Era o `glow` do
// github.com: o pai `.lp-SectionHero-glow` estava certo em y=2875 e o filho em y=0,
// pintando uma faixa clara no topo da página, a 2900px de onde devia estar.
translate_box :: proc(b: ^Box, dx, dy: f32) {
    translate_subtree(b, dx, dy)
}

// ── Paint ────────────────────────────────────────────────────────────────────
//
// FASE 0 — command list como emenda (grava→replay, passthrough puro).
// paint_box GRAVA comandos num Painter em vez de desenhar direto no DrawList;
// replay_paint os reexecuta contra o DrawList real, NA MESMA ORDEM → zero
// mudança visual. A emenda existe para as próximas fases (reordenar por z-index
// sem 3 passadas; compositar layers offscreen p/ opacity de grupo/filter/blend).
// O trabalho de INPUT/estado (hover, scroll, click, transições, animações) segue
// no traversal (record); só o DESENHO é adiado. Os helpers de desenho ficam
// intocados — cada um vira uma variante de comando que os chama no replay.

Grad_Kind :: enum u8 { Flat, Rounded, RoundDiag, Radial, Conic }

// Um gradiente clipado ao texto de um elemento INLINE, atribuído pelo mesmo
// `ibg_grp` que já agrupa os itens de um elemento inline (o grupo é o run de
// palavras do span). Fica na Box que POSSUI os itens.
Inline_Grad :: struct { grp: u32, g: csspkg.Gradient }

Paint_Cmd :: union {
    PC_Shadow, PC_Gradient, PC_RectFilled, PC_RectMulti, PC_Rect, PC_BgImage, PC_Border, PC_BorderImage,
    PC_ControlMark, PC_Image, PC_TextInput, PC_MaskCorners, PC_InnerNotch, PC_InlineText,
    PC_Line, PC_PushClip, PC_PopClip, PC_XformBegin, PC_XformEnd, PC_ProjectEnd,
    PC_LayerBegin, PC_LayerEnd, PC_BackdropFilter, PC_Polyline, PC_Select, PC_RoundClipBegin,
    PC_ShadeGradBegin, PC_ShadeGradEnd,
}
PC_Shadow      :: struct { x0, y0, x1, y1, radius: f32, sh: Shadow, eff: f32, inset: bool }
// c0/c1 + clip: background-attachment:fixed posiciona o gradiente no VIEWPORT (p0/p1)
// e o RECORTA na caixa (c0/c1) — os painters de gradiente só têm um retângulo.
PC_Gradient    :: struct { p0, p1: im.Vec2, g: csspkg.Gradient, radius, eff: f32, kind: Grad_Kind, c0, c1: im.Vec2, clip: bool }
PC_RectFilled  :: struct { p0, p1: im.Vec2, col: u32, rounding: f32, flags: im.DrawFlags }
// Retângulo com cor por CANTO (AddRectFilledMultiColor interpola). Existe p/ o
// gradiente de SVG (M225): a rasterização por scanline emite um span de 1px por
// linha, e as duas cores das PONTAS dão a variação horizontal dentro do span.
PC_RectMulti   :: struct { p0, p1: im.Vec2, c_ul, c_ur, c_br, c_bl: u32 }
PC_Rect        :: struct { p0, p1: im.Vec2, col: u32, rounding: f32, flags: im.DrawFlags, thickness: f32 }
// o=origin (posiciona), c=clip (limita). layer = índice em b.bg_extra, ou -1 p/
// a camada 0 (que mora nos campos diretos da Box).
PC_BgImage     :: struct { o0, o1, c0, c1: im.Vec2, b: ^Box, eff: f32, layer: int }
PC_Border      :: struct { screen: im.Vec2, b: ^Box, cols: [4]u32, eff, radius: f32, flags: im.DrawFlags }
// border-image. Carrega TUDO que a borda normal carrega porque, se a imagem não
// estiver pronta (ou falhar), a spec manda desenhar a borda de sempre — e essa
// decisão só pode ser tomada na PINTURA, que é onde o cache de imagem responde.
PC_BorderImage :: struct { screen: im.Vec2, b: ^Box, cols: [4]u32, eff, radius: f32, flags: im.DrawFlags }
PC_ControlMark :: struct { screen: im.Vec2, b: ^Box, radius, eff: f32 }
PC_Image       :: struct { url: string, pos: im.Vec2, w, h: f32, fit: Obj_Fit, opa, px, py: f32, deco: bool, rounding: Image_Rounding }
PC_TextInput   :: struct { b: ^Box, screen: im.Vec2, eff: f32 }
PC_Select      :: struct { b: ^Box, screen: im.Vec2, eff: f32 }
PC_MaskCorners :: struct { x0, y0, x1, y1, radius: f32, flags: im.DrawFlags, col: u32 }
// Irmão do PC_MaskCorners para o ponto cego dele: o entalhe da curva INTERNA
// (padding-box). O MaskCorners só limpa o que passa da curva EXTERNA; com BORDA,
// o filho que preenche a padding-box mantém o canto QUADRADO (o clip do ImGui é
// retangular) e pinta por cima da faixa entre as duas curvas — a borda visível
// "abre" no canto. `bw` = larguras da borda [topo, dir, base, esq].
PC_InnerNotch :: struct { x0, y0, x1, y1: f32, bw: [4]f32, radius: f32, flags: im.DrawFlags, col: u32 }

// Compõe `src` (possivelmente translúcido) sobre `dst` (tido como opaco) e
// devolve cor OPACA. Convenção de cor do motor: byte alto 0 = opaco, 1..255 =
// alpha/255 (retrocompat com 0xRRGGBB).
bg_over :: proc(dst, src: u32) -> u32 {
    ab := (src >> 24) & 0xff
    if ab == 0 do return src & 0x00ffffff // src já é opaco: substitui
    a := f32(ab) / 255
    mix :: proc(d, s: f32, a: f32) -> u32 { return u32(clamp(s * a + d * (1 - a), 0, 255) + 0.5) }
    r := mix(f32((dst >> 16) & 0xff), f32((src >> 16) & 0xff), a)
    g := mix(f32((dst >>  8) & 0xff), f32((src >>  8) & 0xff), a)
    b := mix(f32( dst        & 0xff), f32( src        & 0xff), a)
    return (r << 16) | (g << 8) | b
}
PC_InlineText  :: struct { font: ^im.Font, size: f32, pos: im.Vec2, col: u32, text: string, spacing: f32, kerning: Font_Kerning }
PC_Line        :: struct { p0, p1: im.Vec2, col: u32 }
PC_PushClip    :: struct { min, max: im.Vec2 }
PC_PopClip     :: struct {}
// `background-clip: text` com gradiente. Marca o trecho de draw list cujos
// VÉRTICES devem ser recoloridos pelo gradiente (o mesmo mecanismo do
// PC_XformBegin/End, que já pós-processa vértices). Funciona porque o glifo do
// ImGui tem a cobertura na TEXTURA e a cor no vértice: trocar a cor do vértice
// pinta o glifo com a cor do gradiente naquele ponto, sem clip nem render target.
PC_ShadeGradBegin :: struct {}
PC_ShadeGradEnd   :: struct { p0, p1: im.Vec2, g: csspkg.Gradient, eff: f32 }
PC_ProjectEnd :: struct { m:XMatrix, keep_depth:bool }
PC_XformBegin  :: struct {}
PC_XformEnd    :: struct { cx, cy, a, b, c, d: f32 }
// group-opacity: os comandos entre Begin e End são renderizados numa textura
// offscreen (opacidade PRÓPRIA não bakeada) e compostos no dl pai a `opacity`.
// clip: forma de clip-path (kind=None = sem recorte); cb* = border-box em TELA,
// referência p/ resolver os % da forma na máscara.
// ⚠️ NÃO acrescente campos aqui sem medir: esta é a MAIOR variante da união
// Paint_Cmd (736 B medidos), então cada campo novo é pago por TODO comando —
// inclusive pelo PC_InlineText de cada palavra. Uma tentativa de carregar o bbox
// previsto aqui foi revertida por isso (Odin não aceita `when` em campo de
// struct, então não dá para condicioná-los).
PC_LayerBegin  :: struct { opacity: f32, blend: Blend_Mode, filters: [MAX_FILTERS]Filter_Op, n_filters: int, node: rawptr, backdrop: u32, clip: Clip_Shape, mask: csspkg.Gradient, cbx, cby, cbw, cbh: f32, mask_image: ^Mask_Image }
PC_LayerEnd    :: struct {}
PC_RoundClipBegin :: struct { node: rawptr, p0, p1: im.Vec2, rounding: Image_Rounding }
// backdrop-filter: filtra o BACKDROP (o `dl` acumulado até aqui) na região do
// border-box e desenha o resultado de volta, ANTES do fundo/conteúdo do elemento.
PC_BackdropFilter :: struct { x0, y0, x1, y1, radius: f32, filters: [MAX_FILTERS]Filter_Op, n: int }
// polilinha de SVG (pts em coords de tela; arena do frame). fill = preenche;
// senão traça com `thickness` (cantos/pontas arredondados, como os ícones lucide).
// `no_aa` = shape-rendering:crispEdges|optimizeSpeed. O ImGui deixa mexer nos
// flags do draw list POR PRIMITIVA, então basta apagar os bits de AA em volta
// desta chamada e devolvê-los depois.
PC_Polyline :: struct { pts: []im.Vec2, col: u32, thickness: f32, closed: bool, fill: bool, no_aa: bool }

Painter :: struct {
    cmds: [dynamic]Paint_Cmd,
}

// Fora da arena temporária: Paint_Cmd exige alinhamento de 32 bytes mesmo
// quando o buffer ultrapassa o bloco de 4 MB. Reutiliza a capacidade por frame.
@(private = "file", thread_local)
g_paint_cmds: [dynamic]Paint_Cmd

painter_begin :: proc() -> Painter {
    cmds := g_paint_cmds
    g_paint_cmds = {} // o Painter fica com a propriedade até painter_end
    if cmds == nil do cmds = make([dynamic]Paint_Cmd, 0, 256, runtime.heap_allocator())
    clear(&cmds)
    return Painter{cmds = cmds}
}

painter_end :: proc(pt: ^Painter) {
    clear(&pt.cmds) // referências ao DOM e à arena não sobrevivem ao frame
    delete(g_paint_cmds)
    g_paint_cmds = pt.cmds
    pt.cmds = {}
}

painter_cache_free :: proc() {
    delete(g_paint_cmds)
    g_paint_cmds = {}
}

emit :: #force_inline proc(pt: ^Painter, cmd: Paint_Cmd) {
    // S1: conta quantas vezes o buffer REALOCA. A hipótese sob teste é que o
    // `make([dynamic]^Box, temp)` do stack_sort de cada caixa de bloco fica
    // INTERCALADO com o crescimento de `cmds` na mesma arena, o que derrota o
    // resize in-place (que exige ser a última alocação do bloco) e faz cada
    // duplicação copiar o buffer inteiro — candidata à superlinearidade medida.
    when PAINTPROF {
        antes_n := len(pt.cmds)
        _, err := append(&pt.cmds, cmd)
        if err != nil || len(pt.cmds) == antes_n {
            if g_pp.append_fail == 0 do g_pp.append_fail_info = {cap(pt.cmds), int(err)}
            g_pp.append_fail += 1
        }
    } else when UIPROF {
        antes := cap(pt.cmds)
        append(&pt.cmds, cmd)
        if cap(pt.cmds) != antes do g_uiprof.n_reallocs += 1
    } else {
        append(&pt.cmds, cmd)
    }
}

// Desenha UMA linha de decoração (underline/overline/line-through) de x0 a x1,
// centrada verticalmente em yc, com espessura `thick`, cor `col` e traçado `style`.
// Sólida = PC_Line 1px quando thick<=1 (idêntico ao render antigo, sem regressão);
// senão retângulo. Pontilhado/tracejado travam a fase no espaço GLOBAL de x, para
// o padrão continuar através de fronteiras de <span> (uma única caixa decoradora).
@(private="file")
emit_deco_line :: proc(pt: ^Painter, x0, x1, yc, thick: f32, col: u32, style: Deco_Style) {
    if x1 <= x0 do return
    t := thick > 0 ? thick : 1
    half := t * 0.5
    switch style {
    case .Solid:
        if t <= 1 {
            emit(pt, PC_Line{{x0, yc}, {x1, yc}, col})
        } else {
            emit(pt, PC_RectFilled{{x0, yc - half}, {x1, yc + half}, col, 0, {}})
        }
    case .Double:
        lt := max(1, t / 3)
        emit(pt, PC_RectFilled{{x0, yc - half}, {x1, yc - half + lt}, col, 0, {}})
        emit(pt, PC_RectFilled{{x0, yc + half - lt}, {x1, yc + half}, col, 0, {}})
    case .Dotted:
        period := max(2, t * 2)          // ponto de diâmetro t + espaço de t
        // Pontos travados à grade GLOBAL (múltiplos de period). O ponto é desenhado
        // INTEIRO (sem cortar em x1): a palavra seguinte retoma a mesma grade no
        // próximo múltiplo, então a fronteira de <span> não trunca ponto algum — o
        // padrão fica contínuo por toda a caixa decoradora (css-text-decor §Line).
        px := math.ceil(x0 / period) * period
        for ; px < x1; px += period {
            emit(pt, PC_RectFilled{{px, yc - half}, {px + t, yc + half}, col, half, {}})
        }
    case .Dashed:
        period := max(4, t * 6)
        dash   := max(2, t * 3)
        b := math.floor(x0 / period) * period
        for ; b < x1; b += period {
            a := max(b, x0); e := min(b + dash, x1)
            if e > a do emit(pt, PC_RectFilled{{a, yc - half}, {e, yc + half}, col, 0, {}})
        }
    case .Wavy:
        // aproximação: linha sólida da mesma espessura (ondulado real é raro).
        emit(pt, PC_RectFilled{{x0, yc - half}, {x1, yc + half}, col, 0, {}})
    }
}

// Reexecuta os comandos gravados contra o DrawList real, em ordem. O único
// comando com estado é o par Xform: PC_XformBegin marca o tamanho ATUAL do
// vertex buffer; PC_XformEnd transforma os vértices [vtx0, fim) — reproduz
// exatamente o truque de transform_vertices, agora com um stack p/ nesting.
replay_paint :: proc(pt: ^Painter, dl: ^im.DrawList) {
    replay_seg(pt.cmds[:], 0, dl, cull = true)
}

// Reexecuta cmds a partir de `start` no drawlist `dl`. Ao encontrar PC_LayerEnd
// RETORNA o índice logo após ele (fecha o sub-segmento). PC_LayerBegin abre um
// sub-segmento compositado (ver composite_layer). vtx_stack é LOCAL ao segmento
// (os vértices do transform vivem no drawlist deste segmento; um transform não
// cruza a fronteira de layer — quem é transformada é a AddImage do resultado).
@(private="file")
replay_seg :: proc(cmds: []Paint_Cmd, start: int, dl: ^im.DrawList, cull := false) -> int {
    vtx_stack := make([dynamic]int, 0, 8, context.temp_allocator)
    // Culling VERTICAL de comandos de texto (ver PC_InlineText abaixo). O clip é
    // lido só onde ele PODE mudar — PushClip/PopClip/layer — porque
    // DrawList_GetClipRectMin/Max é travessia de FFI e, por comando, custaria
    // mais do que economiza.
    cmin, cmax: im.Vec2
    if cull { cmin = im.DrawList_GetClipRectMin(dl); cmax = im.DrawList_GetClipRectMax(dl) }
    // Profundidade de transform. Os vértices gravados dentro de um
    // PC_XformBegin/End são PRÉ-transform (a matriz só é aplicada no
    // transform_vertices do End), então uma subárvore rotacionada/transladada
    // pode voltar para a tela DEPOIS da decisão — culling ali seria errado.
    // Contador próprio, e não len(vtx_stack): a pilha é compartilhada com
    // PC_ShadeGradBegin, que não move vértice nenhum.
    depth:=make(map[int][4]f32,context.temp_allocator)
    defer delete(depth)
    xform_depth := 0
    i := start
    for i < len(cmds) {
        switch v in cmds[i] {
        case PC_LayerEnd:
            return i + 1
        case PC_LayerBegin:
            mask_image := Mask_Image{}
            if v.mask_image != nil do mask_image = v.mask_image^
            lf := v.filters // cópia local addressable p/ fatiar o array
            i = composite_layer(cmds, i + 1, dl, v.opacity, v.blend, lf[:v.n_filters], v.node, v.backdrop, v.clip, v.mask, v.cbx, v.cby, v.cbw, v.cbh, mask_image = mask_image)
            // A layer pode ter empilhado/desempilhado clip no `dl` pai.
            if cull { cmin = im.DrawList_GetClipRectMin(dl); cmax = im.DrawList_GetClipRectMax(dl) }
            continue
        case PC_RoundClipBegin:
            i = composite_layer(cmds, i + 1, dl, 1, .Normal, nil, v.node, 0,
                cbx = v.p0.x, cby = v.p0.y, cbw = v.p1.x-v.p0.x, cbh = v.p1.y-v.p0.y,
                rounding = v.rounding, round_clip = true)
            if cull { cmin = im.DrawList_GetClipRectMin(dl); cmax = im.DrawList_GetClipRectMax(dl) }
            continue
        case PC_BackdropFilter:
            apply_backdrop_filter(dl, v)
        case PC_Polyline:
            if len(v.pts) >= 2 {
                saved := dl.Flags
                if v.no_aa do dl.Flags -= {.AntiAliasedLines, .AntiAliasedLinesUseTex, .AntiAliasedFill}
                if v.fill {
                    im.DrawList_AddConcavePolyFilled(dl, raw_data(v.pts), c.int(len(v.pts)), v.col)
                } else {
                    fl := v.closed ? im.DrawFlags_Closed : im.DrawFlags_None
                    im.DrawList_AddPolyline(dl, raw_data(v.pts), c.int(len(v.pts)), v.col, fl, v.thickness)
                }
                if v.no_aa do dl.Flags = saved
            }
        case PC_Shadow:
            if v.inset do draw_inset_shadow(dl, v.x0, v.y0, v.x1, v.y1, v.radius, v.sh, v.eff)
            else       do draw_box_shadow(dl, v.x0, v.y0, v.x1, v.y1, v.radius, v.sh, v.eff)
        case PC_Gradient:
            if v.clip do im.DrawList_PushClipRect(dl, v.c0, v.c1, true)
            defer if v.clip do im.DrawList_PopClipRect(dl)
            switch v.kind {
            case .Conic:     paint_conic_gradient(dl, v.p0, v.p1, v.g, v.radius, v.eff)
            case .Radial:    paint_radial_gradient(dl, v.p0, v.p1, v.g, v.radius, v.eff)
            case .RoundDiag: paint_gradient_rounded_diagonal(dl, v.p0, v.p1, v.g, v.radius, v.eff)
            case .Rounded:   paint_gradient_rounded(dl, v.p0, v.p1, v.g, v.radius, v.eff)
            case .Flat:      paint_gradient(dl, v.p0, v.p1, v.g, v.eff)
            }
        case PC_RectFilled:  im.DrawList_AddRectFilled(dl, v.p0, v.p1, v.col, v.rounding, v.flags)
        case PC_RectMulti:   im.DrawList_AddRectFilledMultiColor(dl, v.p0, v.p1, v.c_ul, v.c_ur, v.c_br, v.c_bl)
        case PC_Rect:        im.DrawList_AddRect(dl, v.p0, v.p1, v.col, v.rounding, v.flags, v.thickness)
        case PC_BgImage:     paint_bg_image(dl, v.o0, v.o1, v.c0, v.c1, v.b, v.eff, v.layer)
        case PC_Border:      paint_border(dl, v.screen, v.b, v.cols, v.eff, v.radius, v.flags)
        case PC_BorderImage: paint_border_image(dl, v.screen, v.b, v.cols, v.eff, v.radius, v.flags)
        case PC_ControlMark: paint_control_mark(dl, v.screen, v.b, v.radius, v.eff)
        case PC_Image:       paint_image(dl, v.url, v.pos, v.w, v.h, v.fit, v.opa, v.px, v.py, v.deco, v.rounding)
        case PC_TextInput:   paint_text_input(v.b, v.screen, v.eff)
        case PC_Select:      paint_select(v.b, v.screen, v.eff)
        case PC_MaskCorners: mask_round_corners(dl, v.x0, v.y0, v.x1, v.y1, v.radius, v.flags, v.col)
        case PC_InnerNotch:  fill_inner_notch(dl, v.x0, v.y0, v.x1, v.y1, v.bw, v.radius, v.flags, v.col)
        case PC_InlineText:
            // S2: quantas palavras chegam ao replay, quantas o ImGui vai de fato
            // desenhar, e quantas caem no caminho por CARACTERE do letter-spacing.
            when CULLPROBE {
                g_cullprof.txt_emit += 1
                if v.spacing != 0 do g_cullprof.txt_space += 1
                {
                    cmin := im.DrawList_GetClipRectMin(dl)
                    cmax := im.DrawList_GetClipRectMax(dl)
                    if v.pos.y < cmax.y && v.pos.y + v.size > cmin.y do g_cullprof.txt_vis += 1
                }
            }
            // Culling VERTICAL. O ImGui já descarta os VÉRTICES do texto fora do
            // clip (ImFont::RenderText sai cedo abaixo do clip e avança rápido as
            // linhas acima) — mas só DEPOIS de nós pagarmos a travessia de FFI, a
            // cópia da string e, no caminho de letter-spacing, um laço inteiro por
            // CARACTERE. Medido em 2026-08-02: 92,3% dos comandos de texto do
            // github e 78,9% dos do w3.org caem fora da tela.
            //
            // É PIXEL-IDÊNTICO por construção, não uma aproximação: o que se pula é
            // trabalho cujo resultado o ImGui já jogava fora. A margem de 2× o
            // tamanho da fonte cobre ascendente/descendente e glifo de fallback,
            // para nunca cortar algo que ele desenharia.
            when UIPROF { if cull do g_uiprof.n_txt_total += 1 }
            // A trava de transform NÃO é teórica: sabotada (culando também dentro
            // de transform), a fixture `xform_scale.html` passa de 0 para 360
            // comandos descartados, todos dentro de transform. Medido 2026-08-02.
            if cull && xform_depth == 0 {
                m := v.size * 2
                if v.pos.y + m < cmin.y || v.pos.y - m > cmax.y {
                    when UIPROF {
                        g_uiprof.n_txt_cull += 1
                        if xform_depth > 0 do g_uiprof.n_txt_cull_xf += 1
                    }
                    break
                }
            }
            if len(v.text) == 0 do break
            if draw_shaped_text(dl,v.font,v.size,v.pos,v.col,v.text) do break
            if v.spacing != 0 || text_has_kerning(v.font, v.size, v.text, v.kerning) {
                draw_spaced_text(dl, v.font, v.size, v.pos, v.col, v.text, v.spacing, v.kerning)
            } else {
                // Par begin/end em vez de clone_to_cstring: `it.text` é uma FATIA do
                // texto do documento (a quebra de linha faz `it.text = head`), então
                // não é NUL-terminado e a cópia existia só para terminá-lo. Com
                // text_end explícito o ImGui não chama ImStrlen e lê a fatia direto —
                // uma alocação de arena + um memcpy a menos POR PALAVRA POR FRAME.
                p := raw_data(v.text)
                im.DrawList_AddTextImFontPtr(dl, v.font, v.size, v.pos, v.col, cstring(p), cstring(p[len(v.text):]))
            }
        case PC_Line:        im.DrawList_AddLine(dl, v.p0, v.p1, v.col)
        case PC_PushClip:
            im.DrawList_PushClipRect(dl, v.min, v.max, true)
            if cull { cmin = im.DrawList_GetClipRectMin(dl); cmax = im.DrawList_GetClipRectMax(dl) }
        case PC_PopClip:
            im.DrawList_PopClipRect(dl)
            if cull { cmin = im.DrawList_GetClipRectMin(dl); cmax = im.DrawList_GetClipRectMax(dl) }
        case PC_ShadeGradBegin: append(&vtx_stack, int(dl.VtxBuffer.Size))
        case PC_ShadeGradEnd:
            v0 := vtx_stack[len(vtx_stack) - 1]
            pop(&vtx_stack)
            shade_vertices_gradient(dl, v0, v.p0, v.p1, v.g, v.eff)
        case PC_XformBegin:
            append(&vtx_stack, int(dl.VtxBuffer.Size))
            xform_depth += 1
        case PC_ProjectEnd:
            v0:=vtx_stack[len(vtx_stack)-1]; pop(&vtx_stack); xform_depth-=1
            x_project_vertices(dl,v0,v.m,v.keep_depth,&depth)
        case PC_XformEnd:
            v0 := vtx_stack[len(vtx_stack) - 1]
            pop(&vtx_stack)
            xform_depth -= 1
            transform_vertices(dl, v0, v.cx, v.cy, v.a, v.b, v.c, v.d)
        }
        i += 1
    }
    return i
}

// Renderiza cmds[start .. PC_LayerEnd casado] numa DrawList secundária → textura
// offscreen (tamanho do viewport) e a compõe no `dl` pai com AddImage no alpha
// `opacity`. Como o conteúdo é compositado 1× depois de desenhado OPACO, filhos
// sobrepostos não sofrem double-darken. Retorna o índice após o PC_LayerEnd. Sem
// g_renderer, faz fallback desenhando o conteúdo direto no `dl` (sem dimming).
// Composição da textura de layer em alpha PREMULTIPLICADO.
//
// A textura é desenhada pelo SDL sobre um alvo TRANSPARENTE, e o resultado disso é
// premultiplicado POR CONSTRUÇÃO (dst = src·αs + 0·(1−αs)). Compô-la de volta com o
// `.BLEND` normal — que multiplica por αs OUTRA VEZ — escurece tudo que for
// semi-transparente DENTRO da layer. Medido com branco a 30% sobre laranja: saía
// (201,94,23) onde o Chrome dá (255,148,77), e o número bate EXATO com
// `77·0,3 + fundo·0,7`, a conta de premultiplicado-lido-como-reto.
//
// ⚠️ Só aparece com conteúdo SEMI-TRANSPARENTE: com αs=1 as duas convenções
// coincidem. É por isso que o `--phase2test` do M101 — dois retângulos OPACOS —
// validava o compositing e este defeito atravessou tudo.
@(private="file")
premul_blend :: proc() -> sdl2.BlendMode {
    return sdl2.ComposeCustomBlendMode(.ONE, .ONE_MINUS_SRC_ALPHA, .ADD, .ONE, .ONE_MINUS_SRC_ALPHA, .ADD)
}

// Tint do AddImage no espaço premultiplicado. O vértice do ImGui multiplica TODOS
// os canais da amostra, então escalar só o alpha (imgui_mul_alpha) quebraria a
// invariante rgb ≤ a e o `opacity` voltaria a escurecer. Escala os quatro juntos.
@(private="file")
premul_tint :: proc(opa: f32) -> u32 {
    v := u32(clamp(opa, 0, 1) * 255 + 0.5)
    return v | (v << 8) | (v << 16) | (v << 24)
}

// Converte o buffer lido do target (premultiplicado) para alpha RETO e de volta.
// Os filtros de cor da spec operam sobre a cor NÃO premultiplicada (uma matriz de
// sepia aplicada ao valor premultiplicado dá outra cor), e o clip/mask mexem no
// alpha — então o processamento inteiro acontece em reto, entre os dois.
@(private="file")
buf_unpremul :: proc(buf: []u8) {
    for i in 0 ..< len(buf) / 4 {
        a := f32(buf[i * 4 + 3])
        if a <= 0 do continue
        for c in 0 ..< 3 do buf[i * 4 + c] = u8(clamp(f32(buf[i * 4 + c]) * 255 / a, 0, 255))
    }
}

@(private="file")
buf_premul :: proc(buf: []u8) {
    for i in 0 ..< len(buf) / 4 {
        a := f32(buf[i * 4 + 3]) / 255
        for c in 0 ..< 3 do buf[i * 4 + c] = u8(clamp(f32(buf[i * 4 + c]) * a, 0, 255))
    }
}

@(private="file")
composite_layer :: proc(cmds: []Paint_Cmd, start: int, dl: ^im.DrawList, opacity: f32, blend: Blend_Mode, filters: []Filter_Op, node: rawptr, backdrop: u32, clip := Clip_Shape{}, mask := csspkg.Gradient{}, cbx: f32 = 0, cby: f32 = 0, cbw: f32 = 0, cbh: f32 = 0, rounding := Image_Rounding{}, round_clip := false, mask_image := Mask_Image{}) -> int {
    if g_renderer == nil {
        return replay_seg(cmds, start, dl) // fallback: sem compositing
    }
    io := im.GetIO()
    cache := &g_layer_cache
    if round_clip do cache = &g_round_clip_cache
    vw := io.DisplaySize.x // viewport (p/ recortar o bbox), em f32
    vh := io.DisplaySize.y

    // DrawList secundária — sem construtor no binding: zera + _Data + reset.
    ld: im.DrawList
    ld._Data = im.GetDrawListSharedData()
    im.DrawList__ResetForNewFrame(&ld)
    im.DrawList_PushTextureID(&ld, io.Fonts.TexID)
    im.DrawList_PushClipRectFullScreen(&ld)
    when UIPROF { g_uiprof.lay_n += 1; t_l := time.tick_now() }
    // ⚠️⚠️ O consumo da fila vem ANTES do replay_seg, e a ordem é o ponto todo.
    // `replay_seg` recursa nas layers ANINHADAS, e cada uma delas consome. Se o
    // consumo do pai viesse depois, a ordem seria filho→pai enquanto o push é
    // pai→filho: INVERTIDA. Medido: 1870 de 2040 pares desalinhados no github
    // (que aninha) e 0 na w3.org (que não aninha) — e o sintoma era um <h2> de
    // 1×1 sem filhos "gerando" 6316 vértices sobre a página inteira.
    // A prova de que está certo é a comparação de `node` logo abaixo.
    when SUBBBOX {
        pb: Pred_BBox
        has_pb := false
        if !round_clip && g_pred_i < len(g_pred_bbox) {
            pb = g_pred_bbox[g_pred_i]; g_pred_i += 1; has_pb = true
            if pb.node != node { g_uiprof.bb_desalinho += 1; has_pb = false }
        }
    }
    next := replay_seg(cmds, start, &ld) // reproduz o conteúdo interno em ld
    when UIPROF { g_uiprof.ms_lay_replay += time.duration_milliseconds(time.tick_since(t_l)); t_l = time.tick_now() }
    defer im.DrawList__ClearFreeMemory(&ld)

    // BBOX: limites EXATOS do conteúdo desenhado (varre os vértices de ld) +
    // margem p/ o espalhamento de blur/drop-shadow, recortado ao viewport. Assim
    // a textura tem só o tamanho do elemento (não do viewport) — memória e o
    // processamento de filtro caem proporcionalmente.
    vn := int(ld.VtxBuffer.Size)
    when UIPROF { if vn == 0 do g_uiprof.lay_e_vn0 += 1 }
    if vn == 0 do return next // nada desenhado (layer vazia)
    verts := ([^]im.DrawVert)(ld.VtxBuffer.Data)
    minx, miny := f32(1e9), f32(1e9)
    maxx, maxy := f32(-1e9), f32(-1e9)
    for k in 0 ..< vn {
        p := verts[k].pos
        minx = min(minx, p.x); miny = min(miny, p.y)
        maxx = max(maxx, p.x); maxy = max(maxy, p.y)
    }
    when UIPROF {
        g_uiprof.lay_vtx += vn
        g_uiprof.ms_lay_bbox += time.duration_milliseconds(time.tick_since(t_l)); t_l = time.tick_now()
        // VALIDAÇÃO do bbox de subárvore: o previsto (fila `g_pred_bbox`, montada
        // no record) contra o REAL (minx..maxy, dos vértices que o replay acabou
        // de gerar). Se o previsto não contém o real, cullar por ele apagaria
        // pixel. Nada é culado — este passo existe só para medir o erro.
        when SUBBBOX {
            // O bbox CRU de vértices super-estima o que aparece: a malha de um
            // radial-gradient cobre a elipse farthest-corner (box × raiz de 2) e o
            // ClipRect do DrawCmd é que recorta. Para julgar o bbox de subárvore
            // interessa o extent VISÍVEL, então intersecta com a união dos clips.
            // (Isto também revela que composite_layer dimensiona a TEXTURA pelo
            // extent cru — área desperdiçada em toda layer com gradiente.)
            cx0, cy0, cx1, cy1 := f32(1e9), f32(1e9), f32(-1e9), f32(-1e9)
            // ⚠️ os ClipRect ainda NÃO foram deslocados p/ o espaço local (isso
            // acontece mais abaixo), então estão em coordenadas de TELA, iguais
            // às de minx..maxy. `cn` só é declarado depois; conta aqui.
            cn2 := int(ld.CmdBuffer.Size)
            if cn2 > 0 {
                cb2 := ([^]im.DrawCmd)(ld.CmdBuffer.Data)
                for k in 0 ..< cn2 {
                    r := cb2[k].ClipRect
                    cx0 = min(cx0, r.x); cy0 = min(cy0, r.y)
                    cx1 = max(cx1, r.z); cy1 = max(cy1, r.w)
                }
            } else { cx0, cy0, cx1, cy1 = minx, miny, maxx, maxy }
            vx0 := max(minx, cx0); vy0 := max(miny, cy0)
            vx1 := min(maxx, cx1); vy1 := min(maxy, cy1)
            if vx1 < vx0 { vx0 = minx; vx1 = maxx }
            if vy1 < vy0 { vy0 = miny; vy1 = maxy }
            g_uiprof.area_crua += f64(maxx-minx) * f64(maxy-miny)
            g_uiprof.area_vis  += f64(vx1-vx0) * f64(vy1-vy0)
            if has_pb {
                if pb.safe {
                    g_uiprof.bb_check += 1
                    if pb.has_abs do g_uiprof.bb_c_abs += 1
                    over := max(max(pb.x0 - vx0, vx1 - pb.x1), max(pb.y0 - vy0, vy1 - pb.y1))
                    if over > 0.5 { // 0,5 px de folga p/ o arredondamento do rasterizador
                        g_uiprof.bb_viola += 1
                        if pb.has_abs do g_uiprof.bb_v_abs += 1
                        if over > 1000 do g_uiprof.bb_v_grande += 1
                        if over > g_uiprof.bb_pior {
                            g_uiprof.bb_pior = over
                            n := min(len(pb.desc), 255)
                            copy(g_bb_worst[:n], pb.desc[:n]); g_bb_worst_n = n
                            g_bb_wp = {pb.x0, pb.y0, pb.x1, pb.y1}
                            g_bb_wr = {vx0, vy0, vx1, vy1}
                            g_bb_wn = pb.ncmd; g_bb_wv = vn; g_bb_wa = pb.has_abs
                            g_bb_wf = pb.nf; g_bb_wfa = pb.famt; g_bb_wbw = pb.bw
                            g_bb_wg = pb.grad; g_bb_wi = pb.bgimg; g_bb_wx = pb.bgfix; g_bb_wnb = pb.nbg
                        }
                    }
                } else {
                    g_uiprof.bb_unsafe += 1
                }
            }
        }
    }
    mx, my: f32 // margem p/ filtros que espalham além do conteúdo (zero-value = 0)
    for f in filters {
        switch f.kind {
        // ⚠️ a margem tem de ser o ALCANCE do Gaussiano (~3σ), não σ: com margem σ
        // o borrão certo seria cortado numa borda RETA exatamente onde ele deveria
        // estar se apagando. (drop-shadow: σ = amount/2, ver apply_drop_shadow.)
        case .Blur:       sp := blur_spread(f.amount)
                          mx = max(mx, sp);             my = max(my, sp)
        case .DropShadow: sp := blur_spread(f.amount * 0.5)
                          mx = max(mx, abs(f.dx) + sp); my = max(my, abs(f.dy) + sp)
        case .Brightness, .Contrast, .Grayscale, .Sepia, .Saturate, .Invert, .HueRotate, .Opacity:
        }
    }
    rx0 := max(minx - mx, 0);  ry0 := max(miny - my, 0)
    rx1 := min(maxx + mx, vw); ry1 := min(maxy + my, vh)
    when UIPROF { if rx1 <= rx0 || ry1 <= ry0 do g_uiprof.lay_e_bbox += 1 }
    if rx1 <= rx0 || ry1 <= ry0 do return next
    ix0 := i32(math.floor(rx0)); iy0 := i32(math.floor(ry0))
    iw := i32(math.ceil(rx1)) - ix0
    ih := i32(math.ceil(ry1)) - iy0
    when UIPROF { if iw < 1 || ih < 1 do g_uiprof.lay_e_bbox += 1 }
    if iw < 1 || ih < 1 do return next

    // desloca os vértices p/ o espaço LOCAL da textura — o backend SDL_Renderer
    // usa as posições CRUAS (não aplica DisplayPos aos vértices, só ao clip).
    fx, fy := f32(ix0), f32(iy0)
    for k in 0 ..< vn {
        verts[k].pos.x -= fx
        verts[k].pos.y -= fy
    }
    // ⚠️ O ClipRect de cada comando também vive em coordenadas de TELA, e o backend
    // o usa CRU aqui (renderizamos a layer com DisplayPos={0,0}, e é dele que sairia
    // o desconto). Sem o MESMO deslocamento dos vértices, um `overflow:hidden`
    // DENTRO da layer recorta num retângulo que nem intercepta a textura e a layer
    // sai VAZIA — quanto mais para baixo na página, mais garantido o apagão. Foi
    // assim que o strip de logos do github.com (mask-image + overflow:hidden a
    // y=2281) desapareceu inteiro: mask e overflow FUNCIONAM sozinhos, só a
    // combinação apagava, porque só o mask leva o conteúdo para a textura.
    cn := int(ld.CmdBuffer.Size)
    if cn > 0 {
        cmdb := ([^]im.DrawCmd)(ld.CmdBuffer.Data)
        for k in 0 ..< cn {
            cmdb[k].ClipRect.x -= fx; cmdb[k].ClipRect.z -= fx
            cmdb[k].ClipRect.y -= fy; cmdb[k].ClipRect.w -= fy
        }
    }

    when UIPROF { g_uiprof.ms_lay_shift += time.duration_milliseconds(time.tick_since(t_l)); t_l = time.tick_now() }

    has_filter := len(filters) > 0
    has_clip   := clip.kind != .None
    has_mask   := mask.active && mask.n >= 2
    has_image_mask := mask_image.url != ""
    // blend não-linear por-canal (overlay/hard-light/soft-light/color-dodge/
    // color-burn/difference): não expressável como blend do SDL → kernel CPU sobre
    // a textura, contra o backdrop sólido. Todos ficam contíguos no fim do enum
    // (>= Overlay). Filters run first; blending must still apply afterwards.
    cpu_blend := blend >= .Overlay

    // HASH do conteúdo: vértices LOCAIS (pos+uv+cor) + blend + filtros. Vértices
    // idênticos ⇒ textura idêntica (o blur/filtro são funções determinísticas),
    // então o cache-hit NÃO tem staleness. Como os vértices são locais ao bbox,
    // rolar a página (que só muda a origem fx,fy) mantém o hash → hit + reposiciona.
    // O backdrop entra no hash pois um blend CPU depende dele (muda a cor → miss).
    h: u64 = 14695981039346656037
    h = fnv(h, u32(blend))
    h = fnv(h, backdrop)
    if round_clip {
        for i in 0..<4 {
            h = fnv(h, transmute(u32)rounding.rx[i]); h = fnv(h, transmute(u32)rounding.ry[i])
        }
        h = fnv(h, transmute(u32)(cbx-fx)); h = fnv(h, transmute(u32)(cby-fy))
        h = fnv(h, transmute(u32)cbw); h = fnv(h, transmute(u32)cbh)
    }
    // clip-path entra no hash (muda os pixels). Usa o box RELATIVO ao bbox
    // (cbx-fx, cby-fy) — invariante a scroll, preservando o cache-hit ao rolar.
    if has_clip {
        h = fnv(h, u32(clip.kind))
        for i in 0 ..< 4 {
            h = fnv(h, transmute(u32)clip.inset[i].v); h = fnv(h, u32(clip.inset[i].pct ? 1 : 0))
        }
        h = fnv(h, transmute(u32)clip.round.v)
        h = fnv(h, transmute(u32)clip.cx.v); h = fnv(h, transmute(u32)clip.cy.v)
        h = fnv(h, transmute(u32)clip.rx.v); h = fnv(h, transmute(u32)clip.ry.v)
        h = fnv(h, u32(clip.n_pts))
        for i in 0 ..< clip.n_pts {
            h = fnv(h, transmute(u32)clip.pts[i][0].v); h = fnv(h, transmute(u32)clip.pts[i][1].v)
        }
        h = fnv(h, transmute(u32)(cbx - fx)); h = fnv(h, transmute(u32)(cby - fy))
        h = fnv(h, transmute(u32)cbw); h = fnv(h, transmute(u32)cbh)
    }
    // mask-image entra no hash (muda o alpha por pixel), com o box RELATIVO ao
    // bbox (invariante a scroll, como o clip).
    if has_mask {
        h = fnv(h, u32(mask.n))
        h = fnv(h, u32(mask.radial ? 2 : (mask.conic ? 3 : 1)))
        h = fnv(h, transmute(u32)mask.angle)
        for i in 0 ..< mask.n {
            h = fnv(h, mask.cols[i]); h = fnv(h, transmute(u32)mask.pos[i]); h = fnv(h, u32(mask.pos_set[i] ? 1 : 0))
        }
        h = fnv(h, transmute(u32)(cbx - fx)); h = fnv(h, transmute(u32)(cby - fy))
        h = fnv(h, transmute(u32)cbw); h = fnv(h, transmute(u32)cbh)
    }
    if has_image_mask {
        h = fnv(h, mask_image_hash(mask_image))
        h = fnv(h, transmute(u32)(cbx-fx)); h = fnv(h, transmute(u32)(cby-fy))
        h = fnv(h, transmute(u32)cbw); h = fnv(h, transmute(u32)cbh)
    }
    for f in filters {
        h = fnv(h, u32(f.kind)); h = fnv(h, transmute(u32)f.amount)
        h = fnv(h, transmute(u32)f.dx); h = fnv(h, transmute(u32)f.dy); h = fnv(h, f.color)
    }
    for k in 0 ..< vn {
        vv := verts[k]
        h = fnv(h, transmute(u32)vv.pos.x); h = fnv(h, transmute(u32)vv.pos.y)
        h = fnv(h, transmute(u32)vv.uv.x);  h = fnv(h, transmute(u32)vv.uv.y)
        h = fnv(h, vv.col)
    }
    // Os CLIPS entram no hash junto dos vértices: um recorte muda os PIXELS sem
    // mudar vértice nenhum (um container `overflow:hidden` sem fundo não desenha
    // nada, só corta os filhos), então sem isto duas layers de mesmo conteúdo e
    // recortes diferentes colidiriam e a segunda reusaria a textura da primeira.
    // Já deslocados p/ o espaço local, então seguem invariantes a scroll (o que
    // preserva o cache-hit ao rolar, igual aos vértices).
    if cn > 0 {
        cmdh := ([^]im.DrawCmd)(ld.CmdBuffer.Data)
        for k in 0 ..< cn {
            r := cmdh[k].ClipRect
            // A nested rounded clip is an image quad. Its vertices may stay
            // identical while its content changes; hash the sampled texture.
            tid := u64(cmdh[k].TextureId)
            h = fnv(h, u32(tid & 0xffffffff)); h = fnv(h, u32(tid >> 32))
            h = fnv(h, transmute(u32)r.x); h = fnv(h, transmute(u32)r.y)
            h = fnv(h, transmute(u32)r.z); h = fnv(h, transmute(u32)r.w)
        }
    }

    when UIPROF { g_uiprof.ms_lay_hash += time.duration_milliseconds(time.tick_since(t_l)); t_l = time.tick_now() }

    // CACHE HIT: mesmo conteúdo e tamanho → reusa a textura, só reposiciona.
    if node != nil {
        if e, ok := cache^[node]; ok && e.hash == h && e.iw == iw && e.ih == ih {
            when UIPROF { g_uiprof.lay_hit += 1 }
            e.used = g_frame; e.fx = fx; e.fy = fy
            cache^[node] = e
            // o tint tem de seguir a convenção com que a TEXTURA CACHEADA foi feita
            tint := e.custom ? u32(0xFFFFFFFF) : (e.premul ? premul_tint(opacity) : imgui_mul_alpha(0xFFFFFFFF, opacity))
            im.DrawList_AddImage(dl, im.TextureID(uintptr(e.tex)), {fx, fy}, {fx + f32(iw), fy + f32(ih)}, {0, 0}, {1, 1}, tint)
            return next
        }
    }
    when UIPROF {
        if node == nil {
            g_uiprof.lay_m_nonode += 1
        } else if e, ok := cache^[node]; !ok {
            g_uiprof.lay_m_new += 1
        } else if e.hash != h {
            g_uiprof.lay_m_hash += 1
        } else {
            g_uiprof.lay_m_size += 1
        }
    }

    // MISS: (re)renderiza. Blend mode do composite: Normal = alpha sobre fundo
    // transparente; um mix-blend separável vira BlendMode custom + limpa com a COR
    // IDENTIDADE do modo (áreas sem elemento = no-op no backdrop). CPU blend
    // runs after filters; native SDL blend with filters is still unsupported.
    tex := sdl2.CreateTexture(g_renderer, .ABGR8888, .TARGET, iw, ih)
    if tex == nil do return next
    cr, cg, cb, ca: u8 = 0, 0, 0, 0 // transparente
    custom := false
    if !has_filter && !cpu_blend && blend != .Normal {
        bm, ir, ig, ib := blend_to_sdl(blend)
        if sdl2.SetTextureBlendMode(tex, bm) == 0 { // 0 = suportado pelo renderer
            custom = true
            cr, cg, cb, ca = ir, ig, ib, 255
        }
    }
    if !custom do sdl2.SetTextureBlendMode(tex, .BLEND)

    prev := sdl2.GetRenderTarget(g_renderer)
    sdl2.SetRenderTarget(g_renderer, tex)
    sdl2.SetRenderDrawColor(g_renderer, cr, cg, cb, ca)
    sdl2.RenderClear(g_renderer)
    lists := [1]^im.DrawList{&ld}
    dd: im.DrawData
    dd.Valid = true
    dd.CmdListsCount = 1
    dd.CmdLists = { Size = 1, Capacity = 1, Data = &lists[0] }
    dd.TotalVtxCount = ld.VtxBuffer.Size
    dd.TotalIdxCount = ld.IdxBuffer.Size
    dd.DisplayPos = {0, 0}
    dd.DisplaySize = {f32(iw), f32(ih)}
    dd.FramebufferScale = {1, 1}
    imgui_sdlr.RenderDrawData(&dd, g_renderer)

    // filter/blend-CPU: lê os pixels do bbox, processa na CPU, sobe numa textura
    // nova. Ambos os caminhos são readback→processa→upload STATIC; o blend CPU
    // reescreve cada cor como B(backdrop, src) mantendo o alpha (a cobertura), pra
    // que o AddImage normal componha αs·B + (1−αs)·backdrop sobre o framebuffer.
    comp_tex := tex
    intermediate: ^sdl2.Texture = nil // a textura .TARGET vira descartável quando processada na CPU
    if has_filter || cpu_blend || has_clip || has_mask || has_image_mask || round_clip {
        pw, ph := int(iw), int(ih)
        buf := make([]u8, pw * ph * 4, context.temp_allocator)
        rect := sdl2.Rect{0, 0, iw, ih}
        if sdl2.RenderReadPixels(g_renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(buf), iw * 4) == 0 {
            // O que sai do target é PREMULTIPLICADO; os kernels abaixo são definidos
            // sobre a cor reta (ver buf_unpremul).
            buf_unpremul(buf)
            if has_filter do apply_filters(buf, pw, ph, filters)
            if cpu_blend do apply_cpu_blend(buf, blend, backdrop)
            // clip-path e mask por ÚLTIMO: reduzem o alpha (o filtro/blend já rodou
            // sobre o conteúdo inteiro, como na spec: clip/mask são o passo final).
            if has_clip do apply_clip_mask(buf, pw, ph, clip, cbx - fx, cby - fy, cbw, cbh)
            if has_mask do apply_mask_gradient(buf, pw, ph, mask, cbx - fx, cby - fy, cbw, cbh)
            if has_image_mask do apply_svg_image_mask(buf, pw, ph, mask_image, cbx-fx, cby-fy, cbw, cbh)
            if round_clip do apply_round_clip(buf, pw, ph, cbx-fx, cby-fy, cbw, cbh, rounding)
            buf_premul(buf) // volta à convenção da textura (ver premul_blend)
            t2 := sdl2.CreateTexture(g_renderer, .ABGR8888, .STATIC, iw, ih)
            if t2 != nil {
                sdl2.UpdateTexture(t2, nil, raw_data(buf), iw * 4)
                comp_tex = t2
                intermediate = tex
            }
        }
    }
    sdl2.SetRenderTarget(g_renderer, prev)

    // Blend do COMPOSITE. `custom` (mix-blend nativo) já tem o seu e blenda contra o
    // framebuffer — não mexer. Os demais compõem em premultiplicado; se o renderer
    // não suportar o modo custom, cai no `.BLEND` de antes (degradação: conteúdo
    // semi-transparente dentro da layer sai escuro, como saía até aqui).
    premul := false
    if !custom {
        if sdl2.SetTextureBlendMode(comp_tex, premul_blend()) == 0 {
            premul = true
        } else {
            sdl2.SetTextureBlendMode(comp_tex, .BLEND)
        }
    }

    // LIFETIME: com nó (e sem colisão no mesmo frame) → cacheia comp_tex (persiste,
    // reusada nos próximos frames). Sem nó, ou nó já usado neste frame (não posso
    // trocar uma textura em uso) → per-frame (g_layer_textures, destruída no próximo
    // paint_layout). The CPU-uploaded result no longer references its target.
    cacheable := node != nil
    if cacheable {
        if old, ok := cache^[node]; ok && old.used == g_frame do cacheable = false
    }
    if cacheable {
        if old, ok := cache^[node]; ok do sdl2.DestroyTexture(old.tex) // stale, substitui
        cache^[node] = Layer_Cache{tex = comp_tex, hash = h, fx = fx, fy = fy, iw = iw, ih = ih, used = g_frame, custom = custom, premul = premul}
    } else {
        append(&g_layer_textures, comp_tex)
    }
    if intermediate != nil do sdl2.DestroyTexture(intermediate)

    tint := custom ? u32(0xFFFFFFFF) : (premul ? premul_tint(opacity) : imgui_mul_alpha(0xFFFFFFFF, opacity))
    im.DrawList_AddImage(dl, im.TextureID(uintptr(comp_tex)), {fx, fy}, {fx + f32(iw), fy + f32(ih)}, {0, 0}, {1, 1}, tint)
    when UIPROF {
        g_uiprof.ms_lay_tex += time.duration_milliseconds(time.tick_since(t_l))
        g_uiprof.lay_tex_built += 1
    }
    return next
}

// backdrop-filter: filtra o que já está pintado ATRÁS do elemento. Diferente de
// `filter` (que filtra os pixels PRÓPRIOS numa layer isolada), aqui rendo o `dl`
// ACUMULADO (tudo pintado até agora = o backdrop, por ordem de pintura) num target
// de tela cheia, leio a região do border-box, aplico o filtro (blur/etc.) e desenho
// o resultado de volta no dl — ANTES do fundo/conteúdo do elemento (que o PC_*
// seguinte pinta por cima). Sem g_renderer OU acima do orçamento → no-op (o
// elemento pinta normal, sem frost — degradação graciosa).
@(private="file")
apply_backdrop_filter :: proc(dl: ^im.DrawList, v: PC_BackdropFilter) {
    if g_renderer == nil || v.n <= 0 do return
    if g_backdrop_count >= BACKDROP_BUDGET do return
    io := im.GetIO()
    vw, vh := io.DisplaySize.x, io.DisplaySize.y
    // região do border-box recortada à tela
    rx0 := i32(math.floor(max(v.x0, 0)));   ry0 := i32(math.floor(max(v.y0, 0)))
    rx1 := i32(math.ceil(min(v.x1, vw)));   ry1 := i32(math.ceil(min(v.y1, vh)))
    rw, rh := rx1 - rx0, ry1 - ry0
    if rw < 1 || rh < 1 do return
    iw, ih := i32(math.ceil(vw)), i32(math.ceil(vh))
    if iw < 1 || ih < 1 do return

    // renderiza o dl ATUAL (o backdrop) num target de tela cheia
    tex := sdl2.CreateTexture(g_renderer, .ABGR8888, .TARGET, iw, ih)
    if tex == nil do return
    prev := sdl2.GetRenderTarget(g_renderer)
    sdl2.SetRenderTarget(g_renderer, tex)
    // limpa com o fundo da página (áreas ainda não cobertas = cor da página, opaca)
    br := u8((g_bg_behind >> 16) & 0xFF); bg := u8((g_bg_behind >> 8) & 0xFF); bb := u8(g_bg_behind & 0xFF)
    sdl2.SetRenderDrawColor(g_renderer, br, bg, bb, 255)
    sdl2.RenderClear(g_renderer)
    lists := [1]^im.DrawList{dl}
    dd: im.DrawData
    dd.Valid = true
    dd.CmdListsCount = 1
    dd.CmdLists = { Size = 1, Capacity = 1, Data = &lists[0] }
    dd.TotalVtxCount = dl.VtxBuffer.Size
    dd.TotalIdxCount = dl.IdxBuffer.Size
    dd.DisplayPos = {0, 0}
    dd.DisplaySize = {vw, vh}
    dd.FramebufferScale = {1, 1}
    imgui_sdlr.RenderDrawData(&dd, g_renderer)

    // lê só a região do elemento, filtra na CPU
    pw, ph := int(rw), int(rh)
    buf := make([]u8, pw * ph * 4, context.temp_allocator)
    rect := sdl2.Rect{rx0, ry0, rw, rh}
    ok := sdl2.RenderReadPixels(g_renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(buf), rw * 4) == 0
    sdl2.SetRenderTarget(g_renderer, prev)
    if !ok { sdl2.DestroyTexture(tex); return }

    lf := v.filters
    apply_filters(buf, pw, ph, lf[:v.n])
    // cantos arredondados: zera o alpha fora do retângulo arredondado (aprox. do
    // recorte do backdrop à forma do border-box).
    if v.radius > 0.5 do round_rect_alpha(buf, pw, ph, v.radius)

    out := sdl2.CreateTexture(g_renderer, .ABGR8888, .STATIC, rw, rh)
    sdl2.DestroyTexture(tex)
    if out == nil do return
    sdl2.UpdateTexture(out, nil, raw_data(buf), rw * 4)
    sdl2.SetTextureBlendMode(out, .BLEND)
    append(&g_layer_textures, out) // per-frame (backdrop é dinâmico, sem cache)
    g_backdrop_count += 1
    im.DrawList_AddImage(dl, im.TextureID(uintptr(out)), {f32(rx0), f32(ry0)}, {f32(rx1), f32(ry1)}, {0, 0}, {1, 1}, 0xFFFFFFFF)
}

// Zera o alpha dos pixels fora de um retângulo de cantos arredondados (raio r),
// no buffer ABGR de w×h. Usado p/ recortar o backdrop-filter à forma do border-box.
@(private="file")
round_rect_alpha :: proc(buf: []u8, w, h: int, r: f32) {
    rr := min(r, min(f32(w), f32(h)) * 0.5)
    if rr <= 0.5 do return
    for y in 0 ..< h {
        py := f32(y) + 0.5
        // distância vertical à zona de canto
        cy := py < rr ? rr : (py > f32(h) - rr ? f32(h) - rr : py)
        for x in 0 ..< w {
            px := f32(x) + 0.5
            cx := px < rr ? rr : (px > f32(w) - rr ? f32(w) - rr : px)
            if cx == px && cy == py do continue // fora das 4 zonas de canto
            dx, dy := px - cx, py - cy
            if dx*dx + dy*dy > rr*rr do buf[(y * w + x) * 4 + 3] = 0
        }
    }
}

// ── clip-path: máscara alpha na CPU ─────────────────────────────────────────
// Zera o alpha dos pixels FORA da forma. Coordenadas LOCAIS ao buffer: (bx,by) é
// o canto do border-box relativo ao bbox da layer; bw/bh o tamanho dele. Os % da
// forma resolvem contra bw/bh (o valor cru já vem em fração quando pct).
@(private="file")
apply_clip_mask :: proc(buf: []u8, w, h: int, cp: Clip_Shape, bx, by, bw, bh: f32) {
    if bw <= 0 || bh <= 0 do return
    for y in 0 ..< h {
        py := f32(y) + 0.5
        for x in 0 ..< w {
            px := f32(x) + 0.5
            if !clip_hit(cp, px, py, bx, by, bw, bh) do buf[(y * w + x) * 4 + 3] = 0
        }
    }
}

// ── mask-image: máscara alpha por gradiente ─────────────────────────────────
// Multiplica o alpha de cada pixel pelo ALPHA do gradiente na posição do pixel
// (mask-mode default match-source p/ um gradiente = alpha). (bx,by,bw,bh) = o
// border-box relativo ao bbox da layer, referência p/ posicionar o gradiente.
// Suporta linear (projeção no eixo do ângulo CSS), radial (distância elíptica ao
// centro) e conic (ângulo ao redor do centro). O gradiente cobre o border-box; um
// pixel fora projeta além de [0,1] e grad_color_at ancora no stop da ponta.
@(private="file")
apply_mask_gradient :: proc(buf: []u8, w, h: int, g: csspkg.Gradient, bx, by, bw, bh: f32) {
    if g.n < 2 || bw <= 0 || bh <= 0 do return
    line := mask_line_px(g, bw, bh)
    pos := resolve_grad_positions(g, line)
    for y in 0 ..< h {
        py := f32(y) + 0.5
        for x in 0 ..< w {
            idx := (y*w + x)*4 + 3
            oa := u32(buf[idx])
            if oa == 0 do continue // já transparente
            t := mask_frac(g, f32(x) + 0.5, py, bx, by, bw, bh)
            ma := (grad_color_at(g, pos, clamp(t, 0, 1), line) >> 24) & 0xFF // alpha do gradiente
            buf[idx] = u8(oa * ma / 255)
        }
    }
}

// Comprimento da linha do gradiente da máscara (p/ resolver stops em px). Linear:
// |W·sinθ|+|H·cosθ|; radial: distância ao canto; conic: n/a (0).
@(private="file")
mask_line_px :: proc(g: csspkg.Gradient, bw, bh: f32) -> f32 {
    if g.conic do return 0
    // radial: a linha do gradiente é o raio HORIZONTAL da elipse final (spec)
    if g.radial {
        _, _, rx, _ := radial_geometry(g, 0, 0, bw, bh)
        return rx
    }
    ang := f64(g.angle) * math.PI / 180
    return abs(bw*f32(math.sin(ang))) + abs(bh*f32(-math.cos(ang)))
}

// Fração t (0..1 do gradiente) no ponto (px,py), coords locais ao buffer. Linear:
// projeção no eixo do ângulo CSS. Radial: distância elíptica ao centro. Conic:
// ângulo ao redor do centro. NÃO faz clamp (o chamador clampa).
@(private="file")
mask_frac :: proc(g: csspkg.Gradient, px, py, bx, by, bw, bh: f32) -> f32 {
    cx, cy := bx + bw*0.5, by + bh*0.5
    if g.radial {
        // MESMA geometria do paint (shape/size/`at` do prelúdio) — o caminho da
        // máscara é por-pixel, mas a elipse final tem de ser a mesma.
        gcx, gcy, rx, ry := radial_geometry(g, bx, by, bw, bh)
        ddx := rx > 0.01 ? (px-gcx)/rx : 0
        ddy := ry > 0.01 ? (py-gcy)/ry : 0
        return f32(math.sqrt(f64(ddx*ddx + ddy*ddy)))
    }
    if g.conic {
        a := f32(math.atan2(f64(px-cx), f64(-(py-cy)))) * 180 / math.PI - g.angle
        for a < 0    do a += 360
        for a >= 360 do a -= 360
        return a / 360
    }
    // linear: vetor d=(sinθ,−cosθ) em coords de tela (y p/ baixo); comprimento da
    // linha do gradiente = |W·sinθ|+|H·cosθ|.
    ang := f64(g.angle) * math.PI / 180
    dxv := f32(math.sin(ang)); dyv := f32(-math.cos(ang))
    L := abs(bw*dxv) + abs(bh*dyv)
    return L > 0 ? 0.5 + ((px-cx)*dxv + (py-cy)*dyv) / L : 0.5
}

// Expõe o fator da máscara (alpha 0..255) num ponto p/ teste — lógica pura.
test_mask_alpha :: proc(g: csspkg.Gradient, px, py, bx, by, bw, bh: f32) -> u32 {
    if g.n < 2 do return 255
    line := mask_line_px(g, bw, bh)
    pos := resolve_grad_positions(g, line)
    t := mask_frac(g, px, py, bx, by, bw, bh)
    return (grad_color_at(g, pos, clamp(t, 0, 1), line) >> 24) & 0xFF
}

// Resolve um Clip_Val contra um eixo de referência.
@(private="file")
clip_rv :: proc(v: Clip_Val, ref: f32) -> f32 { return v.pct ? v.v * ref : v.v }

// O ponto (px,py) está DENTRO da forma? Tudo em coords locais ao buffer.
@(private="file")
clip_hit :: proc(cp: Clip_Shape, px, py: f32, bx, by, bw, bh: f32) -> bool {
    switch cp.kind {
    case .None:
        return true
    case .Inset:
        t := clip_rv(cp.inset[0], bh); r := clip_rv(cp.inset[1], bw)
        b := clip_rv(cp.inset[2], bh); l := clip_rv(cp.inset[3], bw)
        x0, y0 := bx + l, by + t
        x1, y1 := bx + bw - r, by + bh - b
        if x1 <= x0 || y1 <= y0 do return false
        if px < x0 || px > x1 || py < y0 || py > y1 do return false
        // round: cantos arredondados — fora do quarto-de-círculo do canto = fora
        rad := clip_rv(cp.round, min(x1 - x0, y1 - y0))
        if rad > 0 {
            rad = min(rad, min((x1 - x0) * 0.5, (y1 - y0) * 0.5))
            // centro do canto mais próximo, se o ponto estiver na zona do canto
            cx := px < x0 + rad ? x0 + rad : (px > x1 - rad ? x1 - rad : px)
            cy := py < y0 + rad ? y0 + rad : (py > y1 - rad ? y1 - rad : py)
            if cx != px || cy != py {
                dx, dy := px - cx, py - cy
                if dx*dx + dy*dy > rad*rad do return false
            }
        }
        return true
    case .Circle:
        // % do raio resolve contra sqrt((bw²+bh²)/2) (spec); centro contra bw/bh
        ref := f32(math.sqrt(f64(bw*bw + bh*bh) / 2))
        r  := clip_rv(cp.rx, ref)
        cx := bx + clip_rv(cp.cx, bw)
        cy := by + clip_rv(cp.cy, bh)
        dx, dy := px - cx, py - cy
        return dx*dx + dy*dy <= r*r
    case .Ellipse:
        rx := clip_rv(cp.rx, bw)
        ry := clip_rv(cp.ry, bh)
        if rx <= 0 || ry <= 0 do return false
        cx := bx + clip_rv(cp.cx, bw)
        cy := by + clip_rv(cp.cy, bh)
        dx, dy := (px - cx) / rx, (py - cy) / ry
        return dx*dx + dy*dy <= 1
    case .Rect:
        // clip: rect(t r b l) — arestas medidas da origem (top-left) do border-box.
        // auto (pct=true): top/left→0, right→bw, bottom→bh. Reta, sem cantos.
        t := cp.inset[0].pct ? 0  : cp.inset[0].v
        r := cp.inset[1].pct ? bw : cp.inset[1].v
        b := cp.inset[2].pct ? bh : cp.inset[2].v
        l := cp.inset[3].pct ? 0  : cp.inset[3].v
        x0, y0 := bx + l, by + t
        x1, y1 := bx + r, by + b
        if x1 <= x0 || y1 <= y0 do return false
        return px >= x0 && px <= x1 && py >= y0 && py <= y1
    case .Polygon:
        // point-in-polygon por cruzamentos (even-odd)
        if cp.n_pts < 3 do return true
        inside := false
        j := cp.n_pts - 1
        for i in 0 ..< cp.n_pts {
            xi := bx + clip_rv(cp.pts[i][0], bw); yi := by + clip_rv(cp.pts[i][1], bh)
            xj := bx + clip_rv(cp.pts[j][0], bw); yj := by + clip_rv(cp.pts[j][1], bh)
            if (yi > py) != (yj > py) {
                xint := xi + (py - yi) / (yj - yi) * (xj - xi)
                if px < xint do inside = !inside
            }
            j = i
        }
        return inside
    }
    return true
}

// Expõe clip_hit p/ os testes (a geometria do clip-path é lógica pura, testável
// sem renderizar).
test_clip_hit :: proc(cp: Clip_Shape, px, py, bx, by, bw, bh: f32) -> bool {
    return clip_hit(cp, px, py, bx, by, bw, bh)
}

// Idem p/ a receita de caixas do Gaussiano: é aritmética pura, e o defeito que ela
// evita (deriva de meio pixel no caso PAR) é invisível num teste de pintura.
test_gauss_boxes :: proc(sigma: f32) -> (los, his: [3]int) { return gauss_boxes(sigma) }
test_blur_spread :: proc(sigma: f32) -> f32 { return blur_spread(sigma) }

// Idem p/ a escolha de `<source>`/`srcset`: a decisão é pura (atributos + viewport),
// e o que ela evita — escolher um AVIF que não sabemos abrir — não dá sintoma
// visível nenhum além da imagem sumir.
test_srcset_pick :: proc(srcset: string, alvo_w: f32) -> string { return srcset_pick(srcset, alvo_w) }
test_picture_source :: proc(img: ^dompkg.Node) -> ^dompkg.Node { return picture_source_for(img) }

// ── filter: processamento de pixels na CPU (ABGR8888 → bytes R,G,B,A) ────────
@(private="file")
apply_filters :: proc(buf: []u8, w, h: int, filters: []Filter_Op) {
    for f in filters {
        switch f.kind {
        case .Blur:       apply_blur(buf, w, h, f.amount)
        case .DropShadow: apply_drop_shadow(buf, w, h, f)
        case .Brightness, .Contrast, .Grayscale, .Sepia, .Saturate, .Invert, .HueRotate, .Opacity:
            apply_color_filter(buf, f)
        }
    }
}

// Filtros de PONTO (cada pixel independente): matriz/escala de cor.
@(private="file")
apply_color_filter :: proc(buf: []u8, f: Filter_Op) {
    n := len(buf) / 4
    hr_c, hr_s: f32
    if f.kind == .HueRotate {
        rad := f.amount * 0.017453292
        hr_c = f32(math.cos(rad)); hr_s = f32(math.sin(rad))
    }
    t := clamp(f.amount, 0, 1) // p/ grayscale/sepia/invert (0..1)
    for i in 0 ..< n {
        r := f32(buf[i * 4]) / 255
        g := f32(buf[i * 4 + 1]) / 255
        b := f32(buf[i * 4 + 2]) / 255
        a := buf[i * 4 + 3]
        switch f.kind {
        case .Grayscale:
            l := 0.2126 * r + 0.7152 * g + 0.0722 * b
            r += (l - r) * t; g += (l - g) * t; b += (l - b) * t
        case .Sepia:
            sr := 0.393 * r + 0.769 * g + 0.189 * b
            sg := 0.349 * r + 0.686 * g + 0.168 * b
            sb := 0.272 * r + 0.534 * g + 0.131 * b
            r += (sr - r) * t; g += (sg - g) * t; b += (sb - b) * t
        case .Saturate:
            l := 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = l + (r - l) * f.amount; g = l + (g - l) * f.amount; b = l + (b - l) * f.amount
        case .Brightness:
            r *= f.amount; g *= f.amount; b *= f.amount
        case .Contrast:
            r = (r - 0.5) * f.amount + 0.5; g = (g - 0.5) * f.amount + 0.5; b = (b - 0.5) * f.amount + 0.5
        case .Invert:
            r += t * (1 - 2 * r); g += t * (1 - 2 * g); b += t * (1 - 2 * b)
        case .Opacity:
            a = u8(clamp(f32(a) * f.amount, 0, 255))
        case .HueRotate:
            nr := r*(0.213+hr_c*0.787-hr_s*0.213) + g*(0.715-hr_c*0.715-hr_s*0.715) + b*(0.072-hr_c*0.072+hr_s*0.928)
            ng := r*(0.213-hr_c*0.213+hr_s*0.143) + g*(0.715+hr_c*0.285+hr_s*0.140) + b*(0.072-hr_c*0.072-hr_s*0.283)
            nb := r*(0.213-hr_c*0.213-hr_s*0.787) + g*(0.715-hr_c*0.715+hr_s*0.715) + b*(0.072+hr_c*0.928+hr_s*0.072)
            r = nr; g = ng; b = nb
        case .Blur, .DropShadow: // tratados em apply_blur/apply_drop_shadow
        }
        buf[i * 4]     = u8(clamp(r * 255, 0, 255))
        buf[i * 4 + 1] = u8(clamp(g * 255, 0, 255))
        buf[i * 4 + 2] = u8(clamp(b * 255, 0, 255))
        buf[i * 4 + 3] = a
    }
}

// ── Aproximação de GAUSSIANO por três box blurs ─────────────────────────────
//
// `blur(<length>)` é um Gaussiano cujo comprimento é o DESVIO-PADRÃO σ (Filter
// Effects §on blur), não um raio de janela. UMA passada de box de raio σ borra
// muito menos: o alcance vira σ em vez de ~3σ. Medido contra o Chrome numa caixa
// de 120px com `blur(24px)`: ele espalha de 3 a 236 (≈57px por lado), nós
// espalhávamos de 36 a 203 (24px por lado) — o borrão saía com menos da metade
// do alcance, e era isso que fazia o brilho difuso do hero da cloudflare virar
// mancha de borda dura.
//
// Receita da spec (SVG 1.1 §15.17, a mesma de Firefox/Skia): d = floor(σ·3·√(2π)/4
// + 0.5); com d ÍMPAR, três passadas de tamanho d centradas no pixel; com d PAR,
// duas de tamanho d centradas em cada BORDA do pixel (uma para cada lado, senão a
// imagem escorrega meio pixel) e uma de tamanho d+1 centrada. Devolve os pares
// (lo,hi) da janela de cada passada — lo+hi+1 = tamanho.
@(private="file")
gauss_boxes :: proc(sigma: f32) -> (los, his: [3]int) {
    d := int(sigma * 1.8799712 + 0.5) // 3·√(2π)/4
    if d < 1 do return
    if d % 2 == 1 {
        r := (d - 1) / 2
        los = {r, r, r}; his = {r, r, r}
    } else {
        k := d / 2
        los = {k, k - 1, k}
        his = {k - 1, k, k}
    }
    return
}

// Alcance VISÍVEL de um Gaussiano de desvio σ (além de ~3σ a contribuição some).
// É a margem que a textura da layer precisa ter para o borrão não ser CORTADO na
// borda — sem crescer isto junto, o blur mais forte só ganharia uma borda reta.
@(private="file")
blur_spread :: proc(sigma: f32) -> f32 { return sigma * 3 }

// blur(σ): três box blurs SEPARÁVEIS (H depois V) em alpha PRÉ-MULTIPLICADO
// (evita franja escura nas bordas transparentes). Custo O(w·h) por passada
// (janela deslizante), independente do tamanho da janela.
@(private="file")
apply_blur :: proc(buf: []u8, w, h: int, sigma_px: f32) {
    s := sigma_px
    if s <= 0.01 || w < 2 || h < 2 do return
    if s > 100 do s = 100 // limita custo (e a área da textura, que cresce com 3σ)
    los, his := gauss_boxes(s)
    if los[0] + his[0] < 1 do return // d<1: nada perceptível
    n := w * h
    a := make([][4]f32, n, context.temp_allocator)
    tmp := make([][4]f32, n, context.temp_allocator)
    for i in 0 ..< n {
        al := f32(buf[i * 4 + 3]) / 255
        a[i] = { f32(buf[i * 4]) / 255 * al, f32(buf[i * 4 + 1]) / 255 * al, f32(buf[i * 4 + 2]) / 255 * al, al }
    }
    for p in 0 ..< 3 { // a → tmp → a: o resultado volta a `a` a cada passada
        box_blur_h(a[:], tmp[:], w, h, los[p], his[p])
        box_blur_v(tmp[:], a[:], w, h, los[p], his[p])
    }
    for i in 0 ..< n {
        al := a[i][3]
        if al > 0.0001 {
            buf[i * 4]     = u8(clamp(a[i][0] / al * 255, 0, 255))
            buf[i * 4 + 1] = u8(clamp(a[i][1] / al * 255, 0, 255))
            buf[i * 4 + 2] = u8(clamp(a[i][2] / al * 255, 0, 255))
            buf[i * 4 + 3] = u8(clamp(al * 255, 0, 255))
        } else {
            buf[i * 4] = 0; buf[i * 4 + 1] = 0; buf[i * 4 + 2] = 0; buf[i * 4 + 3] = 0
        }
    }
}

// Janela ASSIMÉTRICA [-lo, +hi]: o tamanho par da receita da spec não tem centro
// no pixel, e é o par de passadas espelhadas que cancela o meio-pixel de deriva.
@(private="file")
box_blur_h :: proc(src, dst: [][4]f32, w, h, lo, hi: int) {
    inv := f32(1) / f32(lo + hi + 1)
    for y in 0 ..< h {
        base := y * w
        sum: [4]f32
        for k in -lo ..= hi do sum += src[base + clamp(k, 0, w - 1)]
        for x in 0 ..< w {
            dst[base + x] = sum * inv
            sum += src[base + clamp(x + hi + 1, 0, w - 1)] - src[base + clamp(x - lo, 0, w - 1)]
        }
    }
}

@(private="file")
box_blur_v :: proc(src, dst: [][4]f32, w, h, lo, hi: int) {
    inv := f32(1) / f32(lo + hi + 1)
    for x in 0 ..< w {
        sum: [4]f32
        for k in -lo ..= hi do sum += src[x + clamp(k, 0, h - 1) * w]
        for y in 0 ..< h {
            dst[x + y * w] = sum * inv
            sum += src[x + clamp(y + hi + 1, 0, h - 1) * w] - src[x + clamp(y - lo, 0, h - 1) * w]
        }
    }
}

// drop-shadow: borra o ALPHA do elemento, desloca por (dx,dy), colore e compõe
// ATRÁS do elemento (src-over: elemento em cima). O elemento em si fica intacto.
@(private="file")
apply_drop_shadow :: proc(buf: []u8, w, h: int, f: Filter_Op) {
    n := w * h
    // alpha do elemento → canal de sombra, borrado
    sa := make([]f32, n, context.temp_allocator)
    for i in 0 ..< n do sa[i] = f32(buf[i * 4 + 3]) / 255
    // ⚠️ O 3º argumento do `drop-shadow()` NÃO é σ: ele é "interpretado como no
    // box-shadow", e lá o desvio é METADE do raio (Filter Effects). Passar o valor
    // cru aqui dobraria a sombra agora que o Gaussiano tem o alcance certo.
    blur_alpha(sa, w, h, f.amount * 0.5)
    // cor da sombra (0xAARRGGBB, AA=0 opaco)
    sr := f32((f.color >> 16) & 0xff) / 255
    sg := f32((f.color >> 8) & 0xff) / 255
    sb := f32(f.color & 0xff) / 255
    ca := (f.color >> 24) & 0xff
    col_a: f32 = ca == 0 ? 1 : f32(ca) / 255
    idx := int(math.round(f.dx))
    idy := int(math.round(f.dy))
    out := make([]u8, n * 4, context.temp_allocator)
    for y in 0 ..< h {
        for x in 0 ..< w {
            i := y * w + x
            ea := f32(buf[i * 4 + 3]) / 255
            er := f32(buf[i * 4]) / 255
            eg := f32(buf[i * 4 + 1]) / 255
            eb := f32(buf[i * 4 + 2]) / 255
            // alpha da sombra no ponto (x-dx, y-dy) × alpha da cor
            sx := x - idx; sy := y - idy
            sha: f32 = 0
            if sx >= 0 && sx < w && sy >= 0 && sy < h do sha = sa[sy * w + sx] * col_a
            // src-over em pré-multiplicado: elemento SOBRE a sombra
            k := 1 - ea
            oa := ea + sha * k
            if oa > 0.0001 {
                out[i * 4]     = u8(clamp((er * ea + sr * sha * k) / oa * 255, 0, 255))
                out[i * 4 + 1] = u8(clamp((eg * ea + sg * sha * k) / oa * 255, 0, 255))
                out[i * 4 + 2] = u8(clamp((eb * ea + sb * sha * k) / oa * 255, 0, 255))
                out[i * 4 + 3] = u8(clamp(oa * 255, 0, 255))
            }
        }
    }
    copy(buf, out)
}

// Gaussiano separável de um canal único (o alpha da sombra), mesma receita de
// três passadas do apply_blur.
@(private="file")
blur_alpha :: proc(a: []f32, w, h: int, sigma: f32) {
    s := sigma
    if s <= 0.01 || w < 2 || h < 2 do return
    if s > 100 do s = 100
    los, his := gauss_boxes(s)
    if los[0] + his[0] < 1 do return
    tmp := make([]f32, len(a), context.temp_allocator)
    for p in 0 ..< 3 {
        lo, hi := los[p], his[p]
        inv := f32(1) / f32(lo + hi + 1)
        for y in 0 ..< h { // horizontal → tmp
            base := y * w
            sum: f32 = 0
            for k in -lo ..= hi do sum += a[base + clamp(k, 0, w - 1)]
            for x in 0 ..< w {
                tmp[base + x] = sum * inv
                sum += a[base + clamp(x + hi + 1, 0, w - 1)] - a[base + clamp(x - lo, 0, w - 1)]
            }
        }
        for x in 0 ..< w { // vertical → a
            sum: f32 = 0
            for k in -lo ..= hi do sum += tmp[x + clamp(k, 0, h - 1) * w]
            for y in 0 ..< h {
                a[x + y * w] = sum * inv
                sum += tmp[x + clamp(y + hi + 1, 0, h - 1) * w] - tmp[x + clamp(y - lo, 0, h - 1) * w]
            }
        }
    }
}

// Traduz um mix-blend-mode separável p/ um BlendMode custom do SDL + a cor
// IDENTIDADE (o que blenda como no-op: onde o elemento não cobre, deixa o
// backdrop intacto). Fator de alpha ZERO/ONE/ADD preserva o alpha do backdrop.
// darken/lighten usam MIN/MAX (só D3D11) — se o renderer não suportar,
// SetTextureBlendMode falha e o chamador faz fallback p/ Normal.
// mix-blend-mode não-linear na CPU. O SDL_Renderer não expressa essas funções como
// fator de blend, e não dá pra ler o framebuffer em construção — então blendamos
// contra o backdrop SÓLIDO (a cor de fundo opaca do ancestral, capturada no record).
// Correto quando o elemento está sobre uma região sólida (caso comum); aproximado
// quando há outro conteúdo atrás. Reescreve cada pixel: cor ← B(Cb, Cs), alpha ← αs
// (cobertura preservada), de modo que o AddImage src-over componha αs·B + (1−αs)·Cb
// sobre o framebuffer. Dois caminhos: SEPARÁVEL (por-canal, blend_ch) e NÃO-SEPARÁVEL
// (hue/sat/color/luminosity: opera no RGB inteiro via luminosity/sat — blend_nonsep).
@(private="file")
u8n :: proc(x: f32) -> u8 { return u8(clamp(x, 0, 1) * 255 + 0.5) }
@(private="file")
apply_cpu_blend :: proc(buf: []u8, blend: Blend_Mode, backdrop: u32) {
    br := f32((backdrop >> 16) & 0xff) / 255
    bg := f32((backdrop >> 8) & 0xff) / 255
    bb := f32(backdrop & 0xff) / 255
    nonsep := blend >= .Hue
    n := len(buf) / 4
    for i in 0 ..< n {
        if buf[i * 4 + 3] == 0 do continue // fora da cobertura: nada a blendar
        sr := f32(buf[i * 4]) / 255
        sg := f32(buf[i * 4 + 1]) / 255
        sb := f32(buf[i * 4 + 2]) / 255
        if nonsep {
            r, g, b := blend_nonsep(blend, br, bg, bb, sr, sg, sb)
            buf[i * 4] = u8n(r); buf[i * 4 + 1] = u8n(g); buf[i * 4 + 2] = u8n(b)
        } else {
            buf[i * 4]     = u8n(blend_ch(blend, br, sr))
            buf[i * 4 + 1] = u8n(blend_ch(blend, bg, sg))
            buf[i * 4 + 2] = u8n(blend_ch(blend, bb, sb))
        }
        // buf[i*4+3] (alpha) preservado
    }
}

// ── blends NÃO-SEPARÁVEIS (spec Compositing and Blending L1, W3C) ─────────────
// Operam no RGB inteiro (não por-canal). Blocos de construção: Lum/SetLum/ClipColor
// (luminosidade) e Sat/SetSat (saturação). Cb=backdrop, Cs=source (cada RGB em 0..1).
@(private="file")
nonsep_lum :: proc(r, g, b: f32) -> f32 { return 0.3 * r + 0.59 * g + 0.11 * b }
@(private="file")
nonsep_sat :: proc(r, g, b: f32) -> f32 { return max(r, g, b) - min(r, g, b) }

// ClipColor: puxa canais fora de [0,1] de volta em direção à luminosidade (preserva Lum).
@(private="file")
nonsep_clip :: proc(r, g, b: f32) -> (f32, f32, f32) {
    l := nonsep_lum(r, g, b)
    n := min(r, g, b)
    x := max(r, g, b)
    rr, gg, bb := r, g, b
    if n < 0 && l - n != 0 {
        rr = l + (rr - l) * l / (l - n)
        gg = l + (gg - l) * l / (l - n)
        bb = l + (bb - l) * l / (l - n)
    }
    if x > 1 && x - l != 0 {
        rr = l + (rr - l) * (1 - l) / (x - l)
        gg = l + (gg - l) * (1 - l) / (x - l)
        bb = l + (bb - l) * (1 - l) / (x - l)
    }
    return rr, gg, bb
}

// SetLum: desloca a cor p/ a luminosidade alvo `l`, depois clampa preservando Lum.
@(private="file")
nonsep_set_lum :: proc(r, g, b, l: f32) -> (f32, f32, f32) {
    d := l - nonsep_lum(r, g, b)
    return nonsep_clip(r + d, g + d, b + d)
}

// SetSat: remapeia [min,max] → [0,s] linearmente em TODOS os canais (min→0, max→s,
// mid→interpolado). Cor acromática (max==min) → preto, como manda a spec.
@(private="file")
nonsep_set_sat :: proc(r, g, b, s: f32) -> (f32, f32, f32) {
    mx := max(r, g, b)
    mn := min(r, g, b)
    if mx <= mn do return 0, 0, 0
    k := s / (mx - mn)
    return (r - mn) * k, (g - mn) * k, (b - mn) * k
}

@(private="file")
blend_nonsep :: proc(blend: Blend_Mode, br, bg, bb, sr, sg, sb: f32) -> (f32, f32, f32) {
    #partial switch blend {
    case .Hue: // matiz do source, sat+lum do backdrop
        r, g, b := nonsep_set_sat(sr, sg, sb, nonsep_sat(br, bg, bb))
        return nonsep_set_lum(r, g, b, nonsep_lum(br, bg, bb))
    case .Saturation: // sat do source, matiz+lum do backdrop
        r, g, b := nonsep_set_sat(br, bg, bb, nonsep_sat(sr, sg, sb))
        return nonsep_set_lum(r, g, b, nonsep_lum(br, bg, bb))
    case .Color: // matiz+sat do source, lum do backdrop
        return nonsep_set_lum(sr, sg, sb, nonsep_lum(br, bg, bb))
    case .Luminosity: // lum do source, matiz+sat do backdrop (= inverso de Color)
        return nonsep_set_lum(br, bg, bb, nonsep_lum(sr, sg, sb))
    }
    return sr, sg, sb
}

// Função de blend separável por canal (cb=backdrop, cs=source, em 0..1). Fórmulas
// da spec Compositing and Blending Level 1 (W3C). Todas separáveis (independentes
// por canal); os não-separáveis (hue/sat/color/luminosity) NÃO passam por aqui.
@(private="file")
blend_ch :: proc(blend: Blend_Mode, cb, cs: f32) -> f32 {
    // hard-light(cb,cs) = cs≤.5 ? 2·cb·cs : 1−2(1−cb)(1−cs) (multiply/screen conforme cs)
    hard :: proc(cb, cs: f32) -> f32 {
        return cs <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs)
    }
    #partial switch blend { // nonsep (hue/sat/color/lum) não chegam aqui (blend_nonsep)
    case .HardLight: return hard(cb, cs)
    case .Overlay:   return hard(cs, cb) // = hard-light com papéis trocados
    case .Difference: return abs(cb - cs)
    case .ColorDodge: // clareia o backdrop conforme o source; cs=1 → branco
        if cb == 0 do return 0
        if cs >= 1 do return 1
        return min(1, cb / (1 - cs))
    case .ColorBurn: // escurece o backdrop conforme o source; cs=0 → preto
        if cb >= 1 do return 1
        if cs == 0 do return 0
        return 1 - min(1, (1 - cb) / cs)
    case .SoftLight: // hard-light suave; usa D(cb) na metade clara
        if cs <= 0.5 do return cb - (1 - 2 * cs) * cb * (1 - cb)
        d := cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : f32(math.sqrt(cb))
        return cb + (2 * cs - 1) * (d - cb)
    case .Normal, .Multiply, .Screen, .Darken, .Lighten, .Exclusion:
    }
    return cs
}

@(private="file")
blend_to_sdl :: proc(m: Blend_Mode) -> (bm: sdl2.BlendMode, ir, ig, ib: u8) {
    #partial switch m { // overlay/hard-light nunca chegam aqui (vão pro kernel CPU)
    case .Multiply:  // cs·cb          identidade = branco
        return sdl2.ComposeCustomBlendMode(.DST_COLOR, .ZERO, .ADD, .ZERO, .ONE, .ADD), 255, 255, 255
    case .Screen:    // cs+cb-cs·cb    identidade = preto
        return sdl2.ComposeCustomBlendMode(.ONE, .ONE_MINUS_SRC_COLOR, .ADD, .ZERO, .ONE, .ADD), 0, 0, 0
    case .Darken:    // min(cs,cb)     identidade = branco
        return sdl2.ComposeCustomBlendMode(.ONE, .ONE, .MINIMUM, .ZERO, .ONE, .ADD), 255, 255, 255
    case .Lighten:   // max(cs,cb)     identidade = preto
        return sdl2.ComposeCustomBlendMode(.ONE, .ONE, .MAXIMUM, .ZERO, .ONE, .ADD), 0, 0, 0
    case .Exclusion: // cs+cb-2cs·cb   identidade = preto
        return sdl2.ComposeCustomBlendMode(.ONE_MINUS_DST_COLOR, .ONE_MINUS_SRC_COLOR, .ADD, .ZERO, .ONE, .ADD), 0, 0, 0
    case .Normal:
        return sdl2.BlendMode.BLEND, 0, 0, 0
    }
    return sdl2.BlendMode.BLEND, 0, 0, 0
}

paint_layout :: proc(s: ^State, root: ^Box) {
    // hit-test de clique: contador de ORDEM DE PINTURA do frame (ver g_hit_seq).
    g_hit_seq   = 0
    g_click_seq = -1
    g_aux_seq   = -1
    // libera as texturas de layer per-frame do frame ANTERIOR (já lidas pelo
    // RenderDrawData de fim-de-frame) e zera o orçamento de layers deste frame.
    animation_step_tree(root, im.GetIO().DeltaTime)
    g_frame += 1
    shadow_stale := make([dynamic]Shadow_Key, 0, 8, context.temp_allocator)
    for k, e in g_shadow_masks do if e.used < g_frame - 1 do append(&shadow_stale, k)
    for k in shadow_stale {
        sdl2.DestroyTexture(g_shadow_masks[k].tex)
        delete_key(&g_shadow_masks, k)
    }
    for t in g_layer_textures do sdl2.DestroyTexture(t)
    clear(&g_layer_textures)
    // eviction do cache de layers: destrói as entradas não usadas no frame anterior
    // (a tex de uma entrada usada no frame F foi lida pelo render de F; no início de
    // F+2 já não é mais referenciada). Coleta as chaves antes (não mutar em iteração).
    stale := make([dynamic]rawptr, 0, 8, context.temp_allocator)
    for k, e in g_layer_cache do if e.used < g_frame - 1 do append(&stale, k)
    for k in stale {
        sdl2.DestroyTexture(g_layer_cache[k].tex)
        delete_key(&g_layer_cache, k)
    }
    clear(&stale)
    for k, e in g_round_clip_cache do if e.used < g_frame - 1 do append(&stale, k)
    for k in stale {
        sdl2.DestroyTexture(g_round_clip_cache[k].tex)
        delete_key(&g_round_clip_cache, k)
    }
    g_backdrop_count = 0
    // cor atrás da raiz = fundo da página (p/ recortar cantos de overflow:hidden)
    if len(s.tabs) > 0 do g_bg_behind = s.tabs[s.active].page_bg
    // BBOX de subárvore, no FUNIL único da pintura. Fica aqui, e não junto de cada
    // um dos 8 call-sites de layout_absolutes, porque (a) é impossível esquecer um
    // e (b) `scroll_y` de container rolável muda sem relayout — o bbox tem de ser
    // do frame que está prestes a ser pintado, não do último layout.
    when SUBBBOX {
        clear(&g_pred_bbox); g_pred_i = 0
        compute_subtree_bbox(root)
    }
    pt := painter_begin()
    defer painter_end(&pt)
    when CULLPROBE { g_cullprof.frames += 1 }
    when PAINTPROF { g_pp.frames += 1 }
    when UIPROF { t_rec := time.tick_now() }
    paint_box(&pt, s, root, 0, 0)                 // grava
    when UIPROF {
        g_uiprof.ms_record += time.duration_milliseconds(time.tick_since(t_rec))
        // Conta Begin/End GRAVADOS. Se Begin != nº de composite_layer chamados,
        // o replay está parando antes do fim (ou pulando comandos) — e é isso que
        // desalinha qualquer canal lateral indexado por ordem de layer.
        for c in pt.cmds {
            #partial switch _ in c {
            case PC_LayerBegin: g_uiprof.cmd_lbegin += 1
            case PC_LayerEnd:   g_uiprof.cmd_lend   += 1
            }
        }
        g_uiprof.n_cmds = len(pt.cmds)
        if len(pt.cmds) > g_uiprof.max_cmds do g_uiprof.max_cmds = len(pt.cmds)
        t_rep := time.tick_now()
    }
    replay_paint(&pt, im.GetWindowDrawList())     // desenha
    when UIPROF { g_uiprof.ms_replay += time.duration_milliseconds(time.tick_since(t_rep)) }
    im.SetCursorPos({0, root.h + 8})
    im.Dummy({1, 1})
}

// Antialiased coverage of a rounded box, in box-local coordinates.
@(private="file")
shadow_box_coverage :: proc(x, y, w, h, radius: f32) -> f32 {
    if w <= 0 || h <= 0 do return 0
    r := clamp(radius, 0, min(w, h) * 0.5)
    qx := abs(x - w * 0.5) - (w * 0.5 - r)
    qy := abs(y - h * 0.5) - (h * 0.5 - r)
    ax, ay := max(qx, 0), max(qy, 0)
    d := math.sqrt(ax * ax + ay * ay) + min(max(qx, qy), 0) - r
    return clamp(0.5 - d, 0, 1)
}

// Blur the spread/offset silhouette first, then knock out the ORIGINAL border
// box. An outer shadow never shows through a translucent or absent background.
@(private="file")
shadow_mask_alpha :: proc(k: Shadow_Key, x0, y0: f32, w, h: int) -> []f32 {
    a := make([]f32, w * h, context.temp_allocator)
    sr := k.radius > 0 ? max(k.radius + k.spread, 0) : f32(0)
    for y in 0..<h {
        for x in 0..<w {
            px, py := x0 + f32(x) + 0.5, y0 + f32(y) + 0.5
            a[y*w+x] = shadow_box_coverage(px - k.dx + k.spread, py - k.dy + k.spread,
                k.w + 2*k.spread, k.h + 2*k.spread, sr)
        }
    }
    blur_alpha(a, w, h, k.blur * 0.5)
    for y in 0..<h {
        for x in 0..<w {
            px, py := x0 + f32(x) + 0.5, y0 + f32(y) + 0.5
            a[y*w+x] *= 1 - shadow_box_coverage(px, py, k.w, k.h, k.radius)
        }
    }
    return a
}

// Cached Gaussian alpha mask, drawn as one quad (also follows group transforms).
@(private="file")
draw_box_shadow :: proc(dl: ^im.DrawList, x0, y0, x1, y1, radius: f32, sh: Shadow, eff: f32) {
    // Mesma convencao das demais cores CSS: byte alto zero significa opaco.
    ab := (sh.color >> 24) & 0xff
    base := ab == 0 ? f32(1) : f32(ab) / 255.0
    if base <= 0 || eff <= 0 || g_renderer == nil do return
    k := Shadow_Key{x1-x0, y1-y0, radius, sh.dx, sh.dy, max(sh.blur, 0), sh.spread}
    if k.w <= 0 || k.h <= 0 || k.w + 2*k.spread <= 0 || k.h + 2*k.spread <= 0 do return
    e, found := g_shadow_masks[k]
    if !found {
        pad := blur_spread(k.blur * 0.5) + 2
        lx, ly := math.floor(min(0, k.dx-k.spread-pad)), math.floor(min(0, k.dy-k.spread-pad))
        rx, ry := math.ceil(max(k.w, k.w+k.dx+k.spread+pad)), math.ceil(max(k.h, k.h+k.dy+k.spread+pad))
        // Match the offscreen compositor's bounded texture allocation.
        if rx-lx > 8192 || ry-ly > 8192 || (rx-lx)*(ry-ly) > 16_777_216 do return
        w, h := int(rx-lx), int(ry-ly)
        a := shadow_mask_alpha(k, lx, ly, w, h)
        buf := make([]u8, w*h*4, context.temp_allocator)
        for v, i in a {
            buf[i*4] = 255; buf[i*4+1] = 255; buf[i*4+2] = 255
            buf[i*4+3] = u8(clamp(math.round(v*255), 0, 255))
        }
        tex := sdl2.CreateTexture(g_renderer, .ABGR8888, .STATIC, c.int(w), c.int(h))
        if tex == nil do return
        if sdl2.UpdateTexture(tex, nil, raw_data(buf), c.int(w*4)) != 0 {
            sdl2.DestroyTexture(tex); return
        }
        sdl2.SetTextureBlendMode(tex, .BLEND)
        sdl2.SetTextureScaleMode(tex, .Linear)
        e = Shadow_Mask{tex, lx, ly, w, h, g_frame}
    }
    e.used = g_frame; g_shadow_masks[k] = e
    p := im.Vec2{x0+e.x, y0+e.y}
    im.DrawList_AddImage(dl, im.TextureID(uintptr(e.tex)), p, {p.x+f32(e.w), p.y+f32(e.h)}, {0, 0}, {1, 1}, col_o(sh.color & 0x00ffffff, eff*base))
}

// Desenha uma box-shadow INSET (sombra interna). Empilha anéis translúcidos
// (AddRect stroked) para dentro das bordas, deslocados por (dx,dy) e recortados
// à caixa — o clip concentra a banda na aresta oposta ao deslocamento (dy>0 →
// banda no topo interno), aproximando o inner-shadow real sem blur nativo.
@(private="file")
draw_inset_shadow :: proc(dl: ^im.DrawList, x0, y0, x1, y1, radius: f32, sh: Shadow, eff: f32) {
    ab := (sh.color >> 24) & 0xff
    base := ab == 0 ? f32(1) : f32(ab) / 255.0
    if base <= 0 do return
    reach := max(sh.spread + sh.blur, 1)
    steps := clamp(int(reach * 0.7), 2, 12)
    a_each := base / f32(steps)
    rgb := sh.color & 0x00ffffff

    im.DrawList_PushClipRect(dl, {x0, y0}, {x1, y1}, true)
    for i in 0 ..< steps {
        inset := sh.spread + reach * (f32(i) / f32(max(steps - 1, 1)))
        ax0 := x0 + sh.dx + inset; ay0 := y0 + sh.dy + inset
        ax1 := x1 + sh.dx - inset; ay1 := y1 + sh.dy - inset
        if ax1 <= ax0 || ay1 <= ay0 do break
        rr := max(radius - inset, 0)
        im.DrawList_AddRect(dl, {ax0, ay0}, {ax1, ay1}, col_o(rgb, eff * a_each), rr, {}, 2)
    }
    im.DrawList_PopClipRect(dl)
}

// Expõe lerp_color p/ os testes (é private="file").
test_lerp_color :: proc(a, b: u32, t: f32) -> u32 { return lerp_color(a, b, t) }

// Expõe a interpolação premultiplicada e a cor de um gradiente num ponto t
// (com os stops já resolvidos), p/ os testes.
test_lerp_color_premul :: proc(a, b: u32, t: f32) -> u32 { return lerp_premul(a, b, t) }
test_grad_color_at :: proc(g: csspkg.Gradient, t: f32, line_px: f32 = 0) -> u32 {
    pos := resolve_grad_positions(g, line_px)
    return grad_color_at(g, pos, t, line_px)
}

// Expõe os steppers de transição p/ os testes.
test_trans_step_f :: proc(ch: ^Trans_FChan, target: f32, tr: Transition, dt: f32, init: bool) -> f32 { return trans_step_f(ch, target, tr, dt, init) }
test_trans_step_c :: proc(ch: ^Trans_CChan, target: u32, tr: Transition, dt: f32, init: bool) -> u32 { return trans_step_c(ch, target, tr, dt, init) }

// Interpola dois 0xAARRGGBB canal a canal. t clampado 0..1.
//
// ⚠️ NÃO usa o lerp_premul dos gradientes: aqui vale a convenção de cor do CSS
// desta engine, em que **byte alto 0 significa OPACO** (retrocompat com
// 0xRRGGBB — ver `vec()`, e é por isso que `transparent` é 0x01000000). Tratar
// esse 0 como "alpha zero" faria toda cor opaca virar transparente. Premultiplicar
// aqui exigiria normalizar a convenção antes e depois; enquanto isso não for
// feito, transição que envolve cor translúcida segue interpolando reto.
@(private="file")
lerp_color :: proc(a, b: u32, t: f32) -> u32 {
    f := clamp(t, 0, 1)
    ch :: proc(a, b: u32, sh: u32, f: f32) -> u32 {
        x := f32((a >> sh) & 0xff); y := f32((b >> sh) & 0xff)
        return (u32(x + (y - x) * f) & 0xff) << sh
    }
    return ch(a, b, 24, f) | ch(a, b, 16, f) | ch(a, b, 8, f) | ch(a, b, 0, f)
}

// ease-in-out (smoothstep) p/ a transição parecer natural.
@(private="file")
ease_inout :: proc(t: f32) -> f32 {
    x := clamp(t, 0, 1)
    return x * x * (3 - 2 * x)
}

Anim_Eval :: struct {
    has_xform:bool, xform:XMatrix,
    has_op:    bool, op:  f32,
    has_bg:    bool, bg:  u32,
    has_col:   bool, col: u32,
    has_rot:   bool, rot: f32,
    has_scale: bool, sx, sy: f32,
    has_translate: bool, tx, ty, tx_percent, ty_percent: f32,
}

// Avalia a animação em t_elapsed (segundos): resolve a posição no ciclo (delay,
// iteration-count, alternate), acha os stops vizinhos e interpola opacity/cor/fundo.
eval_anim :: proc(a: ^Anim, t_elapsed: f32, width:f32=0, height:f32=0) -> Anim_Eval {
    if a.n == 0 do return {}
    tt := t_elapsed - a.delay
    before := tt < 0
    if tt < 0 && !a.fill_before do return {}
    if tt < 0 do tt = 0
    cycles := a.dur > 0 ? tt / a.dur : 0
    prog: f32
    if !before && (a.dur == 0 || a.zero_iterations || (a.iter > 0 && cycles >= a.iter)) {
        if !a.fill_after do return {}
        whole := max(int(math.ceil(a.iter)) - 1, 0)
        prog = a.zero_iterations ? 0 : a.iter - f32(whole)
        if a.alternate && whole % 2 == 1 do prog = 1 - prog
    } else {
        w := int(cycles)
        prog = cycles - f32(w)
        if a.alternate && (w % 2 == 1) do prog = 1 - prog
    }
    if a.reverse do prog = 1 - prog

    out: Anim_Eval
    // Each property ignores keyframes that do not declare that property.
    // Missing 0/100% values come from the underlying computed style.
    for channel in 0 ..< 7 {
        s0, s1 := a.underlying, a.underlying
        s0.pct = 0; s1.pct = 1
        found := false
        for k in 0 ..< a.n {
            st := a.stops[k]
            present := false
            switch channel {
            case 0: present = st.has_opacity
            case 1: present = st.has_bg
            case 2: present = st.has_color
            case 3: present = st.has_rot
            case 4: present = st.has_scale
            case 5: present = st.has_translate
            case 6: present = st.has_xform
            }
            if !present do continue
            found = true
            if st.pct <= prog do s0 = st
            if st.pct > prog && st.pct <= s1.pct do s1 = st
            if st.pct == 1 && s1.pct == 1 do s1 = st
        }
        if !found do continue
        span := s1.pct - s0.pct
        lt := span > 0 ? clamp((prog - s0.pct) / span, 0, 1) : 0
        lt = timing_eval(s0.has_timing ? s0.timing : a.timing, lt)
        switch channel {
        case 0: out.has_op = true; out.op = s0.opacity + (s1.opacity-s0.opacity)*lt
        case 1: out.has_bg = true; out.bg = lerp_color(s0.bg,s1.bg,lt)
        case 2: out.has_col = true; out.col = lerp_color(s0.color,s1.color,lt)
        case 3: out.has_rot = true; out.rot = s0.rot+(s1.rot-s0.rot)*lt
        case 4:
            out.has_scale = true
            out.sx = s0.sx+(s1.sx-s0.sx)*lt; out.sy = s0.sy+(s1.sy-s0.sy)*lt
        case 6:
            out.has_xform=true
            out.xform=x_interpolate(s0.xform,s1.xform,lt,width,height)
        case 5:
            out.has_translate = true
            out.tx = s0.tx+(s1.tx-s0.tx)*lt; out.ty = s0.ty+(s1.ty-s0.ty)*lt
            out.tx_percent = s0.tx_percent+(s1.tx_percent-s0.tx_percent)*lt
            out.ty_percent = s0.ty_percent+(s1.ty_percent-s0.ty_percent)*lt
        }
    }
    return out
}

test_eval_anim :: proc(a: ^Anim, elapsed: f32) -> Anim_Eval { return eval_anim(a, elapsed) }

// Recolore os vértices emitidos desde `vtx0` com a cor do gradiente NA POSIÇÃO de
// cada vértice — é assim que `background-clip: text` vira texto com gradiente de
// verdade, sem clip de glifo nem render target: o ImGui guarda a cobertura do
// glifo na TEXTURA e a cor no vértice, então trocar a cor do vértice pinta o
// glifo. Cada quad de glifo tem 4 vértices, logo a rampa interpola DENTRO de cada
// glifo, não só entre eles.
//
// ⚠️ O ALPHA do vértice é preservado (é ele que carrega `opacity` e a cor do
// texto); só o RGB vem do gradiente. Gradiente que varia alpha (fade p/
// transparente) não afeta o texto — degradação anotada, com teste.
@(private="file")
shade_vertices_gradient :: proc(dl: ^im.DrawList, vtx0: int, p_min, p_max: im.Vec2, g: csspkg.Gradient, opa: f32) {
    n := int(dl.VtxBuffer.Size)
    if vtx0 >= n || g.n < 2 do return
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    if W < 0.5 || H < 0.5 do return

    // Geometria da linha do gradiente: a MESMA de paint_gradient/_diagonal, para
    // que o texto e uma caixa com o mesmo gradiente casem cor a cor.
    cx := (p_min.x + p_max.x) * 0.5
    cy := (p_min.y + p_max.y) * 0.5
    dx, dy, L: f32
    if g.diagonal {
        th := g.angle * math.PI / 180
        st := math.sin(th); ct := math.cos(th)
        dx = st; dy = -ct
        L  = abs(W * st) + abs(H * ct)
    } else {
        horiz := g.dir == .Right || g.dir == .Left
        rev   := g.dir == .Left  || g.dir == .Top
        dx = horiz ? (rev ? -1 : 1) : 0
        dy = horiz ? 0 : (rev ? -1 : 1)
        L  = horiz ? W : H
    }
    if L < 0.5 do return
    pos := resolve_grad_positions(g, L)

    verts := ([^]im.DrawVert)(dl.VtxBuffer.Data)
    for i in vtx0 ..< n {
        p := verts[i].pos
        t := clamp((((p.x - cx) * dx + (p.y - cy) * dy) + L * 0.5) / L, 0, 1)
        c := imgui_mul_alpha(grad_color_at(g, pos, t, L), opa)
        verts[i].col = (verts[i].col & 0xFF000000) | (c & 0x00FFFFFF)
    }
}

// Aplica a matriz linear 2×2 [a b; c d] (em torno de cx,cy) aos vértices
// [vtx0, fim) do DrawList. Cobre rotate/scale/skew/matrix — o translate já vai via
// offset ox/oy. p' = C + M·(p − C).
@(private="file")
transform_vertices :: proc(dl: ^im.DrawList, vtx0: int, cx, cy, a, b, c, d: f32) {
    n := int(dl.VtxBuffer.Size)
    if vtx0 >= n do return
    verts := ([^]im.DrawVert)(dl.VtxBuffer.Data)
    for i in vtx0 ..< n {
        p := verts[i].pos
        dx := p.x - cx; dy := p.y - cy
        verts[i].pos = {cx + a*dx + b*dy, cy + c*dx + d*dy}
    }
}

@(private="file")
cursor_to_imgui :: proc(c: Cursor_Kind) -> im.MouseCursor {
    switch c {
    case .Pointer:    return .Hand
    case .Text:       return .TextInput
    case .Move:       return .ResizeAll
    case .NotAllowed: return .NotAllowed
    case .Progress:   return .Progress
    case .Auto:       return .Arrow
    }
    return .Arrow
}

// Interpola dois RGB (0xRRGGBB) por t∈[0,1]: a·(1−t) + b·t, canal a canal.
@(private="file")
mix_rgb :: proc(a, b: u32, t: f32) -> u32 {
    ar, ag, ab := (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff
    br, bg, bb := (b >> 16) & 0xff, (b >> 8) & 0xff, b & 0xff
    r := u32(f32(ar) + (f32(br) - f32(ar)) * t)
    g := u32(f32(ag) + (f32(bg) - f32(ag)) * t)
    bl := u32(f32(ab) + (f32(bb) - f32(ab)) * t)
    return (r << 16) | (g << 8) | bl
}

// Cor de contraste p/ a marca (✓) sobre um accent: escura sobre accent claro,
// branca sobre accent escuro (luminância relativa aproximada).
@(private="file")
accent_contrast :: proc(c: u32) -> u32 {
    r, g, b := f32((c >> 16) & 0xff), f32((c >> 8) & 0xff), f32(c & 0xff)
    lum := (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return lum > 0.6 ? 0x1a1a1a : 0xffffff
}

// Desenha o estado MARCADO de um checkbox/radio (nada se desmarcado): no checkbox,
// preenche a caixa de azul e traça o ✓ branco; no radio, um ponto azul central.
@(private="file")
paint_control_mark :: proc(dl: ^im.DrawList, screen: im.Vec2, b: ^Box, radius, eff: f32) {
    if !b.ctrl_checked do return
    x, y, w, h := screen.x, screen.y, b.w, b.h
    // accent-color define a cor do preenchimento; senão o azul padrão do UA.
    accent: u32 = b.ctrl_disabled ? 0x8aa9d6 : 0x1a73e8
    if b.has_accent {
        accent = b.accent_color
        if b.ctrl_disabled do accent = mix_rgb(accent, 0xffffff, 0.45) // desbota se disabled
    }
    if b.ctrl == .Radio {
        im.DrawList_AddCircleFilled(dl, {x + w*0.5, y + h*0.5}, w*0.28, col_o(accent, eff))
    } else {
        im.DrawList_AddRectFilled(dl, {x, y}, {x + w, y + h}, col_o(accent, eff), radius)
        // marca com contraste conforme a luminância do accent (clara→marca escura)
        c: u32 = accent_contrast(accent)
        if b.ctrl_disabled do c = mix_rgb(c, 0xffffff, 0.3)
        th := max(w*0.14, 1.4)
        im.DrawList_AddLine(dl, {x + w*0.24, y + h*0.52}, {x + w*0.42, y + h*0.70}, col_o(c, eff), th)
        im.DrawList_AddLine(dl, {x + w*0.42, y + h*0.70}, {x + w*0.76, y + h*0.30}, col_o(c, eff), th)
    }
}

// Coloca um InputText do ImGui (transparente) sobre a área interna do campo —
// o fundo/borda já foram desenhados por paint_box. O buffer vive no próprio Box,
// então o texto digitado persiste entre frames.
@(private="file")
paint_text_input :: proc(b: ^Box, screen: im.Vec2, eff: f32) {
    mouse:=x_widget_mouse(b)
    defer x_widget_restore(mouse)
    txt := b.edit_color != 0 ? b.edit_color : DEFAULT_TEXT
    if b.ctrl_disabled do txt = 0x9a9a9a

    // frame transparente (a caixa já foi pintada) e sem padding extra do ImGui;
    // assim controlamos a posição do texto manualmente.
    im.PushStyleColor(.FrameBg, 0)
    im.PushStyleColor(.FrameBgHovered, 0)
    im.PushStyleColor(.FrameBgActive, 0)
    im.PushStyleColor(.Text, col_o(txt, eff))
    // cor do placeholder: `::placeholder` quando existe, senão o texto a 50%
    hint_c := b.hint_color != 0 ? b.hint_color : txt
    hint_a := eff * (b.hint_color != 0 ? f32(1.0) : f32(0.5)) * (b.hint_alpha > 0 ? b.hint_alpha : 0)
    im.PushStyleColor(.TextDisabled, col_o(hint_c, hint_a))
    im.PushStyleVarImVec2(.FramePadding, {0, 0})
    defer { im.PopStyleVar(1); im.PopStyleColor(5) }

    // usa a fonte do conteúdo (mesma da página), no tamanho do CSS
    pushed_font := b.edit_font != nil
    if pushed_font do im.PushFont(b.edit_font)
    defer { if pushed_font do im.PopFont() }

    flags: im.InputTextFlags
    if b.ctrl == .Password do flags += {.Password}
    if b.ctrl_disabled || b.ctrl_readonly do flags += {.ReadOnly}
    im.BeginDisabled(b.ctrl_disabled)
    defer im.EndDisabled()

    id := fmt.ctprintf("##ti_%p", b)

    // área interna (dentro de borda + padding)
    ix := screen.x + b.border_w[3] + b.padding[3]
    iw := b.w - b.border_w[3] - b.border_w[1] - b.padding[3] - b.padding[1]
    if iw < 4 do iw = 4

    if b.ctrl == .Textarea {
        // multi-linha: preenche toda a área interna (não centraliza).
        iy := screen.y + b.border_w[0] + b.padding[0]
        ih := b.h - b.border_w[0] - b.border_w[2] - b.padding[0] - b.padding[2]
        if ih < 4 do ih = 4
        im.SetCursorScreenPos({ix, iy})
        if b.edit_hint != "" && b.edit_buf[0] == 0 {
            // InputTextMultiline não tem variante "with hint": desenha o
            // placeholder manualmente quando o buffer está vazio.
            hint := strings.clone_to_cstring(b.edit_hint, context.temp_allocator)
            im.DrawList_AddText(im.GetWindowDrawList(), {ix, iy}, col_o(hint_c, hint_a), hint)
        }
        im.InputTextMultiline(id, cstring(&b.edit_buf[0]), EDIT_CAP, {iw, ih}, flags)
        return
    }

    // linha única: centraliza verticalmente na altura da caixa.
    line_h := im.GetTextLineHeight()
    iy := screen.y + max((b.h - line_h) * 0.5, b.border_w[0])
    im.SetCursorScreenPos({ix, iy})
    im.SetNextItemWidth(iw)
    if b.edit_hint != "" {
        hint := strings.clone_to_cstring(b.edit_hint, context.temp_allocator)
        im.InputTextWithHint(id, hint, cstring(&b.edit_buf[0]), EDIT_CAP, flags)
    } else {
        im.InputText(id, cstring(&b.edit_buf[0]), EDIT_CAP, flags)
    }
    paint_caret_over(b, ix, iy, eff)
}

// caret-color (css-ui §4).
//
// ⚠️⚠️ O ImGui 1.91.9b desenha o cursor com **`ImGuiCol_Text`** — a MESMA cor do
// texto — e não tem `ImGuiCol_InputTextCursor` (que só chegou em versão
// posterior). Por isso o lote 7 PULOU esta prop: empurrar a cor pelo
// `PushStyleColor(.Text)` pintaria o texto junto. O caminho que sobra é
// REDESENHAR o cursor por cima, na cor certa — e as três peças que faltavam
// (índice do cursor, scroll horizontal e o timer da piscada) estão expostas nas
// bindings internas.
//
// ⚠️ As fórmulas abaixo foram LIDAS do `vendor/imgui/imgui/imgui_widgets.cpp`
// (bloco "Draw blinking cursor"), não reconstituídas de memória: como estamos
// pintando POR CIMA do cursor do ImGui, um erro de 1 px apareceria como caret
// DOBRADO, e um erro na fase da piscada como um caret que não apaga.
//   draw_pos          = frame_bb.Min + FramePadding   (empurramos FramePadding=0)
//   cursor_offset.x   = largura do texto até o cursor
//   cursor_offset.y   = cursor_line_no * FontSize, e `line_count` COMEÇA EM 1
//   cursor_screen_pos = trunc(draw_pos + cursor_offset - scroll)
//   rect              = (x, y-FontSize+0.5) .. (x+1, y-1.5)
//   visível           = CursorAnim <= 0 || fmod(CursorAnim, 1.20) <= 0.80
@(private="file")
paint_caret_over :: proc(b: ^Box, ix, iy: f32, eff: f32) {
    if !b.has_caret do return
    // `Password` desenha bolinhas em vez do texto, então a largura do prefixo
    // não é a do buffer — o caret sairia no lugar errado. Fica de fora.
    if b.ctrl == .Password do return
    if !im.IsItemActive() do return // só o campo com FOCO tem cursor

    g := im.GetCurrentContext()
    if g == nil do return
    st := &g.InputTextState
    if st.ID_ != im.GetItemID() do return

    // fase APAGADA da piscada: não desenha (senão o caret nunca some)
    blink := g.IO.ConfigInputTextCursorBlink && st.CursorAnim > 0
    if blink && math.mod(st.CursorAnim, 1.20) > 0.80 do return

    cur := int(im.InputTextState_GetCursorPos(st))
    n   := int(st.TextLen)
    cur = clamp(cur, 0, n)
    fs := im.GetFontSize()
    prefix_w: f32 = 0
    if cur > 0 && st.TextA.Data != nil {
        buf := ([^]u8)(st.TextA.Data)[:cur]
        pfx := strings.clone_to_cstring(string(buf), context.temp_allocator)
        // ⚠️ NÃO usar `CalcTextSize`: ele ARREDONDA PARA CIMA
        // (`text_size.x = IM_TRUNC(text_size.x + 0.99999f)` no imgui.cpp),
        // enquanto o `InputTextCalcTextSize` que posiciona o cursor usa o avanço
        // CRU. A diferença é de até 1 px — e 1 px aqui é um caret DOBRADO,
        // porque o nosso deixa de cobrir o do ImGui. Foi o que a captura pegou.
        prefix_w = im.Font_CalcTextSizeA(im.GetFont(), fs, 1e9, 0, pfx).x
    }

    cx := math.trunc(ix + prefix_w - st.Scroll.x)
    cy := math.trunc(iy + fs) // cursor_line_no = 1 em campo de UMA linha
    im.DrawList_AddLine(im.GetWindowDrawList(), {cx, cy - fs + 0.5}, {cx, cy - 1.5},
        col_o(b.caret_color, eff), 1)
}

// Escolha feita num <select> neste frame, para ser APLICADA depois do paint (o
// mesmo desenho do `click_target`: mexer no DOM/rodar JS no meio do replay
// invalidaria as caixas que ainda vão ser pintadas). Consumido por
// `take_select_change` em browser_ui/headless.
g_select_change: struct { sel: ^dompkg.Node, opt: ^dompkg.Node }

// Devolve (e limpa) a escolha pendente de <select>. nil,nil = nada mudou.
take_select_change :: proc() -> (sel: ^dompkg.Node, opt: ^dompkg.Node) {
    sel, opt = g_select_change.sel, g_select_change.opt
    g_select_change = {}
    return
}

// Aterra a escolha no DOM: `selected` fica SÓ na opção escolhida e o valor
// corrente vai para o atributo `value` do select — que é onde o dom_bindings lê e
// escreve `el.value` (ver a nota lá). Separado do dispatch de evento de propósito:
// o valor tem de estar no DOM ANTES de qualquer handler rodar, senão o script lê
// `e.target.value` VELHO, que é justo o que um select controlado usa p/ decidir o
// próximo estado.
apply_select_choice :: proc(sel: ^dompkg.Node, opt: ^dompkg.Node) {
    if sel == nil || opt == nil do return
    opts := make([dynamic]^dompkg.Node, context.temp_allocator)
    select_options(sel, &opts)
    for o in opts {
        if o == opt do dompkg.set_attr(o, strings.clone("selected"), strings.clone("true"))
        else        do dompkg.del_attr(o, "selected")
    }
    dompkg.set_attr(sel, strings.clone("value"), strings.clone(option_value(opt)))
}

// <select> fechado + popup da lista, via BeginCombo do ImGui (mesma estratégia do
// campo de texto, que usa o InputText): o frame do widget é TRANSPARENTE — o
// fundo/borda/raio da caixa já foram pintados pelo CSS — e o popup entra como
// janela própria do ImGui, então aparece por cima do resto da página.
paint_select :: proc(b: ^Box, screen: im.Vec2, eff: f32) {
    if b.node == nil do return
    txt := b.edit_color != 0 ? b.edit_color : DEFAULT_TEXT
    if b.ctrl_disabled do txt = 0x9a9a9a

    opts := make([dynamic]^dompkg.Node, context.temp_allocator)
    select_options(b.node, &opts)
    cur := select_selected_index(b.node, opts[:])

    im.PushStyleColor(.FrameBg, 0)
    im.PushStyleColor(.FrameBgHovered, 0)
    im.PushStyleColor(.FrameBgActive, 0)
    im.PushStyleColor(.Text, col_o(txt, eff))
    // a lista é janela do ImGui, que herdaria o tema do CHROME do navegador (escuro)
    // sobre uma página clara — força um visual de lista nativa, legível nos dois.
    im.PushStyleColor(.PopupBg, col(0xffffff))
    im.PushStyleColor(.Border, col(0xd0d7de))
    im.PushStyleColor(.Header, col(0xdbeafe))        // item selecionado
    im.PushStyleColor(.HeaderHovered, col(0xbfdbfe)) // sob o cursor
    im.PushStyleColor(.HeaderActive, col(0xbfdbfe))
    im.PushStyleVarImVec2(.FramePadding, {0, 0})
    defer { im.PopStyleVar(1); im.PopStyleColor(9) }

    pushed_font := b.edit_font != nil
    if pushed_font do im.PushFont(b.edit_font)
    defer { if pushed_font do im.PopFont() }

    // área interna (dentro de borda + padding), como no campo de texto
    ix := screen.x + b.border_w[3] + b.padding[3]
    iw := b.w - b.border_w[3] - b.border_w[1] - b.padding[3] - b.padding[1]
    if iw < 4 do iw = 4
    line_h := im.GetTextLineHeight()
    iy := screen.y + max((b.h - line_h) * 0.5, b.border_w[0])

    preview: cstring = ""
    if cur >= 0 do preview = strings.clone_to_cstring(option_label(opts[cur]), context.temp_allocator)

    flags: im.ComboFlags
    // appearance:none = o autor desenha o próprio indicador (o padrão do
    // Tailwind é um <svg> chevron posicionado por cima) → sem a setinha nativa,
    // senão aparecem DUAS.
    if b.appearance_none do flags += {.NoArrowButton}

    im.SetCursorScreenPos({ix, iy})
    im.SetNextItemWidth(iw)
    im.BeginDisabled(b.ctrl_disabled)
    defer im.EndDisabled()

    id := fmt.ctprintf("##sel_%p", b)
    // Keep preview geometry in the box plane; open the native popup using
    // the projected anchor and physical mouse, outside that coordinate scope.
    mouse:=x_widget_mouse(b)
    released:=im.InvisibleButton(id,{iw,line_h},{.EnableNav})
    pressed:=released || (im.IsItemHovered() && im.IsMouseClicked(.Left))
    item_id:=im.GetItemID()
    x_widget_restore(mouse)
    dl:=im.GetWindowDrawList()
    arrow:=b.appearance_none ? f32(0) : line_h
    im.RenderTextClipped({ix,iy},{ix+iw-arrow,iy+line_h},preview,nil,nil)
    if arrow>0 {
        im.DrawList_AddTriangleFilled(dl,{ix+iw-arrow*.75,iy+line_h*.4},{ix+iw-arrow*.25,iy+line_h*.4},{ix+iw-arrow*.5,iy+line_h*.65},col_o(txt,eff))
    }
    popup_id:=im.cImHashStr("##ComboPopup",0,item_id)
    if pressed && !im.IsPopupOpenID(popup_id,im.PopupFlags_None) do im.OpenPopupEx(popup_id,im.PopupFlags_None)
    anchor:=b.x_world*x_translation64(ix-b.x_paint_origin.x,iy-b.x_paint_origin.y,0)
    x0,y0,x1,y1:=x_bounds(anchor,iw,line_h)
    rect:=im.Rect{{x0+b.x_view_origin.x,y0+b.x_view_origin.y},{x1+b.x_view_origin.x,y1+b.x_view_origin.y}}
    im.SetNextWindowPos({rect.Min.x,rect.Max.y})
    opened:=im.BeginComboPopup(popup_id,rect,flags)
    if opened {
        for o, i in opts {
            lbl := strings.clone_to_cstring(option_label(o), context.temp_allocator)
            if im.Selectable(lbl, i == cur) && i != cur {
                // não muda o DOM aqui: só registra a escolha (ver g_select_change)
                g_select_change = {b.node, o}
            }
            if i == cur do im.SetItemDefaultFocus()
        }
        im.EndCombo()
    }
}

// Nome do grupo de um radio (atributo name); "" = sem grupo (não desliga outros).
@(private="file")
radio_name :: proc(b: ^Box) -> string {
    if b.node == nil do return ""
    return b.node.attrs["name"]
}

// Desmarca todos os radios de um grupo (mesmo name) na árvore — inclui os que
// estão dentro de caixas inline (InlineBox). Usado ao marcar um radio.
@(private="file")
uncheck_radio_group :: proc(b: ^Box, name: string) {
    if b == nil do return
    if b.ctrl == .Radio && radio_name(b) == name do b.ctrl_checked = false
    for c in b.children do uncheck_radio_group(c, name)
    for &it in b.inlines do if it.kind == .InlineBox && it.box != nil do uncheck_radio_group(it.box, name)
}

// Raio efetivo dos cantos → (raio único, flags de cantos). Resolve %, limita à
// metade do menor lado. O raio devolvido é o maior dos 4; as flags marcam quais
// cantos arredondam. Exato quando os cantos arredondados compartilham o raio.
@(private="file")
corner_rounding :: proc(b: ^Box) -> (f32, im.DrawFlags) {
    mn := min(b.w, b.h) * 0.5
    r: [4]f32
    maxr: f32 = 0
    for i in 0 ..< 4 {
        v := b.border_radius_pct[i] ? b.border_radius[i] * min(b.w, b.h) : b.border_radius[i]
        if v > mn do v = mn
        r[i] = v
        if v > maxr do maxr = v
    }
    if maxr <= 0.5 do return 0, {}
    flags: im.DrawFlags
    if r[0] > 0.5 do flags |= im.DrawFlags_RoundCornersTopLeft     // tl
    if r[1] > 0.5 do flags |= im.DrawFlags_RoundCornersTopRight    // tr
    if r[2] > 0.5 do flags |= im.DrawFlags_RoundCornersBottomRight // br
    if r[3] > 0.5 do flags |= im.DrawFlags_RoundCornersBottomLeft  // bl
    return maxr, flags
}

// "Recorta" os cantos arredondados de um container overflow:hidden: preenche o
// entalhe de cada canto (a área quadrada FORA do arco) com a cor de trás, já que
// o clip do ImGui é retangular e não arredonda os filhos. `flags` = cantos ativos.
@(private="file")
mask_round_corners :: proc(dl: ^im.DrawList, x0, y0, x1, y1, radius: f32, flags: im.DrawFlags, color: u32) {
    r := radius
    PI :: f32(3.14159265)
    notch :: proc(dl: ^im.DrawList, corner, center: im.Vec2, r, a0, a1: f32, color: u32) {
        im.DrawList_PathClear(dl)
        im.DrawList_PathLineTo(dl, corner)
        im.DrawList_PathArcTo(dl, center, r, a0, a1, 0)
        im.DrawList_PathFillConvex(dl, color)
    }
    if flags & im.DrawFlags_RoundCornersTopLeft     != {} do notch(dl, {x0, y0}, {x0 + r, y0 + r}, r, PI,        1.5 * PI, color)
    if flags & im.DrawFlags_RoundCornersTopRight    != {} do notch(dl, {x1, y0}, {x1 - r, y0 + r}, r, 1.5 * PI,  2.0 * PI, color)
    if flags & im.DrawFlags_RoundCornersBottomRight != {} do notch(dl, {x1, y1}, {x1 - r, y1 - r}, r, 0,         0.5 * PI, color)
    if flags & im.DrawFlags_RoundCornersBottomLeft  != {} do notch(dl, {x0, y1}, {x0 + r, y1 - r}, r, 0.5 * PI,  PI,       color)
}

// Preenche o entalhe da curva INTERNA (padding-box) de cada canto arredondado:
// a área do canto da padding-box que fica FORA da curva interna. É exatamente
// onde o canto QUADRADO de um filho (que preenche a padding-box: `width:100%`,
// `inset:0`, …) cobre a faixa de fundo/borda que deveria contornar o canto —
// o clip de overflow do ImGui é retangular e não arredonda os filhos.
//
// css-backgrounds-3 §5.3: as duas curvas são CONCÊNTRICAS e o raio interno é o
// externo menos a largura da borda DAQUELE lado, com piso em 0 — ou seja, a faixa
// de um canto é um SETOR DE ANEL. Um TRAÇO de arco de espessura `w` no raio
// r − w/2 cobre exatamente [r − w, r], e é o que se desenha aqui.
//
// ⚠️ o caminho óbvio — preencher o polígono `canto + arco` — NÃO serve: ele é
// NÃO-CONVEXO (o arco curva PARA o canto). O leque de triângulos do
// PathFillConvex acerta a área (a região é estrelada a partir do canto), mas o
// anel de ANTI-ALIASING desloca cada vértice pela média das normais e a mitra
// ESTOURA nos vértices côncavos (o IM_FIXNORMAL2F do ImGui deixa a escala chegar
// a 100×): medido, +2,8px de preenchimento OPACO além da curva na linha mais
// tangente, erro médio 0,77px contra a curva teórica. E o PathFillConcave deste
// build devolve o FECHO CONVEXO (a fronteira vira uma reta a 45°) nos DOIS
// sentidos de enrolamento — não dá p/ usar. O traço de polilinha não tem nenhum
// dos dois problemas: o AA é por aresta, sem junta côncava fechando o caminho.
//
// `bw` = [topo, dir, base, esq]; `flags` = quais cantos arredondam.
// DEGRADAÇÃO: com larguras DIFERENTES nos dois lados de um canto a curva interna
// é uma elipse, que um traço circular não descreve — usa-se a MENOR das duas, que
// erra por FALTA (deixa uma lasca por restaurar) em vez de comer o conteúdo.
@(private="file")
fill_inner_notch :: proc(dl: ^im.DrawList, x0, y0, x1, y1: f32, bw: [4]f32, radius: f32, flags: im.DrawFlags, color: u32) {
    if color >> 24 == 0 do return // fill totalmente transparente: nada a compor
    r := radius
    PI :: f32(3.14159265)
    // Estende o arco um tico além dos pontos de tangência para não deixar fio de
    // cabelo na emenda com a faixa RETA: ali o traço cai sobre a própria faixa,
    // que já está correta, então o excesso pinta a mesma cor por cima.
    EXT :: f32(0.06)
    band :: proc(dl: ^im.DrawList, center: im.Vec2, r, w, a0, a1: f32, color: u32) {
        if w <= 0.25 || r - w <= 0.5 do return // sem borda, ou raio ≤ borda: nada a restaurar
        im.DrawList_PathClear(dl)
        im.DrawList_PathArcTo(dl, center, r - w * 0.5, a0 - EXT, a1 + EXT, 0)
        im.DrawList_PathStroke(dl, color, {}, w)
    }
    if flags & im.DrawFlags_RoundCornersTopLeft != {} {
        band(dl, {x0 + r, y0 + r}, r, min(bw[0], bw[3]), PI, 1.5 * PI, color)
    }
    if flags & im.DrawFlags_RoundCornersTopRight != {} {
        band(dl, {x1 - r, y0 + r}, r, min(bw[0], bw[1]), 1.5 * PI, 2.0 * PI, color)
    }
    if flags & im.DrawFlags_RoundCornersBottomRight != {} {
        band(dl, {x1 - r, y1 - r}, r, min(bw[2], bw[1]), 0, 0.5 * PI, color)
    }
    if flags & im.DrawFlags_RoundCornersBottomLeft != {} {
        band(dl, {x0 + r, y1 - r}, r, min(bw[2], bw[3]), 0.5 * PI, PI, color)
    }
}

// Traço de contorno DENTRO da caixa `p0..p1`, com aresta EXTERNA exatamente sobre
// ela. ⚠️ o traço do `AddRect` do ImGui é CENTRADO no caminho: desenhá-lo na
// border-box joga METADE da largura para FORA do elemento, e a borda do CSS é
// desenhada por DENTRO (css-backgrounds-3 §4: a área da borda vai da border-box à
// padding-box). Medido contra o Chrome numa borda de 5px: os 2,5px de fora
// pintavam onde o Chrome deixa o fundo da página, e só 3 dos 5px internos ficavam
// com a cor da borda.
//
// ⚠️⚠️ O RECUO NÃO É w/2. O `AddRect` do ImGui já aplica um recuo PRÓPRIO de meio
// pixel ao caminho (`PathRect(p_min + 0.5, p_max - 0.49)`), então pedir mais w/2
// corrige meio pixel A MAIS e a borda sai ESPALHADA em vez de nítida. Medido numa
// borda de 3px com a border-box em x=20 (o Chrome pinta 20,21,22 opacos):
//   caminho na border-box  -> 19,20,21 opacos          (deslocada 1px p/ FORA)
//   recuo de w/2           -> 20:128 21:0 22:0 23:128  (no lugar, porém BORRADA)
//   recuo de w/2 - 0.5     -> 20,21,22 opacos          (igual ao Chrome)
// Vale para largura par e ímpar: 1px cai num pixel só, 2px em dois.
//
// O raio do CAMINHO desce `w/2` (não `h`), que é o recuo TOTAL até o eixo do
// traço — assim o centro da curva não se move e a aresta externa fica no `radius`
// pedido. DEGRADAÇÃO: com raio menor que w/2 o caminho fica com raio 0 e o canto
// externo sai reto em vez de arredondado — erro limitado a `radius` (≤ w/2).
@(private="file")
stroke_inside :: proc(dl: ^im.DrawList, p0, p1: im.Vec2, col: u32, radius, w: f32, flags: im.DrawFlags) {
    if w <= 0 do return
    // borda mais larga que a caixa: os quatro lados se encontram e cobrem tudo
    if p1.x - p0.x <= w || p1.y - p0.y <= w {
        im.DrawList_AddRectFilled(dl, p0, p1, col, radius, flags)
        return
    }
    h := w * 0.5 - 0.5 // pode ser NEGATIVO p/ borda subpixel — e aí é o certo
    im.DrawList_AddRect(dl, {p0.x + h, p0.y + h}, {p1.x - h, p1.y - h},
                        col, max(0, radius - w * 0.5), flags, w)
}

// Pinta a borda. Uniforme (mesma largura e cor nos 4 lados) usa um único
// traco interno (respeita o raio). Lados diferentes usam um anel compartilhado,
// com curvas internas elipticas e sem sobreposicao nos cantos.
@(private="file")
paint_border :: proc(dl: ^im.DrawList, screen: im.Vec2, b: ^Box, cols: [4]u32, eff, radius: f32, flags: im.DrawFlags) {
    bwt, bwr, bwb, bwl := b.border_w[0], b.border_w[1], b.border_w[2], b.border_w[3]
    uniform := bwt == bwr && bwr == bwb && bwb == bwl &&
               cols[0] == cols[1] && cols[1] == cols[2] && cols[2] == cols[3]
    if uniform {
        stroke_inside(dl, screen, {screen.x + b.w, screen.y + b.h}, col_o(cols[0], eff), radius, bwt, flags)
        return
    }
    paint_border_ring(dl, screen, b, cols, eff, radius, flags)
}

// ox/oy: deslocamento acumulado de position:relative dos ancestrais.
// opa: opacidade efetiva herdada dos ancestrais (multiplicada com a própria).
// `in_xform`: algum ancestral (ou o próprio) tem transform. Um elemento
// transformado vira BLOCO CONTENEDOR de position:fixed e de
// background-attachment:fixed (css-transforms §3) — dentro dele o fundo
// volta a se comportar como `scroll`. Sem isto o reftest
// background-attachment-fixed-inside-transform-1 regride.
// Lado (px de tela) da alça de resize: área sensível ao mouse e área desenhada.
@(private="file") RESIZE_GRIP :: f32(14)
// Piso do tamanho arrastado, no espaço do box-sizing. Existe só p/ a caixa não
// desaparecer sob o cursor; os limites de VERDADE (min-width/min-height) são
// aplicados pelo layout, porque o arraste entra pelos mesmos campos do autor.
// ── border-image (css-backgrounds-3 §6) ─────────────────────────────────────
// A imagem é cortada em 9 pelas quatro `slice`: os 4 CANTOS vão ESTICADOS para
// os cantos da área, as 4 BORDAS seguem o `border-image-repeat`, e o miolo só
// aparece com `fill`. Sem imagem pronta (ainda baixando, ou falhou), cai na
// borda normal — que é o que a spec manda e o motivo de o comando carregar as
// cores da borda até a pintura.

// Um retângulo da imagem, com recorte em coords de TELA (o UV é reinterpolado
// no corte, senão o ladrilho parcial da ponta sairia esticado em vez de cortado).
@(private="file")
bimg_quad_clip :: proc(
    dl: ^im.DrawList, tex: im.TextureID, tint: u32, iw, ih: f32,
    dx0, dy0, dx1, dy1: f32, sx0, sy0, sx1, sy1: f32, cx0, cy0, cx1, cy1: f32,
) {
    if dx1 <= dx0 || dy1 <= dy0 || sx1 <= sx0 || sy1 <= sy0 do return
    vx0 := max(dx0, cx0); vy0 := max(dy0, cy0)
    vx1 := min(dx1, cx1); vy1 := min(dy1, cy1)
    if vx1 <= vx0 || vy1 <= vy0 do return
    fx0 := (vx0 - dx0) / (dx1 - dx0); fx1 := (vx1 - dx0) / (dx1 - dx0)
    fy0 := (vy0 - dy0) / (dy1 - dy0); fy1 := (vy1 - dy0) / (dy1 - dy0)
    im.DrawList_AddImage(dl, tex, {vx0, vy0}, {vx1, vy1},
        {(sx0 + (sx1 - sx0) * fx0) / iw, (sy0 + (sy1 - sy0) * fy0) / ih},
        {(sx0 + (sx1 - sx0) * fx1) / iw, (sy0 + (sy1 - sy0) * fy1) / ih}, tint)
}

// Uma BORDA (a faixa entre dois cantos). `horiz` = a faixa se repete em x.
@(private="file")
bimg_edge :: proc(
    dl: ^im.DrawList, tex: im.TextureID, tint: u32, iw, ih: f32,
    dx0, dy0, dx1, dy1: f32, sx0, sy0, sx1, sy1: f32, mode: Bimg_Repeat, horiz: bool,
) {
    if dx1 <= dx0 || dy1 <= dy0 || sx1 <= sx0 || sy1 <= sy0 do return
    if mode == .Stretch {
        bimg_quad_clip(dl, tex, tint, iw, ih, dx0, dy0, dx1, dy1, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1)
        return
    }
    // tamanho NATURAL do ladrilho = o da fatia, na escala do eixo PERPENDICULAR
    dlen  := horiz ? dx1 - dx0 : dy1 - dy0
    scale := horiz ? (dy1 - dy0) / (sy1 - sy0) : (dx1 - dx0) / (sx1 - sx0)
    tile  := (horiz ? sx1 - sx0 : sy1 - sy0) * scale
    if tile <= 0.5 { // ladrilho sub-pixel: milhares de quads que somem — estica
        bimg_quad_clip(dl, tex, tint, iw, ih, dx0, dy0, dx1, dy1, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1)
        return
    }
    off: f32 = 0
    n := 0
    if mode == .Round {
        // `round` ESPREME o ladrilho p/ caber um nº inteiro de vezes
        n = max(1, int(math.round(dlen / tile)))
        tile = dlen / f32(n)
    } else {
        // `repeat` mantém o tamanho e CENTRALIZA, cortando as duas pontas.
        // ⚠️ `space` cai aqui: distribuir a sobra em vãos não está implementado.
        n = int(math.ceil(dlen / tile)) + 1
        off = (dlen - f32(n) * tile) * 0.5
    }
    if n > 512 { // teto: padrão minúsculo em borda longa (mesmo espírito do dash)
        bimg_quad_clip(dl, tex, tint, iw, ih, dx0, dy0, dx1, dy1, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1)
        return
    }
    for i in 0 ..< n {
        a := off + f32(i) * tile
        if horiz {
            bimg_quad_clip(dl, tex, tint, iw, ih, dx0 + a, dy0, dx0 + a + tile, dy1,
                sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1)
        } else {
            bimg_quad_clip(dl, tex, tint, iw, ih, dx0, dy0 + a, dx1, dy0 + a + tile,
                sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1)
        }
    }
}

// Larguras da borda-imagem por lado (t r b l), já com a redução do §6.3.
@(private="file")
bimg_widths :: proc(bi: Border_Image, bw: [4]f32, sl4: [4]f32, aw, ah: f32) -> (w4: [4]f32) {
    abase := [4]f32{ah, aw, ah, aw}
    for i in 0 ..< 4 {
        switch bi.wkind[i] {
        case .Number: w4[i] = bi.width[i] * bw[i] // número PURO = múltiplo da border-width
        case .Len:    w4[i] = bi.width[i]
        case .Pct:    w4[i] = abase[i] * bi.width[i] / 100
        case .Auto:   w4[i] = sl4[i]              // o tamanho intrínseco da fatia
        }
    }
    // §6.3: se os lados opostos somam mais que a área, TODOS encolhem no mesmo fator
    fh: f32 = (w4[3] + w4[1]) > 0 ? aw / (w4[3] + w4[1]) : 1
    fv: f32 = (w4[0] + w4[2]) > 0 ? ah / (w4[0] + w4[2]) : 1
    if f := min(fh, fv); f < 1 do for i in 0 ..< 4 do w4[i] *= f
    return
}

@(private="file")
paint_border_image :: proc(dl: ^im.DrawList, screen: im.Vec2, b: ^Box, cols: [4]u32, eff, radius: f32, flags: im.DrawFlags) {
    bi := b.bimg
    // área = border-box + outset (número = múltiplo da border-width do lado)
    o: [4]f32
    for i in 0 ..< 4 do o[i] = bi.outset_num[i] ? bi.outset[i] * b.border_w[i] : bi.outset[i]
    ax0 := screen.x - o[3];        ay0 := screen.y - o[0]
    ax1 := screen.x + b.w + o[1];  ay1 := screen.y + b.h + o[2]
    aw, ah := ax1 - ax0, ay1 - ay0
    if aw <= 0 || ah <= 0 do return

    if bi.grad != "" {
        g, ok := csspkg.parse_gradient(bi.grad)
        if !ok || !g.active {
            paint_border(dl, screen, b, cols, eff, radius, flags)
            return
        }
        // ⚠️ APROXIMAÇÃO ASSUMIDA: o gradiente NÃO é fatiado em 9 — ele é pintado
        // sobre a área inteira e recortado ao ANEL. Para `slice:1` (o idioma
        // `border-image: linear-gradient(...) 1`, que é o uso dominante) isso dá o
        // mesmo resultado, porque cada faixa de 1px do gradiente esticada É a
        // faixa correspondente do gradiente inteiro. Com fatia GRANDE diverge.
        w4 := bimg_widths(bi, b.border_w, {0, 0, 0, 0}, aw, ah)
        strips := [4][4]f32{
            {ax0, ay0, ax1, ay0 + w4[0]},          // topo
            {ax0, ay1 - w4[2], ax1, ay1},          // base
            {ax0, ay0 + w4[0], ax0 + w4[3], ay1 - w4[2]}, // esquerda
            {ax1 - w4[1], ay0 + w4[0], ax1, ay1 - w4[2]}, // direita
        }
        for s in strips {
            if s[2] <= s[0] || s[3] <= s[1] do continue
            im.DrawList_PushClipRect(dl, {s[0], s[1]}, {s[2], s[3]}, true)
            paint_gradient(dl, {ax0, ay0}, {ax1, ay1}, g, eff)
            im.DrawList_PopClipRect(dl)
        }
        return
    }

    img := image_get(bi.src)
    if img.state != .Ready || img.w <= 0 || img.h <= 0 {
        paint_border(dl, screen, b, cols, eff, radius, flags) // baixando ou falhou
        return
    }
    iw, ih := f32(img.w), f32(img.h)

    // fatias em PIXELS da imagem (t r b l); % é relativo ao lado da IMAGEM
    sl4: [4]f32
    ibase := [4]f32{ih, iw, ih, iw}
    for i in 0 ..< 4 {
        sl4[i] = bi.slice_pct[i] ? ibase[i] * bi.slice[i] / 100 : bi.slice[i]
        sl4[i] = clamp(sl4[i], 0, ibase[i])
    }
    if sl4[0] + sl4[2] > ih { f := ih / (sl4[0] + sl4[2]); sl4[0] *= f; sl4[2] *= f }
    if sl4[3] + sl4[1] > iw { f := iw / (sl4[3] + sl4[1]); sl4[3] *= f; sl4[1] *= f }

    w4 := bimg_widths(bi, b.border_w, sl4, aw, ah)
    wt, wr, wb, wl := w4[0], w4[1], w4[2], w4[3]
    st, sr, sb, sq := sl4[0], sl4[1], sl4[2], sl4[3]

    tex  := im.TextureID(uintptr(img.tex))
    tint := imgui_mul_alpha(0xFFFFFFFF, eff)
    Q :: bimg_quad_clip

    // 4 cantos: sempre ESTICADOS na caixa do canto (spec)
    Q(dl, tex, tint, iw, ih, ax0, ay0, ax0 + wl, ay0 + wt, 0, 0, sq, st,                  ax0, ay0, ax0 + wl, ay0 + wt)
    Q(dl, tex, tint, iw, ih, ax1 - wr, ay0, ax1, ay0 + wt, iw - sr, 0, iw, st,            ax1 - wr, ay0, ax1, ay0 + wt)
    Q(dl, tex, tint, iw, ih, ax0, ay1 - wb, ax0 + wl, ay1, 0, ih - sb, sq, ih,            ax0, ay1 - wb, ax0 + wl, ay1)
    Q(dl, tex, tint, iw, ih, ax1 - wr, ay1 - wb, ax1, ay1, iw - sr, ih - sb, iw, ih,      ax1 - wr, ay1 - wb, ax1, ay1)

    // 4 bordas
    bimg_edge(dl, tex, tint, iw, ih, ax0 + wl, ay0, ax1 - wr, ay0 + wt, sq, 0, iw - sr, st,           bi.repeat[0], true)
    bimg_edge(dl, tex, tint, iw, ih, ax0 + wl, ay1 - wb, ax1 - wr, ay1, sq, ih - sb, iw - sr, ih,     bi.repeat[0], true)
    bimg_edge(dl, tex, tint, iw, ih, ax0, ay0 + wt, ax0 + wl, ay1 - wb, 0, st, sq, ih - sb,           bi.repeat[1], false)
    bimg_edge(dl, tex, tint, iw, ih, ax1 - wr, ay0 + wt, ax1, ay1 - wb, iw - sr, st, iw, ih - sb,     bi.repeat[1], false)

    // miolo: só com `fill` (por isso o zero-value não pode ser "preenche")
    if bi.fill {
        bimg_edge(dl, tex, tint, iw, ih, ax0 + wl, ay0 + wt, ax1 - wr, ay1 - wb,
            sq, st, iw - sr, ih - sb, bi.repeat[0], true)
    }
}

@(private="file") RESIZE_MIN :: f32(12)

// Alça de `resize` (css-ui §5.2): desenha as 3 diagonais do canto inferior
// direito e trata o arraste. O tamanho vai p/ `g_resize` (keyed pelo NÓ) e a
// varredura no topo do layout_box o aplica na passada SEGUINTE — o paint vem
// depois do layout no frame, então o arraste aparece um frame atrás do mouse
// (imperceptível a 60fps, e o tamanho final é sempre o do mouse ao soltar).
// ⚠️ só o canto inferior direito (é o único que os navegadores expõem em ltr).
@(private="file")
paint_resize_grip :: proc(pt: ^Painter, b: ^Box, screen: im.Vec2, eff: f32) {
    gs := min(RESIZE_GRIP, min(b.w, b.h))
    if gs < 5 do return // caixa minúscula: não haveria o que agarrar
    x1, y1 := screen.x + b.w, screen.y + b.h
    io := im.GetIO()

    dragging := g_resize_drag.active && g_resize_drag.node == b.node
    in_grip  := x_mouse_rect(b, {x1 - gs, y1 - gs}, {x1, y1})
    pointer:=x_widget_point(b,io.MousePos)

    if in_grip || dragging {
        switch b.resize {
        case .Both:       im.SetMouseCursor(.ResizeNWSE)
        case .Horizontal: im.SetMouseCursor(.ResizeEW)
        case .Vertical:   im.SetMouseCursor(.ResizeNS)
        case .None:
        }
    }

    // Início do arraste: snapshota o tamanho ATUAL no espaço do box-sizing (o
    // mesmo em que `width` é escrito), p/ o delta do mouse somar direto.
    // Sem guarda de "já tem arraste": o paint é PAI-primeiro, então o descendente
    // sobrescreve na mesma pressão do mouse e a alça mais INTERNA vence, como
    // nos navegadores. (IsMouseClicked só é true no frame da pressão.)
    if in_grip && im.IsMouseClicked(.Left) {
        ex_w := b.padding[3] + b.padding[1] + b.border_w[3] + b.border_w[1]
        ex_h := b.padding[0] + b.padding[2] + b.border_w[0] + b.border_w[2]
        w0 := b.box_sizing == .Border ? b.w : b.w - ex_w
        h0 := b.box_sizing == .Border ? b.h : b.h - ex_h
        g_resize_drag = {node = b.node, active = true, mx = pointer.x, my = pointer.y, w0 = w0, h0 = h0}
        dragging = true
    }
    if dragging {
        if im.IsMouseDown(.Left) {
            st := g_resize[b.node] // ausente = zero; quem manda são os has_* abaixo
            if b.resize == .Both || b.resize == .Horizontal {
                st.w = max(RESIZE_MIN, g_resize_drag.w0 + (pointer.x - g_resize_drag.mx)); st.has_w = true
            }
            if b.resize == .Both || b.resize == .Vertical {
                st.h = max(RESIZE_MIN, g_resize_drag.h0 + (pointer.y - g_resize_drag.my)); st.has_h = true
            }
            g_resize[b.node] = st
        } else {
            g_resize_drag = {} // soltou o botão
        }
    }

    // Desenho: 3 diagonais paralelas encolhendo rumo ao canto (o mesmo padrão de
    // Chrome/Firefox). A spec não define aparência; cinza translúcido funciona
    // sobre fundo claro e escuro. 0x70 no byte alto = alpha (convenção do motor).
    lc := col_o(0x70808080, eff)
    for k in ([?]f32{3, 6, 9}) {
        if k + 3 > gs do break
        emit(pt, PC_Line{{x1 - 2, y1 - 2 - k}, {x1 - 2 - k, y1 - 2}, lc})
    }
}

// Only queried for a non-identity transform that has no layer yet.
@(private="file")
paint_subtree_has_overflow_clip :: proc(b: ^Box) -> bool {
    if b.overflow_hidden do return true
    for child in b.children do if paint_subtree_has_overflow_clip(child) do return true
    for it in b.inlines do if it.box != nil && paint_subtree_has_overflow_clip(it.box) do return true
    return false
}

emit_overflow_clip :: proc(pt: ^Painter, b: ^Box, lo, hi: im.Vec2, rounded: bool) {
    if rounded {
        r := image_rounding(b.w, b.h, b.border_radius, b.border_radius_pct, b.border_w)
        emit(pt, PC_RoundClipBegin{rawptr(b.node), lo, hi, r})
    }
    emit(pt, PC_PushClip{lo, hi})
}

end_overflow_clip :: proc(pt: ^Painter, rounded: bool) {
    emit(pt, PC_PopClip{})
    if rounded do emit(pt, PC_LayerEnd{})
}

rounded_overflow_clip :: proc(b: ^Box) -> bool {
    if !b.overflow_hidden || !b.ovf_clip_x || !b.ovf_clip_y || g_renderer == nil do return false
    r := image_rounding(b.w, b.h, b.border_radius, b.border_radius_pct, b.border_w)
    return image_has_rounding(r)
}

paint_box :: proc(pt: ^Painter, s: ^State, b: ^Box, ox, oy: f32, opa: f32 = 1.0, in_xform := false, scope: ^Stacking_Scope = nil, stacked := false, abs_origin: im.Vec2 = {}) {
    if scope != nil && !stacked && b in scope.deferred do return
    if b.inline_parent_effect != nil {
        effect := b.inline_parent_effect
        b.inline_parent_effect = nil
        defer b.inline_parent_effect = effect
        paint_inline_absolute(pt, s, b, effect, ox, oy, opa, in_xform, scope, stacked, abs_origin)
        return
    }
    when PAINTPROF {
        pp_saved := g_pp_child; g_pp_child = 0
        pp_t0 := time.tick_now(); pp_ts := pp_t0
        g_pp.calls += 1
        defer {
            incl := time.duration_milliseconds(time.tick_since(pp_t0))
            g_pp.self_ms += incl - g_pp_child
            g_pp_child = pp_saved + incl
        }
        pp_mark :: proc(k: int, ts: ^time.Tick) {
            g_pp.seg[k] += time.duration_milliseconds(time.tick_since(ts^)); ts^ = time.tick_now()
        }
    }
    if scope == nil && !stacked {
        x_geometry_tree(b, ox, oy, im.GetScrollX(), im.GetScrollY())
    }
    when PAINTPROF { pp_mark(0, &pp_ts) }
    keep_depth:=g_x_keep_depth
    saved_keep:=g_x_keep_depth
    g_x_keep_depth=x_preserves(b) || b.perspective>0
    defer g_x_keep_depth=saved_keep
    local_scope: Stacking_Scope
    active_scope := scope
    owns_scope := scope == nil || stacking_context_at(b, ox, oy)
    if owns_scope {
        local_scope.deferred = make(map[^Box]bool, context.temp_allocator)
        local_scope.entries = make([dynamic]Stacking_Entry, context.temp_allocator)
        local_scope.clips = make([dynamic]Stacking_Clip, context.temp_allocator)
        active_scope = &local_scope
    }
    defer if owns_scope {
        delete(local_scope.deferred); delete(local_scope.entries); delete(local_scope.clips)
    }
    // opacidade efetiva = herdada × própria
    eff := opa * b.opacity
    // Totalmente transparente: não pinta — EXCETO se há transition (o alvo pode
    // estar subindo de 0, ex.: fade-in de opacity:0 rumo a 1; o bloco de transição
    // abaixo cria/atualiza o estado e recalcula eff). Sem transition, sai já.
    // Sonda de PINTURA (`-define:PAINTPROBE=true`): "a caixa existe no dump mas não
    // aparece na tela" tem 3 causas indistinguíveis de fora — não foi pintada,
    // foi pintada fora da tela, ou foi coberta. Isto imprime a decisão.
    when #config(PAINTPROBE, false) {
        if eff <= 0 && !(trans_any(b.trans) && b.node != nil) {
            fmt.eprintfln("[paint] PULADA opa=%.2f prop=%.2f %s", opa, b.opacity, diag_desc(b))
        }
    }
    if eff <= 0 && len(b.animations) == 0 && !(trans_any(b.trans) && b.node != nil) do return

    // Ordem de pintura desta caixa, tirada ANTES de pintar os filhos (eles pegam
    // números maiores e por isso vencem o pai no hit-test). Ver g_hit_seq.
    my_paint_seq := g_hit_seq
    g_hit_seq += 1

    // o offset de relative deste box vale p/ ele e a subárvore
    ox2 := ox + b.rel_dx
    oy2 := oy + b.rel_dy
    adx, ady := animation_translation_delta(b)
    ox2 += adx; oy2 += ady

    // position:fixed/sticky — o conteúdo é pintado dentro de um child que rola
    // (GetCursorScreenPos aplica -scroll), então devolvemos o scroll ao y.
    // Fixed: pinado ao viewport. Sticky: gruda em top:N quando o topo passaria
    // dele, limitado à base do bloco contendor (sticky_max_dy, do layout).
    if b.pos == .Fixed {
        ox2 += im.GetScrollX() // a página também rola na horizontal
        oy2 += im.GetScrollY()
    } else if b.pos == .Sticky && b.inset_has[0] && !b.inset_pct[0] {
        dy := im.GetScrollY() + b.inset[0] - (b.y + oy2)
        if dy > 0 do oy2 += min(dy, b.sticky_max_dy)
    }

    im.SetCursorPos({b.x + ox2, b.y + oy2})
    screen := im.GetCursorScreenPos()
    when #config(PAINTPROBE, false) {
        fmt.eprintfln("[paint] seq=%d eff=%.2f screen=(%.0f,%.0f) %s", my_paint_seq, eff, screen.x, screen.y, diag_desc(b))
    }
    // S2: esta caixa foi visitada; o border-box dela intersecta o clip corrente?
    // A razão entre as duas contagens é o TETO do ganho de um culling por
    // viewport — se der ~1:1 em site real, não se escreve o cull.
    when CULLPROBE {
        g_cullprof.visitadas += 1
        {
            cdl   := im.GetWindowDrawList()
            cmin  := im.DrawList_GetClipRectMin(cdl)
            cmax  := im.DrawList_GetClipRectMax(cdl)
            if screen.x < cmax.x && screen.x + b.w > cmin.x &&
               screen.y < cmax.y && screen.y + b.h > cmin.y {
                g_cullprof.visiveis += 1
            }
        }
    }
    // insets do fundo por lado (o fundo fica dentro das bordas)
    bwt, bwr, bwb, bwl := b.border_w[0], b.border_w[1], b.border_w[2], b.border_w[3]

    // mouse sobre a caixa? (para :hover e cursor). A caixa mais interna pintada
    // por último vence (SetMouseCursor é last-wins no frame).
    b.x_view_origin={screen.x-b.x-ox2+im.GetScrollX(),screen.y-b.y-oy2+im.GetScrollY()}
    b.x_paint_origin=screen
    over := x_mouse_over(b, screen, ox2, oy2) && !b.pe_none
    b.x_hovered = over
    if over && b.cursor != .Auto do im.SetMouseCursor(cursor_to_imgui(b.cursor))
    when PAINTPROF { pp_mark(1, &pp_ts) }

    // scroll de elemento: a roda sobre um container rolável ajusta seu scroll e é
    // CONSUMIDA (zera io.MouseWheel), evitando que a página role junto. Paint é
    // pai-primeiro, então o container externo captura antes (aninhados: externo vence).
    // Rolagem automática do meio (autoscroll.odin): no aperto, o rolável mais
    // interno sob o cursor vira o alvo (pai-primeiro ⇒ o último a gravar é o de
    // dentro); nos frames seguintes, o alvo — achado por COMPARAÇÃO de ponteiro,
    // o nó nunca é derreferenciado por aqui — recebe o deslocamento do frame.
    if b.overflow_scroll && (b.scroll_max > 0 || b.scroll_max_x > 0) && b.node != nil {
        if over && im.IsMouseClicked(.Middle) {
            g_aux_scroller = rawptr(b.node)
            g_aux_axes = {b.scroll_max_x > 0, b.scroll_max > 0}
        }
        if g_autoscroll_target != nil && rawptr(b.node) == g_autoscroll_target {
            g_autoscroll_hit = true
            wheel_axis_stop(&b.wheel[0]); wheel_axis_stop(&b.wheel[1])
            b.scroll_x = clamp(b.scroll_x + g_autoscroll_d.x, 0, b.scroll_max_x)
            b.scroll_y = clamp(b.scroll_y + g_autoscroll_d.y, 0, b.scroll_max)
        }
    }
    if b.overflow_scroll {
        io := im.GetIO()
        // Consome a roda se o container REALMENTE rolou; no limite (não moveu),
        // overscroll-behavior:auto (default) DEIXA encadear p/ a página, enquanto
        // contain/none consome mesmo assim (não encadeia). Cada eixo por si:
        // a roda horizontal (MouseWheelH; Shift+roda já chega convertida — ver
        // wheel_shift_to_h) não é consumida por quem só rola no Y.
        dy := over && b.scroll_max > 0 ? -io.MouseWheel * 40 : 0
        dx := over && b.scroll_max_x > 0 ? -io.MouseWheelH * 40 : 0
        vy, cy := wheel_container_step(&b.wheel[1], b.scroll_y, b.scroll_max, dy, io.DeltaTime, b.overscroll_contain)
        vx, cx := wheel_container_step(&b.wheel[0], b.scroll_x, b.scroll_max_x, dx, io.DeltaTime, b.overscroll_contain)
        b.scroll_y = vy; b.scroll_x = vx
        if cy do io.MouseWheel = 0
        if cx do io.MouseWheelH = 0
    }

    // ── Transições genéricas ──────────────────────────────────────────────────
    // Alvo de cada prop de pintura = valor a exibir AGORA (base, ou override de
    // :hover quando o mouse está sobre). O alvo também muda quando um re-layout
    // troca o valor base (ex.: classe alternada por JS) — a transition anima em
    // ambos os casos. Sem transition (dur=0) ou sem nó, usa o alvo instantâneo.
    hovering := b.hover.active && over
    eff_shadows := b.shadows
    eff_shadow_n := b.shadow_n
    if hovering && b.hover.has_shadow {
        eff_shadows = b.hover.shadows; eff_shadow_n = b.hover.shadow_n
    }
    tgt_bg      := (b.hover.has_bg      && hovering) ? b.hover.bg      : b.bg
    tgt_bg_has  := b.hover.has_bg && hovering ? true : b.has_bg
    tgt_border  := (b.hover.has_border_c && hovering) ? b.hover.border_c : b.border_c[0]
    tgt_opacity := (b.hover.has_opacity && hovering) ? b.hover.opacity : b.opacity
    tgt_rot     := (b.hover.has_transform && hovering) ? b.hover.rot : b.transform_rot
    tgt_sx      := (b.hover.has_transform && hovering) ? b.hover.sx  : b.transform_sx
    tgt_sy      := (b.hover.has_transform && hovering) ? b.hover.sy  : b.transform_sy
    tgt_hoverp  : f32 = (b.hover.has_color && hovering) ? 1 : 0

    eff_bg     := b.bg;       eff_has_bg := b.has_bg
    eff_border := b.border_c  // cores por lado (t r b l)
    hover_t: f32 = 0 // blend da cor do texto rumo ao :hover (p/ paint_inline)
    eff_rot := b.transform_rot
    eff_sx  := b.transform_sx
    eff_sy  := b.transform_sy

    // Transição POR CANAL: `transition-property` decide quais destes cinco
    // interpolam; o que não está na lista salta direto para o alvo, exatamente
    // como quando não havia transição nenhuma (é o mesmo código do `else`).
    if trans_any(b.trans) && b.node != nil {
        dt := im.GetIO().DeltaTime
        if b.node not_in g_trans do g_trans[b.node] = {}
        st := &g_trans[b.node]
        init := !st.init; st.init = true

        if b.trans[.Bg].on {
            eff_bg     = trans_step_c(&st.bg, tgt_bg, b.trans[.Bg], dt, init)
            eff_has_bg = tgt_bg_has || (st.bg.prog < 1) // ainda desvanecendo o fundo anterior
        } else {
            eff_bg = tgt_bg; eff_has_bg = tgt_bg_has
        }
        if b.trans[.Border].on {
            // ⚠️ animar borda COLAPSA os 4 lados numa cor só (o canal é único).
            // Sem transição de borda os lados são preservados — por isso os dois
            // ramos são diferentes, e não um `if` em volta do valor.
            bc := trans_step_c(&st.border, tgt_border, b.trans[.Border], dt, init)
            for s in 0 ..< 4 do eff_border[s] = bc
        } else {
            for s in 0 ..< 4 do if b.hover.has_border_c && hovering do eff_border[s] = tgt_border
        }
        eff = opa * (b.trans[.Opacity].on ? trans_step_f(&st.opacity, tgt_opacity, b.trans[.Opacity], dt, init) : tgt_opacity)
        if b.trans[.Transform].on {
            eff_rot = trans_step_f(&st.rot, tgt_rot, b.trans[.Transform], dt, init)
            eff_sx  = trans_step_f(&st.sx,  tgt_sx,  b.trans[.Transform], dt, init)
            eff_sy  = trans_step_f(&st.sy,  tgt_sy,  b.trans[.Transform], dt, init)
        } else {
            eff_rot = tgt_rot; eff_sx = tgt_sx; eff_sy = tgt_sy
        }
        hover_t = (b.trans[.Color].on && b.hover.has_color) ? trans_step_f(&st.hoverp, tgt_hoverp, b.trans[.Color], dt, init) : tgt_hoverp
    } else {
        // instantâneo (sem transition): aplica o alvo direto
        eff_bg = tgt_bg; eff_has_bg = tgt_bg_has
        for s in 0 ..< 4 do if b.hover.has_border_c && hovering do eff_border[s] = tgt_border
        eff = opa * tgt_opacity
        eff_rot = tgt_rot; eff_sx = tgt_sx; eff_sy = tgt_sy
        hover_t = tgt_hoverp
    }

    // animation/@keyframes: avança o relógio e sobrepõe as props animadas.
    anim_col: u32; anim_col_on := false
    for &player in b.animations {
        if !player.anim.active do continue
        ev := eval_anim(&player.anim, player.elapsed)
        if ev.has_op    do eff = opa * ev.op
        if ev.has_bg    { eff_bg = ev.bg; eff_has_bg = true }
        if ev.has_col   { anim_col = ev.col; anim_col_on = true }
        if ev.has_rot   do eff_rot = ev.rot
        if ev.has_scale { eff_sx = ev.sx; eff_sy = ev.sy }
    }

    when PAINTPROF { pp_mark(2, &pp_ts) }
    target_x:=b.xform
    if hovering && b.hover.has_transform do target_x=b.hover.xform
    full:=x_resolve(target_x,b.w,b.h)
    if trans_any(b.trans) && b.node!=nil {
        st:=&g_trans[b.node]
        full=x_step(&st.xform,target_x,b.trans[.Transform],im.GetIO().DeltaTime,b.w,b.h)
    }
    for &player in b.animations {
        if !player.anim.active do continue
        ev:=eval_anim(&player.anim,player.elapsed,b.w,b.h)
        if ev.has_xform do full=ev.xform
    }
    if b.motion_rotation!=0 do full=x_rotation({0,0,1},b.motion_rotation)*full
    use_full:=b.xform!=nil || (hovering && b.hover.has_transform) || len(b.animations)>0 || b.trans[.Transform].on || b.has_offset_path || x_preserves(b) || b.perspective>0
    base_tx,base_ty:=x_box_translation(b)
    baked_tx,baked_ty:=base_tx+adx,base_ty+ady
    if use_full {
        dx,dy:=full[0,3]-baked_tx,full[1,3]-baked_ty
        ox2+=dx; oy2+=dy; screen.x+=dx; screen.y+=dy
        baked_tx=full[0,3]; baked_ty=full[1,3]
    }
    b.x_paint_origin=screen
    pivot_x:=screen.x-baked_tx+b.w*b.transform_ox+b.transform_opx
    pivot_y:=screen.y-baked_ty+b.h*b.transform_oy+b.transform_opy
    project:=x_translation(pivot_x,pivot_y,b.transform_opz)*full*x_translation(-pivot_x-baked_tx,-pivot_y-baked_ty,-b.transform_opz)

    // backface-visibility. O lado é decidido AQUI, depois de transition/animação,
    // porque um giro animado troca de lado no meio do caminho — e antes de
    // qualquer `emit`, para a caixa escondida não deixar comando pela metade.
    // A saída antecipada também pula o registro de clique/link do fim da função:
    // face escondida não recebe evento, como manda a spec.
    back := box_face_back(b, hovering, eff_sx * eff_sy, tgt_sx * tgt_sy)
    if use_full {
        det:=full[0,0]*(full[1,1]*full[2,2]-full[1,2]*full[2,1])-full[0,1]*(full[1,0]*full[2,2]-full[1,2]*full[2,0])+full[0,2]*(full[1,0]*full[2,1]-full[1,1]*full[2,0])
        cof:=full[0,0]*full[1,1]-full[0,1]*full[1,0]
        back=det!=0 && (cof<0)!=(det<0)
    }
    if b.in_p3d do back = back != g_p3d_back
    if back && b.backface_hidden do return
    // preserve-3d: os filhos compõem o lado deles com o nosso. Sem ele o
    // conteúdo é ACHATADO no nosso plano e cada filho responde só por si.
    p3d_salvo := g_p3d_back
    g_p3d_back = b.preserve_3d && back
    defer g_p3d_back = p3d_salvo

    // transform rotate/scale: aplicado aos vértices da subárvore no fim do paint.
    // Matriz linear 2×2 a aplicar: skew/matrix usam xf_* (estáticos); senão deriva
    // de rot/scale efetivos (permite transition/animação animarem rotate/scale).
    // rot+scale: p' = R·S·(p−C) → [cos·sx, −sin·sy; sin·sx, cos·sy].
    xa, xb, xc, xd: f32
    if b.has_xform_matrix {
        xa, xb, xc, xd = b.xf_a, b.xf_b, b.xf_c, b.xf_d
    } else {
        cs, sn := f32(math.cos(eff_rot)), f32(math.sin(eff_rot))
        xa = cs * eff_sx; xb = -sn * eff_sy; xc = sn * eff_sx; xd = cs * eff_sy
    }
    // Gatilha se a matriz não é identidade (estático OU animado).
    do_xform := use_full || keep_depth || xa != 1 || xb != 0 || xc != 0 || xd != 1

    // group-opacity: se a opacidade PRÓPRIA (own_a = eff/opa) < 1 e o box tem
    // filhos (onde o double-darken de sobreposição apareceria), embrulha a
    // subárvore numa LAYER — o conteúdo é desenhado OPACO (eff←opa) e o dimming
    // vem do composite da textura a own_a (replay_paint/composite_layer). Sem
    // filhos (folha) ou sem renderer, mantém o baking antigo (eff = opa·own_a).
    own_a := opa > 0.0001 ? eff / opa : b.opacity
    // layer quando: (opacidade PRÓPRIA<1 com filhos, onde o double-darken de
    // sobreposição apareceria) OU (mix-blend-mode≠normal, que blenda o elemento
    // com o backdrop — vale até p/ folhas).
    // isolation:isolate força um grupo de composição (stacking context): os
    // mix-blend-mode dos descendentes compõem DENTRO do grupo, não com o backdrop
    // da página. Só faz sentido com filhos (senão o grupo é vazio).
    // clip-path exige layer: o clip do ImGui é RETANGULAR, então a forma é aplicada
    // como máscara alpha na CPU sobre a textura da layer (mesmo caminho dos filtros).
    want_layer := (own_a < 1 && (len(b.children) > 0 || len(b.inlines) > 0)) || b.blend_mode != .Normal || b.n_filters > 0 || (b.isolate && (len(b.children) > 0 || len(b.inlines) > 0)) || b.clip_path.kind != .None || b.mask_grad.active || b.mask_image.url != ""
    // Scissor rectangles do not follow transform_vertices. Rasterize local clips
    // before transforming the group, so a scaled/rotated card and its contents
    // share the same transformed edge (including clips in nested wrappers).
    if !want_layer && do_xform do want_layer = paint_subtree_has_overflow_clip(b)
    do_layer := want_layer && g_renderer != nil
    if do_layer {
        eff = opa // conteúdo desenhado opaco na layer; o composite aplica own_a/blend
    }
    when PAINTPROF { pp_mark(3, &pp_ts) }

    // backdrop-filter: emitido ANTES de tudo que o elemento pinta (fundo/borda/
    // conteúdo/layer) — no replay, o `dl` já contém tudo ATRÁS do elemento (ordem
    // de pintura), que é exatamente o backdrop a filtrar. Fica FORA de qualquer
    // layer do próprio elemento (é o fundo, não o conteúdo).
    if b.n_backdrop > 0 && !b.invisible {
        br, _ := corner_rounding(b)
        emit(pt, PC_BackdropFilter{screen.x, screen.y, screen.x + b.w, screen.y + b.h, br, b.backdrop_filters, b.n_backdrop})
    }

    // marca o início do range de vértices desta subárvore (o vtx0 real é lido
    // no replay, quando os vértices existem); PC_XformEnd fecha o range.
    if do_xform do emit(pt, PC_XformBegin{})
    // backdrop capturado no RECORD (g_bg_behind = fundo opaco do ancestral mais
    // próximo): os blends de kernel CPU (overlay/hard-light) não podem ler o
    // framebuffer em construção, então blendam contra esta cor sólida.
    if do_layer {
        // Prova de contenção do bbox de subárvore (só em build de sonda). O par
        // (previsto, real) é comparado em composite_layer, que já calcula o bbox
        // EXATO dos vértices. `screen` corresponde ao ponto local
        // (b.x + rel_dx, b.y + rel_dy) do espaço em que sub_* foi calculado, então
        // a conversão é uma translação. A fila é consumida na MESMA ordem em que é
        // produzida (record e replay percorrem os comandos em profundidade).
        when SUBBBOX {
            // Duas conversões DIFERENTES, e é exatamente aí que estava o erro de
            // desenho anterior:
            //  • em fluxo: `screen` corresponde ao ponto local (x+rel_dx, y+rel_dy)
            //    do espaço de sub_* ⇒ translação por (screen − esse ponto).
            //  • fora de fluxo: está em espaço GLOBAL (offset 0,0). A origem
            //    global em tela é `screen − (b.x + ox2, b.y + oy2)`.
            lox := screen.x - (b.x + b.rel_dx)
            loy := screen.y - (b.y + b.rel_dy)
            px0 := b.sub_x0 + lox; py0 := b.sub_y0 + loy
            px1 := b.sub_x1 + lox; py1 := b.sub_y1 + loy
            if b.has_abs {
                gox := screen.x - (b.x + ox2)
                goy := screen.y - (b.y + oy2)
                px0 = min(px0, b.abs_x0 + gox); py0 = min(py0, b.abs_y0 + goy)
                px1 = max(px1, b.abs_x1 + gox); py1 = max(py1, b.abs_y1 + goy)
            }
            append(&g_pred_bbox, Pred_BBox{px0, py0, px1, py1, b.sub_safe, b.has_abs, len(b.children), rawptr(b.node), diag_desc(b),
                b.n_filters, b.n_filters > 0 ? b.filters[0].amount : 0, b.w, b.grad.active, b.bg_img != "", b.bg_fixed, len(b.bg_extra)})
        }
        b.mask_image = mask_for_box(b)
        emit(pt, PC_LayerBegin{own_a, b.blend_mode, b.filters, b.n_filters, rawptr(b.node), g_bg_behind, b.clip_path, b.mask_grad, screen.x, screen.y, b.w, b.h, &b.mask_image})
    }

    // raio por canto: um único `radius` (o maior) + flags de quais cantos
    // arredondam — casa exatamente o caso comum (cantos arredondados com o
    // mesmo raio, outros retos); raios distintos entre si são aproximados.
    radius, corner_flags := corner_rounding(b)

    // empty-cells:hide — célula de tabela SEM conteúdo (sem filhos e sem itens
    // inline) não pinta fundo nem borda.
    hide_empty := b.is_table_cell && b.empty_cells_hide && len(b.children) == 0 && len(b.inlines) == 0

    // área de pintura do fundo conforme background-clip. Default border-box:
    // o fundo preenche a caixa TODA (a borda, desenhada depois, cobre a parte
    // dela quando opaca — mas bordas transparentes/pontilhadas deixam ver o
    // fundo). padding-box recua pela borda; content-box, pela borda+padding.
    // b.padding = [topo, dir, base, esq].
    //
    // Fica FORA do `if !b.invisible` porque o entalhe da curva interna (no fim,
    // depois dos filhos) mede a rampa do gradiente nesta MESMA caixa — reler a
    // geometria lá daria duas fontes de verdade para a mesma conta.
    il, it, ir, ib: f32 = 0, 0, 0, 0
    switch b.bg_clip {
    case .Border:  // sem recuo
    case .Padding: il, it, ir, ib = bwl, bwt, bwr, bwb
    case .Content:
        il = bwl + b.padding[3]; it = bwt + b.padding[0]
        ir = bwr + b.padding[1]; ib = bwb + b.padding[2]
    }
    ip0 := im.Vec2{screen.x + il, screen.y + it}
    ip1 := im.Vec2{screen.x + b.w - ir, screen.y + b.h - ib}

    // visibility:hidden — não pinta o PRÓPRIO conteúdo (fundo/borda/texto/etc.),
    // mas mantém a caixa no layout e recursa nos filhos (que podem reexibir).
    if !b.invisible {
        // box-shadow externa: desenhada ATRÁS do fundo/borda do próprio box.
        // (as inset vêm depois do fundo, por cima — ver abaixo.)
        for i := eff_shadow_n - 1; i >= 0; i -= 1 {
            if eff_shadows[i].inset do continue
            emit(pt, PC_Shadow{screen.x, screen.y, screen.x + b.w, screen.y + b.h, radius, eff_shadows[i], eff, false})
        }
        // FUNDO DO CANVAS (css-backgrounds §2.11.2): o fundo do elemento raiz (ou
        // do <body>, quando a raiz não tem) cobre a PÁGINA INTEIRA. Sem isto,
        // `html{background:#333}` com conteúdo curto deixava tudo abaixo do
        // conteúdo BRANCO, e um `body{background:linear-gradient(…)}` só pintava
        // a faixa do body.
        //
        // ⚠️ só a área de PINTURA vira o canvas — a de POSICIONAMENTO continua
        // sendo a caixa do elemento ("as if they were painted for that element
        // alone"). Como `background-repeat` é `repeat` por padrão, o gradiente/
        // imagem LADRILHA pelo canvas: é o que o Chrome faz (verificado lado a
        // lado), não uma rampa esticada. A origem da PÁGINA em coords de tela é
        // (screen − b.x/b.y) — a mesma conversão do background-attachment:fixed.
        cv0, cv1 := ip0, ip1
        is_canvas := b.bg_canvas && !in_xform && !b.has_transform && !b.has_xform_matrix
        if is_canvas {
            page_ox := screen.x - b.x
            page_oy := screen.y - b.y
            vw, vh := im.GetIO().DisplaySize.x, im.GetIO().DisplaySize.y
            cv0 = im.Vec2{page_ox, page_oy}
            cv1 = im.Vec2{page_ox + max(b.x + b.w, vw), page_oy + max(b.y + b.h, vh)}
        }
        // ORDEM DE PINTURA DO FUNDO (css-backgrounds §3): a cor fica EMBAIXO de
        // todas as camadas; a PRIMEIRA camada da lista fica por CIMA. Por isso
        // `bg_extra` (camadas 1..N-1) é percorrido de trás pra frente e só
        // depois vem a camada 0 (b.grad / b.bg_img).
        // ⚠️ antes a cor era `else if` do gradiente — um `background-color` sob
        // um gradiente TRANSLÚCIDO não aparecia. Com gradiente opaco dá no mesmo.
        if eff_has_bg && !hide_empty {
            // a COR não tem posicionamento: preenche direto a área de pintura
            // (a caixa, ou o canvas inteiro quando este elemento é a fonte dele)
            emit(pt, PC_RectFilled{cv0, cv1, col_o(eff_bg, eff), is_canvas ? 0 : radius, corner_flags})
        }
        for i := len(b.bg_extra) - 1; i >= 0; i -= 1 {
            lay := b.bg_extra[i]
            if lay.grad.active {
                emit_grad_bg(pt, lay.grad, b, screen, ip0, ip1, cv0, cv1, is_canvas, lay.repeat, radius, eff, in_xform)
            } else if lay.img != "" {
                op0, op1 := bg_origin_box(b, screen, bwl, bwt, bwr, bwb, in_xform)
                emit_bg_image(pt, op0, op1, cv0, cv1, b, eff, i) // clip = canvas quando é a fonte
            }
        }
        // `background-clip: text`: o gradiente NÃO pinta a caixa — ele colore os
        // glifos (paint_inline sombreia os vértices do texto).
        if b.grad.active && !b.grad_clip_text {
            emit_grad_bg(pt, b.grad, b, screen, ip0, ip1, cv0, cv1, is_canvas, b.bg_repeat, radius, eff, in_xform)
        }
        if b.bg_img != "" {
            op0, op1 := bg_origin_box(b, screen, bwl, bwt, bwr, bwb, in_xform)
            emit_bg_image(pt, op0, op1, cv0, cv1, b, eff, -1) // -1 = camada 0
        }
        // box-shadow inset: por cima do fundo, recortada à caixa, sob a borda.
        for i := eff_shadow_n - 1; i >= 0; i -= 1 {
            if !eff_shadows[i].inset do continue
            emit(pt, PC_Shadow{screen.x, screen.y, screen.x + b.w, screen.y + b.h, radius, eff_shadows[i], eff, true})
        }
        if b.has_border && !hide_empty {
            if b.bimg.active do emit(pt, PC_BorderImage{screen, b, eff_border, eff, radius, corner_flags})
            else             do emit(pt, PC_Border{screen, b, eff_border, eff, radius, corner_flags})
        }
        // marca de checkbox (✓) / ponto de radio, quando marcado. appearance:none
        // suprime a marca nativa (o autor desenha o próprio indicador via :checked).
        if (b.ctrl == .Checkbox || b.ctrl == .Radio) && !b.appearance_none {
            emit(pt, PC_ControlMark{screen, b, radius, eff})
        }
        // outline: anel FORA da caixa (borda + offset), sem afetar layout. Sem
        // raio, 4 retângulos preenchidos (sem franja de AA — pixel-exato); com
        // raio, traço do AddRect centrado no caminho expandido.
        if b.outline_w > 0 {
            ow := b.outline_w
            oc := col_o(b.outline_c, eff)
            if radius > 0 {
                mid := b.outline_off + ow / 2
                emit(pt, PC_Rect{{screen.x - mid, screen.y - mid},
                    {screen.x + b.w + mid, screen.y + b.h + mid}, oc, radius + mid, {}, ow})
            } else {
                x0 := screen.x - b.outline_off - ow
                y0 := screen.y - b.outline_off - ow
                x1 := screen.x + b.w + b.outline_off + ow
                y1 := screen.y + b.h + b.outline_off + ow
                emit(pt, PC_RectFilled{{x0, y0}, {x1, y0 + ow}, oc, 0, {}})           // topo
                emit(pt, PC_RectFilled{{x0, y1 - ow}, {x1, y1}, oc, 0, {}})           // base
                emit(pt, PC_RectFilled{{x0, y0 + ow}, {x0 + ow, y1 - ow}, oc, 0, {}}) // esquerda
                emit(pt, PC_RectFilled{{x1 - ow, y0 + ow}, {x1, y1 - ow}, oc, 0, {}}) // direita
            }
        }
    }

    when PAINTPROF { pp_mark(4, &pp_ts) }
    // campo de texto editável: coloca o InputText do ImGui sobre a caixa e sai
    // (fundo/borda já pintados; sem conteúdo inline ou filhos).
    if b.ctrl == .Text || b.ctrl == .Password || b.ctrl == .Textarea || b.ctrl == .Select {
        if !b.invisible {
            if b.ctrl == .Select do emit(pt, PC_Select{b, screen, eff})
            else                 do emit(pt, PC_TextInput{b, screen, eff})
            // A alça precisa ser emitida AQUI também: este ramo RETORNA antes do
            // bloco geral lá embaixo, e o <textarea> — que é o caso dominante de
            // `resize` em site real — cai justamente nele. Depois do PC_TextInput
            // p/ ficar POR CIMA do widget no replay.
            // ⚠️ achado pelo pixel: o teste de unidade já dizia resize=.Both e
            // mesmo assim nada era pintado.
            if b.resize != .None && b.node != nil && !b.pe_none {
                paint_resize_grip(pt, b, screen, eff)
            }
        }
        // fecha os ranges de layer/transform abertos acima (senão o stack do
        // replay ficaria desbalanceado neste return antecipado)
        if do_layer do emit(pt, PC_LayerEnd{})
        if do_xform {
            if use_full || keep_depth { emit(pt,PC_ProjectEnd{project,keep_depth}) } else { emit(pt,PC_XformEnd{screen.x+b.w*b.transform_ox,screen.y+b.h*b.transform_oy,xa,xb,xc,xd}) }
        }
        return
    }

    // cor atrás dos filhos: se esta caixa tem fundo sólido opaco, passa a ser ela;
    // se tem fundo TRANSLÚCIDO, compõe sobre a de trás; senão herda. Guardada p/
    // restaurar e p/ mascarar os cantos abaixo.
    //
    // ⚠️ O ramo translúcido faltava, e isso pintava CANTO BRANCO em modal: o
    // overlay `bg-black/75` de um modal não é opaco, então não entrava aqui e o
    // `g_bg_behind` continuava o default BRANCO. Quem paga é o `PC_MaskCorners`
    // abaixo — com overflow:hidden + raio nós não recortamos de verdade, pintamos
    // o entalhe do canto com ESTA cor. Resultado: um L branco em cada canto do
    // card, contra um fundo escuro. Compor o translúcido não dá a cor exata (o
    // certo seria o conteúdo real por trás), mas erra por pouco em vez de por tudo.
    behind := g_bg_behind
    if eff_has_bg && !b.grad.active {
        if (eff_bg >> 24) & 0xff == 0 {
            g_bg_behind = eff_bg                    // opaco: substitui
        } else {
            g_bg_behind = bg_over(g_bg_behind, eff_bg) // translúcido: compõe
        }
    }

    // clip POR EIXO: no eixo que não clipa, estende o retângulo p/ ±BIG (o clip
    // do ImGui é a interseção com o atual, então BIG = "sem restrição nesse eixo").
    // Ex.: overflow-x:clip clipa só a horizontal; a vertical vaza (overflow-y visible).
    // Hoisted p/ fora do `if` porque o .Block reusa o retângulo ao religar o clip
    // entre filhos posicionados que escapam e os que são recortados.
    cx0, cy0, cx1, cy1: f32
    round_clip := rounded_overflow_clip(b)
    if b.overflow_hidden {
        BIG :: f32(1e6)
        // overflow recorta na PADDING box (dentro das bordas), não na border box —
        // um filho cuja borda invade a região de borda do pai (ex.: margin negativo)
        // deve ser cortado ali (border_w = [top,right,bottom,left]).
        cx0 = b.ovf_clip_x ? screen.x + b.border_w[3] : screen.x - BIG
        cx1 = b.ovf_clip_x ? screen.x + b.w - b.border_w[1] : screen.x + b.w + BIG
        cy0 = b.ovf_clip_y ? screen.y + b.border_w[0] : screen.y - BIG
        cy1 = b.ovf_clip_y ? screen.y + b.h - b.border_w[2] : screen.y + b.h + BIG
        emit_overflow_clip(pt, b, {cx0, cy0}, {cx1, cy1}, round_clip)
    }
    // scroll de elemento: desloca o conteúdo pra cima por scroll_y e p/ a
    // esquerda por scroll_x (clipado acima)
    child_oy := b.overflow_scroll ? oy2 - b.scroll_y : oy2
    child_ox := b.overflow_scroll ? ox2 - b.scroll_x : ox2
    if b.perspective>0 do emit(pt,PC_XformBegin{})
    if owns_scope {
        if b.overflow_hidden do end_overflow_clip(pt, round_clip)
        collect_stacking(active_scope, b, ox2, oy2, -1, abs_origin)
        if x_preserves(b) do stacking_depths(active_scope.entries[:],b,full,ox2,oy2)
        sort_stacking(active_scope.entries[:],x_preserves(b))
        paint_stacking(pt, s, active_scope, true, screen.x - b.x - ox2, screen.y - b.y - oy2, eff, in_xform || b.has_transform || b.has_xform_matrix)
        if b.overflow_hidden do emit_overflow_clip(pt, b, {cx0, cy0}, {cx1, cy1}, round_clip)
    }
    if b.is_inline {
        // recolore o texto: animação (se ativa) tem prioridade sobre :hover
        oc := anim_col_on ? anim_col : b.hover.color
        ot := anim_col_on ? f32(1) : hover_t
        // text-decoration do `:hover` do autor quando quem casa a regra é a CAIXA
        // (`<a>` display:block de menu, um <div> com :hover). Vale para o run de
        // texto DESTA caixa; o de uma caixa descendente tem o seu próprio hover —
        // mesma degradação do `:hover{color}`, que também não desce por caixas.
        hdeco := b.hover.deco
        if b.href != "" && !b.hover.deco_set do hdeco.underline = true // default de link do UA
        when PAINTPROF { pp_ti := time.tick_now(); pp_kids0 := g_pp_child }
        paint_inline(pt, s, b, child_ox, child_oy, eff, oc, ot, in_xform || b.has_transform || b.has_xform_matrix, hdeco, b.hover.has_deco && hovering, active_scope) // per-item visibility lets descendants become visible
        when PAINTPROF {
            g_pp.inline_ms += time.duration_milliseconds(time.tick_since(pp_ti)) - (g_pp_child - pp_kids0)
            g_pp.inline_n += 1
        }
        if b.overflow_hidden do end_overflow_clip(pt, round_clip)
    } else {
        switch b.kind {
        case .Image:
            if !b.invisible {
                im.SetCursorPos({b.content_x + ox2, b.content_y + oy2})
                cs := im.GetCursorScreenPos()
                if b.is_canvas {
                    paint_canvas(pt, s, b, cs, b.img_dw, b.img_dh, eff)
                } else if b.is_svg {
                    paint_svg(pt, b, cs, b.img_dw, b.img_dh, eff)
                } else if sroot := svg_image_root(b.img_url); sroot != nil {
                    // <img src=".svg">: documento externo baixado+parseado no cache.
                    paint_svg_node(pt, sroot, b.svg_fg, cs, b.img_dw, b.img_dh, eff)
                } else {
                    inset: [4]f32
                    for i in 0..<4 do inset[i] = b.border_w[i] + b.padding[i]
                    rounding := image_rounding(b.w, b.h, b.border_radius, b.border_radius_pct, inset)
                    emit(pt, PC_Image{b.img_url, cs, b.img_dw, b.img_dh, b.obj_fit, eff, b.obj_pos_x, b.obj_pos_y, b.img_deco, rounding})
                }
            }
            if b.overflow_hidden do end_overflow_clip(pt, round_clip)
        case .Block:
            // Contextos e posicionados são pintados pelo contexto ancestral.
            clip_on := b.overflow_hidden
            for child in stacking_children(b) {
                if b.overflow_hidden {
                    esc := overflow_escapes(b, child)
                    if      esc && clip_on  { end_overflow_clip(pt, round_clip); clip_on = false }
                    else if !esc && !clip_on { emit_overflow_clip(pt, b, {cx0, cy0}, {cx1, cy1}, round_clip); clip_on = true }
                }
                emit_stacked(pt, s, child, child_ox, child_oy, eff, in_xform || b.has_transform || b.has_xform_matrix, active_scope)
            }
            if clip_on do end_overflow_clip(pt, round_clip)
        }
    }

    if owns_scope {
        paint_stacking(pt, s, active_scope, false, screen.x - b.x - ox2, screen.y - b.y - oy2, eff, in_xform || b.has_transform || b.has_xform_matrix)
    }

    if b.perspective>0 {
        px,py:=screen.x+b.w*b.perspective_ox+b.perspective_opx,screen.y+b.h*b.perspective_oy+b.perspective_opy
        pm:XMatrix=1; pm[3,2]=-1/b.perspective
        emit(pt,PC_ProjectEnd{x_translation(px,py,0)*pm*x_translation(-px,-py,0),x_preserves(b)})
    }
    // overflow:hidden + raio: o clip do ImGui é retangular, então os filhos que
    // chegam aos cantos (ex.: um topo em gradiente) saem quadrados. Recorta os
    // cantos arredondados preenchendo o entalhe com a cor de trás e redesenha a borda.
    if b.overflow_hidden && radius > 0.5 && !round_clip {
        // ⚠️ o entalhe EXTERNO (PC_MaskCorners, abaixo) não basta quando há BORDA:
        // ele só limpa o que passa da curva externa, e o canto QUADRADO do filho
        // continua cobrindo a faixa entre a curva INTERNA (padding-box) e a
        // externa — que é onde o fundo contorna o canto por baixo da borda. Efeito
        // visível: a moldura AFINA até sumir nos 4 cantos (medido no famososbr.com,
        // `.profile-image`: 5px na reta → 0px no canto; o Chrome mantém os 5px).
        // Sem borda as duas curvas coincidem e o entalhe externo já resolve — por
        // isso o caso comum (sem borda) sai daqui sem emitir nada.
        if bwt > 0.5 || bwr > 0.5 || bwb > 0.5 || bwl > 0.5 {
            bw4 := [4]f32{bwt, bwr, bwb, bwl}
            x1b, y1b := screen.x + b.w, screen.y + b.h
            // mesma ordem da passada de fundo: cor de trás → background-color →
            // gradiente. A cor de trás vai sempre (fundo transparente sob borda
            // translúcida tem de mostrar o que está ATRÁS, não o filho).
            emit(pt, PC_InnerNotch{screen.x, screen.y, x1b, y1b, bw4, radius, corner_flags, col_o(behind, eff)})
            // ⚠️ a faixa restaurada é a ÁREA DA BORDA. Com `background-clip`
            // padding-box/content-box o fundo NÃO pinta ali — repintá-lo aqui
            // inventaria cor onde a spec manda mostrar o que está atrás. Só o
            // default (border-box) leva fundo; os outros ficam na cor de trás.
            if !b.invisible && !hide_empty && b.bg_clip == .Border {
                if eff_has_bg {
                    emit(pt, PC_InnerNotch{screen.x, screen.y, x1b, y1b, bw4, radius, corner_flags, col_o(eff_bg, eff)})
                }
                // Gradiente LINEAR: recolore os VÉRTICES do entalhe pela mesma
                // rampa do fundo (o mecanismo do background-clip:text), medida em
                // ip0/ip1 — a mesma caixa do emit_grad_bg, então casa cor a cor.
                // DEGRADAÇÃO: radial/cônico, background-image e alpha por stop
                // ficam de fora e caem na cor sólida acima.
                if b.grad.active && !b.grad_clip_text && !b.grad.radial && !b.grad.conic {
                    emit(pt, PC_ShadeGradBegin{})
                    emit(pt, PC_InnerNotch{screen.x, screen.y, x1b, y1b, bw4, radius, corner_flags, col_o(0xFFFFFF, eff)})
                    emit(pt, PC_ShadeGradEnd{ip0, ip1, b.grad, eff})
                }
            }
        }
        emit(pt, PC_MaskCorners{screen.x, screen.y, screen.x + b.w, screen.y + b.h, radius, corner_flags, col_o(behind, eff)})
        // The corner cleanup also erased the outer shadow in those notches.
        // Restore only the part inside the rectangular box; the mask has a
        // transparent hole for the rounded interior, so children stay intact.
        if !b.invisible && eff_shadow_n > 0 {
            emit(pt, PC_PushClip{screen, {screen.x + b.w, screen.y + b.h}})
            for i := eff_shadow_n - 1; i >= 0; i -= 1 {
                if eff_shadows[i].inset do continue
                emit(pt, PC_Shadow{screen.x, screen.y, screen.x + b.w, screen.y + b.h, radius, eff_shadows[i], eff, false})
            }
            emit(pt, PC_PopClip{})
        }
        if b.has_border {
            if b.bimg.active do emit(pt, PC_BorderImage{screen, b, eff_border, eff, radius, corner_flags})
            else             do emit(pt, PC_Border{screen, b, eff_border, eff, radius, corner_flags})
        }
    }
    g_bg_behind = behind

    // alça de `resize` — depois dos filhos (fica POR CIMA do conteúdo) e fora do
    // clip de overflow, que já foi fechado acima.
    if b.resize != .None && b.node != nil && !b.pe_none && !b.invisible {
        paint_resize_grip(pt, b, screen, eff)
    }

    // pointer-events:none — o elemento não é alvo de cliques (passam através).
    if b.href != "" && !b.pe_none {
        if x_mouse_over(b, screen, ox2, oy2) {
            im.SetMouseCursor(.Hand)
            if im.IsMouseClicked(.Left) do navigate_href(s, b.href)
            if aux_frame() do s.aux_href = b.href // o último pintado (o de cima) vence
        }
    }

    // botão do MEIO: mesmo hit-test por ordem de pintura do clique (abaixo), mas
    // num alvo SEPARADO — o meio não dispara `click`, e sim mousedown/mouseup/
    // auxclick (ver dispatch_page_aux).
    if b.node != nil && my_paint_seq > g_aux_seq && !b.pe_none && aux_frame() {
        if x_mouse_over(b, screen, ox2, oy2) {
            s.aux_node = b.node
            g_aux_seq  = my_paint_seq
        }
    }

    // clique com handler JS: grava a caixa sob o cursor que está MAIS ACIMA na
    // ordem de pintura (ver g_hit_seq: filho > pai, e irmão da frente > irmão de
    // trás). O dispatch acontece DEPOIS do paint (dispatch_page_click), nunca aqui.
    if b.node != nil && my_paint_seq > g_click_seq && !b.pe_none {
        if x_mouse_over(b, screen, ox2, oy2) && im.IsMouseClicked(.Left) {
            s.click_target = b.node
            g_click_seq    = my_paint_seq
        }
    }

    // clique em checkbox/radio: alterna o estado (radio liga este e desliga o grupo)
    if (b.ctrl == .Checkbox || b.ctrl == .Radio) && !b.ctrl_disabled && !b.pe_none {
        if x_mouse_over(b, screen, ox2, oy2) && im.IsMouseClicked(.Left) {
            if b.ctrl == .Checkbox {
                b.ctrl_checked = !b.ctrl_checked
            } else {
                if name := radio_name(b); name != "" && len(s.tabs) > 0 && s.tabs[s.active].layout != nil {
                    uncheck_radio_group(s.tabs[s.active].layout, name)
                }
                b.ctrl_checked = true
            }
        }
    }

    // fecha a layer (LIFO: dentro do transform, que foi aberto antes)
    if do_layer do emit(pt, PC_LayerEnd{})
    // transform rotate/scale: gira/escala todos os vértices desta subárvore em
    // torno do transform-origin (fração 0..1 do box; default 50% 50%).
    if do_xform {
        if use_full || keep_depth { emit(pt,PC_ProjectEnd{project,keep_depth}) } else { emit(pt,PC_XformEnd{screen.x+b.w*b.transform_ox,screen.y+b.h*b.transform_oy,xa,xb,xc,xd}) }
    }
}

// Um filho posicionado ESCAPA do overflow:hidden deste box quando o box NÃO é o
// bloco contenedor dele (o CB é um ancestral) — o abspos "fura" as caixas entre
// ele e seu CB. Se o box É o CB (position!=static, ou cb_abs/cb_fixed do M120), o
// overflow dele RECORTA o filho. Filhos em fluxo (static/relative/sticky) nunca
// escapam. Regra espelha layout_absolutes: abs → CB é o ancestral posicionado ou
// cb_abs; fixed → CB é cb_fixed (position não fixa fixed).
overflow_escapes :: proc(b, child: ^Box) -> bool {
    #partial switch child.pos {
    case .Absolute: return !(b.pos != .Static || b.cb_abs)
    case .Fixed:    return !b.cb_fixed
    }
    return false
}

// Lado do pai `preserve-3d` que está pintando agora (true = de trás). Só o filho
// DIRETO o lê (`in_p3d`, resolvido no estilo): um descendente adiado para o
// stacking context de um ancestral mais distante não herda o lado por engano.
g_p3d_back: bool

// O transform PRÓPRIO desta caixa está mostrando a face de trás?
//
// A matriz é estática (`xf_back` basta). Nos campos escalares o :hover troca o
// alvo e a transition atravessa o zero no meio do giro: o lado é o do ALVO
// enquanto o sinal da escala efetiva bate com o dele, e o do outro estado antes
// disso. O sinal sozinho não serve — `scaleX(-1)` inverte o sinal sem virar a face.
box_face_back :: proc(b: ^Box, hovering: bool, eff_s, tgt_s: f32) -> bool {
    if b.has_xform_matrix || !b.hover.has_transform do return b.xf_back
    alvo, outro := b.xf_back, b.hover.back
    if hovering do alvo, outro = outro, alvo
    return (eff_s < 0) == (tgt_s < 0) ? alvo : outro
}

// Pinta um filho na sua posição de empilhamento. absolute/fixed já têm coords
// absolutas (translate_box) → offset 0; o resto (static/relative/sticky) carrega
// os offsets acumulados dos ancestrais.
@(private="file")
emit_stacked :: proc(pt: ^Painter, s: ^State, child: ^Box, ox, oy, eff: f32, in_xform := false, scope: ^Stacking_Scope = nil) {
    if child.pos == .Absolute || child.pos == .Fixed {
        paint_box(pt, s, child, 0, 0, eff, in_xform, scope)
    } else {
        paint_box(pt, s, child, ox, oy, eff, in_xform, scope)
    }
}

// Desenha texto glifo a glifo inserindo letter-spacing (px) após cada um.
// Só chamado quando spacing != 0; o caso comum usa o AddText de string inteira.
@(private="file")
draw_spaced_text :: proc(dl: ^im.DrawList, font: ^im.Font, size: f32, pos: im.Vec2, col: u32, text: string, spacing: f32, kerning: Font_Kerning = .Auto) {
    x := pos.x
    prev: rune
    for r in text {
        x += text_pair_kerning(font, size, prev, r, kerning)
        prev = r
        // Buffer de PILHA com o NUL escrito à mão, no lugar de clone_to_cstring:
        // este laço roda por CARACTERE, e `tracking-*` do Tailwind faz dele o
        // caminho comum (58% dos comandos de texto do github têm spacing). O par
        // controlado de 2026-08-02 mediu este laço DOBRANDO o tempo de replay.
        b4, n := utf8.encode_rune(r)
        buf: [5]u8
        copy(buf[:4], b4[:])
        buf[n] = 0
        cs := cstring(&buf[0])
        adv := im.Font_CalcTextSizeA(font, size, FLT_MAX, FLT_MAX, cs).x
        v0 := int(dl.VtxBuffer.Size)
        im.DrawList_AddTextImFontPtr(dl, font, size, {x, pos.y}, col, cs)
        // AddText trunca a origem de cada chamada. Preserve a posição relativa
        // fracionária dos glifos, como numa chamada única para a palavra inteira.
        dx := (x - pos.x) - (f32(int(x)) - f32(int(pos.x)))
        verts := ([^]im.DrawVert)(dl.VtxBuffer.Data)
        for i in v0 ..< int(dl.VtxBuffer.Size) do verts[i].pos.x += dx
        x += adv + spacing
    }
}

paint_inline_content :: proc(pt: ^Painter, s: ^State, b: ^Box, ox, oy: f32, opa: f32 = 1.0, over_color: u32 = 0, over_t: f32 = 0, in_xform := false, box_deco: Deco = {}, box_deco_on := false, scope: ^Stacking_Scope = nil) {
    im.SetCursorPos({b.content_x + ox, b.content_y + oy})
    cs := im.GetCursorScreenPos()

    // Grupo do elemento INLINE sob o mouse cujo :hover muda a text-decoration.
    // Precisa sair ANTES do laço: a decoração é pintada junto da palavra, e o
    // gatilho é o elemento inteiro — hover numa palavra decide pelas outras.
    hov_deco_grp := b.pe_none ? u32(0) : hovered_deco_grp(b, cs)
    eff_deco :: proc(it: Inline_Item, box_deco: Deco, box_deco_on: bool, hov_grp: u32) -> Deco {
        d := it.deco
        if box_deco_on do d = box_deco // :hover que casou a CAIXA
        // o elemento INLINE é mais interno que a caixa: ganha dela
        if it.hov_grp != 0 && it.hov_grp == hov_grp do d = it.hov_deco
        return d
    }

    // Fundo/borda de elementos inline (badges, <a class=button>, pílulas): pinta
    // ANTES do texto. Agrupa itens consecutivos com o mesmo ibg_grp na mesma linha
    // (mesmo y) — cada run vira uma caixa. Elementos que quebram em várias linhas
    // rendem um run por linha (box-decoration-break:slice, o default).
    for i := 0; i < len(b.inlines); {
        it := b.inlines[i]
        if it.ibg_grp == 0 || it.hidden || it.ibg_invisible { i += 1; continue }
        grp := it.ibg_grp
        y0 := it.y
        x_left := cs.x + it.x - it.ibl
        x_right := cs.x + it.x + it.w
        top := f32(1e9); bot := f32(-1e9)
        j := i
        for j < len(b.inlines) && b.inlines[j].ibg_grp == grp && b.inlines[j].y == y0 && !b.inlines[j].hidden && !b.inlines[j].ibg_invisible {
            e := b.inlines[j]
            x_left=min(x_left,cs.x+e.x-e.ibl)
            x_right=max(x_right,cs.x+e.x+e.w+e.ibr)
            core := e.fsize > 0 ? e.fsize : e.h // altura de conteúdo ≈ font-size (em box)
            cy := cs.y + e.y + e.h * 0.5
            if t := cy - core * 0.5 - e.ipt; t < top do top = t
            if bb := cy + core * 0.5 + e.ipb; bb > bot do bot = bb
            j += 1
        }
        p0 := im.Vec2{x_left, top}; p1 := im.Vec2{x_right, bot}
        // Limita o raio à METADE do menor lado, como o `corner_rounding` das caixas
        // de bloco. `rounded-full` do Tailwind v4 é `border-radius: 3.40282e38px`
        // (o máximo do f32, literal); sem o limite o valor cru — que com zoom vira
        // +Inf — ia direto p/ o rasterizador.
        rad := it.irad
        if lim := min(p1.x - p0.x, p1.y - p0.y) * 0.5; rad > lim do rad = lim
        if it.ibg_has do emit(pt, PC_RectFilled{p0, p1, col_o(it.ibg, opa), rad, {}})
        if it.ibw > 0 do emit(pt, PC_Rect{p0, p1, col_o(it.ibd, opa), rad, {}, it.ibw})
        i = j
    }

    // `background-clip: text` com gradiente: a rampa é resolvida na caixa do
    // ELEMENTO que tem o clip, não no texto — então o retângulo sai UMA vez, fora
    // do laço. Dois casos:
    //   • o BLOCO tem o clip → a caixa é o content-box dele;
    //   • um SPAN inline tem o clip → a caixa é o RUN de palavras do span
    //     (b.inline_grads casa o grupo `ibg_grp`). É o caso do Tailwind.
    gt_p0, gt_p1: im.Vec2
    if b.grad_clip_text {
        hmax: f32 = 0
        for &g in b.inlines {
            if g.hidden do continue
            if e := g.y + g.h; e > hmax do hmax = e
        }
        gt_p0 = cs
        gt_p1 = {cs.x + b.content_w, cs.y + hmax}
    }
    // retângulo de cada gradiente inline (mesma ordem de b.inline_grads)
    ig_rect: [][2]im.Vec2
    if len(b.inline_grads) > 0 {
        ig_rect = make([][2]im.Vec2, len(b.inline_grads), context.temp_allocator)
        for ig, gi in b.inline_grads {
            x0, y0 := f32(1e9), f32(1e9)
            x1, y1 := f32(-1e9), f32(-1e9)
            for &it in b.inlines {
                if it.hidden || it.ibg_grp != ig.grp do continue
                if v := cs.x + it.x;        v < x0 do x0 = v
                if v := cs.x + it.x + it.w; v > x1 do x1 = v
                if v := cs.y + it.y;        v < y0 do y0 = v
                if v := cs.y + it.y + it.h; v > y1 do y1 = v
            }
            ig_rect[gi] = {{x0, y0}, {x1, y1}}
        }
    }

    for &it, it_i in b.inlines {
        if it.hidden || (it.invisible && it.kind != .InlineBox) do continue // retain layout for hidden text
        px := cs.x + it.x
        py := cs.y + it.y
        switch it.kind {
        case .Break:
        case .Word:
            if it.fsize <= 0 do continue // font-size:0 → invisível (ImGui trata size 0 como tamanho nativo)
            // rs = tamanho de render (com correção em-square). centraliza a caixa
            // ascent-descent do glifo na caixa de linha (half-leading do line-height).
            rs := render_px(it.fsize, it.em)
            line_height:=it.h
            if b.writing_mode!=.Horizontal {
                if it.vertical_sideways {
                    cx,cy:=px+it.w/2,py+it.h/2
                    emit(pt,PC_XformBegin{})
                    px=cx-it.h/2; py=cy-it.w/2; line_height=it.w
                } else { px+=(it.w-it.text_w)/2 }
            }
            ty := py + (line_height - rs) * 0.5
            word_color := over_t > 0 ? lerp_color(it.color, over_color, over_t) : it.color
            tc := col_o(word_color, opa)
            txt := it.text
            if it.ellipsized {
                txt = strings.concatenate({it.text[:it.draw_bytes], "…"}, context.temp_allocator)
            }
            txt=bidi_display_text(txt,it.bidi_level,it.bidi_override)
            // text-shadow: cópias do texto atrás, em ordem reversa (a 1ª da lista
            // fica no topo). Sem blur real — só o offset nítido. Herdado no Box.
            if b.text_shadow_n > 0 {
                for si := b.text_shadow_n - 1; si >= 0; si -= 1 {
                    sh := b.text_shadows[si]
                    scol := col_o(sh.color, opa)
                    emit(pt, PC_InlineText{it.font, rs, {px + sh.dx, ty + sh.dy}, scol, txt, it.letter_spacing, it.font_kerning})
                }
            }
            // texto: o replay decide entre AddText e draw_spaced_text por spacing.
            // Com clip:text, os vértices deste trecho são recoloridos pelo gradiente
            // (a decoração entra junto: ela também é clipada ao texto). O
            // text-shadow acima fica FORA — a sombra não é clipada.
            shade_i := -1 // índice em b.inline_grads, se esta palavra é de um span clipado
            if it.ibg_grp != 0 {
                for ig, gi in b.inline_grads do if ig.grp == it.ibg_grp { shade_i = gi; break }
            }
            if b.grad_clip_text || shade_i >= 0 do emit(pt, PC_ShadeGradBegin{})
            emit(pt, PC_InlineText{it.font, rs, {px, ty}, tc, txt, it.letter_spacing, it.font_kerning})
            // decoração efetiva: a do :hover do autor SUBSTITUI a normal enquanto o
            // elemento estiver sob o mouse (ver eff_deco).
            deco := eff_deco(it, box_deco, box_deco_on, hov_deco_grp)
            if deco.underline || deco.overline || deco.strike {
                // cor da linha = text-decoration-color, ou a cor do texto se ausente.
                dcol := deco.color != DECO_UNSET ? col_o(deco.color, opa) : tc
                dthk := deco.thick // 0 = auto → emit_deco_line usa 1px
                // A linha atravessa o ESPAÇO até a próxima palavra: no navegador a
                // decoração é do elemento DECORADOR, não da palavra — sem isto todo
                // link de várias palavras saía com o sublinhado picotado. Estende só
                // dentro do mesmo elemento (link_grp/hov_grp) e com a MESMA decoração
                // e cor, senão dois links vizinhos virariam um traço só.
                x1 := px + it.w
                if it_i + 1 < len(b.inlines) {
                    nx := b.inlines[it_i + 1]
                    if nx.kind == .Word && !nx.hidden && nx.y == it.y && nx.color == it.color &&
                       nx.link_grp == it.link_grp && nx.hov_grp == it.hov_grp &&
                       eff_deco(nx, box_deco, box_deco_on, hov_deco_grp) == deco {
                        if v := cs.x + nx.x; v > x1 do x1 = v
                    }
                }
                if deco.overline  do emit_deco_line(pt, px, x1, ty + rs * 0.04, dthk, dcol, deco.style)
                if deco.underline {
                    // text-underline-position:under desce a linha; offset a afasta mais.
                    uy := ty + rs * (deco.under ? 0.94 : 0.82) + deco.offset
                    emit_deco_line(pt, px, x1, uy, dthk, dcol, deco.style)
                }
                if deco.strike    do emit_deco_line(pt, px, x1, ty + rs * 0.46, dthk, dcol, deco.style)
            }
            if shade_i >= 0 {
                r := ig_rect[shade_i]
                emit(pt, PC_ShadeGradEnd{r[0], r[1], b.inline_grads[shade_i].g, opa})
            } else if b.grad_clip_text {
                emit(pt, PC_ShadeGradEnd{gt_p0, gt_p1, b.grad, opa})
            }
            if b.writing_mode!=.Horizontal && it.vertical_sideways {
                emit(pt,PC_XformEnd{cs.x+it.x+it.w/2,cs.y+it.y+it.h/2,0,-1,1,0})
            }
        case .Image:
            if sroot := svg_image_root(it.img_url); sroot != nil {
                fg := it.color != 0 ? it.color : DEFAULT_TEXT
                paint_svg_node(pt, sroot, fg, {px, py}, it.w, it.h, opa) // currentColor = cor do texto do contexto
            } else {
                rounding := image_rounding(it.w, it.h, it.img_radius, it.img_radius_pct)
                emit(pt, PC_Image{it.img_url, {px, py}, it.w, it.h, it.img_fit, opa, it.img_pos_x, it.img_pos_y, it.img_deco, rounding})
            }
        case .InlineBox:
            // a caixa foi disposta a partir de (0,0); desloca-a p/ a posição do
            // item na linha (origem do conteúdo + it.x/it.y, no espaço do pai).
            if it.box != nil {
                paint_box(pt, s, it.box, b.content_x + ox + it.x, b.content_y + oy + it.y, opa, in_xform || b.has_transform || b.has_xform_matrix, scope)
            }
        }
    }

    tem_link := false
    if !b.pe_none do for &it in b.inlines do if it.href != "" && !it.hidden && !it.invisible { tem_link = true; break }
    if tem_link { // pointer-events:none e caixa sem link nenhum saem sem alocar nada
        // o realce do UA só existe p/ quem NÃO tem sublinhado: repetir a linha num
        // link já sublinhado dá traço duplo (o do texto e o do realce).
        ja_sub := make([]bool, len(b.inlines), context.temp_allocator)
        for &it, i in b.inlines do ja_sub[i] = eff_deco(it, box_deco, box_deco_on, hov_deco_grp).underline
        paint_link_hover(pt, s, b, cs, opa, over_color, over_t, hov_deco_grp, ja_sub)
    }
}

// Grupo do elemento inline com `:hover{text-decoration}` que está sob o mouse (0
// = nenhum). Itens contíguos de mesmo grupo na mesma linha formam um run, então
// o vão ENTRE as palavras do elemento também conta como estar sobre ele.
@(private="file")
hovered_deco_grp :: proc(b: ^Box, cs: im.Vec2) -> u32 {
    hit: u32 = 0
    for i := 0; i < len(b.inlines); {
        it := b.inlines[i]
        if it.hov_grp == 0 || it.hidden || it.invisible { i += 1; continue }
        x0 := cs.x + it.x; x1 := cs.x + it.x + it.w
        top := cs.y + it.y; bot := top + it.h
        j := i + 1
        for j < len(b.inlines) {
            e := b.inlines[j]
            if e.hidden || e.hov_grp != it.hov_grp || e.y != it.y do break
            x0=min(x0,cs.x+e.x)
            x1=max(x1,cs.x+e.x+e.w)
            if v := cs.y + e.y;       v < top do top = v
            if v := cs.y + e.y + e.h; v > bot do bot = v
            j += 1
        }
        if x_mouse_rect(b, {x0, top}, {x1, bot}) do hit = it.hov_grp // o último ganha
        i = j
    }
    return hit
}

// Um run de link numa linha: os itens contíguos do MESMO <a> (link_grp) que
// caíram na mesma linha. Um link que quebra rende um run por linha.
@(private="file")
Link_Run :: struct {
    grp:      u32,
    x0, x1:   f32, // extremos horizontais do run (inclui o espaço ENTRE as palavras)
    top, bot: f32,
    col:      u32,
    href:     string,
    autoral:  bool, // o AUTOR definiu a decoração de :hover deste link (o UA cala)
}

// Realce de hover do link: cursor de mão, clique e sublinhado.
//
// O alvo é o LINK, não a palavra. Um <a> de várias palavras rende um item por
// palavra — testar item a item (o que se fazia antes) sublinhava só a palavra
// sob o cursor e deixava o espaço entre elas morto ao clique. Aqui os itens do
// mesmo `link_grp` viram runs por linha; o run sob o mouse identifica o link, e
// TODOS os runs dele (inclusive os das outras linhas) recebem o sublinhado.
@(private="file")
paint_link_hover :: proc(pt: ^Painter, s: ^State, b: ^Box, cs: im.Vec2, opa: f32, over_color: u32, over_t: f32, hov_deco_grp: u32, ja_sub: []bool) {
    runs := make([dynamic]Link_Run, 0, 4, context.temp_allocator)
    for i := 0; i < len(b.inlines); {
        it := b.inlines[i]
        if it.href == "" || it.hidden || it.invisible { i += 1; continue }
        wc := over_t > 0 ? lerp_color(it.color, over_color, over_t) : it.color
        r := Link_Run{
            grp = it.link_grp, href = it.href, col = col_o(wc, opa),
            x0 = cs.x + it.x, x1 = cs.x + it.x + it.w,
            top = cs.y + it.y, bot = cs.y + it.y + it.h,
            // o UA cala quando o AUTOR mandou na decoração de :hover deste link, ou
            // quando o texto já sai sublinhado (senão o realce vira traço duplo).
            autoral = (it.hov_grp != 0 && it.hov_grp == hov_deco_grp) || ja_sub[i],
        }
        j := i + 1
        // grupo 0 (link sem grupo atribuído) NÃO funde: cada item vira o seu run,
        // senão dois links vizinhos sem grupo viravam um só.
        for r.grp != 0 && j < len(b.inlines) {
            e := b.inlines[j]
            if e.hidden || e.invisible || e.href == "" || e.link_grp != r.grp || e.y != it.y do break
            r.x0=min(r.x0,cs.x+e.x)
            r.x1=max(r.x1,cs.x+e.x+e.w)
            if v := cs.y + e.y;       v < r.top do r.top = v
            if v := cs.y + e.y + e.h; v > r.bot do r.bot = v
            j += 1
        }
        append(&runs, r)
        i = j
    }

    hov := -1
    for r, ri in runs do if x_mouse_rect(b, {r.x0, r.top}, {r.x1, r.bot}) do hov = ri
    if hov < 0 do return

    im.SetMouseCursor(.Hand)
    if im.IsMouseClicked(.Left) do navigate_href(s, runs[hov].href)
    if aux_frame() do s.aux_href = runs[hov].href
    hg := runs[hov].grp
    for r, ri in runs {
        if ri != hov && (hg == 0 || r.grp != hg) do continue
        // O sublinhado abaixo é do UA (afordância de link) — ver `autoral`.
        if r.autoral do continue
        y := r.bot - 2
        emit(pt, PC_Line{{r.x0, y}, {r.x1, y}, r.col})
    }
}

// Desenha uma imagem recortada MANUALMENTE ao retângulo clip [cmin,cmax],
// ajustando as UVs — o DrawList_AddImage do ImGui NÃO respeita o clip do child
// (texto/retângulos respeitam, imagem não), então as imagens vazavam sobre a
// toolbar ao rolar. Desenha só a porção visível. clip=[a,b] é a interseção final.
@(private="file")
draw_image_clipped :: proc(dl: ^im.DrawList, tex: im.TextureID, ix0, iy0, ix1, iy1: f32, tint: u32, cmin, cmax: im.Vec2) {
    vx0 := max(ix0, cmin.x); vy0 := max(iy0, cmin.y)
    vx1 := min(ix1, cmax.x); vy1 := min(iy1, cmax.y)
    if vx1 <= vx0 || vy1 <= vy0 do return
    iw := ix1 - ix0; ih := iy1 - iy0
    if iw <= 0 || ih <= 0 do return
    u0 := (vx0 - ix0) / iw; u1 := (vx1 - ix0) / iw
    v0 := (vy0 - iy0) / ih; v1 := (vy1 - iy0) / ih
    im.DrawList_AddImage(dl, tex, {vx0, vy0}, {vx1, vy1}, {u0, v0}, {u1, v1}, tint)
}

@(private="file")
paint_image :: proc(dl: ^im.DrawList, url: string, pos: im.Vec2, w, h: f32, fit := Obj_Fit.Fill, opa: f32 = 1.0, pos_fx: f32 = 0.5, pos_fy: f32 = 0.5, deco := false, rounding: Image_Rounding = {}) {
    tint := imgui_mul_alpha(0xFFFFFFFF, opa) // full white tinted by opacity
    cmin := im.DrawList_GetClipRectMin(dl)
    cmax := im.DrawList_GetClipRectMax(dl)
    if url != "" {
        img := image_get(url)
        // Enquanto carrega, preserva o fundo CSS ja pintado e o espaco do layout.
        // O navegador nao deve impor uma cor de placeholder sobre o site.
        if img.state == .Loading do return
        if img.state == .Ready {
            tex := im.TextureID(uintptr(img.tex))
            iw, ih := f32(img.w), f32(img.h)
            if fit == .Fill || iw <= 0 || ih <= 0 || w <= 0 || h <= 0 {
                if image_has_rounding(rounding) {
                    draw_image_rounded(dl, tex, pos, {pos.x+w, pos.y+h}, pos.x, pos.y, pos.x+w, pos.y+h, tint, cmin, cmax, rounding)
                } else {
                    draw_image_clipped(dl, tex, pos.x, pos.y, pos.x + w, pos.y + h, tint, cmin, cmax)
                }
            } else {
                dw, dh: f32
                switch fit {
                case .Cover:   s := max(w / iw, h / ih); dw = iw * s; dh = ih * s
                case .Contain: s := min(w / iw, h / ih); dw = iw * s; dh = ih * s
                case .None:    dw = iw; dh = ih
                case .Fill:    dw = w;  dh = h
                }
                // object-position: fração 0..1 (0.5 = centro); recorta ao elemento
                x := pos.x + (w - dw) * pos_fx
                y := pos.y + (h - dh) * pos_fy
                // clip = interseção do retângulo do elemento com o clip atual
                ecmin := im.Vec2{max(pos.x, cmin.x), max(pos.y, cmin.y)}
                ecmax := im.Vec2{min(pos.x + w, cmax.x), min(pos.y + h, cmax.y)}
                if image_has_rounding(rounding) {
                    draw_image_rounded(dl, tex, pos, {pos.x+w, pos.y+h}, x, y, x+dw, y+dh, tint, ecmin, ecmax, rounding)
                } else {
                    draw_image_clipped(dl, tex, x, y, x + dw, y + dh, tint, ecmin, ecmax)
                }
            }
            return
        }
    }
    // Emoji sem glifo (ou ainda no 1º frame): NADA. O placeholder cinza de <img>
    // aqui seria um bloco cinza no meio de uma frase — pior que o vão.
    if strings.has_prefix(url, EMOJI_SCHEME) do return
    // Imagem DECORATIVA que FALHOU (formato sem decoder — AVIF —, 404, decode
    // inválido): NADA. Em `.Failed` o placeholder seria uma mancha opaca sobre o que estiver
    // atrás. Restrito ao decorativo por MEDIDA, não por gosto — ver img_is_decorative.
    //
    // Custou uma regressão para aparecer: o M234 deu altura aos absolutos com
    // `height:%`, e o poster AVIF do hero da cloudflare (`h-full w-full`, `alt=""`,
    // até então com altura 0) passou a pintar 1256x760 de cinza sobre o hero
    // laranja — `--imgdiff` 11,7 → 25,2. O defeito era ANTIGO; a altura só o revelou.
    if deco && url != "" && image_get(url).state == .Failed do return
    // placeholder (retângulo respeita o clip do ImGui normalmente)
    if image_has_rounding(rounding) {
        points: [160]im.Vec2
        n := image_round_polygon(pos, {pos.x+w, pos.y+h}, rounding, cmin, cmax, &points)
        if n >= 3 do im.DrawList_AddConvexPolyFilled(dl, &points[0], i32(n), col_o(0xe8e8ec, opa))
    } else {
        im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, col_o(0xe8e8ec, opa), 4)
    }
}

// Pinta um linear-gradient em faixas: um retângulo bicolor por par de stops
// (AddRectFilledMultiColor interpola entre as bordas). Direção mapeada ao eixo
// horizontal/vertical (diagonais aproximadas). Ignora border-radius. Em
// repeating-linear-gradient o padrão [pos[0],pos[n-1]] é ladrilhado ao longo do
// eixo (período < 1 → várias faixas na caixa) preservando as bordas nítidas.
@(private="file")
paint_gradient :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, opa: f32 = 1.0) {
    n := g.n
    if n < 2 do return
    if g.diagonal {
        paint_gradient_diagonal(dl, p_min, p_max, g, opa)
        return
    }
    horiz   := g.dir == .Right || g.dir == .Left
    reverse := g.dir == .Left  || g.dir == .Top
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    span := horiz ? W : H
    pos  := resolve_grad_positions(g, span)

    // offsets de ladrilhamento: só {0} p/ não-repeating; múltiplos do período p/
    // cobrir a fração [0,1] quando repeating.
    off_lo, off_hi := 0, 0
    L: f32 = 0
    if g.repeating {
        L = pos[n - 1] - pos[0]
        if L <= 1e-4 || span <= 0 do return
        off_lo = int(math.floor((0 - pos[n - 1]) / L))
        off_hi = int(math.ceil((1 - pos[0]) / L))
        if off_hi - off_lo > 4096 do off_hi = off_lo + 4096 // guarda faixas sub-pixel
    }

    im.DrawList_PushClipRect(dl, p_min, p_max, true)
    for m := off_lo; m <= off_hi; m += 1 {
        shift := f32(m) * L
        for i in 0 ..< n - 1 {
            pa := pos[i]     + shift
            pb := pos[i + 1] + shift
            if pb <= pa || pb <= 0 || pa >= 1 do continue // vazio ou fora da caixa
            if g.hint_set[i] {
                // segmento com color hint: a mistura é NÃO-linear (curva de potência),
                // que o AddRectFilledMultiColor (linear) não faz → subdivide amostrando
                // grad_color_at (que aplica o hint) em sub-faixas.
                K :: 24
                prev_s := pa
                prev_c := imgui_mul_alpha(grad_color_at(g, pos, pa, span), opa)
                for k in 1 ..= K {
                    s := pa + (pb - pa) * f32(k) / f32(K)
                    cc := imgui_mul_alpha(grad_color_at(g, pos, s, span), opa)
                    draw_axial_band(dl, p_min, p_max, W, H, horiz, reverse, prev_s, s, prev_c, cc)
                    prev_s = s; prev_c = cc
                }
                continue
            }
            ca := imgui_mul_alpha(col(g.cols[i]),     opa)
            cb := imgui_mul_alpha(col(g.cols[i + 1]), opa)
            draw_axial_band(dl, p_min, p_max, W, H, horiz, reverse, pa, pb, ca, cb)
        }
    }
    im.DrawList_PopClipRect(dl)
}

// Uma faixa bicolor de um linear axial: da fração pa (cor ca) à pb (cor cb),
// mapeada ao eixo horizontal/vertical (reverse inverte o sentido). O
// AddRectFilledMultiColor interpola LINEARMENTE entre as bordas.
@(private="file")
draw_axial_band :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, W, H: f32, horiz, reverse: bool, pa, pb: f32, ca, cb: u32) {
    if horiz {
        c0 := reverse ? p_min.x + W - pa * W : p_min.x + pa * W
        c1 := reverse ? p_min.x + W - pb * W : p_min.x + pb * W
        lo, hi := min(c0, c1), max(c0, c1)
        cl := reverse ? cb : ca // cor na borda esquerda / direita
        cr := reverse ? ca : cb
        im.DrawList_AddRectFilledMultiColor(dl, {lo, p_min.y}, {hi, p_max.y}, cl, cr, cr, cl)
    } else {
        c0 := reverse ? p_min.y + H - pa * H : p_min.y + pa * H
        c1 := reverse ? p_min.y + H - pb * H : p_min.y + pb * H
        lo, hi := min(c0, c1), max(c0, c1)
        ct := reverse ? cb : ca // cor na borda superior / inferior
        cbm := reverse ? ca : cb
        im.DrawList_AddRectFilledMultiColor(dl, {p_min.x, lo}, {p_max.x, hi}, ct, ct, cbm, cbm)
    }
}

// Geometria da elipse final do radial-gradient (css-images-3 §3.3): centro do
// `at <position>` e semi-eixos do shape+size do prelúdio. (bx,by,bw,bh) = caixa
// do fundo. O zero-value do Gradient dá o default do CSS — elipse centrada
// farthest-corner —, então gradiente sem prelúdio segue como antes.
radial_geometry :: proc(g: csspkg.Gradient, bx, by, bw, bh: f32) -> (cx, cy, rx, ry: f32) {
    cx, cy = bx + bw*0.5, by + bh*0.5
    if g.r_pos_set {
        cx = bx + (g.r_cx_pct ? g.r_cx * bw : g.r_cx)
        cy = by + (g.r_cy_pct ? g.r_cy * bh : g.r_cy)
    }
    // distâncias do centro a cada lado (podem ser negativas se o centro está
    // fora da caixa; o abs mantém "lado mais próximo/distante" com sentido)
    dl, dr := abs(cx - bx), abs(bx + bw - cx)
    dt, db := abs(cy - by), abs(by + bh - cy)

    if g.r_size == .Explicit {
        rx = g.r_rx_pct ? g.r_rx * bw : g.r_rx
        ry = g.r_ry_pct ? g.r_ry * bh : g.r_ry
        if g.r_circle do ry = rx // círculo: um raio só (o % já virou px em bw)
        return
    }
    side_x, side_y: f32
    far := g.r_size == .Farthest_Side || g.r_size == .Farthest_Corner
    if far { side_x, side_y = max(dl, dr), max(dt, db) }
    else   { side_x, side_y = min(dl, dr), min(dt, db) }

    if g.r_circle {
        // círculo: o raio é a distância (ao lado ou ao canto), igual nos 2 eixos
        switch g.r_size {
        case .Closest_Side:    rx = min(side_x, side_y)
        case .Farthest_Side:   rx = max(side_x, side_y)
        case .Closest_Corner:  rx = math.sqrt(side_x*side_x + side_y*side_y)
        case .Farthest_Corner: rx = math.sqrt(side_x*side_x + side_y*side_y)
        case .Explicit:        // já tratado acima
        }
        ry = rx
        return
    }
    rx, ry = side_x, side_y
    if g.r_size == .Closest_Corner || g.r_size == .Farthest_Corner {
        // a elipse mantém a razão de aspecto do *-side e é escalada até PASSAR
        // pelo canto (spec): fator k tal que (dx/rx)² + (dy/ry)² = 1.
        if rx > 0.01 && ry > 0.01 {
            k := math.sqrt((side_x/rx)*(side_x/rx) + (side_y/ry)*(side_y/ry))
            rx *= k; ry *= k
        }
    }
    return
}

// radial-gradient. Sem gradiente nativo por-pixel no ImGui, tesselamos ANÉIS
// concêntricos — mas com COR POR VÉRTICE (PrimWriteVtx, como o linear
// arredondado): a interpolação do rasterizador suaviza dentro do anel, o que
// antes ficava em faixas chapadas visíveis (o "anel cinza" do hero do
// getbootstrap). A malha é contínua (anéis compartilham vértices), então cada
// pixel é coberto UMA vez e cor com alpha não se super-empilha.
//
// O anel externo vai até t_max = a elipse que ainda alcança o canto mais
// distante, p/ a área FORA da elipse final receber a cor do último stop (ou as
// repetições, no repeating). Recortado ao retângulo do fundo.
@(private="file")
paint_radial_gradient :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, radius: f32, opa: f32 = 1.0) {
    if g.n < 2 do return
    bw, bh := p_max.x - p_min.x, p_max.y - p_min.y
    if bw < 0.5 || bh < 0.5 do return
    cx, cy, rx, ry := radial_geometry(g, p_min.x, p_min.y, bw, bh)
    if rx < 0.01 || ry < 0.01 do return
    // A linha do gradiente do radial é o raio HORIZONTAL do centro à elipse
    // final (spec) — é ela que resolve os stops em px.
    pos := resolve_grad_positions(g, rx)

    // t que faz a elipse alcançar o canto mais distante (cobre a caixa toda)
    corners := [4][2]f32{{p_min.x, p_min.y}, {p_max.x, p_min.y}, {p_min.x, p_max.y}, {p_max.x, p_max.y}}
    t_max: f32 = 1
    for corner in corners {
        ddx := (corner[0] - cx) / rx
        ddy := (corner[1] - cy) / ry
        t_max = max(t_max, math.sqrt(ddx*ddx + ddy*ddy))
    }
    t_max = min(t_max, 64) // elipse minúscula numa caixa grande: não explode a malha

    // extensão em pixels do anel externo → quantos anéis/segmentos valem a pena
    ext := max(rx, ry) * t_max
    RINGS := clamp(int(ext / 8), 16, 80)
    SEG   := clamp(int(ext / 6), 24, 96)
    if g.repeating {
        // os stops cobrem 1 período; sem anéis extras as repetições somem
        period := pos[g.n - 1] - pos[0]
        if period > 1e-4 do RINGS = clamp(int(math.ceil(6 * t_max / period)), RINGS, 320)
    }
    // ⚠️ o índice do ImGui é u16 (DrawIdx = c.ushort) e o backend SDL não usa
    // VtxOffset: a draw list INTEIRA do frame cabe em 64k vértices. O teto aqui
    // mantém a malha no mesmo patamar da versão antiga (40×48 quads = 7680
    // vértices), então uma página com vários gradientes não piora.
    MESH_MAX_VTX :: 8192
    MAX_SEG      :: 96

    // raios dos anéis: amostras uniformes MAIS um par (p−ε, p+ε) em cada stop.
    // Sem o par, uma transição DURA (`azul 0 12px, amarelo 12px 24px`) ficaria
    // borrada na largura de um anel; com ele a troca acontece em ~0,3% do raio.
    ts := make([dynamic]f32, 0, RINGS + 2*g.n + 8, context.temp_allocator)
    for r in 0 ..= RINGS do append(&ts, f32(r) / f32(RINGS) * t_max)
    add_stop_ring :: proc(ts: ^[dynamic]f32, p, t_max: f32) {
        EPS :: f32(0.0015)
        if p <= 0 || p > t_max do return
        append(ts, max(0, p - EPS))
        append(ts, min(t_max, p + EPS))
    }
    if g.repeating {
        period := pos[g.n - 1] - pos[0]
        if period > 1e-4 {
            for k := 0; f32(k) * period <= t_max && k < 128; k += 1 {
                for i in 0 ..< g.n do add_stop_ring(&ts, pos[i] + f32(k)*period, t_max)
            }
        }
    } else {
        for i in 0 ..< g.n do add_stop_ring(&ts, pos[i], t_max)
    }
    slice.sort(ts[:])
    rs := make([dynamic]f32, 0, len(ts), context.temp_allocator)
    min_gap := t_max * 0.0004
    for v in ts {
        if len(rs) == 0 || v - rs[len(rs) - 1] > min_gap do append(&rs, v)
    }
    if len(rs) < 2 do return
    // teto de vértices (ver MESH_MAX_VTX): primeiro afina o ângulo, depois
    // rareia os anéis (metade por passada) até caber.
    for len(rs) * SEG > MESH_MAX_VTX && SEG > 24 do SEG = max(24, SEG * 3 / 4)
    for len(rs) * SEG > MESH_MAX_VTX && len(rs) > 8 {
        keep := make([dynamic]f32, 0, len(rs)/2 + 2, context.temp_allocator)
        for v, i in rs do if i % 2 == 0 || i == len(rs)-1 do append(&keep, v)
        rs = keep
    }
    NR := len(rs)

    // tabela trigonométrica DEPOIS do SEG final (senão os ângulos não fecham a volta)
    cosv, sinv: [MAX_SEG + 1]f32
    for s in 0 ..< SEG {
        ang := f32(s) / f32(SEG) * 2 * math.PI
        cosv[s] = math.cos(ang); sinv[s] = math.sin(ang)
    }

    im.DrawList_PushClipRect(dl, p_min, p_max, true)
    // malha em anéis: NR círculos de SEG vértices, compartilhados entre anéis
    // vizinhos (cada pixel coberto UMA vez). O anel de t=0 degenera no centro —
    // triângulos de área zero, sem custo visual, e mantém a indexação uniforme.
    uv := im.GetFontTexUvWhitePixel()
    im.DrawList_PrimReserve(dl, i32(6 * SEG * (NR - 1)), i32(SEG * NR))
    base := u32(dl._VtxCurrentIdx)
    for t in rs {
        c := imgui_mul_alpha(grad_color_at(g, pos, t, rx), opa)
        xr, yr := rx * t, ry * t
        for s in 0 ..< SEG {
            im.DrawList_PrimWriteVtx(dl, {cx + xr * cosv[s], cy + yr * sinv[s]}, uv, c)
        }
    }
    for r in 0 ..< NR - 1 {
        i0 := base + u32(r * SEG)       // anel interno
        i1 := base + u32((r + 1) * SEG) // anel externo
        for s in 0 ..< SEG {
            s2 := u32((s + 1) % SEG) // fecha o anel no último segmento
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i0 + u32(s)))
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i1 + u32(s)))
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i1 + s2))
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i0 + u32(s)))
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i1 + s2))
            im.DrawList_PrimWriteIdx(dl, im.DrawIdx(i0 + s2))
        }
    }
    im.DrawList_PopClipRect(dl)
}

// conic-gradient: a cor varia pelo ÂNGULO ao redor do centro (0=topo, horário,
// deslocado por 'from'). Tesselamos em cunhas (triângulos centro→borda): para
// cada par de ângulos amostrados, um triângulo com cor por vértice = cor no
// ângulo. Os 4 cantos entram na amostragem p/ a borda seguir o retângulo sem
// cortar cantos. Cada cunha tem vértice-centro próprio (o centro é singular no
// conic), colorido no ângulo médio.
@(private="file")
paint_conic_gradient :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, radius: f32 = 0, opa: f32 = 1.0) {
    if g.n < 2 do return
    pos := resolve_grad_positions(g)
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    if W < 0.5 || H < 0.5 do return
    cx := (p_min.x + p_max.x) * 0.5
    cy := (p_min.y + p_max.y) * 0.5
    hw := W * 0.5; hh := H * 0.5
    r  := clamp(radius, 0, min(hw, hh)) // raio dos cantos (0 = retângulo)
    from := g.angle
    RAD :: f32(math.PI / 180)

    ang_of :: proc(dx, dy: f32) -> f32 { // direção (screen) → ângulo CSS conic (graus)
        a := math.atan2(dx, -dy) / RAD
        for a < 0    do a += 360
        for a >= 360 do a -= 360
        return a
    }
    // amostras: uniforme + os 4 cantos (p/ a borda não cortar canto). Repeating
    // conic → mais amostras p/ resolver as faixas angulares repetidas.
    N := 128
    if g.repeating {
        period := pos[g.n - 1] - pos[0]
        if period > 1e-4 do N = clamp(int(math.ceil(12 / period)), 128, 720)
    }
    angs := make([dynamic]f32, 0, N + 4, context.temp_allocator)
    for i in 0 ..< N do append(&angs, f32(i) / f32(N) * 360)
    append(&angs, ang_of(hw, -hh), ang_of(hw, hh), ang_of(-hw, hh), ang_of(-hw, -hh))
    slice.sort(angs[:])
    m := len(angs)
    if m < 3 do return

    // ponto na borda (retângulo, ou rounded-rect quando r>0) p/ um ângulo, a partir
    // do centro. Nos cantos (além da parte reta em ambos os eixos), intersecta o
    // raio com o arco de raio r centrado em (±(hw-r), ±(hh-r)).
    bpt :: proc(cx, cy, hw, hh, r, adeg: f32) -> im.Vec2 {
        a := adeg * RAD
        dx := math.sin(a); dy := -math.cos(a)
        sx := abs(dx) > 1e-6 ? hw / abs(dx) : 1e30
        sy := abs(dy) > 1e-6 ? hh / abs(dy) : 1e30
        s := min(sx, sy)
        px := dx * s; py := dy * s // relativo ao centro
        if r > 0.5 && abs(px) > hw - r && abs(py) > hh - r {
            // zona de canto: interseção raio×círculo (centro do arco a partir da origem)
            ccx := math.sign(px) * (hw - r)
            ccy := math.sign(py) * (hh - r)
            b := dx * ccx + dy * ccy
            disc := b * b - (ccx * ccx + ccy * ccy - r * r)
            if disc >= 0 {
                s = b + math.sqrt(disc) // raiz externa (centro está dentro)
                px = dx * s; py = dy * s
            }
        }
        return {cx + px, cy + py}
    }
    tcol :: proc(g: csspkg.Gradient, pos: []f32, adeg, from, opa: f32) -> u32 {
        t := adeg - from
        for t < 0    do t += 360
        for t >= 360 do t -= 360
        return imgui_mul_alpha(grad_color_at(g, pos, t / 360), opa)
    }

    uv := im.GetFontTexUvWhitePixel()
    im.DrawList_PrimReserve(dl, i32(3 * m), i32(3 * m)) // m triângulos, 3 vért cada (sem compartilhar)
    base := u32(dl._VtxCurrentIdx)
    idx := base
    for i in 0 ..< m {
        a0 := angs[i]
        a1 := i + 1 < m ? angs[i + 1] : angs[0] + 360
        amid := (a0 + a1) * 0.5
        cc := tcol(g, pos, amid, from, opa)
        im.DrawList_PrimWriteVtx(dl, {cx, cy}, uv, cc)
        im.DrawList_PrimWriteVtx(dl, bpt(cx, cy, hw, hh, r, a0), uv, tcol(g, pos, a0, from, opa))
        im.DrawList_PrimWriteVtx(dl, bpt(cx, cy, hw, hh, r, a1), uv, tcol(g, pos, a1, from, opa))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(idx))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(idx + 1))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(idx + 2))
        idx += 3
    }
}

// linear-gradient em ângulo NÃO axial (diagonais reais, sem snap ao eixo).
// A linha do gradiente passa pelo centro na direção CSS θ; a posição t∈[0,1] de
// um ponto é a projeção normalizada nessa linha (comprimento L = |W·sinθ|+|H·cosθ|,
// conforme a spec). Tesselamos o box numa grade de células e pintamos cada uma
// com AddRectFilledMultiColor usando as cores projetadas dos 4 cantos — bilinear
// reproduz EXATAMENTE a rampa afim (2 stops full-range → 1 célula já basta; para
// multi-stop/posições internas a grade refina a curva). Sem sobreposição → alpha
// correto. (Cantos arredondados continuam pelo caminho axial em paint_gradient_rounded.)
@(private="file")
paint_gradient_diagonal :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, opa: f32 = 1.0) {
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    if W < 0.5 || H < 0.5 do return
    cx := (p_min.x + p_max.x) * 0.5
    cy := (p_min.y + p_max.y) * 0.5
    th := g.angle * math.PI / 180
    st := math.sin(th); ct := math.cos(th)
    dx := st; dy := -ct                      // direção do gradiente (y p/ baixo)
    L := abs(W * st) + abs(H * ct)           // comprimento da linha do gradiente
    if L < 0.5 do return
    pos := resolve_grad_positions(g, L)

    tat :: proc(px, py, cx, cy, dx, dy, L: f32) -> f32 {
        return clamp((((px - cx) * dx + (py - cy) * dy) + L * 0.5) / L, 0, 1)
    }
    // 2 stops full-range = rampa globalmente afim → 1 célula é exata; senão refina.
    // (color hint torna a mistura não-linear → precisa da grade fina, não 1 célula.)
    full2 := g.n == 2 && pos[0] <= 0.001 && pos[1] >= 0.999 && !grad_has_hints(g)
    GN := full2 ? 1 : 24
    if g.repeating {
        // faixas de alta frequência: refina a grade p/ ~4 células por período
        // (a interpolação bilinear ainda suaviza um pouco as bordas diagonais).
        period := pos[g.n - 1] - pos[0]
        if period > 1e-4 do GN = clamp(int(math.ceil(4 / period)), 24, 160)
    }
    if grad_has_hints(g) do GN = max(GN, 48) // amostra fina p/ a curva do hint
    for gy in 0 ..< GN {
        y0 := p_min.y + H * f32(gy) / f32(GN)
        y1 := p_min.y + H * f32(gy + 1) / f32(GN)
        for gx in 0 ..< GN {
            x0 := p_min.x + W * f32(gx) / f32(GN)
            x1 := p_min.x + W * f32(gx + 1) / f32(GN)
            ctl := imgui_mul_alpha(grad_color_at(g, pos, tat(x0, y0, cx, cy, dx, dy, L), L), opa)
            ctr := imgui_mul_alpha(grad_color_at(g, pos, tat(x1, y0, cx, cy, dx, dy, L), L), opa)
            cbr := imgui_mul_alpha(grad_color_at(g, pos, tat(x1, y1, cx, cy, dx, dy, L), L), opa)
            cbl := imgui_mul_alpha(grad_color_at(g, pos, tat(x0, y1, cx, cy, dx, dy, L), L), opa)
            im.DrawList_AddRectFilledMultiColor(dl, {x0, y0}, {x1, y1}, ctl, ctr, cbr, cbl)
        }
    }
}

// linear-gradient diagonal COM cantos arredondados. Sem clip arredondado nativo,
// tesselamos a rounded-rect num LEQUE a partir do centro: amostramos o contorno
// (4 arcos + 4 lados retos) e emitimos triângulos (centro, P_i, P_{i+1}) com cor
// por vértice = cor projetada na linha do gradiente. 2 stops → exato (rampa afim);
// multi-stop → aproximado nas arestas (amostragem densa reduz o erro).
@(private="file")
paint_gradient_rounded_diagonal :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, radius: f32, opa: f32 = 1.0) {
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    if W < 0.5 || H < 0.5 do return
    x0, y0, x1, y1 := p_min.x, p_min.y, p_max.x, p_max.y
    r := min(radius, min(W, H) * 0.5)
    cx := (x0 + x1) * 0.5
    cy := (y0 + y1) * 0.5
    th := g.angle * math.PI / 180
    st := math.sin(th); ct := math.cos(th)
    dx := st; dy := -ct
    L := abs(W * st) + abs(H * ct)
    if L < 0.5 do return
    pos := resolve_grad_positions(g, L)

    // contorno da rounded-rect, sentido horário: lado sup → arco TR → lado dir →
    // arco BR → lado inf → arco BL → lado esq → arco TL. Lados amostrados p/ que
    // gradientes multi-stop também sigam a curva ao longo das arestas.
    pts := make([dynamic]im.Vec2, 0, 96, context.temp_allocator)
    K :: 8  // passos por arco
    E :: 6  // passos por lado reto
    arc :: proc(pts: ^[dynamic]im.Vec2, ccx, ccy, r, a0, a1: f32) {
        for k in 0 ..= K {
            a := a0 + (a1 - a0) * f32(k) / f32(K)
            append(pts, im.Vec2{ccx + r * math.cos(a), ccy + r * math.sin(a)})
        }
    }
    edge :: proc(pts: ^[dynamic]im.Vec2, ax, ay, bx, by: f32) {
        for k in 1 ..< E { // pontos internos (extremos vêm dos arcos vizinhos)
            f := f32(k) / f32(E)
            append(pts, im.Vec2{ax + (bx - ax) * f, ay + (by - ay) * f})
        }
    }
    PI := f32(math.PI)
    edge(&pts, x0 + r, y0, x1 - r, y0)                 // topo
    arc(&pts, x1 - r, y0 + r, r, 1.5 * PI, 2 * PI)     // TR
    edge(&pts, x1, y0 + r, x1, y1 - r)                 // direita
    arc(&pts, x1 - r, y1 - r, r, 0, 0.5 * PI)          // BR
    edge(&pts, x1 - r, y1, x0 + r, y1)                 // base
    arc(&pts, x0 + r, y1 - r, r, 0.5 * PI, PI)         // BL
    edge(&pts, x0, y1 - r, x0, y0 + r)                 // esquerda
    arc(&pts, x0 + r, y0 + r, r, PI, 1.5 * PI)         // TL

    m := len(pts)
    if m < 3 do return
    uv := im.GetFontTexUvWhitePixel()
    im.DrawList_PrimReserve(dl, i32(3 * m), i32(m + 1))
    base := u32(dl._VtxCurrentIdx)
    cc := imgui_mul_alpha(grad_color_at(g, pos, 0.5, L), opa) // centro projeta em t=0.5
    im.DrawList_PrimWriteVtx(dl, {cx, cy}, uv, cc)
    for p in pts {
        t := clamp((((p.x - cx) * dx + (p.y - cy) * dy) + L * 0.5) / L, 0, 1)
        im.DrawList_PrimWriteVtx(dl, p, uv, imgui_mul_alpha(grad_color_at(g, pos, t, L), opa))
    }
    for i in 0 ..< m {
        j := (i + 1) % m
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(base))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(base + 1 + u32(i)))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(base + 1 + u32(j)))
    }
}

// Multiplica o canal alpha de uma cor já em formato ImGui (RGBA u32) por opa.
@(private="file")
imgui_mul_alpha :: proc(c: u32, opa: f32) -> u32 {
    if opa >= 1.0 do return c
    a := u32(f32((c >> 24) & 0xFF) * opa + 0.5)
    if a > 255 do a = 255
    return (c & 0x00FFFFFF) | (a << 24)
}

// Interpola duas cores empacotadas (alpha no byte ALTO) em espaço de alpha
// PREMULTIPLICADO, como manda a spec (css-images-3 §3.4.3, css-color-4 §12.3).
//
// Interpolar canal a canal SEM premultiplicar arrasta a cor p/ o valor RGB do
// stop transparente — e `transparent` é PRETO com alpha 0. Um fade
// `azul → transparent` passava por cinza-escuro no meio (metade do caminho:
// RGB já 50% preto, alpha ainda 50%), dando um halo sujo em volta de todo glow
// (visível nas bolhas do getbootstrap). Premultiplicando, o canal de cor é
// ponderado pelo próprio alpha: o stop transparente não contribui com cor
// nenhuma e o azul só desvanece.
//
// Se os dois lados são opacos (a=255), o resultado é idêntico ao antigo — que é
// por que isto passou despercebido em quase todo gradiente.
//
// ⚠️ SÓ p/ cor já empacotada pelo ImGui, onde alpha 0 é MESMO transparente. A
// cor do CSS nesta engine usa a convenção oposta (byte alto 0 = OPACO, ver
// `vec()`), então `lerp_color` das transições NÃO pode usar isto — foi o que os
// testes de transição pegaram na 1ª versão desta mudança.
@(private="file")
lerp_premul :: proc(c0, c1: u32, t: f32) -> u32 {
    a0 := f32((c0 >> 24) & 0xFF)
    a1 := f32((c1 >> 24) & 0xFF)
    a  := a0 + (a1 - a0) * t
    out := u32(clamp(a + 0.5, 0, 255)) << 24
    for sh: u32 = 0; sh < 24; sh += 8 {
        p0 := f32((c0 >> sh) & 0xFF) * a0 // canais premultiplicados (escala 0..255*255)
        p1 := f32((c1 >> sh) & 0xFF) * a1
        p  := p0 + (p1 - p0) * t
        v: f32 = 0
        if a > 0.01 do v = p / a // desfaz a premultiplicação
        out |= u32(clamp(v + 0.5, 0, 255)) << sh
    }
    return out
}

// Interpola duas cores empacotadas (ImGui RGBA u32). Ver lerp_premul.
@(private="file")
lerp_col :: proc(c0, c1: u32, t: f32) -> u32 {
    return lerp_premul(c0, c1, t)
}

// Peso de interpolação de um color hint no segmento: `frac` = fração linear
// (0..1) do ponto no segmento; `p` = posição RELATIVA do hint (0..1). Per
// css-images-4: weight = frac^(ln0.5/ln p) → em p a mistura vale 50%. p→0 = tudo
// cor final; p→1 = tudo cor inicial; p=0.5 = linear.
@(private="file")
hint_weight :: proc(frac, p: f32) -> f32 {
    if p <= 0.0001 do return 1
    if p >= 0.9999 do return 0
    if abs(p - 0.5) < 0.0001 do return frac
    return math.pow(clamp(frac, 0, 1), math.ln(f32(0.5)) / math.ln(p))
}

// Algum segmento do gradiente tem color interpolation hint?
@(private="file")
grad_has_hints :: proc(g: csspkg.Gradient) -> bool {
    for i in 0 ..< g.n do if g.hint_set[i] do return true
    return false
}

// Cor do gradiente no parâmetro t∈[0,1] do eixo (com alpha), em formato ImGui.
// line_px = comprimento da linha do gradiente (p/ resolver hints em px; 0 = n/a).
@(private="file")
grad_color_at :: proc(g: csspkg.Gradient, pos: []f32, t: f32, line_px: f32 = 0) -> u32 {
    n := g.n
    tt := t
    if g.repeating {
        // enrola t no período [pos[0], pos[n-1]) — o padrão se repete em ambos os
        // sentidos p/ cobrir toda a linha (período < 1 → várias faixas na caixa).
        lo, hi := pos[0], pos[n - 1]
        L := hi - lo
        if L > 1e-6 do tt = lo + (t - lo) - math.floor((t - lo) / L) * L
    }
    if tt <= pos[0]     do return col(g.cols[0])
    if tt >= pos[n - 1] do return col(g.cols[n - 1])
    for i in 0 ..< n - 1 {
        a, b := pos[i], pos[i + 1]
        if tt <= b {
            if b <= a do return col(g.cols[i])
            f := (tt - a) / (b - a)
            if g.hint_set[i] {
                // hint em px → fração via line_px; senão já é fração/turn. Grampeia
                // dentro do segmento e aplica a curva de potência.
                h := g.hint_px[i] ? (line_px > 0 ? g.hint_pos[i] / line_px : a) : g.hint_pos[i]
                h = clamp(h, a, b)
                f = hint_weight(f, (h - a) / (b - a))
            }
            return lerp_col(col(g.cols[i]), col(g.cols[i + 1]), f)
        }
    }
    return col(g.cols[n - 1])
}

// Variante de gradiente com cantos arredondados. AddRectFilledMultiColor não
// arredonda, então aqui tesselamos a faixa em quads ao longo do eixo: cada
// coluna recua a dimensão transversal perto dos cantos (arco de quarto de
// círculo) e recebe a cor calculada por vértice — multi-stop e alpha corretos.
// Colunas extras são inseridas em cada stop p/ manter as paradas nítidas.
@(private="file")
paint_gradient_rounded :: proc(dl: ^im.DrawList, p_min, p_max: im.Vec2, g: csspkg.Gradient, radius: f32, opa: f32 = 1.0) {
    n := g.n
    if n < 2 do return
    horiz   := g.dir == .Right || g.dir == .Left
    reverse := g.dir == .Left  || g.dir == .Top
    W := p_max.x - p_min.x
    H := p_max.y - p_min.y
    if W <= 0 || H <= 0 do return
    r    := min(radius, min(W, H) * 0.5)
    span := horiz ? W : H
    pos  := resolve_grad_positions(g, span)

    // amostras axiais (0..span): tesselagem dos dois arcos + cada stop.
    ax := make([dynamic]f32, 0, 64, context.temp_allocator)
    nseg := clamp(int(r * 0.5) + 4, 6, 24)
    for k in 0 ..= nseg {
        f := f32(k) / f32(nseg)
        append(&ax, f * r)            // arco inicial [0, r]
        append(&ax, span - r + f * r) // arco final  [span-r, span]
    }
    for i in 0 ..< n {
        a := reverse ? (1 - pos[i]) * span : pos[i] * span
        append(&ax, clamp(a, 0, span))
    }
    if g.repeating {
        // stops só cobrem 1 período; adiciona colunas uniformes p/ as faixas
        // repetidas aparecerem (a cor por-vértice vem de grad_color_at c/ wrap).
        period := pos[n - 1] - pos[0]
        if period > 1e-4 {
            ns := clamp(int(math.ceil(4 / period)), 8, 400)
            for k in 0 ..= ns do append(&ax, span * f32(k) / f32(ns))
        }
    } else if grad_has_hints(g) {
        // hints tornam a mistura NÃO-linear entre stops; colunas só nos stops
        // interpolariam reto. Amostra uniforme p/ a curva aparecer.
        for k in 0 ..= 48 do append(&ax, span * f32(k) / 48)
    }
    slice.sort(ax[:])

    // descarta quase-duplicatas, preservando ordem crescente
    cols := make([dynamic]f32, 0, len(ax), context.temp_allocator)
    for v in ax {
        if len(cols) == 0 || v - cols[len(cols) - 1] > 0.25 do append(&cols, v)
    }
    nc := len(cols)
    if nc < 2 do return

    uv := im.GetFontTexUvWhitePixel()
    im.DrawList_PrimReserve(dl, i32(6 * (nc - 1)), i32(2 * nc))
    base := u32(dl._VtxCurrentIdx)

    for a, k in cols {
        inset: f32 = 0
        if a < r {
            d := r - a;            inset = r - math.sqrt(max(0, r * r - d * d))
        } else if a > span - r {
            d := a - (span - r);   inset = r - math.sqrt(max(0, r * r - d * d))
        }
        t := reverse ? 1 - a / span : a / span
        c := imgui_mul_alpha(grad_color_at(g, pos, t, span), opa)
        if horiz {
            x := p_min.x + a
            im.DrawList_PrimWriteVtx(dl, {x, p_min.y + inset}, uv, c) // topo
            im.DrawList_PrimWriteVtx(dl, {x, p_max.y - inset}, uv, c) // base
        } else {
            y := p_min.y + a
            im.DrawList_PrimWriteVtx(dl, {p_min.x + inset, y}, uv, c) // esquerda
            im.DrawList_PrimWriteVtx(dl, {p_max.x - inset, y}, uv, c) // direita
        }
    }
    for k in 0 ..< nc - 1 {
        a0 := base + u32(2 * k)       // A_k
        a1 := base + u32(2 * (k + 1)) // A_{k+1}
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a0))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a1))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a1 + 1)) // B_{k+1}
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a0))
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a1 + 1)) // B_{k+1}
        im.DrawList_PrimWriteIdx(dl, im.DrawIdx(a0 + 1)) // B_k
    }
}

// SVGs do cache ficam Ready sem textura. Expande-os no RECORD, onde o
// renderer vetorial pode emitir sua geometria; raster continua no PC_BgImage.
// Usa a mesma geometria/limites do painter raster (inclusive o teto de tiles).
@(private)
emit_bg_image :: proc(pt: ^Painter, o_min, o_max, c_min, c_max: im.Vec2, b: ^Box, opa: f32 = 1.0, layer := -1) {
    url, size, repeat := b.bg_img, b.bg_size, b.bg_repeat
    pos_x, pos_y := b.bg_pos_x, b.bg_pos_y
    if layer >= 0 {
        if layer >= len(b.bg_extra) do return
        lay := b.bg_extra[layer]
        url, size, repeat = lay.img, lay.size, lay.repeat
        pos_x, pos_y = lay.pos_x, lay.pos_y
    }
    if url == "" do return
    img := image_get(url)
    if !img.is_svg {
        emit(pt, PC_BgImage{o_min, o_max, c_min, c_max, b, opa, layer})
        return
    }
    if img.state != .Ready || img.svg_root == nil || img.w <= 0 || img.h <= 0 do return
    W, H := o_max.x - o_min.x, o_max.y - o_min.y
    if W <= 0 || H <= 0 || c_max.x <= c_min.x || c_max.y <= c_min.y do return
    iw, ih := f32(img.w), f32(img.h)
    dw, dh := iw, ih
    switch size {
    case .Cover:   s := max(W / iw, H / ih); dw, dh = iw * s, ih * s
    case .Contain: s := min(W / iw, H / ih); dw, dh = iw * s, ih * s
    case .Auto:
    }
    if dw < 0.5 || dh < 0.5 do return
    if repeat && size == .Auto {
        startx := o_min.x - dw * math.ceil((o_min.x - c_min.x) / dw)
        starty := o_min.y - dh * math.ceil((o_min.y - c_min.y) / dh)
        y := starty
        for rows := 0; y < c_max.y && rows < 512; rows += 1 {
            x := startx
            for cols := 0; x < c_max.x && cols < 512; cols += 1 {
                emit_bg_svg_tile(pt, img, {x, y}, dw, dh, c_min, c_max, opa)
                x += dw
            }
            y += dh
        }
    } else {
        origin := im.Vec2{o_min.x + (W - dw) * pos_x, o_min.y + (H - dh) * pos_y}
        emit_bg_svg_tile(pt, img, origin, dw, dh, c_min, c_max, opa)
    }
}

// Recorta também ao viewport de CADA tile: paths/traços fora do SVG não
// podem invadir o tile vizinho. PC_PushClip intersecta com o clip do ancestral
// no replay, inclusive quando a geometria pertence a uma layer offscreen.
@(private="file")
emit_bg_svg_tile :: proc(pt: ^Painter, img: ^Img, origin: im.Vec2, dw, dh: f32, c_min, c_max: im.Vec2, opa: f32) {
    lo := im.Vec2{max(c_min.x, origin.x), max(c_min.y, origin.y)}
    hi := im.Vec2{min(c_max.x, origin.x + dw), min(c_max.y, origin.y + dh)}
    if hi.x <= lo.x || hi.y <= lo.y do return
    emit(pt, PC_PushClip{lo, hi})
    // Documento externo: currentColor inicial é preto, não a cor do elemento host.
    paint_svg_node(pt, img.svg_root, 0x000000, origin, dw, dh, opa)
    emit(pt, PC_PopClip{})
}

// Pinta background-image: url(). Recorta ao retângulo da caixa (PushClipRect).
// Suporta background-size cover/contain/auto, background-position e repeat (tile
// só no modo auto). Nada é desenhado enquanto a imagem não terminar de carregar.
@(private="file")
// o_min/o_max = área de POSICIONAMENTO (background-origin); c_min/c_max = área de
// CLIP/limite (background-clip). A imagem é dimensionada e posicionada na origin,
// mas o desenho é recortado à clip (∩ clip do ImGui).
// `layer` = índice em b.bg_extra, ou -1 p/ a camada 0 (campos diretos da Box).
paint_bg_image :: proc(dl: ^im.DrawList, o_min, o_max, c_min, c_max: im.Vec2, b: ^Box, opa: f32 = 1.0, layer := -1) {
    url    := b.bg_img
    size   := b.bg_size
    repeat := b.bg_repeat
    pos_x, pos_y := b.bg_pos_x, b.bg_pos_y
    if layer >= 0 {
        if layer >= len(b.bg_extra) do return
        lay := b.bg_extra[layer]
        url, size, repeat = lay.img, lay.size, lay.repeat
        pos_x, pos_y = lay.pos_x, lay.pos_y
    }
    img := image_get(url)
    if !bg_image_drawable(img) do return
    iw, ih := f32(img.w), f32(img.h)
    W, H := o_max.x - o_min.x, o_max.y - o_min.y // área de posicionamento
    if W <= 0 || H <= 0 do return
    tex := im.TextureID(uintptr(img.tex))
    tint := imgui_mul_alpha(0xFFFFFFFF, opa)

    dw, dh := iw, ih
    switch size {
    case .Cover:   s := max(W / iw, H / ih); dw, dh = iw * s, ih * s
    case .Contain: s := min(W / iw, H / ih); dw, dh = iw * s, ih * s
    case .Auto:
    }
    if dw < 0.5 || dh < 0.5 do return

    // clip efetivo = caixa de clip ∩ clip atual do ImGui (recorte manual via
    // draw_image_clipped, pois AddImage do ImGui não respeita o clip do child).
    cmin := im.DrawList_GetClipRectMin(dl)
    cmax := im.DrawList_GetClipRectMax(dl)
    ecmin := im.Vec2{max(c_min.x, cmin.x), max(c_min.y, cmin.y)}
    ecmax := im.Vec2{min(c_max.x, cmax.x), min(c_max.y, cmax.y)}

    if repeat && size == .Auto {
        // tiling ancorado à origem, cobrindo toda a caixa de clip (c_min..c_max).
        startx := o_min.x - dw * math.ceil((o_min.x - c_min.x) / dw)
        starty := o_min.y - dh * math.ceil((o_min.y - c_min.y) / dh)
        y := starty
        for rows := 0; y < c_max.y && rows < 512; rows += 1 {
            x := startx
            for cols := 0; x < c_max.x && cols < 512; cols += 1 {
                draw_image_clipped(dl, tex, x, y, x + dw, y + dh, tint, ecmin, ecmax)
                x += dw
            }
            y += dh
        }
    } else {
        x := o_min.x + (W - dw) * pos_x
        y := o_min.y + (H - dh) * pos_y
        draw_image_clipped(dl, tex, x, y, x + dw, y + dh, tint, ecmin, ecmax)
    }
}

// Resolve as posições dos stops em fração crescente: extremos viram 0/1 quando
// implícitos; intermediários sem posição distribuem uniformemente. Stops em px
// (g.pos_px) dividem pelo comprimento da linha do gradiente `line_px` (0 = px
// indisponível → degrada p/ 0). Em gradientes repeating NÃO recorta a [0,1] — as
// posições podem exceder 1 e o padrão [pos[0],pos[n-1]] é o período que se repete.
@(private="file")
resolve_grad_positions :: proc(g: csspkg.Gradient, line_px: f32 = 0) -> []f32 {
    n := g.n
    out := make([]f32, n, context.temp_allocator)
    for i in 0 ..< n {
        if !g.pos_set[i] { out[i] = -1; continue }
        v := g.pos_px[i] ? (line_px > 0 ? g.pos[i] / line_px : 0) : g.pos[i]
        out[i] = g.repeating ? v : clamp(v, 0, 1)
    }
    if out[0] < 0     do out[0] = 0
    if out[n - 1] < 0 do out[n - 1] = 1
    i := 1
    for i < n {
        if out[i] >= 0 { i += 1; continue }
        j := i
        for j < n && out[j] < 0 do j += 1
        prev := out[i - 1]
        next := j < n ? out[j] : 1
        steps := j - (i - 1)
        for k in i ..< j do out[k] = prev + (next - prev) * f32(k - (i - 1)) / f32(steps)
        i = j
    }
    for i in 1 ..< n do if out[i] < out[i - 1] do out[i] = out[i - 1]
    return out
}

@(private="file")
navigate_href :: proc(s: ^State, href: string) {
    // Âncora na MESMA página (#id): rola até o elemento em vez de recarregar. O
    // scroll é aplicado no viewport (pulo instantâneo, ou animação se a raiz tem
    // scroll-behavior:smooth). `#` sozinho ou `#top` = topo.
    if len(href) > 0 && href[0] == '#' {
        id := href[1:]
        tab := len(s.tabs) > 0 ? &s.tabs[s.active] : nil
        if tab != nil && tab.layout != nil {
            ty: f32 = 0
            found := id == "" || strings.equal_fold(id, "top")
            if !found {
                if tgt := find_box_by_id(tab.layout, id); tgt != nil {
                    // scroll-margin-top do alvo + scroll-padding-top da raiz recuam o
                    // ponto de aterrissagem (compensa header fixo/sticky).
                    ty = tgt.y - tgt.scroll_margin_top - root_scroll_padding_top(tab.layout)
                    if ty < 0 do ty = 0
                    found = true
                }
            }
            if found {
                s.scroll_pending = true
                s.scroll_target  = ty
                s.scroll_smooth  = root_scroll_smooth(tab.layout)
            }
        }
        return
    }
    base := len(s.tabs) > 0 ? s.tabs[s.active].url : ""
    if r := netpkg.resolve_url(base, href, context.temp_allocator); r != "" do start_navigation(s, r)
}

// scroll-behavior no <html>/<body> propaga p/ o viewport. O box do documento é
// sintético (sem estilo), então desce a cadeia doc→html→body procurando o flag.
root_scroll_smooth :: proc(root: ^Box) -> bool {
    n := root
    for depth := 0; n != nil && depth < 3; depth += 1 {
        if n.scroll_smooth do return true
        next: ^Box = nil
        for c in n.children { if c != nil && c.node != nil { next = c; break } } // 1º filho elemento
        n = next
    }
    return false
}

// Acha o primeiro Box cujo elemento tem id == `id` (Box.y é Y-página absoluto).
find_box_by_id :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_box_by_id(c, id); r != nil do return r
    }
    return nil
}

// scroll-padding-top da raiz (html/body): recuo do topo do container p/ o scroll
// de âncora (mesma cadeia sintética doc→html→body do scroll-behavior).
root_scroll_padding_top :: proc(root: ^Box) -> f32 {
    n := root
    for depth := 0; n != nil && depth < 3; depth += 1 {
        if n.scroll_padding_top > 0 do return n.scroll_padding_top
        next: ^Box = nil
        for c in n.children { if c != nil && c.node != nil { next = c; break } }
        n = next
    }
    return 0
}

// ── Liberação ────────────────────────────────────────────────────────────────

free_layout :: proc(b: ^Box) {
    if b == nil do return
    for c in b.children do free_layout(c)
    delete(b.children)
    for &p in b.animations { delete(p.anim.name); delete(p.anim.stops); delete(p.pending) }
    delete(b.animations)
    for &it in b.inlines {
        if it.text != ""    do delete(it.text)
        if it.href != ""    do delete(it.href)
        if it.img_url != "" do delete(it.img_url)
        if it.box != nil    do free_layout(it.box)
    }
    delete(b.inlines)
    for source in b.inline_sources do free(source)
    delete(b.inline_sources)
    for effect in b.inline_effects { delete(effect.absolutes); free(effect) }
    delete(b.inline_effects)
    delete(b.inline_grads)
    if b.img_url != ""   do delete(b.img_url)
    if b.bg_img != ""    do delete(b.bg_img)
    if b.mask_image.url != "" do delete(b.mask_image.url)
    if b.bimg.src  != "" do delete(b.bimg.src)
    if b.bimg.grad != "" do delete(b.bimg.grad)
    for lay in b.bg_extra do if lay.img != "" do delete(lay.img) // urls resolvidas em adopt_bg_extra
    delete(b.bg_extra)
    if b.edit_hint != "" do delete(b.edit_hint)
    if b.offset_path != "" do delete(b.offset_path) // clonado em apply_box
    free(b)
}

// ── Helpers locais ──────────────────────────────────────────────────────────

@(private="file")
is_ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

attr_num :: proc(n: ^dompkg.Node, name: string) -> f32 {
    if n == nil do return 0
    if v, ok := n.attrs[name]; ok {
        if f, k := strconv.parse_f64(v); k do return f32(f)
    }
    return 0
}

// ⚠️ NÃO é `private="file"`: o canvas2d.odin escolhe a fonte do `fillText` por
// esta MESMA proc — a escada de tamanhos e o fallback de face não podem ter uma
// 2ª cópia (lição do M213).
l_pick_font :: proc(size: f32, weight: Font_Weight, fam_id: u8, family: Font_Family = .Sans, italic := false) -> (^im.Font, f32, f32) {
    em_calibrar() // idempotente; roda de fato na 1ª vez que o atlas tem glifos
    // razão em-square da família pedida (a face do autor sobrescreve abaixo)
    em: f32 = g_em_sans
    switch family {
    case .Mono:  em = g_em_mono
    case .Serif: em = g_em_serif
    case .Sans:  em = g_em_sans
    }
    rsize := render_px(size, em) // degrau próximo do tamanho de RENDER (com em-square)
    best := 0
    for sz, i in g_font_sizes {
        if abs(sz - rsize) < abs(g_font_sizes[best] - rsize) do best = i
    }
    // Peso 500/600 (`.Semi`) tem face PRÓPRIA só no sans (Segoe UI Semibold).
    // ⚠️ degradação anotada: serif/mono do sistema (Georgia/Consolas) não têm
    // semibold, e não carregamos o semibold ITÁLICO — nesses casos cai no
    // NEGRITO, que dista 100 do alvo (600→700) em vez dos 200 do regular.
    // ⚠️ os 3 degraus (`fw_class`) valem SÓ p/ a face embutida: a @font-face
    // recebe o número inteiro — uma fonte variável instancia o 300 e o 900.
    cls := fw_class(weight)
    bold := cls == .Bold
    f: ^im.Font
    // @font-face primeiro: uma face declarada pelo autor VENCE a genérica. Só
    // quando não há face pronta (ainda baixando, formato não suportado, teto de
    // faces) cai na pilha embutida — que é o comportamento anterior ao M224.
    if fam_id != 0 {
        fem: f32
        f, fem = fontface_pick(fam_id, fw_css(weight), italic, best)
        if f != nil {
            f = native_font_pick(f, render_px(size, fem))
            return f, size / f.FontSize, fem
        }
    }
    switch family {
    case .Mono:
        if italic do f = cls != .Regular ? g_mono_z[best] : g_mono_i[best]
        if f == nil do f = cls != .Regular ? g_mono_b[best] : g_mono[best]
    case .Serif:
        if italic do f = cls != .Regular ? g_serif_z[best] : g_serif_i[best]
        if f == nil do f = cls != .Regular ? g_serif_b[best] : g_serif[best]
    case .Sans:
        if italic do f = cls != .Regular ? g_ital_b[best] : g_ital[best]
        if f == nil && cls == .Semi do f = g_semi[best]
        if f == nil do f = bold ? g_bold[best] : g_reg[best]
    }
    if f == nil { f = bold ? g_bold[best] : g_reg[best]; em = g_em_sans } // fallback se a TTF não carregou
    f = native_font_pick(f, render_px(size, em))
    if f != nil && f.FontSize > 0 do return f, size / f.FontSize, em
    return f, size / g_font_sizes[best], em
}

@(private="file")
l_default_size :: proc(tag: string) -> f32 {
    base: f32 = 16
    switch tag {
    case "h1": base = 32
    case "h2": base = 24
    case "h3": base = 19
    case "h4": base = 16
    case "h5": base = 13
    case "h6": base = 12
    }
    return base * g_zoom // acompanha o zoom da página (Ctrl +/-)
}

@(private="file")
l_is_heading :: proc(tag: string) -> bool {
    switch tag { case "h1","h2","h3","h4","h5","h6": return true }
    return false
}

@(private="file")
l_is_skip :: proc(tag: string) -> bool {
    switch tag {
    case "head", "script", "style", "title", "meta", "link", "base",
         "noscript", "template", "iframe", "object",
         // parse_document sintetiza um nó de DOCTYPE (tag "!doctype") como filho
         // do Document, irmão de <html>. O parser legado descartava o doctype;
         // aqui ele fica na árvore (p/ document.doctype futuro) mas não pinta.
         "!doctype":
        return true
    }
    return false
}

// Visível no PACOTE (não mais file-private): é a tabela de tags inline do UA, e o
// getComputedStyle (computed_om.odin) precisa dela p/ responder `display` quando a
// cascata não definiu nada — sem isto seriam DUAS tabelas p/ divergir.
l_is_inline :: proc(tag: string) -> bool {
    switch tag {
    case "a", "span", "b", "strong", "i", "em", "u", "s", "small",
         "mark", "code", "abbr", "cite", "q", "sub", "sup", "label",
         "time", "big", "tt", "font", "bdi", "bdo", "ins", "del":
        return true
    }
    return false
}

@(private="file")
l_find_link :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    if n.kind == .Element && n.tag == "a" && "href" in n.attrs do return n
    for c in n.children do if r := l_find_link(c); r != nil do return r
    return nil
}

@(private="file")
l_block_link_href :: proc(n: ^dompkg.Node) -> string {
    link := l_find_link(n)
    if link == nil do return ""
    href, ok := link.attrs["href"]
    if !ok || href == "" do return ""
    if n.tag == "a" do return href
    if l_gather_text(n) == l_gather_text(link) do return href
    return ""
}

@(private="file")
l_gather_text :: proc(n: ^dompkg.Node) -> string {
    sb := strings.builder_make(context.temp_allocator)
    dompkg.text_content(n, &sb)
    return l_collapse_ws(strings.to_string(sb))
}

@(private="file")
l_collapse_ws :: proc(s: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    prev := false
    for i in 0 ..< len(s) {
        ch := s[i]
        if is_ws(ch) {
            if !prev do strings.write_byte(&sb, ' ')
            prev = true
        } else {
            strings.write_byte(&sb, ch)
            prev = false
        }
    }
    return strings.trim_space(strings.to_string(sb))
}

// Tab stops are measured from the content edge and recomputed on each reflow.
tab_advance :: proc(it: ^Inline_Item, x, word_spacing: f32) -> f32 {
    step := f32(max(it.tab_columns, 0)) * max(0, space_adv(it) + word_spacing)
    if step <= 0 do return 0
    advance := step - (x - math.floor(x / step) * step)
    if advance < space_adv(it) * 0.5 do advance += step
    return advance
}

// Available inline extent shared by physical-width intrinsic measurements.
@(private="file")
orthogonal_inline_limit :: proc(b: ^Box) -> f32 {
    limit := b.has_height ? b.height : max(1, g_viewport_h)
    if b.has_height && b.box_sizing == .Border do limit = max(0, limit-b.padding[0]-b.padding[2]-bw_y(b))
    return limit
}

emit_mask_image :: proc(pt: ^Painter, m: Mask_Image, img: ^Img, bx, by, bw, bh: f32, surface := im.Vec2{1e6,1e6}) {
    if img == nil || img.state != .Ready || !img.is_svg || img.svg_root == nil do return
    x, y, dw, dh := mask_tile_geometry(m, f32(img.w), f32(img.h), bx, by, bw, bh)
    if dw < 0.01 || dh < 0.01 do return
    lo := im.Vec2{bx+m.clip_inset[3], by+m.clip_inset[0]}
    hi := im.Vec2{bx+bw-m.clip_inset[1], by+bh-m.clip_inset[2]}
    if m.no_clip { lo = {-1e6, -1e6}; hi = {1e6, 1e6} }
    // Keep tiling bounded by the offscreen surface rather than no-clip infinity.
    lo.x = max(lo.x, 0); lo.y = max(lo.y, 0); hi.x = min(hi.x, surface.x); hi.y = min(hi.y, surface.y)
    if !m.no_repeat[0] do x -= dw*math.ceil((x-lo.x)/dw)
    if !m.no_repeat[1] do y -= dh*math.ceil((y-lo.y)/dh)
    start_x := x
    for row := 0; row < 512 && y < hi.y; row += 1 {
        x = start_x
        for col := 0; col < 512 && x < hi.x; col += 1 {
            emit_bg_svg_tile(pt, img, {x,y}, dw, dh, lo, hi, 1)
            if m.no_repeat[0] do break
            x += dw
        }
        if m.no_repeat[1] do break
        y += dh
    }
}

apply_svg_image_mask :: proc(dst: []u8, w, h: int, m: Mask_Image, bx, by, bw, bh: f32) {
    pixels := make([]u8, w*h*4, context.temp_allocator)
    img := image_get(m.url)
    if img.state == .Ready && img.is_svg && img.svg_root != nil {
        tex := sdl2.CreateTexture(g_renderer, .ABGR8888, .TARGET, c.int(w), c.int(h))
        if tex != nil {
            defer sdl2.DestroyTexture(tex)
            prev := sdl2.GetRenderTarget(g_renderer)
            defer sdl2.SetRenderTarget(g_renderer, prev)
            sdl2.SetRenderTarget(g_renderer, tex)
            sdl2.SetRenderDrawColor(g_renderer, 0, 0, 0, 0); sdl2.RenderClear(g_renderer)
            pt: Painter
            defer delete(pt.cmds)
            emit_mask_image(&pt, m, img, bx, by, bw, bh, {f32(w),f32(h)})
            ld: im.DrawList
            ld._Data = im.GetDrawListSharedData()
            im.DrawList__ResetForNewFrame(&ld)
            defer im.DrawList__ClearFreeMemory(&ld)
            im.DrawList_PushTextureID(&ld, im.GetIO().Fonts.TexID)
            im.DrawList_PushClipRect(&ld, {0,0}, {f32(w),f32(h)}, false)
            replay_seg(pt.cmds[:], 0, &ld)
            lists := [1]^im.DrawList{&ld}
            dd := im.DrawData{Valid=true, CmdListsCount=1, CmdLists={Size=1, Capacity=1, Data=&lists[0]}, TotalVtxCount=ld.VtxBuffer.Size, TotalIdxCount=ld.IdxBuffer.Size, DisplaySize={f32(w),f32(h)}, FramebufferScale={1,1}}
            imgui_sdlr.RenderDrawData(&dd, g_renderer)
            rect := sdl2.Rect{0,0,c.int(w),c.int(h)}
            sdl2.RenderReadPixels(g_renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(pixels), c.int(w*4))
        }
    }
    apply_image_mask_pixels(dst, pixels, m.luminance)
}
