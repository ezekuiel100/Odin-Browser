package js

import "base:runtime"
import "core:fmt"
import "core:strings"

// ── Error.stack com frames (pilha-sombra de chamadas) ───────────────────────────
// Antes `stack` era só "Name: msg" — sem um frame. Biblioteca que PARSEIA a pilha
// (error-stack-parser, loggers, detecção do script corrente por `new Error().stack`,
// o `captureStackTrace` de toda classe de erro "à Node") recebia uma linha só.
//
// Como funciona, com custo ~zero no caminho quente:
//   • cada ^Node de chamada/`new`/statement guarda `pos` (offset+1 no fonte; mora no
//     padding do Node — a AST não cresce). O `eval` copia p/ `vm.cur_pos`.
//   • cada fonte executado (script, módulo, eval/Function) vira um Script_Src; toda
//     ^Function criada durante ele aponta p/ ele (`fn.script`, em new_function).
//   • call_function (função de usuário) empilha um Stack_Frame LOCAL (na pilha
//     nativa) encadeado por `parent` em `vm.frame`: guarda a função e ONDE, no
//     código do chamador, a chamada aconteceu. A saída restaura tudo por `defer`.
//   • generator/async: o corpo roda numa thread própria e fica suspenso entre
//     retomadas — gen_resume troca `vm.frame/cur_pos/cur_script` (ver lá).
//
// Formato: o do V8 ("    at nome (url:linha:coluna)"), que é o que os parsers de
// pilha esperam. Desvios conscientes: sem frames de NATIVAS ("at Array.map
// (<anonymous>)"), sem o prefixo de tipo do receptor ("Foo.bar"), sem "async ";
// linha de script INLINE conta do início do <script>, não do documento HTML; e
// erro do próprio motor (null.x) aponta o início do STATEMENT, não a expressão.

STACK_TRACE_LIMIT_DEFAULT :: 10

Script_Allocator :: runtime.Allocator // tipo do vm.script_alloc (interp.odin não importa runtime)

Script_Src :: struct {
    url:   string,       // owned. "" = eval/Function() → "<anonymous>"
    src:   string,       // fatia de vm.owned_sources (NÃO owned aqui)
    lines: [dynamic]int, // offset do início de cada linha; montada na 1ª consulta
}

Stack_Frame :: struct {
    parent:      ^Stack_Frame,
    fn:          ^Function,
    call_pos:    u32,         // pos (offset+1) da chamada, no código do CHAMADOR; 0 = ?
    call_script: ^Script_Src, // fonte do chamador; nil = chamado pelo HOST (timer, evento)
    is_new:      bool,
}

// Registra um fonte prestes a executar. `src` precisa viver tanto quanto o vm.
// Aloca no alocador do HEAP explicitamente: a tabela de linhas é montada sob
// demanda, possivelmente sob o alocador TEMP (ver crash-global-map-temp-alloc).
script_register :: proc(vm: ^Interp, url, src: string) -> ^Script_Src {
    if vm.script_alloc.procedure == nil do vm.script_alloc = context.allocator
    s := new(Script_Src, vm.script_alloc)
    s.url = url == "" ? "" : strings.clone(url, vm.script_alloc)
    s.src = src
    s.lines = make([dynamic]int, vm.script_alloc)
    append(&vm.all_scripts, s)
    return s
}

scripts_free :: proc(vm: ^Interp) {
    for s in vm.all_scripts {
        if s.url != "" do delete(s.url, vm.script_alloc)
        delete(s.lines)
        free(s, vm.script_alloc)
    }
    delete(vm.all_scripts)
}

// pos (offset+1) → linha e coluna 1-based. Coluna em CODE UNITS UTF-16, como o V8.
script_line_col :: proc(s: ^Script_Src, pos: u32) -> (line, col: int) {
    src := s.src
    if len(s.lines) == 0 {
        append(&s.lines, 0)
        for i := 0; i < len(src); i += 1 {
            c := src[i]
            if c == '\n' {
                append(&s.lines, i + 1)
            } else if c == '\r' {
                if i + 1 < len(src) && src[i + 1] == '\n' do i += 1
                append(&s.lines, i + 1)
            } else if c == 0xE2 && i + 2 < len(src) && src[i + 1] == 0x80 && (src[i + 2] == 0xA8 || src[i + 2] == 0xA9) {
                i += 2 // U+2028/U+2029 também terminam linha em JS
                append(&s.lines, i + 1)
            }
        }
    }
    off := clamp(int(pos) - 1, 0, len(src))
    lo, hi := 0, len(s.lines) - 1 // maior k com lines[k] <= off
    for lo < hi {
        mid := (lo + hi + 1) / 2
        if s.lines[mid] <= off do lo = mid
        else do hi = mid - 1
    }
    col = 1
    for i := s.lines[lo]; i < off; i += 1 {
        b := src[i]
        if b & 0xC0 == 0x80 do continue // byte de continuação
        col += 2 if b >= 0xF0 else 1    // fora do BMP = par substituto
    }
    return lo + 1, col
}

@(private = "file")
write_location :: proc(sb: ^strings.Builder, s: ^Script_Src, pos: u32) {
    if s == nil || s.url == "" {
        strings.write_string(sb, "<anonymous>")
    } else {
        strings.write_string(sb, s.url)
    }
    if s != nil && pos != 0 {
        line, col := script_line_col(s, pos)
        fmt.sbprintf(sb, ":%d:%d", line, col)
    }
}

@(private = "file")
write_frame :: proc(sb: ^strings.Builder, fn: ^Function, is_new: bool, s: ^Script_Src, pos: u32) {
    strings.write_string(sb, "\n    at ")
    name := fn != nil ? fn.name : ""
    if is_new {
        strings.write_string(sb, "new ")
        strings.write_string(sb, name if name != "" else "<anonymous>")
    } else if name == "" {
        write_location(sb, s, pos) // anônima: V8 escreve só o local, sem parênteses
        return
    } else {
        strings.write_string(sb, name)
    }
    strings.write_string(sb, " (")
    write_location(sb, s, pos)
    strings.write_string(sb, ")")
}

// Error.stackTraceLimit corrente. ok=false: não é número → o V8 NÃO grava `stack`.
@(private = "file")
stack_trace_limit :: proc(vm: ^Interp) -> (limit: int, ok: bool) {
    ec := vm.error_ctor
    if ec == nil || ec.props == nil do return STACK_TRACE_LIMIT_DEFAULT, true
    v, has := ec.props["stackTraceLimit"]
    if !has do return 0, false
    n, isnum := v.(f64)
    if !isnum do return 0, false
    if n != n || n <= 0 do return 0, true
    if n >= 1e6 do return 1_000_000, true
    return int(n), true
}

// Monta o `stack` do ponto de execução ATUAL: `header` + até stackTraceLimit frames.
// `skip_fn` (2º arg de Error.captureStackTrace): omite o frame mais recente dessa
// função e tudo acima dele; se ela não está na pilha, nenhum frame (como o V8).
stack_capture :: proc(vm: ^Interp, header: string, skip_fn: ^Function = nil) -> (Value, bool) {
    limit, ok := stack_trace_limit(vm)
    if !ok do return nil, false
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, header)

    pos, script := vm.cur_pos, vm.cur_script
    f := vm.frame
    if skip_fn != nil {
        found := false
        for g := vm.frame; g != nil; g = g.parent {
            if g.fn == skip_fn {
                pos, script = g.call_pos, g.call_script
                f = g.parent
                found = true
                break
            }
        }
        if !found do return own_str(vm, strings.to_string(sb)), true
    }
    n := 0
    for ; f != nil && n < limit; f = f.parent {
        write_frame(&sb, f.fn, f.is_new, script, pos)
        n += 1
        pos, script = f.call_pos, f.call_script
    }
    // fundo da pilha: código de TOPO de um script (o host não conta como frame)
    if f == nil && n < limit && script != nil {
        write_frame(&sb, nil, false, script, pos)
    }
    return own_str(vm, strings.to_string(sb)), true
}

// "Name: msg" (ou "Name" com msg vazia) + frames. Atalho dos construtores de erro.
stack_for_error :: proc(vm: ^Interp, name, msg: string) -> (Value, bool) {
    header := name if msg == "" else fmt.tprintf("%s: %s", name, msg)
    return stack_capture(vm, header)
}
