package ui

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "base:intrinsics"
import "base:runtime"
import html "../html"
import dom "../dom"
import js "../js"
import net "../net"
import im "../../vendor/imgui"

@(private = "file")
resource_fixture_lock: sync.Mutex
@(private = "file")
resource_fixture_calls: map[string]int
@(private = "file")
resource_fixture_second: sync.Sema
@(private = "file")
resource_fixture_overlap: bool

@(private = "file")
resource_fixture_load :: proc(url: string) -> net.Response {
    sync.mutex_lock(&resource_fixture_lock)
    resource_fixture_calls[url] += 1
    sync.mutex_unlock(&resource_fixture_lock)
    code := ""
    switch {
    case strings.has_suffix(url, "/a.js"):
        // Sequential downloads time out here. Completion order is B then A;
        // execution must still be A, B, A (with one download of A).
        resource_fixture_overlap = sync.sema_wait_with_timeout(&resource_fixture_second, 500 * time.Millisecond)
        code = `window.trace = (window.trace || '') + 'A';`
    case strings.has_suffix(url, "/b.js"):
        sync.sema_post(&resource_fixture_second)
        code = `window.trace += 'B';`
    case strings.has_suffix(url, "/page.css"):
        code = `@import "nested.css"; p {color:red}`
    case strings.has_suffix(url, "/nested.css"):
        code = `p {background:yellow}`
    case strings.has_suffix(url, "/missing.js"):
        return {ok = false, err = strings.clone("fixture failure")}
    }
    return {ok = true, status = 200, body = strings.clone(code)}
}

@(test)
page_resources_overlap_preserve_execution_and_css_occurrences :: proc(t: ^testing.T) {
    // Odin's per-test rollback allocator isn't thread-safe. This integration
    // fixture shares heap allocations with download workers, as the app does.
    context.allocator = runtime.default_allocator()
    resource_fixture_calls = make(map[string]int)
    defer delete(resource_fixture_calls)
    resource_fixture_overlap = false
    doc := html.parse_render(`<link rel="stylesheet" href="page.css"><link rel="stylesheet" href="page.css" media="print"><body><p>hello</p><script src="a.js"></script><script src="b.js" defer></script><script src="a.js" defer></script><script src="missing.js" defer></script>`)
    defer dom.free_tree(doc)
    p := page_resources_start(doc, "https://resources.test/", resource_fixture_load)
    defer page_resources_free(p)
    vm := load_page_scripts(doc, "https://resources.test/", p)
    defer js.vm_free(vm)
    testing.expect_value(t, js.vm_run(vm, "window.trace").(string), "ABA")
    testing.expect_value(t, vm.uncaught_total, 0)
    css := collect_page_css(doc, "https://resources.test/", p)
    testing.expect_value(t, strings.count(css, "p {color:red}"), 2)
    testing.expect(t, strings.contains(css, "@media print"))
    testing.expect(t, resource_fixture_overlap, "two downloads must overlap")
    // Every queued response has been consumed, so all counters are published.
    testing.expect_value(t, resource_fixture_calls["https://resources.test/a.js"], 1)
    testing.expect_value(t, resource_fixture_calls["https://resources.test/page.css"], 1)
    collect_page_css(doc, "https://resources.test/", p)
    testing.expect(t, resource_fixture_calls["https://resources.test/nested.css"] == 1,
        "imports must be reused between preview and final CSS collection")
    // A failed prefetched request must also be cached and safe to consume twice.
    failed := page_resource_fetch(p, "https://resources.test/missing.js")
    testing.expect(t, !failed.ok)
    delete(failed.err)
    testing.expect_value(t, resource_fixture_calls["https://resources.test/missing.js"], 1)
}

@(private = "file")
preview_fixture_job :: proc(markup: string, id, generation: u64) -> ^Fetch_Job {
    job := new(Fetch_Job)
    job.url = strings.clone("https://preview.test/")
    job.final_url = strings.clone(job.url)
    job.tab_id = id; job.navigation_id = generation
    job.viewport_w = 800; job.viewport_h = 600
    job.resp = {ok = true, status = 200, body = strings.clone(markup)}
    job.dom = html.parse_render(markup)
    job.preview = new(Fetch_Job)
    job.preview.tab_id = id; job.preview.navigation_id = generation
    job.preview.viewport_w = 800; job.preview.viewport_h = 600
    return job
}

@(private = "file")
preview_fixture_free_tab :: proc(tab: ^Tab) {
    if tab.vm != nil do js.vm_free(tab.vm)
    if tab.layout != nil do free_layout(tab.layout)
    if tab.styles != nil do free_styles(tab.styles)
    tab_drop_rules(tab)
    if tab.dom != nil do dom.free_tree(tab.dom)
    delete(tab.css_text); delete(tab.content)
    delete(tab.relational_selectors)
    js_style_source_clear()
}

@(private = "file")
preview_fixture_has_text :: proc(b: ^Box, text: string) -> bool {
    if b == nil do return false
    for it in b.inlines do if it.kind == .Word && it.text == text do return true
    for c in b.children do if preview_fixture_has_text(c, text) do return true
    return false
}

@(test)
page_preview_transfers_independent_dom_then_final_page :: proc(t: ^testing.T) {
    previous_jobs := g_jobs
    g_jobs = nil
    defer { delete(g_jobs); g_jobs = previous_jobs }
    s: State
    append(&s.tabs, Tab{id = 901, navigation_id = 1, url = "https://preview.test/", loading = true})
    defer delete(s.tabs)
    defer preview_fixture_free_tab(&s.tabs[0])
    job := preview_fixture_job(`<style>p{color:red}</style><body><p id="message">before</p><script>document.getElementById('message').textContent='after';</script>`, 901, 1)
    append(&g_jobs, job)
    page_publish_preview(job, nil)
    poll_jobs(&s)
    testing.expect(t, s.tabs[0].loading && s.tabs[0].preview_visible)
    testing.expect(t, s.tabs[0].dom != job.dom && s.tabs[0].vm == nil)
    testing.expect(t, preview_fixture_has_text(s.tabs[0].layout, "before"))
    job.vm = load_page_scripts(job.dom, job.url)
    testing.expect(t, preview_fixture_has_text(s.tabs[0].layout, "before"), "worker mutations must not touch the displayed snapshot")
    job.css_text = strings.clone(collect_page_css(job.dom, job.url))
    fetch_job_prepare_layout(job)
    intrinsics.atomic_store(&job.done, true)
    poll_jobs(&s)
    testing.expect(t, !s.tabs[0].loading && !s.tabs[0].preview_visible)
    testing.expect(t, preview_fixture_has_text(s.tabs[0].layout, "after"))
    testing.expect_value(t, len(g_jobs), 0)
}

@(test)
page_preview_and_final_ignore_superseded_navigation :: proc(t: ^testing.T) {
    previous_jobs := g_jobs
    g_jobs = nil
    defer { delete(g_jobs); g_jobs = previous_jobs }
    s: State
    append(&s.tabs, Tab{id = 902, navigation_id = 2, loading = true})
    defer delete(s.tabs)
    job := preview_fixture_job(`<body>old<script>var a=1;</script>`, 902, 1)
    append(&g_jobs, job)
    page_publish_preview(job, nil)
    poll_jobs(&s)
    testing.expect(t, s.tabs[0].dom == nil && s.tabs[0].loading)
    intrinsics.atomic_store(&job.done, true)
    poll_jobs(&s)
    testing.expect(t, s.tabs[0].dom == nil && s.tabs[0].loading)
    testing.expect_value(t, len(g_jobs), 0)
}

@(test)
page_preview_is_discarded_after_tab_closes :: proc(t: ^testing.T) {
    previous_jobs := g_jobs
    g_jobs = nil
    defer { delete(g_jobs); g_jobs = previous_jobs }
    s: State // no matching tab remains
    job := preview_fixture_job(`<body>closed<script>var a=1;</script>`, 903, 1)
    append(&g_jobs, job)
    page_publish_preview(job, nil)
    poll_jobs(&s)
    testing.expect(t, job.preview.dom != nil, "an unconsumed preview remains owned by its job")
    intrinsics.atomic_store(&job.done, true)
    poll_jobs(&s)
    testing.expect_value(t, len(g_jobs), 0)
    testing.expect_value(t, len(s.tabs), 0)
}

@(test)
page_resources_skip_empty_shell_preview :: proc(t: ^testing.T) {
    doc := html.parse_render(`<title>not page content</title><body><div id="root"></div><script>var a=1;</script>`)
    defer dom.free_tree(doc)
    testing.expect(t, !page_has_static_content(doc))
}

// Like the tab-widget integration test, this owns a real font atlas and must
// run in its own process (other tests intentionally use synthetic fonts).
when #config(PAGE_PREVIEW_INTEGRATION_TEST, false) {
@(test)
page_preview_paints_in_real_ui_while_script_is_busy :: proc(t: ^testing.T) {
    previous_jobs := g_jobs
    g_jobs = nil
    defer { delete(g_jobs); g_jobs = previous_jobs }
    previous := im.GetCurrentContext()
    ctx := im.CreateContext()
    defer im.SetCurrentContext(previous)
    defer im.DestroyContext(ctx)
    defer shaped_text_clear()
    defer text_metrics_clear()
    io := im.GetIO()
    io.IniFilename = nil
    io.DisplaySize = {1280, 800}; io.DeltaTime = 1.0 / 60
    apply_style()
    old_big, old_ui := g_font_big, g_font_ui
    defer { g_font_big = old_big; g_font_ui = old_ui }
    font := im.FontAtlas_AddFontDefault(io.Fonts)
    g_font_big, g_font_ui = font, font
    testing.expect(t, im.FontAtlas_Build(io.Fonts))
    s: State
    append(&s.tabs, make_tab("Preview"))
    defer delete(s.tabs)
    defer preview_fixture_free_tab(&s.tabs[0])
    start_navigation(&s, `data:text/html,<body><p>Early content</p><script>var end=Date.now()+800;while(Date.now()<end){}</script>`)
    job := g_jobs[0]
    deadline := time.tick_now()
    for !bool(intrinsics.atomic_load(&job.preview.done)) && time.tick_since(deadline) < 5 * time.Second {
        time.sleep(time.Millisecond)
    }
    loading_test_frame(&s, -1, -1, false)
    testing.expect(t, s.tabs[0].loading && s.tabs[0].preview_visible)
    testing.expect(t, g_viewport_valid, "the loading page must reach the actual page painting branch")
    for !bool(intrinsics.atomic_load(&job.done)) do time.sleep(time.Millisecond)
    poll_jobs(&s)
    testing.expect(t, !s.tabs[0].loading && s.tabs[0].vm != nil)
    testing.expect_value(t, len(g_jobs), 0)
}
}
