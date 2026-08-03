package js

// M210 — os dois gaps de HOST que sobraram no github.com depois do M209, ambos da
// família "stub que devolve valor neutro" (a página fica errada em SILÊNCIO):
//
// A) `document.createElement("<custom-element>")` NÃO construía o elemento. Só
//    promovíamos na INSERÇÃO, mas a spec constrói no createElement — e o Turbo cria
//    um `turbo-frame` SÓ para ler o protótipo do `delegate`, sem nunca inserir:
//       Object.getPrototypeOf(document.createElement("turbo-frame").delegate)
//    `.delegate` vinha undefined ⇒ `Cannot read properties of null (reading
//    'requestErrored')`. (O `null` em vez de TypeError é outra leniência antiga,
//    anotada no fim.)
//
// B) `document.domain` não existia. O helper de cookie do github faz
//    `if (null == s) throw Error("Unable to get document domain")` — o módulo de
//    sessão inteiro morria numa propriedade de uma linha.
//
// A armadilha do fix de (A): a marca de "já promovido" era UMA só. Construir no
// createElement e reusar a mesma marca faria o connectedCallback da INSERÇÃO ser
// pulado para sempre — trocar um bug por outro, mais silencioso. Por isso a
// construção e a conexão têm marcas separadas, e é isso que os dois primeiros
// testes abaixo medem.
//
// Conferido contra o Chrome headless (9 checagens de `document.createElement` de
// custom element); o que segue divergindo de propósito está anotado no fim.

import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
run_ce :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── A: createElement CONSTRÓI o custom element ───────────────────────────────

@(test)
m210_create_element_roda_o_construtor :: proc(t: ^testing.T) {
    // a forma exata do Turbo: cria só p/ ler o que o constructor instalou
    src := `
        class F extends HTMLElement {
            constructor(){ super(); this.delegate = { requestErrored: function(){ return "orig" } } }
        }
        customElements.define("turbo-frame", F);
        var el = document.createElement("turbo-frame");
        var proto = Object.getPrototypeOf(el.delegate);
        (typeof el.delegate === "object" && proto !== null) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_ce(src).(string), "ok")
}

@(test)
m210_connected_so_na_insercao_e_uma_vez :: proc(t: ^testing.T) {
    // A armadilha do fix: construção e conexão precisam de marcas SEPARADAS.
    // Com marca única daria "ctor" (o connected some) ou "ctor,connected" já no
    // createElement (dispara com o nó solto). O certo é ctor no create, connected
    // no append, e UMA vez só.
    src := `
        var marcas = [];
        class X extends HTMLElement {
            constructor(){ super(); marcas.push("ctor") }
            connectedCallback(){ marcas.push("connected") }
        }
        customElements.define("x-seq", X);
        var el = document.createElement("x-seq");
        marcas.push("|criado");
        document.body.appendChild(el);
        marcas.join(",")
    `
    testing.expect_value(t, run_ce(src).(string), "ctor,|criado,connected")
}

@(test)
m210_create_element_liga_prototype_e_campos :: proc(t: ^testing.T) {
    // o resto do contrato do upgrade tem de valer no createElement também
    src := `
        class Base extends HTMLElement { opcoes = { host: this } }
        class X extends Base { metodo(){ return "meu" } }
        customElements.define("x-completo", X);
        var el = document.createElement("x-completo");
        (el.metodo() === "meu" && el instanceof X && el instanceof HTMLElement
            && el.opcoes.host === el && el.constructor === X) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_ce(src).(string), "ok")
}

@(test)
m210_create_element_nao_promove_o_que_nao_e_registrado :: proc(t: ^testing.T) {
    // CONTROLE: sem definição, o elemento continua um elemento comum — o fix não
    // pode ter passado a rodar construtor de tag qualquer.
    src := `
        var el = document.createElement("x-nao-definido");
        (el.tagName === "X-NAO-DEFINIDO" && el.metodo === undefined) ? "ok" : "falhou"
    `
    testing.expect_value(t, run_ce(src).(string), "ok")
}

@(test)
m210_create_element_construtor_que_lanca_nao_derruba :: proc(t: ^testing.T) {
    // mesma filosofia tolerante do upgrade na inserção: o componente que lança não
    // pode envenenar quem chamou o createElement
    src := `
        class Mau extends HTMLElement { constructor(){ super(); nadaAqui.explode() } }
        customElements.define("x-mau", Mau);
        var el = document.createElement("x-mau");
        (el && el.tagName === "X-MAU") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_ce(src).(string), "ok")
}

@(test)
m210_create_element_case_insensitive :: proc(t: ^testing.T) {
    // o registry guarda em minúsculo; `createElement("TURBO-FRAME")` tem de achar
    src := `
        class X extends HTMLElement { constructor(){ super(); this.marca = 1 } }
        customElements.define("x-caixa", X);
        document.createElement("X-CAIXA").marca === 1 ? "ok" : "falhou"
    `
    testing.expect_value(t, run_ce(src).(string), "ok")
}

// ── B: document.domain ───────────────────────────────────────────────────────

@(test)
m210_document_domain :: proc(t: ^testing.T) {
    // sem base_url, o fallback é o mesmo do document.URL
    testing.expect_value(t, run_ce(`typeof document.domain`).(string), "string")
    testing.expect_value(t, run_ce(`document.domain.length > 0 ? "ok" : "vazio"`).(string), "ok")
    // é o teste EXATO que o github faz antes de lançar
    testing.expect_value(t, run_ce(`(null == document.domain) ? "lanca" : "ok"`).(string), "ok")
}

@(test)
m210_document_domain_e_o_hostname_sem_porta :: proc(t: ^testing.T) {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    dom.append_child(root, html)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm.base_url = strings.clone("https://github.com:8443/features/copilot?a=1#x")
    testing.expect_value(t, vm_run(vm, `document.domain`).(string), "github.com")
    // e a ESCRITA vence a leitura derivada (a prop é depreciada mas legal, e o
    // get-hook roda antes das props próprias — sem a guarda, o valor escrito
    // ficaria invisível)
    vm_run(vm, `document.domain = "github.com"`)
    testing.expect_value(t, vm_run(vm, `document.domain`).(string), "github.com")
}

// DEGRADAÇÃO CONHECIDA (anterior a este marco, exposta pelo oráculo do Chrome ao
// conferir (A)): `Object.getPrototypeOf(undefined)` e `(null)` devolvem `null` aqui
// e LANÇAM "Cannot convert undefined or null to object" no Chrome. É a leniência
// antiga do motor, e o preço dela apareceu neste caso: em vez de um TypeError com o
// nome certo, o github recebeu um `null` e só quebrou uma linha depois, com uma
// mensagem que não aponta para a causa. Mexer ali afeta toda leitura de protótipo e
// é marco próprio.
