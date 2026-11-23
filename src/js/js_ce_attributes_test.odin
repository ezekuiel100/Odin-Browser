package js

import "core:strings"
import "core:testing"
import dom "../dom"
import htmlp "../html"

@(private = "file")
ce_attributes_eval :: proc(t: ^testing.T, source: string) -> string {
    root := htmlp.parse("<html><body><x-loader bundlename='feed' loading='lazy'></x-loader></body></html>")
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    result := vm_run(vm, source)
    testing.expect(t, !vm.throwing)
    testing.expect_value(t, vm.uncaught_total, 0)
    text, _ := result.(string)
    return strings.clone(text, context.temp_allocator)
}

@(test)
ce_attributes_reddit_loader_before_connect :: proc(t: ^testing.T) {
    testing.expect_value(t, ce_attributes_eval(t, `
        var log = [], finalized = 0;
        class Reactive extends HTMLElement {
            static get observedAttributes() { finalized++; return ['bundlename','loading']; }
            attributeChangedCallback(name, old, value) {
                if(name === 'bundlename') this.bundleName = value;
                else this.loading = value;
                log.push(name + ':' + old + ':' + value);
            }
        }
        class Loader extends Reactive {
            connectedCallback() {
                if(!this.bundleName) throw Error('Unspecified bundle.');
                log.push('load:' + this.bundleName + ':' + this.loading);
            }
        }
        customElements.define('x-loader', Loader);
        log.join('|') + '|' + finalized;
    `), "bundlename:null:feed|loading:null:lazy|load:feed:lazy|1")
}

@(test)
ce_attributes_updates_removal_and_filtering :: proc(t: ^testing.T) {
    testing.expect_value(t, ce_attributes_eval(t, `
        var log = [];
        class El extends HTMLElement {
            static get observedAttributes(){ return ['data-value']; }
            attributeChangedCallback(n,o,v){ log.push(n + ':' + o + ':' + v); }
        }
        customElements.define('x-values', El);
        var e = document.createElement('x-values');
        e.setAttribute('other', 'ignored');
        e.dataset.value = 'a';
        e.setAttribute('data-value', 'a');
        e.setAttribute('data-value', 'b');
        e.removeAttribute('data-value');
        e.removeAttribute('data-value');
        log.join('|');
    `), "data-value:null:a|data-value:a:a|data-value:a:b|data-value:b:null")
}

@(test)
ce_attributes_snapshot_and_reentrant_changes :: proc(t: ^testing.T) {
    testing.expect_value(t, ce_attributes_eval(t, `
        var log = [], observed = ['bundlename','loading'];
        class Loader extends HTMLElement {
            static get observedAttributes(){return observed;}
            attributeChangedCallback(n,o,v) {
                log.push(n+':'+o+':'+v);
                if(n === 'bundlename') this.setAttribute('loading', 'eager');
            }
            connectedCallback(){log.push('connected');}
        }
        customElements.define('x-loader', Loader);
        observed.push('other');
        var e = document.getElementsByTagName('x-loader')[0];
        e.setAttribute('other', 'ignored');
        log.join('|');
    `), "bundlename:null:feed|loading:lazy:eager|loading:null:lazy|connected")
}
