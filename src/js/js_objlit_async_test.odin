package js

import "core:testing"

// Literal de objeto: prefixo `async` compondo com generator e chave computada,
// e a guarda contra chave que não é chave.
//
// Origem: `ReferenceError:  is not defined` — mensagem SEM NOME, que não diz o
// identificador nem a sintaxe. O nome vazio nascia do ramo SHORTHAND consumindo
// um token de PONTUAÇÃO (operadores não carregam `.text`), o que só acontece
// depois de o parser já ter dessincronizado.
//
// A caçada (vale mais que o conserto): 5 bundles reais e 35 construtos deram
// ZERO — e o zero só passou a significar alguma coisa depois do CONTROLE
// POSITIVO (`{ = }`) provar que a sonda dispara. Foi ele que revelou que
// `--parsetree` dumpa a árvore HTML, não a de JS: a varredura anterior media
// NADA. Com a ferramenta certa (`--js262`), a bissecção achou dois desyncs
// reais, ambos no ramo `async`.

@(test)
objlit_async_generator :: proc(t: ^testing.T) {
    // `{async *g(){}}` — o ramo antigo exigia chave Ident/Str seguida de '(',
    // então o `*` não casava: `async` virava chave shorthand e o script morria
    // com `ReferenceError: async is not defined`.
    r := run(`
        var o = { async *gen() { yield 1; } };
        typeof o.gen === 'function' && typeof o.async === 'undefined'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "async generator em literal: vira método `gen`, não a chave `async`")
}

@(test)
objlit_async_chave_computada :: proc(t: ^testing.T) {
    r := run(`
        var k = 'dinamica';
        var o = { async [k]() { return 7; } };
        typeof o.dinamica === 'function' && typeof o.async === 'undefined'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "async com chave computada: vira método com o nome computado")
}

@(test)
objlit_async_de_verdade_devolve_promise :: proc(t: ^testing.T) {
    // Não basta PARSEAR: o corpo tem de ser async (o `aux` propagado). Um método
    // comum devolveria 7 cru em vez de uma promise.
    r := run(`
        var k = 'm';
        var o = { async [k]() { return 7; } };
        var v = o.m();
        typeof v === 'object' && typeof v.then === 'function'
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "o método async computado devolve Promise (o `async` não se perdeu)")
}

@(test)
objlit_async_como_chave_normal_continua :: proc(t: ^testing.T) {
    // ⚠️ CONTROLE da mudança: mexi na DETECÇÃO do prefixo `async`. Se ela ficar
    // gulosa demais, `{async: 1}` e `{async(){}}` — que são chaves normais e
    // aparecem em código real — quebram.
    r := run(`
        var a = { async: 1 };
        var b = { async() { return 2; } };
        var c = { async: function () { return 3; } };
        a.async === 1 && b.async() === 2 && c.async() === 3
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "`async` continua sendo chave normal quando não é prefixo de método")
}

@(test)
objlit_formas_vizinhas_intactas :: proc(t: ^testing.T) {
    // CONTROLES: as formas que já funcionavam e passam pelo mesmo trecho.
    r := run(`
        var k = 'ck';
        var o = {
            *g() { yield 1; },
            [k]() { return 'comp'; },
            async simples() { return 1; },
            get acc() { return 'g'; },
            set acc(v) {},
            metodo() { return 'm'; },
            curta: 1,
        };
        typeof o.g === 'function' && o.ck() === 'comp' &&
        typeof o.simples === 'function' && o.acc === 'g' &&
        o.metodo() === 'm' && o.curta === 1
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "generator, computada, async simples, get/set e método curto intactos")
}

@(test)
objlit_chave_string_vazia_continua_legal :: proc(t: ^testing.T) {
    // ⚠️ A guarda nova recusa chave vazia — mas `{"": v}` é LEGAL e não pode cair
    // nela. É o par que impede o conserto de virar regressão.
    r := run(`
        var o = { '': 'vazia', x: 1 };
        o[''] === 'vazia' && o.x === 1
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "chave string vazia `{'': v}` continua funcionando")
}
