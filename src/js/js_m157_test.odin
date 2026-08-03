package js

// M157 — Path2D e XPathEvaluator (shells de feature-detect, dom_shims.odin).
//
// Últimos nomes do ranking de globais do MOTOR (o resto é do-site). São globais
// do WINDOW/DOM, então os testes usam VM com DOM (vm_create_with_dom), não run().
//
// O que guardam: o construtor EXISTE (typeof/instanceof), os métodos NÃO estouram,
// e — a parte honesta — o XPath devolve resultado VAZIO (não inventamos matches).

import "core:testing"
import "core:strings"
import dom "../dom"

@(private = "file")
m157_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, html)
    dom.append_child(html, body)
    return root
}

@(private = "file")
run_m157 :: proc(src: string) -> Value {
    root := m157_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    return vm_run(vm, src)
}

// ── Path2D ────────────────────────────────────────────────────────────────────

@(test)
m157_path2d_existe_e_constroi :: proc(t: ^testing.T) {
    testing.expect_value(t, run_m157(`typeof Path2D`).(string), "function")
    testing.expect_value(t, run_m157(`new Path2D() instanceof Path2D`).(bool), true)
}

@(test)
m157_path2d_metodos_nao_estouram :: proc(t: ^testing.T) {
    // o feature-detect real chama estes métodos; não podem lançar.
    src := `
        var p = new Path2D();
        p.moveTo(0,0); p.lineTo(10,10); p.rect(0,0,5,5);
        p.arc(0,0,1,0,6.28); p.closePath();
        var q = new Path2D();
        p.addPath(q);
        "ok"
    `
    testing.expect_value(t, run_m157(src).(string), "ok")
}

@(test)
m157_path2d_aceita_arg :: proc(t: ^testing.T) {
    // new Path2D(svgPathString) e new Path2D(outroPath) constroem sem estourar.
    testing.expect_value(t, run_m157(`new Path2D("M0 0 L10 10") instanceof Path2D`).(bool), true)
    testing.expect_value(t, run_m157(`var a = new Path2D(); new Path2D(a) instanceof Path2D`).(bool), true)
}

// ── XPathEvaluator / document.evaluate ────────────────────────────────────────

@(test)
m157_xpath_evaluator_existe :: proc(t: ^testing.T) {
    testing.expect_value(t, run_m157(`typeof XPathEvaluator`).(string), "function")
    testing.expect_value(t, run_m157(`new XPathEvaluator() instanceof XPathEvaluator`).(bool), true)
    testing.expect_value(t, run_m157(`typeof document.evaluate`).(string), "function")
}

@(test)
m157_xpath_result_constantes :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_m157(`XPathResult.ORDERED_NODE_SNAPSHOT_TYPE`)), f64(7))
    testing.expect_value(t, as_number(run_m157(`XPathResult.FIRST_ORDERED_NODE_TYPE`)), f64(9))
    testing.expect_value(t, as_number(run_m157(`XPathResult.ANY_TYPE`)), f64(0))
}

@(test)
m157_document_evaluate_resultado_vazio :: proc(t: ^testing.T) {
    // A degradação HONESTA: XPath não é avaliado → resultado VAZIO (não inventa nós).
    src := `
        var r = document.evaluate("//div", document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        r.snapshotLength + "|" + (r.snapshotItem(0) === null) + "|" + r.resultType
    `
    testing.expect_value(t, run_m157(src).(string), "0|true|7")
}

@(test)
m157_xpath_iterate_next_null :: proc(t: ^testing.T) {
    src := `
        var r = document.evaluate("//a", document, null, XPathResult.ORDERED_NODE_ITERATOR_TYPE, null);
        (r.iterateNext() === null) + "|" + (r.singleNodeValue === null)
    `
    testing.expect_value(t, run_m157(src).(string), "true|true")
}

@(test)
m157_xpath_create_expression :: proc(t: ^testing.T) {
    src := `
        var e = document.createExpression("//p", null);
        var r = e.evaluate(document, XPathResult.ANY_TYPE, null);
        r.snapshotLength
    `
    testing.expect_value(t, as_number(run_m157(src)), f64(0))
}

@(test)
m157_xpath_evaluator_instancia_avalia :: proc(t: ^testing.T) {
    // `new XPathEvaluator().evaluate(...)` — o caminho por instância.
    src := `
        var ev = new XPathEvaluator();
        var res = ev.createNSResolver(document);
        var r = ev.evaluate("//x", document, res, 7, null);
        r.snapshotLength
    `
    testing.expect_value(t, as_number(run_m157(src)), f64(0))
}
