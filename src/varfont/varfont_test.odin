package varfont

import "core:testing"
import "core:fmt"
import tt "vendor:stb/truetype"
import woff2 "../woff2"

// ── unidade ─────────────────────────────────────────────────────────────────

@(test)
test_normaliza_contra_o_eixo :: proc(t: ^testing.T) {
    a := Axis{TAG_WGHT, 100, 400, 900}
    testing.expect_value(t, normalize(a, 400), 0)
    testing.expect_value(t, normalize(a, 900), 1)
    testing.expect_value(t, normalize(a, 100), -1)
    testing.expect_value(t, normalize(a, 250), -0.5)
    testing.expect_value(t, normalize(a, 650), 0.5)
    // fora da faixa: CLAMP (font-weight 1000 numa fonte que vai até 900)
    testing.expect_value(t, normalize(a, 1000), 1)
    testing.expect_value(t, normalize(a, 1), -1)
    // eixo cujo default é a ponta: o lado que não existe vale 0
    b := Axis{TAG_WGHT, 100, 100, 900}
    testing.expect_value(t, normalize(b, 50), 0)
}

@(test)
test_avar_por_segmentos :: proc(t: ^testing.T) {
    // avar 1.0, 1 eixo, mapa {-1→-1, 0→0, 0.5→0.25, 1→1}
    f :: proc(v: f32) -> [2]u8 { x := u16(i16(v * 16384)); return {u8(x >> 8), u8(x)} }
    b := make([dynamic]u8, context.temp_allocator)
    append(&b, 0, 1, 0, 0, 0, 0, 0, 1) // major, minor, reserved, axisCount
    append(&b, 0, 4)
    for p in ([4][2]f32{{-1, -1}, {0, 0}, {0.5, 0.25}, {1, 1}}) {
        x := f(p[0]); y := f(p[1])
        append(&b, x[0], x[1], y[0], y[1])
    }
    testing.expect_value(t, avar_map(b[:], 0, 0.5), 0.25)
    testing.expect_value(t, avar_map(b[:], 0, 0.75), 0.625) // meio do segmento
    testing.expect_value(t, avar_map(b[:], 0, 0), 0)
    testing.expect_value(t, avar_map(b[:], 0, -0.5), -0.5)
    testing.expect_value(t, avar_map(b[:], 1, 0.5), 0.5) // eixo sem mapa: identidade
}

@(test)
test_escalar_de_tupla :: proc(t: ^testing.T) {
    none := []f32{0}
    testing.expect_value(t, tuple_scalar({0.5}, {1}, none, none, false), 0.5)
    testing.expect_value(t, tuple_scalar({1}, {1}, none, none, false), 1)
    testing.expect_value(t, tuple_scalar({-0.5}, {1}, none, none, false), 0) // lado oposto
    testing.expect_value(t, tuple_scalar({0}, {1}, none, none, false), 0)
    testing.expect_value(t, tuple_scalar({0.7}, {0}, none, none, false), 1) // eixo não participa
    // intermediária: pico 0.5 entre 0 e 1
    testing.expect_value(t, tuple_scalar({0.25}, {0.5}, {0}, {1}, true), 0.5)
    testing.expect_value(t, tuple_scalar({0.75}, {0.5}, {0}, {1}, true), 0.5)
}

// ── fonte real: Work Sans variável (a do animate.style) ─────────────────────
//
// Oráculo: as instâncias ESTÁTICAS que o próprio Google Fonts serve (sem UA ele
// entrega TTF por peso, gerado da mesma fonte variável pelo instanciador do
// fontTools). Avanço por letra tem de bater EXATO; bbox com folga de 1 unidade
// (arredondamento de deltas fracionários).

@(private)
VAR_W2 := #load("testdata/worksans-var-latin.woff2")
@(private)
STATIC_400 := #load("testdata/worksans-400.ttf")
@(private)
STATIC_700 := #load("testdata/worksans-700.ttf")

@(private)
Diff :: struct { adv, box, checked: int, worst: string }

// Compara letra a letra (ASCII imprimível) as métricas de duas fontes.
@(private)
compare :: proc(a, b: []byte) -> (d: Diff, ok: bool) {
    fa, fb: tt.fontinfo
    if !tt.InitFont(&fa, raw_data(a), 0) || !tt.InitFont(&fb, raw_data(b), 0) do return
    for cp in rune(0x21) ..= rune(0x7E) {
        ga := tt.FindGlyphIndex(&fa, cp)
        gb := tt.FindGlyphIndex(&fb, cp)
        if ga == 0 || gb == 0 do continue
        d.checked += 1
        aa, la, ab, lb: i32
        tt.GetGlyphHMetrics(&fa, ga, &aa, &la)
        tt.GetGlyphHMetrics(&fb, gb, &ab, &lb)
        if aa != ab {
            d.adv += 1
            if d.worst == "" do d.worst = fmt.tprintf("'%c' avanço %d × %d", cp, aa, ab)
        }
        x0a, y0a, x1a, y1a, x0b, y0b, x1b, y1b: i32
        tt.GetGlyphBox(&fa, ga, &x0a, &y0a, &x1a, &y1a)
        tt.GetGlyphBox(&fb, gb, &x0b, &y0b, &x1b, &y1b)
        if abs(x0a - x0b) > 1 || abs(y0a - y0b) > 1 || abs(x1a - x1b) > 1 || abs(y1a - y1b) > 1 {
            d.box += 1
            if d.worst == "" do d.worst = fmt.tprintf("'%c' bbox (%d,%d,%d,%d) × (%d,%d,%d,%d)", cp, x0a, y0a, x1a, y1a, x0b, y0b, x1b, y1b)
        }
    }
    return d, true
}

@(test)
test_work_sans_eixo_de_peso :: proc(t: ^testing.T) {
    sfnt, err := woff2.to_sfnt(VAR_W2)
    defer delete(sfnt)
    if !testing.expectf(t, err == .None, "woff2: %v", err) do return
    mn, df, mx, ok := weight_axis(sfnt)
    testing.expect(t, ok, "Work Sans tem eixo wght")
    testing.expectf(t, mn == 100 && mx == 900, "faixa %v..%v", mn, mx)
    _ = df
    // fonte estática não é variável
    _, _, _, ok2 := weight_axis(STATIC_700)
    testing.expect(t, !ok2, "o TTF estático não tem fvar")
    _, e2 := instantiate_weight(STATIC_700, 700)
    testing.expect_value(t, e2, Error.Not_Variable)
}

@(test)
test_work_sans_700_bate_com_a_instancia_estatica_do_google :: proc(t: ^testing.T) {
    sfnt, err := woff2.to_sfnt(VAR_W2)
    defer delete(sfnt)
    if !testing.expect(t, err == .None) do return

    // CONTROLE: a instância padrão (o que pintávamos antes) NÃO bate com o 700.
    // Sem isto o teste abaixo poderia passar por um oráculo cego.
    ctl, cok := compare(sfnt, STATIC_700)
    if !testing.expect(t, cok) do return
    testing.expectf(t, ctl.adv > ctl.checked / 2,
        "controle: só %d/%d avanços divergem do 700 — o oráculo não distingue", ctl.adv, ctl.checked)

    bold, e := instantiate_weight(sfnt, 700)
    defer delete(bold)
    if !testing.expectf(t, e == .None, "instantiate_weight: %v", e) do return
    d, ok := compare(bold, STATIC_700)
    if !testing.expect(t, ok, "a instância tem de abrir no stb") do return
    testing.expectf(t, d.checked > 90, "só %d letras comparadas", d.checked)
    testing.expectf(t, d.adv == 0 && d.box == 0,
        "700: %d avanços e %d bbox divergem de %d (1º: %s)", d.adv, d.box, d.checked, d.worst)
}

@(test)
test_work_sans_400_e_default_ou_bate :: proc(t: ^testing.T) {
    sfnt, err := woff2.to_sfnt(VAR_W2)
    defer delete(sfnt)
    if !testing.expect(t, err == .None) do return
    inst, e := instantiate_weight(sfnt, 400)
    defer delete(inst)
    src := e == .Default ? sfnt : inst
    if e != .Default && !testing.expectf(t, e == .None, "400: %v", e) do return
    d, ok := compare(src, STATIC_400)
    if !testing.expect(t, ok) do return
    testing.expectf(t, d.adv == 0 && d.box == 0,
        "400: %d avanços e %d bbox divergem de %d (1º: %s)", d.adv, d.box, d.checked, d.worst)
}

// Peso INTERMEDIÁRIO (sem estática para comparar): monotonia da TINTA. ⚠️ Não
// use o avanço: nesta família o do 'n' vai de 619 a 620 entre 400 e 700 — a
// 1ª versão deste teste afirmava avanço crescente e reprovou uma instância certa.
// O que o peso muda é a espessura do traço, logo a tinta rasterizada.
@(test)
test_work_sans_peso_intermediario_e_monotono :: proc(t: ^testing.T) {
    sfnt, err := woff2.to_sfnt(VAR_W2)
    defer delete(sfnt)
    if !testing.expect(t, err == .None) do return
    ink :: proc(b: []byte) -> int {
        f: tt.fontinfo
        if !tt.InitFont(&f, raw_data(b), 0) do return -1
        w, h, xo, yo: i32
        s := tt.ScaleForPixelHeight(&f, 120)
        bm := tt.GetCodepointBitmap(&f, 0, s, 'n', &w, &h, &xo, &yo)
        defer tt.FreeBitmap(bm, nil)
        sum := 0
        for i in 0 ..< int(w * h) do sum += int(bm[i])
        return sum
    }
    w := [4]f32{300, 400, 550, 700}
    tinta: [4]int
    for x, i in w {
        b, e := instantiate_weight(sfnt, x)
        defer delete(b)
        tinta[i] = ink(e == .Default ? sfnt : b)
    }
    testing.expectf(t, tinta[0] < tinta[1] && tinta[1] < tinta[2] && tinta[2] < tinta[3], "tinta do n: %v", tinta)
}

// Bytes truncados não podem derrubar o processo (a entrada vem da rede).
@(test)
test_truncado_nao_derruba :: proc(t: ^testing.T) {
    sfnt, err := woff2.to_sfnt(VAR_W2)
    defer delete(sfnt)
    if !testing.expect(t, err == .None) do return
    for cut in ([]int{0, 6, 12, 100, len(sfnt) / 3, len(sfnt) / 2, len(sfnt) - 7}) {
        b, _ := instantiate_weight(sfnt[:cut], 700)
        delete(b)
    }
}
