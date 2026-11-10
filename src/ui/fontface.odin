package ui

// M224 — `@font-face`: registro, download, decode e injeção no atlas.
//
// O parser (src/css/fontface.odin) só DESCREVE a face. Aqui:
//   1. `fontface_register` recebe as faces de uma página, resolve as URLs contra
//      a base, escolhe a melhor `src` que SABEMOS decodificar e dispara o
//      download numa thread (mesmo desenho do images.odin: worker + flag `done`
//      + poll na thread principal, que é a dona do renderer/atlas);
//   2. `fontface_poll` (thread principal, 1×/frame) injeta as faces prontas no
//      atlas do ImGui e o RECONSTRÓI — a peça de risco, provada isolada por
//      `browser.exe --fonttest` antes de qualquer linha disto ser escrita;
//   3. `fontface_lookup` resolve (família, peso, itálico) → face, no momento da
//      PINTURA (é lá que peso e itálico já estão decididos).
//
// ── Formatos ────────────────────────────────────────────────────────────────
// SFNT cru (TTF/OTF) carrega direto no stb_truetype. WOFF1 é um invólucro com as
// tabelas comprimidas em zlib — remontamos o SFNT. **WOFF2** (M226) passa por
// `src/woff2`, que descomprime o stream único com `src/brotli` e RECONSTRÓI as
// tabelas transformadas (`glyf`, `loca` e, quando usada, a de `hmtx`).
//
// Com o WOFF2 no ar caiu a concessão do M224: `net.fetch_font` ia sem
// User-Agent só para o Google Fonts responder `.ttf` em vez de woff2. Agora
// pede-se como navegador moderno. ⚠️ Note que a rota do CSS do provedor SEMPRE
// foi com UA (o `is_font_css_host` que existia para isso nunca chegou a ser
// chamado) — então na prática as URLs que voltavam eram woff2, o `pick_src`
// as pontuava 0 e **toda webfont de Google Fonts caía na família genérica**.
// Era isto que estava quebrado, não só o formato.
//
// Degradação: face que não baixa, não decodifica ou não cabe no orçamento →
// a família cai na pilha genérica (sans/serif/mono), que é o comportamento
// anterior a este marco. Nada some da página.

import "core:strings"
import "core:fmt"
import "core:thread"
import "core:time"
import "core:sync"
import "core:slice"
import "core:c"
import "core:compress/zlib"
import "core:bytes"
import tt         "vendor:stb/truetype"
import im         "../../vendor/imgui"
import imgui_sdlr "../../vendor/imgui/imgui_impl_sdlrenderer2"
import csspkg     "../css"
import netpkg     "../net"
import woff2pkg   "../woff2"
import varfontpkg "../varfont"

// Teto de faces carregadas ou em download por sessão. Falhas não contam.
// Cada face ocupa FONT_N tamanhos no atlas
// (a mesma escada das embutidas) — a textura do atlas cresce com isso, e um site
// com 20 pesos declarados encheria a GPU à toa.
MAX_FACES :: 32 // Loading + Ready; failed entries do not consume atlas capacity.
FONT_RETRY_DELAY :: 2 * time.Second
FONT_MAX_ATTEMPTS :: 3

Face_State :: enum u8 { Loading, Ready, Failed }
Face_Failure :: enum u8 { None, Network, Http, Empty, Decode, No_Glyphs, Thread }

Loaded_Face :: struct {
    fam_id: u8,  // índice+1 em g_face_families
    weight: int, // chave do registro E peso em que a face é instanciada
    // Faixa declarada (`font-weight: 100 900`, fonte variável). 0/0 = peso único.
    // Numa face de faixa, `weight` é o 400 trazido para dentro dela (o peso que
    // a 1ª instância usa); pesos pedidos pela página geram instâncias DERIVADAS
    // sob demanda (ver `fontface_pick`).
    wmin, wmax: int,
    italic: bool,
    url:    string, // owned (resolvida)
    state:  Face_State,
    failure: Face_Failure,
    retryable: bool, // transient network/HTTP failures only
    attempts: int,
    last_attempt: time.Tick,

    // handoff worker → main
    done:    b32,
    // SFNT DECODIFICADO, antes de instanciar. Várias faces podem apontar para o
    // MESMO buffer: as `@font-face` de 400 e 700 de uma fonte variável têm a
    // mesma URL, e só uma delas baixa (ver `fontface_start`). `raw_borrowed`
    // marca quem não é dona.
    raw:          []byte,
    raw_borrowed: bool,
    waiting_on:   int,  // índice+1 da face cujo download esta aguarda (0 = nenhum)
    is_var:       bool, // o `raw` tem eixo `wght` instanciável
    derived:      bool, // instância criada pelo `fontface_pick`, sem download próprio
    // O que vai para o atlas: a instância no `weight` (owned) ou o próprio `raw`
    // quando não há o que instanciar (fonte estática, ou o peso é o default).
    payload: []byte,

    fonts: [FONT_N]^im.Font, // preenchido no poll, um por degrau da escada
    // Razão em-square DESTA face, MEDIDA no atlas (ver em_ratio_medido). A webfont do
    // autor não tem por que ter a mesma métrica das genéricas do sistema: sem
    // isto, uma face com em-square diferente sairia com o tamanho errado —
    // exatamente o defeito que a constante global 1.36 causava no serif/mono.
    em: f32,
}

// Nomes de família declarados por @font-face, em minúsculas. O ÍNDICE+1 é o
// `font_fam_id` que viaja no Computed/Box/Inline_Style — um u8, não a string.
g_face_families: [dynamic]string
g_faces: [dynamic]Loaded_Face
g_faces_dirty: bool // alguma face nova entrou no atlas: precisa rebuild

// ⚠️ NÃO existe "esquecer as faces" ao navegar, e é DE PROPÓSITO: com
// `FontDataOwnedByAtlas = false` o atlas guarda um PONTEIRO para o nosso
// `payload`, e ele é relido a cada `FontAtlas_Build` — liberar o buffer numa
// troca de página seria use-after-free no próximo rebuild (que acontece quando
// a face da página SEGUINTE chega). As faces vivem a sessão inteira, limitadas
// por MAX_FACES.
// Consequência anotada: se duas páginas declararem a MESMA família com arquivos
// diferentes, a segunda reusa a face da primeira (a chave é família+peso+itálico,
// não a URL). Erro limitado e visível só nesse caso.

// Índice+1 da família (cria se nova). 0 = não coube.
@(private = "file")
fam_id_of :: proc(name_lower: string) -> u8 {
    for f, i in g_face_families do if f == name_lower do return u8(i + 1)
    if len(g_face_families) >= 255 do return 0
    append(&g_face_families, strings.clone(name_lower))
    return u8(len(g_face_families))
}

// A família tem alguma face declarada? (chamado no cômputo de estilo, onde só
// se sabe o NOME — peso e itálico só existem na pintura.)
fontface_family_id :: proc(name_lower: string) -> u8 {
    for f, i in g_face_families do if f == name_lower do return u8(i + 1)
    return 0
}

// Escolhe a `src` que sabemos decodificar. A ordem é a do que custa menos para
// chegar pronto na memória: SFNT cru carrega direto, woff2 é o formato que os
// provedores servem por padrão (e o menor), woff1 é o legado.
//
// `embedded-opentype` e `svg` continuam fora — são formatos mortos e nenhum
// deles é SFNT.
@(private = "file")
pick_src :: proc(srcs: []csspkg.Font_Src) -> (string, bool) {
    score :: proc(s: csspkg.Font_Src) -> int {
        h := s.hint
        if h == "" { // sem format(): deduz pela extensão
            lo := strings.to_lower(s.url, context.temp_allocator)
            if q := strings.index_byte(lo, '?'); q >= 0 do lo = lo[:q]
            switch {
            case strings.has_suffix(lo, ".ttf"), strings.has_suffix(lo, ".otf"): h = "truetype"
            case strings.has_suffix(lo, ".woff"):  h = "woff"
            case strings.has_suffix(lo, ".woff2"): h = "woff2"
            }
        }
        switch h {
        case "truetype", "opentype", "truetype-variations", "opentype-variations": return 4
        case "woff2": return 3
        case "woff": return 2
        case "embedded-opentype", "svg": return 0
        }
        return 1 // desconhecido: tenta (o sniff de magic decide de verdade)
    }
    best, best_score := "", 0
    for s in srcs {
        sc := score(s)
        if sc > best_score { best, best_score = s.url, sc }
    }
    return best, best_score > 0
}

// ── decode ──────────────────────────────────────────────────────────────────

@(private = "file")
be32 :: proc(b: []byte, at: int) -> u32 {
    if at + 4 > len(b) do return 0
    return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}
@(private = "file")
be16 :: proc(b: []byte, at: int) -> u32 {
    if at + 2 > len(b) do return 0
    return u32(b[at]) << 8 | u32(b[at + 1])
}

// SFNT cru? (0x00010000 = TrueType, "OTTO" = CFF, "true"/"ttcf" = variantes Apple)
@(private = "file")
is_sfnt :: proc(b: []byte) -> bool {
    if len(b) < 4 do return false
    t := be32(b, 0)
    return t == 0x00010000 || t == 0x4F54544F || t == 0x74727565
}

// WOFF1 → SFNT. O invólucro é: header de 44 bytes ("wOFF"), diretório de N
// entradas de 20 bytes (offset/compLength/origLength/origChecksum) e os dados,
// cada tabela comprimida em zlib (ou armazenada, quando comp==orig).
// Devolve bytes OWNED, ou nil se não for WOFF/estiver corrompido.
@(private = "file")
woff1_to_sfnt :: proc(b: []byte) -> []byte {
    if len(b) < 44 || be32(b, 0) != 0x774F4646 do return nil // "wOFF"
    num := int(be16(b, 12))
    if num <= 0 || num > 512 do return nil
    if 44 + num * 20 > len(b) do return nil

    // tamanho do SFNT: header(12) + dir(16·n) + tabelas alinhadas em 4
    total := 12 + 16 * num
    for i in 0 ..< num {
        e := 44 + i * 20
        orig := int(be32(b, e + 12))
        total += (orig + 3) & ~int(3)
    }
    out := make([]byte, total)
    ok := false
    defer if !ok do delete(out)

    // header SFNT (searchRange & co. podem ser zero: o stb não os usa)
    sfnt_ver := be32(b, 4)
    out[0] = u8(sfnt_ver >> 24); out[1] = u8(sfnt_ver >> 16); out[2] = u8(sfnt_ver >> 8); out[3] = u8(sfnt_ver)
    out[4] = u8(num >> 8); out[5] = u8(num)

    put32 :: proc(d: []byte, at: int, v: u32) {
        d[at] = u8(v >> 24); d[at + 1] = u8(v >> 16); d[at + 2] = u8(v >> 8); d[at + 3] = u8(v)
    }
    data_at := 12 + 16 * num
    for i in 0 ..< num {
        e := 44 + i * 20
        tag  := be32(b, e)
        off  := int(be32(b, e + 4))
        comp := int(be32(b, e + 8))
        orig := int(be32(b, e + 12))
        csum := be32(b, e + 16)
        if off < 0 || comp < 0 || off + comp > len(b) || orig < 0 || data_at + orig > total do return nil

        d := 12 + i * 16
        put32(out, d, tag); put32(out, d + 4, csum)
        put32(out, d + 8, u32(data_at)); put32(out, d + 12, u32(orig))

        if comp == orig { // tabela ARMAZENADA (sem compressão)
            copy(out[data_at:data_at + orig], b[off:off + comp])
        } else {
            buf: bytes.Buffer
            defer bytes.buffer_destroy(&buf)
            if zlib.inflate_from_byte_array(b[off:off + comp], &buf) != nil do return nil
            inflated := bytes.buffer_to_bytes(&buf)
            if len(inflated) != orig do return nil
            copy(out[data_at:data_at + orig], inflated)
        }
        data_at += (orig + 3) & ~int(3)
    }
    ok = true
    return out
}

// O SFNT tem o que o stb_truetype EXIGE, e um cmap que sabemos endereçar?
//
// ⚠️ Isto não é zelo: sem a checagem, um arquivo que o stb recusa **derruba o
// processo** — o ImGui trata a falha com `IM_ASSERT(0 && "stbtt_InitFont():
// failed to parse FontData")`, que aborta. Como os bytes vêm da REDE, qualquer
// fonte corrompida ou exótica seria um crash do navegador. Medido com a
// Wingdings do Windows, que aborta o `--render`.
//
// Exigimos: as tabelas que o stb procura no InitFont (head/hhea/hmtx/maxp/cmap
// + glyf&loca ou CFF) e ao menos UM subtable de cmap com encoding UNICODE
// (3,1 / 3,10 / plataforma 0). Fonte de cmap só-símbolo (3,0), como a Wingdings,
// é recusada de propósito: os nossos ranges de glifo são codepoints Unicode, e
// não há como endereçá-la por texto de página.
//
// Visível no pacote porque o `--woff2test` (headless.odin) aplica a MESMA
// triagem na fonte remontada: se ela não passasse aqui, não seria carregada de
// todo jeito e a prova diferencial mentiria.
sfnt_usable :: proc(b: []byte) -> bool {
    if len(b) < 12 do return false
    num := int(be16(b, 4))
    if num <= 0 || num > 512 || 12 + num * 16 > len(b) do return false
    has := map[u32]int{} // tag → offset
    defer delete(has)
    for i in 0 ..< num {
        e := 12 + i * 16
        tag := be32(b, e)
        off := int(be32(b, e + 8))
        if off < 0 || off >= len(b) do return false
        has[tag] = off
    }
    T :: proc(s: string) -> u32 { return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3]) }
    for t in ([]string{"head", "hhea", "hmtx", "maxp", "cmap"}) do if T(t) not_in has do return false
    _, glyf := has[T("glyf")]
    _, loca := has[T("loca")]
    _, cff  := has[T("CFF ")]
    if !(glyf && loca) && !cff do return false

    cm := has[T("cmap")]
    if cm + 4 > len(b) do return false
    ntab := int(be16(b, cm + 2))
    if ntab <= 0 || cm + 4 + ntab * 8 > len(b) do return false
    for i in 0 ..< ntab {
        e := cm + 4 + i * 8
        plat := be16(b, e)
        enc  := be16(b, e + 2)
        if plat == 0 do return true              // Unicode
        if plat == 3 && (enc == 1 || enc == 10) do return true // Windows Unicode BMP/full
    }
    return false // só cmap de símbolo: não dá p/ endereçar por codepoint
}

// Quantos glifos esta face produziria no atlas, dados os ranges que pedimos?
//
// ZERO é fatal: `ImFontAtlasBuildSetupFont` limpa os glifos do ImFont e o passo
// 9 não repõe nenhum, então `ImFont::BuildLookupTable` bate no
// `IM_ASSERT(Glyphs.Size > 0 && "Font has not loaded glyph!")`
// (imgui_draw.cpp:3738) e ABORTA o processo.
//
// ⚠️⚠️ Por isso a triagem é ANTES de adicionar, e não uma inspeção do ^Font
// depois: `BuildLookupTable` roda DENTRO de `FontAtlas_Build` (via
// ImFontAtlasBuildFinish, imgui_draw.cpp:3375), não na primeira pintura —
// quando o Build retorna já não há processo para consertar coisa alguma.
//
// A contagem não é aproximação, é a MESMA do ImGui: o passo 2 de
// `ImFontAtlasBuildWithStbTruetype` conta exatamente os cp dos ranges com
// `stbtt_FindGlyphIndex(cp) != 0`, e o passo 9 chama `AddGlyph` uma vez por item
// contado, SEM filtro (nem `was_packed`) — logo `Glyphs.Size` É esta contagem.
//
// ⚠️ HONESTIDADE SOBRE O ALCANCE (medido em 2026-07-31, com as fontes na mão):
// escrevi este guarda convencido de que fonte de ÍCONES era o espécime, porque
// os glifos dela vivem na PUA (U+E000–U+F8FF), fora dos nossos ranges. A medição
// DERRUBOU a hipótese — contagem em `g_text_ranges`:
//     Font Awesome 6 (fa-solid-900)          108
//     Glyphicons Halflings (bootstrap 3)      21
//     Segoe MDL2 Assets                        1   (só o espaço)
//     Roboto greek-ext (subset Google Fonts)   2
// Nenhuma chega a zero, e a razão é estrutural: `g_text_ranges` começa em
// U+0020 e praticamente toda fonte embarca o ESPAÇO. ⇒ este guarda é blindagem
// barata e PROVADAMENTE correta, mas NÃO há espécime real conhecido que passe
// por ele — não credite a ele um crash sem antes ver o número no FONTPROBE
// abaixo. Se um crash em `BuildLookupTable` voltar, a causa é OUTRA e este
// comentário é o aviso para não perder o dia que eu perdi.
//
// Degradação quando de fato der zero: a família cai na pilha genérica, como
// qualquer face que não baixa.
face_glyph_count_in_ranges :: proc(sfnt: []byte, ranges: []im.Wchar) -> int {
    // ⚠️ `sfnt_usable` PRIMEIRO, e não por ordem estética: `stbtt_InitFont` não
    // valida nada e SEGFAULTA em bytes truncados (medido — 6 bytes de lixo
    // derrubaram o teste). Em produção este guarda só é chamado depois da
    // triagem, mas uma função que estoura conforme o chamador é uma armadilha
    // para o próximo call-site.
    if !sfnt_usable(sfnt) do return 0
    info: tt.fontinfo
    if !bool(tt.InitFont(&info, raw_data(sfnt), 0)) do return 0
    n := 0
    for i := 0; i + 1 < len(ranges) && ranges[i] != 0; i += 2 {
        for cp := rune(ranges[i]); cp <= rune(ranges[i + 1]); cp += 1 {
            if tt.FindGlyphIndex(&info, cp) != 0 do n += 1
        }
    }
    return n
}

// Bytes da rede → SFNT pronto p/ o stb (owned), ou nil.
@(private = "file")
to_sfnt :: proc(body: []byte) -> []byte {
    if is_sfnt(body) {
        if !sfnt_usable(body) do return nil
        return slice.clone(body)
    }
    if s := woff1_to_sfnt(body); s != nil {
        if !sfnt_usable(s) { delete(s); return nil }
        return s
    }
    if s, err := woff2pkg.to_sfnt(body); err == .None {
        if !sfnt_usable(s) { delete(s); return nil }
        return s
    } else {
        // `Not_Woff2` é o caso benigno (não era woff2); os outros são fonte
        // woff2 de verdade que não soubemos montar, e aí a família cai na
        // genérica em vez de a página perder o texto.
        when #config(FONTPROBE, false) {
            if err != .Not_Woff2 do fmt.eprintfln("[FONT] woff2 recusado: %v", err)
        }
        delete(s)
    }
    return nil
}

// ── download ────────────────────────────────────────────────────────────────

@(private = "file")
Face_Job :: struct { idx: int, url: string }

// Keep diagnostics bounded, especially for embedded data: fonts.
@(private)
font_log_url :: proc(url: string) -> string {
    if strings.has_prefix(url, "data:") do return "data:<embedded font>"
    return url[:min(len(url), 180)]
}

Face_Reservation :: enum { Start, Existing, Deferred, Limit }

// Main thread, with g_face_lock held. Only entries never handed to the atlas
// can be recycled: the atlas borrows the payload of every installed face.
@(private)
fontface_reserve :: proc(fid: u8, weight: int, italic: bool, url: string, now: time.Tick) -> (int, Face_Reservation) {
    retry, spare, active := -1, -1, 0
    for &f, i in g_faces {
        if f.state != .Failed do active += 1
        if f.state == .Failed && f.fonts[0] == nil do spare = i
        if f.fam_id != fid || f.weight != weight || f.italic != italic do continue
        if f.state != .Failed do return i, .Existing
        retry = i
        if f.url == url && (f.attempts >= FONT_MAX_ATTEMPTS || time.tick_diff(f.last_attempt, now) < FONT_RETRY_DELAY) {
            return i, .Deferred
        }
    }
    if active >= MAX_FACES do return -1, .Limit
    idx := retry >= 0 ? retry : spare
    attempts := 1
    if idx >= 0 {
        old := &g_faces[idx]
        if old.url == url && retry >= 0 do attempts = old.attempts + 1
        delete(old.url)
        face_release_bytes(idx) // safe: this entry never entered the atlas
    } else {
        idx = len(g_faces)
        append(&g_faces, Loaded_Face{})
    }
    g_faces[idx] = Loaded_Face{
        fam_id = fid, weight = weight, italic = italic, url = strings.clone(url),
        state = .Loading, attempts = attempts, last_attempt = now,
    }
    return idx, .Start
}

// Libera os bytes de uma entrada que NUNCA entrou no atlas (o atlas guarda
// ponteiro para o payload das que entraram). A instância é sempre da entrada;
// o `raw` só se ninguém mais o estiver usando — outra face com a mesma URL pode
// tê-lo emprestado.
@(private)
face_release_bytes :: proc(idx: int) {
    f := &g_faces[idx]
    if f.payload != nil && raw_data(f.payload) != raw_data(f.raw) do delete(f.payload)
    f.payload = nil
    if f.raw != nil && !f.raw_borrowed {
        shared := false
        for o, j in g_faces do if j != idx && o.raw != nil && raw_data(o.raw) == raw_data(f.raw) { shared = true; break }
        if !shared do delete(f.raw)
    }
    f.raw = nil
    f.raw_borrowed = false
}

// Empresta o `raw` já decodificado da face `src` para `dst` (mesma URL).
@(private)
face_borrow :: proc(dst, src: int) {
    d := &g_faces[dst]
    s := &g_faces[src]
    d.raw = s.raw
    d.raw_borrowed = true
    d.is_var = s.is_var
    d.waiting_on = 0
    d.failure = .None
    d.state = .Ready
    sync.atomic_store(&d.done, true) // o poll instancia e põe no atlas
}

@(private = "file")
g_face_lock: sync.Mutex

@(private)
fontface_retry_due :: proc(f: ^Loaded_Face, now: time.Tick) -> bool {
    return f.state == .Failed && f.retryable && f.attempts < FONT_MAX_ATTEMPTS &&
        time.tick_diff(f.last_attempt, now) >= FONT_RETRY_DELAY
}

// Caller holds g_face_lock; job URLs stay alive until the worker publishes done.
//
// UMA URL, UM download. Fonte variável servida pelo Google Fonts tem a MESMA
// URL em todas as `@font-face` de pesos diferentes; antes cada face baixava a
// sua cópia, em paralelo — e era essa rajada simultânea ao mesmo host que caía
// no travamento do PIPEWAIT (ver net.odin). Se outra face já baixou, empresta;
// se está baixando, espera por ela (`waiting_on`, resolvido no poll).
@(private)
fontface_start :: proc(idx: int) {
    me := &g_faces[idx]
    for &o, j in g_faces {
        if j == idx || o.url != me.url do continue
        if o.state == .Ready && o.raw != nil {
            face_borrow(idx, j)
            return
        }
        if o.state == .Loading && o.waiting_on == 0 && !o.derived && !sync.atomic_load(&o.done) {
            me.waiting_on = j + 1
            return
        }
    }
    me.waiting_on = 0
    job := new(Face_Job)
    job.idx = idx
    job.url = g_faces[idx].url
    if t := thread.create(face_worker); t != nil {
        t.data = job
        thread.start(t)
    } else {
        free(job)
        f := &g_faces[idx]
        f.state = .Failed
        f.failure = .Thread
        fmt.eprintfln("[FONT] family=%q weight=%d italic=%v failure=Thread", g_face_families[int(f.fam_id)-1], f.weight, f.italic)
    }
}

@(private = "file")
face_worker :: proc(t: ^thread.Thread) {
    job := (^Face_Job)(t.data)
    defer free(job)
    resp := netpkg.fetch_font(job.url)
    defer if resp.body != "" do delete(resp.body)

    payload: []byte
    failure: Face_Failure
    switch {
    case resp.err != "": failure = .Network
    case resp.status >= 400: failure = .Http
    case len(resp.body) == 0: failure = .Empty
    case:
        payload = to_sfnt(transmute([]byte)resp.body)
        if payload == nil do failure = .Decode
    }
    // Fonte variável? Só lê o `fvar` (barato); a instância é feita no poll, por
    // face, porque cada peso que compartilha este arquivo quer a sua.
    is_var := false
    if payload != nil {
        _, _, _, v := varfontpkg.weight_axis(payload)
        is_var = v
    }
    when #config(FONTPROBE, false) {
        fmt.eprintfln("[FF] worker %s: err=%q status=%d bytes=%d -> sfnt=%d",
            font_log_url(job.url), resp.err, resp.status, len(resp.body), payload != nil ? len(payload) : -1)
    }

    sync.mutex_lock(&g_face_lock)
    if job.idx < len(g_faces) {
        f := &g_faces[job.idx]
        f.raw = payload
        f.raw_borrowed = false
        f.is_var = is_var
        f.state = payload != nil ? .Ready : .Failed
        f.failure = failure
        f.retryable = failure == .Network || (failure == .Http && (resp.status == 408 || resp.status == 429 || resp.status >= 500))
        if failure != .None {
            fmt.eprintfln("[FONT] family=%q weight=%d italic=%v attempt=%d failure=%v status=%d bytes=%d error=%q url=%s",
                g_face_families[int(f.fam_id)-1], f.weight, f.italic, f.attempts, failure,
                resp.status, len(resp.body), resp.err, font_log_url(f.url))
        }
        sync.atomic_store(&f.done, true)
    } else if payload != nil {
        delete(payload)
    }
    sync.mutex_unlock(&g_face_lock)
}

// Entrada da thread PRINCIPAL: varre o CSS da página em busca de @font-face e
// registra o que achar. Barato o bastante p/ chamar a cada (re)parse — o registro
// é idempotente por (família, peso, itálico).
fontface_scan :: proc(css_text, base: string) {
    if !strings.contains(css_text, "@font-face") && !strings.contains(css_text, "@FONT-FACE") {
        when #config(FONTPROBE, false) { fmt.eprintfln("[FF] scan: nenhum @font-face no css (%d bytes)", len(css_text)) }
        return
    }
    for ch in sheet_chunks(css_text, base, context.temp_allocator) {
        scan_one(ch.css, ch.base)
    }
}

Sheet_Chunk :: struct { css, base: string } // fatias do css_text (não copiam)

// Quebra o css_text concatenado nos trechos de cada FOLHA, com a base de cada
// uma. Existe porque `url(...)` relativa resolve contra a URL DA FOLHA, não da
// página (CSS Syntax §3.3) — e sem isso o `src` de `@font-face` de todo site que
// serve CSS de subpasta virava 404. As marcas são postas pelo coletor
// (`write_sheet_mark`); texto sem marca nenhuma (folha única, teste) fica com
// `base`, que é o comportamento antigo.
sheet_chunks :: proc(css_text, base: string, alloc := context.allocator) -> []Sheet_Chunk {
    out := make([dynamic]Sheet_Chunk, alloc)
    rest := css_text
    cur := base
    for {
        i := strings.index(rest, CSS_SHEET_MARK)
        if i < 0 {
            if len(rest) > 0 do append(&out, Sheet_Chunk{rest, cur})
            return out[:]
        }
        if i > 0 do append(&out, Sheet_Chunk{rest[:i], cur})
        rest = rest[i + len(CSS_SHEET_MARK):]
        fim := strings.index(rest, ">>*/")
        if fim < 0 { // marca truncada: o resto fica com a base corrente
            if len(rest) > 0 do append(&out, Sheet_Chunk{rest, cur})
            return out[:]
        }
        cur = strings.trim_space(rest[:fim])
        if cur == "" do cur = base
        rest = rest[fim + 4:]
    }
}

@(private="file")
scan_one :: proc(css_text, base: string) {
    if !strings.contains(css_text, "@font-face") && !strings.contains(css_text, "@FONT-FACE") do return
    faces := csspkg.parse_faces_only(css_text)
    defer csspkg.free_faces(&faces)
    when #config(FONTPROBE, false) {
        fmt.eprintfln("[FF] scan: %d face(s) parseadas, base=%s", len(faces), base)
        for f in faces do fmt.eprintfln("[FF]   fam=%q w=%d it=%v srcs=%d src0=%q hint0=%q",
            f.family, f.weight, f.italic, len(f.srcs), len(f.srcs) > 0 ? font_log_url(f.srcs[0].url) : "", len(f.srcs) > 0 ? f.srcs[0].hint : "")
    }
    fontface_register(faces[:], base)
}

// Registra as @font-face de uma página e dispara os downloads. `base` resolve
// URLs relativas. Faces prontas/em download são idempotentes; falhas podem ser
// tentadas novamente num próximo scan, com intervalo e limite por URL.
fontface_register :: proc(faces: []csspkg.Font_Face, base: string) {
    sync.mutex_lock(&g_face_lock)
    defer sync.mutex_unlock(&g_face_lock)
    for face, fi in faces {
        // Um provedor publica a MESMA (família, peso, estilo) uma vez por bloco
        // Unicode, e nós só guardamos UMA. Pular a que não cobre o latim básico
        // QUANDO existe uma irmã que cobre: sem isto ficávamos com a primeira
        // declarada — `cyrillic-ext` na ordem do Google Fonts —, uma fonte sem
        // nenhuma letra do texto da página. (Se NENHUMA cobrir, registra assim
        // mesmo: melhor a face errada que nenhuma, e é o caso de página não-latina.)
        if !face.latin {
            tem_irma := false
            for outra, oi in faces {
                if oi == fi || !outra.latin do continue
                if outra.family == face.family && outra.weight == face.weight && outra.italic == face.italic {
                    tem_irma = true; break
                }
            }
            if tem_irma do continue
        }
        url_raw, ok := pick_src(face.srcs[:])
        if !ok do continue
        url := netpkg.resolve_url(base, url_raw, context.allocator)
        if url == "" do continue

        fid := fam_id_of(face.family)
        if fid == 0 { delete(url); continue }
        // Faixa (`100 900`): a chave/instância inicial é o 400 trazido para dentro
        // dela — o peso de texto corrido, que é o que quase toda página pede.
        wmin, wmax := face.weight, face.weight
        if face.weight_max > face.weight do wmax = face.weight_max
        key := clamp(400, wmin, wmax)
        idx, reservation := fontface_reserve(fid, key, face.italic, url, time.tick_now())
        delete(url)
        if reservation == .Limit {
            fmt.eprintfln("[FONT] family=%q weight=%d italic=%v skipped=atlas-limit limit=%d", face.family, key, face.italic, MAX_FACES)
        }
        if reservation != .Start do continue
        g_faces[idx].wmin, g_faces[idx].wmax = wmin, wmax

        when #config(FONTPROBE, false) { fmt.eprintfln("[FF] registra family=%q weight=%d italic=%v attempt=%d url=%s", face.family, face.weight, face.italic, g_faces[idx].attempts, font_log_url(g_faces[idx].url)) }
        fontface_start(idx)
    }
}

// ── injeção no atlas (thread principal) ─────────────────────────────────────

// Faces que aguardam o download de OUTRA (mesma URL) herdam o resultado dela:
// os bytes (emprestados) ou a falha. Caller holds g_face_lock.
@(private)
fontface_resolve_waiters :: proc(now: time.Tick) {
    for &f, i in g_faces {
        if f.waiting_on == 0 || f.state != .Loading do continue
        j := f.waiting_on - 1
        if j < 0 || j >= len(g_faces) || j == i || g_faces[j].url != f.url {
            fontface_start(i) // a fonte foi reciclada: baixa por conta própria
            continue
        }
        src := &g_faces[j]
        switch src.state {
        case .Loading: // segue esperando
        case .Ready:
            if src.raw != nil { face_borrow(i, j) } else { fontface_start(i) }
        case .Failed:
            f.waiting_on = 0
            f.state = .Failed
            f.failure = src.failure
            f.retryable = src.retryable
            f.last_attempt = now
            fmt.eprintfln("[FONT] family=%q weight=%d italic=%v failure=%v shared-download url=%s",
                g_face_families[int(f.fam_id)-1], f.weight, f.italic, src.failure, font_log_url(f.url))
        }
    }
}

// 1×/frame: promove faces baixadas para o atlas e reconstrói se preciso.
// Devolve true quando o atlas mudou (o chamador não precisa fazer nada — a
// textura já foi refeita —, mas o layout deve ser reconstruído, porque as
// métricas de texto mudaram).
fontface_poll :: proc() -> bool {
    io := im.GetIO()
    if io == nil || io.Fonts == nil do return false
    added := native_fonts_add(io.Fonts)

    sync.mutex_lock(&g_face_lock)
    active := 0
    for f in g_faces do if f.state != .Failed do active += 1
    now := time.tick_now()
    for &f, i in g_faces {
        if active >= MAX_FACES || !fontface_retry_due(&f, now) do continue
        f.state = .Loading
        f.failure = .None
        f.retryable = false
        f.attempts += 1
        f.last_attempt = now
        sync.atomic_store(&f.done, false)
        fmt.eprintfln("[FONT] family=%q weight=%d italic=%v retry=%d url=%s", g_face_families[int(f.fam_id)-1], f.weight, f.italic, f.attempts, font_log_url(f.url))
        fontface_start(i)
        active += 1
    }
    fontface_resolve_waiters(now)
    for &f, i in g_faces {
        if !sync.atomic_load(&f.done) do continue
        sync.atomic_store(&f.done, false)
        if f.state != .Ready || f.raw == nil do continue
        // Instância no peso DESTA face. Fonte estática, CFF2 ou peso = default
        // → o próprio `raw` (comportamento de antes deste marco).
        f.payload = f.raw
        if f.is_var {
            inst, e := varfontpkg.instantiate_weight(f.raw, f32(f.weight))
            if e == .None {
                f.payload = inst
            } else if e != .Default {
                fmt.eprintfln("[FONT] family=%q weight=%d italic=%v variation=%v (usando a instância padrão) url=%s",
                    g_face_families[int(f.fam_id)-1], f.weight, f.italic, e, font_log_url(f.url))
            }
            when #config(FONTPROBE, false) {
                fmt.eprintfln("[FF] instancia weight=%d -> %v (%d bytes)", f.weight, e, len(f.payload))
            }
        }
        // ⚠️ ver `face_glyph_count_in_ranges`: face com ZERO glifo aborta o
        // processo lá embaixo, DENTRO do FontAtlas_Build. Esta entrada nunca
        // entra no atlas: seu payload pode ser reciclado no próximo registro.
        // O FONTPROBE imprime a contagem de TODA face, não só das recusadas: é
        // a evidência que faltou quando eu tentei atribuir um crash a este
        // caminho sem número na mão.
        n_glifos := face_glyph_count_in_ranges(f.payload, g_text_ranges[:])
        when #config(FONTPROBE, false) {
            fmt.eprintfln("[FF] face %s: %d glifos nos ranges do atlas%s",
                font_log_url(f.url), n_glifos, n_glifos == 0 ? " -> RECUSADA (abortaria o Build)" : "")
        }
        if n_glifos == 0 {
            f.state = .Failed // `fontface_pick` pula: a família cai na genérica
            f.failure = .No_Glyphs
            fmt.eprintfln("[FONT] family=%q weight=%d italic=%v failure=No_Glyphs url=%s", g_face_families[int(f.fam_id)-1], f.weight, f.italic, font_log_url(f.url))
            continue
        }
        for sz, k in g_font_sizes {
            cfg := im.FontConfig{
                // ⚠️ os bytes são NOSSOS: o atlas os usaria e LIBERARIA (default
                // FontDataOwnedByAtlas=true), e as FONT_N entradas compartilham o
                // MESMO buffer — o 2º free seria duplo.
                FontDataOwnedByAtlas = false,
                OversampleH = 2, OversampleV = 1,
                GlyphMaxAdvanceX = 3.4028235e38,
                RasterizerMultiply = 1.0, RasterizerDensity = 1.0,
                EllipsisChar = 0xFFFF,
            }
            f.fonts[k] = im.FontAtlas_AddFontFromMemoryTTF(
                io.Fonts, raw_data(f.payload), c.int(len(f.payload)), sz, &cfg, &g_text_ranges[0])
        }
        added = true
        _ = i
    }
    sync.mutex_unlock(&g_face_lock)

    when #config(FONTPROBE, false) { if added do fmt.eprintfln("[FF] poll: face(s) entraram no atlas, rebuild") }
    if !added do return false
    // O rebuild: ver `browser.exe --fonttest`, que prova que os ^Font ANTIGOS
    // sobrevivem e que a face nova rasteriza depois disto.
    imgui_sdlr.DestroyFontsTexture()
    if !im.FontAtlas_Build(io.Fonts) do return false
    text_metrics_clear()
    imgui_sdlr.CreateFontsTexture()
    // Razão em-square das faces novas: só AGORA, com o atlas construído, o
    // avanço do glifo existe para ser medido (ver em_ratio_medido).
    for &f in g_faces {
        if f.state != .Ready || f.em != 0 || f.fonts[0] == nil do continue
        if r, k := em_ratio_medido(f.payload, f.fonts[0]); k { f.em = r } else { f.em = g_em_sans }
    }
    g_faces_dirty = true
    return true
}

// Resolve (família, peso, itálico) → fonte do atlas. Devolve nil quando não há
// face pronta: o chamador cai na pilha genérica (degradação).
// A escolha de peso é a mais próxima, com desempate para o mais PESADO (é o que
// os navegadores fazem para pedidos ≥ 400).
fontface_pick :: proc(fam_id: u8, weight: int, italic: bool, step: int) -> (^im.Font, f32) {
    if fam_id == 0 do return nil, 0
    best := -1
    best_cost := 1 << 30
    for f, i in g_faces {
        if f.fam_id != fam_id || f.state != .Ready do continue
        if f.fonts[step] == nil do continue
        // Distância à FAIXA da face (css-fonts §5.2: peso dentro da faixa casa).
        lo, hi := f.weight, f.weight
        if f.wmax > f.wmin do lo, hi = f.wmin, f.wmax
        dist := weight < lo ? lo - weight : (weight > hi ? weight - hi : 0)
        cost := dist * 4
        // Dentro da faixa mas instanciada noutro peso: serve agora, e a instância
        // EXATA (derivada abaixo) ganha quando ficar pronta.
        if dist == 0 && f.weight != weight do cost += 1
        if f.italic != italic do cost += 2000 // itálico errado é pior que peso errado
        if cost < best_cost { best_cost = cost; best = i }
    }
    if best >= 0 {
        b := g_faces[best]
        if b.is_var && b.wmax > b.wmin && b.italic == italic && b.weight != weight &&
           weight >= b.wmin && weight <= b.wmax {
            fontface_derive(best, weight)
        }
    }
    when #config(FONTPROBE, false) {
        // Log changes rather than just the first five calls (often made before
        // any download completed). Include the actual selected variant.
        @(static) previous: map[u32]int
        if previous == nil do previous = make(map[u32]int)
        key := u32(fam_id) << 17 | u32(weight) << 1 | u32(italic ? 1 : 0)
        last, seen := previous[key]
        if !seen || last != best {
            previous[key] = best
            if best >= 0 {
                f := &g_faces[best]
                fmt.eprintfln("[FF] pick fam=%d requested-weight=%d requested-italic=%v -> weight=%d italic=%v url=%s", fam_id, weight, italic, f.weight, f.italic, font_log_url(f.url))
            } else {
                fmt.eprintfln("[FF] pick fam=%d requested-weight=%d requested-italic=%v -> generic fallback", fam_id, weight, italic)
            }
        }
    }
    if best < 0 do return nil, 0
    return g_faces[best].fonts[step], g_faces[best].em
}

// Cria (se ainda não existe) a instância de `weight` de uma face variável de
// FAIXA. Não baixa nada: empresta o `raw` da mãe; o poll seguinte instancia e
// põe no atlas, e o relayout que ele provoca passa a escolher a derivada.
// Teto: o mesmo MAX_FACES — estourou, segue com a instância da mãe, calado
// (isto roda por item de texto; um log aqui inundaria o stderr).
@(private)
fontface_derive :: proc(parent: int, weight: int) {
    sync.mutex_lock(&g_face_lock)
    defer sync.mutex_unlock(&g_face_lock)
    p := g_faces[parent]
    if p.state != .Ready || p.raw == nil do return
    idx, r := fontface_reserve(p.fam_id, weight, p.italic, p.url, time.tick_now())
    if r != .Start do return
    d := &g_faces[idx]
    d.wmin, d.wmax = weight, weight
    d.derived = true
    face_borrow(idx, parent)
    when #config(FONTPROBE, false) {
        fmt.eprintfln("[FF] deriva weight=%d da faixa %d..%d url=%s", weight, p.wmin, p.wmax, font_log_url(p.url))
    }
}

// Alguma face ainda baixando? O `--render` headless não tem tempo de parede:
// ele pinta N frames e sai. Sem isto o laço termina ANTES de a fonte chegar e a
// página é capturada com a família genérica — foi exatamente o que aconteceu na
// 1ª prova ponta-a-ponta (o worker só imprimiu DEPOIS do último poll).
// Mesmo papel do `images_pending()` para imagens.
fontface_pending :: proc() -> bool {
    if native_fonts_pending() do return true
    sync.mutex_lock(&g_face_lock)
    defer sync.mutex_unlock(&g_face_lock)
    for &f in g_faces {
        if f.state == .Loading && !sync.atomic_load(&f.done) do return true
        // pronta mas ainda não promovida ao atlas (emprestada/derivada: o poll
        // seguinte a instancia) — o `--render` não pode sair antes disso
        if sync.atomic_load(&f.done) do return true
        if f.state == .Failed && f.retryable && f.attempts < FONT_MAX_ATTEMPTS do return true
    }
    return false
}

// Alguma face desta família já está pronta? (p/ decidir se vale usar o id)
fontface_family_ready :: proc(fam_id: u8) -> bool {
    if fam_id == 0 do return false
    for f in g_faces do if f.fam_id == fam_id && f.state == .Ready do return true
    return false
}


// Razão em-square MEDIDA de uma face já no atlas.
//
// Compara o avanço de um glifo pelos DOIS lados: em unidades de em (pelo stb, a
// partir dos bytes da fonte) e em pixels (pelo ImGui, que já assou a face). O
// quociente dá o tamanho real do em em pixels, e daí a razão que `render_px`
// precisa. É empírico DE PROPÓSITO: nenhuma tabela do sfnt previu o que o stb
// faz com o Consolas (hhea diz 1,0000, o necessário medido é 1,0922), então
// deduzir da tabela erra em silêncio — medir, não.
//
// ok=false se a fonte não parseia ou o glifo de referência não existe; aí o
// chamador fica com o valor anterior e nada piora.
em_ratio_medido :: proc(blob: []byte, f: ^im.Font) -> (f32, bool) {
    if f == nil || len(blob) == 0 do return 0, false
    info: tt.fontinfo
    ini := bool(tt.InitFont(&info, raw_data(blob), 0))
    when #config(EMPROBE, false) { fmt.eprintfln("[em]   InitFont=%v", ini) }
    if !ini do return 0, false
    REF :: rune('M') // presente em toda face de texto latino
    adv_u, lsb: i32
    tt.GetCodepointHMetrics(&info, REF, &adv_u, &lsb)
    // avanço como FRAÇÃO do em (ScaleForMappingEmToPixels(1) = 1/unitsPerEm)
    adv_em := f32(adv_u) * tt.ScaleForMappingEmToPixels(&info, 1.0)
    // ⚠️ mede com `Font_CalcTextSizeA`, a MESMA função que o layout usa — e não
    // lendo `ImFontGlyph.AdvanceX`. A struct de glifo do ImGui tem bitfields, e
    // o binding devolvia 4,333px para o 'M' da Segoe UI a 16px (o certo é ~11):
    // campo errado, número plausível. Medir pelo caminho de produção não tem
    // como divergir do que a página vai usar.
    adv_px := im.Font_CalcTextSizeA(f, f.FontSize, 3.4028235e38, 3.4028235e38, "M").x
    when #config(EMPROBE, false) {
        fmt.eprintfln("[em]   adv_u=%d adv_em=%.4f adv_px=%.3f FontSize=%.1f", adv_u, adv_em, adv_px, f.FontSize)
    }
    if adv_u <= 0 do return 0, false
    if adv_em <= 0 do return 0, false
    if adv_px <= 0 do return 0, false
    em_px := adv_px / adv_em                // tamanho do em, em px, no tamanho assado
    if em_px <= 0 || f.FontSize <= 0 do return 0, false
    r := f.FontSize / em_px
    if r < 0.5 || r > 3.0 do return 0, false // sanidade: fora disto é lixo
    return r, true
}

// ── expostos p/ os testes (a lógica de decode é pura e testável sem atlas) ────
test_sfnt_usable :: proc(b: []byte) -> bool { return sfnt_usable(b) }
test_to_sfnt :: proc(b: []byte) -> []byte { return to_sfnt(b) }
test_pick_src :: proc(srcs: []csspkg.Font_Src) -> (string, bool) { return pick_src(srcs) }
