package js

// M48: bugs de memória/concorrência (auditoria 2026-07-08, grupo 2) —
// deadlock de generator reentrante, UAF no dispatch de eventos, strings de
// atributo dom-owned entregues cruas ao JS, double-free de nós owned em
// textContent=/innerHTML=, snapshot no yield* sobre Set/Map, cópia no fn.apply.

import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
build_page :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    form := dom.make_node(.Element)
    form.tag = strings.clone("form")
    inp := dom.make_node(.Element)
    inp.tag = strings.clone("input")
    inp.attrs = make(map[string]string)
    inp.attrs[strings.clone("id")]    = strings.clone("campo")
    inp.attrs[strings.clone("value")] = strings.clone("inicial")
    dom.append_child(form, inp)
    dom.append_child(root, form)
    return root
}

@(private = "file")
expect_true_m48 :: proc(t: ^testing.T, src: string, root: ^dom.Node, msg: string) {
    r := run_with_dom(src, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, msg)
}

// ── generator reentrante: TypeError, não deadlock ────────────────────────────

@(test)
test_gen_reentrante_next :: proc(t: ^testing.T) {
    // it.next() de DENTRO do corpo deadlockava os semáforos p/ SEMPRE (navegador
    // congelava). Agora: TypeError capturável.
    testing.expect_value(t, as_number(run(`
        function* g(){ yield it.next() }
        var it = g();
        var caught = 0;
        try { it.next() } catch (e) { caught = 1 }
        caught`)), f64(1))
}

@(test)
test_gen_reentrante_nao_envenena :: proc(t: ^testing.T) {
    // depois do TypeError o vm continua utilizável e o generator não trava o resto
    testing.expect_value(t, as_number(run(`
        function* g(){ yield it.next(); yield 7 }
        var it = g();
        try { it.next() } catch (e) {}
        function* h(){ yield 42 }
        h().next().value`)), f64(42))
}

// ── dispatch de eventos: handler que muda os listeners do próprio nó ─────────

@(test)
test_dispatch_handler_se_remove :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    // `el.onclick = null` DENTRO do handler fazia delete() do backing sendo
    // iterado (UAF). Agora: dispatch itera snapshot; 2º dispatch não re-dispara.
    expect_true_m48(t, `
        var el = document.getElementById('campo');
        var n = 0;
        el.onclick = function(){ n++; el.onclick = null; };
        el.dispatchEvent('click');
        el.dispatchEvent('click');
        n === 1`,
        root, "handler que se desregistra: roda 1x, sem UAF")
}

@(test)
test_dispatch_handler_adiciona :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    // addEventListener em massa DENTRO do handler realocava a lista sob o for.
    // Snapshot: os novos NÃO disparam no evento corrente (como no browser).
    expect_true_m48(t, `
        var el = document.getElementById('campo');
        var extras = 0;
        el.addEventListener('click', function(){
            for (var i = 0; i < 32; i++) el.addEventListener('click', function(){ extras++; });
        });
        el.dispatchEvent('click');
        var durante = extras;      // novos não rodam no mesmo dispatch
        el.dispatchEvent('click');
        durante === 0 && extras === 32`,
        root, "handlers adicionados durante o dispatch só disparam no próximo")
}

// ── strings de atributo: clonadas p/ o vm, não dom-owned cruas ───────────────

@(test)
test_attr_string_sobrevive_ao_set :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    // padrão do input controlado do React: guardar .value e reescrever depois.
    // Antes: `antes` apontava p/ memória liberada pelo set_attr_str.
    expect_true_m48(t, `
        var el = document.getElementById('campo');
        var antes = el.value;
        var attr  = el.getAttribute('value');
        el.className = 'aa bb';
        var cls = el.className;
        el.value = 'trocado-por-uma-string-bem-mais-comprida';
        el.setAttribute('value', 'de-novo');
        el.className = 'cc';
        antes === 'inicial' && attr === 'inicial' && cls === 'aa bb'`,
        root, ".value/getAttribute/className devem sobreviver à reescrita do atributo")
}

// ── textContent=/innerHTML=: sem double-free de nós owned ────────────────────

@(test)
test_textcontent_libera_no_owned :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    // div de createElement (owned pelo vm) anexada e depois destruída por
    // textContent=. Antes: vm_free → free_orphan_nodes dereferenciava/duplo-liberava.
    expect_true_m48(t, `
        var form = document.getElementById('campo').parentNode;
        var d = document.createElement('div');
        d.appendChild(document.createElement('span'));
        form.appendChild(d);
        form.textContent = 'limpo';
        form.textContent === 'limpo'`,
        root, "textContent= sobre subárvore com nós de createElement: sem double-free no vm_free")
}

@(test)
test_innerhtml_libera_no_owned :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    expect_true_m48(t, `
        var form = document.getElementById('campo').parentNode;
        var d = document.createElement('div');
        d.addEventListener('click', function(){});
        form.appendChild(d);
        form.innerHTML = '<p>novo</p>';
        form.innerHTML.indexOf('novo') >= 0`,
        root, "innerHTML= sobre subárvore com nós de createElement e listeners: sem double-free")
}

@(test)
test_textcontent_preserva_no_referenciado :: proc(t: ^testing.T) {
    root := build_page()
    defer dom.free_tree(root)
    // Padrão do jQuery.buildFragment (RAIZ do erro do wikipedia): captura um filho,
    // esvazia o pai com `textContent=""`, e re-anexa o MESMO nó via appendChild.
    // Antes: textContent= LIBERAVA os filhos → host zerado → appendChild devolvia
    // undefined → `getAll(undefined).getElementsByTagName` → "Cannot read properties
    // of undefined". Agora um filho com wrapper JS vivo é só DESANEXADO, sobrevive, e
    // pode ser re-inserido. Ver [[dom-uaf-wikipedia]].
    expect_true_m48(t, `
        var box = document.createElement('div');
        document.getElementById('campo').parentNode.appendChild(box);
        box.innerHTML = '<span>oi</span>';    // filho vem do PARSER (como no buildFragment)
        var saved = box.firstChild;           // wrapper JS vivo p/ o <span>
        box.textContent = '';                 // esvazia box — no browser real 'saved' SOBREVIVE
        var ret = box.appendChild(saved);     // re-anexa o MESMO nó: NÃO pode ser undefined
        ret === saved && ret.textContent === 'oi' && typeof ret.getElementsByTagName === 'function'`,
        root, "nó referenciado sobrevive a textContent='' do pai e re-anexa (jQuery.buildFragment/wikipedia)")
}

// ── yield* sobre Set/Map: snapshot (mutação com generator suspenso) ──────────

@(test)
test_yield_star_set_mutado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var s = new Set([1, 2]);
        function* g(){ yield* s }
        var it = g();
        var a = it.next().value;                       // 1 (suspende no meio da iteração)
        for (var i = 0; i < 64; i++) s.add(100 + i);   // realoca s.entries
        var b = it.next().value;                       // 2 (do snapshot, não lixo)
        a * 10 + b`)), f64(12))
}

@(test)
test_yield_star_map_mutado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var m = new Map([['a', 1], ['b', 2]]);
        function* g(){ yield* m }
        var it = g();
        var p1 = it.next().value;
        for (var i = 0; i < 64; i++) m.set('k' + i, i);
        var p2 = it.next().value;
        (p1[1] === 1 && p2[0] === 'b' && p2[1] === 2) ? 1 : 0`)), f64(1))
}

// ── fn.apply: args copiados, não alias do array ──────────────────────────────

@(test)
test_apply_default_muta_array :: proc(t: ^testing.T) {
    // default de parâmetro que dá push no MESMO array passado ao apply: o slice
    // aliasado morreria no realloc; com cópia, b continua lendo o valor original.
    testing.expect_value(t, as_number(run(`
        var arr = [undefined, 2];
        function muta(){ for (var i = 0; i < 100; i++) arr.push(i); return 5 }
        function g(a = muta(), b){ return a * 10 + b }
        g.apply(null, arr)`)), f64(52))
}
