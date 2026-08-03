package js

import "core:strings"
import "core:testing"
import dom "../dom"

// document.write / writeln.
//
// ⚠️ Estes testes NÃO podem usar `run_with_dom`: o que decide o comportamento é
// `vm.current_script` (o ponto de inserção), e o helper não o define. Montamos o
// vm à mão e setamos o script em execução, que é o que `load_page_scripts` faz
// na página real.
//
// O que está sob teste é POSIÇÃO e ORDEM, não "não lançou": um `write` que
// insere no lugar errado é tão inútil quanto um que não existe.

@(private = "file")
dom_com_script :: proc() -> (root: ^dom.Node, script: ^dom.Node) {
    root = dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    antes := dom.make_node(.Element); antes.tag = strings.clone("i"); antes.attrs = make(map[string]string)
    script = dom.make_node(.Element); script.tag = strings.clone("script"); script.attrs = make(map[string]string)
    depois := dom.make_node(.Element); depois.tag = strings.clone("b"); depois.attrs = make(map[string]string)
    dom.append_child(root, html)
    dom.append_child(html, body)
    dom.append_child(body, antes)   // <i>  — tem de continuar ANTES do escrito
    dom.append_child(body, script)
    dom.append_child(body, depois)  // <b>  — tem de continuar DEPOIS do escrito
    return
}

// Tags dos filhos do <body>, em ordem — é a afirmação de POSIÇÃO.
@(private = "file")
tags_do_body :: proc(root: ^dom.Node, allocator := context.allocator) -> string {
    body := dom.find_first(root, "body")
    sb: strings.Builder; strings.builder_init(&sb, allocator)
    for c in body.children {
        if c.kind != .Element do continue
        if strings.builder_len(sb) > 0 do strings.write_byte(&sb, ',')
        strings.write_string(&sb, c.tag)
    }
    return strings.to_string(sb)
}

@(private = "file")
vm_no_script :: proc(root, script: ^dom.Node) -> ^Interp {
    vm := vm_create_with_dom(root)
    vm.current_script = rawptr(script) // é o que load_page_scripts faz por script
    return vm
}

@(test)
doc_write_insere_no_lugar_do_script :: proc(t: ^testing.T) {
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    vm_run(vm, `document.write('<p>oi</p>')`)
    got := tags_do_body(root, context.temp_allocator)
    testing.expectf(t, got == "i,script,p,b",
        "o escrito entra DEPOIS do <script> e antes do resto; veio %q", got)
}

@(test)
doc_write_repetido_mantem_a_ordem :: proc(t: ^testing.T) {
    // ⚠️ o caso que a âncora existe para resolver: sem ela, as duas chamadas
    // inseririam logo após o <script> e sairiam INVERTIDAS (p2,p1).
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    vm_run(vm, `document.write('<p></p>'); document.write('<u></u>');`)
    got := tags_do_body(root, context.temp_allocator)
    testing.expectf(t, got == "i,script,p,u,b",
        "duas chamadas saem na ORDEM em que foram feitas; veio %q", got)
}

@(test)
doc_write_varios_nos_e_argumentos :: proc(t: ^testing.T) {
    // write concatena TODOS os argumentos, e um fragmento pode trazer N nós.
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    vm_run(vm, `document.write('<p></p>', '<u></u>')`)
    got := tags_do_body(root, context.temp_allocator)
    testing.expectf(t, got == "i,script,p,u,b",
        "argumentos são concatenados e todos os nós entram em ordem; veio %q", got)
}

@(test)
doc_write_de_script_inline_EXECUTA :: proc(t: ^testing.T) {
    // ⚠️ ESTE é o caso que dá valor à feature: <script> escrito EXECUTA
    // (ao contrário do innerHTML). É a forma do `write('<script src=jquery>')`.
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    r := vm_run(vm, `
        window.marca = 'nao rodou';
        document.write('<scr' + 'ipt>window.marca = "rodou"</scr' + 'ipt>');
        window.marca
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "rodou", "script escrito por document.write executa; veio %q", s)
}

@(test)
doc_writeln_tambem_escreve :: proc(t: ^testing.T) {
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    vm_run(vm, `document.writeln('<p></p>')`)
    got := tags_do_body(root, context.temp_allocator)
    testing.expectf(t, got == "i,script,p,b", "writeln insere igual ao write; veio %q", got)
}

@(test)
doc_write_fora_de_script_e_ignorado_sem_lancar :: proc(t: ^testing.T) {
    // Degradação DELIBERADA: a spec apagaria o documento; nós ignoramos. O que
    // este caso trava é que a página fica INTACTA e nada lança.
    root, script := dom_com_script(); defer dom.free_tree(root)
    _ = script
    vm := vm_create_with_dom(root); defer vm_free(vm) // current_script == nil
    r := vm_run(vm, `
        var e = 'sem erro';
        try { document.write('<p></p>'); } catch (x) { e = 'lancou: ' + x; }
        e + '|' + document.body.children.length
    `)
    s, _ := r.(string)
    testing.expectf(t, s == "sem erro|3",
        "sem ponto de inserção: não lança e NÃO mexe no documento; veio %q", s)
}

@(test)
doc_open_close_sao_noop_que_nao_lancam :: proc(t: ^testing.T) {
    // O idioma legado é open(); write(...); close(). Sem os dois stubs, o
    // conserto do write não serviria de nada nessas páginas.
    root, script := dom_com_script(); defer dom.free_tree(root)
    vm := vm_no_script(root, script); defer vm_free(vm)
    vm_run(vm, `document.open(); document.write('<p></p>'); document.close();`)
    got := tags_do_body(root, context.temp_allocator)
    testing.expectf(t, got == "i,script,p,b",
        "open/close não lançam e open NÃO apaga o documento; veio %q", got)
}
