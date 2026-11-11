package ui

import "base:runtime"
import "core:testing"

// O buffer de comandos de pintura NÃO pode perder comando em página grande.
//
// Defeito (medido 11/11): o buffer vivia no temp_allocator. `Paint_Cmd` tem
// alinhamento 32; passando de 4 MB, a arena do runtime cria um bloco de tamanho
// EXATO cujo início útil fica 16 B desalinhado (cabeçalho de 48 B), e o append
// falha com Out_Of_Memory — o comando some em silêncio e a parte de baixo da
// página não é pintada.
//
// O teste monta a MESMA arena que o runtime usa como temp_allocator (bloco
// mínimo de 4 MB): no runner de testes o temp_allocator é outro, e com ele o
// defeito não aparece — o teste passaria com o bug vivo.

@(private = "file")
com_arena_do_runtime :: proc(t: ^testing.T, n: int) -> (got: int) {
    arena: runtime.Default_Temp_Allocator
    runtime.default_temp_allocator_init(&arena, runtime.DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE, context.allocator)
    defer runtime.default_temp_allocator_destroy(&arena)
    saved := context.temp_allocator
    context.temp_allocator = runtime.default_temp_allocator(&arena)
    defer context.temp_allocator = saved

    pt := painter_begin()
    for _ in 0 ..< n do emit(&pt, PC_PopClip{})
    got = len(pt.cmds)
    painter_end(&pt)
    return
}

@(test)
paint_cmds_nao_perde_comando_acima_de_4mb :: proc(t: ^testing.T) {
    defer painter_cache_free()
    // 20.000 × 768 B ≈ 15 MB: bem acima do bloco de 4 MB da arena
    N :: 20_000
    testing.expect_value(t, com_arena_do_runtime(t, N), N)
}

@(test)
paint_cmds_controle_pagina_pequena :: proc(t: ^testing.T) {
    defer painter_cache_free()
    // controle: abaixo de 4 MB nunca falhou, nem no código antigo
    N :: 1_000
    testing.expect_value(t, com_arena_do_runtime(t, N), N)
}

@(test)
paint_cmds_buffer_e_reaproveitado_entre_frames :: proc(t: ^testing.T) {
    defer painter_cache_free()
    // 2º frame começa VAZIO (sem comando do anterior) e com a capacidade guardada
    com_arena_do_runtime(t, 10_000)
    pt := painter_begin()
    testing.expect_value(t, len(pt.cmds), 0)
    testing.expectf(t, cap(pt.cmds) >= 10_000, "capacidade não foi guardada: %d", cap(pt.cmds))
    painter_end(&pt)
}
