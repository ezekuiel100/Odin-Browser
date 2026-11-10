package js

import "core:strings"
import "core:testing"

// M110 — nome de function/class EXPRESSION não vaza p/ o escopo externo (spec).
// A RAIZ do crates.io BLANK: o runtime do svelte tem `un=class e{...}` e o módulo
// importava `{n as e}` — o nome da class expression CLOBBERAVA o import binding
// `e`; depois `var Xa=e({...})` chamava a CLASSE (retorna undefined) em vez do
// helper de namespace → export `t` undefined → "reading 'tick'" → página em branco.

@(test)
m110_fn_expr_nao_vaza :: proc(t: ^testing.T) {
    r := run(`var f = function g(){ return 1; }; typeof g`)
    s, _ := r.(string)
    testing.expectf(t, s == "undefined", "nome de fn expression não vaza: got %q", s)
}

@(test)
m110_fn_expr_nao_clobbera_homonimo :: proc(t: ^testing.T) {
    r := run(`var g = 42; var f = function g(){ return 1; }; g`)
    testing.expectf(t, as_number(r) == 42, "fn expression não clobbera homônimo externo: got %v", r)
}

@(test)
m110_fn_expr_autorreferencia :: proc(t: ^testing.T) {
    // recursão pelo próprio nome (visível SÓ dentro do corpo)
    r := run(`var fact = function f(n){ return n < 2 ? 1 : n * f(n - 1); }; fact(5)`)
    testing.expectf(t, as_number(r) == 120, "auto-referência de fn expression: got %v", r)
}

@(test)
m110_class_expr_nao_vaza :: proc(t: ^testing.T) {
    r := run(`var C = class D{}; typeof D`)
    s, _ := r.(string)
    testing.expectf(t, s == "undefined", "nome de class expression não vaza: got %q", s)
}

@(test)
m110_class_expr_nao_clobbera :: proc(t: ^testing.T) {
    // o cenário EXATO do sveltekit: `e` externo sobrevive à class expression `class e{}`
    r := run(`
        var e = function(o){ return { ok: true, src: o }; };
        var un = class e { id = 1 };
        var Xa = e({ tick: 7 });
        (typeof Xa) + "," + Xa.ok + "," + Xa.src.tick
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "object,true,7", "class expression não clobbera `e` externo: got %q", s)
}

@(test)
m110_class_expr_autorreferencia_em_metodo :: proc(t: ^testing.T) {
    r := run(`
        var C = class D {
            clone(){ return new D(); }
        };
        (new C()).clone() instanceof C
    `)
    b, _ := r.(bool)
    testing.expect(t, b, "método referencia o nome da class expression (new D())")
}

@(test)
m110_class_decl_continua_bindando :: proc(t: ^testing.T) {
    r := run(`class X { v(){ return 3; } } (new X()).v()`)
    testing.expectf(t, as_number(r) == 3, "class DECLARATION binda o nome: got %v", r)
}

@(test)
m110_fn_decl_continua_bindando_e_icada :: proc(t: ^testing.T) {
    r := run(`var a = soma(2, 3); function soma(x, y){ return x + y; } a`)
    testing.expectf(t, as_number(r) == 5, "function DECLARATION içada + bindada: got %v", r)
}

@(test)
m110_cenario_sveltekit_modulo :: proc(t: ^testing.T) {
    // fim-a-fim no sistema de módulos: import binding `e` + class expression `class e`
    vm := vm_create()
    defer vm_free(vm)
    vm.module_resolve = m110_stub_resolve
    vm.module_fetch = m110_stub_fetch
    vm.module_stubs = make(map[string]string)
    vm.module_stubs["h.js"] = "var T=Object.defineProperty;export var mk=(e,n)=>{let r={};for(var i in e)T(r,i,{get:e[i],enumerable:!0});return r};export{mk as n};"
    vm.module_stubs["runtime.js"] = `import{n as e}from"h.js";
var un=class e{id=1;};
function Hr(){return 9}
var Xa=e({tick:()=>Hr});
export{Xa as t,un as U};`
    // {tick:()=>Hr}: o GETTER devolve a função Hr → W = Hr → W() = 9
    vm.module_stubs["app.js"] = `import{t as s}from"runtime.js";const{tick:W}=s;export const r=W();`
    vm_run(vm, `var got; import("app.js").then(function(m){ got = m.r; }).catch(function(e){ got = ""+e; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 9, "cenário sveltekit fim-a-fim: got %v", r)
}

@(private = "file")
m110_stub_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    return strings.clone(specifier)
}

@(private = "file")
m110_stub_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
    return "", false
}
