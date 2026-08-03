package net

import "core:strings"

// Começa com o esquema `file:`? Esquema é case-insensitive (RFC 3986 §3.1) e o
// `equal_fold` não aloca.
is_file_url :: proc(s: string) -> bool {
    return len(s) >= 5 && strings.equal_fold(s[:5], "file:")
}

// Leva qualquer grafia de URL `file:` à forma canônica `file:///caminho`.
// As formas que aparecem na vida real (todas aceitas pelo Chrome):
//   file:///C:/x    → file:///C:/x     (canônica)
//   file://C:/x     → file:///C:/x     (falta a barra do host VAZIO)
//   file:/C:/x      → file:///C:/x     (uma barra só)
//   file:C:/x       → file:///C:/x     (sem barra)
//   FILE:///C:/x    → file:///C:/x     (esquema em maiúscula)
//   file://srv/s/x  → file://srv/s/x   (host de VERDADE — UNC, preservado)
// A distinção entre "host vazio esquecido" e "host de verdade" é a LETRA DE
// UNIDADE: `C:` depois de duas barras é caminho, `srv` é host. Sem isso, ou
// `file://C:/x` fica com host "C:" (e o curl não acha), ou todo UNC vira
// caminho local.
// ⚠️ o curl SÓ entende a forma canônica — por isso normalizar é obrigatório
// antes de buscar, não cosmético.
normalize_file_url :: proc(url: string, allocator := context.allocator) -> string {
    if !is_file_url(url) do return strings.clone(url, allocator)
    // barra invertida do Windows não é separador de URL
    rest, _ := strings.replace_all(url[5:], "\\", "/", context.temp_allocator)
    n := 0
    for n < len(rest) && rest[n] == '/' do n += 1
    corpo := rest[n:]
    if n == 2 && !comeca_com_unidade(corpo) {
        return strings.concatenate({"file://", corpo}, allocator) // UNC: host preservado
    }
    return strings.concatenate({"file:///", corpo}, allocator)
}

// "C:/..." ou "C:" — letra de unidade seguida de dois-pontos.
@(private)
comeca_com_unidade :: proc(s: string) -> bool {
    if len(s) < 2 do return false
    c := s[0]
    return ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) && s[1] == ':'
}

// Resolve um href (possivelmente relativo) contra a URL da página atual.
// Devolve string nova (owned) ou "" quando não é navegável (mailto:, etc.).
// Versão simplificada — não trata "../" nem query/fragment com precisão.
resolve_url :: proc(base_in, href_in: string, allocator := context.allocator) -> string {
    href := strings.trim_space(href_in)
    if href == "" do return ""

    // Base em grafia não-canônica (`file:/C:/dir/p.html`) faria o `split_base`
    // ler "file:" como HOST e todo relativo da página sairia errado. Normalizar
    // aqui deixa a função total: quem chama não precisa saber da diferença.
    base := base_in
    if is_file_url(base) do base = normalize_file_url(base, context.temp_allocator)

    // não navegáveis
    if strings.has_prefix(href, "mailto:") ||
       strings.has_prefix(href, "tel:") ||
       strings.has_prefix(href, "javascript:") ||
       strings.has_prefix(href, "#") {
        return ""
    }

    // `file:` em QUALQUER grafia é absoluta — sai canonizada (o curl só entende a
    // forma de três barras). O RELATIVO dentro de uma página file:// não precisa
    // de caso próprio: o `split_base` devolve scheme="file", host="" e
    // path="/C:/dir/p.html", então `style.css` resolve para
    // `file:///C:/dir/style.css` pelo caminho comum.
    if is_file_url(href) do return normalize_file_url(href, allocator)

    // já é absoluta / auto-contida (data: carrega o próprio conteúdo inline;
    // NÃO pode ser resolvida contra a base, senão vira https://host/data:...)
    if strings.has_prefix(href, "http://") || strings.has_prefix(href, "https://") ||
       strings.has_prefix(href, "data:") {
        return strings.clone(href, allocator)
    }

    scheme, host, path := split_base(base)
    if scheme == "" do scheme = "https"

    // relativa ao protocolo: //host/caminho
    if strings.has_prefix(href, "//") {
        return strings.concatenate({scheme, ":", href}, allocator)
    }

    // relativa à raiz: /caminho
    if strings.has_prefix(href, "/") {
        np := normalize_dot_segments(href, context.temp_allocator)
        return strings.concatenate({scheme, "://", host, np}, allocator)
    }

    // relativa ao diretório atual
    dir := path
    if slash := strings.last_index_byte(path, '/'); slash >= 0 {
        dir = path[:slash + 1]
    } else {
        dir = "/"
    }
    joined := strings.concatenate({dir, href}, context.temp_allocator)
    np := normalize_dot_segments(joined, context.temp_allocator)
    return strings.concatenate({scheme, "://", host, np}, allocator)
}

// Remove segmentos-ponto do caminho (`/./` e `/../`) — RFC 3986 §5.2.4. Sem isto,
// `/assets/entry.js` + `../chunks/x.js` virava `/assets/../chunks/x.js` LITERAL,
// que CDNs estritas rejeitam com 404 (crates.io: quebrava o grafo de módulos ES
// do M109 — `import estático falhou: ../chunks/...`). Query/fragment preservados.
@(private)
normalize_dot_segments :: proc(path: string, allocator := context.allocator) -> string {
    // separa query/fragment (não fazem parte do caminho)
    cut := len(path)
    if q := strings.index_byte(path, '?'); q >= 0 do cut = q
    if h := strings.index_byte(path, '#'); h >= 0 && h < cut do cut = h
    p := path[:cut]
    suffix := path[cut:]
    if !strings.contains(p, "/.") do return strings.clone(path, allocator) // caminho já limpo

    parts := strings.split(p, "/", context.temp_allocator)
    out := make([dynamic]string, context.temp_allocator)
    for seg in parts {
        switch seg {
        case ".":  // segmento "aqui": ignora
        case "..": if len(out) > 1 do pop(&out) // sobe um nível; nunca passa da raiz (out[0]="")
        case:      append(&out, seg)
        }
    }
    np := strings.join(out[:], "/", context.temp_allocator)
    if np == "" do np = "/"
    return strings.concatenate({np, suffix}, allocator)
}

// Quebra uma URL absoluta em (scheme, host, path). path começa com '/'.
@(private)
split_base :: proc(url: string) -> (scheme, host, path: string) {
    rest := url
    if i := strings.index(rest, "://"); i >= 0 {
        scheme = rest[:i]
        rest = rest[i + 3:]
    }
    // host vai até a primeira '/'
    if i := strings.index_byte(rest, '/'); i >= 0 {
        host = rest[:i]
        path = rest[i:]
    } else {
        host = rest
        path = "/"
    }
    return
}
