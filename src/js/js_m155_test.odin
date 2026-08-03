package js

// M155 — yield* passou a ENCAMINHAR throw()/return()/next(v) ao iterador delegado.
//
// Peel do cluster `(lançou undefined)` do airbnb. A máquina de estado que o
// regenerator-runtime emite p/ `async function` é um generator dirigido por um
// runtime que, quando um await REJEITA, chama `gen.throw(motivo)`. Quando esse
// generator está suspenso num `yield* innerGen()` (idioma de `async f(){ await
// innerAsync() }`), o throw TEM de ser encaminhado a `inner.throw(motivo)` p/ o
// try/catch do inner ver o erro. A implementação antiga só dirigia `next()` e, no
// throw/return, ABANDONAVA o delegado — o erro escapava o try/catch e subia
// (às vezes como undefined). Ver interp.odin:eval_yield_star.
//
// ⚠️ run() NÃO devolve o valor de conclusão de try/catch/finally — guarde numa
// variável e termine COM ELA (lição do M148).

import "core:testing"

// ── throw encaminhado ao delegado ─────────────────────────────────────────────

@(test)
m155_yield_star_encaminha_throw :: proc(t: ^testing.T) {
    // O CASO QUE FALHAVA: outer.throw sobre um yield* inner() tem de cair no
    // catch do INNER, não escapar.
    src := `
        function* inner(){ try { yield 1 } catch(e){ yield "caught:" + e } }
        function* outer(){ yield* inner(); }
        var it = outer(); it.next();
        it.throw("BOOM").value
    `
    testing.expect_value(t, run(src).(string), "caught:BOOM")
}

@(test)
m155_yield_star_throw_sem_metodo_no_delegado :: proc(t: ^testing.T) {
    // FRONTEIRA do fix (documentada): delegar a um GENERATOR sem throw próprio —
    // a máquina cai no throw DEFAULT do generator (roda finally e re-lança), que é
    // o que o regenerator produz. O erro chega ao consumidor (não some).
    src := `
        var r = "?", log = [];
        function* inner(){ try { yield 1; } finally { log.push("in-fin"); } }
        function* outer(){ yield* inner(); }
        var it = outer(); it.next();
        try { it.throw("X"); } catch(e){ r = e; }
        r + "|" + log.join(",")
    `
    // sem catch no inner, o throw default roda o finally e re-lança "X" ao consumidor.
    testing.expect_value(t, run(src).(string), "X|in-fin")
}

@(test)
m155_yield_star_iteravel_nativo_nao_encaminha_throw :: proc(t: ^testing.T) {
    // FRONTEIRA (documentada): `yield* [array]` usa o fast-path nativo (com a
    // lógica de SNAPSHOT do M48 p/ mutação-durante-yield), NÃO um iterador de
    // protocolo — então throw() não é encaminhado, o valor lançado sobe direto.
    // O idioma real (regenerator) delega SEMPRE a generators, então isto não é o
    // caminho do airbnb; fica anotado p/ a diferença ser decisão, não acidente.
    src := `
        var r = "?";
        function* outer(){ yield* [1,2,3]; }
        var it = outer(); it.next();
        try { it.throw("X"); } catch(e){ r = e; }
        r
    `
    testing.expect_value(t, run(src).(string), "X")
}

// ── return encaminhado ao delegado (roda o finally do inner) ──────────────────

@(test)
m155_yield_star_encaminha_return_roda_finally :: proc(t: ^testing.T) {
    // outer.return sobre yield* inner() tem de rodar o finally do inner E o do
    // outer, na ordem inner→outer, e concluir com o valor devolvido.
    src := `
        var log = [];
        function* inner(){ try { yield 1; } finally { log.push("in"); } }
        function* outer(){ try { yield* inner(); } finally { log.push("out"); } }
        var it = outer(); it.next();
        var res = it.return("R");
        log.join(",") + "|" + res.value + "|" + res.done
    `
    testing.expect_value(t, run(src).(string), "in,out|R|true")
}

// ── next(v) encaminhado ao delegado ──────────────────────────────────────────

@(test)
m155_yield_star_encaminha_valor_de_next :: proc(t: ^testing.T) {
    // O valor passado a next(v) tem de chegar ao yield SUSPENSO do inner.
    src := `
        function* inner(){ var a = yield 1; yield "got:" + a; }
        function* outer(){ yield* inner(); }
        var it = outer(); it.next();          // -> {value:1}
        it.next("Z").value                    // envia Z ao yield do inner
    `
    testing.expect_value(t, run(src).(string), "got:Z")
}

// ── contra-caso: delegação normal (só next) segue intacta ─────────────────────

@(test)
m155_yield_star_delegacao_normal_intacta :: proc(t: ^testing.T) {
    src := `
        function* inner(){ yield 2; yield 3; }
        function* outer(){ yield 1; yield* inner(); yield 4; }
        [...outer()].join(",")
    `
    testing.expect_value(t, run(src).(string), "1,2,3,4")
}

@(test)
m155_yield_star_valor_de_retorno_do_delegado :: proc(t: ^testing.T) {
    // `var x = yield* inner()` recebe o RETURN do inner, não undefined.
    src := `
        function* inner(){ yield 1; return "ret"; }
        function* outer(){ var x = yield* inner(); yield "x=" + x; }
        var it = outer(); it.next();          // {value:1}
        it.next().value                        // consome o return do inner -> "x=ret"
    `
    testing.expect_value(t, run(src).(string), "x=ret")
}

// ── yield* em ASYNC GENERATOR: mesmo encaminhamento, cada passo awaitado ──────

@(test)
m155_asyncgen_yield_star_encaminha_throw :: proc(t: ^testing.T) {
    src := `
        var out = "?";
        async function* inner(){ try { yield 1; } catch(e){ yield "caught:" + e; } }
        async function* outer(){ yield* inner(); }
        (async function(){
            var ag = outer();
            await ag.next();
            var r = await ag.throw("BOOM");
            out = r.value;
        })();
        out
    `
    testing.expect_value(t, run(src).(string), "caught:BOOM")
}

@(test)
m155_asyncgen_yield_star_encaminha_return :: proc(t: ^testing.T) {
    src := `
        var log = [];
        async function* inner(){ try { yield 1; } finally { log.push("in"); } }
        async function* outer(){ try { yield* inner(); } finally { log.push("out"); } }
        (async function(){
            var ag = outer();
            await ag.next();
            var r = await ag.return("R");
            log.push("v=" + r.value + ",done=" + r.done);
        })();
        log.join(",")
    `
    testing.expect_value(t, run(src).(string), "in,out,v=R,done=true")
}

@(test)
m155_asyncgen_yield_star_encaminha_next :: proc(t: ^testing.T) {
    src := `
        var out = "?";
        async function* inner(){ var a = yield 1; yield "got:" + a; }
        async function* outer(){ yield* inner(); }
        (async function(){
            var ag = outer();
            await ag.next();
            var r = await ag.next("Z");
            out = r.value;
        })();
        out
    `
    testing.expect_value(t, run(src).(string), "got:Z")
}

@(test)
m155_asyncgen_yield_star_delegacao_normal :: proc(t: ^testing.T) {
    // contra-caso: for-await sobre delegação normal segue intacto.
    src := `
        var out = "?";
        async function* inner(){ yield 2; yield 3; }
        async function* outer(){ yield 1; yield* inner(); yield 4; }
        (async function(){
            var acc = [];
            for await (const x of outer()) acc.push(x);
            out = acc.join(",");
        })();
        out
    `
    testing.expect_value(t, run(src).(string), "1,2,3,4")
}

// ── o padrão regenerator: erro cruzando fronteira async aninhada ──────────────

@(test)
m155_async_aninhado_reencaminha_erro :: proc(t: ^testing.T) {
    // `async outer(){ await inner() }` com inner lançando — o motor delega o
    // throw do runtime pela cadeia de generators. É a forma que o airbnb usa.
    src := `
        var out = "?";
        async function inner(){ throw new Error("boom-async"); }
        async function outer(){ await inner(); }
        (async function(){ try { await outer(); } catch(e){ out = e && e.message; } })();
        out
    `
    testing.expect_value(t, run(src).(string), "boom-async")
}
