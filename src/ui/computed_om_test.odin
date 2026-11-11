package ui

// M199 (getComputedStyle) + M200 (geometria) — ver computed_om.odin.
//
// Dois níveis de teste, de propósito:
//  1. `js_computed_style` / `js_element_rect` / `js_element_metric` direto — a
//     serialização e a matemática de coordenadas, propriedade a propriedade;
//  2. pela API do JS (`getComputedStyle(el).x`, `el.getBoundingClientRect()`) —
//     cobre a normalização de camelCase, o `getPropertyValue` e o DOMRect, que
//     moram no lado js.
//
// ⚠️ A fonte (g_js_styles/g_js_layout) é ESTADO GLOBAL do pacote: todo teste daqui
// seta e LIMPA (defer). O test.ps1 já roda src/ui com ODIN_TEST_THREADS=1 — foi a
// lição do M192, quando estado global + runner paralelo gerou teste intermitente.

import "core:testing"
import "core:fmt"
import "core:strings"
import htmlp "../html"
import csspkg "../css"
import jspkg "../js"
import dompkg "../dom"

@(private = "file")
Cena :: struct {
    dom:    ^dompkg.Node,
    styles: map[^dompkg.Node]Computed,
    layout: ^Box,
    rules:  [dynamic]csspkg.Rule,
    kf:     [dynamic]csspkg.Keyframe_Set,
    vm:     ^jspkg.Interp,
}

// Monta DOM + estilo + layout e liga a fonte do getComputedStyle, como um frame real.
@(private = "file")
montar :: proc(html: string, vw: f32 = 800, vh: f32 = 600, com_js := false) -> Cena {
    c := Cena{}
    c.dom = htmlp.parse(html)
    htmlp.normalize_document(c.dom)
    if com_js do c.vm = jspkg.load_page(c.dom)
    css := collect_css(c.dom)
    c.rules, c.kf = csspkg.parse(css)
    c.styles, _ = compute_styles(c.dom, &c.rules, vw, vh, c.kf[:])
    c.layout = build_layout(c.dom, c.styles, "")
    js_style_source_set(c.styles, c.layout, vw, vh)
    return c
}

@(private = "file")
desmontar :: proc(c: ^Cena) {
    js_style_source_free() // _free e não _clear: devolve o índice nó→caixa, senão
                           // o rastreador de alocação do runner o acusa por teste
    if c.vm != nil do jspkg.vm_free(c.vm)
    if c.layout != nil do free_layout(c.layout)
    free_styles(c.styles)
    csspkg.free_rules(&c.rules)
    csspkg.free_keyframes(&c.kf)
    // DOM por último: a vm referencia nós (o vm_free acima roda o dom_cleanup) e o
    // Computed guarda fatias `_raw` p/ dentro das rules.
    if c.dom != nil do dompkg.free_tree(c.dom)
}

@(private = "file")
por_id :: proc(n: ^dompkg.Node, id: string) -> ^dompkg.Node {
    if n == nil do return nil
    if n.kind == .Element {
        if v, ok := n.attrs["id"]; ok && v == id do return n
    }
    for ch in n.children {
        if r := por_id(ch, id); r != nil do return r
    }
    return nil
}

@(private = "file")
eq :: proc(t: ^testing.T, got, want, quem: string) {
    testing.expectf(t, got == want, "%s: esperava %q, veio %q", quem, want, got)
}

// ── 1. Serialização, propriedade a propriedade ──────────────────────────────

@(test)
test_gcs_display :: proc(t: ^testing.T) {
    c := montar(`<style>
        #f{display:flex} #g{display:grid} #n{display:none} #ib{display:inline-block}
        #forcado{display:block}
    </style><body>
        <div id="d">d</div><span id="s">s</span><span id="forcado">f</span>
        <div id="f"></div><div id="g"></div><div id="n"></div><div id="ib"></div>
        <ul><li id="li">i</li></ul>
    </body>`)
    defer desmontar(&c)
    eq(t, js_computed_style(por_id(c.dom, "d"), "display"), "block", "div sem CSS")
    eq(t, js_computed_style(por_id(c.dom, "s"), "display"), "inline", "span sem CSS")
    eq(t, js_computed_style(por_id(c.dom, "forcado"), "display"), "block", "span com display:block")
    eq(t, js_computed_style(por_id(c.dom, "f"), "display"), "flex", "flex")
    eq(t, js_computed_style(por_id(c.dom, "g"), "display"), "grid", "grid")
    eq(t, js_computed_style(por_id(c.dom, "n"), "display"), "none", "none")
    eq(t, js_computed_style(por_id(c.dom, "ib"), "display"), "inline-block", "inline-block")
    eq(t, js_computed_style(por_id(c.dom, "li"), "display"), "list-item", "li")
}

@(test)
test_gcs_cor :: proc(t: ^testing.T) {
    c := montar(`<style>
        #a{color:rgb(1,2,3);background:#ff0000}
        #b{color:rgba(10,20,30,0.5)}
        #c{background:transparent}
    </style><body><p id="a">a</p><p id="b">b</p><p id="c">c</p></body>`)
    defer desmontar(&c)
    eq(t, js_computed_style(por_id(c.dom, "a"), "color"), "rgb(1, 2, 3)", "color opaca")
    eq(t, js_computed_style(por_id(c.dom, "a"), "background-color"), "rgb(255, 0, 0)", "bg opaca")
    // sem background declarado o navegador devolve o transparente, não ""
    eq(t, js_computed_style(por_id(c.dom, "b"), "background-color"), "rgba(0, 0, 0, 0)", "sem bg")
    got := js_computed_style(por_id(c.dom, "b"), "color")
    testing.expectf(t, strings.has_prefix(got, "rgba(10, 20, 30, 0.5"), "cor com alpha: veio %q", got)
}

@(test)
test_gcs_texto :: proc(t: ^testing.T) {
    c := montar(`<style>
        #a{font-size:20px;line-height:1.5;font-weight:bold;font-style:italic;
           text-align:center;text-transform:uppercase;letter-spacing:2px;
           font-family:Georgia,serif;text-decoration:underline}
    </style><body><p id="a">a</p><p id="b">b</p></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    eq(t, js_computed_style(a, "font-size"), "20px", "font-size")
    // line-height sai em px (valor USADO), como no navegador: 20 * 1.5
    eq(t, js_computed_style(a, "line-height"), "30px", "line-height usado")
    eq(t, js_computed_style(a, "font-weight"), "700", "font-weight")
    eq(t, js_computed_style(a, "font-style"), "italic", "font-style")
    eq(t, js_computed_style(a, "text-align"), "center", "text-align")
    eq(t, js_computed_style(a, "text-transform"), "uppercase", "text-transform")
    eq(t, js_computed_style(a, "letter-spacing"), "2px", "letter-spacing")
    eq(t, js_computed_style(a, "font-family"), "serif", "font-family (degradação #3: genérica)")
    eq(t, js_computed_style(a, "text-decoration-line"), "underline", "text-decoration-line")
    // herdadas/normais no irmão sem CSS
    b := por_id(c.dom, "b")
    eq(t, js_computed_style(b, "letter-spacing"), "normal", "letter-spacing default")
    eq(t, js_computed_style(b, "font-weight"), "400", "font-weight default")
}

@(test)
test_gcs_caixa :: proc(t: ^testing.T) {
    c := montar(`<style>
        #a{width:300px;height:50px;padding:5px;margin:7px;border:2px solid red}
        #b{width:300px;box-sizing:border-box;padding:5px;border:2px solid red}
    </style><body><div id="a">a</div><div id="b">b</div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    // content-box: `width` é a caixa de CONTEÚDO
    eq(t, js_computed_style(a, "width"), "300px", "width content-box")
    eq(t, js_computed_style(a, "height"), "50px", "height content-box")
    eq(t, js_computed_style(a, "margin-top"), "7px", "margin-top")
    eq(t, js_computed_style(a, "margin-left"), "7px", "margin-left")
    eq(t, js_computed_style(a, "padding-bottom"), "5px", "padding-bottom")
    eq(t, js_computed_style(a, "border-top-width"), "2px", "border-top-width")
    eq(t, js_computed_style(a, "border-top-color"), "rgb(255, 0, 0)", "border-top-color")
    eq(t, js_computed_style(a, "border-top-style"), "solid", "border-top-style")
    eq(t, js_computed_style(a, "box-sizing"), "content-box", "box-sizing")
    // border-box: `width` é a caixa de BORDA (inclui padding+borda)
    b := por_id(c.dom, "b")
    eq(t, js_computed_style(b, "box-sizing"), "border-box", "box-sizing border")
    eq(t, js_computed_style(b, "width"), "300px", "width border-box")
}

@(test)
test_gcs_posicao_e_flex :: proc(t: ^testing.T) {
    c := montar(`<style>
        #a{position:absolute;top:10px;left:20px;z-index:5;opacity:0.5}
        #f{display:flex;flex-direction:column;justify-content:space-between;
           align-items:center;gap:12px;flex-wrap:wrap}
        #i{flex-grow:2;order:3}
    </style><body><div id="a">a</div><div id="f"><div id="i">i</div></div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    eq(t, js_computed_style(a, "position"), "absolute", "position")
    eq(t, js_computed_style(a, "top"), "10px", "top")
    eq(t, js_computed_style(a, "left"), "20px", "left")
    eq(t, js_computed_style(a, "right"), "auto", "right não definido")
    eq(t, js_computed_style(a, "z-index"), "5", "z-index")
    eq(t, js_computed_style(a, "opacity"), "0.5", "opacity")
    f := por_id(c.dom, "f")
    eq(t, js_computed_style(f, "flex-direction"), "column", "flex-direction")
    eq(t, js_computed_style(f, "justify-content"), "space-between", "justify-content")
    eq(t, js_computed_style(f, "align-items"), "center", "align-items")
    eq(t, js_computed_style(f, "gap"), "12px", "gap")
    eq(t, js_computed_style(f, "flex-wrap"), "wrap", "flex-wrap")
    i := por_id(c.dom, "i")
    eq(t, js_computed_style(i, "flex-grow"), "2", "flex-grow")
    eq(t, js_computed_style(i, "order"), "3", "order")
}

// ── 2. As degradações, NOMEADAS (o teste diz qual é) ────────────────────────

@(test)
test_gcs_degradacao_sem_fonte :: proc(t: ^testing.T) {
    // Degradação #1: antes do 1º compute_styles não há o que ler. É a janela em
    // que os <script> de carga rodam — devolve "" em vez de inventar.
    dom := htmlp.parse(`<body><div id="a" style="color:red">a</div></body>`)
    htmlp.normalize_document(dom)
    defer dompkg.free_tree(dom)
    js_style_source_clear()
    eq(t, js_computed_style(por_id(dom, "a"), "color"), "", "sem fonte de estilo")
}

// scroll-padding-top: a única prop que uma leitura de SITE REAL pediu (sonda
// -define:GCSPROBE, <html> da Wikipedia) e que caía na degradação #2.
@(test)
test_gcs_scroll_padding :: proc(t: ^testing.T) {
    c := montar(`<style>html{scroll-padding-top:64px}</style><body><div id="a">a</div></body>`)
    defer desmontar(&c)
    html := dompkg.find_first(c.dom, "html")
    testing.expect(t, html != nil, "achou <html>")
    if html == nil do return
    eq(t, js_computed_style(html, "scroll-padding-top"), "64px", "scroll-padding-top")
    // sem declaração o navegador devolve `auto`, não 0px
    eq(t, js_computed_style(por_id(c.dom, "a"), "scroll-padding-top"), "auto", "sem declaração")
}

@(test)
test_gcs_degradacao_prop_nao_mapeada :: proc(t: ^testing.T) {
    // Degradação #2: prop fora do switch devolve "" (não lança, não inventa).
    c := montar(`<style>#a{color:red;background-image:url(x.png)}</style><body><div id="a">a</div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    eq(t, js_computed_style(a, "color"), "rgb(255, 0, 0)", "prop mapeada responde")
    eq(t, js_computed_style(a, "background-image"), "", "prop NÃO mapeada")
    eq(t, js_computed_style(a, "quero-uma-prop-que-nao-existe"), "", "prop inexistente")
}

@(test)
test_gcs_no_fora_do_mapa :: proc(t: ^testing.T) {
    // Nó que não está no mapa de estilos (ex.: criado pelo JS e ainda não
    // estilizado) devolve "" em vez de ler lixo.
    c := montar(`<body><div id="a">a</div></body>`)
    defer desmontar(&c)
    solto := dompkg.make_node(.Element)
    solto.tag = "div"
    defer dompkg.free_tree(solto)
    eq(t, js_computed_style(solto, "display"), "", "nó fora do mapa")
    eq(t, js_computed_style(nil, "display"), "", "nó nil")
}

// ── 3. Pela API do JS (camelCase + getPropertyValue) ────────────────────────

@(private = "file")
js_str :: proc(t: ^testing.T, vm: ^jspkg.Interp, src: string) -> string {
    v := jspkg.vm_run(vm, src)
    s, ok := v.(string)
    if !ok {
        testing.expectf(t, false, "%s: não devolveu string (veio %v)", src, v)
        return ""
    }
    return s
}

@(test)
test_gcs_api_js :: proc(t: ^testing.T) {
    c := montar(`<style>
        #a{display:flex;color:rgb(9,8,7);font-size:20px;margin-top:4px;width:200px}
    </style><body><div id="a">a</div></body>`, 800, 600, com_js = true)
    defer desmontar(&c)
    testing.expect(t, c.vm != nil, "vm criada")
    if c.vm == nil do return

    // kebab-case pelo getPropertyValue
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).getPropertyValue('font-size')`),
       "20px", "getPropertyValue kebab")
    // camelCase pelo acesso a propriedade (a forma que código real usa)
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).fontSize`),
       "20px", "acesso camelCase")
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).marginTop`),
       "4px", "camelCase composto")
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).display`),
       "flex", "display pela API")
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).color`),
       "rgb(9, 8, 7)", "color pela API")
    // width vem do LAYOUT: exercita o flush síncrono do box_of (o JS de teste roda
    // sem nenhum layout_box anterior, igual ao 1º pump de um frame real)
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).width`),
       "200px", "width pela API (flush de layout)")
    // a declaração é read-only no navegador: setProperty não pode mudar a leitura
    eq(t, js_str(t, c.vm, `(function(){ var s = getComputedStyle(document.getElementById('a'));
                                        s.setProperty('color','lime'); return s.color })()`),
       "rgb(9, 8, 7)", "setProperty é no-op (computed é read-only)")
    // prop não mapeada continua "" — falsy, como o stub antigo: código que testa
    // `if (cs.x)` segue funcionando
    eq(t, js_str(t, c.vm, `getComputedStyle(document.getElementById('a')).backgroundImage`),
       "", "não mapeada pela API")
}

@(test)
test_gcs_api_js_elemento_invalido :: proc(t: ^testing.T) {
    c := montar(`<body><div id="a">a</div></body>`, 800, 600, com_js = true)
    defer desmontar(&c)
    if c.vm == nil { testing.expect(t, false, "vm criada"); return }
    // getComputedStyle(null) não pode CRASHAR nem lançar: devolve declaração vazia
    eq(t, js_str(t, c.vm, `getComputedStyle(null).display`), "", "getComputedStyle(null)")
    eq(t, js_str(t, c.vm, `getComputedStyle().display`), "", "getComputedStyle() sem arg")
    v := jspkg.vm_run(c.vm, `typeof getComputedStyle(document.getElementById('a'))`)
    s, _ := v.(string)
    eq(t, s, "object", "devolve objeto")
}

// Sanidade do formato de número: sem zeros à direita, como o CSSOM.
@(test)
test_gcs_formato_numero :: proc(t: ^testing.T) {
    c := montar(`<style>#a{font-size:12.5px;opacity:0.25;letter-spacing:1.5px}</style>
                 <body><div id="a">a</div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    eq(t, js_computed_style(a, "font-size"), "12.5px", "fracionário sem zeros à direita")
    eq(t, js_computed_style(a, "opacity"), "0.25", "opacity fracionária")
    eq(t, js_computed_style(a, "letter-spacing"), "1.5px", "letter-spacing fracionário")
    _ = fmt.tprintf("") // mantém o import de fmt (usado pelo expectf acima)
}

// ── 4. GEOMETRIA (M200): getBoundingClientRect e a família offset*/client* ───

@(private = "file")
rect_of :: proc(n: ^dompkg.Node) -> (x, y, w, h: f32, ok: bool) {
    return js_element_rect(n)
}

@(test)
test_rect_caixa_de_borda :: proc(t: ^testing.T) {
    // 300 de conteúdo + 5 de padding dos dois lados + 2 de borda dos dois = 314.
    c := montar(`<style>body{margin:0}
        #a{width:300px;height:50px;margin:10px;padding:5px;border:2px solid red}
    </style><body><div id="a">A</div></body>`)
    defer desmontar(&c)
    x, y, w, h, ok := rect_of(por_id(c.dom, "a"))
    testing.expect(t, ok, "achou caixa")
    testing.expectf(t, w == 314, "width: esperava 314 (border box), veio %v", w)
    testing.expectf(t, h == 64,  "height: esperava 64, veio %v", h)
    testing.expectf(t, x == 10 && y == 10, "origem: esperava (10,10), veio (%v,%v)", x, y)
}

@(test)
test_rect_relativo_ao_viewport :: proc(t: ^testing.T) {
    // O rect é do VIEWPORT: rolar a página muda `top`, mas não `offsetTop`.
    // E o idioma "posição no documento" (rect.top + scrollY) tem de fechar.
    c := montar(`<style>body{margin:0}#pad{height:900px}#a{height:40px}</style>
                 <body><div id="pad"></div><div id="a">A</div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    _, y0, _, _, _ := rect_of(a)
    testing.expectf(t, y0 == 900, "sem scroll: esperava top=900, veio %v", y0)

    js_scroll_set(0, 300)
    _, y1, _, _, _ := rect_of(a)
    testing.expectf(t, y1 == 600, "com scroll 300: esperava top=600, veio %v", y1)

    off, ok := js_element_metric(a, "offsetTop")
    testing.expect(t, ok, "offsetTop existe")
    testing.expectf(t, off == 900, "offsetTop é do DOCUMENTO: esperava 900, veio %v", off)
    testing.expectf(t, y1 + 300 == off, "invariante rect.top+scrollY==offsetTop: %v+300 != %v", y1, off)
}

@(test)
test_rect_display_none_zera :: proc(t: ^testing.T) {
    // Elemento sem caixa: o navegador devolve tudo 0 (não a largura declarada).
    c := montar(`<style>#n{display:none;width:99px;height:99px}</style>
                 <body><div id="n">N</div></body>`)
    defer desmontar(&c)
    _, _, w, h, ok := rect_of(por_id(c.dom, "n"))
    testing.expect(t, !ok, "display:none não tem caixa")
    testing.expectf(t, w == 0 && h == 0, "esperava 0x0, veio %vx%v", w, h)
    v, mok := js_element_metric(por_id(c.dom, "n"), "offsetWidth")
    testing.expect(t, !mok || v == 0, "offsetWidth de display:none é 0")
}

@(test)
test_metricas_offset_client :: proc(t: ^testing.T) {
    c := montar(`<style>body{margin:0}
        #a{width:300px;height:50px;padding:5px;border:2px solid red}
    </style><body><div id="a">A</div></body>`)
    defer desmontar(&c)
    a := por_id(c.dom, "a")
    ow, _ := js_element_metric(a, "offsetWidth")
    oh, _ := js_element_metric(a, "offsetHeight")
    cw, _ := js_element_metric(a, "clientWidth")
    ch, _ := js_element_metric(a, "clientHeight")
    testing.expectf(t, ow == 314 && oh == 64, "offset: esperava 314x64, veio %vx%v", ow, oh)
    // client = caixa de PADDING (border box menos as bordas)
    testing.expectf(t, cw == 310 && ch == 60, "client: esperava 310x60, veio %vx%v", cw, ch)
}

@(test)
test_metricas_viewport_e_documento :: proc(t: ^testing.T) {
    c := montar(`<style>body{margin:0}#a{height:1500px}</style><body><div id="a">A</div></body>`, 800, 600)
    defer desmontar(&c)
    html := dompkg.find_first(c.dom, "html")
    testing.expect(t, html != nil, "achou <html>")
    if html == nil do return
    // documentElement.clientWidth/Height É o viewport, por spec
    cw, _ := js_element_metric(html, "clientWidth")
    ch, _ := js_element_metric(html, "clientHeight")
    testing.expectf(t, cw == 800 && ch == 600, "viewport: esperava 800x600, veio %vx%v", cw, ch)
    // scrollHeight de html/body = altura do DOCUMENTO (o "carregar mais no fim")
    body := dompkg.find_first(c.dom, "body")
    if body != nil {
        sh, ok := js_element_metric(body, "scrollHeight")
        testing.expect(t, ok, "body.scrollHeight existe")
        testing.expectf(t, sh >= 1500, "doc: esperava >=1500, veio %v", sh)
    }
}

@(test)
test_metricas_container_rolavel :: proc(t: ^testing.T) {
    c := montar(`<style>body{margin:0}#sc{height:60px;overflow:auto}#sc>div{height:500px}</style>
                 <body><div id="sc"><div>tall</div></div></body>`)
    defer desmontar(&c)
    sc := por_id(c.dom, "sc")
    ch, _ := js_element_metric(sc, "clientHeight")
    sh, _ := js_element_metric(sc, "scrollHeight")
    testing.expectf(t, ch == 60, "clientHeight: esperava 60, veio %v", ch)
    testing.expectf(t, sh >= 500, "scrollHeight tem de ver o conteúdo: esperava >=500, veio %v", sh)
    st, ok := js_element_metric(sc, "scrollTop")
    testing.expect(t, ok, "scrollTop existe (era undefined antes)")
    testing.expectf(t, st == 0, "scrollTop inicial 0, veio %v", st)
}

@(test)
test_geometria_sem_fonte :: proc(t: ^testing.T) {
    // Mesma degradação #1 do estilo: na janela de carga não há layout.
    dom := htmlp.parse(`<body><div id="a">a</div></body>`)
    htmlp.normalize_document(dom)
    defer dompkg.free_tree(dom)
    js_style_source_clear()
    _, _, w, _, ok := rect_of(por_id(dom, "a"))
    testing.expect(t, !ok && w == 0, "sem layout: rect zerado")
    _, mok := js_element_metric(por_id(dom, "a"), "offsetWidth")
    testing.expect(t, !mok, "sem layout: métrica indisponível")
}

@(test)
test_geometria_api_js :: proc(t: ^testing.T) {
    c := montar(`<style>body{margin:0}#a{width:200px;height:40px;border:1px solid red}</style>
                 <body><div id="a">A</div></body>`, 800, 600, com_js = true)
    defer desmontar(&c)
    if c.vm == nil { testing.expect(t, false, "vm criada"); return }
    eq(t, js_str(t, c.vm, `String(document.getElementById('a').getBoundingClientRect().width)`),
       "202", "rect.width pela API")
    eq(t, js_str(t, c.vm, `String(document.getElementById('a').getBoundingClientRect().bottom)`),
       "42", "rect.bottom = top+height")
    eq(t, js_str(t, c.vm, `String(document.getElementById('a').offsetWidth)`), "202", "offsetWidth pela API")
    eq(t, js_str(t, c.vm, `String(document.getElementById('a').getClientRects().length)`), "1", "getClientRects")
    eq(t, js_str(t, c.vm, `String(window.scrollY) + "/" + String(window.pageYOffset)`), "0/0", "window.scrollY")
    // rect de nó SEM caixa não pode lançar
    eq(t, js_str(t, c.vm, `String(document.createElement('div').getBoundingClientRect().width)`),
       "0", "elemento solto devolve 0")
}

@(test)
test_scrollheight_conta_fora_de_fluxo :: proc(t: ^testing.T) {
    // `root.h` é a altura EM FLUXO e mente com conteúdo absolute/fixed — foi o que
    // fez o gap-miner classificar site renderizado como BLANK. O scrollHeight da
    // raiz usa box_max_extent, que enxerga as caixas fora de fluxo.
    c := montar(`<style>body{margin:0}
        #flow{height:100px}
        #abs{position:absolute;top:1200px;height:50px;width:10px}
    </style><body><div id="flow"></div><div id="abs"></div></body>`, 800, 600)
    defer desmontar(&c)
    body := dompkg.find_first(c.dom, "body")
    testing.expect(t, body != nil, "achou <body>")
    if body == nil do return
    sh, ok := js_element_metric(body, "scrollHeight")
    testing.expect(t, ok, "scrollHeight existe")
    testing.expectf(t, sh >= 1250, "esperava >=1250 (o absoluto em top:1200), veio %v", sh)
}

@(test)
test_scrolltop_da_raiz_e_o_scroll_da_pagina :: proc(t: ^testing.T) {
    // Metade do idioma `window.pageYOffset || document.documentElement.scrollTop`.
    // A Box da raiz não sabe do scroll da página (ele vive no container da UI).
    c := montar(`<style>body{margin:0}#a{height:2000px}</style><body><div id="a"></div></body>`)
    defer desmontar(&c)
    html := dompkg.find_first(c.dom, "html")
    if html == nil { testing.expect(t, false, "achou <html>"); return }
    v0, _ := js_element_metric(html, "scrollTop")
    testing.expectf(t, v0 == 0, "sem scroll: esperava 0, veio %v", v0)
    js_scroll_set(0, 250)
    v1, ok := js_element_metric(html, "scrollTop")
    testing.expect(t, ok, "scrollTop existe")
    testing.expectf(t, v1 == 250, "com scroll: esperava 250, veio %v", v1)
}

@(test)
test_rect_fixed_nao_rola :: proc(t: ^testing.T) {
    // `position:fixed` é pinado ao VIEWPORT: o rect NÃO pode mudar ao rolar.
    // ⚠️ a compensação do fixed mora no PAINT (`oy += GetScrollY()`), não na Box —
    // ler b.y e subtrair o scroll dava subtração DUPLA (cabeçalho fixo reportando
    // posição negativa ao rolar).
    c := montar(`<style>body{margin:0}#fix{position:fixed;top:30px;left:40px;width:100px;height:20px}
                 #pad{height:2000px}</style>
                 <body><div id="fix">F</div><div id="pad"></div></body>`)
    defer desmontar(&c)
    fix := por_id(c.dom, "fix")
    x0, y0, _, _, ok := rect_of(fix)
    testing.expect(t, ok, "achou caixa do fixed")
    testing.expectf(t, y0 == 30 && x0 == 40, "sem scroll: esperava (40,30), veio (%v,%v)", x0, y0)
    js_scroll_set(0, 500)
    x1, y1, _, _, _ := rect_of(fix)
    testing.expectf(t, y1 == 30 && x1 == 40, "com scroll 500 o fixed NÃO se move: veio (%v,%v)", x1, y1)
}

@(test)
test_rect_herda_offset_de_ancestral_relativo :: proc(t: ^testing.T) {
    // O deslocamento de position:relative/transform é acumulado pelo PAINT descendo
    // a árvore (`ox2 := ox + b.rel_dx`) e NÃO está em b.x/b.y — quem lê a caixa
    // isolada erra a posição de todo descendente de um elemento relativo.
    c := montar(`<style>body{margin:0}
        #outer{position:relative;top:100px;left:20px}
        #inner{width:30px;height:10px}
        #tr{transform:translate(10px,20px);width:50px;height:10px}
    </style><body><div id="outer"><div id="inner">I</div></div><div id="tr">T</div></body>`)
    defer desmontar(&c)
    x, y, _, _, ok := rect_of(por_id(c.dom, "inner"))
    testing.expect(t, ok, "achou caixa interna")
    testing.expectf(t, y == 100 && x == 20, "o filho herda o offset do ancestral relativo: esperava (20,100), veio (%v,%v)", x, y)
    // transform entra no mesmo acumulador: #tr fica após #inner (10px de altura)
    tx, ty, _, _, _ := rect_of(por_id(c.dom, "tr"))
    testing.expectf(t, tx == 10 && ty == 30, "transform translate: esperava (10,30), veio (%v,%v)", tx, ty)
}

@(test)
test_gcs_resize :: proc(t: ^testing.T) {
    // O valor COMPUTADO é o DECLARADO: a aplicabilidade (overflow ≠ visible) é
    // decidida no uso, não na cascata — o Chrome também devolve "both" para uma
    // <div> com overflow:visible.
    c := montar(`<style>
        #b{resize:both;overflow:auto} #v{resize:vertical;overflow:auto}
        #i{resize:inline;overflow:auto} #vis{resize:both}
    </style><body>
        <div id="d"></div><div id="b"></div><div id="v"></div><div id="i"></div>
        <div id="vis"></div><textarea id="ta"></textarea>
    </body>`)
    defer desmontar(&c)
    eq(t, js_computed_style(por_id(c.dom, "d"),   "resize"), "none",       "div sem CSS")
    eq(t, js_computed_style(por_id(c.dom, "b"),   "resize"), "both",       "resize:both")
    eq(t, js_computed_style(por_id(c.dom, "v"),   "resize"), "vertical",   "resize:vertical")
    eq(t, js_computed_style(por_id(c.dom, "i"),   "resize"), "horizontal", "resize:inline ≡ horizontal")
    eq(t, js_computed_style(por_id(c.dom, "vis"), "resize"), "both",       "declarado vale mesmo sem se aplicar")
    eq(t, js_computed_style(por_id(c.dom, "ta"),  "resize"), "both",       "<textarea> herda o default da UA")
}

// ── M232: a ponte do window.matchMedia ──────────────────────────────────────
// A mecânica do MediaQueryList (objeto vivo, evento 'change') é testada no
// src/js com um avaliador falso. O que só o ui pode afirmar é a LIGAÇÃO: a query
// crua do JS chega ao MESMO motor do @media, com o MESMO viewport. Se estes dois
// lados divergissem, a página teria uma resposta no CSS e outra no JS.
@(test)
test_media_query_ponte_js :: proc(t: ^testing.T) {
    js_viewport_set(1000, 800) // thread_local: não conflita com o runner paralelo
    defer js_style_source_clear()
    testing.expect(t, js_media_matches("(min-width: 600px)"),  "1000px casa min-width:600")
    testing.expect(t, !js_media_matches("(min-width: 1200px)"), "1000px NÃO casa min-width:1200")
    testing.expect(t, js_media_matches("screen and (max-width: 1100px)"), "tipo screen + max-width")
    testing.expect(t, !js_media_matches("print"), "não somos mídia de impressão")
    testing.expect(t, js_media_matches("(width >= 40rem)"), "sintaxe de FAIXA (MQ4), 640px <= 1000")
    // Lista de media VAZIA é inválida ⇒ `not all` ⇒ não casa. ⚠️ é o oposto do
    // prelúdio vazio de um @media (que casa sempre), e os dois usam o mesmo parser.
    testing.expect(t, !js_media_matches(""), "query vazia não casa")
    // Feature que não modelamos ⇒ desconhecida ⇒ não casa (é o que o Chrome
    // devolve para `reduce` numa máquina sem a preferência ligada).
    testing.expect(t, !js_media_matches("(prefers-reduced-motion: reduce)"), "preferência não modelada")
}

@(test)
test_inline_fragments_nested_images_and_scroll :: proc(t:^testing.T) {
    c:=montar(`<style>body{margin:0}#outer{position:absolute;left:50px;top:40px;width:100px;transform:scale(2);transform-origin:0 0}img{width:20px;height:10px}</style><div id="outer"><span id="a"><span id="b"><img><br><img></span></span><span id="hidden" style="display:none">none</span></div>`,800,600,true)
    defer desmontar(&c)
    a,b:=por_id(c.dom,"a"),por_id(c.dom,"b")
    x0,y0,w0,h0,ok:=js_element_fragment(a,0)
    testing.expect(t,ok && w0==40 && h0==20)
    x1,y1,w1,h1,ok1:=js_element_fragment(a,1)
    testing.expect(t,ok1 && x1==x0 && y1>y0 && w1==40 && h1==20)
    _,_,_,_,end:=js_element_fragment(a,2)
    testing.expect(t,!end)
    x,y,w,h,union_ok:=js_element_rect(a)
    testing.expect(t,union_ok && x==x0 && y==y0 && w==40 && h==y1+h1-y0)
    bx,by,bw,bh,bok:=js_element_rect(b)
    testing.expect(t,bok && bx==x && by==y && bw==w && bh==h)
    js_scroll_set(0,10)
    _,scrolled,_,_,_:=js_element_fragment(a,0)
    testing.expect(t,scrolled==y0-10)
    eq(t,js_str(t,c.vm,`String(document.getElementById('a').getClientRects().length)`),"2","inline fragment API")
    eq(t,js_str(t,c.vm,`String(document.getElementById('hidden').getClientRects().length)`),"0","display:none has no fragments")
    eq(t,js_str(t,c.vm,`String(document.createElement('span').getClientRects().length)`),"0","detached node has no fragments")
}

@(test)
test_inline_vertical_column_fragments :: proc(t:^testing.T) {
    c:=montar(`<style>body{margin:0}#v{writing-mode:vertical-rl;width:100px;height:100px}img{width:20px;height:10px}</style><div id="v"><span id="s"><img><br><img></span></div>`)
    defer desmontar(&c)
    node:=por_id(c.dom,"s")
    x0,y0,w0,h0,ok0:=js_element_fragment(node,0)
    x1,y1,w1,h1,ok1:=js_element_fragment(node,1)
    testing.expect(t,ok0 && ok1 && x1<x0 && y1==y0 && w0==20 && w1==20 && h0==10 && h1==10)
    _,_,_,_,extra:=js_element_fragment(node,2)
    testing.expect(t,!extra)
}

@(test)
test_empty_inline_fragment_geometry :: proc(t:^testing.T) {
    c:=montar(`<style>body{margin:0;font-size:20px;line-height:1}#p{position:absolute;left:40px;top:30px;transform:scale(2);transform-origin:0 0}</style><div id="p"><span id="a"></span><span id="nest"><span id="b"></span></span><span id="none" style="display:none"></span><span id="contents" style="display:contents"></span></div>`,800,600,true)
    defer desmontar(&c)
    for id in ([]string{"a","b","nest"}) {
        n:=por_id(c.dom,id)
        x,y,w,h,ok:=js_element_fragment(n,0)
        testing.expectf(t,ok && x==40 && y==30 && w==0 && h==40,"%s: (%v,%v,%v,%v), ok=%v",id,x,y,w,h,ok)
        _,_,_,_,extra:=js_element_fragment(n,1)
        testing.expect(t,!extra)
        bx,by,bw,bh,bok:=js_element_rect(n)
        testing.expect(t,bok && bx==x && by==y && bw==w && bh==h)
    }
    for id in ([]string{"none","contents"}) {
        _,_,_,_,ok:=js_element_fragment(por_id(c.dom,id),0)
        testing.expect(t,!ok)
    }
    eq(t,js_str(t,c.vm,`String(document.getElementById('a').getClientRects().length)`),"1","empty inline has one fragment")
    _,_,_,ph,pok:=js_element_rect(por_id(c.dom,"p"))
    testing.expect(t,pok && ph==0,"empty anchors do not create a nonempty line box")
    js_scroll_set(0,10)
    _,y,_,_,ok:=js_element_fragment(por_id(c.dom,"a"),0)
    testing.expect(t,ok && y==20)
}
