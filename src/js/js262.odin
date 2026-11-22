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
// phase=parse: o fonte foi rejeitado pelo parser (SyntaxError antes de executar);
// phase=runtime: lançou durante a execução. source distingue harness de teste.
// --module aplica goal Module somente ao ultimo fonte; --async instala $DONE.
// status=incomplete/invalid nunca aprovam um teste no runner externo.

import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"

// Resultado bruto de rodar uma sequência de fontes numa VM.
Js262_Result :: struct {
    phase:      string,
    source:     int,
    threw:      bool,
    err_name:   string, // "TypeError" / "Test262Error" / "SyntaxError" / ...
    err_msg:    string, // primeira linha da mensagem
    recoveries: int,    // parse_recoveries acumuladas
    incomplete: bool,  // async sem $DONE ou modulo que nao terminou
    protocol_error: bool, // mais de uma chamada a $DONE
    uncaught_jobs: int, // callbacks do host que o motor reportou e limpou
}

// Executa cada fonte em ordem no MESMO vm (escopo global compartilhado). Para na
// primeira exceção não capturada. NÃO limpa a exceção entre fontes — o corpo do
// teste vê os helpers do harness definidos pelas fontes anteriores.
run_js262 :: proc(sources: []string, module_path := "", is_async := false, entry_path := "") -> Js262_Result {
    vm := vm_create()
    defer vm_free(vm)
    // The runner owns the deadline and kills the process on timeout. Browser
    // watchdog RangeErrors must not accidentally satisfy negative tests.
    vm.time_budget_ms = 0
    vm.step_limit = 0xffff_ffff_ffff_ffff
    host := new_object(vm)
    host.props["detachArrayBuffer"] = mk_native(vm, js262_detach_buffer)
    host.props["evalScript"] = mk_native(vm, js262_eval_script)
    host.props["#done"] = f64(0)
    global := new_object(vm)
    global.get = js262_global_get
    global.set = js262_global_set
    for name, value in vm.global.vars do oput(global, name, value)
    vm.global_this = global
    env_define(vm.global, "globalThis", global)
    oput(global, "globalThis", global)
    host.props["global"] = global
    env_define(vm.global, "$262", host)
    oput(global, "$262", host)
    if is_async {
        done := mk_native(vm, js262_done)
        done.bound = host
        env_define(vm.global, "$DONE", done)
        oput(global, "$DONE", done)
    }
    env_define(vm.global, "print", vm.console_log_fn)
    vm.module_resolve = js262_module_resolve
    vm.module_fetch = js262_module_fetch
    vm.base_url = strings.clone(entry_path)

    failed_source := -1
    phase := "runtime"
    entry: ^Module
    for src, i in sources {
        before := vm.syntax_errors
        before_scripts := len(vm.all_scripts)
        if module_path != "" && i == len(sources)-1 {
            // Do not use vm_run_module: it clears uncaught exceptions.
            entry = new(Module)
            entry.url = strings.clone(module_path)
            entry.ns = new_object(vm)
            entry.env = new_env(vm, vm.global)
            entry.env.is_fn_scope = true
            entry.state = .Loading
            module_bind_ns_live(entry)
            append(&vm.all_modules, entry)
            vm.modules[entry.url] = entry
            vm.current_module = entry
            _ = vm_exec(vm, src, entry.env)
            vm.current_module = nil
        } else {
            _ = vm_exec(vm, src)
        }
        if !vm.throwing {
            promise_checkpoint(vm)
            if is_async && truthy(host.props["#error"]) {
                vm.throwing = true
                vm.thrown = host.props["#error"]
            }
        }
        if vm.throwing {
            failed_source = i
            // o fonte foi REJEITADO antes de executar (early error de verdade):
            // é a fase `parse` do frontmatter `negative:`
            // A dependency parsed after the root began execution is not a
            // parse error of the test itself. Never approve a parse-negative
            // merely because an imported fixture has a syntax error.
            if vm.syntax_errors > before && len(vm.all_scripts) == before_scripts do phase = "parse"
            break
        }
    }

    if !vm.throwing {
        // Test262 async jobs do not require browser timers. A checkpoint drains
        // the FIFO including async continuations; absence of $DONE never passes.
        promise_checkpoint(vm)
        if entry != nil && entry.state == .Failed {
            vm.throwing = true
            vm.thrown = entry.error
        }
        if is_async && truthy(host.props["#error"]) {
            vm.throwing = true
            vm.thrown = host.props["#error"]
        }
        if vm.throwing do failed_source = len(sources)-1
    }

    // `rec` segue medindo recuperação SILENCIOSA (que não deve mais existir); um
    // SyntaxError de verdade sai como phase=parse, nunca como recuperação.
    res := Js262_Result{ recoveries = vm.parse_recoveries, phase = phase, source = failed_source }
    done_count, _ := host.props["#done"].(f64)
    res.protocol_error = is_async && done_count > 1
    res.uncaught_jobs = vm.uncaught_total
    res.incomplete = !vm.throwing && ((is_async && done_count == 0) || (entry != nil && entry.state == .Loading))
    if vm.throwing {
        res.threw = true
        res.err_name, res.err_msg = describe_thrown(vm)
        vm.throwing = false // limpo p/ o vm_free rodar sem exceção pendente
        vm.thrown   = nil
    }
    return res
}

@(private = "file")
js262_done :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    host, ok := vm.native_bound.(^Object)
    if !ok do return nil
    count, _ := host.props["#done"].(f64)
    host.props["#done"] = count + 1
    if truthy(arg(args, 0)) && !truthy(host.props["#error"]) do host.props["#error"] = arg(args, 0)
    return nil
}

@(private = "file")
js262_global_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    return env_get(vm.global, name, vm)
}

@(private = "file")
js262_global_set :: proc(vm: ^Interp, o: ^Object, name: string, value: Value) -> bool {
    env_define(vm.global, name, value)
    oput(o, name, value)
    return true
}

@(private = "file")
js262_eval_script :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    src, ok := arg(args, 0).(string)
    if !ok { throw_type_error(vm, "$262.evalScript expects source text"); return nil }
    return vm_eval_source_global(vm, src)
}

@(private = "file")
js262_module_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    if !strings.has_prefix(specifier, "./") && !strings.has_prefix(specifier, "../") do return ""
    resolved, _ := filepath.join({filepath.dir(referrer), specifier})
    return resolved
}

@(private = "file")
js262_module_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    data, err := os.read_entire_file_from_path(url, context.allocator)
    return string(data), err == nil
}

// Test262 host operation: invalidate all views sharing the backing store.
js262_detach_buffer :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok || o.ab == nil || o.ta_kind != .None {
        throw_type_error(vm, "Expected an ArrayBuffer")
        return nil
    }
    o.ab.detached = true
    o.props["byteLength"] = f64(0)
    return nil
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
    is_async, is_module := false, false
    entry_path := ""
    for p in paths {
        if p == "--async" { is_async = true; continue }
        if p == "--module" { is_module = true; continue }
        data, rerr := os.read_entire_file_from_path(p, context.allocator)
        if rerr != nil {
            fmt.eprintfln("[js262] não consegui ler %s", p)
            return 2
        }
        append(&sources, string(data))
        entry_path = p
    }

    res := run_js262(sources[:], is_module ? entry_path : "", is_async, entry_path)
    if res.protocol_error || res.uncaught_jobs > 0 {
        reason := res.protocol_error ? "multiple-done" : "uncaught-job"
        fmt.printfln("__262__ status=invalid reason=%s rec=0", reason)
        if res.threw { delete(res.err_name); delete(res.err_msg) }
    } else if res.incomplete {
        fmt.println("__262__ status=incomplete reason=async-or-module-pending rec=0")
    } else if res.threw {
        fmt.printfln("__262__ status=throw name=%s phase=%s source=%d rec=%d msg=%s",
            res.err_name, res.phase, res.source, res.recoveries, res.err_msg)
        delete(res.err_name)
        delete(res.err_msg)
    } else {
        fmt.printfln("__262__ status=pass rec=%d", res.recoveries)
    }
    return 0
}

// Modo CLI `--jsparse [m:|s:]arquivo ...` — SÓ PARSEIA (não executa) e imprime uma
// linha por arquivo: `OK <arq>` ou `ERR <arq> <linha>:<col> <mensagem>`. Prefixo
// `m:` = goal Module; `s:` = código strict (prefixa "use strict";). Serve para medir
// o parser em lote: falso positivo em bundle real (deve ser 0) e acerto nos
// negativos de sintaxe do Test262 — sem o custo nem o risco de executar.
js_parse_main :: proc(paths: []string) -> int {
    n_ok, n_err := 0, 0
    for arg in paths {
        path := arg
        is_module, strict := false, false
        if strings.has_prefix(path, "m:") { is_module = true; path = path[2:] }
        if strings.has_prefix(path, "s:") { strict = true; path = path[2:] }
        data, rerr := os.read_entire_file_from_path(path, context.allocator)
        if rerr != nil {
            fmt.printfln("IOERR %s", path)
            continue
        }
        src := string(data)
        if strict {
            src = strings.concatenate({"\"use strict\";\n", src})
            delete(data)
        }
        toks, owned, _, lerr := tokenize(src, is_module)
        p := Parser{toks = toks[:], src = src, is_module = is_module}
        prog := parse_program(&p)
        if msg, off, bad := pick_syntax_error(&p, lerr); bad {
            line, col := src_line_col(src, off)
            fmt.printfln("ERR %s %d:%d %s", path, line, col, msg)
            n_err += 1
        } else {
            fmt.printfln("OK %s", path)
            n_ok += 1
        }
        delete(p.err_msg)
        free_ast(prog)
        for s in p.owned_strings do delete(s)
        delete(p.owned_strings)
        for s in owned do delete(s)
        delete(owned)
        delete(toks)
        delete(src)
        free_all(context.temp_allocator)
    }
    fmt.printfln("__jsparse__ ok=%d err=%d", n_ok, n_err)
    return 0
}
