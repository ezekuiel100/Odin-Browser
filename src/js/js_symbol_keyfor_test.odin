package js

// Symbol.keyFor — o inverso do Symbol.for. Antes não existia (só a entrada de
// `length` em builtin_meta), então `Symbol.keyFor(s)` era "undefined is not a function".

import "core:testing"

@(test)
symbol_keyfor_devolve_chave_do_registro :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Symbol.keyFor(Symbol.for("react.element"))`).(string), "react.element")
    testing.expect_value(t, run(`Symbol.keyFor(Symbol.for(""))`).(string), "")
    // dois registros distintos não se confundem
    testing.expect_value(t, run(`var a=Symbol.for("a"), b=Symbol.for("b"); Symbol.keyFor(a)+Symbol.keyFor(b)`).(string), "ab")
}

@(test)
symbol_keyfor_simbolo_fora_do_registro_e_undefined :: proc(t: ^testing.T) {
    // homônimo de um registrado continua FORA do registro
    testing.expect_value(t, run(`Symbol.for("x"); Symbol.keyFor(Symbol("x")) === undefined`).(bool), true)
    testing.expect_value(t, run(`Symbol.keyFor(Symbol.iterator) === undefined`).(bool), true)
}

// Symbol.for aplica ToString à chave. Antes só string era aceita e o resto caía na
// chave "": Symbol.for(1) === Symbol.for(true) === Symbol.for().
@(test)
symbol_for_aplica_to_string_na_chave :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Symbol.for(1) === Symbol.for("1")`).(bool), true)
    testing.expect_value(t, run(`Symbol.for(1) === Symbol.for(true)`).(bool), false)
    testing.expect_value(t, run(`Symbol.for(1) === Symbol.for("")`).(bool), false)
    testing.expect_value(t, run(`Symbol.for() === Symbol.for("undefined")`).(bool), true)
    testing.expect_value(t, run(`[Symbol.for(1), Symbol.for(true), Symbol.for(null), Symbol.for(), Symbol.for(-0)].map(Symbol.keyFor).join("|")`).(string), "1|true|null|undefined|0")
    // objeto passa por ToPrimitive(hint string): toString antes de valueOf
    testing.expect_value(t, run(`Symbol.keyFor(Symbol.for({toString(){return "k"}, valueOf(){return "v"}}))`).(string), "k")
    testing.expect_value(t, run(`Symbol.keyFor(Symbol.for([1,2]))`).(string), "1,2")
    // ToString(Symbol) lança; e o erro do toString do usuário propaga
    testing.expect_value(t, run(`var r="nao lancou"; try { Symbol.for(Symbol()) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var s={}, r="nao lancou"; try { Symbol.for({toString(){throw s}}) } catch (e) { r = e === s } r`).(bool), true)
}

@(test)
symbol_ctor_aplica_to_string_na_descricao :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`String(Symbol(1))`).(string), "Symbol(1)")
    testing.expect_value(t, run(`String(Symbol({toString(){return "d"}}))`).(string), "Symbol(d)")
    testing.expect_value(t, run(`String(Symbol())`).(string), "Symbol()")
    testing.expect_value(t, run(`String(Symbol(null))`).(string), "Symbol(null)")
    testing.expect_value(t, run(`var r="nao lancou"; try { Symbol(Symbol()) } catch (e) { r = e instanceof TypeError } r`).(bool), true)
}

@(test)
symbol_keyfor_nao_simbolo_lanca_type_error :: proc(t: ^testing.T) {
    src := `
        var n = 0;
        for (var x of ["x", 1, undefined, null, {}, true]) {
            try { Symbol.keyFor(x) } catch (e) { if (e instanceof TypeError) n++ }
        }
        n
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
    testing.expect_value(t, run(`typeof Symbol.keyFor + Symbol.keyFor.length`).(string), "function1")
}
