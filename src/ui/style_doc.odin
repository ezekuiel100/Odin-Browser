package ui

import dompkg "../dom"

// ── Estado de estilo POR DOCUMENTO ──────────────────────────────────────────
//
// O que a resolução de estilo e o layout de UM documento precisam lembrar entre
// si e entre passadas. Antes eram seis globais de pacote, com três regimes
// diferentes de posse:
//
//   g_root_font_size, g_viewport_w/h   thread_local — certo para o runner de
//                                      teste, mas "o documento" era a THREAD;
//   g_container_w/used/dirty           globais COMUNS — compartilhados por todas
//                                      as abas e pelo fetch_worker, que monta o
//                                      layout NUMA THREAD própria: dois escritores
//                                      num `map` sem trava. E o app nunca os
//                                      limpava: chaveados por ^Node, cresciam a
//                                      cada navegação, e um nó novo que reusasse
//                                      o endereço de um nó liberado herdava a
//                                      largura de contêiner da página ANTERIOR.
//
// Agora cada documento tem o seu Style_Doc (a aba e o job de fetch guardam um
// PONTEIRO — a Tab é copiada por valor, e um map dentro dela duplicaria o
// cabeçalho entre as cópias). Quem resolve estilo/layout de um documento o
// VINCULA (`style_doc_bind`) na thread corrente; o vínculo é thread_local, então
// o worker e a thread principal nunca se enxergam.
//
// Sem vínculo (testes, ferramentas de linha de comando) cai num documento
// IMPLÍCITO por thread — exatamente o regime antigo dos thread_local, que é o
// que os testes já assumem.
Style_Doc :: struct {
    root_font_size: f32, // font-size computado do <html> (base do `rem`); 0 = ainda não
    viewport_w:     f32, // viewport do último compute_styles; 0 = fallback no LEITOR
    viewport_h:     f32,
    // Container queries (ver container_matches em style.odin)
    container_w:     map[^dompkg.Node]f32, // nó do contêiner → largura de conteúdo medida
    container_used:  map[^dompkg.Node]f32, // o que a última resolução de estilo usou
    container_dirty: bool,                 // medida != usada → precisa reestilizar
}

@(private="file", thread_local) g_style_doc:          ^Style_Doc
@(private="file", thread_local) g_style_doc_implicit: Style_Doc

// Documento cujo estilo/layout está sendo resolvido nesta thread.
style_doc :: proc() -> ^Style_Doc {
    return g_style_doc != nil ? g_style_doc : &g_style_doc_implicit
}

// Vincula `d` à thread corrente e devolve o vínculo anterior (p/ restaurar:
// `prev := style_doc_bind(d); defer style_doc_bind(prev)`). nil = implícito.
style_doc_bind :: proc(d: ^Style_Doc) -> (prev: ^Style_Doc) {
    prev = g_style_doc
    g_style_doc = d
    return
}

style_doc_new :: proc() -> ^Style_Doc { return new(Style_Doc) }

style_doc_free :: proc(d: ^Style_Doc) {
    if d == nil do return
    if g_style_doc == d do g_style_doc = nil // não deixar vínculo pendurado
    delete(d.container_w)
    delete(d.container_used)
    free(d)
}

// Esquece as medidas de contêiner (nova passada de render do zero).
container_w_clear :: proc() {
    d := style_doc()
    clear(&d.container_w); clear(&d.container_used); d.container_dirty = false
}
