package js

// M130 — o peel do Lit no archive.org. SETE bugs distintos, todos de motor e todos
// compartilhados. O que mais custou: `await` era BLOQUEANTE (girava bombeando timers
// até a promise assentar, com timeout de 10s). Isso é deadlock por construção quando
// quem resolve a promise é código que só roda DEPOIS da chamada async — que é
// exatamente o ciclo de update do Lit. Agora a async function roda como CORROTINA
// (mesma máquina dos generators) e cada await SUSPENDE.

import "core:testing"
import dom "../dom"
import "core:strings"

@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── 1) await suspende em vez de bloquear ─────────────────────────────────────

@(test)
m130_await_retoma_com_promise_resolvida_depois :: proc(t: ^testing.T) {
    // O CASO DO LIT: a promise é criada antes e resolvida por código POSTERIOR à
    // chamada async. Com await bloqueante isto travava 10s e morria por timeout.
    src := `
        var enable;
        var p = new Promise(function(res){ enable = res });
        var ordem = [];
        (async function(){ ordem.push("antes"); await p; ordem.push("depois") })();
        ordem.push("sincrono");
        enable(true);
        ordem.join(",")
    `
    // O essencial: "depois" ACONTECE. (A posição exata dele em relação ao código
    // síncrono seguinte é uma fidelidade de microtask que ainda não temos.)
    got := run(src).(string)
    testing.expectf(t, strings.contains(got, "depois"), "a corrotina retomou (ordem=%s)", got)
    testing.expectf(t, strings.contains(got, "antes"), "o corpo rodou até o await (ordem=%s)", got)
}

@(test)
m130_async_devolve_promise_e_nao_bloqueia :: proc(t: ^testing.T) {
    // A chamada async retorna IMEDIATAMENTE (antes do await assentar).
    src := `
        var enable;
        var p = new Promise(function(res){ enable = res });
        var voltou = false;
        (async function(){ await p; })();
        voltou = true;
        enable(1);
        voltou
    `
    testing.expect_value(t, run(src).(bool), true)
}

@(test)
m130_await_de_ja_resolvida_continua_funcionando :: proc(t: ^testing.T) {
    src := `
        var r = "nao";
        (async function(){ r = await Promise.resolve("sim") })();
        r
    `
    testing.expect_value(t, run(src).(string), "sim")
}

@(test)
m130_rejeicao_vira_throw_no_ponto_do_await :: proc(t: ^testing.T) {
    src := `
        var rej;
        var p = new Promise(function(_, rj){ rej = rj });
        var capturado = "nao";
        (async function(){
            try { await p } catch (e) { capturado = e.message }
        })();
        rej(new Error("falhou"));
        capturado
    `
    testing.expect_value(t, run(src).(string), "falhou")
}

@(test)
m130_valor_de_retorno_resolve_a_promise_da_async :: proc(t: ^testing.T) {
    src := `
        var got = "nao";
        (async function(){ return 7 })().then(function(v){ got = "v=" + v });
        got
    `
    testing.expect_value(t, run(src).(string), "v=7")
}

@(test)
m130_awaits_encadeados :: proc(t: ^testing.T) {
    src := `
        var e1, e2;
        var p1 = new Promise(function(r){ e1 = r });
        var p2 = new Promise(function(r){ e2 = r });
        var passos = [];
        (async function(){ await p1; passos.push("um"); await p2; passos.push("dois") })();
        e1(1); e2(2);
        passos.join(",")
    `
    testing.expect_value(t, run(src).(string), "um,dois")
}

// ── 2) hasOwnProperty em Array (o lit-html valida o template com isso) ───────

@(test)
m130_array_herda_metodos_de_object_prototype :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof [].hasOwnProperty`).(string), "function")
    testing.expect_value(t, run(`[1,2].hasOwnProperty(0)`).(bool), true)
    testing.expect_value(t, run(`[1,2].hasOwnProperty(5)`).(bool), false)
    testing.expect_value(t, run(`[1,2].hasOwnProperty("length")`).(bool), true)
}

@(test)
m130_template_tagueado_tem_raw_proprio :: proc(t: ^testing.T) {
    // `strings.hasOwnProperty('raw')` — o lit-html lança "invalid template strings
    // array" quando isto é false.
    src := "function tag(s){ return s.hasOwnProperty('raw') } tag`a${1}b`"
    testing.expect_value(t, run(src).(bool), true)
}

// ── 3) constructor de custom element promovido é a CLASSE ────────────────────

@(test)
m130_constructor_de_elemento_promovido_e_a_classe :: proc(t: ^testing.T) {
    // O Lit faz `this.constructor.elementProperties` DENTRO do construtor; o hook
    // do DOM devolvia um construtor genérico compartilhado (p/ o React), e o
    // componente morria.
    src := `
        document.body.innerHTML = "<x-ctor id='e'></x-ctor>";
        class XC extends HTMLElement { static elementProperties = new Map([["a",1]]); }
        customElements.define("x-ctor", XC);
        var e = document.getElementById("e");
        (e.constructor === XC && e.constructor.elementProperties.size === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m130_elemento_comum_mantem_constructor_generico :: proc(t: ^testing.T) {
    // Não-regressão: o caminho do React (constructor com prototype VAZIO) segue
    // valendo p/ elementos NÃO promovidos.
    src := `
        var d = document.createElement("input");
        (typeof d.constructor === "function" && typeof d.constructor.prototype === "object") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── 4) DocumentFragment: inserir move os FILHOS ──────────────────────────────

@(test)
m130_append_de_template_content_move_os_filhos :: proc(t: ^testing.T) {
    // `appendChild(importNode(tpl.content, true))` é como TODO lit-html instancia
    // um template. Antes, o nó #content ia inteiro p/ a árvore e o layout (que pula
    // pseudo-nós) não renderizava nada.
    src := `
        var t = document.createElement("template");
        t.innerHTML = "<b>um</b><i>dois</i>";
        var alvo = document.createElement("div");
        alvo.appendChild(document.importNode(t.content, true));
        (alvo.childNodes.length === 2 && alvo.firstChild.tagName.toLowerCase() === "b") ? "ok"
            : ("filhos=" + alvo.childNodes.length)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m130_import_node_existe_e_clona :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        d.innerHTML = "<b>x</b>";
        var c = document.importNode(d, true);
        (c !== d && c.childNodes.length === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── 5) hasAttributes / getAttributeNames (o walker do lit-html) ──────────────

@(test)
m130_has_attributes_e_get_attribute_names :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        var vazio = d.hasAttributes();
        d.setAttribute("a", "1");
        d.setAttribute("b", "2");
        var nomes = d.getAttributeNames().sort().join(",");
        (vazio === false && d.hasAttributes() === true && nomes === "a,b") ? "ok"
            : ("vazio=" + vazio + " nomes=" + nomes)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── 6) comment.data / nodeValue ──────────────────────────────────────────────

@(test)
m130_comment_data_e_legivel :: proc(t: ^testing.T) {
    // O lit-html reconhece os PRÓPRIOS marcadores lendo comment.data.
    src := `
        var d = document.createElement("div");
        d.innerHTML = "<!--marcador-->";
        var c = d.firstChild;
        (c.nodeType === 8 && c.data === "marcador" && c.nodeValue === "marcador") ? "ok"
            : ("tipo=" + c.nodeType + " data=" + c.data)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

// ── 7) `<?...>` é BOGUS COMMENT, não elemento ───────────────────────────────

@(test)
m130_marcador_lit_vira_comentario_no_innerhtml :: proc(t: ^testing.T) {
    // O lit-html emite `<?lit$xxx$>` COMO marcador contando que o parser vire
    // comentário. O parser de spec (parse_document) já fazia certo; o caminho
    // LEGADO usado pelo innerHTML criava um elemento que engolia o resto.
    src := `
        var d = document.createElement("div");
        d.innerHTML = '<p><?lit$abc$><span>s</span></p>';
        var p = d.firstChild;
        var c = p.childNodes[0];
        (p.childNodes.length === 2 && c.nodeType === 8 && p.childNodes[1].tagName.toLowerCase() === "span")
            ? "ok" : ("filhos=" + p.childNodes.length + " tipo0=" + c.nodeType)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}
