package woff2

// WOFF2 → SFNT.
//
// Um WOFF2 não é "um zip de tabelas" como o WOFF1: é UM stream Brotli com
// todas as tabelas concatenadas, e duas delas chegam TRANSFORMADAS — `glyf`
// (reescrita em sub-streams paralelos, com as coordenadas em tripleto) e
// `loca` (que não viaja: é reconstruída a partir do `glyf`). Medido numa fonte
// real do Google Fonts (Roboto): `glyf` e `loca` vêm com transform version 0,
// isto é, TRANSFORMADAS — não há atalho pelo caminho de transform nula.
//
// ── Recorte ─────────────────────────────────────────────────────────────────
// Fonte individual (TrueType e CFF), transform de `glyf`/`loca` e de `hmtx`.
// FORA: coleção (`ttcf`) — recusada explicitamente, não silenciosamente.
//
// ── Sobre o resultado não ser byte-idêntico ─────────────────────────────────
// A spec diz, e é importante: a reconstrução preserva a FUNCIONALIDADE, não os
// bytes. Um mesmo contorno tem várias codificações válidas (delta em 1 ou 2
// bytes, flag repetida ou explícita), e a spec proíbe o decodificador de
// rejeitar a fonte porque o `glyf` remontado não tem o tamanho de `origLength`.
// Por isso o oráculo destes testes é RENDERIZAR, não comparar com o original.

import "core:mem"
import brotli "../brotli"

Error :: enum u8 {
    None = 0,
    Not_Woff2,   // não começa com "wOF2": quem chama tenta outro formato
    Invalid,     // é WOFF2 e está malformado
    Unsupported, // WOFF2 válido usando algo que não fazemos (coleção)
    Brotli,      // o stream não descomprimiu
}

TAG_GLYF :: u32(0x676C7966)
TAG_LOCA :: u32(0x6C6F6361)
TAG_HMTX :: u32(0x686D7478)
TAG_HHEA :: u32(0x68686561)
TAG_MAXP :: u32(0x6D617870)
TAG_HEAD :: u32(0x68656164)

SIG_WOFF2 :: u32(0x774F4632) // "wOF2"
SIG_TTCF :: u32(0x74746366) // "ttcf"

MAX_TABLES :: 512

// Teto de bytes descomprimidos. Os `origLength` do diretório são declarados
// pelo ARQUIVO, então um woff2 de 20 KB pode dizer que suas tabelas somam 4 GB.
// Fonte de verdade não passa de poucos MB; 128 MiB é folga larga.
MAX_UNCOMPRESSED :: 128 << 20

// ── leitor big-endian com limite ────────────────────────────────────────────
//
// Todo campo passa por aqui e `bad` fica gravado no cursor. É o que permite
// escrever a reconstrução sem um `if` de limite por linha: basta conferir
// `c.bad` nos pontos de junção.

@(private)
Cur :: struct {
    b:   []byte,
    at:  int,
    bad: bool,
}

@(private)
rd8 :: proc(c: ^Cur) -> u32 {
    if c.at + 1 > len(c.b) {
        c.bad = true
        return 0
    }
    v := u32(c.b[c.at])
    c.at += 1
    return v
}

@(private)
rd16 :: proc(c: ^Cur) -> u32 {
    if c.at + 2 > len(c.b) {
        c.bad = true
        return 0
    }
    v := u32(c.b[c.at]) << 8 | u32(c.b[c.at + 1])
    c.at += 2
    return v
}

@(private)
rd32 :: proc(c: ^Cur) -> u32 {
    if c.at + 4 > len(c.b) {
        c.bad = true
        return 0
    }
    v := u32(c.b[c.at]) << 24 | u32(c.b[c.at + 1]) << 16 | u32(c.b[c.at + 2]) << 8 | u32(c.b[c.at + 3])
    c.at += 4
    return v
}

@(private)
rds16 :: proc(c: ^Cur) -> int {
    return int(i16(u16(rd16(c))))
}

@(private)
rdn :: proc(c: ^Cur, n: int) -> []byte {
    if n < 0 || c.at + n > len(c.b) {
        c.bad = true
        return nil
    }
    s := c.b[c.at:c.at + n]
    c.at += n
    return s
}

// UIntBase128 (seção 4.1 da spec). A spec MANDA recusar zero à esquerda,
// sequência acima de 5 bytes e estouro de 32 bits — as três são recusa, não
// truncamento, porque um encoder correto nunca as produz.
@(private)
rd_base128 :: proc(c: ^Cur) -> u32 {
    accum: u32 = 0
    for i in 0 ..< 5 {
        v := rd8(c)
        if c.bad do return 0
        if i == 0 && v == 0x80 { // zero à esquerda
            c.bad = true
            return 0
        }
        if accum & 0xFE00_0000 != 0 { // o << 7 estouraria
            c.bad = true
            return 0
        }
        accum = (accum << 7) | (v & 0x7F)
        if v & 0x80 == 0 do return accum
    }
    c.bad = true // mais de 5 bytes
    return 0
}

// 255UInt16 (seção 4.1). ⚠️ A codificação NÃO é única — 506 pode vir como
// [255,253], [254,0] ou [253,1,250] — e a spec exige que o decodificador
// aceite as três. Daí não haver validação de forma canônica aqui.
@(private)
rd_255u16 :: proc(c: ^Cur) -> u32 {
    code := rd8(c)
    switch code {
    case 253:
        return rd16(c)
    case 255:
        return rd8(c) + 253
    case 254:
        return rd8(c) + 506
    }
    return code
}

// ── diretório ───────────────────────────────────────────────────────────────

@(private)
Entry :: struct {
    tag:         u32,
    tv:          u8,
    orig_len:    int,
    trans_len:   int,
    transformed: bool,
    data:        []byte, // fatia do stream descomprimido
    out:         []byte, // o que vai para o SFNT
    owned:       bool,   // `out` foi alocado por nós
}

// Uma tabela está transformada? A regra é ASSIMÉTRICA e é fácil errar: para
// `glyf`/`loca` a transform NULA é a versão 3 e a versão 0 é a transformada;
// para todo o resto é o contrário. Escrever "tv != 0" trataria todo glyf
// transformado como cru.
@(private)
is_transformed :: proc(tag: u32, tv: u8) -> bool {
    if tag == TAG_GLYF || tag == TAG_LOCA do return tv == 0
    return tv != 0
}

// ── entrada ─────────────────────────────────────────────────────────────────

// Devolve um SFNT novo (owned) ou nil. `Not_Woff2` é o caso benigno: quem
// chama simplesmente tenta o próximo formato.
to_sfnt :: proc(src: []byte, allocator := context.allocator) -> (res: []byte, err: Error) {
    c := Cur{b = src}
    if rd32(&c) != SIG_WOFF2 do return nil, .Not_Woff2
    flavor := rd32(&c)
    _ = rd32(&c) // length
    num := int(rd16(&c))
    _ = rd16(&c) // reserved
    _ = rd32(&c) // totalSfntSize
    total_comp := int(rd32(&c))
    _ = rd32(&c) // majorVersion / minorVersion
    _ = rd32(&c) // metaOffset
    _ = rd32(&c) // metaLength
    _ = rd32(&c) // metaOrigLength
    _ = rd32(&c) // privOffset
    _ = rd32(&c) // privLength
    if c.bad do return nil, .Invalid
    if num <= 0 || num > MAX_TABLES do return nil, .Invalid
    if flavor == SIG_TTCF do return nil, .Unsupported // coleção

    entries := make([]Entry, num, allocator)
    defer {
        for &e in entries do if e.owned do delete(e.out, allocator)
        delete(entries, allocator)
    }

    need := 0 // soma dos comprimentos DENTRO do stream descomprimido
    for &e in entries {
        flags := u8(rd8(&c))
        idx := flags & 0x3f
        e.tv = (flags >> 6) & 3
        if idx == 63 {
            e.tag = rd32(&c)
        } else {
            s := W2_KNOWN_TAGS[idx]
            e.tag = u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
        }
        e.orig_len = int(rd_base128(&c))
        e.transformed = is_transformed(e.tag, e.tv)
        if e.transformed do e.trans_len = int(rd_base128(&c))
        if c.bad do return nil, .Invalid
        // `loca` transformada é um PLACEHOLDER: declara o tamanho que a tabela
        // vai ter e não consome byte nenhum do stream (a spec exige
        // transformLength == 0).
        if e.tag == TAG_LOCA && e.transformed && e.trans_len != 0 do return nil, .Invalid
        need += e.transformed ? e.trans_len : e.orig_len
        if need < 0 || need > MAX_UNCOMPRESSED do return nil, .Invalid
    }

    comp := rdn(&c, total_comp)
    if c.bad do return nil, .Invalid

    // O teto é a soma declarada: se o stream produzir mais que isso já está
    // malformado, e o teto impede que um woff2 de 20 KB peça 1 GB.
    raw, berr := brotli.decode(comp, need, allocator)
    defer delete(raw, allocator)
    if berr != .None do return nil, .Brotli
    if len(raw) != need do return nil, .Invalid

    at := 0
    for &e in entries {
        n := e.transformed ? e.trans_len : e.orig_len
        e.data = raw[at:at + n]
        at += n
        if !e.transformed do e.out = e.data
    }

    // ── reconstrução das tabelas transformadas ──
    glyf_i, loca_i, hmtx_i := -1, -1, -1
    for &e, i in entries {
        if !e.transformed do continue
        switch e.tag {
        case TAG_GLYF: glyf_i = i
        case TAG_LOCA: loca_i = i
        case TAG_HMTX: hmtx_i = i
        case:
            // transform desconhecida para esta tabela: a spec manda rejeitar a
            // fonte inteira, não passar os bytes transformados adiante
            return nil, .Unsupported
        }
    }
    // as duas andam JUNTAS: uma sem a outra é arquivo malformado
    if (glyf_i < 0) != (loca_i < 0) do return nil, .Invalid

    xmins: []i16
    defer delete(xmins, allocator)
    if glyf_i >= 0 {
        g, l, xs, long, ok := rebuild_glyf(entries[glyf_i].data, allocator)
        if !ok {
            delete(g, allocator)
            delete(l, allocator)
            delete(xs, allocator)
            return nil, .Invalid
        }
        entries[glyf_i].out, entries[glyf_i].owned = g, true
        entries[loca_i].out, entries[loca_i].owned = l, true
        xmins = xs
        // Trocamos o formato do `loca` quando o `glyf` remontado não caberia
        // no formato curto (ver rebuild_glyf). Aí o `head` TEM de concordar,
        // senão o consumidor lê os offsets pela metade.
        if long do patch_index_to_loc(entries[:], 1, allocator)
    }
    if hmtx_i >= 0 {
        h, ok := rebuild_hmtx(entries[hmtx_i].data, entries[:], xmins, allocator)
        if !ok do return nil, .Invalid
        entries[hmtx_i].out, entries[hmtx_i].owned = h, true
    }

    return assemble(entries[:], flavor, allocator), .None
}

// `head` é uma tabela CRUA, então dá para corrigir em cima da fatia do stream
// — mas ela pertence a `raw`, que vai embora. Por isso a cópia é feita aqui.
@(private)
patch_index_to_loc :: proc(entries: []Entry, val: u16, allocator: mem.Allocator) {
    for &e in entries {
        if e.tag != TAG_HEAD || len(e.out) < 52 do continue
        if !e.owned {
            cp := make([]byte, len(e.out), allocator)
            copy(cp, e.out)
            e.out, e.owned = cp, true
        }
        put16(e.out, 50, u32(val))
        return
    }
}

// ── montagem do SFNT ────────────────────────────────────────────────────────

@(private)
put16 :: proc(d: []byte, at: int, v: u32) {
    d[at] = u8(v >> 8)
    d[at + 1] = u8(v)
}

@(private)
put32 :: proc(d: []byte, at: int, v: u32) {
    d[at] = u8(v >> 24)
    d[at + 1] = u8(v >> 16)
    d[at + 2] = u8(v >> 8)
    d[at + 3] = u8(v)
}

// checkSum de tabela do OpenType: soma de u32 big-endian, com a cauda
// completada por zeros.
@(private)
table_checksum :: proc(b: []byte) -> u32 {
    sum: u32 = 0
    i := 0
    for ; i + 4 <= len(b); i += 4 {
        sum += u32(b[i]) << 24 | u32(b[i + 1]) << 16 | u32(b[i + 2]) << 8 | u32(b[i + 3])
    }
    if i < len(b) {
        tail: u32 = 0
        for j in 0 ..< 4 {
            tail <<= 8
            if i + j < len(b) do tail |= u32(b[i + j])
        }
        sum += tail
    }
    return sum
}

@(private)
assemble :: proc(entries: []Entry, flavor: u32, allocator: mem.Allocator) -> []byte {
    n := len(entries)
    // O diretório do SFNT é ordenado por TAG; a ordem física das tabelas no
    // WOFF2 é outra (`glyf` antes de `loca`, por exigência da spec) e não
    // importa para o resultado.
    order := make([]int, n, allocator)
    defer delete(order, allocator)
    for i in 0 ..< n do order[i] = i
    // insertion sort: n <= 512 e a comparação precisa olhar `entries`
    for i in 1 ..< n {
        j := i
        for j > 0 && entries[order[j - 1]].tag > entries[order[j]].tag {
            order[j - 1], order[j] = order[j], order[j - 1]
            j -= 1
        }
    }

    total := 12 + 16 * n
    for e in entries do total += (len(e.out) + 3) & ~int(3)
    out := make([]byte, total, allocator)

    put32(out, 0, flavor)
    put16(out, 4, u32(n))
    // searchRange/entrySelector/rangeShift: derivados, como manda o formato
    sel: u32 = 0
    for (u32(1) << (sel + 1)) <= u32(n) do sel += 1
    put16(out, 6, u32(16) << sel)          // searchRange
    put16(out, 8, sel)                     // entrySelector
    put16(out, 10, u32(16 * n) - (u32(16) << sel)) // rangeShift

    data_at := 12 + 16 * n
    for oi, k in order {
        e := entries[oi]
        d := 12 + 16 * k
        put32(out, d, e.tag)
        put32(out, d + 4, table_checksum(e.out))
        put32(out, d + 8, u32(data_at))
        put32(out, d + 12, u32(len(e.out)))
        copy(out[data_at:], e.out)
        data_at += (len(e.out) + 3) & ~int(3)
    }
    return out
}
