package js

// M141 — innerHTML / insertAdjacentHTML passaram a usar o parser de FRAGMENTO de
// spec (htmlp.parse_fragment) em vez do htmlp.parse legado. O comportamento
// depende do elemento de CONTEXTO, exatamente como no navegador. Estes testes
// exercitam o caminho REAL do setter (dom_bindings.odin), lendo de volta pela
// API do DOM — não pela suíte html5lib (que mede o parser diretamente).

import "core:testing"
import dom "../dom"
import "core:strings"

@(private = "file")
run_dom141 :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── tbody implícito: a maior perda do parser legado em página real ──

@(test)
m141_innerhtml_table_sintetiza_tbody :: proc(t: ^testing.T) {
    // `table.innerHTML='<tr><td>x'` deve inserir <tbody> em volta do <tr> —
    // com o parser legado a árvore era table>tr>td e qualquer CSS/JS que
    // esperasse table>tbody>tr falhava. Contexto = <table>.
    src := `
        var tbl = document.createElement("table");
        tbl.innerHTML = "<tr><td>x</td></tr>";
        var f = tbl.firstChild;
        (f && f.tagName.toLowerCase() === "tbody"
            && f.firstChild.tagName.toLowerCase() === "tr") ? "ok"
            : ("primeiro=" + (f ? f.tagName : "nil"))
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}

@(test)
m141_innerhtml_tbody_aceita_tr_solto :: proc(t: ^testing.T) {
    // contexto <tbody>: um <tr> solto sobrevive (modo InRow). No documento
    // inteiro um <tr> no topo seria ignorado — é o ponto do contexto.
    src := `
        var tb = document.createElement("tbody");
        tb.innerHTML = "<tr><td>a</td></tr>";
        (tb.childNodes.length === 1
            && tb.firstChild.tagName.toLowerCase() === "tr") ? "ok"
            : ("filhos=" + tb.childNodes.length)
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}

// ── adoption agency: HTML malformado não perde a formatação ──

@(test)
m141_innerhtml_adoption_agency :: proc(t: ^testing.T) {
    // `<b>bold<i>both</b>ital</i>` — sem adoption agency (parser legado) o
    // "ital" saía do <i> e perdia o itálico. Agora o segundo <i> é
    // reconstruído como irmão do <b>, contendo "ital".
    src := `
        var d = document.createElement("div");
        d.innerHTML = "<p>a<b>bold<i>both</b>ital</i>end</p>";
        var p = d.firstChild;
        // p deve ter: "a", <b>, <i>ital</i>, "end"
        var i2 = null;
        for (var k = 0; k < p.childNodes.length; k++) {
            var c = p.childNodes[k];
            if (c.tagName && c.tagName.toLowerCase() === "i") i2 = c;
        }
        // pega o ÚLTIMO <i> (o reconstruído) e confere que contém "ital"
        (i2 && i2.textContent === "ital") ? "ok"
            : ("i2=" + (i2 ? i2.textContent : "nil"))
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}

// ── div continua descartando tags de tabela (contexto certo, não "sempre body") ──

@(test)
m141_innerhtml_div_descarta_tr :: proc(t: ^testing.T) {
    // MESMO input do primeiro teste, contexto <div>: as tags de tabela são
    // descartadas e sobra só o texto. Prova que o contexto está sendo usado,
    // não um modo fixo.
    src := `
        var d = document.createElement("div");
        d.innerHTML = "<tr><td>x</td></tr>";
        (d.childNodes.length === 1 && d.firstChild.nodeType === 3
            && d.textContent === "x") ? "ok"
            : ("filhos=" + d.childNodes.length + " txt=" + d.textContent)
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}

// ── insertAdjacentHTML: contexto por posição ──

@(test)
m141_insert_adjacent_html_beforebegin_usa_pai :: proc(t: ^testing.T) {
    // beforebegin insere IRMÃOS do alvo → contexto é o PAI. Com o alvo dentro de
    // uma <table>, um <tr> injetado antes dele deve virar tbody>tr, não ser
    // descartado. Monta uma tabela com um <tbody> alvo e injeta antes dele.
    src := `
        var tbl = document.createElement("table");
        tbl.innerHTML = "<tbody id='alvo'><tr><td>x</td></tr></tbody>";
        var alvo = tbl.firstChild;
        alvo.insertAdjacentHTML("beforebegin", "<tbody><tr><td>y</td></tr></tbody>");
        // agora a tabela tem 2 tbodys
        var n = 0;
        for (var k = 0; k < tbl.childNodes.length; k++)
            if (tbl.childNodes[k].tagName &&
                tbl.childNodes[k].tagName.toLowerCase() === "tbody") n++;
        (n === 2) ? "ok" : ("tbodys=" + n)
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}

// ── template.innerHTML continua alimentando o content fragment ──

@(test)
m141_template_innerhtml_vai_para_content :: proc(t: ^testing.T) {
    src := `
        var tp = document.createElement("template");
        tp.innerHTML = "<b>um</b><i>dois</i>";
        (tp.content && tp.content.childNodes.length === 2
            && tp.content.firstChild.tagName.toLowerCase() === "b") ? "ok"
            : ("content=" + (tp.content ? tp.content.childNodes.length : "nil"))
    `
    testing.expect_value(t, run_dom141(src).(string), "ok")
}
