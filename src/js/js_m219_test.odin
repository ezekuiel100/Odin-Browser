package js

// M219 — a cadeia de protótipos dos iteradores tinha UM degrau a menos, e o preço
// foi Object.prototype ENVENENADO no github.com.
//
// A spec manda três degraus acima da instância:
//
//     iterador → %ArrayIteratorPrototype% (next) → %IteratorPrototype% ([Symbol.iterator]) → Object.prototype
//
// Nós tínhamos dois (`next` e `[Symbol.iterator]` juntos num único %IteratorPrototype%).
// Ninguém repara nisso iterando — for-of, spread e Map.entries() funcionam igual. O
// que repara é POLYFILL: o de iterator-helpers do github pega o alvo assim
//
//     let e = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
//     "map"    in e || Object.assign(e, {map: en}),
//     "filter" in e || Object.assign(e, {filter: eo}), …
//
// e com um degrau só esse `e` ERA o Object.prototype. Resultado: `map`, `filter`,
// `take`, `drop`, `flatMap`, `reduce`, `toArray`, `forEach`, `some`, `every` e `find`
// viraram propriedades de Object.prototype — `x in obj` e `obj.x` da página inteira
// passaram a mentir para esses onze nomes. (Aqui o `for-in` NÃO sobe a cadeia — gap
// antigo, medido neste marco: `for (k in o)` só lista as próprias. Então o dano
// observável foi por `in` e por LEITURA, não por enumeração.)
//
// O estrago apareceu LONGE da causa. O property-information (usado pelo React p/
// mapear props → atributos) faz `caseSensitiveTransform`:
//
//     function s(e,n){ return n in e ? e[n] : n }
//
// com `e` = o mapa de exceções do esquema SVG e `n` = o nome da propriedade. Existe
// uma propriedade SVG chamada **filter**; `"filter" in {…}` virou true, `e["filter"]`
// devolveu a FUNÇÃO do polyfill, e o normalize() logo abaixo estourou com
//
//     TypeError: e.toLowerCase is not a function
//
// — a única exceção não capturada que sobrava na home. Nenhuma linha do erro fala de
// iterador; o que ligou uma ponta à outra foi a sonda `-define:CALLPROBE` somada à
// `-define:MEMBERPROBE` imprimindo a pilha com os PARÂMETROS de cada função (nome
// minificado não identifica nada, `(e,n,t)` + `a(e)` + `r(e)` identifica) e os nomes
// visíveis nos 3 escopos mais internos.

import "core:testing"

// ── a cadeia ─────────────────────────────────────────────────────────────────

@(test)
m219_cadeia_do_iterador_tem_dois_degraus :: proc(t: ^testing.T) {
    // é literalmente a expressão que o polyfill avalia
    src := `
        var it = [][Symbol.iterator]();
        var p1 = Object.getPrototypeOf(it);
        var p2 = Object.getPrototypeOf(p1);
        (p1 !== null && p2 !== null && p1 !== Object.prototype && p2 !== Object.prototype
            && p1 !== p2 && Object.getPrototypeOf(p2) === Object.prototype) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m219_next_fica_no_degrau_de_baixo :: proc(t: ^testing.T) {
    // CONTROLE (passa dos dois lados): core-js detecta o iterator-prototype com
    // `getPrototypeOf(coll.values()).next`, e antes do fix o `next` também era own do
    // protótipo imediato. Mover o `next` p/ o %ArrayIteratorPrototype% não pode ter
    // quebrado essa checagem — é isso que ele guarda.
    src := `
        var p1 = Object.getPrototypeOf([1,2][Symbol.iterator]());
        var p2 = Object.getPrototypeOf(p1);
        (typeof p1.next === "function"
            && Object.prototype.hasOwnProperty.call(p1, "next")
            && !Object.prototype.hasOwnProperty.call(p2, "next")) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m219_symbol_iterator_fica_no_degrau_de_cima :: proc(t: ^testing.T) {
    // e o [Symbol.iterator] no %IteratorPrototype%, que é onde a spec o põe — é o
    // que faz o objeto DEVOLVIDO pelo polyfill continuar iterável
    src := `
        var it = [7,8][Symbol.iterator]();
        var p1 = Object.getPrototypeOf(it);
        var p2 = Object.getPrototypeOf(p1);
        (Object.prototype.hasOwnProperty.call(p2, Symbol.iterator)
            && !Object.prototype.hasOwnProperty.call(p1, Symbol.iterator)
            && it[Symbol.iterator]() === it) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

// ── o polyfill e o estrago ───────────────────────────────────────────────────

@(test)
m219_polyfill_de_iterator_helpers_nao_toca_object_prototype :: proc(t: ^testing.T) {
    // a forma EXATA do bundle do github (função eb() do chunk 78205)
    src := `
        function ee(){
            var e = [][Symbol.iterator]();
            var t = Object.getPrototypeOf(e);
            if (!t) return null;
            return Object.getPrototypeOf(t);
        }
        function eo(e){ return e }
        var alvo = ee() || {};
        "filter" in alvo || Object.assign(alvo, { filter: eo });
        "map"    in alvo || Object.assign(alvo, { map: eo });
        (("filter" in {}) === false && ({}).filter === undefined
            && ("map" in {}) === false
            && typeof [1,2][Symbol.iterator]().filter === "function") ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m219_property_information_devolve_o_nome_do_atributo :: proc(t: ^testing.T) {
    // a linha que estourava, com o polyfill instalado antes: `filter` é uma
    // propriedade SVG de verdade, e o transform tem de devolver a STRING "filter"
    src := `
        function ee(){
            var e = [][Symbol.iterator]();
            var t = Object.getPrototypeOf(e);
            return t ? Object.getPrototypeOf(t) : null;
        }
        "filter" in (ee() || {}) || Object.assign(ee() || {}, { filter: function eo(e){ return e } });
        function s(e,n){ return n in e ? e[n] : n }
        var atributos = { className: "class", clipPath: "clip-path", crossOrigin: "crossorigin" };
        var v = s(atributos, "filter");
        (typeof v === "string" && v === "filter"
            && s(atributos, "className") === "class") ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m219_object_prototype_fica_limpo :: proc(t: ^testing.T) {
    // o alvo do polyfill visto do outro lado: depois de instalar, Object.prototype
    // não pode ter ganhado NENHUM dos onze nomes
    src := `
        function ee(){
            var t = Object.getPrototypeOf([][Symbol.iterator]());
            return t ? Object.getPrototypeOf(t) : null;
        }
        Object.assign(ee() || {}, { take: function(e){ return e }, drop: function(e){ return e } });
        (Object.prototype.take === undefined && Object.prototype.drop === undefined
            && !Object.prototype.hasOwnProperty.call(Object.prototype, "take")) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

// ── controles: o degrau novo não pode ter mexido em iterar ───────────────────

@(test)
m219_iteracao_continua_funcionando :: proc(t: ^testing.T) {
    // CONTROLE — passa dos DOIS lados do fix. Existe para provar que o marco não
    // comprou a cadeia certa ao preço do protocolo de iteração.
    src := `
        var soma = 0;
        for (var v of [1,2,3]) soma += v;
        var esp = [...new Set([4,5])].join("-");
        var m = new Map([["a",1],["b",2]]);
        var pares = [];
        for (var it = m.entries(), r; !(r = it.next()).done; ) pares.push(r.value[0] + r.value[1]);
        var letras = [..."xy"].join("");
        (soma === 6 && esp === "4-5" && pares.join(",") === "a1,b2" && letras === "xy"
            && Object.keys({a:1}).length === 1) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m219_iterador_ainda_e_iteravel_de_si_mesmo :: proc(t: ^testing.T) {
    // CONTROLE — o [Symbol.iterator] subiu de degrau; continuar sendo HERDADO é o
    // que faz `for-of` sobre um iterador cru funcionar
    src := `
        var it = [1,2,3][Symbol.iterator]();
        it.next();
        var resto = [];
        for (var v of it) resto.push(v);
        resto.join(",")
    `
    testing.expect_value(t, run(src).(string), "2,3")
}

// GAP VIZINHO MEDIDO AQUI (anterior a este marco, NÃO consertado): o `for-in` deste
// motor não sobe a cadeia de protótipos — `function P(){}; P.prototype.herdada = 2;
// for (k in new P())` lista só as próprias, e a spec manda listar as enumeráveis
// herdadas também. Foi o que impediu o envenenamento de aparecer em enumeração (só em
// `in` e em leitura). Mexer nisso afeta todo `for-in` do corpus e é marco próprio.
//
// DEGRADAÇÃO CONHECIDA: os iteradores de Map/Set/string compartilham o MESMO
// %ArrayIteratorPrototype% (a spec tem um %MapIteratorPrototype%, um
// %SetIteratorPrototype% e um %StringIteratorPrototype% distintos, cada um com o seu
// Symbol.toStringTag). Isso é observável por `Object.prototype.toString.call(m.keys())`
// — que aqui não diz "[object Map Iterator]" — e por quem comparar os protótipos entre
// si. Nenhum dos dois aparece no corpus; o que importava era existir o degrau, porque é
// ELE que os polyfills procuram.
