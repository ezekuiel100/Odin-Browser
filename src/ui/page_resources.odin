package ui

import "core:strings"
import "core:sync"
import "core:thread"
import "base:intrinsics"
import net "../net"
import dom "../dom"
import html "../html"

// The navigation owns this cache. Downloads overlap; DOM access, script
// execution and CSS expansion stay on the navigation's owning thread.
PAGE_RESOURCE_WORKERS :: 6
Page_Resource_Load :: #type proc(url: string) -> net.Response
Page_Resource :: struct {
    url: string,
    response: net.Response,
    lock: sync.Mutex,
    ready: sync.Cond,
    done: bool,
}
Page_Resources :: struct {
    entries: [dynamic]^Page_Resource,
    by_url: map[string]^Page_Resource,
    late: map[string]net.Response, // imports/links discovered later; owner-thread only
    threads: [dynamic]^thread.Thread,
    lock: sync.Mutex,
    next: int,
    load: Page_Resource_Load,
}

page_resources_add :: proc(p: ^Page_Resources, url: string) {
    if url in p.by_url do return
    r := new(Page_Resource)
    r.url = strings.clone(url)
    append(&p.entries, r)
    p.by_url[r.url] = r
}

page_resources_start :: proc(root: ^dom.Node, base: string, load: Page_Resource_Load = net.fetch) -> ^Page_Resources {
    p := new(Page_Resources)
    p.by_url = make(map[string]^Page_Resource)
    p.late = make(map[string]net.Response)
    p.load = load
    // Queue CSS first, so a styled first page needn't wait for script bundles.
    page_resources_collect_css(root, base, p)
    scripts: [dynamic]^dom.Node
    collect_scripts_rec(root, &scripts)
    count := 0
    for s in script_exec_order(scripts[:], context.temp_allocator) {
        src := s.attrs["src"]
        if src == "" || is_blocked_script_host(src) do continue
        if count >= MAX_SCRIPTS do break
        count += 1
        page_resources_add(p, net.resolve_url(base, src, context.temp_allocator))
    }
    delete(scripts)
    // Initialize curl before starting concurrent first requests.
    if len(p.entries) > 0 && load == net.fetch do net.ensure_init()
    for i in 0 ..< min(PAGE_RESOURCE_WORKERS, len(p.entries)) {
        t := thread.create(page_resources_worker)
        if t == nil do break
        t.data = p
        append(&p.threads, t)
        thread.start(t)
    }
    // Thread allocation failure must not leave a request waiting forever.
    if len(p.threads) == 0 do page_resources_run(p)
    return p
}

page_resources_collect_css :: proc(n: ^dom.Node, base: string, p: ^Page_Resources) {
    if n.kind == .Element && n.tag == "link" && len(p.entries) < MAX_SHEETS {
        rel := strings.to_lower(n.attrs["rel"], context.temp_allocator)
        if href, ok := n.attrs["href"]; ok && strings.contains(rel, "stylesheet") {
            url := net.resolve_url(base, href, context.temp_allocator)
            if url_buscavel(url) do page_resources_add(p, url)
        }
    }
    for c in n.children do page_resources_collect_css(c, base, p)
}

page_resources_worker :: proc(t: ^thread.Thread) {
    dbg_adopt_allocator()
    page_resources_run(cast(^Page_Resources)t.data)
}

page_resources_run :: proc(p: ^Page_Resources) {
    for {
        sync.mutex_lock(&p.lock)
        i := p.next
        p.next += 1
        sync.mutex_unlock(&p.lock)
        if i >= len(p.entries) do break
        r := p.entries[i]
        response := p.load(r.url)
        // curl's metadata is borrowed; retain it while cached bodies are in use.
        response.content_type = strings.clone(response.content_type)
        sync.mutex_lock(&r.lock)
        r.response = response
        r.done = true
        sync.cond_broadcast(&r.ready)
        sync.mutex_unlock(&r.lock)
    }
}

// The index is immutable after start. Each consumer owns its body/error copy;
// metadata stays valid until page_resources_free (after all consumers finish).
page_resource_fetch :: proc(p: ^Page_Resources, url: string) -> net.Response {
    if p == nil do return net.fetch(url)
    r, found := p.by_url[url]
    if !found {
        response, cached := p.late[url]
        if !cached {
            response = p.load(url)
            response.content_type = strings.clone(response.content_type)
            p.late[strings.clone(url)] = response
        }
        return page_resource_response_copy(response)
    }
    sync.mutex_lock(&r.lock)
    defer sync.mutex_unlock(&r.lock)
    for !r.done do sync.cond_wait(&r.ready, &r.lock)
    return page_resource_response_copy(r.response)
}

page_resource_response_copy :: proc(response: net.Response) -> net.Response {
    result := response
    result.body = strings.clone(result.body)
    if !result.ok do result.err = strings.clone(result.err)
    return result
}

page_resources_free :: proc(p: ^Page_Resources) {
    if p == nil do return
    for t in p.threads { thread.join(t); thread.destroy(t) }
    for r in p.entries {
        delete(r.url)
        delete(r.response.body)
        delete(r.response.content_type)
        if !r.response.ok && r.response.err != "" do delete(r.response.err)
        free(r)
    }
    for url, r in p.late {
        delete(url); delete(r.body); delete(r.content_type)
        if !r.ok && r.err != "" do delete(r.err)
    }
    delete(p.late)
    delete(p.threads); delete(p.entries); delete(p.by_url)
    free(p)
}

// Pure app shells gain nothing from painting an empty root before bootstrap.
page_has_static_content :: proc(n: ^dom.Node) -> bool {
    if n.kind == .Text do return strings.trim_space(n.text) != ""
    if n.kind == .Element {
        switch n.tag {
        case "head", "script", "style", "template": return false
        case "img", "svg", "input", "video": return true
        }
    }
    for c in n.children do if page_has_static_content(c) do return true
    return false
}

// An independent snapshot is transferred to the UI. The worker keeps its own
// DOM for script mutations, so a frame never races against JavaScript.
page_publish_preview :: proc(job: ^Fetch_Job, resources: ^Page_Resources) {
    preview := job.preview
    if preview == nil || !page_has_static_content(job.dom) do return
    scripts: [dynamic]^dom.Node
    collect_scripts_rec(job.dom, &scripts)
    has_scripts := len(scripts) > 0
    delete(scripts)
    if !has_scripts do return
    preview.resp = {ok = true, status = job.resp.status, body = strings.clone(job.resp.body)}
    preview.url = strings.clone(job.url)
    preview.dom = html.parse_render(job.resp.body)
    preview.final_url = strings.clone(job.final_url)
    preview.css_text = strings.clone(collect_page_css(preview.dom, job.url, resources))
    fetch_job_prepare_layout(preview)
    loading_trace_event("preview-ready")
    intrinsics.atomic_store(&preview.done, true)
}
