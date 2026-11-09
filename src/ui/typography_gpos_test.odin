package ui

import "core:testing"

@(private="file")
gp16 :: proc(b: []byte, p, value: int) {
    b[p] = byte((value >> 8) & 255); b[p+1] = byte(value & 255)
}

@(private="file")
gp_fixture :: proc() -> [100]byte {
    b: [100]byte
    gp16(b[:], 0, 1); gp16(b[:], 6, 10); gp16(b[:], 8, 24)
    gp16(b[:], 10, 1); copy(b[12:16], []byte{'k','e','r','n'})
    gp16(b[:], 16, 8); gp16(b[:], 20, 1)
    gp16(b[:], 24, 1); gp16(b[:], 26, 4)
    gp16(b[:], 28, 9); gp16(b[:], 32, 1); gp16(b[:], 34, 8)
    gp16(b[:], 36, 1); gp16(b[:], 38, 2); gp16(b[:], 42, 8)
    // PairPos 1: glifo 10 seguido de 11, ajuste -80 unidades.
    gp16(b[:], 44, 1); gp16(b[:], 46, 18); gp16(b[:], 48, 4)
    gp16(b[:], 52, 1); gp16(b[:], 54, 12)
    gp16(b[:], 56, 1); gp16(b[:], 58, 11); gp16(b[:], 60, 65536-80)
    gp16(b[:], 62, 1); gp16(b[:], 64, 1); gp16(b[:], 66, 10)
    return b
}

@(test)
test_typography_gpos_extension_pair_and_feature_filter :: proc(t: ^testing.T) {
    b := gp_fixture()
    offsets: [8]int
    n := ot_kern_lookups(b[:], offsets[:])
    testing.expect(t, n == 1)
    v, ok := ot_pair_advance(b[:], offsets[:n], 10, 11)
    testing.expect(t, ok && v == -80)
    _, ok = ot_pair_advance(b[:], offsets[:n], 12, 11)
    testing.expect(t, !ok, "glifo esquerdo fora da coverage")
    _, ok = ot_pair_advance(b[:], offsets[:n], 10, 12)
    testing.expect(t, !ok, "glifo direito fora do pair set")
    copy(b[12:16], []byte{'d','i','s','t'})
    testing.expect(t, ot_kern_lookups(b[:], offsets[:]) == 0, "outra feature não liga kerning")
}

@(test)
test_typography_gpos_pair_classes_and_range_coverage :: proc(t: ^testing.T) {
    b := gp_fixture()
    gp16(b[:], 44, 2); gp16(b[:], 46, 46) // coverage em 90
    gp16(b[:], 52, 30); gp16(b[:], 54, 38) // classdefs em 74 e 82
    gp16(b[:], 56, 2); gp16(b[:], 58, 2)
    for i in 60 ..< 68 do b[i] = 0
    gp16(b[:], 66, 65536-100) // matriz: classe 1, classe 1
    gp16(b[:], 74, 1); gp16(b[:], 76, 10); gp16(b[:], 78, 1); gp16(b[:], 80, 1)
    gp16(b[:], 82, 1); gp16(b[:], 84, 11); gp16(b[:], 86, 1); gp16(b[:], 88, 1)
    gp16(b[:], 90, 2); gp16(b[:], 92, 1); gp16(b[:], 94, 10); gp16(b[:], 96, 10)
    v, ok := ot_pair_advance(b[:], []int{28}, 10, 11)
    testing.expect(t, ok && v == -100)
    v, ok = ot_pair_advance(b[:], []int{28}, 10, 12)
    testing.expect(t, ok && v == 0, "glifo não listado pertence à classe zero")
}

@(test)
test_typography_gpos_truncated_and_invalid_offsets :: proc(t: ^testing.T) {
    b := gp_fixture()
    offsets: [8]int
    for size in 0 ..< 68 {
        ot_kern_lookups(b[:size], offsets[:])
        _, ok := ot_pair_advance(b[:size], []int{28}, 10, 11)
        testing.expect(t, !ok, "tabela incompleta não pode fornecer um par")
    }
    // Extensão de 32 bits apontando muito além do fim.
    gp16(b[:], 40, 65535); gp16(b[:], 42, 65535)
    _, ok := ot_pair_advance(b[:], []int{28}, 10, 11)
    testing.expect(t, !ok)
}
