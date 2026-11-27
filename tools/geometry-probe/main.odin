package main

// Real-font mutation probe. Run through geometry-check.ps1; screenshots and
// geometry are compared with independent complete style/layout trees.
import "core:os"
import "core:fmt"
import "core:strings"
import ui "../../src/ui"
import html "../../src/html"
import dom "../../src/dom"
import im "../../vendor/imgui"
import imgui_sdl2 "../../vendor/imgui/imgui_impl_sdl2"
import imgui_sdlr "../../vendor/imgui/imgui_impl_sdlrenderer2"
import sdl2 "vendor:sdl2"
import stbi "vendor:stb/image"

STEPS :: 16

find :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
    if n.attrs["id"] == id do return n
    for c in n.children do if r := find(c,id); r != nil do return r
    return nil
}
attr :: proc(n: ^dom.Node, key, value: string) { dom.set_attr(n,strings.clone(key),strings.clone(value)) }

compare :: proc(a,b: ^ui.Box) -> int {
    if a == nil || b == nil do return a == b ? 0 : 1
    bad := 0
    if a.node != b.node || a.x != b.x || a.y != b.y || a.w != b.w || a.h != b.h ||
       a.content_x != b.content_x || a.content_y != b.content_y || a.content_w != b.content_w ||
       len(a.children) != len(b.children) || len(a.inlines) != len(b.inlines) { bad += 1 }
    for i in 0 ..< min(len(a.children),len(b.children)) do bad += compare(a.children[i],b.children[i])
    for i in 0 ..< min(len(a.inlines),len(b.inlines)) {
        x,y := a.inlines[i],b.inlines[i]
        if x.kind != y.kind || x.text != y.text || x.x != y.x || x.y != y.y || x.w != y.w || x.h != y.h do bad += 1
        bad += compare(x.box,y.box)
    }
    return bad
}

main :: proc() {
    assert(len(os.args) == 3,"usage: geometry-probe <incremental|full> <output-directory>")
    mode, output := os.args[1],os.args[2]
    assert(mode == "incremental" || mode == "full")
    assert(sdl2.Init(sdl2.INIT_VIDEO) == 0)
    defer sdl2.Quit()
    window := sdl2.CreateWindow("geometry probe",0,0,700,500,{.HIDDEN})
    assert(window != nil); defer sdl2.DestroyWindow(window)
    renderer := sdl2.CreateRenderer(window,-1,{.ACCELERATED})
    assert(renderer != nil); defer sdl2.DestroyRenderer(renderer)
    ui.g_renderer = renderer
    im.CHECKVERSION(); im.CreateContext(); defer im.DestroyContext()
    io := im.GetIO(); io.DisplaySize = {700,500}; io.MousePos = {-1,-1}
    ui.setup_fonts(io); ui.apply_style(); ui.g_native_font_interactive = true
    imgui_sdl2.InitForSDLRenderer(window,renderer); defer imgui_sdl2.Shutdown()
    imgui_sdlr.Init(renderer); defer imgui_sdlr.Shutdown()
    doc := html.parse(`<body><header id="prefix"></header><main><aside id="target">sidebar</aside><section>one two three four five six seven eight nine ten Superlongwordtoreflow <b>inline atom</b></section></main><div id="grid"><div>first cell</div><div>second cell</div></div><article id="stable">stable text and pseudo <b>atom</b></article><p id="text">a word that wraps with the next words</p><div id="list"><div>existing row</div></div><div style="position:relative;height:30px"><span style="position:absolute;right:20px;top:3px">positioned</span></div><footer>stable footer</footer></body>`)
    defer dom.free_tree(doc)
    tab := ui.Tab{dom=doc,css_text=`body{margin:10px;font:18px sans-serif}header{height:10px;background:#eee}header.tall{height:40px}main{display:flex;width:450px;height:90px}aside{width:100px;flex:none;background:#dbeafe}aside.wide{width:220px}section{flex:1;min-width:0;overflow-wrap:anywhere;background:#dcfce7}b{display:inline-block;width:70px;background:#fee2e2}#grid{display:grid;grid-template-columns:1fr 2fr;grid-template-rows:1fr;height:50px;width:450px;background:#fef3c7}#grid.tall{height:80px}article{width:450px;background:#eee;transform:translateX(2px)}article::before{content:'BEFORE ';color:blue}p{width:260px;margin:5px 0}footer{width:300px;background:#def}`}
    defer { ui.free_layout(tab.layout); ui.free_styles(tab.styles); ui.tab_drop_rules(&tab); ui.js_style_source_free() }
    state := ui.State{}
    inserted: ^dom.Node
    width: f32 = 700
    hits, reflowed := 0,0
    for step in 0 ..< STEPS {
        switch step {
        case 1: attr(find(doc,"target"),"class","wide")
        case 2: attr(find(doc,"target"),"class","")
        case 3: attr(find(doc,"prefix"),"class","tall")
        case 4: attr(find(doc,"prefix"),"class","")
        case 5: attr(find(doc,"grid"),"class","tall")
        case 6: attr(find(doc,"grid"),"class","")
        case 7:
            n := find(doc,"text").children[0]; delete(n.text)
            n.text = strings.clone("Changed text with more words Supercalifragilisticexpialidocious and a tail")
        case 8:
            inserted = dom.make_node(.Element); inserted.tag = strings.clone("div")
            attr(inserted,"style","height:20px;background:green")
            list := find(doc,"list"); inserted.parent=list; dom.kids_insert(list,0,inserted)
        case 9: dom.kids_remove_at(find(doc,"list"),0); dom.free_tree(inserted); inserted=nil
        case 10: attr(find(doc,"stable"),"style","background-color:#ccf;opacity:.7")
        case 11: width=620
        case 12: width=700
        case 13: attr(find(doc,"grid"),"style","grid-template-columns:2fr 1fr")
        case 14: attr(find(doc,"target"),"class","wide")
        case 15: attr(find(doc,"target"),"class",""); ui.g_geometry_resources += 1
        }
        if mode == "full" do tab.style_vw = -1
        ui.restyle_tab(&tab,width,500)
        ui.ensure_tab_geometry(tab.layout,width,500)
        hits += tab.layout.geometry_stats.hits; reflowed += tab.layout.geometry_stats.reflowed
        styles,_ := ui.compute_styles(tab.dom,&tab.rules,width,500,tab.kf[:])
        reference := ui.build_layout(doc,styles,"")
        ui.ensure_tab_geometry(reference,width,500)
        bad := compare(tab.layout,reference)
        fmt.eprintfln("[geometry-probe] mode=%s step=%d mismatches=%d hits=%d reflowed=%d",mode,step,bad,tab.layout.geometry_stats.hits,tab.layout.geometry_stats.reflowed)
        assert(bad == 0)
        ui.free_layout(reference); ui.free_styles(styles); ui.svg_css_bind(tab.styles)
        imgui_sdlr.NewFrame(); imgui_sdl2.NewFrame(); im.NewFrame()
        im.SetNextWindowPos({0,0}); im.SetNextWindowSize({700,500})
        im.PushStyleVarImVec2(.WindowPadding,{0,0})
        im.PushStyleColor(.WindowBg,0xffffffff)
        im.Begin("probe",nil,{.NoTitleBar,.NoResize,.NoMove,.NoScrollbar,.NoBringToFrontOnFocus,.NoNavFocus})
        ui.paint_layout(&state,tab.layout)
        im.End(); im.PopStyleColor(1); im.PopStyleVar(1); im.Render()
        sdl2.SetRenderDrawColor(renderer,255,255,255,255); sdl2.RenderClear(renderer)
        imgui_sdlr.RenderDrawData(im.GetDrawData(),renderer)
        pixels := make([]u8,700*500*4)
        rect := sdl2.Rect{0,0,700,500}
        assert(sdl2.RenderReadPixels(renderer,&rect,u32(sdl2.PixelFormatEnum.ABGR8888),raw_data(pixels),700*4) == 0)
        path := fmt.tprintf("%s/%s-%d.png",output,mode,step)
        assert(stbi.write_png(strings.clone_to_cstring(path,context.temp_allocator),700,500,4,raw_data(pixels),700*4) != 0)
        delete(pixels); sdl2.RenderPresent(renderer)
    }
    fmt.eprintfln("[geometry-probe] DONE mode=%s steps=%d hits=%d reflowed=%d",mode,STEPS,hits,reflowed)
    if mode == "incremental" do assert(hits > 0,"probe never exercised a geometry hit")
}
