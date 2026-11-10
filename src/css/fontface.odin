package css

// M224 — `@font-face`: parsing da at-rule.
//
// Até aqui `@font-face` caía no `skip_at_rule` (era o único "NÃO implementa" que
// o cabeçalho do css.odin declarava). O parser não toma nenhuma decisão sobre
// rede ou atlas — só extrai a DESCRIÇÃO da face; quem baixa, decodifica e injeta
// no atlas é `src/ui/fontface.odin`.
//
// Cobre o descritor que importa: `font-family`, `src` (lista de `url()` com
// `format()` opcional), `font-weight` e `font-style`. Ignorados de propósito:
// `unicode-range` (não fazemos subsetting), `font-display` (não temos política de
// swap/bloqueio — a face aparece quando chega), `font-feature-settings`,
// `ascent-override` e família. `local()` é DESCARTADO: não temos como enumerar
// fontes instaladas por nome PostScript.

import "core:strings"
import "core:strconv"

// Uma origem de `src`. `hint` é o que veio em `format(...)` já em minúsculas e
// sem aspas ("woff2", "truetype", …), ou "" quando ausente — nesse caso quem
// escolhe olha a extensão da URL.
Font_Src :: struct {
    url:  string, // owned
    hint: string, // owned
}

Font_Face :: struct {
    family: string, // owned, MINÚSCULAS (o casamento com font-family é case-insensitive)
    weight: int,    // 400 = normal, 700 = bold; numa faixa `100 900`, o INÍCIO
    weight_max: int, // fim da faixa (`100 900` → 900); 0 = peso único
    italic: bool,
    latin:  bool,   // o `unicode-range` cobre o latim básico? (sem descritor = true)
    srcs:   [dynamic]Font_Src,
}

free_faces :: proc(faces: ^[dynamic]Font_Face) {
    for &f in faces {
        delete(f.family)
        for s in f.srcs { delete(s.url); delete(s.hint) }
        delete(f.srcs)
    }
    delete(faces^)
    faces^ = nil
}

// Tira aspas simples/duplas de um valor ("Inter" → Inter).
@(private = "file")
unquote :: proc(s: string) -> string {
    t := strings.trim_space(s)
    if len(t) >= 2 && (t[0] == '"' || t[0] == '\'') && t[len(t) - 1] == t[0] {
        return strings.trim_space(t[1 : len(t) - 1])
    }
    return t
}

// Extrai o conteúdo de `nome(...)` a partir de `at` (que aponta p/ o '('),
// respeitando parênteses aninhados. Devolve o miolo e o índice APÓS o ')'.
@(private = "file")
paren_body :: proc(s: string, at: int) -> (body: string, next: int, ok: bool) {
    depth := 0
    for i := at; i < len(s); i += 1 {
        if      s[i] == '(' do depth += 1
        else if s[i] == ')' {
            depth -= 1
            if depth == 0 do return s[at + 1 : i], i + 1, true
        }
    }
    return "", len(s), false
}

// Divide por vírgulas de TOPO (as de dentro de `url(...)`/`format(...)` não contam).
@(private = "file")
split_src_list :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    depth, start := 0, 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case '(': depth += 1
        case ')': depth -= 1
        case ',':
            if depth == 0 { append(&out, strings.trim_space(s[start:i])); start = i + 1 }
        }
    }
    append(&out, strings.trim_space(s[start:]))
    return out[:]
}

// `font-weight` do descritor: número, palavra-chave, ou faixa `100 900`. A faixa
// é o que uma fonte VARIÁVEL declara ("sirvo qualquer peso entre estes"); quem
// registra a face usa as duas pontas para casar o peso pedido e instanciar o
// eixo `wght` nele (ver src/varfont). `hi` = 0 quando não há faixa.
@(private = "file")
face_weight :: proc(v: string) -> (lo: int, hi: int) {
    t := strings.to_lower(strings.trim_space(v), context.temp_allocator)
    one :: proc(s: string) -> int {
        switch s {
        case "normal":  return 400
        case "bold":    return 700
        case "lighter": return 300
        case "bolder":  return 700
        }
        if n, ok := strconv.parse_int(s); ok do return n
        if f, ok := strconv.parse_f64(s); ok do return int(f + 0.5) // `font-weight: 350.5`
        return 400
    }
    if t == "" do return 400, 0
    parts := strings.fields(t, context.temp_allocator)
    if len(parts) == 0 do return 400, 0
    lo = one(parts[0])
    if len(parts) >= 2 {
        hi = one(parts[1])
        if hi < lo do lo, hi = hi, lo // css-fonts-4: faixa invertida é trocada
        if hi == lo do hi = 0
    }
    return
}

// Varre um texto CSS colhendo SÓ as `@font-face`, sem montar regra nenhuma.
// Existe porque quem registra as faces é a thread PRINCIPAL (dona do atlas),
// enquanto o `parse` completo da página roda num worker de fetch — passar as
// faces por dentro do job exigiria plumbing em todo o caminho de navegação.
// O scan é barato: acha o token, pula até `{` e casa a chave (o corpo de um
// @font-face não tem blocos aninhados).
parse_faces_only :: proc(input: string) -> (faces: [dynamic]Font_Face) {
    src := strip_comments(input, context.temp_allocator)
    i := 0
    for i < len(src) {
        at := strings.index_byte(src[i:], '@')
        if at < 0 do break
        at += i
        rest := src[at:]
        if len(rest) < 11 || !strings.equal_fold(rest[:10], "@font-face") {
            i = at + 1
            continue
        }
        j := at + 10
        for j < len(src) && src[j] != '{' && src[j] != ';' do j += 1
        if j >= len(src) || src[j] == ';' { i = j + 1; continue }
        j += 1
        start := j
        depth := 1
        for j < len(src) && depth > 0 {
            if      src[j] == '{' do depth += 1
            else if src[j] == '}' do depth -= 1
            j += 1
        }
        parse_font_face(src[start : depth == 0 ? j - 1 : len(src)], &faces)
        i = j
    }
    return
}

// A lista de `unicode-range` inclui o latim básico? Testamos UM ponto de código,
// o 'A' (U+0041): é o que decide se a face serve para texto latino, que é o único
// uso que fazemos da informação (ver a nota em parse_font_face).
// Formas aceitas (css-fonts §4.5): `U+41`, `U+0041-005A`, `U+00??` (curinga).
@(private)
range_cobre_latim :: proc(v: string) -> bool {
    ALVO :: 0x41
    for item in strings.split(v, ",", context.temp_allocator) {
        t := strings.trim_space(item)
        if len(t) < 2 do continue
        if t[0] != 'u' && t[0] != 'U' do continue
        t = strings.trim_space(t[1:])
        if len(t) == 0 || t[0] != '+' do continue
        t = t[1:]
        // curinga: `U+00??` vira a faixa 0x0000..0x00FF
        if strings.contains(t, "?") {
            lo_s, _ := strings.replace_all(t, "?", "0", context.temp_allocator)
            hi_s, _ := strings.replace_all(t, "?", "F", context.temp_allocator)
            lo, lok := strconv.parse_u64_of_base(lo_s, 16)
            hi, hok := strconv.parse_u64_of_base(hi_s, 16)
            if lok && hok && u64(ALVO) >= lo && u64(ALVO) <= hi do return true
            continue
        }
        if dash := strings.index_byte(t, '-'); dash >= 0 {
            lo, lok := strconv.parse_u64_of_base(strings.trim_space(t[:dash]), 16)
            hi, hok := strconv.parse_u64_of_base(strings.trim_space(t[dash + 1:]), 16)
            if lok && hok && u64(ALVO) >= lo && u64(ALVO) <= hi do return true
            continue
        }
        if p, ok := strconv.parse_u64_of_base(t, 16); ok && p == u64(ALVO) do return true
    }
    return false
}

// Parseia o CORPO de um `@font-face { … }` e acrescenta a face em `out`.
// Uma face sem `font-family` ou sem nenhum `src` utilizável é DESCARTADA.
@(private)
parse_font_face :: proc(body: string, out: ^[dynamic]Font_Face) {
    decls := parse_decls(body, context.temp_allocator)
    fam_raw, has_fam := decls["font-family"]
    src_raw, has_src := decls["src"]
    if !has_fam || !has_src do return
    fam := unquote(fam_raw)
    if fam == "" do return

    face := Font_Face{
        family = strings.to_lower(fam),
        weight = 400,
        srcs   = make([dynamic]Font_Src),
        latin  = true, // sem unicode-range, a face cobre tudo
    }
    // `unicode-range`: NÃO fazemos subsetting, mas a pergunta "esta face tem as
    // letras latinas básicas?" é obrigatória. Um provedor tipo Google Fonts
    // publica a MESMA (família, peso, estilo) N vezes, uma por bloco Unicode
    // (cyrillic-ext, greek, vietnamese, latin-ext, latin…), e como só guardamos
    // UMA face por combinação, ficar com a primeira significava ficar com o
    // cirílico — uma fonte sem nenhuma letra do texto da página.
    if ur, ok := decls["unicode-range"]; ok do face.latin = range_cobre_latim(ur)
    if w, ok := decls["font-weight"]; ok do face.weight, face.weight_max = face_weight(w)
    if s, ok := decls["font-style"]; ok {
        st := strings.to_lower(strings.trim_space(s), context.temp_allocator)
        face.italic = strings.has_prefix(st, "italic") || strings.has_prefix(st, "oblique")
    }

    for item in split_src_list(src_raw) {
        url, hint := "", ""
        i := 0
        for i < len(item) {
            open := strings.index_byte(item[i:], '(')
            if open < 0 do break
            open += i
            name := strings.to_lower(strings.trim_space(item[i:open]), context.temp_allocator)
            // o nome da função pode vir grudado no token anterior ("…) format")
            if sp := strings.last_index_byte(name, ' '); sp >= 0 do name = name[sp + 1:]
            b, nxt, ok := paren_body(item, open)
            if !ok do break
            switch name {
            case "url": url = unquote(b)
            case "format", "tech": if hint == "" do hint = strings.to_lower(unquote(b), context.temp_allocator)
            // `local(...)`: sem enumeração de fontes instaladas, é descartado.
            }
            i = nxt
        }
        if url == "" do continue
        append(&face.srcs, Font_Src{url = strings.clone(url), hint = strings.clone(hint)})
    }

    if len(face.srcs) == 0 {
        delete(face.family)
        delete(face.srcs)
        return
    }
    append(out, face)
}
