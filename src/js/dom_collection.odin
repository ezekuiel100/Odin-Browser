package js

// HTMLCollection / NodeList VIVAS — `el.children` e `el.childNodes`.
//
// O QUE HAVIA ANTES: os dois getters MATERIALIZAVAM um ^Array novo a cada leitura,
// percorrendo `node.children` inteiro e embrulhando cada filho. Ou seja, `el.children`
// custava O(n) POR ACESSO, e o idioma mais comum que existe em JS de site real —
//     for (var i = 0; i < el.children.length; i++) el.children[i]
// — era O(n²) com alocação. Medido em duas páginas que fazem o MESMO trabalho de DOM
// (20 mil appendChild + 20 mil setAttribute + 20 mil remoções): 44.581 ms indexando
// `raiz.children[i]` contra 419 ms guardando os nós num array JS. ~100×.
//
// Além do custo, a coleção materializada era MORTA: `var c = el.children` congelava a
// lista, e a spec manda que ela seja VIVA (a sonda acusava isso como `HTMLCollection
// live`). As duas coisas têm a mesma raiz — copiar em vez de referenciar — e o mesmo
// conserto.
//
// O QUE FAZ AGORA: `children`/`childNodes` devolvem um objeto HOST (um por nó e por
// tipo, cacheado, então `el.children === el.children` como no navegador) cujo get-hook
// lê `node.children` na hora. Nada é copiado, então a coleção é viva por construção —
// não há cache de conteúdo para congelar.
//
// O CACHE que existe é só de POSIÇÃO, e é um PREFIXO preguiçoso: guarda os primeiros
// k filhos já filtrados e o índice cru onde parou. Ele é validado por `node.kids_ver`
// (contador de mutação da lista de filhos, em src/dom/dom.odin) — se a lista mudou, o
// prefixo é jogado fora. Daí sai o custo:
//   - `coll[i]` sequencial sem mutação → estende o prefixo de 1 → O(1) amortizado;
//   - `coll.length` → O(1) depois do 1º cálculo naquela versão;
//   - `coll[0]` DEPOIS de uma mutação (o laço `while(el.children.length) el.removeChild
//     (el.children[0])`) → varre só até o 1º casamento, NÃO refaz a lista → O(1).
// É por isso que o prefixo é preguiçoso em vez de completo: com rebuild completo, todo
// laço que remove enquanto lê voltaria a ser O(n²).
//
// O `length` NÃO vem do prefixo: vem dos contadores `n_elem_kids`/`n_pseudo_kids` que
// o mesmo funil de src/dom/dom.odin mantém na hora da mutação. Isso é O(1) SEMPRE, e
// não só enquanto ninguém muta — que é o que salva o outro idioma clássico,
// `while (el.children.length) el.removeChild(el.children[0])`: ali a mutação de cada
// volta mata o prefixo, então um `length` por varredura devolveria O(n²). Medido com
// 20 mil filhos: **1.199 ms varrendo → 395 ms com os contadores**, e esses 395 ms são
// o PISO — é o mesmo tempo de 20 mil `remove()` sem coleção nenhuma (o `detach` varre
// `p.children` para achar o índice, O(n²) pré-existente e alheio a este arquivo). Ou
// seja, a coleção parou de custar. Contar na MUTAÇÃO é O(1) por mutação; contar na
// LEITURA é O(filhos) por leitura — e leitura é o que acontece em laço.
//
// DEGRADAÇÕES CONHECIDAS (o que esta coleção NÃO faz, nomeado em vez de escondido):
//  1. `for (var k in el.children)` e `Object.keys(el.children)` NÃO enumeram os
//     índices — o navegador enumera "0","1",… O motor só enumera props PRÓPRIAS
//     (own_enum_keys lê o map), e os índices aqui vêm de hook, não de map. Ninguém
//     escreve for-in sobre coleção (é o for de índice ou o for-of), então fica.
//  2. `el.children[0] = x` não é no-op: vai parar em `props` e é ignorado na leitura
//     (o hook vence). Observavelmente igual ao navegador (que ignora), mas gasta uma
//     entrada de map.
//  3. O prototype tem MAIS métodos do que a spec (map/filter/slice/reduce/…). É
//     compatibilidade com o passado — ver install_collection_protos.
//  4. `getElementsByTagName`/`getElementsByClassName`/`querySelectorAll` seguem
//     devolvendo ^Array. Os dois primeiros são vivos na spec e continuam mortos aqui;
//     o terceiro é ESTÁTICO na spec, então array é a resposta certa.
//
// ⚠️ TUDO ISTO DEPENDE DE A MUTAÇÃO PASSAR PELOS HELPERS `dom.kids_*` — são eles que
// bumpam o `kids_ver` (que invalida o prefixo) E mantêm os contadores (de onde sai o
// length). Um sítio que mexa em `parent.children` na mão deixa a coleção devolvendo
// lista VELHA, e em silêncio, que é a pior falha possível. As duas defesas: (1) fora
// de src/dom/dom.odin ninguém escreve em `.children` — auditável por grep, ver o
// comentário de kids_ver; (2) a sonda `-define:COLLCHECK` refaz a filtragem a cada
// leitura e grita se o prefixo OU o contador divergirem. É ela que PROVA a completude,
// em vez de eu conferir por leitura — e ela já foi provada capaz de falhar (tirando o
// bump de kids_remove_at, acusa na hora).

import "core:fmt"
import "core:strconv"
import dom "../dom"

// HTMLCollection (`children`: só filhos ELEMENTO) vs NodeList (`childNodes`: todos os
// filhos, inclusive texto e comentário). O filtro é a única diferença entre as duas.
Kids_Kind :: enum u8 { Elements, Nodes }

// Estado de UMA coleção. Vive em vm.dom_colls (chaveado pelo ^Object da coleção) em
// vez de num campo do Object: coleção é coisa de DOM e o núcleo não paga 8 bytes por
// objeto JS por causa dela.
Coll_State :: struct {
    node:     ^dom.Node,          // dono da lista (nil = nó já destruído → coleção inerte)
    kind:     Kids_Kind,
    ver:      u64,                // node.kids_ver quando este prefixo foi montado
    items:    [dynamic]^dom.Node, // PREFIXO já filtrado (não necessariamente completo)
    raw_next: int,                // próximo índice de node.children a examinar
}

// Chaves dos slots ocultos no wrapper do elemento: é o que dá IDENTIDADE
// (`el.children === el.children`) e o que evita alocar um objeto por acesso — sem
// isto, `while (i < el.children.length)` criaria uma coleção por iteração.
@(private = "file")
COLL_KEY_ELEMENTS :: "__htmlcollection_children"
@(private = "file")
COLL_KEY_NODES :: "__nodelist_childNodes"

@(private = "file")
coll_key :: proc(kind: Kids_Kind) -> string {
    return kind == .Elements ? COLL_KEY_ELEMENTS : COLL_KEY_NODES
}

// A coleção de `node`, criada na 1ª leitura e guardada no wrapper `owner`.
dom_collection :: proc(vm: ^Interp, owner: ^Object, node: ^dom.Node, kind: Kids_Kind) -> ^Object {
    key := coll_key(kind)
    if c, ok := owner.props[key].(^Object); ok do return c

    o := new_object(vm)
    o.host = rawptr(node) // MESMA convenção dos outros wrappers: host é sempre um ^dom.Node
    o.get  = coll_get
    o.geti = coll_geti
    o.proto = kind == .Elements ? vm.dom_htmlcollection_proto : vm.dom_nodelist_proto

    st := new(Coll_State)
    st.node = node
    st.kind = kind
    st.ver  = node.kids_ver
    vm.dom_colls[rawptr(o)] = st

    owner.props[key] = o
    mark_non_enumerable(owner, key) // fora de Object.keys(el)
    return o
}

// Chamado por forget_wrapper quando o nó vai ser liberado: a coleção pode continuar
// viva na página (`var c = el.children` guardado antes do innerHTML=), então ela tem de
// virar INERTE em vez de apontar para memória reciclada — mesmo motivo do host=nil do
// wrapper. length passa a 0 e todo índice a undefined.
coll_forget :: proc(vm: ^Interp, owner: ^Object) {
    for key in ([2]string{COLL_KEY_ELEMENTS, COLL_KEY_NODES}) {
        c, ok := owner.props[key].(^Object)
        if !ok do continue
        c.host = nil
        if st, sok := vm.dom_colls[rawptr(c)]; sok && st != nil {
            st.node = nil
            clear(&st.items)
            st.raw_next = 0
        }
    }
}

// Libera o estado de todas as coleções (vm_destroy). Os ^Object saem por all_objects.
coll_free_all :: proc(vm: ^Interp) {
    for _, st in vm.dom_colls {
        if st == nil do continue
        delete(st.items)
        free(st)
    }
    delete(vm.dom_colls)
    vm.dom_colls = nil
}

// ── prefixo ─────────────────────────────────────────────────────────────────

// Um filho conta para esta coleção? MESMO critério que o dom.kid_count usa para
// manter os contadores — por isso os dois lados chamam o mesmo is_pseudo_child.
@(private = "file")
coll_accepts :: proc(kind: Kids_Kind, c: ^dom.Node) -> bool {
    if is_pseudo_child(c) do return false // #shadow / #content não são filhos de luz
    if kind == .Elements && c.kind != .Element do return false
    return true
}

// Descarta o prefixo se a lista de filhos mudou desde que ele foi montado.
@(private = "file")
coll_sync :: proc(st: ^Coll_State) {
    if st.node == nil {
        clear(&st.items); st.raw_next = 0
        return
    }
    if st.ver != st.node.kids_ver {
        clear(&st.items)
        st.raw_next = 0
        st.ver = st.node.kids_ver
    }
}

// Estende o prefixo até ter `want` itens (want < 0 = até o fim da lista).
@(private = "file")
coll_extend :: proc(st: ^Coll_State, want: int) {
    if st.node == nil do return
    kids := st.node.children
    for st.raw_next < len(kids) {
        if want >= 0 && len(st.items) >= want do return
        c := kids[st.raw_next]
        st.raw_next += 1
        if coll_accepts(st.kind, c) do append(&st.items, c)
    }
}

// O(1) SEMPRE — inclusive logo depois de uma mutação. Sai dos contadores que o
// funil de dom.odin mantém na hora de mutar; varrer aqui deixaria
// `while (el.children.length) …` quadrático (ver o cabeçalho).
coll_length :: proc(st: ^Coll_State) -> int {
    if st == nil || st.node == nil do return 0
    when #config(COLLCHECK, false) {
        coll_sync(st)
        coll_extend(st, -1)
        coll_check(st, "length")
    }
    if st.kind == .Elements do return int(st.node.n_elem_kids)
    return len(st.node.children) - int(st.node.n_pseudo_kids)
}

coll_item :: proc(st: ^Coll_State, i: int) -> ^dom.Node {
    if st == nil || i < 0 do return nil
    coll_sync(st)
    coll_extend(st, i + 1)
    when #config(COLLCHECK, false) do coll_check(st, "item")
    if i < len(st.items) do return st.items[i]
    return nil
}

// Sonda de completude do funil (-define:COLLCHECK). Refaz a filtragem do zero e
// compara com o prefixo cacheado: qualquer sítio que mute `children` sem bumpar
// `kids_ver` aparece aqui como divergência. Ver o cabeçalho do arquivo.
when #config(COLLCHECK, false) {
    coll_check :: proc(st: ^Coll_State, origem: string) {
        if st.node == nil do return
        k := 0
        for c in st.node.children {
            if !coll_accepts(st.kind, c) do continue
            if k < len(st.items) && st.items[k] != c {
                fmt.eprintfln("[collcheck] %s: prefixo DIVERGE no índice %d (kind=%v, ver=%d) — mutação sem bump de kids_ver",
                    origem, k, st.kind, st.ver)
                return
            }
            k += 1
        }
        // prefixo completo (raw_next no fim) tem de bater com a contagem real
        if st.raw_next >= len(st.node.children) && k != len(st.items) {
            fmt.eprintfln("[collcheck] %s: length %d != real %d (kind=%v) — mutação sem bump de kids_ver",
                origem, len(st.items), k, st.kind)
        }
        // …e os CONTADORES do dom (que é de onde o length sai de verdade) também.
        // Um kid_count esquecido num helper novo aparece aqui, não numa página.
        contado := len(st.node.children) - int(st.node.n_pseudo_kids)
        if st.kind == .Elements do contado = int(st.node.n_elem_kids)
        if contado != k {
            fmt.eprintfln("[collcheck] %s: contador do dom diz %d, varredura diz %d (kind=%v) — kid_count esquecido",
                origem, contado, k, st.kind)
        }
    }
}

// ── hooks ───────────────────────────────────────────────────────────────────

@(private = "file")
coll_state :: proc(vm: ^Interp, o: ^Object) -> ^Coll_State {
    if st, ok := vm.dom_colls[rawptr(o)]; ok do return st
    return nil
}

// Índice inteiro sem materializar o nome — ver Prop_Get_Idx (interp.odin). É por aqui
// que passa `coll[i]`: sem ele, cada acesso cravaria uma string nova em
// vm.owned_strings, retida até o vm_destroy.
coll_geti :: proc(vm: ^Interp, o: ^Object, idx: int) -> (Value, bool) {
    st := coll_state(vm, o)
    if st == nil do return nil, false
    n := coll_item(st, idx)
    if n == nil do return nil, true // fora do intervalo = undefined (não cai no proto)
    return wrap_element(vm, n), true
}

coll_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    st := coll_state(vm, o)
    if st == nil do return nil, false
    if name == "length" do return f64(coll_length(st)), true
    // "0", "12", … chegam aqui quando o acesso NÃO passou pelo geti (ex.:
    // `coll["2"]` com chave string, ou array_like_get dos métodos de Array).
    if idx, is_idx := canonical_index(name); is_idx {
        if n := coll_item(st, idx); n != nil do return wrap_element(vm, n), true
        return nil, true
    }
    return nil, false // o resto cai no prototype (item/namedItem/forEach/Symbol.iterator/…)
}

// `name` é um índice de array CANÔNICO? (spec: a chave tem de ser exatamente o
// ToString do número). Exige TODOS os dígitos porque strconv.parse_int aceita
// prefixo — "0abc" viraria o índice 0 — e recusa zero à esquerda, porque no JS
// `a["01"]` é uma propriedade comum, não o item 1.
@(private = "file")
canonical_index :: proc(name: string) -> (int, bool) {
    if len(name) == 0 || len(name) > 10 do return 0, false // >10 dígitos não cabe e não é índice de DOM
    if name[0] == '0' && len(name) > 1 do return 0, false
    for i in 0 ..< len(name) {
        if name[i] < '0' || name[i] > '9' do return 0, false
    }
    return strconv.parse_int(name, 10)
}

// ── métodos do prototype ────────────────────────────────────────────────────

@(private = "file")
coll_this :: proc(vm: ^Interp, this: Value) -> ^Coll_State {
    o, ok := this.(^Object)
    if !ok do return nil
    return coll_state(vm, o)
}

@(private = "file")
native_coll_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := coll_this(vm, this)
    if st == nil do return JS_Null{}
    n := coll_item(st, as_int(arg(args, 0)))
    if n == nil do return JS_Null{} // spec: item() fora do intervalo é null (não undefined)
    return wrap_element(vm, n)
}

// HTMLCollection.namedItem(k): o 1º elemento com id=k, senão o 1º com name=k (spec).
@(private = "file")
native_coll_named_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := coll_this(vm, this)
    if st == nil do return JS_Null{}
    key, ok := arg(args, 0).(string)
    if !ok do return JS_Null{}
    n := coll_length(st)
    for i in 0 ..< n {
        c := coll_item(st, i)
        if c == nil do continue
        if v, has := c.attrs["id"]; has && v == key do return wrap_element(vm, c)
    }
    for i in 0 ..< n {
        c := coll_item(st, i)
        if c == nil do continue
        if v, has := c.attrs["name"]; has && v == key do return wrap_element(vm, c)
    }
    return JS_Null{}
}

// NodeList.forEach(cb, thisArg). Existe no navegador (NodeList é `iterable<Node>`) e é
// o alvo do feature-detect `if (!NodeList.prototype.forEach)` de meio polyfill.
// Relê o length a cada passo, como a spec manda para uma lista viva.
@(private = "file")
native_coll_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := coll_this(vm, this)
    if st == nil do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "NodeList.forEach: callback não é função"); return nil }
    this_arg := arg(args, 1)
    for i := 0; i < coll_length(st); i += 1 {
        c := coll_item(st, i)
        if c == nil do continue
        call_function(vm, cb, this_arg, []Value{wrap_element(vm, c), f64(i), this})
        if vm.throwing do break
    }
    return nil
}

// Monta HTMLCollection.prototype e NodeList.prototype sobre as CASCAS que
// install_dom_interfaces já expõe como globais (elas existiam só p/ instanceof e p/
// polyfill escrever em cima). Chamado de lá.
install_collection_protos :: proc(vm: ^Interp, htmlcoll, nodelist: ^Object) {
    vm.dom_htmlcollection_proto = htmlcoll
    vm.dom_nodelist_proto       = nodelist

    put :: proc(o: ^Object, k: string, v: Value) {
        oput(o, k, v)
        mark_non_enumerable(o, k) // método de prototype não enumera (spec)
    }

    item := mk_native(vm, native_coll_item)
    item.name = "item"
    put(htmlcoll, "item", item)
    put(nodelist, "item", item)
    named := mk_native(vm, native_coll_named_item)
    named.name = "namedItem"
    put(htmlcoll, "namedItem", named)

    fe := mk_native(vm, native_coll_for_each)
    fe.name = "forEach"
    put(nodelist, "forEach", fe)

    // Iteração: WebIDL dá @@iterator = Array.prototype.values a toda interface com
    // getter indexado, então `[...el.children]` e `for (x of el.childNodes)` funcionam
    // no navegador. Os métodos de Array daqui são GENÉRICOS por length+índice
    // (array_like_* em builtins.odin), então servem a coleção sem cópia intermediária.
    for proto in ([2]^Object{htmlcoll, nodelist}) {
        for name in ([3]string{"values", "keys", "entries"}) {
            if fn, ok := vm.array_methods[name]; ok do put(proto, name, fn)
        }
        if fn, ok := vm.array_methods["values"]; ok do put(proto, vm.sym_iterator_key, fn)
        // DELIBERADAMENTE um SUPERCONJUNTO da spec: no navegador, map/filter/slice/
        // indexOf/reduce NÃO existem em HTMLCollection nem em NodeList. Aqui existem
        // porque até agora `children`/`childNodes` ERAM ^Array de verdade — tirá-los
        // quebraria, calado, todo código de página que os usava e que este motor já
        // renderizava. O que a spec garante (item/namedItem/forEach/@@iterator) está
        // acima; isto é compatibilidade com o passado, não conformidade.
        for name in ([12]string{"forEach", "map", "filter", "reduce", "reduceRight",
                                "slice", "indexOf", "includes", "find", "findIndex",
                                "some", "every"}) {
            if _, has := proto.props[name]; has do continue // não sobrepõe o forEach nativo
            if fn, ok := vm.array_methods[name]; ok do put(proto, name, fn)
        }
    }
}
