package brotli

// Decodificador de Brotli (RFC 7932).
//
// Existe para destravar o WOFF2, que é "um SFNT com as tabelas transformadas,
// tudo dentro de UM stream Brotli". No M224 o `@font-face` ficou capaz de
// TTF/OTF/WOFF1 e o WOFF2 ficou de fora exatamente por isto: `core:compress`
// tem zlib, não tem Brotli. E woff2 é o que os provedores servem por padrão
// para navegador moderno — tanto que naquele marco a saída foi PEDIR o formato
// antigo (mandar a requisição de fonte sem User-Agent, para o Google Fonts
// responder `.ttf`). Com este arquivo essa concessão deixa de ser necessária.
//
// ── Recorte ─────────────────────────────────────────────────────────────────
// Só DECODIFICA. Não há compressor e não precisamos de um.
//
// ── Sobre as tabelas ────────────────────────────────────────────────────────
// O dicionário estático (122.784 bytes), as 121 transformações de palavra e as
// três tabelas de contexto NÃO foram digitadas: `tools/brotli-tables.py` as
// extrai do texto da RFC e confere os CRC-32 que a própria RFC publica. Os
// mesmos CRC são reconferidos em `brotli_test.odin`.
//
// ── Sobre desempenho ────────────────────────────────────────────────────────
// A decodificação de símbolo é bit a bit (até 15 iterações), na forma canônica
// do RFC 1951, sem tabela de lookup. Para fonte (dezenas a centenas de KB) o
// custo é irrelevante e a forma canônica é auditável linha a linha. Se algum
// dia o Brotli for usado para CORPO de HTTP, é `huff_get` que ganha uma tabela
// de 8 bits com fallback para o caminho bit a bit — e nada mais muda.

import "core:mem"

MAX_CODE_LEN :: 15 // seção 3.2
DEFAULT_LIMIT :: 64 << 20 // teto de saída quando o chamador não dá um

Error :: enum u8 {
    None = 0,
    Truncated, // acabaram os bytes no meio de um campo
    Invalid,   // stream malformado — a RFC manda REJEITAR, não adivinhar
    Too_Large, // a saída passou do teto pedido pelo chamador
}

// ── leitor de bits ──────────────────────────────────────────────────────────
//
// O stream é LSB-primeiro dentro do byte (seção 1.5.1). Valores inteiros vêm
// do bit menos significativo; códigos de PREFIXO vêm do bit mais significativo
// do código — o que faz o laço canônico `code = (code << 1) | bit` funcionar,
// exatamente como no DEFLATE.

@(private)
Reader :: struct {
    src:   []byte,
    pos:   int,  // próximo byte a entrar no acumulador
    bits:  u64,  // acumulador
    nbits: uint, // bits válidos em `bits`
    err:   Error,
}

@(private)
take :: proc(r: ^Reader, n: uint) -> u32 {
    if n == 0 do return 0
    for r.nbits < n {
        if r.pos >= len(r.src) {
            if r.err == .None do r.err = .Truncated
            return 0
        }
        r.bits |= u64(r.src[r.pos]) << r.nbits
        r.pos += 1
        r.nbits += 8
    }
    v := u32(r.bits & ((u64(1) << n) - 1))
    r.bits >>= n
    r.nbits -= n
    return v
}

// Descarta os bits até o próximo byte. A RFC exige que sejam ZERO em todos os
// pontos onde isto é usado (metadados, meta-bloco não comprimido).
@(private)
align_byte :: proc(r: ^Reader) -> bool {
    n := r.nbits % 8
    return n == 0 || take(r, n) == 0
}

// Bytes crus a partir da posição alinhada. Só vale depois de `align_byte`.
@(private)
take_bytes :: proc(r: ^Reader, n: int) -> ([]byte, bool) {
    p := r.pos - int(r.nbits / 8)
    if n < 0 || p + n > len(r.src) do return nil, false
    r.bits, r.nbits, r.pos = 0, 0, p + n
    return r.src[p:p + n], true
}

// ── códigos de prefixo canônicos ────────────────────────────────────────────

@(private)
Huff :: struct {
    counts:  [MAX_CODE_LEN + 1]u16,
    symbols: []u16, // ordenados por (comprimento, símbolo)
    max_len: uint,
    single:  i32, // >= 0 quando o código tem UM símbolo, de comprimento zero
}

// Um código de um símbolo só não emite bit nenhum (seções 3.4 e 3.5).
@(private)
huff_one :: proc(h: ^Huff, sym: u16) {
    h^ = Huff{single = i32(sym)}
}

@(private)
huff_build :: proc(h: ^Huff, lens: []u8, max_len: uint, alloc: mem.Allocator) -> bool {
    h^ = Huff{single = -1, max_len = max_len}
    n := 0
    for l in lens {
        if uint(l) > max_len do return false
        if l != 0 {
            h.counts[l] += 1
            n += 1
        }
    }
    if n < 2 do return false // um código completo precisa de ao menos dois símbolos
    // Kraft: a soma de (1<<max_len)>>len tem de fechar EXATO. Frouxo demais
    // aceitaria código incompleto (buraco = leitura de lixo); apertado demais
    // aceitaria sobre-inscrição (dois símbolos com o mesmo código).
    left := 1 << max_len
    for l in 1 ..= int(max_len) do left -= int(h.counts[l]) << (max_len - uint(l))
    if left != 0 do return false

    start: [MAX_CODE_LEN + 2]u16
    for l in 1 ..= int(max_len) do start[l + 1] = start[l] + h.counts[l]
    h.symbols = make([]u16, n, alloc)
    for l, s in lens {
        if l != 0 {
            h.symbols[start[l]] = u16(s)
            start[l] += 1
        }
    }
    return true
}

@(private)
huff_get :: proc(r: ^Reader, h: ^Huff) -> u16 {
    if h.single >= 0 do return u16(h.single)
    code, first, index := 0, 0, 0
    for l in 1 ..= int(h.max_len) {
        code |= int(take(r, 1))
        cnt := int(h.counts[l])
        if code - first < cnt do return h.symbols[index + code - first]
        index += cnt
        first = (first + cnt) << 1
        code <<= 1
    }
    if r.err == .None do r.err = .Invalid
    return 0
}

// Código FIXO do alfabeto de comprimentos (seção 3.5). Os padrões da RFC estão
// escritos como aparecem nos bytes, lidos da direita para a esquerda:
//   0 -> 00    1 -> 0111   2 -> 011
//   3 -> 10    4 -> 01     5 -> 1111
@(private)
take_cl_prefix :: proc(r: ^Reader) -> u8 {
    v := take(r, 2)
    if v == 0 do return 0
    if v == 1 do return 4
    if v == 2 do return 3
    if take(r, 1) == 0 do return 2
    return take(r, 1) == 0 ? 1 : 5
}

// O código de comprimento variável usado por NBLTYPES* e NTREES* (seção 9.2).
@(private)
take_var_count :: proc(r: ^Reader) -> int {
    if take(r, 1) == 0 do return 1
    n := uint(take(r, 3))
    if n == 0 do return 2
    return int(1 << n) + 1 + int(take(r, n))
}

// Menor número de bits que endereça todo o alfabeto (seção 3.4).
@(private)
alpha_bits :: proc(size: int) -> uint {
    b: uint = 0
    for (1 << b) < size do b += 1
    return b
}

MAX_ALPHABET :: 704 // o maior é o de insert-and-copy

@(private)
read_prefix :: proc(r: ^Reader, h: ^Huff, size: int, alloc: mem.Allocator) -> bool {
    if size < 2 || size > MAX_ALPHABET do return false
    lens: [MAX_ALPHABET]u8

    hskip := take(r, 2)
    if hskip == 1 {
        // ── código SIMPLES (seção 3.4) ──
        nsym := int(take(r, 2)) + 1
        ab := alpha_bits(size)
        syms: [4]u16
        for i in 0 ..< nsym {
            s := int(take(r, ab))
            if s >= size do return false
            for j in 0 ..< i do if int(syms[j]) == s do return false // repetido
            syms[i] = u16(s)
        }
        if r.err != .None do return false
        switch nsym {
        case 1:
            huff_one(h, syms[0])
            return true
        case 2:
            lens[syms[0]] = 1
            lens[syms[1]] = 1
        case 3:
            lens[syms[0]] = 1
            lens[syms[1]] = 2
            lens[syms[2]] = 2
        case 4:
            // o bit tree-select escolhe entre as duas árvores de 4 símbolos
            if take(r, 1) == 0 {
                for i in 0 ..< 4 do lens[syms[i]] = 2
            } else {
                lens[syms[0]] = 1
                lens[syms[1]] = 2
                lens[syms[2]] = 3
                lens[syms[3]] = 3
            }
        }
        return huff_build(h, lens[:size], MAX_CODE_LEN, alloc)
    }

    // ── código COMPLEXO (seção 3.5) ──
    ORDER := [18]u8{1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15}
    cl: [18]u8
    space, ncodes := 32, 0
    for i := int(hskip); i < 18 && space > 0; i += 1 {
        v := take_cl_prefix(r)
        if v != 0 {
            cl[ORDER[i]] = v
            space -= 32 >> uint(v)
            ncodes += 1
        }
    }
    if r.err != .None do return false
    if ncodes != 1 && space != 0 do return false

    clh: Huff
    if ncodes == 1 {
        // um único comprimento não-zero: esse símbolo sai sem consumir bit
        clh.single = -1
        for v, s in cl do if v != 0 {
            huff_one(&clh, u16(s))
            break
        }
    } else if !huff_build(&clh, cl[:], 5, alloc) {
        return false
    }
    defer delete(clh.symbols, alloc)

    // Sequência de comprimentos do alfabeto de verdade, com os códigos de
    // repetição 16 (repete o último não-zero) e 17 (repete zero).
    symbol, repeat := 0, 0
    prev_len, repeat_len: u8 = 8, 0 // "previous length is taken to be 8"
    space2 := 1 << MAX_CODE_LEN
    for symbol < size && space2 > 0 {
        c := int(huff_get(r, &clh))
        if r.err != .None do return false
        if c < 16 {
            lens[symbol] = u8(c)
            symbol += 1
            if c != 0 {
                prev_len = u8(c)
                space2 -= (1 << MAX_CODE_LEN) >> uint(c)
            }
            repeat = 0
            continue
        }
        extra: uint = c == 16 ? 2 : 3
        new_len: u8 = c == 16 ? prev_len : 0
        // um 16 não modifica a contagem de um 17 logo antes, nem vice-versa
        if repeat_len != new_len {
            repeat = 0
            repeat_len = new_len
        }
        old := repeat
        if repeat > 0 {
            repeat -= 2
            repeat <<= extra
        }
        repeat += int(take(r, extra)) + 3
        delta := repeat - old
        if symbol + delta > size do return false
        for _ in 0 ..< delta {
            lens[symbol] = repeat_len
            symbol += 1
        }
        if repeat_len != 0 do space2 -= delta << (MAX_CODE_LEN - uint(repeat_len))
    }
    if space2 != 0 do return false
    return huff_build(h, lens[:size], MAX_CODE_LEN, alloc)
}

// ── mapa de contexto (seção 7.3) ────────────────────────────────────────────

@(private)
inverse_mtf :: proc(v: []u8) {
    mtf: [256]u8
    for i in 0 ..< 256 do mtf[i] = u8(i)
    for i in 0 ..< len(v) {
        index := v[i]
        value := mtf[index]
        v[i] = value
        for j := index; j > 0; j -= 1 do mtf[j] = mtf[j - 1]
        mtf[0] = value
    }
}

@(private)
read_context_map :: proc(r: ^Reader, cmap: []u8, ntrees: int, alloc: mem.Allocator) -> bool {
    rlemax := 0
    if take(r, 1) != 0 do rlemax = int(take(r, 4)) + 1
    h: Huff
    if !read_prefix(r, &h, ntrees + rlemax, alloc) do return false
    defer delete(h.symbols, alloc)

    i := 0
    for i < len(cmap) {
        c := int(huff_get(r, &h))
        if r.err != .None do return false
        switch {
        case c == 0:
            cmap[i] = 0
            i += 1
        case c <= rlemax: // corrida de zeros
            n := (1 << uint(c)) + int(take(r, uint(c)))
            if i + n > len(cmap) do return false
            for _ in 0 ..< n {
                cmap[i] = 0
                i += 1
            }
        case:
            v := c - rlemax
            if v > 255 do return false
            cmap[i] = u8(v)
            i += 1
        }
    }
    if take(r, 1) != 0 do inverse_mtf(cmap)
    for v in cmap do if int(v) >= ntrees do return false
    return true
}

// ── tabelas de comprimento (seções 5 e 6) ───────────────────────────────────

@(private)
INSERT_EXTRA := [24]uint{0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24}
@(private)
INSERT_BASE := [24]int{0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594}
@(private)
COPY_EXTRA := [24]uint{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24}
@(private)
COPY_BASE := [24]int{2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118}
@(private)
BLOCK_EXTRA := [26]uint{2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24}
@(private)
BLOCK_BASE := [26]int{1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625}

// Decomposição do código de insert-and-copy (seção 5). A tabela da RFC é uma
// grade de células de 64 valores; estes dois vetores são a coluna "grupo de 8"
// de cada célula, na ordem do índice `cmd >> 6`:
//
//   cmd>>6:      0     1     2     3     4     5     6     7     8     9    10
//   insert:   0..7  0..7  0..7  0..7 8..15 8..15  0..7 16..  8..15 16..  16..
//   copy:     0..7 8..15  0..7 8..15  0..7 8..15 16..   0..7 16..  8..15 16..
//
// As duas primeiras células (cmd < 128) são as que trazem o símbolo de
// distância IMPLÍCITO zero.
@(private)
IC_INSERT_GROUP := [11]int{0, 0, 0, 0, 1, 1, 0, 2, 1, 2, 2}
@(private)
IC_COPY_GROUP := [11]int{0, 1, 0, 1, 0, 1, 2, 0, 2, 1, 2}

// Os 16 símbolos especiais de distância (seção 4): (índice no anel, delta).
@(private)
DIST_SHORT := [16][2]int{
    {0, 0}, {1, 0}, {2, 0}, {3, 0},
    {0, -1}, {0, 1}, {0, -2}, {0, 2}, {0, -3}, {0, 3},
    {1, -1}, {1, 1}, {1, -2}, {1, 2}, {1, -3}, {1, 3},
}

// ── dicionário estático (seção 8) ───────────────────────────────────────────

DICT := #load("dict.bin")

@(private)
NDBITS := [25]uint{0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5}

// Deslocamento da primeira palavra de cada comprimento. Derivado de NDBITS pela
// recursão da seção 8 em vez de digitado: `dict_size()` tem de dar exatamente
// os 122.784 bytes de `dict.bin`, e há teste para isso.
@(private)
DOFFSET: [25]int

// `"contextless"` é EXIGIDO em @(init) (o context ainda não existe quando o
// runtime roda os inicializadores). Por isso `nwords` também é contextless —
// é aritmética pura, não aloca e não usa allocator/logger.
@(init)
init_doffset :: proc "contextless" () {
    for l in 0 ..< 24 do DOFFSET[l + 1] = DOFFSET[l] + l * nwords(l)
}

@(private)
nwords :: proc "contextless" (l: int) -> int {
    return l < 4 ? 0 : 1 << NDBITS[l]
}

@(private)
dict_size :: proc() -> int {
    return DOFFSET[24] + 24 * nwords(24)
}

Transform_Kind :: enum u8 {
    Identity, FermentFirst, FermentAll,
    OmitFirst1, OmitFirst2, OmitFirst3, OmitFirst4, OmitFirst5,
    OmitFirst6, OmitFirst7, OmitFirst8, OmitFirst9,
    OmitLast1, OmitLast2, OmitLast3, OmitLast4, OmitLast5,
    OmitLast6, OmitLast7, OmitLast8, OmitLast9,
}

Transform :: struct {
    prefix: string,
    kind:   Transform_Kind,
    suffix: string,
}

// Ferment* da seção 8, transcrito do C da RFC. Devolve quantos bytes do ponto
// `pos` foram consumidos (1..3 — é consciente de UTF-8).
@(private)
ferment :: proc(w: []u8, pos: int) -> int {
    if w[pos] < 192 {
        if w[pos] >= 97 && w[pos] <= 122 do w[pos] ~= 32
        return 1
    }
    if w[pos] < 224 {
        if pos + 1 < len(w) do w[pos + 1] ~= 32
        return 2
    }
    if pos + 2 < len(w) do w[pos + 2] ~= 5
    return 3
}

// prefixo + T(palavra) + sufixo. A RFC garante no máximo 13 bytes a mais que a
// palavra base (24), então 64 sobra.
@(private)
apply_transform :: proc(dst: []u8, word: []byte, t: Transform) -> int {
    n := copy(dst, transmute([]u8)t.prefix)
    w := word
    k := int(t.kind)
    switch {
    case k >= int(Transform_Kind.OmitFirst1) && k <= int(Transform_Kind.OmitFirst9):
        omit := k - int(Transform_Kind.OmitFirst1) + 1
        w = len(w) <= omit ? w[:0] : w[omit:]
    case k >= int(Transform_Kind.OmitLast1) && k <= int(Transform_Kind.OmitLast9):
        omit := k - int(Transform_Kind.OmitLast1) + 1
        w = len(w) <= omit ? w[:0] : w[:len(w) - omit]
    }
    m := copy(dst[n:], w)
    // o ferment opera sobre a cópia já escrita no destino
    if len(w) > 0 {
        body := dst[n:n + m]
        #partial switch t.kind {
        case .FermentFirst:
            ferment(body, 0)
        case .FermentAll:
            for i := 0; i < len(body); i += ferment(body, i) {}
        }
    }
    n += m
    n += copy(dst[n:], transmute([]u8)t.suffix)
    return n
}

// ── blocos (seção 6) ────────────────────────────────────────────────────────

@(private)
Block :: struct {
    ntypes: int,
    htype:  Huff, // código sobre os tipos de bloco
    hlen:   Huff, // código sobre as contagens
    btype:  int,
    prev:   int,
    blen:   int,
}

@(private)
NO_SWITCH :: 1 << 24 // 16777216: contagem "infinita" quando só há um tipo

@(private)
read_block_count :: proc(r: ^Reader, h: ^Huff) -> int {
    c := int(huff_get(r, h))
    if c >= 26 {
        if r.err == .None do r.err = .Invalid
        return 0
    }
    return BLOCK_BASE[c] + int(take(r, BLOCK_EXTRA[c]))
}

@(private)
read_blocks :: proc(r: ^Reader, b: ^Block, alloc: mem.Allocator) -> bool {
    b.ntypes = take_var_count(r)
    if b.ntypes < 1 || b.ntypes > 256 do return false
    // "the previous and current block types are initialized to 1 and 0"
    b.btype, b.prev = 0, 1
    if b.ntypes < 2 {
        b.blen = NO_SWITCH
        return true
    }
    if !read_prefix(r, &b.htype, b.ntypes + 2, alloc) do return false
    if !read_prefix(r, &b.hlen, 26, alloc) do return false
    b.blen = read_block_count(r, &b.hlen)
    return r.err == .None && b.blen > 0
}

@(private)
block_next :: proc(r: ^Reader, b: ^Block) {
    if b.blen == 0 {
        if b.ntypes < 2 {
            b.blen = NO_SWITCH // só um tipo: nunca há troca a ler
        } else {
            s := int(huff_get(r, &b.htype))
            nt: int
            switch {
            case s == 0:           nt = b.prev
            case s == 1:           nt = (b.btype + 1) % b.ntypes
            case s < b.ntypes + 2: nt = s - 2
            case:
                if r.err == .None do r.err = .Invalid
                return
            }
            b.prev, b.btype = b.btype, nt
            b.blen = read_block_count(r, &b.hlen)
            if r.err != .None do return
            if b.blen <= 0 {
                r.err = .Invalid
                return
            }
        }
    }
    b.blen -= 1
}

// ── contexto do literal (seção 7.1) ─────────────────────────────────────────

@(private)
ctx_id :: proc(mode: u8, p1, p2: u8) -> int {
    switch mode {
    case 0: return int(p1 & 0x3f)          // LSB6
    case 1: return int(p1 >> 2)            // MSB6
    case 2: return int(LUT0[p1] | LUT1[p2]) // UTF8
    case:   return int((LUT2[p1] << 3) | LUT2[p2]) // Signed
    }
}

@(private)
free_huffs :: proc(hs: []Huff, alloc: mem.Allocator) {
    for &h in hs do delete(h.symbols, alloc)
    delete(hs, alloc)
}

// ── decodificação ───────────────────────────────────────────────────────────

// `limit` é o teto de bytes de saída — 0 usa DEFAULT_LIMIT. Não é zelo: os
// bytes vêm da REDE, e um stream de poucos KB pode pedir gigabytes de saída.
decode :: proc(
    src: []byte,
    limit := 0,
    allocator := context.allocator,
) -> (
    res: []byte,
    err: Error,
) {
    cap_out := limit > 0 ? limit : DEFAULT_LIMIT
    r := Reader{src = src}
    out := make([dynamic]u8, 0, min(cap_out, 64 << 10), allocator)
    ok := false
    defer if !ok do delete(out)

    wbits := take_wbits(&r)
    if r.err != .None do return nil, r.err
    if wbits < 10 || wbits > 24 do return nil, .Invalid
    window := (1 << uint(wbits)) - 16

    // Anel das 4 últimas distâncias: [última, 2ª, 3ª, 4ª]. Inicializado no
    // começo do STREAM (não do meta-bloco) e nunca reiniciado — seção 4.
    rb := [4]u32{4, 11, 15, 16}

    for {
        islast := take(&r, 1) != 0
        if islast && take(&r, 1) != 0 do break // ISLASTEMPTY
        if r.err != .None do return nil, r.err

        mnib := take(&r, 2)
        if mnib == 3 {
            // meta-bloco de METADADOS: não produz saída nenhuma
            if take(&r, 1) != 0 do return nil, .Invalid // bit reservado
            nsk := uint(take(&r, 2))
            skip := 0
            if nsk > 0 {
                v := int(take(&r, nsk * 8))
                if nsk > 1 && (v >> ((nsk - 1) * 8)) == 0 do return nil, .Invalid
                skip = v + 1
            }
            if !align_byte(&r) do return nil, .Invalid
            if _, k := take_bytes(&r, skip); !k do return nil, .Truncated
            if islast do break
            continue
        }

        nnib := uint(mnib) + 4
        mlen := int(take(&r, nnib * 4)) + 1
        if r.err != .None do return nil, r.err
        if nnib > 4 && ((mlen - 1) >> ((nnib - 1) * 4)) == 0 do return nil, .Invalid

        if !islast && take(&r, 1) != 0 {
            // ISUNCOMPRESSED: MLEN bytes literais, alinhados
            if !align_byte(&r) do return nil, .Invalid
            b, k := take_bytes(&r, mlen)
            if !k do return nil, .Truncated
            if len(out) + mlen > cap_out do return nil, .Too_Large
            append(&out, ..b)
            continue
        }
        if r.err != .None do return nil, r.err

        // ── cabeçalho do meta-bloco (seção 9.2) ──
        blocks: [3]Block // 0=literais, 1=insert-and-copy, 2=distâncias
        defer {
            for &b in blocks {
                delete(b.htype.symbols, allocator)
                delete(b.hlen.symbols, allocator)
            }
        }
        for &b in blocks do if !read_blocks(&r, &b, allocator) do return nil, .Invalid

        npostfix := uint(take(&r, 2))
        ndirect := int(take(&r, 4)) << npostfix

        cmodes := make([]u8, blocks[0].ntypes, allocator)
        defer delete(cmodes, allocator)
        for i in 0 ..< blocks[0].ntypes do cmodes[i] = u8(take(&r, 2))

        ntreesl := take_var_count(&r)
        if ntreesl < 1 || ntreesl > 256 do return nil, .Invalid
        cmapl := make([]u8, 64 * blocks[0].ntypes, allocator)
        defer delete(cmapl, allocator)
        if ntreesl >= 2 && !read_context_map(&r, cmapl, ntreesl, allocator) do return nil, .Invalid

        ntreesd := take_var_count(&r)
        if ntreesd < 1 || ntreesd > 256 do return nil, .Invalid
        cmapd := make([]u8, 4 * blocks[2].ntypes, allocator)
        defer delete(cmapd, allocator)
        if ntreesd >= 2 && !read_context_map(&r, cmapd, ntreesd, allocator) do return nil, .Invalid

        dalpha := 16 + ndirect + (48 << npostfix)
        htreel := make([]Huff, ntreesl, allocator)
        defer free_huffs(htreel, allocator)
        htreei := make([]Huff, blocks[1].ntypes, allocator)
        defer free_huffs(htreei, allocator)
        htreed := make([]Huff, ntreesd, allocator)
        defer free_huffs(htreed, allocator)
        for i in 0 ..< ntreesl do if !read_prefix(&r, &htreel[i], 256, allocator) do return nil, .Invalid
        for i in 0 ..< blocks[1].ntypes do if !read_prefix(&r, &htreei[i], 704, allocator) do return nil, .Invalid
        for i in 0 ..< ntreesd do if !read_prefix(&r, &htreed[i], dalpha, allocator) do return nil, .Invalid

        // ── comandos (seção 9.3) ──
        produced := 0
        for produced < mlen {
            block_next(&r, &blocks[1])
            if r.err != .None do return nil, r.err
            cmd := int(huff_get(&r, &htreei[blocks[1].btype]))
            if r.err != .None do return nil, r.err
            if cmd >= 704 do return nil, .Invalid

            ri := cmd >> 6
            icode := IC_INSERT_GROUP[ri] * 8 + ((cmd >> 3) & 7)
            ccode := IC_COPY_GROUP[ri] * 8 + (cmd & 7)
            ilen := INSERT_BASE[icode] + int(take(&r, INSERT_EXTRA[icode]))
            clen := COPY_BASE[ccode] + int(take(&r, COPY_EXTRA[ccode]))
            if r.err != .None do return nil, r.err

            if produced + ilen > mlen do return nil, .Invalid
            if len(out) + ilen > cap_out do return nil, .Too_Large
            for _ in 0 ..< ilen {
                block_next(&r, &blocks[0])
                if r.err != .None do return nil, r.err
                p1 := len(out) > 0 ? out[len(out) - 1] : 0
                p2 := len(out) > 1 ? out[len(out) - 2] : 0
                bt := blocks[0].btype
                tree := int(cmapl[64 * bt + ctx_id(cmodes[bt], p1, p2)])
                if tree >= ntreesl do return nil, .Invalid
                lit := huff_get(&r, &htreel[tree])
                if r.err != .None do return nil, r.err
                append(&out, u8(lit))
                produced += 1
            }
            // o copy do ÚLTIMO comando é ignorado quando os literais já
            // completaram MLEN — e aí pode ter qualquer valor
            if produced == mlen do break

            dist: u32
            pushable := false
            if cmd < 128 {
                dist = rb[0] // símbolo de distância implícito zero: reusa a última
            } else {
                block_next(&r, &blocks[2])
                if r.err != .None do return nil, r.err
                bt := blocks[2].btype
                cidd := clen > 4 ? 3 : clen - 2
                tree := int(cmapd[4 * bt + cidd])
                if tree >= ntreesd do return nil, .Invalid
                dsym := int(huff_get(&r, &htreed[tree]))
                if r.err != .None do return nil, r.err
                if dsym >= dalpha do return nil, .Invalid
                switch {
                case dsym < 16:
                    e := DIST_SHORT[dsym]
                    v := int(rb[e[0]]) + e[1]
                    if v <= 0 do return nil, .Invalid
                    dist = u32(v)
                    pushable = dsym != 0
                case dsym < 16 + ndirect:
                    dist = u32(dsym - 16 + 1)
                    pushable = true
                case:
                    d := uint(dsym - ndirect - 16)
                    nb := 1 + (d >> (npostfix + 1))
                    dextra := u64(take(&r, nb))
                    if r.err != .None do return nil, r.err
                    hcode := d >> npostfix
                    lcode := d & ((1 << npostfix) - 1)
                    offset := ((2 + u64(hcode & 1)) << nb) - 4
                    dist = u32(((offset + dextra) << npostfix) + u64(lcode) + u64(ndirect) + 1)
                    pushable = true
                }
            }

            // O que separa uma referência para trás de uma palavra do
            // dicionário é só isto: a distância passar do que existe.
            max_back := min(window, len(out))
            if int(dist) <= max_back {
                if pushable {
                    rb[3], rb[2], rb[1], rb[0] = rb[2], rb[1], rb[0], dist
                }
                if produced + clen > mlen do return nil, .Invalid
                if len(out) + clen > cap_out do return nil, .Too_Large
                start := len(out) - int(dist)
                for k in 0 ..< clen {
                    // a origem pode SOBREPOR o destino, e isso é intencional:
                    // <len 5, dist 2> sobre "XY" produz XYXYX
                    v := out[start + k]
                    append(&out, v)
                }
                produced += clen
            } else {
                // palavra do dicionário estático — nunca entra no anel
                if clen < 4 || clen > 24 do return nil, .Invalid
                word_id := int(dist) - max_back - 1
                nb := NDBITS[clen]
                mask := (int(1) << nb) - 1 // NWORDS[len] é potência de 2
                index := word_id & mask
                tid := word_id >> nb
                if tid > 120 do return nil, .Invalid
                off := DOFFSET[clen] + index * clen
                buf: [64]u8
                n := apply_transform(buf[:], DICT[off:off + clen], TRANSFORMS[tid])
                if produced + n > mlen do return nil, .Invalid
                if len(out) + n > cap_out do return nil, .Too_Large
                append(&out, ..buf[:n])
                produced += n
            }
        }
        if islast do break
    }

    ok = true
    return out[:], .None
}

// WBITS do cabeçalho do stream (seção 9.1). O valor 9 é alcançável pelo código
// e é INVÁLIDO — quem chama confere a faixa 10..24.
@(private)
take_wbits :: proc(r: ^Reader) -> int {
    if take(r, 1) == 0 do return 16
    if n := take(r, 3); n != 0 do return 17 + int(n)
    if m := take(r, 3); m != 0 do return 8 + int(m)
    return 17
}
