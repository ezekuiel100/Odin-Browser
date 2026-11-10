package ui

// Modo headless: renderiza um arquivo HTML local para um PNG, sem mostrar
// janela. Reusa todo o pipeline (parse → CSS → layout → paint), só troca a
// origem (arquivo em vez de rede) e o destino (textura offscreen → PNG).
//
// Usado por reftests e screenshot-diff. CLI:
//   browser.exe --render entrada.html saida.png [largura altura]

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:c"
import sdl2       "vendor:sdl2"
import stbi       "vendor:stb/image"
import im         "../../vendor/imgui"
import imgui_sdl2 "../../vendor/imgui/imgui_impl_sdl2"
import imgui_sdlr "../../vendor/imgui/imgui_impl_sdlrenderer2"
import htmlp      "../html"
import csspkg     "../css"
import dompkg     "../dom"
import jspkg      "../js"
import net        "../net"
import woff2pkg   "../woff2"
import brotlipkg  "../brotli"

// Modo debug: roda o pipeline do fetch_worker de forma SÍNCRONA sobre uma URL
// real (fetch de rede + CSS externo + compute + build_layout com a base real),
// sem thread e sem paint. Serve p/ localizar crashes de navegação.
//   browser.exe --fetch https://exemplo.com/pagina
// Modo html5lib: browser.exe --parsetree <arquivo.html>
// Lê o HTML de um arquivo, roda o parser e imprime a árvore no formato do
// html5lib-tests (tree-construction #document). O html5lib-test.ps1 compara a
// saída com o #document esperado. Se o parser crashar/travar num input
// adversarial, o processo morre e o .ps1 marca CRASH — o ganho principal aqui.
headless_parsetree :: proc(path: string) -> bool {
    data, rerr := os.read_entire_file_from_path(path, context.allocator)
    if rerr != nil { fmt.eprintfln("parsetree: nao consegui ler %s", path); return false }
    dom := htmlp.parse_document(string(data)) // CRU: conformidade html5lib, sem strip de CDATA
    out := htmlp.html5lib_serialize(dom)
    fmt.print(out) // já termina em \n por nó; sem nós, imprime vazio
    return true
}

// Modo html5lib FRAGMENTO: browser.exe --parsefragment <arquivo.html> <contexto>
// `contexto` = o elemento de contexto do #document-fragment do html5lib: "td",
// "svg path", "math ms". Serializa os nós do fragmento (sem raiz).
headless_parsefragment :: proc(path: string, ctx: string) -> bool {
    data, rerr := os.read_entire_file_from_path(path, context.allocator)
    if rerr != nil { fmt.eprintfln("parsefragment: nao consegui ler %s", path); return false }
    tag, ns := ctx, ""
    if sp := strings.index_byte(ctx, ' '); sp >= 0 {
        ns, tag = ctx[:sp], ctx[sp + 1:]
    }
    dom := htmlp.parse_fragment(string(data), tag, ns)
    out := htmlp.html5lib_serialize(dom)
    fmt.print(out)
    return true
}

// Modo html5lib LEGADO: browser.exe --parsetree-legacy <arquivo.html>
// Igual ao --parsetree, mas roda o parser que a RENDERIZAÇÃO usa de fato
// (htmlp.parse + normalize_document, o mesmo par de browser_ui.odin), não o
// parser de spec. Serve p/ MEDIR a distância entre o placar html5lib e o que a
// página realmente vê — os dois parsers convivem desde o M111.
headless_parsetree_legacy :: proc(path: string) -> bool {
    data, rerr := os.read_entire_file_from_path(path, context.allocator)
    if rerr != nil { fmt.eprintfln("parsetree-legacy: nao consegui ler %s", path); return false }
    dom := htmlp.parse(string(data))
    htmlp.normalize_document(dom) // <html>/<head>/<body> implícitos, como na navegação
    out := htmlp.html5lib_serialize(dom)
    fmt.print(out)
    return true
}

// Modo html5lib tokenizer: browser.exe --tokenize <arquivo.html> [estado] [last]
// Emite os tokens no formato JSON do html5lib-tests, uma linha por token.
// `estado` = data (default)/plaintext/rcdata/rawtext/script/cdata; `last` = a
// appropriate end tag (lastStartTag). O html5lib-tokenizer.ps1 compara.
headless_tokenize :: proc(path: string, state := "data", last := "") -> bool {
    data, rerr := os.read_entire_file_from_path(path, context.allocator)
    if rerr != nil { fmt.eprintfln("tokenize: nao consegui ler %s", path); return false }
    out := htmlp.html5lib_tokenize(string(data), state, last)
    fmt.print(out)
    return true
}

headless_fetch :: proc(url: string) -> bool {
    ms :: proc(t0: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_since(t0)) }
    t := time.tick_now()
    fmt.eprintfln("[fetch] url=%s", url)
    resp := net.fetch(url)
    fmt.eprintfln("[fetch] ok=%v %d bytes | %.0fms", resp.ok, len(resp.body), ms(t)); t = time.tick_now()
    if !resp.ok do return false

    dom := htmlp.parse_render(resp.body) // parser de spec (ver browser_ui.odin)
    fetch_vm := load_page_scripts(dom, url) // <script> inline + externos mutam o DOM antes do style/layout
    defer jspkg.vm_free(fetch_vm)
    fmt.eprintfln("[parse html+js] %.0fms", ms(t)); t = time.tick_now()

    css_text := collect_page_css(dom, url) // inclui fetch dos <link> externos
    fmt.eprintfln("[css fetch+collect] %d bytes | %.0fms", len(css_text), ms(t)); t = time.tick_now()
    rules, kf := csspkg.parse(css_text)
    fmt.eprintfln("[css parse] %d regras | %.0fms", len(rules), ms(t)); t = time.tick_now()

    styles, page_bg := compute_styles(dom, &rules, 1280, 720, kf[:])
    fmt.eprintfln("[compute_styles] %d nós | %.0fms", len(styles), ms(t)); t = time.tick_now()
    _ = page_bg

    layout := build_layout(dom, styles, url) // ANTES de free_rules: lê slices _raw p/ dentro de rules
    csspkg.free_rules(&rules); csspkg.free_keyframes(&kf)
    fmt.eprintfln("[build_layout] %.0fms", ms(t)); t = time.tick_now()
    fmt.eprintfln("[layout] ok, root=%v", layout != nil)

    fmt.eprintln("[layout_box] rodando layout...")
    if layout != nil {
        layout_box(layout, 0, 0, 1280)
        page := Rect{0, 0, 1280, 900} // ICB = viewport (CSS 2.1 §10.1), não altura do doc
        layout_absolutes(layout, page, page)
    }
    // diagnóstico: conta itens/caixas de imagem e amostra as URLs
    nimg := 0
    count_imgs :: proc(b: ^Box, n: ^int, shown: ^int) {
        if b == nil do return
        if b.kind == .Image && b.img_url != "" { n^ += 1; if shown^ < 4 { fmt.eprintfln("  img(box): %s", b.img_url); shown^ += 1 } }
        for &it in b.inlines do if it.kind == .Image && it.img_url != "" { n^ += 1; if shown^ < 4 { fmt.eprintfln("  img(inl): %s", it.img_url); shown^ += 1 } }
        for c in b.children do count_imgs(c, n, shown)
    }
    shown := 0
    count_imgs(layout, &nimg, &shown)
    fmt.eprintfln("[img] %d imagens no layout", nimg)
    fmt.eprintln("[done] pipeline completo, SEM crash")
    return true
}

// Modo inventário: roda o pipeline (fetch + CSS + compute_styles) sobre uma
// LISTA de URLs reais, acumulando as propriedades não implementadas em
// g_css_unknown, e grava css_unknown.txt uma vez ao final.
//   browser.exe --css-inventory url1 [url2 ...]
headless_css_inventory :: proc(urls: []string) -> bool {
    any_ok := false
    for url in urls {
        resp := net.fetch(url)
        if !resp.ok {
            fmt.eprintfln("[inv] FALHOU %s (%s)", url, resp.err)
            continue
        }
        dom := htmlp.parse_render(resp.body) // parser de spec (ver browser_ui.odin)
        css_text := collect_page_css(dom, url) // inclui <link> externos + @import
        rules, kf := csspkg.parse(css_text)
        styles, _ := compute_styles(dom, &rules, 1280, 720, kf[:]) // popula g_css_unknown
        n_unknown := len(g_css_unknown)
        fmt.eprintfln("[inv] ok %s | %d regras, %d nós, %d props desconhecidas (acum.)",
            url, len(rules), len(styles), n_unknown)
        free_styles(styles)
        csspkg.free_rules(&rules)
        csspkg.free_keyframes(&kf)
        dompkg.free_tree(dom)
        delete(resp.body)
        any_ok = true
    }
    css_unknown_report()
    fmt.eprintfln("[inv] %d propriedades distintas gravadas em css_unknown.txt", len(g_css_unknown))
    return any_ok
}

// Modo debug: busca uma URL real e PINTA num loop de frames (com images_poll),
// espelhando o run() real — expõe crashes de pintura/imagens que só aparecem
// depois que as texturas carregam.
//   browser.exe --paint https://exemplo.com/pagina [frames]
headless_paint :: proc(url: string, url2: string = "", frames: int = 150) -> bool {
    when ODIN_DEBUG {
        mem_tracking_begin()
        defer mem_tracking_report()
    }
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 { fmt.eprintln("SDL_Init falhou"); return false }
    defer sdl2.Quit()
    window := sdl2.CreateWindow("paint", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 1280, 900, {.HIDDEN})
    if window == nil { fmt.eprintln("janela falhou"); return false }
    defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer // p/ o compositing de layers (group-opacity)
    if renderer == nil { fmt.eprintln("renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda

    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO(); io.DisplaySize = {1280, 900}
    setup_fonts(io); apply_style()
    imgui_sdl2.InitForSDLRenderer(window, renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()

    // Estado real: 1 aba. Carrega a 1ª URL pelo caminho REAL (start_navigation +
    // fetch_worker + poll_jobs). Depois navega p/ a 2ª (= o clique no link),
    // exercitando o free/swap da página anterior.
    s := State{}
    tab := make_tab("dbg")
    append(&s.tabs, tab)
    defer delete(s.tabs)

    fmt.eprintfln("[paint] navegando p/ %s", url)
    start_navigation(&s, url)
    navigated := url2 == ""

    for f in 0 ..< frames {
        imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
        poll_jobs(&s)          // entrega/troca páginas — caminho de free/swap
        images_poll(renderer)  // baixa/sobe texturas
        io.MousePos = {-1, -1}

        // bombeia timers e fetches do JS (como o draw_content faz no navegador
        // vivo); se algum disparou, re-estiliza a página mutada
        if len(s.tabs) > 0 && s.tabs[0].vm != nil {
            anim_fired := animation_dispatch(s.tabs[0].layout, s.tabs[0].vm)
            timer_fired := jspkg.vm_pump_timers(s.tabs[0].vm, 1000.0 / 60.0)
            if anim_fired || timer_fired {
                restyle_tab(&s.tabs[0], 1280, 900)
            }
        }

        // dispara a "navegação por clique" p/ a 2ª URL na metade do caminho,
        // depois da 1ª página ter carregado e pintado.
        if !navigated && f == 40 {
            fmt.eprintfln("[paint] >>> CLIQUE: navegando p/ %s", url2)
            start_navigation(&s, url2)
            navigated = true
        }

        pb := len(s.tabs) > 0 ? s.tabs[0].page_bg : 0xffffff
        im.SetNextWindowPos({0, 0}); im.SetNextWindowSize({1280, 900})
        im.PushStyleColor(.WindowBg, col(pb))
        im.Begin("##dbg", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoBringToFrontOnFocus, .NoNavFocus})
        lay := len(s.tabs) > 0 ? s.tabs[0].layout : nil
        if lay != nil {
            layout_box(lay, 0, 0, 1280)
            page := Rect{0, 0, 1280, 900} // ICB = viewport (CSS 2.1 §10.1)
            layout_absolutes(lay, page, page)
            paint_layout(&s, lay)
        }
        im.End(); im.PopStyleColor(1)
        im.Render()
        sdl2.SetRenderDrawColor(renderer, 255,255,255,255); sdl2.RenderClear(renderer)
        imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)
        // captura a última frame p/ PNG (debug do render real)
        if f == frames - 1 {
            px := make([]u8, 1280 * 900 * 4, context.temp_allocator)
            rc := sdl2.Rect{0, 0, 1280, 900}
            if sdl2.RenderReadPixels(renderer, &rc, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(px), 1280 * 4) == 0 {
                out := strings.clone_to_cstring("paint_capture.png", context.temp_allocator)
                stbi.write_png(out, 1280, 900, 4, raw_data(px), 1280 * 4)
                fmt.eprintln("[paint] PNG salvo: paint_capture.png")
            }
        }
        sdl2.RenderPresent(renderer)
        if f % 20 == 0 do fmt.eprintfln("[paint] frame %d ok (img_active=%d, g_images=%d, layout=%v, url=%s)", f, g_img_active, len(g_images), lay != nil, len(s.tabs) > 0 ? s.tabs[0].url : "")
        sdl2.Delay(8)
    }
    when ODIN_DEBUG {
        nready, nfail, nload := 0, 0, 0
        for _, img in g_images {
            switch img.state {
            case .Ready:   nready += 1
            case .Failed:  nfail += 1
            case .Loading: nload += 1
            }
        }
        fmt.eprintfln("[img] FINAL: %d Ready, %d Failed, %d Loading (de %d)", nready, nfail, nload, len(g_images))
        // dimensões das caixas/itens de imagem no layout (após carregar)
        shown := 0
        dump_dims :: proc(b: ^Box, shown: ^int) {
            if b == nil do return
            if b.kind == .Image && b.img_url != "" && shown^ < 4 { fmt.eprintfln("  IMG BOX  w=%.0f h=%.0f dw=%.0f dh=%.0f fit=%v", b.w, b.h, b.img_dw, b.img_dh, b.obj_fit); shown^ += 1 }
            for &it in b.inlines do if it.kind == .Image && it.img_url != "" && shown^ < 4 { fmt.eprintfln("  IMG ITEM w=%.0f h=%.0f", it.w, it.h); shown^ += 1 }
            for c in b.children do dump_dims(c, shown)
        }
        lay := len(s.tabs) > 0 ? s.tabs[0].layout : nil
        if lay != nil { layout_box(lay, 0, 0, 1280); dump_dims(lay, &shown) }
    }
    fmt.eprintln("[paint] DONE — sem crash")
    return true
}

// ── Modo diagnóstico ──────────────────────────────────────────────────────────
// browser.exe --diagnose https://exemplo.com/pagina
//
// Busca a URL, renderiza no caminho REAL (com fontes e imagens carregadas, então
// as larguras de texto são fiéis — ao contrário do --fetch) e emite um relatório
// de "por que pode estar quebrado": CSS não suportado, imagens não rasterizadas/
// com falha, overflow horizontal, containers colapsados, e grava a árvore de
// layout completa em diagnose_layout.txt.

// Maior extensão vertical (y+h) da subárvore, incluindo caixas FORA DO FLUXO
// (absolute/fixed). É a métrica honesta de "a página tem conteúdo?": a altura do
// root sozinha dá 0 em qualquer site cujo conteúdo esteja em wrapper posicionado.
box_max_extent :: proc(b: ^Box) -> f32 {
    if b == nil do return 0
    m := b.y + b.h
    for c in b.children {
        if e := box_max_extent(c); e > m do m = e
    }
    return m
}

// Extensão vertical ROLÁVEL: como box_max_extent, mas PODA as subárvores
// position:fixed (que ficam coladas no viewport e não devem gerar scroll).
// É o que alimenta a região rolável da página em browser_ui: usar só a
// altura EM FLUXO do root (root.h) mente quando o conteúdo vive num wrapper
// posicionado (grid+sticky da skin Vector da wikipedia, `html{position:absolute}`
// do bandcamp, body travado da cnn): root.h colapsa p/ ≈ viewport, a barra de
// scroll some e todo o conteúdo abaixo da dobra fica inalcançável/sobreposto,
// embora content_h (box_max_extent) enxergue os milhares de px reais.
box_scroll_extent :: proc(b: ^Box) -> f32 {
    if b == nil do return 0
    if b.pos == .Fixed do return 0 // colado no viewport: não estende o scroll
    m := b.y + b.h
    for c in b.children {
        if e := box_scroll_extent(c); e > m do m = e
    }
    return m
}

// Descrição curta de uma caixa: <tag#id.classe> display x/w/h.
diag_desc :: proc(b: ^Box) -> string {
    tag, id, cls := "anon", "", ""
    if b.node != nil {
        tag = b.node.tag
        if v, ok := b.node.attrs["id"];    ok do id = v
        if v, ok := b.node.attrs["class"]; ok { if len(v) > 40 do v = v[:40]; cls = v }
    }
    disp := b.is_grid ? "grid" : b.is_flex ? "flex" : b.is_inline ? "inline" : b.kind == .Image ? "img" : "block"
    // `y` entrou junto com x/w/h (M211): sem ele o dump não distingue "a caixa não
    // existe" de "a caixa está fora da tela", que é exatamente a pergunta de um
    // elemento posicionado (o hero FIXED do github.com caía em y=1013 num viewport
    // de 900). Os goldens de `tests/layout` foram regravados com o campo novo — e
    // passaram a travar também regressão VERTICAL, que antes escapava inteira.
    return fmt.tprintf("<%s#%s .%s> %s x=%.0f y=%.0f w=%.0f h=%.0f", tag, id, cls, disp, b.x, b.y, b.w, b.h)
}

// Escreve a árvore de layout indentada num strings.Builder.
diag_tree :: proc(b: ^Box, depth: int, sb: ^strings.Builder) {
    if b == nil do return
    pad := "                                                                "
    ind := pad[:min(depth * 2, len(pad))]
    posn := ""
    #partial switch b.pos {
    case .Absolute: posn = " ABS"
    case .Fixed:    posn = " FIX"
    case .Sticky:   posn = " STK"
    case .Relative: posn = " REL"
    }
    extra := ""
    if b.is_grid      do extra = fmt.tprintf(" cols=%d rows=%d gap=%.0f", b.grid_track_n, b.grid_row_track_n, b.gap)
    else if b.is_flex do extra = fmt.tprintf(" dir=%v gap=%.0f", b.flex_dir, b.gap)
    fmt.sbprintf(sb, "%s%s%s%s\n", ind, diag_desc(b), posn, extra)
    for c in b.children do diag_tree(c, depth + 1, sb)
}

diag_is_table_internal :: proc(tag: string) -> bool {
    switch tag {
    case "tbody", "thead", "tfoot", "tr", "colgroup", "col": return true
    }
    return false
}

// Percorre a árvore acumulando sinais de quebra.
diag_walk :: proc(b: ^Box, page_w: f32, n_boxes, n_over, n_coll: ^int, over, coll: ^[dynamic]^Box) {
    if b == nil do return
    n_boxes^ += 1
    // overflow horizontal: borda direita ultrapassa a página, em fluxo normal
    if b.pos != .Absolute && b.pos != .Fixed && b.x + b.w > page_w + 1 {
        n_over^ += 1
        if len(over) < 8 do append(over, b)
    }
    // container colapsado: bloco com filhos-elemento mas largura ~0. Pula tags
    // internas de tabela (tbody/tr/…) — o layout de tabela dimensiona as células
    // direto e deixa essas caixas intermediárias em 0 por design (não é quebra).
    if b.node != nil && !b.is_inline && b.w < 1 && !diag_is_table_internal(b.node.tag) {
        has_el := false
        for c in b.children do if c.node != nil { has_el = true; break }
        if has_el {
            n_coll^ += 1
            if len(coll) < 8 do append(coll, b)
        }
    }
    for c in b.children do diag_walk(c, page_w, n_boxes, n_over, n_coll, over, coll)
}

diag_report :: proc(url: string, root: ^Box, page_w: f32) {
    n_boxes, n_over, n_coll := 0, 0, 0
    over: [dynamic]^Box; defer delete(over)
    coll: [dynamic]^Box; defer delete(coll)
    diag_walk(root, page_w, &n_boxes, &n_over, &n_coll, &over, &coll)

    // imagens (estado real de download)
    n_ready, n_failed, n_loading, n_svg_fail := 0, 0, 0, 0
    for _, img in g_images {
        switch img.state {
        case .Ready:   n_ready += 1
        case .Failed:  n_failed += 1; if strings.has_suffix(img.url, ".svg") do n_svg_fail += 1
        case .Loading: n_loading += 1
        }
    }

    // CSS não suportado, ordenado por frequência
    keys := make([]string, len(g_css_unknown), context.temp_allocator)
    { i := 0; for k in g_css_unknown { keys[i] = k; i += 1 } }
    for a in 0 ..< len(keys) {
        for b in a + 1 ..< len(keys) {
            if g_css_unknown[keys[b]] > g_css_unknown[keys[a]] do keys[a], keys[b] = keys[b], keys[a]
        }
    }

    fmt.eprintln()
    fmt.eprintfln("===== DIAGNÓSTICO  %s", url)
    fmt.eprintfln("  página              : %.0f x %.0f px  (%d caixas)", page_w, root.h, n_boxes)
    fmt.eprintfln("  overflow horizontal : %d caixa(s) passam de %.0fpx", n_over, page_w)
    for b in over do fmt.eprintfln("      +%-5.0f %s", (b.x + b.w) - page_w, diag_desc(b))
    fmt.eprintfln("  containers colapsados (w<1 c/ filhos): %d", n_coll)
    for b in coll do fmt.eprintfln("      %s", diag_desc(b))
    fmt.eprintfln("  imagens             : %d ok | %d falha (%d svg) | %d carregando", n_ready, n_failed, n_svg_fail, n_loading)
    { // detalhe das falhas: http=0 é fetch/rede; 200 mas falha = decode; 429/503 = rate-limit
        shown_f := 0
        for _, img in g_images {
            if img.state != .Failed do continue
            fmt.eprintfln("      FALHA http=%d retries=%d svg=%v  %s", img.http_status, img.retries, img.is_svg, img.url)
            shown_f += 1; if shown_f >= 25 do break
        }
    }
    fmt.eprintfln("  CSS não suportado   : %d props distintas", len(keys))
    shown := 0
    for k in keys { fmt.eprintfln("      %-28s x%d", k, g_css_unknown[k]); shown += 1; if shown >= 12 do break }

    sb: strings.Builder
    strings.builder_init(&sb, context.allocator)
    defer strings.builder_destroy(&sb)
    diag_tree(root, 0, &sb)
    tree_path := "diagnose_layout.txt"
    _ = os.write_entire_file(tree_path, transmute([]u8)strings.to_string(sb))
    fmt.eprintfln("  árvore de layout    → %s  (%d caixas)", tree_path, n_boxes)
    fmt.eprintln("=========================================")
}

// ── Saída JSON do diagnóstico (gap-miner.ps1) ────────────────────────────────
// O relatório humano trunca (top-12 de CSS, exceções só no stderr); o JSON leva
// TUDO estruturado p/ agregação entre sites: css_unknown completo, exceções JS
// não capturadas, recuperações de parse, imagens e sinais de layout.

diag_json_esc :: proc(sb: ^strings.Builder, s: string) {
    for r in s {
        switch r {
        case '"':  strings.write_string(sb, "\\\"")
        case '\\': strings.write_string(sb, "\\\\")
        case '\n': strings.write_string(sb, "\\n")
        case '\r': strings.write_string(sb, "\\r")
        case '\t': strings.write_string(sb, "\\t")
        case:
            if r < 0x20 do fmt.sbprintf(sb, "\\u%04x", int(r))
            else do strings.write_rune(sb, r)
        }
    }
}

// Página que nem chegou ao layout (fetch falhou / timeout): registra o motivo
// p/ o minerador distinguir "não abre" de "abre quebrado".
diag_write_json_fail :: proc(path, url, reason: string, http_status := 0, body_bytes := 0) {
    // Um "fail" (sem layout) pode ser bloqueio: challenge cujo corpo minúsculo não
    // gerou layout, ou 4xx/5xx. Emite a mesma classificação anti-bot do caminho ok.
    blocked := http_status == 202 || http_status == 401 || http_status == 403 ||
        http_status == 429 || http_status == 451 || http_status >= 500
    block_reason := ""
    switch {
    case http_status == 202:                       block_reason = "aws-waf-challenge"
    case http_status == 403 || http_status == 401: block_reason = "forbidden"
    case http_status == 429:                       block_reason = "rate-limited"
    case http_status == 451:                       block_reason = "legal-block"
    case http_status >= 500:                       block_reason = "server-error"
    }
    sb: strings.Builder
    strings.builder_init(&sb, context.allocator)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "{\"url\":\"");  diag_json_esc(&sb, url)
    strings.write_string(&sb, "\",\"ok\":false,\"error\":\""); diag_json_esc(&sb, reason)
    fmt.sbprintf(&sb, "\",\"http_status\":%d,\"body_bytes\":%d,\"blocked\":%s", http_status, body_bytes, blocked ? "true" : "false")
    if block_reason != "" { strings.write_string(&sb, ",\"block_reason\":\""); diag_json_esc(&sb, block_reason); strings.write_string(&sb, "\"") }
    strings.write_string(&sb, "}\n")
    _ = os.write_entire_file(path, transmute([]u8)strings.to_string(sb))
}

diag_write_json :: proc(path, url: string, root: ^Box, page_w: f32, vm: ^jspkg.Interp, http_status := 200, body_bytes := 0) {
    n_boxes, n_over, n_coll := 0, 0, 0
    over: [dynamic]^Box; defer delete(over)
    coll: [dynamic]^Box; defer delete(coll)
    diag_walk(root, page_w, &n_boxes, &n_over, &n_coll, &over, &coll)

    n_ready, n_failed, n_loading, n_svg_fail := 0, 0, 0, 0
    for _, img in g_images {
        switch img.state {
        case .Ready:   n_ready += 1
        case .Failed:  n_failed += 1; if strings.has_suffix(img.url, ".svg") do n_svg_fail += 1
        case .Loading: n_loading += 1
        }
    }

    sb: strings.Builder
    strings.builder_init(&sb, context.allocator)
    defer strings.builder_destroy(&sb)

    // Classificação anti-bot: separa páginas BLOQUEADAS por WAF/challenge de gaps
    // reais da engine. HTTP 202 = desafio do AWS WAF; 401/403/429/451/5xx = bloqueio/
    // erro; corpo minúsculo (<2KB) num status "ok" ainda pode ser um loader de
    // challenge, então também marcamos como suspeito. Sem isto o ranking do
    // gap-miner misturava desafios não-acionáveis com bugs de engine acionáveis.
    uncaught := vm != nil ? vm.uncaught_total : 0
    blocked := http_status == 202 || http_status == 401 || http_status == 403 ||
        http_status == 429 || http_status == 451 || http_status >= 500
    block_reason := ""
    switch {
    case http_status == 202:                 block_reason = "aws-waf-challenge"
    case http_status == 403 || http_status == 401: block_reason = "forbidden"
    case http_status == 429:                 block_reason = "rate-limited"
    case http_status == 451:                 block_reason = "legal-block"
    case http_status >= 500:                 block_reason = "server-error"
    // corpo minúsculo num 200 só é bloqueio se a página NÃO rodou/lançou JS real:
    // uma shell SPA que executa e falha (uncaught>0) é GAP da engine, não challenge
    // (ex.: archive.org = 200/1.8KB mas erro Lit `createProperty` — bug real, não WAF).
    case http_status == 200 && body_bytes < 2048 && uncaught == 0: blocked = true; block_reason = "tiny-body"
    }

    strings.write_string(&sb, "{\"url\":\""); diag_json_esc(&sb, url)
    // page_h = altura EM FLUXO do root. Sozinha ela mente quando o conteúdo vive em
    // caixas fixed/absolute (fora do fluxo → o root não as soma): bandcamp
    // (`html{position:absolute}`) e edition.cnn.com (body com scroll travado pelo
    // modal de consentimento) RENDERIZAM mas davam page_h=0 e eram classificados
    // BLANK. content_h = maior extensão y+h de QUALQUER caixa, que inclui as
    // out-of-flow (o passe de absolutos as reparenteia na árvore).
    fmt.sbprintf(&sb, "\",\"ok\":true,\"boxes\":%d,\"page_h\":%.0f,\"content_h\":%.0f,\"overflow\":%d,\"collapsed\":%d",
        n_boxes, root.h, box_max_extent(root), n_over, n_coll)
    fmt.sbprintf(&sb, ",\"http_status\":%d,\"body_bytes\":%d,\"blocked\":%s", http_status, body_bytes, blocked ? "true" : "false")
    if block_reason != "" { strings.write_string(&sb, ",\"block_reason\":\""); diag_json_esc(&sb, block_reason); strings.write_string(&sb, "\"") }
    strings.write_string(&sb, ",\"images\":{") // "{" literal fora do format string (o fmt do Odin trata { como placeholder)
    fmt.sbprintf(&sb, "\"ready\":%d,\"failed\":%d,\"svg_failed\":%d,\"loading\":%d", n_ready, n_failed, n_svg_fail, n_loading)
    strings.write_string(&sb, "}")

    strings.write_string(&sb, ",\"css_unknown\":{")
    first := true
    for k, v in g_css_unknown {
        if !first do strings.write_string(&sb, ",")
        first = false
        strings.write_string(&sb, "\""); diag_json_esc(&sb, k)
        fmt.sbprintf(&sb, "\":%d", v)
    }
    strings.write_string(&sb, "}")

    strings.write_string(&sb, ",\"js_uncaught\":[")
    if vm != nil {
        for m, i in vm.uncaught_log {
            if i > 0 do strings.write_string(&sb, ",")
            strings.write_string(&sb, "\""); diag_json_esc(&sb, m); strings.write_string(&sb, "\"")
        }
    }
    strings.write_string(&sb, "]")
    fmt.sbprintf(&sb, ",\"js_uncaught_total\":%d", vm != nil ? vm.uncaught_total : 0)

    // Rejeições de promise NÃO TRATADAS: o 2º ponto cego (o 1º foi console.error, M127).
    // Um erro no corpo de uma async function vira rejeição e some dos dois canais —
    // custou várias rodadas de sonda no peel do Lit (M130).
    strings.write_string(&sb, ",\"js_unhandled_rejections\":[")
    if vm != nil {
        for m, i in vm.rejected_log {
            if i > 0 do strings.write_string(&sb, ",")
            strings.write_string(&sb, "\""); diag_json_esc(&sb, m); strings.write_string(&sb, "\"")
        }
    }
    strings.write_string(&sb, "]")
    fmt.sbprintf(&sb, ",\"js_rejected_total\":%d", vm != nil ? vm.rejected_total : 0)

    // Uso REAL do MutationObserver (M201). A lição do M199 é contar quanto uma API
    // é chamada ANTES de investir nela; agora que investimos, este par é a medida
    // de quanto ela paga em site de verdade — e o gap-miner o coleta de graça.
    fmt.sbprintf(&sb, ",\"js_mo_observe_calls\":%d", vm != nil ? vm.mo_observe_calls : 0)
    fmt.sbprintf(&sb, ",\"js_mo_records_sent\":%d", vm != nil ? vm.mo_records_sent : 0)
    // O par equivalente do IntersectionObserver (M232). `observe_calls>0` com
    // `entries_sent=0` é o sinal de que a página observa mas o passo nunca correu —
    // exatamente o estado em que a feature ficaria se o hospedeiro esquecesse o io_step.
    fmt.sbprintf(&sb, ",\"js_io_observe_calls\":%d", vm != nil ? vm.io_observe_calls : 0)
    fmt.sbprintf(&sb, ",\"js_io_entries_sent\":%d",  vm != nil ? vm.io_entries_sent  : 0)
    fmt.sbprintf(&sb, ",\"js_ro_observe_calls\":%d", vm != nil ? vm.ro_observe_calls : 0)
    fmt.sbprintf(&sb, ",\"js_ro_entries_sent\":%d",  vm != nil ? vm.ro_entries_sent  : 0)

    // console.error: PONTO CEGO do js_uncaught. Frameworks com error boundary (React)
    // CAPTURAM a exceção, desmontam a árvore e seguem — o site fica em branco com
    // js_uncaught vazio e uncaught_total 0. Foi o que escondeu a raiz do npmjs.com por
    // várias camadas de peel (M127). Aqui o sinal entra no JSON e o gap-report pode
    // ranqueá-lo junto com as uncaught.
    strings.write_string(&sb, ",\"js_console_errors\":[")
    if vm != nil {
        n_err := 0
        for e in vm.console_buf {
            if e.level != .Error do continue
            if n_err >= 12 do break // teto: basta a assinatura, não o log inteiro
            if n_err > 0 do strings.write_string(&sb, ",")
            strings.write_string(&sb, "\""); diag_json_esc(&sb, e.text); strings.write_string(&sb, "\"")
            n_err += 1
        }
    }
    strings.write_string(&sb, "]")
    fmt.sbprintf(&sb, ",\"js_parse_recoveries\":%d", vm != nil ? vm.parse_recoveries : 0)

    strings.write_string(&sb, ",\"js_parse_notes\":[")
    if vm != nil {
        n_notes := min(vm.parse_recoveries, len(vm.parse_notes))
        for i in 0 ..< n_notes {
            if i > 0 do strings.write_string(&sb, ",")
            rn := vm.parse_notes[i]
            strings.write_string(&sb, "\""); diag_json_esc(&sb, rn.what)
            if rn.text != "" { fmt.sbprintf(&sb, " [%v] :: ", rn.kind); diag_json_esc(&sb, rn.text) }
            strings.write_string(&sb, "\"")
        }
    }
    strings.write_string(&sb, "]}\n")

    _ = os.write_entire_file(path, transmute([]u8)strings.to_string(sb))
    fmt.eprintfln("  relatório JSON      → %s", path)
}

// ── Fase 2 (PROVA isolada do pipeline de layer offscreen) ────────────────────
// Renderiza uma SUB-lista de comandos numa textura offscreen via uma DrawList
// SECUNDÁRIA (montada à mão — os bindings não expõem construtor de ImDrawList) e
// a compõe com alpha, provando que: (a) o backend SDL_Renderer renderiza uma
// DrawData avulsa num alvo .TARGET, e (b) o group-opacity NÃO sofre double-darken.
// Dois retângulos VERMELHOS OPACOS sobrepostos, compostos 1× a 50% sobre branco,
// dão (255,128,128) no overlap — NÃO um vermelho escurecido (255,~64,~64), que é
// o que a abordagem atual (alpha por-primitiva) produziria.
headless_phase2test :: proc() -> bool {
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 { fmt.eprintln("SDL_Init falhou"); return false }
    defer sdl2.Quit()
    window := sdl2.CreateWindow("p2", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 128, 128, {.HIDDEN})
    if window == nil { fmt.eprintln("janela falhou"); return false }
    defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer // p/ o compositing de layers (group-opacity)
    if renderer == nil { fmt.eprintln("renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda

    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO(); io.DisplaySize = {128, 128}
    setup_fonts(io); apply_style()
    imgui_sdl2.InitForSDLRenderer(window, renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()

    // um frame vazio p/ o backend SDL_Renderer criar a textura do atlas de fonte
    // (o white-pixel usado por AddRectFilled vem dela; io.Fonts.TexID fica válido).
    imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
    im.Render()
    imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)

    W :: i32(128); H :: i32(128)

    // ── textura da LAYER: 2 quadrados VERMELHOS OPACOS sobrepostos ────────────
    layer := sdl2.CreateTexture(renderer, .ABGR8888, .TARGET, W, H)
    if layer == nil { fmt.eprintln("layer tex falhou"); return false }
    defer sdl2.DestroyTexture(layer)
    sdl2.SetTextureBlendMode(layer, .BLEND)
    sdl2.SetRenderTarget(renderer, layer)
    sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 0) // transparente
    sdl2.RenderClear(renderer)

    // DrawList secundária — sem construtor no binding: zera + _Data + reset.
    ld: im.DrawList
    ld._Data = im.GetDrawListSharedData()
    im.DrawList__ResetForNewFrame(&ld)
    defer im.DrawList__ClearFreeMemory(&ld)
    im.DrawList_PushTextureID(&ld, io.Fonts.TexID)
    im.DrawList_PushClipRectFullScreen(&ld)
    RED :: u32(0xff0000ff) // IM_COL32: A=ff B=00 G=00 R=ff (opaco)
    im.DrawList_AddRectFilled(&ld, {20, 20}, {80, 80},  RED, 0, {})
    im.DrawList_AddRectFilled(&ld, {48, 48}, {108, 108}, RED, 0, {})

    // DrawData de 1 lista → renderiza na textura da layer
    lists := [1]^im.DrawList{&ld}
    dd: im.DrawData
    dd.Valid = true
    dd.CmdListsCount = 1
    dd.CmdLists = { Size = 1, Capacity = 1, Data = &lists[0] }
    dd.TotalVtxCount = ld.VtxBuffer.Size
    dd.TotalIdxCount = ld.IdxBuffer.Size
    dd.DisplayPos = {0, 0}
    dd.DisplaySize = {f32(W), f32(H)}
    dd.FramebufferScale = {1, 1}
    imgui_sdlr.RenderDrawData(&dd, renderer)

    // ── alvo BRANCO + compõe a layer a 50% (group opacity) ────────────────────
    target := sdl2.CreateTexture(renderer, .ABGR8888, .TARGET, W, H)
    if target == nil { fmt.eprintln("target tex falhou"); return false }
    defer sdl2.DestroyTexture(target)
    sdl2.SetRenderTarget(renderer, target)
    sdl2.SetRenderDrawColor(renderer, 255, 255, 255, 255) // fundo branco
    sdl2.RenderClear(renderer)
    sdl2.SetTextureAlphaMod(layer, 128) // group opacity = 0.5
    sdl2.RenderCopy(renderer, layer, nil, nil)

    // ── lê os pixels e valida ─────────────────────────────────────────────────
    px := make([]u8, int(W)*int(H)*4); defer delete(px)
    rect := sdl2.Rect{0, 0, W, H}
    if sdl2.RenderReadPixels(renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(px), W*4) != 0 {
        fmt.eprintfln("RenderReadPixels falhou: %s", sdl2.GetErrorString()); return false
    }
    sdl2.SetRenderTarget(renderer, nil)

    // ABGR8888 little-endian → bytes R,G,B,A
    sample :: proc(px: []u8, W, x, y: i32) -> (r, g, b: int) {
        i := (int(y)*int(W) + int(x)) * 4
        return int(px[i]), int(px[i+1]), int(px[i+2])
    }
    br, bg, bb := sample(px, W, 5, 5)    // fundo (sem layer)
    sr, sg, sb := sample(px, W, 25, 25)  // vermelho ÚNICO a 50%
    or_, og, ob := sample(px, W, 64, 64) // OVERLAP dos 2 quadrados
    fmt.printfln("fundo   (5,5)   = (%d,%d,%d)   esperado ~(255,255,255)", br, bg, bb)
    fmt.printfln("single  (25,25) = (%d,%d,%d)   esperado ~(255,128,128)", sr, sg, sb)
    fmt.printfln("overlap (64,64) = (%d,%d,%d)   esperado ~(255,128,128)  [double-darken daria G/B ~64]", or_, og, ob)

    near :: proc(v, want: int) -> bool { return abs(v - want) <= 12 }
    ok := near(br,255)&&near(bg,255)&&near(bb,255) &&
          near(sr,255)&&near(sg,128)&&near(sb,128) &&
          near(or_,255)&&near(og,128)&&near(ob,128)
    fmt.printfln(ok ? "PHASE2 SELFTEST: PASS (pipeline offscreen OK, sem double-darken)" : "PHASE2 SELFTEST: FAIL")
    return ok
}

// ── PROVA isolada do rebuild de ATLAS em runtime (pré-requisito do @font-face) ──
// O atlas de fontes é montado UMA vez no boot (setup_fonts) e o backend cria a
// textura a partir dele. `@font-face` exige acrescentar uma face DEPOIS — uma
// fonte que chegou pela rede —, o que significa reconstruir o atlas e re-subir a
// textura com o frame já em andamento. Esta prova responde, sem depender de nada
// do resto da feature: (a) `AddFontFromMemoryTTF` aceita bytes nossos;
// (b) `DestroyFontsTexture` + `FontAtlas_Build` + `CreateFontsTexture` refaz a
// textura; (c) os ponteiros ^Font ANTIGOS continuam válidos depois disso; e
// (d) a face nova realmente MEDE e PINTA diferente da embutida.
// Mesmo papel do `--phase2test` para o compositing de layers (M101): provar a
// peça de risco antes de construir por cima dela.
headless_fonttest :: proc(ttf_path := "C:\\Windows\\Fonts\\impact.ttf") -> bool {
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 { fmt.eprintln("SDL_Init falhou"); return false }
    defer sdl2.Quit()
    window := sdl2.CreateWindow("ft", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 256, 128, {.HIDDEN})
    if window == nil { fmt.eprintln("janela falhou"); return false }
    defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer
    if renderer == nil { fmt.eprintln("renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all()
    defer emoji_shutdown()

    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO(); io.DisplaySize = {256, 128}
    setup_fonts(io); apply_style()
    imgui_sdl2.InitForSDLRenderer(window, renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()

    imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
    im.Render()
    imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)

    SAMPLE :: "Hamburgefonstiv"
    base_font := g_reg[0]
    if base_font == nil { fmt.eprintln("fonttest: g_reg[0] nil"); return false }
    w_base := im.Font_CalcTextSizeA(base_font, 16, 1e9, 0, SAMPLE).x
    tex_before := io.Fonts.TexID

    // ── a face "da rede": aqui vem de disco, mas o caminho é o mesmo (bytes) ──
    data, err_read := os.read_entire_file_from_path(ttf_path, context.allocator)
    if err_read != nil { fmt.eprintfln("fonttest: nao li %s (%v)", ttf_path, err_read); return false }
    defer delete(data)

    cfg := im.FontConfig{
        FontDataOwnedByAtlas = false, // os bytes são NOSSOS (o atlas não pode liberá-los)
        OversampleH = 2, OversampleV = 1,
        GlyphMaxAdvanceX = 3.4028235e38,
        RasterizerMultiply = 1.0, RasterizerDensity = 1.0,
        EllipsisChar = 0xFFFF,
    }
    novo := im.FontAtlas_AddFontFromMemoryTTF(io.Fonts, raw_data(data), c.int(len(data)), 16, &cfg, &g_text_ranges[0])
    if novo == nil { fmt.eprintln("fonttest: AddFontFromMemoryTTF devolveu nil"); return false }

    // ── o rebuild propriamente dito ──────────────────────────────────────────
    imgui_sdlr.DestroyFontsTexture()
    if !im.FontAtlas_Build(io.Fonts) { fmt.eprintln("fonttest: FontAtlas_Build falhou"); return false }
    if !imgui_sdlr.CreateFontsTexture() { fmt.eprintln("fonttest: CreateFontsTexture falhou"); return false }

    w_novo  := im.Font_CalcTextSizeA(novo, 16, 1e9, 0, SAMPLE).x
    w_base2 := im.Font_CalcTextSizeA(base_font, 16, 1e9, 0, SAMPLE).x
    tex_after := io.Fonts.TexID

    // ── pinta o mesmo texto com as duas faces e conta pixels escritos ────────
    conta_pixels :: proc(renderer: ^sdl2.Renderer, io: ^im.IO, f: ^im.Font, s: cstring) -> (int, bool) {
        W :: i32(256); H :: i32(64)
        target := sdl2.CreateTexture(renderer, .ABGR8888, .TARGET, W, H)
        if target == nil do return 0, false
        defer sdl2.DestroyTexture(target)
        sdl2.SetRenderTarget(renderer, target)
        sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 255)
        sdl2.RenderClear(renderer)

        ld: im.DrawList
        ld._Data = im.GetDrawListSharedData()
        im.DrawList__ResetForNewFrame(&ld)
        defer im.DrawList__ClearFreeMemory(&ld)
        im.DrawList_PushTextureID(&ld, io.Fonts.TexID)
        im.DrawList_PushClipRectFullScreen(&ld)
        im.DrawList_AddTextImFontPtr(&ld, f, 32, {4, 4}, 0xffffffff, s)

        lists := [1]^im.DrawList{&ld}
        dd: im.DrawData
        dd.Valid = true
        dd.CmdListsCount = 1
        dd.CmdLists = {Size = 1, Capacity = 1, Data = &lists[0]}
        dd.TotalVtxCount = ld.VtxBuffer.Size
        dd.TotalIdxCount = ld.IdxBuffer.Size
        dd.DisplayPos = {0, 0}
        dd.DisplaySize = {f32(W), f32(H)}
        dd.FramebufferScale = {1, 1}
        imgui_sdlr.RenderDrawData(&dd, renderer)

        px := make([]u8, int(W) * int(H) * 4); defer delete(px)
        rect := sdl2.Rect{0, 0, W, H}
        if sdl2.RenderReadPixels(renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(px), W * 4) != 0 {
            sdl2.SetRenderTarget(renderer, nil); return 0, false
        }
        sdl2.SetRenderTarget(renderer, nil)
        n := 0
        for i := 0; i < len(px); i += 4 do if px[i] > 128 do n += 1
        return n, true
    }
    n_base, ok1 := conta_pixels(renderer, io, base_font, SAMPLE)
    n_novo, ok2 := conta_pixels(renderer, io, novo, SAMPLE)
    if !ok1 || !ok2 { fmt.eprintln("fonttest: leitura de pixels falhou"); return false }

    fmt.printfln("largura embutida antes/depois do rebuild = %.2f / %.2f  (o ^Font antigo tem de sobreviver INTACTO)", w_base, w_base2)
    fmt.printfln("largura da face NOVA                     = %.2f  (informativo: fontes distintas podem ter avanço parecido)", w_novo)
    fmt.printfln("TexID antes/depois                       = %v / %v  (informativo: o backend pode reusar o MESMO endereço)", tex_before, tex_after)
    fmt.printfln("pixels pintados embutida / nova          = %d / %d  (é ESTE o sinal: ambos > 0 e claramente diferentes)", n_base, n_novo)

    // O critério é o PIXEL, não o TexID nem a largura. Se a textura não tivesse
    // sido re-subida, os glifos da face nova sairiam vazios/lixo; e o fato de a
    // embutida AINDA pintar (849 px) prova que o rebuild não a corrompeu.
    // ⚠️ 1ª versão deste teste reprovava por TexID igual e por 0,8px de diferença
    // de largura — critérios meus errados, não a pipeline (a suspeita nº1 quando
    // um teste próprio falha é a expectativa).
    dif := abs(f32(n_novo - n_base)) / f32(max(n_base, 1))
    ok := w_base2 > 0 && abs(w_base - w_base2) < 0.01 && // (c) a face antiga sobreviveu intacta
          w_novo > 0 &&                                   // (a) a face nova existe e mede
          n_base > 50 && n_novo > 50 && dif > 0.2         // (b,d) as duas rasterizam, e diferente
    fmt.printfln(ok ? "FONTTEST: PASS (atlas reconstruido em runtime; face nova rasteriza e a antiga sobrevive)" : "FONTTEST: FAIL")
    return ok
}

headless_diagnose :: proc(url: string, json_path := "") -> bool {
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 { fmt.eprintln("SDL_Init falhou"); return false }
    defer sdl2.Quit()
    window := sdl2.CreateWindow("diag", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 1280, 900, {.HIDDEN})
    if window == nil { fmt.eprintln("janela falhou"); return false }
    defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer // p/ o compositing de layers (group-opacity)
    if renderer == nil { fmt.eprintln("renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda

    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO(); io.DisplaySize = {1280, 900}
    setup_fonts(io); apply_style()
    imgui_sdl2.InitForSDLRenderer(window, renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()

    s := State{}
    tab := make_tab("diag")
    append(&s.tabs, tab)
    defer delete(s.tabs)

    fmt.eprintfln("[diag] navegando p/ %s", url)
    start_navigation(&s, url)

    page_w: f32 = 1280
    lay: ^Box = nil
    stable := 0
    for f in 0 ..< 2000 {
        // Recicla a arena temp POR FRAME, igual ao loop real do navegador
        // (browser_ui.odin, topo do frame). Sem isto, 2000 frames de
        // layout_box+paint_layout — e um compute_styles+build_layout INTEIRO a
        // cada tick de timer via restyle_tab — empilhavam na arena sem nunca
        // voltar: o processo crescia ~1 GB/s, linear no TEMPO e nao no tamanho
        // da pagina, ate encher a RAM da maquina. Era o que fazia a mineracao
        // de sites reais travar o PC.
        //
        // Seguro pelas MESMAS invariantes do loop interativo, que ja faz isto:
        //   - o trabalho por frame (layout_box/layout_absolutes/paint_layout) le
        //     so a arvore de Box, que e AUTOCONTIDA (Inline_Item.text, href e
        //     edit_hint sao strings.clone no heap; bg_img idem);
        //   - o mapa `styles` — que guarda slices p/ dentro da temp em campos
        //     como content/quotes_raw — so e lido dentro do build_layout, e todo
        //     caminho de rebuild aqui faz compute_styles logo antes, no MESMO
        //     frame, depois deste free_all;
        //   - `tab.css_text`, re-parseado pelo restyle_tab, e DONO (clonado pelo
        //     fetch_worker justamente p/ sobreviver ao free_all).
        free_all(context.temp_allocator)
        imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
        when UIPROF { g_uiprof.frames += 1; tf := time.tick_now() }
        poll_jobs(&s)
        when UIPROF { g_uiprof.ms_jobs += time.duration_milliseconds(time.tick_since(tf)); tf = time.tick_now() }
        images_poll(renderer)
        when UIPROF { g_uiprof.ms_imagens += time.duration_milliseconds(time.tick_since(tf)) }
        io.MousePos = {-1, -1}
        // Fonte do getComputedStyle ANTES do pump de timers: aqui a aba veio pronta
        // do worker (start_navigation → poll_jobs), sem passar por restyle_tab, e o
        // JS do 1º timer roda logo abaixo. Setar só depois do layout_box (como faz o
        // browser_ui) deixaria a 1ª leitura sem estilo — foi o que a sonda mediu.
        if len(s.tabs) > 0 && s.tabs[0].layout != nil {
            js_style_source_set(s.tabs[0].styles, s.tabs[0].layout, page_w, 900)
        }
        if len(s.tabs) > 0 && s.tabs[0].vm != nil {
            // timer disparou ≠ DOM mudou: só re-estiliza se mudou (ver
            // dompkg.fingerprint e o guarda equivalente no browser_ui)
            when UIPROF { tf = time.tick_now() }
            disparou := animation_dispatch(s.tabs[0].layout, s.tabs[0].vm)
            if jspkg.vm_pump_timers(s.tabs[0].vm, 1000.0 / 60.0) do disparou = true
            // IntersectionObserver: mesmo passo por frame do headless_render. Sem
            // ele o --diagnose mediria uma página em que o observador nunca correu,
            // e os contadores js_io_* seriam sempre zero.
            if jspkg.vm_frame_step(s.tabs[0].vm) do disparou = true
            when UIPROF { g_uiprof.ms_js += time.duration_milliseconds(time.tick_since(tf)) }
            if disparou {
                t := &s.tabs[0]
                when UIPROF { tf = time.tick_now() }
                mudou := t.dom != nil && dompkg.fingerprint(t.dom) != t.dom_fp
                when UIPROF { g_uiprof.ms_fp += time.duration_milliseconds(time.tick_since(tf)); tf = time.tick_now() }
                if mudou do restyle_tab(t, 1280, 900)
                when UIPROF { if mudou { g_uiprof.ms_restyle += time.duration_milliseconds(time.tick_since(tf)); g_uiprof.restyles += 1 } }
            }
        }
        im.SetNextWindowPos({0, 0}); im.SetNextWindowSize({1280, 900})
        im.Begin("##diag", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoBringToFrontOnFocus, .NoNavFocus})
        lay = len(s.tabs) > 0 ? s.tabs[0].layout : nil
        if lay != nil {
            when UIPROF { tf = time.tick_now() }
            layout_box(lay, 0, 0, page_w)
            page := Rect{0, 0, page_w, 900} // ICB = viewport (CSS 2.1 §10.1)
            layout_absolutes(lay, page, page)
            // fonte do getComputedStyle p/ o JS deste frame (mesma razão do
            // browser_ui: a aba pode ter vindo pronta, sem passar por restyle_tab)
            js_style_source_set(s.tabs[0].styles, lay, page_w, 900, laid_out = true)
            when UIPROF { g_uiprof.ms_layout += time.duration_milliseconds(time.tick_since(tf)); tf = time.tick_now() }
            paint_layout(&s, lay)
            when UIPROF { g_uiprof.ms_paint += time.duration_milliseconds(time.tick_since(tf)) }
        }
        im.End()
        when UIPROF { tf = time.tick_now() }
        im.Render()
        sdl2.SetRenderDrawColor(renderer, 255, 255, 255, 255); sdl2.RenderClear(renderer)
        imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)
        sdl2.RenderPresent(renderer)
        when UIPROF { g_uiprof.ms_render += time.duration_milliseconds(time.tick_since(tf)) }
        // estabilizou = layout pronto e nenhuma imagem baixando NEM esperando backoff
        // de retry (images_pending inclui as .Loading em espera de Retry-After) por ~45 frames
        if lay != nil && g_img_active == 0 && !images_pending() {
            stable += 1
            if stable >= 45 do break
        } else {
            stable = 0
        }
        when UIPROF { tf = time.tick_now() }
        sdl2.Delay(6)
        when UIPROF { g_uiprof.ms_delay += time.duration_milliseconds(time.tick_since(tf)) }
    }
    if lay == nil {
        fmt.eprintln("[diag] layout não carregou (timeout)")
        st, bb := 0, 0
        if len(s.tabs) > 0 { st = s.tabs[0].status; bb = len(s.tabs[0].content) }
        if json_path != "" do diag_write_json_fail(json_path, url, "layout não carregou (fetch falhou ou timeout)", st, bb)
        return false
    }

    // relayout final na largura da página p/ medidas consistentes
    layout_box(lay, 0, 0, page_w)
    // ICB (bloco contenedor inicial) = dimensões do VIEWPORT (CSS 2.1 §10.1), não a
    // altura do documento: um `html{position:absolute;inset:0}` (bandcamp) sai do
    // fluxo, zera a altura do root e, com ICB=altura-do-documento, resolveria a si
    // mesmo como 0 (circular) → página inteira colapsa.
    pg := Rect{0, 0, page_w, 900}
    layout_absolutes(lay, pg, pg)

    diag_report(url, lay, page_w)
    if json_path != "" do diag_write_json(json_path, url, lay, page_w, s.tabs[0].vm, s.tabs[0].status, len(s.tabs[0].content))
    return true
}

headless_render :: proc(html_path, out_png: string, width: i32 = 800, height: i32 = 600, mx: f32 = -1, my: f32 = -1, frames: i32 = 1, scroll_y: f32 = 0, wheel: f32 = 0, click: bool = false) -> bool {
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 {
        fmt.eprintfln("headless: SDL_Init falhou: %s", sdl2.GetErrorString())
        return false
    }
    defer sdl2.Quit()

    // Janela oculta: precisamos dela só para criar o renderer.
    window := sdl2.CreateWindow("headless", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, width, height, {.HIDDEN})
    if window == nil { fmt.eprintln("headless: janela falhou"); return false }
    defer sdl2.DestroyWindow(window)

    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer // p/ o compositing de layers (group-opacity)
    if renderer == nil { fmt.eprintln("headless: renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda

    im.CHECKVERSION()
    im.CreateContext()
    defer im.DestroyContext()
    io := im.GetIO()
    setup_fonts(io)
    apply_style()

    imgui_sdl2.InitForSDLRenderer(window, renderer)
    defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer)
    defer imgui_sdlr.Shutdown()

    // ── Carrega o HTML: de URL (com rede) ou de arquivo local ────────────────
    // O viewport ANTES dos <script> de carga: `window.innerWidth` é lido aí (é onde
    // o site decide mobile×desktop) e o js_style_source_set só acontece lá embaixo,
    // depois do 1º compute_styles. Vale para os dois ramos.
    js_viewport_set(f32(width), f32(height))
    dom: ^dompkg.Node
    page_vm: ^jspkg.Interp
    css_text: string
    base_url := ""
    if strings.has_prefix(html_path, "http://") || strings.has_prefix(html_path, "https://") {
        // Pipeline de rede COMPLETO (igual ao --fetch): scripts externos+inline em
        // duas fases (load_page_scripts) E folhas de estilo externas (collect_page_css).
        // É o caminho que representa um site ao vivo — o --render de arquivo NÃO baixa CSS.
        resp := net.fetch(html_path)
        if !resp.ok { fmt.eprintfln("headless: fetch falhou %s (%s)", html_path, resp.err); return false }
        dom = htmlp.parse_render(resp.body)
        page_vm = load_page_scripts(dom, html_path) // roda <script>; retém handlers
        css_text = collect_page_css(dom, html_path) // <style> + <link> externos
        base_url = html_path
    } else {
        data, rerr := os.read_entire_file_from_path(html_path, context.allocator)
        if rerr != nil { fmt.eprintfln("headless: nao consegui ler %s", html_path); return false }
        dom = htmlp.parse_render(string(data)) // parser de spec — caminho do --render local (WPT)
        page_vm = jspkg.load_page(dom)          // vm persistente: roda <script> e retém handlers
        css_text = collect_css(dom)             // só <style> inline / style="" (sem rede)
    }
    defer jspkg.vm_free(page_vm)
    // collect_page_css/collect_css devolvem string da arena TEMP, e o laço de
    // frames abaixo re-parseia css_text (timer e clique) DEPOIS do free_all por
    // frame — logo ela precisa ser DONA, como o fetch_worker faz com job.css_text.
    css_text = strings.clone(css_text)
    defer delete(css_text)

    // @font-face: registra (e dispara os downloads) ANTES do 1º compute_styles,
    // p/ que `font-family: Inter` já resolva p/ o fam_id se a face chegar a tempo.
    fontface_scan(css_text, base_url)
    // rules/kf transitórios; um clique re-parseia css_text (ver bloco de clique)
    rules, kf := csspkg.parse(css_text)
    styles, page_bg := compute_styles(dom, &rules, f32(width), f32(height), kf[:])
    // build_layout LÊ campos "_raw" do Computed (quotes_raw, content_raw…) que são
    // SLICES p/ dentro de `rules` — liberar rules antes do build = use-after-free
    // (crash em <q>/quote_mark em páginas como a Wikipedia). Libera DEPOIS do build
    // (os caminhos de rebuild por clique/timer já faziam nessa ordem).
    layout := build_layout(dom, styles, base_url)
    // Fonte do getComputedStyle (computed_om.odin). Aqui `styles`/`layout` são
    // LOCAIS desta função, que vive por toda a renderização — o ponteiro é estável.
    // Re-setado depois de cada rebuild abaixo, porque cada um libera o mapa anterior.
    js_style_source_set(styles, layout, f32(width), f32(height))
    defer js_style_source_clear()
    // Scroll ANTES do laço, direto do parâmetro: o 1º pump de timers roda antes do
    // im.Begin (logo, antes de qualquer GetScrollY), e sem isto o
    // getBoundingClientRect da 1ª leitura ignoraria o scroll pedido.
    js_scroll_set(0, scroll_y)
    // Container queries: a 1ª passada MEDE os contêineres, a 2ª reestiliza com as
    // medidas. São só duas: `container-type` estabelece contenção, então a largura
    // do contêiner não depende do conteúdo dele — a 3ª mediria o mesmo.
    if container_rules_present(rules[:]) {
        container_w_clear()
        layout_box(layout, 0, 0, f32(width))
        if g_container_dirty {
            g_container_dirty = false
            free_styles(styles)
            old_layout := layout
            styles, page_bg = compute_styles(dom, &rules, f32(width), f32(height), kf[:])
            layout = build_layout(dom, styles, base_url)
            animation_restore_tree(layout, old_layout)
            free_layout(old_layout)
            js_style_source_set(styles, layout, f32(width), f32(height))
        }
    }
    csspkg.free_rules(&rules)
    csspkg.free_keyframes(&kf)

    // State mínimo p/ o paint (sem abas/UI reais).
    s := State{}
    tab := make_tab("headless")
    tab.dom = dom; tab.styles = styles; tab.page_bg = page_bg; tab.layout = layout; tab.vm = page_vm
    append(&s.tabs, tab)
    defer delete(s.tabs)

    // ── Alvo offscreen ───────────────────────────────────────────────────────
    target := sdl2.CreateTexture(renderer, .ABGR8888, .TARGET, width, height)
    if target == nil { fmt.eprintln("headless: target falhou"); return false }
    defer sdl2.DestroyTexture(target)
    sdl2.SetRenderTarget(renderer, target)

    // ── Frame(s) ImGui ─ frames>1 avança animações (transition) c/ dt fixo ─────
    // Após os frames planejados, CONTINUA pintando p/ DRENAR imagens assíncronas
    // (headless não tem loop de tempo real; os downloads não terminam em poucos
    // frames). Nos frames de dreno usamos dt=0 → não avança timer/animação.
    planned := max(frames, 1)
    click_frame := planned - 2 // clica no penúltimo frame; o último pinta o resultado
    IMG_DRAIN_CAP :: 600       // ~9s a 15ms/frame de teto (quebra cedo quando tudo chega)
    f: i32 = 0
    done := false
    had_pending := false // houve alguma imagem carregando? (senão NÃO faz o repaint-final)
    // Baseline do fingerprint p/ o guarda de timer. Tirada AGORA, depois do
    // compute_styles inicial (que carimba data-shadow-scope nos hosts de shadow
    // root) — tirar antes daria divergência permanente e o guarda nunca pegaria.
    dom_fp := dompkg.fingerprint(dom)
    for {
        // Recicla a arena temp por frame (ver a justificativa completa no laço do
        // headless_diagnose). Aqui o teto é planned+IMG_DRAIN_CAP = até ~600
        // frames de layout+paint, então o acúmulo era o mesmo problema. É o que
        // o `css_text = strings.clone(...)` acima passou a proteger.
        free_all(context.temp_allocator)
        draining := f >= planned
        // @font-face: promove as faces baixadas p/ o atlas ANTES de abrir o frame.
        // ⚠️ o ImGui TRAVA o atlas entre NewFrame e Render ("Cannot modify a locked
        // ImFontAtlas") — foi o assert que a 1ª versão disto tomou, e que a prova
        // isolada (--fonttest, fora de qualquer frame) não podia pegar.
        // Quando entra face nova as MÉTRICAS de texto mudam ⇒ força o rebuild de
        // layout do bloco de timers abaixo, zerando o fingerprint.
        fonts_changed := fontface_poll()
        imgui_sdlr.NewFrame()
        imgui_sdl2.NewFrame()  // o backend SDL sobrescreve DeltaTime/MousePos...
        // injeta um clique esquerdo ANTES do NewFrame (p/ IsMouseClicked disparar)
        if click && f == click_frame {
            im.IO_AddMousePosEvent(io, mx, my)
            im.IO_AddMouseButtonEvent(io, 0, true)
        }
        im.NewFrame()
        io.MousePos = {mx, my}    // ...então fixamos DEPOIS: mouse (p/ :hover)
        io.DeltaTime = draining ? 0 : 1.0 / 60.0 // dt determinístico; 0 no dreno
        io.MouseWheel = wheel     // injeta a roda (p/ testar scroll de elemento)
        images_poll(renderer)     // baixa/sobe texturas (imagens são assíncronas)

        // timers JS: dt determinístico de 1/60s (casa com io.DeltaTime acima).
        // Se algum disparou E mexeu no DOM, re-estiliza e reconstrói o layout
        // ANTES de pintar. O fingerprint evita o compute_styles+build_layout
        // inteiros quando o callback não mudou nada (ver dompkg.fingerprint).
        // Reconstrói quando um TIMER mexeu no DOM **ou** quando entrou face nova:
        // a fonte é escolhida no BUILD (fica gravada no Inline_Item), então uma
        // @font-face que chega depois só aparece com um novo build_layout.
        // ⚠️ o `||` importa: o ramo do timer exige `vm_pump_timers` ter disparado,
        // e uma página sem JS nenhum nunca satisfaria isso.
        // As DUAS fontes de JS por frame: timers/fetches e o passo do
        // IntersectionObserver (o "update the intersection observations" da spec,
        // que no navegador roda dentro do "update the rendering"). O io_step lê a
        // geometria pelo MESMO hook do getBoundingClientRect, então o layout do
        // frame anterior é o que ele enxerga — como no navegador, que observa
        // antes de pintar o frame novo.
        // ⚠️ os dois têm efeito colateral: encadear com `&&`/`||` curto-circuitaria
        // o segundo (era assim que a condição estava escrita, com o pump dentro do
        // `||`), e o observador só rodaria em frame com timer vencido.
        js_fired := false
        if !draining && page_vm != nil {
            if animation_dispatch(layout, page_vm) do js_fired = true
            if jspkg.vm_pump_timers(page_vm, 1000.0 / 60.0) do js_fired = true
            if jspkg.vm_frame_step(page_vm)                 do js_fired = true
        }
        if fonts_changed || (js_fired && dompkg.fingerprint(dom) != dom_fp) {
            rt, kt := csspkg.parse(css_text)
            free_styles(styles)
            old_layout := layout
            styles, page_bg = compute_styles(dom, &rt, f32(width), f32(height), kt[:])
            layout = build_layout(dom, styles, base_url) // base REAL: senão URLs relativas (/static, ../) viram https:/// e as imagens falham
            animation_restore_tree(layout, old_layout)
            free_layout(old_layout)
            csspkg.free_rules(&rt)
            csspkg.free_keyframes(&kt)
            s.tabs[0].styles = styles
            s.tabs[0].layout = layout
            js_style_source_set(styles, layout, f32(width), f32(height)) // o rebuild liberou o mapa antigo
            dom_fp = dompkg.fingerprint(dom) // nova baseline (o compute_styles pode ter carimbado)
        }

        im.SetNextWindowPos({0, 0})
        im.SetNextWindowSize({f32(width), f32(height)})
        im.PushStyleVarImVec2(.WindowPadding, {0, 0})
        im.PushStyleColor(.WindowBg, col(page_bg)) // fundo da página cobre todo o viewport
        im.Begin("##headless", nil, {
            .NoTitleBar, .NoResize, .NoMove,
            .NoScrollbar, .NoScrollWithMouse,
            .NoBringToFrontOnFocus, .NoNavFocus,
        })
        // scroll_y>0 exercita o MESMO mecanismo de scroll da página (SetScrollY +
        // GetCursorScreenPos aplicando o offset). Precisa da extensão do frame
        // anterior p/ não clampar em 0 — por isso rode com frames>=2.
        if scroll_y > 0 do im.SetScrollY(scroll_y)
        js_scroll_set(0, im.GetScrollY()) // p/ o getBoundingClientRect e window.scrollY
        if layout != nil {
            layout_box(layout, 0, 0, f32(width))
            page := Rect{0, 0, f32(width), f32(height)} // ICB = viewport (CSS 2.1 §10.1)
            layout_absolutes(layout, page, page)
            s.click_target = nil
            paint_layout(&s, layout)
            // dispatch do clique JS (headless): pode reconstruir o `layout` local
            if s.click_target != nil && page_vm != nil {
                target := s.click_target
                s.click_target = nil
                // bubbling acontece dentro de dispatch_event (alvo -> raiz)
                fired := jspkg.dispatch_event(page_vm, target, "click")
                if fired {
                    // re-estiliza (nós novos entram no mapa) e reconstrói o layout,
                    // re-parseando o css_text (rules com seletores frescos)
                    rules2, kf2 := csspkg.parse(css_text)
                    free_styles(styles)
                    old_layout := layout
                    styles, page_bg = compute_styles(dom, &rules2, f32(width), f32(height), kf2[:])
                    layout = build_layout(dom, styles, base_url) // base REAL (ver rebuild por timer)
                    animation_restore_tree(layout, old_layout)
                    free_layout(old_layout)
                    csspkg.free_rules(&rules2)
                    csspkg.free_keyframes(&kf2)
                    s.tabs[0].styles = styles
                    s.tabs[0].layout = layout
                    js_style_source_set(styles, layout, f32(width), f32(height)) // idem: mapa novo
                    dom_fp = dompkg.fingerprint(dom) // o clique mudou o DOM: nova baseline
                }
            }
            im.SetCursorPos({0, layout.h}) // extensão do conteúdo p/ habilitar scroll
            im.Dummy({1, 1})
        }
        im.End()
        im.PopStyleColor(1)
        im.PopStyleVar(1)

        im.Render()

        // ── Pinta fundo + draw data no alvo ──────────────────────────────────
        sdl2.SetRenderDrawColor(renderer, u8((page_bg >> 16) & 0xff), u8((page_bg >> 8) & 0xff), u8(page_bg & 0xff), 255)
        sdl2.RenderClear(renderer)
        imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)
        // ⚠️ VAZAMENTO: o SDL ENFILEIRA os comandos de render e só recicla essa
        // memória no flush. O laço interativo e o --diagnose flushavam de graça
        // pelo RenderPresent; aqui, que pinta num alvo offscreen, NINGUÉM flushava
        // e a fila crescia a cada frame — 4 alocações SDL/frame, ~7,7 MB/frame numa
        // página de 3000 caixas (medido: working set ia a 2 GB em ~400 frames, e o
        // bandcamp estourava 2,5 GB e nunca produzia PNG). O rastreador de alocação
        // do Odin não via NADA disso: é memória do lado C. Ver LEAK_PROBE.
        sdl2.RenderFlush(renderer)

        // Sonda de vazamento do lado C (compile-gated, custo zero quando off):
        //   odin build . -define:LEAK_PROBE=true
        // O rastreador de alocação do Odin mostrou só ~59 MB vivos enquanto o
        // working set ia a 2 GB — logo o que cresce NÃO é heap nosso. Estes dois
        // contadores separam os dois suspeitos que sobram: alocações do SDL e
        // geometria do ImGui.
        when LEAK_PROBE {
            if f % 50 == 0 {
                fmt.eprintfln("[leak] frame=%4d sdl_allocs=%8d vtx=%7d idx=%7d",
                    f, sdl2.GetNumAllocations(), io.MetricsRenderVertices, io.MetricsRenderIndices)
            }
        }

        if done do break // acabamos de pintar um frame com TODAS as imagens Ready
        f += 1
        if f >= planned {
            // O que o frame RECÉM-PINTADO viu — tem de ser lido ANTES do poll.
            // Emoji (emoji.odin) rasteriza LOCALMENTE: nasce e fica Ready dentro
            // do mesmo images_poll, então o teste de baixo nunca o via pendente e
            // caía no `break` sem repintar — a página saía com o vão e sem o
            // glifo. Imagem de rede escapava disso só porque demora frames.
            pendente_no_frame := images_pending() || fontface_pending()
            images_poll(renderer)                       // coleta downloads concluídos
            if images_pending() || fontface_pending() {
                had_pending = true
                if f >= planned + IMG_DRAIN_CAP do break // teto: imagens que não chegam
                sdl2.Delay(15)                          // cede tempo de parede aos workers
            } else if had_pending || pendente_no_frame {
                // As imagens coletadas AGORA foram pintadas como placeholder no frame
                // acima (image_get as viu Loading). Pinta MAIS UM frame — todas Ready —
                // e captura. SÓ quando houve pendências: senão (WPT sem imagens) um
                // repaint extra rodaria layout_absolutes 2× e deslocaria abspos.
                done = true
            } else {
                break // nunca houve imagem pendente (ex.: reftest WPT) → 1 paint só
            }
        }
    }
    when ODIN_DEBUG {
        r, l, fa := images_stats()
        fmt.eprintfln("[dreno] frames=%d imagens: %d ready, %d loading, %d failed", f, r, l, fa)
    }

    // ── Lê os pixels do alvo (ABGR8888 → bytes R,G,B,A em little-endian) ─────
    pixels := make([]u8, int(width) * int(height) * 4)
    defer delete(pixels)
    rect := sdl2.Rect{0, 0, width, height}
    if sdl2.RenderReadPixels(renderer, &rect, u32(sdl2.PixelFormatEnum.ABGR8888), raw_data(pixels), width * 4) != 0 {
        fmt.eprintfln("headless: RenderReadPixels falhou: %s", sdl2.GetErrorString())
        return false
    }
    sdl2.SetRenderTarget(renderer, nil)

    // ── Escreve PNG (stb espera R,G,B,A — que é o layout do ABGR8888 em LE) ──
    out_c := strings.clone_to_cstring(out_png, context.temp_allocator)
    // ⚠️ RETRY: o write_png falha TRANSITORIAMENTE no Windows (o stb faz fopen e
    // devolve 0; o antivírus/indexador segura o arquivo recém-criado por alguns ms).
    // Medido: abortou 3 corridas de WPT e produziu 5 falsos `OURS_FAIL` no
    // oracle-diff numa única sessão — ou seja, a flakiness contaminava as DUAS
    // ferramentas de medição. 4 tentativas com espera crescente.
    wrote := false
    for tent in 0 ..< 4 {
        if stbi.write_png(out_c, width, height, 4, raw_data(pixels), width * 4) != 0 { wrote = true; break }
        fmt.eprintfln("headless: write_png falhou (tentativa %d/4) — %s", tent + 1, out_png)
        sdl2.Delay(u32(30 * (tent + 1)))
    }
    if !wrote {
        fmt.eprintln("headless: write_png falhou")
        return false
    }
    return true
}

// ── Dump da árvore de layout (harness de golden-tests, estilo Ladybird) ───────
// browser.exe --dumplayout <entrada.html|URL> <saida.txt> [larg alt]
//
// Parseia + estiliza + faz layout de um ARQUIVO LOCAL ou URL e serializa a árvore
// de caixas (mesma serialização do --diagnose: <tag#id .classe> disp x/w/h, px
// inteiro) para <saida.txt>. É a peça central do layout-golden.ps1: o dump
// commitado é o "esperado"; um diff textual acusa qualquer regressão de layout
// (largura colapsada, caixa que muda de posição, etc.) de forma precisa e
// legível — ao contrário do reftest de pixel, que só diz "difere".
//
// URL (http/https): pipeline de rede COMPLETO (scripts+CSS externos) E **DRENO DE
// IMAGENS** — as imagens são baixadas e o layout é RE-CALCULADO com as dimensões
// reais. Isso permite diagnosticar bugs de DIMENSIONAMENTO de imagem offline (ex.:
// logo SVG que não clampa ao container) sem abrir uma janela: o --dumplayout de
// ARQUIVO local NÃO baixa imagens (relativas sem base) → usa o fallback e esconde
// esses bugs. Com URL, image_dims devolve o tamanho carregado e a caixa é real.
//
// Sem SDL de verdade (janela oculta só p/ criar o renderer + atlas de fontes,
// que a medição de texto exige); sem loop de frame nem pintura.
headless_dumplayout :: proc(in_path: string, out_path: string, width: i32 = 800, height: i32 = 600) -> bool {
    if sdl2.Init(sdl2.INIT_VIDEO) != 0 { fmt.eprintfln("dumplayout: SDL_Init falhou: %s", sdl2.GetErrorString()); return false }
    defer sdl2.Quit()
    window := sdl2.CreateWindow("dumplayout", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, width, height, {.HIDDEN})
    if window == nil { fmt.eprintln("dumplayout: janela falhou"); return false }
    defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window, -1, {.ACCELERATED})
    g_renderer = renderer
    if renderer == nil { fmt.eprintln("dumplayout: renderer falhou"); return false }
    defer sdl2.DestroyRenderer(renderer)
    defer images_free_all() // ANTES do DestroyRenderer (defer roda LIFO): textura e do renderer
    defer emoji_shutdown()  // a fonte de emoji (~12 MB), carregada sob demanda

    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO()
    setup_fonts(io)      // atlas de fontes: métricas de texto dependem dele
    apply_style()
    imgui_sdl2.InitForSDLRenderer(window, renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()

    // Um frame vazio p/ CONSTRUIR o atlas de fontes (imgui_sdlr.NewFrame cria a
    // textura/glyphs). Sem isto, Font_CalcTextSizeA devolve 0 → a medição de
    // texto zera → nada quebra linha e o dump fica errado (tudo em 1 linha).
    io.DisplaySize = {f32(width), f32(height)}
    imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
    im.Render()
    imgui_sdlr.RenderDrawData(im.GetDrawData(), renderer)

    // ── Carrega o HTML: de URL (com rede, igual ao --render) ou de arquivo local ─
    dom: ^dompkg.Node
    page_vm: ^jspkg.Interp
    css_text: string
    base_url := ""
    js_viewport_set(f32(width), f32(height)) // idem headless_render: antes dos <script>
    is_url := strings.has_prefix(in_path, "http://") || strings.has_prefix(in_path, "https://")
    if is_url {
        resp := net.fetch(in_path)
        if !resp.ok { fmt.eprintfln("dumplayout: fetch falhou %s (%s)", in_path, resp.err); return false }
        dom = htmlp.parse_render(resp.body)
        page_vm = load_page_scripts(dom, in_path) // <script> externos+inline em 2 fases
        css_text = collect_page_css(dom, in_path)  // <style> + <link> externos
        base_url = in_path
    } else {
        data, rerr := os.read_entire_file_from_path(in_path, context.allocator)
        if rerr != nil { fmt.eprintfln("dumplayout: nao consegui ler %s", in_path); return false }
        dom = htmlp.parse_render(string(data))
        page_vm = jspkg.load_page(dom)
        css_text = collect_css(dom)
    }
    defer jspkg.vm_free(page_vm)

    rules, kf := csspkg.parse(css_text)
    styles, _ := compute_styles(dom, &rules, f32(width), f32(height), kf[:])
    layout := build_layout(dom, styles, base_url) // ANTES de free_rules: lê slices _raw p/ dentro de rules
    csspkg.free_rules(&rules)
    csspkg.free_keyframes(&kf)
    if layout == nil { fmt.eprintln("dumplayout: layout nil"); return false }

    // ── Dreno de imagens (só URL): baixa tudo ANTES do layout final ─────────────
    // O 1º layout_box chama image_get p/ cada <img>, enfileirando os downloads;
    // images_poll inicia/coleta os workers (e sobe texturas). Quando nada mais está
    // pendente, o layout_box FINAL lê image_dims já carregado → o dump reflete o
    // tamanho REAL das imagens (bugs de sizing aparecem). layout_absolutes roda UMA
    // vez só (não é idempotente: reparenta boxes) DEPOIS do dreno.
    DRAIN_CAP :: 600 // ~9s a 15ms/iter de teto (quebra cedo quando tudo chega)
    if is_url {
        layout_box(layout, 0, 0, f32(width)) // registra as imagens (image_get → Loading)
        images_poll(renderer)
        for iter := 0; images_pending() && iter < DRAIN_CAP; iter += 1 {
            sdl2.Delay(15)
            images_poll(renderer)
        }
    }
    layout_box(layout, 0, 0, f32(width)) // layout final (imagens carregadas se URL)
    page := Rect{0, 0, f32(width), f32(height)} // ICB = viewport (CSS 2.1 §10.1)
    layout_absolutes(layout, page, page) // UMA vez só (reparenta — não repetir)

    sb: strings.Builder
    strings.builder_init(&sb, context.allocator)
    defer strings.builder_destroy(&sb)
    diag_tree(layout, 0, &sb)
    _ = os.write_entire_file(out_path, transmute([]u8)strings.to_string(sb))
    return true
}

// ── Modo --imgdiff a.png b.png ──────────────────────────────────────────────
// Compara dois PNGs (nosso --render vs screenshot do Chrome) e imprime dois
// números: "<diff%> <altura_dif%>". diff% = diferença média de cor no topo comum
// (0=idêntico, 100=oposto); altura_dif% = quão diferentes são as alturas (Chrome
// full-page vs nosso viewport = sinal de conteúdo faltando/JS não rodou). Usado
// pelo oracle-diff.ps1 p/ ranquear as piores páginas por dano visual.
headless_imgdiff :: proc(path_a, path_b: string) -> bool {
    load :: proc(path: string) -> ([^]byte, int, int, bool) {
        data, err := os.read_entire_file_from_path(path, context.allocator)
        if err != nil || len(data) == 0 do return nil, 0, 0, false
        defer delete(data)
        w, h, ch: c.int
        px := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &ch, 4)
        if px == nil do return nil, 0, 0, false
        return px, int(w), int(h), true
    }
    pa, wa, ha, oka := load(path_a)
    if !oka { fmt.eprintln("imgdiff: falha ao ler", path_a); return false }
    defer stbi.image_free(pa)
    pb, wb, hb, okb := load(path_b)
    if !okb { fmt.eprintln("imgdiff: falha ao ler", path_b); return false }
    defer stbi.image_free(pb)

    // downscale ambos p/ largura fixa (média de blocos: tolera ruído/subpixel).
    TW :: 160
    da, dha := imgdiff_downscale(pa, wa, ha, TW)
    db, dhb := imgdiff_downscale(pb, wb, hb, TW)
    H := min(dha, dhb) // compara só o topo comum (acima-da-dobra)
    if H < 1 { fmt.println("100.0 100.0"); return true }
    total := 0
    for i in 0 ..< H * TW {
        for k in 0 ..< 3 {
            d := int(da[i * 3 + k]) - int(db[i * 3 + k])
            total += d < 0 ? -d : d
        }
    }
    score := f64(total) / f64(H * TW * 3) / 255.0 * 100.0
    hdiff := f64(abs(ha - hb)) / f64(max(max(ha, hb), 1)) * 100.0
    // "brancura" da referência (b=Chrome): fração de pixels quase-brancos. Alto
    // (>~95%) = provável página de erro/bloqueio (429/anti-bot) → ref inválida.
    blankb := imgdiff_blankness(db, dhb, TW)
    fmt.printf("%.3f %.1f %.1f\n", score, hdiff, blankb * 100.0)
    return true
}

// fração de pixels quase-brancos (todos os canais >= 244).
imgdiff_blankness :: proc(buf: []u8, h, tw: int) -> f64 {
    if h < 1 do return 1
    white := 0
    for i in 0 ..< h * tw {
        if buf[i * 3] >= 244 && buf[i * 3 + 1] >= 244 && buf[i * 3 + 2] >= 244 do white += 1
    }
    return f64(white) / f64(h * tw)
}

// Média de blocos w×h → tw×th (th mantém o aspecto). Saída RGB packed.
imgdiff_downscale :: proc(px: [^]byte, w, h, tw: int) -> ([]u8, int) {
    th := max(1, h * tw / max(w, 1))
    out := make([]u8, tw * th * 3, context.allocator)
    for oy in 0 ..< th {
        sy0 := oy * h / th; sy1 := max(sy0 + 1, (oy + 1) * h / th)
        for ox in 0 ..< tw {
            sx0 := ox * w / tw; sx1 := max(sx0 + 1, (ox + 1) * w / tw)
            acc: [3]int; cnt := 0
            for sy in sy0 ..< sy1 {
                for sx in sx0 ..< sx1 {
                    idx := (sy * w + sx) * 4
                    acc[0] += int(px[idx]); acc[1] += int(px[idx + 1]); acc[2] += int(px[idx + 2])
                    cnt += 1
                }
            }
            oi := (oy * tw + ox) * 3
            if cnt > 0 { out[oi] = u8(acc[0] / cnt); out[oi + 1] = u8(acc[1] / cnt); out[oi + 2] = u8(acc[2] / cnt) }
        }
    }
    return out, th
}

// browser.exe --woff2test <entrada.woff2> <saida.ttf>
//
// Descomprime e REMONTA um WOFF2, grava o SFNT e imprime um resumo. Existe para
// alimentar `tools/woff2-difftest.py`, que compara o resultado com o do
// fontTools glifo a glifo.
//
// Por que o oráculo é externo: a spec do WOFF2 diz que a reconstrução preserva a
// FUNCIONALIDADE, não os bytes — o mesmo contorno tem várias codificações
// válidas e a spec PROÍBE rejeitar a fonte porque o tamanho mudou. Então não
// existe comparação byte a byte possível, e o que tem de bater é o conteúdo
// semântico: contornos, coordenadas absolutas, quais pontos estão sobre a
// curva, instruções, caixas e métricas.
headless_woff2test :: proc(in_path, out_path: string) -> bool {
    // ⚠️ neste `core:os` a leitura devolve ERRO, não bool, e é a variante
    // `_from_path` que aceita string (é o que o resto do arquivo já usa).
    src, rerr := os.read_entire_file_from_path(in_path, context.allocator)
    if rerr != nil {
        fmt.eprintfln("não deu para ler %s: %v", in_path, rerr)
        return false
    }
    defer delete(src)

    sfnt, err := woff2pkg.to_sfnt(src)
    if err != .None {
        fmt.eprintfln("woff2: %v", err)
        return false
    }
    defer delete(sfnt)

    // A MESMA triagem que a rede usa. Se a fonte remontada não passa por aqui,
    // ela não seria carregada de todo jeito — e o `--woff2test` mentiria.
    if !sfnt_usable(sfnt) {
        fmt.eprintln("a fonte remontada não passa no sfnt_usable")
        return false
    }
    if werr := os.write_entire_file(out_path, sfnt); werr != nil {
        fmt.eprintfln("não deu para escrever %s: %v", out_path, werr)
        return false
    }
    ntabs := int(u32(sfnt[4]) << 8 | u32(sfnt[5]))
    fmt.printfln("woff2 %d bytes -> sfnt %d bytes, %d tabelas", len(src), len(sfnt), ntabs)
    return true
}

// browser.exe --brotlitest <manifesto.txt>
//
// O manifesto tem uma linha por caso:
//     nome <TAB> caminho.br <TAB> caminho.raw <TAB> tamanho_esperado
//
// Para cada um, descomprime e exige igualdade byte a byte. Os pares vêm de
// `tools/brotli-difftest.py`, que os produz com o brotli de REFERÊNCIA variando
// qualidade e janela — é o que faz o codificador usar caminhos diferentes do
// formato (janelas grandes, códigos de prefixo simples, muitas árvores) em vez
// de só "dados variados".
//
// Manifesto em vez de listar a pasta de propósito: quem gerou os casos DIZ
// quantos são, e uma pasta vazia ou um filtro errado apareceria como "passou
// tudo" em vez de "não testou nada".
//
// Os vetores fixos ficam em `src/brotli/testdata` e rodam no `odin test`; isto
// aqui é o volume, que não caberia no repositório.
headless_brotlitest :: proc(manifest: string) -> bool {
    man, merr := os.read_entire_file_from_path(manifest, context.allocator)
    if merr != nil {
        fmt.eprintfln("não deu para ler o manifesto %s: %v", manifest, merr)
        return false
    }
    defer delete(man)

    ok_n, bad_n := 0, 0
    for linha in strings.split_lines(string(man), context.temp_allocator) {
        l := strings.trim_space(linha)
        if l == "" do continue
        campos := strings.split(l, "\t", context.temp_allocator)
        if len(campos) != 4 {
            fmt.printfln("BAD  linha do manifesto com %d campos: %q", len(campos), l)
            bad_n += 1
            continue
        }
        base := campos[0]
        // tamanho esperado, parseado à mão p/ não puxar core:strconv aqui
        esperado, nd := 0, 0
        for ch in campos[3] {
            if ch < '0' || ch > '9' do break
            esperado = esperado * 10 + int(ch - '0')
            nd += 1
        }
        if nd == 0 || nd != len(campos[3]) {
            fmt.printfln("BAD  %-28s tamanho esperado ilegível: %q", base, campos[3])
            bad_n += 1
            continue
        }
        br, err1 := os.read_entire_file_from_path(campos[1], context.allocator)
        raw, _ := os.read_entire_file_from_path(campos[2], context.allocator) // 0 bytes pode voltar como falha
        defer delete(br)
        defer delete(raw)
        if err1 != nil {
            fmt.printfln("BAD  %-28s não deu para ler o .br", base)
            bad_n += 1
            continue
        }
        // Isto é o que distingue "arquivo de 0 bytes" de "arquivo que não
        // existe": sem o tamanho vindo do manifesto, um .raw faltando passaria
        // como "esperava saída vazia".
        if len(raw) != esperado {
            fmt.printfln("BAD  %-28s o .raw tem %d bytes, o manifesto diz %d",
                base, len(raw), esperado)
            bad_n += 1
            continue
        }
        got, err := brotlipkg.decode(br, len(raw) + 1)
        defer delete(got)
        switch {
        case err != .None:
            fmt.printfln("BAD  %-28s decode devolveu %v", base, err)
            bad_n += 1
        case len(got) != len(raw):
            fmt.printfln("BAD  %-28s saiu com %d bytes, esperava %d", base, len(got), len(raw))
            bad_n += 1
        case:
            diff := -1
            for i in 0 ..< len(got) do if got[i] != raw[i] {
                diff = i
                break
            }
            if diff >= 0 {
                fmt.printfln("BAD  %-28s difere no byte %d (0x%02x, esperava 0x%02x)",
                    base, diff, got[diff], raw[diff])
                bad_n += 1
            } else {
                ok_n += 1
            }
        }
    }
    fmt.printfln("TOTAL: %d OK, %d BAD", ok_n, bad_n)
    return bad_n == 0 && ok_n > 0
}
