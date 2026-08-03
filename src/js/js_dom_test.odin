package js

// Testes da ponte JS ↔ DOM (M5, primeira fatia).
// Montamos uma árvore DOM na mão, rodamos um script com run_with_dom e
// verificamos que o DOM real foi lido/mutado. Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// Monta:  <div id="x">antigo</div>  sob um Document.
// Todas as strings são clonadas para que dom.free_tree possa liberá-las.
@(private = "file")
build_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)

    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("x")

    txt := dom.make_node(.Text)
    txt.text = strings.clone("antigo")
    dom.append_child(div, txt)
    dom.append_child(root, div)
    return root
}

// Lê o textContent de um nó como string comum (para as asserções).
@(private = "file")
node_text :: proc(n: ^dom.Node) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    dom.text_content(n, &sb)
    return strings.clone(strings.to_string(sb), context.temp_allocator)
}

@(test)
test_dom_get_by_id_e_text :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // comparação retorna bool (avaliada antes do vm_destroy)
    r := run_with_dom("document.getElementById('x').textContent == 'antigo'", root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "textContent inicial deve ser 'antigo'")
}

@(test)
test_dom_document_nodetype :: proc(t: ^testing.T) {
    // O objeto `document` precisa expor nodeType=9 e nodeName="#document". Sem
    // isso o Sizzle (jQuery) faz `9===r.nodeType && r.documentElement` como guarda
    // p/ setar sua var de document; a guarda falhava, a var ficava undefined e os
    // testes de suporte chamavam `<undef>.createElement` → jQuery abortava → `$`.
    root := build_dom()
    defer dom.free_tree(root)
    r := run_with_dom(`
        document.nodeType + '|' + document.nodeName + '|' + (9 === document.nodeType) +
        '|' + typeof document.createComment
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "9|#document|true|function")
}

@(test)
test_dom_create_html_document :: proc(t: ^testing.T) {
    // document.implementation.createHTMLDocument: o jQuery faz a feature-detect
    // `support.createHTMLDocument` como `implementation.createHTMLDocument('').body`
    // + `body.innerHTML='<form></form><form></form>'; childNodes.length===2`. Sem
    // implementation, `.body` de undefined lançava e o init do jQuery abortava.
    root := build_dom()
    defer dom.free_tree(root)
    r := run_with_dom(`
        var b = document.implementation.createHTMLDocument("").body;
        b.innerHTML = "<form></form><form></form>";
        typeof document.implementation + '|' + b.nodeName + '|' + (b.childNodes.length === 2) +
        '|' + document.implementation.createHTMLDocument("").nodeType
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "object|BODY|true|9")
}

@(test)
test_dom_document_fragment :: proc(t: ^testing.T) {
    // createDocumentFragment + semântica de expansão: ao dar appendChild do
    // fragmento, os FILHOS dele migram p/ o pai e o fragmento esvazia.
    root := build_dom()
    defer dom.free_tree(root)
    r := run_with_dom(`
        var frag = document.createDocumentFragment();
        frag.appendChild(document.createElement('span'));
        frag.appendChild(document.createElement('span'));
        var host = document.getElementById('x');
        var before = frag.children.length;
        host.appendChild(frag);
        frag.nodeType + '|' + before + '|' + host.children.length + '|' + frag.children.length
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "11|2|2|0") // nodeType=11, 2 antes, 2 migraram, 0 sobra
}

@(test)
test_dom_set_text_content :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    run_with_dom("document.getElementById('x').textContent = 'oi mundo'", root)
    // o nó DOM real deve ter mudado
    div := dom.find_first(root, "div")
    testing.expect_value(t, node_text(div), "oi mundo")
}

@(test)
test_dom_get_attribute :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // getAttribute devolve string dom-owned, válida até free_tree
    r := run_with_dom("document.getElementById('x').getAttribute('id')", root)
    v, _ := r.(string)
    testing.expect_value(t, v, "x")
}

@(test)
test_dom_set_attribute :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    run_with_dom("document.getElementById('x').setAttribute('data-n', '42')", root)
    div := dom.find_first(root, "div")
    v, found := div.attrs["data-n"]
    testing.expect(t, found, "atributo data-n deve existir")
    testing.expect_value(t, v, "42")
}

@(test)
test_dom_elemento_inexistente :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // getElementById de id inexistente -> null
    r := run_with_dom("document.getElementById('naoexiste') == null", root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "elemento inexistente deve dar null")
}

@(test)
test_dom_tag_name :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    r := run_with_dom("document.getElementById('x').tagName == 'DIV'", root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "tagName deve ser 'DIV' (MAIÚSCULO, spec HTML)")
}

// ── M6 fatia 1: vm persistente + eventos ──────────────────────────────────────

@(test)
test_event_add_listener_click :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    // vm PERSISTENTE: registra o handler agora, dispara depois
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0;
        document.getElementById('x').addEventListener('click', function() {
            n = n + 1;
            document.getElementById('x').textContent = 'clicado ' + n;
        });
    `)

    div := dom.find_first(root, "div")
    // o handler ainda não rodou
    testing.expect_value(t, node_text(div), "antigo")

    // dois cliques → a closure `n` persiste entre eles
    dispatch_event(vm, div, "click")
    dispatch_event(vm, div, "click")
    testing.expect_value(t, node_text(div), "clicado 2")
}

@(test)
test_event_onclick :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, "document.getElementById('x').onclick = function() { document.getElementById('x').textContent = 'via onclick'; };")

    div := dom.find_first(root, "div")
    dispatch_event(vm, div, "click")
    testing.expect_value(t, node_text(div), "via onclick")
}

@(test)
test_event_sem_listener :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)

    // nenhum handler registrado → dispatch não faz nada e devolve false
    div := dom.find_first(root, "div")
    fired := dispatch_event(vm, div, "click")
    testing.expect(t, !fired, "sem listener não deve disparar")
    testing.expect_value(t, node_text(div), "antigo")
}

// ── M8 fatia A: createElement / appendChild / removeChild / classList ─────────

@(test)
test_create_append :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, "var el = document.createElement('span'); el.textContent = 'novo'; document.getElementById('x').appendChild(el);")

    span := dom.find_first(root, "span")
    testing.expect(t, span != nil, "elemento criado deve estar na árvore")
    if span != nil do testing.expect_value(t, node_text(span), "novo")
}

// Conta elementos com a tag dada na subárvore (helper dos testes de cloneNode).
@(private = "file")
count_tag :: proc(n: ^dom.Node, tag: string) -> int {
    c := 0
    if n.kind == .Element && n.tag == tag do c += 1
    for ch in n.children do c += count_tag(ch, tag)
    return c
}

@(test)
test_clone_node_deep :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    // Padrão comum de montagem de listas: um nó "modelo" com filhos é clonado
    // (deep) por item. Regressão famososbr: sem cloneNode isto lançava
    // "cloneNode is not a function" e a galeria ficava vazia.
    vm_run(vm, `
        var tpl = document.createElement('article');
        tpl.setAttribute('data-k','v');
        var inner = document.createElement('span');
        inner.textContent = 'oi';
        tpl.appendChild(inner);
        document.getElementById('x').appendChild(tpl.cloneNode(true));
    `)
    // O modelo `tpl` é órfão (nunca anexado); só o CLONE entra na árvore. Deep:
    // o clone <article> traz junto seu filho <span> → 1 article e 1 span no root.
    testing.expect_value(t, count_tag(root, "article"), 1)
    testing.expect_value(t, count_tag(root, "span"), 1)
}

@(test)
test_module_scope_isolado :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    // Dois <script type="module"> declaram `r` no topo (um function, outro let). Cada
    // módulo ES tem seu escopo: não colidem nem vazam p/ o global. Regressão
    // famososbr: sem isolamento o `let r` do 2º módulo atropelava o `function r` do
    // 1º → "r is not a function" quando o handler do 1º disparava.
    vm_run_module(vm, "function r(){ return 1 }; globalThis.__callA = function(){ return r() }")
    vm_run_module(vm, "let r = 99")
    // o closure do módulo A ainda enxerga o SEU `function r` (=1), não o `let r` de B
    a := vm_run(vm, "globalThis.__callA()")
    if n, ok := a.(f64); ok { testing.expect_value(t, n, f64(1)) } else { testing.expect(t, false, "callA devolveu número") }
    // e nenhum `r` de módulo vazou p/ o escopo global
    ty := vm_run(vm, "typeof r")
    if s, ok := ty.(string); ok { testing.expect_value(t, s, "undefined") } else { testing.expect(t, false, "typeof r devolveu string") }
}

@(test)
test_clone_node_shallow :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    // cloneNode() sem argumento = raso: copia o nó mas NÃO os filhos.
    vm_run(vm, `
        var tpl = document.createElement('ul');
        tpl.appendChild(document.createElement('li'));
        document.getElementById('x').appendChild(tpl.cloneNode(false));
    `)
    // Só o clone entra na árvore; raso ⇒ SEM o <li> → 1 ul e 0 li no root
    // (contraste com o deep, que traz o filho).
    testing.expect_value(t, count_tag(root, "ul"), 1)
    testing.expect_value(t, count_tag(root, "li"), 0)
}

@(test)
test_remove_child :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    // cria + anexa e depois remove (referenciando `el`, que persiste no vm)
    vm_run(vm, "var el = document.createElement('p'); document.getElementById('x').appendChild(el);")
    testing.expect(t, dom.find_first(root, "p") != nil, "p deve entrar na árvore")
    vm_run(vm, "document.getElementById('x').removeChild(el);")
    testing.expect(t, dom.find_first(root, "p") == nil, "p deve sair após removeChild")
}

@(test)
test_orfao_sem_leak :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    // nó criado e NUNCA anexado: vm_free deve liberá-lo (o tracker acusaria leak)
    vm_run(vm, "var el = document.createElement('div'); el.textContent = 'solto';")
    testing.expect(t, dom.find_first(root, "div") != nil, "o div original continua lá")
}

@(test)
test_classlist :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)

    // add foo, add bar, remove foo, toggle baz  =>  "bar baz"
    run_with_dom("var e = document.getElementById('x'); e.classList.add('foo'); e.classList.add('bar'); e.classList.remove('foo'); e.classList.toggle('baz');", root)
    cls := dom.find_first(root, "div").attrs["class"]
    testing.expect(t, strings.contains(cls, "bar"),  "deve conter bar")
    testing.expect(t, strings.contains(cls, "baz"),  "deve conter baz")
    testing.expect(t, !strings.contains(cls, "foo"), "não deve conter foo")
}

@(test)
test_classlist_contains :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    a, _ := run_with_dom("var e = document.getElementById('x'); e.classList.add('active'); e.classList.contains('active')", root).(bool)
    b, _ := run_with_dom("document.getElementById('x').classList.contains('missing')", root).(bool)
    testing.expect(t, a && !b, "classList.contains")
}

// ── M10: querySelector (com stub de matcher; o real vive no pacote ui) ───────

// Stub do hook g_dom_query p/ os testes deste pacote: casa APENAS por tag.
// O matcher CSS completo (classes, ids, combinadores, :not...) é instalado
// pelo pacote ui via @(init) e verificado nas páginas de teste headless.
@(private = "file")
stub_query :: proc(scope: ^dom.Node, selector: string, all: bool, out: ^[dynamic]^dom.Node) {
    walk :: proc(n: ^dom.Node, tag: string, all: bool, out: ^[dynamic]^dom.Node) -> bool {
        if n.kind == .Element && n.tag == tag {
            append(out, n)
            if !all do return true
        }
        for c in n.children {
            if walk(c, tag, all, out) do return true
        }
        return false
    }
    for c in scope.children {
        if walk(c, selector, all, out) do break
    }
}

@(test)
test_query_selector :: proc(t: ^testing.T) {
    g_dom_query = stub_query
    root := build_dom()
    defer dom.free_tree(root)
    run_with_dom("document.querySelector('div').textContent = 'achou';", root)
    div := dom.find_first(root, "div")
    testing.expect_value(t, node_text(div), "achou")
}

@(test)
test_query_selector_null :: proc(t: ^testing.T) {
    g_dom_query = stub_query
    root := build_dom()
    defer dom.free_tree(root)
    v, _ := run_with_dom("document.querySelector('table') == null", root).(bool)
    testing.expect(t, v, "sem match deve dar null")
}

@(test)
test_query_selector_all :: proc(t: ^testing.T) {
    g_dom_query = stub_query
    root := build_dom()
    defer dom.free_tree(root)
    // cria 3 spans e consulta todos; o Array devolvido tem os métodos normais
    src := `
        for (var i = 0; i < 3; i++) {
            var sp = document.createElement('span');
            sp.textContent = 'n' + i;
            document.getElementById('x').appendChild(sp);
        }
        var todos = document.querySelectorAll('span');
        var soma = '';
        todos.forEach(function(el) { soma += el.textContent; });
        todos.length + ':' + soma
    `
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "3:n0n1n2")
}

@(test)
test_query_selector_escopo_elemento :: proc(t: ^testing.T) {
    g_dom_query = stub_query
    root := build_dom()
    defer dom.free_tree(root)
    // querySelector num ELEMENTO busca só na subárvore dele
    src := `
        var sp = document.createElement('span');
        sp.textContent = 'dentro';
        document.getElementById('x').appendChild(sp);
        document.getElementById('x').querySelector('span').textContent
    `
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "dentro")
}

// ── M13: innerHTML + navegação de nós ─────────────────────────────────────────

@(test)
test_inner_html_set :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    run_with_dom("document.getElementById('x').innerHTML = '<b>negrito</b> resto';", root)
    b := dom.find_first(root, "b")
    testing.expect(t, b != nil, "o <b> do fragmento deve entrar na árvore")
    div := dom.find_first(root, "div")
    testing.expect_value(t, node_text(div), "negrito resto")
}

@(test)
test_inner_html_roundtrip :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    src := `var e = document.getElementById('x');
            e.innerHTML = '<b>a</b>texto<br>';
            e.innerHTML`
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "<b>a</b>texto<br>")
}

@(test)
test_inner_html_atributos :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // atributos do fragmento sobrevivem (o span fica consultável por classe... via getAttribute)
    src := `var e = document.getElementById('x');
            e.innerHTML = '<span class="oi">s</span>';
            e.firstChild.getAttribute('class')`
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "oi")
}

@(test)
test_parent_node :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    src := `var sp = document.createElement('span');
            document.getElementById('x').appendChild(sp);
            sp.parentNode.tagName`
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "DIV")
}

@(test)
test_children_e_siblings :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // div#x tem 1 filho de TEXTO ("antigo"); children (só elementos) ignora-o
    src := `var e = document.getElementById('x');
            var antes = e.children.length;
            var a = document.createElement('em');   a.textContent = '1';
            var b = document.createElement('code'); b.textContent = '2';
            e.appendChild(a); e.appendChild(b);
            antes + ':' + e.children.length + ':' + e.children[0].tagName + ':' + a.nextSibling.tagName`
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "0:2:EM:CODE")
}

@(test)
test_first_child_texto :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // firstChild devolve QUALQUER nó — aqui, o nó de texto "antigo"
    src := "document.getElementById('x').firstChild.textContent"
    v, _ := run_with_dom(src, root).(string)
    testing.expect_value(t, v, "antigo")
}

@(test)
test_next_sibling_null :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    ok, _ := run_with_dom("document.getElementById('x').firstChild.nextSibling == null", root).(bool)
    testing.expect(t, ok, "último filho não tem nextSibling")
}

// ── M9 fatia 2: objeto event (target, bubbling, stopPropagation) ─────────────

@(test)
test_event_object_target :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)

    // listener no PAI (#x); o clique acontece no filho <span> criado pelo JS.
    // e.target deve ser o span; this (currentTarget) deve ser o div.
    vm_run(vm, `
        var out = '';
        var sp = document.createElement('span');
        document.getElementById('x').appendChild(sp);
        document.getElementById('x').addEventListener('click', function(e) {
            out = e.type + ':' + e.target.tagName + ':' + this.tagName;
        });
    `)
    span := dom.find_first(root, "span")
    fired := dispatch_event(vm, span, "click") // bolha: span -> div#x
    testing.expect(t, fired, "handler do ancestral deve disparar via bubbling")
    v, _ := vm_run(vm, "out").(string)
    testing.expect_value(t, v, "click:SPAN:DIV")
}

@(test)
test_event_stop_propagation :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)

    // filho para a propagação: o handler do pai NÃO deve rodar
    vm_run(vm, `
        var log = '';
        var sp = document.createElement('span');
        document.getElementById('x').appendChild(sp);
        sp.addEventListener('click', function(e) { log += 'filho'; e.stopPropagation(); });
        document.getElementById('x').addEventListener('click', function() { log += ',pai'; });
    `)
    span := dom.find_first(root, "span")
    dispatch_event(vm, span, "click")
    v, _ := vm_run(vm, "log").(string)
    testing.expect_value(t, v, "filho")
}

@(test)
test_event_prevent_default :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)

    // defaultPrevented reflete a chamada de preventDefault
    vm_run(vm, `
        var out = '';
        document.getElementById('x').addEventListener('click', function(e) {
            out = '' + e.defaultPrevented;
            e.preventDefault();
            out = out + '/' + e.defaultPrevented;
        });
    `)
    div := dom.find_first(root, "div")
    dispatch_event(vm, div, "click")
    v, _ := vm_run(vm, "out").(string)
    testing.expect_value(t, v, "false/true")
}

@(test)
test_class_name :: proc(t: ^testing.T) {
    root := build_dom()
    defer dom.free_tree(root)
    // className setter grava, e classList enxerga as mesmas classes
    ok, _ := run_with_dom("var e = document.getElementById('x'); e.className = 'a b c'; e.className == 'a b c'", root).(bool)
    testing.expect(t, ok, "className get/set")
    ok2, _ := run_with_dom("var e = document.getElementById('x'); e.className = 'a b'; e.classList.contains('b')", root).(bool)
    testing.expect(t, ok2, "classList lê o que className gravou")
}
