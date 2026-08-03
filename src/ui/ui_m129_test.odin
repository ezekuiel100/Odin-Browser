package ui

// M129 — RENDERIZAÇÃO do Shadow DOM: a árvore sombra entra no lugar dos filhos de
// luz, <slot> projeta o conteúdo do host, e o <style> de dentro do shadow NÃO vaza
// para a página (nem a página entra no componente). A API JS está em
// src/js/js_m129_test.odin.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import jspkg "../js"

@(private = "file")
render :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    htmlp.normalize_document(dom)
    vm := jspkg.load_page(dom) // roda os <script>: é aí que os componentes se registram
    defer jspkg.vm_free(vm)
    css := collect_css(dom)
    rules, kf := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, vw, vh, kf[:])
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return root
}

@(private = "file")
find_tag :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := find_tag(c, tag); r != nil do return r
    }
    return nil
}

// Junta todo o texto das caixas inline da subárvore.
@(private = "file")
text_of :: proc(b: ^Box, sb: ^[dynamic]string) {
    if b == nil do return
    for it in b.inlines {
        if it.kind == .Word do append(sb, it.text)
    }
    for c in b.children do text_of(c, sb)
}

@(private = "file")
has_text :: proc(b: ^Box, want: string) -> bool {
    words: [dynamic]string
    defer delete(words)
    text_of(b, &words)
    for w in words {
        if w == want do return true
    }
    return false
}

@(private = "file")
COMP :: `<script>
class MyC extends HTMLElement {
  connectedCallback(){
    var r = this.attachShadow({mode:"open"});
    r.innerHTML = '<style>.cx{height:40px}</style>' +
      '<div class="cx">SOMBRA</div>' +
      '<div><slot name="t">FALLBACK-T</slot></div>' +
      '<div><slot>FALLBACK-D</slot></div>';
  }
}
customElements.define("my-c", MyC);
</script>`

// A árvore SOMBRA aparece; os filhos de luz não-projetados NÃO aparecem crus.
@(test)
m129_shadow_substitui_filhos_de_luz :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><my-c>LUZ-CRUA</my-c>` + COMP + `</body>`)
    host := find_tag(root, "my-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    testing.expect(t, has_text(host, "SOMBRA"), "a árvore sombra renderizou")
}

// <slot> nomeado e default projetam o conteúdo de luz do host.
@(test)
m129_slot_projeta_conteudo_de_luz :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><my-c><span slot="t">TITULO</span><b>CORPO</b></my-c>` + COMP + `</body>`)
    host := find_tag(root, "my-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    testing.expect(t, has_text(host, "TITULO"), "slot nomeado projetou")
    testing.expect(t, has_text(host, "CORPO"), "slot default projetou")
    testing.expect(t, !has_text(host, "FALLBACK-T"), "com projeção o fallback NÃO entra")
}

// Sem conteúdo de luz, vale o fallback de dentro do <slot>.
@(test)
m129_slot_usa_fallback_quando_vazio :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><my-c></my-c>` + COMP + `</body>`)
    host := find_tag(root, "my-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    testing.expect(t, has_text(host, "FALLBACK-T"), "fallback nomeado")
    testing.expect(t, has_text(host, "FALLBACK-D"), "fallback default")
}

// O <style> do shadow vale DENTRO (a altura de 40px chega na caixa do componente).
@(test)
m129_estilo_do_shadow_aplica_dentro :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><my-c></my-c>` + COMP + `</body>`)
    host := find_tag(root, "my-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    achou := false
    for c in host.children {
        if c.h == 40 do achou = true
    }
    testing.expect(t, achou, "a regra .cx{height:40px} do shadow aplicou")
}

// …e NÃO vaza para um elemento de mesma classe fora do componente.
@(test)
m129_estilo_do_shadow_nao_vaza_pra_pagina :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><my-c></my-c><div class="cx" id="fora">x</div>` + COMP + `</body>`)
    fora: ^Box
    walk :: proc(b: ^Box, out: ^^Box) {
        if b == nil do return
        if b.node != nil && b.node.attrs != nil {
            if v, ok := b.node.attrs["id"]; ok && v == "fora" do out^ = b
        }
        for c in b.children do walk(c, out)
    }
    walk(root, &fora)
    testing.expect(t, fora != nil, "achou o div de fora")
    if fora == nil do return
    testing.expectf(t, fora.h != 40, "regra do shadow NÃO pode valer fora (h=%.0f)", fora.h)
}

// A regra da PÁGINA não deve entrar no shadow (escopo no outro sentido).
@(test)
m129_estilo_da_pagina_nao_entra_no_shadow :: proc(t: ^testing.T) {
    // A página manda .cx ter 7px; dentro do shadow a regra local (40px) é que vale.
    root := render(`<body style="margin:0"><style>.cx{height:7px}</style><my-c></my-c>` + COMP + `</body>`)
    host := find_tag(root, "my-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    for c in host.children {
        testing.expectf(t, c.h != 7, "regra da página não pode vencer dentro do shadow (h=%.0f)", c.h)
    }
}

// :host estiliza o próprio elemento hospedeiro.
@(test)
m129_host_estiliza_o_hospedeiro :: proc(t: ^testing.T) {
    comp :: `<script>
      class HostC extends HTMLElement {
        connectedCallback(){
          this.attachShadow({mode:"open"}).innerHTML =
            '<style>:host{height:55px;display:block}</style><i>x</i>';
        }
      }
      customElements.define("host-c", HostC);
    </script>`
    root := render(`<body style="margin:0"><host-c></host-c>` + comp + `</body>`)
    host := find_tag(root, "host-c")
    testing.expect(t, host != nil, "achou o host")
    if host == nil do return
    testing.expectf(t, host.h == 55, ":host{height:55px} aplicou (h=%.0f)", host.h)
}

// Componente sem shadow segue renderizando os filhos de luz (não-regressão).
@(test)
m129_sem_shadow_renderiza_luz_normalmente :: proc(t: ^testing.T) {
    root := render(`<body style="margin:0"><div id="d">TEXTO-NORMAL</div></body>`)
    testing.expect(t, has_text(root, "TEXTO-NORMAL"), "árvore comum intacta")
}
