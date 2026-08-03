package net

// Resolução de URL relativa — em especial com base `file://`, que passou a ser
// navegável pela barra de endereço. Sem isto, o `<link href="estilo.css">` de
// uma página local resolveria contra `https://` e a página abriria sem CSS.
//
// Primeiro arquivo de teste do pacote `net` (por isso `src/net` entrou na lista
// do test.ps1).

import "core:testing"

@(private = "file")
eq :: proc(t: ^testing.T, base, href, esperado: string) {
    got := resolve_url(base, href, context.temp_allocator)
    testing.expectf(t, got == esperado, "resolve(%q, %q) → esperava %q, veio %q", base, href, esperado, got)
}

@(test)
test_resolve_base_file :: proc(t: ^testing.T) {
    base := "file:///C:/dir/pagina.html"
    // relativa ao diretório: o caso do <link>/<script>/<img> de página local
    eq(t, base, "estilo.css", "file:///C:/dir/estilo.css")
    eq(t, base, "sub/app.js", "file:///C:/dir/sub/app.js")
    // segmentos-ponto continuam sendo normalizados
    eq(t, base, "../outro/x.png", "file:///C:/outro/x.png")
    // relativa à RAIZ: host vazio se mantém (file:///x, nunca file://x)
    eq(t, base, "/raiz.css", "file:///raiz.css")
    // absoluta file:// passa intacta (não pode ser resolvida contra a base)
    eq(t, base, "file:///D:/outro.css", "file:///D:/outro.css")
    // absoluta http a partir de página local também passa intacta
    eq(t, base, "https://cdn.exemplo.com/a.js", "https://cdn.exemplo.com/a.js")
    // não-navegáveis seguem descartados
    eq(t, base, "#secao", "")
    eq(t, base, "javascript:void(0)", "")
}

@(test)
test_resolve_base_http_nao_regride :: proc(t: ^testing.T) {
    // CONTRA-CASO: a base http(s) tem de resolver exatamente como antes.
    base := "https://exemplo.com/a/b/pagina.html"
    eq(t, base, "estilo.css", "https://exemplo.com/a/b/estilo.css")
    eq(t, base, "/raiz.css", "https://exemplo.com/raiz.css")
    eq(t, base, "../c/x.js", "https://exemplo.com/a/c/x.js")
    eq(t, base, "//cdn.exemplo.com/x.js", "https://cdn.exemplo.com/x.js")
    eq(t, base, "https://outro.com/y", "https://outro.com/y")
    eq(t, base, "data:text/css,body{}", "data:text/css,body{}")
}

@(test)
test_normalize_file_url :: proc(t: ^testing.T) {
    chk :: proc(t: ^testing.T, entrada, esperado: string) {
        got := normalize_file_url(entrada, context.temp_allocator)
        testing.expectf(t, got == esperado, "normalize(%q) → esperava %q, veio %q", entrada, esperado, got)
    }
    // as cinco grafias que o Chrome aceita convergem p/ a canônica
    chk(t, "file:///C:/x.html", "file:///C:/x.html")
    chk(t, "file://C:/x.html",  "file:///C:/x.html")
    chk(t, "file:/C:/x.html",   "file:///C:/x.html")
    chk(t, "file:C:/x.html",    "file:///C:/x.html")
    chk(t, "FILE:///C:/x.html", "file:///C:/x.html") // esquema é case-insensitive
    // barra invertida do Windows
    chk(t, `file:\C:\dir\x.html`, "file:///C:/dir/x.html")
    // ⚠️ host de VERDADE (UNC) tem de sobreviver: a diferença é a letra de unidade
    chk(t, "file://servidor/compartilhamento/x.html", "file://servidor/compartilhamento/x.html")
    // caminho POSIX absoluto continua absoluto
    chk(t, "file:///usr/local/x", "file:///usr/local/x")
    chk(t, "file:/usr/local/x",   "file:///usr/local/x")
    // não-file passa intacto
    chk(t, "https://exemplo.com/a", "https://exemplo.com/a")
}

@(test)
test_resolve_base_file_nao_canonica :: proc(t: ^testing.T) {
    // Base numa grafia torta faria o split_base ler "file:" como HOST e TODO
    // relativo da página sairia errado — por isso o resolve_url normaliza a base.
    eq(t, "file:/C:/dir/pagina.html",  "estilo.css", "file:///C:/dir/estilo.css")
    eq(t, "file://C:/dir/pagina.html", "sub/a.js",   "file:///C:/dir/sub/a.js")
    // href em grafia torta também sai canonizado (o curl só entende três barras)
    eq(t, "file:///C:/dir/pagina.html", "file:/D:/y.css", "file:///D:/y.css")
    eq(t, "file:///C:/dir/pagina.html", "file:D:/y.css",  "file:///D:/y.css")
}
