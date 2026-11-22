package js

// Built-ins: métodos de Array e String, o objeto Math e funções globais
// (parseInt, parseFloat, isNaN). Registrados no vm por install_builtins,
// chamado a partir de vm_init.
//
// Convenção de memória: strings NOVAS criadas aqui viram propriedade do vm
// (owned_strings) via own_str/own_taken, liberadas no vm_destroy.

import "core:math"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:fmt"

// ── helpers (visíveis no pacote: json.odin também usa) ──────────────────────

arg :: proc(args: []Value, i: int) -> Value {
    return args[i] if i < len(args) else nil
}

// Clona `s` para memória do vm (para views/fatias de strings existentes).
own_str :: proc(vm: ^Interp, s: string) -> Value {
    c := clone_js_string(s)
    append(&vm.owned_strings, c)
    return c
}

// Igual, mas devolvendo `string` — para quem guarda a cópia num campo TIPADO
// (o `text` de um Canvas_Cmd), onde um `Value` não serve.
own_str_raw :: proc(vm: ^Interp, s: string) -> string {
    c := clone_js_string(s)
    append(&vm.owned_strings, c)
    return c
}

// Assume posse de uma string JÁ alocada (ex.: resultado de strings.to_upper).
own_taken :: proc(vm: ^Interp, s: string) -> Value {
    if js_has_surrogate_pair(s) {
        c := clone_js_string(s)
        delete(s)
        append(&vm.owned_strings, c)
        return c
    }
    append(&vm.owned_strings, s)
    return s
}

mk_native :: proc(vm: ^Interp, fn: Native_Fn) -> ^Function {
    f := new_function(vm)
    f.native = fn
    return f
}

// ── índices de string em CODE UNITS UTF-16 (M167) ───────────────────────────
// O JS mede strings em unidades UTF-16; nós ARMAZENAMOS UTF-8. Estes helpers são
// a única camada que traduz entre os dois, e por isso `length`, `s[i]`, slice/
// substring/indexOf, `.index` de regex e `lastIndex` ficam todos consistentes de
// graça — interp e regex também passam por aqui.
//
// Um code point < 0x10000 vale 1 unidade; um astral (emoji) vale 2, porque no
// UTF-16 ele é um PAR SURROGATE. Era contado como 1 até o M166 ("😀".length dava
// 1 em vez de 2).
//
// Cortes no meio de um par preservam a metade em WTF-8. A concatenação
// recombina pares adjacentes, mantendo igualdade e chaves de objetos estáveis.

// Largura em bytes de um code point pelo seu PRIMEIRO byte. Percorrer com isto
// evita decodificar a rune inteira quando só precisamos avançar — decodificar em
// todo passo custou 4,4× no `length` de uma string de 2 KB (medido).
utf8_width :: proc(b: u8) -> int {
    if b < 0x80 do return 1
    if b < 0xE0 do return 2 // (bytes de continuação soltos caem aqui; string inválida só desalinha o passo, não estoura)
    if b < 0xF0 do return 3
    return 4
}

// comprimento em code units UTF-16 ("length" do JS).
//
// Count byte leaders directly, including WTF-8 surrogates as one unit. The
// Unicode rune counter would count each byte of a lone surrogate separately.
str_rlen :: proc(s: string) -> int {
    n := 0
    for i := 0; i < len(s); {
        n += 2 if s[i] >= 0xF0 else 1
        i += utf8_width(s[i])
    }
    return n
}

// offset de BYTE do índice de code unit `ui` (clampado a [0, len(s)]); um índice
// no meio de um par surrogate cai na fronteira seguinte (ver o aviso acima).
str_rbyte :: proc(s: string, ui: int) -> int {
    if ui <= 0 do return 0
    k := 0
    for i := 0; i < len(s); {
        if k >= ui do return i
        w := utf8_width(s[i])
        k += 2 if s[i] >= 0xF0 else 1
        i += w
    }
    return len(s)
}

// índice de CODE UNIT do offset de byte `bo` (bo deve cair em fronteira de rune)
str_rindex :: proc(s: string, bo: int) -> int {
    k := 0
    for i := 0; i < len(s) && i < bo; {
        w := utf8_width(s[i])
        k += 2 if s[i] >= 0xF0 else 1
        i += w
    }
    return k
}

// fatia por índices de code unit [lo, hi)
str_rslice :: proc(s: string, lo, hi: int) -> string {
    if hi <= lo do return ""
    bl, split_lo := js_unit_boundary(s, lo)
    bh, split_hi := js_unit_boundary(s, hi)
    if !split_lo && !split_hi do return s[bl:max(bl,bh)]
    sb := strings.builder_make(context.temp_allocator)
    if split_lo {
        r, w := decode_js_rune(s[bl:])
        write_js_rune(&sb, 0xDC00 + ((r-0x10000) & 1023))
        bl += w
    }
    if bh > bl do strings.write_string(&sb, s[bl:bh])
    if split_hi {
        r, _ := decode_js_rune(s[bh:])
        write_js_rune(&sb, 0xD800 + ((r-0x10000) >> 10))
    }
    return strings.to_string(sb)
}

// A unidade UTF-16 no índice ui, preservada em WTF-8; vazio fora do intervalo.
str_rune_at :: proc(s: string, ui: int) -> string {
    if ui < 0 do return ""
    return str_rslice(s, ui, ui+1)
}

// O CODE UNIT UTF-16 no índice `ui` — para um astral devolve o high surrogate no
// 1º índice e o low no 2º, como exige charCodeAt.
str_code_unit_at :: proc(s: string, ui: int) -> (u16, bool) {
    if ui < 0 do return 0, false
    k := 0
    for i := 0; i < len(s); {
        r, w := decode_js_rune(s[i:])
        if r < 0x10000 {
            if k == ui do return u16(r), true
            k += 1
        } else {
            v := u32(r) - 0x10000
            if k == ui     do return u16(0xD800 + (v >> 10)), true   // high
            if k + 1 == ui do return u16(0xDC00 + (v & 0x3FF)), true // low
            k += 2
        }
        i += w
    }
    return 0, false
}

// Índice no estilo JS: negativo conta do fim; resultado limitado a [0, n].
@(private = "file")
idx_from :: proc(v: f64, n: int) -> int {
    if v != v do return 0 // NaN
    if v >= f64(n) do return n
    if v <= -f64(n) do return 0
    i := int(v)
    if i < 0 do i += n
    if i < 0 do i = 0
    if i > n do i = n
    return i
}

// ── métodos de Array ────────────────────────────────────────────────────────

@(private = "file")
arr_push :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    if n + len(args) > (1 << 53) - 1 { throw_type_error(vm, "Invalid array-like length"); return nil }
    for v, i in args { arr_set(vm, this, n + i, v); if vm.throwing do return nil }
    arr_write(vm, this, "length", f64(n + len(args)))
    return f64(n + len(args))
}

@(private = "file")
arr_pop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    v: Value
    if n > 0 {
        v = array_like_get(vm, this, n - 1)
        if vm.throwing do return nil
        arr_delete(vm, this, n - 1)
    }
    arr_write(vm, this, "length", f64(max(0, n - 1)))
    return v
}

@(private = "file")
arr_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    if n == 0 do return f64(-1)
    from := arr_integer(vm, arg(args, 1))
    if vm.throwing do return nil
    if from < 0 do from = max(n + from, 0)
    for i := from; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        if v == arg(args, 0) do return f64(i)
    }
    return f64(-1)
}

@(private = "file")
// Array.prototype.includes: compara por SameValueZero, NÃO por === — é justamente
// o que o separa do indexOf, porque só assim `[NaN].includes(NaN)` é true. Usava o
// `==` da union, onde NaN != NaN pelo IEEE, e o caso NaN falhava calado.
arr_includes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    if n == 0 do return false
    from := arr_integer(vm, arg(args, 1))
    if vm.throwing do return nil
    if from < 0 do from = max(n + from, 0)
    for i := from; i < n; i += 1 {
        
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        if same_value_zero(v, arg(args, 0)) do return true
    }
    return false
}

@(private = "file")
arr_join :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // `this` que não é ^Array segue como array-like (ver arr_index_of). Um ^Object
    // SEM length dá n=0 e o resultado continua "", como antes.
    a, is_arr := this.(^Array)
    n := is_arr ? len(a.items) : array_like_len(vm, this)
    if vm.throwing do return nil
    sep := ","
    if arg(args, 0) != nil do sep = to_js_string(vm, args[0])
    if vm.throwing do return nil
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i < n; i += 1 {
        if i > 0 do strings.write_string(&sb, sep)
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        // spec: null/undefined viram STRING VAZIA no join (não "null"/"undefined")
        if it == nil do continue
        if _, is_null := it.(JS_Null); is_null do continue
        write_text_spec(&sb, vm, it) // ToString da spec (respeita toString custom)
        if vm.throwing do return nil
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
// ⚠️ É por AQUI que uma coleção do DOM vira array no código de site real:
// `[].slice.call(el.children)` / `Array.prototype.slice.call(nodeList)` é o idioma
// mais comum que existe. Enquanto o `!ok` devolvia array VAZIO, trocar children de
// ^Array para coleção viva teria zerado esse idioma EM SILÊNCIO.
arr_slice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    start := idx_from(to_number(vm, arg(args, 0)), n)
    if vm.throwing do return nil
    end := n
    if arg(args, 1) != nil do end = idx_from(to_number(vm, args[1]), n)
    if vm.throwing do return nil
    count := max(0, end - start)
    out := array_species_create(vm, this, count)
    if vm.throwing do return nil
    for i := 0; i < count; i += 1 {
        if !array_like_has(vm,this, start + i) do continue
        v := array_like_get(vm, this, start + i)
        if vm.throwing do return nil
        array_result_set(vm, out, i, v)
        if vm.throwing do return nil
    }
    arr_write(vm, out, "length", f64(count))
    return out
}

// ── acesso genérico a array-like ────────────────────────────────────────────
// Spec: os métodos de Array operam sobre ToObject(this) usando ToLength(this.length)
// e acesso indexado — não só sobre arrays reais. Habilita o idioma ubíquo
// `Array.prototype.map.call(arguments/nodeList/{length,0:...}, fn)`. ^Array segue
// pelo caminho rápido (items diretos); ^Object/^Function leem length+índice.
array_like_len :: proc(vm: ^Interp, this: Value) -> int {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return 0 }
    #partial switch t in this {
    case ^Array:  return len(t.items)
    case string:  return str_rlen(t)
    case ^Object, ^Function:
        length := get_member(vm, this, "length")
        if vm.throwing do return 0
        n := to_number(vm, length)
        if vm.throwing do return 0
        if n != n || n <= 0 do return 0 // NaN / negativo → 0 (ToLength)
        MAXLEN :: (1 << 53) - 1
        if n > f64(MAXLEN) do return MAXLEN
        return int(n) // positivo trunca p/ baixo
    }
    return 0 // primitivo não-objeto (número/bool): wrapper sem length → 0
}

array_like_get :: proc(vm: ^Interp, this: Value, i: int) -> Value {
    #partial switch t in this {
    case ^Array:  return get_index(vm, t, f64(i))
    case string:  return own_str(vm, str_rslice(t, i, i + 1)) if i >= 0 && i < str_rlen(t) else nil
    case ^Object, ^Function:
        buf: [24]u8
        return get_index(vm, this, f64(i))
    }
    return nil
}

// HasProperty(this, i): buracos (índices ausentes) são PULADOS pelos métodos de
// Array (spec) — `[].filter.call({length:2, 1:true}, ...)` só visita o índice 1.
@(private = "file")
array_like_has :: proc(vm: ^Interp, this: Value, i: int) -> bool {
    #partial switch t in this {
    case ^Array:  return arr_has_index(t, i) // buraco = ausente (pulado)
    case string:  return i >= 0 && i < str_rlen(t)
    case ^Object:
        // Proxy: HasProperty é o trap `has` (ou o default no alvo). As props do
        // objeto-proxy em si são vazias — sem isto todo índice dava "ausente" e
        // `reverse.call(proxy)` com length 2^53 iterava para sempre sem tocar o alvo.
        if t.px_handler != nil {
            buf: [24]u8
            return proxy_has(vm, t, strconv.write_int(buf[:], i64(i), 10))
        }
        // objeto HOST com acesso INDEXADO (geti != nil, hoje só as coleções vivas de
        // DOM): os índices não moram em `props` — quem os serve é o hook. Sem esta
        // linha, uma HTMLCollection tem length>0 e NENHUM índice "presente", e
        // forEach/map/filter/reduce varrem a coleção inteira sem visitar nada — o pior
        // tipo de falha, silenciosa e com resultado plausível. Coleção não tem buraco:
        // dentro de [0, length) o índice existe sempre, e é o chamador quem já limita
        // `i` a esse intervalo (array_like_len).
        // A condição é `geti`, não `get`: um wrapper host qualquer (classList, style,
        // window) tem get-hook e NÃO serve índices — dizer "presente" ali faria
        // forEach visitar N undefineds.
        if t.geti != nil do return i >= 0
        if n, is_ta := ta_own_index_count(t); is_ta do return i >= 0 && i < n // TypedArray: índice no range existe
        buf: [24]u8
        key := strconv.write_int(buf[:], i64(i), 10)
        // HasProperty sobe a CADEIA (spec) — e desde o M208 isso importa de verdade:
        // `Object.create(<array>)` herda length E os índices, então parar nas props
        // PRÓPRIAS deixava o objeto com length=2 e nenhum índice "presente" —
        // `[].map.call(o, f)` devolvia `[null,null]` em vez do resultado. Mesma falha
        // silenciosa que o `geti` acima conserta para as coleções vivas.
        // ⚠️ o `get` hook segue de FORA de propósito (ver o parágrafo acima).
        for cur := t; cur != nil; cur = cur.proto {
            if _, has := cur.getters[key]; has do return true
            if _, has := cur.setters[key]; has do return true
            if cur.props == nil do continue
            if _, has := cur.props[key]; has do return true
        }
        if array_is_array(t.prim) do return array_like_has(vm,t.prim, i)
        if x := proto_exotic_end(t); x != nil do return array_like_has(vm,x, i)
        return false
    case ^Function:
        if t.props == nil do return false
        buf: [24]u8
        _, has := t.props[strconv.write_int(buf[:], i64(i), 10)]
        return has
    }
    return false
}

@(private = "file")
arr_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.forEach called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.forEach: callback não é função"); return nil }
    this_arg := arg(args, 1)
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue // pula buracos (HasProperty)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        call_function(vm, cb, this_arg, []Value{it, f64(i), this})
        if vm.throwing do break // exceção no callback interrompe a iteração
    }
    return nil
}

@(private = "file")
arr_map :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.map called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.map: callback não é função"); return nil }
    res := array_species_create(vm, this, n)
    if vm.throwing do return nil
    this_arg := arg(args, 1)
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) { continue } // buraco → undefined (preserva posição)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        v := call_function(vm, cb, this_arg, []Value{it, f64(i), this})
        if vm.throwing do return nil
        array_result_set(vm, res, i, v)
        if vm.throwing do break
    }
    return res
}

@(private = "file")
arr_filter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.filter called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.filter: callback não é função"); return nil }
    res := array_species_create(vm, this, 0)
    if vm.throwing do return nil
    target := 0
    this_arg := arg(args, 1)
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue // pula buracos (HasProperty)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        accepted := call_function(vm, cb, this_arg, []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(accepted) { array_result_set(vm, res, target, it); target += 1 }
        if vm.throwing do break
    }
    return res
}

@(private = "file")
arr_reverse :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    for lo := 0; lo < n / 2; lo += 1 {
        hi := n - lo - 1
        lh := array_like_has(vm,this, lo)
        lv: Value; if lh do lv = array_like_get(vm, this, lo)
        if vm.throwing do return nil
        hh := array_like_has(vm,this, hi)
        hv: Value; if hh do hv = array_like_get(vm, this, hi)
        if vm.throwing do return nil
        if hh { arr_set(vm, this, lo, hv) } else { arr_delete(vm, this, lo) }
        if vm.throwing do return nil
        if lh { arr_set(vm, this, hi, lv) } else { arr_delete(vm, this, hi) }
        if vm.throwing do return nil
    }
    return this
}

// "x vem depois de y?" para o sort: comparador JS (>0) ou, sem comparador, a
// comparação de STRINGS do JS (por isso [10,9,1].sort() dá [1,10,9]).
@(private = "file")
sort_after :: proc(vm: ^Interp, cmp: ^Function, x, y: Value) -> bool {
    if x == nil do return y != nil
    if y == nil do return false
    if cmp != nil {
        result := call_function(vm, cmp, nil, []Value{x, y})
        if vm.throwing do return false
        return to_number(vm, result) > 0
    }
    sbx, sby: strings.Builder
    strings.builder_init(&sbx); defer strings.builder_destroy(&sbx)
    strings.builder_init(&sby); defer strings.builder_destroy(&sby)
    write_text_spec(&sbx, vm, x)
    if vm.throwing do return false
    write_text_spec(&sby, vm, y)
    return js_string_compare(strings.to_string(sbx), strings.to_string(sby)) > 0
}

// sort in-place (insertion sort — arrays de página são pequenos), devolve o array.
@(private = "file")
arr_sort :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    cmp, ok := arg(args, 0).(^Function)
    if arg(args, 0) != nil && !ok { throw_type_error(vm, "Comparator is not a function"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    values := new_array(vm)
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        append(&values.items, array_like_get(vm, this, i))
        if vm.throwing do return nil
    }
    for i := 1; i < len(values.items); i += 1 {
        v := values.items[i]
        j := i - 1
        for j >= 0 {
            after := sort_after(vm, cmp, values.items[j], v)
            if vm.throwing do return nil
            if !after do break
            values.items[j + 1] = values.items[j]; j -= 1
        }
        values.items[j + 1] = v
    }
    for v, i in values.items { arr_set(vm, this, i, v); if vm.throwing do return nil }
    for i := len(values.items); i < n; i += 1 { arr_delete(vm, this, i); if vm.throwing do return nil }
    return this
}

@(private = "file")
arr_reduce :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.reduce called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.reduce: callback não é função"); return nil }
    acc: Value
    start := 0
    if len(args) >= 2 {
        acc = args[1]
    } else {
        // sem valor inicial: acc = 1º índice PRESENTE (pula buracos à esquerda)
        for start < n && !array_like_has(vm,this, start) do start += 1
        // TypeError REAL (era string crua → assert.throws(TypeError) não casava)
        if start >= n { throw_type_error(vm, "Reduce of empty array with no initial value"); return nil }
        acc = array_like_get(vm, this, start)
        if vm.throwing do return nil
        start += 1
    }
    for i := start; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue // pula buracos (HasProperty)
        cur := array_like_get(vm, this, i)
        if vm.throwing do break
        acc = call_function(vm, cb, nil, []Value{acc, cur, f64(i), this})
        if vm.throwing do break
    }
    return acc
}

// reduceRight: como reduce, mas da direita p/ a esquerda. callback(acc, cur, idx, array).
@(private = "file")
arr_reduce_right :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.reduceRight called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.reduceRight: callback não é função"); return nil }
    acc: Value
    start := n - 1
    if len(args) >= 2 {
        acc = args[1]
    } else {
        // sem valor inicial: acc = 1º índice PRESENTE (pula buracos à esquerda)
        for start >= 0 && !array_like_has(vm,this, start) do start -= 1
        // TypeError REAL (era string crua → assert.throws(TypeError) não casava)
        if start < 0 { throw_type_error(vm, "Reduce of empty array with no initial value"); return nil }
        acc = array_like_get(vm, this, start)
        if vm.throwing do return nil
        start -= 1
    }
    for i := start; i >= 0; i -= 1 {
        if !array_like_has(vm,this, i) do continue // pula buracos (HasProperty)
        cur := array_like_get(vm, this, i)
        if vm.throwing do break
        acc = call_function(vm, cb, nil, []Value{acc, cur, f64(i), this})
        if vm.throwing do break
    }
    return acc
}

@(private = "file")
arr_concat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "concat called on null or undefined"); return nil }
    out := array_species_create(vm, this, 0)
    if vm.throwing do return nil
    target := 0
    for part := -1; part < len(args); part += 1 {
        item := this if part < 0 else args[part]
        spread := false
        if !is_primitive(item) {
            marker := get_member(vm, item, vm.sym_concat_spreadable_key)
            if vm.throwing do return nil
            spread = array_is_array(item) if marker == nil else truthy(marker)
        }
        if spread {
            n := array_like_len(vm, item)
            if vm.throwing do return nil
            if target + n > (1 << 53) - 1 { throw_type_error(vm, "Invalid concat length"); return nil }
            for i := 0; i < n; i += 1 {
                if array_like_has(vm,item, i) {
                    v := array_like_get(vm, item, i)
                    if vm.throwing do return nil
                    array_result_set(vm, out, target, v)
                    if vm.throwing do return nil
                }
                target += 1
            }
        } else {
            if target >= (1 << 53) - 1 { throw_type_error(vm, "Invalid concat length"); return nil }
            array_result_set(vm, out, target, item)
            if vm.throwing do return nil
            target += 1
        }
    }
    arr_write(vm, out, "length", f64(target))
    return out
}

@(private = "file")
arr_find :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := 0; i < n; i += 1 {
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(r) do return it
    }
    return nil
}

@(private = "file")
arr_find_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := 0; i < n; i += 1 {
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(r) do return f64(i)
    }
    return f64(-1)
}

@(private = "file")
arr_some :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(r) do return true
    }
    return false
}

@(private = "file")
arr_every :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if !truthy(r) do return false
    }
    return true
}

@(private = "file")
arr_shift :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    v: Value
    if n > 0 {
        v = array_like_get(vm, this, 0)
        if vm.throwing do return nil
        for i := 1; i < n; i += 1 { arr_move(vm, this, i, i - 1); if vm.throwing do return nil }
        arr_delete(vm, this, n - 1)
    }
    arr_write(vm, this, "length", f64(max(0, n - 1)))
    return v
}

@(private = "file")
arr_unshift :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    count := len(args)
    if n + count > (1 << 53) - 1 { throw_type_error(vm, "Invalid array-like length"); return nil }
    if count > 0 {
        for i := n - 1; i >= 0; i -= 1 { arr_move(vm, this, i, i + count); if vm.throwing do return nil }
        for v, i in args { arr_set(vm, this, i, v); if vm.throwing do return nil }
    }
    arr_write(vm, this, "length", f64(n + count))
    return f64(n + count)
}

// ── Change Array by Copy (ES2023) ───────────────────────────────────────────
// `toReversed`/`toSorted`/`toSpliced`/`with` são as versões que NÃO mutam o
// receptor. Vieram JUNTAS na mesma proposta e o código de página as usa em
// cadeia (`n.filter(...).map(...).toSorted(...)` — o x.com quebrava exatamente
// aí), então implementar uma só empurraria o TypeError para a linha seguinte.
//
// Sempre devolvem um Array novo e DENSO: a spec lê os buracos do receptor como
// `undefined` (ao contrário de `reverse`/`sort` in-place, que os preservam).
// Genéricas sobre array-like pelo mesmo caminho do `slice`.
@(private = "file")
arr_copy_of :: proc(vm: ^Interp, this: Value) -> ^Array {
    res := new_array(vm)
    a, is_arr := this.(^Array)
    n := is_arr ? len(a.items) : array_like_len(vm, this)
    if vm.throwing do return nil
    for i := 0; i < n; i += 1 {
        append(&res.items, array_like_get(vm, this, i))
        if vm.throwing do return nil
    }
    return res
}

@(private = "file")
arr_to_reversed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    res := new_array(vm)
    for i := n - 1; i >= 0; i -= 1 {
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        append(&res.items, v)
    }
    return res
}

// The copy is dense; sorting shares comparator validation and ordering.
@(private = "file")
arr_to_sorted :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    _, ok := arg(args, 0).(^Function)
    if arg(args, 0) != nil && !ok { throw_type_error(vm, "Comparator is not a function"); return nil }
    res := arr_copy_of(vm, this)
    if vm.throwing do return nil
    return arr_sort(vm, res, args)
}

// toSpliced(start, skipCount, ...novos): como splice, mas devolve o array NOVO
// (o splice devolve os REMOVIDOS — a diferença é fácil de errar).
@(private = "file")
arr_to_spliced :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    start := idx_from(to_number(vm, arg(args, 0)), n)
    if vm.throwing do return nil
    skip := n - start if len(args) > 0 else 0
    if len(args) >= 2 do skip = min(max(arr_integer(vm, args[1]), 0), n - start)
    if vm.throwing do return nil
    count := max(0, len(args) - 2)
    if n - skip + count > (1 << 53) - 1 { throw_type_error(vm, "Invalid array-like length"); return nil }
    res := new_array(vm)
    for i := 0; i < start; i += 1 {
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        append(&res.items, v)
    }
    for i := 2; i < len(args); i += 1 do append(&res.items, args[i])
    for i := start + skip; i < n; i += 1 {
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        append(&res.items, v)
    }
    return res
}

// with(index, value): cópia com UM índice trocado. Índice negativo conta do fim;
// fora do range é RangeError (não silêncio) — é o que distingue do `arr[i]=v`.
@(private = "file")
arr_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    index := arr_integer(vm, arg(args, 0))
    if vm.throwing do return nil
    if index < 0 do index += n
    if index < 0 || index >= n { vm.thrown = mk_error(vm, "RangeError", "Invalid index"); vm.throwing = true; return nil }
    res := new_array(vm)
    for i := 0; i < n; i += 1 {
        v := arg(args, 1) if i == index else array_like_get(vm, this, i)
        if vm.throwing do return nil
        append(&res.items, v)
    }
    return res
}

// splice(start, deleteCount, ...novos) — remove/insere in-place; devolve os removidos.
@(private = "file")
arr_splice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    start := idx_from(to_number(vm, arg(args, 0)), n)
    if vm.throwing do return nil
    delc := n - start if len(args) > 0 else 0
    if len(args) >= 2 do delc = min(max(arr_integer(vm, args[1]), 0), n - start)
    if vm.throwing do return nil
    count := max(0, len(args) - 2)
    if n - delc + count > (1 << 53) - 1 { throw_type_error(vm, "Invalid array-like length"); return nil }
    removed := array_species_create(vm, this, delc)
    if vm.throwing do return nil
    for i := 0; i < delc; i += 1 {
        if !array_like_has(vm,this, start + i) do continue
        v := array_like_get(vm, this, start + i)
        if vm.throwing do return nil
        array_result_set(vm, removed, i, v)
        if vm.throwing do return nil
    }
    arr_write(vm, removed, "length", f64(delc))
    if vm.throwing do return nil
    if count < delc {
        for i := start; i < n - delc; i += 1 { arr_move(vm, this, i + delc, i + count); if vm.throwing do return nil }
        for i := n - 1; i >= n - delc + count; i -= 1 { arr_delete(vm, this, i); if vm.throwing do return nil }
    } else if count > delc {
        for i := n - delc - 1; i >= start; i -= 1 { arr_move(vm, this, i + delc, i + count); if vm.throwing do return nil }
    }
    for i := 0; i < count; i += 1 { arr_set(vm, this, start + i, args[i + 2]); if vm.throwing do return nil }
    arr_write(vm, this, "length", f64(n - delc + count))
    return removed
}

// ── métodos de String ───────────────────────────────────────────────────────
// Índices e comprimentos em unidades UTF-16; iteração em code points.

@(private = "file")
str_char_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    i := as_int(arg(args, 0)) // NaN/ausente → 0
    return own_str(vm, str_rune_at(s, i)) // fora do range → "" (spec)
}

@(private = "file")
// charCodeAt: o CODE UNIT UTF-16 no índice — para um emoji devolve o high
// surrogate (0xD83D...) no 1º índice e o low no 2º, como manda a spec. Devolvia o
// code point inteiro, que é o que codePointAt faz.
str_char_code_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return nil
    i := as_int(arg(args, 0)) // NaN/ausente → 0
    u, in_range := str_code_unit_at(s, i)
    if !in_range do return math.nan_f64() // fora do range → NaN (spec); devolvia undefined
    return f64(u)
}

// codePointAt: o CODE POINT no índice — para um emoji devolve 0x1F600 no índice do
// high surrogate, e o low solto se o índice cair no meio (spec).
@(private = "file")
str_code_point_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return nil
    i := as_int(arg(args, 0))
    u, in_range := str_code_unit_at(s, i)
    if !in_range do return nil
    if u >= 0xD800 && u <= 0xDBFF {
        lo, ok := str_code_unit_at(s, i+1)
        if ok && lo >= 0xDC00 && lo <= 0xDFFF do return f64(0x10000 + ((u32(u)-0xD800) << 10) + u32(lo)-0xDC00)
    }
    return f64(u)
}

@(private = "file")
str_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.indexOf requires a receiver"); return nil }
    s := to_js_string(vm, this); if vm.throwing do return nil
    sub := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    pos := to_number(vm, arg(args, 1)); if vm.throwing do return nil
    return f64(js_string_find(s, sub, clamp_index(pos, str_rlen(s))))
}

// ToString(v) da spec p/ os métodos de String que coagem argumentos: primitivos
// direto; um objeto invoca o seu toString() (próprio ou herdado de Object.prototype).
// Sem isto, `"a1".replace(1,"x")` ou `"x".includes({toString:()=>"x"})` viravam no-op.
to_js_string :: proc(vm: ^Interp, v: Value) -> string {
    if s, ok := v.(string); ok do return s
    val := v
    if o, ook := v.(^Object); ook {
        m := get_member(vm, o, "toString")
        if fn, fok := m.(^Function); fok {
            r := call_function(vm, fn, o, nil)
            if vm.throwing do return ""
            if s, sok := r.(string); sok do return s
            val = r // toString devolveu não-string: serializa o resultado
        }
    }
    // ToString(Symbol) LANÇA (spec 7.1.17) — `"a".startsWith(Symbol())` não pode
    // virar a busca por "Symbol()". (String(sym) é o caso à parte que descreve o
    // símbolo, e não passa por aqui.)
    if _, issym := val.(^Symbol); issym {
        throw_type_error(vm, "Cannot convert a Symbol value to a string")
        return ""
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    to_text(&sb, val)
    out := strings.clone(strings.to_string(sb))
    strings.builder_destroy(&sb)
    append(&vm.owned_strings, out)
    return out
}

// includes(searchString, position): honra `position` (ToInteger, clampado a
// [0,len]) e coage searchString via ToString — antes ignorava a posição e só
// aceitava string, quebrando `"word".includes("o",3)` (→ false) e coerção.
@(private = "file")
str_includes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, sub, ok := str_search_args(vm, this, args, "includes")
    if !ok do return nil
    pos := to_number(vm, arg(args, 1)); if vm.throwing do return nil
    return js_string_find(s, sub, clamp_index(pos, str_rlen(s))) >= 0
}

@(private = "file")
str_slice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    n := str_rlen(s)
    // undefined explícito conta como ausente (spec: end undefined → até o fim).
    // to_number = ToInteger com valueOf: `"x".slice({valueOf:()=>2})`; valueOf que
    // lança propaga (antes as_number dava NaN sem chamar valueOf).
    start := 0
    if len(args) >= 1 && args[0] != nil {
        sv := to_number(vm, args[0]); if vm.throwing do return nil
        start = idx_from(sv, n)
    }
    end := n
    if len(args) >= 2 && args[1] != nil {
        ev := to_number(vm, args[1]); if vm.throwing do return nil
        end = idx_from(ev, n)
    }
    if start > end do start = end
    return own_str(vm, str_rslice(s, start, end))
}

// substring difere de slice: negativos/NaN viram 0 (sem contar do fim) e
// start > end TROCA os argumentos em vez de devolver vazio.
@(private = "file")
str_substring :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    n := str_rlen(s)
    clamp01 :: proc(v: Value, n: int) -> int {
        x := as_number(v)
        if x != x || x < 0 do return 0 // NaN/negativo → 0
        if x > f64(n) do return n
        return int(x)
    }
    start := len(args) >= 1 && args[0] != nil ? clamp01(args[0], n) : 0
    end   := len(args) >= 2 && args[1] != nil ? clamp01(args[1], n) : n
    if start > end do start, end = end, start
    return own_str(vm, str_rslice(s, start, end))
}

// substr(start, length) — Annex B, legado mas MUITO comum: `Math.random().toString(36).substr(2)`
// (geração de ID; sem ele ge/g1.globo e outros caíam em ".substr is not a function", gap #1
// tratável do gap-miner). Difere de substring/slice: o 2º arg é COMPRIMENTO, não índice final;
// start negativo conta do fim uma vez. Índices em unidades UTF-16.
@(private = "file")
str_substr :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    n := str_rlen(s)
    start := 0
    if len(args) >= 1 && args[0] != nil {
        sv := to_number(vm, args[0]); if vm.throwing do return nil
        start = idx_from(sv, n) // negativo→do fim, clamp [0,n] (== max(n+start,0) do Annex B)
    }
    length := n - start // length ausente/undefined → até o fim
    if len(args) >= 2 && args[1] != nil {
        lv := to_number(vm, args[1]); if vm.throwing do return nil
        li := 0
        if lv == lv { // não-NaN (NaN→0)
            if lv < 0        do li = 0
            else if lv > f64(n) do li = n // cap seguro (evita int(+Inf) e limita a size-start abaixo)
            else             do li = int(lv)
        }
        if li < length do length = li
    }
    if length <= 0 do return own_str(vm, "")
    return own_str(vm, str_rslice(s, start, start + length))
}

// toString/valueOf de String: devolvem o próprio primitivo. Faltavam — bundles
// minificados chamam `x.toString()`/`x.valueOf()` sobre valores de tipo desconhecido
// (que podem ser string), estourando ".toString is not a function" (gap do gap-miner:
// techcrunch e outros). Number já tinha os dois; String não.
@(private = "file")
str_identity :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_str(vm, s)
}

@(private = "file")
str_to_upper :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_taken(vm, strings.to_upper(s))
}

@(private = "file")
str_to_lower :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_taken(vm, strings.to_lower(s))
}

@(private = "file")
str_trim :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_str(vm, strings.trim_space(s))
}

@(private = "file")
str_repeat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    n := as_int(arg(args, 0))
    if n <= 0 do return own_str(vm, "")
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for _ in 0 ..< n do strings.write_string(&sb, s)
    return own_str(vm, strings.to_string(sb))
}

// concat(...args): ToString(this) seguido de ToString de cada argumento, tudo
// concatenado. Estava FALTANDO — era o gap de motor mais comum entre sites reais
// (17 no gap-report: dev.to, python.org, getbootstrap, ...). O erro que aparecia
// era `(intermediate value).concat is not a function`.
@(private = "file")
str_concat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, to_js_string(vm, this)); if vm.throwing do return nil
    for a in args {
        strings.write_string(&sb, to_js_string(vm, a)); if vm.throwing do return nil
    }
    return own_str(vm, strings.to_string(sb))
}

// ── helpers de regex para replace ───────────────────────────────────────────

@(private = "file")
write_replacement :: proc(sb: ^strings.Builder, repl: string, s: string, m: Re_Match, re: ^Regex) {
    i := 0
    for i < len(repl) {
        if repl[i] == '$' && i + 1 < len(repl) {
            next := repl[i + 1]
            switch {
            case next == '$':
                strings.write_byte(sb, '$'); i += 2
            case next == '&':
                gs, ge := m.groups[0], m.groups[1]
                if gs >= 0 do strings.write_string(sb, str_rslice(s, gs, ge))
                i += 2
            case next == '`':
                gs := m.groups[0]
                if gs > 0 do strings.write_string(sb, str_rslice(s, 0, gs))
                i += 2
            case next == '\'':
                ge := m.groups[1]
                if ge >= 0 && ge <= str_rlen(s) do strings.write_string(sb, str_rslice(s, ge, str_rlen(s)))
                i += 2
            case next >= '1' && next <= '9':
                idx := int(next - '0')
                i += 2
                if i < len(repl) && repl[i] >= '0' && repl[i] <= '9' {
                    idx2 := idx * 10 + int(repl[i] - '0')
                    if idx2 <= re.ngroups { idx = idx2; i += 1 }
                }
                if idx <= re.ngroups {
                    gs2, ge2 := m.groups[2 * idx], m.groups[2 * idx + 1]
                    if gs2 >= 0 do strings.write_string(sb, str_rslice(s, gs2, ge2))
                }
            case next == '<' && len(re.gnames) > 0:
                // $<nome>: grupo nomeado (spec GetSubstitution). Sem `>` de fechamento
                // fica literal; nome inexistente ou grupo que não casou vira "".
                // Sem grupos nomeados no padrão, `$<` é sempre literal (cai no default).
                close := strings.index_byte(repl[i + 2:], '>')
                if close < 0 { strings.write_string(sb, "$<"); i += 2; break }
                name := repl[i + 2:][:close]
                if _, found := re.gnames[name]; found {
                    gi := regex_named_group(re, name, m)
                    gs2, ge2 := m.groups[2 * gi], m.groups[2 * gi + 1]
                    if gs2 >= 0 do strings.write_string(sb, str_rslice(s, gs2, ge2))
                }
                i += 2 + close + 1
            case:
                strings.write_byte(sb, '$'); i += 1
            }
        } else {
            strings.write_byte(sb, repl[i]); i += 1
        }
    }
}

@(private = "file")
write_replacer_result :: proc(vm: ^Interp, sb: ^strings.Builder, fn: ^Function, s: string, m: Re_Match, re: ^Regex) {
    fargs: [dynamic]Value
    defer delete(fargs)
    gs, ge := m.groups[0], m.groups[1]
    append(&fargs, gs >= 0 ? own_str(vm, str_rslice(s, gs, ge)) : Value(nil))
    for g in 1 ..= re.ngroups {
        gs2, ge2 := m.groups[2 * g], m.groups[2 * g + 1]
        append(&fargs, gs2 >= 0 ? own_str(vm, str_rslice(s, gs2, ge2)) : Value(nil))
    }
    append(&fargs, f64(gs)) // offset em unidades UTF-16
    append(&fargs, Value(s))
    // com grupos nomeados, o callback recebe o objeto `groups` por último (spec)
    if len(re.gnames) > 0 do append(&fargs, regex_groups_object(vm, re, s, m))
    result := call_function(vm, fn, nil, fargs[:])
    to_text(sb, result)
}

@(private = "file")
regex_replace_impl :: proc(vm: ^Interp, s: string, re: ^Regex, replacement: Value, all: bool) -> Value {
    repl_fn, is_fn := replacement.(^Function)
    repl_str := ""
    if !is_fn {
        repl_str = to_js_string(vm, replacement) // ToString: `.replace(/x/,1)` → "1"
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    last := 0
    start := 0
    for {
        m := regex_run(re, s, start)
        if !m.ok do break
        defer delete(m.groups)
        gs, ge := m.groups[0], m.groups[1]
        strings.write_string(&sb, str_rslice(s, last, gs))
        if is_fn {
            write_replacer_result(vm, &sb, repl_fn, s, m, re)
        } else {
            write_replacement(&sb, repl_str, s, m, re)
        }
        last = ge
        if !all do break
        start = js_advance_index(s, ge, re.unicode || re.unicode_sets) if ge == gs else ge
        if start > str_rlen(s) do break
    }
    strings.write_string(&sb, str_rslice(s, last, str_rlen(s)))
    return own_str(vm, strings.to_string(sb))
}

// replace(pattern, replacement) — regex com $-refs/função OU string (1ª ocorrência).
@(private = "file")
str_replace :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.replace requires a receiver"); return nil }
    pattern := arg(args, 0)
    replacement := arg(args, 1)
    if result, handled := str_custom_replace(vm, this, pattern, replacement); handled do return result
    s := to_js_string(vm, this)
    if vm.throwing do return nil

    if re, rok := pattern.(^Regex); rok {
        return regex_replace_impl(vm, s, re, replacement, re.global)
    }

    old := to_js_string(vm, pattern) // ToString(searchValue): `.replace(1,"x")`, {toString}
    if vm.throwing do return own_str(vm, s)

    return string_replace_impl(vm, s, old, replacement, false)
}

@(private = "file")
str_custom_replace :: proc(vm: ^Interp, receiver, pattern, replacement: Value) -> (Value, bool) {
    // Só OBJETO delega (spec atual: "If regexp is an Object"); um primitivo não
    // consulta String.prototype[@@replace].
    if is_primitive(pattern) do return nil, false
    method := get_member(vm, pattern, vm.sym_replace_key)
    if vm.throwing do return nil, true
    if is_nullish(method) do return nil, false
    if fn, ok := method.(^Function); ok {
        return call_function(vm, fn, pattern, []Value{receiver, replacement}), true
    }
    throw_type_error(vm, "Symbol.replace must be callable")
    return nil, true
}

// $-refs de replacement com pattern STRING (sem grupos): $$ → $, $& → casado,
// $` → antes, $' → depois; $1..$9 ficam LITERAIS (spec: sem capturas).
write_str_replacement :: proc(sb: ^strings.Builder, repl: string, s: string, idx: int, old_len: int) {
    i := 0
    for i < len(repl) {
        if repl[i] == '$' && i + 1 < len(repl) {
            switch repl[i + 1] {
            case '$':  strings.write_byte(sb, '$');                    i += 2; continue
            case '&':  strings.write_string(sb, str_rslice(s, idx, idx+old_len)); i += 2; continue
            case '`':  strings.write_string(sb, str_rslice(s, 0, idx));              i += 2; continue
            case '\'': strings.write_string(sb, str_rslice(s, idx+old_len, str_rlen(s)));    i += 2; continue
            }
        }
        strings.write_byte(sb, repl[i])
        i += 1
    }
}

@(private = "file")
str_replace_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.replaceAll requires a receiver"); return nil }
    pattern := arg(args, 0)
    if !is_nullish(pattern) {
        isre := is_regexp(vm, pattern) // IsRegExp + flags, como no matchAll
        if vm.throwing do return nil
        if isre && !regexp_has_flag(vm, pattern, 'g', "replaceAll") do return nil
    }
    if result, handled := str_custom_replace(vm, this, pattern, arg(args, 1)); handled do return result
    s := to_js_string(vm, this)
    if vm.throwing do return nil
    if re, rok := pattern.(^Regex); rok {
        return regex_replace_impl(vm, s, re, arg(args, 1), true)
    }

    old := to_js_string(vm, pattern) // ToString(searchValue)
    if vm.throwing do return own_str(vm, s)
    return string_replace_impl(vm, s, old, arg(args, 1), true)
}

@(private = "file")
str_starts_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, sub, ok := str_search_args(vm, this, args, "startsWith")
    if !ok do return nil
    n := str_rlen(s)
    pos := 0
    if len(args) >= 2 && args[1] != nil {
        pv := to_number(vm, args[1]); if vm.throwing do return nil
        pos = clamp_index(pv, n)
    }
    return js_string_find(s, sub, pos) == pos
}

// endsWith(sub, endPosition): a busca termina em endPosition (padrão: o fim).
// Antes as duas ignoravam a posição e exigiam que o argumento já fosse string.
@(private = "file")
str_ends_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, sub, ok := str_search_args(vm, this, args, "endsWith")
    if !ok do return nil
    n := str_rlen(s)
    end := n
    if len(args) >= 2 && args[1] != nil {
        pv := to_number(vm, args[1]); if vm.throwing do return nil
        end = clamp_index(pv, n)
    }
    start := end - str_rlen(sub)
    return start >= 0 && js_string_find(s, sub, start) == start
}

// Comum a startsWith/endsWith: `this` string e ToString do 1º argumento, que NÃO
// pode ser RegExp (spec: TypeError — evita que `s.startsWith(/a/)` vire "/a/").
@(private = "file")
str_search_args :: proc(vm: ^Interp, this: Value, args: []Value, method: string) -> (string, string, bool) {
    s, ok := this.(string)
    if !ok {
        if is_nullish(this) { throw_type_error(vm, fmt.tprintf("String.prototype.%s called on null or undefined", method)); return "", "", false }
        s = to_js_string(vm, this); if vm.throwing do return "", "", false
    }
    isre := is_regexp(vm, arg(args, 0)) // IsRegExp: @@match decide (não só ^Regex)
    if vm.throwing do return "", "", false
    if isre {
        throw_type_error(vm, fmt.tprintf("First argument to String.prototype.%s must not be a regular expression", method))
        return "", "", false
    }
    sub := to_js_string(vm, arg(args, 0)); if vm.throwing do return "", "", false
    return s, sub, true
}

// ToIntegerOrInfinity(v) limitado a [0, n] — sem passar NaN/±Infinity por `int()`,
// que em Odin é comportamento indefinido.
@(private = "file")
clamp_index :: proc(v: f64, n: int) -> int {
    if v != v || v <= 0 do return 0
    if v >= f64(n) do return n
    return int(v)
}

// padStart/padEnd: comprimento e truncamento em unidades UTF-16.
@(private = "file")
str_pad :: proc(vm: ^Interp, this: Value, args: []Value, at_start: bool) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    want := as_int(arg(args, 0)) // comprimento-alvo em unidades UTF-16
    pad := " "
    if p := arg(args, 1); p != nil { pad = to_js_string(vm, p); if vm.throwing do return nil }
    n := str_rlen(s)
    if want <= n || pad == "" do return own_str(vm, s)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    fill := want - n
    pr := js_string_chars(pad, false)
    if !at_start do strings.write_string(&sb, s)
    for i := 0; i < fill; i += 1 do write_js_rune(&sb, pr[i % len(pr)])
    if at_start do strings.write_string(&sb, s)
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
str_pad_start :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return str_pad(vm, this, args, true)
}

@(private = "file")
str_pad_end :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return str_pad(vm, this, args, false)
}

// ── protocolo dos símbolos de regex (@@match/@@matchAll/@@search/@@split) ─────
// Os métodos de String que aceitam regex (spec 22.1.3) não sabem nada de RegExp:
// se o argumento não é null/undefined e tem um método @@x, a chamada é DELEGADA a
// ele. É o que permite um objeto qualquer se comportar como padrão, e o que o
// core-js/babel testam (`''.split({[Symbol.split]: () => 7}) === 7`) antes de
// decidir se substituem o método nativo.
//
// A RegExp NATIVA chega aqui também: o RegExp.prototype tem @@x nativos (ver
// install_regex_symbol_methods), que rodam os *_impl abaixo. Desvio consciente: os
// nativos exigem `this` ^Regex e usam o motor direto — a spec os escreve em cima de
// `this.exec(...)`, então um `re.exec = fn` sobrescrito NÃO é consultado.
@(private = "file")
str_delegate :: proc(vm: ^Interp, pattern: Value, key: string, what: string, call_args: []Value) -> (Value, bool) {
    // Só OBJETO delega (spec atual: "If regexp is an Object"). Um separador
    // primitivo como "," NÃO consulta String.prototype[@@split] — o Test262
    // (cstm-*-on-*-primitive) instala um getter que lança ali para provar isso.
    if key == "" || is_primitive(pattern) do return nil, false
    method := get_member(vm, pattern, key)
    if vm.throwing do return nil, true
    if is_nullish(method) do return nil, false
    if fn, ok := method.(^Function); ok {
        return call_function(vm, fn, pattern, call_args), true
    }
    throw_type_error(vm, fmt.tprintf("%s must be callable", what))
    return nil, true
}

// IsRegExp (spec 7.2.8): objeto com @@match ⇒ ToBoolean dele; sem @@match, só uma
// RegExp de verdade. `re[Symbol.match] = false` faz a regex passar por string em
// startsWith/includes; `{[Symbol.match]: true}` faz um objeto qualquer ser recusado.
// Quem chama confere vm.throwing (o getter de @@match pode lançar).
is_regexp :: proc(vm: ^Interp, v: Value) -> bool {
    if is_primitive(v) do return false
    if vm.sym_match_key != "" {
        m := get_member(vm, v, vm.sym_match_key)
        if vm.throwing do return false
        if m != nil do return truthy(m)
    }
    _, isre := v.(^Regex)
    return isre
}

// RegExpCreate(arg, flags) dos métodos de String: ToString do padrão (undefined →
// padrão vazio) e regex inválida LANÇA SyntaxError. Antes um não-string virava o
// padrão vazio (`"x1".match(1)` casava "" na posição 0) e regex inválida dava null.
@(private = "file")
str_regex_create :: proc(vm: ^Interp, pattern: Value, flags: string) -> ^Regex {
    pat := ""
    if pattern != nil {
        pat = to_js_string(vm, pattern)
        if vm.throwing do return nil
    }
    re, ok := regex_compile(vm, pat, flags)
    if !ok {
        vm.thrown = mk_error(vm, "SyntaxError", fmt.tprintf("Invalid regular expression: /%s/", pat))
        vm.throwing = true
        return nil
    }
    return re
}

// `this` dos métodos de String: RequireObjectCoercible + ToString.
@(private = "file")
str_this :: proc(vm: ^Interp, this: Value, method: string) -> (string, bool) {
    if is_nullish(this) {
        throw_type_error(vm, fmt.tprintf("String.prototype.%s called on null or undefined", method))
        return "", false
    }
    s := to_js_string(vm, this)
    return s, !vm.throwing
}

// limit do split: ToUint32 (undefined = 2^32−1).
@(private = "file")
split_limit :: proc(vm: ^Interp, v: Value) -> (int, bool) {
    if v == nil do return int(0xFFFFFFFF), true
    number := to_number(vm, v)
    if vm.throwing do return 0, false
    return int(to_uint32(Value(number))), true
}

@(private = "file")
str_split :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.split requires a receiver"); return nil }
    sep_val := arg(args, 0)
    if r, handled := str_delegate(vm, sep_val, vm.sym_split_key, "Symbol.split", []Value{this, arg(args, 1)}); handled do return r
    s := to_js_string(vm, this); if vm.throwing do return nil
    limit, lok := split_limit(vm, arg(args, 1))
    if !lok do return nil
    res := new_array(vm)
    if limit == 0 do return res
    n := str_rlen(s)
    if re, rok := sep_val.(^Regex); rok do return regex_split_impl(vm, re, s, limit)
    if sep_val == nil { append(&res.items, own_str(vm, s)); return res }
    sep := to_js_string(vm, sep_val); if vm.throwing do return nil
    if sep == "" {
        for i in 0 ..< min(n,limit) do append(&res.items, own_str(vm, str_rslice(s, i, i+1)))
        return res
    }
    last := 0
    for {
        found := js_string_find(s, sep, last)
        if found < 0 do break
        append(&res.items, own_str(vm, str_rslice(s, last, found)))
        if len(res.items) == limit do return res
        last = found + str_rlen(sep)
    }
    append(&res.items, own_str(vm, str_rslice(s, last, n)))
    return res
}

// Split por regex: tentativa ANCORADA (sticky) em cada posição — o equivalente ao
// splitter com flag "y" da spec. Corpo de String.prototype.split e de
// RegExp.prototype[@@split].
@(private = "file")
regex_split_impl :: proc(vm: ^Interp, re: ^Regex, s: string, limit: int) -> Value {
    res := new_array(vm)
    if limit == 0 do return res
    n := str_rlen(s)
    {
        points := re.unicode || re.unicode_sets
        if n == 0 {
            m := regex_run(re, s, 0, true)
            defer delete(m.groups)
            if !m.ok do append(&res.items, own_str(vm, ""))
            return res
        }
        last, start := 0, 0
        for start < n {
            m := regex_run(re, s, start, true)
            if !m.ok { start = js_advance_index(s, start, points); continue }
            end := m.groups[1]
            if end == last {
                delete(m.groups)
                start = js_advance_index(s, start, points)
                continue
            }
            append(&res.items, own_str(vm, str_rslice(s, last, start)))
            if len(res.items) == limit { delete(m.groups); return res }
            for g in 1 ..= re.ngroups {
                lo, hi := m.groups[2*g], m.groups[2*g+1]
                append(&res.items, own_str(vm, str_rslice(s, lo, hi)) if lo >= 0 else Value(nil))
                if len(res.items) == limit { delete(m.groups); return res }
            }
            delete(m.groups)
            last = end; start = end
        }
        append(&res.items, own_str(vm, str_rslice(s, last, n)))
        return res
    }
}

// match(regexp): delega a regexp[@@match]; senão RegExpCreate + o match da regex.
@(private = "file")
str_match :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.match called on null or undefined"); return nil }
    if r, handled := str_delegate(vm, arg(args, 0), vm.sym_match_key, "Symbol.match", []Value{this}); handled do return r
    s := to_js_string(vm, this); if vm.throwing do return nil
    re := str_regex_create(vm, arg(args, 0), "")
    if re == nil do return nil
    return regex_match_impl(vm, re, s)
}

// sem g: [match, g1, ...] ou null; com g: [match1, match2, ...] ou null (lastIndex
// termina em 0, como no laço de exec da spec).
@(private = "file")
regex_match_impl :: proc(vm: ^Interp, re: ^Regex, s: string) -> Value {
    if re.global {
        re.last_index = 0
        arr := new_array(vm)
        start := 0
        for {
            m := regex_run(re, s, start)
            if !m.ok do break
            defer delete(m.groups)
            gs, ge := m.groups[0], m.groups[1]
            append(&arr.items, own_str(vm, str_rslice(s, gs, ge)))
            start = js_advance_index(s, ge, re.unicode || re.unicode_sets) if ge == gs else ge
            if start > str_rlen(s) do break
        }
        return len(arr.items) > 0 ? Value(arr) : Value(JS_Null{})
    }
    m := regex_run(re, s, 0)
    if !m.ok do return JS_Null{}
    defer delete(m.groups)
    return regex_result_array(vm, re, s, m)
}

// search(regexp): delega a regexp[@@search]; senão RegExpCreate + o search da regex.
@(private = "file")
str_search :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.search called on null or undefined"); return nil }
    if r, handled := str_delegate(vm, arg(args, 0), vm.sym_search_key, "Symbol.search", []Value{this}); handled do return r
    s := to_js_string(vm, this); if vm.throwing do return nil
    re := str_regex_create(vm, arg(args, 0), "")
    if re == nil do return nil
    return regex_search_impl(vm, re, s)
}

// Índice (UTF-16) da 1ª correspondência, ou -1. Busca desde 0 e não toca no
// lastIndex (a spec o salva e restaura); com a flag y, ancorada em 0.
@(private = "file")
regex_search_impl :: proc(vm: ^Interp, re: ^Regex, s: string) -> Value {
    m := regex_run(re, s, 0, re.sticky)
    if !m.ok do return f64(-1)
    defer delete(m.groups)
    return f64(m.groups[0])
}

// matchAll(regexp): regex (IsRegExp) sem a flag g é TypeError ANTES da delegação;
// depois delega a regexp[@@matchAll]; senão RegExpCreate(regexp, "g").
@(private = "file")
str_match_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.matchAll called on null or undefined"); return nil }
    pattern := arg(args, 0)
    if !is_nullish(pattern) {
        isre := is_regexp(vm, pattern)
        if vm.throwing do return nil
        if isre && !regexp_has_flag(vm, pattern, 'g', "matchAll") do return nil
    }
    if r, handled := str_delegate(vm, pattern, vm.sym_match_all_key, "Symbol.matchAll", []Value{this}); handled do return r
    s := to_js_string(vm, this); if vm.throwing do return nil
    re := str_regex_create(vm, pattern, "g")
    if re == nil do return nil
    return regex_match_all_impl(vm, re, s)
}

// Para matchAll/replaceAll com um padrão IsRegExp: Get(flags), RequireObjectCoercible,
// ToString, e TypeError se faltar a flag. false = já lançou.
@(private = "file")
regexp_has_flag :: proc(vm: ^Interp, pattern: Value, flag: byte, method: string) -> bool {
    flags := get_member(vm, pattern, "flags")
    if vm.throwing do return false
    if is_nullish(flags) {
        throw_type_error(vm, fmt.tprintf("String.prototype.%s: regexp flags is null or undefined", method))
        return false
    }
    fs := to_js_string(vm, flags)
    if vm.throwing do return false
    if strings.index_byte(fs, flag) < 0 {
        throw_type_error(vm, fmt.tprintf("String.prototype.%s called with a non-global RegExp argument", method))
        return false
    }
    return true
}

// Iterador de TODOS os matches desde lastIndex, cada um com grupos/.index/.input/
// .groups. Não mexe no lastIndex da regex (a spec itera um CLONE). Sem a flag g
// (só via RegExp.prototype[@@matchAll] direto), dá só o 1º casamento, como na spec.
@(private = "file")
regex_match_all_impl :: proc(vm: ^Interp, re: ^Regex, s: string) -> Value {
    out := new_array(vm)
    start := max(0, re.last_index)
    for start <= str_rlen(s) {
        m := regex_run(re, s, start)
        if !m.ok do break
        defer delete(m.groups)
        append(&out.items, regex_result_array(vm, re, s, m))
        if !re.global do break
        gs, ge := m.groups[0], m.groups[1]
        start = js_advance_index(s, ge, re.unicode || re.unicode_sets) if ge == gs else ge
    }
    return make_array_iterator(vm, out)
}

// ── RegExp.prototype[@@match/@@matchAll/@@search/@@split/@@replace] ───────────
// Dois caminhos:
//   RÁPIDO — `this` é uma ^Regex (ou subclasse sem nada sobrescrito): `exec` é o
//       nativo e `flags` bate com a regex. Os *_impl rodam o motor direto, como os
//       métodos de String sempre fizeram.
//   GENÉRICO — qualquer outro objeto: os algoritmos da spec (22.2.6.*) em cima de
//       RegExpExec, que chama o `exec` que o objeto TIVER. É o que deixa um
//       `re.exec = fn` (ou `class R extends RegExp { exec() {} }`) ser respeitado, e
//       o que o core-js/babel testam (DELEGATES_TO_EXEC) antes de decidir se trocam
//       os métodos nativos.
// O @@matchAll genérico devolve um iterador PREGUIÇOSO (exec a cada next()), como
// na spec; o caminho rápido segue coletando na hora (sem exec observável, dá igual).

// A ^Regex de `rx`, se ela for uma regex de verdade ou o wrapper de uma subclasse.
regex_of :: proc(rx: Value) -> ^Regex {
    #partial switch r in rx {
    case ^Regex:  return r
    case ^Object: if re, ok := r.prim.(^Regex); ok do return re
    }
    return nil
}

// A ^Regex de `rx` se o caminho RÁPIDO vale; nil = use o genérico (ou já lançou).
regex_fast :: proc(vm: ^Interp, rx: Value) -> ^Regex {
    re := regex_of(rx)
    if re == nil do return nil
    ex := get_member(vm, rx, "exec")
    if vm.throwing do return nil
    if fn, ok := ex.(^Function); !ok || fn != vm.regex_exec_fn do return nil
    fl := get_member(vm, rx, "flags")
    if vm.throwing do return nil
    fs, ok := fl.(string)
    if !ok || len(fs) != len(re.flags) do return nil
    for c in fs do if strings.index_rune(re.flags, c) < 0 do return nil // mesma letra, qualquer ordem
    return re
}

// Caminho rápido de @@split/@@matchAll: além do regex_fast, o SpeciesConstructor
// tem de ser o %RegExp% — e ele roda SEMPRE (um `constructor` inválido lança
// TypeError mesmo numa regex comum; o Test262 species-constructor-* cobre isso).
regex_fast_species :: proc(vm: ^Interp, rx: Value) -> ^Regex {
    re := regex_fast(vm, rx)
    if re == nil do return nil
    c := rx_species_ctor(vm, rx)
    if c == nil do return nil // lançou
    default_ctor, _ := vm.regex_proto.props["constructor"].(^Function)
    return re if c == default_ctor else nil
}

// RegExpExec(R, S) (spec 22.2.7.1): o `exec` do objeto, se chamável (resultado tem de
// ser objeto ou null); senão R precisa ser RegExp e roda o exec nativo.
regexp_exec :: proc(vm: ^Interp, rx: Value, s: string) -> Value {
    ex := get_member(vm, rx, "exec")
    if vm.throwing do return nil
    if fn, ok := ex.(^Function); ok {
        r := call_function(vm, fn, rx, []Value{s})
        if vm.throwing do return nil
        if _, null := r.(JS_Null); null do return r
        if is_primitive(r) {
            throw_type_error(vm, "RegExp exec method returned something other than an Object or null")
            return nil
        }
        return r
    }
    re := regex_of(rx)
    if re == nil {
        throw_type_error(vm, "RegExp.prototype.exec called on an incompatible receiver")
        return nil
    }
    return call_function(vm, vm.regex_exec_fn, re, []Value{s})
}

// ToLength(v) limitado ao que um int de índice de string precisa.
@(private = "file")
rx_to_length :: proc(vm: ^Interp, v: Value) -> int {
    n := to_number(vm, v)
    if vm.throwing || n != n || n <= 0 do return 0
    if n >= 9007199254740991 do return 9007199254740991
    return int(n)
}

@(private = "file")
rx_get_last_index :: proc(vm: ^Interp, rx: Value) -> int {
    v := get_member(vm, rx, "lastIndex")
    if vm.throwing do return 0
    return rx_to_length(vm, v)
}

// Set(rx, "lastIndex", v, true): falha de escrita é TypeError.
@(private = "file")
rx_set_last_index :: proc(vm: ^Interp, rx: Value, v: Value) -> bool {
    if !set_member(vm, rx, "lastIndex", v) && !vm.throwing {
        throw_type_error(vm, "Cannot assign to read only property 'lastIndex'")
    }
    return !vm.throwing
}

// ToString(Get(rx, "flags")).
@(private = "file")
rx_flags :: proc(vm: ^Interp, rx: Value) -> string {
    fl := get_member(vm, rx, "flags")
    if vm.throwing do return ""
    return to_js_string(vm, fl)
}

// ToString(Get(result, k)).
@(private = "file")
rx_result_str :: proc(vm: ^Interp, result: Value, k: string) -> string {
    v := get_member(vm, result, k)
    if vm.throwing do return ""
    return to_js_string(vm, v)
}

// Depois de um casamento VAZIO num laço global: lastIndex = AdvanceStringIndex.
@(private = "file")
rx_advance_after_empty :: proc(vm: ^Interp, rx: Value, s: string, full_unicode: bool) -> bool {
    i := rx_get_last_index(vm, rx)
    if vm.throwing do return false
    return rx_set_last_index(vm, rx, f64(js_advance_index(s, i, full_unicode)))
}

// O `this` dos @@métodos: na spec, qualquer OBJETO (não só RegExp).
@(private = "file")
rx_receiver :: proc(vm: ^Interp, this: Value, what: string) -> bool {
    if is_primitive(this) {
        throw_type_error(vm, fmt.tprintf("RegExp.prototype[%s] called on a non-object", what))
        return false
    }
    return true
}

// SameValue (o `obj_is` do Object.is é privado de object.odin): como ===, mas NaN
// é igual a NaN e +0 ≠ -0.
@(private = "file")
rx_same_value :: proc(a, b: Value) -> bool {
    if x, xok := a.(f64); xok {
        y, yok := b.(f64)
        if !yok do return false
        if x != x && y != y do return true
        if x == 0 && y == 0 do return math.sign_bit(x) == math.sign_bit(y)
        return x == y
    }
    return a == b
}

// SpeciesConstructor(rx, %RegExp%).
@(private = "file")
rx_species_ctor :: proc(vm: ^Interp, rx: Value) -> ^Function {
    default_ctor, _ := vm.regex_proto.props["constructor"].(^Function) // %RegExp%
    c := get_member(vm, rx, "constructor")
    if vm.throwing do return nil
    if c == nil do return default_ctor
    if is_primitive(c) {
        throw_type_error(vm, "object.constructor is not an object")
        return nil
    }
    sp := get_member(vm, c, vm.sym_species_key)
    if vm.throwing do return nil
    if is_nullish(sp) do return default_ctor
    if f, ok := sp.(^Function); ok do return f
    throw_type_error(vm, "object.constructor[Symbol.species] is not a constructor")
    return nil
}

@(private = "file")
regex_sym_match :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if !rx_receiver(vm, this, "Symbol.match") do return nil
    s := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    if re := regex_fast(vm, this); re != nil do return regex_match_impl(vm, re, s)
    if vm.throwing do return nil
    flags := rx_flags(vm, this); if vm.throwing do return nil
    if strings.index_byte(flags, 'g') < 0 do return regexp_exec(vm, this, s)
    full := strings.index_byte(flags, 'u') >= 0 || strings.index_byte(flags, 'v') >= 0
    if !rx_set_last_index(vm, this, f64(0)) do return nil
    out := new_array(vm)
    for {
        r := regexp_exec(vm, this, s); if vm.throwing do return nil
        if _, null := r.(JS_Null); null do return len(out.items) == 0 ? Value(JS_Null{}) : Value(out)
        ms := rx_result_str(vm, r, "0"); if vm.throwing do return nil
        append(&out.items, own_str(vm, ms))
        if ms == "" && !rx_advance_after_empty(vm, this, s, full) do return nil
    }
}

@(private = "file")
regex_sym_search :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if !rx_receiver(vm, this, "Symbol.search") do return nil
    s := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    if re := regex_fast(vm, this); re != nil do return regex_search_impl(vm, re, s)
    if vm.throwing do return nil
    is_pos_zero :: proc(v: Value) -> bool { n, ok := v.(f64); return ok && n == 0 && !math.sign_bit(n) }
    prev := get_member(vm, this, "lastIndex"); if vm.throwing do return nil
    if !is_pos_zero(prev) && !rx_set_last_index(vm, this, f64(0)) do return nil
    r := regexp_exec(vm, this, s); if vm.throwing do return nil
    cur := get_member(vm, this, "lastIndex"); if vm.throwing do return nil
    if !rx_same_value(cur, prev) && !rx_set_last_index(vm, this, prev) do return nil
    if _, null := r.(JS_Null); null do return f64(-1)
    return get_member(vm, r, "index")
}

@(private = "file")
regex_sym_replace :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if !rx_receiver(vm, this, "Symbol.replace") do return nil
    s := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    if re := regex_fast(vm, this); re != nil do return regex_replace_impl(vm, s, re, arg(args, 1), re.global)
    if vm.throwing do return nil
    repl_fn, functional := arg(args, 1).(^Function)
    repl_str := ""
    if !functional { repl_str = to_js_string(vm, arg(args, 1)); if vm.throwing do return nil }
    flags := rx_flags(vm, this); if vm.throwing do return nil
    global := strings.index_byte(flags, 'g') >= 0
    full := strings.index_byte(flags, 'u') >= 0 || strings.index_byte(flags, 'v') >= 0
    if global && !rx_set_last_index(vm, this, f64(0)) do return nil
    results := make([dynamic]Value, context.temp_allocator)
    for {
        r := regexp_exec(vm, this, s); if vm.throwing do return nil
        if _, null := r.(JS_Null); null do break
        append(&results, r)
        if !global do break
        ms := rx_result_str(vm, r, "0"); if vm.throwing do return nil
        if ms == "" && !rx_advance_after_empty(vm, this, s, full) do return nil
    }
    slen := str_rlen(s)
    sb := strings.builder_make(context.temp_allocator)
    next_pos := 0
    for r in results {
        ncap := rx_to_length(vm, get_member(vm, r, "length")) - 1
        if vm.throwing do return nil
        if ncap < 0 do ncap = 0
        matched := rx_result_str(vm, r, "0"); if vm.throwing do return nil
        pv := to_number(vm, get_member(vm, r, "index")); if vm.throwing do return nil
        position := clamp_index(pv, slen)
        captures := make([]Value, ncap, context.temp_allocator)
        for n in 1 ..= ncap {
            c := get_member(vm, r, fmt.tprintf("%d", n)); if vm.throwing do return nil
            if c != nil { c = own_str(vm, to_js_string(vm, c)); if vm.throwing do return nil }
            captures[n - 1] = c
        }
        named := get_member(vm, r, "groups"); if vm.throwing do return nil
        if _, null := named.(JS_Null); null && !functional {
            throw_type_error(vm, "Cannot convert null to object (exec result groups)") // ToObject(null)
            return nil
        }
        replacement: string
        if functional {
            fargs := make([dynamic]Value, context.temp_allocator)
            append(&fargs, own_str(vm, matched))
            append(&fargs, ..captures)
            append(&fargs, f64(position), Value(s))
            if named != nil do append(&fargs, named)
            rv := call_function(vm, repl_fn, nil, fargs[:]); if vm.throwing do return nil
            replacement = to_js_string(vm, rv); if vm.throwing do return nil
        } else {
            rb := strings.builder_make(context.temp_allocator)
            get_substitution(vm, &rb, matched, s, position, captures, named, repl_str)
            if vm.throwing do return nil
            replacement = strings.to_string(rb)
        }
        if position >= next_pos {
            strings.write_string(&sb, str_rslice(s, next_pos, position))
            strings.write_string(&sb, replacement)
            next_pos = position + str_rlen(matched)
        }
    }
    if next_pos < slen do strings.write_string(&sb, str_rslice(s, next_pos, slen))
    return own_str(vm, strings.to_string(sb))
}

// GetSubstitution (spec 22.1.3.19.1) com capturas já em string — a versão genérica
// do write_replacement (que lê direto do Re_Match).
@(private = "file")
get_substitution :: proc(vm: ^Interp, sb: ^strings.Builder, matched, s: string, position: int, captures: []Value, named: Value, repl: string) {
    slen := str_rlen(s)
    m := len(captures)
    write_cap :: proc(sb: ^strings.Builder, c: Value) { if cs, ok := c.(string); ok do strings.write_string(sb, cs) }
    i := 0
    for i < len(repl) {
        if repl[i] != '$' || i + 1 >= len(repl) { strings.write_byte(sb, repl[i]); i += 1; continue }
        next := repl[i + 1]
        switch {
        case next == '$': strings.write_byte(sb, '$'); i += 2
        case next == '&': strings.write_string(sb, matched); i += 2
        case next == '`': strings.write_string(sb, str_rslice(s, 0, position)); i += 2
        case next == '\'':
            tail := min(position + str_rlen(matched), slen)
            strings.write_string(sb, str_rslice(s, tail, slen)); i += 2
        case next >= '0' && next <= '9':
            d1 := int(next - '0')
            if i + 2 < len(repl) && repl[i + 2] >= '0' && repl[i + 2] <= '9' {
                d2 := d1 * 10 + int(repl[i + 2] - '0')
                if d2 >= 1 && d2 <= m { write_cap(sb, captures[d2 - 1]); i += 3; continue }
            }
            if d1 >= 1 && d1 <= m { write_cap(sb, captures[d1 - 1]); i += 2; continue }
            strings.write_byte(sb, '$'); i += 1
        case next == '<' && named != nil:
            close := strings.index_byte(repl[i + 2:], '>')
            if close < 0 { strings.write_string(sb, "$<"); i += 2; continue }
            v := get_member(vm, named, repl[i + 2:][:close])
            if vm.throwing do return
            if v != nil {
                vs := to_js_string(vm, v)
                if vm.throwing do return
                strings.write_string(sb, vs)
            }
            i += 2 + close + 1
        case:
            strings.write_byte(sb, '$'); i += 1
        }
    }
}

@(private = "file")
regex_sym_split :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if !rx_receiver(vm, this, "Symbol.split") do return nil
    s := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    if re := regex_fast_species(vm, this); re != nil {
        limit, lok := split_limit(vm, arg(args, 1))
        if !lok do return nil
        return regex_split_impl(vm, re, s, limit)
    }
    if vm.throwing do return nil
    c := rx_species_ctor(vm, this); if c == nil do return nil
    flags := rx_flags(vm, this); if vm.throwing do return nil
    full := strings.index_byte(flags, 'u') >= 0 || strings.index_byte(flags, 'v') >= 0
    new_flags := flags if strings.index_byte(flags, 'y') >= 0 else strings.concatenate({flags, "y"}, context.temp_allocator)
    splitter := construct_object(vm, c, []Value{this, own_str(vm, new_flags)}); if vm.throwing do return nil
    out := new_array(vm)
    lim, lok := split_limit(vm, arg(args, 1))
    if !lok do return nil
    if lim == 0 do return out
    size := str_rlen(s)
    if size == 0 {
        z := regexp_exec(vm, splitter, s); if vm.throwing do return nil
        if _, null := z.(JS_Null); null do append(&out.items, own_str(vm, s))
        return out
    }
    p, q := 0, 0
    for q < size {
        if !rx_set_last_index(vm, splitter, f64(q)) do return nil
        z := regexp_exec(vm, splitter, s); if vm.throwing do return nil
        if _, null := z.(JS_Null); null { q = js_advance_index(s, q, full); continue }
        e := min(rx_get_last_index(vm, splitter), size); if vm.throwing do return nil
        if e == p { q = js_advance_index(s, q, full); continue }
        append(&out.items, own_str(vm, str_rslice(s, p, q)))
        if len(out.items) == lim do return out
        p = e
        ncap := rx_to_length(vm, get_member(vm, z, "length")) - 1
        if vm.throwing do return nil
        for i in 1 ..= max(ncap, 0) {
            v := get_member(vm, z, fmt.tprintf("%d", i)); if vm.throwing do return nil
            append(&out.items, v)
            if len(out.items) == lim do return out
        }
        q = p
    }
    append(&out.items, own_str(vm, str_rslice(s, p, size)))
    return out
}

@(private = "file")
regex_sym_match_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if !rx_receiver(vm, this, "Symbol.matchAll") do return nil
    s := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    if re := regex_fast_species(vm, this); re != nil do return regex_match_all_impl(vm, re, s)
    if vm.throwing do return nil
    c := rx_species_ctor(vm, this); if c == nil do return nil
    flags := rx_flags(vm, this); if vm.throwing do return nil
    matcher := construct_object(vm, c, []Value{this, own_str(vm, flags)}); if vm.throwing do return nil
    li := rx_get_last_index(vm, this); if vm.throwing do return nil
    if !rx_set_last_index(vm, matcher, f64(li)) do return nil
    // CreateRegExpStringIterator: PREGUIÇOSO — cada next() chama RegExpExec uma vez.
    // O estado mora em chaves `#...` (internas, fora de for-in/Object.keys).
    it := new_object(vm)
    it.proto = regex_string_iter_proto(vm)
    it.props[RX_IT_MATCHER] = matcher
    it.props[RX_IT_STRING]  = own_str(vm, s)
    it.props[RX_IT_GLOBAL]  = strings.index_byte(flags, 'g') >= 0
    it.props[RX_IT_UNICODE] = strings.index_byte(flags, 'u') >= 0 || strings.index_byte(flags, 'v') >= 0
    it.props[RX_IT_DONE]    = false
    return it
}

RX_IT_MATCHER :: "#rx_matcher"
RX_IT_STRING  :: "#rx_string"
RX_IT_GLOBAL  :: "#rx_global"
RX_IT_UNICODE :: "#rx_unicode"
RX_IT_DONE    :: "#rx_done"
RX_IT_PROTO   :: "#rx_string_iterator_proto" // guardado no RegExp.prototype (raiz do GC)

// %RegExpStringIteratorPrototype% (spec 22.2.9.2): next + @@toStringTag, herdando
// de %IteratorPrototype% ([Symbol.iterator] → this). Criado na 1ª vez: o
// install_regex roda ANTES de existir o vm.iter_proto.
@(private = "file")
regex_string_iter_proto :: proc(vm: ^Interp) -> ^Object {
    if p, ok := vm.regex_proto.props[RX_IT_PROTO].(^Object); ok do return p
    p := new_object(vm)
    p.proto = vm.iter_proto
    p.props["next"] = mk_builtin_method(vm, regex_string_iter_next, "next", 0)
    mark_non_enumerable(p, "next")
    if vm.sym_tostring_tag_key != "" {
        p.props[vm.sym_tostring_tag_key] = "RegExp String Iterator"
        if p.attrs == nil do p.attrs = make(map[string]Prop_Attrs)
        p.attrs[vm.sym_tostring_tag_key] = {.Configurable}
    }
    vm.regex_proto.props[RX_IT_PROTO] = p
    return p
}

// {value, done} — o make_iter_result do generator.odin é privado dele.
@(private = "file")
rx_iter_result :: proc(vm: ^Interp, value: Value, done: bool) -> ^Object {
    r := new_object(vm)
    oput(r, "value", value)
    oput(r, "done", done)
    return r
}

// %RegExpStringIteratorPrototype%.next (spec 22.2.9.2.1).
@(private = "file")
regex_string_iter_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    it, ok := this.(^Object)
    matcher: Value
    has := false
    if ok do matcher, has = it.props[RX_IT_MATCHER]
    if !has {
        throw_type_error(vm, "%RegExpStringIterator%.next requires that 'this' be a RegExp String Iterator")
        return nil
    }
    if done, _ := it.props[RX_IT_DONE].(bool); done do return rx_iter_result(vm, nil, true)
    s, _ := it.props[RX_IT_STRING].(string)
    r := regexp_exec(vm, matcher, s); if vm.throwing do return nil
    if _, null := r.(JS_Null); null {
        it.props[RX_IT_DONE] = true
        return rx_iter_result(vm, nil, true)
    }
    if global, _ := it.props[RX_IT_GLOBAL].(bool); global {
        ms := rx_result_str(vm, r, "0"); if vm.throwing do return nil
        if ms == "" {
            full, _ := it.props[RX_IT_UNICODE].(bool)
            if !rx_advance_after_empty(vm, matcher, s, full) do return nil
        }
        return rx_iter_result(vm, r, false)
    }
    it.props[RX_IT_DONE] = true
    return rx_iter_result(vm, r, false)
}

// RegExp.prototype.test (spec 22.2.6.16): RegExpExec(R, S) !== null — logo também
// passa por um `exec` sobrescrito.
regex_test_generic :: proc(vm: ^Interp, this: Value, s: string) -> Value {
    if is_primitive(this) {
        throw_type_error(vm, "RegExp.prototype.test called on a non-object")
        return nil
    }
    r := regexp_exec(vm, this, s)
    if vm.throwing do return nil
    _, null := r.(JS_Null)
    return !null
}

// ── getters do RegExp.prototype (flags, global, …, source) ───────────────────
// Antes não existiam: só a INSTÂNCIA respondia (casos fixos do get_member), então
// `RegExp.prototype.flags` era undefined e um objeto qualquer não tinha como pedir
// emprestado o getter de flags (que a spec escreve em cima de Get(this, "global")…).

// `flags` (spec 22.2.6.4): uma letra por flag cujo getter dê verdadeiro, na ordem
// canônica "dgimsuvy".
@(private = "file")
regex_proto_flags_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_primitive(this) {
        throw_type_error(vm, "RegExp.prototype.flags getter called on non-object")
        return nil
    }
    Flag :: struct { name: string, c: byte }
    sb := strings.builder_make(context.temp_allocator)
    for f in ([]Flag{{"hasIndices", 'd'}, {"global", 'g'}, {"ignoreCase", 'i'}, {"multiline", 'm'},
                     {"dotAll", 's'}, {"unicode", 'u'}, {"unicodeSets", 'v'}, {"sticky", 'y'}}) {
        v := get_member(vm, this, f.name)
        if vm.throwing do return nil
        if truthy(v) do strings.write_byte(&sb, f.c)
    }
    return own_str(vm, strings.to_string(sb))
}

// Os getters de flag individual: a própria regex responde; no RegExp.prototype é
// undefined (caso especial da spec); qualquer outra coisa é TypeError.
@(private = "file")
regex_proto_flag_get :: proc(vm: ^Interp, this: Value, name: string) -> Value {
    if re := regex_of(this); re != nil {
        switch name {
        case "global":      return re.global
        case "ignoreCase":  return re.icase
        case "multiline":   return re.multiline
        case "dotAll":      return re.dotall
        case "sticky":      return re.sticky
        case "unicode":     return re.unicode
        case "unicodeSets": return re.unicode_sets
        case "hasIndices":  return re.has_indices
        }
    }
    if o, ok := this.(^Object); ok && o == vm.regex_proto do return nil
    throw_type_error(vm, fmt.tprintf("RegExp.prototype.%s getter called on non-RegExp", name))
    return nil
}

@(private = "file") rp_global      :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "global") }
@(private = "file") rp_ignore_case :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "ignoreCase") }
@(private = "file") rp_multiline   :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "multiline") }
@(private = "file") rp_dot_all     :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "dotAll") }
@(private = "file") rp_sticky      :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "sticky") }
@(private = "file") rp_unicode     :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "unicode") }
@(private = "file") rp_unicode_sets :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "unicodeSets") }
@(private = "file") rp_has_indices :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return regex_proto_flag_get(vm, this, "hasIndices") }

@(private = "file")
rp_source :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if re := regex_of(this); re != nil do return regex_source_text(vm, re)
    if o, ok := this.(^Object); ok && o == vm.regex_proto do return "(?:)"
    throw_type_error(vm, "RegExp.prototype.source getter called on non-RegExp")
    return nil
}

install_regex_symbol_methods :: proc(vm: ^Interp, proto: ^Object, ctor: ^Function) {
    Entry :: struct { key: string, name: string, n: int, fn: Native_Fn }
    for e in ([]Entry{
        {vm.sym_match_key,     "[Symbol.match]",    1, regex_sym_match},
        {vm.sym_match_all_key, "[Symbol.matchAll]", 1, regex_sym_match_all},
        {vm.sym_search_key,    "[Symbol.search]",   1, regex_sym_search},
        {vm.sym_split_key,     "[Symbol.split]",    2, regex_sym_split},
        {vm.sym_replace_key,   "[Symbol.replace]",  2, regex_sym_replace},
    }) {
        if e.key == "" do continue
        proto.props[e.key] = mk_builtin_method(vm, e.fn, e.name, e.n)
    }
    Getter :: struct { name: string, fn: Native_Fn }
    if proto.getters == nil do proto.getters = make(map[string]^Function)
    if proto.attrs == nil do proto.attrs = make(map[string]Prop_Attrs)
    for g in ([]Getter{
        {"flags", regex_proto_flags_get}, {"global", rp_global}, {"ignoreCase", rp_ignore_case},
        {"multiline", rp_multiline}, {"dotAll", rp_dot_all}, {"sticky", rp_sticky},
        {"unicode", rp_unicode}, {"unicodeSets", rp_unicode_sets}, {"hasIndices", rp_has_indices},
        {"source", rp_source},
    }) {
        proto.getters[g.name] = mk_builtin_method(vm, g.fn, own_str_raw(vm, strings.concatenate({"get ", g.name}, context.temp_allocator)), 0) // nome owned pela VM
        proto.attrs[g.name] = {.Configurable}
    }
    // RegExp[Symbol.species] (spec 22.2.5.2): o @@split/@@matchAll genéricos constroem
    // o splitter/matcher por ele — é o que faz uma subclasse gerar instâncias dela.
    if vm.sym_species_key != "" {
        if ctor.getters == nil do ctor.getters = make(map[string]^Function)
        if ctor.attrs == nil do ctor.attrs = make(map[string]Prop_Attrs)
        ctor.getters[vm.sym_species_key] = mk_builtin_method(vm, array_species_get, "get [Symbol.species]", 0)
        ctor.attrs[vm.sym_species_key] = {.Configurable}
    }
}

// Locale-aware ordering shares the same ICU path as Intl.Collator.
@(private = "file")
str_locale_compare :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "localeCompare requires a non-null receiver"); return nil }
    x := collation_string(vm, this)
    if vm.throwing do return nil
    y := collation_string(vm, arg(args, 0))
    if vm.throwing do return nil
    o := collation_options(vm, arg(args, 1), arg(args, 2))
    if vm.throwing do return nil
    return collation_compare(vm, o, x, y)
}

// normalize() — identidade (sem NFC/NFD; a maioria dos usos só quer "uma forma")
@(private = "file")
str_normalize :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_str(vm, s)
}

// lastIndexOf(sub)
@(private = "file")
str_last_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "String.prototype.lastIndexOf requires a receiver"); return nil }
    s := to_js_string(vm, this); if vm.throwing do return nil
    sub := to_js_string(vm, arg(args, 0)); if vm.throwing do return nil
    pos := to_number(vm, arg(args, 1)); if vm.throwing do return nil
    n := str_rlen(s)
    start := n if pos != pos else clamp_index(pos,n)
    return f64(js_string_find(s, sub, start, true))
}

// trimStart / trimEnd
@(private = "file")
str_trim_start :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_str(vm, strings.trim_left_space(s))
}

@(private = "file")
str_trim_end :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    return own_str(vm, strings.trim_right_space(s))
}

// at(index) — negativo conta do fim
@(private = "file")
str_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return nil
    i := as_int(arg(args, 0)) // NaN/ausente → 0
    n := str_rlen(s)
    if i < 0 do i += n
    if i < 0 || i >= n do return nil
    return own_str(vm, str_rune_at(s, i))
}

// Array.from
@(private = "file")
arr_from :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    src := arg(args, 0)
    mapper, mapped := arg(args, 1).(^Function)
    if arg(args, 1) != nil && !mapped { throw_type_error(vm, "Mapper is not a function"); return nil }
    if is_nullish(src) { throw_type_error(vm, "Array.from called on null or undefined"); return nil }
    out := new_array(vm)
    method := get_member(vm, src, vm.sym_iterator_key)
    if vm.throwing do return nil
    if !is_nullish(method) {
        fn, ok := method.(^Function)
        if !ok { throw_type_error(vm, "Iterator method is not callable"); return nil }
        iter := call_function(vm, fn, src, nil)
        if vm.throwing do return nil
        next := iterator_next_fn(iter)
        if next == nil { throw_type_error(vm, "Invalid iterator"); return nil }
        for i := 0; ; i += 1 {
            if step_guard(vm) do return nil
            result := call_function(vm, next, iter, nil)
            if vm.throwing do return nil
            if _, ok := result.(^Object); !ok { throw_type_error(vm, "Invalid iterator result"); return nil }
            done := get_member(vm, result, "done")
            if vm.throwing do return nil
            if truthy(done) do return out
            v := get_member(vm, result, "value")
            if vm.throwing do return nil
            if mapped {
                v = call_function(vm, mapper, arg(args, 2), []Value{v, f64(i)})
                if vm.throwing {
                    exception := vm.thrown
                    vm.throwing = false
                    iterator_close(vm, iter)
                    vm.throwing = true; vm.thrown = exception
                    return nil
                }
            }
            append(&out.items, v)
        }
    }
    n := array_like_len(vm, src)
    if vm.throwing do return nil
    for i := 0; i < n; i += 1 {
        v := array_like_get(vm, src, i)
        if vm.throwing do return nil
        if mapped do v = call_function(vm, mapper, arg(args, 2), []Value{v, f64(i)})
        if vm.throwing do return nil
        append(&out.items, v)
    }
    return out
}

// ── Array moderno (M59) ─────────────────────────────────────────────────────

@(private = "file")
arr_flatten_into :: proc(vm: ^Interp, src: Value, depth: int, out: Value, target: ^int) {
    n := array_like_len(vm, src)
    if vm.throwing do return
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,src, i) do continue
        it := array_like_get(vm, src, i)
        if vm.throwing do return
        if sub := it; array_is_array(sub) && depth > 0 {
            if vm.call_depth >= vm.call_depth_limit { vm.thrown = mk_error(vm, "RangeError", "Flatten recursion exceeded"); vm.throwing = true; return }
            vm.call_depth += 1
            arr_flatten_into(vm, sub, depth - 1, out, target)
            vm.call_depth -= 1
            if vm.throwing do return
        } else { array_result_set(vm, out, target^, it); if vm.throwing do return; target^ += 1 }
    }
}

@(private = "file")
arr_flat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    depth := 1
    if arg(args, 0) != nil do depth = arr_integer(vm, args[0])
    if vm.throwing do return nil
    out := array_species_create(vm, this, 0)
    if vm.throwing do return nil
    target := 0
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        if sub := it; array_is_array(sub) && depth > 0 { arr_flatten_into(vm, sub, depth - 1, out, &target) } else { array_result_set(vm, out, target, it); target += 1 }
        if vm.throwing do return nil
    }
    return out
}

@(private = "file")
arr_flat_map :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    fn, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "Callback is not a function"); return nil }
    out := array_species_create(vm, this, 0)
    if vm.throwing do return nil
    target := 0
    for i := 0; i < n; i += 1 {
        if !array_like_has(vm,this, i) do continue
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, fn, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if sub := r; array_is_array(sub) { arr_flatten_into(vm, sub, 0, out, &target) } else { array_result_set(vm, out, target, r); target += 1 }
        if vm.throwing do return nil
    }
    return out
}

@(private = "file")
arr_fill :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    start := idx_from(to_number(vm, arg(args, 1)), n)
    if vm.throwing do return nil
    end := n
    if arg(args, 2) != nil do end = idx_from(to_number(vm, args[2]), n)
    if vm.throwing do return nil
    for i := start; i < end; i += 1 { arr_set(vm, this, i, arg(args, 0)); if vm.throwing do return nil }
    return this
}

@(private = "file")
arr_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    index := arr_integer(vm, arg(args, 0))
    if vm.throwing do return nil
    if index < 0 do index += n
    if index < 0 || index >= n do return nil
    return array_like_get(vm, this, index)
}

@(private = "file")
arr_find_last :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := n - 1; i >= 0; i -= 1 {
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(r) do return it
    }
    return nil
}

@(private = "file")
arr_find_last_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array method called on null or undefined"); return nil }
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    cb, ok := arg(args, 0).(^Function)
    if !ok { throw_type_error(vm, "callback is not a function"); return nil }
    for i := n - 1; i >= 0; i -= 1 {
        it := array_like_get(vm, this, i)
        if vm.throwing do return nil
        r := call_function(vm, cb, arg(args, 1), []Value{it, f64(i), this})
        if vm.throwing do return nil
        if truthy(r) do return f64(i)
    }
    return f64(-1)
}

@(private = "file")
arr_copy_within :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    dst := idx_from(to_number(vm, arg(args, 0)), n)
    if vm.throwing do return nil
    src := idx_from(to_number(vm, arg(args, 1)), n)
    if vm.throwing do return nil
    end := n
    if arg(args, 2) != nil do end = idx_from(to_number(vm, args[2]), n)
    if vm.throwing do return nil
    count := min(end - src, n - dst)
    step := 1
    if src < dst && dst < src + count { src += count - 1; dst += count - 1; step = -1 }
    for count > 0 {
        arr_move(vm, this, src, dst)
        if vm.throwing do return nil
        src += step; dst += step; count -= 1
    }
    return this
}

// Array iterators read their receiver lazily at each next().
@(private = "file")
arr_keys_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return arr_live_iterator(vm, this, 0)
}

// `values` é também o Symbol.iterator de Array.prototype (ver install), e é ele que
// a coleção viva do DOM empresta: sem o caminho array-like, `[...el.children]` e
// `for (x of el.children)` iteravam ZERO elemento sem lançar nada.
@(private = "file")
arr_values_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return arr_live_iterator(vm, this, 1)
}

@(private = "file")
arr_entries_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return arr_live_iterator(vm, this, 2)
}

// length de `this` para os três iteradores acima (array real ou array-like).
@(private = "file")
arr_iter_len :: proc(vm: ^Interp, this: Value) -> int {
    if a, ok := this.(^Array); ok do return len(a.items)
    return array_like_len(vm, this)
}

// String.prototype[Symbol.iterator]: itera por CODE POINT (como o spread de string
// em eval_args). core-js/libs chamam `str[Symbol.iterator]()` explicitamente.
@(private = "file")
str_values_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    if s, ok := this.(string); ok {
        starts: [dynamic]int
        defer delete(starts)
        js_code_point_offsets(s, &starts)
        for k := 0; k + 1 < len(starts); k += 1 {
            append(&arr.items, own_str(vm, s[starts[k]:starts[k + 1]]))
        }
    }
    return make_array_iterator(vm, arr)
}

@(private = "file")
arr_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := new_array(vm)
    for v in args do append(&a.items, v)
    return a
}

// Array.isArray
@(private = "file")
arr_is_array :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if a, ok := arg(args, 0).(^Array); ok {
        // `arguments` é um ^Array por dentro (para os métodos de Array funcionarem
        // via .call), mas NÃO é um Array para o JS. Libs fazem
        // `Array.isArray(x) ? x : slice.call(x)` — dizer true aqui manda o
        // `arguments` pelo ramo errado.
        return !a.is_arguments
    }
    // instância de `class X extends Array` (M136): é um ^Object com o array no slot
    // interno, e a spec manda IsArray seguir o slot.
    if o, ok := arg(args, 0).(^Object); ok && o.prim != nil {
        if _, isarr := o.prim.(^Array); isarr do return true
    }
    return false
}

// Construtor Array(): `Array(n)` (n number) → array de n slots (undefined);
// `Array(a,b,...)` → array com esses elementos. É DIFERENTE de Array.from.
// React.createElement usa `Array(childrenLength)` p/ >1 filho — sem isto,
// elementos com múltiplos filhos perdem os filhos.
@(private = "file")
arr_construct :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := new_array(vm)
    if len(args) == 1 {
        if n, ok := args[0].(f64); ok {
            // comprimento inválido (NaN/negativo/não-inteiro/>2^32-1): JS lança
            // RangeError. Aqui: array vazio (evita alocar bilhões de slots — o
            // int(NaN) virava lixo gigante e travava o processo num for nativo).
            if n != n || n < 0 || n != math.trunc(n) || n > 4294967295 {
                vm.thrown = mk_error(vm, "RangeError", "Invalid array length"); vm.throwing = true; return nil
            }
            count := int(n)
            arr_mark_holes(a, 0, count) // `new Array(3)`: length 3, NENHUM índice presente
            for i := 0; i < count; i += 1 do append(&a.items, nil)
            return a
        }
    }
    for v in args do append(&a.items, v)
    return a
}

// isFinite
@(private = "file")
global_is_finite :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := as_number(arg(args, 0))
    return n == n && n != math.inf_f64(1) && n != math.inf_f64(-1)
}

// Number(x), String(x)
@(private = "file")
global_number_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    is_new := vm.native_new
    n: f64 = 0 // Number() sem argumento é 0, não NaN
    if len(args) > 0 {
        n = to_number(vm, args[0]) // ToNumber da spec: Number(new Date) = timestamp
        if vm.throwing do return nil
    }
    if is_new do return make_wrapper(vm, n) // new Number(5): objeto, typeof "object"
    return n
}

// Boolean(x): ToBoolean. Estava FALTANDO como global (`typeof Boolean` == undefined),
// o que quebrava o idioma onipresente `arr.filter(Boolean)` p/ remover falsy —
// 7 sites no gap-report caíam em "Boolean is not a function".
global_boolean_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    b := truthy(arg(args, 0))
    // new Boolean(false) é um OBJETO — e portanto truthy (`if (new Boolean(false))` entra)
    if vm.native_new do return make_wrapper(vm, b)
    return b
}

// Boolean.prototype.toString / .valueOf: thisBooleanValue (spec) — o booleano, ou o
// de dentro do wrapper (que unwrap_prim já entrega como `this: bool`); qualquer
// outra coisa é TypeError. Antes devolvia truthy(this), então
// `Boolean.prototype.valueOf.call({})` dava true em vez de lançar.
@(private = "file")
boolean_this :: proc(vm: ^Interp, this: Value) -> (bool, bool) {
    if b, ok := this.(bool); ok do return b, true
    if p, ok := wrapper_value(this); ok {
        if b, bok := p.(bool); bok do return b, true
    }
    throw_type_error(vm, "Boolean.prototype method called on incompatible receiver")
    return false, false
}

@(private = "file")
boolean_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    b, ok := boolean_this(vm, this)
    if !ok do return nil
    return b ? "true" : "false"
}

@(private = "file")
boolean_value_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    b, ok := boolean_this(vm, this)
    if !ok do return nil
    return b
}

// String.raw(strings, ...vals): tag que intercala os chunks com os valores.
// APROXIMAÇÃO: nossos chunks já vêm com escapes decodificados (cooked==raw) —
// `String.raw`+"`a\nb`" devolve a quebra real, não "\n" literal.
@(private = "file")
string_raw :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    strs, ok := arg(args, 0).(^Array)
    if !ok do return own_str(vm, "")
    // A spec lê `strings.raw`, não `strings`: é isso que faz String.raw`a\nb`
    // devolver a barra e o `n` literais. Só cai no array cozido se `raw` não vier
    // (chamada manual como `String.raw({raw:[...]})` já entra aqui pelo caminho certo).
    parts := strs
    if strs.props != nil {
        if r, rok := strs.props["raw"].(^Array); rok do parts = r
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for it, i in parts.items {
        to_text(&sb, it)
        if i + 1 < len(args) do to_text(&sb, args[i + 1])
    }
    return own_str(vm, strings.to_string(sb))
}

// String.fromCharCode(...units): recebe CODE UNITS UTF-16, então um par surrogate
// adjacente tem de ser RECOMBINADO no code point — `fromCharCode(0xD83D, 0xDE00)`
// é o emoji, não dois caracteres de lixo.
@(private = "file")
string_from_char_code :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i < len(args); i += 1 {
        u := u32(as_int(args[i])) & 0xFFFF
        if u >= 0xD800 && u <= 0xDBFF && i + 1 < len(args) { // high seguido de low?
            lo := u32(as_int(args[i + 1])) & 0xFFFF
            if lo >= 0xDC00 && lo <= 0xDFFF {
                strings.write_rune(&sb, rune(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)))
                i += 1
                continue
            }
        }
        write_js_rune(&sb, rune(u))
    }
    return own_str(vm, strings.to_string(sb))
}

// String.fromCodePoint(...points): cada argumento JÁ é um code point, então
// escreve direto — sem a recombinação de par que o fromCharCode faz.
@(private = "file")
string_from_code_point :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for a in args do write_js_rune(&sb, rune(as_int(a)))
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
global_string_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    is_new := vm.native_new
    s: Value
    if len(args) == 0 {
        s = own_str(vm, "") // String() sem argumento é "", não "undefined"
    } else {
        v := args[0]
        if v == nil {
            s = own_str(vm, "undefined")
        } else if _, isNull := v.(JS_Null); isNull {
            s = own_str(vm, "null")
        } else {
            sb: strings.Builder
            strings.builder_init(&sb); defer strings.builder_destroy(&sb)
            write_text_spec(&sb, vm, v) // String([1,2]) === "1,2", não o texto de debug
            if vm.throwing do return nil
            s = own_str(vm, strings.to_string(sb))
        }
    }
    if is_new do return make_wrapper(vm, s) // new String("a"): objeto, typeof "object"
    return s
}

// (Date virou objeto completo em date.odin — M59)

// ── métodos de Number (this = f64; despachados por get_member case f64) ─────

// toFixed / toExponential / toPrecision: numfmt.odin (decimal exato, empate p/ cima)

@(private = "file")
num_to_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this.(f64); if !ok do return own_str(vm, "NaN")
    radix := 10
    if len(a) >= 1 && a[0] != nil do radix = as_int(a[0])
    if radix == 10 || radix < 2 || radix > 36 {
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, x) // mesma formatação do resto do motor
        return own_str(vm, strings.to_string(sb))
    }
    if x != x do return own_str(vm, "NaN")
    digits_tbl := "0123456789abcdefghijklmnopqrstuvwxyz"
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    v := x
    if v < 0 { strings.write_byte(&sb, '-'); v = -v }
    ip := math.trunc(v)
    frac := v - ip
    // parte inteira (dígitos em ordem reversa num buffer local)
    buf: [72]u8
    bi := 0
    if ip == 0 { buf[0] = '0'; bi = 1 }
    for ip >= 1 && bi < len(buf) {
        d := int(math.mod(ip, f64(radix)))
        buf[bi] = digits_tbl[d]
        bi += 1
        ip = math.trunc(ip / f64(radix))
    }
    for k := bi - 1; k >= 0; k -= 1 do strings.write_byte(&sb, buf[k])
    // fração: até 20 dígitos, sem zeros à direita
    if frac > 0 {
        fb: [24]u8
        fn := 0
        f := frac
        for k := 0; k < 20 && f > 0; k += 1 {
            f *= f64(radix)
            d := int(math.trunc(f))
            if d > radix - 1 do d = radix - 1
            fb[fn] = digits_tbl[d]
            fn += 1
            f -= math.trunc(f)
        }
        for fn > 0 && fb[fn - 1] == '0' do fn -= 1
        if fn > 0 {
            strings.write_byte(&sb, '.')
            for k := 0; k < fn; k += 1 do strings.write_byte(&sb, fb[k])
        }
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
num_value_of :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this.(f64)
    return ok ? Value(x) : Value(math.nan_f64())
}

@(private = "file") num_is_integer :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := arg(a, 0).(f64)
    return ok && x == x && math.trunc(x) == x && x != math.inf_f64(1) && x != math.inf_f64(-1)
}
@(private = "file") num_is_finite :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := arg(a, 0).(f64) // Number.isFinite NÃO converte (diferente do global)
    return ok && x == x && x != math.inf_f64(1) && x != math.inf_f64(-1)
}
@(private = "file") num_is_nan :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := arg(a, 0).(f64)
    return ok && x != x
}
@(private = "file") num_is_safe_integer :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := arg(a, 0).(f64)
    return ok && x == x && math.trunc(x) == x && math.abs(x) <= 9007199254740991
}

// queueMicrotask compartilha a FIFO das reações de Promise.
@(private = "file")
global_queue_microtask :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    cb, ok := arg(a, 0).(^Function)
    if !ok {
        throw_type_error(vm, "queueMicrotask: callback must be callable")
        return nil
    }
    append(&vm.reaction_queue, Reaction_Job{microtask = cb})
    return nil
}

// reportError(e) (HTML §8.1.4.6): relata `e` como exceção NÃO capturada, sem
// lançar. O React 19 (github.com) o usa para erros de render/hidratação; sem
// ele o `ReferenceError: reportError is not defined` ESCONDIA o erro real.
// Mesmo destino de uma exceção não capturada do motor (log + uncaught_log);
// o motor ainda não dispara `error`/ErrorEvent no window para nenhuma das duas.
global_report_error :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if len(a) == 0 {
        throw_type_error(vm, "reportError: 1 argument required, but only 0 present")
        return nil
    }
    prev_throwing, prev_thrown := vm.throwing, vm.thrown
    vm.throwing = true
    vm.thrown = a[0]
    vm_clear_uncaught(vm)
    vm.throwing, vm.thrown = prev_throwing, prev_thrown
    return nil
}

// ── percent-encoding (M61) — opera nos BYTES UTF-8, como manda a spec ────────

// unreserved de encodeURIComponent: A-Z a-z 0-9 - _ . ! ~ * ' ( )
@(private = "file")
is_uri_unreserved :: proc(c: u8) -> bool {
    switch {
    case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
        return true
    case c == '-' || c == '_' || c == '.' || c == '!' || c == '~' || c == '*' || c == '\'' || c == '(' || c == ')':
        return true
    }
    return false
}

// reservados que encodeURI PRESERVA (além dos unreserved): ; , / ? : @ & = + $ #
@(private = "file")
is_uri_reserved :: proc(c: u8) -> bool {
    switch c {
    case ';', ',', '/', '?', ':', '@', '&', '=', '+', '$', '#':
        return true
    }
    return false
}

@(private = "file")
percent_encode :: proc(vm: ^Interp, s: string, keep_reserved: bool) -> Value {
    hex := "0123456789ABCDEF"
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if is_uri_unreserved(c) || (keep_reserved && is_uri_reserved(c)) {
            strings.write_byte(&sb, c)
        } else {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, hex[c >> 4])
            strings.write_byte(&sb, hex[c & 0xF])
        }
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
hex_val :: proc(c: u8) -> int {
    switch {
    case c >= '0' && c <= '9': return int(c - '0')
    case c >= 'a' && c <= 'f': return int(c - 'a') + 10
    case c >= 'A' && c <= 'F': return int(c - 'A') + 10
    }
    return -1
}

// decode: %XX → byte. `keep_reserved` (decodeURI): %XX de um RESERVADO fica
// como estava (spec). %-sequência malformada → URIError.
@(private = "file")
percent_decode :: proc(vm: ^Interp, s: string, keep_reserved: bool) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i < len(s); {
        c := s[i]
        if c != '%' {
            strings.write_byte(&sb, c)
            i += 1
            continue
        }
        if i + 2 >= len(s) {
            vm.thrown = mk_error(vm, "URIError", "URI malformada")
            vm.throwing = true
            return nil
        }
        hi := hex_val(s[i + 1]); lo := hex_val(s[i + 2])
        if hi < 0 || lo < 0 {
            vm.thrown = mk_error(vm, "URIError", "URI malformada")
            vm.throwing = true
            return nil
        }
        b := u8(hi << 4 | lo)
        if keep_reserved && is_uri_reserved(b) {
            strings.write_byte(&sb, '%')
            strings.write_byte(&sb, s[i + 1])
            strings.write_byte(&sb, s[i + 2])
        } else {
            strings.write_byte(&sb, b)
        }
        i += 3
    }
    return own_str(vm, strings.to_string(sb))
}

@(private) // visivel no pacote: fetch_api.odin (URLSearchParams) reusa
global_encode_uri_component :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    return percent_encode(vm, s, false)
}

@(private) // visivel no pacote: fetch_api.odin (URLSearchParams) reusa
global_decode_uri_component :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    return percent_decode(vm, s, false)
}

@(private = "file")
global_encode_uri_full :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    return percent_encode(vm, s, true)
}

@(private = "file")
global_decode_uri_full :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    return percent_decode(vm, s, true)
}

// ── base64 (btoa/atob) — semântica Latin-1 do browser ───────────────────────

@(private = "file")
B64_TBL := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// btoa(s): cada CHAR (rune) vira um byte; rune > 0xFF → InvalidCharacterError
@(private = "file")
global_btoa :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    bytes: [dynamic]u8
    defer delete(bytes)
    for r in s {
        if r > 0xFF {
            vm.thrown = mk_error(vm, "InvalidCharacterError", "btoa: caractere fora de Latin-1")
            vm.throwing = true
            return nil
        }
        append(&bytes, u8(r))
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    n := len(bytes)
    for i := 0; i < n; i += 3 {
        b0 := int(bytes[i])
        b1 := i + 1 < n ? int(bytes[i + 1]) : 0
        b2 := i + 2 < n ? int(bytes[i + 2]) : 0
        strings.write_byte(&sb, B64_TBL[b0 >> 2])
        strings.write_byte(&sb, B64_TBL[(b0 & 3) << 4 | b1 >> 4])
        strings.write_byte(&sb, i + 1 < n ? B64_TBL[(b1 & 15) << 2 | b2 >> 6] : '=')
        strings.write_byte(&sb, i + 2 < n ? B64_TBL[b2 & 63] : '=')
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
b64_val :: proc(c: u8) -> int {
    switch {
    case c >= 'A' && c <= 'Z': return int(c - 'A')
    case c >= 'a' && c <= 'z': return int(c - 'a') + 26
    case c >= '0' && c <= '9': return int(c - '0') + 52
    case c == '+': return 62
    case c == '/': return 63
    }
    return -1
}

// atob(b64): bytes decodificados viram runes (Latin-1 → UTF-8 interno).
// Whitespace é tolerado (como nos browsers); char inválido/tamanho errado lança.
@(private = "file")
global_atob :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := arg(args, 0).(string); if !ok do return own_str(vm, "")
    vals: [dynamic]int
    defer delete(vals)
    pad := 0
    bad := false
    loop: for i := 0; i < len(s); i += 1 {
        c := s[i]
        switch {
        case c == ' ' || c == '\t' || c == '\n' || c == '\r':
            continue
        case c == '=':
            pad += 1
        case pad > 0: // dado depois do '='
            bad = true
            break loop
        case:
            v := b64_val(c)
            if v < 0 { bad = true; break loop }
            append(&vals, v)
        }
    }
    rem := (len(vals) + pad) % 4
    if bad || pad > 2 || (rem != 0 && !(pad == 0 && len(vals) % 4 >= 2)) {
        vm.thrown = mk_error(vm, "InvalidCharacterError", "atob: base64 inválido")
        vm.throwing = true
        return nil
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i + 1 < len(vals); i += 4 {
        b0 := vals[i] << 2 | vals[i + 1] >> 4
        strings.write_rune(&sb, rune(b0))
        if i + 2 < len(vals) {
            b1 := (vals[i + 1] & 15) << 4 | vals[i + 2] >> 2
            strings.write_rune(&sb, rune(b1))
        }
        if i + 3 < len(vals) {
            b2 := (vals[i + 2] & 3) << 6 | vals[i + 3]
            strings.write_rune(&sb, rune(b2))
        }
    }
    return own_str(vm, strings.to_string(sb))
}

// ── Math e funções globais ──────────────────────────────────────────────────

@(private = "file") math_floor  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.floor(as_number(arg(a, 0))) }
@(private = "file") math_ceil   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.ceil(as_number(arg(a, 0))) }
// JS arredonda meio-caminho para CIMA (+inf): round(-2.5) = -2 (math.round
// arredonda para longe do zero, daria -3).
// Math.round: arredonda para +∞ no empate. Dois desvios da versão `floor(x+0.5)`:
// (1) em [-0.5, 0) o resultado é -0, não +0 (`1/Math.round(-0.5)` é -Infinity);
// (2) `x+0.5` arredonda em f64 — 0.49999999999999994+0.5 dá 1, e o certo é 0.
@(private = "file") math_round  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0)) // ToNumber com valueOf
    if vm.throwing do return nil
    if x != x || math.trunc(x) == x do return x // NaN/inteiro/±inf/±0: intactos
    if x < 0 && x >= -0.5 do return math.copy_sign(f64(0), -1)
    r := math.floor(x)
    if x - r >= 0.5 do r += 1
    return r
}
@(private = "file") math_trunc  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.trunc(as_number(arg(a, 0))) }
@(private = "file") math_abs_   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return abs(as_number(arg(a, 0))) }
@(private = "file") math_sqrt   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.sqrt(as_number(arg(a, 0))) }
@(private = "file") math_pow    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.pow(as_number(arg(a, 0)), as_number(arg(a, 1))) }
@(private = "file") math_random :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return rand.float64() }
@(private = "file") math_log    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.ln(as_number(arg(a, 0))) }
@(private = "file") math_log2   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.log2(as_number(arg(a, 0))) }
@(private = "file") math_log10  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.log10(as_number(arg(a, 0))) }
@(private = "file") math_exp    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.exp(as_number(arg(a, 0))) }
@(private = "file") math_cbrt   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { n := as_number(arg(a, 0)); return math.pow(n, 1.0/3.0) if n >= 0 else -math.pow(-n, 1.0/3.0) }
@(private = "file") math_sin    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.sin(as_number(arg(a, 0))) }
@(private = "file") math_cos    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.cos(as_number(arg(a, 0))) }
@(private = "file") math_tan    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.tan(as_number(arg(a, 0))) }
@(private = "file") math_asin   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.asin(as_number(arg(a, 0))) }
@(private = "file") math_acos   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.acos(as_number(arg(a, 0))) }
@(private = "file") math_atan   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.atan(as_number(arg(a, 0))) }
@(private = "file") math_atan2  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return math.atan2(as_number(arg(a, 0)), as_number(arg(a, 1))) }

// exp(x)-1 perde os digitos significativos perto de zero. A serie neste
// intervalo converge antes de 18 termos, sem subtrair numeros quase iguais.
@(private = "file")
math_expm1_number :: proc(x: f64) -> f64 {
    if x == 0 do return x // preserva -0
    if abs(x) >= 0.5 || math.is_nan(x) do return math.exp(x) - 1
    term, sum := x, x
    for n := 2; n <= 18; n += 1 {
        term *= x / f64(n)
        sum += term
    }
    return sum
}

@(private = "file")
math_expm1 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math_expm1_number(x)
}

@(private = "file")
math_log1p :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math.log1p(x)
}

@(private = "file")
math_cosh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    // exp(x) pode transbordar antes de cosh(x); exp(x/2) ainda cabe.
    e := math.exp(abs(x) * 0.5)
    return (0.5 * e) * e + (0.5 / e) / e
}

@(private = "file")
math_sinh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    if x == 0 do return x
    z := abs(x)
    if z < 1 {
        t := math_expm1_number(z)
        return math.copy_sign(0.5 * (t + t / (t + 1)), x)
    }
    e := math.exp(z * 0.5)
    return math.copy_sign((0.5 * e) * e - (0.5 / e) / e, x)
}

@(private = "file")
math_tanh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math.tanh(x)
}

@(private = "file")
math_acosh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math.acosh(x)
}

@(private = "file")
math_asinh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math.asinh(x)
}

@(private = "file")
math_atanh :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return math.atanh(x)
}

@(private = "file")
math_fround :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return f64(f32(x)) // IEEE 754 binary32, empate para o par
}

// Math.clz32(x): número de zeros à esquerda em ToUint32(x) (0 → 32). CRÍTICO:
// o scheduler do React usa isto p/ escolher a "lane" de prioridade — sem ele o
// laço de lanes nunca converge (loop infinito).
@(private = "file")
math_clz32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := to_uint32(arg(a, 0))
    if x == 0 do return f64(32)
    n := 0
    for bit := u32(0x8000_0000); bit != 0 && (x & bit) == 0; bit >>= 1 do n += 1
    return f64(n)
}

// Math.imul(a, b): multiplicação inteira de 32 bits (resultado como int32).
@(private = "file")
math_imul :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return f64(to_int32(arg(a, 0)) * to_int32(arg(a, 1)))
}

// Math.hypot(...): sqrt(soma dos quadrados).
@(private = "file")
math_hypot :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    sum := 0.0
    for v in a { n := as_number(v); sum += n * n }
    return math.sqrt(sum)
}

@(private = "file")
math_sign :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    n := as_number(arg(a, 0))
    return f64(0) if n == 0 else (f64(1) if n > 0 else f64(-1))
}

@(private = "file")
math_min :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    m := math.inf_f64(1)
    has_nan := false
    for i := 0; i < len(a); i += 1 {
        v := to_number(vm, a[i]) // a spec coage TODOS os args (valueOf) ANTES de checar NaN
        if vm.throwing do return nil
        if v != v { has_nan = true; continue } // não retorna já: coage o resto primeiro
        // -0 é "menor" que +0 (spec): troca também quando v==m==0 e v é -0
        if v < m || (v == 0 && m == 0 && math.sign_bit(v)) do m = v
    }
    if has_nan do return math.nan_f64()
    return m
}

@(private = "file")
math_max :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    m := math.inf_f64(-1)
    has_nan := false
    for i := 0; i < len(a); i += 1 {
        v := to_number(vm, a[i]) // a spec coage TODOS os args (valueOf) ANTES de checar NaN
        if vm.throwing do return nil
        if v != v { has_nan = true; continue } // não retorna já: coage o resto primeiro
        // +0 é "maior" que -0 (spec): troca também quando v==m==0 e v é +0
        if v > m || (v == 0 && m == 0 && !math.sign_bit(v)) do m = v
    }
    if has_nan do return math.nan_f64()
    return m
}

@(private = "file")
is_js_space :: proc(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'
}

// Lê o número decimal no início de `s` (estilo parseFloat): sinal, inteiro,
// fração e expoente e/E±dígitos (só consumido se houver dígito depois).
@(private = "file")
leading_number :: proc(s: string, allow_dot: bool) -> (f64, bool) {
    i := 0
    for i < len(s) && is_js_space(s[i]) do i += 1
    start := i
    if i < len(s) && (s[i] == '+' || s[i] == '-') do i += 1
    digs := i
    for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
    if allow_dot && i < len(s) && s[i] == '.' {
        i += 1
        for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
    }
    if i == digs do return 0, false // nenhum dígito
    if allow_dot && i < len(s) && (s[i] == 'e' || s[i] == 'E') {
        j := i + 1
        if j < len(s) && (s[j] == '+' || s[j] == '-') do j += 1
        k := j
        for k < len(s) && s[k] >= '0' && s[k] <= '9' do k += 1
        if k > j do i = k // "1e3" consome; "1e" fica como 1
    }
    return strconv.parse_f64(s[start:i])
}

@(private = "file")
digit_val :: proc(c: u8) -> int {
    switch {
    case c >= '0' && c <= '9': return int(c - '0')
    case c >= 'a' && c <= 'z': return int(c - 'a') + 10
    case c >= 'A' && c <= 'Z': return int(c - 'A') + 10
    }
    return -1
}

// parseInt spec-correto: whitespace, sinal, radix 2-36 (ausente/0 → 10, com
// prefixo 0x/0X → 16), consome dígitos válidos no radix até o 1º inválido.
@(private = "file")
global_parse_int :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    s, sok := arg(a, 0).(string)
    if !sok do return math.trunc(as_number(arg(a, 0)))
    i := 0
    for i < len(s) && is_js_space(s[i]) do i += 1
    neg := false
    if i < len(s) && (s[i] == '+' || s[i] == '-') { neg = s[i] == '-'; i += 1 }
    radix := as_int(arg(a, 1))
    if radix == 0 {
        radix = 10
        if i + 1 < len(s) && s[i] == '0' && (s[i+1] == 'x' || s[i+1] == 'X') { radix = 16; i += 2 }
    } else if radix < 2 || radix > 36 {
        return math.nan_f64()
    } else if radix == 16 {
        if i + 1 < len(s) && s[i] == '0' && (s[i+1] == 'x' || s[i+1] == 'X') do i += 2
    }
    first := i
    v: f64 = 0
    for i < len(s) {
        d := digit_val(s[i])
        if d < 0 || d >= radix do break
        v = v * f64(radix) + f64(d)
        i += 1
    }
    if i == first do return math.nan_f64() // nenhum dígito válido
    return neg ? -v : v
}

@(private = "file")
global_parse_float :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if s, ok := arg(a, 0).(string); ok {
        i := 0
        for i < len(s) && is_js_space(s[i]) do i += 1
        j := i
        if j < len(s) && (s[j] == '+' || s[j] == '-') do j += 1
        if strings.has_prefix(s[j:], "Infinity") {
            return math.inf_f64(s[i] == '-' ? -1 : 1)
        }
        if v, vok := leading_number(s[i:], true); vok do return v
        return math.nan_f64()
    }
    return as_number(arg(a, 0))
}

@(private = "file")
global_is_nan :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    n := as_number(arg(a, 0))
    return n != n // NaN é o único valor diferente de si mesmo
}

// ── erros (Error, TypeError, ...) ───────────────────────────────────────────
// Erros de verdade (M60): cada tipo tem um prototype (vm.error_protos) cujo
// proto é o Error.prototype base → `e instanceof TypeError` E `e instanceof
// Error` funcionam (js_instanceof anda a cadeia vs ctor.props["prototype"]).
// Instâncias têm name/message/stack próprios. Funciona com e sem `new`.

@(private = "file")
make_error_obj :: proc(vm: ^Interp, name: string, args: []Value) -> Value {
    o := new_object(vm)
    o.props["name"] = name
    msg: Value = ""
    if len(args) >= 1 do msg = args[0]
    o.props["message"] = msg
    // `new Error(msg, {cause})` — ES2022. Bibliotecas encadeiam erro de origem aqui.
    if opts, ook := arg(args, 1).(^Object); ook {
        if c, cok := opts.props["cause"]; cok do o.props["cause"] = c
    }
    if proto, ok := vm.error_protos[name]; ok do o.proto = proto
    ms, _ := msg.(string)
    if st, ok := stack_for_error(vm, name, ms); ok {
        o.props["stack"] = st // com frames; NÃO enumerável (V8): fora de keys/JSON.stringify
        mark_non_enumerable(o, "stack")
    }
    return o
}

@(private = "file") native_error        :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "Error", a) }
@(private = "file") native_type_error   :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "TypeError", a) }
@(private = "file") native_range_error  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "RangeError", a) }
@(private = "file") native_syntax_error :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "SyntaxError", a) }
@(private = "file") native_reference_error :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "ReferenceError", a) }
@(private = "file") native_uri_error       :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "URIError", a) }
@(private = "file") native_eval_error      :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_error_obj(vm, "EvalError", a) }

// `new AggregateError(errors, message)` — assinatura DIFERENTE das demais: o 1º
// argumento é a lista de erros e a mensagem é o 2º. Por isso não dá p/ reusar
// make_error_obj direto (ele leria a lista como `message`).
@(private = "file")
native_aggregate_error :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := make_error_obj(vm, "AggregateError", len(a) >= 2 ? a[1:] : nil).(^Object)
    errs := new_array(vm)
    if src, ok := arg(a, 0).(^Array); ok {
        for v in src.items do append(&errs.items, v)
    } else if v := arg(a, 0); v != nil {
        append(&errs.items, v) // não-iterável: trata como um erro só (degradação)
    }
    o.props["errors"] = errs
    return o
}

// Error.prototype.toString: "Name: mensagem" ("Name" se a mensagem for vazia)
@(private = "file")
err_to_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok do return own_str(vm, "Error")
    name := "Error"
    if n, nok := get_member(vm, o, "name").(string); nok do name = n
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, name)
    if msg := get_member(vm, o, "message"); msg != nil {
        if ms, mok := msg.(string); !mok || ms != "" {
            strings.write_string(&sb, ": ")
            to_text(&sb, msg)
        }
    }
    return own_str(vm, strings.to_string(sb))
}

// Error.captureStackTrace(obj, ctorOpt?) — V8: grava em obj.stack o cabeçalho
// (Error.prototype.toString de obj) + os frames do ponto da chamada; com `ctorOpt`,
// omite o frame mais recente dele e tudo acima (esconde o construtor do erro).
@(private = "file")
err_capture_stack_trace :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := arg(a, 0).(^Object)
    if !ok {
        throw_type_error(vm, "Invalid argument") // mesma mensagem do V8
        return nil
    }
    skip, _ := arg(a, 1).(^Function)
    header, hok := err_to_string(vm, o, nil).(string)
    if vm.throwing do return nil
    if !hok do header = "Error"
    if st, sok := stack_capture(vm, header, skip); sok {
        o.props["stack"] = st
        mark_non_enumerable(o, "stack")
    }
    return nil
}

@(private = "file")
install_errors :: proc(vm: ^Interp) {
    vm.error_protos = make(map[string]^Object)
    base := new_object(vm)
    base.props["name"] = "Error"
    base.props["message"] = ""
    base.props["toString"] = mk_builtin_method(vm, err_to_string, "toString", 0)
    vm.error_protos["Error"] = base

    reg :: proc(vm: ^Interp, name: string, native: Native_Fn, base: ^Object) {
        proto := base
        if name != "Error" {
            proto = new_object(vm)
            proto.proto = base
            proto.props["name"] = name
            vm.error_protos[name] = proto
        }
        ctor := mk_native(vm, native)
        ctor.name = name
        ctor.props = make(map[string]Value)
        ctor.props["prototype"] = proto
        // `err.constructor === TypeError` (spec): sem isto, catch(e){e.constructor}
        // dava undefined e o `assert.throws(TypeError,...)` do Test262 quebrava lendo
        // `.name` de undefined — mascarando TODOS os throws corretos como falha.
        proto.props["constructor"] = ctor
        mark_non_enumerable(proto, "constructor") // não-enumerável
        env_define(vm.global, name, ctor)
        if name == "Error" {
            vm.error_ctor = ctor
            // API de pilha do V8 (stack_trace.odin). Classe de erro "à Node" chama
            // `Error.captureStackTrace(this, Ctor)` no construtor; detecção de script
            // e loggers mexem no limite.
            ctor.props["stackTraceLimit"] = f64(STACK_TRACE_LIMIT_DEFAULT)
            ctor.props["captureStackTrace"] = mk_builtin_method(vm, err_capture_stack_trace, "captureStackTrace", 2)
        }
    }
    reg(vm, "Error",          native_error,           base)
    reg(vm, "TypeError",      native_type_error,      base)
    reg(vm, "RangeError",     native_range_error,     base)
    reg(vm, "SyntaxError",    native_syntax_error,    base)
    reg(vm, "ReferenceError", native_reference_error, base)
    reg(vm, "URIError",       native_uri_error,       base)
    // Faltavam os dois últimos da lista da spec. `EvalError` quase não é LANÇADO
    // hoje (o `eval` moderno não o usa), mas é REFERENCIADO por polyfill/bundle
    // que varre os construtores nativos — o bandcamp entrava em laço cuspindo
    // `ReferenceError: EvalError is not defined`. `AggregateError` é o de
    // Promise.any, que aqui já montava o objeto à mão e SEM protótipo.
    reg(vm, "EvalError",      native_eval_error,      base)
    reg(vm, "AggregateError", native_aggregate_error, base)
}

// ── timers ──────────────────────────────────────────────────────────────────

@(private = "file")
add_timer :: proc(vm: ^Interp, a: []Value, repeat: bool) -> Value {
    fn, ok := arg(a, 0).(^Function)
    if !ok do return f64(-1)
    delay := as_number(arg(a, 1))
    if delay != delay || delay < 0 do delay = 0 // setTimeout(fn) sem delay → NaN → 0
    vm.next_timer_id += 1
    append(&vm.timers, Timer{
        id       = vm.next_timer_id,
        fn       = fn,
        due      = vm.clock_ms + delay,
        interval = repeat ? max(delay, 1) : 0,
    })
    return f64(vm.next_timer_id)
}

@(private = "file")
global_set_timeout :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return add_timer(vm, a, false)
}

// requestAnimationFrame(cb): agenda cb p/ ~próximo quadro (~16ms → 60fps). O
// callback recebe um timestamp (DOMHighResTimeStamp = clock_ms do vm), como no
// navegador. Devolve um id cancelável por cancelAnimationFrame. O scheduler do
// React e código de animação dependem disto.
@(private = "file")
global_request_animation_frame :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    fn, ok := arg(a, 0).(^Function)
    if !ok do return f64(-1)
    vm.next_timer_id += 1
    append(&vm.timers, Timer{
        id  = vm.next_timer_id,
        fn  = fn,
        due = vm.clock_ms + 16,
        raf = true,
    })
    return f64(vm.next_timer_id)
}

@(private = "file")
global_set_interval :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return add_timer(vm, a, true)
}

// IdleDeadline.timeRemaining() — quanto tempo (ms) "resta" no quadro ocioso.
// APROXIMAÇÃO: valor fixo generoso (não modelamos ociosidade real; o objetivo é
// que o callback rode e o `deadline.timeRemaining()` não estoure).
@(private = "file")
idle_time_remaining :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(50) }

// requestIdleCallback(cb[, opts]): agenda cb p/ quando o quadro estiver ocioso. O
// callback recebe um IdleDeadline (timeRemaining()/didTimeout). Muitos apps adiam
// init não-crítico com isto; sem ele, `requestIdleCallback is not a function` podia
// impedir a inicialização. Devolve id cancelável por cancelIdleCallback (mesmo canal).
@(private = "file")
global_request_idle_callback :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    fn, ok := arg(a, 0).(^Function)
    if !ok do return f64(-1)
    vm.next_timer_id += 1
    append(&vm.timers, Timer{ id = vm.next_timer_id, fn = fn, due = vm.clock_ms + 1, idle = true })
    return f64(vm.next_timer_id)
}

// clearTimeout e clearInterval: cancela pelo id (serve para ambos).
@(private = "file")
global_clear_timer :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    id := as_int(arg(a, 0))
    for t, i in vm.timers {
        if t.id == id {
            ordered_remove(&vm.timers, i)
            break
        }
    }
    // dentro de um pump, o timer pode já ter sido copiado p/ a leva `due` —
    // marca o id p/ o pump pular o disparo pendente (limpo ao fim do pump raiz)
    if vm.pump_depth > 0 do vm.dead_timer_ids[id] = true
    return nil
}

// new Function(args..., body) / Function(...): não compilamos JS em runtime.
// Devolvemos uma função no-op. core-js usa `Function("return this")()` só como
// ÚLTIMO fallback p/ globalThis (já resolvido antes por globalThis/window/self),
// então este caminho quase nunca roda; quando roda, no-op é melhor que crash.
@(private = "file")
// new Function(p1, ..., pn, corpo) — COMPILA de verdade. Antes era um stub que
// devolvia uma função no-op: `Function("return this")()` dava undefined, e esse é
// justamente o idioma com que todo bundler detecta o objeto global
// (`g = g || Function("return this")()`). Com o shim devolvendo undefined, o módulo
// caía num objeto vazio no lugar de `window` e depois estourava em
// `t.location.pathname` / `t.addEventListener` (npmjs.com, ver M127).
// Escopo: o GLOBAL (spec) — a função NÃO enxerga o léxico de quem a criou.
global_function_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    strings.write_string(&sb, "(function anonymous(")
    if len(args) > 1 {
        for i in 0 ..< len(args) - 1 {
            if i > 0 do strings.write_string(&sb, ",")
            to_text(&sb, args[i])
        }
    }
    // A quebra antes do `{` é da spec e protege contra corpo terminando em comentário `//`.
    strings.write_string(&sb, "\n) {\n")
    if len(args) > 0 do to_text(&sb, args[len(args) - 1])
    strings.write_string(&sb, "\n})")

    v := vm_eval_source_global(vm, strings.to_string(sb))
    if f, ok := v.(^Function); ok do return f
    // corpo inválido: devolve uma função inerte em vez de propagar lixo
    f := new_function(vm)
    f.native = fn_noop_native
    return f
}

@(private = "file")
fn_noop_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }

// eval INDIRETO: qualquer invocação que NÃO seja a forma sintática `eval(...)`
// (ex.: `(0,eval)(x)`, `var e=eval; e(x)`, `globalThis.eval(x)`) roda no escopo
// GLOBAL. O eval DIRETO é interceptado antes desta nativa, em eval_call
// (interp.odin), onde há o env do chamador. `do_eval` cuida do arg não-string
// (devolvido intacto) e do valor de conclusão.
@(private = "file")
global_eval :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return do_eval(vm, arg(args, 0), vm.global)
}

// structuredClone(v): clone PROFUNDO com preservação de ciclos e referências
// compartilhadas (memo por ponteiro). Suporta primitivos, Array, Object simples,
// Map/Set, Date, RegExp, ArrayBuffer/TypedArray/DataView. Função/Symbol e nós DOM/
// proxy não são clonáveis → lança DataCloneError (como a spec). options (transfer)
// é ignorado — não há transferência de posse de buffer aqui.
@(private = "file")
global_structured_clone :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    memo := make(map[rawptr]Value, context.temp_allocator)
    return structured_clone_val(vm, arg(args, 0), &memo)
}

@(private = "file")
structured_clone_not_cloneable :: proc(vm: ^Interp, what: string) -> Value {
    vm.thrown = mk_error(vm, "DataCloneError", fmt.tprintf("%s could not be cloned", what))
    vm.throwing = true
    return nil
}

@(private = "file")
structured_clone_val :: proc(vm: ^Interp, v: Value, memo: ^map[rawptr]Value) -> Value {
    switch x in v {
    case f64, bool, string, JS_Null, ^BigInt:
        return v // primitivos (BigInt é imutável): compartilha por valor
    case ^Symbol:
        return structured_clone_not_cloneable(vm, "Symbol")
    case ^Function:
        return structured_clone_not_cloneable(vm, "Function")
    case ^Regex:
        re, _ := regex_compile(vm, x.source, x.flags) // recompila (fonte+flags)
        return re
    case ^Array:
        if got, ok := memo[rawptr(x)]; ok do return got
        na := new_array(vm)
        memo[rawptr(x)] = na
        for it in x.items {
            append(&na.items, structured_clone_val(vm, it, memo))
            if vm.throwing do return nil
        }
        return na
    case ^Collection:
        if x.kind == .Weak_Map || x.kind == .Weak_Set {
            return structured_clone_not_cloneable(vm, x.kind == .Weak_Map ? "WeakMap" : "WeakSet")
        }
        if got, ok := memo[rawptr(x)]; ok do return got
        nc := new_collection(vm, x.kind)
        memo[rawptr(x)] = nc
        for e in x.entries {
            if e.dead do continue
            k := structured_clone_val(vm, e.key, memo); if vm.throwing do return nil
            val := structured_clone_val(vm, e.val, memo); if vm.throwing do return nil
            coll_put(nc, k, val)
        }
        return nc
    case ^Object:
        if got, ok := memo[rawptr(x)]; ok do return got
        // DOM node / proxy / generator não são serializáveis
        if x.host != nil || x.px_handler != nil || x.gen != nil {
            return structured_clone_not_cloneable(vm, "object")
        }
        // ArrayBuffer / TypedArray / DataView: clona os bytes
        if x.ab != nil {
            c := ta_structured_clone(vm, x)
            if c != nil { memo[rawptr(x)] = c; return c }
        }
        // Date: instante (#t) preservado num novo Date
        if x.proto == vm.date_proto {
            if t, tok := x.props["#t"].(f64); tok {
                d := date_new(vm, t)
                memo[rawptr(x)] = d
                return d
            }
        }
        no := new_object(vm) // objeto simples: props próprias enumeráveis, em ordem
        memo[rawptr(x)] = no
        keys := make([dynamic]string, context.temp_allocator)
        own_enum_keys(vm, x, &keys)
        for k in keys {
            pv := get_member(vm, x, k) // invoca getters (spec-ish: lê via Get)
            if vm.throwing do return nil
            oput(no, k, structured_clone_val(vm, pv, memo))
            if vm.throwing do return nil
        }
        return no
    }
    return nil // undefined
}

// ── registro ────────────────────────────────────────────────────────────────

install_builtins :: proc(vm: ^Interp) {
    vm.array_methods = make(map[string]^Function)
    vm.string_methods = make(map[string]^Function)

    vm.array_methods["push"]      = mk_builtin_method(vm, arr_push, "push", 1)
    vm.array_methods["pop"]       = mk_builtin_method(vm, arr_pop, "pop", 0)
    vm.array_methods["lastIndexOf"] = mk_builtin_method(vm, arr_last_index_of, "lastIndexOf", 1)
    vm.array_methods["indexOf"]   = mk_builtin_method(vm, arr_index_of, "indexOf", 1)
    vm.array_methods["includes"]  = mk_builtin_method(vm, arr_includes, "includes", 1)
    vm.array_methods["join"]      = mk_builtin_method(vm, arr_join, "join", 1)
    vm.array_methods["toString"]  = mk_builtin_method(vm, arr_join, "toString", 0) // Array.prototype.toString = join(",") (aprox. spec)
    vm.array_methods["slice"]     = mk_builtin_method(vm, arr_slice, "slice", 2)
    vm.array_methods["forEach"]   = mk_builtin_method(vm, arr_for_each, "forEach", 1)
    vm.array_methods["map"]       = mk_builtin_method(vm, arr_map, "map", 1)
    vm.array_methods["filter"]    = mk_builtin_method(vm, arr_filter, "filter", 1)
    vm.array_methods["reverse"]   = mk_builtin_method(vm, arr_reverse, "reverse", 0)
    vm.array_methods["sort"]      = mk_builtin_method(vm, arr_sort, "sort", 1)
    vm.array_methods["reduce"]    = mk_builtin_method(vm, arr_reduce, "reduce", 1)
    vm.array_methods["reduceRight"] = mk_builtin_method(vm, arr_reduce_right, "reduceRight", 1)
    vm.array_methods["concat"]    = mk_builtin_method(vm, arr_concat, "concat", 1)
    vm.array_methods["find"]      = mk_builtin_method(vm, arr_find, "find", 1)
    vm.array_methods["findIndex"] = mk_builtin_method(vm, arr_find_index, "findIndex", 1)
    vm.array_methods["some"]      = mk_builtin_method(vm, arr_some, "some", 1)
    vm.array_methods["every"]     = mk_builtin_method(vm, arr_every, "every", 1)
    vm.array_methods["shift"]     = mk_builtin_method(vm, arr_shift, "shift", 0)
    vm.array_methods["unshift"]   = mk_builtin_method(vm, arr_unshift, "unshift", 1)
    vm.array_methods["splice"]    = mk_builtin_method(vm, arr_splice, "splice", 2)
    vm.array_methods["flat"]          = mk_builtin_method(vm, arr_flat, "flat", 0)
    vm.array_methods["flatMap"]       = mk_builtin_method(vm, arr_flat_map, "flatMap", 1)
    vm.array_methods["fill"]          = mk_builtin_method(vm, arr_fill, "fill", 1)
    vm.array_methods["at"]            = mk_builtin_method(vm, arr_at, "at", 1)
    vm.array_methods["findLast"]      = mk_builtin_method(vm, arr_find_last, "findLast", 1)
    vm.array_methods["findLastIndex"] = mk_builtin_method(vm, arr_find_last_index, "findLastIndex", 1)
    vm.array_methods["copyWithin"]    = mk_builtin_method(vm, arr_copy_within, "copyWithin", 2)
    // Change Array by Copy (ES2023) — ver o bloco acima do arr_splice
    vm.array_methods["toReversed"]    = mk_builtin_method(vm, arr_to_reversed, "toReversed", 0)
    vm.array_methods["toSorted"]      = mk_builtin_method(vm, arr_to_sorted, "toSorted", 1)
    vm.array_methods["toSpliced"]     = mk_builtin_method(vm, arr_to_spliced, "toSpliced", 2)
    vm.array_methods["with"]          = mk_builtin_method(vm, arr_with, "with", 2)
    vm.array_methods["keys"]          = mk_builtin_method(vm, arr_keys_iter, "keys", 0)
    vm.array_methods["values"]        = mk_builtin_method(vm, arr_values_iter, "values", 0)
    vm.array_methods["entries"]       = mk_builtin_method(vm, arr_entries_iter, "entries", 0)

    // métodos de Number ((3.14).toFixed(2) etc.; get_member case f64)
    vm.number_methods = make(map[string]^Function)
    vm.number_methods["toFixed"]        = mk_native(vm, num_to_fixed)
    vm.number_methods["toString"]       = mk_builtin_method(vm, num_to_string, "toString", 0)
    vm.number_methods["toPrecision"]    = mk_native(vm, num_to_precision)
    vm.number_methods["toExponential"]  = mk_native(vm, num_to_exponential)
    vm.number_methods["toLocaleString"] = mk_builtin_method(vm, num_to_string, "toLocaleString", 0) // aproximação sem separadores
    vm.number_methods["valueOf"]        = mk_builtin_method(vm, num_value_of, "valueOf", 0)

    vm.string_methods["charAt"]      = mk_native(vm, str_char_at)
    vm.string_methods["charCodeAt"]  = mk_native(vm, str_char_code_at)
    vm.string_methods["indexOf"]     = mk_builtin_method(vm, str_index_of, "indexOf", 1)
    vm.string_methods["includes"]    = mk_builtin_method(vm, str_includes, "includes", 1)
    vm.string_methods["slice"]       = mk_builtin_method(vm, str_slice, "slice", 2)
    vm.string_methods["substring"]   = mk_native(vm, str_substring)
    vm.string_methods["substr"]      = mk_native(vm, str_substr)
    vm.string_methods["toString"]    = mk_builtin_method(vm, str_identity, "toString", 0)
    vm.string_methods["valueOf"]     = mk_builtin_method(vm, str_identity, "valueOf", 0)
    vm.string_methods["toUpperCase"] = mk_native(vm, str_to_upper)
    vm.string_methods["toLowerCase"] = mk_native(vm, str_to_lower)
    vm.string_methods["trim"]        = mk_native(vm, str_trim)
    vm.string_methods["repeat"]      = mk_native(vm, str_repeat)
    vm.string_methods["concat"]       = mk_builtin_method(vm, str_concat, "concat", 1)
    vm.string_methods["split"]        = mk_native(vm, str_split)
    vm.string_methods["replace"]      = mk_native(vm, str_replace)
    vm.string_methods["replaceAll"]   = mk_native(vm, str_replace_all)
    vm.string_methods["startsWith"]   = mk_native(vm, str_starts_with)
    vm.string_methods["endsWith"]     = mk_native(vm, str_ends_with)
    vm.string_methods["padStart"]     = mk_native(vm, str_pad_start)
    vm.string_methods["padEnd"]       = mk_native(vm, str_pad_end)
    vm.string_methods["match"]        = mk_native(vm, str_match)
    vm.string_methods["search"]       = mk_native(vm, str_search)
    vm.string_methods["lastIndexOf"]  = mk_builtin_method(vm, str_last_index_of, "lastIndexOf", 1)
    vm.string_methods["trimStart"]    = mk_native(vm, str_trim_start)
    vm.string_methods["trimEnd"]      = mk_native(vm, str_trim_end)
    vm.string_methods["at"]           = mk_builtin_method(vm, str_at, "at", 1)
    vm.string_methods["matchAll"]      = mk_native(vm, str_match_all)
    vm.string_methods["codePointAt"]   = mk_native(vm, str_code_point_at) // ≠ charCodeAt desde o M167
    vm.string_methods["localeCompare"] = mk_native(vm, str_locale_compare)
    vm.string_methods["normalize"]     = mk_native(vm, str_normalize)
    vm.string_methods["isWellFormed"] = mk_builtin_method(vm, str_is_well_formed, "isWellFormed", 0)
    vm.string_methods["toWellFormed"] = mk_builtin_method(vm, str_to_well_formed, "toWellFormed", 0)

    // objeto Math
    m := new_object(vm)
    m.props["floor"]  = mk_native(vm, math_floor)
    m.props["ceil"]   = mk_native(vm, math_ceil)
    m.props["round"]  = mk_native(vm, math_round)
    m.props["trunc"]  = mk_native(vm, math_trunc)
    m.props["abs"]    = mk_native(vm, math_abs_)
    m.props["sqrt"]   = mk_native(vm, math_sqrt)
    m.props["pow"]    = mk_native(vm, math_pow)
    m.props["sign"]   = mk_native(vm, math_sign)
    m.props["min"]    = mk_native(vm, math_min)
    m.props["max"]    = mk_native(vm, math_max)
    m.props["random"] = mk_native(vm, math_random)
    m.props["clz32"]  = mk_native(vm, math_clz32)
    m.props["imul"]   = mk_native(vm, math_imul)
    m.props["log"]    = mk_native(vm, math_log)
    m.props["log2"]   = mk_native(vm, math_log2)
    m.props["log10"]  = mk_native(vm, math_log10)
    m.props["exp"]    = mk_native(vm, math_exp)
    m.props["cbrt"]   = mk_native(vm, math_cbrt)
    m.props["hypot"]  = mk_native(vm, math_hypot)
    m.props["sin"]    = mk_native(vm, math_sin)
    m.props["cos"]    = mk_native(vm, math_cos)
    m.props["tan"]    = mk_native(vm, math_tan)
    m.props["asin"]   = mk_native(vm, math_asin)
    m.props["acos"]   = mk_native(vm, math_acos)
    m.props["atan"]   = mk_native(vm, math_atan)
    m.props["atan2"]  = mk_native(vm, math_atan2)
    m.props["cosh"]   = mk_native(vm, math_cosh)
    m.props["sinh"]   = mk_native(vm, math_sinh)
    m.props["tanh"]   = mk_native(vm, math_tanh)
    m.props["acosh"]  = mk_native(vm, math_acosh)
    m.props["asinh"]  = mk_native(vm, math_asinh)
    m.props["atanh"]  = mk_native(vm, math_atanh)
    m.props["expm1"]  = mk_native(vm, math_expm1)
    m.props["log1p"]  = mk_native(vm, math_log1p)
    m.props["fround"] = mk_native(vm, math_fround)
    m.props["PI"]     = f64(math.PI)
    m.props["E"]      = f64(math.E)
    m.props["LN2"]    = f64(math.LN2)
    m.props["LN10"]   = f64(math.LN10)
    m.props["LOG2E"]  = f64(1.0 / math.LN2)
    m.props["LOG10E"] = f64(1.0 / math.LN10)
    m.props["SQRT2"]  = f64(math.SQRT_TWO)
    m.props["SQRT1_2"] = f64(1.0 / math.SQRT_TWO)
    m.props["#class"] = "[object Math]" // Object.prototype.toString.call(Math) (Symbol.toStringTag)
    env_define(vm.global, "Math", m)

    // valores globais numéricos (antes faltavam: `NaN` resolvia como undefined,
    // e undefined == undefined dava `NaN == NaN` true!)
    env_define(vm.global, "NaN",      math.nan_f64())
    env_define(vm.global, "Infinity", math.inf_f64(1))

    // funções globais
    env_define(vm.global, "parseInt",              mk_native(vm, global_parse_int))
    env_define(vm.global, "parseFloat",            mk_native(vm, global_parse_float))
    env_define(vm.global, "isNaN",                 mk_native(vm, global_is_nan))
    env_define(vm.global, "isFinite",              mk_native(vm, global_is_finite))
    num_ctor := mk_native(vm, global_number_ctor)
    num_ctor.name = "Number" // `x.constructor.name` é type-check comum
    num_ctor.props = make(map[string]Value)
    num_ctor.props["isInteger"]        = mk_native(vm, num_is_integer)
    num_ctor.props["isFinite"]         = mk_native(vm, num_is_finite)
    num_ctor.props["isNaN"]            = mk_native(vm, num_is_nan)
    num_ctor.props["isSafeInteger"]    = mk_native(vm, num_is_safe_integer)
    num_ctor.props["parseInt"]         = mk_native(vm, global_parse_int)
    num_ctor.props["parseFloat"]       = mk_native(vm, global_parse_float)
    num_ctor.props["MAX_SAFE_INTEGER"] = f64(9007199254740991)
    num_ctor.props["MIN_SAFE_INTEGER"] = f64(-9007199254740991)
    num_ctor.props["EPSILON"]          = f64(2.220446049250313e-16)
    num_ctor.props["MAX_VALUE"]        = f64(1.7976931348623157e308)
    num_ctor.props["MIN_VALUE"]        = f64(5e-324)
    num_ctor.props["POSITIVE_INFINITY"] = math.inf_f64(1)
    num_ctor.props["NEGATIVE_INFINITY"] = math.inf_f64(-1)
    num_ctor.props["NaN"]              = math.nan_f64()
    env_define(vm.global, "Number", num_ctor)
    bool_ctor := mk_native(vm, global_boolean_ctor)
    bool_ctor.name = "Boolean"
    env_define(vm.global, "Boolean", bool_ctor)
    str_ctor := mk_native(vm, global_string_ctor)
    str_ctor.name = "String"
    str_ctor.props = make(map[string]Value)
    str_ctor.props["raw"] = mk_native(vm, string_raw) // String.raw`...` (tagged)
    str_ctor.props["fromCharCode"] = mk_native(vm, string_from_char_code)
    str_ctor.props["fromCodePoint"] = mk_native(vm, string_from_code_point) // sem recombinar par
    env_define(vm.global, "String",                str_ctor)
    env_define(vm.global, "encodeURIComponent",    mk_native(vm, global_encode_uri_component))
    env_define(vm.global, "decodeURIComponent",    mk_native(vm, global_decode_uri_component))
    env_define(vm.global, "encodeURI",             mk_native(vm, global_encode_uri_full))
    env_define(vm.global, "decodeURI",             mk_native(vm, global_decode_uri_full))
    env_define(vm.global, "btoa",                  mk_native(vm, global_btoa))
    env_define(vm.global, "atob",                  mk_native(vm, global_atob))

    // Array.from / Array.isArray
    arr_ctor := mk_native(vm, arr_construct) // Array(n) / Array(a,b,...) — NÃO é Array.from
    arr_ctor.name = "Array"
    arr_ctor.props = make(map[string]Value)
    arr_ctor.props["from"]    = mk_builtin_method(vm, arr_from, "from", 1)
    arr_ctor.props["fromAsync"] = mk_builtin_method(vm, arr_from_async, "fromAsync", 1)
    arr_ctor.props["isArray"] = mk_builtin_method(vm, arr_is_array, "isArray", 1)
    arr_ctor.props["of"]      = mk_builtin_method(vm, arr_of, "of", 0)
    arr_ctor.name = "Array"
    vm.array_ctor = arr_ctor // `[].constructor === Array` (get_member do ^Array)
    env_define(vm.global, "Array", arr_ctor)

    // ── `.prototype` dos construtores nativos ──────────────────────────────────
    // core-js (presente em quase todo bundle minificado) e muitas libs acessam
    // esses prototypes DIRETO: `Function.prototype.call`, `String.prototype.trimStart=…`,
    // e o padrão "uncurryThis" (`c=String.prototype.slice; c.bind(c)`). Sem eles,
    // `X.prototype` era undefined → o bundle abortava no init → PÁGINA EM BRANCO.
    // São objetos onde polyfills GRAVAM e onde feature-detects (`"x" in String.prototype`)
    // leem. O dispatch de métodos do motor continua por VALOR (str_*/array/number),
    // então aqui são sobretudo alvo de escrita/detecção. Function.prototype leva
    // call/apply/bind/toString REAIS (é o alvo uncurryThis nº 1 do core-js).
    fn_proto := new_object(vm)
    fn_proto.props["call"]     = vm.fn_call_fn
    fn_proto.props["apply"]    = vm.fn_apply_fn
    fn_proto.props["bind"]     = vm.fn_bind_fn
    fn_proto.props["toString"] = vm.fn_tostring_fn
    vm.function_proto = fn_proto // [[Prototype]] de toda função (Object.getPrototypeOf)
    func_ctor := mk_native(vm, global_function_ctor)
    func_ctor.name = "Function"
    func_ctor.props = make(map[string]Value)
    func_ctor.props["prototype"]  = fn_proto
    fn_proto.props["constructor"] = func_ctor
    env_define(vm.global, "Function", func_ctor)

    // ── Symbol.iterator nos iteráveis nativos (arrays/strings) ─────────────────
    // core-js e libs fazem `x[Symbol.iterator]()` EXPLÍCITO (getIterator), não só
    // via for-of. Sem o método, getIterator lê undefined e o `.next` seguinte
    // estoura ("reading 'next' of null") → o bundle da SPA morre no init → BRANCO.
    // Instalado ANTES da cópia p/ os .prototype abaixo, p/ Array/String.prototype
    // também exporem [Symbol.iterator]. (install_symbol foi removido do bloco de
    // installs lá embaixo — é chamado SÓ aqui, p/ vm.sym_iterator_key existir agora.)
    install_symbol(vm) // Symbol / Symbol.for (symbol.odin) — define sym_iterator_key
    vm.array_methods[vm.sym_iterator_key]  = vm.array_methods["values"] // === Array.prototype.values
    vm.string_methods[vm.sym_iterator_key] = mk_native(vm, str_values_iter)

    // Populamos os .prototype com os MESMOS natives dos mapas de dispatch. Como
    // os métodos já são genéricos (leem `this` na hora da chamada — é assim que
    // `arr.map()` funciona), `Array.prototype.slice` devolve o native REAL e o
    // padrão uncurryThis do core-js (`c=Array.prototype.slice; c.call(arr)` /
    // `c.bind(c)`) passa a funcionar. O dispatch normal (`arr.map`) continua indo
    // direto no mapa (get_member de ^Array), então isto NÃO muda `arr.metodo()`.
    num_proto := new_object(vm)
    for k, fn in vm.number_methods do num_proto.props[k] = fn
    num_proto.props["constructor"] = num_ctor
    num_ctor.props["prototype"] = num_proto
    vm.number_proto = num_proto // [[Prototype]] de new Number(x) / Object(1)
    // spec: Number.prototype É um Number object ([[NumberData]] +0), String.prototype
    // um String exótico de "" e Boolean.prototype um Boolean false —
    // `Boolean.prototype.toString()` é "false", não TypeError
    num_proto.prim = f64(0)
    num_ctor.native_length = 1

    str_proto := new_object(vm)
    for k, fn in vm.string_methods do str_proto.props[k] = fn
    str_proto.props["constructor"] = str_ctor
    str_ctor.props["prototype"] = str_proto
    vm.string_proto = str_proto // [[Prototype]] de new String(x) / Object("a")
    str_proto.prim = ""
    str_ctor.native_length = 1

    arr_proto := new_object(vm)
    for k, fn in vm.array_methods do arr_proto.props[k] = fn
    arr_proto.props["constructor"] = arr_ctor
    arr_ctor.props["prototype"] = arr_proto
    arr_ctor.getters = make(map[string]^Function)
    arr_ctor.attrs = make(map[string]Prop_Attrs)
    arr_ctor.attrs[vm.sym_species_key] = {.Configurable}
    arr_ctor.getters[vm.sym_species_key] = mk_builtin_method(vm, array_species_get, "get [Symbol.species]", 0)
    // Array.prototype[@@unscopables] (spec 23.1.3.41): objeto de protótipo NULO com os
    // métodos que o `with` NÃO pode ligar — os que entraram no Array depois de 2015 e
    // quebravam código antigo do tipo `with (arr) { values }`. Antes o `with` usava uma
    // lista fixa por dentro e `[][Symbol.unscopables]` era undefined.
    if vm.sym_unscopables_key != "" {
        unscop := new_object(vm)
        unscop.proto = nil
        for name in ([]string{"at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast",
                              "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed",
                              "toSorted", "toSpliced", "values"}) {
            oput(unscop, name, true)
        }
        arr_proto.props[vm.sym_unscopables_key] = unscop
        if arr_proto.attrs == nil do arr_proto.attrs = make(map[string]Prop_Attrs)
        arr_proto.attrs[vm.sym_unscopables_key] = {.Configurable}
    }

    // Boolean ficou de fora deste bloco: não tinha .prototype NEM métodos, então
    // `true.toString()` lançava e `Boolean.prototype.valueOf` era undefined. O helper
    // _createSuper do Babel usa exatamente `Boolean.prototype.valueOf.call(
    // Reflect.construct(Boolean,[],function(){}))` para detectar Reflect.construct
    // nativo — falhando o detect, o bundle cai no caminho degradado (ver M127).
    vm.boolean_methods = make(map[string]^Function)
    vm.boolean_methods["toString"] = mk_builtin_method(vm, boolean_to_string, "toString", 0)
    vm.boolean_methods["valueOf"]  = mk_builtin_method(vm, boolean_value_of, "valueOf", 0)
    bool_proto := new_object(vm)
    for k, fn in vm.boolean_methods do bool_proto.props[k] = fn
    bool_proto.props["constructor"] = bool_ctor
    bool_ctor.props = make(map[string]Value)
    bool_ctor.props["prototype"] = bool_proto
    vm.boolean_proto = bool_proto // [[Prototype]] de new Boolean(x) / Object(true)
    bool_proto.prim = false
    bool_ctor.native_length = 1

    install_date(vm) // Date completo (date.odin)

    install_errors(vm) // Error/TypeError/... com prototypes reais (instanceof)

    // timers (o hospedeiro dispara via vm_pump_timers a cada frame)
    env_define(vm.global, "queueMicrotask", mk_native(vm, global_queue_microtask))
    env_define(vm.global, "reportError", mk_native(vm, global_report_error))
    env_define(vm.global, "setTimeout",    mk_native(vm, global_set_timeout))
    env_define(vm.global, "setInterval",   mk_native(vm, global_set_interval))
    env_define(vm.global, "clearTimeout",  mk_native(vm, global_clear_timer))
    env_define(vm.global, "clearInterval", mk_native(vm, global_clear_timer))
    env_define(vm.global, "requestAnimationFrame", mk_native(vm, global_request_animation_frame))
    env_define(vm.global, "cancelAnimationFrame",  mk_native(vm, global_clear_timer)) // mesmo cancelamento por id
    // IdleDeadline reusável (aproximação estática) p/ requestIdleCallback
    dl := new_object(vm)
    dl.props["didTimeout"]    = false
    dl.props["timeRemaining"] = mk_native(vm, idle_time_remaining)
    vm.idle_deadline = dl
    env_define(vm.global, "requestIdleCallback", mk_native(vm, global_request_idle_callback))
    env_define(vm.global, "cancelIdleCallback",  mk_native(vm, global_clear_timer)) // mesmo cancelamento por id

    install_intl(vm)   // Intl/ECMA-402 aproximado (intl.odin) — DEPOIS de install_date
    install_css(vm)    // namespace CSS: escape/supports (css_om.odin)
    install_json(vm)   // objeto JSON (json.odin)
    install_object(vm) // Object + hasOwnProperty (object.odin)
    install_regex(vm)  // RegExp + test/exec (regex.odin)
    install_collections(vm) // Map/Set/WeakMap/WeakSet (collections.odin) — usa sym_iterator_key (já instalado acima)
    install_generator(vm) // métodos next/return/throw de generators (generator.odin)
    install_message_channel(vm) // MessageChannel/MessagePort (scheduler do React)
    // escape/unescape: legados mas VIVOS (3 sites do corpus em "escape is not a function")
    env_define(vm.global, "escape",   mk_native(vm, global_escape))
    env_define(vm.global, "unescape", mk_native(vm, global_unescape))

    // eval: DIRETO (forma `eval(...)`) roda no escopo do chamador — interceptado em
    // eval_call; INDIRETO cai em global_eval (escopo global). vm.eval_fn guarda o
    // ponteiro p/ eval_call reconhecer o builtin.
    eval_fn := mk_native(vm, global_eval)
    eval_fn.name = "eval"
    vm.eval_fn = eval_fn
    env_define(vm.global, "eval", eval_fn)

    // Cadeia de protótipos dos iteradores nativos, com os DOIS degraus da spec:
    //
    //     iterador → %ArrayIteratorPrototype% (next) → %IteratorPrototype% ([Symbol.iterator]) → Object.prototype
    //
    // core-js detecta o iterator-prototype com `getPrototypeOf(coll.values()).next`
    // — se o iterador não tem proto, isso vira "reading 'next' of null" e o bundle
    // morre; por isso `next` é HERDADO, não own.
    //
    // ⚠️ O degrau do meio não é decoração (M219): os polyfills de iterator-helpers
    // pegam o alvo com `getPrototypeOf(getPrototypeOf([][Symbol.iterator]()))`. Com
    // um degrau só isso dava **Object.prototype**, e o polyfill do github.com fazia
    // `Object.assign(Object.prototype, {map, filter, take, drop, …})` — envenenando
    // `in`/`for-in` da página INTEIRA. O estrago aparecia longe: `"filter" in {…}`
    // virava true no property-information e o React recebia uma FUNÇÃO onde esperava
    // o nome do atributo SVG `filter`.
    vm.iter_proto = new_object(vm)
    vm.iter_proto.proto = vm.object_proto
    if vm.sym_iterator_key != "" && vm.gen_iter_fn != nil do vm.iter_proto.props[vm.sym_iterator_key] = vm.gen_iter_fn
    vm.array_iter_proto = new_object(vm)
    vm.array_iter_proto.proto = vm.iter_proto
    vm.array_iter_proto.props["next"] = vm.iter_next_fn
    install_collection_iterators(vm)
    install_proxy(vm)  // Proxy + Reflect (proxy.odin)
    install_typed_arrays(vm) // ArrayBuffer / Uint8Array / ... / DataView (typedarray.odin)
    install_bigint(vm) // BigInt (bigint.odin)
    env_define(vm.global, "structuredClone", mk_native(vm, global_structured_clone))
}

// ── MessageChannel / MessagePort (M132) ──────────────────────────────────────
// 4 sites do corpus morriam em "MessageChannel is not a constructor". É o canal
// que o SCHEDULER DO REACT usa p/ ceder ao event loop:
//     const ch = new MessageChannel();
//     ch.port1.onmessage = trabalhar;
//     ch.port2.postMessage(null);
// Entrega ASSÍNCRONA (macrotask, via a fila de timers) — se fosse síncrona, o
// scheduler recursionaria em vez de fatiar o trabalho.

@(private = "file")
mc_deliver :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h, ok := vm.native_bound.(^Object)
    if !ok do return nil
    port, pok := h.props["port"].(^Object)
    if !pok do return nil
    ev := new_object(vm)
    ev.props["data"]   = h.props["data"]
    ev.props["type"]   = "message"
    ev.props["target"] = port
    if cb, cok := port.props["onmessage"].(^Function); cok {
        call_function(vm, cb, port, []Value{ev})
        vm_clear_uncaught(vm) // um handler que lança não derruba os demais
    }
    if ls, lok := port.props["__listeners"].(^Array); lok {
        for it in ls.items {
            if fn, fok := it.(^Function); fok {
                call_function(vm, fn, port, []Value{ev})
                vm_clear_uncaught(vm)
            }
        }
    }
    return nil
}

// Enfileira `f` como TAREFA (macrotask) do próximo pump. Exposto ao pacote: usado
// pelo MessageChannel e por window.postMessage.
vm_schedule_task :: proc(vm: ^Interp, f: ^Function) {
    vm.next_timer_id += 1
    append(&vm.timers, Timer{ id = vm.next_timer_id, fn = f, due = vm.clock_ms })
}

@(private = "file")
mc_post_message :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    port, ok := this.(^Object)
    if !ok do return nil
    pair, pok := port.props["__pair"].(^Object)
    if !pok do return nil
    holder := new_object(vm)
    holder.props["port"] = pair // a mensagem chega na porta IRMÃ
    holder.props["data"] = arg(args, 0)
    f := new_function(vm)
    f.native = mc_deliver
    f.bound  = holder
    vm_schedule_task(vm, f)
    return nil
}

@(private = "file")
mc_add_listener :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    port, ok := this.(^Object)
    if !ok do return nil
    ev, eok := arg(args, 0).(string)
    fn, fok := arg(args, 1).(^Function)
    if !eok || !fok || ev != "message" do return nil
    ls, lok := port.props["__listeners"].(^Array)
    if !lok {
        ls = new_array(vm)
        port.props["__listeners"] = ls
    }
    append(&ls.items, fn)
    return nil
}

@(private = "file")
mc_noop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }

@(private = "file")
mc_make_port :: proc(vm: ^Interp) -> ^Object {
    p := new_object(vm)
    p.props["postMessage"]        = mk_native(vm, mc_post_message)
    p.props["addEventListener"]   = mk_native(vm, mc_add_listener)
    p.props["removeEventListener"] = mk_native(vm, mc_noop)
    p.props["start"]              = mk_native(vm, mc_noop)
    p.props["close"]              = mk_native(vm, mc_noop)
    return p
}

@(private = "file")
message_channel_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    ch := new_object(vm)
    p1 := mc_make_port(vm)
    p2 := mc_make_port(vm)
    p1.props["__pair"] = p2
    p2.props["__pair"] = p1
    ch.props["port1"] = p1
    ch.props["port2"] = p2
    return ch
}

install_message_channel :: proc(vm: ^Interp) {
    ctor := mk_native(vm, message_channel_ctor)
    ctor.name = "MessageChannel"
    env_define(vm.global, "MessageChannel", ctor)
}


// ── escape / unescape (Annex B, legados mas usados) ──────────────────────────
// Diferente de encodeURIComponent: preserva @*_+-./ e usa %uXXXX acima de 0xFF.

@(private = "file")
esc_keep :: proc(c: u8) -> bool {
    switch c {
    case 'A'..='Z', 'a'..='z', '0'..='9', '@', '*', '_', '+', '-', '.', '/': return true
    }
    return false
}

@(private = "file")
global_escape :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sbv: strings.Builder
    strings.builder_init(&sbv)
    defer strings.builder_destroy(&sbv)
    to_text(&sbv, arg(args, 0))
    src := strings.to_string(sbv)
    out: strings.Builder
    strings.builder_init(&out)
    defer strings.builder_destroy(&out)
    HEX := "0123456789ABCDEF"
    for r in src {
        cp := int(r)
        if cp < 256 {
            c := u8(cp)
            if esc_keep(c) {
                strings.write_byte(&out, c)
            } else {
                strings.write_byte(&out, '%')
                strings.write_byte(&out, HEX[c >> 4])
                strings.write_byte(&out, HEX[c & 15])
            }
        } else {
            strings.write_string(&out, "%u")
            for sh := 12; sh >= 0; sh -= 4 do strings.write_byte(&out, HEX[(cp >> uint(sh)) & 15])
        }
    }
    return own_str(vm, strings.to_string(out))
}

@(private = "file")
hexv :: proc(c: u8) -> (int, bool) {
    switch c {
    case '0'..='9': return int(c - '0'), true
    case 'a'..='f': return int(c - 'a') + 10, true
    case 'A'..='F': return int(c - 'A') + 10, true
    }
    return 0, false
}

@(private = "file")
global_unescape :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sbv: strings.Builder
    strings.builder_init(&sbv)
    defer strings.builder_destroy(&sbv)
    to_text(&sbv, arg(args, 0))
    src := strings.to_string(sbv)
    out: strings.Builder
    strings.builder_init(&out)
    defer strings.builder_destroy(&out)
    i := 0
    for i < len(src) {
        if src[i] == '%' && i + 5 < len(src) && (src[i+1] == 'u' || src[i+1] == 'U') {
            v, okc := 0, true
            for k in 2 ..< 6 {
                d, dok := hexv(src[i+k])
                if !dok { okc = false; break }
                v = v * 16 + d
            }
            if okc { strings.write_rune(&out, rune(v)); i += 6; continue }
        }
        if src[i] == '%' && i + 2 < len(src) {
            h1, ok1 := hexv(src[i+1])
            h2, ok2 := hexv(src[i+2])
            if ok1 && ok2 { strings.write_rune(&out, rune(h1 * 16 + h2)); i += 3; continue }
        }
        strings.write_byte(&out, src[i])
        i += 1
    }
    return own_str(vm, strings.to_string(out))
}

mk_builtin_method :: proc(vm: ^Interp, fn: Native_Fn, name: string, arity: int) -> ^Function {
    f := mk_native(vm, fn)
    f.name = name
    f.native_length = arity
    f.non_constructor = true
    return f
}

@(private = "file")
arr_integer :: proc(vm: ^Interp, v: Value) -> int {
    return as_int(to_number(vm, v))
}
@(private = "file")
arr_write :: proc(vm: ^Interp, this: Value, key: string, v: Value) {
    if vm.throwing do return
    #partial switch o in this {
    case ^Array:
        // Set(O, P, V, true) da spec: os métodos mutadores LANÇAM em qualquer modo
        // quando o [[Set]] falha (`Object.freeze([]).push(1)` é TypeError mesmo em
        // sloppy). Antes o caminho do ^Array ignorava o false e o length mudava.
        if key == "length" {
            if !array_set_length(vm, o, v) && !vm.throwing {
                throw_type_error(vm, "Cannot assign to read only property 'length' of object")
            }
            return
        }
        if !set_index(vm, this, key, v) && !vm.throwing {
            throw_type_error(vm, fmt.tprintf("Cannot assign to read only property '%s' of object", key))
        }
        return
    case ^Object:
        if a, wrapped := o.prim.(^Array); wrapped && key == "length" { arr_write(vm, a, key, v); return }
        if a, wrapped := o.prim.(^Array); wrapped && key != "length" { set_index(vm, a, key, v); return }
        if o.set != nil { set_member(vm, o, key, v); return }
        for cur := o; cur != nil; cur = cur.proto {
            if setter, ok := cur.setters[key]; ok {
                if setter == nil { throw_type_error(vm, "Cannot write accessor"); return }
                call_function(vm, setter, o, []Value{v}); return
            }
            if _, ok := cur.getters[key]; ok { throw_type_error(vm, "Cannot write accessor"); return }
            if _, ok := cur.props[key]; ok {
                if .Writable not_in prop_attrs(cur, key) { throw_type_error(vm, "Cannot write read-only property"); return }
                break
            }
        }
        if _, own := o.props[key]; !own && o.non_extensible { throw_type_error(vm, "Cannot add property"); return }
    case string:
        throw_type_error(vm, "Cannot modify string"); return
    }
    set_member(vm, this, key, v)
}
@(private = "file")
arr_set :: proc(vm: ^Interp, this: Value, i: int, v: Value) {
    buf: [24]u8
    arr_write(vm, this, own_str_raw(vm, strconv.write_int(buf[:], i64(i), 10)), v)
}
@(private = "file")
arr_delete :: proc(vm: ^Interp, this: Value, i: int) {
    if vm.throwing do return
    buf: [24]u8
    key := strconv.write_int(buf[:], i64(i), 10)
    #partial switch o in this {
    case ^Object:
        if a, wrapped := o.prim.(^Array); wrapped { arr_delete(vm, a, i); return }
        _, data := o.props[key]; _, getter := o.getters[key]; _, setter := o.setters[key]
        if (data || getter || setter) && .Configurable not_in prop_attrs(o, key) { throw_type_error(vm, "Cannot delete property"); return }
        oremove(o, key); delete_key(&o.getters, key); delete_key(&o.setters, key)
    case ^Function:
        delete_key(&o.props, key); delete_key(&o.getters, key); delete_key(&o.setters, key)
    case ^Array:
        if !array_delete_property(o, key) do throw_type_error(vm, "Cannot delete property")
    case string:
        if i >= 0 && i < str_rlen(o) do throw_type_error(vm, "Cannot delete string index")
    }
}
@(private = "file")
arr_move :: proc(vm: ^Interp, this: Value, src, dst: int) {
    if vm.throwing do return
    if array_like_has(vm,this, src) {
        v := array_like_get(vm, this, src)
        if !vm.throwing do arr_set(vm, this, dst, v)
    } else { arr_delete(vm, this, dst) }
}

@(private = "file")
arr_last_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := array_like_len(vm, this)
    if vm.throwing do return nil
    if n == 0 do return f64(-1)
    from := n - 1
    if len(args) > 1 do from = arr_integer(vm, args[1])
    if vm.throwing do return nil
    if from < 0 { from += n } else { from = min(from, n - 1) }
    for i := from; i >= 0; i -= 1 {
        if !array_like_has(vm,this, i) do continue
        v := array_like_get(vm, this, i)
        if vm.throwing do return nil
        if v == arg(args, 0) do return f64(i)
    }
    return f64(-1)
}

// The shared iterator prototype dispatches these live iterators here.
arr_iter_next :: proc(vm: ^Interp, o: ^Object) -> Value {
    res := new_object(vm)
    res.props["value"] = nil
    res.props["done"] = true
    if truthy(o.props["_done"]) do return res
    src := o.props["_source"]
    n := array_like_len(vm, src)
    if vm.throwing do return nil
    i := as_int(o.props["_i"])
    if i >= n { o.props["_done"] = true; o.props["_source"] = nil; return res }
    o.props["_i"] = f64(i + 1)
    kind := as_int(o.props["_kind"])
    v: Value = f64(i)
    if kind != 0 {
        v = array_like_get(vm, src, i)
        if vm.throwing do return nil
        if kind == 2 {
            pair := new_array(vm)
            append(&pair.items, f64(i), v)
            v = pair
        }
    }
    res.props["value"] = v
    res.props["done"] = false
    return res
}
@(private = "file")
arr_live_iterator :: proc(vm: ^Interp, src: Value, kind: int) -> Value {
    if is_nullish(src) { throw_type_error(vm, "Array iterator called on null or undefined"); return nil }
    it := make_array_iterator(vm, nil).(^Object)
    it.props["_source"] = src
    it.props["_kind"] = f64(kind)
    return it
}

@(private = "file")
array_species_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return this }

@(private = "file")
array_is_array :: proc(v: Value) -> bool {
    #partial switch o in v {
    case ^Array: return !o.is_arguments
    case ^Object: return array_is_array(o.prim) if o.prim != nil else false
    }
    return false
}

// ArraySpeciesCreate: constructor/species reads occur only for actual arrays.
@(private = "file")
array_species_create :: proc(vm: ^Interp, original: Value, length: int) -> Value {
    ctor: Value
    if array_is_array(original) {
        ctor = get_member(vm, original, "constructor")
        if vm.throwing do return nil
        if ctor != nil && !is_primitive(ctor) {
            ctor = get_member(vm, ctor, vm.sym_species_key)
            if vm.throwing do return nil
            if _, null := ctor.(JS_Null); null do ctor = nil
        }
    }
    if ctor == nil {
        out := new_array(vm)
        arr_mark_holes(out, 0, length) // ArrayCreate(n): só length; quem escreve preenche
        for i := 0; i < length; i += 1 do append(&out.items, nil)
        return out
    }
    if fn, ok := ctor.(^Function); ok do return construct_object(vm, fn, []Value{f64(length)})
    if o, ok := ctor.(^Object); ok && o.px_handler != nil do return proxy_construct(vm, o, []Value{f64(length)})
    throw_type_error(vm, "Array species is not a constructor")
    return nil
}

// CreateDataPropertyOrThrow defines own properties, bypassing inherited setters.
@(private = "file")
array_result_set :: proc(vm: ^Interp, out: Value, index: int, v: Value) {
    if vm.throwing do return
    if a, ok := out.(^Array); ok { set_index(vm, a, f64(index), v); return }
    if o, ok := out.(^Object); ok {
        if a, wrapped := o.prim.(^Array); wrapped { set_index(vm, a, f64(index), v); return }
    }
    desc := new_object(vm)
    desc.props["value"] = v
    desc.props["writable"] = true; desc.props["enumerable"] = true; desc.props["configurable"] = true
    obj_define_property(vm, nil, []Value{out, f64(index), desc})
}
