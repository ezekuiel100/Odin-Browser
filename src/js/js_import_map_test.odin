package js

import "core:strings"
import "core:testing"

// Import maps (import_map.odin). O caso real: a home do github.com faz
// `import "react"` e mapeia "react" → bundle com hash num <script type=importmap>.
// Sem o mapa, o React morria e o bloco principal (opacity:0 até a animação de
// entrada) ficava em branco.

DOC :: "https://github.com/"

@(private = "file")
im_vm :: proc(json_text: string) -> ^Interp {
    vm := vm_create()
    ok := import_map_register(vm, json_text, DOC)
    assert(ok, "JSON do import map de teste é válido")
    return vm
}

@(private = "file")
expect_resolve :: proc(t: ^testing.T, vm: ^Interp, spec, base, want: string, loc := #caller_location) {
    got, ok := import_map_resolve(vm, spec, base)
    testing.expectf(t, ok, "%q deveria resolver", spec, loc = loc)
    testing.expectf(t, got == want, "%q → %q, esperava %q", spec, got, want, loc = loc)
}

@(private = "file")
expect_fail :: proc(t: ^testing.T, vm: ^Interp, spec, base: string, loc := #caller_location) {
    got, ok := import_map_resolve(vm, spec, base)
    testing.expectf(t, !ok, "%q deveria FALHAR, resolveu %q", spec, got, loc = loc)
}

@(test)
import_map_github_react :: proc(t: ^testing.T) {
    vm := im_vm(`{"imports":{"react":"https://github.githubassets.com/assets/react-fa5e.js",
        "react/jsx-runtime":"https://github.githubassets.com/assets/react-jsx-runtime-49.js"}}`)
    defer vm_free(vm)
    mod := "https://github.githubassets.com/assets/core-3fcf.js"
    expect_resolve(t, vm, "react", mod, "https://github.githubassets.com/assets/react-fa5e.js")
    // `react/jsx-runtime` é chave PRÓPRIA (exata), não prefixo de `react`
    expect_resolve(t, vm, "react/jsx-runtime", mod, "https://github.githubassets.com/assets/react-jsx-runtime-49.js")
    // relativo segue relativo ao módulo importador
    expect_resolve(t, vm, "./chunk-1.js", mod, "https://github.githubassets.com/assets/chunk-1.js")
}

@(test)
import_map_nu_sem_mapa_falha :: proc(t: ^testing.T) {
    // spec: especificador nu sem mapeamento é TypeError — não `base + "/lodash"`
    vm := vm_create(); defer vm_free(vm)
    expect_fail(t, vm, "lodash", DOC)
    // e sem import map nenhum, relativo/absoluto continuam como antes
    expect_resolve(t, vm, "./a.js", "https://x.com/dir/m.js", "https://x.com/dir/a.js")
    expect_resolve(t, vm, "https://cdn.x/y.js", DOC, "https://cdn.x/y.js")
}

@(test)
import_map_prefixo_com_barra :: proc(t: ^testing.T) {
    vm := im_vm(`{"imports":{"lodash/":"https://cdn.x/lodash-es/", "lodash":"https://cdn.x/lodash-es/lodash.js"}}`)
    defer vm_free(vm)
    expect_resolve(t, vm, "lodash", DOC, "https://cdn.x/lodash-es/lodash.js")
    expect_resolve(t, vm, "lodash/fp/map.js", DOC, "https://cdn.x/lodash-es/fp/map.js")
    // backtracking: não pode escapar do prefixo mapeado
    expect_fail(t, vm, "lodash/../../segredo.js", DOC)
}

@(test)
import_map_chave_url_like_remapeia_url :: proc(t: ^testing.T) {
    // chave "/js/app.js" é normalizada contra o documento e casa o import absoluto
    vm := im_vm(`{"imports":{"/js/app.js":"/js/app-v2.js"}}`)
    defer vm_free(vm)
    expect_resolve(t, vm, "/js/app.js", DOC, "https://github.com/js/app-v2.js")
    expect_resolve(t, vm, "https://github.com/js/app.js", DOC, "https://github.com/js/app-v2.js")
}

@(test)
import_map_scopes_mais_especifico_vence :: proc(t: ^testing.T) {
    vm := im_vm(`{"imports":{"dep":"/dep-v1.js"},
        "scopes":{"/legado/":{"dep":"/dep-v0.js"}, "/legado/antigo/":{"dep":"/dep-vX.js"}}}`)
    defer vm_free(vm)
    expect_resolve(t, vm, "dep", "https://github.com/app.js", "https://github.com/dep-v1.js")
    expect_resolve(t, vm, "dep", "https://github.com/legado/m.js", "https://github.com/dep-v0.js")
    expect_resolve(t, vm, "dep", "https://github.com/legado/antigo/m.js", "https://github.com/dep-vX.js")
}

@(test)
import_map_valor_invalido_bloqueia :: proc(t: ^testing.T) {
    // valor nu (não URL-like) e prefixo "x/" → valor sem "/" final: a entrada
    // BLOQUEIA a resolução em vez de cair no fallback
    vm := im_vm(`{"imports":{"a":"nao-e-url", "b/":"/b.js", "c":42}}`)
    defer vm_free(vm)
    expect_fail(t, vm, "a", DOC)
    expect_fail(t, vm, "b/x.js", DOC)
    expect_fail(t, vm, "c", DOC)
}

@(test)
import_map_mescla_primeiro_vence :: proc(t: ^testing.T) {
    vm := im_vm(`{"imports":{"a":"/a1.js"}}`)
    defer vm_free(vm)
    testing.expect(t, import_map_register(vm, `{"imports":{"a":"/a2.js","b":"/b.js"}}`, DOC))
    expect_resolve(t, vm, "a", DOC, "https://github.com/a1.js")
    expect_resolve(t, vm, "b", DOC, "https://github.com/b.js")
    testing.expect(t, !import_map_register(vm, `{nao json`, DOC), "JSON inválido é recusado")
}

@(test)
report_error_relata_sem_lancar :: proc(t: ^testing.T) {
    // React 19 chama reportError(e); antes era ReferenceError e o erro real sumia
    vm := vm_create(); defer vm_free(vm)
    antes := vm.uncaught_total
    r := vm_run(vm, `var depois = "nao"; reportError(new TypeError("falha de hidratação")); depois = "sim"; depois`)
    s, _ := r.(string)
    testing.expectf(t, s == "sim", "reportError NÃO lança: got %v", r)
    testing.expect_value(t, vm.uncaught_total, antes + 1)
    if len(vm.uncaught_log) > 0 {
        testing.expectf(t, strings.contains(vm.uncaught_log[len(vm.uncaught_log) - 1], "falha de hidratação"),
            "o log leva a mensagem do erro: %q", vm.uncaught_log[len(vm.uncaught_log) - 1])
    }
    r2 := vm_run(vm, `typeof reportError`)
    s2, _ := r2.(string)
    testing.expect(t, s2 == "function")
}

@(test)
object_prototype_metodos_sao_proprios :: proc(t: ^testing.T) {
    // isPlainObject do zod (github.com): `schema.extend({...})` lançava
    // "expected a plain object" porque isPrototypeOf não era prop PRÓPRIA.
    vm := vm_create(); defer vm_free(vm)
    src := `
        function $(e){return "object"==typeof e&&null!==e&&!Array.isArray(e)}
        function I(e){if(!1===$(e))return!1;let t=e.constructor;if(void 0===t||"function"!=typeof t)return!0;
            let n=t.prototype;return!1!==$(n)&&!1!==Object.prototype.hasOwnProperty.call(n,"isPrototypeOf")}
        var hop = Object.prototype.hasOwnProperty;
        [I({a:1}), I(Object.create(null)), I(new (class X{})), I([]),
         hop.call(Object.prototype,"hasOwnProperty"), hop.call(Object.prototype,"valueOf"),
         hop.call(Object.prototype,"propertyIsEnumerable"), hop.call(Object.prototype,"toLocaleString"),
         Object.prototype.propertyIsEnumerable.call(Object.prototype,"isPrototypeOf"),
         Object.keys(Object.prototype).length,
         ({}).hasOwnProperty === Object.prototype.hasOwnProperty,
         ({a:1}).hasOwnProperty("a"), ({}).hasOwnProperty("isPrototypeOf")].join(",")`
    r := vm_run(vm, src)
    s, _ := r.(string)
    testing.expect_value(t, s, "true,true,false,false,true,true,true,true,false,0,true,true,false")
}

@(private = "file")
run_str :: proc(t: ^testing.T, vm: ^Interp, src: string, want: string, loc := #caller_location) {
    r := vm_run(vm, src)
    s, _ := r.(string)
    testing.expectf(t, s == want, "%s\n  got  %q\n  want %q", src, s, want, loc = loc)
}

@(test)
intl_segmenter_grafemas :: proc(t: ^testing.T) {
    // `new Intl.Segmenter` no topo do bundle landing-pages do github: sem ele, o
    // módulo morria. Grafemas = UAX #29 (emoji ZWJ e bandeira são UM segmento).
    vm := vm_create(); defer vm_free(vm)
    run_str(t, vm, `typeof new Intl.Segmenter`, "object")
    run_str(t, vm, `[...new Intl.Segmenter().segment("aé👨‍👩‍👧🇧🇷!")].map(s=>s.segment).join("|")`, "a|é|👨‍👩‍👧|🇧🇷|!")
    // index em UTF-16: 👨‍👩‍👧 ocupa 8 unidades
    run_str(t, vm, `[...new Intl.Segmenter().segment("a👨‍👩‍👧b")].map(s=>s.index).join(",")`, "0,1,9")
    run_str(t, vm, `var s=new Intl.Segmenter().segment("ab"); [Array.isArray(s), s.containing(1).segment, s.containing(5)===undefined, [...s][0].input].join(",")`,
        "false,b,true,ab")
    run_str(t, vm, `JSON.stringify(new Intl.Segmenter("pt-BR",{granularity:"word"}).resolvedOptions())`,
        `{"locale":"pt-BR","granularity":"word"}`)
    run_str(t, vm, `var n="nao"; try{new Intl.Segmenter("en",{granularity:"x"})}catch(e){n=e.name}; n`, "RangeError")
}

@(test)
intl_segmenter_palavras_e_frases :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    // valores conferidos contra o Chrome
    run_str(t, vm, `[...new Intl.Segmenter("en",{granularity:"word"}).segment("Don't stop, 3.14 now!")].map(s=>s.segment+(s.isWordLike?"*":"")).join("|")`,
        "Don't*| |stop*|,| |3.14*| |now*|!")
    run_str(t, vm, `[...new Intl.Segmenter("en",{granularity:"sentence"}).segment("Hi there. Pi is 3.14! Ok?")].map(s=>s.segment).join("|")`,
        "Hi there. |Pi is 3.14! |Ok?")
}

// Ponta a ponta pelo carregador de módulos: `import "react"` num módulo vai
// para a URL MAPEADA (o loader stub só serve essa URL).
@(private = "file")
im_resolve_hook :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    base := referrer != "" ? referrer : DOC
    url, ok := import_map_resolve(vm, specifier, base)
    return ok ? strings.clone(url) : ""
}

@(private = "file")
im_fetch_hook :: proc(vm: ^Interp, url: string) -> (string, bool) {
    if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
    return "", false
}

@(test)
import_map_ponta_a_ponta_no_loader :: proc(t: ^testing.T) {
    vm := im_vm(`{"imports":{"react":"https://cdn.x/react-123.js"}}`)
    defer vm_free(vm)
    vm.module_resolve = im_resolve_hook
    vm.module_fetch = im_fetch_hook
    vm.module_stubs = make(map[string]string)
    vm.module_stubs["https://cdn.x/react-123.js"] = `export const versao = 19;`
    vm.module_stubs["https://github.com/app.js"] = `import { versao } from "react"; export const v = versao;`
    vm_run(vm, `var got = 0; import("https://github.com/app.js").then(function(m){ got = m.v; });`)
    r := vm_run(vm, `got`)
    testing.expectf(t, as_number(r) == 19, "import \"react\" via import map: got %v", r)
}
