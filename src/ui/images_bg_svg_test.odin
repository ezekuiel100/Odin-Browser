package ui

// SVG em `background-image` apagava o `background-color` do elemento.
//
// Uma imagem SVG termina o download em `.Ready` mas SEM textura (`tex == nil`):
// é vetorial, e o caminho de <img> a intercepta no paint (svg_image_root ->
// paint_svg_node). O background-image não tem esse caminho e desenhava mesmo
// assim, passando `TextureID(0)` ao backend — que pinta um QUAD BRANCO OPACO.
// Com o `background-repeat` default o quad era LADRILHADO sobre a caixa toda,
// cobrindo a cor de fundo.
//
// Sintoma real: www.php.net (`html { background-color:#333;
// background-image:url('/images/bg-texture-00.svg') }`) renderizava a página
// INTEIRA branca — e como o `color:#CCC` do mesmo seletor continuava valendo,
// o texto ficava cinza-claro sobre branco, ilegível. A cor de fundo estava
// sendo pintada certo; era a "imagem" que a apagava logo depois.
//
// A guarda é `bg_image_drawable`: sem textura, não desenha nada (a cor/gradiente
// por baixo permanece). O SVG de fundo em si segue NÃO renderizado — degradação
// anotada, igual às `data:` URIs, que sequer são baixadas.

import "core:testing"
import sdl2 "vendor:sdl2"

// Ponteiro de textura FALSO: o predicado só testa se é nil, nunca desreferencia.
@(private = "file")
fake_tex :: proc() -> ^sdl2.Texture {
    return cast(^sdl2.Texture)uintptr(0xF00D)
}

@(test)
test_bg_image_svg_sem_textura_nao_desenha :: proc(t: ^testing.T) {
    // o caso do php.net: SVG baixado e parseado (Ready, dims intrínsecas), tex nil
    svg := Img{state = .Ready, is_svg = true, w = 4, h = 4}
    testing.expect(t, !bg_image_drawable(&svg),
        "SVG sem textura NAO pode ser desenhado como background (pinta quad branco)")
}

@(test)
test_bg_image_raster_pronta_desenha :: proc(t: ^testing.T) {
    png := Img{state = .Ready, tex = fake_tex(), w = 8, h = 8}
    testing.expect(t, bg_image_drawable(&png),
        "imagem raster pronta com textura DEVE ser desenhada (caso comum)")
}

@(test)
test_bg_image_carregando_ou_falha_nao_desenha :: proc(t: ^testing.T) {
    loading := Img{state = .Loading, w = 8, h = 8}
    testing.expect(t, !bg_image_drawable(&loading), "imagem ainda baixando nao desenha")

    failed := Img{state = .Failed, w = 8, h = 8}
    testing.expect(t, !bg_image_drawable(&failed), "imagem que falhou nao desenha")

    testing.expect(t, !bg_image_drawable(nil), "img nil nao desenha")
}

@(test)
test_bg_image_dimensao_zero_nao_desenha :: proc(t: ^testing.T) {
    // dims 0 dividiriam por zero no cover/contain e no laço de tiling
    zero := Img{state = .Ready, tex = fake_tex(), w = 0, h = 8}
    testing.expect(t, !bg_image_drawable(&zero), "largura 0 nao desenha")

    zero2 := Img{state = .Ready, tex = fake_tex(), w = 8, h = 0}
    testing.expect(t, !bg_image_drawable(&zero2), "altura 0 nao desenha")
}
