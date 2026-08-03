package ui

// Testes do pipeline de layout: HTML -> DOM -> compute_styles -> build_layout.
// Diferente de style_test.odin (que para em Computed), estes exercitam a
// construção da árvore de Box. Servem de rede de segurança contra:
//   - recursão infinita em build_layout/new_box (estoura a pilha → teste falha)
//   - opacity padrão != 1.0 (regressão da "página branca")
// Rodar:  odin test src/ui

import "core:testing"
import htmlp  "../html"
import csspkg "../css"

// Roda o pipeline completo a partir de um HTML e devolve a raiz da árvore.
@(private="file")
build_from_html :: proc(html: string) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")          // sem folhas externas; usa só style="" inline
    styles, _ := compute_styles(dom, &rules)
    return build_layout(dom, styles, "")
}

// Igual ao build_from_html, mas também roda o layout (dimensiona/posiciona) e o
// passe de absolutos — necessário para inspecionar w/x/y das caixas.
@(private="file")
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

// Primeira caixa position:absolute em pré-ordem.
@(private="file")
first_absolute :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.pos == .Absolute do return b
    for c in b.children {
        if r := first_absolute(c); r != nil do return r
    }
    return nil
}

// Existe algum item inline .Word com exatamente este texto na subárvore?
@(private="file")
has_word :: proc(b: ^Box, want: string) -> bool {
    if b == nil do return false
    for &it in b.inlines {
        if it.kind == .Word && it.text == want do return true
    }
    for c in b.children {
        if has_word(c, want) do return true
    }
    return false
}

@(test)
test_inline_style_not_rendered :: proc(t: ^testing.T) {
    // <style> embutido num <span> inline (padrão TemplateStyles da Wikipédia) não
    // deve ter seu texto CSS renderizado como palavras no fluxo inline.
    html := `<p id="p">antes <span><style>.zzzmarker{color:red}</style></span> depois</p>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    testing.expect(t, has_word(root, "antes"),  "texto real 'antes' presente")
    testing.expect(t, has_word(root, "depois"), "texto real 'depois' presente")
    testing.expect(t, !has_word(root, ".zzzmarker{color:red}"), "CSS do <style> NÃO renderiza")
}

@(test)
test_inline_display_none_not_rendered :: proc(t: ^testing.T) {
    // span inline com display:none não contribui texto no fluxo inline.
    html := `<p id="p">a <span style="display:none">OCULTO</span> b</p>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    testing.expect(t, has_word(root, "a") && has_word(root, "b"), "texto visível presente")
    testing.expect(t, !has_word(root, "OCULTO"), "texto de display:none NÃO renderiza")
}

// Devolve o primeiro item .Word com este texto (p/ inspecionar cor/estilo).
@(private="file")
find_word_item :: proc(b: ^Box, want: string) -> (Inline_Item, bool) {
    if b == nil do return {}, false
    for it in b.inlines {
        if it.kind == .Word && it.text == want do return it, true
    }
    for c in b.children {
        if r, ok := find_word_item(c, want); ok do return r, true
    }
    return {}, false
}

// Visita a árvore de Box em pré-ordem e chama fn em cada nó.
@(private="file")
walk_boxes :: proc(b: ^Box, fn: proc(^Box) -> bool) -> bool {
    if b == nil do return false
    if fn(b) do return true
    for c in b.children {
        if walk_boxes(c, fn) do return true
    }
    return false
}

// Primeira caixa com o controle de formulário dado (busca em pré-ordem).
@(private="file")
find_ctrl :: proc(b: ^Box, want: Form_Control) -> ^Box {
    if b == nil do return nil
    if b.ctrl == want do return b
    for c in b.children {
        if r := find_ctrl(c, want); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_ctrl(it.box, want); r != nil do return r
        }
    }
    return nil
}

// Valor do buffer editável (até o terminador nulo) como string.
@(private="file")
edit_value :: proc(b: ^Box) -> string {
    n := 0
    for n < EDIT_CAP && b.edit_buf[n] != 0 do n += 1
    return string(b.edit_buf[:n])
}

// ── textarea ───────────────────────────────────────────────────────────────────

@(test)
test_textarea_valor_inicial :: proc(t: ^testing.T) {
    root := build_from_html("<textarea>Linha um\nLinha dois</textarea>")
    defer free_layout(root)
    ta := find_ctrl(root, .Textarea)
    testing.expect(t, ta != nil, "textarea vira controle .Textarea")
    if ta != nil {
        testing.expect_value(t, edit_value(ta), "Linha um\nLinha dois")
    }
}

@(test)
test_textarea_newline_lider_removido :: proc(t: ^testing.T) {
    // a spec ignora um único '\n' logo após <textarea>
    root := build_from_html("<textarea>\nconteudo</textarea>")
    defer free_layout(root)
    ta := find_ctrl(root, .Textarea)
    testing.expect(t, ta != nil, "textarea presente")
    if ta != nil do testing.expect_value(t, edit_value(ta), "conteudo")
}

@(test)
test_textarea_disabled :: proc(t: ^testing.T) {
    root := build_from_html("<textarea disabled>x</textarea>")
    defer free_layout(root)
    ta := find_ctrl(root, .Textarea)
    testing.expect(t, ta != nil && ta.ctrl_disabled, "disabled marca ctrl_disabled")
}

// ── display: block / inline ─────────────────────────────────────────────────────

// Conta caixas de bloco cujo nó tem a tag dada.
@(private="file")
count_tag_boxes :: proc(b: ^Box, tag: string) -> int {
    if b == nil do return 0
    total := 0
    if b.node != nil && b.node.tag == tag do total += 1
    for c in b.children do total += count_tag_boxes(c, tag)
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil do total += count_tag_boxes(it.box, tag)
    }
    return total
}

@(test)
test_display_block_em_tag_inline :: proc(t: ^testing.T) {
    // <label> é inline por padrão → vira item inline (0 caixas de bloco próprias).
    // display:block deve torná-lo uma caixa de bloco própria.
    inl := build_from_html(`<label>A</label>`)
    defer free_layout(inl)
    testing.expect_value(t, count_tag_boxes(inl, "label"), 0) // inline: sem caixa própria

    blk := build_from_html(`<label style="display:block">A</label>`)
    defer free_layout(blk)
    testing.expect_value(t, count_tag_boxes(blk, "label"), 1) // bloco: caixa própria
}

@(test)
test_display_inline_em_tag_bloco :: proc(t: ^testing.T) {
    // <div> é bloco por padrão (caixa própria); display:inline deve inliná-lo.
    blk := build_from_html(`<div>A</div>`)
    defer free_layout(blk)
    testing.expect_value(t, count_tag_boxes(blk, "div"), 1)

    inl := build_from_html(`<div style="display:inline">A</div>`)
    defer free_layout(inl)
    testing.expect_value(t, count_tag_boxes(inl, "div"), 0) // inline: sem caixa própria
}

// ── white-space ────────────────────────────────────────────────────────────────

@(test)
test_ws_nowrap_marca_itens :: proc(t: ^testing.T) {
    root := build_from_html(`<div style="white-space: nowrap">um dois</div>`)
    defer free_layout(root)
    it, ok := find_word_item(root, "um")
    testing.expect(t, ok, "palavra presente")
    testing.expect(t, it.nowrap, "white-space:nowrap marca os itens com nowrap")
}

@(test)
test_ws_normal_sem_nowrap :: proc(t: ^testing.T) {
    root := build_from_html(`<div>um dois</div>`)
    defer free_layout(root)
    it, ok := find_word_item(root, "um")
    testing.expect(t, ok, "palavra presente")
    testing.expect(t, !it.nowrap, "texto normal não é nowrap")
}

@(test)
test_ws_pre_preserva_quebras :: proc(t: ^testing.T) {
    // white-space:pre em <div> (sem tag <pre>): '\n' vira item .Break
    root := build_from_html("<div style=\"white-space: pre\">um\ndois</div>")
    defer free_layout(root)
    testing.expect(t, has_word(root, "um") && has_word(root, "dois"), "palavras presentes")
    achou_break := walk_boxes(root, proc(b: ^Box) -> bool {
        for it in b.inlines do if it.kind == .Break do return true
        return false
    })
    testing.expect(t, achou_break, "white-space:pre gera .Break no '\\n'")
}

// ── Regressão: build_layout não pode recursar infinitamente ─────────────────────
// Se new_box() ou build_layout voltarem a se auto-chamar, este teste estoura a
// pilha (stack overflow) e o processo de teste falha — exatamente o sintoma que
// queremos capturar em CI em vez de no navegador rodando.

@(test)
test_build_layout_nao_crasha :: proc(t: ^testing.T) {
    layout := build_from_html("<html><body><div style='background:red;width:100px;height:100px'>oi</div></body></html>")
    testing.expect(t, layout != nil, "build_layout deve retornar uma raiz")
}

@(test)
test_build_layout_aninhado :: proc(t: ^testing.T) {
    // árvore com alguma profundidade + features que tocam o paint
    html := "<html><body>" +
        "<div style='opacity:0.5;background:blue;width:80px;height:80px'>" +
        "  <p style='transform:translate(-50%,-50%);position:absolute'>x</p>" +
        "  <span style='opacity:0'>some</span>" +
        "</div></body></html>"
    layout := build_from_html(html)
    testing.expect(t, layout != nil, "árvore aninhada deve construir")
    // percorre a árvore inteira: se houver ciclo, walk_boxes recursaria sem fim
    walk_boxes(layout, proc(b: ^Box) -> bool { return false })
}

// ── Regressão: opacity padrão = 1.0 (página branca) ─────────────────────────────
// Todo Box criado por new_box() deve nascer com opacity 1.0. Se voltar a 0 (o
// zero-value de Odin), o paint descarta tudo e a página fica em branco.

@(test)
test_opacity_padrao_em_todos_os_boxes :: proc(t: ^testing.T) {
    layout := build_from_html("<html><body><div style='background:red;width:50px;height:50px'><p>texto</p></div></body></html>")
    testing.expect(t, layout != nil, "layout deve existir")

    bad := walk_boxes(layout, proc(b: ^Box) -> bool {
        return b.opacity <= 0   // qualquer box invisível por padrão é bug
    })
    testing.expect(t, !bad, "nenhum box deve nascer com opacity <= 0")
}

// ── Regressão: absolutos com largura auto fazem shrink-to-fit ───────────────────
// Sem isso, todo position:absolute vira uma faixa de largura total e sobrepõe o
// resto da página (o bug de posicionamento do famososbr). Usa um filho de largura
// explícita p/ a largura intrínseca não depender de fontes (ausentes no teste).

@(test)
test_absolute_shrink_to_fit :: proc(t: ^testing.T) {
    html := "<html><body>" +
        "<div style='position:relative;width:600px;height:400px'>" +
        "<div style='position:absolute;background:red'>" +
        "<div style='width:120px;height:20px'></div>" +
        "</div></div></body></html>"
    root := layout_from_html(html)
    abs := first_absolute(root)
    testing.expect(t, abs != nil, "deve haver um box absoluto")
    testing.expect(t, abs.w > 100 && abs.w < 300, "absoluto auto encolhe ao conteudo (~120, nao 600)")
    testing.expect(t, abs.has_static, "absoluto sem inset registra a posicao estatica")
}

@(test)
test_absolute_anchored_right :: proc(t: ^testing.T) {
    // right:0 ancora a borda direita no contêiner (600 de largura, na origem 0)
    html := "<html><body>" +
        "<div style='position:relative;width:600px;height:400px'>" +
        "<div style='position:absolute;right:0;top:0;background:blue'>" +
        "<div style='width:80px;height:20px'></div>" +
        "</div></div></body></html>"
    root := layout_from_html(html)
    abs := first_absolute(root)
    testing.expect(t, abs != nil, "deve haver um box absoluto")
    // borda direita do absoluto ~ borda direita do contêiner (600)
    testing.expect(t, abs.x + abs.w > 560, "right:0 ancora perto da borda direita")
}

@(test)
test_flex_abspos_static :: proc(t: ^testing.T) {
    // abspos filho de um container flex (justify/align center) tem a posição
    // ESTÁTICA alinhada pelo flex (centraliza a margin box), e o içamento o
    // re-parenteia ao box do CB (o próprio container relative). container 100x100
    // em (8,8) por causa da margem default do body; margin box 60 (margin 10 + 50);
    // offset (100-60)/2=20; x = 8 + 20 + margin 10 = 38. idem y.
    html := "<html><body>" +
        "<div style='position:relative;width:100px;height:100px;display:flex;justify-content:center;align-items:center'>" +
        "<div style='position:absolute;width:50px;height:50px;margin-left:10px;margin-top:10px;background:green'></div>" +
        "</div></body></html>"
    root := layout_from_html(html)
    abs := first_absolute(root)
    testing.expect(t, abs != nil, "deve haver um box absoluto")
    testing.expect(t, abs.x > 36 && abs.x < 40, "abspos centralizado pelo flex em x~38")
    testing.expect(t, abs.y > 36 && abs.y < 40, "abspos centralizado pelo flex em y~38")
}

@(test)
test_absolute_auto_margin_center_h :: proc(t: ^testing.T) {
    // left:0;right:0;margin:auto;width:100px num contêiner de 300px → centralizado.
    // free=200 → offset 100 (+8px de margem do body). Sem o fix ficaria em left:0.
    html := "<html><body>" +
        "<div style='position:relative;width:300px;height:100px'>" +
        "<div style='position:absolute;left:0;right:0;margin:auto;width:100px;height:50px;background:green'></div>" +
        "</div></body></html>"
    root := layout_from_html(html)
    abs := first_absolute(root)
    testing.expect(t, abs != nil, "deve haver um box absoluto")
    testing.expect_value(t, abs.w, f32(100))
    testing.expect(t, abs.x > 95 && abs.x < 120, "left:0;right:0;margin:auto centraliza horizontalmente")
}

@(test)
test_absolute_auto_margin_center_v :: proc(t: ^testing.T) {
    // top:0;bottom:0;margin:auto;height:40px num contêiner de 200px → y~88.
    html := "<html><body>" +
        "<div style='position:relative;width:100px;height:200px'>" +
        "<div style='position:absolute;top:0;bottom:0;margin:auto;height:40px;width:50px;background:green'></div>" +
        "</div></body></html>"
    root := layout_from_html(html)
    abs := first_absolute(root)
    testing.expect(t, abs != nil, "deve haver um box absoluto")
    testing.expect(t, abs.y > 80 && abs.y < 100, "top:0;bottom:0;margin:auto centraliza verticalmente")
}

@(test)
test_font_size_zero_mantem_strut :: proc(t: ^testing.T) {
    // <span font-size:0> é invisível, mas a caixa-linha do <p> mantém o strut da
    // fonte própria do bloco (16 × line-height ~1.3 ≈ 20). Sem isso a linha
    // colapsaria a 0 e o conteúdo seguinte subiria.
    root := layout_from_html("<html><body><p id='p'><span style='font-size:0'>zero</span></p></body></html>")
    p := find_box_by_id(root, "p")
    testing.expect(t, p != nil, "deve achar o <p>")
    testing.expect(t, p.strut > 15, "strut do bloco setado (~16*1.3)")
    testing.expect(t, p.h > 15, "linha com font-size:0 mantém a altura do strut")
}

// ── text-transform aplicado ao texto no build ──────────────────────────────────

@(test)
test_text_transform_uppercase :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><p style='text-transform:uppercase'>hello world</p></body></html>")
    testing.expect(t, has_word(root, "HELLO"), "uppercase transforma a palavra")
    testing.expect(t, has_word(root, "WORLD"), "uppercase na segunda palavra")
}

@(test)
test_text_transform_capitalize :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><p style='text-transform:capitalize'>hello world</p></body></html>")
    testing.expect(t, has_word(root, "Hello"), "capitalize maiuscula so a 1a letra")
    testing.expect(t, has_word(root, "World"), "capitalize na segunda palavra")
}

@(test)
test_text_transform_herda :: proc(t: ^testing.T) {
    // definido no pai; a palavra do filho <span> deve herdar a transformacao
    root := build_from_html("<html><body><p style='text-transform:uppercase'>oi <span>mundo</span></p></body></html>")
    testing.expect(t, has_word(root, "MUNDO"), "filho herda text-transform do pai")
}

// ── estilo próprio de elemento inline (color/transform) ─────────────────────────

@(test)
test_inline_own_text_transform :: proc(t: ^testing.T) {
    // text-transform DIRETO no elemento inline (não herdado do pai)
    root := build_from_html("<html><body><p>oi <b style='text-transform:uppercase'>mundo</b></p></body></html>")
    testing.expect(t, has_word(root, "MUNDO"), "inline aplica seu proprio text-transform")
}

@(test)
test_inline_own_color :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><p>a <span style='color:#ff0000'>vermelho</span></p></body></html>")
    it, ok := find_word_item(root, "vermelho")
    testing.expect(t, ok, "palavra do span existe")
    testing.expect_value(t, it.color, u32(0xff0000))
}

@(test)
test_inline_link_color_preservada :: proc(t: ^testing.T) {
    // regressão: <span> dentro de <a> não deve sobrescrever a cor de link
    root := build_from_html("<html><body><p><a href='x'><span>link</span></a></p></body></html>")
    it, ok := find_word_item(root, "link")
    testing.expect(t, ok, "palavra do link existe")
    testing.expect_value(t, it.color, u32(COL_LINK))
}

@(test)
test_bloco_herda_color_do_pai :: proc(t: ^testing.T) {
    // regressão famososbr.com: um elemento de BLOCO que só HERDA `color` (não o
    // define) deve pintar com a cor herdada — não com DEFAULT_TEXT. O caminho de
    // bloco (build_box) calculava eff_color a partir do has_color DESTE elemento e
    // caía em DEFAULT_TEXT quando false, ignorando comp.color já herdado. Efeito:
    // <p>/<h2> sob `body{color:...}` saíam escuros e ilegíveis no fundo escuro.
    // O caminho inline (<span>) já herdava certo — por isso os testes antigos, que
    // só cobriam cor própria/inline, não pegavam isto.
    root := build_from_html("<html><body style='color:#f8f9fa'><div><p>herdado</p></div></body></html>")
    it, ok := find_word_item(root, "herdado")
    testing.expect(t, ok, "palavra do bloco filho existe")
    testing.expect_value(t, it.color, u32(0xf8f9fa)) // herdado do body, não DEFAULT_TEXT
}

@(test)
test_link_sem_color_continua_azul :: proc(t: ^testing.T) {
    // guarda do outro ramo do fix: <a href> de BLOCO sem color próprio ainda usa a
    // cor de link (não herda o texto do pai).
    root := build_from_html("<html><body style='color:#f8f9fa'>" +
        "<a href='x' style='display:block'>link</a></body></html>")
    it, ok := find_word_item(root, "link")
    testing.expect(t, ok, "palavra do link de bloco existe")
    testing.expect_value(t, it.color, u32(COL_LINK))
}

@(test)
test_link_color_inherit_vence_o_azul_do_ua :: proc(t: ^testing.T) {
    // `a{color:inherit}` é o reset de link do preflight do Tailwind (e do
    // normalize/Bootstrap): o site pinta os links com a cor do container. Como
    // `parse_color("inherit")` FALHA, has_color ficava false e o link caía no azul
    // do nosso UA-stylesheet — rodapé e menu de site moderno saíam azuis, com a cor
    // escolhida pelo site ignorada. `color` herda, então o valor certo já estava em
    // comp; faltava só a marca de "o autor definiu cor aqui".
    root := build_from_html("<html><body style='color:#f8f9fa'>" +
        "<p><a href='x' style='color:inherit'>link</a></p></body></html>")
    it, ok := find_word_item(root, "link")
    testing.expect(t, ok, "palavra do link existe")
    testing.expect_value(t, it.color, u32(0xf8f9fa))
}

@(test)
test_link_color_unset_equivale_a_inherit :: proc(t: ^testing.T) {
    // `unset` numa propriedade que HERDA é idêntico a `inherit` (CSS Cascade §7.3).
    root := build_from_html("<html><body style='color:#f8f9fa'>" +
        "<p><a href='x' style='color:unset'>link</a></p></body></html>")
    it, ok := find_word_item(root, "link")
    testing.expect(t, ok, "palavra do link existe")
    testing.expect_value(t, it.color, u32(0xf8f9fa))
}

// Coleta o y de cada caixa que carrega itens inline (= uma "linha de conteúdo").
@(private="file")
collect_run_ys :: proc(b: ^Box, out: ^[dynamic]f32) {
    if b == nil do return
    if len(b.inlines) > 0 do append(out, b.y)
    for c in b.children do collect_run_ys(c, out)
}

@(test)
test_code_com_filhos_block_empilha_linhas :: proc(t: ^testing.T) {
    // Shiki/Prism (todo site de documentação) emitem o bloco de código como
    // `<pre><code><code><span class="line">…</span><span class="line">…` SEM nenhum
    // `\n`: quem quebra as linhas é o CSS, `.line{display:block}`. Como `<code>` é
    // tag INLINE, a subárvore inteira era achatada num run e TODAS as linhas saíam
    // NUMA SÓ. O `<pre>` sozinho já funcionava (tag de bloco) — daí o defeito ter
    // passado despercebido. Note o `<code>` DUPLO: a busca por bloco tem de ser
    // recursiva, não só nos filhos diretos.
    root := layout_from_html("<html><body><pre><code><code>" +
        "<span style='display:block'>alfa</span>" +
        "<span style='display:block'>beta</span>" +
        "<span style='display:block'>gama</span>" +
        "</code></code></pre></body></html>")
    ys := make([dynamic]f32, context.temp_allocator)
    collect_run_ys(root, &ys)
    testing.expectf(t, len(ys) == 3, "cada linha vira caixa propria; vieram %d", len(ys))
    if len(ys) == 3 {
        testing.expectf(t, ys[0] < ys[1] && ys[1] < ys[2],
            "linhas EMPILHADAS (y crescente); vieram %.0f/%.0f/%.0f", ys[0], ys[1], ys[2])
    }
}

@(test)
test_block_em_inline_fora_de_pre_segue_achatado :: proc(t: ^testing.T) {
    // DEGRADAÇÃO DELIBERADA, documentada aqui de propósito: a divisão em caixas
    // anônimas está escopada a contexto pré-formatado. Fora dele o achatamento
    // antigo continua, porque aplicar o modelo do CSS em todo lugar custa 3 FAILs
    // nomeados no WPT que só passam por causa desse achatamento (all-prop-002
    // depende de `all:inherit`, e first-letter-exclude-inline-child-marker de
    // `display:inline list-item` — dois gaps NOSSOS, não deste código).
    // Quando esses gaps fecharem, tire o escopo e ESTE teste muda junto.
    root := layout_from_html("<html><body><div><code>" +
        "<span style='display:block'>alfa</span><span style='display:block'>beta</span>" +
        "</code></div></body></html>")
    ys := make([dynamic]f32, context.temp_allocator)
    collect_run_ys(root, &ys)
    testing.expectf(t, len(ys) == 1, "fora de <pre> segue achatado em 1 run; vieram %d", len(ys))
}

@(test)
test_code_inline_puro_continua_na_mesma_linha :: proc(t: ^testing.T) {
    // CONTROLE do teste acima: sem filho de bloco, `<code>` continua inline e o
    // parágrafo inteiro é UM run. Sem esta guarda, um fix que quebrasse todo
    // elemento inline em bloco passaria pelo teste anterior.
    root := layout_from_html("<html><body><p>antes <code>x()</code> depois</p></body></html>")
    ys := make([dynamic]f32, context.temp_allocator)
    collect_run_ys(root, &ys)
    testing.expectf(t, len(ys) == 1, "<code> sem bloco dentro fica no MESMO run; vieram %d caixas", len(ys))
}

@(test)
test_abspos_icado_nao_desce_a_cada_relayout :: proc(t: ^testing.T) {
    // A calha de números do bloco de código (`.line::before{position:absolute;left:0}`
    // + `code{position:relative}`) saía UMA LINHA abaixo do seu texto. A posição
    // estática estava certa no 1º passe — o `--dumplayout`, que faz UM passe só,
    // acertava; quem errava era o `--render`, que refaz o layout POR FRAME.
    // Causa: `layout_absolutes` IÇA a caixa p/ os filhos do bloco contenedor, logo
    // após o âncora; no passe seguinte o laço de fluxo relê a estática já na
    // posição nova, onde o cursor JÁ passou pelo âncora. Este teste roda o layout
    // DUAS vezes e exige que o absoluto não se mova — é o invariante que faltava.
    css := "code{position:relative} span{display:block} span:before{content:'#';position:absolute;left:0}"
    html := "<html><body><pre><code>" +
        "<span>alfa</span><span>beta</span><span>gama</span></code></pre></body></html>"
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    page := Rect{0, 0, 800, 600}

    layout_box(root, 0, 0, 800)
    layout_absolutes(root, page, page)
    ab := first_absolute(root)
    testing.expect(t, ab != nil, "existe caixa absoluta (o ::before)")
    if ab == nil do return
    y1 := ab.y

    layout_box(root, 0, 0, 800) // 2º passe = o próximo frame do --render
    layout_absolutes(root, page, page)
    y2 := first_absolute(root).y
    testing.expectf(t, y1 == y2,
        "relayout NAO pode mover o absoluto icado: 1o passe y=%.1f, 2o passe y=%.1f", y1, y2)
}

// ── float ────────────────────────────────────────────────────────────────────

// Num pai com um float:left, o irmão de bloco seguinte começa À DIREITA do float.
@(private="file")
float_shifts_sibling :: proc(b: ^Box) -> bool {
    if b == nil do return false
    fl_right: f32 = -1
    for c in b.children {
        if c.float == .Left do fl_right = c.x + c.w
        else if fl_right >= 0 && c.pos == .Static && c.float == .None && c.x >= fl_right - 1 do return true
    }
    for c in b.children do if float_shifts_sibling(c) do return true
    return false
}

@(test)
test_float_left_desloca_irmao :: proc(t: ^testing.T) {
    root := layout_from_html("<html><body><div>" +
        "<div style='float:left;width:100px;height:50px'>f</div>" +
        "<div style='height:30px'>ao lado</div>" +
        "</div></body></html>")
    testing.expect(t, float_shifts_sibling(root), "irmao do float:left comeca a direita dele")
}

// Regressão books.toscrape: width:% de floats consecutivos deve resolver contra
// o CONTAINER (larguras iguais), não o espaço restante (encolheria); e o 3º
// float (que não cabe) quebra p/ a linha de baixo.
@(private="file")
floats_iguais_e_quebram :: proc(b: ^Box) -> bool {
    if b == nil do return false
    n := 0
    w0, ymin, ymax: f32 = -1, 1e9, -1e9
    equal := true
    for c in b.children {
        if c.float == .Left {
            n += 1
            if w0 < 0 { w0 = c.w } else if (c.w - w0 > 2 || w0 - c.w > 2) { equal = false }
            if c.y < ymin do ymin = c.y
            if c.y > ymax do ymax = c.y
        }
    }
    if n >= 3 && equal && ymax > ymin + 1 do return true
    for c in b.children do if floats_iguais_e_quebram(c) do return true
    return false
}

@(test)
test_float_percent_largura_e_quebra :: proc(t: ^testing.T) {
    // 3 floats de 50% num container de 400px: cada um ~200 (não 200/100/50),
    // e o 3º cai na 2ª linha.
    root := layout_from_html("<html><body><div style='width:400px'>" +
        "<div style='float:left;width:50%;height:20px'>a</div>" +
        "<div style='float:left;width:50%;height:20px'>b</div>" +
        "<div style='float:left;width:50%;height:20px'>c</div>" +
        "</div></body></html>")
    testing.expect(t, floats_iguais_e_quebram(root), "floats % iguais e 3º quebra p/ 2ª linha")
}

@(test)
test_clear_desce_abaixo :: proc(t: ^testing.T) {
    // o clear:both deve ficar ABAIXO da base do float (y >= float.y + float.h)
    root := layout_from_html("<html><body><div>" +
        "<div style='float:left;width:80px;height:120px'>f</div>" +
        "<div style='clear:both;height:20px'>depois</div>" +
        "</div></body></html>")
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        fbottom: f32 = -1
        for c in b.children {
            if c.float == .Left do fbottom = c.y + c.h
            else if c.clear == .Both && fbottom >= 0 && c.y >= fbottom - 1 do return true
        }
        return false
    })
    testing.expect(t, ok, "clear:both desce abaixo do float")
}

// Regressão books.toscrape: uma imagem com vertical-align:middle SOZINHA na
// linha não pode subir p/ y negativo (o bug cortava o topo da imagem). Deve
// centrar na caixa-linha (y >= 0 quando é o único item).
@(test)
test_valign_middle_img_nao_sobe :: proc(t: ^testing.T) {
    root := layout_from_html("<html><body><p><img style='vertical-align:middle' src='x.png'></p></body></html>")
    found_mid, ok := false, true
    check :: proc(b: ^Box, found_mid, ok: ^bool) {
        if b == nil do return
        for &it in b.inlines {
            if it.kind == .Image && it.valign == .Middle {
                found_mid^ = true
                if it.y < -0.5 do ok^ = false // não pode estar acima da linha
            }
        }
        for c in b.children do check(c, found_mid, ok)
    }
    check(root, &found_mid, &ok)
    testing.expect(t, found_mid, "achou a imagem vertical-align:middle")
    testing.expect(t, ok, "imagem middle sozinha NÃO sobe p/ y negativo (topo cortado)")
}

// ── flex aninhado: largura intrínseca é a SOMA (regressão famososbr nav) ─────

@(test)
test_flex_row_aninhado_soma_largura :: proc(t: ^testing.T) {
    // Uma navbar flex (ul) dentro de outro flex (nav space-between). O flex
    // externo precisa medir a ul pela SOMA dos itens, não o máximo — senão a ul
    // encolhe, os itens se sobrepõem e o único item com espaço ("Em Alta") quebra.
    html := `<nav style="display:flex;justify-content:space-between">
      <div class="logo">LOGO</div>
      <ul style="display:flex;gap:40px;list-style:none">
        <li><a href="#">Inicio</a></li>
        <li><a href="#">Aniversarios</a></li>
        <li><a href="#">Em Alta</a></li>
        <li><a href="#">Jogos</a></li>
        <li><a href="#">Sobre</a></li>
      </ul>
      <div class="search">busca</div>
    </nav>`
    root := layout_from_html(html, 1900, 200)
    defer free_layout(root)

    // "Em Alta" (único item com espaço) NÃO pode quebrar: "Em" e "Alta" na mesma
    // linha => mesmo y. Se a ul tivesse encolhido, "Alta" iria p/ a linha de baixo.
    em, ok1   := find_word_item(root, "Em")
    alta, ok2 := find_word_item(root, "Alta")
    testing.expect(t, ok1 && ok2, "achou 'Em' e 'Alta'")
    // esta expectativa também cobre o WRAP_EPS: a li "Em Alta" é dimensionada ao
    // seu max-content exato; sem a folga sub-pixel, o arredondamento f32 quebraria
    // a linha (em.y != alta.y).
    testing.expect(t, abs(em.y - alta.y) < 0.5, "'Em Alta' fica numa linha só (ul não encolheu + WRAP_EPS)")
    testing.expect(t, alta.x > em.x, "'Alta' vem depois de 'Em' na mesma linha")
}

@(test)
test_aspect_ratio_deriva_altura :: proc(t: ^testing.T) {
    // width:200 + aspect-ratio:2/1 => altura de conteúdo = 100
    html := `<div id="a" style="width:200px;aspect-ratio:2/1"></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil, "achou a")
    testing.expect(t, abs(a.h - 100) < 0.5, "altura = largura/razão (200/2 = 100)")
}

@(test)
test_aspect_ratio_numero_unico :: proc(t: ^testing.T) {
    // aspect-ratio:1 (quadrado) com width:150 => altura 150
    html := `<div id="a" style="width:150px;aspect-ratio:1"></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil && abs(a.h - 150) < 0.5, "razão 1 = quadrado (150x150)")
}

@(test)
test_aspect_ratio_height_explicita_vence :: proc(t: ^testing.T) {
    // height explícita tem prioridade sobre a razão
    html := `<div id="a" style="width:200px;height:40px;aspect-ratio:2/1"></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil && abs(a.h - 40) < 0.5, "height:40 vence a razão (que daria 100)")
}

@(test)
test_height_pct_contra_altura_explicita :: proc(t: ^testing.T) {
    html := `<div id="p" style="width:100px;height:200px"><div id="c" style="height:100%;width:50px"></div></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    c := find_box_by_id(root, "c")
    testing.expect(t, c != nil && abs(c.h - 200) < 0.5, "height:100% resolve contra os 200px do pai")
}

@(test)
test_height_pct_contra_aspect_ratio :: proc(t: ^testing.T) {
    // caso da galeria famososbr: pai aspect-square (altura via razão) + filho h-full.
    html := `<div id="p" style="width:150px;aspect-ratio:1"><div id="c" style="height:100%;width:100%"></div></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    c := find_box_by_id(root, "c")
    testing.expect(t, c != nil && abs(c.h - 150) < 0.5, "h-full preenche o quadrado derivado do aspect-ratio")
}

@(test)
test_height_pct_pai_auto_nao_resolve :: proc(t: ^testing.T) {
    // pai com altura AUTO: height:% do filho NÃO resolve (vira auto), como no CSS real.
    html := `<div id="p" style="width:100px"><div id="c" style="height:100%;width:50px"></div></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    c := find_box_by_id(root, "c")
    testing.expect(t, c != nil && c.h < 5, "sem altura definida no pai, height:100% vira ~0 (auto)")
}

@(test)
test_gap_calc_nao_quebra :: proc(t: ^testing.T) {
    // regressão: `gap: calc(...)` tem espaços INTERNOS; o split por espaço quebrava
    // o valor em 3 tokens e o gap virava 0. split_top_level respeita os parênteses.
    html := `<div id="f" style="display:flex;gap:calc(4px * 4)"><div id="c1" style="width:10px;height:10px"></div><div id="c2" style="width:10px;height:10px"></div></div>`
    root := layout_from_html(html, 800, 600)
    defer free_layout(root)
    c1 := find_box_by_id(root, "c1"); c2 := find_box_by_id(root, "c2")
    testing.expect(t, c1 != nil && c2 != nil, "achou os filhos")
    testing.expect(t, abs((c2.x - (c1.x + c1.w)) - 16) < 1.0, "gap calc(4px*4) = 16px entre os itens")
}

// Os steppers passaram a receber a `Transition` inteira (M223). Aqui usamos a
// curva LINEAR de propósito: com ela "meio do tempo = meio do valor" é verdade
// por definição, então o teste mede o RELÓGIO, não a curva (que tem testes
// próprios em transition_test.odin).
@(private = "file")
tr_lin :: proc(dur: f32, delay: f32 = 0) -> Transition {
    return Transition{dur = dur, delay = delay, timing = Timing{kind = .Linear}, on = dur > 0}
}

@(test)
test_transition_scalar :: proc(t: ^testing.T) {
    ch: Trans_FChan
    // init: assume o alvo instantaneamente (sem flash)
    v := test_trans_step_f(&ch, 0, tr_lin(0.1), 0, true)
    testing.expect(t, abs(v - 0) < 0.001 && abs(ch.prog - 1) < 0.001, "init snapa ao alvo, prog=1")
    // alvo muda p/ 1, dur 0.1s, meio passo (dt=0.05 → prog 0.5)
    v = test_trans_step_f(&ch, 1, tr_lin(0.1), 0.05, false)
    testing.expect(t, abs(v - 0.5) < 0.02, "meio da transição ≈ 0.5 (linear)")
    // completa
    v = test_trans_step_f(&ch, 1, tr_lin(0.1), 0.05, false)
    testing.expect(t, abs(v - 1) < 0.001, "transição completa chega a 1")
}

@(test)
test_transition_reversao :: proc(t: ^testing.T) {
    ch: Trans_FChan
    test_trans_step_f(&ch, 0, tr_lin(0.2), 0, true) // settle em 0
    // sobe até ~metade
    mid := test_trans_step_f(&ch, 1, tr_lin(0.2), 0.1, false)
    testing.expect(t, mid > 0.1 && mid < 0.9, "no meio do caminho")
    // inverte o alvo p/ 0 no meio → snapshota o valor atual como start, anima de volta
    back := test_trans_step_f(&ch, 0, tr_lin(0.2), 0.1, false)
    testing.expect(t, back < mid, "reversão: volta a descer a partir do valor atual")
}

@(test)
test_transition_cor :: proc(t: ^testing.T) {
    ch: Trans_CChan
    c := test_trans_step_c(&ch, 0xff0000, tr_lin(0.1), 0, true)
    testing.expect_value(t, c, u32(0xff0000)) // init snapa
    // passo completo p/ azul (dt=dur)
    c = test_trans_step_c(&ch, 0x0000ff, tr_lin(0.1), 0.1, false)
    testing.expect_value(t, c, u32(0x0000ff))
}

@(test)
test_transition_instantanea_dur_zero :: proc(t: ^testing.T) {
    ch: Trans_FChan
    test_trans_step_f(&ch, 0, tr_lin(0), 0, true)
    v := test_trans_step_f(&ch, 1, tr_lin(0), 0.016, false) // dur=0 → instantâneo
    testing.expect(t, abs(v - 1) < 0.001, "dur=0 chega ao alvo no mesmo frame")
}

@(test)
test_multicol_balanceia :: proc(t: ^testing.T) {
    // 4 blocos de altura 40 em 2 colunas → col0: a,b ; col1: c,d (balanceado)
    html := `<div style="column-count:2;width:300px">
        <div id="a" style="height:40px"></div>
        <div id="b" style="height:40px"></div>
        <div id="c" style="height:40px"></div>
        <div id="d" style="height:40px"></div>
    </div>`
    root := layout_from_html(html, 600, 400)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    c := find_box_by_id(root, "c"); d := find_box_by_id(root, "d")
    testing.expect(t, a != nil && b != nil && c != nil && d != nil, "achou os 4 blocos")
    testing.expect(t, abs(a.x - b.x) < 1, "a e b na mesma coluna")
    testing.expect(t, c.x > a.x + 1, "c começa na 2ª coluna (à direita)")
    testing.expect(t, abs(c.x - d.x) < 1, "c e d na mesma coluna")
    testing.expect(t, abs(a.y - c.y) < 1, "a e c no topo de cada coluna (mesmo y)")
    testing.expect(t, b.y > a.y + 1, "b abaixo de a na 1ª coluna")
    // largura da coluna ≈ (300 - gap)/2, bem menor que 300
    testing.expect(t, a.w < 170, "coluna estreita (~metade da largura menos o gap)")
}

@(test)
test_multicol_width :: proc(t: ^testing.T) {
    // column-width:120 num container de 400 → cabem ~3 colunas
    html := `<div style="column-width:120px;column-gap:20px;width:400px">
        <div id="a" style="height:30px"></div>
        <div id="b" style="height:30px"></div>
        <div id="c" style="height:30px"></div>
    </div>`
    root := layout_from_html(html, 600, 400)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b"); c := find_box_by_id(root, "c")
    // 3 blocos / 3 colunas → um por coluna, todos no topo
    testing.expect(t, a != nil && b != nil && c != nil, "achou os blocos")
    testing.expect(t, b.x > a.x + 1 && c.x > b.x + 1, "3 colunas: a<b<c em x")
    testing.expect(t, abs(a.y - b.y) < 1 && abs(b.y - c.y) < 1, "todos no topo")
}

@(test)
test_grid_stretch_auto_vs_intrinseca :: proc(t: ^testing.T) {
    // item de altura AUTO estica p/ a célula (100)
    root := layout_from_html(
        `<div style="display:grid;width:100px;height:100px;grid-template:100%/100%"><div id="a"></div></div>`, 400, 400)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil && abs(a.h - 100) < 1, "item de altura auto estica p/ a célula (100)")
    free_layout(root)
    // height:max-content NÃO é auto → não estica (fica na altura natural ~0)
    root2 := layout_from_html(
        `<div style="display:grid;width:100px;height:100px;grid-template:100%/100%"><div id="b" style="height:max-content"></div></div>`, 400, 400)
    b := find_box_by_id(root2, "b")
    testing.expect(t, b != nil && b.h < 50, "height:max-content NÃO estica no grid (altura intrínseca)")
    free_layout(root2)
}

@(test)
test_display_contents :: proc(t: ^testing.T) {
    // o wrapper display:contents não gera caixa; seus filhos sobem ao pai
    html := `<div id="c">
        <div id="w" style="display:contents">
            <div id="a" style="height:20px"></div>
            <div id="b" style="height:20px"></div>
        </div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    c := find_box_by_id(root, "c"); w := find_box_by_id(root, "w")
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, c != nil && a != nil && b != nil, "achou c, a, b")
    testing.expect(t, w == nil, "wrapper display:contents NÃO gera caixa")
    found_a, found_b := false, false
    for ch in c.children {
        if ch == a do found_a = true
        if ch == b do found_b = true
    }
    testing.expect(t, found_a && found_b, "filhos do wrapper viram filhos DIRETOS de c")
    testing.expect(t, b.y > a.y + 0.5, "a e b empilham em c (fluxo de bloco normal)")
}

@(test)
test_display_contents_flex :: proc(t: ^testing.T) {
    // caso #1 real: wrapper contents num flex → filhos viram itens flex
    html := `<div style="display:flex;width:300px">
        <div style="display:contents">
            <div id="a" style="flex:1;height:20px"></div>
            <div id="b" style="flex:1;height:20px"></div>
        </div>
    </div>`
    root := layout_from_html(html, 600, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou os itens")
    testing.expect(t, abs(a.w - 150) < 1 && abs(b.w - 150) < 1, "viram itens flex (150 cada)")
    testing.expect(t, b.x > a.x + 0.5, "lado a lado no eixo flex")
}

@(test)
test_display_table_css :: proc(t: ^testing.T) {
    // display:table/table-row/table-cell em <div>s (sem tags de tabela) deve
    // alinhar as células em colunas, como uma tabela HTML.
    // larguras explícitas nas células (o harness de teste não tem atlas de fonte,
    // então texto mede 0; larguras fixas exercitam o algoritmo de coluna).
    html := `<div style="display:table;width:300px">
        <div style="display:table-row">
            <div id="a" style="display:table-cell;width:100px;height:20px"></div>
            <div id="b" style="display:table-cell;width:100px;height:20px"></div>
        </div>
        <div style="display:table-row">
            <div id="c" style="display:table-cell;width:100px;height:20px"></div>
            <div id="d" style="display:table-cell;width:100px;height:20px"></div>
        </div>
    </div>`
    root := layout_from_html(html, 800, 400)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    c := find_box_by_id(root, "c"); d := find_box_by_id(root, "d")
    testing.expect(t, a != nil && b != nil && c != nil && d != nil, "achou as 4 células")
    // mesma coluna → mesmo x; célula à direita começa depois
    testing.expect(t, abs(a.x - c.x) < 0.5, "coluna 1: a e c alinhadas em x")
    testing.expect(t, abs(b.x - d.x) < 0.5, "coluna 2: b e d alinhadas em x")
    testing.expect(t, b.x > a.x + 0.5, "célula 2 fica à direita da 1")
    // mesma linha → mesmo y; linha 2 fica abaixo
    testing.expect(t, abs(a.y - b.y) < 0.5, "linha 1: a e b no mesmo y")
    testing.expect(t, c.y > a.y + 0.5, "linha 2 fica abaixo da linha 1")
}

@(test)
test_display_table_cells_anonimas :: proc(t: ^testing.T) {
    // células soltas direto no display:table → linha anônima (as duas na mesma linha)
    html := `<div style="display:table;width:200px">
        <div id="a" style="display:table-cell;width:60px;height:20px"></div>
        <div id="b" style="display:table-cell;width:60px;height:20px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou as células")
    testing.expect(t, abs(a.y - b.y) < 0.5, "linha anônima: mesmo y")
    testing.expect(t, b.x > a.x + 0.5, "b à direita de a na mesma linha")
}

@(test)
test_inline_margin_horizontal :: proc(t: ^testing.T) {
    // margin-right num <a> inline empurra o conteúdo seguinte (nav a{margin-right})
    root := layout_from_html(`<p><a href="/a" style="margin-right:20px">um</a><a href="/b">dois</a></p>`, 600, 200)
    defer free_layout(root)
    w1, ok1 := find_word_item(root, "um")
    w2, ok2 := find_word_item(root, "dois")
    testing.expect(t, ok1 && ok2, "achou as duas palavras")
    testing.expect(t, abs(w1.pad_after - 20) < 0.5, "pad_after do último item do 1º link = 20 (margin-right)")
    testing.expect(t, w2.x - w1.x >= 19.5, "'dois' começa ~20px depois (margem aplicada)")
}

@(test)
test_inline_padding_esquerda :: proc(t: ^testing.T) {
    // padding-left num inline vira pad_before no 1º item
    root := layout_from_html(`<p>a<span style="padding-left:12px">b</span></p>`, 400, 200)
    defer free_layout(root)
    w, ok := find_word_item(root, "b")
    testing.expect(t, ok && abs(w.pad_before - 12) < 0.5, "padding-left do span = pad_before do 1º item")
}

@(test)
test_coalesce_words_adjacentes :: proc(t: ^testing.T) {
    // foo<span>bar</span>baz (mesmo estilo, sem espaço) → UMA palavra "foobarbaz".
    // Reproduz uma única caixa decoradora e um único AddText (sem desvio sub-pixel).
    root := layout_from_html(`<p>foo<span>bar</span>baz</p>`, 400, 200)
    defer free_layout(root)
    _, merged := find_word_item(root, "foobarbaz")
    testing.expect(t, merged, "words adjacentes de mesmo estilo fundem num só")
    _, sep := find_word_item(root, "bar")
    testing.expect(t, !sep, "não sobra 'bar' isolado após a fusão")
}

@(test)
test_coalesce_nao_funde_estilo_diferente :: proc(t: ^testing.T) {
    // span com COR diferente NÃO funde (deco/estilo distintos ficam separados).
    root := layout_from_html(`<p>foo<span style="color:red">bar</span>baz</p>`, 400, 200)
    defer free_layout(root)
    _, hasbar := find_word_item(root, "bar")
    testing.expect(t, hasbar, "'bar' com cor diferente permanece palavra própria")
    _, nomerge := find_word_item(root, "foobarbaz")
    testing.expect(t, !nomerge, "estilos diferentes não fundem")
}

@(test)
test_link_estilo_padrao :: proc(t: ^testing.T) {
    // link sem estilo: azul de link (UA) + sublinhado
    root := layout_from_html(`<p>veja <a href="/x">aqui</a> agora</p>`, 400, 200)
    defer free_layout(root)
    w, ok := find_word_item(root, "aqui")
    testing.expect(t, ok, "achou a palavra do link")
    testing.expect(t, w.deco.underline, "link sem estilo é sublinhado (UA-stylesheet)")
    testing.expect_value(t, w.color, u32(COL_LINK))
    testing.expect(t, w.href != "", "palavra do link é clicável")
    // texto vizinho NÃO é sublinhado nem azul
    v, _ := find_word_item(root, "veja")
    testing.expect(t, !v.deco.underline, "texto normal não é sublinhado")
    testing.expect(t, v.color != COL_LINK, "texto normal não é azul de link")
}

@(test)
test_link_estilo_autor_vence :: proc(t: ^testing.T) {
    // autor define color no link → vence o azul default
    r1 := layout_from_html(`<p><a href="/x" style="color:#ff0000">aqui</a></p>`, 400, 200)
    defer free_layout(r1)
    w1, _ := find_word_item(r1, "aqui")
    testing.expect_value(t, w1.color, u32(0xff0000))
    // autor define text-decoration:none → sem sublinhado
    r2 := layout_from_html(`<p><a href="/x" style="text-decoration:none">aqui</a></p>`, 400, 200)
    defer free_layout(r2)
    w2, _ := find_word_item(r2, "aqui")
    testing.expect(t, !w2.deco.underline, "text-decoration:none remove o sublinhado do link")
}

// Primeira caixa cujo nó DOM tem id=want (busca em pré-ordem).
@(private="file")
find_box_by_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if id, ok := b.node.attrs["id"]; ok && id == want do return b
    }
    for c in b.children {
        if r := find_box_by_id(c, want); r != nil do return r
    }
    return nil
}

// ── flex: min/max-width em itens (algoritmo de flexible lengths) ─────────────

@(test)
test_flex_min_width_trava_grow :: proc(t: ^testing.T) {
    // container 200px, dois itens flex:1 (dariam 100 cada), mas 'a' tem min-width:150
    // => 'a' congela em 150, 'b' fica com o resto (50).
    html := `<div style="display:flex;width:200px">
        <div id="a" style="flex:1;min-width:150px"></div>
        <div id="b" style="flex:1"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.w - 150) < 0.5, "a respeita min-width:150")
    testing.expect(t, abs(b.w - 50) < 0.5, "b recebe o restante (50)")
}

@(test)
test_flex_max_width_trava_grow :: proc(t: ^testing.T) {
    // container 400px, dois itens flex:1 (dariam 200 cada), 'a' tem max-width:120
    // => 'a' congela em 120, 'b' fica com 280.
    html := `<div style="display:flex;width:400px">
        <div id="a" style="flex:1;max-width:120px"></div>
        <div id="b" style="flex:1"></div>
    </div>`
    root := layout_from_html(html, 800, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.w - 120) < 0.5, "a respeita max-width:120")
    testing.expect(t, abs(b.w - 280) < 0.5, "b recebe o restante (280)")
}

@(test)
test_flex_min_width_trava_shrink :: proc(t: ^testing.T) {
    // container 100px, dois itens width:100 encolhíveis (dariam 50 cada), 'a' tem
    // min-width:80 => 'a' congela em 80, 'b' encolhe p/ 20.
    html := `<div style="display:flex;width:100px">
        <div id="a" style="width:100px;min-width:80px"></div>
        <div id="b" style="width:100px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.w - 80) < 0.5, "a não encolhe abaixo de min-width:80")
    testing.expect(t, abs(b.w - 20) < 0.5, "b absorve o resto do encolhimento (20)")
}

// ── flex: order e row-reverse ───────────────────────────────────────────────

@(test)
test_flex_order :: proc(t: ^testing.T) {
    // 'a' aparece primeiro no DOM mas order:2; 'b' order:1 => b fica à esquerda de a
    html := `<div style="display:flex;width:300px">
        <div id="a" style="width:100px;order:2"></div>
        <div id="b" style="width:100px;order:1"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, b.x < a.x, "order:1 (b) posiciona antes de order:2 (a)")
}

@(test)
test_flex_row_reverse :: proc(t: ^testing.T) {
    // row-reverse inverte a ordem visual: 'a' (1º no DOM) vai p/ a direita de 'b'
    html := `<div style="display:flex;flex-direction:row-reverse;width:300px">
        <div id="a" style="width:100px"></div>
        <div id="b" style="width:100px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, a.x > b.x, "row-reverse: a (primeiro no DOM) fica à direita de b")
}

@(test)
test_flex_margin_left_auto_empurra :: proc(t: ^testing.T) {
    // padrão navbar: c tem margin-left:auto e vai para a extremidade direita,
    // enquanto a e b ficam à esquerda. container 300, itens de 50.
    html := `<div style="display:flex;width:300px">
        <div id="a" style="width:50px"></div>
        <div id="b" style="width:50px"></div>
        <div id="c" style="width:50px;margin-left:auto"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b"); c := find_box_by_id(root, "c")
    testing.expect(t, a != nil && b != nil && c != nil, "achou a, b e c")
    // coords relativas a `a` (o body implícito recua o conteúdo em 8px)
    testing.expect(t, abs(a.x - 8) < 0.5,          "a à esquerda (x=8, margem do body implícito)")
    testing.expect(t, abs(b.x - a.x - 50) < 0.5,   "b logo após a (+50)")
    testing.expect(t, abs(c.x - a.x - 250) < 0.5,  "margin-left:auto empurra c à direita (+250)")
}

// ── grid: colunas (comportamento existente) ─────────────────────────────────

@(test)
test_grid_cols_fr :: proc(t: ^testing.T) {
    // 1fr 2fr num container de 300 => colunas de 100 e 200
    html := `<div style="display:grid;grid-template-columns:1fr 2fr;width:300px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.w - 100) < 0.5, "coluna 1fr = 100")
    testing.expect(t, abs(b.w - 200) < 0.5, "coluna 2fr = 200")
    testing.expect(t, abs(b.x - a.x - 100) < 0.5, "b começa após a coluna de a")
}

@(test)
test_grid_col_gap :: proc(t: ^testing.T) {
    // duas colunas de 100 com gap 20 => b.x = a.x + 120
    html := `<div style="display:grid;grid-template-columns:100px 100px;gap:20px;width:300px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(b.x - a.x - 120) < 0.5, "gap de 20 entre colunas de 100")
}

// ── grid: linhas explícitas + posicionamento (novo) ─────────────────────────

@(test)
test_grid_template_rows :: proc(t: ^testing.T) {
    // 1 coluna, 2 linhas 50px/80px => dois itens empilhados com essas alturas
    html := `<div style="display:grid;grid-template-columns:100px;grid-template-rows:50px 80px;width:100px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 400, 300)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.h - 50) < 0.5, "linha 1 = 50px")
    testing.expect(t, abs(b.h - 80) < 0.5, "linha 2 = 80px")
    testing.expect(t, abs(b.y - a.y - 50) < 0.5, "b começa após a linha de 50")
}

@(test)
test_grid_column_explicito :: proc(t: ^testing.T) {
    // 3 colunas de 100; item com grid-column:2/4 começa na 2ª coluna e ocupa 2
    html := `<div id="g" style="display:grid;grid-template-columns:100px 100px 100px;width:300px">
        <div id="a" style="grid-column:2 / 4"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a")
    testing.expect(t, g != nil && a != nil, "achou g e a")
    testing.expect(t, abs(a.x - g.content_x - 100) < 0.5, "começa na 2ª coluna (content_x+100)")
    testing.expect(t, abs(a.w - 200) < 0.5, "ocupa 2 colunas (200)")
}

@(test)
test_grid_row_span :: proc(t: ^testing.T) {
    // linhas 40/40/40; item com grid-row:span 2 => altura ~80 (2 linhas)
    html := `<div style="display:grid;grid-template-columns:100px;grid-template-rows:40px 40px 40px;width:100px">
        <div id="a" style="grid-row:span 2"></div>
    </div>`
    root := layout_from_html(html, 400, 300)
    defer free_layout(root)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil, "achou a")
    testing.expect(t, abs(a.h - 80) < 0.5, "grid-row:span 2 => 2 linhas de 40 = 80")
}

@(test)
test_grid_placement_nao_sobrepoe :: proc(t: ^testing.T) {
    // 'a' fixado em grid-column:1; 'b' auto deve pular p/ a coluna 2 (não sobrepor)
    html := `<div style="display:grid;grid-template-columns:100px 100px;width:200px">
        <div id="a" style="grid-column:1"></div>
        <div id="b"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.y - b.y) < 0.5, "a e b na mesma linha")
    testing.expect(t, b.x > a.x + 50, "b foi para a 2ª coluna (não sobrepôs a)")
}

// ── flex: altura esticada propaga a filhos flex/grid aninhados ───────────────

@(test)
test_flex_nested_column_stretch_height :: proc(t: ^testing.T) {
    // container row de 120px; a coluna aninhada (sem height própria) é esticada
    // por align-items:stretch e deve repassar os 120px aos 2 filhos flex:1 (60 cada).
    html := `<div style="display:flex;height:120px;width:300px">
        <div style="width:100px;display:flex;flex-direction:column">
            <div id="a" style="flex:1"></div>
            <div id="b" style="flex:1"></div>
        </div>
        <div id="main" style="flex:1"></div>
    </div>`
    root := layout_from_html(html, 400, 300)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.h - 60) < 0.5, "filho flex:1 da coluna esticada = 60 (metade de 120)")
    testing.expect(t, abs(b.h - 60) < 0.5, "2º filho flex:1 = 60")
    testing.expect(t, b.y > a.y + 50, "b empilhado abaixo de a")
}

@(test)
test_grid_nested_stretch_fr_rows :: proc(t: ^testing.T) {
    // grid aninhado sem height própria, esticado pelo pai (120px): as 2 linhas 1fr
    // devem dividir a altura recebida (60 cada), não colapsar.
    html := `<div style="display:flex;height:120px;width:200px">
        <div style="width:100px;display:grid;grid-template-rows:1fr 1fr">
            <div id="a"></div>
            <div id="b"></div>
        </div>
    </div>`
    root := layout_from_html(html, 400, 300)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.h - 60) < 0.5, "linha 1fr do grid esticado = 60")
    testing.expect(t, abs(b.h - 60) < 0.5, "linha 2 1fr = 60")
}

// ── flex-direction: row-reverse empacota no fim (direita) ────────────────────

@(test)
test_flex_row_reverse_packs_right :: proc(t: ^testing.T) {
    // row-reverse: main-start vira a direita; com justify padrão (start) os itens
    // grudam à DIREITA e a ordem visual inverte (o 1º do DOM fica mais à direita).
    html := `<div id="cont" style="display:flex;flex-direction:row-reverse;width:300px">
        <div id="a" style="width:50px;height:20px"></div>
        <div id="b" style="width:50px;height:20px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    root_div := find_box_by_id(root, "cont") // container flex (sob html>body implícito)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    right_edge := root_div.content_x + root_div.content_w
    testing.expect(t, abs((a.x + a.w) - right_edge) < 0.5, "a (1º no DOM) encosta na borda direita")
    testing.expect(t, b.x < a.x, "b fica à esquerda de a (ordem invertida)")
}

// ── grid-template-areas ────────────────────────────────────────────────────

@(test)
test_grid_template_areas_basic :: proc(t: ^testing.T) {
    // 3 colunas x 2 linhas; header ocupa toda a 1ª linha, sidebar e content na 2ª
    html := `<div style="display:grid;grid-template-columns:100px 100px 100px;grid-template-rows:40px 40px;grid-template-areas:'header header header' 'sidebar content content';width:300px">
        <div id="h" style="grid-area:header"></div>
        <div id="s" style="grid-area:sidebar"></div>
        <div id="c" style="grid-area:content"></div>
    </div>`
    root := layout_from_html(html, 400, 400)
    defer free_layout(root)
    h := find_box_by_id(root, "h")
    s := find_box_by_id(root, "s")
    c := find_box_by_id(root, "c")
    testing.expect(t, h != nil && s != nil && c != nil, "achou h, s e c")
    testing.expect(t, abs(h.w - 300) < 0.5, "header ocupa 3 colunas (300)")
    testing.expect(t, abs(s.w - 100) < 0.5, "sidebar ocupa 1 coluna (100)")
    testing.expect(t, abs(c.w - 200) < 0.5, "content ocupa 2 colunas (200)")
    testing.expect(t, s.y > h.y, "sidebar abaixo do header")
    testing.expect(t, abs(s.y - c.y) < 0.5, "sidebar e content na mesma linha")
}

@(test)
test_grid_areas_implicit_tracks :: proc(t: ^testing.T) {
    // grid-template-areas sem grid-template-columns: infere 2 colunas Auto.
    // Colunas `auto` são dimensionadas pelo CONTEÚDO (não dividem igual — isso é
    // 1fr), então cada coluna encolhe à largura do seu item.
    html := `<div style="display:grid;grid-template-areas:'a b';width:200px">
        <div id="a" style="grid-area:a;width:60px"></div>
        <div id="b" style="grid-area:b;width:40px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, a != nil && b != nil, "achou a e b")
    testing.expect(t, abs(a.w - 60) < 0.5, "coluna auto = conteúdo (60)")
    testing.expect(t, abs(b.w - 40) < 0.5, "coluna auto = conteúdo (40)")
    testing.expect(t, abs(b.x - a.x - 60) < 0.5, "b começa após a coluna a (+60)")
    testing.expect(t, abs(a.y - b.y) < 0.5, "mesma linha")
}

@(test)
test_grid_areas_dot_empty :: proc(t: ^testing.T) {
    // '.' = célula vazia; b fica na 2ª coluna
    html := `<div id="g" style="display:grid;grid-template-columns:100px 100px;grid-template-areas:'. b';width:200px">
        <div id="b" style="grid-area:b"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    grid := find_box_by_id(root, "g") // container (sob html>body implícito)
    b := find_box_by_id(root, "b")
    testing.expect(t, b != nil, "achou b")
    testing.expect(t, abs(b.w - 100) < 0.5, "b ocupa 1 coluna (100)")
    // b começa na 2ª coluna (offset 100)
    if grid != nil {
        testing.expect(t, abs(b.x - grid.content_x - 100) < 0.5, "b na 2ª coluna (x = content_x+100)")
    }
}

@(test)
test_grid_areas_multirow_span :: proc(t: ^testing.T) {
    // sidebar ocupa 2 linhas
    html := `<div style="display:grid;grid-template-columns:100px 200px;grid-template-rows:50px 50px;grid-template-areas:'side main' 'side footer';width:300px">
        <div id="side" style="grid-area:side"></div>
        <div id="main" style="grid-area:main"></div>
        <div id="foot" style="grid-area:footer"></div>
    </div>`
    root := layout_from_html(html, 400, 300)
    defer free_layout(root)
    side := find_box_by_id(root, "side")
    main := find_box_by_id(root, "main")
    foot := find_box_by_id(root, "foot")
    testing.expect(t, side != nil && main != nil && foot != nil, "achou side, main e foot")
    testing.expect(t, abs(side.w - 100) < 0.5, "side = 1 coluna (100)")
    testing.expect(t, abs(side.h - 100) < 0.5, "side = 2 linhas (100)")
    testing.expect(t, abs(main.w - 200) < 0.5, "main = 1 coluna (200)")
    testing.expect(t, abs(foot.w - 200) < 0.5, "footer = 1 coluna (200)")
    testing.expect(t, foot.y > main.y, "footer abaixo do main")
}

// ── grid-template shorthand ────────────────────────────────────────────────

@(test)
test_grid_template_shorthand_layout :: proc(t: ^testing.T) {
    // grid-template: "hd hd" 40px "sb ct" 60px / 100px 200px
    html := `<div style="display:grid;grid-template:'hd hd' 40px 'sb ct' 60px / 100px 200px;width:300px">
        <div id="hd" style="grid-area:hd"></div>
        <div id="sb" style="grid-area:sb"></div>
        <div id="ct" style="grid-area:ct"></div>
    </div>`
    root := layout_from_html(html, 400, 400)
    defer free_layout(root)
    hd := find_box_by_id(root, "hd")
    sb := find_box_by_id(root, "sb")
    ct := find_box_by_id(root, "ct")
    testing.expect(t, hd != nil && sb != nil && ct != nil, "achou hd, sb e ct")
    testing.expect(t, abs(hd.w - 300) < 0.5, "header 2 colunas (300)")
    testing.expect(t, abs(hd.h - 40)  < 0.5, "header linha 40px")
    testing.expect(t, abs(sb.w - 100) < 0.5, "sidebar 1 coluna (100)")
    testing.expect(t, abs(ct.w - 200) < 0.5, "content 1 coluna (200)")
    testing.expect(t, abs(sb.h - 60)  < 0.5, "sidebar linha 60px")
    testing.expect(t, sb.y > hd.y, "sidebar abaixo do header")
}

// ── flex align-content + grid justify-items/align-self ──────────────────────

@(test)
test_flex_align_content_center :: proc(t: ^testing.T) {
    // 4 itens de 100px num container de 220 (2 por linha) e altura 300; cada
    // linha ~40. align-content:center => o bloco de linhas centraliza no eixo Y.
    html := `<div style="display:flex;flex-wrap:wrap;width:220px;height:300px;align-content:center">
        <div id="a" style="width:100px;height:40px"></div>
        <div id="b" style="width:100px;height:40px"></div>
        <div id="c" style="width:100px;height:40px"></div>
        <div id="d" style="width:100px;height:40px"></div>
    </div>`
    root := layout_from_html(html, 400, 400)
    defer free_layout(root)
    g := find_box_by_id(root, "g")
    a := find_box_by_id(root, "a"); c := find_box_by_id(root, "c")
    testing.expect(t, a != nil && c != nil, "achou a e c")
    // duas linhas (a/b e c/d); com center devem estar deslocadas p/ baixo do topo.
    // topo do container = padding0. altura 300, 2 linhas de 40 + 0 gap = 80,
    // sobra 220, off = 110 => 1ª linha começa ~y=110.
    testing.expect(t, a.y > 90, "align-content:center empurra as linhas p/ o meio (a.y>90)")
    testing.expect(t, c.y > a.y + 30, "2ª linha (c) abaixo da 1ª (a)")
}

@(test)
test_grid_justify_items_start :: proc(t: ^testing.T) {
    // célula de 200px, item de 60px, justify-items:start => item NÃO estica (w~60)
    html := `<div style="display:grid;grid-template-columns:200px;justify-items:start;width:200px">
        <div id="a" style="width:60px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    a := find_box_by_id(root, "a")
    testing.expect(t, a != nil, "achou a")
    testing.expect(t, abs(a.w - 60) < 0.5, "justify-items:start => item mantém 60px (não estica p/ 200)")
}

@(test)
test_grid_justify_items_center :: proc(t: ^testing.T) {
    // item de 60 numa célula de 200, justify-items:center => x deslocado ~70
    html := `<div id="g" style="display:grid;grid-template-columns:200px;justify-items:center;width:200px">
        <div id="a" style="width:60px"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a")
    testing.expect(t, g != nil && a != nil, "achou g e a")
    testing.expect(t, abs(a.x - g.content_x - 70) < 1.0, "center: (200-60)/2 = 70 de offset")
}

@(test)
test_grid_justify_self_override :: proc(t: ^testing.T) {
    // container justify-items:start, mas o item pede justify-self:end
    html := `<div id="g" style="display:grid;grid-template-columns:200px;justify-items:start;width:200px">
        <div id="a" style="width:60px;justify-self:end"></div>
    </div>`
    root := layout_from_html(html, 400, 200)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a")
    testing.expect(t, g != nil && a != nil, "achou g e a")
    testing.expect(t, abs(a.x - g.content_x - 140) < 1.0, "justify-self:end vence justify-items:start (offset 140)")
}

// ── grid: justify-content / align-content (distribuem as trilhas) ───────────

@(test)
test_grid_justify_content_center :: proc(t: ^testing.T) {
    // 2 colunas de 100 num container de 400 => sobra 200; center desloca +100
    html := `<div id="g" style="display:grid;grid-template-columns:100px 100px;justify-content:center;width:400px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 500, 200)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, g != nil && a != nil && b != nil, "achou g, a, b")
    testing.expect(t, abs(a.x - g.content_x - 100) < 0.5, "center: grupo de colunas desloca +100")
    testing.expect(t, abs(b.x - a.x - 100) < 0.5, "b logo após a (colunas de 100)")
}

@(test)
test_grid_justify_content_between :: proc(t: ^testing.T) {
    // space-between: 1ª coluna na esquerda, 2ª encostada na direita
    html := `<div id="g" style="display:grid;grid-template-columns:100px 100px;justify-content:space-between;width:400px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 500, 200)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, g != nil && a != nil && b != nil, "achou g, a, b")
    testing.expect(t, abs(a.x - g.content_x) < 0.5, "a encostado à esquerda")
    testing.expect(t, abs(b.x - g.content_x - 300) < 0.5, "b encostado à direita (400-100)")
}

@(test)
test_grid_align_content_center :: proc(t: ^testing.T) {
    // 2 linhas de 50 num container de 300 de altura => sobra 200; center desloca +100
    html := `<div id="g" style="display:grid;grid-template-columns:100px;grid-template-rows:50px 50px;height:300px;align-content:center;width:100px">
        <div id="a"></div><div id="b"></div>
    </div>`
    root := layout_from_html(html, 400, 400)
    defer free_layout(root)
    g := find_box_by_id(root, "g"); a := find_box_by_id(root, "a"); b := find_box_by_id(root, "b")
    testing.expect(t, g != nil && a != nil && b != nil, "achou g, a, b")
    testing.expect(t, abs(a.y - g.content_y - 100) < 0.5, "center: linhas deslocam +100 na vertical")
    testing.expect(t, abs(b.y - a.y - 50) < 0.5, "b uma linha (50) abaixo de a")
}

// ── overflow: scroll (container rolável) ────────────────────────────────────

@(test)
test_overflow_scroll_max :: proc(t: ^testing.T) {
    // caixa 100px de altura com 200px de conteúdo => scroll_max ~100
    html := "<html><body><div style='height:100px;overflow-y:scroll'>" +
        "<div style='height:50px'>a</div><div style='height:50px'>b</div>" +
        "<div style='height:50px'>c</div><div style='height:50px'>d</div>" +
        "</div></body></html>"
    root := layout_from_html(html)
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        return b.overflow_scroll && b.scroll_max > 90 && b.scroll_max < 110
    })
    testing.expect(t, ok, "container rolável tem scroll_max ~100 (200 conteudo - 100 visivel)")
}

@(test)
test_overflow_scroll_sem_transbordo :: proc(t: ^testing.T) {
    // conteúdo cabe na caixa => scroll_max 0 (nada a rolar)
    html := "<html><body><div style='height:200px;overflow:scroll'>" +
        "<div style='height:50px'>a</div></div></body></html>"
    root := layout_from_html(html)
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        return b.overflow_scroll && b.scroll_max < 0.5
    })
    testing.expect(t, ok, "sem transbordo => scroll_max 0")
}

@(test)
test_opacity_explicita_propaga_ao_box :: proc(t: ^testing.T) {
    // opacity:0 no CSS deve, sim, chegar ao box (é intencional, não default)
    layout := build_from_html("<html><body><div style='opacity:0;background:red;width:50px;height:50px'>x</div></body></html>")
    found := walk_boxes(layout, proc(b: ^Box) -> bool {
        return b.has_bg && b.opacity == 0
    })
    testing.expect(t, found, "div com opacity:0 deve ter box.opacity == 0")
}

// ── display:inline-block ────────────────────────────────────────────────────────

@(private="file")
count_inline_boxes :: proc(b: ^Box) -> int {
    if b == nil do return 0
    c := 0
    for &it in b.inlines do if it.kind == .InlineBox && it.box != nil do c += 1
    for ch in b.children do c += count_inline_boxes(ch)
    return c
}

@(test)
test_inline_block_vira_caixa :: proc(t: ^testing.T) {
    // o <span> inline-block deve virar 1 InlineBox (caixa que flui), não texto
    root := build_from_html("<html><body><p>oi <span style='display:inline-block;background:#ff0000;padding:4px'>x</span> tchau</p></body></html>")
    testing.expect_value(t, count_inline_boxes(root), 1)
}

@(test)
test_inline_block_flui_na_linha :: proc(t: ^testing.T) {
    // texto e caixa inline-block na MESMA linha: com baseline-align eles têm y
    // DIFERENTES (a base da caixa na baseline do texto), mas se SOBREPÕEM verticalmente.
    root := layout_from_html("<html><body><p>oi <span style='display:inline-block;width:30px;height:20px;background:#00ff00'>x</span> fim</p></body></html>")
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        wy, wh, by, bh: f32 = -2, 0, -3, 0
        for &it in b.inlines {
            if it.kind == .Word && it.text == "oi" { wy = it.y; wh = it.h }
            if it.kind == .InlineBox { by = it.y; bh = it.h }
        }
        if wy < 0 || by < 0 do return false
        return wy < by + bh && by < wy + wh // faixas verticais se cruzam = mesma linha
    })
    testing.expect(t, ok, "texto e inline-block se sobrepoem (mesma linha)")
}

@(test)
test_inline_block_baseline :: proc(t: ^testing.T) {
    // baseline: a BASE da caixa inline-block (alta) fica >= a base do texto (baixo),
    // i.e. a caixa se estende p/ CIMA do texto (não top-aligned como antes).
    root := layout_from_html("<html><body><p>texto <span style='display:inline-block;width:20px;height:40px;background:#00f'>x</span></p></body></html>")
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        wy, by: f32 = -1, -1
        for &it in b.inlines {
            if it.kind == .Word && it.text == "texto" do wy = it.y
            if it.kind == .InlineBox do by = it.y
        }
        // caixa (40px) mais alta que a linha do texto => começa ACIMA do topo do texto
        return wy >= 0 && by >= 0 && by < wy
    })
    testing.expect(t, ok, "inline-block alto sobe acima do texto (baseline, nao top)")
}

@(test)
test_inline_block_shrink_to_fit :: proc(t: ^testing.T) {
    // sem width explícita, a caixa encolhe ao conteúdo — NÃO ocupa a linha toda (800)
    root := layout_from_html("<html><body><p><span style='display:inline-block;background:#00ff00;padding:5px'>x</span></p></body></html>")
    ok := walk_boxes(root, proc(b: ^Box) -> bool {
        for &it in b.inlines do if it.kind == .InlineBox && it.box != nil && it.box.w > 0 && it.box.w < 200 do return true
        return false
    })
    testing.expect(t, ok, "inline-block sem width encolhe ao conteudo (nao 800)")
}

// ── <button>: folha de estilo padrão do user-agent ──────────────────────────

// Primeira caixa cujo nó é um <button> (átomo inline-block) na subárvore.
@(private="file")
find_button_box :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil && it.box.node != nil && it.box.node.tag == "button" {
            return it.box
        }
    }
    for c in b.children do if r := find_button_box(c); r != nil do return r
    return nil
}

@(test)
test_button_vira_inline_box :: proc(t: ^testing.T) {
    // o <button> deve virar 1 InlineBox que flui na linha (não texto solto)
    root := build_from_html("<html><body><p>antes <button>Clique</button> depois</p></body></html>")
    defer free_layout(root)
    testing.expect_value(t, count_inline_boxes(root), 1)
    bb := find_button_box(root)
    testing.expect(t, bb != nil && has_word(bb, "Clique"), "rotulo do botao presente na caixa")
}

@(test)
test_button_estilo_padrao :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><button>Ok</button></body></html>")
    defer free_layout(root)
    bb := find_button_box(root)
    testing.expect(t, bb != nil, "achou a caixa do botao")
    testing.expect(t, bb.has_bg, "botao tem fundo padrao")
    testing.expect(t, bb.has_border, "botao tem borda padrao")
    testing.expect(t, bb.cursor == .Pointer, "botao usa cursor de ponteiro")
}

@(test)
test_button_shrink_to_fit :: proc(t: ^testing.T) {
    // encolhe ao rótulo + padding + borda — não ocupa a linha toda (800)
    root := layout_from_html("<html><body><button>Ok</button></body></html>")
    defer free_layout(root)
    bb := find_button_box(root)
    testing.expect(t, bb != nil && bb.w > 0 && bb.w < 200, "botao encolhe ao rotulo (nao 800)")
}

@(test)
test_button_css_sobrescreve :: proc(t: ^testing.T) {
    // a página pode sobrescrever o fundo padrão do UA
    root := build_from_html("<html><body><button style='background:#123456'>Ok</button></body></html>")
    defer free_layout(root)
    bb := find_button_box(root)
    testing.expect(t, bb != nil, "achou a caixa do botao")
    testing.expect_value(t, bb.bg, u32(0x123456))
}

@(test)
test_button_disabled :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><button disabled>Ok</button></body></html>")
    defer free_layout(root)
    bb := find_button_box(root)
    testing.expect(t, bb != nil, "achou a caixa do botao")
    testing.expect(t, bb.cursor == .NotAllowed, "botao disabled bloqueia o cursor")
}

// ── <input type=submit/reset/button>: mesma cara de botão ────────────────────

// Primeira caixa inline-block cujo nó tem esta tag.
@(private="file")
find_inline_box_tag :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil && it.box.node != nil && it.box.node.tag == tag do return it.box
    }
    for c in b.children do if r := find_inline_box_tag(c, tag); r != nil do return r
    return nil
}

@(test)
test_input_submit_vira_botao :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><form><input type='submit' value='Enviar agora'></form></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "input submit vira caixa inline")
    testing.expect(t, bb.has_bg && bb.has_border, "input submit tem cara de botao")
    testing.expect(t, has_word(bb, "Enviar agora"), "rotulo vem do atributo value")
}

@(test)
test_input_submit_label_padrao :: proc(t: ^testing.T) {
    // sem value → rótulo padrão "Enviar"
    root := build_from_html("<html><body><input type='submit'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && has_word(bb, "Enviar"), "submit sem value usa 'Enviar'")
}

// Lê o buffer editável (null-terminado) de um campo de texto como string.
@(private="file")
edit_str :: proc(b: ^Box) -> string {
    return string(cstring(&b.edit_buf[0]))
}

@(test)
test_input_text_vira_campo :: proc(t: ^testing.T) {
    // input type=text vira um campo editável: fundo branco, borda, value no buffer
    root := build_from_html("<html><body><input type='text' value='oi'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "input text vira caixa (campo)")
    testing.expect(t, bb.ctrl == .Text, "campo editavel de texto")
    testing.expect(t, bb.has_bg && bb.bg == 0xffffff, "campo tem fundo branco")
    testing.expect(t, bb.has_border, "campo tem borda")
    testing.expect_value(t, edit_str(bb), "oi") // value inicial no buffer editavel
}

@(test)
test_input_placeholder :: proc(t: ^testing.T) {
    // sem value, o placeholder vira o hint do InputText; buffer começa vazio
    root := build_from_html("<html><body><input type='text' placeholder='Busca'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "campo existe")
    testing.expect_value(t, bb.edit_hint, "Busca")
    testing.expect_value(t, edit_str(bb), "")
}

@(test)
test_input_password :: proc(t: ^testing.T) {
    // o mascaramento é feito pela flag .Password do InputText (não no buffer)
    root := build_from_html("<html><body><input type='password' value='abc'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "campo de senha existe")
    testing.expect(t, bb.ctrl == .Password, "tipo password")
    testing.expect_value(t, edit_str(bb), "abc")
}

@(test)
test_input_disabled_readonly :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><input type='text' value='x' readonly></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && bb.ctrl_disabled, "readonly marca o campo como nao editavel")
}

// Roda o pipeline completo com CSS externo (não só style="") e faz o layout.
@(private="file")
layout_with_css :: proc(html, css: string, vw: f32 = 800) -> ^Box {
    dom := htmlp.parse(html)
    rules, kf := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, vw, 600, kf[:])
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return root
}

// Regressão famososbr.com: `input::placeholder{color}` NÃO pode pintar o texto do
// próprio input (o pseudo-elemento vazava para a cor do elemento).
@(test)
test_placeholder_nao_vaza_cor :: proc(t: ^testing.T) {
    root := layout_with_css(
        `<html><body><input type="text"></body></html>`,
        `input{color:#00ff00} .b input::placeholder{color:#ff0000} input::placeholder{color:#ff0000}`)
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "input existe")
    testing.expect_value(t, bb.edit_color, u32(0x00ff00)) // cor do elemento, nao do ::placeholder
}

// Regressão famososbr.com: com box-sizing:border-box + padding grande, o campo
// não pode achatar (a altura padrão precisa somar padding+borda).
@(test)
test_input_border_box_nao_achata :: proc(t: ^testing.T) {
    root := layout_with_css(
        `<html><body><input type="text"></body></html>`,
        `*{box-sizing:border-box} input{padding:11px 19px;border:2px solid red}`)
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "input existe")
    // padding(22) + borda(4) = 26; com a linha de texto deve passar disso
    testing.expect(t, bb.h > 34, "campo border-box nao achata (altura inclui a linha)")
}

@(test)
test_input_text_largura_padrao :: proc(t: ^testing.T) {
    // campo vazio ainda tem largura padrão (não encolhe a ~zero)
    root := layout_from_html("<html><body><input type='text'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && bb.w > 80, "campo vazio tem largura padrao")
}

@(test)
test_input_hidden_nao_renderiza :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><input type='hidden' value='x'></body></html>")
    defer free_layout(root)
    testing.expect(t, find_inline_box_tag(root, "input") == nil, "input hidden nao renderiza")
}

// ── checkbox / radio (visual) ───────────────────────────────────────────────

@(test)
test_checkbox_marca_e_tamanho :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><input type='checkbox' checked></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil, "checkbox vira caixa")
    testing.expect(t, bb.ctrl == .Checkbox, "marcada como checkbox p/ o paint")
    testing.expect(t, bb.ctrl_checked, "checked reflete o atributo")
    testing.expect(t, bb.has_width && bb.width == 13, "tamanho fixo de 13px")
}

@(test)
test_checkbox_sem_checked :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><input type='checkbox'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && bb.ctrl == .Checkbox, "checkbox existe")
    testing.expect(t, !bb.ctrl_checked, "sem atributo checked = desmarcada")
    testing.expect(t, bb.bg == 0xffffff, "desmarcada tem fundo branco")
}

@(test)
test_radio_e_circulo :: proc(t: ^testing.T) {
    root := build_from_html("<html><body><input type='radio' checked></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && bb.ctrl == .Radio, "marcada como radio")
    // border-radius = metade do lado => círculo
    testing.expect(t, bb.border_radius[0] == 6.5, "radio arredonda em circulo (raio 6.5)")
    testing.expect(t, bb.ctrl_checked, "radio marcado")
}

@(test)
test_checkbox_flui_com_label :: proc(t: ^testing.T) {
    // checkbox + texto do <label> devem ficar na MESMA linha (fluxo inline)
    root := build_from_html("<html><body><label><input type='checkbox'> Aceito</label></body></html>")
    defer free_layout(root)
    testing.expect_value(t, count_inline_boxes(root), 1) // o checkbox é 1 InlineBox
    testing.expect(t, has_word(root, "Aceito"), "rotulo do label presente")
}

@(test)
test_input_button_shrink_to_fit :: proc(t: ^testing.T) {
    root := layout_from_html("<html><body><input type='button' value='X'></body></html>")
    defer free_layout(root)
    bb := find_inline_box_tag(root, "input")
    testing.expect(t, bb != nil && bb.w > 0 && bb.w < 200, "input botao encolhe ao rotulo")
}
