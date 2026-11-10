package js

// M209 — os três defeitos que mantinham o github.com sem JS nenhum, achados a
// partir do stderr de uma carga da HOME (10 bundles rspack, `type="module"`).
//
// O stderr trazia 6 linhas; **duas** eram causa e o resto era colateral:
//
//   [js] import estático falhou: ./behaviors-….js (avaliação do módulo lançou)
//   [js] TypeError: Cannot read properties of undefined (reading 'initial')      ← A
//   [js] TypeError: Cannot read properties of undefined (reading '__rspack_esm_ids') ← C
//   [js] import estático falhou: ./landing-pages-….js (avaliação do módulo lançou)
//   [js] TypeError: Promise.withResolvers is not a function                      ← B
//   [js] TypeError: Cannot read properties of undefined (reading '__rspack_esm_ids') ← C
//
// A) `var x;` SEM inicializador APAGAVA um binding que já tinha valor. A spec diz o
//    contrário (VariableDeclaration : BindingIdentifier → "Return empty"): quem cria o
//    binding é o hoisting, e o statement em si não faz nada. O minificador põe o `var`
//    no FIM do módulo, então o enum de TypeScript do Turbo era montado e logo perdido:
//        (eT = eV || (eV = {}))[eT.initial = 0] = "initial";  …
//        class et { constructor(){ this.stage = eV.initial } }
//        var eS, eE, /*…*/ eV, eN = Object.freeze({…});   // ← zerava eV
//
// B) `Promise.withResolvers` (ES2024) não existia. O landing-pages morre na 1ª linha.
//
// C) `<script type="module" src=U>` rodava FORA do registry de módulos. O rspack fecha
//    todo bundle com um AUTO-IMPORT (`import * as C from "./este-mesmo.js"; e.C(C)`)
//    — sem a URL registrada isso não batia no cache e BAIXAVA + REAVALIAVA o bundle
//    inteiro. Medido no github.com: os 8 bundles de entrada avaliados 2× (incluindo o
//    landing-pages de 2,6 MB). E quando a 2ª avaliação lançava (por A ou B), o `import
//    * as` bindava undefined e o runtime lia `.__rspack_esm_ids` dele — que é o
//    colateral acima, não uma causa. Repro em HTTP local confirmou os 2 GET / 2
//    avaliações antes, 1 e 1 depois.
//
// Os valores esperados de A e B foram conferidos linha a linha contra o Chrome
// headless (25 checagens, `--dump-dom`): 24 batiam e a única divergência era
// `promise instanceof Promise`, gap ANTIGO e geral (valia p/ `new Promise` também) —
// fechado aqui junto, ver a última seção.

import "core:strings"
import "core:testing"

@(private = "file")
val :: proc(expr: string) -> string {
    src := strings.concatenate({
        `(function(){ try { return String(`, expr,
        `) } catch (e) { return "<throw> " + e.message } })()`,
    }, context.temp_allocator)
    v := run(src)
    s, ok := v.(string)
    if !ok do return "<nao-string>"
    return s
}

// ── A: `var x;` sem inicializador é NO-OP ────────────────────────────────────

@(test)
m209_var_sem_init_nao_apaga :: proc(t: ^testing.T) {
    // a forma exata do bug: atribuição ANTES, `var` depois (o minificador junta
    // todos os `var` do módulo no fim)
    testing.expect_value(t, val(`(function(){ A = {v:1}; var A; return JSON.stringify(A) })()`), `{"v":1}`)
    // o enum de TypeScript que o Turbo emite, reduzido
    testing.expect_value(t, val(`(function(){ E = {}; E.initial = 0; var D, E; return E.initial })()`), "0")
    // declarador VIZINHO não pode ser afetado nem por dentro nem por fora
    testing.expect_value(t, val(`(function(){ A = 1; var A, B; return String(B) })()`), "undefined")
    testing.expect_value(t, val(`(function(){ A = 1; var A, C = 9; return C })()`), "9")
    // no escopo de topo vale o mesmo (implicit global + `var` do mesmo nome)
    testing.expect_value(t, val(`(function(){ Z = 5; return (function(){ return Z })() })()`), "5")
    // `var` dentro de bloco/if/catch é function-scoped e igualmente no-op
    testing.expect_value(t, val(`(function(){ A = 5; { var A } return A })()`), "5")
    testing.expect_value(t, val(`(function(){ A = 5; if (true) { var A } return A })()`), "5")
    testing.expect_value(t, val(`(function(){ A = 7; try { throw 1 } catch (e) { var A } return A })()`), "7")
    // redeclaração repetida também
    testing.expect_value(t, val(`(function(){ var A = 3; var A; var A; return A })()`), "3")
}

@(test)
m209_var_COM_init_continua_atribuindo :: proc(t: ^testing.T) {
    // CONTROLE do fix: o no-op é só p/ o `var` SEM inicializador. Se o teste acima
    // tivesse sido implementado como "todo var é no-op", estes falhariam.
    testing.expect_value(t, val(`(function(){ A = 1; var A = 2; return A })()`), "2")
    testing.expect_value(t, val(`(function(){ A = 1; var A = undefined; return String(A) })()`), "undefined")
    testing.expect_value(t, val(`(function(){ var Q; return String(Q) })()`), "undefined") // 1º uso: define
}

@(test)
m209_var_nao_toca_parametro_nem_sombra :: proc(t: ^testing.T) {
    // `function f(p){ var p }` mantém o argumento (o binding do parâmetro já existe)
    testing.expect_value(t, val(`(function(p){ var p; return p })("mantido")`), "mantido")
    testing.expect_value(t, val(`(function(p){ var p = "novo"; return p })("velho")`), "novo")
    // …mas um `var` que ainda NÃO existe naquele escopo continua criando (sombra):
    // o interno não pode enxergar o externo
    testing.expect_value(t, val(`(function(){ var S = "outer"; return (function(){ var S; return String(S) })() })()`), "undefined")
}

@(test)
m209_var_em_laco_persiste_e_let_reinicia :: proc(t: ^testing.T) {
    // `var V` na 2ª volta é no-op ⇒ o valor da 1ª sobrevive…
    testing.expect_value(t, val(`(function(){ var k=[]; for (var j=0;j<2;j++){ var V; k.push(String(V)); V=j } return k.join(",") })()`),
        "undefined,0")
    // …e `let` (que NÃO é n.aux) tem de continuar reinicializando a cada iteração.
    // É o controle que impede o fix de vazar p/ let/const.
    testing.expect_value(t, val(`(function(){ var k=[]; for (var j=0;j<2;j++){ let L; k.push(String(L)); L=j } return k.join(",") })()`),
        "undefined,undefined")
}

@(test)
m209_var_nao_apaga_funcao_icada :: proc(t: ^testing.T) {
    // declaração de função é içada COM o valor; um `var f` depois não pode zerá-la
    // (é a mesma cláusula da spec, e o caso que mais dói: `f is not a function`).
    testing.expect_value(t, val(`(function(){ var r = typeof f; function f(){}; var f; return r + "," + typeof f })()`),
        "function,function")
}

// ── B: Promise.withResolvers ─────────────────────────────────────────────────

@(test)
m209_promise_with_resolvers :: proc(t: ^testing.T) {
    testing.expect_value(t, val(`typeof Promise.withResolvers`), "function")
    testing.expect_value(t, val(`Object.keys(Promise.withResolvers()).sort().join(",")`), "promise,reject,resolve")
    testing.expect_value(t, val(`(function(){ var w = Promise.withResolvers(); return typeof w.resolve + "," + typeof w.reject })()`),
        "function,function")
    // resolve/reject de FORA do executor mexem na promise devolvida (é o ponto da API)
    // (reações são microtasks: o estado é lido numa 2ª tarefa, depois do checkpoint)
    settled :: proc(src: string) -> string {
        s, _ := run_settled(src, "visto").(string)
        return s
    }
    testing.expect_value(t, settled(`
        var w = Promise.withResolvers(), visto = "pendente";
        w.promise.then(function(v){ visto = "ok:" + v });
        w.resolve(42);
    `), "ok:42")
    testing.expect_value(t, settled(`
        var w = Promise.withResolvers(), visto = "pendente";
        w.promise.catch(function(e){ visto = "erro:" + e });
        w.reject("boom");
    `), "erro:boom")
    // encadeia como qualquer promise
    testing.expect_value(t, settled(`
        var w = Promise.withResolvers(), visto = "";
        w.promise.then(function(v){ return v * 2 }).then(function(v){ visto = String(v) });
        w.resolve(21);
    `), "42")
}

// ── Promise.prototype na cadeia (gap antigo que o oráculo do Chrome expôs) ────

@(test)
m209_promise_instanceof :: proc(t: ^testing.T) {
    // Valia p/ TODA promise, não só p/ a do withResolvers: `promise_new` nascia sem
    // [[Prototype]]. Uma lib que ramifica por `instanceof Promise` ia sempre p/ o
    // galho errado — em silêncio.
    testing.expect_value(t, val(`new Promise(function(){}) instanceof Promise`), "true")
    testing.expect_value(t, val(`Promise.resolve(1) instanceof Promise`), "true")
    testing.expect_value(t, val(`Promise.all([]) instanceof Promise`), "true")
    testing.expect_value(t, val(`Promise.withResolvers().promise instanceof Promise`), "true")
    testing.expect_value(t, val(`Promise.resolve(1).then(function(){}) instanceof Promise`), "true")
    testing.expect_value(t, val(`Promise.resolve(1).constructor === Promise`), "true")
    // CONTROLE: os métodos continuam vindo das props PRÓPRIAS (o caminho quente não
    // passou a depender da cadeia) e um objeto qualquer não virou promise.
    testing.expect_value(t, val(`Promise.resolve(1).hasOwnProperty("then")`), "true")
    testing.expect_value(t, val(`({}) instanceof Promise`), "false")
}
