package ui

// Carregamento e cache de imagens (<img>).
//
// Fluxo (sem travar a UI):
//   1. render pede image_get(url) -> cria entrada "Loading" e enfileira
//   2. images_poll (main loop) inicia downloads respeitando um limite
//   3. uma thread baixa (libcurl) e decodifica (stb_image) -> pixels RGBA
//   4. images_poll cria a textura SDL a partir dos pixels (SDL exige a
//      thread principal/dona do renderer) e marca "Ready"
//   5. render desenha a textura com im.Image

import "core:fmt"
import "core:c"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import "base:intrinsics"
import sdl2   "vendor:sdl2"
import stbi   "vendor:stb/image"
import webp   "../../vendor/webp"
import netpkg "../net"
import dompkg "../dom"
import htmlp  "../html"

IMG_MAX_ACTIVE :: 4 // downloads simultâneos (baixo p/ não provocar 429 em CDNs sensíveis, ex. upload.wikimedia)

Img_State :: enum { Loading, Ready, Failed }

Img :: struct {
    url:     string,
    state:   Img_State,
    pending: bool,          // ainda não começou a baixar
    tex:     ^sdl2.Texture, // criada na thread principal
    w, h:    int,           // dimensões (pixels)

    // handoff worker -> main
    done:    b32,           // sinalizado atomicamente
    ok:      bool,
    pixels:  [^]byte,       // RGBA decodificado, liberado após upload
    pw, ph:  int,
    is_webp: bool,          // pixels vieram da libwebp (free diferente do stb)

    // SVG (<img src=".svg">): vetorial, sem textura. O worker guarda os bytes;
    // o poll (main thread) parseia em DOM e o paint chama paint_svg_node.
    http_status: int,          // código HTTP da última tentativa (p/ retry em 429/503)
    retry_after: int,          // Retry-After (s) da última resposta 429/503 (0 = ausente)
    retries:  int,             // tentativas já feitas (rate-limit)
    next_try_ns: i64,          // instante (relógio monotônico, ns) a partir do qual pode re-tentar
    is_svg:   bool,
    svg_src:  string,          // handoff: texto do SVG (liberado após o parse)
    svg_dom:  ^dompkg.Node,    // documento parseado (dono; liberado em free)
    svg_root: ^dompkg.Node,    // o elemento <svg> dentro do documento

    last_used: int,            // g_frame do último image_get (evicção LRU)
    // Bytes de pixel desta entrada (w*h*4), gravados quando a textura sobe. Fica
    // num CAMPO, e não derivado de `tex`, para o custo ser inspecionável sem
    // depender de recurso de GPU — é o que deixa a evicção testável em `odin test`
    // (que não tem renderer). SVG é vetorial e continua pesando 0.
    bytes:     int,
}

g_images:    map[string]^Img
g_img_active: int

// Pacing POR HOST: instante (relógio monotônico, ns) mínimo p/ INICIAR o próximo
// request àquele host. CDNs anti-abuso (upload.wikimedia) estrangulam por TAXA —
// disparar 4 concorrentes na carga estoura a rajada e devolve 429 mesmo com o
// Retry-After honrado. Espaçamos requests ao mesmo host; um 429 estende o cooldown
// pelo Retry-After inteiro. Acesso só na thread principal (images_poll) → sem lock.
g_host_next_ns: map[string]i64
IMG_HOST_SPACE_MS :: 150 // espaçamento normal entre inícios ao MESMO host (~6/s)

// Host de uma URL "scheme://host/resto" (fatia da própria url, sem alocar).
@(private="file")
url_host :: proc(url: string) -> string {
    s := url
    if i := strings.index(s, "://"); i >= 0 do s = s[i + 3:]
    if i := strings.index_any(s, "/?#"); i >= 0 do s = s[:i]
    return s
}

// Devolve (criando se preciso) a entrada de cache para uma URL de imagem.
image_get :: proc(url: string) -> ^Img {
    if img, ok := g_images[url]; ok {
        img.last_used = g_frame // carimbo de USO (evicção LRU; ver images_evict)
        return img
    }
    img := new(Img)
    img.url     = strings.clone(url)
    img.state   = .Loading
    img.pending = true
    img.last_used = g_frame
    g_images[img.url] = img
    return img
}

// Se `url` for uma imagem SVG já baixada e parseada, devolve o nó <svg> raiz
// (p/ o paint renderizar vetorialmente). Senão nil. Dispara o download na 1ª
// chamada (image_get cria a entrada Loading) — como qualquer <img>.
svg_image_root :: proc(url: string) -> ^dompkg.Node {
    if url == "" do return nil
    img := image_get(url)
    if img.state == .Ready && img.is_svg do return img.svg_root
    return nil
}

// Esta imagem pode ser desenhada como TEXTURA (AddImage)? Um SVG fica `.Ready`
// SEM textura de propósito (é vetorial: o <img> é interceptado no paint e vai
// p/ paint_svg_node). O background-image não tem caminho vetorial, e desenhar
// assim mesmo passava `TextureID(0)` ao backend — que pinta um QUAD BRANCO
// OPACO. Com o repeat default isso LADRILHAVA branco sobre a caixa inteira,
// apagando o background-color: era a página do php.net inteira branca com o
// texto ilegível (`html{background-color:#333; background-image:url(.svg)}`).
// Sem textura o certo é não desenhar nada — a cor/gradiente por baixo fica.
bg_image_drawable :: proc(img: ^Img) -> bool {
    return img != nil && img.state == .Ready && img.tex != nil && img.w > 0 && img.h > 0
}

// Há alguma imagem ainda não resolvida (pendente de download ou baixando)?
// Usado pelo headless p/ DRENAR imagens antes de capturar (sem loop de tempo
// real, os poucos frames não bastam p/ os downloads assíncronos terminarem).
images_pending :: proc() -> bool {
    for _, img in g_images {
        if img.state == .Loading do return true
    }
    return false
}

// Libera TUDO de uma entrada de imagem: textura SDL, pixels ainda não subidos, o
// DOM do SVG, o handoff de texto e a própria URL (clonada em `image_get`).
//
// ⚠️ a textura é o item caro e era o que NUNCA era destruído: `images_poll` fazia
// `sdl2.CreateTexture` e não existia UM `DestroyTexture` no arquivo inteiro. Uma
// textura é memória do lado C (VRAM + cópia do host), invisível para o
// `TRACK_ALLOC`; ver a caçada do M177 em [[css-style-perf]].
@(private="file")
img_free :: proc(img: ^Img) {
    if img == nil do return
    if img.tex != nil { sdl2.DestroyTexture(img.tex); img.tex = nil }
    if img.pixels != nil {
        // o free TEM de casar com quem alocou (libwebp vs stb) — trocar os dois
        // corrompe o heap em vez de liberar.
        if img.is_webp {
            webp.WebPFree(img.pixels)
        } else {
            stbi.image_free(img.pixels)
        }
        img.pixels = nil
    }
    if img.svg_dom != nil { dompkg.free_tree(img.svg_dom); img.svg_dom = nil; img.svg_root = nil }
    if img.svg_src != "" { delete(img.svg_src); img.svg_src = "" }
    delete(img.url)
    free(img)
}

// Orçamento do cache de imagens, em BYTES de pixel (w*h*4 — o que a textura custa
// na GPU e no host). 128 MB cabe folgadamente a área visível de qualquer página
// real (uma tela cheia de 1280×900 são 4,6 MB) e ainda guarda muita coisa fora de
// tela; o objetivo é ter TETO, não ser esperto.
IMG_CACHE_BUDGET :: 128 * 1024 * 1024

// Bytes de pixel de uma entrada. SVG não tem textura (é vetorial) → pesa 0.
@(private="file")
img_bytes :: proc(img: ^Img) -> int {
    if img == nil do return 0
    return img.bytes
}

// Evicção LRU do cache de imagens, chamada uma vez por frame no fim do
// `images_poll`. Sem isto o cache é ILIMITADO: toda imagem de toda página
// visitada fica na memória até o processo morrer (ver [[css-style-perf]] M178).
//
// Três invariantes, todas necessárias — a 1ª por CORREÇÃO, as outras 2 por não
// transformar cache em re-download em laço:
//   1. só evicta `.Ready`. Uma entrada `.Loading` tem um WORKER em outra thread
//      escrevendo dentro dela (img.pixels/img.done); liberá-la é use-after-free.
//   2. nunca evicta o que foi usado nos 2 últimos frames — é o que está NA TELA
//      (mesmo raciocínio do cache de layers: a textura usada no frame F ainda é
//      lida pelo render de F, então só é seguro a partir de F+2).
//   3. evicta do MENOS usado p/ o mais usado, só até voltar ao orçamento.
//
// ⚠️ evicção é segura porque ninguém guarda `^Img` entre frames — todo uso é
// `image_get(url)` seguido de uso imediato (conferido: layout.odin e render.odin).
// Se algum dia um Box passar a guardar o ponteiro, isto vira UAF.
//
// Visível ao pacote (não `private="file"`) para os testes exercitarem a política.
images_evict :: proc() {
    total := 0
    for _, img in g_images do total += img_bytes(img)
    if total <= IMG_CACHE_BUDGET do return

    // candidatos: prontos e fora da janela de proteção, do mais VELHO p/ o mais novo
    cands := make([dynamic]^Img, 0, 16, context.temp_allocator)
    for _, img in g_images {
        if img.state != .Ready do continue          // invariante 1
        if img.last_used >= g_frame - 1 do continue // invariante 2
        if img_bytes(img) == 0 do continue          // SVG: não libera bytes de textura
        append(&cands, img)
    }
    slice.sort_by(cands[:], proc(a, b: ^Img) -> bool { return a.last_used < b.last_used })

    liberado := 0
    for img in cands {
        if total - liberado <= IMG_CACHE_BUDGET do break
        liberado += img_bytes(img)
        delete_key(&g_images, img.url) // a chave É a img.url; tirar do mapa ANTES do free
        img_free(img)
    }
}

// Esvazia o cache de imagens. Chamado no encerramento de cada modo (headless e
// janela), p/ o processo sair sem segurar textura — e p/ o relatório do
// TRACK_ALLOC não afogar o sinal em ruído de imagem viva.
//
// ⚠️ NÃO chamar entre páginas: `g_images` é cache POR URL de propósito (revisitar
// a mesma imagem não deve re-baixar). O que falta p/ uma sessão longa é uma
// política de EVICÇÃO por tamanho/uso — anotado, não embutido aqui: seria mudança
// de comportamento, não conserto de vazamento.
images_free_all :: proc() {
    for _, img in g_images do img_free(img)
    clear(&g_images)
    clear(&g_host_next_ns)
    // ⚠️ NÃO libere aqui a fonte de emoji. O M188 tinha posto `emoji_shutdown()`
    // nesta linha, e é acoplamento errado: "esvaziar o cache de imagens" não é
    // "descarregar a fonte". Em teste isso virou CORRIDA — o teste de evicção
    // chama images_free_all() e derrubava a fonte por baixo dos testes de emoji
    // que rodavam em paralelo. Quem libera a fonte é o shutdown de verdade
    // (browser_ui/headless, ao lado do defer images_free_all).
}

// Contagem por estado (diagnóstico do dreno headless).
images_stats :: proc() -> (ready, loading, failed: int) {
    for _, img in g_images {
        switch img.state {
        case .Ready:   ready += 1
        case .Loading: loading += 1
        case .Failed:  failed += 1
        }
    }
    return
}


IMG_MAX_RETRIES :: 5 // CDNs que estrangulam por TAXA (upload.wikimedia: libera ~4 e
                     // depois manda 429 com `Retry-After: 1`) recuperam se esperarmos
                     // o tempo pedido; poucas tentativas rápidas só desistem cedo demais.

// Hash FNV-1a de 32 bits — só p/ derivar um jitter estável por URL (espalha as
// re-tentativas no tempo; sem isto todas re-disparariam juntas e re-tomariam 429).
@(private="file")
url_hash :: proc(s: string) -> u32 {
    h: u32 = 2166136261
    for b in transmute([]u8)s { h = (h ~ u32(b)) * 16777619 }
    return h
}

// Re-enfileira uma imagem que falhou por rate-limit (429/503). Espera pelo menos o
// `Retry-After` do servidor (default 1s) mais um degrau por tentativa e um jitter
// por URL, p/ NÃO re-disparar todas as imagens no mesmo instante (o que re-bursta e
// re-toma 429). Backoff em RELÓGIO (não em frames): a cadência do poll varia com o
// FPS e com o dreno headless. Devolve true se re-enfileirou.
@(private="file")
img_retry :: proc(img: ^Img) -> bool {
    if (img.http_status != 429 && img.http_status != 503) || img.retries >= IMG_MAX_RETRIES {
        return false
    }
    img.retries += 1
    wait_s := img.retry_after > 0 ? img.retry_after : 1
    jitter_ms := i64(url_hash(img.url) % 900)             // 0..899ms, estável por URL
    step_ms   := i64(img.retries - 1) * 500                // +0.5s por tentativa já feita
    delay_ns  := i64(wait_s) * 1_000_000_000 + (step_ms + jitter_ms) * 1_000_000
    now_ns    := time.tick_now()._nsec
    img.next_try_ns = now_ns + delay_ns
    // segura o HOST INTEIRO pelo Retry-After: as outras imagens do mesmo CDN não
    // adianta disparar antes disso (só re-bustariam o 429).
    host := url_host(img.url)
    hn := now_ns + i64(wait_s) * 1_000_000_000
    if cur, ok := g_host_next_ns[host]; !ok || hn > cur do g_host_next_ns[host] = hn
    img.ok = false
    img.is_svg = false
    intrinsics.atomic_store(&img.done, false)
    img.pending = true
    img.state = .Loading
    return true
}

// Chamado a cada frame na thread principal: sobe texturas prontas e
// inicia downloads pendentes respeitando o limite de concorrência.
images_poll :: proc(renderer: ^sdl2.Renderer) {
    for _, img in g_images {
        // entrega de downloads concluídos
        if img.state == .Loading && !img.pending && bool(intrinsics.atomic_load(&img.done)) {
            if img.ok && img.is_svg && img.svg_src != "" {
                // parse do SVG na thread principal (o parser aloca DOM). Achamos o
                // <svg> e o dimensionamento intrínseco (viewBox → width/height → 24).
                dom := htmlp.parse(img.svg_src)
                root := dompkg.find_first(dom, "svg")
                if root != nil {
                    img.svg_dom  = dom
                    img.svg_root = root
                    iw, ih := svg_intrinsic_size(root)
                    img.w = int(iw); img.h = int(ih)
                    img.state = .Ready
                } else {
                    dompkg.free_tree(dom)
                    img.state = .Failed
                }
                delete(img.svg_src); img.svg_src = ""
                g_img_active -= 1
                continue
            }
            if img.ok && img.pixels != nil {
                // defesa: se esta entrada já tinha textura (re-entrega da MESMA
                // URL), a antiga tem de morrer antes de ser sobrescrita — senão
                // fica órfã, sem ninguém para destruí-la.
                if img.tex != nil { sdl2.DestroyTexture(img.tex); img.tex = nil }
                tex := sdl2.CreateTexture(renderer, .RGBA32, .STATIC, c.int(img.pw), c.int(img.ph))
                if tex != nil {
                    sdl2.UpdateTexture(tex, nil, img.pixels, c.int(img.pw * 4))
                    sdl2.SetTextureBlendMode(tex, .BLEND)
                    img.tex   = tex
                    img.w     = img.pw
                    img.h     = img.ph
                    img.bytes = img.pw * img.ph * 4 // custo p/ a evicção
                    img.state = .Ready
                } else {
                    img.state = .Failed
                }
                if img.is_webp {
                    webp.WebPFree(img.pixels)
                } else {
                    stbi.image_free(img.pixels)
                }
                img.pixels = nil
                g_img_active -= 1
            } else {
                // fetch OK mas não decodou: pode ser página de erro 429/503 (rate-limit) → retry.
                g_img_active -= 1
                if !img_retry(img) do img.state = .Failed
            }
        }
    }

    // inicia pendentes (ou re-tentativas cujo backoff já venceu) enquanto há vaga.
    // next_try_ns=0 nas imagens novas → dispara já; >0 só após um 429/503 (honra Retry-After).
    // Além disso respeita o pacing POR HOST (g_host_next_ns) p/ não estourar a rajada.
    now_ns := time.tick_now()._nsec
    for _, img in g_images {
        if !img.pending do continue
        // Emoji (esquema "emoji:") não tem rede: rasteriza LOCALMENTE e sobe a
        // textura aqui mesmo. Não gasta vaga de download nem pacing de host —
        // são microssegundos de stb_truetype. Ver emoji.odin.
        if strings.has_prefix(img.url, EMOJI_SCHEME) {
            img.pending = false
            emoji_img_upload(img, renderer)
            continue
        }
        if now_ns < img.next_try_ns || g_img_active >= IMG_MAX_ACTIVE do continue
        // `data:` traz o conteúdo consigo: vai ao worker (o decode é caro e fica
        // fora da thread principal), mas SEM pacing por host. Sem esta guarda todas
        // as data URIs cairiam no mesmo "host" sintético e seriam serializadas a uma
        // por 150 ms — uma página com 20 ícones inline levaria 3 s para aparecer.
        if !strings.has_prefix(img.url, "data:") {
            host := url_host(img.url)
            if hn, ok := g_host_next_ns[host]; ok && now_ns < hn do continue // host em pacing/cooldown
            g_host_next_ns[host] = now_ns + IMG_HOST_SPACE_MS * 1_000_000    // espaça o próximo do mesmo host
        }
        img.pending = false
        g_img_active += 1
        thread.create_and_start_with_poly_data(img, image_worker, self_cleanup = true)
    }

    images_evict() // teto do cache (LRU); no-op enquanto estiver dentro do orçamento
}

// Thread de trabalho: baixa e decodifica para RGBA.
@(private="file")
image_worker :: proc(img: ^Img) {
    dbg_adopt_allocator() // alocador tracked global em debug (evita falso bad-free)
    resp := netpkg.fetch(img.url)
    img.http_status = resp.status
    img.retry_after = resp.retry_after
    if resp.ok && len(resp.body) > 0 {
        data := raw_data(resp.body)
        n    := c.int(len(resp.body))
        w, h, ch: c.int

        // 1) stb_image: PNG, JPEG, GIF, BMP...
        px := stbi.load_from_memory(data, n, &w, &h, &ch, 4)
        if px != nil {
            img.pixels = px
            img.pw = int(w); img.ph = int(h)
            img.ok = true
        } else {
            // 2) fallback WebP (libwebp)
            ww, hh: c.int
            wp := webp.WebPDecodeRGBA(data, c.size_t(len(resp.body)), &ww, &hh)
            if wp != nil {
                img.pixels  = wp
                img.pw = int(ww); img.ph = int(hh)
                img.ok = true
                img.is_webp = true
            } else if body_is_svg(resp.body) {
                // 3) SVG: não é raster — guarda os bytes; a main thread parseia e
                // o paint renderiza vetorialmente (paint_svg_node). Copiado pois
                // resp.body é liberado abaixo.
                img.svg_src = strings.clone(resp.body)
                img.is_svg = true
                img.ok = true
            }
        }
    }
    if resp.ok do delete(resp.body)
    intrinsics.atomic_store(&img.done, true)
}

// Sniff: os primeiros ~256 bytes contêm "<svg" (aceita prólogo <?xml / comentário
// / DOCTYPE antes). Robusto a content-type ausente ou errado do servidor.
@(private="file")
body_is_svg :: proc(body: string) -> bool {
    n := min(len(body), 256)
    head := strings.to_lower(body[:n], context.temp_allocator)
    return strings.contains(head, "<svg")
}

// Tamanho intrínseco de um <svg>: os atributos width/height são o tamanho de
// EXIBIÇÃO; o viewBox é só o sistema de coordenadas. Ordem correta = width/height
// → viewBox → 24×24. (Antes usava o viewBox primeiro → o logo do HN, viewBox
// 188×188 mas width/height=18, renderizava a 188px = triângulo laranja gigante.)
svg_intrinsic_size :: proc(root: ^dompkg.Node) -> (w, h: f32) {
    w = attr_num(root, "width"); h = attr_num(root, "height")
    if w > 0 && h > 0 do return w, h
    if _, _, vw, vh, ok := svg_viewbox(root); ok && vw > 0 && vh > 0 do return vw, vh
    if w <= 0 do w = 24
    if h <= 0 do h = 24
    return w, h
}
