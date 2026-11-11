package ui

import "core:testing"
import "core:thread"
import dompkg "../dom"
import csspkg "../css"

// Dois documentos vinculados em sequência não compartilham viewport nem rem.
// Antes eram globais de pacote: o último compute_styles valia para todos.
@(test)
test_style_doc_isola_viewport_e_rem :: proc(t: ^testing.T) {
    a, b := style_doc_new(), style_doc_new()
    defer { style_doc_free(a); style_doc_free(b) }

    run :: proc(d: ^Style_Doc, css: string, vw: f32) {
        prev := style_doc_bind(d)
        defer style_doc_bind(prev)
        rules, _ := csspkg.parse(css)
        defer csspkg.free_rules(&rules)
        html := dompkg.make_node(.Element); html.tag = "html"
        defer dompkg.free_tree(html)
        styles, _ := compute_styles(html, &rules, vw, 600)
        free_styles(styles)
    }
    run(a, "html{font-size:10px}", 500)
    run(b, "html{font-size:20px}", 900)
    testing.expectf(t, a.viewport_w == 500 && a.root_font_size == 10, "doc A contaminado: vw=%v rem=%v", a.viewport_w, a.root_font_size)
    testing.expectf(t, b.viewport_w == 900 && b.root_font_size == 20, "doc B: vw=%v rem=%v", b.viewport_w, b.root_font_size)
}

// O cenário da corrida: o fetch_worker monta o layout NUMA THREAD e grava
// medidas de container query. Com o vínculo thread_local, o que ele grava vai
// para o documento DELE; o documento da thread principal não vê nada.
@(test)
test_style_doc_worker_nao_escreve_no_doc_da_main :: proc(t: ^testing.T) {
    main_doc, job_doc := style_doc_new(), style_doc_new()
    defer { style_doc_free(main_doc); style_doc_free(job_doc) }
    prev := style_doc_bind(main_doc)
    defer style_doc_bind(prev)

    no := dompkg.make_node(.Element)
    defer dompkg.free_tree(no)
    Ctx :: struct { doc: ^Style_Doc, n: ^dompkg.Node }
    ctx := Ctx{job_doc, no}
    th := thread.create_and_start_with_poly_data(&ctx, proc(c: ^Ctx) {
        style_doc_bind(c.doc)
        container_w_record(c.n, 321)
    })
    thread.join(th); thread.destroy(th)

    w, tem := job_doc.container_w[no]
    testing.expectf(t, tem && w == 321, "o worker deveria gravar no doc do job; veio %v %v", tem, w)
    testing.expect(t, job_doc.container_dirty, "medida nova suja o doc do job")
    _, vazou := main_doc.container_w[no]
    testing.expect(t, !vazou && !main_doc.container_dirty, "a medida do worker vazou p/ o doc da thread principal")
    // controle: gravar na thread principal vai p/ o doc vinculado AQUI
    container_w_record(no, 111)
    mw, mtem := main_doc.container_w[no]
    testing.expectf(t, mtem && mw == 111, "controle: a main grava no próprio doc; veio %v %v", mtem, mw)
}

// Liberar o documento vinculado não deixa ponteiro pendurado: o vínculo cai
// para o documento implícito da thread.
@(test)
test_style_doc_free_desvincula :: proc(t: ^testing.T) {
    d := style_doc_new()
    prev := style_doc_bind(d)
    defer style_doc_bind(prev)
    testing.expect(t, style_doc() == d, "pré-condição: vinculado")
    style_doc_free(d)
    testing.expect(t, style_doc() != d, "style_doc() ainda aponta p/ o doc liberado")
}
