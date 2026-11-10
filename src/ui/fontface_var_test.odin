package ui

import "core:testing"
import "core:time"
import "core:sync"
import "core:mem"
import im "../../vendor/imgui"

// Download compartilhado e instâncias de fonte VARIÁVEL (animate.style: as
// `@font-face` de 400 e 700 da Work Sans apontam para a MESMA URL).
// Nenhum destes testes dispara thread: toda face criada aqui tem uma irmã com a
// mesma URL, então `fontface_start` espera ou empresta em vez de baixar.

@(private = "file")
with_faces :: proc() -> (saved_faces: [dynamic]Loaded_Face, saved_fams: [dynamic]string) {
    saved_faces, saved_fams = g_faces, g_face_families
    g_faces = make([dynamic]Loaded_Face)
    g_face_families = make([dynamic]string)
    append(&g_face_families, "work sans")
    return
}

@(private = "file")
restore :: proc(saved_faces: [dynamic]Loaded_Face, saved_fams: [dynamic]string) {
    delete(g_faces)
    delete(g_face_families)
    g_faces, g_face_families = saved_faces, saved_fams
}

@(test)
test_var_mesma_url_espera_o_download_da_irma :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    raw := make([]byte, 16)
    defer delete(raw)
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Loading})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Loading})
    fontface_start(1)
    testing.expect_value(t, g_faces[1].waiting_on, 1) // espera a 0, não baixa
    // a irmã ainda baixando: segue esperando
    fontface_resolve_waiters(time.tick_now())
    testing.expect_value(t, g_faces[1].state, Face_State.Loading)
    // o download da 0 chega: a 1 EMPRESTA os mesmos bytes
    g_faces[0].raw = raw
    g_faces[0].is_var = true
    g_faces[0].state = .Ready
    fontface_resolve_waiters(time.tick_now())
    f := g_faces[1]
    testing.expect_value(t, f.state, Face_State.Ready)
    testing.expect(t, raw_data(f.raw) == raw_data(raw) && f.raw_borrowed, "empresta, não copia")
    testing.expect(t, f.is_var, "herda o diagnóstico de fonte variável")
    testing.expect(t, bool(sync.atomic_load(&g_faces[1].done)), "o poll precisa instanciá-la")
    testing.expect_value(t, f.waiting_on, 0)
}

@(test)
test_var_irma_ja_pronta_empresta_na_hora :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    raw := make([]byte, 16)
    defer delete(raw)
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Ready, raw = raw})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Loading})
    fontface_start(1)
    testing.expect_value(t, g_faces[1].state, Face_State.Ready)
    testing.expect(t, raw_data(g_faces[1].raw) == raw_data(raw), "mesmos bytes")
}

@(test)
test_var_falha_do_download_compartilhado_propaga :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Loading})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Loading})
    fontface_start(1)
    g_faces[0].state = .Failed
    g_faces[0].failure = .Network
    g_faces[0].retryable = true
    fontface_resolve_waiters(time.tick_now())
    f := g_faces[1]
    testing.expect_value(t, f.state, Face_State.Failed)
    testing.expect_value(t, f.failure, Face_Failure.Network)
    testing.expect(t, f.retryable, "rede é transitória: a dependente também re-tenta")
}

// O `raw` emprestado não pode ser liberado por quem o pegou emprestado, nem pela
// dona enquanto alguém o usa (o atlas guarda PONTEIRO). O rastreador de memória
// do test runner acusa o free duplo.
@(test)
test_var_liberar_nao_derruba_bytes_emprestados :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    // ⚠️ rastreador PRÓPRIO: o do test runner só IMPRIME "bad free" e deixa o
    // teste passar (medido: a sabotagem da guarda passava verde).
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    defer testing.expectf(t, len(track.bad_free_array) == 0, "%d free(s) de bytes emprestados", len(track.bad_free_array))

    raw := make([]byte, 16)
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Failed, raw = raw})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Failed, raw = raw, raw_borrowed = true})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 900, url = "U", state = .Failed, raw = raw, raw_borrowed = true})
    // 1) a DONA é reciclada com emprestadas vivas: não pode liberar
    face_release_bytes(0)
    testing.expect(t, g_faces[0].raw == nil && raw_data(g_faces[1].raw) == raw_data(raw))
    // 2) emprestada solta: nunca libera
    face_release_bytes(1)
    face_release_bytes(2)
    // 3) o buffer seguiu vivo o tempo todo — se algum passo acima o tivesse
    //    liberado, este delete seria o 2º free e o rastreador acusaria.
    delete(raw)
}

// Dona sem ninguém emprestando: libera de verdade (o rastreador acusaria o vazamento).
@(test)
test_var_liberar_dona_sozinha_libera :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Failed, raw = make([]byte, 16)})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Failed})
    face_release_bytes(0)
    testing.expect(t, g_faces[0].raw == nil)
}

// Peso pedido DENTRO da faixa de uma face variável: serve a mãe agora e cria
// a instância exata, que ganha assim que entra no atlas.
@(test)
test_var_faixa_deriva_a_instancia_do_peso_pedido :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    raw := make([]byte, 16)
    defer delete(raw)
    fonts := [2]im.Font{}
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, wmin = 100, wmax = 900, url = "U",
        state = .Ready, raw = raw, is_var = true})
    g_faces[0].fonts[0] = &fonts[0]
    defer for &f in g_faces do if f.derived do delete(f.url)

    got, _ := fontface_pick(1, 700, false, 0)
    testing.expect(t, got == &fonts[0], "enquanto não há a instância de 700, a mãe serve")
    testing.expect_value(t, len(g_faces), 2)
    if len(g_faces) < 2 do return
    d := g_faces[1]
    testing.expect(t, d.derived && d.weight == 700 && d.state == .Ready, "derivada no peso pedido")
    testing.expect(t, raw_data(d.raw) == raw_data(raw) && d.raw_borrowed, "sem download: empresta da mãe")
    // segunda consulta não deriva de novo
    fontface_pick(1, 700, false, 0)
    testing.expect_value(t, len(g_faces), 2)
    // quando a derivada entra no atlas, ela ganha
    g_faces[1].fonts[0] = &fonts[1]
    got2, _ := fontface_pick(1, 700, false, 0)
    testing.expect(t, got2 == &fonts[1], "a instância exata ganha da mãe")
    // o peso da própria mãe não deriva nada
    got3, _ := fontface_pick(1, 400, false, 0)
    testing.expect(t, got3 == &fonts[0])
    testing.expect_value(t, len(g_faces), 2)
}

// Os casos em que NÃO se deriva: fonte que não é variável (instanciar não muda
// nada e gastaria atlas) e pesos únicos estilo Google Fonts (400 e 700 já são
// faces próprias; um pedido de 600 casa com a de 700, como no CSS).
@(test)
test_var_sem_faixa_ou_sem_eixo_nao_deriva :: proc(t: ^testing.T) {
    sf, sn := with_faces()
    defer restore(sf, sn)
    raw := make([]byte, 16)
    defer delete(raw)
    fonts := [3]im.Font{}
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, url = "U", state = .Ready, raw = raw, is_var = true})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 700, url = "U", state = .Ready, raw = raw, raw_borrowed = true, is_var = true})
    append(&g_faces, Loaded_Face{fam_id = 1, weight = 400, wmin = 100, wmax = 900, italic = true, url = "S",
        state = .Ready, raw = raw, raw_borrowed = true, is_var = false})
    for &f, i in g_faces do f.fonts[0] = &fonts[i]
    b, _ := fontface_pick(1, 700, false, 0)
    testing.expect(t, b == &fonts[1], "700 casa com a face de 700")
    s, _ := fontface_pick(1, 600, false, 0)
    testing.expect(t, s == &fonts[1], "600 casa com a mais próxima")
    it, _ := fontface_pick(1, 700, true, 0)
    testing.expect(t, it == &fonts[2], "itálico de faixa casa pela faixa")
    testing.expect_value(t, len(g_faces), 3) // nada derivado
}
