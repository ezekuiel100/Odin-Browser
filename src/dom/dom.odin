package dom

// Árvore DOM: a representação em memória de um documento HTML.
// Document
//   └─ Element <html>
//        ├─ Element <head> ...
//        └─ Element <body>
//             ├─ Element <p>
//             │    └─ Text "Olá"
//             └─ ...

import "core:strings"

Node_Kind :: enum {
    Document,
    Element,
    Text,
    Comment,
}

Node :: struct {
    kind:     Node_Kind,
    tag:      string,            // nome da tag (só para Element), ex.: "div"
    text:     string,            // conteúdo (só para Text/Comment)
    attrs:    map[string]string, // atributos (só para Element)
    // ORDEM DE DOCUMENTO dos atributos. O map do Odin não tem ordem, e a spec exige
    // que getAttributeNames()/a coleção .attributes venham na ordem em que aparecem.
    // O lit-html pareia getAttributeNames() POSICIONALMENTE com a sua lista de
    // bindings — com ordem aleatória, o valor de um binding caía na propriedade
    // ERRADA (era o que punha `false` em appConfig no archive.org, M131).
    // Escrever SEMPRE por set_attr/del_attr para manter isto em sincronia.
    attr_order: [dynamic]string, // fatias que apontam para as MESMAS chaves de `attrs`
    children: [dynamic]^Node,
    parent:   ^Node,
    ns:       string,            // namespace: "" = HTML (default), "svg", "math"
    // Contador de mutação DESTA lista de filhos. Só quem precisa dele é a
    // HTMLCollection/NodeList VIVA do JS (src/js/dom_collection.odin): ela cacheia
    // um prefixo filtrado dos filhos e usa `kids_ver` para saber, em O(1), que o
    // prefixo morreu. Sem isso, `el.children[i]` refiltra a lista INTEIRA a cada
    // acesso e o idioma `for(i=0;i<el.children.length;i++)` fica O(n²) — medido:
    // 44 s contra 0,4 s no mesmo trabalho de DOM sem tocar em `.children`.
    //
    // ⚠️ CONTADOR SÓ FUNCIONA SE NINGUÉM ESCAPAR. A regra é: fora deste arquivo,
    // NADA escreve em `n.children` na mão — tudo passa por kids_append/kids_insert/
    // kids_remove_at/kids_clear/kids_take abaixo. A auditoria é grepável:
    //     grep -rn "children" --include=*.odin src/ | grep -E "append\(&|ordered_remove\(&|inject_at\(&|clear\(&|\.children = "
    // não pode achar `^Node` nenhum fora daqui (os hits de ui/layout.odin são
    // `^Box`, outra árvore). E a sonda `-define:COLLCHECK` refaz a filtragem a cada
    // leitura e grita se o cache divergir — é ela que PROVA que nenhum sítio ficou
    // de fora, em vez de eu conferir por leitura.
    //
    // (Distinto do `fingerprint` acima, que é hash de ESTADO: aquele precisa pegar
    // texto e atributos, escritos em dezenas de sítios; este cobre só a lista de
    // filhos, cujas mutações cabem numa mão e são enumeráveis por grep.)
    // u64 e não u32: com u32 uma página que mutasse 4 bi de vezes poderia dar a
    // volta e cair no MESMO valor entre duas leituras, revalidando um cache morto.
    // Custa os mesmos 8 bytes por nó (o alinhamento comeria o padding de qualquer
    // jeito), então não há troca a fazer.
    kids_ver: u64,
    // CONTAGEM dos filhos, mantida pelos mesmos helpers que bumpam o kids_ver. Existe
    // para `el.children.length` / `el.childNodes.length` serem O(1) SEMPRE, e não só
    // enquanto ninguém muta: sem isto, `while (el.children.length) el.removeChild
    // (el.children[0])` refaz a varredura a cada volta e o laço volta a ser O(n²)
    // (medido: 1,2 s para 20 mil filhos). Contar na MUTAÇÃO é O(1) por mutação; contar
    // na LEITURA é O(filhos) por leitura, e leitura é o que acontece em laço.
    //   n_elem_kids   = filhos que são Element e NÃO são pseudo (o `children` do JS)
    //   n_pseudo_kids = filhos pseudo (#shadow/#content); `childNodes` é
    //                   len(children) - n_pseudo_kids
    // i32 e não int: cabe no padding e 2 bi de filhos num nó não existe.
    n_elem_kids:   i32,
    n_pseudo_kids: i32,
}

// Pseudo-filho: nó que existe na árvore mas NÃO é filho de luz — o "#content" de
// <template> (criado pelo parser) e o "#shadow" de attachShadow. Some de
// children/childNodes/firstChild/siblings. Definição CANÔNICA aqui (o pacote js
// delega para esta) porque as contagens acima dependem de usar o mesmo critério que
// a coleção do JS — duas cópias da regra divergiriam em silêncio.
is_pseudo_child :: proc(n: ^Node) -> bool {
    if n == nil || len(n.tag) == 0 || n.tag[0] != '#' do return false // nenhuma tag real começa com '#'
    return n.tag == "#shadow" || n.tag == "#content"
}

@(private)
kid_count :: proc(parent: ^Node, child: ^Node, d: i32) {
    if is_pseudo_child(child)      do parent.n_pseudo_kids += d
    else if child.kind == .Element do parent.n_elem_kids += d
}

make_node :: proc(kind: Node_Kind) -> ^Node {
    n := new(Node)
    n.kind = kind
    return n
}

append_child :: proc(parent, child: ^Node) {
    child.parent = parent
    kids_append(parent, child)
}

// ── mutação da lista de filhos (ÚNICO caminho; ver kids_ver acima) ───────────
// Não mexem em `child.parent`: os chamadores em html/ tratam o parent por conta
// própria (o parser reordena nós mantendo o pai), e mudar isso aqui alteraria a
// semântica de tree-construction. Estes helpers fazem EXATAMENTE o que a linha
// crua fazia, mais o bump.

kids_append :: proc(parent: ^Node, child: ^Node) {
    append(&parent.children, child)
    kid_count(parent, child, +1)
    parent.kids_ver += 1
}

kids_append_many :: proc(parent: ^Node, kids: []^Node) {
    append(&parent.children, ..kids)
    for k in kids do kid_count(parent, k, +1)
    parent.kids_ver += 1
}

kids_insert :: proc(parent: ^Node, idx: int, child: ^Node) {
    inject_at(&parent.children, idx, child)
    kid_count(parent, child, +1)
    parent.kids_ver += 1
}

kids_remove_at :: proc(parent: ^Node, idx: int) {
    kid_count(parent, parent.children[idx], -1) // ANTES de sair da lista
    ordered_remove(&parent.children, idx)
    parent.kids_ver += 1
}

kids_clear :: proc(parent: ^Node) {
    clear(&parent.children)
    parent.n_elem_kids = 0
    parent.n_pseudo_kids = 0
    parent.kids_ver += 1
}

// Rouba o buffer de filhos (deixa a lista VAZIA e devolve o que estava lá). O
// chamador vira dono do `[dynamic]` — usado pelo parser p/ re-hospedar em massa.
kids_take :: proc(parent: ^Node) -> [dynamic]^Node {
    kids := parent.children
    parent.children = nil
    parent.n_elem_kids = 0
    parent.n_pseudo_kids = 0
    parent.kids_ver += 1
    return kids
}

// ── Impressão digital do DOM ────────────────────────────────────────────────
// Hash de TODO estado do DOM que afeta renderização: kind/tag/texto/namespace e
// atributos de cada nó, mais a estrutura da árvore. Serve p/ pular o restyle
// quando um timer JS disparou sem mexer em nada — o caso comum de setInterval
// de analytics/relógio/heartbeat, que hoje custa um compute_styles +
// build_layout INTEIROS por tick (medido: ~3,0 s numa página de 16 mil
// elementos; o re-parse do CSS é só ~7 ms disso).
//
// Por que hash do ESTADO e não um contador de mutação: as escritas em
// children/attrs/text estão espalhadas por dezenas de sítios em js/, html/ e
// ui/ e NÃO passam todas por set_attr/append_child. Um contador perderia
// alguma e a página congelaria em silêncio — falha pior que a lentidão, e que
// nem o WPT nem o dump de tiro único pegariam. O hash lê o estado atual, então
// nenhuma escrita escapa, ao custo de uma varredura O(nós) por frame.
//
// Cobre também `el.style.x = …` (que escreve de volta em attrs["style"]) e
// mudança de CSS (o texto vive num nó <style>, que é hasheado). Não existe
// insertRule/styleSheets neste motor, então não há caminho de CSSOM que altere
// o CSS sem passar pelo DOM.
FP_OFFSET :: 0xcbf29ce484222325
FP_PRIME  :: 0x100000001b3

fingerprint :: proc(n: ^Node) -> u64 {
    h: u64 = FP_OFFSET
    fp_walk(n, &h)
    return h
}

@(private)
fp_str :: proc(s: string) -> u64 {
    h: u64 = FP_OFFSET
    for i in 0 ..< len(s) { h ~= u64(s[i]); h *= FP_PRIME }
    return h
}

@(private)
fp_mix :: proc(h: ^u64, s: string) {
    for i in 0 ..< len(s) { h^ ~= u64(s[i]); h^ *= FP_PRIME }
    h^ ~= 0xff; h^ *= FP_PRIME // separador: "ab"+"c" não colide com "a"+"bc"
}

@(private)
fp_walk :: proc(n: ^Node, h: ^u64) {
    if n == nil do return
    h^ ~= u64(n.kind); h^ *= FP_PRIME
    fp_mix(h, n.tag)
    fp_mix(h, n.text)
    fp_mix(h, n.ns)
    // Atributos combinados de forma COMUTATIVA (soma): `attrs` é um map, que não
    // tem ordem, e `attr_order` pode não refletir escrita direta no map.
    acc: u64 = 0
    for k, v in n.attrs {
        acc += fp_str(k) * 0x9E3779B97F4A7C15 + fp_str(v)
    }
    h^ ~= acc; h^ *= FP_PRIME
    h^ ~= u64(len(n.children)); h^ *= FP_PRIME
    for c in n.children do fp_walk(c, h)
    h^ ~= 0x5d; h^ *= FP_PRIME // fecha o nível: distingue irmão de filho
}

// Conta quantos elementos existem na subárvore (para diagnóstico).
count_elements :: proc(n: ^Node) -> int {
    total := 0
    if n.kind == .Element do total += 1
    for c in n.children {
        total += count_elements(c)
    }
    return total
}

// Sonda compile-gated (-define:DOMPROBE=true): registra QUEM liberou cada nó,
// p/ rastrear ponteiro pendurado (o crash do wikipedia em querySelectorAll).
when #config(DOMPROBE, false) {
    g_free_log: map[rawptr]string
    g_free_tag: string = "?"
    g_probe_owner: ^Node       // quem levou o textContent/innerHTML da vez
    g_probe_alias: bool        // algum filho tinha .parent DIFERENTE do nó (aliasing)
    g_free_owner: map[rawptr]^Node
    // Aliasing em QUALQUER profundidade: free_tree confere, p/ cada nó que vai
    // liberar, se os filhos realmente apontam de volta p/ ele. Se um filho tem
    // outro pai, ele está em DOIS arrays de filhos e liberá-lo aqui deixa
    // ponteiro pendurado no outro.
    g_alias_child, g_alias_expected, g_alias_actual: rawptr
    g_zumbi_insert: int          // quantas vezes o JS inseriu um nó JÁ LIBERADO
    g_zumbi_parent, g_zumbi_child: rawptr
}

// Libera recursivamente a árvore e todas as strings que ela possui.
free_tree :: proc(n: ^Node) {
    if n == nil do return
    when #config(DOMPROBE, false) {
        if g_free_log == nil do g_free_log = make(map[rawptr]string)
        g_free_log[rawptr(n)] = g_free_tag
        for c in n.children do if c.parent != n {
            g_alias_child = rawptr(c); g_alias_expected = rawptr(n); g_alias_actual = rawptr(c.parent)
        }
        if g_free_owner == nil do g_free_owner = make(map[rawptr]^Node)
        g_free_owner[rawptr(n)] = g_probe_owner
    }
    for c in n.children {
        free_tree(c)
    }
    delete(n.children)
    if n.tag  != "" do delete(n.tag)
    if n.text != "" do delete(n.text)
    for k, v in n.attrs {
        delete(k)
        delete(v)
    }
    delete(n.attrs)
    delete(n.attr_order) // as strings são as MESMAS chaves de attrs (já liberadas)
    free(n)
}

// Escreve um atributo preservando a ORDEM de documento. `key`/`val` devem ser
// strings já CLONADAS (posse do nó) — como no resto do DOM. Se a chave já existe, o
// valor é trocado (a chave antiga é mantida, a nova é liberada) e a ordem não muda,
// que é a semântica de setAttribute na spec.
set_attr :: proc(n: ^Node, key: string, val: string) {
    if n == nil do return
    if n.attrs == nil do n.attrs = make(map[string]string)
    if old, exists := n.attrs[key]; exists {
        delete(old)
        n.attrs[key] = val
        delete(key) // a chave armazenada continua sendo a original
        return
    }
    n.attrs[key] = val
    append(&n.attr_order, key)
}

// Remove um atributo (e o tira da ordem). Libera chave e valor.
del_attr :: proc(n: ^Node, key: string) {
    if n == nil do return
    val, ok := n.attrs[key]
    if !ok do return
    // A chave POSSUÍDA é a que está em attr_order. Se ela não estiver lá, o nó foi
    // montado escrevendo direto no map (existem alguns: o #shadow do attachShadow,
    // fixtures de teste) e a única string que temos é a do CHAMADOR — liberá-la
    // seria bad free (heap corrompida). Preferimos vazar a chave: sintoma menor e
    // restrito a nós fora do set_attr.
    stored_key := ""
    found := false
    for k in n.attr_order { if k == key { stored_key = k; found = true; break } }
    delete_key(&n.attrs, key)
    if found {
        for k, i in n.attr_order {
            if k == key {
                ordered_remove(&n.attr_order, i)
                break
            }
        }
        delete(stored_key)
    }
    delete(val)
}

// Nomes dos atributos em ordem de documento. Cai no map (ordem arbitrária) só se a
// lista estiver dessincronizada — nós criados antes desta rotina existir.
attr_names :: proc(n: ^Node, out: ^[dynamic]string) {
    if n == nil do return
    if len(n.attr_order) == len(n.attrs) {
        for k in n.attr_order do append(out, k)
        return
    }
    for k in n.attrs do append(out, k)
}

// Primeiro elemento com a tag dada (busca em profundidade). nil se não achar.
find_first :: proc(n: ^Node, tag: string) -> ^Node {
    if n.kind == .Element && n.tag == tag do return n
    for c in n.children {
        if r := find_first(c, tag); r != nil do return r
    }
    return nil
}

// Texto concatenado de toda a subárvore (todos os nós de texto).
text_content :: proc(n: ^Node, sb: ^strings.Builder) {
    if n.kind == .Text {
        strings.write_string(sb, n.text)
    }
    for c in n.children {
        text_content(c, sb)
    }
}
