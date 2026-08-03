package woff2

import "core:testing"

// ── tabelas geradas ─────────────────────────────────────────────────────────
//
// A spec do WOFF2 não publica CRC (diferente da RFC do Brotli), então o que
// confere a extração são INVARIANTES estruturais. O segundo é o que importa de
// verdade: se a soma dos bits não enchesse exatamente os bytes de dado, a
// decodificação de coordenada seria AMBÍGUA e não haveria como escolher certo.

@(test)
test_tripleto_tem_os_invariantes_da_spec :: proc(t: ^testing.T) {
    for r, i in W2_TRIPLET {
        bc, xb, yb := int(r[0]), int(r[1]), int(r[2])
        testing.expectf(t, bc == 1 + (xb + yb + 7) / 8,
            "índice %d: byteCount %d não bate com xbits=%d ybits=%d", i, bc, xb, yb)
        testing.expectf(t, xb + yb == 8 * (bc - 1),
            "índice %d: xbits+ybits=%d não enche %d bytes de dado", i, xb + yb, bc - 1)
        testing.expectf(t, r[5] <= 1 && r[6] <= 1, "índice %d: sinal fora de 0/1", i)
    }
    // as faixas de tamanho que a spec descreve em texto
    testing.expect(t, W2_TRIPLET[0][0] == 2 && W2_TRIPLET[83][0] == 2, "0..83 usam 1 byte de dado")
    testing.expect(t, W2_TRIPLET[84][0] == 3 && W2_TRIPLET[119][0] == 3, "84..119 usam 2 bytes")
    testing.expect(t, W2_TRIPLET[120][0] == 4 && W2_TRIPLET[123][0] == 4, "120..123 usam 3 bytes")
    testing.expect(t, W2_TRIPLET[124][0] == 5 && W2_TRIPLET[127][0] == 5, "124..127 usam 4 bytes")
}

@(test)
test_tags_conhecidas :: proc(t: ^testing.T) {
    testing.expect(t, len(W2_KNOWN_TAGS) == 63, "63 tags: o índice 63 é 'tag explícita a seguir'")
    for s, i in W2_KNOWN_TAGS {
        testing.expectf(t, len(s) == 4, "tag %d = %q não tem 4 bytes", i, s)
    }
    // âncoras: se a tabela escorregar uma posição, o diretório inteiro passa a
    // ler a tabela errada e nada mais faz sentido
    testing.expect(t, W2_KNOWN_TAGS[0] == "cmap", "0 = cmap")
    testing.expect(t, W2_KNOWN_TAGS[10] == "glyf", "10 = glyf")
    testing.expect(t, W2_KNOWN_TAGS[11] == "loca", "11 = loca")
    testing.expect(t, W2_KNOWN_TAGS[8] == "cvt ", "8 = cvt com espaço")
    testing.expect(t, W2_KNOWN_TAGS[13] == "CFF ", "13 = CFF com espaço")
    testing.expect(t, W2_KNOWN_TAGS[62] == "Sill", "62 = Sill")
}

// A regra de "está transformada?" é ASSIMÉTRICA, e é a armadilha do formato:
// para glyf/loca a transform NULA é a versão 3; para todo o resto é a 0.
@(test)
test_transformada_e_assimetrica :: proc(t: ^testing.T) {
    testing.expect(t, is_transformed(TAG_GLYF, 0), "glyf tv=0 está TRANSFORMADA")
    testing.expect(t, !is_transformed(TAG_GLYF, 3), "glyf tv=3 é transform nula")
    testing.expect(t, is_transformed(TAG_LOCA, 0), "loca tv=0 está transformada")
    testing.expect(t, !is_transformed(TAG_LOCA, 3), "loca tv=3 é nula")
    testing.expect(t, !is_transformed(TAG_HMTX, 0), "hmtx tv=0 é NULA")
    testing.expect(t, is_transformed(TAG_HMTX, 1), "hmtx tv=1 está transformada")
    testing.expect(t, !is_transformed(TAG_MAXP, 0), "maxp tv=0 é nula")
}

// ── tipos de tamanho variável ───────────────────────────────────────────────

@(test)
test_base128 :: proc(t: ^testing.T) {
    ler :: proc(b: []byte) -> (u32, bool) {
        c := Cur{b = b}
        v := rd_base128(&c)
        return v, !c.bad
    }
    v, ok := ler([]byte{0x3F})
    testing.expect(t, ok && v == 63, "um byte")
    v, ok = ler([]byte{0x87, 0x68})
    testing.expectf(t, ok && v == 1000, "dois bytes deram %d", v)
    // a spec MANDA recusar: zero à esquerda, sequência > 5 bytes, estouro
    _, ok = ler([]byte{0x80, 0x3F})
    testing.expect(t, !ok, "0x80 inicial é zero à esquerda: recusar")
    _, ok = ler([]byte{0x81, 0x81, 0x81, 0x81, 0x81, 0x01})
    testing.expect(t, !ok, "mais de 5 bytes: recusar")
    _, ok = ler([]byte{0x90, 0x80, 0x80, 0x80, 0x00})
    testing.expect(t, !ok, "estouro de 32 bits: recusar")
    _, ok = ler([]byte{0x87})
    testing.expect(t, !ok, "acabou o buffer com o bit de continuação ligado")
}

// ⚠️ A codificação de 255UInt16 NÃO é única, e a spec exige aceitar todas as
// formas. Um decodificador que só aceitasse a mais curta recusaria arquivos
// válidos de outros encoders.
@(test)
test_255u16_aceita_as_tres_formas_de_506 :: proc(t: ^testing.T) {
    ler :: proc(b: []byte) -> u32 {
        c := Cur{b = b}
        return rd_255u16(&c)
    }
    testing.expect(t, ler([]byte{0}) == 0, "0")
    testing.expect(t, ler([]byte{252}) == 252, "252, o maior de um byte")
    testing.expectf(t, ler([]byte{255, 0}) == 253, "código 255 soma 253")
    testing.expectf(t, ler([]byte{254, 0}) == 506, "código 254 soma 506")
    testing.expectf(t, ler([]byte{253, 0x12, 0x34}) == 0x1234, "código 253 é UInt16 cru")
    // as três grafias de 506 que a spec cita por nome
    testing.expect(t, ler([]byte{255, 253}) == 506, "506 como [255,253]")
    testing.expect(t, ler([]byte{254, 0}) == 506, "506 como [254,0]")
    testing.expect(t, ler([]byte{253, 1, 250}) == 506, "506 como [253,1,250]")
}

// O glifo 0 é o bit MAIS significativo do primeiro byte. Empacotar ao
// contrário trocaria as caixas de contorno de lugar entre glifos.
@(test)
test_bitmap_e_msb_primeiro :: proc(t: ^testing.T) {
    bmp := []byte{0b1000_0001, 0b0100_0000}
    testing.expect(t, bit_is_set(bmp, 0), "glifo 0 = bit mais significativo")
    testing.expect(t, !bit_is_set(bmp, 1), "glifo 1")
    testing.expect(t, bit_is_set(bmp, 7), "glifo 7 = bit menos significativo do 1º byte")
    testing.expect(t, !bit_is_set(bmp, 8), "glifo 8 = bit mais significativo do 2º byte")
    testing.expect(t, bit_is_set(bmp, 9), "glifo 9")
    testing.expect(t, !bit_is_set(bmp, 99), "fora do bitmap não estoura")
}

// ── recusa ──────────────────────────────────────────────────────────────────

@(test)
test_nao_woff2_e_caso_benigno :: proc(t: ^testing.T) {
    // um SFNT cru não é WOFF2: quem chama tem de poder tentar outro formato,
    // e por isso este caso tem erro PRÓPRIO, distinto de "malformado"
    res, err := to_sfnt([]byte{0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0})
    defer delete(res)
    testing.expectf(t, err == .Not_Woff2, "esperava .Not_Woff2, veio %v", err)

    res2, err2 := to_sfnt(transmute([]u8)string("wOFF"))
    defer delete(res2)
    testing.expectf(t, err2 == .Not_Woff2, "WOFF1 também: veio %v", err2)
}

@(test)
test_recusa_colecao :: proc(t: ^testing.T) {
    // "wOF2" com flavor "ttcf": arquivo VÁLIDO que não sabemos montar. Tem de
    // sair como .Unsupported, não como .Invalid nem como fonte quebrada.
    b := make([]byte, 48)
    defer delete(b)
    copy(b, transmute([]u8)string("wOF2"))
    copy(b[4:], transmute([]u8)string("ttcf"))
    b[12], b[13] = 0, 1 // numTables = 1
    res, err := to_sfnt(b)
    defer delete(res)
    testing.expectf(t, err == .Unsupported, "esperava .Unsupported, veio %v", err)
}

@(test)
test_recusa_truncado_no_cabecalho :: proc(t: ^testing.T) {
    b := transmute([]u8)string("wOF2\x00\x01\x00\x00")
    res, err := to_sfnt(b)
    defer delete(res)
    testing.expectf(t, err == .Invalid, "esperava .Invalid, veio %v", err)
}

// ── fonte real ──────────────────────────────────────────────────────────────

@(test)
test_roboto_woff2_vira_sfnt_valido :: proc(t: ^testing.T) {
    src := #load("testdata/roboto.woff2")
    sfnt, err := to_sfnt(src)
    defer delete(sfnt)
    if !testing.expectf(t, err == .None, "to_sfnt devolveu %v", err) do return

    be16 :: proc(b: []byte, at: int) -> int {
        return at + 2 <= len(b) ? int(u32(b[at]) << 8 | u32(b[at + 1])) : -1
    }
    be32 :: proc(b: []byte, at: int) -> int {
        if at + 4 > len(b) do return -1
        return int(u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]))
    }

    testing.expect(t, be32(sfnt, 0) == 0x00010000, "sfntVersion de TrueType")
    n := be16(sfnt, 4)
    testing.expectf(t, n == 18, "numTables = %d, a fonte declara 18", n)

    // o diretório do SFNT tem de estar ORDENADO por tag
    glyf, loca, maxp, head := -1, -1, -1, -1
    glyf_len, loca_len := 0, 0
    prev := -1
    for i in 0 ..< n {
        d := 12 + 16 * i
        tag := be32(sfnt, d)
        off := be32(sfnt, d + 8)
        ln := be32(sfnt, d + 12)
        testing.expectf(t, tag > prev, "diretório fora de ordem na entrada %d", i)
        prev = tag
        testing.expectf(t, off >= 0 && ln >= 0 && off + ln <= len(sfnt),
            "entrada %d aponta fora do arquivo", i)
        switch u32(tag) {
        case TAG_GLYF: glyf, glyf_len = off, ln
        case TAG_LOCA: loca, loca_len = off, ln
        case TAG_MAXP: maxp = off
        case TAG_HEAD: head = off
        }
    }
    if !testing.expect(t, glyf >= 0 && loca >= 0 && maxp >= 0 && head >= 0,
        "faltou glyf/loca/maxp/head") {
        return
    }

    nglyphs := be16(sfnt, maxp + 4)
    long := be16(sfnt, head + 50) != 0
    testing.expectf(t, nglyphs > 100, "numGlyphs = %d, esperava uma fonte de texto", nglyphs)

    // O `loca` tem de ter numGlyphs+1 entradas, ser não-decrescente e terminar
    // exatamente no fim do `glyf`. É o que amarra a reconstrução: se algum
    // stream do glyf desalinhar, isto quebra.
    want := (nglyphs + 1) * (long ? 4 : 2)
    testing.expectf(t, loca_len == want, "loca tem %d bytes, esperava %d", loca_len, want)
    off_of :: proc(b: []byte, loca: int, long: bool, k: int) -> int {
        if long {
            at := loca + 4 * k
            return int(u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]))
        }
        at := loca + 2 * k
        return 2 * int(u32(b[at]) << 8 | u32(b[at + 1]))
    }
    testing.expect(t, off_of(sfnt, loca, long, 0) == 0, "loca[0] = 0")
    testing.expectf(t, off_of(sfnt, loca, long, nglyphs) == glyf_len,
        "loca[n] = %d, glyf tem %d bytes", off_of(sfnt, loca, long, nglyphs), glyf_len)

    // e cada registro de glifo tem de FECHAR dentro do seu vão do loca
    simples, compostos, vazios := 0, 0, 0
    for g in 0 ..< nglyphs {
        a := off_of(sfnt, loca, long, g)
        b := off_of(sfnt, loca, long, g + 1)
        if !testing.expectf(t, a <= b && b <= glyf_len, "glifo %d: vão [%d,%d) inválido", g, a, b) do return
        if a == b {
            vazios += 1
            continue
        }
        rec := sfnt[glyf + a:glyf + b]
        nc := be16(rec, 0)
        if nc == 0xFFFF {
            compostos += 1
            continue // o tamanho do composto depende das flags; basta caber
        }
        simples += 1
        // 10 bytes de cabeçalho + endPts + instruções + flags + coordenadas
        need := 10 + 2 * nc + 2
        if !testing.expectf(t, need <= len(rec), "glifo %d: cabeçalho não cabe", g) do return
        npts := be16(rec, 10 + 2 * (nc - 1)) + 1
        ilen := be16(rec, 10 + 2 * nc)
        at := 10 + 2 * nc + 2 + ilen
        // percorre as flags e soma quantos bytes de coordenada elas pedem
        nx, ny, p := 0, 0, 0
        for p < npts && at < len(rec) {
            f := rec[at]
            at += 1
            reps := 1
            if f & 0x08 != 0 && at < len(rec) {
                reps += int(rec[at])
                at += 1
            }
            for _ in 0 ..< reps {
                if p >= npts do break
                if f & 0x02 != 0 { nx += 1 } else if f & 0x10 == 0 { nx += 2 }
                if f & 0x04 != 0 { ny += 1 } else if f & 0x20 == 0 { ny += 2 }
                p += 1
            }
        }
        testing.expectf(t, p == npts, "glifo %d: %d flags para %d pontos", g, p, npts)
        testing.expectf(t, at + nx + ny == len(rec) || at + nx + ny == len(rec) - 1,
            "glifo %d: registro tem %d bytes, as flags pedem %d (+ até 1 de padding)",
            g, len(rec), at + nx + ny)
    }
    testing.expectf(t, simples > 100, "só %d glifos simples", simples)
    testing.expectf(t, compostos > 0, "nenhum glifo composto — o caminho não foi exercitado")
    testing.expectf(t, vazios > 0, "nenhum glifo vazio — o caminho não foi exercitado")
}
