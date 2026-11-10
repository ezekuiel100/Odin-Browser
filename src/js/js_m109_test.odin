package js

import "core:strings"
import "core:testing"

// M109 — módulos ES: import() dinâmico + import/export estáticos + namespace.
// Gap-miner: `import is not a function` (5-7 sites, crates.io BLANK). Os testes
// usam um loader STUB em memória (vm.module_stubs) — sem rede: module_resolve é
// identidade e module_fetch serve do mapa (clona, pois load_module deleta a fonte).

@(private = "file")
stub_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    return strings.clone(specifier)
}

@(private = "file")
stub_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
    return "", false
}

@(private = "file")
m109_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = stub_resolve
    vm.module_fetch = stub_fetch
    vm.module_stubs = make(map[string]string)
    return vm
}

@(test)
m109_import_dinamico_namespace :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["mod.js"] = `export const x = 42; export function f(){ return 7; }`
    vm_run(vm, `var got = 0; import("mod.js").then(function(m){ got = m.x + m.f(); });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 49, "import() namespace: got %v", r)
}

@(test)
m109_export_default :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["d.js"] = `export default 5;`
    vm_run(vm, `var got; import("d.js").then(function(m){ got = m.default; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 5, "export default: got %v", r)
}

@(test)
m109_import_estatico_encadeado :: proc(t: ^testing.T) {
    // a.js importa {y} de b.js — o grafo carrega em profundidade
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["b.js"] = `export const y = 10;`
    vm.module_stubs["a.js"] = `import { y } from "b.js"; export const soma = y + 1;`
    vm_run(vm, `var got; import("a.js").then(function(m){ got = m.soma; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 11, "cadeia estática a→b: got %v", r)
}

@(test)
m109_import_star_as_ns :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["m.js"] = `export const a = 1; export const b = 2;`
    vm.module_stubs["uses.js"] = `import * as ns from "m.js"; export const total = ns.a + ns.b;`
    vm_run(vm, `var got; import("uses.js").then(function(m){ got = m.total; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 3, "import * as ns: got %v", r)
}

@(test)
m109_export_snapshot_adiado :: proc(t: ^testing.T) {
    // `export {a as b}` reflete o valor FINAL (atribuição após o export)
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["s.js"] = `var a = 1; export { a as b }; a = 2;`
    vm_run(vm, `var got; import("s.js").then(function(m){ got = m.b; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 2, "snapshot adiado exporta o valor final: got %v", r)
}

@(test)
m109_cache_identidade :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["c.js"] = `export const n = 1;`
    // ⚠️ lido na MESMA tarefa isto passava sem testar nada (undefined === undefined)
    vm_run(vm, `
        var m1, m2;
        import("c.js").then(function(m){ m1 = m; });
        import("c.js").then(function(m){ m2 = m; });
    `)
    r := vm_run(vm, `m1 !== undefined && m1 === m2`)
    b, _ := r.(bool)
    testing.expect(t, b, "mesmo especificador → mesmo namespace (cache)")
}

@(test)
m109_import_inexistente_rejeita :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm_run(vm, `
        var err = "";
        import("nope.js").then(function(){ err = "resolveu?!"; })
                          .catch(function(e){ err = "" + e; });
    `)
    r := vm_run(vm, `err`)
    s, _ := r.(string)
    testing.expectf(t, strings.contains(s, "nope.js"), "import() inexistente rejeita: got %q", s)
}

@(test)
m109_reexport :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["base.js"] = `export const k = 9; export const j = 4; export default 0;`
    vm.module_stubs["re.js"] = `export { k as kk } from "base.js"; export * from "base.js";`
    vm_run(vm, `
        var got;
        import("re.js").then(function(m){ got = m.kk + "," + m.k + "," + m.j + "," + (typeof m.default); });
    `)
    r := vm_run(vm, `got`)
    s, _ := r.(string)
    testing.expectf(t, s == "9,9,4,undefined", "re-export {as}/*: got %q", s)
}

@(test)
m109_import_meta_url :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["meta.js"] = `export const u = import.meta.url;`
    vm_run(vm, `var got; import("meta.js").then(function(m){ got = m.u; });`)
    r := vm_run(vm, `got`)
    s, _ := r.(string)
    testing.expectf(t, s == "meta.js", "import.meta.url = url do módulo: got %q", s)
}

@(test)
m109_default_import_binding :: proc(t: ^testing.T) {
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["lib.js"] = `export default function(){ return 33; }`
    vm.module_stubs["app.js"] = `import D from "lib.js"; export const r = D();`
    vm_run(vm, `var got; import("app.js").then(function(m){ got = m.r; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 33, "import default binding: got %v", r)
}

@(test)
m109_script_module_entrada :: proc(t: ^testing.T) {
    // o caminho do <script type="module">: vm_run_module com import estático
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `export const x = 21;`
    vm_run_module(vm, `import { x } from "dep.js"; resultadoGlobal = x * 2;`)
    r := vm_run(vm, `resultadoGlobal`)
    testing.expectf(t, as_number(r) == 42, "vm_run_module com import estático: got %v", r)
}

@(test)
m109_padrao_sveltekit :: proc(t: ^testing.T) {
    // o padrão real do crates.io (SvelteKit): export-list com renames no FIM do
    // módulo (`export{Xa as t, G}`), importador renomeia (`import{t as s}`) e
    // DESTRUTURA o objeto (`{onMount:U, tick:W} = s`).
    vm := m109_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `var Xa={onMount:2,tick:7};function G(){return 1}
export{Xa as t,G};`
    vm.module_stubs["main.js"] = `import{t as s,G as g}from"dep.js";const{onMount:U,tick:W}=s;export const r=W+g();`
    vm_run(vm, `var got; import("main.js").then(function(m){ got = m.r; }).catch(function(e){ got = ""+e; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 8, "padrão sveltekit (export-list+rename+destructure): got %v", r)
}

@(test)
m109_sem_hooks_import_rejeita :: proc(t: ^testing.T) {
    // vm PURO (sem hooks): import() rejeita em vez de estourar; estático é no-op
    r := run_settled(`
        var out = "";
        import("x.js").then(function(){ out = "resolveu?!"; })
                      .catch(function(e){ out = "rejeitou"; });
    `, "out")
    s, _ := r.(string)
    testing.expectf(t, s == "rejeitou", "sem hooks: import() rejeita: got %q", s)
}
