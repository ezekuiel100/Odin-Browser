package css

import "core:testing"

@(test)
layers_parser_list_and_reopening :: proc(t: ^testing.T) {
    // A lista fixa a ordem mesmo quando os blocos aparecem ao contrário.
    rules, _ := parse(`
        @layer reset, theme, utilities;
        @layer utilities { p { color: blue } }
        @layer theme { p { color: green } }
        @layer reset { p { color: red } }
        @layer theme { p { color: purple } }
        @layer reset, utilities;
        @layer utilities { p { color: black } }
    `)
    defer free_rules(&rules)
    testing.expect_value(t, len(rules), 5)
    if len(rules) != 5 do return
    expected := []int{2, 1, 0, 1, 2}
    for rank, i in expected do testing.expect_value(t, rules[i].layer_rank, rank)
    testing.expect(t, layer_compare(rules[0], rules[2], false) > 0,
                   "a lista prevalece sobre a ordem dos blocos")
    testing.expect_value(t, layer_compare(rules[1], rules[3], false), 0)
    testing.expect(t, rules[3].order > rules[1].order,
                   "reabertura preserva a layer, mas avanca a ordem de origem")
}

@(test)
layers_parser_nested_parent_and_children :: proc(t: ^testing.T) {
    rules, _ := parse(`
        @layer outer, later;
        @layer outer {
            @layer first, second;
            p { color: red }
            @layer second { p { color: green } }
            @layer first { p { color: blue } }
        }
        @layer later { p { color: black } }
        @layer outer.first { p { color: purple } }
        @layer outer { @layer second { p { color: orange } } }
    `)
    defer free_rules(&rules)
    testing.expect_value(t, len(rules), 6)
    if len(rules) != 6 do return
    // Pos-ordem: first=0, second=1, declaracoes diretas de outer=2, later=3.
    expected := []int{2, 1, 0, 3, 0, 1}
    for rank, i in expected do testing.expect_value(t, rules[i].layer_rank, rank)
    testing.expect(t, layer_compare(rules[0], rules[1], false) > 0,
                   "declaracao direta do pai vence os filhos em normal")
    testing.expect(t, layer_compare(rules[0], rules[1], true) < 0,
                   "filhos vencem o pai em important")
    testing.expect(t, layer_compare(rules[3], rules[0], false) > 0,
                   "a proxima layer raiz vem depois de toda a subarvore")
    testing.expect_value(t, layer_compare(rules[2], rules[4], false), 0)
    testing.expect_value(t, layer_compare(rules[1], rules[5], false), 0)
}

@(test)
layers_parser_anonymous_are_distinct :: proc(t: ^testing.T) {
    rules, _ := parse(`
        @layer { p { color: red } }
        @layer named { p { color: green } }
        @layer { p { color: blue } }
        @layer named {
            @layer { p { color: purple } }
            @layer { p { color: orange } }
        }
        @layer named { p { color: black } }
    `)
    defer free_rules(&rules)
    testing.expect_value(t, len(rules), 6)
    if len(rules) != 6 do return
    expected := []int{0, 3, 4, 1, 2, 3}
    for rank, i in expected do testing.expect_value(t, rules[i].layer_rank, rank)
    testing.expect(t, rules[0].layer_rank != rules[2].layer_rank,
                   "cada bloco anonimo raiz tem identidade propria")
    testing.expect(t, rules[3].layer_rank != rules[4].layer_rank,
                   "blocos anonimos irmaos tambem sao distintos")
    testing.expect_value(t, layer_compare(rules[1], rules[5], false), 0)
}

@(test)
layers_parser_important_inversion_and_unlayered :: proc(t: ^testing.T) {
    rules, _ := parse(`
        @layer first, second;
        @layer first { p { color: red !important } }
        @layer second { p { color: green !important } }
        p { color: blue !important }
    `)
    defer free_rules(&rules)
    testing.expect_value(t, len(rules), 3)
    if len(rules) != 3 do return
    testing.expect_value(t, rules[0].layer_rank, 0)
    testing.expect_value(t, rules[1].layer_rank, 1)
    testing.expect_value(t, rules[2].layer_rank, LAYER_UNLAYERED)
    for i := 0; i < len(rules); i += 1 {
        for j := 0; j < len(rules); j += 1 {
            normal := layer_compare(rules[i], rules[j], false)
            important := layer_compare(rules[i], rules[j], true)
            testing.expect_value(t, important, -normal)
            if i < j {
                testing.expect(t, normal < 0, "normal: ultima layer e depois unlayered vencem")
                testing.expect(t, important > 0, "important: primeira layer vence inclusive unlayered")
            }
        }
    }
}

@(test)
layers_parser_registered_stays_fallback :: proc(t: ^testing.T) {
    rules, _ := parse(`
        @layer first, second;
        @layer first {
            @property --accent { syntax: "<color>"; inherits: false; initial-value: red; }
            p { --accent: blue }
        }
        @layer second { p { --accent: green } }
        p { --accent: black }
    `)
    defer free_rules(&rules)
    testing.expect_value(t, len(rules), 4)
    if len(rules) != 4 do return
    testing.expect_value(t, rules[0].layer_rank, LAYER_REGISTERED)
    testing.expect_value(t, rules[0].decls["--accent"], "red")
    testing.expect_value(t, rules[1].layer_rank, 0)
    testing.expect_value(t, rules[2].layer_rank, 1)
    testing.expect_value(t, rules[3].layer_rank, LAYER_UNLAYERED)
    for important in ([]bool{false, true}) {
        for i := 1; i < len(rules); i += 1 {
            testing.expect(t, layer_compare(rules[i], rules[0], important) > 0,
                           "regra real sempre vence o fallback registrado")
            testing.expect(t, layer_compare(rules[0], rules[i], important) < 0,
                           "fallback nao sobe de prioridade com important")
        }
        testing.expect_value(t, layer_compare(rules[0], rules[0], important), 0)
    }
}
