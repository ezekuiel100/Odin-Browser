package js

// M208 — protótipo EXÓTICO: `Object.create(array)` devolvia um objeto SEM HERANÇA.
//
// Achado no github.com, onde era o último erro de JS que sobrava depois do M206/M207:
// `TypeError: e.slice is not a function` em github-elements / behaviors /
// marketing-essentials. A raiz não está em nenhum dos três — está no `selector-set`
// (que o selector-observer embrulha), e a forma é esta:
//
//     n.prototype.indexes = [];                     // um ARRAY de índices de seletor
//     n.prototype.indexes.push({name:"ID", …});     // …com itens…
//     n.prototype.indexes.default = {name:"UNIVERSAL", …};  // …e uma prop PRÓPRIA
//     …
//     this.indexes = Object.create(this.indexes);   // ← protótipo é o ARRAY
//     function f(e,t){ … e = e.slice(0).concat(e.default) … }
//
// `Object.proto` é um `^Object` e um array é uma variante PRÓPRIA da union Value, então
// `obj_create` simplesmente DESCARTAVA o argumento: o objeto nascia sem cadeia nenhuma.
// Não faltava só o `slice` — faltavam `length`, os índices e a prop própria `default`.
// E o modo de falhar era o pior: silencioso até a primeira chamada de método.
//
// O campo novo é `Object.proto_x` (o [[Prototype]] quando ele não é ^Object). NÃO é o
// `prim` que já existia: `prim` é subclasse de builtin e faz `Array.isArray` dar TRUE,
// que aqui seria errado — por isso o teste do isArray abaixo é o controle.
//
// Todos os valores esperados aqui foram conferidos contra o Chrome headless (29 linhas
// de oráculo); as 2 que não batiam eram gaps ANTIGOS, e uma delas virou o último teste
// (`"slice" in []`). O que segue divergindo de propósito está anotado no fim.

import "core:fmt"
import "core:strings"
import "core:testing"

// Roda `expr` como EXPRESSÃO e devolve o resultado já em String. O try/catch é o que
// torna a prova negativa legível: sem ele, a versão quebrada devolve `undefined`/lança e
// o `.(string)` do teste vira um PANIC — e panic de teste aqui TRAVA o runner (o binário
// ficou 8 min em loop e só saiu com kill) em vez de dar FAIL com o valor à vista.
//
// ⚠️ A fonte é CONCATENADA, não formatada: as chaves do corpo da função passam pelo fmt
// do Odin como diretiva (`%!(MISSING CLOSE BRACE)`), o JS chega quebrado e o
// check_parse_recoveries derruba o teste por um motivo que não tem nada a ver com o
// que ele mede. Custou uma rodada inteira aqui.
@(private = "file")
val :: proc(expr: string) -> string {
    src := strings.concatenate({
        `(function(){ try { return String(`, expr,
        `) } catch (e) { return "<throw> " + e.message } })()`,
    }, context.temp_allocator)
    v := run(src)
    s, ok := v.(string)
    if !ok do return fmt.tprintf("<nao-string %v>", v)
    return s
}

@(test)
m208_object_create_de_array_herda :: proc(t: ^testing.T) {
    // método da Array.prototype pela cadeia — o `e.slice is not a function` do GitHub
    testing.expect_value(t, val(`typeof Object.create([1,2]).slice`), "function")
    // `length` e os ÍNDICES também são herdados (o objeto não tem nada próprio)
    testing.expect_value(t, val(`Object.create([1,2]).length`), "2")
    testing.expect_value(t, val(`Object.create(["a","b"])[1]`), "b")
    // …e as props PRÓPRIAS do array, que é como o selector-set guarda o índice
    // universal (`indexes.default`)
    testing.expect_value(t, val(`(function(){ var p=["x"]; p.default="U"; return Object.create(p).default })()`), "U")
}

@(test)
m208_forma_real_do_selector_set :: proc(t: ^testing.T) {
    // A linha que quebrava, reduzida: slice() sobre um objeto cujo protótipo é o array
    // (o `this` do slice NÃO é um array — ele lê length/índices como array-like) e
    // concat com a prop própria do protótipo.
    testing.expect_value(t, val(`(function(){
        var proto = [];
        proto.push({name:"ID"}); proto.push({name:"CLASS"});
        proto.default = {name:"UNIVERSAL"};
        var e = Object.create(proto);
        var r = e.slice(0).concat(e.default);
        return r.length + ":" + r[0].name + ":" + r[2].name
    })()`), "3:ID:UNIVERSAL")
}

@(test)
m208_nao_vira_array :: proc(t: ^testing.T) {
    // CONTROLE do desenho: o objeto HERDA de um array, mas não É um array. Se o
    // protótipo exótico tivesse sido guardado no `prim` (a alternativa que economizaria
    // memória), este teste passaria a dar true — `Array.isArray` olha o prim.
    testing.expect_value(t, val(`Array.isArray(Object.create([1,2]))`), "false")
    // e o que o JSON vê segue sendo um objeto sem props próprias
    testing.expect_value(t, val(`JSON.stringify(Object.create([1,2]))`), "{}")
}

@(test)
m208_cadeia_visivel_pelas_apis :: proc(t: ^testing.T) {
    testing.expect_value(t, val(`(function(){ var a=[1]; return Object.getPrototypeOf(Object.create(a)) === a })()`), "true")
    testing.expect_value(t, val(`(function(){ var a=[1]; return a.isPrototypeOf(Object.create(a)) })()`), "true")
    testing.expect_value(t, val(`Object.create([1]) instanceof Array`), "true")
    testing.expect_value(t, val(`Object.create([1]) instanceof Object`), "true")
    // `in` é HasProperty: sobe a cadeia inteira
    testing.expect_value(t, val(`"slice" in Object.create([1,2])`), "true")
    testing.expect_value(t, val(`"0" in Object.create([1,2])`), "true")
    testing.expect_value(t, val(`"2" in Object.create([1,2])`), "false")
    // hasOwnProperty NÃO: o índice é herdado, não próprio
    testing.expect_value(t, val(`Object.create([1,2]).hasOwnProperty("0")`), "false")
    testing.expect_value(t, val(`Object.keys(Object.create([1,2])).length`), "0")
    // o construtor herdado é o Array (`Object.create([]).constructor === Array`)
    testing.expect_value(t, val(`Object.create([1]).constructor === Array`), "true")
}

@(test)
m208_escrita_vira_own :: proc(t: ^testing.T) {
    // escrever no objeto NÃO pode tocar no array-protótipo (é isso que faz o
    // selector-set funcionar: cada instância acumula o seu sem sujar o compartilhado)
    testing.expect_value(t, val(`(function(){
        var p = [{n:"P"}];
        var o = Object.create(p);
        o[0] = {n:"O"}; o.x = 1;
        return p[0].n + ":" + o[0].n + ":" + p.length + ":" + (p.x === undefined)
    })()`), "P:O:1:true")
}

@(test)
m208_outros_prototipos_exoticos :: proc(t: ^testing.T) {
    // FUNÇÃO como protótipo: mesma raiz (^Function também não cabe no campo `proto`)
    testing.expect_value(t, val(`(function(){ function F(){}; F.marca=7; return Object.create(F).marca })()`), "7")
    testing.expect_value(t, val(`(function(){ function F(){}; return typeof Object.create(F).call })()`), "function")
    // setPrototypeOf também aceita — é o outro caminho para a mesma cadeia
    testing.expect_value(t, val(`(function(){ var o={}; Object.setPrototypeOf(o,[1,2,3]); return o.length })()`), "3")
    testing.expect_value(t, val(`(function(){ var o={}; Object.setPrototypeOf(o,[1,2,3]); return typeof o.slice })()`), "function")
    // dois elos: objeto → objeto → array
    testing.expect_value(t, val(`Object.create(Object.create([1,2])).length`), "2")
}

@(test)
m208_null_continua_sem_cadeia :: proc(t: ^testing.T) {
    // CONTROLE do caminho antigo: `Object.create(null)` é o idioma de mapa puro e não
    // pode ter ganhado protótipo nenhum.
    testing.expect_value(t, val(`Object.getPrototypeOf(Object.create(null)) === null`), "true")
    testing.expect_value(t, val(`(function(){ var o=Object.create(null); o.a=1; return Object.keys(o).length })()`), "1")
    // e um protótipo ^Object comum segue funcionando
    testing.expect_value(t, val(`(function(){ var b={m:function(){return 9}}; return Object.create(b).m() })()`), "9")
    // 2º arg que não é objeto nem null é NO-OP: não pode DESLIGAR a cadeia que já
    // existia (a spec lança ali; no-op é a leniência antiga). Um `o.proto=nil` aqui
    // seria uma regressão silenciosa em cima de código alheio.
    testing.expect_value(t, val(`(function(){
        var b={m:1}; var o=Object.create(b);
        Object.setPrototypeOf(o, undefined);
        Object.setPrototypeOf(o, 5);
        return o.m
    })()`), "1")
    // null DESLIGA (esse é o caminho válido)
    testing.expect_value(t, val(`(function(){
        var b={m:1}; var o=Object.create(b);
        Object.setPrototypeOf(o, null);
        return o.m
    })()`), "undefined")
}

@(test)
m208_in_sobre_array_ve_o_prototipo :: proc(t: ^testing.T) {
    // Gap ANTIGO, achado pelo oráculo do Chrome ao conferir o fix acima: `in` é
    // HasProperty e sobe até Array.prototype/Object.prototype. Dava false, e um
    // polyfill que testa assim instalava por cima do nosso método nativo.
    testing.expect_value(t, val(`"slice" in []`), "true")
    testing.expect_value(t, val(`"hasOwnProperty" in []`), "true")
    testing.expect_value(t, val(`"length" in []`), "true")
    testing.expect_value(t, val(`"0" in [7]`), "true")
    testing.expect_value(t, val(`"1" in [7]`), "false")
    testing.expect_value(t, val(`"naoexiste" in []`), "false")
}

@(test)
m208_metodos_de_array_iteram_o_objeto :: proc(t: ^testing.T) {
    // Consequência do fix que o oráculo pegou: com os índices HERDADOS, o `length` do
    // objeto passou a ser 2 — mas o teste de presença (HasProperty) do array_like_has
    // olhava só as props PRÓPRIAS, então forEach/map tratavam tudo como BURACO. O
    // resultado era o pior tipo: `map` devolvia `[null,null]`, plausível e errado.
    testing.expect_value(t, val(`(function(){ var n=0; [].forEach.call(Object.create([1,2]), function(){n++}); return n })()`), "2")
    testing.expect_value(t, val(`JSON.stringify([].map.call(Object.create(["a","b"]), function(x){return x+"!"}))`), `["a!","b!"]`)
    testing.expect_value(t, val(`JSON.stringify(Array.from(Object.create([1,2])))`), "[1,2]")
    testing.expect_value(t, val(`[].filter.call(Object.create([1,2,3]), function(x){return x>1}).length`), "2")
    // CONTROLE: buraco de verdade continua sendo pulado (é o que o array_like_has faz)
    testing.expect_value(t, val(`(function(){ var n=0; [].forEach.call({length:3, 1:"x"}, function(){n++}); return n })()`), "1")
}

// DEGRADAÇÃO CONHECIDA (não é regressão deste marco): **`for-in` não sobe a cadeia** —
// é own-only em todo o motor. Medido contra o Chrome no mesmo oráculo:
// `for (k in Object.create(arrayComProps))` dá `["0","x"]` aqui e
// `["0","1","default","x"]` lá. Fica anotado porque o fix deste marco TORNOU a diferença
// visível (antes o objeto não herdava nada, então "não enumerar" era consistente);
// consertar mexe no for-in de TODO objeto e é marco próprio.
//
// DEGRADAÇÃO CONHECIDA 2 (anterior a este marco): `Object.create(null).toString`
// devolve uma função aqui e `undefined` no Chrome. `get_member` cai em
// `vm.object_methods` sem exigir protótipo — leniência DELIBERADA e antiga (um mapa
// puro responde a hasOwnProperty/toString como se herdasse). Fica anotado porque o
// oráculo do Chrome bateu nela ao conferir este fix; mexer ali afeta a leitura de
// TODO objeto e é marco próprio.
