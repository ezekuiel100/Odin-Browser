package js

// Namespace PARCIAL de módulo em CICLO (achado ao investigar por que o github.com
// não roda nenhum JS).
//
// O bundler do GitHub (rspack) emite módulos que importam a SI MESMOS, para
// entregar o próprio namespace ao runtime que registra os módulos:
//
//     export const __rspack_esm_ids = [85363];
//     export const __webpack_modules__ = { … };
//     import * as r from "./ele-mesmo.js";      // ← ciclo de 1 elo
//     e.C(r);                                    // runtime: d = r.__rspack_esm_ids
//                                                //          … n < d.length
//
// Como `import` é HOISTED por spec, quando `e.C(r)` roda os três `export const`
// já foram avaliados e o namespace tem os valores. Nós instalávamos o get-hook de
// live binding (M139) só no FIM da avaliação, então dentro do ciclo o namespace
// vinha VAZIO: `d` = undefined, `d.length` lançava
// `Cannot read properties of undefined (reading 'length')`, o módulo virava
// .Failed e o importador lia `__rspack_esm_ids` de undefined — o grafo INTEIRO
// caía em cascata e o site ficava sem JS nenhum.
//
// A correção é uma consequência do próprio desenho do M139: o hook JÁ relê o
// escopo do módulo a cada acesso, só estava sendo ligado tarde demais.

import "core:fmt"
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
ciclo_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = stub_resolve
    vm.module_fetch = stub_fetch
    vm.module_stubs = make(map[string]string)
    return vm
}

// Forma exata do módulo do rspack, reduzida.
@(private = "file")
RSPACK_SELF :: `
    export const __rspack_esm_ids = [85363];
    export const __webpack_modules__ = { um: 1, dois: 2 };
    import * as r from "app.js";
    vistoIds = r.__rspack_esm_ids ? r.__rspack_esm_ids.length : -1;
    vistoMods = r.__webpack_modules__ ? "sim" : "nao";
`

@(test)
ciclo_auto_import_ve_os_exports_ja_avaliados :: proc(t: ^testing.T) {
    vm := ciclo_vm(); defer vm_free(vm)
    vm.module_stubs["app.js"] = RSPACK_SELF
    vm_run_module(vm, `import * as m from "app.js"; fora = m.__rspack_esm_ids.length;`)

    // é isto que o `e.C(r)` do rspack faz e que lançava
    testing.expect_value(t, as_number(vm_run(vm, `vistoIds`)), 1)
    testing.expect_value(t, vm_run(vm, `vistoMods`).(string), "sim")
    // e o importador de fora continua enxergando (não pode ter regredido)
    testing.expect_value(t, as_number(vm_run(vm, `fora`)), 1)
}

@(test)
ciclo_auto_import_avalia_uma_vez_so :: proc(t: ^testing.T) {
    // o registry é a guarda de ciclo: auto-import tem de bater no cache, não
    // re-avaliar o corpo (senão todo efeito colateral do módulo acontece 2×).
    vm := ciclo_vm(); defer vm_free(vm)
    // ⚠️ sem `globalThis` de propósito: este vm é `vm_create()` puro (sem DOM) e lá
    // `globalThis` não existe — atribuição solta é o idioma dos testes vizinhos.
    vm.module_stubs["app.js"] = `
        vezes = (typeof vezes === "undefined" ? 0 : vezes) + 1;
        export const pronto = true;
        import * as r from "app.js";
        viu = r.pronto === true;
    `
    vm_run_module(vm, `import * as m from "app.js";`)
    testing.expect_value(t, as_number(vm_run(vm, `vezes`)), 1)
    testing.expect_value(t, vm_run(vm, `String(viu)`).(string), "true")
}

// ── o SCRIPT DE ENTRADA também é um módulo do registry (M209) ────────────────
// Os dois testes acima cobrem o auto-import de um módulo IMPORTADO (que passa por
// load_module e portanto pelo registry). O `<script type="module" src=U>` não
// passava: `vm_run_module` criava um módulo efêmero, fora do registry. Como cada
// bundle do rspack termina se auto-importando, a URL não batia no cache e o bundle
// INTEIRO era baixado e avaliado outra vez — 8 bundles × 2 no github.com, com o
// landing-pages de 2,6 MB entre eles. Pior: quando a 2ª avaliação lançava, o
// `import * as` do topo bindava undefined e o runtime lia `.__rspack_esm_ids` dele.

@(test)
entry_script_com_src_entra_no_registry :: proc(t: ^testing.T) {
    vm := ciclo_vm(); defer vm_free(vm)
    vm.module_stubs["app.js"] = `
        vezes = (typeof vezes === "undefined" ? 0 : vezes) + 1;
        export const __rspack_esm_ids = [85363];
        import * as r from "app.js";
        vistoIds = r.__rspack_esm_ids ? r.__rspack_esm_ids.length : -1;
    `
    // é o caminho do <script type="module" src="app.js">: a fonte já veio na mão,
    // a URL é a do src
    vm_run_module(vm, vm.module_stubs["app.js"], "app.js")
    testing.expect_value(t, as_number(vm_run(vm, `vezes`)), 1)     // 1 avaliação, não 2
    testing.expect_value(t, as_number(vm_run(vm, `vistoIds`)), 1)  // e o ns do ciclo é VIVO
    testing.expect_value(t, vm.modules_loaded, 0)                  // o entry não gastou vaga do teto
}

@(test)
entry_script_compartilha_o_modulo_com_quem_importa :: proc(t: ^testing.T) {
    // O outro ganho: os 8 bundles do github importam "./wp-runtime.js", que TAMBÉM é
    // um <script type="module">. Fora do registry, o runtime era instanciado 2× (um
    // por caminho) e cada metade do site falava com um estado diferente.
    vm := ciclo_vm(); defer vm_free(vm)
    vm.module_stubs["runtime.js"] = `
        vezes = (typeof vezes === "undefined" ? 0 : vezes) + 1;
        export const marca = {};
    `
    vm_run_module(vm, vm.module_stubs["runtime.js"], "runtime.js") // <script src=runtime.js>
    vm_run_module(vm, `import * as r from "runtime.js"; doImport = r.marca;`, "outro.js")
    vm_run(vm, `porScript = (function(){ return marca === undefined })()`) // marca não vaza p/ o global
    testing.expect_value(t, as_number(vm_run(vm, `vezes`)), 1) // avaliado uma única vez
    testing.expect_value(t, vm_run(vm, `String(typeof doImport)`).(string), "object")
}

@(test)
entry_script_INLINE_nao_entra_no_registry :: proc(t: ^testing.T) {
    // CONTROLE do recorte: módulo inline não tem URL própria (a dele é a do
    // documento). Registrar o documento criaria uma entrada que especificador nenhum
    // deveria alcançar — e dois inlines na mesma página colidiriam.
    vm := ciclo_vm(); defer vm_free(vm)
    vm_run_module(vm, `um = 1;`)
    vm_run_module(vm, `dois = 2;`)
    testing.expect_value(t, len(vm.modules), 0)
    testing.expect_value(t, as_number(vm_run(vm, `um + dois`)), 3)
}

@(test)
ciclo_de_dois_elos_ve_o_que_ja_rodou :: proc(t: ^testing.T) {
    // Caso geral A→B→A. Em B, o namespace de A tem o que A já avaliou ANTES do
    // import de B (`antes`), e ainda não tem o que vem depois (`depois`) — que é
    // exatamente o que a spec promete p/ ciclo, e o motivo de o hook ser VIVO:
    // quando A termina, uma leitura nova de B enxerga `depois`.
    vm := ciclo_vm(); defer vm_free(vm)
    vm.module_stubs["a.js"] = `
        export const antes = "A-antes";
        import * as b from "b.js";
        export const depois = "A-depois";
        bViuAntes = b.viuAntes;
        bViuDepois = b.viuDepois;
    `
    vm.module_stubs["b.js"] = `
        import * as a from "a.js";
        export const viuAntes = String(a.antes);
        export const viuDepois = String(a.depois);
        // leitura TARDIA: o hook é vivo, então depois que A terminar isto muda
        leDeNovo = function(){ return String(a.depois) };
    `
    vm_run_module(vm, `import * as m from "a.js";`)
    testing.expect_value(t, vm_run(vm, `bViuAntes`).(string), "A-antes")
    testing.expect_value(t, vm_run(vm, `bViuDepois`).(string), "undefined") // ainda não rodou
    testing.expect_value(t, vm_run(vm, `leDeNovo()`).(string), "A-depois")  // agora sim (vivo)
}

// ── teto de módulos ──────────────────────────────────────────────────────────────
// O `MAX_SHEETS` do M204 contava ELEMENTO `<link>` em vez de URL, e por isso cortava
// uma página no meio mesmo tendo orçamento de sobra. Aqui a unidade está certa (o
// cache hit sai antes do incremento), e este teste é o que impede que ela regrida:
// importar a MESMA URL N vezes não pode consumir N vagas.

@(test)
teto_de_modulos_conta_URL_UNICA :: proc(t: ^testing.T) {
    vm := ciclo_vm(); defer vm_free(vm)
    // um módulo só, importado muitas vezes por muitos importadores
    vm.module_stubs["um.js"] = `export const v = 1;`
    sb := strings.builder_make(context.temp_allocator)
    for i in 0 ..< MAX_MODULES + 50 {
        strings.write_string(&sb, `import * as a`)
        strings.write_int(&sb, i)
        strings.write_string(&sb, ` from "um.js";`)
    }
    strings.write_string(&sb, `fim = a0.v + a1.v;`)
    vm_run_module(vm, strings.to_string(sb))
    testing.expect_value(t, vm.modules_loaded, 1) // 1 URL = 1 vaga, não MAX+50
    testing.expect_value(t, as_number(vm_run(vm, `fim`)), 2)
}

@(test)
teto_de_modulos_corta_no_limite :: proc(t: ^testing.T) {
    // CONTROLE do teste acima: com URLs DISTINTAS o teto realmente corta — senão
    // o `conta_URL_UNICA` passaria mesmo com o teto quebrado.
    vm := ciclo_vm(); defer vm_free(vm)
    sb := strings.builder_make(context.temp_allocator)
    for i in 0 ..< MAX_MODULES + 20 {
        nome := fmt.tprintf("m%d.js", i)
        vm.module_stubs[strings.clone(nome)] = `export const v = 1;`
        strings.write_string(&sb, `import * as a`)
        strings.write_int(&sb, i)
        strings.write_string(&sb, ` from "`)
        strings.write_string(&sb, nome)
        strings.write_string(&sb, `";`)
    }
    vm_run_module(vm, strings.to_string(sb))
    testing.expect_value(t, vm.modules_loaded, MAX_MODULES)
}

@(test)
ciclo_nao_quebra_o_caso_aciclico :: proc(t: ^testing.T) {
    // CONTROLE: o caminho comum (sem ciclo) tem de continuar idêntico, incluindo
    // `default` e o export adiado que o M139 tornou vivo.
    vm := ciclo_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `
        var A;
        function init(){ A = "tarde" }
        export default 7;
        export { A as x, init };
        export const y = "cedo";
    `
    vm_run_module(vm, `
        import d, { x, init, y } from "dep.js";
        import * as ns from "dep.js";
        padrao = d; cedo = y; antes = String(x);
        init();
        depois = String(x); porNs = String(ns.x);
    `)
    testing.expect_value(t, as_number(vm_run(vm, `padrao`)), 7)
    testing.expect_value(t, vm_run(vm, `cedo`).(string), "cedo")
    testing.expect_value(t, vm_run(vm, `antes`).(string), "undefined")
    testing.expect_value(t, vm_run(vm, `depois`).(string), "tarde")
    testing.expect_value(t, vm_run(vm, `porNs`).(string), "tarde")
}
