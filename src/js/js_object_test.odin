package js
import "core:testing"
@(test)
test_obj_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o={m(){return 3}}; o.m()`)), f64(3))
    testing.expect_value(t, as_number(run(`var o={add(a,b){return a+b}}; o.add(4,5)`)), f64(9))
}
@(test)
test_obj_method_this :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o={x:10, get2(){return this.x*2}}; o.get2()`)), f64(20))
}
@(test)
test_obj_getter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o={get x(){return 5}}; o.x`)), f64(5))
    testing.expect_value(t, as_number(run(`var o={_v:7, get v(){return this._v}}; o.v`)), f64(7))
}
@(test)
test_obj_setter :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var v=0; var o={set x(n){v=n}}; o.x=9; v`)), f64(9))
    testing.expect_value(t, as_number(run(`var o={_v:0, set v(n){this._v=n*2}, get v(){return this._v}}; o.v=5; o.v`)), f64(10))
}
@(test)
test_obj_get_as_key :: proc(t: ^testing.T) {
    // "get"/"set" como CHAVE normal (não seguidos de nome+()) continuam funcionando
    testing.expect_value(t, as_number(run(`var o={get:1, set:2}; o.get+o.set`)), f64(3))
}
@(test)
test_obj_esbuild_wrapper :: proc(t: ^testing.T) {
    // o helper `pr` do esbuild: arrow devolvendo objeto com getter/setter
    n := as_number(run(`
        var wm=new WeakMap();
        var pr=(u,i)=>({set _(o){i.set(u,o)}, get _(){return i.get(u)}});
        var obj={}; var w=pr(obj,wm);
        w._=42; w._
    `))
    testing.expect_value(t, n, f64(42))
}

@(test)
test_optional_chaining :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var o={a:{b:7}}; o?.a?.b`)), f64(7))
    testing.expect_value(t, as_number(run(`var o={a:[10,20]}; o?.a?.[1]`)), f64(20))
    testing.expect_value(t, as_number(run(`var o={m(){return 5}}; o.m?.()`)), f64(5))
    // curto-circuito: base nullish → undefined, sem lançar
    testing.expect(t, is_nullish(run(`var o=null; o?.a?.b`)), "o?.a?.b com o null = undefined")
    testing.expect(t, is_nullish(run(`var o={a:null}; o?.a?.b`)), "a nullish no meio da cadeia")
    testing.expect(t, is_nullish(run(`var o={}; o.m?.()`)), "chamada opcional de método ausente")
    // `?.` dentro de função NÃO quebra as chaves (era o bug do bundle esbuild)
    testing.expect_value(t, as_number(run(`function f(){ var o={a:1}; return o?.a } function g(){ return 3 } g()`)), f64(3))
    // ternário com decimal não confunde com ?.
    testing.expect_value(t, as_number(run(`var x=0; x ? .5 : 9`)), f64(9))
}

@(test)
test_symbol :: proc(t: ^testing.T) {
    // Symbol.for: mesma chave = mesmo símbolo; chaves distintas = distintos (o que o React exige)
    testing.expect(t, truthy(run(`Symbol.for('react.element') === Symbol.for('react.element')`)), "for mesma chave")
    testing.expect(t, !truthy(run(`Symbol.for('a') === Symbol.for('b')`)), "for chaves distintas")
    testing.expect(t, !truthy(run(`Symbol('x') === Symbol('x')`)), "Symbol() sempre único")
    v, _ := run(`typeof Symbol()`).(string)
    testing.expect_value(t, v, "symbol")
    testing.expect(t, !truthy(run(`Symbol.iterator === Symbol.asyncIterator`)), "well-known distintos")
}

@(test)
test_function_prototype :: proc(t: ^testing.T) {
    // construtor-função comum (não class): métodos no .prototype são herdados por new
    src := `
        function Root(x){ this.x = x; }
        Root.prototype.get = function(){ return this.x; };
        var r = new Root(42);
        r.get()
    `
    testing.expect_value(t, as_number(run(src)), f64(42))
    // .prototype é auto-criado e estável
    testing.expect(t, truthy(run(`function F(){}; F.prototype === F.prototype`)), "prototype estável")
    testing.expect(t, truthy(run(`function F(){}; var f=new F(); f.constructor === F`)), "constructor")
}
