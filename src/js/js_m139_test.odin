package js

// M139 — LIVE BINDINGS de módulo ES. A raiz do cluster "módulo que exporta vazio".
//
// Nossos exports eram um SNAPSHOT tirado no fim da avaliação do módulo (limitação
// que o próprio cabeçalho do module.odin documentava). A spec manda que sejam
// bindings VIVOS: o importador enxerga a variável do exportador, não uma cópia.
//
// A diferença é observável sempre que o exportador atribui o valor DEPOIS de rodar
// o corpo — inicialização preguiçosa, que é idioma comum em bundle. O caso que
// achei no crates.io (chunk do Svelte 5):
//
//     var Ln, Rn;
//     function Hn(){ if (Ln === void 0) { Ln = window, Rn = document, … } }
//     export { Ln as tt, Rn as et };
//
// Com cópia, `tt`/`et` ficavam undefined PARA SEMPRE no importador — e o breadcrumb
// do M109 dizia isso em voz alta na saída (`[js] import: 'tt' de … veio undefined`),
// eu é que demorei a olhar para ele.

import "core:strings"
import "core:testing"

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
m139_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = stub_resolve
    vm.module_fetch = stub_fetch
    vm.module_stubs = make(map[string]string)
    return vm
}

// O idioma exato do bundle do crates.io.
@(private = "file")
DEP_PREGUICOSO :: `
    var A, B;
    function init(){ A = "janela"; B = "documento" }
    export { A as x, B as y, init };
`

@(test)
m139_import_ve_o_valor_atribuido_depois :: proc(t: ^testing.T) {
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = DEP_PREGUICOSO
    vm_run_module(vm, `
        import { x, y, init } from "dep.js";
        antes = String(x) + "/" + String(y);
        init();
        depois = String(x) + "/" + String(y);
    `)
    testing.expect_value(t, vm_run(vm, `antes`).(string), "undefined/undefined")
    testing.expect_value(t, vm_run(vm, `depois`).(string), "janela/documento")
}

@(test)
m139_namespace_tambem_e_vivo :: proc(t: ^testing.T) {
    // `import * as ns` e o namespace do import() dinâmico seguem a mesma regra.
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = DEP_PREGUICOSO
    vm_run_module(vm, `
        import * as ns from "dep.js";
        antes = String(ns.x);
        ns.init();
        depois = String(ns.x);
    `)
    testing.expect_value(t, vm_run(vm, `antes`).(string), "undefined")
    testing.expect_value(t, vm_run(vm, `depois`).(string), "janela")
}

@(test)
m139_import_dinamico_vivo :: proc(t: ^testing.T) {
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = DEP_PREGUICOSO
    vm_run(vm, `
        var got = "";
        import("dep.js").then(function(ns){ ns.init(); got = String(ns.x) + "/" + String(ns.y) });
    `)
    testing.expect_value(t, vm_run(vm, `got`).(string), "janela/documento")
}

@(test)
m139_renomeando_no_import_e_no_export :: proc(t: ^testing.T) {
    // O alias tem que atravessar DOIS renomes (local→exportado→importado), que é o
    // que um bundle minificado sempre faz.
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = DEP_PREGUICOSO
    vm_run_module(vm, `
        import { x as meuX, init as ligar } from "dep.js";
        ligar();
        resultado = String(meuX);
    `)
    testing.expect_value(t, vm_run(vm, `resultado`).(string), "janela")
}

@(test)
m139_reatribuicao_no_exportador_propaga :: proc(t: ^testing.T) {
    // Não é só o 1º valor: cada leitura relê a variável do exportador.
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["c.js"] = `
        var n = 0;
        function inc(){ n = n + 1 }
        export { n, inc };
    `
    vm_run_module(vm, `
        import { n, inc } from "c.js";
        inc(); inc(); inc();
        total = n;
    `)
    testing.expect_value(t, as_number(vm_run(vm, `total`)), 3)
}

// ── não-regressão do que já funcionava ───────────────────────────────────────

@(test)
m139_export_com_valor_no_corpo_intacto :: proc(t: ^testing.T) {
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["v.js"] = `export const x = 42; export function f(){ return 7 }`
    vm_run_module(vm, `import { x, f } from "v.js"; soma = x + f();`)
    testing.expect_value(t, as_number(vm_run(vm, `soma`)), 49)
}

@(test)
m139_export_default_intacto :: proc(t: ^testing.T) {
    // `export default <expr>` é valor imediato na spec (não é binding nomeado):
    // continua sendo cópia, e é o correto.
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["d.js"] = `export default 5;`
    vm_run_module(vm, `import d from "d.js"; valor = d;`)
    testing.expect_value(t, as_number(vm_run(vm, `valor`)), 5)
}

@(test)
m139_reexport_intacto :: proc(t: ^testing.T) {
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["base.js"] = `export const a = 1;`
    vm.module_stubs["meio.js"] = `export { a } from "base.js";`
    vm_run_module(vm, `import { a } from "meio.js"; valor = a;`)
    testing.expect_value(t, as_number(vm_run(vm, `valor`)), 1)
}

@(test)
m139_variavel_local_nao_e_sombreada_pelo_alias :: proc(t: ^testing.T) {
    // O alias mora no escopo do módulo importador; uma variável local de função com
    // o mesmo nome continua vencendo (o env_get acha `vars` antes de `aliases`).
    vm := m139_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = DEP_PREGUICOSO
    vm_run_module(vm, `
        import { x } from "dep.js";
        function f(){ var x = "local"; return x }
        resultado = f();
    `)
    testing.expect_value(t, vm_run(vm, `resultado`).(string), "local")
}
