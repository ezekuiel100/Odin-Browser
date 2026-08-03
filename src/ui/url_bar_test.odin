package ui

// Normalização do que se digita na BARRA DE ENDEREÇO (`url_from_bar`).
// Motivo de existir: a barra prefixava `https://` em tudo que não fosse
// http(s), então `file:///C:/x.html` virava `https://file:///C:/x.html` e a
// página local nunca carregava — foi assim que descobri, tentando abrir uma
// fixture no app de verdade.

import "core:testing"

@(private = "file")
eq_url :: proc(t: ^testing.T, entrada, esperado: string, auto_esperado: bool) {
    u, auto := url_from_bar(entrada)
    testing.expectf(t, u == esperado, "%q → esperava %q, veio %q", entrada, esperado, u)
    testing.expectf(t, auto == auto_esperado, "%q → auto_https esperado %v, veio %v", entrada, auto_esperado, auto)
}

@(test)
test_url_bar_file_scheme :: proc(t: ^testing.T) {
    // o caso que estava quebrado: passa INTACTO e sem assumir https
    eq_url(t, "file:///C:/Users/Adm/x.html", "file:///C:/Users/Adm/x.html", false)
    // duas barras só: o host VAZIO é obrigatório, senão o curl lê "C:" como host
    eq_url(t, "file://C:/Users/Adm/x.html", "file:///C:/Users/Adm/x.html", false)
    // barra invertida não é separador de URL
    eq_url(t, `file:///C:\Users\Adm\x.html`, "file:///C:/Users/Adm/x.html", false)
    // espaço em volta (colar de um terminal costuma trazer)
    eq_url(t, "  file:///C:/x.html  ", "file:///C:/x.html", false)
}

@(test)
test_url_bar_caminho_local :: proc(t: ^testing.T) {
    // caminho de Windows digitado cru é o que o usuário faz quando quer abrir
    // um arquivo — vira file:// em vez de virar um domínio inexistente
    eq_url(t, `C:\Users\Adm\Desktop\x.html`, "file:///C:/Users/Adm/Desktop/x.html", false)
    eq_url(t, "D:/dir/x.html", "file:///D:/dir/x.html", false)
    // minúscula também é letra de unidade
    eq_url(t, `c:\x.html`, "file:///c:/x.html", false)
}

@(test)
test_url_bar_nao_regride :: proc(t: ^testing.T) {
    // CONTRA-CASOS: o comportamento antigo tem de continuar idêntico.
    eq_url(t, "http://exemplo.com/a", "http://exemplo.com/a", false)
    eq_url(t, "https://exemplo.com/a", "https://exemplo.com/a", false)
    // domínio nu → https-first com fallback p/ http (auto_https = true)
    eq_url(t, "exemplo.com", "https://exemplo.com", true)
    eq_url(t, "127.0.0.1:8765/x.html", "https://127.0.0.1:8765/x.html", true)
    // vazio não navega
    eq_url(t, "", "", false)
    eq_url(t, "   ", "", false)
    // "C:" sozinho NÃO é caminho (falta o separador) — não pode virar file://
    eq_url(t, "C:", "https://C:", true)
}

@(test)
test_url_buscavel :: proc(t: ^testing.T) {
    // Guarda dos SUBRECURSOS (<link rel=stylesheet> e @import). Era
    // `has_prefix(url, "http")` e por isso a folha de uma página file:// era
    // pulada em SILÊNCIO — a página abria sem CSS nenhum, sem erro.
    testing.expect(t, url_buscavel("file:///C:/dir/estilo.css"), "file:// tem de ser buscável")
    testing.expect(t, url_buscavel("http://a/x.css"),  "http continua buscável")
    testing.expect(t, url_buscavel("https://a/x.css"), "https continua buscável")
    // CONTRA-CASOS: o que nunca foi buscado aqui continua fora
    testing.expect(t, !url_buscavel("data:text/css,body{}"), "data: nunca foi aceito neste ponto")
    testing.expect(t, !url_buscavel("mailto:a@b.c"), "mailto não é subrecurso")
    testing.expect(t, !url_buscavel("estilo.css"), "relativa não resolvida não é buscável")
}

@(test)
test_url_bar_file_uma_barra :: proc(t: ^testing.T) {
    // As grafias que o Chrome aceita e a barra passou a aceitar. A normalização
    // é a MESMA do resolve_url (net.normalize_file_url) — barra e página não
    // podem discordar sobre o que uma URL de arquivo significa.
    eq_url(t, "file:/C:/Users/Adm/x.html", "file:///C:/Users/Adm/x.html", false)
    eq_url(t, "file:C:/Users/Adm/x.html",  "file:///C:/Users/Adm/x.html", false)
    eq_url(t, "FILE:///C:/x.html",         "file:///C:/x.html",           false)
    eq_url(t, "  file:/C:/x.html  ",       "file:///C:/x.html",           false)
    // host de VERDADE (UNC) sobrevive — não pode virar caminho local
    eq_url(t, "file://servidor/share/x.html", "file://servidor/share/x.html", false)
}
