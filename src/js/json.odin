package js

// JSON.parse / JSON.stringify.
//
// parse: descida recursiva sobre o texto JSON; erros LANÇAM (capturáveis com
// try/catch). Strings novas viram owned_strings do vm.
// stringify: undefined/função somem em objetos e viram null em arrays (como no
// JS); estrutura circular lança.

import "core:math"
import "core:strconv"
import "core:strings"

install_json :: proc(vm: ^Interp) {
    j := new_object(vm)
    j.props["parse"]     = mk_native(vm, json_parse_native)
    j.props["stringify"] = mk_native(vm, json_stringify_native)
    j.props["#class"]    = "[object JSON]" // Object.prototype.toString.call(JSON)
    env_define(vm.global, "JSON", j)
}

// ── stringify ───────────────────────────────────────────────────────────────

// Estado de uma chamada de JSON.stringify (spec 25.5.2: ReplacerFunction,
// PropertyList, gap e a pilha de ciclo).
@(private = "file")
Json_Out :: struct {
    vm:        ^Interp,
    sb:        strings.Builder,
    seen:      map[rawptr]bool,
    replacer:  ^Function,        // 2º arg função: chamado em TODA propriedade, holder como this
    plist:     [dynamic]string,  // 2º arg array: só essas chaves, nessa ordem (sem repetição)
    has_plist: bool,
    indent:    string,
}

@(private) // visivel no pacote: fetch_api.odin reusa p/ Response.json()
json_stringify_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := Json_Out{vm = vm}
    strings.builder_init(&st.sb)
    defer strings.builder_destroy(&st.sb)
    defer delete(st.seen)
    defer delete(st.plist)
    // 2º arg (replacer): função, ou lista de chaves. Antes era IGNORADO por inteiro —
    // `JSON.stringify(o, ['a'])` e `JSON.stringify(o, (k,v)=>…)` saíam iguais a sem ele.
    #partial switch r in arg(args, 1) {
    case ^Function:
        st.replacer = r
    case ^Array:
        st.has_plist = true
        for it in r.items {
            k: string
            #partial switch x in it {
            case string: k = x
            case f64:    k = own_str_raw(vm, key_string(vm, x)) // [1] lista a chave "1"
            case:        continue // demais tipos são ignorados (spec)
            }
            dup := false
            for e in st.plist do if e == k { dup = true; break }
            if !dup do append(&st.plist, k)
        }
    }
    // 3º arg (space): número (0-10 espaços) ou string (até 10 chars) → pretty-print
    spaces := "          " // 10 espaços (máximo da spec)
    #partial switch sp in arg(args, 2) {
    case f64:
        n := as_int(sp)
        if n > 10 do n = 10
        if n > 0 do st.indent = spaces[:n]
    case string:
        st.indent = len(sp) > 10 ? sp[:10] : sp
    }
    v := arg(args, 0)
    // o replacer recebe o objeto-holder como `this`: no topo, a spec cria `{"": v}`
    holder: Value = nil
    if st.replacer != nil {
        w := new_object(vm)
        oput(w, "", v)
        holder = w
    }
    if !json_prop(&st, holder, "", v, 0) do return nil // undefined/função no topo → undefined
    if vm.throwing do return nil
    return own_str(vm, strings.to_string(st.sb))
}

// quebra de linha + indentação de `depth` níveis (só quando há indent)
@(private = "file")
json_nl_indent :: proc(sb: ^strings.Builder, indent: string, depth: int) {
    strings.write_byte(sb, '\n')
    for _ in 0 ..< depth do strings.write_string(sb, indent)
}

// A chave como valor JS para toJSON/replacer. Índice de array chega como f64 e só
// vira string quando alguém vai de fato recebê-la (evita alocar por elemento).
@(private = "file")
json_key_value :: proc(vm: ^Interp, key: Value) -> Value {
    if s, ok := key.(string); ok do return s
    return own_str(vm, key_string(vm, key))
}

// SerializeJSONProperty (spec 25.5.2.2): toJSON → replacer → escreve. Devolve false
// quando o valor final não é serializável (undefined, função, símbolo) e NADA foi
// escrito — o chamador decide: em objeto a chave some, em array vira null.
@(private = "file")
json_prop :: proc(st: ^Json_Out, holder: Value, key: Value, value: Value, depth: int) -> bool {
    vm := st.vm
    value := value
    // toJSON: consultado em objeto E em BigInt (BigInt.prototype.toJSON de polyfill).
    // Sem isto `JSON.stringify(new Date)` devolvia `{}`.
    _, is_big := value.(^BigInt)
    if !is_primitive(value) || is_big {
        if fn, ok := get_member(vm, value, "toJSON").(^Function); ok {
            value = call_function(vm, fn, value, []Value{json_key_value(vm, key)})
            if vm.throwing do return false
        }
    }
    if st.replacer != nil {
        value = call_function(vm, st.replacer, holder, []Value{json_key_value(vm, key), value})
        if vm.throwing do return false
    }
    // wrappers viram o primitivo (spec: ToNumber/ToString/[[BooleanData]]) —
    // `JSON.stringify(new String("a"))` é `"a"`, não `{}`
    if p, isw := wrapper_value(value); isw {
        #partial switch _ in p {
        case f64:
            value = to_number(vm, value)
        case string:
            value = to_primitive(vm, value, false, "string")
        case bool:
            value = p
        }
        if vm.throwing do return false
    }
    sb := &st.sb
    switch x in value {
    case:
        return false // undefined
    case ^Function, ^Symbol:
        return false
    case f64:
        if x != x || abs(x) == math.inf_f64(1) {
            strings.write_string(sb, "null") // NaN/Infinity viram null (como no JS)
        } else {
            to_text(sb, value)
        }
    case bool:
        to_text(sb, value)
    case string:
        json_write_quoted(sb, x)
    case JS_Null:
        strings.write_string(sb, "null")
    case ^Object:
        // subclasse de Array (M136): IsArray é true → serializa como array
        if a, isarr := x.prim.(^Array); isarr {
            json_array(st, x, a, depth)
        } else {
            json_object(st, x, depth)
        }
    case ^Array:
        if x.args != nil do json_object(st, x, depth) // `arguments` é objeto comum
        else do json_array(st, x, x, depth)
    case ^Regex, ^Collection:
        strings.write_string(sb, "{}") // sem props próprias enumeráveis: `{}` no JS
    case ^BigInt:
        // JSON.stringify(1n) LANÇA TypeError no JS
        vm.thrown = mk_error(vm, "TypeError", "Do not know how to serialize a BigInt")
        vm.throwing = true
    }
    return true
}

@(private = "file")
json_enter :: proc(st: ^Json_Out, p: rawptr) -> bool {
    if p in st.seen {
        st.vm.thrown = mk_error(st.vm, "TypeError", "Converting circular structure to JSON")
        st.vm.throwing = true
        return false
    }
    st.seen[p] = true
    return true
}

// SerializeJSONObject: valores lidos por Get (getters RODAM — antes chave de accessor
// era pulada e `{get a(){return 1}}` virava `{}`), na ordem de own_enum_keys ou da
// PropertyList.
@(private = "file")
json_object :: proc(st: ^Json_Out, x: Value, depth: int) {
    vm := st.vm
    // `x` é um ^Object ou o objeto `arguments` (^Array com args), que a spec
    // serializa como OBJETO: {"0":1,"1":2}, não [1,2]
    ptr: rawptr
    #partial switch v in x {
    case ^Object: ptr = v
    case ^Array:  ptr = v
    }
    if !json_enter(st, ptr) do return
    defer delete_key(&st.seen, ptr)
    sb := &st.sb
    strings.write_byte(sb, '{')
    keys: [dynamic]string
    defer delete(keys)
    if st.has_plist {
        for k in st.plist do append(&keys, k)
    } else if o, isobj := x.(^Object); isobj {
        own_enum_keys(vm, o, &keys)
    } else {
        own_keys_any(vm, x, &keys)
    }
    first := true
    for k in keys {
        pv := get_member(vm, x, k)
        if vm.throwing do return
        // escreve o prefixo já; se o valor não for serializável, desfaz até a marca
        mark := len(sb.buf)
        if !first do strings.write_byte(sb, ',')
        if st.indent != "" do json_nl_indent(sb, st.indent, depth + 1)
        json_write_quoted(sb, k)
        strings.write_byte(sb, ':')
        if st.indent != "" do strings.write_byte(sb, ' ')
        if !json_prop(st, x, k, pv, depth + 1) {
            if vm.throwing do return
            resize(&sb.buf, mark) // undefined/função/símbolo: a chave SOME
            continue
        }
        if vm.throwing do return
        first = false
    }
    if !first && st.indent != "" do json_nl_indent(sb, st.indent, depth)
    strings.write_byte(sb, '}')
}

// SerializeJSONArray: comprimento lido UMA vez (spec); `holder` é o valor JS do
// array (o próprio ^Array, ou a instância da subclasse) — é o `this` do replacer.
@(private = "file")
json_array :: proc(st: ^Json_Out, holder: Value, a: ^Array, depth: int) {
    vm := st.vm
    if !json_enter(st, rawptr(a)) do return
    defer delete_key(&st.seen, rawptr(a))
    sb := &st.sb
    strings.write_byte(sb, '[')
    n := len(a.items)
    for i in 0 ..< n {
        if i > 0 do strings.write_byte(sb, ',')
        if st.indent != "" do json_nl_indent(sb, st.indent, depth + 1)
        // o replacer pode encolher o array no meio: índice sumido lê undefined
        it: Value = i < len(a.items) ? a.items[i] : nil
        if !json_prop(st, holder, f64(i), it, depth + 1) {
            if vm.throwing do return
            strings.write_string(sb, "null") // undefined/função em array vira null
        }
        if vm.throwing do return
    }
    if n > 0 && st.indent != "" do json_nl_indent(sb, st.indent, depth)
    strings.write_byte(sb, ']')
}

// QuoteJSONString: todo controle < 0x20 é escapado (antes só \n \r \t — os demais
// saíam CRUS e o resultado era JSON INVÁLIDO, que o próprio JSON.parse rejeitava).
// ⚠️ surrogate solto não chega aqui: o lexer já o troca por U+FFFD ao montar a
// string, então o `\udXXX` da spec (well-formed stringify) não é reproduzível.
@(private = "file")
json_write_quoted :: proc(sb: ^strings.Builder, s: string) {
    HEX := "0123456789abcdef"
    strings.write_byte(sb, '"')
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        switch c {
        case '"':  strings.write_string(sb, "\\\"")
        case '\\': strings.write_string(sb, "\\\\")
        case '\b': strings.write_string(sb, "\\b")
        case '\f': strings.write_string(sb, "\\f")
        case '\n': strings.write_string(sb, "\\n")
        case '\r': strings.write_string(sb, "\\r")
        case '\t': strings.write_string(sb, "\\t")
        case 0x00 ..< 0x20:
            strings.write_string(sb, "\\u00")
            strings.write_byte(sb, HEX[c >> 4])
            strings.write_byte(sb, HEX[c & 0xF])
        case:
            strings.write_byte(sb, c)
        }
    }
    strings.write_byte(sb, '"')
}

// ── parse ───────────────────────────────────────────────────────────────────

@(private = "file")
Json_Reader :: struct {
    src: string,
    pos: int,
    err: bool,
}

@(private) // visivel no pacote: fetch.odin reusa p/ Response.json()
json_parse_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // spec: JSON.parse faz ToString no argumento (JSON.parse(true) → parseia "true").
    // key_string devolve a própria string se já for string; senão ToString via to_text.
    text := key_string(vm, arg(args, 0))
    r := Json_Reader{src = text}
    v := jp_value(vm, &r)
    jp_ws(&r)
    if r.err || r.pos < len(r.src) { // lixo após o valor também é erro
        // SyntaxError REAL (era string crua → assert.throws(SyntaxError) não casava)
        vm.thrown = mk_error(vm, "SyntaxError", "JSON.parse: JSON inválido")
        vm.throwing = true
        return nil
    }
    // reviver (2º arg): aplicado de baixo p/ cima; retorno undefined REMOVE a chave
    if fn, fok := arg(args, 1).(^Function); fok {
        return json_revive(vm, "", v, fn)
    }
    return v
}

@(private = "file")
json_revive :: proc(vm: ^Interp, key: string, val: Value, fn: ^Function) -> Value {
    #partial switch o in val {
    case ^Object:
        keys: [dynamic]string
        defer delete(keys)
        own_enum_keys(vm, o, &keys)
        for k in keys {
            pv, has := o.props[k]
            if !has do continue
            nv := json_revive(vm, k, pv, fn)
            if vm.throwing do return nil
            if nv == nil { oremove(o, k) } else { o.props[k] = nv }
        }
    case ^Array:
        buf: [24]u8
        for it, i in o.items {
            ks := strconv.write_int(buf[:], i64(i), 10)
            o.items[i] = json_revive(vm, ks, it, fn)
            if vm.throwing do return nil
        }
    }
    return call_function(vm, fn, nil, []Value{own_str(vm, key), val})
}

@(private = "file")
jp_ws :: proc(r: ^Json_Reader) {
    for r.pos < len(r.src) {
        c := r.src[r.pos]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            r.pos += 1
        } else {
            break
        }
    }
}

@(private = "file")
jp_lit :: proc(r: ^Json_Reader, lit: string) -> bool {
    if strings.has_prefix(r.src[r.pos:], lit) {
        r.pos += len(lit)
        return true
    }
    r.err = true
    return false
}

@(private = "file")
jp_value :: proc(vm: ^Interp, r: ^Json_Reader) -> Value {
    jp_ws(r)
    if r.pos >= len(r.src) {
        r.err = true
        return nil
    }
    switch r.src[r.pos] {
    case '{':
        return jp_object(vm, r)
    case '[':
        return jp_array(vm, r)
    case '"':
        return jp_string(vm, r)
    case 't':
        if jp_lit(r, "true") do return true
        return nil
    case 'f':
        if jp_lit(r, "false") do return false
        return nil
    case 'n':
        if jp_lit(r, "null") do return JS_Null{}
        return nil
    }
    return jp_number(r)
}

@(private = "file")
jp_object :: proc(vm: ^Interp, r: ^Json_Reader) -> Value {
    o := new_object(vm)
    r.pos += 1 // {
    jp_ws(r)
    if r.pos < len(r.src) && r.src[r.pos] == '}' {
        r.pos += 1
        return o
    }
    for {
        jp_ws(r)
        if r.pos >= len(r.src) || r.src[r.pos] != '"' {
            r.err = true
            return o
        }
        key_v := jp_string(vm, r)
        key, _ := key_v.(string)
        jp_ws(r)
        if r.pos >= len(r.src) || r.src[r.pos] != ':' {
            r.err = true
            return o
        }
        r.pos += 1 // :
        oput(o, key, jp_value(vm, r))
        if r.err do return o
        jp_ws(r)
        if r.pos < len(r.src) && r.src[r.pos] == ',' {
            r.pos += 1
            continue
        }
        if r.pos < len(r.src) && r.src[r.pos] == '}' {
            r.pos += 1
            return o
        }
        r.err = true
        return o
    }
}

@(private = "file")
jp_array :: proc(vm: ^Interp, r: ^Json_Reader) -> Value {
    a := new_array(vm)
    r.pos += 1 // [
    jp_ws(r)
    if r.pos < len(r.src) && r.src[r.pos] == ']' {
        r.pos += 1
        return a
    }
    for {
        append(&a.items, jp_value(vm, r))
        if r.err do return a
        jp_ws(r)
        if r.pos < len(r.src) && r.src[r.pos] == ',' {
            r.pos += 1
            continue
        }
        if r.pos < len(r.src) && r.src[r.pos] == ']' {
            r.pos += 1
            return a
        }
        r.err = true
        return a
    }
}

@(private = "file")
jp_string :: proc(vm: ^Interp, r: ^Json_Reader) -> Value {
    r.pos += 1 // "
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for r.pos < len(r.src) {
        c := r.src[r.pos]
        if c == '"' {
            r.pos += 1
            return own_str(vm, strings.to_string(sb))
        }
        if c == '\\' && r.pos + 1 < len(r.src) {
            r.pos += 1
            e := r.src[r.pos]
            switch e {
            case '"':  strings.write_byte(&sb, '"')
            case '\\': strings.write_byte(&sb, '\\')
            case '/':  strings.write_byte(&sb, '/')
            case 'n':  strings.write_byte(&sb, '\n')
            case 'r':  strings.write_byte(&sb, '\r')
            case 't':  strings.write_byte(&sb, '\t')
            case 'b':  strings.write_byte(&sb, '\b')
            case 'f':  strings.write_byte(&sb, '\f')
            case 'u':
                if r.pos + 4 < len(r.src) {
                    if cp, ok := strconv.parse_int(r.src[r.pos + 1:r.pos + 5], 16); ok {
                        strings.write_rune(&sb, rune(cp))
                        r.pos += 4
                    } else {
                        r.err = true
                    }
                } else {
                    r.err = true
                }
            case:
                r.err = true
            }
            r.pos += 1
            continue
        }
        strings.write_byte(&sb, c)
        r.pos += 1
    }
    r.err = true // EOF sem fechar a aspa
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
jp_number :: proc(r: ^Json_Reader) -> Value {
    start := r.pos
    if r.pos < len(r.src) && (r.src[r.pos] == '-' || r.src[r.pos] == '+') do r.pos += 1
    for r.pos < len(r.src) {
        c := r.src[r.pos]
        if (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-' {
            r.pos += 1
        } else {
            break
        }
    }
    if r.pos == start {
        r.err = true
        return nil
    }
    n, ok := strconv.parse_f64(r.src[start:r.pos])
    if !ok {
        r.err = true
        return nil
    }
    return n
}
