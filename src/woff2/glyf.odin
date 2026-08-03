package woff2

// Reconstrução do `glyf` transformado (seção 5.1) e do `loca` (seção 5.3).
//
// O `glyf` transformado não é uma tabela: são SETE sub-streams paralelos
// (contagem de contornos, pontos por contorno, flags, coordenadas, compostos,
// caixas e instruções) que o decodificador tem de reintercalar glifo a glifo,
// avançando em cada um por conta própria. Errar o avanço de UM stream
// desalinha todos os glifos seguintes — daí cada leitura passar pelo cursor
// que carrega o `bad`.

import "core:mem"

// Bit do glifo `g` num bitmap empacotado com o glifo 0 no bit MAIS
// significativo do primeiro byte (a spec diz isso explicitamente para o
// bboxBitmap; escrever LSB-primeiro trocaria as caixas de lugar).
@(private)
bit_is_set :: proc(bmp: []byte, g: int) -> bool {
    i := g >> 3
    return i < len(bmp) && (bmp[i] & (0x80 >> uint(g & 7))) != 0
}

@(private)
w16d :: proc(b: ^[dynamic]u8, v: u32) {
    append(b, u8(v >> 8), u8(v))
}

@(private)
rebuild_glyf :: proc(
    t: []byte,
    allocator: mem.Allocator,
) -> (
    glyf: []byte,
    loca: []byte,
    xmins: []i16,
    fmt_changed: bool,
    ok: bool,
) {
    c := Cur{b = t}
    _ = rd16(&c) // reserved
    opt := rd16(&c)
    nglyphs := int(rd16(&c))
    index_fmt := rd16(&c)
    sz_ncont := int(rd32(&c))
    sz_npts := int(rd32(&c))
    sz_flag := int(rd32(&c))
    sz_glyph := int(rd32(&c))
    sz_comp := int(rd32(&c))
    sz_bbox := int(rd32(&c))
    sz_instr := int(rd32(&c))
    if c.bad do return

    s_ncont := Cur{b = rdn(&c, sz_ncont)}
    s_npts := Cur{b = rdn(&c, sz_npts)}
    s_flag := Cur{b = rdn(&c, sz_flag)}
    s_glyph := Cur{b = rdn(&c, sz_glyph)}
    s_comp := Cur{b = rdn(&c, sz_comp)}
    bbox_all := rdn(&c, sz_bbox)
    s_instr := Cur{b = rdn(&c, sz_instr)}
    overlap: []byte
    if opt & 1 != 0 do overlap = rdn(&c, (nglyphs + 7) / 8)
    if c.bad do return

    // o bboxBitmap vem COLADO no bboxStream, e o tamanho dele é o do bitmap
    // arredondado para múltiplo de 4 (a spec dá a fórmula)
    bmp_sz := 4 * ((nglyphs + 31) / 32)
    if sz_bbox < bmp_sz do return
    bmp := bbox_all[:bmp_sz]
    s_bbox := Cur{b = bbox_all[bmp_sz:]}

    gbuf := make([dynamic]u8, 0, max(len(t), 1024), allocator)
    offs := make([]int, nglyphs + 1, allocator)
    xs := make([]i16, max(nglyphs, 1), allocator)
    defer if !ok {
        delete(gbuf)
        delete(offs, allocator)
        delete(xs, allocator)
    }

    // buffers reusados entre glifos, para não alocar por glifo
    ends := make([dynamic]u32, 0, 64, allocator)
    dxs := make([dynamic]i32, 0, 512, allocator)
    dys := make([dynamic]i32, 0, 512, allocator)
    oncv := make([dynamic]bool, 0, 512, allocator)
    defer {
        delete(ends)
        delete(dxs)
        delete(dys)
        delete(oncv)
    }

    for g in 0 ..< nglyphs {
        offs[g] = len(gbuf)
        ncont := rds16(&s_ncont)
        if s_ncont.bad do return

        switch {
        case ncont == 0:
            // glifo VAZIO: registro de zero bytes, loca[n+1] == loca[n]. A
            // spec manda REJEITAR se ele trouxer caixa explícita.
            if bit_is_set(bmp, g) do return
            xs[g] = 0

        case ncont > 0:
            clear(&ends)
            clear(&dxs)
            clear(&dys)
            clear(&oncv)
            total := 0
            for _ in 0 ..< ncont {
                np := int(rd_255u16(&s_npts))
                total += np
                append(&ends, u32(total - 1))
            }
            if s_npts.bad || total <= 0 || total > 65535 do return

            x, y: i32
            xmin, ymin, xmax, ymax: i32
            for p in 0 ..< total {
                f := u8(rd8(&s_flag))
                tr := W2_TRIPLET[f & 0x7f]
                nb := int(tr[0]) - 1
                xb, yb := uint(tr[1]), uint(tr[2])
                v: u32 = 0
                for _ in 0 ..< nb do v = (v << 8) | rd8(&s_glyph)
                if s_flag.bad || s_glyph.bad do return
                // os bits de X vêm PRIMEIRO, do mais significativo
                dx := i32((v >> yb) & ((u32(1) << xb) - 1)) + i32(tr[3])
                dy := i32(v & ((u32(1) << yb) - 1)) + i32(tr[4])
                if tr[5] != 0 do dx = -dx
                if tr[6] != 0 do dy = -dy
                // o TrueType guarda o delta em int16; um valor fora disso não
                // vem de fonte real e seria truncado em silêncio
                if dx < -32768 || dx > 32767 || dy < -32768 || dy > 32767 do return
                append(&dxs, dx)
                append(&dys, dy)
                append(&oncv, f & 0x80 == 0) // MSB 0 = ponto SOBRE a curva
                x += dx
                y += dy
                if p == 0 {
                    xmin, xmax, ymin, ymax = x, x, y, y
                } else {
                    xmin = min(xmin, x); xmax = max(xmax, x)
                    ymin = min(ymin, y); ymax = max(ymax, y)
                }
            }

            instr_len := int(rd_255u16(&s_glyph))
            instr := rdn(&s_instr, instr_len)
            if s_glyph.bad || s_instr.bad do return

            // Caixa: explícita quando o bit está ligado; senão CALCULADA de
            // todos os pontos, inclusive os fora da curva (a spec exige que o
            // decodificador faça essa conta).
            if bit_is_set(bmp, g) {
                xmin = i32(rds16(&s_bbox))
                ymin = i32(rds16(&s_bbox))
                xmax = i32(rds16(&s_bbox))
                ymax = i32(rds16(&s_bbox))
                if s_bbox.bad do return
            }
            xs[g] = i16(clamp(xmin, -32768, 32767))

            w16d(&gbuf, u32(u16(i16(ncont))))
            w16d(&gbuf, u32(u16(i16(xmin))))
            w16d(&gbuf, u32(u16(i16(ymin))))
            w16d(&gbuf, u32(u16(i16(xmax))))
            w16d(&gbuf, u32(u16(i16(ymax))))
            for e in ends do w16d(&gbuf, e)
            w16d(&gbuf, u32(instr_len))
            append(&gbuf, ..instr)

            // flags, com os bits que dizem COMO a coordenada foi guardada
            for p in 0 ..< total {
                f: u8 = oncv[p] ? 0x01 : 0
                if p == 0 && overlap != nil && bit_is_set(overlap, g) do f |= 0x40
                // Sem X_SHORT nem X_IS_SAME: o delta vai como int16 de 2 bytes.
                // Com X_IS_SAME e sem X_SHORT: o delta é ZERO e não ocupa byte.
                // Com X_SHORT: 1 byte sem sinal, e X_IS_SAME dá o sinal.
                dx, dy := dxs[p], dys[p]
                switch {
                case dx == 0:
                    f |= 0x10
                case dx >= -255 && dx <= 255:
                    f |= 0x02
                    if dx > 0 do f |= 0x10
                }
                switch {
                case dy == 0:
                    f |= 0x20
                case dy >= -255 && dy <= 255:
                    f |= 0x04
                    if dy > 0 do f |= 0x20
                }
                append(&gbuf, f)
            }
            for p in 0 ..< total {
                d := dxs[p]
                switch {
                case d == 0:
                case d >= -255 && d <= 255: append(&gbuf, u8(abs(d)))
                case:                       w16d(&gbuf, u32(u16(i16(d))))
                }
            }
            for p in 0 ..< total {
                d := dys[p]
                switch {
                case d == 0:
                case d >= -255 && d <= 255: append(&gbuf, u8(abs(d)))
                case:                       w16d(&gbuf, u32(u16(i16(d))))
                }
            }

        case ncont == -1:
            // COMPOSTO. A spec exige caixa explícita: calcular a de um
            // composto obrigaria a resolver os componentes, o que brigaria
            // com decodificação em fluxo.
            if !bit_is_set(bmp, g) do return
            start := s_comp.at
            have_instr := false
            for {
                fl := rd16(&s_comp)
                if s_comp.bad do return
                if fl & 0x0100 != 0 do have_instr = true // WE_HAVE_INSTRUCTIONS
                nargs := 2 + (fl & 0x0001 != 0 ? 4 : 2) // glyphIndex + arg1/arg2
                switch {
                case fl & 0x0008 != 0: nargs += 2 // escala única
                case fl & 0x0040 != 0: nargs += 4 // escala X e Y
                case fl & 0x0080 != 0: nargs += 8 // matriz 2x2
                }
                _ = rdn(&s_comp, nargs)
                if s_comp.bad do return
                if fl & 0x0020 == 0 do break // MORE_COMPONENTS
            }
            comps := s_comp.b[start:s_comp.at]

            instr_len := 0
            instr: []byte
            if have_instr {
                instr_len = int(rd_255u16(&s_glyph))
                instr = rdn(&s_instr, instr_len)
                if s_glyph.bad || s_instr.bad do return
            }
            xmin := rds16(&s_bbox)
            ymin := rds16(&s_bbox)
            xmax := rds16(&s_bbox)
            ymax := rds16(&s_bbox)
            if s_bbox.bad do return
            xs[g] = i16(clamp(xmin, -32768, 32767))

            w16d(&gbuf, 0xFFFF)
            w16d(&gbuf, u32(u16(i16(xmin))))
            w16d(&gbuf, u32(u16(i16(ymin))))
            w16d(&gbuf, u32(u16(i16(xmax))))
            w16d(&gbuf, u32(u16(i16(ymax))))
            append(&gbuf, ..comps)
            if have_instr {
                w16d(&gbuf, u32(instr_len))
                append(&gbuf, ..instr)
            }

        case:
            return // ncont < -1 não existe
        }

        // Offsets do `loca` curto são guardados divididos por dois, então
        // todo registro tem de terminar em posição PAR.
        if len(gbuf) & 1 != 0 do append(&gbuf, 0)
    }
    offs[nglyphs] = len(gbuf)

    // O `glyf` remontado pode ficar MAIOR que o original (a spec avisa e
    // proíbe rejeitar por isso). Se passar do que o formato curto endereça,
    // o `loca` vai longo — e quem chama corrige o `head`.
    long := index_fmt != 0 || len(gbuf) > 0x1FFFE
    fmt_changed = long && index_fmt == 0

    if long {
        loca = make([]byte, 4 * (nglyphs + 1), allocator)
        for k in 0 ..= nglyphs do put32(loca, 4 * k, u32(offs[k]))
    } else {
        loca = make([]byte, 2 * (nglyphs + 1), allocator)
        for k in 0 ..= nglyphs do put16(loca, 2 * k, u32(offs[k] / 2))
    }

    delete(offs, allocator)
    glyf = gbuf[:]
    xmins = xs
    ok = true
    return
}

// ── hmtx transform version 1 (seção 5.4) ────────────────────────────────────
//
// A transform aproveita que, em fonte bem desenhada, o left side bearing é
// igual ao xMin da caixa do glifo — então os arrays de lsb podem sumir do
// arquivo e voltar a partir do `glyf`. É por isso que esta função precisa dos
// xMin que a reconstrução do `glyf` colheu.
@(private)
rebuild_hmtx :: proc(
    t: []byte,
    entries: []Entry,
    xmins: []i16,
    allocator: mem.Allocator,
) -> (
    []byte,
    bool,
) {
    num_hmetrics, nglyphs := 0, 0
    for e in entries {
        if e.tag == TAG_HHEA && len(e.out) >= 36 {
            num_hmetrics = int(u32(e.out[34]) << 8 | u32(e.out[35]))
        }
        if e.tag == TAG_MAXP && len(e.out) >= 6 {
            nglyphs = int(u32(e.out[4]) << 8 | u32(e.out[5]))
        }
    }
    if num_hmetrics <= 0 || nglyphs <= 0 || num_hmetrics > nglyphs do return nil, false
    // sem os xMin do glyf não há de onde reconstruir (fonte CFF, por exemplo)
    if len(xmins) < nglyphs do return nil, false

    c := Cur{b = t}
    flags := u8(rd8(&c))
    if c.bad do return nil, false
    // a spec: ao menos um dos dois bits TEM de estar ligado, e 2..7 reservados
    if flags & 0x03 == 0 || flags & 0xFC != 0 do return nil, false
    lsb_gone := flags & 0x01 != 0
    lsb_mono_gone := flags & 0x02 != 0

    // Os arrays ausentes NÃO consomem bytes do stream — daí a leitura ser
    // condicional, e não um read-and-discard.
    adv := rdn(&c, 2 * num_hmetrics)
    lsb, mono: []byte
    if !lsb_gone do lsb = rdn(&c, 2 * num_hmetrics)
    if !lsb_mono_gone do mono = rdn(&c, 2 * (nglyphs - num_hmetrics))
    if c.bad do return nil, false

    out := make([]byte, 4 * num_hmetrics + 2 * (nglyphs - num_hmetrics), allocator)
    for i in 0 ..< num_hmetrics {
        out[4 * i] = adv[2 * i]
        out[4 * i + 1] = adv[2 * i + 1]
        v := u32(u16(xmins[i]))
        if !lsb_gone do v = u32(lsb[2 * i]) << 8 | u32(lsb[2 * i + 1])
        put16(out, 4 * i + 2, v)
    }
    base := 4 * num_hmetrics
    for i in num_hmetrics ..< nglyphs {
        k := i - num_hmetrics
        v := u32(u16(xmins[i]))
        if !lsb_mono_gone do v = u32(mono[2 * k]) << 8 | u32(mono[2 * k + 1])
        put16(out, base + 2 * k, v)
    }
    return out, true
}
