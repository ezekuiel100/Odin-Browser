package js

// Interpretador tree-walking: percorre a AST e executa.
// Mesma espinha dorsal do LibJS (Ladybird) na fase inicial.

import "core:fmt"
import "core:math"
import "core:sort"
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
    promise: ^Promise_Data, // private Promise slots; absent on ordinary objects
    coll_iter: ^Coll_Iterator, // private state for live Map/Set iterators
    px_revoked: bool,
    px_self: Value,
    px_target:  Value,   // Proxy: o alvo envolvido (nil se não é proxy — ver px_handler)
    px_handler: Value, // Proxy: o handler com os traps (get/set/has/...). != nil ⇒ este Object É um proxy
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
    detached: bool,
}

Array :: struct {
    items: [dynamic]Value,
    descriptors: ^Object, // Lazy attributes/accessors; data values stay in items/props.
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
    holes: [dynamic]u64, // BURACOS (índices ausentes: `[1,,3]`, `new Array(3)`, `delete a[i]`,
                         // `a[9]=x` além do fim). Bitmap lateral, vazio no caso comum. Um
                         // índice só é buraco com o bit ligado E o item == nil (arr_is_hole):
                         // qualquer escrita de valor preenche o slot sem tocar no bitmap. Ver
                         // arr_mark_hole / arr_holes_reset.
    args: ^Args_Info, // só no objeto `arguments` (is_arguments): callee + mapeamento
}

// Estado do objeto `arguments` de uma chamada, fora do ^Array para não pesar em
// todo array. Mapeamento (sloppy + params simples, spec 10.4.4): `arguments[i]` e
// o parâmetro i são o MESMO binding — escrever um muda o outro. Os items ficam
// SEMPRE em dia nos dois sentidos (set_index escreve no env; env_assign escreve
// nos items), então quem lê os items direto (spread, slice.call, apply) vê o certo.
Args_Info :: struct {
    callee:   ^Function, // arguments.callee (strict: lança TypeError)
    env:      ^Env,      // escopo da chamada, onde moram os params
    params:   []string,  // fn.params (fatia emprestada do nó)
    nmap:     int,       // índices mapeáveis: min(len(args), len(params)); 0 = sem mapeamento
    unmapped: u64,       // bit i = índice i desligado (delete arguments[i]); só os 64 primeiros mapeiam
}

// O índice i de `arguments` está ligado a um parâmetro? Param repetido (`function
// f(a, a)`) liga só a ÚLTIMA ocorrência (spec: o laço vai do fim para o começo).
args_mapped :: proc(info: ^Args_Info, i: int) -> bool {
    if info == nil || i < 0 || i >= info.nmap || i >= 64 do return false
    if info.unmapped & (u64(1) << uint(i)) != 0 do return false
    name := info.params[i]
    if name == "" do return false
    for j in i + 1 ..< len(info.params) do if info.params[j] == name do return false
    return true
}

// `param = v` numa função com arguments mapeado: espelha no item.
args_param_written :: proc(a: ^Array, name: string, v: Value) {
    info := a.args
    for i in 0 ..< min(info.nmap, len(a.items)) {
        if info.params[i] == name && args_mapped(info, i) do a.items[i] = v
    }
}

// ── buracos de array ──────────────────────────────────────────────────────────
// Os items continuam DENSOS (o buraco lido dá undefined, como no JS); o bitmap só
// responde "o índice EXISTE?" — HasProperty, Object.keys, for-in, e os métodos que
// pulam ausentes (forEach/map/filter/reduce/indexOf...).

arr_is_hole :: #force_inline proc(a: ^Array, i: int) -> bool {
    w := i >> 6
    if i < 0 || w >= len(a.holes) || i >= len(a.items) do return false
    if a.items[i] != nil do return false
    return a.holes[w] & (u64(1) << uint(i & 63)) != 0
}

// O índice existe (dentro do length e não é buraco).
arr_has_index :: #force_inline proc(a: ^Array, i: int) -> bool {
    return i >= 0 && i < len(a.items) && !arr_is_hole(a, i)
}

arr_mark_holes :: proc(a: ^Array, from, to: int) { // [from, to)
    if from >= to do return
    need := (to + 63) >> 6
    for len(a.holes) < need do append(&a.holes, 0)
    for i in from ..< to do a.holes[i >> 6] |= u64(1) << uint(i & 63)
}

arr_mark_hole :: proc(a: ^Array, i: int) { arr_mark_holes(a, i, i + 1) }

// Escrita EXPLÍCITA de undefined num índice: deixa de ser buraco.
arr_fill_slot :: #force_inline proc(a: ^Array, i: int) {
    w := i >> 6
    if w < len(a.holes) do a.holes[w] &~= u64(1) << uint(i & 63)
}

// Operações que REORDENAM/encolhem os items (shift/splice/sort/reverse/truncar):
// o bitmap deixaria de casar com as posições. Os buracos viram undefined de
// verdade. ⚠️ DEGRADAÇÃO ANOTADA: a spec preservaria/moveria os buracos.
arr_holes_reset :: #force_inline proc(a: ^Array) {
    if len(a.holes) > 0 do clear(&a.holes)
}

// Depois de ENCOLHER os items (pop, length menor): apaga os bits a partir do novo
// fim, senão um `push(undefined)` posterior cairia num bit velho e viraria buraco.
arr_holes_trim :: proc(a: ^Array) {
    if len(a.holes) == 0 do return
    n := len(a.items)
    w := n >> 6
    if w >= len(a.holes) do return
    a.holes[w] &= (u64(1) << uint(n & 63)) - 1
    resize(&a.holes, w + 1)
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
    evaluation: ^Object, // settles only after the entire module body completes
    error: Value,
    parent: ^Module, // evaluation ancestry, for static cycles
    deferred: [dynamic]Deferred_Export,
    program: ^Node, // retained AST, used for ResolveExport across star graphs
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
    attrs: map[string]Prop_Attrs,
    native_length: int,
    non_constructor: bool,
    is_arrow: bool, // arrow não vincula `this` próprio (herda o léxico via closure)
    is_async: bool, // devolve Promise; throw vira rejeição (ver call_function)
    self_bind: bool, // function EXPRESSION nomeada: o nome só é visível dentro do
                     // próprio corpo — bindado no escopo da CHAMADA (setup_call_scope),
                     // já que não vaza mais p/ o env externo (spec)
    is_generator: bool, // function*: chamar devolve um objeto generator (generator.odin)
    strict: bool, // corpo strict (do nó .Func): `arguments` sem mapeamento e callee que lança
    uses_arguments: bool, // o corpo menciona `arguments` (ou `eval`) — só então
                          // setup_call_scope materializa o objeto. Vem do nó .Func
                          // (Parser.saw_arguments); nativa/bound nunca precisam.
    bound:    Value, // "closure" de nativas: valor extra visível via vm.native_bound
                     // durante a chamada (ex.: o resolve() de uma Promise sabe qual é a sua)
    props:    map[string]Value, // propriedades da função (ex.: Promise.resolve, prototype de classe); nil se não usadas
    // ── suporte a `class` (M21 fatia 1) ──
    super_ctor:  ^Function, // construtora da superclasse, para `super(...)`
    home_super:  ^Object,   // prototype da superclasse, para `super.metodo()`
    home_static: ^Function, // método STATIC de classe derivada: `super` = a construtora-pai
    home_obj:    ^Object,   // método de LITERAL de objeto ({ m(){ super.x } }): o objeto
                            // dono. `super` = Object.getPrototypeOf(home_obj), lido NA
                            // CHAMADA (setPrototypeOf depois da criação vale — spec).
    auto_super:  bool,      // construtor default derivado: chama super_ctor com os mesmos args
    super_null:  bool,      // `class extends null`: derivada SEM construtora-pai — super() lança
    class_keys: []string, // resolved member names, indexed by class_node.body
    class_node:  ^Node,     // se é a construtora de uma class: o nó .Class (p/ inicializar
                            // os campos de instância no `new`, ver init_instance_fields)
    getters:  map[string]^Function, // getters STATIC de classe (static get x(){}); nil até ter algum
    setters:  map[string]^Function, // setters STATIC de classe (static set x(v){})
    // ── Function.prototype.bind ──
    proxy: ^Object, // callable proxy state; shared with its revoker
    bind_target: ^Function,   // se != nil, esta é uma função LIGADA de bind_target
    bind_this:   Value,       // `this` fixado pelo bind
    bind_args:   [dynamic]Value, // args pré-fixados (prepended nas chamadas)
    script: ^Script_Src, // fonte em que a função nasceu (p/ linha:coluna do Error.stack)
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
    uninitialized: map[string]bool, // module lexical bindings in the TDZ
    parent: ^Env,
    is_fn_scope: bool, // fronteira de escopo de FUNÇÃO (var sobe até aqui; blocos não)
    is_with: bool,     // AMBIENTE DE OBJETO de um `with (obj)` (spec 9.1.1.2): o objeto mora
                       // em vars[WITH_OBJ_KEY] (ver with_object) e o nome resolve nele se
                       // HasProperty e não bloqueado por @@unscopables (with_has_binding).
                       // Só um bool no padding: um campo Value (+24 B no Env, alocado em toda
                       // chamada/bloco) custou ~1,8% num laço de variáveis. O caminho quente
                       // (env_get/env_assign) testa o bool SÓ depois de errar no `vars`.
    aliases: map[string]Env_Alias, // nil até o 1º import com live binding
    consts: map[string]bool,       // bindings declarados com `const` neste escopo; nil
                                   // até o 1º. env_assign lança TypeError ao acertar um
                                   // deles. Um mapa à parte (em vez de engordar `vars`
                                   // com um struct) mantém o caminho quente de leitura
                                   // intocado e não custa nada em escopo sem const.
    mapped_args: ^Array, // escopo de função com `arguments` MAPEADO: env_assign num param
                         // espelha o valor no item (ver Args_Info). nil no caso comum.
}

// ── Valor de conclusão VAZIO (spec: `empty`) ──────────────────────────────────
// O valor de conclusão de um statement é o que eval()/vm_exec devolvem do script.
// `break`, `continue`, `var`/`let`/`const`, `;`, `debugger` e declaração de classe
// não têm valor — e "sem valor" não é `undefined`: numa lista de statements o
// vazio HERDA o valor anterior (UpdateEmpty), então `3; break;` conclui com 3 e
// `1; var x;` com 1. Representado por um ^Symbol estático que NUNCA chega ao JS:
// só statements o devolvem, só listas/laços/if/try/with/rótulo o consomem, e as
// fronteiras (vm_eval_source_in, vm_exec, resultado do programa assíncrono)
// passam por completion_value. Corpo de função descarta o resultado.
@(private = "file")
g_empty_completion: Symbol

empty_completion :: #force_inline proc() -> Value {
    return &g_empty_completion
}

is_empty_completion :: #force_inline proc(v: Value) -> bool {
    s, ok := v.(^Symbol)
    return ok && s == &g_empty_completion
}

// Fronteira: o vazio vira undefined (spec: o script conclui com `undefined`).
completion_value :: #force_inline proc(v: Value) -> Value {
    return nil if is_empty_completion(v) else v
}

// UpdateEmpty(C, V) da spec para uma LISTA de statements: o resultado `r` de `s`
// só substitui o acumulado se não for vazio. Declaração de classe é vazia, mas o
// eval dela devolve a classe (o `export default class` precisa do valor), então
// é tratada aqui, no único contexto em que ela aparece como statement.
@(private = "file")
update_empty :: #force_inline proc(acc: Value, s: ^Node, r: Value) -> Value {
    if is_empty_completion(r) || (s.kind == .Class && s.decl) do return acc
    return r
}

// Chave do objeto de um `with` no `vars` do ambiente de objeto. NUL não aparece em
// identificador JS, então nenhum nome do fonte colide; e o mapa já é marcado pelo GC
// e esvaziado pelo pool — sem campo novo no Env.
WITH_OBJ_KEY :: "\x00with"

with_object :: #force_inline proc(e: ^Env) -> Value {
    return e.vars[WITH_OBJ_KEY]
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
    gc_threshold: int, // adaptive host-safepoint collection threshold
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
    sym_species_key: string,
    sym_concat_spreadable_key: string,
    sym_replace_key: string,
    // Symbol.match/matchAll/search/split: String.prototype.<m> delega a arg[@@m]
    // (como o replace); @@match também é o critério do IsRegExp.
    sym_match_key: string,
    sym_match_all_key: string,
    sym_search_key: string,
    sym_split_key: string,
    sym_iterator_key: string,             // chave-string do Symbol.iterator (p/ protocolo de iterador)
    sym_async_iterator_key: string,        // chave-string do Symbol.asyncIterator (for-await + async generators)
    sym_toprimitive_key: string,           // chave-string do Symbol.toPrimitive (ToPrimitive consulta antes de valueOf/toString)
    sym_has_instance_key: string,          // chave-string do Symbol.hasInstance (instanceof consulta antes da cadeia de proto)
    sym_tostring_tag_key: string,          // chave-string do Symbol.toStringTag (Object.prototype.toString consulta antes do #class)
    sym_unscopables_key: string,           // chave-string do Symbol.unscopables (o `with` consulta antes de ligar um nome)
    with_used: bool,                       // algum `with` já executou: só então eval_call/delete procuram a
                                           // BASE de um identificador (o `this` de `f()` dentro do with)
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
    // String/Number/Boolean.prototype: [[Prototype]] dos objetos WRAPPER
    // (`new String("a")`, `Object(1)`) — ver make_wrapper.
    string_proto, number_proto, boolean_proto: ^Object,
    // true durante a construção de uma nativa (`new X()` ou super()):
    // é como String/Number/Boolean distinguem `new String(x)` (wrapper) de `String(x)`
    // (primitivo). call_function usa seu próprio new.target pendente, então o
    // estado não vaza para chamadas comuns aninhadas.
    native_new:     bool,
    error_protos:   map[string]^Object,   // Error/TypeError/... → prototype (instanceof)
    object_methods: map[string]^Function, // métodos de todo objeto (hasOwnProperty, ...)
    collection_methods: map[string]^Function, // métodos de Map/Set/WeakMap/WeakSet (set, get, has, ...)
    collection_protos: [Coll_Kind]^Object, // intrinsic prototypes, independent of replaced globals
    collection_iter_protos: [Coll_Kind]^Object,
    regex_test_fn:  ^Function,             // RegExp.prototype.test/exec (regex.odin)
    regex_exec_fn:  ^Function,
    regex_proto:    ^Object, // RegExp.prototype: o get_member de ^Regex cai aqui depois dos casos fixos
    regex_tostring_fn: ^Function,          // RegExp.prototype.toString ("/fonte/flags")
    dom_element_ctor:     ^Function,             // constructor compartilhado dos elementos DOM (node.constructor.prototype — inputValueTracking do React); é o HTMLElement da hierarquia de interfaces
    dom_element_proto:     ^Object,               // HTMLElement.prototype (proto dos wrappers de elemento; base p/ instanceof + polyfills em Element/Node/HTMLElement.prototype)
    dom_htmlcollection_proto: ^Object,            // HTMLCollection.prototype (el.children — dom_collection.odin)
    dom_nodelist_proto:       ^Object,            // NodeList.prototype (el.childNodes)
    dom_namednodemap_proto:   ^Object,            // NamedNodeMap.prototype (el.attributes — dom_attributes.odin)
    dom_attr_proto:           ^Object,            // Attr.prototype (itens de el.attributes)
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
    mo_queued: bool,
    mo_pending: [dynamic]^Object,
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
    nav_request:     string,              // navegação pedida pela PÁGINA (location.href=/assign/replace,
                                          // envio de <form>); URL ABSOLUTA, owned. O host (ui) consome
                                          // e zera: vm_take_nav_request. Última escrita vence.
    nav_replace:     bool,                // location.replace: não empilha no histórico
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
    import_map:     Import_Map,           // <script type="importmap"> (import_map.odin)
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
    // pilha-sombra p/ Error.stack (stack_trace.odin): frame da função de usuário em
    // execução, a posição corrente no código dela e o fonte a que pertence.
    frame:          ^Stack_Frame,
    cur_pos:        u32,         // offset+1 no fonte de cur_script; 0 = desconhecido
    cur_script:     ^Script_Src, // nil = fora de qualquer script (callback do host)
    all_scripts:    [dynamic]^Script_Src,
    script_alloc:   Script_Allocator,
    error_ctor:     ^Function,   // o `Error` instalado (lê Error.stackTraceLimit)
    stack_low:      uintptr, // fundo reservado da stack da thread atual (stack_guard.odin); 0 = guarda off
    task_start:     time.Tick, // relógio REAL do início da tarefa (watchdog por tempo)
    time_budget_ms: f64,   // teto de tempo de parede por tarefa; 0 = desligado (TIME_BUDGET_MS)
    host_turn_start: time.Tick,
    host_turn_budget_ms: f64, // aggregate UI budget; task resets must not extend it
    reaction_queue: [dynamic]Reaction_Job, // reações de Promise pendentes (microtasks; promise.odin)
    draining:       bool,  // já dentro de drain_reactions? (evita drain reentrante — mantém a stack flat)
    pump_depth:     int,   // profundidade de vm_pump_timers (await dentro de callback re-entra no pump)
    dead_timer_ids: map[int]bool, // ids cancelados por clearTimeout DURANTE um pump (o disparo pendente é pulado); limpo ao sair do pump raiz
    parse_recoveries: int, // recuperações silenciosas acumuladas (lexer+parser) — testes exigem 0 (check_parse_recoveries)
    syntax_errors: int, // fontes REJEITADAS por SyntaxError (não executaram) — cada um tem nota em parse_notes
                        // (índice = parse_recoveries + syntax_errors). Testes exigem 0 também.
    parse_notes: [8]Parse_Recovery, // detalhe das primeiras (diagnóstico)
    uncaught_log:   [dynamic]string, // mensagens das exceções que chegaram ao topo sem catch (clonadas;
                                     // teto UNCAUGHT_LOG_MAX p/ um setInterval que lança não crescer sem fim).
                                     // Consumido pelo --diagnose <url> <saida.json> (gap-miner.ps1).
    cssom_revision: u64,             // stylesheet mutations requiring rule collection
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

// The interactive host shares one deadline across events, timers and observers.
// Callers without a frame budget retain the normal per-task watchdog.
vm_begin_host_turn :: proc(vm: ^Interp, budget_ms: f64) {
    if vm == nil do return
    vm.host_turn_start = time.tick_now()
    vm.host_turn_budget_ms = budget_ms
}

vm_end_host_turn :: proc(vm: ^Interp) {
    if vm != nil {
        vm.host_turn_budget_ms = 0
        if gc_heap_count(vm) >= max(4096, vm.gc_threshold) do vm_collect(vm)
    }
}

vm_host_turn_expired :: proc(vm: ^Interp) -> bool {
    return vm != nil && vm.host_turn_budget_ms > 0 &&
        time.duration_milliseconds(time.tick_since(vm.host_turn_start)) >= vm.host_turn_budget_ms
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

step_guard :: proc(vm: ^Interp) -> bool {
    vm.steps += 1
    // The host's frame budget defers whole callbacks at scheduler boundaries.
    // Throwing here interrupts a valid callback halfway through its DOM work:
    // React catches that artificial error and replaces the page with its error
    // boundary. Long/infinite callbacks still have the per-task watchdog below.
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
        e.is_with = false
        e.mapped_args = nil
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
        if e.uninitialized != nil {
            delete(e.uninitialized)
            e.uninitialized = nil
        }
        if e.consts != nil {
            delete(e.consts)
            e.consts = nil
        }
        if len(vm.env_pool) < ENV_POOL_MAX && len(e.vars) <= ENV_POOL_VAR_MAX {
            clear(&e.vars)
            e.parent = nil
            e.is_with = false
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
hoist_functions :: proc(vm: ^Interp, stmts: []^Node, env: ^Env) {
    for statement in stmts {
        s := statement
        for s.kind == .Labeled do s = s.left
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
    n := s
    for n.kind == .Labeled do n = n.left
    return n.kind == .Func && n.name != ""
}

// Copy the current block binding only when execution reaches the declaration.
@(private = "file")
execute_hoisted_func :: proc(vm: ^Interp, s: ^Node, env: ^Env) {
    n := s
    for n.kind == .Labeled do n = n.left
    if n.annex_b {
        target := fn_scope_env(env)
        env_assign(vm, target, n.name, env.vars[n.name])
    }
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
        if node.annex_b do hoist_declare(env, node.name)
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
    case .With:
        hoist_vars(node.right, env) // `var` no corpo do with sobe p/ a função
    }
}

// `var x = v` dentro de um `with`: se um ambiente de objeto ENTRE `env` e o escopo
// de função `target` tem o nome, o valor vai p/ o objeto (true). Um binding
// declarativo no meio do caminho (param de catch…) mantém o comportamento de antes.
@(private = "file")
var_init_through_with :: proc(vm: ^Interp, env, target: ^Env, name: string, val: Value) -> bool {
    for cur := env; cur != nil && cur != target; cur = cur.parent {
        if cur.is_with {
            if with_has_binding(vm, with_object(cur), name) {
                if !vm.throwing do set_member(vm, with_object(cur), name, val)
                return true
            }
            if vm.throwing do return true
        } else if _, ok := cur.vars[name]; ok {
            return false
        }
    }
    return false
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
    if st, ok := stack_for_error(vm, name, msg); ok {
        o.props["stack"] = st // com frames; NÃO enumerável (V8): fora de keys/JSON.stringify
        mark_non_enumerable(o, "stack")
    }
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
lookup_ident :: proc(vm: ^Interp, env: ^Env, name: string, strict := false) -> (Value, bool) {
    if strict && vm.with_used { // GetBindingValue strict de um `with`: caminho lento
        v, ok, _ := lookup_ident_base(vm, env, name, true)
        return v, ok
    }
    if v, ok := env_get(env, name, vm); ok do return v, true
    return lookup_window(vm, name)
}

// lookup_ident + a BASE do binding (o objeto do `with` que respondeu; nil no resto).
lookup_ident_base :: proc(vm: ^Interp, env: ^Env, name: string, strict := false) -> (Value, bool, Value) {
    if v, ok, base := env_resolve(env, name, vm, strict); ok do return v, true, base
    v, ok := lookup_window(vm, name)
    return v, ok, nil
}

// Último degrau do lookup_ident: as props da janela (o objeto global no browser).
@(private = "file")
lookup_window :: proc(vm: ^Interp, name: string) -> (Value, bool) {
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
    f.script = vm.cur_script
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
        if e.uninitialized != nil do delete(e.uninitialized)
        if e.consts != nil do delete(e.consts)
        free(e)
    }
    delete(vm.all_envs)
    // escopos ociosos no pool: fora de all_envs, precisam ser liberados aqui
    for e in vm.env_pool {
        delete(e.vars)
        if e.aliases != nil do delete(e.aliases)
        if e.uninitialized != nil do delete(e.uninitialized)
        if e.consts != nil do delete(e.consts)
        free(e)
    }
    delete(vm.env_pool)
    delete(vm.probe_stack) // vazia fora de build com MEMBERPROBE
    for f in vm.all_funcs {
        delete(f.attrs)
        delete(f.props)
        if f.class_keys != nil do delete(f.class_keys)
        if f.bind_args != nil do delete(f.bind_args)
        if f.getters != nil do delete(f.getters)
        if f.setters != nil do delete(f.setters)
        free(f)
    }
    delete(vm.all_funcs)
    fetch_abandon_pending(vm) // fetches em voo: protocolo atômico (fetch.odin)
    if vm.base_url != "" do delete(vm.base_url)
    import_map_destroy(&vm.import_map)
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
        coll_iterator_destroy(o)
        promise_destroy(o)
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
        delete(a.holes)
        if a.args != nil do free(a.args)
        free(a)
    }
    delete(vm.all_arrays)
    for b in vm.all_buffers { delete(b.data); free(b) }
    delete(vm.all_buffers)
    for re in vm.all_regexes do regex_destroy(re)
    delete(vm.all_regexes)
    for c in vm.all_collections { delete(c.entries); delete(c.index); free(c) }
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
    scripts_free(vm) // Script_Src só referenciava as fontes acima
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
    refresh_stack_limit(vm)      // pode ser chamado de thread diferente (await na worker)
    vm.clock_ms += dt_ms
    if vm_host_turn_expired(vm) do return false
    fired := false
    // Resume microtasks/observers left pending when the preceding UI turn ended.
    if len(vm.reaction_queue) > 0 || mo_has_records(vm) {
        fired = true
        vm.steps = 0
        reset_task_clock(vm)
        mo_task_enter(vm)
        mo_task_exit(vm)
    }
    if vm_pump_fetches(vm) do fired = true
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
    // O id desempata pela ordem de registro, inclusive após adiar para outro frame.
    sort.quick_sort_proc(due[:], proc(a, b: Timer) -> int {
        if a.due < b.due do return -1
        if a.due > b.due do return 1
        return a.id - b.id
    })
    scheduled_at := vm.clock_ms
    vm.pump_depth += 1
    for t, index in due {
        if vm_host_turn_expired(vm) {
            // One-shots were removed by the snapshot above: restore those we
            // haven't called. Intervals must remain due, not skip a firing.
            for pending in due[index:] {
                if vm.dead_timer_ids[pending.id] do continue
                if pending.interval == 0 {
                    append(&vm.timers, pending)
                } else {
                    for &timer in vm.timers {
                        if timer.id == pending.id && timer.due == scheduled_at + pending.interval {
                            timer.due = pending.due
                            break
                        }
                    }
                }
            }
            break
        }
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
    if vm == nil || vm_host_turn_expired(vm) do return false
    fired := io_step(vm)   // IntersectionObserver (intersection_observer.odin)
    if ro_step(vm)  do fired = true // ResizeObserver   (resize_observer.odin)
    if mql_step(vm) do fired = true // matchMedia 'change' (media_query.odin)
    return fired
}

// Caminho QUENTE do motor: laço próprio (delegar ao env_resolve, que devolve 3
// valores com uma union, custou ~19% num laço de leitura de variáveis). Só ao
// topar com um ambiente de objeto (`with`) desvia para o env_resolve.
env_get :: proc(e: ^Env, name: string, vm: ^Interp = nil) -> (Value, bool) {
    when JSPROF { g_prof.env_get += 1 }
    cur := e
    for cur != nil {
        when JSPROF { g_prof.env_saltos += 1 } // custo REAL da cadeia: niveis percorridos
        if v, ok := cur.vars[name]; ok {
            if vm != nil && cur.uninitialized[name] {
                throw_reference_error(vm, fmt.tprintf("Cannot access '%s' before initialization", name))
                return nil, true
            }
            return v, true
        }
        // ambiente de objeto (`with`): `vars` dele é sempre vazio, então testar SÓ no
        // erro tira o custo do caminho de acerto (era ~2,5% num laço de vars)
        if cur.is_with && vm != nil {
            v, ok, _ := env_resolve(cur, name, vm)
            return v, ok
        }
        // live binding de import: resolve no escopo do módulo exportador AGORA
        if cur.aliases != nil {
            if a, ok := cur.aliases[name]; ok do return env_get(a.src, a.local, vm)
        }
        cur = cur.parent
    }
    return nil, false
}

// Nomes que o motor guarda COMO variável no Env mas que não são referências de
// identificador do fonte (ThisExpression, new.target, ligações internas de classe).
// Um ambiente de objeto não pode capturá-los: `with ({this: 1}) this` é o `this`
// de fora.
@(private = "file")
is_internal_binding :: proc(name: string) -> bool {
    switch name {
    case "this", "new.target", "__superctor__", "__classctor__", "__superproto__":
        return true
    }
    return false
}

// HasBinding de um ambiente de objeto (spec 9.1.1.2.1): HasProperty(obj, N) e, se
// sim, N não pode estar marcado em obj[@@unscopables]. Com exceção em voo devolve
// true — o chamador para a busca e a exceção propaga.
with_has_binding :: proc(vm: ^Interp, obj: Value, name: string) -> bool {
    if is_internal_binding(name) do return false
    has := with_has_property(vm, obj, name)
    if vm.throwing do return true
    if !has do return false
    if vm.sym_unscopables_key != "" {
        u := get_member(vm, obj, vm.sym_unscopables_key)
        if vm.throwing do return true
        if !is_primitive(u) {
            blocked := get_member(vm, u, name)
            if vm.throwing do return true
            if truthy(blocked) do return false
        }
    }
    return true
}

// GetBindingValue de um ambiente de objeto (spec 9.1.1.2.6): a prop pode ter sumido
// entre a resolução e a leitura (getter de @@unscopables que apaga) — HasProperty
// de novo; sumiu = ReferenceError em strict, undefined em sloppy.
with_get_binding :: proc(vm: ^Interp, obj: Value, name: string, strict: bool) -> Value {
    still := with_has_property(vm, obj, name)
    if vm.throwing do return nil
    if !still {
        if strict do throw_reference_error(vm, fmt.tprintf("%s is not defined", name))
        return nil
    }
    return get_member(vm, obj, name)
}

// SetMutableBinding de um ambiente de objeto (spec 9.1.1.2.5): idem, e a escrita
// rejeitada vira TypeError em strict.
with_set_binding :: proc(vm: ^Interp, obj: Value, name: string, v: Value, strict: bool) {
    still := with_has_property(vm, obj, name)
    if vm.throwing do return
    if !still && strict {
        throw_reference_error(vm, fmt.tprintf("%s is not defined", name))
        return
    }
    if !set_member(vm, obj, name, v) && strict do strict_write_failed(vm, obj, name)
}

// Referência a identificador resolvida UMA vez (spec: ResolveBinding antes do RHS;
// `x++`/`x += v` leem e escrevem a MESMA referência). Só montada depois de algum
// `with` ter rodado — sem with, re-resolver não é observável e o caminho de sempre
// (env_get/env_assign) fica intocado.
Ident_Ref :: struct {
    resolved: bool,  // a resolução foi feita (senão: caminho de sempre)
    wobj:     Value, // != nil: o binding é do objeto de um `with`
    holder:   ^Env,  // escopo declarativo que tem o nome
    root:     ^Env,  // raiz da cadeia (irresolúvel: global implícito / ReferenceError)
}

resolve_ident_ref :: proc(vm: ^Interp, env: ^Env, name: string) -> (r: Ident_Ref) {
    r.resolved = true
    for cur := env; cur != nil; cur = cur.parent {
        r.root = cur
        if cur.is_with {
            if with_has_binding(vm, with_object(cur), name) {
                if !vm.throwing do r.wobj = with_object(cur)
                return
            }
            continue
        }
        if _, ok := cur.vars[name]; ok { r.holder = cur; return }
        if cur.aliases != nil {
            if _, ok := cur.aliases[name]; ok { r.holder = cur; return }
        }
    }
    return
}

ident_ref_get :: proc(vm: ^Interp, r: Ident_Ref, name: string, strict: bool) -> Value {
    if r.wobj != nil do return with_get_binding(vm, r.wobj, name, strict)
    if r.holder != nil {
        v, _ := env_get(r.holder, name, vm)
        return v
    }
    return nil // irresolúvel: o mesmo undefined do ref_read de sempre
}

ident_ref_put :: proc(vm: ^Interp, r: Ident_Ref, name: string, v: Value, strict: bool) {
    if r.wobj != nil { with_set_binding(vm, r.wobj, name, v, strict); return }
    if r.holder != nil { env_assign(vm, r.holder, name, v, strict); return }
    if r.root != nil do env_assign(vm, r.root, name, v, strict)
}

// `x = v` / `x op= v` / `x &&= v` com alvo Ident depois de algum `with`: a mesma
// lógica do .Assign do eval, mas lendo e escrevendo a referência resolvida UMA vez,
// ANTES do RHS. Fora do eval de propósito: o Ident_Ref como local do eval engordava
// o frame da função recursiva para todo tipo de nó (medido: ~3% num laço de vars).
eval_assign_with :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    name := n.left.name
    r := resolve_ident_ref(vm, env, name)
    if vm.throwing do return nil
    #partial switch n.op {
    case .AmpAmp, .PipePipe, .QQuestion:
        cur := ident_ref_get(vm, r, name, n.strict)
        if vm.throwing do return nil
        keep := false
        #partial switch n.op {
        case .AmpAmp:    keep = !truthy(cur)
        case .PipePipe:  keep = truthy(cur)
        case .QQuestion: keep = !is_nullish(cur)
        }
        if keep do return cur
        rhs := eval(vm, n.right, env)
        if vm.throwing do return nil
        infer_binding_name(n.right, rhs, name)
        ident_ref_put(vm, r, name, rhs, n.strict)
        return rhs
    }
    old: Value
    if n.op != .Assign do old = ident_ref_get(vm, r, name, n.strict) // composto lê ANTES do RHS
    if vm.throwing do return nil
    rhs := eval(vm, n.right, env)
    if vm.throwing do return nil
    val: Value = rhs
    if n.op == .Assign do infer_binding_name(n.right, rhs, name)
    else do val = binop(vm, n.op, old, rhs)
    if vm.throwing do return nil
    ident_ref_put(vm, r, name, val, n.strict)
    return val
}

// with (obj) stmt (spec 14.11.2): ToObject(obj) — null/undefined lançam, primitivo
// vira o wrapper — e o corpo roda com um AMBIENTE DE OBJETO na frente da cadeia.
// Closures criadas no corpo o capturam como qualquer escopo.
eval_with :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    ov := eval(vm, n.left, env)
    if vm.throwing do return nil
    if is_nullish(ov) {
        throw_type_error(vm, "Cannot convert undefined or null to object")
        return nil
    }
    wenv := new_env(vm, env)
    wenv.vars[WITH_OBJ_KEY] = make_wrapper(vm, ov)
    wenv.is_with = true
    vm.with_used = true
    return completion_value(eval(vm, n.right, wenv)) // UpdateEmpty(C, undefined)
}

// `delete x` (sloppy) depois de algum `with`: se `x` resolve num ambiente de objeto,
// é um delete da PROPRIEDADE (spec 9.1.1.2.7). Fora disso, o comportamento de
// sempre (true, sem efeito).
delete_ident_with :: proc(vm: ^Interp, name: string, env: ^Env) -> Value {
    for cur := env; cur != nil; cur = cur.parent {
        if cur.is_with {
            if with_has_binding(vm, with_object(cur), name) {
                if vm.throwing do return nil
                return delete_property_value(vm, with_object(cur), name, false)
            }
            if vm.throwing do return nil
            continue
        }
        if _, ok := cur.vars[name]; ok do return true // binding declarativo
    }
    return true
}

// `x++`/`--x` com alvo Ident depois de algum `with`: lê e escreve a MESMA referência
// (um getter de @@unscopables não pode mandar a escrita p/ outro objeto).
eval_update_with :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    name := n.left.name
    r := resolve_ident_ref(vm, env, name)
    if vm.throwing do return nil
    old := ident_ref_get(vm, r, name, n.strict)
    if vm.throwing do return nil
    if ob, ok := old.(^BigInt); ok {
        one := bigint_from_i64(vm, 1)
        nb := n.op == .PlusPlus ? bigint_add(vm, ob, one) : bigint_sub(vm, ob, one)
        ident_ref_put(vm, r, name, nb, n.strict)
        return nb if n.bval else ob
    }
    cur := as_number(old)
    newv := cur + (1 if n.op == .PlusPlus else -1)
    ident_ref_put(vm, r, name, newv, n.strict)
    return newv if n.bval else cur
}

// HasProperty(obj, N) para o objeto de um `with` (qualquer tipo de valor).
@(private = "file")
with_has_property :: proc(vm: ^Interp, obj: Value, name: string) -> bool {
    has: bool
    #partial switch _ in obj {
    case ^Object, ^Array:
        has = js_in(vm, name, obj)
        // wrapper (`with ("abc")`): `length`/índices vêm do primitivo pelo fallback
        // de `prim` do get_member, que o js_in não enxerga
        if o, is_obj := obj.(^Object); is_obj && !has && !vm.throwing && o.prim != nil {
            has = get_member(vm, obj, name) != nil
        }
    case:
        // js_in só conhece Object/Array; p/ o resto (função, regex, coleção…)
        // HasProperty vira "Get não deu undefined" — aproximação: uma prop que
        // existe valendo undefined fica de fora.
        has = get_member(vm, obj, name) != nil
    }
    return has
}

// [[Delete]](k) de `obj` com o resultado do operador `delete`: prop própria
// NÃO-configurável não sai — devolve false em sloppy e lança TypeError em strict
// (spec 13.5.1.2). Compartilhado por `delete o.k`/`delete o[k]` e pelo `delete x`
// que resolve num `with`.
delete_property_value :: proc(vm: ^Interp, obj: Value, k: string, strict: bool) -> Value {
    if p := proxy_state(obj); p != nil {
        proxy_delete(vm, p, k)
        return true
    }
    ok := true
    #partial switch o in obj {
    case ^Object:
        if o.px_handler != nil { proxy_delete(vm, o, k); return true } // trap deleteProperty
        if o.get == storage_get { storage_remove_key(o, k); return true } // delete localStorage.x
        if okey_alive(o, k) && .Configurable not_in prop_attrs(o, k) {
            ok = false
        } else if .Configurable in prop_attrs(o, k) {
            oremove(o, k)
            delete_key(&o.getters, k); delete_key(&o.setters, k)
            delete_key(&o.attrs, k)
        }
    case ^Function:
        if a, explicit := o.attrs[k]; explicit && .Configurable not_in a {
            ok = false
        } else {
            delete_key(&o.props, k); delete_key(&o.getters, k); delete_key(&o.setters, k)
            delete_key(&o.attrs, k)
        }
    case ^Array:
        ok = array_delete_property(o, k)
    }
    if !ok && strict {
        throw_type_error(vm, fmt.tprintf("Cannot delete property '%s' of object", k))
        return nil
    }
    return ok
}

// Resolve `name` subindo a cadeia. `base` != nil quando quem respondeu foi um
// AMBIENTE DE OBJETO (`with`): é o objeto, que vira o `this` de `f()` (spec
// 9.1.1.2.10 WithBaseObject). Sem `vm` (consultas internas) os `with` são pulados.
// `strict`: a referência é de código strict (só pesa se a prop do `with` sumir
// entre a resolução e a leitura — ver with_get_binding).
env_resolve :: proc(e: ^Env, name: string, vm: ^Interp = nil, strict := false) -> (Value, bool, Value) {
    when JSPROF { g_prof.env_get += 1 }
    cur := e
    for cur != nil {
        when JSPROF { g_prof.env_saltos += 1 } // custo REAL da cadeia: niveis percorridos
        if cur.is_with && vm != nil {
            if with_has_binding(vm, with_object(cur), name) {
                if vm.throwing do return nil, true, nil
                v := with_get_binding(vm, with_object(cur), name, strict)
                return v, true, with_object(cur)
            }
            cur = cur.parent
            continue
        }
        if v, ok := cur.vars[name]; ok {
            if vm != nil && cur.uninitialized[name] {
                throw_reference_error(vm, fmt.tprintf("Cannot access '%s' before initialization", name))
                return nil, true, nil
            }
            return v, true, nil
        }
        // live binding de import: resolve no escopo do módulo exportador AGORA
        if cur.aliases != nil {
            if a, ok := cur.aliases[name]; ok {
                av, aok := env_get(a.src, a.local, vm)
                return av, aok, nil
            }
        }
        cur = cur.parent
    }
    return nil, false, nil
}

// Binda `name` como live binding de `local` no escopo `src` (ver Env_Alias).
env_alias :: proc(e: ^Env, name: string, src: ^Env, local: string) {
    if src == nil do return
    if e.aliases == nil do e.aliases = make(map[string]Env_Alias)
    e.aliases[name] = Env_Alias{src = src, local = local}
}

env_define :: proc(e: ^Env, name: string, v: Value) {
    if e.uninitialized != nil do delete_key(&e.uninitialized, name)
    e.vars[name] = v
}

// Declara um binding `const`: define o valor e marca o nome como imutável NESTE
// escopo. A marca é por escopo (não por nome), então um `const x` interno e um
// `let x` externo continuam independentes — e um `for (const x of ...)`, que
// redefine o binding a cada iteração num escopo novo, segue funcionando (o rebind
// passa por env_define, não por env_assign).
env_define_const :: proc(e: ^Env, name: string, v: Value) {
    env_define(e, name, v)
    if e.consts == nil do e.consts = make(map[string]bool)
    e.consts[name] = true
}

// Atribui a um binding EXISTENTE, subindo a cadeia. Lança TypeError se o binding
// encontrado for `const` — antes a reatribuição passava calada, e um bug que o
// browser real rejeita corrompia estado aqui em silêncio.
env_assign :: proc(vm: ^Interp, e: ^Env, name: string, v: Value, strict := false) {
    cur := e
    root := e
    for cur != nil {
        if _, ok := cur.vars[name]; ok {
            if cur.uninitialized[name] {
                throw_reference_error(vm, fmt.tprintf("Cannot access '%s' before initialization", name))
                return
            }
            if cur.consts != nil && cur.consts[name] {
                throw_type_error(vm, "Assignment to constant variable.")
                return
            }
            cur.vars[name] = v
            if cur.mapped_args != nil do args_param_written(cur.mapped_args, name, v)
            return
        }
        // ambiente de objeto (`with`): SetMutableBinding = Set(obj, N, V) — grava no
        // objeto se ele tem o nome, senão segue p/ o escopo de fora. Testado só depois
        // do `vars` (vazio num ambiente de objeto): o acerto comum não paga nada.
        if cur.is_with {
            if with_has_binding(vm, with_object(cur), name) {
                if vm.throwing do return
                with_set_binding(vm, with_object(cur), name, v, strict)
                return
            }
            cur = cur.parent
            continue
        }
        if alias, ok := cur.aliases[name]; ok {
            if env_uninitialized(alias.src, alias.local) do throw_reference_error(vm, "Cannot access import before initialization")
            else do throw_type_error(vm, "Assignment to import binding")
            return
        }
        root = cur
        cur = cur.parent
    }
    // strict: atribuir a referência IRRESOLÚVEL é ReferenceError (spec PutValue).
    // Prop da janela (`window.x = 1; x = 2`) resolve — só o nome que não existe
    // em lugar nenhum lança.
    if strict {
        if _, ok := lookup_ident(vm, e, name); !ok {
            throw_reference_error(vm, fmt.tprintf("%s is not defined", name))
            return
        }
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
        regex_write_source(sb, x.source) // `(?:)` p/ vazia, `/` escapado
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
        write_number(sb, f64(x.size))
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
    // Objeto como chave: ToPropertyKey = ToPrimitive(hint string) — o toString/
    // @@toPrimitive do objeto decide. Antes ia direto ao to_text (formatador de
    // DEBUG): `o[{toString(){return "a"}}]` não achava `o.a`, e `o[Object(sym)]`
    // não chegava ao símbolo. Se o ToPrimitive lançar, a chave é "" e a exceção
    // propaga pelo vm.throwing do chamador.
    if !is_primitive(v) {
        p := to_primitive(vm, v, false, "string")
        if vm.throwing do return ""
        if !is_primitive(p) do return "" // não deveria: to_primitive devolve primitivo ou lança
        return key_string(vm, p)
    }
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
// `text` passa a ser POSSE do buffer (clone antes de passar). Visível no pacote:
// avisos do HOST (dom_forms.odin: envio POST não suportado) aparecem no DevTools.
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
    mo_task_enter(vm)
    defer mo_task_exit(vm) // após reportar/limpar o resultado ou erro síncrono
    console_capture(vm, .Input, strings.clone(src))

    v := vm_exec(vm, src)          // escopo global (env=nil), devolve o valor de conclusão
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
    bf.name = own_str_raw(vm, fmt.tprintf("bound %s", target.name))
    bf.non_constructor = target.non_constructor || target.is_arrow || target.is_async || target.is_generator
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
    defer strings.builder_destroy(&sb)
    return own_str(vm, strings.to_string(sb))
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
    // units, inclusive para caracteres astrais); senão, numérico.
    // 'b' > 'a', '2024-06' < '2024-07' (datas ISO) etc.
    case .Lt:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return js_string_compare(ls, rs) < 0 }
        return as_number(l) <  as_number(r)
    case .Gt:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return js_string_compare(ls, rs) > 0 }
        return as_number(l) >  as_number(r)
    case .LtEq:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return js_string_compare(ls, rs) <= 0 }
        return as_number(l) <= as_number(r)
    case .GtEq:
        if ls, lok := l.(string); lok { if rs, rok := r.(string); rok do return js_string_compare(ls, rs) >= 0 }
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
    if p := proxy_state(r); p != nil do return proxy_has(vm, p, key)
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
        if idx, ok := array_index_name(key); ok do return arr_has_index(o, idx)
        if o.props != nil { if _, ok := o.props[key]; ok do return true }
        if key == "length" do return true
        if o.args != nil { // `arguments`: callee/iterator próprios, cadeia de Object.prototype
            if key == "callee" || key == vm.sym_iterator_key do return true
            if _, ok := vm.object_methods[key]; ok do return true
            if vm.object_proto != nil do return js_in(vm, l, vm.object_proto)
            return false
        }
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
    // Bound functions delegate OrdinaryHasInstance to their target.
    if rf.bind_target != nil do return js_instanceof(vm, l, rf.bind_target)
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
        if lv.args != nil do return rf.name == "Object" // `arguments` não é Array
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
    if !okey_alive(o, k) do append(&o.korder, k)
    o.props[k] = v
}

// A chave existe como prop própria — de DADO ou ACCESSOR. A ordem de inserção da
// spec (OrdinaryOwnPropertyKeys) não distingue os dois, mas getters/setters de
// literal e de defineProperty não entravam no korder: `{get b(){}, c:1, a:1}` saía
// `c,a,b` em Object.keys/JSON/for-in (e em ordem de MAP do Odin, não-determinística,
// quando havia mais de um accessor).
okey_alive :: proc(o: ^Object, k: string) -> bool {
    if _, e := o.props[k]; e do return true
    if o.getters != nil { if _, e := o.getters[k]; e do return true }
    if o.setters != nil { if _, e := o.setters[k]; e do return true }
    return false
}

// Registra a chave de um accessor que está sendo CRIADO na ordem de inserção.
// Chamar ANTES de gravar em getters/setters (redefinir mantém a posição).
okey_accessor :: proc(o: ^Object, k: string) {
    if !okey_alive(o, k) do append(&o.korder, k)
}

// Remove uma data-prop mantendo korder coerente (re-inserir depois de deletar
// deve ir p/ o FIM da ordem, como na spec).
oremove :: proc(o: ^Object, k: string) {
    if okey_alive(o, k) {
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
own_enum_keys :: proc(vm: ^Interp, o: ^Object, out: ^[dynamic]string) {
    own_string_keys(vm, o, out, false)
}

// Mesma ordem, com `all` = inclui as NÃO-enumeráveis (Object.getOwnPropertyNames).
own_string_keys :: proc(vm: ^Interp, o: ^Object, out: ^[dynamic]string, all: bool) {
    if o.px_handler != nil {
        proxy_keys(vm, o, out, all)
        return
    }
    if o.get == storage_get { // localStorage/sessionStorage: só as chaves armazenadas, em ordem
        st := cast(^Storage) o.host
        for k in st.keys do append(out, k)
        return
    }
    emit :: proc(o: ^Object, k: string, seen: ^map[string]bool, out: ^[dynamic]string, all: bool) {
        if is_non_enumerable_key(k) do return // símbolo ou campo privado #x
        if !all && o.attrs != nil && .Enumerable not_in prop_attrs(o, k) do return
        if seen[k] do return
        seen[k] = true
        append(out, k)
    }
    seen: map[string]bool
    defer delete(seen)
    // 0) String wrapper: os índices da string vêm antes de tudo (e "length", que não
    //    é enumerável, só na lista completa) — spec 10.4.3.3
    if s, isstr := o.prim.(string); isstr {
        for i in 0 ..< str_rlen(s) {
            k := fmt.tprintf("%d", i)
            seen[k] = true
            append(out, k)
        }
        if all { seen["length"] = true; append(out, "length") }
    }
    // 1) chaves-índice, crescente (insertion sort: quase sempre pouquíssimas)
    idx_keys: [dynamic]string
    defer delete(idx_keys)
    for k in o.props do if is_index_key(k) do append(&idx_keys, k)
    // índice de accessor (`get 0(){}`) também ordena numericamente
    if o.getters != nil do for k in o.getters do if is_index_key(k) {
        if _, d := o.props[k]; !d do append(&idx_keys, k)
    }
    if o.setters != nil do for k in o.setters do if is_index_key(k) {
        _, d := o.props[k]
        _, g := o.getters[k]
        if !d && !g do append(&idx_keys, k)
    }
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
    for k in idx_keys do emit(o, k, &seen, out, all)
    // 2) ordem de inserção registrada (dados E accessors; pula entradas obsoletas de deletes)
    for k in o.korder {
        if okey_alive(o, k) && !is_index_key(k) do emit(o, k, &seen, out, all)
    }
    // 3) sobras (escritas nativas que não passaram por oput/okey_accessor)
    for k in o.props do emit(o, k, &seen, out, all)
    if o.getters != nil do for k in o.getters do emit(o, k, &seen, out, all)
    if o.setters != nil do for k in o.setters do emit(o, k, &seen, out, all)
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
// package-visible: object.odin (descritor de índice de array) reusa.
array_index_name :: proc(name: string) -> (idx: int, ok: bool) {
    if len(name) == 0 || len(name) > 10 do return 0, false
    if name[0] == '0' && len(name) > 1 do return 0, false // "01" não é canônico
    n := 0
    for c in transmute([]u8)name {
        if c < '0' || c > '9' do return 0, false
        n = n * 10 + int(c - '0')
    }
    return n, n < 4294967295
}

// Membro de um primitivo pela cadeia do seu prototype (String/Number/Boolean.prototype
// → Object.prototype). Getter roda com this = o primitivo. found=false quando
// nada na cadeia tem a chave (o chamador cai nos mapas de dispatch).
@(private = "file")
prim_proto_lookup :: proc(vm: ^Interp, proto: ^Object, this: Value, name: string) -> (Value, bool) {
    for cur := proto; cur != nil; cur = cur.proto {
        if cur.getters != nil {
            if g, has := cur.getters[name]; has {
                if g == nil do return nil, true
                return call_function(vm, g, this, nil), true
            }
        }
        if v, has := cur.props[name]; has do return v, true
    }
    return nil, false
}

// Membro não-índice do objeto `arguments` (o.args != nil), depois das props próprias.
@(private = "file")
arguments_member :: proc(vm: ^Interp, o: ^Array, name: string) -> Value {
    if name == "callee" {
        // strict: o accessor %ThrowTypeError% (spec 10.4.4.6)
        if o.args.callee == nil || o.args.callee.strict {
            throw_type_error(vm, "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them")
            return nil
        }
        return o.args.callee
    }
    // %Array.prototype.values% — o mesmo objeto que Array.prototype[Symbol.iterator]
    if name == vm.sym_iterator_key do return vm.array_methods["values"]
    if v, found := prim_proto_lookup(vm, vm.object_proto, o, name); found do return v
    if fn, ok := vm.object_methods[name]; ok do return fn
    if name == "constructor" do return global_ctor(vm, "Object")
    return nil
}

// Visível no pacote (object.odin invoca getters ao ler values/entries/assign).
get_member :: proc(vm: ^Interp, obj: Value, name: string) -> Value {
    when JSPROF { g_prof.get_member += 1 }
    if is_nullish(obj) { // null.x / undefined.x → TypeError (spec)
        throw_type_error(vm, fmt.tprintf("Cannot read properties of %s (reading '%s')",
            obj == nil ? "undefined" : "null", name))
        return nil
    }
    if p := proxy_state(obj); p != nil { v, _ := proxy_get(vm, p, name); return v }
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
            #partial switch p in o.prim {
            case string:
                // String wrapper: `length` e os índices são props PRÓPRIAS
                // (`new String("ab")[1]`). Métodos NÃO vêm do primitivo — só da
                // cadeia (String.prototype); senão `delete String.prototype.x` não teria efeito.
                if name == "length" do return f64(str_rlen(p))
                if is_index_key(name) do return get_index(vm, p, as_number(name))
            case f64, bool:
                // Number/Boolean wrapper: nada próprio — tudo já veio da cadeia acima
            case:
                if v := get_member(vm, o.prim, name); v != nil do return v
            }
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
        if m := o.descriptors; m != nil {
            if g, has := m.getters[name]; has {
                if g == nil do return nil
                return call_function(vm, g, o, nil)
            }
            if _, has := m.setters[name]; has do return nil
        }
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
        // objeto `arguments`: é um objeto COMUM na spec — herda de Object.prototype,
        // não de Array.prototype (`arguments.map` é undefined, `instanceof Array` é
        // false), e tem `callee` e `[Symbol.iterator]` próprios.
        if o.args != nil do return arguments_member(vm, o, name)
        if vm.array_ctor != nil {
            if proto, ok := vm.array_ctor.props["prototype"].(^Object); ok {
                for cur := proto; cur != nil; cur = cur.proto {
                    if g, has := cur.getters[name]; has do return call_function(vm, g, o, nil)
                    if v, has := cur.props[name]; has do return v
                }
            }
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
        value, _ := prim_proto_lookup(vm, vm.collection_protos[o.kind], o, name)
        return value
    case ^Symbol:
        if name == "description" do return nil if o.no_desc else Value(own_str(vm, o.desc))
        if name == "constructor" do return global_ctor(vm, "Symbol")
        // resto (toString/valueOf/[Symbol.toPrimitive]) vem do %SymbolPrototype% —
        // mesmo objeto que `Symbol.prototype` expõe, para não haver duas cópias (M220)
        if vm.symbol_proto != nil {
            if v, ok := vm.symbol_proto.props[name]; ok do return v
        }
        return nil
    case string:
        if name == "length" do return f64(str_rlen(o)) // CODE POINTS ('café'.length = 4)
        // Nativo PRIMEIRO, depois a cadeia String.prototype → Object.prototype: o que
        // um polyfill ADICIONA (`String.prototype.x = ...`) vale para o primitivo.
        // ⚠️ DEGRADAÇÃO ANOTADA: SOBRESCREVER um método nativo não alcança o
        // primitivo. Proposital — com a cadeia na frente o g1.globo.com caiu de
        // ~1500 para ~300 caixas: o polyfill que a página instala por cima do
        // nativo depende de peças que o motor ainda não tem (Symbol.replace...).
        if fn, ok := vm.string_methods[name]; ok do return fn
        if v, found := prim_proto_lookup(vm, vm.string_proto, o, name); found do return v
        if name == "constructor" do return global_ctor(vm, "String")
        return nil
    case f64:
        // (3.14).toFixed(2), (255).toString(16), ... — this = o próprio número
        if fn, ok := vm.number_methods[name]; ok do return fn // nativo primeiro (ver string)
        if v, found := prim_proto_lookup(vm, vm.number_proto, o, name); found do return v
        if name == "constructor" do return global_ctor(vm, "Number")
        return nil
    case bool:
        // true.toString() / valueOf: o boxing de booleano não tinha NENHUM método
        // (`true.toString()` lançava "is not a function"). Os transpiladores usam
        // `Boolean.prototype.valueOf.call(...)` no feature-detect de Reflect.construct
        // (helper _createSuper do Babel) — sem isto o detect falha e o bundle cai
        // no caminho degradado. Ver install_boolean_proto.
        if fn, ok := vm.boolean_methods[name]; ok do return fn // nativo primeiro (ver string)
        if v, found := prim_proto_lookup(vm, vm.boolean_proto, o, name); found do return v
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
        case "length": return function_length(o)
        }
        // toda função (não-arrow) tem um `.prototype` (objeto) criado sob demanda —
        // é onde `Ctor.prototype.metodo = fn` grava e de onde `new Ctor()` herda.
        // Sem isto, construtores-função (ex.: ReactDOMRoot) perdem seus métodos.
        // EXCEÇÃO: bound functions (`.bind()`) NÃO têm `.prototype` (spec: "exotic
        // bound function objects" não recebem a prop prototype). O core-js detecta
        // bind nativo via `!boundFn.hasOwnProperty('prototype')` — se o auto-proto
        // aparecer, NATIVE_BIND=false e o core-js embrulha Map/Set e usa caminhos
        // uncurryThis alternativos (foi a raiz do bug do M97). Ver obj_has_own_property.
        if name == "prototype" && !o.is_arrow && !o.non_constructor && o.native == nil && o.bind_target == nil {
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
        if g, has := o.getters[name]; has do return call_function(vm, g, o, nil) if g != nil else nil // acessor próprio (defineProperty)
        if _, has := o.setters[name]; has do return nil // só setter: leitura é undefined
        if v, has := o.props[name]; has do return v // expando própria (ver set_member)
        switch name {
        case "source":     return regex_source_text(vm, o)
        case "flags":      return o.flags
        case "global":     return o.global
        case "ignoreCase": return o.icase
        case "multiline":  return o.multiline
        case "dotAll":     return o.dotall
        case "sticky":     return o.sticky
        case "unicode":    return o.unicode
        case "unicodeSets": return o.unicode_sets
        case "hasIndices": return o.has_indices
        case "lastIndex":  return f64(o.last_index)
        // test/exec/toString vêm do RegExp.prototype (o fallback abaixo): assim um
        // `RegExp.prototype.exec = fn` vale para todas as regex, como na spec.
        case "test":       if vm.regex_proto == nil do return vm.regex_test_fn
        case "exec":       if vm.regex_proto == nil do return vm.regex_exec_fn
        case "toString":   if vm.regex_proto == nil do return vm.regex_tostring_fn // antes caía no de Object: "[object RegExp]"
        case "constructor": return global_ctor(vm, "RegExp")
        }
        // RegExp.prototype de verdade: os @@match/@@split/... nativos e o que o
        // código do usuário pendurar ali. Antes a instância não via o protótipo.
        if vm.regex_proto != nil {
            if v, ok := vm.regex_proto.props[name]; ok do return v
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
//
// Devolve o resultado do [[Set]] da spec: false = a escrita foi REJEITADA
// (writable:false, accessor só com getter, prop nova em objeto não-extensível,
// prop em primitivo). Sloppy ignora o false; código strict o transforma em
// TypeError (strict_write_failed). ⚠️ Limitação do MOTOR (Map/RegExp/host que não
// guardam a prop) devolve TRUE: lançar ali seria erro que o navegador não dá.
set_member :: proc(vm: ^Interp, obj: Value, name: string, val: Value) -> bool {
    if is_nullish(obj) { // null.x = v → TypeError (spec)
        throw_type_error(vm, fmt.tprintf("Cannot set properties of %s (setting '%s')",
            obj == nil ? "undefined" : "null", name))
        return true // já lançou: o chamador não deve lançar de novo
    }
    if p := proxy_state(obj); p != nil { proxy_set(vm, p, name, val); return true }
    #partial switch o in obj {
    case ^Object:
        if o.set != nil {
            if o.set(vm, o, name, val) do return true
        }
        // subclasse de Array (M136): `this.length = 0` age no array embrulhado
        if name == "length" && o.prim != nil {
            if a, isarr := o.prim.(^Array); isarr do return array_set_length(vm, a, val)
        }
        // subclasse de RegExp: `lastIndex` é o estado do exec/test, que mora na ^Regex
        // embrulhada. Como prop própria do wrapper, `r.lastIndex = 0` não reiniciava
        // nada e a leitura passava a divergir do que o exec usa.
        if name == "lastIndex" && o.prim != nil {
            if re, isre := o.prim.(^Regex); isre do return set_member(vm, re, name, val)
        }
        // setter na cadeia, NÍVEL a NÍVEL (espelho do get_member): uma data
        // property num nível mais próximo sombreia setter herdado — a escrita
        // vira own em vez de invocar o set de um ancestral.
        for cur := o; cur != nil; cur = cur.proto {
            if cur.setters != nil {
                if s, ok := cur.setters[name]; ok { call_function(vm, s, o, []Value{val}); return true }
            }
            // accessor SÓ com getter (próprio ou herdado): a escrita falha — não
            // vira data property própria por cima do getter
            if cur.getters != nil {
                if _, ok := cur.getters[name]; ok do return false
            }
            if _, ok := cur.props[name]; ok {
                // data property HERDADA writable:false também barra a escrita
                // (spec OrdinarySet: "override mistake" de proto congelado)
                if cur != o && .Writable not_in prop_attrs(cur, name) do return false
                break
            }
        }
        // writable:false (ou prop nova em objeto não-extensível)
        if !prop_writable(o, name) do return false
        oput(o, name, val)
        return true
    case ^Function:
        if a, explicit := o.attrs[name]; explicit {
            if _, accessor := o.getters[name]; accessor {
                if setter, ok := o.setters[name]; ok && setter != nil {
                    call_function(vm, setter, o, []Value{val})
                    return true
                }
                return false
            }
            if .Writable not_in a do return false
        }
        // setter static de classe (static set x(v){}) — invoca com this = a classe
        if o.setters != nil {
            if s, ok := o.setters[name]; ok { call_function(vm, s, o, []Value{val}); return true }
        }
        // escrever propriedade estática numa função (ex.: Ctor.prop = x)
        if o.props == nil do o.props = make(map[string]Value)
        o.props[name] = val
        return true
    case ^Regex:
        if s, has := o.setters[name]; has {
            if s == nil do return false
            call_function(vm, s, o, []Value{val}); return true
        }
        if _, has := o.getters[name]; has do return false // acessor sem setter: não grava
        if name == "lastIndex" { // p/ loops de exec global
            if o.last_index_ro do return false // writable:false — quem pede Set(..., true) lança
            o.last_index = as_int(val); return true
        }
        // demais props: expando PRÓPRIA da instância (`re.toString = ...`, marcas de
        // libs) — sombreia os métodos no get_member, como numa propriedade própria.
        if o.props == nil do o.props = make(map[string]Value)
        if _, has := o.props[name]; has {
            o.props[name] = val
        } else {
            o.props[strings.clone(name)] = val
        }
        return true
    case ^Array:
        // prop não-índice num array (m.index custom, marcações de libs); índices
        // inteiros passam por set_index.
        if name == "length" do return array_set_length(vm, o, val)
        if idx, indexed := array_index_name(name); indexed do return set_index(vm, o, f64(idx), val)
        if m := o.descriptors; m != nil {
            if s, has := m.setters[name]; has {
                if s == nil do return false
                call_function(vm, s, o, []Value{val}); return true
            }
            if _, has := m.getters[name]; has do return false
        }
        if o.frozen do return false
        if _, exists := o.props[name]; exists {
            if .Writable not_in array_attrs(o, name) do return false
        } else if o.sealed { return false }
        if o.props == nil do o.props = make(map[string]Value)
        o.props[name] = val
        return true
    case f64, bool, string, ^Symbol, ^BigInt:
        return false // primitivo não guarda prop: `"s".x = 1` é ignorado / TypeError strict
    }
    return true // ^Collection etc.: limitação do motor, não rejeição
}

// [[Set]] devolveu false num alvo de código STRICT: TypeError (spec PutValue).
// Em sloppy a mesma escrita é ignorada em silêncio. Mensagens no formato do V8.
@(private = "file")
strict_write_failed :: proc(vm: ^Interp, obj: Value, key: string) {
    if vm.throwing do return
    if is_primitive(obj) {
        throw_type_error(vm, fmt.tprintf("Cannot create property '%s' on %s", key, value_kind_name(obj)))
        return
    }
    throw_type_error(vm, fmt.tprintf("Cannot assign to read only property '%s' of object", key))
}

// `arr.length = v` (ArraySetLength, spec 10.4.2.4): trunca ou estende. Antes a escrita
// era IGNORADA — `buf.length = 0` (o idioma clássico de reuso de buffer) não limpava nada.
// A spec coage DUAS vezes (ToUint32 e ToNumber, cada uma com seu valueOf) e exige que
// concordem, senão RangeError: -1, 1.5, NaN e 2^32 são inválidos.
// Estender cria BURACOS (arr_mark_holes); frozen/sealed ignoram a escrita (sloppy).
// package-visible: Reflect.set/defineProperty podem reusar.
array_set_length :: proc(vm: ^Interp, o: ^Array, val: Value) -> bool {
    u := to_number(vm, val)
    if vm.throwing do return true
    n := to_number(vm, val)
    if vm.throwing do return true
    // ToUint32(u) == n  ⇔  n é inteiro em [0, 2^32) (u e n vêm da mesma coerção)
    u32ok := u == u && math.trunc(u) == u && u >= 0 && u < 4294967296
    if !u32ok || n != u {
        vm.thrown = mk_error(vm, "RangeError", "Invalid array length"); vm.throwing = true
        return true
    }
    new_len := int(n)
    if .Writable not_in array_attrs(o, "length") do return false
    if o.frozen || o.sealed do return new_len == len(o.items) // mudar o length: rejeitado
    if new_len <= len(o.items) {
        if o.descriptors != nil {
            for i := len(o.items) - 1; i >= new_len; i -= 1 {
                if !array_delete_property(o, key_string(vm, f64(i))) {
                    resize(&o.items, i + 1)
                    arr_holes_trim(o)
                    return false
                }
            }
        }
        resize(&o.items, new_len)
        arr_holes_trim(o)
        return true
    }
    // mesma guarda de set_index: `a.length = 4e9` alocaria GBs de undefined
    if new_len > 100_000_000 do return true
    arr_mark_holes(o, len(o.items), new_len)
    for len(o.items) < new_len do append(&o.items, nil)
    return true
}

// package-visible: proxy.odin (default get/Reflect.get) reusa.
get_index :: proc(vm: ^Interp, obj: Value, key: Value) -> Value {
    when JSPROF { g_prof.get_index += 1 }
    #partial switch o in obj {
    case ^Array:
        // só chave numérica INTEIRA indexa items; "length"/métodos/"foo" caem
        // no get_member (antes, as_number("foo")→0 lia items[0] por engano)
        if o.descriptors == nil {
            if n, numeric := key.(f64); numeric && n >= 0 && n < 4294967295 && math.trunc(n) == n {
                idx := int(n)
                return o.items[idx] if idx < len(o.items) else nil
            }
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
        // s[i]: uma unidade UTF-16, inclusive metades isoladas de surrogates.
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
// Devolve o [[Set]] da spec, como set_member.
set_index :: proc(vm: ^Interp, obj: Value, key: Value, val: Value) -> bool {
    #partial switch o in obj {
    case ^Array:
        // Numeric indices only need a transient map lookup key. Do not retain
        // a new VM string on every ordinary element assignment.
        name: string
        buf: [24]u8
        if n, numeric := key.(f64); numeric && n >= 0 && n < 4294967295 && math.trunc(n) == n {
            name = strconv.write_int(buf[:], i64(n), 10)
        } else { name = key_string(vm, key) }
        idx, indexed := array_index_name(name)
        if !indexed do return set_member(vm, obj, name, val)
        if m := o.descriptors; m != nil {
            if s, has := m.setters[name]; has {
                if s == nil do return false
                call_function(vm, s, o, []Value{val}); return true
            }
            if _, has := m.getters[name]; has do return false
        }
        if arr_has_index(o, idx) && .Writable not_in array_attrs(o, name) do return false
        if idx >= len(o.items) && .Writable not_in array_attrs(o, "length") do return false
        if idx < 0 || idx > 100_000_000 do return true // guarda (limitação): arr[1e12]=x alocaria GBs
        if o.frozen do return false // Object.freeze([...]): item não muda
        // seal/preventExtensions: os itens EXISTENTES seguem graváveis, o array é que
        // não cresce mais.
        if !arr_has_index(o, idx) && (o.sealed || o.frozen) do return false
        if idx > len(o.items) do arr_mark_holes(o, len(o.items), idx) // a[9]=x: 0..8 são buracos
        for len(o.items) <= idx do append(&o.items, nil)
        o.items[idx] = val
        if val == nil do arr_fill_slot(o, idx) // a[i]=undefined: existe, não é buraco
        // `arguments[i] = v` mapeado: o parâmetro i é o MESMO binding
        if o.args != nil && args_mapped(o.args, idx) do o.args.env.vars[o.args.params[idx]] = val
        return true
    case ^Object:
        // subclasse de Array (M136): índice numérico escreve no array embrulhado.
        if o.prim != nil {
            if n := as_number(key); n == n && math.trunc(n) == n {
                if _, isarr := o.prim.(^Array); isarr do return set_index(vm, o.prim, key, val)
            }
        }
        // via set_member: honra setters (accessor/defineProperty) e freeze.
        return set_member(vm, o, key_string(vm, key), val)
    case ^Function:
        // `fn[k] = v` (chave computada) numa função. FALTAVA — só `fn.x = v`
        // (nomeado) passava por set_member; o computado caía aqui e era IGNORADO
        // silenciosamente. Era a RAIZ de "$ is not a function": jQuery.extend copia
        // as props via `target[c] = src[c]` sobre o objeto jQuery (uma FUNÇÃO), então
        // jQuery.ready/etc. nunca eram setados → `jQuery.ready.promise=` lançava →
        // init do jQuery abortava → `$`/`jQuery` nunca eram definidos. set_member já
        // trata ^Function (grava em fn.props / invoca setters static).
        return set_member(vm, o, key_string(vm, key), val)
    case nil, JS_Null, f64, bool, string, ^Symbol, ^BigInt:
        // `null[k] = v` lança como `null.x = v`; primitivo devolve false (set_member)
        return set_member(vm, obj, key_string(vm, key), val)
    case ^Regex:
        // `re[k] = v` computado: expando própria via set_member, como `re.x = v`.
        // Antes era IGNORADO, e `re[Symbol.match] = false` (o jeito da spec de fazer
        // uma regex passar por string no startsWith/includes) não tinha efeito.
        return set_member(vm, o, key_string(vm, key), val)
    }
    return true // ^Collection: o motor não guarda a prop (limitação)
}

// Lê/escreve um alvo cuja base/chave JÁ foram avaliadas (obj/key) — o .Assign
// resolve a referência uma vez e reusa aqui (ordem da spec, sem reavaliação).
@(private = "file")
ref_read :: proc(vm: ^Interp, t: ^Node, env: ^Env, obj: Value, key: Value) -> Value {
    #partial switch t.kind {
    case .Ident:
        v, _ := env_get(env, t.name, vm)
        return v
    case .Member:
        return get_member(vm, obj, t.name)
    case .Index:
        return get_index(vm, obj, key)
    }
    return nil
}

// `strict`: o nó de escrita é de código strict — rejeição vira TypeError e nome
// não declarado, ReferenceError.
@(private = "file")
ref_write :: proc(vm: ^Interp, t: ^Node, env: ^Env, obj: Value, key: Value, val: Value, strict := false) {
    #partial switch t.kind {
    case .Ident:
        env_assign(vm, env, t.name, val, strict)
    case .Member:
        if !set_member(vm, obj, t.name, val) && strict do strict_write_failed(vm, obj, t.name)
    case .Index:
        if !set_index(vm, obj, key, val) && strict do strict_write_failed(vm, obj, key_string(vm, key))
    }
}

// Lê/escreve o valor atual de um alvo de atribuição (Ident/Member/Index).
// Usado por ++/-- (avalia a base/chave a cada chamada; em obj.x++ o objeto é
// avaliado duas vezes — aceitável, alvos de ++ raramente têm efeitos colaterais).
@(private = "file")
read_target :: proc(vm: ^Interp, t: ^Node, env: ^Env) -> Value {
    #partial switch t.kind {
    case .Ident:
        v, _ := env_get(env, t.name, vm)
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
write_target :: proc(vm: ^Interp, t: ^Node, val: Value, env: ^Env, strict := false) {
    #partial switch t.kind {
    case .Ident:
        env_assign(vm, env, t.name, val, strict)
    case .Member:
        obj := eval(vm, t.left, env)
        if vm.throwing do return
        if !set_member(vm, obj, t.name, val) && strict do strict_write_failed(vm, obj, t.name)
    case .Index:
        obj := eval(vm, t.left, env)
        key := eval(vm, t.right, env)
        if vm.throwing do return
        if !set_index(vm, obj, key, val) && strict do strict_write_failed(vm, obj, key_string(vm, key))
    }
}

// Resolve o objeto-iterador de `v` pelo protocolo de iteração:
//   (1) se `v` já É um iterador (tem .next), ele mesmo;
//   (2) senão, se `v` tem um método Symbol.iterator, chama-o (this=v) p/ obtê-lo.
// Devolve (iterador, ok). ok=false → `v` não é iterável por protocolo (o chamador
// cai nos caminhos nativos Array/string/Collection).
get_iterator :: proc(vm: ^Interp, v: Value) -> (Value, bool) {
    if is_iterator_obj(v) do return v, true
    #partial switch _ in v {
    case ^Object, ^Collection:
    case: return nil, false
    }
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
                    for e in s.entries do if !e.dead do append(&out, e.key)
                } else {
                    for e in s.entries {
                        if e.dead do continue
                        pair := new_array(vm)
                        append(&pair.items, e.key); append(&pair.items, e.val)
                        append(&out, pair)
                    }
                }
            case string:
                // ...str = um item por code point (strings são iteráveis)
                starts: [dynamic]int
                defer delete(starts)
                js_code_point_offsets(s, &starts)
                for k := 0; k + 1 < len(starts); k += 1 {
                    append(&out, own_str(vm, s[starts[k]:starts[k + 1]]))
                }
            }
            // spread de outros valores: ignora
        } else {
            append(&out, eval(vm, a, env))
        }
        // um argumento que LANÇA aborta a lista: os seguintes não são avaliados
        // (efeito colateral deles não pode acontecer) — quem chama confere throwing
        if vm.throwing do break
    }
    return out
}

// Um passo do iterador de um padrão de array (IteratorStepValue, spec 7.4.8): devolve
// o próximo valor, ou undefined com `done^ = true` quando o iterador terminou. Erro
// em next()/done/value também marca done — a spec NÃO fecha um iterador que falhou.
@(private = "file")
pattern_iter_step :: proc(vm: ^Interp, iter: Value, next_fn: ^Function, done: ^bool) -> Value {
    if done^ do return nil
    if next_fn == nil || step_guard(vm) { done^ = true; return nil }
    r := call_function(vm, next_fn, iter, nil)
    if vm.throwing { done^ = true; return nil }
    if is_primitive(r) {
        done^ = true
        throw_type_error(vm, "Iterator result is not an object")
        return nil
    }
    d := get_member(vm, r, "done")
    if vm.throwing || truthy(d) { done^ = true; return nil }
    v := get_member(vm, r, "value")
    if vm.throwing { done^ = true; return nil }
    return v
}

// Nome do tipo primitivo p/ mensagem de erro do destructuring.
@(private = "file")
value_kind_name :: proc(v: Value) -> string {
    #partial switch _ in v {
    case nil:     return "undefined"
    case JS_Null: return "null"
    case f64:     return "number"
    case bool:    return "boolean"
    case string:  return "string"
    case ^Symbol: return "symbol"
    case ^BigInt: return "bigint"
    }
    return "object"
}

// Alvo de destructuring-EXPRESSÃO (`[o.x, a[k]] = v`) com o objeto e a chave JÁ
// avaliados: a spec avalia o alvo ANTES de ler o valor — `[ {}[f()] ] = it` chama
// f() antes do next(), e se f() lança o iterador ainda é fechado.
@(private = "file")
Target_Ref :: struct {
    node: ^Node,
    obj:  Value,
    key:  Value,
}

@(private = "file")
eval_target_ref :: proc(vm: ^Interp, t: ^Node, env: ^Env) -> (ref: Target_Ref) {
    ref.node = t
    #partial switch t.kind {
    case .Member:
        ref.obj = eval(vm, t.left, env)
    case .Index:
        ref.obj = eval(vm, t.left, env)
        if !vm.throwing do ref.key = eval(vm, t.right, env)
    }
    return
}

@(private = "file")
put_target_ref :: proc(vm: ^Interp, ref: Target_Ref, val: Value, env: ^Env, strict := false) {
    #partial switch ref.node.kind {
    case .Ident:
        env_assign(vm, env, ref.node.name, val, strict)
    case .Member:
        if !set_member(vm, ref.obj, ref.node.name, val) && strict do strict_write_failed(vm, ref.obj, ref.node.name)
    case .Index:
        if !set_index(vm, ref.obj, ref.key, val) && strict do strict_write_failed(vm, ref.obj, key_string(vm, ref.key))
    }
}

// IteratorClose (spec 7.4.11) do destructuring: o padrão acabou e o iterador NÃO
// terminou — chama return(). Diferente do iterator_close do for-of, roda também com
// exceção em voo (default/alvo que lançou), e aí a exceção ORIGINAL prevalece sobre
// qualquer erro do return(). Sem exceção em voo, erro do return() propaga e um
// resultado que não é objeto vira TypeError.
@(private = "file")
pattern_iter_close :: proc(vm: ^Interp, iter: Value) {
    if vm.gen_hard_kill do return
    saved_throw, saved_exc := vm.throwing, vm.thrown
    saved_ret, saved_val := vm.returning, vm.ret_val
    saved_break, saved_continue := vm.breaking, vm.continuing
    vm.throwing = false; vm.thrown = nil
    vm.returning = false; vm.ret_val = nil
    vm.breaking = false; vm.continuing = false
    ret := get_member(vm, iter, "return")
    if !vm.throwing {
        #partial switch fn in ret {
        case nil, JS_Null: // sem return(): nada a fechar
        case ^Function:
            r := call_function(vm, fn, iter, nil)
            if !vm.throwing && is_primitive(r) do throw_type_error(vm, "Iterator result is not an object")
        case:
            throw_type_error(vm, "iterator.return is not a function")
        }
    }
    if vm.gen_hard_kill do return
    if saved_throw {
        vm.throwing = true; vm.thrown = saved_exc
    }
    if !vm.throwing {
        vm.returning = saved_ret; vm.ret_val = saved_val
        vm.breaking = saved_break; vm.continuing = saved_continue
    }
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
    // `strict` (do nó .Pattern) só pesa na ATRIBUIÇÃO: nome não declarado lança.
    bind_one :: proc(vm: ^Interp, env: ^Env, name: string, v: Value, declare: bool, is_const: bool, strict: bool) {
        if declare {
            if is_const do env_define_const(env, name, v)
            else do env_define(env, name, v)
        } else {
            env_assign(vm, env, name, v, strict)
        }
    }
    val := val
    // chaves de objeto consumidas por elementos de chave COMPUTADA (`{ [k]: v }`):
    // só o runtime conhece essas chaves, então um rest de objeto (`...resto`) precisa
    // excluí-las além das estáticas (pattern_has_key). Preenchido ao processar cada
    // elemento computado; o rest é sempre o último, logo já está completo ao chegar lá.
    computed_consumed: map[string]bool
    defer delete(computed_consumed)
    // destructuring de ARRAY sobre um iterável não-array. Array e string seguem o
    // caminho rápido (get_index os cobre por índice); Set/Map usam iteradores vivos.
    // Iterável por PROTOCOLO (generator, iterador, objeto com Symbol.iterator) é
    // PUXADO um next() por elemento — `[a] = gen()` puxa UM valor, não drena o
    // gerador — e fechado (return()) no fim se não terminou (spec 8.6.2/13.15.5.5).
    iter: Value
    iter_next: ^Function
    by_protocol, iter_done := false, false
    // fonte que não se desestrutura lança MESMO com padrão vazio (`[] = 1`,
    // `({} = null)`): GetIterator / RequireObjectCoercible da spec.
    #partial switch _ in val {
    case nil, JS_Null:
        kind := value_kind_name(val)
        if !pat.bval {
            throw_type_error(vm, fmt.tprintf("%s is not iterable", kind))
        } else if len(pat.body) > 0 && !pat.body[0].bval && pat.body[0].third == nil {
            // nomeia a 1ª chave, como o V8: diz QUAL leitura falhou (pista p/ site real)
            throw_type_error(vm, fmt.tprintf("Cannot destructure property '%s' of '%s' as it is %s.", pat.body[0].str, kind, kind))
        } else {
            throw_type_error(vm, fmt.tprintf("Cannot destructure '%s' as it is %s.", kind, kind))
        }
        return
    case f64, bool, ^Symbol, ^BigInt:
        if !pat.bval {
            throw_type_error(vm, fmt.tprintf("%s is not iterable", value_kind_name(val)))
            return
        }
    }
    if !pat.bval {
        #partial switch v in val {
        case ^Array, string: // caminho rápido posicional
        case ^Object, ^Collection:
            if it, ok := get_iterator(vm, v); ok {
                iter, iter_next, by_protocol = it, iterator_next_fn(it), true
            } else if vm.throwing {
                return
            } // não-iterável: cai no acesso por índice (array-like com .length)
        }
    }
    defer if by_protocol && !iter_done do pattern_iter_close(vm, iter)
    for el, i in pat.body {
        if vm.throwing do break
        if el.bval { // rest: recolhe o restante
            if pat.bval {
                // objeto: chaves ainda não consumidas por este padrão (ordem da fonte)
                rest := new_object(vm)
                if src, ok := val.(^Object); ok {
                    keys: [dynamic]string
                    defer delete(keys)
                    own_enum_keys(vm, src, &keys)
                    for k in keys {
                        if !pattern_has_key(pat, k) && !computed_consumed[k] do oput(rest, k, get_member(vm, src, k))
                    }
                }
                bind_one(vm, env, el.name, rest, declare, is_const, pat.strict)
            } else {
                // array: itens a partir do índice atual
                rest_ref: Target_Ref
                if el.left != nil && el.left.kind != .Pattern {
                    rest_ref = eval_target_ref(vm, el.left, env) // alvo ANTES de drenar
                    if vm.throwing do break
                }
                rest := new_array(vm)
                if by_protocol {
                    for !iter_done { // rest DRENA o iterador (aí não há o que fechar)
                        v := pattern_iter_step(vm, iter, iter_next, &iter_done)
                        if iter_done do break
                        append(&rest.items, v)
                    }
                    if vm.throwing do break
                } else if src, ok := val.(^Array); ok {
                    for j := i; j < len(src.items); j += 1 do append(&rest.items, src.items[j])
                }
                if el.left != nil && el.left.kind == .Pattern {
                    bind_pattern(vm, el.left, rest, env, declare, is_const) // [...[a, b]]
                } else if el.left != nil {
                    put_target_ref(vm, rest_ref, rest, env, pat.strict) // [...o.x] = v (só expressão)
                } else {
                    bind_one(vm, env, el.name, rest, declare, is_const, pat.strict)
                }
            }
            continue
        }
        v: Value
        // alvo member/index (`[o.x] = v`, só expressão): avaliado ANTES de ler o
        // valor — depois da chave computada, antes do get/next() (spec 13.15.5.5-6)
        ref: Target_Ref
        has_ref := el.left != nil && el.left.kind != .Pattern
        if pat.bval {
            key := el.str                         // objeto: pela chave estática
            if el.third != nil { // chave computada: { [expr]: alvo }
                key = key_string(vm, eval(vm, el.third, env))
                if vm.throwing do break
                computed_consumed[key] = true
            }
            if has_ref { ref = eval_target_ref(vm, el.left, env); if vm.throwing do break }
            v = get_member(vm, val, key)
        } else {
            if has_ref { ref = eval_target_ref(vm, el.left, env); if vm.throwing do break }
            if by_protocol {
                v = pattern_iter_step(vm, iter, iter_next, &iter_done) // buraco também consome
                if vm.throwing do break
            } else {
                v = get_index(vm, val, f64(i))    // array: pelo índice posicional
            }
        }
        if v == nil && el.right != nil {
            v = eval(vm, el.right, env)
            if vm.throwing do break
            // NamedEvaluation applies only to anonymous definitions used as
            // defaults for identifiers, never to an existing function value.
            name := el.name
            if has_ref && el.left.kind == .Ident do name = el.left.name
            if name != "" && (el.right.kind == .Func || el.right.kind == .Class) && el.right.name == "" {
                if f, ok := v.(^Function); ok do f.name = name
            }
        }
        if el.left != nil {
            if el.left.kind == .Pattern {
                bind_pattern(vm, el.left, v, env, declare, is_const) // aninhado
            } else {
                put_target_ref(vm, ref, v, env, pat.strict)
            }
        } else if el.name != "" {
            bind_one(vm, env, el.name, v, declare, is_const, pat.strict)
        }
        // el.name=="" && el.left==nil => buraco de array: ignora
    }
}

// Roda o corpo de um for-of/for-in para um valor `v` (escopo por iteração; closures
// capturam bindings distintos). Devolve true se o loop deve PARAR (break/return/throw
// ou um continue/break rotulado que mira um loop externo).
@(private = "file")
for_of_run_body :: proc(vm: ^Interp, n: ^Node, env: ^Env, v: Value, my_label: string, cv: ^Value) -> (stop: bool) {
    iter_env := new_env(vm, env)
    if n.third != nil {
        // alvo de ATRIBUIÇÃO sem declaração: `for (o.k in obj)` / `for ([a, b] of pares)`
        if n.third.kind == .Pattern {
            bind_pattern(vm, n.third, v, env, declare = false)
        } else {
            write_target(vm, n.third, v, env, n.strict)
        }
        if vm.throwing do return true
    } else if n.stat {
        // for (var x of/in ...): function-scoped — atribui à var JÁ ÍÇADA no escopo
        // de função (mesmo slot em todas as iterações; vaza p/ fora com o último
        // valor). env_assign sobe a cadeia até achar o binding hoisted.
        if n.left != nil {
            bind_pattern(vm, n.left, v, env, declare = false)
        } else {
            env_assign(vm, env, n.name, v, n.strict)
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
        env_assign(vm, env, n.name, v, n.strict) // for (x of ...) sem declaração
    }
    // conclusão do laço: o último valor NÃO vazio do corpo (como no .While)
    if r := eval(vm, n.callee, iter_env); !is_empty_completion(r) do cv^ = r
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

// Fecha um iterador assíncrono preservando a conclusão abrupta do corpo.
async_iterator_close :: proc(vm: ^Interp, iter: Value) {
    saved_throw, saved_exc := vm.throwing, vm.thrown
    saved_ret, saved_val := vm.returning, vm.ret_val
    saved_break, saved_continue := vm.breaking, vm.continuing
    vm.throwing = false; vm.thrown = nil
    vm.returning = false; vm.ret_val = nil
    vm.breaking = false; vm.continuing = false
    ret := get_member(vm, iter, "return")
    if fn, ok := ret.(^Function); ok && !vm.throwing {
        result := call_function(vm, fn, iter, nil)
        if !vm.throwing do await_value(vm, result)
    }
    if vm.gen_hard_kill do return
    if saved_throw {
        vm.throwing = true; vm.thrown = saved_exc
    }
    if !vm.throwing {
        vm.returning = saved_ret; vm.ret_val = saved_val
        vm.breaking = saved_break; vm.continuing = saved_continue
    }
}

// for (x of it) / for (x in it).
//
// Iteráveis por PROTOCOLO (generator, iterador de Map/Set, objeto com Symbol.iterator)
// são percorridos de forma LAZY: dirige next() e roda o corpo a CADA passo. Isso é
// essencial p/ generators infinitos (`for(x of fib())` com break) — materializar tudo
// travaria — e faz `break` parar cedo de verdade. Iteráveis nativos (array/string/
// Collection) e o for-in materializam num snapshot (evita invalidação se o corpo mutar).
// Await comum a expressões, for-await e yield*, inclusive no topo.
// Toda execução que pode aguardar usa uma corrotina; não há pump aninhado.
await_value :: proc(vm: ^Interp, v: Value) -> Value {
    if vm.current_gen != nil && (vm.current_gen.is_async_fn || vm.current_gen.is_async) {
        vm.current_gen.awaiting = true
        return generator_yield(vm, v)
    }
    vm.throwing = true
    vm.thrown = mk_error(vm, "SyntaxError", "await outside an asynchronous execution")
    return nil
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
            for e in o.entries do if !e.dead do append(out, e.key)
        } else {
            for e in o.entries {
                if e.dead do continue
                pair := new_array(vm)
                append(&pair.items, e.key); append(&pair.items, e.val)
                append(out, pair)
            }
        }
    case string:
        starts: [dynamic]int
        defer delete(starts)
        js_code_point_offsets(o, &starts)
        for k := 0; k + 1 < len(starts); k += 1 {
            append(out, own_str(vm, o[starts[k]:starts[k + 1]]))
        }
    }
}

// for-await awaits next() results for async iterators. Sync iterators use
// AsyncFromSyncIterator, which awaits each value before returning the result.
@(private = "file")
eval_for_await :: proc(vm: ^Interp, n: ^Node, env: ^Env, it: Value, my_label: string) -> Value {
    cv: Value = nil // valor de conclusão do laço (atualizado pelo for_of_run_body)
    iter: Value
    by_protocol, is_async := false, false
    if !is_primitive(it) {
        method := get_member(vm, it, vm.sym_async_iterator_key)
        if vm.throwing do return cv
        if method != nil && method != (JS_Null{}) {
            fn, ok := method.(^Function)
            if !ok { throw_type_error(vm, "Symbol.asyncIterator is not callable"); return cv }
            iter = call_function(vm, fn, it, nil)
            if vm.throwing do return cv
            by_protocol, is_async = true, true
        }
    }
    if !by_protocol do iter, by_protocol = get_iterator(vm, it)
    if vm.throwing do return cv
    if by_protocol {
        next_fn := iterator_next_fn(iter)
        if next_fn == nil { throw_type_error(vm, "Iterator next is not callable"); return cv }
        for {
            if step_guard(vm) do break
            r := call_function(vm, next_fn, iter, nil)
            if vm.throwing do return cv
            if is_async do r = await_value(vm, r)
            if vm.throwing do return cv
            if is_primitive(r) { throw_type_error(vm, "Iterator result is not an object"); return cv }
            done := truthy(get_member(vm, r, "done"))
            if vm.throwing do return cv
            value: Value
            // AsyncFromSyncIterator unwraps the value, including the done step.
            // A real async iterator already returns its result through Await.
            if !is_async || !done do value = get_member(vm, r, "value")
            if vm.throwing do return cv
            if !is_async do value = await_value(vm, value)
            if vm.throwing do return cv
            if done do break
            if for_of_run_body(vm, n, env, value, my_label, &cv) {
                async_iterator_close(vm, iter)
                break
            }
        }
        return cv
    }
    // Native arrays advance lazily, so mutations made while suspended are seen.
    if array, ok := it.(^Array); ok {
        for i := 0; ; i += 1 {
            if step_guard(vm) do return cv
            done := i >= len(array.items)
            value: Value
            if !done do value = get_index(vm, array, f64(i))
            if vm.throwing do return cv
            value = await_value(vm, value)
            if vm.throwing || done do return cv
            if for_of_run_body(vm, n, env, value, my_label, &cv) do return cv
        }
    }
    values: [dynamic]Value
    defer delete(values)
    collect_sync_values(vm, it, &values)
    for v in values {
        av := await_value(vm, v)
        if vm.throwing do return cv
        if for_of_run_body(vm, n, env, av, my_label, &cv) do return cv
    }
    // Even an empty iterator suspends on its final next() result.
    await_value(vm, nil)
    return cv
}

@(private = "file")
eval_for_of :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    cv: Value = nil // valor de conclusão do laço (atualizado pelo for_of_run_body)
    my_label := vm.pending_label; vm.pending_label = ""
    it := eval(vm, n.right, env)
    if vm.throwing do return cv

    // for await (x of it): drena um iterável ASSÍNCRONO (ou síncrono, awaitando
    // cada valor). Cada passo suspende a corrotina até assentar.
    if n.is_generator do return eval_for_await(vm, n, env, it, my_label)

    // caminho LAZY: for-of sobre iterável por protocolo
    if n.bval {
        if iter, ok := get_iterator(vm, it); ok {
            next_fn := iterator_next_fn(iter)
            if next_fn != nil {
                for {
                    if step_guard(vm) do break
                    r := call_function(vm, next_fn, iter, nil)
                    if vm.throwing do return cv
                    ro, rok := r.(^Object)
                    if !rok || truthy(ro.props["done"]) do break
                    if for_of_run_body(vm, n, env, ro.props["value"], my_label, &cv) {
                        // término ABRUPTO (break/return): IteratorClose — chama
                        // iter.return() p/ o finally de generator rodar
                        iterator_close(vm, iter)
                        break
                    }
                }
                return cv
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
                for e in o.entries do if !e.dead do append(&values, e.key)
            } else {
                for e in o.entries {
                    if e.dead do continue
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
            js_code_point_offsets(o, &starts)
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
            own_enum_keys(vm, o, &keys)
            for k in keys do append(&values, own_str(vm, k))
        case ^Array, ^Function:
            keys: [dynamic]string
            defer delete(keys)
            own_keys_any(vm, o, &keys)
            for k in keys do append(&values, own_str(vm, k))
        case string:
            // `for (i in "ab")` enumera os índices "0","1" (não dava nada)
            buf: [24]u8
            for i in 0 ..< str_rlen(o) do append(&values, own_str(vm, strconv.write_int(buf[:], i64(i), 10)))
        }
    }

    for v in values {
        if for_of_run_body(vm, n, env, v, my_label, &cv) do break
    }
    return cv
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
    if n.pos != 0 do vm.cur_pos = n.pos // statement/chamada: posição p/ Error.stack
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
        // strict só pesa no GetBindingValue de um `with` (prop que sumiu)
        if v, ok := lookup_ident(vm, env, n.name, n.strict); ok do return v
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
        // Prop própria NÃO-configurável não sai: `delete` devolve false em sloppy e
        // lança TypeError em strict (spec 13.5.1.2). Antes devolvia true sempre.
        t := n.left
        #partial switch t.kind {
        case .Ident:
            if !vm.with_used do return true
            return delete_ident_with(vm, t.name, env)
        case .Member, .Index:
            obj := eval(vm, t.left, env)
            if vm.throwing do return nil
            k: string
            kv: Value
            if t.kind == .Member {
                k = t.name
            } else {
                kv = eval(vm, t.right, env)
                if vm.throwing do return nil
            }
            if t.kind == .Index {
                // ToPropertyKey só p/ os tipos que guardam props (o comportamento de
                // antes: `delete "abc"[k]` não convertia a chave).
                keyed := proxy_state(obj) != nil
                #partial switch _ in obj {
                case ^Object, ^Function, ^Array: keyed = true
                }
                if keyed do k = key_string(vm, kv)
            }
            return delete_property_value(vm, obj, k, n.strict)
        }
        return true

    case .Update:
        // ++x / x++ / --x / x--
        // alvo Ident depois de algum `with`: proc à parte (ver eval_update_with) —
        // um local de 48 B aqui engordava o frame do eval p/ TODO nó (~3%)
        if n.left.kind == .Ident && vm.with_used do return eval_update_with(vm, n, env)
        old := read_target(vm, n.left, env)
        if vm.throwing do return nil
        if ob, ok := old.(^BigInt); ok { // BigInt: ++ soma 1n (não Number 1)
            one := bigint_from_i64(vm, 1)
            nb := n.op == .PlusPlus ? bigint_add(vm, ob, one) : bigint_sub(vm, ob, one)
            write_target(vm, n.left, nb, env, n.strict)
            return nb if n.bval else ob
        }
        cur := as_number(old)
        newv := cur + (1 if n.op == .PlusPlus else -1)
        write_target(vm, n.left, newv, env, n.strict)
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
        return await_value(vm, v)

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
        // alvo Ident depois de algum `with`: proc à parte (ver eval_assign_with)
        if n.left.kind == .Ident && vm.with_used do return eval_assign_with(vm, n, env)
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
            if vm.throwing do return nil
            keep := false
            #partial switch n.op {
            case .AmpAmp:    keep = !truthy(cur)
            case .PipePipe:  keep = truthy(cur)
            case .QQuestion: keep = !is_nullish(cur)
            }
            if keep do return cur
            rhs := eval(vm, n.right, env)
            if vm.throwing do return nil
            if n.left.kind == .Ident do infer_binding_name(n.right, rhs, n.left.name)
            ref_write(vm, n.left, env, tobj, tkey, rhs, n.strict)
            return rhs
        }
        old: Value
        if n.op != .Assign do old = ref_read(vm, n.left, env, tobj, tkey) // composto lê ANTES do RHS
        if vm.throwing do return nil // getter do composto lançou
        rhs := eval(vm, n.right, env)
        // RHS que lança NÃO escreve: antes `x = f()` com f lançando gravava undefined
        // em x (e o.q ??= f() criava `q`), e no strict o ReferenceError do nome não
        // declarado sobrescrevia a exceção do RHS.
        if vm.throwing do return nil
        val: Value = rhs
        if n.op == .Assign && n.left.kind == .Ident do infer_binding_name(n.right, rhs, n.left.name)
        if n.op != .Assign do val = binop(vm, n.op, old, rhs) // x += v ≡ x = x <op> v
        if vm.throwing do return nil // valueOf do binop lançou
        ref_write(vm, n.left, env, tobj, tkey, val, n.strict)
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
                        fn.home_obj = o
                        okey_accessor(o, k)
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
                cv := eval(vm, vnode.right, env)
                set_home_object(cv, vnode.right, o)
                oput(o, k, cv)
                continue
            }
            if vnode.acc != 0 { // getter (1) / setter (2)
                fn, _ := eval(vm, vnode, env).(^Function)
                if fn == nil do continue
                fn.home_obj = o
                okey_accessor(o, key)
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
            mv := eval(vm, vnode, env)
            set_home_object(mv, vnode, o)
            oput(o, key, mv)
        }
        return o

    case .ArrayLit:
        a := new_array(vm)
        has_elision := false
        for el in n.body do if el.kind == .Undef && el.bval { has_elision = true; break }
        if !has_elision {
            items := eval_args(vm, n.body, env) // expande ...spread
            defer delete(items)
            for it in items do append(&a.items, it)
            return a
        }
        // Com elisão (`[1,,3]`): avalia em trechos entre os buracos (o spread pode
        // mudar a posição de tudo que vem depois) e marca cada buraco no índice real.
        seg: [dynamic]^Node
        defer delete(seg)
        flush :: proc(vm: ^Interp, a: ^Array, seg: ^[dynamic]^Node, env: ^Env) {
            if len(seg) == 0 do return
            items := eval_args(vm, seg^, env)
            defer delete(items)
            for it in items do append(&a.items, it)
            clear(seg)
        }
        for el in n.body {
            if el.kind == .Undef && el.bval {
                flush(vm, a, &seg, env)
                if vm.throwing do return nil
                arr_mark_hole(a, len(a.items))
                append(&a.items, nil)
                continue
            }
            append(&seg, el)
        }
        flush(vm, a, &seg, env)
        if vm.throwing do return nil
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
                if vm.throwing do return nil
                return proxy_construct(vm, p, pargs[:])
            }
            // new de não-função → TypeError (era undefined silencioso; M42 BUG 2)
            throw_type_error(vm, fmt.tprintf("%s is not a constructor", describe_callee(n.callee)))
            return nil
        }
        args := eval_args(vm, n.body, env)
        defer delete(args)
        if vm.throwing do return nil // argumento lançou: o construtor não roda
        if n.pos != 0 do vm.cur_pos = n.pos // os args podem ter chamado algo: volta ao `new`
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
        f.strict = n.strict
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
        if vm.throwing do return nil
        if n.left == nil do infer_binding_name(n.right, val, n.name)
        // `var` é function-scoped: binda no escopo de função mais próximo (React
        // declara `var d` num bloco e usa fora dele). let/const ficam no bloco.
        target := fn_scope_env(env) if n.aux else env
        if n.left != nil {
            bind_pattern(vm, n.left, val, target, true, n.is_const) // const {a,b} = x / [a,b] = arr
        } else if n.is_const {
            env_define_const(target, n.name, val) // reatribuir depois → TypeError
        } else if n.aux && n.right != nil && vm.with_used && var_init_through_with(vm, env, target, n.name, val) {
            // `with (o) { var x = 1 }` com `x` em o: o inicializador é PutValue da
            // referência resolvida AGORA — grava em o.x; a var içada fica undefined.
            if vm.throwing do return nil
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
        return empty_completion() // declaração: conclusão VAZIA (`1; var x = 2` dá 1)

    case .Return:
        vm.ret_val = nil
        if n.right != nil do vm.ret_val = eval(vm, n.right, env)
        vm.returning = true
        return vm.ret_val

    case .Break:
        vm.breaking = true
        vm.break_label = n.name // "" = loop/switch mais próximo
        return empty_completion() // o valor vem do que veio antes (UpdateEmpty)

    case .Continue:
        vm.continuing = true
        vm.continue_label = n.name
        return empty_completion()

    case .With:
        return eval_with(vm, n, env) // fora do eval: não engorda o frame recursivo

    case .EmptyStmt:
        return empty_completion() // `;` / `debugger`

    case .Labeled:
        // marca o label p/ o loop/switch DIRETAMENTE rotulado (ele o lê em
        // pending_label). Só se o interno for laço/switch — senão o label vazaria
        // p/ um laço aninhado dentro de um bloco rotulado. Para statements não-laço
        // (bloco/if rotulado) o `break label` é consumido no pós-check abaixo.
        inner := n.left
        is_loop := inner.kind == .While || inner.kind == .For || inner.kind == .DoWhile || inner.kind == .ForOf || inner.kind == .Switch
        if is_loop do vm.pending_label = n.name
        // conclusão = a do corpo (inclusive o valor de um `break label` que o
        // encerra: `l: { 3; break l; }` dá 3); pode ser vazia
        lr := eval(vm, inner, env)
        vm.pending_label = ""
        if vm.breaking && vm.break_label == n.name {
            vm.breaking = false; vm.break_label = ""
        }
        return lr

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
        // conclusão: a do try (ou a do catch, se capturou); um finally ABRUPTO a
        // substitui. Vazio vira undefined (spec: UpdateEmpty(C, undefined)).
        tr := eval(vm, n.left, env) // bloco try
        if vm.throwing && n.right != nil && !vm.gen_hard_kill {
            vm.throwing = false // capturada
            exc := vm.thrown
            vm.thrown = nil
            cenv := new_env(vm, env)
            if n.name != "" do env_define(cenv, n.name, exc)
            if n.callee != nil do bind_pattern(vm, n.callee, exc, cenv) // catch ({ message })
            tr = eval(vm, n.right, cenv) // bloco catch (vê o parâmetro)
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
            fr := eval(vm, n.third, env)
            if !(vm.throwing || vm.returning || vm.breaking || vm.continuing) {
                vm.throwing = st_thr;  vm.thrown  = st_val
                vm.returning = st_ret; vm.ret_val = st_rv
                vm.breaking = st_brk;  vm.continuing = st_cnt
            } else {
                tr = fr // finally abrupto: a conclusão é a dele
            }
        }
        return completion_value(tr)

    case .Block:
        child := new_env(vm, env)
        hoist_functions(vm, n.body[:], child)
        // valor de conclusão (o eval() do topo o usa): o do último statement NÃO
        // vazio — `{ 3; break; }` conclui com 3; bloco só de vazios é vazio
        result := empty_completion()
        for s in n.body {
            if is_hoisted_func(s) {
                execute_hoisted_func(vm, s, child)
                continue
            }
            result = update_empty(result, s, eval(vm, s, child))
            if vm.returning || vm.breaking || vm.continuing || vm.throwing do break
        }
        return result

    case .If:
        // devolve o valor de conclusão do ramo tomado (semântica de completion,
        // que o eval() lê: `eval("if(true) 7")` === 7).
        cond := truthy(eval(vm, n.left, env))
        if vm.throwing do return nil
        // vazio vira undefined: `1; if (true) {}` dá undefined (UpdateEmpty(C, undefined))
        if cond do return completion_value(eval(vm, n.right, env))
        if n.third != nil do return completion_value(eval(vm, n.third, env))
        return nil

    case .While:
        my_label := vm.pending_label; vm.pending_label = ""
        lv: Value = nil // conclusão do laço: o último valor NÃO vazio do corpo (spec V)
        for truthy(eval(vm, n.left, env)) {
            if step_guard(vm) do break
            if r := eval(vm, n.right, env); !is_empty_completion(r) do lv = r
            if vm.continuing { if loop_take_continue(vm, my_label) do continue; break } // volta à cond (ou propaga p/ label externo)
            if vm.breaking { loop_take_break(vm, my_label); break }
            if vm.returning || vm.throwing do break
        }
        return lv

    case .DoWhile:
        my_label := vm.pending_label; vm.pending_label = ""
        lv: Value = nil // conclusão do laço (ver .While)
        for {
            if step_guard(vm) do break
            if r := eval(vm, n.right, env); !is_empty_completion(r) do lv = r // corpo roda pelo menos uma vez
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
        return lv

    case .Switch:
        my_label := vm.pending_label; vm.pending_label = ""
        d := eval(vm, n.left, env)
        senv := new_env(vm, env)
        for c in n.body do hoist_functions(vm, c.body[:], senv)
        matched := false
        sv: Value = nil // conclusão: o último valor NÃO vazio dos statements rodados
        // 1ª fase: procura um case que case (===); uma vez casado, executa TUDO
        // dali em diante (fallthrough) até um break
        exec: for c in n.body {
            if !matched {
                if c.left == nil do continue                 // default fica p/ a 2ª fase
                if eval(vm, c.left, senv) != d do continue   // igualdade ESTRITA (union ==)
                matched = true
            }
            for s in c.body {
                if is_hoisted_func(s) do execute_hoisted_func(vm, s, senv)
                else do sv = update_empty(sv, s, eval(vm, s, senv))
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
                    if is_hoisted_func(s) do execute_hoisted_func(vm, s, senv)
                    else do sv = update_empty(sv, s, eval(vm, s, senv))
                    if vm.breaking { loop_take_break(vm, my_label); break exec2 }
                    if vm.returning || vm.throwing || vm.continuing do break exec2
                }
            }
        }
        return sv

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
        lv: Value = nil // conclusão do laço (ver .While)
        for n.right == nil || truthy(eval(vm, n.right, iter_env)) { // cond ausente = true
            if vm.throwing do break // cond lançou (ou exceção pendente em for(;;))
            if step_guard(vm) do break
            if n.callee != nil { // corpo
                if r := eval(vm, n.callee, iter_env); !is_empty_completion(r) do lv = r
            }
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
        return lv

    case .ForOf:
        return eval_for_of(vm, n, env)

    case .Program:
        // conclusão do script (pode ser VAZIA: as fronteiras convertem — ver
        // completion_value)
        result := empty_completion()
        if vm.current_module == nil || vm.current_module.env != env do hoist_functions(vm, n.body[:], env)
        hoist_vars_body(n.body[:], env) // var top-level (inclui os aninhados em blocos)
        for s in n.body {
            if is_hoisted_func(s) do continue // já içada
            result = update_empty(result, s, eval(vm, s, env))
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
        // `yield promise` suspende até resolver, antes de emitir o yield.
        if vm.current_gen != nil && vm.current_gen.is_async {
            val = await_value(vm, val)
            if vm.throwing || vm.returning do return nil
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
    f.non_constructor = true
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
    f.strict = true // corpo de classe é sempre strict
    f.super_ctor = super_fn
    if m.stat {
        // static: o home object é a CONSTRUTORA, cujo [[Prototype]] é a do pai —
        // `super.m()` num static procura em Pai, não em Pai.prototype
        f.home_static = super_fn
    } else {
        f.home_super = super_proto
    }
    return f
}

// Método de literal de objeto (`{ m(){} }`, nó marcado pelo parser) ganha o objeto
// como home object — é o que dá sentido a `super.x` nele. `{ k: function(){} }` e
// arrows NÃO ganham (spec: só MethodDefinition tem [[HomeObject]]).
@(private = "file")
set_home_object :: proc(v: Value, node: ^Node, o: ^Object) {
    if node == nil || node.kind != .Func || !node.is_method do return
    if fn, ok := v.(^Function); ok do fn.home_obj = o
}

// Initializes only this class's fields. Base fields run on constructor entry;
// derived fields run immediately after that constructor's super() returns.
@(private = "file")
init_instance_fields :: proc(vm: ^Interp, fn: ^Function, obj: ^Object) {
    if fn.class_node == nil do return
    fenv: ^Env
    for m, i in fn.class_node.body {
        if m.kind != .ClassField || m.stat do continue
        if fenv == nil {
            fenv = new_env(vm, fn.closure)
            env_define(fenv, "this", obj)
        }
        v: Value = nil
        if m.right != nil do v = eval(vm, m.right, fenv)
        if vm.throwing do return
        oput(obj, fn.class_keys[i], v)
    }
}

// Computed names are resolved in source order during class definition.
@(private = "file")
class_member_key :: proc(vm: ^Interp, m: ^Node, env: ^Env) -> string {
    if m.name != "" || m.left == nil do return m.name
    v := eval(vm, m.left, env)
    if vm.throwing do return ""
    v = to_primitive(vm, v, false)
    if vm.throwing do return ""
    return key_string(vm, v)
}

// eval de `class`: monta a função-construtora + o objeto prototype (que segura
// os métodos de instância). Herança = prototype.proto aponta p/ o prototype da
// superclasse; `new` liga this.proto a este prototype (ver .New).
@(private = "file")
eval_class :: proc(vm: ^Interp, n: ^Node, env: ^Env) -> Value {
    super_fn: ^Function
    super_proto: ^Object
    extends_null := false
    if n.callee != nil {
        hv := eval(vm, n.callee, env)
        if vm.throwing do return nil
        #partial switch sv in hv {
        case ^Function:
            super_fn = sv
            if sv.props != nil {
                if pv, ok2 := sv.props["prototype"].(^Object); ok2 do super_proto = pv
            }
        case JS_Null:
            // `class X extends null` (spec ClassDefinitionEvaluation): o prototype
            // NÃO herda de Object.prototype, a construtora herda de
            // Function.prototype, e a classe é DERIVADA sem pai — super() lança.
            extends_null = true
        }
    }

    proto := new_object(vm)
    if extends_null do proto.proto = nil
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
            ctor.non_constructor = false
            ctor.name = n.name // a CLASSE é a função: `E.name` é "E", não "constructor"
        }
    }
    if ctor == nil {
        // construtor default: vazio; se deriva, encaminha os args ao super
        ctor = new_function(vm)
        ctor.name = n.name
        ctor.closure = cenv
        env_escaped(vm)
        ctor.super_ctor = super_fn
        ctor.auto_super = super_fn != nil || extends_null
    }
    ctor.super_null = extends_null
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

    // Resolve keys in source order and install all methods before static inits.
    // A cache per constructor keeps repeated evaluations of one AST independent.
    ctor.class_keys = make([]string, len(n.body))
    for m, i in n.body {
        if m.kind != .Func && m.kind != .ClassField do continue
        key := class_member_key(vm, m, env)
        if vm.throwing do return nil
        ctor.class_keys[i] = key
        if m.kind != .Func || m.name == "constructor" do continue
        if !m.stat {
            fn := build_method(vm, m, cenv, super_fn, super_proto)
            if m.acc != 0 do okey_accessor(proto, key)
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
            continue
        }
        fn := build_method(vm, m, cenv, super_fn, super_proto)
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
    for m, i in n.body {
        if !m.stat do continue
        #partial switch m.kind {
        case .ClassField:
            senv := new_env(vm, cenv) // cenv: o nome da classe já visível na cadeia
            env_define(senv, "this", ctor) // `this` num campo static é a própria classe
            v: Value = nil
            if m.right != nil do v = eval(vm, m.right, senv)
            if vm.throwing do return nil
            ctor.props[ctor.class_keys[i]] = v
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
        if _, is_null := sc.(JS_Null); is_null {
            throw_type_error(vm, "Super constructor null of anonymous class is not a constructor")
            return nil, true
        }
        fn, ok := sc.(^Function)
        if !ok do return nil, true // sem superclasse: no-op silencioso
        args := eval_args(vm, n.body, env)
        defer delete(args)
        if vm.throwing do return nil, true
        nt, _ := env_get(env, "new.target")
        ret := super_construct(vm, fn, this_val, args[:], nt)
        if vm.throwing do return nil, true
        owner, _ := env_get(env, "__classctor__")
        if ctor, cok := owner.(^Function); cok {
            if obj, ook := this_val.(^Object); ook do init_instance_fields(vm, ctor, obj)
        }
        if vm.throwing do return nil, true
        return ret, true
    }

    // super.metodo(...)
    if c.kind == .Member && c.left.kind == .Ident && c.left.name == "super" {
        sp, _ := env_get(env, "__superproto__")
        #partial switch _ in sp {
        case ^Object, ^Function: // ^Function = super num método static
        case: return nil, true
        }
        fn, fok := get_member(vm, sp, c.name).(^Function)
        if !fok do return nil, true
        args := eval_args(vm, n.body, env)
        defer delete(args)
        if vm.throwing do return nil, true
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
    this_val, _ := env_get(env, "this")
    // método STATIC: a base é a construtora-pai; sobe pela cadeia de construtoras
    // (super_ctor = [[Prototype]] da função) e, no fim, os builtins de Function.
    if sf, fok := sp.(^Function); fok {
        for c := sf; c != nil; c = c.super_ctor {
            if c.getters != nil {
                if g, gok := c.getters[name]; gok do return call_function(vm, g, this_val, nil)
            }
            if c.props != nil {
                if v, vok := c.props[name]; vok do return v
            }
        }
        return get_member(vm, sf, name)
    }
    base, ok := sp.(^Object)
    if !ok do return nil // fora de método de classe derivada
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
//
// `new_target` = o new.target da construtora DERIVADA: a do pai roda como parte do
// mesmo [[Construct]] (é o que deixa passar a guarda de "classe sem new" do
// call_function, e o new.target lá dentro é a subclasse, como manda a spec).
super_construct :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value, new_target: Value = nil) -> Value {
    vm.pending_new_target = new_target if new_target != nil else fn
    ret := call_function(vm, fn, this, args)
    if vm.throwing do return ret
    o, ok := this.(^Object)
    if !ok do return ret
    #partial switch r in ret {
    case ^Object:
        if r == o do return ret // já escreveu direto no this
        if r.prim != nil do o.prim = r.prim // native super() can return a primitive wrapper
        for k in r.korder {
            if v, vok := r.props[k]; vok do oput(o, k, v)
        }
        for k, v in r.props {
            if _, seen := o.props[k]; !seen do oput(o, k, v)
        }
    case ^Collection, ^Array, ^Regex:
        o.prim = ret
    case string, f64, bool:
        // `class X extends String { constructor(){ super("ab") } }`: a nativa chamada
        // sem `new` devolve o primitivo; a instância vira o wrapper dele
        if fn.native != nil do o.prim = ret
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
    case ^Collection:
        // Branded collection methods validate wrappers themselves and preserve
        // their identity for chaining and forEach's third callback argument.
        if fn.native == coll_method_dispatch do return this
        for _, m in vm.collection_methods do if m == fn do return o.prim
    case ^Array:      return this
    // subclasse de RegExp: exec/toString nativos leem `this.(^Regex)` — recebem a
    // regex embrulhada. test e os @@match/@@split/... NÃO: eles precisam da
    // INSTÂNCIA para enxergar um `exec` sobrescrito na subclasse (RegExpExec), e
    // achar a ^Regex sozinhos pelo regex_of/regex_fast.
    case ^Regex:
        if fn == vm.regex_exec_fn || fn == vm.regex_tostring_fn do return o.prim
    // wrapper de primitivo (`new String("a").toUpperCase()`, valueOf no ToPrimitive):
    // os métodos nativos leem `this.(string)`/`.(f64)`/`.(bool)` — é o valor
    // embrulhado ([[StringData]]/[[NumberData]]/[[BooleanData]]) que eles querem.
    // Só wrappers chegam aqui (o.prim != nil), então o laço não pesa no caminho comum.
    case string: for _, m in vm.string_methods do if m == fn do return o.prim
    case f64:    for _, m in vm.number_methods do if m == fn do return o.prim
    case bool:   for _, m in vm.boolean_methods do if m == fn do return o.prim
    // Object(sym): toString/valueOf/[Symbol.toPrimitive] nativos leem `this.(^Symbol)`
    case ^Symbol:
        if vm.symbol_proto != nil {
            for _, m in vm.symbol_proto.props do if m == fn do return o.prim
        }
    }
    return this
}

// ToObject de um primitivo string/número/booleano: o objeto WRAPPER, com o
// primitivo no slot `prim` e o X.prototype certo. O que o wrapper herda do
// primitivo (`length`, índices, métodos) vem pelo fallback de `prim` do get_member.
// Outros valores voltam como estão (objeto já é objeto; null/undefined são do chamador).
make_wrapper :: proc(vm: ^Interp, v: Value) -> Value {
    proto: ^Object
    #partial switch _ in v {
    case string: proto = vm.string_proto
    case f64:    proto = vm.number_proto
    case bool:   proto = vm.boolean_proto
    case ^Symbol: proto = vm.symbol_proto // Object(sym) / ToObject(sym): `instanceof Symbol`
    case:        return v
    }
    o := new_object(vm)
    o.proto = proto
    o.prim = v
    return o
}

// O primitivo dentro de um wrapper (ok=false se `v` não é um).
wrapper_value :: proc(v: Value) -> (Value, bool) {
    o, ok := v.(^Object)
    if !ok || o.prim == nil do return nil, false
    #partial switch _ in o.prim {
    case string, f64, bool: return o.prim, true
    }
    return nil, false
}

// new_target != nil só via Reflect.construct(alvo, args, newTarget): o corpo que
// roda é o do `fn`, mas o prototype da instância e o `new.target` vêm do newTarget.
construct_object :: proc(vm: ^Interp, fn: ^Function, args: []Value, new_target: ^Function = nil) -> Value {
    if fn.proxy != nil do return proxy_construct(vm, fn.proxy, args, new_target)
    // `new (f.bind(t, a))(b)` = `new f(a, b)` (spec §10.4.1.2): prototype, campos de
    // classe e new.target vêm do ALVO; o boundThis é ignorado.
    if fn.bind_target != nil {
        combined := make([dynamic]Value, 0, len(fn.bind_args) + len(args))
        defer delete(combined)
        for v in fn.bind_args do append(&combined, v)
        for v in args do append(&combined, v)
        nt := new_target
        if nt == fn do nt = nil
        return construct_object(vm, fn.bind_target, combined[:], nt)
    }
    if fn.non_constructor || fn.is_arrow || fn.is_async || fn.is_generator {
        throw_type_error(vm, "function is not a constructor"); return nil
    }
    if fn.native != nil {
        // nativas (Error, TypeError, Proxy, ...) constroem e devolvem o objeto.
        // `fn.bound` tem de ficar visível TAMBÉM aqui: este caminho chama a
        // nativa DIRETO, sem passar pelo call_function que normalmente publica o
        // native_bound. Sem isto, uma nativa construtora que carrega estado em
        // bound (o Intl usa p/ levar o próprio prototype) enxerga nil sob `new` e
        // funciona só quando chamada sem `new` — assimetria silenciosa.
        saved_bound := vm.native_bound
        vm.native_bound = fn.bound
        saved_new := vm.native_new
        vm.native_new = true
        ret := fn.native(vm, nil, args)
        vm.native_new = saved_new
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
    case .Ident:
        // `f()` que resolve num ambiente de objeto (`with (o) f()`) chama com
        // this = o (spec 13.3.6.2 EvaluateCall: WithBaseObject). Só depois de algum
        // `with` ter rodado — no resto o caminho é o eval comum, logo abaixo.
        if vm.with_used && n.callee.name != "eval" {
            // direto nas variáveis da chamada: sem locais Value novos no frame
            found: bool
            fn_val, found, this_val = lookup_ident_base(vm, env, n.callee.name)
            if vm.throwing do return nil
            if found do break
        }
        fallthrough
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
                return do_eval(vm, len(eargs) > 0 ? eargs[0] : nil, env, n.strict)
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
        if n.pos != 0 do vm.cur_pos = n.pos
        throw_type_error(vm, fmt.tprintf("%s is not a function", describe_callee(n.callee)))
        return nil
    }

    args := eval_args(vm, n.body, env) // expande ...spread (pode conter cadeias opcionais)
    defer delete(args)
    // argumento lançou: a chamada NÃO acontece. Sem isto a função rodava com os
    // args já avaliados — `console.log("x" + f())` imprimia "xundefined" ANTES do
    // TypeError de f() chegar ao catch.
    if vm.throwing do return nil
    if n.pos != 0 do vm.cur_pos = n.pos // callee/args podem ter chamado algo: volta a ESTA chamada
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
    case .Ident:
        if vm.with_used { // tag resolvida num `with`: this = o objeto (como no eval_call)
            // direto nas variáveis da chamada: sem locais Value novos no frame
            found: bool
            fn_val, found, this_val = lookup_ident_base(vm, env, n.callee.name)
            if vm.throwing do return nil
            if found do break
        }
        fallthrough
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
    if g.program != nil {
        result := eval(vm, g.program, g.program_env)
        if !vm.throwing && !vm.gen_hard_kill {
            vm.returning = true
            vm.ret_val = result
        }
        return
    }
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
                                if !vm.throwing do await_value(vm, rr) // IteratorClose
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
                    r = await_value(vm, r) // método de async iterator devolve Promise
                    if vm.throwing do return nil
                    ro, rok := r.(^Object)
                    if !rok do break
                    if truthy(ro.props["done"]) {
                        if mode == 2 {
                            vm.returning = true; vm.ret_val = ro.props["value"]
                        }
                        return ro.props["value"] // valor de retorno do delegado
                    }
                    val := await_value(vm, ro.props["value"])
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
            av := await_value(vm, v)
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
        js_code_point_offsets(s, &starts)
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
                if e.dead do continue
                generator_yield(vm, e.key)
                if vm.throwing || vm.returning || vm.gen_hard_kill do return nil
            }
        } else {
            for e in snap {
                if e.dead do continue
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
    if !fn.is_arrow {
        scope.vars["new.target"] = new_target
        scope.vars["__classctor__"] = fn if fn.class_node != nil else nil
    }
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
    if fn.home_static != nil do scope.vars["__superproto__"] = fn.home_static
    // método de literal: `super` é o [[Prototype]] ATUAL do home object
    if fn.home_obj != nil && fn.home_obj.proto != nil do scope.vars["__superproto__"] = fn.home_obj.proto
    // `class extends null`: marca que existe heritage, mas sem construtora — o
    // super() lê isto e lança em vez do no-op silencioso de "sem superclasse"
    if fn.super_null do scope.vars["__superctor__"] = JS_Null{}
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
        info := new(Args_Info)
        info.callee = fn
        argobj.args = info
        // MAPEADO só em sloppy com lista de params SIMPLES (sem default, padrão nem
        // rest — spec 10.2.11 passo 18). E só se houver o que mapear.
        simple := fn.rest_param == "" && fn.rest_pat == nil
        if simple do for d in fn.param_defaults do if d != nil { simple = false; break }
        if simple do for pt in fn.param_pats do if pt != nil { simple = false; break }
        if !fn.strict && simple && min(len(args), len(fn.params)) > 0 {
            info.env = scope
            info.params = fn.params
            info.nmap = min(len(args), len(fn.params))
            scope.mapped_args = argobj
            // o objeto guarda o escopo: se ele sobreviver à chamada (`return
            // arguments`), o escopo NÃO pode voltar ao pool
            env_escaped(vm)
        }
    }
    for p, i in fn.params {
        av: Value = args[i] if i < len(args) else nil
        // default: aplica-se quando o arg é undefined (nil), avaliado no escopo
        // já com os params anteriores visíveis — `(a, b=a) => ...` funciona.
        if av == nil && fn.param_defaults != nil && i < len(fn.param_defaults) && fn.param_defaults[i] != nil {
            av = eval(vm, fn.param_defaults[i], scope)
            if p != "" do infer_binding_name(fn.param_defaults[i], av, p)
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
    if fn == nil do return nil
    if fn.proxy != nil do return proxy_apply(vm, fn.proxy, this, args)
    when JSPROF { g_prof.chamadas += 1; if fn.native != nil do g_prof.chamadas_nat += 1 }
    // async function (não-generator): roda como CORROTINA — cada await suspende.
    // O corpo é iniciado por run_generator_body; toda chamada JS, inclusive
    // recursiva à mesma função, precisa criar sua própria corrotina/Promise.
    if fn.is_async && !fn.is_generator && fn.native == nil {
        return async_call(vm, fn, this, args)
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
        // `new (f.bind(...))()` continua sendo `new`, e o [[Construct]] de bound
        // function IGNORA o boundThis: o `this` é o objeto recém-criado (spec §10.4.1.2)
        vm.pending_new_target = nt_pending
        bthis := this if nt_pending != nil else fn.bind_this
        return call_function(vm, fn.bind_target, bthis, combined[:])
    }
    // Construtora de CLASSE só roda via [[Construct]] (`new`, super(), Reflect.construct,
    // upgrade de custom element) — todos põem o pending_new_target. Chamada comum
    // (`A()`, `A.call(o)`) é TypeError (spec §10.2.1 [[Call]] de classConstructor).
    if fn.class_node != nil && nt_pending == nil {
        cname := fn.class_node.name
        if cname == "" do cname = "(anonymous)"
        throw_type_error(vm, fmt.tprintf("Class constructor %s cannot be invoked without 'new'", cname))
        return nil
    }
    if fn.native != nil {
        // expõe fn.bound à nativa via vm.native_bound (save/restore = reentrante)
        saved := vm.native_bound
        vm.native_bound = fn.bound
        saved_new := vm.native_new
        vm.native_new = nt_pending != nil // includes super() constructing a native base
        ret := fn.native(vm, unwrap_prim(vm, fn, this), args)
        vm.native_new = saved_new
        vm.native_bound = saved
        return ret
    }
    // generator (function*): chamar NÃO roda o corpo — devolve um objeto generator
    // cujo .next() dirige o corpo numa thread própria em ping-pong (generator.odin).
    if fn.is_generator {
        return make_generator(vm, fn, this, args)
    }
    // pilha-sombra do Error.stack (stack_trace.odin): frame LOCAL encadeado; a saída
    // (inclusive por exceção) devolve frame, posição e fonte do chamador.
    frame := Stack_Frame{parent = vm.frame, fn = fn, call_pos = vm.cur_pos, call_script = vm.cur_script, is_new = nt_pending != nil}
    vm.frame = &frame
    vm.cur_script = fn.script
    vm.cur_pos = 0
    defer {
        vm.frame = frame.parent
        vm.cur_pos = frame.call_pos
        vm.cur_script = frame.call_script
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
    if fn.class_node != nil && fn.super_ctor == nil && !fn.super_null {
        if obj, ok := this.(^Object); ok do init_instance_fields(vm, fn, obj)
        if vm.throwing do return nil
    }
    scope := setup_call_scope(vm, fn, this, args, nt_pending)
    // construtor default de classe derivada: encaminha os args ao super
    if fn.auto_super && fn.super_null {
        throw_type_error(vm, "Super constructor null of anonymous class is not a constructor")
        return nil
    }
    if fn.auto_super && fn.super_ctor != nil {
        super_construct(vm, fn.super_ctor, this, args, nt_pending)
        if vm.throwing do return nil
        if obj, ok := this.(^Object); ok do init_instance_fields(vm, fn, obj)
        if vm.throwing do return nil
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
    vm.script_alloc = context.allocator // Script_Src/tabela de linhas: nunca no TEMP
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
    finalize_builtin_metadata(vm) // name/length/atributos da spec nos builtins (builtin_meta.odin)
    // Error.stackTraceLimit é dado COMUM (W/E/C): o finalize trata número como constante
    if ec := vm.error_ctor; ec != nil && ec.attrs != nil do ec.attrs["stackTraceLimit"] = ATTRS_DEFAULT
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
// `url`: de onde o script veio (src externo) — só p/ as linhas do Error.stack;
// "" = inline → a URL da página.
vm_run :: proc(vm: ^Interp, src: string, url := "") -> Value {
    mo_task_enter(vm)     // tarefa de JS: a entrega de MutationRecords sai no exit
    v := vm_exec(vm, src, nil, url)
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
    vm.current_module = prev
    vm_clear_uncaught(vm)
    mo_task_exit(vm)
    return v
}

// Igual a vm_run mas NÃO limpa a exceção pendente — o chamador inspeciona
// vm.throwing/vm.thrown e decide o que fazer. Usado pelo runner do Test262
// (js262.odin), que precisa saber SE e O QUE o teste lançou.
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
// `strict`: eval DIRETO feito de código strict (herda a strictness, spec 19.2.1.1).
vm_eval_source_in :: proc(vm: ^Interp, src: string, env: ^Env, strict := false) -> Value {
    owned := strings.clone(src)
    append(&vm.owned_sources, owned)
    toks, tok_strings, _, lerr := tokenize(owned)
    defer delete(toks)
    for s in tok_strings do append(&vm.owned_strings, s)
    delete(tok_strings)
    p := Parser{ toks = toks[:], src_url = vm.base_url, src = owned, is_eval = true }
    p.ctx.strict = strict
    prog := parse_program(&p)
    append(&vm.all_asts, prog)
    for s in p.owned_strings do append(&vm.owned_strings, s)
    delete(p.owned_strings)
    // erro de sintaxe: eval/Function() LANÇA SyntaxError e não executa nada (antes
    // rodava o que o parser tolerante conseguiu montar). Não entra em syntax_errors:
    // é exceção capturável do próprio script (feature-detect por `try { eval(...) }`).
    if msg, _, bad := pick_syntax_error(&p, lerr); bad {
        vm.thrown = mk_error(vm, "SyntaxError", msg)
        vm.throwing = true
        delete(p.err_msg)
        return nil
    }
    // Error.stack: código de eval/Function() é "<anonymous>" (tem fonte próprio)
    // frame anônimo p/ o código do eval: a linha do CHAMADOR (onde o eval foi feito) fica
    eval_frame := Stack_Frame{parent = vm.frame, call_pos = vm.cur_pos, call_script = vm.cur_script}
    vm.frame = &eval_frame
    vm.cur_script = script_register(vm, "", owned)
    vm.cur_pos = 0
    defer { vm.frame = eval_frame.parent; vm.cur_script = eval_frame.call_script; vm.cur_pos = eval_frame.call_pos }
    // eval STRICT (herdado ou por "use strict" no próprio fonte): `var`/funções
    // ficam num ambiente PRÓPRIO — não vazam para o escopo do chamador (spec
    // PerformEval: varEnv = o novo lexEnv quando strict).
    if prog.strict {
        own := new_env(vm, env)
        own.is_fn_scope = true // fronteira de `var`: sem isto o var subia ao escopo de função
        return completion_value(eval(vm, prog, own))
    }
    return completion_value(eval(vm, prog, env)) // conclusão vazia → undefined
}

// eval(x): se x NÃO é string, devolve x intacto (spec); se é, avalia no `env`.
// Direto (eval_call passa o env do chamador → vê locais) e indireto (global_eval
// passa vm.global) compartilham isto.
do_eval :: proc(vm: ^Interp, code: Value, env: ^Env, strict := false) -> Value {
    src, ok := code.(string)
    if !ok do return code
    return vm_eval_source_in(vm, src, env, strict)
}

vm_exec :: proc(vm: ^Interp, src: string, env: ^Env = nil, url := "") -> Value {
    when JSPROF {
        t_ini := time.tick_now()
        g_prof.bytes_fonte += u64(len(src))
        defer g_prof.ms_total += time.duration_milliseconds(time.tick_since(t_ini))
    }
    owned := strings.clone(src)
    append(&vm.owned_sources, owned)

    toks, tok_strings, bad_chars, lerr := tokenize(owned, vm.current_module != nil)
    defer delete(toks)
    // strings decodificadas de escapes: a AST as referencia, então o vm assume
    // a posse (liberadas junto com owned_strings no vm_destroy)
    for s in tok_strings do append(&vm.owned_strings, s)
    delete(tok_strings)
    // URL do que está sendo parseado: os nós de import()/import.meta guardam este
    // referrer, em vez de perguntar quem está correndo na HORA da chamada (M137).
    p := Parser{ toks = toks[:], src_url = vm.current_module != nil ? vm.current_module.url : vm.base_url, src = owned, is_module = vm.current_module != nil }
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
    // (o parser não recupera mais em silêncio: p.recoveries só conta o erro de
    // sintaxe, que vai abaixo — por isso não soma aqui)
    _ = bad_chars

    // ERRO DE SINTAXE: o fonte inteiro é rejeitado, nada executa (spec: early error).
    // Antes o parser trocava o trecho inválido por `0` e o script rodava
    // miscompilado; agora lança SyntaxError como um navegador de verdade.
    if msg, off, bad := pick_syntax_error(&p, lerr); bad {
        report_syntax_error(vm, owned, msg, off, &p)
        delete(p.err_msg)
        if m := vm.current_module; m != nil {
            m.evaluation = promise_new(vm)
            m.state = .Failed
            m.error = vm.thrown
            promise_settle(vm, m.evaluation, PROMISE_REJECTED, vm.thrown)
        }
        return nil
    }

    // Error.stack: o código de topo deste fonte é o fundo da pilha enquanto ele roda
    script_url := url
    if vm.current_module != nil do script_url = vm.current_module.url
    if script_url == "" do script_url = vm.base_url
    saved_script, saved_pos := vm.cur_script, vm.cur_pos
    vm.cur_script = script_register(vm, script_url, owned)
    vm.cur_pos = 0
    defer { vm.cur_script = saved_script; vm.cur_pos = saved_pos }

    vm.steps = 0 // watchdog: nova tarefa síncrona
    vm.call_depth = 0
    refresh_stack_limit(vm) // stack da thread atual (script pode rodar na worker de fetch)
    reset_task_clock(vm)    // relógio do watchdog por tempo
    run_env := env if env != nil else vm.global
    m := vm.current_module
    if m != nil {
        m.evaluation = promise_new(vm)
        module_instantiate(vm, m, prog, run_env)
    }
    pending_dependencies := module_start_dependencies(vm, prog)
    if program_needs_coroutine(prog) || pending_dependencies {
        return program_call(vm, prog, run_env)
    }
    // Ordinary modules stay on the host thread, preserving synchronous host
    // hooks which keep their layout context in thread locals.
    result := completion_value(eval(vm, prog, run_env)) // conclusão vazia → undefined
    if m != nil {
        if vm.throwing {
            m.state = .Failed
            m.error = vm.thrown
            promise_settle(vm, m.evaluation, PROMISE_REJECTED, vm.thrown)
        } else {
            module_snapshot_exports(vm, m)
            m.state = .Done
            promise_settle(vm, m.evaluation, PROMISE_FULFILLED, m.ns)
        }
    }
    return result
}

// Escolhe o erro de sintaxe a relatar: o do lexer ou o do parser, o que vier
// PRIMEIRO no fonte (o V8 tokeniza sob demanda, então o 1º em ordem de fonte vence).
pick_syntax_error :: proc(p: ^Parser, lerr: Lex_Error) -> (msg: string, off: int, bad: bool) {
    if lerr.msg != "" && (!p.err || lerr.off <= p.err_off) do return lerr.msg, lerr.off, true
    if p.err do return p.err_msg, p.err_off, true
    return "", 0, false
}

// Lança o SyntaxError de um fonte rejeitado e guarda a nota de diagnóstico
// (mensagem + linha:coluna + trecho) p/ o --diagnose e o modo estrito dos testes.
report_syntax_error :: proc(vm: ^Interp, src, msg: string, off: int, p: ^Parser) {
    line, col := src_line_col(src, off)
    idx := vm.parse_recoveries + vm.syntax_errors
    if idx < len(vm.parse_notes) {
        lo := max(0, off - 40)
        hi := min(len(src), off + 40)
        snippet := fmt.tprintf("%d:%d: %s", line, col, src[lo:hi])
        sn := strings.clone(snippet); append(&vm.owned_strings, sn)
        mc := strings.clone(msg); append(&vm.owned_strings, mc)
        vm.parse_notes[idx] = Parse_Recovery{pos = off, kind = .EOF, text = sn, what = mc}
    }
    vm.syntax_errors += 1
    vm.thrown = mk_error(vm, "SyntaxError", msg)
    vm.throwing = true
    when ODIN_TEST {
        fmt.eprintfln("[js] SyntaxError: %s (linha %d, coluna %d)", msg, line, col)
    }
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
    total := vm.parse_recoveries + vm.syntax_errors
    if total == 0 do return
    fmt.eprintfln("parse com %d erro(s) de sintaxe / recuperação(ões):", total)
    for i in 0 ..< min(total, len(vm.parse_notes)) {
        n := vm.parse_notes[i]
        fmt.eprintfln("  [%d] %s — token #%d %v %q", i, n.what, n.pos, n.kind, n.text)
    }
    fmt.eprintfln("  fonte: %q", src[:min(len(src), 300)])
    when #config(PARSEFAIL_LOG, false) { fmt.eprintln("[PARSEFAIL]"); return }
    panic("teste parseou JS com erro de sintaxe (o fonte foi rejeitado com SyntaxError)")
}

// Execução transitória (cria vm, roda, destrói). Usada pelos testes do núcleo.
run :: proc(src: string) -> Value {
    vm := vm_create()
    defer vm_free(vm)
    v := vm_run(vm, src)
    check_parse_recoveries(vm, src)
    return v
}

// Como `run`, mas lê `probe` numa SEGUNDA tarefa, depois do checkpoint de
// microtasks que fecha a primeira. O valor de conclusão de `run(src)` é síncrono
// (spec): `Promise.resolve(1).then(v => x = v); x` dá o valor ANTERIOR de x, então
// testes de Promise/async que liam o estado ali codificavam o modelo antigo de
// reações drenadas no settle (anterior ao bfd7c21).
run_settled :: proc(src, probe: string) -> Value {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, src)
    v := vm_run(vm, probe)
    check_parse_recoveries(vm, src)
    return v
}

program_needs_coroutine :: proc(n: ^Node) -> bool {
    if n == nil || n.kind == .Func do return false
    if n.kind == .Await do return true
    if n.kind == .ForOf && n.is_generator do return true
    if program_needs_coroutine(n.left) || program_needs_coroutine(n.right) || program_needs_coroutine(n.third) || program_needs_coroutine(n.callee) do return true
    for child in n.body do if program_needs_coroutine(child) do return true
    return false
}

function_length :: proc(f: ^Function) -> f64 {
    if f.bind_target != nil do return max(0, function_length(f.bind_target) - f64(len(f.bind_args)))
    if f.native != nil do return f64(f.native_length)
    for d, i in f.param_defaults do if d != nil do return f64(i)
    return f64(len(f.params))
}

// Binding resolution follows import aliases without reading a value.
env_uninitialized :: proc(e: ^Env, name: string, depth := 0) -> bool {
    if depth > 256 do return false
    for cur := e; cur != nil; cur = cur.parent {
        if _, ok := cur.vars[name]; ok do return cur.uninitialized[name]
        if a, ok := cur.aliases[name]; ok do return env_uninitialized(a.src, a.local, depth + 1)
    }
    return false
}

env_declare_uninitialized :: proc(e: ^Env, name: string) {
    e.vars[name] = nil
    if e.uninitialized == nil do e.uninitialized = make(map[string]bool)
    e.uninitialized[name] = true
}
