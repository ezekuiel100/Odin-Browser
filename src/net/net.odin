package net

// Camada de rede usando libcurl (estático, com SSL nativo do Windows).
// Por enquanto é síncrono: fetch() bloqueia até a resposta chegar.
// O próximo passo será rodar em outra thread para não travar a UI.

import curl "vendor:curl"
import "core:c"
import "core:fmt"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:bytes"
import "core:compress/gzip"
import "core:encoding/base64"
import "core:time"

@(private) g_inited: bool

// Pool COMPARTILHADO de conexões/DNS/sessões-TLS entre os worker threads de fetch.
// Sem ele, cada fetch abre conexão nova (handshake TLS por imagem) e alguns CDNs
// (upload.wikimedia) tratam a rajada de conexões como abuso (429). Com o share +
// HTTP/2, os handles reusam/multiplexam conexões p/ o mesmo host — comportamento
// de navegador. Os callbacks de lock dão thread-safety (1 mutex por lock_data).
@(private) g_share:       ^curl.CURLSH
@(private) g_share_locks: [8]sync.Mutex

@(private)
share_lock_cb :: proc "c" (handle: ^curl.CURL, data: curl.lock_data, locktype: curl.lock_access, userptr: rawptr) {
    i := int(data)
    if i >= 0 && i < len(g_share_locks) do sync.mutex_lock(&g_share_locks[i])
}
@(private)
share_unlock_cb :: proc "c" (handle: ^curl.CURL, data: curl.lock_data, userptr: rawptr) {
    i := int(data)
    if i >= 0 && i < len(g_share_locks) do sync.mutex_unlock(&g_share_locks[i])
}

// UA de Chrome real. Sites com bot-detection (Cloudflare, Akamai, ...) servem
// página de bloqueio/challenge a User-Agents desconhecidos — nos passamos por
// Chrome no Windows pra receber o conteúdo de verdade.
CHROME_UA :: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

Response :: struct {
    body:   string, // corpo da resposta (HTML). Liberar com delete(resp.body)
    status: int,    // código HTTP (200, 404, ...)
    ok:     bool,
    err:    string, // mensagem de erro (válida só quando ok == false)
    // Content-Type CRU do servidor (ex. "text/html; charset=utf-8"), fatia de
    // memória da libcurl — válida só até o próximo uso do handle, então quem
    // precisa guardar deve clonar. "" quando o servidor não mandou.
    content_type: string,
    // Retry-After (segundos) de uma resposta 429/503. 0 = header ausente. O loader
    // de imagens honra isto no backoff (upload.wikimedia manda `Retry-After: 1`).
    retry_after: int,
}

ensure_init :: proc() {
    if !g_inited {
        curl.global_init(curl.GLOBAL_DEFAULT)
        // Cria o pool compartilhado UMA vez (chamado pela main thread no 1º fetch,
        // antes dos workers de imagem — nenhuma corrida na criação).
        g_share = curl.share_init()
        if g_share != nil {
            curl.share_setopt(g_share, .CURLSHOPT_LOCKFUNC,   share_lock_cb)
            curl.share_setopt(g_share, .CURLSHOPT_UNLOCKFUNC, share_unlock_cb)
            curl.share_setopt(g_share, .CURLSHOPT_SHARE, c.int(curl.lock_data.CONNECT))
            curl.share_setopt(g_share, .CURLSHOPT_SHARE, c.int(curl.lock_data.SSL_SESSION))
            curl.share_setopt(g_share, .CURLSHOPT_SHARE, c.int(curl.lock_data.DNS))
        }
        g_inited = true
    }
}

// Callback chamado pela libcurl com pedaços do corpo da resposta.
@(private)
write_cb :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
    context = runtime.default_context()
    n := int(size) * int(nmemb)
    buf := cast(^[dynamic]u8)userdata
    append(buf, ..ptr[:n])
    return c.size_t(n)
}

// Callback de HEADER (uma chamada por linha de cabeçalho). Só nos interessa o
// `Retry-After` das respostas 429/503: escreve os segundos no int apontado por
// userdata. Retry-After pode ser delta-segundos ("1") ou uma data HTTP; parseamos
// o inteiro à frente e, se vier data, usamos um default modesto (o importante é
// esperar ALGO em vez de re-disparar na hora).
@(private)
header_cb :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
    context = runtime.default_context()
    n := int(size) * int(nitems)
    if userdata != nil && n > 12 {
        // compara "retry-after:" case-insensitive SEM alocar (roda em thread de worker;
        // evita tocar o temp_allocator do contexto)
        key := "retry-after:"
        match := true
        for i in 0 ..< 12 {
            ch := buffer[i]
            if ch >= 'A' && ch <= 'Z' do ch += 32 // to-lower ASCII
            if ch != key[i] { match = false; break }
        }
        if match {
            i := 12
            for i < n && (buffer[i] == ' ' || buffer[i] == '\t') do i += 1 // pula espaços
            secs, got := 0, false
            for i < n && buffer[i] >= '0' && buffer[i] <= '9' {
                secs = secs * 10 + int(buffer[i] - '0'); got = true; i += 1
            }
            if !got do secs = 2 // veio data HTTP (não dígito) → default modesto
            (cast(^int)userdata)^ = secs
        }
    }
    return c.size_t(n)
}

// Decodifica uma data: URI. Formato: data:[<mediatype>][;base64],<dados>
// (RFC 2397). Sites reais (ex.: Facebook) servem scripts inline assim; nunca
// passam pela rede. Devolve o corpo já decodificado (owned, como fetch normal).
@(private)
fetch_data_uri :: proc(url: string) -> Response {
    rest := url[len("data:"):]
    comma := strings.index_byte(rest, ',')
    if comma < 0 {
        return {err = strings.clone("data URI sem vírgula")}
    }
    meta    := rest[:comma]
    payload := rest[comma + 1:]
    // data: URLs contain URL-escaped bytes, including SVG markup and sometimes
    // the base64 alphabet itself. A '+' is literal here, not a form-space.
    if strings.contains(payload, "%") {
        hex :: proc(c: u8) -> int {
            if c >= '0' && c <= '9' do return int(c-'0')
            if c >= 'a' && c <= 'f' do return int(c-'a')+10
            if c >= 'A' && c <= 'F' do return int(c-'A')+10
            return -1
        }
        decoded := make([dynamic]u8, 0, len(payload), context.temp_allocator)
        for i := 0; i < len(payload); i += 1 {
            if payload[i] == '%' && i+2 < len(payload) {
                a, b := hex(payload[i+1]), hex(payload[i+2])
                if a >= 0 && b >= 0 { append(&decoded, u8(a*16+b)); i += 2; continue }
            }
            append(&decoded, payload[i])
        }
        payload = string(decoded[:])
    }

    if strings.contains(meta, ";base64") {
        // base64 pode conter quebras de linha/espaços; o decoder não os tolera.
        clean := payload
        if strings.index_any(payload, " \t\r\n") >= 0 {
            sb := strings.builder_make(context.temp_allocator)
            for i in 0 ..< len(payload) {
                c := payload[i]
                if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
                    strings.write_byte(&sb, c)
                }
            }
            clean = strings.to_string(sb)
        }
        decoded, err := base64.decode(clean, base64.DEC_TABLE, nil, context.allocator)
        if err != nil {
            return {err = fmt.aprintf("data URI base64 inválida (%v)", err)}
        }
        return {body = string(decoded), status = 200, ok = true}
    }

    // Caller owns the response body, just as for HTTP and base64 data URLs.
    return {body = strings.clone(payload), status = 200, ok = true}
}

// Busca uma URL e devolve o corpo. Bloqueante.
fetch :: proc(url: string) -> Response {
    return fetch_opts(url)
}

// Busca de ARQUIVO DE FONTE. Existe como nome próprio só para o call-site ficar
// legível — vai com o mesmo CHROME_UA de todo o resto.
//
// Histórico que vale registrar: no M224 esta função ia deliberadamente SEM
// User-Agent, porque provedores de webfont negociam o formato pelo UA e, com o
// CHROME_UA, o Google Fonts responde **woff2** — que é Brotli, e não havia
// decodificador. Sem UA o mesmo endpoint responde `.ttf`. Agora que `src/brotli`
// e `src/woff2` existem, a concessão saiu: pedimos como navegador moderno e
// decodificamos o que um navegador moderno recebe.
fetch_font :: proc(url: string) -> Response {
    return fetch_opts(url)
}

@(private)
fetch_opts :: proc(url: string) -> Response {
    if strings.has_prefix(url, "data:") do return fetch_data_uri(url)

    ensure_init()

    h := curl.easy_init()
    if h == nil {
        return {err = "curl_easy_init falhou"}
    }
    defer curl.easy_cleanup(h)

    curl_url := strings.clone_to_cstring(url, context.temp_allocator)
    body: [dynamic]u8

    // Cabeçalhos de navegador real. O Accept-Encoding é o pulo do gato do brotli:
    // anunciamos SÓ gzip (o único que sabemos descomprimir). Assim o servidor
    // nunca manda brotli/zstd — que não temos como decodificar em Odin e chegavam
    // como lixo binário no parser → tela branca. Usamos header manual (não
    // CURLOPT_ACCEPT_ENCODING) de propósito: o header manual NÃO aciona o
    // auto-decompress da libcurl, que exigiria zlib compilado (que não temos);
    // recebemos gzip cru e descomprimimos nós mesmos mais abaixo.
    headers: ^curl.slist
    headers = curl.slist_append(headers, "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8")
    headers = curl.slist_append(headers, "Accept-Language: en-US,en;q=0.9")
    headers = curl.slist_append(headers, "Accept-Encoding: gzip")
    defer curl.slist_free_all(headers)

    retry_after_secs := 0 // preenchido pelo header_cb se vier Retry-After (429/503)

    curl.easy_setopt(h, .URL,            curl_url)
    curl.easy_setopt(h, .WRITEFUNCTION,  write_cb)
    curl.easy_setopt(h, .WRITEDATA,      &body)
    curl.easy_setopt(h, .HEADERFUNCTION, header_cb)
    curl.easy_setopt(h, .HEADERDATA,     &retry_after_secs)
    curl.easy_setopt(h, .HTTPHEADER,     headers)
    curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))            // segue redirects
    curl.easy_setopt(h, .USERAGENT,      cstring(CHROME_UA))
    curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(10))           // p/ fallback https→http rápido
    curl.easy_setopt(h, .TIMEOUT,        c.long(30))
    // Pool compartilhado + HTTP/2: REUSA conexões entre fetches (menos handshakes,
    // menos rajada de conexões p/ o mesmo host).
    //
    // ⚠️ SEM `PIPEWAIT`, de propósito. Cada fetch é um `easy_perform` na SUA thread
    // (um multi interno próprio), e a libcurl não multiplexa numa conexão presa ao
    // multi de OUTRA thread. Com PIPEWAIT o 2º handle não abria conexão nova:
    // ficava ESPERANDO a do 1º, sem ninguém para acordá-lo, até o CONNECTTIMEOUT
    // (10 s) — e falhava. Medido (10/11/2026, página com 2 `@font-face` na MESMA
    // URL + 30 imagens do wikimedia, 3 rodadas): com PIPEWAIT, 1 falha por rodada
    // travada em 10 001 ms (a Work Sans do animate.style morria assim); sem ele,
    // 0 falhas, maior requisição < 300 ms, 0 respostas 429. Requisições
    // simultâneas ao mesmo host abrem conexões próprias, como num navegador
    // HTTP/1.1; as SEQUENCIAIS continuam reusando o pool.
    if g_share != nil do curl.easy_setopt(h, .SHARE, g_share)
    curl.easy_setopt(h, .HTTP_VERSION, curl.HTTP_VERSION_2TLS)

    // Sonda de rede: tempo e resultado de CADA fetch (`-define:NETPROBE=true`).
    // Foi o que mostrou o travamento acima — a falha só aparecia como "fonte errada".
    when #config(NETPROBE, false) { t0 := time.tick_now() }
    res := curl.easy_perform(h)
    when #config(NETPROBE, false) {
        st_p: c.long
        curl.easy_getinfo(h, .RESPONSE_CODE, &st_p)
        fmt.eprintfln("[NET] %dms res=%v status=%d %s", i64(time.duration_milliseconds(time.tick_since(t0))), res, st_p, url[:min(len(url), 120)])
    }
    if res != .E_OK {
        delete(body)
        return {err = fmt.aprintf("erro de rede (%v)", res)}
    }

    status: c.long
    curl.easy_getinfo(h, .RESPONSE_CODE, &status)
    ct_c: cstring
    curl.easy_getinfo(h, .CONTENT_TYPE, &ct_c)

    // Diagnóstico de rede (compila-out por padrão; ligue com -define:NET_DEBUG=true).
    // Mostra o corpo CRU recebido da libcurl — útil p/ distinguir "nossa engine
    // falhou" de "o servidor mandou outra coisa" (ex.: lobste.rs devolve 51 bytes
    // "You'll have to speak up, I'm wearing a towel" = rate-limit; reuters/etsy
    // devolvem CAPTCHA da DataDome, não o conteúdo — nada disso é bug do navegador).
    when #config(NET_DEBUG, false) {
        fmt.eprintfln("[net-dbg] %s: raw=%d bytes gzip_magic=%v BODY<<%s>>",
            url, len(body), len(body) >= 2 && body[0] == 0x1f && body[1] == 0x8b,
            string(body[:min(len(body), 200)]))
    }

    out := string(body[:])

    // Alguns servidores mandam gzip mesmo sem pedirmos (ignoram Accept-Encoding).
    // Detecta a "magic" do gzip (1f 8b) e descomprime.
    if len(body) >= 2 && body[0] == 0x1f && body[1] == 0x8b {
        buf: bytes.Buffer
        if gzip.load(body[:], &buf) == nil {
            delete(body)
            out = string(bytes.buffer_to_bytes(&buf))
        }
        // se falhar, mantém o corpo cru (melhor que nada)
    }

    return {
        body         = out,
        status       = int(status),
        ok           = true,
        content_type = ct_c != nil ? string(ct_c) : "",
        retry_after  = retry_after_secs,
    }
}
