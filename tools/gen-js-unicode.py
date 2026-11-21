"""Generate ECMAScript RegExp property tables from pinned Unicode 17.0.0 data.

Run: python tools/gen-js-unicode.py
Downloads are cached outside the source tree. No network is used by the engine.
Unicode data is distributed under Unicode License v3 (src/js/unicode-LICENSE.txt).
"""
from collections import defaultdict
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile
import hashlib
import io

ROOT = Path(__file__).resolve().parents[1]
VERSION = "17.0.0"
CACHE = ROOT / "_local" / "unicode" / VERSION
CACHE.mkdir(parents=True, exist_ok=True)
CHECKSUMS = {
    "UCD.zip": "2066d1909b2ea93916ce092da1c0ee4808ea3ef8407c94b4f14f5b7eb263d28e",
    "emoji-sequences.txt": "12cc8267dc33cbd11ed32bcf6fc5dc2ad9c7a77bae1bdfba2f41b1b9b3ead8dd",
    "emoji-zwj-sequences.txt": "5b25441daed2322b068c5e70cda522946a4f0274df864445a1965a92e5fc5cad",
    "LICENSE.txt": "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96",
}


def download(name, url):
    path = CACHE / name
    if not path.exists():
        path.write_bytes(urlopen(url, timeout=90).read())
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != CHECKSUMS[name]:
        raise ValueError(f"Checksum mismatch: {path}")
    return data


ucd_bytes = download("UCD.zip", f"https://www.unicode.org/Public/{VERSION}/ucd/UCD.zip")
ucd = ZipFile(io.BytesIO(ucd_bytes))


def records(text):
    for line in text.splitlines():
        body = line.split("#", 1)[0].strip()
        if body:
            yield [field.strip() for field in body.split(";")]


def read(name):
    return ucd.read(name).decode("utf-8-sig")


def span(value):
    ends = value.split("..")
    return int(ends[0], 16), int(ends[-1], 16)


def merge(ranges):
    out = []
    for lo, hi in sorted(ranges):
        if out and lo <= out[-1][1] + 1:
            out[-1] = out[-1][0], max(out[-1][1], hi)
        else:
            out.append((lo, hi))
    return out


def complement(ranges):
    out, start = [], 0
    for lo, hi in merge(ranges):
        if start < lo:
            out.append((start, lo - 1))
        start = hi + 1
    if start <= 0x10FFFF:
        out.append((start, 0x10FFFF))
    return out


aliases = defaultdict(dict)
for row in records(read("PropertyValueAliases.txt")):
    if row[0] in ("gc", "sc"):
        for alias in row[1:]:
            aliases[row[0]][alias] = row[1]

gc = defaultdict(list)
for row in records(read("extracted/DerivedGeneralCategory.txt")):
    gc[row[1]].append(span(row[0]))
for category in "LCMNPSZ":
    gc[category] = [r for key, ranges in list(gc.items()) if len(key) == 2 and key[0] == category for r in ranges]
gc["LC"] = gc["Lu"] + gc["Ll"] + gc["Lt"]
assert sum(hi-lo+1 for key, ranges in gc.items() if len(key) == 2 and key != "LC" for lo, hi in ranges) == 0x110000

scripts = defaultdict(list)
for row in records(read("Scripts.txt")):
    scripts[aliases["sc"][row[1]]].append(span(row[0]))
scripts["Zzzz"] = complement([r for ranges in scripts.values() for r in ranges])
extensions = defaultdict(list)
overrides = []
for row in records(read("ScriptExtensions.txt")):
    value = span(row[0])
    overrides.append(value)
    for script in row[1].split():
        extensions[script].append(value)
for script, ranges in scripts.items():
    # scx defaults to Script except where ScriptExtensions explicitly overrides it.
    for lo, hi in merge(ranges):
        pieces = [(lo, hi)]
        for a, b in overrides:
            pieces = [(x, min(y, a-1)) for x, y in pieces if x < a] + [(max(x,b+1), y) for x,y in pieces if y > b]
        extensions[script].extend(pieces)

# ECMA-262 Table "Binary Unicode properties"; no loose matching of aliases.
binary_names = set("""ASCII ASCII_Hex_Digit Alphabetic Any Assigned Bidi_Control
Bidi_Mirrored Case_Ignorable Cased Changes_When_Casefolded Changes_When_Casemapped
Changes_When_Lowercased Changes_When_NFKC_Casefolded Changes_When_Titlecased
Changes_When_Uppercased Dash Default_Ignorable_Code_Point Deprecated Diacritic
Emoji Emoji_Component Emoji_Modifier Emoji_Modifier_Base Emoji_Presentation
Extended_Pictographic Extender Grapheme_Base Grapheme_Extend Hex_Digit
IDS_Binary_Operator IDS_Trinary_Operator ID_Continue ID_Start Ideographic
Join_Control Logical_Order_Exception Lowercase Math Noncharacter_Code_Point
Pattern_Syntax Pattern_White_Space Quotation_Mark Radical Regional_Indicator
Sentence_Terminal Soft_Dotted Terminal_Punctuation Unified_Ideograph Uppercase
Variation_Selector White_Space XID_Continue XID_Start""".split())
binary = defaultdict(list)
for filename in ("PropList.txt", "DerivedCoreProperties.txt", "DerivedNormalizationProps.txt", "emoji/emoji-data.txt"):
    for row in records(read(filename)):
        if row[1] in binary_names:
            binary[row[1]].append(span(row[0]))
for row in records(read("UnicodeData.txt")):
    if row[9] == "Y":
        binary["Bidi_Mirrored"].append((int(row[0], 16), int(row[0], 16)))
binary["ASCII"] = [(0, 127)]
binary["Any"] = [(0, 0x10FFFF)]
binary["Assigned"] = complement(gc["Cn"])
assert set(binary) == binary_names, binary_names - set(binary)
binary_aliases = {}
for row in records(read("PropertyAliases.txt")):
    if row[1] in binary_names:
        for alias in row:
            binary_aliases[alias] = row[1]
binary_aliases.update({name: name for name in binary_names})

sequences = defaultdict(set)
for filename in ("emoji-sequences.txt", "emoji-zwj-sequences.txt"):
    data = download(filename, f"https://www.unicode.org/Public/{VERSION}/emoji/{filename}")
    for row in records(data.decode("utf-8-sig")):
        if ".." in row[0]:
            lo, hi = span(row[0])
            sequences[row[1]].update((cp,) for cp in range(lo, hi+1))
        else:
            sequences[row[1]].add(tuple(int(cp, 16) for cp in row[0].split()))
sequences["RGI_Emoji"] = set.union(*sequences.values())
assert len(sequences) == 7

properties, lookup = [], {}


def add_property(name, ranges, names, strings=(), is_strings=False):
    index = len(properties)
    properties.append((name, merge(ranges), sorted(strings), is_strings))
    for alias in names:
        assert alias not in lookup, alias
        lookup[alias] = index


for key, ranges in sorted(gc.items()):
    names = [a for a, canonical in aliases["gc"].items() if canonical == key]
    add_property("gc=" + key, ranges, names + [p+"="+a for p in ("gc", "General_Category") for a in names])
for group, short, tables in (("Script", "sc", scripts), ("Script_Extensions", "scx", extensions)):
    for key in sorted(scripts):
        names = [a for a, canonical in aliases["sc"].items() if canonical == key]
        add_property(short+"="+key, tables[key], [p+"="+a for p in (short, group) for a in names])
for name in sorted(binary_names):
    add_property(name, binary[name], [a for a, canonical in binary_aliases.items() if canonical == name])
for name, strings in sorted(sequences.items()):
    add_property(name, [(s[0],s[0]) for s in strings if len(s) == 1], [name],
                 [s for s in strings if len(s) > 1], True)

folds = []
for row in records(read("CaseFolding.txt")):
    if row[1] in ("C", "S"):
        folds.append((int(row[0],16), int(row[2],16)))

out = ["package js", "", "// Generated by tools/gen-js-unicode.py; Unicode " + VERSION + ".",
       "// Unicode License v3: unicode-LICENSE.txt. Do not edit by hand.",
       "// UCD.zip SHA-256: " + hashlib.sha256(ucd_bytes).hexdigest(), "",
       "RE_UNICODE_VERSION :: \"" + VERSION + "\"", "",
       "Re_Unicode_Property :: struct { start, count, string_start, string_count: int, strings: bool }", "",
       "RE_UNICODE_PROPERTIES := [?]Re_Unicode_Property{"]
ranges, strings = [], []
for name, rs, ss, is_strings in properties:
    out.append(f"    {{{len(ranges)}, {len(rs)}, {len(strings)}, {len(ss)}, {str(is_strings).lower()}}}, // {name}")
    ranges.extend(rs)
    strings.extend(ss)
out += ["}", "", "RE_UNICODE_RANGES := [?]Re_Range{"]
out += [f"    {{0x{lo:X}, 0x{hi:X}}}," for lo,hi in ranges]
out += ["}", "", "RE_UNICODE_STRINGS := [?]string{"]
out += ['    "' + ''.join(f"\\U{cp:08X}" for cp in s) + '",' for s in strings]
out += ["}", "", "RE_UNICODE_FOLDS := [?][2]rune{"]
out += [f"    {{0x{a:X}, 0x{b:X}}}," for a,b in sorted(folds)]
out += ["}", "", "RE_UNICODE_FOLD_INVERSE := [?][2]rune{"]
out += [f"    {{0x{b:X}, 0x{a:X}}}," for b,a in sorted((b,a) for a,b in folds)]
out += ["}", "", "re_unicode_lookup :: proc(name: string) -> int {", "    switch name {"]
by_id = defaultdict(list)
for name,index in lookup.items():
    by_id[index].append(name)
for index,names in sorted(by_id.items()):
    out.append("    case " + ", ".join('"'+name+'"' for name in sorted(names)) + f": return {index}")
out += ["    }", "    return -1", "}", ""]
target = ROOT / "src" / "js" / "unicode_tables_gen.odin"
target.write_text("\n".join(out), encoding="utf-8", newline="\n")
(ROOT / "src" / "js" / "unicode-LICENSE.txt").write_bytes(download("LICENSE.txt", "https://www.unicode.org/license.txt"))
print(f"{len(properties)} properties, {len(ranges)} ranges, {len(strings)} strings, {len(folds)} folds; {target.stat().st_size} bytes")
