package varfont

// Instância ESTÁTICA de uma fonte variável TrueType (`fvar` + `gvar`) num ponto
// do espaço de design — hoje, só o eixo `wght`.
//
// Por que existe: o stb_truetype não sabe nada de variação. Ele lê `glyf`/`hmtx`
// e desenha a instância PADRÃO (`default` do `fvar`). Provedores modernos (o
// Google Fonts, com UA de navegador) servem UM arquivo variável para todos os
// pesos: as `@font-face` de 400 e 700 apontam para a MESMA URL e diferem só no
// descritor `font-weight`. Sem instanciar, o "700" saía idêntico ao "400" — foi o
// "Documentation" fino do animate.style.
//
// O que fazemos é o mesmo que `fontTools.varLib.instancer` faz para um ponto:
//   1. normaliza o valor pedido contra o eixo do `fvar` (−1..0..1) e passa pelo
//      `avar`, se houver;
//   2. para cada glifo, soma os deltas de cada tupla do `gvar` ponderados pelo
//      escalar da tupla, com IUP (interpolação dos pontos não tocados) quando a
//      tupla é esparsa;
//   3. os 4 pontos FANTASMA no fim de cada glifo dão o deslocamento da origem e
//      do avanço — é daí que sai o novo `hmtx`;
//   4. regrava `glyf` (coordenadas em int16 cru, sem compactação), `loca` longa,
//      `hmtx` completa, e corrige `head`/`hhea`. As tabelas de variação saem.
//
// ── Recorte / degradação ────────────────────────────────────────────────────
// - Só contornos TrueType (`glyf`). CFF2 variável → `.Unsupported`: quem chama
//   fica com a instância padrão, que é o comportamento anterior.
// - Eixos que não o `wght` ficam no default.
// - `HVAR` não é lido: o avanço vem dos pontos fantasma do `gvar`, que as
//   ferramentas de build (fontmake/varLib) sempre escrevem. `MVAR` (ascender &
//   cia. variando) também não — métricas verticais ficam as do default.
// - Instruções de hinting são copiadas como estão (o stb não as executa).

import "core:mem"
import "core:math"

Error :: enum u8 {
    None = 0,     // instância gerada
    Default,      // o ponto pedido É o default: use os bytes originais
    Not_Variable, // sem `fvar`/`gvar` ou sem eixo `wght`
    Unsupported,  // variável, mas em algo que não fazemos (CFF2, eixos demais)
    Invalid,      // tabela truncada/incoerente
}

tag :: proc(s: string) -> u32 {
    return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

TAG_WGHT :: u32(0x77676874)

MAX_AXES :: 64
MAX_DEPTH :: 8 // aninhamento de compostos

// ── leitura big-endian com limite ───────────────────────────────────────────

@(private)
u16at :: proc(b: []byte, at: int) -> (u32, bool) {
    if at < 0 || at + 2 > len(b) do return 0, false
    return u32(b[at]) << 8 | u32(b[at + 1]), true
}
@(private)
i16at :: proc(b: []byte, at: int) -> (int, bool) {
    v, ok := u16at(b, at)
    return int(i16(u16(v))), ok
}
@(private)
u32at :: proc(b: []byte, at: int) -> (u32, bool) {
    if at < 0 || at + 4 > len(b) do return 0, false
    return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]), true
}
@(private)
fixed_at :: proc(b: []byte, at: int) -> (f32, bool) {
    v, ok := u32at(b, at)
    return f32(i32(v)) / 65536, ok
}
@(private)
f2dot14_at :: proc(b: []byte, at: int) -> (f32, bool) {
    v, ok := i16at(b, at)
    return f32(v) / 16384, ok
}
@(private)
put16 :: proc(d: []byte, at: int, v: int) {
    d[at] = u8(u32(v) >> 8)
    d[at + 1] = u8(u32(v))
}
@(private)
put32 :: proc(d: []byte, at: int, v: u32) {
    d[at] = u8(v >> 24); d[at + 1] = u8(v >> 16); d[at + 2] = u8(v >> 8); d[at + 3] = u8(v)
}

// ── diretório de tabelas ────────────────────────────────────────────────────

Table :: struct { tag: u32, data: []byte }

@(private)
read_tables :: proc(f: []byte, allocator: mem.Allocator) -> ([]Table, u32, bool) {
    flavor, ok := u32at(f, 0)
    if !ok do return nil, 0, false
    n, ok2 := u16at(f, 4)
    if !ok2 || n == 0 || n > 512 do return nil, 0, false
    out := make([]Table, int(n), allocator)
    for i in 0 ..< int(n) {
        r := 12 + 16 * i
        t, a := u32at(f, r)
        off, b := u32at(f, r + 8)
        ln, c := u32at(f, r + 12)
        if !a || !b || !c || u64(off) + u64(ln) > u64(len(f)) {
            delete(out, allocator)
            return nil, 0, false
        }
        out[i] = Table{t, f[off:off + ln]}
    }
    return out, flavor, true
}

@(private)
find :: proc(ts: []Table, t: u32) -> ([]byte, bool) {
    for x in ts do if x.tag == t do return x.data, true
    return nil, false
}

// ── eixos ───────────────────────────────────────────────────────────────────

Axis :: struct { tag: u32, min, def, max: f32 }

@(private)
read_axes :: proc(fvar: []byte, buf: ^[MAX_AXES]Axis) -> (int, bool) {
    arr, a := u16at(fvar, 4)
    count, b := u16at(fvar, 8)
    size, c := u16at(fvar, 10)
    if !a || !b || !c || size < 20 || count > MAX_AXES do return 0, false
    for i in 0 ..< int(count) {
        at := int(arr) + i * int(size)
        t, ok1 := u32at(fvar, at)
        mn, ok2 := fixed_at(fvar, at + 4)
        df, ok3 := fixed_at(fvar, at + 8)
        mx, ok4 := fixed_at(fvar, at + 12)
        if !ok1 || !ok2 || !ok3 || !ok4 do return 0, false
        buf[i] = Axis{t, mn, df, mx}
    }
    return int(count), true
}

// Faixa do eixo `wght` de uma fonte (ok=false se não for variável em peso).
// Barato e SEM ALOCAR (roda na thread de download): varre o diretório direto e
// lê só o `fvar`. Quem decide se vale pedir instâncias de outros pesos usa isto.
weight_axis :: proc(sfnt: []byte) -> (min, def, max: f32, ok: bool) {
    n_tables, k := u16at(sfnt, 4)
    if !k || n_tables > 512 do return
    fvar: []byte
    has_fvar, has_gvar, has_glyf := false, false, false
    for i in 0 ..< int(n_tables) {
        r := 12 + 16 * i
        t, a := u32at(sfnt, r)
        off, b := u32at(sfnt, r + 8)
        ln, c := u32at(sfnt, r + 12)
        if !a || !b || !c || u64(off) + u64(ln) > u64(len(sfnt)) do return
        switch t {
        case tag("fvar"): fvar, has_fvar = sfnt[off:off + ln], true
        case tag("gvar"): has_gvar = true
        case tag("glyf"): has_glyf = true
        }
    }
    if !has_fvar || !has_gvar || !has_glyf do return
    axes: [MAX_AXES]Axis
    n, fine := read_axes(fvar, &axes)
    if !fine do return
    for a in axes[:n] {
        if a.tag == TAG_WGHT do return a.min, a.def, a.max, true
    }
    return
}

@(private)
round_f2dot14 :: proc(v: f32) -> f32 {
    return math.floor(v * 16384 + 0.5) / 16384
}

// Normalização do OpenType (§ "Coordinate scales and normalization").
normalize :: proc(a: Axis, v: f32) -> f32 {
    x := clamp(v, a.min, a.max)
    n: f32 = 0
    if x < a.def && a.def > a.min {
        n = (x - a.def) / (a.def - a.min)
    } else if x > a.def && a.max > a.def {
        n = (x - a.def) / (a.max - a.def)
    }
    return round_f2dot14(n)
}

// Mapa por segmentos do `avar` (versão 1) para o eixo `axis`.
@(private)
avar_map :: proc(avar: []byte, axis: int, n: f32) -> f32 {
    count, ok := u16at(avar, 6)
    if !ok || axis >= int(count) do return n
    at := 8
    for i in 0 ..< axis { // pula os mapas dos eixos anteriores
        pc, k := u16at(avar, at)
        if !k do return n
        at += 2 + 4 * int(pc)
        _ = i
    }
    pc, k := u16at(avar, at)
    if !k || pc == 0 do return n
    from := make([]f32, int(pc), context.temp_allocator)
    to := make([]f32, int(pc), context.temp_allocator)
    for i in 0 ..< int(pc) {
        f, a := f2dot14_at(avar, at + 2 + 4 * i)
        t, b := f2dot14_at(avar, at + 4 + 4 * i)
        if !a || !b do return n
        from[i], to[i] = f, t
    }
    if n <= from[0] do return round_f2dot14(n + to[0] - from[0])
    last := int(pc) - 1
    if n >= from[last] do return round_f2dot14(n + to[last] - from[last])
    for i in 1 ..= last {
        if n <= from[i] {
            if from[i] == from[i - 1] do return to[i]
            t := (n - from[i - 1]) / (from[i] - from[i - 1])
            return round_f2dot14(to[i - 1] + t * (to[i] - to[i - 1]))
        }
    }
    return n
}

// Escalar de uma tupla para as coordenadas normalizadas `coords`.
tuple_scalar :: proc(coords, peak, start, end: []f32, intermediate: bool) -> f32 {
    s: f32 = 1
    for i in 0 ..< len(coords) {
        p := peak[i]
        if p == 0 do continue
        v := coords[i]
        if v == 0 do return 0
        if v == p do continue
        if intermediate {
            lo, hi := start[i], end[i]
            if lo > p || p > hi || (lo < 0 && hi > 0) do continue // região inválida: ignora o eixo
            if v < lo || v > hi do return 0
            if v < p {
                if p != lo do s *= (v - lo) / (p - lo)
            } else {
                if p != hi do s *= (hi - v) / (hi - p)
            }
        } else {
            if v < min(0, p) || v > max(0, p) do return 0
            s *= v / p
        }
    }
    return s
}

// ── glifos ──────────────────────────────────────────────────────────────────

Pt :: [2]f32 // .x/.y por swizzle; array permite somar

@(private)
Glyph :: struct {
    raw:       []byte, // bytes originais (pode ser vazio)
    contours:  int,    // >=0 simples, <0 composto
    ends:      []int,  // fim de cada contorno (simples)
    on:        []bool, // on-curve (simples)
    overlap:   bool,   // flag OVERLAP_SIMPLE do 1º ponto
    instr:     []byte, // instruções (simples ou composto)
    pts:       []Pt,   // coordenadas: pontos (simples) ou offsets dos componentes (composto), + 4 fantasmas
    comps:     []Comp,
    adv, lsb:  int,    // hmtx original
    xmin:      int,    // bbox original (para o fantasma 1)
}

@(private)
Comp :: struct {
    flags: u32,
    glyph: int,
    xy:    bool,   // ARGS_ARE_XY_VALUES
    a1, a2: int,   // argumentos originais (índices de ponto quando !xy)
    xform: []byte, // bytes da transformação (escala/2x2), copiados como estão
    m:     [4]f32, // a mesma transformação, decodificada (p/ a bbox)
}

ARG_WORDS     :: 0x0001
ARGS_XY       :: 0x0002
HAVE_SCALE    :: 0x0008
MORE_COMPS    :: 0x0020
HAVE_XY_SCALE :: 0x0040
HAVE_2X2      :: 0x0080
HAVE_INSTR    :: 0x0100

@(private)
parse_glyph :: proc(raw: []byte, g: ^Glyph, allocator: mem.Allocator) -> bool {
    g.raw = raw
    if len(raw) == 0 {
        g.pts = make([]Pt, 4, allocator)
        return true
    }
    nc, ok := i16at(raw, 0)
    if !ok do return false
    g.contours = nc
    xmin, _ := i16at(raw, 2)
    g.xmin = xmin
    if nc >= 0 {
        g.ends = make([]int, nc, allocator)
        at := 10
        npts := 0
        for i in 0 ..< nc {
            e, k := u16at(raw, at)
            if !k do return false
            g.ends[i] = int(e)
            at += 2
            npts = int(e) + 1
        }
        il, k := u16at(raw, at)
        if !k || at + 2 + int(il) > len(raw) do return false
        g.instr = raw[at + 2:at + 2 + int(il)]
        at += 2 + int(il)
        flags := make([]u8, npts, allocator)
        for i := 0; i < npts; {
            if at >= len(raw) do return false
            f := raw[at]; at += 1
            flags[i] = f; i += 1
            if f & 0x08 != 0 {
                if at >= len(raw) do return false
                rep := int(raw[at]); at += 1
                for r := 0; r < rep && i < npts; r += 1 { flags[i] = f; i += 1 }
            }
        }
        g.pts = make([]Pt, npts + 4, allocator)
        g.on = make([]bool, npts, allocator)
        if npts > 0 do g.overlap = flags[0] & 0x40 != 0
        v := 0
        for i in 0 ..< npts {
            f := flags[i]
            g.on[i] = f & 0x01 != 0
            if f & 0x02 != 0 {
                if at >= len(raw) do return false
                d := int(raw[at]); at += 1
                v += f & 0x10 != 0 ? d : -d
            } else if f & 0x10 == 0 {
                d, k2 := i16at(raw, at)
                if !k2 do return false
                at += 2
                v += d
            }
            g.pts[i].x = f32(v)
        }
        v = 0
        for i in 0 ..< npts {
            f := flags[i]
            if f & 0x04 != 0 {
                if at >= len(raw) do return false
                d := int(raw[at]); at += 1
                v += f & 0x20 != 0 ? d : -d
            } else if f & 0x20 == 0 {
                d, k2 := i16at(raw, at)
                if !k2 do return false
                at += 2
                v += d
            }
            g.pts[i].y = f32(v)
        }
        return true
    }
    // composto
    comps := make([dynamic]Comp, allocator)
    at := 10
    last_flags: u32 = 0
    for {
        fl, k1 := u16at(raw, at)
        gi, k2 := u16at(raw, at + 2)
        if !k1 || !k2 do return false
        at += 4
        c := Comp{flags = fl, glyph = int(gi), xy = fl & ARGS_XY != 0, m = {1, 0, 0, 1}}
        if fl & ARG_WORDS != 0 {
            if c.xy {
                c.a1, _ = i16at(raw, at); c.a2, _ = i16at(raw, at + 2)
            } else {
                a, _ := u16at(raw, at); b, _ := u16at(raw, at + 2)
                c.a1, c.a2 = int(a), int(b)
            }
            at += 4
        } else {
            if at + 2 > len(raw) do return false
            if c.xy {
                c.a1, c.a2 = int(i8(raw[at])), int(i8(raw[at + 1]))
            } else {
                c.a1, c.a2 = int(raw[at]), int(raw[at + 1])
            }
            at += 2
        }
        xs := 0
        if fl & HAVE_SCALE != 0 {
            xs = 2
            s, _ := f2dot14_at(raw, at)
            c.m = {s, 0, 0, s}
        } else if fl & HAVE_XY_SCALE != 0 {
            xs = 4
            sx, _ := f2dot14_at(raw, at); sy, _ := f2dot14_at(raw, at + 2)
            c.m = {sx, 0, 0, sy}
        } else if fl & HAVE_2X2 != 0 {
            xs = 8
            a, _ := f2dot14_at(raw, at); b, _ := f2dot14_at(raw, at + 2)
            cc, _ := f2dot14_at(raw, at + 4); d, _ := f2dot14_at(raw, at + 6)
            c.m = {a, b, cc, d}
        }
        if at + xs > len(raw) do return false
        c.xform = raw[at:at + xs]
        at += xs
        append(&comps, c)
        last_flags = fl
        if fl & MORE_COMPS == 0 do break
    }
    if last_flags & HAVE_INSTR != 0 {
        il, k := u16at(raw, at)
        if k && at + 2 + int(il) <= len(raw) do g.instr = raw[at + 2:at + 2 + int(il)]
    }
    g.comps = comps[:]
    g.pts = make([]Pt, len(comps) + 4, allocator)
    for c, i in comps do if c.xy do g.pts[i] = {f32(c.a1), f32(c.a2)}
    return true
}

// ── leitura de números empacotados do gvar ──────────────────────────────────

@(private)
Rd :: struct { b: []byte, at: int, bad: bool }

@(private)
rd8 :: proc(r: ^Rd) -> int {
    if r.at >= len(r.b) { r.bad = true; return 0 }
    v := int(r.b[r.at]); r.at += 1
    return v
}
@(private)
rd16 :: proc(r: ^Rd) -> int {
    if r.at + 2 > len(r.b) { r.bad = true; return 0 }
    v := int(u32(r.b[r.at]) << 8 | u32(r.b[r.at + 1])); r.at += 2
    return v
}

// Devolve os índices de ponto; `all` = "todos os pontos" (contagem zero).
@(private)
read_points :: proc(r: ^Rd, allocator: mem.Allocator) -> (pts: []int, all: bool) {
    n := rd8(r)
    if n == 0 do return nil, true
    if n & 0x80 != 0 do n = (n & 0x7F) << 8 | rd8(r)
    out := make([]int, n, allocator)
    i, v := 0, 0
    for i < n && !r.bad {
        ctl := rd8(r)
        run := (ctl & 0x7F) + 1
        for k := 0; k < run && i < n; k += 1 {
            v += ctl & 0x80 != 0 ? rd16(r) : rd8(r)
            out[i] = v
            i += 1
        }
    }
    return out, false
}

@(private)
read_deltas :: proc(r: ^Rd, n: int, out: []f32) {
    i := 0
    for i < n && !r.bad {
        ctl := rd8(r)
        run := (ctl & 0x3F) + 1
        for k := 0; k < run && i < n; k += 1 {
            if ctl & 0x80 != 0 {
                out[i] = 0
            } else if ctl & 0x40 != 0 {
                out[i] = f32(i16(u16(rd16(r))))
            } else {
                out[i] = f32(i8(u8(rd8(r))))
            }
            i += 1
        }
    }
}

// IUP de um contorno [s..e] num eixo (0=x, 1=y), como o `iup_segment` do fontTools.
@(private)
iup_contour :: proc(orig: []Pt, d: []Pt, touched: []bool, s, e: int) {
    first := -1
    for i in s ..= e do if touched[i] { first = i; break }
    if first < 0 do return // nenhum tocado: tudo fica zero
    // anda pelos tocados em ordem cíclica
    cur := first
    for {
        nxt := -1
        for k in 1 ..= e - s + 1 {
            j := s + (cur - s + k) % (e - s + 1)
            if touched[j] { nxt = j; break }
        }
        // pontos entre cur e nxt (exclusivos), andando para frente com volta
        k := s + (cur - s + 1) % (e - s + 1)
        for k != nxt {
            for ax in 0 ..< 2 {
                c1 := ax == 0 ? orig[cur].x : orig[cur].y
                c2 := ax == 0 ? orig[nxt].x : orig[nxt].y
                d1 := ax == 0 ? d[cur].x : d[cur].y
                d2 := ax == 0 ? d[nxt].x : d[nxt].y
                c := ax == 0 ? orig[k].x : orig[k].y
                out: f32
                if c1 == c2 {
                    out = d1 == d2 ? d1 : 0
                } else {
                    if c1 > c2 { c1, c2 = c2, c1; d1, d2 = d2, d1 }
                    if c <= c1 {
                        out = d1
                    } else if c >= c2 {
                        out = d2
                    } else {
                        out = d1 + (c - c1) * (d2 - d1) / (c2 - c1)
                    }
                }
                if ax == 0 { d[k].x = out } else { d[k].y = out }
            }
            k = s + (k - s + 1) % (e - s + 1)
        }
        cur = nxt
        if cur == first do break
    }
}

// Soma em `g.pts` os deltas do glifo para `coords`.
@(private)
apply_gvar :: proc(g: ^Glyph, data: []byte, axis_count: int, shared: []f32, coords: []f32, allocator: mem.Allocator) -> bool {
    if len(data) == 0 do return true
    r := Rd{b = data}
    tc := rd16(&r)
    data_off := rd16(&r)
    if r.bad do return false
    count := tc & 0x0FFF
    n := len(g.pts)
    orig := make([]Pt, n, allocator)
    copy(orig, g.pts)
    acc := make([]Pt, n, allocator)

    ser := Rd{b = data, at = data_off}
    shared_pts: []int
    shared_all := true
    if tc & 0x8000 != 0 do shared_pts, shared_all = read_points(&ser, allocator)

    peak := make([]f32, axis_count, allocator)
    start := make([]f32, axis_count, allocator)
    end := make([]f32, axis_count, allocator)
    dx := make([]f32, n, allocator)
    dy := make([]f32, n, allocator)
    tmp := make([]Pt, n, allocator)
    touched := make([]bool, n, allocator)

    for _ in 0 ..< count {
        size := rd16(&r)
        ti := rd16(&r)
        if ti & 0x8000 != 0 {
            for a in 0 ..< axis_count do peak[a] = f32(i16(u16(rd16(&r)))) / 16384
        } else {
            idx := ti & 0x0FFF
            if (idx + 1) * axis_count > len(shared) do return false
            copy(peak, shared[idx * axis_count:(idx + 1) * axis_count])
        }
        inter := ti & 0x4000 != 0
        if inter {
            for a in 0 ..< axis_count do start[a] = f32(i16(u16(rd16(&r)))) / 16384
            for a in 0 ..< axis_count do end[a] = f32(i16(u16(rd16(&r)))) / 16384
        }
        if r.bad do return false
        tuple_end := ser.at + size
        if tuple_end > len(data) do return false
        s := tuple_scalar(coords, peak, start, end, inter)
        if s == 0 {
            ser.at = tuple_end
            continue
        }
        pts, all := shared_pts, shared_all
        if ti & 0x2000 != 0 do pts, all = read_points(&ser, allocator)
        m := all ? n : len(pts)
        read_deltas(&ser, m, dx)
        read_deltas(&ser, m, dy)
        if ser.bad do return false
        ser.at = tuple_end

        if all {
            for i in 0 ..< n do acc[i] += Pt{dx[i] * s, dy[i] * s}
            continue
        }
        for i in 0 ..< n { tmp[i] = {}; touched[i] = false }
        for k in 0 ..< m {
            p := pts[k]
            if p < 0 || p >= n do continue
            tmp[p] = {dx[k], dy[k]}
            touched[p] = true
        }
        if g.contours > 0 { // IUP só em glifo simples, só nos pontos do contorno
            s0 := 0
            for e in g.ends {
                if e >= n - 4 do break
                iup_contour(orig, tmp, touched, s0, e)
                s0 = e + 1
            }
        }
        for i in 0 ..< n do acc[i] += Pt{tmp[i].x * s, tmp[i].y * s}
    }
    for i in 0 ..< n do g.pts[i] = orig[i] + acc[i]
    return true
}

// ── saída ───────────────────────────────────────────────────────────────────

@(private)
rnd :: proc(v: f32) -> int { return int(math.floor(v + 0.5)) }

@(private)
Box :: struct { x0, y0, x1, y1: int, empty: bool }

@(private)
Out_Glyph :: struct {
    shift: int, // deslocamento horizontal aplicado ao contorno (origem nova)
    adv:   int,
    box:   Box,
    done:  bool,
    busy:  bool,
}

@(private)
Ctx :: struct {
    gs:  []Glyph,
    out: []Out_Glyph,
}

// bbox (já instanciada e deslocada) do glifo `gi` — recursivo nos compostos.
@(private)
glyph_box :: proc(c: ^Ctx, gi: int, depth: int) -> Box {
    if gi < 0 || gi >= len(c.gs) || depth > MAX_DEPTH do return Box{empty = true}
    o := &c.out[gi]
    if o.done do return o.box
    if o.busy do return Box{empty = true} // ciclo: fonte malformada
    o.busy = true
    defer o.busy = false
    g := &c.gs[gi]
    n := len(g.pts) - 4
    pp1 := g.pts[n]
    pp2 := g.pts[n + 1]
    o.shift = rnd(pp1.x) - (g.xmin - g.lsb)
    o.adv = max(0, rnd(pp2.x) - rnd(pp1.x))
    b := Box{empty = true}
    add :: proc(b: ^Box, x, y: int) {
        if b.empty { b^ = Box{x, y, x, y, false}; return }
        b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x); b.y1 = max(b.y1, y)
    }
    if g.contours > 0 {
        for i in 0 ..< n do add(&b, rnd(g.pts[i].x) - o.shift, rnd(g.pts[i].y))
    } else if g.contours < 0 {
        for comp, i in g.comps {
            cb := glyph_box(c, comp.glyph, depth + 1)
            if cb.empty do continue
            ox, oy := 0, 0
            if comp.xy do ox, oy = comp_offset(c, gi, i)
            xs := [2]f32{f32(cb.x0), f32(cb.x1)}
            ys := [2]f32{f32(cb.y0), f32(cb.y1)}
            for xx in xs do for yy in ys {
                tx := comp.m[0] * xx + comp.m[2] * yy
                ty := comp.m[1] * xx + comp.m[3] * yy
                add(&b, int(math.floor(tx)) + ox, int(math.floor(ty)) + oy)
                add(&b, int(math.ceil(tx)) + ox, int(math.ceil(ty)) + oy)
            }
        }
    }
    o.box = b
    o.done = true
    return b
}

// Offset final do componente `i` do composto `gi`. O contorno de cada glifo sai
// deslocado pelo SEU `shift`; para o componente cair onde cairia na fonte
// variável, devolve-se o shift do componente e tira-se o do composto.
@(private)
comp_offset :: proc(c: ^Ctx, gi, i: int) -> (int, int) {
    g := &c.gs[gi]
    comp := g.comps[i]
    cs := 0
    if comp.glyph >= 0 && comp.glyph < len(c.out) {
        _ = glyph_box(c, comp.glyph, 1) // garante o shift calculado
        cs = c.out[comp.glyph].shift
    }
    return rnd(g.pts[i].x) + cs - c.out[gi].shift, rnd(g.pts[i].y)
}

@(private)
w16 :: proc(b: ^[dynamic]u8, v: int) {
    append(b, u8(u32(v) >> 8), u8(u32(v)))
}

@(private)
write_glyph :: proc(c: ^Ctx, gi: int, b: ^[dynamic]u8) {
    g := &c.gs[gi]
    if len(g.raw) == 0 do return
    o := &c.out[gi]
    bx := o.box
    if bx.empty do bx = Box{}
    w16(b, g.contours)
    w16(b, bx.x0); w16(b, bx.y0); w16(b, bx.x1); w16(b, bx.y1)
    if g.contours >= 0 {
        n := len(g.pts) - 4
        for e in g.ends do w16(b, e)
        w16(b, len(g.instr))
        append(b, ..g.instr)
        for i in 0 ..< n {
            f: u8 = g.on[i] ? 0x01 : 0
            if i == 0 && g.overlap do f |= 0x40
            append(b, f) // x e y em int16 delta (sem SHORT/SAME)
        }
        px := 0
        for i in 0 ..< n {
            x := rnd(g.pts[i].x) - o.shift
            w16(b, x - px); px = x
        }
        py := 0
        for i in 0 ..< n {
            y := rnd(g.pts[i].y)
            w16(b, y - py); py = y
        }
    } else {
        for comp, i in g.comps {
            fl := comp.flags
            a1, a2 := comp.a1, comp.a2
            if comp.xy {
                a1, a2 = comp_offset(c, gi, i)
                fl |= ARG_WORDS
            }
            w16(b, int(fl)); w16(b, comp.glyph)
            if fl & ARG_WORDS != 0 {
                w16(b, a1); w16(b, a2)
            } else {
                append(b, u8(a1), u8(a2))
            }
            append(b, ..comp.xform)
        }
        if len(g.comps) > 0 && g.comps[len(g.comps) - 1].flags & HAVE_INSTR != 0 {
            w16(b, len(g.instr))
            append(b, ..g.instr)
        }
    }
    for len(b) % 4 != 0 do append(b, 0)
}

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
assemble :: proc(ts: []Table, flavor: u32, allocator: mem.Allocator) -> []byte {
    n := len(ts)
    order := make([]int, n, context.temp_allocator)
    for i in 0 ..< n do order[i] = i
    for i in 1 ..< n {
        j := i
        for j > 0 && ts[order[j - 1]].tag > ts[order[j]].tag {
            order[j - 1], order[j] = order[j], order[j - 1]
            j -= 1
        }
    }
    total := 12 + 16 * n
    for t in ts do total += (len(t.data) + 3) & ~int(3)
    out := make([]byte, total, allocator)
    put32(out, 0, flavor)
    put16(out, 4, n)
    sel: u32 = 0
    for (u32(1) << (sel + 1)) <= u32(n) do sel += 1
    put16(out, 6, int(u32(16) << sel))
    put16(out, 8, int(sel))
    put16(out, 10, int(u32(16 * n) - (u32(16) << sel)))
    at := 12 + 16 * n
    for oi, k in order {
        t := ts[oi]
        d := 12 + 16 * k
        put32(out, d, t.tag)
        put32(out, d + 4, table_checksum(t.data))
        put32(out, d + 8, u32(at))
        put32(out, d + 12, u32(len(t.data)))
        copy(out[at:], t.data)
        at += (len(t.data) + 3) & ~int(3)
    }
    return out
}

// Tabelas que deixam de valer na instância (variação) ou que descrevem o
// `glyf`/`hmtx` antigos byte a byte (hdmx/LTSH/VDMX: cache de métrica por ppem).
@(private)
dropped :: proc(t: u32) -> bool {
    switch t {
    case tag("fvar"), tag("gvar"), tag("avar"), tag("HVAR"), tag("VVAR"), tag("MVAR"),
         tag("cvar"), tag("STAT"), tag("hdmx"), tag("LTSH"), tag("VDMX"):
        return true
    }
    return false
}

// ── entrada ─────────────────────────────────────────────────────────────────

// Instancia `sfnt` no peso `weight` (escala do CSS = escala do eixo `wght`).
// Devolve SFNT novo (owned por `allocator`) e `.None`; ou nil e o motivo — em
// `.Default` o ponto pedido já é a instância padrão e os bytes originais servem.
instantiate_weight :: proc(sfnt: []byte, weight: f32, allocator := context.allocator) -> ([]byte, Error) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)
    defer mem.dynamic_arena_destroy(&arena)
    tmp := mem.dynamic_arena_allocator(&arena)

    ts, flavor, ok := read_tables(sfnt, tmp)
    if !ok do return nil, .Invalid
    fvar, has_fvar := find(ts, tag("fvar"))
    gvar, has_gvar := find(ts, tag("gvar"))
    if !has_fvar do return nil, .Not_Variable
    glyf, has_glyf := find(ts, tag("glyf"))
    loca, has_loca := find(ts, tag("loca"))
    if !has_glyf || !has_loca || !has_gvar do return nil, .Unsupported // CFF2
    head, h1 := find(ts, tag("head"))
    hhea, h2 := find(ts, tag("hhea"))
    hmtx, h3 := find(ts, tag("hmtx"))
    maxp, h4 := find(ts, tag("maxp"))
    if !h1 || !h2 || !h3 || !h4 || len(head) < 54 || len(hhea) < 36 do return nil, .Invalid

    axes: [MAX_AXES]Axis
    na, fine := read_axes(fvar, &axes)
    if !fine do return nil, .Invalid
    wi := -1
    for a, i in axes[:na] do if a.tag == TAG_WGHT { wi = i; break }
    if wi < 0 do return nil, .Not_Variable

    coords := make([]f32, na, tmp)
    coords[wi] = normalize(axes[wi], weight)
    if avar, has := find(ts, tag("avar")); has do coords[wi] = avar_map(avar, wi, coords[wi])
    if coords[wi] == 0 do return nil, .Default

    // gvar
    gac, _ := u16at(gvar, 4)
    if int(gac) != na do return nil, .Invalid
    stc, _ := u16at(gvar, 6)
    sto, _ := u32at(gvar, 8)
    gcount, _ := u16at(gvar, 12)
    gflags, _ := u16at(gvar, 14)
    garr, k5 := u32at(gvar, 16)
    if !k5 do return nil, .Invalid
    shared := make([]f32, int(stc) * na, tmp)
    for i in 0 ..< len(shared) {
        v, k := f2dot14_at(gvar, int(sto) + 2 * i)
        if !k do return nil, .Invalid
        shared[i] = v
    }
    gvar_off :: proc(gvar: []byte, long: bool, i: int) -> (int, bool) {
        if long {
            v, k := u32at(gvar, 20 + 4 * i)
            return int(v), k
        }
        v, k := u16at(gvar, 20 + 2 * i)
        return int(v) * 2, k
    }

    num_glyphs_u, _ := u16at(maxp, 4)
    ng := int(num_glyphs_u)
    if int(gcount) != ng do return nil, .Invalid
    loca_long := head[50] != 0 || head[51] != 0
    nhm_u, _ := u16at(hhea, 34)
    nhm := int(nhm_u)
    if nhm == 0 || nhm > ng || len(hmtx) < 4 * nhm + 2 * (ng - nhm) do return nil, .Invalid

    gs := make([]Glyph, ng, tmp)
    for i in 0 ..< ng {
        a, b: int
        if loca_long {
            x, k1 := u32at(loca, 4 * i); y, k2 := u32at(loca, 4 * i + 4)
            if !k1 || !k2 do return nil, .Invalid
            a, b = int(x), int(y)
        } else {
            x, k1 := u16at(loca, 2 * i); y, k2 := u16at(loca, 2 * i + 2)
            if !k1 || !k2 do return nil, .Invalid
            a, b = int(x) * 2, int(y) * 2
        }
        if a > b || b > len(glyf) do return nil, .Invalid
        if !parse_glyph(glyf[a:b], &gs[i], tmp) do return nil, .Invalid
        g := &gs[i]
        if i < nhm {
            v, _ := u16at(hmtx, 4 * i); l, _ := i16at(hmtx, 4 * i + 2)
            g.adv, g.lsb = int(v), l
        } else {
            v, _ := u16at(hmtx, 4 * (nhm - 1)); l, _ := i16at(hmtx, 4 * nhm + 2 * (i - nhm))
            g.adv, g.lsb = int(v), l
        }
        // fantasmas: pp1 = (xMin − lsb, 0), pp2 = pp1 + avanço
        n := len(g.pts) - 4
        g.pts[n] = {f32(g.xmin - g.lsb), 0}
        g.pts[n + 1] = {f32(g.xmin - g.lsb + g.adv), 0}
        o1, k1 := gvar_off(gvar, gflags & 1 != 0, i)
        o2, k2 := gvar_off(gvar, gflags & 1 != 0, i + 1)
        if !k1 || !k2 || o1 > o2 || int(garr) + o2 > len(gvar) do return nil, .Invalid
        if !apply_gvar(g, gvar[int(garr) + o1:int(garr) + o2], na, shared, coords, tmp) do return nil, .Invalid
    }

    c := Ctx{gs = gs, out = make([]Out_Glyph, ng, tmp)}
    for i in 0 ..< ng do glyph_box(&c, i, 0)

    nglyf := make([dynamic]u8, tmp)
    nloca := make([]byte, 4 * (ng + 1), tmp)
    nhmtx := make([]byte, 4 * ng, tmp)
    adv_max := 0
    bb := Box{empty = true}
    for i in 0 ..< ng {
        put32(nloca, 4 * i, u32(len(nglyf)))
        write_glyph(&c, i, &nglyf)
        o := c.out[i]
        lsb := o.box.empty ? 0 : o.box.x0 - (gs[i].xmin - gs[i].lsb)
        put16(nhmtx, 4 * i, o.adv)
        put16(nhmtx, 4 * i + 2, lsb)
        adv_max = max(adv_max, o.adv)
        if !o.box.empty {
            if bb.empty { bb = o.box } else {
                bb.x0 = min(bb.x0, o.box.x0); bb.y0 = min(bb.y0, o.box.y0)
                bb.x1 = max(bb.x1, o.box.x1); bb.y1 = max(bb.y1, o.box.y1)
            }
        }
    }
    put32(nloca, 4 * ng, u32(len(nglyf)))

    nhead := make([]byte, len(head), tmp); copy(nhead, head)
    put16(nhead, 50, 1) // indexToLocFormat = longa
    put32(nhead, 8, 0)  // checkSumAdjustment: não recalculamos (ninguém aqui confere)
    if !bb.empty {
        put16(nhead, 36, bb.x0); put16(nhead, 38, bb.y0); put16(nhead, 40, bb.x1); put16(nhead, 42, bb.y1)
    }
    nhhea := make([]byte, len(hhea), tmp); copy(nhhea, hhea)
    put16(nhhea, 10, adv_max)
    put16(nhhea, 34, ng)

    outs := make([dynamic]Table, tmp)
    for t in ts {
        if dropped(t.tag) do continue
        switch t.tag {
        case tag("glyf"): append(&outs, Table{t.tag, nglyf[:]})
        case tag("loca"): append(&outs, Table{t.tag, nloca})
        case tag("hmtx"): append(&outs, Table{t.tag, nhmtx})
        case tag("head"): append(&outs, Table{t.tag, nhead})
        case tag("hhea"): append(&outs, Table{t.tag, nhhea})
        case: append(&outs, t)
        }
    }
    return assemble(outs[:], flavor, allocator), .None
}
