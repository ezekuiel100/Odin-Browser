package js

import "core:fmt"
import "core:strings"

// Symbol / Symbol.for — o mínimo que o React (e libs) exigem: valores com
// IDENTIDADE (dois símbolos só são === se forem o MESMO). O React marca cada
// tipo de elemento com Symbol.for("react.element" / "react.fragment" / ...);
// sem símbolos distintos, todos colapsam em undefined e o React não distingue
// os tipos → não renderiza. Identidade = ponteiro (a union Value compara por
// ponteiro no ==). Além da descrição, guardamos a chave-string de PROPRIEDADE
// (ver symbol_key): a identidade tem de sobreviver a `o[sym]`, e antes não
// sobrevivia — a chave era só a descrição, então dois Symbol("a") colidiam.

Symbol :: struct {
    desc: string, // descrição (owned); só p/ debug/toString
    key:  string, // chave-string ÚNICA sob a qual este símbolo indexa um objeto
                  // (owned pelo vm via owned_strings; "" até o 1º uso como chave).
                  // Ver symbol_key — cacheada aqui porque `o[sym]` a recalcularia
                  // em todo acesso.
}

// A chave-string com que `sym` indexa propriedades. Precisa ser ÚNICA POR SÍMBOLO:
// `Symbol("a")` e `Symbol("a")` são símbolos DIFERENTES, e usar só a descrição fazia
// os dois colidirem — `o[s1]=1; o[s2]=2` deixava o[s1] valendo 2, corrompendo dados
// em silêncio. O endereço do ^Symbol dá a identidade (é o mesmo critério do `===`).
//
// O prefixo "Symbol(" é o que `is_symbol_key` testa para manter estas chaves fora de
// for-in/Object.keys/JSON, então tem de continuar no início.
symbol_key :: proc(vm: ^Interp, sym: ^Symbol) -> string {
    if sym.key != "" do return sym.key
    s := fmt.aprintf("Symbol(%s)@%d", sym.desc, uintptr(rawptr(sym)))
    append(&vm.owned_strings, s)
    sym.key = s
    if vm.symbol_keys == nil do vm.symbol_keys = make(map[string]^Symbol)
    vm.symbol_keys[s] = sym // mapa reverso, p/ Object.getOwnPropertySymbols
    return s
}

new_symbol :: proc(vm: ^Interp, desc: string) -> ^Symbol {
    s := new(Symbol)
    s.desc = strings.clone(desc)
    append(&vm.all_symbols, s)
    return s
}

// Symbol(desc): um símbolo NOVO e único a cada chamada.
@(private = "file")
symbol_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    desc := ""
    if s, ok := arg(args, 0).(string); ok do desc = s
    return new_symbol(vm, desc)
}

// Symbol.for(key): registro GLOBAL — mesma chave devolve o MESMO símbolo,
// chaves distintas devolvem símbolos distintos. É disso que o React depende.
@(private = "file")
symbol_for :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    key := ""
    if s, ok := arg(args, 0).(string); ok do key = s
    if sym, ok := vm.symbol_registry[key]; ok do return sym
    sym := new_symbol(vm, key)
    vm.symbol_registry[strings.clone(key)] = sym // chave owned (liberada em vm_free)
    return sym
}

// Symbol.prototype.toString() → "Symbol(desc)". A spec exige `this` SÍMBOLO
// (thisSymbolValue) e lança TypeError caso contrário — lançar aqui é o mesmo que o
// Chrome faz, então quem depende do comportamento não vê diferença.
@(private = "file")
symbol_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sym, ok := this.(^Symbol)
    if !ok {
        throw_type_error(vm, "Symbol.prototype.toString requires that 'this' be a Symbol")
        return nil
    }
    return own_str(vm, fmt.tprintf("Symbol(%s)", sym.desc))
}

// valueOf e [Symbol.toPrimitive] devolvem o próprio símbolo (o valor primitivo).
@(private = "file")
symbol_value_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sym, ok := this.(^Symbol)
    if !ok {
        throw_type_error(vm, "Symbol.prototype.valueOf requires that 'this' be a Symbol")
        return nil
    }
    return sym
}

install_symbol :: proc(vm: ^Interp) {
    vm.symbol_registry = make(map[string]^Symbol)
    ctor := mk_native(vm, symbol_ctor)
    ctor.name = "Symbol"
    ctor.props = make(map[string]Value)
    ctor.props["for"] = mk_native(vm, symbol_for)
    // símbolos "bem conhecidos" — cada um único e distinto
    iter_sym := new_symbol(vm, "Symbol.iterator")
    ctor.props["iterator"]      = iter_sym
    // chave-string sob a qual `obj[Symbol.iterator]=fn` grava (key_string→to_text);
    // o protocolo de iterador (for-of/spread) lê o método por esta mesma chave.
    vm.sym_iterator_key = key_string(vm, iter_sym)
    async_iter_sym := new_symbol(vm, "Symbol.asyncIterator")
    ctor.props["asyncIterator"] = async_iter_sym
    vm.sym_async_iterator_key = key_string(vm, async_iter_sym) // for-await + async generators
    // hasInstance / toStringTag existiam como símbolos DISTINTOS desde sempre, mas
    // ninguém os consultava: `instanceof` ignorava o primeiro e
    // Object.prototype.toString ignorava o segundo. Guardar a chave-string é o que
    // permite js_instanceof/obj_proto_to_string lerem a propriedade.
    hi_sym := new_symbol(vm, "Symbol.hasInstance")
    ctor.props["hasInstance"]   = hi_sym
    vm.sym_has_instance_key = key_string(vm, hi_sym)
    tag_sym := new_symbol(vm, "Symbol.toStringTag")
    ctor.props["toStringTag"]   = tag_sym
    vm.sym_tostring_tag_key = key_string(vm, tag_sym)
    tp_sym := new_symbol(vm, "Symbol.toPrimitive")
    ctor.props["toPrimitive"]   = tp_sym
    vm.sym_toprimitive_key = key_string(vm, tp_sym) // ToPrimitive consulta esta chave 1º

    // %SymbolPrototype% (M220). Symbol era o último primitivo SEM `.prototype` — a
    // mesma falta que o M127 consertou no Boolean, e pelo mesmo motivo: o padrão
    // `uncurryThis` de biblioteca lê o método NO PROTÓTIPO, não na instância.
    //     const symbolToString = unapply(Symbol.prototype.toString)   ← DOMPurify
    // Com `Symbol.prototype` undefined isso era `reading 'toString' of undefined` e
    // derrubava o módulo inteiro — era a exceção que sobrava na página de repositório
    // do github (o DOMPurify sanitiza o markdown do README).
    //
    // Este objeto é a fonte ÚNICA dos métodos de símbolo: o get_member de `^Symbol`
    // lê daqui, então `sym.toString()` e `Symbol.prototype.toString.call(sym)` são o
    // MESMO native (sem cópia que possa divergir).
    sym_proto := new_object(vm)
    sym_proto.props["toString"] = mk_native(vm, symbol_to_string)
    sym_proto.props["valueOf"]  = mk_native(vm, symbol_value_of)
    if vm.sym_toprimitive_key != "" do sym_proto.props[vm.sym_toprimitive_key] = mk_native(vm, symbol_value_of)
    sym_proto.props["constructor"] = ctor
    ctor.props["prototype"] = sym_proto
    vm.symbol_proto = sym_proto

    env_define(vm.global, "Symbol", ctor)
}
