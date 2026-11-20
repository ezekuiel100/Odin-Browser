package js

// element.animate / scrollTo (web_animations.odin). Caso real: a home do
// github.com — sem `animate`, o fade-in das imagens lançava a cada render e os
// error boundaries remontavam em laço até o React error #185.

import "core:testing"
import "core:strings"
import dom "../dom"

@(private = "file")
run_dom_wa :: proc(t: ^testing.T, src: string, want: string, loc := #caller_location) {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, src)
    r := vm_run(vm, `log.join(",")`) // depois do checkpoint de microtasks
    s, _ := r.(string)
    testing.expectf(t, s == want, "got %q, want %q", s, want, loc = loc)
    testing.expectf(t, vm.uncaught_total == 0, "nada pode lançar (uncaught=%d)", vm.uncaught_total, loc = loc)
}

@(test)
animate_padrao_github_pause_play_cancel :: proc(t: ^testing.T) {
    run_dom_wa(t, `
        var log = [];
        var img = document.createElement("img"); document.body.appendChild(img);
        var a = img.animate([{opacity:0},{opacity:1}], {duration:200, easing:"ease-out", fill:"backwards"});
        a.pause();                      // o github pausa até a imagem carregar
        log.push(a.playState);
        a.finished.then(function(x){ log.push("fim", x === a, a.playState); });
        a.play();                       // load
        var b = img.animate([{opacity:0},{opacity:1}], 100);
        b.cancel();                     // error
        b.finished; log.push(b.playState);
        log.push(typeof img.scrollTo, typeof img.getAnimations, img.getAnimations().length);
    `, "paused,idle,function,function,0,fim,true,finished")
}

@(test)
node_normalize_junta_textos_e_remove_vazios :: proc(t: ^testing.T) {
    // SplitText (github.com) chama `linha.normalize()` ao montar as linhas do título
    run_dom_wa(t, `
        var log = [];
        var p = document.createElement("p"); document.body.appendChild(p);
        p.appendChild(document.createTextNode("Soft"));
        p.appendChild(document.createTextNode(""));
        p.appendChild(document.createTextNode("ware "));
        var b = document.createElement("b"); p.appendChild(b);
        b.appendChild(document.createTextNode("st")); b.appendChild(document.createTextNode("ill"));
        p.appendChild(document.createTextNode(""));
        var primeiro = p.firstChild;
        p.normalize();
        log.push(p.childNodes.length, p.firstChild === primeiro, p.firstChild.data, b.childNodes.length, b.firstChild.data, p.textContent);
    `, "2,true,Software ,1,still,Software still")
}

@(test)
animate_fill_forwards_aplica_ultimo_keyframe :: proc(t: ^testing.T) {
    run_dom_wa(t, `
        var log = [];
        var d = document.createElement("div"); document.body.appendChild(d);
        var a = d.animate({opacity:[0, 0.5], transform:["none","translateX(10px)"]}, {duration:300, fill:"forwards"});
        var n = d.animate([{color:"red"},{color:"blue"}], {duration:300});   // sem fill: nada fica
        a.onfinish = function(e){ log.push("onfinish:"+e.type); };
        a.finished.then(function(){ log.push(d.style.opacity, d.style.transform, d.style.color === "" ? "sem-cor" : d.style.color); });
    `, "onfinish:finish,0.5,translateX(10px),sem-cor")
}
