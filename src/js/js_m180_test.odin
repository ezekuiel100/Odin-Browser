package js

// M180 — `Object.keys/values/entries/getOwnPropertyNames` só enxergavam `^Object`.
//
// Neste motor Function, Array e string NÃO são `^Object` — cada um é seu próprio
// tipo, com seu próprio `props`. Todas essas natives faziam
// `if o, ok := arg(args,0).(^Object); ok { ... }` e, para os demais tipos, caíam
// fora EM SILÊNCIO devolvendo lista VAZIA.
//
// O estrago concreto foi o open.spotify.com em branco. O runtime do webpack 5
// decide se já pode rodar a entrada com:
//
//     Object.keys(__webpack_require__.O).every(k => O[k](chunkId))
//
// onde `O` é uma FUNÇÃO com o teste de chunk pendurado nela (`O.j`). Como
// `Object.keys(O)` dava `[]` e `[].every(...)` é **true por vacuidade**, o portão
// abria sempre: a entrada rodava durante o 1º bundle, antes de o chunk `vendor`
// chegar, e pedia um módulo que ainda não existia — `l[96175].call` de undefined.
//
// ⚠️ o `.every` sobre vazio dar true está CERTO; o erro era a lista vazia.

import "core:testing"

// O caso do spotify, reduzido ao portão.
@(test)
m180_keys_de_funcao_com_props :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function f(){}
        f.j = 1; f.k = 2;
        Object.keys(f).sort().join(",")
    `).(string), "j,k")

    // o portão do webpack 5, literal: com o chunk AUSENTE não pode abrir
    testing.expect_value(t, run(`
        var O = function(){};
        var instalados = { "web-player": 0 };
        O.j = function(id){ return instalados[id] === 0; };
        Object.keys(O).every(function(k){ return O[k]("vendor"); })
    `).(bool), false)

    // e abre quando o chunk chega
    testing.expect_value(t, run(`
        var O = function(){};
        var instalados = { "web-player": 0, "vendor": 0 };
        O.j = function(id){ return instalados[id] === 0; };
        Object.keys(O).every(function(k){ return O[k]("vendor"); })
    `).(bool), true)
}

// `prototype`/`name`/`length` são próprias mas NÃO-enumeráveis (spec): não podem
// aparecer em Object.keys, senão o portão acima abriria por chave errada.
@(test)
m180_keys_de_funcao_esconde_intrinsecos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.keys(function nomeada(a,b){}).length`).(f64), f64(0))
    testing.expect_value(t, run(`
        function f(){}
        Object.keys(f).indexOf("prototype") < 0 && Object.keys(f).indexOf("name") < 0
    `).(bool), true)
    // getOwnPropertyNames é o oposto: AS não-enumeráveis é que interessam
    testing.expect_value(t, run(`
        function f(){}
        f.x = 1;
        var n = Object.getOwnPropertyNames(f);
        n.indexOf("x") >= 0 && n.indexOf("name") >= 0 && n.indexOf("length") >= 0
    `).(bool), true)
}

// Mesmo buraco em ARRAY e STRING (idiomas comuns, achados junto).
@(test)
m180_keys_values_entries_de_array_e_string :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.keys([10,20]).join(",")`).(string), "0,1")
    testing.expect_value(t, run(`Object.values([10,20]).join(",")`).(string), "10,20")
    testing.expect_value(t, run(`JSON.stringify(Object.entries([7]))`).(string), `[["0",7]]`)
    testing.expect_value(t, run(`Object.keys("ab").join(",")`).(string), "0,1")
    // prop própria de array entra junto com os índices
    testing.expect_value(t, run(`
        var a = [1]; a.extra = "x";
        Object.keys(a).join(",")
    `).(string), "0,extra")
}

// Não-regressão: o caminho de ^Object segue igual, inclusive não-enumeráveis.
@(test)
m180_objeto_comum_intacto :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.keys({a:1,b:2}).join(",")`).(string), "a,b")
    testing.expect_value(t, run(`Object.values({a:1,b:2}).join(",")`).(string), "1,2")
    testing.expect_value(t, run(`
        var o = {};
        Object.defineProperty(o, "escondida", { value: 1, enumerable: false });
        o.visivel = 2;
        Object.keys(o).join(",")
    `).(string), "visivel")
    // objeto vazio segue vazio (guarda de que o teste pode falhar)
    testing.expect_value(t, run(`Object.keys({}).length`).(f64), f64(0))
    testing.expect_value(t, run(`Object.keys(function(){}).length`).(f64), f64(0))
}
