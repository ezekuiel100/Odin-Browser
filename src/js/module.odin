package js

// ── Módulos ES (M109) ─────────────────────────────────────────────────────────
// Carregamento de módulos p/ `import()` dinâmico e `import`/`export` estáticos.
// O gap-miner apontava `import is not a function` em 5-7 sites (crates.io BLANK):
// sites que servem ESM NATIVO (sem bundler) chamavam import() — que não existia —
// e os imports estáticos de <script type="module"> eram silenciosamente ignorados.
//
// Desenho (consistente com a filosofia da engine: await/fetch BLOQUEANTES):
//   • Registry por URL absoluta (cache + guarda de ciclo): 1 fetch e 1 avaliação
//     por módulo, identidade estável do namespace.
//   • load_module: resolve (hook) → cache? → fetch (hook) → avalia em escopo
//     próprio (filho do global) → snapshot de exports no namespace.
//   • Exports "adiados": `export {a}` registra o par (local→exportado); o valor é
//     lido do escopo NO FIM da avaliação — `export {a}; a = 2` exporta 2 (aproxima
//     live bindings p/ grafos acíclicos; em CICLOS o snapshot ainda pode ver
//     undefined — limitação documentada, sem live bindings de verdade).
//   • import() devolve Promise já assentada (resolve com o namespace; rejeita com
//     o erro do fetch/avaliação) — consistente com o await bloqueante.
//   • Hooks module_resolve/module_fetch: instalados por dom_bindings (net); os
//     testes instalam stubs em memória (vm.module_stubs). SEM hooks, import
//     estático degrada p/ no-op (comportamento pré-M109) e import() rejeita.

import "core:fmt"
import "core:strings"

MAX_MODULES :: 160 // teto de módulos ÚNICOS buscados por página (anti-runaway de rede).
// Era 64, e virou o gargalo assim que o M206 fez o grafo de módulos ANDAR (antes ele
// morria no 1º módulo, então o teto quase nunca era alcançado: no github.com o aviso
// "teto atingido" saltou de 2 p/ 51 ocorrências depois daquele fix).
// MEDIDO com sonda (`-define:MODULES_CAP=400 -define:MODPROBE=true`, que imprimia cada
// módulo novo): github.com home 94, /features/copilot 94, **página de repositório 108**;
// react.dev/nextjs.org/wikipedia 0 (bundle clássico, sem ESM), vuejs.org 9, svelte.dev 22.
// 160 cobre a página mais pesada medida com folga e continua uma ordem de grandeza abaixo
// de runaway. Custo do grafo completo do github: ~7,4s→10,8s e ~1390→1457 MB de pico.
// ⚠️ o teto conta URL ÚNICA porque cache hit sai antes do incremento — ao contrário do
// que o MAX_SHEETS fazia (contava ELEMENTO <link>), que foi o bug do M204.

// Busca (ou devolve do cache) o módulo de `specifier` relativo a `referrer`.
// Devolve nil se não há hooks/resolução falhou/cap estourou. Um módulo devolvido
// pode estar .Failed (fetch/avaliação falhou) ou .Loading (ciclo em andamento).
load_module :: proc(vm: ^Interp, specifier, referrer: string) -> ^Module {
    if vm.module_resolve == nil || vm.module_fetch == nil do return nil
    if strings.trim_space(specifier) == "" do return nil
    url := vm.module_resolve(vm, specifier, referrer)
    if url == "" do return nil
    if m, ok := vm.modules[url]; ok { // cache; inclui ciclo (state==.Loading)
        delete(url)
        return m
    }
    if vm.modules_loaded >= MAX_MODULES {
        fmt.eprintfln("[js] teto de módulos atingido (%d); import de %s ignorado", MAX_MODULES, specifier)
        delete(url)
        return nil
    }
    vm.modules_loaded += 1

    m := new(Module)
    m.url = url
    m.ns = new_object(vm)
    m.state = .Loading
    append(&vm.all_modules, m)
    vm.modules[m.url] = m // chave = m.url (owned pelo módulo; mapa deletado antes no destroy)

    src, ok := vm.module_fetch(vm, m.url)
    if !ok {
        fmt.eprintfln("[js] módulo falhou ao buscar: %s (referrer %s)", m.url, referrer)
        m.state = .Failed
        return m
    }
    defer delete(src) // vm_exec clona a fonte (owned_sources)

    menv := new_env(vm, vm.global)
    menv.is_fn_scope = true // como vm_run_module: var/hoist top-level ficam no módulo
    m.env = menv
    module_bind_ns_live(m) // ANTES do corpo: em ciclo o ns é lido durante o .Loading
    env_escaped(vm) // o escopo do módulo vive no registry, muito além desta chamada

    prev := vm.current_module
    vm.current_module = m
    saved_depth := vm.call_depth // vm_exec zera call_depth (mesmo guard do M102)
    saved_short := vm.opt_short  // fronteira de módulo: sinais transientes NÃO vazam
    vm.opt_short = false         // (um módulo terminando em `w?.h` deixava opt_short=true
                                 //  e a cadeia EXTERNA `.then()` era silenciosamente pulada)
    _ = vm_exec(vm, src, menv)
    vm.call_depth = saved_depth
    vm.opt_short = saved_short
    vm.returning = false // return/break/continue não cruzam fronteira de módulo
    vm.breaking = false
    vm.continuing = false
    vm.current_module = prev

    if vm.throwing {
        m.state = .Failed // exceção fica pendente: o CHAMADOR decide (rejeição/log)
        return m
    }
    module_snapshot_exports(vm, m)
    m.state = .Done
    return m
}

// Liga o namespace ao escopo do módulo (get-hook de LIVE BINDING, M139).
//
// ⚠️ Tem de ser chamado assim que `m.env` existe, ANTES de avaliar o corpo — não
// no fim. Um módulo em CICLO (inclusive o auto-import de 1 elo que o rspack emite)
// tem o namespace lido enquanto ainda está `.Loading`; com o hook ligado só no fim,
// essa leitura via um objeto VAZIO. Era o que matava o grafo de módulos inteiro do
// github.com: `r.__rspack_esm_ids` vinha undefined e o runtime fazia `.length` nele.
// O hook em si já resolvia o caso — só estava sendo instalado tarde.
module_bind_ns_live :: proc(m: ^Module) {
    if m == nil || m.ns == nil do return
    m.ns.host = rawptr(m)
    m.ns.get  = module_ns_get
}

// Publica os exports adiados (local→exportado) no namespace. O valor NÃO é
// congelado aqui: quem manda na leitura é o get-hook acima. Isto existe como valor
// de partida e, principalmente, p/ quem ENUMERA as chaves (`Object.keys(ns)`,
// `export * from`), que passa por `ns.props` e não pelo hook.
module_snapshot_exports :: proc(vm: ^Interp, m: ^Module) {
    if m == nil || m.env == nil do return
    for d in m.deferred {
        if v, ok := env_get(m.env, d.local); ok do oput(m.ns, d.exported, v)
        else do oput(m.ns, d.exported, nil) // existe como chave, ainda sem valor
    }
    module_bind_ns_live(m)
}

// Leitura do namespace: se a chave é um export adiado, resolve o local NO ESCOPO
// do módulo agora. É o que torna vivo o idioma `var A; export{A as x}; function
// init(){ A = ... }` — com snapshot, `x` ficava undefined p/ sempre.
module_ns_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    m := cast(^Module) o.host
    if m == nil || m.env == nil do return nil, false
    for d in m.deferred {
        if d.exported == name {
            v, _ := env_get(m.env, d.local)
            return v, true
        }
    }
    return nil, false // default/props comuns seguem pelo caminho normal
}

// Local (no escopo do exportador) por trás de um nome exportado — "" se o export
// não é adiado (ex.: `export default`), caso em que o import copia o valor.
@(private = "file")
module_local_of :: proc(m: ^Module, exported: string) -> string {
    if m == nil do return ""
    for d in m.deferred do if d.exported == exported do return d.local
    return ""
}

// import(expr) → Promise<namespace>. Bloqueante: a Promise volta já assentada.
eval_import_call :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    spec_v := eval(vm, n.left, env)
    if vm.throwing do return nil
    spec: string
    if s, ok := spec_v.(string); ok {
        spec = s
    } else { // ToString(especificador)
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, spec_v)
        spec = own_str(vm, strings.to_string(sb)).(string)
    }

    p := promise_new(vm)
    // Referrer LÉXICO: o nó carrega a URL do módulo onde o `import()` foi ESCRITO
    // (carimbada no parse). Perguntar `vm.current_module` na hora da chamada dá o
    // referrer errado sempre que o import() roda depois que o módulo terminou —
    // dentro de um callback de timer, por exemplo, que é o caso do SvelteKit:
    // `import("../nodes/0.js")` virava /nodes/0.js em vez de /assets/nodes/0.js.
    referrer := n.str
    if referrer == "" do referrer = vm.current_module != nil ? vm.current_module.url : vm.base_url
    m := load_module(vm, spec, referrer)
    if m == nil || m.state != .Done {
        reason: Value
        if vm.throwing { // avaliação do módulo lançou: rejeita com o erro real
            reason = vm.thrown
            vm.throwing = false
            vm.thrown = nil
        } else {
            reason = mk_error(vm, "TypeError",
                fmt.tprintf("Failed to fetch dynamically imported module: %s", spec))
        }
        promise_settle(vm, p, PROMISE_REJECTED, reason)
    } else {
        promise_resolve_with(vm, p, m.ns)
    }
    return p
}

// import estático: carrega o módulo e define os bindings no escopo corrente.
// Sem hooks (bundles clássicos, testes puros): no-op — comportamento pré-M109.
// Falha de dep: loga, binda undefined e segue (filosofia tolerante da engine).
eval_import_decl :: proc(vm: ^Interp, n: ^Node, env: ^Env) {
    if n.str == "" do return // sintaxe capenga sem especificador: nada a fazer
    if vm.module_resolve == nil || vm.module_fetch == nil do return
    referrer := vm.current_module != nil ? vm.current_module.url : vm.base_url
    m := load_module(vm, n.str, referrer)
    ok := m != nil && m.state != .Failed // .Loading (ciclo) binda do ns parcial
    if !ok {
        fmt.eprintfln("[js] import estático falhou: %s → %s (%s)", n.str,
            m != nil ? m.url : "<não resolveu>",
            m != nil ? "avaliação do módulo lançou" : "resolução/cap")
        if vm.throwing do vm_clear_uncaught(vm) // dep lançou: loga e não envenena o importador
    }
    if n.name != "" do env_define(env, n.name, ok ? get_member(vm, m.ns, "default") : nil)
    if n.rest_param != "" do env_define(env, n.rest_param, ok ? m.ns : nil)
    for c in n.body { // {a, b as c}: c.str = exportado, c.name = local
        // LIVE BINDING (M139): quando o export vem de uma variável do exportador, o
        // importador ALIASA essa variável em vez de copiar o valor. Sem isto, um
        // export atribuído depois da avaliação do corpo (init preguiçoso) ficava
        // undefined no importador p/ sempre — era a raiz do cluster "módulo que
        // exporta vazio" (crates.io: `var Ln,Rn; function Hn(){Ln=window,Rn=document}`
        // com `export{Ln as tt, Rn as et}`).
        if ok {
            if local := module_local_of(m, c.str); local != "" {
                env_alias(env, c.name, m.env, local)
                env_escaped(vm) // o alias segura o escopo do exportador por referência
                continue
            }
        }
        v: Value = ok ? get_member(vm, m.ns, c.str) : nil
        // breadcrumb de grafo: binding undefined = export que não materializou
        // (ciclo, export perdido no parse, snapshot falho) — aponta o elo exato.
        if ok && v == nil do fmt.eprintfln("[js] import: '%s' de %s veio undefined", c.str, n.str)
        env_define(env, c.name, v)
    }
}

// export ...: registra no namespace do módulo corrente (fora de módulo, só avalia
// a declaração — mesmo efeito observável de antes do M109).
eval_export_decl :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    m := vm.current_module
    if n.bval { // export default <expr> — valor imediato (spec)
        v := eval(vm, n.left, env)
        if vm.throwing do return nil
        if m != nil do oput(m.ns, "default", v)
        return v
    }
    if n.left != nil { // export <declaração>: executa e adia o snapshot dos nomes
        v := eval(vm, n.left, env)
        if vm.throwing do return nil
        if m != nil {
            module_collect_decl_exports(m, n.left)
            // publica JÁ, não só no fim: em ciclo o namespace é enumerado enquanto
            // o módulo ainda roda, e enumeração passa por `ns.props` (o get-hook só
            // cobre leitura por nome). Sem isto, `export * from` e `Object.keys(ns)`
            // de dentro de um ciclo viam um objeto vazio mesmo com o hook ligado.
            module_snapshot_exports(vm, m)
        }
        return v
    }
    if n.str != "" { // re-export: export {..} from / export * [as ns] from
        referrer := m != nil ? m.url : vm.base_url
        dep := load_module(vm, n.str, referrer)
        if dep == nil || dep.state == .Failed {
            fmt.eprintfln("[js] re-export falhou: %s", n.str)
            if vm.throwing do vm_clear_uncaught(vm)
            return nil
        }
        if m == nil do return nil
        if n.aux {
            if n.name != "" { // export * as ns from "x"
                oput(m.ns, n.name, dep.ns)
            } else { // export * from "x" — copia tudo exceto default (spec)
                for k, v in dep.ns.props do if k != "default" do oput(m.ns, k, v)
            }
        } else { // export {a, b as c} from "x"
            for c in n.body do oput(m.ns, c.str, get_member(vm, dep.ns, c.name))
        }
        return nil
    }
    // export {a, b as c} local: adia p/ o snapshot do fim do módulo
    if m != nil {
        for c in n.body do append(&m.deferred, Deferred_Export{local = c.name, exported = c.str})
        module_snapshot_exports(vm, m) // idem acima: chave visível já durante o ciclo
    }
    return nil
}

// Nomes declarados por `export <declaração>` → exports adiados (nome = exportado).
@(private = "file")
module_collect_decl_exports :: proc(m: ^Module, decl: ^Node) {
    add :: proc(m: ^Module, name: string) {
        if name != "" do append(&m.deferred, Deferred_Export{local = name, exported = name})
    }
    #partial switch decl.kind {
    case .VarDecl:
        add(m, decl.name)
        if decl.left != nil && decl.left.kind == .Pattern { // export const {a, b} = obj
            for el in decl.left.body do add(m, el.name)
        }
        for d in decl.body { // declaradores extras: export const a = 1, b = 2
            add(m, d.name)
            if d.left != nil && d.left.kind == .Pattern do for el in d.left.body do add(m, el.name)
        }
    case .Func, .Class:
        add(m, decl.name)
    }
}

// import.meta → { url } do módulo corrente (ou base_url em script clássico).
eval_import_meta :: proc(vm: ^Interp, n: ^Node = nil) -> Value {
    o := new_object(vm)
    url := n != nil ? n.str : ""            // léxico (carimbado no parse), como o import()
    if url == "" do url = vm.current_module != nil ? vm.current_module.url : vm.base_url
    o.props["url"] = own_str(vm, url)
    return o
}
