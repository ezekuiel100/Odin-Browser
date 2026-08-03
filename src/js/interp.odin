package js

// Interpretador tree-walking: percorre a AST e executa.
// Mesma espinha dorsal do LibJS (Ladybird) na fase inicial.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

// ── objetos, arrays e funções ───────────────────────────────────────────────

// Hooks opcionais de propriedade. Objetos "host" (ex.: um wrapper de nó DOM,
// instalado por dom_bindings.odin) usam-nos para interceptar get/set sem que o
// núcleo conheça o DOM. `handled=false` => cai no comportamento normal (props).
Prop_Get :: proc(vm: ^Interp, o: ^Object, name: string) -> (val: Value, handled: bool)
Prop_Set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> (handled: bool)
// Leitura por ÍNDICE INTEIRO, sem passar pelo nome. Existe só por custo: o caminho
// normal de `o[i]` num ^Object é get_index → key_string(i) → strings.clone +
// append(&vm.owned_strings) — ou seja, uma string RETIDA ATÉ O vm_destroy por
// acesso. Uma coleção viva (HTMLCollection, dom_collection.odin) é lida por índice
// dentro de laços, e sem este atalho `for(i…) el.children[i]` trocaria O(n) de
// cópia por O(n) de lixo. `handled=false` => cai no caminho por nome.
Prop_Get_Idx :: proc(vm: ^Interp, o: ^Object, idx: int) -> (val: Value, handled: bool)

// Atributos de uma propriedade (spec §6.1.7.1). A AUSÊNCIA da chave em `Object.attrs`
// significa o default de uma atribuição normal (`o.x = 1`): os três verdadeiros. Só
// props tocadas por defineProperty/freeze/seal entram no mapa, então o caminho quente
// (objeto comum, attrs == nil) não paga nada.
//
// Substituiu o antigo `hidden: map[string]bool`, que modelava só o enumerable — daí o
// helper mark_non_enumerable, que é o que aquele mapa fazia em ~30 sítios do motor.
Prop_Attr :: enum u8 { Writable, Enumerable, Configurable }
Prop_Attrs :: bit_set[Prop_Attr; u8]
ATTRS_DEFAULT :: Prop_Attrs{.Writable, .Enumerable, .Configurable}

Object :: struct {
    props:  map[string]Value,
    korder: [dynamic]string, // ordem de INSERÇÃO das data-props (spec: for-in/Object.keys/JSON enumeram na ordem de criação); escrever via oput p/ registrar
    getters: map[string]^Function, // accessors de object literal (nil até ter algum)
    setters: map[string]^Function,
    attrs:  map[string]Prop_Attrs, // atributos das props que NÃO são o default; nil até a 1ª
    proto:  ^Object,   // cadeia de protótipo (nil = fim); get_member sobe por ela
    proto_x: Value,    // protótipo EXÓTICO: o [[Prototype]] quando ele NÃO é um ^Object
                       // (`Object.create(array)`, `setPrototypeOf(o, fn)`). Array/função/
                       // regex/coleção são variantes próprias da union Value e não cabem
                       // em `proto`, então sem este campo o protótipo era DESCARTADO em
                       // silêncio e o objeto nascia sem herança nenhuma. Fica sempre no
                       // FIM da cadeia (quem tem proto_x não tem proto) — ver
                       // proto_exotic_end. NÃO é o `prim` abaixo: `prim` é subclasse de
                       // builtin e faz `Array.isArray` dar true, o que aqui seria errado.
    non_extensible: bool, // Object.preventExtensions/seal/freeze: não aceita prop NOVA.
                          // Polaridade invertida de propósito: o zero-value (false) é
                          // "extensível", que é o estado de todo objeto recém-criado.
    host:   rawptr,    // ponteiro NÃO-dono para um hospedeiro (ex.: ^dom.Node)
    get:    Prop_Get,  // hook opcional de leitura
    set:    Prop_Set,  // hook opcional de escrita
    geti:   Prop_Get_Idx, // hook opcional de leitura por índice inteiro (atalho do `get`)
    gen:    ^Generator, // != nil se este objeto é uma INSTÂNCIA de generator (generator.odin)
    px_target:  Value,   // Proxy: o alvo envolvido (nil se não é proxy — ver px_handler)
    px_handler: ^Object, // Proxy: o handler com os traps (get/set/has/...). != nil ⇒ este Object É um proxy
    ab:      ^Array_Buffer, // ArrayBuffer/TypedArray/DataView: buffer de bytes compartilhado (nil senão)
    ta_kind: TA_Kind,      // TypedArray: tipo do elemento; .None p/ ArrayBuffer; .DataView p/ DataView (typedarray.odin)
    ta_off:  int,          // TypedArray/DataView: offset em bytes dentro de ab.data
    ta_len:  int,          // TypedArray: nº de elementos; DataView: byteLength
    prim:    Value,        // SLOT INTERNO de subclasse de builtin (M136): `class X extends
                           // Map` cria um ^Object comum (props, proto, campos de classe) e
                           // guarda aqui o ^Collection que o `super()` construiu. Ver
                           // adopt_super_result / native_wants_prim.
}

// Buffer de bytes por trás de ArrayBuffer e suas views (TypedArray/DataView).
// Rastreado em vm.all_buffers e liberado no vm_destroy.
Array_Buffer :: struct {
    data: [dynamic]u8,
}

Array :: struct {
    items: [dynamic]Value,
    frozen: bool, // Object.freeze: itens não mudam e o array não cresce
    sealed: bool, // Object.seal/preventExtensions: não cresce, mas os itens mudam
    is_arguments: bool, // este ^Array é o objeto `arguments` de uma chamada. É um
                        // array de verdade por dentro (por isso
                        // `Array.prototype.slice.call(arguments)` funciona), mas o JS
                        // tem de vê-lo como Arguments: `Array.isArray` dá false e
                        // `Object.prototype.toString` dá "[object Arguments]" — as
                        // duas formas com que uma lib distingue os dois.
                        // Cabe no padding dos bools acima: custo de memória zero.
    props: map[string]Value, // props não-índice (exec.index/.input, strings.raw
                             // de tagged template); nil até a primeira escrita.
                             // NÃO enumeram (for-in/JSON seguem só nos items).
}

// Nativas recebem `this` (o objeto à esquerda do ponto) além dos argumentos.
Native_Fn :: proc(vm: ^Interp, this: Value, args: []Value) -> Value

// Um listener de evento registrado num nó DOM. Fica chaveado pelo ponteiro do
// nó (rawptr) no vm, não no wrapper — porque cada getElementById cria um wrapper
// novo, sem identidade estável.
Listener :: struct {
    type: string,     // "click", ...
    fn:   ^Function,
    prop: bool,       // veio de `el.onclick = fn` (propriedade) vs addEventListener.
                      // Reatribuir a propriedade SUBSTITUI o handler-propriedade anterior
                      // do mesmo tipo (evita acúmulo quando um componente re-renderiza).
}

// Um timer pendente (setTimeout/setInterval). O vm não tem relógio próprio: o
// hospedeiro (loop de frames da UI) avança o tempo via vm_pump_timers(dt).
Timer :: struct {
    id:       int,
    fn:       ^Function,
    due:      f64, // instante de disparo no relógio do vm (ms)
    interval: f64, // >0 = setInterval (reagenda a cada disparo)
    raf:      bool, // requestAnimationFrame: o callback recebe o timestamp (clock_ms)
    idle:     bool, // requestIdleCallback: o callback recebe um IdleDeadline (vm.idle_deadline)
}

// ── módulos ES (M109) ────────────────────────────────────────────────────────
// Um módulo carregado (por import()/import estático). O namespace (ns) recebe os
// exports; `deferred` são pares (local→exportado) snapshotados no FIM da avaliação
// (aproxima live bindings p/ grafos acíclicos: `export {a}; a = 2` exporta 2).

Module_State :: enum { Loading, Done, Failed }

Deferred_Export :: struct { local, exported: string } // fatias da fonte (owned_sources)

Module :: struct {
    url:      string,  // absoluta, owned (chave do registry)
    ns:       ^Object, // namespace de exports (vm-tracked)
    env:      ^Env,    // escopo do módulo (p/ snapshot adiado)
    state:    Module_State,
    deferred: [dynamic]Deferred_Export,
}

// Hooks de resolução/busca — instalados por dom_bindings (o interp não importa
// `net`). Testes instalam stubs em memória (vm.module_stubs).
Module_Resolve_Fn :: proc(vm: ^Interp, specifier, referrer: string) -> string   // "" = falha; owned
Module_Fetch_Fn   :: proc(vm: ^Interp, url: string) -> (src: string, ok: bool)  // src owned (caller deleta)

// Um valor-função. Se `native != nil`, é um builtin. Caso contrário é definida
// pelo usuário: guarda parâmetros, corpo e o `closure` (ambiente de definição).
Function :: struct {
    params:     []string,
    param_pats: []^Node, // padrão por parâmetro (nil = simples); paralelo a params
    param_defaults: []^Node, // valor default por parâmetro (nil = sem default); paralelo a params
    rest_param: string,  // nome do rest param (...xs); "" se não houver
    rest_pat: ^Node,     // rest DESESTRUTURADO (`...[t]`); nil = usa rest_param
    body:       ^Node,
    closure:  ^Env,
    native:   Native_Fn,
    name:     string,
    is_arrow: bool, // arrow não vincula `this` próprio (herda o léxico via closure)
    is_async: bool, // devolve Promise; throw vira rejeição (ver call_function)
    self_bind: bool, // function EXPRESSION nomeada: o nome só é visível dentro do
                     // próprio corpo — bindado no escopo da CHAMADA (setup_call_scope),
                     // já que não vaza mais p/ o env externo (spec)
    is_generator: bool, // function*: chamar devolve um objeto generator (generator.odin)
    uses_arguments: bool, // o corpo menciona `arguments` (ou `eval`) — só então
                          // setup_call_scope materializa o objeto. Vem do nó .Func
                          // (Parser.saw_arguments); nativa/bound nunca precisam.
    bound:    Value, // "closure" de nativas: valor extra visível via vm.native_bound
                     // durante a chamada (ex.: o resolve() de uma Promise sabe qual é a sua)
    props:    map[string]Value, // propriedades da função (ex.: Promise.resolve, prototype de classe); nil se não usadas
    // ── suporte a `class` (M21 fatia 1) ──
    super_ctor:  ^Function, // construtora da superclasse, para `super(...)`
    home_super:  ^Object,   // prototype da superclasse, para `super.metodo()`
    auto_super:  bool,      // construtor default derivado: chama super_ctor com os mesmos args
    class_node:  ^Node,     // se é a construtora de uma class: o nó .Class (p/ inicializar
                            // os campos de instância no `new`, ver init_instance_fields)
    getters:  map[string]^Function, // getters STATIC de classe (static get x(){}); nil até ter algum
    setters:  map[string]^Function, // setters STATIC de classe (static set x(v){})
    // ── Function.prototype.bind ──
    bind_target: ^Function,   // se != nil, esta é uma função LIGADA de bind_target
    bind_this:   Value,       // `this` fixado pelo bind
    bind_args:   [dynamic]Value, // args pré-fixados (prepended nas chamadas)
}

// ── ambiente (escopos) ─────────────────────────────────────────────────────────

// LIVE BINDING de import (M139): `import {x} from "m"` não copia o valor — aponta
// para a variável `local` no escopo do módulo exportador, e a leitura resolve NA
// HORA. É o que a spec manda, e a diferença é observável sempre que o exportador
// atribui o valor DEPOIS de avaliar o corpo (inicialização preguiçosa), que é
// idioma comum em bundle: `var Ln,Rn; function init(){ Ln=window, Rn=document }`
// com `export{Ln as tt, Rn as et}` — com cópia, o importador via undefined p/ sempre.
Env_Alias :: struct {
    src:   ^Env,   // escopo do módulo exportador
    local: string, // nome da variável LÁ (pode diferir do nome importado)
}

Env :: struct {
    vars:   map[string]Value,
    parent: ^Env,
    is_fn_scope: bool, // fronteira de escopo de FUNÇÃO (var sobe até aqui; blocos não)
    aliases: map[string]Env_Alias, // nil até o 1º import com live binding
    consts: map[string]bool,       // bindings declarados com `const` neste escopo; nil
                                   // até o 1º. env_assign lança TypeError ao acertar um
                                   // deles. Um mapa à parte (em vez de engordar `vars`
                                   // com um struct) mantém o caminho quente de leitura
                                   // intocado e não custa nada em escopo sem const.
}

// Escopo de função mais próximo (onde `var` binda — var é function-scoped, não
// block-scoped). Sobe pela cadeia até um is_fn_scope; cai no global se não achar.
@(private = "file")
fn_scope_env :: proc(env: ^Env) -> ^Env {
    cur := env
    for cur != nil {
        if cur.is_fn_scope || cur.parent == nil do return cur
        cur = cur.parent
    }
    return env
}

// Estado de execução: escopo global + memória de runtime a liberar no fim +
// o sinal de `return`.
Interp :: struct {
    global:         ^Env,
    all_envs:       [dynamic]^Env,
    env_pool:       [dynamic]^Env, // escopos de chamada devolvidos por recycle_envs,
                                   // prontos p/ reuso em new_env (mapa já alocado).
                                   // NÃO estão em all_envs — o vm_destroy libera à parte.
    env_escapes:    u64,           // nº de vezes que um ^Env pôde ser CAPTURADO por algo
                                   // que sobrevive à chamada corrente (closure, generator,
                                   // módulo, alias de import). call_function compara o
                                   // valor na entrada e na saída: se não mexeu, nada do
                                   // que nasceu na chamada escapou e pode ser reciclado.
                                   // Ver env_escaped/recycle_envs.
    all_funcs:      [dynamic]^Function,
    all_objects:    [dynamic]^Object,
    all_arrays:     [dynamic]^Array,
    all_buffers:    [dynamic]^Array_Buffer, // buffers de ArrayBuffer/TypedArray (typedarray.odin)
    ta_protos:      [TA_Kind]^Object,  // prototype compartilhado por tipo de TypedArray
    array_buffer_proto: ^Object,       // ArrayBuffer.prototype (slice)
    dataview_proto: ^Object,           // DataView.prototype (get/setInt8/Uint16/Float32/...)
    text_encoder_proto: ^Object,       // TextEncoder.prototype (encode/encodeInto)
    text_decoder_proto: ^Object,       // TextDecoder.prototype (decode)
    blob_proto:     ^Object,           // Blob.prototype (text/arrayBuffer/slice)
    idle_deadline:  Value,             // IdleDeadline reusável p/ requestIdleCallback (timeRemaining/didTimeout)
    bigint_proto:   ^Object,           // BigInt.prototype (toString/valueOf)
    all_regexes:    [dynamic]^Regex,   // regexes criadas (literais e new RegExp)
    all_collections:[dynamic]^Collection, // Map/Set/WeakMap/WeakSet criadas
    all_symbols:    [dynamic]^Symbol,      // Symbols criados (literais e Symbol.for)
    all_bigints:    [dynamic]^BigInt,      // BigInts criados (literais 123n e aritmética)
    symbol_registry: map[string]^Symbol,   // Symbol.for(key) — interna por chave
    symbol_keys:     map[string]^Symbol,   // chave-string de propriedade → ^Symbol que a gerou
                                           // (inverso de symbol_key); base do
                                           // Object.getOwnPropertySymbols. nil até o 1º uso.
    sym_iterator_key: string,              // chave-string do Symbol.iterator (p/ protocolo de iterador)
    sym_async_iterator_key: string,        // chave-string do Symbol.asyncIterator (for-await + async generators)
    sym_toprimitive_key: string,           // chave-string do Symbol.toPrimitive (ToPrimitive consulta antes de valueOf/toString)
    sym_has_instance_key: string,          // chave-string do Symbol.hasInstance (instanceof consulta antes da cadeia de proto)
    sym_tostring_tag_key: string,          // chave-string do Symbol.toStringTag (Object.prototype.toString consulta antes do #class)
    custom_elements: map[string]^Function, // registry de Web Components: tag → classe (customElements.define)
    document_node:   rawptr,               // ^dom.Node raiz (p/ upgrade de custom elements já no documento)
    all_asts:       [dynamic]^Node,   // ASTs de cada vm_run (handlers apontam p/ elas)
    owned_sources:  [dynamic]string,  // fontes clonadas (AST guarda fatias delas)
    owned_strings:  [dynamic]string,
    listeners:      map[rawptr][dynamic]Listener, // eventos por nó DOM (rawptr)
    console_log_fn: ^Function,
    console_buf:    [dynamic]Console_Entry, // linhas de console.log/warn/error capturadas p/ o painel DevTools
                                            // (ring: descarta as mais antigas ao passar de CONSOLE_LOG_MAX)
    fn_call_fn:     ^Function, // Function.prototype.call
    fn_tostring_fn: ^Function, // Function.prototype.toString ("[native code]")
    fn_apply_fn:    ^Function, // Function.prototype.apply
    fn_bind_fn:     ^Function, // Function.prototype.bind
    eval_fn:        ^Function, // o `eval` builtin — comparado por ponteiro p/ detectar eval DIRETO
    iter_next_fn:   ^Function, // next() compartilhado dos iteradores (array-backed)
    array_methods:  map[string]^Function, // métodos de Array (push, map, ...)
    array_ctor:     ^Function,             // o construtor Array (p/ `[].constructor === Array`)
    string_methods: map[string]^Function, // métodos de String (slice, split, ...)
    number_methods: map[string]^Function, // métodos de Number (toFixed, toString radix, ...)
    boolean_methods: map[string]^Function, // métodos de Boolean (toString, valueOf)
    function_proto: ^Object,              // Function.prototype: [[Prototype]] de toda função
                                          // (Object.getPrototypeOf(fn) quando não é classe derivada)
    global_this:    Value,                // `this` de chamada sem receptor (= window; nil sem DOM)
    date_proto:     ^Object,              // prototype compartilhado dos Date (date.odin)
    error_protos:   map[string]^Object,   // Error/TypeError/... → prototype (instanceof)
    object_methods: map[string]^Function, // métodos de todo objeto (hasOwnProperty, ...)
    collection_methods: map[string]^Function, // métodos de Map/Set/WeakMap/WeakSet (set, get, has, ...)
    regex_test_fn:  ^Function,             // RegExp.prototype.test/exec (regex.odin)
    regex_exec_fn:  ^Function,
    dom_element_ctor:      ^Function,             // constructor compartilhado dos elementos DOM (node.constructor.prototype — inputValueTracking do React); é o HTMLElement da hierarquia de interfaces
    dom_element_proto:     ^Object,               // HTMLElement.prototype (proto dos wrappers de elemento; base p/ instanceof + polyfills em Element/Node/HTMLElement.prototype)
    dom_htmlcollection_proto: ^Object,            // HTMLCollection.prototype (el.children — dom_collection.odin)
    dom_nodelist_proto:       ^Object,            // NodeList.prototype (el.childNodes)
    dom_colls: map[rawptr]^Coll_State,            // ^Object da coleção -> prefixo cacheado dos filhos
    dom_fragment_proto:    ^Object,               // DocumentFragment.prototype (nós "#content" de <template>)
    dom_shadowroot_proto:  ^Object,               // ShadowRoot.prototype (nós "#shadow")
    dom_tag_protos:        map[string]^Object,    // tag HTML -> HTML*Element.prototype específico (ex.: "script" -> HTMLScriptElement.prototype) p/ `el instanceof HTMLScriptElement` (invariant do Turbopack); ausente => cai no dom_element_proto genérico
    dom_element_methods:   map[string]^Function, // métodos de elemento (getAttribute, appendChild, ...)
    dom_classlist_methods: map[string]^Function, // métodos de classList (add, remove, ...)
    dom_style_methods:     map[string]^Function, // métodos de el.style (setProperty, getPropertyValue, ...)
    node_wrappers:  map[rawptr]^Object,   // cache nó DOM -> wrapper (IDENTIDADE: mesmo nó => mesmo Object)
    owned_nodes:    map[rawptr]bool,      // nós DOM criados/removidos pelo JS (liberar órfãos)
    dyn_scripts_run: int,                 // <script src> injetados via appendChild já executados (teto anti-runaway)
    dom_cleanup:    proc(vm: ^Interp),    // hook (dom_bindings) p/ liberar os órfãos no fim
    mut_observers:  [dynamic]^Object,     // MutationObserver ativos (mutation_observer.odin). VAZIO no caso comum:
                                          // é o `len` disto que faz toda mutação de DOM não pagar nada quando
                                          // nenhuma página observa. Objetos rastreados pelo vm; só a lista é liberada.
    mo_notifying:   bool,                 // já dentro de mo_notify? (um callback que muta não re-entra na entrega)
    mo_task_depth:  int,                  // tarefas síncronas de JS empilhadas (mo_task_enter/exit); a entrega
                                          // de MutationRecords só acontece quando volta a ZERO — a spec só roda
                                          // o microtask checkpoint com a pilha de execução VAZIA
    // Uso REAL da API (sai no --diagnose): quantas vezes a página chamou observe()
    // e quantos MutationRecords foram de fato entregues. Existe pela lição do M199,
    // onde a sonda GCSPROBE mostrou que `getComputedStyle` era chamado UMA vez em 9
    // sites — antes de investir num stub, conte quanto ele é usado. Contadores e não
    // sonda compile-gated porque nenhum dos dois pontos é caminho quente.
    mo_observe_calls: int,
    mo_records_sent:  int,
    int_observers:  [dynamic]^Object,     // IntersectionObserver ativos (intersection_observer.odin).
                                          // Mesma convenção do mut_observers: é o `len` disto que faz o
                                          // io_step do hospedeiro custar zero na página que não observa.
    io_stepping:    bool,                 // já dentro de io_step? (um callback que force layout não re-entra)
    io_observe_calls: int,                // uso REAL da API (sai no --diagnose), como o par do MutationObserver
    io_entries_sent:  int,
    media_lists:    [dynamic]^Object,     // MediaQueryList COM ouvinte (media_query.odin). Quem só lê
                                          // `.matches` não entra aqui — e por isso não custa nada por frame.
    media:          map[rawptr]^Media_State, // <video>/<audio> -> estado (media.odin), liberado à mão
    dommatrix_proto:    ^Object,          // DOMMatrix.prototype        (dommatrix.odin)
    dommatrix_ro_proto: ^Object,          // DOMMatrixReadOnly.prototype
    dompoint_proto:     ^Object,          // DOMPoint.prototype
    canvases:       map[rawptr]^Canvas_Ctx, // <canvas> -> contexto 2D (canvas.odin). O estado
                                          // gráfico e a lista de comandos são struct NATIVA
                                          // (não props do objeto JS): são milhares de números.
    size_observers: [dynamic]^Object,     // ResizeObserver ativos (resize_observer.odin)
    ro_stepping:    bool,                 // já dentro de ro_step? (callback que redimensiona não re-entra)
    ro_observe_calls: int,                // uso REAL da API (sai no --diagnose)
    ro_entries_sent:  int,
    timers:         [dynamic]Timer,       // setTimeout/setInterval pendentes
    next_timer_id:  int,
    clock_ms:       f64,                  // relógio do vm (avançado por vm_pump_timers)
    native_bound:   Value,                // fn.bound da nativa em execução (ver Function.bound)
    probe_stack:    [dynamic]string,      // nomes das funções em execução — SÓ mantida sob
                                          // -define:MEMBERPROBE=true (as sondas imprimem
                                          // a pilha JS; sem isso o nome minificado sozinho
                                          // não localiza o código no bundle)
    pending_new_target: Value,             // construtor do `new` corrente; consumido por setup_call_scope p/ new.target
    promise_then_fn:  ^Function,          // métodos compartilhados de Promise (promise.odin)
    promise_catch_fn: ^Function,
    promise_finally_fn: ^Function,
    promise_proto:    ^Object,            // Promise.prototype — [[Prototype]] de toda promise
    resp_text_fn:     ^Function,          // métodos da Response do fetch (fetch.odin)
    resp_json_fn:     ^Function,
    web_headers_proto:  ^Object,          // prototypes compartilhados da Fetch API (fetch.odin)
    web_request_proto:  ^Object,
    web_response_proto: ^Object,
    web_usp_proto:      ^Object,          // URLSearchParams
    web_formdata_proto: ^Object,          // FormData (mesma API k/v; reusa os métodos de USP)
    web_url_proto:      ^Object,          // URL (toString/toJSON; instâncias usam get hook p/ href/search/host/origin)
    web_signal_proto:   ^Object,          // AbortSignal
    web_rstream_proto:  ^Object,          // ReadableStream (streams.odin)
    web_wstream_proto:  ^Object,          // WritableStream
    event_proto:        ^Object,          // Event.prototype (instâncias de new Event linkam aqui)
    local_storage:   Storage, // localStorage — chave→valor de strings, em memória (storage.odin)
    session_storage: Storage, // sessionStorage
    pending_fetches: [dynamic]^Fetch_Req, // fetches em voo (threads; ver fetch.odin)
    base_url:        string,              // URL da página (owned) p/ resolver fetch relativo
    current_script:  rawptr,              // ^dom.Node do <script> em execução AGORA (document.currentScript);
                                          // rawptr pois interp.odin não importa `dom`. Setado por
                                          // load_page_scripts (por script) e maybe_run_injected_script.
    // document.write: PONTO DE INSERÇÃO. `write_owner` é o <script> a que a
    // âncora pertence; `write_anchor` é o nó depois do qual o PRÓXIMO write
    // insere. Sem a âncora, duas chamadas seguidas do mesmo script sairiam em
    // ordem INVERTIDA (as duas inseririam logo após o <script>).
    write_owner:     rawptr,              // ^dom.Node
    write_anchor:    rawptr,              // ^dom.Node
    // módulos ES (M109) — ver module.odin
    modules:        map[string]^Module,   // registry: url absoluta → módulo (cache + guarda de ciclo)
    all_modules:    [dynamic]^Module,     // todos os módulos criados (p/ liberar no destroy)
    modules_loaded: int,                  // cap MAX_MODULES (anti-runaway de rede)
    current_module: ^Module,              // módulo em avaliação (referrer/import.meta/exports)
    module_resolve: Module_Resolve_Fn,    // instalado por dom_bindings (net.resolve_url)
    module_fetch:   Module_Fetch_Fn,      // instalado por dom_bindings (net.fetch)
    module_stubs:   map[string]string,    // testes: fontes de módulo em memória (stub loader)
    event_prevent_fn: ^Function,          // e.preventDefault / e.stopPropagation (dom_bindings)
    event_stop_fn:    ^Function,
    returning:      bool,
    ret_val:        Value,
    breaking:       bool,  // um `break` está desenrolando até o loop
    continuing:     bool,  // um `continue` está desenrolando até o loop
    break_label:    string, // label alvo de `break foo` ("" = loop/switch mais próximo)
    continue_label: string, // label alvo de `continue foo` ("" = loop mais próximo)
    pending_label:  string, // label recém-visto (`foo:`), lido pelo próximo loop/switch
    throwing:       bool,  // um `throw` está desenrolando até o try/catch
    thrown:         Value, // o valor lançado
    opt_short:      bool,  // optional chaining (?.) curto-circuitou: o RESTO da cadeia
                           // (mesmo os elos NÃO-opcionais) deve ser pulado. `a?.b.c.d`
                           // com a nullish → undefined sem avaliar .b.c.d. Setado no elo
                           // opcional nullish; propagado pelos Member/Index/Call seguintes;
                           // limpo ao entrar em qualquer nó que NÃO seja elo de cadeia.
    steps:          u64,   // watchdog anti-hang: iterações de laço desde o último reset
    step_limit:     u64,   // teto de iterações por tarefa (STEP_LIMIT; testes reduzem)
    call_depth:     int,   // profundidade atual de call_function (recursão JS)
    call_depth_limit: int, // teto de recursão (CALL_DEPTH_LIMIT; testes reduzem)
    stack_low:      uintptr, // fundo reservado da stack da thread atual (stack_guard.odin); 0 = guarda off
    task_start:     time.Tick, // relógio REAL do início da tarefa (watchdog por tempo)
    time_budget_ms: f64,   // teto de tempo de parede por tarefa; 0 = desligado (TIME_BUDGET_MS)
    reaction_queue: [dynamic]Reaction_Job, // reações de Promise pendentes (microtasks; promise.odin)
    draining:       bool,  // já dentro de drain_reactions? (evita drain reentrante — mantém a stack flat)
    pump_depth:     int,   // profundidade de vm_pump_timers (await dentro de callback re-entra no pump)
    dead_timer_ids: map[int]bool, // ids cancelados por clearTimeout DURANTE um pump (o disparo pendente é pulado); limpo ao sair do pump raiz
    parse_recoveries: int, // recuperações silenciosas acumuladas (lexer+parser) — testes exigem 0 (check_parse_recoveries)
    parse_notes: [8]Parse_Recovery, // detalhe das primeiras (diagnóstico)
    uncaught_log:   [dynamic]string, // mensagens das exceções que chegaram ao topo sem catch (clonadas;
                                     // teto UNCAUGHT_LOG_MAX p/ um setInterval que lança não crescer sem fim).
                                     // Consumido pelo --diagnose <url> <saida.json> (gap-miner.ps1).
    uncaught_total: int,             // total REAL de exceções não capturadas (mesmo além do teto do log)
    // REJEIÇÕES de promise que ninguém tratou. PONTO CEGO até o M131: um erro no
    // corpo de uma async function vira rejeição, some do uncaught_log E do console —
    // foi o que escondeu cada camada do peel do Lit (M130). Registrado aqui p/ o
    // --diagnose reportar (js_unhandled_rejections).
    rejected_log:   [dynamic]string,
    rejected_total: int,
    // ── generators (generator.odin) ──
    all_generators: [dynamic]^Generator,  // generators criados (threads a limpar no destroy)
    current_gen:    ^Generator,            // generator cuja thread está rodando AGORA (p/ eval de yield)
    gen_hard_kill:  bool,                  // vm_destroy: desenrola o corpo do generator sem rodar mais JS
    gen_next_fn:    ^Function,             // métodos compartilhados do generator: next/return/throw
    gen_return_fn:  ^Function,
    gen_throw_fn:   ^Function,
    gen_iter_fn:    ^Function,             // [Symbol.iterator]() { return this }
    async_gen_next_fn:   ^Function,        // async generator: next/return/throw que devolvem Promise<{value,done}>
    async_gen_return_fn: ^Function,
    async_gen_throw_fn:  ^Function,
    object_proto:   ^Object,               // Object.prototype (base da cadeia; %IteratorPrototype% herda dele)
    iter_proto:     ^Object,               // %IteratorPrototype%: só [Symbol.iterator](){return this}. É o ALVO dos polyfills de iterator-helpers (getPrototypeOf(getPrototypeOf([][Symbol.iterator]()))).
    array_iter_proto: ^Object,             // %ArrayIteratorPrototype%: `next`. Fica ENTRE o iterador e o %IteratorPrototype% — sem ele a cadeia tinha um degrau a menos e os polyfills escreviam em Object.prototype (M219).
    symbol_proto:   ^Object,               // %SymbolPrototype% (= `Symbol.prototype`): toString/valueOf/[Symbol.toPrimitive]. Fonte ÚNICA — o get_member de ^Symbol lê daqui (M220).
}

// Teto de profundidade de recursão (frames de call_function empilhados). O
// interpretador é tree-walking: cada chamada JS = frames nativos Odin, e a stack
// nativa é finita. Sem este teto, recursão profunda (ou infinita) do JS de uma
// página ESTOURA a stack e MATA o processo sem diálogo. Ao bater no teto,
// lançamos RangeError (capturável) — mesma filosofia do STEP_LIMIT. O valor é
// folgado p/ apps reais (o React do tradebig recursiona ~1500) mas fica BEM abaixo
// da capacidade da stack nativa (com /STACK:256MB no build, ~20000 frames cabem).
CALL_DEPTH_LIMIT :: 10_000

// Teto de iterações de laço por "tarefa" síncrona (script inicial, callback de
// timer, handler de evento). Um browser NUNCA pode deixar o JS de uma página
// travar a UI; ao estourar, lançamos RangeError em vez de rodar p/ sempre.
// 200M é folgado p/ páginas legítimas mas corta laços que não convergem.
STEP_LIMIT :: 200_000_000

// Teto de TEMPO DE PAREDE por tarefa síncrona. O teto por PASSOS (200M) é a rede
// contra laço infinito, mas 200M passos podem levar dezenas de SEGUNDOS (ex.: o
// gtag.js do Google loopava ~40s até estourar), deixando a UI congelada. Este
// watchdog por tempo aborta QUALQUER tarefa que rode mais que isto de relógio
// real — corta o congelamento para poucos segundos. Generoso p/ render legítimo
// (SPAs renderizam em <1s com -o:speed); o await NÃO conta (reseta o relógio ao
// retornar, senão um await de 8s dispararia falso no código pós-await).
TIME_BUDGET_MS :: 4000.0

// ── perfil do interpretador (compile-gated: `-define:JSPROF=true`) ───────────
// Custo ZERO quando desligado (o `when` some no compilador). Ligado, conta o que
// é BARATO contar — um incremento por evento, sem tocar no relógio, que num
// tree-walker distorceria tudo. O tempo vem de fora (por fase), os contadores
// dizem ONDE o trabalho está.
JSPROF :: #config(JSPROF, false)

when JSPROF {
    Prof :: struct {
        evals:        u64,
        por_no:       [Node_Kind]u64, // eval() por tipo de nó
        get_member:   u64,            // leitura de propriedade por NOME
        get_index:    u64,            // leitura por índice/chave computada
        chamadas:     u64,            // call_function (usuário + nativa)
        chamadas_nat: u64,            // só nativas
        env_get:      u64,            // resolução de identificador na cadeia de escopo
        env_saltos:   u64,            // níveis percorridos até achar (custo REAL da cadeia)
        novos_env:    u64,            // escopos criados
        novos_obj:    u64,            // objetos alocados
        ms_total:     f64,            // tempo dentro de vm_exec (tokenize+parse+exec)
        ms_parse:     f64,            // só o parse_program
        bytes_fonte:  u64,            // JS entregue ao vm_exec
    }
    g_prof: Prof

    // Relatório em stderr; chamado no fim de cada modo headless (ver main.odin).
    prof_report :: proc() {
        if g_prof.evals == 0 { fmt.eprintfln("[jsprof] nada executado"); return }
        fmt.eprintfln("\n[jsprof] %d evals | %d chamadas (%d nativas) | %d get_member | %d get_index",
            g_prof.evals, g_prof.chamadas, g_prof.chamadas_nat, g_prof.get_member, g_prof.get_index)
        media := f64(g_prof.env_saltos) / f64(max(g_prof.env_get, 1))
        fmt.eprintfln("[jsprof] env_get=%d saltos=%d (media %.2f niveis) | envs criados=%d | objetos=%d",
            g_prof.env_get, g_prof.env_saltos, media, g_prof.novos_env, g_prof.novos_obj)
        fmt.eprintfln("[jsprof] vm_exec total=%.0f ms (parse %.0f ms = %.1f%%) sobre %.2f MB de JS",
            g_prof.ms_total, g_prof.ms_parse,
            100 * g_prof.ms_parse / max(g_prof.ms_total, 0.001),
            f64(g_prof.bytes_fonte) / (1024 * 1024))
        // top 12 tipos de nó
        Par :: struct { k: Node_Kind, n: u64 }
        lista: [dynamic]Par
        defer delete(lista)
        for n, k in g_prof.por_no do if n > 0 do append(&lista, Par{k, n})
        for i in 0 ..< len(lista) { // seleção simples: a lista é curta
            maxi := i
            for j in i + 1 ..< len(lista) do if lista[j].n > lista[maxi].n do maxi = j
            lista[i], lista[maxi] = lista[maxi], lista[i]
        }
        fmt.eprintfln("[jsprof] nós mais avaliados:")
        for p, i in lista {
            if i >= 12 do break
            fmt.eprintfln("   %6.2f%%  %12d  %v", 100 * f64(p.n) / f64(g_prof.evals), p.n, p.k)
        }
    }
}

// Teto EFETIVO, ajustável em tempo de execução pela CLI (`--js-timeout <ms>`; 0
// desliga). O default segue o TIME_BUDGET_MS acima — a flag existe para o caso
// medido no M181: com o teto padrão o bootstrap do open.spotify.com (bundle React
// de 4,5 MB, 2341 módulos) é ABORTADO pelo watchdog, e sem o teto ele roda sem
// exceção nenhuma. Ou seja: a flag é o que permite distinguir "o motor não sabe
// fazer" de "o motor é lento demais" — sem afrouxar o default, que existe p/ não
// congelar a UI em página patológica.
g_time_budget_ms: f64 = TIME_BUDGET_MS

// Ajusta o teto de tempo por tarefa de todo vm criado DAQUI PRA FRENTE.
// ⚠️ chamar ANTES de criar o vm da página (o valor é copiado em vm_create).
set_time_budget_ms :: proc(ms: f64) {
    g_time_budget_ms = ms if ms >= 0 else TIME_BUDGET_MS
}

// (Re)inicia o relógio da tarefa: chamado em cada fronteira de tarefa síncrona
// (vm_run, callback de timer, handler de evento) e ao retornar de um await.
reset_task_clock :: proc(vm: ^Interp) {
    vm.task_start = time.tick_now()
}

// Máscara p/ checar o tempo só a cada 2^16 passos (time.tick_now não é grátis).
@(private = "file")
TIME_CHECK_MASK :: u64(0xFFFF)

// Conta uma iteração de laço; devolve true (e arma um throw) se o teto estourou.
// break dentro de um loop/switch rotulado `my_label`: consome se for sem-label ou
// destinado a este; se for p/ um label EXTERNO, deixa `breaking` setado (propaga).
// De qualquer forma o chamador sai do loop.
@(private = "file")
loop_take_break :: proc(vm: ^Interp, my_label: string) {
    if vm.break_label == "" || vm.break_label == my_label {
        vm.breaking = false
        vm.break_label = ""
    }
}

// continue: devolve true se ESTE loop deve continuar (sem-label ou bate no label);
// false se o continue mira um loop EXTERNO (o loop atual sai mantendo o sinal).
@(private = "file")
loop_take_continue :: proc(vm: ^Interp, my_label: string) -> bool {
    if vm.continue_label == "" || vm.continue_label == my_label {
        vm.continuing = false
        vm.continue_label = ""
        return true
    }
    return false
}

@(private = "file")
step_guard :: proc(vm: ^Interp) -> bool {
    vm.steps += 1
    // teto por PASSOS
    if vm.steps > vm.step_limit {
        if !vm.throwing {
            vm.thrown = mk_error(vm, "RangeError", "limite de execução excedido (possível laço infinito)")
            vm.throwing = true
        }
        return true
    }
    // teto por TEMPO (checado esparso: 1x a cada 65536 passos). Aborta tarefas que
    // rodam demais de relógio (ex.: gtag.js loopando) sem esperar os 200M passos.
    if vm.time_budget_ms > 0 && (vm.steps & TIME_CHECK_MASK) == 0 {
        if time.duration_milliseconds(time.tick_since(vm.task_start)) > vm.time_budget_ms {
            if !vm.throwing {
                vm.thrown = mk_error(vm, "RangeError", "tempo de execução excedido (tarefa longa demais)")
                vm.throwing = true
            }
            return true
        }
    }
    return false
}

new_env :: proc(vm: ^Interp, parent: ^Env) -> ^Env {
    when JSPROF { g_prof.novos_env += 1 }
    e: ^Env
    if n := len(vm.env_pool); n > 0 {
        // reuso: `vars` já veio esvaziado (com a capacidade preservada) do
        // recycle_envs, o que poupa a alocação do mapa — o item mais caro de
        // montar um escopo de chamada.
        e = vm.env_pool[n - 1]
        pop(&vm.env_pool)
        e.parent = parent
        e.is_fn_scope = false
    } else {
        e = new(Env)
        e.parent = parent
        e.vars = make(map[string]Value)
    }
    append(&vm.all_envs, e)
    return e
}

// Teto do pool (escopos ociosos retidos) e maior mapa que vale a pena guardar:
// um escopo que chegou a centenas de vars carrega um mapa gordo, melhor liberar
// que manter reservado.
ENV_POOL_MAX     :: 1024
ENV_POOL_VAR_MAX :: 64

// Registra que um ^Env acabou de ficar alcançável por algo que sobrevive à
// chamada em curso. Chamado nos ÚNICOS pontos que guardam um ^Env em algum lugar:
// a closure de uma função (3 sítios), o escopo de um módulo, um alias de import
// com live binding, e a retomada de um generator (cuja thread mantém vivos os
// escopos do corpo suspenso entre um next() e o seguinte).
//
// É deliberadamente CONSERVADOR: basta um escape em qualquer ponto da chamada
// para ela inteira desistir de reciclar. Errar para o lado do vazamento é
// recuperável; errar para o lado da liberação é use-after-free.
env_escaped :: proc(vm: ^Interp) {
    vm.env_escapes += 1
}

// Devolve ao pool todos os escopos criados a partir de `mark` — o escopo da
// chamada e os escopos de bloco/laço que nasceram dentro dela. Só é chamado
// quando env_escapes não mudou durante a chamada, isto é, quando está provado
// que nenhum ^Env do intervalo pode ser alcançado depois do retorno.
@(private = "file")
recycle_envs :: proc(vm: ^Interp, mark: int) {
    for i := len(vm.all_envs) - 1; i >= mark; i -= 1 {
        e := vm.all_envs[i]
        if e.aliases != nil {
            delete(e.aliases)
            e.aliases = nil
        }
        if e.consts != nil {
            delete(e.consts)
            e.consts = nil
        }
        if len(vm.env_pool) < ENV_POOL_MAX && len(e.vars) <= ENV_POOL_VAR_MAX {
            clear(&e.vars)
            e.parent = nil
            append(&vm.env_pool, e)
        } else {
            delete(e.vars)
            free(e)
        }
    }
    resize(&vm.all_envs, mark)
}

// Cópia dos bindings do escopo de um `for (let ...)` p/ a próxima iteração
// (CreatePerIterationEnvironment da spec). O parent é o escopo EXTERNO ao for.
@(private = "file")
clone_loop_bindings :: proc(vm: ^Interp, src: ^Env, parent: ^Env) -> ^Env {
    e := new_env(vm, parent)
    for k, v in src.vars do e.vars[k] = v
    return e
}

// O subtree contém alguma função/arrow/classe (= pode criar closure)?
// Usado pelo .For p/ só pagar o binding por-iteração quando é observável.
@(private = "file")
subtree_has_func :: proc(n: ^Node) -> bool {
    if n == nil do return false
    if n.kind == .Func || n.kind == .Class do return true
    if subtree_has_func(n.left) || subtree_has_func(n.right) || subtree_has_func(n.third) || subtree_has_func(n.callee) {
        return true
    }
    for c in n.body do if subtree_has_func(c) do return true
    for pd in n.param_defaults do if subtree_has_func(pd) do return true
    return false
}

// Hoisting de declarações de função: antes de executar uma lista de statements,
// pré-define toda `function nome(){}` (posição de statement, filha direta) no
// escopo, para que chamadas ANTES da linha de declaração funcionem — semântica
// JS. Expressões de função (`var f = function(){}`) NÃO são içadas (não estão em
// posição de statement). O loop de execução PULA essas declarações depois (já
// içadas), evitando recriar a função. Declaração posterior de mesmo nome vence.
@(private = "file")
hoist_functions :: proc(vm: ^Interp, stmts: []^Node, env: ^Env) {
    for s in stmts {
        if s.kind == .Func && s.name != "" {
            eval(vm, s, env) // cria a ^Function e a define em env
        }
        // `export function f(){}` — a função içada vive DENTRO do .ExportDecl.
        // Iça a função; o .ExportDecl ainda roda na ordem (re-define, inofensivo,
        // e registra o nome no namespace do módulo).
        if s.kind == .ExportDecl && !s.bval && s.left != nil && s.left.kind == .Func && s.left.name != "" {
            eval(vm, s.left, env)
        }
    }
}

// Uma declaração de função já içada por hoist_functions — o loop de execução a
// pula para não recriar a mesma função ao alcançar a linha.
@(private = "file")
is_hoisted_func :: proc(s: ^Node) -> bool {
    return s.kind == .Func && s.name != ""
}

// ── Hoisting de `var` (function-scoped) ──────────────────────────────────────
// `var` é içado ao ESCOPO DE FUNÇÃO, não importa em que bloco aparece. Sem isto,
// um `var x` num ramo (ex.: `case"img": var a` do React — declarado 1× mas usado
// como local em TODOS os cases do switch) nunca é definido quando a execução cai
// noutro ramo, e a atribuição `a=...` desse ramo vira GLOBAL implícito (env_assign
// sobe até a raiz) — corrompendo um `a` homônimo de OUTRA função. Pré-define cada
// nome como undefined (sem clobber de param/função já ligados). NÃO desce em
// funções aninhadas (escopo próprio). Só declara; a init roda ao alcançar o `var`.
@(private = "file")
hoist_declare :: proc(env: ^Env, name: string) {
    if name == "" do return
    if _, ok := env.vars[name]; !ok do env.vars[name] = nil
}

@(private = "file")
hoist_pattern_names :: proc(pat: ^Node, env: ^Env) {
    if pat == nil do return
    for el in pat.body {
        hoist_declare(env, el.name) // ident ligado (inclui rest)
        if el.left != nil && el.left.kind == .Pattern do hoist_pattern_names(el.left, env)
    }
}

@(private = "file")
hoist_one_decl :: proc(decl: ^Node, env: ^Env) {
    hoist_declare(env, decl.name)
    if decl.left != nil do hoist_pattern_names(decl.left, env)
}

@(private = "file")
hoist_vars :: proc(node: ^Node, env: ^Env) {
    if node == nil do return
    #partial switch node.kind {
    case .Func:
        return // função aninhada: escopo próprio, não desce
    case .VarDecl:
        if node.aux { // só var; let/const são block-scoped
            hoist_one_decl(node, env)
            for d in node.body do hoist_one_decl(d, env) // declaradores extras (var a=1,b=2)
        }
    case .Program, .Block:
        for s in node.body do hoist_vars(s, env)
    case .ExportDecl:
        hoist_vars(node.left, env) // export var x — o var içado vive dentro do wrapper
    case .If:
        hoist_vars(node.right, env)
        hoist_vars(node.third, env)
    case .While, .DoWhile:
        hoist_vars(node.right, env)
    case .For:
        hoist_vars(node.left, env)   // init (VarDecl no for clássico)
        hoist_vars(node.callee, env) // corpo
    case .ForOf:
        if node.stat { // for(var x of/in ...): o loop-var é function-scoped
            hoist_declare(env, node.name)
            if node.left != nil do hoist_pattern_names(node.left, env)
        }
        hoist_vars(node.callee, env) // corpo
    case .Switch:
        for c in node.body do hoist_vars(c, env) // SwitchCase
    case .SwitchCase:
        for s in node.body do hoist_vars(s, env)
    case .Try:
        hoist_vars(node.left, env)   // try
        hoist_vars(node.right, env)  // catch
        hoist_vars(node.third, env)  // finally
    case .Labeled:
        hoist_vars(node.left, env)
    }
}

hoist_vars_body :: proc(stmts: []^Node, env: ^Env) {
    for s in stmts do hoist_vars(s, env)
}

// Todo objeto nasce com [[Prototype]] = Object.prototype (spec: OrdinaryObjectCreate
// em ObjectLiteral/JSON.parse/new). Ficar com proto nil fazia
// `Object.getPrototypeOf({})` devolver null e `({}) instanceof Object` dar FALSE —
// e é exatamente isso que o `isPlainObject` do Redux testa (ele sobe a cadeia até
// null e compara com o topo). Com proto nil o teste dava false e o Redux recusava
// TODA action: "Actions must be plain objects" (ext.popups da Wikipedia). Custo
// ZERO de memória — `proto` já era um campo do Object; o que muda é o get_member
// andar UM nível a mais só quando a prop NÃO existe.
// ⚠️ nil durante o bootstrap (install_object ainda não criou o proto): é o que
// impede Object.prototype.proto de apontar p/ si mesmo e enroscar o get_member.
new_object :: proc(vm: ^Interp) -> ^Object {
    when JSPROF { g_prof.novos_obj += 1 }
    o := new(Object)
    o.props = make(map[string]Value)
    o.proto = vm.object_proto
    append(&vm.all_objects, o)
    return o
}

new_array :: proc(vm: ^Interp) -> ^Array {
    a := new(Array)
    append(&vm.all_arrays, a)
    return a
}

// Objeto de erro {name, message} para lançar (msg é clonada p/ o vm).
mk_error :: proc(vm: ^Interp, name, msg: string) -> ^Object {
    o := new_object(vm)
    o.props["name"] = name
    o.props["message"] = own_str(vm, msg)
    // erro de verdade: cadeia de protótipo (instanceof TypeError/Error) + stack
    if proto, ok := vm.error_protos[name]; ok {
        o.proto = proto
    } else if base, bok := vm.error_protos["Error"]; bok {
        o.proto = base
    }
    o.props["stack"] = own_str(vm, fmt.tprintf("%s: %s", name, msg)) // mínimo (sem frames)
    return o
}

// Lança um TypeError do próprio motor (null.x, chamar não-função, ...).
throw_type_error :: proc(vm: ^Interp, msg: string) {
    when #config(MEMBERPROBE, false) {
        fmt.eprintfln("[throwprobe] %s | pilha: %v", msg, vm.probe_stack)
    }
    vm.thrown = mk_error(vm, "TypeError", msg)
    vm.throwing = true
}

// Lança um ReferenceError do próprio motor (identificador livre não resolvido).
throw_reference_error :: proc(vm: ^Interp, msg: string) {
    when #config(MEMBERPROBE, false) {
        fmt.eprintfln("[throwprobe] %s | pilha: %v", msg, vm.probe_stack)
    }
    vm.thrown = mk_error(vm, "ReferenceError", msg)
    vm.throwing = true
}

// Resolve um identificador LIVRE sem lançar: cadeia de escopos e, se nada,
// o objeto global (no browser o global É o window, então `addEventListener(...)`
// nu == `window.addEventListener`; idem matchMedia/getComputedStyle/innerWidth…).
// Devolve (valor, achou). Compartilhado por eval(.Ident) — que LANÇA quando não
// acha — e por `typeof`, a única isenção da spec, que precisa do mesmo lookup
// SEM o throw. Ter um funil só é o que garante que os dois não divirjam.
lookup_ident :: proc(vm: ^Interp, env: ^Env, name: string) -> (Value, bool) {
    if v, ok := env_get(env, name); ok do return v, true
    if winv, wok := env_get(vm.global, "window"); wok {
        if win, ok := winv.(^Object); ok {
            // ⚠️ pelo HOOK (window_get), não por `win.props` direto: as props
            // DINÂMICAS da janela (innerWidth/innerHeight, scrollY/pageYOffset)
            // são servidas pelo hook, e o mapa guarda só o FALLBACK estático.
            // Lendo o mapa, `window.innerWidth` dava 1280 e `innerWidth` NU dava
            // 800 — exatamente a divergência que o comentário acima promete não
            // existir. Medido pelo teste do M232.
            if win.get != nil {
                if v, handled := win.get(vm, win, name); handled do return v, true
            } else if pv, has := win.props[name]; has {
                return pv, true
            }
        }
    }
    return nil, false
}

// Um valor é primitivo se NÃO é objeto/array/função/regex/coleção.
is_primitive :: proc(v: Value) -> bool {
    #partial switch _ in v {
    case ^Object, ^Array, ^Function, ^Regex, ^Collection:
        return false
    }
    return true // f64/bool/string/nil(undefined)/JS_Null/Symbol
}

// ToPrimitive(v, hint): objeto → tenta valueOf/toString (ordem pelo hint) e devolve
// o 1º resultado PRIMITIVO; se nenhum for primitivo, TypeError. Não-objetos passam.
// `hint_name` só afeta a STRING passada ao @@toPrimitive; a ordem valueOf/toString
// continua vindo de `hint_number`. Existe porque o operador `+` usa o hint "default"
// da spec (não "number"), e código real inspeciona esse argumento.
to_primitive :: proc(vm: ^Interp, v: Value, hint_number: bool, hint_name := "") -> Value {
    if is_primitive(v) do return v
    // 1) Symbol.toPrimitive tem precedência sobre valueOf/toString (spec).
    if vm.sym_toprimitive_key != "" {
        if fn, fok := get_member(vm, v, vm.sym_toprimitive_key).(^Function); fok {
            hint: Value = hint_name != "" ? hint_name : (hint_number ? "number" : "string")
            r := call_function(vm, fn, v, []Value{hint})
            if vm.throwing do return nil
            if is_primitive(r) do return r
        }
    }
    // 2) valueOf/toString, na ordem ditada pelo hint.
    order := hint_number ? [2]string{"valueOf", "toString"} : [2]string{"toString", "valueOf"}
    for m in order {
        if fn, fok := get_member(vm, v, m).(^Function); fok {
            r := call_function(vm, fn, v, nil)
            if vm.throwing do return nil
            if is_primitive(r) do return r
        }
    }
    // 3) Sem método primitivo. Para ^Object a spec manda TypeError (e é o que já
    //    fazíamos). Para os demais (Regex, Collection, ...) alguns não têm toString
    //    próprio no nosso motor — lançar aqui seria uma REGRESSÃO em código que hoje
    //    funciona, então caímos no texto de debug.
    if _, is_obj := v.(^Object); is_obj {
        throw_type_error(vm, "Cannot convert object to primitive value")
        return nil
    }
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, v)
    return own_str(vm, strings.to_string(sb))
}

// ToString(v) da spec: um objeto passa por ToPrimitive(hint string) ANTES de virar
// texto. NÃO confundir com to_text, que é o formatador de DEBUG do console.log
// (mostra `[1, 2]` e "Error: msg"). Aqui `[1,2]` vira "1,2" e um toString custom é
// respeitado — é o que `"" + obj`, `${obj}` e String(obj) precisam.
write_text_spec :: proc(sb: ^strings.Builder, vm: ^Interp, v: Value) {
    if is_primitive(v) {
        to_text(sb, v)
        return
    }
    p := to_primitive(vm, v, false) // hint string
    if vm.throwing do return
    to_text(sb, p)
}

// ToNumber espec (com ToPrimitive): objeto invoca valueOf/toString; Symbol lança
// TypeError. Use nos pontos onde a spec pede coerção numérica de argumentos
// (Math.max, setters de Date, ...) — NÃO no caminho quente da aritmética.
to_number :: proc(vm: ^Interp, v: Value) -> f64 {
    #partial switch _ in v {
    case ^Symbol:
        throw_type_error(vm, "Cannot convert a Symbol value to a number")
        return math.nan_f64()
    case ^Object:
        p := to_primitive(vm, v, true)
        if vm.throwing do return math.nan_f64()
        return as_number(p)
    }
    return as_number(v) // primitivos + array/função/regex (as_number já cobre)
}

new_function :: proc(vm: ^Interp) -> ^Function {
    f := new(Function)
    append(&vm.all_funcs, f)
    return f
}

vm_destroy :: proc(vm: ^Interp) {
    // encerra threads de generators suspensos ANTES de liberar envs/objetos (o
    // desenrolar das threads ainda percorre frames que referenciam esses envs).
    cleanup_generators(vm)
    mo_free(vm) // antes do dom_cleanup: nada mais deve enfileirar record
    io_free(vm) // idem: nenhum observador de interseção sobrevive ao vm
    mq_free(vm) // idem p/ os MediaQueryList com ouvinte
    ro_free(vm)     // idem p/ os ResizeObserver
    canvas_free(vm) // contexto 2D: struct nativa, liberada à mão
    media_free(vm)  // estado de <video>/<audio>: idem
    // libera os nós DOM órfãos (criados/removidos pelo JS e nunca (re)anexados);
    // os anexados à árvore da página são liberados pelo free_tree dela.
    if vm.dom_cleanup != nil do vm.dom_cleanup(vm)
    for e in vm.all_envs {
        delete(e.vars)
        if e.aliases != nil do delete(e.aliases)
        if e.consts != nil do delete(e.consts)
        free(e)
    }
    delete(vm.all_envs)
    // escopos ociosos no pool: fora de all_envs, precisam ser liberados aqui
    for e in vm.env_pool {
        delete(e.vars)
        if e.aliases != nil do delete(e.aliases)
        if e.consts != nil do delete(e.consts)
        free(e)
    }
    delete(vm.env_pool)
    delete(vm.probe_stack) // vazia fora de build com MEMBERPROBE
    for f in vm.all_funcs {
        delete(f.props)
        if f.bind_args != nil do delete(f.bind_args)
        if f.getters != nil do delete(f.getters)
        if f.setters != nil do delete(f.setters)
        free(f)
    }
    delete(vm.all_funcs)
    fetch_abandon_pending(vm) // fetches em voo: protocolo atômico (fetch.odin)
    if vm.base_url != "" do delete(vm.base_url)
    // módulos ES: o registry referencia m.url como chave — deleta o mapa ANTES
    // de liberar as urls. ns/env são vm-tracked (all_objects/all_envs).
    delete(vm.modules)
    for m in vm.all_modules {
        delete(m.url)
        delete(m.deferred)
        free(m)
    }
    delete(vm.all_modules)
    if vm.module_stubs != nil do delete(vm.module_stubs)
    for o in vm.all_objects {
        delete(o.props)
        delete(o.korder)
        if o.getters != nil do delete(o.getters)
        if o.setters != nil do delete(o.setters)
        if o.attrs != nil do delete(o.attrs)
        free(o)
    }
    delete(vm.all_objects)
    for a in vm.all_arrays {
        delete(a.items)
        if a.props != nil do delete(a.props)
        free(a)
    }
    delete(vm.all_arrays)
    for b in vm.all_buffers { delete(b.data); free(b) }
    delete(vm.all_buffers)
    for re in vm.all_regexes do regex_destroy(re)
    delete(vm.all_regexes)
    for c in vm.all_collections { delete(c.entries); free(c) }
    delete(vm.all_collections)
    for s in vm.all_symbols { delete(s.desc); free(s) }
    delete(vm.all_symbols)
    for b in vm.all_bigints { bigint_destroy(b) }
    delete(vm.all_bigints)
    for k in vm.symbol_registry do delete(k)
    delete(vm.symbol_registry)
    if vm.symbol_keys != nil do delete(vm.symbol_keys) // chaves são owned_strings
    for s in vm.owned_strings do delete(s)
    delete(vm.owned_strings)
    for ast in vm.all_asts do free_ast(ast)
    delete(vm.all_asts)
    for src in vm.owned_sources do delete(src)
    delete(vm.owned_sources)
    for _, list in vm.listeners do delete(list)
    delete(vm.listeners)
    delete(vm.array_methods)  // as ^Function já foram liberadas via all_funcs
    delete(vm.string_methods)
    delete(vm.number_methods)
    delete(vm.boolean_methods)
    for k in vm.custom_elements do delete(k)
    delete(vm.custom_elements)
    delete(vm.error_protos)   // os ^Object vão via all_objects
    delete(vm.object_methods)
    delete(vm.collection_methods)
    delete(vm.dom_element_methods)
    delete(vm.dom_classlist_methods)
    delete(vm.dom_style_methods)
    delete(vm.owned_nodes)
    delete(vm.node_wrappers) // os ^Object já foram liberados via all_objects
    coll_free_all(vm)         // prefixos das HTMLCollection/NodeList vivas (dom_collection.odin)
    delete(vm.dom_tag_protos) // só chaves string próprias; os ^Object são liberados via all_objects
    delete(vm.timers)
    delete(vm.reaction_queue)
    delete(vm.dead_timer_ids)
    for m in vm.uncaught_log do delete(m)
    delete(vm.uncaught_log)
    for m in vm.rejected_log do delete(m)
    delete(vm.rejected_log)
    for e in vm.console_buf do delete(e.text)
    delete(vm.console_buf)
    storage_free(&vm.local_storage)   // localStorage/sessionStorage: strings clonadas (storage.odin)
    storage_free(&vm.session_storage)
}

// Avança o relógio do vm e dispara os timers vencidos. O hospedeiro chama a
// cada frame (dt em ms). Coleta primeiro, dispara depois: handlers podem criar
// ou cancelar timers durante a execução sem invalidar a iteração.
// Devolve true se algum disparou (o hospedeiro deve re-estilizar/re-layout).
vm_pump_timers :: proc(vm: ^Interp, dt_ms: f64) -> bool {
    fired := vm_pump_fetches(vm) // fetches concluídos resolvem suas Promises aqui
    refresh_stack_limit(vm)      // pode ser chamado de thread diferente (await na worker)
    vm.clock_ms += dt_ms
    due: [dynamic]Timer // copia os vencidos (fn+raf) antes de disparar
    defer delete(due)
    i := 0
    for i < len(vm.timers) {
        if vm.timers[i].due <= vm.clock_ms {
            append(&due, vm.timers[i])
            if vm.timers[i].interval > 0 {
                vm.timers[i].due = vm.clock_ms + vm.timers[i].interval
                i += 1
            } else {
                ordered_remove(&vm.timers, i)
            }
        } else {
            i += 1
        }
    }
    // ordem de disparo: VENCIMENTO crescente, não ordem de registro —
    // setTimeout(f,100); setTimeout(g,50) vencidos juntos disparam g antes de f.
    // Empate mantém a ordem de registro (insertion sort estável).
    for a := 1; a < len(due); a += 1 {
        for j := a; j > 0 && due[j].due < due[j-1].due; j -= 1 {
            due[j], due[j-1] = due[j-1], due[j]
        }
    }
    vm.pump_depth += 1
    for t in due {
        // clearTimeout chamado por um callback ANTERIOR deste mesmo pump: o
        // disparo pendente é cancelado (como no navegador)
        if vm.dead_timer_ids[t.id] do continue
        vm.steps = 0 // watchdog: cada callback é uma tarefa síncrona nova
        vm.call_depth = 0
        reset_task_clock(vm)
        mo_task_enter(vm)
        if t.raf {
            call_function(vm, t.fn, nil, []Value{vm.clock_ms}) // rAF: passa o timestamp
        } else if t.idle {
            call_function(vm, t.fn, nil, []Value{vm.idle_deadline}) // rIC: passa o IdleDeadline
        } else {
            call_function(vm, t.fn, nil, nil)
        }
        vm_clear_uncaught(vm) // um callback que lança não impede os demais
        mo_task_exit(vm)      // fim de tarefa: entrega os MutationRecords desta callback
    }
    vm.pump_depth -= 1
    if vm.pump_depth == 0 && len(vm.dead_timer_ids) > 0 do clear(&vm.dead_timer_ids)
    return fired || len(due) > 0
}

// O outro lado do que o hospedeiro chama por frame: o que a spec faz no "update
// the rendering", DEPOIS das tarefas (é a ordem do navegador — um setTimeout(0)
// registrado junto de um observe() roda ANTES do 1º callback dele). Funil ÚNICO
// de propósito: a próxima API deste tipo (ResizeObserver) entra aqui e nenhum
// hospedeiro precisa mudar.
// Devolve true se algum callback rodou — o hospedeiro trata igual ao retorno de
// `vm_pump_timers` (pode ter mexido no DOM: re-estilizar antes de pintar).
vm_frame_step :: proc(vm: ^Interp) -> bool {
    if vm == nil do return false
    fired := io_step(vm)   // IntersectionObserver (intersection_observer.odin)
    if ro_step(vm)  do fired = true // ResizeObserver   (resize_observer.odin)
    if mql_step(vm) do fired = true // matchMedia 'change' (media_query.odin)
    return fired
}

env_get :: proc(e: ^Env, name: string) -> (Value, bool) {
    when JSPROF { g_prof.env_get += 1 }
    cur := e
    for cur != nil {
        when JSPROF { g_prof.env_saltos += 1 } // custo REAL da cadeia: niveis percorridos
        if v, ok := cur.vars[name]; ok do return v, true
        // live binding de import: resolve no escopo do módulo exportador AGORA
        if cur.aliases != nil {
            if a, ok := cur.aliases[name]; ok do return env_get(a.src, a.local)
        }
        cur = cur.parent
    }
    return nil, false
}

// Binda `name` como live binding de `local` no escopo `src` (ver Env_Alias).
env_alias :: proc(e: ^Env, name: string, src: ^Env, local: string) {
    if src == nil do return
    if e.aliases == nil do e.aliases = make(map[string]Env_Alias)
    e.aliases[name] = Env_Alias{src = src, local = local}
}

env_define :: proc(e: ^Env, name: string, v: Value) {
    e.vars[name] = v
}

// Declara um binding `const`: define o valor e marca o nome como imutável NESTE
// escopo. A marca é por escopo (não por nome), então um `const x` interno e um
// `let x` externo continuam independentes — e um `for (const x of ...)`, que
// redefine o binding a cada iteração num escopo novo, segue funcionando (o rebind
// passa por env_define, não por env_assign).
env_define_const :: proc(e: ^Env, name: string, v: Value) {
    e.vars[name] = v
    if e.consts == nil do e.consts = make(map[string]bool)
    e.consts[name] = true
}

// Atribui a um binding EXISTENTE, subindo a cadeia. Lança TypeError se o binding
// encontrado for `const` — antes a reatribuição passava calada, e um bug que o
// browser real rejeita corrompia estado aqui em silêncio.
env_assign :: proc(vm: ^Interp, e: ^Env, name: string, v: Value) {
    cur := e
    root := e
    for cur != nil {
        if _, ok := cur.vars[name]; ok {
            if cur.consts != nil && cur.consts[name] {
                throw_type_error(vm, "Assignment to constant variable.")
                return
            }
            cur.vars[name] = v
            return
        }
        root = cur
        cur = cur.parent
    }
    // não declarada em lugar nenhum: GLOBAL implícito (sloppy mode) — a raiz
    // da cadeia é o escopo global; gravar no env atual criaria um local que
    // some no fim do bloco/função (código real depende do global vazar).
    root.vars[name] = v
}

// ── texto (console.log / concatenação) ─────────────────────────────────────────

@(private = "file")
write_number :: proc(sb: ^strings.Builder, n: f64) {
    if n != n { // %v do Odin imprime "NaN"/"+Inf"/"-Inf" — JS quer estes nomes:
        strings.write_string(sb, "NaN")
        return
    }
    if n == math.inf_f64(1) {
        strings.write_string(sb, "Infinity")
        return
    }
    if n == math.inf_f64(-1) {
        strings.write_string(sb, "-Infinity")
        return
    }
    // caminho QUENTE: inteiro exato de até 15 dígitos. Como |n| < 1e15, a spec
    // sempre pede a forma decimal simples aqui — o %d já dá o resultado certo.
    // (-0 vira i64 0 → "0", que é o que String(-0) devolve.)
    if abs(n) < 1e15 && n == f64(i64(n)) {
        fmt.sbprintf(sb, "%d", i64(n))
        return
    }
    write_number_spec(sb, n)
}

// Number::toString(x, 10) da spec (§6.1.6.1.20). O `%v` do Odin formatava pelo
// estilo do C, que diverge do JS em dois pontos VISÍVEIS em qualquer página que
// imprima número pequeno: o expoente vinha com zero à esquerda ("1e-07" em vez de
// "1e-7") e a troca para notação científica acontecia cedo demais ("1e-06" em vez
// de "0.000001" — o JS só troca abaixo de 1e-6).
//
// O algoritmo da spec parte dos MENORES dígitos significativos que fazem
// round-trip (é o que `write_float(..., 'e', -1, ...)` produz) e então escolhe a
// forma pelo expoente decimal. Com s = dígitos, k = len(s) e n = expoente+1:
//   k ≤ n ≤ 21  → s seguido de n−k zeros          (1e20 → "100000000000000000000")
//   0 < n ≤ 21  → s com ponto após n dígitos      (1234.5678)
//   −6 < n ≤ 0  → "0." + (−n zeros) + s           (1e-6 → "0.000001")
//   senão       → científica, expoente SEM zero à esquerda (1e-7 → "1e-7")
@(private = "file")
write_number_spec :: proc(sb: ^strings.Builder, x: f64) {
    v := x
    if v < 0 {
        strings.write_byte(sb, '-')
        v = -v
    }
    if v == 0 {
        strings.write_byte(sb, '0')
        return
    }
    buf: [64]u8
    sci := strconv.write_float(buf[:], v, 'e', -1, 64) // "+d.ddde±dd" (shortest)
    body := sci
    if len(body) > 0 && (body[0] == '+' || body[0] == '-') do body = body[1:]
    epos := strings.index_byte(body, 'e')
    if epos < 0 { // formato inesperado: melhor imprimir algo do que nada
        strings.write_string(sb, body)
        return
    }
    exp10, exp_ok := strconv.parse_int(body[epos + 1:])
    if !exp_ok {
        strings.write_string(sb, body)
        return
    }
    // dígitos significativos, sem o ponto (um f64 tem no máximo 17)
    digits: [32]u8
    k := 0
    for c in transmute([]u8)body[:epos] {
        if c == '.' do continue
        if k >= len(digits) do break
        digits[k] = c
        k += 1
    }
    s := string(digits[:k])
    n := exp10 + 1

    switch {
    case k <= n && n <= 21:
        strings.write_string(sb, s)
        for _ in 0 ..< n - k do strings.write_byte(sb, '0')
    case 0 < n && n <= 21:
        strings.write_string(sb, s[:n])
        strings.write_byte(sb, '.')
        strings.write_string(sb, s[n:])
    case -6 < n && n <= 0:
        strings.write_string(sb, "0.")
        for _ in 0 ..< -n do strings.write_byte(sb, '0')
        strings.write_string(sb, s)
    case:
        strings.write_byte(sb, s[0])
        if k > 1 {
            strings.write_byte(sb, '.')
            strings.write_string(sb, s[1:])
        }
        strings.write_byte(sb, 'e')
        e := n - 1
        if e >= 0 {
            strings.write_byte(sb, '+')
        } else {
            strings.write_byte(sb, '-')
            e = -e
        }
        fmt.sbprintf(sb, "%d", e)
    }
}

// Escreve a forma textual de um Value no builder (usado por console.log,
// concatenação e pelas bindings de DOM). Visível no pacote (não file-private).
to_text :: proc(sb: ^strings.Builder, v: Value) {
    switch x in v {
    case f64:
        write_number(sb, x)
    case bool:
        strings.write_string(sb, "true" if x else "false")
    case string:
        strings.write_string(sb, x)
    case JS_Null:
        strings.write_string(sb, "null")
    case ^Function:
        strings.write_string(sb, "function")
    case ^Object:
        // objetos "de erro" ({name, message}) imprimem "Name: message" — é o
        // que faz o log de exceção não capturada ficar útil
        name, has_name := x.props["name"]
        msg, has_msg := x.props["message"]
        if has_name && has_msg {
            to_text(sb, name)
            if s, is_s := msg.(string); !is_s || len(s) > 0 {
                strings.write_string(sb, ": ")
                to_text(sb, msg)
            }
        } else {
            strings.write_string(sb, "[object Object]")
        }
    case ^Array:
        strings.write_byte(sb, '[')
        for it, i in x.items {
            if i > 0 do strings.write_string(sb, ", ")
            to_text(sb, it)
        }
        strings.write_byte(sb, ']')
    case ^Regex:
        strings.write_byte(sb, '/')
        strings.write_string(sb, x.source)
        strings.write_byte(sb, '/')
        strings.write_string(sb, x.flags)
    case ^Collection:
        // ex.: "Map(2)" / "Set(3)" — como o console dos navegadores
        switch x.kind {
        case .Map:      strings.write_string(sb, "Map")
        case .Set:      strings.write_string(sb, "Set")
        case .Weak_Map: strings.write_string(sb, "WeakMap")
        case .Weak_Set: strings.write_string(sb, "WeakSet")
        }
        strings.write_byte(sb, '(')
        write_number(sb, f64(len(x.entries)))
        strings.write_byte(sb, ')')
    case ^Symbol:
        strings.write_string(sb, "Symbol(")
        strings.write_string(sb, x.desc)
        strings.write_byte(sb, ')')
    case ^BigInt:
        s := bigint_to_string(x) // dígitos decimais, SEM o sufixo 'n' (como String(1n))
        strings.write_string(sb, s)
        delete(s)
    case:
        strings.write_string(sb, "undefined")
    }
}

// Uma chave-string derivada de um Symbol (via key_string→to_text) tem a forma
// "Symbol(...)". Chaves-símbolo não devem ser enumeradas por for-in / Object.keys.
is_symbol_key :: proc(k: string) -> bool {
    return strings.has_prefix(k, "Symbol(")
}

// Nome privado de classe (#x): a chave começa com '#'. Nunca enumera (for-in,
// Object.keys/values/entries, JSON.stringify) — é "privado". O lexer emite o '#'
// no texto do Ident; nenhuma chave de usuário normal começa com '#'.
is_private_key :: proc(k: string) -> bool {
    return len(k) > 0 && k[0] == '#'
}

// Chave interna que não deve enumerar: símbolo OU campo privado.
is_non_enumerable_key :: proc(k: string) -> bool {
    return is_symbol_key(k) || is_private_key(k)
}

// Converte um Value para uma string usável como chave de objeto.
// Se precisar alocar (chave numérica), registra para liberação no fim.
key_string :: proc(vm: ^Interp, v: Value) -> string {
    if s, ok := v.(string); ok do return s
    // Symbol tem chave PRÓPRIA, única por símbolo e cacheada (ver symbol_key). O
    // caminho genérico abaixo usaria to_text, que dá só "Symbol(desc)" — e aí dois
    // símbolos homônimos indexariam a MESMA propriedade.
    if sym, ok := v.(^Symbol); ok do return symbol_key(vm, sym)
    sb: strings.Builder
    strings.builder_init(&sb)
    to_text(&sb, v)
    s := strings.clone(strings.to_string(sb))
    strings.builder_destroy(&sb)
    append(&vm.owned_strings, s)
    return s
}

CONSOLE_LOG_MAX :: 2048 // teto de linhas retidas p/ o painel DevTools (ring)

Console_Level :: enum u8 { Log, Warn, Error, Input, Result } // Input/Result = eco/retorno do REPL
Console_Entry  :: struct { level: Console_Level, text: string } // text clonada (posse do vm)

// Formata os args de console.* numa linha só (mesma regra visual do console dos
// navegadores). Devolve string CLONADA (posse do chamador).
@(private = "file")
console_format :: proc(args: []Value) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for a, i in args {
        if i > 0 do strings.write_byte(&sb, ' ')
        to_text(&sb, a)
    }
    return strings.clone(strings.to_string(sb))
}

// Guarda a linha no buffer do painel DevTools. Ring: ao passar do teto, descarta o
// bloco mais antigo (libera as strings) — um setInterval que loga não cresce sem fim.
@(private = "file")
console_capture :: proc(vm: ^Interp, level: Console_Level, text: string) {
    if len(vm.console_buf) >= CONSOLE_LOG_MAX {
        drop := CONSOLE_LOG_MAX / 4
        for i in 0 ..< drop do delete(vm.console_buf[i].text)
        remove_range(&vm.console_buf, 0, drop)
    }
    append(&vm.console_buf, Console_Entry{level, text})
}

// Limpa o buffer do console (botão "Limpar" do painel DevTools). Libera as strings.
vm_console_clear :: proc(vm: ^Interp) {
    for e in vm.console_buf do delete(e.text)
    clear(&vm.console_buf)
}

// REPL do DevTools: avalia `src` no escopo GLOBAL do vm — compartilha as globais da
// página (document, window, variáveis e funções já definidas pelos scripts), então
// dá pra inspecionar/mexer no estado vivo. Registra no console o eco da entrada e o
// resultado (ou o erro). Não envenena o vm: reseta os sinais de exceção/controle.
vm_repl_eval :: proc(vm: ^Interp, src: string) {
    console_capture(vm, .Input, strings.clone(src))

    v := vm_exec(vm, src)          // escopo global (env=nil), devolve o valor de conclusão
    // microtasks (Promise.then) já drenam no settle via kick_drain; timers de
    // setTimeout disparam nos frames seguintes pelo vm_pump_timers normal.
    vm.returning = false; vm.breaking = false; vm.continuing = false

    if vm.throwing {
        console_capture(vm, .Error, repl_format(vm.thrown))
        vm.throwing = false
        vm.thrown = nil
    } else {
        console_capture(vm, .Result, repl_format(v))
    }
    vm_clear_uncaught(vm)
}

@(private = "file")
repl_format :: proc(v: Value) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, v)
    return strings.clone(strings.to_string(sb))
}

@(private = "file")
native_log :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := console_format(args)
    fmt.println(s)               // mantém a saída no stdout (--diagnose / terminal)
    console_capture(vm, .Log, s) // e no painel DevTools
    return nil
}

// console.error/warn escrevem em stderr com prefixo (visíveis no --diagnose, onde
// o relatório também vai p/ stderr). CRÍTICO: React reporta erros de render via
// console.error; sem isto, um erro vira árvore vazia SEM sinal.
@(private = "file")
native_error :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := console_format(args)
    fmt.eprintfln("[console.error] %s", s)
    when #config(MEMBERPROBE, false) {
        fmt.eprintfln("[errprobe] pilha: %v", vm.probe_stack)
    }
    console_capture(vm, .Error, s)
    return nil
}

@(private = "file")
native_warn :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := console_format(args)
    fmt.eprintfln("[console.warn] %s", s)
    console_capture(vm, .Warn, s)
    return nil
}

@(private = "file")
native_noop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return nil
}

// ── Function.prototype.call / apply / bind ──────────────────────────────────
// O alvo é o `this` da chamada (fn.call(...) → this = fn). Ubíquos em bundles;
// React agenda callbacks via `work.bind(null, root)` — sem bind, o callback vira
// undefined e o scheduler roda em falso (loop infinito / árvore vazia).

@(private = "file")
native_fn_call :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target, ok := this.(^Function); if !ok do return nil
    new_this := args[0] if len(args) >= 1 else nil
    rest := args[1:] if len(args) >= 1 else args
    return call_function(vm, target, new_this, rest)
}

@(private = "file")
native_fn_apply :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target, ok := this.(^Function); if !ok do return nil
    new_this := args[0] if len(args) >= 1 else nil
    call_args: []Value
    copied := false
    if len(args) >= 2 {
        if arr, aok := args[1].(^Array); aok {
            // CÓPIA, não alias de arr.items: um default de parâmetro (JS arbitrário
            // no setup_call_scope) pode dar push no MESMO array → realoc → slice morto.
            // Todos os outros caminhos de chamada já copiam (eval_args).
            call_args = make([]Value, len(arr.items))
            copy(call_args, arr.items[:])
            copied = true
        }
    }
    defer if copied do delete(call_args)
    return call_function(vm, target, new_this, call_args)
}

// Function.prototype.toString — APROXIMAÇÃO: sempre a forma "[native code]"
// (não guardamos o fonte das funções; suficiente p/ detecção de nativas).
@(private = "file")
native_fn_tostring :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name := ""
    if f, ok := this.(^Function); ok do name = f.name
    // CONCATENAR, não tprintf: o fmt do Odin trata `{`/`}` como diretiva, então
    // "function %s() { [native code] }" saía como
    // "function foo() %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)[native code] }".
    // Toda `fn.toString()` vinha corrompida — e é string que libs inspecionam
    // (`/\[native code\]/.test(fn.toString())` é feature-detect clássico).
    return own_str(vm, strings.concatenate(
        {"function ", name, "() { [native code] }"}, context.temp_allocator))
}

@(private = "file")
native_fn_bind :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    target, ok := this.(^Function); if !ok do return nil
    bf := new_function(vm)
    bf.bind_target = target
    bf.bind_this = args[0] if len(args) >= 1 else nil
    bf.name = target.name
    if len(args) > 1 {
        bf.bind_args = make([dynamic]Value, 0, len(args) - 1)
        for i := 1; i < len(args); i += 1 do append(&bf.bind_args, args[i])
    }
    return bf
}

// package-visível: bigint.odin também concatena (BigInt + string).
concat :: proc(vm: ^Interp, a, b: Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    write_text_spec(&sb, vm, a) // ToString da spec: respeita toString/@@toPrimitive
    write_text_spec(&sb, vm, b)
    s := strings.clone(strings.to_string(sb))
    strings.builder_destroy(&sb)
    append(&vm.owned_strings, s)
    return s
}

@(private = "file")
// Igualdade frouxa (==) — IsLooselyEqual da spec (§7.2.15).
//
// Duas armadilhas históricas moram aqui. A versão MAIS antiga fazia
// `as_number(a)==as_number(b)` p/ tudo que não fosse string, o que dava
// `objeto == null` == true (ambos viram 0) — e como React faz `x != null` em TODO
// lugar, o reconciler colapsava (árvore vazia). A correção disso jogou para o outro
// extremo: objeto vs primitivo devolvia SEMPRE false, então `[1] == "1"`, `[] == false`
// e `{toString(){...}} == "x"` divergiam do JS real. Agora o lado OBJETO passa por
// ToPrimitive e a comparação é refeita, que é literalmente o que a spec manda.
loose_eq :: proc(vm: ^Interp, a, b: Value) -> bool {
    a, b := a, b
    // null/undefined só se igualam entre si (nunca a objeto/0/"") — o caso do React
    an := is_nullish(a); bn := is_nullish(b)
    if an || bn do return an && bn

    // `is_primitive` trata Symbol/BigInt como primitivos (é o que a spec faz):
    // só objeto/array/função/regex/coleção têm ToPrimitive.
    ao := !is_primitive(a); bo := !is_primitive(b)
    if ao && bo do return a == b // objeto vs objeto: identidade (mesmo Type ⇒ ===)
    if ao || bo {
        // Objeto vs primitivo: coage o lado objeto e RECOMPARA. O hint é "default"
        // (que se comporta como number), exceto para Date, cujo @@toPrimitive default
        // é string — mesma regra que o `+` já aplica em binop.
        if ao {
            a = to_primitive(vm, a, !is_date_object(vm, a), "default")
        } else {
            b = to_primitive(vm, b, !is_date_object(vm, b), "default")
        }
        if vm.throwing do return false
        // O nosso to_primitive tem um fallback que devolve texto de debug p/ Regex/
        // Collection em vez de lançar; se ainda assim sobrou um objeto, desiste em
        // vez de recursar (a recursão abaixo é de UM nível por construção).
        if !is_primitive(a) || !is_primitive(b) do return false
        return loose_eq(vm, a, b)
    }

    // daqui em diante os DOIS são primitivos.
    // Symbol nunca coage: só é igual ao mesmo símbolo (identidade de ponteiro).
    _, asym := a.(^Symbol)
    _, bsym := b.(^Symbol)
    if asym || bsym do return a == b

    as, aok := a.(string); bs, bok := b.(string)
    if aok && bok do return as == bs

    // number / bool / string↔number: compara coagindo p/ número (1==true, "1"==1, ""==0)
    return as_number(a) == as_number(b)
}

// Tipo por referência (comparado por identidade, não por valor coagido).
// package-visível: bigint.odin usa em == (BigInt vs objeto → false).
is_ref_type :: proc(v: Value) -> bool {
    #partial switch _ in v {
    case ^Object, ^Array, ^Function, ^Regex, ^Collection, ^Symbol:
        return true
    }
    return false
}

// É uma instância de Date? (o @@toPrimitive default de Date é STRING, não number —
// por isso `data + ""` dá a data por extenso e não o timestamp.)
@(private = "file")
is_date_object :: proc(vm: ^Interp, v: Value) -> bool {
    o, ok := v.(^Object)
    return ok && vm.date_proto != nil && o.proto == vm.date_proto
}

// Aplica um operador binário a dois valores. Reusado por Binary, pelos
// compostos (+=, -=, ...) e por ++/--.
@(private = "file")
binop :: proc(vm: ^Interp, op: Token_Kind, l, r: Value) -> Value {
    // BigInt: se algum operando é BigInt, semântica própria (mistura com Number em
    // aritmética lança; ===/== e relacionais tratam mistura). Exceto que instanceof/
    // in não têm sentido especial p/ BigInt — caem no caminho comum abaixo.
    if op != .Instanceof && op != .In {
        _, lb := l.(^BigInt)
        _, rb := r.(^BigInt)
        if lb || rb do return bigint_binop(vm, op, l, r)
    }
    // ToPrimitive dos operandos (spec §13.15/§13.10): objeto vira primitivo ANTES da
    // operação, invocando @@toPrimitive/valueOf/toString. Sem isto `dataB - dataA` era
    // NaN, `data1 < data2` era false e `"x" + [1,2]` virava "x[1, 2]".
    // O caminho QUENTE é preservado: `is_primitive` de f64/string/bool sai no 1º switch,
    // e o bloco inteiro é pulado quando os dois lados já são primitivos (o caso normal).
    l, r := l, r
    if !is_primitive(l) || !is_primitive(r) {
        #partial switch op {
        case .Plus, .Minus, .Star, .StarStar, .Slash, .Percent, .Lt, .Gt, .LtEq, .GtEq:
            // `+` usa o hint DEFAULT, que se comporta como number — exceto para Date,
            // cujo @@toPrimitive default é string (`data + ""` dá a data por extenso).
            hint_num := op != .Plus || !is_date_object(vm, l) && !is_date_object(vm, r)
            hname := op == .Plus ? "default" : "" // `+` passa "default" ao @@toPrimitive
            l = to_primitive(vm, l, hint_num, hname)
            if vm.throwing do return nil
            r = to_primitive(vm, r, hint_num, hname)
            if vm.throwing do return nil
        }
    }
    #partial switch op {
    case .Plus:
        if is_string(l) || is_string(r) do return concat(vm, l, r)
        return as_number(l) + as_number(r)
    case .Minus: return as_number(l) - as_number(r)
    case .Star:  return as_number(l) * as_number(r)
    case .StarStar: return math.pow(as_number(l), as_number(r))
    case .Slash: return as_number(l) / as_number(r)
    case .Percent:
        a := as_number(l); b := as_number(r)
        return a - b * math.trunc(a / b) // resto no estilo JS (sinal do dividendo)
    case .EqEq:  return loose_eq(vm, l, r)
    case .NotEq: return !loose_eq(vm, l, r)
    // igualdade estrita: a union Value já compara variante+valor (tipo importa)
    case .EqEqEq:  return l == r
    case .NotEqEq: return l != r
    // relacionais: DUAS strings comparam lexicograficamente (spec: por code
    // units — byte a byte em UTF-8 dá a mesma ordem p/ quase tudo); senão, numérico.
    // 'b' > 'a', '2024-06' < '2024-07' (datas ISO) etc.
    case .Lt:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return ls < rs }
        return as_number(l) <  as_number(r)
    case .Gt:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return ls > rs }
        return as_number(l) >  as_number(r)
    case .LtEq:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return ls <= rs }
        return as_number(l) <= as_number(r)
    case .GtEq:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return ls >= rs }
        return as_number(l) >= as_number(r)
    case .Instanceof: return js_instanceof(vm, l, r)
    case .In: return js_in(vm, l, r)
    // bitwise: operam sobre inteiros de 32 bits (ToInt32/ToUint32), como no JS.
    case .Amp:   return f64(to_int32(l) & to_int32(r))
    case .Pipe:  return f64(to_int32(l) | to_int32(r))
    case .Caret: return f64(to_int32(l) ~ to_int32(r))
    case .Shl:   return f64(to_int32(l) << (to_uint32(r) & 31))
    case .Shr:   return f64(to_int32(l) >> (to_uint32(r) & 31))          // aritmético (preserva sinal)
    case .UShr:  return f64(to_uint32(l) >> (to_uint32(r) & 31))         // lógico (zero-fill), resultado unsigned
    }
    return nil
}

// ToUint32 (spec ES): NaN/±Inf → 0; senão trunca p/ zero e reduz módulo 2^32.
to_uint32 :: proc(v: Value) -> u32 {
    n := as_number(v)
    if n != n do return 0 // NaN
    if n == math.INF_F64 || n == math.NEG_INF_F64 do return 0
    t := math.trunc(n)
    two32 :: 4294967296.0 // 2^32
    m := t - math.floor(t / two32) * two32 // módulo positivo em [0, 2^32)
    return u32(m)
}

// ToInt32: mesmos bits do ToUint32 reinterpretados como signed 32-bit.
to_int32 :: proc(v: Value) -> i32 {
    return i32(to_uint32(v))
}

// `l in r`: true se a chave `l` existe em `r` (objeto: props próprias + cadeia de
// proto e accessors; array: índice válido ou "length"). Não-objeto → false (JS
// lançaria TypeError; leniência aqui evita envenenar bundles que nunca acertam isso).
// package-visible: Reflect.has / proxy `has` (proxy.odin) reusam.
// Brand check `#key in obj`: obj tem o slot privado? Só ^Object; varre próprias +
// cadeia de proto (campos privados são own; métodos privados vivem no proto). NÃO
// invoca traps de proxy (estado privado ignora o Proxy, como na spec) e não lança.
private_in :: proc(key: string, r: Value) -> bool {
    o, ok := r.(^Object)
    if !ok do return false
    for cur := o; cur != nil; cur = cur.proto {
        if _, ok := cur.props[key]; ok do return true
        if cur.getters != nil { if _, ok := cur.getters[key]; ok do return true }
        if cur.setters != nil { if _, ok := cur.setters[key]; ok do return true }
    }
    return false
}

js_in :: proc(vm: ^Interp, l, r: Value) -> bool {
    key := key_string(vm, l)
    #partial switch o in r {
    case ^Object:
        if o.px_handler != nil do return proxy_has(vm, o, key) // trap `has` (ou default no alvo)
        for cur := o; cur != nil; cur = cur.proto {
            if _, ok := cur.props[key]; ok do return true
            if cur.getters != nil { if _, ok := cur.getters[key]; ok do return true }
            if cur.setters != nil { if _, ok := cur.setters[key]; ok do return true }
        }
        // Hook nativo (DOM/window/storage): as propriedades servidas por ele NÃO
        // vivem em props, então `'content' in template` e todo feature-detect no
        // mesmo estilo davam false — e bibliotecas baixavam polyfill por cima do
        // nosso nativo (webcomponentsjs). O hook é a fonte da verdade dessas props.
        if o.get != nil {
            if _, handled := o.get(vm, o, key); handled do return true
        }
        // protótipo EXÓTICO no fim da cadeia (Object.create(array)) — `in` é
        // HasProperty, que sobe a cadeia inteira.
        if x := proto_exotic_end(o); x != nil do return js_in(vm, l, x)
        return false
    case ^Array:
        if idx, ok := strconv.parse_int(key); ok do return idx >= 0 && idx < len(o.items)
        if o.props != nil { if _, ok := o.props[key]; ok do return true }
        if key == "length" do return true
        // HasProperty sobe até Array.prototype/Object.prototype: `"slice" in []` é TRUE
        // no JS (era false aqui). Um polyfill que testa assim instalava por cima do
        // nosso método nativo.
        if _, ok := vm.array_methods[key];  ok do return true
        if _, ok := vm.object_methods[key]; ok do return true
        return false
    }
    return false
}

// `l instanceof r`: coleções nativas casam pelo nome do construtor; classes de
// usuário procuram r.prototype na cadeia de protótipo de l.
@(private = "file")
js_instanceof :: proc(vm: ^Interp, l, r: Value) -> bool {
    // `r[Symbol.hasInstance]` tem precedência sobre TUDO (spec §13.10.2): é o
    // gancho com que uma lib define a própria noção de "é instância de". Vem antes
    // do early-return de ^Function porque o lado direito pode ser um objeto comum
    // que só implementa o símbolo.
    if vm.sym_has_instance_key != "" && !is_primitive(r) {
        if fn, fok := get_member(vm, r, vm.sym_has_instance_key).(^Function); fok {
            res := call_function(vm, fn, r, []Value{l})
            if vm.throwing do return false
            return truthy(res)
        }
    }
    rf, ok := r.(^Function)
    if !ok do return false
    if coll, cok := l.(^Collection); cok {
        switch rf.name {
        case "Map":     return coll.kind == .Map
        case "Set":     return coll.kind == .Set
        case "WeakMap": return coll.kind == .Weak_Map
        case "WeakSet": return coll.kind == .Weak_Set
        }
        return false
    }
    // Valores que NÃO são ^Object não têm cadeia de proto no nosso modelo (array,
    // função e regex são variantes próprias da union), então o laço abaixo os
    // reprovava sempre: `[] instanceof Array` — idioma comuníssimo — dava FALSE.
    // Casam pelo construtor correspondente, como as coleções logo acima.
    #partial switch lv in l {
    case ^Array:
        if vm.array_ctor != nil && rf == vm.array_ctor do return true
        return rf.name == "Array" || rf.name == "Object"
    case ^Function:
        return rf.name == "Function" || rf.name == "Object"
    case ^Regex:
        return rf.name == "RegExp" || rf.name == "Object"
    }
    proto, pok := rf.props["prototype"].(^Object)
    if !pok do return false
    o, ook := l.(^Object)
    if !ook do return false
    for cur := o.proto; cur != nil; cur = cur.proto {
        if cur == proto do return true
    }
    // cadeia terminando num protótipo EXÓTICO: `Object.create([]) instanceof Array`
    // resolve pelo caso ^Array acima.
    if x := proto_exotic_end(o); x != nil do return js_instanceof(vm, x, r)
    return false
}

// ── acesso a propriedades ───────────────────────────────────────────────────

// Chaves PRÓPRIAS enumeráveis (string, não-símbolo) de um objeto: props + getters,
// pulando as marcadas não-enumeráveis (Object.defineProperty enumerable:false).
// Base de Object.keys/values/entries e do for-in. Dedup entre props e getters.
// Visível no pacote (object.odin também usa).
// Escrita de data-prop que REGISTRA a ordem de inserção (consumida por
// own_enum_keys). Todo caminho de escrita visível ao JS deve usar isto;
// escritas nativas diretas em o.props continuam válidas — só enumeram
// depois das ordenadas, em ordem de map.
// ── atributos de propriedade ────────────────────────────────────────────────

// Atributos de `key`: o default quando a chave não está no mapa (ver Prop_Attrs).
prop_attrs :: proc(o: ^Object, key: string) -> Prop_Attrs {
    if o.attrs == nil do return ATTRS_DEFAULT
    if a, ok := o.attrs[key]; ok do return a
    return ATTRS_DEFAULT
}

// Grava os atributos de `key`. Só materializa o mapa quando algo difere do default.
set_prop_attrs :: proc(o: ^Object, key: string, a: Prop_Attrs) {
    if a == ATTRS_DEFAULT {
        if o.attrs != nil do delete_key(&o.attrs, key)
        return
    }
    if o.attrs == nil do o.attrs = make(map[string]Prop_Attrs)
    o.attrs[key] = a
}

// `key` não aparece em Object.keys/for-in/JSON. É o que o antigo mapa `hidden` fazia,
// e o que o motor precisa ao instalar métodos em prototypes (`Object.keys(X.prototype)`
// tem de vir vazio, como no navegador).
mark_non_enumerable :: proc(o: ^Object, key: string) {
    set_prop_attrs(o, key, prop_attrs(o, key) - {.Enumerable})
}

// A propriedade PRÓPRIA `key` aceita escrita? Prop inexistente é regida pela
// extensibilidade do objeto, não por writable.
@(private = "file")
prop_writable :: proc(o: ^Object, key: string) -> bool {
    if _, exists := o.props[key]; !exists do return !o.non_extensible
    return .Writable in prop_attrs(o, key)
}

oput :: proc(o: ^Object, k: string, v: Value) {
    if _, exists := o.props[k]; !exists do append(&o.korder, k)
    o.props[k] = v
}

// Remove uma data-prop mantendo korder coerente (re-inserir depois de deletar
// deve ir p/ o FIM da ordem, como na spec).
oremove :: proc(o: ^Object, k: string) {
    if _, exists := o.props[k]; exists {
        for kk, i in o.korder do if kk == k { ordered_remove(&o.korder, i); break }
    }
    delete_key(&o.props, k)
}

// Chave que conta como "índice de array" p/ a ordem de enumeração da spec:
// inteiro canônico sem zero à esquerda ("0", "7", "42" — não "07", "1.5", "-1").
@(private = "file")
is_index_key :: proc(k: string) -> bool {
    if len(k) == 0 || len(k) > 10 do return false
    if len(k) > 1 && k[0] == '0' do return false
    for c in transmute([]u8)k do if c < '0' || c > '9' do return false
    return true
}

// Chaves próprias enumeráveis na ordem da spec (OrdinaryOwnPropertyKeys):
// índices inteiros em ordem numérica crescente, depois as demais strings na
// ordem de inserção (korder), depois sobras de escritas nativas diretas.
own_enum_keys :: proc(o: ^Object, out: ^[dynamic]string) {
    // Proxy: enumera as chaves do ALVO (aproximação do trap ownKeys — devolve o
    // conjunto certo p/ Object.keys/for-in; os VALORES ainda passam pelo trap get
    // porque obj_values/for-in leem via get_member(proxy,k)). O efeito colateral
    // de rastreio do ownKeys do Vue é pulado — ok p/ a 1ª renderização.
    if o.px_handler != nil {
        if t, ok := o.px_target.(^Object); ok do own_enum_keys(t, out)
        return
    }
    if o.get == storage_get { // localStorage/sessionStorage: só as chaves armazenadas, em ordem
        st := cast(^Storage) o.host
        for k in st.keys do append(out, k)
        return
    }
    emit :: proc(o: ^Object, k: string, seen: ^map[string]bool, out: ^[dynamic]string) {
        if is_non_enumerable_key(k) do return // símbolo ou campo privado #x
        if o.attrs != nil && .Enumerable not_in prop_attrs(o, k) do return
        if seen[k] do return
        seen[k] = true
        append(out, k)
    }
    seen: map[string]bool
    defer delete(seen)
    // 1) chaves-índice, crescente (insertion sort: quase sempre pouquíssimas)
    idx_keys: [dynamic]string
    defer delete(idx_keys)
    for k in o.props do if is_index_key(k) do append(&idx_keys, k)
    // inteiro canônico menor = string mais curta, ou mesma largura e menor lexicográfico
    idx_less :: proc(a, b: string) -> bool {
        if len(a) != len(b) do return len(a) < len(b)
        return a < b
    }
    for i := 1; i < len(idx_keys); i += 1 {
        for j := i; j > 0 && idx_less(idx_keys[j], idx_keys[j-1]); j -= 1 {
            idx_keys[j], idx_keys[j-1] = idx_keys[j-1], idx_keys[j]
        }
    }
    for k in idx_keys do emit(o, k, &seen, out)
    // 2) ordem de inserção registrada (pula entradas obsoletas de deletes)
    for k in o.korder {
        if _, alive := o.props[k]; alive && !is_index_key(k) do emit(o, k, &seen, out)
    }
    // 3) sobras (escritas nativas que não passaram por oput) + getters
    for k in o.props do emit(o, k, &seen, out)
    if o.getters != nil do for k in o.getters do emit(o, k, &seen, out)
}

// O construtor GLOBAL de um tipo, por nome ("String", "Number", …). `.constructor`
// faltava em praticamente tudo (só Array tinha): `"x".constructor`, `(1).constructor`,
// `({}).constructor`, `/a/.constructor`, `new Map().constructor` — todos undefined.
// É idioma básico de introspecção (`x.constructor === Object`, `x.constructor.name`,
// `entity.constructor.toString()` — este último quebrava 6 portais no corpus).
@(private = "file")
global_ctor :: proc(vm: ^Interp, name: string) -> Value {
    if v, ok := env_get(vm.global, name); ok {
        if f, fok := v.(^Function); fok do return f
    }
    return nil
}

// Último elo da cadeia de protótipos quando ele NÃO é um ^Object (ver Object.proto_x):
// `Object.create(array)` põe o array aqui. nil = cadeia termina em ^Object/nada, que é
// o caso de quase todo objeto — o laço morre no 1º elo sem proto.
// Visível no pacote (object.odin usa em getPrototypeOf/isPrototypeOf).
proto_exotic_end :: proc(o: ^Object) -> Value {
    for cur := o; cur != nil; cur = cur.proto {
        if cur.proto == nil do return cur.proto_x
    }
    return nil
}

// Um nome de propriedade é um ÍNDICE canônico de array? ("0","7" sim; "01","1.0",
// "0x1"," 1","-1" não). Estrito de propósito: no JS `a["01"]` é uma prop comum, não
// o item 1 — e `strconv.parse_int` sozinho aceitaria hexadecimal e sinal.
@(private = "file")
array_index_name :: proc(name: string) -> (idx: int, ok: bool) {
    if len(name) == 0 || len(name) > 10 do return 0, false
    if name[0] == '0' && len(name) > 1 do return 0, false // "01" não é canônico
    n := 0
    for c in transmute([]u8)name {
        if c < '0' || c > '9' do return 0, false
        n = n * 10 + int(c - '0')
    }
    return n, true
}

// Visível no pacote (object.odin invoca getters ao ler values/entries/assign).
get_member :: proc(vm: ^Interp, obj: Value, name: string) -> Value {
    when JSPROF { g_prof.get_member += 1 }
    if is_nullish(obj) { // null.x / undefined.x → TypeError (spec)
        throw_type_error(vm, fmt.tprintf("Cannot read properties of %s (reading '%s')",
            obj == nil ? "undefined" : "null", name))
        return nil
    }
    #partial switch o in obj {
    case ^Object:
        if o.get != nil {
            if v, handled := o.get(vm, o, name); handled do return v
        }
        // cadeia de protótipo NÍVEL a NÍVEL — o nível mais próximo vence: uma
        // data property própria sombreia um getter herdado (class B extends A
        // { x = 5 } lê o 5, não o get x() de A). No mesmo nível o getter tem
        // prioridade ({get x(){...}} de object literal / accessor de classe).
        for cur := o; cur != nil; cur = cur.proto {
            if cur.getters != nil {
                if g, ok := cur.getters[name]; ok do return call_function(vm, g, o, nil)
            }
            if v, ok := cur.props[name]; ok do return v
        }
        // protótipo EXÓTICO no fim da cadeia (Object.create(array)): a busca CONTINUA
        // nele. Só no caminho de MISS — o laço acima segue sem custo nenhum.
        if x := proto_exotic_end(o); x != nil {
            if v := get_member(vm, x, name); v != nil do return v
        }
        // subclasse de builtin (M136): o que a cadeia da subclasse não define cai no
        // builtin embrulhado — é de lá que vêm `size`, `length` e os métodos.
        if o.prim != nil {
            if v := get_member(vm, o.prim, name); v != nil do return v
        }
        // sonda: prop pedida de um wrapper de nó DOM que NINGUÉM serve
        when #config(MEMBERPROBE, false) {
            if o.host != nil && name != "constructor" {
                if _, isobj := vm.object_methods[name]; !isobj {
                    fmt.eprintfln("[domgap] .%s", name)
                }
            }
        }
        // métodos comuns a todo objeto (hasOwnProperty, ...) sem exigir proto
        if fn, ok := vm.object_methods[name]; ok do return fn
        // `({}).constructor === Object`. Só chega aqui se NADA na cadeia definiu
        // `constructor` — uma instância de classe pega o da sua prototype acima.
        if name == "constructor" do return global_ctor(vm, "Object")
        return nil
    case ^Array:
        if name == "length" do return f64(len(o.items))
        // `[].__proto__`: array é variante própria da union e NÃO percorre os
        // getters de Object.prototype (cai no mapa PLANO object_methods lá
        // embaixo), então o acessor instalado lá não o alcança. Mesma fonte que
        // `Object.getPrototypeOf` para os dois não divergirem.
        if name == "__proto__" do return obj_get_prototype_of(vm, nil, []Value{o})
        // Índice em forma de NOME. O acesso normal `a[0]` entra por get_index (chave
        // numérica) e nunca passa por aqui; quem chega assim é a delegação de um objeto
        // cujo protótipo é este array (Object.create(arr) → `o[0]`/array_like_get, que
        // resolvem por NOME) — sem isto o objeto herdava os métodos mas nenhum item.
        if len(name) > 0 && name[0] >= '0' && name[0] <= '9' {
            if idx, iok := array_index_name(name); iok {
                if idx < len(o.items) do return o.items[idx]
                return nil
            }
        }
        if o.props != nil { // props não-índice (exec.index, strings.raw)
            if v, ok := o.props[name]; ok do return v
        }
        if fn, ok := vm.array_methods[name]; ok do return fn
        if name == "constructor" do return vm.array_ctor // `[].constructor === Array`
        // Array herda de Object.prototype: hasOwnProperty/isPrototypeOf/toLocaleString.
        // Faltava só aqui (^Object e ^Function já tinham o fallback) — `arr.hasOwnProperty(i)`
        // lançava "is not a function". O Lit chama exatamente isso ao finalizar uma
        // classe de componente, e a exceção sumia numa rejeição não tratada.
        if fn, ok := vm.object_methods[name]; ok do return fn
        return nil
    case ^Collection:
        if name == "size" do return f64(len(o.entries))
        if fn, ok := vm.collection_methods[name]; ok do return fn
        if name == "constructor" {
            switch o.kind {
            case .Map:      return global_ctor(vm, "Map")
            case .Set:      return global_ctor(vm, "Set")
            case .Weak_Map: return global_ctor(vm, "WeakMap")
            case .Weak_Set: return global_ctor(vm, "WeakSet")
            }
        }
        if fn, ok := vm.object_methods[name]; ok do return fn // idem p/ Map/Set
        return nil
    case ^Symbol:
        if name == "description" do return own_str(vm, o.desc)
        if name == "constructor" do return global_ctor(vm, "Symbol")
        // resto (toString/valueOf/[Symbol.toPrimitive]) vem do %SymbolPrototype% —
        // mesmo objeto que `Symbol.prototype` expõe, para não haver duas cópias (M220)
        if vm.symbol_proto != nil {
            if v, ok := vm.symbol_proto.props[name]; ok do return v
        }
        return nil
    case string:
        if name == "length" do return f64(str_rlen(o)) // CODE POINTS ('café'.length = 4)
        if fn, ok := vm.string_methods[name]; ok do return fn
        if name == "constructor" do return global_ctor(vm, "String")
        return nil
    case f64:
        // (3.14).toFixed(2), (255).toString(16), ... — this = o próprio número
        if fn, ok := vm.number_methods[name]; ok do return fn
        if name == "constructor" do return global_ctor(vm, "Number")
        return nil
    case bool:
        // true.toString() / valueOf: o boxing de booleano não tinha NENHUM método
        // (`true.toString()` lançava "is not a function"). Os transpiladores usam
        // `Boolean.prototype.valueOf.call(...)` no feature-detect de Reflect.construct
        // (helper _createSuper do Babel) — sem isto o detect falha e o bundle cai
        // no caminho degradado. Ver install_boolean_proto.
        if fn, ok := vm.boolean_methods[name]; ok do return fn
        if name == "constructor" do return global_ctor(vm, "Boolean")
        if fn, ok := vm.object_methods[name]; ok do return fn
        return nil
    case ^Function:
        // `fn.__proto__` — mesma razão do ^Array acima: função não anda pelos
        // getters de Object.prototype. Para classe derivada isto devolve a
        // SUPERCLASSE, que é o que o `_getPrototypeOf(Derived)` do Babel quer.
        // ⚠️ antes do lookup de props: uma função pode ter prop estática de
        // qualquer nome, e `__proto__` não pode virar prop comum.
        if name == "__proto__" do return obj_get_prototype_of(vm, nil, []Value{o})
        // getter static de classe (static get x(){}) — invoca com this = a classe
        if o.getters != nil {
            if g, ok := o.getters[name]; ok do return call_function(vm, g, o, nil)
        }
        if o.props != nil { // propriedades estáticas (ex.: Promise.resolve)
            if v, ok := o.props[name]; ok do return v
        }
        // HERANÇA ESTÁTICA: `class B extends A` faz B herdar os membros static de A
        // (spec: o [[Prototype]] de B é A). Sem subir a cadeia, `B.metodoStatic` era
        // undefined — e `super.metodoStatic()` dentro de um static também. Só props
        // e getters; call/apply/bind/prototype abaixo são de cada função.
        for sup := o.super_ctor; sup != nil; sup = sup.super_ctor {
            if sup.getters != nil {
                if g, ok := sup.getters[name]; ok do return call_function(vm, g, o, nil)
            }
            if sup.props != nil {
                if v, ok := sup.props[name]; ok && name != "prototype" do return v
            }
        }
        // call / apply / bind — comuns a toda função
        switch name {
        case "call":  return vm.fn_call_fn
        case "toString": return vm.fn_tostring_fn
        case "apply": return vm.fn_apply_fn
        case "bind":  return vm.fn_bind_fn
        case "name":  return o.name
        case "length": return f64(len(o.params))
        }
        // toda função (não-arrow) tem um `.prototype` (objeto) criado sob demanda —
        // é onde `Ctor.prototype.metodo = fn` grava e de onde `new Ctor()` herda.
        // Sem isto, construtores-função (ex.: ReactDOMRoot) perdem seus métodos.
        // EXCEÇÃO: bound functions (`.bind()`) NÃO têm `.prototype` (spec: "exotic
        // bound function objects" não recebem a prop prototype). O core-js detecta
        // bind nativo via `!boundFn.hasOwnProperty('prototype')` — se o auto-proto
        // aparecer, NATIVE_BIND=false e o core-js embrulha Map/Set e usa caminhos
        // uncurryThis alternativos (foi a raiz do bug do M97). Ver obj_has_own_property.
        if name == "prototype" && !o.is_arrow && o.native == nil && o.bind_target == nil {
            if o.props == nil do o.props = make(map[string]Value)
            proto := new_object(vm)
            proto.props["constructor"] = o
            mark_non_enumerable(proto, "constructor")
            o.props["prototype"] = proto
            return proto
        }
        // funções herdam de Object.prototype (hasOwnProperty, isPrototypeOf, ...);
        // sem isto `algumaFn.hasOwnProperty(...)` lançava "is not a function".
        if name == "constructor" do return global_ctor(vm, "Function")
        if fn, ok := vm.object_methods[name]; ok do return fn
        return nil
    case ^Regex:
        switch name {
        case "source":     return o.source
        case "flags":      return o.flags
        case "global":     return o.global
        case "ignoreCase": return o.icase
        case "multiline":  return o.multiline
        case "dotAll":     return o.dotall
        case "sticky":     return o.sticky
        case "unicode":    return strings.contains(o.flags, "u")
        case "hasIndices": return strings.contains(o.flags, "d")
        case "lastIndex":  return f64(o.last_index)
        case "test":       return vm.regex_test_fn
        case "exec":       return vm.regex_exec_fn
        case "constructor": return global_ctor(vm, "RegExp")
        }
        if fn, ok := vm.object_methods[name]; ok do return fn
        return nil
    case ^BigInt:
        // métodos (toString/valueOf) vivem no BigInt.prototype
        if vm.bigint_proto != nil {
            if m, ok := vm.bigint_proto.props[name]; ok do return m
        }
        return nil
    }
    return nil
}

// Visível no pacote: object.odin (Object.assign) também usa.
set_member :: proc(vm: ^Interp, obj: Value, name: string, val: Value) {
    if is_nullish(obj) { // null.x = v → TypeError (spec)
        throw_type_error(vm, fmt.tprintf("Cannot set properties of %s (setting '%s')",
            obj == nil ? "undefined" : "null", name))
        return
    }
    #partial switch o in obj {
    case ^Object:
        if o.set != nil {
            if o.set(vm, o, name, val) do return
        }
        // setter na cadeia, NÍVEL a NÍVEL (espelho do get_member): uma data
        // property num nível mais próximo sombreia setter herdado — a escrita
        // vira own em vez de invocar o set de um ancestral.
        for cur := o; cur != nil; cur = cur.proto {
            if cur.setters != nil {
                if s, ok := cur.setters[name]; ok { call_function(vm, s, o, []Value{val}); return }
            }
            if _, ok := cur.props[name]; ok do break
        }
        // writable:false (ou prop nova em objeto não-extensível) — em sloppy mode a
        // escrita é IGNORADA em silêncio, que é o modo em que rodamos.
        if !prop_writable(o, name) do return
        oput(o, name, val)
    case ^Function:
        // setter static de classe (static set x(v){}) — invoca com this = a classe
        if o.setters != nil {
            if s, ok := o.setters[name]; ok { call_function(vm, s, o, []Value{val}); return }
        }
        // escrever propriedade estática numa função (ex.: Ctor.prop = x)
        if o.props == nil do o.props = make(map[string]Value)
        o.props[name] = val
    case ^Regex:
        if name == "lastIndex" do o.last_index = as_int(val) // p/ loops de exec global
    case ^Array:
        // prop não-índice num array (m.index custom, marcações de libs); índices
        // inteiros passam por set_index, "length" segue read-only (aproximação)
        if name == "length" do return
        if o.props == nil do o.props = make(map[string]Value)
        o.props[name] = val
    }
}

// package-visible: proxy.odin (default get/Reflect.get) reusa.
get_index :: proc(vm: ^Interp, obj: Value, key: Value) -> Value {
    when JSPROF { g_prof.get_index += 1 }
    #partial switch o in obj {
    case ^Array:
        // só chave numérica INTEIRA indexa items; "length"/métodos/"foo" caem
        // no get_member (antes, as_number("foo")→0 lia items[0] por engano)
        if n := as_number(key); n == n && math.trunc(n) == n {
            idx := int(n)
            if idx >= 0 && idx < len(o.items) do return o.items[idx]
            return nil // fora do range: undefined
        }
        return get_member(vm, obj, key_string(vm, key))
    case ^Object:
        // coleção host (HTMLCollection/NodeList): índice inteiro resolvido SEM
        // materializar o nome — ver Prop_Get_Idx.
        // Só chave NUMÉRICA de verdade: uma chave string tem de seguir pelo nome, senão
        // `coll["01"]` viraria o item 1 (as_number("01") = 1) quando no JS "01" é uma
        // propriedade comum — quem decide o que é índice canônico é o hook por nome.
        // O teto de 2^31 é só para o `int(n)` não estourar (em Odin o overflow de
        // f64→int é UB); acima dele cai no caminho por nome, que devolve undefined —
        // que é a resposta certa para um índice desses de qualquer forma.
        if o.geti != nil {
            if n, is_num := key.(f64); is_num && n == n && math.trunc(n) == n && n >= 0 && n < 2147483648 {
                if v, handled := o.geti(vm, o, int(n)); handled do return v
            }
        }
        // subclasse de Array (M136): índice numérico vai direto ao array embrulhado,
        // desde que a própria instância não tenha essa chave.
        if o.prim != nil {
            if _, own := o.props[key_string(vm, key)]; !own {
                if _, isarr := o.prim.(^Array); isarr do return get_index(vm, o.prim, key)
            }
        }
        // via get_member: honra getters (accessor/defineProperty), cadeia de proto
        // e hook de host — igual ao acesso por ponto.
        return get_member(vm, o, key_string(vm, key))
    case string:
        // s[i]: a rune no índice i (code point; 'café'[3] = 'é')
        if kn := as_number(key); kn == kn && math.trunc(kn) == kn {
            ch := str_rune_at(o, int(kn))
            if ch == "" do return nil
            return own_str(vm, ch)
        }
        return get_member(vm, obj, key_string(vm, key))
    }
    return get_member(vm, obj, key_string(vm, key))
}

// package-visible: proxy.odin (default set/Reflect.set) reusa.
set_index :: proc(vm: ^Interp, obj: Value, key: Value, val: Value) {
    #partial switch o in obj {
    case ^Array:
        n := as_number(key)
        if n != n || math.trunc(n) != n { // chave não-inteira num Array → props
            set_member(vm, obj, key_string(vm, key), val)
            return
        }
        idx := int(n)
        if idx < 0 || idx > 100_000_000 do return // guarda: arr[1e12]=x alocaria GBs preenchendo buracos
        if o.frozen do return // Object.freeze([...]): item não muda
        // seal/preventExtensions: os itens EXISTENTES seguem graváveis, o array é que
        // não cresce mais.
        if idx >= len(o.items) && (o.sealed || o.frozen) do return
        for len(o.items) <= idx do append(&o.items, nil) // preenche buracos
        o.items[idx] = val
    case ^Object:
        // subclasse de Array (M136): índice numérico escreve no array embrulhado.
        if o.prim != nil {
            if n := as_number(key); n == n && math.trunc(n) == n {
                if _, isarr := o.prim.(^Array); isarr { set_index(vm, o.prim, key, val); return }
            }
        }
        // via set_member: honra setters (accessor/defineProperty) e freeze.
        set_member(vm, o, key_string(vm, key), val)
    case ^Function:
        // `fn[k] = v` (chave computada) numa função. FALTAVA — só `fn.x = v`
        // (nomeado) passava por set_member; o computado caía aqui e era IGNORADO
        // silenciosamente. Era a RAIZ de "$ is not a function": jQuery.extend copia
        // as props via `target[c] = src[c]` sobre o objeto jQuery (uma FUNÇÃO), então
        // jQuery.ready/etc. nunca eram setados → `jQuery.ready.promise=` lançava →
        // init do jQuery abortava → `$`/`jQuery` nunca eram definidos. set_member já
        // trata ^Function (grava em fn.props / invoca setters static).
        set_member(vm, o, key_string(vm, key), val)
    }
}

// Lê/escreve um alvo cuja base/chave JÁ foram avaliadas (obj/key) — o .Assign
// resolve a referência uma vez e reusa aqui (ordem da spec, sem reavaliação).
@(private = "file")
ref_read :: proc(vm: ^Interp, t: ^Node, env: ^Env, obj: Value, key: Value) -> Value {
    #partial switch t.kind {
    case .Ident:
        v, _ := env_get(env, t.name)
        return v
    case .Member:
        return get_member(vm, obj, t.name)
    case .Index:
        return get_index(vm, obj, key)
    }
    return nil
}

@(private = "file")
ref_write :: proc(vm: ^Interp, t: ^Node, env: ^Env, obj: Value, key: Value, val: Value) {
    #partial switch t.kind {
    case .Ident:
        env_assign(vm, env, t.name, val)
    case .Member:
        set_member(vm, obj, t.name, val)
    case .Index:
        set_index(vm, obj, key, val)
    }
}

// Lê/escreve o valor atual de um alvo de atribuição (Ident/Member/Index).
// Usado por ++/-- (avalia a base/chave a cada chamada; em obj.x++ o objeto é
// avaliado duas vezes — aceitável, alvos de ++ raramente têm efeitos colaterais).
@(private = "file")
read_target :: proc(vm: ^Interp, t: ^Node, env: ^Env) -> Value {
    #partial switch t.kind {
    case .Ident:
        v, _ := env_get(env, t.name)
        return v
    case .Member:
        return get_member(vm, eval(vm, t.left, env), t.name)
    case .Index:
        obj := eval(vm, t.left, env)
        return get_index(vm, obj, eval(vm, t.right, env))
    }
    return nil
}

@(private = "file")
write_target :: proc(vm: ^Interp, t: ^Node, val: Value, env: ^Env) {
    #partial switch t.kind {
    case .Ident:
        env_assign(vm, env, t.name, val)
    case .Member:
        set_member(vm, eval(vm, t.left, env), t.name, val)
    case .Index:
        obj := eval(vm, t.left, env)
        set_index(vm, obj, eval(vm, t.right, env), val)
    }
}

// Resolve o objeto-iterador de `v` pelo protocolo de iteração:
//   (1) se `v` já É um iterador (tem .next), ele mesmo;
//   (2) senão, se `v` tem um método Symbol.iterator, chama-o (this=v) p/ obtê-lo.
// Devolve (iterador, ok). ok=false → `v` não é iterável por protocolo (o chamador
// cai nos caminhos nativos Array/string/Collection).
get_iterator :: proc(vm: ^Interp, v: Value) -> (Value, bool) {
    if is_iterator_obj(v) do return v, true
    if _, ok := v.(^Object); !ok do return nil, false
    m := get_member(vm, v, vm.sym_iterator_key)
    fn, fok := m.(^Function)
    if !fok do return nil, false
    iter := call_function(vm, fn, v, nil)
    if vm.throwing do return nil, false
    if !is_iterator_obj(iter) do return nil, false
    return iter, true
}

// Dirige o protocolo de iterador de `v`, empurrando cada valor em `out`.
// Devolve true se `v` era iterável por protocolo (iterador ou Symbol.iterator);
// false → o chamador deve tratar `v` pelos caminhos nativos (Array/string/etc).
iterate_protocol :: proc(vm: ^Interp, v: Value, out: ^[dynamic]Value) -> bool {
    iter, ok := get_iterator(vm, v)
    if !ok do return false
    next_fn := iterator_next_fn(iter)
    for {
        if step_guard(vm) do break
        r := call_function(vm, next_fn, iter, nil)
        if vm.throwing do break
        ro, rok := r.(^Object)
        if !rok || truthy(ro.props["done"]) do break
        append(out, ro.props["value"])
    }
    return true
}

// Avalia uma lista de argumentos/elementos, expandindo os `...spread` de arrays.
// Reusado por chamadas, `new`, super() e literais de array.
eval_args :: proc(vm: ^Interp, nodes: [dynamic]^Node, env: ^Env) -> [dynamic]Value {
    out: [dynamic]Value
    for a in nodes {
        if a.kind == .Spread {
            sv := eval(vm, a.left, env)
            // iterador (...map.keys()) ou objeto com Symbol.iterator: dirige o protocolo
            if iterate_protocol(vm, sv, &out) do continue
            #partial switch s in sv {
            case ^Array:
                for it in s.items do append(&out, it)
            case ^Collection:
                // ...set = elementos; ...map = pares [k,v] (como o for-of)
                if s.kind == .Set || s.kind == .Weak_Set {
                    for e in s.entries do append(&out, e.key)
                } else {
                    for e in s.entries {
                        pair := new_array(vm)
                        append(&pair.items, e.key); append(&pair.items, e.val)
                        append(&out, pair)
                    }
                }
            case string:
                // ...str = um item por code point (strings são iteráveis)
                starts: [dynamic]int
                defer delete(starts)
                for _, i in s do append(&starts, i)
                append(&starts, len(s))
                for k := 0; k + 1 < len(starts); k += 1 {
                    append(&out, own_str(vm, s[starts[k]:starts[k + 1]]))
                }
            }
            // spread de outros valores: ignora
        } else {
            append(&out, eval(vm, a, env))
        }
    }
    return out
}

// Materializa um iterável num ^Array p/ destructuring posicional `[a,b] = it`.
// Cobre Set/Map (entries), generators, iteradores e objetos com Symbol.iterator.
// Devolve false p/ não-iteráveis (o chamador cai no acesso por índice, que trata
// array-likes com .length). Iterável infinito é limitado pelo step_guard.
@(private = "file")
materialize_for_pattern :: proc(vm: ^Interp, val: Value) -> (^Array, bool) {
    #partial switch v in val {
    case ^Array:
        return v, true // já é array (sem cópia)
    case ^Collection:
        arr := new_array(vm)
        if v.kind == .Set || v.kind == .Weak_Set {
            for e in v.entries do append(&arr.items, e.key)
        } else {
            for e in v.entries { // Map: pares [k,v] (como o for-of)
                pair := new_array(vm)
                append(&pair.items, e.key); append(&pair.items, e.val)
                append(&arr.items, pair)
            }
        }
        return arr, true
    case ^Object:
        out: [dynamic]Value // iterador / generator / objeto com Symbol.iterator
        if iterate_protocol(vm, v, &out) {
            arr := new_array(vm)
            arr.items = out // transfere posse do buffer materializado
            return arr, true
        }
        delete(out)
        return nil, false
    }
    return nil, false
}

// Liga um padrão de desestruturação (.Pattern) a `val`, definindo as variáveis
// no `env`. Reusado por VarDecl e por parâmetros de função. Recursivo p/ padrões
// aninhados; `default` (el.right) só entra quando a fonte é undefined.
// Elemento rest (el.bval) recolhe o restante num array (posição) ou objeto (chaves).
// `declare`: true = declaração (let/const/params: env_define no escopo novo);
// false = destructuring-EXPRESSÃO (`[a,b]=[b,a]`: env_assign sobe a cadeia).
// `is_const`: a declaração é `const` (`const {a,b} = o`) — cada nome ligado vira
// binding imutável, como um `const a` simples.
bind_pattern :: proc(vm: ^Interp, pat: ^Node, val: Value, env: ^Env, declare := true, is_const := false) {
    bind_one :: proc(vm: ^Interp, env: ^Env, name: string, v: Value, declare: bool, is_const: bool) {
        if declare {
            if is_const do env_define_const(env, name, v)
            else do env_define(env, name, v)
        } else {
            env_assign(vm, env, name, v)
        }
    }
    val := val
    // chaves de objeto consumidas por elementos de chave COMPUTADA (`{ [k]: v }`):
    // só o runtime conhece essas chaves, então um rest de objeto (`...resto`) precisa
    // excluí-las além das estáticas (pattern_has_key). Preenchido ao processar cada
    // elemento computado; o rest é sempre o último, logo já está completo ao chegar lá.
    computed_consumed: map[string]bool
    defer delete(computed_consumed)
    // destructuring de ARRAY sobre um iterável não-array (Set/Map/generator/iterador/
    // objeto com Symbol.iterator): materializa num array e usa acesso posicional.
    // Array e string seguem o caminho rápido (get_index já os cobre por índice).
    if !pat.bval {
        #partial switch _ in val {
        case ^Array, string: // caminho rápido posicional
        case:
            if arr, ok := materialize_for_pattern(vm, val); ok do val = arr
        }
    }
    for el, i in pat.body {
        if el.bval { // rest: recolhe o restante
            if pat.bval {
                // objeto: chaves ainda não consumidas por este padrão (ordem da fonte)
                rest := new_object(vm)
                if src, ok := val.(^Object); ok {
                    keys: [dynamic]string
                    defer delete(keys)
                    own_enum_keys(src, &keys)
                    for k in keys {
                        if !pattern_has_key(pat, k) && !computed_consumed[k] do oput(rest, k, get_member(vm, src, k))
                    }
                }
                bind_one(vm, env, el.name, rest, declare, is_const)
            } else {
                // array: itens a partir do índice atual
                rest := new_array(vm)
                if src, ok := val.(^Array); ok {
                    for j := i; j < len(src.items); j += 1 do append(&rest.items, src.items[j])
                }
                bind_one(vm, env, el.name, rest, declare, is_const)
            }
            continue
        }
        v: Value
        if pat.bval {
            if el.third != nil { // chave computada: { [expr]: alvo }
                key := key_string(vm, eval(vm, el.third, env))
                computed_consumed[key] = true
                v = get_member(vm, val, key)
            } else {
                v = get_member(vm, val, el.str)   // objeto: pela chave estática
            }
        } else {
            v = get_index(vm, val, f64(i))        // array: pelo índice posicional
        }
        if v == nil && el.right != nil do v = eval(vm, el.right, env) // default
        if el.left != nil {
            if el.left.kind == .Pattern {
                bind_pattern(vm, el.left, v, env, declare, is_const) // aninhado
            } else {
                write_target(vm, el.left, v, env) // alvo member/index: [o.x] = v (só expressão)
            }
        } else if el.name != "" {
            bind_one(vm, env, el.name, v, declare, is_const)
        }
        // el.name=="" && el.left==nil => buraco de array: ignora
    }
}

// Roda o corpo de um for-of/for-in para um valor `v` (escopo por iteração; closures
// capturam bindings distintos). Devolve true se o loop deve PARAR (break/return/throw
// ou um continue/break rotulado que mira um loop externo).
@(private = "file")
for_of_run_body :: proc(vm: ^Interp, n: ^Node, env: ^Env, v: Value, my_label: string) -> (stop: bool) {
    iter_env := new_env(vm, env)
    if n.stat {
        // for (var x of/in ...): function-scoped — atribui à var JÁ ÍÇADA no escopo
        // de função (mesmo slot em todas as iterações; vaza p/ fora com o último
        // valor). env_assign sobe a cadeia até achar o binding hoisted.
        if n.left != nil {
            bind_pattern(vm, n.left, v, env, declare = false)
        } else {
            env_assign(vm, env, n.name, v)
        }
    } else if n.left != nil {
        // let/const: padrão block-scoped, por iteração. `const` marca o binding —
        // rebindar a cada volta é env_define (permitido); atribuir DENTRO do corpo
        // passa por env_assign e lança.
        bind_pattern(vm, n.left, v, iter_env, true, n.is_const)
    } else if n.aux {
        if n.is_const {
            env_define_const(iter_env, n.name, v) // for (const x of ...)
        } else {
            env_define(iter_env, n.name, v) // for (let x of ...)
        }
    } else {
        env_assign(vm, env, n.name, v)      // for (x of ...) sem declaração
    }
    eval(vm, n.callee, iter_env)
    if vm.continuing { if loop_take_continue(vm, my_label) do return false; return true }
    if vm.breaking { loop_take_break(vm, my_label); return true }
    if vm.returning || vm.throwing do return true
    return false
}

// IteratorClose (spec 7.4.6, simplificado): no término abrupto de um for-of
// (break / return do corpo), chama o método `return` do iterador se existir —
// é o que faz o try/finally de um generator abandonado rodar. Os sinais em voo
// (returning/breaking) são estacionados p/ o corpo do return() poder executar;
// exceção lançada DENTRO do return() prevalece (spec). DESVIO consciente: com
// exceção já em voo no corpo do for-of, NÃO chamamos return() (a spec chama e
// preserva a exceção original; aqui evitamos rodar finally sob exceção pendente).
@(private = "file")
iterator_close :: proc(vm: ^Interp, iter: Value) {
    if vm.throwing do return
    ret_v := get_member(vm, iter, "return")
    ret_fn, fok := ret_v.(^Function)
    if !fok do return
    sav_ret, sav_val := vm.returning, vm.ret_val
    sav_brk, sav_cont := vm.breaking, vm.continuing
    vm.returning = false; vm.ret_val = nil; vm.breaking = false; vm.continuing = false
    call_function(vm, ret_fn, iter, nil)
    if !vm.throwing {
        vm.returning, vm.ret_val = sav_ret, sav_val
        vm.breaking, vm.continuing = sav_brk, sav_cont
    }
}

// for (x of it) / for (x in it).
//
// Iteráveis por PROTOCOLO (generator, iterador de Map/Set, objeto com Symbol.iterator)
// são percorridos de forma LAZY: dirige next() e roda o corpo a CADA passo. Isso é
// essencial p/ generators infinitos (`for(x of fib())` com break) — materializar tudo
// travaria — e faz `break` parar cedo de verdade. Iteráveis nativos (array/string/
// Collection) e o for-in materializam num snapshot (evita invalidação se o corpo mutar).
// Await bloqueante que traduz uma rejeição em exceção JS (throwing). Devolve o
// valor resolvido (ou o próprio valor, se não-promise). Reusado por for-await.
@(private = "file")
await_blocking_throw :: proc(vm: ^Interp, v: Value) -> Value {
    res, rejected := promise_await_blocking(vm, v)
    if rejected { vm.thrown = res; vm.throwing = true; return nil }
    return res
}

// Resolve o iterador ASSÍNCRONO de `v`: Symbol.asyncIterator se existir; senão o
// Symbol.iterator síncrono (for-await envolve iteráveis síncronos, awaitando cada
// valor adiante). false ⇒ não é iterável por protocolo (cai no fallback nativo).
@(private = "file")
get_async_iterator :: proc(vm: ^Interp, v: Value) -> (Value, bool) {
    if _, ok := v.(^Object); ok {
        m := get_member(vm, v, vm.sym_async_iterator_key)
        if fn, fok := m.(^Function); fok {
            iter := call_function(vm, fn, v, nil)
            if vm.throwing do return nil, false
            return iter, true
        }
    }
    return get_iterator(vm, v) // fallback: iterador síncrono por protocolo
}

// Materializa os VALORES de um iterável nativo síncrono (array/Collection/string)
// — o fallback do for-await quando não há iterador por protocolo.
@(private = "file")
collect_sync_values :: proc(vm: ^Interp, it: Value, out: ^[dynamic]Value) {
    #partial switch o in it {
    case ^Array:
        for item in o.items do append(out, item)
    case ^Collection:
        if o.kind == .Set || o.kind == .Weak_Set {
            for e in o.entries do append(out, e.key)
        } else {
            for e in o.entries {
                pair := new_array(vm)
                append(&pair.items, e.key); append(&pair.items, e.val)
                append(out, pair)
            }
        }
    case string:
        starts: [dynamic]int
        defer delete(starts)
        for _, i in o do append(&starts, i)
        append(&starts, len(o))
        for k := 0; k + 1 < len(starts); k += 1 {
            append(out, own_str(vm, o[starts[k]:starts[k + 1]]))
        }
    }
}

// for await (x of it) — drena um async iterator (ou um síncrono envolvido). Cada
// passo: `res = await it.next()`; se done, para; senão `val = await res.value` e
// roda o corpo. Awaitar o valor cobre `for await (x of [p1, p2])` (arrays de
// promises), como o AsyncFromSyncIterator da spec.
@(private = "file")
eval_for_await :: proc(vm: ^Interp, n: ^Node, env: ^Env, it: Value, my_label: string) -> Value {
    if iter, ok := get_async_iterator(vm, it); ok {
        next_fn := iterator_next_fn(iter)
        if next_fn != nil {
            for {
                if step_guard(vm) do break
                r := call_function(vm, next_fn, iter, nil)
                if vm.throwing do return nil
                r = await_blocking_throw(vm, r) // next() de async gen devolve Promise
                if vm.throwing do return nil
                ro, rok := r.(^Object)
                if !rok || truthy(ro.props["done"]) do break
                val := await_blocking_throw(vm, ro.props["value"])
                if vm.throwing do return nil
                if for_of_run_body(vm, n, env, val, my_label) {
                    iterator_close(vm, iter) // término abrupto → it.return()
                    break
                }
            }
            return nil
        }
    }
    // fallback: iterável nativo síncrono (array/Collection/string) — awaita cada elemento
    values: [dynamic]Value
    defer delete(values)
    collect_sync_values(vm, it, &values)
    for v in values {
        av := await_blocking_throw(vm, v)
        if vm.throwing do return nil
        if for_of_run_body(vm, n, env, av, my_label) do break
    }
    return nil
}

@(private = "file")
eval_for_of :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    my_label := vm.pending_label; vm.pending_label = ""
    it := eval(vm, n.right, env)
    if vm.throwing do return nil

    // for await (x of it): drena um iterável ASSÍNCRONO (ou síncrono, awaitando
    // cada valor). O await é bloqueante — pausa o loop até cada passo assentar.
    if n.is_generator do return eval_for_await(vm, n, env, it, my_label)

    // caminho LAZY: for-of sobre iterável por protocolo
    if n.bval {
        if iter, ok := get_iterator(vm, it); ok {
            next_fn := iterator_next_fn(iter)
            if next_fn != nil {
                for {
                    if step_guard(vm) do break
                    r := call_function(vm, next_fn, iter, nil)
                    if vm.throwing do return nil
                    ro, rok := r.(^Object)
                    if !rok || truthy(ro.props["done"]) do break
                    if for_of_run_body(vm, n, env, ro.props["value"], my_label) {
                        // término ABRUPTO (break/return): IteratorClose — chama
                        // iter.return() p/ o finally de generator rodar
                        iterator_close(vm, iter)
                        break
                    }
                }
                return nil
            }
        }
    }

    // caminho MATERIALIZADO: array/string/Collection nativos e for-in
    values: [dynamic]Value
    defer delete(values)

    if n.bval { // for-of: os VALORES
        #partial switch o in it {
        case ^Array:
            for item in o.items do append(&values, item)
        case ^Collection:
            // Set/WeakSet: os elementos. Map/WeakMap: pares [chave, valor].
            if o.kind == .Set || o.kind == .Weak_Set {
                for e in o.entries do append(&values, e.key)
            } else {
                for e in o.entries {
                    pair := new_array(vm)
                    append(&pair.items, e.key)
                    append(&pair.items, e.val)
                    append(&values, pair)
                }
            }
        case string:
            // um valor por code point (fatias válidas da string, clonadas ao vm)
            starts: [dynamic]int
            defer delete(starts)
            for _, i in o do append(&starts, i)
            append(&starts, len(o))
            for k := 0; k + 1 < len(starts); k += 1 {
                append(&values, own_str(vm, o[starts[k]:starts[k + 1]]))
            }
        }
    } else { // for-in: as CHAVES
        #partial switch o in it {
        case ^Object:
            // próprias enumeráveis, não-símbolo (métodos de proto, chaves-símbolo e
            // props não-enumeráveis via defineProperty não aparecem)
            keys: [dynamic]string
            defer delete(keys)
            own_enum_keys(o, &keys)
            for k in keys do append(&values, own_str(vm, k))
        case ^Array:
            buf: [24]u8
            for i in 0 ..< len(o.items) do append(&values, own_str(vm, strconv.write_int(buf[:], i64(i), 10)))
        }
    }

    for v in values {
        if for_of_run_body(vm, n, env, v, my_label) do break
    }
    return nil
}

// True se o padrão de objeto lista `key` como uma chave-fonte (p/ excluir do rest).
@(private = "file")
pattern_has_key :: proc(pat: ^Node, key: string) -> bool {
    for el in pat.body {
        if !el.bval && el.str == key do return true
    }
    return false
}

// ── avaliação ───────────────────────────────────────────────────────────────

eval :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    when JSPROF { g_prof.por_no[n.kind] += 1; g_prof.evals += 1 }
    // exceção em voo: nada mais é avaliado até um try/catch (ou o topo) tratá-la.
    // gen_hard_kill: um generator sendo terminado no vm_destroy — não roda mais JS.
    if vm.throwing || vm.gen_hard_kill do return nil
    // fronteira de cadeia opcional: um nó que não é Member/Index/Call encerra
    // qualquer curto-circuito de `?.` em andamento (o valor já foi consumido).
    if n.kind != .Member && n.kind != .Index && n.kind != .Call do vm.opt_short = false
    switch n.kind {
    case .Num:
        return n.num
    case .BigIntLit:
        b, ok := bigint_from_string(vm, n.str)
        if !ok { throw_type_error(vm, "invalid BigInt literal"); return nil }
        return b
    case .Str:
        return n.str
    case .Regex:
        re, ok := regex_compile(vm, n.str, n.name)
        if !ok {
            vm.thrown = mk_error(vm, "SyntaxError", "expressão regular inválida")
            vm.throwing = true
            return nil
        }
        return re
    case .Bool:
        return n.bval
    case .Null:
        return JS_Null{}
    case .Undef:
        return nil
    case .Ident:
        if v, ok := lookup_ident(vm, env, n.name); ok do return v
        // Identificador NÃO RESOLVIDO → ReferenceError (spec §13.3.1 / GetValue de
        // uma Reference unresolvable). `typeof x` é a única isenção e não passa
        // por aqui. Devolvíamos `undefined` até o M150, e o custo não era só de
        // conformidade: global ausente ficava INVISÍVEL — virava undefined, o erro
        // aparecia páginas depois como `reading 'x' of undefined`, e a seção
        // "Globais faltando (ReferenceError)" do gap-report vivia estruturalmente
        // VAZIA. Agora o nome que falta aparece com o nome dele no relatório.
        when #config(MEMBERPROBE, false) {
            if g_probe_in_typeof == 0 do fmt.eprintfln("[unresolved] %s", n.name)
        }
        // ⚠️ `this` NÃO é referência de identificador — é ThisExpression, e a spec
        // nunca a torna unresolvable. Nós a guardamos como uma var chamada "this"
        // no escopo (env_define(fenv,"this",obj)), então ela CAI AQUI quando não
        // há ligação: topo de script sem DOM, onde `this` é o objeto global (nil
        // p/ nós, sloppy mode). Sem esta isenção o M150 fez `var g = this` LANÇAR
        // — 3 regressões nomeadas no Test262 (`this is not defined`) que o total
        // agregado esconderia. Devolve global_this (o window quando há DOM).
        if n.name == "this" do return vm.global_this
        when !#config(NOREFERR, false) {
            throw_reference_error(vm, fmt.tprintf("%s is not defined", n.name))
        }
        return nil

    case .Unary:
        v := eval(vm, n.left, env)
        if vm.throwing do return nil
        if b, ok := v.(^BigInt); ok { // BigInt: -x nega, ~x = -(x+1), +x LANÇA
            #partial switch n.op {
            case .Minus: return bigint_neg(vm, b)
            case .Tilde: return bigint_not(vm, b)
            case .Bang:  return !truthy(v)
            case .Plus:
                throw_type_error(vm, "Cannot convert a BigInt value to a number")
                return nil
            }
        }
        // to_number (não as_number): objeto passa por ToPrimitive — `+new Date` = ms,
        // `+{valueOf:()=>42}` = 42. Primitivo cai no caminho rápido dentro de to_number.
        #partial switch n.op {
        case .Minus:
            return -to_number(vm, v)
        case .Plus:
            return to_number(vm, v) // unário +: coerção numérica
        case .Bang:
            return !truthy(v)
        case .Tilde:
            return f64(~to_int32(to_number(vm, v))) // bitwise NOT
        }
        return v

    case .Void:
        eval(vm, n.left, env) // efeitos colaterais; resultado descartado
        return nil            // undefined

    case .Delete:
        t := n.left
        #partial switch t.kind {
        case .Member:
            if o, ok := eval(vm, t.left, env).(^Object); ok {
                if o.px_handler != nil { proxy_delete(vm, o, t.name); return true } // trap deleteProperty
                if o.get == storage_get { storage_remove_key(o, t.name); return true } // delete localStorage.x
                if .Configurable in prop_attrs(o, t.name) do oremove(o, t.name)
            }
        case .Index:
            obj := eval(vm, t.left, env)
            if o, ok := obj.(^Object); ok {
                if o.px_handler != nil { proxy_delete(vm, o, key_string(vm, eval(vm, t.right, env))); return true }
                if o.get == storage_get { storage_remove_key(o, key_string(vm, eval(vm, t.right, env))); return true }
                k := key_string(vm, eval(vm, t.right, env))
                if .Configurable in prop_attrs(o, k) do oremove(o, k)
            } else if a, ok := obj.(^Array); ok {
                if idx := as_int(eval(vm, t.right, env)); idx >= 0 && idx < len(a.items) {
                    a.items[idx] = nil // JS deixa um buraco (undefined)
                }
            }
        }
        return true

    case .Update:
        // ++x / x++ / --x / x--
        old := read_target(vm, n.left, env)
        if ob, ok := old.(^BigInt); ok { // BigInt: ++ soma 1n (não Number 1)
            one := bigint_from_i64(vm, 1)
            nb := n.op == .PlusPlus ? bigint_add(vm, ob, one) : bigint_sub(vm, ob, one)
            write_target(vm, n.left, nb, env)
            return nb if n.bval else ob
        }
        cur := as_number(old)
        newv := cur + (1 if n.op == .PlusPlus else -1)
        write_target(vm, n.left, newv, env)
        return newv if n.bval else cur // prefixo devolve o novo; sufixo, o antigo

    case .Binary:
        // brand check de campo privado: `#x in obj`. O lado esquerdo `#x` NÃO é um
        // valor avaliável (env_get falharia) — testamos se obj tem o slot privado.
        if n.op == .In && n.left.kind == .Ident && is_private_key(n.left.name) {
            r := eval(vm, n.right, env)
            if vm.throwing do return nil
            return private_in(n.left.name, r)
        }
        l := eval(vm, n.left, env)
        r := eval(vm, n.right, env)
        return binop(vm, n.op, l, r)

    case .Logical:
        // curto-circuito, devolvendo o operando (não um bool), como no JS
        l := eval(vm, n.left, env)
        #partial switch n.op {
        case .AmpAmp:    return eval(vm, n.right, env) if truthy(l) else l
        case .QQuestion:                                 // nullish: só cai em null/undefined
            _, is_null := l.(JS_Null)
            return eval(vm, n.right, env) if (l == nil || is_null) else l
        }
        return l if truthy(l) else eval(vm, n.right, env) // ||

    case .Ternary:
        if truthy(eval(vm, n.left, env)) do return eval(vm, n.right, env)
        return eval(vm, n.third, env)

    case .Seq:
        // operador vírgula: avalia left (efeitos colaterais) e devolve right
        eval(vm, n.left, env)
        if vm.returning || vm.throwing || vm.breaking || vm.continuing do return nil
        return eval(vm, n.right, env)

    case .Await:
        v := eval(vm, n.left, env)
        if vm.throwing do return nil
        // Dentro de uma CORROTINA async: suspende (o driver async_step retoma quando
        // a promise assentar). Fora dela — await de topo — cai no antigo caminho
        // bloqueante, que ali é seguro porque não há continuação a agendar.
        if vm.current_gen != nil && vm.current_gen.is_async_fn {
            r := generator_yield(vm, v)
            if vm.throwing || vm.returning do return nil // rejeição injetada como throw
            return r
        }
        res, was_rejected := promise_await_blocking(vm, v)
        if was_rejected { // await de promise rejeitada LANÇA (capturável por try/catch)
            vm.thrown = res
            vm.throwing = true
            return nil
        }
        return res

    case .TypeOf:
        // `typeof x` é a ÚNICA isenção da spec: não lança para identificador
        // ausente — `typeof WeakRef === "undefined"` é O idioma de detecção de
        // feature, e lançar aqui quebraria todo site. Por isso o operando IDENT
        // resolve por lookup_ident (mesmo funil, sem throw) em vez de eval.
        // Só o ident NU é isento: `typeof a.b` com `a` ausente segue lançando,
        // porque quem lança é o eval do `a` lá dentro.
        v: Value
        if n.left != nil && n.left.kind == .Ident {
            v, _ = lookup_ident(vm, env, n.left.name)
        } else {
            when #config(MEMBERPROBE, false) { g_probe_in_typeof += 1 }
            v = eval(vm, n.left, env)
            when #config(MEMBERPROBE, false) { g_probe_in_typeof -= 1 }
            if vm.throwing do return nil
        }
        switch _ in v {
        case f64:       return "number"
        case bool:      return "boolean"
        case string:    return "string"
        case JS_Null:   return "object" // sim: typeof null == "object" (JS histórico)
        case ^Function: return "function"
        case ^Object:     return "object"
        case ^Array:      return "object"
        case ^Regex:      return "object"
        case ^Collection: return "object"
        case ^Symbol:     return "symbol"
        case ^BigInt:     return "bigint"
        case:             return "undefined"
        }

    case .Assign:
        // destructuring-expressão: `[a, b] = [b, a]` / `({ x } = o)` — atribui
        // (env_assign/write_target), não declara
        if n.left.kind == .Pattern {
            rhs := eval(vm, n.right, env)
            if vm.throwing do return nil
            bind_pattern(vm, n.left, rhs, env, false)
            return rhs
        }
        // Ordem da spec: a REFERÊNCIA do alvo é resolvida ANTES do RHS, uma vez só
        // (a[i] = i++ escreve no índice antigo; obj() .x += v não reavalia obj()).
        tobj, tkey: Value // base e chave de Member/Index, avaliadas UMA vez
        #partial switch n.left.kind {
        case .Member:
            tobj = eval(vm, n.left.left, env)
        case .Index:
            tobj = eval(vm, n.left.left, env)
            tkey = eval(vm, n.left.right, env)
        }
        if vm.throwing do return nil
        when #config(MEMBERPROBE, false) {
            if n.left.kind != .Ident && is_nullish(tobj) {
                fmt.eprintfln("[assignprobe] %s é %s no alvo de atribuição | pilha: %v",
                    describe_callee(n.left.left), tobj == nil ? "undefined" : "null", vm.probe_stack)
            }
        }
        // &&= ||= ??=: curto-circuito — se não vai atribuir, o RHS NEM É AVALIADO
        // (a ??= custoso() não pode rodar custoso() quando a já tem valor)
        #partial switch n.op {
        case .AmpAmp, .PipePipe, .QQuestion:
            cur := ref_read(vm, n.left, env, tobj, tkey)
            keep := false
            #partial switch n.op {
            case .AmpAmp:    keep = !truthy(cur)
            case .PipePipe:  keep = truthy(cur)
            case .QQuestion: keep = !is_nullish(cur)
            }
            if keep do return cur
            rhs := eval(vm, n.right, env)
            ref_write(vm, n.left, env, tobj, tkey, rhs)
            return rhs
        }
        old: Value
        if n.op != .Assign do old = ref_read(vm, n.left, env, tobj, tkey) // composto lê ANTES do RHS
        rhs := eval(vm, n.right, env)
        val: Value = rhs
        if n.op != .Assign do val = binop(vm, n.op, old, rhs) // x += v ≡ x = x <op> v
        ref_write(vm, n.left, env, tobj, tkey, val)
        return val

    case .Member:
        // leitura de super.prop (super.m() é tratado em try_eval_super_call)
        if n.left.kind == .Ident && n.left.name == "super" {
            return eval_super_member(vm, n.name, env)
        }
        obj := eval(vm, n.left, env)
        // A base LANÇOU (ex.: ReferenceError de `baseInexistente.prop`, M150).
        // Sem esta guarda o get_member abaixo seguia e trocava a exceção real por
        // "Cannot read properties of undefined" — mesma classe do M148: o erro
        // de verdade era apagado pelo erro do passo seguinte.
        if vm.throwing do return nil
        if vm.opt_short do return nil // um `?.` anterior na cadeia já curto-circuitou
        if n.bval && is_nullish(obj) { vm.opt_short = true; return nil } // a?.b com a nullish
        // sonda: qual EXPRESSÃO deu undefined (a mensagem padrão só diz a chave lida)
        when #config(MEMBERPROBE, false) {
            if is_nullish(obj) {
                // pilha com PARÂMETROS + nomes dos escopos internos: em bundle
                // minificado é o que identifica a função (M219)
                msb: strings.Builder
                strings.builder_init(&msb)
                {
                    cur := env
                    for lvl := 0; cur != nil && lvl < 3; lvl += 1 {
                        fmt.sbprintf(&msb, "{{")
                        first := true
                        for k in cur.vars {
                            if !first do fmt.sbprintf(&msb, ",")
                            fmt.sbprintf(&msb, "%s", k); first = false
                        }
                        fmt.sbprintf(&msb, "}} ")
                        cur = cur.parent
                    }
                }
                fmt.eprintfln("[memberprobe] %s é %s ao ler '%s' | modulo=%s | pilha=%v | escopos=%s",
                    describe_callee(n.left), obj == nil ? "undefined" : "null", n.name,
                    vm.current_module != nil ? vm.current_module.url : "<fora de modulo>",
                    vm.probe_stack, strings.to_string(msb))
                strings.builder_destroy(&msb)
                // se a base é uma CHAMADA, identifica a função chamada (nome minificado
                // não diz nada; params + nativa/usuário dizem)
                if n.left.kind == .Call && n.left.callee != nil && n.left.callee.kind == .Ident {
                    if cv, _ := env_get(env, n.left.callee.name); cv != nil {
                        if f, fok := cv.(^Function); fok {
                            fmt.eprintfln("           └─ %s = fn nome='%s' nativa=%v params=%v",
                                n.left.callee.name, f.name, f.native != nil, f.params)
                        }
                    }
                }
                for a, i in n.left.body {
                    fmt.eprintfln("           └─ arg%d: %s", i, describe_callee(a))
                }
            }
        }
        r := get_member(vm, obj, n.name)
        vm.opt_short = false // esta leitura operou: um getter pode ter setado a flag
        return r

    case .Index:
        obj := eval(vm, n.left, env)
        if vm.throwing do return nil // base lançou (M150) — não trocar a exceção
        if vm.opt_short do return nil
        if n.bval && is_nullish(obj) { vm.opt_short = true; return nil } // a?.[i]
        key := eval(vm, n.right, env) // pode conter outra cadeia opcional
        if vm.throwing do return nil
        when #config(MEMBERPROBE, false) {
            if is_nullish(obj) do fmt.eprintfln("[memberprobe] %s é undefined ao indexar", describe_callee(n.left))
        }
        r := get_index(vm, obj, key)
        vm.opt_short = false
        return r

    case .ObjectLit:
        o := new_object(vm)
        for key, i in n.params {
            vnode := n.body[i]
            if vnode.kind == .Spread { // {...src}: copia props próprias ENUMERÁVEIS de src
                // via own_keys_any + get_index: preserva a ordem de inserção da fonte
                // E invoca getters ({...{get x(){...}}} materializa o valor).
                // ⚠️ a fonte NÃO é só `^Object` (M220): Function/Array/string são
                // variantes próprias da union e caíam fora em SILÊNCIO — `{...arr}`
                // dava `{}` em vez de `{0:…,1:…}` e `{...Componente}` perdia as props
                // estáticas. null/undefined viram `{}`, como manda a spec.
                src := eval(vm, vnode.left, env)
                if vm.throwing do return o
                keys: [dynamic]string
                defer delete(keys)
                own_keys_any(vm, src, &keys)
                for k in keys do oput(o, k, get_index(vm, src, k))
                continue
            }
            if vnode.kind == .ComputedKey { // {[expr]: v} / { get [expr](){} }
                k := key_string(vm, eval(vm, vnode.left, env))
                if vnode.right != nil && vnode.right.kind == .Func && vnode.right.acc != 0 {
                    // accessor com chave computada
                    if fn, fok := eval(vm, vnode.right, env).(^Function); fok {
                        if vnode.right.acc == 1 {
                            if o.getters == nil do o.getters = make(map[string]^Function)
                            o.getters[k] = fn
                        } else {
                            if o.setters == nil do o.setters = make(map[string]^Function)
                            o.setters[k] = fn
                        }
                    }
                    continue
                }
                oput(o, k, eval(vm, vnode.right, env))
                continue
            }
            if vnode.acc != 0 { // getter (1) / setter (2)
                fn, _ := eval(vm, vnode, env).(^Function)
                if fn == nil do continue
                if vnode.acc == 1 {
                    if o.getters == nil do o.getters = make(map[string]^Function)
                    o.getters[key] = fn
                } else {
                    if o.setters == nil do o.setters = make(map[string]^Function)
                    o.setters[key] = fn
                }
                continue
            }
            // `{__proto__: v}` DEFINE o [[Prototype]] em vez de criar uma prop
            // própria (spec B.3.1) — é a única chave da linguagem com esse
            // tratamento, e o idioma `{__proto__: null}` (dicionário sem herança)
            // depende dele. ⚠️ Vale só para a forma `chave: valor` literal: a
            // COMPUTADA `{["__proto__"]: v}` cria prop normal e é tratada acima,
            // antes daqui — a spec distingue as duas de propósito.
            if key == "__proto__" {
                set_proto_value(o, eval(vm, vnode, env)) // no-op p/ não-objeto, como no acessor
                continue
            }
            oput(o, key, eval(vm, vnode, env))
        }
        return o

    case .ArrayLit:
        a := new_array(vm)
        items := eval_args(vm, n.body, env) // expande ...spread
        defer delete(items)
        for it in items do append(&a.items, it)
        return a

    case .Call:
        return eval_call(vm, n, env)

    case .New:
        callee := eval(vm, n.callee, env)
        if vm.throwing do return nil
        fn, ok := callee.(^Function)
        if !ok {
            // `new proxy(...)`: um Proxy é um ^Object, não ^Function — sem isto, um
            // construtor envolvido em Proxy era "is not a constructor" (M136).
            if p, pok := callee.(^Object); pok && p.px_handler != nil {
                pargs := eval_args(vm, n.body, env)
                defer delete(pargs)
                return proxy_construct(vm, p, pargs[:])
            }
            // new de não-função → TypeError (era undefined silencioso; M42 BUG 2)
            throw_type_error(vm, fmt.tprintf("%s is not a constructor", describe_callee(n.callee)))
            return nil
        }
        args := eval_args(vm, n.body, env)
        defer delete(args)
        return construct_object(vm, fn, args[:])

    case .NewTarget:
        // vinculado em setup_call_scope (nil fora de `new`); herança léxica em arrows
        v, _ := env_get(env, "new.target")
        return v

    // módulos ES (M109) — implementações em module.odin
    case .ImportCall:
        return eval_import_call(vm, n, env)
    case .ImportMeta:
        return eval_import_meta(vm, n)
    case .ImportDecl:
        eval_import_decl(vm, n, env)
        return nil
    case .ExportDecl:
        return eval_export_decl(vm, n, env)

    case .Func:
        f := new_function(vm)
        f.params = n.params[:]
        f.param_pats = n.param_pats[:]
        f.param_defaults = n.param_defaults[:]
        f.rest_param = n.rest_param
        f.rest_pat = n.rest_pat
        f.body = n.right
        f.closure = env // captura o ambiente atual (closure!)
        env_escaped(vm) // `env` (e seus ancestrais) agora sobrevive a esta chamada
        f.name = n.name
        f.is_arrow = n.bval
        f.is_async = n.aux
        f.is_generator = n.is_generator
        f.uses_arguments = n.uses_arguments
        val: Value = f
        // Só DECLARAÇÕES bindam o nome no escopo externo. Expressão nomeada
        // (`var f = function g(){}`) tem `g` visível apenas no próprio corpo
        // (self_bind em setup_call_scope) — vazar clobberava homônimos externos.
        if n.name != "" {
            if n.decl do env_define(env, n.name, val)
            else do f.self_bind = true
        }
        return val

    case .Class:
        return eval_class(vm, n, env)

    case .ExprStmt:
        return eval(vm, n.left, env)

    case .VarDecl:
        val: Value = nil
        if n.right != nil do val = eval(vm, n.right, env)
        // `var` é function-scoped: binda no escopo de função mais próximo (React
        // declara `var d` num bloco e usa fora dele). let/const ficam no bloco.
        target := fn_scope_env(env) if n.aux else env
        if n.left != nil {
            bind_pattern(vm, n.left, val, target, true, n.is_const) // const {a,b} = x / [a,b] = arr
        } else if n.is_const {
            env_define_const(target, n.name, val) // reatribuir depois → TypeError
        } else if n.aux && n.right == nil {
            // `var x;` SEM inicializador é NO-OP quando o binding já existe (spec:
            // VariableDeclaration : BindingIdentifier → "Return empty"). Redefinir
            // aqui APAGAVA o valor, e o minificador coloca o `var` no FIM do módulo:
            //   (eT = eV || (eV = {}))[eT.initial = 0] = "initial";  // enum TS
            //   ... class et { constructor(){ this.stage = eV.initial } }
            //   var eS, eE, /*…*/ eV, eN = Object.freeze({…});       // ← zerava eV
            // O enum era montado e logo em seguida perdido: `Cannot read properties
            // of undefined (reading 'initial')` matava o behaviors.js do github.com.
            // Só `var`: `let x;` inicializa mesmo (e reinicializa a cada iteração).
            if _, exists := target.vars[n.name]; !exists do env_define(target, n.name, nil)
        } else {
            env_define(target, n.name, val)
        }
        // declaradores extras (`var a=1, b=2`): mesmo escopo, em ordem
        for d in n.body do eval(vm, d, env)
        return nil

    case .Return:
        vm.ret_val = nil
        if n.right != nil do vm.ret_val = eval(vm, n.right, env)
        vm.returning = true
        return vm.ret_val

    case .Break:
        vm.breaking = true
        vm.break_label = n.name // "" = loop/switch mais próximo
        return nil

    case .Continue:
        vm.continuing = true
        vm.continue_label = n.name
        return nil

    case .Labeled:
        // marca o label p/ o loop/switch DIRETAMENTE rotulado (ele o lê em
        // pending_label). Só se o interno for laço/switch — senão o label vazaria
        // p/ um laço aninhado dentro de um bloco rotulado. Para statements não-laço
        // (bloco/if rotulado) o `break label` é consumido no pós-check abaixo.
        inner := n.left
        is_loop := inner.kind == .While || inner.kind == .For || inner.kind == .DoWhile || inner.kind == .ForOf || inner.kind == .Switch
        if is_loop do vm.pending_label = n.name
        eval(vm, inner, env)
        vm.pending_label = ""
        if vm.breaking && vm.break_label == n.name {
            vm.breaking = false; vm.break_label = ""
        }
        return nil

    case .Throw:
        // A expressão do throw pode LANÇAR ela mesma (`throw new Foo()` com Foo
        // indefinido, `throw f()` que estoura, `throw o.x` com o null). Nesse caso
        // o eval JÁ preencheu vm.thrown com o erro REAL — e escrever por cima
        // (era `vm.thrown = nil` ANTES do eval, depois atribuição do retorno nil)
        // APAGAVA esse erro: o catch recebia `undefined` e o relatório dizia
        // "(lançou undefined)". Não era só mensagem ruim; a semântica ficava errada.
        // Era o cluster de 5 sites do gap-miner (airbnb, stackoverflow, ebay,
        // figma, theguardian) — cada um escondendo o erro de verdade.
        v: Value
        if n.right != nil {
            v = eval(vm, n.right, env)
            if vm.throwing do return nil // preserva a exceção que veio da expressão
        }
        // Sonda do peel de `(lançou undefined)`: DEPOIS do M148 o que sobra é
        // valor genuinamente undefined (airbnb 4, figma 1). Diz QUAL expressão
        // produziu o undefined e em que pilha — sem isso o relatório só informa
        // que "algo" lançou undefined, que é inacionável.
        when #config(MEMBERPROBE, false) {
            if v == nil {
                // O valor de uma SEQUÊNCIA é o ÚLTIMO operando — é ele que virou
                // undefined, então é ele que a sonda tem de nomear (describe_callee
                // devolve "(intermediate value)" para o nó Seq inteiro).
                tail := n.right
                for tail != nil && tail.kind == .Seq do tail = tail.right
                fmt.eprintfln("[undefthrow] valor=%s kind=%v | pilha: %v",
                    tail == nil ? "(sem expressão)" : describe_callee(tail),
                    tail == nil ? Node_Kind.Ident : tail.kind, vm.probe_stack)
            }
        }
        vm.thrown = v
        vm.throwing = true
        return nil

    case .Try:
        eval(vm, n.left, env) // bloco try
        if vm.throwing && n.right != nil && !vm.gen_hard_kill {
            vm.throwing = false // capturada
            exc := vm.thrown
            vm.thrown = nil
            cenv := new_env(vm, env)
            if n.name != "" do env_define(cenv, n.name, exc)
            if n.callee != nil do bind_pattern(vm, n.callee, exc, cenv) // catch ({ message })
            eval(vm, n.right, cenv) // bloco catch (vê o parâmetro)
        }
        if n.third != nil && !vm.gen_hard_kill {
            // finally roda SEMPRE, mesmo com sinal pendente (throw sem catch,
            // return, break...). Estaciona o sinal, roda, e restaura — a menos
            // que o próprio finally gere um sinal novo (que então prevalece).
            st_thr := vm.throwing;   st_val := vm.thrown
            st_ret := vm.returning;  st_rv  := vm.ret_val
            st_brk := vm.breaking;   st_cnt := vm.continuing
            vm.throwing = false; vm.returning = false
            vm.breaking = false; vm.continuing = false
            eval(vm, n.third, env)
            if !(vm.throwing || vm.returning || vm.breaking || vm.continuing) {
                vm.throwing = st_thr;  vm.thrown  = st_val
                vm.returning = st_ret; vm.ret_val = st_rv
                vm.breaking = st_brk;  vm.continuing = st_cnt
            }
        }
        return nil

    case .Block:
        child := new_env(vm, env)
        hoist_functions(vm, n.body[:], child)
        result: Value = nil // valor de conclusão (o eval() do topo o usa)
        for s in n.body {
            if is_hoisted_func(s) do continue // já içada
            result = eval(vm, s, child)
            if vm.returning || vm.breaking || vm.continuing || vm.throwing do break
        }
        return result

    case .If:
        // devolve o valor de conclusão do ramo tomado (semântica de completion,
        // que o eval() lê: `eval("if(true) 7")` === 7).
        cond := truthy(eval(vm, n.left, env))
        if vm.throwing do return nil
        if cond do return eval(vm, n.right, env)
        if n.third != nil do return eval(vm, n.third, env)
        return nil

    case .While:
        my_label := vm.pending_label; vm.pending_label = ""
        for truthy(eval(vm, n.left, env)) {
            if step_guard(vm) do break
            eval(vm, n.right, env)
            if vm.continuing { if loop_take_continue(vm, my_label) do continue; break } // volta à cond (ou propaga p/ label externo)
            if vm.breaking { loop_take_break(vm, my_label); break }
            if vm.returning || vm.throwing do break
        }
        return nil

    case .DoWhile:
        my_label := vm.pending_label; vm.pending_label = ""
        for {
            if step_guard(vm) do break
            eval(vm, n.right, env) // corpo roda pelo menos uma vez
            if vm.continuing {
                if !loop_take_continue(vm, my_label) do break // continue p/ label externo: sai
                // senão: segue para a condição
            } else if vm.breaking {
                loop_take_break(vm, my_label)
                break
            } else if vm.returning || vm.throwing {
                break
            }
            if !truthy(eval(vm, n.left, env)) do break
        }
        return nil

    case .Switch:
        my_label := vm.pending_label; vm.pending_label = ""
        d := eval(vm, n.left, env)
        senv := new_env(vm, env)
        matched := false
        // 1ª fase: procura um case que case (===); uma vez casado, executa TUDO
        // dali em diante (fallthrough) até um break
        exec: for c in n.body {
            if !matched {
                if c.left == nil do continue                 // default fica p/ a 2ª fase
                if eval(vm, c.left, senv) != d do continue   // igualdade ESTRITA (union ==)
                matched = true
            }
            for s in c.body {
                eval(vm, s, senv)
                if vm.breaking { loop_take_break(vm, my_label); break exec } // break do switch (ou `break label`); label externo propaga
                if vm.returning || vm.throwing || vm.continuing do break exec
            }
        }
        // 2ª fase: nenhum case casou → roda do default em diante (com fallthrough)
        if !matched {
            in_default := false
            exec2: for c in n.body {
                if !in_default {
                    if c.left != nil do continue
                    in_default = true
                }
                for s in c.body {
                    eval(vm, s, senv)
                    if vm.breaking { loop_take_break(vm, my_label); break exec2 }
                    if vm.returning || vm.throwing || vm.continuing do break exec2
                }
            }
        }
        return nil

    case .SwitchCase:
        return nil // executado pelo Switch; nunca avaliado sozinho

    case .For:
        my_label := vm.pending_label; vm.pending_label = ""
        loop_env := new_env(vm, env) // escopo do for (init vive aqui)
        if n.left != nil do eval(vm, n.left, loop_env) // init
        // Binding POR ITERAÇÃO (spec ES6): `for (let i...)` dá a cada volta uma
        // cópia nova de i — closures criadas no corpo capturam 0,1,2, não 3,3,3.
        // Só paga o custo quando (a) o init declarou let/const no loop_env (var
        // vaza p/ o escopo de função e expressão não declara nada) e (b) o corpo
        // pode criar closures (contém function/arrow) — senão ninguém observa a cópia.
        // (cacheado em n.acc — campo não usado por .For: 0=não checado, 1=tem função, 2=não tem)
        if n.acc == 0 do n.acc = 1 if (n.callee != nil && subtree_has_func(n.callee)) else 2
        per_iter := len(loop_env.vars) > 0 && n.acc == 1
        iter_env := loop_env
        if per_iter do iter_env = clone_loop_bindings(vm, loop_env, env)
        for n.right == nil || truthy(eval(vm, n.right, iter_env)) { // cond ausente = true
            if vm.throwing do break // cond lançou (ou exceção pendente em for(;;))
            if step_guard(vm) do break
            if n.callee != nil do eval(vm, n.callee, iter_env) // corpo
            if vm.continuing {
                if !loop_take_continue(vm, my_label) do break // continue p/ label externo: sai
                // senão: continue deste for AINDA roda o update abaixo
            } else if vm.breaking {
                loop_take_break(vm, my_label)
                break
            } else if vm.returning || vm.throwing {
                break
            }
            // a PRÓXIMA iteração ganha bindings novos com os valores atuais;
            // o update já roda neles (a closure da iteração corrente não vê o ++)
            if per_iter do iter_env = clone_loop_bindings(vm, iter_env, env)
            if n.third != nil do eval(vm, n.third, iter_env) // update
        }
        return nil

    case .ForOf:
        return eval_for_of(vm, n, env)

    case .Program:
        result: Value = nil
        hoist_functions(vm, n.body[:], env)
        hoist_vars_body(n.body[:], env) // var top-level (inclui os aninhados em blocos)
        for s in n.body {
            if is_hoisted_func(s) do continue // já içada
            result = eval(vm, s, env)
            if vm.returning || vm.breaking || vm.continuing || vm.throwing do break
        }
        return result

    case .Pattern, .PatElem:
        // nunca avaliados diretamente: bind_pattern os consome (VarDecl/params)
        return nil

    case .ClassField, .StaticBlock:
        // nunca avaliado direto: eval_class (static) e init_instance_fields consomem
        return nil

    case .Yield:
        // roda na THREAD do generator (só é alcançado dentro de um corpo de generator).
        if n.bval do return eval_yield_star(vm, n, env) // yield* delega a outro iterável
        val: Value = nil
        if n.left != nil {
            val = eval(vm, n.left, env)
            if vm.throwing do return nil
        }
        // async generator: AsyncGeneratorYield faz Await(value) antes de emitir —
        // `yield promise` rende o valor RESOLVIDO (não a promise). O await é
        // bloqueante e roda na thread do generator (pump normal).
        if vm.current_gen != nil && vm.current_gen.is_async {
            res, rejected := promise_await_blocking(vm, val)
            if rejected { vm.thrown = res; vm.throwing = true; return nil }
            val = res
        }
        return generator_yield(vm, val)

    case .Spread:
        // nunca avaliado direto: eval_args/.ObjectLit expandem o ...spread
        return nil

    case .Template:
        // `a${x}b`: concatena chunks + ToString das interpolações
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        for e, i in n.body {
            if i < len(n.params) do strings.write_string(&sb, n.params[i])
            v := eval(vm, e, env)
            if vm.throwing do return nil
            write_text_spec(&sb, vm, v) // ToString da spec (não o texto de debug)
            if vm.throwing do return nil
        }
        if len(n.body) < len(n.params) do strings.write_string(&sb, n.params[len(n.body)])
        return own_str(vm, strings.to_string(sb))

    case .Tagged:
        // tag`a${x}b` → tag(["a","b"], x) — a tag recebe os chunks num array e
        // cada interpolação como argumento separado. `this` de tag-membro
        // (styled.div`...`) resolvido como em eval_call. strings.raw aponta p/
        // o mesmo array (cooked == raw; escapes já decodificados pelo lexer).
        return eval_tagged(vm, n, env)

    case .ComputedKey:
        // nunca avaliado direto: .ObjectLit consome (left=chave, right=valor)
        return nil
    }
    return nil
}

// Constrói o ^Function de um método de classe (nó .Func) capturando o env da
// definição como closure e os elos de super (usados por super()/super.m()).
@(private = "file")
build_method :: proc(vm: ^Interp, m: ^Node, env: ^Env, super_fn: ^Function, super_proto: ^Object) -> ^Function {
    f := new_function(vm)
    f.params = m.params[:]
    f.param_pats = m.param_pats[:]
    f.param_defaults = m.param_defaults[:]
    f.rest_param = m.rest_param
    f.rest_pat = m.rest_pat
    f.body = m.right
    f.closure = env
    env_escaped(vm)
    f.name = m.name
    f.is_async = m.aux
    f.is_generator = m.is_generator
    f.uses_arguments = m.uses_arguments
    f.super_ctor = super_fn
    f.home_super = super_proto
    return f
}

// Inicializa os campos de instância (`x = init`) no objeto recém-criado por `new`.
// Percorre a cadeia de construtoras da BASE até a DERIVADA para que campos herdados
// entrem primeiro (e campos da subclasse possam sombrear). Cada nível avalia seus
// inicializadores no SEU escopo léxico (c.closure) com `this` = o objeto.
// SIMPLIFICAÇÃO vs. spec: todos os campos entram ANTES do corpo do construtor (a
// spec intercala os da subclasse logo após super()); irrelevante p/ inits comuns.
@(private = "file")
init_instance_fields :: proc(vm: ^Interp, fn: ^Function, obj: ^Object) {
    chain: [dynamic]^Function
    defer delete(chain)
    for c := fn; c != nil; c = c.super_ctor do append(&chain, c)
    #reverse for c in chain {
        if c.class_node == nil do continue
        fenv: ^Env = nil // criado sob demanda (só se houver campos de instância)
        for m in c.class_node.body {
            if m.kind != .ClassField || m.stat do continue
            if fenv == nil {
                fenv = new_env(vm, c.closure)
                env_define(fenv, "this", obj)
            }
            v: Value = nil
            if m.right != nil do v = eval(vm, m.right, fenv)
            if vm.throwing do return // erro na init de um campo propaga
            oput(obj, class_member_key(vm, m, fenv), v)
        }
    }
}

// Nome de um membro de classe: fixo (m.name) ou COMPUTADO (`[expr]`, guardado
// em m.left pelo parser; avaliado no env dado). Desvio menor da spec: chaves
// computadas de CAMPO são reavaliadas por instância (a spec avalia 1× na
// definição da classe) — irrelevante p/ chaves puras (strings/símbolos).
@(private = "file")
class_member_key :: proc(vm: ^Interp, m: ^Node, env: ^Env) -> string {
    if m.name != "" || m.left == nil do return m.name
    return key_string(vm, eval(vm, m.left, env))
}

// eval de `class`: monta a função-construtora + o objeto prototype (que segura
// os métodos de instância). Herança = prototype.proto aponta p/ o prototype da
// superclasse; `new` liga this.proto a este prototype (ver .New).
@(private = "file")
eval_class :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    super_fn: ^Function
    super_proto: ^Object
    if n.callee != nil {
        if sv, ok := eval(vm, n.callee, env).(^Function); ok {
            super_fn = sv
            if sv.props != nil {
                if pv, ok2 := sv.props["prototype"].(^Object); ok2 do super_proto = pv
            }
        }
    }

    proto := new_object(vm)
    // Classe DERIVADA: o prototype dela encadeia no prototype da superclasse.
    // Classe BASE: fica com o Object.prototype que new_object já ligou (spec:
    // %Object.prototype% é o [[Prototype]] do prototype de uma classe sem extends).
    // Atribuir super_proto incondicionalmente ZERAVA a cadeia da classe base —
    // `new A() instanceof Object` dava false e o isPlainObject do Redux confundia
    // instância de classe com objeto simples.
    if super_proto != nil do proto.proto = super_proto

    // ESCOPO DA CLASSE: o nome (declaração OU expressão nomeada) fica visível p/
    // os métodos/campos via closure SEM depender do escopo externo — spec: numa
    // class expression (`un=class e{}`) o nome NÃO existe fora do corpo. O valor
    // é preenchido assim que o ctor existe (métodos capturam cenv por referência).
    cenv := env
    if n.name != "" do cenv = new_env(vm, env)

    ctor: ^Function
    for m in n.body {
        if m.kind != .Func do continue // campos (.ClassField) tratados à parte
        if m.name == "constructor" {
            ctor = build_method(vm, m, cenv, super_fn, super_proto)
        } else if !m.stat {
            fn := build_method(vm, m, cenv, super_fn, super_proto)
            key := class_member_key(vm, m, env) // fixa ou computada [expr]
            switch m.acc {
            case 1: // getter de instância → getters do prototype (get_member sobe a cadeia)
                if proto.getters == nil do proto.getters = make(map[string]^Function)
                proto.getters[key] = fn
            case 2: // setter de instância → setters do prototype
                if proto.setters == nil do proto.setters = make(map[string]^Function)
                proto.setters[key] = fn
            case: // método normal
                proto.props[key] = fn
            }
            // membro de classe é NÃO-enumerável (spec §15.7.14): `Object.keys(C.prototype)`
            // vem vazio no navegador. Só passou a ser expressável com o mapa de atributos.
            mark_non_enumerable(proto, key)
        }
    }
    if ctor == nil {
        // construtor default: vazio; se deriva, encaminha os args ao super
        ctor = new_function(vm)
        ctor.name = n.name
        ctor.closure = cenv
        env_escaped(vm)
        ctor.super_ctor = super_fn
        ctor.auto_super = super_fn != nil
    }
    // nome da classe visível p/ os métodos (closures capturaram cenv por referência)
    if n.name != "" do env_define(cenv, n.name, ctor)
    ctor.class_node = n // campos de instância são inicializados no `new` (init_instance_fields)
    if ctor.props == nil do ctor.props = make(map[string]Value)
    ctor.props["prototype"] = proto
    // back-reference `Classe.prototype.constructor === Classe` (invariante do spec):
    // `instancia.constructor` sobe a cadeia até aqui. Sem isto, código transpilado
    // (Babel `_inherits`, detecção de tipo via obj.constructor.prototype) lê undefined
    // e quebra o bundle inteiro — sintoma "reading 'prototype' of undefined" que
    // deixava tradebig/google em branco. Não-enumerável (não aparece em for-in/keys).
    proto.props["constructor"] = ctor
    mark_non_enumerable(proto, "constructor")

    // Membros STATIC vão na própria construtora, em DUAS FASES — é o que a spec
    // manda (ClassDefinitionEvaluation): TODOS os métodos são instalados antes de
    // QUALQUER inicializador de campo rodar.
    //
    // ⚠️ antes era uma passada só, em ordem de fonte, e por isso um campo não
    // enxergava método declarado DEPOIS dele:
    //     class V { static BLACK = V.fromRGB({r:0}); static fromRGB(e){…} }
    // Isso é exatamente o que o open.spotify.com faz na classe de cor, e dava
    // `TypeError: v.fromRGB is not a function` (ver [[real-site-fidelity]] M180).
    //
    // FASE 1 — métodos/acessores estáticos.
    for m in n.body {
        if !m.stat || m.kind != .Func do continue
        if m.name == "constructor" do continue
        fn := build_method(vm, m, cenv, super_fn, super_proto)
        key := class_member_key(vm, m, env)
        switch m.acc {
        case 1: // getter static → getters da própria construtora (get_member ^Function)
            if ctor.getters == nil do ctor.getters = make(map[string]^Function)
            ctor.getters[key] = fn
        case 2:
            if ctor.setters == nil do ctor.setters = make(map[string]^Function)
            ctor.setters[key] = fn
        case:
            ctor.props[key] = fn
        }
    }
    // FASE 2 — campos e blocos static, em ORDEM DE FONTE entre si (a spec avalia
    // ClassStaticBlock e campo static na ordem em que aparecem, e um campo enxerga
    // o valor dos anteriores).
    for m in n.body {
        if !m.stat do continue
        #partial switch m.kind {
        case .ClassField:
            senv := new_env(vm, cenv) // cenv: o nome da classe já visível na cadeia
            env_define(senv, "this", ctor) // `this` num campo static é a própria classe
            v: Value = nil
            if m.right != nil do v = eval(vm, m.right, senv)
            if vm.throwing do return nil
            ctor.props[class_member_key(vm, m, senv)] = v
        case .StaticBlock:
            senv := new_env(vm, cenv)
            env_define(senv, "this", ctor) // `this` no bloco static é a própria classe
            if m.right != nil do eval(vm, m.right, senv) // roda os statements do bloco
            if vm.throwing do return nil
        }
    }

    val: Value = ctor
    // Só DECLARAÇÕES bindam o nome fora; expressão nomeada fica restrita ao cenv
    // (spec) — `un=class e{}` vazando `e` clobberava o import binding do sveltekit.
    if n.name != "" && n.decl do env_define(env, n.name, val)
    return val
}

// Trata chamadas envolvendo `super` dentro de métodos de classe:
//   super(args)         -> chama a construtora da superclasse com o `this` atual
//   super.metodo(args)  -> chama metodo herdado, mas com o `this` atual
// __superctor__/__superproto__ são ligados no escopo por call_function.
@(private = "file")
try_eval_super_call :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> (result: Value, handled: bool) {
    c := n.callee
    this_val, _ := env_get(env, "this")

    // super(...)
    if c.kind == .Ident && c.name == "super" {
        sc, _ := env_get(env, "__superctor__")
        fn, ok := sc.(^Function)
        if !ok do return nil, true // sem superclasse: no-op silencioso
        args := eval_args(vm, n.body, env)
        defer delete(args)
        return super_construct(vm, fn, this_val, args[:]), true
    }

    // super.metodo(...)
    if c.kind == .Member && c.left.kind == .Ident && c.left.name == "super" {
        sp, _ := env_get(env, "__superproto__")
        base, ok := sp.(^Object)
        if !ok do return nil, true
        fn, fok := get_member(vm, base, c.name).(^Function)
        if !fok do return nil, true
        args := eval_args(vm, n.body, env)
        defer delete(args)
        return call_function(vm, fn, this_val, args[:]), true // this = objeto atual
    }

    return nil, false
}

// Leitura de `super.prop` (fora de chamada): procura na cadeia do prototype da
// superclasse; um GETTER herdado roda com this = o objeto ATUAL (spec), por
// isso não dá p/ reusar o get_member (que passaria o próprio proto como this).
@(private = "file")
eval_super_member :: proc(vm: ^Interp, name: string, env: ^Env) -> Value {
    sp, _ := env_get(env, "__superproto__")
    base, ok := sp.(^Object)
    if !ok do return nil // fora de método de classe derivada
    this_val, _ := env_get(env, "this")
    for cur := base; cur != nil; cur = cur.proto {
        if cur.getters != nil {
            if g, gok := cur.getters[name]; gok do return call_function(vm, g, this_val, nil)
        }
        if v, vok := cur.props[name]; vok do return v
    }
    return nil
}

// Descreve textualmente o nó de um callee/construtor para a mensagem de
// TypeError ("X is not a function/constructor"). Reconstrói a cadeia de acesso
// (obj.prop, obj.prop[k], obj[k]) para que APIs faltantes se identifiquem pelo
// nome — antes o `.Index` e expressões caíam num genérico "expressão" (M60).
@(private = "file")
describe_callee :: proc(n: ^Node) -> string {
    if n == nil do return "(intermediate value)"
    #partial switch n.kind {
    case .Ident:
        return n.name
    case .Member:
        return fmt.tprintf("%s.%s", describe_callee(n.left), n.name)
    case .Index:
        // chave literal string vira acesso por ponto legível; caso contrário [...].
        // Índice pode ser sequência (obj[a, b, 'k']): a chave efetiva é o último.
        key := n.right
        for key != nil && key.kind == .Seq do key = key.right
        if key != nil && key.kind == .Str {
            return fmt.tprintf("%s.%s", describe_callee(n.left), key.str)
        }
        return fmt.tprintf("%s[...]", describe_callee(n.left))
    case .Call:
        return fmt.tprintf("%s(...)", describe_callee(n.callee))
    }
    return "(intermediate value)"
}

// Constrói uma instância a partir de uma função construtora (usado por `new` E
// por Reflect.construct). Nativas constroem e devolvem; funções de usuário criam
// o objeto, ligam o prototype, inicializam campos e rodam o corpo (retorno-objeto
// explícito vence).
// ── subclasse de builtin (M136) ──────────────────────────────────────────────
//
// `class X extends Map/Set/Array/Error` era um beco: a instância é um ^Object
// comum, e Map/Array são variantes PRÓPRIAS da união Value — nunca um ^Object.
// Então `x.set(...)` batia em "called on incompatible receiver" e `extends Array`
// perdia push/length. Erro custoso na prática: toda biblioteca que define erro
// próprio faz `class Xerr extends Error`, e a mensagem sumia.
//
// A saída é a mesma da spec (slots internos) e a mesma que já usamos p/ TypedArray
// (`ab`/`ta_*`) e generator (`gen`): a instância continua um ^Object de verdade —
// com props, cadeia de protótipo, campos de classe — e o valor exótico que o
// `super()` construiu fica no slot `prim`.
//
// Duas formas de adoção, conforme o builtin:
//   ^Object (Error e afins) → COPIA as props (message/stack/cause) p/ o `this`,
//       que já tem o prototype certo da subclasse.
//   exótico (^Collection/^Array/^Regex) → guarda em `this.prim`.
super_construct :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    ret := call_function(vm, fn, this, args)
    if vm.throwing do return ret
    o, ok := this.(^Object)
    if !ok do return ret
    #partial switch r in ret {
    case ^Object:
        if r == o do return ret // já escreveu direto no this
        for k in r.korder {
            if v, vok := r.props[k]; vok do oput(o, k, v)
        }
        for k, v in r.props {
            if _, seen := o.props[k]; !seen do oput(o, k, v)
        }
    case ^Collection, ^Array, ^Regex:
        o.prim = ret
    }
    return ret
}

// Uma nativa que É método do builtin embrulhado recebe o valor exótico como
// `this`; qualquer outra (hasOwnProperty, toString de Object, métodos do DOM…)
// continua recebendo o próprio ^Object. Sem esse recorte, `sub.hasOwnProperty(x)`
// passaria a inspecionar o ^Collection interno em vez da instância.
@(private = "file")
unwrap_prim :: proc(vm: ^Interp, fn: ^Function, this: Value) -> Value {
    o, ok := this.(^Object)
    if !ok || o.prim == nil do return this
    #partial switch _ in o.prim {
    case ^Collection: for _, m in vm.collection_methods do if m == fn do return o.prim
    case ^Array:      for _, m in vm.array_methods      do if m == fn do return o.prim
    }
    return this
}

// new_target != nil só via Reflect.construct(alvo, args, newTarget): o corpo que
// roda é o do `fn`, mas o prototype da instância e o `new.target` vêm do newTarget.
construct_object :: proc(vm: ^Interp, fn: ^Function, args: []Value, new_target: ^Function = nil) -> Value {
    if fn.native != nil {
        // nativas (Error, TypeError, Proxy, ...) constroem e devolvem o objeto.
        // `fn.bound` tem de ficar visível TAMBÉM aqui: este caminho chama a
        // nativa DIRETO, sem passar pelo call_function que normalmente publica o
        // native_bound. Sem isto, uma nativa construtora que carrega estado em
        // bound (o Intl usa p/ levar o próprio prototype) enxerga nil sob `new` e
        // funciona só quando chamada sem `new` — assimetria silenciosa.
        saved_bound := vm.native_bound
        vm.native_bound = fn.bound
        ret := fn.native(vm, nil, args)
        vm.native_bound = saved_bound
        // `Reflect.construct(Error, [msg], MinhaErro)` tem que sair com o prototype
        // da subclasse — senão o instanceof mente.
        if nt := new_target; nt != nil {
            if o, ok := ret.(^Object); ok {
                if p, pok := get_member(vm, nt, "prototype").(^Object); pok do o.proto = p
            }
        }
        return ret
    }
    obj := new_object(vm)
    // liga a cadeia de protótipo ANTES de rodar o construtor (this.metodo()/super
    // já funcionam lá dentro). get_member cria o .prototype sob demanda p/ funções
    // comuns (ex.: `Ctor.prototype.m = fn` + `new Ctor()`), não só classes.
    proto_src: ^Function = new_target if new_target != nil else fn
    if proto, pok := get_member(vm, proto_src, "prototype").(^Object); pok do obj.proto = proto
    // campos de instância (class fields) são inicializados ANTES do corpo do
    // construtor — semântica de classe base; deriva percorre a cadeia super.
    init_instance_fields(vm, fn, obj)
    if vm.throwing do return nil
    vm.pending_new_target = proto_src // new.target = o construtor (ou o newTarget do Reflect)
    ret := call_function(vm, fn, obj, args)
    // [[Construct]] da spec: se o corpo retorna um OBJETO, ele substitui o `this`
    // recém-criado (retorno primitivo é ignorado). Antes só ^Object/^Array
    // contavam — um construtor que devolvia ^Collection/^Function/^Regex tinha o
    // retorno DESCARTADO. O core-js embrulha `Map`/`Set` num construtor JS que faz
    // `return new NativeMap()` (^Collection): sem isto, `new Map()` devolvia o
    // ^Object vazio (proto=Map.prototype) e `.set()` batia num receiver que não é
    // ^Collection → "Map.prototype.set called on incompatible receiver" (globo/etc).
    #partial switch _ in ret {
    case ^Object, ^Array, ^Function, ^Regex, ^Collection:
        return ret
    }
    return obj
}

// Avalia uma chamada, determinando `this` quando o callee é obj.metodo().
@(private = "file")
eval_call :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    // super(...) e super.metodo(...) dentro de um método de classe
    if res, handled := try_eval_super_call(vm, n, env); handled do return res
    this_val: Value = nil
    fn_val: Value = nil

    #partial switch n.callee.kind {
    case .Member:
        obj := eval(vm, n.callee.left, env)
        if vm.throwing do return nil
        if vm.opt_short do return nil // um `?.` anterior curto-circuitou → pula a chamada
        if n.callee.bval && is_nullish(obj) { vm.opt_short = true; return nil } // a?.m()
        when #config(MEMBERPROBE, false) {
            if is_nullish(obj) {
                fmt.eprintfln("[callprobe] %s é undefined ao chamar '%s'", describe_callee(n.callee.left), n.callee.name)
                // Se a base é um ÍNDICE (`registro[id].call(...)` — o corpo do
                // __webpack_require__), dizer QUAL chave faltou e o que o registro
                // tem: distingue "chave convertida errado" de "módulo nunca
                // registrado" (chunk que não carregou), que exigem fixes opostos.
                if n.callee.left.kind == .Index {
                    base := eval(vm, n.callee.left.left, env)
                    k    := eval(vm, n.callee.left.right, env)
                    sb: strings.Builder
                    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
                    to_text(&sb, k)
                    fmt.eprintfln("           └─ chave pedida: %q", strings.to_string(sb))
                    if o, ok := base.(^Object); ok {
                        n_keys := len(o.props)
                        fmt.eprintfln("           └─ registro: objeto com %d chaves", n_keys)
                        i := 0
                        for kk, _ in o.props {
                            if i >= 5 do break
                            fmt.eprintfln("               ex: %q", kk)
                            i += 1
                        }
                    } else {
                        fmt.eprintfln("           └─ registro NÃO é objeto: %v", base)
                    }
                }
            }
        }
        this_val = obj
        fn_val = get_member(vm, obj, n.callee.name)
    case .Index:
        obj := eval(vm, n.callee.left, env)
        if vm.throwing do return nil
        if vm.opt_short do return nil
        if n.callee.bval && is_nullish(obj) { vm.opt_short = true; return nil } // a?.[k]()
        key := eval(vm, n.callee.right, env)
        this_val = obj
        fn_val = get_index(vm, obj, key)
    case:
        fn_val = eval(vm, n.callee, env)
        if vm.opt_short do return nil // o próprio callee era uma cadeia que curto-circuitou
        if vm.throwing do return nil
        // eval DIRETO: só a forma sintática `eval(...)` (identificador literal `eval`
        // resolvendo p/ o builtin) roda no ESCOPO ATUAL — vê e altera locais. Qualquer
        // outra forma ((0,eval)(x), var e=eval; e(x), obj.eval(x)) é INDIRETA e cai no
        // native, que roda no escopo global. Distinção exigida pela spec (§19.2.1.1).
        if n.callee.kind == .Ident && n.callee.name == "eval" && vm.eval_fn != nil {
            if rf, rok := fn_val.(^Function); rok && rf == vm.eval_fn {
                eargs := eval_args(vm, n.body, env)
                defer delete(eargs)
                if vm.throwing do return nil
                return do_eval(vm, len(eargs) > 0 ? eargs[0] : nil, env)
            }
        }
    }
    if vm.throwing do return nil

    fn, ok := fn_val.(^Function)
    if !ok {
        if vm.throwing do return nil          // o get_member já lançou (ex.: null.f())
        if n.bval && is_nullish(fn_val) { vm.opt_short = true; return nil } // a?.() → undefined + propaga
        // TypeError nomeado — diagnóstico honesto de API faltante (era undefined
        // silencioso, que mascarava bugs como o BetterAuthError do M42)
        //
        // Sonda de bundle MINIFICADO (`-define:CALLPROBE=true`): "e.toLowerCase is not
        // a function" não diz nada sozinho — o que resolve é saber O QUE o receptor é.
        // Imprime o tipo e uma amostra do valor no ponto do throw.
        when #config(CALLPROBE, false) {
            kind := "?"
            switch _ in this_val {
            case f64:         kind = "number"
            case bool:        kind = "boolean"
            case string:      kind = "string"
            case JS_Null:     kind = "null"
            case ^Function:
                rf := this_val.(^Function)
                kind = fmt.tprintf("function<%s>(%s) arrow=%v nativa=%v classe=%v",
                    rf.name, strings.join(rf.params[:], ","), rf.is_arrow,
                    rf.native != nil, rf.class_node != nil)
            case ^Object:     kind = "object"
            case ^Array:      kind = "array"
            case ^Regex:      kind = "regex"
            case ^Collection: kind = "collection"
            case ^Symbol:     kind = "symbol"
            case ^BigInt:     kind = "bigint"
            case:             kind = "undefined"
            }
            psb: strings.Builder
            strings.builder_init(&psb)
            to_text(&psb, this_val)
            ptxt := strings.to_string(psb)
            if len(ptxt) > 160 do ptxt = ptxt[:160]
            // A `probe_stack` (nomes das funções em execução) só é ALIMENTADA sob
            // MEMBERPROBE — buildar com os dois defines quando o nome do módulo não
            // bastar (callback definido no módulo A e chamado de dentro do B).
            // nomes visíveis nos 3 escopos mais internos — impressão digital do
            // trecho de fonte quando o nome minificado da função não basta
            esc: strings.Builder
            strings.builder_init(&esc)
            {
                cur := env
                for lvl := 0; cur != nil && lvl < 3; lvl += 1 {
                    fmt.sbprintf(&esc, "{{")
                    first := true
                    for k in cur.vars {
                        if !first do fmt.sbprintf(&esc, ",")
                        fmt.sbprintf(&esc, "%s", k); first = false
                    }
                    fmt.sbprintf(&esc, "}} ")
                    cur = cur.parent
                }
            }
            fmt.eprintfln("[callprobe] %s is not a function | receptor=%s valor=%s | modulo=%s | pilha=%v | escopos=%s",
                describe_callee(n.callee), kind, ptxt,
                vm.current_module != nil ? vm.current_module.url : "<fora de modulo>",
                vm.probe_stack, strings.to_string(esc))
            strings.builder_destroy(&esc)
            strings.builder_destroy(&psb)
        }
        throw_type_error(vm, fmt.tprintf("%s is not a function", describe_callee(n.callee)))
        return nil
    }

    args := eval_args(vm, n.body, env) // expande ...spread (pode conter cadeias opcionais)
    defer delete(args)
    res := call_function(vm, fn, this_val, args[:])
    vm.opt_short = false // esta chamada operou; limpa flag que args/callee possam ter deixado
    return res
}

// tag`a${x}b` (nó .Tagged: callee=tag, left=.Template). Resolve `this` de tag
// que é membro (styled.div`...`) igual ao eval_call.
@(private = "file")
eval_tagged :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    this_val: Value = nil
    fn_val: Value = nil
    #partial switch n.callee.kind {
    case .Member:
        obj := eval(vm, n.callee.left, env)
        if vm.throwing do return nil
        this_val = obj
        fn_val = get_member(vm, obj, n.callee.name)
    case .Index:
        obj := eval(vm, n.callee.left, env)
        key := eval(vm, n.callee.right, env)
        if vm.throwing do return nil
        this_val = obj
        fn_val = get_index(vm, obj, key)
    case:
        fn_val = eval(vm, n.callee, env)
    }
    if vm.throwing do return nil
    fn, ok := fn_val.(^Function)
    if !ok {
        vm.thrown = mk_error(vm, "TypeError", "tag de template não é uma função")
        vm.throwing = true
        return nil
    }
    tpl := n.left
    // tpl.params traz os N chunks COZIDOS seguidos dos N CRUS (ver Node.params).
    nchunks := len(tpl.body) + 1
    if nchunks > len(tpl.params) do nchunks = len(tpl.params)
    strs := new_array(vm)
    for i in 0 ..< nchunks do append(&strs.items, own_str(vm, tpl.params[i]))
    // strings.raw: array PRÓPRIO, sem escapes decodificados. Era um ALIAS do array
    // cozido, e por isso String.raw`a\nb` devolvia a quebra de linha de verdade em
    // vez de "a\nb" — justamente o único motivo de String.raw existir.
    raws := new_array(vm)
    if len(tpl.params) >= nchunks * 2 {
        for i in 0 ..< nchunks do append(&raws.items, own_str(vm, tpl.params[nchunks + i]))
    } else {
        // defensivo (parse com recuperação): entrega os cozidos em vez de um array
        // de tamanho diferente — o lit-html valida `strings.raw.length`.
        for it in strs.items do append(&raws.items, it)
    }
    strs.props = make(map[string]Value)
    strs.props["raw"] = raws
    args: [dynamic]Value
    defer delete(args)
    append(&args, strs)
    for e in tpl.body {
        v := eval(vm, e, env)
        if vm.throwing do return nil
        append(&args, v)
    }
    return call_function(vm, fn, this_val, args[:])
}

// Roda o corpo de um generator (na thread do generator; chamado por gen_thread_proc
// em generator.odin). Mesmo setup de call_function via setup_call_scope; os sinais
// pendentes ao terminar (return/throw/fim) são traduzidos pela thread.
run_generator_body :: proc(vm: ^Interp, g: ^Generator) {
    fn := g.fn
    scope := setup_call_scope(vm, fn, g.this, g.args)
    if fn.body != nil {
        hoist_functions(vm, fn.body.body[:], scope)
        hoist_vars_body(fn.body.body[:], scope) // var aninhados em blocos/switch/if/try
        for s in fn.body.body {
            if is_hoisted_func(s) do continue
            eval(vm, s, scope)
            if vm.returning || vm.throwing || vm.gen_hard_kill do break
        }
    }
}

// yield* it: delega a `it`, repassando cada valor via yield; devolve o valor final
// de retorno do iterador (undefined p/ iteráveis nativos). Em async generator,
// delega a um iterável ASSÍNCRONO (Symbol.asyncIterator), awaitando cada passo.
// SIMPLIFICAÇÃO: não encaminha next(v)/throw/return ao delegado. Cobre `yield*
// gen()`, `yield* arr`, `yield* asyncGen()`.
eval_yield_star :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    operand := eval(vm, n.left, env)
    if vm.throwing do return nil

    // async generator: `yield* asyncIter` delega a um iterável ASSÍNCRONO (ou
    // síncrono envolvido), awaitando cada passo e repassando via yield. Como o
    // caminho síncrono (M155), ENCAMINHA throw()/return()/next(v) ao delegado —
    // mas aqui cada método devolve uma Promise, então awaita o resultado.
    if vm.current_gen != nil && vm.current_gen.is_async {
        if it, ok := get_async_iterator(vm, operand); ok {
            next_fn := iterator_next_fn(it)
            if next_fn != nil {
                mode := 0            // 0=next, 1=throw, 2=return
                sent: Value = nil
                for {
                    if step_guard(vm) do break
                    r: Value
                    switch mode {
                    case 1:
                        throw_fn := iterator_method_fn(it, "throw")
                        if throw_fn == nil {
                            if ret_fn := iterator_method_fn(it, "return"); ret_fn != nil {
                                rr := call_function(vm, ret_fn, it, nil)
                                if !vm.throwing do await_blocking_throw(vm, rr) // IteratorClose
                            }
                            vm.throwing = false; vm.thrown = nil // não mascara o TypeError
                            throw_type_error(vm, "The iterator does not provide a 'throw' method")
                            return nil
                        }
                        r = call_function(vm, throw_fn, it, []Value{sent})
                    case 2:
                        ret_fn := iterator_method_fn(it, "return")
                        if ret_fn == nil {
                            vm.returning = true; vm.ret_val = sent
                            return sent
                        }
                        r = call_function(vm, ret_fn, it, []Value{sent})
                    case:
                        r = call_function(vm, next_fn, it, []Value{sent})
                    }
                    if vm.throwing do return nil
                    r = await_blocking_throw(vm, r) // método de async iterator devolve Promise
                    if vm.throwing do return nil
                    ro, rok := r.(^Object)
                    if !rok do break
                    if truthy(ro.props["done"]) {
                        if mode == 2 {
                            vm.returning = true; vm.ret_val = ro.props["value"]
                        }
                        return ro.props["value"] // valor de retorno do delegado
                    }
                    val := await_blocking_throw(vm, ro.props["value"])
                    if vm.throwing do return nil
                    sent = generator_yield(vm, val)
                    mode = 0
                    if vm.gen_hard_kill do return nil
                    if vm.throwing {
                        mode = 1; sent = vm.thrown
                        vm.throwing = false; vm.thrown = nil
                    } else if vm.returning {
                        mode = 2; sent = vm.ret_val
                        vm.returning = false; vm.ret_val = nil
                    }
                }
                return nil
            }
        }
        // fallback: iterável nativo síncrono (array/Collection/string) — awaita cada elemento
        vals: [dynamic]Value
        defer delete(vals)
        collect_sync_values(vm, operand, &vals)
        for v in vals {
            av := await_blocking_throw(vm, v)
            if vm.throwing do return nil
            generator_yield(vm, av)
            if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
        }
        return nil
    }

    // iterável por protocolo (outro generator, iterador custom): dirige o delegado
    // ENCAMINHANDO next(v)/throw(e)/return(v) — não só next(). É o que a spec manda
    // (YieldExpression delegate, §14.4.5.5) e o que o regenerator-runtime usa p/
    // propagar erro pela máquina de estado async: sem isto, `outer.throw(e)` sobre
    // um outer suspenso num `yield* inner()` ESCAPAVA o try/catch do inner (era o
    // cluster `(lançou undefined)` do airbnb).
    if it, ok := get_iterator(vm, operand); ok {
        next_fn := iterator_next_fn(it)
        if next_fn == nil do return nil
        mode := 0            // 0=next, 1=throw, 2=return — como o outer foi retomado
        sent: Value = nil    // valor que veio de next(v)/throw(e)/return(v)
        for {
            if step_guard(vm) do break
            r: Value
            switch mode {
            case 1:
                // outer.throw(e): encaminha a it.throw(e). Sem throw no delegado, a
                // spec manda fechar (it.return) e lançar TypeError.
                throw_fn := iterator_method_fn(it, "throw")
                if throw_fn == nil {
                    if ret_fn := iterator_method_fn(it, "return"); ret_fn != nil {
                        call_function(vm, ret_fn, it, nil) // IteratorClose (resultado ignorado)
                    }
                    throw_type_error(vm, "The iterator does not provide a 'throw' method")
                    return nil
                }
                r = call_function(vm, throw_fn, it, []Value{sent})
            case 2:
                // outer.return(v): encaminha a it.return(v). Sem return no delegado,
                // yield* completa e o RETURN segue subindo com v.
                ret_fn := iterator_method_fn(it, "return")
                if ret_fn == nil {
                    vm.returning = true; vm.ret_val = sent
                    return sent
                }
                r = call_function(vm, ret_fn, it, []Value{sent})
            case:
                r = call_function(vm, next_fn, it, []Value{sent})
            }
            if vm.throwing do return nil
            ro, rok := r.(^Object)
            if !rok do break
            if truthy(ro.props["done"]) {
                // delegado concluiu. Se veio de um return encaminhado, o RETURN do
                // outer prossegue com o value do delegado; senão é o valor de yield*.
                if mode == 2 {
                    vm.returning = true; vm.ret_val = ro.props["value"]
                }
                return ro.props["value"]
            }
            // não-done: repassa o value ao consumidor e captura a PRÓXIMA intenção
            sent = generator_yield(vm, ro.props["value"])
            mode = 0
            if vm.gen_hard_kill do return nil
            if vm.throwing {
                mode = 1; sent = vm.thrown
                vm.throwing = false; vm.thrown = nil
            } else if vm.returning {
                mode = 2; sent = vm.ret_val
                vm.returning = false; vm.ret_val = nil
            }
        }
        return nil
    }
    // iteráveis nativos: array / string (code points) / Collection
    #partial switch s in operand {
    case ^Array:
        snapshot := make([]Value, len(s.items)) // snapshot: o corpo pode mutar durante o yield
        defer delete(snapshot)
        copy(snapshot, s.items[:])
        for v in snapshot {
            generator_yield(vm, v)
            if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
        }
    case string:
        starts: [dynamic]int
        defer delete(starts)
        for _, i in s do append(&starts, i)
        append(&starts, len(s))
        for k := 0; k + 1 < len(starts); k += 1 {
            generator_yield(vm, own_str(vm, s[starts[k]:starts[k + 1]]))
            if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
        }
    case ^Collection:
        // snapshot como no ^Array acima: o consumidor pode fazer set.add() com o
        // generator suspenso → append realoca s.entries e o for leria memória liberada
        snap := make([]Coll_Entry, len(s.entries))
        defer delete(snap)
        copy(snap, s.entries[:])
        if s.kind == .Set || s.kind == .Weak_Set {
            for e in snap {
                generator_yield(vm, e.key)
                if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
            }
        } else {
            for e in snap {
                pair := new_array(vm)
                append(&pair.items, e.key); append(&pair.items, e.val)
                generator_yield(vm, pair)
                if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
            }
        }
    }
    return nil
}

// Monta o escopo de uma chamada de função definida pelo usuário: escopo filho do
// CLOSURE (não do chamador), com `this`, elos de super, params (defaults/padrões),
// rest param e o objeto `arguments`. Compartilhado por call_function e pelo runner
// de generator (generator.odin), que precisa exatamente do mesmo setup.
setup_call_scope :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value, new_target: Value = nil) -> ^Env {
    scope := new_env(vm, fn.closure)
    scope.is_fn_scope = true // fronteira p/ `var` (function-scoped)
    // new.target: só funções NÃO-arrow o vinculam; arrows herdam léxico (o lookup
    // sobe a cadeia de closures, como this). Chamada normal → nil (undefined).
    if !fn.is_arrow do scope.vars["new.target"] = new_target
    // arrow NÃO vincula `this`: o lookup sobe a cadeia de closures e encontra
    // o `this` da função envolvente — é exatamente a semântica léxica do ES6.
    if !fn.is_arrow {
        if this != nil {
            scope.vars["this"] = this
        } else {
            // Chamada SEM receptor: em sloppy mode o `this` é o objeto GLOBAL
            // (spec, OrdinaryCallBindThis). Antes NÃO vinculávamos nada, apostando
            // que o lookup cairia no `this` global — mas ele sobe a cadeia de
            // CLOSURES, então uma função plana declarada DENTRO de um método
            // herdava o `this` do método. É o bug que deixava npmjs.com em branco:
            // o webpack chama cada módulo com `this = module.exports`, e o shim de
            // global (`g = (function(){ return this })()`) capturava o exports em
            // vez de window; depois o código fazia `g.location.pathname` e morria.
            // Vincula SEMPRE, mesmo que a undefined: é o vínculo que interrompe a
            // subida pela cadeia de closures. Sem DOM (--js262) não há objeto
            // global para ser o `this` — undefined é a resposta honesta e continua
            // impedindo o vazamento.
            // vm.global_this é o window, resolvido UMA vez em install_dom (nil em JS
            // puro, sem DOM). Vincular mesmo a nil é o que INTERROMPE a subida pela
            // cadeia de closures — é o vínculo, não o valor, que corrige o bug.
            scope.vars["this"] = vm.global_this
        }
    }
    // elos de super p/ métodos de classe (super()/super.m() os leem via env_get)
    if fn.super_ctor != nil do scope.vars["__superctor__"] = fn.super_ctor
    if fn.home_super != nil do scope.vars["__superproto__"] = fn.home_super
    // function expression NOMEADA: o nome referencia a si mesma DENTRO do corpo
    // (`var f = function g(n){ return g(n-1) }`) — antes dos params (que sombreiam).
    if fn.self_bind && fn.name != "" do scope.vars[fn.name] = fn
    // objeto `arguments` (só funções não-arrow): array-like com TODOS os args.
    // React.createElement usa `arguments.length` p/ contar children — sem isto,
    // props.children nunca é populado. Um ^Array serve (tem length + índices).
    //
    // SÓ quando o corpo o menciona (fn.uses_arguments, decidido no parser). Era
    // materializado em TODA chamada: um ^Object de Array + o dynamic array dos
    // itens + a entrada no mapa do escopo, ~310 B por chamada que nada libera
    // (não há GC). Uma arrow já não o criava — era exatamente a diferença medida
    // entre 765 B/chamada (arrow) e 1077 B/chamada (função comum).
    //
    // ANTES dos params: o objeto existe desde a instanciação do escopo, então um
    // default pode lê-lo (`function f(a, b = arguments[0])`). Ficava DEPOIS do
    // laço, e nesse caso o default via `arguments` indefinido — bug pré-existente
    // que o teste do M159 destapou. Um param CHAMADO `arguments` sobrescreve
    // logo abaixo, que é a precedência certa.
    if !fn.is_arrow && fn.uses_arguments {
        argobj := new_array(vm)
        argobj.is_arguments = true // Array.isArray(arguments) === false (spec)
        for a in args do append(&argobj.items, a)
        scope.vars["arguments"] = argobj
    }
    for p, i in fn.params {
        av: Value = args[i] if i < len(args) else nil
        // default: aplica-se quando o arg é undefined (nil), avaliado no escopo
        // já com os params anteriores visíveis — `(a, b=a) => ...` funciona.
        if av == nil && fn.param_defaults != nil && i < len(fn.param_defaults) && fn.param_defaults[i] != nil {
            av = eval(vm, fn.param_defaults[i], scope)
        }
        if fn.param_pats != nil && i < len(fn.param_pats) && fn.param_pats[i] != nil {
            bind_pattern(vm, fn.param_pats[i], av, scope) // param desestruturado
        } else {
            scope.vars[p] = av
        }
    }
    // rest param: recolhe os args além dos fixos num array. O rest pode ser um
    // PADRÃO (`...[t]`), e aí o array recolhido é desestruturado nele.
    if fn.rest_param != "" || fn.rest_pat != nil {
        rest := new_array(vm)
        for j := len(fn.params); j < len(args); j += 1 do append(&rest.items, args[j])
        if fn.rest_pat != nil {
            bind_pattern(vm, fn.rest_pat, rest, scope)
        } else {
            scope.vars[fn.rest_param] = rest
        }
    }
    return scope
}

// Invoca uma função (nativa ou definida pelo usuário). Para user-defined:
// escopo filho do CLOSURE (não do chamador), liga params + `this`, roda o corpo.
call_function :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    when JSPROF { g_prof.chamadas += 1; if fn.native != nil do g_prof.chamadas_nat += 1 }
    // async function (não-generator): roda como CORROTINA — cada await suspende.
    // Precisa ser interceptado ANTES do corpo. A checagem de current_gen evita
    // reentrar quando já estamos rodando o corpo dentro da thread da corrotina.
    if fn.is_async && !fn.is_generator && fn.native == nil {
        if vm.current_gen == nil || vm.current_gen.fn != fn {
            return async_call(vm, fn, this, args)
        }
    }
    // Guarda de recursão: converte um stack-overflow nativo (fatal, fecha o
    // navegador) em RangeError capturável. defer garante o decremento mesmo
    // no caminho de erro (o unwind passa por cada call_function empilhado).
    vm.call_depth += 1
    defer vm.call_depth -= 1
    // Guarda por PONTEIRO (stack_guard.odin): mede a stack nativa realmente usada,
    // agnóstica ao tamanho do frame (React gasta muito por chamada). `stack_probe`
    // é um local — seu endereço aproxima o SP atual. call_depth fica de backstop.
    stack_probe: int
    if vm.call_depth > vm.call_depth_limit || stack_near_limit(vm, uintptr(&stack_probe)) {
        if !vm.throwing {
            when #config(MEMBERPROBE, false) {
                fmt.eprintfln("[stackprobe] estourou em fn nome='%s' nativa=%v params=%v bound=%v",
                    fn.name, fn.native != nil, fn.params, vm.native_bound)
            }
            vm.thrown = mk_error(vm, "RangeError", "profundidade de recursão excedida (Maximum call stack size exceeded)")
            vm.throwing = true
        }
        return nil
    }
    // new.target pendente (posto por construct_object): captura e limpa AQUI para
    // não vazar p/ chamadas normais aninhadas. Só o frame desta função o enxerga.
    nt_pending := vm.pending_new_target
    vm.pending_new_target = nil
    // função LIGADA (bind): usa o `this` fixado e prefixa os args ligados.
    // `new (boundFn)` ignoraria o bind_this, mas isso é raro; tratamos como chamada.
    if fn.bind_target != nil {
        combined := make([dynamic]Value, 0, len(fn.bind_args) + len(args))
        defer delete(combined)
        for v in fn.bind_args do append(&combined, v)
        for v in args do append(&combined, v)
        return call_function(vm, fn.bind_target, fn.bind_this, combined[:])
    }
    if fn.native != nil {
        // expõe fn.bound à nativa via vm.native_bound (save/restore = reentrante)
        saved := vm.native_bound
        vm.native_bound = fn.bound
        ret := fn.native(vm, unwrap_prim(vm, fn, this), args)
        vm.native_bound = saved
        return ret
    }
    // generator (function*): chamar NÃO roda o corpo — devolve um objeto generator
    // cujo .next() dirige o corpo numa thread própria em ping-pong (generator.odin).
    if fn.is_generator {
        return make_generator(vm, fn, this, args)
    }
    when #config(MEMBERPROBE, false) {
        // nome + PARÂMETROS: em bundle minificado o nome sozinho ("r", "a") não
        // identifica a função; a aridade e os nomes dos params sim (grepáveis).
        append(&vm.probe_stack, fmt.tprintf("%s(%s)", fn.name, strings.join(fn.params[:], ",")))
        defer pop(&vm.probe_stack)
    }
    // Reciclagem do escopo desta chamada. `env_mark` delimita tudo que nascer a
    // partir daqui (o escopo da chamada mais os escopos de bloco/laço do corpo);
    // `esc_mark` fotografa o contador de escapes. Se ao sair o contador não mudou,
    // nada que nasceu aqui pode ser alcançado depois — devolve tudo ao pool.
    // Sem isto cada chamada deixava ~1 KB para trás em definitivo (não há GC), o
    // que fazia um bundle de SPA consumir gigabytes só de escopos mortos.
    // Vale também no caminho de exceção: o valor lançado é um ^Object, não um Env.
    env_mark := len(vm.all_envs)
    esc_mark := vm.env_escapes
    defer { if vm.env_escapes == esc_mark do recycle_envs(vm, env_mark) }
    scope := setup_call_scope(vm, fn, this, args, nt_pending)
    // construtor default de classe derivada: encaminha os args ao super
    if fn.auto_super && fn.super_ctor != nil {
        super_construct(vm, fn.super_ctor, this, args)
    }
    if fn.body != nil {
        hoist_functions(vm, fn.body.body[:], scope) // declarações do corpo içadas
        hoist_vars_body(fn.body.body[:], scope)     // var aninhados em blocos/switch/if/try
        for s in fn.body.body {
            if is_hoisted_func(s) do continue // já içada
            eval(vm, s, scope)
            if vm.returning || vm.throwing do break
        }
    }
    ret: Value = nil
    if vm.returning {
        ret = vm.ret_val
        vm.returning = false
        vm.ret_val = nil
    }
    // break/continue não atravessam a fronteira de função (seria erro de
    // sintaxe no JS real; aqui apenas os descartamos). `throwing` atravessa:
    // é o chamador (try/catch ou o topo) que trata.
    vm.breaking = false
    vm.continuing = false
    vm.break_label = ""
    vm.continue_label = ""
    vm.pending_label = ""

    // async: o retorno vira Promise cumprida; um throw vira Promise REJEITADA
    // (não propaga como exceção). Como o await é bloqueante, quando o corpo
    // termina tudo já assentou — a promise devolvida nunca fica pendente.
    if fn.is_async {
        p := promise_new(vm)
        if vm.throwing {
            vm.throwing = false
            thrown := vm.thrown
            vm.thrown = nil
            promise_settle(vm, p, PROMISE_REJECTED, thrown)
        } else {
            promise_resolve_with(vm, p, ret)
        }
        return p
    }
    return ret
}

// Loga e limpa uma exceção que chegou ao topo sem catch. Chamado nos pontos de
// entrada (vm_run, dispatch_event, vm_pump_timers) para o vm não ficar
// "envenenado" — o próximo script/evento roda normalmente.
UNCAUGHT_LOG_MAX :: 64

// Profundidade de `typeof` em curso — só existe sob MEMBERPROBE, para a sonda
// [unresolved] separar leitura NUA de detecção de feature (`typeof WeakRef`).
when #config(MEMBERPROBE, false) { g_probe_in_typeof: int }

// Registra uma REJEIÇÃO de promise que ninguém tratou. Chamado quando o corpo de uma
// corrotina async escapa com exceção (generator.odin). Sem isto o erro é invisível:
// não é "uncaught" (virou rejeição) e não passa pelo console.
vm_note_rejection :: proc(vm: ^Interp, err: Value) {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    describe_thrown(&sb, vm, err) // mesma legibilidade das uncaught
    vm.rejected_total += 1
    if len(vm.rejected_log) < UNCAUGHT_LOG_MAX {
        append(&vm.rejected_log, strings.clone(strings.to_string(sb)))
    }
}

// Descreve um valor LANÇADO de forma útil no relatório. `to_text` sozinho devolve
// "[object Object]" para qualquer objeto sem name+message e "undefined" para nil —
// e era isso que 13 sites do corpus reportavam, tornando o erro ilegível e o peel
// impossível. Aqui um não-Error vira uma prévia com chaves e valores.
describe_thrown :: proc(sb: ^strings.Builder, vm: ^Interp, v: Value) {
    #partial switch x in v {
    case ^Object:
        // Error-like (name+message): to_text já formata "Name: message"
        _, has_name := x.props["name"]
        _, has_msg  := x.props["message"]
        if has_name && has_msg {
            to_text(sb, v)
            return
        }
        strings.write_string(sb, "(objeto lançado) {")
        n := 0
        for k in x.korder {
            pv, alive := x.props[k]
            if !alive do continue
            if n >= 6 { strings.write_string(sb, ", …"); break }
            if n > 0 do strings.write_string(sb, ", ")
            strings.write_string(sb, k)
            strings.write_string(sb, ": ")
            #partial switch pvv in pv {
            case ^Object:     strings.write_string(sb, "{…}")
            case ^Array:      strings.write_string(sb, "[…]")
            case ^Function:   strings.write_string(sb, "fn")
            case string:
                s := pvv
                if len(s) > 40 do s = s[:40]
                strings.write_byte(sb, '"'); strings.write_string(sb, s); strings.write_byte(sb, '"')
            case: to_text(sb, pv)
            }
            n += 1
        }
        if n == 0 do strings.write_string(sb, "sem propriedades próprias")
        strings.write_string(sb, "}")
    case ^Array:
        fmt.sbprintf(sb, "(array lançado, %d itens)", len(x.items))
    case ^Function:
        fmt.sbprintf(sb, "(função lançada: %s)", x.name == "" ? "anônima" : x.name)
    case JS_Null:
        strings.write_string(sb, "(lançou null)")
    case string:
        fmt.sbprintf(sb, "(string lançada) %s", x)
    case:
        if v == nil {
            strings.write_string(sb, "(lançou undefined)")
        } else {
            to_text(sb, v)
        }
    }
}

vm_clear_uncaught :: proc(vm: ^Interp) {
    if !vm.throwing do return
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    describe_thrown(&sb, vm, vm.thrown)
    msg := strings.to_string(sb)
    fmt.eprintfln("[js] exceção não capturada: %s", msg)
    vm.uncaught_total += 1
    if len(vm.uncaught_log) < UNCAUGHT_LOG_MAX do append(&vm.uncaught_log, strings.clone(msg))
    vm.throwing = false
    vm.thrown = nil
}

// ── pipeline público ────────────────────────────────────────────────────────

// Prepara o escopo global e os builtins nativos. Compartilhado por run() e
// run_with_dom() (que adiciona ainda os bindings de DOM).
vm_init :: proc(vm: ^Interp) {
    vm.global = new_env(vm, nil)
    vm.global.is_fn_scope = true // topo: `var` global binda aqui
    vm.step_limit = STEP_LIMIT
    vm.call_depth_limit = CALL_DEPTH_LIMIT
    vm.time_budget_ms = g_time_budget_ms // default TIME_BUDGET_MS; ver --js-timeout
    refresh_stack_limit(vm) // valor inicial; cada tarefa re-lê p/ a thread corrente
    reset_task_clock(vm)
    vm.listeners = make(map[rawptr][dynamic]Listener)
    vm.owned_nodes = make(map[rawptr]bool)

    vm.console_log_fn = new_function(vm)
    vm.console_log_fn.native = native_log
    vm.console_log_fn.name = "log"

    vm.fn_call_fn  = new_function(vm); vm.fn_call_fn.native  = native_fn_call;  vm.fn_call_fn.name  = "call"
    vm.fn_apply_fn = new_function(vm); vm.fn_apply_fn.native = native_fn_apply; vm.fn_apply_fn.name = "apply"
    vm.fn_bind_fn  = new_function(vm); vm.fn_bind_fn.native  = native_fn_bind;  vm.fn_bind_fn.name  = "bind"
    vm.fn_tostring_fn = new_function(vm); vm.fn_tostring_fn.native = native_fn_tostring; vm.fn_tostring_fn.name = "toString"

    // `console` é um objeto de verdade (fim do caso especial do M3).
    console_obj := new_object(vm)
    console_obj.props["log"] = vm.console_log_fn
    console_obj.props["info"]  = vm.console_log_fn
    console_obj.props["debug"] = vm.console_log_fn
    console_obj.props["trace"] = vm.console_log_fn
    err_fn := new_function(vm); err_fn.native = native_error; err_fn.name = "error"
    warn_fn := new_function(vm); warn_fn.native = native_warn; warn_fn.name = "warn"
    console_obj.props["error"] = err_fn
    console_obj.props["warn"]  = warn_fn
    // no-ops comuns que bundles chamam (não devem virar undefined-call)
    noop_fn := new_function(vm); noop_fn.native = native_noop; noop_fn.name = "noop"
    for k in ([]string{"group", "groupEnd", "groupCollapsed", "table", "dir", "count", "time", "timeEnd", "assert"}) {
        console_obj.props[k] = noop_fn
    }
    env_define(vm.global, "console", console_obj)

    install_builtins(vm) // Array/String methods, Math, parseInt, ... (builtins.odin)
    install_promise(vm)  // Promise/then/catch (promise.odin)
    install_fetch(vm)    // fetch() assíncrono (fetch.odin)
}

// ── VM persistente ───────────────────────────────────────────────────────────
// Ao contrário de run(), o vm vive entre chamadas. Isso é o que permite que um
// handler de evento (uma ^Function/closure com um ^Node de corpo) continue
// válido e possa ser disparado em frames futuros. O vm passa a ser DONO das
// fontes e das ASTs.

vm_create :: proc() -> ^Interp {
    vm := new(Interp)
    vm_init(vm)
    return vm
}

vm_free :: proc(vm: ^Interp) {
    if vm == nil do return
    vm_destroy(vm)
    free(vm)
}

// Compila e executa `src` no vm. Clona a fonte e retém a AST (um handler guarda
// um ^Node do corpo — não pode ser liberado antes do vm).
vm_run :: proc(vm: ^Interp, src: string) -> Value {
    mo_task_enter(vm)     // tarefa de JS: a entrega de MutationRecords sai no exit
    v := vm_exec(vm, src)
    vm_clear_uncaught(vm) // throw sem catch: loga e não envenena o próximo run
    mo_task_exit(vm)
    return v
}

// Roda um <script type="module"> com escopo de topo PRÓPRIO (filho do global).
// Cada módulo ES tem seu próprio escopo na spec: declarações top-level
// (let/const/function/var) NÃO viram globais nem colidem entre módulos. Sem isto,
// um `let r` de um módulo sobrescrevia o `function r` de outro rodado antes
// (famososbr: "TypeError: r is not a function" ao disparar o handler). Referências
// livres ainda sobem a cadeia até o global (window/document e o que scripts
// clássicos definiram); `window.X = …` continua publicando no global.
// `url` (M109): URL absoluta do script (src externo) ou "" (inline → base_url).
// É o referrer p/ imports estáticos/dinâmicos do módulo e o import.meta.url.
vm_run_module :: proc(vm: ^Interp, src: string, url := "") -> Value {
    mo_task_enter(vm) // idem vm_run: tarefa de JS
    menv := new_env(vm, vm.global)
    menv.is_fn_scope = true // top-level `var`/hoist bindam AQUI (escopo do módulo)
    // dá referrer + import.meta + destino p/ os exports.
    m := new(Module)
    m.url = strings.clone(url != "" ? url : vm.base_url)
    m.ns = new_object(vm)
    m.env = menv
    m.state = .Loading
    module_bind_ns_live(m) // idem load_module: ns vivo desde antes do corpo
    env_escaped(vm) // idem module.odin: o escopo do módulo sobrevive à chamada
    append(&vm.all_modules, m)
    // REGISTRA no registry, antes do corpo: um `<script type="module" src=U>` É o
    // módulo U, não um script anônimo. Fora do registry, todo `import` daquela mesma
    // URL virava fetch+avaliação NOVOS — e o rspack emite, no fim de cada bundle,
    // um AUTO-IMPORT (`import * as C from "./este-mesmo-arquivo.js"; e.C(C)`). Efeito
    // medido no github.com: os 8 bundles de entrada baixados e avaliados 2× (inclusive
    // o landing-pages de 2,6 MB), e quando a 2ª avaliação lançava o `import * as`
    // bindava undefined → `Cannot read properties of undefined (reading
    // '__rspack_esm_ids')`. Registrado, o auto-import vira ciclo: cache hit em
    // .Loading com o namespace VIVO (M139/M206), e o `import "./wp-runtime.js"` dos
    // outros bundles acha o runtime que já rodou em vez de instanciar um segundo.
    // ⚠️ só com `src` EXTERNO (url != ""): um módulo INLINE não tem URL própria — a
    // dele é a do documento, e registrar o documento como módulo criaria uma entrada
    // que nenhum especificador deveria alcançar.
    // ⚠️ não sobrescreve entrada existente: a chave é `m.url`, owned por m, e o
    // destroy libera cada url uma única vez via all_modules.
    if url != "" {
        if _, dup := vm.modules[m.url]; !dup do vm.modules[m.url] = m
    }
    prev := vm.current_module
    vm.current_module = m
    saved_short := vm.opt_short // fronteira de módulo: sinais transientes não vazam
    vm.opt_short = false
    v := vm_exec(vm, src, menv)
    vm.opt_short = saved_short
    vm.returning = false
    vm.breaking = false
    vm.continuing = false
    module_snapshot_exports(vm, m)
    m.state = vm.throwing ? .Failed : .Done
    vm.current_module = prev
    vm_clear_uncaught(vm)
    mo_task_exit(vm)
    return v
}

// Igual a vm_run mas NÃO limpa a exceção pendente — o chamador inspeciona
// vm.throwing/vm.thrown e decide o que fazer. Usado pelo runner do Test262
// (js262.odin), que precisa saber SE e O QUE o teste lançou.
// Exposto ao pacote: o UPGRADE de custom element (dom_bindings) precisa inicializar
// os campos de classe sem passar por construct_object — o elemento já existe, só o
// construtor é que roda depois. Sem isto todo `campo = valor` da classe fica
// undefined (era o que quebrava o Lit: `this.renderOptions` undefined).
vm_init_instance_fields :: proc(vm: ^Interp, fn: ^Function, obj: ^Object) {
    init_instance_fields(vm, fn, obj)
}

// Compila `src` no escopo GLOBAL e devolve o valor de completude. É o motor do
// construtor `Function` (código gerado em runtime). Difere de vm_exec em dois
// pontos deliberados: (1) NÃO reseta os contadores do watchdog — é chamado de
// DENTRO de código já em execução, e zerar vm.steps ali daria fôlego infinito a um
// laço que chamasse Function() a cada volta; (2) não mexe em parse_recoveries, que
// mede a qualidade do parse do SITE, não de fonte que nós mesmos montamos.
// A posse de fonte/AST/strings vai para o vm, igual a vm_exec.
vm_eval_source_global :: proc(vm: ^Interp, src: string) -> Value {
    return vm_eval_source_in(vm, src, vm.global)
}

// Núcleo do eval/Function(): tokeniza, parseia e avalia `src` no ENV dado,
// devolvendo o VALOR DE CONCLUSÃO (o .Program devolve o valor do último statement
// — é a semântica de completion do eval). NÃO zera vm.steps/relógio (roda DENTRO
// de código já em execução; zerar daria fôlego infinito a um laço que chamasse
// eval a cada volta). Posse de fonte/AST/strings vai p/ o vm.
// ⚠️ Erro de sintaxe: nosso parser RECUPERA em silêncio em vez de lançar, então
// `eval("(")` roda o que parseou (best-effort) em vez de lançar SyntaxError — é a
// degradação consciente do parser tolerante; anotada, não esquecida.
vm_eval_source_in :: proc(vm: ^Interp, src: string, env: ^Env) -> Value {
    owned := strings.clone(src)
    append(&vm.owned_sources, owned)
    toks, tok_strings, _ := tokenize(owned)
    defer delete(toks)
    for s in tok_strings do append(&vm.owned_strings, s)
    delete(tok_strings)
    p := Parser{ toks = toks[:], src_url = vm.base_url }
    prog := parse_program(&p)
    append(&vm.all_asts, prog)
    for s in p.owned_strings do append(&vm.owned_strings, s)
    delete(p.owned_strings)
    return eval(vm, prog, env)
}

// eval(x): se x NÃO é string, devolve x intacto (spec); se é, avalia no `env`.
// Direto (eval_call passa o env do chamador → vê locais) e indireto (global_eval
// passa vm.global) compartilham isto.
do_eval :: proc(vm: ^Interp, code: Value, env: ^Env) -> Value {
    src, ok := code.(string)
    if !ok do return code
    return vm_eval_source_in(vm, src, env)
}

vm_exec :: proc(vm: ^Interp, src: string, env: ^Env = nil) -> Value {
    when JSPROF {
        t_ini := time.tick_now()
        g_prof.bytes_fonte += u64(len(src))
        defer g_prof.ms_total += time.duration_milliseconds(time.tick_since(t_ini))
    }
    owned := strings.clone(src)
    append(&vm.owned_sources, owned)

    toks, tok_strings, bad_chars := tokenize(owned)
    defer delete(toks)
    // strings decodificadas de escapes: a AST as referencia, então o vm assume
    // a posse (liberadas junto com owned_strings no vm_destroy)
    for s in tok_strings do append(&vm.owned_strings, s)
    delete(tok_strings)
    // URL do que está sendo parseado: os nós de import()/import.meta guardam este
    // referrer, em vez de perguntar quem está correndo na HORA da chamada (M137).
    p := Parser{ toks = toks[:], src_url = vm.current_module != nil ? vm.current_module.url : vm.base_url }
    when JSPROF { t_parse := time.tick_now() }
    prog := parse_program(&p)
    when JSPROF { g_prof.ms_parse += time.duration_milliseconds(time.tick_since(t_parse)) }
    append(&vm.all_asts, prog)
    // chaves numéricas canônicas alocadas pelo parser: a AST as referencia, o vm
    // assume a posse (liberadas com owned_strings no vm_destroy). Igual a tok_strings.
    for s in p.owned_strings do append(&vm.owned_strings, s)
    delete(p.owned_strings)

    // recuperações silenciosas (lexer + parser) — acumuladas no vm p/ o modo
    // estrito dos testes (check_parse_recoveries) e p/ diagnóstico de sites
    if bad_chars > 0 {
        if vm.parse_recoveries < len(vm.parse_notes) {
            vm.parse_notes[vm.parse_recoveries] = Parse_Recovery{what = "caractere(s) desconhecido(s) ignorado(s) no lexer"}
        }
        vm.parse_recoveries += 1
    }
    for i in 0 ..< min(p.recoveries, len(p.rec_notes)) {
        if vm.parse_recoveries + i < len(vm.parse_notes) {
            vm.parse_notes[vm.parse_recoveries + i] = p.rec_notes[i]
        }
    }
    vm.parse_recoveries += p.recoveries

    vm.steps = 0 // watchdog: nova tarefa síncrona
    vm.call_depth = 0
    refresh_stack_limit(vm) // stack da thread atual (script pode rodar na worker de fetch)
    reset_task_clock(vm)    // relógio do watchdog por tempo
    run_env := env if env != nil else vm.global
    result := eval(vm, prog, run_env)
    return result
}

// Modo estrito dos TESTES (compilado só com `odin test`): código de teste é
// sempre JS válido, então qualquer recuperação silenciosa = a engine miscompilou
// sintaxe sem avisar — a classe de bug mais difícil de achar (auditoria
// 2026-07-08: &&=, [a,b]=[b,a], catch({}) etc. viviam exatamente aqui).
// Em produção (browser.exe) nada disso roda: sites reais TÊM sintaxe não
// suportada e a tolerância é deliberada.
check_parse_recoveries :: proc(vm: ^Interp, src: string) {
    when !ODIN_TEST {
        return
    }
    if vm.parse_recoveries == 0 do return
    fmt.eprintfln("parse com %d recuperação(ões) silenciosa(s):", vm.parse_recoveries)
    for i in 0 ..< min(vm.parse_recoveries, len(vm.parse_notes)) {
        n := vm.parse_notes[i]
        fmt.eprintfln("  [%d] %s — token #%d %v %q", i, n.what, n.pos, n.kind, n.text)
    }
    fmt.eprintfln("  fonte: %q", src[:min(len(src), 300)])
    panic("teste parseou JS com recuperação silenciosa (sintaxe não suportada foi engolida)")
}

// Execução transitória (cria vm, roda, destrói). Usada pelos testes do núcleo.
run :: proc(src: string) -> Value {
    vm := vm_create()
    defer vm_free(vm)
    v := vm_run(vm, src)
    check_parse_recoveries(vm, src)
    return v
}
