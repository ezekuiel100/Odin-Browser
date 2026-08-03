package js

import "core:testing"

// M120 — destructuring com CHAVE COMPUTADA: `{ [expr]: alvo } = obj`.
// Era o padrão de parse-recovery DOMINANTE do corpus (spotify 2004, npmjs 694,
// coinmarketcap 599, americanas 502, +30 sites): `{ [i]: c, [s]: l } = e.getBoundingClientRect()`.
// O parser assumia chave Ident/Str (advance().text pegava o '[' cru) → cascata de
// recoveries → TypeError → SPA branca. Agora `.third` guarda a expressão da chave.

@(test)
m120_computed_key_basic :: proc(t: ^testing.T) {
    r := run(`
        var o = { a: 1, b: 2, c: 3 };
        var k = "a", k2 = "c";
        var { [k]: x, [k2]: y } = o;
        x * 10 + y
    `)
    n, ok := r.(f64)
    testing.expect(t, ok && n == 13, "{ [k]: x, [k2]: y } liga x=1 y=3")
}

@(test)
m120_computed_key_expr :: proc(t: ^testing.T) {
    // chave é uma expressão de membro, não só um ident (caso spotify: { [a.fl.PLAYLISTS]: e })
    r := run(`
        var src = { xy: 42 };
        var cfg = { name: "x" };
        var { [cfg.name + "y"]: v } = src;
        v
    `)
    n, ok := r.(f64)
    testing.expect(t, ok && n == 42, "chave computada por expressão de membro resolve para 'xy'")
}

@(test)
m120_computed_key_with_rest :: proc(t: ^testing.T) {
    // caso hub.docker: { [g]: m, light: b, ...x } = o — o rest exclui a chave computada.
    r := run(`
        var o = { p: 1, light: 2, dark: 3, extra: 4 };
        var g = "p";
        var { [g]: m, light: b, ...rest } = o;
        var keys = Object.keys(rest).sort().join(",");
        m + "|" + b + "|" + keys
    `)
    s, ok := r.(string)
    testing.expect(t, ok && s == "1|2|dark,extra", "rest exclui chave computada 'p' e estática 'light'")
}

@(test)
m120_computed_key_default :: proc(t: ^testing.T) {
    // default quando a chave computada não existe: { [k]: v = 9 }
    r := run(`
        var o = { a: 1 };
        var k = "missing";
        var { [k]: v = 9 } = o;
        v
    `)
    n, ok := r.(f64)
    testing.expect(t, ok && n == 9, "default aplica quando a chave computada está ausente")
}

@(test)
m120_computed_key_assign_expr :: proc(t: ^testing.T) {
    // destructuring-EXPRESSÃO (sem var), atribui a variáveis existentes: ({ [k]: x } = o)
    r := run(`
        var x = 0;
        var o = { hello: 7 };
        var k = "hello";
        ({ [k]: x } = o);
        x
    `)
    n, ok := r.(f64)
    testing.expect(t, ok && n == 7, "destructuring-expressão com chave computada atribui a x")
}
