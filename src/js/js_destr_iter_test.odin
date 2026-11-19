package js

import "core:testing"

// ── Destructuring de array por PROTOCOLO de iterador (spec 8.6.2 / 13.15.5.5) ──
// Antes o padrão MATERIALIZAVA o iterador inteiro antes de ligar os nomes:
// `var [x] = it` puxava 1001 valores de um iterador de 1001 (spec: 1), nunca
// chamava return(), e `const [a] = geradorInfinito()` travava até o step_guard.
// Agora cada elemento/buraco puxa UM next(), o rest drena, e o iterador que não
// terminou é fechado (IteratorClose → return()).

// Iterador contador: n = nº de next(), c = nº de return(). `lim` = quantos valores
// entrega antes de done (0 = infinito).
@(private = "file")
ITER_SRC :: `
    var n = 0, c = 0;
    function mk(lim) {
        return { [Symbol.iterator]() { return {
            next() { n++; return (lim && n > lim) ? { value: undefined, done: true } : { value: n, done: false }; },
            return() { c++; return {}; }
        }; } };
    }
`

@(test)
test_destr_iter_puxa_so_o_necessario :: proc(t: ^testing.T) {
    v, _ := run(ITER_SRC + `var [a, b] = mk(1000); a + ':' + b + ':' + n + ':' + c`).(string)
    testing.expectf(t, v == "1:2:2:1", "[a,b] deve puxar 2 next() e fechar 1×: got %v", v)
}

@(test)
test_destr_gerador_infinito :: proc(t: ^testing.T) {
    src := `
        var puxados = 0;
        function* nat() { var i = 0; while (true) { puxados++; yield ++i; } }
        const [a, b] = nat();
        a + ':' + b + ':' + puxados
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1:2:2", "[a,b] = gerador infinito deve puxar só 2: got %v", v)
}

// O iterador que terminou durante o padrão NÃO é fechado; o que não terminou é,
// mesmo que o último valor tenha sido exatamente o último (done ainda não foi visto).
@(test)
test_destr_iter_close_so_se_nao_terminou :: proc(t: ^testing.T) {
    v, _ := run(ITER_SRC + `var [a, b, d] = mk(2); a + ':' + b + ':' + d + ':' + n + ':' + c`).(string)
    testing.expectf(t, v == "1:2:undefined:3:0", "esgotado no padrão: sem return(): got %v", v)
    w, _ := run(ITER_SRC + `var [a] = mk(1); a + ':' + n + ':' + c`).(string)
    testing.expectf(t, w == "1:1:1", "done não visto ainda: fecha 1×: got %v", w)
}

@(test)
test_destr_iter_rest_drena_sem_fechar :: proc(t: ^testing.T) {
    v, _ := run(ITER_SRC + `var [a, ...r] = mk(4); a + ':' + r.join(',') + ':' + n + ':' + c`).(string)
    testing.expectf(t, v == "1:2,3,4:5:0", "rest drena e não fecha: got %v", v)
}

@(test)
test_destr_iter_buraco_consome :: proc(t: ^testing.T) {
    v, _ := run(ITER_SRC + `var [, , x] = mk(0); x + ':' + n + ':' + c`).(string)
    testing.expectf(t, v == "3:3:1", "buraco puxa um next() cada: got %v", v)
}

// O generator abandonado pelo padrão não avança além do que foi puxado, e o seu
// finally roda (via return()). Drenar também rodaria o finally — é o `depois` que
// distingue.
@(test)
test_destr_gerador_finally :: proc(t: ^testing.T) {
    src := `
        var fin = false, depois = false;
        function* g() { try { yield 1; depois = true; yield 2; } finally { fin = true; } }
        var [x] = g();
        x + ':' + depois + ':' + fin
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1:false:true", "generator para no 1º yield e roda o finally: got %v", v)
}

// Default que lança: o iterador é fechado e a exceção ORIGINAL prevalece.
@(test)
test_destr_iter_default_lanca_fecha :: proc(t: ^testing.T) {
    src := ITER_SRC + `
        var meu = new Error('meu'), pego;
        function lanca() { throw meu; }
        try { var [a, b = lanca()] = { [Symbol.iterator]() { return {
            next() { n++; return n === 1 ? { value: 1, done: false } : { value: undefined, done: false }; },
            return() { c++; throw new Error('do return'); }
        }; } }; } catch (e) { pego = e; }
        (pego === meu) + ':' + n + ':' + c
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "true:2:1", "default que lança: fecha e preserva o erro original: got %v", v)
}

// next() que lança: a spec NÃO fecha um iterador que falhou.
@(test)
test_destr_iter_next_lanca_nao_fecha :: proc(t: ^testing.T) {
    src := `
        var c = 0, pego;
        var it = { [Symbol.iterator]() { return {
            next() { throw new RangeError('next'); },
            return() { c++; return {}; }
        }; } };
        try { var [a] = it; } catch (e) { pego = e; }
        (pego instanceof RangeError) + ':' + c
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "true:0", "next() que lança não chama return(): got %v", v)
}

// Sem exceção em voo, return() que devolve primitivo é TypeError.
@(test)
test_destr_iter_return_primitivo :: proc(t: ^testing.T) {
    src := `
        var pego;
        var it = { [Symbol.iterator]() { return {
            next() { return { value: 1, done: false }; },
            return() { return 1; }
        }; } };
        try { var [a] = it; } catch (e) { pego = e; }
        String(pego instanceof TypeError)
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "true", "return() primitivo deve dar TypeError: got %v", v)
}

// Mesmo comportamento na atribuição (`[a, b] = it`) e em parâmetro desestruturado.
@(test)
test_destr_iter_atribuicao_e_parametro :: proc(t: ^testing.T) {
    v, _ := run(ITER_SRC + `var a, b; [a, b] = mk(0); a + ':' + b + ':' + n + ':' + c`).(string)
    testing.expectf(t, v == "1:2:2:1", "atribuição [a,b] = it: got %v", v)
    w, _ := run(ITER_SRC + `function f([x]) { return x; } f(mk(0)) + ':' + n + ':' + c`).(string)
    testing.expectf(t, w == "1:1:1", "parâmetro [x]: got %v", w)
}

// Atribuição: o ALVO (`{}[f()]`, `o[k()]`) é avaliado ANTES do next(); se o alvo
// lança, nenhum next() roda e o iterador é fechado.
@(test)
test_destr_iter_alvo_antes_do_next :: proc(t: ^testing.T) {
    src := ITER_SRC + `
        var log = [], pego;
        var o = {};
        function k(nome) { log.push('alvo' + nome + '@' + n); return nome; }
        [o[k('a')], ...o[k('r')]] = mk(3);
        function lanca() { throw new RangeError('alvo'); }
        var n0 = n, c0 = c;
        try { [ {}[lanca()] ] = mk(0); } catch (e) { pego = e; }
        log.join(',') + '|' + o.a + ':' + o.r.join(',') + '|' + (pego instanceof RangeError) + ':' + (n - n0) + ':' + (c - c0)
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "alvoa@0,alvor@1|1:2,3|true:0:1", "alvo antes do next(); alvo que lança fecha: got %v", v)
}

// Fonte que não se desestrutura lança mesmo com padrão vazio.
@(test)
test_destr_fonte_primitiva_lanca :: proc(t: ^testing.T) {
    src := `
        var r = [];
        function tipo(f) { try { f(); return 'ok'; } catch (e) { return e.name; } }
        r.push(tipo(function(){ var [] = undefined; }));
        r.push(tipo(function(){ [] = null; }));
        r.push(tipo(function(){ var [a] = 5; }));
        r.push(tipo(function(){ var [] = true; }));
        r.push(tipo(function(){ ({} = null); }));
        r.push(tipo(function(){ var {} = 5; }));          // objeto aceita primitivo
        r.push(tipo(function(){ var [a] = "x"; }));       // string é iterável
        r.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "TypeError,TypeError,TypeError,TypeError,TypeError,ok,ok", "fonte primitiva: got %v", v)
}

// A mensagem nomeia a 1ª chave (como o V8): é a pista de QUAL leitura falhou num
// site real (`{ pathname } = undefined`).
@(test)
test_destr_mensagem_nomeia_chave :: proc(t: ^testing.T) {
    src := `
        function msg(f) { try { f(); } catch (e) { return e.message; } return 'ok'; }
        msg(function(){ var { pathname, x } = undefined; }) + '|' +
        msg(function(){ (function({ meta }) {})(null); }) + '|' +
        msg(function(){ var {} = undefined; })
    `
    v, _ := run(src).(string)
    want := "Cannot destructure property 'pathname' of 'undefined' as it is undefined.|" +
            "Cannot destructure property 'meta' of 'null' as it is null.|" +
            "Cannot destructure 'undefined' as it is undefined."
    testing.expectf(t, v == want, "mensagem do destructuring: got %v", v)
}

// Aninhado: o iterador interno é fechado independentemente do externo.
@(test)
test_destr_iter_aninhado :: proc(t: ^testing.T) {
    src := `
        var log = [];
        function mk2(nome) { var i = 0; return { [Symbol.iterator]() { return {
            next() { i++; return { value: nome === 'ext' ? mk2('int' + i) : i, done: false }; },
            return() { log.push(nome); return {}; }
        }; } }; }
        var [[a, b]] = mk2('ext');
        a + ':' + b + ':' + log.join(',')
    `
    v, _ := run(src).(string)
    testing.expectf(t, v == "1:2:int1,ext", "interno fecha antes do externo: got %v", v)
}
