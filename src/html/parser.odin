package html

// Parser de HTML simplificado e legado: tokeniza e constrói uma árvore DOM
// numa única passada, usando uma pilha de elementos abertos. Não é o caminho
// principal de navegação/renderização nem o usado por innerHTML: esses passam por
// parse_document/parse_render e parse_fragment, em treebuild.odin. Este arquivo
// permanece para comparação via --parsetree-legacy e conserva helpers de baixo
// nível compartilhados.
//
// Cobre o grosso do HTML do mundo real:
//   - tags de abertura/fechamento e auto-fechadas (<br/>)
//   - atributos (com aspas duplas, simples ou sem aspas)
//   - elementos vazios (br, img, meta, ...)
//   - <script>/<style> como texto cru
//   - comentários <!-- --> e <!doctype>
//   - entidades comuns (&amp; &lt; &#39; ...)
//
// NÃO implementa todas as regras de recuperação de erro da spec do HTML5
// (modos de inserção, tabelas etc.) — isso é um projeto à parte.

import "core:strings"
import dom "../dom"

// Elementos vazios: nunca têm filhos nem tag de fechamento.
@(private)
is_void :: proc(tag: string) -> bool {
    switch tag {
    case "area", "base", "br", "col", "embed", "hr", "img", "input",
         "link", "meta", "param", "source", "track", "wbr":
        return true
    }
    return false
}

@(private)
is_space :: proc(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// Ponto de entrada: recebe o HTML, devolve o nó Document raiz.
parse :: proc(input: string) -> ^dom.Node {
    input := input
    // BOM inicial (U+FEFF, EF BB BF em UTF-8) é descartado pelo HTML spec — senão
    // vira um "?" visível no começo da página.
    if len(input) >= 3 && input[0] == 0xEF && input[1] == 0xBB && input[2] == 0xBF {
        input = input[3:]
    }
    doc := dom.make_node(.Document)

    stack: [dynamic]^dom.Node
    defer delete(stack)
    append(&stack, doc)

    current :: proc(stack: [dynamic]^dom.Node) -> ^dom.Node {
        return stack[len(stack) - 1]
    }

    i := 0
    n := len(input)

    for i < n {
        if input[i] == '<' && i + 1 < n {
            next := input[i + 1]

            // comentário <!-- ... -->
            if has_at(input, i, "<!--") {
                end := index_from(input, i + 4, "-->")
                body_end := end if end >= 0 else n
                node := dom.make_node(.Comment)
                node.text = strings.clone(input[i + 4 : body_end])
                dom.append_child(current(stack), node)
                i = body_end + 3 if end >= 0 else n
                continue
            }

            // `<?...>` → BOGUS COMMENT (spec: o '?' entra no conteúdo do comentário).
            // Não é curiosidade de spec: o lit-html emite `<?lit$xxx$>` como marcador
            // de posição JUSTAMENTE porque o parser vira comentário. Aqui virava um
            // ELEMENTO `?lit$xxx$` que engolia o resto do template — o componente
            // renderizava vazio. O parser de spec, parse_document, já fazia certo;
            // este caminho pertence somente ao parser legado. innerHTML usa
            // treebuild.parse_fragment.)
            if next == '?' {
                end := index_byte_from(input, i, '>')
                body_end := end if end >= 0 else n
                node := dom.make_node(.Comment)
                node.text = strings.clone(input[i + 1 : body_end])
                dom.append_child(current(stack), node)
                i = body_end + 1 if end >= 0 else n
                continue
            }

            // declaração <!doctype ...> — ignorada
            if next == '!' {
                end := index_byte_from(input, i, '>')
                i = end + 1 if end >= 0 else n
                continue
            }

            // tag de fechamento </tag>
            if next == '/' {
                end := index_byte_from(input, i, '>')
                close := end if end >= 0 else n
                tag := close_tag_name(input[i + 2 : close])
                close_tag(&stack, tag)
                delete(tag)
                i = close + 1 if end >= 0 else n
                continue
            }

            // tag de abertura <tag ...>
            tag, attrs, aorder, self_closing, consumed, _, ok := parse_open_tag(input[i:])
            if ok {
                // fechamento implícito: <li>, <p>, <tr>, <td>... fecham irmãos abertos
                implied_close(&stack, tag)

                el := dom.make_node(.Element)
                el.tag   = tag
                el.attrs = attrs
                el.attr_order = aorder
                dom.append_child(current(stack), el)

                if !is_void(tag) && !self_closing {
                    // Conteúdo de texto até o fechamento:
                    //  - RAWTEXT (<script>/<style>): cru, sem decodificar
                    //  - RCDATA  (<textarea>/<title>): texto, mas com entidades
                    raw    := tag == "script" || tag == "style"
                    rcdata := tag == "textarea" || tag == "title"
                    if raw || rcdata {
                        rest_start := i + consumed
                        rclose := find_raw_close(input, rest_start, tag)
                        end := rclose if rclose >= 0 else n
                        if end > rest_start {
                            t := dom.make_node(.Text)
                            if rcdata {
                                t.text = sanitize_text(decode_entities(input[rest_start:end]))
                            } else {
                                // <script>/<style>: cru, mas descasca um invólucro
                                // <![CDATA[ ... ]]> (convenção XHTML) — senão a
                                // folha inteira vira regra inválida e nada aplica.
                                t.text = strings.clone(strip_cdata(input[rest_start:end]))
                            }
                            dom.append_child(el, t)
                        }
                        // pula até o fim do </tag ...>
                        if rclose >= 0 {
                            ce := index_byte_from(input, rclose, '>')
                            i = ce + 1 if ce >= 0 else n
                        } else {
                            i = n
                        }
                        continue
                    }
                    append(&stack, el)
                }
                i += consumed
                continue
            }

            // '<' solto que não é tag — trata como texto
        }

        // nó de texto até o próximo '<'. Mantemos nós só-de-espaço: o colapso
        // e o aparo acontecem no layout (preserva o espaço entre inline).
        //
        // Se chegamos aqui com input[i]=='<', é um '<' que NÃO virou tag (ex.:
        // "< ", "a<b" sem tag válida, ou "<" no fim do input): é texto literal.
        // A busca do próximo '<' precisa começar DEPOIS dele — senão
        // index_byte_from devolve a MESMA posição i, o slice fica vazio e i não
        // avança: LOOP INFINITO (achado pelo html5lib-tests com o input "<").
        search_from := i + 1 if input[i] == '<' else i
        j := index_byte_from(input, search_from, '<')
        text_end := j if j >= 0 else n
        raw := input[i:text_end]
        if len(raw) > 0 {
            t := dom.make_node(.Text)
            t.text = sanitize_text(decode_entities(raw))
            dom.append_child(current(stack), t)
        }
        i = text_end
    }

    return doc
}

// Elementos de metadados (conteúdo de <head>): ficam ANTES do <body>. O primeiro
// nó de FLUXO (qualquer outro elemento, ou texto não-branco) dispara o body.
@(private)
is_head_element :: proc(tag: string) -> bool {
    switch tag {
    case "head", "title", "base", "basefont", "bgsound", "link", "meta",
         "style", "script", "noscript", "template":
        return true
    }
    return false
}

// Sintetiza a estrutura implícita `html > (metadados..., body > fluxo...)`.
// O parser não cria <head>/<body> implícitos; sem um <body> real as regras
// `body{...}` não casam com nada e a geometria do corpo (margem default de 8px,
// width, height, background que propaga p/ o viewport) se perde. A MAIORIA das
// páginas reais (e ~2/3 dos WPT) omite a tag <body>. Aqui embrulhamos o conteúdo
// de fluxo num <body> (spec HTML: tudo a partir do primeiro nó de fluxo entra no
// body; metadados anteriores ficam no head). Idempotente quando já há <body>.
// Chamado pelos PONTOS DE RENDERIZAÇÃO (não por parse()): o parser em si devolve
// a árvore CRUA (contrato dos testes html5lib/parser_test); a normalização é um
// passo de preparação do documento aplicado só quando se vai renderizar.
normalize_document :: proc(doc: ^dom.Node) {
    // localiza (ou cria) o <html> como filho direto do documento
    html: ^dom.Node
    for c in doc.children {
        if c.kind == .Element && c.tag == "html" { html = c; break }
    }
    if html == nil {
        // sem <html>: cria um e move TODO o conteúdo do documento p/ dentro dele
        html = dom.make_node(.Element)
        html.tag = strings.clone("html")
        moved := dom.kids_take(doc)
        dom.append_child(doc, html)
        for c in moved {
            c.parent = html
            dom.kids_append(html, c)
        }
        delete(moved)
    }
    // já existe <body> como filho direto? então a árvore já está normalizada.
    for c in html.children {
        if c.kind == .Element && c.tag == "body" do return
    }
    // acha o índice do primeiro nó de FLUXO (dispara o body)
    split := -1
    for c, idx in html.children {
        if c.kind == .Element && !is_head_element(c.tag) { split = idx; break }
        if c.kind == .Text && strings.trim_space(c.text) != "" { split = idx; break }
    }
    if split < 0 do return // só há metadados: nenhum body necessário
    // reconstrói html.children: cabeça [0..split) + <body> com o restante
    kids := dom.kids_take(html)
    for i in 0 ..< split {
        kids[i].parent = html
        dom.kids_append(html, kids[i])
    }
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    dom.append_child(html, body)
    for i in split ..< len(kids) {
        kids[i].parent = body
        dom.kids_append(body, kids[i])
    }
    delete(kids)
}

// Fecha a tag dada: desempilha até encontrar um elemento com esse nome.
@(private)
close_tag :: proc(stack: ^[dynamic]^dom.Node, tag: string) {
    for idx := len(stack) - 1; idx >= 1; idx -= 1 {
        if stack[idx].tag == tag {
            resize(stack, idx) // remove o elemento e tudo acima dele
            return
        }
    }
    // sem correspondência: ignora (fechamento órfão)
}

// Fechamento implícito de tags com end tag opcional (regras do HTML5):
// ao abrir certas tags, fecha automaticamente irmãos abertos do mesmo grupo.
@(private)
implied_close :: proc(stack: ^[dynamic]^dom.Node, tag: string) {
    switch tag {
    case "li":
        close_to(stack, []string{"li"}, []string{"ul", "ol", "menu"})
    case "dt", "dd":
        close_to(stack, []string{"dt", "dd"}, []string{"dl"})
    case "option":
        close_to(stack, []string{"option"}, []string{"select", "datalist", "optgroup"})
    case "optgroup":
        close_to(stack, []string{"optgroup", "option"}, []string{"select", "datalist"})
    case "tr":
        close_to(stack, []string{"tr"}, []string{"table"})
    case "td", "th":
        close_to(stack, []string{"td", "th"}, []string{"tr", "thead", "tbody", "tfoot", "table"})
    case "thead", "tbody", "tfoot", "caption", "colgroup":
        close_table_sections(stack)
    }
    // elementos de bloco fecham um <p> aberto
    if closes_p(tag) {
        close_to(stack, []string{"p"}, []string{})
    }
}

// Desempilha até (e incluindo) o alvo mais próximo do topo. Aborta sem mexer
// se encontrar antes uma tag de "stop" (limite de escopo, ex.: <ul> para <li>).
@(private)
close_to :: proc(stack: ^[dynamic]^dom.Node, targets, stops: []string) -> bool {
    for idx := len(stack) - 1; idx >= 1; idx -= 1 {
        t := stack[idx].tag
        if tag_in(targets, t) { resize(stack, idx); return true }
        if tag_in(stops, t)   { return false }
    }
    return false
}

// Fecha seções/linhas/células abertas até o <table> (ao abrir thead/tbody/...).
@(private)
close_table_sections :: proc(stack: ^[dynamic]^dom.Node) {
    group := []string{"thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup"}
    for len(stack) > 1 {
        t := stack[len(stack) - 1].tag
        if t == "table" do break
        if !tag_in(group, t) do break
        resize(stack, len(stack) - 1)
    }
}

@(private)
tag_in :: proc(set: []string, t: string) -> bool {
    for s in set do if s == t do return true
    return false
}

// Tags de bloco cuja abertura fecha um <p> em aberto.
@(private)
closes_p :: proc(tag: string) -> bool {
    switch tag {
    case "address", "article", "aside", "blockquote", "details", "dialog", "div",
         "dl", "fieldset", "figcaption", "figure", "footer", "form",
         "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
         "menu", "nav", "ol", "p", "pre", "section", "table", "ul":
        return true
    }
    return false
}

// Lê uma tag de abertura a partir de '<'. Devolve nome, atributos, se é
// auto-fechada, quantos bytes consumiu, se um '>' fechou a tag (`closed`; false =
// bateu em EOF sem fechar — o tokenizer abandona a tag nesse caso), e se deu certo.
@(private)
// `order` = nomes dos atributos na ordem em que aparecem no texto (a spec exige que
// getAttributeNames() venha em ordem de documento; o map do Odin não tem ordem).
parse_open_tag :: proc(s: string) -> (tag: string, attrs: map[string]string, order: [dynamic]string, self_closing: bool, consumed: int, closed: bool, ok: bool) {
    n := len(s)
    if n < 2 || s[0] != '<' do return

    i := 1
    name_start := i
    for i < n && !is_space(s[i]) && s[i] != '>' && s[i] != '/' {
        i += 1
    }
    if i == name_start do return // '<' seguido de espaço etc. — não é tag

    tag = normalize_tag(s[name_start:i])
    attrs = make(map[string]string)

    for i < n {
        // pula espaços
        for i < n && is_space(s[i]) do i += 1
        if i >= n do break

        if s[i] == '>' {
            i += 1
            consumed = i
            closed = true
            ok = true
            return
        }
        if s[i] == '/' {
            // self-closing SÓ se a '/' vier imediatamente antes do '>'. Uma '/'
            // seguida de outra coisa (ex.: `<h/a='b'>`) é uma solidus perdida:
            // a spec a ignora e segue lendo atributos (não é self-closing).
            if i + 1 < n && s[i + 1] == '>' do self_closing = true
            i += 1
            continue
        }

        // nome do atributo. Um '=' no INÍCIO (before-attribute-name state) é um
        // parse error, mas a spec o trata como 1º caractere do nome — ex.:
        // `<a =>` vira atributo de nome "=". Por isso consumimos um '=' inicial
        // antes de parar no próximo '='.
        an_start := i
        if i < n && s[i] == '=' do i += 1
        for i < n && !is_space(s[i]) && s[i] != '=' && s[i] != '>' && s[i] != '/' {
            i += 1
        }
        aname := normalize_tag(s[an_start:i])

        avalue := ""
        for i < n && is_space(s[i]) do i += 1
        if i < n && s[i] == '=' {
            i += 1
            for i < n && is_space(s[i]) do i += 1
            if i < n && (s[i] == '"' || s[i] == '\'') {
                quote := s[i]
                i += 1
                v_start := i
                for i < n && s[i] != quote do i += 1
                avalue = decode_entities(s[v_start:i], in_attribute = true)
                if i < n do i += 1 // pula a aspa de fechamento
            } else {
                v_start := i
                for i < n && !is_space(s[i]) && s[i] != '>' do i += 1
                avalue = decode_entities(s[v_start:i], in_attribute = true)
            }
        }

        if aname != "" && aname not_in attrs {
            attrs[aname] = avalue
            append(&order, aname)
        } else {
            // atributo duplicado (mantém o PRIMEIRO, spec) ou nome vazio: descarta
            delete(aname)
            if avalue != "" do delete(avalue)
        }
    }

    consumed = n
    ok = true
    return
}

// ── utilitários de string ───────────────────────────────────────────────────

@(private)
normalize_tag :: proc(s: string) -> string {
    // sem trim: os scanners (parse_open_tag/close_tag_name) já param na
    // whitespace HTML. O strings.trim_space do Odin removeria também o VT
    // (U+000B), que NÃO é delimitador de nome no HTML5 e deve ficar no nome.
    // NUL → U+FFFD (regra dos "tag name"/"attribute name state" do HTML5).
    if strings.index_byte(s, 0) >= 0 {
        b := strings.builder_make()
        for k in 0 ..< len(s) {
            c := s[k]
            if c == 0x00 { strings.write_rune(&b, '�') }
            else if c >= 'A' && c <= 'Z' { strings.write_byte(&b, c + 32) }
            else { strings.write_byte(&b, c) }
        }
        return strings.to_string(b)
    }
    return strings.to_lower(s)
}

// Nome de tag a partir do conteúdo de uma tag de fechamento (`</NOME ...>`): vai
// até o 1º espaço ou '/', minúsculo. Sem isto, `</div class=x>` viraria o "nome"
// "div class=x" e NÃO fecharia o <div> (bug real de fechamento).
@(private)
close_tag_name :: proc(s: string) -> string {
    end := len(s)
    for k in 0 ..< len(s) {
        if is_space(s[k]) || s[k] == '/' { end = k; break }
    }
    return normalize_tag(s[:end])
}

@(private)
has_at :: proc(s: string, at: int, needle: string) -> bool {
    if at + len(needle) > len(s) do return false
    return s[at : at + len(needle)] == needle
}

@(private)
index_from :: proc(s: string, from: int, needle: string) -> int {
    if from >= len(s) do return -1
    r := strings.index(s[from:], needle)
    return -1 if r < 0 else from + r
}

// Descasca um invólucro <![CDATA[ ... ]]> do texto cru de <style>/<script>.
// É a convenção de XHTML (as refs .xht do WPT usam isso); sem descascar, o
// texto "<![CDATA[ div{...}" vira regra CSS inválida e a folha inteira é
// descartada. Sem invólucro (ou incompleto), devolve a fatia intacta.
@(private)
strip_cdata :: proc(s: string) -> string {
    a := strings.trim_space(s)
    if strings.has_prefix(a, "<![CDATA[") && strings.has_suffix(a, "]]>") {
        return a[len("<![CDATA[") : len(a) - len("]]>")]
    }
    return s
}

// Acha o '<' do fechamento de um elemento RAWTEXT/RCDATA (`</tag`), casando o
// nome de forma case-insensitive (ex.: </TITLE> fecha <title>). -1 se não achar.
@(private)
find_raw_close :: proc(input: string, from: int, tag: string) -> int {
    n  := len(input)
    tl := len(tag)
    i  := from
    for {
        lt := index_from(input, i, "</")
        if lt < 0 do return -1
        p := lt + 2
        if p + tl <= n && eq_ascii_ci(input[p : p + tl], tag) {
            after := p + tl
            if after >= n || is_space(input[after]) || input[after] == '>' || input[after] == '/' {
                return lt
            }
        }
        i = lt + 2
    }
}

@(private)
eq_ascii_ci :: proc(a, b: string) -> bool {
    if len(a) != len(b) do return false
    for i in 0 ..< len(a) {
        ca, cb := a[i], b[i]
        if ca >= 'A' && ca <= 'Z' do ca += 32
        if cb >= 'A' && cb <= 'Z' do cb += 32
        if ca != cb do return false
    }
    return true
}

@(private)
index_byte_from :: proc(s: string, from: int, b: u8) -> int {
    for i := from; i < len(s); i += 1 {
        if s[i] == b do return i
    }
    return -1
}

// Remove codepoints que o motor não renderiza, para não virarem '?' na tela:
//   - plano astral (> U+FFFF): emojis coloridos (📷 🎵 🔥 👍) não cabem no
//     ImWchar de 16 bits do ImGui — sem isto apareceriam como '?'.
//   - seletores de variação (U+FE0E/FE0F) e joiners de largura zero (U+200D,
//     U+200B/C): invisíveis por definição; sem remover, viram um '?' extra
//     depois do símbolo base (ex.: "▶️" = ▶ + FE0F → '?' sobrando).
// Recebe uma string OWNED (de decode_entities) e devolve OWNED: se não há nada a
// remover, devolve a mesma; senão reconstrói e libera a original.
@(private)
sanitize_text :: proc(s: string) -> string {
    need := false
    for r in s {
        if is_drop_rune(r) || r == 0x00a0 { need = true; break }
    }
    if !need do return s
    sb := strings.builder_make()
    for r in s {
        if r == 0x00a0 {
            strings.write_byte(&sb, ' ') // nbsp → espaço ASCII (render; ver decode_entities)
        } else if !is_drop_rune(r) {
            strings.write_rune(&sb, r)
        }
    }
    delete(s)
    return strings.to_string(sb)
}

@(private)
is_drop_rune :: proc(r: rune) -> bool {
    switch r {
    case 0xFE0E, 0xFE0F, 0x200B, 0x200C, 0x200D: return true // var. selectors / ZW joiners
    }
    // ⚠️ Aqui havia `return r > 0xFFFF`: todo rune fora do BMP era APAGADO do
    // texto, porque o ImWchar de 16 bits do ImGui não o representa e ele viraria
    // `?` na tela. Desde o M188 o emoji não passa mais pelo atlas — vira TEXTURA
    // (ver src/ui/emoji.odin) — e apagá-lo aqui era justamente o que impedia o
    // conserto: o caractere sumia antes de chegar ao layout.
    return false
}

@(private)
is_alnum :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Decodifica referências de caractere (numéricas e nomeadas). Devolve string
// nova (owned). Implementa o LONGEST-MATCH do HTML5 para entidades nomeadas,
// incluindo as formas LEGADAS sem ';' (&copy, &AElig, ...): a tabela completa
// (entities_gen.odin) guarda ambas as formas.
//
// `in_attribute` liga a "ambiguous ampersand": em valor de atributo, uma
// entidade legada (sem ';') seguida de '=' ou alfanumérico NÃO é decodificada —
// senão `href="?a&copy=1"` viraria `?a©=1`. Em texto a entidade legada sempre
// resolve.
@(private)
decode_entities :: proc(s: string, in_attribute := false) -> string {
    // atalho: nada a fazer se não há '&' nem (em atributo) NUL a mapear p/ FFFD
    if strings.index_byte(s, '&') < 0 && !(in_attribute && strings.index_byte(s, 0x00) >= 0) {
        return strings.clone(s)
    }

    sb := strings.builder_make()
    i := 0
    n := len(s)
    for i < n {
        if s[i] != '&' {
            // NUL em valor de atributo → U+FFFD (spec). Em texto (data state) o
            // NUL é mantido, por isso o gate em in_attribute.
            if in_attribute && s[i] == 0x00 {
                strings.write_rune(&sb, '�')
            } else {
                strings.write_byte(&sb, s[i])
            }
            i += 1
            continue
        }

        // referência numérica: &#123; ou &#xAB;. O ';' é OPCIONAL (forma legada);
        // consome os dígitos direto (zeros à esquerda ok, sem teto de comprimento).
        if i + 1 < n && s[i + 1] == '#' {
            k := i + 2
            hex := k < n && (s[k] == 'x' || s[k] == 'X')
            if hex do k += 1
            cp := 0
            have := false
            for k < n {
                d := -1
                c := s[k]
                if hex {
                    switch {
                    case c >= '0' && c <= '9': d = int(c - '0')
                    case c >= 'a' && c <= 'f': d = int(c - 'a') + 10
                    case c >= 'A' && c <= 'F': d = int(c - 'A') + 10
                    }
                } else if c >= '0' && c <= '9' {
                    d = int(c - '0')
                }
                if d < 0 do break
                have = true
                cp = cp * (16 if hex else 10) + d
                if cp > 0x110000 do cp = 0x110000 // satura (evita overflow)
                k += 1
            }
            if have {
                if k < n && s[k] == ';' do k += 1 // ';' opcional
                // regras de erro do "numeric character reference end state":
                if cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                    strings.write_rune(&sb, '�')
                } else {
                    strings.write_rune(&sb, remap_c1(cp)) // 0x80-0x9F → windows-1252
                }
                i = k
                continue
            }
            strings.write_byte(&sb, '&') // '&#' sem dígitos → literal
            i += 1
            continue
        }

        // referência nomeada: run alfanumérico após o '&'
        j := i + 1
        for j < n && is_alnum(s[j]) do j += 1
        run_len := j - (i + 1)

        ma, mb: rune
        matched := 0 // nº de chars consumidos após o '&' (0 = sem match)

        // 1) forma com ';': o run inteiro seguido de ';' (é sempre a mais longa)
        if run_len > 0 && j < n && s[j] == ';' {
            if a, b, ok := named_entity(s[i + 1 : j + 1]); ok { // inclui o ';'
                ma, mb, matched = a, b, run_len + 1
            }
        }
        // 2) legado (sem ';'): o MAIOR prefixo do run que é uma chave da tabela
        if matched == 0 {
            for L := run_len; L >= 1; L -= 1 {
                if a, b, ok := named_entity(s[i + 1 : i + 1 + L]); ok {
                    // ambiguous ampersand: em atributo, se o char seguinte for '='
                    // ou alfanumérico, não decodifica (fica literal).
                    if in_attribute {
                        nx := i + 1 + L
                        if nx < n && (s[nx] == '=' || is_alnum(s[nx])) do break
                    }
                    ma, mb, matched = a, b, L
                    break
                }
            }
        }

        if matched > 0 {
            // decode_entities é spec-correto (nbsp → U+00A0 real). A troca por
            // espaço ASCII para RENDER é feita no sanitize_text (só o parser), não
            // aqui — assim o tokenizer reporta o codepoint real.
            strings.write_rune(&sb, ma)
            if mb != 0 do strings.write_rune(&sb, mb)
            i += 1 + matched
        } else {
            strings.write_byte(&sb, '&') // sem match → '&' literal
            i += 1
        }
    }
    return strings.to_string(sb)
}

// Remapeamento dos controles C1 (0x80-0x9F) de char ref numérico para
// windows-1252 — regra do "numeric character reference end state" do HTML5.
// Ex.: &#128; → € (U+20AC). Codepoints fora dessa faixa passam intactos.
@(private)
remap_c1 :: proc(cp: int) -> rune {
    switch cp {
    case 0x80: return '€'
    case 0x82: return '‚'
    case 0x83: return 'ƒ'
    case 0x84: return '„'
    case 0x85: return '…'
    case 0x86: return '†'
    case 0x87: return '‡'
    case 0x88: return 'ˆ'
    case 0x89: return '‰'
    case 0x8A: return 'Š'
    case 0x8B: return '‹'
    case 0x8C: return 'Œ'
    case 0x8E: return 'Ž'
    case 0x91: return '‘'
    case 0x92: return '’'
    case 0x93: return '“'
    case 0x94: return '”'
    case 0x95: return '•'
    case 0x96: return '–'
    case 0x97: return '—'
    case 0x98: return '˜'
    case 0x99: return '™'
    case 0x9A: return 'š'
    case 0x9B: return '›'
    case 0x9C: return 'œ'
    case 0x9E: return 'ž'
    case 0x9F: return 'Ÿ'
    }
    return rune(cp)
}
