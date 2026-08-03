package js

// M129 — Shadow DOM + Custom Elements. Antes: `customElements.define` era um NO-OP e
// `attachShadow` não existia. Um site inteiro feito de Web Components (Lit) ficava com
// a árvore vazia — e attachShadow sozinho não resolveria nada, porque quem o chama é o
// próprio componente, de dentro do connectedCallback que nunca rodava.
//
// Os testes de RENDERIZAÇÃO (shadow tree no lugar dos filhos de luz, projeção de
// <slot>, escopo de estilo) estão em src/ui/ui_m129_test.odin — aqui é a API JS.
//
// ⚠️ Neste pacote NÃO há querySelector: o matcher de CSS entra por `g_dom_query`,
// instalado pela camada de UI. Em teste puro ele é nil e querySelector devolve
// sempre null — navegar por firstChild/children é o caminho válido aqui.

import "core:testing"
import dom "../dom"
import "core:strings"

// Documento mínimo com <html><body>: os testes de upgrade precisam de um body real
// (o registro varre a árvore do documento à procura de elementos a promover).
@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    // tag CLONADA: free_tree faz delete(n.tag), e liberar um literal é memória
    // não-heap — trava o runner (custou uma rodada de teste inteira).
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── attachShadow / ShadowRoot ─────────────────────────────────────────────────

@(test)
m129_attach_shadow_devolve_root :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var r = d.attachShadow({mode:"open"});
        (r !== null && typeof r === "object") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_shadow_root_host_aponta_de_volta :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var r = d.attachShadow({mode:"open"});
        (r.host === d && d.shadowRoot === r) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_modo_closed_esconde_o_shadow_root :: proc(t: ^testing.T) {
    // spec: com mode:"closed" o `el.shadowRoot` é null, mas a árvore existe.
    src := `
        var d = document.createElement("div");
        var r = d.attachShadow({mode:"closed"});
        (d.shadowRoot === null && r !== null) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_attach_shadow_e_idempotente :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var a = d.attachShadow({mode:"open"});
        var b = d.attachShadow({mode:"open"});
        a === b ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_shadow_nao_aparece_nos_filhos_de_luz :: proc(t: ^testing.T) {
    // A shadow root é um pseudo-filho na árvore: se vazasse p/ childNodes, um
    // `el.childNodes.length` passaria a mentir depois do attachShadow.
    src := `
        var d = document.createElement("div");
        d.appendChild(document.createElement("span"));
        var antes = d.childNodes.length;
        d.attachShadow({mode:"open"});
        (antes === 1 && d.childNodes.length === 1 && d.children.length === 1) ? "ok"
            : ("antes=" + antes + " depois=" + d.childNodes.length)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_shadow_root_aceita_innerhtml_e_query :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var r = d.attachShadow({mode:"open"});
        r.innerHTML = '<p class="x">oi</p>';
        var p = r.firstChild;
        // tagName vem MINÚSCULO neste motor (quirk conhecido; no DOM real é "P")
        (p !== null && p.tagName.toLowerCase() === "p" && p.textContent === "oi") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── getRootNode ──────────────────────────────────────────────────────────────

@(test)
m129_get_root_node_para_na_shadow_root :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var r = d.attachShadow({mode:"open"});
        r.innerHTML = "<b>x</b>";
        var b = r.firstChild;
        b.getRootNode() === r ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_get_root_node_composed_atravessa :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        document.body.appendChild(d);
        var r = d.attachShadow({mode:"open"});
        r.innerHTML = "<b>x</b>";
        var b = r.firstChild;
        b.getRootNode({composed:true}) !== r ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── template.content ─────────────────────────────────────────────────────────

@(test)
m129_template_content_de_elemento_criado :: proc(t: ^testing.T) {
    // createElement("template") não passa pelo parser: o #content é criado sob
    // demanda e os filhos existentes MIGRAM p/ dentro dele.
    src := `
        var t = document.createElement("template");
        t.innerHTML = "<i>dentro</i>";
        (t.content && t.content.childNodes.length === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_template_content_e_document_fragment :: proc(t: ^testing.T) {
    // O webcomponentsjs testa exatamente isto p/ decidir se carrega o polyfill.
    src := `
        var t = document.createElement("template");
        (t.content.cloneNode() instanceof DocumentFragment) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_feature_detect_do_webcomponentsjs :: proc(t: ^testing.T) {
    // O detect COMPLETO do loader: se der true, o polyfill entra por cima do nosso
    // nativo e briga com ele.
    src := `
        var t = document.createElement('template');
        var precisa = false;
        if (!('content' in t)) precisa = true;
        else if (!(t.content.cloneNode() instanceof DocumentFragment)) precisa = true;
        else {
            var t2 = document.createElement('template');
            t2.content.appendChild(document.createElement('div'));
            t.content.appendChild(t2);
            var clone = t.cloneNode(true);
            if (clone.content.childNodes.length === 0) precisa = true;
            else if (clone.content.firstChild.content.childNodes.length === 0) precisa = true;
        }
        var sd = !('attachShadow' in Element.prototype && 'getRootNode' in Element.prototype);
        (!precisa && !sd) ? "ok" : ("template=" + precisa + " shadow=" + sd)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── `in` enxerga o que o hook nativo serve ───────────────────────────────────

@(test)
m129_operador_in_consulta_o_hook_nativo :: proc(t: ^testing.T) {
    // Propriedades DOM vivem no get-hook, não em props: `in` não as via, e todo
    // feature-detect nesse estilo dava false.
    src := `
        var d = document.createElement("div");
        ('shadowRoot' in d && 'childNodes' in d && 'tagName' in d) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── Custom Elements: registro, upgrade e ciclo de vida ───────────────────────

@(test)
m129_define_e_get_registram :: proc(t: ^testing.T) {
    src := `
        class X extends HTMLElement {}
        customElements.define("x-um", X);
        customElements.get("x-um") === X ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_upgrade_roda_construtor_e_connected :: proc(t: ^testing.T) {
    // Elemento JÁ no documento quando o define acontece.
    src := `
        document.body.innerHTML = "<x-dois id='e'></x-dois>";
        var marcas = [];
        class X extends HTMLElement {
            constructor(){ super(); marcas.push("ctor") }
            connectedCallback(){ marcas.push("connected") }
        }
        customElements.define("x-dois", X);
        marcas.join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "ctor,connected")
}

@(test)
m129_upgrade_inicializa_campos_de_classe :: proc(t: ^testing.T) {
    // O upgrade chama o construtor SEM passar por construct_object, então precisa
    // inicializar os campos explicitamente. Era isto que deixava `this.renderOptions`
    // undefined no Lit.
    src := `
        document.body.innerHTML = "<x-tres id='e'></x-tres>";
        class Base extends HTMLElement { opcoes = { host: this }; }
        class X extends Base { proprio = 7; }
        customElements.define("x-tres", X);
        var e = document.getElementById("e");
        (e.opcoes && e.opcoes.host === e && e.proprio === 7) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_upgrade_liga_o_prototype_da_classe :: proc(t: ^testing.T) {
    src := `
        document.body.innerHTML = "<x-quatro id='e'></x-quatro>";
        class X extends HTMLElement { metodo(){ return "meu" } }
        customElements.define("x-quatro", X);
        var e = document.getElementById("e");
        (e.metodo() === "meu" && e instanceof X && e instanceof HTMLElement) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_upgrade_e_idempotente :: proc(t: ^testing.T) {
    src := `
        document.body.innerHTML = "<x-cinco id='e'></x-cinco>";
        var n = 0;
        class X extends HTMLElement { constructor(){ super(); n++ } }
        customElements.define("x-cinco", X);
        customElements.upgrade(document.getElementById("e"));
        n
    `
    testing.expect_value(t, run_dom(src).(f64), 1)
}

@(test)
m129_componente_que_lanca_nao_derruba_os_outros :: proc(t: ^testing.T) {
    src := `
        document.body.innerHTML = "<x-mau></x-mau><x-bom id='b'></x-bom>";
        class Mau extends HTMLElement { connectedCallback(){ throw new Error("boom") } }
        class Bom extends HTMLElement { connectedCallback(){ this.vivo = true } }
        customElements.define("x-mau", Mau);
        customElements.define("x-bom", Bom);
        document.getElementById("b").vivo === true ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m129_slot_assigned_nodes :: proc(t: ^testing.T) {
    src := `
        document.body.innerHTML = "<x-seis id='e'><span slot='t'>A</span><b>B</b></x-seis>";
        class X extends HTMLElement {
            connectedCallback(){
                this.attachShadow({mode:"open"}).innerHTML =
                    '<slot name="t"></slot><slot></slot>';
            }
        }
        customElements.define("x-seis", X);
        var e = document.getElementById("e");
        var slots = e.shadowRoot.children;
        (slots[0].assignedNodes().length === 1 && slots[1].assignedNodes().length === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}
