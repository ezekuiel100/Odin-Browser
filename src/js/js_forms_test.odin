package js

import "core:strings"
import "core:testing"
import dom "../dom"

// Envio de <form> e navegação pedida pela página (dom_forms.odin).
//
// O que está sob teste é a URL PEDIDA (vm.nav_request), byte a byte, não "não
// lançou". O caso-âncora é o desafio de JS do reddit, reproduzido no 1º teste com
// o script original deles: sem o envio, a aba ficava parada no logo para sempre.

@(private = "file")
doc_vazio :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, html)
    dom.append_child(html, body)
    return root
}

// Monta o vm sobre um documento cujo <body> recebe `body_html`, roda `src` e
// devolve (resultado do script, URL pedida). A URL sai clonada no temp.
@(private = "file")
roda :: proc(body_html, src: string, base := "https://www.exemplo.com/pasta/pagina?velha=1#frag") -> (res: Value, nav: string, replace: bool) {
    root := doc_vazio()
    vm := vm_create_with_dom(root)
    vm.base_url = strings.clone(base) // o vm_destroy libera base_url por conta própria
    vm_run(vm, strings.concatenate({"document.body.innerHTML = ", js_quote(body_html), ";"}, context.temp_allocator))
    res = vm_run(vm, src)
    if s, ok := res.(string); ok do res = strings.clone(s, context.temp_allocator)
    if u, r, ok := vm_take_nav_request(vm); ok {
        nav = strings.clone(u, context.temp_allocator)
        replace = r
    }
    vm_free(vm)
    dom.free_tree(root)
    return
}

@(private = "file")
js_quote :: proc(s: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_byte(&sb, '"')
    for c in transmute([]u8)s {
        switch c {
        case '"':  strings.write_string(&sb, `\"`)
        case '\\': strings.write_string(&sb, `\\`)
        case '\n': strings.write_string(&sb, `\n`)
        case:      strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// O script REAL do desafio do reddit (só trocado o "solution" calculado).
@(test)
forms_desafio_do_reddit :: proc(t: ^testing.T) {
    body := `<main></main><form hidden method="GET" action="/">` +
            `<input type="hidden" name="solution" />` +
            `<input type="hidden" name="js_challenge" value="1"/>` +
            `<input type="hidden" name="jsc_token" value="abc123"/>` +
            `<input type="hidden" name="jsc_orig_r" value=""/></form>`
    src := `(async function(){var e=document.forms[0],n=(e.onsubmit=function(t){return new URLSearchParams(document.location.search).forEach((e,n)=>t.target.appendChild(Object.assign(document.createElement("input"),{name:n,type:"hidden",value:e}))),!0},await(async e=>e+e)("ff"));e.elements.namedItem("solution").value=n,e.requestSubmit()})(); 1`
    _, nav, _ := roda(body, src, "https://www.reddit.com/")
    testing.expect_value(t, nav, "https://www.reddit.com/?solution=ffff&js_challenge=1&jsc_token=abc123&jsc_orig_r=")
}

// O onsubmit do reddit copia a query da página para o form: os campos novos
// entram no envio (o handler roda ANTES de montar os dados).
@(test)
forms_onsubmit_adiciona_campo_antes_de_montar :: proc(t: ^testing.T) {
    body := `<form action="/busca"><input name="q" value="a b"></form>`
    src := `var f=document.forms[0]; f.onsubmit=function(e){var i=document.createElement("input"); i.name="x"; i.value="1"; e.target.appendChild(i)}; f.requestSubmit(); 1`
    _, nav, _ := roda(body, src)
    testing.expect_value(t, nav, "https://www.exemplo.com/busca?q=a+b&x=1")
}

@(test)
forms_preventdefault_e_return_false_cancelam :: proc(t: ^testing.T) {
    body := `<form action="/x"><input name="q" value="1"></form>`
    _, nav1, _ := roda(body, `var f=document.forms[0]; f.addEventListener("submit", function(e){e.preventDefault()}); f.requestSubmit(); 1`)
    testing.expect_value(t, nav1, "")
    _, nav2, _ := roda(body, `var f=document.forms[0]; f.onsubmit=function(){return false}; f.requestSubmit(); 1`)
    testing.expect_value(t, nav2, "")
    // submit() NÃO dispara o evento: o cancelamento não o alcança (spec)
    _, nav3, _ := roda(body, `var f=document.forms[0]; f.onsubmit=function(){return false}; f.submit(); 1`)
    testing.expect_value(t, nav3, "https://www.exemplo.com/x?q=1")
}

// Conjunto de dados: desabilitado, sem nome, checkbox/radio, select, textarea,
// botões (só o submitter), e a codificação (espaço='+', UTF-8 em %XX, CRLF).
@(test)
forms_conjunto_de_dados_e_codificacao :: proc(t: ^testing.T) {
    body := `<form action="dest?velha=9#ancora">` +
            `<input name="a" value="x&y=z">` +
            `<input name="off" value="1" disabled>` +
            `<input value="sem-nome">` +
            `<input type="checkbox" name="c1" checked>` +
            `<input type="checkbox" name="c2" value="nao">` +
            `<input type="radio" name="r" value="um">` +
            `<input type="radio" name="r" value="dois" checked>` +
            `<select name="s"><option>p</option><option selected value="q2">q</option></select>` +
            `<textarea name="t">l1
l2</textarea>` +
            `<fieldset disabled><input name="fs" value="1"></fieldset>` +
            `<button name="b1" value="v1">1</button>` +
            `<button name="b2" value="v2" id="dois">2</button>` +
            `<input name="u" value="ção">` +
            `</form>`
    src := `var f=document.forms[0]; f.requestSubmit(document.getElementById("dois")); 1`
    _, nav, _ := roda(body, src)
    testing.expect_value(t, nav,
        "https://www.exemplo.com/pasta/dest?a=x%26y%3Dz&c1=on&r=dois&s=q2&t=l1%0D%0Al2&b2=v2&u=%C3%A7%C3%A3o#ancora")
}

// Clique num botão de envio = ação padrão do clique (é o que a UI chama).
@(test)
forms_clique_no_botao_envia :: proc(t: ^testing.T) {
    root := doc_vazio()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm.base_url = strings.clone("https://h.com/")
    vm_run(vm, `document.body.innerHTML = '<form action="/go"><input name="k" value="v"><button id="b"><span id="s">ok</span></button></form><button id="fora">x</button>'`)
    span := dom.find_first(root, "span")
    testing.expect(t, click_default_submit(vm, span), "clique no <span> dentro do botão envia")
    u, _, ok := vm_take_nav_request(vm)
    testing.expect(t, ok && u == "https://h.com/go?k=v", u)
    // botão FORA de formulário: nada
    fora: ^dom.Node
    for b in dom.find_first(root, "body").children do if b.tag == "button" do fora = b
    testing.expect(t, !click_default_submit(vm, fora), "botão sem form não envia")
}

// POST é recusado (degradação 1): nada de virar um GET que o servidor não espera.
@(test)
forms_post_nao_vira_get :: proc(t: ^testing.T) {
    _, nav, _ := roda(`<form method="post" action="/login"><input name="u" value="1"></form>`,
        `document.forms[0].submit(); document.forms[0].method`)
    testing.expect_value(t, nav, "")
}

@(test)
forms_colecoes_e_propriedades :: proc(t: ^testing.T) {
    body := `<form id="f1" name="busca" action="/a"><input name="q"><input id="x"></form><form id="f2"></form><input form="f1" name="externo">`
    r, _, _ := roda(body,
        `var f=document.forms.busca; [document.forms.length, f===document.forms.namedItem("f1"), f.elements.length, ` +
        `f.elements.q.name, f.elements.namedItem("x").id, f.elements.externo.name, document.forms.f2.elements.length, ` +
        `f.elements.q.form===f, f.action, f.method, document.forms.item(5)===null].join("|")`)
    s, _ := r.(string)
    testing.expect_value(t, s, "2|true|3|q|x|externo|0|true|https://www.exemplo.com/a|get|true")
}

@(test)
forms_location_navega :: proc(t: ^testing.T) {
    _, n1, r1 := roda("", `location.href = "/novo"; 1`)
    testing.expect_value(t, n1, "https://www.exemplo.com/novo")
    testing.expect(t, !r1, "href não é replace")
    _, n2, r2 := roda("", `location.replace("outra.html"); 1`)
    testing.expect_value(t, n2, "https://www.exemplo.com/pasta/outra.html")
    testing.expect(t, r2, "replace marca replace")
    _, n3, _ := roda("", `location.assign("?p=2"); 1`)
    testing.expect_value(t, n3, "https://www.exemplo.com/pasta/pagina?p=2")
    _, n4, _ := roda("", `window.location = "https://outro.org/z"; 1`)
    testing.expect_value(t, n4, "https://outro.org/z")
    _, n5, _ := roda("", `location.search = "a=1"; 1`)
    testing.expect_value(t, n5, "https://www.exemplo.com/pasta/pagina?a=1")
    // só fragmento e javascript: NÃO navegam; reload segue no-op (degradação 5)
    _, n6, _ := roda("", `location.href = "#sec"; location.hash = "y"; location.assign("javascript:void 0"); location.reload(); 1`)
    testing.expect_value(t, n6, "")
    // `location.href = new URL(...)` usa o toString do objeto
    _, n7, _ := roda("", `location.href = new URL("https://u.com/p"); 1`)
    testing.expect_value(t, n7, "https://u.com/p")
}
