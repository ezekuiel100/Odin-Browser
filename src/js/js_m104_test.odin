package js

import "core:testing"

// M104 — família Object de integridade/extensibilidade que FALTAVA (gap-miner:
// "Object.isExtensible is not a function", 3 sites, coingecko). Queries corretas
// sobre o flag `frozen`; seal/preventExtensions são no-op aprox. (nosso frozen
// bloqueia escrita demais). + getOwnPropertyDescriptors / getOwnPropertySymbols.

@(test)
m104_isExtensible_padrao :: proc(t: ^testing.T) {
    r := run(`Object.isExtensible({})`)
    b, _ := r.(bool)
    testing.expect(t, b, "objeto novo é extensível")
}

@(test)
m104_isExtensible_apos_freeze :: proc(t: ^testing.T) {
    r := run(`var o={}; Object.freeze(o); Object.isExtensible(o)`)
    b, ok := r.(bool)
    testing.expectf(t, ok && !b, "objeto congelado NÃO é extensível: got %v", r)
}

@(test)
m104_isExtensible_primitivo :: proc(t: ^testing.T) {
    r := run(`Object.isExtensible(5)`)
    b, _ := r.(bool)
    testing.expect(t, !b, "primitivo não é extensível")
}

@(test)
m104_isFrozen :: proc(t: ^testing.T) {
    r := run(`var o={}; var a=Object.isFrozen(o); Object.freeze(o); var b=Object.isFrozen(o); a+","+b`)
    s, _ := r.(string)
    testing.expectf(t, s == "false,true", "isFrozen antes/depois de freeze: got %q", s)
}

@(test)
m104_isFrozen_primitivo :: proc(t: ^testing.T) {
    r := run(`Object.isFrozen(5)`)
    b, _ := r.(bool)
    testing.expect(t, b, "primitivo é frozen (spec)")
}

@(test)
m104_isSealed_frozen :: proc(t: ^testing.T) {
    // congelado implica selado (isSealed≈isFrozen no nosso modelo)
    r := run(`var o={}; Object.freeze(o); Object.isSealed(o)`)
    b, _ := r.(bool)
    testing.expect(t, b, "objeto congelado é selado")
}

@(test)
m104_seal_e_preventExtensions_devolvem_alvo :: proc(t: ^testing.T) {
    // no-op: devolve o próprio objeto e não estoura (uso defensivo das libs)
    r := run(`var o={x:1}; var p=Object.preventExtensions(o); var q=Object.seal(o); (p===o)+","+(q===o)`)
    s, _ := r.(string)
    testing.expectf(t, s == "true,true", "seal/preventExtensions devolvem o alvo: got %q", s)
}

@(test)
m104_getOwnPropertyDescriptors :: proc(t: ^testing.T) {
    r := run(`
        var o = {a:1, b:2};
        var d = Object.getOwnPropertyDescriptors(o);
        d.a.value + "," + d.b.value + "," + (d.a.enumerable)
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "1,2,true", "descriptors de props próprias: got %q", s)
}

@(test)
m104_getOwnPropertyDescriptors_reconstroi :: proc(t: ^testing.T) {
    // o idioma real: copiar props via defineProperties(getOwnPropertyDescriptors)
    r := run(`
        var src = {x:10, y:20};
        var dst = {};
        Object.defineProperties(dst, Object.getOwnPropertyDescriptors(src));
        dst.x + dst.y
    `)
    testing.expectf(t, as_number(r) == 30, "reconstrução via descriptors: got %v", r)
}

@(test)
m104_getOwnPropertySymbols_array_vazio :: proc(t: ^testing.T) {
    r := run(`var s = Object.getOwnPropertySymbols({a:1}); Array.isArray(s) + "," + s.length`)
    s, _ := r.(string)
    testing.expectf(t, s == "true,0", "getOwnPropertySymbols → array vazio: got %q", s)
}

@(test)
m104_todos_sao_funcoes :: proc(t: ^testing.T) {
    // feature-detect que as libs fazem
    r := run(`
        ["isExtensible","isFrozen","isSealed","preventExtensions","seal",
         "getOwnPropertyDescriptors","getOwnPropertySymbols"]
        .every(function(n){ return typeof Object[n] === "function"; })
    `)
    b, _ := r.(bool)
    testing.expect(t, b, "toda a família de integridade é função")
}
