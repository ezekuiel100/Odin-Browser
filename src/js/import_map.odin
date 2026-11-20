package js

// Import maps (HTML §8.1.5.3) — `<script type="importmap">`.
//
// Sem isto, `import "react"` (especificador NU) virava `resolve_url(base,
// "react")` = `…/assets/react`, 404, e o React inteiro do github.com morria:
// o bloco principal da home (servido com `style="opacity:0"` à espera da
// animação de entrada do React) ficava EM BRANCO.
//
// Cobre o algoritmo de resolução da spec: `imports` com casamento exato e por
// PREFIXO (chave terminada em "/"), `scopes` (o prefixo mais longo vence; o
// mapa do topo é o último recurso), normalização de chaves/valores do tipo URL
// contra a base do documento, entrada inválida que BLOQUEIA a resolução (em vez
// de cair na URL relativa) e a mesclagem de vários import maps (a 1ª definição
// vence). Fora: `integrity` (não verificamos SRI de módulo).

import "core:encoding/json"
import "core:slice"
import "core:strings"
import "base:runtime"
import net "../net"

Import_Map_Entry :: struct {
    key:     string, // especificador normalizado
    value:   string, // URL absoluta; "" se `blocked`
    blocked: bool,   // valor inválido: a spec manda FALHAR, não cair no fallback
}

Import_Map_Scope :: struct {
    prefix:  string, // URL absoluta do escopo
    imports: [dynamic]Import_Map_Entry,
}

Import_Map :: struct {
    imports: [dynamic]Import_Map_Entry, // ordem decrescente de chave (spec)
    scopes:  [dynamic]Import_Map_Scope, // ordem decrescente de prefixo (spec)
    alloc:   runtime.Allocator,         // dono de todas as strings acima
}

// Esquema de URL absoluta: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
@(private = "file")
has_url_scheme :: proc(s: string) -> bool {
    if len(s) < 2 do return false
    c0 := s[0]
    if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z')) do return false
    for i in 1 ..< len(s) {
        c := s[i]
        switch {
        case c == ':': return true
        case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'),
             c == '+', c == '-', c == '.':
        case: return false
        }
    }
    return false
}

// "Resolve a URL-like module specifier": só "/", "./", "../" ou URL absoluta.
// Especificador NU (`react`, `lodash/fp`) devolve ok=false. Resultado no temp.
@(private = "file")
resolve_url_like :: proc(spec, base: string) -> (string, bool) {
    if strings.has_prefix(spec, "/") || strings.has_prefix(spec, "./") || strings.has_prefix(spec, "../") {
        if base == "" do return "", false
        return net.resolve_url(base, spec, context.temp_allocator), true
    }
    if has_url_scheme(spec) do return spec, true
    return "", false
}

@(private = "file")
is_special_scheme :: proc(url: string) -> bool {
    for s in ([]string{"http:", "https:", "ftp:", "ws:", "wss:", "file:"}) {
        if len(url) >= len(s) && strings.equal_fold(url[:len(s)], s) do return true
    }
    return false
}

// "Sort and normalize a specifier map", MESCLANDO em `dst` (o que já existe vence).
@(private = "file")
merge_specifier_map :: proc(dst: ^[dynamic]Import_Map_Entry, obj: json.Object, base: string, a: runtime.Allocator) {
    for k, v in obj {
        if k == "" do continue
        key := k
        if u, ok := resolve_url_like(k, base); ok do key = u
        dup := false
        for e in dst do if e.key == key { dup = true; break }
        if dup do continue // spec (merge): definição anterior vence
        e := Import_Map_Entry{key = strings.clone(key, a)}
        s, is_str := v.(json.String)
        addr, ok := "", false
        if is_str do addr, ok = resolve_url_like(string(s), base)
        if !ok || (strings.has_suffix(k, "/") && !strings.has_suffix(addr, "/")) {
            e.blocked = true
        } else {
            e.value = strings.clone(addr, a)
        }
        append(dst, e)
    }
    // decrescente em code units: `react/` antes de `react`, mais específico antes
    slice.sort_by(dst[:], proc(x, y: Import_Map_Entry) -> bool { return x.key > y.key })
}

// Registra um `<script type="importmap">` (texto JSON) no vm. `base` = URL do
// documento. Devolve false se o JSON é inválido (a spec reporta e ignora).
import_map_register :: proc(vm: ^Interp, text, base: string) -> bool {
    parsed, err := json.parse_string(text, allocator = context.temp_allocator)
    if err != nil do return false
    root, is_obj := parsed.(json.Object)
    if !is_obj do return false
    im := &vm.import_map
    if im.alloc.procedure == nil {
        im.alloc = context.allocator
        im.imports = make([dynamic]Import_Map_Entry, im.alloc)
        im.scopes = make([dynamic]Import_Map_Scope, im.alloc)
    }
    a := im.alloc
    if imp, ok := root["imports"]; ok {
        if o, k := imp.(json.Object); k do merge_specifier_map(&im.imports, o, base, a)
    }
    if sc, ok := root["scopes"]; ok {
        if o, k := sc.(json.Object); k {
            for p, v in o {
                so, sk := v.(json.Object)
                if !sk do continue
                prefix := net.resolve_url(base, p, context.temp_allocator)
                idx := -1
                for s, i in im.scopes do if s.prefix == prefix { idx = i; break }
                if idx < 0 {
                    append(&im.scopes, Import_Map_Scope{prefix = strings.clone(prefix, a), imports = make([dynamic]Import_Map_Entry, a)})
                    idx = len(im.scopes) - 1
                }
                merge_specifier_map(&im.scopes[idx].imports, so, base, a)
            }
            slice.sort_by(im.scopes[:], proc(x, y: Import_Map_Scope) -> bool { return x.prefix > y.prefix })
        }
    }
    return true
}

// "Resolve an imports match". matched=false: este mapa não decide; matched=true
// com ok=false: BLOQUEADO (a resolução inteira falha).
@(private = "file")
imports_match :: proc(entries: []Import_Map_Entry, normalized, as_url: string, has_url: bool) -> (url: string, matched, ok: bool) {
    for e in entries {
        if e.key == normalized {
            if e.blocked do return "", true, false
            return e.value, true, true
        }
        if strings.has_suffix(e.key, "/") && strings.has_prefix(normalized, e.key) &&
           (!has_url || is_special_scheme(as_url)) {
            if e.blocked do return "", true, false
            after := normalized[len(e.key):]
            r := net.resolve_url(e.value, after, context.temp_allocator)
            // "backtracking": `react/../../x` não pode escapar do prefixo mapeado
            if !strings.has_prefix(r, e.value) do return "", true, false
            return r, true, true
        }
    }
    return "", false, false
}

// Resolve `specifier` importado de `base` (URL do módulo importador, ou do
// documento). Sem import map, equivale ao `resolve_url` de antes para
// especificadores relativos/absolutos; NU sem mapeamento FALHA (spec: TypeError)
// — buscar `…/react` só gerava um 404 garantido.
// Resultado no temp_allocator; ok=false = resolução falhou.
import_map_resolve :: proc(vm: ^Interp, specifier, base: string) -> (string, bool) {
    as_url, has_url := resolve_url_like(specifier, base)
    normalized := has_url ? as_url : specifier
    im := &vm.import_map
    for &s in im.scopes {
        if s.prefix == base || (strings.has_suffix(s.prefix, "/") && strings.has_prefix(base, s.prefix)) {
            if r, matched, ok := imports_match(s.imports[:], normalized, as_url, has_url); matched do return r, ok
        }
    }
    if r, matched, ok := imports_match(im.imports[:], normalized, as_url, has_url); matched do return r, ok
    if has_url do return as_url, true
    return "", false
}

import_map_destroy :: proc(im: ^Import_Map) {
    if im.alloc.procedure == nil do return
    a := im.alloc
    free_entries :: proc(es: ^[dynamic]Import_Map_Entry, a: runtime.Allocator) {
        for e in es {
            delete(e.key, a)
            if e.value != "" do delete(e.value, a)
        }
        delete(es^)
    }
    free_entries(&im.imports, a)
    for &s in im.scopes {
        delete(s.prefix, a)
        free_entries(&s.imports, a)
    }
    delete(im.scopes)
    im^ = {}
}
