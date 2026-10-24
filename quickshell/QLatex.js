.pragma library

// LaTeX math in Q's replies -> Qt rich text (Unicode symbols + <sup>/<sub>/<i>), for the chat widget's
// MarkdownText bubbles. No TeX install: common math only (greek, operators, relations, arrows, fractions,
// roots, sums/integrals, accents, \text, \mathbb, simple environments). Unknown commands show as their name.
//
// extract(s) swaps every formula for a private-use placeholder (so the bubble's markdown/bracket cleanup
// can't touch it), restore(s, math) puts the rendered HTML back. Delimiters: $$..$$ and \[..\] (display),
// \(..\) and $..$ (inline). A single $ only opens math when it is followed by a non-space and not preceded by
// a letter/digit, and only closes when preceded by a non-space and not followed by a digit, on the same line
// (pandoc's rule), so "costs $5" or "$5 to $10" stay prose. Code spans and fenced code are left alone.

var PH_OPEN = "", PH_CLOSE = ""

var SYM = {
  // greek
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ϵ", varepsilon: "ε", zeta: "ζ", eta: "η",
  theta: "θ", vartheta: "ϑ", iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", omicron: "ο",
  pi: "π", varpi: "ϖ", rho: "ρ", varrho: "ϱ", sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ",
  phi: "ϕ", varphi: "φ", chi: "χ", psi: "ψ", omega: "ω",
  Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π", Sigma: "Σ", Upsilon: "Υ",
  Phi: "Φ", Psi: "Ψ", Omega: "Ω",
  // binary operators
  times: "×", div: "÷", cdot: "·", pm: "±", mp: "∓", ast: "∗", star: "⋆", circ: "∘", bullet: "•",
  oplus: "⊕", otimes: "⊗", ominus: "⊖", odot: "⊙", cap: "∩", cup: "∪", setminus: "∖", wedge: "∧",
  land: "∧", vee: "∨", lor: "∨", neg: "¬", lnot: "¬", dagger: "†",
  // relations
  le: "≤", leq: "≤", ge: "≥", geq: "≥", leqslant: "≤", geqslant: "≥", ne: "≠", neq: "≠", approx: "≈",
  equiv: "≡", sim: "∼", simeq: "≃", cong: "≅", propto: "∝", ll: "≪", gg: "≫", prec: "≺", succ: "≻",
  in: "∈", notin: "∉", ni: "∋", subset: "⊂", supset: "⊃", subseteq: "⊆", supseteq: "⊇", perp: "⊥",
  parallel: "∥", mid: "∣", models: "⊨", vdash: "⊢", coloneqq: "≔", doteq: "≐",
  // arrows
  to: "→", rightarrow: "→", leftarrow: "←", gets: "←", leftrightarrow: "↔", Rightarrow: "⇒",
  Leftarrow: "⇐", Leftrightarrow: "⇔", implies: "⟹", impliedby: "⟸", iff: "⟺", mapsto: "↦",
  longrightarrow: "⟶", longleftarrow: "⟵", longmapsto: "⟼", uparrow: "↑", downarrow: "↓",
  Uparrow: "⇑", Downarrow: "⇓", nearrow: "↗", searrow: "↘", hookrightarrow: "↪", rightleftharpoons: "⇌",
  // big operators
  sum: "∑", prod: "∏", coprod: "∐", int: "∫", iint: "∬", iiint: "∭", oint: "∮", bigcup: "⋃",
  bigcap: "⋂", bigoplus: "⨁", bigotimes: "⨂", bigvee: "⋁", bigwedge: "⋀",
  // misc
  infty: "∞", partial: "∂", nabla: "∇", forall: "∀", exists: "∃", nexists: "∄", emptyset: "∅",
  varnothing: "∅", angle: "∠", triangle: "△", degree: "°", prime: "′", hbar: "ℏ", ell: "ℓ", Re: "ℜ",
  Im: "ℑ", aleph: "ℵ", wp: "℘", therefore: "∴", because: "∵", top: "⊤", bot: "⊥", checkmark: "✓",
  ldots: "…", cdots: "⋯", vdots: "⋮", ddots: "⋱", dots: "…", dotsc: "…", dotsb: "⋯",
  langle: "⟨", rangle: "⟩", lceil: "⌈", rceil: "⌉", lfloor: "⌊", rfloor: "⌋", vert: "|", Vert: "‖",
  lvert: "|", rvert: "|", lVert: "‖", rVert: "‖", backslash: "\\", surd: "√", square: "□", Box: "□",
  lbrace: "{", rbrace: "}", "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
  "|": "‖", ",": " ", ":": " ", ";": " ", ">": " ", "!": "", " ": " ",
  quad: " ", qquad: "  ", enspace: " ", thinspace: " ",
  colon: ":", lt: "<", gt: ">"
}
// upright function names
var FUNCS = ["sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
             "coth", "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det",
             "dim", "ker", "deg", "gcd", "lcm", "arg", "Pr", "mod", "bmod", "hom", "tr", "sgn"]
var NOOP = ["left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
            "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "middle", "nonumber",
            "notag", "label", "tag"]
var ACCENT = { hat: "̂", widehat: "̂", bar: "̄", overline: "̅", vec: "⃗",
               dot: "̇", ddot: "̈", tilde: "̃", widetilde: "̃", acute: "́",
               grave: "̀", breve: "̆", check: "̌", underline: "̲" }
var BB = { R: "ℝ", N: "ℕ", Z: "ℤ", Q: "ℚ", C: "ℂ", P: "ℙ", H: "ℍ", E: "𝔼", F: "𝔽", "1": "𝟙" }
var CAL = { A: "𝒜", B: "ℬ", C: "𝒞", D: "𝒟", E: "ℰ", F: "ℱ", G: "𝒢", H: "ℋ", I: "ℐ", J: "𝒥", K: "𝒦",
            L: "ℒ", M: "ℳ", N: "𝒩", O: "𝒪", P: "𝒫", Q: "𝒬", R: "ℛ", S: "𝒮", T: "𝒯", U: "𝒰", V: "𝒱",
            W: "𝒲", X: "𝒳", Y: "𝒴", Z: "𝒵" }
var VULGAR = { "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "1/6": "⅙",
               "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞" }

// every ASCII char that markdown or HTML could act on goes out as an entity
function esc(s) {
  return s.replace(/[<>&*_`\[\]\\~|#+\-!{}()$=.:]/g, function (c) { return "&#" + c.charCodeAt(0) + ";" })
}

// ---------- parser: LaTeX math -> {h: html, s: simple (single symbol/number, no parens needed)}
function Parser(src) { this.s = src; this.i = 0 }
Parser.prototype.peek = function () { return this.s.charAt(this.i) }
Parser.prototype.ws = function () { while (/\s/.test(this.peek()) && this.i < this.s.length) this.i++ }
Parser.prototype.cmdName = function () {           // after the backslash
  var m = /^[A-Za-z]+\*?/.exec(this.s.slice(this.i))
  if (m) { this.i += m[0].length; return m[0].replace(/\*$/, "") }
  var c = this.s.charAt(this.i); this.i++; return c
}
Parser.prototype.rawGroup = function () {          // {...} as raw text (for \text, \begin names)
  this.ws()
  if (this.peek() !== "{") { var c = this.s.charAt(this.i); this.i++; return c }
  var d = 0, st = ++this.i
  for (; this.i < this.s.length; this.i++) {
    var ch = this.s.charAt(this.i)
    if (ch === "\\") { this.i++; continue }
    if (ch === "{") d++
    else if (ch === "}") { if (d === 0) break; d-- }
  }
  var r = this.s.slice(st, this.i); this.i++; return r
}
Parser.prototype.optArg = function () {            // [...] optional argument
  this.ws()
  if (this.peek() !== "[") return null
  var e = this.s.indexOf("]", this.i)
  if (e < 0) return null
  var r = this.s.slice(this.i + 1, e); this.i = e + 1; return r
}
Parser.prototype.arg = function () {               // one argument: a group or a single atom
  this.ws()
  if (this.peek() === "{") { this.i++; var r = this.expr("}"); this.i++; return r }
  return this.atom() || { h: "", s: true }
}
Parser.prototype.expr = function (stop) {
  var out = "", n = 0, simple = true, depth = 0
  while (this.i < this.s.length) {
    var c = this.peek()
    if (stop && c === stop) break
    if (c === "}") { this.i++; continue }               // stray brace
    if (c === "^" || c === "_") {
      this.i++
      var a = this.arg()
      var sh = a.h.replace(/[ \u00A0](&#[0-9]+;|[^\s<&])[ \u00A0]/g, "$1")      // scripts: no spacing around = + etc
      out += c === "^" ? "<sup>" + sh + "</sup>" : "<sub>" + sh + "</sub>"
      continue
    }
    if (c === "'") { this.i++; out += "′"; continue }
    if (/\s/.test(c)) { this.i++; continue }
    if (c === "\\" && /^\\(end\b|\\|cr\b)/.test(this.s.slice(this.i)) && stop === "\\row") break
    if (c === "&" && stop === "\\row") break
    var at = this.atom()
    if (!at) continue
    if (at.minus && n > 0 && !/[\s\u00A0(]$|&#40;$|<sub>$|<sup>$/.test(out)) at = { h: "\u00A0−\u00A0", s: false }
    out += at.h; n++
    if (at.h === "&#40;" || at.h === "&#91;") depth++                // operators inside (...) don't count
    else if ((at.h === "&#41;" || at.h === "&#93;") && depth > 0) depth--
    else if (depth === 0) simple = simple && at.s
  }
  return { h: out.replace(/<\/i><i>/g, ""), s: simple }
}
Parser.prototype.atom = function () {
  var c = this.peek()
  if (c === "{") { this.i++; var g = this.expr("}"); this.i++; return g }
  if (c === "\\") { this.i++; return this.command(this.cmdName()) }
  if (/[0-9.]/.test(c)) {
    var m = /^[0-9]+(?:\.[0-9]+)?|^\./.exec(this.s.slice(this.i)); this.i += m[0].length
    return { h: esc(m[0]), s: true }
  }
  this.i++
  if (/[A-Za-z]/.test(c)) return { h: "<i>" + c + "</i>", s: true }
  if (c === "-") return { h: "−", s: true, minus: true }
  if (c === "*") return { h: "∗", s: true }
  if (c === "~") return { h: " ", s: true }
  if (c === "&") return { h: " ", s: true }
  if (/[=<>]/.test(c)) return { h: "\u00A0" + esc(c) + " ", s: false }     // may wrap after a relation,
  if (c === "+") return { h: "\u00A0+\u00A0", s: false }                  // never around + or before =
  return { h: esc(c), s: true }
}
Parser.prototype.command = function (name) {
  if (name === "\\") return { h: "<br>", s: false }
  if (Object.prototype.hasOwnProperty.call(SYM, name)) {
    var sy = SYM[name]
    if (/^[=≤≥≠≈≡∼≃≅∝∈∉⊂⊃⊆⊇→←↔⇒⇐⇔⟹⟸⟺↦⟶⟵⟼≪≫]$/.test(sy)) return { h: "\u00A0" + esc(sy) + " ", s: false }
    return { h: esc(sy), s: true }
  }
  if (FUNCS.indexOf(name) >= 0) return { h: name + (name === "mod" || name === "bmod" ? " " : " "), s: false }
  if (NOOP.indexOf(name) >= 0) {
    if (name === "label" || name === "tag") this.rawGroup()
    if (name === "left" || name === "right" || name === "middle") {   // keep the delimiter, drop "."
      this.ws()
      if (this.peek() === ".") { this.i++; return { h: "", s: true } }
    }
    return { h: "", s: true }
  }
  switch (name) {
  case "frac": case "dfrac": case "tfrac": case "cfrac": {
    var a = this.arg(), b = this.arg()
    var plain = (a.h + "/" + b.h).replace(/<\/?i>/g, "")
    if (VULGAR[plain]) return { h: VULGAR[plain], s: true }
    var short = function (x) { return x.s && x.h.replace(/<[^>]*>/g, "").replace(/&#[0-9]+;/g, "_").length <= 3 }
    if (short(a) && short(b)) return { h: "<sup>" + a.h + "</sup>⁄<sub>" + b.h + "</sub>", s: true }
    return { h: (a.s ? a.h : "(" + a.h + ")") + "\u202F/\u202F" + (b.s ? b.h : "(" + b.h + ")"), s: false }
  }
  case "binom": case "dbinom": case "tbinom": {
    var n = this.arg(), k = this.arg()
    return { h: "(<sup>" + n.h + "</sup><sub>" + k.h + "</sub>)", s: true }
  }
  case "sqrt": {
    var idx = this.optArg(), r = this.arg()
    var root = idx === "3" ? "∛" : idx === "4" ? "∜" : idx ? "<sup>" + this.sub(idx).h + "</sup>√" : "√"
    var one = r.h.replace(/<[^>]*>/g, "").replace(/&#[0-9]+;/g, "_").length <= 1
    return { h: root + (one ? r.h : "(" + r.h + ")"), s: true }
  }
  case "text": case "textrm": case "textnormal": case "mathrm": case "operatorname": case "mbox":
  case "textup": case "mathsf": case "textsf": case "mathtt": case "texttt":
    return { h: esc(this.rawGroup().replace(/\\([{}$%&#_ ])/g, "$1").replace(/~/g, " ")), s: false }
  case "textbf": case "mathbf": case "boldsymbol": case "bm":
    return { h: "<b>" + this.arg().h.replace(/<\/?i>/g, "") + "</b>", s: true }
  case "textit": case "mathit": case "emph":
    return { h: "<i>" + esc(this.rawGroup()) + "</i>", s: true }
  case "mathbb": case "Bbb": case "mathcal": case "mathscr": case "mathfrak": {
    var t = this.rawGroup(), map = name === "mathcal" || name === "mathscr" ? CAL : BB
    return { h: t.split("").map(function (ch) { return map[ch] || ch }).join(""), s: t.length <= 1 }
  }
  case "not": {
    var x = this.atom()
    return { h: x ? x.h.replace(/^ ?(.)/, " $1̸") : "", s: false }
  }
  case "overset": case "stackrel": {
    var top = this.arg(), base = this.arg()
    return { h: base.h + "<sup>" + top.h + "</sup>", s: false }
  }
  case "underset": {
    var bot = this.arg(), bs = this.arg()
    return { h: bs.h + "<sub>" + bot.h + "</sub>", s: false }
  }
  case "pmod": return { h: " (mod " + this.arg().h + ")", s: false }
  case "begin": return this.env(this.rawGroup())
  case "end": this.rawGroup(); return { h: "", s: true }
  case "hspace": case "vspace": case "phantom": this.rawGroup(); return { h: " ", s: true }
  case "color": case "textcolor": this.rawGroup(); return { h: "", s: true }
  case "boxed": return { h: "[" + this.arg().h + "]", s: true }
  }
  if (ACCENT[name]) {
    var ac = this.arg(), mark = ACCENT[name]
    var many = name === "overline" || name === "underline" || name === "widehat" || name === "widetilde"
    // put the combining mark after each letter (one letter for \hat x, every letter for \overline{AB})
    var done = false
    var h = ac.h.replace(/(<[^>]*>)|(&#[0-9]+;|[^<&])/g, function (all, tag, ch) {
      if (tag) return tag
      if (done && !many) return ch
      done = true; return ch + mark
    })
    return { h: h, s: ac.s }
  }
  return { h: esc("\\" + name), s: true }                 // unknown: show it as written
}
Parser.prototype.sub = function (src) { return new Parser(src).expr(null) }
Parser.prototype.env = function (name) {
  var envName = name.replace(/\*$/, "")
  if (envName === "array") this.rawGroup()
  // rows split on \\, cells on &
  var rows = [], row = [], guard = 0
  while (this.i < this.s.length && guard++ < 10000) {
    var cell = this.expr("\\row")
    row.push(cell.h.trim())
    if (this.peek() === "&") { this.i++; continue }
    if (this.s.slice(this.i, this.i + 2) === "\\\\") { this.i += 2; rows.push(row); row = []; continue }
    if (this.s.slice(this.i, this.i + 3) === "\\cr") { this.i += 3; rows.push(row); row = []; continue }
    if (/^\\end\b/.test(this.s.slice(this.i))) { this.i += 4; this.rawGroup(); break }
    break
  }
  if (row.length && row.join("") !== "") rows.push(row)
  var mat = { matrix: ["", ""], pmatrix: ["(", ")"], bmatrix: ["[", "]"], Bmatrix: ["{", "}"],
              vmatrix: ["|", "|"], Vmatrix: ["‖", "‖"], smallmatrix: ["", ""] }
  if (mat[envName]) {
    var br = mat[envName]
    var inner = rows.map(function (r) { return r.join(" ") }).join("; ")
    return { h: esc(br[0]) + inner + esc(br[1]), s: true }
  }
  if (envName === "cases" || envName === "dcases") {
    return { h: "{ " + rows.map(function (r) { return r.join(", ") }).join("<br> "), s: false }
  }
  // aligned/align/gather/split/eqnarray/array: one line per row
  return { h: rows.map(function (r) { return r.join(" ") }).join("<br>"), s: false }
}

function toHtml(tex) {
  try {
    return new Parser(tex).expr(null).h.replace(/[ \u00A0]{2,}/g, "\u00A0").replace(/^[ \u00A0]+|[ \u00A0]+$/g, "")
  } catch (e) {
    return esc(tex)
  }
}

// ---------- delimiters
function findInlineClose(s, from) {
  for (var j = from; j < s.length; j++) {
    var c = s.charAt(j)
    if (c === "\n") return -1
    if (c === "\\") { j++; continue }
    if (c !== "$") continue
    if (!/\s/.test(s.charAt(j - 1)) && !/[0-9]/.test(s.charAt(j + 1))) {
      // money, not math: "$5 ... 3$" style spans need something mathematical inside
      var body = s.slice(from, j)
      if (/^[0-9]/.test(body) && !/[\\^_={}+*\/<>]/.test(body)) return -1
      return j
    }
    return -1                                          // a $ that can't close: TeX math never contains a bare $
  }
  return -1
}

function extract(s) {
  var out = "", math = [], i = 0, n = s.length
  function put(tex, display) {
    out += PH_OPEN + math.length + PH_CLOSE
    math.push({ h: toHtml(tex.trim()), d: display })
  }
  while (i < n) {
    var c = s.charAt(i)
    var bol = i === 0 || s.charAt(i - 1) === "\n"
    // fenced code: copy to the closing fence
    if (bol) {
      var f = /^[ \t]*(```+|~~~+)/.exec(s.slice(i, i + 40))
      if (f) {
        var close = s.indexOf("\n", i), fence = f[1]
        var end = -1
        while (close >= 0) {
          var line = s.slice(close + 1, s.indexOf("\n", close + 1) < 0 ? n : s.indexOf("\n", close + 1))
          if (line.trim().indexOf(fence) === 0) { end = close + 1 + line.length; break }
          close = s.indexOf("\n", close + 1)
        }
        if (end < 0) end = n
        out += s.slice(i, end); i = end; continue
      }
    }
    if (c === "`") {                                   // code span: copy to the matching backtick run
      var run = /^`+/.exec(s.slice(i))[0]
      var e = s.indexOf(run, i + run.length)
      if (e < 0) { out += run; i += run.length; continue }
      out += s.slice(i, e + run.length); i = e + run.length; continue
    }
    if (c === "\\") {
      var d = s.charAt(i + 1)
      if (d === "[" || d === "(") {
        var closer = d === "[" ? "\\]" : "\\)"
        var e2 = s.indexOf(closer, i + 2)
        if (e2 > i + 2 && s.slice(i + 2, e2).trim() !== "") { put(s.slice(i + 2, e2), d === "["); i = e2 + 2; continue }
      }
      out += c + d; i += 2; continue                   // any other escape (\$, \*, ...) passes through
    }
    if (c === "$") {
      if (s.charAt(i + 1) === "$") {
        var e3 = s.indexOf("$$", i + 2)
        if (e3 > i + 2 && s.slice(i + 2, e3).trim() !== "") { put(s.slice(i + 2, e3), true); i = e3 + 2; continue }
        out += "$$"; i += 2; continue
      }
      var nx = s.charAt(i + 1), pv = i > 0 ? s.charAt(i - 1) : ""
      if (nx && !/\s/.test(nx) && !/[A-Za-z0-9]/.test(pv)) {
        var e4 = findInlineClose(s, i + 1)
        if (e4 > i + 1) { put(s.slice(i + 1, e4), false); i = e4 + 1; continue }
      }
    }
    out += c; i++
  }
  return { text: out, math: math }
}

// display math alone on its line becomes its own indented paragraph (an HTML <p> block loses the break); anywhere else it stays inline
function restore(s, math) {
  if (!math.length) return s
  return s.replace(new RegExp("^([ \\t]*)" + PH_OPEN + "(\\d+)" + PH_CLOSE + "[ \\t]*$", "gm"), function (all, ind, k) {
    var m = math[+k]
    return m.d ? "\n\u2003\u2003" + m.h + "\n" : ind + m.h
  }).replace(new RegExp(PH_OPEN + "(\\d+)" + PH_CLOSE, "g"), function (all, k) { return math[+k].h })
}
