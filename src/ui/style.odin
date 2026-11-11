package ui

// Cômputo de estilo: casa as regras CSS contra cada nó do DOM e produz um
// "estilo computado" por elemento, respeitando cascata (especificidade +
// ordem), herança e o style="" inline.

import "core:strings"
import "core:strconv"
import "core:fmt"
import "core:os"
import "core:math"
import "core:mem"
import "core:unicode"
import dompkg "../dom"
import csspkg "../css"
import jspkg  "../js"

DEFAULT_TEXT :: 0x202124 // texto padrão (escuro, p/ fundo branco)

// Zoom da página (Ctrl +/-): multiplica os comprimentos ABSOLUTOS (px/pt/rem,
// tamanhos-palavra de fonte, defaults do UA) na resolução de estilo. em/%/parent
// herdam o zoom via font-size (já escalado); vw/vh e % NÃO escalam (são relativos
// ao viewport/pai). Assim o layout inteiro fica em px já-escalados e a pintura
// segue 1:1 — clique, clip, scroll e campos de texto continuam consistentes.
// Lido também pelo layout (l_default_size) e por render (block_style).
g_zoom: f32 = 1.0

// Line-height COMPUTADA (px) do elemento cujas declarações estão sendo aplicadas
// agora — a base da unidade `lh` (CSS Values 4). Vive aqui, e não como parâmetro,
// pelo mesmo motivo do g_zoom acima: o `parse_len` tem 43 pontos de chamada e a
// unidade tem de valer em TODOS (min-height, padding, inset, gap…). É gravada em
// apply_decls, que não se aninha: o apply_decls de :hover/pseudo só começa depois
// que o do elemento terminou. Zero = "ainda não sei" → o parse_len cai na
// aproximação `fs * 1.3` (o mesmo `normal` do resto do motor) em vez de descartar
// a declaração.
// ⚠️ **thread_local**: em produção `compute_styles` é sequencial, mas o runner de
// teste roda 16 pacotes de estilo AO MESMO TEMPO — sem isto, a thread vizinha
// sobrescrevia esta base entre o `line-height` e o `min-height: 1lh`, e a leitura
// caía nos 20,8px do default (16 × 1,3). Mesma raiz do M216 (a ponte ui→js).
@(private="file", thread_local)
g_cur_lh_px: f32 // (thread_local não aceita inicializador; o zero-value já é o "não sei")

// font-size COMPUTADO do elemento RAIZ (<html>) — a base da unidade `rem` (CSS
// Values §5.1.3). Era 16px fixo em três lugares, o que quebrava o truque
// `html{font-size:62.5%}` (rem = 10px), comum o bastante para deformar um site
// inteiro: no svelte.dev a fonte do hero saía 86,4px em vez de 54px.
// Vive num global pelo mesmo motivo do `g_cur_lh_px` acima — `parse_len` tem
// dezenas de call-sites e a unidade tem de valer em TODOS. É gravado uma vez por
// página, quando as declarações da raiz terminam de ser aplicadas e ANTES de
// qualquer descendente ser computado.
// ⚠️ thread_local pela mesma razão: o runner de teste computa estilo em 16
// threads ao mesmo tempo. Zero = "ainda não computei a raiz" → cai no inicial.
@(private="file", thread_local)
g_root_font_size: f32

// Base da unidade `rem`, já escalada pelo zoom (o font-size da raiz também é).
@(private="file")
rem_px :: proc() -> f32 {
    return g_root_font_size > 0 ? g_root_font_size : 16 * g_zoom
}

// Esquema de cor preferido, avaliado por `@media (prefers-color-scheme: …)`.
// Default = claro (o navegador não tem tema escuro próprio ainda); um toggle de
// UI pode ligar isto para sites com dark mode responderem.
g_prefers_dark: bool = false

// Altura do viewport do render atual (px), p/ avaliar `@media (aspect-ratio)`.
// Setada no início de compute_styles; media_matches usa vw/g_viewport_h.
// thread_local pela MESMA razão do g_cur_lh_px acima: é escrita por compute_styles,
// e o runner de teste tem 16 delas em voo.
// ⚠️ thread_local NÃO aceita inicializador, então o default de 720 saiu daqui e
// virou fallback no ponto de LEITURA (é o único).
@(thread_local)
g_viewport_h: f32

// Largura do viewport do render atual (px). Mesma disciplina do g_viewport_h e
// pela mesma razão de invariante: o `media` de um `<source>` de `<picture>` e o
// `@media` da folha NÃO podem discordar sobre "sou desktop?" — então a seleção
// de source lê daqui, e não de um parâmetro próprio. Fallback no ponto de LEITURA.
@(thread_local)
g_viewport_w: f32

// Custom properties registradas com `inherits: false` (nome + valor inicial),
// recolhidas das regras sintéticas de `@property` no início de compute_styles e
// PASSADAS por parâmetro até compute_node. ⚠️ deliberadamente NÃO é global: o
// runner de teste é multi-thread e um `[dynamic]` de pacote mutado por
// compute_styles vira corrida (a lição do M192). Vazia na esmagadora maioria dos
// sites ⇒ o laço por nó nem entra.
Noinherit_Prop :: struct { name, initial: string }

// Coletor de propriedades CSS não implementadas.
// Chame css_unknown_report() para imprimir o relatório no console.
g_css_unknown: map[string]int

// `fill`/`stroke`/`stroke-width` vindos da CASCATA (regra CSS, não do atributo
// de apresentação). Esparso: só o nó que DECLAROU alguma prop ganha um `^Svg_Css`
// no Computed (a HERANÇA pela subárvore continua sendo do painter, SvgCtx).
//
// ⚠️ M246: isto VIVIA num `map[^Node]Svg_Css` de pacote (`g_svg_css`). O runner
// de teste troca o `context.allocator` a cada @(test) (tracking), o mapa crescia
// com o alocador de um teste e era `clear`/rehashado com o do seguinte — len=1
// com iteração vazia, falha em rajadas inclusive a 1 thread. Dono agora é o
// Computed (mesmo alocador do mapa de estilos, liberado em free_styles). O
// painter não recebe o mapa: `svg_css_bind` no fim de compute_styles / no
// js_style_source_set (main thread depois do worker).
// ── border-image (css-backgrounds-3 §6) ─────────────────────────────────────
// A imagem é fatiada em 9 (4 cantos + 4 bordas + miolo) e substitui a borda.
//
// ⚠️ A fonte fica como TEXTO, e o gradiente é parseado na PINTURA. Um
// `csspkg.Gradient` tem ~350 B e o Computed é UM POR ELEMENTO — pagar isso em
// toda página por uma prop que aparece em 4 ocorrências do gap-report seria o
// erro que o M162/M29 já documentaram. Reparsear por frame um elemento raro é
// barato; carregar 350 B por elemento de toda página, não.
Bimg_Repeat :: enum u8 { Stretch, Repeat, Round, Space }
Bimg_WKind  :: enum u8 { Number, Len, Pct, Auto } // border-image-width

Border_Image :: struct {
    active: bool,
    src:    string, // url() CRUA no Computed, RESOLVIDA na Box ("" = não é url)
    grad:   string, // texto do gradiente ("" = não é gradiente)
    slice:  [4]f32, slice_pct: [4]bool, fill: bool, // t r b l
    width:  [4]f32, wkind: [4]Bimg_WKind,
    outset: [4]f32, outset_num: [4]bool,
    repeat: [2]Bimg_Repeat, // horizontal, vertical
}

// Valores INICIAIS da spec. Zero-value não serve: slice inicial é 100% e width
// inicial é 1 (múltiplo da border-width), então a struct zerada desenharia nada.
bimg_initial :: proc() -> Border_Image {
    b: Border_Image
    b.slice = {100, 100, 100, 100}; b.slice_pct = {true, true, true, true}
    b.width = {1, 1, 1, 1} // .Number = 1× a border-width do lado
    return b
}

Svg_Css :: struct {
    fill_set,   fill_none:   bool, fill:   u32, // cor CSS (0xRRGGBB), currentColor já resolvido
    stroke_set, stroke_none: bool, stroke: u32,
    sw_set: bool, sw: f32,
    fill_op_set:   bool, fill_op:   f32, // fill-opacity / stroke-opacity: só o ALFA
    stroke_op_set: bool, stroke_op: f32,
    cap_set:  bool, cap:  u8,   // stroke-linecap  (0 butt, 1 round, 2 square)
    join_set: bool, join: u8,   // stroke-linejoin (0 miter, 1 round, 2 bevel)
    rule_set: bool, evenodd: bool, // fill-rule
    // stroke-dasharray/-dashoffset. A lista já vem NORMALIZADA pelo parser do
    // painter (ímpar duplicada, `none`/erro = n 0), então quem lê não decide nada.
    dash_set: bool, dash: [MAX_DASH]f32, dash_n: int,
    doff_set: bool, doff: f32,
    mlim_set:  bool, mlim: f32,                       // stroke-miterlimit
    shape_set: bool, no_aa: bool, seg_mul: int,       // shape-rendering
    // stop-color/stop-opacity de REGRA CSS num <stop> (M225). É por aqui que as
    // duas props chegam quando o autor as declara em folha em vez de atributo.
    stop_col_set: bool, stop_col: u32,
    stop_op_set:  bool, stop_op:  f32,
}

// Fonte ATIVA do painter: o mapa de estilos do documento corrente. thread_local
// pela mesma razão do g_js_styles — o worker de fetch computa estilo numa thread
// e o paint corre na main; bind é o js_style_source_set, que já é o funil.
@(thread_local)
g_svg_css_styles: map[^dompkg.Node]Computed
@(thread_local)
g_svg_css_have: bool

svg_css_bind :: proc(styles: map[^dompkg.Node]Computed) {
    g_svg_css_styles = styles
    g_svg_css_have = true
}

svg_css_clear :: proc() {
    g_svg_css_have = false
    g_svg_css_styles = {}
}

svg_css_get :: proc(n: ^dompkg.Node) -> (Svg_Css, bool) {
    if !g_svg_css_have || n == nil do return {}, false
    c, ok := g_svg_css_styles[n]
    if !ok || c.svg_css == nil do return {}, false
    return c.svg_css^, true
}

// ── Container queries ────────────────────────────────────────────────────────
// A condição de `@container` avalia contra a LARGURA do contêiner (ancestral com
// container-type), que só existe no LAYOUT — mas o estilo é resolvido ANTES dele.
// Resolvemos em DUAS passadas, e isso é EXATO, não aproximado: `container-type`
// estabelece contenção, então o tamanho do contêiner NÃO depende do conteúdo dele
// (só dos ancestrais) — a 2ª passada mede o mesmo que a 3ª mediria.
//   1ª: sem medidas → cai no FALLBACK (viewport), que é o comportamento antigo.
//   2ª: com g_container_w preenchido pelo layout → avalia contra o contêiner.
g_container_w: map[^dompkg.Node]f32   // nó do contêiner → largura de conteúdo medida
g_container_used: map[^dompkg.Node]f32 // o que a última resolução de estilo usou
g_container_dirty: bool                // medida != usada → precisa reestilizar

container_w_clear :: proc() { clear(&g_container_w); clear(&g_container_used); g_container_dirty = false }

// Alguma regra veio de um @container? Portão da 2ª passada: página sem
// container query não paga NADA (nem o layout extra).
container_rules_present :: proc(rules: []csspkg.Rule) -> bool {
    for r in rules do if r.cq_active do return true
    return false
}

// Chamado pelo layout p/ cada caixa que É um contêiner de consulta.
container_w_record :: proc(n: ^dompkg.Node, w: f32) {
    if n == nil do return
    old, had := g_container_w[n]
    if !had || abs(old - w) > 0.5 {
        g_container_w[n] = w
        // só suja se o estilo já foi resolvido com um valor DIFERENTE
        if used, uok := g_container_used[n]; !uok || abs(used - w) > 0.5 do g_container_dirty = true
    }
}

// A regra `r` (de um bloco @container) casa para o nó `n`? Sobe até o contêiner
// mais próximo (com nome, se a consulta o exigir) e testa a largura MEDIDA.
@(private="file")
container_matches :: proc(r: csspkg.Rule, n: ^dompkg.Node, styles: ^map[^dompkg.Node]Computed, viewport_w: f32) -> bool {
    for p := (styles != nil ? n.parent : nil); p != nil; p = p.parent {
        c, ok := styles[p]
        if !ok || !c.container_inline do continue
        if r.cq_name != "" && c.container_name != r.cq_name do continue
        w, measured := g_container_w[p]
        if !measured do break // contêiner achado mas ainda não medido → fallback
        g_container_used[p] = w
        if r.cq_min >= 0 && w < r.cq_min do return false
        if r.cq_max >= 0 && w > r.cq_max do return false
        return true
    }
    // Sem contêiner medido: FALLBACK para o viewport (o proxy que já existia antes
    // desta feature). Per-spec deveria não casar, mas não casar aqui APAGARIA
    // estilos que hoje aparecem — e a 1ª passada sempre cai neste caminho.
    if r.cq_min >= 0 && viewport_w < r.cq_min do return false
    if r.cq_max >= 0 && viewport_w > r.cq_max do return false
    return true
}

// Um item de dasharray vindo de REGRA CSS: `parse_len` é `@(private="file")`
// aqui, então o painter (svg.odin) recebe ESTE proc como conversor. Porcentagem
// é rejeitada — precisaria da diagonal do viewport, que não threadamos.
@(private="file")
svg_css_len :: proc(tok: string, fs, vw, vh: f32) -> (f32, bool) {
    px, pct, ok := parse_len(tok, fs, vw, vh)
    return px, ok && !pct
}

// Lê fill/stroke/stroke-width das declarações que venceram a cascata. currentColor
// resolve contra a cor JÁ computada do próprio elemento (mais correto que o `cur`
// do painter, que é a cor do <svg> raiz).
@(private="file")
collect_svg_css :: proc(comp: ^Computed, decls: map[string]string, vars: map[string]string, vw, vh: f32) {
    e: Svg_Css
    any := false
    paint :: proc(v: string, cur: u32, set, none: ^bool, col: ^u32) -> bool {
        t := strings.trim_space(v)
        if t == "" do return false
        if strings.equal_fold(t, "none")         { set^ = true; none^ = true; return true }
        if strings.equal_fold(t, "currentcolor") { set^ = true; col^ = cur;   return true }
        if c, ok := csspkg.parse_color(t); ok    { set^ = true; col^ = c;     return true }
        return false // url(#grad)/context-fill: sem suporte, deixa o atributo valer
    }
    if v, ok := decls["fill"];   ok do any |= paint(resolve_var(v, vars), comp.color, &e.fill_set,   &e.fill_none,   &e.fill)
    if v, ok := decls["stroke"]; ok do any |= paint(resolve_var(v, vars), comp.color, &e.stroke_set, &e.stroke_none, &e.stroke)
    if v, ok := decls["stroke-width"]; ok {
        if px, pct, k := parse_len(resolve_var(v, vars), comp.font_size, vw, vh); k && !pct {
            e.sw_set = true; e.sw = px; any = true
        }
    }
    if v, ok := decls["fill-opacity"]; ok {
        if o, k := svg_opacity(resolve_var(v, vars)); k { e.fill_op_set = true; e.fill_op = o; any = true }
    }
    if v, ok := decls["stroke-opacity"]; ok {
        if o, k := svg_opacity(resolve_var(v, vars)); k { e.stroke_op_set = true; e.stroke_op = o; any = true }
    }
    if v, ok := decls["stroke-linecap"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "butt":   e.cap_set = true; e.cap = 0; any = true
        case "round":  e.cap_set = true; e.cap = 1; any = true
        case "square": e.cap_set = true; e.cap = 2; any = true
        }
    }
    if v, ok := decls["stroke-linejoin"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "miter": e.join_set = true; e.join = 0; any = true
        case "round": e.join_set = true; e.join = 1; any = true
        case "bevel": e.join_set = true; e.join = 2; any = true
        }
    }
    if v, ok := decls["stop-color"]; ok {
        t := strings.trim_space(resolve_var(v, vars))
        if strings.equal_fold(t, "currentcolor") { e.stop_col_set = true; e.stop_col = comp.color; any = true }
        else if c, k := csspkg.parse_color(t); k { e.stop_col_set = true; e.stop_col = c; any = true }
    }
    if v, ok := decls["stop-opacity"]; ok {
        if o, k := svg_opacity(resolve_var(v, vars)); k { e.stop_op_set = true; e.stop_op = o; any = true }
    }
    if v, ok := decls["fill-rule"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "nonzero" { e.rule_set = true; e.evenodd = false; any = true }
        if lv == "evenodd" { e.rule_set = true; e.evenodd = true;  any = true }
    }
    if v, ok := decls["stroke-dasharray"]; ok {
        // `svg_css_len`: mesma convenção de unidade do stroke-width de REGRA (ver
        // svg_parse_dasharray). `none` grava n=0 — que é DISTINTO de não declarar,
        // pois precisa CANCELAR um dasharray herdado do <g> pai.
        if a, n, k := svg_parse_dasharray(resolve_var(v, vars), svg_css_len, comp.font_size, vw, vh); k {
            e.dash_set = true; e.dash = a; e.dash_n = n; any = true
        }
    }
    if v, ok := decls["stroke-dashoffset"]; ok {
        if px, pct, k := parse_len(resolve_var(v, vars), comp.font_size, vw, vh); k && !pct {
            e.doff_set = true; e.doff = px; any = true
        }
    }
    if v, ok := decls["stroke-miterlimit"]; ok {
        // número PURO (não é comprimento): é uma RAZÃO contra a espessura.
        // < 1 é erro per-spec → declaração ignorada, o herdado vale.
        if f, k := strconv.parse_f64(strings.trim_space(resolve_var(v, vars))); k && f >= 1 {
            e.mlim_set = true; e.mlim = f32(f); any = true
        }
    }
    if v, ok := decls["shape-rendering"]; ok {
        if na, sm, k := svg_parse_shape_rendering(resolve_var(v, vars)); k {
            e.shape_set = true; e.no_aa = na; e.seg_mul = sm; any = true
        }
    }
    if any {
        p := new(Svg_Css)
        p^ = e
        comp.svg_css = p
    }
}

css_prop_is_known :: proc(p: string) -> bool {
    switch p {
    case "color","background-color","background-image","background",
         "background-size","background-repeat","background-position",
         "background-position-x","background-position-y",
         "object-fit","overflow","overflow-x","overflow-y","float","clear","visibility","direction",
         "font-weight","font-style","display","font-size","font-family","font","position",
         "top","right","bottom","left",
         "line-height","border-radius","text-align","text-align-last",
         "text-decoration-line","text-decoration","-webkit-text-decoration",
         "text-decoration-color","text-decoration-style","text-decoration-thickness","quotes",
         "text-underline-offset","text-underline-position","text-decoration-skip-ink",
         "counter-reset","counter-increment",
         "cursor","caret-color","object-position","vertical-align","scroll-behavior",
         "scroll-margin","scroll-margin-top","scroll-margin-right","scroll-margin-bottom","scroll-margin-left",
         "scroll-margin-block","scroll-margin-inline","scroll-margin-block-start","scroll-margin-block-end",
         "scroll-margin-inline-start","scroll-margin-inline-end",
         "scroll-padding","scroll-padding-top","scroll-padding-right","scroll-padding-bottom","scroll-padding-left",
         "scroll-padding-block","scroll-padding-inline","scroll-padding-block-start","scroll-padding-block-end",
         "scroll-padding-inline-start","scroll-padding-inline-end",
         "appearance","-webkit-appearance","-moz-appearance","resize",
         "pointer-events","user-select","-webkit-user-select","-moz-user-select","-ms-user-select",
         "transition","transition-duration","transition-property","transition-timing-function","transition-delay",
         "animation","animation-name","animation-duration","animation-delay",
         "animation-iteration-count","animation-direction","animation-timing-function","animation-fill-mode","animation-play-state",
         "margin","margin-top","margin-right","margin-bottom","margin-left",
         "padding","padding-top","padding-right","padding-bottom","padding-left",
         "border","border-width","border-color","border-style",
         "border-top-width","border-right-width","border-bottom-width","border-left-width",
         "border-top-color","border-right-color","border-bottom-color","border-left-color",
         "border-top-style","border-right-style","border-bottom-style","border-left-style",
         "border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius",
         "outline","outline-width","outline-color","outline-style","outline-offset",
         "border-top","border-right","border-bottom","border-left",
         "width","max-width","min-width","height","max-height","min-height",
         "box-sizing","aspect-ratio",
         "flex-direction","flex-wrap","justify-content","align-items","align-self",
         "align-content","justify-items","justify-self",
         "place-items","place-content","place-self",
         "gap","row-gap","column-gap",
         "column-count","column-width","columns","column-rule","column-rule-color","column-rule-width","column-rule-style",
         "break-before","break-after","break-inside","page-break-before","page-break-after","page-break-inside",
         "grid-template-columns","grid-template-rows","grid-template-areas",
         "grid","grid-template",
         "grid-auto-flow","grid-auto-rows","grid-auto-columns",
         "container","container-type","container-name",
         "content-visibility","contain-intrinsic-size","contain-intrinsic-width","contain-intrinsic-height",
         "contain-intrinsic-block-size","contain-intrinsic-inline-size",
         "grid-column","grid-row","grid-area",
         "border-collapse","border-spacing","table-layout","caption-side","empty-cells",
         "border-image","border-image-source","border-image-slice","border-image-width",
         "border-image-outset","border-image-repeat","-webkit-border-image",
         "flex-grow","flex-shrink","flex-basis","flex","order",
         "inset","z-index","opacity","isolation","mix-blend-mode","filter","backdrop-filter","-webkit-backdrop-filter","transform","transform-origin","box-shadow","text-shadow",
         "clip-path","-webkit-clip-path","clip",
         "mask","mask-image","-webkit-mask","-webkit-mask-image",
         "mask-size","-webkit-mask-size","mask-position","-webkit-mask-position",
         "mask-repeat","-webkit-mask-repeat","mask-mode","mask-clip","-webkit-mask-clip",
         "mask-origin","-webkit-mask-origin","mask-composite","-webkit-mask-composite","mask-type",
         "translate","rotate","scale",
         // 3D achatado: o lado (frente × verso) é honrado; a profundidade não.
         "backface-visibility","transform-style",
         "counter-set","accent-color",
         "all",
         "contain","will-change","offset-path","offset-distance","offset-rotate",
         "background-clip","-webkit-background-clip","background-origin","background-attachment","-webkit-text-fill-color",
         "font-kerning","letter-spacing","word-spacing","text-indent","text-transform","white-space","content",
         "overflow-wrap","word-wrap","word-break","text-overflow",
         "-webkit-line-clamp","line-clamp","-webkit-box-orient",
         "list-style","list-style-type","list-style-position","list-style-image",
         // Reconhecidas mas INERTES neste motor (sem engine de touch/hifenização/
         // justify/scroll-chaining/ajuste-de-fonte): recognize-only, p/ não poluírem
         // o relatório de props desconhecidas. Comportamento real fica p/ o futuro.
         "image-rendering","hyphens","-webkit-hyphens","touch-action","text-justify",
         "font-feature-settings","font-variation-settings","font-optical-sizing",
         "overscroll-behavior","overscroll-behavior-x","overscroll-behavior-y",
         "overscroll-behavior-block","overscroll-behavior-inline",
         "text-size-adjust","-webkit-text-size-adjust","color-scheme",
         "print-color-adjust","-webkit-print-color-adjust","forced-color-adjust",
         "text-rendering","-webkit-font-smoothing","-moz-osx-font-smoothing",
         "perspective","perspective-origin",
         "scroll-snap-type","scroll-snap-align","scroll-snap-stop",
         "overflow-anchor","tab-size","-moz-tab-size","hanging-punctuation",
         "text-emphasis","text-emphasis-color","text-emphasis-style","text-emphasis-position",
         "font-variant","font-variant-caps","font-variant-numeric","font-variant-ligatures",
         "font-stretch","font-synthesis","writing-mode","text-orientation","unicode-bidi",
         // SVG: props de apresentação vindas de REGRA CSS. O que AINDA falta da
         // família (paint-order, vector-effect, text-rendering…) segue fora
         // desta lista de propósito, p/ continuar aparecendo no gap-miner.
         "fill","stroke","stroke-width",
         "fill-opacity","stroke-opacity","stroke-linecap","stroke-linejoin","fill-rule",
         "stroke-dasharray","stroke-dashoffset","stroke-miterlimit","shape-rendering",
         // <stop> de gradiente SVG (M225)
         "stop-color","stop-opacity",
         // Estilo de barra de rolagem / realce de toque: o renderer não tem
         // scrollbar estilizável nem eventos de toque → inertes por design.
         "scrollbar-width","scrollbar-color","scrollbar-gutter",
         "-webkit-tap-highlight-color","-ms-overflow-style","-webkit-overflow-scrolling",
         // text-wrap: balance/pretty precisam de quebra-de-linha com lookahead
         "text-wrap","text-wrap-mode","text-wrap-style",
         // aliases/legados traduzidos em collect_decls (aqui só p/ o caso de
         // apply_decls ser chamado direto, sem passar pela tradução)
         "flex-flow","grid-gap","grid-column-gap","grid-row-gap",
         "grid-column-start","grid-column-end","grid-row-start","grid-row-end":
        return true
    }
    return false
}

css_unknown_report :: proc() {
    if len(g_css_unknown) == 0 do return
    // ordena por frequência (selection sort simples)
    keys := make([]string, len(g_css_unknown), context.temp_allocator)
    i := 0; for k in g_css_unknown { keys[i] = k; i += 1 }
    for a := 0; a < len(keys); a += 1 {
        for b := a + 1; b < len(keys); b += 1 {
            if g_css_unknown[keys[b]] > g_css_unknown[keys[a]] {
                keys[a], keys[b] = keys[b], keys[a]
            }
        }
    }
    buf: strings.Builder
    strings.builder_init(&buf, context.allocator)
    defer strings.builder_destroy(&buf)
    strings.write_string(&buf, "\n=== CSS props nao implementadas (por frequencia) ===\n")
    for k in keys {
        fmt.sbprintf(&buf, "  %-35s %d\n", k, g_css_unknown[k])
    }
    strings.write_string(&buf, "====================================================\n")
    content := strings.to_string(buf)
    _ = os.write_entire_file("C:\\Users\\Adm\\Desktop\\browser\\css_unknown.txt", content)
}

// Um comprimento de clip-path: "50%" → {0.5, true}; "10px"/"1em" → {px, false}.
@(private="file")
clip_len :: proc(s: string, fs, vw, vh: f32) -> (Clip_Val, bool) {
    t := strings.trim_space(s)
    if t == "" do return {}, false
    if strings.has_suffix(t, "%") {
        if n, k := strconv.parse_f64(strings.trim_space(t[:len(t) - 1])); k do return Clip_Val{f32(n) / 100, true}, true
        return {}, false
    }
    if px, _, k := parse_len(t, fs, vw, vh); k do return Clip_Val{px, false}, true
    return {}, false
}

// Posição de `at <x> [<y>]` (circle/ellipse). Keywords viram frações; 1 valor → y=50%.
@(private="file")
clip_pos :: proc(toks: []string, fs, vw, vh: f32) -> (cx, cy: Clip_Val) {
    cx = Clip_Val{0.5, true}; cy = Clip_Val{0.5, true}
    axis :: proc(tok: string, fs, vw, vh: f32) -> (Clip_Val, bool) {
        switch strings.to_lower(strings.trim_space(tok), context.temp_allocator) {
        case "left", "top":     return Clip_Val{0, true}, true
        case "right", "bottom": return Clip_Val{1, true}, true
        case "center":          return Clip_Val{0.5, true}, true
        }
        return clip_len(tok, fs, vw, vh)
    }
    if len(toks) >= 1 { if v, k := axis(toks[0], fs, vw, vh); k do cx = v }
    if len(toks) >= 2 { if v, k := axis(toks[1], fs, vw, vh); k do cy = v }
    return
}

// clip-path: none | inset() | circle() | ellipse() | polygon(). url()/path()/
// geometry-box não suportados → None (sem recorte).
parse_clip_path :: proc(comp: ^Computed, value: string, fs, vw, vh: f32) {
    comp.clip_path = {}
    s := strings.trim_space(value)
    lo := strings.to_lower(s, context.temp_allocator)
    if s == "" || lo == "none" do return
    open := strings.index_byte(s, '(')
    if open < 0 do return
    close := strings.last_index_byte(s, ')')
    if close <= open do return
    fn   := strings.to_lower(strings.trim_space(s[:open]), context.temp_allocator)
    args := strings.trim_space(s[open + 1:close])

    switch fn {
    case "inset":
        // inset( <len>{1,4} [round <len>] )
        body := args
        round_s := ""
        if ri := strings.index(strings.to_lower(body, context.temp_allocator), "round"); ri >= 0 {
            round_s = strings.trim_space(body[ri + 5:])
            body = strings.trim_space(body[:ri])
        }
        toks := strings.fields(body, context.temp_allocator)
        if len(toks) == 0 do return
        vals: [4]Clip_Val
        for i in 0 ..< 4 {
            src := i // 1 valor = todos; 2 = t/b, l/r; 3 = t, l/r, b; 4 = t r b l
            switch len(toks) {
            case 1: src = 0
            case 2: src = i % 2 == 0 ? 0 : 1
            case 3: src = i == 0 ? 0 : (i == 2 ? 2 : 1)
            case:   src = min(i, len(toks) - 1)
            }
            v, k := clip_len(toks[src], fs, vw, vh)
            if !k do return
            vals[i] = v
        }
        comp.clip_path.kind  = .Inset
        comp.clip_path.inset = vals
        if round_s != "" {
            rt := strings.fields(round_s, context.temp_allocator)
            if len(rt) >= 1 { if r, k := clip_len(rt[0], fs, vw, vh); k do comp.clip_path.round = r }
        }
    case "circle", "ellipse":
        // circle( <r> [at <pos>] ) | ellipse( <rx> <ry> [at <pos>] )
        body := args
        pos_toks: []string
        if ai := strings.index(strings.to_lower(body, context.temp_allocator), " at "); ai >= 0 {
            pos_toks = strings.fields(strings.trim_space(body[ai + 4:]), context.temp_allocator)
            body = strings.trim_space(body[:ai])
        } else if strings.has_prefix(strings.to_lower(body, context.temp_allocator), "at ") {
            pos_toks = strings.fields(strings.trim_space(body[3:]), context.temp_allocator)
            body = ""
        }
        rt := strings.fields(body, context.temp_allocator)
        if fn == "circle" {
            comp.clip_path.kind = .Circle
            comp.clip_path.rx = Clip_Val{0.5, true} // default ≈ closest-side
            if len(rt) >= 1 { if r, k := clip_len(rt[0], fs, vw, vh); k do comp.clip_path.rx = r }
            comp.clip_path.ry = comp.clip_path.rx
        } else {
            comp.clip_path.kind = .Ellipse
            comp.clip_path.rx = Clip_Val{0.5, true}
            comp.clip_path.ry = Clip_Val{0.5, true}
            if len(rt) >= 1 { if r, k := clip_len(rt[0], fs, vw, vh); k do comp.clip_path.rx = r }
            if len(rt) >= 2 { if r, k := clip_len(rt[1], fs, vw, vh); k do comp.clip_path.ry = r }
        }
        comp.clip_path.cx, comp.clip_path.cy = clip_pos(pos_toks, fs, vw, vh)
    case "polygon":
        // polygon( [<fill-rule>,]? <x> <y> [, <x> <y>]* )
        parts := strings.split(args, ",", context.temp_allocator)
        n := 0
        for p in parts {
            if n >= CLIP_MAX_PTS do break
            pt := strings.fields(strings.trim_space(p), context.temp_allocator)
            if len(pt) < 2 do continue // pula fill-rule (nonzero/evenodd)
            x, kx := clip_len(pt[0], fs, vw, vh)
            y, ky := clip_len(pt[1], fs, vw, vh)
            if !kx || !ky do continue
            comp.clip_path.pts[n] = {x, y}
            n += 1
        }
        if n < 3 do return // polígono degenerado → sem recorte
        comp.clip_path.kind  = .Polygon
        comp.clip_path.n_pts = n
    }
}

// `clip` (legado, CSS2): clip: rect(<top>, <right>, <bottom>, <left>) — recorta a
// caixa a um retângulo cujas ARESTAS são distâncias da origem (top-left) do
// border-box: top/bottom medem do topo; right/left medem da esquerda. Região
// visível = x∈[left,right], y∈[top,bottom]. `auto` = aresta da caixa. Separadores
// podem ser vírgulas OU espaços (a sintaxe antiga aceita ambos). Reusa a máquina
// de clip-path como kind `.Rect`; `auto` é codificado em Clip_Val{pct=true} (rect()
// só usa comprimentos, nunca %, então pct fica livre p/ marcar auto).
// ⚠️ per-spec `clip` só vale em elementos absolutamente posicionados; aplicamos
// sempre (uso real = padrão `.sr-only`, sempre com position:absolute).
parse_clip_rect :: proc(comp: ^Computed, value: string, fs, vw, vh: f32) {
    s := strings.trim_space(value)
    lo := strings.to_lower(s, context.temp_allocator)
    if s == "" || lo == "auto" || lo == "none" do return
    open := strings.index_byte(s, '(')
    if open < 0 do return
    close := strings.last_index_byte(s, ')')
    if close <= open do return
    fn := strings.to_lower(strings.trim_space(s[:open]), context.temp_allocator)
    if fn != "rect" do return
    args := strings.trim_space(s[open + 1:close])
    // aceita "t, r, b, l" ou "t r b l"
    toks: []string
    if strings.contains(args, ",") {
        toks = strings.split(args, ",", context.temp_allocator)
    } else {
        toks = strings.fields(args, context.temp_allocator)
    }
    if len(toks) != 4 do return
    vals: [4]Clip_Val // top, right, bottom, left
    n_auto := 0
    for i in 0 ..< 4 {
        t := strings.to_lower(strings.trim_space(toks[i]), context.temp_allocator)
        if t == "auto" || t == "" {
            vals[i] = Clip_Val{0, true} // pct=true marca "auto"
            n_auto += 1
            continue
        }
        if px, _, k := parse_len(t, fs, vw, vh); k {
            vals[i] = Clip_Val{px, false}
        } else {
            return // valor inválido → ignora a declaração inteira
        }
    }
    if n_auto == 4 do return // rect(auto,auto,auto,auto) = sem recorte
    comp.clip_path.kind  = .Rect
    comp.clip_path.inset = vals
}

// mask-image / -webkit-mask-image (e o shorthand `mask`): extrai o PRIMEIRO
// gradiente do valor. `none`/vazio/url()/imagem raster → sem máscara. Reusa
// csspkg.parse_gradient (mesmo parser do background linear/radial/conic).
parse_mask_image :: proc(comp: ^Computed, value: string) {
    comp.mask_grad = {}
    s := strings.trim_space(value)
    lo := strings.to_lower(s, context.temp_allocator)
    if s == "" || lo == "none" do return
    // isola o 1º "*-gradient(...)" (o shorthand `mask` pode ter size/repeat/etc.
    // ao redor). Acha "gradient(" e recua até o início do nome da função.
    gi := strings.index(lo, "gradient(")
    if gi < 0 do return // sem gradiente (url()/imagem) → sem máscara
    start := gi
    for start > 0 && (is_ident_byte(s[start - 1])) do start -= 1
    // acha o ')' que casa a partir do '(' da função
    open := strings.index_byte(s[start:], '(')
    if open < 0 do return
    open += start
    depth := 0
    close := -1
    scan: for i in open ..< len(s) {
        c := s[i]
        if c == '(' {
            depth += 1
        } else if c == ')' {
            depth -= 1
            if depth == 0 { close = i; break scan }
        }
    }
    if close < 0 do return
    if g, k := csspkg.parse_gradient(s[start:close + 1]); k {
        comp.mask_grad = g
    }
}

// byte de um identificador CSS (nome de função de gradiente): letra, dígito ou '-'.
@(private="file")
is_ident_byte :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '-'
}

// filter: <fn>(<arg>) <fn>(<arg>) … — parseia até MAX_FILTERS funções em ordem.
parse_filter :: proc(comp: ^Computed, v: string, fs, vw, vh: f32) {
    parse_filter_list(&comp.filters, &comp.n_filters, v, fs, comp.color)
}

// backdrop-filter: MESMA gramática do filter, mas aplicada ao BACKDROP (o que já
// foi pintado atrás do elemento) em vez dos pixels próprios — frosted glass.
parse_backdrop_filter :: proc(comp: ^Computed, v: string, fs: f32) {
    parse_filter_list(&comp.backdrop_filters, &comp.n_backdrop, v, fs, comp.color)
}

// Núcleo compartilhado por filter e backdrop-filter: parseia a lista de funções
// em `out`/`n_out`. `cur` = currentColor (p/ drop-shadow).
@(private="file")
parse_filter_list :: proc(out: ^[MAX_FILTERS]Filter_Op, n_out: ^int, v: string, fs: f32, cur: u32) {
    n_out^ = 0
    s := strings.trim_space(strings.to_lower(v, context.temp_allocator))
    if s == "" || s == "none" do return
    for len(s) > 0 && n_out^ < MAX_FILTERS {
        op := strings.index_byte(s, '(')
        if op < 0 do break
        // acha o ')' que CASA (parênteses balanceados — drop-shadow pode ter rgb(...))
        depth := 0; cl := -1
        for i in op ..< len(s) {
            if s[i] == '(' do depth += 1
            else if s[i] == ')' { depth -= 1; if depth == 0 { cl = i; break } }
        }
        if cl < 0 do break
        name := strings.trim_space(s[:op])
        arg  := strings.trim_space(s[op + 1:cl])
        s = strings.trim_space(s[cl + 1:])
        fo: Filter_Op
        ok := true
        switch name {
        case "blur":        fo = {kind = .Blur,       amount = filter_px(arg, fs)}
        case "brightness":  fo = {kind = .Brightness, amount = filter_num(arg, 1)}
        case "contrast":    fo = {kind = .Contrast,   amount = filter_num(arg, 1)}
        case "grayscale":   fo = {kind = .Grayscale,  amount = filter_num(arg, 1)}
        case "sepia":       fo = {kind = .Sepia,      amount = filter_num(arg, 1)}
        case "saturate":    fo = {kind = .Saturate,   amount = filter_num(arg, 1)}
        case "invert":      fo = {kind = .Invert,     amount = filter_num(arg, 1)}
        case "opacity":     fo = {kind = .Opacity,    amount = filter_num(arg, 1)}
        case "hue-rotate":  fo = {kind = .HueRotate,  amount = filter_deg(arg)}
        case "drop-shadow": fo = parse_drop_shadow(arg, fs, cur)
        case: ok = false // função desconhecida: ignora, segue as demais
        }
        if ok {
            out[n_out^] = fo
            n_out^ += 1
        }
    }
}

// drop-shadow(<dx> <dy> [blur] [cor]) — offsets/blur em px, cor via parse_color
// (default = currentColor = comp.color). Tokeniza por espaços mantendo grupos
// entre parênteses (ex.: rgb(0,0,0) fica um token só).
@(private="file")
parse_drop_shadow :: proc(arg: string, fs: f32, def_color: u32) -> Filter_Op {
    fo := Filter_Op{kind = .DropShadow, color = def_color}
    li := 0
    i := 0
    for i < len(arg) {
        for i < len(arg) && arg[i] == ' ' do i += 1
        if i >= len(arg) do break
        start := i; depth := 0
        for i < len(arg) && (arg[i] != ' ' || depth > 0) {
            if arg[i] == '(' do depth += 1
            else if arg[i] == ')' do depth -= 1
            i += 1
        }
        tok := arg[start:i]
        is_len := len(tok) > 0 && (tok[0] >= '0' && tok[0] <= '9' || tok[0] == '-' || tok[0] == '+' || tok[0] == '.')
        if is_len && li < 3 {
            v := filter_px(tok, fs)
            switch li {
            case 0: fo.dx = v
            case 1: fo.dy = v
            case 2: fo.amount = v // blur
            }
            li += 1
        } else {
            if c, cok := csspkg.parse_color(tok); cok do fo.color = c
        }
    }
    return fo
}

// número/porcentagem de filtro: "50%"→0.5, "1.2"→1.2, ""→default.
@(private="file")
filter_num :: proc(s: string, def: f32) -> f32 {
    t := strings.trim_space(s)
    if t == "" do return def
    if strings.has_suffix(t, "%") {
        if f, ok := strconv.parse_f64(t[:len(t) - 1]); ok do return f32(f) / 100
        return def
    }
    if f, ok := strconv.parse_f64(t); ok do return f32(f)
    return def
}

// comprimento do blur em px (px/em/rem; número puro = px).
@(private="file")
filter_px :: proc(s: string, fs: f32) -> f32 {
    t := strings.trim_space(s)
    if strings.has_suffix(t, "px")  { if f, ok := strconv.parse_f64(t[:len(t) - 2]); ok do return f32(f) }
    else if strings.has_suffix(t, "rem") { if f, ok := strconv.parse_f64(t[:len(t) - 3]); ok do return f32(f) * rem_px() }
    else if strings.has_suffix(t, "em")  { if f, ok := strconv.parse_f64(t[:len(t) - 2]); ok do return f32(f) * fs }
    else { if f, ok := strconv.parse_f64(t); ok do return f32(f) }
    return 0
}

// ângulo p/ graus (hue-rotate): deg/grad/rad/turn.
@(private="file")
filter_deg :: proc(s: string) -> f32 {
    t := strings.trim_space(s)
    mul: f32 = 1
    num := t
    if      strings.has_suffix(t, "grad") { mul = 0.9;          num = t[:len(t) - 4] }
    else if strings.has_suffix(t, "turn") { mul = 360;          num = t[:len(t) - 4] }
    else if strings.has_suffix(t, "rad")  { mul = 57.29577951;  num = t[:len(t) - 3] }
    else if strings.has_suffix(t, "deg")  { mul = 1;            num = t[:len(t) - 3] }
    if f, ok := strconv.parse_f64(strings.trim_space(num)); ok do return f32(f) * mul
    return 0
}

Unicode_Bidi :: enum u8 { Normal, Embed, Isolate, Override, Isolate_Override, Plaintext }
Bidi_Scope :: struct { node: ^dompkg.Node, mode: Unicode_Bidi, direction: Directionality }

Writing_Mode :: enum u8 { Horizontal, Vertical_Rl, Vertical_Lr }
Text_Orientation :: enum u8 { Mixed, Upright, Sideways }

Text_Align :: enum u8 { Left, Center, Right, Justify, Start, End, Match_Parent }

align_physical :: proc(a: Text_Align, d: Directionality) -> Text_Align {
    if a == .Start || a == .Match_Parent do return d == .Rtl ? .Right : .Left
    if a == .End do return d == .Rtl ? .Left : .Right
    return a
}
// text-decoration-style: como a linha é traçada.
Deco_Style :: enum u8 { Solid, Double, Dotted, Dashed, Wavy }
// sentinela p/ deco_color "não definido" (usa a cor do texto). 0xFFFFFFFF = branco
// totalmente transparente no nosso formato 0xAARRGGBB → nunca é uma cor real.
DECO_UNSET :: u32(0xFFFFFFFF)
// `transparent` no nosso esquema de cor. O byte alto é o alpha com a convenção
// **0 = OPACO** (retrocompat com 0xRRGGBB), então alpha exato 0 NÃO é
// representável; byte 1 = 1/255 ≈ 0,4% de opacidade, imperceptível. Já era o
// valor usado por borda/outline transparente — agora com nome.
COLOR_TRANSPARENT :: u32(0x01000000)
// Decoração de texto que flui pela linha (propaga da caixa decoradora p/ o run).
Deco :: struct {
    underline, overline, strike: bool,
    color: u32,        // DECO_UNSET = usa a cor do texto
    style: Deco_Style, // solid/double/dotted/dashed/wavy
    thick: f32,        // espessura em px (0 = auto)
    offset: f32,       // text-underline-offset em px (afasta a linha do texto)
    under:  bool,      // text-underline-position: under (linha mais baixa)
}
deco_of :: proc(c: Computed) -> Deco {
    return Deco{c.underline, c.overline, c.strike, c.deco_color, c.deco_style, c.deco_thick, c.underline_offset, c.underline_under}
}
Box_Sizing :: enum u8 { Content, Border }
Flex_Dir   :: enum u8 { Row, Column }
Flex_Just  :: enum u8 { Start, Center, End, Between, Around, Evenly }
Flex_Align :: enum u8 { Stretch, Start, Center, End, Baseline, LastBaseline }
Position   :: enum u8 { Static, Relative, Absolute, Fixed, Sticky }
// InlineStart/InlineEnd = valores LÓGICOS (css-logical); compute_node os resolve
// p/ Left/Right conforme a direção do elemento antes do layout (que só vê físico).
Float_Side :: enum u8 { None, Left, Right, InlineStart, InlineEnd }
Clear_Side :: enum u8 { None, Left, Right, Both, InlineStart, InlineEnd }
// font-weight: o NÚMERO do CSS (1..1000). ⚠️ zero-value = `normal` (400): todo
// Computed nasce zerado, então LEIA SEMPRE por `fw_css`, nunca o campo cru.
//
// Era `enum {Regular, Semi, Bold}` — 3 degraus que bastavam p/ as faces do
// SISTEMA, mas jogavam fora o peso pedido antes de ele chegar à @font-face:
// numa fonte VARIÁVEL (`font-weight: 100 900`) o 300 saía igual ao 400 e o 900
// igual ao 700 (animate.style, 10/11/2026). Agora o número vai inteiro até o
// `fontface_pick`; só a escolha da face EMBUTIDA quantiza, por `fw_class`.
Font_Weight :: distinct u16
FW_NORMAL :: Font_Weight(400)
FW_BOLD   :: Font_Weight(700)

fw_css :: #force_inline proc "contextless" (w: Font_Weight) -> int {
    return w == 0 ? 400 : int(w)
}

// Face EMBUTIDA que serve um peso. A Segoe UI tem 400/600/700 carregadas (a
// Light/Black existem no Windows mas custam ~4 MB de atlas cada e são raras em
// texto de site). Regra de matching do CSS (Fonts 4 §5.2.1) sobre {400,600,700}:
//   ≤500 → 400  (alvo 400..500 procura até 500 subindo e, não achando, DESCE;
//                abaixo de 400 desce e, sem face light, sobe p/ a 400)
//   501..600 → 600   (acima de 500: o menor peso ≥ alvo)
//   >600 → 700       (e acima de 700 desce p/ a mais pesada que há)
// Verificado lado a lado com o Chrome: 300/400/500 idênticos, só o 600 engrossa.
Weight_Class :: enum u8 { Regular, Semi, Bold }
fw_class :: proc "contextless" (w: Font_Weight) -> Weight_Class {
    v := fw_css(w)
    if v <= 500 do return .Regular
    if v <= 600 do return .Semi
    return .Bold
}
Bg_Size    :: enum u8 { Auto, Cover, Contain }
Bg_Clip    :: enum u8 { Border, Padding, Content } // área de pintura do fundo (default border-box)
// Uma camada de `background-image` (a propriedade aceita LISTA separada por
// vírgula: `radial-gradient(…), url(x), linear-gradient(…)`).
//
// A camada 0 mora nos campos diretos do Computed/Box (grad/bg_img/bg_size/…):
// é o caminho SEM alocação, e é o de praticamente todo elemento. As demais vão
// p/ `bg_extra`, FORA da linha — um Gradient tem ~350 B e reservar um array
// fixo por nó seria caro em memória (a lição do M162).
//
// ⚠️ ORDEM CSS: a PRIMEIRA camada da lista fica POR CIMA. `bg_extra` guarda as
// camadas 1..N-1 em ordem de documento, então o paint as percorre DE TRÁS PRA
// FRENTE e só então pinta a camada 0. O background-color fica embaixo de todas.
Bg_Layer :: struct {
    grad:   csspkg.Gradient,
    img:    string, // url() da camada (temp no Computed, resolvida/owned na Box)
    pos_x, pos_y: f32,
    size:   Bg_Size,
    repeat: bool,
}
Obj_Fit    :: enum u8 { Fill, Cover, Contain, None }
// Valor de `overflow` de UM eixo. Precisa ser o valor da spec (e não o par de
// bools que o layout consome) porque a BLOCKIFICAÇÃO do css-overflow-3 §3.1 olha
// os dois eixos juntos: `visible` ao lado de hidden/scroll/auto vira `auto`, mas
// ao lado de `clip` continua `visible`.
Ovf_Kind   :: enum u8 { Visible, Clip, Hidden, Scroll, Auto }
// cursor: subconjunto mapeável aos cursores do ImGui/SDL. Auto = padrão (seta).
Cursor_Kind :: enum u8 { Auto, Pointer, Text, Move, NotAllowed, Progress }
// resize (css-ui §5.2): em quais eixos o USUÁRIO pode redimensionar o elemento
// arrastando a alça do canto inferior direito. Não herda; None é o zero-value.
// `block`/`inline` são as grafias lógicas (horizontal-tb: block=vertical).
Resize_Dir :: enum u8 { None, Both, Horizontal, Vertical }
// vertical-align de itens inline. text-top/text-bottom aproximados p/ Top/Bottom.
V_Align :: enum u8 { Baseline, Top, Middle, Bottom, Sub, Super }
// Família genérica de fonte. Não baixamos web fonts; mapeamos a stack do CSS
// para uma destas três (Sans = padrão). Sans precisa ser o zero-value p/ herdar.
Font_Family :: enum u8 { Sans, Serif, Mono }
// text-transform: None é o zero-value (padrão, herda).
Text_Transform :: enum u8 { None, Upper, Lower, Capitalize }
// white-space (herda). Normal = zero-value; Nowrap não quebra linha;
// Preserve and collapse modes retain distinct wrapping/segment-break behavior.
White_Space :: enum u8 { Normal, Nowrap, Pre, Pre_Wrap, Pre_Line, Break_Spaces }
// list-style-type (herda). Auto = zero-value → usa o padrão da tag (ol=decimal,
// ul=disc). None suprime o marcador; demais forçam o tipo.
List_Style :: enum u8 { Auto, None, Disc, Circle, Square, Decimal, Decimal_Zero,
                        Lower_Alpha, Upper_Alpha, Lower_Roman, Upper_Roman }

// box-shadow. inset = sombra interna (desenhada dentro da borda).
Shadow :: struct { dx, dy, blur, spread: f32, color: u32, inset: bool }
// 6 p/ acomodar a cadeia do Tailwind v4 (5 camadas compostas por var: inset/
// inset-ring/ring-offset/ring/shadow) + folga p/ designs que empilham sombras.
MAX_SHADOWS :: 6

// CSS Grid: tipo de cada track (coluna). Pct guarda fração 0..1; Fr a fração;
// Fixed os px. min_px é o piso vindo de minmax(min, …); min_pct é o piso quando
// esse mínimo é PORCENTAGEM (fração 0..1, resolvida contra a largura do container
// no layout). Sem min_pct, `minmax(45%, max-content)` guardava min_px=0.45 — um
// piso de meio pixel — e a trilha colapsava no max-content. É o idioma responsivo
// mais comum (`repeat(auto-fit, minmax(45%, max-content))`), e era o que espremia
// o feed do ge.globo a 73px. Ver M134.
Grid_Track_Kind :: enum u8 { Fixed, Fr, Pct, Auto }
// ⚠️ `de_minmax` distingue `minmax(0, 500px)` de `500px` PURO. Sem esse bit as
// duas viravam a MESMA trilha (kind=.Fixed value=500 min_px=0), e o `value` era
// tratado como largura PEDIDA nos dois casos. Mas num minmax o max é apenas um
// LIMITE DE CRESCIMENTO, alcançável só com espaço livre (Grid §12.6): o
// tailwindcss.com pede `minmax(0, var(--breakpoint-2xl))` = minmax(0, 1536px)
// numa grade de 1280 e o Chrome resolve a trilha em 1185, enquanto nós dávamos
// os 1536 inteiros — a coluna transbordava e o <h1> saía 30% largo demais.
Grid_Intrinsic :: enum u8 { Auto, MinContent, MaxContent, Fixed, FitContent }
Grid_Track :: struct {
    kind: Grid_Track_Kind, value: f32, min_px: f32, min_pct: f32, de_minmax: bool,
    min_kind, max_kind: Grid_Intrinsic,
    fit_pct: bool,
}
// 24: o grid GEL da BBC (e vários design systems de notícia) usa 24 colunas —
// com 16, itens em grid-column: 19/25 eram clampados p/ colunas já ocupadas e
// as regiões (left 1-6 / center 7-18 / right 19-24) SE SOBREPUNHAM. O array é
// copiado por valor em Computed/Box (~12 B/track), então 24 é o teto realista.
GRID_MAX_TRACKS :: 24
// trilhas de grid-auto-rows/columns: ciclam, e o uso real é 1-2 valores.
GRID_MAX_AUTO :: 4
GRID_MAX_AREAS  :: 16
Grid_Area :: struct { name: string, col, row, col_span, row_span: int }
// Nome de linha do grid (grid-template-columns: [foo] 1fr …). line = índice
// 1-based da linha (a linha n fica ANTES da trilha n; nomes após a última
// trilha referem a última linha).
Grid_Line :: struct { name: string, line: int }
GRID_MAX_LINES :: 16

// Overrides de :hover aplicáveis na PINTURA (sem re-layout): cor/fundo/borda/
// opacity/sublinhado. Preenchido quando alguma regra :hover casa o elemento;
// aplicado por frame em paint_box quando o mouse está sobre a caixa.
Hover_Style :: struct {
    active:       bool,          // há regra :hover casando este nó
    color:        u32, has_color:    bool,
    bg:           u32, has_bg:       bool,
    border_c:     u32, has_border_c: bool,
    opacity:      f32, has_opacity:  bool,
    shadows:      [MAX_SHADOWS]Shadow,
    shadow_n:     int,
    has_shadow:   bool, // includes box-shadow:none, which clears the base shadows
    // text-decoration do estado (linha/cor/estilo/espessura), não só o sublinhado:
    // `a:hover{text-decoration:none}` é tão comum quanto o inverso.
    deco:         Deco, has_deco:     bool,
    // o AUTOR escreveu text-decoration na regra :hover. Quando NÃO escreveu, o
    // default de link do UA (sublinhar <a href>) continua valendo no hover — quem
    // reaplica é o build_inline_items, que é onde esse default nasce.
    deco_set:     bool,
    // transform no :hover (ex.: botão que cresce/gira ao passar o mouse). Animado
    // pela transition como as demais props de pintura.
    xform: ^XList,
    has_transform: bool,
    tx, ty:        f32, tx_pct, ty_pct: bool,
    rot:           f32,
    sx, sy:        f32,
    back:          bool, // xf_back do estado :hover
}

// @keyframes resolvido p/ um elemento: stops com as props de pintura animáveis
// (opacity/cor/fundo). Array fixo p/ caber no Computed copiado por valor.
ANIM_MAX_STOPS :: 8
Anim_Stop :: struct {
    xform: ^XList, has_xform: bool,
    pct:         f32,
    has_opacity: bool, opacity: f32,
    has_color:   bool, color:   u32,
    has_bg:      bool, bg:      u32,
    has_rot:     bool, rot:     f32, // rotação (rad)
    has_scale:   bool, sx, sy:  f32, // escala
    has_translate: bool, tx, ty, tx_percent, ty_percent: f32,
    has_timing: bool, timing: Timing,
}
Anim :: struct {
    name: string,
    zero_iterations: bool,
    active:    bool,
    dur:       f32,  // segundos
    delay:     f32,  // segundos
    iter:      f32,  // nº de iterações (0 = infinito)
    alternate: bool, // direction: alternate
    reverse, fill_before, fill_after, paused: bool,
    timing: Timing,
    n:         int,  // nº de stops preenchidos
    stops:     [ANIM_MAX_STOPS]Anim_Stop,
    underlying: Anim_Stop,
}

// mix-blend-mode. Dois grupos: (a) LINEARES, realizáveis direto com blend modes
// do SDL_Renderer via ComposeCustomBlendMode (multiply/screen/darken/lighten/
// exclusion), que blendam contra o backdrop REAL no framebuffer; (b) NÃO-LINEARES
// por-canal (overlay/hard-light), que não são um fator linear → kernel CPU sobre
// a textura da layer, blendando contra o backdrop SÓLIDO aproximado (g_bg_behind).
// Os não-separáveis (hue/sat/color/luminosity) seguem tratados como Normal.
// ⚠️ ordem importa (checagens por RANGE em composite_layer/apply_cpu_blend):
//   >= Overlay → kernel CPU (não expressável como blend do SDL);
//   >= Hue     → NÃO-SEPARÁVEL (opera no pixel RGB inteiro via luminosity/sat,
//                não por-canal). Manter os grupos contíguos, não intercalar.
Blend_Mode :: enum u8 {
    Normal, Multiply, Screen, Darken, Lighten, Exclusion, // lineares (SDL)
    Overlay, HardLight, SoftLight, ColorDodge, ColorBurn, Difference, // separáveis (CPU)
    Hue, Saturation, Color, Luminosity, // não-separáveis (CPU, pixel inteiro)
}

// filter — efeitos gráficos sobre os pixels renderizados do elemento (aplicados
// na CPU sobre a textura da layer, pois o SDL_Renderer não tem shaders). Os de
// PONTO (por pixel) + blur (convolução). drop-shadow fica de fora da v1.
Filter_Kind :: enum u8 { Blur, Brightness, Contrast, Grayscale, Sepia, Saturate, Invert, HueRotate, Opacity, DropShadow }
Filter_Op :: struct {
    kind: Filter_Kind,
    amount: f32,   // px (blur/drop-shadow-blur), graus (hue-rotate), fator/fração (resto)
    dx, dy: f32,   // drop-shadow: offset em px
    color: u32,    // drop-shadow: cor (0xAARRGGBB, AA=0 opaco)
}
MAX_FILTERS :: 8

// clip-path (CSS Masking): recorta o elemento a uma forma básica. Os valores
// ficam CRUS (px ou %) e são resolvidos contra a caixa na PINTURA, pois % é
// relativo ao tamanho do border-box (desconhecido no cômputo de estilo).
Clip_Kind :: enum u8 { None, Inset, Circle, Ellipse, Polygon, Rect }
Clip_Val  :: struct { v: f32, pct: bool } // pct: v é fração (0..1) do eixo de referência
CLIP_MAX_PTS :: 16
Clip_Shape :: struct {
    kind:  Clip_Kind,
    inset: [4]Clip_Val, // inset(): t r b l
    round: Clip_Val,    // inset(... round <r>)
    cx, cy: Clip_Val,   // circle/ellipse: centro (default 50%)
    rx, ry: Clip_Val,   // circle: rx=raio; ellipse: rx/ry
    pts:   [CLIP_MAX_PTS][2]Clip_Val, // polygon()
    n_pts: int,
}

Computed :: struct {
    color:         u32,
    // caret-color (css-ui §4): HERDA, como o `color`. `auto` = a cor do texto,
    // que é o que o ImGui já faz sozinho ⇒ has_caret=false.
    caret_color:  u32, has_caret:    bool,
    bg:            u32,
    has_bg:        bool,
    hover:         Hover_Style, // overrides de :hover (não herda)
    anim_more: []Anim, // temporary list; Box owns playback copies
    anim:          Anim,        // animation/@keyframes resolvido (não herda)
    weight:        Font_Weight, // font-weight (Regular/Semi/Bold; ver Font_Weight)
    italic:        bool, // font-style: italic/oblique (herda)
    display_none:  bool,
    font_size:     f32,  // tamanho do texto em px (herdado, padrão 16)
    has_font_size: bool, // CSS definiu font-size explicitamente?
    line_height:   f32,  // multiplicador da altura de linha (herda; padrão 1.3)
    font_family:   Font_Family, // família genérica sans/serif/mono (herda; padrão Sans)
    font_fam_id:   u8,          // família de @font-face (índice+1 em g_face_families; 0 = genérica). HERDA junto.
    has_color:       bool, // este elemento definiu color? (p/ propagar a inline)
    has_font_family: bool, // este elemento definiu font-family? (idem)
    text_transform: Text_Transform, // maiúsculas/minúsculas/capitalizar (herda)
    letter_spacing: f32, // espaço extra entre glifos em px (herda; 0 = normal)
    font_kerning: Font_Kerning, // herda; auto/normal usam os pares da face
    word_spacing:   f32,  // word-spacing: px extra em cada espaço entre palavras (herda; 0 = normal)
    // text-wrap: balance — HERDA (prop de texto), então NÃO entra no bloco de reset
    // das não-herdadas. `pretty`/`stable` seguem inertes (algoritmo diferente).
    text_balance:    bool,
    text_indent:     f32,  // text-indent: recuo da 1ª linha (herda; px OU fração se _pct)
    indent_each_line, indent_hanging: bool,
    text_indent_pct: bool, // text-indent é % (do content-width do bloco, resolvido no layout)
    white_space:    White_Space, // nowrap/pre (herda; padrão Normal)
    break_word:     bool, // overflow-wrap:break-word/anywhere (herda)
    break_all:      bool, // word-break:break-all (inherited)
    wrap_anywhere:  bool, // overflow-wrap:anywhere also reduces min-content
    ellipsis:       bool, // text-overflow:ellipsis (NÃO herda; exige overflow hidden)
    line_clamp:     int,  // -webkit-line-clamp: N — trunca em N linhas + "…" (0 = sem)
    list_style:     List_Style,  // list-style-type (herda; Auto = padrão da tag)
    invisible:      bool,        // visibility:hidden/collapse (herda; mantém o layout)
    text_align:    Text_Align, // alinhamento do texto (herda)
    text_align_last:     Text_Align, // text-align-last (herda; alinha a ÚLTIMA linha do bloco)
    has_text_align_last: bool,        // autor definiu text-align-last?
    underline:     bool, // text-decoration: underline (propaga p/ descendentes)
    overline:      bool, // text-decoration: overline
    strike:        bool, // text-decoration: line-through
    deco_set:      bool, // autor definiu text-decoration? (p/ o UA sublinhar links só quando não)
    quotes_raw:    string, // valor cru da prop `quotes` (herda; slice persistente, não-owned)
    lang:          string, // idioma efetivo (atributo lang herdado; slice do DOM, não-owned)
    unicode_bidi: Unicode_Bidi,
    writing_mode: Writing_Mode,
    text_orientation: Text_Orientation,
    direction:     Directionality, // prop CSS `direction` (HERDA; Ltr=default). Resolve props lógicas.
    deco_color:    u32,  // text-decoration-color (DECO_UNSET = usa a cor do texto)
    deco_style:    Deco_Style, // text-decoration-style (solid/double/dotted/dashed/wavy)
    deco_thick:    f32,  // text-decoration-thickness em px (0 = auto)
    underline_offset: f32,  // text-underline-offset em px (HERDA; 0 = auto)
    underline_under:  bool, // text-underline-position: under (HERDA; abaixo das descidas)
    skip_ink_none:    bool, // text-decoration-skip-ink: none (HERDA; sublinha contínuo, sem pular glifos)

    // box model (não herdam)
    margin:     [4]f32,  // t r b l (px)
    has_margin: bool,
    padding:    [4]f32,
    // padding/margin em % (ou calc com %): a base é a LARGURA do bloco contenedor
    // (spec: vale p/ os 4 lados, inclusive topo/base) e só existe no layout.
    // Antes parse_box4 fazia `ok && !pct` e a porcentagem era DESCARTADA.
    padding_pct: [4]bool, padding_frac: [4]f32, padding_off: [4]f32,
    margin_pct:  [4]bool, margin_frac:  [4]f32, margin_off:  [4]f32,  // t r b l (px)
    border_w:   [4]f32, // larguras por lado (t r b l)
    border_c:   [4]u32, // cores por lado (t r b l)
    border_style_none: [4]bool, // border-style:none/hidden zera o lado na pintura
    has_border: bool,
    bimg: Border_Image, // border-image (não herda); active=false = borda normal
    border_collapse: bool, // border-collapse:collapse (tabela: bordas fundidas)
    table_fixed:      bool, // table-layout:fixed — larguras da 1ª linha, ignora conteúdo (não herda)
    empty_cells_hide: bool, // empty-cells:hide — não pinta fundo/borda de célula vazia (HERDA)
    caption_side_bottom: bool, // caption-side:bottom — caption abaixo da tabela (HERDA)
    outline_w:   f32, // outline: traço FORA da caixa (não afeta layout); 0 = sem
    outline_c:   u32,
    outline_off: f32, // outline-offset (pode ser negativo)
    width:      f32,  width_pct: bool,  has_width: bool,
    maxw:       f32,  maxw_pct:  bool,  has_maxw:  bool,
    minw:       f32,  minw_pct:  bool,  has_minw:  bool,
    height:     f32,  has_height: bool,
    height_pct: f32,  has_height_pct: bool, // height:N% — fração; resolvida no layout contra a altura DEFINIDA do pai
    // offset em px somado DEPOIS de resolver a fração: suporta `calc(100% - 40px)`
    // (a base da % só existe no layout). 0 quando a % é pura.
    width_pct_off:  f32,
    height_pct_off: f32,
    minw_pct_off:   f32,
    maxw_pct_off:   f32,
    // Limites ABSOLUTOS de um min()/max()/clamp() MISTO (ver Len_Bounds): aplicados
    // DEPOIS da fração, no mesmo ponto em que ela é resolvida (pct_resolve).
    // Vazio (has=false) para todo valor que não seja mistura — inclusive o
    // min/max/clamp todo-absoluto, que o parse_len já dobra num número só.
    width_bd, height_bd, minw_bd, maxw_bd, minh_bd, maxh_bd: Len_Bounds,
    // min/max-height em % (ou calc com %): a base é a altura DEFINIDA do pai, então
    // o PAI resolve a fração em px nos campos minh/maxh antes de dispor o filho
    // (mesma estratégia do height_pct). Antes a % aqui era simplesmente DESCARTADA.
    minh_pct: f32, has_minh_pct: bool, minh_pct_off: f32,
    maxh_pct: f32, has_maxh_pct: bool, maxh_pct_off: f32,
    height_mc:  bool, // height: min/max/fit-content — altura intrínseca (NÃO auto → sem stretch)
    width_mc:   bool, // width: min/max/fit-content — largura intrínseca (resolve p/ measure_intrinsic_w; NÃO auto → sem stretch)
    width_minc: bool, // usa oportunidades de quebra na medida intrínseca
    width_fit: bool,  // limita max-content ao disponível, respeitando min-content
    maxh:       f32,  has_maxh:  bool,  // só px (% de altura é ignorado, como height)
    minh:       f32,  has_minh:  bool,
    minh_mc:    bool, // min-height: min/max-content (teto = altura natural do conteúdo)
    aspect:     f32,  // aspect-ratio = largura/altura (0 = sem); deriva a dimensão faltante
    box_sizing: Box_Sizing,
    margin_x_auto: bool, // margin-left/right: auto (centraliza com width fixa)
    margin_left_auto: bool, margin_right_auto: bool, // por lado (auto-margins em flex empurram itens)
    margin_top_auto: bool, margin_bottom_auto: bool, // margin-top/bottom: auto (centra abspos no eixo vertical)
    border_radius: [4]f32,  border_radius_pct: [4]bool, // raio por canto (tl tr br bl)

    // posicionamento
    position:  Position,
    inset:     [4]f32,  // t r b l (top/right/bottom/left)
    // px somado após a fração: `top:calc(50% - 10px)`. Base = dimensão do bloco
    // contenedor no eixo (altura p/ top/bottom, largura p/ left/right).
    inset_off: [4]f32,
    inset_pct: [4]bool,
    inset_has: [4]bool,

    display_inline_block: bool, // display:inline-block — caixa que flui inline (não herda)
    display_block:  bool, // display:block explícito — força bloco numa tag inline (não herda)
    display_inline: bool, // display:inline explícito — força inline numa tag de bloco (não herda)
    // display:inline-flex / inline-grid / inline-table. O formatador INTERNO é o
    // mesmo (display_flex/_grid/_table seguem ligados); esta flag diz só que o
    // elemento é de nível INLINE — flui como átomo na linha em vez de quebrá-la.
    // Sem ela as duas famílias eram indistinguíveis e `flex` numa tag inline
    // (<label>/<span>/<a>) era tratado como inline (ver l_flows_inline).
    display_inline_level: bool,

    // flex container
    display_flex: bool,
    flex_dir:     Flex_Dir,
    flex_reverse: bool,     // row-reverse / column-reverse: inverte a ordem no eixo principal
    flex_wrap:    bool,
    flex_wrap_reverse: bool,
    justify:      Flex_Just,
    align_items:  Flex_Align,
    align_content: Flex_Just, // distribuição das LINHAS no eixo cruzado (flex-wrap)
    ac_stretch:    bool, // align-content resolve p/ stretch (normal/stretch): grid estica
                         // as trilhas AUTO p/ preencher a altura definida. default true.
    justify_items: Flex_Align, // grid: alinhamento horizontal dos itens na célula
    // align-self (item): override do align_items do container; auto = herda
    align_self:     Flex_Align,
    has_align_self: bool,
    justify_self:     Flex_Align, // grid: override do justify_items por item
    has_justify_self: bool,
    gap:          f32,
    // gap em % (ou calc com %): fração + offset; a base é o tamanho de CONTEÚDO do
    // próprio container no eixo (inline p/ gap/column-gap, bloco p/ row-gap) e só
    // existe no layout. Antes `gap:5%` virava 0.05 PIXEL.
    gap_pct: bool, gap_frac: f32, gap_off: f32,
    row_gap_pct: bool, row_gap_frac: f32, row_gap_off: f32,
    // flex item
    flex_grow:        f32,
    flex_shrink:      f32,
    flex_basis:       f32,  flex_basis_pct: bool,  has_flex_basis: bool,  flex_basis_auto: bool,
    flex_basis_pct_off: f32, // px somado após a fração: flex-basis:calc(50% - 8px)
    flex_basis_bd: Len_Bounds, // limites de min()/max()/clamp() misto (ver Len_Bounds)
    order:            int,  // ordem visual do item flex/grid (default 0)

    // grid container
    display_grid:   bool,
    // display: table / table-row / table-cell / table-*-group (não herdam). O
    // motor de layout de tabela (layout_table) reconhece estes além das tags HTML.
    display_table:       bool, // table / inline-table
    display_table_row:   bool, // table-row
    display_table_cell:  bool, // table-cell
    display_table_rowgrp: bool, // table-row-group / table-header-group / table-footer-group
    display_contents:    bool, // display:contents — o elemento não gera caixa; os filhos sobem ao pai
    // multi-coluna (column-count/column-width/columns/column-gap). 0 = não definido.
    col_count: int,
    col_width: f32,
    col_gap:   f32, // -1 = normal (1em); >=0 explícito
    break_before_avoid: bool, // break-before/page-break-before: avoid
    break_after_avoid:  bool, // break-after/page-break-after: avoid (não quebra p/ próx. coluna)
    grid_auto_fill: bool,                     // repeat(auto-fill/auto-fit, <track>)
    grid_track_n:   int,                      // nº de tracks de coluna explícitos (1 se auto-fill)
    grid_tracks:    [GRID_MAX_TRACKS]Grid_Track,
    grid_row_track_n: int,                     // nº de tracks de LINHA explícitos (grid-template-rows)
    grid_row_tracks:  [GRID_MAX_TRACKS]Grid_Track,
    // grade IMPLÍCITA: tamanho das trilhas criadas além do template (ciclam) e
    // a direção/densidade do auto-placement. Array pequeno de propósito — o
    // padrão real é 1-2 valores, e Computed/Box copiam isto POR VALOR.
    grid_auto_row_n: int, grid_auto_rows: [GRID_MAX_AUTO]Grid_Track,
    grid_auto_col_n: int, grid_auto_cols: [GRID_MAX_AUTO]Grid_Track,
    // container queries: este elemento é um CONTÊINER de consulta?
    // content-visibility: hidden → o CONTEÚDO não é renderizado (a caixa fica).
    // `auto` renderiza normal (a otimização de pular o que está fora da tela é
    // ganho de perf, não de aparência — e sem ela o resultado é o mesmo).
    content_hidden: bool,
    // contain-intrinsic-size: tamanho de RESERVA quando o conteúdo é pulado.
    cis_w, cis_h: f32, has_cis_w, has_cis_h: bool,
    container_inline: bool,   // container-type: inline-size | size
    container_name:   string, // container-name (vazio = anônimo)
    grid_flow_col:   bool,                     // grid-auto-flow: column
    grid_flow_dense: bool,                     // grid-auto-flow: … dense
    row_gap:        f32,                       // espaçamento entre linhas (gap = entre colunas)
    // grid item — posicionamento (linha 1-based; 0 = auto)
    grid_col_start: int, grid_col_span: int,   // grid-column: <start> / <end|span N>
    grid_row_start: int, grid_row_span: int,   // grid-row: <start> / <end|span N>
    // grid-template-areas (container): mapa de áreas nomeadas
    grid_areas: [GRID_MAX_AREAS]Grid_Area,
    grid_area_n: int,
    // grid-area (item): nome da área (resolvido contra o parent em compute_node)
    grid_area_name: string,
    // linhas nomeadas do template (container): [foo] em grid-template-columns/rows
    grid_col_lines: [GRID_MAX_LINES]Grid_Line, grid_col_line_n: int,
    grid_row_lines: [GRID_MAX_LINES]Grid_Line, grid_row_line_n: int,
    // grid-column/grid-row por NOME (item): resolvido contra as linhas do parent
    grid_col_start_name, grid_col_end_name: string,
    grid_row_start_name, grid_row_end_name: string,
    // Linha de FIM ainda NÃO resolvida, quando ela é NEGATIVA (`grid-column: 2 / -2`).
    // Negativo conta do fim do grid explícito, logo depende do nº de tracks do PAI,
    // que o parser de string não tem — resolvido em compute_node e zerado lá, igual
    // aos nomes acima. 0 = não declarada.
    grid_col_end_line: int, grid_row_end_line: int,

    // background
    grad: csspkg.Gradient, // linear-gradient (substitui a cor de fundo sólida)
    // `background-clip: text` com gradiente: o `grad` acima NÃO pinta a caixa —
    // ele vai colorir os GLIFOS. Uma flag em vez de um segundo Gradient no
    // Computed, que custaria ~350 B em TODO nó (a armadilha do M162/M29).
    grad_clip_text: bool,
    bg_img:    string,     // background-image: url() — URL crua (clone temp; resolvida na Box)
    bg_size:   Bg_Size,
    bg_extra:  []Bg_Layer, // camadas ADICIONAIS (ver Bg_Layer); vazia no caso comum
    bg_canvas: bool,       // este elemento é a FONTE do fundo do canvas (raiz, ou
                           // body quando a raiz não tem fundo): sua área de pintura
                           // de fundo é o canvas inteiro, não a caixa dele
    bg_clip:   Bg_Clip,    // background-clip: border/padding/content-box
    bg_origin: Bg_Clip,    // background-origin: área de posicionamento (default Padding); não herda
    // background-attachment: fixed — o fundo é posicionado contra o VIEWPORT e
    // não acompanha o scroll (cabeçalho "parallax"). `local` = igual a `scroll`
    // p/ nós (só difere em elemento com scroll próprio).
    bg_fixed: bool,
    bg_pos_x:  f32, bg_pos_y: f32, // posição (frações 0..1)
    bg_repeat: bool,

    // imagem: object-fit + object-position (frações 0..1; padrão 0.5 = centro)
    obj_fit: Obj_Fit,
    obj_pos_x, obj_pos_y: f32,
    cursor: Cursor_Kind, // ponteiro do mouse (herda; Auto = seta)
    accent_color: u32, has_accent: bool, // accent-color: cor de checkbox/radio marcado (HERDA)
    pe_none:          bool, // pointer-events:none — elemento transparente a cliques/hover (HERDA)
    user_select_none: bool, // user-select:none — HERDA; inerte por ora (sem seleção de texto de página)
    appearance_none:  bool, // appearance:none — suprime a marca nativa do controle; não herda
    scroll_smooth:    bool, // scroll-behavior:smooth — anima scroll programático (âncora); não herda
    scroll_margin_top:  f32, // scroll-margin-top — desloca onde a âncora aterrissa (não herda)
    scroll_padding_top: f32, // scroll-padding-top — recuo do topo do container de scroll (não herda)
    overscroll_contain: bool, // overscroll-behavior contain/none — não encadeia scroll ao pai/página (não herda)
    tab_size:           int,  // tab-size (nº de espaços em <pre>; 0 = default 8; HERDA)
    valign: V_Align,     // vertical-align do item inline (não herda; Baseline)
    // transition por CANAL animável (duração/atraso/curva). Não herda.
    // Antes era um único `transition_dur` que governava todos os canais.
    trans: [Trans_Chan]Transition,

    // overflow
    overflow_hidden: bool,  // legado: clipa ALGUM eixo (= ovf_clip_x || ovf_clip_y)
    ovf_clip_x: bool,       // clipa no eixo horizontal (overflow[-x]:hidden/clip/scroll/auto)
    ovf_clip_y: bool,       // clipa no eixo vertical
    overflow_scroll: bool,  // overflow:scroll/auto — clipa E rola (não herda)
    ovf_scroll_x: bool,     // o eixo X é ROLÁVEL (overflow-x scroll/auto); hidden só clipa
    ovf_scroll_y: bool,     // idem no eixo Y
    scroll_container: bool, // é scroll container: overflow hidden/scroll/auto em ALGUM
                            // eixo (NÃO clip — clip clipa mas não rola). Usado p/ o
                            // min-size:auto de flex item (clip ≡ visible; hidden/scroll → 0).
    resize: Resize_Dir,     // resize — alça de redimensionamento pelo usuário (não herda).
                            // A APLICABILIDADE (só vale com overflow≠visible) é decidida
                            // no apply_box, que também conhece a tag do nó.
    float:  Float_Side,    // float:left/right (não herda)
    clear:  Clear_Side,    // clear:left/right/both (não herda)

    // stacking
    z_index: int,
    z_index_set: bool, // auto e zero têm contextos distintos
    stacking_hint: bool, // will-change e contain

    // visual
    opacity: f32,  // 1.0 = opaco (padrão)
    isolate: bool, // isolation:isolate — força grupo de composição (stacking/blend); não herda
    clip_path: Clip_Shape, // clip-path (forma básica; não herda). kind=None = sem recorte
    mask_grad: csspkg.Gradient, // mask-image: <gradient> — máscara alpha (não herda). active=false = sem máscara
    blend_mode: Blend_Mode, // mix-blend-mode (Normal = sem blend)
    filters: [MAX_FILTERS]Filter_Op, n_filters: int, // filter (aplicados em ordem)
    backdrop_filters: [MAX_FILTERS]Filter_Op, n_backdrop: int, // backdrop-filter (não herda)

    // transform. translate = pct do próprio tamanho; rotate/scale ficam em campos
    // próprios (animáveis por transition). skew()/matrix() vão pela matriz linear
    // 2×2 composta (xf_*), que quando presente (has_xform_matrix) SUBSTITUI rot/scale
    // na pintura — cobre skew, matrix e composições arbitrárias de funções.
    transform_tx, transform_ty:         f32,
    transform_tx_pct, transform_ty_pct: bool,
    xform: ^XList,
    perspective: f32,
    perspective_ox, perspective_oy: f32,
    perspective_opx, perspective_opy: f32,
    transform_opx, transform_opy, transform_opz:f32,
    xf_percent: [4]f32, // translation coefficients: x/w, x/h, y/w, y/h
    transform_rot:                      f32, // rotação em radianos
    transform_sx, transform_sy:         f32, // escala (1 = sem)
    transform_ox, transform_oy:         f32, // transform-origin como fração 0..1 (default 0.5)
    xf_a, xf_b, xf_c, xf_d:             f32, // parte linear 2×2 [a b; c d] (identidade = 1,0,0,1)
    has_xform_matrix:                   bool, // usa xf_* (skew/matrix) em vez de rot/scale
    has_transform:                      bool,
    // 3D ACHATADO (ver parse_transform): as funções 3D compõem numa matriz 3×3 e
    // só a projeção ortográfica (o bloco 2×2) chega à pintura. O que a projeção
    // perde é o LADO: `rotateY(180deg)` e `scaleX(-1)` dão o mesmo 2×2, mas só o
    // primeiro mostra o VERSO. `xf_back` guarda esse bit.
    xf_back:         bool, // o transform próprio deixa a face de TRÁS voltada p/ o observador
    backface_hidden: bool, // backface-visibility:hidden (não herda)
    preserve_3d:     bool, // transform-style:preserve-3d (não herda)
    in_p3d:          bool, // o PAI tem preserve-3d: o lado do pai compõe com o nosso

    // offset-path (CSS Motion Path): posiciona a caixa ao longo de um caminho.
    // Só path(...) com segmentos retos (M/L/H/V/Z). offset_distance em fração da
    // largura (pct→fração do comprimento do path) ou px. Aplicado no layout.
    has_offset_path:      bool,
    offset_path:          string, // dados do path() (ex.: "m 0 0 h 200 v 150 z")
    offset_distance:      f32,    // fração (pct/100) se _pct, senão px
    offset_distance_pct:  bool,
    offset_rotate_auto:   bool,   // offset-rotate: auto (default) segue a tangente
    offset_rotate_angle:  f32,    // ângulo adicional/absoluto em radianos

    // will-change (css-will-change): se o valor não-inicial de um prop LISTADO criaria
    // um bloco contenedor p/ descendentes posicionados, o will-change tb cria. `position`
    // cria só p/ absolute; transform/filter/perspective/contain/offset-path criam p/ AMBOS
    // (absolute E fixed). Computado no parse; consumido em layout_absolutes.
    cb_abs:   bool, // estabelece containing block p/ position:absolute
    cb_fixed: bool, // estabelece containing block p/ position:fixed
    contained: bool, // `contain` != none (layout/paint/size/style/strict/content)

    // box-shadow (externas; não herda)
    shadows:  [MAX_SHADOWS]Shadow,
    shadow_n: int,

    // text-shadow (HERDA; reusa Shadow — spread/inset ignorados; sem blur real).
    // Pintadas atrás do texto no paint_inline. A 1ª da lista fica no topo.
    text_shadows:  [MAX_SHADOWS]Shadow,
    text_shadow_n: int,

    // content (::before/::after): texto gerado. has_content marca que a regra
    // define `content` (mesmo "" gera caixa). before/after são os estilos
    // computados dos pseudo-elementos (nil = não existem).
    content:     string,
    has_content: bool,
    content_raw: string, // valor cru de `content` quando tem counter()/counters() (resolvido no passe de counters; slice não-owned)
    content_has_counter: bool,
    counter_reset_raw:     string, // `counter-reset` cru (não herda; slice não-owned)
    counter_increment_raw: string, // `counter-increment` cru (não herda)
    counter_set_raw:       string, // `counter-set` cru (não herda; slice não-owned)
    before: ^Computed,
    after:  ^Computed,
    // ::first-letter — estilo da primeira letra (nil = sem regra). Diferente de
    // before/after, NÃO usa `content` (o conteúdo é a 1ª letra do texto real).
    // v1: só é consumido no layout quando tem float (drop-cap).
    first_letter: ^Computed,
    // ::placeholder (M218) — estilo do texto-DICA de <input>/<textarea>. Só `color`
    // e `opacity` são consumidos (é o que decide se a dica aparece e em que cor).
    placeholder: ^Computed,
    // fill/stroke de REGRA CSS (nil = o painter usa só atributo). NÃO herda.
    // Alocado só quando o nó declarou alguma prop da família; dono = free_styles.
    svg_css: ^Svg_Css,
}

// Junta o conteúdo de todas as tags <style> da página (texto CSS).
collect_css :: proc(root: ^dompkg.Node) -> string {
    sb := strings.builder_make(context.temp_allocator)
    collect_css_walk(root, &sb)
    return strings.to_string(sb)
}

@(private="file")
collect_css_walk :: proc(n: ^dompkg.Node, sb: ^strings.Builder) {
    if n.kind == .Element && n.tag == "style" {
        // <style> DENTRO de uma shadow root: as regras valem só naquela árvore. Não
        // temos escopo no motor de CSS (as regras viram um blob único), então
        // escopamos por REESCRITA de seletor: o host ganha um atributo-marcador e
        // cada seletor é prefixado com ele. Ver shadow_scope_css.
        if host, sid := shadow_host_of(n); host != nil {
            for c in n.children {
                if c.kind == .Text do shadow_scope_css(sb, c.text, sid)
            }
        } else {
            for c in n.children {
                if c.kind == .Text do strings.write_string(sb, c.text)
            }
        }
    }
    for c in n.children do collect_css_walk(c, sb)
}

// Carimba `data-shadow-scope="s<id>"` em todo elemento que hospeda uma shadow root.
// É o gancho que os seletores reescritos por shadow_scope_css usam para casar. O id é
// o endereço do nó "#shadow" — estável dentro de uma passada de estilo, que é o
// tempo de vida que importa (o CSS é recoletado a cada restyle).
@(private="file")
stamp_shadow_scopes :: proc(n: ^dompkg.Node) {
    if n == nil do return
    for c in n.children {
        if c.tag == "#shadow" {
            want := fmt.aprintf("s%d", uintptr(rawptr(c)))
            if old, ok := n.attrs["data-shadow-scope"]; ok && old == want {
                delete(want) // já carimbado com o mesmo id
            } else {
                dompkg.set_attr(n, strings.clone("data-shadow-scope"), want)
            }
            break
        }
    }
    for c in n.children do stamp_shadow_scopes(c)
}

// Sobe até a shadow root que contém `n`; devolve o HOST e o id de escopo (estável:
// o endereço do nó da shadow root). nil se `n` está no documento de luz.
@(private="file")
shadow_host_of :: proc(n: ^dompkg.Node) -> (^dompkg.Node, uintptr) {
    for a := n.parent; a != nil; a = a.parent {
        if a.tag == "#shadow" do return a.parent, uintptr(rawptr(a))
    }
    return nil, 0
}

// Reescreve `css` prefixando cada seletor com `[data-shadow-scope="<sid>"] `, e
// trocando `:host` pelo próprio marcador. Preserva at-rules com bloco (@media etc.)
// recursivamente, e regras sem seletor passam intactas.
//
// APROXIMAÇÃO conhecida: o prefixo é um combinador DESCENDENTE, então (a) regras do
// componente também alcançam conteúdo projetado por <slot> (no DOM real só via
// ::slotted) e (b) uma shadow root aninhada é descendente da externa, então regras da
// externa podem alcançá-la. O vazamento GRAVE — regras do componente escapando para a
// página — está fechado, que é o que importa para renderizar sem estragar o resto.
@(private="file")
shadow_scope_css :: proc(sb: ^strings.Builder, css: string, sid: uintptr) {
    marker := fmt.tprintf("[data-shadow-scope=\"s%d\"]", sid)
    i := 0
    for i < len(css) {
        // at-rule: copia o prelúdio e escopa o BLOCO interno (se houver)
        if css[i] == '@' {
            j := i
            for j < len(css) && css[j] != '{' && css[j] != ';' do j += 1
            if j >= len(css) { strings.write_string(sb, css[i:]); return }
            if css[j] == ';' { strings.write_string(sb, css[i:j+1]); i = j + 1; continue }
            depth, k := 0, j
            for k < len(css) {
                if css[k] == '{' do depth += 1
                if css[k] == '}' { depth -= 1; if depth == 0 do break }
                k += 1
            }
            inner_end := min(k, len(css))
            strings.write_string(sb, css[i:j+1]) // "@media ... {"
            if j+1 < inner_end do shadow_scope_css(sb, css[j+1:inner_end], sid)
            strings.write_string(sb, "}")
            i = min(k+1, len(css))
            continue
        }
        // regra normal: <seletores> { <decls> }
        br := strings.index_byte(css[i:], '{')
        if br < 0 { return } // lixo no fim: descarta
        br += i
        sel := strings.trim_space(css[i:br])
        depth, k := 0, br
        for k < len(css) {
            if css[k] == '{' do depth += 1
            if css[k] == '}' { depth -= 1; if depth == 0 do break }
            k += 1
        }
        body_end := min(k, len(css))
        if sel != "" {
            first := true
            for part in strings.split(sel, ",", context.temp_allocator) {
                p := strings.trim_space(part)
                if p == "" do continue
                if !first do strings.write_string(sb, ",")
                first = false
                if p == ":host" {
                    strings.write_string(sb, marker)
                } else if strings.has_prefix(p, ":host(") && strings.has_suffix(p, ")") {
                    // :host(.foo) → marcador + o composto interno
                    strings.write_string(sb, marker)
                    strings.write_string(sb, strings.trim_space(p[6:len(p)-1]))
                } else if strings.has_prefix(p, ":host ") {
                    strings.write_string(sb, marker)
                    strings.write_string(sb, p[5:])
                } else {
                    strings.write_string(sb, marker)
                    strings.write_string(sb, " ")
                    strings.write_string(sb, p)
                }
            }
            strings.write_string(sb, "{")
            strings.write_string(sb, css[br+1:body_end])
            strings.write_string(sb, "}")
        }
        i = min(k+1, len(css))
    }
}

// Computa os estilos de toda a árvore. Devolve o mapa por nó e o fundo da página.
compute_styles :: proc(root: ^dompkg.Node, rules: ^[dynamic]csspkg.Rule, viewport_w: f32 = 1280, viewport_h: f32 = 720, kf: []csspkg.Keyframe_Set = nil) -> (styles: map[^dompkg.Node]Computed, page_bg: u32) {
    styles = make(map[^dompkg.Node]Computed)
    stamp_shadow_scopes(root) // marcador que dá escopo às regras de cada shadow root
    g_viewport_h = viewport_h // p/ @media (aspect-ratio) em collect_decls
    g_viewport_w = viewport_w // p/ o `media` dos <source> de <picture> (build_layout)
    csspkg.g_dark_scheme = g_prefers_dark // p/ light-dark() no parser de cor
    // base do `rem` volta ao INICIAL a cada página: o <html> desta árvore pode não
    // declarar font-size, e herdar a base da página anterior seria pior que o bug
    // que isto conserta.
    g_root_font_size = 16 * g_zoom
    root_inherit := Computed{color = DEFAULT_TEXT, font_size = 16 * g_zoom, line_height = 1.3, deco_color = DECO_UNSET, text_align = .Start}
    root_vars := make(map[string]string, context.temp_allocator) // variáveis CSS (--x)
    // `@property … { inherits: false }`: as regras sintéticas vêm marcadas com
    // `reg_noinherit`. Coletamos aqui UMA vez (a lista é minúscula — o Tailwind
    // registra ~15) para que compute_node possa devolver o valor INICIAL ao
    // descendente que não declarou a propriedade. Lista vazia (o caso de quase
    // todo site) ⇒ custo ZERO no laço por nó.
    noinh := make([dynamic]Noinherit_Prop, context.temp_allocator)
    for &r in rules {
        if !r.reg_noinherit do continue
        for name, init in r.decls do if strings.has_prefix(name, "--") {
            append(&noinh, Noinherit_Prop{name, init})
        }
    }
    idx := build_rule_index(rules) // índice p/ evitar testar todas as regras por nó
    compute_node(root, root_inherit, root_vars, rules, &idx, &styles, viewport_w, viewport_h, kf, noinh[:])
    resolve_counters(root, &styles) // preenche content de ::before/::after com counter()

    // FUNDO DO CANVAS (css-backgrounds §2.11.2): quem manda é o ELEMENTO RAIZ —
    // seu fundo vira o do canvas e cobre o VIEWPORT INTEIRO, não só a caixa dele.
    // Só quando a raiz NÃO tem fundo é que o do <body> propaga no lugar dela
    // (quirk histórico do HTML). Antes olhávamos apenas o <body>: uma página com
    // `html{background:#333}` (php.net e todo tema escuro) ficava BRANCA abaixo
    // do fim do conteúdo, porque o #333 só pintava a caixa do <html>.
    // `contain` no elemento suprime a propagação (css-contain).
    page_bg = 0xffffff
    src: ^dompkg.Node
    if html := dompkg.find_first(root, "html"); html != nil {
        if c, ok := styles[html]; ok && (c.has_bg || c.grad.active) && !c.contained do src = html
    }
    if src == nil {
        if body := dompkg.find_first(root, "body"); body != nil {
            if c, ok := styles[body]; ok && (c.has_bg || c.grad.active) && !c.contained do src = body
        }
    }
    if src != nil {
        if c, ok := &styles[src]; ok {
            // ⚠️ cor TRANSLÚCIDA fica FORA do page_bg: o backdrop da página é
            // BRANCO e a composição tem de acontecer UMA vez só. Como a área de
            // pintura do elemento agora É o canvas, quem compõe é o paint dele;
            // pôr a cor também no page_bg somava duas vezes e escurecia
            // (o reftest `root-element-background-transparency` pegou isso).
            if c.has_bg {
                a := (c.bg >> 24) & 0xFF // convenção da engine: 0 = OPACO
                if a == 0 || a == 255 do page_bg = c.bg
            }
            c.bg_canvas = true // o paint estende a ÁREA de fundo deste elemento ao canvas
        }
    }
    svg_css_bind(styles) // painter e os testes lêem daqui, não de um mapa global
    return
}

// Folha de estilo padrão do "user agent": aparência/comportamento embutidos de
// certos elementos, aplicados antes do CSS do autor (que pode sobrescrever).
@(private="file")
apply_ua_defaults :: proc(n: ^dompkg.Node, comp: ^Computed) {
    switch n.tag {
    case "h1", "h2", "h3", "h4", "h5", "h6":
        // negrito do UA. Fica AQUI (antes das declarações do autor) e não no
        // layout: assim `h3{font-weight:500}` VENCE, como no Chrome. Antes o
        // layout fazia `comp.bold || is_heading`, então o peso do autor era
        // ignorado e todo heading saía 700.
        comp.weight = FW_BOLD
    case "em", "i", "cite", "dfn", "var", "address":
        comp.italic = true // itálico por padrão (herda; font-style:normal desliga)
    case "pre":
        // `pre{white-space:pre}` da folha do UA. Estava só como `eff_ws` LOCAL no
        // build_layout do próprio <pre>, então não HERDAVA: um `<code>` (ou
        // qualquer filho) dentro do <pre> lia `white_space == .Normal` do Computed
        // e COLAPSAVA os espaços — a indentação do bloco de código sumia. Aqui,
        // antes das declarações do autor, herda pelos descendentes e continua
        // sobrescritível por `pre{white-space:normal}`.
        comp.white_space = .Pre
    case "button":
        ua_button_look(comp, "disabled" in n.attrs)
    case "input":
        dis := "disabled" in n.attrs
        switch n.attrs["type"] {
        case "submit", "reset", "button":
            ua_button_look(comp, dis)
        case "hidden":
            comp.display_none = true
        case "", "text", "search", "email", "url", "tel", "password", "number":
            ua_textfield_look(n, comp, dis)
        case "checkbox", "radio":
            ua_checkbox_look(comp, n.attrs["type"] == "radio", "checked" in n.attrs, dis)
        // file/date/...: sem renderização própria (caixa vazia) por ora
        }
    case "textarea":
        ua_textarea_look(comp, "disabled" in n.attrs || "readonly" in n.attrs)
    }
}

// Aparência padrão de <textarea>: campo multi-linha com fundo branco, borda 1px
// e respiro interno. A largura/altura (colunas × linhas) é definida no layout,
// a partir dos atributos cols/rows; o CSS width/height sobrescreve.
@(private="file")
ua_textarea_look :: proc(comp: ^Computed, disabled: bool) {
    comp.display_inline_block = true
    comp.text_align = .Start
    comp.cursor     = .Text
    comp.white_space = .Pre // textarea preserva espaços/quebras
    // <textarea> é redimensionável por padrão em todas as UAs (é o que dá sentido
    // ao `resize:none` que os sites escrevem — sem este default não haveria nada
    // p/ suprimir). Vem ANTES das decls do autor, então `resize:vertical` vence.
    comp.resize = .Both
    comp.has_bg = true; comp.bg = 0xffffff
    comp.has_border = true
    comp.border_w = {1, 1, 1, 1}
    comp.border_c = {0x767676, 0x767676, 0x767676, 0x767676}
    comp.padding       = {2, 4, 2, 4}
    comp.border_radius = {2, 2, 2, 2}
    if disabled {
        comp.bg = 0xf3f3f5
        comp.color = 0x9a9a9a; comp.has_color = true
        comp.cursor = .NotAllowed
    }
}

// Aparência padrão de checkbox/radio (não clicável): quadradinho (ou círculo, no
// radio) de 13px com borda. A marca (✓) e o ponto do radio são desenhados no
// paint. `checked` no checkbox pinta o fundo de azul; no radio o anel fica branco.
@(private="file")
ua_checkbox_look :: proc(comp: ^Computed, is_radio: bool, checked: bool, disabled: bool) {
    comp.display_inline_block = true
    comp.cursor     = .Pointer
    SIZE :: f32(13)
    comp.has_width  = true; comp.width  = SIZE
    comp.has_height = true; comp.height = SIZE
    comp.box_sizing = .Border // 13px inclui a borda
    comp.has_border = true
    comp.border_w = {1, 1, 1, 1}
    comp.border_c = {0x767676, 0x767676, 0x767676, 0x767676}
    comp.has_bg = true; comp.bg = 0xffffff
    r := is_radio ? SIZE / 2 : 2 // radio = círculo
    comp.border_radius = {r, r, r, r}
    // O estado "marcado" (fundo azul do checkbox / ponto do radio) é desenhado no
    // paint a partir de ctrl_checked — assim o clique alterna sem re-layout.
    if disabled {
        comp.bg = 0xebebeb
        comp.border_c = {0xb5b5b5, 0xb5b5b5, 0xb5b5b5, 0xb5b5b5}
        comp.cursor = .NotAllowed
    }
}

// Aparência padrão de campo de texto (não editável): fundo branco, borda 1px,
// largura fixa (~20 caracteres ou o atributo `size`), altura de uma linha.
@(private="file")
ua_textfield_look :: proc(n: ^dompkg.Node, comp: ^Computed, disabled: bool) {
    comp.display_inline_block = true
    comp.text_align = .Start
    comp.cursor     = .Text
    comp.has_bg = true; comp.bg = 0xffffff
    comp.has_border = true
    comp.border_w = {1, 1, 1, 1}
    comp.border_c = {0x767676, 0x767676, 0x767676, 0x767676}
    comp.padding       = {3, 6, 4, 6}
    comp.border_radius = {2, 2, 2, 2}
    // a altura (uma linha) é definida no build com a fonte real; aqui só a largura.
    // largura padrão: atributo `size` (em caracteres) ou ~20ch; CSS width sobrescreve
    chars := 20
    if s, ok := n.attrs["size"]; ok {
        if v, k := strconv.parse_int(s); k && v > 0 do chars = v
    }
    comp.has_width = true
    comp.width = f32(chars) * comp.font_size * 0.5 + 2
    if disabled {
        comp.bg = 0xf3f3f5
        comp.color = 0x9a9a9a; comp.has_color = true
        comp.cursor = .NotAllowed
    }
}

// Aparência padrão de botão: caixa que flui inline, encolhe ao rótulo, texto
// centralizado, fundo cinza, borda 1px, cantos arredondados e respiro interno.
@(private="file")
ua_button_look :: proc(comp: ^Computed, disabled: bool) {
    comp.display_inline_block = true
    comp.text_align = .Center
    comp.cursor     = .Pointer
    comp.has_bg = true; comp.bg = 0xe9e9ed
    comp.has_border = true
    comp.border_w = {1, 1, 1, 1}
    comp.border_c = {0x8f8f8f, 0x8f8f8f, 0x8f8f8f, 0x8f8f8f}
    comp.padding       = {4, 12, 5, 12}
    comp.border_radius = {4, 4, 4, 4}
    // realce ao passar o mouse, sem exigir CSS na página
    comp.hover.active = true
    comp.hover.has_bg = true; comp.hover.bg = 0xdcdce1
    // disabled: acinzentado e cursor bloqueado
    if disabled {
        comp.bg    = 0xf3f3f5
        comp.color = 0x9a9a9a; comp.has_color = true
        comp.cursor = .NotAllowed
        comp.hover  = {}
    }
}

@(private="file")
compute_node :: proc(n: ^dompkg.Node, inherit: Computed, vars: map[string]string, rules: ^[dynamic]csspkg.Rule, idx: ^Rule_Index, styles: ^map[^dompkg.Node]Computed, viewport_w: f32, viewport_h: f32 = 720, kf: []csspkg.Keyframe_Set = nil, noinh: []Noinherit_Prop = nil) {
    comp := inherit
    if d, ok := n.attrs["dir"]; ok {
        if strings.equal_fold(d, "rtl") { comp.direction = .Rtl }
        else if strings.equal_fold(d, "ltr") { comp.direction = .Ltr }
        else if strings.equal_fold(d, "auto") { comp.direction = dir_from_text(n) }
    }
    // lang efetivo: atributo `lang` do elemento sobrepõe o herdado (usado p/ as
    // aspas default de <q> quando não há prop `quotes`).
    if l, ok := n.attrs["lang"]; ok && l != "" do comp.lang = l
    // estas propriedades não herdam — zera antes de aplicar as deste nó
    comp.unicode_bidi = .Normal
    comp.svg_css = nil              // fill/stroke de regra CSS é por-elemento (M246)
    comp.counter_reset_raw = ""     // counter-reset/increment/set não herdam
    comp.counter_increment_raw = ""
    comp.counter_set_raw = ""
    comp.content = ""; comp.has_content = false
    comp.content_raw = ""; comp.content_has_counter = false
    comp.has_bg = false
    comp.bg = 0
    comp.display_none = false
    comp.margin = {}
    comp.has_margin = false
    comp.padding = {}
    comp.padding_pct = {}; comp.padding_frac = {}; comp.padding_off = {}
    comp.margin_pct  = {}; comp.margin_frac  = {}; comp.margin_off  = {}
    comp.border_w = {}
    comp.border_c = {}
    comp.border_style_none = {}
    comp.has_border = false
    comp.bimg = {} // border-image NÃO herda
    comp.outline_w = 0
    comp.outline_c = 0
    comp.outline_off = 0
    comp.has_width = false
    comp.has_maxw = false
    comp.has_minw = false
    comp.has_height = false
    comp.has_height_pct = false
    comp.width_pct_off = 0
    comp.height_pct_off = 0
    comp.minw_pct_off = 0
    comp.maxw_pct_off = 0
    comp.has_minh_pct = false; comp.minh_pct_off = 0
    comp.has_maxh_pct = false; comp.maxh_pct_off = 0
    comp.width_bd = {}; comp.height_bd = {}; comp.minw_bd = {}
    comp.maxw_bd = {}; comp.minh_bd = {}; comp.maxh_bd = {}
    comp.height_mc = false
    comp.width_mc = false
    comp.width_minc = false
    comp.width_fit = false
    comp.has_maxh = false
    comp.has_minh = false
    comp.minh_mc = false
    comp.aspect = 0
    comp.box_sizing = .Content
    comp.margin_x_auto = false
    comp.margin_left_auto = false
    comp.margin_right_auto = false
    comp.margin_top_auto = false
    comp.margin_bottom_auto = false
    comp.border_radius = {}
    comp.border_radius_pct = {}
    comp.position = .Static
    comp.inset = {}
    comp.inset_off = {}
    comp.inset_pct = {}
    comp.inset_has = {}
    // flex (não herdam)
    comp.display_inline_block = false
    comp.display_block = false
    comp.display_inline = false
    comp.display_inline_level = false
    comp.display_flex = false
    comp.display_table = false
    comp.display_table_row = false
    comp.display_table_cell = false
    comp.display_table_rowgrp = false
    comp.display_contents = false
    comp.flex_dir = .Row
    comp.flex_reverse = false
    comp.flex_wrap = false
    comp.flex_wrap_reverse = false
    comp.justify = .Start
    comp.align_items = .Stretch
    comp.align_content = .Start
    comp.ac_stretch = true // default: align-content normal → stretch das trilhas auto
    comp.justify_items = .Stretch
    comp.align_self = .Stretch
    comp.has_align_self = false
    comp.justify_self = .Stretch
    comp.has_justify_self = false
    comp.gap = 0
    comp.col_count = 0
    comp.col_width = 0
    comp.col_gap = -1 // normal (1em)
    comp.gap_pct = false; comp.gap_frac = 0; comp.gap_off = 0
    comp.row_gap_pct = false; comp.row_gap_frac = 0; comp.row_gap_off = 0
    comp.break_before_avoid = false
    comp.break_after_avoid = false
    comp.flex_grow = 0
    comp.flex_shrink = 1
    comp.has_flex_basis = false
    comp.flex_basis_pct_off = 0; comp.flex_basis_bd = {}
    comp.flex_basis_auto = false
    comp.order = 0
    // grid (não herdam)
    comp.display_grid = false
    comp.grid_auto_fill = false
    comp.grid_track_n = 0
    comp.grid_row_track_n = 0
    comp.grid_auto_row_n = 0
    comp.grid_auto_col_n = 0
    comp.content_hidden = false
    comp.has_cis_w = false; comp.has_cis_h = false
    comp.container_inline = false
    comp.container_name = ""
    comp.grid_flow_col = false
    comp.grid_flow_dense = false
    comp.row_gap = 0
    comp.grid_col_start = 0; comp.grid_col_span = 1
    comp.grid_row_start = 0; comp.grid_row_span = 1
    comp.grid_area_n = 0
    comp.grid_area_name = ""
    comp.grid_col_line_n = 0; comp.grid_row_line_n = 0
    comp.grid_col_start_name = ""; comp.grid_col_end_name = ""
    comp.grid_row_start_name = ""; comp.grid_row_end_name = ""
    comp.grad = {}
    comp.grad_clip_text = false // anda junto com o grad (background-clip não herda)
    comp.bg_img = ""
    comp.bg_extra = nil // background-image não herda — e o filho copia o Computed
                        // do pai inteiro (child_inherit), então SEM este reset as
                        // camadas extras vazavam p/ toda a subárvore (o hero do
                        // getbootstrap pintava seus 4 radiais em cada descendente)
    comp.bg_size = .Auto
    comp.bg_pos_x = 0; comp.bg_pos_y = 0
    comp.bg_repeat = true
    comp.bg_origin = .Padding
    comp.bg_clip = .Border // background-clip não herda; inicial = border-box
    comp.bg_fixed = false // background-attachment não herda
    comp.obj_fit        = .Fill
    comp.obj_pos_x = 0.5; comp.obj_pos_y = 0.5 // object-position não herda; padrão centro
    comp.valign = .Baseline // vertical-align não herda
    comp.trans = {} // transition não herda
    comp.anim_more = nil
    comp.anim = {}          // animation não herda
    // comp.cursor NÃO é resetado: herda do pai (comportamento CSS)
    comp.scroll_smooth = false // scroll-behavior não herda
    comp.scroll_margin_top = 0; comp.scroll_padding_top = 0 // scroll-margin/padding não herdam
    comp.overscroll_contain = false // overscroll-behavior não herda
    comp.appearance_none = false // appearance não herda
    comp.overflow_hidden = false
    comp.ovf_clip_x = false
    comp.ovf_clip_y = false
    comp.overflow_scroll = false
    comp.ovf_scroll_x = false
    comp.ovf_scroll_y = false
    comp.scroll_container = false
    comp.resize = .None // resize não herda
    comp.ellipsis = false // text-overflow não herda
    comp.line_clamp = 0
    comp.float = .None
    comp.clear = .None
    comp.z_index   = 0
    comp.z_index_set = false
    comp.stacking_hint = false
    comp.opacity   = 1.0
    comp.isolate   = false // isolation não herda
    comp.clip_path = {}    // clip-path não herda
    comp.mask_grad = {}    // mask-image não herda
    comp.table_fixed = false // table-layout não herda
    comp.blend_mode = .Normal
    comp.n_filters = 0
    comp.n_backdrop = 0 // backdrop-filter não herda
    transform_reset(&comp)
    comp.transform_ox   = 0.5; comp.transform_oy = 0.5
    // `comp` ainda é a cópia do PAI neste ponto: lê o preserve-3d dele antes de
    // zerar o nosso (transform-style não herda; o que desce é só "meu pai tem").
    comp.in_p3d = comp.preserve_3d
    comp.preserve_3d = false
    comp.perspective = 0; comp.perspective_ox = 0.5; comp.perspective_oy = 0.5
    comp.perspective_opx=0; comp.perspective_opy=0
    comp.transform_opx=0; comp.transform_opy=0; comp.transform_opz=0
    comp.backface_hidden = false
    comp.has_offset_path = false; comp.offset_path = ""
    comp.offset_distance = 0; comp.offset_distance_pct = false
    comp.offset_rotate_auto = true; comp.offset_rotate_angle = 0
    comp.cb_abs = false; comp.cb_fixed = false // will-change não herda
    comp.contained = false // `contain` não herda
    comp.shadow_n = 0
    // flags "definido neste elemento" (não herdam) — p/ propagar a filhos inline
    comp.has_color = false
    comp.has_font_family = false

    elem_vars := vars // variáveis CSS visíveis a este nó (herdadas)

    if n.kind == .Element {
        cands := make([dynamic]int, 0, 32, context.temp_allocator)
        node_passes: Pass_Set // que passes as regras candidatas deste nó pedem
        query_candidates(idx, n, &cands, &node_passes)
        merged := collect_decls(n, rules, cands[:], viewport_w, .None, .None, styles, idx.pass_mask, comp.direction, vars, comp.writing_mode)

        // custom properties (--nome) definidas aqui sobrescrevem p/ a subárvore
        own := false
        for prop, val in merged {
            if strings.has_prefix(prop, "--") {
                if !own { elem_vars = clone_vars(vars); own = true }
                elem_vars[prop] = val
            }
        }

        // `@property … { inherits: false }`: a propriedade NÃO atravessa a
        // fronteira do elemento. Quem não a declara volta ao valor INICIAL, em vez
        // de enxergar a do ancestral. Só há trabalho quando algum ancestral de fato
        // declarou (senão o valor herdado JÁ é o inicial, posto pela regra
        // sintética `:root`) — então o caso comum não clona o mapa.
        for np in noinh {
            if _, mine := merged[np.name]; mine do continue // declarada AQUI: vale
            cur, has := elem_vars[np.name]
            if !has || cur == np.initial do continue        // já está no inicial
            if !own { elem_vars = clone_vars(vars); own = true }
            elem_vars[np.name] = np.initial
        }

        // attr() (CSS Values 5): resolvido AQUI porque precisa dos atributos do
        // nó (apply_decls não os tem). Coleta antes p/ não mutar o map em iteração.
        // `content` NÃO entra aqui: sua sintaxe é uma SEQUÊNCIA (strings + attr() +
        // aspas) resolvida pelo tokenizador em apply_decls (que recebe o nó), não uma
        // simples substituição de valor — pré-resolver quebraria a concatenação.
        attr_props := make([dynamic]string, context.temp_allocator)
        for prop, val in merged do if strings.contains(val, "attr(") && prop != "content" do append(&attr_props, prop)
        for prop in attr_props {
            if resolved, ok := resolve_attr(merged[prop], n, comp.font_size, viewport_w, viewport_h); ok {
                merged[prop] = resolved
            } else {
                delete_key(&merged, prop) // attr inválido sem fallback → declaração descartada
            }
        }

        // estilo padrão do "user agent" (ex.: <button>) — ANTES do CSS do autor,
        // para que regras da página possam sobrescrevê-lo.
        apply_ua_defaults(n, &comp)

        // Atributos de APRESENTAÇÃO legados (HTML): bgcolor → background-color. Baixa
        // prioridade — o CSS do autor (apply_decls, a seguir) sobrepõe. Comum em
        // layouts de tabela antigos (ex.: Hacker News: header #ff6600, corpo #f6f6ef).
        if bg, ok := n.attrs["bgcolor"]; ok {
            if col, cok := csspkg.parse_color(strings.trim_space(bg)); cok { comp.has_bg = true; comp.bg = col }
        }
        // width/height como atributo de apresentação (table/td/th/col/hr/…): "85%"
        // ou "600". NÃO para <img> (dimensionado pelo intrínseco/req_w). O CSS vence.
        if n.tag != "img" && n.tag != "svg" {
            if wv, ok := n.attrs["width"]; ok && !comp.has_width {
                wt := strings.trim_space(wv)
                if strings.has_suffix(wt, "%") {
                    if f, k := strconv.parse_f64(wt[:len(wt) - 1]); k { comp.has_width = true; comp.width = f32(f) / 100; comp.width_pct = true }
                } else if f, k := strconv.parse_f64(wt); k { comp.has_width = true; comp.width = f32(f); comp.width_pct = false }
            }
        }
        // <font color> / atributo `color` em <font>: cor de texto legada.
        if n.tag == "font" {
            if fc, ok := n.attrs["color"]; ok {
                if col, cok := csspkg.parse_color(strings.trim_space(fc)); cok { comp.has_color = true; comp.color = col }
            }
            // <font size>: 1..7 (absoluto) ou ±N (relativo ao 3), mapeados nas
            // palavras de tamanho pelo HTML rendering spec §15.3.2. Sem isto o
            // atributo era IGNORADO — e o reftest css-fonts/font-size-xxx-large
            // (que compara `font-size:xxx-large` com `<font size=7>`) passava pelo
            // motivo errado: os DOIS lados caíam em 16px. Ao implementar
            // `xxx-large` no parse_font_size, o outro lado do par apareceu.
            if sv, ok := n.attrs["size"]; ok {
                s := strings.trim_space(sv)
                rel := 0
                if len(s) > 0 && (s[0] == '+' || s[0] == '-') do rel = 3 // base do relativo
                if nnum, k := strconv.parse_int(s, 10); k {
                    lvl := rel == 0 ? nnum : rel + nnum
                    lvl = clamp(lvl, 1, 7)
                    // literal composto indexado por VARIÁVEL vira variável antes
                    tabela := [8]string{"", "xx-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"}
                    kw := tabela[lvl]
                    if px, pk := parse_font_size(kw, comp.font_size, viewport_w, viewport_h); pk {
                        comp.font_size = px
                        comp.has_font_size = true
                    }
                }
            }
        }

        apply_decls(&comp, merged, elem_vars, viewport_w, viewport_h, n)
        if v, ok := merged["z-index"]; ok && strings.equal_fold(strings.trim_space(resolve_var(v, elem_vars)), "inherit") {
            comp.z_index = inherit.z_index
            comp.z_index_set = inherit.z_index_set
        }
        // A fonte do elemento RAIZ define o `rem` do resto da página. Gravado aqui:
        // as declarações da raiz já foram aplicadas e a recursão nos filhos só vem
        // depois — então todo descendente já enxerga a base certa.
        // ⚠️ as declarações da PRÓPRIA raiz que usam `rem` ficam com o valor
        // anterior (o inicial), que é o que a spec manda para o `font-size` da raiz
        // — e é a mesma ordem-de-propriedade que o `em` já tem neste motor.
        if n.kind == .Element && n.tag == "html" do g_root_font_size = comp.font_size
        // `background-clip: inherit` — a palavra-chave `inherit` (CSS Values §4.4)
        // pega o valor COMPUTADO do pai. Fica AQUI, e não no apply_decls, porque
        // só o compute_node tem o Computed do pai. Tratamento PONTUAL: o motor não
        // tem `inherit` genérico (o único outro caso é `cursor`), e esta é a prop
        // onde a falta doía — enquanto bg_clip vazava por herança, `inherit`
        // "funcionava" por acidente; ao parar o vazamento (bg_clip não herda), o
        // wpt css-backgrounds/background-clip-006 expôs a palavra-chave faltando.
        for p in ([?]string{"background-clip", "-webkit-background-clip"}) {
            if v, ok := merged[p]; ok && strings.equal_fold(strings.trim_space(v), "inherit") {
                comp.bg_clip = inherit.bg_clip
            }
        }
        // `font-weight: inherit` — mesmo motivo (só aqui existe o Computed do pai),
        // mas com um agravante: `apply_ua_defaults` já pôs .Bold em h1..h6 ANTES
        // das declarações do autor, então o `comp` que o apply_decls vê não tem
        // mais o peso herdado — só `inherit.weight` tem. É o reset que TODO
        // preflight moderno faz (`h1,…,h6 { font-weight: inherit }`, Tailwind
        // incluso): sem isto, todo heading dentro de card/lista sai em negrito.
        if v, ok := merged["font-weight"]; ok {
            fw := strings.trim_space(v)
            if strings.equal_fold(fw, "inherit") do comp.weight = inherit.weight
            // `bolder`/`lighter` são relativos ao peso do PAI — pelo mesmo
            // agravante do h1..h6 (o apply_decls só viu o 700 do UA).
            for kw in ([?]string{"bolder", "lighter"}) {
                if strings.equal_fold(fw, kw) {
                    if w, k := font_weight_token(kw, inherit.weight); k do comp.weight = w
                }
            }
        }
        // ── palavras-chave CSS-wide (Values §7.3) que precisam do PAI ou do INICIAL ──
        //
        // Duas metades, e só estas duas precisam de código:
        //   • `inherit` numa prop que NÃO herda — o valor tem de vir do pai, e só
        //     aqui existe o Computed dele. O caso que doía é o reset clássico
        //     `html{box-sizing:border-box} *{box-sizing:inherit}`: sem isto a
        //     página inteira ficava em content-box (a declaração era ignorada) e
        //     toda largura com padding saía maior.
        //   • `initial` numa prop que HERDA — tem de QUEBRAR a herança. O `comp`
        //     chega como cópia do pai, então ignorar a declaração deixava o valor
        //     herdado: `color: initial` mantinha o vermelho do pai.
        //
        // As outras combinações JÁ estavam certas por construção e continuam sem
        // código: `inherit`/`unset` em prop que herda = o valor que `comp` já traz;
        // `initial`/`unset` em prop que não herda = o reset das não-herdadas que
        // roda logo acima; `revert` = o valor do UA, que também já está em `comp`.
        {
            ini := computed_initial()
            kw :: proc(merged: map[string]string, prop: string) -> (inh: bool, init: bool) {
                v, ok := merged[prop]
                if !ok do return false, false
                t := strings.trim_space(v)
                return strings.equal_fold(t, "inherit"), strings.equal_fold(t, "initial")
            }
            // `inherit` em prop que NÃO herda
            if i, _ := kw(merged, "box-sizing");  i do comp.box_sizing = inherit.box_sizing
            if i, _ := kw(merged, "display");     i {
                comp.display_none         = inherit.display_none
                comp.display_block        = inherit.display_block
                comp.display_inline       = inherit.display_inline
                comp.display_inline_block = inherit.display_inline_block
                comp.display_flex         = inherit.display_flex
                comp.display_grid         = inherit.display_grid
                comp.display_contents     = inherit.display_contents
                comp.display_inline_level = inherit.display_inline_level
            }
            if i, _ := kw(merged, "background-color"); i { comp.bg = inherit.bg; comp.has_bg = inherit.has_bg }
            // `initial` em prop que HERDA
            if _, x := kw(merged, "color");          x do comp.color          = ini.color
            if _, x := kw(merged, "font-weight");    x do comp.weight         = ini.weight
            if _, x := kw(merged, "font-style");     x do comp.italic         = ini.italic
            if _, x := kw(merged, "font-size");      x do comp.font_size      = ini.font_size
            if _, x := kw(merged, "line-height");    x do comp.line_height    = ini.line_height
            if _, x := kw(merged, "text-align");     x do comp.text_align     = ini.text_align
            if _, x := kw(merged, "letter-spacing"); x do comp.letter_spacing = ini.letter_spacing
            if _, x := kw(merged, "font-kerning"); x do comp.font_kerning = ini.font_kerning
            if _, x := kw(merged, "word-spacing");   x do comp.word_spacing   = ini.word_spacing
            if _, x := kw(merged, "white-space");    x do comp.white_space    = ini.white_space
            if _, x := kw(merged, "overflow-wrap"); x { comp.break_word = false; comp.wrap_anywhere = false }
            if _, x := kw(merged, "word-wrap"); x { comp.break_word = false; comp.wrap_anywhere = false }
            if _, x := kw(merged, "word-break"); x do comp.break_all = false
            if _, x := kw(merged, "visibility");     x do comp.invisible      = ini.invisible
            if _, x := kw(merged, "text-transform"); x do comp.text_transform = ini.text_transform
            if _, x := kw(merged, "list-style-type"); x do comp.list_style    = ini.list_style
            if _,x:=kw(merged,"writing-mode"); x do comp.writing_mode=.Horizontal
            if _,x:=kw(merged,"text-orientation"); x do comp.text_orientation=.Mixed
            if _, x := kw(merged, "direction");      x do comp.direction      = ini.direction
            if _, x := kw(merged, "text-indent"); x { comp.text_indent = 0; comp.text_indent_pct = false; comp.indent_each_line = false; comp.indent_hanging = false }
            if _, x := kw(merged, "text-align-last"); x do comp.has_text_align_last = false
        }
        if comp.text_align == .Match_Parent do comp.text_align = align_physical(inherit.text_align, inherit.direction)
        resolve_animation(&comp, merged, kf, elem_vars, viewport_w, viewport_h)
        collect_svg_css(&comp, merged, elem_vars, viewport_w, viewport_h)
        delete(merged)

        // float/clear LÓGICOS (css-logical): inline-start/end → físico conforme a
        // prop CSS `direction` (herdada) do elemento (LTR: start=left/end=right; RTL:
        // invertido). Resolvido aqui (não em apply_decls) por consistência de fase.
        if comp.float >= .InlineStart || comp.clear >= .InlineStart {
            rtl := comp.direction == .Rtl
            switch comp.float {
            case .InlineStart: comp.float = rtl ? .Right : .Left
            case .InlineEnd:   comp.float = rtl ? .Left : .Right
            case .None, .Left, .Right:
            }
            switch comp.clear {
            case .InlineStart: comp.clear = rtl ? .Right : .Left
            case .InlineEnd:   comp.clear = rtl ? .Left : .Right
            case .None, .Left, .Right, .Both:
            }
        }

        // grid-area: resolve nome contra o mapa de áreas do pai
        if comp.grid_area_name != "" {
            for i in 0 ..< inherit.grid_area_n {
                if inherit.grid_areas[i].name == comp.grid_area_name {
                    comp.grid_col_start = inherit.grid_areas[i].col + 1
                    comp.grid_col_span  = inherit.grid_areas[i].col_span
                    comp.grid_row_start = inherit.grid_areas[i].row + 1
                    comp.grid_row_span  = inherit.grid_areas[i].row_span
                    break
                }
            }
            comp.grid_area_name = ""
        }
        // grid-column / grid-row por NOME de linha: resolve contra o container pai
        if comp.grid_col_start_name != "" {
            cl := inherit.grid_col_lines // cópia local: array-fixo de campo não é sliceável direto
            if s, sp, ok := grid_resolve_named(cl[:inherit.grid_col_line_n], comp.grid_col_start_name, comp.grid_col_end_name); ok {
                comp.grid_col_start = s; comp.grid_col_span = sp
            }
        }
        if comp.grid_row_start_name != "" {
            rl := inherit.grid_row_lines
            if s, sp, ok := grid_resolve_named(rl[:inherit.grid_row_line_n], comp.grid_row_start_name, comp.grid_row_end_name); ok {
                comp.grid_row_start = s; comp.grid_row_span = sp
            }
        }
        comp.grid_col_start_name = ""; comp.grid_col_end_name = ""
        comp.grid_row_start_name = ""; comp.grid_row_end_name = ""
        // Linha NEGATIVA (`grid-column: 2 / -2`) conta do FIM do grid explícito do
        // PAI: com N tracks existem N+1 linhas, então -1 = N+1, -2 = N. O nº de
        // tracks só existe aqui, por isso o parser guardou o valor cru.
        comp.grid_col_start, comp.grid_col_span =
            grid_resolve_negative(comp.grid_col_start, comp.grid_col_span, comp.grid_col_end_line, inherit.grid_track_n)
        comp.grid_row_start, comp.grid_row_span =
            grid_resolve_negative(comp.grid_row_start, comp.grid_row_span, comp.grid_row_end_line, inherit.grid_row_track_n)
        comp.grid_col_end_line = 0; comp.grid_row_end_line = 0
        // grid-template-areas implica tracks automáticos se não declarados
        if comp.grid_area_n > 0 {
            if comp.grid_track_n == 0 {
                nc := 0
                for i in 0 ..< comp.grid_area_n do nc = max(nc, comp.grid_areas[i].col + comp.grid_areas[i].col_span)
                if nc > GRID_MAX_TRACKS do nc = GRID_MAX_TRACKS
                comp.grid_track_n = nc
                for i in 0 ..< nc do comp.grid_tracks[i] = Grid_Track{kind = .Auto}
            }
            if comp.grid_row_track_n == 0 {
                nr := 0
                for i in 0 ..< comp.grid_area_n do nr = max(nr, comp.grid_areas[i].row + comp.grid_areas[i].row_span)
                if nr > GRID_MAX_TRACKS do nr = GRID_MAX_TRACKS
                comp.grid_row_track_n = nr
                for i in 0 ..< nr do comp.grid_row_tracks[i] = Grid_Track{kind = .Auto}
            }
        }

        // pseudo-elementos ::before / ::after (só geram caixa se tiverem `content`)
        // e ::first-letter. Os três — e o :hover abaixo — só rodam se ALGUMA regra
        // candidata deste nó pode alimentar o passe; senão o resultado seria nil/
        // vazio de qualquer jeito, depois de varrer todos os candidatos à toa.
        if .Before in node_passes {
            comp.before = compute_pseudo(n, comp, elem_vars, rules, cands[:], .Before, viewport_w, viewport_h, styles, idx.pass_mask)
        }
        if .After in node_passes {
            comp.after = compute_pseudo(n, comp, elem_vars, rules, cands[:], .After, viewport_w, viewport_h, styles, idx.pass_mask)
        }
        if .First_Letter in node_passes {
            comp.first_letter = compute_first_letter(n, comp, elem_vars, rules, cands[:], viewport_w, viewport_h, styles, idx.pass_mask)
        }
        // ::placeholder — só faz sentido em campo de texto; a guarda por TAG evita
        // varrer candidatos p/ todo elemento da página (o passe roda por nó).
        if .Placeholder in node_passes && (n.tag == "input" || n.tag == "textarea") {
            comp.placeholder = compute_placeholder(n, comp, elem_vars, rules, cands[:], viewport_w, viewport_h, styles, idx.pass_mask)
        }

        // :hover — declarações do estado, aplicadas a uma cópia; guardamos só os
        // deltas de PINTURA (sem re-layout). Ativado por frame em paint_box.
        hov: map[string]string
        if .Hover in node_passes {
            hov = collect_decls(n, rules, cands[:], viewport_w, .None, .Hover, styles, idx.pass_mask, comp.direction, elem_vars, comp.writing_mode)
        }
        defer delete(hov)
        if len(hov) > 0 {
            hc := comp
            // O transform do :hover SUBSTITUI o da base, não compõe com ele. Como
            // `hc` nasce da cópia já transformada e o apply_decls ACUMULA (rot +=,
            // sx *=), `.x{transform:rotate(45deg)} .x:hover{transform:rotate(45deg)
            // scale(1.2)}` girava 90° no hover, e `:hover{transform:none}` não
            // desfazia nada. Zera os campos e reaplica o grupo inteiro: do :hover
            // o que ele declarou, da base o que ele não tocou (as quatro props
            // caem nos mesmos campos, então são resolvidas juntas).
            XF_PROPS :: [?]string{"transform", "translate", "rotate", "scale"}
            hov_xf := false
            for p in XF_PROPS do if p in hov { hov_xf = true; break }
            if hov_xf {
                for p in XF_PROPS {
                    if p in hov do continue
                    if v, ok := merged[p]; ok do hov[p] = v
                }
                transform_reset(&hc)
            }
            apply_decls(&hc, hov, elem_vars, viewport_w, viewport_h, n)
            comp.hover.active = true
            if hc.color != comp.color            { comp.hover.has_color    = true; comp.hover.color    = hc.color }
            if hc.has_bg && (!comp.has_bg || hc.bg != comp.bg) { comp.hover.has_bg = true; comp.hover.bg = hc.bg }
            if hc.has_border && hc.border_c[0] != comp.border_c[0] { comp.hover.has_border_c = true; comp.hover.border_c = hc.border_c[0] }
            if hc.opacity != comp.opacity        { comp.hover.has_opacity  = true; comp.hover.opacity  = hc.opacity }
            if hc.shadow_n != comp.shadow_n || hc.shadows != comp.shadows {
                comp.hover.has_shadow = true
                comp.hover.shadows = hc.shadows; comp.hover.shadow_n = hc.shadow_n
            }
            // text-decoration: compara a decoração INTEIRA e também o `deco_set`.
            // Sem o segundo, `a:hover{text-decoration:none}` sem regra normal some:
            // os dois lados têm underline=false (o sublinhado do link só nasce no
            // build_inline_items, por `!deco_set`) e o delta pareceria vazio.
            if hcd, cd := deco_of(hc), deco_of(comp); hcd != cd || hc.deco_set != comp.deco_set {
                comp.hover.has_deco = true; comp.hover.deco = hcd; comp.hover.deco_set = hc.deco_set
            }
            // transform no hover: guarda os valores-alvo (a transition anima deles)
            if hc.xform!=comp.xform || hc.has_transform || hc.transform_rot != comp.transform_rot ||
               hc.transform_sx != comp.transform_sx || hc.transform_sy != comp.transform_sy ||
               hc.transform_tx != comp.transform_tx || hc.transform_ty != comp.transform_ty {
                comp.hover.has_transform = true
                comp.hover.xform = hc.xform
                comp.hover.tx = hc.transform_tx; comp.hover.ty = hc.transform_ty
                comp.hover.tx_pct = hc.transform_tx_pct; comp.hover.ty_pct = hc.transform_ty_pct
                comp.hover.rot = hc.transform_rot
                comp.hover.sx = hc.transform_sx; comp.hover.sy = hc.transform_sy
                comp.hover.back = hc.xf_back
            }
        }
    }

    styles[n] = comp

    child_inherit := comp
    child_inherit.has_bg = false
    child_inherit.deco_set = false // "autor definiu text-decoration" é por-elemento
    child_inherit.display_none = false
    child_inherit.hover = {} // :hover pertence só a este nó (não herda)
    child_inherit.anim_more = nil
    child_inherit.anim = {}  // animation não herda
    // Os pseudo-elementos ::before/::after pertencem SÓ a este nó. Sem isto, os
    // filhos herdam os ponteiros ^Computed do pai; nós que não são Element pulam
    // a atribuição em 308-309 e ficam com o ponteiro aliased → free_styles libera
    // o mesmo ponteiro em duas entradas do mapa (double free / crash na 2ª navegação).
    child_inherit.before = nil
    child_inherit.after  = nil
    child_inherit.first_letter = nil
    child_inherit.placeholder  = nil
    child_inherit.svg_css = nil // mesmo motivo dos ^Computed: alias vira double-free
    for c in n.children {
        compute_node(c, child_inherit, elem_vars, rules, idx, styles, viewport_w, viewport_h, kf, noinh)
    }
}

// Computa o estilo de um pseudo-elemento ::before/::after do nó n. Devolve nil se
// não houver regra com `content` (nesse caso não há caixa gerada). O pseudo herda
// cor/fonte/line-height/família do elemento pai.
// Libera os pseudo-elementos (::before/::after) que compute_styles alocou e então
// o mapa. Usar no lugar de delete(styles) — delete(map) sozinho vaza os ^Computed.
free_styles :: proc(styles: map[^dompkg.Node]Computed) {
    x_free_styles(styles)
    // o painter segura um ALIAS deste mapa; soltar antes de liberar os buckets
    svg_css_clear()
    for _, comp in styles {
        if comp.before != nil { delete(comp.before.content); free(comp.before) }
        if comp.after  != nil { delete(comp.after.content);  free(comp.after)  }
        if comp.first_letter != nil { free(comp.first_letter) }
        if comp.placeholder  != nil { free(comp.placeholder)  }
        if comp.svg_css != nil { free(comp.svg_css) }
    }
    delete(styles)
}

@(private="file")
compute_pseudo :: proc(n: ^dompkg.Node, parent: Computed, vars: map[string]string, rules: ^[dynamic]csspkg.Rule, candidates: []int, kind: csspkg.Pseudo_Kind, vw: f32, vh: f32, styles: ^map[^dompkg.Node]Computed = nil, masks: []Pass_Set = nil) -> ^Computed {
    decls := collect_decls(n, rules, candidates, vw, kind, .None, styles, masks, parent.direction, vars, parent.writing_mode)
    defer delete(decls)
    if _, ok := decls["content"]; !ok do return nil // sem content → sem pseudo

    pc := Computed{
        color = parent.color, font_size = parent.font_size,
        line_height = parent.line_height, font_family = parent.font_family,
        italic = parent.italic, weight = parent.weight,
        font_fam_id = parent.font_fam_id, invisible = parent.invisible,
        white_space = parent.white_space, text_transform = parent.text_transform,
        direction = parent.direction, text_align = parent.text_align,
        writing_mode = parent.writing_mode, text_orientation = parent.text_orientation,
        tab_size = parent.tab_size, word_spacing = parent.word_spacing,
        text_indent = parent.text_indent, text_indent_pct = parent.text_indent_pct,
        indent_each_line = parent.indent_each_line, indent_hanging = parent.indent_hanging,
        letter_spacing = parent.letter_spacing, font_kerning = parent.font_kerning,
        opacity = 1.0, deco_color = DECO_UNSET,
        // transform neutro (escala 1, origem 50%, matriz identidade). Sem isto os
        // campos ficam em 0 e o paint dispara um xform de matriz-zero que colapsa
        // o pseudo a um ponto (bg + texto somem). `apply_decls` multiplica scale.
        transform_sx = 1, transform_sy = 1, transform_ox = 0.5, transform_oy = 0.5,
        xf_a = 1, xf_d = 1,
    }
    apply_decls(&pc, decls, vars, vw, vh, n)
    if !pc.has_content do return nil // content:none/normal

    out := new(Computed)
    out^ = pc
    out.content = strings.clone(pc.content) // persistente p/ o layout
    out.before = nil; out.after = nil; out.first_letter = nil; out.placeholder = nil
    return out
}

// Computa o estilo de ::first-letter. Diferente de compute_pseudo, NÃO exige
// `content` (a 1ª letra do texto real é o conteúdo). Devolve nil se não houver
// nenhuma regra ::first-letter. Herda cor/fonte/etc do elemento pai.
@(private="file")
compute_first_letter :: proc(n: ^dompkg.Node, parent: Computed, vars: map[string]string, rules: ^[dynamic]csspkg.Rule, candidates: []int, vw: f32, vh: f32, styles: ^map[^dompkg.Node]Computed = nil, masks: []Pass_Set = nil) -> ^Computed {
    decls := collect_decls(n, rules, candidates, vw, .FirstLetter, .None, styles, masks, parent.direction, vars, parent.writing_mode)
    defer delete(decls)
    if len(decls) == 0 do return nil // sem regra ::first-letter

    pc := Computed{
        color = parent.color, font_size = parent.font_size,
        line_height = parent.line_height, font_family = parent.font_family,
        italic = parent.italic, weight = parent.weight,
        opacity = 1.0, deco_color = DECO_UNSET,
        transform_sx = 1, transform_sy = 1, transform_ox = 0.5, transform_oy = 0.5,
        xf_a = 1, xf_d = 1,
    }
    apply_decls(&pc, decls, vars, vw, vh, n)

    out := new(Computed)
    out^ = pc
    out.before = nil; out.after = nil; out.first_letter = nil; out.placeholder = nil
    return out
}

// ::placeholder (M218) — estilo do texto-DICA de <input>/<textarea>. Como o
// ::first-letter, NÃO exige `content`: o conteúdo é o atributo `placeholder`.
// Devolve nil se não houver regra nenhuma.
//
// Existe porque `::placeholder` era DESCARTADO (casava com nada), e o idioma do
// "label flutuante" — `input::placeholder{opacity:0}` + o rótulo posicionado por
// cima, revelando a dica só no foco — fazia o motor pintar OS DOIS ao mesmo tempo.
// No github.com o "Enter your email" saía sobreposto ao "you@domain.com".
@(private="file")
compute_placeholder :: proc(n: ^dompkg.Node, parent: Computed, vars: map[string]string, rules: ^[dynamic]csspkg.Rule, candidates: []int, vw: f32, vh: f32, styles: ^map[^dompkg.Node]Computed = nil, masks: []Pass_Set = nil) -> ^Computed {
    decls := collect_decls(n, rules, candidates, vw, .Placeholder, .None, styles, masks, parent.direction, vars, parent.writing_mode)
    defer delete(decls)
    if len(decls) == 0 do return nil

    pc := Computed{
        color = parent.color, font_size = parent.font_size,
        line_height = parent.line_height, font_family = parent.font_family,
        italic = parent.italic, weight = parent.weight,
        opacity = 1.0, deco_color = DECO_UNSET,
        transform_sx = 1, transform_sy = 1, transform_ox = 0.5, transform_oy = 0.5,
        xf_a = 1, xf_d = 1,
    }
    apply_decls(&pc, decls, vars, vw, vh, n)

    out := new(Computed)
    out^ = pc
    out.before = nil; out.after = nil; out.first_letter = nil; out.placeholder = nil
    return out
}

@(private="file")
clone_vars :: proc(v: map[string]string) -> map[string]string {
    out := make(map[string]string, context.temp_allocator)
    for k, val in v do out[k] = val
    return out
}

// Resolve var(--nome) / var(--nome, fallback) num valor CSS.
@(private="file")
resolve_var :: proc(val: string, vars: map[string]string, depth := 0) -> string {
    if depth > 8 do return val
    start := strings.index(val, "var(")
    if start < 0 do return val

    open := start + 3 // posição do '('
    paren := 0
    i := open
    for i < len(val) {
        if val[i] == '(' do paren += 1
        else if val[i] == ')' { paren -= 1; if paren == 0 do break }
        i += 1
    }
    if i >= len(val) do return val

    inside := val[open + 1:i]
    name := strings.trim_space(inside)
    fallback := ""
    if comma := strings.index_byte(inside, ','); comma >= 0 {
        name = strings.trim_space(inside[:comma])
        fallback = strings.trim_space(inside[comma + 1:])
    }

    // Uma custom property com valor `initial` é o VALOR GARANTIDO-INVÁLIDO (CSS
    // Variables §3): var() a trata como se estivesse ausente → usa o fallback.
    // Padrão ONIPRESENTE no Tailwind v4: `--tw-shadow-color: initial` +
    // `box-shadow: … var(--tw-shadow-color, #00000040)`. Sem isto, substituíamos o
    // literal "initial" na cor → sombra inválida → cards CHAPADOS no site inteiro.
    repl := fallback
    if rv, ok := vars[name]; ok && !strings.equal_fold(strings.trim_space(rv), "initial") {
        repl = rv
    }

    result := strings.concatenate({val[:start], repl, val[i + 1:]}, context.temp_allocator)
    return resolve_var(result, vars, depth + 1)
}

// ── Índice de regras (performance) ───────────────────────────────────────────
// Sem índice, cada nó testava TODAS as regras: O(nós × regras) ≈ 15M testes de
// seletor numa página como a Wikipédia (~5s). O índice agrupa as regras pelo
// COMPOSTO-CHAVE (o composto mais à direita do seletor — o que descreve o alvo)
// por tag / classe / id. Um nó só considera as regras cujo composto-chave bate
// com a sua tag/id/classe, mais as universais. Reduz de milhares p/ dezenas.

// ── Passes de coleta ────────────────────────────────────────────────────────
// O compute_node chama collect_decls CINCO vezes por elemento — estilo normal,
// ::before, ::after, ::first-letter e :hover — e cada chamada re-varria TODOS
// os candidatos fazendo casamento de seletor COMPLETO. Como a esmagadora
// maioria dos elementos não tem regra de pseudo nem de :hover casando neles,
// quatro dessas cinco varreduras faziam o trabalho inteiro só p/ devolver vazio.
//
// Agora cada REGRA carrega no índice o conjunto de passes em que ela PODE ser
// aceita, derivado do mesmo predicado que o collect_decls aplica. Com isso:
//   - collect_decls rejeita o candidato em O(1) ANTES de casar seletor;
//   - compute_node NEM CHAMA o passe quando nenhum candidato do nó o pede,
//     poupando junto o mapa temporário que cada chamada aloca.
//
// `Unknown` = combinação que nenhum passe atual coleta mas que também não é
// seguro declarar impossível (pseudo/estado novo que ninguém mapeou aqui). O
// candidato então passa direto pelo filtro, caindo no comportamento antigo —
// perde-se a otimização, nunca a correção.
// ⚠️ 9 bits desde o M218 (Placeholder): o bit_set precisa de u16, não cabe mais em u8.
Pass_Bit :: enum u8 { Plain, Before, After, First_Letter, Placeholder, Hover, Focus, Active, Unknown }
Pass_Set :: bit_set[Pass_Bit; u16]

// Em quais passes este seletor pode ser aceito? ESPELHA o predicado de
// aceitação do collect_decls — se um mudar, o outro TEM de mudar junto.
@(private="file")
selector_passes :: proc(sel: csspkg.Selector) -> Pass_Set {
    if len(sel.parts) == 0 do return {}
    last := sel.parts[len(sel.parts) - 1]

    if last.state == .None {
        // No passe com state==.None o collect_decls rejeita se QUALQUER composto
        // exige estado (`.menu:hover .item` nunca vale no render estático). Como
        // last.state já é .None aqui, basta olhar os ancestrais.
        for i in 0 ..< len(sel.parts) - 1 {
            if sel.parts[i].state != .None do return {}
        }
        #partial switch last.pseudo {
        case .None, .Other: return {.Plain} // Other (:nth/:not/…) entra no passe normal
        case .Before:       return {.Before}
        case .After:        return {.After}
        case .FirstLetter:  return {.First_Letter}
        case .Placeholder:  return {.Placeholder}
        }
        return {.Unknown}
    }

    // last.state != .None: só é aceito no passe daquele estado, e todo passe de
    // estado usa want==.None — logo o pseudo-alvo tem de ser None/Other.
    // (`::before:hover` não é coletado por passe nenhum hoje.)
    if last.pseudo != .None && last.pseudo != .Other do return {}
    #partial switch last.state {
    case .Hover:  return {.Hover}
    case .Focus:  return {.Focus}
    case .Active: return {.Active}
    }
    return {.Unknown}
}

// Passe correspondente a (want, state). ok=false → combinação não mapeada: o
// collect_decls não filtra nada (comportamento antigo).
@(private="file")
pass_of :: proc(want: csspkg.Pseudo_Kind, state: csspkg.Element_State) -> (Pass_Bit, bool) {
    if state == .None {
        #partial switch want {
        case .None:        return .Plain, true
        case .Before:      return .Before, true
        case .After:       return .After, true
        case .FirstLetter: return .First_Letter, true
        case .Placeholder: return .Placeholder, true
        }
        return .Unknown, false
    }
    if want != .None do return .Unknown, false
    #partial switch state {
    case .Hover:  return .Hover, true
    case .Focus:  return .Focus, true
    case .Active: return .Active, true
    }
    return .Unknown, false
}

@(private="file")
Rule_Index :: struct {
    by_id:     map[string][dynamic]int,
    by_class:  map[string][dynamic]int,
    by_tag:    map[string][dynamic]int,
    universal: [dynamic]int, // composto-chave sem tag/id/classe (*, :hover, [attr]…)
    seen:      []int,        // scratch p/ dedup na query (seen[ri] == gen)
    gen:       int,
    pass_mask: []Pass_Set,   // por REGRA: união dos passes dos seus seletores
}

@(private="file")
idx_bucket_add :: proc(m: ^map[string][dynamic]int, key: string, ri: int) {
    if _, ok := m[key]; !ok do m[key] = make([dynamic]int, context.temp_allocator)
    b := &m[key]
    if len(b) > 0 && b[len(b) - 1] == ri do return // já é o último (2 sels, mesma chave)
    append(b, ri)
}

@(private="file")
build_rule_index :: proc(rules: ^[dynamic]csspkg.Rule) -> Rule_Index {
    idx: Rule_Index
    idx.by_id     = make(map[string][dynamic]int, context.temp_allocator)
    idx.by_class  = make(map[string][dynamic]int, context.temp_allocator)
    idx.by_tag    = make(map[string][dynamic]int, context.temp_allocator)
    idx.universal = make([dynamic]int, context.temp_allocator)
    idx.seen      = make([]int, len(rules), context.temp_allocator) // zero-init
    idx.pass_mask = make([]Pass_Set, len(rules), context.temp_allocator)
    for &rule, ri in rules {
        uni := false
        for sel in rule.selectors {
            if len(sel.parts) == 0 do continue
            idx.pass_mask[ri] += selector_passes(sel)
            key := sel.parts[len(sel.parts) - 1] // composto-chave (mais à direita)
            if key.id != "" {
                idx_bucket_add(&idx.by_id, key.id, ri)
            } else if len(key.classes) > 0 {
                idx_bucket_add(&idx.by_class, key.classes[0], ri)
            } else if key.tag != "" && key.tag != "*" {
                idx_bucket_add(&idx.by_tag, key.tag, ri)
            } else if !uni {
                append(&idx.universal, ri) // só uma vez por regra
                uni = true
            }
        }
    }
    return idx
}

@(private="file")
idx_add_bucket :: proc(idx: ^Rule_Index, b: [dynamic]int, out: ^[dynamic]int, mask: ^Pass_Set) {
    for ri in b {
        if idx.seen[ri] == idx.gen do continue // já coletado nesta query
        idx.seen[ri] = idx.gen
        append(out, ri)
        if mask != nil do mask^ += idx.pass_mask[ri]
    }
}

// Coleta em `out` os índices das regras candidatas para o nó (universais + tag +
// id + classes), sem duplicatas. `mask` (opcional) recebe a UNIÃO dos passes que
// os candidatos podem alimentar — o compute_node usa isso p/ pular inteiros os
// passes de pseudo/:hover que nenhuma regra deste nó pede.
@(private="file")
query_candidates :: proc(idx: ^Rule_Index, n: ^dompkg.Node, out: ^[dynamic]int, mask: ^Pass_Set = nil) {
    idx.gen += 1
    idx_add_bucket(idx, idx.universal, out, mask)
    if n.tag != "" {
        if b, ok := idx.by_tag[n.tag]; ok do idx_add_bucket(idx, b, out, mask)
    }
    if id, ok := n.attrs["id"]; ok && id != "" {
        if b, ok2 := idx.by_id[id]; ok2 do idx_add_bucket(idx, b, out, mask)
    }
    if cls, ok := n.attrs["class"]; ok && cls != "" {
        for c in strings.fields(cls, context.temp_allocator) {
            if b, ok2 := idx.by_class[c]; ok2 do idx_add_bucket(idx, b, out, mask)
        }
    }
}

// Junta todas as declarações que se aplicam ao nó, resolvendo a cascata.
// `candidates` = índices das regras a testar (do query_candidates; já filtra ~99%).
// As strings de valor são emprestadas (vivem nas regras / no temp do frame).
@(private="file")
// ── Sonda de CASCATA ────────────────────────────────────────────────────────
// Desligada por default: com CASCADEPROBE=false todo o `when` some do binário.
// Ver o bloco em collect_decls para o porquê e o modo de uso.
CASCADEPROBE :: #config(CASCADEPROBE, false)
CASCADE_ALVO :: #config(CASCADE_ALVO, "") // substring de id/class do nó a espionar
CASCADE_PROP :: #config(CASCADE_PROP, "") // substring da propriedade ("" = todas)

when CASCADEPROBE {
    // Reconstrói um seletor LEGÍVEL a partir da forma parseada (a Rule não guarda
    // o texto original). Aproximado de propósito — serve para IDENTIFICAR a regra
    // no meio de milhares, não para reserializar CSS.
    @(private = "file")
    casc_sel_txt :: proc(r: csspkg.Rule) -> string {
        sb := strings.builder_make(context.temp_allocator)
        for sel, i in r.selectors {
            if i > 0 do strings.write_string(&sb, ", ")
            for p, j in sel.parts {
                if j > 0 do strings.write_byte(&sb, ' ')
                if p.tag != "" do strings.write_string(&sb, p.tag)
                if p.id != "" { strings.write_byte(&sb, '#'); strings.write_string(&sb, p.id) }
                for c in p.classes { strings.write_byte(&sb, '.'); strings.write_string(&sb, c) }
                for _ in p.attrs do strings.write_string(&sb, "[attr]")
                if len(p.nots) > 0 do fmt.sbprintf(&sb, ":not(%d)", len(p.nots))
                if len(p.ors)  > 0 do fmt.sbprintf(&sb, ":is(%d)",  len(p.ors))
                if p.state != .None do fmt.sbprintf(&sb, ":%v", p.state)
                if p.pseudo != .None do fmt.sbprintf(&sb, "::%v", p.pseudo)
            }
        }
        return strings.to_string(sb)
    }
}

collect_decls :: proc(n: ^dompkg.Node, rules: ^[dynamic]csspkg.Rule, candidates: []int, viewport_w: f32, want: csspkg.Pseudo_Kind = .None, state: csspkg.Element_State = .None, styles: ^map[^dompkg.Node]Computed = nil, masks: []Pass_Set = nil, inherited_dir: Directionality = .Ltr, inherited_vars: map[string]string = nil, inherited_mode: Writing_Mode = .Horizontal) -> map[string]string {
    Win :: struct { spec: Cascade_Priority, order: int, val: string }
    wins := make(map[string]Win, context.temp_allocator)
    // Não reduzir antes do rollback: precisamos inclusive dos perdedores da camada.
    originals := make(map[string][dynamic]Win, context.temp_allocator)
    retain :: proc(all: ^map[string][dynamic]Win, prop: string, w: Win) {
        list, ok := all[prop]
        if !ok do list = make([dynamic]Win, context.temp_allocator)
        append(&list, w)
        all[prop] = list
    }

    // Sonda de CASCATA: com `-define:CASCADEPROBE=true` imprime, para o nó cujo
    // id/classe casa CASCADE_ALVO, TODA regra que casou o seletor e TODA
    // declaração da(s) propriedade(s) em CASCADE_PROP — com prio, ordem e
    // important —, e no fim quem venceu. Existe porque três REDUÇÕES seguidas
    // falharam em reproduzir um caso do github (o `padding:0!important` do
    // `.show-on-focus:not(:focus)` perdendo para `.px-2`): quando a fixture não
    // reproduz, o que resta é instrumentar o funil na página REAL.
    //
    // Uso: -define:CASCADEPROBE=true -define:CASCADE_ALVO=js-skip-to-content
    //      -define:CASCADE_PROP=padding
    // ⚠️ `casc_alvo` é declarado FORA do `when` de baixo de propósito: a sonda
    // precisa dele de novo no fim, no bloco de shorthand×longhand. Enquanto o
    // "VENCEU" só era impresso AQUI, a sonda mostrava o `wins` ANTES de qualquer
    // desempate — e portanto era CEGA justamente para o que o M241 faz. Perdi uma
    // rodada de diagnóstico com isso: sondei dois nós do go.dev e os dois saíram
    // "sem conflito", porque a apagada acontece depois deste ponto.
    casc_alvo := false
    when CASCADEPROBE {
        if CASCADE_ALVO != "" && want == .None {
            if id, ok := n.attrs["id"]; ok && strings.contains(id, CASCADE_ALVO) do casc_alvo = true
            if cl, ok := n.attrs["class"]; ok && strings.contains(cl, CASCADE_ALVO) do casc_alvo = true
        }
        if casc_alvo {
            cls := n.attrs["class"]
            fmt.eprintfln("[casc] === <%s class=%q> state=%v  (%d candidatas)", n.tag, cls, state, len(candidates))
        }
    }

    // Filtro O(1) por regra: pula sem casar seletor a regra que não pode ser
    // aceita neste passe (ver Pass_Bit). `masks == nil` ou passe não mapeado →
    // não filtra nada, exatamente como antes.
    pass, pass_ok := pass_of(want, state)
    filter := pass_ok && masks != nil

    // Importância > inline > layer > tupla de especificidade; ordem separada.
    consider :: proc(wins: ^map[string]Win, prop: string, spec: Cascade_Priority, order: int, val: string) {
        if w, ok := wins[prop]; ok {
            if cascade_priority_compare(spec, w.spec) < 0 do return
            if spec == w.spec && order < w.order do return
        }
        wins[prop] = Win{spec, order, val}
    }

    for ri in candidates {
        if filter {
            m := masks[ri]
            if pass not_in m && .Unknown not_in m do continue
        }
        rule := &rules[ri]
        vh_mq := g_viewport_h > 0 ? g_viewport_h : 720 // ver a nota no g_viewport_h
        if !csspkg.media_matches(rule^, viewport_w, vh_mq, g_prefers_dark) do continue
        // @container: avalia contra o CONTÊINER medido (com fallback p/ viewport)
        if rule.cq_active && !container_matches(rule^, n, styles, viewport_w) do continue
        best: [3]int
        matched := false
        exact := false // algum seletor exato (sem aproximação) casou?
        for sel in rule.selectors {
            if len(sel.parts) == 0 do continue
            // roteia por pseudo-alvo: estilo do elemento (None) vs ::before/::after.
            // None aceita também Other (:hover/:nth… aproximados como sempre ativos).
            last := sel.parts[len(sel.parts) - 1]
            tp := last.pseudo
            accept := want == .None ? (tp == .None || tp == .Other) : (tp == want)
            // estado (:hover/:focus/:active): só casa no pass do mesmo estado.
            // Assim regras :hover NÃO entram no estilo normal (antes vazavam
            // como se fossem sempre ativas).
            if last.state != state do accept = false
            // estado num compound ANCESTRAL (ex.: `.dropdown:hover .content` ou
            // `.dropdown:focus-within .content`): a regra só vale quando o ANCESTRAL
            // está no estado — nunca no render estático. Sem isto o estado só era
            // checado no compound-alvo (last), então a regra de revelar vazava e o
            // menu dropdown aparecia SEMPRE (gutenberg: menu "About" despejado sobre
            // a página). No pass estático (state=None) rejeita qualquer estado.
            if accept && state == .None {
                for p in sel.parts do if p.state != .None { accept = false; break }
            }
            if !accept do continue
            if selector_matches_node(sel, n) {
                if !matched || csspkg.specificity_compare(sel.specificity, best) > 0 do best = sel.specificity
                matched = true
                if !sel.loose do exact = true
            }
        }
        when CASCADEPROBE {
            if casc_alvo && matched {
                for prop, val in rule.decls {
                    if CASCADE_PROP != "" && !strings.contains(prop, CASCADE_PROP) do continue
                    v, imp := csspkg.split_important(val)
                    p := Cascade_Priority{important = imp, layer = rule.layer_rank, specificity = best}
                    fmt.eprintfln("[casc]   CASOU  sel=%s  prop=%-16s val=%-20s spec=%v layer=%d imp=%v prio=%v ordem=%d",
                        casc_sel_txt(rule^), prop, v, best, rule.layer_rank, imp, p, rule.order)
                }
            }
            // regra que NÃO casou mas declara a prop: é o outro lado da pergunta
            // ("por que a regra certa não entrou?"), e sem isto a sonda só mostra
            // metade do funil.
            if casc_alvo && !matched {
                for prop, val in rule.decls {
                    if CASCADE_PROP != "" && !strings.contains(prop, CASCADE_PROP) do continue
                    fmt.eprintfln("[casc]   nao-casou  sel=%s  prop=%-16s val=%s", casc_sel_txt(rule^), prop, val)
                }
            }
        }
        if !matched do continue
        for prop, val in rule.decls {
            // display:none só de seletor exato — evita esconder conteúdo por engano
            if prop == "display" && !exact do continue
            v, imp := csspkg.split_important(val)
            prio := Cascade_Priority{important = imp, layer = rule.layer_rank, specificity = best}
            retain(&originals, prop, Win{prio, rule.order, v})
        }
    }

    // style="" inline: vence layers dentro da mesma importância (só no próprio elemento)
    if style, ok := n.attrs["style"]; ok && want == .None && state == .None {
        inline := csspkg.parse_decls(style, context.temp_allocator)
        for prop, val in inline {
            v, imp := csspkg.split_important(val)
            prio := Cascade_Priority{important = imp, inline = true, layer = csspkg.LAYER_UNLAYERED}
            retain(&originals, prop, Win{prio, 1 << 30, v})
        }
    }

    // Rollback ANTES dos aliases/lógicas/shorthands: o resto da pipeline continua
    // usando Win/consider, mas só recebe vencedores sem o token revert-layer.
    // Esta cascata representa uma única origem (autor); @property é fallback.
    // Sem candidato restante, a ausência deixa herança/inicial ao apply_decls.
    // Não expande all nem shorthands aqui: a arquitetura ainda os aplica depois
    // da cascata; rollback entre shorthand e longhand não é completo.
    for prop, list in originals {
        removed := make([]bool, len(list), context.temp_allocator)
        for {
            best := -1
            for w, i in list {
                if removed[i] do continue
                if best < 0 {
                    best = i
                } else {
                    cmp := cascade_priority_compare(w.spec, list[best].spec)
                    if cmp > 0 || (cmp == 0 && w.order >= list[best].order) do best = i
                }
            }
            if best < 0 do break
            w := list[best]
            if !strings.equal_fold(strings.trim_space(w.val), "revert-layer") {
                wins[prop] = w
                break
            }
            // CSS Cascade 5 §7.3.5: remove a camada inteira, não apenas o
            // vencedor. Important também remove as declarações ENTRE os níveis
            // important/normal dessa camada, mas pode cair em outra important.
            // Inline é categoria própria: important inline NÃO apaga important
            // de folhas de autor; só remove as declarações inline desta prop.
            for other, i in list {
                p := other.spec
                if p.layer == csspkg.LAYER_REGISTERED && w.spec.layer != csspkg.LAYER_REGISTERED do continue
                if w.spec.inline {
                    if p.inline do removed[i] = true
                } else if w.spec.important && !p.important {
                    if p.inline || csspkg.layer_compare(csspkg.Rule{layer_rank = p.layer}, csspkg.Rule{layer_rank = w.spec.layer}, false) >= 0 do removed[i] = true
                } else if p.inline == w.spec.inline && p.layer == w.spec.layer {
                    removed[i] = true
                }
            }
            removed[best] = true // garante progresso inclusive para fallbacks
        }
    }
    when CASCADEPROBE {
        if casc_alvo {
            for prop, w in wins {
                if CASCADE_PROP != "" && !strings.contains(prop, CASCADE_PROP) do continue
                fmt.eprintfln("[casc]   >>> VENCEU %-16s = %-20s prio=%v ordem=%d", prop, w.val, w.spec, w.order)
            }
        }
    }

    // ── Aliases de FORNECEDOR e LEGADOS → props padrão ──
    // Reinjetados com a MESMA spec/ordem do original, então entre REGRAS a
    // cascata decide sozinha ("prefixado antes, padrão depois" → padrão vence).
    // Só aliasamos o que NÃO é conhecido por si (-webkit-mask-image e
    // -webkit-line-clamp têm tratamento PRÓPRIO em apply_decls; aliasá-los
    // p/ mask-image/line-clamp quebraria a semântica).
    {
        // O alias perde o EMPATE (mesma regra → mesma spec/ordem, e o `wins` não
        // guarda ordem por-declaração): `{-webkit-box-sizing:X; box-sizing:Y}`
        // resolve p/ Y, que é o que o autor quer (o prefixado é o fallback).
        // Entre REGRAS diferentes a ordem de fonte decide normalmente.
        alias :: proc(wins: ^map[string]Win, prop: string, spec: Cascade_Priority, order: int, val: string) {
            if w, ok := wins[prop]; ok {
                if cascade_priority_compare(spec, w.spec) < 0 do return
                if spec == w.spec && order <= w.order do return
            }
            wins[prop] = Win{spec, order, val}
        }

        // 1. Prefixo genérico: -webkit-/-moz-/-ms-/-o- + prop conhecida.
        //    (coletamos as chaves antes de mutar o mapa — iterar mutando é UB)
        prefixed := make([dynamic]string, 0, 8, context.temp_allocator)
        for prop in wins {
            if len(prop) > 1 && prop[0] == '-' && !strings.has_prefix(prop, "--") do append(&prefixed, prop)
        }
        for prop in prefixed {
            if css_prop_is_known(prop) do continue // já tem semântica própria
            base := ""
            for pfx in ([?]string{"-webkit-", "-moz-", "-ms-", "-o-"}) {
                if strings.has_prefix(prop, pfx) { base = prop[len(pfx):]; break }
            }
            if base == "" || !css_prop_is_known(base) do continue
            w := wins[prop]
            alias(&wins, base, w.spec, w.order, w.val)
            delete_key(&wins, prop)
        }

        // 2. Legados com VALORES diferentes (flexbox 2009/2012 e grid-gap).
        //    O mapa de valores traduz start/end/justify/distribute; valor não
        //    listado passa cru (center/baseline/stretch já batem).
        Legacy :: struct { old, new: string, vals: bool }
        legacies := [?]Legacy{
            {"-webkit-box-align",       "align-items",     true},
            {"-ms-flex-align",          "align-items",     true},
            {"-webkit-box-pack",        "justify-content", true},
            {"-ms-flex-pack",           "justify-content", true},
            {"-ms-flex-item-align",     "align-self",      true},
            {"-ms-flex-line-pack",      "align-content",   true},
            {"-ms-flex-positive",       "flex-grow",       false},
            {"-ms-flex-negative",       "flex-shrink",     false},
            {"-ms-flex-preferred-size", "flex-basis",      false},
            {"-ms-flex-order",          "order",           false},
            {"-webkit-box-ordinal-group","order",          false},
            {"-webkit-box-flex",        "flex-grow",       false},
            {"-moz-box-flex",           "flex-grow",       false},
            // início/fim LÓGICOS com prefixo: viram a prop lógica padrão, que o
            // bloco seguinte (lógicas → físicas) traduz. É por isso que este bloco
            // roda ANTES daquele.
            {"-webkit-padding-start", "padding-inline-start", false},
            {"-webkit-padding-end",   "padding-inline-end",   false},
            {"-moz-padding-start",    "padding-inline-start", false},
            {"-moz-padding-end",      "padding-inline-end",   false},
            {"-webkit-margin-before", "margin-block-start",   false},
            {"-webkit-margin-after",  "margin-block-end",     false},
            {"-moz-margin-before",    "margin-block-start",   false},
            {"-moz-margin-after",     "margin-block-end",     false},
            {"-webkit-padding-before","padding-block-start",  false},
            {"-webkit-padding-after", "padding-block-end",    false},
            {"-webkit-margin-start",  "margin-inline-start",  false},
            {"-webkit-margin-end",    "margin-inline-end",    false},
            {"-moz-margin-start",     "margin-inline-start",  false},
            {"-moz-margin-end",       "margin-inline-end",    false},
            // quebra de coluna legada (Multi-column L1)
            {"-webkit-column-break-inside", "break-inside", false},
            {"-moz-column-break-inside",    "break-inside", false},
            {"-webkit-column-break-before", "break-before", false},
            {"-webkit-column-break-after",  "break-after",  false},
            // grid-gap: nomes obsoletos do Grid L1, mesmos valores
            {"grid-gap",         "gap",        false},
            {"grid-column-gap",  "column-gap", false},
            {"grid-row-gap",     "row-gap",    false},
        }
        for m in legacies {
            w, ok := wins[m.old]
            if !ok do continue
            val := w.val
            if m.vals {
                switch strings.to_lower(strings.trim_space(val), context.temp_allocator) {
                case "start":      val = "flex-start"
                case "end":        val = "flex-end"
                case "justify":    val = "space-between"
                case "distribute": val = "space-around"
                }
            }
            alias(&wins, m.new, w.spec, w.order, val)
            delete_key(&wins, m.old)
        }

        // 2b. -webkit-box-direction: reverse — o eixo vem do -webkit-box-orient
        //     (que NÃO aliaso: ele tem semântica própria no -webkit-line-clamp).
        if w, ok := wins["-webkit-box-direction"]; ok {
            if strings.equal_fold(strings.trim_space(w.val), "reverse") {
                vert := false
                if o, ok2 := wins["-webkit-box-orient"]; ok2 {
                    lv := strings.to_lower(strings.trim_space(o.val), context.temp_allocator)
                    vert = lv == "vertical" || lv == "block-axis"
                }
                alias(&wins, "flex-direction", w.spec, w.order, vert ? "column-reverse" : "row-reverse")
            }
            delete_key(&wins, "-webkit-box-direction")
        }

        // 3. flex-flow: <flex-direction> || <flex-wrap> (ordem livre).
        if w, ok := wins["flex-flow"]; ok {
            for t in strings.fields(w.val, context.temp_allocator) {
                switch strings.to_lower(t, context.temp_allocator) {
                case "row", "row-reverse", "column", "column-reverse":
                    alias(&wins, "flex-direction", w.spec, w.order, t)
                case "nowrap", "wrap", "wrap-reverse":
                    alias(&wins, "flex-wrap", w.spec, w.order, t)
                }
            }
            delete_key(&wins, "flex-flow")
        }

        // 4. Longhands de linha de grid → o shorthand "<start> / <end>" que o
        //    motor já entende (parse_grid_line). Ausente = "auto".
        GridPair :: struct { start, end, short: string }
        for m in ([?]GridPair{{"grid-column-start","grid-column-end","grid-column"},
                              {"grid-row-start","grid-row-end","grid-row"}}) {
            ws, has_s := wins[m.start]
            we, has_e := wins[m.end]
            if !has_s && !has_e do continue
            sv := has_s ? ws.val : "auto"
            ev := has_e ? we.val : "auto"
            spec, order := ws.spec, ws.order
            if !has_s || (has_e && (cascade_priority_compare(we.spec, spec) > 0 || (we.spec == spec && we.order > order))) {
                spec, order = we.spec, we.order
            }
            alias(&wins, m.short, spec, order, strings.concatenate({sv, " / ", ev}, context.temp_allocator))
            delete_key(&wins, m.start)
            delete_key(&wins, m.end)
        }
    }

    // ── Propriedades lógicas → físicas (horizontal-tb, direção calculada) ──
    // O resto do motor só conhece top/right/bottom/left. Traduzimos as lógicas
    // (inline = eixo horizontal, block = vertical) reinjetando-as via consider()
    // com a mesma spec/ordem, para que compitam na cascata como as físicas.
    // start = left/top, end = right/bottom. Depois removemos a lógica do mapa.
    {
        mode := inherited_mode
        if w, ok := wins["writing-mode"]; ok {
            mode_vars := clone_vars(inherited_vars)
            defer delete(mode_vars)
            for prop,val in wins do if strings.has_prefix(prop,"--") do mode_vars[prop]=val.val
            v := strings.to_lower(strings.trim_space(resolve_var(w.val,mode_vars)),context.temp_allocator)
            if v=="vertical-rl" { mode=.Vertical_Rl } else if v=="vertical-lr" { mode=.Vertical_Lr } else if v=="horizontal-tb" || v=="initial" { mode=.Horizontal }
        }
        direction := inherited_dir
        if w, ok := wins["direction"]; ok {
            local_vars := clone_vars(inherited_vars)
            defer delete(local_vars)
            for prop, v in wins do if strings.has_prefix(prop, "--") do local_vars[prop] = v.val
            d := strings.to_lower(strings.trim_space(resolve_var(w.val, local_vars)), context.temp_allocator)
            if d == "rtl" { direction = .Rtl } else if d == "ltr" || d == "initial" { direction = .Ltr }
        }
        Single :: struct { logical, physical: string }
        singles := [?]Single{
            // tamanho lógico (horizontal-tb: inline=width, block=height)
            {"inline-size",     "width"},
            {"block-size",      "height"},
            {"min-inline-size", "min-width"},
            {"max-inline-size", "max-width"},
            {"min-block-size",  "min-height"},
            {"max-block-size",  "max-height"},
            {"margin-inline-start",  "margin-left"},
            {"margin-inline-end",    "margin-right"},
            {"margin-block-start",   "margin-top"},
            {"margin-block-end",     "margin-bottom"},
            {"padding-inline-start", "padding-left"},
            {"padding-inline-end",   "padding-right"},
            {"padding-block-start",  "padding-top"},
            {"padding-block-end",    "padding-bottom"},
            {"inset-inline-start",   "left"},
            {"inset-inline-end",     "right"},
            {"inset-block-start",    "top"},
            {"inset-block-end",      "bottom"},
            // bordas lógicas: longhands por lado (width/style/color)
            {"border-inline-start-width", "border-left-width"},
            {"border-inline-end-width",   "border-right-width"},
            {"border-block-start-width",  "border-top-width"},
            {"border-block-end-width",    "border-bottom-width"},
            {"border-inline-start-style", "border-left-style"},
            {"border-inline-end-style",   "border-right-style"},
            {"border-block-start-style",  "border-top-style"},
            {"border-block-end-style",    "border-bottom-style"},
            {"border-inline-start-color", "border-left-color"},
            {"border-inline-end-color",   "border-right-color"},
            {"border-block-start-color",  "border-top-color"},
            {"border-block-end-color",    "border-bottom-color"},
            // bordas lógicas: shorthand por lado (border-inline-start: 1px solid red)
            {"border-inline-start", "border-left"},
            {"border-inline-end",   "border-right"},
            {"border-block-start",  "border-top"},
            {"border-block-end",    "border-bottom"},
            // raios lógicos de canto: <block><inline> (horizontal-tb ltr →
            // start=topo/esquerda, end=base/direita).
            {"border-start-start-radius", "border-top-left-radius"},
            {"border-start-end-radius",   "border-top-right-radius"},
            {"border-end-start-radius",   "border-bottom-left-radius"},
            {"border-end-end-radius",     "border-bottom-right-radius"},
            // overflow lógico (horizontal-tb: block=vertical, inline=horizontal)
            {"overflow-block",  "overflow-y"},
            {"overflow-inline", "overflow-x"},
        }
        for m in singles {
            if w, ok := wins[m.logical]; ok {
                consider(&wins, logical_physical(m.physical,m.logical,mode,direction), w.spec, w.order, w.val)
                delete_key(&wins, m.logical)
            }
        }
        // Atalhos de eixo: 1-2 valores (<start> <end>?) → os dois lados físicos.
        Axis :: struct { logical, side_start, side_end: string }
        axes := [?]Axis{
            {"margin-inline",  "margin-left",  "margin-right"},
            {"margin-block",   "margin-top",   "margin-bottom"},
            {"padding-inline", "padding-left", "padding-right"},
            {"padding-block",  "padding-top",  "padding-bottom"},
            {"inset-inline",   "left",         "right"},
            {"inset-block",    "top",          "bottom"},
            // bordas lógicas de eixo: 1-2 valores → os dois lados
            {"border-inline-width", "border-left-width",  "border-right-width"},
            {"border-block-width",  "border-top-width",   "border-bottom-width"},
            {"border-inline-style", "border-left-style",  "border-right-style"},
            {"border-block-style",  "border-top-style",   "border-bottom-style"},
            {"border-inline-color", "border-left-color",  "border-right-color"},
            {"border-block-color",  "border-top-color",   "border-bottom-color"},
        }
        for m in axes {
            if w, ok := wins[m.logical]; ok {
                // split_top_level (não strings.fields): UM valor pode ter espaços
                // INTERNOS — `padding-inline: calc(var(--spacing) * 4)` é o que o
                // Tailwind v4 emite p/ `px-4`. Picado por espaço, cada lado recebia
                // um pedaço inválido ("calc(var(--spacing)" / "*") e o padding do
                // botão sumia. Mesmo remédio já aplicado a `gap`.
                toks := split_top_level(w.val)
                start_v, end_v := w.val, w.val
                if len(toks) >= 2 { start_v = toks[0]; end_v = toks[1] }
                else if len(toks) == 1 { start_v = toks[0]; end_v = toks[0] }
                consider(&wins, logical_physical(m.side_start,m.logical,mode,direction), w.spec, w.order, start_v)
                consider(&wins, logical_physical(m.side_end,m.logical,mode,direction), w.spec, w.order, end_v)
                delete_key(&wins, m.logical)
            }
        }
        // Shorthands de borda lógica (border-inline/border-block): o valor
        // INTEIRO ("1px solid red") vai aos dois lados — não se divide por espaço.
        Both :: struct { logical, side_a, side_b: string }
        boths := [?]Both{
            {"border-inline", "border-left", "border-right"},
            {"border-block",  "border-top",  "border-bottom"},
        }
        for m in boths {
            if w, ok := wins[m.logical]; ok {
                consider(&wins, logical_physical(m.side_a,m.logical,mode,direction), w.spec, w.order, w.val)
                consider(&wins, logical_physical(m.side_b,m.logical,mode,direction), w.spec, w.order, w.val)
                delete_key(&wins, m.logical)
            }
        }
    }

    // ── M243: família BORDER resolvida no nível do ÁTOMO (lado × sub-prop) ──
    //
    // O desempate pairwise (bloco seguinte) só sabe comparar ANCESTRAL com
    // DESCENDENTE. `border-top` e `border-width` são IRMÃOS — nenhum contém o
    // outro, mas os dois escrevem `border-top-width` —, e aí quem decidia era a
    // ordem fixa do apply_decls, que roda border-<lado> ANTES de border-<sub>.
    // Num dos dois sentidos o resultado saía errado (era a degradação declarada
    // do M241, no teste m241_irmaos_sobrepostos_seguem_abertos).
    //
    // 💡 A saída não é apagar shorthand nenhum: os 12 longhands por lado são
    // aplicados por ÚLTIMO (passo 4 do apply_border_props), então basta EMITIR o
    // átomo vencedor e ele passa por cima de todos os passos anteriores. Nada é
    // deletado, o shorthand segue rodando — e com isso `has_border`, a regra da
    // LARGURA OMITIDA (`medium`) e o `style_none` continuam exatamente como
    // estavam. Não-regressão por construção.
    //
    // Só roda com DUAS OU MAIS declarações da família: com uma não há conflito e
    // o caminho antigo fica intocado.
    borda_por_atomo := false
    {
        LADOS :: [4]string{"top", "right", "bottom", "left"}
        SUBS  :: [3]string{"width", "style", "color"}

        // `border: var(--x)` não se fatia por texto (o `vars` só existe no
        // apply_decls). Nesse caso desistimos da resolução por átomo e o pairwise
        // segue valendo — degradação DECLARADA, não silenciosa.
        tem_var := false
        n_fam   := 0
        nao_atomicas := make([dynamic]string, 0, 8, context.temp_allocator)
        {
            cand := make([dynamic]string, 0, 8, context.temp_allocator)
            append(&cand, "border")
            for l in LADOS do append(&cand, strings.concatenate({"border-", l}, context.temp_allocator))
            for s in SUBS  do append(&cand, strings.concatenate({"border-", s}, context.temp_allocator))
            for k in cand {
                if w, ok := wins[k]; ok {
                    n_fam += 1
                    append(&nao_atomicas, k)
                    if strings.contains(w.val, "var(") do tem_var = true
                }
            }
            for l in LADOS do for s in SUBS {
                if _, ok := wins[strings.concatenate({"border-", l, "-", s}, context.temp_allocator)]; ok do n_fam += 1
            }
        }

        if n_fam >= 2 && !tem_var {
            borda_por_atomo = true
            // Componente <sub> de um valor de LADO ("1px solid red"). Espelha a
            // classificação do parse_border_side: estilo por palavra-chave,
            // largura por thin/medium/thick ou <length>, resto é cor.
            // ⚠️ devolve ok=false para componente OMITIDO — e aí NÃO emitimos
            // átomo. É de propósito: o shorthand da CSS reseta o omitido ao
            // inicial, o que este motor nunca fez, e inventar isso aqui seria
            // mudança de comportamento escondida dentro de um conserto de
            // desempate. Fica igual ao de hoje, e anotado.
            componente :: proc(val, sub: string) -> (string, bool) {
                for tok in split_top_level(strings.to_lower(val, context.temp_allocator)) {
                    if st, _ := is_border_style_kw(tok); st {
                        if sub == "style" do return tok, true
                        continue
                    }
                    if _, k := border_width_token(tok, 16, 1280, 720); k {
                        if sub == "width" do return tok, true
                        continue
                    }
                    if sub == "color" do return tok, true
                }
                return "", false
            }
            // i-ésimo lado de um valor 1-4 ("1px 2px" → t=1px r=2px b=1px l=2px)
            item4 :: proc(val: string, i: int) -> (string, bool) {
                toks := split_top_level(val)
                if len(toks) == 0 do return "", false
                tabela := [4][4]int{{0,0,0,0}, {0,1,0,1}, {0,1,2,1}, {0,1,2,3}}
                idx := tabela[min(max(len(toks), 1), 4) - 1]
                return toks[idx[i]], true
            }

            // Vencedor de cada átomo, calculado ANTES de mexer no mapa.
            Atomo :: struct { chave: string, winner: Win }
            atomos := make([dynamic]Atomo, 0, 12, context.temp_allocator)
            for l, li in LADOS {
            for s in SUBS {
                chave := strings.concatenate({"border-", l, "-", s}, context.temp_allocator)
                best  := Win{order = -1}
                // ⚠️⚠️ EMPATE: `>=` na ordem, não `>`. Declarações do MESMO bloco —
                // e todo o `style=""` inline é um bloco só — chegam com spec E
                // ordem IGUAIS, porque o `wins` não guarda ordem por-declaração.
                // Com `>` estrito vencia o PRIMEIRO consultado, e como consulto do
                // mais genérico ao mais específico isso fazia `border:10px solid`
                // ganhar de `border-top:none` escrito ao lado — o oposto do certo.
                // Com `>=`, o empate vai para o ÚLTIMO consultado, e a sequência de
                // consulta abaixo (border → border-<lado> → border-<sub> → átomo) é
                // exatamente a ordem em que o apply_border_props já os aplicava.
                // Pego pelo WPT auto-fill-auto-size-001-print, onde a caixa passou
                // de 0 para 20px de altura por causa da borda que devia ser `none`.
                melhor :: proc(best: ^Win, w: Win, val: string) {
                    if best.order < 0 || cascade_priority_compare(w.spec, best.spec) > 0 || (w.spec == best.spec && w.order >= best.order) {
                        best^ = Win{w.spec, w.order, val}
                    }
                }
                if w, ok := wins["border"]; ok {
                    if v, k := componente(w.val, s); k do melhor(&best, w, v)
                }
                if w, ok := wins[strings.concatenate({"border-", l}, context.temp_allocator)]; ok {
                    if v, k := componente(w.val, s); k do melhor(&best, w, v)
                }
                if w, ok := wins[strings.concatenate({"border-", s}, context.temp_allocator)]; ok {
                    if v, k := item4(w.val, li); k do melhor(&best, w, v)
                }
                if w, ok := wins[chave]; ok do melhor(&best, w, w.val)
                if best.order >= 0 do append(&atomos, Atomo{chave, best})
            }
            }
            // Preserva a prioridade real do vencedor; o pairwise pula a família
            // já resolvida, sem precisar de uma prioridade sentinela artificial.
            for a in atomos do wins[a.chave] = a.winner
        }
    }

    // SHORTHAND que vence o LONGHAND: o `decls` que devolvemos é PLANO (uma
    // entrada por propriedade) e não diz de qual regra cada uma veio, então
    // apply_decls só pode aplicá-las numa ordem fixa. Quando o shorthand ganha a
    // cascata, o longhand perdedor tem de sair daqui — senão ele sobrevive à
    // ordem fixa e vence quem deveria ter perdido. Era o at-supports-001 do WPT:
    // `div{background-color:red}` (spec 1) + `.test1{background:green}` (spec 10)
    // saía VERMELHO. O caminho inverso (longhand vence) continua resolvido pela
    // ordem em apply_decls, onde o longhand roda por último.
    //
    // M241 — a tabela abaixo era de TRÊS shorthands com listas parciais, e o que
    // não estava nela simplesmente NÃO COMPETIA: `padding` e `padding-left` são
    // chaves distintas do `wins`, cada uma "vencia" a sua, e quem decidia era a
    // ordem fixa de apply_decls. Foi assim que o "Skip to content" do github saiu
    // errado — `.show-on-focus:not(:focus){padding:0!important}` perdendo para um
    // utilitário `.px-2{padding-left:8px!important}` de especificidade MENOR.
    //
    // ⚠️ CADA par aqui exige que, em apply_decls, o SHORTHAND rode ANTES dos seus
    // longhands: é essa ordem que resolve o caminho inverso (longhand vence →
    // guardamos os dois, e o longhand sobrescreve o seu pedaço). A ordem foi
    // conferida uma a uma no fonte — e NÃO é uniforme: `flex` roda DEPOIS de
    // flex-grow/shrink/basis, `place-items` depois de align-items, `list-style`
    // depois de list-style-type. Esses TRÊS estão fora da tabela de propósito;
    // incluí-los sem antes mover o bloco de aplicação trocaria um erro por outro.
    //
    // ⚠️ Pares ANCESTRAL→DESCENDENTE só. `border-top` × `border-width` são IRMÃOS
    // que se sobrepõem no border-top-width, e a ordem fixa não sabe desempatá-los
    // nos dois sentidos — resolver isso exigiria expandir tudo em longhand, que é
    // outra rodada. Documentado no teste m241_irmaos_sobrepostos_seguem_abertos.
    {
        Sh :: struct { sh: string, longhands: []string }
        LADOS  :: [4]string{"top", "right", "bottom", "left"}
        pares := []Sh{
            {"margin",  {"margin-top", "margin-right", "margin-bottom", "margin-left"}},
            {"padding", {"padding-top", "padding-right", "padding-bottom", "padding-left"}},
            {"inset",   {"top", "right", "bottom", "left"}},
            {"gap",      {"row-gap", "column-gap"}},
            {"overflow", {"overflow-x", "overflow-y"}},
            {"outline",  {"outline-width", "outline-style", "outline-color"}},
            {"text-decoration", {"text-decoration-line", "text-decoration-style",
                                 "text-decoration-color", "text-decoration-thickness"}},
            {"border-radius", {"border-top-left-radius", "border-top-right-radius",
                               "border-bottom-right-radius", "border-bottom-left-radius"}},
            // `border` alcança TODA a subárvore (os shorthands por lado, os box4 e
            // os 12 longhands por lado); a comparação é transitiva, então listar os
            // descendentes diretos não bastaria.
            {"border", {"border-top", "border-right", "border-bottom", "border-left",
                        "border-width", "border-color", "border-style",
                        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
                        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
                        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color"}},
            {"border-width", {"border-top-width", "border-right-width", "border-bottom-width", "border-left-width"}},
            {"border-style", {"border-top-style", "border-right-style", "border-bottom-style", "border-left-style"}},
            {"border-color", {"border-top-color", "border-right-color", "border-bottom-color", "border-left-color"}},
            // já existiam
            {"background", {"background-color", "background-image"}},
            {"font",       {"font-style", "font-weight"}},
        }
        // border-top/right/bottom/left → os 3 longhands daquele lado
        por_lado := make([dynamic]Sh, 0, 4, context.temp_allocator)
        for l in LADOS {
            base := strings.concatenate({"border-", l}, context.temp_allocator)
            lhs  := make([]string, 3, context.temp_allocator)
            lhs[0] = strings.concatenate({base, "-width"}, context.temp_allocator)
            lhs[1] = strings.concatenate({base, "-style"}, context.temp_allocator)
            lhs[2] = strings.concatenate({base, "-color"}, context.temp_allocator)
            append(&por_lado, Sh{base, lhs})
        }

        resolve :: proc(wins: ^map[string]Win, p: Sh, probe: bool) {
            w, ok := wins[p.sh]
            if !ok do return
            for lh in p.longhands {
                l, ok2 := wins[lh]
                if !ok2 do continue
                // vence quem tem prioridade maior; empate desempata por ordem de fonte
                if cascade_priority_compare(w.spec, l.spec) > 0 || (w.spec == l.spec && w.order > l.order) {
                    when CASCADEPROBE {
                        if probe {
                            fmt.eprintfln("[casc]   xxx APAGOU %-22s = %-20s (prio=%v ordem=%d) — perdeu p/ %s = %s (prio=%v ordem=%d)",
                                lh, l.val, l.spec, l.order, p.sh, w.val, w.spec, w.order)
                        }
                    }
                    delete_key(wins, lh)
                }
            }
        }
        // ⚠️ Quando o M243 resolveu a borda por ÁTOMO, a família inteira já está
        // decidida e o pairwise não pode reabri-la (ele apagaria justamente o
        // átomo vencedor de um IRMÃO). O `border-radius` não entra nessa família:
        // é árvore de dois níveis, sem irmãos, e segue no pairwise.
        eh_borda :: proc(sh: string) -> bool {
            return sh == "border" || strings.has_prefix(sh, "border-") && sh != "border-radius"
        }
        for p in pares {
            if borda_por_atomo && eh_borda(p.sh) do continue
            resolve(&wins, p, casc_alvo)
        }
        if !borda_por_atomo {
            for p in por_lado do resolve(&wins, p, casc_alvo)
        }
    }

    out := make(map[string]string, context.temp_allocator)
    for prop, w in wins do out[prop] = w.val
    return out
}

// Cor CSS com suporte a currentColor (resolve para a cor computada do elemento;
// `color:` é aplicado antes das demais props, então cur já está atualizado).
@(private="file")
parse_color_cc :: proc(v: string, cur: u32) -> (u32, bool) {
    if strings.equal_fold(strings.trim_space(v), "currentcolor") do return cur, true
    return csspkg.parse_color(v)
}

// Resolve attr() (CSS Values 5) num valor CSS contra os atributos do elemento.
// Sintaxe: attr(<nome> type(<length>|<color>) , <fallback>?). Substitui cada
// attr(...) pelo valor do atributo convertido/validado ao tipo, ou pelo
// fallback. Sem fallback e com atributo ausente/cast inválido → ("", false):
// a declaração é "inválida em tempo de valor computado" e o chamador a descarta.
@(private="file")
resolve_attr :: proc(val: string, n: ^dompkg.Node, fs, vw, vh: f32) -> (string, bool) {
    out := val
    for _ in 0 ..< 8 { // várias attr() na mesma declaração; guarda anti-loop
        start := strings.index(out, "attr(")
        if start < 0 do break
        depth, close := 0, -1
        for i := start + 4; i < len(out); i += 1 { // casa o ) do '(' de attr(
            if      out[i] == '(' do depth += 1
            else if out[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
        }
        if close < 0 do return "", false // malformado
        rep, ok := attr_one(out[start + 5 : close], n, fs, vw, vh)
        if !ok do return "", false
        out = strings.concatenate({out[:start], rep, out[close + 1:]}, context.temp_allocator)
    }
    return out, true
}

// Resolve UMA notação attr() (o conteúdo entre os parênteses).
@(private="file")
attr_one :: proc(inner: string, n: ^dompkg.Node, fs, vw, vh: f32) -> (string, bool) {
    // separa "<nome> type(<t>)" do ", <fallback>" (vírgula de nível superior)
    head, fallback := inner, ""
    depth := 0
    for i in 0 ..< len(inner) {
        switch inner[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',': if depth == 0 { head = inner[:i]; fallback = strings.trim_space(inner[i + 1:]); break }
        }
        if head != inner do break
    }
    fields := strings.fields(strings.trim_space(head), context.temp_allocator)
    if len(fields) == 0 do return "", false
    name := fields[0]
    typ := ""
    if      strings.contains(head, "<length>") do typ = "length"
    else if strings.contains(head, "<color>")  do typ = "color"

    if av, has := n.attrs[name]; has {
        avt := strings.trim_space(av)
        switch typ {
        case "length": if _, _, k := parse_len(avt, fs, vw, vh); k do return avt, true
        case "color":  if _, k := csspkg.parse_color(avt); k do return avt, true
        case:          return avt, true // sem tipo declarado: usa a string crua
        }
    }
    // atributo ausente ou cast inválido → fallback (se houver)
    if fallback != "" do return fallback, true
    return "", false
}

// ── Juiz de valor utilizável (cadeia de fallback) ───────────────────────────
//
// Instalado no parser de CSS (csspkg.g_value_usable) e consultado SÓ quando a
// MESMA propriedade aparece duas vezes no MESMO bloco. Responde à pergunta que
// interessa p/ um fallback: "aplicar isto muda alguma coisa neste motor?".
// Não é validação de sintaxe — é medição do EFEITO, e por isso não envelhece:
// quando `fit-content` (ou qualquer outro gap) passar a ser implementado, este
// juiz passa a aceitá-lo sozinho, sem tabela p/ manter.
//
// ⚠️ LIMITAÇÃO conhecida: um valor que é VÁLIDO e cujo efeito é exatamente o
// INICIAL (`width: 100px; width: auto`) seria lido como "não faz nada" e o
// primeiro sobreviveria. Daí a lista de palavras-chave abaixo, que são sempre
// aceitas. Fora dela o risco é de uma grafia esotérica cujo efeito coincide com
// o inicial — e o preço é manter a declaração ANTERIOR do autor, não inventar.
// ⚠️ Vale só DENTRO do bloco; entre REGRAS diferentes a cascata segue como era.
@(private = "file")
usable_always := []string{
    "auto", "none", "normal", "transparent", "currentcolor",
    "initial", "inherit", "unset", "revert", "revert-layer", "0",
}

value_usable :: proc(prop, old_val, val: string) -> bool {
    if valid, checked := css_value_valid(prop, val); checked do return valid
    v := strings.to_lower(strings.trim_space(val), context.temp_allocator)
    if v == "" do return false
    // var()/env()/attr(): só dá p/ julgar depois de resolver — o attr() inclusive
    // resolve mais tarde, em compute_node, contra o ATRIBUTO do nó, que aqui não
    // existe. Nunca descartamos.
    if strings.contains(v, "var(") || strings.contains(v, "env(") || strings.contains(v, "attr(") {
        return true
    }
    for k in usable_always do if v == k do return true
    // Propriedade que nem reconhecemos não tem parser aqui: "não muda nada"
    // seria sempre verdade e descartaríamos o valor à toa.
    if !css_prop_is_known(prop) do return true

    // Mede o EFEITO **sobre o valor anterior**, não sobre o inicial: o que
    // interessa é se a 2ª declaração MUDA o resultado da 1ª. Medir contra o
    // inicial descartava valor que RESETA (`appearance:none; appearance:button`
    // — 5 reftests de css-ui), porque o efeito de `button` É o inicial.
    // Tudo em memória temporária: o probe não pode deixar rastro no motor.
    ctx := context
    ctx.allocator = context.temp_allocator
    context = ctx

    saved_lh := g_cur_lh_px
    d := make(map[string]string, 1, context.temp_allocator)
    base := computed_initial()
    d[prop] = old_val
    apply_decls(&base, d, nil)   // A = o que a declaração ANTERIOR produziu
    probe := base
    d[prop] = val
    apply_decls(&probe, d, nil)  // B = A com a nova declaração por cima
    g_cur_lh_px = saved_lh
    // Comparação por BYTES: `probe` é cópia de `base`, então o enchimento é
    // idêntico e qualquer campo tocado aparece — sem precisar enumerar campos
    // (que é justamente o que envelheceria).
    return mem.compare_byte_ptrs(cast(^byte)&base, cast(^byte)&probe, size_of(Computed)) != 0
}

@(init)
install_value_usable :: proc "contextless" () {
    csspkg.g_value_usable = value_usable
}

@(private="file")
// Valores INICIAIS de todas as propriedades (o "zero" da spec). Os campos que
// não aparecem aqui têm inicial = zero do tipo.
computed_initial :: proc() -> Computed {
    return Computed{text_align = .Start, color = DEFAULT_TEXT, font_size = 16 * g_zoom, line_height = 1.3, opacity = 1.0,
                    obj_pos_x = 0.5, obj_pos_y = 0.5, transform_sx = 1, transform_sy = 1,
                    transform_ox = 0.5, transform_oy = 0.5, xf_a = 1, xf_d = 1, deco_color = DECO_UNSET,
                    // Estes seis DIVERGIAM do bloco de reset das não-herdadas de
                    // compute_node, que é quem manda em produção: aqui ficavam no
                    // zero-value do tipo, e o zero-value NÃO é o valor inicial da
                    // spec. Duas consequências reais: `all: initial` (que faz
                    // `comp^ = computed_initial()`) produzia um estilo que a
                    // engine nunca produziria sozinha, e todo teste escrito com
                    // `test_apply` media contra uma base errada — foi o falso
                    // positivo de `flex: 1` (shrink 0 aqui, 1 no pipeline).
                    flex_shrink = 1,          // css-flexbox §7.2: inicial 1
                    col_gap     = -1,         // sentinela "normal" (1em)
                    ac_stretch  = true,       // align-content: normal → stretch
                    bg_origin   = .Padding,   // background-origin: padding-box
                    bg_repeat   = true,       // background-repeat: repeat
                    grid_col_span = 1, grid_row_span = 1}
}

apply_decls :: proc(comp: ^Computed, raw_decls: map[string]string, vars: map[string]string, vw: f32 = 1280, vh: f32 = 720, node: ^dompkg.Node = nil) {
    decls := raw_decls
    // Validate substitution results atomically, including shorthands. Invalid
    // var() results do not resurrect an earlier cascade candidate.
    filtered: map[string]string
    for prop, val in decls {
        if !strings.contains(val, "var(") do continue
        if !css_declaration_valid(prop, resolve_var(val, vars)) {
            if filtered == nil {
                filtered = make(map[string]string, len(decls), context.temp_allocator)
                for k, v in decls do filtered[k] = v
            }
            delete_key(&filtered, prop)
        }
    }
    if filtered != nil do decls = filtered
    // Base da unidade `lh` p/ este elemento. Começa pelos valores HERDADOS (comp já
    // chega como cópia do pai) e é reescrita quando font-size e line-height próprios
    // forem aplicados, ambos ANTES do bloco de métricas de caixa (margin/padding/
    // width/height/min-*), que é quem usa `lh` na prática.
    g_cur_lh_px = comp.font_size * (comp.line_height > 0 ? comp.line_height : 1.3)
    // `all`: atalho que atinge TODAS as propriedades (menos direction/unicode-bidi
    // e as custom). Aplicado ANTES das demais declarações — é o uso real
    // (`.x { all: unset; color: red }`); a precedência exata por ordem-de-fonte
    // exigiria ordem POR DECLARAÇÃO, que o `wins` da cascata não guarda.
    //   • initial → tudo ao valor inicial (inclusive o que se herda)
    //   • unset   → herdadas herdam, o resto vai ao inicial. `comp` JÁ chega assim
    //               (cópia do pai + reset das não-herdadas) → no-op correto.
    //   • revert  → descarta o autor e mantém o UA. Os defaults de UA já foram
    //               aplicados em comp antes daqui → mesmo no-op.
    if v, ok := decls["all"]; ok {
        if strings.equal_fold(strings.trim_space(v), "initial") {
            // ponteiros de pseudo são ALOCADOS e liberados por free_styles —
            // preservá-los, senão `all:initial` vaza memória.
            bf, af, fl := comp.before, comp.after, comp.first_letter
            comp^ = computed_initial()
            comp.before, comp.after, comp.first_letter = bf, af, fl
        }
    }
    // `color: transparent` — o texto SOME. `named_color` rejeita `transparent` de
    // propósito (para `background: transparent` significar ausência de cor), então
    // o valor era ignorado e o texto saía na cor HERDADA, bem visível: o oposto do
    // pedido. Vale p/ o padrão de esconder texto sob imagem/ícone e p/ skeletons.
    // Guardo a cor de ANTES porque o bloco de `background-clip:text` (adiante)
    // precisa dela para não apagar texto que não sabemos clipar.
    color_transparent := false
    color_antes := comp.color
    if v, ok := decls["color"]; ok {
        rv := resolve_var(v, vars)
        rvt := strings.trim_space(rv)
        if strings.equal_fold(rvt, "transparent") {
            comp.color = COLOR_TRANSPARENT; comp.has_color = true; color_transparent = true
        } else if strings.equal_fold(rvt, "inherit") || strings.equal_fold(rvt, "unset") ||
                  strings.equal_fold(rvt, "currentcolor") {
            // `color` HERDA, então o VALOR já está em comp (cópia do pai) e não há
            // nada a computar. O que faltava era registrar que o AUTOR definiu cor
            // aqui: sem essa marca o <a> caía no azul do nosso UA-stylesheet
            // (layout.odin: `if !lc.has_color do s2.color = COL_LINK`).
            // `a{color:inherit}` é o reset de link do preflight do Tailwind — e do
            // normalize/Bootstrap —, então sem isto TODO link de site moderno sai
            // azul, com a cor que o site escolheu para o rodapé/menu ignorada.
            // `unset` num property que herda é idêntico a `inherit`; `revert` NÃO
            // entra (volta ao estilo de UA, que é justamente o azul).
            comp.has_color = true
        } else if rgb, k := csspkg.parse_color(rv); k {
            comp.color = rgb; comp.has_color = true
        }
    }
    // ⚠️ DEPOIS do `color`: `caret-color: currentColor` resolve contra o `color`
    // da MESMA regra, não contra o herdado. Antes deste ponto `comp.color` ainda
    // é a cópia do pai — e o caret sairia com a cor errada justamente no caso em
    // que as duas props são declaradas juntas.
    if v, ok := decls["caret-color"]; ok {
        t := strings.trim_space(resolve_var(v, vars))
        if strings.equal_fold(t, "auto") {
            comp.has_caret = false // `auto` = currentColor: é o padrão do ImGui
        } else if c, k := parse_color_cc(t, comp.color); k {
            comp.caret_color = c; comp.has_caret = true
        }
    }
    if v, ok := decls["background-image"]; ok {
        apply_bg_layers(comp, resolve_var(v, vars), false)
    }
    if v, ok := decls["background"]; ok {
        rv := resolve_var(v, vars)
        // o shorthand carrega background-attachment junto (`background: url(x) fixed`)
        {
            lo := strings.to_lower(rv, context.temp_allocator)
            if strings.contains(lo, " fixed") || strings.has_prefix(lo, "fixed") do comp.bg_fixed = true
        }
        found_color := apply_bg_layers(comp, rv, true)
        // O shorthand RESETA os longhands que cobre (spec): um `background` sem cor
        // devolve `background-color` a transparent. `background: 0 0` — a grafia que
        // o GitHub usa para "sem fundo" — é só uma POSIÇÃO, e sem o reset o fundo
        // claro que o UA dá ao `<button>` sobrevivia: a nav ficava com uma faixa
        // clara atrás dos itens. Vale igual p/ `background: none` e
        // `background: url(x)`.
        // ⚠️ Só quando NÃO há `background-color` explícito no mesmo conjunto: o nosso
        // `decls` é PLANO e não guarda a ordem relativa entre shorthand e longhand,
        // então na dúvida o longhand vence (é o caso comum — `background: url(x)`
        // numa regra e `background-color` em outra, mais específica).
        if !found_color {
            if _, tem_longhand := decls["background-color"]; !tem_longhand {
                comp.bg = 0
                comp.has_bg = false
            }
        }
    }
    // `background-color` roda DEPOIS do shorthand (era antes) — é a mesma
    // convenção "na dúvida o longhand vence" que o bloco acima já declara. Com a
    // ordem antiga, `.a{background:#f00}` + `.i{background-color:transparent}`
    // acabava vermelho: o longhand limpava e o shorthand repintava.
    if v, ok := decls["background-color"]; ok {
        rv := resolve_var(v, vars)
        // `transparent` é AUSÊNCIA de fundo, e tem de APAGAR o que já estava lá —
        // o fundo do UA (<button>/<input>) ou um `background:` de outra regra.
        // `named_color` rejeita `transparent` de propósito, então isto virava
        // no-op e o cinza do UA sobrevivia: `<button
        // style="background-color:transparent">` saía com a pílula #e9e9ed atrás.
        // O caminho do SHORTHAND já fazia esse reset (`found_color` acima); só o
        // longhand não fazia.
        if strings.equal_fold(strings.trim_space(rv), "transparent") {
            comp.bg = 0
            comp.has_bg = false
        } else if rgb, k := parse_color_cc(rv, comp.color); k {
            comp.bg = rgb; comp.has_bg = true
        }
    }
    // background-size/-repeat/-position também são LISTAS: o i-ésimo valor vale
    // p/ a i-ésima camada (o 1º na camada 0, que mora nos campos diretos).
    if v, ok := decls["background-size"]; ok {
        for part, i in bg_split_layers(v) {
            sz: Bg_Size = .Auto
            switch strings.to_lower(strings.trim_space(part), context.temp_allocator) {
            case "cover":   sz = .Cover
            case "contain": sz = .Contain
            }
            if i == 0 do comp.bg_size = sz
            else if i - 1 < len(comp.bg_extra) do comp.bg_extra[i - 1].size = sz
        }
    }
    if v, ok := decls["background-repeat"]; ok {
        for part, i in bg_split_layers(v) {
            rp := !strings.contains(strings.to_lower(part, context.temp_allocator), "no-repeat")
            if i == 0 do comp.bg_repeat = rp
            else if i - 1 < len(comp.bg_extra) do comp.bg_extra[i - 1].repeat = rp
        }
    }
    if v, ok := decls["background-position"]; ok {
        for part, i in bg_split_layers(resolve_var(v, vars)) {
            px, py := parse_bg_position(part, vw, vh)
            if i == 0 { comp.bg_pos_x, comp.bg_pos_y = px, py }
            else if i - 1 < len(comp.bg_extra) {
                comp.bg_extra[i - 1].pos_x, comp.bg_extra[i - 1].pos_y = px, py
            }
        }
    }
    if v, ok := decls["background-position-x"]; ok {
        comp.bg_pos_x = parse_bg_position_axis(resolve_var(v, vars), false, vw, vh)
    }
    if v, ok := decls["background-position-y"]; ok {
        comp.bg_pos_y = parse_bg_position_axis(resolve_var(v, vars), true, vw, vh)
    }
    if v, ok := decls["object-fit"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "cover":   comp.obj_fit = .Cover
        case "contain": comp.obj_fit = .Contain
        case "none":    comp.obj_fit = .None
        case:           comp.obj_fit = .Fill
        }
    }
    if v, ok := decls["object-position"]; ok {
        comp.obj_pos_x, comp.obj_pos_y = parse_bg_position(resolve_var(v, vars), vw, vh)
    }
    if v, ok := decls["cursor"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "pointer":                          comp.cursor = .Pointer
        case "text", "vertical-text":            comp.cursor = .Text
        case "move", "grab", "grabbing", "all-scroll": comp.cursor = .Move
        case "not-allowed", "no-drop":           comp.cursor = .NotAllowed
        case "wait", "progress":                 comp.cursor = .Progress
        case "auto", "default", "inherit":       comp.cursor = .Auto
        case:                                    comp.cursor = .Auto
        }
    }
    // scroll-behavior (não herda): `smooth` anima scrolls programáticos (âncora).
    if v, ok := decls["scroll-behavior"]; ok {
        comp.scroll_smooth = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "smooth")
    }
    // scroll-margin-top / scroll-padding-top (não herdam): deslocam o ponto de
    // aterrissagem do scroll de âncora (compensa header fixo). Só o topo afeta o
    // scroll VERTICAL de página; as outras bordas são só reconhecidas (whitelist).
    // A shorthand usa o 1º token (topo). % é ignorado.
    if v, ok := decls["scroll-margin-top"]; ok {
        if px, _, k := parse_len(strings.trim_space(resolve_var(v, vars)), comp.font_size, vw, vh); k do comp.scroll_margin_top = px
    } else if v, ok := decls["scroll-margin"]; ok {
        toks := strings.fields(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if len(toks) >= 1 { if px, _, k := parse_len(toks[0], comp.font_size, vw, vh); k do comp.scroll_margin_top = px }
    }
    if v, ok := decls["scroll-padding-top"]; ok {
        if px, _, k := parse_len(strings.trim_space(resolve_var(v, vars)), comp.font_size, vw, vh); k do comp.scroll_padding_top = px
    } else if v, ok := decls["scroll-padding"]; ok {
        toks := strings.fields(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if len(toks) >= 1 { if px, _, k := parse_len(toks[0], comp.font_size, vw, vh); k do comp.scroll_padding_top = px }
    }
    // overscroll-behavior (não herda): contain/none impede o scroll de encadear
    // ao pai/página quando o container atinge o limite. Só o eixo Y importa (scroll
    // de página é vertical); qualquer eixo contain/none liga o flag.
    for prop in ([]string{"overscroll-behavior", "overscroll-behavior-y", "overscroll-behavior-block"}) {
        if v, ok := decls[prop]; ok {
            lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
            comp.overscroll_contain = strings.contains(lv, "contain") || strings.contains(lv, "none")
        }
    }
    // tab-size (HERDA): nº de espaços por tab em <pre>. Só a forma numérica (a de
    // comprimento é rejeitada). Campo interno: 0 = default 8, -1 = tab zero.
    if v, ok := decls["tab-size"]; ok {
        if n, k := strconv.parse_int(strings.trim_space(resolve_var(v, vars))); k && n >= 0 do comp.tab_size = n == 0 ? -1 : n
    } else if v, ok := decls["-moz-tab-size"]; ok {
        if n, k := strconv.parse_int(strings.trim_space(resolve_var(v, vars))); k && n >= 0 do comp.tab_size = n == 0 ? -1 : n
    }
    // appearance (não herda): `none` suprime a marca nativa do controle (checkbox/
    // radio custom). Aceita variantes prefixadas; a não-prefixada vence por vir por último.
    for prop in ([]string{"-webkit-appearance", "-moz-appearance", "appearance"}) {
        if v, ok := decls[prop]; ok {
            comp.appearance_none = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "none")
        }
    }
    // pointer-events (HERDA): `none` torna o elemento transparente a cliques/hover;
    // `auto` (ou qualquer outro) reativa. Como herda via comp=inherit, um filho
    // com `auto` sobrepõe um ancestral `none`.
    if v, ok := decls["pointer-events"]; ok {
        comp.pe_none = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "none")
    }
    // user-select (HERDA): guardado p/ uso futuro; inerte por ora (o motor não tem
    // seleção de texto de página p/ desabilitar). `none` = true; resto = false.
    // Aceita as variantes prefixadas (a não-prefixada, se presente, vence por vir por último).
    for prop in ([]string{"-webkit-user-select", "-moz-user-select", "-ms-user-select", "user-select"}) {
        if v, ok := decls[prop]; ok {
            comp.user_select_none = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "none")
        }
    }
    // accent-color (HERDA): cor de destaque de checkbox/radio marcado. `auto` = default.
    if v, ok := decls["accent-color"]; ok {
        lv := strings.trim_space(resolve_var(v, vars))
        if strings.equal_fold(lv, "auto") {
            comp.has_accent = false
        } else if col, k := parse_color_cc(lv, comp.color); k {
            comp.accent_color = col; comp.has_accent = true
        }
    }
    // transition: shorthand + os 4 longhands, espalhados por CANAL animável
    // (ver transition.odin). Antes só a 1ª duração era lida e ela governava
    // TODOS os canais; property/timing-function/delay eram jogados fora.
    {
        get :: proc(decls: map[string]string, vars: map[string]string, k: string) -> string {
            if v, ok := decls[k]; ok do return resolve_var(v, vars)
            return ""
        }
        sh := get(decls, vars, "transition")
        pp := get(decls, vars, "transition-property")
        pd := get(decls, vars, "transition-duration")
        pt := get(decls, vars, "transition-timing-function")
        px := get(decls, vars, "transition-delay")
        if sh != "" || pp != "" || pd != "" || pt != "" || px != "" {
            parse_transitions(&comp.trans, sh, pp, pd, pt, px)
        }
    }
    if v, ok := decls["vertical-align"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "top", "text-top":       comp.valign = .Top
        case "middle":                comp.valign = .Middle
        case "bottom", "text-bottom": comp.valign = .Bottom
        case "sub":                   comp.valign = .Sub
        case "super":                 comp.valign = .Super
        case:                         comp.valign = .Baseline // baseline/length/%
        }
    }
    // scroll/auto rolam (e clipam); hidden/clip só clipam. `visible`/desconhecido
    // NÃO clipa. Uma palavra por EIXO — ver o bloco que chama, adiante.
    ovf_kind :: proc(lo: string) -> Ovf_Kind {
        switch lo {
        case "hidden":          return .Hidden
        case "clip":            return .Clip
        case "scroll":          return .Scroll
        case "auto", "overlay": return .Auto // `overlay` é alias legado de `auto`
        }
        return .Visible
    }
    if v, ok := decls["resize"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        // `auto` é "a UA decide" (css-ui-4) e toda UA decide POR redimensionar
        // onde a prop se aplica — logo, equivale a `both` aqui.
        case "both", "auto":         comp.resize = .Both
        case "horizontal", "inline": comp.resize = .Horizontal
        case "vertical", "block":    comp.resize = .Vertical
        case:                        comp.resize = .None // none/inherit/lixo
        }
    }
    if v,ok:=decls["unicode-bidi"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v,vars)),context.temp_allocator) {
        case "normal": comp.unicode_bidi=.Normal
        case "embed": comp.unicode_bidi=.Embed
        case "isolate": comp.unicode_bidi=.Isolate
        case "bidi-override": comp.unicode_bidi=.Override
        case "isolate-override": comp.unicode_bidi=.Isolate_Override
        case "plaintext": comp.unicode_bidi=.Plaintext
        }
    }
    if v,ok:=decls["writing-mode"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v,vars)),context.temp_allocator) {
        case "horizontal-tb": comp.writing_mode=.Horizontal
        case "vertical-rl": comp.writing_mode=.Vertical_Rl
        case "vertical-lr": comp.writing_mode=.Vertical_Lr
        }
    }
    if v,ok:=decls["text-orientation"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v,vars)),context.temp_allocator) {
        case "mixed": comp.text_orientation=.Mixed
        case "upright": comp.text_orientation=.Upright
        case "sideways": comp.text_orientation=.Sideways
        }
    }
    if v, ok := decls["direction"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "rtl": comp.direction = .Rtl
        case "ltr": comp.direction = .Ltr
        }
    }
    if v, ok := decls["float"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "left":         comp.float = .Left
        case "right":        comp.float = .Right
        case "inline-start": comp.float = .InlineStart
        case "inline-end":   comp.float = .InlineEnd
        case:                comp.float = .None
        }
    }
    if v, ok := decls["clear"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "left":         comp.clear = .Left
        case "right":        comp.clear = .Right
        case "both":         comp.clear = .Both
        case "inline-start": comp.clear = .InlineStart
        case "inline-end":   comp.clear = .InlineEnd
        case:                comp.clear = .None
        }
    }
    // ── overflow: uma palavra por EIXO + a BLOCKIFICAÇÃO da spec ───────────────
    //
    // css-overflow-3 §3.1: os dois eixos não são independentes. Se um é `visible`
    // e o OUTRO é hidden/scroll/auto, o `visible` computa para **auto** — ou seja,
    // passa a clipar (e a rolar) também. `clip` é a exceção: ele NÃO arrasta o
    // outro eixo, e `clip` com `visible` do outro lado é combinação legal.
    //
    // Antes isto era um `strings.contains` sobre a string INTEIRA, com um `axis`
    // 0/1/2. Dois defeitos vinham daí:
    //   • `overflow-x: hidden` sozinho clipava só o X — o Chrome clipa os DOIS
    //     (medido com fixture + headless), porque o Y vira `auto`;
    //   • `overflow: clip visible` não clipava NADA: o `contains` não achava
    //     "hidden"/"scroll"/"auto" e o `lo == "clip"` falhava por causa do 2º token.
    //   (O caso `overflow: hidden visible` acertava por acidente: o `contains`
    //   pegava o "hidden" e clipava os dois, que é o que a blockificação manda.)
    {
        kx, ky := Ovf_Kind.Visible, Ovf_Kind.Visible
        tem := false
        if v, ok := decls["overflow"]; ok {
            toks := strings.fields(strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator), context.temp_allocator)
            if len(toks) >= 1 { kx = ovf_kind(toks[0]); ky = kx; tem = true }
            if len(toks) >= 2 { ky = ovf_kind(toks[1]) } // `overflow: <x> <y>`
        }
        if v, ok := decls["overflow-x"]; ok {
            kx = ovf_kind(strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)); tem = true
        }
        if v, ok := decls["overflow-y"]; ok {
            ky = ovf_kind(strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)); tem = true
        }
        if tem {
            // ⚠️ `html`/`body` FORA da blockificação: neles o overflow PROPAGA para
            // o viewport (css-overflow §3.3) e a caixa do próprio elemento segue
            // visível. Sem esta exceção, o `body{overflow-x:hidden}` que meio site
            // escreve p/ matar a rolagem horizontal passaria a clipar o eixo Y na
            // altura da caixa — cortando a página inteira. É o caso mais comum da
            // propriedade, e por isso a exceção vem ANTES do resto.
            raiz := node != nil && (node.tag == "html" || node.tag == "body")
            if !raiz {
                sc :: proc(k: Ovf_Kind) -> bool { return k == .Hidden || k == .Scroll || k == .Auto }
                if kx == .Visible && sc(ky) do kx = .Auto
                if ky == .Visible && sc(kx) do ky = .Auto
            }
            comp.ovf_clip_x = kx != .Visible
            comp.ovf_clip_y = ky != .Visible
            if kx == .Scroll || kx == .Auto || ky == .Scroll || ky == .Auto do comp.overflow_scroll = true
            comp.ovf_scroll_x = kx == .Scroll || kx == .Auto
            comp.ovf_scroll_y = ky == .Scroll || ky == .Auto
            // scroll container = hidden/scroll/auto (rolável programaticamente). `clip`
            // NÃO é — clipa mas não rola; p/ min-size:auto de flex item conta como visible.
            if kx == .Hidden || ky == .Hidden || comp.overflow_scroll do comp.scroll_container = true
            comp.overflow_hidden = comp.ovf_clip_x || comp.ovf_clip_y
        }
    }
    // background-clip:text + -webkit-text-fill-color (texto com gradiente/cor).
    // Sem clip real de glifos: aproximamos pintando o texto com uma cor sólida
    // representativa do fundo e suprimimos o fundo como caixa.
    {
        bg_clip_text := false
        if v, ok := decls["background-clip"]; ok {
            lv := strings.to_lower(v, context.temp_allocator)
            if strings.contains(lv, "text") do bg_clip_text = true
            else if strings.contains(lv, "content-box") do comp.bg_clip = .Content
            else if strings.contains(lv, "padding-box") do comp.bg_clip = .Padding
            else if strings.contains(lv, "border-box")  do comp.bg_clip = .Border
        }
        if v, ok := decls["-webkit-background-clip"]; ok {
            if strings.contains(strings.to_lower(v, context.temp_allocator), "text") do bg_clip_text = true
        }
        // background-origin: área de posicionamento da imagem de fundo (default padding-box).
        if v, ok := decls["background-attachment"]; ok {
        lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        comp.bg_fixed = strings.contains(lo, "fixed")
    }
    if v, ok := decls["background-origin"]; ok {
            lv := strings.to_lower(v, context.temp_allocator)
            if      strings.contains(lv, "content-box") do comp.bg_origin = .Content
            else if strings.contains(lv, "border-box")  do comp.bg_origin = .Border
            else if strings.contains(lv, "padding-box") do comp.bg_origin = .Padding
        }
        fill_set, fill_transparent := false, false
        fill_col: u32 = 0
        if v, ok := decls["-webkit-text-fill-color"]; ok {
            rv := resolve_var(v, vars)
            if strings.equal_fold(strings.trim_space(rv), "transparent") {
                fill_set = true; fill_transparent = true
            } else if c, k := parse_color_cc(rv, comp.color); k {
                fill_set = true; fill_col = c
            }
        }
        if bg_clip_text && (comp.grad.active || comp.has_bg) {
            if comp.grad.active {
                // O gradiente PERMANECE, mas marcado p/ colorir os glifos em vez da
                // caixa (o paint sombreia os vértices do texto). A cor sólida
                // representativa continua sendo escrita como FALLBACK: é o que
                // aparece em qualquer caminho de texto que não passe pelo
                // sombreamento (e o que se via antes deste marco, em tudo).
                comp.color = gradient_repr_color(comp.grad)
                comp.grad_clip_text = true
            } else {
                comp.color = comp.bg
                comp.has_bg = false
            }
            comp.has_color = true
        } else if fill_set && !fill_transparent {
            comp.color = fill_col // -webkit-text-fill-color define a cor do texto
            comp.has_color = true
        } else if color_transparent && bg_clip_text {
            // `color: transparent` + `background-clip: text` MAS sem fundo que
            // saibamos clipar (ex.: imagem raster): deixar transparente apagaria o
            // texto da página. Volta p/ a cor de antes — a MESMA escolha já feita
            // p/ `-webkit-text-fill-color: transparent` sem clip, logo abaixo.
            comp.color = color_antes
        }
        // fill transparent sem clip: mantém a cor normal p/ o texto não sumir
    }
    if v, ok := decls["z-index"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "auto" || lv == "initial" || lv == "unset" || lv == "revert" {
            comp.z_index = 0; comp.z_index_set = false
        } else if n, k := strconv.parse_int(lv); k {
            comp.z_index = n; comp.z_index_set = true
        }
    }
    if v, ok := decls["opacity"]; ok {
        lv := strings.trim_space(resolve_var(v, vars))
        if strings.has_suffix(lv, "%") {
            if f, k := strconv.parse_f64(lv[:len(lv)-1]); k do comp.opacity = clamp(f32(f)/100, 0, 1)
        } else {
            if f, k := strconv.parse_f64(lv); k do comp.opacity = clamp(f32(f), 0, 1)
        }
    }
    if v, ok := decls["isolation"]; ok {
        comp.isolate = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "isolate")
    }
    if v, ok := decls["backface-visibility"]; ok {
        comp.backface_hidden = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "hidden")
    }
    if v, ok := decls["transform-style"]; ok {
        comp.preserve_3d = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "preserve-3d")
    }
    if v, ok := decls["mix-blend-mode"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "multiply":  comp.blend_mode = .Multiply
        case "screen":    comp.blend_mode = .Screen
        case "darken":    comp.blend_mode = .Darken
        case "lighten":    comp.blend_mode = .Lighten
        case "exclusion":  comp.blend_mode = .Exclusion
        case "overlay":     comp.blend_mode = .Overlay
        case "hard-light":  comp.blend_mode = .HardLight
        case "soft-light":  comp.blend_mode = .SoftLight
        case "color-dodge": comp.blend_mode = .ColorDodge
        case "color-burn":  comp.blend_mode = .ColorBurn
        case "difference":  comp.blend_mode = .Difference
        case "hue":         comp.blend_mode = .Hue
        case "saturation":  comp.blend_mode = .Saturation
        case "color":       comp.blend_mode = .Color
        case "luminosity":  comp.blend_mode = .Luminosity
        case:               comp.blend_mode = .Normal // normal + não-suportados
        }
    }
    if v, ok := decls["filter"]; ok {
        parse_filter(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    if v, ok := decls["backdrop-filter"]; ok {
        parse_backdrop_filter(comp, resolve_var(v, vars), comp.font_size)
    } else if v, ok := decls["-webkit-backdrop-filter"]; ok {
        parse_backdrop_filter(comp, resolve_var(v, vars), comp.font_size)
    }
    // `clip` (legado) ANTES de clip-path: se ambos existirem, clip-path VENCE
    // (spec) — parse_clip_path sobrescreve o kind .Rect; e se só clip-path vier,
    // o guard aqui não roda. Aplica clip só quando clip-path ainda não recortou.
    if v, ok := decls["clip"]; ok && comp.clip_path.kind == .None {
        parse_clip_rect(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    if v, ok := decls["clip-path"]; ok {
        parse_clip_path(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    } else if v, ok := decls["-webkit-clip-path"]; ok {
        parse_clip_path(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    // mask-image: <gradient> — máscara alpha reusando a máquina de layer do
    // clip-path (multiplica o alpha em vez de zerar). mask-mode default
    // (match-source) p/ um <image>/gradiente = ALPHA do gradiente, então
    // linear-gradient(black,transparent) faz fade-out. url()/imagem raster → sem
    // máscara (parse_gradient falha → active=false). `mask` shorthand: tentamos
    // parsear o valor inteiro como gradiente (o restante — size/repeat/position —
    // é ignorado; cobrimos sempre o border-box). `none` limpa.
    if v, ok := decls["mask-image"]; ok {
        parse_mask_image(comp, resolve_var(v, vars))
    } else if v, ok := decls["-webkit-mask-image"]; ok {
        parse_mask_image(comp, resolve_var(v, vars))
    } else if v, ok := decls["mask"]; ok {
        parse_mask_image(comp, resolve_var(v, vars))
    } else if v, ok := decls["-webkit-mask"]; ok {
        parse_mask_image(comp, resolve_var(v, vars))
    }
    individual:=XList{}
    defer delete(individual.ops)
    // Individual properties precede the transform list in T * R * S order.
    // Keep scalar compatibility channels alongside the complete operations.
    if v, ok := decls["translate"]; ok {
        lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lo != "" && lo != "none" {
            // split_top_level, não strings.fields: o Tailwind v4 escreve cada eixo
            // como `calc(var(--spacing) * -1)` — com ESPAÇOS dentro dos parênteses.
            // Fatiado por espaço, o eixo Y virava "calc(0.25rem", não parseava, e o
            // deslocamento vertical sumia (a classe de defeito do M172/M173).
            toks := split_top_level(lo)
            if len(toks) >= 1 {
                if px, pct, k := parse_len(toks[0], comp.font_size, vw, vh); k {
                    comp.transform_tx = px; comp.transform_tx_pct = pct; comp.has_transform = true
                }
            }
            if len(toks) >= 2 {
                if py, pct, k := parse_len(toks[1], comp.font_size, vw, vh); k {
                    comp.transform_ty = py; comp.transform_ty_pct = pct; comp.has_transform = true
                }
            }
            op:=x_base(comp^); op.kind=.Translate
            if len(toks)>=3 { if z,pct,k:=parse_len(toks[2],comp.font_size,vw,vh); k && !pct { op.m[2,3]=z; individual.spatial=true } }
            append(&individual.ops,op)
        }
    }
    if v, ok := decls["rotate"]; ok {
        lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lo != "" && lo != "none" {
            // rotate: <angle> | [x|y|z|<x> <y> <z>] && <angle>.
            // split_top_level pelo mesmo motivo do `translate` acima (`calc()`).
            toks := split_top_level(lo)
            if len(toks) >= 1 {
                // Eixo: `x`/`y`/`z` ou um vetor de 3 números; o ângulo é o token
                // que sobra (a spec aceita o eixo antes OU depois do ângulo).
                // Grafia que não é nenhuma das três formas deixa o eixo nulo e
                // não gira nada (antes desta mudança também era ignorada).
                ax, ay, az: f32 = 0, 0, 0
                ang := toks[len(toks) - 1]
                switch len(toks) {
                case 1:
                    az = 1
                case 2:
                    eixo := toks[0]
                    if toks[1] == "x" || toks[1] == "y" || toks[1] == "z" { eixo = toks[1]; ang = toks[0] }
                    switch eixo {
                    case "x": ax = 1
                    case "y": ay = 1
                    case "z": az = 1
                    }
                case 4:
                    v0, k0 := strconv.parse_f64(toks[0]); v1, k1 := strconv.parse_f64(toks[1]); v2, k2 := strconv.parse_f64(toks[2])
                    if k0 && k1 && k2 { ax, ay, az = f32(v0), f32(v1), f32(v2) }
                    else {
                        ang = toks[0]
                        w1, j1 := strconv.parse_f64(toks[1]); w2, j2 := strconv.parse_f64(toks[2]); w3, j3 := strconv.parse_f64(toks[3])
                        if j1 && j2 && j3 { ax, ay, az = f32(w1), f32(w2), f32(w3) }
                    }
                }
                // Mesmo achatamento do parse_transform, pelos campos escalares
                // (é o que a transition anima): girar sobre x/y ENCOLHE o eixo
                // oposto por cos θ, e passa a mostrar o verso quando cos θ < 0.
                // Eixo oblíquo não tem forma escalar e fica de fora.
                a := parse_angle(ang)
                cs := f32(math.cos(f64(a)))
                append(&individual.ops,XOp{m=x_rotation({ax,ay,az},a),kind=.Rotate,rotate=true,axis={ax,ay,az},angle=a})
                if ax!=0 || ay!=0 do individual.spatial=true
                comp.has_transform=true
                switch {
                case ax == 0 && ay == 0 && az != 0:
                    comp.transform_rot += az < 0 ? -a : a; comp.has_transform = true
                case ay == 0 && az == 0 && ax != 0:
                    comp.transform_sy *= cs; comp.has_transform = true
                    if cs < 0 do comp.xf_back = !comp.xf_back
                case ax == 0 && az == 0 && ay != 0:
                    comp.transform_sx *= cs; comp.has_transform = true
                    if cs < 0 do comp.xf_back = !comp.xf_back
                }
            }
        }
    }
    if v, ok := decls["scale"]; ok {
        lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lo != "" && lo != "none" {
            toks := split_top_level(lo) // idem: `scale: calc(105% * 1)` tem espaço dentro

            num :: proc(t: string) -> (f32, bool) {
                if strings.has_suffix(t, "%") {
                    if n, k := strconv.parse_f64(t[:len(t)-1]); k do return f32(n)/100, true
                    return 0, false
                }
                if n, k := strconv.parse_f64(t); k do return f32(n), true
                return 0, false
            }
            if len(toks) >= 1 {
                if sx, k := num(toks[0]); k {
                    sy := sx // 1 valor: escala uniforme
                    if len(toks) >= 2 { if v2, k2 := num(toks[1]); k2 do sy = v2 }
                    op:=XOp{m=1,kind=.Scale}; op.m[0,0]=sx; op.m[1,1]=sy
                    if len(toks)>=3 { if z,k:=num(toks[2]); k { op.m[2,2]=z; individual.spatial=true } }
                    append(&individual.ops,op)
                    comp.transform_sx *= sx; comp.transform_sy *= sy; comp.has_transform = true
                }
            }
        }
    }
    if len(individual.ops)>0 {
        comp.xform=new(XList)
        x_copy(comp.xform,&individual)
    }
    if v, ok := decls["transform"]; ok {
        parse_transform(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    if v, ok := decls["perspective"]; ok {
        if px,pct,k := parse_len(resolve_var(v,vars),comp.font_size,vw,vh); k && !pct && px>0 do comp.perspective=max(px,1)
    }
    if v, ok := decls["perspective-origin"]; ok {
        comp.perspective_ox,comp.perspective_oy,comp.perspective_opx,comp.perspective_opy,_=x_parse_origin(resolve_var(v,vars),comp.font_size,vw,vh)
    }
    if v, ok := decls["transform-origin"]; ok {
        comp.transform_ox,comp.transform_oy,comp.transform_opx,comp.transform_opy,comp.transform_opz=x_parse_origin(resolve_var(v,vars),comp.font_size,vw,vh)
    }
    // offset-path / offset-distance / offset-rotate (CSS Motion Path). Só path().
    if v, ok := decls["offset-path"]; ok {
        rv := strings.trim_space(resolve_var(v, vars))
        lo := strings.to_lower(rv, context.temp_allocator)
        if strings.has_prefix(lo, "path(") {
            inner := rv[5:] // depois de "path("
            if e := strings.last_index_byte(inner, ')'); e >= 0 do inner = inner[:e]
            inner = strings.trim_space(inner)
            inner = strings.trim(inner, "'\"") // remove aspas do path('...')
            comp.offset_path = strings.clone(inner, context.temp_allocator)
            comp.has_offset_path = true
        }
    }
    if v, ok := decls["offset-distance"]; ok {
        rv := strings.trim_space(resolve_var(v, vars))
        if strings.has_suffix(rv, "%") {
            if f, k := strconv.parse_f32(strings.trim_space(rv[:len(rv)-1])); k {
                comp.offset_distance = f / 100; comp.offset_distance_pct = true
            }
        } else if px, _, k := parse_len(rv, comp.font_size, vw, vh); k {
            comp.offset_distance = px; comp.offset_distance_pct = false
        }
    }
    if v, ok := decls["offset-rotate"]; ok {
        lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        comp.offset_rotate_auto = strings.contains(lo, "auto") || strings.contains(lo, "reverse") || lo == ""
        // extrai o token de ângulo (o resto sem as palavras-chave auto/reverse)
        ang := strings.trim_space(strings.trim_space(strings.trim_prefix(strings.trim_prefix(lo, "auto"), "reverse")))
        comp.offset_rotate_angle = ang != "" ? parse_angle(ang) : 0
        if strings.contains(lo, "reverse") do comp.offset_rotate_angle += math.PI
    }
    if v, ok := decls["box-shadow"]; ok {
        parse_box_shadow(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    if v, ok := decls["text-shadow"]; ok {
        parse_text_shadow(comp, resolve_var(v, vars), comp.font_size, vw, vh)
    }
    if v, ok := decls["content"]; ok {
        raw := resolve_var(v, vars)
        lo := strings.to_lower(strings.trim_space(raw), context.temp_allocator)
        if lo == "" || lo == "none" || lo == "normal" {
            // sem caixa gerada
        } else if strings.contains(raw, "counter(") || strings.contains(raw, "counters(") {
            // counters precisam da ordem do documento → resolvidos no passe de counters
            // (counter_dfs tem o nó, resolve attr() junto se coexistir).
            comp.content_raw = raw; comp.content_has_counter = true; comp.has_content = true
        } else {
            // SEQUÊNCIA de componentes (strings + attr() + open/close-quote), tokenizada
            // e concatenada corretamente. Antes, `parse_content` tirava só as aspas
            // externas de `"<" attr(href) ">"` → dumpava o miolo literal. Temp: o
            // compute_pseudo clona p/ persistente.
            comp.content = resolve_content_counters(raw, nil, node, context.temp_allocator)
            comp.has_content = true
        }
    }
    if v, ok := decls["counter-reset"];     ok do comp.counter_reset_raw     = resolve_var(v, vars)
    if v, ok := decls["counter-increment"]; ok do comp.counter_increment_raw = resolve_var(v, vars)
    if v, ok := decls["counter-set"];       ok do comp.counter_set_raw       = resolve_var(v, vars)
    // `quotes` (herda): guarda o valor cru; o layout resolve os pares por profundidade
    // ao montar as aspas de <q> (content: open-quote/close-quote).
    if v, ok := decls["quotes"]; ok do comp.quotes_raw = resolve_var(v, vars)
    if v, ok := decls["font-weight"]; ok {
        // ⚠️ resolve_var OBRIGATÓRIO aqui: o Tailwind v4 não escreve o número, escreve
        // `font-weight: var(--font-weight-bold)`. Sem resolver, o valor cru não casa
        // nenhum case, o peso herdado permanece e TODO `font-bold`/`font-semibold` do
        // site vira texto normal (o ticker e o preço do card do tradebig).
        lv := strings.to_lower(resolve_var(v, vars), context.temp_allocator)
        // Guarda o NÚMERO; a face embutida que o serve (500 → regular, 600 →
        // semibold…) é decisão do `fw_class`, no layout.
        // `bolder`/`lighter` aqui são relativos ao `comp.weight` — que é o
        // herdado, EXCETO em h1..h6 (o UA já pôs 700). O compute_node refaz o
        // relativo contra o peso do PAI de verdade.
        if w, k := font_weight_token(strings.trim_space(lv), comp.weight); k do comp.weight = w
        // valores inválidos: mantém o herdado
    }
    if v, ok := decls["font-style"]; ok {
        // idem font-weight: o valor pode vir de custom property.
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "italic", "oblique": comp.italic = true
        case "normal":            comp.italic = false
        }
    }
    { // overflow-wrap (e o alias legado word-wrap)
        v, ok := decls["overflow-wrap"]
        if !ok do v, ok = decls["word-wrap"]
        if ok {
            switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
            case "break-word": comp.break_word = true; comp.wrap_anywhere = false
            case "anywhere":   comp.break_word = true; comp.wrap_anywhere = true
            case "normal":     comp.break_word = false; comp.wrap_anywhere = false
            }
        }
    }
    if v, ok := decls["word-break"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "break-all":  comp.break_all = true
        case "break-word": comp.break_all = false; comp.break_word = true; comp.wrap_anywhere = true
        case "normal":     comp.break_all = false
        }
    }
    if v, ok := decls["text-overflow"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "ellipsis": comp.ellipsis = true
        case "clip":     comp.ellipsis = false
        }
    }
    // -webkit-line-clamp: N (E o line-clamp sem prefixo) — trunca em N linhas.
    // Ativamos pelo valor N; display:-webkit-box/box-orient:vertical (que o
    // acompanham na spec legada) são formalidades que não exigimos.
    for prop in ([]string{"-webkit-line-clamp", "line-clamp"}) {
        if v, ok := decls[prop]; ok {
            lo := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
            if lo == "none" do comp.line_clamp = 0
            else if n, k := strconv.parse_int(lo); k && n > 0 do comp.line_clamp = n
        }
    }
    // Família extraída do shorthand `font` (o que vem DEPOIS do tamanho e do
    // /line-height). Fica fora do bloco porque quem aplica família é o bloco de
    // font-family, mais abaixo.
    sh_family := ""
    // ESTILO e PESO embutidos no shorthand `font`. A gramática é
    //   font: [ <style> || <variant> || <weight> || <stretch> ]? <size> [/<lh>]? <family>
    // — os quatro vêm em ORDEM LIVRE antes do tamanho, então roteamos por VALOR
    // (não por posição) até o token de tamanho.
    //
    // ⚠️ O PESO era simplesmente JOGADO FORA: `font: bold 40px serif` renderizava
    // pixel a pixel igual a `font-weight:normal` (medido por `--imgdiff`: 0.000%
    // contra o normal e 6.1% contra o bold correto). O comentário abaixo já
    // discutia como distinguir tamanho de peso — o código do peso nunca existiu.
    if v, ok := decls["font"]; ok {
        lv := strings.to_lower(resolve_var(v, vars), context.temp_allocator)
        toks := split_top_level(lv)
        sh_italic := false
        sh_weight := FW_NORMAL
        saw_size  := false
        scan: for tok in toks {
            t := tok
            if slash := strings.index_byte(t, '/'); slash >= 0 do t = t[:slash] // "12px/1.5"
            if is_font_size_token(t) { saw_size = true; break scan }
            switch {
            case t == "italic" || t == "oblique": sh_italic = true
            case:
                if w, k := font_weight_token(t, comp.weight); k do sh_weight = w
            }
        }
        // Reset da spec: o shorthand devolve ao INICIAL todo sub-valor omitido —
        // e só é um `font` válido se declarar o tamanho (daí o `saw_size`).
        // Aplicamos aos dois sub-valores que modelamos (style e weight).
        // ⚠️ Só quando o longhand correspondente NÃO está no mesmo conjunto: o
        // `decls` é PLANO e não guarda ordem relativa entre shorthand e longhand,
        // então na dúvida o longhand vence (mesma convenção do `background`).
        if saw_size {
            if _, tem := decls["font-style"];  !tem do comp.italic = sh_italic
            if _, tem := decls["font-weight"]; !tem do comp.weight = sh_weight
            if _, tem := decls["font-kerning"]; !tem do comp.font_kerning = .Auto
        }
        // TAMANHO e LINE-HEIGHT do shorthand (`font: [estilo] <size>[/<lh>] <familia>`).
        // Antes só o itálico e a família saíam daqui: `body{font:16px/1.5 sans-serif}`
        // não mexia em nenhum dos dois e o texto ficava no default 16px/1.3 — e, pior,
        // qualquer `lh` do documento passava a medir contra a entrelinha ERRADA.
        // Como distinguir o tamanho do PESO, já que os dois podem ser numéricos:
        // tamanho tem UNIDADE (ou é palavra-chave de tamanho); `700` puro é peso.
        // O `/` pode vir colado (`16px/1.5`) ou solto (`16px / 1.5`).
        // ⚠️ O reset da spec (acima) cobre style e weight; `font-variant`/`-stretch`
        // não são modelados e seguem intocados.
        size_str, lh_str := "", ""
        for tok, i in toks {
            t := tok
            if t == "" || t == "/" do continue
            if slash := strings.index_byte(t, '/'); slash >= 0 {
                lh_str = strings.trim_space(t[slash + 1:])
                t = strings.trim_space(t[:slash])
                if t == "" do continue // era só "/1.5" (o `/` veio solto antes)
            }
            if is_font_size_token(t) {
                size_str = t
                if lh_str == "" && i + 1 < len(toks) {
                    nx := toks[i + 1]
                    if strings.has_prefix(nx, "/") {
                        lh_str = strings.trim_space(nx[1:])
                        if lh_str == "" && i + 2 < len(toks) do lh_str = toks[i + 2]
                    }
                }
                // A FAMÍLIA é tudo que sobra depois do tamanho (e do line-height,
                // colado `16px/1.5` ou solto `16px / 1.5`). Sem isto, o valor que
                // ia para o resolvedor de família era o shorthand INTEIRO: o 1º
                // item da lista virava `500 5.4rem / 1.2 "dm serif display"`, que
                // não casa com nada, e a família caía no PRÓXIMO item (a fallback
                // genérica). Consequência: **webfont declarada por `font:` nunca
                // era usada** — só as declaradas por `font-family:`.
                j := i + 1
                for j < len(toks) {
                    tk := toks[j]
                    if tk == "/" { j += 2; continue }                  // "/" solto + o valor
                    if strings.has_prefix(tk, "/") { j += 1; continue } // "/1.2"
                    break
                }
                if j < len(toks) do sh_family = strings.join(toks[j:], " ", context.temp_allocator)
                break
            }
        }
        if size_str != "" {
            if px, k := parse_font_size(size_str, comp.font_size, vw, vh); k {
                comp.font_size = px
                comp.has_font_size = true
            }
        }
        if lh_str != "" do comp.line_height = parse_line_height(lh_str, comp.font_size)
        if size_str != "" || lh_str != "" {
            g_cur_lh_px = comp.font_size * (comp.line_height > 0 ? comp.line_height : 1.3)
        }
    }
    if v, ok := decls["display"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "none":              comp.display_none = true
        case "flex":              comp.display_flex = true
        case "inline-flex":       comp.display_flex = true;  comp.display_inline_level = true
        case "grid":              comp.display_grid = true
        case "inline-grid":       comp.display_grid = true;  comp.display_inline_level = true
        case "inline-block":      comp.display_inline_block = true
        case "block", "flow-root": comp.display_block = true
        case "inline":            comp.display_inline = true
        case "table":             comp.display_table = true
        case "inline-table":      comp.display_table = true; comp.display_inline_level = true
        case "table-row":         comp.display_table_row = true
        case "table-cell":        comp.display_table_cell = true
        case "table-row-group", "table-header-group", "table-footer-group":
            comp.display_table_rowgrp = true
        case "contents":          comp.display_contents = true
        }
    }
    if v, ok := decls["font-size"]; ok {
        if px, k := parse_font_size(resolve_var(v, vars), comp.font_size, vw, vh); k {
            comp.font_size = px
            comp.has_font_size = true
            g_cur_lh_px = comp.font_size * (comp.line_height > 0 ? comp.line_height : 1.3)
        }
    }
    // font-size-adjust: 0 → tamanho ajustado = 0 (texto invisível). Só o caso 0 é
    // tratado; valores não-zero exigem a razão de aspecto da fonte (não suportado).
    if v, ok := decls["font-size-adjust"]; ok {
        if strings.trim_space(resolve_var(v, vars)) == "0" {
            comp.font_size = 0
            comp.has_font_size = true
        }
    }
    // font-family (ou a família embutida no shorthand `font`). Só aplica se
    // reconhecermos algo na stack; senão mantém o que foi herdado.
    {
        fam_val := ""
        if v, ok := decls["font-family"]; ok do fam_val = v
        else do fam_val = sh_family // só a parte de FAMÍLIA do shorthand (ver acima)
        if fam_val != "" {
            if f, fid, ok := parse_font_family(resolve_var(fam_val, vars)); ok {
                comp.font_family = f; comp.has_font_family = true; comp.font_fam_id = fid
            }
        }
    }
    if v, ok := decls["position"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "relative": comp.position = .Relative
        case "absolute": comp.position = .Absolute
        case "fixed":    comp.position = .Fixed
        case "sticky", "-webkit-sticky": comp.position = .Sticky
        case:            comp.position = .Static
        }
    }
    // will-change: cada prop LISTADO cujo valor não-inicial geraria um bloco contenedor
    // p/ posicionados deve, ao ser nomeado aqui, gerar esse bloco (css-will-change §3).
    // `position` → só absolute; transform/perspective/filter/backdrop-filter/contain/
    // offset-path (e translate/rotate/scale/individual) → absolute E fixed.
    if v, ok := decls["will-change"]; ok {
        lo := strings.to_lower(v, context.temp_allocator)
        for tok in strings.split(lo, ",", context.temp_allocator) {
            t := strings.trim_space(tok)
            switch t {
            case "opacity":
                comp.stacking_hint = true
            case "position":
                comp.cb_abs = true
            case "transform", "perspective", "filter", "backdrop-filter",
                 "contain", "offset-path", "translate", "rotate", "scale":
                comp.cb_abs = true; comp.cb_fixed = true
                comp.stacking_hint = true
            }
        }
    }
    // contain (css-contain): qualquer valor != none estabelece contenção. Usado p/
    // suprimir a propagação do fundo do <body> ao viewport (css-contain §"the used
    // value ... is not propagated"): um body contido pinta o fundo só na própria
    // caixa, não no canvas. (strict/content/size/layout/style/paint todos contam.)
    if v, ok := decls["contain"]; ok {
        lo := strings.trim_space(strings.to_lower(resolve_var(v, vars), context.temp_allocator))
        comp.contained = lo != "" && lo != "none" && lo != "initial"
        for tok in strings.split(lo, " ", context.temp_allocator) {
            if tok == "paint" || tok == "layout" || tok == "strict" || tok == "content" do comp.stacking_hint = true
        }
    }
    // content-visibility: `hidden` PULA a renderização do conteúdo (a caixa
    // permanece, ao contrário de display:none). `auto` = renderiza (a versão
    // "pula o que está fora da tela" é otimização, não muda a aparência).
    if v, ok := decls["content-visibility"]; ok {
        lo := strings.trim_space(strings.to_lower(resolve_var(v, vars), context.temp_allocator))
        comp.content_hidden = lo == "hidden"
    }
    // contain-intrinsic-size: <w> [<h>] de RESERVA quando o conteúdo é pulado
    // (evita a caixa colapsar p/ 0 e o scroll pular). `auto <len>` = ignora o
    // `auto` (que reusa a última medida real) e usa o comprimento.
    if v, ok := decls["contain-intrinsic-size"]; ok {
        toks := strings.fields(strings.to_lower(resolve_var(v, vars), context.temp_allocator), context.temp_allocator)
        vals := make([dynamic]f32, context.temp_allocator)
        for tk in toks {
            if tk == "auto" || tk == "none" do continue
            if px, pct, k := parse_len(tk, comp.font_size, vw, vh); k && !pct do append(&vals, px)
        }
        if len(vals) >= 1 { comp.cis_w = vals[0]; comp.has_cis_w = true
                            comp.cis_h = vals[len(vals) > 1 ? 1 : 0]; comp.has_cis_h = true }
    }
    if v, ok := decls["contain-intrinsic-width"]; ok {
        if px, pct, k := parse_len(resolve_var(v, vars), comp.font_size, vw, vh); k && !pct { comp.cis_w = px; comp.has_cis_w = true }
    }
    if v, ok := decls["contain-intrinsic-height"]; ok {
        if px, pct, k := parse_len(resolve_var(v, vars), comp.font_size, vw, vh); k && !pct { comp.cis_h = px; comp.has_cis_h = true }
    }

    // inset shorthand: mesma lógica de 1-4 valores do margin/padding (t r b l).
    // Aplicado antes dos lados individuais p/ que top/right/bottom/left possam sobrescrever.
    if v, ok := decls["inset"]; ok {
        // split_top_level: `inset: calc(10% - 5px) 0` tem espaços DENTRO dos parênteses
        toks := split_top_level(resolve_var(v, vars))
        vals: [4]string
        switch len(toks) {
        case 1: vals = {toks[0], toks[0], toks[0], toks[0]}
        case 2: vals = {toks[0], toks[1], toks[0], toks[1]}
        case 3: vals = {toks[0], toks[1], toks[2], toks[1]}
        case:
            if len(toks) >= 4 do vals = {toks[0], toks[1], toks[2], toks[3]}
        }
        if len(toks) >= 1 {
            for i in 0 ..< 4 do set_inset_side(comp, i, vals[i], vw, vh)
        }
    }
    {
        sides := [4]string{"top", "right", "bottom", "left"}
        for s, i in sides {
            if v, ok := decls[s]; ok do set_inset_side(comp, i, resolve_var(v, vars), vw, vh)
        }
    }
    if v, ok := decls["line-height"]; ok {
        comp.line_height = parse_line_height(resolve_var(v, vars), comp.font_size)
        g_cur_lh_px = comp.font_size * (comp.line_height > 0 ? comp.line_height : 1.3)
    }
    if v, ok := decls["letter-spacing"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "normal" {
            comp.letter_spacing = 0
        } else if px, pct, k := parse_len(lv, comp.font_size, vw, vh); k && !pct {
            comp.letter_spacing = px
        }
    }
    if v, ok := decls["word-spacing"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "normal" {
            comp.word_spacing = 0
        } else if px, pct, k := parse_len(lv, comp.font_size, vw, vh); k && !pct {
            comp.word_spacing = px // % de word-spacing é raro; ignorado
        }
    }
    for prop in ([]string{"text-wrap", "text-wrap-style"}) {
        if v, ok := decls[prop]; ok {
            comp.text_balance = strings.contains(strings.to_lower(v, context.temp_allocator), "balance")
        }
    }
    if v, ok := decls["text-indent"]; ok {
        comp.indent_each_line = false; comp.indent_hanging = false
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        first := ""
        for token in split_top_level(lv) {
            if token == "each-line" { comp.indent_each_line = true }
            else if token == "hanging" { comp.indent_hanging = true }
            else { first = token }
        }
        if px, pct, k := parse_len(first, comp.font_size, vw, vh); k {
            comp.text_indent = px // parse_len já devolve fração p/ %
            comp.text_indent_pct = pct
        }
    }
    if v, ok := decls["text-transform"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "uppercase":  comp.text_transform = .Upper
        case "lowercase":  comp.text_transform = .Lower
        case "capitalize": comp.text_transform = .Capitalize
        case "none":       comp.text_transform = .None
        }
    }
    if v, ok := decls["white-space"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "nowrap":                       comp.white_space = .Nowrap
        case "pre":          comp.white_space = .Pre
        case "pre-wrap":     comp.white_space = .Pre_Wrap
        case "pre-line":     comp.white_space = .Pre_Line
        case "break-spaces": comp.white_space = .Break_Spaces
        case "normal":       comp.white_space = .Normal
        }
    }
    if v, ok := decls["visibility"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "hidden", "collapse": comp.invisible = true
        case "visible":            comp.invisible = false // filho reexibe sob pai oculto
        }
    }
    // list-style-type e o shorthand list-style (varre os tokens buscando o tipo;
    // 'none' vence — cobre `list-style: none` que zera o marcador).
    if v, ok := decls["list-style-type"]; ok {
        if ls, k := parse_list_style_type(strings.trim_space(v)); k do comp.list_style = ls
    }
    if v, ok := decls["list-style"]; ok {
        lo := strings.to_lower(resolve_var(v, vars), context.temp_allocator)
        if strings.contains(lo, "none") {
            comp.list_style = .None // list-style:none (ou list-style-type/image none)
        } else {
            for tok in strings.fields(lo, context.temp_allocator) {
                if ls, k := parse_list_style_type(tok); k { comp.list_style = ls; break }
            }
        }
    }
    apply_border_radius(comp, decls, vars, comp.font_size, vw, vh)
    if v, ok := decls["text-align"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "center":        comp.text_align = .Center
        case "right": comp.text_align = .Right
        case "end": comp.text_align = .End
        case "match-parent": comp.text_align = .Match_Parent
        case "justify":       comp.text_align = .Justify
        case "left": comp.text_align = .Left
        case "start": comp.text_align = .Start
        }
    }
    // text-align-last (HERDA): alinhamento da ÚLTIMA linha do bloco. `auto` = segue text-align.
    if v, ok := decls["text-align-last"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "center":        comp.text_align_last = .Center; comp.has_text_align_last = true
        case "right": comp.text_align_last = .Right; comp.has_text_align_last = true
        case "end": comp.text_align_last = .End; comp.has_text_align_last = true
        case "justify":       comp.text_align_last = .Justify; comp.has_text_align_last = true
        case "left": comp.text_align_last = .Left; comp.has_text_align_last = true
        case "start": comp.text_align_last = .Start; comp.has_text_align_last = true
        case "auto":          comp.has_text_align_last = false
        }
    }
    // text-decoration é shorthand de line/style/color/thickness (CSS Text Decor L4).
    // O shorthand carrega line + (opcional) style/color; os longhands sobrescrevem.
    is_shorthand := false
    deco := ""
    if v, ok := decls["text-decoration"]; ok { deco = v; is_shorthand = true }
    else if v, ok := decls["-webkit-text-decoration"]; ok { deco = v; is_shorthand = true } // prefixo Safari
    if v, ok := decls["text-decoration-line"]; ok { deco = v; is_shorthand = false } // longhand só de linha vence a linha do shorthand
    if deco != "" {
        comp.deco_set = true // autor definiu → suprime o sublinhado default de link
        lv := strings.to_lower(resolve_var(deco, vars), context.temp_allocator)
        if strings.contains(lv, "none") {
            comp.underline = false; comp.overline = false; comp.strike = false
        } else {
            if strings.contains(lv, "underline")    do comp.underline = true
            if strings.contains(lv, "overline")     do comp.overline = true
            if strings.contains(lv, "line-through") do comp.strike = true
        }
        // O shorthand pode trazer style e color junto (ex.: "dotted red underline").
        // split_top_level (não strings.fields) pela mesma razão da borda: a cor pode
        // ser funcional e ter espaços dentro dos parênteses.
        if is_shorthand {
            for tok in split_top_level(lv) {
                switch tok {
                case "solid":  comp.deco_style = .Solid
                case "double": comp.deco_style = .Double
                case "dotted": comp.deco_style = .Dotted
                case "dashed": comp.deco_style = .Dashed
                case "wavy":   comp.deco_style = .Wavy
                case "underline", "overline", "line-through", "none", "blink":
                    // palavras de linha — já tratadas acima
                case:
                    if c, k := parse_color_cc(tok, comp.color); k do comp.deco_color = c
                }
            }
        }
    }
    if v, ok := decls["text-decoration-style"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "solid":  comp.deco_style = .Solid
        case "double": comp.deco_style = .Double
        case "dotted": comp.deco_style = .Dotted
        case "dashed": comp.deco_style = .Dashed
        case "wavy":   comp.deco_style = .Wavy
        }
    }
    if v, ok := decls["text-decoration-color"]; ok {
        if c, k := parse_color_cc(resolve_var(v, vars), comp.color); k do comp.deco_color = c
    }
    if v, ok := decls["text-decoration-thickness"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "auto" || lv == "from-font" {
            comp.deco_thick = 0
        } else if px, _, k := parse_len(lv, comp.font_size, vw, vh); k {
            comp.deco_thick = px
        }
    }
    // text-underline-offset (HERDA): afasta a linha do texto. `auto` = 0.
    if v, ok := decls["text-underline-offset"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if lv == "auto" {
            comp.underline_offset = 0
        } else if px, _, k := parse_len(lv, comp.font_size, vw, vh); k {
            comp.underline_offset = px
        }
    }
    // text-underline-position (HERDA): `under` desce a linha p/ abaixo das descidas.
    if v, ok := decls["text-underline-position"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        comp.underline_under = strings.contains(lv, "under")
    }
    // text-decoration-skip-ink (HERDA): `none` = sublinhado contínuo (já é o nosso
    // comportamento; `auto` skiparia glifos, o que não fazemos). Guardado p/ o futuro.
    if v, ok := decls["text-decoration-skip-ink"]; ok {
        comp.skip_ink_none = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "none")
    }

    fs := comp.font_size

    // ── box model ──
    if v, ok := decls["margin"]; ok {
        comp.margin, comp.margin_frac, comp.margin_off = parse_box4_linear(resolve_var(v, vars), fs, vw, vh)
        comp.has_margin = true
    }
    apply_side(&comp.margin, &comp.has_margin, decls, "margin", vars, fs, vw, vh, &comp.margin_frac, &comp.margin_off)
    if v, ok := decls["padding"]; ok {
        comp.padding, comp.padding_frac, comp.padding_off = parse_box4_linear(resolve_var(v, vars), fs, vw, vh)
    }
    apply_side(&comp.padding, nil, decls, "padding", vars, fs, vw, vh, &comp.padding_frac, &comp.padding_off)
    for i in 0 ..< 4 {
        comp.padding_pct[i] = comp.padding_frac[i] != 0
        comp.margin_pct[i]  = comp.margin_frac[i]  != 0
    }

    apply_border_props(comp, decls, vars, fs, vw, vh)

    // outline: mesmo formato do border ("2px solid red"), mas pintado FORA da
    // caixa e sem afetar layout. Sem cor explícita assume a cor do texto.
    if v, ok := decls["outline"]; ok {
        if w, c, has_col, k := parse_border(resolve_var(v, vars), fs, comp.color, vw, vh); k {
            comp.outline_w = w
            comp.outline_c = has_col ? c : comp.color
        } else {
            comp.outline_w = 0 // none/auto/inválido
        }
    }
    if v, ok := decls["outline-width"]; ok {
        if px, _, k := parse_len(resolve_var(v, vars), fs, vw, vh); k {
            comp.outline_w = px
            if comp.outline_c == 0 do comp.outline_c = comp.color
        }
    }
    if v, ok := decls["outline-color"]; ok {
        if c, k := parse_color_cc(resolve_var(v, vars), comp.color); k do comp.outline_c = c
    }
    if v, ok := decls["outline-style"]; ok {
        lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
        if lv == "none" || lv == "hidden" do comp.outline_w = 0
    }
    if v, ok := decls["outline-offset"]; ok {
        if px, _, k := parse_len(resolve_var(v, vars), fs, vw, vh); k do comp.outline_off = px
    }

    if v, ok := decls["font-kerning"]; ok {
        switch strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator) {
        case "auto":   comp.font_kerning = .Auto
        case "normal": comp.font_kerning = .Normal
        case "none":   comp.font_kerning = .None
        }
    }

    if v, ok := decls["width"]; ok {
        rvw := resolve_var(v, vars)
        // forma linear `pct*base + off`: cobre px puro, % puro e calc misto
        // (`calc(100% - 40px)`) — a base da % só é conhecida no layout.
        if off, pc, bd, k := parse_len_clamped(rvw, fs, vw, vh); k {
            if pc != 0 { comp.width = pc; comp.width_pct = true; comp.width_pct_off = off; comp.width_bd = bd }
            else       { comp.width = off; comp.width_pct = false; comp.width_pct_off = 0; comp.width_bd = {} }
            comp.has_width = true
            comp.width_mc = false; comp.width_minc = false; comp.width_fit = false
        }
        else {
            // Keywords intrínsecas não são auto: flex/grid não devem esticá-las.
            lv := strings.to_lower(strings.trim_space(rvw), context.temp_allocator)
            if lv == "max-content" || lv == "min-content" || lv == "fit-content" || lv == "auto" {
                comp.has_width = false; comp.width_pct = false
                comp.width_mc = lv != "auto"
                comp.width_minc = lv == "min-content"
                comp.width_fit = lv == "fit-content"
            }
        }
    }
    if v, ok := decls["max-width"]; ok {
        if off, pc, bd, k := parse_len_clamped(resolve_var(v, vars), fs, vw, vh); k {
            if pc != 0 { comp.maxw = pc; comp.maxw_pct = true; comp.maxw_pct_off = off; comp.maxw_bd = bd }
            else       { comp.maxw = off; comp.maxw_pct = false; comp.maxw_pct_off = 0; comp.maxw_bd = {} }
            comp.has_maxw = true
        }
    }
    if v, ok := decls["min-width"]; ok {
        if off, pc, bd, k := parse_len_clamped(resolve_var(v, vars), fs, vw, vh); k {
            if pc != 0 { comp.minw = pc; comp.minw_pct = true; comp.minw_pct_off = off; comp.minw_bd = bd }
            else       { comp.minw = off; comp.minw_pct = false; comp.minw_pct_off = 0; comp.minw_bd = {} }
            comp.has_minw = true
        }
    }
    if v, ok := decls["height"]; ok {
        // altura em % (ex.: Tailwind `h-full`) é resolvida no LAYOUT contra a altura
        // DEFINIDA do pai (height explícita, aspect-ratio ou force_h). Guardamos só a
        // fração aqui; se o pai não tiver altura definida, vira auto (não resolve).
        rv := resolve_var(v, vars)
        // forma linear: % puro OU calc misto (`calc(100% - 40px)` do openstreetmap)
        // viram fração+offset resolvidos no layout; px puro vira height direto.
        if off, pc, bd, kl := parse_len_clamped(rv, fs, vw, vh); kl {
            if pc != 0 { comp.height_pct = pc; comp.height_pct_off = off; comp.has_height_pct = true; comp.height_bd = bd }
            else       { comp.height = off; comp.has_height = true; comp.height_bd = {} }
        }
        else {
            // min/max/fit-content: altura intrínseca (= conteúdo natural), mas NÃO
            // é `auto` → itens flex/grid com ela não esticam (align stretch só p/ auto).
            lv := strings.to_lower(strings.trim_space(rv), context.temp_allocator)
            if lv == "max-content" || lv == "min-content" || lv == "fit-content" do comp.height_mc = true
        }
    }
    if v, ok := decls["max-height"]; ok {
        // % (e calc com %) ficam pendentes: o PAI resolve contra a altura definida dele.
        if off, pc, bd, k := parse_len_clamped(resolve_var(v, vars), fs, vw, vh); k {
            if pc != 0 { comp.maxh_pct = pc; comp.maxh_pct_off = off; comp.has_maxh_pct = true; comp.maxh_bd = bd }
            else       { comp.maxh = off; comp.has_maxh = true; comp.maxh_bd = {} }
        }
    }
    if v, ok := decls["min-height"]; ok {
        rv := resolve_var(v, vars)
        if off, pc, bd, k := parse_len_clamped(rv, fs, vw, vh); k {
            if pc != 0 { comp.minh_pct = pc; comp.minh_pct_off = off; comp.has_minh_pct = true; comp.minh_bd = bd }
            else       { comp.minh = off; comp.has_minh = true; comp.minh_bd = {} }
        }
        else {
            lv := strings.to_lower(strings.trim_space(rv), context.temp_allocator)
            if lv == "max-content" || lv == "min-content" || lv == "fit-content" do comp.minh_mc = true
        }
    }
    if v, ok := decls["box-sizing"]; ok {
        if strings.to_lower(strings.trim_space(v), context.temp_allocator) == "border-box" do comp.box_sizing = .Border
    }
    // aspect-ratio: <w> [/ <h>] (ignora a palavra 'auto', que só desliga a razão).
    // Guardamos w/h; o layout deriva a dimensão faltante a partir da definida.
    if v, ok := decls["aspect-ratio"]; ok {
        if r, k := parse_aspect_ratio(resolve_var(v, vars)); k do comp.aspect = r
    }

    comp.margin_left_auto, comp.margin_right_auto = margins_x_auto(decls, vars)
    comp.margin_x_auto = comp.margin_left_auto && comp.margin_right_auto
    comp.margin_top_auto, comp.margin_bottom_auto = margins_y_auto(decls, vars)

    // ── flex ──
    if v, ok := decls["flex-direction"]; ok {
        lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
        if lv == "column" || lv == "column-reverse" do comp.flex_dir = .Column
        else do comp.flex_dir = .Row
        comp.flex_reverse = strings.has_suffix(lv, "-reverse")
    }
    if v, ok := decls["flex-wrap"]; ok {
        lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
        comp.flex_wrap = lv == "wrap" || lv == "wrap-reverse"
        comp.flex_wrap_reverse = lv == "wrap-reverse"
    }
    if v, ok := decls["justify-content"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "center":        comp.justify = .Center
        case "flex-end", "end", "right": comp.justify = .End
        case "space-between": comp.justify = .Between
        case "space-around":  comp.justify = .Around
        case "space-evenly":  comp.justify = .Evenly
        case:                 comp.justify = .Start
        }
    }
    if v, ok := decls["align-items"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "flex-start", "start": comp.align_items = .Start
        case "baseline", "first baseline": comp.align_items = .Baseline
        case "last baseline": comp.align_items = .LastBaseline
        case "center":              comp.align_items = .Center
        case "flex-end", "end":     comp.align_items = .End
        case:                       comp.align_items = .Stretch
        }
    }
    if v, ok := decls["align-self"]; ok {
        switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
        case "auto":                comp.has_align_self = false
        case "flex-start", "start": comp.align_self = .Start;   comp.has_align_self = true
        case "center":              comp.align_self = .Center;  comp.has_align_self = true
        case "flex-end", "end":     comp.align_self = .End;     comp.has_align_self = true
        case "baseline", "first baseline": comp.align_self = .Baseline; comp.has_align_self = true
        case "last baseline": comp.align_self = .LastBaseline; comp.has_align_self = true
        case "stretch":             comp.align_self = .Stretch; comp.has_align_self = true
        }
    }
    // align-content: distribui as LINHAS do flex-wrap no eixo cruzado (reusa Flex_Just)
    if v, ok := decls["align-content"]; ok {
        lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
        switch lv {
        case "center":        comp.align_content = .Center
        case "flex-end", "end": comp.align_content = .End
        case "space-between": comp.align_content = .Between
        case "space-around":  comp.align_content = .Around
        case "space-evenly":  comp.align_content = .Evenly
        case:                 comp.align_content = .Start // start/stretch/normal → topo
        }
        // valor EXPLÍCITO que não é stretch/normal desliga o stretch das trilhas auto
        // (a sobra vai p/ offsets/gaps via align_content, não p/ dentro das trilhas).
        comp.ac_stretch = lv == "stretch" || lv == "normal"
    }
    // justify-items / justify-self: alinhamento horizontal do item na célula do grid
    if v, ok := decls["justify-items"]; ok {
        comp.justify_items = parse_box_align(v)
    }
    if v, ok := decls["justify-self"]; ok {
        s := strings.to_lower(strings.trim_space(v), context.temp_allocator)
        if s == "auto" { comp.has_justify_self = false } else { comp.justify_self = parse_box_align(v); comp.has_justify_self = true }
    }
    // place-items/place-content/place-self: shorthands "<align> <justify>?" → aplicam
    // direto nos campos. 1 valor = ambos os eixos. Só age no eixo cujo LONGHAND não
    // foi dado explicitamente (o longhand, parseado acima, vence).
    if v, ok := decls["place-items"]; ok {
        toks := strings.fields(strings.trim_space(v), context.temp_allocator)
        if len(toks) >= 1 {
            jt := len(toks) >= 2 ? toks[1] : toks[0]
            if _, has := decls["align-items"];   !has do comp.align_items   = map_align_items(toks[0])
            if _, has := decls["justify-items"]; !has do comp.justify_items = parse_box_align(jt)
        }
    }
    if v, ok := decls["place-content"]; ok {
        toks := strings.fields(strings.trim_space(v), context.temp_allocator)
        if len(toks) >= 1 {
            jt := len(toks) >= 2 ? toks[1] : toks[0]
            if _, has := decls["align-content"];   !has do comp.align_content = map_align_content(toks[0])
            if _, has := decls["justify-content"]; !has do comp.justify        = map_justify_content(jt)
        }
    }
    if v, ok := decls["place-self"]; ok {
        toks := strings.fields(strings.trim_space(v), context.temp_allocator)
        if len(toks) >= 1 {
            jt := len(toks) >= 2 ? toks[1] : toks[0]
            if _, has := decls["align-self"]; !has {
                if strings.to_lower(strings.trim_space(toks[0]), context.temp_allocator) != "auto" {
                    comp.align_self = map_align_items(toks[0]); comp.has_align_self = true
                }
            }
            if _, has := decls["justify-self"]; !has {
                if strings.to_lower(strings.trim_space(jt), context.temp_allocator) != "auto" {
                    comp.justify_self = parse_box_align(jt); comp.has_justify_self = true
                }
            }
        }
    }
    // gap: <row-gap> <column-gap>?  (gap = espaço entre colunas; row_gap entre linhas)
    // split_top_level (não strings.fields): um único valor pode ser calc()/min()/…
    // com espaços INTERNOS — ex.: Tailwind v4 `gap-4` = `calc(var(--spacing) * 4)`.
    // strings.fields o quebrava em 3 tokens inválidos → gap virava 0.
    if v, ok := decls["gap"]; ok {
        toks := split_top_level(resolve_var(v, vars))
        if len(toks) > 0 { set_gap_row(comp, toks[0], fs, vw, vh); set_gap_col(comp, toks[0], fs, vw, vh) }
        if len(toks) > 1 { set_gap_col(comp, toks[1], fs, vw, vh) }
    }
    if v, ok := decls["row-gap"]; ok    do set_gap_row(comp, resolve_var(v, vars), fs, vw, vh)
    if v, ok := decls["column-gap"]; ok do set_gap_col(comp, resolve_var(v, vars), fs, vw, vh)
    // ── multi-coluna ──
    if v, ok := decls["column-count"]; ok {
        s := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if n, k := strconv.parse_int(s); k && n > 0 do comp.col_count = n // 'auto' fica 0
    }
    if v, ok := decls["column-width"]; ok {
        if px, pct, k := parse_len(resolve_var(v, vars), fs, vw, vh); k && !pct && px > 0 do comp.col_width = px
    }
    if v, ok := decls["columns"]; ok {
        // shorthand: <count> e/ou <width> em qualquer ordem ('auto' ignorado)
        for tok in strings.fields(resolve_var(v, vars), context.temp_allocator) {
            lo := strings.to_lower(tok, context.temp_allocator)
            if lo == "auto" do continue
            if n, k := strconv.parse_int(lo); k && n > 0 { comp.col_count = n; continue }
            if px, pct, k := parse_len(tok, fs, vw, vh); k && !pct && px > 0 do comp.col_width = px
        }
    }
    // fragmentação: break-before/after (+ aliases page-break-*). Só tratamos 'avoid'
    // (impede quebra de coluna entre este bloco e o vizinho); force/always ignorado.
    for prop in ([]string{"break-before", "page-break-before"}) {
        if v, ok := decls[prop]; ok && strings.contains(strings.to_lower(v, context.temp_allocator), "avoid") do comp.break_before_avoid = true
    }
    for prop in ([]string{"break-after", "page-break-after"}) {
        if v, ok := decls[prop]; ok && strings.contains(strings.to_lower(v, context.temp_allocator), "avoid") do comp.break_after_avoid = true
    }

    // ── grid ──
    // shorthand `grid`: além do que grid-template faz, aceita a forma
    // `auto-flow [dense] [<trilhas-implicitas>] / <colunas>` (e o espelho com o
    // auto-flow do lado direito = fluxo por COLUNA). Reseta o resto do subgrupo,
    // mas aqui só ligamos o que o motor usa.
    if v, ok := decls["grid"]; ok {
        raw := strings.trim_space(resolve_var(v, vars))
        lo := strings.to_lower(raw, context.temp_allocator)
        if strings.contains(lo, "auto-flow") {
            sl := -1
            depth := 0
            for i in 0 ..< len(raw) {
                switch raw[i] {
                case '(': depth += 1
                case ')': depth -= 1
                case '/': if depth == 0 && sl < 0 do sl = i
                }
            }
            left  := sl >= 0 ? strings.trim_space(raw[:sl])     : raw
            right := sl >= 0 ? strings.trim_space(raw[sl + 1:]) : ""
            // o lado que tem `auto-flow` define o EIXO do fluxo e as trilhas
            // IMPLÍCITAS; o outro lado é o template explícito do eixo oposto.
            flow_left := strings.contains(strings.to_lower(left, context.temp_allocator), "auto-flow")
            fl := flow_left ? left : right
            tpl := flow_left ? right : left
            comp.grid_flow_col = !flow_left // auto-flow à DIREITA = fluxo por coluna
            fll := strings.to_lower(fl, context.temp_allocator)
            comp.grid_flow_dense = strings.contains(fll, "dense")
            // sobra do lado do auto-flow = lista de trilhas implícitas
            rest := fl
            for tok in ([]string{"auto-flow", "dense"}) {
                if i := strings.index(strings.to_lower(rest, context.temp_allocator), tok); i >= 0 {
                    rest = strings.concatenate({rest[:i], rest[i + len(tok):]}, context.temp_allocator)
                }
            }
            rest = strings.trim_space(rest)
            if rest != "" {
                if flow_left do comp.grid_auto_row_n = parse_grid_auto_tracks(&comp.grid_auto_rows, rest, fs, vw, vh)
                else         do comp.grid_auto_col_n = parse_grid_auto_tracks(&comp.grid_auto_cols, rest, fs, vw, vh)
            }
            if tpl != "" {
                af: bool
                if flow_left do parse_grid_template(&comp.grid_tracks, &comp.grid_track_n, &comp.grid_auto_fill, tpl, fs, vw, vh, &comp.grid_col_lines, &comp.grid_col_line_n)
                else         do parse_grid_template(&comp.grid_row_tracks, &comp.grid_row_track_n, &af, tpl, fs, vw, vh, &comp.grid_row_lines, &comp.grid_row_line_n)
            }
        } else {
            parse_grid_template_shorthand(comp, raw, fs, vw, vh) // `<linhas> / <colunas>`
        }
    }
    if v, ok := decls["grid-template"]; ok {
        parse_grid_template_shorthand(comp, resolve_var(v, vars), fs, vw, vh)
    }
    if v, ok := decls["grid-template-columns"]; ok {
        parse_grid_template(&comp.grid_tracks, &comp.grid_track_n, &comp.grid_auto_fill, resolve_var(v, vars), fs, vw, vh, &comp.grid_col_lines, &comp.grid_col_line_n)
    }
    if v, ok := decls["grid-template-rows"]; ok {
        af: bool // auto-fill de linhas não é usado no layout (linhas crescem por conteúdo)
        parse_grid_template(&comp.grid_row_tracks, &comp.grid_row_track_n, &af, resolve_var(v, vars), fs, vw, vh, &comp.grid_row_lines, &comp.grid_row_line_n)
    }
    if v, ok := decls["grid-template-areas"]; ok {
        parse_grid_template_areas(comp, resolve_var(v, vars))
    }
    // grade IMPLÍCITA: lista de trilhas que CICLA nas linhas/colunas criadas
    // além do template (`grid-auto-rows: 100px 40px` → 100,40,100,40…).
    if v, ok := decls["grid-auto-rows"]; ok {
        comp.grid_auto_row_n = parse_grid_auto_tracks(&comp.grid_auto_rows, resolve_var(v, vars), fs, vw, vh)
    }
    if v, ok := decls["grid-auto-columns"]; ok {
        comp.grid_auto_col_n = parse_grid_auto_tracks(&comp.grid_auto_cols, resolve_var(v, vars), fs, vw, vh)
    }
    // container-type / container-name / container. `size` (as DUAS dimensões) é
    // tratado como inline-size: só consultamos LARGURA, e o eixo de bloco exigiria
    // contenção de altura, que o motor não tem.
    if v, ok := decls["container-type"]; ok {
        lv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        comp.container_inline = lv == "inline-size" || lv == "size"
    }
    if v, ok := decls["container-name"]; ok {
        nm := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        if nm != "none" do comp.container_name = nm
    }
    // shorthand `container: <nome> [/ <tipo>]`. Sem barra, per-spec o tipo fica
    // `normal` (só nomeia) — não inventamos inline-size.
    if v, ok := decls["container"]; ok {
        val := resolve_var(v, vars)
        nm, tp := val, ""
        if sl := strings.index_byte(val, '/'); sl >= 0 { nm = val[:sl]; tp = val[sl + 1:] }
        nml := strings.to_lower(strings.trim_space(nm), context.temp_allocator)
        if nml != "" && nml != "none" do comp.container_name = nml
        tpl := strings.to_lower(strings.trim_space(tp), context.temp_allocator)
        if tpl == "inline-size" || tpl == "size" do comp.container_inline = true
    }

    // grid-auto-flow: <row | column> || dense
    if v, ok := decls["grid-auto-flow"]; ok {
        for t in strings.fields(strings.to_lower(resolve_var(v, vars), context.temp_allocator), context.temp_allocator) {
            switch t {
            case "column": comp.grid_flow_col = true
            case "row":    comp.grid_flow_col = false
            case "dense":  comp.grid_flow_dense = true
            }
        }
    }
    if v, ok := decls["grid-area"]; ok {
        parse_grid_area_prop(comp, resolve_var(v, vars))
    }
    if v, ok := decls["grid-column"]; ok {
        comp.grid_col_start, comp.grid_col_span, comp.grid_col_start_name, comp.grid_col_end_name, comp.grid_col_end_line = parse_grid_line(resolve_var(v, vars))
    }
    if v, ok := decls["grid-row"]; ok {
        comp.grid_row_start, comp.grid_row_span, comp.grid_row_start_name, comp.grid_row_end_name, comp.grid_row_end_line = parse_grid_line(resolve_var(v, vars))
    }

    if v, ok := decls["flex-grow"]; ok {
        if f, k := strconv.parse_f64(strings.trim_space(v)); k do comp.flex_grow = f32(f)
    }
    if v, ok := decls["flex-shrink"]; ok {
        if f, k := strconv.parse_f64(strings.trim_space(v)); k do comp.flex_shrink = f32(f)
    }
    if v, ok := decls["flex-basis"]; ok {
        set_flex_basis(comp, resolve_var(v, vars), fs, vw, vh)
    }
    if v, ok := decls["order"]; ok {
        if o, k := strconv.parse_int(strings.trim_space(v)); k do comp.order = o
    }
    if v, ok := decls["flex"]; ok {
        parse_flex_shorthand(comp, resolve_var(v, vars), fs, vw, vh)
    }

    // Coletor de props não implementadas (para debug/inventário)
    for prop in decls {
        if strings.has_prefix(prop, "--") do continue // custom props são esperadas
        if !css_prop_is_known(prop) {
            if g_css_unknown == nil do g_css_unknown = make(map[string]int)
            if _, exists := g_css_unknown[prop]; exists {
                g_css_unknown[prop] += 1
            } else {
                permanent := strings.clone(prop) // chave precisa durar além do temp allocator
                g_css_unknown[permanent] = 1
            }
        }
    }
}

// gap/column-gap e row-gap: % (ou calc com %) viram fração+offset, resolvidos no
// layout contra o tamanho de conteúdo do container no eixo correspondente.
// top/right/bottom/left (e o shorthand inset): % ou calc-com-% viram fração+offset,
// resolvidos no layout contra a dimensão do bloco contenedor no eixo.
@(private="file")
set_inset_side :: proc(comp: ^Computed, i: int, tok: string, vw, vh: f32) {
    if off, pc, k := parse_len_linear(tok, comp.font_size, vw, vh); k {
        if pc != 0 { comp.inset[i] = pc; comp.inset_pct[i] = true; comp.inset_off[i] = off }
        else       { comp.inset[i] = off; comp.inset_pct[i] = false; comp.inset_off[i] = 0 }
        comp.inset_has[i] = true
    }
}

@(private="file")
set_gap_col :: proc(comp: ^Computed, tok: string, fs, vw, vh: f32) {
    if off, pc, k := parse_len_linear(tok, fs, vw, vh); k {
        if pc != 0 { comp.gap_pct = true; comp.gap_frac = pc; comp.gap_off = off; comp.gap = 0 }
        else       { comp.gap_pct = false; comp.gap = off }
        comp.col_gap = comp.gap
    }
}
@(private="file")
set_gap_row :: proc(comp: ^Computed, tok: string, fs, vw, vh: f32) {
    if off, pc, k := parse_len_linear(tok, fs, vw, vh); k {
        if pc != 0 { comp.row_gap_pct = true; comp.row_gap_frac = pc; comp.row_gap_off = off; comp.row_gap = 0 }
        else       { comp.row_gap_pct = false; comp.row_gap = off }
    }
}

@(private="file")
set_flex_basis :: proc(comp: ^Computed, v: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) {
    lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
    if lv == "auto" || lv == "content" {
        comp.has_flex_basis = true; comp.flex_basis_auto = true
        return
    }
    if off, pc, bd, k := parse_len_clamped(lv, fs, vw, vh); k {
        if pc != 0 { comp.flex_basis = pc; comp.flex_basis_pct = true; comp.flex_basis_pct_off = off; comp.flex_basis_bd = bd }
        else       { comp.flex_basis = off; comp.flex_basis_pct = false; comp.flex_basis_pct_off = 0; comp.flex_basis_bd = {} }
        comp.has_flex_basis = true; comp.flex_basis_auto = false
    }
}

// flex: <grow> <shrink>? <basis>?  | none | auto | initial | <basis>
@(private="file")
parse_flex_shorthand :: proc(comp: ^Computed, v: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) {
    lv := strings.to_lower(strings.trim_space(v), context.temp_allocator)
    switch lv {
    case "none":    comp.flex_grow = 0; comp.flex_shrink = 0; comp.has_flex_basis = true; comp.flex_basis_auto = true; return
    case "auto":    comp.flex_grow = 1; comp.flex_shrink = 1; comp.has_flex_basis = true; comp.flex_basis_auto = true; return
    case "initial": comp.flex_grow = 0; comp.flex_shrink = 1; comp.has_flex_basis = true; comp.flex_basis_auto = true; return
    }
    // split_top_level: `flex: 1 1 calc(100% - 2rem)` — o basis pode ser função.
    toks := split_top_level(lv)
    got_grow := false
    got_basis := false
    nums := 0
    for tok in toks {
        // comprimento (com unidade) ou 0 → basis; número puro → grow/shrink
        if is_len_token(tok) {
            set_flex_basis(comp, tok, fs, vw, vh); got_basis = true
            continue
        }
        if f, k := strconv.parse_f64(tok); k {
            if nums == 0 { comp.flex_grow = f32(f); got_grow = true }
            else if nums == 1 { comp.flex_shrink = f32(f) }
            nums += 1
        }
    }
    // "flex: 1" → grow 1, shrink 1, basis 0
    if got_grow && !got_basis {
        comp.flex_basis = 0; comp.flex_basis_pct = false; comp.flex_basis_pct_off = 0; comp.flex_basis_bd = {}
        comp.has_flex_basis = true; comp.flex_basis_auto = false
    }
}

// Token de comprimento: tem unidade ou é "0"? (número puro vira grow/shrink.)
@(private="file")
is_len_token :: proc(tok: string) -> bool {
    if tok == "0" do return false // ambíguo; tratamos como grow/shrink
    // Token FUNCIONAL (`calc(...)`, `min()`, `clamp()`): nesta posição só pode ser o
    // basis — grow/shrink são números puros. Sem isto, `flex: 1 1 calc(50px + 50px)`
    // não casava nenhuma unidade (o token termina em `)`), o basis nunca era setado
    // e caía no ramo "flex: 1" → basis ZERO, item colapsado. Achado pelo gate de
    // grafia em [style_grafia_test.odin] no dia em que ele foi escrito.
    if strings.has_suffix(tok, ")") && strings.contains(tok, "(") do return true
    // Sufixos: `dvh`/`svh`/`lvh` já entram por "vh" (e as de largura por "vw"); os
    // eixos `vi`/`vb` e `vmin`/`vmax` precisam de entrada própria.
    units := [?]string{"px", "em", "rem", "pt", "%", "vw", "vh", "vmin", "vmax", "vi", "vb", "auto", "content"}
    for u in units {
        if strings.has_suffix(tok, u) do return true
    }
    return false
}

// Mapeia um valor de justify-items/justify-self/align (box alignment) p/ Flex_Align.
@(private="file")
parse_box_align :: proc(v: string) -> Flex_Align {
    switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
    case "baseline", "first baseline": return .Baseline
    case "last baseline": return .LastBaseline
    case "center":                     return .Center
    case "end", "flex-end", "right":   return .End
    case "start", "flex-start", "left": return .Start
    case:                              return .Stretch
    }
}

// Mapeamentos de valor → enum, espelhando os switches de align-items/align-content/
// justify-content. Usados pelos shorthands place-*.
@(private="file")
map_align_items :: proc(v: string) -> Flex_Align {
    switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
    case "flex-start", "start": return .Start
    case "baseline", "first baseline": return .Baseline
    case "last baseline": return .LastBaseline
    case "center":              return .Center
    case "flex-end", "end":     return .End
    }
    return .Stretch
}
@(private="file")
map_justify_content :: proc(v: string) -> Flex_Just {
    switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
    case "center":                   return .Center
    case "flex-end", "end", "right": return .End
    case "space-between":            return .Between
    case "space-around":             return .Around
    case "space-evenly":             return .Evenly
    }
    return .Start
}
@(private="file")
map_align_content :: proc(v: string) -> Flex_Just {
    switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
    case "center":          return .Center
    case "flex-end", "end": return .End
    case "space-between":   return .Between
    case "space-around":    return .Around
    case "space-evenly":    return .Evenly
    }
    return .Start
}

// Detecta margin-left: auto / margin-right: auto (incl. shorthand "margin: 0 auto").
// Devolve por lado — ambos true = centraliza; um só = auto-margin de flex (empurra).
@(private="file")
margins_x_auto :: proc(decls: map[string]string, vars: map[string]string) -> (left, right: bool) {
    is_auto :: proc(s: string) -> bool { return strings.trim_space(s) == "auto" }

    if v, ok := decls["margin"]; ok { // shorthand primeiro (menor especificidade que os lados)
        // split_top_level: `margin: calc(1rem + 4px) auto` são DOIS valores. Com
        // split por espaço viravam quatro e caía no ramo "t r b l", lendo o `auto`
        // no índice errado — a centralização horizontal se perdia. Ver M172.
        toks := split_top_level(resolve_var(v, vars))
        switch len(toks) {
        case 1: left = is_auto(toks[0]);  right = left
        case 2, 3: left = is_auto(toks[1]); right = left       // valor lateral (right=left)
        case 4: right = is_auto(toks[1]);   left = is_auto(toks[3]) // t r b l
        }
    }
    if l, okl := decls["margin-left"];  okl do left  = is_auto(l)
    if r, okr := decls["margin-right"]; okr do right = is_auto(r)
    return
}

// Análogo vertical: margin-top/bottom auto (centra abspos no eixo do bloco quando
// top E bottom estão setados). Shorthand "t r b l" → top=toks[0], bottom=toks[2].
@(private="file")
margins_y_auto :: proc(decls: map[string]string, vars: map[string]string) -> (top, bottom: bool) {
    is_auto :: proc(s: string) -> bool { return strings.trim_space(s) == "auto" }

    if v, ok := decls["margin"]; ok {
        toks := split_top_level(resolve_var(v, vars)) // idem margins_x_auto
        switch len(toks) {
        case 1, 2: top = is_auto(toks[0]); bottom = top
        case 3, 4: top = is_auto(toks[0]); bottom = is_auto(toks[2])
        }
    }
    if v, okt := decls["margin-top"];    okt do top    = is_auto(v)
    if v, okb := decls["margin-bottom"]; okb do bottom = is_auto(v)
    return
}

// Aplica margin-top/right/bottom/left (ou padding-*) individuais.
@(private="file")
apply_side :: proc(box: ^[4]f32, has: ^bool, decls: map[string]string, prefix: string, vars: map[string]string, fs: f32, vw: f32 = 1280, vh: f32 = 720, frac: ^[4]f32 = nil, offb: ^[4]f32 = nil) {
    sides := [4]string{"-top", "-right", "-bottom", "-left"}
    for s, i in sides {
        if v, ok := decls[strings.concatenate({prefix, s}, context.temp_allocator)]; ok {
            if off, pc, k := parse_len_linear(resolve_var(v, vars), fs, vw, vh); k {
                if pc != 0 {
                    if frac != nil { frac[i] = pc; offb[i] = off; box[i] = 0 }
                } else {
                    box[i] = off
                    if frac != nil { frac[i] = 0; offb[i] = 0 }
                }
                if has != nil do has^ = true
            }
        }
    }
}

@(private="file")
// Avalia um calc() de COMPRIMENTO na forma LINEAR `pct * base + px`, porque a base
// da porcentagem (o bloco contenedor) só existe no LAYOUT, não aqui. Antes o
// avaliador chamava parse_len e DESCARTAVA o flag de porcentagem, então `100%`
// virava 1 *pixel*: `calc(100% - 40px)` dava -39 (→0) e `calc(50% + 10px)` dava 10.
// Era o BLANK do openstreetmap (`#map{height:calc(100% - 40px)}` → altura 0).
// Multiplicação/divisão só valem com um lado ESCALAR (spec), então a forma linear
// é fechada sob todos os operadores permitidos.
eval_calc_linear :: proc(expr: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (px: f32, pct: f32, ok: bool) {
    p, c, _, k := eval_calc_num(expr, fs, vw, vh)
    return p, c, k
}

@(private="file")
// Igual ao de cima, mas devolve TAMBÉM se o resultado é um número PURO (sem
// unidade). É essa informação que valida a multiplicação — a spec exige que um
// dos lados de `*` seja escalar. Antes o teste era TEXTUAL (`is_scalar_token`:
// "o pedaço parseia como f64?"), então SÓ um literal contava: qualquer
// parêntese ou `calc()` aninhado do lado direito reprovava, a conta falhava e a
// declaração INTEIRA caía em silêncio. Essa é exatamente a grafia que o
// **Tailwind v4** emite em `space-y-*`
// (`calc(calc(var(--spacing) * 3) * calc(1 - var(--tw-space-y-reverse)))`) e em
// `-translate-x-1/2` (`calc(calc(1 / 2 * 100%) * -1)`, os dois lados
// não-literais) — o espaçamento de listas e a centralização de modal/overlay.
eval_calc_num :: proc(expr: string, fs: f32, vw: f32, vh: f32) -> (px: f32, pct: f32, unitless: bool, ok: bool) {
    s := strings.trim_space(expr)
    if s == "" do return 0, 0, false, false

    if s[0] == '(' && s[len(s) - 1] == ')' {
        depth := 0
        wraps := true
        for i in 0 ..< len(s) {
            if      s[i] == '(' do depth += 1
            else if s[i] == ')' {
                depth -= 1
                if depth == 0 && i < len(s) - 1 { wraps = false; break }
            }
        }
        if wraps do return eval_calc_num(s[1 : len(s) - 1], fs, vw, vh)
    }

    depth := 0
    add_pos := -1; add_ch := byte(0)
    mul_pos := -1; mul_ch := byte(0)
    for i := len(s) - 1; i >= 0; i -= 1 {
        c := s[i]
        if      c == ')' do depth += 1
        else if c == '(' do depth -= 1
        else if depth == 0 && i > 0 {
            // O char anterior SIGNIFICATIVO (pulando espaços) é o que diz se este
            // '+'/'-' é operador binário ou SINAL do número. Olhar só `s[i-1]`
            // fazia `calc(var(--spacing) * -1)` — a forma que o **Tailwind v4 emite
            // p/ toda utilidade negativa** (`-translate-y-1`, `-mt-4`) — ser lido
            // como SUBTRAÇÃO: o lado esquerdo virava `0.25rem *` (multiplicação sem
            // operando), não avaliava, e o calc INTEIRO falhava em silêncio.
            // `k < 0` (só espaço antes) também é contexto unário: `calc( -5px + 2px)`.
            k := i - 1
            for k >= 0 && (s[k] == ' ' || s[k] == '\t' || s[k] == '\n' || s[k] == '\r') do k -= 1
            prev := k >= 0 ? s[k] : byte(0)
            is_after_op := k < 0 || prev == '*' || prev == '/' || prev == '+' || prev == '-'
            if (c == '+' || c == '-') && add_pos < 0 && !is_after_op {
                add_pos = i; add_ch = c
            } else if (c == '*' || c == '/') && mul_pos < 0 {
                mul_pos = i; mul_ch = c
            }
        }
    }

    op_pos := add_pos if add_pos >= 0 else mul_pos
    op_ch  := add_ch  if add_pos >= 0 else mul_ch
    if op_pos > 0 {
        lpx, lpc, lnum, lok := eval_calc_num(s[:op_pos], fs, vw, vh)
        rpx, rpc, rnum, rok := eval_calc_num(s[op_pos + 1:], fs, vw, vh)
        if lok && rok {
            switch op_ch {
            case '+': return lpx + rpx, lpc + rpc, lnum && rnum, true
            case '-': return lpx - rpx, lpc - rpc, lnum && rnum, true
            case '*': // um dos lados precisa ser escalar puro (sem unidade nem %)
                if rnum do return lpx * rpx, lpc * rpx, lnum, true
                if lnum do return rpx * lpx, rpc * lpx, rnum, true
                return 0, 0, false, false
            case '/':
                if rpx == 0 || rpc != 0 do return 0, 0, false, false
                return lpx / rpx, lpc / rpx, lnum, true
            }
        }
        return 0, 0, false, false
    }

    // primário. A ordem importa: um número PURO tem de ser reconhecido ANTES do
    // parse_len (que o devolveria como px, perdendo a informação de escalar).
    if n, k := strconv.parse_f64(s); k do return f32(n), 0, true, true
    // `calc()` aninhado: recursão direta, senão o parse_len avalia mas descarta
    // o "sem unidade" e o `*` de fora reprova um operando legítimo.
    if len(s) > 5 && strings.has_prefix(s, "calc(") && s[len(s) - 1] == ')' {
        return eval_calc_num(s[5 : len(s) - 1], fs, vw, vh)
    }
    // comprimento com unidade (% vira coeficiente)
    if v, is_pct, k := parse_len(s, fs, vw, vh); k {
        if is_pct do return 0, v, false, true
        return v, 0, false, true
    }
    return 0, 0, false, false
}

// Compat: valor escalar em px. Uma porcentagem contribui com seu COEFICIENTE
// (comportamento histórico) — chamadores que precisam da base usam eval_calc_linear.
eval_calc_expr :: proc(expr: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (val: f32, ok: bool) {
    px, pct, k := eval_calc_linear(expr, fs, vw, vh)
    if !k do return 0, false
    return px + pct, true
}

// ── min()/max()/clamp() MISTO: a forma linear CLAMPADA ──────────────────────
// `min(50%, 300px)` não é uma reta: é uma reta com TETO. Enquanto a
// representação era só `frac*base + off`, todo min/max/clamp que misturasse %
// com px era DESCARTADO (a declaração inteira caía). A representação completa é
//
//     clamp(lo, frac*base + off, hi)          lo/hi ABSOLUTOS em px
//
// que cobre exatamente a forma que aparece em site real: UM operando percentual
// (ou calc com %) e os demais absolutos — `min(100%, 1200px)`,
// `clamp(320px, 90%, 1200px)`, `max(50%, 20rem)`. Dois operandos percentuais com
// offsets diferentes são retas que se CRUZAM: aí não há forma fechada e seguimos
// descartando (ver parse_len_clamped).
//
// Zero-value = SEM limite (`has=false`) — obrigatório, porque Computed e Box são
// zerados no reset e um `{lo:0, hi:0}` ativo grudaria toda porcentagem em zero.
Len_Bounds :: struct {
    lo, hi: f32,
    has:    bool,
}

// `max(lo, min(hi, x))` é a ordem do clamp() da spec: com lo > hi, o lo vence.
bounds_apply :: proc(x: f32, b: Len_Bounds) -> f32 {
    if !b.has do return x
    return max(b.lo, min(b.hi, x))
}

// FUNIL: todo sítio de layout que resolve uma porcentagem contra a base passa por
// aqui. É o que garante que o limite de um min()/clamp() misto não seja esquecido
// em algum caminho — a invariante grepável é que `_pct_off` só apareça como
// argumento desta proc.
pct_resolve :: proc(frac, off, base: f32, b: Len_Bounds) -> f32 {
    return bounds_apply(frac * base + off, b)
}

// Como parse_len_linear, mas também devolve os LIMITES quando o valor é um
// `min()/max()/clamp()` que mistura % com absoluto. Sem mistura devolve exatamente
// o que parse_len_linear devolveria (bounds vazio) — por construção, o caminho
// novo só dispara onde HOJE a declaração é jogada fora.
// ⚠️ NÃO cobre `calc(min(50%, 300px) + 10px)`: dentro de calc o min/max ainda passa
// pelo parse_len, que só resolve o caso todo-absoluto.
parse_len_clamped :: proc(value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (px_off: f32, pct: f32, bd: Len_Bounds, ok: bool) {
    plain :: proc(value: string, fs, vw, vh: f32) -> (f32, f32, Len_Bounds, bool) {
        o, p, k := parse_len_linear(value, fs, vw, vh)
        return o, p, {}, k
    }
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    kind := 0 // 1=min 2=max 3=clamp
    if      strings.has_prefix(v, "min(")   do kind = 1
    else if strings.has_prefix(v, "max(")   do kind = 2
    else if strings.has_prefix(v, "clamp(") do kind = 3
    if kind == 0 do return plain(value, fs, vw, vh)

    // o ')' que CASA com o '(' da função tem de ser o último byte (senão é outra
    // coisa, ex. `min(1px,2px) 3px`, e quem decide é o parser de sempre)
    open := strings.index_byte(v, '(')
    depth, close := 0, -1
    for i in open ..< len(v) {
        if      v[i] == '(' do depth += 1
        else if v[i] == ')' { depth -= 1; if depth == 0 { close = i; break } }
    }
    if close != len(v) - 1 do return plain(value, fs, vw, vh)

    // argumentos no topo (vírgulas fora de parênteses)
    offs, fracs: [8]f32
    n := 0
    start, d := 0, 0
    for i := 0; i <= len(v[open + 1:close]); i += 1 {
        inner := v[open + 1:close]
        if i < len(inner) {
            c := inner[i]
            if c == '(' { d += 1; continue }
            if c == ')' { d -= 1; continue }
            if c != ',' || d != 0 do continue
        }
        arg := strings.trim_space(inner[start:i])
        start = i + 1
        if arg == "" || n >= 8 do return 0, 0, {}, false
        o, p, k := parse_len_linear(arg, fs, vw, vh)
        if !k {
            // expressão sem o wrapper `calc()` ("100px - 30px"), que o parse_len aceita
            val, k2 := eval_calc_expr(arg, fs, vw, vh)
            if !k2 do return 0, 0, {}, false
            o, p = val, 0
        }
        offs[n] = o; fracs[n] = p; n += 1
    }
    if n == 0 do return 0, 0, {}, false
    if kind == 3 && n != 3 do return 0, 0, {}, false

    // classifica: quem carrega a % e quem é absoluto
    absv: [8]f32
    nabs := 0
    npct, ipct := 0, -1
    pfrac, poff: f32
    for i in 0 ..< n {
        if fracs[i] != 0 { npct += 1; ipct = i; pfrac = fracs[i]; poff = offs[i] }
        else { absv[nabs] = offs[i]; nabs += 1 }
    }
    // Tudo absoluto: o parse_len já dobra num número só — caminho de sempre.
    if npct == 0 do return plain(value, fs, vw, vh)
    if nabs == 0 {
        // Só porcentagens. Se todas forem fração PURA (sem offset), estão na mesma
        // base e min/max/clamp delas tem forma fechada: o parse_len resolve, e
        // delegar preserva o comportamento anterior bit a bit. (Foi um teste que
        // pegou `clamp(10%, 50%, 90%)` regredindo quando este ramo não existia.)
        todas_puras := true
        for i in 0 ..< n do if offs[i] != 0 do todas_puras = false
        if todas_puras do return plain(value, fs, vw, vh)
        // Com offsets diferentes são retas que se CRUZAM — sem forma fechada.
        // DESCARTA. ⚠️ Não é o comportamento anterior: o parse_len devolvia um
        // número SEM SENTIDO aqui (o ramo de calc misto soma `frac + off` como se
        // a fração fosse px, então `min(calc(50% - 10px), calc(30% + 5px))` virava
        // `min(-9.5, 5.3)` = -9.5px). Declaração descartada é honesto; número
        // inventado não é.
        return 0, 0, {}, false
    }
    if npct > 1 {
        // Vários operandos com %: só há reta única quando TODOS têm offset zero —
        // aí min/max de frações sobre a MESMA base é a menor/maior fração. Com
        // offsets diferentes as retas se cruzam (e clamp nem entra): descarta.
        if kind == 3 do return 0, 0, {}, false
        for i in 0 ..< n do if fracs[i] != 0 && offs[i] != 0 do return 0, 0, {}, false
        best := f32(0)
        first := true
        for i in 0 ..< n do if fracs[i] != 0 {
            if first { best = fracs[i]; first = false }
            else if kind == 1 { best = min(best, fracs[i]) }
            else { best = max(best, fracs[i]) }
        }
        pfrac = best; poff = 0
    }
    lo, hi := -max(f32), max(f32)
    switch kind {
    case 1: for i in 0 ..< nabs do hi = min(hi, absv[i]) // min(): os absolutos são TETO
    case 2: for i in 0 ..< nabs do lo = max(lo, absv[i]) // max(): são PISO
    case 3:
        // clamp(A,B,C) ≡ max(A, min(B,C)). Com exatamente um operando percentual P:
        //   P=A → max(P, min(B,C))  = piso min(B,C)
        //   P=B → max(A, min(P,C))  = piso A, teto C
        //   P=C → max(A, min(B,P))  = piso A, teto B
        switch ipct {
        case 0: lo = min(offs[1], offs[2])
        case 1: lo = offs[0]; hi = offs[2]
        case 2: lo = offs[0]; hi = offs[1]
        }
    }
    return poff, pfrac, Len_Bounds{lo = lo, hi = hi, has = true}, true
}

// Comprimento CSS na forma LINEAR `pct * base + px_off`, que é o que width/height
// precisam p/ suportar `calc(100% - 40px)`: a base só é conhecida no layout.
// px puro → (v, 0); % puro → (0, frac); calc misto → os dois.
parse_len_linear :: proc(value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (px_off: f32, pct: f32, ok: bool) {
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if strings.has_prefix(v, "calc(") && strings.has_suffix(v, ")") {
        return eval_calc_linear(strings.trim_space(v[5 : len(v) - 1]), fs, vw, vh)
    }
    if p, is_pct, k := parse_len(value, fs, vw, vh); k {
        if is_pct do return 0, p, true
        return p, 0, true
    }
    return 0, 0, false
}

// Comprimento CSS -> px (pct=true e valor em fração quando é %).
// Suporta calc(...) via eval_calc_expr. vw/vh usam o viewport padrão (1280×720).
@(private="file")
parse_len :: proc(value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (px: f32, pct: bool, ok: bool) {
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if v == "" || v == "auto" || v == "none" || v == "fit-content" do return 0, false, false
    if v == "0" do return 0, false, true

    // calc(...) — delega a um avaliador recursivo de expressão (respeita
    // precedência e parênteses). Um calc que resolve para porcentagem PURA sai
    // como PORCENTAGEM: antes todo calc era rotulado px, então
    // `translate: calc(calc(1 / 2 * 100%) * -1)` (como o Tailwind v4 escreve
    // `-translate-x-1/2`, a centralização de modal/overlay) deslocava -50 PIXELS
    // em vez de -50% da própria caixa. O número devolvido é o mesmo dos dois
    // jeitos — só o rótulo muda —, então quem ignora o flag não vê diferença.
    // Misto (`calc(100% - 40px)`) continua somado como px: sem a base do bloco
    // contenedor não dá p/ representá-lo aqui (quem precisa usa parse_len_linear).
    if strings.has_prefix(v, "calc(") && strings.has_suffix(v, ")") {
        inner := strings.trim_space(v[5 : len(v) - 1])
        if off, frac, k := eval_calc_linear(inner, fs, vw, vh); k {
            if off == 0 && frac != 0 do return frac, true, true
            return off + frac, false, true
        }
        return 0, false, false
    }

    // min()/max()/clamp() — argumentos são comprimentos ou expressões calc.
    // Todos precisam concordar em ser % ou absolutos (misto, ex. min(50%, 300px),
    // não é resolvível sem a base — falha e a propriedade é ignorada).
    if (strings.has_prefix(v, "min(") || strings.has_prefix(v, "max(") || strings.has_prefix(v, "clamp(")) &&
       strings.has_suffix(v, ")") {
        open := strings.index_byte(v, '(')
        inner := v[open + 1 : len(v) - 1]
        vals := make([dynamic]f32, context.temp_allocator)
        all_pct, any_pct := true, false
        start, depth := 0, 0
        for i := 0; i <= len(inner); i += 1 {
            if i < len(inner) {
                ch := inner[i]
                if ch == '(' { depth += 1; continue }
                if ch == ')' { depth -= 1; continue }
                if ch != ',' || depth != 0 do continue
            }
            arg := strings.trim_space(inner[start:i])
            start = i + 1
            if arg == "" do return 0, false, false
            apx, apct, aok := parse_len(arg, fs, vw, vh)
            if !aok { // expressão sem o wrapper calc(): "100px - 30px"
                apx, aok = eval_calc_expr(arg, fs, vw, vh)
                apct = false
            }
            if !aok do return 0, false, false
            append(&vals, apx)
            if apct { any_pct = true } else { all_pct = false }
        }
        if len(vals) == 0 || (any_pct && !all_pct) do return 0, false, false
        r := vals[0]
        switch {
        case strings.has_prefix(v, "min("): for x in vals[1:] do r = min(r, x)
        case strings.has_prefix(v, "max("): for x in vals[1:] do r = max(r, x)
        case: // clamp(mín, valor, máx) = max(mín, min(valor, máx))
            if len(vals) != 3 do return 0, false, false
            r = max(vals[0], min(vals[1], vals[2]))
        }
        return r, any_pct, true
    }

    // Um scanner de número SÓ, compartilhado com o pacote css (media queries e
    // calc): dígitos, '.', sinal e expoente científico. `3.40282e38px` é o
    // `rounded-full` do Tailwind v4; `3em`/`2ex` continuam unidade porque o
    // expoente exige DÍGITO depois do 'e'.
    end := csspkg.scan_number_end(v, 0, true)
    if end == 0 do return 0, false, false
    n, k := strconv.parse_f64(v[:end])
    if !k do return 0, false, false
    unit := strings.trim_space(v[end:])
    switch unit {
    case "px", "": return f32(n) * g_zoom, false, true
    // Unidades ABSOLUTAS (css-values §5.2). Todas ancoradas em 1in = 96px, que é
    // a definição da spec — não uma medida do monitor. Faltavam TODAS menos `pt`,
    // e a declaração caía em silêncio: `padding: 5mm` virava "sem padding".
    // ⚠️ `pt` era 1.333 (3 casas): 12pt dava 15,996 em vez de 16 EXATO. O fator é
    // 96/72, que em binário não é o mesmo número.
    case "pt":     return f32(n) * (96.0 / 72.0)  * g_zoom, false, true
    case "pc":     return f32(n) * 16             * g_zoom, false, true // 1pc = 12pt
    case "in":     return f32(n) * 96             * g_zoom, false, true
    case "cm":     return f32(n) * (96.0 / 2.54)  * g_zoom, false, true
    case "mm":     return f32(n) * (96.0 / 25.4)  * g_zoom, false, true
    case "q":      return f32(n) * (96.0 / 101.6) * g_zoom, false, true // 1Q = ¼mm
    case "rem":    return f32(n) * rem_px(), false, true // base = font-size da RAIZ (já escalado)
    case "em":     return f32(n) * fs, false, true // fs já vem escalado (herdado)
    // ex = altura do 'x'. Sem métricas reais da fonte aqui, usamos a aproximação
    // padrão de 0.5em (comum em navegadores p/ fontes sem as tabelas). fs já vem
    // escalado (herdado). `ch` fica de fora: depende de font-size-adjust p/ casar
    // com browsers em alguns reftests e não é necessário pelos alvos atuais.
    case "ex":     return f32(n) * fs * 0.5, false, true
    // lh = a line-height COMPUTADA do próprio elemento (CSS Values 4). O Tailwind v4
    // usa em `min-h-lh`/`h-lh` p/ dar a uma caixa a altura de UMA linha (a linha
    // vazia de um bloco de código, por exemplo). `rlh` (line-height da RAIZ) fica de
    // fora de propósito: não rastreamos o valor da raiz aqui e chutá-lo seria pior
    // que a declaração cair.
    case "lh":     return f32(n) * (g_cur_lh_px > 0 ? g_cur_lh_px : fs * 1.3), false, true
    case "%":      return f32(n) / 100, true, true
    // Unidades de VIEWPORT. As variantes small/large/dynamic (`sv*`/`lv*`/`dv*`)
    // existem por causa da barra de URL retrátil do mobile: elas diferem quando o
    // viewport MUDA de tamanho durante a rolagem. Este motor não tem UI de
    // navegador que retraia — então, per css-values-4 §6.1.2, o small, o large e o
    // dynamic viewport são TODOS o mesmo viewport, e `100dvh == 100lvh == 100svh
    // == 100vh`. Não é aproximação: é o que a spec manda quando não há tal UI.
    // `vi`/`vb` são os eixos INLINE/BLOCK; só suportamos `horizontal-tb`, onde
    // inline=horizontal e block=vertical (ver [writing-mode] na lista de props
    // reconhecidas-mas-inertes — quando vertical-* existir, estes dois trocam).
    case "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi":
        return f32(n) * vw / 100, false, true // relativo ao viewport: não escala com o zoom
    case "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb":
        return f32(n) * vh / 100, false, true
    case "vmin", "svmin", "lvmin", "dvmin": return f32(n) * min(vw, vh) / 100, false, true
    case "vmax", "svmax", "lvmax", "dvmax": return f32(n) * max(vw, vh) / 100, false, true
    }
    return 0, false, false
}

// Shorthand de 1-4 valores (margin/padding). % e auto viram 0.
@(private="file")
parse_box4 :: proc(value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> [4]f32 {
    px4, _, _ := parse_box4_linear(value, fs, vw, vh)
    return px4
}

// Como parse_box4, mas devolve também a fração de PORCENTAGEM e o offset por lado
// (forma linear `frac*larguraCB + off`). A base só existe no layout, então quem
// chama guarda os três e resolve lá.
parse_box4_linear :: proc(value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> (px4: [4]f32, frac4: [4]f32, off4: [4]f32) {
    // split_top_level (e não strings.fields): `padding: calc(10% - 20px)` tem ESPAÇOS
    // dentro dos parênteses e viraria 3 tokens quebrados.
    toks := split_top_level(value)
    vals, fracs, offs: [4]f32
    n := min(len(toks), 4)
    for i in 0 ..< n {
        if off, pc, ok := parse_len_linear(toks[i], fs, vw, vh); ok {
            if pc != 0 { fracs[i] = pc; offs[i] = off } else { vals[i] = off }
        }
    }
    pick :: proc(v: [4]f32, cnt: int) -> [4]f32 {
        switch cnt {
        case 1: return {v[0], v[0], v[0], v[0]}
        case 2: return {v[0], v[1], v[0], v[1]}
        case 3: return {v[0], v[1], v[2], v[1]}
        }
        return {v[0], v[1], v[2], v[3]}
    }
    c := len(toks)
    return pick(vals, c), pick(fracs, c), pick(offs, c)
}

// Split por ',' no nível SUPERIOR: `url(a), linear-gradient(x, y)` são DUAS
// camadas, e as vírgulas de dentro dos parênteses não contam.
@(private="file")
bg_split_layers :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',': if depth == 0 { append(&out, s[start:i]); start = i + 1 }
        }
    }
    append(&out, s[start:])
    return out[:]
}

// `background-image` / `background` com N camadas (ver Bg_Layer). A camada 0 vai
// p/ os campos diretos do Computed; as demais p/ comp.bg_extra. `shorthand`
// liga a leitura de cor/size/repeat, que só existem no `background`.
//
// ⚠️ a COR do shorthand só pode aparecer na ÚLTIMA camada (spec) e vale p/ o
// elemento todo — por isso é aplicada ao comp, não à camada.
@(private="file")
// Devolve `found_color` = o shorthand trouxe uma COR. Quem chama usa isso para
// aplicar a regra de reset do shorthand (ver o call-site de `background`).
apply_bg_layers :: proc(comp: ^Computed, value: string, shorthand: bool) -> (found_color: bool) {
    parts := bg_split_layers(value)
    // `background: red` (sem imagem) não é uma lista de camadas: mantém o
    // caminho antigo e NÃO limpa bg_extra de uma regra anterior.
    extra := make([dynamic]Bg_Layer, 0, max(0, len(parts) - 1), context.temp_allocator)
    for part, i in parts {
        lay: Bg_Layer
        lay.repeat = true
        lay.size = .Auto
        if g, k := csspkg.parse_gradient(part); k {
            lay.grad = g
        } else if u := csspkg.extract_url(part); u != "" {
            lay.img = strings.clone(u, context.temp_allocator) // resolvida na Box
        }
        if shorthand {
            lo := strings.to_lower(part, context.temp_allocator)
            if      strings.contains(lo, "cover")   do lay.size = .Cover
            else if strings.contains(lo, "contain") do lay.size = .Contain
            if strings.contains(lo, "no-repeat") do lay.repeat = false
            // cor: tenta o valor inteiro e, se não for cor, token a token
            // A COR do shorthand mora só na ÚLTIMA camada (spec: `<final-bg-layer>`)
            // e PODE conviver com imagem/gradiente ali — `background: #00f url(x)`
            // define os dois. Antes só procurávamos cor em camada SEM imagem, e a cor
            // desse idioma sumia calada.
            if i == len(parts) - 1 {
                if rgb, k := parse_color_cc(strings.trim_space(part), comp.color); k {
                    comp.bg = rgb; comp.has_bg = true; found_color = true
                } else {
                    // ⚠️ split_top_level, NÃO strings.fields: cor funcional tem espaço
                    // DENTRO dos parênteses (`rgb(0 128 0)`) e o split por espaço a
                    // destruiria — é o defeito grepável do M172.
                    for tok in split_top_level(part) {
                        if c, kk := parse_color_cc(tok, comp.color); kk { comp.bg = c; comp.has_bg = true; found_color = true; break }
                    }
                }
            }
        }
        if i == 0 {
            if lay.grad.active do comp.grad = lay.grad
            if lay.img != ""   do comp.bg_img = lay.img
            if shorthand {
                comp.bg_size = lay.size
                comp.bg_repeat = lay.repeat
            }
        } else if lay.grad.active || lay.img != "" {
            append(&extra, lay)
        }
    }
    if len(extra) > 0 do comp.bg_extra = extra[:]
    return
}

// background-position: palavras-chave (left/center/right, top/center/bottom) ou
// porcentagens → frações 0..1. "center" sozinho = 0.5,0.5.
@(private="file")
parse_bg_position :: proc(value: string, vw: f32 = 1280, vh: f32 = 720) -> (px, py: f32) {
    // split_top_level: `calc(100% - 10px) center` são DOIS valores. Com split por
    // espaço viravam quatro e o `center` caía no índice errado — isto é, no EIXO
    // errado. Ver M172. (Se o calc em si resolve é outra questão, do parse_len.)
    toks := split_top_level(strings.to_lower(value, context.temp_allocator))
    if len(toks) == 1 && toks[0] == "center" do return 0.5, 0.5
    for tok, i in toks {
        switch tok {
        case "left":   px = 0
        case "right":  px = 1
        case "top":    py = 0
        case "bottom": py = 1
        case "center": if i == 0 { px = 0.5 } else { py = 0.5 }
        case:
            if p, pct, k := parse_len(tok, 16, vw, vh); k && pct {
                if i == 0 { px = p } else { py = p }
            }
        }
    }
    return
}

// background-position-x/y: um único eixo. `is_y` escolhe o eixo p/ keywords
// ambíguas (center) e porcentagens. Devolve fração 0..1 (default 0 = início).
@(private="file")
parse_bg_position_axis :: proc(value: string, is_y: bool, vw: f32 = 1280, vh: f32 = 720) -> f32 {
    t := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    switch t {
    case "left":   return 0
    case "right":  return 1
    case "top":    return 0
    case "bottom": return 1
    case "center": return 0.5
    }
    if p, pct, k := parse_len(t, 16, vw, vh); k && pct do return p
    return 0
}

// "1px solid #ccc" -> (largura, cor, achou_cor). cur = cor computada (p/ currentColor).
@(private="file")
parse_border :: proc(value: string, fs: f32, cur: u32 = 0, vw: f32 = 1280, vh: f32 = 720) -> (w: f32, c: u32, has_col: bool, ok: bool) {
    w = 1
    found := false
    // split_top_level, não strings.fields: uma cor FUNCIONAL tem espaços dentro
    // dos parênteses (`oklch(0.968 0.007 247.896)`, `rgb(241 245 249)`) e o split
    // ingênuo a picava em tokens inválidos → cor descartada. Ver parse_border_side.
    for tok in split_top_level(value) {
        if px, _, k := parse_len(tok, fs, vw, vh); k { w = px; found = true; continue }
        // `transparent` não é aceito por named_color (é ausência de cor); numa
        // BORDA, porém, a largura conta p/ o layout mas o traço deve ser
        // invisível. O esquema de cor (byte alto = alpha, 0 = opaco) não faz
        // alpha exato 0, mas byte=1 dá ~0,4% de opacidade — imperceptível.
        if strings.equal_fold(tok, "transparent") { c = COLOR_TRANSPARENT; has_col = true; found = true; continue }
        if col, k := parse_color_cc(tok, cur); k { c = col; has_col = true; found = true; continue }
        if tok == "none" do return 0, 0, false, false
    }
    return w, c, has_col, found
}

// Palavra-chave de estilo de borda (não pintamos os tracejados; só importa
// distinguir none/hidden, que zeram o lado).
@(private="file")
is_border_style_kw :: proc(s: string) -> (style: bool, none: bool) {
    switch s {
    case "none", "hidden":                       return true, true
    case "solid", "dashed", "dotted", "double",
         "groove", "ridge", "inset", "outset":   return true, false
    }
    return false, false
}

// Comprimento de borda: thin/medium/thick ou um <length>.
@(private="file")
border_width_token :: proc(tok: string, fs, vw, vh: f32) -> (f32, bool) {
    switch tok {
    case "thin":   return 1, true
    case "medium": return 3, true
    case "thick":  return 5, true
    }
    if px, pct, k := parse_len(tok, fs, vw, vh); k && !pct do return px, true
    return 0, false
}

// Um lado de borda ("1px solid #ccc" / "none" / "medium dashed red").
// has_w/has_col indicam o que foi especificado; none = estilo none/hidden.
// ⚠️ `has_style` foi ACRESCENTADO à assinatura de propósito (o truque do M201):
// mudar a assinatura faz o compilador enumerar os call-sites, e cada um tem de
// decidir o que fazer com "o autor declarou um estilo?" — que é a informação que
// faltava para dois defeitos opostos: largura omitida virava 0 (e não `medium`)
// e estilo omitido PINTAVA (quando deveria ser `none`).
@(private="file")
parse_border_side :: proc(value: string, cur: u32, fs, vw, vh: f32) -> (w: f32, has_w: bool, c: u32, has_col: bool, none: bool, has_style: bool) {
    // ⚠️ split_top_level (agrupa parênteses), NÃO strings.fields: o Tailwind v4
    // escreve TODA cor como `oklch(L C H)` e a sintaxe moderna de rgb/hsl também
    // separa os canais por espaço — fatiar por espaço mata a cor e a borda cai no
    // fallback currentColor (borda preta em card branco). Ver o teste do M172.
    for tok in split_top_level(strings.to_lower(value, context.temp_allocator)) {
        if st, nn := is_border_style_kw(tok); st { has_style = true; if nn do none = true; continue }
        if px, k := border_width_token(tok, fs, vw, vh); k { w = px; has_w = true; continue }
        // `transparent`: largura conta p/ o layout, mas o traço é invisível.
        // named_color rejeita transparent; byte alto de alpha = 1 → ~0,4% (o
        // esquema de cor não faz alpha exato 0). Ver parse_border (outline).
        if tok == "transparent" { c = COLOR_TRANSPARENT; has_col = true; continue }
        if col, k := parse_color_cc(tok, cur); k { c = col; has_col = true; continue }
    }
    return
}

// border-width em 1-4 valores (thin/medium/thick + lengths) → [4] t r b l.
@(private="file")
parse_border_width4 :: proc(value: string, fs, vw, vh: f32) -> [4]f32 {
    // agrupa parênteses: `calc(1px + 2px)` é UM valor, não três.
    toks := split_top_level(strings.to_lower(value, context.temp_allocator))
    vals: [4]f32
    for i in 0 ..< min(len(toks), 4) {
        if px, ok := border_width_token(toks[i], fs, vw, vh); ok do vals[i] = px
    }
    switch len(toks) {
    case 1: return {vals[0], vals[0], vals[0], vals[0]}
    case 2: return {vals[0], vals[1], vals[0], vals[1]}
    case 3: return {vals[0], vals[1], vals[2], vals[1]}
    case:   return {vals[0], vals[1], vals[2], vals[3]}
    }
}

// Aplica todas as propriedades de borda (shorthand, por lado, width/color/
// style e seus longhands por lado). Ordem: mais geral → mais específico, para
// aproximar a cascata sem a ordem de origem (que o mapa de decls não guarda).

// 1-4 valores no padrão CSS (t / t-r / t-r-b / t-r-b-l), via um conversor por
// token. `ok=false` num token descarta a lista inteira (declaração inválida).
@(private="file")
bimg_quad :: proc(
    v: string, conv: proc(tok: string, out: ^f32, flag: ^bool, kind: ^Bimg_WKind) -> bool,
    out: ^[4]f32, flags: ^[4]bool, kinds: ^[4]Bimg_WKind,
) -> bool {
    toks := split_top_level(v)
    if len(toks) == 0 || len(toks) > 4 do return false
    val:  [4]f32
    flg:  [4]bool
    knd:  [4]Bimg_WKind
    for t, i in toks {
        if !conv(t, &val[i], &flg[i], &knd[i]) do return false
    }
    // t r b l a partir de 1..4 valores
    // ⚠️ literal composto indexado por VARIÁVEL tem de virar variável antes
    // (`Cannot index a constant` — a mesma armadilha do @(rodata) dos geradores).
    table := [4][4]int{ {0,0,0,0}, {0,1,0,1}, {0,1,2,1}, {0,1,2,3} }
    idx := table[len(toks) - 1]
    for i in 0 ..< 4 {
        if out   != nil do out[i]   = val[idx[i]]
        if flags != nil do flags[i] = flg[idx[i]]
        if kinds != nil do kinds[i] = knd[idx[i]]
    }
    return true
}

// <number> | <percentage> — border-image-slice
@(private="file")
bimg_conv_slice :: proc(tok: string, out: ^f32, pct: ^bool, _: ^Bimg_WKind) -> bool {
    t := strings.trim_space(tok)
    if strings.has_suffix(t, "%") {
        if n, k := strconv.parse_f64(t[:len(t) - 1]); k && n >= 0 { out^ = f32(n); pct^ = true; return true }
        return false
    }
    if n, k := strconv.parse_f64(t); k && n >= 0 { out^ = f32(n); pct^ = false; return true }
    return false
}

// <length> | <percentage> | <number> | auto — border-image-width
@(private="file")
bimg_conv_width :: proc(tok: string, out: ^f32, _: ^bool, kind: ^Bimg_WKind) -> bool {
    t := strings.trim_space(tok)
    if strings.equal_fold(t, "auto") { kind^ = .Auto; return true }
    if strings.has_suffix(t, "%") {
        if n, k := strconv.parse_f64(t[:len(t) - 1]); k && n >= 0 { out^ = f32(n); kind^ = .Pct; return true }
        return false
    }
    if n, k := strconv.parse_f64(t); k && n >= 0 { out^ = f32(n); kind^ = .Number; return true } // número PURO = múltiplo da border-width
    if px, p, k := parse_len(t, g_bimg_fs, g_bimg_vw, g_bimg_vh); k && !p && px >= 0 { out^ = px; kind^ = .Len; return true }
    return false
}

// <length> | <number> — border-image-outset (número = múltiplo da border-width)
@(private="file")
bimg_conv_outset :: proc(tok: string, out: ^f32, num: ^bool, _: ^Bimg_WKind) -> bool {
    t := strings.trim_space(tok)
    if n, k := strconv.parse_f64(t); k && n >= 0 { out^ = f32(n); num^ = true; return true }
    if px, p, k := parse_len(t, g_bimg_fs, g_bimg_vw, g_bimg_vh); k && !p && px >= 0 { out^ = px; num^ = false; return true }
    return false
}

// ⚠️ `parse_len` precisa de fs/vw/vh e a assinatura do conversor não os carrega.
// São thread_local porque o runner de teste monta 16 páginas ao mesmo tempo — a
// armadilha do M192/M216, que já custou SEGFAULT intermitente neste pacote.
@(private="file", thread_local)
g_bimg_fs, g_bimg_vw, g_bimg_vh: f32

@(private="file")
bimg_repeat_kw :: proc(t: string) -> (Bimg_Repeat, bool) {
    switch strings.to_lower(strings.trim_space(t), context.temp_allocator) {
    case "stretch": return .Stretch, true
    case "repeat":  return .Repeat,  true
    case "round":   return .Round,   true
    case "space":   return .Space,   true
    }
    return .Stretch, false
}

// `border-image: <source> || <slice> [/ <width> [/ <outset>]] || <repeat>`
@(private="file")
bimg_shorthand :: proc(bi: ^Border_Image, v: string) {
    // as 3 partes são separadas por '/' de TOPO — `url(a/b)` e `linear-gradient(...)`
    // têm barra DENTRO dos parênteses e não podem cortar aqui
    parts := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(v) {
        switch v[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case '/': if depth == 0 { append(&parts, v[start:i]); start = i + 1 }
        }
    }
    append(&parts, v[start:])

    // ⚠️ A repetição é `||` no TOPO da gramática, então pode aparecer em
    // qualquer uma das 3 partes — inclusive DEPOIS do outset
    // (`border-image: url(x) 20 / 12px / 4px round`, que o Chrome aceita).
    // Retirá-la de todas as partes ANTES é o que evita que ela envenene a lista
    // de números da parte em que caiu (foi o teste que pegou isto).
    rep := make([dynamic]Bimg_Repeat, context.temp_allocator)
    for p, i in parts {
        keep := make([dynamic]string, context.temp_allocator)
        for tok in split_top_level(p) {
            if r, k := bimg_repeat_kw(tok); k { append(&rep, r); continue }
            append(&keep, tok)
        }
        parts[i] = strings.join(keep[:], " ", context.temp_allocator)
    }

    // parte 0: fonte, fatia e `fill` misturados — roteia por VALOR, não por posição
    slice_toks := make([dynamic]string, context.temp_allocator)
    for tok in split_top_level(parts[0]) {
        lo := strings.to_lower(strings.trim_space(tok), context.temp_allocator)
        if lo == "none" { bi.src = ""; bi.grad = ""; continue }
        if lo == "fill" { bi.fill = true; continue }
        if u := csspkg.extract_url(tok); u != "" { bi.src = strings.clone(u, context.temp_allocator); continue }
        if strings.contains(lo, "gradient(") { bi.grad = strings.clone(strings.trim_space(tok), context.temp_allocator); continue }
        append(&slice_toks, tok)
    }
    if len(slice_toks) > 0 {
        j := strings.join(slice_toks[:], " ", context.temp_allocator)
        bimg_quad(j, bimg_conv_slice, &bi.slice, &bi.slice_pct, nil)
    }
    if len(rep) > 0 {
        bi.repeat[0] = rep[0]
        bi.repeat[1] = len(rep) > 1 ? rep[1] : rep[0]
    }
    if len(parts) > 1 do bimg_quad(parts[1], bimg_conv_width,  &bi.width,  nil,             &bi.wkind)
    if len(parts) > 2 do bimg_quad(parts[2], bimg_conv_outset, &bi.outset, &bi.outset_num,  nil)
}

// Os 5 longhands + o shorthand. Só monta a struct se ALGUMA das props aparecer —
// página sem border-image não paga nada.
@(private="file")
apply_border_image :: proc(comp: ^Computed, decls: map[string]string, vars: map[string]string, fs, vw, vh: f32) {
    PROPS :: []string{
        "border-image", "border-image-source", "border-image-slice",
        "border-image-width", "border-image-outset", "border-image-repeat",
        "-webkit-border-image",
    }
    any := false
    for p in PROPS do if p in decls { any = true; break }
    if !any do return
    g_bimg_fs = fs; g_bimg_vw = vw; g_bimg_vh = vh

    bi := bimg_initial()
    // shorthand ANTES dos longhands: na mesma regra o longhand explícito vence
    // (o `wins` guarda spec/ordem da REGRA, não por declaração — lote 14/15/22).
    if v, ok := decls["-webkit-border-image"]; ok do bimg_shorthand(&bi, resolve_var(v, vars))
    if v, ok := decls["border-image"];         ok do bimg_shorthand(&bi, resolve_var(v, vars))

    if v, ok := decls["border-image-source"]; ok {
        rv := strings.trim_space(resolve_var(v, vars))
        lo := strings.to_lower(rv, context.temp_allocator)
        bi.src = ""; bi.grad = ""
        if u := csspkg.extract_url(rv); u != "" do bi.src = strings.clone(u, context.temp_allocator)
        else if strings.contains(lo, "gradient(") do bi.grad = strings.clone(rv, context.temp_allocator)
    }
    if v, ok := decls["border-image-slice"]; ok {
        rv := resolve_var(v, vars)
        lo := strings.to_lower(rv, context.temp_allocator)
        if strings.contains(lo, "fill") {
            bi.fill = true
            sem_fill, _ := strings.replace_all(lo, "fill", "", context.temp_allocator)
            rv = strings.trim_space(sem_fill)
        }
        bimg_quad(rv, bimg_conv_slice, &bi.slice, &bi.slice_pct, nil)
    }
    if v, ok := decls["border-image-width"];  ok do bimg_quad(resolve_var(v, vars), bimg_conv_width,  &bi.width,  nil,            &bi.wkind)
    if v, ok := decls["border-image-outset"]; ok do bimg_quad(resolve_var(v, vars), bimg_conv_outset, &bi.outset, &bi.outset_num, nil)
    if v, ok := decls["border-image-repeat"]; ok {
        toks := split_top_level(resolve_var(v, vars))
        if len(toks) >= 1 {
            if r, k := bimg_repeat_kw(toks[0]); k {
                bi.repeat[0] = r
                bi.repeat[1] = r
                if len(toks) > 1 { if r2, k2 := bimg_repeat_kw(toks[1]); k2 do bi.repeat[1] = r2 }
            }
        }
    }
    // sem fonte não há o que pintar — a borda normal continua valendo (spec)
    bi.active = bi.src != "" || bi.grad != ""
    comp.bimg = bi
}

@(private="file")
apply_border_props :: proc(comp: ^Computed, decls: map[string]string, vars: map[string]string, fs, vw, vh: f32) {
    apply_border_image(comp, decls, vars, fs, vw, vh)
    Side :: struct { name: string, idx: int }
    sides := [4]Side{ {"top", 0}, {"right", 1}, {"bottom", 2}, {"left", 3} }

    // Rastreio por lado, p/ a regra da LARGURA OMITIDA (css-backgrounds §4.2:
    // border-width inicial = `medium` = 3px, não 0). Sem isto, `border: solid red`
    // e `border-style: solid` davam borda de ZERO — some da tela.
    w_set:    [4]bool // o autor declarou uma largura para este lado?
    style_on: [4]bool // …e um estilo VISÍVEL (nem omitido, nem none/hidden)?

    // 1. shorthand `border`: aplica aos 4 lados
    if v, ok := decls["border"]; ok {
        w, hw, c, hc, none, hs := parse_border_side(resolve_var(v, vars), comp.color, fs, vw, vh)
        for s in 0 ..< 4 {
            if hw { comp.border_w[s] = w; w_set[s] = true }
            if hc do comp.border_c[s] = c
            // estilo OMITIDO no shorthand volta ao inicial, que é `none` → não
            // pinta (é o que o Chrome faz com `border: 1px red`). Antes qualquer
            // shorthand sem a palavra de estilo acendia a borda.
            comp.border_style_none[s] = none || !hs
            style_on[s] = hs && !none
        }
        comp.has_border = true
    }
    // 2. shorthands por lado: border-top / border-right / …
    for sd in sides {
        if v, ok := decls[strings.concatenate({"border-", sd.name}, context.temp_allocator)]; ok {
            w, hw, c, hc, none, hs := parse_border_side(resolve_var(v, vars), comp.color, fs, vw, vh)
            if hw { comp.border_w[sd.idx] = w; w_set[sd.idx] = true }
            if hc do comp.border_c[sd.idx] = c
            comp.border_style_none[sd.idx] = none || !hs
            style_on[sd.idx] = hs && !none
            comp.has_border = true
        }
    }
    // 3. longhands box4
    if v, ok := decls["border-width"]; ok {
        comp.border_w = parse_border_width4(resolve_var(v, vars), fs, vw, vh); comp.has_border = true
        w_set = {true, true, true, true}
    }
    if v, ok := decls["border-color"]; ok {
        // 1-4 valores, mas cada valor pode ser FUNCIONAL com espaços dentro:
        // `border-color: oklch(0.968 0.007 247.896)` são 1 valor, não 3.
        toks := split_top_level(resolve_var(v, vars))
        cs: [4]u32
        any := false
        for i in 0 ..< min(len(toks), 4) do if c, k := parse_color_cc(toks[i], comp.color); k { cs[i] = c; any = true }
        if any {
            switch len(toks) {
            case 1: comp.border_c = {cs[0], cs[0], cs[0], cs[0]}
            case 2: comp.border_c = {cs[0], cs[1], cs[0], cs[1]}
            case 3: comp.border_c = {cs[0], cs[1], cs[2], cs[1]}
            case:   comp.border_c = {cs[0], cs[1], cs[2], cs[3]}
            }
            comp.has_border = true
        }
    }
    if v, ok := decls["border-style"]; ok {
        toks := strings.fields(strings.to_lower(resolve_var(v, vars), context.temp_allocator), context.temp_allocator)
        ns: [4]bool // este lado é none/hidden?
        on: [4]bool // …ou um estilo VISÍVEL (p/ a largura `medium`)?
        for i in 0 ..< min(len(toks), 4) {
            st, nn := is_border_style_kw(toks[i])
            if nn do ns[i] = true
            if st && !nn do on[i] = true
        }
        // ⚠️ literal composto indexado por VARIÁVEL tem de virar variável antes
        // (`Cannot index a constant` — a mesma armadilha do bimg_quad).
        tabela := [4][4]int{ {0,0,0,0}, {0,1,0,1}, {0,1,2,1}, {0,1,2,3} }
        idx := tabela[min(max(len(toks), 1), 4) - 1]
        for i in 0 ..< 4 {
            comp.border_style_none[i] = ns[idx[i]]
            style_on[i] = on[idx[i]]
        }
    }
    // 4. longhands por lado
    for sd in sides {
        if v, ok := decls[strings.concatenate({"border-", sd.name, "-width"}, context.temp_allocator)]; ok {
            if px, k := border_width_token(strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator), fs, vw, vh); k {
                comp.border_w[sd.idx] = px; comp.has_border = true
                w_set[sd.idx] = true
            }
        }
        if v, ok := decls[strings.concatenate({"border-", sd.name, "-color"}, context.temp_allocator)]; ok {
            if c, k := parse_color_cc(resolve_var(v, vars), comp.color); k { comp.border_c[sd.idx] = c; comp.has_border = true }
        }
        if v, ok := decls[strings.concatenate({"border-", sd.name, "-style"}, context.temp_allocator)]; ok {
            st, nn := is_border_style_kw(strings.to_lower(strings.trim_space(v), context.temp_allocator))
            comp.border_style_none[sd.idx] = nn
            style_on[sd.idx] = st && !nn
        }
    }
    // LARGURA OMITIDA = `medium` (3px). Só onde o autor pediu um estilo visível e
    // não disse largura NENHUMA — e só se não houver largura vinda de antes (o UA
    // dá borda a input/button, e o estilo do autor não deve mexer nela).
    for i in 0 ..< 4 {
        if style_on[i] && !w_set[i] && comp.border_w[i] == 0 {
            comp.border_w[i] = 3
            comp.has_border = true
        }
    }
    if v, ok := decls["border-collapse"]; ok {
        comp.border_collapse = strings.trim_space(v) == "collapse"
    }
    if v, ok := decls["table-layout"]; ok {
        comp.table_fixed = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "fixed")
    }
    if v, ok := decls["empty-cells"]; ok {
        comp.empty_cells_hide = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "hide")
    }
    if v, ok := decls["caption-side"]; ok {
        comp.caption_side_bottom = strings.equal_fold(strings.trim_space(resolve_var(v, vars)), "bottom")
    }
}

// Aplica border-radius (shorthand 1-4 + eixo "/") e os 4 longhands por canto
// (tl tr br bl). O eixo vertical após '/' é ignorado (usa o horizontal).
@(private="file")
apply_border_radius :: proc(comp: ^Computed, decls: map[string]string, vars: map[string]string, fs, vw, vh: f32) {
    if v, ok := decls["border-radius"]; ok {
        h := resolve_var(v, vars)
        if slash := strings.index_byte(h, '/'); slash >= 0 do h = h[:slash] // ignora raio vertical
        toks := split_top_level(h) // não strings.fields: `calc(1px + 2px)` tem espaço dentro
        r: [4]f32; pct: [4]bool
        for i in 0 ..< min(len(toks), 4) {
            if px, p, k := parse_len(toks[i], fs, vw, vh); k { r[i] = px; pct[i] = p }
        }
        switch len(toks) {
        case 1: comp.border_radius = {r[0], r[0], r[0], r[0]}; comp.border_radius_pct = {pct[0], pct[0], pct[0], pct[0]}
        case 2: comp.border_radius = {r[0], r[1], r[0], r[1]}; comp.border_radius_pct = {pct[0], pct[1], pct[0], pct[1]}
        case 3: comp.border_radius = {r[0], r[1], r[2], r[1]}; comp.border_radius_pct = {pct[0], pct[1], pct[2], pct[1]}
        case:   comp.border_radius = {r[0], r[1], r[2], r[3]}; comp.border_radius_pct = {pct[0], pct[1], pct[2], pct[3]}
        }
    }
    Corner :: struct { name: string, idx: int }
    corners := [4]Corner{ {"top-left", 0}, {"top-right", 1}, {"bottom-right", 2}, {"bottom-left", 3} }
    for cn in corners {
        if v, ok := decls[strings.concatenate({"border-", cn.name, "-radius"}, context.temp_allocator)]; ok {
            h := resolve_var(v, vars)
            toks := split_top_level(h) // "x y" → usa x (split_top_level pelo calc)
            if len(toks) > 0 {
                if px, p, k := parse_len(toks[0], fs, vw, vh); k { comp.border_radius[cn.idx] = px; comp.border_radius_pct[cn.idx] = p }
            }
        }
    }
}

// Palavra-chave de list-style-type → enum. ok=false se não for um tipo
// reconhecido (p/ o shorthand ignorar position/image).
@(private="file")
parse_list_style_type :: proc(tok: string) -> (List_Style, bool) {
    switch strings.to_lower(strings.trim_space(tok), context.temp_allocator) {
    case "none":                 return .None, true
    case "disc":                 return .Disc, true
    case "circle":               return .Circle, true
    case "square":               return .Square, true
    case "decimal":              return .Decimal, true
    case "decimal-leading-zero": return .Decimal_Zero, true
    case "lower-alpha", "lower-latin": return .Lower_Alpha, true
    case "upper-alpha", "upper-latin": return .Upper_Alpha, true
    case "lower-roman":          return .Lower_Roman, true
    case "upper-roman":          return .Upper_Roman, true
    }
    return .Auto, false
}

// Peso de fonte a partir de UM token (`bold`, `700`, `450`, `bolder`…). ok=false
// para token que não é peso — é o que deixa o shorthand `font` ROTEAR os tokens
// antes do tamanho, e o que faz valor inválido manter o peso herdado.
//
// Guarda o NÚMERO (o degrau da face embutida é do `fw_class`, no layout).
// `base` = peso do PAI, p/ os relativos (Fonts 4 §2.2, tabela de bolder/lighter).
// Antes `bolder` valia 700 fixo e `lighter` era ignorado.
@(private="file")
font_weight_token :: proc(tok: string, base: Font_Weight) -> (Font_Weight, bool) {
    switch tok {
    case "normal": return FW_NORMAL, true
    case "bold":   return FW_BOLD, true
    case "bolder":
        b := fw_css(base)
        switch {
        case b < 350: return 400, true
        case b < 550: return 700, true
        case b < 900: return 900, true
        }
        return Font_Weight(b), true
    case "lighter":
        b := fw_css(base)
        switch {
        case b < 100: return Font_Weight(b), true
        case b < 550: return 100, true
        case b < 750: return 400, true
        }
        return 700, true
    }
    // <number [1,1000]> (Fonts 4 aceita qualquer número, não só as centenas:
    // `font-weight: 450` é comum em fonte variável). Sem unidade — `12px` não é peso.
    if len(tok) == 0 || !(tok[0] >= '0' && tok[0] <= '9' || tok[0] == '.') do return 0, false
    n, ok := strconv.parse_f64(tok)
    if !ok || n < 1 || n > 1000 do return 0, false
    return Font_Weight(n + 0.5), true
}

// Este token do shorthand `font` é o TAMANHO? Só conta com UNIDADE (ou palavra-
// chave de tamanho) — assim `700`/`400` continuam sendo peso, não tamanho.
@(private="file")
is_font_size_token :: proc(t: string) -> bool {
    switch t {
    case "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
         "xxx-large", "larger", "smaller":
        return true
    }
    if len(t) == 0 do return false
    if !(t[0] >= '0' && t[0] <= '9' || t[0] == '.' || t[0] == '+' || t[0] == '-') do return false
    end := csspkg.scan_number_end(t, 0, true)
    return end > 0 && end < len(t) // sobrou unidade depois do número
}

// line-height: número puro = multiplicador; comprimento (px/rem/em/calc) = /font-size; % = /100.
@(private="file")
parse_line_height :: proc(value: string, fs: f32) -> f32 {
    s := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if s == "" || s == "normal" do return 1.3
    // Número PURO = multiplicador (o único caso que não é comprimento).
    if n, ok := strconv.parse_f64(s); ok do return f32(n)
    // calc(): a resposta depende de o resultado ter UNIDADE, e só o avaliador sabe.
    // `calc(1.75 / 1.125)` é uma RAZÃO — é assim que o Tailwind v4 define
    // `--text-lg--line-height` e afins —, enquanto `calc(0.25rem * 6)` é COMPRIMENTO.
    // Mandar os dois pelo parse_len (que devolve px) dividia a RAZÃO pela fonte:
    // 1.5555/16 = 0.097, linha colapsada. Isto passou pelo WPT e pelos unitários
    // verdes; quem pegou foi o `--imgdiff` do site real (1,15 → 2,43).
    if strings.has_prefix(s, "calc(") && strings.has_suffix(s, ")") {
        if off, frac, unitless, k := eval_calc_num(s[5 : len(s) - 1], fs, 1280, 720); k {
            if unitless  do return off            // razão pura
            if frac != 0 do return frac           // % (parse_len já devolve fração)
            return fs > 0 ? off / fs : 1.3        // comprimento absoluto
        }
        return 1.3
    }
    // Todo o resto é <length-percentage> e vai pelo parse_len — que conhece calc(),
    // todas as unidades e o zoom. Guardamos SEMPRE como multiplicador, então um
    // comprimento absoluto vira px/font-size.
    //
    // Antes esta função tinha um scanner de número PRÓPRIO que exigia dígito no
    // 1º byte: `line-height: calc(var(--spacing) * 6)` — a grafia que o Tailwind v4
    // emite p/ `leading-6` e p/ o modificador de `text-[13px]/6` — caía no default
    // 1.3 EM SILÊNCIO. Era o bloco de código do tailwindcss.com com as linhas
    // apertadas (13px × 1.3 = 17, contra os 24 do Chrome). E `rem` estava errado:
    // era tratado como múltiplo da fonte (1.5rem virava 1.5×), quando é comprimento
    // ABSOLUTO relativo à raiz — justamente o que `calc(0.25rem * 6)` produz.
    if fs > 0 {
        if px, pct, ok := parse_len(s, fs); ok {
            if pct do return px          // parse_len já devolve % como fração
            return px / fs
        }
    }
    return 1.3
}

// aspect-ratio: "<w> / <h>" ou "<n>" (razão w/h). Ignora a palavra 'auto'
// (pode vir sozinha = desliga, ou "auto <ratio>" = usa o ratio). ok=false se
// não houver razão numérica válida (ou se for 0/negativa).
@(private)
parse_aspect_ratio :: proc(value: string) -> (f32, bool) {
    s := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if s == "" || s == "auto" do return 0, false
    // remove um 'auto' opcional (sintaxe "auto <ratio>" / "<ratio> auto")
    s = strings.trim_space(strings.trim_prefix(s, "auto"))
    if slash := strings.index_byte(s, '/'); slash >= 0 {
        w, kw := strconv.parse_f64(strings.trim_space(s[:slash]))
        hpart := strings.trim_space(s[slash + 1:])
        hpart = strings.trim_space(strings.trim_suffix(hpart, "auto"))
        h, kh := strconv.parse_f64(hpart)
        if kw && kh && h > 0 && w > 0 do return f32(w / h), true
        return 0, false
    }
    // um único número = razão direta (w/1)
    n, k := strconv.parse_f64(strings.trim_space(strings.trim_suffix(s, "auto")))
    if k && n > 0 do return f32(n), true
    return 0, false
}

// Registra os nomes dentro de um token `[a b …]` como linhas no índice `at_line`
// (1-based). Nomes são slices do `s` já lowercased (mesma vida do grid_area_name).
@(private="file")
grid_record_lines :: proc(lines: ^[GRID_MAX_LINES]Grid_Line, line_n: ^int, tok: string, at_line: int) {
    if lines == nil || line_n == nil do return
    inner := tok
    if strings.has_prefix(inner, "[") do inner = inner[1:]
    if strings.has_suffix(inner, "]") do inner = inner[:len(inner) - 1]
    for nm in strings.fields(inner, context.temp_allocator) {
        if line_n^ >= GRID_MAX_LINES do break
        lines[line_n^] = Grid_Line{name = nm, line = at_line}
        line_n^ += 1
    }
}

// grid-template-columns/rows -> lista de tracks. Suporta px/%/fr/auto,
// repeat(N, …), repeat(auto-fill|auto-fit, <track>) e minmax(min, max).
// Preenche os arrays passados (reusado por colunas e linhas).
@(private="file")
parse_grid_template :: proc(tracks: ^[GRID_MAX_TRACKS]Grid_Track, track_n: ^int, auto_fill: ^bool, value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720, lines: ^[GRID_MAX_LINES]Grid_Line = nil, line_n: ^int = nil) {
    s := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    track_n^ = 0
    auto_fill^ = false
    if line_n != nil do line_n^ = 0
    if s == "" || s == "none" do return

    toks := split_top_level(s)
    n := 0
    for tok in toks {
        if n >= GRID_MAX_TRACKS do break
        if strings.has_prefix(tok, "[") { grid_record_lines(lines, line_n, tok, n + 1); continue } // nome de linha
        if strings.has_prefix(tok, "repeat(") && strings.has_suffix(tok, ")") {
            inner := tok[len("repeat("):len(tok) - 1]
            comma := strings.index_byte(inner, ',')
            if comma < 0 do continue
            count_s := strings.trim_space(inner[:comma])
            rest    := strings.trim_space(inner[comma + 1:])
            if count_s == "auto-fill" || count_s == "auto-fit" {
                // padrão de track único; a contagem é resolvida no layout
                auto_fill^ = true
                tracks[0] = parse_grid_track(first_track(rest), fs, vw, vh)
                track_n^ = 1
                return
            }
            if cnt, k := strconv.parse_int(count_s); k && cnt > 0 {
                rtoks := split_top_level(rest)
                for _ in 0 ..< cnt {
                    for rt in rtoks {
                        if n >= GRID_MAX_TRACKS do break
                        if strings.has_prefix(rt, "[") { grid_record_lines(lines, line_n, rt, n + 1); continue } // nome de linha
                        tracks[n] = parse_grid_track(rt, fs, vw, vh); n += 1
                    }
                }
            }
            continue
        }
        tracks[n] = parse_grid_track(tok, fs, vw, vh); n += 1
    }
    track_n^ = n
}

// grid-auto-rows / grid-auto-columns: lista simples de trilhas (sem repeat()
// nem nomes de linha — a spec não os permite aqui). `auto` cai em .Auto, que é
// exatamente o comportamento atual das trilhas implícitas, então uma lista só de
// `auto` é no-op. split_top_level respeita os parênteses de minmax(a, b).
@(private="file")
parse_grid_auto_tracks :: proc(out: ^[GRID_MAX_AUTO]Grid_Track, value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> int {
    n := 0
    for tok in split_top_level(strings.trim_space(value)) {
        if n >= GRID_MAX_AUTO do break
        t := strings.trim_space(tok)
        if t == "" do continue
        out[n] = parse_grid_track(t, fs, vw, vh)
        n += 1
    }
    return n
}

@(private="file")
parse_grid_track :: proc(tok: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) -> Grid_Track {
    t := strings.trim_space(tok)
    if strings.has_prefix(t, "minmax(") && strings.has_suffix(t, ")") {
        inner := t[len("minmax("):len(t) - 1]
        if comma := strings.index_byte(inner, ','); comma >= 0 {
            mn := strings.trim_space(inner[:comma])
            mx := strings.trim_space(inner[comma + 1:])
            tr := parse_grid_track(mx, fs, vw, vh) // a parte "max" define o tipo
            tr.de_minmax = true // o `max` é TETO de crescimento, não largura pedida
            tr.min_kind = .Auto
            if mn == "min-content" do tr.min_kind = .MinContent
            if mn == "max-content" do tr.min_kind = .MaxContent
            if px, is_pct, k := parse_len(mn, fs, vw, vh); k {
                tr.min_kind = .Fixed
                if is_pct { tr.min_pct = px } else { tr.min_px = px } // px aqui é FRAÇÃO se %
            }
            return tr
        }
    }
    if t == "auto" do return Grid_Track{kind = .Auto}
    if t == "min-content" do return Grid_Track{kind = .Auto, min_kind = .MinContent, max_kind = .MinContent}
    if t == "max-content" do return Grid_Track{kind = .Auto, min_kind = .MaxContent, max_kind = .MaxContent}
    if strings.has_prefix(t, "fit-content(") && strings.has_suffix(t, ")") {
        if px, pct, ok := parse_len(strings.trim_space(t[12:len(t)-1]), fs, vw, vh); ok {
            return Grid_Track{kind = .Auto, max_kind = .FitContent, value = px, fit_pct = pct}
        }
    }
    if strings.has_suffix(t, "fr") {
        if f, k := strconv.parse_f64(strings.trim_space(t[:len(t) - 2])); k {
            return Grid_Track{kind = .Fr, value = f32(f)}
        }
    }
    if px, pct, k := parse_len(t, fs, vw, vh); k {
        if pct do return Grid_Track{kind = .Pct, value = px} // px = fração aqui
        return Grid_Track{kind = .Fixed, value = px}
    }
    return Grid_Track{kind = .Auto}
}

// grid-column / grid-row -> (linha inicial 1-based, span, nome-início, nome-fim).
// start=0 && start_name=="" => auto-place. Suporta "span N", "a / b" (índices),
// "a / span N", "a" (start só), "auto" E nomes de linha ("nome", "a / b" com
// idents), resolvidos depois contra o container em compute_node.
@(private="file")
parse_grid_line :: proc(value: string) -> (start, span: int, start_name, end_name: string, end_line: int) {
    start = 0; span = 1
    s := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if s == "" || s == "auto" do return
    if slash := strings.index_byte(s, '/'); slash >= 0 {
        a     := strings.trim_space(s[:slash])
        bpart := strings.trim_space(s[slash + 1:])
        if ai, ak := strconv.parse_int(a); ak {
            start = ai // início explícito
        } else if strings.has_prefix(a, "span") {
            // `span N / <linha>`: o start é AUTO e quem ancora é o FIM
            // (start = fim - N, resolvido junto do negativo em compute_node).
            // Antes o N da ESQUERDA era jogado fora e sobrava span 1 — o golden
            // do fixture pegou isso, o teste de unidade não, porque eu havia
            // chamado o helper com um span que o parser nunca produzia.
            if n, k := strconv.parse_int(strings.trim_space(a[4:])); k && n > 0 do span = n
        } else if a != "auto" && a != "" {
            start_name = a // nome de linha
        }
        if strings.has_prefix(bpart, "span") {
            if n, k := strconv.parse_int(strings.trim_space(bpart[4:])); k && n > 0 do span = n
        } else if bi, bk := strconv.parse_int(bpart); bk {
            end_line = bi // guardado CRU: se for negativo, só o compute_node resolve
            if start > 0 && bi > start do span = bi - start // a / b => span = b-a
        } else if bpart != "auto" && bpart != "" {
            end_name = bpart // nome de linha de fim
        }
        return
    }
    if strings.has_prefix(s, "span") {
        if n, k := strconv.parse_int(strings.trim_space(s[4:])); k && n > 0 do span = n
        return
    }
    if v, k := strconv.parse_int(s); k {
        start = v // "grid-column: 2" (span 1)
    } else {
        start_name = s // nome único, ex.: grid-column: content
    }
    return
}

// Acha a linha (1-based) de um nome na tabela do container. ok=false se ausente.
@(private="file")
grid_lookup_line :: proc(lines: []Grid_Line, name: string) -> (int, bool) {
    for l in lines do if l.name == name do return l.line, true
    return 0, false
}

// Resolve grid-column/grid-row nomeado contra as linhas do container.
// "a / b" -> linhas a..b. Nome único "a" -> linha literal "a" (span 1) OU área
// implícita de linhas nomeadas "a-start"/"a-end". ok=false => cai p/ auto-place.
// Linha negativa -> positiva, e o span recalculado. `n` = nº de tracks EXPLÍCITOS
// do container (grid-template-columns/rows já com repeat() expandido).
//
// Sem grid explícito para contar (n=0, ou `repeat(auto-fill)`, cuja contagem só
// sai no layout) não existe de onde contar de trás: degrada para AUTO, que é o
// comportamento anterior. Documentado como degradação, não como acerto.
@(private="file")
grid_resolve_negative :: proc(start, span, end_line, n: int) -> (int, int) {
    s, sp := start, span
    // Ancoragem pelo FIM com fim POSITIVO não precisa do nº de tracks:
    // `span 2 / 5` => start 3; `auto / 5` => start 4 (span 1).
    if s == 0 && end_line > 0 && sp > 0 && end_line - sp > 0 do return end_line - sp, sp
    if s >= 0 && end_line >= 0 do return s, sp // nada negativo: caminho antigo INTACTO
    if n <= 0 {
        if s < 0 do s = 0 // negativo irresolvível não pode vazar p/ o layout
        return s, sp
    }
    last := n + 1 // índice 1-based da ÚLTIMA linha
    if s < 0 do s = last + 1 + s
    e := end_line
    if e < 0 do e = last + 1 + e
    if s <= 0 {
        // start auto + fim conhecido: ancora pelo FIM (`grid-column: span 2 / -1`)
        if e > 0 && sp > 0 && e - sp > 0 do return e - sp, sp
        return 0, sp
    }
    if e > s do sp = e - s
    return s, sp
}

@(private="file")
grid_resolve_named :: proc(lines: []Grid_Line, start_name, end_name: string) -> (start, span: int, ok: bool) {
    span = 1
    if start_name == "" do return 0, 1, false
    if end_name != "" {
        s, sok := grid_lookup_line(lines, start_name)
        e, eok := grid_lookup_line(lines, end_name)
        if sok && eok {
            if e <= s do e = s + 1
            return s, e - s, true
        }
        if sok do return s, 1, true
        return 0, 1, false
    }
    if s, sok := grid_lookup_line(lines, start_name); sok {
        if e, eok := grid_lookup_line(lines, fmt.tprintf("%s-end", start_name)); eok && e > s {
            return s, e - s, true // linha "a" + "a-end" => área implícita
        }
        return s, 1, true
    }
    // sem linha literal: par implícito "a-start" / "a-end"
    s, sok := grid_lookup_line(lines, fmt.tprintf("%s-start", start_name))
    e, eok := grid_lookup_line(lines, fmt.tprintf("%s-end", start_name))
    if sok && eok && e > s do return s, e - s, true
    if sok do return s, 1, true
    return 0, 1, false
}

// grid-template (shorthand): combina areas + rows + columns.
//   "header header" auto "content content" 1fr / 200px 1fr
//   auto 1fr / 200px 1fr  (sem áreas)
//   none
@(private="file")
parse_grid_template_shorthand :: proc(comp: ^Computed, value: string, fs, vw, vh: f32) {
    s := strings.trim_space(value)
    if s == "" || s == "none" do return

    // Encontra o '/' de nível superior (fora de aspas e parênteses)
    slash := -1
    depth := 0
    in_q: u8 = 0
    for i in 0 ..< len(s) {
        c := s[i]
        if in_q != 0 { if c == in_q do in_q = 0; continue }
        if c == '\'' || c == '"' { in_q = c; continue }
        if c == '(' { depth += 1; continue }
        if c == ')' && depth > 0 { depth -= 1; continue }
        if depth == 0 && c == '/' { slash = i; break }
    }

    if slash >= 0 {
        left  := strings.trim_space(s[:slash])
        right := strings.trim_space(s[slash + 1:])
        // direita = colunas
        parse_grid_template(&comp.grid_tracks, &comp.grid_track_n, &comp.grid_auto_fill, right, fs, vw, vh)
        // esquerda = áreas+linhas ou só linhas
        has_q := strings.index_byte(left, '"') >= 0 || strings.index_byte(left, '\'') >= 0
        if has_q {
            parse_grid_template_areas(comp, left)
            // extrai os track-sizes de linha entre/após as aspas
            rn := 0
            i := 0
            for i < len(left) && rn < GRID_MAX_TRACKS {
                for i < len(left) && (left[i] == ' ' || left[i] == '\t' || left[i] == '\n') do i += 1
                if i >= len(left) do break
                if left[i] == '"' || left[i] == '\'' {
                    q := left[i]; i += 1
                    for i < len(left) && left[i] != q do i += 1
                    if i < len(left) do i += 1
                    // pula espaço após a aspas
                    for i < len(left) && (left[i] == ' ' || left[i] == '\t') do i += 1
                    if i >= len(left) || left[i] == '"' || left[i] == '\'' {
                        comp.grid_row_tracks[rn] = Grid_Track{kind = .Auto}
                    } else {
                        // extrai token de tamanho (pode ser minmax(...))
                        j := i; pd := 0
                        for j < len(left) {
                            if left[j] == '(' do pd += 1
                            else if left[j] == ')' do pd -= 1
                            else if pd == 0 && (left[j] == '"' || left[j] == '\'' || left[j] == ' ' || left[j] == '\t') do break
                            j += 1
                        }
                        comp.grid_row_tracks[rn] = parse_grid_track(left[i:j], fs, vw, vh)
                        i = j
                    }
                    rn += 1
                } else {
                    // token antes da 1ª aspas (line-name?) — pula
                    for i < len(left) && left[i] != '"' && left[i] != '\'' && left[i] != ' ' do i += 1
                }
            }
            comp.grid_row_track_n = rn
        } else {
            af: bool
            parse_grid_template(&comp.grid_row_tracks, &comp.grid_row_track_n, &af, left, fs, vw, vh)
        }
    } else {
        // sem '/': pode ser só áreas
        has_q := strings.index_byte(s, '"') >= 0 || strings.index_byte(s, '\'') >= 0
        if has_q do parse_grid_template_areas(comp, s)
    }
}

// grid-template-areas: "header header" "sidebar content" "footer footer"
// Extrai áreas nomeadas com bounding rect (col/row/span) em comp.grid_areas.
@(private="file")
parse_grid_template_areas :: proc(comp: ^Computed, value: string) {
    s := strings.trim_space(value)
    if s == "" || s == "none" do return

    // Cada string entre aspas é uma linha; dentro, tokens separados por espaço.
    row_buf: [GRID_MAX_TRACKS][GRID_MAX_TRACKS]string
    row_cnt: [GRID_MAX_TRACKS]int
    nrows, ncols: int

    i := 0
    for i < len(s) && nrows < GRID_MAX_TRACKS {
        if s[i] == '"' || s[i] == '\'' {
            q := s[i]; i += 1; st := i
            for i < len(s) && s[i] != q do i += 1
            row_str := s[st:i]
            if i < len(s) do i += 1

            col := 0; j := 0
            for j < len(row_str) && col < GRID_MAX_TRACKS {
                for j < len(row_str) && (row_str[j] == ' ' || row_str[j] == '\t') do j += 1
                if j >= len(row_str) do break
                k := j
                for k < len(row_str) && row_str[k] != ' ' && row_str[k] != '\t' do k += 1
                row_buf[nrows][col] = row_str[j:k]
                col += 1; j = k
            }
            row_cnt[nrows] = col
            ncols = max(ncols, col)
            nrows += 1
        } else {
            i += 1
        }
    }
    if nrows == 0 || ncols == 0 do return

    n := 0
    for r in 0 ..< nrows {
        for c in 0 ..< row_cnt[r] {
            name := row_buf[r][c]
            if name == "." || name == "" do continue
            found := false
            for a in 0 ..< n {
                if comp.grid_areas[a].name == name {
                    ec := c + 1; er := r + 1
                    oc := comp.grid_areas[a].col + comp.grid_areas[a].col_span
                    or := comp.grid_areas[a].row + comp.grid_areas[a].row_span
                    comp.grid_areas[a].col = min(comp.grid_areas[a].col, c)
                    comp.grid_areas[a].row = min(comp.grid_areas[a].row, r)
                    comp.grid_areas[a].col_span = max(ec, oc) - comp.grid_areas[a].col
                    comp.grid_areas[a].row_span = max(er, or) - comp.grid_areas[a].row
                    found = true; break
                }
            }
            if !found && n < GRID_MAX_AREAS {
                comp.grid_areas[n] = Grid_Area{name = name, col = c, row = r, col_span = 1, row_span = 1}
                n += 1
            }
        }
    }
    comp.grid_area_n = n
}

// grid-area: <nome> | <row-start> / <col-start> [/ <row-end> [/ <col-end>]]
@(private="file")
parse_grid_area_prop :: proc(comp: ^Computed, value: string) {
    s := strings.trim_space(value)
    if s == "" || s == "auto" do return
    if strings.index_byte(s, '/') >= 0 {
        // shorthand numérico: row-start / col-start / row-end / col-end
        vals: [4]int; ni := 0
        rest := s
        for ni < 4 {
            sl := strings.index_byte(rest, '/')
            part := sl >= 0 ? strings.trim_space(rest[:sl]) : strings.trim_space(rest)
            if v, k := strconv.parse_int(part); k do vals[ni] = v
            ni += 1
            if sl < 0 do break
            rest = rest[sl + 1:]
        }
        // ⚠️ os NEGATIVOS aqui são a mesma cegueira que o `grid-column` tinha
        // (`vals[3] > vals[1]` é falso p/ -2): guarda o cru nos mesmos campos que
        // o compute_node resolve contra o nº de tracks do pai.
        if vals[0] != 0 do comp.grid_row_start = vals[0]
        if vals[1] != 0 do comp.grid_col_start = vals[1]
        if ni >= 3 {
            if vals[2] < 0 { comp.grid_row_end_line = vals[2] }
            else if vals[2] > vals[0] && vals[0] > 0 { comp.grid_row_span = vals[2] - vals[0] }
        }
        if ni >= 4 {
            if vals[3] < 0 { comp.grid_col_end_line = vals[3] }
            else if vals[3] > vals[1] && vals[1] > 0 { comp.grid_col_span = vals[3] - vals[1] }
        }
        return
    }
    lo := strings.to_lower(s, context.temp_allocator)
    if strings.has_prefix(lo, "span") do return
    if _, k := strconv.parse_int(s); k do return
    comp.grid_area_name = s
}

// Primeiro token de nível superior (para o padrão de auto-fill).
@(private="file")
first_track :: proc(s: string) -> string {
    t := split_top_level(s)
    for tok in t do if !strings.has_prefix(tok, "[") do return tok // pula nomes de linha
    return len(t) > 0 ? t[0] : s
}

// Separa por espaços apenas no nível superior (ignora espaços dentro de
// parênteses, ex.: minmax(200px, 1fr)). Usa o temp allocator do frame.
split_top_level :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth := 0
    start := -1
    for i in 0 ..< len(s) {
        ch := s[i]
        // ( ) e [ ] agrupam: minmax(200px,1fr) fica 1 token; nomes de linha
        // grid [a b] também (senão "b]" viraria trilha fantasma no template).
        if      ch == '(' || ch == '[' do depth += 1
        else if ch == ')' || ch == ']' do depth -= 1
        sep := depth == 0 && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        if sep {
            if start >= 0 { append(&out, s[start:i]); start = -1 }
        } else if start < 0 {
            start = i
        }
    }
    if start >= 0 do append(&out, s[start:])
    return out[:]
}

// Converte um valor de font-size em px (parent = tamanho do elemento pai).
@(private="file")
parse_font_size :: proc(value: string, parent: f32, vw: f32 = 1280, vh: f32 = 720) -> (f32, bool) {
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    switch v {
    case "xx-small": return 9  * g_zoom, true
    case "x-small":  return 10 * g_zoom, true
    case "small":    return 13 * g_zoom, true
    case "medium":   return 16 * g_zoom, true
    case "large":    return 18 * g_zoom, true
    case "x-large":  return 24 * g_zoom, true
    case "xx-large": return 32 * g_zoom, true
    case "xxx-large": return 48 * g_zoom, true
    case "smaller":  return parent * 0.85, true // parent ja escalado
    case "larger":   return parent * 1.15, true
    }

    // O COMPRIMENTO vai INTEIRO para o parse_len, dono unico da tabela de unidades.
    // Aqui havia um SEGUNDO switch, copia parcial daquele -- e as duas copias ja
    // tinham divergido: `ex`, `lh` e as ABSOLUTAS (in/cm/mm/pc/Q) existiam so la, e
    // `xxx-large` estava no is_font_size_token mas nao neste switch. Toda declaracao
    // nessas grafias caia CALADA. (Mesmo padrao de "duas copias divergindo" do M225.)
    //
    // As duas diferencas de CONTEXTO ficam aqui, e sao so estas:
    //   - a base de `em` e de `%` e o font-size do PAI, que passamos como `fs`;
    //   - `%` e RAZAO do pai, nao fracao de uma caixa: multiplicamos de volta.
    if px, pct, ok := parse_len(v, parent, vw, vh); ok {
        if pct do return px * parent, true
        return px, true
    }
    return 0, false
}

// Aspas default por idioma (subconjunto da tabela do HTML rendering spec). `depth`
// 0 = par externo, 1 = interno. Devolve a marca de abertura (open) ou fechamento.
lang_quote :: proc(lang: string, depth: int, open: bool) -> string {
    l := lang
    if idx := strings.index_byte(l, '-'); idx >= 0 do l = l[:idx] // "en-US" → "en"
    l = strings.to_lower(l, context.temp_allocator)
    o0, c0, o1, c1 := "“", "”", "‘", "’" // default (en, bn, chr, …)
    switch l {
    case "am", "fa": o0, c0, o1, c1 = "«", "»", "‹", "›" // amárico, persa
    case "el":       o0, c0, o1, c1 = "«", "»", "“", "”" // grego
    case "fr":       o0, c0, o1, c1 = "«", "»", "«", "»" // francês
    }
    if depth <= 0 do return open ? o0 : c0
    return open ? o1 : c1
}

// Marca de aspas p/ um <q> na profundidade `depth`. Prioriza a prop `quotes`
// (pares "abre" "fecha" …; `none`→sem marca; `auto`/ausente→default por idioma).
quote_mark :: proc(quotes_raw, lang: string, depth: int, open: bool) -> string {
    qr := strings.trim_space(quotes_raw)
    if qr != "" {
        lc := strings.to_lower(qr, context.temp_allocator)
        if lc == "none" do return ""
        if lc != "auto" {
            marks: [dynamic]string
            marks.allocator = context.temp_allocator
            i := 0
            for i < len(qr) {
                c := qr[i]
                if c == '"' || c == '\'' {
                    j := i + 1
                    for j < len(qr) && qr[j] != c do j += 1
                    append(&marks, qr[i + 1:j])
                    i = j + 1
                } else {
                    i += 1
                }
            }
            if len(marks) >= 2 {
                npairs := len(marks) / 2
                p := depth < npairs ? depth : npairs - 1
                idx := 2 * p + (open ? 0 : 1)
                r := idx < len(marks) ? marks[idx] : ""
                return r
            }
            return ""
        }
    }
    return lang_quote(lang, depth, open)
}

// ── CSS counters (counter-reset/-increment + counter()/counters() em content) ──

Counter_Op :: struct { name: string, val: int }

// Numeral romano (1..3999); fora do intervalo cai p/ decimal.
to_roman_ct :: proc(n: int, upper: bool) -> string {
    if n <= 0 || n >= 4000 do return fmt.tprintf("%d", n)
    vals := [?]int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
    su   := [?]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}
    sl   := [?]string{"m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"}
    b := strings.builder_make(context.temp_allocator)
    x := n
    for i in 0 ..< len(vals) {
        for x >= vals[i] {
            strings.write_string(&b, upper ? su[i] : sl[i])
            x -= vals[i]
        }
    }
    return strings.to_string(b)
}

// Formata um valor de counter no estilo pedido (subconjunto; fallback = decimal).
fmt_counter :: proc(n: int, style: string) -> string {
    switch strings.to_lower(strings.trim_space(style), context.temp_allocator) {
    case "decimal-leading-zero":
        if n >= 0 && n < 10 do return fmt.tprintf("0%d", n)
        return fmt.tprintf("%d", n)
    case "lower-roman": return to_roman_ct(n, false)
    case "upper-roman": return to_roman_ct(n, true)
    case: return fmt.tprintf("%d", n) // decimal, georgian/cjk/… → decimal
    }
}

// Parseia `counter-reset`/`-increment` cru em pares (nome [inteiro]); default_val
// = 0 p/ reset, 1 p/ increment.
parse_counter_ops :: proc(raw: string, default_val: int) -> [dynamic]Counter_Op {
    out: [dynamic]Counter_Op; out.allocator = context.temp_allocator
    toks := strings.fields(raw, context.temp_allocator)
    i := 0
    for i < len(toks) {
        name := toks[i]; i += 1
        if strings.equal_fold(name, "none") do continue
        val := default_val
        if i < len(toks) {
            if v, ok := strconv.parse_int(toks[i]); ok { val = v; i += 1 }
        }
        append(&out, Counter_Op{name, val})
    }
    return out
}

// Pilha por nome de counter (ponteiro p/ mutar via mapa). Innermost = último.
counter_get :: proc(cs: ^map[string]^[dynamic]int, name: string) -> ^[dynamic]int {
    if st, ok := cs[name]; ok do return st
    st := new([dynamic]int)
    cs[name] = st
    return st
}
counter_top :: proc(cs: ^map[string]^[dynamic]int, name: string) -> int {
    if st, ok := cs[name]; ok && len(st) > 0 do return st[len(st) - 1]
    return 0
}
counter_apply_reset :: proc(raw: string, cs: ^map[string]^[dynamic]int, pushed: ^[dynamic]string) {
    if raw == "" do return
    for op in parse_counter_ops(raw, 0) {
        append(counter_get(cs, op.name), op.val)
        append(pushed, op.name)
    }
}
counter_apply_inc :: proc(raw: string, cs: ^map[string]^[dynamic]int, pushed: ^[dynamic]string) {
    if raw == "" do return
    for op in parse_counter_ops(raw, 1) {
        st := counter_get(cs, op.name)
        if len(st) == 0 { append(st, 0); append(pushed, op.name) } // reset implícito a 0
        st[len(st) - 1] += op.val
    }
}
// counter-set: DEFINE o valor do counter (default 0). Se já existe no escopo,
// sobrescreve o topo; senão cria um novo neste elemento (como counter-reset).
counter_apply_set :: proc(raw: string, cs: ^map[string]^[dynamic]int, pushed: ^[dynamic]string) {
    if raw == "" do return
    for op in parse_counter_ops(raw, 0) {
        st := counter_get(cs, op.name)
        if len(st) == 0 { append(st, op.val); append(pushed, op.name) }
        else            { st[len(st) - 1] = op.val }
    }
}
counter_apply_inc_one :: proc(name: string, delta: int, cs: ^map[string]^[dynamic]int, pushed: ^[dynamic]string) {
    st := counter_get(cs, name)
    if len(st) == 0 { append(st, 0); append(pushed, name) }
    st[len(st) - 1] += delta
}
counter_pop :: proc(cs: ^map[string]^[dynamic]int, names: [dynamic]string) {
    #reverse for name in names {
        if st, ok := cs[name]; ok && len(st) > 0 do pop(st)
    }
}

// Divide os args de counter()/counters() por vírgula de topo (respeita aspas).
counter_split_args :: proc(s: string) -> [dynamic]string {
    out: [dynamic]string; out.allocator = context.temp_allocator
    q: u8 = 0; start := 0
    for i in 0 ..< len(s) {
        c := s[i]
        if q != 0 { if c == q do q = 0; continue }
        if c == '"' || c == '\'' do q = c
        else if c == ',' { append(&out, s[start:i]); start = i + 1 }
    }
    append(&out, s[start:])
    return out
}
counter_unquote :: proc(s: string) -> string {
    t := strings.trim_space(s)
    if len(t) >= 2 && (t[0] == '"' || t[0] == '\'') && t[len(t) - 1] == t[0] {
        return unescape_css(t[1:len(t) - 1])
    }
    return t
}

// Resolve `content` como uma SEQUÊNCIA de componentes concatenados: strings entre
// aspas, counter()/counters(), attr(<nome> [, <fallback>]), e as keywords de aspas
// (open-quote/close-quote/no-*-quote). String OWNED (default allocator; liberada em
// free_styles). `cs` pode ser nil (sem counters); `node` pode ser nil (sem attr).
// Acha o ')' que FECHA a função a partir de `open` (o char após '('), respeitando
// aspas e parênteses aninhados — o fallback de attr()/o separador de counters()
// podem conter ')'. Retorna len(s) se não fechar.
@(private="file")
content_close_paren :: proc(s: string, open: int) -> int {
    depth := 0; q: u8 = 0
    for j := open; j < len(s); j += 1 {
        c := s[j]
        if q != 0 { if c == q do q = 0; continue }
        switch c {
        case '"', '\'': q = c
        case '(': depth += 1
        case ')': if depth == 0 do return j; depth -= 1
        }
    }
    return len(s)
}

resolve_content_counters :: proc(raw: string, cs: ^map[string]^[dynamic]int, node: ^dompkg.Node = nil, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    s := strings.trim_space(raw)
    n := len(s)
    i := 0
    for i < n {
        c := s[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' { i += 1; continue }
        if c == '"' || c == '\'' {
            j := i + 1
            for j < n && s[j] != c do j += 1
            strings.write_string(&b, unescape_css(s[i + 1:j]))
            i = j + 1
        } else if strings.has_prefix(s[i:], "attr(") {
            // attr(<nome> [, <fallback>]) → valor do atributo do elemento (ou o
            // fallback, ou ""). O nome pode vir com um sufixo de tipo (attr(x string));
            // pegamos só o 1º token do 1º argumento.
            open := i + len("attr(")
            close := content_close_paren(s, open)
            args := counter_split_args(s[open:close])
            name := ""
            if len(args) >= 1 {
                nt := strings.fields(strings.trim_space(args[0]), context.temp_allocator)
                if len(nt) >= 1 do name = nt[0]
            }
            got := false
            if node != nil && name != "" {
                if val, ok := node.attrs[name]; ok { strings.write_string(&b, val); got = true }
            }
            if !got && len(args) >= 2 do strings.write_string(&b, counter_unquote(args[1]))
            i = close + 1
        } else if strings.has_prefix(s[i:], "counters(") {
            open := i + len("counters(")
            close := content_close_paren(s, open)
            args := counter_split_args(s[open:close])
            if cs != nil && len(args) >= 2 {
                name  := strings.trim_space(args[0])
                sep   := counter_unquote(args[1])
                style := len(args) >= 3 ? args[2] : "decimal"
                if st, ok := cs[name]; ok && len(st) > 0 {
                    for v, k in st {
                        if k > 0 do strings.write_string(&b, sep)
                        strings.write_string(&b, fmt_counter(v, style))
                    }
                } else {
                    strings.write_string(&b, fmt_counter(0, style))
                }
            }
            i = close + 1
        } else if strings.has_prefix(s[i:], "counter(") {
            open := i + len("counter(")
            close := content_close_paren(s, open)
            args := counter_split_args(s[open:close])
            if cs != nil && len(args) >= 1 {
                name  := strings.trim_space(args[0])
                style := len(args) >= 2 ? args[1] : "decimal"
                strings.write_string(&b, fmt_counter(counter_top(cs, name), style))
            }
            i = close + 1
        } else if strings.has_prefix(s[i:], "no-open-quote") {
            i += len("no-open-quote") // sem saída
        } else if strings.has_prefix(s[i:], "no-close-quote") {
            i += len("no-close-quote")
        } else if strings.has_prefix(s[i:], "open-quote") {
            strings.write_string(&b, "“"); i += len("open-quote")
        } else if strings.has_prefix(s[i:], "close-quote") {
            strings.write_string(&b, "”"); i += len("close-quote")
        } else {
            i += 1 // token desconhecido (ident/etc.) — ignora
        }
    }
    return strings.to_string(b)
}

// Passe em ordem de documento que resolve os counters e preenche o `content`
// gerado de ::before/::after que usa counter()/counters(). Escopo de um counter =
// subárvore + irmãos seguintes → cada nó devolve o que EMPILHOU e o PAI desempilha
// depois de todos os filhos (CSS Lists §nesting/scope).
resolve_counters :: proc(root: ^dompkg.Node, styles: ^map[^dompkg.Node]Computed) {
    cs := make(map[string]^[dynamic]int)
    defer {
        for _, st in cs { delete(st^); free(st) }
        delete(cs)
    }
    counter_dfs(root, styles, &cs)
}

@(private="file")
counter_dfs :: proc(node: ^dompkg.Node, styles: ^map[^dompkg.Node]Computed, cs: ^map[string]^[dynamic]int) {
    pushed: [dynamic]string          // counters criados por ESTE elemento
    defer { counter_pop(cs, pushed); delete(pushed) } // escopo = elemento + descendentes
    comp, has := styles[node]
    if has {
        // UA-stylesheet: <ol>/<ul> criam o counter `list-item` (reset a 0).
        if node.tag == "ol" || node.tag == "ul" {
            append(counter_get(cs, "list-item"), 0); append(&pushed, "list-item")
        }
        counter_apply_reset(comp.counter_reset_raw, cs, &pushed)
        if node.tag == "li" do counter_apply_inc_one("list-item", 1, cs, &pushed)
        counter_apply_inc(comp.counter_increment_raw, cs, &pushed)
        counter_apply_set(comp.counter_set_raw, cs, &pushed)
        if comp.before != nil {
            counter_apply_reset(comp.before.counter_reset_raw, cs, &pushed)
            counter_apply_inc(comp.before.counter_increment_raw, cs, &pushed)
            counter_apply_set(comp.before.counter_set_raw, cs, &pushed)
            if comp.before.content_has_counter {
                delete(comp.before.content)
                comp.before.content = resolve_content_counters(comp.before.content_raw, cs, node)
            }
        }
    }
    for c in node.children do counter_dfs(c, styles, cs)
    if has && comp.after != nil {
        counter_apply_reset(comp.after.counter_reset_raw, cs, &pushed)
        counter_apply_inc(comp.after.counter_increment_raw, cs, &pushed)
        counter_apply_set(comp.after.counter_set_raw, cs, &pushed)
        if comp.after.content_has_counter {
            delete(comp.after.content)
            comp.after.content = resolve_content_counters(comp.after.content_raw, cs, node)
        }
    }
}


@(private="file")
unescape_css :: proc(s: string) -> string {
    if strings.index_byte(s, '\\') < 0 do return s
    b := strings.builder_make(context.temp_allocator)
    hexval :: proc(c: u8) -> (u32, bool) {
        switch {
        case c >= '0' && c <= '9': return u32(c - '0'), true
        case c >= 'a' && c <= 'f': return u32(c - 'a') + 10, true
        case c >= 'A' && c <= 'F': return u32(c - 'A') + 10, true
        }
        return 0, false
    }
    i := 0
    for i < len(s) {
        if s[i] == '\\' && i + 1 < len(s) {
            j := i + 1
            v: u32 = 0
            hn := 0
            for j < len(s) && hn < 6 {
                hv, ok := hexval(s[j])
                if !ok do break
                v = v * 16 + hv; j += 1; hn += 1
            }
            if hn > 0 {
                strings.write_rune(&b, rune(v))
                if j < len(s) && s[j] == ' ' do j += 1 // espaço opcional pós-escape
                i = j
            } else {
                strings.write_byte(&b, s[i + 1]); i += 2
            }
        } else {
            strings.write_byte(&b, s[i]); i += 1
        }
    }
    return strings.to_string(b)
}

// Cor sólida representativa de um gradiente: média dos color-stops. Usada para
// aproximar background-clip:text (texto com gradiente) sem clip real de glifos.
@(private="file")
gradient_repr_color :: proc(g: csspkg.Gradient) -> u32 {
    if g.n <= 0 do return DEFAULT_TEXT
    r, gg, b: u32 = 0, 0, 0
    for i in 0 ..< g.n {
        c := g.cols[i]
        r  += (c >> 16) & 0xff
        gg += (c >>  8) & 0xff
        b  +=  c        & 0xff
    }
    n := u32(g.n)
    return ((r / n) << 16) | ((gg / n) << 8) | (b / n)
}

// Classifica um nome de família único em Sans/Serif/Mono. ok=false quando o
// nome é uma família específica desconhecida (ex.: "Poppins" sem fallback) —
// aí o chamador tenta o próximo da stack.
@(private="file")
classify_family :: proc(t: string) -> (Font_Family, bool) {
    switch t {
    case "monospace","ui-monospace","consolas","menlo","monaco","courier","courier new",
         "cascadia code","cascadia mono","sf mono","fira code","fira mono","jetbrains mono",
         "source code pro","roboto mono","dejavu sans mono","liberation mono","lucida console":
        return .Mono, true
    case "serif","ui-serif","georgia","times","times new roman","cambria","garamond",
         "book antiqua","palatino","palatino linotype","merriweather","playfair display","lora","pt serif":
        return .Serif, true
    case "sans-serif","ui-sans-serif","system-ui","-apple-system","blinkmacsystemfont",
         "segoe ui","roboto","helvetica","helvetica neue","arial","inter","poppins","open sans",
         "lato","montserrat","nunito","ubuntu","noto sans","verdana","tahoma","calibri","raleway":
        return .Sans, true
    }
    return .Sans, false
}

// Resolve uma stack de font-family (lista separada por vírgula) para a primeira
// família genérica reconhecida. ok=false se nenhuma for reconhecida.
@(private="file")
// Percorre a PILHA na ordem do autor. Um nome declarado por `@font-face` vence
// no ponto em que aparece (é o que a cascata de font-family manda: a 1ª família
// disponível ganha) e devolve o `fam_id` do registro; senão, o 1º nome que casar
// com uma genérica decide o Font_Family embutido.
// ⚠️ o `fam_id` é resolvido aqui só por NOME — peso e itálico só existem na
// PINTURA, e é lá que `fontface_pick` escolhe a face concreta.
parse_font_family :: proc(value: string) -> (Font_Family, u8, bool) {
    lo := strings.to_lower(value, context.temp_allocator)
    when #config(FONTPROBE, false) {
        @(static) nfam := 0
        nfam += 1
        if nfam <= 25 do fmt.eprintfln("[FF] family pedida: %q", lo)
    }
    for raw in strings.split(lo, ",", context.temp_allocator) {
        t := strings.trim_space(raw)
        t = strings.trim(t, "\"'")     // tira aspas
        t = strings.trim_space(t)
        if t == "" do continue
        if id := fontface_family_id(t); id != 0 do return .Sans, id, true
        if f, ok := classify_family(t); ok do return f, 0, true
    }
    return .Sans, 0, false
}

// Casa um seletor complexo contra um nó, subindo pela cadeia de ancestrais.
@(private="file")
selector_matches_node :: proc(sel: csspkg.Selector, n: ^dompkg.Node, scope0: ^dompkg.Node = nil) -> bool {
    scope := scope0
    np := len(sel.parts)
    if np == 0 do return false
    // alvo (composto mais à direita) casa contra o próprio nó
    if !compound_matches_node(sel.parts[np - 1], n, scope) do return false
    return match_left(sel, np - 2, n, scope)
}

// Casa parts[pi] (e o resto da cadeia à esquerda) em relação ao nó à direita já
// casado. Descendant/Sibling tentam todos os candidatos (backtracking).
@(private="file")
match_left :: proc(sel: csspkg.Selector, pi: int, right: ^dompkg.Node, scope: ^dompkg.Node = nil) -> bool {
    if pi < 0 do return true
    switch sel.combs[pi] {
    case .Child:
        p := right.parent
        return p != nil && compound_matches_node(sel.parts[pi], p, scope) && match_left(sel, pi - 1, p, scope)
    case .Descendant:
        for a := right.parent; a != nil; a = a.parent {
            if compound_matches_node(sel.parts[pi], a, scope) && match_left(sel, pi - 1, a, scope) do return true
        }
        return false
    case .Adjacent: // '+': irmão elemento imediatamente anterior
        s := prev_elem_sibling(right)
        return s != nil && compound_matches_node(sel.parts[pi], s, scope) && match_left(sel, pi - 1, s, scope)
    case .Sibling: // '~': qualquer irmão elemento anterior
        for s := prev_elem_sibling(right); s != nil; s = prev_elem_sibling(s) {
            if compound_matches_node(sel.parts[pi], s, scope) && match_left(sel, pi - 1, s, scope) do return true
        }
        return false
    }
    return false
}

// Irmão ELEMENTO imediatamente anterior no pai (nil se for o primeiro).
@(private="file")
prev_elem_sibling :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    p := n.parent
    if p == nil do return nil
    idx := -1
    for c, i in p.children {
        if c == n { idx = i; break }
    }
    for j := idx - 1; j >= 0; j -= 1 {
        if p.children[j].kind == .Element do return p.children[j]
    }
    return nil
}

Directionality :: enum u8 { Ltr, Rtl }

// Direcionalidade de um elemento p/ `:dir()` (HTML §the-dir-attribute, subconjunto):
// o atributo `dir` mais próximo subindo a árvore decide — "ltr"/"rtl" explícitos,
// "auto" = primeiro caractere forte do texto do elemento (senão ltr). Valor `dir`
// inválido é IGNORADO (herda do ancestral). Sem nenhum `dir` válido → ltr (default
// do documento). NÃO é a prop CSS `direction` — é a direcionalidade semântica.
@(private="file")
node_directionality :: proc(n: ^dompkg.Node) -> Directionality {
    cur := n
    for cur != nil {
        if cur.kind == .Element {
            if d, ok := cur.attrs["dir"]; ok {
                if      strings.equal_fold(d, "ltr")  do return .Ltr
                else if strings.equal_fold(d, "rtl")  do return .Rtl
                else if strings.equal_fold(d, "auto") do return dir_from_text(cur)
                // valor inválido (ex.: dir="foopy") → ignora, herda do ancestral
            }
        }
        cur = cur.parent
    }
    return .Ltr
}

// dir=auto: direção do PRIMEIRO caractere forte (L → ltr; R/AL → rtl) no texto do
// elemento e descendentes, em ordem de documento. Sem nenhum forte → ltr.
@(private="file")
dir_from_text :: proc(n: ^dompkg.Node) -> Directionality {
    d, found := first_strong_dir(n)
    return found ? d : .Ltr
}

@(private="file")
first_strong_dir :: proc(n: ^dompkg.Node) -> (Directionality, bool) {
    if n.kind == .Text {
        for r in n.text {
            // faixas RTL fortes: hebraico (0590–05FF) e árabe (0600–07BF, 08A0–08FF,
            // FB1D–FDFF, FE70–FEFF). Latino/etc. = forte L. Fraco/neutro = pula.
            if is_rtl_rune(r) do return .Rtl, true
            if is_ltr_rune(r) do return .Ltr, true
        }
        return .Ltr, false
    }
    for c in n.children {
        if d, ok := first_strong_dir(c); ok do return d, true
    }
    return .Ltr, false
}

@(private="file")
is_rtl_rune :: proc(r: rune) -> bool {
    return (r >= 0x0590 && r <= 0x05FF) || (r >= 0x0600 && r <= 0x07BF) ||
           (r >= 0x08A0 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) ||
           (r >= 0xFE70 && r <= 0xFEFF)
}

// Forte L (aproximação): letra latina/grega/cirílica/CJK e a maioria dos scripts
// LTR. Excluímos dígitos e pontuação (fracos/neutros) e a faixa RTL.
@(private="file")
is_ltr_rune :: proc(r: rune) -> bool {
    if is_rtl_rune(r) do return false
    return unicode.is_letter(r)
}

@(private="file")
compound_matches_node :: proc(c: csspkg.Compound, n: ^dompkg.Node, scope: ^dompkg.Node = nil) -> bool {
    if n == nil || n.kind != .Element do return false
    // ── Caminho QUENTE do motor inteiro ──────────────────────────────────────
    // Esta proc roda uma vez por COMPOSTO, por regra candidata, por nó, por
    // passe (são 5: normal/::before/::after/::first-letter/:hover) — e mais uma
    // vez por ancestral em cada combinador descendente. Antes ela chamava
    // node_classes(n) de cara, que alocava DUAS vezes na arena temp
    // (strings.fields + o [dynamic]string), sempre, mesmo quando o composto nem
    // olhava classe. Como o compute_styles inteiro roda sem nenhum
    // free_all(temp) no meio (o único fica no topo do loop de frame), essa
    // alocação por-casamento era a que fazia a arena crescer com o PRODUTO
    // nós × regras-candidatas em vez do tamanho da página.
    //
    // Agora: (1) tag e id — os filtros que rejeitam a esmagadora maioria dos
    // candidatos — são testados ANTES de tocar em qualquer string de classe;
    // (2) o atributo `class` só é fatiado se o composto REALMENTE exige classe;
    // (3) o fatiamento escreve num buffer de pilha, sem alocar.
    // A duplicação dos testes de tag/id com csspkg.compound_matches é
    // deliberada: a versão do pacote css continua correta sozinha (é o que os
    // testes de css_test.odin exercitam), aqui eles são só um pré-filtro.
    if c.scope_req {
        if scope != nil { if n != scope do return false
        } else {
            for a := n.parent; a != nil; a = a.parent {
                if a.kind == .Element do return false
            }
        }
    }
    if c.pseudo_only do return false
    if c.never do return false // :target/:invalid/:nth-child(bogus)… (ver Compound.never)
    if c.tag != "" && c.tag != "*" && c.tag != n.tag do return false
    id := n.attrs["id"] if "id" in n.attrs else ""
    if c.id != "" && c.id != id do return false
    cls_buf: [MAX_INLINE_CLASSES]string
    classes: []string
    if len(c.classes) > 0 do classes = node_classes_into(n, cls_buf[:])
    if !csspkg.compound_matches(c, n.tag, classes, id, n.attrs) do return false
    if c.nth_kind != .None && !structural_matches(c, n, scope) do return false
    if c.empty_req && !node_is_empty(n) do return false
    if c.dir_req != .None { // :dir(ltr)/:dir(rtl)
        switch c.dir_req {
        case .None:  // inalcançável (guardado acima)
        case .Never: return false // :dir(foopy)/:dir()/:dir(ltr,rtl) → casa nada
        case .Ltr:   if node_directionality(n) != .Ltr do return false
        case .Rtl:   if node_directionality(n) != .Rtl do return false
        }
    }
    for ns in c.nots { // :not(X): o nó não pode casar nenhum seletor X
        if selector_matches_node(ns, n, scope) do return false
    }
    if len(c.ors) > 0 { // :is(A, B): precisa casar algum dos seletores (completos)
        any_match := false
        for os, i in c.ors {
            if !any_match do any_match = selector_matches_node(os, n, scope)
            if os.or_group_end || i == len(c.ors)-1 {
                if !any_match do return false
                any_match = false
            }
        }
    }
    has_group_match := false
    for h, i in c.has { // OR dentro de uma chamada; AND entre chamadas de :has().
        if !has_group_match do has_group_match = has_matches(n, h.lead, h.sel, scope)
        if h.group_end || i == len(c.has) - 1 {
            if !has_group_match do return false
            has_group_match = false
        }
    }
    return true
}

// Irmão ELEMENTO imediatamente seguinte (nil se for o último).
@(private="file")
next_elem_sibling :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    p := n.parent
    if p == nil do return nil
    idx := -1
    for c, i in p.children {
        if c == n { idx = i; break }
    }
    for j := idx + 1; j < len(p.children); j += 1 {
        if p.children[j].kind == .Element do return p.children[j]
    }
    return nil
}

// :has(S) — existe algum elemento alcançável a partir de `scope` via `lead`
// (e depois pelos combinadores internos de S) que casa a cadeia? Avalia da
// esquerda p/ a direita: parte do escopo, encontra candidatos p/ parts[0], e
// segue a cadeia até o alvo.
@(private="file")
has_matches :: proc(anchor: ^dompkg.Node, lead: csspkg.Combinator, sel: csspkg.Selector, scope: ^dompkg.Node) -> bool {
    return has_reach(anchor, lead, sel, 0, scope)
}

@(private="file")
has_reach :: proc(from: ^dompkg.Node, comb: csspkg.Combinator, sel: csspkg.Selector, idx: int, scope: ^dompkg.Node) -> bool {
    switch comb {
    case .Child:
        for c in from.children do if c.kind == .Element && has_try(c, sel, idx, scope) do return true
    case .Descendant:
        for c in from.children {
            if c.kind != .Element do continue
            if has_try(c, sel, idx, scope) do return true
            if has_reach(c, .Descendant, sel, idx, scope) do return true // desce mais fundo
        }
    case .Adjacent:
        if s := next_elem_sibling(from); s != nil do return has_try(s, sel, idx, scope)
    case .Sibling:
        for s := next_elem_sibling(from); s != nil; s = next_elem_sibling(s) {
            if has_try(s, sel, idx, scope) do return true
        }
    }
    return false
}

// Testa o candidato contra parts[idx] e, se casar e não for o alvo, segue a
// cadeia interna de S via o próximo combinador.
@(private="file")
has_try :: proc(cand: ^dompkg.Node, sel: csspkg.Selector, idx: int, scope: ^dompkg.Node) -> bool {
    if !compound_matches_node(sel.parts[idx], cand, scope) do return false
    if idx == len(sel.parts) - 1 do return true
    return has_reach(cand, sel.combs[idx], sel, idx + 1, scope)
}

// Avalia a pseudo-classe estrutural (:first-child/:nth-child/…) contra a
// posição do nó entre os irmãos ELEMENTO do pai (1-based; *-of-type conta só
// irmãos com a mesma tag).
@(private="file")
structural_matches :: proc(c: csspkg.Compound, n: ^dompkg.Node, scope: ^dompkg.Node) -> bool {
    p := n.parent
    if p == nil do return false
    of_type := c.nth_kind == .Of_Type || c.nth_kind == .Last_Of_Type || c.nth_kind == .Only_Of_Type
    idx, total := 0, 0
    for ch in p.children {
        if ch.kind != .Element do continue
        if of_type && ch.tag != n.tag do continue
        if len(c.nth_filter)>0 {
            matched := false
            for sel in c.nth_filter do if selector_matches_node(sel, ch, scope) { matched=true; break }
            if !matched do continue
        }
        total += 1
        if ch == n do idx = total
    }
    if idx == 0 do return false
    #partial switch c.nth_kind {
    case .Only, .Only_Of_Type:      return total == 1
    case .Child, .Of_Type:          return csspkg.nth_matches(c.nth_a, c.nth_b, idx)
    case .Last_Child, .Last_Of_Type: return csspkg.nth_matches(c.nth_a, c.nth_b, total - idx + 1)
    }
    return true
}

// `:empty` (Selectors 4 §14.3.3): sem filho ELEMENTO e sem texto — espaço em
// branco NÃO conta ("whitespace-only" casa `:empty`, como no Chrome), e
// comentário também não. Antes `:empty` caía no balde de pseudo desconhecida e
// casava TODO elemento; `p:empty{display:none}` escondia todo <p>.
@(private="file")
node_is_empty :: proc(n: ^dompkg.Node) -> bool {
    for ch in n.children {
        #partial switch ch.kind {
        case .Element: return false
        case .Text:
            for i in 0 ..< len(ch.text) {
                switch ch.text[i] {
                case ' ', '\t', '\n', '\r', '\f': continue
                case: return false
                }
            }
        }
    }
    return true
}

// Teto de classes lidas SEM alocar. Elementos de framework utilitário
// (Tailwind) chegam a ~30; acima disso caímos no caminho alocado, que continua
// correto — só volta a custar o que custava antes, num caso raro.
@(private="file")
MAX_INLINE_CLASSES :: 48

// Fatia o atributo `class` do nó em `buf`, SEM alocar: as fatias apontam para a
// string do atributo, que vive no DOM e sobrevive ao casamento. Devolve o
// prefixo preenchido de `buf` (nil se o nó não tem classe).
//
// Separadores: espaço em branco ASCII (space, \t, \n, \r, \f), como manda o
// HTML p/ listas de tokens separados por espaço. É de propósito MAIS estrito
// que o strings.fields de antes, que usava espaço UNICODE e portanto partia
// classes contendo NBSP (U+00A0) — nesse caso o comportamento novo é o correto
// (é o que o Chrome faz), e um NBSP dentro de `class` é a armadilha de
// caractere invisível de sempre.
@(private="file")
node_classes_into :: proc(n: ^dompkg.Node, buf: []string) -> []string {
    cls, ok := n.attrs["class"]
    if !ok || cls == "" do return nil
    is_ws :: proc(b: u8) -> bool { return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' }
    cnt := 0
    i := 0
    for i < len(cls) {
        for i < len(cls) && is_ws(cls[i]) do i += 1
        if i >= len(cls) do break
        start := i
        for i < len(cls) && !is_ws(cls[i]) do i += 1
        if cnt >= len(buf) do return node_classes_slow(cls) // estouro: raro, volta a alocar
        buf[cnt] = cls[start:i]
        cnt += 1
    }
    return buf[:cnt]
}

// Caminho de estouro de node_classes_into (mais de MAX_INLINE_CLASSES classes
// num único elemento). Aloca na arena temp, como o código antigo fazia sempre.
@(private="file")
node_classes_slow :: proc(cls: string) -> []string {
    out := make([dynamic]string, 0, 64, context.temp_allocator)
    for c in strings.fields(cls, context.temp_allocator) do append(&out, c)
    return out[:]
}

// Parseia transform: suporta translateX, translateY e translate.
// Compatibility helper for callers that only need fractional origin terms.
@(private)
parse_transform_origin :: proc(value:string) -> (ox,oy:f32) {
    ox,oy,_,_,_=x_parse_origin(value,16,1280,720)
    return
}

// Estado inicial dos campos que `translate`/`rotate`/`scale`/`transform`
// alimentam. `transform-origin` fica de fora: é outra propriedade.
@(private="file")
transform_reset :: proc(comp: ^Computed) {
    comp.has_transform  = false
    comp.transform_tx   = 0; comp.transform_ty   = 0
    comp.transform_tx_pct = false; comp.transform_ty_pct = false
    comp.xf_percent = {}
    comp.xform = nil
    comp.transform_rot  = 0
    comp.transform_sx   = 1; comp.transform_sy   = 1
    comp.xf_a = 1; comp.xf_b = 0; comp.xf_c = 0; comp.xf_d = 1
    comp.has_xform_matrix = false
    comp.xf_back = false
}

@(private="file")
parse_transform :: proc(comp: ^Computed, value: string, fs: f32, vw: f32, vh: f32) {
    s := strings.trim_space(value)
    if s == "" || strings.equal_fold(s, "none") do return

    // Compose in CSS order: M := M * Mi. Translation is an affine
    // column: T := T + M * Ti. Keep width/height coefficients symbolic
    // until layout resolves the reference box. XList retains all 4D operations
    // for projection and animation; M/T also fill the legacy scalar channels.
    list:=comp.xform
    if list==nil {
        list=new(XList)
        base:=x_base(comp^)
        if base.m != XMatrix(1) || base.pct != ([2]f32{}) do append(&list.ops,base)
    }
    comp.xform=list
    op:=XOp{m=1}
    M: matrix[3, 3]f32 = 1
    lin2 :: proc(a, b, c, d: f32) -> matrix[3, 3]f32 {
        return {a, b, 0,  c, d, 0,  0, 0, 1}
    }
    // Rotação de `a` radianos sobre o eixo (x,y,z) — Rodrigues, na convenção da
    // spec (CSS Transforms 2, rotate3d). Eixo nulo = sem rotação.
    rot3 :: proc(x, y, z, a: f32) -> matrix[3, 3]f32 {
        l := math.sqrt(x*x + y*y + z*z)
        if l == 0 do return 1
        x, y, z := x/l, y/l, z/l
        c, s := f32(math.cos(f64(a))), f32(math.sin(f64(a)))
        t := 1 - c
        return {
            t*x*x + c,   t*x*y - s*z, t*x*z + s*y,
            t*x*y + s*z, t*y*y + c,   t*y*z - s*x,
            t*x*z - s*y, t*y*z + s*x, t*z*z + c,
        }
    }
    cs0, sn0 := f32(math.cos(comp.transform_rot)), f32(math.sin(comp.transform_rot))
    M = lin2(cs0*comp.transform_sx, -sn0*comp.transform_sy, sn0*comp.transform_sx, cs0*comp.transform_sy)
    T: [2]f32
    P := comp.xf_percent
    if comp.transform_tx_pct { P[0] += comp.transform_tx } else { T[0] = comp.transform_tx }
    if comp.transform_ty_pct { P[3] += comp.transform_ty } else { T[1] = comp.transform_ty }
    add_translation :: proc(T: ^[2]f32, P: ^[4]f32, M: matrix[3, 3]f32, x: bool, v: f32, pct: bool, op:^XOp) {
        col := x ? 0 : 1
        if pct { op.pct[col]+=v } else { op.m[col,3]+=v }
        if pct {
            P[col] += M[0, col]*v
            P[2+col] += M[1, col]*v
        } else {
            T[0] += M[0, col]*v
            T[1] += M[1, col]*v
        }
    }
    saw3d := false // alguma função saiu do plano: confere os campos escalares no fim

    i := 0
    n := len(s)
    for i < n {
        // pula whitespace
        for i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') do i += 1
        if i >= n do break

        // localiza o '(' que inicia os args da função
        open := i
        for open < n && s[open] != '(' do open += 1
        if open >= n do break      // sem parêntese → não é uma função

        // matching balanceado: acha o ')' correspondente
        depth := 1
        close := open + 1
        for close < n && depth > 0 {
            if      s[close] == '(' do depth += 1
            else if s[close] == ')' do depth -= 1
            if depth > 0 do close += 1
        }
        if depth != 0 do break     // parênteses desbalanceados

        fn   := strings.trim_space(s[i:open])
        args := strings.trim_space(s[open+1:close])
        i = close + 1

        op=XOp{m=1}
        switch {
        case strings.equal_fold(fn, "translateX"):
            if px, pct, k := parse_len(args, fs, vw, vh); k {
                add_translation(&T, &P, M, true, px, pct, &op); comp.has_transform = true
            }
        case strings.equal_fold(fn, "translateY"):
            if px, pct, k := parse_len(args, fs, vw, vh); k {
                add_translation(&T, &P, M, false, px, pct, &op); comp.has_transform = true
            }
        case strings.equal_fold(fn, "translate"):
            // acha a vírgula no nível superior (fora de qualquer parêntese)
            comma := -1
            d := 0
            for ci in 0 ..< len(args) {
                if      args[ci] == '(' do d += 1
                else if args[ci] == ')' do d -= 1
                else if args[ci] == ',' && d == 0 { comma = ci; break }
            }
            tx_str := strings.trim_space(args if comma < 0 else args[:comma])
            ty_str := strings.trim_space("" if comma < 0 else args[comma+1:])
            if px, pct, k := parse_len(tx_str, fs, vw, vh); k {
                add_translation(&T, &P, M, true, px, pct, &op); comp.has_transform = true
            }
            if ty_str != "" {
                if py, pct, k := parse_len(ty_str, fs, vw, vh); k {
                    add_translation(&T, &P, M, false, py, pct, &op); comp.has_transform = true
                }
            }
        case strings.equal_fold(fn, "rotate") || strings.equal_fold(fn, "rotateZ"):
            a := parse_angle(args)
            op.rotate=true; op.axis={0,0,1}; op.angle=a
            comp.transform_rot += a
            cs, sn := f32(math.cos(a)), f32(math.sin(a))
            N := lin2(cs, -sn, sn, cs)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            comp.has_transform = true
        case strings.equal_fold(fn, "scale"):
            comma := strings.index_byte(args, ',')
            sx, sy: f32 = 1, 1
            if comma < 0 {
                if v, ok := strconv.parse_f64(strings.trim_space(args)); ok { sx = f32(v); sy = f32(v) }
            } else {
                if vx, kx := strconv.parse_f64(strings.trim_space(args[:comma])); kx do sx = f32(vx)
                if vy, ky := strconv.parse_f64(strings.trim_space(args[comma+1:])); ky do sy = f32(vy)
            }
            comp.transform_sx *= sx; comp.transform_sy *= sy; comp.has_transform = true
            N := lin2(sx, 0, 0, sy)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
        case strings.equal_fold(fn, "scaleX"):
            if v, ok := strconv.parse_f64(strings.trim_space(args)); ok {
                comp.transform_sx *= f32(v); comp.has_transform = true
                N := lin2(f32(v), 0, 0, 1)
                M = M * N
                L := x_lift(N)
                for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            }
        case strings.equal_fold(fn, "scaleY"):
            if v, ok := strconv.parse_f64(strings.trim_space(args)); ok {
                comp.transform_sy *= f32(v); comp.has_transform = true
                N := lin2(1, 0, 0, f32(v))
                M = M * N
                L := x_lift(N)
                for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            }
        case strings.equal_fold(fn, "skewX"):
            op.kind=.Skew; op.skew[0]=parse_angle(args)
            t := f32(math.tan(op.skew[0]))
            N := lin2(1, t, 0, 1)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            comp.has_transform = true; comp.has_xform_matrix = true
        case strings.equal_fold(fn, "skewY"):
            op.kind=.Skew; op.skew[1]=parse_angle(args)
            t := f32(math.tan(op.skew[1]))
            N := lin2(1, 0, t, 1)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            comp.has_transform = true; comp.has_xform_matrix = true
        case strings.equal_fold(fn, "skew"):
            comma := strings.index_byte(args, ',')
            ax := parse_angle(comma < 0 ? args : args[:comma])
            ay := comma < 0 ? f32(0) : parse_angle(args[comma+1:])
            op.kind=.Skew; op.skew={ax,ay}
            N := lin2(1, f32(math.tan(ax)), f32(math.tan(ay)), 1)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
            comp.has_transform = true; comp.has_xform_matrix = true
        case strings.equal_fold(fn, "matrix"):
            // matrix(a,b,c,d,e,f) — coluna-maior: linear [a c; b d], translate (e,f)
            f := strings.split(args, ",", context.temp_allocator)
            if len(f) == 6 {
                p: [6]f32
                allok := true
                for k in 0 ..< 6 { if v, ok := strconv.parse_f64(strings.trim_space(f[k])); ok do p[k] = f32(v); else do allok = false }
                if allok {
                    add_translation(&T, &P, M, true, p[4], false, &op)
                    add_translation(&T, &P, M, false, p[5], false, &op)
                    N := lin2(p[0], p[2], p[1], p[3])
                    M = M * N
                    L := x_lift(N)
                    for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
                    comp.has_transform = true; comp.has_xform_matrix = true
                }
            }
        // ── 3D, achatado por projeção ortográfica (ver o comentário do topo) ──
        case strings.equal_fold(fn, "translate3d"):
            f := split_commas_top(args)
            if len(f) == 3 {
                if z,pct,k:=parse_len(f[2],fs,vw,vh); k && !pct do op.m[2,3]=z
                list.spatial=true
                if px, pct, k := parse_len(f[0], fs, vw, vh); k {
                    add_translation(&T, &P, M, true, px, pct, &op); comp.has_transform = true
                }
                if py, pct, k := parse_len(f[1], fs, vw, vh); k {
                    add_translation(&T, &P, M, false, py, pct, &op); comp.has_transform = true
                }
            }
        case strings.equal_fold(fn, "translateZ"):
            if z,pct,k:=parse_len(args,fs,vw,vh); k && !pct do op.m[2,3]=z
            list.spatial=true
            comp.has_transform=true
        case strings.equal_fold(fn, "perspective"):
            if d,pct,k:=parse_len(args,fs,vw,vh); k && !pct && d>0 do op.m[3,2]=-1/max(d,1)
            list.spatial=true
            // Nada a desenhar, mas o elemento TEM transform: `translateZ(0)` é o
            // idioma de "promover a layer" e cria stacking context e containing
            // block como qualquer outro.
            comp.has_transform = true
        case strings.equal_fold(fn, "scale3d"):
            f := split_commas_top(args)
            if len(f) == 3 {
                vx, kx := strconv.parse_f64(f[0]); vy, ky := strconv.parse_f64(f[1]); vz, kz := strconv.parse_f64(f[2])
                if kx && ky && kz {
                    comp.transform_sx *= f32(vx); comp.transform_sy *= f32(vy); comp.has_transform = true
                    N := matrix[3, 3]f32{f32(vx), 0, 0,  0, f32(vy), 0,  0, 0, f32(vz)}
                    M = M * N
                    L := x_lift(N)
                    for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
                    saw3d = true // z negativo vira a face (ver o cálculo do lado, no fim)
                }
            }
        case strings.equal_fold(fn, "scaleZ"):
            if v, ok := strconv.parse_f64(args); ok {
                comp.has_transform = true
                N := matrix[3, 3]f32{1, 0, 0,  0, 1, 0,  0, 0, f32(v)}
                M = M * N
                L := x_lift(N)
                for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
                saw3d = true
            }
        case strings.equal_fold(fn, "rotateX"):
            // No plano: encolhe Y por cos θ. O campo escalar recebe o mesmo fator
            // p/ a transition poder animar o giro (aproximado por um "achatar").
            a := parse_angle(args)
            op.rotate=true; op.axis={1,0,0}; op.angle=a
            comp.transform_sy *= f32(math.cos(f64(a))); comp.has_transform = true
            N := rot3(1, 0, 0, a)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }; saw3d = true
        case strings.equal_fold(fn, "rotateY"):
            a := parse_angle(args)
            op.rotate=true; op.axis={0,1,0}; op.angle=a
            comp.transform_sx *= f32(math.cos(f64(a))); comp.has_transform = true
            N := rot3(0, 1, 0, a)
            M = M * N
            L := x_lift(N)
            for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }; saw3d = true
        case strings.equal_fold(fn, "rotate3d"):
            f := split_commas_top(args)
            if len(f) == 4 {
                vx, kx := strconv.parse_f64(f[0]); vy, ky := strconv.parse_f64(f[1]); vz, kz := strconv.parse_f64(f[2])
                if kx && ky && kz {
                    x, y, z := f32(vx), f32(vy), f32(vz)
                    a := parse_angle(f[3])
                    op.rotate=true; op.axis={x,y,z}; op.angle=a
                    cs := f32(math.cos(f64(a)))
                    // eixo puro → os mesmos campos de rotateX/Y/Z; eixo oblíquo
                    // não tem forma escalar (a conferência do fim liga a matriz).
                    switch {
                    case x == 0 && y == 0 && z != 0: comp.transform_rot += z < 0 ? -a : a
                    case y == 0 && z == 0 && x != 0: comp.transform_sy *= cs
                    case x == 0 && z == 0 && y != 0: comp.transform_sx *= cs
                    }
                    comp.has_transform = true
                    N := rot3(x, y, z, a)
                    M = M * N
                    L := x_lift(N)
                    for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }; saw3d = true
                }
            }
        case strings.equal_fold(fn, "matrix3d"):
            // 16 valores em coluna-maior: a coluna j é (v[4j], v[4j+1], v[4j+2]);
            // a 4ª coluna é a translação. A 4ª LINHA (v3,v7,v11) é a perspectiva,
            // descartada; v15 é o divisor homogêneo.
            f := split_commas_top(args)
            if len(f) == 16 {
                p: [16]f32
                allok := true
                for k in 0 ..< 16 { if v, ok := strconv.parse_f64(f[k]); ok do p[k] = f32(v); else do allok = false }
                if allok {
                    list.spatial=true
                    w := p[15]!=0 ? 1 / p[15] : 1
                    add_translation(&T, &P, M, true, p[12]*w, false, &op)
                    add_translation(&T, &P, M, false, p[13]*w, false, &op)
                    N := matrix[3, 3]f32{
                        p[0]*w, p[4]*w, p[8]*w,
                        p[1]*w, p[5]*w, p[9]*w,
                        p[2]*w, p[6]*w, p[10]*w,
                    }
                    M = M * N
                    L := x_lift(N)
                    for r in 0..<3 { for c in 0..<3 { op.m[r,c]=L[r,c] } }
                    comp.has_transform = true; comp.has_xform_matrix = true; saw3d = true
                    for r in 0..<4 { for c in 0..<4 { op.m[r,c]=p[c*4+r] } }
                }
            }
        }
        if strings.has_prefix(strings.to_lower(fn,context.temp_allocator),"translate") { op.kind=.Translate }
        else if strings.has_prefix(strings.to_lower(fn,context.temp_allocator),"scale") { op.kind=.Scale }
        else if op.rotate { op.kind=.Rotate }
        else if strings.equal_fold(fn,"perspective") { op.kind=.Perspective }
        if saw3d do list.spatial=true
        append(&list.ops,op)
    }
    comp.transform_tx = T[0]; comp.transform_ty = T[1]
    comp.transform_tx_pct = false; comp.transform_ty_pct = false
    // Retain the compact representation for a pure own-axis percentage.
    if T[0] == 0 && P[1] == 0 { comp.transform_tx = P[0]; comp.transform_tx_pct = P[0] != 0; P[0] = 0 }
    if T[1] == 0 && P[2] == 0 { comp.transform_ty = P[3]; comp.transform_ty_pct = P[3] != 0; P[3] = 0 }
    comp.xf_percent = P
    comp.xf_a = M[0, 0]; comp.xf_b = M[0, 1]; comp.xf_c = M[1, 0]; comp.xf_d = M[1, 1]
    if saw3d {
        // LADO: a normal (0,0,1) transformada tem z = cofator(3,3)/det. Negativo =
        // a face de trás está voltada p/ o observador. É o bit que a projeção
        // perde (`rotateY(180deg)` × `scaleX(-1)`) e que backface-visibility lê.
        // XOR, e não atribuição: a prop individual `rotate` pode já ter virado.
        det := M[0, 0]*(M[1, 1]*M[2, 2] - M[1, 2]*M[2, 1]) -
               M[0, 1]*(M[1, 0]*M[2, 2] - M[1, 2]*M[2, 0]) +
               M[0, 2]*(M[1, 0]*M[2, 1] - M[1, 1]*M[2, 0])
        cof := M[0, 0]*M[1, 1] - M[0, 1]*M[1, 0]
        if det != 0 && (cof < 0) != (det < 0) do comp.xf_back = !comp.xf_back
    }
    // Use the scalar animation path only when R*S represents the full product,
    // including 2D lists such as scaleX(2) rotate(45deg).
    if !comp.has_xform_matrix {
        cs, sn := f32(math.cos(comp.transform_rot)), f32(math.sin(comp.transform_rot))
        EPS :: 1e-4
        if abs(cs*comp.transform_sx - comp.xf_a) > EPS || abs(-sn*comp.transform_sy - comp.xf_b) > EPS ||
           abs(sn*comp.transform_sx - comp.xf_c) > EPS || abs(cs*comp.transform_sy - comp.xf_d) > EPS {
            comp.has_xform_matrix = true
        }
    }
}

// Fatia os argumentos de uma função nas vírgulas de NÍVEL SUPERIOR (as de dentro
// de `calc()`/`var()` não contam), já sem espaços nas pontas.
@(private="file")
split_commas_top :: proc(args: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    d, start := 0, 0
    for i in 0 ..< len(args) {
        switch args[i] {
        case '(': d += 1
        case ')': d -= 1
        case ',':
            if d == 0 { append(&out, strings.trim_space(args[start:i])); start = i + 1 }
        }
    }
    append(&out, strings.trim_space(args[start:]))
    return out[:]
}

// Converte um ângulo CSS (Ndeg/Nrad/Nturn/Ngrad; nº puro = graus) em radianos.
@(private="file")
parse_angle :: proc(s: string) -> f32 {
    t := strings.to_lower(strings.trim_space(s), context.temp_allocator)
    if strings.has_suffix(t, "deg") {
        if v, ok := strconv.parse_f64(t[:len(t)-3]); ok do return f32(v) * math.PI / 180
    } else if strings.has_suffix(t, "turn") {
        if v, ok := strconv.parse_f64(t[:len(t)-4]); ok do return f32(v) * 2 * math.PI
    } else if strings.has_suffix(t, "grad") {
        if v, ok := strconv.parse_f64(t[:len(t)-4]); ok do return f32(v) * math.PI / 200
    } else if strings.has_suffix(t, "rad") {
        if v, ok := strconv.parse_f64(t[:len(t)-3]); ok do return f32(v)
    } else if v, ok := strconv.parse_f64(t); ok {
        return f32(v) * math.PI / 180 // nº puro: assume graus (lenient)
    }
    return 0
}

// box-shadow: lista separada por vírgula de "[inset] dx dy [blur] [spread] [cor]".
// Sombras inset são ignoradas (não suportadas). Guarda até MAX_SHADOWS externas.
@(private="file")
parse_box_shadow :: proc(comp: ^Computed, value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) {
    comp.shadow_n = 0
    v := strings.trim_space(value)
    if v == "" || strings.equal_fold(v, "none") do return
    for part in split_commas_paren(v) {
        if comp.shadow_n >= MAX_SHADOWS do break
        if sh, ok := parse_one_shadow(part, fs, comp.color, vw, vh); ok {
            // Pula camadas de geometria ZERO (dx=dy=blur=spread=0) — invisíveis
            // (o retângulo cai exatamente atrás da caixa, ocluso). Tailwind v4 usa
            // `0 0 #0000` como default de CADA slot da cadeia (--tw-inset-shadow,
            // --tw-ring-shadow…) e a sombra REAL é a última: sem pular, as 4-5
            // camadas-ruído estouravam MAX_SHADOWS e descartavam a sombra real.
            if sh.dx == 0 && sh.dy == 0 && sh.blur == 0 && sh.spread == 0 do continue
            comp.shadows[comp.shadow_n] = sh
            comp.shadow_n += 1
        }
    }
}

// text-shadow: lista separada por vírgula de "[cor] dx dy [blur]" (sem spread/
// inset). HERDA — "none"/vazio zera (sobrepõe o herdado). Cor ausente = cor do
// texto (currentColor). Sem blur real (aproximado como offset nítido na pintura).
@(private="file")
parse_text_shadow :: proc(comp: ^Computed, value: string, fs: f32, vw: f32 = 1280, vh: f32 = 720) {
    v := strings.trim_space(value)
    comp.text_shadow_n = 0
    if v == "" || strings.equal_fold(v, "none") do return
    for part in split_commas_paren(v) {
        if comp.text_shadow_n >= MAX_SHADOWS do break
        sh: Shadow
        nums: [3]f32
        nn := 0
        got_color := false
        for tok in fields_paren(strings.trim_space(part)) {
            if px, _, k := parse_len(tok, fs, vw, vh); k {
                if nn < 3 { nums[nn] = px; nn += 1 }
                continue
            }
            if c, k := parse_color_cc(tok, comp.color); k && !got_color {
                sh.color = c; got_color = true
            }
        }
        if nn < 2 do continue // precisa dx e dy
        sh.dx = nums[0]; sh.dy = nums[1]
        if nn >= 3 do sh.blur = nums[2]
        if !got_color do sh.color = comp.color // currentColor
        comp.text_shadows[comp.text_shadow_n] = sh
        comp.text_shadow_n += 1
    }
}

@(private="file")
parse_one_shadow :: proc(part: string, fs: f32, cur: u32 = 0, vw: f32 = 1280, vh: f32 = 720) -> (Shadow, bool) {
    sh := Shadow{color = cur}
    nums: [4]f32
    nn := 0
    got_color := false
    is_inset := false
    for tok in fields_paren(strings.trim_space(part)) {
        if strings.equal_fold(tok, "inset") { is_inset = true; continue }
        // tenta comprimento primeiro (dx/dy/blur/spread), depois cor
        if px, _, k := parse_len(tok, fs, vw, vh); k {
            if nn < 4 { nums[nn] = px; nn += 1 }
            continue
        }
        if c, k := parse_color_cc(tok, cur); k && !got_color {
            sh.color = c; got_color = true
            continue
        }
    }
    if nn < 2   do return sh, false // precisa ao menos dx e dy
    sh.inset = is_inset
    sh.dx = nums[0]; sh.dy = nums[1]
    if nn >= 3 do sh.blur   = nums[2]
    if nn >= 4 do sh.spread = nums[3]
    return sh, true
}

// Separa por vírgulas no nível superior (ignora vírgulas dentro de parênteses,
// ex.: rgba(0,0,0,.3)). Usa o temp allocator do frame.
@(private="file")
split_commas_paren :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth := 0
    start := 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',': if depth == 0 { append(&out, s[start:i]); start = i + 1 }
        }
    }
    append(&out, s[start:])
    return out[:]
}

// Separa por espaços no nível superior (mantém rgba(...) inteiro).
@(private="file")
fields_paren :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth := 0
    start := -1
    for i in 0 ..< len(s) {
        ch := s[i]
        if      ch == '(' do depth += 1
        else if ch == ')' do depth -= 1
        sep := depth == 0 && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
        if sep {
            if start >= 0 { append(&out, s[start:i]); start = -1 }
        } else if start < 0 {
            start = i
        }
    }
    if start >= 0 do append(&out, s[start:])
    return out[:]
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers de teste. Ficam aqui (mesma file) para alcançar os procs file-private
// parse_len / apply_decls / parse_font_size. Chamados por style_test.odin.
// ─────────────────────────────────────────────────────────────────────────────

// Extrai a 1ª duração (ex.: "0.3s", "200ms") de um valor de transition. Devolve
// segundos (0 se nenhuma). Ignora nomes de prop/timing-function/vírgulas.
@(private="file")
parse_duration :: proc(v: string) -> f32 {
    toks := strings.fields(strings.to_lower(v, context.temp_allocator), context.temp_allocator)
    for tok in toks {
        t := strings.trim_right(tok, ",")
        if strings.has_suffix(t, "ms") {
            if n, ok := strconv.parse_f64(t[:len(t) - 2]); ok do return f32(n) / 1000.0
        } else if strings.has_suffix(t, "s") {
            if n, ok := strconv.parse_f64(t[:len(t) - 1]); ok do return f32(n)
        }
    }
    return 0
}

// Parseia um ÚNICO token de tempo ("2s", "200ms"). ok=false se não for tempo.
// (visível no pacote: transition.odin também tokeniza tempo)
parse_time_token :: proc(t: string) -> (f32, bool) {
    if strings.has_suffix(t, "ms") {
        if n, ok := strconv.parse_f64(t[:len(t) - 2]); ok do return f32(n) / 1000.0, true
    } else if strings.has_suffix(t, "s") {
        if n, ok := strconv.parse_f64(t[:len(t) - 1]); ok do return f32(n), true
    }
    return 0, false
}

// keywords de animation que NÃO são nome (timing/direction/fill/play-state).
@(private="file")
is_anim_keyword :: proc(t: string) -> bool {
    switch t {
    case "ease","ease-in","ease-out","ease-in-out","linear","step-start","step-end",
         "normal","reverse","alternate","alternate-reverse",
         "forwards","backwards","both","none","running","paused","infinite":
        return true
    }
    return strings.contains(t, "(") // cubic-bezier(...)/steps(...)
}

// Resolve `animation`/@keyframes p/ este nó: acha o keyframe set e baka os stops
// das props de PINTURA (opacity/cor/fundo) em comp.anim. Anima por frame na pintura.
@(private="file")
first_animation_value :: proc(v: string) -> string {
    items := split_commas_paren(v)
    return len(items) > 0 ? strings.trim_space(items[0]) : ""
}

resolve_animation :: proc(comp: ^Computed, decls: map[string]string, kf: []csspkg.Keyframe_Set, vars: map[string]string, vw, vh: f32) {
    if len(kf) == 0 do return
    if _, ok := decls["animation"]; !ok {
        if _, named := decls["animation-name"]; !named do return
    }
    sh := split_commas_paren(resolve_var(decls["animation"], vars))
    count := len(sh)
    if v, ok := decls["animation-name"]; ok do count = len(split_commas_paren(resolve_var(v, vars)))
    if count == 0 do return
    if count > 1 do comp.anim_more = make([]Anim, count - 1, context.temp_allocator)
    for i in 0 ..< count {
        one := make(map[string]string, context.temp_allocator)
        if len(sh) > 0 do one["animation"] = sh[i % len(sh)]
        for prop, raw in decls {
            if !strings.has_prefix(prop, "animation-") do continue
            vals := split_commas_paren(resolve_var(raw, vars))
            if len(vals) > 0 do one[prop] = vals[i % len(vals)]
        }
        tmp := comp^
        tmp.anim = {}; tmp.anim_more = nil
        resolve_animation_one(&tmp, one, kf, vars, vw, vh)
        if i == 0 { comp.anim = tmp.anim } else { comp.anim_more[i - 1] = tmp.anim }
    }
}

resolve_animation_one :: proc(comp: ^Computed, decls: map[string]string, kf: []csspkg.Keyframe_Set, vars: map[string]string, vw, vh: f32) {
    if len(kf) == 0 do return
    name := ""
    dur, delay: f32 = 0, 0
    iter: f32 = 1
    infinite := false
    alt := false
    rev, before, after, paused := false, false, false, false
    timing := TIMING_DEFAULT

    if v, ok := decls["animation"]; ok {
        rv := resolve_var(v, vars)
        rv = first_animation_value(rv)
        time_seen := 0
        for raw_tok in fields_paren(rv) {
            tok := strings.to_lower(raw_tok, context.temp_allocator)
            if d, isd := parse_time_token(tok); isd {
                if time_seen == 0 do dur = d
                else              do delay = d
                time_seen += 1
            } else if tok == "infinite" {
                iter = 0
                infinite = true
            } else if n, isn := strconv.parse_f64(tok); isn {
                iter = f32(n)
            } else if tok == "alternate" || tok == "alternate-reverse" {
                alt = true
                rev = tok == "alternate-reverse"
            } else if tok == "reverse" {
                rev = true
            } else if tok == "forwards" || tok == "backwards" || tok == "both" {
                before = tok != "forwards"; after = tok != "backwards"
            } else if tok == "paused" {
                paused = true
            } else if tm, valid := parse_timing(tok); valid {
                timing = tm
            } else if is_anim_keyword(tok) {
                // ignora timing/fill/etc
            } else if name == "" {
                name = raw_tok
            }
        }
    }
    if v, ok := decls["animation-name"]; ok do name = strings.trim_space(first_animation_value(resolve_var(v, vars)))
    if v, ok := decls["animation-duration"]; ok do dur = parse_duration(resolve_var(v, vars))
    if v, ok := decls["animation-delay"]; ok do delay = parse_duration(resolve_var(v, vars))
    if v, ok := decls["animation-iteration-count"]; ok {
        iv := strings.to_lower(strings.trim_space(resolve_var(v, vars)), context.temp_allocator)
        infinite = iv == "infinite"
        if infinite do iter = 0
        else if nn, k := strconv.parse_f64(iv); k do iter = f32(nn)
    }
    if v, ok := decls["animation-direction"]; ok {
        direction := strings.trim_space(first_animation_value(resolve_var(v, vars)))
        alt = direction == "alternate" || direction == "alternate-reverse"
        rev = direction == "reverse" || direction == "alternate-reverse"
    }
    if v, ok := decls["animation-timing-function"]; ok {
        if tm, valid := parse_timing(strings.trim_space(first_animation_value(resolve_var(v, vars)))); valid do timing = tm
    }
    if v, ok := decls["animation-fill-mode"]; ok {
        fill := strings.trim_space(first_animation_value(resolve_var(v, vars)))
        before = fill == "backwards" || fill == "both"
        after = fill == "forwards" || fill == "both"
    }
    if v, ok := decls["animation-play-state"]; ok do paused = strings.trim_space(first_animation_value(resolve_var(v, vars))) == "paused"

    if name == "" || name == "none" || dur < 0 || (!infinite && iter < 0) do return
    set: ^csspkg.Keyframe_Set
    for &s in kf do if s.name == name { set = &s; break }
    if set == nil do return

    comp.anim.zero_iterations = !infinite && iter == 0
    comp.anim.name = name
    comp.anim.dur = dur; comp.anim.delay = delay; comp.anim.iter = iter; comp.anim.alternate = alt
    comp.anim.reverse = rev; comp.anim.fill_before = before; comp.anim.fill_after = after
    comp.anim.timing = timing; comp.anim.paused = paused
    comp.anim.n = 0
    comp.anim.underlying = Anim_Stop{
        opacity = comp.opacity, color = comp.color, bg = comp.bg,
        rot = comp.transform_rot, sx = comp.transform_sx, sy = comp.transform_sy,
        xform = comp.xform,
        tx = comp.transform_tx_pct ? 0 : comp.transform_tx,
        ty = comp.transform_ty_pct ? 0 : comp.transform_ty,
        tx_percent = comp.transform_tx_pct ? comp.transform_tx : 0,
        ty_percent = comp.transform_ty_pct ? comp.transform_ty : 0,
    }
    for st in set.stops {
        if comp.anim.n >= ANIM_MAX_STOPS do break
        as := Anim_Stop{ pct = st.pct }
        if tv, ok := st.decls["animation-timing-function"]; ok {
            if tm, valid := parse_timing(strings.trim_space(resolve_var(tv, vars))); valid {
                as.has_timing = true; as.timing = tm
            }
        }
        if ov, ok := st.decls["opacity"]; ok {
            if f, k := strconv.parse_f64(strings.trim_space(resolve_var(ov, vars))); k { as.has_opacity = true; as.opacity = clamp(f32(f), 0, 1) }
        }
        if cv, ok := st.decls["color"]; ok {
            if c, k := csspkg.parse_color(resolve_var(cv, vars)); k { as.has_color = true; as.color = c }
        }
        bg := ""
        if v, ok := st.decls["background-color"]; ok do bg = v
        else if v, ok := st.decls["background"]; ok do bg = v
        if bg != "" {
            if c, k := csspkg.parse_color(resolve_var(bg, vars)); k { as.has_bg = true; as.bg = c }
        }
        if tv, ok := st.decls["transform"]; ok {
            tmp := Computed{transform_sx = 1, transform_sy = 1}
            parse_transform(&tmp, resolve_var(tv, vars), comp.font_size, vw, vh)
            as.has_xform=true; as.xform=tmp.xform
            as.has_translate = true
            as.tx = tmp.transform_tx_pct ? 0 : tmp.transform_tx
            as.ty = tmp.transform_ty_pct ? 0 : tmp.transform_ty
            as.tx_percent = tmp.transform_tx_pct ? tmp.transform_tx : 0
            as.ty_percent = tmp.transform_ty_pct ? tmp.transform_ty : 0
            as.has_rot = true; as.rot = tmp.transform_rot
            as.has_scale = true; as.sx = tmp.transform_sx; as.sy = tmp.transform_sy
        }
        comp.anim.stops[comp.anim.n] = as
        comp.anim.n += 1
    }
    comp.anim.active = comp.anim.n > 0 // implicit endpoints permit a single keyframe
}

// Como test_compute_one, mas com um ATRIBUTO arbitrário no elemento — p/ testar
// os atributos de APRESENTAÇÃO legados (`<font size>`, `bgcolor`, `width`), que
// não passam pelo CSS e por isso nenhum helper existente alcançava.
test_compute_attr :: proc(css_text: string, tag: string, attr: string, val: string) -> Computed {
    rules, _ := csspkg.parse(css_text)
    n := dompkg.make_node(.Element)
    n.tag = tag
    n.attrs = make(map[string]string, context.temp_allocator)
    n.attrs[attr] = val
    styles, _ := compute_styles(n, &rules)
    return styles[n]
}

// Expõe computed_initial p/ os testes (ele é @(private="file")). Serve p/ afirmar
// que ele NÃO diverge do bloco de reset das não-herdadas de compute_node — a
// divergência valia para `all: initial` e para toda medição feita com test_apply.
test_computed_initial :: proc() -> Computed { return computed_initial() }

// Expõe parse_len p/ os testes. fs = font-size do contexto (em px).
test_parse_len :: proc(value: string, fs: f32 = 16, vw: f32 = 1280, vh: f32 = 720) -> (px: f32, pct: bool, ok: bool) {
    return parse_len(value, fs, vw, vh)
}

// Aplica uma lista de declarações ("prop: val; prop2: val2") a um Computed
// padrão e devolve o resultado. vars_text define custom props ("--x: 4px").
test_apply :: proc(decls_text: string, vars_text := "") -> Computed {
    comp := computed_initial()
    decls := csspkg.parse_decls(decls_text, context.temp_allocator)
    vars  := csspkg.parse_decls(vars_text,  context.temp_allocator)
    apply_decls(&comp, decls, vars)
    return comp
}

// Aplica declarações SOBRE um Computed já montado — é o que o pipeline real faz
// depois do `apply_ua_defaults`. Os testes usam p/ medir o que o autor RESETA do UA
// (ex.: `background: 0 0` sobre o fundo que o UA dá ao <button>).
test_apply_over :: proc(base: Computed, decls_text: string, vars_text := "") -> Computed {
    comp := base
    decls := csspkg.parse_decls(decls_text, context.temp_allocator)
    vars  := csspkg.parse_decls(vars_text,  context.temp_allocator)
    apply_decls(&comp, decls, vars)
    return comp
}

// Expõe parse_font_size p/ os testes.
test_parse_font_size :: proc(value: string, parent: f32 = 16, vw: f32 = 1280, vh: f32 = 720) -> (f32, bool) {
    return parse_font_size(value, parent, vw, vh)
}

// Expõe grid_resolve_named p/ os testes (resolução de grid-column/row nomeado
// contra a tabela de linhas do container).
test_grid_resolve_named :: proc(names: []string, at: []int, start_name, end_name: string) -> (start, span: int, ok: bool) {
    lines: [GRID_MAX_LINES]Grid_Line
    n := min(len(names), GRID_MAX_LINES)
    for i in 0 ..< n do lines[i] = Grid_Line{name = names[i], line = at[i]}
    return grid_resolve_named(lines[:n], start_name, end_name)
}

test_grid_resolve_negative :: proc(start, span, end_line, n: int) -> (int, int) {
    return grid_resolve_negative(start, span, end_line, n)
}

// Como test_compute_one, mas monta PAI + FILHO e devolve o Computed do FILHO.
// Necessário para item de grid: a linha negativa e a nomeada só resolvem contra o
// nº de tracks / as linhas do CONTAINER, então um elemento sozinho não exercita o
// caminho de verdade.
test_compute_child :: proc(css_text: string, parent_cls := "g", child_cls := "i") -> Computed {
    rules, _ := csspkg.parse(css_text)
    parent := dompkg.make_node(.Element)
    parent.tag = "div"
    parent.attrs = make(map[string]string, context.temp_allocator)
    parent.attrs["class"] = parent_cls
    child := dompkg.make_node(.Element)
    child.tag = "div"
    child.attrs = make(map[string]string, context.temp_allocator)
    child.attrs["class"] = child_cls
    dompkg.append_child(parent, child)
    styles, _ := compute_styles(parent, &rules)
    return styles[child]
}

// Como test_compute_child, mas o FILHO leva um nó de texto dentro. É o que
// distingue `:empty` de verdade (filho vazio × filho com conteúdo) — sem texto
// no DOM os dois casos seriam o mesmo elemento.
test_compute_child_text :: proc(css_text: string, parent_cls := "g", child_cls := "i", txt := "x") -> Computed {
    rules, _ := csspkg.parse(css_text)
    parent := dompkg.make_node(.Element)
    parent.tag = "div"
    parent.attrs = make(map[string]string, context.temp_allocator)
    parent.attrs["class"] = parent_cls
    child := dompkg.make_node(.Element)
    child.tag = "div"
    child.attrs = make(map[string]string, context.temp_allocator)
    child.attrs["class"] = child_cls
    dompkg.append_child(parent, child)
    if txt != "" {
        tn := dompkg.make_node(.Text)
        tn.text = txt
        dompkg.append_child(child, tn)
    }
    styles, _ := compute_styles(parent, &rules)
    return styles[child]
}

// Roda a pipeline real (collect_decls -> apply_decls) para um único elemento
// <tag class="cls">. Necessário para testar o que só ocorre em collect_decls,
// como o aliasing de propriedades lógicas (não passa por test_apply).
test_compute_one :: proc(css_text: string, tag := "div", cls := "", style := "") -> Computed {
    rules, _ := csspkg.parse(css_text)
    n := dompkg.make_node(.Element)
    n.tag = tag
    n.attrs = make(map[string]string, context.temp_allocator)
    if cls != "" do n.attrs["class"] = cls
    if style != "" do n.attrs["style"] = style
    styles, _ := compute_styles(n, &rules)
    return styles[n]
}

// Como test_compute_one, mas passa os @keyframes coletados (p/ testar animation).
test_compute_anim :: proc(css_text: string, tag := "div", cls := "") -> Computed {
    rules, kf := csspkg.parse(css_text)
    defer csspkg.free_keyframes(&kf)
    n := dompkg.make_node(.Element)
    n.tag = tag
    n.attrs = make(map[string]string, context.temp_allocator)
    if cls != "" do n.attrs["class"] = cls
    styles, _ := compute_styles(n, &rules, 1280, 720, kf[:])
    return styles[n]
}

// Monta <tag>texto</tag> (elemento com filho de texto), roda compute_styles na
// ÁRVORE inteira e conta quantos ponteiros ^Computed de pseudo (before/after)
// aparecem em mais de uma entrada do mapa. >0 = aliasing → free_styles daria
// double free. Guarda de regressão do crash de navegação (::before herdado por
// nós que não são Element). Devolve (nós no mapa, ponteiros compartilhados).
test_pseudo_alias :: proc(css_text: string, tag := "div") -> (n_nodes: int, shared: int) {
    rules, _ := csspkg.parse(css_text)
    parent := dompkg.make_node(.Element)
    parent.tag = tag
    parent.attrs = make(map[string]string, context.temp_allocator)
    txt := dompkg.make_node(.Text)
    txt.text = "texto"
    dompkg.append_child(parent, txt)

    styles, _ := compute_styles(parent, &rules)
    n_nodes = len(styles)

    seen: map[rawptr]bool
    defer delete(seen)
    for _, comp in styles {
        for p in ([]rawptr{comp.before, comp.after}) {
            if p == nil do continue
            if seen[p] do shared += 1
            seen[p] = true
        }
    }
    return
}

// ── querySelector: ponte p/ o pacote js ─────────────────────────────────────
// O js não pode importar ui/css (ciclo), então injetamos o matcher CSS real
// como hook. @(init) roda antes do main de qualquer binário que importe ui.

@(init)
install_js_query_hook :: proc "contextless" () {
    jspkg.g_dom_query = js_dom_query
    jspkg.g_selector_valid = csspkg.selectors_valid
    jspkg.g_dom_matches = js_dom_matches
    jspkg.g_css_supports = css_supports_decl // CSS.supports (css_om.odin) — mesma razão de ciclo
    jspkg.g_computed_style = js_computed_style // getComputedStyle (computed_om.odin) — idem
    jspkg.g_element_rect   = js_element_rect   // getBoundingClientRect  (idem)
    jspkg.g_element_metric = js_element_metric // offsetWidth/clientHeight/... (idem)
    jspkg.g_element_box    = js_element_box    // as duas caixas p/ o ResizeObserver (idem)
    jspkg.g_page_scroll    = js_scroll_get     // window.scrollY/pageYOffset (idem)
    jspkg.g_viewport_dims  = js_viewport_dims  // raiz implícita do IntersectionObserver (idem)
    jspkg.g_media_match    = js_media_matches  // window.matchMedia — MESMO motor do @media (idem)
    jspkg.g_parse_color    = js_canvas_color   // canvas 2D: MESMO parser de cor do CSS (canvas2d.odin)
    jspkg.g_measure_text   = js_canvas_measure // canvas 2D: measureText na fonte REAL (idem)
    csspkg.g_prop_supported = css_supports_decl // @supports (css/supports.odin) — MESMA proc: uma
                                                // resposta só p/ a at-rule e p/ o CSS.supports() do JS
}

// A resposta única de "o motor implementa esta declaração?" — serve tanto ao
// `@supports` (avaliado no parse, css/supports.odin) quanto ao `CSS.supports()`
// do JS. Recebe a propriedade JÁ em minúsculas.
//
// Shared value grammar first, then implementation capability checks. Grammars
// not yet covered retain the legacy parser policy; see docs/CSS-VALUES.md.
css_supports_decl :: proc(raw_prop: string, raw_value: string) -> bool {
    prop := strings.to_lower(strings.trim_space(csspkg.declaration_text(raw_prop)), context.temp_allocator)
    value := csspkg.declaration_text(raw_value)
    if valid, _ := css_value_valid(prop, value); !valid do return false
    if strings.has_prefix(prop, "--") do return true // custom property: nós parseamos
    if !css_prop_is_known(prop) do return false
    v := strings.to_lower(strings.trim_space(value), context.temp_allocator)
    if v == "" do return false
    if value_has_unsupported_unit(v) do return false
    if value_has_unsupported_fn(v) do return false
    // Recognizing a property for diagnostics is not implementation support.
    switch prop {
    case "touch-action", "hyphens", "-webkit-hyphens", "font-variation-settings",
         "font-feature-settings", "scroll-snap-type", "scroll-snap-align", "scroll-snap-stop",
         "transform-style":
        return false
    }
    if valid, checked := css_value_valid(prop, value); checked do return valid

    return true
}

// Unidades de COMPRIMENTO que o `parse_len` não converte — declaração com uma
// delas é descartada na cascata. ⚠️ ESTA LISTA É O ESPELHO do switch de unidades
// do parse_len: ao implementar uma unidade lá, tire-a daqui (o teste
// `test_supports_unidades_espelham_parse_len` falha se as duas divergirem).
// Só unidades de comprimento entram: `deg`/`s`/`ms`/`fr` têm parsers próprios.
@(private = "file")
value_has_unsupported_unit :: proc(v: string) -> bool {
    i := 0
    for i < len(v) {
        c := v[i]
        if !((c >= '0' && c <= '9') || c == '.') { i += 1; continue }
        if i > 0 { // dígito no meio de um identificador (translate3d, #00ff00) não é número
            p := v[i - 1]
            if (p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') || p == '#' || p == '_' {
                i += 1
                continue
            }
            // '-' pode ser SINAL (`-1cm`) ou hífen de identificador (`url(a-2in.png)`,
            // `--var-2in`). Decide pelo que vem ANTES do hífen.
            if p == '-' && i >= 2 {
                q := v[i - 2]
                if (q >= 'a' && q <= 'z') || (q >= 'A' && q <= 'Z') || (q >= '0' && q <= '9') ||
                   q == '-' || q == '_' {
                    i += 1
                    continue
                }
            }
        }
        e := csspkg.scan_number_end(v, i, false)
        if e == i { i += 1; continue }
        u := e
        for u < len(v) && ((v[u] >= 'a' && v[u] <= 'z') || (v[u] >= 'A' && v[u] <= 'Z')) do u += 1
        if u > e {
            switch v[e:u] { // `v` já veio em minúsculas
            // `cm`/`mm`/`in`/`pc`/`q` SAÍRAM daqui no M238: o parse_len passou a
            // convertê-las (todas ancoradas em 1in = 96px), então afirmá-las no
            // @supports virou verdade. Restam as que dependem de métrica de fonte
            // (`ch`), da raiz (`rlh`) ou do contêiner de consulta (`cq*`).
            case "ch", "rlh", "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax":
                return true
            }
        }
        i = max(u, e)
    }
    return false
}

// Funções de valor que o motor não avalia (a declaração inteira cai).
@(private = "file")
value_has_unsupported_fn :: proc(v: string) -> bool {
    for i := 0; i < len(v); i += 1 {
        if v[i] != '(' do continue
        s := i
        for s > 0 {
            c := v[s - 1]
            if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' { s -= 1 } else { break }
        }
        if s == i do continue
        switch v[s:i] {
        case "env", "anchor", "anchor-size", "image-set", "-webkit-image-set",
             "round", "mod", "rem", "sign", "abs", "pow", "sqrt", "hypot",
             "element", "paint", "cross-fade":
            return true
        }
    }
    return false
}

// Implementação do hook: parseia o seletor (fatia `selector`, então usar e
// liberar aqui mesmo — não reter, ver bugfix dos seletores danglando) e coleta
// os descendentes de `scope` que casam, em ordem de documento.
js_dom_query :: proc(scope: ^dompkg.Node, selector: string, all: bool, out: ^[dynamic]^dompkg.Node) {
    sels := csspkg.parse_selectors(selector)
    defer {
        for &s in sels do csspkg.free_selector(&s)
        delete(sels)
    }
    if len(sels) == 0 do return
    query_walk(scope, sels[:], all, out, true, scope.kind == .Element ? scope : document_element(scope))
}

// Devolve true quando deve PARAR (achou o 1º e all=false).
@(private = "file")
query_walk :: proc(n: ^dompkg.Node, sels: []csspkg.Selector, all: bool, out: ^[dynamic]^dompkg.Node, is_scope: bool, scope: ^dompkg.Node) -> bool {
    // Sonda compile-gated (-define:DOMPROBE=true) do crash do wikipedia: o ASAN
    // apontou access-violation em `for c in n.children` com endereço 0x1, ou seja
    // o PONTEIRO DE DADOS do slice de filhos está corrompido. Aqui identificamos
    // QUAL nó é (e o pai dele), que é o que a mensagem do ASAN não diz.
    when #config(DOMPROBE, false) {
        dp := uintptr(raw_data(n.children))
        ln := len(n.children)
        if ln < 0 || ln > 1_000_000 || (ln > 0 && dp < 0x10000) {
            fmt.eprintfln("[domprobe] children CORROMPIDO: n=%p kind=%v len=%d data=%p",
                          rawptr(n), int(n.kind), ln, rawptr(dp))
            return false
        }
        // O nó pendurado tem endereço de heap VÁLIDO (só o conteúdo é lixo), então
        // o teste é o `kind` fora do enum. Aqui o PAI ainda é bom → dá p/ dizer
        // ONDE na árvore está o filho morto.
        for c, i in n.children {
            bad := uintptr(rawptr(c)) < 0x10000 || int(c.kind) < 0 || int(c.kind) > 4
            if bad {
                id := n.attrs["id"]; cls := n.attrs["class"]
                quem := "NUNCA LIBERADO (lixo de outra origem)"
                dono_igual := false
                alias := false
                zumbis := 0
                zpar: rawptr = nil
                when #config(DOMPROBE, false) {
                    if t, seen := dompkg.g_free_log[rawptr(c)]; seen do quem = t
                    if o, seen2 := dompkg.g_free_owner[rawptr(c)]; seen2 do dono_igual = (o == n)
                    alias = dompkg.g_alias_child == rawptr(c)
                    zumbis = dompkg.g_zumbi_insert
                    zpar   = dompkg.g_zumbi_parent
                }

                fmt.eprintfln("[domprobe] filho MORTO: idx=%d/%d ptr=%p kind=%d | PAI: <%s id=%q class=%q> | LIBERADO POR: %s | aliasado=%v | INSERCOES-DE-NO-MORTO=%d (ultimo pai=%p, este pai=%p)",
                              i, ln, rawptr(c), int(c.kind), n.tag, id, cls, quem, alias, zumbis, zpar, rawptr(n))
                return false
            }
        }
    }
    if !is_scope && n.kind == .Element {
        for s in sels {
            if query_selector_matches(s, n, scope) {
                append(out, n)
                if !all do return true
                break // já casou; não duplicar por outro seletor da lista
            }
        }
    }
    for c in n.children {
        if query_walk(c, sels, all, out, false, scope) do return true
    }
    return false
}

// Direct matching also works for detached elements.
js_dom_matches :: proc(n: ^dompkg.Node, text: string, scope: ^dompkg.Node) -> bool {
    sels := csspkg.parse_selectors(text)
    defer { for &s in sels do csspkg.free_selector(&s); delete(sels) }
    for s in sels do if query_selector_matches(s, n, scope) do return true
    return false
}

document_element :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    for c in n.children do if c.kind == .Element do return c
    return nil
}

// Generated pseudo-elements are not DOM elements.
query_selector_matches :: proc(sel: csspkg.Selector, n, scope: ^dompkg.Node) -> bool {
    for p in sel.parts {
        if p.pseudo == .Before || p.pseudo == .After || p.pseudo == .FirstLetter || p.pseudo == .Placeholder do return false
    }
    return selector_matches_node(sel, n, scope)
}
