package brotli

import "core:testing"
import "core:slice"
import "core:hash"
import "core:strings"

// ── as tabelas geradas ──────────────────────────────────────────────────────
//
// A RFC 7932 publica o CRC-32 de cada tabela que ela define por extenso. Isso
// faz dela um ORÁCULO: `tools/brotli-tables.py` extrai do texto e confere, e
// estes testes reconferem o que ficou no repositório. Uma edição à mão em
// `tables.odin` ou em `dict.bin` cai aqui em vez de sair como bytes
// silenciosamente corrompidos num stream específico.

// Antes de acreditar em qualquer CRC abaixo, pinar a IMPLEMENTAÇÃO de CRC-32:
// se `core:hash` usasse outro polinômio, os cinco testes seguintes falhariam
// juntos e a conclusão errada ("extraí a tabela errada") seria a óbvia.
@(test)
test_crc32_e_o_da_rfc :: proc(t: ^testing.T) {
    // vetor canônico do CRC-32 do gzip/zlib, que é o do apêndice C da RFC
    got := hash.crc32(transmute([]u8)string("123456789"))
    testing.expectf(t, got == 0xCBF43926, "core:hash não é o CRC-32 esperado: 0x%08x", got)
}

@(test)
test_dicionario_bate_com_a_rfc :: proc(t: ^testing.T) {
    testing.expectf(t, len(DICT) == 122784, "dicionário tem %d bytes, a RFC diz 122784", len(DICT))
    got := hash.crc32(DICT)
    testing.expectf(t, got == 0x5136cb04, "CRC do dicionário 0x%08x, a RFC diz 0x5136cb04", got)
}

@(test)
test_transformacoes_batem_com_a_rfc :: proc(t: ^testing.T) {
    testing.expect(t, len(TRANSFORMS) == 121, "a RFC define 121 transformações")
    // A serialização é a que o próprio apêndice B descreve para o check:
    // prefixo + \0 + byte do tipo + sufixo + \0, concatenados.
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    for tr in TRANSFORMS {
        strings.write_string(&b, tr.prefix)
        strings.write_byte(&b, 0)
        strings.write_byte(&b, u8(tr.kind))
        strings.write_string(&b, tr.suffix)
        strings.write_byte(&b, 0)
    }
    s := strings.to_string(b)
    testing.expectf(t, len(s) == 648, "serialização tem %d bytes, a RFC diz 648", len(s))
    got := hash.crc32(transmute([]u8)s)
    testing.expectf(t, got == 0x3d965f81, "CRC das transformações 0x%08x, a RFC diz 0x3d965f81", got)
}

@(test)
test_luts_de_contexto_batem_com_a_rfc :: proc(t: ^testing.T) {
    l0, l1, l2 := LUT0, LUT1, LUT2
    c0 := hash.crc32(l0[:])
    c1 := hash.crc32(l1[:])
    c2 := hash.crc32(l2[:])
    testing.expectf(t, c0 == 0x8e91efb7, "Lut0 0x%08x, a RFC diz 0x8e91efb7", c0)
    testing.expectf(t, c1 == 0xd01a32f4, "Lut1 0x%08x, a RFC diz 0xd01a32f4", c1)
    testing.expectf(t, c2 == 0x0dd7a0d6, "Lut2 0x%08x, a RFC diz 0x0dd7a0d6", c2)
}

// DOFFSET é DERIVADO de NDBITS pela recursão da seção 8. Se a derivação ou a
// tabela NDBITS estiver errada, o tamanho total não fecha com o arquivo — e
// toda referência ao dicionário passaria a ler a palavra errada.
@(test)
test_doffset_fecha_com_o_arquivo :: proc(t: ^testing.T) {
    testing.expectf(t, dict_size() == len(DICT),
        "DOFFSET dá %d bytes de dicionário, o arquivo tem %d", dict_size(), len(DICT))
    // amostras da recursão, para localizar o erro se o total divergir
    testing.expect(t, DOFFSET[4] == 0, "palavras de 4 bytes começam em 0")
    testing.expect(t, DOFFSET[5] == 4096, "1024 palavras de 4 bytes = 4096")
    testing.expect(t, nwords(3) == 0, "não há palavra com menos de 4 bytes")
    testing.expect(t, nwords(24) == 32, "2^5 palavras de 24 bytes")
}

// ── vetores contra o brotli de referência ───────────────────────────────────
//
// Gerados por `tools/brotli-vectors.py`. Cada caso existe por exercitar uma
// PARTE do formato (ver os comentários no gerador), não por variedade.

@(private = "file")
Vetor :: struct {
    nome: string,
    br:   []byte,
    raw:  []byte,
}

@(test)
test_vetores_do_brotli_de_referencia :: proc(t: ^testing.T) {
    vs := []Vetor{
        {"hello",     #load("testdata/hello.br"),     #load("testdata/hello.raw")},
        {"repeat",    #load("testdata/repeat.br"),    #load("testdata/repeat.raw")},
        {"zeros",     #load("testdata/zeros.br"),     #load("testdata/zeros.raw")},
        {"random",    #load("testdata/random.br"),    #load("testdata/random.raw")},
        {"html",      #load("testdata/html.br"),      #load("testdata/html.raw")},
        {"utf8",      #load("testdata/utf8.br"),      #load("testdata/utf8.raw")},
        {"dict",      #load("testdata/dict.br"),      #load("testdata/dict.raw")},
        {"dictwords", #load("testdata/dictwords.br"), #load("testdata/dictwords.raw")},
        {"rfctext",   #load("testdata/rfctext.br"),   #load("testdata/rfctext.raw")},
        // o alvo de verdade: o stream Brotli de dentro de um woff2 do Google Fonts
        {"woff2",     #load("testdata/woff2stream.br"), #load("testdata/woff2stream.raw")},
    }
    for v in vs {
        got, err := decode(v.br)
        defer delete(got)
        if !testing.expectf(t, err == .None, "%s: decode devolveu %v", v.nome, err) do continue
        if !testing.expectf(t, len(got) == len(v.raw),
            "%s: saiu com %d bytes, esperava %d", v.nome, len(got), len(v.raw)) {
            continue
        }
        // primeiro byte divergente, que localiza o defeito melhor que "difere"
        for i in 0 ..< len(got) {
            if got[i] != v.raw[i] {
                testing.expectf(t, false, "%s: difere no byte %d (0x%02x, esperava 0x%02x)",
                    v.nome, i, got[i], v.raw[i])
                break
            }
        }
    }
}

@(test)
test_stream_vazio :: proc(t: ^testing.T) {
    // um stream cujo primeiro meta-bloco já é ISLAST+ISLASTEMPTY
    got, err := decode(#load("testdata/empty.br"))
    defer delete(got)
    testing.expectf(t, err == .None, "erro %v", err)
    testing.expectf(t, len(got) == 0, "saíram %d bytes de um stream vazio", len(got))
}

// ── caminhos que o codificador de referência não emite ──────────────────────
//
// Nenhum vetor gerado pelo brotli de referência contém meta-bloco de METADADOS,
// e ele raramente emite meta-bloco NÃO COMPRIMIDO. São dois ramos inteiros do
// formato que passariam sem cobertura nenhuma. Os streams abaixo foram montados
// bit a bit a partir da seção 9.2 — que é também a única forma de conferir que
// eu li a ordem dos campos certo.

@(test)
test_meta_bloco_de_metadados_e_pulado :: proc(t: ^testing.T) {
    // WBITS=16 (1 bit 0) · ISLAST=0 · MNIBBLES=0 (padrão 11) · reservado=0 ·
    // MSKIPBYTES=1 · MSKIPLEN-1=2 · enchimento até o byte · "abc" ·
    // meta-bloco final vazio (ISLAST=1, ISLASTEMPTY=1).
    // Os metadados NÃO são saída nem entram na janela.
    src := []byte{0x2C, 0x01, 'a', 'b', 'c', 0x03}
    got, err := decode(src)
    defer delete(got)
    testing.expectf(t, err == .None, "erro %v", err)
    testing.expectf(t, len(got) == 0, "metadados viraram %d bytes de saída", len(got))
}

@(test)
test_meta_bloco_nao_comprimido :: proc(t: ^testing.T) {
    // WBITS=16 · ISLAST=0 · MNIBBLES=4 (padrão 00) · MLEN-1=4 ·
    // ISUNCOMPRESSED=1 · enchimento · "HELLO" · meta-bloco final vazio.
    src := []byte{0x40, 0x00, 0x10, 'H', 'E', 'L', 'L', 'O', 0x03}
    got, err := decode(src)
    defer delete(got)
    testing.expectf(t, err == .None, "erro %v", err)
    testing.expectf(t, string(got) == "HELLO", "veio %q", string(got))
}

// ── rejeição: o que a RFC manda REJEITAR ────────────────────────────────────

@(test)
test_recusa_wbits_invalido :: proc(t: ^testing.T) {
    // O padrão 0010001 dá WBITS=9, e a RFC diz explicitamente que ele é
    // inválido e não deve ser usado (a faixa é 10..24). Lido do bit menos
    // significativo, esse padrão é o byte 0x11.
    got, err := decode([]byte{0x11, 0, 0, 0})
    defer delete(got)
    testing.expectf(t, err == .Invalid, "esperava .Invalid, veio %v", err)
}

@(test)
test_recusa_truncado :: proc(t: ^testing.T) {
    full := #load("testdata/rfctext.br")
    // cortar em vários pontos: qualquer corte tem de dar erro, nunca uma
    // saída "quase certa" nem um travamento
    for cut in ([]int{1, 2, 5, 17, 100, 1000}) {
        if cut >= len(full) do continue
        got, err := decode(full[:cut])
        defer delete(got)
        testing.expectf(t, err != .None, "corte em %d passou como válido", cut)
    }
}

@(test)
test_teto_de_saida_e_respeitado :: proc(t: ^testing.T) {
    // `zeros` descomprime 100 KB a partir de poucas dezenas de bytes: é o
    // formato de uma bomba de descompressão. Os bytes vêm da REDE, então o
    // teto não é zelo.
    br := #load("testdata/zeros.br")
    got, err := decode(br, 1000)
    defer delete(got)
    testing.expectf(t, err == .Too_Large, "esperava .Too_Large, veio %v", err)

    // e com teto suficiente o MESMO stream passa — senão o teste acima
    // passaria por qualquer motivo
    got2, err2 := decode(br, 100000)
    defer delete(got2)
    testing.expectf(t, err2 == .None, "com teto de 100000 devia passar, veio %v", err2)
    testing.expect(t, len(got2) == 100000, "tamanho errado com teto suficiente")
}

// ── transformações de palavra do dicionário ─────────────────────────────────

@(test)
test_transformacao_ferment_e_omit :: proc(t: ^testing.T) {
    buf: [64]u8
    w := transmute([]u8)string("word")

    n := apply_transform(buf[:], w, Transform{"", .Identity, ""})
    testing.expect(t, string(buf[:n]) == "word", "Identity")

    n = apply_transform(buf[:], w, Transform{"", .FermentFirst, ""})
    testing.expectf(t, string(buf[:n]) == "Word", "FermentFirst deu %q", string(buf[:n]))

    n = apply_transform(buf[:], w, Transform{"", .FermentAll, ""})
    testing.expectf(t, string(buf[:n]) == "WORD", "FermentAll deu %q", string(buf[:n]))

    n = apply_transform(buf[:], w, Transform{" ", .Identity, " the "})
    testing.expectf(t, string(buf[:n]) == " word the ", "prefixo/sufixo deu %q", string(buf[:n]))

    n = apply_transform(buf[:], w, Transform{"", .OmitFirst2, ""})
    testing.expectf(t, string(buf[:n]) == "rd", "OmitFirst2 deu %q", string(buf[:n]))

    n = apply_transform(buf[:], w, Transform{"", .OmitLast1, ""})
    testing.expectf(t, string(buf[:n]) == "wor", "OmitLast1 deu %q", string(buf[:n]))

    // omitir mais do que a palavra tem dá vazio, não estouro
    n = apply_transform(buf[:], w, Transform{"[", .OmitFirst9, "]"})
    testing.expectf(t, string(buf[:n]) == "[]", "OmitFirst9 de 4 bytes deu %q", string(buf[:n]))
}

// O Ferment da RFC é CIENTE de UTF-8: em byte >= 0xC0 ele mexe no byte
// seguinte, não no atual. Escrever "if é minúscula, xor 32" pareceria certo e
// quebraria todo acento.
@(test)
test_ferment_e_ciente_de_utf8 :: proc(t: ^testing.T) {
    buf: [64]u8
    src := transmute([]u8)string("ábaco") // "á" = C3 A1
    n := apply_transform(buf[:], src, Transform{"", .FermentFirst, ""})
    testing.expectf(t, string(buf[:n]) == "Ábaco", "FermentFirst de \"ábaco\" deu %q", string(buf[:n]))
    testing.expect(t, n == len(src), "o comprimento em bytes não muda")
}

// ── leitor de bits ──────────────────────────────────────────────────────────

@(test)
test_leitor_de_bits_lsb_primeiro :: proc(t: ^testing.T) {
    // O exemplo da seção 1.5.1: os bytes 0x96 0xC5 0xE2 carregam, em ordem,
    // o inteiro de 3 bits 6, o de 4 bits 2, dois códigos de prefixo e o
    // inteiro de 12 bits 3628.
    r := Reader{src = []byte{0x96, 0xC5, 0xE2}}
    testing.expect(t, take(&r, 3) == 6, "inteiro de 3 bits")
    testing.expect(t, take(&r, 4) == 2, "inteiro de 4 bits")
    // os códigos de prefixo 110 e 10 ocupam 5 bits no total
    _ = take(&r, 5)
    testing.expectf(t, take(&r, 12) == 3628, "inteiro de 12 bits")
    testing.expect(t, r.err == .None, "não devia ter faltado byte")
}

@(test)
test_leitor_acusa_falta_de_byte :: proc(t: ^testing.T) {
    r := Reader{src = []byte{0xFF}}
    _ = take(&r, 8)
    _ = take(&r, 1)
    testing.expectf(t, r.err == .Truncated, "esperava .Truncated, veio %v", r.err)
}

@(test)
test_alpha_bits :: proc(t: ^testing.T) {
    testing.expect(t, alpha_bits(256) == 8, "alfabeto de literais")
    testing.expect(t, alpha_bits(704) == 10, "alfabeto de insert-and-copy")
    testing.expect(t, alpha_bits(26) == 5, "alfabeto de contagem de bloco")
    testing.expect(t, alpha_bits(2) == 1, "o menor alfabeto")
}

// ── decomposição do código de insert-and-copy ───────────────────────────────
//
// Espelha a GRADE da seção 5 em vez de repetir a fórmula do código: se os dois
// vetores de grupo estiverem trocados, isto cai.
@(test)
test_grade_de_insert_and_copy :: proc(t: ^testing.T) {
    Caso :: struct {
        cmd:                 int,
        insert_lo, copy_lo:  int,
        implicito_zero:      bool,
    }
    // (primeiro código de cada célula da grade, com a faixa que ela abre)
    casos := []Caso{
        {0, 0, 0, true}, {64, 0, 8, true},
        {128, 0, 0, false}, {192, 0, 8, false},
        {256, 8, 0, false}, {320, 8, 8, false},
        {384, 0, 16, false}, {448, 16, 0, false},
        {512, 8, 16, false}, {576, 16, 8, false},
        {640, 16, 16, false},
    }
    for c in casos {
        ri := c.cmd >> 6
        icode := IC_INSERT_GROUP[ri] * 8 + ((c.cmd >> 3) & 7)
        ccode := IC_COPY_GROUP[ri] * 8 + (c.cmd & 7)
        testing.expectf(t, icode == c.insert_lo, "cmd %d: insert code %d, esperava %d", c.cmd, icode, c.insert_lo)
        testing.expectf(t, ccode == c.copy_lo, "cmd %d: copy code %d, esperava %d", c.cmd, ccode, c.copy_lo)
        testing.expectf(t, (c.cmd < 128) == c.implicito_zero, "cmd %d: distância implícita", c.cmd)
    }
    // e o último código do alfabeto cai na última célula
    testing.expect(t, IC_INSERT_GROUP[703 >> 6] * 8 + ((703 >> 3) & 7) == 23, "insert code de 703")
    testing.expect(t, IC_COPY_GROUP[703 >> 6] * 8 + (703 & 7) == 23, "copy code de 703")
}

@(test)
test_tabelas_de_comprimento_sao_contiguas :: proc(t: ^testing.T) {
    // cada faixa começa onde a anterior termina: base[i+1] == base[i] + 2^extra[i]
    for i in 0 ..< 23 {
        want := INSERT_BASE[i] + (1 << INSERT_EXTRA[i])
        testing.expectf(t, INSERT_BASE[i + 1] == want,
            "insert: base[%d]=%d, esperava %d", i + 1, INSERT_BASE[i + 1], want)
        want = COPY_BASE[i] + (1 << COPY_EXTRA[i])
        testing.expectf(t, COPY_BASE[i + 1] == want,
            "copy: base[%d]=%d, esperava %d", i + 1, COPY_BASE[i + 1], want)
    }
    for i in 0 ..< 25 {
        want := BLOCK_BASE[i] + (1 << BLOCK_EXTRA[i])
        testing.expectf(t, BLOCK_BASE[i + 1] == want,
            "block: base[%d]=%d, esperava %d", i + 1, BLOCK_BASE[i + 1], want)
    }
    testing.expect(t, INSERT_BASE[0] == 0 && COPY_BASE[0] == 2 && BLOCK_BASE[0] == 1, "primeiras faixas")
}

@(test)
test_inverse_mtf :: proc(t: ^testing.T) {
    // move-to-front inverso: uma sequência de zeros devolve o mesmo valor
    v := []u8{0, 0, 0}
    inverse_mtf(v)
    testing.expect(t, slice.equal(v, []u8{0, 0, 0}), "zeros ficam zeros")
    // 1 traz o índice 1 para a frente; o 1 seguinte devolve o que estava em 0
    w := []u8{1, 1, 0}
    inverse_mtf(w)
    testing.expectf(t, slice.equal(w, []u8{1, 0, 0}), "veio %v", w)
}
