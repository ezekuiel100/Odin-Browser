package ui

// border-image (css-backgrounds-3 §6).
//
// O parser é o que dá p/ afirmar sem janela: a PINTURA depende de textura e de
// métrica, e por isso o 9-slice é coberto pelo portão de pintura
// (tests/paint/border-image.html) e pelo oráculo contra o Chrome.
//
// ⚠️ Os valores INICIAIS não são o zero-value: slice inicial é 100% e width
// inicial é 1 (múltiplo da border-width). Uma struct zerada desenharia NADA, e é
// por isso que `bimg_initial()` existe em vez de um `Border_Image{}`.

import "core:testing"

@(private = "file")
bimg_de :: proc(decls: string) -> Border_Image {
    return test_apply(decls).bimg
}

@(test)
test_border_image_longhands :: proc(t: ^testing.T) {
    // sem fonte NÃO ativa: a borda normal tem de continuar valendo (spec)
    b0 := bimg_de(`border-image-slice: 30`)
    testing.expect(t, !b0.active, "só a fatia, sem fonte, não pode ativar border-image")

    b1 := bimg_de(`border-image-source: url(f.png); border-image-slice: 30`)
    testing.expect(t, b1.active && b1.src == "f.png", "fonte url ativa")
    testing.expectf(t, b1.slice == [4]f32{30, 30, 30, 30} && b1.slice_pct == [4]bool{},
        "1 valor vale p/ os 4 lados, sem %%; veio %v", b1.slice)

    // 1-4 valores no padrão CSS (t / t-r / t-r-b / t-r-b-l)
    b2 := bimg_de(`border-image-source: url(f.png); border-image-slice: 10 20`)
    testing.expectf(t, b2.slice == [4]f32{10, 20, 10, 20}, "2 valores = t-r-b-l cruzado; veio %v", b2.slice)
    b3 := bimg_de(`border-image-source: url(f.png); border-image-slice: 10 20 30`)
    testing.expectf(t, b3.slice == [4]f32{10, 20, 30, 20}, "3 valores; veio %v", b3.slice)
    b4 := bimg_de(`border-image-source: url(f.png); border-image-slice: 10 20 30 40`)
    testing.expectf(t, b4.slice == [4]f32{10, 20, 30, 40}, "4 valores; veio %v", b4.slice)

    // porcentagem e `fill` (que é uma PALAVRA no meio da lista de números)
    b5 := bimg_de(`border-image-source: url(f.png); border-image-slice: 33% fill`)
    testing.expect(t, b5.slice_pct[0] && b5.slice[0] == 33, "fatia em %")
    testing.expect(t, b5.fill, "`fill` liga o miolo")
    b6 := bimg_de(`border-image-source: url(f.png); border-image-slice: 30`)
    testing.expect(t, !b6.fill, "CONTRA-CASO: sem `fill` o miolo não é pintado")

    // width: número PURO é múltiplo da border-width — distinto de px
    w1 := bimg_de(`border-image-source: url(f.png); border-image-width: 2`)
    testing.expect(t, w1.wkind[0] == .Number && w1.width[0] == 2, "número = múltiplo da border-width")
    w2 := bimg_de(`border-image-source: url(f.png); border-image-width: 15px`)
    testing.expect(t, w2.wkind[0] == .Len && w2.width[0] == 15, "px = comprimento")
    w3 := bimg_de(`border-image-source: url(f.png); border-image-width: 20%`)
    testing.expect(t, w3.wkind[0] == .Pct && w3.width[0] == 20, "% da área")
    w4 := bimg_de(`border-image-source: url(f.png); border-image-width: auto`)
    testing.expect(t, w4.wkind[0] == .Auto, "auto = o tamanho da fatia")

    // outset: número (múltiplo da border-width) × comprimento
    o1 := bimg_de(`border-image-source: url(f.png); border-image-outset: 2`)
    testing.expect(t, o1.outset_num[0] && o1.outset[0] == 2, "outset numérico")
    o2 := bimg_de(`border-image-source: url(f.png); border-image-outset: 7px`)
    testing.expect(t, !o2.outset_num[0] && o2.outset[0] == 7, "outset em px")

    r1 := bimg_de(`border-image-source: url(f.png); border-image-repeat: round`)
    testing.expect(t, r1.repeat[0] == .Round && r1.repeat[1] == .Round, "1 valor vale p/ os 2 eixos")
    r2 := bimg_de(`border-image-source: url(f.png); border-image-repeat: repeat stretch`)
    testing.expect(t, r2.repeat[0] == .Repeat && r2.repeat[1] == .Stretch, "2 valores = h e v")
}

@(test)
test_border_image_defaults :: proc(t: ^testing.T) {
    // Só a FONTE: tudo o mais tem de cair nos INICIAIS da spec — e o inicial de
    // slice é 100%, não 0. Com 0 a moldura sairia vazia em silêncio.
    b := bimg_de(`border-image-source: url(f.png)`)
    testing.expect(t, b.active, "fonte sozinha já ativa")
    testing.expectf(t, b.slice == [4]f32{100, 100, 100, 100} && b.slice_pct[0],
        "slice inicial = 100%%; veio %v pct=%v", b.slice, b.slice_pct[0])
    testing.expectf(t, b.width == [4]f32{1, 1, 1, 1} && b.wkind[0] == .Number,
        "width inicial = 1 (múltiplo da border-width); veio %v", b.width)
    testing.expect(t, b.outset == [4]f32{}, "outset inicial = 0")
    testing.expect(t, b.repeat[0] == .Stretch && b.repeat[1] == .Stretch, "repeat inicial = stretch")
    testing.expect(t, !b.fill, "fill inicial = desligado")
}

@(test)
test_border_image_shorthand :: proc(t: ^testing.T) {
    // fonte + fatia + repetição, tudo misturado numa parte só: o parser roteia
    // por VALOR (é imagem? é palavra-chave? é número?), não por posição
    s1 := bimg_de(`border-image: url(f.png) 30 round`)
    testing.expect(t, s1.active && s1.src == "f.png", "fonte do shorthand")
    testing.expectf(t, s1.slice == [4]f32{30, 30, 30, 30}, "fatia do shorthand; veio %v", s1.slice)
    testing.expect(t, s1.repeat[0] == .Round, "repetição do shorthand")

    // as barras separam fatia / largura / outset
    s2 := bimg_de(`border-image: url(f.png) 20 / 12px / 4px round`)
    testing.expectf(t, s2.slice[0] == 20, "fatia antes da 1ª barra; veio %v", s2.slice[0])
    testing.expectf(t, s2.wkind[0] == .Len && s2.width[0] == 12, "largura entre as barras; veio %v", s2.width[0])
    testing.expectf(t, !s2.outset_num[0] && s2.outset[0] == 4, "outset depois da 2ª barra; veio %v", s2.outset[0])

    // ⚠️ a barra de DENTRO do url() não pode cortar o shorthand
    s3 := bimg_de(`border-image: url(a/b/c.png) 10`)
    testing.expectf(t, s3.src == "a/b/c.png", "url com barra sobrevive ao split; veio %q", s3.src)
    testing.expectf(t, s3.slice[0] == 10, "e a fatia continua sendo lida; veio %v", s3.slice[0])

    // gradiente como fonte (o idioma moderno) — guardado como TEXTO
    s4 := bimg_de(`border-image: linear-gradient(to right, red, blue) 1`)
    testing.expect(t, s4.active && s4.src == "" && s4.grad != "", "gradiente vira fonte, não url")
    testing.expectf(t, s4.slice[0] == 1, "fatia 1; veio %v", s4.slice[0])

    // `none` desativa
    s5 := bimg_de(`border-image: none`)
    testing.expect(t, !s5.active, "none = sem border-image")

    // longhand explícito vence o shorthand na MESMA regra (a convenção que os
    // lotes 14/15/22 já usam, porque o `wins` não guarda ordem por declaração)
    s6 := bimg_de(`border-image: url(f.png) 30 round; border-image-repeat: stretch`)
    testing.expect(t, s6.repeat[0] == .Stretch, "o longhand vence o shorthand")
}
