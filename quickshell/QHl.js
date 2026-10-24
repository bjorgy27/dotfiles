.pragma library
// Syntax highlighting for the fenced code cards of the Q chat panel (drawn by QMdView.qml).
// html(code, lang, pal) -> rich-text spans (inner HTML, the caller wraps it in a pre-wrap div) or "" when the block
// should stay plain text: unknown language, empty code, more than MAX chars, or anything unexpected (never throws).
// A small regex tokenizer per language: at each position the language's sticky rules are tried in order and the first
// non-empty match wins; anything no rule claims is plain text. Every rule tolerates an unclosed string/comment, so a
// block that is still streaming highlights cleanly. All code text is HTML-escaped; only the span markup is ours.
// Token types map to palette roles: the widget passes palette(Theme.colors), the live wallpaper theme fitted to
// 4.5:1 contrast on the card; DEFAULT (Catppuccin Mocha) is only the fallback when no palette is given:
//   kw mauve, str green, num/const/builtin peach, com overlay italic, fn blue, type yellow, op sky, punc overlay2,
//   self/del red, prop/tag blue/lavender, deco/var/esc pink, meta/head mauve/sky, add green.

var MAX = 20000

var DEFAULT = {
  kw: "#cba6f7", str: "#a6e3a1", num: "#fab387", com: "#7f849c", fn: "#89b4fa", type: "#f9e2af", op: "#89dceb",
  punc: "#9399b2", cnst: "#fab387", builtin: "#fab387", self: "#f38ba8", prop: "#b4befe", tag: "#89b4fa",
  attr: "#f9e2af", deco: "#f5c2e7", vari: "#f5c2e7", esc: "#f5c2e7", meta: "#89dceb", head: "#cba6f7",
  add: "#a6e3a1", del: "#f38ba8", link: "#89b4fa", url: "#7f849c", strong: "#fab387", em: "#f5c2e7"
}
var STYLE = { com: "font-style:italic;", head: "font-weight:bold;", strong: "font-weight:bold;", em: "font-style:italic;",
              url: "text-decoration:underline;" }

function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") }
function words(s) { var o = Object.create(null); s.split(/\s+/).forEach(function (w) { if (w) o[w] = 1 }); return o }

// ---------- shared pieces
var WS = /\s+/y
var DQ = /"(?:[^"\\\n]|\\.)*"?/y
var DQML = /"(?:[^"\\]|\\[\s\S])*"?/y
var SQ = /'(?:[^'\\\n]|\\.)*'?/y
var BLOCKC = /\/\*[\s\S]*?(?:\*\/|$)/y
var SLC = /\/\/.*/y
var HASHC = /#.*/y
var NUM = /(?:0[xX][\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\d[\d_]*(?:\.(?!\.)[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?)[A-Za-z_\d]*/y
var OP = /[+\-*\/%=<>!&|^~?:@]+/y
var PUNC = /[{}()\[\];,.\\]/y
var IDENT = /[A-Za-z_$][\w$]*/y
var CALL = /[ \t]*\(/y

function lineLead(code, i) {               // only indentation (or a "{" / ";") between the line start and i
  for (var k = i - 1; k >= 0; k--) {
    var c = code.charAt(k)
    if (c === "\n") return true
    if (c === " " || c === "\t") continue
    return c === "{" || c === ";"
  }
  return true
}
function afterSpace(code, i) { return i === 0 || /\s/.test(code.charAt(i - 1)) }

// identifier classifier: o = {kw, types, consts, builtins, self, ci (case-insensitive), capType, upperConst, macro}
function idents(o) {
  return function (m, st, code, end) {
    var w = m[0], k = o.ci ? w.toLowerCase() : w
    if (o.kw && o.kw[k]) return "kw"
    if (o.self && o.self[k]) return "self"
    if (o.consts && o.consts[k]) return "cnst"
    if (o.types && o.types[k]) return "type"
    if (o.macro && code.charAt(end) === "!" && code.charAt(end + 1) !== "=") return "fn"
    CALL.lastIndex = end
    if (CALL.test(code)) return o.builtins && o.builtins[k] ? "builtin" : "fn"
    if (o.builtins && o.builtins[k]) return "builtin"
    if (o.upperConst && w.length > 1 && /^[A-Z][A-Z0-9_]*$/.test(w)) return "cnst"
    if (o.capType && /^[A-Z]/.test(w) && /[a-z]/.test(w)) return "type"
    return ""
  }
}
function r(re, t, extra) { var o = { re: re, t: t }; for (var k in extra) o[k] = extra[k]; return o }

// ---------- languages
var L = Object.create(null)

var JS_KW = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch throw try typeof var void while with yield async await of static get set from as"
var TS_KW = " interface type enum implements namespace declare abstract public private protected readonly keyof infer is satisfies module"
var JS_ID = { kw: words(JS_KW + TS_KW), self: words("this"), consts: words("true false null undefined NaN Infinity"),
              types: words("string number boolean any unknown never object symbol bigint"),
              builtins: words("console Math JSON Object Array String Number Boolean Promise Date Error Map Set WeakMap RegExp Symbol window document require module exports process globalThis parseInt parseFloat setTimeout setInterval clearTimeout fetch Qt"),
              capType: true, upperConst: true }
function regexOk(st) { return st.last === "" || st.last === "op" || st.last === "kw" || (st.last === "punc" && !/[)\]]/.test(st.lastText)) }
var JS_RULES = [
  r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"),
  r(/`(?:[^`\\]|\\[\s\S])*`?/y, "str"), r(DQ, "str"), r(SQ, "str"),
  r(/\/(?![*\/])(?:[^\/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\]?)+\/[a-z]*/y, "str", { when: regexOk }),
  r(/@[A-Za-z_][\w.]*/y, "deco"), r(NUM, "num"), r(IDENT, idents(JS_ID)), r(/=>/y, "op"), r(OP, "op"), r(PUNC, "punc")
]
L.javascript = { rules: JS_RULES }

var QML_ID = Object.assign({}, JS_ID, { kw: words(JS_KW + " property signal readonly required alias component default on pragma"),
                                        types: words("bool int real double string var color url list point rect size font date variant") })
L.qml = { rules: [r(/import\b.*/y, function (m) { return [["kw", "import"], ["type", m[0].slice(6)]] }, { bol: true }),
                  r(/[A-Za-z_][\w.]*(?=[ \t]*:(?!:))/y, "prop", { when: function (st, code, i) { return lineLead(code, i) } })]
                 .concat(JS_RULES.map(function (x) { return x.re === IDENT ? r(IDENT, idents(QML_ID)) : x })) }

L.json = { rules: [r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"), r(/"(?:[^"\\\n]|\\.)*"(?=\s*:)/y, "prop"), r(DQ, "str"), r(SQ, "str"),
                   r(/-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/y, "num"), r(/(?:true|false|null)\b/y, "cnst"), r(/[A-Za-z_]\w*/y, ""),
                   r(/[{}\[\]:,]/y, "punc")] }

L.python = { rules: [
  r(WS, ""), r(HASHC, "com"),
  r(/[rRbBuUfF]{0,2}(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$))/y, "str"),
  r(/[rRbBuUfF]{0,2}(?:"(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?)/y, "str"),
  r(/@[A-Za-z_][\w.]*/y, "deco", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(NUM, "num"),
  r(IDENT, idents({ kw: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
                     self: words("self cls"), consts: words("True False None NotImplemented Ellipsis __name__ __file__"),
                     builtins: words("print len range open int str float list dict set tuple bool type isinstance issubclass super enumerate zip map filter sorted reversed sum min max abs any all repr input iter next hasattr getattr setattr delattr round divmod pow hash id chr ord format vars dir callable bytes bytearray frozenset object property staticmethod classmethod"),
                     capType: true, upperConst: true })),
  r(/->|:=|\*\*|\/\//y, "op"), r(OP, "op"), r(PUNC, "punc")] }

var SH_START = /^(?:\||\|\||&&|;|;;|&|\(|\$\(|`|\{|then|do|else|elif|sudo|time|exec|xargs|env|!)$/
L.bash = { rules: [
  r(/\s+/y, function (m, st) { if (m[0].indexOf("\n") >= 0) st.cmd = true; return "" }),
  r(HASHC, "com", { when: function (st, code, i) { return afterSpace(code, i) } }),
  r(/\$'(?:[^'\\]|\\[\s\S])*'?/y, "str"), r(DQML, "str"), r(/'[^']*'?/y, "str"),
  r(/\$(?:\{[^}\n]*\}?|[A-Za-z_]\w*|[@*#?$!0-9-])/y, "vari"),
  r(/<<-?[ \t]*['"]?\w+['"]?/y, "op"),
  r(/--?[A-Za-z][\w-]*/y, "attr", { when: function (st, code, i) { return afterSpace(code, i) } }),
  r(/[A-Za-z_]\w*(?==)/y, function (m, st) { return st.cmd ? "vari" : "" }),
  r(/[A-Za-z_.\/~][\w.\/~+@%-]*/y, function (m, st) {
    var w = m[0], kw = SH_KW[w]
    var t = kw ? "kw" : st.cmd ? "fn" : /^\d/.test(w) ? "num" : ""
    st.cmd = SH_START.test(w) || w === "if" || w === "while" || w === "until"
    return t
  }),
  r(/\d+(?![\w.\/])/y, "num"),
  r(/\|\||&&|;;|\$\(\(?|[|;&()`{}]/y, function (m, st) { st.cmd = SH_START.test(m[0]); return "op" }),
  r(/[<>=!]+|\[\[?|\]\]?/y, function (m, st) { st.cmd = false; return "op" })] }
var SH_KW = words("if then else elif fi for while until do done case esac in function select return break continue local export readonly declare unset shift exit source alias time")

L.rust = { rules: [
  r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"),
  r(/#!?\[[^\]\n]*\]?/y, "deco"),
  r(/b?'(?:\\(?:x[\da-fA-F]{2}|u\{[\da-fA-F]*\}|.)|[^\\'\n])'/y, "str"), r(/'[A-Za-z_]\w*/y, "deco"),
  r(/b?r(#*)"[\s\S]*?(?:"\1|$)/y, "str"), r(/b?"(?:[^"\\]|\\[\s\S])*"?/y, "str"),
  r(NUM, "num"),
  r(IDENT, idents({ kw: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while"),
                     self: words("self Self"), consts: words("true false None"),
                     types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
                     capType: true, upperConst: true, macro: true })),
  r(/->|=>|::/y, "op"), r(OP, "op"), r(PUNC, "punc")] }

var C_KW = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Static_assert"
var CPP_KW = " alignas alignof and asm catch class constexpr const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast static_assert static_cast template throw try typeid typename using virtual override final concept requires co_await co_return co_yield consteval constinit"
var C_RULES = [
  r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"),
  r(/(#[ \t]*include)([ \t]*)(<[^>\n]*>?)?/y, ["kw", "", "str"], { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/#[ \t]*[A-Za-z]+/y, "kw", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/(?:u8|[uUL])?R"([^(\s]*)\([\s\S]*?(?:\)\1"|$)/y, "str"),
  r(/(?:u8|[uUL])?"(?:[^"\\\n]|\\.)*"?/y, "str"), r(/[uUL]?'(?:[^'\\\n]|\\.)*'?/y, "str"),
  r(NUM, "num"),
  r(IDENT, idents({ kw: words(C_KW + CPP_KW), self: words("this"), consts: words("true false NULL nullptr EOF stdin stdout stderr"),
                     types: words("int long short float double char void bool unsigned signed size_t ssize_t ptrdiff_t wchar_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t FILE std string vector map unique_ptr shared_ptr"),
                     capType: true, upperConst: true })),
  r(/->|::/y, "op"), r(OP, "op"), r(PUNC, "punc")]
L.c = { rules: C_RULES }

L.go = { rules: [
  r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"), r(/`[^`]*`?/y, "str"), r(DQ, "str"), r(SQ, "str"), r(NUM, "num"),
  r(IDENT, idents({ kw: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
                     consts: words("true false nil iota"),
                     types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"),
                     builtins: words("append cap clear close complex copy delete imag len make max min new panic print println real recover"),
                     capType: true })),
  r(/:=|<-/y, "op"), r(OP, "op"), r(PUNC, "punc")] }

L.java = { rules: [
  r(WS, ""), r(SLC, "com"), r(BLOCKC, "com"), r(/"""[\s\S]*?(?:"""|$)/y, "str"), r(DQ, "str"), r(SQ, "str"),
  r(/@[A-Za-z_][\w.]*/y, "deco"), r(NUM, "num"),
  r(IDENT, idents({ kw: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized throw throws transient try volatile while var record sealed permits yield non-sealed"),
                     self: words("this"), consts: words("true false null"),
                     types: words("boolean byte char double float int long short void"), capType: true, upperConst: true })),
  r(/->|::/y, "op"), r(OP, "op"), r(PUNC, "punc")] }

L.lua = { rules: [
  r(WS, ""), r(/--\[(=*)\[[\s\S]*?(?:\]\1\]|$)/y, "com"), r(/--.*/y, "com"), r(/\[(=*)\[[\s\S]*?(?:\]\1\]|$)/y, "str"),
  r(DQ, "str"), r(SQ, "str"), r(NUM, "num"),
  r(IDENT, idents({ kw: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
                     self: words("self"), consts: words("true false nil"),
                     builtins: words("print pairs ipairs type tostring tonumber require table string math os io error pcall xpcall select setmetatable getmetatable rawget rawset unpack assert coroutine next"),
                     upperConst: true })),
  r(/\.\.\.?|~=|::/y, "op"), r(/[+\-*\/%^#=<>&|~]+/y, "op"), r(/[{}()\[\];:,.]/y, "punc")] }

L.sql = { rules: [
  r(WS, ""), r(/--.*/y, "com"), r(BLOCKC, "com"), r(/'(?:[^']|'')*'?/y, "str"), r(/"[^"\n]*"?|`[^`\n]*`?/y, "prop"),
  r(NUM, "num"), r(/[@:$][A-Za-z_]\w*|\$\d+|\?/y, "vari"),
  r(/[A-Za-z_]\w*/y, idents({ ci: true,
     kw: words("select from where and or not insert into values update set delete create table drop alter add column index primary key foreign references join left right inner outer full cross natural on using as group by order having limit offset distinct union all intersect except case when then else end is null like ilike in between exists default constraint unique check view returning with recursive desc asc if begin commit rollback transaction grant revoke to database schema trigger function procedure replace temporary temp cascade explain analyze vacuum over partition window filter conflict do nothing"),
     consts: words("true false null"),
     types: words("int integer bigint smallint tinyint text varchar char boolean bool date time timestamp timestamptz interval float real double precision numeric decimal serial bigserial uuid json jsonb blob bytea") })),
  r(/[+\-*\/%=<>!|:]+/y, "op"), r(/[()\[\];,.]/y, "punc")] }

L.css = { rules: [
  r(WS, ""), r(BLOCKC, "com"), r(SLC, "com", { when: function (st) { return st.scss } }), r(DQ, "str"), r(SQ, "str"),
  r(/\{/y, function (m, st) { st.depth++; return "punc" }), r(/\}/y, function (m, st) { st.depth = Math.max(0, st.depth - 1); return "punc" }),
  r(/@[\w-]+/y, "kw"), r(/!important/y, "kw"),
  r(/-{0,2}[A-Za-z_][\w-]*(?=\s*:)/y, "prop", { when: function (st, code, i) { return st.depth > 0 && lineLead(code, i) } }),
  r(/#[\da-fA-F]{3,8}(?![\w-])/y, "num", { when: function (st) { return st.depth > 0 } }),
  r(/-?(?:\d+\.?\d*|\.\d+)(?:%|[A-Za-z]+)?/y, "num"),
  r(/[\w-]+(?=\()/y, "fn"),
  r(/\.[A-Za-z_-][\w-]*/y, "type", { when: function (st) { return st.depth === 0 } }),
  r(/#[A-Za-z_-][\w-]*/y, "cnst", { when: function (st) { return st.depth === 0 } }),
  r(/::?[A-Za-z-]+/y, "deco", { when: function (st) { return st.depth === 0 } }),
  r(/&/y, "deco"), r(/\$[\w-]+/y, "vari"),
  r(/[A-Za-z_-][\w-]*/y, function (m, st) { return st.depth === 0 ? "tag" : "" }),
  r(/[>+~*=:]/y, "op"), r(/[()\[\];,]/y, "punc")] }

function tagParts(m) {                       // <name attr="v" ...> -> segments
  var s = m[0], out = [], h = /^(<\/?)([^\s\/>]*)/.exec(s)
  out.push(["punc", h[1]], ["tag", h[2]])
  var re = /(\s+)|([^\s=\/>"']+)|(=)|("[^"]*"?|'[^']*'?)|(\/?>)|([\s\S])/g, x
  re.lastIndex = h[0].length
  while ((x = re.exec(s)) !== null)
    out.push([x[1] ? "" : x[2] ? "attr" : x[3] ? "op" : x[4] ? "str" : "punc", x[0]])
  return out
}
L.html = { rules: [
  r(WS, ""), r(/<!--[\s\S]*?(?:-->|$)/y, "com"), r(/<!\[CDATA\[[\s\S]*?(?:\]\]>|$)/y, "str"), r(/<[!?][^>]*>?/y, "meta"),
  r(/<\/?[A-Za-z][\w:.-]*(?:[^<>"']|"[^"]*"?|'[^']*'?)*>?/y, tagParts), r(/&#?\w+;/y, "esc"), r(/[^<&\s]+/y, "")] }

L.yaml = { rules: [
  r(WS, ""), r(HASHC, "com", { when: function (st, code, i) { return afterSpace(code, i) } }),
  r(/(?:---|\.\.\.)(?=\s|$)/y, "meta", { bol: true }),
  r(/(-[ \t]+)?((?:[^\s#:'"\[\]{},&*!|>-][^:#\n]*?)|"[^"\n]*"|'[^'\n]*')([ \t]*:)(?=\s|$)/y, ["punc", "prop", "punc"],
    { when: function (st, code, i) { return lineLead(code, i) || /-[ \t]*$/.test(code.slice(Math.max(0, i - 4), i)) } }),
  r(/-(?=\s|$)/y, "punc"), r(DQML, "str"), r(/'(?:[^']|'')*'?/y, "str"), r(/[|>][-+]?\d*(?=\s|$)/y, "op"),
  r(/[&*][\w-]+/y, "deco"), r(/![\w!\/.-]*/y, "type"),
  r(/(?:true|false|yes|no|on|off|null|True|False|TRUE|FALSE|Null|NULL|~)(?=[ \t]*(?:$|\n|#|,|\]|\}))/y, "cnst"),
  r(/[-+]?(?:0x[\da-fA-F]+|\d[\d_]*(?:\.\d*)?(?:[eE][+-]?\d+)?|\.inf|\.nan)(?=[ \t]*(?:$|\n|#|,|\]|\}))/y, "num"),
  r(/[^\s#,\[\]{}]+/y, ""), r(/[\[\]{},]/y, "punc")] }

L.toml = { rules: [
  r(WS, ""), r(HASHC, "com"), r(/;.*/y, "com", { bol: true }),
  r(/\[\[?[^\]\n]*\]?\]?/y, "head", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/([A-Za-z0-9_.\-]+|"[^"\n]*"|'[^'\n]*')(?=[ \t]*=)/y, "prop", { when: function (st, code, i) { return lineLead(code, i) || /[{,][ \t]*$/.test(code.slice(Math.max(0, i - 8), i)) } }),
  r(/"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)/y, "str"), r(DQ, "str"), r(/'[^'\n]*'?/y, "str"),
  r(/\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)?|\d{2}:\d{2}:\d{2}/y, "num"),
  r(/[+-]?(?:inf|nan)\b|true\b|false\b/y, "cnst"), r(/[+-]?(?:0x[\da-fA-F_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)/y, "num"),
  r(/[A-Za-z_][\w-]*/y, ""), r(/=/y, "op"), r(/[\[\]{},.]/y, "punc")] }

L.diff = { rules: [
  r(/\n/y, ""),
  r(/(?:diff |index |\+\+\+ |--- |\+\+\+$|---$|new file|deleted file|similarity|rename |Binary files|Only in ).*/y, "head", { bol: true }),
  r(/@@.*/y, "meta", { bol: true }), r(/[+>].*/y, "add", { bol: true }), r(/[-<].*/y, "del", { bol: true }),
  r(/!.*/y, "attr", { bol: true }), r(/.+/y, "")] }

L.markdown = { rules: [
  r(WS, ""),
  r(/#{1,6}(?=[ \t]|\n|$).*/y, "head", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/(?:```|~~~).*/y, "meta", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/>+/y, "com", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/(?:[-*+]|\d+[.)])(?=[ \t])(?:[ \t]+\[[ xX]\](?=[ \t]))?/y, "op", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/(?:[-*_][ \t]*){3,}(?=\n|$)/y, "punc", { when: function (st, code, i) { return lineLead(code, i) } }),
  r(/\\./y, "esc"), r(/``[^\n]*?(?:``|$)|`[^`\n]*`?/y, "str"),
  r(/(!?\[)([^\]\n]*)(\]\()([^)\n]*)(\)?)/y, ["punc", "link", "punc", "url", "punc"]),
  r(/<https?:\/\/[^>\s]*>?|https?:\/\/[^\s)>\]]+/y, "url"),
  r(/\*\*[^*\n]+\*\*?\*?|__[^_\n]+__?_?/y, "strong"),
  r(/\*[^*\s][^*\n]*\*?|_[^_\s][^_\n]*_?(?![\w])/y, "em"),
  r(/[A-Za-z0-9][\w'.,:;!?-]*/y, ""), r(/\|/y, "punc"), r(/\$[^$\n]*\$?/y, "num")] }

L.latex = { rules: [
  r(WS, ""), r(/%.*/y, "com"),
  r(/(\\(?:begin|end))([ \t]*\{)([^}\n]*)(\}?)/y, ["kw", "punc", "type", "punc"]),
  r(/\\(?:[A-Za-z@]+\*?|.)/y, "kw"), r(/\$\$?|\\\(|\\\)|\\\[|\\\]/y, "op"), r(/[{}\[\]]/y, "punc"),
  r(/[&^_~]/y, "op"), r(/\d+(?:\.\d+)?/y, "num"), r(/[A-Za-z]+/y, "")] }

var ALIAS = {
  python: "python", py: "python", python3: "python", py3: "python", ipython: "python", pycon: "python", sage: "python",
  javascript: "javascript", js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript", node: "javascript",
  typescript: "javascript", ts: "javascript", tsx: "javascript", mts: "javascript", cts: "javascript",
  json: "json", jsonc: "json", json5: "json", jsonl: "json", geojson: "json",
  bash: "bash", sh: "bash", zsh: "bash", shell: "bash", console: "bash", shellsession: "bash", ksh: "bash", fish: "bash", dash: "bash", ash: "bash", "shell-session": "bash", nix: null,
  rust: "rust", rs: "rust", c: "c", h: "c", cpp: "c", "c++": "c", cc: "c", cxx: "c", hpp: "c", hh: "c", hxx: "c", ino: "c", arduino: "c", objc: "c", glsl: "c", cuda: "c", cu: "c",
  go: "go", golang: "go", qml: "qml", qmljs: "qml",
  html: "html", htm: "html", xml: "html", xhtml: "html", svg: "html", vue: "html", svelte: "html", plist: "html", rss: "html", xsl: "html",
  css: "css", scss: "css", less: "css", sass: "css", yaml: "yaml", yml: "yaml",
  toml: "toml", ini: "toml", cfg: "toml", conf: "toml", desktop: "toml", properties: "toml", editorconfig: "toml", systemd: "toml", service: "toml",
  sql: "sql", psql: "sql", postgres: "sql", postgresql: "sql", mysql: "sql", sqlite: "sql", plsql: "sql",
  diff: "diff", patch: "diff", udiff: "diff", markdown: "markdown", md: "markdown", mdx: "markdown", gfm: "markdown",
  latex: "latex", tex: "latex", bibtex: "latex", bib: "latex", lua: "lua", luau: "lua", java: "java", kotlin: "java", kt: "java", scala: "java", groovy: "java", gradle: "java", "c#": "java", csharp: "java", cs: "java", dart: "java"
}
// "```python title=x" / "```{python}" / "```py:main.py" -> "python"
function langOf(lang) {
  var k = String(lang || "").trim().toLowerCase().replace(/^\{\.?|\}$/g, "").split(/[\s,:{]/)[0]
  return ALIAS[k] || null
}
function supported(lang) { return !!langOf(lang) }

// tokens: [[type, text], ...] with adjacent same-type runs merged
function tokenize(code, name, raw) {
  var lang = L[name], rules = lang.rules, out = [], i = 0, n = code.length
  var st = { depth: 0, cmd: true, last: "", lastText: "", scss: /^(?:scss|less|sass)$/.test(raw || "") }
  function push(t, s) {
    if (!s) return
    var last = out[out.length - 1]
    if (last && last[0] === t) last[1] += s; else out.push([t, s])
    if (/\S/.test(s)) { st.last = t || "id"; st.lastText = s }
  }
  while (i < n) {
    var bol = i === 0 || code.charCodeAt(i - 1) === 10, hit = null, m = null
    for (var k = 0; k < rules.length; k++) {
      var ru = rules[k]
      if (ru.bol && !bol) continue
      if (ru.when && !ru.when(st, code, i)) continue
      ru.re.lastIndex = i
      m = ru.re.exec(code)
      if (m && m[0].length > 0) { hit = ru; break }
    }
    if (!hit) { push("", code.charAt(i)); i++; continue }
    var end = i + m[0].length, t = hit.t
    if (typeof t === "function") t = t(m, st, code, end)
    if (typeof t === "string") push(t, m[0])
    else if (t && t.length && typeof t[0] === "string") {          // one type per capture group
      var got = ""
      for (var g = 0; g < t.length; g++) if (m[g + 1]) { push(t[g], m[g + 1]); got += m[g + 1] }
      if (got !== m[0]) push("", m[0].slice(got.length))
    } else {                                                        // [[type, text], ...] from a function
      var all = ""
      for (var q = 0; q < t.length; q++) { push(t[q][0], t[q][1]); all += t[q][1] }
      if (all !== m[0]) { out.length = 0; return null }              // a rule lost text: give up, render plain
    }
    i = end
  }
  return out
}

var cache = Object.create(null), cacheN = 0
function palKey(p) { var s = ""; for (var k in DEFAULT) s += (p && p[k]) || ""; return s }

function html(code, lang, pal) {
  try {
    var name = langOf(lang)
    code = String(code === undefined || code === null ? "" : code)
    if (!name || code === "" || code.length > MAX) return ""
    var key = name + "\u0001" + palKey(pal) + "\u0001" + code
    if (key in cache) return cache[key]
    var toks = tokenize(code, name, String(lang).trim().toLowerCase())
    if (!toks) return ""
    var p = pal || DEFAULT, h = ""
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i][0], s = esc(toks[i][1])
      var col = t && (p[t] || DEFAULT[t])
      h += col ? '<span style="color:' + col + ';' + (STYLE[t] || "") + '">' + s + "</span>" : s
    }
    if (++cacheN > 64) { cache = Object.create(null); cacheN = 1 }
    cache[key] = h
    return h
  } catch (e) {
    return ""
  }
}

// ---------- theme colours
// rgb(x): [r,g,b] 0..255 from a QML color / "#rrggbb" / "#aarrggbb" (alpha dropped), null when unparsable
function rgb(x) {
  var m = /^#(?:[\da-f]{2})?([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i.exec(String(x))
  return m ? [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)] : null
}
function hexOf(c) { return "#" + c.map(function (v) { return ("0" + Math.round(Math.max(0, Math.min(255, v))).toString(16)).slice(-2) }).join("") }
// a over b at alpha t (0 = b, 1 = a)
function blend(a, b, t) {
  var A = rgb(a), B = rgb(b)
  if (!A || !B) return A ? hexOf(A) : B ? hexOf(B) : ""
  return hexOf([0, 1, 2].map(function (i) { return A[i] * t + B[i] * (1 - t) }))
}
function lum(c) {
  var v = c.map(function (u) { u /= 255; return u <= 0.03928 ? u / 12.92 : Math.pow((u + 0.055) / 1.055, 2.4) })
  return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
}
function contrast(a, b) {
  var A = rgb(a), B = rgb(b)
  if (!A || !B) return 21
  var x = lum(A), y = lum(B)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
function hsl(c) {
  var r = c[0] / 255, g = c[1] / 255, b = c[2] / 255, mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn
  if (d === 0) return [0, 0, l]
  var s = d / (1 - Math.abs(2 * l - 1)), h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4
  return [(h * 60 + 360) % 360, s, l]
}
function fromHsl(h, s, l) {
  var C = (1 - Math.abs(2 * l - 1)) * s, X = C * (1 - Math.abs((h / 60) % 2 - 1)), m = l - C / 2, k = Math.floor(h / 60) % 6
  var t = [[C, X, 0], [X, C, 0], [0, C, X], [0, X, C], [X, 0, C], [C, 0, X]][k]
  return [(t[0] + m) * 255, (t[1] + m) * 255, (t[2] + m) * 255]
}
// fg nudged until it reaches `min` contrast on bg, keeping its hue and saturation: HSL lightness stepped up on a dark
// bg, down on a light one (the smallest step that passes wins). Already-readable colours come back unchanged.
function fit(fg, bg, min) {
  var F = rgb(fg), B = rgb(bg)
  if (!F || !B) return F ? hexOf(F) : String(fg)
  min = min || 4.5
  var out = hexOf(F)
  if (contrast(out, bg) >= min) return out
  var q = hsl(F), dir = lum(B) < 0.18 ? 1 : -1
  for (var i = 1; i <= 50; i++) {
    out = hexOf(fromHsl(q[0], q[1], Math.max(0, Math.min(1, q[2] + dir * i * 0.02))))
    if (contrast(out, bg) >= min) return out
  }
  return out
}

// the code card's background as drawn by QMdView.qml: inset at 45 % over the chat panel
function cardBg(c) { return blend(c.inset, c.panel, 0.45) }

// palette from the widget's live Theme.colors roles (ColorTheme.qml), every role fitted to 4.5:1 on the card
// background. Besides the token roles it carries fg (plain code text), label (the card's language / copy text) and bg.
function palette(c) {
  function hex(x) { var v = rgb(x); return v ? hexOf(v) : String(x) }
  var bg = cardBg(c)
  if (!rgb(bg)) return null
  var muted = blend(c.textMuted, c.textSecondary, 0.5)
  var p = { kw: hex(c.violet), str: hex(c.green), num: hex(c.orange), com: muted, fn: hex(c.blue), type: hex(c.yellow), op: hex(c.cyan),
            punc: hex(c.textSecondary), cnst: hex(c.orange), builtin: hex(c.orange), self: hex(c.red), prop: hex(c.lavender), tag: hex(c.blue),
            attr: hex(c.yellow), deco: hex(c.pink), vari: hex(c.pink), esc: hex(c.pink), meta: hex(c.cyan), head: hex(c.violet),
            add: hex(c.green), del: hex(c.red), link: hex(c.blue), url: muted, strong: hex(c.orange), em: hex(c.pink),
            fg: hex(c.textPrimary), label: hex(c.textMuted) }
  for (var k in p) p[k] = fit(p[k], bg, 4.5)
  p.bg = bg
  return p
}
