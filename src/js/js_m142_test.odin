package js

// M142 — wrappers de elemento DOM ganharam PROTOTYPE ESPECÍFICO por tag, então
// `el instanceof HTMLScriptElement` (etc.) passa a ser TRUE. Motivador: o runtime
// do Turbopack/Next.js EXIGE `document.currentScript instanceof HTMLScriptElement`
// e lançava "InvariantError: Expected document.currentScript to be a <script>
// element" em 5 sites do gap-miner (nextjs.org, nodejs.org, tailwindcss.com,
// digitalocean, stanford). Antes, TODO wrapper usava HTMLElement.prototype.

import "core:testing"
import dom "../dom"
import "core:strings"

@(private = "file")
run_dom142 :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

@(test)
m142_script_instanceof_htmlscriptelement :: proc(t: ^testing.T) {
    // o coração do fix: um <script> passa no brand check do Turbopack.
    src := `
        var s = document.createElement("script");
        (s instanceof HTMLScriptElement) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

@(test)
m142_cadeia_de_prototype_preservada :: proc(t: ^testing.T) {
    // o prototype específico encadeia sob HTMLElement/Element/Node: instanceof
    // das interfaces-base continua valendo (senão quebraria meio polyfill).
    src := `
        var s = document.createElement("script");
        (s instanceof HTMLElement && s instanceof Element && s instanceof Node
            && s instanceof EventTarget) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

@(test)
m142_tag_sem_subtipo_cai_no_generico :: proc(t: ^testing.T) {
    // tag sem interface própria (ex.: <section>) usa HTMLElement; instanceof de
    // um subtipo QUALQUER deve ser false (não vaza pro tipo errado).
    src := `
        var el = document.createElement("section");
        (el instanceof HTMLElement && !(el instanceof HTMLScriptElement)
            && !(el instanceof HTMLDivElement)) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

@(test)
m142_subtipos_distintos_nao_se_confundem :: proc(t: ^testing.T) {
    // <div> é HTMLDivElement mas NÃO HTMLScriptElement, e vice-versa.
    src := `
        var d = document.createElement("div");
        var s = document.createElement("script");
        (d instanceof HTMLDivElement && !(d instanceof HTMLScriptElement)
            && s instanceof HTMLScriptElement && !(s instanceof HTMLDivElement)) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

@(test)
m142_headings_compartilham_htmlheadingelement :: proc(t: ^testing.T) {
    // h1..h6 mapeiam TODOS p/ HTMLHeadingElement (spec).
    src := `
        var h1 = document.createElement("h1");
        var h3 = document.createElement("h3");
        (h1 instanceof HTMLHeadingElement && h3 instanceof HTMLHeadingElement) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

// ── tagName MAIÚSCULO p/ HTML (spec), caixa preservada p/ estrangeiro ──

@(test)
m142_tagname_html_maiusculo :: proc(t: ^testing.T) {
    // `el.tagName === 'SCRIPT'` é idioma comum de site (o próprio invariant do
    // Turbopack pode checar assim); antes devolvíamos minúsculo e falhava.
    src := `
        var s = document.createElement("script");
        var d = document.createElement("div");
        (s.tagName === "SCRIPT" && d.tagName === "DIV"
            && s.nodeName === "SCRIPT") ? "ok"
            : ("tag=" + s.tagName + " node=" + s.nodeName)
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}

@(test)
m142_tagname_svg_preserva_caixa :: proc(t: ^testing.T) {
    // conteúdo estrangeiro (SVG) NÃO é uppercased: um <svg> parseado fica "svg".
    // (Distingue-se de createElement("svg"), que é HTML → "SVG".)
    src := `
        var host = document.createElement("div");
        host.innerHTML = "<svg><rect></rect></svg>";
        var svg = host.firstChild;
        (svg.tagName === "svg" && svg.firstChild.tagName === "rect") ? "ok"
            : ("svg=" + svg.tagName + " child=" + svg.firstChild.tagName)
    `
    testing.expect_value(t, run_dom142(src).(string), "ok")
}
