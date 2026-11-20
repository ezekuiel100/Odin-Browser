package js

// Upgrade de custom element que JÁ está no documento, com HERANÇA de campos de
// classe — o `<react-app>` do github.com: `class H extends HTMLElement { #e=0;
// get name(){ return this.getAttribute(this.nameAttribute) } }` e
// `class App extends H { nameAttribute = "app-name" }` (construtor implícito).

import "core:testing"
import "core:strings"
import dom "../dom"

@(private = "file")
run_dom_ce :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

@(test)
ce_upgrade_campos_herdados :: proc(t: ^testing.T) {
    src := `
        var log = [];
        var el = document.createElement("x-app");
        el.setAttribute("app-name", "landing-pages");
        document.body.appendChild(el);           // no documento ANTES do define
        class Base extends HTMLElement {
            #e = 0;
            base = "b";
            get name() { return this.getAttribute(this.nameAttribute); }
            connectedCallback() { log.push(this.name, ++this.#e, this.base, typeof this.nameAttribute); }
        }
        class App extends Base { nameAttribute = "app-name"; }
        customElements.define("x-app", App);
        log.join(",")
    `
    r := run_dom_ce(src)
    s, _ := r.(string)
    testing.expect_value(t, s, "landing-pages,1,b,string")
}

@(test)
ce_classe_sombreia_nativo_so_quando_define :: proc(t: ^testing.T) {
    // setter da classe vence o nativo; o que a classe NÃO define segue nativo
    src := `
        var log = [];
        var el = document.createElement("x-v");
        el.setAttribute("name", "attr-name");
        el.id = "i1";
        document.body.appendChild(el);
        class V extends HTMLElement {
            #v = "";
            get value() { return "classe:" + this.#v; }
            set value(x) { this.#v = x; }
        }
        customElements.define("x-v", V);
        el.value = "abc";
        log.push(el.value, el.getAttribute("value"), el.name, el.id);
        log.join(",")
    `
    r := run_dom_ce(src)
    s, _ := r.(string)
    testing.expect_value(t, s, "classe:abc,,attr-name,i1")
}

@(test)
ce_upgrade_campos_com_construtor_explicito :: proc(t: ^testing.T) {
    src := `
        var log = [];
        var el = document.createElement("x-b");
        document.body.appendChild(el);
        class Base extends HTMLElement { a = 1; constructor(){ super(); this.c = this.a + 1; } }
        class B extends Base { b = 10; constructor(){ super(); this.d = this.b + this.c; }
            connectedCallback(){ log.push(this.a, this.b, this.c, this.d); } }
        customElements.define("x-b", B);
        log.join(",")
    `
    r := run_dom_ce(src)
    s, _ := r.(string)
    testing.expect_value(t, s, "1,10,2,12")
}
