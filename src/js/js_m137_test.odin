package js

// M137 — peel do cluster "módulo que exporta vazio", começando pelo crates.io
// (BLANK, com `Failed to fetch dynamically imported module: ../nodes/0.js`).
//
// A raiz NÃO era o carregamento de módulo: era **resolução de URL**, em quatro
// pontos que se encadeavam.
//
// 1. REFERRER DO `import()` ERA DINÂMICO. `eval_import_call` perguntava
//    `vm.current_module` NA HORA DA CHAMADA. A spec captura o script ativo na
//    COMPILAÇÃO — é léxico. Todo `import()` que roda depois que o módulo terminou
//    (callback de timer, o padrão do SvelteKit) caía no `vm.base_url` = a PÁGINA, e
//    `../nodes/0.js` resolvia contra `/` em vez de `/assets/app/`. Reproduzido com
//    servidor HTTP local antes de mexer; o sintoma bateu byte a byte com o do site.
//    Agora o nó de import()/import.meta carrega a URL do que foi parseado.
//
// 2. `web_str` (o ToString das APIs web) não passava pelo ToPrimitive, então
//    `new URL(x, outraURL)` e `new URL(location)` viravam "[object Object]".
//
// 3. `document.baseURI`/`URL` não existiam e `location` não tinha `toString`.
//
// 4. A Response do `fetch()` era um objeto PARALELO e pobre — sem `headers` e sem
//    `url` (o `new Response()` construído tinha). `r.headers.get("content-type")`
//    é o passo seguinte de quase todo cliente HTTP.

import "core:strings"
import "core:testing"
import dom "../dom"

// ── 1) referrer léxico do import() ───────────────────────────────────────────

// O hook `module_resolve` é um ponteiro de proc SEM contexto de usuário, então o
// referrer observado tem de sair por uma global. Global de ARQUIVO era compartilhada
// entre os quatro testes abaixo, e o harness do Odin roda testes em PARALELO: um
// zerava/escrevia enquanto o outro assertava (falha INTERMITENTE e simétrica —
// ora "" onde se esperava a URL, ora o inverso). `thread_local` dá uma cópia por
// thread do harness; cada teste roda inteiro numa thread só e zera a sua cópia em
// `m137_vm()`, então não há mais estado atravessando testes.
@(private = "file", thread_local)
g_last_referrer: string

@(private = "file")
rec_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    g_last_referrer = referrer
    return strings.clone(specifier)
}

@(private = "file")
rec_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
    return "", false
}

@(private = "file")
m137_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = rec_resolve
    vm.module_fetch = rec_fetch
    vm.module_stubs = make(map[string]string)
    vm.base_url = strings.clone("https://site.test/pagina.html")
    g_last_referrer = ""
    return vm
}

@(test)
m137_import_adiado_mantem_o_referrer_do_modulo :: proc(t: ^testing.T) {
    // O caso do SvelteKit: o import() é ESCRITO no módulo mas EXECUTADO depois que
    // ele terminou. Antes o referrer virava a página; agora é o módulo.
    vm := m137_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `export const x = 1;`
    vm_run_module(vm, `maisTarde = function(){ import("dep.js") }`,
        "https://site.test/assets/app/app.js")
    testing.expect_value(t, g_last_referrer, "") // ainda não chamou
    vm_run(vm, `maisTarde()`)
    testing.expect_value(t, g_last_referrer, "https://site.test/assets/app/app.js")
}

@(test)
m137_import_imediato_continua_com_o_referrer_certo :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o caminho síncrono (que já funcionava) não mudou.
    vm := m137_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `export const x = 1;`
    vm_run_module(vm, `import("dep.js")`, "https://site.test/assets/app/app.js")
    testing.expect_value(t, g_last_referrer, "https://site.test/assets/app/app.js")
}

@(test)
m137_import_meta_url_e_lexico :: proc(t: ^testing.T) {
    // Mesma raiz: import.meta.url dentro de callback dava a URL da PÁGINA.
    vm := m137_vm(); defer vm_free(vm)
    vm_run_module(vm, `leMeta = function(){ return import.meta.url }`,
        "https://site.test/assets/app/app.js")
    r := vm_run(vm, `leMeta()`)
    testing.expect_value(t, r.(string), "https://site.test/assets/app/app.js")
}

@(test)
m137_script_classico_cai_no_base_url :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: fora de módulo, o referrer segue sendo a página.
    vm := m137_vm(); defer vm_free(vm)
    vm.module_stubs["dep.js"] = `export const x = 1;`
    vm_run(vm, `import("dep.js")`)
    testing.expect_value(t, g_last_referrer, "https://site.test/pagina.html")
}

// ── 2) ToString das APIs web passa pelo ToPrimitive ──────────────────────────

@(test)
m137_url_aceita_outra_url_como_base :: proc(t: ^testing.T) {
    src := `new URL("x.js", new URL("http://h/a/b/c.js")).href`
    testing.expect_value(t, run(src).(string), "http://h/a/b/x.js")
}

@(test)
m137_url_aceita_objeto_com_tostring :: proc(t: ^testing.T) {
    src := `new URL({ toString: function() { return "http://h/z" } }).href`
    testing.expect_value(t, run(src).(string), "http://h/z")
}

@(test)
m137_url_com_string_continua_igual :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO do caminho comum.
    src := `new URL("../n/x.js", "http://h/a/b/c.js").href + "|" + new URL("http://h/q?a=1").search`
    testing.expect_value(t, run(src).(string), "http://h/a/n/x.js|?a=1")
}

// ── 3) baseURI / location.toString ───────────────────────────────────────────

@(private = "file")
run_page :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    if vm.base_url != "" do delete(vm.base_url)
    vm.base_url = strings.clone("https://site.test/dir/pagina.html")
    return vm_run(vm, src)
}

@(test)
m137_document_base_uri :: proc(t: ^testing.T) {
    testing.expect_value(t, run_page(`document.baseURI`).(string), "https://site.test/dir/pagina.html")
    testing.expect_value(t, run_page(`document.URL`).(string), "https://site.test/dir/pagina.html")
}

@(test)
m137_location_vira_string :: proc(t: ^testing.T) {
    // `new URL(location)` e `String(location)` são idioma de resolvedor de asset.
    testing.expect_value(t, run_page(`String(location)`).(string), "https://site.test/dir/pagina.html")
    testing.expect_value(t, run_page(`new URL("../x.js", document.baseURI).href`).(string),
        "https://site.test/x.js")
}

@(test)
m137_location_pathname_intacto :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o get-hook de location continua respondendo os campos.
    testing.expect_value(t, run_page(`location.pathname`).(string), "/dir/pagina.html")
}

// ── 4) Response do fetch é uma Response de verdade ───────────────────────────

@(test)
m137_response_construida_tem_headers_e_url :: proc(t: ^testing.T) {
    // O contrato que a Response do fetch passou a cumprir também (o caminho de rede
    // não dá p/ exercitar em teste puro; aqui fica o formato esperado).
    src := `
        var r = new Response("oi", { status: 201, headers: { "content-type": "application/json" } });
        r.status + "|" + r.headers.get("content-type") + "|" + r.ok
    `
    testing.expect_value(t, run(src).(string), "201|application/json|true")
}

@(test)
m137_headers_get_e_case_insensitive :: proc(t: ^testing.T) {
    // O código real escreve "Content-Type" e lê "content-type" (e vice-versa).
    src := `
        var h = new Headers({ "Content-Type": "text/html" });
        h.get("content-type") + "|" + h.get("CONTENT-TYPE")
    `
    testing.expect_value(t, run(src).(string), "text/html|text/html")
}
