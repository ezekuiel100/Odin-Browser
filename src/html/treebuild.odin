package html

// Construção de árvore HTML5 FIEL (tree construction / insertion modes) — o
// algoritmo real da spec, usado pelo modo `browser.exe --parsetree` e medido
// pela suíte html5lib tree-construction.
//
// Diferente do parser.odin (um SUBCONJUNTO de passada única, usado pela
// renderização), aqui implementamos:
//   - o esqueleto <html>/<head>/<body> sintetizado
//   - o nó <!DOCTYPE> e detecção de quirks
//   - a pilha de elementos abertos com escopos
//   - a lista de elementos de formatação ativos + adoption agency
//   - as insertion modes (initial → before html → ... → in body → tabelas →
//     select → after body → frameset)
//   - foster parenting
//
// LIMITAÇÕES desta versão (geram DIFF, não crash): conteúdo estrangeiro
// (SVG/MathML) é tratado como HTML comum; <template> vira elemento normal (sem
// o document-fragment "content"); fragment parsing não é exposto.
//
// Reusa os helpers de baixo nível do parser.odin (parse_open_tag,
// decode_entities, find_raw_close, is_void, close_tag_name, has_at,
// index_byte_from, index_from, is_space).

import "core:strings"
import "core:unicode/utf8"
import dom "../dom"

// ─────────────────────────────── Tokens ────────────────────────────────────

Tok_Kind :: enum { Char, StartTag, EndTag, Comment, Doctype, EOF }

Token :: struct {
    kind:         Tok_Kind,
    name:         string,            // nome de tag (start/end) ou de doctype
    data:         string,            // texto (Char) ou dados (Comment)
    attrs:        map[string]string, // atributos (StartTag)
    attr_order:   [dynamic]string,    // ordem de DOCUMENTO dos atributos (spec; ver dom.set_attr)
    self_closing: bool,
    // `data` é o ÚNICO campo com posse ambígua: em Comment e no texto do estado
    // Data ele é alocado (scan_comment/decode_entities), mas em CDATA, RAWTEXT e
    // no "</" solto é uma FATIA do input — liberá-la corromperia a heap. Os
    // demais (name/pub_id/sys_id/attrs/attr_order) são SEMPRE alocados quando
    // presentes. Default `false` = "não é meu": esquecer a marca vaza (sintoma
    // pequeno), marcar de menos nunca dá bad free. Ver token_destroy.
    owns_data:    bool,
    // doctype
    has_name, has_pub, has_sys, force_quirks: bool,
    pub_id, sys_id: string,
}

// Libera o que o TOKEN possui. Chamado em tb_run depois que o token foi
// processado (o reprocessamento da spec é interno ao tb_process, então nesse
// ponto ninguém mais o lê).
//
// Por que é seguro: TODO consumidor de tok.name/data/attrs no tree builder ou
// COMPARA (switch tok.name, "color" in tok.attrs) ou CLONA para dentro do DOM
// (make_element, apply_token_attrs, insert_text, insert_comment, insert_doctype).
// Nenhuma estrutura de vida longa guarda uma string do token: b.afe só tem
// ^dom.Node, e b.tok.last_start aponta para o `tag` do ELEMENTO, não do token.
@(private = "file")
token_destroy :: proc(tok: ^Token) {
    if tok.name   != "" do delete(tok.name)
    if tok.pub_id != "" do delete(tok.pub_id)
    if tok.sys_id != "" do delete(tok.sys_id)
    if tok.owns_data && tok.data != "" do delete(tok.data)
    for k, v in tok.attrs {
        delete(k)
        if v != "" do delete(v) // atributo sem `=` guarda o literal "" (parse_open_tag)
    }
    delete(tok.attrs)
    delete(tok.attr_order) // as strings são as MESMAS chaves de attrs (já liberadas)
    tok^ = {}
}

Tok_State :: enum { Data, RCDATA, RAWTEXT, ScriptData, PLAINTEXT }

Tokenizer :: struct {
    input:      string,
    pos:        int,
    state:      Tok_State,
    last_start: string,     // "appropriate end tag" p/ RCDATA/RAWTEXT/script
    foreign_ok: bool,       // adjusted current node é estrangeiro (habilita CDATA)
    q:          [dynamic]Token,
}

// ── helpers ASCII locais (has_at_ci é file-private no tokenize.odin) ──
@(private = "file")
is_alpha :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

@(private = "file")
ci_at :: proc(s: string, at: int, needle: string) -> bool {
    if at + len(needle) > len(s) do return false
    for k in 0 ..< len(needle) {
        a := s[at + k]; b := needle[k]
        if a >= 'A' && a <= 'Z' do a += 32
        if b >= 'A' && b <= 'Z' do b += 32
        if a != b do return false
    }
    return true
}

// Fecha RAWTEXT/RCDATA: acha `</tag` seguido de um delimitador REAL
// (whitespace/`/`/`>`) — NÃO no EOF. `</SCRIPT` no fim do input é TEXTO, não
// fechamento (find_raw_close aceitaria EOF, por isso não a usamos aqui).
@(private = "file")
raw_text_close :: proc(s: string, from: int, tag: string) -> int {
    n := len(s); tl := len(tag); i := from
    // tag vazia = não há "appropriate end tag" (fragmento antes de qualquer
    // start tag): nada fecha. Sem o guarda, o slice vazio casaria o primeiro
    // `</` seguido de delimitador (`</ x`, `</>`).
    if tl == 0 do return -1
    for {
        lt := index_from(s, i, "</")
        if lt < 0 do return -1
        p := lt + 2
        if p + tl <= n && eq_ascii_ci(s[p : p + tl], tag) {
            after := p + tl
            if after < n && (is_space(s[after]) || s[after] == '>' || s[after] == '/') do return lt
        }
        i = lt + 2
    }
}

// Acha o '>' que fecha uma tag a partir de `from`, ignorando '>' dentro de
// valores de atributo entre aspas (simples ou duplas). -1 se não achar.
@(private = "file")
tag_end_gt :: proc(s: string, from: int) -> int {
    i := from
    quote: u8 = 0
    for i < len(s) {
        c := s[i]
        if quote != 0 {
            if c == quote do quote = 0
        } else if c == '"' || c == '\'' {
            quote = c
        } else if c == '>' {
            return i
        }
        i += 1
    }
    return -1
}

// Fecha script data honrando os sub-estados de escape (`<!-- ... -->` e
// double-escaped via `<script ... </script`). st: 0=script data, 1=escaped,
// 2=double-escaped. Exige delimitador real após `</tag` (nunca fecha no EOF).
@(private = "file")
script_close :: proc(s: string, start: int, last: string) -> int {
    n := len(s)
    st := 0
    i := start
    delim :: proc(s: string, a: int) -> bool {
        return a < len(s) && (is_space(s[a]) || s[a] == '/' || s[a] == '>')
    }
    for i < n {
        if st >= 1 && has_at(s, i, "-->") { st = 0; i += 3; continue }
        if s[i] == '<' {
            if len(last) > 0 && (st == 0 || st == 1) && i + 1 < n && s[i + 1] == '/' && ci_at(s, i + 2, last) && delim(s, i + 2 + len(last)) {
                return i
            }
            if st == 2 && i + 1 < n && s[i + 1] == '/' && ci_at(s, i + 2, "script") && delim(s, i + 2 + 6) {
                st = 1; i = i + 2 + 6; continue
            }
            if st == 1 && ci_at(s, i + 1, "script") && delim(s, i + 1 + 6) {
                st = 2; i = i + 1 + 6; continue
            }
            if st == 0 && has_at(s, i, "<!--") { st = 1; i += 4; continue }
        }
        i += 1
    }
    return -1
}

// Devolve também se o resultado é ALOCADO: sem NUL a saída é a própria fatia do
// input (nada a liberar); com NUL é uma string nova. Quem enfileira o token
// precisa da distinção (ver Token.owns_data).
@(private = "file")
nul_fffd :: proc(s: string) -> (out: string, owned: bool) {
    if strings.index_byte(s, 0) < 0 do return s, false
    b := strings.builder_make()
    for k in 0 ..< len(s) {
        if s[k] == 0 { strings.write_rune(&b, '�') } else { strings.write_byte(&b, s[k]) }
    }
    return strings.to_string(b), true
}

// Lê o próximo token do fluxo.
@(private = "file")
tok_next :: proc(t: ^Tokenizer) -> Token {
    for len(t.q) == 0 do tok_step(t)
    tok := t.q[0]
    ordered_remove(&t.q, 0)
    return tok
}

// Executa UM passo do tokenizer, enfileirando 0+ tokens. Sempre avança pos ou
// enfileira (garante progresso).
@(private = "file")
tok_step :: proc(t: ^Tokenizer) {
    s := t.input
    n := len(s)
    if t.pos >= n {
        append(&t.q, Token{kind = .EOF})
        return
    }

    switch t.state {
    case .PLAINTEXT:
        pt, pt_owned := nul_fffd(s[t.pos:n])
        append(&t.q, Token{kind = .Char, data = pt, owns_data = pt_owned})
        t.pos = n
        return
    case .RCDATA, .RAWTEXT, .ScriptData:
        close := -1
        if t.state == .ScriptData {
            close = script_close(s, t.pos, t.last_start)
        } else {
            close = raw_text_close(s, t.pos, t.last_start)
        }
        endp := close if close >= 0 else n
        run := s[t.pos:endp]
        text := run
        text_owned := false
        // RAWTEXT/script entregam a FATIA crua; só o RCDATA aloca (decode).
        if t.state == .RCDATA { text = decode_entities(run); text_owned = true }
        if len(text) > 0 do append(&t.q, Token{kind = .Char, data = text, owns_data = text_owned})
        if close >= 0 {
            // a end tag pode ter atributos (`</script foo=">" dd>`): o '>' que
            // fecha NÃO pode estar dentro de um valor entre aspas.
            ce := tag_end_gt(s, close)
            t.pos = ce + 1 if ce >= 0 else n
            append(&t.q, Token{kind = .EndTag, name = strings.to_lower(t.last_start)})
        } else {
            t.pos = n
        }
        t.state = .Data
        return
    case .Data:
        // trata abaixo
    }

    // ── estado Data ──
    if s[t.pos] == '<' && t.pos + 1 < n {
        c := s[t.pos + 1]
        if c == '!' {
            if has_at(s, t.pos, "<!--") {
                data, np := scan_comment_struct(s, t.pos + 4)
                t.pos = np
                append(&t.q, Token{kind = .Comment, data = data, owns_data = true})
                return
            } else if ci_at(s, t.pos + 2, "doctype") {
                tok, np := scan_doctype_struct(s, t.pos + 9)
                t.pos = np
                append(&t.q, tok)
                return
            } else if t.foreign_ok && has_at(s, t.pos + 2, "[CDATA[") {
                end := index_from(s, t.pos + 9, "]]>")
                run := s[t.pos + 9 : end if end >= 0 else n]
                t.pos = end + 3 if end >= 0 else n
                // fatia do input: owns_data fica false de propósito
                if len(run) > 0 do append(&t.q, Token{kind = .Char, data = run})
                return
            } else {
                data, np := scan_bogus_comment(s, t.pos + 2)
                t.pos = np
                append(&t.q, Token{kind = .Comment, data = data, owns_data = true})
                return
            }
        }
        if c == '/' {
            if t.pos + 2 < n && is_alpha(s[t.pos + 2]) {
                end := index_byte_from(s, t.pos, '>')
                close := end if end >= 0 else n
                name := close_tag_name(s[t.pos + 2 : close])
                t.pos = close + 1 if end >= 0 else n
                append(&t.q, Token{kind = .EndTag, name = name})
                return
            } else if t.pos + 2 < n && s[t.pos + 2] == '>' {
                t.pos += 3 // </> ignorado (sem token → progresso pelo pos)
                return
            } else if t.pos + 2 >= n {
                // fatia do input (owns_data false de propósito)
                append(&t.q, Token{kind = .Char, data = s[t.pos:n]}) // "</" literal
                t.pos = n
                return
            } else {
                data, np := scan_bogus_comment(s, t.pos + 2)
                t.pos = np
                append(&t.q, Token{kind = .Comment, data = data, owns_data = true})
                return
            }
        }
        if c == '?' {
            data, np := scan_bogus_comment(s, t.pos + 1)
            t.pos = np
            append(&t.q, Token{kind = .Comment, data = data, owns_data = true})
            return
        }
        if is_alpha(c) {
            tag, attrs, aorder, self_closing, consumed, closed, ok := parse_open_tag(s[t.pos:])
            if ok && !closed {
                t.pos = n // EOF na tag → token abandonado
                // …mas o parse_open_tag JÁ alocou nome, map e ordem: o token que
                // não vai ser emitido continua dono deles (448 B + 128 B + as
                // strings, por tag inacabada — comum em HTML truncado da rede).
                abandoned := Token{kind = .StartTag, name = tag, attrs = attrs, attr_order = aorder}
                token_destroy(&abandoned)
                append(&t.q, Token{kind = .EOF})
                return
            }
            if ok {
                t.pos += consumed
                // aorder = ordem de documento dos atributos (parse_open_tag).
                // Antes era DESCARTADO: a serialização do html5lib ordena os
                // atributos por nome, então a ordem nunca era exercida pela
                // suíte — só apareceu ao plugar isto no innerHTML (m131).
                append(&t.q, Token{kind = .StartTag, name = tag, attrs = attrs, attr_order = aorder, self_closing = self_closing})
                return
            }
        }
    }

    // texto até o próximo '<' ('<' que não vira tag é literal → busca após ele)
    search_from := t.pos + 1 if s[t.pos] == '<' else t.pos
    j := index_byte_from(s, search_from, '<')
    text_end := j if j >= 0 else n
    append(&t.q, Token{kind = .Char, data = decode_entities(s[t.pos:text_end]), owns_data = true})
    t.pos = text_end
}

// Comentário: máquina de estados fiel (fecha em --> / --!>, trata abruptos).
@(private = "file")
scan_comment_struct :: proc(s: string, start: int) -> (data: string, newpos: int) {
    n := len(s)
    p := start
    d := strings.builder_make()
    put :: proc(d: ^strings.Builder, c: u8) {
        if c == 0 { strings.write_rune(d, '�') } else { strings.write_byte(d, c) }
    }
    St :: enum { Start, StartDash, Comment, EndDash, End, EndBang }
    st := St.Start
    done := false
    for !done {
        if p >= n do break
        c := s[p]
        switch st {
        case .Start:
            if c == '-' { p += 1; st = .StartDash }
            else if c == '>' { p += 1; done = true }
            else { st = .Comment }
        case .StartDash:
            if c == '-' { p += 1; st = .End }
            else if c == '>' { p += 1; done = true }
            else { put(&d, '-'); st = .Comment }
        case .Comment:
            if c == '-' { p += 1; st = .EndDash }
            else { put(&d, c); p += 1 }
        case .EndDash:
            if c == '-' { p += 1; st = .End }
            else { put(&d, '-'); st = .Comment }
        case .End:
            if c == '>' { p += 1; done = true }
            else if c == '!' { p += 1; st = .EndBang }
            else if c == '-' { put(&d, '-'); p += 1 }
            else { put(&d, '-'); put(&d, '-'); st = .Comment }
        case .EndBang:
            if c == '-' { put(&d, '-'); put(&d, '-'); put(&d, '!'); p += 1; st = .EndDash }
            else if c == '>' { p += 1; done = true }
            else { put(&d, '-'); put(&d, '-'); put(&d, '!'); st = .Comment }
        }
    }
    return strings.to_string(d), p
}

@(private = "file")
scan_bogus_comment :: proc(s: string, start: int) -> (data: string, newpos: int) {
    n := len(s)
    gt := index_byte_from(s, start, '>')
    end := gt if gt >= 0 else n
    d := strings.builder_make()
    for k in start ..< end {
        if s[k] == 0 { strings.write_rune(&d, '�') } else { strings.write_byte(&d, s[k]) }
    }
    return strings.to_string(d), (end + 1 if gt >= 0 else n)
}

@(private = "file")
Dt_State :: enum {
    BeforeName, Name, AfterName, AfterPubKw, BeforePubId, PubIdDq, PubIdSq,
    AfterPubId, BetweenPubSys, AfterSysKw, BeforeSysId, SysIdDq, SysIdSq,
    AfterSysId, Bogus, Done,
}

// DOCTYPE estruturado: máquina de estados fiel; devolve o Token e a nova pos.
@(private = "file")
scan_doctype_struct :: proc(s: string, start: int) -> (Token, int) {
    n := len(s)
    p := start
    name := strings.builder_make()
    pub  := strings.builder_make()
    sys  := strings.builder_make()
    has_name, has_pub, has_sys, fq := false, false, false, false
    st := Dt_State.BeforeName
    put :: proc(b: ^strings.Builder, c: u8, lower: bool) {
        if c == 0 { strings.write_rune(b, '�'); return }
        ch := c
        if lower && ch >= 'A' && ch <= 'Z' do ch += 32
        strings.write_byte(b, ch)
    }
    for st != .Done {
        if p >= n {
            if st != .Bogus do fq = true
            break
        }
        c := s[p]
        switch st {
        case .BeforeName:
            if is_space(c) { p += 1 }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { has_name = true; put(&name, c, true); p += 1; st = .Name }
        case .Name:
            if is_space(c) { p += 1; st = .AfterName }
            else if c == '>' { p += 1; st = .Done }
            else { put(&name, c, true); p += 1 }
        case .AfterName:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else if ci_at(s, p, "public") { p += 6; st = .AfterPubKw }
            else if ci_at(s, p, "system") { p += 6; st = .AfterSysKw }
            else { fq = true; st = .Bogus }
        case .AfterPubKw:
            if is_space(c) { p += 1; st = .BeforePubId }
            else if c == '"' { has_pub = true; p += 1; st = .PubIdDq }
            else if c == '\'' { has_pub = true; p += 1; st = .PubIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .BeforePubId:
            if is_space(c) { p += 1 }
            else if c == '"' { has_pub = true; p += 1; st = .PubIdDq }
            else if c == '\'' { has_pub = true; p += 1; st = .PubIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .PubIdDq:
            if c == '"' { p += 1; st = .AfterPubId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { put(&pub, c, false); p += 1 }
        case .PubIdSq:
            if c == '\'' { p += 1; st = .AfterPubId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { put(&pub, c, false); p += 1 }
        case .AfterPubId:
            if is_space(c) { p += 1; st = .BetweenPubSys }
            else if c == '>' { p += 1; st = .Done }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else { fq = true; st = .Bogus }
        case .BetweenPubSys:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else { fq = true; st = .Bogus }
        case .AfterSysKw:
            if is_space(c) { p += 1; st = .BeforeSysId }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .BeforeSysId:
            if is_space(c) { p += 1 }
            else if c == '"' { has_sys = true; p += 1; st = .SysIdDq }
            else if c == '\'' { has_sys = true; p += 1; st = .SysIdSq }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { fq = true; st = .Bogus }
        case .SysIdDq:
            if c == '"' { p += 1; st = .AfterSysId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { put(&sys, c, false); p += 1 }
        case .SysIdSq:
            if c == '\'' { p += 1; st = .AfterSysId }
            else if c == '>' { fq = true; p += 1; st = .Done }
            else { put(&sys, c, false); p += 1 }
        case .AfterSysId:
            if is_space(c) { p += 1 }
            else if c == '>' { p += 1; st = .Done }
            else { st = .Bogus }
        case .Bogus:
            if c == '>' { p += 1; st = .Done }
            else { p += 1 }
        case .Done:
        }
    }
    tok := Token{
        kind = .Doctype, name = strings.to_string(name),
        has_name = has_name, has_pub = has_pub, has_sys = has_sys,
        pub_id = strings.to_string(pub), sys_id = strings.to_string(sys),
        force_quirks = fq,
    }
    return tok, p
}

// ─────────────────────────── Construtor de árvore ───────────────────────────

Mode :: enum {
    Initial, BeforeHtml, BeforeHead, InHead, InHeadNoscript, AfterHead,
    InBody, Text, InTable, InTableText, InCaption, InColumnGroup,
    InTableBody, InRow, InCell, InSelect, InSelectInTable, InTemplate,
    AfterBody, InFrameset, AfterFrameset, AfterAfterBody, AfterAfterFrameset,
}

Active :: struct { node: ^dom.Node, marker: bool }

Builder :: struct {
    tok:            ^Tokenizer,
    doc:            ^dom.Node,
    open:           [dynamic]^dom.Node,
    afe:            [dynamic]Active,
    mode:           Mode,
    original_mode:  Mode,
    head:           ^dom.Node,
    form:           ^dom.Node,
    frameset_ok:    bool,
    quirks:         bool,
    fostering:      bool,
    ignore_lf:      bool,
    pending:        strings.Builder, // in table text
    pending_ns:     bool,            // pending tem não-espaço
    template_modes: [dynamic]Mode,   // pilha de insertion modes de <template>
    ctx:            ^dom.Node,       // elemento de CONTEXTO (só em fragmento; nil = documento)
}

// "adjusted current node": no caso de FRAGMENTO, quando a pilha só tem a raiz
// <html> sintética, quem manda é o elemento de CONTEXTO — é o que faz
// `svgEl.innerHTML = "<rect/>"` parsear em namespace SVG. Fora disso é o topo
// da pilha. (HTML5 §13.2.1: "the adjusted current node".)
@(private = "file")
adjusted_current :: proc(b: ^Builder) -> ^dom.Node {
    if b.ctx != nil && len(b.open) == 1 do return b.ctx
    return cur(b)
}

// preprocessing do input stream: descarta UM BOM inicial (U+FEFF) + CR/CRLF → LF.
// O BOM é removido na detecção de encoding (HTML5 §13.2.3.5 / §12.2.3.2): "One
// leading U+FEFF BYTE ORDER MARK must be ignored". Sem isso o BOM vira um token
// de caractere não-espaço, ABRE o <body> cedo e joga <title>/<meta>/<style> pra
// dentro do body — quebrou 5 reftests do WPT com BOM (counter-001..003 etc.).
@(private = "file")
preprocess_cr :: proc(input0: string) -> string {
    input0 := input0
    // BOM = U+FEFF = bytes EF BB BF (evita-se o literal: o compilador Odin recusa
    // um BOM no meio do arquivo-fonte).
    if len(input0) >= 3 && input0[0] == 0xEF && input0[1] == 0xBB && input0[2] == 0xBF {
        input0 = input0[3:]
    }
    if strings.index_byte(input0, '\r') < 0 do return input0
    nb := strings.builder_make()
    k := 0
    for k < len(input0) {
        if input0[k] == '\r' {
            strings.write_byte(&nb, '\n')
            if k + 1 < len(input0) && input0[k + 1] == '\n' do k += 1
        } else {
            strings.write_byte(&nb, input0[k])
        }
        k += 1
    }
    return strings.to_string(nb)
}

// laço principal: bombeia tokens até o EOF.
@(private = "file")
tb_run :: proc(b: ^Builder) {
    for {
        // CDATA sections só valem quando o adjusted current node é estrangeiro
        b.tok.foreign_ok = len(b.open) > 0 && adjusted_current(b).ns != ""
        tok := tok_next(b.tok)
        tb_process(b, tok)
        eof := tok.kind == .EOF
        token_destroy(&tok) // tudo que foi p/ a árvore já foi CLONADO lá dentro
        if eof do break
    }
}

// Libera o ANDAIME do parse: as pilhas do builder e a fila do tokenizador. Nada
// disto vai para a árvore — a árvore só recebe cópias. Sem isto cada parse
// vazava a fila de tokens (~1,2 KiB) + as pilhas, o que em `el.innerHTML=…` (um
// parse INTEIRO por atribuição) virava vazamento por atribuição.
@(private = "file")
parse_teardown :: proc(b: ^Builder) {
    // tokens que sobraram na fila (o laço só drena até o EOF)
    for &tok in b.tok.q do token_destroy(&tok)
    delete(b.tok.q)
    delete(b.open)
    delete(b.afe)
    delete(b.template_modes)
    strings.builder_destroy(&b.pending)
}

// Ponto de entrada: HTML → Document (com esqueleto html/head/body).
parse_document :: proc(input0: string) -> ^dom.Node {
    t := Tokenizer{input = preprocess_cr(input0), state = .Data}
    b := Builder{tok = &t, doc = dom.make_node(.Document), frameset_ok = true, pending = strings.builder_make()}
    tb_run(&b)
    parse_teardown(&b)
    return b.doc
}

// Descasca `<![CDATA[ ... ]]>` do texto cru de <style>/<script>. É a convenção
// XHTML (`<style><![CDATA[ div{...} ]]></style>`), comum nas REFERÊNCIAS .xht do
// WPT. Em HTML5 esse invólucro é TEXTO literal (o parse_document o preserva, por
// conformância com o html5lib), mas o nosso parser de CSS não recupera do
// `<![CDATA[` inicial e descarta a folha inteira → a referência não renderiza.
// Passo de PREPARAÇÃO DE RENDER (como o antigo normalize_document): só o pipeline
// visual chama, nunca o --parsetree. Espelha o que o parser legado fazia inline.
@(private = "file")
raw_ptr :: proc(s: string) -> rawptr { return raw_data(s) }

// Prepara a árvore para RENDER (não para conformância). Dois ajustes que o parser
// LEGADO fazia inline e que o parse_document (spec) não faz de propósito:
//   1. style/script: descasca `<![CDATA[ ... ]]>` (idioma XHTML) — senão o CSS
//      não recupera e a folha inteira é descartada.
//   2. texto normal: `sanitize_text` — dropa var.selectors/ZWJ/astral (>U+FFFF,
//      não representáveis no ImWchar de 16 bits do ImGui) e nbsp→espaço. O
//      parse_document emite os codepoints REAIS (correto p/ html5lib); sem este
//      passo eles chegam ao atlas como TOFU. NÃO se aplica a style/script (CSS/JS
//      precisam do texto cru).
@(private = "file")
prepare_render_tree :: proc(n: ^dom.Node) {
    if n.kind == .Element && (n.tag == "style" || n.tag == "script") {
        if len(n.children) == 1 && n.children[0].kind == .Text {
            tn := n.children[0]
            stripped := strip_cdata(tn.text)
            if raw_ptr(stripped) != raw_ptr(tn.text) { // mudou → substitui a posse
                // clonar ANTES do delete: `stripped` é uma fatia DENTRO de tn.text.
                newtext := strings.clone(stripped)
                delete(tn.text)
                tn.text = newtext
            }
        }
        return // conteúdo de style/script é cru: não sanitiza nem recursa
    }
    if n.kind == .Text {
        // sanitize_text devolve a MESMA string quando nada muda, ou uma nova
        // (e libera a antiga) quando dropa algo — a posse já fica correta.
        n.text = sanitize_text(n.text)
        return
    }
    for c in n.children do prepare_render_tree(c)
}

// Ponto de entrada para RENDERIZAÇÃO: parse_document + preparação visual.
// Navegação e --render/--dumplayout/--diagnose/--fetch usam ESTE; o --parsetree
// usa parse_document CRU (conformidade html5lib, sem sanitize nem strip).
parse_render :: proc(input0: string) -> ^dom.Node {
    doc := parse_document(input0)
    prepare_render_tree(doc)
    return doc
}

// Ponto de entrada de FRAGMENTO (innerHTML / insertAdjacentHTML): HTML5 §13.4.
// O resultado depende do elemento de CONTEXTO — `<td>x</td>` sobrevive dentro de
// um <tr> e some dentro de um <div>; `<rect/>` só vira SVG dentro de um <svg>.
// Devolve um Document cujos filhos são os nós do fragmento (mesma forma de
// retorno do parse_document, p/ servir ao serializador e ao setter de innerHTML).
parse_fragment :: proc(input0: string, ctx_tag: string, ctx_ns := "", ctx_form: ^dom.Node = nil) -> ^dom.Node {
    t := Tokenizer{input = preprocess_cr(input0), state = .Data}
    ctx := make_element(ctx_tag, ctx_ns)

    // O estado inicial do tokenizador vem do contexto: o conteúdo de <title> é
    // RCDATA, o de <style>/<script> é cru. Sem isso, `style.innerHTML='a<b'`
    // inventaria um elemento <b>.
    //
    // last_start fica VAZIO de propósito: a "appropriate end tag" é definida
    // contra a última start tag EMITIDA PELO TOKENIZER, e no fragmento nenhuma
    // foi (§13.4 só seta o estado). Logo `</script>`/`</title>` do input NÃO
    // fecham nada — `script.innerHTML='<!-- </script> -->'` é TODO texto.
    // (raw_text_close/script_close com last vazio devolvem -1 = nunca fecha.)
    if ctx_ns == "" {
        switch ctx_tag {
        case "title", "textarea":                       t.state = .RCDATA
        case "style", "xmp", "iframe", "noembed", "noframes": t.state = .RAWTEXT
        case "script":                                  t.state = .ScriptData
        case "plaintext":                               t.state = .PLAINTEXT
        // "noscript" ficaria RAWTEXT com scripting LIGADO; o resto do treebuild
        // assume scripting desligado (tem modo InHeadNoscript), então mantemos.
        }
    }

    b := Builder{tok = &t, doc = dom.make_node(.Document), frameset_ok = true, pending = strings.builder_make()}
    b.ctx = ctx

    // raiz <html> sintética: recebe tudo e no fim é descascada.
    root := make_element("html")
    dom_insert(b.doc, root, nil)
    append(&b.open, root)

    if ctx_ns == "" && ctx_tag == "template" do append(&b.template_modes, Mode.InTemplate)
    b.form = ctx_form // form pointer = o <form> ancestral do contexto, se houver
    reset_insertion_mode(&b)

    tb_run(&b)

    // descasca a raiz: os filhos dela SÃO o fragmento.
    kids := dom.kids_take(root) // cópia do CABEÇALHO; o backing store é o mesmo
    for k in kids do k.parent = b.doc

    // O que estiver pendurado DIRETO no doc não é fragmento: a raiz <html>
    // sintética e, nos modos "after after", comentários. O `clear` abaixo
    // descartava tudo isso em SILÊNCIO (a raiz + o `tag` dela + o array de
    // filhos = 2 dos blocos vazados por atribuição de innerHTML).
    for c in b.doc.children do dom.free_tree(c) // root.children já é nil: não toca em kids
    dom.kids_clear(b.doc)
    dom.kids_append_many(b.doc, kids[:]) // copia os ponteiros
    delete(kids)                         // …então o array velho da raiz pode ir

    // O elemento de CONTEXTO nunca entra na árvore (só serve de referência p/ o
    // adjusted current node e p/ reset_insertion_mode) — ninguém o libera senão aqui.
    dom.free_tree(ctx)
    parse_teardown(&b)
    return b.doc
}

@(private = "file")
tb_process :: proc(b: ^Builder, tok: Token) {
    if tok.kind == .Char {
        data := tok.data
        if b.ignore_lf {
            b.ignore_lf = false
            if len(data) > 0 && data[0] == '\n' do data = data[1:]
        }
        if len(data) == 0 do return
        fc := use_foreign_char(b)
        // CAMINHO EM LOTE: onde o dispatch por rune não decide NADA além de
        // inserir, o run inteiro entra de uma vez (ver insert_text).
        if !fc {
            #partial switch b.mode {
            case .Text:
                insert_text(b, data)
                return
            case .InBody, .InCaption, .InCell, .InTemplate:
                // NUL é descartado POR RUNE; no caso raro de haver um no run,
                // cai no laço abaixo em vez de filtrar. O reconstruct do AFE é
                // no-op depois do 1º (os elementos já estão na pilha), então
                // uma chamada antes do run equivale a uma por rune.
                if strings.index_byte(data, 0) < 0 {
                    reconstruct_afe(b)
                    insert_text(b, data)
                    for r in data do if !is_ws(r) { b.frameset_ok = false; break }
                    return
                }
            }
        }
        for r in data {
            if fc { foreign_char(b, r) }
            else { for tb_char(b, r) {} }
        }
        return
    }
    b.ignore_lf = false
    for {
        rp: bool
        if use_foreign_token(b, tok) { rp = foreign_token(b, tok) }
        else { rp = tb_token(b, tok) }
        if !rp do break
    }
}

// ── helpers de pilha / DOM ──

@(private = "file") cur :: proc(b: ^Builder) -> ^dom.Node { return b.open[len(b.open) - 1] }

// Desempilha o current node, mas NUNCA esvazia a pilha. No caso de FRAGMENTO os
// modos escritos p/ documento mandam coisas como "pop the current node (which
// will be the head element)" — só que o fundo da pilha é a raiz <html>
// sintética, e popá-la deixa a pilha vazia: todo cur() seguinte estoura
// (foi o crash de `head.innerHTML='<title>x</title>'`). A spec assume que a raiz
// está sempre lá; em documento nenhuma regra pop a <html>, então o guarda é
// inócuo fora do fragmento.
@(private = "file")
pop_open :: proc(b: ^Builder) -> ^dom.Node {
    if len(b.open) <= 1 do return nil
    return pop(&b.open)
}

@(private = "file")
make_element :: proc(name: string, ns := "") -> ^dom.Node {
    el := dom.make_node(.Element)
    el.tag = strings.clone(name)
    el.ns = ns
    el.attrs = make(map[string]string)
    return el
}

// Copia os atributos de um token para `el` na ORDEM DE DOCUMENTO (tok.attr_order),
// via dom.set_attr — que mantém `attr_order` no nó. Escrever direto em el.attrs
// (como se fazia) deixava attr_order VAZIO e getAttributeNames() caía na iteração
// não-determinística do map do Odin: o lit-html pareia essa lista posicionalmente
// e quebrava (regressão pega pelos testes m131 ao plugar isto no innerHTML).
// `if k not_in`: token pode repetir atributo; o 1º vence (spec).
@(private = "file")
apply_token_attrs :: proc(el: ^dom.Node, tok: Token) {
    for k in tok.attr_order {
        if k in el.attrs do continue
        dom.set_attr(el, strings.clone(k), strings.clone(tok.attrs[k]))
    }
}

@(private = "file")
clone_element :: proc(src: ^dom.Node) -> ^dom.Node {
    el := make_element(src.tag, src.ns)
    // preserva a ordem de documento da fonte (usado no reconstruct do afe)
    for k in src.attr_order do dom.set_attr(el, strings.clone(k), strings.clone(src.attrs[k]))
    return el
}

@(private = "file")
dom_insert :: proc(parent, node, ref: ^dom.Node) {
    node.parent = parent
    if ref == nil {
        dom.kids_append(parent, node)
        return
    }
    idx := len(parent.children)
    for c, i in parent.children do if c == ref { idx = i; break }
    dom.kids_insert(parent, idx, node)
}

@(private = "file")
is_table_ctx :: proc(n: ^dom.Node) -> bool {
    if n.ns != "" do return false
    switch n.tag { case "table", "tbody", "tfoot", "thead", "tr": return true }
    return false
}

@(private = "file")
last_table_index :: proc(b: ^Builder) -> int {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        if b.open[i].ns == "" && b.open[i].tag == "table" do return i
    }
    return -1
}

@(private = "file")
foster_target :: proc(b: ^Builder) -> (^dom.Node, ^dom.Node) {
    lt := last_table_index(b)
    if lt < 0 do return b.open[0], nil
    table := b.open[lt]
    if table.parent != nil do return table.parent, table
    return b.open[lt - 1], nil
}

@(private = "file")
insertion_place :: proc(b: ^Builder) -> (^dom.Node, ^dom.Node) {
    target := cur(b)
    if b.fostering && is_table_ctx(target) do return foster_target(b)
    // conteúdo de <template> vai para o document-fragment "content"
    if target.ns == "" && target.tag == "template" && len(target.children) > 0 && target.children[0].tag == "#content" {
        return target.children[0], nil
    }
    return target, nil
}

@(private = "file")
insert_from_token :: proc(b: ^Builder, tok: Token, ns := "") -> ^dom.Node {
    el := make_element(tok.name, ns)
    apply_token_attrs(el, tok)
    parent, ref := insertion_place(b)
    dom_insert(parent, el, ref)
    append(&b.open, el)
    return el
}

@(private = "file")
insert_named :: proc(b: ^Builder, name: string) -> ^dom.Node {
    el := make_element(name)
    parent, ref := insertion_place(b)
    dom_insert(parent, el, ref)
    append(&b.open, el)
    return el
}

// Anexa um RUN de texto no ponto de inserção; insert_char é o caso de uma rune.
// Anexar rune a rune refazia o concatenate sobre o nó INTEIRO a cada caractere:
// O(L²) em cópias, e cada estado intermediário VAZAVA (~L²/2 bytes no total).
// Como o corpo de <script>/<style> chega como UM token de caractere, L é o
// arquivo todo — 80KB de JSON inline custavam 1,3 s.
@(private = "file")
insert_text :: proc(b: ^Builder, s: string) {
    if len(s) == 0 do return
    parent, ref := insertion_place(b)
    // nó imediatamente antes do ponto de inserção
    prev: ^dom.Node
    if ref == nil {
        if len(parent.children) > 0 do prev = parent.children[len(parent.children) - 1]
    } else {
        for c, i in parent.children do if c == ref { if i > 0 do prev = parent.children[i - 1]; break }
    }
    if prev != nil && prev.kind == .Text {
        old := prev.text
        prev.text = strings.concatenate({old, s})
        delete(old) // já copiado, e durante o parse ninguém mais aponta p/ ele
        return
    }
    tn := dom.make_node(.Text)
    tn.text = strings.clone(s)
    dom_insert(parent, tn, ref)
}

@(private = "file")
insert_char :: proc(b: ^Builder, r: rune) {
    bytes, w := utf8.encode_rune(r)
    insert_text(b, string(bytes[:w]))
}

@(private = "file")
insert_comment :: proc(b: ^Builder, data: string) {
    c := dom.make_node(.Comment)
    c.text = strings.clone(data)
    parent, ref := insertion_place(b)
    dom_insert(parent, c, ref)
}

@(private = "file")
insert_comment_to :: proc(parent: ^dom.Node, data: string) {
    c := dom.make_node(.Comment)
    c.text = strings.clone(data)
    dom.append_child(parent, c)
}

@(private = "file")
insert_doctype :: proc(b: ^Builder, tok: Token) {
    d := dom.make_node(.Element)
    d.tag = strings.clone("!doctype")
    inner := strings.builder_make()
    strings.write_string(&inner, tok.name)
    if tok.has_pub || tok.has_sys {
        strings.write_string(&inner, " \"")
        strings.write_string(&inner, tok.pub_id)
        strings.write_string(&inner, "\" \"")
        strings.write_string(&inner, tok.sys_id)
        strings.write_string(&inner, "\"")
    }
    d.text = strings.to_string(inner)
    dom.append_child(b.doc, d)
}

// ── procura por template na pilha (afeta html/body attrs merge etc.) ──
@(private = "file")
has_template :: proc(b: ^Builder) -> bool {
    for e in b.open do if e.ns == "" && e.tag == "template" do return true
    return false
}

// ── escopos ──
@(private = "file")
scope_stop_default :: proc(n: ^dom.Node) -> bool {
    if n.ns == "svg" {
        switch n.tag { case "foreignobject", "desc", "title": return true }
        return false
    }
    if n.ns == "math" {
        switch n.tag { case "mi", "mo", "mn", "ms", "mtext", "annotation-xml": return true }
        return false
    }
    switch n.tag {
    case "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template":
        return true
    }
    return false
}

@(private = "file")
has_in_scope :: proc(b: ^Builder, tag: string) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && n.tag == tag do return true
        if scope_stop_default(n) do return false
    }
    return false
}

@(private = "file")
has_node_in_scope :: proc(b: ^Builder, node: ^dom.Node) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n == node do return true
        if scope_stop_default(n) do return false
    }
    return false
}

@(private = "file")
has_in_button_scope :: proc(b: ^Builder, tag: string) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && n.tag == tag do return true
        if n.ns == "" && n.tag == "button" do return false
        if scope_stop_default(n) do return false
    }
    return false
}

@(private = "file")
has_in_list_scope :: proc(b: ^Builder, tag: string) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && n.tag == tag do return true
        if n.ns == "" && (n.tag == "ol" || n.tag == "ul") do return false
        if scope_stop_default(n) do return false
    }
    return false
}

@(private = "file")
has_heading_in_scope :: proc(b: ^Builder) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && is_heading(n.tag) do return true
        if scope_stop_default(n) do return false
    }
    return false
}

@(private = "file")
has_in_table_scope :: proc(b: ^Builder, tag: string) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && n.tag == tag do return true
        if n.ns == "" && (n.tag == "html" || n.tag == "table" || n.tag == "template") do return false
    }
    return false
}

@(private = "file")
has_in_select_scope :: proc(b: ^Builder, tag: string) -> bool {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        n := b.open[i]
        if n.ns == "" && n.tag == tag do return true
        if !(n.ns == "" && (n.tag == "optgroup" || n.tag == "option")) do return false
    }
    return false
}

@(private = "file")
is_heading :: proc(tag: string) -> bool {
    switch tag { case "h1", "h2", "h3", "h4", "h5", "h6": return true }
    return false
}

// ── implied end tags, pops ──
@(private = "file")
generate_implied_end_tags :: proc(b: ^Builder, except := "") {
    for len(b.open) > 0 {
        t := cur(b)
        if t.ns != "" do break
        stop := true
        switch t.tag {
        case "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc":
            stop = false
        }
        if stop || t.tag == except do break
        pop_open(b)
    }
}

@(private = "file")
pop_until :: proc(b: ^Builder, tag: string) {
    for len(b.open) > 0 {
        n := pop_open(b)
        if n.ns == "" && n.tag == tag do break
    }
}

@(private = "file")
pop_until_heading :: proc(b: ^Builder) {
    for len(b.open) > 0 {
        n := pop_open(b)
        if n.ns == "" && is_heading(n.tag) do break
    }
}

@(private = "file")
close_p :: proc(b: ^Builder) {
    generate_implied_end_tags(b, "p")
    pop_until(b, "p")
}

// ── special elements (para adoption / "any other end tag") ──
@(private = "file")
is_special :: proc(n: ^dom.Node) -> bool {
    if n.ns == "math" {
        switch n.tag { case "mi", "mo", "mn", "ms", "mtext", "annotation-xml": return true }
        return false
    }
    if n.ns == "svg" {
        switch n.tag { case "foreignobject", "desc", "title": return true }
        return false
    }
    switch n.tag {
    case "address", "applet", "area", "article", "aside", "base", "basefont",
        "bgsound", "blockquote", "body", "br", "button", "caption", "center",
        "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
        "html", "iframe", "img", "input", "keygen", "li", "link", "listing",
        "main", "marquee", "menu", "meta", "nav", "noembed", "noframes",
        "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script",
        "section", "select", "source", "style", "summary", "table", "tbody",
        "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr",
        "track", "ul", "wbr", "xmp":
        return true
    }
    return false
}

@(private = "file")
is_formatting :: proc(tag: string) -> bool {
    switch tag {
    case "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small",
        "strike", "strong", "tt", "u":
        return true
    }
    return false
}

// ── active formatting elements ──
@(private = "file")
afe_index_of :: proc(b: ^Builder, node: ^dom.Node) -> int {
    for i := len(b.afe) - 1; i >= 0; i -= 1 {
        if !b.afe[i].marker && b.afe[i].node == node do return i
    }
    return -1
}

@(private = "file")
in_open :: proc(b: ^Builder, node: ^dom.Node) -> bool {
    for e in b.open do if e == node do return true
    return false
}

@(private = "file")
open_index :: proc(b: ^Builder, node: ^dom.Node) -> int {
    for e, i in b.open do if e == node do return i
    return -1
}

@(private = "file")
insert_marker :: proc(b: ^Builder) { append(&b.afe, Active{marker = true}) }

@(private = "file")
clear_afe_to_marker :: proc(b: ^Builder) {
    for len(b.afe) > 0 {
        e := pop(&b.afe)
        if e.marker do break
    }
}

@(private = "file")
same_element :: proc(a, c: ^dom.Node) -> bool {
    if a.ns != c.ns || a.tag != c.tag do return false
    if len(a.attrs) != len(c.attrs) do return false
    for k, v in a.attrs {
        cv, ok := c.attrs[k]
        if !ok || cv != v do return false
    }
    return true
}

@(private = "file")
push_afe :: proc(b: ^Builder, el: ^dom.Node) {
    // Noah's Ark: no máximo 3 iguais após o último marcador
    count := 0
    earliest := -1
    for i := len(b.afe) - 1; i >= 0; i -= 1 {
        if b.afe[i].marker do break
        if same_element(b.afe[i].node, el) { count += 1; earliest = i }
    }
    if count >= 3 do ordered_remove(&b.afe, earliest)
    append(&b.afe, Active{node = el})
}

@(private = "file")
reconstruct_afe :: proc(b: ^Builder) {
    if len(b.afe) == 0 do return
    last := b.afe[len(b.afe) - 1]
    if last.marker || in_open(b, last.node) do return
    i := len(b.afe) - 1
    for i > 0 {
        e := b.afe[i - 1]
        if e.marker || in_open(b, e.node) do break
        i -= 1
    }
    for i < len(b.afe) {
        e := b.afe[i]
        nel := clone_element(e.node)
        parent, ref := insertion_place(b)
        dom_insert(parent, nel, ref)
        append(&b.open, nel)
        b.afe[i].node = nel
        i += 1
    }
}

@(private = "file")
reparent :: proc(parent, child: ^dom.Node) {
    if child.parent != nil {
        for c, i in child.parent.children do if c == child { dom.kids_remove_at(child.parent, i); break }
    }
    dom.append_child(parent, child)
}

// Adoption agency algorithm. Devolve true se o token deve ser tratado como
// "qualquer outra end tag" (fim precoce sem match).
@(private = "file")
adoption_agency :: proc(b: ^Builder, subject: string) -> bool {
    cn := cur(b)
    if cn.ns == "" && cn.tag == subject && afe_index_of(b, cn) < 0 {
        pop_open(b)
        return false
    }
    for outer := 0; outer < 8; outer += 1 {
        // formatting element: último na AFE após o último marcador com tag==subject
        fe_idx := -1
        for i := len(b.afe) - 1; i >= 0; i -= 1 {
            if b.afe[i].marker do break
            if b.afe[i].node.ns == "" && b.afe[i].node.tag == subject { fe_idx = i; break }
        }
        if fe_idx < 0 do return true // sem match → any-other-end-tag
        fe := b.afe[fe_idx].node
        fe_oi := open_index(b, fe)
        if fe_oi < 0 {
            ordered_remove(&b.afe, fe_idx)
            return false
        }
        if !has_node_in_scope(b, fe) do return false
        // furthest block: primeiro special abaixo de fe
        fb_idx := -1
        for i := fe_oi + 1; i < len(b.open); i += 1 {
            if is_special(b.open[i]) { fb_idx = i; break }
        }
        if fb_idx < 0 {
            for len(b.open) > fe_oi do pop_open(b)
            ordered_remove(&b.afe, fe_idx)
            return false
        }
        fb := b.open[fb_idx]
        ca := b.open[fe_oi - 1]
        bookmark := fe_idx
        last_node := fb
        node_oi := fb_idx
        for inner := 0; ; inner += 1 {
            node_oi -= 1
            if node_oi < 0 do break
            node := b.open[node_oi]
            if node == fe do break
            node_afe := afe_index_of(b, node)
            if inner >= 3 && node_afe >= 0 {
                ordered_remove(&b.afe, node_afe)
                if node_afe < bookmark do bookmark -= 1
                node_afe = -1
            }
            if node_afe < 0 {
                ordered_remove(&b.open, node_oi)
                continue
            }
            clone := clone_element(node)
            b.afe[node_afe].node = clone
            b.open[node_oi] = clone
            node = clone
            if last_node == fb do bookmark = node_afe + 1
            reparent(node, last_node)
            last_node = node
        }
        // insere last_node no lugar apropriado do common ancestor
        if last_node.parent != nil {
            for c, i in last_node.parent.children do if c == last_node { dom.kids_remove_at(last_node.parent, i); break }
        }
        if is_table_ctx(ca) {
            p, r := foster_target(b)
            dom_insert(p, last_node, r)
        } else {
            dom.append_child(ca, last_node)
        }
        // clone de fe recebe os filhos de fb
        fe_clone := clone_element(fe)
        for len(fb.children) > 0 {
            ch := fb.children[0]
            dom.kids_remove_at(fb, 0)
            dom.append_child(fe_clone, ch)
        }
        dom.append_child(fb, fe_clone)
        // AFE: remove fe, insere fe_clone no bookmark
        ordered_remove(&b.afe, fe_idx)
        if fe_idx < bookmark do bookmark -= 1
        if bookmark < 0 do bookmark = 0
        if bookmark > len(b.afe) do bookmark = len(b.afe)
        inject_at(&b.afe, bookmark, Active{node = fe_clone})
        // open: remove fe, insere fe_clone logo abaixo de fb
        roi := open_index(b, fe)
        if roi >= 0 do ordered_remove(&b.open, roi)
        fbn := open_index(b, fb)
        inject_at(&b.open, fbn + 1, fe_clone)
    }
    return false
}

// ── reset the insertion mode appropriately ──
@(private = "file")
reset_insertion_mode :: proc(b: ^Builder) {
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        node := b.open[i]
        last := i == 0
        // Fragmento: ao chegar na raiz sintética, quem decide o modo é o
        // elemento de CONTEXTO — é assim que `tbody.innerHTML='<tr>'` entra em
        // InRow em vez de InBody (onde <tr> seria simplesmente ignorado).
        if last && b.ctx != nil do node = b.ctx
        if node.ns != "" {
            if last { b.mode = .InBody; return }
            continue
        }
        switch node.tag {
        case "select":
            in_tbl := false
            for j := i - 1; j > 0; j -= 1 {
                if b.open[j].ns == "" && b.open[j].tag == "template" do break
                if b.open[j].ns == "" && b.open[j].tag == "table" { in_tbl = true; break }
            }
            b.mode = .InSelectInTable if in_tbl else .InSelect
            return
        case "td", "th":
            if !last { b.mode = .InCell; return }
        case "tr": b.mode = .InRow; return
        case "tbody", "thead", "tfoot": b.mode = .InTableBody; return
        case "caption": b.mode = .InCaption; return
        case "colgroup": b.mode = .InColumnGroup; return
        case "table": b.mode = .InTable; return
        case "template":
            b.mode = b.template_modes[len(b.template_modes) - 1] if len(b.template_modes) > 0 else .InBody
            return
        case "head": b.mode = .InHead; return
        case "body": b.mode = .InBody; return
        case "frameset": b.mode = .InFrameset; return
        case "html":
            b.mode = .BeforeHead if b.head == nil else .AfterHead
            return
        }
        if last { b.mode = .InBody; return }
    }
}

// ── quirks a partir do DOCTYPE (subconjunto) ──
@(private = "file")
compute_quirks :: proc(tok: Token) -> bool {
    if tok.force_quirks do return true
    if !tok.has_name || tok.name != "html" do return true
    if tok.has_pub {
        pl := strings.to_lower(tok.pub_id); defer delete(pl)
        quirky := []string{
            "-//w3o//dtd w3 html strict 3.0//en//", "-/w3c/dtd html 4.0 transitional/en",
            "html", "+//silmaril//dtd html pro v0r11 19970101//",
            "-//as//dtd html 3.0 aswedit + extensions//", "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
            "-//ietf//dtd html 2.0 level 1//", "-//ietf//dtd html 2.0 level 2//",
            "-//ietf//dtd html 2.0 strict level 1//", "-//ietf//dtd html 2.0 strict level 2//",
            "-//ietf//dtd html 2.0 strict//", "-//ietf//dtd html 2.0//",
            "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//", "-//ietf//dtd html 3.2 final//",
            "-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//", "-//ietf//dtd html level 0//",
            "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//", "-//ietf//dtd html level 3//",
            "-//ietf//dtd html strict level 0//", "-//ietf//dtd html strict level 1//",
            "-//ietf//dtd html strict level 2//", "-//ietf//dtd html strict level 3//",
            "-//ietf//dtd html strict//", "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//",
            "-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//",
            "-//microsoft//dtd internet explorer 2.0 tables//", "-//microsoft//dtd internet explorer 3.0 html strict//",
            "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//",
            "-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//",
            "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//",
            "-//o'reilly and associates//dtd html extended relaxed 1.0//",
            "-//sq//dtd html 2.0 hotmetal + extensions//", "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
            "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
            "-//spyglass//dtd html 2.0 extended//", "-//sun microsystems corp.//dtd hotjava html//",
            "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//",
            "-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//",
            "-//w3c//dtd html 3.2s draft//", "-//w3c//dtd html 4.0 frameset//", "-//w3c//dtd html 4.0 transitional//",
            "-//w3c//dtd html experimental 19960712//", "-//w3c//dtd html experimental 970421//",
            "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//", "-//webtechs//dtd mozilla html 2.0//",
            "-//webtechs//dtd mozilla html//",
        }
        for q in quirky do if strings.has_prefix(pl, q) do return true
        if !tok.has_sys {
            if strings.has_prefix(pl, "-//w3c//dtd html 4.01 frameset//") do return true
            if strings.has_prefix(pl, "-//w3c//dtd html 4.01 transitional//") do return true
        }
        // Nota: "-//W3C//DTD XHTML 1.0 Frameset//" e "…Transitional//" são
        // LIMITED-quirks (almost standards), NÃO full quirks — não entram aqui.
    }
    if tok.has_sys {
        sl := strings.to_lower(tok.sys_id); defer delete(sl)
        if sl == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd" do return true
    }
    return false
}

@(private = "file")
is_ws :: proc(r: rune) -> bool {
    return r == ' ' || r == '\t' || r == '\n' || r == '\f' || r == '\r'
}

// ─────────────────────── dispatch de CHARACTER tokens ───────────────────────
// Devolve true se o caractere deve ser reprocessado (após mudar de mode).
@(private = "file")
tb_char :: proc(b: ^Builder, r: rune) -> bool {
    switch b.mode {
    case .Initial:
        if is_ws(r) do return false
        b.quirks = true
        b.mode = .BeforeHtml
        return true
    case .BeforeHtml:
        if is_ws(r) do return false
        el := make_element("html")
        dom.append_child(b.doc, el)
        append(&b.open, el)
        b.mode = .BeforeHead
        return true
    case .BeforeHead:
        if is_ws(r) do return false
        b.head = insert_named(b, "head")
        b.mode = .InHead
        return true
    case .InHead:
        if is_ws(r) { insert_char(b, r); return false }
        pop_open(b) // pop head
        b.mode = .AfterHead
        return true
    case .InHeadNoscript:
        if is_ws(r) { insert_char(b, r); return false }
        pop_open(b) // pop noscript
        b.mode = .InHead
        return true
    case .AfterHead:
        if is_ws(r) { insert_char(b, r); return false }
        insert_named(b, "body")
        b.mode = .InBody
        return true
    case .InBody, .InCaption, .InCell, .InTemplate:
        if r == 0 do return false
        reconstruct_afe(b)
        insert_char(b, r)
        if !is_ws(r) do b.frameset_ok = false
        return false
    case .Text:
        insert_char(b, r)
        return false
    case .InTable, .InTableBody, .InRow:
        if r == 0 do return false
        // A regra de caractere de "in table" só entra no buffer se o CURRENT node
        // for table-ish; senão (ex.: dentro de um MathML text integration point
        // foster-parented) é "anything else": foster + regras de in body.
        cn := cur(b)
        if cn.ns == "" && (cn.tag == "table" || cn.tag == "tbody" || cn.tag == "tfoot" || cn.tag == "thead" || cn.tag == "tr") {
            strings.builder_reset(&b.pending)
            b.pending_ns = false
            b.original_mode = b.mode
            b.mode = .InTableText
            return true
        }
        b.fostering = true
        reconstruct_afe(b)
        insert_char(b, r)
        if !is_ws(r) do b.frameset_ok = false
        b.fostering = false
        return false
    case .InTableText:
        if r == 0 do return false
        strings.write_rune(&b.pending, r)
        if !is_ws(r) do b.pending_ns = true
        return false
    case .InColumnGroup:
        if is_ws(r) { insert_char(b, r); return false }
        if !(cur(b).ns == "" && cur(b).tag == "colgroup") do return false
        pop_open(b)
        b.mode = .InTable
        return true
    case .InSelect, .InSelectInTable:
        if r == 0 do return false
        insert_char(b, r)
        return false
    case .AfterBody:
        if is_ws(r) {
            reconstruct_afe(b)
            insert_char(b, r)
            return false
        }
        b.mode = .InBody
        return true
    case .InFrameset:
        if is_ws(r) do insert_char(b, r)
        return false
    case .AfterFrameset:
        if is_ws(r) do insert_char(b, r)
        return false
    case .AfterAfterBody:
        if is_ws(r) {
            reconstruct_afe(b)
            insert_char(b, r)
            return false
        }
        b.mode = .InBody
        return true
    case .AfterAfterFrameset:
        if is_ws(r) do insert_char(b, r)
        return false
    }
    return false
}

// Flush do buffer de "in table text".
@(private = "file")
flush_table_text :: proc(b: ^Builder) {
    text := strings.to_string(b.pending)
    if len(text) == 0 do return
    if b.pending_ns {
        // reprocessa como "in table anything else": foster parenting
        b.fostering = true
        reconstruct_afe(b) // no-op após o 1º; era chamado por rune
        insert_text(b, text)
        b.fostering = false
    } else {
        insert_text(b, text)
    }
    strings.builder_reset(&b.pending)
    b.pending_ns = false
}

// ── helpers de inserção de texto cru / delegação ──
@(private = "file")
create_html_from_token :: proc(b: ^Builder, tok: Token) -> ^dom.Node {
    el := make_element("html")
    apply_token_attrs(el, tok)
    dom.append_child(b.doc, el)
    append(&b.open, el)
    return el
}

@(private = "file")
start_rcdata :: proc(b: ^Builder, tok: Token) {
    el := insert_from_token(b, tok)
    b.tok.state = .RCDATA; b.tok.last_start = el.tag
    b.original_mode = b.mode; b.mode = .Text
}
@(private = "file")
start_rawtext :: proc(b: ^Builder, tok: Token) {
    el := insert_from_token(b, tok)
    b.tok.state = .RAWTEXT; b.tok.last_start = el.tag
    b.original_mode = b.mode; b.mode = .Text
}
@(private = "file")
start_script :: proc(b: ^Builder, tok: Token) {
    el := insert_from_token(b, tok)
    b.tok.state = .ScriptData; b.tok.last_start = el.tag
    b.original_mode = b.mode; b.mode = .Text
}
@(private = "file")
open_template :: proc(b: ^Builder, tok: Token) {
    el := insert_from_token(b, tok)
    // document-fragment "content" (serializado como `content`)
    content := dom.make_node(.Element)
    content.tag = strings.clone("#content")
    dom.append_child(el, content)
    insert_marker(b)
    b.frameset_ok = false
    append(&b.template_modes, Mode.InTemplate)
    b.mode = .InTemplate
}
@(private = "file")
close_template :: proc(b: ^Builder) {
    if !has_template(b) do return
    generate_implied_end_tags(b)
    pop_until(b, "template")
    clear_afe_to_marker(b)
    if len(b.template_modes) > 0 do pop(&b.template_modes)
    reset_insertion_mode(b)
}
@(private = "file")
switch_template_mode :: proc(b: ^Builder, m: Mode) {
    if len(b.template_modes) > 0 do pop(&b.template_modes)
    append(&b.template_modes, m)
    b.mode = m
}

@(private = "file")
insert_void :: proc(b: ^Builder, tok: Token) {
    insert_from_token(b, tok)
    pop_open(b)
}
@(private = "file")
insert_void_named :: proc(b: ^Builder, name: string) {
    insert_named(b, name)
    pop_open(b)
}

// ─────────────────────── dispatch de tokens não-Char ────────────────────────
@(private = "file")
tb_token :: proc(b: ^Builder, tok: Token) -> bool {
    switch b.mode {
    case .Initial:
        #partial switch tok.kind {
        case .Comment: insert_comment_to(b.doc, tok.data); return false
        case .Doctype:
            insert_doctype(b, tok); b.quirks = compute_quirks(tok); b.mode = .BeforeHtml; return false
        }
        b.quirks = true
        b.mode = .BeforeHtml
        return true

    case .BeforeHtml:
        #partial switch tok.kind {
        case .Doctype: return false
        case .Comment: insert_comment_to(b.doc, tok.data); return false
        case .StartTag:
            if tok.name == "html" { create_html_from_token(b, tok); b.mode = .BeforeHead; return false }
        case .EndTag:
            switch tok.name { case "head", "body", "html", "br": // anything else
            case: return false }
        }
        el := make_element("html"); dom.append_child(b.doc, el); append(&b.open, el)
        b.mode = .BeforeHead
        return true

    case .BeforeHead:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "head": b.head = insert_from_token(b, tok); b.mode = .InHead; return false
            }
        case .EndTag:
            switch tok.name { case "head", "body", "html", "br": // anything else
            case: return false }
        }
        b.head = insert_named(b, "head"); b.mode = .InHead
        return true

    case .InHead:
        return tb_inhead(b, tok)

    case .InHeadNoscript:
        #partial switch tok.kind {
        case .Doctype: return false
        case .Comment: return tb_inhead(b, tok)
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "basefont", "bgsound", "link", "meta", "noframes", "style": return tb_inhead(b, tok)
            case "head", "noscript": return false
            }
            pop_open(b); b.mode = .InHead; return true
        case .EndTag:
            switch tok.name {
            case "noscript": pop_open(b); b.mode = .InHead; return false
            case "br": pop_open(b); b.mode = .InHead; return true
            }
            return false
        case .EOF:
            pop_open(b); b.mode = .InHead; return true
        }
        return false

    case .AfterHead:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "body": insert_from_token(b, tok); b.frameset_ok = false; b.mode = .InBody; return false
            case "frameset": insert_from_token(b, tok); b.mode = .InFrameset; return false
            case "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title":
                append(&b.open, b.head)
                tb_inhead(b, tok)
                for i := len(b.open) - 1; i >= 0; i -= 1 do if b.open[i] == b.head { ordered_remove(&b.open, i); break }
                return false
            case "head": return false
            }
        case .EndTag:
            switch tok.name {
            case "template": return tb_inhead(b, tok)
            case "body", "html", "br": // anything else
            case: return false
            }
        case .EOF:
            // Num FRAGMENTO cujo contexto NÃO é <html> (ex.: `head.innerHTML=
            // '<title>x</title>'`) o fim do input não pode materializar um
            // <body>: chegamos em AfterHead só porque InHead tentou popar um
            // <head> que não está na pilha — o body seria artefato.
            // Com contexto <html> o fragmento É o miolo de um documento e o
            // par head/body implícito continua correto, como no documento.
            if b.ctx != nil && !(b.ctx.ns == "" && b.ctx.tag == "html") do return false
        }
        insert_named(b, "body"); b.mode = .InBody
        return true

    case .InBody, .InCaption, .InCell:
        // InCaption / InCell têm regras próprias que ANTECEDEM as de InBody
        if b.mode == .InCaption {
            if r, handled := caption_token(b, tok); handled do return r
        }
        if b.mode == .InCell {
            if r, handled := cell_token(b, tok); handled do return r
        }
        return tb_inbody(b, tok)

    case .Text:
        #partial switch tok.kind {
        case .EndTag: pop_open(b); b.mode = b.original_mode; return false
        case .EOF: pop_open(b); b.mode = b.original_mode; return true
        }
        return false

    case .InTable, .InTableText:
        if b.mode == .InTableText {
            flush_table_text(b)
            b.mode = b.original_mode
            return true
        }
        return table_token(b, tok)

    case .InColumnGroup:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "col": insert_void(b, tok); return false
            case "template": return tb_inhead(b, tok)
            }
        case .EndTag:
            switch tok.name {
            case "colgroup":
                if cur(b).ns == "" && cur(b).tag == "colgroup" { pop_open(b); b.mode = .InTable }
                return false
            case "col": return false
            case "template": return tb_inhead(b, tok)
            }
        case .EOF:
            return tb_inbody(b, tok)
        }
        if !(cur(b).ns == "" && cur(b).tag == "colgroup") do return false
        pop_open(b); b.mode = .InTable
        return true

    case .InTableBody:
        return table_body_token(b, tok)

    case .InRow:
        return row_token(b, tok)

    case .InSelect:
        return select_token(b, tok)

    case .InSelectInTable:
        #partial switch tok.kind {
        case .StartTag:
            switch tok.name {
            case "caption", "table", "tbody", "tfoot", "thead", "tr", "td", "th":
                pop_until(b, "select"); reset_insertion_mode(b); return true
            }
        case .EndTag:
            switch tok.name {
            case "caption", "table", "tbody", "tfoot", "thead", "tr", "td", "th":
                if has_in_table_scope(b, tok.name) { pop_until(b, "select"); reset_insertion_mode(b); return true }
                return false
            }
        }
        return select_token(b, tok)

    case .InTemplate:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "base", "basefont", "bgsound", "link", "meta", "noframes",
                "script", "style", "template", "title":
                return tb_inhead(b, tok)
            case "caption", "colgroup", "tbody", "tfoot", "thead":
                switch_template_mode(b, .InTable); return true
            case "col":
                switch_template_mode(b, .InColumnGroup); return true
            case "tr":
                switch_template_mode(b, .InTableBody); return true
            case "td", "th":
                switch_template_mode(b, .InRow); return true
            }
            switch_template_mode(b, .InBody); return true
        case .EndTag:
            if tok.name == "template" do return tb_inhead(b, tok)
            return false
        case .EOF:
            if !has_template(b) do return false
            pop_until(b, "template")
            clear_afe_to_marker(b)
            if len(b.template_modes) > 0 do pop(&b.template_modes)
            reset_insertion_mode(b)
            return true
        }
        return false

    case .AfterBody:
        #partial switch tok.kind {
        case .Comment: insert_comment_to(b.open[0], tok.data); return false
        case .Doctype: return false
        case .StartTag:
            if tok.name == "html" do return tb_inbody(b, tok)
        case .EndTag:
            // "If the parser was created as part of the HTML fragment parsing
            // algorithm, this is a parse error; ignore the token." Sem isto o
            // fragmento cai em AfterAfterBody e um comentário depois de
            // `</html>` vai parar no Document, que o descasque joga fora.
            if tok.name == "html" {
                if b.ctx != nil do return false
                b.mode = .AfterAfterBody; return false
            }
        case .EOF:
            return false
        }
        b.mode = .InBody
        return true

    case .InFrameset:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "frameset": insert_from_token(b, tok); return false
            case "frame": insert_void(b, tok); return false
            case "noframes": return tb_inhead(b, tok)
            }
        case .EndTag:
            if tok.name == "frameset" {
                if !(cur(b).ns == "" && cur(b).tag == "html") {
                    pop_open(b)
                    if !(cur(b).ns == "" && cur(b).tag == "frameset") do b.mode = .AfterFrameset
                }
                return false
            }
        case .EOF:
            return false
        }
        return false

    case .AfterFrameset:
        #partial switch tok.kind {
        case .Comment: insert_comment(b, tok.data); return false
        case .Doctype: return false
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "noframes": return tb_inhead(b, tok)
            }
        case .EndTag:
            if tok.name == "html" { b.mode = .AfterAfterFrameset; return false }
        }
        return false

    case .AfterAfterBody:
        #partial switch tok.kind {
        case .Comment: insert_comment_to(b.doc, tok.data); return false
        case .Doctype: return tb_inbody(b, tok)
        case .StartTag:
            if tok.name == "html" do return tb_inbody(b, tok)
        case .EOF:
            return false
        }
        b.mode = .InBody
        return true

    case .AfterAfterFrameset:
        #partial switch tok.kind {
        case .Comment: insert_comment_to(b.doc, tok.data); return false
        case .Doctype: return tb_inbody(b, tok)
        case .StartTag:
            switch tok.name {
            case "html": return tb_inbody(b, tok)
            case "noframes": return tb_inhead(b, tok)
            }
        }
        return false
    }
    return false
}

// ── in head (token) ──
@(private = "file")
tb_inhead :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .Comment: insert_comment(b, tok.data); return false
    case .Doctype: return false
    case .StartTag:
        switch tok.name {
        case "html": return tb_inbody(b, tok)
        case "base", "basefont", "bgsound", "link", "meta": insert_void(b, tok); return false
        case "title": start_rcdata(b, tok); return false
        case "noframes", "style": start_rawtext(b, tok); return false
        case "noscript": insert_from_token(b, tok); b.mode = .InHeadNoscript; return false
        case "script": start_script(b, tok); return false
        case "template": open_template(b, tok); return false
        case "head": return false
        }
        pop_open(b); b.mode = .AfterHead; return true
    case .EndTag:
        switch tok.name {
        case "head": pop_open(b); b.mode = .AfterHead; return false
        case "body", "html", "br": pop_open(b); b.mode = .AfterHead; return true
        case "template": close_template(b); return false
        }
        return false
    case .EOF:
        pop_open(b); b.mode = .AfterHead; return true
    }
    return false
}

// ── lista de tags de bloco de InBody (end tags) ──
@(private = "file")
inbody_block_end :: proc(tag: string) -> bool {
    switch tag {
    case "address", "article", "aside", "blockquote", "button", "center",
        "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption",
        "figure", "footer", "header", "hgroup", "listing", "main", "menu",
        "nav", "ol", "pre", "search", "section", "summary", "ul":
        return true
    }
    return false
}

// ── in body (token) ──
@(private = "file")
tb_inbody :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .Comment: insert_comment(b, tok.data); return false
    case .Doctype: return false
    case .EOF:
        if len(b.template_modes) > 0 {
            if !has_template(b) do return false
            pop_until(b, "template")
            clear_afe_to_marker(b)
            pop(&b.template_modes)
            reset_insertion_mode(b)
            return true
        }
        return false

    case .StartTag:
        switch tok.name {
        case "html":
            if !has_template(b) {
                apply_token_attrs(b.open[0], tok)
            }
            return false
        case "base", "basefont", "bgsound", "link", "meta", "noframes", "script",
            "style", "template", "title":
            return tb_inhead(b, tok)
        case "body":
            if len(b.open) >= 2 && b.open[1].ns == "" && b.open[1].tag == "body" && !has_template(b) {
                b.frameset_ok = false
                apply_token_attrs(b.open[1], tok)
            }
            return false
        case "frameset":
            if b.frameset_ok && len(b.open) >= 2 && b.open[1].ns == "" && b.open[1].tag == "body" {
                body := b.open[1]
                if body.parent != nil do for c, i in body.parent.children do if c == body { dom.kids_remove_at(body.parent, i); break }
                for len(b.open) > 1 do pop_open(b)
                insert_from_token(b, tok); b.mode = .InFrameset
            }
            return false
        case "address", "article", "aside", "blockquote", "center", "details",
            "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure",
            "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p",
            "search", "section", "summary", "ul":
            if has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); return false
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if has_in_button_scope(b, "p") do close_p(b)
            if cur(b).ns == "" && is_heading(cur(b).tag) do pop_open(b)
            insert_from_token(b, tok); return false
        case "pre", "listing":
            if has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); b.ignore_lf = true; b.frameset_ok = false; return false
        case "form":
            if b.form != nil && !has_template(b) do return false
            if has_in_button_scope(b, "p") do close_p(b)
            el := insert_from_token(b, tok)
            if !has_template(b) do b.form = el
            return false
        case "li":
            b.frameset_ok = false
            for i := len(b.open) - 1; i >= 0; i -= 1 {
                node := b.open[i]
                if node.ns == "" && node.tag == "li" {
                    generate_implied_end_tags(b, "li"); pop_until(b, "li"); break
                }
                if is_special(node) && !(node.ns == "" && (node.tag == "address" || node.tag == "div" || node.tag == "p")) do break
            }
            if has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); return false
        case "dd", "dt":
            b.frameset_ok = false
            for i := len(b.open) - 1; i >= 0; i -= 1 {
                node := b.open[i]
                if node.ns == "" && (node.tag == "dd" || node.tag == "dt") {
                    generate_implied_end_tags(b, node.tag); pop_until(b, node.tag); break
                }
                if is_special(node) && !(node.ns == "" && (node.tag == "address" || node.tag == "div" || node.tag == "p")) do break
            }
            if has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); return false
        case "plaintext":
            if has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); b.tok.state = .PLAINTEXT; return false
        case "button":
            if has_in_scope(b, "button") { generate_implied_end_tags(b); pop_until(b, "button") }
            reconstruct_afe(b); insert_from_token(b, tok); b.frameset_ok = false; return false
        case "a":
            found: ^dom.Node
            for i := len(b.afe) - 1; i >= 0; i -= 1 {
                if b.afe[i].marker do break
                if b.afe[i].node.ns == "" && b.afe[i].node.tag == "a" { found = b.afe[i].node; break }
            }
            if found != nil {
                adoption_agency(b, "a")
                ai := afe_index_of(b, found); if ai >= 0 do ordered_remove(&b.afe, ai)
                oi := open_index(b, found); if oi >= 0 do ordered_remove(&b.open, oi)
            }
            reconstruct_afe(b); el := insert_from_token(b, tok); push_afe(b, el); return false
        case "b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u":
            reconstruct_afe(b); el := insert_from_token(b, tok); push_afe(b, el); return false
        case "nobr":
            reconstruct_afe(b)
            if has_in_scope(b, "nobr") { adoption_agency(b, "nobr"); reconstruct_afe(b) }
            el := insert_from_token(b, tok); push_afe(b, el); return false
        case "applet", "marquee", "object":
            reconstruct_afe(b); insert_from_token(b, tok); insert_marker(b); b.frameset_ok = false; return false
        case "table":
            if !b.quirks && has_in_button_scope(b, "p") do close_p(b)
            insert_from_token(b, tok); b.frameset_ok = false; b.mode = .InTable; return false
        case "area", "br", "embed", "img", "keygen", "wbr":
            reconstruct_afe(b); insert_void(b, tok); b.frameset_ok = false; return false
        case "input":
            reconstruct_afe(b)
            insert_from_token(b, tok)
            typ, ok := b.open[len(b.open) - 1].attrs["type"]
            pop_open(b)
            // eq_ascii_ci em vez de strings.to_lower: a to_lower ALOCA e o
            // resultado era descartado sem delete (6 B por <input> no corpo).
            if !(ok && eq_ascii_ci(typ, "hidden")) do b.frameset_ok = false
            return false
        case "param", "source", "track":
            insert_void(b, tok); return false
        case "hr":
            if has_in_button_scope(b, "p") do close_p(b)
            insert_void(b, tok); b.frameset_ok = false; return false
        case "image":
            t2 := tok; t2.name = "img"
            reconstruct_afe(b); insert_void(b, t2); b.frameset_ok = false; return false
        case "textarea":
            el := insert_from_token(b, tok)
            b.ignore_lf = true
            b.tok.state = .RCDATA; b.tok.last_start = el.tag
            b.frameset_ok = false; b.original_mode = b.mode; b.mode = .Text; return false
        case "xmp":
            if has_in_button_scope(b, "p") do close_p(b)
            reconstruct_afe(b); b.frameset_ok = false; start_rawtext(b, tok); return false
        case "iframe":
            b.frameset_ok = false; start_rawtext(b, tok); return false
        case "noembed":
            start_rawtext(b, tok); return false
        case "select":
            reconstruct_afe(b); insert_from_token(b, tok); b.frameset_ok = false
            #partial switch b.mode {
            case .InTable, .InCaption, .InTableBody, .InRow, .InCell: b.mode = .InSelectInTable
            case: b.mode = .InSelect
            }
            return false
        case "optgroup", "option":
            if cur(b).ns == "" && cur(b).tag == "option" do pop_open(b)
            reconstruct_afe(b); insert_from_token(b, tok); return false
        case "rb", "rtc":
            if has_in_scope(b, "ruby") do generate_implied_end_tags(b)
            insert_from_token(b, tok); return false
        case "rp", "rt":
            if has_in_scope(b, "ruby") do generate_implied_end_tags(b, "rtc")
            insert_from_token(b, tok); return false
        case "math":
            reconstruct_afe(b); insert_foreign_element(b, tok, "math")
            if tok.self_closing do pop_open(b)
            return false
        case "svg":
            reconstruct_afe(b); insert_foreign_element(b, tok, "svg")
            if tok.self_closing do pop_open(b)
            return false
        case "caption", "col", "colgroup", "frame", "head", "tbody", "td",
            "tfoot", "th", "thead", "tr":
            return false // ignore
        }
        // qualquer outra start tag
        reconstruct_afe(b); insert_from_token(b, tok); return false

    case .EndTag:
        switch tok.name {
        case "template": return tb_inhead(b, tok)
        case "body":
            if has_in_scope(b, "body") do b.mode = .AfterBody
            return false
        case "html":
            if has_in_scope(b, "body") { b.mode = .AfterBody; return true }
            return false
        case "p":
            if !has_in_button_scope(b, "p") do insert_named(b, "p")
            close_p(b); return false
        case "li":
            if has_in_list_scope(b, "li") { generate_implied_end_tags(b, "li"); pop_until(b, "li") }
            return false
        case "dd", "dt":
            if has_in_scope(b, tok.name) { generate_implied_end_tags(b, tok.name); pop_until(b, tok.name) }
            return false
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if has_heading_in_scope(b) { generate_implied_end_tags(b); pop_until_heading(b) }
            return false
        case "form":
            if !has_template(b) {
                node := b.form; b.form = nil
                if node == nil || !has_node_in_scope(b, node) do return false
                generate_implied_end_tags(b)
                oi := open_index(b, node); if oi >= 0 do ordered_remove(&b.open, oi)
            } else {
                if has_in_scope(b, "form") { generate_implied_end_tags(b); pop_until(b, "form") }
            }
            return false
        case "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small",
            "strike", "strong", "tt", "u":
            if adoption_agency(b, tok.name) do return inbody_any_end(b, tok.name)
            return false
        case "applet", "marquee", "object":
            if has_in_scope(b, tok.name) {
                generate_implied_end_tags(b); pop_until(b, tok.name); clear_afe_to_marker(b)
            }
            return false
        case "br":
            reconstruct_afe(b); insert_void_named(b, "br"); b.frameset_ok = false; return false
        }
        if inbody_block_end(tok.name) {
            if has_in_scope(b, tok.name) { generate_implied_end_tags(b); pop_until(b, tok.name) }
            return false
        }
        return inbody_any_end(b, tok.name)
    }
    return false
}

// "any other end tag" (in body)
@(private = "file")
inbody_any_end :: proc(b: ^Builder, tag: string) -> bool {
    target: ^dom.Node
    for i := len(b.open) - 1; i >= 0; i -= 1 {
        node := b.open[i]
        if node.ns == "" && node.tag == tag { target = node; break }
        if is_special(node) do return false
    }
    if target != nil {
        generate_implied_end_tags(b, tag)
        for len(b.open) > 0 { n := pop_open(b); if n == target do break }
    }
    return false
}

// ── in table (token) ──
@(private = "file")
clear_to_table_ctx :: proc(b: ^Builder) {
    for {
        t := cur(b)
        if t.ns == "" && (t.tag == "table" || t.tag == "template" || t.tag == "html") do break
        pop_open(b)
    }
}
@(private = "file")
clear_to_table_body_ctx :: proc(b: ^Builder) {
    for {
        t := cur(b)
        if t.ns == "" && (t.tag == "tbody" || t.tag == "tfoot" || t.tag == "thead" || t.tag == "template" || t.tag == "html") do break
        pop_open(b)
    }
}
@(private = "file")
clear_to_table_row_ctx :: proc(b: ^Builder) {
    for {
        t := cur(b)
        if t.ns == "" && (t.tag == "tr" || t.tag == "template" || t.tag == "html") do break
        pop_open(b)
    }
}

@(private = "file")
table_token :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .Comment: insert_comment(b, tok.data); return false
    case .Doctype: return false
    case .StartTag:
        switch tok.name {
        case "caption":
            clear_to_table_ctx(b); insert_marker(b); insert_from_token(b, tok); b.mode = .InCaption; return false
        case "colgroup":
            clear_to_table_ctx(b); insert_from_token(b, tok); b.mode = .InColumnGroup; return false
        case "col":
            clear_to_table_ctx(b); insert_named(b, "colgroup"); b.mode = .InColumnGroup; return true
        case "tbody", "tfoot", "thead":
            clear_to_table_ctx(b); insert_from_token(b, tok); b.mode = .InTableBody; return false
        case "td", "th", "tr":
            clear_to_table_ctx(b); insert_named(b, "tbody"); b.mode = .InTableBody; return true
        case "table":
            if !has_in_table_scope(b, "table") do return false
            pop_until(b, "table"); reset_insertion_mode(b); return true
        case "style", "script", "template":
            return tb_inhead(b, tok)
        case "input":
            typ, ok := tok.attrs["type"]
            // eq_ascii_ci em vez de strings.to_lower: a to_lower ALOCA e o
            // resultado era descartado sem delete (vazava por <input> em tabela).
            if ok && eq_ascii_ci(typ, "hidden") { insert_void(b, tok); return false }
            // senão: anything else (foster)
        case "form":
            if b.form == nil && !has_template(b) {
                el := insert_from_token(b, tok); b.form = el; pop_open(b)
            }
            return false
        }
    case .EndTag:
        switch tok.name {
        case "table":
            if !has_in_table_scope(b, "table") do return false
            pop_until(b, "table"); reset_insertion_mode(b); return false
        case "body", "caption", "col", "colgroup", "html", "tbody", "td",
            "tfoot", "th", "thead", "tr":
            return false
        case "template":
            return tb_inhead(b, tok)
        }
    case .EOF:
        return tb_inbody(b, tok)
    }
    // anything else: foster parenting + regras de in body
    b.fostering = true
    r := tb_inbody(b, tok)
    b.fostering = false
    return r
}

// ── in table body (token) ──
@(private = "file")
table_body_token :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .StartTag:
        switch tok.name {
        case "tr":
            clear_to_table_body_ctx(b); insert_from_token(b, tok); b.mode = .InRow; return false
        case "th", "td":
            clear_to_table_body_ctx(b); insert_named(b, "tr"); b.mode = .InRow; return true
        case "caption", "col", "colgroup", "tbody", "tfoot", "thead":
            if !(has_in_table_scope(b, "tbody") || has_in_table_scope(b, "thead") || has_in_table_scope(b, "tfoot")) do return false
            clear_to_table_body_ctx(b); pop_open(b); b.mode = .InTable; return true
        }
    case .EndTag:
        switch tok.name {
        case "tbody", "tfoot", "thead":
            if has_in_table_scope(b, tok.name) { clear_to_table_body_ctx(b); pop_open(b); b.mode = .InTable }
            return false
        case "table":
            if !(has_in_table_scope(b, "tbody") || has_in_table_scope(b, "thead") || has_in_table_scope(b, "tfoot")) do return false
            clear_to_table_body_ctx(b); pop_open(b); b.mode = .InTable; return true
        case "body", "caption", "col", "colgroup", "html", "td", "th", "tr":
            return false
        }
    }
    return table_token(b, tok)
}

// ── in row (token) ──
@(private = "file")
row_token :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .StartTag:
        switch tok.name {
        case "th", "td":
            clear_to_table_row_ctx(b); insert_from_token(b, tok); b.mode = .InCell; insert_marker(b); return false
        case "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr":
            if !has_in_table_scope(b, "tr") do return false
            clear_to_table_row_ctx(b); pop_open(b); b.mode = .InTableBody; return true
        }
    case .EndTag:
        switch tok.name {
        case "tr":
            if has_in_table_scope(b, "tr") { clear_to_table_row_ctx(b); pop_open(b); b.mode = .InTableBody }
            return false
        case "table":
            if !has_in_table_scope(b, "tr") do return false
            clear_to_table_row_ctx(b); pop_open(b); b.mode = .InTableBody; return true
        case "tbody", "tfoot", "thead":
            if !has_in_table_scope(b, tok.name) do return false
            if has_in_table_scope(b, "tr") { clear_to_table_row_ctx(b); pop_open(b); b.mode = .InTableBody }
            return true
        case "body", "caption", "col", "colgroup", "html", "td", "th":
            return false
        }
    }
    return table_token(b, tok)
}

// ── in caption (regras próprias antes de in body) ──
@(private = "file")
caption_token :: proc(b: ^Builder, tok: Token) -> (reprocess: bool, handled: bool) {
    #partial switch tok.kind {
    case .StartTag:
        switch tok.name {
        case "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr":
            if !has_in_table_scope(b, "caption") do return false, true
            generate_implied_end_tags(b); pop_until(b, "caption"); clear_afe_to_marker(b); b.mode = .InTable
            return true, true
        }
    case .EndTag:
        switch tok.name {
        case "caption":
            if has_in_table_scope(b, "caption") {
                generate_implied_end_tags(b); pop_until(b, "caption"); clear_afe_to_marker(b); b.mode = .InTable
            }
            return false, true
        case "table":
            if !has_in_table_scope(b, "caption") do return false, true
            generate_implied_end_tags(b); pop_until(b, "caption"); clear_afe_to_marker(b); b.mode = .InTable
            return true, true
        case "body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr":
            return false, true
        }
    }
    return false, false
}

// ── in cell (regras próprias antes de in body) ──
@(private = "file")
close_cell :: proc(b: ^Builder) {
    generate_implied_end_tags(b)
    if has_in_table_scope(b, "td") { pop_until(b, "td") }
    else if has_in_table_scope(b, "th") { pop_until(b, "th") }
    clear_afe_to_marker(b)
    b.mode = .InRow
}
@(private = "file")
cell_token :: proc(b: ^Builder, tok: Token) -> (reprocess: bool, handled: bool) {
    #partial switch tok.kind {
    case .StartTag:
        switch tok.name {
        case "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr":
            if !(has_in_table_scope(b, "td") || has_in_table_scope(b, "th")) do return false, true
            close_cell(b); return true, true
        }
    case .EndTag:
        switch tok.name {
        case "td", "th":
            if has_in_table_scope(b, tok.name) {
                generate_implied_end_tags(b); pop_until(b, tok.name); clear_afe_to_marker(b); b.mode = .InRow
            }
            return false, true
        case "body", "caption", "col", "colgroup", "html":
            return false, true
        case "table", "tbody", "tfoot", "thead", "tr":
            if !has_in_table_scope(b, tok.name) do return false, true
            close_cell(b); return true, true
        }
    }
    return false, false
}

// ── in select (token) ──
// Modelo "customizable select" (spec atual): o <select> deixou de ter um content
// model restritivo no parser. Só option/optgroup/hr/select/script/template têm
// tratamento próprio; QUALQUER outra tag é delegada às regras de in body (que
// reconstroem os formatting elements e inserem div/button/i/keygen/plaintext/
// math/svg/... dentro do select).
@(private = "file")
select_token :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .Comment: insert_comment(b, tok.data); return false
    case .Doctype: return false
    case .StartTag:
        switch tok.name {
        case "html": return tb_inbody(b, tok)
        case "option":
            if cur(b).ns == "" && cur(b).tag == "option" do pop_open(b)
            reconstruct_afe(b); insert_from_token(b, tok); return false
        case "optgroup":
            if cur(b).ns == "" && cur(b).tag == "option" do pop_open(b)
            if cur(b).ns == "" && cur(b).tag == "optgroup" do pop_open(b)
            reconstruct_afe(b); insert_from_token(b, tok); return false
        case "hr":
            if cur(b).ns == "" && cur(b).tag == "option" do pop_open(b)
            if cur(b).ns == "" && cur(b).tag == "optgroup" do pop_open(b)
            insert_void(b, tok); return false
        case "select":
            if has_in_select_scope(b, "select") { pop_until(b, "select"); reset_insertion_mode(b) }
            return false
        case "input", "textarea":
            // input/textarea AINDA fecham o select (keygen NÃO — foi removido
            // dessa lista: cai em "anything else" → in body, virando void dentro).
            if !has_in_select_scope(b, "select") do return false
            pop_until(b, "select"); reset_insertion_mode(b); return true
        case "script", "template": return tb_inhead(b, tok)
        }
        return tb_inbody(b, tok) // anything else → in body
    case .EndTag:
        switch tok.name {
        case "optgroup":
            if cur(b).ns == "" && cur(b).tag == "option" && len(b.open) >= 2 && b.open[len(b.open) - 2].ns == "" && b.open[len(b.open) - 2].tag == "optgroup" {
                pop_open(b)
            }
            if cur(b).ns == "" && cur(b).tag == "optgroup" do pop_open(b)
            return false
        case "option":
            if cur(b).ns == "" && cur(b).tag == "option" do pop_open(b)
            return false
        case "select":
            if has_in_select_scope(b, "select") { pop_until(b, "select"); reset_insertion_mode(b) }
            return false
        case "template": return tb_inhead(b, tok)
        }
        return tb_inbody(b, tok) // anything else → in body
    case .EOF:
        return tb_inbody(b, tok)
    }
    return false
}

// ═══════════════════════ CONTEÚDO ESTRANGEIRO (SVG/MathML) ══════════════════

@(private = "file")
is_mathml_tip :: proc(n: ^dom.Node) -> bool {
    if n.ns != "math" do return false
    switch n.tag { case "mi", "mo", "mn", "ms", "mtext": return true }
    return false
}

@(private = "file")
is_html_ip :: proc(n: ^dom.Node) -> bool {
    if n.ns == "svg" {
        tl := strings.to_lower(n.tag); defer delete(tl)
        return tl == "foreignobject" || tl == "desc" || tl == "title"
    }
    if n.ns == "math" && n.tag == "annotation-xml" {
        enc, ok := n.attrs["encoding"]
        if ok {
            el := strings.to_lower(enc); defer delete(el)
            return el == "text/html" || el == "application/xhtml+xml"
        }
    }
    return false
}

// Deve o token não-Char ser processado pelas regras de conteúdo estrangeiro?
@(private = "file")
use_foreign_token :: proc(b: ^Builder, tok: Token) -> bool {
    if len(b.open) == 0 do return false
    acn := adjusted_current(b)
    if acn.ns == "" do return false
    if tok.kind == .EOF do return false
    if is_mathml_tip(acn) && tok.kind == .StartTag && tok.name != "mglyph" && tok.name != "malignmark" do return false
    if acn.ns == "math" && acn.tag == "annotation-xml" && tok.kind == .StartTag && tok.name == "svg" do return false
    if is_html_ip(acn) && tok.kind == .StartTag do return false
    return true
}

@(private = "file")
use_foreign_char :: proc(b: ^Builder) -> bool {
    if len(b.open) == 0 do return false
    acn := adjusted_current(b)
    if acn.ns == "" do return false
    if is_mathml_tip(acn) do return false
    if is_html_ip(acn) do return false
    return true
}

@(private = "file")
foreign_char :: proc(b: ^Builder, r: rune) {
    if r == 0 { insert_char(b, '�'); return }
    insert_char(b, r)
    if !is_ws(r) do b.frameset_ok = false
}

@(private = "file")
is_foreign_breakout :: proc(tok: Token) -> bool {
    switch tok.name {
    case "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div",
        "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p",
        "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup",
        "table", "tt", "u", "ul", "var":
        return true
    case "font":
        return "color" in tok.attrs || "face" in tok.attrs || "size" in tok.attrs
    }
    return false
}

@(private = "file")
insert_foreign_element :: proc(b: ^Builder, tok: Token, ns: string) -> ^dom.Node {
    // Guardamos o nome SVG em minúsculas (o ajuste de caixa "foreignObject" etc.
    // é aplicado só na serialização): assim os testes de escopo/integração e o
    // casamento de end tag comparam com os literais minúsculos corretamente.
    el := make_element(tok.name, ns)
    // ordem de documento (attr_order), com ajuste de nome estrangeiro por atributo
    for k in tok.attr_order {
        nm := k
        if ns == "svg" do nm = svg_attr_adjust(nm)
        else if ns == "math" && nm == "definitionurl" do nm = "definitionURL"
        nm = foreign_attr_adjust(nm)
        if nm not_in el.attrs do dom.set_attr(el, strings.clone(nm), strings.clone(tok.attrs[k]))
    }
    parent, ref := insertion_place(b)
    dom_insert(parent, el, ref)
    append(&b.open, el)
    return el
}

@(private = "file")
foreign_token :: proc(b: ^Builder, tok: Token) -> bool {
    #partial switch tok.kind {
    case .Comment: insert_comment(b, tok.data); return false
    case .Doctype: return false
    case .StartTag:
        if is_foreign_breakout(tok) {
            // FRAGMENTO com contexto estrangeiro (`svgEl.innerHTML='<nobr>X'`):
            // a spec manda processar direto pelas regras de HTML, SEM o
            // desempilhamento abaixo. Fazer o breakout aqui era loop infinito —
            // a pilha só tem a raiz <html>, nada é popado, e o adjusted current
            // node continua sendo o contexto estrangeiro, então o reprocesso
            // reentra em foreign_token para sempre.
            if b.ctx != nil && len(b.open) == 1 do return tb_token(b, tok)
            // parse error: sai do conteúdo estrangeiro e reprocessa em HTML
            for len(b.open) > 0 && cur(b).ns != "" && !is_mathml_tip(cur(b)) && !is_html_ip(cur(b)) {
                pop_open(b)
            }
            return true
        }
        // "in the same namespace as the ADJUSTED current node" — em fragmento
        // com contexto estrangeiro a pilha só tem a raiz <html> (ns=""), então
        // usar cur() fazia `svgEl.innerHTML='<rect/>'` nascer sem namespace.
        ns := adjusted_current(b).ns
        insert_foreign_element(b, tok, ns)
        if tok.self_closing do pop_open(b)
        return false
    case .EndTag:
        // </br> e </p> fazem BREAKOUT como as start tags da lista (§13.2.6.5:
        // "An end tag whose tag name is 'br', 'p'" compartilha a entrada de
        // breakout). Depois de desempilhar, a spec manda reprocessar "in HTML
        // content" DIRETO (tb_token), não via dispatcher: numa end tag o
        // dispatcher voltaria às regras estrangeiras (a isenção de integration
        // point só existe p/ start tag/char) e seria loop infinito.
        if tok.name == "br" || tok.name == "p" {
            for len(b.open) > 1 && cur(b).ns != "" && !is_mathml_tip(cur(b)) && !is_html_ip(cur(b)) {
                pop_open(b)
            }
            return tb_token(b, tok)
        }
        // </script> num <svg script>: só desempilha
        if tok.name == "script" && cur(b).ns == "svg" && eq_ascii_ci(cur(b).tag, "script") {
            pop_open(b); return false
        }
        idx := len(b.open) - 1
        node := b.open[idx]
        for {
            if node == b.open[0] do return false
            if eq_ascii_ci(node.tag, tok.name) {
                for len(b.open) > 0 { x := pop_open(b); if x == node do break }
                return false
            }
            idx -= 1
            node = b.open[idx]
            if node.ns == "" do return tb_token(b, tok)
        }
    }
    return false
}

// ── tabela de ajuste de NOME de tag SVG (lowercased → correto) ──
// Package-private: usada pelo serializador (serialize.odin) na hora de imprimir.
@(private)
svg_tag_adjust :: proc(t: string) -> string {
    switch t {
    case "altglyph": return "altGlyph"
    case "altglyphdef": return "altGlyphDef"
    case "altglyphitem": return "altGlyphItem"
    case "animatecolor": return "animateColor"
    case "animatemotion": return "animateMotion"
    case "animatetransform": return "animateTransform"
    case "clippath": return "clipPath"
    case "feblend": return "feBlend"
    case "fecolormatrix": return "feColorMatrix"
    case "fecomponenttransfer": return "feComponentTransfer"
    case "fecomposite": return "feComposite"
    case "feconvolvematrix": return "feConvolveMatrix"
    case "fediffuselighting": return "feDiffuseLighting"
    case "fedisplacementmap": return "feDisplacementMap"
    case "fedistantlight": return "feDistantLight"
    case "fedropshadow": return "feDropShadow"
    case "feflood": return "feFlood"
    case "fefunca": return "feFuncA"
    case "fefuncb": return "feFuncB"
    case "fefuncg": return "feFuncG"
    case "fefuncr": return "feFuncR"
    case "fegaussianblur": return "feGaussianBlur"
    case "feimage": return "feImage"
    case "femerge": return "feMerge"
    case "femergenode": return "feMergeNode"
    case "femorphology": return "feMorphology"
    case "feoffset": return "feOffset"
    case "fepointlight": return "fePointLight"
    case "fespecularlighting": return "feSpecularLighting"
    case "fespotlight": return "feSpotLight"
    case "fetile": return "feTile"
    case "feturbulence": return "feTurbulence"
    case "foreignobject": return "foreignObject"
    case "glyphref": return "glyphRef"
    case "lineargradient": return "linearGradient"
    case "radialgradient": return "radialGradient"
    case "textpath": return "textPath"
    }
    return t
}

// ── tabela de ajuste de NOME de atributo SVG (case fixups) ──
@(private = "file")
svg_attr_adjust :: proc(a: string) -> string {
    switch a {
    case "attributename": return "attributeName"
    case "attributetype": return "attributeType"
    case "basefrequency": return "baseFrequency"
    case "baseprofile": return "baseProfile"
    case "calcmode": return "calcMode"
    case "clippathunits": return "clipPathUnits"
    case "diffuseconstant": return "diffuseConstant"
    case "edgemode": return "edgeMode"
    case "filterunits": return "filterUnits"
    case "glyphref": return "glyphRef"
    case "gradienttransform": return "gradientTransform"
    case "gradientunits": return "gradientUnits"
    case "kernelmatrix": return "kernelMatrix"
    case "kernelunitlength": return "kernelUnitLength"
    case "keypoints": return "keyPoints"
    case "keysplines": return "keySplines"
    case "keytimes": return "keyTimes"
    case "lengthadjust": return "lengthAdjust"
    case "limitingconeangle": return "limitingConeAngle"
    case "markerheight": return "markerHeight"
    case "markerunits": return "markerUnits"
    case "markerwidth": return "markerWidth"
    case "maskcontentunits": return "maskContentUnits"
    case "maskunits": return "maskUnits"
    case "numoctaves": return "numOctaves"
    case "pathlength": return "pathLength"
    case "patterncontentunits": return "patternContentUnits"
    case "patterntransform": return "patternTransform"
    case "patternunits": return "patternUnits"
    case "pointsatx": return "pointsAtX"
    case "pointsaty": return "pointsAtY"
    case "pointsatz": return "pointsAtZ"
    case "preservealpha": return "preserveAlpha"
    case "preserveaspectratio": return "preserveAspectRatio"
    case "primitiveunits": return "primitiveUnits"
    case "refx": return "refX"
    case "refy": return "refY"
    case "repeatcount": return "repeatCount"
    case "repeatdur": return "repeatDur"
    case "requiredextensions": return "requiredExtensions"
    case "requiredfeatures": return "requiredFeatures"
    case "specularconstant": return "specularConstant"
    case "specularexponent": return "specularExponent"
    case "spreadmethod": return "spreadMethod"
    case "startoffset": return "startOffset"
    case "stddeviation": return "stdDeviation"
    case "stitchtiles": return "stitchTiles"
    case "surfacescale": return "surfaceScale"
    case "systemlanguage": return "systemLanguage"
    case "tablevalues": return "tableValues"
    case "targetx": return "targetX"
    case "targety": return "targetY"
    case "textlength": return "textLength"
    case "viewbox": return "viewBox"
    case "viewtarget": return "viewTarget"
    case "xchannelselector": return "xChannelSelector"
    case "ychannelselector": return "yChannelSelector"
    case "zoomandpan": return "zoomAndPan"
    }
    return a
}

// ── atributos com namespace (xlink:/xml:/xmlns): serializados como "prefix local" ──
@(private = "file")
foreign_attr_adjust :: proc(a: string) -> string {
    switch a {
    case "xlink:actuate": return "xlink actuate"
    case "xlink:arcrole": return "xlink arcrole"
    case "xlink:href": return "xlink href"
    case "xlink:role": return "xlink role"
    case "xlink:show": return "xlink show"
    case "xlink:title": return "xlink title"
    case "xlink:type": return "xlink type"
    case "xml:lang": return "xml lang"
    case "xml:space": return "xml space"
    case "xmlns": return "xmlns"
    case "xmlns:xlink": return "xmlns xlink"
    }
    return a
}

