package js

// Number.prototype.toFixed / toExponential / toPrecision pela spec (§21.1.3).
//
// Antes eram `fmt.tprintf("%.*f")`/`"%.*g"`, e o printf do Odin arredonda EMPATE
// PARA O PAR: (2.5).toFixed(0) dava "2" (a spec e o Chrome dão "3"), (0.5) dava
// "0", (1e21).toFixed(2) saía em notação fixa, o `%g` cortava zeros que a spec
// manda manter ((1).toPrecision(3) é "1.00") e toExponential nem existia.
//
// A spec pede "o n cujo n/10^f − x é o mais próximo de zero; se houver dois, o
// MAIOR" — sobre o valor EXATO do double. Então expandimos o double em decimal
// EXATO (todo double é m·2^e, e com e < 0 isso é m·5^k / 10^k: um inteiro de até
// ~770 dígitos) e arredondamos a string de dígitos: com os dígitos exatos, o
// próximo dígito ≥ 5 já É "metade ou mais", e empate vai para cima — sem nenhum
// caso especial. É por isso que (1.005).toFixed(2) dá "1.00": o double é
// 1.00499999999999989…, não um empate.

import "core:math"
import "core:strconv"
import "core:strings"

// Inteiro grande mínimo: limbs de 32 bits, little-endian. 100 limbs = 3200 bits;
// o pior caso é m·5^1074 (53 + 2494 bits) ou m·2^971 (1024 bits).
@(private = "file")
Big :: struct {
    l: [100]u32,
    n: int,
}

@(private = "file")
big_mul_small :: proc(b: ^Big, m: u32) {
    carry: u64
    for i in 0 ..< b.n {
        p := u64(b.l[i]) * u64(m) + carry
        b.l[i] = u32(p)
        carry = p >> 32
    }
    if carry != 0 { b.l[b.n] = u32(carry); b.n += 1 }
}

@(private = "file")
big_shl :: proc(b: ^Big, bits: int) {
    words, rest := bits / 32, uint(bits % 32)
    if rest != 0 {
        carry: u32
        for i in 0 ..< b.n {
            v := b.l[i]
            b.l[i] = (v << rest) | carry
            carry = v >> (32 - rest)
        }
        if carry != 0 { b.l[b.n] = carry; b.n += 1 }
    }
    if words > 0 {
        for i := b.n - 1; i >= 0; i -= 1 do b.l[i + words] = b.l[i]
        for i in 0 ..< words do b.l[i] = 0
        b.n += words
    }
}

// Divide por 1e9 no lugar; devolve o resto.
@(private = "file")
big_divmod_1e9 :: proc(b: ^Big) -> u32 {
    rem: u64
    for i := b.n - 1; i >= 0; i -= 1 {
        cur := (rem << 32) | u64(b.l[i])
        b.l[i] = u32(cur / 1_000_000_000)
        rem = cur % 1_000_000_000
    }
    for b.n > 0 && b.l[b.n - 1] == 0 do b.n -= 1
    return u32(rem)
}

// Expansão decimal EXATA de x (> 0, finito): valor = 0.d₁d₂d₃… × 10^point, sem
// zeros à esquerda nem à direita em `digits`.
Exact_Dec :: struct {
    buf:    [800]u8,
    len:    int,
    point:  int,
}

@(private = "file")
exact_decimal :: proc(x: f64, d: ^Exact_Dec) {
    bits := transmute(u64)x
    mant := bits & (1 << 52 - 1)
    bexp := int((bits >> 52) & 0x7ff)
    e: int
    if bexp == 0 { e = -1074 } else { mant |= 1 << 52; e = bexp - 1075 }

    b: Big
    b.l[0] = u32(mant); b.l[1] = u32(mant >> 32)
    b.n = b.l[1] != 0 ? 2 : 1
    k := 0 // valor = b / 10^k
    if e >= 0 {
        big_shl(&b, e)
    } else {
        k = -e
        rem := k
        for rem >= 13 { big_mul_small(&b, 1_220_703_125); rem -= 13 } // 5^13
        p5: u32 = 1
        for _ in 0 ..< rem do p5 *= 5
        if p5 != 1 do big_mul_small(&b, p5)
    }

    // b → decimal, de trás para a frente em blocos de 9 dígitos
    tmp: [800]u8
    t := len(tmp)
    for b.n > 0 {
        r := big_divmod_1e9(&b)
        for _ in 0 ..< 9 {
            t -= 1
            tmp[t] = u8('0' + r % 10)
            r /= 10
        }
    }
    for t < len(tmp) && tmp[t] == '0' do t += 1
    n := len(tmp) - t
    d.point = n - k
    for n > 0 && tmp[t + n - 1] == '0' do n -= 1
    copy(d.buf[:n], tmp[t:t + n])
    d.len = n
}

// Arredonda (metade para CIMA, sobre dígitos exatos) mantendo `keep` dígitos a
// partir do primeiro significativo. Escreve em `out` e devolve o nº de dígitos
// (keep, ou keep+1 se o "vai um" criou um dígito novo) e o novo `point`.
@(private = "file")
round_digits :: proc(d: ^Exact_Dec, keep: int, out: []u8) -> (n: int, point: int) {
    point = d.point
    if keep < 0 do return 0, point
    for i in 0 ..< keep do out[i] = i < d.len ? d.buf[i] : '0'
    n = keep
    if keep < d.len && d.buf[keep] >= '5' {
        i := keep - 1
        for i >= 0 && out[i] == '9' { out[i] = '0'; i -= 1 }
        if i >= 0 {
            out[i] += 1
        } else { // 999… → 1000…
            for j := n; j > 0; j -= 1 do out[j] = out[j - 1]
            out[0] = '1'
            n += 1
            point += 1
        }
    }
    return
}

// Dígitos mais curtos que fazem round-trip (o mesmo que o ToString usa).
@(private = "file")
shortest_digits :: proc(x: f64, out: []u8) -> (n: int, exp10: int) {
    buf: [64]u8
    sci := strconv.write_float(buf[:], x, 'e', -1, 64)
    body := sci
    if len(body) > 0 && (body[0] == '+' || body[0] == '-') do body = body[1:]
    epos := strings.index_byte(body, 'e')
    if epos < 0 do return 0, 0
    exp10, _ = strconv.parse_int(body[epos + 1:])
    for c in transmute([]u8)body[:epos] {
        if c == '.' do continue
        out[n] = c
        n += 1
    }
    for n > 1 && out[n - 1] == '0' do n -= 1
    return
}

@(private = "file")
write_exp_suffix :: proc(sb: ^strings.Builder, e: int) {
    strings.write_byte(sb, 'e')
    strings.write_byte(sb, e >= 0 ? '+' : '-')
    strings.write_int(sb, abs(e))
}

// ── os três métodos ──────────────────────────────────────────────────────────

this_number_value :: proc(vm: ^Interp, this: Value, method: string) -> (f64, bool) {
    if x, ok := this.(f64); ok do return x, true
    if p, ok := wrapper_value(this); ok {
        if x, ok2 := p.(f64); ok2 do return x, true
    }
    throw_type_error(vm, strings.concatenate({"Number.prototype.", method, " requires that 'this' be a Number"}, context.temp_allocator))
    return 0, false
}

// ToIntegerOrInfinity (NaN → 0; ±Infinity preservado em `inf`).
to_int_or_inf :: proc(vm: ^Interp, v: Value) -> (i: int, inf: int) {
    x := to_number(vm, v)
    if x != x do return 0, 0
    if x == math.inf_f64(1) do return 0, 1
    if x == math.inf_f64(-1) do return 0, -1
    x = math.trunc(x)
    if x > 1e9 do return 0, 1
    if x < -1e9 do return 0, -1
    return int(x), 0
}

range_error :: proc(vm: ^Interp, msg: string) -> Value {
    vm.thrown = mk_error(vm, "RangeError", msg)
    vm.throwing = true
    return nil
}

is_finite_num :: proc(x: f64) -> bool { return x == x && abs(x) != math.inf_f64(1) }

@(private = "file")
number_string :: proc(vm: ^Interp, x: f64) -> Value {
    sb := strings.builder_make(context.temp_allocator)
    to_text(&sb, x)
    return own_str(vm, strings.to_string(sb))
}

num_to_fixed :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this_number_value(vm, this, "toFixed")
    if !ok do return nil
    f, inf := to_int_or_inf(vm, arg(a, 0))
    if vm.throwing do return nil
    if inf != 0 || f < 0 || f > 100 do return range_error(vm, "toFixed() digits argument must be between 0 and 100")
    if !is_finite_num(x) do return number_string(vm, x)

    sb := strings.builder_make(context.temp_allocator)
    if x < 0 { strings.write_byte(&sb, '-'); x = -x }
    if x >= 1e21 {
        to_text(&sb, x)
        return own_str(vm, strings.to_string(sb))
    }
    // n = round(x · 10^f) como string: são os dígitos exatos até a f-ésima casa
    digits: [1200]u8
    n := 0
    if x != 0 {
        d: Exact_Dec
        exact_decimal(x, &d)
        n, _ = round_digits(&d, d.point + f, digits[:])
    }
    if n == 0 { digits[0] = '0'; n = 1 }
    m := string(digits[:n])
    switch {
    case f == 0:
        strings.write_string(&sb, m)
    case n > f: // a.b com b de f dígitos
        strings.write_string(&sb, m[:n - f])
        strings.write_byte(&sb, '.')
        strings.write_string(&sb, m[n - f:])
    case: // n ≤ f: "0." + zeros + m ((0.05).toFixed(2) → "0.05")
        strings.write_string(&sb, "0.")
        for _ in 0 ..< f - n do strings.write_byte(&sb, '0')
        strings.write_string(&sb, m)
    }
    return own_str(vm, strings.to_string(sb))
}

num_to_exponential :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this_number_value(vm, this, "toExponential")
    if !ok do return nil
    fd := arg(a, 0)
    f, inf := to_int_or_inf(vm, fd)
    if vm.throwing do return nil
    if !is_finite_num(x) do return number_string(vm, x)
    if inf != 0 || f < 0 || f > 100 do return range_error(vm, "toExponential() argument must be between 0 and 100")

    sb := strings.builder_make(context.temp_allocator)
    if x < 0 { strings.write_byte(&sb, '-'); x = -x }
    digits: [1200]u8
    n, e: int
    switch {
    case x == 0:
        n = fd == nil ? 1 : f + 1
        for i in 0 ..< n do digits[i] = '0'
    case fd == nil:
        n, e = shortest_digits(x, digits[:])
    case:
        d: Exact_Dec
        exact_decimal(x, &d)
        point: int
        n, point = round_digits(&d, f + 1, digits[:])
        n = f + 1 // o "vai um" só acrescenta um zero no fim
        e = point - 1
    }
    strings.write_byte(&sb, digits[0])
    if n > 1 {
        strings.write_byte(&sb, '.')
        strings.write_string(&sb, string(digits[1:n]))
    }
    write_exp_suffix(&sb, e)
    return own_str(vm, strings.to_string(sb))
}

num_to_precision :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this_number_value(vm, this, "toPrecision")
    if !ok do return nil
    if arg(a, 0) == nil do return number_string(vm, x)
    p, inf := to_int_or_inf(vm, a[0])
    if vm.throwing do return nil
    if !is_finite_num(x) do return number_string(vm, x)
    if inf != 0 || p < 1 || p > 100 do return range_error(vm, "toPrecision() argument must be between 1 and 100")

    sb := strings.builder_make(context.temp_allocator)
    if x < 0 { strings.write_byte(&sb, '-'); x = -x }
    digits: [1200]u8
    e := 0
    if x == 0 {
        for i in 0 ..< p do digits[i] = '0'
    } else {
        d: Exact_Dec
        exact_decimal(x, &d)
        _, point := round_digits(&d, p, digits[:])
        e = point - 1
    }
    m := string(digits[:p])
    switch {
    case e < -6 || e >= p:
        strings.write_byte(&sb, m[0])
        if p > 1 {
            strings.write_byte(&sb, '.')
            strings.write_string(&sb, m[1:])
        }
        write_exp_suffix(&sb, e)
    case e == p - 1:
        strings.write_string(&sb, m)
    case e >= 0:
        strings.write_string(&sb, m[:e + 1])
        strings.write_byte(&sb, '.')
        strings.write_string(&sb, m[e + 1:])
    case:
        strings.write_string(&sb, "0.")
        for _ in 0 ..< -(e + 1) do strings.write_byte(&sb, '0')
        strings.write_string(&sb, m)
    }
    return own_str(vm, strings.to_string(sb))
}
