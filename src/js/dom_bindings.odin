package js


// Ponte JS ↔ DOM. Único arquivo do pacote `js` que conhece o `dom`; o núcleo
// (lexer/parser/interp/value) permanece independente e testável sozinho.
//
// Modelo: `document` é um Object hospedeiro cujo `host` aponta (sem posse) para
// a raiz da árvore DOM. getElementById/createElement devolvem wrappers — Objects
// cujo `host` é o ^dom.Node. As propriedades do wrapper (textContent, classList,
// appendChild, ...) são interceptadas pelos hooks get/set.
//
// Posse de memória:
//  - A árvore da PÁGINA pertence ao `dom` (liberada por free_tree pela UI).
//  - Strings escritas no DOM são clonadas com posse do DOM; lidas do DOM viram
//    owned_strings do vm.
//  - Nós CRIADOS/REMOVIDOS pelo JS entram em vm.owned_nodes. No fim, free_orphan_nodes
//    libera só os que ficaram órfãos (parent==nil); os anexados são liberados
//    pelo free_tree da página.

import "core:strings"
import "core:fmt" // só o probe do MEMBERPROBE usa
import csspkg "../css"
import dom "../dom"
import htmlp "../html" // p/ innerHTML= (parse de fragmento); html só importa dom — sem ciclo
import net "../net"    // p/ buscar <script src> injetado dinamicamente (chunk webpack)

// Hook do querySelector: o matcher CSS real vive no pacote ui (que conhece css
// e style), e o js não pode importá-lo (ciclo de imports). O ui instala a
// implementação aqui via @(init). Contrato: coleta em `out` os descendentes de
// `scope` (em ordem de documento) que casam `selector`; para no 1º se !all.
// nil => querySelector devolve null e querySelectorAll devolve [].
Dom_Query_Fn :: proc(scope: ^dom.Node, selector: string, all: bool, out: ^[dynamic]^dom.Node)
g_dom_query: Dom_Query_Fn
g_selector_valid: proc(string) -> bool
g_dom_matches: proc(^dom.Node, string, ^dom.Node) -> bool

selector_check :: proc(vm: ^Interp, s: string) -> bool {
    if g_selector_valid == nil || g_selector_valid(s) do return true
    vm.throwing = true
    vm.thrown = mk_error(vm, "SyntaxError", "Invalid CSS selector")
    return false
}

// Hook do getComputedStyle: o valor computado (e o USADO, que precisa do layout)
// vive no pacote ui — mesma razão de ciclo do g_dom_query. Contrato: `prop` chega
// em kebab-case MINÚSCULO (a normalização de camelCase é daqui, ver css_prop_of);
// devolve o valor serializado, ou "" quando a prop não é mapeada / não há estilo
// disponível ainda. ⚠️ a string devolvida é EMPRESTADA (arena temp do ui) — quem
// guarda tem de clonar com own_str. nil => tudo "" (é o caso do `odin test src/js`
// e de qualquer binário sem o pacote ui).
Computed_Style_Fn :: proc(node: ^dom.Node, prop: string) -> string
g_computed_style: Computed_Style_Fn

// Hooks de GEOMETRIA (mesma razão de ciclo; o ui instala no @(init)).
// `g_element_rect`: caixa de BORDA em coords do VIEWPORT (scroll já descontado).
// `g_element_metric`: escalar da família offset*/client*/scroll*, por nome.
// ok=false = o nó não gera caixa (display:none) ou não há layout ainda → o
// chamador devolve zero, que é o que o navegador devolve p/ elemento sem caixa.
// `g_viewport_dims`: tamanho do viewport em px de CSS — a caixa da raiz do
// IntersectionObserver quando a página não passa `root` (o caso de ~toda página).
// Mesma fonte do g_element_rect (o ui a empurra junto com o mapa de estilos).
// `g_element_box`: as duas caixas (conteúdo e borda) + o offset de padding, numa
// chamada só — é o que o ResizeObserver pergunta de cada alvo a cada frame.
Element_Rect_Fn   :: proc(node: ^dom.Node) -> (x, y, w, h: f32, ok: bool)
Element_Metric_Fn :: proc(node: ^dom.Node, which: string) -> (v: f32, ok: bool)
Element_Box_Fn    :: proc(node: ^dom.Node) -> (cw, ch, bw, bh, pad_x, pad_y: f32, ok: bool)
Page_Scroll_Fn    :: proc() -> (x, y: f32)
Viewport_Dims_Fn  :: proc() -> (w, h: f32)
g_element_rect:   Element_Rect_Fn
g_element_metric: Element_Metric_Fn
g_element_box:    Element_Box_Fn
g_page_scroll:    Page_Scroll_Fn
g_viewport_dims:  Viewport_Dims_Fn

install_dom :: proc(vm: ^Interp, root: ^dom.Node) {
    vm.dom_element_methods = make(map[string]^Function)
    vm.dom_classlist_methods = make(map[string]^Function)
    vm.node_wrappers = make(map[rawptr]^Object)
    vm.document_node = rawptr(root) // raiz p/ o upgrade de custom elements
    vm.dom_cleanup = free_orphan_nodes

    vm.dom_element_methods["getAttribute"]     = mk_dom(vm, native_get_attribute)
    vm.dom_element_methods["setAttribute"]     = mk_dom(vm, native_set_attribute)
    vm.dom_element_methods["removeAttribute"]  = mk_dom(vm, native_remove_attribute)
    vm.dom_element_methods["hasAttribute"]     = mk_dom(vm, native_has_attribute)
    vm.dom_element_methods["toggleAttribute"]  = mk_dom(vm, native_toggle_attribute)
    vm.dom_element_methods["matches"]          = mk_dom(vm, native_matches)
    // aliases legados de matches (Sizzle/jQuery: `el.matchesSelector`/vendor-prefixed)
    vm.dom_element_methods["matchesSelector"]       = mk_dom(vm, native_matches)
    vm.dom_element_methods["webkitMatchesSelector"] = mk_dom(vm, native_matches)
    vm.dom_element_methods["mozMatchesSelector"]    = mk_dom(vm, native_matches)
    vm.dom_element_methods["msMatchesSelector"]     = mk_dom(vm, native_matches)
    vm.dom_element_methods["oMatchesSelector"]      = mk_dom(vm, native_matches)
    vm.dom_element_methods["closest"]          = mk_dom(vm, native_closest)
    vm.dom_element_methods["getBoundingClientRect"] = mk_dom(vm, native_get_bounding_client_rect)
    vm.dom_element_methods["getContext"]       = mk_dom(vm, native_get_context) // <canvas> 2D (canvas.odin)
    // <video>/<audio> (media.odin). Como o `getContext`, ficam no mapa PLANO e
    // cada nativa checa a tag — é o idioma daqui.
    vm.dom_element_methods["play"]             = mk_dom(vm, native_media_play)
    vm.dom_element_methods["pause"]            = mk_dom(vm, native_media_pause)
    vm.dom_element_methods["load"]             = mk_dom(vm, native_media_load)
    vm.dom_element_methods["canPlayType"]      = mk_dom(vm, native_media_can_play_type)
    vm.dom_element_methods["getClientRects"]   = mk_dom(vm, native_get_client_rects)
    vm.dom_element_methods["scrollIntoView"]   = mk_dom(vm, dom_noop)
    vm.dom_element_methods["contains"]         = mk_dom(vm, native_contains)
    vm.dom_element_methods["hasChildNodes"]    = mk_dom(vm, native_has_child_nodes)
    vm.dom_element_methods["isEqualNode"]      = mk_dom(vm, native_is_equal_node)
    vm.dom_element_methods["attachShadow"]     = mk_dom(vm, native_attach_shadow)
    vm.dom_element_methods["hasAttributes"]    = mk_dom(vm, native_has_attributes)
    vm.dom_element_methods["getAttributeNames"] = mk_dom(vm, native_get_attribute_names)
    vm.dom_element_methods["getRootNode"]      = mk_dom(vm, native_get_root_node)
    vm.dom_element_methods["assignedNodes"]    = mk_dom(vm, native_assigned_nodes)
    vm.dom_element_methods["assignedElements"] = mk_dom(vm, native_assigned_nodes)
    vm.dom_element_methods["isSameNode"]       = mk_dom(vm, native_is_same_node)
    vm.dom_element_methods["remove"]           = mk_dom(vm, native_remove_self)
    vm.dom_element_methods["addEventListener"] = mk_dom(vm, native_add_event_listener)
    vm.dom_element_methods["appendChild"]      = mk_dom(vm, native_append_child)
    vm.dom_element_methods["insertBefore"]     = mk_dom(vm, native_insert_before)
    vm.dom_element_methods["removeChild"]      = mk_dom(vm, native_remove_child)
    vm.dom_element_methods["cloneNode"]        = mk_dom(vm, native_clone_node)
    // ParentNode/ChildNode modernos (variádicos, aceitam nós OU strings→texto).
    // Libs modernas usam `el.append(...)`, `document.head.append(style)` etc.
    vm.dom_element_methods["append"]           = mk_dom(vm, native_append)
    vm.dom_element_methods["prepend"]          = mk_dom(vm, native_prepend)
    vm.dom_element_methods["before"]           = mk_dom(vm, native_before)
    vm.dom_element_methods["after"]            = mk_dom(vm, native_after)
    vm.dom_element_methods["replaceWith"]      = mk_dom(vm, native_replace_with)
    vm.dom_element_methods["replaceChildren"]  = mk_dom(vm, native_replace_children)
    vm.dom_element_methods["replaceChild"]     = mk_dom(vm, native_replace_child)     // (novo, oldChild)
    vm.dom_element_methods["insertAdjacentElement"] = mk_dom(vm, native_insert_adjacent_element)
    vm.dom_element_methods["insertAdjacentText"]    = mk_dom(vm, native_insert_adjacent_text)
    vm.dom_element_methods["insertAdjacentHTML"]    = mk_dom(vm, native_insert_adjacent_html)
    vm.dom_element_methods["querySelector"]    = mk_dom(vm, native_query_selector)
    vm.dom_element_methods["querySelectorAll"] = mk_dom(vm, native_query_selector_all)
    vm.dom_element_methods["dispatchEvent"]    = mk_dom(vm, native_dispatch_event)
    vm.dom_element_methods["removeEventListener"] = mk_dom(vm, native_remove_event_listener)
    vm.dom_element_methods["focus"]            = mk_dom(vm, dom_noop)
    vm.dom_element_methods["blur"]             = mk_dom(vm, dom_noop)

    vm.dom_classlist_methods["add"]      = mk_dom(vm, classlist_add)
    vm.dom_classlist_methods["remove"]   = mk_dom(vm, classlist_remove)
    vm.dom_classlist_methods["toggle"]   = mk_dom(vm, classlist_toggle)
    vm.dom_classlist_methods["contains"] = mk_dom(vm, classlist_contains)
    vm.dom_classlist_methods["replace"]  = mk_dom(vm, classlist_replace)

    vm.dom_style_methods = make(map[string]^Function)
    vm.dom_style_methods["setProperty"]       = mk_dom(vm, style_set_property)
    vm.dom_style_methods["getPropertyValue"]  = mk_dom(vm, style_get_property)
    vm.dom_style_methods["getPropertyPriority"] = mk_dom(vm, style_get_priority)
    vm.dom_style_methods["removeProperty"]    = mk_dom(vm, style_remove_property)

    vm.event_prevent_fn = mk_dom(vm, event_prevent_default)
    vm.event_stop_fn    = mk_dom(vm, event_stop_propagation)

    doc := new_object(vm)
    doc.host = rawptr(root)
    doc.get  = document_get // resolve currentScript dinamicamente (ver document_get)
    doc.props["getElementById"]   = mk_dom(vm, native_get_element_by_id)
    doc.props["createElement"]    = mk_dom(vm, native_create_element)
    doc.props["createElementNS"]  = mk_dom(vm, native_create_element_ns)
    doc.props["createTextNode"]   = mk_dom(vm, native_create_text_node)
    doc.props["createComment"]    = mk_dom(vm, native_create_comment)
    doc.props["createDocumentFragment"] = mk_dom(vm, native_create_document_fragment)
    doc.props["importNode"] = mk_dom(vm, native_import_node)
    doc.props["adoptNode"]  = mk_dom(vm, native_import_node)
    // nodeType=9 (DOCUMENT_NODE) / nodeName="#document". FALTAVAM no objeto document
    // (que não passa pelo dom_elem_get dos elementos wrapped). O Sizzle (motor de
    // seletores do jQuery) faz `setDocument`: `9===r.nodeType && r.documentElement`
    // como guarda p/ setar sua var de document `C`; sem nodeType===9 a guarda FALHAVA,
    // `C` ficava undefined e os testes de suporte chamavam `C.createElement` →
    // "reading 'createElement' of undefined" → jQuery abortava → `$` indefinido
    // (go.dev/heroku/techcrunch/espn/discord).
    doc.props["nodeType"] = f64(9)
    doc.props["nodeName"] = own_str(vm, "#document")
    // document.implementation.createHTMLDocument (feature-detect do jQuery/Sizzle)
    impl := new_object(vm)
    impl.props["createHTMLDocument"] = mk_dom(vm, native_create_html_document)
    impl.props["hasFeature"]         = mk_dom(vm, native_true) // legado; sempre true
    doc.props["implementation"] = impl
    doc.props["querySelector"]    = mk_dom(vm, native_query_selector)
    doc.props["querySelectorAll"] = mk_dom(vm, native_query_selector_all)
    doc.props["getElementsByTagName"]   = mk_dom(vm, native_get_elements_by_tag_name)
    doc.props["getElementsByClassName"] = mk_dom(vm, native_get_elements_by_class_name)
    doc.props["getElementsByName"]      = mk_dom(vm, native_get_elements_by_name)
    doc.props["addEventListener"]       = mk_dom(vm, native_add_event_listener)
    doc.props["removeEventListener"]    = mk_dom(vm, native_remove_event_listener)
    doc.props["hasFocus"]               = mk_dom(vm, native_true) // aproximação: sempre focado
    doc.props["write"]                  = mk_dom(vm, native_doc_write)   // ver o bloco em doc_write_impl
    doc.props["writeln"]                = mk_dom(vm, native_doc_writeln)
    doc.props["open"]                   = mk_dom(vm, dom_noop) // no-op DELIBERADO (não apaga o doc)
    doc.props["close"]                  = mk_dom(vm, dom_noop)
    doc.props["createEvent"]            = mk_dom(vm, native_create_event)    // legado (archive.org)
    doc.props["createTreeWalker"]       = mk_dom(vm, native_create_tree_walker) // archive.org/mercadolivre/wired
    doc.props["createNodeIterator"]     = mk_dom(vm, native_create_node_iterator) // airbnb
    // body/head/documentElement: resolvidos AGORA (o DOM já foi parseado)
    if body := dom.find_first(root, "body"); body != nil do doc.props["body"] = wrap_element(vm, body)
    if head := dom.find_first(root, "head"); head != nil do doc.props["head"] = wrap_element(vm, head)
    if html := dom.find_first(root, "html"); html != nil do doc.props["documentElement"] = wrap_element(vm, html)
    // Propriedades-string do document. Eram undefined → `document.cookie.indexOf(...)`,
    // `document.referrer.indexOf(...)`, `document.title.length` etc. lançavam
    // "reading 'indexOf' of undefined" e derrubavam o bundle. Aproximações:
    // cookie/referrer vazios (não persistimos cookies), readyState="complete"
    // (o DOM já está pronto quando os scripts rodam — apps que esperam DOMContentLoaded
    // via readyState seguem sem travar), modo padrões (CSS1Compat).
    doc.props["cookie"]        = own_str(vm, "")      // leitura/escrita (plain prop, sem persistência)
    doc.props["referrer"]      = own_str(vm, "")
    doc.props["readyState"]    = own_str(vm, "complete")
    doc.props["characterSet"]  = own_str(vm, "UTF-8")
    doc.props["charset"]       = own_str(vm, "UTF-8")
    doc.props["compatMode"]    = own_str(vm, "CSS1Compat")
    doc.props["visibilityState"] = own_str(vm, "visible")
    doc.props["hidden"]        = false
    title_txt := ""
    if tn := dom.find_first(root, "title"); tn != nil {
        sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
        dom.text_content(tn, &sb)
        title_txt = strings.to_string(sb)
    }
    doc.props["title"] = own_str(vm, title_txt)
    env_define(vm.global, "document", doc)

    // Interfaces DOM globais (Element/Node/HTMLElement/Document/…). Idempotente —
    // o wrap_element de body/head acima já pode tê-las montado. document herda de
    // Document.prototype (document instanceof Document; polyfills em Document.prototype).
    install_dom_interfaces(vm)
    install_dommatrix(vm) // DOMMatrix/DOMMatrixReadOnly/DOMPoint (dommatrix.odin)
    if dctor, dok := env_get(vm.global, "Document"); dok {
        if df, fok := dctor.(^Function); fok {
            if dp, pok := df.props["prototype"].(^Object); pok do doc.proto = dp
        }
    }

    vm.dom_element_methods["getElementsByTagName"]   = mk_dom(vm, native_get_elements_by_tag_name)
    vm.dom_element_methods["getElementsByClassName"] = mk_dom(vm, native_get_elements_by_class_name)

    // Construtores de evento (usados com el.dispatchEvent(new Event('input'))).
    // Compartilham um Event.prototype com os métodos de evento — instâncias de
    // event_ctor linkam nele (via vm.event_proto), e polyfills leem Event.prototype.*.
    ev_ctor  := mk_dom(vm, event_ctor)
    ev_proto := attach_prototype(vm, ev_ctor, vm.object_proto)
    ev_proto.props["preventDefault"]           = mk_dom(vm, dom_noop)
    ev_proto.props["stopPropagation"]          = mk_dom(vm, dom_noop)
    ev_proto.props["stopImmediatePropagation"] = mk_dom(vm, dom_noop)
    ev_proto.props["composedPath"]             = mk_dom(vm, native_empty_array_ret)
    vm.event_proto = ev_proto
    env_define(vm.global, "Event", ev_ctor)
    ce_ctor := mk_dom(vm, event_ctor); attach_prototype(vm, ce_ctor, ev_proto)
    env_define(vm.global, "CustomEvent",   ce_ctor)
    ke_ctor := mk_dom(vm, event_ctor); attach_prototype(vm, ke_ctor, ev_proto)
    env_define(vm.global, "KeyboardEvent", ke_ctor)
    // NÃO redefinir `URL` aqui: o fetch_api já instala uma implementação COMPLETA
    // (searchParams VIVO, origin, username/password, normalização de path). Esta
    // daqui era mais pobre e, por ser instalada DEPOIS, sombreava a boa — em toda
    // página `new URL(x).searchParams` era undefined, embora funcionasse em JS puro.
    // (M132; achado pela sonda de capacidade, que eu havia lido como "feature ausente".)
    env_define(vm.global, "Image",         mk_dom(vm, image_ctor)) // new Image() = <img> (bandcamp)

    // NodeFilter: constantes usadas com createTreeWalker/createNodeIterator.
    nf := new_object(vm)
    nf.props["SHOW_ALL"]      = f64(0xFFFFFFFF)
    nf.props["SHOW_ELEMENT"]  = f64(0x1)
    nf.props["SHOW_TEXT"]     = f64(0x4)
    nf.props["SHOW_COMMENT"]  = f64(0x80)
    nf.props["FILTER_ACCEPT"] = f64(1)
    nf.props["FILTER_REJECT"] = f64(2)
    nf.props["FILTER_SKIP"]   = f64(3)
    env_define(vm.global, "NodeFilter", nf)
    xhr_ctor_fn := mk_dom(vm, xhr_ctor) // stub: não faz rede (telemetria segue sem travar)
    xhr_proto := attach_prototype(vm, xhr_ctor_fn, vm.object_proto) // polyfills leem XMLHttpRequest.prototype.*
    for m in ([]string{"open", "send", "abort", "setRequestHeader", "overrideMimeType", "addEventListener", "removeEventListener"}) do xhr_proto.props[m] = mk_dom(vm, dom_noop)
    xhr_proto.props["getResponseHeader"]     = mk_dom(vm, native_null_ret)
    xhr_proto.props["getAllResponseHeaders"] = mk_dom(vm, native_empty_str_ret)
    env_define(vm.global, "XMLHttpRequest", xhr_ctor_fn)

    install_dom_shims(vm, doc) // Path2D / XPathEvaluator (dom_shims.odin) — shells de feature-detect

    // Popula os protótipos de interface com os métodos nativos (DEPOIS de TODOS
    // registrados em dom_element_methods). Precisa vir aqui no fim: getElements*
    // acima só entram no mapa agora.
    populate_dom_interface_prototypes(vm)

    install_window(vm, doc)
}

// `window`: em navegadores É o objeto global. Aqui: um Object com hooks que
// (1) resolvem self-refs (window/self/globalThis/top/parent) para si mesmo,
// (2) devolvem props próprias (location/navigator/history), (3) caem no ESCOPO
// GLOBAL p/ tudo mais (window.document === document, window.setTimeout === setTimeout).
// React-DOM e o scheduler dependem de `window` existir.
@(private = "file")
install_window :: proc(vm: ^Interp, doc: ^Object) {
    win := new_object(vm)
    win.get = window_get
    win.set = window_set

    // location — get-hook lê vm.base_url NA HORA (base_url é setado após install)
    loc := new_object(vm)
    loc.get = location_get
    // `String(location)` / `new URL(location)`: sem um toString próprio o ToPrimitive
    // caía no de Object e dava "[object Object]".
    loc.props["toString"] = mk_dom(vm, location_to_string)
    loc.props["reload"]  = mk_dom(vm, dom_noop)
    loc.props["assign"]  = mk_dom(vm, dom_noop)
    loc.props["replace"] = mk_dom(vm, dom_noop)
    win.props["location"] = loc
    doc.props["location"] = loc // document.location === window.location (bundles leem
                                // `document.location.search/host`; era undefined → gap-report)

    nav := new_object(vm)
    // Mesma identidade das requisições HTTP: evita que o servidor veja Chrome
    // enquanto os scripts da página detectam MiniBrowser. A versão fica em net.
    nav.props["userAgent"]  = own_str(vm, net.CHROME_UA)
    nav.props["appVersion"] = own_str(vm, net.CHROME_UA[len("Mozilla/"):])
    nav.props["appName"]    = own_str(vm, "Netscape")
    nav.props["product"]    = own_str(vm, "Gecko")
    nav.props["vendor"]     = own_str(vm, "Google Inc.")
    nav.props["language"]  = own_str(vm, "pt-BR")
    langs := new_array(vm) // navigator.languages: código faz [0] / forEach / indexOf
    append(&langs.items, own_str(vm, "pt-BR"), own_str(vm, "pt"), own_str(vm, "en"))
    nav.props["languages"] = langs
    nav.props["platform"]  = own_str(vm, "Win32")
    nav.props["onLine"]    = true
    nav.props["cookieEnabled"]       = true
    nav.props["maxTouchPoints"]      = f64(0)
    nav.props["hardwareConcurrency"] = f64(4)
    nav.props["sendBeacon"] = mk_dom(vm, native_send_beacon) // analytics: aceita e descarta
    win.props["navigator"] = nav

    // history — React Router/Next/medium usam pushState/replaceState p/ GUARDAR
    // um state (chave de navegação/scroll) e depois LEEM `history.state.key`. Sem
    // navegação real, mas o state É persistido: senão `history.state` ficava null
    // e `history.state.key` lançava "reading 'key' of null" (medium blank).
    hist := new_object(vm)
    hist.props["pushState"]    = mk_dom(vm, history_push_state)
    hist.props["replaceState"] = mk_dom(vm, history_push_state)
    hist.props["back"]         = mk_dom(vm, dom_noop)
    hist.props["forward"]      = mk_dom(vm, dom_noop)
    hist.props["go"]           = mk_dom(vm, dom_noop)
    hist.props["length"]       = f64(1)
    hist.props["state"]        = JS_Null{}
    win.props["history"] = hist

    // performance.now() (DOMHighResTimeStamp = relógio do vm); mark/measure stub.
    // Libs de perf/animação e alguns bundles fazem `performance.now()` no init.
    perf := new_object(vm)
    perf.props["now"]              = mk_dom(vm, native_performance_now)
    perf.props["timeOrigin"]       = f64(0)
    // mark/measure/getEntries* eram NO-OP (engoliam tudo e devolviam array
    // vazio). install_performance (performance.odin) os substitui por uma
    // timeline de verdade e instala o PerformanceObserver — chamado no FIM,
    // depois que `perf` está montado.
    // performance.timing (API legada): todos os campos são epoch-ms. Bundles de
    // métricas leem `timing.navigationStart` p/ calcular deltas — sem o objeto,
    // `undefined.navigationStart` matava o script. 0 = tudo "no timeOrigin".
    timing := new_object(vm)
    for k in ([]string{
        "navigationStart", "unloadEventStart", "unloadEventEnd", "redirectStart",
        "redirectEnd", "fetchStart", "domainLookupStart", "domainLookupEnd",
        "connectStart", "connectEnd", "secureConnectionStart", "requestStart",
        "responseStart", "responseEnd", "domLoading", "domInteractive",
        "domContentLoadedEventStart", "domContentLoadedEventEnd", "domComplete",
        "loadEventStart", "loadEventEnd",
    }) {
        timing.props[k] = f64(0)
    }
    perf.props["timing"] = timing
    perfnav := new_object(vm) // performance.navigation legada
    perfnav.props["type"]          = f64(0)
    perfnav.props["redirectCount"] = f64(0)
    perf.props["navigation"] = perfnav
    win.props["performance"] = perf
    env_define(vm.global, "performance", perf)
    install_performance(vm, perf) // timeline real + PerformanceObserver

    // window.addEventListener/removeEventListener no host = raiz (mesmo canal do document)
    win.host = rawptr(doc.host)
    win.props["addEventListener"]    = mk_dom(vm, native_add_event_listener)
    win.props["removeEventListener"] = mk_dom(vm, native_remove_event_listener)
    win.props["dispatchEvent"]       = mk_dom(vm, native_dispatch_event) // win.host = doc.host
    // window.postMessage(msg, origin): entrega ASSÍNCRONA de um evento "message" na
    // própria janela. O scheduler do React usa como alternativa ao MessageChannel;
    // no corpus aparecia como "postMessage is not a function" (medium.com).
    win.props["postMessage"] = mk_dom(vm, window_post_message)
    win.props["document"] = doc

    // Viewport de FALLBACK. O valor real vem do hospedeiro pelo `g_viewport_dims`
    // (ver window_get); estes 800x600 só valem quando não há hospedeiro nenhum
    // (`odin test src/js`) ou antes de a aba saber o próprio tamanho.
    win.props["innerWidth"]  = f64(800)
    win.props["innerHeight"] = f64(600)
    // rolagem: no-ops (routers/scroll-restoration chamam window.scrollTo(0,0) na
    // navegação; sem o método o script aborta com TypeError). Offsets = topo.
    win.props["scrollTo"] = mk_dom(vm, dom_noop)
    win.props["scroll"]   = mk_dom(vm, dom_noop)
    win.props["scrollBy"] = mk_dom(vm, dom_noop)
    win.props["matchMedia"] = mk_dom(vm, native_match_media) // MediaQueryList real (media_query.odin)
    win.props["getComputedStyle"] = mk_dom(vm, native_get_computed_style) // CSSStyleDeclaration stub ("")
    win.props["scrollX"]      = f64(0)
    win.props["scrollY"]      = f64(0)
    win.props["pageXOffset"]  = f64(0)
    win.props["pageYOffset"]  = f64(0)
    scr := new_object(vm)
    scr.props["width"]  = f64(1920)
    scr.props["height"] = f64(1080)
    win.props["screen"] = scr

    // Web Storage: localStorage/sessionStorage (em memória; storage.odin). Como
    // prop de window E identificador solto (o padrão `localStorage.getItem(...)`).
    ls := make_storage(vm, &vm.local_storage)
    ss := make_storage(vm, &vm.session_storage)
    win.props["localStorage"]   = ls
    win.props["sessionStorage"] = ss
    env_define(vm.global, "localStorage", ls)
    env_define(vm.global, "sessionStorage", ss)

    doc.props["defaultView"] = win
    env_define(vm.global, "window", win)
    env_define(vm.global, "globalThis", win)
    // `this` de uma chamada SEM receptor (sloppy mode). Resolvido AQUI, uma vez, e não
    // por chamada: fazer env_get("window") a cada call custou caro o bastante para
    // estourar o orçamento de frames do --diagnose num site pesado (apnews, 2680 caixas).
    vm.global_this = win
    env_define(vm.global, "self", win)
    // `top`/`parent`: sem frames, ambos SÃO a própria janela (spec). Faltavam, e o
    // idioma `if (window.top !== window.self)` (anti-framing, em meio site) lia
    // undefined em silêncio — até o M150, quando `top` virou o global mais faltante
    // do corpus inteiro (6 sites). São a prova de que a seção vazia do gap-report
    // escondia coisa trivial, não coisa difícil.
    win.props["top"]    = win
    win.props["parent"] = win
    env_define(vm.global, "top", win)
    env_define(vm.global, "parent", win)
    // `win instanceof Window` e `Window.prototype.x = …` (polyfill). Só dá para
    // ligar AQUI: o ctor nasce em install_dom_interfaces, mas a janela não existe
    // ainda naquele ponto.
    if wc, ok := env_get(vm.global, "Window"); ok {
        if f, fok := wc.(^Function); fok {
            if wp, pok := f.props["prototype"].(^Object); pok do win.proto = wp
        }
    }
    // como identificadores SOLTOS também (location.href, navigator.userAgent, ...)
    env_define(vm.global, "location", loc)
    env_define(vm.global, "navigator", nav)
    env_define(vm.global, "history", hist)
    env_define(vm.global, "screen", scr)
    // `this` no top-level (e em chamadas sem receptor, sloppy mode) = window
    env_define(vm.global, "this", win)

    // customElements (Web Components registry): não implementamos custom elements,
    // mas bundles chamam `customElements.get(tag)` no init (feature-detect/upgrade).
    // get→undefined (nenhum definido), define/upgrade no-op, whenDefined→promise
    // pendente (o elemento nunca é "definido", então nunca resolve — semântica ok).
    ce := new_object(vm)
    ce.props["get"]         = mk_dom(vm, custom_elements_get)
    ce.props["define"]      = mk_dom(vm, custom_elements_define)
    ce.props["upgrade"]     = mk_dom(vm, custom_elements_upgrade)
    ce.props["getName"]     = mk_dom(vm, native_null_ret)
    ce.props["whenDefined"] = mk_dom(vm, custom_elements_when_defined)
    win.props["customElements"] = ce
    env_define(vm.global, "customElements", ce)

    // Os TRÊS observers são reais: MutationObserver no M201 (mutation_observer.odin),
    // IntersectionObserver e ResizeObserver no M232 (arquivos próprios).
    env_define(vm.global, "MutationObserver",     mk_dom(vm, mo_ctor))
    env_define(vm.global, "ResizeObserver",       mk_dom(vm, ro_ctor))
    env_define(vm.global, "IntersectionObserver", mk_dom(vm, io_ctor))
}

// (`observer_ctor`/`observer_take_records` — a casca que aceitava tudo e nunca
// disparava — foram REMOVIDOS: os três observers têm implementação própria desde
// o M232. Órfão que fica no arquivo é o que faz a próxima pessoa achar que ainda
// existe um caminho de stub.)

@(private = "file")
native_send_beacon :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return true // "enfileirado" (descartado — sem rede p/ analytics)
}

@(private = "file")
dom_noop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }

// history.pushState(state, title, url) / replaceState(...): sem navegação real,
// mas GUARDA o `state` (arg 0) p/ `history.state` devolvê-lo (SPAs leem
// history.state.key/idx). URL (arg 2) ignorada — não há navegação de verdade.
history_push_state :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if h, ok := this.(^Object); ok {
        h.props["state"] = len(args) >= 1 && args[0] != nil ? args[0] : JS_Null{}
    }
    return nil
}

@(private = "file")
native_performance_now :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return vm.clock_ms }

@(private = "file")
native_empty_array :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return new_array(vm) }

@(private = "file")
window_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    switch name {
    case "window", "self", "globalThis", "top", "parent", "frames":
        if w, ok := env_get(vm.global, "window"); ok do return w, true
    case "scrollX", "pageXOffset", "scrollY", "pageYOffset":
        // Scroll REAL da página (antes eram props fixas em 0). Vem do mesmo lugar
        // que o getBoundingClientRect desconta — senão `rect.top + scrollY` (o
        // idioma p/ "posição no documento") não fecharia com a nossa geometria.
        if g_page_scroll != nil {
            sx, sy := g_page_scroll()
            if name == "scrollX" || name == "pageXOffset" do return f64(sx), true
            return f64(sy), true
        }
    case "innerWidth", "innerHeight":
        // Viewport REAL (eram props fixas em 800x600 — um render 1280x2400
        // reportava 800x600 a quem perguntasse). MESMA fonte do
        // `documentElement.clientWidth` e da raiz do IntersectionObserver: as três
        // respostas não podem divergir, porque o código de site compara umas com
        // as outras (`innerWidth || documentElement.clientWidth` é idioma).
        // ⚠️ 0 = ainda não há hospedeiro/tamanho ⇒ cai no fallback das props.
        if g_viewport_dims != nil {
            w, h := g_viewport_dims()
            if w > 0 && h > 0 {
                if name == "innerWidth" do return f64(w), true
                return f64(h), true
            }
        }
    }
    if v, ok := o.props[name]; ok do return v, true            // location/navigator/history/document
    if v, ok := env_get(vm.global, name); ok do return v, true // globais: setTimeout, fetch, Promise, ...
    return nil, false // undefined
}

@(private = "file")
window_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    // window.foo = x  ≡  var foo = x (window É o global). location/history ficam protegidas.
    if name == "location" || name == "history" || name == "navigator" {
        o.props[name] = val
        return true
    }
    env_define(vm.global, name, val)
    return true
}

// Quebra uma URL em componentes (scheme sem ':', host com porta, path, search, hash).
// scheme padrão "https"; path padrão "/". Compartilhado por location e URL.
@(private = "file")
split_url :: proc(url: string) -> (scheme, host, path, search, hash: string) {
    scheme, host, path = "https", "", "/"
    s := url
    if i := strings.index(s, "://"); i >= 0 { scheme = s[:i]; s = s[i + 3:] }
    if i := strings.index(s, "#"); i >= 0 { hash = s[i:]; s = s[:i] }
    if i := strings.index(s, "?"); i >= 0 { search = s[i:]; s = s[:i] }
    if i := strings.index(s, "/"); i >= 0 { host = s[:i]; path = s[i:] } else { host = s }
    if path == "" do path = "/"
    return
}

// new URL(url [, base]): parseia e expõe protocol/host/hostname/port/pathname/
// search/hash/origin/href. Sem isto, `new URL(...)` caía num objeto vazio e
// `.protocol` (undefined) fazia libs de auth (better-auth) lançarem "Invalid base
// URL", matando o bundle antes do React montar.
@(private = "file")
url_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    raw, _ := arg(args, 0).(string)
    full := raw
    // resolve relativo contra base (args[1]) quando `raw` não é absoluto
    if !strings.contains(raw, "://") {
        if base, bok := arg(args, 1).(string); bok && strings.contains(base, "://") {
            bscheme, bhost, _, _, _ := split_url(base)
            sep := "" if strings.has_prefix(raw, "/") else "/"
            full = strings.concatenate({bscheme, "://", bhost, sep, raw}, context.temp_allocator)
        }
    }
    scheme, host, path, search, hash := split_url(full)
    hostname, port := host, ""
    if ci := strings.index(host, ":"); ci >= 0 { hostname = host[:ci]; port = host[ci + 1:] }
    o := new_object(vm)
    o.props["href"]     = own_str(vm, full)
    o.props["protocol"] = own_str(vm, strings.concatenate({scheme, ":"}, context.temp_allocator))
    o.props["host"]     = own_str(vm, host)
    o.props["hostname"] = own_str(vm, hostname)
    o.props["port"]     = own_str(vm, port)
    o.props["pathname"] = own_str(vm, path)
    o.props["search"]   = own_str(vm, search)
    o.props["hash"]     = own_str(vm, hash)
    o.props["origin"]   = own_str(vm, strings.concatenate({scheme, "://", host}, context.temp_allocator))
    o.props["toString"] = mk_dom(vm, url_to_string)
    return o
}

@(private = "file")
url_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if o, ok := this.(^Object); ok { if h, hok := o.props["href"]; hok do return h }
    return own_str(vm, "")
}

// window.postMessage: agenda a entrega de um evento "message" na janela (macrotask,
// como no navegador — entrega SÍNCRONA faria o scheduler recursionar).
@(private = "file")
window_post_message :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    holder := new_object(vm)
    holder.props["data"] = arg(args, 0)
    f := new_function(vm)
    f.native = window_deliver_message
    f.bound  = holder
    vm_schedule_task(vm, f)
    return nil
}

@(private = "file")
window_deliver_message :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h, ok := vm.native_bound.(^Object)
    if !ok do return nil
    ev := new_object(vm)
    ev.props["type"]   = "message"
    ev.props["data"]   = h.props["data"]
    ev.props["origin"] = own_str(vm, "")
    if winv, wok := env_get(vm.global, "window"); wok {
        if w, w2 := winv.(^Object); w2 {
            if d, dok := w.props["onmessage"].(^Function); dok {
                call_function(vm, d, winv, []Value{ev})
                vm_clear_uncaught(vm)
            }
            native_dispatch_event(vm, winv, []Value{ev})
            vm_clear_uncaught(vm)
        }
    }
    return nil
}

// location.* derivado de vm.base_url no momento do acesso (React Router lê pathname).
@(private = "file")
location_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return own_str(vm, vm.base_url == "" ? "https://localhost/" : vm.base_url)
}

@(private = "file")
location_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    url := vm.base_url
    scheme, host, path, search, hash := split_url(url)
    switch name {
    case "href":                return own_str(vm, url == "" ? "https://localhost/" : url), true
    case "protocol":            return own_str(vm, strings.concatenate({scheme, ":"}, context.temp_allocator)), true
    case "host", "hostname":    return own_str(vm, host), true
    case "port":                return own_str(vm, ""), true
    case "pathname":            return own_str(vm, path), true
    case "search":              return own_str(vm, search), true
    case "hash":                return own_str(vm, hash), true
    case "origin":              return own_str(vm, strings.concatenate({scheme, "://", host}, context.temp_allocator)), true
    }
    return nil, false // reload/assign/replace vêm das props
}

@(private = "file")
mk_dom :: proc(vm: ^Interp, fn: Native_Fn) -> ^Function {
    f := new_function(vm)
    f.native = fn
    return f
}

// ── scripts da página / vm ──────────────────────────────────────────────────

run_page_scripts :: proc(root: ^dom.Node) {
    if root == nil do return
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    gather_scripts(root, &sb)
    src := strings.to_string(sb)
    if len(strings.trim_space(src)) == 0 do return
    run_with_dom(src, root)
}

@(private = "file")
gather_scripts :: proc(n: ^dom.Node, sb: ^strings.Builder) {
    if n.kind == .Element && n.tag == "script" {
        for c in n.children {
            if c.kind == .Text do strings.write_string(sb, c.text)
        }
        strings.write_byte(sb, '\n')
    }
    for c in n.children do gather_scripts(c, sb)
}

vm_create_with_dom :: proc(root: ^dom.Node) -> ^Interp {
    vm := vm_create()
    install_dom(vm, root)
    // hooks de módulo ES (M109): rede de verdade. O interp não importa `net`,
    // então a resolução/busca vivem aqui (mesmo padrão do g_dom_query).
    vm.module_resolve = dom_module_resolve
    vm.module_fetch = dom_module_fetch
    return vm
}

// Resolve o especificador contra o referrer (módulo importador) ou o base_url.
@(private = "file")
dom_module_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    base := referrer != "" ? referrer : vm.base_url
    if base == "" do return strings.clone(specifier)
    return strings.clone(net.resolve_url(base, specifier, context.temp_allocator))
}

// Busca BLOQUEANTE da fonte do módulo (mesma filosofia do chunk do M102).
@(private = "file")
dom_module_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    resp := net.fetch(url)
    if !resp.ok || len(resp.body) == 0 {
        if resp.err != "" do delete(resp.err)
        if len(resp.body) > 0 do delete(resp.body)
        return "", false
    }
    // módulo que voltou como HTML = asset inexistente servido com o index.html
    // (fallback de SPA, 200). Parsear como JS gera milhares de recuperações
    // ("<!DOCTYPE html" em posição de expressão) e suja o vm — falha o import.
    if response_is_not_js(resp.status, resp.content_type, string(resp.body), strict_mime = true) {
        delete(resp.body)
        return "", false
    }
    return string(resp.body), true // posse transferida; load_module deleta após o clone do vm_exec
}

run_with_dom :: proc(src: string, root: ^dom.Node) -> Value {
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    v := vm_run(vm, src)
    check_parse_recoveries(vm, src) // no-op fora de builds de teste (ODIN_TEST)
    return v
}

load_page :: proc(root: ^dom.Node) -> ^Interp {
    vm := vm_create_with_dom(root)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    gather_scripts(root, &sb)
    src := strings.to_string(sb)
    if len(strings.trim_space(src)) > 0 do vm_run(vm, src)
    return vm
}

// Get-hook do objeto `document`: resolve `currentScript` DINAMICAMENTE (o <script>
// em execução muda a cada script). Turbopack/webpack leem `document.currentScript` +
// `.getAttribute('src')` p/ computar o caminho-base dos chunks; sem ele o runtime do
// Turbopack lançava "chunk path empty but not in a worker" em CADA chunk (nextjs.org e
// cia., gap #4 do gap-miner). Fora da execução de um script → null (spec). Demais
// propriedades caem no lookup normal de props (handled=false).
@(private = "file")
document_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if name == "currentScript" {
        if vm.current_script != nil do return wrap_element(vm, cast(^dom.Node) vm.current_script), true
        return JS_Null{}, true
    }
    // baseURI/URL/documentURI: a URL da página, lida NA HORA (base_url só é setado
    // depois do install). Era undefined, e `new URL(x, document.baseURI)` — como
    // todo resolvedor de asset faz — virava "Invalid URL".
    if name == "baseURI" || name == "URL" || name == "documentURI" {
        return own_str(vm, vm.base_url == "" ? "https://localhost/" : vm.base_url), true
    }
    // document.domain = hostname da origem (sem porta). Era undefined, e o helper de
    // COOKIE do github testa `if (null == s) throw Error("Unable to get document
    // domain")` — então o módulo de sessão inteiro morria numa propriedade de 1 linha.
    // Só responde se ninguém ESCREVEU `document.domain` (a escrita é depreciada mas
    // legal, e o hook roda antes das props próprias: sem esta guarda, o valor escrito
    // ficaria invisível).
    if name == "domain" {
        if _, own := o.props["domain"]; !own {
            _, host, _, _, _ := split_url(vm.base_url == "" ? "https://localhost/" : vm.base_url)
            if ci := strings.index(host, ":"); ci >= 0 do host = host[:ci]
            return own_str(vm, host), true
        }
    }
    return nil, false
}

// ── eventos ─────────────────────────────────────────────────────────────────

@(private = "file")
add_listener :: proc(vm: ^Interp, key: rawptr, type: string, fn: ^Function) {
    if list, ok := vm.listeners[key]; ok {
        // spec: o mesmo (type, callback) só registra UMA vez
        for h in list do if !h.prop && h.type == type && h.fn == fn do return
    } else {
        vm.listeners[key] = make([dynamic]Listener)
    }
    list := &vm.listeners[key]
    append(list, Listener{type = type, fn = fn})
}

// `el.on<tipo> = fn` (handler-PROPRIEDADE): substitui qualquer handler-propriedade
// anterior do mesmo tipo (não os de addEventListener). fn=nil só remove.
@(private = "file")
set_prop_handler :: proc(vm: ^Interp, key: rawptr, type: string, fn: ^Function) {
    if old, ok := vm.listeners[key]; ok {
        kept := make([dynamic]Listener) // filtra handlers-propriedade do mesmo tipo
        for h in old {
            if h.prop && h.type == type do continue
            append(&kept, h)
        }
        delete(old)
        vm.listeners[key] = kept
    }
    if fn == nil do return
    if _, ok := vm.listeners[key]; !ok do vm.listeners[key] = make([dynamic]Listener)
    list := &vm.listeners[key]
    append(list, Listener{type = type, fn = fn, prop = true})
}

@(private = "file")
native_add_event_listener :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok || o.host == nil || len(args) < 2 do return nil
    type, tok := args[0].(string)
    fn, fok := args[1].(^Function)
    if !tok || !fok do return nil
    add_listener(vm, o.host, type, fn)
    return nil
}

// removeEventListener(type, fn): tira o listener registrado por addEventListener
// com o MESMO par (type, fn). Não afeta handlers-propriedade (el.onclick) — igual
// ao DOM real.
@(private = "file")
native_remove_event_listener :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok || o.host == nil || len(args) < 2 do return nil
    type, tok := args[0].(string)
    fn, fok := args[1].(^Function)
    if !tok || !fok do return nil
    if list, lok := &vm.listeners[o.host]; lok {
        for h, i in list {
            if !h.prop && h.type == type && h.fn == fn {
                ordered_remove(list, i)
                break // só há uma (dedup no add)
            }
        }
    }
    return nil
}

// Dispara um evento em `node` com BUBBLING: sobe do alvo até a raiz, chamando
// os listeners de `type` de cada ancestral. Cria um objeto `event` (e.type,
// e.target, e.currentTarget, e.preventDefault(), e.stopPropagation()) passado
// como 1º argumento; `this` do handler = elemento atual (currentTarget).
// A UI chama no clique com o nó MAIS PROFUNDO. true se algum handler disparou.
dispatch_animation_event :: proc(vm: ^Interp, node: ^dom.Node, kind, name: string, elapsed: f64) -> bool {
    ev := new_object(vm)
    ev.proto = vm.event_proto
    ev.props["type"] = kind
    ev.props["bubbles"] = true
    ev.props["cancelable"] = false
    owned_name := strings.clone(name)
    append(&vm.owned_strings, owned_name)
    ev.props["animationName"] = owned_name
    ev.props["elapsedTime"] = elapsed
    ev.props["pseudoElement"] = ""
    fired, _ := dispatch_event_obj(vm, node, kind, ev)
    return fired
}

dispatch_event :: proc(vm: ^Interp, node: ^dom.Node, type: string) -> bool {
    fired, _ := dispatch_event_obj(vm, node, type, nil)
    return fired
}

// Evento de MOUSE sintetizado pela UI (click/auxclick/mousedown/mouseup), com
// `button` (QUAL botão mudou: 0=esq 1=meio 2=dir) e `buttons` (bitmask dos que
// estão APERTADOS depois do evento: 1=esq 4=meio 2=dir). Sobe e é cancelável.
// ⚠️ sem `button` o evento chegava com `e.button === undefined`, e o filtro mais
// comum de handler de link (`if (e.button !== 0) return`) recusava até o clique
// ESQUERDO. Degradação: sem clientX/Y, sem modificadores (ctrl/shift/alt/meta).
dispatch_mouse_event :: proc(vm: ^Interp, node: ^dom.Node, type: string, button, buttons: int) -> (fired: bool, prevented: bool) {
    ev := new_object(vm)
    if vm.event_proto != nil do ev.proto = vm.event_proto
    ev.props["type"] = type
    ev.props["bubbles"] = true
    ev.props["cancelable"] = true
    ev.props["button"] = f64(button)
    ev.props["buttons"] = f64(buttons)
    return dispatch_event_obj(vm, node, type, ev)
}

// Núcleo do dispatch. ev_in != nil → o objeto Event veio do JS (dispatchEvent):
// preserva as props dele (detail etc.) e honra `bubbles` (default false, como
// new Event na spec); ev_in == nil → evento sintetizado pela UI, sempre sobe.
// Devolve (algum handler disparou, preventDefault foi chamado).
@(private = "file")
dispatch_event_obj :: proc(vm: ^Interp, node: ^dom.Node, type: string, ev_in: ^Object) -> (fired: bool, prevented: bool) {
    vm.steps = 0 // watchdog: um handler de evento é uma tarefa síncrona nova
    vm.call_depth = 0
    refresh_stack_limit(vm) // cliques rodam na thread main (stack própria)
    reset_task_clock(vm)
    mo_task_enter(vm) // `el.click()` chamado de dentro de um handler ANINHA aqui
    ev := ev_in
    bubbles := true
    if ev == nil {
        ev = new_object(vm)
        // ⚠️ SEM esta linha o evento sintetizado pela UI é um objeto CRU: só as
        // 6 props escritas logo abaixo. Era o caminho de TODO listener de página
        // real (clique, input, load) — e o de `el.dispatchEvent('click')`, que
        // passa uma string —, então `e.composedPath()` e
        // `e.stopImmediatePropagation()` lançavam em qualquer framework com
        // listener delegado no document (React 17+, Lit, click-outside).
        // Só `new Event()` linkava no protótipo, que é o caso RARO.
        if vm.event_proto != nil do ev.proto = vm.event_proto
        ev.props["type"] = type
    } else {
        bubbles = truthy(ev.props["bubbles"])
    }
    ev.props["target"] = wrap_element(vm, node)
    ev.props["defaultPrevented"] = false
    ev.props["preventDefault"] = vm.event_prevent_fn
    ev.props["stopPropagation"] = vm.event_stop_fn

    for n := node; n != nil; n = n.parent {
        list, ok := vm.listeners[rawptr(n)]
        if ok {
            // SNAPSHOT dos handlers antes de chamar JS: um handler pode
            // (des)registrar listeners DESTE nó (el.onclick=null / addEventListener)
            // — delete/append realocam o backing e o `for h in list` leria memória
            // liberada. As ^Function são posse do vm e continuam válidas.
            snap := make([dynamic]^Function)
            defer delete(snap)
            for h in list do if h.type == type do append(&snap, h.fn)
            if len(snap) > 0 {
                cur := wrap_element(vm, n)
                ev.props["currentTarget"] = cur
                for fn in snap {
                    call_function(vm, fn, cur, []Value{ev})
                    fired = true
                }
            }
        }
        // stopPropagation: corta a subida (handlers do MESMO nó ainda rodam todos)
        if stopped, sok := ev.props["_stop"]; sok && truthy(stopped) do break
        if !bubbles do break // Event sem bubbles: só o alvo
    }
    vm_clear_uncaught(vm) // handler que lança: loga e não envenena o vm
    mo_task_exit(vm)      // fim de tarefa: entrega o que os handlers mutaram
    prevented = truthy(ev.props["defaultPrevented"])
    return fired, prevented
}

// el.dispatchEvent(evt): dispara um evento. Aceita string ("input", sobe sempre)
// OU um objeto Event — as props dele (detail etc.) chegam intactas aos handlers
// e `bubbles` é honrado (default false, como new Event na spec). Retorna false
// se preventDefault foi chamado (como no DOM).
@(private = "file")
native_dispatch_event :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return false
    type := ""
    ev_obj: ^Object
    #partial switch a in args[0] {
    case string:
        type = a
    case ^Object:
        ev_obj = a
        if t, tok := a.props["type"].(string); tok do type = t
    }
    if type == "" do return false
    _, prevented := dispatch_event_obj(vm, node, type, ev_obj)
    return !prevented
}

// Event(type, opts) / CustomEvent(type, opts): objeto simples {type, bubbles, detail}.
// Usado com el.dispatchEvent(new Event('input', {bubbles:true})).
@(private = "file")
event_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.event_proto // herda preventDefault/stopPropagation/composedPath
    if t, ok := arg(args, 0).(string); ok do o.props["type"] = t
    o.props["bubbles"] = false
    if opts, ok := arg(args, 1).(^Object); ok {
        if b, bok := opts.props["bubbles"]; bok do o.props["bubbles"] = truthy(b)
        if d, dok := opts.props["detail"]; dok do o.props["detail"] = d
    }
    return o
}

@(private = "file")
event_prevent_default :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if o, ok := this.(^Object); ok {
        if c, has := o.props["cancelable"]; !has || truthy(c) do o.props["defaultPrevented"] = true
    }
    return nil
}

@(private = "file")
event_stop_propagation :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if o, ok := this.(^Object); ok do o.props["_stop"] = true
    return nil
}

// new Image([w,h]) = elemento <img> (HTMLImageElement). bandcamp preloadeia
// imagens com `new Image()`; sem o construtor lançava "Image is not a constructor".
@(private = "file")
image_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := dom.make_node(.Element)
    node.tag = strings.clone("img")
    node.attrs = make(map[string]string)
    vm.owned_nodes[rawptr(node)] = true
    return wrap_element(vm, node)
}

// document.createEvent('Event'|'CustomEvent'|…): objeto de evento LEGADO com
// initEvent (archive.org). O path moderno é `new Event(type)`; o antigo cria
// vazio e inicializa depois via initEvent(type, bubbles, cancelable).
@(private = "file")
native_create_event :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    // Mesma razão do dispatch sintetizado: sem o proto, o evento legado não tem
    // composedPath/stopImmediatePropagation. As props REAIS de preventDefault e
    // stopPropagation abaixo são PRÓPRIAS e sombreiam os no-ops do protótipo.
    if vm.event_proto != nil do o.proto = vm.event_proto
    o.props["type"]             = own_str(vm, "")
    o.props["bubbles"]          = false
    o.props["cancelable"]       = false
    o.props["defaultPrevented"] = false
    o.props["initEvent"]        = mk_dom(vm, event_init_event)
    o.props["initCustomEvent"]  = mk_dom(vm, event_init_event)
    o.props["preventDefault"]   = vm.event_prevent_fn
    o.props["stopPropagation"]  = vm.event_stop_fn
    return o
}
@(private = "file")
event_init_event :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if o, ok := this.(^Object); ok {
        if t, tok := arg(args, 0).(string); tok do o.props["type"] = own_str(vm, t)
        o.props["bubbles"]    = truthy(arg(args, 1))
        o.props["cancelable"] = truthy(arg(args, 2))
    }
    return nil
}

// ── TreeWalker (document.createTreeWalker) ──────────────────────────────────
// Percorre a subárvore de `root` em ordem de documento filtrando por whatToShow
// (SHOW_ELEMENT=1 / SHOW_TEXT=4 / SHOW_COMMENT=128 / SHOW_ALL). O callback de
// filtro (NodeFilter) é IGNORADO (aproximação por whatToShow). archive.org (lit)
// e mercadolivre usam nextNode p/ varrer a árvore; sem isto o módulo abortava.
@(private = "file")
tw_accept :: proc(n: ^dom.Node, what: u32) -> bool {
    if n == nil do return false
    if what == 0xFFFFFFFF do return true
    #partial switch n.kind {
    case .Element: return what & 0x1  != 0
    case .Text:    return what & 0x4  != 0
    case .Comment: return what & 0x80 != 0
    }
    return false
}
@(private = "file")
tw_sibling :: proc(n: ^dom.Node, delta: int) -> ^dom.Node {
    if n == nil || n.parent == nil do return nil
    kids := n.parent.children
    for c, i in kids do if c == n {
        j := i + delta
        return (j >= 0 && j < len(kids)) ? kids[j] : nil
    }
    return nil
}
@(private = "file")
tw_doc_next :: proc(cur, root: ^dom.Node) -> ^dom.Node {
    if cur == nil do return nil
    if len(cur.children) > 0 do return cur.children[0]
    n := cur
    for n != nil && n != root {
        if s := tw_sibling(n, +1); s != nil do return s
        n = n.parent
    }
    return nil
}
@(private = "file")
tw_doc_prev :: proc(cur, root: ^dom.Node) -> ^dom.Node {
    if cur == nil || cur == root do return nil
    if p := tw_sibling(cur, -1); p != nil {
        n := p
        for len(n.children) > 0 do n = n.children[len(n.children) - 1]
        return n
    }
    return cur.parent != root ? cur.parent : nil
}
@(private = "file")
tw_state :: proc(this: Value) -> (tw: ^Object, cur, root: ^dom.Node, what: u32) {
    o, ok := this.(^Object)
    if !ok do return
    tw = o
    root = cast(^dom.Node) o.host
    if cn, cok := o.props["currentNode"]; cok do cur = node_of(cn)
    if w, wok := o.props["_whatToShow"].(f64); wok do what = u32(i64(w))
    return
}
@(private = "file")
tw_step :: proc(vm: ^Interp, this: Value, forward: bool) -> Value {
    tw, cur, root, what := tw_state(this)
    if tw == nil || root == nil do return JS_Null{}
    n := cur
    for {
        n = forward ? tw_doc_next(n, root) : tw_doc_prev(n, root)
        if n == nil do return JS_Null{}
        if tw_accept(n, what) {
            w := wrap_element(vm, n)
            tw.props["currentNode"] = w
            return w
        }
    }
}
@(private = "file")
tw_next_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_step(vm, this, true) }
@(private = "file")
tw_prev_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_step(vm, this, false) }
// firstChild/lastChild/nextSibling/previousSibling/parentNode: navegam a partir
// de currentNode respeitando whatToShow (aprox.: 1º/último filho ou irmão aceito).
@(private = "file")
tw_move :: proc(vm: ^Interp, this: Value, pick: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node) -> Value {
    tw, cur, root, what := tw_state(this)
    if tw == nil do return JS_Null{}
    n := pick(cur, root, what)
    if n == nil do return JS_Null{}
    w := wrap_element(vm, n)
    tw.props["currentNode"] = w
    return w
}
@(private = "file")
tw_pick_first_child :: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node {
    if cur == nil do return nil
    for c in cur.children do if tw_accept(c, what) do return c
    return nil
}
@(private = "file")
tw_pick_last_child :: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node {
    if cur == nil do return nil
    for i := len(cur.children) - 1; i >= 0; i -= 1 do if tw_accept(cur.children[i], what) do return cur.children[i]
    return nil
}
@(private = "file")
tw_pick_next_sib :: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node {
    n := cur
    for { n = tw_sibling(n, +1); if n == nil do return nil; if tw_accept(n, what) do return n }
}
@(private = "file")
tw_pick_prev_sib :: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node {
    n := cur
    for { n = tw_sibling(n, -1); if n == nil do return nil; if tw_accept(n, what) do return n }
}
@(private = "file")
tw_pick_parent :: proc(cur, root: ^dom.Node, what: u32) -> ^dom.Node {
    if cur == nil || cur == root do return nil
    n := cur.parent
    for n != nil {
        if tw_accept(n, what) do return n
        if n == root do return nil
        n = n.parent
    }
    return nil
}
@(private = "file")
tw_first_child :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_move(vm, this, tw_pick_first_child) }
@(private = "file")
tw_last_child :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_move(vm, this, tw_pick_last_child) }
@(private = "file")
tw_next_sibling :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_move(vm, this, tw_pick_next_sib) }
@(private = "file")
tw_prev_sibling :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_move(vm, this, tw_pick_prev_sib) }
@(private = "file")
tw_parent_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return tw_move(vm, this, tw_pick_parent) }

@(private = "file")
native_create_tree_walker :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    root := node_of(arg(args, 0))
    if root == nil do return JS_Null{}
    what: u32 = 0xFFFFFFFF
    if w, ok := arg(args, 1).(f64); ok do what = u32(i64(w))
    tw := new_object(vm)
    tw.host = rawptr(root)
    tw.props["_whatToShow"]     = f64(what)
    tw.props["whatToShow"]      = f64(what)
    tw.props["root"]            = wrap_element(vm, root)
    tw.props["currentNode"]     = wrap_element(vm, root)
    tw.props["nextNode"]        = mk_dom(vm, tw_next_node)
    tw.props["previousNode"]    = mk_dom(vm, tw_prev_node)
    tw.props["firstChild"]      = mk_dom(vm, tw_first_child)
    tw.props["lastChild"]       = mk_dom(vm, tw_last_child)
    tw.props["nextSibling"]     = mk_dom(vm, tw_next_sibling)
    tw.props["previousSibling"] = mk_dom(vm, tw_prev_sibling)
    tw.props["parentNode"]      = mk_dom(vm, tw_parent_node)
    return tw
}

// ── NodeIterator (document.createNodeIterator) ──────────────────────────────
// Iterador LINEAR sobre a subárvore de `root` em ordem de documento (pré-ordem),
// com o modelo referenceNode + pointerBeforeReferenceNode da spec — a diferença
// que importa vs. TreeWalker: o PRIMEIRO nextNode() pode devolver o próprio root
// (o ponteiro começa ANTES da referência), e previousNode() alcança root de volta.
// airbnb usa isto p/ varrer nós de texto; sem ele o módulo abortava.
//
// Ao contrário do TreeWalker acima, o FILTRO (NodeFilter) é HONRADO: função ou
// objeto com acceptNode. Ignorá-lo devolveria nós que a página rejeitou — e como
// o iterador alimenta lógica (não só leitura), isso corromperia o resultado. O
// gate de whatToShow vem ANTES (spec: não-casou → FILTER_SKIP sem chamar o filtro).

// Passo anterior na pré-ordem DENTRO da subárvore, INCLUINDO root como 1º nó.
// (tw_doc_prev não serve: ele barra o retorno a root — correto p/ TreeWalker,
// errado p/ NodeIterator, onde root é o primeiro elemento da lista achatada.)
@(private = "file")
ni_prev :: proc(cur, root: ^dom.Node) -> ^dom.Node {
    if cur == nil || cur == root do return nil
    if p := tw_sibling(cur, -1); p != nil {
        n := p
        for len(n.children) > 0 do n = n.children[len(n.children) - 1]
        return n
    }
    return cur.parent // dentro da subárvore (cur != root ⇒ parent é root ou abaixo)
}

// Resultado do filtro p/ um nó: 1=FILTER_ACCEPT, 2/3 = pular. Gate whatToShow
// primeiro; depois função ou objeto-com-acceptNode.
@(private = "file")
ni_filter :: proc(vm: ^Interp, n: ^dom.Node, what: u32, filter: Value) -> int {
    if !tw_accept(n, what) do return 3 // FILTER_SKIP
    #partial switch f in filter {
    case ^Function:
        r := call_function(vm, f, nil, []Value{wrap_element(vm, n)})
        return int(as_number(r))
    case ^Object:
        if an, ok := f.props["acceptNode"]; ok {
            if fn, fok := an.(^Function); fok {
                r := call_function(vm, fn, f, []Value{wrap_element(vm, n)})
                return int(as_number(r))
            }
        }
    }
    return 1 // sem filtro utilizável → aceita
}

@(private = "file")
ni_step :: proc(vm: ^Interp, this: Value, forward: bool) -> Value {
    ni, ok := this.(^Object)
    if !ok do return JS_Null{}
    root := cast(^dom.Node) ni.host
    if root == nil do return JS_Null{}
    what: u32 = 0xFFFFFFFF
    if w, wok := ni.props["_whatToShow"].(f64); wok do what = u32(i64(w))
    filter := ni.props["_filter"]
    node := node_of(ni.props["referenceNode"])
    if node == nil do node = root
    before := true
    if b, bok := ni.props["pointerBeforeReferenceNode"].(bool); bok do before = b

    for {
        if forward {
            if !before {
                node = tw_doc_next(node, root)
                if node == nil do return JS_Null{} // fim: estado inalterado
            } else {
                before = false
            }
        } else {
            if before {
                node = ni_prev(node, root)
                if node == nil do return JS_Null{}
            } else {
                before = true
            }
        }
        res := ni_filter(vm, node, what, filter)
        if vm.throwing do return JS_Null{} // filtro lançou → aborta sem avançar estado
        if res == 1 do break
    }
    w := wrap_element(vm, node)
    ni.props["referenceNode"]                = w
    ni.props["pointerBeforeReferenceNode"]   = before
    return w
}
@(private = "file")
ni_next_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ni_step(vm, this, true) }
@(private = "file")
ni_prev_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ni_step(vm, this, false) }

@(private = "file")
native_create_node_iterator :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    root := node_of(arg(args, 0))
    if root == nil do return JS_Null{}
    what: u32 = 0xFFFFFFFF
    if w, ok := arg(args, 1).(f64); ok do what = u32(i64(w))
    ni := new_object(vm)
    ni.host = rawptr(root)
    ni.props["_whatToShow"] = f64(what)
    ni.props["_filter"]     = arg(args, 2) // função / objeto-com-acceptNode / nil
    ni.props["root"]        = wrap_element(vm, root)
    ni.props["whatToShow"]  = f64(what)
    fv := arg(args, 2)
    ni.props["filter"]      = fv != nil ? fv : JS_Null{}
    ni.props["referenceNode"]              = wrap_element(vm, root)
    ni.props["pointerBeforeReferenceNode"] = true
    ni.props["nextNode"]     = mk_dom(vm, ni_next_node)
    ni.props["previousNode"] = mk_dom(vm, ni_prev_node)
    ni.props["detach"]       = mk_dom(vm, dom_noop) // legado: no-op
    return ni
}

// ── busca / wrapper ─────────────────────────────────────────────────────────

@(private = "file")
find_by_id :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
    if n.kind == .Element {
        if v, ok := n.attrs["id"]; ok && v == id do return n
    }
    for c in n.children {
        if r := find_by_id(c, id); r != nil do return r
    }
    return nil
}

// Coleta DESCENDENTES Element que casam (ordem de documento).
// mode: 0=tag ("*"=todos), 1=classe, 2=atributo name.
@(private = "file")
collect_elements :: proc(vm: ^Interp, node: ^dom.Node, out: ^Array, mode: int, want: string) {
    for c in node.children {
        if c.kind == .Element {
            hit := false
            switch mode {
            case 0: hit = want == "*" || c.tag == want
            case 1: hit = node_has_class(c, want)
            case 2: hit = c.attrs["name"] == want
            }
            if hit do append(&out.items, wrap_element(vm, c))
        }
        collect_elements(vm, c, out, mode, want)
    }
}

@(private = "file")
node_has_class :: proc(node: ^dom.Node, cls: string) -> bool {
    fields := strings.fields(get_class(node), context.temp_allocator)
    defer delete(fields, context.temp_allocator)
    for f in fields do if f == cls do return true
    return false
}

@(private = "file")
native_get_elements_by_tag_name :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil do return arr
    tag, _ := arg(args, 0).(string)
    collect_elements(vm, node, arr, 0, strings.to_lower(tag, context.temp_allocator))
    return arr
}

@(private = "file")
native_get_elements_by_class_name :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil do return arr
    cls, _ := arg(args, 0).(string)
    collect_elements(vm, node, arr, 1, cls)
    return arr
}

@(private = "file")
native_get_elements_by_name :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil do return arr
    nm, _ := arg(args, 0).(string)
    collect_elements(vm, node, arr, 2, nm)
    return arr
}

// IDENTIDADE: o mesmo ^dom.Node SEMPRE devolve o MESMO ^Object wrapper. Sem isto,
// cada getElementById/parentNode/firstChild criava um objeto novo → `a === a` era
// false entre duas consultas, quebrando refs/diffing do React (fiber.stateNode,
// event.target === node, etc.). O cache é keyed pelo ponteiro do nó (rawptr).
// Pseudo-filhos: nós que existem na árvore mas NÃO são filhos de luz visíveis ao JS
// nem ao layout normal. "#content" é o document-fragment do <template> (criado pelo
// parser em treebuild.odin) e "#shadow" é a shadow root (criada por attachShadow).
// Ambos precisam sumir de childNodes/children/firstChild/lastChild/siblings, senão
// um `el.childNodes.length` depois de attachShadow passa a mentir.
// Delega ao `dom`: a definição precisa ser UMA só, porque os contadores de filhos
// que o funil de dom.odin mantém (n_elem_kids/n_pseudo_kids, de onde sai o
// `children.length` em O(1)) usam exatamente este critério. Duas cópias da regra
// divergiriam em silêncio no dia em que aparecesse um terceiro pseudo-filho.
is_pseudo_child :: proc(n: ^dom.Node) -> bool {
    return dom.is_pseudo_child(n)
}

// A shadow root de um elemento (nil se não tem). Guardada como pseudo-filho, no
// mesmo padrão que o parser já usa para o conteúdo de <template>.
shadow_root_of :: proc(n: ^dom.Node) -> ^dom.Node {
    if n == nil do return nil
    for c in n.children {
        if c.tag == "#shadow" do return c
    }
    return nil
}

@(private = "file")
last_real_child :: proc(n: ^dom.Node) -> ^dom.Node {
    #reverse for c in n.children {
        if !is_pseudo_child(c) do return c
    }
    return nil
}

// el.attachShadow({mode}): cria a shadow root e devolve-a. O modo fica num atributo
// do próprio nó "#shadow" — `closed` faz `el.shadowRoot` devolver null (spec), mas a
// árvore continua existindo para o layout.
@(private = "file")
native_attach_shadow :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil do return JS_Null{}
    if sr := shadow_root_of(node); sr != nil do return wrap_element(vm, sr) // já existe
    mode := "open"
    if o, ok := arg(args, 0).(^Object); ok {
        if m, mok := get_member(vm, o, "mode").(string); mok && m == "closed" do mode = "closed"
    }
    sr := dom.make_node(.Element)
    sr.tag = strings.clone("#shadow")
    sr.attrs = make(map[string]string)
    // CHAVE também clonada: free_tree faz delete(k) nas chaves de attrs — um literal
    // ali vira bad free no teardown da página.
    sr.attrs[strings.clone("mode")] = strings.clone(mode)
    dom.append_child(node, sr)
    return wrap_element(vm, sr)
}

// node.getRootNode({composed}): a raiz da árvore. Dentro de uma shadow root, é ELA
// (não o document) — salvo com composed:true. O feature-detect do webcomponentsjs é
// `'attachShadow' in Element.prototype && 'getRootNode' in Element.prototype`: sem
// isto o loader baixa o polyfill de Shadow DOM e ele briga com o nosso nativo.
@(private = "file")
native_get_root_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil do return JS_Null{}
    composed := false
    if o, ok := arg(args, 0).(^Object); ok do composed = truthy(get_member(vm, o, "composed"))
    r := node
    for r.parent != nil {
        if !composed && r.tag == "#shadow" do break // a shadow root É a raiz da sua árvore
        r = r.parent
    }
    return wrap_element(vm, r)
}

// slot.assignedNodes()/assignedElements(): os nós de luz projetados neste slot.
@(private = "file")
native_assigned_nodes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil || node.tag != "slot" do return arr
    host: ^dom.Node
    for a := node.parent; a != nil; a = a.parent {
        if a.tag == "#shadow" { host = a.parent; break }
    }
    if host == nil do return arr
    want := node.attrs["name"]
    for c in host.children {
        if is_pseudo_child(c) do continue
        got := ""
        if c.kind == .Element do got = c.attrs["slot"]
        if got == want do append(&arr.items, wrap_element(vm, c))
    }
    return arr
}

// ── Custom Elements (Web Components) ─────────────────────────────────────────
// Antes era um stub: `define` no-op. Só que sem UPGRADE nada acontece — a classe
// nunca é instanciada, `connectedCallback` nunca roda e uma SPA feita de componentes
// (Lit/Angular Elements) fica com a árvore vazia. attachShadow sozinho não resolve:
// quem chama attachShadow é o próprio componente, dentro do connectedCallback.
//
// Upgrade aqui = rodar o construtor da classe com `this` = o wrapper JÁ EXISTENTE do
// nó (o cache de wrappers é keyed por ponteiro, então a identidade se preserva) e
// religar o proto do wrapper à Ctor.prototype, p/ os métodos da classe resolverem.
// O get-hook nativo continua tendo prioridade, então propriedades do DOM não somem.

@(private = "file")
custom_elements_define :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name, nok := arg(args, 0).(string)
    ctor, cok := arg(args, 1).(^Function)
    if !nok || !cok do return nil
    if vm.custom_elements == nil do vm.custom_elements = make(map[string]^Function)
    lower := strings.to_lower(name, context.temp_allocator)
    if _, exists := vm.custom_elements[lower]; exists do return nil // já definido
    vm.custom_elements[strings.clone(lower)] = ctor
    // upgrade dos elementos que JÁ estão no documento
    if vm.document_node != nil do upgrade_tree(vm, cast(^dom.Node) vm.document_node, lower, ctor)
    return nil
}

@(private = "file")
custom_elements_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name, ok := arg(args, 0).(string)
    if !ok || vm.custom_elements == nil do return nil
    lower := strings.to_lower(name, context.temp_allocator)
    if c, has := vm.custom_elements[lower]; has do return c
    return nil
}

@(private = "file")
custom_elements_upgrade :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok || o.host == nil do return nil
    node := cast(^dom.Node) o.host
    maybe_upgrade_element(vm, node)
    return nil
}

@(private = "file")
upgrade_tree :: proc(vm: ^Interp, n: ^dom.Node, tag: string, ctor: ^Function) {
    if n.kind == .Element && n.tag == tag do upgrade_element(vm, n, ctor)
    for c in n.children do upgrade_tree(vm, c, tag, ctor)
}

// Um nó recém-inserido pode ter tag de custom element já registrado.
maybe_upgrade_element :: proc(vm: ^Interp, n: ^dom.Node) {
    if n == nil || n.kind != .Element || vm.custom_elements == nil do return
    if ctor, ok := vm.custom_elements[n.tag]; ok do upgrade_element(vm, n, ctor)
    for c in n.children do maybe_upgrade_element(vm, c)
}

// `run_connected=false` é o caminho do `document.createElement`: a spec CONSTRÓI o
// elemento ali (o constructor roda), mas o connectedCallback só na INSERÇÃO. Com ele
// disparando cedo, um componente que mexe em `parentNode`/`ownerDocument` rodaria
// sobre um nó solto — e como o UPGRADED_KEY é idempotente, o callback nunca mais
// chegaria no momento certo.
@(private = "file")
upgrade_element :: proc(vm: ^Interp, n: ^dom.Node, ctor: ^Function, run_connected := true) {
    w, wok := wrap_element(vm, n).(^Object)
    if !wok do return

    if _, done := w.props[UPGRADED_KEY]; !done { // construção: idempotente
        w.props[UPGRADED_KEY] = true

        // proto = Ctor.prototype: métodos da classe (render, connectedCallback, ...)
        // passam a resolver no wrapper. A cadeia do DOM continua atrás dele.
        if proto, pok := get_member(vm, ctor, "prototype").(^Object); pok {
            // "sem cadeia própria" agora inclui Object.prototype: desde que new_object
            // liga todo objeto nele, o `.prototype` de uma classe que NÃO estende
            // HTMLElement chega aqui com proto = Object.prototype em vez de nil. Sem
            // incluir esse caso, o custom element perdia a cadeia do DOM inteira.
            if proto.proto == nil || proto.proto == vm.object_proto do proto.proto = vm.dom_element_proto
            w.proto = proto
        }
        // CAMPOS DE CLASSE: `class X extends HTMLElement { renderOptions = {host:this} }`.
        // Os inicializadores rodam em construct_object, não em call_function — chamar o
        // construtor "cru" deixava todo campo undefined. Era isso que quebrava o Lit:
        // `this.renderOptions.renderBefore` com renderOptions undefined.
        vm_init_instance_fields(vm, ctor, w)
        vm.pending_new_target = ctor // new.target = a classe (setup_call_scope consome)
        call_function(vm, ctor, w, nil) // roda o constructor com this = o elemento
        vm_clear_uncaught(vm)           // um componente que lança não derruba os outros
    }

    // connectedCallback tem marca PRÓPRIA, separada da construção: um elemento que
    // nasceu por createElement já está construído mas ainda NÃO conectado, e quando
    // ele for inserido o callback tem de chegar. Com uma marca só, o caminho da
    // inserção via `done do return` e o callback se perdia para sempre.
    if !run_connected do return
    if _, conn := w.props[CONNECTED_KEY]; conn do return
    w.props[CONNECTED_KEY] = true
    if cb, ok := get_member(vm, w, "connectedCallback").(^Function); ok {
        call_function(vm, cb, w, nil)
        vm_clear_uncaught(vm)
    }
}

@(private = "file")
UPGRADED_KEY :: "__ce_upgraded"
@(private = "file")
CONNECTED_KEY :: "__ce_connected"

// Nome de tag como a spec expõe em `tagName`/`nodeName` (que devem ser IGUAIS):
// MAIÚSCULO p/ elemento HTML (namespace vazio), preservando a caixa p/ conteúdo
// estrangeiro (SVG/MathML — ex.: `foreignObject`; nós SVG são guardados em
// minúsculo, então saem minúsculos, mas nunca uppercased à força). Antes o
// `tagName` devolvia `node.tag` cru (minúsculo): `el.tagName === 'SCRIPT'` —
// idioma comum de site — FALHAVA. Devolve uma fatia efêmera; o chamador clona
// (own_str). Usa temp_allocator no uppercase.
@(private = "file")
element_tag_name :: proc(node: ^dom.Node) -> string {
    if node.ns == "" do return strings.to_upper(node.tag, context.temp_allocator)
    return node.tag
}

wrap_element :: proc(vm: ^Interp, node: ^dom.Node) -> Value {
    key := rawptr(node)
    if cached, ok := vm.node_wrappers[key]; ok do return cached
    o := new_object(vm)
    o.host = key
    o.get = dom_elem_get
    o.set = dom_elem_set
    // proto = HTMLElement.prototype (cadeia …←Element←HTMLElement): habilita
    // `el instanceof Element/Node/HTMLElement` e alcança métodos poly-preenchidos
    // em Element/Node/HTMLElement.prototype (o get-hook nativo tem prioridade).
    if vm.dom_element_proto == nil do install_dom_interfaces(vm)
    // Proto por TIPO de nó: fragmento de <template> e shadow root não são
    // HTMLElement — o instanceof precisa distinguir (o webcomponentsjs testa).
    switch node.tag {
    case "#content": o.proto = vm.dom_fragment_proto
    case "#shadow":  o.proto = vm.dom_shadowroot_proto
    case:
        // prototype específico por tag quando houver (habilita `el instanceof
        // HTMLScriptElement` etc.); senão o HTMLElement genérico.
        if p, ok := vm.dom_tag_protos[node.tag]; ok do o.proto = p
        else                                        do o.proto = vm.dom_element_proto
    }
    if o.proto == nil do o.proto = vm.dom_element_proto
    vm.node_wrappers[key] = o
    return o
}

// Cache (por wrapper de iframe) do contentWindow — identidade estável:
// `iframe.contentWindow === iframe.contentWindow`.
@(private = "file")
IFRAME_WIN_KEY :: "__iframe_contentWindow"

// Janela+documento de um <iframe> (em branco). window_get resolve o `document`
// PRÓPRIO (sombreia o do main) antes de cair no global; proto = window principal
// p/ herdar location/navigator/addEventListener/… O documento em branco reusa a
// mesma fábrica do document.implementation.createHTMLDocument (M96).
@(private = "file")
iframe_content_window :: proc(vm: ^Interp, o: ^Object, node: ^dom.Node) -> ^Object {
    if cw, ok := o.props[IFRAME_WIN_KEY].(^Object); ok do return cw // cacheado
    iwin := new_object(vm)
    iwin.get  = window_get
    iwin.set  = window_set
    iwin.host = rawptr(node) // addEventListener no host do iframe
    if idoc, dok := native_create_html_document(vm, nil, nil).(^Object); dok {
        iwin.props["document"] = idoc
        idoc.props["defaultView"] = iwin // contentDocument.defaultView === contentWindow
    }
    if mw, ok := env_get(vm.global, "window"); ok {
        if mwo, mok := mw.(^Object); mok do iwin.proto = mwo // herda a API de janela
    }
    o.props[IFRAME_WIN_KEY] = iwin
    mark_non_enumerable(o, IFRAME_WIN_KEY) // fora de Object.keys(iframe)
    return iwin
}

// Remove a entrada de cache de um nó (e da subárvore) prestes a ser liberado, para
// que o wrapper não sobreviva apontando para memória do DOM já liberada.
@(private = "file")
// Chamado antes de free_tree(node): esquece a subárvore INTEIRA nos registros
// do vm — wrappers, owned_nodes e listeners. Sem tirar de owned_nodes, o
// free_orphan_nodes do vm_destroy dereferencia `.parent` de memória liberada e
// pode dar free_tree de novo (double-free) num nó de createElement que foi
// anexado e depois destruído por textContent=/innerHTML=.
forget_wrapper :: proc(vm: ^Interp, node: ^dom.Node) {
    if node == nil do return
    // ⚠️ CRASH DO WIKIPEDIA (use-after-free): tirar o wrapper do MAPA não basta —
    // o objeto JS continua vivo na página apontando p/ o nó que vamos liberar.
    // Padrão real: a página guarda `var el = ...`, o container leva
    // `textContent=`/`innerHTML=` (que libera a subárvore) e DEPOIS o script faz
    // `outroPai.appendChild(el)` → um ponteiro MORTO entra em children e o
    // próximo querySelectorAll percorre memória reciclada.
    // Zerar o host torna a referência INERTE (node_of devolve nil e as nativas de
    // DOM caem no early-return) em vez de corromper a heap.
    if w, ok := vm.node_wrappers[rawptr(node)]; ok && w != nil {
        // As coleções vivas (children/childNodes) pendem do wrapper e têm host PRÓPRIO
        // apontando p/ este nó: zerar só o do wrapper deixaria `var c = el.children`
        // guardado pela página lendo memória reciclada.
        coll_forget(vm, w)
        w.host = nil
    }
    delete_key(&vm.node_wrappers, rawptr(node))
    delete_key(&vm.owned_nodes, rawptr(node))
    if list, ok := vm.listeners[rawptr(node)]; ok {
        delete(list)
        delete_key(&vm.listeners, rawptr(node))
    }
    for c in node.children do forget_wrapper(vm, c)
}

// True se `n` ou QUALQUER descendente ainda tem um wrapper JS vivo no mapa. Se tem,
// o JS pode estar guardando o nó e re-inseri-lo depois — liberá-lo seria um
// use-after-free (ou, com o host zerado, um zumbi que quebra appendChild).
@(private = "file")
subtree_has_live_wrapper :: proc(vm: ^Interp, n: ^dom.Node) -> bool {
    if n == nil do return false
    if w, ok := vm.node_wrappers[rawptr(n)]; ok && w != nil do return true
    for c in n.children do if subtree_has_live_wrapper(vm, c) do return true
    return false
}

// Remove TODOS os filhos de `node` — usado por textContent=/innerHTML=. Um filho
// cuja subárvore tem wrapper JS vivo é só DESANEXADO (parent=nil) e registrado em
// owned_nodes (p/ free_orphan_nodes liberá-lo no destroy se ficar órfão); o wrapper
// é PRESERVADO para o JS poder re-inseri-lo. Sem isto, o padrão do jQuery.buildFragment
// (captura `childNodes`, faz `tmp.textContent=""`, re-anexa cada nó via
// `fragment.appendChild(elem)`) achava o host zerado, appendChild devolvia undefined,
// e o setup do MediaWiki quebrava com "reading 'getElementsByTagName' of undefined"
// (wikipedia). Um filho SEM wrapper vivo (caso comum de re-render de SPA: ninguém
// referencia os nós antigos) é liberado na hora, p/ não vazar. Ver [[dom-uaf-wikipedia]].
@(private = "file")
detach_or_free_children :: proc(vm: ^Interp, node: ^dom.Node) {
    // A ORDEM IMPORTA (M201): o MutationRecord é montado ANTES do laço porque o
    // `wrap_element` que ele faz em cada filho removido é EXATAMENTE o que faz o
    // subtree_has_live_wrapper abaixo dar true e PRESERVAR o nó. Sem isto,
    // `record.removedNodes[0]` apontaria para memória já liberada. A retenção é
    // condicional: sem observador interessado nada é criado e nada muda.
    if mo_active(vm) do mo_record_children(vm, node, nil, node.children[:], nil, nil)
    for c in node.children {
        if subtree_has_live_wrapper(vm, c) {
            c.parent = nil                   // desanexa; NÃO libera (JS pode re-inserir)
            vm.owned_nodes[rawptr(c)] = true // vira órfão gerenciado: cleanup no destroy
        } else {
            forget_wrapper(vm, c)
            dom.free_tree(c)
        }
    }
    dom.kids_clear(node)
}

// Cria uma interface DOM (Element, Node, HTMLElement, …): função nomeada cujo
// `.prototype` é um objeto real com o proto ENCADEADO no parent
// (Object.prototype ← EventTarget ← Node ← Element ← HTMLElement ← HTMLDivElement…).
// `new X()` em navegadores lança "Illegal constructor"; aqui a função é não-nativa
// (só carrega o prototype) — nenhum bundle real chama `new HTMLElement()`, e um
// objeto inócuo é preferível a estourar.
@(private = "file")
// Anexa um `.prototype` a um construtor NATIVO já existente (Event/XMLHttpRequest/…
// que usam ctor próprio, não mk_dom_interface). Polyfills leem `Ctor.prototype.metodo`
// (patch/feature-detect) — sem `.prototype` isso lançava "reading 'prototype' of
// undefined" (gap-report: soundcloud XMLHttpRequest.prototype, mercadolivre
// Event.prototype). Devolve o proto p/ popular com métodos.
attach_prototype :: proc(vm: ^Interp, f: ^Function, parent_proto: ^Object) -> ^Object {
    if f.props == nil do f.props = make(map[string]Value)
    proto := new_object(vm)
    proto.proto = parent_proto
    proto.props["constructor"] = f
    mark_non_enumerable(proto, "constructor")
    f.props["prototype"] = proto
    return f.props["prototype"].(^Object)
}

mk_dom_interface :: proc(vm: ^Interp, name: string, parent_proto: ^Object) -> ^Function {
    f := new_function(vm)
    f.name = name
    f.props = make(map[string]Value)
    proto := new_object(vm)
    proto.proto = parent_proto
    proto.props["constructor"] = f
    mark_non_enumerable(proto, "constructor") // constructor é não-enumerável (spec)
    f.props["prototype"] = proto
    return f
}

// Monta (idempotente) a hierarquia de interfaces DOM e a expõe como GLOBAIS.
// MOTIVO: `Element.prototype.matches = …` (polyfills ubíquos), `x instanceof
// HTMLElement`, `Node.prototype`, feature-detects — tudo batia em "Cannot read
// properties of undefined (reading 'prototype')" porque Element/Node/HTMLElement/
// Document NÃO existiam como globais → o bundle abortava no init → PÁGINA EM BRANCO
// (archive.org e cia., grupo #1 do gap-miner empatado em 8 sites).
// HTMLElement.prototype é o proto dos wrappers de elemento (wrap_element), então
// métodos poly-preenchidos em Element/Node/HTMLElement.prototype ficam ALCANÇÁVEIS
// por `el.metodo()` (o get-hook nativo tem prioridade; a cadeia só preenche lacunas)
// e `el instanceof Element/Node/HTMLElement` passa (js_instanceof anda o proto).
@(private = "file")
install_dom_interfaces :: proc(vm: ^Interp) {
    if vm.dom_element_ctor != nil do return // já montado (idempotente)

    event_target := mk_dom_interface(vm, "EventTarget", vm.object_proto)
    et_proto := event_target.props["prototype"].(^Object)
    node := mk_dom_interface(vm, "Node", et_proto)
    node_proto := node.props["prototype"].(^Object)
    element := mk_dom_interface(vm, "Element", node_proto)
    el_proto := element.props["prototype"].(^Object)
    html_element := mk_dom_interface(vm, "HTMLElement", el_proto)
    vm.dom_element_ctor  = html_element
    vm.dom_element_proto = html_element.props["prototype"].(^Object)
    char_data := mk_dom_interface(vm, "CharacterData", node_proto)
    cd_proto := char_data.props["prototype"].(^Object)

    // DocumentFragment/ShadowRoot têm prototypes PRÓPRIOS: os wrappers de "#content"
    // e "#shadow" apontam para eles, senão `t.content.cloneNode() instanceof
    // DocumentFragment` dá false — é um dos testes do webcomponentsjs, e falhar nele
    // faz o polyfill de <template> carregar por cima do nosso nativo.
    frag_ctor := mk_dom_interface(vm, "DocumentFragment", node_proto)
    shadow_ctor := mk_dom_interface(vm, "ShadowRoot", node_proto)
    vm.dom_fragment_proto = frag_ctor.props["prototype"].(^Object)
    vm.dom_shadowroot_proto = shadow_ctor.props["prototype"].(^Object)

    base := [?]struct{ name: string, ctor: ^Function }{
        {"EventTarget", event_target}, {"Node", node}, {"Element", element},
        {"HTMLElement", html_element}, {"CharacterData", char_data},
        {"Text",             mk_dom_interface(vm, "Text", cd_proto)},
        {"Comment",          mk_dom_interface(vm, "Comment", cd_proto)},
        {"Document",         mk_dom_interface(vm, "Document", node_proto)},
        {"HTMLDocument",     mk_dom_interface(vm, "HTMLDocument", node_proto)},
        {"DocumentFragment", frag_ctor},
        {"ShadowRoot",       shadow_ctor},
        {"SVGElement",       mk_dom_interface(vm, "SVGElement", el_proto)}, // extends Element
    }
    for g in base do env_define(vm.global, g.name, g.ctor)

    // Interfaces que NINGUÉM servia e que o M150 nomeou na mineração (antes viravam
    // undefined silencioso; depois do M150, ReferenceError que ABORTA o módulo —
    // medido: `DOMTokenList` custou 66 caixas no ge.globo e `NodeList` 35 no apple).
    // São cascas, como as de cima: existem para `instanceof`, para feature-detect
    // (`if (!NodeList.prototype.forEach)`) e para o padrão de polyfill que escreve
    // no .prototype. Nossas NodeList/DOMTokenList reais são Array/string do motor,
    // então `instanceof` dá false — mas false é o que o browser responderia para o
    // objeto errado, e é infinitamente melhor que lançar.
    // NodeList/HTMLCollection deixaram de ser casca: são o prototype REAL das coleções
    // vivas de children/childNodes (dom_collection.odin), montado logo abaixo.
    orfas := [?]struct{ name: string, proto: ^Object }{
        {"NodeList",          vm.object_proto},
        {"HTMLCollection",    vm.object_proto},
        {"DOMTokenList",      vm.object_proto},
        {"DOMException",      vm.object_proto},
        {"DOMStringMap",      vm.object_proto},
        {"CSSStyleSheet",     vm.object_proto},
        {"CSSStyleDeclaration", vm.object_proto},
        {"Attr",              node_proto},          // Attr extends Node (spec)
        // HTMLMediaElement NÃO entra aqui: agora é criada com Video/Audio
        // pendurados nela, logo abaixo (a ordem importa).
    }
    for o in orfas {
        ctor := mk_dom_interface(vm, o.name, o.proto)
        env_define(vm.global, o.name, ctor)
    }
    if hc, ok := env_get(vm.global, "HTMLCollection"); ok {
        if nl, nok := env_get(vm.global, "NodeList"); nok {
            hcf, _ := hc.(^Function)
            nlf, _ := nl.(^Function)
            if hcf != nil && nlf != nil {
                hcp, _ := hcf.props["prototype"].(^Object)
                nlp, _ := nlf.props["prototype"].(^Object)
                if hcp != nil && nlp != nil do install_collection_protos(vm, hcp, nlp)
            }
        }
    }

    // `Window` é a interface da própria janela: `win instanceof Window` e
    // `Window.prototype.foo = …` (polyfill) aparecem em bundle real. O prototype
    // do wrapper de window passa a ser o dela, senão o instanceof mente.
    // ⚠️ install_dom_interfaces roda ANTES de `window` existir no escopo global,
    // então NÃO dá para ligar o proto da janela aqui — quem faz isso é o trecho
    // do env_define("window", win), lá embaixo. (Tentei aqui primeiro; o
    // env_get("window") volta vazio e o instanceof fica mentindo em silêncio.)
    env_define(vm.global, "Window", mk_dom_interface(vm, "Window", et_proto)) // extends EventTarget

    // Subtipos HTML*Element mais referenciados por libs/polyfills — herdam de
    // HTMLElement.prototype. (Lista pragmática; HTMLUnknownElement cobre o resto.)
    html_subtypes := [?]string{
        "HTMLDivElement", "HTMLSpanElement", "HTMLAnchorElement", "HTMLInputElement",
        "HTMLButtonElement", "HTMLImageElement", "HTMLParagraphElement", "HTMLUListElement",
        "HTMLOListElement", "HTMLLIElement", "HTMLSelectElement", "HTMLOptionElement",
        "HTMLTextAreaElement", "HTMLFormElement", "HTMLTableElement", "HTMLCanvasElement",
        "HTMLScriptElement", "HTMLStyleElement", "HTMLLinkElement", "HTMLHeadingElement",
        "HTMLBodyElement", "HTMLHtmlElement", "HTMLHeadElement", "HTMLIFrameElement",
        "HTMLLabelElement", "HTMLPreElement", "HTMLTemplateElement", "HTMLUnknownElement",
        // nomeados pelo gap-report depois do M150 (coingecko pedia HTMLMetaElement)
        "HTMLMetaElement", "HTMLTitleElement", "HTMLSourceElement", "HTMLPictureElement",
        "HTMLTableRowElement", "HTMLTableCellElement", "HTMLTableSectionElement",
        "HTMLTimeElement", "HTMLDataListElement",
        "HTMLFieldSetElement", "HTMLLegendElement", "HTMLOptGroupElement", "HTMLProgressElement",
    }
    for name in html_subtypes {
        env_define(vm.global, name, mk_dom_interface(vm, name, vm.dom_element_proto))
    }
    // ⚠️ Video/Audio saíram da lista acima porque a cadeia da spec é
    // HTMLVideoElement → HTMLMediaElement → HTMLElement, e eles estavam como
    // IRMÃOS de HTMLMediaElement (todos direto em HTMLElement). Com isso
    // `video instanceof HTMLMediaElement` mentia e `HTMLMediaElement.prototype.play`
    // — que todo polyfill de player escreve/lê — não alcançava instância nenhuma.
    // A casca dela saiu de `orfas` e é criada AQUI, antes dos dois, para que o
    // prototype exista na hora de pendurá-los.
    {
        mp := mk_dom_interface(vm, "HTMLMediaElement", vm.dom_element_proto)
        env_define(vm.global, "HTMLMediaElement", mp)
        media_proto, _ := mp.props["prototype"].(^Object)
        if media_proto == nil do media_proto = vm.dom_element_proto
        env_define(vm.global, "HTMLVideoElement", mk_dom_interface(vm, "HTMLVideoElement", media_proto))
        env_define(vm.global, "HTMLAudioElement", mk_dom_interface(vm, "HTMLAudioElement", media_proto))
    }

    // Mapa TAG → prototype específico: `<script>` deve dar `instanceof
    // HTMLScriptElement` (o runtime do Turbopack/Next.js EXIGE isso —
    // `document.currentScript instanceof HTMLScriptElement`, senão lança
    // "InvariantError: Expected document.currentScript to be a <script>
    // element", visto em 5 sites do gap-miner). Os prototypes de subtipo já
    // encadeiam sob HTMLElement.prototype, então instanceof HTMLElement/Element/
    // Node segue valendo. Só as tags com subtipo declarado entram; o resto usa o
    // HTMLElement genérico. (h1..h6 → HTMLHeadingElement, como na spec.)
    proto_by_name :: proc(vm: ^Interp, iface: string) -> ^Object {
        if v, ok := env_get(vm.global, iface); ok {
            if f, fok := v.(^Function); fok {
                if p, pok := f.props["prototype"].(^Object); pok do return p
            }
        }
        return nil
    }
    tag_iface := [?]struct{ tag, iface: string }{
        {"div", "HTMLDivElement"}, {"span", "HTMLSpanElement"}, {"a", "HTMLAnchorElement"},
        {"input", "HTMLInputElement"}, {"button", "HTMLButtonElement"}, {"img", "HTMLImageElement"},
        {"p", "HTMLParagraphElement"}, {"ul", "HTMLUListElement"}, {"ol", "HTMLOListElement"},
        {"li", "HTMLLIElement"}, {"select", "HTMLSelectElement"}, {"option", "HTMLOptionElement"},
        {"textarea", "HTMLTextAreaElement"}, {"form", "HTMLFormElement"}, {"table", "HTMLTableElement"},
        {"canvas", "HTMLCanvasElement"}, {"script", "HTMLScriptElement"}, {"style", "HTMLStyleElement"},
        {"link", "HTMLLinkElement"}, {"body", "HTMLBodyElement"}, {"html", "HTMLHtmlElement"},
        {"head", "HTMLHeadElement"}, {"iframe", "HTMLIFrameElement"}, {"label", "HTMLLabelElement"},
        {"pre", "HTMLPreElement"}, {"template", "HTMLTemplateElement"},
        {"h1", "HTMLHeadingElement"}, {"h2", "HTMLHeadingElement"}, {"h3", "HTMLHeadingElement"},
        {"h4", "HTMLHeadingElement"}, {"h5", "HTMLHeadingElement"}, {"h6", "HTMLHeadingElement"},
        {"meta", "HTMLMetaElement"}, {"title", "HTMLTitleElement"}, {"source", "HTMLSourceElement"},
        {"picture", "HTMLPictureElement"}, {"tr", "HTMLTableRowElement"},
        {"td", "HTMLTableCellElement"}, {"th", "HTMLTableCellElement"},
        {"tbody", "HTMLTableSectionElement"}, {"thead", "HTMLTableSectionElement"},
        {"tfoot", "HTMLTableSectionElement"}, {"video", "HTMLVideoElement"},
        {"audio", "HTMLAudioElement"}, {"time", "HTMLTimeElement"},
        {"datalist", "HTMLDataListElement"}, {"fieldset", "HTMLFieldSetElement"},
        {"legend", "HTMLLegendElement"}, {"optgroup", "HTMLOptGroupElement"},
        {"progress", "HTMLProgressElement"},
    }
    for e in tag_iface {
        if p := proto_by_name(vm, e.iface); p != nil do vm.dom_tag_protos[e.tag] = p
    }
}

// Coloca os métodos nativos de elemento nos protótipos de interface CERTOS, para
// que `Element.prototype.matches`, `Node.prototype.appendChild`, feature-detects
// (`if (!Element.prototype.matches) …`) e o padrão uncurryThis
// (`Element.prototype.matches.call(el, sel)`) resolvam o NATIVO — como nos browsers.
// Colocação na interface-BASE: as derivadas herdam pela cadeia de protótipo
// (`Node.prototype.appendChild` próprio → `Element.prototype.appendChild` herdado),
// idêntico ao real. `el.metodo()` continua indo pelo get-hook (prioridade); isto é
// só p/ leituras no protótipo. Métodos são não-enumeráveis (spec). Chamado no FIM
// de install_dom (todos os dom_element_methods já registrados).
@(private = "file")
populate_dom_interface_prototypes :: proc(vm: ^Interp) {
    if vm.dom_element_ctor == nil do install_dom_interfaces(vm)

    proto_of :: proc(vm: ^Interp, name: string) -> ^Object {
        if v, ok := env_get(vm.global, name); ok {
            if f, fok := v.(^Function); fok {
                if p, pok := f.props["prototype"].(^Object); pok do return p
            }
        }
        return nil
    }
    put :: proc(vm: ^Interp, proto: ^Object, names: []string) {
        if proto == nil do return
        for n in names {
            if fn, ok := vm.dom_element_methods[n]; ok {
                proto.props[n]  = fn
                mark_non_enumerable(proto, n) // não-enumerável (Object.keys(Element.prototype) === [])
            }
        }
    }
    // Colocação padrão (interface-base; derivadas herdam):
    put(vm, proto_of(vm, "EventTarget"), {"addEventListener", "removeEventListener", "dispatchEvent"})
    put(vm, proto_of(vm, "Node"), {"appendChild", "insertBefore", "removeChild", "replaceChild", "cloneNode", "contains", "hasChildNodes", "isEqualNode", "isSameNode", "attachShadow", "getRootNode",
        "assignedNodes", "assignedElements"})
    put(vm, proto_of(vm, "Element"), {
        "getAttribute", "setAttribute", "removeAttribute", "hasAttribute", "toggleAttribute",
        "matches", "matchesSelector", "webkitMatchesSelector", "mozMatchesSelector",
        "closest", "getBoundingClientRect", "getClientRects", "scrollIntoView",
        "remove", "before", "after", "replaceWith", "append", "prepend", "replaceChildren",
        "insertAdjacentElement", "insertAdjacentText", "insertAdjacentHTML",
        "querySelector", "querySelectorAll", "getElementsByTagName", "getElementsByClassName",
        "hasAttributes", "getAttributeNames",
    })
    put(vm, proto_of(vm, "HTMLElement"), {"focus", "blur"})

    // (As propriedades servidas pelo get-hook — content/shadowRoot/host/... — não
    // precisam de marcador no prototype: js_in consulta o hook, então `'content' in
    // template` responde certo. Ver interp.odin/js_in.)

    // ACESSORES nos prototypes de interface (M138). O get-hook da INSTÂNCIA já serve
    // essas props, mas `Object.getOwnPropertyDescriptor(Element.prototype,"innerHTML")`
    // devolvia undefined — e ler `.get` desse descritor é como toda lib captura o
    // acessor nativo (React no inputValueTracking, Svelte, polyfills). No crates.io
    // era exatamente isso: `o(t, "…")` nativa devolvendo undefined e o `.get` em cima.
    //
    // Os acessores sintetizados delegam ao get_member/set_member do RECEPTOR, então
    // reusam o hook — não há segunda implementação p/ divergir. Para uma instância o
    // hook continua vencendo (get_member consulta o.get antes da cadeia).
    accessors :: proc(vm: ^Interp, proto: ^Object, names: []string) {
        if proto == nil do return
        if proto.getters == nil do proto.getters = make(map[string]^Function)
        if proto.setters == nil do proto.setters = make(map[string]^Function)
        for n in names {
            g := mk_native(vm, dom_accessor_get); g.bound = own_str(vm, n); g.name = n
            s := mk_native(vm, dom_accessor_set); s.bound = own_str(vm, n); s.name = n
            proto.getters[n] = g
            proto.setters[n] = s
            mark_non_enumerable(proto, n) // não-enumerável, como no navegador
        }
    }
    accessors(vm, proto_of(vm, "Node"), {"textContent", "nodeValue", "nodeName", "nodeType",
        "parentNode", "parentElement", "childNodes", "firstChild", "lastChild",
        "nextSibling", "previousSibling", "isConnected", "ownerDocument"})
    accessors(vm, proto_of(vm, "Element"), {"innerHTML", "outerHTML", "id", "className",
        "classList", "tagName", "attributes", "children", "firstElementChild",
        "lastElementChild", "nextElementSibling", "previousElementSibling",
        "clientWidth", "clientHeight", "scrollTop", "scrollLeft"})
    accessors(vm, proto_of(vm, "HTMLElement"), {"innerText", "style", "dataset", "hidden",
        "title", "value", "checked", "disabled", "type", "name", "href", "src"})
    accessors(vm, proto_of(vm, "CharacterData"), {"data", "length"})
}

// Acessor sintetizado de interface DOM: o NOME da prop vem do `bound` da nativa
// (mesma "closure de nativa" usada por bind/generator), e a leitura/escrita é
// delegada ao receptor — ou seja, ao get-hook do elemento.
@(private = "file")
dom_accessor_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name, ok := vm.native_bound.(string)
    if !ok do return nil
    o, ook := this.(^Object)
    if !ook || o.host == nil do return nil // só wrapper de nó (o prototype não tem host)
    // Chama o HOOK direto, NUNCA get_member: com get_member, um nome que o hook não
    // serve cai na cadeia de protótipo, reencontra ESTE getter e recursa até estourar
    // a pilha. Foi o que aconteceu com `parentElement` — as rejeições do crates.io
    // viraram um RangeError. Delegar ao hook expõe exatamente o que ele serve.
    if o.get != nil {
        if v, handled := o.get(vm, o, name); handled do return v
    }
    if v, has := o.props[name]; has do return v
    return nil
}

@(private = "file")
dom_accessor_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    name, ok := vm.native_bound.(string)
    if !ok do return nil
    o, ook := this.(^Object)
    if !ook || o.host == nil do return nil // idem: só wrapper de nó
    if o.set != nil {
        if handled := o.set(vm, o, name, arg(args, 0)); handled do return nil
    }
    oput(o, name, arg(args, 0))
    return nil
}

// Constructor compartilhado dos elementos DOM (== HTMLElement). O React lê
// descriptors de `node.constructor.prototype` (inputValueTracking); o prototype é
// o mesmo compartilhado da hierarquia de interfaces acima.
@(private = "file")
dom_element_constructor :: proc(vm: ^Interp) -> ^Function {
    if vm.dom_element_ctor == nil do install_dom_interfaces(vm)
    return vm.dom_element_ctor
}

// ⚠️ NÃO é `private="file"`: o canvas.odin resolve o `<canvas>` do `this` com
// esta MESMA proc (uma 2ª cópia divergiria calada).
node_of :: proc(this: Value) -> ^dom.Node {
    o, ok := this.(^Object)
    if !ok do return nil
    return cast(^dom.Node) o.host
}

// ── atributos ───────────────────────────────────────────────────────────────

// Grava um atributo a partir de um Value JS (converte p/ string via to_text).
@(private = "file")
set_attr_val :: proc(vm: ^Interp, node: ^dom.Node, key: string, val: Value) {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, val)
    set_attr_str(vm, node, key, strings.to_string(sb))
}

// Grava um atributo (dom-owned), liberando o valor antigo se existir.
// FUNIL ÚNICO de escrita de atributo vinda do JS — setAttribute, className,
// id, dataset, el.style.* e os reflexos de propriedade passam todos por aqui.
// Recebe o `vm` para o MutationObserver ver a escrita (e para o compilador
// apontar quem esquecer). Ver mutation_observer.odin.
@(private = "file")
set_attr_str :: proc(vm: ^Interp, node: ^dom.Node, key, val: string) {
    if mo_active(vm) {
        old, had := node.attrs[key]
        mo_record_attr(vm, node, key, old, had) // valor ANTIGO: tem de ser lido antes
    }
    // dom.set_attr mantém a ORDEM de documento (a spec exige em
    // getAttributeNames()/.attributes; o lit-html depende dela).
    dom.set_attr(node, strings.clone(key), strings.clone(val))
}

@(private = "file")
native_get_element_by_id :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    doc, ok := this.(^Object)
    if !ok || doc.host == nil || len(args) < 1 do return JS_Null{}
    id, sok := args[0].(string)
    if !sok do return JS_Null{}
    node := find_by_id(cast(^dom.Node) doc.host, id)
    if node == nil do return JS_Null{}
    return wrap_element(vm, node)
}

// querySelector: 1º descendente que casa o seletor CSS (ou null). Funciona em
// `document` e em elementos (escopo = subárvore, excluindo o próprio escopo).
@(private = "file")
native_query_selector :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 || g_dom_query == nil do return JS_Null{}
    sel, ok := args[0].(string)
    if !ok do return JS_Null{}
    found: [dynamic]^dom.Node
    defer delete(found)
    if !selector_check(vm, sel) do return JS_Null{}
    g_dom_query(node, sel, false, &found)
    if len(found) == 0 do return JS_Null{}
    return wrap_element(vm, found[0])
}

// querySelectorAll: TODOS os descendentes que casam, como Array de wrappers
// (ganha length/forEach/map/... de graça — não é um NodeList de verdade).
@(private = "file")
native_query_selector_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil || len(args) < 1 || g_dom_query == nil do return arr
    sel, ok := args[0].(string)
    if !ok do return arr
    found: [dynamic]^dom.Node
    defer delete(found)
    if !selector_check(vm, sel) do return arr
    g_dom_query(node, sel, true, &found)
    for n in found do append(&arr.items, wrap_element(vm, n))
    return arr
}

@(private = "file")
native_get_attribute :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return JS_Null{}
    key, kok := args[0].(string)
    if !kok do return JS_Null{}
    if v, found := node.attrs[key]; found do return own_str(vm, v) // clonado: dom-owned dangleia no próximo set
    return JS_Null{}
}

@(private = "file")
native_set_attribute :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 2 do return nil
    key, kok := args[0].(string)
    if !kok do return nil
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, args[1])
    set_attr_str(vm, node, key, strings.to_string(sb))
    return nil
}

// ── createElement / appendChild / removeChild ───────────────────────────────

@(private = "file")
native_create_element :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) < 1 do return JS_Null{}
    tag, ok := args[0].(string)
    if !ok do return JS_Null{}
    node := dom.make_node(.Element)
    node.tag = strings.clone(tag)
    node.attrs = make(map[string]string)
    vm.owned_nodes[rawptr(node)] = true // rastreado p/ liberar se ficar órfão
    w := wrap_element(vm, node)
    // CUSTOM ELEMENT: a spec CONSTRÓI aqui (o "create an element" roda o constructor
    // quando a definição já existe). Nós só promovíamos na inserção, então tudo que o
    // constructor instala nascia ausente e o site lia undefined de um elemento que
    // parecia normal. Era o erro que sobrava no github.com depois do M209:
    //   Object.getPrototypeOf(document.createElement("turbo-frame").delegate)
    // — o Turbo cria o elemento SÓ para ler o protótipo do delegate, sem nunca
    // inserir. `.delegate` vinha undefined e o `getPrototypeOf` disso devolvia null:
    // `Cannot read properties of null (reading 'requestErrored')`.
    // O connectedCallback NÃO roda aqui (ver upgrade_element): o nó está solto.
    if vm.custom_elements != nil {
        lower := strings.to_lower(tag, context.temp_allocator)
        if ctor, ok := vm.custom_elements[lower]; ok do upgrade_element(vm, node, ctor, false)
    }
    return w
}

// node.cloneNode(deep): cópia do nó (rasa por padrão; profunda se deep truthy).
// Muitos sites (ex.: galerias que montam itens a partir de um <template>/nó modelo
// + JSON em data-*) fazem `modelo.cloneNode(true)` por item — sem isto lançava
// "cloneNode is not a function" e a construção da lista abortava (grid vazio).
// Copia kind/tag/text/attrs; NÃO copia listeners (como manda a spec). Cada nó
// clonado entra em owned_nodes p/ ser liberado se ficar órfão.
@(private = "file")
clone_subtree :: proc(vm: ^Interp, src: ^dom.Node, deep: bool) -> ^dom.Node {
    n := dom.make_node(src.kind)
    if src.tag  != "" do n.tag  = strings.clone(src.tag)
    if src.text != "" do n.text = strings.clone(src.text)
    if src.kind == .Element {
        n.attrs = make(map[string]string)
        cnames := make([dynamic]string, context.temp_allocator)
        dom.attr_names(src, &cnames) // clona preservando a ordem
        for k in cnames do dom.set_attr(n, strings.clone(k), strings.clone(src.attrs[k]))
    }
    vm.owned_nodes[rawptr(n)] = true
    if deep {
        for c in src.children {
            dom.append_child(n, clone_subtree(vm, c, true))
        }
    }
    return n
}

@(private = "file")
// document.importNode(node, deep): clona um nó de OUTRO documento p/ este. Não
// temos múltiplos documentos, então é um cloneNode — mas o lit-html chama
// `d.importNode(template.content, true)` para instanciar CADA template; sem isto o
// commit morria e o componente ficava só com o marcador.
native_import_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok || o.host == nil do return JS_Null{}
    src := cast(^dom.Node) o.host
    deep := len(args) >= 2 && truthy(args[1])
    return wrap_element(vm, clone_subtree(vm, src, deep))
}

@(private = "file")
native_clone_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    src := node_of(this)
    if src == nil do return JS_Null{}
    deep := len(args) >= 1 && truthy(args[0])
    return wrap_element(vm, clone_subtree(vm, src, deep))
}

@(private = "file")
native_create_text_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, len(args) >= 1 ? args[0] : nil)
    node := dom.make_node(.Text)
    node.text = strings.clone(strings.to_string(sb))
    vm.owned_nodes[rawptr(node)] = true
    return wrap_element(vm, node)
}

@(private = "file")
native_true :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return true }

// document.implementation.createHTMLDocument(title): monta um DOCUMENT novo e
// isolado (html > head[ > title] , body) e devolve um wrapper com os essenciais.
// O jQuery/Sizzle faz `document.implementation.createHTMLDocument("").body` na
// feature-detect `support.createHTMLDocument` (e usa como contexto seguro de
// parseHTML). Sem isto, `.body` de undefined lançava e o init do jQuery abortava
// (go.dev/heroku/techcrunch/espn/discord — próximo elo após o nodeType do M95).
@(private = "file")
native_create_html_document :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    docnode := dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    head := dom.make_node(.Element); head.tag = strings.clone("head"); head.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    if len(args) >= 1 {
        sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
        to_text(&sb, args[0])
        if ttl := strings.to_string(sb); ttl != "" {
            title := dom.make_node(.Element); title.tag = strings.clone("title"); title.attrs = make(map[string]string)
            txt := dom.make_node(.Text); txt.text = strings.clone(ttl)
            dom.append_child(title, txt); dom.append_child(head, title)
        }
    }
    dom.append_child(html, head); dom.append_child(html, body); dom.append_child(docnode, html)
    vm.owned_nodes[rawptr(docnode)] = true // só a RAIZ: free_tree libera a subárvore (evita double-free)

    d := new_object(vm)
    d.host = rawptr(docnode)
    d.props["createElement"]   = mk_dom(vm, native_create_element)
    d.props["createElementNS"] = mk_dom(vm, native_create_element_ns)
    d.props["createTextNode"]  = mk_dom(vm, native_create_text_node)
    d.props["createComment"]   = mk_dom(vm, native_create_comment)
    d.props["createDocumentFragment"] = mk_dom(vm, native_create_document_fragment)
    d.props["importNode"] = mk_dom(vm, native_import_node)
    d.props["adoptNode"]  = mk_dom(vm, native_import_node) // sem multi-documento: mesmo efeito
    d.props["getElementsByTagName"] = mk_dom(vm, native_get_elements_by_tag_name)
    d.props["querySelector"]    = mk_dom(vm, native_query_selector)
    d.props["querySelectorAll"] = mk_dom(vm, native_query_selector_all)
    d.props["createTreeWalker"]   = mk_dom(vm, native_create_tree_walker)
    d.props["createNodeIterator"] = mk_dom(vm, native_create_node_iterator)
    d.props["body"]            = wrap_element(vm, body)
    d.props["head"]            = wrap_element(vm, head)
    d.props["documentElement"] = wrap_element(vm, html)
    d.props["nodeType"]        = f64(9)
    d.props["nodeName"]        = own_str(vm, "#document")
    return d
}

@(private = "file")
native_create_comment :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, len(args) >= 1 ? args[0] : nil)
    node := dom.make_node(.Comment)
    node.text = strings.clone(strings.to_string(sb))
    vm.owned_nodes[rawptr(node)] = true
    return wrap_element(vm, node)
}

// DocumentFragment: contêiner leve p/ montar uma subárvore fora do DOM e inseri-la
// de uma vez (padrão comum de frameworks p/ batch de inserções). Não há kind
// próprio no dom.Node — representamos como Element de tag sentinela FRAG_TAG.
// A semântica-chave (spec): ao inserir o fragmento num pai, os FILHOS dele é que
// migram (o nó-fragmento nunca entra na árvore); ver move_fragment_children, usado
// por appendChild/insertBefore/append. nodeType/nodeName tratam FRAG_TAG à parte.
FRAG_TAG :: "#document-fragment"

is_fragment :: proc(n: ^dom.Node) -> bool {
    // "#content" (o conteúdo de um <template>) TAMBÉM é um DocumentFragment: inserir
    // um fragmento move os FILHOS dele, não o nó. Sem isto, `appendChild(
    // importNode(tpl.content, true))` — o que todo lit-html faz p/ instanciar um
    // template — enfiava o próprio nó #content na árvore, e o layout (que pula
    // pseudo-nós) não renderizava nada.
    return n != nil && n.kind == .Element && (n.tag == FRAG_TAG || n.tag == "#content")
}

@(private = "file")
native_create_document_fragment :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := dom.make_node(.Element)
    node.tag = strings.clone(FRAG_TAG)
    node.attrs = make(map[string]string)
    vm.owned_nodes[rawptr(node)] = true
    return wrap_element(vm, node)
}

// Move os FILHOS de `frag` para `parent` a partir do índice `at` (at<0 = fim),
// esvaziando o fragmento. Snapshot antes (detach muta frag.children durante o laço).
@(private = "file")
move_fragment_children :: proc(vm: ^Interp, parent, frag: ^dom.Node, at: int) {
    kids := make([dynamic]^dom.Node, 0, len(frag.children), context.temp_allocator)
    for c in frag.children do append(&kids, c)
    idx := at
    for k in kids {
        if would_create_cycle(parent, k) do continue
        detach(vm, k)
        mo_insert(vm, parent, k, idx)
        if idx >= 0 do idx += 1
    }
}

// ── funil de mutação de FILHOS (MutationObserver, M201) ─────────────────────
// `detach` e `mo_insert` são os DOIS pontos por onde a lista de filhos muda em
// js/. Ambos recebem o `vm` de propósito: é o que faz o compilador apontar todo
// call-site novo que esqueça de notificar o observador. Ao acrescentar uma
// operação de árvore, ROTEIE por aqui — mexer em `parent.children` na mão volta
// a ser uma mutação invisível. Ver mutation_observer.odin.
//
// Custo com zero observadores: um `len(vm.mut_observers)` por chamada.

// Desanexa um nó do pai atual (remove da lista de filhos).
@(private = "file")
// Uma varredura só: acha o índice, tira os irmãos DALI e remove. Procurar os
// irmãos num segundo laço faria `for(i<20k) parent.removeChild(...)` virar
// quadrático assim que houvesse um observador ligado.
detach :: proc(vm: ^Interp, child: ^dom.Node) {
    p := child.parent
    if p == nil do return
    at := -1
    for c, i in p.children do if c == child { at = i; break }
    if at < 0 { child.parent = nil; return } // .parent mentia: nada a remover
    if mo_active(vm) {
        prev, next: ^dom.Node
        if at > 0                  do prev = p.children[at - 1]
        if at + 1 < len(p.children) do next = p.children[at + 1]
        mo_record_children(vm, p, nil, {child}, prev, next) // ANTES de sair da árvore
    }
    dom.kids_remove_at(p, at)
    child.parent = nil
}

// Insere `child` em `parent` no índice `idx` (idx < 0 ou além do fim = append).
// A posição final é conhecida, então os irmãos saem sem varrer a lista (o mesmo
// motivo do detach: `for(i<20k) parent.appendChild(...)` observado seria O(n²)).
@(private = "file")
mo_insert :: proc(vm: ^Interp, parent, child: ^dom.Node, idx := -1) {
    at: int
    if idx < 0 || idx >= len(parent.children) {
        dom.append_child(parent, child) // seta child.parent
        at = len(parent.children) - 1
    } else {
        child.parent = parent
        dom.kids_insert(parent, idx, child)
        at = idx
    }
    if mo_active(vm) {
        prev, next: ^dom.Node
        if at > 0                       do prev = parent.children[at - 1]
        if at + 1 < len(parent.children) do next = parent.children[at + 1]
        mo_record_children(vm, parent, {child}, nil, prev, next)
    }
    // CUSTOM ELEMENTS: o nó que ENTRA na árvore é promovido aqui. Antes o único
    // caminho automático era o `customElements.define`, que varre o documento UMA
    // vez — então tudo que aparecia DEPOIS do define (innerHTML, appendChild, o
    // elemento vindo de createElement) nunca era promovido, e nenhum
    // connectedCallback chegava. É o funil certo pelo mesmo motivo do M201: toda
    // inserção do motor passa por mo_insert.
    // ⚠️ só se o destino estiver LIGADO ao documento — a spec conecta por
    // "shadow-including connected", e disparar connectedCallback dentro de uma
    // subárvore solta é o erro que o custom element não tem como desfazer.
    if vm.custom_elements != nil && len(vm.custom_elements) > 0 && node_is_connected(vm, parent) {
        maybe_upgrade_element(vm, child)
    }
}

// O nó está pendurado no documento? (sobe pelos pais até a raiz registrada)
@(private = "file")
node_is_connected :: proc(vm: ^Interp, n: ^dom.Node) -> bool {
    if vm.document_node == nil do return false
    for cur := n; cur != nil; cur = cur.parent {
        if rawptr(cur) == vm.document_node do return true
    }
    return false
}

// Um nó não pode ser inserido dentro de si mesmo nem de um descendente seu — o
// DOM real lança HierarchyRequestError. Sem esta checagem, um appendChild/
// insertBefore degenerado (visto no bundle real do Facebook) cria um CICLO na
// árvore: o layout depois recursiona nele até estourar a stack e fechar o
// navegador. Recusamos silenciosamente (devolvendo o filho, como no-op).
@(private = "file")
would_create_cycle :: proc(parent, child: ^dom.Node) -> bool {
    for n := parent; n != nil; n = n.parent do if n == child do return true // child == parent ou ancestral
    return false
}

@(private = "file")
native_append_child :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil || len(args) < 1 do return nil
    child_o, ok := args[0].(^Object)
    if !ok || child_o.host == nil do return nil
    child := cast(^dom.Node) child_o.host
    if is_fragment(child) { move_fragment_children(vm, parent, child, -1); return args[0] } // migra os filhos
    if would_create_cycle(parent, child) do return args[0] // no-op: evita ciclo na árvore
    when #config(DOMPROBE, false) {
        // O nó que o JS está inserindo JÁ foi liberado? (wrapper sobrevivente)
        if _, morto := dom.g_free_log[rawptr(child)]; morto {
            dom.g_zumbi_insert += 1
            dom.g_zumbi_parent = rawptr(parent)
            dom.g_zumbi_child  = rawptr(child)
        }
    }
    if child.parent != nil do detach(vm, child) // move: tira do pai antigo
    mo_insert(vm, parent, child)                // append; seta child.parent = parent
    maybe_run_injected_script(vm, child)    // <script src> dinâmico: busca+executa (chunk webpack)
    return args[0]                          // DOM devolve o filho anexado
}

MAX_DYN_SCRIPTS :: 100 // teto de <script> injetados executados por página (anti-runaway)

// Executa um <script> injetado via createElement('script')+appendChild — o mecanismo
// de carregamento de chunk do webpack/Next (`__webpack_require__.l`: cria o script,
// seta .src e .onload, e faz head.appendChild). Sem isto, os módulos dos chunks
// assíncronos nunca se registravam e `modules[id].call(...)` estourava com "reading
// 'call' of undefined" (gap #1 do gap-miner: codepen/soundcloud/figma/slack/aliexpress/uol).
// Busca BLOQUEANTE (mesma filosofia do await): garante o chunk disponível ao voltar
// do appendChild, então o `.then(()=>require(id))` do webpack acha o módulo. Dispara
// 'load' no fim (webpack resolve a Promise do chunk lá, seguindo p/ o require).
// <script type="module"> (o type é o único sinal; o resto do pipeline já trata
// module vs clássico assim).
@(private = "file")
is_module_script :: proc(node: ^dom.Node) -> bool {
    if node.attrs == nil do return false
    return strings.trim_space(node.attrs["type"]) == "module"
}

@(private = "file")
maybe_run_injected_script :: proc(vm: ^Interp, node: ^dom.Node) {
    if node == nil || node.kind != .Element || node.tag != "script" do return
    if node.attrs != nil { if _, done := node.attrs["__executed"]; done do return } // 1x só
    src := ""
    if node.attrs != nil do src = node.attrs["src"]
    has_src := strings.trim_space(src) != ""

    // inline injetado (createElement('script'); s.textContent=code; appendChild):
    // executa o texto direto (sem rede). Scripts vindos de innerHTML NÃO passam aqui
    // (só appendChild/insertBefore/append), então mantêm o comportamento de não-exec.
    inline := ""
    if !has_src {
        sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
        dom.text_content(node, &sb)
        inline = strings.clone(strings.to_string(sb), context.temp_allocator)
        if strings.trim_space(inline) == "" do return // <script> vazio: nada a fazer
    }

    set_attr_str(vm, node, "__executed", "1") // marca ANTES (evita reentrância/loop se re-anexar)
    if vm.dyn_scripts_run >= MAX_DYN_SCRIPTS { fire_script_load(vm, node, false); return }
    vm.dyn_scripts_run += 1

    // document.currentScript = este <script> durante a execução (Turbopack/webpack
    // leem p/ derivar o caminho-base do chunk). Restaura antes do load/error.
    saved_cs := vm.current_script
    vm.current_script = rawptr(node)

    ok := false
    if has_src {
        url := src
        if vm.base_url != "" do url = net.resolve_url(vm.base_url, src, context.temp_allocator)
        resp := net.fetch(url) // BLOQUEANTE (mesma filosofia do await): chunk pronto ao voltar
        defer if len(resp.body) > 0 do delete(resp.body)
        defer if resp.err != "" do delete(resp.err)
        ok = resp.ok && len(resp.body) > 0
        // O chunk veio como HTML (fallback de SPA/404 devolvendo o index.html com
        // 200) — é o caso DOMINANTE do corpus: os loaders de chunk do webpack pedem
        // assets que não existem e o servidor responde a página. Rodar isso como JS
        // gerava milhares de recuperações de parse ("<!DOCTYPE html" em posição de
        // expressão: techcrunch 9129, wordpress 2124) e sujava o vm. Conta como
        // FALHA do script (onerror), que é o que um navegador real faz por MIME.
        if ok && response_is_not_js(resp.status, resp.content_type, string(resp.body)) {
            ok = false
        } else if ok {
            run_injected_source(vm, string(resp.body), is_module_script(node) ? url : "")
        }
    } else {
        // inline: mesmo sendo módulo, a URL dele É a da página (spec)
        run_injected_source(vm, inline, "")
        ok = true
    }
    vm.current_script = saved_cs // restaura ANTES do load/error (handlers veem currentScript anterior)
    when #config(MEMBERPROBE, false) {
        // qual chunk dinâmico entrou, e se entrou. `ok=false` aqui vira `onerror` no
        // webpack, que costuma rejeitar a Promise do chunk EM SILÊNCIO — e o módulo
        // simplesmente nunca aparece no registro.
        fmt.eprintfln("[dynscript] ok=%v n=%d src=%s", ok, vm.dyn_scripts_run, src)
    }
    fire_script_load(vm, node, ok) // dispara onload/onerror (resolve a Promise do chunk no webpack)
}

// A resposta de um script é HTML em vez de JavaScript? (asset inexistente servido
// como index.html com 200, ou página de erro). Content-Type E sniff do corpo, pois
// nesse caminho de fallback o MIME costuma vir errado. NÃO basta olhar o primeiro
// '<': script legado pode começar com o hack `<!--`, que é JS válido aqui — só
// `<!doctype` e `<html` são conclusivos. (Gêmeo do response_is_html de browser_ui;
// duplicado porque `js` não pode importar `ui` — a dependência é ui→js.)
// `strict_mime`: só p/ MÓDULOS. A spec HTML exige MIME de JavaScript em módulos
// (falha o import se não for), mas é TOLERANTE com script clássico — e servidores
// mandam .js com Content-Type errado com frequência. Rejeitar clássico por MIME
// quebraria sites cujo corpo é JS legítimo; por isso lá só fazemos sniff do corpo.
@(private = "file")
response_is_not_js :: proc(status: int, content_type: string, body: string, strict_mime := false) -> bool {
    // 1) status HTTP fora de 2xx: navegador dispara `error` no <script> e NÃO
    //    executa o corpo — o corpo de um 402/404/500 é página de erro ou JSON de
    //    API, nunca script. O slack.com tem um `<script src>` do clearbit que
    //    responde **402 + application/json** ("over_quota") e nós PARSEÁVAMOS
    //    aquilo como JS: era o que sobrava dele no ranking de recuperações.
    //    (`status == 0` = resposta sintética/data:, não julga.)
    if status != 0 && (status < 200 || status > 299) do return true
    lo_ct := strings.to_lower(content_type, context.temp_allocator)
    // 2) Content-Type JSON: resposta de API no lugar do script. Vale mesmo em 200,
    //    e é seguro para script clássico — corpo JSON nunca é JS executável.
    if strings.contains(lo_ct, "application/json") || strings.contains(lo_ct, "+json") do return true
    if strict_mime && strings.contains(lo_ct, "text/html") do return true
    head := strings.trim_left_space(body)
    if len(head) > 64 do head = head[:64]
    lo := strings.to_lower(head, context.temp_allocator)
    return strings.has_prefix(lo, "<!doctype") || strings.has_prefix(lo, "<html")
}

// Executa a fonte de um script injetado, preservando o guard de recursão externo
// (vm_exec zera call_depth; sem restaurar, os `defer call_depth-=1` das chamadas
// externas em curso ficariam negativos — enfraquece o guard até reequilibrar).
// `module_url` != "" quando o <script> injetado é type="module" com src: aí ele
// roda como MÓDULO e com a URL dele (M137). Antes ia sempre por vm_run, então o
// chunk perdia a própria URL e todo `import()` relativo dentro dele resolvia contra
// a PÁGINA — `../nodes/0.js` virava /nodes/0.js (crates.io, SvelteKit).
@(private = "file")
run_injected_source :: proc(vm: ^Interp, source: string, module_url := "") {
    saved_depth := vm.call_depth
    saved_short := vm.opt_short // mesmo isolamento de fronteira do M109: um script
    vm.opt_short = false        // terminando em `w?.h` não pode pular a cadeia externa
    if module_url != "" {
        vm_run_module(vm, source, module_url)
        vm_clear_uncaught(vm)
    } else do vm_run(vm, source) // clona a fonte + loga/limpa exceção (não envenena o vm)
    vm.call_depth = saved_depth
    vm.opt_short = saved_short
}

// Dispara o evento load (ok) ou error (!ok) num <script> — os handlers foram
// registrados por `script.onload=` / addEventListener antes do appendChild.
@(private = "file")
fire_script_load :: proc(vm: ^Interp, node: ^dom.Node, ok: bool) {
    dispatch_event(vm, node, ok ? "load" : "error")
}

// parent.insertBefore(novo, ref): insere `novo` antes de `ref` (ou append se ref=null).
// É a primitiva de inserção do React — sem ela, nada é montado.
@(private = "file")
native_insert_before :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil || len(args) < 1 do return nil
    child_o, ok := args[0].(^Object)
    if !ok || child_o.host == nil do return nil
    child := cast(^dom.Node) child_o.host
    ref: ^dom.Node
    if len(args) >= 2 { if ro, rok := args[1].(^Object); rok && ro.host != nil do ref = cast(^dom.Node) ro.host }
    if is_fragment(child) { // migra os filhos: antes de `ref` (ou no fim se ref=nil)
        at := -1
        if ref != nil do for c, i in parent.children do if c == ref { at = i; break }
        move_fragment_children(vm, parent, child, at)
        return args[0]
    }
    if would_create_cycle(parent, child) do return args[0] // no-op: evita ciclo na árvore
    if child.parent != nil do detach(vm, child)
    idx := -1
    if ref != nil do for c, i in parent.children do if c == ref { idx = i; break }
    mo_insert(vm, parent, child, idx) // idx<0 (sem ref, ou ref não é filho) = append, como o DOM tolera
    maybe_run_injected_script(vm, child) // <script src> dinâmico (chunk webpack)
    return args[0]
}

// parent.replaceChild(newChild, oldChild): troca oldChild por newChild na mesma
// posição; devolve oldChild. No-op se oldChild não é filho ou criaria ciclo.
@(private = "file")
native_replace_child :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil || len(args) < 2 do return JS_Null{}
    new_o, nok := args[0].(^Object)
    old_o, ook := args[1].(^Object)
    if !nok || !ook || new_o.host == nil || old_o.host == nil do return JS_Null{}
    newc := cast(^dom.Node) new_o.host
    oldc := cast(^dom.Node) old_o.host
    // oldChild precisa ser filho
    found := false
    for c in parent.children do if c == oldc { found = true; break }
    if !found do return JS_Null{}
    if would_create_cycle(parent, newc) do return args[1] // no-op seguro
    if newc.parent != nil do detach(vm, newc)
    // reencontra o índice (detach pode ter deslocado se newc era do mesmo parent)
    idx := -1
    for c, i in parent.children do if c == oldc { idx = i; break }
    if idx < 0 do return JS_Null{}
    mo_insert(vm, parent, newc, idx)        // newc no índice; oldc empurrado p/ idx+1
    detach(vm, oldc)                        // remove oldc (agora órfão; devolvido ao caller)
    // órfão RASTREADO, como em removeChild/remove/replaceWith: sem isto o nó
    // trocado (que veio da árvore da página, não do JS) não é alcançado nem pelo
    // free_tree da página nem pelo free_orphan_nodes — vazava a subárvore inteira.
    vm.owned_nodes[rawptr(oldc)] = true
    maybe_run_injected_script(vm, newc)     // <script> inserido ao vivo executa
    return args[1]
}

// Insere `child` na posição adjacente a `ref` (beforebegin/afterbegin/beforeend/
// afterend). Devolve true se inseriu. Compartilhado por insertAdjacentElement/Text/HTML.
@(private = "file")
insert_adjacent_node :: proc(vm: ^Interp, ref, child: ^dom.Node, pos: string) -> bool {
    tp: ^dom.Node // parent-alvo
    switch pos {
    case "afterbegin", "beforeend": tp = ref
    case "beforebegin", "afterend":
        tp = ref.parent
        if tp == nil do return false
    case: return false
    }
    if would_create_cycle(tp, child) do return true // no-op seguro
    if child.parent != nil do detach(vm, child)
    idx := len(tp.children)
    switch pos {
    case "afterbegin": idx = 0
    case "beforeend":  idx = len(tp.children)
    case "beforebegin": for c, i in tp.children do if c == ref { idx = i;     break }
    case "afterend":    for c, i in tp.children do if c == ref { idx = i + 1; break }
    }
    mo_insert(vm, tp, child, idx)
    return true
}

@(private = "file")
native_insert_adjacent_element :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 2 do return JS_Null{}
    pos, pok := args[0].(string)
    child_o, cok := args[1].(^Object)
    if !pok || !cok || child_o.host == nil do return JS_Null{}
    child := cast(^dom.Node) child_o.host
    if insert_adjacent_node(vm, node, child, strings.to_lower(pos, context.temp_allocator)) {
        maybe_run_injected_script(vm, child)
        return args[1]
    }
    return JS_Null{}
}

@(private = "file")
native_insert_adjacent_text :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 2 do return nil
    pos, pok := args[0].(string)
    if !pok do return nil
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    to_text(&sb, args[1])
    tn := dom.make_node(.Text); tn.text = strings.clone(strings.to_string(sb))
    vm.owned_nodes[rawptr(tn)] = true
    insert_adjacent_node(vm, node, tn, strings.to_lower(pos, context.temp_allocator))
    return nil
}

// ── document.write / writeln ────────────────────────────────────────────────
//
// ⚠️ QUAL semântica é possível aqui, e por quê. No navegador real o `write`
// injeta no PONTO DE INSERÇÃO do parser, porque o script roda NO MEIO do parse.
// Aqui não roda: `load_page_scripts` (src/ui/browser_ui.odin) COLETA todos os
// <script> numa lista e só então executa — quando o 1º script roda, o documento
// já está inteiro parseado. O equivalente honesto é inserir logo DEPOIS do
// <script> que está executando (`vm.current_script`), que é exatamente onde o
// ponto de inserção estaria no parse real.
//
// Degradações ANOTADAS (nenhuma é silenciosa):
//   - Fora de um <script> (timer, handler de evento, callback) não existe ponto
//     de inserção. A spec manda um `document.open()` implícito, que APAGA o
//     documento inteiro; aqui IGNORAMOS e logamos. Apagar a página é pior e mais
//     difícil de acertar do que não escrever — e um `write` de script de anúncio
//     atrasado passaria a zerar a página.
//   - Cada chamada é um FRAGMENTO próprio: `write('<div>')` + `write('</div>')`
//     NÃO se juntam (o navegador mantém o tokenizador aberto entre chamadas).
//     O idioma legado comum manda a tag inteira numa chamada só, que funciona.
//   - `document.open()`/`close()` são no-ops: existem para o idioma
//     `open(); write(...); close()` não lançar, mas `open` não apaga nada — o
//     que é coerente com a decisão acima, não um esquecimento.
//   - ⚠️⚠️ **DEPENDE DO PONTO DE ENTRADA, e isso vai fazer duas ferramentas
//     discordarem.** Só `load_page_scripts` (browser_ui.odin) percorre os
//     <script> UM A UM setando `current_script` — é o caminho da navegação
//     real, do `--render` e do `--dumplayout` de URL. O `load_page` daqui
//     CONCATENA todos os scripts num blob só e nunca seta `current_script`,
//     então sob ele (`--dumplayout` de ARQUIVO LOCAL, e 2 testes de ui) todo
//     write cai no ramo "ignorado" acima. Não foi alinhado de propósito: dar um
//     `current_script` ao blob seria INVENTAR uma posição para os scripts 2..N.
//     ⇒ para medir document.write, use URL (servidor local), não arquivo.
//
// ✅ <script> escrito assim EXECUTA — ao contrário do innerHTML, e é o que a
// spec manda. Reusa `maybe_run_injected_script` inteiro (fetch de src, dedupe
// por `__executed`, teto MAX_DYN_SCRIPTS, eventos load/error).
@(private = "file")
run_written_scripts :: proc(vm: ^Interp, n: ^dom.Node) {
    if n == nil do return
    if n.kind == .Element && n.tag == "script" do maybe_run_injected_script(vm, n)
    for c in n.children do run_written_scripts(vm, c)
}

@(private = "file")
doc_write_impl :: proc(vm: ^Interp, args: []Value, newline: bool) -> Value {
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    for a in args do to_text(&sb, a)
    if newline do strings.write_byte(&sb, '\n')
    html := strings.to_string(sb)
    if strings.trim_space(html) == "" do return nil

    if vm.current_script == nil {
        fmt.eprintfln("[js] document.write fora de <script> ignorado (%d bytes; a spec apagaria o documento)", len(html))
        return nil
    }
    if vm.write_owner != vm.current_script { // 1º write DESTE script: ancora nele
        vm.write_owner  = vm.current_script
        vm.write_anchor = vm.current_script
    }
    anchor := (^dom.Node)(vm.write_anchor)
    if anchor == nil || anchor.parent == nil do return nil // <script> solto: sem onde inserir

    frag := parse_html_fragment(anchor.parent, html)
    kids := make([dynamic]^dom.Node, context.temp_allocator)
    for c in frag.children do append(&kids, c)
    dom.kids_clear(frag) // os filhos passam a ser do documento
    prev := anchor
    for c in kids {
        insert_adjacent_node(vm, prev, c, "afterend")
        prev = c
    }
    vm.write_anchor = rawptr(prev) // o próximo write continua DAQUI
    when #config(DOMPROBE, false) { dom.g_free_tag = "document.write-frag" }
    dom.free_tree(frag)

    // ⚠️ os scripts escritos podem chamar document.write eles mesmos e mexem em
    // write_owner/write_anchor; salvar e restaurar mantém a cadeia do script de
    // FORA correta quando ele escrever de novo.
    saved_owner, saved_anchor := vm.write_owner, vm.write_anchor
    for c in kids do run_written_scripts(vm, c)
    vm.write_owner, vm.write_anchor = saved_owner, saved_anchor
    return nil
}

@(private = "file")
native_doc_write :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return doc_write_impl(vm, args, false)
}
@(private = "file")
native_doc_writeln :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return doc_write_impl(vm, args, true)
}

// Parseia `html` como FRAGMENTO no contexto do elemento `ctx` — é o que faz
// `td.innerHTML='<tr>'` diferir de `div.innerHTML='<tr>'` e `svg.innerHTML=...`
// entrar em namespace SVG. Antes usávamos `htmlp.parse` (documento), que não
// tinha esse comportamento. Devolve um Document cujos filhos são o fragmento.
// ctx nil / não-Element → contexto vazio (cai em "in body", como um <div>).
@(private = "file")
parse_html_fragment :: proc(ctx: ^dom.Node, html: string) -> ^dom.Node {
    tag, ns := "div", ""
    if ctx != nil && ctx.kind == .Element {
        tag, ns = ctx.tag, ctx.ns
    }
    return htmlp.parse_fragment(html, tag, ns)
}

// el.insertAdjacentHTML(pos, html): parseia o fragmento (parser HTML real) e insere
// os nós na posição. Como innerHTML, <script> inserido NÃO executa.
@(private = "file")
native_insert_adjacent_html :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 2 do return nil
    pos, pok := args[0].(string)
    if !pok do return nil
    lo := strings.to_lower(pos, context.temp_allocator)
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    to_text(&sb, args[1])
    // contexto do fragmento depende da posição: beforebegin/afterend inserem
    // como IRMÃOS de `node`, então o contexto é o PAI; afterbegin/beforeend
    // inserem DENTRO, contexto é o próprio `node`. (HTML5, insertAdjacentHTML.)
    ctx := node
    if lo == "beforebegin" || lo == "afterend" {
        if node.parent != nil && node.parent.kind == .Element do ctx = node.parent
    }
    frag := parse_html_fragment(ctx, strings.to_string(sb))
    kids := make([dynamic]^dom.Node, context.temp_allocator)
    for c in frag.children do append(&kids, c)
    dom.kids_clear(frag) // os filhos passam a ser do node (re-ancorados abaixo)
    // 1º filho na posição pedida; os demais encadeados via "afterend" p/ manter a ordem.
    prev: ^dom.Node = nil
    for c in kids {
        if prev == nil do insert_adjacent_node(vm, node, c, lo)
        else           do insert_adjacent_node(vm, prev, c, "afterend")
        prev = c
    }
    when #config(DOMPROBE,false) { dom.g_free_tag = "insertAdjacentHTML-frag" }
    dom.free_tree(frag)
    return nil
}

// Remove um atributo liberando a CHAVE e o VALOR dom-owned (captura antes de
// mutar o mapa p/ não invalidar o iterador). No-op se ausente.
// Par de set_attr_str: mesmo funil, mesma razão para receber o `vm`.
@(private = "file")
remove_attr_owned :: proc(vm: ^Interp, node: ^dom.Node, name: string) {
    if mo_active(vm) {
        old, had := node.attrs[name]
        if had do mo_record_attr(vm, node, name, old, true) // remoção também é "attributes"
    }
    dom.del_attr(node, name) // tira do map E da ordem
}

@(private = "file")
native_remove_attribute :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return nil
    name, ok := args[0].(string)
    if !ok do return nil
    remove_attr_owned(vm, node, name)
    return nil
}

// el.hasAttribute(name) → bool. Cobre atributos do parse E os postos via setAttribute.
@(private = "file")
native_has_attribute :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    name, ok := arg(args, 0).(string)
    if node == nil || !ok || node.attrs == nil do return false
    _, has := node.attrs[name]
    return has
}

// el.toggleAttribute(name[, force]): alterna a PRESENÇA de um atributo booleano
// (valor ""). Com `force`: true garante presente, false garante ausente. Devolve
// o estado final (presente?).
@(private = "file")
native_toggle_attribute :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    name, ok := arg(args, 0).(string)
    if node == nil || !ok do return false
    has := false
    if node.attrs != nil do _, has = node.attrs[name]
    if len(args) >= 2 { // force explícito
        if truthy(args[1]) {
            if !has do set_attr_str(vm, node, name, "")
            return true
        }
        remove_attr_owned(vm, node, name)
        return false
    }
    if has { remove_attr_owned(vm, node, name); return false }
    set_attr_str(vm, node, name, "")
    return true
}

// Testa se `node` casa o seletor CSS, reusando o matcher do pacote ui (só faz
// match de DESCENDENTES de um escopo): consultamos o PAI e vemos se `node` está
// no resultado. Sem pai (raiz) não há como testar → false (aproximação aceitável).
@(private = "file")
dom_node_matches :: proc(node: ^dom.Node, sel: string, scope: ^dom.Node = nil) -> bool {
    if node == nil || node.kind != .Element do return false
    if g_dom_matches != nil do return g_dom_matches(node, sel, scope != nil ? scope : node)
    if g_dom_query == nil || node.parent == nil do return false
    tmp: [dynamic]^dom.Node
    defer delete(tmp)
    g_dom_query(node.parent, sel, true, &tmp)
    for c in tmp do if c == node do return true
    return false
}

// el.matches(sel) → bool.
@(private = "file")
native_matches :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    sel, ok := arg(args, 0).(string)
    if node == nil || !ok do return false
    if !selector_check(vm, sel) do return false
    return dom_node_matches(node, sel)
}

// el.closest(sel): 1º ancestral (incluindo o próprio) que casa o seletor, ou null.
@(private = "file")
native_closest :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    sel, ok := arg(args, 0).(string)
    if node == nil || !ok do return JS_Null{}
    if !selector_check(vm, sel) do return JS_Null{}
    for n := node; n != nil; n = n.parent {
        if n.kind == .Element && dom_node_matches(n, sel, node) do return wrap_element(vm, n)
    }
    return JS_Null{}
}

// DOMRect com os 8 campos derivados de x/y/w/h (right = x+w, etc.), como a spec.
// Sem geometria disponível (nó sem caixa, ou nenhum layout ainda) todos são 0 —
// que é o que o navegador devolve p/ elemento `display:none`.
// ⚠️ NÃO é `private="file"`: o intersection_observer.odin monta os três rects de
// cada entry com ESTA proc. Uma 2ª cópia divergiria calada (a lição do M213).
make_dom_rect :: proc(vm: ^Interp, x, y, w, h: f32) -> ^Object {
    r := new_object(vm)
    r.props["x"]      = f64(x)
    r.props["y"]      = f64(y)
    r.props["width"]  = f64(w)
    r.props["height"] = f64(h)
    r.props["top"]    = f64(y)
    r.props["left"]   = f64(x)
    r.props["right"]  = f64(x + w)
    r.props["bottom"] = f64(y + h)
    return r
}

// Geometria do nó pelo hook do ui. Zeros quando não há caixa/layout.
@(private = "file")
node_rect :: proc(node: ^dom.Node) -> (x, y, w, h: f32) {
    if g_element_rect == nil || node == nil do return 0, 0, 0, 0
    rx, ry, rw, rh, ok := g_element_rect(node)
    if !ok do return 0, 0, 0, 0
    return rx, ry, rw, rh
}

@(private = "file")
native_get_bounding_client_rect :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    x, y, w, h := node_rect(node_of(this))
    return make_dom_rect(vm, x, y, w, h)
}

// el.getClientRects(): lista (array-like) de DOMRects. Devolvemos UM retângulo —
// a caixa de borda. ⚠️ degradação nomeada: um inline quebrado em várias linhas tem
// um retângulo POR LINHA no navegador, e nós damos a caixa inteira.
@(private = "file")
native_get_client_rects :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := new_array(vm)
    x, y, w, h := node_rect(node_of(this))
    append(&a.items, make_dom_rect(vm, x, y, w, h))
    return a
}

// el.contains(other) → bool: `other` é o próprio nó ou um descendente dele.
// node.hasChildNodes(): NÃO EXISTIA. Achado pela bissecção do M150 — servir a
// casca de `NodeList` fez o bundle do mercadolivre avançar até a HIDRATAÇÃO do
// React, que chama `ref.current.hasChildNodes()`; o "is not a function" ali
// desmontava a subárvore (−340 caixas). É o padrão de sempre: destapar uma camada
// revela a próxima.
@(private = "file")
native_has_child_nodes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil do return false
    return len(node.children) > 0
}

@(private = "file")
native_contains :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    other_o, ok := arg(args, 0).(^Object)
    if node == nil || !ok || other_o.host == nil do return false
    other := cast(^dom.Node) other_o.host
    for n := other; n != nil; n = n.parent do if n == node do return true
    return false
}

// a.isEqualNode(b): igualdade ESTRUTURAL (tipo, tag, atributos e filhos na mesma
// ordem) — distinta de isSameNode, que compara identidade. O React usa isEqualNode
// na hidratação para conferir o markup do servidor contra o que renderizou.
@(private = "file")
native_is_equal_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    other_o, ok := arg(args, 0).(^Object)
    if !ok || other_o.host == nil do return node == nil
    return nodes_structurally_equal(node, cast(^dom.Node) other_o.host)
}

@(private = "file")
nodes_structurally_equal :: proc(a, b: ^dom.Node) -> bool {
    if a == b do return true
    if a == nil || b == nil do return false
    if a.kind != b.kind || a.tag != b.tag || a.ns != b.ns do return false
    if a.kind != .Element { // Text/Comment: compara o conteúdo
        if a.text != b.text do return false
    } else {
        if len(a.attrs) != len(b.attrs) do return false
        for k, v in a.attrs {
            bv, has := b.attrs[k]
            if !has || bv != v do return false
        }
    }
    if len(a.children) != len(b.children) do return false
    for ch, i in a.children {
        if !nodes_structurally_equal(ch, b.children[i]) do return false
    }
    return true
}

// a.isSameNode(b): identidade (o mesmo nó). Trivial, mas parte da mesma família.
@(private = "file")
native_is_same_node :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    other_o, ok := arg(args, 0).(^Object)
    if !ok || other_o.host == nil do return node == nil
    return node == cast(^dom.Node) other_o.host
}

// el.hasAttributes() / el.getAttributeNames(): o lit-html percorre o template com
// um TreeWalker e, em cada elemento, faz `node.hasAttributes()` e depois
// `node.getAttributeNames()` p/ descobrir os bindings. Sem os dois, o commit do
// template morria e o componente renderizava só o marcador de comentário.
@(private = "file")
native_has_attributes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    return node != nil && len(node.attrs) > 0
}

@(private = "file")
native_get_attribute_names :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    arr := new_array(vm)
    node := node_of(this)
    if node == nil do return arr
    names := make([dynamic]string, context.temp_allocator)
    dom.attr_names(node, &names) // ORDEM DE DOCUMENTO (spec)
    for k in names do append(&arr.items, own_str(vm, k))
    return arr
}

// el.remove(): desanexa do pai (ChildNode.remove). Vira órfão → o vm o libera.
@(private = "file")
native_remove_self :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil do return nil
    if node.parent != nil {
        detach(vm, node)
        vm.owned_nodes[rawptr(node)] = true
    }
    return nil
}

// Converte um argumento de append/prepend/before/... num ^dom.Node: wrapper de
// elemento → o nó; qualquer outra coisa (string, número, ...) → nó de TEXTO.
@(private = "file")
arg_to_node :: proc(vm: ^Interp, v: Value) -> ^dom.Node {
    if o, ok := v.(^Object); ok && o.host != nil {
        return cast(^dom.Node) o.host
    }
    // não-nó: vira texto (spec: DOMString). null/undefined → "null"/"undefined".
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    to_text(&sb, v)
    t := dom.make_node(.Text)
    t.text = strings.clone(strings.to_string(sb))
    vm.owned_nodes[rawptr(t)] = true
    return t
}

// Anexa `child` a `parent` (move do pai antigo, evita ciclo). Compartilhado.
@(private = "file")
dom_attach :: proc(vm: ^Interp, parent, child: ^dom.Node) {
    if is_fragment(child) { move_fragment_children(vm, parent, child, -1); return }
    if would_create_cycle(parent, child) do return
    if child.parent != nil do detach(vm, child)
    mo_insert(vm, parent, child)
}

// el.append(...nodes|strings): anexa cada um ao FIM (ParentNode.append).
@(private = "file")
native_append :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil do return nil
    for a in args {
        child := arg_to_node(vm, a)
        dom_attach(vm, parent, child)
        maybe_run_injected_script(vm, child) // <script src> dinâmico (chunk webpack)
    }
    return nil
}

// el.prepend(...): insere no INÍCIO, preservando a ordem dos argumentos.
@(private = "file")
native_prepend :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil do return nil
    idx := 0
    for a in args {
        child := arg_to_node(vm, a)
        if would_create_cycle(parent, child) do continue
        if child.parent != nil do detach(vm, child)
        mo_insert(vm, parent, child, idx)
        idx += 1
    }
    return nil
}

// Insere os args no `parent` a partir do índice `at` (usado por before/after).
@(private = "file")
insert_nodes_at :: proc(vm: ^Interp, parent: ^dom.Node, at: int, args: []Value) {
    idx := at
    for a in args {
        child := arg_to_node(vm, a)
        if would_create_cycle(parent, child) do continue
        if child.parent != nil do detach(vm, child)
        mo_insert(vm, parent, child, idx) // idx além do fim = append
        idx += 1
    }
}

// Índice de `node` entre os filhos do pai, ou -1.
@(private = "file")
child_index :: proc(node: ^dom.Node) -> int {
    if node.parent == nil do return -1
    for c, i in node.parent.children do if c == node do return i
    return -1
}

// el.before(...): insere ANTES de `el` no pai (ChildNode.before).
@(private = "file")
native_before :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || node.parent == nil do return nil
    i := child_index(node)
    if i >= 0 do insert_nodes_at(vm, node.parent, i, args)
    return nil
}

// el.after(...): insere DEPOIS de `el` no pai (ChildNode.after).
@(private = "file")
native_after :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || node.parent == nil do return nil
    i := child_index(node)
    if i >= 0 do insert_nodes_at(vm, node.parent, i + 1, args)
    return nil
}

// el.replaceWith(...): substitui `el` pelos args no pai (ChildNode.replaceWith).
@(private = "file")
native_replace_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || node.parent == nil do return nil
    parent := node.parent
    i := child_index(node)
    if i < 0 do return nil
    detach(vm, node)
    vm.owned_nodes[rawptr(node)] = true
    insert_nodes_at(vm, parent, i, args)
    return nil
}

// el.replaceChildren(...): remove TODOS os filhos e anexa os args (ParentNode).
@(private = "file")
native_replace_children :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil do return nil
    for len(parent.children) > 0 {
        c := parent.children[len(parent.children) - 1]
        detach(vm, c)
        vm.owned_nodes[rawptr(c)] = true
    }
    for a in args do dom_attach(vm, parent, arg_to_node(vm, a))
    return nil
}

// getComputedStyle(el[, pseudo]): CSSStyleDeclaration ligada ao estilo REAL do
// motor pelo hook `g_computed_style` (ver o contrato lá em cima). O objeto guarda
// o nó em `o.host`, e tanto o acesso por propriedade (`cs.display`) quanto
// `getPropertyValue('display')` desembocam na mesma função.
//
// `pseudo` (arg 1) é IGNORADO: o ::before/::after tem Computed próprio no ui, mas
// o mapa é indexado por NÓ e o pseudo não tem nó — devolvemos o estilo do
// elemento em vez de "". É over-claim consciente e restrito (quem lê pseudo quer
// `content`, que não mapeamos e sai "").
//
// setProperty/removeProperty seguem no-op: no navegador a declaração devolvida por
// getComputedStyle é READ-ONLY (escrever lança NoModificationAllowedError), então
// no-op está mais perto do certo do que aceitar a escrita.
@(private = "file")
native_get_computed_style :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.get = computed_style_get
    if len(args) > 0 {
        if el, ok := args[0].(^Object); ok do o.host = el.host // ^dom.Node do elemento
    }
    o.props["getPropertyValue"]    = mk_dom(vm, native_computed_get_property_value)
    o.props["getPropertyPriority"] = mk_dom(vm, native_empty_str_ret)
    o.props["setProperty"]         = mk_dom(vm, dom_noop)
    o.props["removeProperty"]      = mk_dom(vm, native_empty_str_ret)
    o.props["length"]              = f64(0)
    return o
}

// Nome de propriedade como o JS escreve → como o CSS escreve.
// `backgroundColor` → `background-color`; `WebkitTransform`/`webkitTransform` →
// `-webkit-transform`; `cssFloat` → `float` (o alias histórico, porque `float`
// era palavra reservada). Já em kebab-case, só normaliza a caixa.
// Resultado no temp_allocator (vale até o fim da chamada nativa).
@(private = "file")
css_prop_of :: proc(name: string) -> string {
    if name == "cssFloat" || name == "styleFloat" do return "float"
    if strings.contains(name, "-") do return strings.to_lower(name, context.temp_allocator)
    sb: strings.Builder
    strings.builder_init(&sb, context.temp_allocator)
    for i in 0 ..< len(name) {
        ch := name[i]
        if ch >= 'A' && ch <= 'Z' {
            // Maiúscula inicial = prefixo de vendor (WebkitFoo → -webkit-foo); no
            // meio da palavra é só a fronteira de camelCase.
            strings.write_byte(&sb, '-')
            strings.write_byte(&sb, ch + 32)
        } else {
            strings.write_byte(&sb, ch)
        }
    }
    return strings.to_string(sb)
}

// Hook de leitura: métodos e `length` vêm de props; qualquer outra chave é uma
// propriedade CSS e vai ao motor de estilo.
@(private = "file")
computed_style_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if v, ok := o.props[name]; ok do return v, true
    return own_str(vm, computed_value(o, name)), true
}

// getPropertyValue(nome): o nome já vem em kebab-case do chamador, mas passa pela
// mesma normalização (código real também manda camelCase aqui).
@(private = "file")
native_computed_get_property_value :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok || len(args) == 0 do return own_str(vm, "")
    name, nok := args[0].(string)
    if !nok do name = key_string(vm, args[0]) // ToString: código real passa até number
    return own_str(vm, computed_value(o, name))
}

// Funil único: normaliza o nome e consulta o hook do ui.
@(private = "file")
computed_value :: proc(o: ^Object, name: string) -> string {
    if g_computed_style == nil || o.host == nil do return ""
    return g_computed_style((^dom.Node)(o.host), css_prop_of(name))
}

// new XMLHttpRequest(): stub que NÃO faz rede. open/send/setRequestHeader etc.
// são no-op; readyState fica em 0 e o callback nunca dispara. Suficiente p/ que
// bundles de telemetria/legado que instanciam XHR no init não abortem com
// "XMLHttpRequest is not a constructor". (fetch real já existe via window.fetch.)
@(private = "file")
xhr_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.props["open"]                = mk_dom(vm, dom_noop)
    o.props["send"]                = mk_dom(vm, dom_noop)
    o.props["abort"]               = mk_dom(vm, dom_noop)
    o.props["setRequestHeader"]    = mk_dom(vm, dom_noop)
    o.props["getResponseHeader"]   = mk_dom(vm, native_null_ret)
    o.props["getAllResponseHeaders"] = mk_dom(vm, native_empty_str_ret)
    o.props["overrideMimeType"]    = mk_dom(vm, dom_noop)
    o.props["addEventListener"]    = mk_dom(vm, dom_noop)
    o.props["removeEventListener"] = mk_dom(vm, dom_noop)
    o.props["readyState"]   = f64(0)
    o.props["status"]       = f64(0)
    o.props["statusText"]   = own_str(vm, "")
    o.props["responseText"] = own_str(vm, "")
    o.props["response"]     = own_str(vm, "")
    o.props["responseURL"]  = own_str(vm, "")
    o.props["withCredentials"] = false
    o.props["timeout"]      = f64(0)
    return o
}

@(private = "file")
native_null_ret :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return JS_Null{} }

// customElements.whenDefined(name): Promise que resolve quando o custom element
// é definido. Como nunca definimos nenhum, devolvemos uma promise PENDENTE (só
// libera a cadeia async de quem aguarda o upgrade; não afeta a render principal).
@(private = "file")
custom_elements_when_defined :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return promise_new(vm)
}

@(private = "file")
native_empty_str_ret :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return own_str(vm, "") }
native_empty_array_ret :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return new_array(vm) }

// window.matchMedia é REAL desde o M232 — `native_match_media` mora em
// media_query.odin, com o `matches` avaliado pelo MESMO motor do `@media`.

native_bool_false_ret :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return false }

// createElementNS(ns, tag): ignoramos o namespace (SVG etc. são tratados como HTML).
@(private = "file")
native_create_element_ns :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) < 2 do return JS_Null{}
    tag, ok := args[1].(string)
    if !ok do return JS_Null{}
    node := dom.make_node(.Element)
    node.tag = strings.clone(tag)
    node.attrs = make(map[string]string)
    vm.owned_nodes[rawptr(node)] = true
    return wrap_element(vm, node)
}

@(private = "file")
native_remove_child :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    parent := node_of(this)
    if parent == nil || len(args) < 1 do return nil
    child_o, ok := args[0].(^Object)
    if !ok || child_o.host == nil do return nil
    child := cast(^dom.Node) child_o.host
    if child.parent == parent {
        detach(vm, child)
        vm.owned_nodes[rawptr(child)] = true // agora órfão; o vm cuida de liberar
    }
    return args[0]
}

// Libera os nós rastreados que ficaram órfãos (parent==nil). Duas passadas: 1)
// coleta as raízes (todos ainda vivos); 2) free_tree — evita ler .parent de um
// descendente já liberado por um free_tree anterior.
@(private = "file")
free_orphan_nodes :: proc(vm: ^Interp) {
    roots: [dynamic]^dom.Node
    defer delete(roots)
    for p in vm.owned_nodes {
        node := cast(^dom.Node) p
        if node.parent == nil do append(&roots, node)
    }
    when #config(DOMPROBE,false) { dom.g_free_tag = "free_orphan_nodes" }
    for r in roots do dom.free_tree(r)
}

// ── classList / className ───────────────────────────────────────────────────

@(private = "file")
get_class :: proc(node: ^dom.Node) -> string {
    if v, ok := node.attrs["class"]; ok do return v
    return ""
}

@(private = "file")
has_class :: proc(node: ^dom.Node, tok: string) -> bool {
    parts := strings.fields(get_class(node))
    defer delete(parts)
    for p in parts do if p == tok do return true
    return false
}

// Reconstrói o atributo class a partir de tokens (copia para builder ANTES de
// gravar, já que set_attr_str libera a string antiga que os tokens referenciam).
@(private = "file")
rebuild_class :: proc(vm: ^Interp, node: ^dom.Node, tokens: []string) {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    for tok, i in tokens {
        if i > 0 do strings.write_byte(&sb, ' ')
        strings.write_string(&sb, tok)
    }
    set_attr_str(vm, node, "class", strings.to_string(sb))
}

@(private = "file")
classlist_add :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return nil
    tok, ok := args[0].(string)
    if !ok || has_class(node, tok) do return nil
    parts := strings.fields(get_class(node))
    defer delete(parts)
    toks: [dynamic]string
    defer delete(toks)
    for p in parts do append(&toks, p)
    append(&toks, tok)
    rebuild_class(vm, node, toks[:])
    return nil
}

@(private = "file")
classlist_remove :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return nil
    tok, ok := args[0].(string)
    if !ok do return nil
    parts := strings.fields(get_class(node))
    defer delete(parts)
    toks: [dynamic]string
    defer delete(toks)
    for p in parts do if p != tok do append(&toks, p)
    rebuild_class(vm, node, toks[:])
    return nil
}

@(private = "file")
classlist_toggle :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return false
    tok, ok := args[0].(string)
    if !ok do return false
    if has_class(node, tok) {
        classlist_remove(vm, this, args)
        return false
    }
    classlist_add(vm, this, args)
    return true
}

// classList.replace(old, new): troca `old` por `new` mantendo a posição; devolve
// true se `old` existia (e trocou), false senão. Faltava — libs alternam tema via
// `documentElement.classList.replace('light','dark')` (canva e cia.: era o 1º erro
// `classList.replace is not a function`). DOMTokenList é um SET: deduplica.
@(private = "file")
classlist_replace :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 2 do return false
    oldt, ok1 := args[0].(string)
    newt, ok2 := args[1].(string)
    if !ok1 || !ok2 do return false
    if !has_class(node, oldt) do return false // não presente: no-op, false
    parts := strings.fields(get_class(node))
    defer delete(parts)
    toks: [dynamic]string
    defer delete(toks)
    for p in parts {
        repl := newt if p == oldt else p
        dup := false
        for existing in toks do if existing == repl { dup = true; break }
        if !dup do append(&toks, repl)
    }
    rebuild_class(vm, node, toks[:])
    return true
}

@(private = "file")
classlist_contains :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return false
    tok, ok := args[0].(string)
    if !ok do return false
    return has_class(node, tok)
}

@(private = "file")
classlist_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if fn, ok := vm.dom_classlist_methods[name]; ok do return fn, true
    return nil, false
}

// ── el.style e el.dataset (wrappers apoiados em atributos) ───────────────────

// camelCase → kebab-case (backgroundColor → background-color). Propriedades CSS
// custom (--foo) e já-kebab passam intactas (sem maiúsculas).
@(private = "file")
camel_to_kebab :: proc(sb: ^strings.Builder, name: string) {
    for i := 0; i < len(name); i += 1 {
        c := name[i]
        if c >= 'A' && c <= 'Z' {
            strings.write_byte(sb, '-')
            strings.write_byte(sb, c - 'A' + 'a')
        } else {
            strings.write_byte(sb, c)
        }
    }
}

// Anexa "k: v" ao builder, com "; " de separador se já houver conteúdo.
@(private = "file")
append_decl :: proc(sb: ^strings.Builder, k, v: string) {
    if strings.builder_len(sb^) > 0 do strings.write_string(sb, "; ")
    strings.write_string(sb, k)
    strings.write_string(sb, ": ")
    strings.write_string(sb, v)
}

// Valor da propriedade kebab `prop` no atributo style="" (ou "" se ausente).
@(private = "file")
inline_style_get :: proc(node: ^dom.Node, prop: string) -> string {
    decls := csspkg.parse_decls(node.attrs["style"], context.temp_allocator)
    value, _ := csspkg.split_important(decls[style_property_name(prop)])
    return value
}

@(private = "file")
style_property_name :: proc(prop: string) -> string {
    if strings.has_prefix(prop, "--") do return prop
    return strings.to_lower(prop, context.temp_allocator)
}

// Define (val!="") ou remove (val=="") a propriedade kebab `prop` no atributo
// style="", preservando as demais declarações na ordem. Reescreve o atributo.
@(private = "file")
inline_style_set :: proc(vm: ^Interp, node: ^dom.Node, prop: string, val: string) {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    replaced := false
    rest := csspkg.declaration_text(node.attrs["style"])
    for len(rest) > 0 {
        decl: string
        if semi := csspkg.declaration_end(rest); semi < 0 {
            decl = rest; rest = ""
        } else {
            decl = rest[:semi]; rest = rest[semi + 1:]
        }
        colon := strings.index_byte(decl, ':')
        if colon < 0 {
            if len(strings.trim_space(decl)) == 0 do continue // ; extra
            continue // declaração malformada: descarta
        }
        k := style_property_name(strings.trim_space(decl[:colon]))
        if k == prop {
            replaced = true
            if val != "" do append_decl(&sb, prop, val) // val=="" => remove (não reemite)
        } else {
            append_decl(&sb, k, strings.trim_space(decl[colon + 1:]))
        }
    }
    if !replaced && val != "" do append_decl(&sb, prop, val)
    set_attr_str(vm, node, "style", strings.to_string(sb))
}

// el.style.<prop> (get): cssText devolve a string inteira; senão camelCase→kebab
// e lê do atributo style. Prop ausente devolve "" (semântica do DOM).
@(private = "file")
style_prop_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    node := cast(^dom.Node) o.host
    if name == "cssText" do return own_str(vm, node.attrs["style"]), true
    if fn, ok := vm.dom_style_methods[name]; ok do return fn, true
    kb: strings.Builder
    strings.builder_init(&kb)
    defer strings.builder_destroy(&kb)
    camel_to_kebab(&kb, name)
    return own_str(vm, inline_style_get(node, strings.to_string(kb))), true
}

// el.style.<prop> = val (set): cssText grava tudo; senão camelCase→kebab e
// atualiza o atributo style. val vazio/undefined remove a propriedade.
@(private = "file")
style_prop_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    node := cast(^dom.Node) o.host
    if name == "cssText" {
        b := strings.builder_make(context.temp_allocator)
        to_text(&b, val)
        decls := csspkg.parse_decls(strings.to_string(b), context.temp_allocator)
        out := strings.builder_make(context.temp_allocator)
        for k, v in decls do append_decl(&out, k, v)
        set_attr_str(vm, node, "style", strings.to_string(out))
        return true
    }
    kb: strings.Builder
    strings.builder_init(&kb)
    defer strings.builder_destroy(&kb)
    camel_to_kebab(&kb, name)

    vb: strings.Builder
    strings.builder_init(&vb)
    defer strings.builder_destroy(&vb)
    to_text(&vb, val)

    prop := strings.to_string(kb)
    text := strings.trim_space(strings.to_string(vb))
    if text != "" && g_css_value_valid != nil && !g_css_value_valid(prop, text) do return true
    inline_style_set(vm, node, prop, text)
    return true
}

// style.setProperty(prop, val): prop já vem kebab/--custom (não converte).
@(private = "file")
style_set_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return nil
    raw_prop, ok := args[0].(string)
    if !ok do return nil
    prop := style_property_name(raw_prop)
    vb: strings.Builder
    strings.builder_init(&vb)
    defer strings.builder_destroy(&vb)
    to_text(&vb, arg(args, 1))
    text := strings.trim_space(strings.to_string(vb))
    if text != "" && g_css_value_valid != nil && !g_css_value_valid(prop, text) do return nil
    if text != "" && len(args) > 2 {
        priority, _ := args[2].(string)
        if priority != "" {
            if !strings.equal_fold(priority, "important") do return nil
            text = strings.concatenate({text, " !important"}, context.temp_allocator)
        }
    }
    inline_style_set(vm, node, prop, text)
    return nil
}

@(private = "file")
style_get_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return own_str(vm, "")
    prop, ok := args[0].(string)
    if !ok do return own_str(vm, "")
    return own_str(vm, inline_style_get(node, prop))
}

@(private = "file")
style_get_priority :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return own_str(vm, "")
    prop, ok := args[0].(string)
    if !ok do return own_str(vm, "")
    decls := csspkg.parse_decls(node.attrs["style"], context.temp_allocator)
    _, important := csspkg.split_important(decls[style_property_name(prop)])
    return own_str(vm, important ? "important" : "")
}

@(private = "file")
style_remove_property :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil || len(args) < 1 do return nil
    if prop, ok := args[0].(string); ok {
        value := own_str(vm, inline_style_get(node, prop))
        inline_style_set(vm, node, style_property_name(prop), "")
        return value
    }
    return own_str(vm, "")
}

// el.dataset.<name> <-> atributo data-<kebab(name)>. Ausente devolve undefined.
@(private = "file")
data_attr_name :: proc(sb: ^strings.Builder, name: string) {
    strings.write_string(sb, "data-")
    camel_to_kebab(sb, name)
}

@(private = "file")
dataset_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    node := cast(^dom.Node) o.host
    ab: strings.Builder
    strings.builder_init(&ab)
    defer strings.builder_destroy(&ab)
    data_attr_name(&ab, name)
    if v, ok := node.attrs[strings.to_string(ab)]; ok do return own_str(vm, v), true
    return nil, true // undefined (data-attr ausente)
}

@(private = "file")
dataset_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    node := cast(^dom.Node) o.host
    ab: strings.Builder
    strings.builder_init(&ab)
    defer strings.builder_destroy(&ab)
    data_attr_name(&ab, name)
    set_attr_val(vm, node, strings.to_string(ab), val)
    return true
}

// ── hooks de propriedade do wrapper de elemento ─────────────────────────────

@(private = "file")
dom_elem_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    node := cast(^dom.Node) o.host
    // host==nil = referência JS a um nó JÁ DESTRUÍDO (forget_wrapper zera o host
    // p/ não deixar ponteiro pendurado — ver o crash do wikipedia). Toda leitura
    // de propriedade vira undefined em vez de dereferenciar nil.
    if node == nil do return nil, true
    switch name {
    case "isConnected":
        // true se o nó alcança o Document subindo por parent (spec). Libs usam p/
        // decidir se ainda vale mexer no DOM depois de um await.
        for a := node; a != nil; a = a.parent {
            if a.kind == .Document do return true, true
        }
        return false, true
    case "data", "nodeValue":
        // CharacterData.data / Node.nodeValue: o conteúdo de Text e Comment. O
        // lit-html identifica os próprios marcadores lendo `comment.data` — sem
        // isto, undefined, e nenhuma "part" era reconhecida no template.
        if node.kind == .Text || node.kind == .Comment do return own_str(vm, node.text), true
        return JS_Null{}, true
    case "textContent":
        sb: strings.Builder
        strings.builder_init(&sb)
        dom.text_content(node, &sb)
        s := strings.clone(strings.to_string(sb)) // lido do DOM -> posse do vm
        strings.builder_destroy(&sb)
        append(&vm.owned_strings, s)
        return s, true
    case "tagName":
        return own_str(vm, element_tag_name(node)), true
    case "contentWindow", "contentDocument":
        // <iframe>/<frame>: janela + documento PRÓPRIOS (em branco). Libs criam um
        // iframe e acessam `iframe.contentWindow.document` (feature-detect/sandbox);
        // contentWindow era undefined → "reading 'document' of undefined" — gap #1 do
        // gap-miner (8 sites: codepen/medium/discord/wired/stackoverflow/canva/zoom/estadao).
        if node == nil || (node.tag != "iframe" && node.tag != "frame") do return nil, false
        win := iframe_content_window(vm, o, node)
        if name == "contentDocument" {
            if d, dok := win.props["document"].(^Object); dok do return d, true
            return JS_Null{}, true
        }
        return win, true
    case "clientWidth", "offsetWidth", "scrollWidth", "clientHeight", "offsetHeight",
         "scrollHeight", "offsetTop", "offsetLeft", "scrollTop", "scrollLeft":
        // Geometria REAL do layout (ui/computed_om.odin). Antes daqui saía uma
        // aproximação cega: viewport p/ html/body e 0 p/ todo o resto — ou seja,
        // TODA medição de elemento devolvia zero, em silêncio.
        if g_element_metric != nil {
            if v, ok := g_element_metric(node, name); ok do return f64(v), true
        }
        // Sem layout ainda (scripts de carga) ou nó sem caixa: o fallback histórico
        // p/ html/body evita que "largura da janela" vire 0 no meio da carga.
        if node.tag == "html" || node.tag == "body" {
            switch name {
            case "clientWidth", "offsetWidth", "scrollWidth":   return f64(800), true
            case "clientHeight", "offsetHeight", "scrollHeight": return f64(600), true
            }
        }
        return f64(0), true
    case "nodeType": // React (isValidContainer) exige: Element=1, Text=3, Comment=8, Document=9, Fragment=11
        if is_fragment(node) do return f64(11), true
        switch node.kind {
        case .Element:  return f64(1), true
        case .Text:     return f64(3), true
        case .Comment:  return f64(8), true
        case .Document: return f64(9), true
        }
        return f64(1), true
    case "nodeName":
        if is_fragment(node)      do return "#document-fragment", true
        if node.kind == .Element do return own_str(vm, element_tag_name(node)), true
        if node.kind == .Text    do return "#text", true
        if node.kind == .Comment do return "#comment", true
        return "#document", true
    case "className":
        return own_str(vm, get_class(node)), true // clonado: a dom-owned morre no próximo set
    case "classList":
        cl := new_object(vm) // wrapper leve; compartilha o host (o mesmo nó)
        cl.host = o.host
        cl.get = classlist_get
        return cl, true
    case "style": // wrapper: el.style.color / el.style.cssText — apoiado no atributo style=""
        st := new_object(vm)
        st.host = o.host
        st.get = style_prop_get
        st.set = style_prop_set
        return st, true
    case "dataset": // wrapper: el.dataset.userId <-> atributo data-user-id
        ds := new_object(vm)
        ds.host = o.host
        ds.get = dataset_get
        ds.set = dataset_set
        return ds, true
    case "constructor":
        // React (inputValueTracking) faz `node.constructor.prototype` p/ ler o
        // descriptor nativo de value/checked de todo <input>/<textarea>/<select>.
        // Sem `constructor`, isso lançava "Cannot read properties of undefined
        // (reading 'prototype')" e MATAVA o commit do React → página em branco
        // (era o único bloqueador de tradebig, e o mesmo erro no google.com).
        // Devolvemos um constructor compartilhado com prototype VAZIO: o
        // Object.getOwnPropertyDescriptor devolve undefined e o React DESISTE do
        // rastreio nativo sem quebrar — inputs controlados seguem pelo re-render.
        //
        // EXCEÇÃO — custom element PROMOVIDO: aí `constructor` PRECISA ser a classe.
        // Todo componente Lit faz `this.constructor.elementProperties` dentro do
        // construtor; devolver o stub genérico dava undefined e matava o componente
        // (era o último bloqueador do archive.org). Restrito aos promovidos para não
        // mexer no caminho do React acima.
        if _, upgraded := o.props[UPGRADED_KEY]; upgraded {
            for p := o.proto; p != nil; p = p.proto {
                if c, has := p.props["constructor"]; has do return c, true
            }
        }
        return dom_element_constructor(vm), true
    case "ownerDocument":
        // React cria host instances via `container.ownerDocument.createElement(type)`.
        // Sem isto, ownerDocument=undefined → createElement no-op → nada é montado.
        if v, ok := env_get(vm.global, "document"); ok do return v, true
        return JS_Null{}, true
    case "parentNode":
        if node.parent == nil do return JS_Null{}, true
        return wrap_element(vm, node.parent), true
    case "namespaceURI":
        // O hidratador do Svelte lê isto p/ escolher createElement vs createElementNS.
        // Não guardamos namespace por nó; devolvemos o do documento HTML (e o de SVG
        // quando a tag é `svg`, que é onde a distinção importa na prática).
        if node.tag == "svg" do return own_str(vm, "http://www.w3.org/2000/svg"), true
        return own_str(vm, "http://www.w3.org/1999/xhtml"), true
    case "parentElement":
        // Faltava — só `parentNode` existia. Difere dele por parar no Document
        // (parentElement de <html> é null) e é o nome que o código de UI usa quase
        // sempre: `el.parentElement.appendChild(...)` dava "reading 'appendChild' of
        // undefined" (o que restava no crates.io).
        if node.parent == nil || node.parent.kind != .Element do return JS_Null{}, true
        return wrap_element(vm, node.parent), true
    // Coleções VIVAS, sem cópia: um objeto por nó, cacheado, que lê node.children na
    // hora. Antes, cada leitura materializava um ^Array inteiro — O(n) por acesso, e
    // `var c = el.children` congelava a lista. Ver dom_collection.odin.
    case "children":   // só filhos ELEMENTO (HTMLCollection)
        return dom_collection(vm, o, node, .Elements), true
    case "childNodes": // TODOS os filhos, inclusive texto/comentário (NodeList); React usa no commit
        return dom_collection(vm, o, node, .Nodes), true
    case "childElementCount":
        return f64(node.n_elem_kids), true // contador do dom: O(1), sem criar coleção
    // firstElementChild/lastElementChild/next-/previousElementSibling: estavam
    // DECLARADOS como accessors em Element.prototype (install_dom_props) e nunca
    // servidos aqui — ou seja, undefined em silêncio, num punhado das APIs de árvore
    // mais usadas que existem. É o que fazia o check `children/childNodes/
    // firstElementChild` da sonda dar FAIL ("reading 'tagName' of undefined").
    case "firstElementChild":
        for c in node.children {
            if is_pseudo_child(c) do continue
            if c.kind == .Element do return wrap_element(vm, c), true
        }
        return JS_Null{}, true
    case "lastElementChild":
        #reverse for c in node.children {
            if is_pseudo_child(c) do continue
            if c.kind == .Element do return wrap_element(vm, c), true
        }
        return JS_Null{}, true
    case "nextElementSibling", "previousElementSibling":
        p := node.parent
        if p == nil do return JS_Null{}, true
        at := -1
        for c, i in p.children do if c == node { at = i; break }
        if at < 0 do return JS_Null{}, true
        if name == "nextElementSibling" {
            for i := at + 1; i < len(p.children); i += 1 {
                c := p.children[i]
                if is_pseudo_child(c) do continue
                if c.kind == .Element do return wrap_element(vm, c), true
            }
        } else {
            for i := at - 1; i >= 0; i -= 1 {
                c := p.children[i]
                if is_pseudo_child(c) do continue
                if c.kind == .Element do return wrap_element(vm, c), true
            }
        }
        return JS_Null{}, true
    case "shadowRoot":
        // null quando não há shadow OU quando o modo é "closed" (spec).
        if sr := shadow_root_of(node); sr != nil {
            if m, ok := sr.attrs["mode"]; !ok || m != "closed" do return wrap_element(vm, sr), true
        }
        return JS_Null{}, true
    case "host":
        // ShadowRoot.host → o elemento que hospeda esta raiz.
        if node.tag == "#shadow" && node.parent != nil do return wrap_element(vm, node.parent), true
        return JS_Null{}, true
    case "content":
        // <template>.content → o document-fragment "#content". O PARSER já o cria
        // (treebuild.odin), mas um template feito por createElement não passa pelo
        // parser: criamos sob demanda e MOVEMOS p/ dentro os filhos que já existirem
        // (o caso de `t.innerHTML = "..."` antes da 1ª leitura de .content).
        if node.tag == "template" {
            for c in node.children {
                if c.tag == "#content" do return wrap_element(vm, c), true
            }
            frag := dom.make_node(.Element)
            frag.tag = strings.clone("#content")
            // DELIBERADAMENTE fora do funil de mutação: no navegador os filhos de
            // um <template> JÁ nascem dentro de .content — esta migração preguiçosa
            // é detalhe nosso e não muda o estado observável. Registrá-la geraria
            // um MutationRecord fantasma.
            existing := make([dynamic]^dom.Node, context.temp_allocator)
            for c in node.children do append(&existing, c)
            dom.kids_clear(node)
            for c in existing {
                c.parent = nil
                dom.append_child(frag, c)
            }
            dom.append_child(node, frag)
            return wrap_element(vm, frag), true
        }
        return nil, false
    case "lastChild":
        if lc := last_real_child(node); lc != nil do return wrap_element(vm, lc), true
        return JS_Null{}, true
    case "previousSibling":
        p := node.parent
        if p != nil {
            for c, i in p.children {
                if c == node {
                    if i > 0 do return wrap_element(vm, p.children[i - 1]), true
                    break
                }
            }
        }
        return JS_Null{}, true
    case "firstChild":
        for c in node.children { // qualquer nó (inclusive texto), menos pseudo-filhos
            if is_pseudo_child(c) do continue
            return wrap_element(vm, c), true
        }
        return JS_Null{}, true
    case "nextSibling":
        p := node.parent
        if p != nil {
            for c, i in p.children {
                if c == node {
                    if i + 1 < len(p.children) do return wrap_element(vm, p.children[i + 1]), true
                    break
                }
            }
        }
        return JS_Null{}, true
    case "innerHTML":
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        for c in node.children do serialize_node(&sb, c)
        return own_str(vm, strings.to_string(sb)), true
    // ── propriedades refletidas de atributo (inputs controlados etc.) ──
    // `.value` corrente de um input: guardado no atributo "value". (Este motor
    // não separa a propriedade `.value` do atributo default — suficiente p/ o
    // padrão React de input controlado: ler e.target.value, reescrever .value.)
    case "value":
        // <option> sem atributo value: o `.value` é o textContent (spec) — o
        // updateOptions do React compara `option.value === selectedValue`.
        if _, ok := node.attrs["value"]; !ok && node.tag == "option" do return option_text(vm, node), true
        return attr_or_empty(vm, node, "value"), true
    case "options": // <select>.options → coleção dos <option> descendentes (HTMLOptionsCollection)
        arr := new_array(vm)
        collect_options(vm, node, arr)
        return arr, true
    case "selectedIndex": // <select>: índice da opção corrente; -1 se não há opções
        if node.tag == "select" do return f64(select_index(node)), true
    case "selected", "defaultSelected": // <option>: estado/atributo selected
        return attr_bool(node, "selected"), true
    case "id":          return attr_or_empty(vm, node, "id"), true
    case "name":        return attr_or_empty(vm, node, "name"), true
    case "type":        return attr_or_empty(vm, node, "type"), true
    case "placeholder": return attr_or_empty(vm, node, "placeholder"), true
    case "href":        return attr_or_empty(vm, node, "href"), true
    case "src":         return attr_or_empty(vm, node, "src"), true
    case "title":       return attr_or_empty(vm, node, "title"), true
    case "alt":         return attr_or_empty(vm, node, "alt"), true
    case "htmlFor":     return attr_or_empty(vm, node, "for"), true
    case "checked":     return attr_bool(node, "checked"), true
    case "disabled":    return attr_bool(node, "disabled"), true
    }
    // <video>/<audio>: paused/currentTime/volume/… (media.odin). Depois do switch
    // acima de propósito — `src`/`title` etc. são refletidas de atributo e valem
    // para mídia igual ao resto.
    if v, ok := media_get(vm, node, name); ok do return v, true
    if fn, ok := vm.dom_element_methods[name]; ok do return fn, true
    return nil, false // cai nas props normais
}

// Valor de um atributo, CLONADO p/ o vm (own_str), ou "" se ausente. Devolver a
// string dom-owned crua danglearia: `const v = input.value; input.value = "x"`
// faz set_attr_str liberar a antiga enquanto o JS ainda segura `v` (fluxo de
// input controlado do React).
@(private = "file")
attr_or_empty :: proc(vm: ^Interp, node: ^dom.Node, key: string) -> Value {
    if v, ok := node.attrs[key]; ok do return own_str(vm, v)
    return ""
}

// Atributo booleano: presente e diferente de "false" => true (`<input disabled>`
// tem valor "" e conta como true; `el.disabled=false` grava "false" e conta false).
@(private = "file")
attr_bool :: proc(node: ^dom.Node, key: string) -> bool {
    v, ok := node.attrs[key]
    return ok && v != "false"
}

// <option>.value / .text quando não há atributo value: o textContent do option.
@(private = "file")
option_text :: proc(vm: ^Interp, node: ^dom.Node) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb)
    dom.text_content(node, &sb)
    s := strings.clone(strings.to_string(sb)) // lido do DOM -> posse do vm
    strings.builder_destroy(&sb)
    append(&vm.owned_strings, s)
    return s
}

// Os <option> de um <select> em ordem de documento, como NÓS (a versão de
// `collect_options` devolve wrappers JS). ⚠️ a mesma regra vive em `select_options`
// no pacote ui — `src/js` NÃO pode importar `src/ui`, então a duplicação é
// estrutural; se uma mudar, a outra tem de mudar (o ui pinta o rótulo, o js
// responde ao script, e divergir aí é bug silencioso).
@(private = "file")
option_nodes :: proc(node: ^dom.Node, out: ^[dynamic]^dom.Node) {
    for c in node.children {
        if c.kind != .Element do continue
        switch c.tag {
        case "option":   append(out, c)
        case "optgroup": option_nodes(c, out)
        }
    }
}

// Valor de um <option>: atributo `value`, senão o texto (spec).
@(private = "file")
option_value_str :: proc(node: ^dom.Node) -> string {
    if v, ok := node.attrs["value"]; ok do return v
    sb := strings.builder_make(context.temp_allocator)
    dom.text_content(node, &sb)
    return strings.trim_space(strings.to_string(sb))
}

// Índice da opção corrente: o atributo `value` do select vence (é onde `el.value`
// aterra neste motor), senão o primeiro `selected`, senão 0.
@(private = "file")
select_index :: proc(node: ^dom.Node) -> int {
    opts := make([dynamic]^dom.Node, context.temp_allocator)
    option_nodes(node, &opts)
    if len(opts) == 0 do return -1
    if want, ok := node.attrs["value"]; ok {
        for o, i in opts do if option_value_str(o) == want do return i
    }
    for o, i in opts {
        if s, ok := o.attrs["selected"]; ok && !strings.equal_fold(s, "false") do return i
    }
    return 0
}

// Coleta os <option> descendentes (recursando em <optgroup>) para select.options.
@(private = "file")
collect_options :: proc(vm: ^Interp, node: ^dom.Node, arr: ^Array) {
    for c in node.children {
        if c.kind != .Element do continue
        if c.tag == "option" {
            append(&arr.items, wrap_element(vm, c))
        } else if c.tag == "optgroup" {
            collect_options(vm, c, arr)
        }
    }
}

// ── serialização (innerHTML getter) ─────────────────────────────────────────

@(private = "file")
is_void_tag :: proc(tag: string) -> bool {
    switch tag {
    case "area", "base", "br", "col", "embed", "hr", "img", "input",
         "link", "meta", "param", "source", "track", "wbr":
        return true
    }
    return false
}

@(private = "file")
write_escaped :: proc(sb: ^strings.Builder, s: string, in_attr: bool) {
    for i := 0; i < len(s); i += 1 {
        switch s[i] {
        case '&': strings.write_string(sb, "&amp;")
        case '<': strings.write_string(sb, "&lt;")
        case '>': strings.write_string(sb, "&gt;")
        case '"':
            if in_attr {
                strings.write_string(sb, "&quot;")
            } else {
                strings.write_byte(sb, '"')
            }
        case:
            strings.write_byte(sb, s[i])
        }
    }
}

@(private = "file")
serialize_node :: proc(sb: ^strings.Builder, n: ^dom.Node) {
    switch n.kind {
    case .Text:
        write_escaped(sb, n.text, false)
    case .Comment:
        strings.write_string(sb, "<!--")
        strings.write_string(sb, n.text)
        strings.write_string(sb, "-->")
    case .Element:
        strings.write_byte(sb, '<')
        strings.write_string(sb, n.tag)
        for k, v in n.attrs {
            strings.write_byte(sb, ' ')
            strings.write_string(sb, k)
            strings.write_string(sb, "=\"")
            write_escaped(sb, v, true)
            strings.write_byte(sb, '"')
        }
        strings.write_byte(sb, '>')
        if is_void_tag(n.tag) do return // sem filhos nem fechamento
        for c in n.children do serialize_node(sb, c)
        strings.write_string(sb, "</")
        strings.write_string(sb, n.tag)
        strings.write_byte(sb, '>')
    case .Document:
        for c in n.children do serialize_node(sb, c)
    }
}

@(private = "file")
dom_elem_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    node := cast(^dom.Node) o.host
    if node == nil do return true // nó destruído: escrita é NO-OP silencioso
    // Handler de evento por propriedade: onclick, oninput, onchange, onsubmit,
    // onkeydown, onblur, ... `el.on<tipo> = fn` registra p/ o evento `<tipo>`;
    // `= null` remove. Substitui o handler-propriedade anterior (não acumula).
    if len(name) > 2 && name[:2] == "on" {
        type := name[2:]
        if fn, ok := val.(^Function); ok {
            set_prop_handler(vm, o.host, type, fn)
        } else {
            set_prop_handler(vm, o.host, type, nil)
        }
        return true
    }
    // <video>/<audio>: currentTime/volume/muted/… (media.odin). ANTES do switch:
    // `loop` e `muted` também são atributos, e para mídia quem manda é o estado.
    if media_set(vm, node, name, val) do return true
    switch name {
    case "value", "id", "name", "type", "placeholder", "href", "src", "title", "alt":
        set_attr_val(vm, node, name, val) // inputs controlados: `el.value = x`
        return true
    case "htmlFor":
        set_attr_val(vm, node, "for", val)
        return true
    case "width", "height":
        // `canvas.width = N`: reflete no ATRIBUTO (é dele que o layout tira o
        // tamanho intrínseco) e RESETA a superfície inteira, como manda a spec —
        // inclusive quando o valor não muda. É o idioma de "limpar o canvas".
        if node.tag == "canvas" {
            set_attr_val(vm, node, name, val)
            canvas_reset(vm, o.host)
            return true
        }
    case "checked", "disabled":
        set_attr_str(vm, node, name, "true" if truthy(val) else "false")
        return true
    case "selectedIndex": // <select>: escolher por índice equivale a escrever .value
        if node.tag == "select" {
            opts := make([dynamic]^dom.Node, context.temp_allocator)
            option_nodes(node, &opts)
            idx := int(to_number(vm, val))
            for o in opts do remove_attr_owned(vm, o, "selected") // pelo funil (observável)
            if idx >= 0 && idx < len(opts) {
                set_attr_str(vm, opts[idx], "selected", "true")
                set_attr_str(vm, node, "value", option_value_str(opts[idx]))
            }
            return true
        }
    case "selected", "defaultSelected": // <option> — ambos refletem o atributo selected
        set_attr_str(vm, node, "selected", "true" if truthy(val) else "false")
        return true
    case "style":
        // `el.style = "color:red"` (string) define o cssText inline inteiro.
        // (`el.style.color = ...` NÃO passa aqui — vai pelo wrapper style_prop_set.)
        set_attr_val(vm, node, "style", val)
        return true
    case "className":
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, val)
        set_attr_str(vm, node, "class", strings.to_string(sb))
        return true
    case "data", "nodeValue":
        // CharacterData.data / Node.nodeValue — a ESCRITA no conteúdo de um Text/
        // Comment. Só o getter existia: `t.data = "x"` caía no set genérico do
        // Object, virava uma prop JS sombreada pelo get-hook e sumia em silêncio.
        // É também a única mutação de `characterData` que o motor tem — sem ela,
        // `observe(t, {characterData:true})` seria uma opção que nunca dispara.
        if node.kind != .Text && node.kind != .Comment do return true
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, val)
        mo_record_char(vm, node, node.text) // valor ANTIGO (own_str clona antes do delete)
        if node.text != "" do delete(node.text)
        node.text = strings.clone(strings.to_string(sb)) // escrito no DOM -> posse do DOM
        return true
    case "textContent":
        when #config(DOMPROBE, false) {
            // teste da hipótese de ALIASING: um filho cujo .parent NÃO é este nó
            // está em dois arrays de filhos → liberar aqui deixa ponteiro pendurado
            // no outro pai. Também identifica QUEM levou textContent.
            // teste de ALIASING sem depender de fmt (não importado aqui): grava no
            // log do dom quem levou textContent e se algum filho tem outro pai.
            dom.g_free_tag = "textContent"
            dom.g_probe_owner = node
            for c in node.children do if c.parent != node do dom.g_probe_alias = true
        }
        detach_or_free_children(vm, node) // troca filhos por 1 nó de texto (preserva os que o JS ainda referencia)
        sb: strings.Builder
        strings.builder_init(&sb)
        to_text(&sb, val)
        t := dom.make_node(.Text)
        t.text = strings.clone(strings.to_string(sb)) // escrito no DOM -> posse do DOM
        strings.builder_destroy(&sb)
        mo_insert(vm, node, t)
        return true
    case "innerHTML":
        // parseia o fragmento com o parser HTML REAL e substitui os filhos.
        // (Como nos navegadores, <script> inserido via innerHTML NÃO executa.)
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, val)

        when #config(DOMPROBE,false) { dom.g_free_tag = "innerHTML" }
        detach_or_free_children(vm, node)

        frag := parse_html_fragment(node, strings.to_string(sb)) // fragmento no contexto do próprio elemento
        for c in frag.children do mo_insert(vm, node, c) // move (re-ancora o parent)
        dom.kids_clear(frag) // esvazia ANTES do free: os filhos agora são do node
        when #config(DOMPROBE,false) { dom.g_free_tag = "innerHTML-frag" }
        dom.free_tree(frag)
        return true
    }
    return false
}
