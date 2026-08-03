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

@(private) // visivel no pacote: fetch_api.odin reusa p/ Response.json()
json_stringify_native :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    v := arg(args, 0)
    if !json_serializable(v) do return nil // stringify(undefined) -> undefined
    // 3º arg (space): número (0-10 espaços) ou string (até 10 chars) → pretty-print
    indent := ""
    spaces := "          " // 10 espaços (máximo da spec)
    #partial switch sp in arg(args, 2) {
    case f64:
        n := as_int(sp)
        if n > 10 do n = 10
        if n > 0 do indent = spaces[:n]
    case string:
        indent = len(sp) > 10 ? sp[:10] : sp
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    seen: map[rawptr]bool
    defer delete(seen)
    json_write(vm, &sb, v, &seen, indent, 0)
    if vm.throwing do return nil // circular
    return own_str(vm, strings.to_string(sb))
}

// quebra de linha + indentação de `depth` níveis (só quando há indent)
@(private = "file")
json_nl_indent :: proc(sb: ^strings.Builder, indent: string, depth: int) {
    strings.write_byte(sb, '\n')
    for _ in 0 ..< depth do strings.write_string(sb, indent)
}

@(private = "file")
json_serializable :: proc(v: Value) -> bool {
    if v == nil do return false // undefined
    if _, isf := v.(^Function); isf do return false
    return true
}

@(private = "file")
json_write :: proc(vm: ^Interp, sb: ^strings.Builder, v: Value, seen: ^map[rawptr]bool, indent := "", depth := 0) {
    v := v
    // toJSON: a spec consulta o hook ANTES de serializar. Sem isto,
    // `JSON.stringify(new Date)` devolvia `{}` em vez da string ISO — e todo payload
    // de API com data saía vazio (Date.prototype.toJSON já existia e funcionava).
    // Aplicado UMA vez aqui: o switch abaixo serializa o resultado direto, então um
    // toJSON que devolve `this` não recursiona (os FILHOS passam por json_write de
    // novo, que é o comportamento certo — cada um consulta o seu próprio toJSON).
    if !is_primitive(v) {
        if fn, ok := get_member(vm, v, "toJSON").(^Function); ok {
            v = call_function(vm, fn, v, nil)
            if vm.throwing do return
            if !json_serializable(v) {
                // toJSON devolveu undefined/função. A spec OMITE a chave; aqui o
                // chamador já escreveu o nome, então "null" é o mal menor.
                strings.write_string(sb, "null")
                return
            }
        }
    }
    switch x in v {
    case f64:
        if x != x || abs(x) == math.inf_f64(1) {
            strings.write_string(sb, "null") // NaN/Infinity viram null (como no JS)
        } else {
            to_text(sb, v)
        }
    case bool:
        to_text(sb, v)
    case string:
        json_write_quoted(sb, x)
    case JS_Null:
        strings.write_string(sb, "null")
    case ^Object:
        if rawptr(x) in seen^ {
            vm.thrown = mk_error(vm, "TypeError", "Converting circular structure to JSON")
            vm.throwing = true
            return
        }
        seen^[rawptr(x)] = true
        strings.write_byte(sb, '{')
        first := true
        keys: [dynamic]string // ordem de inserção (spec), não a do map do Odin
        defer delete(keys)
        own_enum_keys(x, &keys)
        for k in keys {
            pv, has := x.props[k]
            if !has do continue // chave só-getter: sem valor de dado p/ serializar
            if !json_serializable(pv) do continue // undefined/função somem
            if !first do strings.write_byte(sb, ',')
            first = false
            if indent != "" do json_nl_indent(sb, indent, depth + 1)
            json_write_quoted(sb, k)
            strings.write_byte(sb, ':')
            if indent != "" do strings.write_byte(sb, ' ')
            json_write(vm, sb, pv, seen, indent, depth + 1)
            if vm.throwing do return
        }
        if !first && indent != "" do json_nl_indent(sb, indent, depth)
        strings.write_byte(sb, '}')
        delete_key(seen, rawptr(x))
    case ^Array:
        if rawptr(x) in seen^ {
            vm.thrown = mk_error(vm, "TypeError", "Converting circular structure to JSON")
            vm.throwing = true
            return
        }
        seen^[rawptr(x)] = true
        strings.write_byte(sb, '[')
        for it, i in x.items {
            if i > 0 do strings.write_byte(sb, ',')
            if indent != "" do json_nl_indent(sb, indent, depth + 1)
            if json_serializable(it) {
                json_write(vm, sb, it, seen, indent, depth + 1)
                if vm.throwing do return
            } else {
                strings.write_string(sb, "null") // undefined em array vira null
            }
        }
        if len(x.items) > 0 && indent != "" do json_nl_indent(sb, indent, depth)
        strings.write_byte(sb, ']')
        delete_key(seen, rawptr(x))
    case ^Function:
        // não serializável (filtrado antes); nada a escrever
    case ^Regex:
        strings.write_string(sb, "{}") // JSON.stringify(regex) === "{}" no JS
    case ^Collection:
        strings.write_string(sb, "{}") // JSON.stringify(new Map()/Set()) === "{}" no JS
    case ^Symbol:
        strings.write_string(sb, "null") // símbolo não é serializável (vira undefined→null aqui)
    case ^BigInt:
        // JSON.stringify(1n) LANÇA TypeError no JS
        vm.thrown = mk_error(vm, "TypeError", "Do not know how to serialize a BigInt")
        vm.throwing = true
    }
}

@(private = "file")
json_write_quoted :: proc(sb: ^strings.Builder, s: string) {
    strings.write_byte(sb, '"')
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        switch c {
        case '"':  strings.write_string(sb, "\\\"")
        case '\\': strings.write_string(sb, "\\\\")
        case '\n': strings.write_string(sb, "\\n")
        case '\r': strings.write_string(sb, "\\r")
        case '\t': strings.write_string(sb, "\\t")
        case:
            strings.write_byte(sb, c) // demais controles: mantidos crus (simplificação)
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
        own_enum_keys(o, &keys)
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
