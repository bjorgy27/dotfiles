.pragma library
.import "QLatex.js" as Latex

// Markdown in Q's replies -> blocks for the chat widget. Untrusted text, so this is a small renderer of its
// own instead of Qt's MarkdownText (which passes raw HTML through and fetches remote images):
//   - fenced code (``` / ~~~) is split out first and becomes its own block ({kind: "code"}), drawn by the widget
//     as a monospace card with a language label and a copy button. Nothing inside a fence is touched (no LaTeX,
//     no marker cleanup, no markdown). An unclosed fence (still streaming) is an open code block to the end.
//   - everything between fences becomes Qt rich text ({kind: "rich"}): headings, paragraphs (a single newline is
//     a line break, as in chat), bold/italic/strike, inline code, links, nested lists, task boxes, blockquotes,
//     pipe tables, horizontal rules and LaTeX (QLatex.js). All text is HTML-escaped; links only keep
//     http(s)/mailto targets; images become a link, never an <img>. <br> and <details>/<summary> lines are
//     understood, any other HTML shows as text.
//   - voice-only markers ([quiet], [listen], [end], [lang:xx]), stage directions ("[laughs]") and MEDIA: lines
//     are dropped from prose only, never from code.
//   - while a reply streams (o.pending), half-typed markup at the end is closed or hidden so it doesn't flash.
//
// render(text, o) -> { blocks: [{kind: "rich"|"code"|"rule", html, code, lang, open}], plain, wide }
//   o.c: colors {text, strong, muted, code, codeBg, link, border, th, quote}, o.px: base font px, o.pending
// finalText(streamed, ev): the text + spoken offset to keep when a turn finishes (done/report events carry the voice
// bridge's speech-flattened text, which has no code blocks; see below).
// safeCut(text, cut): moves a dim/spoken cut that falls inside a fenced code block to the block's start, and one
// inside a heading/list/quote/table line to the end of that line.

var T_OPEN = "", T_CLOSE = ""
var FENCE_OPEN = /^([ \t]*)(`{3,}|~{3,})[ \t]*([^\s`]*)[^`]*$/
var FENCE_CLOSE = /^[ \t]*(`{3,}|~{3,})[ \t]*$/
var LIST = /^( *)([-*+•]|\d{1,9}[.)])( +|$)(.*)$/
var DELIM = /^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$/

function escHtml(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
function escAttr(s) { return escHtml(s).replace(/"/g, "&quot;") }
function safeUrl(u) {
  u = u.trim()
  if (/^www\./i.test(u)) u = "https://" + u
  return /^(https?:\/\/|mailto:)/i.test(u) ? u : ""
}

// ---------- fences
// [{t: "prose", s, at}, {t: "code", code, lang, open, at, end}] ; at/end are offsets into text
function split(text) {
  var lines = text.split("\n"), out = [], prose = [], pos = 0, proseAt = 0
  function flush() { if (prose.length) out.push({ t: "prose", s: prose.join("\n"), at: proseAt }); prose = [] }
  for (var i = 0; i < lines.length; i++) {
    var m = FENCE_OPEN.exec(lines[i])
    if (!m) { if (!prose.length) proseAt = pos; prose.push(lines[i]); pos += lines[i].length + 1; continue }
    flush()
    var ind = m[1].replace(/\t/g, "    ").length, ch = m[2].charAt(0), len = m[2].length
    var at = pos, body = [], closed = false
    pos += lines[i].length + 1
    for (i++; i < lines.length; i++) {
      var c = FENCE_CLOSE.exec(lines[i])
      pos += lines[i].length + 1
      if (c && c[1].charAt(0) === ch && c[1].length >= len) { closed = true; break }
      var l = lines[i], k = 0
      while (k < ind && l.charAt(k) === " ") k++
      body.push(l.slice(k))
    }
    out.push({ t: "code", code: body.join("\n"), lang: m[3].toLowerCase(), open: !closed, at: at, end: Math.min(pos, text.length) })
  }
  flush()
  return out
}

function safeCut(text, cut) {
  if (cut < 0) return cut
  var segs = split(text)
  for (var i = 0; i < segs.length; i++)
    if (segs[i].t === "code" && cut > segs[i].at && cut < segs[i].end) return segs[i].at
  // inside a heading, list item, quote or table row: move to the end of that line so the line stays whole
  var bol = text.lastIndexOf("\n", cut - 1) + 1
  if (cut > bol && /^[ \t]*(#{1,6}[ \t]|>|\||[-*+•][ \t]|\d{1,9}[.)][ \t])/.test(text.slice(bol, cut + 1))) {
    var eol = text.indexOf("\n", cut)
    return eol < 0 ? text.length : eol + 1
  }
  return cut
}

// ---------- prose cleanup (outside inline code only)
function outsideCode(s, fn) {
  var out = "", i = 0, from = 0
  while (i < s.length) {
    if (s.charAt(i) !== "`") { i++; continue }
    var run = /^`+/.exec(s.slice(i))[0], e = s.indexOf(run, i + run.length)
    while (e >= 0 && s.charAt(e + run.length) === "`") e = s.indexOf(run, e + run.length + 1)
    if (e < 0) { i += run.length; continue }
    out += fn(s.slice(from, i)) + s.slice(i, e + run.length)
    i = from = e + run.length
  }
  return out + fn(s.slice(from))
}
function cleanProse(s) {
  return outsideCode(s, function (t) {
    return t.replace(/^[ \t]*MEDIA:.*$/gm, "")
            .replace(/\[(?:quiet|listen|end)\]|\[\s*lang(?:uage)?\s*[:=][^\]\n]{0,16}\]/gi, "")
            .replace(/\[[^\[\]\n`]*\](?![(\[:])/g, function (m) { return /^\[[ xX]\]$/.test(m) ? m : "" })
  })
}

// streaming: close or hide markup that is only half there at the very end
function autoClose(s) {
  s = s.replace(/(^|\n)[ \t]*(`{1,2}|~{1,2})[ \t]*$/, "$1")            // a fence being typed
  s = s.replace(/(^|\s)[*_~`]+$/, "$1")                                // a marker with nothing after it yet
  s = s.replace(/!?\[([^\]\n]*)\]\([^)\s]*$/, "$1")                    // [text](half-a-url
  var p = s.lastIndexOf("\n\n"), head = s.slice(0, p + 2), tail = s.slice(p + 2)
  var re = /`+/g, m, open = ""
  while ((m = re.exec(tail)) !== null) {
    if (!open) open = m[0]
    else if (m[0] === open) open = ""
  }
  if (open) tail += open
  var bare = outsideCode(tail, function (t) { return t }).replace(/`[^`]*`/g, "")
  if (((bare.match(/\*\*/g) || []).length) % 2) tail += "**"
  if (((bare.match(/~~/g) || []).length) % 2) tail += "~~"
  return head + tail
}

// ---------- inline
function inline(s, ctx, noLinks) {
  var toks = ctx.toks
  function tok(h) { toks.push(h); return T_OPEN + (toks.length - 1) + T_CLOSE }
  function link(url, labelHtml) {
    var u = safeUrl(url)
    if (!u) return tok(labelHtml)
    return tok('<a href="' + escAttr(u) + '"><span style="color:' + ctx.c.link + '">' + labelHtml + '</span></a>')
  }
  var out = "", i = 0, n = s.length
  while (i < n) {
    var c = s.charAt(i), rest
    if (c === "`") {
      var run = /^`+/.exec(s.slice(i))[0], e = s.indexOf(run, i + run.length)
      while (e >= 0 && s.charAt(e + run.length) === "`") e = s.indexOf(run, e + run.length + 1)
      if (e < 0) { out += run; i += run.length; continue }
      var code = s.slice(i + run.length, e).replace(/\n/g, " ")
      if (/^ .*[^ ].* $/.test(code)) code = code.slice(1, -1)
      out += tok('<span style="background-color:' + ctx.c.codeBg + '; color:' + ctx.c.code + '">' + escHtml(code) + '</span>')
      i = e + run.length; continue
    }
    if (c === "\\" && i + 1 < n && /[!-\/:-@\[-`{-~]/.test(s.charAt(i + 1))) { out += tok(escHtml(s.charAt(i + 1))); i += 2; continue }
    if (c === "\\" && s.charAt(i + 1) === "\n") { out += "\n"; i += 2; continue }
    if (!noLinks && c === "<" && (rest = /^<((?:https?:\/\/|mailto:)[^\s<>]+)>/i.exec(s.slice(i)))) {
      out += link(rest[1], escHtml(rest[1])); i += rest[0].length; continue
    }
    if (!noLinks && (c === "[" || (c === "!" && s.charAt(i + 1) === "["))) {
      var img = c === "!", lb = i + (img ? 1 : 0), depth = 0, j = lb
      for (; j < n; j++) {
        var d = s.charAt(j)
        if (d === "\\") { j++; continue }
        if (d === "[") depth++
        else if (d === "]" && --depth === 0) break
        else if (d === "\n" && s.charAt(j + 1) === "\n") { j = n; break }
      }
      if (j < n && s.charAt(j + 1) === "(") {
        var k = j + 2, par = 0, url = ""
        if (s.charAt(k) === "<") { var gt = s.indexOf(">", k); if (gt > 0) { url = s.slice(k + 1, gt); k = gt + 1 } }
        else {
          for (; k < n; k++) {
            var ch = s.charAt(k)
            if (/\s/.test(ch)) break
            if (ch === "(") par++
            else if (ch === ")") { if (par === 0) break; par-- }
          }
          url = s.slice(j + 2, k)
        }
        var t = /^[ \t]*(?:"[^"\n]*"|'[^'\n]*')?[ \t]*\)/.exec(s.slice(k))
        if (t) {
          var label = s.slice(lb + 1, j)
          if (img) {
            var alt = "🖼 " + escHtml(label.trim() || "image")
            out += safeUrl(url) ? link(url, alt) : tok(alt)
          } else out += link(url, inline(label, ctx, true))
          i = k + t[0].length; continue
        }
      }
      out += c; i++; continue
    }
    if (!noLinks && (c === "h" || c === "w") && !/[A-Za-z0-9]/.test(s.charAt(i - 1)) &&
        (rest = /^(?:https?:\/\/|www\.)[^\s<>]+/i.exec(s.slice(i)))) {
      var u2 = rest[0].replace(/[.,:;!?'"*_~]+$/, "")
      while (/\)$/.test(u2) && (u2.match(/\)/g) || []).length > (u2.match(/\(/g) || []).length) u2 = u2.slice(0, -1)
      out += link(u2, escHtml(u2)); i += u2.length; continue
    }
    out += c; i++
  }
  var h = escHtml(out)
    .replace(/&lt;br\s*\/?&gt;/gi, "\n")
    .replace(/\*\*\*(?![\s*])([\s\S]*?[^\s*])\*\*\*/g, "<b><i>$1</i></b>")
    .replace(/\*\*(?!\s)([\s\S]*?[^\s])\*\*/g, "<b>$1</b>")
    .replace(/(^|[^A-Za-z0-9_])__(?!\s)([\s\S]*?[^\s])__(?![A-Za-z0-9_]|\.[A-Za-z0-9])/g, "$1<b>$2</b>")
    .replace(/(^|[^*\\])\*(?![\s*])([^*\n]*?[^\s*]|[^\s*])\*(?!\*)/g, "$1<i>$2</i>")
    .replace(/(^|[^A-Za-z0-9_])_(?![\s_])([^_\n]*?[^\s_]|[^\s_])_(?![A-Za-z0-9_]|\.[A-Za-z0-9])/g, "$1<i>$2</i>")
    .replace(/~~(?!\s)([\s\S]*?[^\s])~~/g, "<s>$1</s>")
  var guard = 0
  while (h.indexOf(T_OPEN) >= 0 && guard++ < 8)
    h = h.replace(new RegExp(T_OPEN + "(\\d+)" + T_CLOSE, "g"), function (a, k) { return toks[+k] })
  h = h.replace(new RegExp(Latex.PH_OPEN + "(\\d+)" + Latex.PH_CLOSE, "g"), function (a, k) {
    var m = ctx.math[+k]; return m ? m.h : ""
  })
  return h.replace(/\n/g, "<br>")
}

// ---------- blocks (each: {k: "p"|"x", inner, html})
function isBlank(l) { return /^\s*$/.test(l) }
function indentOf(l) { return /^ */.exec(l)[0].length }
function isTableStart(lines, i) {
  return i + 1 < lines.length && lines[i].indexOf("|") >= 0 && lines[i + 1].indexOf("|") >= 0 &&
         lines[i + 1].indexOf("-") >= 0 && DELIM.test(lines[i + 1])
}
function isHeading(l) { return /^ {0,3}#{1,6}(?:[ \t]|$)/.test(l) }
function isRule(l) { return /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(l) }
function isBlockStart(l) { return isHeading(l) || isRule(l) || /^ {0,3}>/.test(l) || LIST.test(l) }
function splitRow(l) {
  var s = l.trim().replace(/^\|/, ""), cells = [], cur = "", tick = false
  if (/[^\\]\|$/.test(s) || s === "|") s = s.slice(0, -1)
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i)
    if (c === "\\" && s.charAt(i + 1) === "|") { cur += "|"; i++; continue }
    if (c === "`") tick = !tick
    if (c === "|" && !tick) { cells.push(cur.trim()); cur = ""; continue }
    cur += c
  }
  cells.push(cur.trim())
  return cells
}

function para(lines, ctx, out) {
  var buf = []
  function flush() {
    if (!buf.length) return
    var inner = inline(buf.join("\n").replace(/[ \t]*\\?$/gm, "").replace(/^[ \t]+/gm, ""), ctx)
    out.push({ k: "p", inner: inner, html: '<p style="margin-top:%TOP%px; margin-bottom:0px">' + inner + "</p>" })
    buf = []
  }
  var disp = new RegExp("^\\s*" + Latex.PH_OPEN + "(\\d+)" + Latex.PH_CLOSE + "\\s*$")
  for (var i = 0; i < lines.length; i++) {
    var m = disp.exec(lines[i])
    if (m && ctx.math[+m[1]] && ctx.math[+m[1]].d) {
      flush(); ctx.wide = true
      out.push({ k: "x", html: '<p align="center" style="margin-top:%TOP%px; margin-bottom:0px">' + ctx.math[+m[1]].h + "</p>" })
    } else buf.push(lines[i])
  }
  flush()
}

function list(lines, i, ctx, out) {
  var first = LIST.exec(lines[i]), ind = first[1].length, ordered = /\d/.test(first[2])
  var start = ordered ? parseInt(first[2], 10) : 1, items = []
  while (i < lines.length) {
    var m = LIST.exec(lines[i])
    if (!m || m[1].length >= ind + 2 || /\d/.test(m[2]) !== ordered) break
    var col = m[1].length + m[2].length + (m[3].length ? Math.min(m[3].length, 4) : 1)
    var raw = [], lazy = []
    i++
    while (i < lines.length) {
      var L = lines[i]
      if (isBlank(L)) {
        var j = i; while (j < lines.length && isBlank(lines[j])) j++
        if (j < lines.length && indentOf(lines[j]) >= Math.min(col, ind + 2)) { for (; i < j; i++) raw.push(""); continue }
        break
      }
      if (indentOf(L) >= Math.min(col, ind + 2)) { raw.push(L); i++; continue }
      if (!isBlockStart(L) && !isTableStart(lines, i) && (raw.length === 0 || !isBlank(raw[raw.length - 1]))) {
        raw.push(L.trim()); i++; continue                                 // lazy continuation line
      }
      break
    }
    var dd = col
    for (var r = 0; r < raw.length; r++) if (!isBlank(raw[r])) dd = Math.min(dd, indentOf(raw[r]))
    var body = [m[4]].concat(raw.map(function (l) { return l.slice(Math.min(dd, indentOf(l))) }))
    var task = /^\[([ xX])\][ \t]+/.exec(body[0])
    if (task) body[0] = body[0].slice(task[0].length)
    ctx.depth++
    var sub = blocks(body, ctx), html = ""
    ctx.depth--
    for (var b = 0; b < sub.length; b++)
      html += sub[b].k === "p" ? (b > 0 ? "<br>" : "") + sub[b].inner : sub[b].html.replace(/%TOP%/g, "0")
    items.push((task ? '<li class="' + (task[1] === " " ? "unchecked" : "checked") + '">' : "<li>") + html + "</li>")
  }
  ctx.wide = true
  var tag = ordered ? "ol" : "ul"
  out.push({ k: "x", html: "<" + tag + (ordered && start !== 1 ? ' start="' + start + '"' : "") +
                           ' style="margin-top:%TOP%px; margin-bottom:0px; margin-left:0px; -qt-list-indent:' + (ctx.depth + 1) + '">' +
                           items.join("") + "</" + tag + ">" })
  return i
}

function table(lines, i, ctx, out) {
  var head = splitRow(lines[i]), aligns = splitRow(lines[i + 1]).map(function (d) {
    return /^:-+:$/.test(d) ? "center" : /-:$/.test(d) ? "right" : "left"
  })
  var rows = []
  for (i += 2; i < lines.length && !isBlank(lines[i]) && lines[i].indexOf("|") >= 0; i++) rows.push(splitRow(lines[i]))
  var ncol = head.length
  function cell(tag, txt, k, bg) {
    return "<" + tag + ' align="' + (aligns[k] || "left") + '"' + (bg ? ' bgcolor="' + bg + '"' : "") + ">" +
           (tag === "th" ? '<span style="color:' + ctx.c.strong + '">' : "") + inline(txt || "", ctx) +
           (tag === "th" ? "</span>" : "") + "</" + tag + ">"
  }
  var h = '<table border="1" cellspacing="0" cellpadding="4" style="margin-top:%TOP%px; border-collapse:collapse; border-style:solid; border-color:' +
          ctx.c.border + '"><tr>'
  for (var k = 0; k < ncol; k++) h += cell("th", head[k], k, "")
  h += "</tr>"
  for (var r = 0; r < rows.length; r++) {
    h += "<tr>"
    for (k = 0; k < ncol; k++) h += cell("td", rows[r][k], k, "")
    h += "</tr>"
  }
  ctx.wide = true
  out.push({ k: "x", html: h + "</table>" })
  return i
}

function blocks(lines, ctx) {
  var out = [], buf = [], i = 0, m
  function flush() { if (buf.length) { para(buf, ctx, out); buf = [] } }
  while (i < lines.length) {
    var L = lines[i]
    if (isBlank(L)) { flush(); i++; continue }
    if ((m = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/.exec(L))) {
      flush(); ctx.wide = true
      var lv = m[1].length, size = Math.round(ctx.px * (lv === 1 ? 1.35 : lv === 2 ? 1.2 : lv === 3 ? 1.08 : 1))
      out.push({ k: "x", html: '<p style="margin-top:%TOP%px; margin-bottom:0px; font-size:' + size + 'px"><span style="color:' + ctx.c.strong + '"><b>' +
                               inline(m[2] || "", ctx) + "</b></span></p>" })
      i++; continue
    }
    if (isRule(L)) {
      flush(); ctx.wide = true
      out.push({ k: "rule", html: '<p style="margin-top:%TOP%px; margin-bottom:0px"><span style="color:' + ctx.c.border + '">' +
                                  "────────────────</span></p>" })
      i++; continue
    }
    if (/^ {0,3}>/.test(L)) {
      flush(); ctx.wide = true
      var q = []
      while (i < lines.length && /^ {0,3}>/.test(lines[i])) q.push(lines[i++].replace(/^ {0,3}> ?/, ""))
      var inner = join(blocks(q, ctx), Math.round(ctx.px * 0.55))
      out.push({ k: "x", html: '<table cellspacing="0" cellpadding="0" style="margin-top:%TOP%px"><tr><td width="3" bgcolor="' + ctx.c.quote +
                               '"></td><td style="padding-left:8px"><span style="color:' + ctx.c.muted + '">' + inner +
                               "</span></td></tr></table>" })
      continue
    }
    if (isTableStart(lines, i)) { flush(); i = table(lines, i, ctx, out); continue }
    if (LIST.test(L) && !(LIST.exec(L)[4] === "" && buf.length)) { flush(); i = list(lines, i, ctx, out); continue }
    if (/^\s*<\/?details\b[^>]*>\s*$/i.test(L)) { flush(); i++; continue }
    if ((m = /^\s*<summary>(.*?)<\/summary>\s*$/i.exec(L))) {
      flush(); out.push({ k: "x", html: '<p style="margin-top:%TOP%px; margin-bottom:0px"><b>▾ ' + inline(m[1], ctx) + "</b></p>" }); i++; continue
    }
    buf.push(L); i++
  }
  flush()
  return out
}

// blocks -> one rich-text document with even spacing between blocks (each block's html has a %TOP% slot)
function join(bs, gap) {
  return bs.map(function (b, k) { return b.html.replace(/%TOP%/g, k === 0 ? "0" : String(gap)) }).join("")
}

function plainOf(html) {
  return html.replace(/<br>/g, "\n").replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
             .replace(/&quot;/g, '"').replace(/&nbsp;/g, " ").replace(/&#[0-9]+;/g, "x").replace(/&amp;/g, "&")
}

function render(text, o) {
  var segs = split((text || "").replace(/\r\n?/g, "\n")), res = [], plain = "", wide = false
  var gap = Math.round(o.px * 0.55)
  for (var s = 0; s < segs.length; s++) {
    var g = segs[s], last = s === segs.length - 1
    if (g.t === "code") {
      if (g.lang === "quiz") continue
      res.push({ kind: "code", html: "", code: g.code, lang: g.lang, open: g.open })
      wide = true
      continue
    }
    var ex = Latex.extract(g.s)
    var t = cleanProse(ex.text)
    if (o.pending && last) t = autoClose(t)
    var ctx = { c: o.c, px: o.px, math: ex.math, toks: [], wide: false, depth: 0 }
    var lines = t.replace(/^\t+/gm, function (m) { return new Array(m.length + 1).join("    ") }).split("\n")
    var bs = blocks(lines, ctx)
    if (bs.length > 1 || ctx.wide) wide = true
    // a top-level rule is drawn by the widget as a real line between rich blocks
    var run = []
    for (var b = 0; b <= bs.length; b++) {
      if (b < bs.length && bs[b].k !== "rule") { run.push(bs[b]); continue }
      if (run.length) {
        var html = join(run, gap)
        plain += plainOf(html)
        res.push({ kind: "rich", html: html, code: "", lang: "", open: false })
        run = []
      }
      if (b < bs.length) res.push({ kind: "rule", html: "", code: "", lang: "", open: false })
    }
  }
  if (plain.indexOf("\n") >= 0) wide = true
  return { blocks: res, plain: plain, wide: wide }
}

// ---------- finished turns
// The voice bridge's done.reply (and report.text) is its speech text: clean_text() + strip_tags() in
// the TV bridge replace every fenced code block with a space and unwrap `code`, [links](...), **, # and
// bullets, and done.spoken counts characters of that flattened text. Showing it would make code blocks (and the
// rest of the markdown) vanish the moment a reply finishes. finalText() keeps the markdown instead: ev.md when the
// bridge sends it (with ev.md_spoken in its coordinates), else the text that streamed in, with the spoken offset
// moved over by mapCut(). Only a turn with nothing streamed falls back to the flattened text.
function finalText(streamed, ev) {
  var flat = typeof ev.reply === "string" ? ev.reply : (ev.text || "")
  var sp = typeof ev.spoken === "number" ? ev.spoken : -1
  if (typeof ev.md === "string" && ev.md.trim() !== "")
    return { text: ev.md, spoken: typeof ev.md_spoken === "number" ? ev.md_spoken : mapCut(ev.md, flat, sp) }
  if (streamed && streamed.trim() !== "") {
    var t = withQuizzes(streamed, flat)
    return { text: t, spoken: mapCut(t, flat, sp) }
  }
  return { text: flat, spoken: sp }
}
// ```quiz blocks come through the bridge verbatim (the stream's tag filter can eat "[abc]" inside one), and their
// hash keys a submitted quiz in history: take them from flat, in order
function withQuizzes(text, flat) {
  var want = flat.match(QUIZ_HOLD) || [], k = 0
  if (!want.length) return text
  return text.replace(QUIZ_HOLD, function (m) { return k < want.length ? m.replace(m.trim(), want[k++].trim()) : m })
}

// the bridge's chat_text(): [lang:xx] out, clean_text's _MD, strip_tags, with ```quiz blocks held verbatim;
// keeps for every output char its offset in s
var SPEECH = [[/\[\s*lang(?:uage)?\s*[:=]\s*([A-Za-z]{2,12}(?:-[A-Za-z]{2,4})?)?\s*\]/gi, ""], [/```[\s\S]*?```/g, " "], [/`([^`]*)`/g, 1], [/\[([^\]]*)\]\([^)]*\)/g, 1], [/https?:\/\/\S+/g, " link "],
              [/\*\*|__|~~/g, ""], [/^\s*#+\s*/gm, ""], [/^\s*[-*]\s+/gm, ""], [/[ \t]+/g, " "], "strip",
              [/\[[A-Za-z][a-z' ,-]{1,48}\]/g, ""], [/ {2,}/g, " "], "strip"]
var QUIZ_HOLD = /^[ \t]*(`{3,}|~{3,})[ \t]*quiz\b[\s\S]*?(?:^[ \t]*\1[ \t]*$|(?![\s\S]))/gim
function speechMap(s) {
  var st = { s: "", m: [] }, held = [], last = 0, q
  QUIZ_HOLD.lastIndex = 0
  while ((q = QUIZ_HOLD.exec(s)) !== null) {
    if (q[0] === "") { QUIZ_HOLD.lastIndex++; continue }
    for (var i = last; i < q.index; i++) { st.s += s.charAt(i); st.m.push(i) }
    var ph = "\u0000Q" + held.length + "\u0000", lead = q[0].length - q[0].replace(/^\s+/, "").length
    held.push({ at: q.index + lead, s: q[0].trim() })
    for (var j = 0; j < ph.length; j++) { st.s += ph.charAt(j); st.m.push(q.index) }
    last = q.index + q[0].length
  }
  for (i = last; i < s.length; i++) { st.s += s.charAt(i); st.m.push(i) }
  for (var r = 0; r < SPEECH.length; r++) {
    var rule = SPEECH[r]
    if (rule === "strip") {
      var a = 0, b = st.s.length
      while (a < b && /\s/.test(st.s.charAt(a))) a++
      while (b > a && /\s/.test(st.s.charAt(b - 1))) b--
      st = { s: st.s.slice(a, b), m: st.m.slice(a, b) }
      continue
    }
    var re = rule[0], rep = rule[1], out = "", map = [], last = 0, x
    re.lastIndex = 0
    while ((x = re.exec(st.s)) !== null) {
      if (x[0] === "") { re.lastIndex++; continue }
      out += st.s.slice(last, x.index); map = map.concat(st.m.slice(last, x.index))
      if (rep === 1) { out += x[1]; map = map.concat(st.m.slice(x.index + 1, x.index + 1 + x[1].length)) }
      else for (var k = 0; k < rep.length; k++) { out += rep.charAt(k); map.push(st.m[x.index]) }
      last = x.index + x[0].length
    }
    st = { s: out + st.s.slice(last), m: map.concat(st.m.slice(last)) }
  }
  if (!held.length) return st
  var res = { s: "", m: [] }, re2 = /\u0000Q(\d+)\u0000/g, y, from = 0
  while ((y = re2.exec(st.s)) !== null) {
    res.s += st.s.slice(from, y.index); res.m = res.m.concat(st.m.slice(from, y.index))
    var h = held[+y[1]]
    res.s += h.s; for (var c = 0; c < h.s.length; c++) res.m.push(h.at + c)
    from = y.index + y[0].length
  }
  res.s += st.s.slice(from); res.m = res.m.concat(st.m.slice(from))
  return res
}
// offset k into the flattened text -> offset into raw (-1: no cut, all of it was spoken or it wasn't a spoken turn)
function mapCut(raw, flat, k) {
  if (k < 0) return -1
  if (k === 0) return 0
  if (k >= flat.length) return -1
  var st = speechMap(raw)
  if (k >= st.m.length) return -1
  return st.m[k]
}
