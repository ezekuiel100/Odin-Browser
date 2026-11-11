package main

import "core:os"
import "core:fmt"
import "core:mem"
import "core:sort"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import ui "src/ui"
import js "src/js"

// Rastreador de alocação, COMPILE-GATED (custo zero quando off, como o GRID_DEBUG):
//   odin build . -define:TRACK_ALLOC=true ...
// Ao sair, imprime o que NÃO foi liberado, agregado POR LOCAL DE CÓDIGO e ordenado
// por bytes. Escrito p/ caçar o vazamento por-frame do render (memória cresce ~300
// MB/s numa página de 3000 caixas) — bissecção por fixture já tinha estreitado até
// "pintura de caixa", mas só o local exato encerra a discussão.
TRACK_ALLOC :: #config(TRACK_ALLOC, false)

when TRACK_ALLOC {
    g_track: ^mem.Tracking_Allocator

    // ⚠️ chamado À MÃO antes de cada os.exit: `defer` NÃO roda em os.exit, e todo
    // modo headless sai por ali.
    track_report :: proc() {
        if g_track == nil do return
        Local :: struct { loc: string, bytes: int, n: int }
        agg := make(map[string]Local, 256, g_track.backing)
        for _, e in g_track.allocation_map {
            k := fmt.aprintf("%s:%d", e.location.file_path, e.location.line, allocator = g_track.backing)
            v := agg[k]
            v.loc = k; v.bytes += e.size; v.n += 1
            agg[k] = v
        }
        lista := make([dynamic]Local, 0, len(agg), g_track.backing)
        for _, v in agg do append(&lista, v)
        sort.quick_sort_proc(lista[:], proc(a, b: Local) -> int { return b.bytes - a.bytes })
        total := 0
        for v in lista do total += v.bytes
        fmt.eprintfln("\n[TRACK_ALLOC] %d blocos NAO liberados, %.1f MB, em %d locais:",
            len(g_track.allocation_map), f64(total) / (1024 * 1024), len(lista))
        for v, i in lista {
            if i >= 15 do break
            fmt.eprintfln("  %8.2f MB  %6d blocos  %s", f64(v.bytes) / (1024 * 1024), v.n, v.loc)
        }
    }
}

// Força o link contra a SDL2 2.28.3 (que tem SDL_RenderGeometryRaw,
// exigida pelo backend SDL_Renderer do ImGui). Sem isto, o `odin run .`
// linka contra a SDL2 antiga embutida no Odin e falha.
when ODIN_OS == .Windows {
    @(require) foreign import _sdl2_new "vendor/imgui/backend_deps/SDL2-bin/SDL2.lib"
}

// `--js-timeout <ms>` (ou `--js-timeout=<ms>`): teto de tempo de PAREDE por tarefa
// de JS. `0` desliga o watchdog. Ausente = TIME_BUDGET_MS (4000 ms).
//
// ⚠️ a flag é REMOVIDA da lista devolvida: todos os modos da CLI são POSICIONAIS
// (`--render <url> <png> <w> <h> <mx> <my> <frames> …`), então um argumento extra
// no meio deslocaria todos os índices seguintes.
//
// Para que serve, concretamente (medido no M181): com o teto padrão o bootstrap do
// open.spotify.com é abortado com `RangeError: tempo de execução excedido`; com
// `--js-timeout 60000` ele roda sem exceção nenhuma e só não termina por lentidão
// do interpretador. É a flag que separa "falta feature" de "está lento" — sem
// afrouxar o default, que existe p/ não congelar a UI numa página patológica.
@(private = "file")
extrai_js_timeout :: proc(argv: []string) -> []string {
    PREFIXO :: "--js-timeout="
    out := make([dynamic]string, 0, len(argv))
    i := 0
    for i < len(argv) {
        a := argv[i]
        if strings.has_prefix(a, PREFIXO) {
            if v, ok := strconv.parse_f64(a[len(PREFIXO):]); ok do js.set_time_budget_ms(v)
            i += 1
            continue
        }
        if a == "--js-timeout" && i + 1 < len(argv) {
            if v, ok := strconv.parse_f64(argv[i + 1]); ok do js.set_time_budget_ms(v)
            i += 2
            continue
        }
        append(&out, a)
        i += 1
    }
    return out[:]
}

main :: proc() {
    // Console em UTF-8: nossas mensagens (e o console.log das páginas) são
    // UTF-8; sem isto o codepage legado (cp850) mostra "exceção" como "exce├º├úo".
    when ODIN_OS == .Windows {
        win.SetConsoleOutputCP(.UTF8)
    }
    when TRACK_ALLOC {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        // ⚠️ NÃO entrar em pânico em "bad free": os workers de imagem/rede rodam em
        // OUTRA thread, cujo context tem o alocador PADRÃO, e o que eles clonam
        // (ex.: `img.svg_src`) é liberado aqui na main — que sob TRACK_ALLOC está
        // embrulhada. O ponteiro não está no mapa do rastreador e ele acusa "bad
        // free" que NÃO existe no build normal (lá os dois são o mesmo heap).
        // Custou um diagnóstico errado meu: quase reportei bug pré-existente.
        track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
        context.allocator = mem.tracking_allocator(&track)
        g_track = &track
        defer track_report() // caminho sem os.exit (janela interativa)
    }
    args := extrai_js_timeout(os.args)
    // Modo headless: browser.exe --render entrada.html saida.png [larg alt [mx my]]
    // mx/my = posição do mouse (p/ testar :hover); ausente = fora da tela.
    if len(args) >= 4 && args[1] == "--render" {
        w: i32 = 800
        h: i32 = 600
        mx: f32 = -1
        my: f32 = -1
        if len(args) >= 6 {
            if v, ok := strconv.parse_int(args[4]); ok do w = i32(v)
            if v, ok := strconv.parse_int(args[5]); ok do h = i32(v)
        }
        if len(args) >= 8 {
            if v, ok := strconv.parse_int(args[6]); ok do mx = f32(v)
            if v, ok := strconv.parse_int(args[7]); ok do my = f32(v)
        }
        frames: i32 = 1
        scroll_y: f32 = 0
        wheel: f32 = 0
        if len(args) >= 9  { if v, ok := strconv.parse_int(args[8]);  ok do frames = i32(v) }
        if len(args) >= 10 { if v, ok := strconv.parse_int(args[9]);  ok do scroll_y = f32(v) }
        if len(args) >= 11 { if v, ok := strconv.parse_int(args[10]); ok do wheel = f32(v) }
        click := false
        if len(args) >= 12 { if v, ok := strconv.parse_int(args[11]); ok do click = v != 0 }
        ok := ui.headless_render(args[2], args[3], w, h, mx, my, frames, scroll_y, wheel, click)
        when js.JSPROF do js.prof_report()
        when TRACK_ALLOC do track_report()
        os.exit(0 if ok else 1)
    }
    // Modo html5lib: browser.exe --parsetree <arquivo.html>
    // Serializa a árvore do parser no formato tree-construction do html5lib-tests.
    if len(args) >= 3 && args[1] == "--parsetree" {
        ok := ui.headless_parsetree(args[2])
        os.exit(0 if ok else 1)
    }
    // Modo html5lib FRAGMENTO: browser.exe --parsefragment <arquivo.html> <contexto>
    if len(args) >= 4 && args[1] == "--parsefragment" {
        ok := ui.headless_parsefragment(args[2], args[3])
        os.exit(0 if ok else 1)
    }
    // Modo html5lib LEGADO: browser.exe --parsetree-legacy <arquivo.html>
    // Mede o parser que a renderizacao usa (htmlp.parse), nao o de spec.
    if len(args) >= 3 && args[1] == "--parsetree-legacy" {
        ok := ui.headless_parsetree_legacy(args[2])
        os.exit(0 if ok else 1)
    }
    // Modo html5lib tokenizer: browser.exe --tokenize <arquivo.html> [estado] [last]
    if len(args) >= 3 && args[1] == "--tokenize" {
        state := args[3] if len(args) >= 4 else "data"
        last  := args[4] if len(args) >= 5 else ""
        ok := ui.headless_tokenize(args[2], state, last)
        os.exit(0 if ok else 1)
    }
    // Modo Test262: browser.exe --js262 f1.js [f2.js ...]
    // Executa os arquivos JS em ordem numa VM única (harness + corpo do teste) e
    // imprime uma linha de veredito. Curadoria/julgamento ficam no test262.ps1.
    if len(args) >= 3 && args[1] == "--js262" {
        os.exit(js.js262_main(args[2:]))
    }
    // Modo debug: browser.exe --fetch <url>  (pipeline síncrono, sem UI)
    if len(args) >= 3 && args[1] == "--fetch" {
        ok := ui.headless_fetch(args[2])
        os.exit(0 if ok else 1)
    }
    // Modo inventário: browser.exe --css-inventory url1 [url2 ...]
    // Roda o pipeline em várias páginas e grava css_unknown.txt.
    if len(args) >= 3 && args[1] == "--css-inventory" {
        ok := ui.headless_css_inventory(args[2:]) // args[2:] = lista de URLs
        os.exit(0 if ok else 1)
    }
    // Modo golden-dump: browser.exe --dumplayout <entrada.html> <saida.txt> [larg alt]
    // Serializa a árvore de layout de um arquivo local (harness layout-golden.ps1).
    if len(args) >= 4 && args[1] == "--dumplayout" {
        w: i32 = 800
        h: i32 = 600
        if len(args) >= 6 {
            if v, ok := strconv.parse_int(args[4]); ok do w = i32(v)
            if v, ok := strconv.parse_int(args[5]); ok do h = i32(v)
        }
        ok := ui.headless_dumplayout(args[2], args[3], w, h)
        os.exit(0 if ok else 1)
    }
    // Modo diagnóstico: browser.exe --diagnose <url> [saida.json]
    // Render real (com fontes/imagens) + relatório de "por que pode estar
    // quebrado": CSS não suportado, imagens, overflow horizontal, colapsos, árvore.
    // Com [saida.json], grava também o relatório estruturado (p/ gap-miner.ps1).
    if len(args) >= 3 && args[1] == "--diagnose" {
        json_path := args[3] if len(args) >= 4 else ""
        ok := ui.headless_diagnose(args[2], json_path)
        when ui.UIPROF do ui.uiprof_report()
        when ui.CULLPROBE do ui.cullprobe_report()
        when ui.PAINTPROF do ui.paintprof_report()
        when ui.GCSPROBE do ui.gcs_probe_report()
        when js.JSPROF do js.prof_report()
        os.exit(0 if ok else 1)
    }
    // Modo debug: browser.exe --paint <url> [frames]  (busca + pinta em loop)
    // browser.exe --paint <url> [url2] [frames]  (url2 = clique num link)
    if len(args) >= 3 && args[1] == "--paint" {
        url2 := ""
        frames := 150
        if len(args) >= 4 do url2 = args[3]
        if len(args) >= 5 { if v, ok := strconv.parse_int(args[4]); ok do frames = v }
        ok := ui.headless_paint(args[2], url2, frames)
        os.exit(0 if ok else 1)
    }
    // Modo oráculo: browser.exe --imgdiff a.png b.png → imprime "<diff%> <alt%>"
    if len(args) >= 4 && args[1] == "--imgdiff" {
        os.exit(0 if ui.headless_imgdiff(args[2], args[3]) else 1)
    }
    // Fase 2 (prova): browser.exe --phase2test
    // Renderiza uma sub-lista numa textura offscreen e compõe com alpha; valida
    // que o pipeline de layer funciona e que group-opacity não sofre double-darken.
    if len(args) >= 2 && args[1] == "--phase2test" {
        os.exit(0 if ui.headless_phase2test() else 1)
    }
    // Rebuild de atlas em runtime (prova): browser.exe --fonttest [caminho.ttf]
    // Pré-requisito do @font-face — acrescenta uma face DEPOIS do boot e valida
    // que a textura é refeita, que os ^Font antigos sobrevivem e que a face nova
    // mede e pinta diferente.
    if len(args) >= 2 && args[1] == "--fonttest" {
        if len(args) >= 3 do os.exit(0 if ui.headless_fonttest(args[2]) else 1)
        os.exit(0 if ui.headless_fonttest() else 1)
    }
    // WOFF2 (prova): browser.exe --woff2test <entrada.woff2> <saida.ttf>
    // Remonta o SFNT e grava, p/ tools/woff2-difftest.py comparar com o
    // fontTools glifo a glifo. Byte a byte não serve: a spec do WOFF2 garante a
    // funcionalidade, não os bytes.
    if len(args) >= 4 && args[1] == "--woff2test" {
        os.exit(0 if ui.headless_woff2test(args[2], args[3]) else 1)
    }
    // Brotli (prova em volume): browser.exe --brotlitest <pasta>
    // Compara com os pares gerados pelo brotli de referência (harness em
    // tools/brotli-difftest.py, que varia qualidade e janela).
    if len(args) >= 3 && args[1] == "--brotlitest" {
        os.exit(0 if ui.headless_brotlitest(args[2]) else 1)
    }
    ui.run()
}
