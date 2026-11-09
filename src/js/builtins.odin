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
    c := strings.clone(s)
    append(&vm.owned_strings, c)
    return c
}

// Igual, mas devolvendo `string` — para quem guarda a cópia num campo TIPADO
// (o `text` de um Canvas_Cmd), onde um `Value` não serve.
own_str_raw :: proc(vm: ^Interp, s: string) -> string {
    c := strings.clone(s)
    append(&vm.owned_strings, c)
    return c
}

// Assume posse de uma string JÁ alocada (ex.: resultado de strings.to_upper).
own_taken :: proc(vm: ^Interp, s: string) -> Value {
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
// ⚠️ DEGRADAÇÃO ANOTADA: um índice que cai NO MEIO de um par surrogate não tem
// offset de byte correspondente — a metade de um par não é representável em UTF-8.
// Nesses casos o par é tratado ATOMICAMENTE: o índice arredonda para a fronteira
// SEGUINTE. O efeito é que `s.slice(0,1)` de um emoji devolve o emoji inteiro em
// vez do high surrogate solto. A propriedade que isso preserva, e que importa na
// prática, é `s.slice(0,i) + s.slice(i) === s` para todo i. `charCodeAt` NÃO
// depende disso e devolve o surrogate correto (ver str_code_unit_at).

// Largura em bytes de um code point pelo seu PRIMEIRO byte. Percorrer com isto
// evita decodificar a rune inteira quando só precisamos avançar — decodificar em
// todo passo custou 4,4× no `length` de uma string de 2 KB (medido).
@(private = "file")
utf8_width :: proc(b: u8) -> int {
    if b < 0x80 do return 1
    if b < 0xE0 do return 2 // (bytes de continuação soltos caem aqui; string inválida só desalinha o passo, não estoura)
    if b < 0xF0 do return 3
    return 4
}

// comprimento em code units UTF-16 ("length" do JS).
//
// `length` é das operações mais quentes do motor, então o caminho ASCII — que é a
// esmagadora maioria das strings — tem de ficar numa passada só. `rune_count_in_string`
// é a contagem otimizada do core; se ela bate com o nº de bytes, a string é ASCII
// pura e não pode conter astral, e acabou. Só quando há multibyte é que vale varrer
// atrás dos líderes de 4 bytes (>= 0xF0), que são os que valem 2 unidades.
str_rlen :: proc(s: string) -> int {
    n := utf8.rune_count_in_string(s)
    if n == len(s) do return n // ASCII puro: nenhum code point astral
    for i := 0; i < len(s); i += 1 do if s[i] >= 0xF0 do n += 1
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
    bl := str_rbyte(s, lo)
    bh := str_rbyte(s, hi)
    if bh < bl do bh = bl
    return s[bl:bh]
}

// o "caractere" no índice `ui` como fatia de s ("" se fora do range). Para um
// astral devolve o code point INTEIRO no índice do seu 1º unit, e "" no 2º —
// consequência do par ser atômico aqui.
str_rune_at :: proc(s: string, ui: int) -> string {
    if ui < 0 do return ""
    k := 0
    for i := 0; i < len(s); {
        w := utf8_width(s[i])
        if k == ui do return s[i:min(i + w, len(s))]
        k += 2 if s[i] >= 0xF0 else 1
        if k > ui do return "" // `ui` era a 2ª metade de um par surrogate
        i += w
    }
    return ""
}

// O CODE UNIT UTF-16 no índice `ui` — para um astral devolve o high surrogate no
// 1º índice e o low no 2º, que é o que charCodeAt tem de reportar. Este caminho
// não sofre a limitação do str_rune_at porque devolve um NÚMERO, não uma fatia.
str_code_unit_at :: proc(s: string, ui: int) -> (u16, bool) {
    if ui < 0 do return 0, false
    k := 0
    for i := 0; i < len(s); {
        r, w := utf8.decode_rune(s[i:])
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
    if v != v do return 0 // NaN (ToIntegerOrInfinity(NaN) = 0); int(NaN) seria UB
    i := int(v)
    if i < 0 do i += n
    if i < 0 do i = 0
    if i > n do i = n
    return i
}

// ── métodos de Array ────────────────────────────────────────────────────────

@(private = "file")
arr_push :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return nil
    for v in args do append(&a.items, v)
    return f64(len(a.items))
}

@(private = "file")
arr_pop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok || len(a.items) == 0 do return nil
    return pop(&a.items)
}

@(private = "file")
arr_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    a, ok := this.(^Array)
    if !ok { // array-like (HTMLCollection/NodeList/arguments): length + índices
        n := array_like_len(vm, this)
        for i := 0; i < n; i += 1 {
            if array_like_get(vm, this, i) == target do return f64(i)
        }
        return f64(-1)
    }
    for it, i in a.items {
        if it == target do return f64(i) // == na union Value = igualdade estrita
    }
    return f64(-1)
}

@(private = "file")
// Array.prototype.includes: compara por SameValueZero, NÃO por === — é justamente
// o que o separa do indexOf, porque só assim `[NaN].includes(NaN)` é true. Usava o
// `==` da union, onde NaN != NaN pelo IEEE, e o caso NaN falhava calado.
arr_includes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target := arg(args, 0)
    a, ok := this.(^Array)
    if !ok { // array-like: ver arr_index_of
        n := array_like_len(vm, this)
        for i := 0; i < n; i += 1 {
            if same_value_zero(array_like_get(vm, this, i), target) do return true
        }
        return false
    }
    for it in a.items {
        if same_value_zero(it, target) do return true
    }
    return false
}

@(private = "file")
arr_join :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // `this` que não é ^Array segue como array-like (ver arr_index_of). Um ^Object
    // SEM length dá n=0 e o resultado continua "", como antes.
    a, is_arr := this.(^Array)
    n := is_arr ? len(a.items) : array_like_len(vm, this)
    sep := ","
    if s, sok := arg(args, 0).(string); sok do sep = s
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for i := 0; i < n; i += 1 {
        if i > 0 do strings.write_string(&sb, sep)
        it := is_arr ? a.items[i] : array_like_get(vm, this, i)
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
    a, is_arr := this.(^Array)
    n := is_arr ? len(a.items) : array_like_len(vm, this)
    // undefined explícito conta como ausente (spec: end undefined → até o fim)
    start := len(args) >= 1 && args[0] != nil ? idx_from(as_number(args[0]), n) : 0
    end   := len(args) >= 2 && args[1] != nil ? idx_from(as_number(args[1]), n) : n
    res := new_array(vm)
    for i := start; i < end; i += 1 {
        append(&res.items, is_arr ? a.items[i] : array_like_get(vm, this, i))
    }
    return res
}

// ── acesso genérico a array-like ────────────────────────────────────────────
// Spec: os métodos de Array operam sobre ToObject(this) usando ToLength(this.length)
// e acesso indexado — não só sobre arrays reais. Habilita o idioma ubíquo
// `Array.prototype.map.call(arguments/nodeList/{length,0:...}, fn)`. ^Array segue
// pelo caminho rápido (items diretos); ^Object/^Function leem length+índice.
@(private = "file")
array_like_len :: proc(vm: ^Interp, this: Value) -> int {
    #partial switch t in this {
    case ^Array:  return len(t.items)
    case string:  return str_rlen(t)
    case ^Object, ^Function:
        n := as_number(get_member(vm, this, "length"))
        if n != n || n <= 0 do return 0 // NaN / negativo → 0 (ToLength)
        MAXLEN :: 1 << 53
        if n > f64(MAXLEN) do return MAXLEN
        return int(n) // positivo trunca p/ baixo
    }
    return 0 // primitivo não-objeto (número/bool): wrapper sem length → 0
}

@(private = "file")
array_like_get :: proc(vm: ^Interp, this: Value, i: int) -> Value {
    #partial switch t in this {
    case ^Array:  return t.items[i]
    case string:  return own_str(vm, str_rslice(t, i, i + 1))
    case ^Object, ^Function:
        buf: [24]u8
        return get_member(vm, this, strconv.write_int(buf[:], i64(i), 10))
    }
    return nil
}

// HasProperty(this, i): buracos (índices ausentes) são PULADOS pelos métodos de
// Array (spec) — `[].filter.call({length:2, 1:true}, ...)` só visita o índice 1.
@(private = "file")
array_like_has :: proc(this: Value, i: int) -> bool {
    #partial switch t in this {
    case ^Array:  return i >= 0 && i < len(t.items)
    case string:  return i >= 0 && i < str_rlen(t)
    case ^Object:
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
        buf: [24]u8
        key := strconv.write_int(buf[:], i64(i), 10)
        // HasProperty sobe a CADEIA (spec) — e desde o M208 isso importa de verdade:
        // `Object.create(<array>)` herda length E os índices, então parar nas props
        // PRÓPRIAS deixava o objeto com length=2 e nenhum índice "presente" —
        // `[].map.call(o, f)` devolvia `[null,null]` em vez do resultado. Mesma falha
        // silenciosa que o `geti` acima conserta para as coleções vivas.
        // ⚠️ o `get` hook segue de FORA de propósito (ver o parágrafo acima).
        for cur := t; cur != nil; cur = cur.proto {
            if cur.props == nil do continue
            if _, has := cur.props[key]; has do return true
        }
        if x := proto_exotic_end(t); x != nil do return array_like_has(x, i)
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
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.forEach: callback não é função"); return nil }
    this_arg := arg(args, 1)
    n := array_like_len(vm, this)
    for i := 0; i < n; i += 1 {
        if !array_like_has(this, i) do continue // pula buracos (HasProperty)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        call_function(vm, cb, this_arg, []Value{it, f64(i), this})
        if vm.throwing do break // exceção no callback interrompe a iteração
    }
    return nil
}

@(private = "file")
arr_map :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_array(vm)
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.map called on null or undefined"); return res }
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.map: callback não é função"); return res }
    this_arg := arg(args, 1)
    n := array_like_len(vm, this)
    for i := 0; i < n; i += 1 {
        if !array_like_has(this, i) { append(&res.items, nil); continue } // buraco → undefined (preserva posição)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        append(&res.items, call_function(vm, cb, this_arg, []Value{it, f64(i), this}))
        if vm.throwing do break
    }
    return res
}

@(private = "file")
arr_filter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_array(vm)
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.filter called on null or undefined"); return res }
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.filter: callback não é função"); return res }
    this_arg := arg(args, 1)
    n := array_like_len(vm, this)
    for i := 0; i < n; i += 1 {
        if !array_like_has(this, i) do continue // pula buracos (HasProperty)
        it := array_like_get(vm, this, i)
        if vm.throwing do break
        if truthy(call_function(vm, cb, this_arg, []Value{it, f64(i), this})) do append(&res.items, it)
        if vm.throwing do break
    }
    return res
}

@(private = "file")
arr_reverse :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return this
    n := len(a.items)
    for i := 0; i < n / 2; i += 1 {
        a.items[i], a.items[n - 1 - i] = a.items[n - 1 - i], a.items[i]
    }
    return a
}

// "x vem depois de y?" para o sort: comparador JS (>0) ou, sem comparador, a
// comparação de STRINGS do JS (por isso [10,9,1].sort() dá [1,10,9]).
@(private = "file")
sort_after :: proc(vm: ^Interp, cmp: ^Function, x, y: Value) -> bool {
    if cmp != nil {
        return as_number(call_function(vm, cmp, nil, []Value{x, y})) > 0
    }
    sbx, sby: strings.Builder
    strings.builder_init(&sbx); defer strings.builder_destroy(&sbx)
    strings.builder_init(&sby); defer strings.builder_destroy(&sby)
    to_text(&sbx, x)
    to_text(&sby, y)
    return strings.to_string(sbx) > strings.to_string(sby)
}

// sort in-place (insertion sort — arrays de página são pequenos), devolve o array.
@(private = "file")
arr_sort :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return this
    cmp, _ := arg(args, 0).(^Function)
    for i := 1; i < len(a.items); i += 1 {
        v := a.items[i]
        j := i - 1
        for j >= 0 && sort_after(vm, cmp, a.items[j], v) {
            a.items[j + 1] = a.items[j]
            j -= 1
        }
        a.items[j + 1] = v
        if vm.throwing do break // comparador lançou
    }
    return a
}

@(private = "file")
arr_reduce :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Array.prototype.reduce called on null or undefined"); return nil }
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Array.prototype.reduce: callback não é função"); return nil }
    n := array_like_len(vm, this)
    acc: Value
    start := 0
    if len(args) >= 2 {
        acc = args[1]
    } else {
        // sem valor inicial: acc = 1º índice PRESENTE (pula buracos à esquerda)
        for start < n && !array_like_has(this, start) do start += 1
        // TypeError REAL (era string crua → assert.throws(TypeError) não casava)
        if start >= n { throw_type_error(vm, "Reduce of empty array with no initial value"); return nil }
        acc = array_like_get(vm, this, start)
        start += 1
    }
    for i := start; i < n; i += 1 {
        if !array_like_has(this, i) do continue // pula buracos (HasProperty)
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
    a, ok := this.(^Array); if !ok do return nil
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    acc: Value
    start := len(a.items) - 1
    if len(args) >= 2 {
        acc = args[1]
    } else {
        if len(a.items) == 0 { // JS lança TypeError aqui
            vm.thrown = mk_error(vm, "TypeError", "Reduce of empty array with no initial value")
            vm.throwing = true
            return nil
        }
        acc = a.items[start]
        start -= 1
    }
    for i := start; i >= 0; i -= 1 {
        acc = call_function(vm, cb, nil, []Value{acc, a.items[i], f64(i), a})
        if vm.throwing do break
    }
    return acc
}

@(private = "file")
arr_concat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_array(vm)
    if a, ok := this.(^Array); ok {
        for it in a.items do append(&res.items, it)
    }
    for v in args { // arrays achatam um nível; o resto entra como está
        if b, ok := v.(^Array); ok {
            for it in b.items do append(&res.items, it)
        } else {
            append(&res.items, v)
        }
    }
    return res
}

@(private = "file")
arr_find :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return nil
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    for it, i in a.items {
        if truthy(call_function(vm, cb, nil, []Value{it, f64(i), a})) do return it
        if vm.throwing do break
    }
    return nil
}

@(private = "file")
arr_find_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return f64(-1)
    cb, cok := arg(args, 0).(^Function); if !cok do return f64(-1)
    for it, i in a.items {
        if truthy(call_function(vm, cb, nil, []Value{it, f64(i), a})) do return f64(i)
        if vm.throwing do break
    }
    return f64(-1)
}

@(private = "file")
arr_some :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return false
    cb, cok := arg(args, 0).(^Function); if !cok do return false
    for it, i in a.items {
        if truthy(call_function(vm, cb, nil, []Value{it, f64(i), a})) do return true
        if vm.throwing do break
    }
    return false
}

@(private = "file")
arr_every :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return true
    cb, cok := arg(args, 0).(^Function); if !cok do return true
    for it, i in a.items {
        if !truthy(call_function(vm, cb, nil, []Value{it, f64(i), a})) do return false
        if vm.throwing do break
    }
    return true
}

@(private = "file")
arr_shift :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok || len(a.items) == 0 do return nil
    v := a.items[0]
    ordered_remove(&a.items, 0)
    return v
}

@(private = "file")
arr_unshift :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return nil
    for i := len(args) - 1; i >= 0; i -= 1 {
        inject_at(&a.items, 0, args[i])
    }
    return f64(len(a.items))
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
    for i := 0; i < n; i += 1 {
        append(&res.items, is_arr ? a.items[i] : array_like_get(vm, this, i))
    }
    return res
}

@(private = "file")
arr_to_reversed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := arr_copy_of(vm, this)
    n := len(res.items)
    for i := 0; i < n / 2; i += 1 {
        res.items[i], res.items[n - 1 - i] = res.items[n - 1 - i], res.items[i]
    }
    return res
}

// ⚠️ Delega ao `arr_sort` de propósito: as duas ordenações têm de concordar
// (mesmo comparador, mesma comparação de STRINGS quando não há um). Herda com
// isso a mesma LENIÊNCIA do `sort`: a spec manda TypeError quando o comparador
// não é undefined nem função, e nenhum dos dois faz essa checagem.
@(private = "file")
arr_to_sorted :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return arr_sort(vm, arr_copy_of(vm, this), args)
}

// toSpliced(start, skipCount, ...novos): como splice, mas devolve o array NOVO
// (o splice devolve os REMOVIDOS — a diferença é fácil de errar).
@(private = "file")
arr_to_spliced :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    src := arr_copy_of(vm, this)
    n := len(src.items)
    start := len(args) >= 1 ? idx_from(as_number(args[0]), n) : 0
    skip := n - start
    if len(args) >= 2 {
        skip = as_int(args[1])
        if skip < 0 do skip = 0
        if skip > n - start do skip = n - start
    }
    res := new_array(vm)
    for i := 0; i < start; i += 1 do append(&res.items, src.items[i])
    for i := 2; i < len(args); i += 1 do append(&res.items, args[i])
    for i := start + skip; i < n; i += 1 do append(&res.items, src.items[i])
    return res
}

// with(index, value): cópia com UM índice trocado. Índice negativo conta do fim;
// fora do range é RangeError (não silêncio) — é o que distingue do `arr[i]=v`.
@(private = "file")
arr_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := arr_copy_of(vm, this)
    n := len(res.items)
    i := as_int(arg(args, 0))
    if i < 0 do i += n
    if i < 0 || i >= n {
        vm.thrown = mk_error(vm, "RangeError", "Invalid index") // não há helper de RangeError (só o do bigint, file-private)
        vm.throwing = true
        return nil
    }
    res.items[i] = arg(args, 1)
    return res
}

// splice(start, deleteCount, ...novos) — remove/insere in-place; devolve os removidos.
@(private = "file")
arr_splice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    removed := new_array(vm)
    a, ok := this.(^Array); if !ok do return removed
    n := len(a.items)
    start := len(args) >= 1 ? idx_from(as_number(args[0]), n) : 0
    delc := n - start
    if len(args) >= 2 {
        delc = as_int(args[1])
        if delc < 0 do delc = 0
        if delc > n - start do delc = n - start
    }
    nova: [dynamic]Value
    for i := 0; i < start; i += 1 do append(&nova, a.items[i])
    for i := 2; i < len(args); i += 1 do append(&nova, args[i])
    for i := start; i < start + delc; i += 1 do append(&removed.items, a.items[i])
    for i := start + delc; i < n; i += 1 do append(&nova, a.items[i])
    delete(a.items)
    a.items = nova
    return removed
}

// ── métodos de String ───────────────────────────────────────────────────────
// (indexação por CODE POINT — ver helpers str_r* no topo; M58)

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
    if ch := str_rune_at(s, i); ch != "" {
        r, _ := utf8.decode_rune(ch)
        return f64(r)
    }
    // índice na 2ª metade de um par: a spec devolve o low surrogate isolado
    u, in_range := str_code_unit_at(s, i)
    if !in_range do return nil
    return f64(u)
}

@(private = "file")
str_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return f64(-1)
    sub, _ := arg(args, 0).(string)
    from := 0 // índice de RUNE
    if len(args) >= 2 && args[1] != nil { // fromIndex (clamp [0,n]; negativo→0)
        from = idx_from(as_number(args[1]), str_rlen(s))
        if as_number(args[1]) < 0 do from = 0 // indexOf NÃO conta do fim
    }
    bfrom := str_rbyte(s, from)
    i := strings.index(s[bfrom:], sub)
    return f64(i < 0 ? -1 : str_rindex(s, i + bfrom))
}

// ToString(v) da spec p/ os métodos de String que coagem argumentos: primitivos
// direto; um objeto invoca o seu toString() (próprio ou herdado de Object.prototype).
// Sem isto, `"a1".replace(1,"x")` ou `"x".includes({toString:()=>"x"})` viravam no-op.
@(private = "file")
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
    s, ok := this.(string); if !ok do return false
    sub := to_js_string(vm, arg(args, 0))
    if vm.throwing do return false
    n := str_rlen(s)
    pos := as_int(arg(args, 1)) // ToInteger; NaN/undefined → 0, true → 1
    if pos < 0 do pos = 0
    if pos > n do pos = n
    bpos := str_rbyte(s, pos)
    return strings.contains(s[bpos:], sub)
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
// start negativo conta do fim uma vez. Índices em CODE POINTS (convenção da engine).
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
                if gs >= 0 do strings.write_string(sb, s[gs:ge])
                i += 2
            case next == '`':
                gs := m.groups[0]
                if gs > 0 do strings.write_string(sb, s[:gs])
                i += 2
            case next == '\'':
                ge := m.groups[1]
                if ge >= 0 && ge <= len(s) do strings.write_string(sb, s[ge:])
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
                    if gs2 >= 0 do strings.write_string(sb, s[gs2:ge2])
                }
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
    append(&fargs, gs >= 0 ? own_str(vm, s[gs:ge]) : Value(nil))
    for g in 1 ..= re.ngroups {
        gs2, ge2 := m.groups[2 * g], m.groups[2 * g + 1]
        append(&fargs, gs2 >= 0 ? own_str(vm, s[gs2:ge2]) : Value(nil))
    }
    append(&fargs, f64(str_rindex(s, gs))) // offset em runes, como os índices do JS
    append(&fargs, Value(s))
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
        strings.write_string(&sb, s[last:gs])
        if is_fn {
            write_replacer_result(vm, &sb, repl_fn, s, m, re)
        } else {
            write_replacement(&sb, repl_str, s, m, re)
        }
        last = ge
        if !all do break
        if ge == gs { // casamento vazio: avança 1 byte
            if ge < len(s) { strings.write_byte(&sb, s[ge]); last = ge + 1; start = ge + 1 }
            else do break
        } else { start = ge }
        if start > len(s) do break
    }
    strings.write_string(&sb, s[last:])
    return own_str(vm, strings.to_string(sb))
}

// replace(pattern, replacement) — regex com $-refs/função OU string (1ª ocorrência).
@(private = "file")
str_replace :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    pattern := arg(args, 0)
    replacement := arg(args, 1)

    if re, rok := pattern.(^Regex); rok {
        return regex_replace_impl(vm, s, re, replacement, re.global)
    }

    old := to_js_string(vm, pattern) // ToString(searchValue): `.replace(1,"x")`, {toString}
    if vm.throwing do return own_str(vm, s)

    if repl_fn, is_fn := replacement.(^Function); is_fn {
        idx := strings.index(s, old)
        if idx < 0 do return own_str(vm, s)
        rsb: strings.Builder
        strings.builder_init(&rsb); defer strings.builder_destroy(&rsb)
        strings.write_string(&rsb, s[:idx])
        result := call_function(vm, repl_fn, nil, []Value{own_str(vm, old), f64(idx), Value(s)})
        to_text(&rsb, result)
        strings.write_string(&rsb, s[idx + len(old):])
        return own_str(vm, strings.to_string(rsb))
    }

    nw := to_js_string(vm, replacement) // ToString(replaceValue): número/bool viram texto
    if vm.throwing do return own_str(vm, s)
    if strings.contains(nw, "$") { // $-refs ($& $$ $` $') com pattern string
        idx := strings.index(s, old)
        if idx < 0 do return own_str(vm, s)
        sb: strings.Builder
        strings.builder_init(&sb); defer strings.builder_destroy(&sb)
        strings.write_string(&sb, s[:idx])
        write_str_replacement(&sb, nw, s, idx, len(old))
        strings.write_string(&sb, s[idx + len(old):])
        return own_str(vm, strings.to_string(sb))
    }
    res, allocated := strings.replace(s, old, nw, 1)
    return allocated ? own_taken(vm, res) : own_str(vm, res)
}

// $-refs de replacement com pattern STRING (sem grupos): $$ → $, $& → casado,
// $` → antes, $' → depois; $1..$9 ficam LITERAIS (spec: sem capturas).
@(private = "file")
write_str_replacement :: proc(sb: ^strings.Builder, repl: string, s: string, idx: int, old_len: int) {
    i := 0
    for i < len(repl) {
        if repl[i] == '$' && i + 1 < len(repl) {
            switch repl[i + 1] {
            case '$':  strings.write_byte(sb, '$');                    i += 2; continue
            case '&':  strings.write_string(sb, s[idx:idx + old_len]); i += 2; continue
            case '`':  strings.write_string(sb, s[:idx]);              i += 2; continue
            case '\'': strings.write_string(sb, s[idx + old_len:]);    i += 2; continue
            }
        }
        strings.write_byte(sb, repl[i])
        i += 1
    }
}

@(private = "file")
str_replace_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    pattern := arg(args, 0)

    if re, rok := pattern.(^Regex); rok {
        if !re.global {
            vm.thrown = mk_error(vm, "TypeError", "replaceAll com regex exige flag global")
            vm.throwing = true
            return own_str(vm, s)
        }
        return regex_replace_impl(vm, s, re, arg(args, 1), true)
    }

    old := to_js_string(vm, pattern) // ToString(searchValue)
    if vm.throwing do return own_str(vm, s)
    if old == "" do return own_str(vm, s)
    nw := to_js_string(vm, arg(args, 1)) // ToString(replaceValue)
    if vm.throwing do return own_str(vm, s)
    res, allocated := strings.replace_all(s, old, nw)
    return allocated ? own_taken(vm, res) : own_str(vm, res)
}

@(private = "file")
str_starts_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return false
    p, pok := arg(args, 0).(string)
    return pok && strings.has_prefix(s, p)
}

@(private = "file")
str_ends_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return false
    p, pok := arg(args, 0).(string)
    return pok && strings.has_suffix(s, p)
}

// padStart/padEnd (por bytes; pad padrão = espaço).
@(private = "file")
str_pad :: proc(vm: ^Interp, this: Value, args: []Value, at_start: bool) -> Value {
    s, ok := this.(string); if !ok do return own_str(vm, "")
    want := as_int(arg(args, 0)) // comprimento-alvo em RUNES
    pad := " "
    if p, pok := arg(args, 1).(string); pok && p != "" do pad = p
    n := str_rlen(s)
    if want <= n do return own_str(vm, s)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    fill := want - n
    pr := utf8.string_to_runes(pad, context.temp_allocator)
    if !at_start do strings.write_string(&sb, s)
    for i := 0; i < fill; i += 1 do strings.write_rune(&sb, pr[i % len(pr)])
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

@(private = "file")
str_split :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_array(vm)
    s, ok := this.(string); if !ok do return res
    sep_val := arg(args, 0)
    limit := -1
    if len(args) >= 2 { if lv, lok := args[1].(f64); lok do limit = int(lv) }

    if re, rok := sep_val.(^Regex); rok {
        // string vazia (spec 21.1.3.21 passo 12): se o regex casa "" → []; senão [""]
        if len(s) == 0 {
            m := regex_run(re, s, 0)
            defer delete(m.groups)
            if !m.ok do append(&res.items, own_str(vm, ""))
            return res
        }
        last := 0  // p: início do segmento não-casado
        start := 0 // q: posição de busca
        // laço só ENQUANTO start < len(s) (spec: q < size — não processa match em len(s))
        for (limit < 0 || len(res.items) < limit) && start < len(s) {
            m := regex_run(re, s, start)
            if !m.ok do break
            defer delete(m.groups)
            gs, ge := m.groups[0], m.groups[1]
            // match VAZIO no início do segmento (e == p): pula sem cortar (spec)
            if gs == ge && gs == last { start = gs + 1; continue }
            append(&res.items, own_str(vm, s[last:gs]))
            for g in 1 ..= re.ngroups {
                gs2, ge2 := m.groups[2 * g], m.groups[2 * g + 1]
                if gs2 >= 0 { append(&res.items, own_str(vm, s[gs2:ge2])) } else { append(&res.items, nil) }
            }
            last = ge
            start = ge == gs ? ge + 1 : ge // match vazio: avança 1 p/ não travar
        }
        if limit < 0 || len(res.items) < limit do append(&res.items, own_str(vm, s[last:]))
        return res
    }

    sep, has_sep := sep_val.(string)
    if !has_sep {
        append(&res.items, own_str(vm, s))
        return res
    }
    if sep == "" { // separa por CODE POINTS ('café' → c,a,f,é)
        for i := 0; i < len(s); {
            if limit >= 0 && len(res.items) >= limit do break
            _, w := utf8.decode_rune(s[i:])
            append(&res.items, own_str(vm, s[i:i + w]))
            i += w
        }
        return res
    }
    parts := strings.split(s, sep)
    defer delete(parts)
    for p in parts {
        if limit >= 0 && len(res.items) >= limit do break
        append(&res.items, own_str(vm, p))
    }
    return res
}

// match(regex) — sem g: [match, g1, ...] ou null; com g: [match1, match2, ...] ou null.
@(private = "file")
str_match :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return JS_Null{}
    re: ^Regex
    if r, rok := arg(args, 0).(^Regex); rok {
        re = r
    } else {
        pat := ""
        if p, pok := arg(args, 0).(string); pok do pat = p
        re2, cok := regex_compile(vm, pat, "")
        if !cok do return JS_Null{}
        re = re2
    }
    if re.global {
        arr := new_array(vm)
        start := 0
        for {
            m := regex_run(re, s, start)
            if !m.ok do break
            defer delete(m.groups)
            gs, ge := m.groups[0], m.groups[1]
            append(&arr.items, own_str(vm, s[gs:ge]))
            if ge == gs { start = ge + 1 } else { start = ge }
            if start > len(s) do break
        }
        return len(arr.items) > 0 ? Value(arr) : Value(JS_Null{})
    }
    m := regex_run(re, s, 0)
    if !m.ok do return JS_Null{}
    defer delete(m.groups)
    return regex_result_array(vm, re, s, m)
}

// search(regex) — índice da primeira correspondência, ou -1.
@(private = "file")
str_search :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return f64(-1)
    re: ^Regex
    if r, rok := arg(args, 0).(^Regex); rok {
        re = r
    } else {
        pat := ""
        if p, pok := arg(args, 0).(string); pok do pat = p
        re2, cok := regex_compile(vm, pat, "")
        if !cok do return f64(-1)
        re = re2
    }
    m := regex_run(re, s, 0)
    if !m.ok do return f64(-1)
    defer delete(m.groups)
    return f64(str_rindex(s, m.groups[0])) // índice em runes
}

// matchAll(regex) — iterador de TODOS os matches, cada um com grupos/.index/
// .input/.groups (regex_result_array). Exige a flag g (spec); string compila
// com g implícito. Não mexe no lastIndex do regex original (spec clona).
@(private = "file")
str_match_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(string); if !ok do return make_array_iterator(vm, new_array(vm))
    re: ^Regex
    if r, rok := arg(args, 0).(^Regex); rok {
        if !r.global {
            throw_type_error(vm, "matchAll exige uma regex com a flag g")
            return nil
        }
        re = r
    } else {
        pat := ""
        if p, pok := arg(args, 0).(string); pok do pat = p
        re2, cok := regex_compile(vm, pat, "g")
        if !cok {
            vm.thrown = mk_error(vm, "SyntaxError", "matchAll: regex inválida")
            vm.throwing = true
            return nil
        }
        re = re2
    }
    out := new_array(vm)
    start := 0
    for {
        m := regex_run(re, s, start)
        if !m.ok do break
        defer delete(m.groups)
        append(&out.items, regex_result_array(vm, re, s, m))
        gs, ge := m.groups[0], m.groups[1]
        if ge == gs { // casamento vazio: avança uma RUNE inteira
            if ge >= len(s) do break
            _, w := utf8.decode_rune(s[ge:])
            start = ge + w
        } else {
            start = ge
        }
        if start > len(s) do break
    }
    return make_array_iterator(vm, out)
}

// localeCompare(b) — ordem por code point (sem colação de locale de verdade)
@(private = "file")
str_locale_compare :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(string); if !ok do return f64(0)
    b, _ := arg(args, 0).(string)
    if a < b do return f64(-1)
    if a > b do return f64(1)
    return f64(0)
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
    s, ok := this.(string); if !ok do return f64(-1)
    sub, _ := arg(args, 0).(string)
    b := strings.last_index(s, sub)
    return f64(b < 0 ? -1 : str_rindex(s, b))
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
    res := new_array(vm)
    v := arg(args, 0)
    mapfn, has_map := arg(args, 1).(^Function)
    #partial switch o in v {
    case ^Array:
        for it in o.items do append(&res.items, it)
    case string: // Array.from('café') → runas inteiras
        for i := 0; i < len(o); {
            _, w := utf8.decode_rune(o[i:])
            append(&res.items, own_str(vm, o[i:i + w]))
            i += w
        }
    case ^Collection:
        for &e in o.entries do append(&res.items, e.val)
    case ^Object:
        // iterável por protocolo (Symbol.iterator/iterador — inclui TypedArray);
        // senão trata como array-like (.length + índices, ex.: arguments, NodeList)
        tmp: [dynamic]Value; defer delete(tmp)
        if iterate_protocol(vm, o, &tmp) {
            for it in tmp do append(&res.items, it)
        } else {
            n := int(as_number(get_member(vm, o, "length")))
            for i in 0 ..< n do append(&res.items, get_member(vm, o, key_string(vm, f64(i))))
        }
    }
    if has_map { // Array.from(x, fn): mapeia cada elemento
        for &it, i in res.items {
            it = call_function(vm, mapfn, nil, []Value{it, f64(i)})
            if vm.throwing do break
        }
    }
    return res
}

// ── Array moderno (M59) ─────────────────────────────────────────────────────

@(private = "file")
arr_flatten_into :: proc(vm: ^Interp, src: ^Array, depth: int, out: ^Array) {
    for it in src.items {
        if sub, ok := it.(^Array); ok && depth > 0 {
            arr_flatten_into(vm, sub, depth - 1, out)
        } else {
            append(&out.items, it)
        }
    }
}

@(private = "file")
arr_flat :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return new_array(vm)
    depth := 1
    if len(args) >= 1 && args[0] != nil {
        d := as_number(args[0])
        depth = d == math.inf_f64(1) ? 1 << 30 : as_int(args[0])
    }
    out := new_array(vm)
    arr_flatten_into(vm, a, depth, out)
    return out
}

@(private = "file")
arr_flat_map :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return new_array(vm)
    fn, fok := arg(args, 0).(^Function); if !fok do return new_array(vm)
    out := new_array(vm)
    for it, i in a.items {
        r := call_function(vm, fn, nil, []Value{it, f64(i), a})
        if vm.throwing do break
        if sub, sok := r.(^Array); sok {
            for v in sub.items do append(&out.items, v) // achata só 1 nível (spec)
        } else {
            append(&out.items, r)
        }
    }
    return out
}

@(private = "file")
arr_fill :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return this
    v := arg(args, 0)
    n := len(a.items)
    start := len(args) >= 2 && args[1] != nil ? idx_from(as_number(args[1]), n) : 0
    end   := len(args) >= 3 && args[2] != nil ? idx_from(as_number(args[2]), n) : n
    for i := start; i < end; i += 1 do a.items[i] = v
    return a
}

@(private = "file")
arr_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, is_arr := this.(^Array)
    n := is_arr ? len(a.items) : array_like_len(vm, this) // array-like: ver arr_index_of
    i := as_int(arg(args, 0))
    if i < 0 do i += n
    if i < 0 || i >= n do return nil
    return is_arr ? a.items[i] : array_like_get(vm, this, i)
}

@(private = "file")
arr_find_last :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return nil
    fn, fok := arg(args, 0).(^Function); if !fok do return nil
    for i := len(a.items) - 1; i >= 0; i -= 1 {
        r := call_function(vm, fn, nil, []Value{a.items[i], f64(i), a})
        if vm.throwing do return nil
        if truthy(r) do return a.items[i]
    }
    return nil
}

@(private = "file")
arr_find_last_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return f64(-1)
    fn, fok := arg(args, 0).(^Function); if !fok do return f64(-1)
    for i := len(a.items) - 1; i >= 0; i -= 1 {
        r := call_function(vm, fn, nil, []Value{a.items[i], f64(i), a})
        if vm.throwing do return f64(-1)
        if truthy(r) do return f64(i)
    }
    return f64(-1)
}

@(private = "file")
arr_copy_within :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array); if !ok do return this
    n := len(a.items)
    tgt   := len(args) >= 1 && args[0] != nil ? idx_from(as_number(args[0]), n) : 0
    start := len(args) >= 2 && args[1] != nil ? idx_from(as_number(args[1]), n) : 0
    end   := len(args) >= 3 && args[2] != nil ? idx_from(as_number(args[2]), n) : n
    if start >= end do return a
    tmp := make([]Value, end - start, context.temp_allocator)
    copy(tmp, a.items[start:end])
    for v, k in tmp {
        if tgt + k >= n do break
        a.items[tgt + k] = v
    }
    return a
}

// keys()/values()/entries() — iteradores (reusa make_array_iterator sobre um
// snapshot; suficiente p/ `for..of arr.entries()`)
@(private = "file")
arr_keys_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    ks := new_array(vm)
    for i := 0; i < arr_iter_len(vm, this); i += 1 do append(&ks.items, f64(i))
    return make_array_iterator(vm, ks)
}

// `values` é também o Symbol.iterator de Array.prototype (ver install), e é ele que
// a coleção viva do DOM empresta: sem o caminho array-like, `[...el.children]` e
// `for (x of el.children)` iteravam ZERO elemento sem lançar nada.
@(private = "file")
arr_values_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, is_arr := this.(^Array)
    vs := new_array(vm)
    if is_arr {
        for it in a.items do append(&vs.items, it)
    } else {
        n := array_like_len(vm, this)
        for i := 0; i < n; i += 1 do append(&vs.items, array_like_get(vm, this, i))
    }
    return make_array_iterator(vm, vs)
}

@(private = "file")
arr_entries_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, is_arr := this.(^Array)
    es := new_array(vm)
    n := is_arr ? len(a.items) : array_like_len(vm, this)
    for i := 0; i < n; i += 1 {
        pair := new_array(vm)
        append(&pair.items, f64(i), is_arr ? a.items[i] : array_like_get(vm, this, i))
        append(&es.items, pair)
    }
    return make_array_iterator(vm, es)
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
        for _, i in s do append(&starts, i)
        append(&starts, len(s))
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
                return a // comprimento inválido: array vazio (JS lançaria RangeError)
            }
            count := int(n)
            for i := 0; i < count; i += 1 do append(&a.items, nil) // slots = undefined
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
    return to_number(vm, arg(args, 0)) // ToNumber da spec: Number(new Date) = timestamp
}

// Boolean(x): ToBoolean. Estava FALTANDO como global (`typeof Boolean` == undefined),
// o que quebrava o idioma onipresente `arr.filter(Boolean)` p/ remover falsy —
// 7 sites no gap-report caíam em "Boolean is not a function".
global_boolean_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return truthy(arg(args, 0))
}

// Boolean.prototype.toString / .valueOf. `this` é o próprio booleano: não temos
// wrapper-object para Boolean (`new Boolean(x)` devolve o primitivo), então o
// `.call(algumBooleano)` do padrão uncurryThis chega aqui com this: bool.
@(private = "file")
boolean_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return truthy(this) ? "true" : "false"
}

@(private = "file")
boolean_value_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return truthy(this)
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
        strings.write_rune(&sb, rune(u))
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
    for a in args do strings.write_rune(&sb, rune(as_int(a)))
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
global_string_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    v := arg(args, 0)
    if v == nil do return own_str(vm, "undefined")
    if _, isNull := v.(JS_Null); isNull do return own_str(vm, "null")
    sb: strings.Builder
    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    write_text_spec(&sb, vm, v) // String([1,2]) === "1,2", não o texto de debug
    if vm.throwing do return nil
    return own_str(vm, strings.to_string(sb))
}

// (Date virou objeto completo em date.odin — M59)

// ── métodos de Number (this = f64; despachados por get_member case f64) ─────

@(private = "file")
num_to_fixed :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this.(f64); if !ok do return own_str(vm, "NaN")
    d := as_int(arg(a, 0))
    if d < 0 do d = 0
    if d > 100 do d = 100
    return own_str(vm, fmt.tprintf("%.*f", d, x))
}

@(private = "file")
num_to_precision :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this.(f64); if !ok do return own_str(vm, "NaN")
    if arg(a, 0) == nil do return num_to_string(vm, this, nil) // sem arg = toString
    p := as_int(a[0])
    if p < 1 do p = 1
    if p > 100 do p = 100
    return own_str(vm, fmt.tprintf("%.*g", p, x))
}

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
@(private = "file") math_round  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := as_number(arg(a, 0))
    if x != x || math.trunc(x) == x do return x // NaN/inteiro/±inf: intactos
    return math.floor(x + 0.5)
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
    if ms, sok := msg.(string); sok && ms != "" {
        o.props["stack"] = own_str(vm, fmt.tprintf("%s: %s", name, ms)) // mínimo, sem frames
    } else {
        o.props["stack"] = name
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

@(private = "file")
install_errors :: proc(vm: ^Interp) {
    vm.error_protos = make(map[string]^Object)
    base := new_object(vm)
    base.props["name"] = "Error"
    base.props["message"] = ""
    base.props["toString"] = mk_native(vm, err_to_string)
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
            k := structured_clone_val(vm, e.key, memo); if vm.throwing do return nil
            val := structured_clone_val(vm, e.val, memo); if vm.throwing do return nil
            append(&nc.entries, Coll_Entry{key = k, val = val})
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
        own_enum_keys(x, &keys)
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

    vm.array_methods["push"]      = mk_native(vm, arr_push)
    vm.array_methods["pop"]       = mk_native(vm, arr_pop)
    vm.array_methods["indexOf"]   = mk_native(vm, arr_index_of)
    vm.array_methods["includes"]  = mk_native(vm, arr_includes)
    vm.array_methods["join"]      = mk_native(vm, arr_join)
    vm.array_methods["toString"]  = mk_native(vm, arr_join) // Array.prototype.toString = join(",") (aprox. spec)
    vm.array_methods["slice"]     = mk_native(vm, arr_slice)
    vm.array_methods["forEach"]   = mk_native(vm, arr_for_each)
    vm.array_methods["map"]       = mk_native(vm, arr_map)
    vm.array_methods["filter"]    = mk_native(vm, arr_filter)
    vm.array_methods["reverse"]   = mk_native(vm, arr_reverse)
    vm.array_methods["sort"]      = mk_native(vm, arr_sort)
    vm.array_methods["reduce"]    = mk_native(vm, arr_reduce)
    vm.array_methods["reduceRight"] = mk_native(vm, arr_reduce_right)
    vm.array_methods["concat"]    = mk_native(vm, arr_concat)
    vm.array_methods["find"]      = mk_native(vm, arr_find)
    vm.array_methods["findIndex"] = mk_native(vm, arr_find_index)
    vm.array_methods["some"]      = mk_native(vm, arr_some)
    vm.array_methods["every"]     = mk_native(vm, arr_every)
    vm.array_methods["shift"]     = mk_native(vm, arr_shift)
    vm.array_methods["unshift"]   = mk_native(vm, arr_unshift)
    vm.array_methods["splice"]    = mk_native(vm, arr_splice)
    vm.array_methods["flat"]          = mk_native(vm, arr_flat)
    vm.array_methods["flatMap"]       = mk_native(vm, arr_flat_map)
    vm.array_methods["fill"]          = mk_native(vm, arr_fill)
    vm.array_methods["at"]            = mk_native(vm, arr_at)
    vm.array_methods["findLast"]      = mk_native(vm, arr_find_last)
    vm.array_methods["findLastIndex"] = mk_native(vm, arr_find_last_index)
    vm.array_methods["copyWithin"]    = mk_native(vm, arr_copy_within)
    // Change Array by Copy (ES2023) — ver o bloco acima do arr_splice
    vm.array_methods["toReversed"]    = mk_native(vm, arr_to_reversed)
    vm.array_methods["toSorted"]      = mk_native(vm, arr_to_sorted)
    vm.array_methods["toSpliced"]     = mk_native(vm, arr_to_spliced)
    vm.array_methods["with"]          = mk_native(vm, arr_with)
    vm.array_methods["keys"]          = mk_native(vm, arr_keys_iter)
    vm.array_methods["values"]        = mk_native(vm, arr_values_iter)
    vm.array_methods["entries"]       = mk_native(vm, arr_entries_iter)

    // métodos de Number ((3.14).toFixed(2) etc.; get_member case f64)
    vm.number_methods = make(map[string]^Function)
    vm.number_methods["toFixed"]        = mk_native(vm, num_to_fixed)
    vm.number_methods["toString"]       = mk_native(vm, num_to_string)
    vm.number_methods["toPrecision"]    = mk_native(vm, num_to_precision)
    vm.number_methods["toLocaleString"] = mk_native(vm, num_to_string) // aproximação sem separadores
    vm.number_methods["valueOf"]        = mk_native(vm, num_value_of)

    vm.string_methods["charAt"]      = mk_native(vm, str_char_at)
    vm.string_methods["charCodeAt"]  = mk_native(vm, str_char_code_at)
    vm.string_methods["indexOf"]     = mk_native(vm, str_index_of)
    vm.string_methods["includes"]    = mk_native(vm, str_includes)
    vm.string_methods["slice"]       = mk_native(vm, str_slice)
    vm.string_methods["substring"]   = mk_native(vm, str_substring)
    vm.string_methods["substr"]      = mk_native(vm, str_substr)
    vm.string_methods["toString"]    = mk_native(vm, str_identity)
    vm.string_methods["valueOf"]     = mk_native(vm, str_identity)
    vm.string_methods["toUpperCase"] = mk_native(vm, str_to_upper)
    vm.string_methods["toLowerCase"] = mk_native(vm, str_to_lower)
    vm.string_methods["trim"]        = mk_native(vm, str_trim)
    vm.string_methods["repeat"]      = mk_native(vm, str_repeat)
    vm.string_methods["concat"]       = mk_native(vm, str_concat)
    vm.string_methods["split"]        = mk_native(vm, str_split)
    vm.string_methods["replace"]      = mk_native(vm, str_replace)
    vm.string_methods["replaceAll"]   = mk_native(vm, str_replace_all)
    vm.string_methods["startsWith"]   = mk_native(vm, str_starts_with)
    vm.string_methods["endsWith"]     = mk_native(vm, str_ends_with)
    vm.string_methods["padStart"]     = mk_native(vm, str_pad_start)
    vm.string_methods["padEnd"]       = mk_native(vm, str_pad_end)
    vm.string_methods["match"]        = mk_native(vm, str_match)
    vm.string_methods["search"]       = mk_native(vm, str_search)
    vm.string_methods["lastIndexOf"]  = mk_native(vm, str_last_index_of)
    vm.string_methods["trimStart"]    = mk_native(vm, str_trim_start)
    vm.string_methods["trimEnd"]      = mk_native(vm, str_trim_end)
    vm.string_methods["at"]           = mk_native(vm, str_at)
    vm.string_methods["matchAll"]      = mk_native(vm, str_match_all)
    vm.string_methods["codePointAt"]   = mk_native(vm, str_code_point_at) // ≠ charCodeAt desde o M167
    vm.string_methods["localeCompare"] = mk_native(vm, str_locale_compare)
    vm.string_methods["normalize"]     = mk_native(vm, str_normalize)

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
    arr_ctor.props["from"]    = mk_native(vm, arr_from)
    arr_ctor.props["isArray"] = mk_native(vm, arr_is_array)
    arr_ctor.props["of"]      = mk_native(vm, arr_of)
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

    str_proto := new_object(vm)
    for k, fn in vm.string_methods do str_proto.props[k] = fn
    str_proto.props["constructor"] = str_ctor
    str_ctor.props["prototype"] = str_proto

    arr_proto := new_object(vm)
    for k, fn in vm.array_methods do arr_proto.props[k] = fn
    arr_proto.props["constructor"] = arr_ctor
    arr_ctor.props["prototype"] = arr_proto

    // Boolean ficou de fora deste bloco: não tinha .prototype NEM métodos, então
    // `true.toString()` lançava e `Boolean.prototype.valueOf` era undefined. O helper
    // _createSuper do Babel usa exatamente `Boolean.prototype.valueOf.call(
    // Reflect.construct(Boolean,[],function(){}))` para detectar Reflect.construct
    // nativo — falhando o detect, o bundle cai no caminho degradado (ver M127).
    vm.boolean_methods = make(map[string]^Function)
    vm.boolean_methods["toString"] = mk_native(vm, boolean_to_string)
    vm.boolean_methods["valueOf"]  = mk_native(vm, boolean_value_of)
    bool_proto := new_object(vm)
    for k, fn in vm.boolean_methods do bool_proto.props[k] = fn
    bool_proto.props["constructor"] = bool_ctor
    bool_ctor.props = make(map[string]Value)
    bool_ctor.props["prototype"] = bool_proto

    install_date(vm) // Date completo (date.odin)

    install_errors(vm) // Error/TypeError/... com prototypes reais (instanceof)

    // timers (o hospedeiro dispara via vm_pump_timers a cada frame)
    env_define(vm.global, "queueMicrotask", mk_native(vm, global_queue_microtask))
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
