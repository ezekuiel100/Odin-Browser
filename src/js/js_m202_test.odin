package js

// M202 — `el.children`/`el.childNodes` VIVAS e sem cópia (dom_collection.odin).
// Antes: cada leitura materializava um ^Array novo (O(n) por acesso, coleção
// MORTA). Estes testes fixam as três coisas que a mudança tem de garantir ao
// mesmo tempo:
//   1. VIVACIDADE — uma referência guardada reflete mutações posteriores;
//   2. IDENTIDADE — `el.children === el.children` (é o que prova que não copia);
//   3. COMPATIBILIDADE — o que funcionava quando isto era um ^Array de verdade
//      (spread, for-of, [].slice.call, Array.from, forEach) continua funcionando.
// O item 3 é o que mais importa: trocar Array por objeto host é exatamente o tipo
// de mudança que quebra em SILÊNCIO, devolvendo lista vazia em vez de lançar.
// Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// <body><div id="h"><span></span>texto<!--c--><b></b></div></body>
// De propósito MISTO: children vê 2 (span,b) e childNodes vê 4.
@(private = "file")
build_coll_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    body.attrs = make(map[string]string)

    h := dom.make_node(.Element)
    h.tag = strings.clone("div")
    h.attrs = make(map[string]string)
    dom.set_attr(h, strings.clone("id"), strings.clone("h"))

    sp := dom.make_node(.Element)
    sp.tag = strings.clone("span")
    sp.attrs = make(map[string]string)
    dom.set_attr(sp, strings.clone("id"), strings.clone("um"))

    tx := dom.make_node(.Text);    tx.text = strings.clone("texto")
    cm := dom.make_node(.Comment); cm.text = strings.clone("c")

    b := dom.make_node(.Element)
    b.tag = strings.clone("b")
    b.attrs = make(map[string]string)
    dom.set_attr(b, strings.clone("name"), strings.clone("dois"))

    dom.append_child(h, sp)
    dom.append_child(h, tx)
    dom.append_child(h, cm)
    dom.append_child(h, b)
    dom.append_child(body, h)
    dom.append_child(root, body)
    return root
}

@(private = "file")
coll_run :: proc(src: string) -> string {
    root := build_coll_dom()
    defer dom.free_tree(root)
    r := run_with_dom(src, root)
    s, _ := r.(string)
    return strings.clone(s, context.temp_allocator)
}

// ── 1. vivacidade ───────────────────────────────────────────────────────────

@(test)
test_m202_htmlcollection_viva :: proc(t: ^testing.T) {
    // O check que a sonda marcava como `HTMLCollection live` BAD desde sempre:
    // a referência é capturada ANTES do appendChild e tem de enxergá-lo.
    got := coll_run(`
        var e = document.createElement('div');
        var c = e.children;
        var a0 = c.length;
        e.appendChild(document.createElement('b'));
        var a1 = c.length;
        e.appendChild(document.createElement('i'));
        var a2 = c.length;
        '' + a0 + ',' + a1 + ',' + a2;
    `)
    testing.expect_value(t, got, "0,1,2")
}

@(test)
test_m202_viva_na_remocao_e_no_indice :: proc(t: ^testing.T) {
    // Não basta o length acompanhar: o ÍNDICE também tem de reapontar. Um cache
    // de prefixo mal invalidado passa no teste de length e falha aqui.
    got := coll_run(`
        var h = document.getElementById('h');
        var c = h.children;
        var antes = c[0].tagName;
        h.removeChild(c[0]);
        var depois = c[0].tagName;
        antes + '>' + depois + ':' + c.length;
    `)
    testing.expect_value(t, got, "SPAN>B:1")
}

@(test)
test_m202_viva_com_insercao_no_meio :: proc(t: ^testing.T) {
    // insertBefore no MEIO: o prefixo cacheado (já estendido até o fim pelo
    // length) precisa morrer inteiro, não só crescer no fim.
    got := coll_run(`
        var h = document.getElementById('h');
        var c = h.children;
        var n0 = c.length;            // força o prefixo completo
        var novo = document.createElement('u');
        h.insertBefore(novo, c[1]);
        c[0].tagName + ',' + c[1].tagName + ',' + c[2].tagName + ':' + c.length + '/' + n0;
    `)
    testing.expect_value(t, got, "SPAN,U,B:3/2")
}

@(test)
test_m202_viva_apos_innerhtml :: proc(t: ^testing.T) {
    // innerHTML= passa por detach_or_free_children (outro sítio de mutação, com
    // `clear` em vez de remoção item a item) — o funil tem de bumpar lá também.
    got := coll_run(`
        var h = document.getElementById('h');
        var c = h.children, n = h.childNodes;
        var a = c.length + '/' + n.length;
        h.innerHTML = '<p></p><p></p><p></p>';
        a + ' -> ' + c.length + '/' + n.length;
    `)
    testing.expect_value(t, got, "2/4 -> 3/3")
}

// ── 2. identidade e forma ───────────────────────────────────────────────────

@(test)
test_m202_identidade_estavel :: proc(t: ^testing.T) {
    // `el.children === el.children` é true no navegador — e aqui é a prova de que
    // não se materializa uma coleção nova por acesso (era o custo de
    // `while (i < el.children.length)`).
    got := coll_run(`
        var h = document.getElementById('h');
        '' + (h.children === h.children) + ',' + (h.childNodes === h.childNodes)
           + ',' + (h.children === h.childNodes);
    `)
    testing.expect_value(t, got, "true,true,false")
}

@(test)
test_m202_children_filtra_children_nodes_nao :: proc(t: ^testing.T) {
    got := coll_run(`
        var h = document.getElementById('h');
        h.children.length + ',' + h.childNodes.length + ','
          + h.childNodes[1].nodeType + ',' + h.childNodes[2].nodeType;
    `)
    testing.expect_value(t, got, "2,4,3,8") // texto=3, comentário=8
}

@(test)
test_m202_fora_do_intervalo_e_undefined :: proc(t: ^testing.T) {
    got := coll_run(`
        var h = document.getElementById('h');
        '' + (h.children[9] === undefined) + ',' + (h.children[-1] === undefined)
           + ',' + (h.children.item(9) === null);
    `)
    testing.expect_value(t, got, "true,true,true")
}

@(test)
test_m202_item_e_named_item :: proc(t: ^testing.T) {
    got := coll_run(`
        var h = document.getElementById('h');
        h.children.item(1).tagName + ',' + h.children.namedItem('um').tagName
          + ',' + h.children.namedItem('dois').tagName;
    `)
    testing.expect_value(t, got, "B,SPAN,B") // namedItem casa por id e, depois, por name
}

@(test)
test_m202_instanceof_das_interfaces :: proc(t: ^testing.T) {
    // HTMLCollection/NodeList eram cascas vazias só p/ instanceof não lançar;
    // agora são o prototype de verdade das coleções.
    got := coll_run(`
        var h = document.getElementById('h');
        '' + (h.children instanceof HTMLCollection) + ','
           + (h.childNodes instanceof NodeList) + ','
           + (typeof NodeList.prototype.forEach === 'function');
    `)
    testing.expect_value(t, got, "true,true,true")
}

// ── 3. compatibilidade: o que já funcionava tem de seguir funcionando ───────

@(test)
test_m202_spread_e_for_of :: proc(t: ^testing.T) {
    // Iterar uma coleção passa por Symbol.iterator = Array.prototype.values. Se
    // `values` não fosse genérico a array-like, isto daria lista VAZIA em silêncio.
    got := coll_run(`
        var h = document.getElementById('h');
        var a = [...h.children].map(function(x){ return x.tagName }).join('');
        var b = '';
        for (var x of h.children) b += x.tagName;
        var c = 0;
        for (var y of h.childNodes) c++;
        a + ',' + b + ',' + c;
    `)
    testing.expect_value(t, got, "SPANB,SPANB,4")
}

@(test)
test_m202_slice_call_e_array_from :: proc(t: ^testing.T) {
    // `[].slice.call(el.children)` é O idioma de converter coleção em array em
    // código de site real — o `!ok do return new_array(vm)` do arr_slice antigo
    // teria devolvido [] para todos eles.
    got := coll_run(`
        var h = document.getElementById('h');
        var s = [].slice.call(h.children);
        var f = Array.from(h.children);
        var p = Array.prototype.slice.call(h.childNodes, 1, 3);
        s.length + ',' + f.length + ',' + p.length + ',' + s[0].tagName + f[1].tagName;
    `)
    testing.expect_value(t, got, "2,2,2,SPANB")
}

@(test)
test_m202_metodos_de_array_genericos :: proc(t: ^testing.T) {
    // forEach/map/filter dependem de array_like_has enxergar índices servidos por
    // HOOK; enquanto ele só olhava `props`, a coleção tinha length>0 e nenhum
    // índice "presente" — varria tudo sem visitar nada.
    got := coll_run(`
        var h = document.getElementById('h');
        var n = 0;
        [].forEach.call(h.children, function(){ n++ });
        var m = [].map.call(h.children, function(x){ return x.tagName }).join('-');
        var f = [].filter.call(h.childNodes, function(x){ return x.nodeType === 1 }).length;
        var i = [].indexOf.call(h.children, h.children[1]);
        var j = [].join.call(h.children, '');
        n + ',' + m + ',' + f + ',' + i + ',' + (j.length >= 0);
    `)
    testing.expect_value(t, got, "2,SPAN-B,2,1,true")
}

@(test)
test_m202_nodelist_foreach_nativo :: proc(t: ^testing.T) {
    // NodeList.forEach existe no navegador e é alvo de feature-detect de polyfill.
    got := coll_run(`
        var h = document.getElementById('h');
        var tipos = [];
        h.childNodes.forEach(function(n, i){ tipos.push(i + ':' + n.nodeType) });
        tipos.join(',');
    `)
    testing.expect_value(t, got, "0:1,1:3,2:8,3:1")
}

// ── 4. as APIs de árvore que estavam declaradas e nunca servidas ────────────

@(test)
test_m202_first_last_element_child :: proc(t: ^testing.T) {
    // Eram accessors registrados em Element.prototype que o dom_elem_get NUNCA
    // servia: devolviam undefined calado. É o que fazia a sonda falhar com
    // "reading 'tagName' of undefined".
    got := coll_run(`
        var h = document.getElementById('h');
        h.firstElementChild.tagName + ',' + h.lastElementChild.tagName
          + ',' + h.childElementCount
          + ',' + (document.createElement('div').firstElementChild === null);
    `)
    testing.expect_value(t, got, "SPAN,B,2,true")
}

@(test)
test_m202_element_siblings :: proc(t: ^testing.T) {
    // Pulam texto e comentário (é a diferença para nextSibling/previousSibling).
    got := coll_run(`
        var h = document.getElementById('h');
        var sp = h.children[0], b = h.children[1];
        sp.nextElementSibling.tagName + ',' + b.previousElementSibling.tagName
          + ',' + (b.nextElementSibling === null)
          + ',' + (sp.previousElementSibling === null)
          + ',' + sp.nextSibling.nodeType;
    `)
    testing.expect_value(t, got, "B,SPAN,true,true,3")
}

// ── 5. o custo (o motivo da mudança) ────────────────────────────────────────

@(test)
test_m202_indexacao_repetida_nao_e_quadratica :: proc(t: ^testing.T) {
    // Não dá para cronometrar num teste unitário sem virar flaky, então o que se
    // afere é a PROPRIEDADE observável de onde o custo vinha: cada `el.children`
    // devolvia um objeto NOVO (uma cópia da lista). Se um dia alguém voltar a
    // materializar por acesso, este teste cai junto com o desempenho.
    got := coll_run(`
        var h = document.getElementById('h');
        var iguais = true;
        for (var i = 0; i < 50; i++) if (h.children !== h.children) iguais = false;
        var soma = 0;
        for (var k = 0; k < h.children.length; k++) soma += h.children[k].tagName.length;
        '' + iguais + ',' + soma;
    `)
    testing.expect_value(t, got, "true,5") // SPAN(4) + B(1)
}

@(test)
test_m202_length_sai_dos_contadores_do_dom :: proc(t: ^testing.T) {
    // `length` NÃO varre: vem de n_elem_kids/n_pseudo_kids, mantidos na mutação. O
    // teste amarra os dois lados — se um helper novo do dom esquecer o kid_count, o
    // length passa a divergir da varredura e isto cai.
    got := coll_run(`
        var h = document.getElementById('h');
        var e = document.createElement('div');
        e.innerHTML = '<b></b>texto<i></i><!--c-->';
        var viaLen = e.children.length + '/' + e.childNodes.length;
        var viaVarredura = [].slice.call(e.children).length + '/' + [].slice.call(e.childNodes).length;
        e.insertBefore(document.createElement('u'), e.children[1]);
        e.removeChild(e.children[0]);
        viaLen + ',' + viaVarredura + ',' + e.children.length + '/' + e.childNodes.length
          + ',' + [].slice.call(e.children).length + '/' + [].slice.call(e.childNodes).length;
    `)
    testing.expect_value(t, got, "2/4,2/4,2/4,2/4")
}

@(test)
test_m202_remover_enquanto_le_esvazia :: proc(t: ^testing.T) {
    // O laço `while (el.children.length) el.removeChild(el.children[0])`: muta e lê
    // alternadamente, então é o caso em que um cache com REBUILD completo por
    // mutação voltaria a ser quadrático. Aqui só se verifica que TERMINA e esvazia.
    got := coll_run(`
        var e = document.createElement('div');
        for (var i = 0; i < 40; i++) e.appendChild(document.createElement('b'));
        var voltas = 0;
        while (e.children.length > 0) { e.removeChild(e.children[0]); voltas++; }
        voltas + ',' + e.children.length + ',' + e.childNodes.length;
    `)
    testing.expect_value(t, got, "40,0,0")
}

@(test)
test_m202_indice_absurdo_nao_estoura :: proc(t: ^testing.T) {
    // f64→int em Odin é UB no overflow, e `coll[1e20]` chega como f64. O teto do
    // get_index manda esses para o caminho por NOME, que devolve undefined.
    got := coll_run(`
        var h = document.getElementById('h');
        '' + (h.children[1e20] === undefined) + ',' + (h.children[4294967296] === undefined)
           + ',' + (h.children['x'] === undefined) + ',' + h.children.length
           + ',' + h.children['1'].tagName
           + ',' + (h.children['0abc'] === undefined)   // parse_int aceitaria o prefixo
           + ',' + (h.children['01'] === undefined);    // no JS "01" é prop comum, não índice
    `)
    testing.expect_value(t, got, "true,true,true,2,B,true,true")
}

@(test)
test_m202_host_sem_indice_nao_vira_array_like :: proc(t: ^testing.T) {
    // O relaxamento do array_like_has é condicionado a `geti`, não a `get`: um
    // wrapper host qualquer (classList/style/dataset) tem get-hook e NÃO serve
    // índices — se a condição fosse `get`, o forEach visitaria N undefineds.
    got := coll_run(`
        var h = document.getElementById('h');
        var n = 0;
        [].forEach.call(h.classList, function(){ n++ });
        var m = 0;
        [].forEach.call(h.style, function(){ m++ });
        n + ',' + m;
    `)
    testing.expect_value(t, got, "0,0")
}

// ── 6. o nó sai da árvore debaixo da coleção ────────────────────────────────

@(test)
test_m202_no_desanexado_mantem_a_propria_colecao :: proc(t: ^testing.T) {
    // Padrão real (o do crash do wikipedia): a página guarda referências, o
    // container leva textContent='' e depois alguém lê. Quem tem wrapper JS vivo é
    // DESANEXADO, não liberado — então a coleção do desanexado segue válida e com
    // os filhos DELE, enquanto a do container esvazia. (Escrevi este teste
    // esperando "0" no desanexado; quem estava errado era a expectativa, não o
    // motor: no navegador é exatamente assim.)
    got := coll_run(`
        var h = document.getElementById('h');
        var filho = document.createElement('div');
        filho.appendChild(document.createElement('b'));
        h.appendChild(filho);
        var cf = filho.children, ch = h.children;
        var antes = cf.length + '/' + ch.length;
        h.textContent = '';
        antes + ' -> ' + cf.length + '/' + ch.length + ',' + (filho.parentNode === null);
    `)
    testing.expect_value(t, got, "1/3 -> 1/0,true")
}

@(test)
test_m202_replace_children_esvazia_a_colecao :: proc(t: ^testing.T) {
    // replaceChildren tem caminho de remoção PRÓPRIO (laço de trás p/ frente); se
    // ele escapasse do funil, a coleção guardada seguiria mostrando os filhos velhos.
    got := coll_run(`
        var h = document.getElementById('h');
        var c = h.children;
        var a = c.length;
        h.replaceChildren();
        var b = c.length;
        h.appendChild(document.createElement('i'));
        a + ',' + b + ',' + c.length + ',' + c[0].tagName;
    `)
    testing.expect_value(t, got, "2,0,1,I")
}
