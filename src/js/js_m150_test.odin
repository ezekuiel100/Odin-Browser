package js

// M150 — identificador livre NÃO RESOLVIDO agora lança ReferenceError.
//
// Até aqui `eval(.Ident)` devolvia `undefined` quando o nome não estava em
// escopo nem em `window`. Não era só desvio de spec: era um APAGADOR DE SINAL.
// Global ausente virava undefined, seguia adiante, e o erro só aparecia páginas
// depois como `Cannot read properties of undefined (reading 'x')` — sem o nome
// do que faltava. Efeito direto no gap-miner: a seção "Globais/APIs faltando
// (ReferenceError)" do gap-report vivia ESTRUTURALMENTE VAZIA, então uma API
// que a engine não tem nunca entrava no ranking de prioridade.
//
// A isenção da spec é UMA só: `typeof x`. Ela é o idioma universal de detecção
// de feature (`typeof WeakRef === "undefined"`), então tem de continuar sem
// lançar — e por isso os contra-casos abaixo são a parte mais importante do
// arquivo. Os dois caminhos compartilham `lookup_ident` de propósito: um funil
// só é o que impede que divirjam depois.
//
// ⚠️ Nota de ESCRITA de teste (mesma do M148): `run()` NÃO devolve o valor de
// conclusão de um try/catch — todo caso guarda o resultado numa variável e
// termina COM ELA.

import "core:testing"
import "core:strings"
import dom "../dom"

// build_dom do js_dom_test é file-private; um Document mínimo basta aqui — o que
// estes testes exercitam é o objeto WINDOW, não a árvore.
@(private = "file")
m150_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    dom.append_child(root, div)
    return root
}

@(test)
m150_ident_livre_lanca_reference_error :: proc(t: ^testing.T) {
    src := `
        var r = "?";
        try { naoExisteEsteNome }
        catch (e) { r = e.name + ": " + e.message }
        r
    `
    testing.expect_value(t, run(src).(string), "ReferenceError: naoExisteEsteNome is not defined")
}

@(test)
m150_o_nome_que_falta_aparece_na_mensagem :: proc(t: ^testing.T) {
    // É ISTO que torna o gap-report acionável: a mensagem carrega o nome.
    // Sem o nome, o relatório agrega "reading 'x' of undefined" e o gap fica anônimo.
    src := `
        var r = "?";
        try { PerformanceObserver.supportedEntryTypes }
        catch (e) { r = (e.message.indexOf("PerformanceObserver") >= 0) ? "nomeado" : e.message }
        r
    `
    testing.expect_value(t, run(src).(string), "nomeado")
}

@(test)
m150_chamada_de_funcao_inexistente_nomeia_o_ident :: proc(t: ^testing.T) {
    // Antes: o ident virava undefined e o erro saía como "X is not a function"
    // — mensagem que descreve o SINTOMA. Agora nomeia a causa.
    src := `
        var r = "?";
        try { funcaoQueNaoExiste(1, 2) }
        catch (e) { r = e.name + "|" + e.message }
        r
    `
    testing.expect_value(t, run(src).(string), "ReferenceError|funcaoQueNaoExiste is not defined")
}

// ── CONTRA-CASOS: a isenção do typeof ─────────────────────────────────────────

@(test)
m150_typeof_de_ident_ausente_nao_lanca :: proc(t: ^testing.T) {
    // O idioma de detecção de feature. Se este quebrar, TODO site quebra.
    src := `
        var r = "?";
        try { r = typeof NaoExisteNadaDisso } catch (e) { r = "LANCOU:" + e.name }
        r
    `
    testing.expect_value(t, run(src).(string), "undefined")
}

@(test)
m150_typeof_em_guarda_de_feature :: proc(t: ^testing.T) {
    // A forma como o código real escreve — condicional, não expressão solta.
    src := `
        var r = "?";
        if (typeof WeakRefQueNaoTemos === "undefined") { r = "sem-feature" } else { r = "tem" }
        r
    `
    testing.expect_value(t, run(src).(string), "sem-feature")
}

@(test)
m150_typeof_de_ident_existente_intacto :: proc(t: ^testing.T) {
    // A isenção não pode ter virado "typeof sempre devolve undefined".
    src := `
        var x = 10, s = "a", f = function(){};
        typeof x + "|" + typeof s + "|" + typeof f + "|" + typeof Object
    `
    testing.expect_value(t, run(src).(string), "number|string|function|function")
}

@(test)
m150_typeof_de_membro_ainda_lanca :: proc(t: ^testing.T) {
    // A isenção é do ident NU. `typeof a.b` com `a` ausente LANÇA (spec): quem
    // lança é o eval do `a` lá dentro, não o typeof. Se este passar a devolver
    // "undefined", a isenção vazou para dentro da expressão.
    src := `
        var r = "?";
        try { r = typeof baseInexistente.prop } catch (e) { r = e.name }
        r
    `
    testing.expect_value(t, run(src).(string), "ReferenceError")
}

// ── CONTRA-CASOS: o que NÃO pode ter passado a lançar ─────────────────────────

@(test)
m150_variavel_declarada_sem_valor_e_undefined :: proc(t: ^testing.T) {
    // `var x` declarado vale undefined e NÃO lança — a diferença entre
    // "não existe" e "existe valendo undefined" é justamente o ponto do M150.
    src := `
        var x;
        var r = "?";
        try { r = (x === undefined) ? "undef-ok" : "outro" } catch (e) { r = "LANCOU" }
        r
    `
    testing.expect_value(t, run(src).(string), "undef-ok")
}

@(test)
m150_parametro_nao_passado_e_undefined :: proc(t: ^testing.T) {
    // Idioma pesadíssimo em código real: argumento omitido.
    src := `
        function f(a, b) { return (b === undefined) ? "b-undef" : "b-tem" }
        f(1)
    `
    testing.expect_value(t, run(src).(string), "b-undef")
}

@(test)
m150_hoisting_de_funcao_e_var_intacto :: proc(t: ^testing.T) {
    // Nome usado ANTES da declaração textual: hoisting resolve, não é "livre".
    src := `
        var r = usaDepois();
        function usaDepois() { return "hoisted" }
        r
    `
    testing.expect_value(t, run(src).(string), "hoisted")
}

@(test)
m150_prop_de_window_resolve_nua :: proc(t: ^testing.T) {
    // O fallback p/ o objeto global tem de continuar funcionando — é ele que faz
    // `addEventListener(...)` nu achar `window.addEventListener`. Se o M150 tivesse
    // sido escrito só como "não achou → lança", teria matado este caminho.
    vm := vm_create()
    defer vm_destroy(vm)
    w := new_object(vm)
    w.props["minhaCoisaGlobal"] = "achei"
    vm.global.vars["window"] = w
    testing.expect_value(t, vm_run(vm, `minhaCoisaGlobal`).(string), "achei")
}

@(test)
m150_atribuicao_a_nome_novo_nao_lanca :: proc(t: ^testing.T) {
    // Modo NÃO-estrito: `x = 1` sem declarar cria a global (sloppy mode) e não
    // lança. Só a LEITURA de nome livre lança. Como o alvo de atribuição não
    // passa por eval(.Ident), este caminho tinha de ficar intacto — o teste
    // existe para provar isso, não por acaso.
    src := `
        semDeclarar = 7;
        semDeclarar + 1
    `
    testing.expect_value(t, as_number(run(src)), f64(8))
}

@(test)
m150_erro_e_capturavel_e_instanceof :: proc(t: ^testing.T) {
    // Tem de ser um Error de verdade (cadeia de protótipo), não um valor solto:
    // código real faz `catch (e) { if (e instanceof ReferenceError) ... }`.
    src := `
        var r = "?";
        try { nomeLivre }
        catch (e) { r = (e instanceof ReferenceError) + "|" + (e instanceof Error) }
        r
    `
    testing.expect_value(t, run(src).(string), "true|true")
}

// ── globais que o próprio M150 NOMEOU na mineração ────────────────────────────
//
// Estes não são "features novas": são os nomes que a seção *"Globais/APIs
// faltando"* do gap-report cuspiu na PRIMEIRA mineração em que ela deixou de ser
// estruturalmente vazia. Antes do M150 eles viravam undefined e o site seguia
// mancando; depois, viraram ReferenceError que ABORTA o módulo — medido por A/B
// de binário no mesmo instante: `DOMTokenList` custou 66 caixas no ge.globo e
// `NodeList` 35 no apple.com (mesma altura de página, então não é conteúdo
// dinâmico). Servi-los é o que torna o M150 líquido-positivo.

@(test)
m150_top_e_parent_sao_a_propria_janela :: proc(t: ^testing.T) {
    // Sem frames, `top` e `parent` SÃO a janela (spec). Era o global mais faltante
    // do corpus (6 sites) e sustenta o idioma anti-framing abaixo.
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect_value(t, vm_run(vm, `(top === window) + "|" + (parent === window)`).(string), "true|true")
    testing.expect_value(t, vm_run(vm, `(window.top === window.self) ? "mesma" : "em-frame"`).(string), "mesma")
}

@(test)
m150_interfaces_orfas_existem_e_tem_prototype :: proc(t: ^testing.T) {
    // O que o código real faz com elas: feature-detect no .prototype e instanceof.
    // Não basta existir — sem `.prototype` o polyfill quebra na linha seguinte.
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    src := `
        var faltando = [];
        var nomes = ["NodeList","HTMLCollection","DOMTokenList","DOMException",
                     "CSSStyleSheet","Attr","HTMLMediaElement","Window"];
        for (var i = 0; i < nomes.length; i++) {
            var g = window[nomes[i]];
            if (!g || !g.prototype) faltando.push(nomes[i]);
        }
        faltando.join(",")
    `
    testing.expect_value(t, vm_run(vm, src).(string), "")
}

@(test)
m150_padrao_de_polyfill_no_prototype_funciona :: proc(t: ^testing.T) {
    // O idioma exato do polyfill de NodeList.forEach, que é o que o apple.com faz.
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    src := `
        var r = "?";
        try {
            if (!NodeList.prototype.forEach) { NodeList.prototype.forEach = Array.prototype.forEach }
            r = "ok"
        } catch (e) { r = "LANCOU:" + e.name }
        r
    `
    testing.expect_value(t, vm_run(vm, src).(string), "ok")
}

@(test)
m150_window_instanceof_window :: proc(t: ^testing.T) {
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect(t, truthy(vm_run(vm, `window instanceof Window`)), "window deve ser instanceof Window")
}

@(test)
m150_has_child_nodes :: proc(t: ^testing.T) {
    // `hasChildNodes` NÃO EXISTIA. Não foi achado por leitura de spec: caiu da
    // BISSECÇÃO por flag de compilação. Servir a casca de `NodeList` fez o bundle
    // do mercadolivre avançar até a hidratação do React, que chama
    // `ref.current.hasChildNodes()` — o "is not a function" ali desmontava a
    // subárvore. Medido: 688 -> 1036 caixas (acima do 1028 de antes do M150).
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    src := `
        var vazio = document.createElement("div");
        var cheio = document.createElement("div");
        cheio.appendChild(document.createTextNode("x"));
        (vazio.hasChildNodes() === false) + "|" + (cheio.hasChildNodes() === true)
    `
    // ambas as comparações devem dar TRUE (vazio→false, cheio→true).
    testing.expect_value(t, vm_run(vm, src).(string), "true|true")
}

@(test)
m150_html_meta_element_e_subtipos_novos :: proc(t: ^testing.T) {
    // Segunda leva de interfaces nomeadas pelo gap-report (coingecko pediu
    // HTMLMetaElement). O que importa não é só o global existir: a TAG tem de
    // mapear para o prototype certo, senão `el instanceof HTMLMetaElement` mente.
    root := m150_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    src := `
        var erros = [];
        var pares = [["meta","HTMLMetaElement"], ["title","HTMLTitleElement"],
                     ["tr","HTMLTableRowElement"], ["td","HTMLTableCellElement"],
                     ["video","HTMLVideoElement"], ["progress","HTMLProgressElement"]];
        for (var i = 0; i < pares.length; i++) {
            var el = document.createElement(pares[i][0]);
            var iface = window[pares[i][1]];
            if (typeof iface !== "function") { erros.push(pares[i][1] + ":ausente"); continue }
            if (!(el instanceof iface)) { erros.push(pares[i][1] + ":instanceof") }
            if (!(el instanceof HTMLElement)) { erros.push(pares[i][1] + ":nao-e-HTMLElement") }
        }
        erros.join(",")
    `
    testing.expect_value(t, vm_run(vm, src).(string), "")
}
