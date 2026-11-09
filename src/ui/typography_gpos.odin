package ui

// OpenType GPOS PairPos (2) e ExtensionPos (9). stb_truetype não atravessa
// ExtensionPos, formato usado pela Segoe UI do Windows.
// Só lemos XAdvance do primeiro glifo; posicionamento complexo exige shaping.
// Todos os offsets são limitados à tabela: webfonts não são dados confiáveis.
@(private="file")
ot16 :: proc(b: []byte, p: int) -> int {
    if p < 0 || p > len(b)-2 do return -1
    return int(b[p]) * 256 + int(b[p+1])
}

@(private="file")
ot32 :: proc(b: []byte, p: int) -> int {
    if p < 0 || p > len(b)-4 do return -1
    return int(b[p])*16777216 + int(b[p+1])*65536 + int(b[p+2])*256 + int(b[p+3])
}

@(private="file")
ot_tag :: proc(b: []byte, p: int, tag: string) -> bool {
    if p < 0 || p > len(b)-4 do return false
    for i in 0 ..< 4 do if b[p+i] != tag[i] do return false
    return true
}

ot_gpos_table :: proc(sfnt: []byte) -> []byte {
    n := ot16(sfnt, 4)
    if n < 0 || n > (len(sfnt)-12)/16 do return nil
    for i in 0 ..< n {
        p := 12 + 16*i
        if !ot_tag(sfnt, p, "GPOS") do continue
        off, size := ot32(sfnt, p+8), ot32(sfnt, p+12)
        if off < 0 || size < 0 || off > len(sfnt) || size > len(sfnt)-off do return nil
        return sfnt[off:off+size]
    }
    return nil
}

// Coleta somente lookups da feature kern, sem duplicá-los entre LangSys.
// Não aplicar indiscriminadamente toda PairPos: há ajustes de outras features.
ot_kern_lookups :: proc(b: []byte, out: []int) -> int {
    if ot16(b, 0) != 1 do return 0
    features, lookups := ot16(b, 6), ot16(b, 8)
    nf, nl := ot16(b, features), ot16(b, lookups)
    if nf < 0 || nl < 0 || features < 10 || lookups < 10 do return 0
    if nf > (len(b)-features-2)/6 || nl > (len(b)-lookups-2)/2 do return 0
    count := 0
    for i in 0 ..< nf {
        rec := features+2+6*i
        if !ot_tag(b, rec, "kern") do continue
        f := features + ot16(b, rec+4)
        n := ot16(b, f+2)
        if n < 0 || f < features || n > (len(b)-f-4)/2 do continue
        for j in 0 ..< n {
            idx := ot16(b, f+4+2*j)
            if idx < 0 || idx >= nl do continue
            off := lookups + ot16(b, lookups+2+2*idx)
            if off <= lookups || off > len(b)-6 do continue
            duplicate := false
            for prev in out[:count] do if prev == off { duplicate = true; break }
            if !duplicate && count < len(out) { out[count] = off; count += 1 }
        }
    }
    return count
}

@(private="file")
ot_coverage :: proc(b: []byte, p, glyph: int) -> int {
    format, n := ot16(b, p), ot16(b, p+2)
    if n < 0 do return -1
    switch format {
    case 1:
        if n > (len(b)-p-4)/2 do return -1
        lo, hi := 0, n
        for lo < hi {
            mid := (lo+hi)/2
            v := ot16(b, p+4+2*mid)
            if v < glyph { lo = mid+1 } else { hi = mid }
        }
        if lo < n && ot16(b, p+4+2*lo) == glyph do return lo
    case 2:
        if n > (len(b)-p-4)/6 do return -1
        for i in 0 ..< n {
            r := p+4+6*i
            start, end := ot16(b, r), ot16(b, r+2)
            if glyph >= start && glyph <= end do return ot16(b, r+4)+glyph-start
        }
    }
    return -1
}

@(private="file")
ot_class :: proc(b: []byte, p, glyph: int) -> int {
    format := ot16(b, p)
    switch format {
    case 1:
        first, n := ot16(b, p+2), ot16(b, p+4)
        if n < 0 || n > (len(b)-p-6)/2 do return -1
        if glyph >= first && glyph-first < n do return ot16(b, p+6+2*(glyph-first))
        return 0
    case 2:
        n := ot16(b, p+2)
        if n < 0 || n > (len(b)-p-4)/6 do return -1
        for i in 0 ..< n {
            r := p+4+6*i
            if glyph >= ot16(b, r) && glyph <= ot16(b, r+2) do return ot16(b, r+4)
        }
        return 0
    }
    return -1
}

@(private="file")
ot_pair :: proc(b: []byte, p, left, right: int) -> (advance: int, matched: bool) {
    if ot16(b, p+4) != 4 || ot16(b, p+6) != 0 do return
    coverage_off := ot16(b, p+2)
    if coverage_off <= 0 do return
    coverage := ot_coverage(b, p+coverage_off, left)
    if coverage < 0 do return
    format := ot16(b, p)
    value := -1
    if format == 1 {
        n := ot16(b, p+8)
        if coverage >= n || n < 0 || n > (len(b)-p-10)/2 do return
        set_off := ot16(b, p+10+2*coverage)
        if set_off <= 0 do return
        set := p+set_off
        pairs := ot16(b, set)
        if pairs < 0 || pairs > (len(b)-set-2)/4 do return
        lo, hi := 0, pairs
        for lo < hi {
            mid := (lo+hi)/2
            if ot16(b, set+2+4*mid) < right { lo = mid+1 } else { hi = mid }
        }
        if lo < pairs && ot16(b, set+2+4*lo) == right do value = ot16(b, set+4+4*lo)
    } else if format == 2 {
        d1, d2 := ot16(b, p+8), ot16(b, p+10)
        if d1 <= 0 || d2 <= 0 do return
        a, c := ot_class(b, p+d1, left), ot_class(b, p+d2, right)
        n1, n2 := ot16(b, p+12), ot16(b, p+14)
        if a < 0 || c < 0 || a >= n1 || c >= n2 || n2 <= 0 do return
        // O produto cabe em int de 64 bits, mas precisa caber também na tabela.
        cells := n1*n2
        if cells > (len(b)-p-16)/2 do return
        value = ot16(b, p+16+2*(a*n2+c))
    }
    if value >= 0 do return (value >= 32768 ? value-65536 : value), true
    return
}

ot_pair_advance :: proc(b: []byte, lookups: []int, left, right: int) -> (advance: int, matched: bool) {
    for l in lookups {
        kind, n := ot16(b, l), ot16(b, l+4)
        if n < 0 || n > (len(b)-l-6)/2 || (kind != 2 && kind != 9) do continue
        for j in 0 ..< n {
            sub_off := ot16(b, l+6+2*j)
            if sub_off <= 0 do continue
            sub := l+sub_off
            if kind == 9 {
                if ot16(b, sub) != 1 || ot16(b, sub+2) != 2 do continue
                ext := ot32(b, sub+4)
                if ext <= 0 || ext > len(b)-sub do continue
                sub += ext
            }
            if v, ok := ot_pair(b, sub, left, right); ok {
                advance += v; matched = true
                break // primeiro subtable aplicável, soma entre lookups
            }
        }
    }
    return
}
