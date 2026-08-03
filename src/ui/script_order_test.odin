package ui

// Ordem de EXECUÇÃO dos <script>: clássicos primeiro, DEFERIDOS depois.
//
// O defeito que originou: no getbootstrap.com um `<script type="module">` na 3ª
// tag faz `new bootstrap.Tooltip(...)` e o `bootstrap.bundle.min.js` clássico é
// a 5ª. Rodando em ordem de DOCUMENTO, o módulo referenciava um global que
// ainda não existia → `ReferenceError: bootstrap is not defined`. O navegador
// defere módulo e `defer` para depois de todos os clássicos.
//
// ⚠️ Três fixtures minhas PASSARAM antes disto (bundle isolado, ambiente
// CJS/AMD, módulo lendo global nu) — o que achou a causa foi a ORDEM das linhas
// do log, não mais um caso sintético. O teste aqui trava a ordem, que é o que
// importa; o resto era hipótese.

import "core:strings"
import "core:testing"
import dompkg "../dom"

@(private = "file")
mk_script :: proc(id: string, attrs: ..[2]string) -> ^dompkg.Node {
    n := dompkg.make_node(.Element)
    n.tag = strings.clone("script")
    n.attrs = make(map[string]string)
    n.attrs[strings.clone("id")] = strings.clone(id)
    for a in attrs do n.attrs[strings.clone(a[0])] = strings.clone(a[1])
    return n
}

@(private = "file")
ids :: proc(ns: []^dompkg.Node, allocator := context.allocator) -> string {
    sb: strings.Builder; strings.builder_init(&sb, allocator)
    for n, i in ns {
        if i > 0 do strings.write_byte(&sb, ',')
        strings.write_string(&sb, n.attrs["id"])
    }
    return strings.to_string(sb)
}

@(test)
script_order_defere_modulo_e_defer :: proc(t: ^testing.T) {
    // Espelha o getbootstrap.com: módulo ANTES do clássico que ele consome.
    lista := [?]^dompkg.Node{
        mk_script("classico1"),
        mk_script("comDefer", [2]string{"defer", ""}),
        mk_script("modulo1", [2]string{"type", "module"}),
        mk_script("bundle"),
        mk_script("modulo2", [2]string{"type", "module"}),
    }
    defer for n in lista do dompkg.free_tree(n)

    ordem := script_exec_order(lista[:], context.temp_allocator)
    got := ids(ordem, context.temp_allocator)
    testing.expectf(t, got == "classico1,bundle,comDefer,modulo1,modulo2",
        "clássicos primeiro, depois os deferidos — cada grupo em ordem de documento; veio %q", got)
}

@(test)
script_order_async_nao_e_deferido :: proc(t: ^testing.T) {
    // ⚠️ `async` volta a ser "assim que der" — inclusive em módulo. Deferi-lo
    // atrasaria analytics sem ganho, e a spec não ordena async.
    lista := [?]^dompkg.Node{
        mk_script("moduloAsync", [2]string{"type", "module"}, [2]string{"async", ""}),
        mk_script("deferAsync", [2]string{"defer", ""}, [2]string{"async", ""}),
        mk_script("moduloPuro", [2]string{"type", "module"}),
        mk_script("classico"),
    }
    defer for n in lista do dompkg.free_tree(n)

    ordem := script_exec_order(lista[:], context.temp_allocator)
    got := ids(ordem, context.temp_allocator)
    testing.expectf(t, got == "moduloAsync,deferAsync,classico,moduloPuro",
        "async (mesmo em módulo) não é deferido; veio %q", got)
}

@(test)
script_order_sem_deferidos_preserva_documento :: proc(t: ^testing.T) {
    // CONTROLE: página só com clássicos não pode ter a ordem mexida — é o caso
    // da esmagadora maioria, e onde uma regressão passaria despercebida.
    lista := [?]^dompkg.Node{
        mk_script("a"), mk_script("b"), mk_script("c"), mk_script("d"),
    }
    defer for n in lista do dompkg.free_tree(n)

    ordem := script_exec_order(lista[:], context.temp_allocator)
    got := ids(ordem, context.temp_allocator)
    testing.expectf(t, got == "a,b,c,d", "só clássicos: ordem de documento intacta; veio %q", got)
}

@(test)
script_order_so_deferidos_preserva_documento :: proc(t: ^testing.T) {
    // Par do controle acima, pelo outro lado: uma página só de módulos também
    // não pode ter a ordem embaralhada.
    lista := [?]^dompkg.Node{
        mk_script("m1", [2]string{"type", "module"}),
        mk_script("m2", [2]string{"type", "module"}),
        mk_script("m3", [2]string{"type", "module"}),
    }
    defer for n in lista do dompkg.free_tree(n)

    ordem := script_exec_order(lista[:], context.temp_allocator)
    got := ids(ordem, context.temp_allocator)
    testing.expectf(t, got == "m1,m2,m3", "só módulos: ordem de documento intacta; veio %q", got)
}
