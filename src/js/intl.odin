package js

// Intl (M151) — ECMA-402, na medida em que um navegador sem ICU consegue.
//
// Entrou porque o M150 fez identificador livre lançar ReferenceError, e aí
// `Intl is not defined` virou o global mais faltante do corpus depois dos que já
// servi: 4 sites (bandcamp, stackoverflow, coingecko, zoom).
//
// ── O QUE ISTO É E O QUE NÃO É ───────────────────────────────────────────────
// ECMA-402 de verdade é uma fachada para o ICU: dezenas de MB de dados CLDR por
// locale (nomes de mês, regras de plural por idioma, colação por idioma, fusos
// horários). Não temos nada disso e não vamos ter. O que dá para fazer com
// honestidade é cobrir a ESTRUTURA da API — os construtores existem, aceitam
// (locales, options), devolvem objetos com format/resolvedOptions, e o
// `supportedLocalesOf` responde — com uma tabela PEQUENA de separadores e
// símbolos que acerta os casos que importam para as páginas que renderizamos
// (en, pt-BR, es, de, fr).
//
// A escolha de projeto: **é melhor formatar 1234.5 como "1.234,50" em pt-BR do
// que lançar**. Um site que faz `new Intl.NumberFormat('pt-BR',{style:'currency',
// currency:'BRL'}).format(x)` para montar um preço hoje MORRE; com isto ele
// mostra "R$ 1.234,50". Onde não sabemos (nome de mês em japonês, colação de
// tcheco, fuso que não seja UTC), degradamos para algo previsível em vez de
// inventar — e está anotado em cada ponto.
//
// ⚠️ FUSO: nossa Date é UTC pura (date.odin, getTimezoneOffset()==0), então
// `resolvedOptions().timeZone` devolve "UTC". É a resposta CONSISTENTE com o
// resto do motor — devolver o fuso real da máquina faria o site formatar horas
// que a nossa própria Date não sabe produzir.

import "core:fmt"
import "core:strings"

// ⚠️ O separador entre número e símbolo de moeda é NBSP (U+00A0), NÃO espaço
// comum — é o que o CLDR manda e o que o Chrome produz ("1.234,50 €").
// Está numa CONSTANTE NOMEADA porque, escrito cru, é um caractere invisível: o
// primeiro teste que escrevi esperava espaço comum e falhou com uma mensagem em
// que os dois lados pareciam idênticos — só o charCodeAt (160) resolveu. Um
// caractere que ninguém enxerga não pode ficar solto no meio do código.
@(private = "file")
NBSP :: "\u00a0"

// ── tabela de locales (pequena de propósito) ─────────────────────────────────

@(private = "file")
Locale_Fmt :: struct {
    group:   string, // separador de milhar
    decimal: string, // separador decimal
}

// Casado pelo SUBTAG PRIMÁRIO ("pt-BR" → "pt"). O default é o padrão en.
@(private = "file")
locale_fmt :: proc(locale: string) -> Locale_Fmt {
    prim := locale
    if i := strings.index_byte(prim, '-'); i >= 0 do prim = prim[:i]
    if i := strings.index_byte(prim, '_'); i >= 0 do prim = prim[:i]
    switch prim {
    case "pt", "es", "de", "it", "nl", "id", "tr", "da", "vi", "ro", "el", "ca":
        return {group = ".", decimal = ","}
    case "fr", "ru", "pl", "cs", "sv", "nb", "no", "fi", "uk", "hu", "lv", "lt":
        return {group = NBSP, decimal = ","} // separador de milhar é NBSP nestes locales
    case "ch":
        return {group = "'", decimal = "."}
    }
    return {group = ",", decimal = "."} // en e todo o resto
}

// Símbolo da moeda + se vem ANTES do número. Fora desta lista usamos o próprio
// código ("XYZ 12,00") — que é exatamente o que o CLDR faz para moeda que ele
// não conhece, então aqui a degradação é a resposta CERTA, não um remendo.
@(private = "file")
currency_symbol :: proc(code: string) -> (sym: string, prefix: bool) {
    switch code {
    case "USD", "CAD", "AUD", "NZD", "MXN", "ARS", "CLP", "COP": return "$", true
    case "BRL": return "R$", true
    case "EUR": return "€", true
    case "GBP": return "£", true
    case "JPY", "CNY": return "¥", true
    case "INR": return "₹", true
    case "KRW": return "₩", true
    case "RUB": return "₽", true
    case "TRY": return "₺", true
    case "CHF": return "CHF", true
    case "":    return "", true
    }
    return code, true
}

// Locales que põem o símbolo DEPOIS ("1.234,50 €"). Regra de moeda é por
// locale, não por moeda — daí a checagem separada.
@(private = "file")
symbol_after :: proc(locale: string) -> bool {
    prim := locale
    if i := strings.index_byte(prim, '-'); i >= 0 do prim = prim[:i]
    switch prim {
    case "de", "fr", "es", "it", "nl", "pl", "cs", "sv", "fi", "pt":
        return prim != "pt" // pt-BR usa "R$ 1.234,50" (prefixo); os europeus, sufixo
    }
    return false
}

// ── formatação numérica ─────────────────────────────────────────────────────

@(private = "file")
Num_Opts :: struct {
    locale:   string,
    style:    string, // "decimal" | "percent" | "currency"
    currency: string,
    min_fd:   int,
    max_fd:   int,
    grouping: bool,
    notation_compact: bool,
}

// Agrupa a parte inteira de 3 em 3 e troca o ponto decimal. Recebe o número JÁ
// arredondado como texto "-1234.5" (saída de %.*f), que é o formato em que o
// arredondamento da libc já resolveu meio-caso para nós.
@(private = "file")
group_digits :: proc(s: string, f: Locale_Fmt, grouping: bool) -> string {
    neg := len(s) > 0 && s[0] == '-'
    body := neg ? s[1:] : s
    int_part := body
    frac := ""
    if dot := strings.index_byte(body, '.'); dot >= 0 {
        int_part = body[:dot]
        frac = body[dot + 1:]
    }
    b := strings.builder_make(context.temp_allocator)
    if neg do strings.write_string(&b, "-")
    if grouping && len(int_part) > 3 {
        // primeiro grupo tem o resto da divisão por 3 (1234567 → "1" + "234" + "567")
        head := len(int_part) % 3
        if head == 0 do head = 3
        strings.write_string(&b, int_part[:head])
        for i := head; i < len(int_part); i += 3 {
            strings.write_string(&b, f.group)
            strings.write_string(&b, int_part[i:i + 3])
        }
    } else {
        strings.write_string(&b, int_part)
    }
    if len(frac) > 0 {
        strings.write_string(&b, f.decimal)
        strings.write_string(&b, frac)
    }
    return strings.to_string(b)
}

// notation:"compact" — 1.2K / 3.4M / 5.6B. Usado por contador de views/likes,
// que é justamente o que os sites do corpus fazem com Intl.
@(private = "file")
compact_parts :: proc(x: f64) -> (val: f64, suffix: string) {
    ax := x < 0 ? -x : x
    switch {
    case ax >= 1e12: return x / 1e12, "T"
    case ax >= 1e9:  return x / 1e9,  "B"
    case ax >= 1e6:  return x / 1e6,  "M"
    case ax >= 1e3:  return x / 1e3,  "K"
    }
    return x, ""
}

@(private = "file")
format_number :: proc(x_in: f64, o: Num_Opts) -> string {
    if x_in != x_in do return "NaN"
    x := x_in
    if o.style == "percent" do x *= 100

    f := locale_fmt(o.locale)
    suffix := ""
    if o.notation_compact {
        x, suffix = compact_parts(x)
    }

    // casas decimais: o default depende do estilo (moeda pede 2; decimal, até 3
    // mas sem zeros à toa — daí o "trim" abaixo, que é o que o CLDR chama de
    // minimumFractionDigits 0 / maximumFractionDigits 3).
    min_fd, max_fd := o.min_fd, o.max_fd
    if min_fd < 0 { // não informado
        min_fd = o.style == "currency" ? 2 : 0
        if o.notation_compact do min_fd = 0
    }
    if max_fd < 0 {
        max_fd = o.style == "currency" ? 2 : 3
        if o.notation_compact do max_fd = 1
        if o.style == "percent" do max_fd = 0
    }
    if max_fd < min_fd do max_fd = min_fd

    s := fmt.tprintf("%.*f", max_fd, x)
    // corta zeros à direita até min_fd (maximumFractionDigits é TETO, não fixo)
    if max_fd > min_fd {
        if dot := strings.index_byte(s, '.'); dot >= 0 {
            last := len(s)
            for last > dot + 1 + min_fd && s[last - 1] == '0' do last -= 1
            if last == dot + 1 do last = dot // sobrou só o ponto
            s = s[:last]
        }
    }

    out := group_digits(s, f, o.grouping)
    if suffix != "" do out = strings.concatenate({out, suffix}, context.temp_allocator)

    switch o.style {
    case "percent":
        return strings.concatenate({out, "%"}, context.temp_allocator)
    case "currency":
        sym, _ := currency_symbol(o.currency)
        if sym == "" do return out
        if symbol_after(o.locale) {
            return strings.concatenate({out, NBSP, sym}, context.temp_allocator)
        }
        // "R$ 1.234,50" (com espaço) vs "$1,234.50" (sem) — o CLDR separa por locale
        sep := locale_fmt(o.locale).decimal == "," ? NBSP : ""
        return strings.concatenate({sym, sep, out}, context.temp_allocator)
    }
    return out
}

// ── leitura dos argumentos (locales, options) ───────────────────────────────

// `locales` pode ser string, array de strings, ou ausente. Pegamos o primeiro —
// não temos negociação de locale, e o 1º é o preferido do chamador.
@(private = "file")
first_locale :: proc(vm: ^Interp, v: Value) -> string {
    switch t in v {
    case string:
        return t
    case ^Array:
        if len(t.items) > 0 do if s, ok := t.items[0].(string); ok do return s
    case bool, f64, JS_Null, ^Object, ^Function, ^Regex, ^Collection, ^Symbol, ^BigInt:
        // objeto Intl.Locale ou similar: tenta o toString
        if _, ok := v.(^Object); ok do return key_string(vm, v)
    }
    return "en-US"
}

@(private = "file")
opt_str :: proc(vm: ^Interp, o: Value, key: string, def: string) -> string {
    obj, ok := o.(^Object); if !ok do return def
    v, has := obj.props[key]; if !has || v == nil do return def
    return key_string(vm, v)
}

@(private = "file")
opt_int :: proc(o: Value, key: string, def: int) -> int {
    obj, ok := o.(^Object); if !ok do return def
    v, has := obj.props[key]; if !has || v == nil do return def
    return as_int(v)
}

@(private = "file")
opt_bool :: proc(o: Value, key: string, def: bool) -> bool {
    obj, ok := o.(^Object); if !ok do return def
    v, has := obj.props[key]; if !has || v == nil do return def
    // useGrouping aceita false, "auto", "always", "min2" (ES2023). Só "false"
    // e false desligam.
    if s, sok := v.(string); sok do return s != "false"
    return truthy(v)
}

// Guarda as opções lidas em props "#" (chave privada: não enumera, não vaza no
// JSON.stringify — mesma convenção do "#t" da Date).
@(private = "file")
store_num_opts :: proc(vm: ^Interp, inst: ^Object, o: Num_Opts) {
    inst.props["#loc"]   = o.locale
    inst.props["#style"] = o.style
    inst.props["#cur"]   = o.currency
    inst.props["#minfd"] = f64(o.min_fd)
    inst.props["#maxfd"] = f64(o.max_fd)
    inst.props["#grp"]   = o.grouping
    inst.props["#cmp"]   = o.notation_compact
}

@(private = "file")
load_num_opts :: proc(inst: ^Object) -> Num_Opts {
    o := Num_Opts{locale = "en-US", style = "decimal", min_fd = -1, max_fd = -1, grouping = true}
    if v, ok := inst.props["#loc"].(string);   ok do o.locale = v
    if v, ok := inst.props["#style"].(string); ok do o.style = v
    if v, ok := inst.props["#cur"].(string);   ok do o.currency = v
    if v, ok := inst.props["#minfd"].(f64);    ok do o.min_fd = int(v)
    if v, ok := inst.props["#maxfd"].(f64);    ok do o.max_fd = int(v)
    if v, ok := inst.props["#grp"].(bool);     ok do o.grouping = v
    if v, ok := inst.props["#cmp"].(bool);     ok do o.notation_compact = v
    return o
}

// O receiver das nativas de instância vem por DOIS caminhos: `nf.format(x)` põe
// a instância em `this`; `[1,2].map(nf.format)` a perde. A spec resolve fazendo
// de `format` um getter que devolve função JÁ ligada — e o idioma detached é
// comum o bastante (o `.map(fmt.format)` aparece em código real) para valer o
// cuidado. Aqui a instância viaja em `fn.bound`, que a chamada expõe em
// `vm.native_bound`, então funciona nos dois casos.
@(private = "file")
receiver :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := this.(^Object); ok && o.props != nil {
        if _, has := o.props["#loc"]; has do return o
        if _, has := o.props["#kind"]; has do return o
    }
    if o, ok := vm.native_bound.(^Object); ok do return o
    return nil
}

// Cria um método de instância cuja `bound` é a própria instância.
@(private = "file")
mk_bound :: proc(vm: ^Interp, inst: ^Object, fn: Native_Fn) -> ^Function {
    f := mk_native(vm, fn)
    f.bound = inst
    return f
}

// ── Intl.NumberFormat ───────────────────────────────────────────────────────

@(private = "file")
nf_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := receiver(vm, this)
    if inst == nil do return own_str(vm, key_string(vm, arg(a, 0)))
    return own_str(vm, format_number(to_number(vm, arg(a, 0)), load_num_opts(inst)))
}

// formatToParts: devolve [{type,value}]. Não fatiamos de verdade (precisaria do
// formatador por partes); entregamos UMA parte com o texto inteiro, marcada como
// "literal". Código que só concatena as partes continua certo; código que filtra
// por type=="currency" não acha nada — e isso é preferível a mentir o tipo.
@(private = "file")
nf_format_to_parts :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    txt := nf_format(vm, this, a)
    arr := new_array(vm)
    part := new_object(vm)
    part.props["type"]  = own_str(vm, "literal")
    part.props["value"] = txt
    append(&arr.items, part)
    return arr
}

@(private = "file")
nf_resolved :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := new_object(vm)
    inst := receiver(vm, this)
    n := inst != nil ? load_num_opts(inst) : Num_Opts{locale = "en-US", style = "decimal", min_fd = -1, max_fd = -1, grouping = true}
    o.props["locale"]           = own_str(vm, n.locale)
    o.props["numberingSystem"]  = own_str(vm, "latn")
    o.props["style"]            = own_str(vm, n.style)
    if n.currency != "" do o.props["currency"] = own_str(vm, n.currency)
    min_default := n.style == "currency" ? 2 : 0
    o.props["minimumFractionDigits"] = f64(n.min_fd < 0 ? min_default : n.min_fd)
    max_default := n.style == "currency" ? 2 : 3
    o.props["maximumFractionDigits"] = f64(n.max_fd < 0 ? max_default : n.max_fd)
    o.props["useGrouping"]      = n.grouping
    o.props["notation"]         = own_str(vm, n.notation_compact ? "compact" : "standard")
    return o
}

@(private = "file")
intl_number_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    o := Num_Opts{
        locale   = first_locale(vm, arg(a, 0)),
        style    = opt_str(vm, arg(a, 1), "style", "decimal"),
        currency = opt_str(vm, arg(a, 1), "currency", ""),
        min_fd   = opt_int(arg(a, 1), "minimumFractionDigits", -1),
        max_fd   = opt_int(arg(a, 1), "maximumFractionDigits", -1),
        grouping = opt_bool(arg(a, 1), "useGrouping", true),
        notation_compact = opt_str(vm, arg(a, 1), "notation", "standard") == "compact",
    }
    store_num_opts(vm, inst, o)
    inst.props["format"]          = mk_bound(vm, inst, nf_format)
    inst.props["formatToParts"]   = mk_bound(vm, inst, nf_format_to_parts)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, nf_resolved)
    for k in ([?]string{"format", "formatToParts", "resolvedOptions"}) do mark_non_enumerable(inst, k)
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.DateTimeFormat ─────────────────────────────────────────────────────
//
// Sem CLDR não há nome de mês/dia por idioma. Servimos os nomes em INGLÊS
// (short e long) e, para os demais locales, caímos no numérico do próprio
// locale (dd/mm/aaaa vs mm/dd/aaaa) — que é a parte que realmente muda o
// sentido da data e que dá para acertar sem tabela.

@(private = "file")
MONTHS_LONG := [?]string{"January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"}
@(private = "file")
MONTHS_SHORT := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
@(private = "file")
DAYS_LONG := [?]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file")
DAYS_SHORT := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

// Ordem dia/mês: en-US é mm/dd/aaaa; praticamente todo o resto é dd/mm/aaaa.
@(private = "file")
month_first :: proc(locale: string) -> bool {
    return strings.has_prefix(locale, "en-US") || locale == "en"
}

@(private = "file")
dtf_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := receiver(vm, this)
    locale := "en-US"
    want_date, want_time := true, false
    long_month, short_month, want_weekday := false, false, false
    if inst != nil {
        if v, ok := inst.props["#loc"].(string); ok do locale = v
        if v, ok := inst.props["#wdate"].(bool); ok do want_date = v
        if v, ok := inst.props["#wtime"].(bool); ok do want_time = v
        if v, ok := inst.props["#mlong"].(bool); ok do long_month = v
        if v, ok := inst.props["#mshort"].(bool); ok do short_month = v
        if v, ok := inst.props["#wday"].(bool); ok do want_weekday = v
    }

    // sem argumento, formata AGORA (spec)
    t := arg(a, 0) == nil ? date_now_ms() : date_t(arg(a, 0))
    if t != t do t = to_number(vm, arg(a, 0))
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)

    b := strings.builder_make(context.temp_allocator)
    if want_date {
        if want_weekday {
            wd := p.wday
            strings.write_string(&b, long_month ? DAYS_LONG[wd] : DAYS_SHORT[wd])
            strings.write_string(&b, ", ")
        }
        if long_month || short_month {
            mn := long_month ? MONTHS_LONG[p.month - 1] : MONTHS_SHORT[p.month - 1]
            if month_first(locale) {
                fmt.sbprintf(&b, "%s %d, %d", mn, p.day, p.year)
            } else {
                fmt.sbprintf(&b, "%d %s %d", p.day, mn, p.year)
            }
        } else if month_first(locale) {
            fmt.sbprintf(&b, "%d/%d/%d", p.month, p.day, p.year)
        } else {
            fmt.sbprintf(&b, "%02d/%02d/%d", p.day, p.month, p.year)
        }
    }
    if want_time {
        if want_date do strings.write_string(&b, ", ")
        fmt.sbprintf(&b, "%02d:%02d:%02d", p.hour, p.min, p.sec)
    }
    return own_str(vm, strings.to_string(b))
}

@(private = "file")
dtf_resolved :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := new_object(vm)
    inst := receiver(vm, this)
    locale := "en-US"
    if inst != nil do if v, ok := inst.props["#loc"].(string); ok do locale = v
    o.props["locale"]          = own_str(vm, locale)
    o.props["calendar"]        = own_str(vm, "gregory")
    o.props["numberingSystem"] = own_str(vm, "latn")
    // ⚠️ "UTC" não é chute: nossa Date É UTC (getTimezoneOffset()==0). Devolver o
    // fuso real da máquina faria o site formatar horas que a nossa Date não
    // produz. `Intl.DateTimeFormat().resolvedOptions().timeZone` é O idioma de
    // detecção de fuso na web — por isso ele responde, em vez de faltar.
    o.props["timeZone"]        = own_str(vm, "UTC")
    return o
}

@(private = "file")
dtf_format_to_parts :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    txt := dtf_format(vm, this, a)
    arr := new_array(vm)
    part := new_object(vm)
    part.props["type"]  = own_str(vm, "literal")
    part.props["value"] = txt
    append(&arr.items, part)
    return arr
}

@(private = "file")
intl_datetime_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    opts := arg(a, 1)
    inst.props["#loc"] = first_locale(vm, arg(a, 0))
    month := opt_str(vm, opts, "month", "")
    // Quais campos o chamador pediu. Sem options, o default da spec é só a DATA.
    has_date := month != "" || opt_str(vm, opts, "day", "") != "" ||
                opt_str(vm, opts, "year", "") != "" || opt_str(vm, opts, "dateStyle", "") != ""
    has_time := opt_str(vm, opts, "hour", "") != "" || opt_str(vm, opts, "minute", "") != "" ||
                opt_str(vm, opts, "second", "") != "" || opt_str(vm, opts, "timeStyle", "") != ""
    if !has_date && !has_time do has_date = true
    inst.props["#wdate"]  = has_date
    inst.props["#wtime"]  = has_time
    inst.props["#mlong"]  = month == "long"
    inst.props["#mshort"] = month == "short"
    inst.props["#wday"]   = opt_str(vm, opts, "weekday", "") != ""
    inst.props["format"]          = mk_bound(vm, inst, dtf_format)
    inst.props["formatToParts"]   = mk_bound(vm, inst, dtf_format_to_parts)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, dtf_resolved)
    for k in ([?]string{"format", "formatToParts", "resolvedOptions"}) do mark_non_enumerable(inst, k)
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.Collator ───────────────────────────────────────────────────────────
//
// Colação de verdade é por idioma (em sueco 'ä' vem depois de 'z'; em alemão,
// junto de 'a'). Sem CLDR fazemos comparação por CODE POINT, com a opção
// `sensitivity:'base'`/'accent' caindo em comparação case-insensitive — que é o
// uso majoritário (ordenar lista da UI) e o único que dá para honrar.

@(private = "file")
coll_compare :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x := key_string(vm, arg(a, 0))
    y := key_string(vm, arg(a, 1))
    inst := receiver(vm, this)
    if inst != nil {
        if v, ok := inst.props["#ci"].(bool); ok && v {
            x = strings.to_lower(x, context.temp_allocator)
            y = strings.to_lower(y, context.temp_allocator)
        }
    }
    return f64(strings.compare(x, y))
}

@(private = "file")
coll_resolved :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := new_object(vm)
    inst := receiver(vm, this)
    locale := "en-US"
    if inst != nil do if v, ok := inst.props["#loc"].(string); ok do locale = v
    o.props["locale"]      = own_str(vm, locale)
    o.props["usage"]       = own_str(vm, "sort")
    o.props["sensitivity"] = own_str(vm, "variant")
    o.props["collation"]   = own_str(vm, "default")
    return o
}

@(private = "file")
intl_collator :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    inst.props["#loc"]  = first_locale(vm, arg(a, 0))
    sens := opt_str(vm, arg(a, 1), "sensitivity", "variant")
    inst.props["#ci"]   = sens == "base" || sens == "accent"
    inst.props["#kind"] = "collator"
    inst.props["compare"]         = mk_bound(vm, inst, coll_compare)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, coll_resolved)
    mark_non_enumerable(inst, "compare")
    mark_non_enumerable(inst, "resolvedOptions")
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.PluralRules ────────────────────────────────────────────────────────
//
// Regras de plural são POR IDIOMA e não-triviais (o russo tem 4 categorias, o
// árabe 6). Implementamos a regra do INGLÊS (1 → "one", resto → "other"), que
// também vale para de/nl/sv/es/it, e a de pt/fr (0 e 1 → "one"). Fora disso,
// "other" — a categoria que TODO idioma tem, então a mensagem sai no plural
// genérico em vez de estourar.

@(private = "file")
pr_select :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    n := to_number(vm, arg(a, 0))
    inst := receiver(vm, this)
    locale := "en"
    if inst != nil do if v, ok := inst.props["#loc"].(string); ok do locale = v
    prim := locale
    if i := strings.index_byte(prim, '-'); i >= 0 do prim = prim[:i]
    ord := false
    if inst != nil do if v, ok := inst.props["#ord"].(bool); ok do ord = v
    if ord {
        // ordinais em inglês: 1st/2nd/3rd/4th (o resto dos idiomas usa "other")
        if prim != "en" do return own_str(vm, "other")
        i := int(n) %% 100
        if i >= 11 && i <= 13 do return own_str(vm, "other")
        switch i %% 10 {
        case 1: return own_str(vm, "one")
        case 2: return own_str(vm, "two")
        case 3: return own_str(vm, "few")
        }
        return own_str(vm, "other")
    }
    switch prim {
    case "pt", "fr", "hi":
        return own_str(vm, (n >= 0 && n < 2) ? "one" : "other")
    case "en", "de", "nl", "sv", "da", "no", "nb", "es", "it", "el", "fi", "et", "he":
        return own_str(vm, n == 1 ? "one" : "other")
    case "ja", "zh", "ko", "vi", "th", "id":
        return own_str(vm, "other") // idiomas SEM distinção de plural
    }
    return own_str(vm, n == 1 ? "one" : "other")
}

@(private = "file")
intl_plural_rules :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    inst.props["#loc"]  = first_locale(vm, arg(a, 0))
    inst.props["#ord"]  = opt_str(vm, arg(a, 1), "type", "cardinal") == "ordinal"
    inst.props["#kind"] = "pluralrules"
    inst.props["select"]          = mk_bound(vm, inst, pr_select)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, coll_resolved)
    mark_non_enumerable(inst, "select")
    mark_non_enumerable(inst, "resolvedOptions")
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.RelativeTimeFormat ─────────────────────────────────────────────────
//
// "3 days ago" / "in 2 hours". Só em inglês (os nomes de unidade são CLDR);
// `numeric:'auto'` ganha os casos especiais yesterday/today/tomorrow, que é o
// motivo pelo qual os sites usam esta API.

@(private = "file")
rtf_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    v := to_number(vm, arg(a, 0))
    unit := key_string(vm, arg(a, 1))
    unit = strings.trim_suffix(unit, "s") // "days" → "day"
    inst := receiver(vm, this)
    auto := false
    if inst != nil do if b, ok := inst.props["#auto"].(bool); ok do auto = b

    if auto && unit == "day" {
        if v == -1 do return own_str(vm, "yesterday")
        if v ==  0 do return own_str(vm, "today")
        if v ==  1 do return own_str(vm, "tomorrow")
    }
    n := v < 0 ? -v : v
    plural := n == 1 ? "" : "s"
    // o número entra formatado (1000 → "1,000 days ago"), como o CLDR faz
    num := format_number(n, Num_Opts{locale = "en-US", style = "decimal", min_fd = -1, max_fd = -1, grouping = true})
    if v < 0 {
        return own_str(vm, fmt.tprintf("%s %s%s ago", num, unit, plural))
    }
    return own_str(vm, fmt.tprintf("in %s %s%s", num, unit, plural))
}

@(private = "file")
intl_relative_time_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    inst.props["#loc"]  = first_locale(vm, arg(a, 0))
    inst.props["#auto"] = opt_str(vm, arg(a, 1), "numeric", "always") == "auto"
    inst.props["#kind"] = "rtf"
    inst.props["format"]          = mk_bound(vm, inst, rtf_format)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, coll_resolved)
    mark_non_enumerable(inst, "format")
    mark_non_enumerable(inst, "resolvedOptions")
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.ListFormat ─────────────────────────────────────────────────────────

@(private = "file")
lf_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    arr, ok := arg(a, 0).(^Array)
    if !ok do return own_str(vm, key_string(vm, arg(a, 0)))
    inst := receiver(vm, this)
    conj := "and"
    if inst != nil do if v, vok := inst.props["#conj"].(string); vok do conj = v
    n := len(arr.items)
    if n == 0 do return own_str(vm, "")
    if n == 1 do return own_str(vm, key_string(vm, arr.items[0]))
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< n {
        if i > 0 {
            // vírgula de Oxford: o inglês a usa a partir de 3 itens
            if i == n - 1 {
                strings.write_string(&b, n > 2 ? ", " : " ")
                strings.write_string(&b, conj)
                strings.write_string(&b, " ")
            } else {
                strings.write_string(&b, ", ")
            }
        }
        strings.write_string(&b, key_string(vm, arr.items[i]))
    }
    return own_str(vm, strings.to_string(b))
}

@(private = "file")
intl_list_format :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := new_object(vm)
    inst.props["#loc"]  = first_locale(vm, arg(a, 0))
    inst.props["#conj"] = opt_str(vm, arg(a, 1), "type", "conjunction") == "disjunction" ? "or" : "and"
    inst.props["#kind"] = "listformat"
    inst.props["format"]          = mk_bound(vm, inst, lf_format)
    inst.props["resolvedOptions"] = mk_bound(vm, inst, coll_resolved)
    mark_non_enumerable(inst, "format")
    mark_non_enumerable(inst, "resolvedOptions")
    adopt_proto(vm, inst)
    return inst
}

// ── Intl.Locale ─────────────────────────────────────────────────────────────

@(private = "file")
intl_locale :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    tag := first_locale(vm, arg(a, 0))
    inst := new_object(vm)
    inst.props["#kind"]    = "locale"
    inst.props["baseName"] = own_str(vm, tag)
    lang := tag
    region := ""
    if i := strings.index_byte(tag, '-'); i >= 0 {
        lang = tag[:i]
        region = tag[i + 1:]
        if j := strings.index_byte(region, '-'); j >= 0 do region = region[:j]
    }
    inst.props["language"] = own_str(vm, lang)
    if region != "" do inst.props["region"] = own_str(vm, region)
    inst.props["toString"] = mk_bound(vm, inst, locale_to_string)
    mark_non_enumerable(inst, "toString")
    adopt_proto(vm, inst)
    return inst
}

@(private = "file")
locale_to_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    inst := receiver(vm, this)
    if inst == nil do return own_str(vm, "en-US")
    if v, ok := inst.props["baseName"].(string); ok do return own_str(vm, v)
    return own_str(vm, "en-US")
}

// ── nível Intl ──────────────────────────────────────────────────────────────

// getCanonicalLocales(x) → array. Não canonizamos de verdade (isso é tabela
// CLDR); devolvemos o que veio, que é o que 99% do código faz com o resultado.
@(private = "file")
intl_get_canonical_locales :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    arr := new_array(vm)
    switch t in arg(a, 0) {
    case string:
        append(&arr.items, own_str(vm, t))
    case ^Array:
        for it in t.items do append(&arr.items, own_str(vm, key_string(vm, it)))
    case bool, f64, JS_Null, ^Object, ^Function, ^Regex, ^Collection, ^Symbol, ^BigInt:
        if arg(a, 0) != nil do append(&arr.items, own_str(vm, key_string(vm, arg(a, 0))))
    }
    return arr
}

// supportedLocalesOf: dizemos que suportamos o que pedirem. Mentir para MENOS
// aqui é pior — código que recebe [] costuma abortar a feature inteira, e nós
// de fato formatamos (ainda que sem CLDR) em qualquer locale.
@(private = "file")
intl_supported_locales_of :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return intl_get_canonical_locales(vm, this, a)
}

// Number.prototype.toLocaleString passa a delegar ao mesmo formatador — era
// "aproximação sem separadores" e por isso `(1234.5).toLocaleString('pt-BR')`
// saía "1234.5" em vez de "1.234,5".
@(private = "file")
num_to_locale_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    x, ok := this.(f64); if !ok do return own_str(vm, "NaN")
    o := Num_Opts{
        locale   = first_locale(vm, arg(a, 0)),
        style    = opt_str(vm, arg(a, 1), "style", "decimal"),
        currency = opt_str(vm, arg(a, 1), "currency", ""),
        min_fd   = opt_int(arg(a, 1), "minimumFractionDigits", -1),
        max_fd   = opt_int(arg(a, 1), "maximumFractionDigits", -1),
        grouping = opt_bool(arg(a, 1), "useGrouping", true),
        notation_compact = opt_str(vm, arg(a, 1), "notation", "standard") == "compact",
    }
    return own_str(vm, format_number(x, o))
}

// Intl.supportedValuesOf(key) — ES2022. Apareceu como
// `Intl.supportedValuesOf is not a function` no bandcamp assim que o Intl passou
// a existir: o site testa `typeof Intl !== "undefined"` e daí em diante assume a
// API inteira. Devolvemos listas CURTAS e verdadeiras (o que de fato sabemos
// formatar), não a enumeração completa do CLDR — e array vazio para a chave que
// não conhecemos, que é resposta melhor que lançar.
@(private = "file")
intl_supported_values_of :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    arr := new_array(vm)
    add :: proc(vm: ^Interp, arr: ^Array, xs: []string) {
        for x in xs do append(&arr.items, own_str(vm, x))
    }
    switch key_string(vm, arg(a, 0)) {
    case "currency":
        add(vm, arr, {"ARS", "AUD", "BRL", "CAD", "CHF", "CLP", "CNY", "COP", "EUR",
                      "GBP", "INR", "JPY", "KRW", "MXN", "NZD", "RUB", "TRY", "USD"})
    case "timeZone":
        add(vm, arr, {"UTC"}) // é o único que nossa Date sabe produzir (date.odin)
    case "calendar":
        add(vm, arr, {"gregory"})
    case "numberingSystem":
        add(vm, arr, {"latn"})
    case "collation":
        add(vm, arr, {"default"})
    case "unit":
        add(vm, arr, {"day", "hour", "minute", "month", "second", "week", "year"})
    }
    return arr
}

@(private = "file")
mk_intl_ctor :: proc(vm: ^Interp, name: string, fn: Native_Fn) -> ^Function {
    f := mk_native(vm, fn)
    f.name = name
    f.props = make(map[string]Value)
    f.props["supportedLocalesOf"] = mk_native(vm, intl_supported_locales_of)
    // prototype real: `x instanceof Intl.NumberFormat` aparece em código de lib.
    // As instâncias apontam para ele, então o instanceof responde a verdade.
    proto := new_object(vm)
    f.props["prototype"] = proto
    proto.props["constructor"] = f
    mark_non_enumerable(proto, "constructor")
    // O prototype viaja em `bound` (visível como vm.native_bound durante a
    // chamada): é assim que a nativa construtora liga a instância ao prototype
    // do SEU construtor sem precisar de um mapa novo no Interp.
    f.bound = proto
    return f
}

// Liga a instância recém-criada ao prototype do construtor em execução.
@(private = "file")
adopt_proto :: proc(vm: ^Interp, inst: ^Object) {
    if p, ok := vm.native_bound.(^Object); ok do inst.proto = p
}

install_intl :: proc(vm: ^Interp) {
    intl := new_object(vm)
    ctors := [?]struct{ name: string, fn: Native_Fn }{
        {"NumberFormat",       intl_number_format},
        {"DateTimeFormat",     intl_datetime_format},
        {"Collator",           intl_collator},
        {"PluralRules",        intl_plural_rules},
        {"RelativeTimeFormat", intl_relative_time_format},
        {"ListFormat",         intl_list_format},
        {"Locale",             intl_locale},
    }
    for c in ctors do intl.props[c.name] = mk_intl_ctor(vm, c.name, c.fn)
    intl.props["getCanonicalLocales"] = mk_native(vm, intl_get_canonical_locales)
    intl.props["supportedValuesOf"]   = mk_native(vm, intl_supported_values_of)
    // `Object.prototype.toString.call(Intl)` → "[object Intl]" (a spec dá a Intl
    // um @@toStringTag; o motor já lê a prop interna "#class" p/ Math/JSON).
    intl.props["#class"] = "Intl"
    env_define(vm.global, "Intl", intl)

    vm.number_methods["toLocaleString"] = mk_native(vm, num_to_locale_string)
}
