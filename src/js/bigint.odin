package js

// BigInt — inteiros de precisão arbitrária (M87). Novo tipo `^BigInt` na union
// Value, sobre o `core:math/big`. Literais `123n`, `BigInt(x)`, `typeof x ===
// "bigint"`, aritmética (+ - * / % **), bitwise (& | ^ ~ << >>), comparações
// (mistura com Number nas relacionais e em ==, mas === exige mesmo tipo).
//
// REGRAS-CHAVE do JS: misturar BigInt e Number em ARITMÉTICA lança TypeError;
// `/` e `%` por 0n lançam RangeError; `**` com expoente negativo → RangeError;
// não há `>>>` (unsigned shift) p/ BigInt. `String(1n)` = "1" (sem o 'n').
//
// APROXIMAÇÕES: bitwise & | ^ com operandos NEGATIVOS pode divergir do two's
// complement infinito da spec (big usa sinal-magnitude; ~x = -(x+1) é exato);
// comparação relacional BigInt×Number usa f64 (perde precisão p/ valores enormes).

import "core:math"
import "core:math/big"
import "core:strings"
import "core:strconv"

BigInt :: struct {
    val: big.Int,
}

// ── criação / ciclo de vida ──────────────────────────────────────────────────

new_bigint :: proc(vm: ^Interp) -> ^BigInt {
    b := new(BigInt)
    append(&vm.all_bigints, b)
    return b
}

bigint_from_i64 :: proc(vm: ^Interp, n: i64) -> ^BigInt {
    b := new_bigint(vm)
    big.set(&b.val, n)
    return b
}

bigint_destroy :: proc(b: ^BigInt) {
    big.destroy(&b.val)
    free(b)
}

// Parseia uma string em BigInt (literais 123n e BigInt("...")): decimal por
// default; prefixos 0x/0b/0o; sinal opcional. ok=false em sintaxe inválida.
bigint_from_string :: proc(vm: ^Interp, s: string) -> (^BigInt, bool) {
    t := strings.trim_space(s)
    b := new_bigint(vm)
    if t == "" { big.set(&b.val, 0); return b, true } // BigInt("") === 0n
    neg := false
    body := t
    if body[0] == '+' || body[0] == '-' {
        neg = body[0] == '-'
        body = body[1:]
    }
    radix := i8(10)
    if len(body) >= 2 && body[0] == '0' {
        switch body[1] {
        case 'x', 'X': radix = 16; body = body[2:]
        case 'o', 'O': radix = 8;  body = body[2:]
        case 'b', 'B': radix = 2;  body = body[2:]
        }
    }
    if body == "" do return b, false
    for i in 0 ..< len(body) { // valida ANTES (big.atoi é leniente demais)
        if !bigint_valid_digit(body[i], radix) do return b, false
    }
    if err := big.atoi(&b.val, body, radix); err != nil do return b, false
    if neg do big.neg(&b.val, &b.val)
    return b, true
}

@(private = "file")
bigint_valid_digit :: proc(c: u8, radix: i8) -> bool {
    v: int
    switch {
    case c >= '0' && c <= '9': v = int(c - '0')
    case c >= 'a' && c <= 'z': v = int(c - 'a') + 10
    case c >= 'A' && c <= 'Z': v = int(c - 'A') + 10
    case: return false
    }
    return v < int(radix)
}

// ── consultas ────────────────────────────────────────────────────────────────

bigint_is_zero :: proc(b: ^BigInt) -> bool {
    z, _ := big.is_zero(&b.val)
    return z
}

// Converte p/ f64 via a string decimal (o int_get_float do core lê um dígito além
// do usado → resultado errado; parse_f64 da string é robusto e arredonda certo).
bigint_to_f64 :: proc(b: ^BigInt) -> f64 {
    s := bigint_to_string(b, 10)
    defer delete(s, context.allocator)
    f, _ := strconv.parse_f64(s)
    return f
}

// String decimal (ou noutra base) — alocada no context.allocator (o do vm em run).
// JS usa dígitos MINÚSCULOS (toString(16)→"ff"); o core big emite A-F maiúsculo,
// então baixamos A-Z→a-z (no-op p/ base 10). A string recém-alocada é mutável.
bigint_to_string :: proc(b: ^BigInt, radix: i8 = 10) -> string {
    s, err := big.itoa(&b.val, radix)
    if err != nil do return "0"
    bytes := transmute([]u8)s
    for i in 0 ..< len(bytes) {
        if bytes[i] >= 'A' && bytes[i] <= 'Z' do bytes[i] += 32
    }
    return s
}

bigint_compare :: proc(a, b: ^BigInt) -> int {
    c, _ := big.compare(&a.val, &b.val)
    return c
}

bigint_equals :: proc(a, b: ^BigInt) -> bool {
    return bigint_compare(a, b) == 0
}

// ── aritmética (novo ^BigInt tracked no vm) ──────────────────────────────────

bigint_add :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.add(&r.val, &a.val, &b.val); return r
}
bigint_sub :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.sub(&r.val, &a.val, &b.val); return r
}
bigint_mul :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.mul(&r.val, &a.val, &b.val); return r
}
bigint_neg :: proc(vm: ^Interp, a: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.neg(&r.val, &a.val); return r
}

// `/` de BigInt trunca em direção a ZERO (int_div). ok=false se divisor 0n.
bigint_div :: proc(vm: ^Interp, a, b: ^BigInt) -> (^BigInt, bool) {
    if bigint_is_zero(b) do return nil, false
    r := new_bigint(vm)
    big.int_div(&r.val, &a.val, &b.val)
    return r, true
}

// `%`: resto com SINAL do dividendo (int_divmod, não int_mod que é floored).
bigint_mod :: proc(vm: ^Interp, a, b: ^BigInt) -> (^BigInt, bool) {
    if bigint_is_zero(b) do return nil, false
    r := new_bigint(vm)
    q: big.Int
    big.int_divmod(&q, &r.val, &a.val, &b.val)
    big.destroy(&q)
    return r, true
}

// `**`: expoente não-negativo que caiba num int. kind: 0=ok, 1=neg, 2=grande.
bigint_pow :: proc(vm: ^Interp, a, b: ^BigInt) -> (^BigInt, int) {
    exp, gerr := big.get(&b.val, int)
    if gerr != nil do return nil, 2
    if exp < 0 do return nil, 1
    r := new_bigint(vm)
    big.pow(&r.val, &a.val, exp)
    return r, 0
}

// ── bitwise ──────────────────────────────────────────────────────────────────

bigint_and :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.bit_and(&r.val, &a.val, &b.val); return r
}
bigint_or :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.bit_or(&r.val, &a.val, &b.val); return r
}
bigint_xor :: proc(vm: ^Interp, a, b: ^BigInt) -> ^BigInt {
    r := new_bigint(vm); big.bit_xor(&r.val, &a.val, &b.val); return r
}
// ~x = -(x+1), exato p/ qualquer sinal.
bigint_not :: proc(vm: ^Interp, a: ^BigInt) -> ^BigInt {
    r := new_bigint(vm)
    one: big.Int; big.set(&one, 1)
    big.add(&r.val, &a.val, &one)
    big.neg(&r.val, &r.val)
    big.destroy(&one)
    return r
}
// deslocamento: conta negativa inverte a direção (semântica do JS). ok=false se
// a conta não couber num int (deslocamento gigante).
bigint_shl :: proc(vm: ^Interp, a, b: ^BigInt) -> (^BigInt, bool) {
    n, gerr := big.get(&b.val, int)
    if gerr != nil do return nil, false
    r := new_bigint(vm)
    if n >= 0 do big.shl(&r.val, &a.val, n)
    else do big.shr(&r.val, &a.val, -n)
    return r, true
}
bigint_shr :: proc(vm: ^Interp, a, b: ^BigInt) -> (^BigInt, bool) {
    n, gerr := big.get(&b.val, int)
    if gerr != nil do return nil, false
    r := new_bigint(vm)
    if n >= 0 do big.shr(&r.val, &a.val, n)
    else do big.shl(&r.val, &a.val, -n)
    return r, true
}

// ── operador binário (chamado por binop quando há um BigInt) ──────────────────

@(private = "file")
bigint_throw_range :: proc(vm: ^Interp, msg: string) {
    vm.thrown = mk_error(vm, "RangeError", msg)
    vm.throwing = true
}

// `l op r` com pelo menos um operando BigInt. Comparações/igualdade permitem
// misturar com Number/String; aritmética/bitwise exigem os DOIS BigInt (senão
// TypeError). `+` com string vira concatenação (o chamador já tratou? não — aqui).
bigint_binop :: proc(vm: ^Interp, op: Token_Kind, l, r: Value) -> Value {
    lb, lisb := l.(^BigInt)
    rb, risb := r.(^BigInt)

    // + envolvendo string → concatenação (como number+string)
    if op == .Plus && (is_string(l) || is_string(r)) do return concat(vm, l, r)

    #partial switch op {
    case .EqEqEq:  return bigint_strict_eq(l, r)
    case .NotEqEq: return !bigint_strict_eq(l, r)
    case .EqEq:    return bigint_loose_eq(l, r)
    case .NotEq:   return !bigint_loose_eq(l, r)
    case .Lt, .Gt, .LtEq, .GtEq:
        // ambos BigInt: comparação EXATA; misto: via f64
        if lisb && risb {
            c := bigint_compare(lb, rb)
            #partial switch op {
            case .Lt:   return c < 0
            case .Gt:   return c > 0
            case .LtEq: return c <= 0
            case .GtEq: return c >= 0
            }
        }
        lf := lisb ? bigint_to_f64(lb) : as_number(l)
        rf := risb ? bigint_to_f64(rb) : as_number(r)
        #partial switch op {
        case .Lt:   return lf < rf
        case .Gt:   return lf > rf
        case .LtEq: return lf <= rf
        case .GtEq: return lf >= rf
        }
    }

    // daqui p/ baixo: aritmética/bitwise — AMBOS têm de ser BigInt
    if !lisb || !risb {
        throw_type_error(vm, "Cannot mix BigInt and other types, use explicit conversions")
        return nil
    }
    #partial switch op {
    case .Plus:  return bigint_add(vm, lb, rb)
    case .Minus: return bigint_sub(vm, lb, rb)
    case .Star:  return bigint_mul(vm, lb, rb)
    case .Slash:
        res, ok := bigint_div(vm, lb, rb)
        if !ok { bigint_throw_range(vm, "Division by zero"); return nil }
        return res
    case .Percent:
        res, ok := bigint_mod(vm, lb, rb)
        if !ok { bigint_throw_range(vm, "Division by zero"); return nil }
        return res
    case .StarStar:
        res, kind := bigint_pow(vm, lb, rb)
        if kind == 1 { bigint_throw_range(vm, "Exponent must be non-negative"); return nil }
        if kind == 2 { bigint_throw_range(vm, "Maximum BigInt size exceeded"); return nil }
        return res
    case .Amp:   return bigint_and(vm, lb, rb)
    case .Pipe:  return bigint_or(vm, lb, rb)
    case .Caret: return bigint_xor(vm, lb, rb)
    case .Shl:
        res, ok := bigint_shl(vm, lb, rb)
        if !ok { bigint_throw_range(vm, "Maximum BigInt size exceeded"); return nil }
        return res
    case .Shr:
        res, ok := bigint_shr(vm, lb, rb)
        if !ok { bigint_throw_range(vm, "Maximum BigInt size exceeded"); return nil }
        return res
    case .UShr:
        throw_type_error(vm, "BigInts have no unsigned right shift, use >> instead")
        return nil
    }
    return nil
}

// === : só true se AMBOS BigInt e iguais (tipo importa).
@(private = "file")
bigint_strict_eq :: proc(l, r: Value) -> bool {
    lb, lok := l.(^BigInt)
    rb, rok := r.(^BigInt)
    if lok && rok do return bigint_equals(lb, rb)
    return false
}

// == : BigInt×BigInt por valor; BigInt×(Number/Bool/String) por valor matemático
// (número não-inteiro nunca iguala BigInt); BigInt×(null/undef/objeto) → false.
@(private = "file")
bigint_loose_eq :: proc(l, r: Value) -> bool {
    lb, lok := l.(^BigInt)
    rb, rok := r.(^BigInt)
    if lok && rok do return bigint_equals(lb, rb)
    bi := lok ? lb : rb
    other := lok ? r : l
    if is_nullish(other) do return false
    if is_ref_type(other) do return false // objeto/array/símbolo: sem toPrimitive
    n := as_number(other)
    if n != n do return false           // NaN
    if n != math.trunc(n) do return false // não-inteiro nunca iguala um BigInt
    return bigint_to_f64(bi) == n
}

// ── BigInt(x) global + prototype ─────────────────────────────────────────────

@(private = "file")
bigint_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    v := arg(args, 0)
    #partial switch x in v {
    case ^BigInt:
        return x
    case bool:
        return bigint_from_i64(vm, x ? 1 : 0)
    case string:
        b, ok := bigint_from_string(vm, x)
        if !ok {
            vm.thrown = mk_error(vm, "SyntaxError", "Cannot convert string to a BigInt")
            vm.throwing = true
            return nil
        }
        return b
    case f64:
        if x != math.trunc(x) || x != x || x == math.INF_F64 || x == math.NEG_INF_F64 {
            bigint_throw_range(vm, "The number is not a safe integer")
            return nil
        }
        return bigint_from_i64(vm, i64(x))
    }
    throw_type_error(vm, "Cannot convert value to a BigInt") // null/undefined/objeto/símbolo
    return nil
}

@(private = "file")
bigint_to_string_method :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    b, ok := this.(^BigInt)
    if !ok do return own_str(vm, "0")
    radix := i8(10)
    if len(args) >= 1 {
        r := as_int(args[0])
        if r >= 2 && r <= 36 do radix = i8(r)
    }
    return own_taken(vm, bigint_to_string(b, radix))
}

@(private = "file")
bigint_value_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return this // já é o BigInt
}

// BigInt.asUintN(bits, x) / asIntN(bits, x): trunca x a `bits` bits (mod 2^bits),
// interpretando com/sem sinal. Implementado via x mod 2^bits + ajuste de sinal.
@(private = "file")
bigint_as_uintn :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return bigint_as_n(vm, args, false)
}
@(private = "file")
bigint_as_intn :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return bigint_as_n(vm, args, true)
}
@(private = "file")
bigint_as_n :: proc(vm: ^Interp, args: []Value, signed: bool) -> Value {
    bits := as_int(arg(args, 0))
    if bits < 0 { bigint_throw_range(vm, "Invalid bits"); return nil }
    x, ok := arg(args, 1).(^BigInt)
    if !ok { throw_type_error(vm, "asN requires a BigInt"); return nil }
    // mod = x mod 2^bits (não-negativo)
    mod := new_bigint(vm)
    two_pow: big.Int; big.set(&two_pow, 1); big.shl(&two_pow, &two_pow, bits)
    q: big.Int
    big.int_divmod(&q, &mod.val, &x.val, &two_pow)
    if neg, _ := big.is_negative(&mod.val); neg do big.add(&mod.val, &mod.val, &two_pow) // torna não-negativo
    if signed { // se >= 2^(bits-1), subtrai 2^bits
        if bits > 0 {
            half: big.Int; big.set(&half, 1); big.shl(&half, &half, bits - 1)
            if c, _ := big.compare(&mod.val, &half); c >= 0 do big.sub(&mod.val, &mod.val, &two_pow)
            big.destroy(&half)
        }
    }
    big.destroy(&q); big.destroy(&two_pow)
    return mod
}

install_bigint :: proc(vm: ^Interp) {
    ctor := mk_native(vm, bigint_ctor)
    ctor.name = "BigInt"
    ctor.props = make(map[string]Value)
    proto := new_object(vm)
    proto.props["toString"] = mk_native(vm, bigint_to_string_method)
    proto.props["valueOf"]  = mk_native(vm, bigint_value_of)
    proto.props["constructor"] = ctor
    ctor.props["prototype"] = proto
    ctor.props["asUintN"]   = mk_native(vm, bigint_as_uintn)
    ctor.props["asIntN"]    = mk_native(vm, bigint_as_intn)
    vm.bigint_proto = proto
    env_define(vm.global, "BigInt", ctor)
}
