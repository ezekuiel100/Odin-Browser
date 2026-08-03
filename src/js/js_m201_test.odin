package js

// M201 — MutationObserver REAL. Antes: observe/disconnect no-op, callback nunca
// disparava, takeRecords sempre []. Estes testes cobrem as três famílias de
// mutação (childList/attributes/characterData), o MOMENTO da entrega (fim de
// tarefa, não síncrono), o alcance (subtree/attributeFilter) e a armadilha de
// memória do nó removido. Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// <body><div id="h"><span id="s">oi</span></div></body> sob um Document.
@(private = "file")
build_mo_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    body.attrs = make(map[string]string)

    h := dom.make_node(.Element)
    h.tag = strings.clone("div")
    h.attrs = make(map[string]string)
    // por dom.set_attr, NÃO escrevendo no map direto: é o set_attr que mantém o
    // attr_order em sincronia, e sem ele o removeAttribute não acha a chave dona.
    dom.set_attr(h, strings.clone("id"), strings.clone("h"))

    s := dom.make_node(.Element)
    s.tag = strings.clone("span")
    s.attrs = make(map[string]string)
    dom.set_attr(s, strings.clone("id"), strings.clone("s"))
    txt := dom.make_node(.Text)
    txt.text = strings.clone("oi")

    dom.append_child(s, txt)
    dom.append_child(h, s)
    dom.append_child(body, h)
    dom.append_child(root, body)
    return root
}

// Roda `src` e devolve o valor como string (a maioria dos testes monta uma
// string-resumo em JS e compara com expect_value).
@(private = "file")
mo_run :: proc(src: string) -> string {
    root := build_mo_dom()
    defer dom.free_tree(root)
    r := run_with_dom(src, root)
    s, _ := r.(string)
    return strings.clone(s, context.temp_allocator)
}

// ── entrega: o que a página vê e QUANDO ─────────────────────────────────────

@(test)
test_mo_childlist_dispara :: proc(t: ^testing.T) {
    // O caso que a sonda acusava como `records=0` desde sempre.
    got := mo_run(`
        var h = document.getElementById('h'), r = null;
        var mo = new MutationObserver(function(recs){ r = recs });
        mo.observe(h, { childList: true });
        h.appendChild(document.createElement('b'));
        // o callback ainda NÃO rodou aqui; takeRecords vê a fila (spec: síncrono)
        var q = mo.takeRecords();
        q.length + '|' + q[0].type + '|' + q[0].target.id + '|' +
            q[0].addedNodes.length + '|' + q[0].addedNodes[0].tagName
    `)
    testing.expect_value(t, got, "1|childList|h|1|B")
}

@(test)
test_mo_entrega_no_fim_da_tarefa_nao_sincrona :: proc(t: ^testing.T) {
    // A fidelidade que mais importa: o callback NÃO roda no meio da mutação
    // (senão um observer que muta o DOM recursionaria) — roda no fim da tarefa.
    // Dois vm_run no MESMO vm: o 1º é a tarefa, o 2º só lê o resultado.
    root := build_mo_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        var mo = new MutationObserver(function(){ log += 'cb;' });
        mo.observe(document.getElementById('h'), { childList: true });
        document.getElementById('h').appendChild(document.createElement('b'));
        log += 'sync;';
    `)
    r := vm_run(vm, `log`)
    s, _ := r.(string)
    testing.expect_value(t, s, "sync;cb;")
}

@(test)
test_mo_dispatch_aninhado_nao_entrega_no_meio :: proc(t: ^testing.T) {
    // A spec só roda o checkpoint com a PILHA VAZIA. Um dispatchEvent disparado
    // de dentro do script (que é uma tarefa) não pode drenar a fila da tarefa de
    // fora — senão o callback rodaria reentrante, no meio do código da página.
    root := build_mo_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        var h = document.getElementById('h');
        h.addEventListener('ping', function () { log += 'handler;' });
        var mo = new MutationObserver(function () { log += 'cb;' });
        mo.observe(h, { childList: true });
        h.appendChild(document.createElement('b'));  // enfileira um record
        h.dispatchEvent('ping');                     // tarefa ANINHADA: não pode entregar
        log += 'fim;';
    `)
    r := vm_run(vm, `log`)
    s, _ := r.(string)
    testing.expect_value(t, s, "handler;fim;cb;")
}

@(test)
test_mo_take_records_esvazia_a_fila :: proc(t: ^testing.T) {
    // takeRecords drena: o callback do fim da tarefa não pode receber de novo.
    root := build_mo_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0;
        var mo = new MutationObserver(function(recs){ n += recs.length });
        mo.observe(document.getElementById('h'), { childList: true });
        document.getElementById('h').appendChild(document.createElement('b'));
        var tomados = mo.takeRecords().length;
    `)
    r := vm_run(vm, `tomados + '|' + n`)
    s, _ := r.(string)
    testing.expect_value(t, s, "1|0")
}

// ── remoção ────────────────────────────────────────────────────────────────

@(test)
test_mo_remocao_com_irmaos :: proc(t: ^testing.T) {
    got := mo_run(`
        var h = document.getElementById('h');
        h.appendChild(document.createElement('i'));   // <span>, <i>
        h.appendChild(document.createElement('u'));   // <span>, <i>, <u>
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true });
        h.removeChild(h.children[1]);                 // tira o <i> do meio
        var q = mo.takeRecords();
        q.length + '|' + q[0].removedNodes[0].tagName + '|' +
            q[0].previousSibling.tagName + '|' + q[0].nextSibling.tagName
    `)
    testing.expect_value(t, got, "1|I|SPAN|U")
}

@(test)
test_mo_textcontent_nao_libera_no_observado :: proc(t: ^testing.T) {
    // ARMADILHA DE MEMÓRIA: `textContent=''` libera na hora todo filho SEM
    // wrapper JS vivo (detach_or_free_children). O record segura o nó removido,
    // então ler `.tagName` dele depois só é válido porque o wrap_element feito ao
    // montar o record o preservou. Se a ordem em detach_or_free_children inverter,
    // isto vira leitura de memória liberada.
    got := mo_run(`
        var h = document.getElementById('h');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true });
        h.textContent = 'zerado';
        var q = mo.takeRecords();
        // um record da limpeza (removed) e outro do nó de texto novo (added)
        var rem = null, add = null;
        for (var i = 0; i < q.length; i++) {
            if (q[i].removedNodes.length) rem = q[i];
            if (q[i].addedNodes.length) add = q[i];
        }
        rem.removedNodes.length + '|' + rem.removedNodes[0].tagName + '|' +
            (add ? add.addedNodes[0].nodeType : 'sem-add') + '|' + h.textContent
    `)
    testing.expect_value(t, got, "1|SPAN|3|zerado")
}

@(test)
test_mo_innerhtml_gera_removidos_e_adicionados :: proc(t: ^testing.T) {
    got := mo_run(`
        var h = document.getElementById('h');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true });
        h.innerHTML = '<p></p><p></p>';
        var q = mo.takeRecords();
        var rem = 0, add = 0;
        for (var i = 0; i < q.length; i++) { rem += q[i].removedNodes.length; add += q[i].addedNodes.length }
        rem + '|' + add + '|' + h.children.length
    `)
    testing.expect_value(t, got, "1|2|2")
}

// ── atributos ──────────────────────────────────────────────────────────────

@(test)
test_mo_atributo_com_old_value :: proc(t: ^testing.T) {
    got := mo_run(`
        var s = document.getElementById('s');
        var mo = new MutationObserver(function(){});
        mo.observe(s, { attributes: true, attributeOldValue: true });
        s.setAttribute('data-x', 'novo');   // atributo NOVO: oldValue null
        s.setAttribute('id', 'trocado');    // existia: oldValue 's'
        var q = mo.takeRecords();
        q.length + '|' + q[0].type + '|' + q[0].attributeName + '|' + q[0].oldValue +
            '|' + q[1].attributeName + '|' + q[1].oldValue
    `)
    testing.expect_value(t, got, "2|attributes|data-x|null|id|s")
}

@(test)
test_mo_sem_old_value_nao_vaza :: proc(t: ^testing.T) {
    // oldValue é POR OBSERVADOR: quem não pediu attributeOldValue vê null.
    got := mo_run(`
        var s = document.getElementById('s'), a = null, b = null;
        var m1 = new MutationObserver(function(){}); m1.observe(s, { attributes: true });
        var m2 = new MutationObserver(function(){}); m2.observe(s, { attributes: true, attributeOldValue: true });
        s.setAttribute('id', 'z');
        a = m1.takeRecords()[0]; b = m2.takeRecords()[0];
        String(a.oldValue) + '|' + String(b.oldValue)
    `)
    testing.expect_value(t, got, "null|s")
}

@(test)
test_mo_attribute_filter :: proc(t: ^testing.T) {
    // `{attributeFilter:['class']}` SEM `attributes:true` é o idioma real das
    // páginas — o filtro implica attributes (spec).
    got := mo_run(`
        var s = document.getElementById('s');
        var mo = new MutationObserver(function(){});
        mo.observe(s, { attributeFilter: ['class'] });
        s.setAttribute('data-x', '1');   // fora do filtro: ignorado
        s.className = 'azul';            // reflexo de propriedade, não setAttribute
        var q = mo.takeRecords();
        q.length + '|' + q[0].attributeName
    `)
    testing.expect_value(t, got, "1|class")
}

@(test)
test_mo_style_e_remocao_de_atributo :: proc(t: ^testing.T) {
    // el.style.cor e removeAttribute também passam pelo funil de atributo.
    got := mo_run(`
        var s = document.getElementById('s');
        var mo = new MutationObserver(function(){});
        mo.observe(s, { attributes: true });
        s.style.color = 'red';
        s.removeAttribute('id');
        var q = mo.takeRecords();
        q.length + '|' + q[0].attributeName + '|' + q[1].attributeName + '|' + s.hasAttribute('id')
    `)
    testing.expect_value(t, got, "2|style|id|false")
}

// ── characterData ──────────────────────────────────────────────────────────

@(test)
test_mo_character_data :: proc(t: ^testing.T) {
    // A escrita em `.data` de um Text NÃO existia (caía no set genérico e sumia);
    // sem ela `characterData:true` seria uma opção que nunca dispara.
    got := mo_run(`
        var tn = document.getElementById('s').firstChild;
        var mo = new MutationObserver(function(){});
        mo.observe(tn, { characterData: true, characterDataOldValue: true });
        tn.data = 'tchau';
        var q = mo.takeRecords();
        q.length + '|' + q[0].type + '|' + q[0].oldValue + '|' + tn.data +
            '|' + document.getElementById('s').textContent
    `)
    testing.expect_value(t, got, "1|characterData|oi|tchau|tchau")
}

// ── alcance ────────────────────────────────────────────────────────────────

@(test)
test_mo_subtree :: proc(t: ^testing.T) {
    // Sem subtree, mutação no NETO não chega ao observador da raiz.
    got := mo_run(`
        var h = document.getElementById('h'), s = document.getElementById('s');
        var raso = new MutationObserver(function(){}); raso.observe(h, { childList: true });
        var fundo = new MutationObserver(function(){}); fundo.observe(h, { childList: true, subtree: true });
        s.appendChild(document.createElement('b'));   // dentro do <span>, não do <div>
        raso.takeRecords().length + '|' + fundo.takeRecords().length
    `)
    testing.expect_value(t, got, "0|1")
}

@(test)
test_mo_um_record_por_observador :: proc(t: ^testing.T) {
    // Dois registros do MESMO observador casando a mesma mutação = UM record.
    got := mo_run(`
        var h = document.getElementById('h'), s = document.getElementById('s');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true, subtree: true });
        mo.observe(s, { childList: true });
        s.appendChild(document.createElement('b'));
        String(mo.takeRecords().length)
    `)
    testing.expect_value(t, got, "1")
}

@(test)
test_mo_disconnect_para_de_gravar :: proc(t: ^testing.T) {
    got := mo_run(`
        var h = document.getElementById('h');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true });
        h.appendChild(document.createElement('b'));
        mo.disconnect();                                   // spec: também esvazia a fila
        var depoisDoDisconnect = mo.takeRecords().length;
        h.appendChild(document.createElement('i'));
        depoisDoDisconnect + '|' + mo.takeRecords().length + '|' + h.children.length
    `)
    testing.expect_value(t, got, "0|0|3")
}

@(test)
test_mo_observar_o_mesmo_alvo_substitui :: proc(t: ^testing.T) {
    // Segundo observe() no mesmo alvo TROCA as opções (spec) — não acumula.
    got := mo_run(`
        var h = document.getElementById('h');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { attributes: true });
        mo.observe(h, { childList: true });   // agora só childList
        h.setAttribute('data-x', '1');
        h.appendChild(document.createElement('b'));
        var q = mo.takeRecords();
        q.length + '|' + q[0].type
    `)
    testing.expect_value(t, got, "1|childList")
}

// ── contrato do construtor / opções ────────────────────────────────────────

@(test)
test_mo_observe_sem_opcao_util_lanca :: proc(t: ^testing.T) {
    got := mo_run(`
        var e1 = '', e2 = '';
        try { new MutationObserver(function(){}).observe(document.body, {}) } catch (e) { e1 = e.name }
        try { new MutationObserver(123) } catch (e) { e2 = e.name }
        e1 + '|' + e2
    `)
    testing.expect_value(t, got, "TypeError|TypeError")
}

// ── guarda de regressão do funil ───────────────────────────────────────────

@(test)
test_mo_sem_observador_a_arvore_continua_certa :: proc(t: ^testing.T) {
    // O funil (detach/mo_insert) reescreveu appendChild/insertBefore/replaceChild/
    // prepend/before/after/replaceWith/replaceChildren. Sem nenhum observador, a
    // ÁRVORE tem de sair idêntica ao que saía antes — este é o teste que pega um
    // erro de índice introduzido pela troca de `inject_at` por `mo_insert`.
    got := mo_run(`
        var h = document.getElementById('h');
        var s = document.getElementById('s');
        var a = document.createElement('a'); a.id = 'a';
        var b = document.createElement('b'); b.id = 'b';
        var c = document.createElement('c'); c.id = 'c';
        h.insertBefore(a, s);        // a, span
        h.appendChild(b);            // a, span, b
        s.before(c);                 // a, c, span, b
        var ordem = '';
        for (var i = 0; i < h.children.length; i++) ordem += h.children[i].tagName;
        h.replaceChild(document.createElement('d'), s);   // a, c, d, b
        var ordem2 = '';
        for (var i = 0; i < h.children.length; i++) ordem2 += h.children[i].tagName;
        ordem + '|' + ordem2
    `)
    testing.expect_value(t, got, "ACSPANB|ACDB")
}

@(test)
test_mo_insercao_no_indice_certo_com_observador :: proc(t: ^testing.T) {
    // O mesmo com observador ligado: o record não pode alterar a POSIÇÃO.
    got := mo_run(`
        var h = document.getElementById('h'), s = document.getElementById('s');
        var mo = new MutationObserver(function(){});
        mo.observe(h, { childList: true, subtree: true });
        h.prepend(document.createElement('a'));
        h.insertBefore(document.createElement('i'), s);
        var ordem = '';
        for (var i = 0; i < h.children.length; i++) ordem += h.children[i].tagName;
        ordem + '|' + mo.takeRecords().length
    `)
    testing.expect_value(t, got, "AISPAN|2")
}
