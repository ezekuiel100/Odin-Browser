package js

// Testes de Object.defineProperty + getters/setters + enumerabilidade (#2 do
// roadmap SPA). Bundles transpilados por Babel/webpack dependem MUITO de
// Object.defineProperty (ex.: `Object.defineProperty(exports, "__esModule",
// {value:true})` e exports preguiçosos `Object.defineProperty(exports, k, {get})`).
// Rodar: odin test src/js

import "core:testing"

// Avalia `src` e espera bool true.
@(private = "file")
expect_js_true :: proc(t: ^testing.T, src: string, msg: string) {
    ok, _ := run(src).(bool)
    testing.expect(t, ok, msg)
}

// Avalia `src` e espera number == want.
@(private = "file")
expect_js_num :: proc(t: ^testing.T, src: string, want: f64, msg: string) {
    v, _ := run(src).(f64)
    testing.expect(t, v == want, msg)
}

// data descriptor: value é lido por ponto e por colchete.
@(test)
test_defprop_data_value :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = {}; Object.defineProperty(o, 'x', { value: 42 }); o.x === 42 && o['x'] === 42`,
        "defineProperty value deve ser lido por ponto e colchete")
}

// enumerable PADRÃO false: não aparece em Object.keys nem for-in.
@(test)
test_defprop_default_non_enumerable :: proc(t: ^testing.T) {
    expect_js_num(t,
        `var o = { a: 1 };
         Object.defineProperty(o, 'hidden', { value: 9 });
         var n = 0; for (var k in o) n++;
         n * 100 + Object.keys(o).length`,
        101, "prop via defineProperty (enumerable padrão false) não deve enumerar")
}

// enumerable:true aparece em keys/for-in.
@(test)
test_defprop_enumerable_true :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = {};
         Object.defineProperty(o, 'x', { value: 1, enumerable: true });
         Object.keys(o).length === 1 && Object.keys(o)[0] === 'x'`,
        "defineProperty enumerable:true deve aparecer em keys")
}

// getter accessor: lido por ponto e colchete, invoca a função.
@(test)
test_defprop_getter :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = { _v: 5 };
         Object.defineProperty(o, 'dobro', { get: function() { return this._v * 2; } });
         o.dobro === 10 && o['dobro'] === 10`,
        "getter via defineProperty deve computar por ponto e colchete")
}

// setter accessor: escrita por ponto E por colchete chama o setter.
@(test)
test_defprop_setter :: proc(t: ^testing.T) {
    expect_js_num(t,
        `var o = { _v: 0 };
         Object.defineProperty(o, 'v', {
            get: function() { return this._v; },
            set: function(x) { this._v = x + 1; }
         });
         o.v = 10;      // setter -> _v = 11
         o['v'] = 20;   // setter -> _v = 21
         o.v`,
        21, "setter via defineProperty deve rodar por ponto e colchete")
}

// getter enumerável (padrão dos exports do Babel) aparece em keys e values reflete o get.
@(test)
test_defprop_getter_enumerable :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var exports = {};
         Object.defineProperty(exports, 'foo', { enumerable: true, get: function() { return 7; } });
         Object.keys(exports).length === 1 &&
         Object.keys(exports)[0] === 'foo' &&
         Object.values(exports)[0] === 7`,
        "getter enumerável deve aparecer em keys e values deve refletir o get")
}

// Padrão do interop de módulos: __esModule não-enumerável não vaza em re-export.
@(test)
test_defprop_esmodule_interop :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var mod = { a: 1, b: 2 };
         Object.defineProperty(mod, '__esModule', { value: true });
         var target = {};
         for (var k in mod) target[k] = mod[k];
         mod.__esModule === true &&
         target.a === 1 && target.b === 2 &&
         !('__esModule' in target) &&
         Object.keys(target).length === 2`,
        "__esModule (não-enum) não deve entrar no re-export por for-in")
}

// hasOwnProperty reconhece data e accessor; 'in' também.
@(test)
test_defprop_has_own :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = {};
         Object.defineProperty(o, 'd', { value: 1 });
         Object.defineProperty(o, 'g', { get: function() { return 2; } });
         o.hasOwnProperty('d') && o.hasOwnProperty('g') && ('d' in o) && ('g' in o)`,
        "hasOwnProperty/in devem reconhecer data e accessor não-enumeráveis")
}

// getOwnPropertyNames inclui as não-enumeráveis; getOwnPropertyDescriptor descreve.
@(test)
test_defprop_descriptor_and_names :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = { visivel: 1 };
         Object.defineProperty(o, 'oculta', { value: 2 });
         var names = Object.getOwnPropertyNames(o);
         var d = Object.getOwnPropertyDescriptor(o, 'oculta');
         names.length === 2 && names.indexOf('oculta') >= 0 &&
         d.value === 2 && d.enumerable === false`,
        "getOwnPropertyNames vê ocultas; descriptor descreve value+enumerable")
}

// defineProperties aplica vários descritores de uma vez.
@(test)
test_defprops_bulk :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = {};
         Object.defineProperties(o, {
            a: { value: 1, enumerable: true },
            b: { get: function() { return 2; }, enumerable: true }
         });
         o.a === 1 && o.b === 2 && Object.keys(o).length === 2`,
        "defineProperties deve aplicar data e accessor em lote")
}

// defineProperty devolve o próprio objeto (encadeável, como os helpers do Babel).
@(test)
test_defprop_returns_object :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = {}; Object.defineProperty(o, 'x', { value: 1 }) === o`,
        "defineProperty deve devolver o objeto alvo")
}

// Mudar só enumerabilidade não deve zerar o valor existente.
@(test)
test_defprop_enum_only_keeps_value :: proc(t: ^testing.T) {
    expect_js_true(t,
        `var o = { x: 5 };
         Object.defineProperty(o, 'x', { enumerable: false });
         o.x === 5 && Object.keys(o).length === 0`,
        "defineProperty sem 'value' deve preservar o valor e só ocultar")
}
