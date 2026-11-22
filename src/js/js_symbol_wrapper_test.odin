package js

// Os itens que faltavam no Symbol: description ausente, `new Symbol()`, o wrapper
// Object(sym), Array.prototype[@@unscopables] — e o ToPropertyKey de objeto, que
// apareceu ao testar `o[Object(sym)]` e valia para QUALQUER objeto como chave.

import "core:testing"

@(test)
symbol_sem_argumento_nao_tem_description :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Symbol().description === undefined`).(bool), true)
    testing.expect_value(t, run(`Symbol(undefined).description === undefined`).(bool), true)
    testing.expect_value(t, run(`Symbol("").description === ""`).(bool), true)
    testing.expect_value(t, run(`Symbol("x").description + String(Symbol())`).(string), "xSymbol()")
}

@(test)
new_symbol_lanca_type_error :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var r="nao lancou"; try { new Symbol() } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`var r="nao lancou"; try { new Symbol("x") } catch (e) { r = e instanceof TypeError } r`).(bool), true)
    testing.expect_value(t, run(`typeof Symbol("ok")`).(string), "symbol") // chamada sem new segue valendo
}

@(test)
object_de_symbol_e_um_wrapper :: proc(t: ^testing.T) {
    src := `
        var s = Symbol("x"), o = Object(s);
        [typeof o, o instanceof Symbol, o.valueOf() === s, o.toString(), o.description,
         Object.prototype.toString.call(o), o == s, o === s, Object(s) !== Object(s)].join()
    `
    testing.expect_value(t, run(src).(string), "object,true,true,Symbol(x),x,[object Symbol],true,false,true")
    testing.expect_value(t, run(`Object.prototype.toString.call(Symbol())`).(string), "[object Symbol]")
}

// ToPropertyKey: objeto como chave passa por ToPrimitive(hint string).
@(test)
objeto_como_chave_usa_to_primitive :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var o={}; o[{toString(){return "a"}}]=1; o.a`).(f64), 1)
    testing.expect_value(t, run(`var o={a:5}; o[{toString(){return "a"}}]`).(f64), 5)
    testing.expect_value(t, run(`var o={}; o[[1,2]]=3; o["1,2"]`).(f64), 3)
    testing.expect_value(t, run(`var o={}; o[{[Symbol.toPrimitive](h){return h}}]=1; Object.keys(o)[0]`).(string), "string")
    // o wrapper de símbolo chega ao SÍMBOLO (não a "Symbol(k)")
    testing.expect_value(t, run(`var s=Symbol("k"), o={}; o[s]=7; o[Object(s)]`).(f64), 7)
    testing.expect_value(t, run(`var s=Symbol("k"), o={[Object(s)]: 3}; o[s]`).(f64), 3)
    testing.expect_value(t, run(`var s=Symbol("k"), o={}; o[s]=1; String(Object(s) in o) + o.hasOwnProperty(Object(s))`).(string), "truetrue")
    // exceção do toString da chave propaga
    testing.expect_value(t, run(`var e0={}, r="nao lancou"; try { ({})[{toString(){throw e0}}] } catch (e) { r = e === e0 } r`).(bool), true)
}

@(test)
array_prototype_unscopables :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var u = Array.prototype[Symbol.unscopables]; typeof u + Object.getPrototypeOf(u) + u.values + u.flat + String(u.map)`).(string), "objectnulltruetrueundefined")
    testing.expect_value(t, run(`Object.keys(Array.prototype[Symbol.unscopables]).sort().join()`).(string),
        "at,copyWithin,entries,fill,find,findIndex,findLast,findLastIndex,flat,flatMap,includes,keys,toReversed,toSorted,toSpliced,values")
    testing.expect_value(t, run(`var d = Object.getOwnPropertyDescriptor(Array.prototype, Symbol.unscopables); [d.writable, d.enumerable, d.configurable].join()`).(string), "false,false,true")
    // o `with` lê o objeto de verdade (antes: lista fixa por dentro)
    testing.expect_value(t, run(`var keys = "fora", values = "fora"; var r; with ([1,2]) { r = [typeof keys, typeof values, typeof map, length].join() } r`).(string), "string,string,function,2")
    testing.expect_value(t, run(`delete Array.prototype[Symbol.unscopables]; var values = "fora"; var r; with ([]) { r = typeof values } r`).(string), "function")
    testing.expect_value(t, run(`Array.prototype[Symbol.unscopables].push = true; var push = "fora"; var r; with ([]) { r = typeof push } r`).(string), "string")
}
