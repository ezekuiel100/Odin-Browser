package js

// Runner do Test262 — a suíte de conformidade oficial do ECMAScript (TC39).
//
// A DIVISÃO de trabalho espelha o par WPT (fetch-wpt.ps1 + wpt-reftest.ps1):
//   - test262.ps1  descobre os testes, lê o frontmatter (/*--- ... ---*/),
//     resolve os `includes` do harness/, aplica flags (onlyStrict/raw/...) e
//     compara o resultado com a expectativa `negative:`.
//   - browser.exe --js262 f1.js f2.js ...  só EXECUTA os arquivos, em ordem,
//     numa VM única (escopo global compartilhado, para o harness ficar visível
//     ao corpo do teste) e imprime UMA linha parseável com o veredito bruto.
//
// Linha de saída (stdout, sempre exit 0 — quem julga é o .ps1):
//   __262__ status=pass  rec=<n>
//   __262__ status=throw name=<Nome> phase=runtime source=<index> rec=<n> msg=...
// Recovery is diagnostic only. vm_exec has no genuine parse-error signal yet;
// parse negatives must fail until that signal exists, even for SyntaxError thrown
// by the test body. source distinguishes harness failures from test failures.

import "core:os"
import "core:fmt"
import "core:strings"

// Resultado bruto de rodar uma sequência de fontes numa VM.
Js262_Result :: struct {
    phase:      string,
    source:     int,
    threw:      bool,
    err_name:   string, // "TypeError" / "Test262Error" / "SyntaxError" / ...
    err_msg:    string, // primeira linha da mensagem
    recoveries: int,    // parse_recoveries acumuladas
}

// Executa cada fonte em ordem no MESMO vm (escopo global compartilhado). Para na
// primeira exceção não capturada. NÃO limpa a exceção entre fontes — o corpo do
// teste vê os helpers do harness definidos pelas fontes anteriores.
run_js262 :: proc(sources: []string) -> Js262_Result {
    vm := vm_create()
    defer vm_free(vm)

    failed_source := -1
    for src, i in sources {
        _ = vm_exec(vm, src)
        if vm.throwing { failed_source = i; break }
    }

    // vm_exec currently exposes runtime throws only. Parser recovery is not
    // evidence of a genuine SyntaxError and must never satisfy parse negatives.
    res := Js262_Result{ recoveries = vm.parse_recoveries, phase = "runtime", source = failed_source }
    if vm.throwing {
        res.threw = true
        res.err_name, res.err_msg = describe_thrown(vm)
        vm.throwing = false // limpo p/ o vm_free rodar sem exceção pendente
        vm.thrown   = nil
    }
    return res
}

// Extrai (nome, mensagem) do valor lançado. Usa get_member para atravessar a
// cadeia de protótipo: erros nativos têm props["name"]; o Test262Error do
// harness não tem `name` próprio, então caímos em constructor.name — que dá
// exatamente "Test262Error". get_member pode ele mesmo mexer em vm.throwing, por
// isso salvamos e restauramos o estado ao redor.
@(private = "file")
describe_thrown :: proc(vm: ^Interp) -> (name: string, msg: string) {
    saved_t := vm.thrown
    saved_f := vm.throwing
    defer { vm.thrown = saved_t; vm.throwing = saved_f }

    thrown := vm.thrown
    vm.throwing = false // p/ get_member não confundir com throw em andamento

    name = "Error"
    if nm := get_member(vm, thrown, "name"); !vm.throwing {
        if s, ok := nm.(string); ok && len(s) > 0 {
            name = s
        } else {
            vm.throwing = false
            ctor := get_member(vm, thrown, "constructor")
            vm.throwing = false
            if cn, ok2 := get_member(vm, ctor, "name").(string); ok2 && len(cn) > 0 {
                name = cn
            }
        }
    }
    vm.throwing = false

    // mensagem: .message se existir (cobre o Test262Error, cujo to_text daria só
    // "[object Object]"); senão o to_text (que formata "Name: message" p/ erros
    // nativos ou o valor cru p/ throw de string/número).
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    mv := get_member(vm, thrown, "message")
    vm.throwing = false
    if s, ok := mv.(string); ok && len(s) > 0 {
        strings.write_string(&sb, s)
    } else {
        to_text(&sb, thrown)
    }
    full := strings.to_string(sb)
    if nl := strings.index_byte(full, '\n'); nl >= 0 {
        full = full[:nl]
    }
    msg = strings.clone(full) // sb será destruído; devolvemos cópia
    // `name` é emprestado da memória da VM (props["name"]/constructor.name) — o
    // caller tem `defer vm_free`, que libera a VM ANTES de imprimir. Sem clonar,
    // err_name vira ponteiro pendente e o printf faz memcpy de memória liberada
    // (crash intermitente, dependente de layout de heap). Clona p/ ownership próprio.
    name = strings.clone(name)
    return
}

// Ponto de entrada do modo CLI `--js262 arquivo1.js arquivo2.js ...`.
// Lê cada arquivo, executa em ordem e imprime a linha de veredito. Devolve o
// exit code do processo (0 = executou; 2 = erro de I/O ao ler algum arquivo).
js262_main :: proc(paths: []string) -> int {
    sources := make([dynamic]string)
    defer {
        for s in sources do delete(s)
        delete(sources)
    }
    for p in paths {
        data, rerr := os.read_entire_file_from_path(p, context.allocator)
        if rerr != nil {
            fmt.eprintfln("[js262] não consegui ler %s", p)
            return 2
        }
        append(&sources, string(data))
    }

    res := run_js262(sources[:])
    if res.threw {
        fmt.printfln("__262__ status=throw name=%s phase=%s source=%d rec=%d msg=%s",
            res.err_name, res.phase, res.source, res.recoveries, res.err_msg)
        delete(res.err_name)
        delete(res.err_msg)
    } else {
        fmt.printfln("__262__ status=pass rec=%d", res.recoveries)
    }
    return 0
}
