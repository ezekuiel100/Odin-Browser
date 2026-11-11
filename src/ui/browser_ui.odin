package ui

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "base:intrinsics"
import net             "../net"
import dompkg          "../dom"
import htmlp           "../html"
import csspkg          "../css"
import jspkg           "../js"
import sdl2            "vendor:sdl2"
import stbi            "vendor:stb/image"
import im              "../../vendor/imgui"
import imgui_sdl2      "../../vendor/imgui/imgui_impl_sdl2"
import imgui_sdlr      "../../vendor/imgui/imgui_impl_sdlrenderer2"

WINDOW_W  : i32 : 1280
WINDOW_H  : i32 :  800
URL_LIMIT :: 2048

// ── Paleta (escuro estilo Chrome / Edge) ────────────────────────────────────

WIN_BG    :: 0x1c1c1e // faixa de abas (mais escuro)
TOOLBAR   :: 0x2c2c2e // toolbar + aba ativa (conectados)
TAB_HOVER :: 0x252527 // aba inativa em hover
OMNIBOX   :: 0x3a3a3c // pílula de URL
OMNIBOX_H :: 0x48484a // pílula focada
ICONBTN_H :: 0x3a3a3c // hover dos botões de ícone
CLOSE_H   :: 0x4a4a4c // hover do × da aba
TEXT_C    :: 0xe8e8e8
SUBTEXT_C :: 0x9a9a9c
ACCENT_C  :: 0x4d9fff
PAGE_BG   :: 0x202124 // página de nova aba
PAGE_BOX  :: 0x303134
STATUS_BG :: 0x1c1c1e

TAB_H     : f32 : 38
TAB_MAX_W : f32 : 220

// ── Estado ──────────────────────────────────────────────────────────────────

Tab :: struct {
    id:      u64,            // identificador estável (índices mudam ao fechar abas)
    opener:  u64,            // id da aba que a abriu com o botão do meio (0 = nenhuma)
    title:   string,
    url:     string,
    loading: bool,
    content: string,         // corpo HTML cru recebido da rede
    status:  int,            // código HTTP
    dom:     ^dompkg.Node,   // árvore DOM parseada
    tree:    string,         // dump indentado da árvore (para exibição)
    history:  [dynamic]string, // URLs visitadas (para voltar/avançar)
    hist_idx: int,             // posição atual no histórico
    styles:   map[^dompkg.Node]Computed, // estilo computado por nó (CSS)
    page_bg:  u32,             // cor de fundo da página (do CSS)
    layout:   ^Box,            // árvore de layout
    vm:       ^jspkg.Interp,   // vm JS persistente da página (nil se sem script)
    css_text: string,          // CSS coletado (DONO) p/ re-estilizar (zoom/mutação JS)
    // Regras parseadas do css_text, RETIDAS entre restyles (DONO). Só é possível
    // porque as strings de Rule/Selector viraram owned (ver a nota de posse em
    // css.odin/free_compound): antes elas eram fatias da arena temp do parse e
    // morriam no free_all do topo do frame, o que obrigava a RE-PARSEAR a folha
    // inteira a cada zoom/clique/tick. rules_ready=false → (re)parseia no próximo
    // restyle; é o que a navegação liga ao trocar o css_text.
    rules:       [dynamic]csspkg.Rule,
    kf:          [dynamic]csspkg.Keyframe_Set,
    rules_ready: bool,
    zoom_applied: f32,                      // g_zoom com que styles/layout foram computados
    // Impressão digital do DOM de quando styles/layout foram computados. Um tick
    // de timer que NÃO mudou o DOM não precisa de restyle (ver dompkg.fingerprint).
    // 0 = nunca computada → o 1º tick re-estiliza (o hash praticamente nunca é 0).
    dom_fp: u64,
}

// Requisição de rede em andamento, processada numa thread separada.
// A thread já entrega o DOM parseado e os estilos computados (incl. CSS externo).
Fetch_Job :: struct {
    url:       string,      // cópia própria da URL (pode mudar p/ http no fallback)
    final_url: string,      // URL realmente buscada (reflete fallback https→http)
    auto_https: bool,       // o esquema https foi auto-adicionado? (permite fallback)
    viewport_w: f32,        // largura do viewport p/ avaliar @media e vw
    viewport_h: f32,        // altura do viewport p/ vh
    tab_id:  u64,           // aba que pediu (pode ter sido fechada)
    resp:    net.Response,  // preenchido pela thread
    dom:     ^dompkg.Node,  // DOM parseado pela thread
    styles:  map[^dompkg.Node]Computed, // estilos computados pela thread
    page_bg: u32,           // fundo da página (do CSS)
    layout:  ^Box,          // árvore de layout construída pela thread
    vm:      ^jspkg.Interp,  // vm JS persistente (scripts já rodados na thread)
    css_text: string,       // CSS coletado (DONO)
    // Regras já parseadas pela thread p/ o estilo inicial. São TRANSFERIDAS à aba
    // em vez de liberadas: poupam um parse no 1º restyle e, mais importante,
    // mantêm vivas as fatias `_raw` do Computed (quotes_raw/content_raw/…), que
    // apontam para dentro de `rule.decls` — antes o worker liberava as rules logo
    // após o build_layout e essas fatias ficavam penduradas em job.styles.
    rules:   [dynamic]csspkg.Rule,
    kf:      [dynamic]csspkg.Keyframe_Set,
    done:    b32,           // sinalizado atomicamente quando termina
}

g_jobs:        [dynamic]^Fetch_Job
g_next_tab_id: u64
g_focus_url:   bool = true // foca a barra de URL no próximo frame (aba nova)

// ── DevTools ────────────────────────────────────────────────────────────────
// Painel inferior. Toggle: F12 ou Ctrl+Shift+J. A altura sai do viewport
// (draw_content encolhe quando aberto). Abas: Console + Elements.
Devtools_Tab :: enum { Console, Elements }
g_devtools_open: bool
g_devtools_tab:  Devtools_Tab
g_devtools_h:    f32  = 260
g_devtools_show: [3]bool = {true, true, true} // filtro do Console por nível: {Log, Warn, Error}

// Elements: nó selecionado (painel de detalhes) e nó sob o mouse na árvore (highlight
// na página). rawptr de ^dompkg.Node — comparação por identidade, sem deref se morto.
g_dt_sel:   rawptr
g_dt_hover: rawptr

// Origem de conteúdo do viewport em coords de TELA, capturada no paint (draw_content).
// screen(box) = g_viewport_o + {box.x, box.y}. O clip recorta o highlight à área da página.
g_viewport_o:     im.Vec2
g_viewport_clip:  [4]f32 // {min_x, min_y, max_x, max_y} em tela
g_viewport_size:  im.Vec2 // dimensões do viewport (p/ re-layout após um snippet do REPL mexer no DOM)
g_viewport_valid: bool

// REPL do Console: buffer editável da linha de entrada (null-terminado p/ o InputText).
REPL_LIMIT :: 2048
g_repl_buf: [REPL_LIMIT]u8

// ── Favoritos ───────────────────────────────────────────────────────────────
// Sites salvos pelo usuário (estrela na barra de endereço). Aparecem como
// atalhos na página de nova aba. Persistidos em bookmarks.txt: uma linha por
// favorito no formato  url<TAB>título  (título pode conter espaços, url não).
Bookmark :: struct { url: string, title: string }
g_bookmarks: [dynamic]Bookmark
BOOKMARKS_PATH :: "C:\\Users\\Adm\\Desktop\\browser\\bookmarks.txt"

// Índice do favorito com esta URL, ou -1 se não estiver salvo.
bookmark_index :: proc(url: string) -> int {
    for bm, i in g_bookmarks do if bm.url == url do return i
    return -1
}

// Adiciona ou remove o favorito da URL (usado pela estrela). Regrava o arquivo.
bookmark_toggle :: proc(url, title: string) {
    if url == "" do return
    if idx := bookmark_index(url); idx >= 0 {
        delete(g_bookmarks[idx].url)
        delete(g_bookmarks[idx].title)
        ordered_remove(&g_bookmarks, idx)
    } else {
        t := title == "" ? url : title
        append(&g_bookmarks, Bookmark{strings.clone(url), strings.clone(t)})
    }
    bookmarks_save()
}

// Carrega bookmarks.txt no início. Ausência do arquivo = lista vazia (ok).
bookmarks_load :: proc() {
    data, rerr := os.read_entire_file_from_path(BOOKMARKS_PATH, context.allocator)
    if rerr != nil do return // arquivo ainda não existe = lista vazia (ok)
    defer delete(data)
    for line in strings.split(string(data), "\n", context.temp_allocator) {
        ln := strings.trim_space(line)
        if ln == "" do continue
        tab := strings.index_byte(ln, '\t')
        url   := tab >= 0 ? ln[:tab]   : ln
        title := tab >= 0 ? ln[tab+1:] : ln
        append(&g_bookmarks, Bookmark{strings.clone(url), strings.clone(title)})
    }
}

// Regrava bookmarks.txt inteiro (chamado a cada alteração; a lista é pequena).
bookmarks_save :: proc() {
    sb := strings.builder_make(context.temp_allocator)
    for bm in g_bookmarks {
        strings.write_string(&sb, bm.url)
        strings.write_byte(&sb, '\t')
        strings.write_string(&sb, bm.title)
        strings.write_byte(&sb, '\n')
    }
    _ = os.write_entire_file(BOOKMARKS_PATH, transmute([]u8)strings.to_string(sb))
}

make_tab :: proc(title: string) -> Tab {
    g_next_tab_id += 1
    return Tab{id = g_next_tab_id, title = title}
}

// Níveis de zoom (Ctrl +/-), estilo navegador. 1.0 = 100%.
g_zoom_levels := [?]f32{0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0}

// Ajusta g_zoom um passo p/ cima (dir>0), baixo (dir<0) ou reset a 100% (dir==0).
// A aba ativa é re-computada no próximo frame (zoom_applied != g_zoom).
zoom_step :: proc(dir: int) {
    if dir == 0 { g_zoom = 1.0; return }
    cur := 0
    for lv, i in g_zoom_levels do if abs(lv - g_zoom) < abs(g_zoom_levels[cur] - g_zoom) do cur = i
    cur = dir > 0 ? min(cur + 1, len(g_zoom_levels) - 1) : max(cur - 1, 0)
    g_zoom = g_zoom_levels[cur]
}

// Libera as regras retidas da aba e marca p/ re-parsear no próximo restyle.
// Chamar SEMPRE que o css_text for trocado ou a aba for destruída — as rules
// são donas das próprias strings desde a correção de posse.
tab_drop_rules :: proc(tab: ^Tab) {
    if !tab.rules_ready do return
    csspkg.free_rules(&tab.rules)
    csspkg.free_keyframes(&tab.kf)
    tab.rules = nil
    tab.kf = nil
    tab.rules_ready = false
}

// Re-estiliza e reconstrói o layout da aba (após Ctrl +/-, troca de aba, ou
// mutação do DOM pelo JS no clique). Reusa as rules retidas: as rules
// retidas em tab.rules são donas das próprias strings, então sobrevivem ao
// free_all(temp) do topo do frame. O parse só acontece na 1ª vez (ou depois de
// tab_drop_rules, que a navegação chama ao trocar o css_text). vw/vh = viewport.
restyle_tab :: proc(tab: ^Tab, vw, vh: f32) {
    if tab.dom == nil { tab.zoom_applied = g_zoom; return }
    if !tab.rules_ready {
        tab.rules, tab.kf = csspkg.parse(tab.css_text)
        tab.rules_ready = true
    }
    // @font-face na thread PRINCIPAL (dona do atlas): o fetch_worker parseia as
    // regras numa thread, então o registro das faces mora aqui. Idempotente.
    fontface_scan(tab.css_text, tab.url)
    if tab.styles != nil do free_styles(tab.styles)
    old_layout := tab.layout
    // S3: os 534 ms de restyle medidos no github são compute_styles + build_layout
    // JUNTOS. A divisão decide se a família de achados de estilo (Computed de
    // 5.936 B por valor, 201 resets manuais, ~210 lookups em apply_decls) vale
    // esforço ou zero. Os dois ticks abaixo são a resposta.
    when UIPROF { t_cs := time.tick_now() }
    tab.styles, tab.page_bg = compute_styles(tab.dom, &tab.rules, vw, vh, tab.kf[:])
    when UIPROF {
        g_uiprof.ms_compute += time.duration_milliseconds(time.tick_since(t_cs))
        t_bl := time.tick_now()
    }
    tab.layout = build_layout(tab.dom, tab.styles, tab.url)
    animation_restore_tree(tab.layout, old_layout)
    free_layout(old_layout)
    when UIPROF { g_uiprof.ms_buildlay += time.duration_milliseconds(time.tick_since(t_bl)) }
    tab.zoom_applied = g_zoom
    // getComputedStyle lê daqui. Tem de ser DEPOIS do compute_styles: o free_styles
    // logo acima liberou o mapa anterior, e o hook apontaria p/ memória morta.
    js_style_source_set(tab.styles, tab.layout, vw, vh)
    // Baseline p/ o guarda de timer. Tirada DEPOIS do compute_styles porque ele
    // carimba `data-shadow-scope` nos hosts de shadow root (idempotente, mas
    // muda o DOM na 1ª passada) — tirar antes daria divergência permanente.
    tab.dom_fp = dompkg.fingerprint(tab.dom)
}

// Bootstrap/fallback do conteúdo. font_raster.odin acrescenta rasterizações no
// tamanho pedido pelo layout; esta escada atende o primeiro frame e os pedidos
// que excedem o orçamento do cache. Densidade 1.5 suaviza apenas esse fallback.
content_font_cfg :: proc() -> im.FontConfig {
    return im.FontConfig{
        FontDataOwnedByAtlas = true,
        OversampleH          = 2,
        OversampleV          = 1,
        PixelSnapH           = false,
        GlyphMaxAdvanceX     = 3.4028235e38,
        RasterizerMultiply   = 1.0,
        RasterizerDensity    = 1.5,
        EllipsisChar         = 0xFFFF,
    }
}

State :: struct {
    tabs:    [dynamic]Tab,
    active:  int,
    url_buf: [URL_LIMIT]u8,
    status:  string,
    click_target: ^dompkg.Node, // nó clicado neste frame (processado após o paint)
    // Botão do MEIO (ver dispatch_page_aux). `aux_node`/`aux_href` são gravados
    // pelo paint SÓ nos frames em que o botão do meio apertou ou soltou: o nó mais
    // acima sob o cursor e o link sob ele. `aux_press_*` sobrevive entre o frame do
    // aperto e o da soltura (o href é CLONADO: o layout pode ser refeito no meio).
    aux_node:       ^dompkg.Node,
    aux_href:       string,
    aux_press_tab:  u64,    // id da aba onde o meio APERTOU (0 = não apertou na página)
    aux_press_href: string, // link sob o aperto (owned)
    // scroll de âncora (#id): navigate_href seta o alvo; o viewport aplica (pulo ou
    // animação suave conforme scroll-behavior). scroll_pending liga o processamento.
    scroll_pending: bool,
    scroll_target:  f32,  // Y-página alvo (box.y é absoluto)
    scroll_smooth:  bool, // anima em vez de pular (scroll-behavior:smooth da raiz)
}

g_font_ui:  ^im.Font
g_font_big: ^im.Font
// "Escada" de fontes para o conteúdo: carregadas em vários tamanhos para que
// texto grande fique nítido (em vez de escalar uma fonte pequena = embaçado).
FONT_N :: 5
g_font_sizes := [FONT_N]f32{16, 20, 25, 32, 40}
// Razão (ascent−descent)/em de cada família embutida, lida do sfnt em
// init_fonts. É o fator que converte `font-size` do CSS no "tamanho" que o
// ImGui entende — ver em_ratio_medido() e render_px().
//
// ⚠️ Era UMA constante (1.36, a da Segoe UI) para todas as faces. Como Georgia
// tem ~1.14 e Consolas ~1.17, serif e mono saíam ~19% e ~22% MAIORES que no
// Chrome; texto maior quebra em mais linhas e a página inteira crescia.
// Valor inicial = o antigo, para que uma leitura que falhe não mude nada.
g_em_sans:  f32 = 1.36
g_em_serif: f32 = 1.36
g_em_mono:  f32 = 1.36
g_em_paths: [3]string // sans, serif, mono — de onde calibrar (ver em_calibrar)
g_em_feito: bool

// Calibra as três razões contra o atlas JÁ CONSTRUÍDO. Idempotente e
// auto-recuperável: enquanto o atlas não tiver glifos, `em_ratio_medido` falha,
// `g_em_feito` continua false e a próxima chamada tenta de novo. É por isso que
// o gatilho fica no l_pick_font e não no init_fonts — a ordem de construção do
// atlas depende do backend, e um "calibrei cedo demais" sairia como texto do
// tamanho errado na página inteira, em silêncio.
em_calibrar :: proc() {
    if g_em_feito do return
    if g_reg[0] == nil do return
    alvo := [3]^im.Font{g_reg[0], g_serif[0], g_mono[0]}
    dest := [3]^f32{&g_em_sans, &g_em_serif, &g_em_mono}
    ok_todos := true
    for i in 0 ..< 3 {
        if g_em_paths[i] == "" || alvo[i] == nil { ok_todos = false; continue }
        b, rerr := os.read_entire_file_from_path(g_em_paths[i], context.allocator)
        if rerr != nil {
            when #config(EMPROBE, false) { fmt.eprintfln("[em] %d: leitura FALHOU %v (%s)", i, rerr, g_em_paths[i]) }
            ok_todos = false; continue
        }
        defer delete(b)
        r, k := em_ratio_medido(b, alvo[i])
        when #config(EMPROBE, false) {
            fmt.eprintfln("[em] %d: %s bytes=%d FontSize=%.1f -> r=%.4f ok=%v", i, g_em_paths[i], len(b), alvo[i].FontSize, r, k)
        }
        if k { dest[i]^ = r } else { ok_todos = false }
    }
    if ok_todos do g_em_feito = true
}
g_reg:  [FONT_N]^im.Font // regular (sans)
g_bold: [FONT_N]^im.Font // negrito (sans)
g_semi: [FONT_N]^im.Font // semibold (sans) — font-weight 500/600
g_serif:   [FONT_N]^im.Font // serif regular
g_serif_b: [FONT_N]^im.Font // serif negrito
g_mono:    [FONT_N]^im.Font // monospace regular
g_mono_b:  [FONT_N]^im.Font // monospace negrito
g_ital:    [FONT_N]^im.Font // itálico (sans)
g_ital_b:  [FONT_N]^im.Font // negrito itálico (sans)
g_serif_i: [FONT_N]^im.Font // serif itálico
g_serif_z: [FONT_N]^im.Font // serif negrito itálico
g_mono_i:  [FONT_N]^im.Font // monospace itálico
g_mono_z:  [FONT_N]^im.Font // monospace negrito itálico
g_font_body: ^im.Font // = g_reg[0]  (atalhos p/ o tamanho base)
g_font_hb:   ^im.Font // = g_bold[0]
// Ranges de glyphs carregados no atlas (Segoe UI cobre todos estes).
g_text_ranges := [?]im.Wchar{
    0x0020, 0x00FF, // ASCII + Latin-1 (acentuadas)
    0x0370, 0x03FF, // grego
    0x2000, 0x206F, // pontuação geral (— – " " ' ' … • † ‡ ′ ‰)
    0x20A0, 0x20BF, // símbolos de moeda (€)
    0x2100, 0x214F, // letterlike (™)
    0x2190, 0x21FF, // setas (← → ↑ ↓ ↔)
    0x2200, 0x22FF, // operadores matemáticos (≤ ≥ ≠ ≈ √ ∞ ∑ ∫)
    0,
}
g_icon_ranges := [?]im.Wchar{0xE700, 0xE9FF, 0}        // Segoe MDL2 Assets (ícones)

// Símbolos/pictogramas monocromáticos do BMP (< U+FFFF) mesclados de Segoe UI
// Symbol no conteúdo: setas, formas (▶ ◀ ●), símbolos diversos (★ ☆ ♥ ☎ ⚡),
// dingbats (✓ ✔ ✕ ❤ ➜) e ⭐. Emojis de plano astral (📷 🎵 U+1F300+) NÃO cabem
// no ImWchar de 16 bits deste build do ImGui — são removidos por sanitize_text
// no parser (viram vazio em vez de '?').
g_symbol_ranges := [?]im.Wchar{
    0x2190, 0x21FF, // setas
    0x2300, 0x23FF, // técnicos (⌚ ⏰ ⏸ ⏹)
    0x25A0, 0x25FF, // formas geométricas (▶ ◀ ● ■ ◆ ▲ ▼)
    0x2600, 0x26FF, // símbolos diversos (★ ☆ ☀ ☁ ♥ ♦ ☎ ✈ ⚡ ⚙)
    0x2700, 0x27BF, // dingbats (✂ ✓ ✔ ✕ ✖ ✨ ❤ ➜ ➤)
    0x2B00, 0x2BFF, // ⭐ e setas (⬆ ⬇ ⬅ ➡)
    0,
}

// Ícones (codepoints da fonte Segoe MDL2 Assets)
IC_BACK   : cstring : ""
IC_FWD    : cstring : ""
IC_RELOAD : cstring : ""
IC_MENU   : cstring : ""
IC_LOCK   : cstring : ""
IC_SEARCH : cstring : ""
IC_ADD    : cstring : ""

// ── Helpers de cor ──────────────────────────────────────────────────────────

// Globals da janela borderless
g_window:       ^sdl2.Window
g_titlebar_h:   f32 = 38
g_drag_x0:      f32
g_drag_x1:      f32

// Codepoints da estrela de favoritos (Segoe MDL2 Assets)
CP_STAR      :: 0xE734 // contorno — página não favoritada
CP_STAR_FILL :: 0xE735 // cheia    — página favoritada

// Codepoints dos controles de janela (Segoe MDL2 Assets)
CP_MIN     :: 0xE921
CP_MAX     :: 0xE922
CP_RESTORE :: 0xE923
CP_CLOSE   :: 0xE8BB

// Converte um codepoint em cstring UTF-8 (válida durante o frame)
icon :: proc(cp: rune) -> cstring {
    return fmt.ctprintf("%r", cp)
}

// Maximiza/restaura usando as funções nativas (a janela tem frame nativo).
toggle_maximize :: proc() {
    if frame_is_maximized() {
        sdl2.RestoreWindow(g_window)
    } else {
        sdl2.MaximizeWindow(g_window)
    }
}

vec :: proc(hex: u32) -> im.Vec4 {
    // byte alto = alpha; 0 significa opaco (retrocompat com cores 0xRRGGBB)
    a: f32 = 1
    if ab := (hex >> 24) & 0xFF; ab != 0 do a = f32(ab) / 255.0
    return {
        f32((hex >> 16) & 0xFF) / 255.0,
        f32((hex >>  8) & 0xFF) / 255.0,
        f32( hex        & 0xFF) / 255.0,
        a,
    }
}

col :: proc(hex: u32) -> u32 {
    return im.ColorConvertFloat4ToU32(vec(hex))
}

col_o :: proc(hex: u32, opacity: f32) -> u32 {
    v := vec(hex)
    v.w *= opacity
    return im.ColorConvertFloat4ToU32(v)
}

push_col :: proc(idx: im.Col, hex: u32) {
    im.PushStyleColor(idx, col(hex))
}

// Carrega as fontes (UI + ícones + escada de conteúdo) no atlas do ImGui.
// Compartilhado entre run() e o modo headless (headless.odin).
setup_fonts :: proc(io: ^im.IO) {
    native_fonts_reset()
    g_font_ui = im.FontAtlas_AddFontFromFileTTF(io.Fonts, "C:\\Windows\\Fonts\\segoeui.ttf", 17, nil, &g_text_ranges[0])

    // mescla os ícones da Segoe MDL2 Assets no mesmo handle de fonte
    icon_cfg := im.FontConfig{
        MergeMode            = true,
        FontDataOwnedByAtlas = true,
        OversampleH          = 1,
        OversampleV          = 1,
        GlyphMinAdvanceX     = 18,
        GlyphMaxAdvanceX     = 3.4028235e38,
        GlyphOffset          = {0, 3},
        RasterizerMultiply   = 1.0,
        RasterizerDensity    = 1.0,
        EllipsisChar         = 0xFFFF,
    }
    im.FontAtlas_AddFontFromFileTTF(io.Fonts, "C:\\Windows\\Fonts\\segmdl2.ttf", 15, &icon_cfg, &g_icon_ranges[0])

    g_font_big = im.FontAtlas_AddFontFromFileTTF(io.Fonts, "C:\\Windows\\Fonts\\segoeuib.ttf", 38, nil, &g_text_ranges[0])

    // escada de fontes do conteúdo (regular + negrito + itálico em vários tamanhos).
    // sans = Segoe UI; serif = Georgia; mono = Consolas (genéricas do CSS).
    SEGOE    :: "C:\\Windows\\Fonts\\segoeui.ttf"
    SEGOEB   :: "C:\\Windows\\Fonts\\segoeuib.ttf"
    SEGOESB  :: "C:\\Windows\\Fonts\\seguisb.ttf" // Segoe UI Semibold (peso 600)
    SEGOEI   :: "C:\\Windows\\Fonts\\segoeuii.ttf"
    SEGOEZ   :: "C:\\Windows\\Fonts\\segoeuiz.ttf"
    GEORGIA  :: "C:\\Windows\\Fonts\\georgia.ttf"
    GEORGIAB :: "C:\\Windows\\Fonts\\georgiab.ttf"
    GEORGIAI :: "C:\\Windows\\Fonts\\georgiai.ttf"
    GEORGIAZ :: "C:\\Windows\\Fonts\\georgiaz.ttf"
    CONSOLA  :: "C:\\Windows\\Fonts\\consola.ttf"
    CONSOLAB :: "C:\\Windows\\Fonts\\consolab.ttf"
    CONSOLAI :: "C:\\Windows\\Fonts\\consolai.ttf"
    CONSOLAZ :: "C:\\Windows\\Fonts\\consolaz.ttf"
    SYMBOL   :: "C:\\Windows\\Fonts\\seguisym.ttf"
    load :: proc(io: ^im.IO, path: cstring, sz: f32) -> ^im.Font {
        cfg := content_font_cfg()
        f := im.FontAtlas_AddFontFromFileTTF(io.Fonts, path, sz, &cfg, &g_text_ranges[0])
        // mescla os símbolos/pictogramas do BMP no MESMO handle (só sans reg/bold
        // — cobre o uso comum; itálico/serif/mono raramente têm ícones no texto).
        merge := content_font_cfg()
        merge.MergeMode = true
        im.FontAtlas_AddFontFromFileTTF(io.Fonts, SYMBOL, sz, &merge, &g_symbol_ranges[0])
        return f
    }
    load_plain :: proc(io: ^im.IO, path: cstring, sz: f32) -> ^im.Font {
        cfg := content_font_cfg()
        return im.FontAtlas_AddFontFromFileTTF(io.Fonts, path, sz, &cfg, &g_text_ranges[0])
    }
    // A razão em-square de cada família é CALIBRADA depois do build do atlas
    // (em em_calibrar), não deduzida de uma tabela do sfnt.
    //
    // ⚠️ Tentei deduzir de `hhea` (ascent−descent)/upem, que é o que o
    // `stbtt_ScaleForPixelHeight` diz usar: acertou Segoe UI (1,330 × 1,337
    // necessário) e Georgia (1,136 × 1,122), e ERROU o Consolas por 9% — o hhea
    // dele dá exatamente 1,0000 e o necessário medido é 1,0922 (as métricas
    // `win` do OS/2 dariam 1,1709, também erradas). Como nenhuma tabela prevê o
    // que o stb realmente faz, a razão sai do avanço que o ImGui PRODUZIU.
    g_em_paths = {SEGOE, GEORGIA, CONSOLA}

    for sz, i in g_font_sizes {
        g_reg[i]     = load(io, SEGOE,    sz)
        g_bold[i]    = load(io, SEGOEB,   sz)
        g_semi[i]    = load_plain(io, SEGOESB, sz)
        g_ital[i]    = load_plain(io, SEGOEI,   sz)
        g_ital_b[i]  = load_plain(io, SEGOEZ,   sz)
        g_serif[i]   = load_plain(io, GEORGIA,  sz)
        g_serif_b[i] = load_plain(io, GEORGIAB, sz)
        g_serif_i[i] = load_plain(io, GEORGIAI, sz)
        g_serif_z[i] = load_plain(io, GEORGIAZ, sz)
        g_mono[i]    = load_plain(io, CONSOLA,  sz)
        g_mono_b[i]  = load_plain(io, CONSOLAB, sz)
        g_mono_i[i]  = load_plain(io, CONSOLAI, sz)
        g_mono_z[i]  = load_plain(io, CONSOLAZ, sz)
    }
    g_font_body = g_reg[0]
    g_font_hb   = g_bold[0]

    if g_font_ui == nil do g_font_ui = im.FontAtlas_AddFontDefault(io.Fonts)

    // ⚠️ Constrói o atlas AQUI para poder calibrar as razões em-square. Sem
    // isto a calibração não acontece a tempo: o `l_pick_font` roda no LAYOUT,
    // que no `--render` é feito UMA vez, antes de o backend construir o atlas na
    // primeira frame. A tentativa preguiçosa falhava por falta de glifo, o
    // layout nunca era refeito, e o texto saía com o fallback 1.36 — ou seja, a
    // correção existia e não valia nada. O backend reconstrói se precisar.
    okb := im.FontAtlas_Build(io.Fonts)
    when #config(EMPROBE, false) { fmt.eprintfln("[em] FontAtlas_Build=%v fonts=%d", okb, io.Fonts.Fonts.Size) }
    em_calibrar()
}

// ── Ponto de entrada ────────────────────────────────────────────────────────

// ── Rede de segurança de memória (Tracking_Allocator, só em debug) ───────────
// Embrulha o alocador e reporta double-free / free de ponteiro errado no exit.
// COMPARTILHADO via globais porque o app usa threads: os workers (fetch/imagem)
// precisam adotar o MESMO alocador (via dbg_adopt_allocator), senão alocam no
// default e a main libera no tracked → falso "bad free". O tracker é thread-safe.
when ODIN_DEBUG {
    g_dbg_track: mem.Tracking_Allocator
    g_dbg_alloc: mem.Allocator
    g_dbg_on:    bool
}

// Chamado no topo de cada thread worker: adota o alocador tracked global.
// No-op em release. Sem isto, frees cruzando threads viram falso double-free.
dbg_adopt_allocator :: proc() {
    when ODIN_DEBUG {
        if g_dbg_on do context.allocator = g_dbg_alloc
    }
}

when ODIN_DEBUG {
mem_tracking_begin :: proc() {
    mem.tracking_allocator_init(&g_dbg_track, context.allocator)
    g_dbg_alloc = mem.tracking_allocator(&g_dbg_track)
    g_dbg_on = true
    context.allocator = g_dbg_alloc
}
mem_tracking_report :: proc() {
    if len(g_dbg_track.bad_free_array) > 0 {
        fmt.eprintfln("\n### [mem] %d FREE(S) INVÁLIDO(S) — double-free ou ponteiro errado:", len(g_dbg_track.bad_free_array))
        for b in g_dbg_track.bad_free_array {
            fmt.eprintfln("    %p liberado em %v", b.memory, b.location)
        }
    } else {
        fmt.eprintln("\n### [mem] nenhum free inválido ✓")
    }
    if len(g_dbg_track.allocation_map) > 0 {
        fmt.eprintfln("### [mem] %d alocação(ões) vivas no exit (vazamentos ou estado global não liberado)", len(g_dbg_track.allocation_map))
    }
    mem.tracking_allocator_destroy(&g_dbg_track)
}
}

run :: proc() {
    // Instalado ANTES de qualquer alocação Odin (p/ não gerar falso "free
    // inválido"). Os workers adotam via dbg_adopt_allocator.
    when ODIN_DEBUG {
        mem_tracking_begin()
        defer mem_tracking_report()
    }

    assert(sdl2.Init(sdl2.INIT_EVERYTHING) == 0)
    defer sdl2.Quit()

    sdl2.SetHint(sdl2.HINT_RENDER_SCALE_QUALITY, "1")

    // Janela normal (NÃO borderless): mantém os estilos nativos do Windows
    // para Aero Snap, sombra e animações. O custom frame esconde a barra de
    // título e desenhamos a nossa por cima. Criada oculta p/ evitar flash.
    window := sdl2.CreateWindow(
        "Odin Browser",
        sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED,
        WINDOW_W, WINDOW_H,
        {.HIDDEN, .RESIZABLE, .ALLOW_HIGHDPI},
    )
    assert(window != nil)
    defer sdl2.DestroyWindow(window)
    g_window = window

    setup_custom_frame(window)    // subclassa a janela (snap/sombra/animação nativos)
    sdl2.MaximizeWindow(window)   // abre já maximizado (agora nativo)
    sdl2.ShowWindow(window)
    sdl2.RaiseWindow(window)      // traz pra frente e dá foco (p/ focar a URL no startup)

    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED, .PRESENTVSYNC})
    assert(renderer != nil)
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer shaped_text_clear()
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda
    g_renderer = renderer // p/ o compositing de layers (group-opacity) em replay_paint

    im.CHECKVERSION()
    im.CreateContext()
    defer im.DestroyContext()

    io := im.GetIO()
    io.ConfigFlags += {.NavEnableKeyboard}

    setup_fonts(io)
    apply_style()

    imgui_sdl2.InitForSDLRenderer(window, renderer)
    defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer)
    defer imgui_sdlr.Shutdown()

    net.ensure_init() // inicializa o libcurl antes de qualquer thread

    s := State{status = "Pronto"}
    defer css_unknown_report()
    defer delete(s.tabs)
    bookmarks_load() // carrega favoritos salvos (bookmarks.txt) p/ a página de nova aba
    append(&s.tabs, make_tab("Nova aba"))

    bg := vec(WIN_BG)
    e: sdl2.Event
    for {
        for sdl2.PollEvent(&e) {
            imgui_sdl2.ProcessEvent(&e)
            if e.type == .QUIT do return
            // Zoom da página: Ctrl + '='/'+' aumenta, Ctrl + '-' diminui, Ctrl+0
            // reseta. Tratado no nível do SDL p/ funcionar mesmo com foco num campo.
            if e.type == .KEYDOWN {
                mod := e.key.keysym.mod
                ctrl  := .LCTRL  in mod || .RCTRL  in mod
                shift := .LSHIFT in mod || .RSHIFT in mod
                if ctrl {
                    #partial switch e.key.keysym.sym {
                    case .EQUALS, .KP_PLUS, .KP_EQUALS: zoom_step(+1)
                    case .MINUS, .KP_MINUS:             zoom_step(-1)
                    case .NUM0, .KP_0:                  zoom_step(0)
                    }
                }
                // DevTools: F12 ou Ctrl+Shift+J (mesmos atalhos do Chrome).
                if e.key.keysym.sym == .F12 || (ctrl && shift && e.key.keysym.sym == .J) {
                    g_devtools_open = !g_devtools_open
                }
                // F9: grava o frame atual em capture.png (ver capture_frame).
                if e.key.keysym.sym == .F9 do g_want_capture = true
            }
            // Ctrl + roda do mouse também dá zoom (padrão de navegador)
            if e.type == .MOUSEWHEEL {
                ks := sdl2.GetModState()
                if .LCTRL in ks || .RCTRL in ks {
                    if e.wheel.y > 0 do zoom_step(+1)
                    else if e.wheel.y < 0 do zoom_step(-1)
                }
            }
        }

        free_all(context.temp_allocator)

        // @font-face: promove as faces baixadas p/ o atlas ANTES de abrir o frame
        // (o ImGui TRAVA o atlas entre NewFrame e Render). Face nova muda as
        // MÉTRICAS de texto ⇒ invalida o layout de todas as abas.
        if fontface_poll() {
            for &t in s.tabs do t.zoom_applied = -1 // força restyle+relayout no frame
        }

        imgui_sdlr.NewFrame()
        imgui_sdl2.NewFrame()
        im.NewFrame()

        images_poll(renderer) // sobe texturas prontas, inicia downloads pendentes

        draw_browser(&s)

        im.Render()
        sdl2.SetRenderDrawColor(renderer, u8(bg.x*255), u8(bg.y*255), u8(bg.z*255), 255)
        sdl2.RenderClear(renderer)
        imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)
        // F9: PNG do frame ATUAL. Existe porque a janela do SDL não é capturável
        // por GDI (CopyFromScreen e PrintWindow devolvem PRETO — o conteúdo vive
        // no swapchain do renderer), e sem isto não há como INSPECIONAR o app
        // interativo: só o headless produzia imagem. Tem de vir ANTES do
        // RenderPresent — depois dele o back buffer é indefinido.
        if g_want_capture {
            g_want_capture = false
            capture_frame(renderer)
        }
        sdl2.RenderPresent(renderer)
    }
}

// ── Captura de tela do app interativo (F9) ──────────────────────────────────
// A janela do SDL NÃO é capturável de fora: tanto `CopyFromScreen` quanto
// `PrintWindow(PW_RENDERFULLCONTENT)` devolvem uma imagem PRETA, porque o
// conteúdo vive no swapchain do renderer e não na superfície GDI da janela.
// Sem isto, o único jeito de ver o motor era o headless (`--render`) — e nada
// que dependa de INTERAÇÃO (arraste da alça de resize, :hover, scroll com a
// roda, foco de campo) aparece lá.
//
// Grava em `capture.png` no diretório de trabalho. Mesmo caminho do headless:
// RenderReadPixels ABGR8888 (= R,G,B,A em little-endian, que é o que o stb
// espera) + o RETRY do write_png, que falha transitoriamente no Windows.
@(private = "file") g_want_capture: bool

@(private = "file")
capture_frame :: proc(renderer: ^sdl2.Renderer) {
    w, h: c.int
    sdl2.GetRendererOutputSize(renderer, &w, &h)
    if w <= 0 || h <= 0 do return
    px := make([]u8, int(w) * int(h) * 4, context.temp_allocator)
    rect := sdl2.Rect{0, 0, w, h}
    if sdl2.RenderReadPixels(renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(px), w * 4) != 0 {
        fmt.eprintfln("captura: RenderReadPixels falhou: %s", sdl2.GetErrorString())
        return
    }
    out := strings.clone_to_cstring("capture.png", context.temp_allocator)
    for tent in 0 ..< 4 {
        if stbi.write_png(out, w, h, 4, raw_data(px), w * 4) != 0 {
            fmt.eprintfln("captura: capture.png %dx%d", w, h)
            return
        }
        sdl2.Delay(u32(30 * (tent + 1)))
    }
    fmt.eprintln("captura: write_png falhou")
}

// ── Janela raiz ─────────────────────────────────────────────────────────────

draw_browser :: proc(s: ^State) {
    vp := im.GetMainViewport()
    im.SetNextWindowPos(vp.Pos)
    im.SetNextWindowSize(vp.Size)

    im.PushStyleVarImVec2(.WindowPadding, {0, 0})
    im.PushStyleColor(.WindowBg, col(WIN_BG))
    im.Begin("##root", nil, {
        .NoTitleBar, .NoResize, .NoMove,
        .NoScrollbar, .NoScrollWithMouse,
        .NoBringToFrontOnFocus, .NoNavFocus,
    })
    defer { im.End(); im.PopStyleColor(1); im.PopStyleVar(1) }

    poll_jobs(s) // entrega downloads concluídos

    draw_tabstrip(s)
    draw_toolbar(s)
    draw_content(s)
    // soltura do meio FORA da página (aba carregando, faixa de abas, devtools):
    // o dispatch_page_aux não rodou, então o aperto pendente morre aqui.
    if im.IsMouseReleased(.Middle) do aux_press_clear(s)
    if g_devtools_open do draw_devtools(s)
    draw_status_bar(s)
}

// ── Faixa de abas (desenhada à mão, estilo Chrome) ──────────────────────────

draw_tabstrip :: proc(s: ^State) {
    dl     := im.GetWindowDrawList()
    vp     := im.GetMainViewport()
    origin := im.GetCursorScreenPos()
    avail  := im.GetContentRegionAvail().x
    pad    : f32 = 8
    ctrl_w : f32 = 138 // espaço reservado p/ minimizar/maximizar/fechar

    n := f32(len(s.tabs))
    tab_w := (avail - ctrl_w - pad*2 - 40) / max(n, 1)
    tab_w  = min(tab_w, TAB_MAX_W)
    tab_w  = max(tab_w, 92)

    x := origin.x + pad
    y := origin.y

    close_idx := -1

    for i in 0 ..< len(s.tabs) {
        tab    := &s.tabs[i]
        active := i == s.active

        p0 := im.Vec2{x, y + 5}
        p1 := im.Vec2{x + tab_w, y + TAB_H}
        midy := (p0.y + p1.y) / 2

        im.SetCursorScreenPos(p0)
        im.SetNextItemAllowOverlap()
        // botão do MEIO fecha a aba (como nos navegadores). O InvisibleButton só
        // dispara na SOLTURA sobre o item que recebeu o aperto, então arrastar o
        // meio p/ fora da aba cancela — o mesmo contrato do clique esquerdo.
        if im.InvisibleButton(fmt.ctprintf("##tab%d", i), {tab_w, TAB_H - 5}, {.MouseButtonLeft, .MouseButtonMiddle}) {
            if im.IsMouseReleased(.Middle) {
                close_idx = i
            } else {
                s.active = i
                sync_url_buf(s)
            }
        }
        hovered := im.IsItemHovered()

        // fundo da aba
        bg : u32 = active ? TOOLBAR : (hovered ? TAB_HOVER : WIN_BG)
        if active || hovered {
            im.DrawList_AddRectFilled(dl, p0, p1, col(bg), 11, im.DrawFlags_RoundCornersTop)
        }

        // favicon
        fav : u32 = (tab.loading || active) ? ACCENT_C : SUBTEXT_C
        im.DrawList_AddCircleFilled(dl, {p0.x + 17, midy}, 5, col(fav))

        // título (clipado)
        tx   := p0.x + 32
        tend := p1.x - 26
        if tend > tx {
            im.DrawList_PushClipRect(dl, {tx, p0.y}, {tend, p1.y}, true)
            tc : u32 = active ? TEXT_C : SUBTEXT_C
            im.DrawList_AddText(dl, {tx, midy - 9}, col(tc), strings.clone_to_cstring(tab.title, context.temp_allocator))
            im.DrawList_PopClipRect(dl)
        }

        // botão fechar (×)
        cx := p1.x - 16
        im.SetCursorScreenPos({cx - 9, midy - 9})
        // o × fica POR CIMA da aba e rouba o hover: sem o meio aqui, o clique do
        // meio sobre o × não fecharia nada.
        if im.InvisibleButton(fmt.ctprintf("##close%d", i), {18, 18}, {.MouseButtonLeft, .MouseButtonMiddle}) {
            close_idx = i
        }
        chov := im.IsItemHovered()
        if chov {
            im.DrawList_AddCircleFilled(dl, {cx, midy}, 9, col(CLOSE_H))
        }
        if active || hovered || chov {
            xc : u32 = active ? TEXT_C : SUBTEXT_C
            im.DrawList_AddText(dl, {cx - 4, midy - 9}, col(xc), "×")
        }

        x += tab_w + 2
    }

    // botão nova aba (+)
    bx := x + 4
    by := y + 9
    im.SetCursorScreenPos({bx, by})
    if im.InvisibleButton("##newtab", {26, 24}) {
        append(&s.tabs, make_tab("Nova aba"))
        s.active = len(s.tabs) - 1
        for &b in s.url_buf do b = 0
        g_focus_url = true // foca a barra de URL na aba nova
    }
    if im.IsItemHovered() {
        im.DrawList_AddRectFilled(dl, {bx, by}, {bx + 26, by + 24}, col(TAB_HOVER), 6)
    }
    im.DrawList_AddText(dl, {bx + 8, by + 3}, col(SUBTEXT_C), "+")

    // remove aba fechada (após o loop)
    if close_idx >= 0 && len(s.tabs) > 1 {
        ct := &s.tabs[close_idx]
        if ct.content != "" do delete(ct.content)
        if ct.vm != nil     do jspkg.vm_free(ct.vm) // vm antes do DOM (referencia nós)
        if ct.dom != nil    { transitions_clear(); dompkg.free_tree(ct.dom) }
        if ct.tree != ""    do delete(ct.tree)
        if ct.styles != nil do free_styles(ct.styles)
        if ct.layout != nil do free_layout(ct.layout)
        if ct.css_text != "" do delete(ct.css_text)
        tab_drop_rules(ct)
        for h in ct.history do delete(h)
        delete(ct.history)
        ordered_remove(&s.tabs, close_idx)
        // fechar uma aba À ESQUERDA da ativa desloca a ativa um índice p/ trás;
        // sem isto o foco pulava p/ a vizinha da direita (raro com o ×, que a
        // aba precisa estar sob o mouse, e comum com o meio em abas de fundo).
        if close_idx < s.active do s.active -= 1
        if s.active >= len(s.tabs) do s.active = len(s.tabs) - 1
        sync_url_buf(s)
    }

    // área arrastável = vão entre o botão + e os controles de janela
    g_titlebar_h = TAB_H
    g_drag_x0    = (bx + 34) - vp.Pos.x
    g_drag_x1    = (origin.x + avail - ctrl_w) - vp.Pos.x

    // controles de janela (minimizar / maximizar / fechar)
    draw_window_controls(origin.x + avail - ctrl_w, y)

    im.SetCursorScreenPos({origin.x, y + TAB_H})
}

// ── Controles da janela (borderless) ────────────────────────────────────────

draw_window_controls :: proc(x0, y0: f32) {
    dl := im.GetWindowDrawList()
    bw : f32 = 46
    bh : f32 = 32

    if win_ctrl_btn(dl, x0, y0, bw, bh, icon(CP_MIN), false) {
        sdl2.MinimizeWindow(g_window)
    }

    glyph := frame_is_maximized() ? icon(CP_RESTORE) : icon(CP_MAX)
    if win_ctrl_btn(dl, x0 + bw, y0, bw, bh, glyph, false) {
        toggle_maximize()
    }

    if win_ctrl_btn(dl, x0 + bw*2, y0, bw, bh, icon(CP_CLOSE), true) {
        ev := sdl2.Event{ type = .QUIT }
        sdl2.PushEvent(&ev)
    }
}

win_ctrl_btn :: proc(dl: ^im.DrawList, x, y, w, h: f32, glyph: cstring, danger: bool) -> bool {
    im.SetCursorScreenPos({x, y})
    clicked := im.InvisibleButton(fmt.ctprintf("##wc_%s", glyph), {w, h})
    hov := im.IsItemHovered()
    if hov {
        hc : u32 = danger ? 0xe81123 : ICONBTN_H
        im.DrawList_AddRectFilled(dl, {x, y}, {x + w, y + h}, col(hc), 0)
    }
    tc : u32 = (danger && hov) ? 0xffffff : SUBTEXT_C
    ts := im.CalcTextSize(glyph)
    im.DrawList_AddText(dl, {x + (w - ts.x)/2, y + (h - ts.y)/2}, col(tc), glyph)
    return clicked
}

// ── Toolbar (navegação + omnibox + menu) ────────────────────────────────────

draw_toolbar :: proc(s: ^State) {
    dl     := im.GetWindowDrawList()
    origin := im.GetCursorScreenPos()
    bar_h  : f32 = 48
    avail  := im.GetContentRegionAvail().x

    // fundo da toolbar (mesma cor da aba ativa = conectado)
    im.DrawList_AddRectFilled(dl, origin, {origin.x + avail, origin.y + bar_h}, col(TOOLBAR), 0)

    has_tab  := len(s.tabs) > 0
    has_url  := has_tab && s.tabs[s.active].url != ""
    can_back := has_tab && s.tabs[s.active].hist_idx > 0
    can_fwd  := has_tab && s.tabs[s.active].hist_idx < len(s.tabs[s.active].history) - 1
    y := origin.y + bar_h/2

    x : f32 = origin.x + 10
    if icon_btn(dl, &x, y, IC_BACK,   can_back, false) do go_back(s)
    if icon_btn(dl, &x, y, IC_FWD,    can_fwd,  false) do go_forward(s)
    if icon_btn(dl, &x, y, IC_RELOAD, has_url,  false) do reload_page(s)

    x += 6

    // omnibox (pílula)
    menu_w  : f32 = 44
    box_x0  := x
    box_x1  := origin.x + avail - menu_w - 10
    box_y0  := y - 16
    box_y1  := y + 16
    box_w   := box_x1 - box_x0

    im.DrawList_AddRectFilled(dl, {box_x0, box_y0}, {box_x1, box_y1}, col(OMNIBOX), 16)
    // ícone de cadeado
    im.DrawList_AddText(dl, {box_x0 + 12, y - 10}, col(SUBTEXT_C), IC_LOCK)

    star_w : f32 = 34 // espaço reservado p/ a estrela na ponta direita da pílula

    im.SetCursorScreenPos({box_x0 + 30, box_y0 + 4})
    im.SetNextItemWidth(box_w - 40 - star_w)
    if g_focus_url {
        im.SetKeyboardFocusHere() // foca a URL (aba nova / startup)
        g_focus_url = false
    }
    // frame transparente (0 = RGBA totalmente transparente): o fundo é a pílula desenhada
    im.PushStyleColor(.FrameBg,        0)
    im.PushStyleColor(.FrameBgHovered, 0)
    im.PushStyleColor(.FrameBgActive,  0)
    push_col(.Text, TEXT_C)
    if im.InputTextWithHint("##url", "Pesquise no Google ou digite um endereço",
        cstring(raw_data(s.url_buf[:])), c.size_t(URL_LIMIT), {.EnterReturnsTrue}) {
        navigate(s)
    }
    im.PopStyleColor(4)

    // estrela de favorito (dentro da pílula, à direita). Cheia = já salvo.
    // Desenhada DEPOIS do input p/ ficar por cima e receber o clique.
    if has_url {
        cur_url  := s.tabs[s.active].url
        faved    := bookmark_index(cur_url) >= 0
        sb_x     := box_x1 - star_w
        im.SetCursorScreenPos({sb_x, y - star_w/2})
        if im.InvisibleButton("##fav", {star_w, star_w}) {
            bookmark_toggle(cur_url, s.tabs[s.active].title)
        }
        if im.IsItemHovered() {
            im.DrawList_AddRectFilled(dl, {sb_x, y - 15}, {sb_x + star_w, y + 15}, col(ICONBTN_H), 8)
        }
        glyph := faved ? icon(CP_STAR_FILL) : icon(CP_STAR)
        gc    : u32 = faved ? 0xE8C25B : SUBTEXT_C // dourado quando salvo
        gs    := im.CalcTextSize(glyph)
        im.DrawList_AddText(dl, {sb_x + (star_w - gs.x)/2, y - gs.y/2}, col(gc), glyph)
    }

    // menu (hambúrguer)
    mx := origin.x + avail - menu_w
    icon_btn_at(dl, mx + 6, y, IC_MENU)

    im.SetCursorScreenPos({origin.x, origin.y + bar_h})
}

// botão de ícone que avança o cursor x; retorna true se clicado
icon_btn :: proc(dl: ^im.DrawList, x: ^f32, y: f32, glyph: cstring, enabled: bool, _: bool) -> bool {
    size : f32 = 34
    bx := x^
    im.SetCursorScreenPos({bx, y - size/2})
    clicked := false
    if enabled {
        clicked = im.InvisibleButton(fmt.ctprintf("##ib_%s", glyph), {size, size})
        if im.IsItemHovered() {
            im.DrawList_AddRectFilled(dl, {bx, y - size/2}, {bx + size, y + size/2}, col(ICONBTN_H), 8)
        }
    }
    tc : u32 = enabled ? SUBTEXT_C : 0x5a5a5c
    ts := im.CalcTextSize(glyph)
    im.DrawList_AddText(dl, {bx + (size - ts.x)/2, y - ts.y/2}, col(tc), glyph)
    x^ = bx + size + 2
    return clicked
}

icon_btn_at :: proc(dl: ^im.DrawList, bx, y: f32, glyph: cstring) {
    size : f32 = 34
    im.SetCursorScreenPos({bx, y - size/2})
    im.InvisibleButton(fmt.ctprintf("##iba_%s", glyph), {size, size})
    if im.IsItemHovered() {
        im.DrawList_AddRectFilled(dl, {bx, y - size/2}, {bx + size, y + size/2}, col(ICONBTN_H), 8)
    }
    ts := im.CalcTextSize(glyph)
    im.DrawList_AddText(dl, {bx + (size - ts.x)/2, y - ts.y/2}, col(SUBTEXT_C), glyph)
}

// ── Conteúdo (viewport) ─────────────────────────────────────────────────────

draw_content :: proc(s: ^State) {
    avail := im.GetContentRegionAvail()
    avail.y -= 24 // barra de status
    if g_devtools_open do avail.y -= g_devtools_h // painel DevTools (desenhado após o viewport)
    g_viewport_valid = false // revalidado no branch de render (p/ o highlight do inspetor)

    // Páginas renderizadas usam o fundo do CSS (branco por padrão);
    // telas internas (nova aba / carregando) usam o fundo escuro.
    bg : u32 = PAGE_BG
    rendering := len(s.tabs) > 0 && s.tabs[s.active].url != "" &&
                 !s.tabs[s.active].loading && s.tabs[s.active].dom != nil
    if rendering do bg = s.tabs[s.active].page_bg

    push_col(.ChildBg, bg)
    // NoScrollWithMouse: a roda é roteada manualmente (elementos roláveis a
    // consomem primeiro; o resto vai p/ a página) — senão a página rolaria junto.
    im.BeginChild("##viewport", avail, {}, {.NoScrollWithMouse})
    defer { im.EndChild(); im.PopStyleColor(1) }

    if len(s.tabs) == 0 do return
    tab := s.tabs[s.active]

    switch {
    case tab.url == "":
        draw_new_tab_page(s, avail)
    case tab.loading:
        im.SetCursorPos({16, 16})
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted(fmt.ctprintf("Carregando %s ...", tab.url))
        im.PopStyleColor(1)
    case:
        // Zoom mudou (Ctrl +/-) ou a aba foi computada com outro zoom: re-estiliza
        // e reconstrói o layout desta aba com o g_zoom atual, e reflete na cópia.
        if s.tabs[s.active].zoom_applied != g_zoom {
            restyle_tab(&s.tabs[s.active], avail.x, avail.y)
            tab = s.tabs[s.active]
        }
        // Layout engine: calcula posições/tamanhos e pinta.
        if tab.layout != nil {
            layout_box(tab.layout, 0, 0, avail.x)
            // Fonte do getComputedStyle desta aba. Setado por FRAME (e não só no
            // restyle_tab) porque a troca de aba não re-estiliza: o mapa vem pronto
            // do worker por poll_jobs, e sem isto o hook responderia com o estilo da
            // aba ANTERIOR. Vem antes do dispatch de clique e do pump de timers —
            // os dois pontos deste frame em que o JS pode rodar.
            js_style_source_set(tab.styles, tab.layout, avail.x, avail.y, laid_out = true)
            // Scroll da página p/ o getBoundingClientRect (coords do VIEWPORT) e p/
            // window.scrollY. Estamos DENTRO do child rolado, então é aqui que o
            // valor existe.
            js_scroll_set(im.GetScrollX(), im.GetScrollY())
            // Container queries: o layout acima MEDIU os contêineres; se a medida
            // difere da que o estilo usou, reestiliza UMA vez e relayouta. Converge
            // em 2 passadas (container-type = contenção → a medida não muda depois).
            if g_container_dirty {
                g_container_dirty = false
                restyle_tab(&s.tabs[s.active], avail.x, avail.y)
                tab = s.tabs[s.active]
                if tab.layout != nil do layout_box(tab.layout, 0, 0, avail.x)
            }
            // cb = ICB, que tem as DIMENSÕES DO VIEWPORT (CSS 2.1 §10.1) — não a
            // altura do documento: com `html{position:absolute}` o root sai do fluxo,
            // sua altura vira 0 e um ICB=altura-do-doc resolveria o próprio html como
            // 0 (circular) → a página inteira colapsa (bandcamp/coingecko).
            // page = viewport (p/ position:fixed — bottom:0 na base da janela).
            view_rect := Rect{0, 0, avail.x, avail.y}
            layout_absolutes(tab.layout, view_rect, view_rect)
            s.click_target = nil       // paint_box grava aqui se houver clique
            s.aux_node = nil; s.aux_href = "" // idem p/ o botão do meio

            // Amostra a origem de conteúdo do viewport em tela p/ o highlight do
            // inspetor: paint_box mapeia screen(box) = origem + {box.x, box.y} (o
            // GetCursorScreenPos já aplica o -scroll do child). Mesma janela/frame.
            im.SetCursorPos({0, 0})
            g_viewport_o = im.GetCursorScreenPos()
            wp := im.GetWindowPos(); ws := im.GetWindowSize()
            g_viewport_clip = {wp.x, wp.y, wp.x + ws.x, wp.y + ws.y}
            g_viewport_size = avail
            g_viewport_valid = true

            paint_layout(s, tab.layout)

            // Informa ao ImGui a altura total do documento p/ habilitar o scroll da
            // página (o child ##viewport rola com a roda; paint_box já posiciona via
            // GetCursorScreenPos, que aplica o offset de scroll automaticamente).
            // A extensão rolável é a MAIOR extensão do conteúdo (inclui out-of-flow
            // absolute/sticky), não só a altura em fluxo do root: sites cujo conteúdo
            // vive em wrapper posicionado (skin Vector da wikipedia) deixavam
            // tab.layout.h ≈ viewport → a página NÃO rolava embora tivesse milhares de
            // px abaixo da dobra. Fixed fica de fora (colado no viewport).
            scroll_h := tab.layout.h
            if ext := box_scroll_extent(tab.layout); ext > scroll_h do scroll_h = ext
            im.SetCursorPos({0, scroll_h})
            im.Dummy({1, 1})

            // scroll da página: aplica a roda RESTANTE (não consumida por um
            // elemento rolável durante o paint). ImGui clampa à extensão do conteúdo.
            io := im.GetIO()
            if io.MouseWheel != 0 && im.IsWindowHovered({}) {
                im.SetScrollY(im.GetScrollY() - io.MouseWheel * 60)
            }

            // scroll de âncora pendente (#id): pulo instantâneo, ou animação suave
            // se a raiz tem scroll-behavior:smooth. A roda do usuário cancela.
            if s.scroll_pending {
                if io.MouseWheel != 0 {
                    s.scroll_pending = false // usuário assumiu o controle
                } else {
                    cur := im.GetScrollY()
                    tgt := clamp(s.scroll_target, 0, im.GetScrollMaxY())
                    if s.scroll_smooth {
                        d := tgt - cur
                        if abs(d) < 1.5 { im.SetScrollY(tgt); s.scroll_pending = false }
                        else            { im.SetScrollY(cur + d * 0.2) } // ease-out
                    } else {
                        im.SetScrollY(tgt); s.scroll_pending = false
                    }
                }
            }

            // POR ÚLTIMO: dispara handlers JS do clique. Pode liberar e reconstruir
            // tab.layout — por isso vem depois de todos os usos da cópia `tab` acima.
            // O layout novo entra em vigor no próximo frame (que re-copia o ponteiro).
            dispatch_page_click(s, avail.x, avail.y)
            // botão do meio (mousedown/mouseup/auxclick + abrir link em aba de
            // fundo). Mesma regra: depois do paint, pode reconstruir o layout.
            dispatch_page_aux(s, avail.x, avail.y)

            // escolha num <select> (o combo do paint só REGISTRA; aqui aterra no
            // DOM e vira evento, com o layout já livre p/ ser reconstruído).
            dispatch_select_change(s, avail.x, avail.y)

            // timers JS (setTimeout/setInterval): avança o relógio do vm e dispara
            // os vencidos. Mesma regra do clique: por último, pois pode re-layout.
            // Só a aba ativa é bombeada (timers de abas em fundo ficam pausados).
            if atab := &s.tabs[s.active]; atab.vm != nil {
                // IntersectionObserver: um passo por frame, DEPOIS do layout deste
                // frame (js_style_source_set lá em cima já marcou laid_out) — é o
                // que faz o observador reagir ao SCROLL, que não passa por funil
                // nenhum. Junto do pump porque as duas são "JS do frame" e caem no
                // mesmo guarda de re-estilizar só se o DOM mudou.
                fired := animation_dispatch(atab.layout, atab.vm)
                if jspkg.vm_pump_timers(atab.vm, f64(io.DeltaTime) * 1000) do fired = true
                if jspkg.vm_frame_step(atab.vm) do fired = true
                if fired {
                    // Um timer DISPAROU — o que não quer dizer que ele mexeu no
                    // DOM. Antes re-estilizávamos sempre, então um setInterval de
                    // analytics/relógio custava compute_styles + build_layout
                    // INTEIROS por frame. Agora a varredura O(nós) do fingerprint
                    // decide (ordens de grandeza mais barata que o restyle).
                    if atab.dom != nil && dompkg.fingerprint(atab.dom) != atab.dom_fp {
                        restyle_tab(atab, avail.x, avail.y)
                    }
                }
            }
        }
    }
}

// ── DevTools (painel inferior: Console + Elements) ──────────────────────────
// #1 Console: lê vm.console_buf da aba ativa (capturado em interp.odin).
// #2 Elements: árvore do DOM (tab.dom) + detalhes do nó + highlight na página.

DEVTOOLS_HDR :: 0x2a2a2c // barra de abas do painel
DEVTOOLS_BG  :: 0x141416 // fundo do painel (mais escuro que o viewport)
DEVTOOLS_WARN :: 0xe2c08d // amarelo âmbar (console.warn)
DEVTOOLS_ERR  :: 0xf07178 // vermelho (console.error)
DEVTOOLS_TAG  :: 0x8fd0ff // azul-claro (nome de tag)
DEVTOOLS_ATTR :: 0xd7a3ff // roxo (atributos)
DEVTOOLS_HL   :: 0x6ca0f0 // azul do highlight na página
DEVTOOLS_REPL :: 0x9cdcaa // verde (resultado do REPL)

draw_devtools :: proc(s: ^State) {
    io := im.GetIO()

    // ── Alça de redimensionar (borda superior do painel) ────────────────────
    grip_w := im.GetContentRegionAvail().x
    im.InvisibleButton("##dt_grip", {grip_w, 6})
    if im.IsItemHovered() || im.IsItemActive() do im.SetMouseCursor(.ResizeNS)
    if im.IsItemActive() {
        g_devtools_h -= io.MouseDelta.y
        max_h := io.DisplaySize.y - 220 // deixa espaço p/ chrome + status
        g_devtools_h = clamp(g_devtools_h, 120, max(120, max_h))
    }

    push_col(.ChildBg, DEVTOOLS_BG)
    im.BeginChild("##devtools", {0, g_devtools_h - 6}, {}, {.NoScrollWithMouse}) // -6 = a alça acima
    defer { im.EndChild(); im.PopStyleColor(1) }

    // ── Barra de abas (Console / Elements) + Fechar ─────────────────────────
    dl := im.GetWindowDrawList()
    p0 := im.GetCursorScreenPos()
    bar_w := im.GetContentRegionAvail().x
    im.DrawList_AddRectFilled(dl, p0, {p0.x + bar_w, p0.y + 30}, col(DEVTOOLS_HDR))

    im.SetCursorPos({6, 4})
    dt_tab_button("Console",  .Console)
    im.SameLine(0, 4)
    dt_tab_button("Elements", .Elements)

    im.SameLine(0, 0); im.SetCursorPosX(bar_w - 62)
    if im.SmallButton("Fechar") do g_devtools_open = false

    im.SetCursorPos({0, 32})
    im.Separator()

    switch g_devtools_tab {
    case .Console:  dt_console_panel(s)
    case .Elements: dt_elements_panel(s)
    }
}

// Botão de aba com realce do ativo.
dt_tab_button :: proc(label: cstring, tab: Devtools_Tab) {
    active := g_devtools_tab == tab
    push_col(.Button,        active ? 0x3a3a3c : DEVTOOLS_HDR)
    push_col(.ButtonHovered, 0x454547)
    push_col(.Text,          active ? TEXT_C : SUBTEXT_C)
    if im.Button(label) do g_devtools_tab = tab
    im.PopStyleColor(3)
}

// ── Aba Console (log + REPL) ────────────────────────────────────────────────
dt_console_panel :: proc(s: ^State) {
    vm := s.tabs[s.active].vm if len(s.tabs) > 0 else nil

    im.Checkbox("Logs",   &g_devtools_show[0]); im.SameLine(0, 12)
    im.Checkbox("Avisos", &g_devtools_show[1]); im.SameLine(0, 12)
    im.Checkbox("Erros",  &g_devtools_show[2])
    im.SameLine(0, 0); im.SetCursorPosX(im.GetContentRegionAvail().x - 52)
    if im.SmallButton("Limpar") && vm != nil do jspkg.vm_console_clear(vm)

    avail := im.GetContentRegionAvail()
    dt_console_log(vm, avail.y - 30) // área rolável; reserva ~30px p/ a linha do REPL
    dt_repl_input(s, vm)
}

// Área rolável do log. Input/Result (REPL) sempre visíveis; Log/Warn/Error filtrados.
dt_console_log :: proc(vm: ^jspkg.Interp, height: f32) {
    push_col(.ChildBg, DEVTOOLS_BG)
    im.BeginChild("##dt_log", {0, height}, {}, {})
    defer { im.EndChild(); im.PopStyleColor(1) }

    if vm == nil || len(vm.console_buf) == 0 {
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted(vm == nil ? "Sem contexto JS nesta aba." : "Console vazio.")
        im.PopStyleColor(1)
        return
    }

    stick := im.GetScrollY() >= im.GetScrollMaxY() - 4 // fixa no fim se já estava no fim
    im.PushTextWrapPos(0)
    for e in vm.console_buf {
        c:      u32    = TEXT_C
        prefix: string = ""
        show := true
        #partial switch e.level {
        case .Log:    show = g_devtools_show[0]
        case .Warn:   show = g_devtools_show[1]; c = DEVTOOLS_WARN
        case .Error:  show = g_devtools_show[2]; c = DEVTOOLS_ERR
        case .Input:  c = SUBTEXT_C;    prefix = "› " // eco do que foi digitado
        case .Result: c = DEVTOOLS_REPL; prefix = "‹ " // valor de retorno
        }
        if !show do continue
        push_col(.Text, c)
        im.TextUnformatted(strings.clone_to_cstring(fmt.tprintf("%s%s", prefix, e.text), context.temp_allocator))
        im.PopStyleColor(1)
    }
    im.PopTextWrapPos()
    if stick do im.SetScrollHereY(1.0)
}

// Linha de entrada do REPL: avalia JS no vm da página ao pressionar Enter.
dt_repl_input :: proc(s: ^State, vm: ^jspkg.Interp) {
    if vm == nil {
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted("REPL indisponível: esta aba não tem contexto JS.")
        im.PopStyleColor(1)
        return
    }
    push_col(.Text, DEVTOOLS_REPL); im.TextUnformatted("›"); im.PopStyleColor(1)
    im.SameLine(0, 6)
    im.SetNextItemWidth(-1) // ocupa a largura restante
    push_col(.FrameBg, 0x202022)
    entered := im.InputText("##repl", cstring(raw_data(g_repl_buf[:])), c.size_t(REPL_LIMIT),
        {.EnterReturnsTrue})
    im.PopStyleColor(1)
    if entered {
        src := string(cstring(raw_data(g_repl_buf[:])))
        if strings.trim_space(src) != "" {
            jspkg.vm_repl_eval(vm, src)
            // o snippet pode ter mexido no DOM/estilo: re-estiliza p/ refletir na página
            if g_viewport_valid {
                restyle_tab(&s.tabs[s.active], g_viewport_size.x, g_viewport_size.y)
            }
        }
        g_repl_buf[0] = 0                // limpa a linha
        im.SetKeyboardFocusHere(-1)      // mantém o foco no campo p/ o próximo comando
    }
}

// ── Aba Elements (inspetor de DOM) ──────────────────────────────────────────
dt_elements_panel :: proc(s: ^State) {
    if len(s.tabs) == 0 || s.tabs[s.active].dom == nil {
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted("Sem documento nesta aba.")
        im.PopStyleColor(1)
        return
    }
    tab := &s.tabs[s.active]

    avail := im.GetContentRegionAvail()
    tree_w := avail.x * 0.6

    // ── Árvore do DOM (esquerda) ────────────────────────────────────────────
    im.BeginChild("##dt_tree", {tree_w, 0}, {.Borders}, {})
    g_dt_hover = nil // recomputado a cada frame pelos IsItemHovered da árvore
    dt_dom_node(tab.dom, 0)
    im.EndChild()

    im.SameLine(0, 4)

    // ── Detalhes do nó selecionado (direita) ────────────────────────────────
    im.BeginChild("##dt_details", {0, 0}, {.Borders}, {})
    dt_node_details(tab)
    im.EndChild()

    // ── Highlight na página: nó sob o mouse; se nenhum, o selecionado ────────
    target := g_dt_hover != nil ? g_dt_hover : g_dt_sel
    dt_page_highlight(tab, target)
}

// Desenha um nó do DOM na árvore (recursivo). depth só limita a auto-abertura.
dt_dom_node :: proc(n: ^dompkg.Node, depth: int) {
    #partial switch n.kind {
    case .Text:
        t := strings.trim_space(n.text)
        if t == "" do return // nós de texto só-whitespace: ruído, ignora
        im.PushIDPtr(n)
        flags := im.TreeNodeFlags{.Leaf, .NoTreePushOnOpen, .SpanAvailWidth}
        if rawptr(n) == g_dt_sel do flags += {.Selected}
        push_col(.Text, SUBTEXT_C)
        im.TreeNodeEx(fmt.ctprintf("\"%s\"", dt_ellipsis(t, 48)), flags)
        im.PopStyleColor(1)
        dt_node_interact(n)
        im.PopID()

    case .Comment:
        im.PushIDPtr(n)
        flags := im.TreeNodeFlags{.Leaf, .NoTreePushOnOpen, .SpanAvailWidth}
        if rawptr(n) == g_dt_sel do flags += {.Selected}
        push_col(.Text, 0x6f7f6f) // verde-acinzentado (comentário)
        im.TreeNodeEx(fmt.ctprintf("<!-- %s -->", dt_ellipsis(strings.trim_space(n.text), 40)), flags)
        im.PopStyleColor(1)
        dt_node_interact(n)
        im.PopID()

    case .Element, .Document:
        // filhos "visíveis" (ignora texto só-whitespace) determinam se há seta
        has_kids := false
        for c in n.children {
            if c.kind == .Text && strings.trim_space(c.text) == "" do continue
            has_kids = true; break
        }
        im.PushIDPtr(n)
        flags := im.TreeNodeFlags{.OpenOnArrow, .SpanAvailWidth}
        if !has_kids do flags += {.Leaf, .NoTreePushOnOpen}
        if rawptr(n) == g_dt_sel do flags += {.Selected}
        if depth < 2 do flags += {.DefaultOpen} // html/body já abertos
        push_col(.Text, DEVTOOLS_TAG)
        open := im.TreeNodeEx(dt_element_label(n), flags)
        im.PopStyleColor(1)
        dt_node_interact(n)
        if open && has_kids {
            for c in n.children do dt_dom_node(c, depth + 1)
            im.TreePop()
        }
        im.PopID()
    }
}

// Hover → highlight; clique → seleciona. Chamado logo após o item da árvore.
dt_node_interact :: proc(n: ^dompkg.Node) {
    if im.IsItemHovered() do g_dt_hover = rawptr(n)
    if im.IsItemClicked() do g_dt_sel  = rawptr(n)
}

// Rótulo estilo seletor CSS: tag#id.classe (compacto, como os DevTools de verdade).
dt_element_label :: proc(n: ^dompkg.Node) -> cstring {
    if n.kind == .Document do return "#document"
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, n.tag != "" ? n.tag : "?")
    if id, ok := n.attrs["id"]; ok && id != "" {
        strings.write_byte(&sb, '#'); strings.write_string(&sb, id)
    }
    if cls, ok := n.attrs["class"]; ok && cls != "" {
        // só a 1ª classe, p/ não estourar a linha
        first := cls
        if sp := strings.index_byte(cls, ' '); sp >= 0 do first = cls[:sp]
        strings.write_byte(&sb, '.'); strings.write_string(&sb, first)
    }
    return strings.clone_to_cstring(strings.to_string(sb), context.temp_allocator)
}

dt_ellipsis :: proc(s: string, n: int) -> string {
    if len(s) <= n do return s
    return fmt.tprintf("%s…", s[:n])
}

// Painel de detalhes: atributos + métricas de caixa do nó selecionado.
dt_node_details :: proc(tab: ^Tab) {
    if g_dt_sel == nil {
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted("Selecione um nó na árvore.")
        im.PopStyleColor(1)
        return
    }
    n := (^dompkg.Node)(g_dt_sel)

    push_col(.Text, DEVTOOLS_TAG)
    im.TextUnformatted(dt_element_label(n))
    im.PopStyleColor(1)
    im.Separator()

    if n.kind == .Text || n.kind == .Comment {
        push_col(.Text, TEXT_C)
        im.PushTextWrapPos(0)
        im.TextUnformatted(strings.clone_to_cstring(strings.trim_space(n.text), context.temp_allocator))
        im.PopTextWrapPos()
        im.PopStyleColor(1)
        return
    }

    // Atributos
    if len(n.attrs) > 0 {
        push_col(.Text, SUBTEXT_C); im.TextUnformatted("Atributos"); im.PopStyleColor(1)
        for k, v in n.attrs {
            push_col(.Text, DEVTOOLS_ATTR)
            im.TextUnformatted(strings.clone_to_cstring(k, context.temp_allocator))
            im.PopStyleColor(1)
            im.SameLine(0, 6); push_col(.Text, TEXT_C)
            im.TextUnformatted(strings.clone_to_cstring(fmt.tprintf("= %s", dt_ellipsis(v, 80)), context.temp_allocator))
            im.PopStyleColor(1)
        }
        im.Separator()
    }

    // Métricas de caixa (do layout, se o nó tem caixa)
    b := tab.layout != nil ? dt_find_box(tab.layout, g_dt_sel) : nil
    if b == nil {
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted("Sem caixa no layout (display:none, inline ou <head>).")
        im.PopStyleColor(1)
        return
    }
    push_col(.Text, SUBTEXT_C); im.TextUnformatted("Caixa"); im.PopStyleColor(1)
    push_col(.Text, TEXT_C)
    im.TextUnformatted(fmt.ctprintf("tamanho   %.0f × %.0f px", b.w, b.h))
    im.TextUnformatted(fmt.ctprintf("posição   x %.0f, y %.0f", b.x, b.y))
    im.TextUnformatted(fmt.ctprintf("padding   %.0f %.0f %.0f %.0f", b.padding[0], b.padding[1], b.padding[2], b.padding[3]))
    im.TextUnformatted(fmt.ctprintf("margin    %.0f %.0f %.0f %.0f", b.margin[0], b.margin[1], b.margin[2], b.margin[3]))
    im.TextUnformatted(fmt.ctprintf("border    %.0f %.0f %.0f %.0f", b.border_w[0], b.border_w[1], b.border_w[2], b.border_w[3]))
    im.PopStyleColor(1)
    if b.has_bg {
        im.TextUnformatted("background")
        im.SameLine(0, 8)
        sw := im.GetCursorScreenPos()
        im.DrawList_AddRectFilled(im.GetWindowDrawList(), sw, {sw.x + 16, sw.y + 16}, col(b.bg), 3)
        im.DrawList_AddRect(im.GetWindowDrawList(), sw, {sw.x + 16, sw.y + 16}, col(0x808080), 3)
        im.Dummy({20, 16}); im.SameLine(0, 6)
        push_col(.Text, SUBTEXT_C)
        im.TextUnformatted(fmt.ctprintf("#%06X", b.bg & 0xffffff))
        im.PopStyleColor(1)
    }
}

// Acha a caixa de layout cujo .node == alvo (busca em profundidade, incl. inline-block).
dt_find_box :: proc(b: ^Box, node: rawptr) -> ^Box {
    if b == nil do return nil
    if rawptr(b.node) == node do return b
    for c in b.children {
        if r := dt_find_box(c, node); r != nil do return r
    }
    for it in b.inlines {
        if it.box != nil {
            if r := dt_find_box(it.box, node); r != nil do return r
        }
    }
    return nil
}

// Desenha o realce da caixa do nó sobre a página (draw list de primeiro plano,
// recortado à área do viewport). Mapeia coords de caixa → tela via g_viewport_o.
dt_page_highlight :: proc(tab: ^Tab, node: rawptr) {
    if node == nil || !g_viewport_valid || tab.layout == nil do return
    b := dt_find_box(tab.layout, node)
    if b == nil do return

    x0 := g_viewport_o.x + b.x
    y0 := g_viewport_o.y + b.y
    x1 := x0 + b.w
    y1 := y0 + b.h

    fdl := im.GetForegroundDrawList()
    im.DrawList_PushClipRect(fdl, {g_viewport_clip[0], g_viewport_clip[1]}, {g_viewport_clip[2], g_viewport_clip[3]}, true)
    im.DrawList_AddRectFilled(fdl, {x0, y0}, {x1, y1}, col_o(DEVTOOLS_HL, 0.25))
    im.DrawList_AddRect(fdl, {x0, y0}, {x1, y1}, col(DEVTOOLS_HL), 0, {}, 1.5)
    im.DrawList_PopClipRect(fdl)
}

draw_new_tab_page :: proc(s: ^State, avail: im.Vec2) {
    title :: "Odin Browser"
    im.PushFont(g_font_big)
    tsize := im.CalcTextSize(title)
    im.SetCursorPos({(avail.x - tsize.x)/2, avail.y/2 - 90})
    push_col(.Text, TEXT_C)
    im.TextUnformatted(title)
    im.PopStyleColor(1)
    im.PopFont()

    // grande barra de busca central (pílula)
    box_w : f32 = 560
    box_h : f32 = 50
    bx := (avail.x - box_w)/2
    by := avail.y/2 - 20
    im.SetCursorPos({bx, by})
    dl := im.GetWindowDrawList()
    p  := im.GetCursorScreenPos()
    im.DrawList_AddRectFilled(dl, p, {p.x + box_w, p.y + box_h}, col(PAGE_BOX), 25)
    im.DrawList_AddText(dl, {p.x + 20, p.y + box_h/2 - 11}, col(SUBTEXT_C), IC_SEARCH)
    im.DrawList_AddText(dl, {p.x + 46, p.y + box_h/2 - 9}, col(SUBTEXT_C), "Pesquise no Google ou digite um endereço")

    // ── Atalhos de favoritos (grade centralizada abaixo da busca) ────────────
    if len(g_bookmarks) == 0 do return
    TILE_W   : f32 = 100
    TILE_H   : f32 = 88
    GAP      : f32 = 16
    PER_ROW  :: 6
    shown    := min(len(g_bookmarks), 18) // teto p/ não estourar a tela
    per_row  := min(shown, PER_ROW)
    grid_w   := f32(per_row)*TILE_W + f32(per_row - 1)*GAP
    grid_x0  := (avail.x - grid_w)/2
    grid_y0  := by + box_h + 40

    for i in 0 ..< shown {
        bm  := g_bookmarks[i]
        row := i / PER_ROW
        cln := i % PER_ROW
        tx  := grid_x0 + f32(cln)*(TILE_W + GAP)
        ty  := grid_y0 + f32(row)*(TILE_H + GAP)

        im.SetCursorPos({tx, ty})
        if im.InvisibleButton(fmt.ctprintf("##bm_%d", i), {TILE_W, TILE_H}) {
            start_navigation(s, bm.url)
        }
        hovered := im.IsItemHovered()
        tp := im.GetItemRectMin() // canto do tile em coords de tela

        // moldura arredondada (realce no hover)
        if hovered {
            im.DrawList_AddRectFilled(dl, tp, {tp.x + TILE_W, tp.y + TILE_H}, col(PAGE_BOX), 12)
        }
        // "ícone": círculo com a inicial do site
        cx := tp.x + TILE_W/2
        cy := tp.y + 30
        im.DrawList_AddCircleFilled(dl, {cx, cy}, 22, col(0x3a3a3c))
        initial := bookmark_initial(bm)
        is_ := im.CalcTextSize(initial)
        im.DrawList_AddText(dl, {cx - is_.x/2, cy - is_.y/2}, col(TEXT_C), initial)

        // título abaixo, truncado ao caber
        label := bookmark_label(bm)
        ls := im.CalcTextSize(label)
        lx := cx - ls.x/2
        if lx < tp.x + 4 do lx = tp.x + 4
        im.DrawList_AddText(dl, {lx, tp.y + 60}, col(SUBTEXT_C), label)
    }
}

// Inicial (maiúscula) do favorito p/ desenhar no círculo do atalho.
bookmark_initial :: proc(bm: Bookmark) -> cstring {
    src := bm.title != "" ? bm.title : bm.url
    src = strings.trim_prefix(src, "https://")
    src = strings.trim_prefix(src, "http://")
    src = strings.trim_prefix(src, "www.")
    if src == "" do return "?"
    r := rune(src[0])
    if r >= 'a' && r <= 'z' do r -= 32
    return icon(r)
}

// Rótulo curto do atalho: host sem esquema/www, cortado em ~14 chars.
bookmark_label :: proc(bm: Bookmark) -> cstring {
    t := bm.title != "" ? bm.title : bm.url
    t = strings.trim_prefix(t, "https://")
    t = strings.trim_prefix(t, "http://")
    t = strings.trim_prefix(t, "www.")
    if slash := strings.index_byte(t, '/'); slash > 0 do t = t[:slash] // só o host
    if len(t) > 14 do return fmt.ctprintf("%s…", t[:13])
    return strings.clone_to_cstring(t, context.temp_allocator)
}

// ── Barra de status ─────────────────────────────────────────────────────────

draw_status_bar :: proc(s: ^State) {
    push_col(.ChildBg, STATUS_BG)
    im.BeginChild("##status", {0, 24}, {}, {.NoScrollbar, .NoScrollWithMouse})
    defer { im.EndChild(); im.PopStyleColor(1) }
    im.SetCursorPos({12, 4})
    push_col(.Text, 0x6a6a6c)
    im.TextUnformatted(strings.clone_to_cstring(s.status, context.temp_allocator))
    im.PopStyleColor(1)
}

// ── Visualização da árvore DOM ──────────────────────────────────────────────

build_tree_view :: proc(root: ^dompkg.Node) -> string {
    sb := strings.builder_make()
    count := 0
    dump_dom(root, &sb, 0, &count, 1500) // limita p/ não explodir em páginas grandes
    return strings.to_string(sb)
}

dump_dom :: proc(n: ^dompkg.Node, sb: ^strings.Builder, depth: int, count: ^int, limit: int) {
    if count^ >= limit do return

    for _ in 0 ..< depth do strings.write_string(sb, "  ")

    switch n.kind {
    case .Document:
        strings.write_string(sb, "#document")
    case .Element:
        strings.write_byte(sb, '<')
        strings.write_string(sb, n.tag)
        for k, v in n.attrs {
            strings.write_byte(sb, ' ')
            strings.write_string(sb, k)
            if v != "" {
                strings.write_string(sb, "=\"")
                strings.write_string(sb, v)
                strings.write_byte(sb, '"')
            }
        }
        strings.write_byte(sb, '>')
    case .Text:
        t := strings.trim_space(n.text)
        if len(t) > 80 do t = t[:80]
        strings.write_byte(sb, '"')
        strings.write_string(sb, t)
        strings.write_byte(sb, '"')
    case .Comment:
        strings.write_string(sb, "<!-- ... -->")
    }
    strings.write_byte(sb, '\n')
    count^ += 1

    for c in n.children {
        dump_dom(c, sb, depth + 1, count, limit)
    }
}

// ── Navegação ───────────────────────────────────────────────────────────────

sync_url_buf :: proc(s: ^State) {
    if len(s.tabs) == 0 do return
    url := s.tabs[s.active].url
    for &b in s.url_buf do b = 0
    copy(s.url_buf[:], url)
}

// O que a barra de endereço faz com o texto DIGITADO. Separado do `navigate`
// para poder ser testado sem rede (o navigate dispara o fetch numa thread).
//   • http/https passam intactos;
//   • `file:` em qualquer grafia (`file:///C:/x`, `file://C:/x`, `file:/C:/x`,
//     `file:C:/x`, maiúsculas) sai CANONIZADO por `net.normalize_file_url` —
//     que é a MESMA função usada na resolução de href, então a barra e a página
//     nunca discordam sobre o que uma URL de arquivo significa;
//   • caminho de Windows (`C:\x` ou `C:/x`) vira `file:///C:/x` — é o que o
//     usuário digita quando quer abrir um arquivo local;
//   • o resto ganha `https://`, com o fallback p/ http que já existia
//     (auto_https), que é o caso "digitei só o domínio".
// ⚠️ Devolve string do TEMP allocator nos casos que reescrevem; quem chama
// (start_navigation) clona.
url_from_bar :: proc(input: string) -> (url: string, auto_https: bool) {
    t := strings.trim_space(input)
    if t == "" do return "", false
    if strings.has_prefix(t, "http://") || strings.has_prefix(t, "https://") do return t, false
    if net.is_file_url(t) do return net.normalize_file_url(t, context.temp_allocator), false
    if caminho_windows(t) {
        p, _ := strings.replace_all(t, "\\", "/", context.temp_allocator)
        return strings.concatenate({"file:///", p}, context.temp_allocator), false
    }
    return fmt.tprintf("https://%s", t), true
}

// `C:\...` ou `C:/...` — letra de unidade, ':' e separador.
@(private = "file")
caminho_windows :: proc(s: string) -> bool {
    if len(s) < 3 do return false
    c := s[0]
    letra := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    return letra && s[1] == ':' && (s[2] == '\\' || s[2] == '/')
}

navigate :: proc(s: ^State) {
    full_url, auto := url_from_bar(string(cstring(raw_data(s.url_buf[:]))))
    if full_url == "" do return
    start_navigation(s, full_url, auto_https = auto)
}

// Inicia uma navegação para uma URL já resolvida (usado pela barra e por links).
// record = true registra no histórico (navegação nova); false é voltar/avançar/recarregar.
// tab_idx < 0 = aba ativa; outro índice navega aquela aba EM SEGUNDO PLANO (a
// barra de URL e o status continuam sendo os da aba ativa).
start_navigation :: proc(s: ^State, url: string, record := true, auto_https := false, tab_idx := -1) {
    if len(s.tabs) == 0 || url == "" do return
    idx := tab_idx if tab_idx >= 0 else s.active
    if idx >= len(s.tabs) do return
    background := idx != s.active
    css_unknown_report()

    tab := &s.tabs[idx]

    if record {
        // descarta o "avançar" pendente e empilha a nova URL
        for i := len(tab.history) - 1; i > tab.hist_idx; i -= 1 {
            delete(tab.history[i])
            ordered_remove(&tab.history, i)
        }
        append(&tab.history, strings.clone(url))
        tab.hist_idx = len(tab.history) - 1
    }

    tab.url     = strings.clone(url) // posse própria (estável)
    tab.title   = strings.clone(url)
    tab.loading = true
    if !background {
        s.status = fmt.aprintf("Conectando a %s ...", url)
        sync_url_buf(s) // reflete a nova URL na barra
    }

    // dispara a busca numa thread separada (não trava a UI)
    job := new(Fetch_Job)
    job.url        = strings.clone(url)
    job.auto_https = auto_https
    job.tab_id     = tab.id
    job.viewport_w = im.GetIO().DisplaySize.x // p/ @media e vw (largura no momento da carga)
    if job.viewport_w < 1 do job.viewport_w = 1280
    job.viewport_h = im.GetIO().DisplaySize.y
    if job.viewport_h < 1 do job.viewport_h = 720
    append(&g_jobs, job)
    thread.create_and_start_with_poly_data(job, fetch_worker, self_cleanup = true)
}

// ── Botões de navegação ─────────────────────────────────────────────────────

go_back :: proc(s: ^State) {
    if len(s.tabs) == 0 do return
    tab := &s.tabs[s.active]
    if tab.hist_idx <= 0 do return
    tab.hist_idx -= 1
    start_navigation(s, tab.history[tab.hist_idx], record = false)
}

go_forward :: proc(s: ^State) {
    if len(s.tabs) == 0 do return
    tab := &s.tabs[s.active]
    if tab.hist_idx >= len(tab.history) - 1 do return
    tab.hist_idx += 1
    start_navigation(s, tab.history[tab.hist_idx], record = false)
}

reload_page :: proc(s: ^State) {
    if len(s.tabs) == 0 do return
    tab := &s.tabs[s.active]
    if tab.url == "" do return
    start_navigation(s, tab.url, record = false)
}

// Roda na thread de trabalho: baixa o HTML, parseia, baixa o CSS (inline +
// externo), computa os estilos e entrega tudo pronto. Não toca na UI.
fetch_worker :: proc(job: ^Fetch_Job) {
    dbg_adopt_allocator() // usa o alocador tracked global em debug (evita falso bad-free)
    job.resp = net.fetch(job.url)

    // HTTPS-first: se o esquema foi auto-adicionado e a conexão https falhou
    // (timeout/recusada — site só-HTTP), tenta novamente via http://.
    if !job.resp.ok && job.auto_https && strings.has_prefix(job.url, "https://") {
        http_url := strings.concatenate({"http://", job.url[8:]}) // 8 = len("https://")
        if job.resp.err != "" do delete(job.resp.err)
        delete(job.url)
        job.url = http_url
        job.resp = net.fetch(job.url)
    }
    job.final_url = strings.clone(job.url) // URL de fato buscada (p/ a aba refletir)

    if job.resp.ok {
        // parse_document = o parser de tree-construction de spec (foster, adoption,
        // tbody implícito, conteúdo estrangeiro). Substituiu o par legado
        // parse+normalize_document: o scaffold html/head/body agora sai do próprio
        // algoritmo. Fecha o buraco medido no M141 (legado 429/1509 vs 1680).
        job.dom = htmlp.parse_render(job.resp.body)
        // O tamanho do viewport ANTES de rodar script alheio: `window.innerWidth`
        // é lido no carregamento (mobile×desktop) e este worker é OUTRA thread, com
        // os thread_local do computed_om zerados. Só as DIMENSÕES — o mapa de
        // estilos deste job ainda não pertence a nenhuma aba, e publicá-lo daqui
        // seria corrida com a main (ver o aviso em computed_om.odin).
        js_viewport_set(job.viewport_w, job.viewport_h)
        job.vm = load_page_scripts(job.dom, job.url) // roda <script> inline E externos (src=)
        css_text := collect_page_css(job.dom, job.url) // inclui <link> externos (temp)
        job.css_text = strings.clone(css_text)         // DONO: sobrevive ao free_all(temp) abaixo
        // As rules ficam NO JOB e são transferidas à aba (poll_jobs) em vez de
        // liberadas aqui: sobrevivem ao free_all(temp) abaixo porque suas strings
        // são owned, poupam o parse do 1º restyle e mantêm válidas as fatias `_raw`
        // que o Computed guarda p/ dentro de rule.decls.
        job.rules, job.kf = csspkg.parse(job.css_text)
        job.styles, job.page_bg = compute_styles(job.dom, &job.rules, job.viewport_w, job.viewport_h, job.kf[:])
        job.layout = build_layout(job.dom, job.styles, job.url)
    }
    free_all(context.temp_allocator)
    intrinsics.atomic_store(&job.done, true)
}

// A resposta de um <script src> é HTML em vez de JavaScript? Acontece quando o
// asset não existe e o servidor devolve o index.html com 200 (fallback de SPA) ou
// uma página de erro. Checa o Content-Type E faz sniff do corpo, porque muitos
// servidores mandam MIME errado (ou nenhum) nesse caminho de fallback.
// CUIDADO: NÃO basta olhar o primeiro '<' — script legado às vezes começa com o
// hack `<!--`, que é JS válido p/ nós. Só `<!doctype` e `<html` são conclusivos.
@(private="file")
response_is_not_js :: proc(status: int, content_type: string, body: string) -> bool {
    // 1) status fora de 2xx: o navegador dispara `error` no <script> e NÃO executa
    //    o corpo — que num 402/404/500 é página de erro ou JSON de API. O slack.com
    //    tem um `<script src>` do clearbit que responde **402 + application/json**
    //    ("over_quota") e nós parseávamos aquilo como JS. (status 0 = sintético.)
    if status != 0 && (status < 200 || status > 299) do return true
    // 2) Content-Type JSON: resposta de API no lugar do script — conclusivo mesmo
    //    em 200, porque corpo JSON nunca é JS executável.
    lo_ct := strings.to_lower(content_type, context.temp_allocator)
    if strings.contains(lo_ct, "application/json") || strings.contains(lo_ct, "+json") do return true
    // 3) corpo HTML. Script CLÁSSICO NÃO é rejeitado por Content-Type text/html:
    //    a spec é tolerante e servidores servem .js com MIME errado; aqui só o
    //    corpo é conclusivo.
    head := strings.trim_left_space(body)
    if len(head) > 64 do head = head[:64]
    lo := strings.to_lower(head, context.temp_allocator)
    return strings.has_prefix(lo, "<!doctype") || strings.has_prefix(lo, "<html")
}

MAX_SCRIPTS :: 48 // teto de <script src> baixados por página (apps webpack/Next
// quebram o bundle em muitos chunks; capar baixo faz `modules[id]` faltar e o
// runtime do webpack lança "reading 'call'" → bundle morre → página em branco)

// Cria o vm da página e executa os <script> em ORDEM DE DOCUMENTO, baixando os
// externos (src=) pela rede — espelho do collect_page_css. Cada script roda
// SEPARADO no mesmo vm (globais compartilhadas): um script quebrado ou uma
// exceção não impede os seguintes. Roda na thread de trabalho.
load_page_scripts :: proc(dom: ^dompkg.Node, base_url: string) -> ^jspkg.Interp {
    vm := jspkg.vm_create_with_dom(dom)
    vm.base_url = strings.clone(base_url) // p/ fetch() com URL relativa

    // DUAS FASES: primeiro COLETAMOS todos os <script> numa lista (em ordem de
    // documento), depois EXECUTAMOS. É essencial: rodar um script pode mutar o
    // DOM (ex.: o snippet do GTM faz `parentNode.insertBefore(novoScript, f)`
    // no mesmo pai). Se caminhássemos a árvore VIVA rodando scripts no caminho,
    // essa inserção mudaria a lista de filhos sendo iterada e o mesmo <script>
    // seria revisitado infinitamente (a Cloudflare travava reexecutando o mesmo
    // script >25 mil vezes). Coletando antes, a execução é imune a mutações.
    scripts: [dynamic]^dompkg.Node
    defer delete(scripts)
    collect_scripts_rec(dom, &scripts)

    ordenados := script_exec_order(scripts[:], context.temp_allocator)

    ext_count := 0 // só <script src> conta p/ o teto de downloads
    for s in ordenados {
        // document.currentScript = este <script> durante sua execução. Turbopack/webpack
        // leem `currentScript.getAttribute('src')` p/ derivar o caminho-base dos chunks;
        // sem isto o runtime do Turbopack estourava "chunk path empty but not in a worker"
        // em cada chunk (nextjs.org e cia.). Fica setado durante o fetch+run; limpo no fim.
        vm.current_script = rawptr(s)
        // <script type="module"> tem escopo de topo PRÓPRIO (spec ES) — rodar no
        // escopo global fazia declarações de módulos diferentes colidirem (ex.: um
        // `let r` sobrescrevia o `function r` de outro → "r is not a function").
        is_module := strings.equal_fold(s.attrs["type"], "module")
        if src, has := s.attrs["src"]; has && src != "" {
            if is_blocked_script_host(src) {
                fmt.eprintfln("[js] script de analytics/ads ignorado: %s", src)
                continue
            }
            if ext_count >= MAX_SCRIPTS do continue // teto de rede; inline não conta
            ext_count += 1
            abs := net.resolve_url(base_url, src, context.temp_allocator)
            resp := net.fetch(abs)
            if resp.ok && response_is_not_js(resp.status, resp.content_type, resp.body) {
                // A resposta não é JavaScript — erro HTTP, JSON de API, ou o
                // index.html do fallback de SPA/404 (200) p/ um asset que não
                // existe. Parsear isso como JS produzia MILHARES de recuperações
                // ("<!DOCTYPE html" em posição de expressão): techcrunch 9129,
                // wordpress 2124, speedtest 247… e ainda sujava o vm. Um navegador
                // real recusa por status/MIME; aqui recusamos igual.
                fmt.eprintfln("[js] resposta não-JS ignorada (HTTP %d, %s): %s", resp.status, resp.content_type, abs)
            } else if resp.ok {
                when #config(MEMBERPROBE, false) {
                    fmt.eprintfln("[script] %d bytes  %s", len(resp.body), abs)
                }
                // módulo externo: a URL do próprio script é o referrer dos imports dele
                if is_module { jspkg.vm_run_module(vm, resp.body, abs) } else { jspkg.vm_run(vm, resp.body) }
            } else {
                fmt.eprintfln("[js] script externo falhou: %s (%s)", abs, resp.err)
            }
            if len(resp.body) > 0 do delete(resp.body)
            if !resp.ok && resp.err != "" do delete(resp.err)
        } else {
            sb := strings.builder_make(context.temp_allocator)
            for c in s.children do if c.kind == .Text do strings.write_string(&sb, c.text)
            code := strings.to_string(sb)
            if len(strings.trim_space(code)) > 0 {
                if is_module { jspkg.vm_run_module(vm, code) } else { jspkg.vm_run(vm, code) }
            }
        }
    }
    vm.current_script = nil // fora de qualquer <script>: document.currentScript === null (spec)
    // Todos os <script> já rodaram e registraram seus listeners. Dispara
    // DOMContentLoaded no document: muitos sites adiam a inicialização com
    // `document.addEventListener("DOMContentLoaded", init)` (scripts de módulo são
    // deferidos e rodam ANTES do DOMContentLoaded no navegador real, então o
    // listener pega o evento). Sem disparar, esses inits nunca rodam — ex.: a
    // galeria "Fotos" do famososbr é montada de um JSON em data-photos via
    // innerHTML dentro de um handler de DOMContentLoaded, e ficava vazia.
    jspkg.dispatch_event(vm, dom, "DOMContentLoaded")
    return vm
}

// Hosts de analytics/publicidade cujos scripts são ignorados: não afetam a
// renderização, são enormes, e alguns entram em laço no motor JS (ex.: gtag.js
// travava a página ~40s até o watchdog). `src` pode ser relativo ou absoluto —
// casamos por substring do host.
@(private)
is_blocked_script_host :: proc(src: string) -> bool {
    hosts := [?]string{
        "googletagmanager.com",
        "google-analytics.com",
        "googlesyndication.com",
        "googleadservices.com",
        "doubleclick.net",
        "connect.facebook.net",
        "static.hotjar.com",
        "cdn.segment.com",
        "js.intercomcdn.com",
    }
    for h in hosts do if strings.contains(src, h) do return true
    return false
}

// Coleta os <script> em ordem de documento (pré-ordem), SEM executá-los. Roda
// sobre a árvore recém-parseada (ainda intocada pelo JS), então é seguro: o
// parser só anexa nós novos, nunca cria ciclos. A execução acontece depois, em
// load_page_scripts, imune a mutações que os scripts façam no DOM.
// Um <script> só é EXECUTÁVEL se o `type` está ausente/vazio ou é um MIME de
// JavaScript. Tipos como application/json (ex.: __NEXT_DATA__ do Next.js),
// application/ld+json (SEO), text/template, text/x-template (Vue/handlebars),
// speculationrules etc. são "blocos de dados" — NÃO são código. Executá-los como
// JS jogava a prosa/JSON no lexer e lançava erros bizarros (ex.: `rate. The` da
// descrição do contador de GDP do stripe virava acesso a membro `rate.The`),
// abortando o bundle e deixando a página EM BRANCO.
@(private)
is_executable_script :: proc(n: ^dompkg.Node) -> bool {
    t, has := n.attrs["type"]
    if !has do return true // sem type = JS clássico
    tl := strings.to_lower(strings.trim_space(t), context.temp_allocator)
    switch tl {
    case "", "module",
         "text/javascript", "application/javascript",
         "text/ecmascript", "application/ecmascript",
         "text/jscript", "text/x-javascript", "application/x-javascript":
        return true
    }
    return false // application/json, ld+json, text/template, ... = dados, não código
}

// Este <script> é DEFERIDO? (`type="module"` ou `defer`, e sem `async` — que
// para ambos volta a ser "assim que der".)
@(private = "file")
script_is_deferred :: proc(s: ^dompkg.Node) -> bool {
    if s == nil || s.attrs == nil do return false
    if _, tem_async := s.attrs["async"]; tem_async do return false
    if _, tem_defer := s.attrs["defer"]; tem_defer do return true
    return strings.equal_fold(s.attrs["type"], "module")
}

// Ordem de EXECUÇÃO dos <script>, que NÃO é a ordem de documento.
//
// ⚠️ `type="module"` e `defer` rodam depois do parse E depois de todos os
// clássicos, mesmo aparecendo ANTES deles no HTML. Sem isto, o caso mais comum
// de site real quebra: no getbootstrap.com um MÓDULO na 3ª tag faz
// `new bootstrap.Tooltip(...)` enquanto o `bootstrap.bundle.min.js` clássico é
// a 5ª — dava `ReferenceError: bootstrap is not defined`. O diagnóstico veio da
// ORDEM no log (`[unresolved] bootstrap` ANTES do `[script] …bundle.min.js`),
// depois de três hipóteses minhas morrerem contra fixtures que passavam.
//
// `async` fica na 1ª fase de propósito: a spec não ordena scripts async, e
// adiá-los só atrasaria analytics sem ganho nenhum.
// Dentro de cada fase a ordem de documento é preservada (a spec exige para
// defer e para módulos).
script_exec_order :: proc(scripts: []^dompkg.Node, allocator := context.allocator) -> []^dompkg.Node {
    out := make([dynamic]^dompkg.Node, 0, len(scripts), allocator)
    for s in scripts do if !script_is_deferred(s) do append(&out, s)
    for s in scripts do if  script_is_deferred(s) do append(&out, s)
    return out[:]
}

@(private)
collect_scripts_rec :: proc(n: ^dompkg.Node, out: ^[dynamic]^dompkg.Node) {
    if n.kind == .Element && n.tag == "script" {
        if is_executable_script(n) do append(out, n)
        return // <script> não tem sub-scripts
    }
    for c in n.children do collect_scripts_rec(c, out)
}

// Junta o CSS da página: conteúdo dos <style> + folhas externas (<link>).
// Roda na thread de trabalho (pode baixar várias folhas em sequência).
collect_page_css :: proc(dom: ^dompkg.Node, base_url: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    count := 0
    imports := css_import_state(&count)
    collect_css_rec(dom, base_url, &sb, &imports)
    return strings.to_string(sb)
}

MAX_SHEETS :: 32 // teto global de folhas ÚNICAS baixadas (<link> + @import, recursivo).
// Era 12, e o teto contava ELEMENTO em vez de URL: a home do GitHub tem 28 <link>
// para 21 URLs distintas (primer-react-css religada 5×, primer-react-brand 4× —
// app que quebra o CSS em módulos religa a mesma folha uma vez por partial React),
// então parávamos na 12ª e as 9 folhas ÚNICAS restantes (~1,1 MB) nunca baixavam.
// Entre elas a marketing-navigation.module.css, que é quem tem
// `.NavDropdown-module__dropdown{visibility:hidden;position:fixed}` — sem ela o
// mega-menu inteiro caía EM FLUXO e era despejado no meio da página.

// Esquemas que o `net.fetch` sabe buscar (o curl resolve os três).
// Existe porque a guarda era `has_prefix(url, "http")` repetida em dois lugares
// — e, com a barra aceitando `file://`, isso PULAVA em silêncio toda folha de
// estilo de página local: a página abria sem CSS e sem nenhum erro.
// ⚠️ `data:` fica de fora de propósito: nunca foi aceito aqui, e incluí-lo
// mudaria comportamento além do pedido.
@(private)
url_buscavel :: proc(url: string) -> bool {
    return strings.has_prefix(url, "http://")  ||
           strings.has_prefix(url, "https://") ||
           net.is_file_url(url)
}

// Chave de dedup de folha. A MESMA URL sob `media` diferente é outra folha de
// verdade (print vs screen escondem coisas opostas), então não pode colapsar;
// `media` vazio ou "all" é o caso irrestrito e colapsa com ele mesmo.
sheet_dedup_key :: proc(url, media: string, alloc := context.temp_allocator) -> string {
    m := strings.trim_space(media)
    if m == "" || strings.equal_fold(m, "all") do return url
    return strings.concatenate({url, "|", m}, alloc)
}

@(private)
collect_css_rec :: proc(n: ^dompkg.Node, base: string, sb: ^strings.Builder, imports: ^CSS_Import_State) {
    if n.kind == .Element {
        if n.tag == "style" {
            text := strings.builder_make(context.temp_allocator)
            for c in n.children do if c.kind == .Text do strings.write_string(&text, c.text)
            css_expand_imports(strings.to_string(text), base, sb, imports)
        } else if n.tag == "link" {
            rel := n.attrs["rel"] if "rel" in n.attrs else ""
            href, has_href := n.attrs["href"]
            if has_href && strings.contains(strings.to_lower(rel, context.temp_allocator), "stylesheet") {
                url := net.resolve_url(base, href, context.temp_allocator)
                body, ok := css_import_body(imports, url)
                if ok {
                    media := strings.trim_space(n.attrs["media"])
                    wrap := media != "" && !strings.equal_fold(media, "all")
                    if wrap {
                        strings.write_string(sb, "\n@media ")
                        strings.write_string(sb, media)
                        strings.write_string(sb, " {\n")
                    }
                    // Repetições mantêm sua posição na cascata; só o download é cacheado.
                    css_expand_imports(body, url, sb, imports)
                    if wrap do strings.write_string(sb, "\n}\n")
                    strings.write_byte(sb, '\n')
                }
            }
        }
    }
    for c in n.children do collect_css_rec(c, base, sb, imports)
}

@(private)
// Marca, DENTRO do css concatenado, de que folha vem o trecho seguinte. Existe
// porque `url(...)` relativa numa folha resolve contra a URL DA FOLHA, não da
// página (CSS Syntax §3.3) — e o `css_text` de uma aba é a concatenação de N
// folhas de diretórios diferentes. Sem isto, o `src` de `@font-face` de qualquer
// site que sirva o CSS de uma subpasta (a maioria: `/_app/…`, `/assets/…`) vira
// 404 e a webfont some em silêncio.
// Vai como COMENTÁRIO CSS: o parser de regras já os descarta, então só o
// `fontface_scan` (que varre o texto cru) enxerga.
// ⚠️ é sinalização IN-BAND: se um site tivesse esta sequência literal no CSS, o
// pior caso é uma URL de fonte resolvida contra a base errada → 404 → família
// genérica, que é exatamente a degradação que já existia.
CSS_SHEET_MARK :: "/*<<@sheet "

@(private)
write_sheet_mark :: proc(sb: ^strings.Builder, sheet_url: string) {
    strings.write_string(sb, "\n")
    strings.write_string(sb, CSS_SHEET_MARK)
    strings.write_string(sb, sheet_url)
    strings.write_string(sb, ">>*/\n")
}

// Processa um clique registrado durante o paint: dispara os handlers "click" do
// nó alvo, subindo pelos ancestrais (event bubbling). Se algum handler rodou, o
// JS pode ter mutado o DOM — reconstrói o layout com os MESMOS estilos (os nós
// existentes não mudaram; ainda não há createElement, então o mapa styles vale).
dispatch_page_click :: proc(s: ^State, vw, vh: f32) {
    if s.click_target == nil || len(s.tabs) == 0 do return
    node := s.click_target
    s.click_target = nil

    tab := &s.tabs[s.active]
    if tab.vm == nil do return

    // bubbling acontece dentro de dispatch_event (alvo -> raiz)
    fired, _ := jspkg.dispatch_mouse_event(tab.vm, node, "click", 0, 0)
    if fired && tab.dom != nil {
        // o JS pode ter criado/removido nós ou mudado classes: re-estiliza a
        // página inteira (o mapa styles antigo não cobre os nós novos) e
        // reconstrói o layout — re-parseando o css_text retido.
        restyle_tab(tab, vw, vh)
    }
}

// Botão do MEIO na página. O paint gravou, nos frames de aperto/soltura, o nó
// mais acima sob o cursor (aux_node) e o link sob ele (aux_href). Sequência da
// UI Events / navegadores:
//   aperto  → `mousedown` {button:1, buttons:4}
//   soltura → `mouseup`   {button:1, buttons:0} + `auxclick` {button:1}
//             e, se o aperto e a soltura caíram no MESMO link e o `auxclick` não
//             foi cancelado, abre o link numa aba nova EM SEGUNDO PLANO.
// O meio NÃO dispara `click` (é o que distingue `auxclick`).
// Degradação: o `auxclick` vai ao alvo da SOLTURA, não ao ancestral comum do
// aperto e da soltura (guardar o nó entre frames arriscaria um nó já liberado);
// a condição é "apertou nesta mesma aba". Link `#âncora`/`javascript:` não abre
// aba (resolve_url devolve "").
dispatch_page_aux :: proc(s: ^State, vw, vh: f32) {
    node := s.aux_node
    href := strings.clone(s.aux_href, context.temp_allocator) // o layout pode ser refeito no dispatch
    s.aux_node = nil
    s.aux_href = ""
    if len(s.tabs) == 0 do return
    pressed  := im.IsMouseClicked(.Middle)
    released := im.IsMouseReleased(.Middle)
    if !pressed && !released do return

    tab_id := s.tabs[s.active].id
    vm     := s.tabs[s.active].vm
    base   := strings.clone(s.tabs[s.active].url, context.temp_allocator)
    fired  := false

    if pressed {
        aux_press_clear(s)
        s.aux_press_tab  = tab_id
        s.aux_press_href = strings.clone(href)
        if node != nil && vm != nil {
            f, _ := jspkg.dispatch_mouse_event(vm, node, "mousedown", 1, 4)
            fired |= f
        }
    }
    if released {
        same_tab := s.aux_press_tab != 0 && s.aux_press_tab == tab_id
        prevented := false
        if node != nil && vm != nil {
            f, _ := jspkg.dispatch_mouse_event(vm, node, "mouseup", 1, 0)
            fired |= f
            if same_tab {
                f2, p := jspkg.dispatch_mouse_event(vm, node, "auxclick", 1, 0)
                fired |= f2
                prevented = p
            }
        }
        if same_tab && !prevented && href != "" && href == s.aux_press_href {
            if url := net.resolve_url(base, href, context.temp_allocator); url != "" {
                open_background_tab(s, url)
            }
        }
        aux_press_clear(s)
    }

    // mesmo contrato do dispatch_page_click: o JS pode ter mexido no DOM
    if fired {
        tab := &s.tabs[s.active] // re-tomado: open_background_tab pode ter realocado s.tabs
        if tab.dom != nil do restyle_tab(tab, vw, vh)
    }
}

aux_press_clear :: proc(s: ^State) {
    if s.aux_press_href != "" do delete(s.aux_press_href)
    s.aux_press_href = ""
    s.aux_press_tab  = 0
}

// Abre `url` numa aba nova SEM ativá-la (clique do meio num link). A aba entra à
// direita da ativa, DEPOIS das que ela já abriu assim — vários cliques do meio
// seguidos ficam na ordem em que foram dados, como no Chrome/Firefox.
// Devolve o índice da aba nova.
open_background_tab :: proc(s: ^State, url: string) -> int {
    if len(s.tabs) == 0 do return -1
    opener := s.tabs[s.active].id
    idx := s.active + 1
    for idx < len(s.tabs) && s.tabs[idx].opener == opener do idx += 1
    t := make_tab("Nova aba") // o start_navigation troca pelo título (clonado) da URL
    t.opener = opener
    inject_at(&s.tabs, idx, t)
    start_navigation(s, url, tab_idx = idx)
    return idx
}

// Aplica a escolha feita num <select> neste frame: reflete no DOM, dispara
// `input` + `change` (é o `change` que o React escuta) e re-estiliza.
//
// A ordem importa: o valor NOVO tem de estar no DOM ANTES do dispatch, senão o
// handler lê `e.target.value` velho — que é justo o que um select controlado usa
// p/ decidir o próximo estado.
dispatch_select_change :: proc(s: ^State, vw, vh: f32) {
    sel, opt := take_select_change()
    if sel == nil || opt == nil || len(s.tabs) == 0 do return
    tab := &s.tabs[s.active]

    apply_select_choice(sel, opt) // DOM primeiro — o handler tem de ler o valor NOVO

    if tab.vm != nil {
        jspkg.dispatch_event(tab.vm, sel, "input")
        jspkg.dispatch_event(tab.vm, sel, "change")
    }
    // re-estiliza SEMPRE (não só quando um handler disparou): a mudança de
    // atributo por si já pode casar seletores (:checked, [value=…]) e o rótulo
    // mostrado vem do DOM.
    if tab.dom != nil do restyle_tab(tab, vw, vh)
}

// Chamado a cada frame na thread da UI: entrega os resultados prontos.
poll_jobs :: proc(s: ^State) {
    for i := len(g_jobs) - 1; i >= 0; i -= 1 {
        job := g_jobs[i]
        if !bool(intrinsics.atomic_load(&job.done)) do continue

        consumed := false
        for &tab in s.tabs {
            if tab.id != job.tab_id do continue
            tab.loading = false
            if job.resp.ok {
                // libera o conteúdo/DOM/estilos/layout anteriores
                if tab.content != "" do delete(tab.content)
                if tab.layout != nil do free_layout(tab.layout)
                if tab.vm != nil     do jspkg.vm_free(tab.vm) // vm antes do DOM (referencia nós)
                if tab.dom != nil    { transitions_clear(); dompkg.free_tree(tab.dom) }
                if tab.tree != ""    do delete(tab.tree)
                if tab.styles != nil do free_styles(tab.styles)
                if tab.css_text != "" do delete(tab.css_text)
                tab_drop_rules(&tab) // o css_text vai mudar: as regras antigas não valem mais

                // transfere o que a thread já preparou
                tab.content = job.resp.body
                tab.status  = job.resp.status
                tab.dom     = job.dom
                tab.styles  = job.styles
                tab.page_bg = job.page_bg
                tab.layout  = job.layout
                tab.vm      = job.vm
                tab.css_text = job.css_text
                tab.rules = job.rules
                tab.kf = job.kf
                tab.rules_ready = true // já parseadas pela thread: o 1º restyle reusa
                tab.zoom_applied = g_zoom // computado pela thread com o zoom atual
                job.dom = nil
                job.layout = nil
                job.vm = nil
                job.css_text = ""     // transferido p/ a aba (evita free duplo)
                job.rules = nil; job.kf = nil // idem

                // fallback https→http: reflete a URL real na aba, histórico e barra
                if job.final_url != "" && job.final_url != tab.url {
                    delete(tab.url)
                    tab.url = strings.clone(job.final_url)
                    if tab.hist_idx >= 0 && tab.hist_idx < len(tab.history) {
                        delete(tab.history[tab.hist_idx])
                        tab.history[tab.hist_idx] = strings.clone(job.final_url)
                    }
                    if tab.id == s.tabs[s.active].id do sync_url_buf(s)
                }

                s.status = fmt.aprintf("%s - %d - %d bytes - %d elementos",
                    tab.url, job.resp.status, len(job.resp.body), dompkg.count_elements(tab.dom))
                consumed = true
            } else {
                tab.status = 0
                s.status = fmt.aprintf("Falha: %s", job.resp.err)
            }
            break
        }
        // aba foi fechada antes de terminar: descarta o que foi baixado
        if !consumed {
            if job.resp.ok && len(job.resp.body) > 0 do delete(job.resp.body)
            if job.vm != nil do jspkg.vm_free(job.vm) // vm antes do DOM (referencia nós)
            if job.layout != nil do free_layout(job.layout)
            if job.dom != nil do dompkg.free_tree(job.dom)
            if job.styles != nil do free_styles(job.styles)
            if job.css_text != "" do delete(job.css_text)
            csspkg.free_rules(&job.rules)     // não foram transferidas
            csspkg.free_keyframes(&job.kf)
        }

        delete(job.url)
        if job.final_url != "" do delete(job.final_url)
        ordered_remove(&g_jobs, i)
        free(job)
    }
}

// ── Estilo global ───────────────────────────────────────────────────────────

apply_style :: proc() {
    style := im.GetStyle()
    style.WindowRounding    = 0
    style.ChildRounding     = 0
    style.FrameRounding     = 8
    style.FrameBorderSize   = 0
    style.WindowBorderSize  = 0
    style.ChildBorderSize   = 0
    style.FramePadding      = {6, 6}
    style.ItemSpacing       = {8, 6}
    style.ScrollbarSize     = 12

    c := &style.Colors
    c[im.Col.Text]           = vec(TEXT_C)
    c[im.Col.WindowBg]       = vec(WIN_BG)
    c[im.Col.ChildBg]        = vec(WIN_BG)
    c[im.Col.PopupBg]        = vec(TOOLBAR)
    c[im.Col.FrameBg]        = vec(OMNIBOX)
    c[im.Col.FrameBgHovered] = vec(OMNIBOX_H)
    c[im.Col.FrameBgActive]  = vec(OMNIBOX_H)
    c[im.Col.TextSelectedBg] = {0.3, 0.62, 1.0, 0.35}
}
