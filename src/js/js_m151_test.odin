package js

// M151 — Intl (ECMA-402 aproximado, intl.odin).
//
// Entrou pela porta que o M150 abriu: com identificador livre lançando
// ReferenceError, `Intl is not defined` apareceu NOMEADO no gap-report em 4
// sites (bandcamp, stackoverflow, coingecko, zoom). Antes disso era invisível.
//
// O que estes testes guardam NÃO é conformidade com o CLDR — não temos ICU e
// nunca teremos. É o CONTRATO que o código real usa: os construtores existem,
// aceitam (locales, options), devolvem objeto com format/resolvedOptions, e o
// número sai com o separador do locale certo. Onde degradamos de propósito
// (nome de mês fora do inglês, colação por idioma, fuso ≠ UTC), há um teste
// dizendo QUAL é a degradação — para que uma mudança futura seja uma decisão,
// não um acidente.

import "core:testing"

// ── Intl.NumberFormat ────────────────────────────────────────────────────────

@(test)
m151_numberformat_separadores_por_locale :: proc(t: ^testing.T) {
    // O caso que motivou tudo: o mesmo número em en e pt-BR. Trocar `,` por `.`
    // não é cosmético — "1.234" lido como en-US é MIL VEZES menor.
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US').format(1234567.891)`).(string), "1,234,567.891")
    testing.expect_value(t, run(`new Intl.NumberFormat('pt-BR').format(1234567.891)`).(string), "1.234.567,891")
    testing.expect_value(t, run(`new Intl.NumberFormat('de-DE').format(1234.5)`).(string), "1.234,5")
}

@(test)
m151_numberformat_sem_new :: proc(t: ^testing.T) {
    // ECMA-402 permite chamar SEM `new` (e código real faz). Se só o `new`
    // funcionasse, metade dos sites continuaria quebrada.
    testing.expect_value(t, run(`Intl.NumberFormat('en-US').format(9876.5)`).(string), "9,876.5")
}

@(test)
m151_numberformat_moeda :: proc(t: ^testing.T) {
    // Preço é O uso de Intl em e-commerce. 2 casas por default no estilo currency.
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(1234.5)`).(string), "$1,234.50")
    // ⚠️ o separador entre número e símbolo é NBSP (U+00A0), não espaço comum —
    // é o que o CLDR manda e o que o Chrome devolve. Escrito como escape aqui de
    // propósito: com o caractere cru o teste passa mas ninguém enxerga a regra.
    testing.expect_value(t, run(`new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(1234.5)`).(string), "R$\u00a01.234,50")
    // símbolo DEPOIS nos locales europeus
    testing.expect_value(t, run(`new Intl.NumberFormat('de-DE',{style:'currency',currency:'EUR'}).format(1234.5)`).(string), "1.234,50\u00a0€")
}

@(test)
m151_numberformat_moeda_desconhecida_usa_o_codigo :: proc(t: ^testing.T) {
    // DEGRADAÇÃO DELIBERADA: sem tabela CLDR, moeda que não conhecemos sai com o
    // próprio código — que é o que o CLDR também faz. Melhor que símbolo errado.
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{style:'currency',currency:'XYZ'}).format(12)`).(string), "XYZ12.00")
}

@(test)
m151_numberformat_percent_e_casas :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{style:'percent'}).format(0.256)`).(string), "26%")
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{minimumFractionDigits:2}).format(5)`).(string), "5.00")
    // maximumFractionDigits é TETO, não fixo: zeros à direita são cortados
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{maximumFractionDigits:4}).format(1.5)`).(string), "1.5")
}

@(test)
m151_numberformat_sem_agrupamento :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{useGrouping:false}).format(1234567)`).(string), "1234567")
}

@(test)
m151_numberformat_compacto :: proc(t: ^testing.T) {
    // contador de views/likes — o uso mais comum de notation:'compact'
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{notation:'compact'}).format(1500)`).(string), "1.5K")
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US',{notation:'compact'}).format(2400000)`).(string), "2.4M")
}

@(test)
m151_numberformat_negativo_e_zero :: proc(t: ^testing.T) {
    // O sinal tem de ficar FORA do agrupamento (senão "-,123").
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US').format(-1234567)`).(string), "-1,234,567")
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US').format(0)`).(string), "0")
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US').format(999)`).(string), "999")
    testing.expect_value(t, run(`new Intl.NumberFormat('en-US').format(1000)`).(string), "1,000")
}

@(test)
m151_format_destacado_do_receiver :: proc(t: ^testing.T) {
    // `[1,2].map(nf.format)` PERDE o `this` — a spec resolve fazendo de `format`
    // uma função já ligada, e o idioma aparece em código real. Aqui a instância
    // viaja em fn.bound. Se este teste quebrar, o formato sai sem locale.
    src := `
        var nf = new Intl.NumberFormat('pt-BR');
        [1234.5, 9876].map(nf.format).join(' | ')
    `
    testing.expect_value(t, run(src).(string), "1.234,5 | 9.876")
}

@(test)
m151_resolved_options :: proc(t: ^testing.T) {
    src := `
        var r = new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).resolvedOptions();
        r.locale + "|" + r.style + "|" + r.currency + "|" + r.minimumFractionDigits
    `
    testing.expect_value(t, run(src).(string), "pt-BR|currency|BRL|2")
}

// ── Intl.DateTimeFormat ──────────────────────────────────────────────────────

@(test)
m151_datetimeformat_ordem_por_locale :: proc(t: ^testing.T) {
    // mm/dd nos EUA, dd/mm no resto — a diferença que muda o SENTIDO da data.
    src := `
        var d = new Date(Date.UTC(2026, 6, 23));
        new Intl.DateTimeFormat('en-US').format(d) + " | " + new Intl.DateTimeFormat('pt-BR').format(d)
    `
    testing.expect_value(t, run(src).(string), "7/23/2026 | 23/07/2026")
}

@(test)
m151_datetimeformat_mes_por_extenso :: proc(t: ^testing.T) {
    // DEGRADAÇÃO DELIBERADA: nomes de mês só em INGLÊS (sem CLDR). O teste fixa
    // isso para que passar a traduzir seja uma decisão consciente.
    src := `
        var d = new Date(Date.UTC(2026, 6, 23));
        new Intl.DateTimeFormat('en-US',{month:'long',day:'numeric',year:'numeric'}).format(d)
    `
    testing.expect_value(t, run(src).(string), "July 23, 2026")
}

@(test)
m151_datetimeformat_timezone_e_utc :: proc(t: ^testing.T) {
    // `Intl.DateTimeFormat().resolvedOptions().timeZone` é O idioma de detecção
    // de fuso na web. "UTC" não é chute: nossa Date É UTC (getTimezoneOffset()==0),
    // então esta resposta é CONSISTENTE com o que a engine sabe produzir.
    src := `
        var r = new Intl.DateTimeFormat().resolvedOptions();
        r.timeZone + "|" + r.calendar + "|" + (new Date().getTimezoneOffset())
    `
    testing.expect_value(t, run(src).(string), "UTC|gregory|0")
}

@(test)
m151_datetimeformat_hora :: proc(t: ^testing.T) {
    src := `
        var d = new Date(Date.UTC(2026, 6, 23, 14, 5, 9));
        new Intl.DateTimeFormat('en-US',{hour:'2-digit',minute:'2-digit'}).format(d)
    `
    testing.expect_value(t, run(src).(string), "14:05:09")
}

// ── demais construtores ──────────────────────────────────────────────────────

@(test)
m151_collator_ordena :: proc(t: ^testing.T) {
    // DEGRADAÇÃO: comparação por code point, não colação por idioma. O uso que
    // importa (ordenar lista da UI) funciona.
    src := `
        var c = new Intl.Collator('en');
        ['banana','abacaxi','cereja'].sort(c.compare).join(',')
    `
    testing.expect_value(t, run(src).(string), "abacaxi,banana,cereja")
}

@(test)
m151_collator_sensitivity_base_ignora_caixa :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Intl.Collator('en',{sensitivity:'base'}).compare('ABC','abc')`), Value(f64(0)))
}

@(test)
m151_plural_rules :: proc(t: ^testing.T) {
    src := `
        var p = new Intl.PluralRules('en-US');
        p.select(0) + "," + p.select(1) + "," + p.select(2)
    `
    testing.expect_value(t, run(src).(string), "other,one,other")
    // pt trata 0 e 1 como singular ("0 dia"), diferente do inglês
    testing.expect_value(t, run(`new Intl.PluralRules('pt-BR').select(0)`).(string), "one")
    // idioma SEM plural
    testing.expect_value(t, run(`new Intl.PluralRules('ja').select(5)`).(string), "other")
}

@(test)
m151_relative_time_format :: proc(t: ^testing.T) {
    src := `
        var r = new Intl.RelativeTimeFormat('en', {numeric:'auto'});
        r.format(-1,'day') + "|" + r.format(2,'hour') + "|" + r.format(-3,'days')
    `
    testing.expect_value(t, run(src).(string), "yesterday|in 2 hours|3 days ago")
}

@(test)
m151_list_format :: proc(t: ^testing.T) {
    // vírgula de Oxford a partir de 3 itens (regra do inglês)
    testing.expect_value(t, run(`new Intl.ListFormat('en').format(['a','b'])`).(string), "a and b")
    testing.expect_value(t, run(`new Intl.ListFormat('en').format(['a','b','c'])`).(string), "a, b, and c")
    testing.expect_value(t, run(`new Intl.ListFormat('en',{type:'disjunction'}).format(['a','b'])`).(string), "a or b")
}

@(test)
m151_locale :: proc(t: ^testing.T) {
    src := `
        var l = new Intl.Locale('pt-BR');
        l.language + "|" + l.region + "|" + l.baseName + "|" + String(l)
    `
    testing.expect_value(t, run(src).(string), "pt|BR|pt-BR|pt-BR")
}

@(test)
m151_get_canonical_e_supported_locales :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Intl.getCanonicalLocales('pt-BR').join(',')`).(string), "pt-BR")
    testing.expect_value(t, run(`Intl.getCanonicalLocales(['en','fr']).length`), Value(f64(2)))
    // supportedLocalesOf devolve o que pediram: dizer que NÃO suportamos faria o
    // site abortar a feature inteira, e nós de fato formatamos em qualquer locale.
    testing.expect_value(t, run(`Intl.NumberFormat.supportedLocalesOf(['de-DE']).join(',')`).(string), "de-DE")
}

// ── contrato do objeto Intl ──────────────────────────────────────────────────

@(test)
m151_intl_existe_e_nao_lanca :: proc(t: ^testing.T) {
    // A regressão que este marco fecha: antes do M151 isto era ReferenceError.
    src := `
        var faltando = [];
        var nomes = ["NumberFormat","DateTimeFormat","Collator","PluralRules",
                     "RelativeTimeFormat","ListFormat","Locale"];
        for (var i = 0; i < nomes.length; i++) { if (typeof Intl[nomes[i]] !== "function") faltando.push(nomes[i]) }
        faltando.join(",")
    `
    testing.expect_value(t, run(src).(string), "")
}

@(test)
m151_instanceof_responde :: proc(t: ^testing.T) {
    // `x instanceof Intl.NumberFormat` aparece em código de lib; sem prototype
    // ligado o instanceof mentiria em silêncio.
    testing.expect(t, truthy(run(`new Intl.NumberFormat('en') instanceof Intl.NumberFormat`)),
        "instância deve ser instanceof do próprio construtor")
    testing.expect(t, !truthy(run(`new Intl.NumberFormat('en') instanceof Intl.Collator`)),
        "e NÃO de outro construtor")
}

@(test)
m151_typeof_intl_deixou_de_ser_undefined :: proc(t: ^testing.T) {
    // O guarda de feature que os sites usam antes de tocar em Intl.
    testing.expect_value(t, run(`typeof Intl`).(string), "object")
    testing.expect_value(t, run(`(typeof Intl !== "undefined" && typeof Intl.NumberFormat === "function") ? "ok" : "sem"`).(string), "ok")
}

@(test)
m151_to_locale_string_de_number_passou_a_agrupar :: proc(t: ^testing.T) {
    // Era "aproximação sem separadores" (devolvia o toString cru), então
    // `(1234.5).toLocaleString('pt-BR')` saía "1234.5". Agora delega ao mesmo
    // formatador do Intl — é o caminho mais usado de todos, porque não exige
    // que o site conheça a API.
    testing.expect_value(t, run(`(1234567).toLocaleString('en-US')`).(string), "1,234,567")
    testing.expect_value(t, run(`(1234.5).toLocaleString('pt-BR')`).(string), "1.234,5")
    testing.expect_value(t, run(`(1234.5).toLocaleString('en-US',{style:'currency',currency:'USD'})`).(string), "$1,234.50")
}

// ── gaps que o PRÓPRIO M151 destapou ─────────────────────────────────────────
//
// O padrão de sempre: servir uma camada faz o bundle avançar e bater na
// seguinte. Assim que `Intl` passou a existir, o bandcamp pediu
// `Intl.supportedValuesOf` e o coingecko pediu `FinalizationRegistry` e
// `HTMLMetaElement` — três nomes que ANTES estavam atrás de um erro anterior.

@(test)
m151_supported_values_of :: proc(t: ^testing.T) {
    // O site faz `typeof Intl !== "undefined"` e daí assume a API INTEIRA — meia
    // API é pior que nenhuma, porque passa no guarda e quebra depois.
    testing.expect(t, truthy(run(`Intl.supportedValuesOf('currency').indexOf('BRL') >= 0`)),
        "supportedValuesOf('currency') deve listar as moedas que sabemos formatar")
    // só UTC: é o único fuso que nossa Date sabe produzir (date.odin)
    testing.expect_value(t, run(`Intl.supportedValuesOf('timeZone').join(',')`).(string), "UTC")
    // chave desconhecida → array vazio, não exceção
    testing.expect_value(t, run(`Intl.supportedValuesOf('naoExiste').length`), Value(f64(0)))
}

@(test)
m151_weakref_e_finalization_registry :: proc(t: ^testing.T) {
    // DEGRADAÇÃO CONFORME (não remendo): a spec não garante que o alvo seja
    // coletado nem que o callback de finalização rode. Nunca coletamos, então
    // deref() sempre devolve o alvo e o registry nunca chama de volta — que é
    // comportamento válido. Código que usa isto como cache-de-oportunidade
    // continua correto.
    src := `
        var alvo = {x: 7};
        var r = new WeakRef(alvo);
        var fr = new FinalizationRegistry(function(){});
        fr.register(alvo, "tag");
        fr.unregister(alvo);
        (r.deref() === alvo) + "|" + r.deref().x
    `
    testing.expect_value(t, run(src).(string), "true|7")
    testing.expect_value(t, run(`typeof WeakRef + "|" + typeof FinalizationRegistry`).(string), "function|function")
}
