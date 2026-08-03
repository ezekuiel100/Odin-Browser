package js

// ── IntersectionObserver REAL (M232) ────────────────────────────────────────
//
// Antes: `observer_ctor` em dom_bindings.odin — observe/disconnect/unobserve
// no-op cujo callback NUNCA disparava. A degradação era do tipo mais caro que
// esta engine tem (auditoria de 28/07, Tier 1): **stub que devolve valor neutro**.
// A página registra, segue em frente, e o que dependia da notificação não
// acontece EM SILÊNCIO — sem exceção, sem console.error, sem nada no --diagnose.
// Em site real isso é imagem/seção que só carrega ao entrar na viewport, menu
// que só marca o item ativo ao passar por ele, e o padrão MAIS comum de 2024+:
// conteúdo que nasce com `opacity:0` e só ganha a classe de "revelar" quando o
// observador dispara. Nesse último caso o conteúdo ESTÁ no DOM e no layout — só
// nunca fica visível.
//
// ONDE O ESTADO MORA: no próprio objeto JS do observador (props "#cb"/"#targets"/
// "#queue"/"#margin"), a mesma convenção do [[mutation-observer]] (M201) e do
// PerformanceObserver. Assim tudo é rastreado pelo vm (all_objects/all_arrays) e
// não entra gestão de memória nova; o vm só guarda a LISTA de observadores vivos
// (`int_observers`), necessária para iterar no passo e para o atalho "ninguém
// observando".
//
// ── DIFERENÇA ESTRUTURAL PARA O MutationObserver ────────────────────────────
// O MO é dirigido por EVENTO: o funil de mutação sabe a hora exata em que algo
// mudou e enfileira ali. Aqui não existe evento nenhum — a interseção muda por
// SCROLL, por RELAYOUT e por mudança de tamanho da janela, e nenhum deles passa
// por um funil só. Por isso o IO é dirigido por AMOSTRAGEM: o hospedeiro chama
// `io_step` uma vez por frame (é o "run the update intersection observations
// steps" da spec, que roda dentro do "update the rendering"), e nós comparamos
// com o estado anterior. É também por isso que a entrega é síncrona dentro do
// io_step em vez de ir para uma fila: o io_step JÁ é chamado do laço de frames,
// com a pilha de JS vazia, que é a condição que a spec quer.
//
// A geometria vem do MESMO hook do getBoundingClientRect (`g_element_rect`, ver
// [[gcs-geometry-rect]] M200) — mesma fonte, mesmo flush de layout, então o que
// a página vê pelo observador e o que ela mede à mão não podem divergir.

import "core:strconv"
import dom "../dom"

// Chaves do estado interno (com `#` p/ não colidir com o que a página escreva).
@(private = "file") IO_CB      :: "#cb"
@(private = "file") IO_TARGETS :: "#targets"
@(private = "file") IO_QUEUE   :: "#queue"
@(private = "file") IO_MARGIN  :: "#margin" // 8 números: (valor, é_%) × top,right,bottom,left

// `idx` de um alvo recém-observado. Qualquer índice calculado (0 inclusive)
// difere de -1, e é ASSIM que sai a **observação inicial** que a spec exige:
// toda página que faz lazy-load conta com o primeiro disparo logo após observe(),
// mesmo com o alvo fora da tela (isIntersecting=false). Sem isso, um alvo que
// nasce fora da viewport e nunca é rolado jamais receberia entry — e é
// exatamente o caso de quem usa o observador só para decidir "já posso carregar?".
@(private = "file") IO_IDX_INICIAL :: f64(-1)

// ── construtor e métodos ────────────────────────────────────────────────────

io_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    cb, cok := arg(a, 0).(^Function)
    if !cok {
        throw_type_error(vm, "IntersectionObserver constructor: callback must be a function")
        return nil
    }
    o := new_object(vm)
    o.props[IO_CB]      = cb
    o.props[IO_TARGETS] = new_array(vm)
    o.props[IO_QUEUE]   = new_array(vm)

    opts, _ := arg(a, 1).(^Object)

    // `root`: elemento OU null (= viewport). Guardamos o wrapper; a caixa dele é
    // lida a cada passo, não agora (o layout ainda pode nem existir).
    root: Value = JS_Null{}
    if opts != nil {
        if r, rok := opts.props["root"].(^Object); rok && r.host != nil do root = r
    }
    o.props["root"] = root

    margin_src := "0px"
    if opts != nil {
        if s, sok := opts.props["rootMargin"].(string); sok && s != "" do margin_src = s
    }
    mv, mp := io_parse_margin(margin_src)
    marr := new_array(vm)
    for k in 0 ..< 4 {
        append(&marr.items, f64(mv[k]))
        append(&marr.items, mp[k])
    }
    o.props[IO_MARGIN]   = marr
    o.props["rootMargin"] = own_str(vm, margin_src) // degradação: devolvemos a
    // string COMO VEIO (o navegador normaliza p/ os 4 componentes em px/%)
    o.props["thresholds"] = io_parse_thresholds(vm, opts)

    o.props["observe"]     = mk_bound_obj(vm, o, io_observe)
    o.props["unobserve"]   = mk_bound_obj(vm, o, io_unobserve)
    o.props["disconnect"]  = mk_bound_obj(vm, o, io_disconnect)
    o.props["takeRecords"] = mk_bound_obj(vm, o, io_take_records)
    for k in ([?]string{IO_CB, IO_TARGETS, IO_QUEUE, IO_MARGIN, "root", "rootMargin",
                        "thresholds", "observe", "unobserve", "disconnect", "takeRecords"}) {
        mark_non_enumerable(o, k)
    }
    return o
}

// O objeto do observador: `mk_bound_obj` põe em vm.native_bound; `this` cobre o
// caso de o método ter sido destacado (`var f = io.observe`).
@(private = "file")
io_self :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := vm.native_bound.(^Object); ok && o.props[IO_TARGETS] != nil do return o
    if o, ok := this.(^Object); ok do return o
    return nil
}

@(private = "file")
io_observe :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := io_self(vm, this)
    if obs == nil do return nil
    target, tok := arg(a, 0).(^Object)
    if !tok || target.host == nil {
        throw_type_error(vm, "IntersectionObserver.observe: target must be an Element")
        return nil
    }
    targets, ok := obs.props[IO_TARGETS].(^Array)
    if !ok do return nil
    // observar o MESMO alvo de novo é NO-OP (spec) — inclusive não repete a
    // observação inicial.
    for it in targets.items {
        if r, rok := it.(^Object); rok {
            if t, tk := r.props["n"].(^Object); tk && t.host == target.host do return nil
        }
    }
    rec := new_object(vm)
    rec.props["n"]   = target
    rec.props["idx"] = IO_IDX_INICIAL
    append(&targets.items, rec)
    vm.io_observe_calls += 1 // uso real da API; sai no --diagnose
    io_track(vm, obs)
    return nil
}

@(private = "file")
io_unobserve :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := io_self(vm, this)
    if obs == nil do return nil
    target, tok := arg(a, 0).(^Object)
    if !tok || target.host == nil do return nil
    targets, ok := obs.props[IO_TARGETS].(^Array)
    if !ok do return nil
    for it, i in targets.items {
        r, rok := it.(^Object)
        if !rok do continue
        if t, tk := r.props["n"].(^Object); tk && t.host == target.host {
            ordered_remove(&targets.items, i)
            break
        }
    }
    if len(targets.items) == 0 do io_untrack(vm, obs) // volta ao atalho de custo zero
    return nil
}

@(private = "file")
io_disconnect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := io_self(vm, this)
    if obs == nil do return nil
    if t, ok := obs.props[IO_TARGETS].(^Array); ok do clear(&t.items)
    if q, ok := obs.props[IO_QUEUE].(^Array);   ok do clear(&q.items) // spec: esvazia a fila
    io_untrack(vm, obs)
    return nil
}

@(private = "file")
io_take_records :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    out := new_array(vm)
    obs := io_self(vm, this)
    if obs == nil do return out
    if q, ok := obs.props[IO_QUEUE].(^Array); ok {
        for e in q.items do append(&out.items, e)
        clear(&q.items)
    }
    return out
}

@(private = "file")
io_track :: proc(vm: ^Interp, obs: ^Object) {
    for o in vm.int_observers do if o == obs do return
    append(&vm.int_observers, obs)
}

@(private = "file")
io_untrack :: proc(vm: ^Interp, obs: ^Object) {
    for o, i in vm.int_observers {
        if o == obs {
            ordered_remove(&vm.int_observers, i)
            return
        }
    }
}

// ── opções: threshold e rootMargin ──────────────────────────────────────────

// `threshold` aceita número OU lista; default [0]. Ordenado crescente porque o
// índice de limiar (io_threshold_index) conta quantos ficaram para trás.
// ⚠️ degradação: valor fora de [0,1] é CLAMPADO (a spec manda lançar RangeError).
@(private = "file")
io_parse_thresholds :: proc(vm: ^Interp, opts: ^Object) -> ^Array {
    out := new_array(vm)
    if opts != nil {
        tv := opts.props["threshold"]
        if arr, aok := tv.(^Array); aok {
            for it in arr.items do append(&out.items, io_clamp01(to_number(vm, it)))
        } else if tv != nil {
            if _, isnull := tv.(JS_Null); !isnull do append(&out.items, io_clamp01(to_number(vm, tv)))
        }
    }
    if len(out.items) == 0 do append(&out.items, f64(0))
    for a := 1; a < len(out.items); a += 1 { // insertion sort (listas de 1-10 itens)
        for j := a; j > 0 && as_number(out.items[j]) < as_number(out.items[j-1]); j -= 1 {
            out.items[j], out.items[j-1] = out.items[j-1], out.items[j]
        }
    }
    return out
}

@(private = "file")
io_clamp01 :: proc(v: f64) -> f64 {
    if v != v do return 0 // NaN (opção inválida) ⇒ 0, em vez de envenenar a comparação
    return clamp(v, 0, 1)
}

// "10px" / "-50%" / "0" → (valor, é_percentual). A spec só admite px e %.
@(private = "file")
io_parse_len :: proc(tok: string) -> (v: f32, pct: bool) {
    s := tok
    if len(s) > 0 && s[len(s)-1] == '%' {
        pct = true
        s = s[:len(s)-1]
    } else if len(s) >= 2 && s[len(s)-2:] == "px" {
        s = s[:len(s)-2]
    }
    if f, ok := strconv.parse_f64(s); ok do return f32(f), pct
    return 0, false
}

// rootMargin no atalho do CSS: 1, 2, 3 ou 4 componentes (top right bottom left).
@(private = "file")
io_parse_margin :: proc(s: string) -> (vals: [4]f32, pcts: [4]bool) {
    tv: [4]f32
    tp: [4]bool
    n := 0
    i := 0
    for i < len(s) && n < 4 {
        for i < len(s) && (s[i] == ' ' || s[i] == '\t') do i += 1
        j := i
        for j < len(s) && s[j] != ' ' && s[j] != '\t' do j += 1
        if j > i {
            tv[n], tp[n] = io_parse_len(s[i:j])
            n += 1
        }
        i = j
    }
    switch n {
    case 0:
        // tudo zero
    case 1:
        for k in 0 ..< 4 { vals[k] = tv[0]; pcts[k] = tp[0] }
    case 2:
        vals = {tv[0], tv[1], tv[0], tv[1]}
        pcts = {tp[0], tp[1], tp[0], tp[1]}
    case 3:
        vals = {tv[0], tv[1], tv[2], tv[1]}
        pcts = {tp[0], tp[1], tp[2], tp[1]}
    case:
        vals = {tv[0], tv[1], tv[2], tv[3]}
        pcts = {tp[0], tp[1], tp[2], tp[3]}
    }
    return
}

// Margens já resolvidas em px. Percentual é relativo à DIMENSÃO DO EIXO do root
// (top/bottom sobre a altura, right/left sobre a largura), como na spec.
@(private = "file")
io_margins :: proc(obs: ^Object, rw, rh: f32) -> (mt, mr, mb, ml: f32) {
    m, ok := obs.props[IO_MARGIN].(^Array)
    if !ok || len(m.items) < 8 do return 0, 0, 0, 0
    out: [4]f32
    for k in 0 ..< 4 {
        v := f32(as_number(m.items[k*2]))
        if truthy(m.items[k*2+1]) {
            base := (k == 0 || k == 2) ? rh : rw
            v = v * base / 100
        }
        out[k] = v
    }
    return out[0], out[1], out[2], out[3]
}

// Índice de limiar. 0 = "não intersecta (ou intersecta abaixo do 1º limiar)";
// a entrega acontece quando este número MUDA. É o que faz `threshold: 0.5` não
// disparar a cada pixel de scroll.
@(private = "file")
io_threshold_index :: proc(obs: ^Object, ratio: f64, inter: bool) -> f64 {
    if !inter do return 0
    th, ok := obs.props["thresholds"].(^Array)
    if !ok || len(th.items) == 0 do return 1
    idx := 0
    for it in th.items do if ratio >= as_number(it) do idx += 1
    return f64(idx)
}

// ── o passo por frame ───────────────────────────────────────────────────────

// Atalho: alguém observando? O hospedeiro chama isto TODO FRAME, então com zero
// observadores (o caso de ~toda página) o custo de ter a feature é um `len`.
io_active :: proc(vm: ^Interp) -> bool {
    return vm != nil && len(vm.int_observers) > 0
}

// Uma rodada de "update the intersection observations". Devolve true se ALGUM
// callback foi chamado — o hospedeiro usa isso do mesmo jeito que usa o retorno
// de `vm_pump_timers`: o callback pode ter mexido no DOM, e aí é preciso
// re-estilizar antes de pintar.
io_step :: proc(vm: ^Interp) -> bool {
    if !io_active(vm) || vm.io_stepping do return false
    vm.io_stepping = true
    defer vm.io_stepping = false

    vw, vh: f32
    if g_viewport_dims != nil do vw, vh = g_viewport_dims()

    delivered := false
    // Cópia da lista: o callback pode chamar observe/disconnect e mexer em
    // vm.int_observers no meio do laço (mesma razão do snapshot do mo_notify).
    snap: [dynamic]^Object
    defer delete(snap)
    for o in vm.int_observers do append(&snap, o)

    for obs in snap {
        targets, tok := obs.props[IO_TARGETS].(^Array)
        if !tok || len(targets.items) == 0 do continue
        q, qok := obs.props[IO_QUEUE].(^Array)
        if !qok do continue

        // Caixa da raiz: o elemento passado em `root`, ou o VIEWPORT.
        rx, ry, rw, rh: f32 = 0, 0, vw, vh
        root_ok := true
        if r, rok := obs.props["root"].(^Object); rok && r.host != nil {
            x, y, w, h, k := io_node_rect(cast(^dom.Node) r.host)
            rx, ry, rw, rh, root_ok = x, y, w, h, k
        }
        mt, mr, mb, ml := io_margins(obs, rw, rh)
        rx -= ml; ry -= mt
        rw += ml + mr; rh += mt + mb

        for it in targets.items {
            rec, rk := it.(^Object)
            if !rk do continue
            tobj, ok2 := rec.props["n"].(^Object)
            if !ok2 || tobj.host == nil do continue
            tx, ty, tw, th, tk := io_node_rect(cast(^dom.Node) tobj.host)

            ix, iy, iw, ih: f32
            ratio: f64 = 0
            inter := false
            if tk && root_ok {
                ix = max(tx, rx)
                iy = max(ty, ry)
                iw = min(tx + tw, rx + rw) - ix
                ih = min(ty + th, ry + rh) - iy
                area := f64(tw) * f64(th)
                if area > 0 {
                    inter = iw > 0 && ih > 0
                    if inter do ratio = (f64(iw) * f64(ih)) / area
                } else {
                    // Alvo de área ZERO (o `<div>` sentinela de "carregar mais",
                    // que é altura 0 de propósito): a razão não é divisível, e a
                    // spec define 1 quando ele está dentro da raiz.
                    inter = iw >= 0 && ih >= 0
                    ratio = inter ? 1 : 0
                }
            }
            if !inter { ix, iy, iw, ih = 0, 0, 0, 0 }

            idx := io_threshold_index(obs, ratio, inter)
            if idx == as_number(rec.props["idx"]) do continue
            rec.props["idx"] = idx

            e := new_object(vm)
            e.props["time"]               = vm.clock_ms
            e.props["target"]             = tobj
            e.props["boundingClientRect"] = make_dom_rect(vm, tx, ty, tw, th)
            e.props["intersectionRect"]   = make_dom_rect(vm, ix, iy, iw, ih)
            e.props["rootBounds"]         = root_ok ? Value(make_dom_rect(vm, rx, ry, rw, rh)) : JS_Null{}
            e.props["isIntersecting"]     = inter
            e.props["intersectionRatio"]  = ratio
            append(&q.items, e)
        }

        if len(q.items) == 0 do continue
        entries := new_array(vm)
        for e in q.items do append(&entries.items, e)
        clear(&q.items)
        vm.io_entries_sent += len(entries.items)
        delivered = true

        cb, cok := obs.props[IO_CB].(^Function)
        if !cok do continue
        // TAREFA de JS própria, como cada callback de timer no vm_pump_timers:
        // watchdog zerado (o callback não herda o orçamento de quem veio antes) e
        // mo_task_enter/exit p/ os MutationRecords que ele gerar saírem no fim
        // dele, e não no meio.
        vm.steps = 0
        vm.call_depth = 0
        reset_task_clock(vm)
        mo_task_enter(vm)
        call_function(vm, cb, obs, []Value{entries, obs})
        vm_clear_uncaught(vm) // um callback que lança não impede os demais
        mo_task_exit(vm)
    }
    return delivered
}

// Geometria pelo mesmo hook do getBoundingClientRect. Sem o pacote ui (ex.:
// `odin test src/js` sem fake instalado) não há layout: ok=false, e aí o alvo
// conta como não-intersectante — nunca como "intersectando por engano".
@(private = "file")
io_node_rect :: proc(node: ^dom.Node) -> (x, y, w, h: f32, ok: bool) {
    if g_element_rect == nil || node == nil do return 0, 0, 0, 0, false
    return g_element_rect(node)
}

// vm_destroy: só a lista (os objetos são rastreados pelo vm).
io_free :: proc(vm: ^Interp) {
    delete(vm.int_observers)
    vm.int_observers = nil
}
