package ui

// O emoji chega ao LAYOUT como item de imagem? (M188)
//
// O teste do rasterizador (emoji_test.odin) prova que sabemos desenhar; este
// prova o outro elo: que `add_words` separa o emoji do texto e cria um item
// `.Image` com a chave sintética. Sem este, um bug de plumbing passaria batido —
// o rasterizador continuaria verde e a tela continuaria sem foguete.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
layout_from_html :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
conta_emoji :: proc(root: ^Box) -> (n_emoji: int, n_word: int, url: string) {
    if root == nil do return
    for &it in root.inlines {
        switch it.kind {
        case .Image:
            if _, ok := emoji_key_rune(it.img_url); ok {
                n_emoji += 1
                if url == "" do url = it.img_url
            }
        case .Word:
            if it.text != "" do n_word += 1
        case .Break, .InlineBox:
        }
    }
    for ch in root.children {
        e, w, u := conta_emoji(ch)
        n_emoji += e; n_word += w
        if url == "" do url = u
    }
    return
}

@(test)
emoji_vira_item_de_imagem_no_layout :: proc(t: ^testing.T) {
    root := layout_from_html("<div id=\"d\">\U0001F680 Comecar</div>")
    n, w, url := conta_emoji(root)
    testing.expectf(t, n == 1, "o foguete tem de virar 1 item de imagem; veio %d", n)
    testing.expectf(t, url == "emoji:1F680", "com a chave do codepoint; veio %q", url)
    testing.expectf(t, w >= 1, "e o texto ao lado continua como Word; veio %d", w)
}

@(test)
emoji_colado_no_texto_separa :: proc(t: ^testing.T) {
    root := layout_from_html("<div id=\"d\">a\U0001F680b</div>")
    n, w, _ := conta_emoji(root)
    testing.expectf(t, n == 1, "emoji colado tambem sai; veio %d", n)
    testing.expectf(t, w == 2, "sobram os Words 'a' e 'b'; veio %d", w)
}

// O caminho comum não pode ganhar itens novos: texto sem emoji continua sendo
// UM Word (é o que mantém coalesce_words/medição idênticos ao de antes).
@(test)
texto_sem_emoji_nao_muda :: proc(t: ^testing.T) {
    root := layout_from_html("<div id=\"d\">Comecar Gratis</div>")
    n, w, _ := conta_emoji(root)
    testing.expectf(t, n == 0, "sem emoji, nenhum item de imagem; veio %d", n)
    testing.expectf(t, w == 2, "duas palavras, dois Words; veio %d", w)
}
