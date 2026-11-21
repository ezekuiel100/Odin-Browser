package js

import "core:strings"
import dom "../dom"

// Keep CSSOM rules connected to their <style> owner. Mutations update the DOM
// used by the style collector, rather than merely making feature detection pass.
install_stylesheets :: proc(vm: ^Interp) {
    ctor := mk_native(vm, stylesheet_ctor)
    ctor.name = "CSSStyleSheet"
    ctor.props = make(map[string]Value)
    p := new_object(vm)
    p.props["constructor"] = ctor
    for m in ([]struct{name: string, fn: Native_Fn}{
        {"insertRule", stylesheet_insert}, {"deleteRule", stylesheet_delete},
    }) {
        p.props[m.name] = mk_native(vm, m.fn)
        mark_non_enumerable(p, m.name)
    }
    ctor.props["prototype"] = p
    env_define(vm.global, "CSSStyleSheet", ctor)
}

stylesheet_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return make_stylesheet(vm, nil)
}

make_stylesheet :: proc(vm: ^Interp, owner: ^Object) -> ^Object {
    s := new_object(vm)
    ctor, _ := env_get(vm.global, "CSSStyleSheet")
    s.proto = ctor.(^Function).props["prototype"].(^Object)
    s.get = stylesheet_get
    s.props["ownerNode"] = JS_Null{} if owner == nil else Value(owner)
    s.props["#rules"] = new_array(vm)
    s.props["#source"] = ""
    return s
}

element_stylesheet :: proc(vm: ^Interp, owner: ^Object) -> ^Object {
    if s, ok := owner.props["#sheet"].(^Object); ok do return s
    s := make_stylesheet(vm, owner)
    owner.props["#sheet"] = s
    return s
}

// Split only at top-level rule boundaries, respecting strings and comments.
// This also keeps @media/keyframes and data URLs intact.
stylesheet_split :: proc(vm: ^Interp, text: string, valid: ^bool = nil) -> ^Array {
    rules := new_array(vm)
    start, depth, parens := 0, 0, 0
    quote: u8
    comment := false
    leading_comment := false
    for i := 0; i < len(text); i += 1 {
        c := text[i]
        if comment {
            if c == '*' && i+1 < len(text) && text[i+1] == '/' {
                comment = false; i += 1
                if leading_comment do start = i+1
            }
            continue
        }
        if quote != 0 {
            if c == '\\' { i += 1 } else if c == quote { quote = 0 }
            continue
        }
        if c == '/' && i+1 < len(text) && text[i+1] == '*' {
            leading_comment = depth == 0 && parens == 0 && strings.trim_space(text[start:i]) == ""
            comment = true; i += 1; continue
        }
        if c == '"' || c == '\'' { quote = c; continue }
        switch c {
        case '(': parens += 1
        case ')': parens -= 1
        case '{': if parens == 0 do depth += 1
        case '}': if parens == 0 do depth -= 1
        }
        if parens == 0 && depth == 0 && (c == '}' || c == ';') {
            source := strings.trim_space(text[start:i+1])
            if source != "" {
                r := new_object(vm)
                r.props["cssText"] = own_str(vm, source)
                append(&rules.items, r)
            }
            start = i+1
        }
    }
    if valid != nil do valid^ = depth == 0 && parens == 0 && quote == 0 && !comment && strings.trim_space(text[start:]) == ""
    return rules
}

stylesheet_rules :: proc(vm: ^Interp, s: ^Object) -> ^Array {
    if owner, ok := s.props["ownerNode"].(^Object); ok && owner.host != nil {
        b := strings.builder_make(context.temp_allocator)
        dom.text_content((^dom.Node)(owner.host), &b)
        text := strings.to_string(b)
        if old, _ := s.props["#source"].(string); old != text {
            fresh := stylesheet_split(vm, text)
            rules := s.props["#rules"].(^Array)
            clear(&rules.items)
            append(&rules.items, ..fresh.items[:])
            s.props["#source"] = own_str(vm, text)
        }
    }
    return s.props["#rules"].(^Array)
}

stylesheet_get :: proc(vm: ^Interp, s: ^Object, name: string) -> (Value, bool) {
    if name == "cssRules" || name == "rules" do return stylesheet_rules(vm, s), true
    return nil, false
}

stylesheet_error :: proc(vm: ^Interp, name: string) -> Value {
    vm.throwing = true
    vm.thrown = mk_error(vm, name, "Invalid stylesheet rule or index")
    return nil
}

stylesheet_sync :: proc(vm: ^Interp, s: ^Object, rules: ^Array) {
    if owner, ok := s.props["ownerNode"].(^Object); ok && owner.host != nil {
        b := strings.builder_make(context.temp_allocator)
        for v in rules.items {
            r := v.(^Object)
            text, _ := r.props["cssText"].(string)
            strings.write_string(&b, text)
            strings.write_byte(&b, '\n')
        }
        text := own_str(vm, strings.to_string(b))
        owner.set(vm, owner, "textContent", text)
        s.props["#source"] = text
        vm.cssom_revision += 1
    }
}

stylesheet_insert :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(^Object)
    if !ok do return stylesheet_error(vm, "TypeError")
    rules := stylesheet_rules(vm, s)
    index := as_int(arg(args, 1))
    if index < 0 || index > len(rules.items) do return stylesheet_error(vm, "IndexSizeError")
    b := strings.builder_make(context.temp_allocator)
    write_text_spec(&b, vm, arg(args, 0))
    text := strings.to_string(b)
    valid := false
    parsed := stylesheet_split(vm, text, &valid)
    if !valid || len(parsed.items) != 1 do return stylesheet_error(vm, "SyntaxError")
    source := parsed.items[0].(^Object).props["cssText"].(string)
    if source[0] != '@' && source[len(source)-1] != '}' do return stylesheet_error(vm, "SyntaxError")
    append(&rules.items, nil)
    for i := len(rules.items)-1; i > index; i -= 1 do rules.items[i] = rules.items[i-1]
    rules.items[index] = parsed.items[0]
    stylesheet_sync(vm, s, rules)
    return f64(index)
}

stylesheet_delete :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s, ok := this.(^Object)
    if !ok do return stylesheet_error(vm, "TypeError")
    rules := stylesheet_rules(vm, s)
    index := as_int(arg(args, 0))
    if index < 0 || index >= len(rules.items) do return stylesheet_error(vm, "IndexSizeError")
    ordered_remove(&rules.items, index)
    stylesheet_sync(vm, s, rules)
    return nil
}
