#!/usr/bin/env python3
"""Typeset one LaTeX equation for the Q panel (QChatWidget.qml) as a transparent PNG.

    q_eq.py OUT.png COLOR DISPLAY(0|1) DPI [LATEX]      (LATEX from stdin when not given)

Renders with latex + dvipng (both machines have TeX Live), falling back to matplotlib's mathtext. The panel names
OUT.png by a hash of everything that shapes the picture, so an existing file is a cache hit and isn't redrawn.
Prints "W H" (pixels) on success, nothing on failure.
"""
import os
import struct
import subprocess
import sys
import tempfile


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def via_latex(tex, out, color, display, dpi):
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    # no preview.sty or standalone.cls on these machines: a plain page, cropped to the ink by dvipng -T tight
    doc = (r"\documentclass[12pt]{article}\usepackage{amsmath,amssymb}\pagestyle{empty}\begin{document}\noindent"
           + ("$" + (r"\displaystyle " if display else "") + tex + "$") + r"\end{document}")
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "eq.tex"), "w") as f:
            f.write(doc)
        p = subprocess.run(["latex", "-interaction=nonstopmode", "-halt-on-error", "eq.tex"], cwd=d,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        if p.returncode != 0:
            return None
        tmp = out + ".tmp.png"
        p = subprocess.run(["dvipng", "-q", "-D", str(dpi), "-T", "tight", "-bg", "Transparent",
                            "-fg", f"rgb {r:.3f} {g:.3f} {b:.3f}", "-o", tmp, "eq.dvi"], cwd=d,
                           capture_output=True, text=True, timeout=20)
        if p.returncode != 0 or not os.path.exists(tmp):
            return None
        os.replace(tmp, out)
        return True


def via_mathtext(tex, out, color, display, dpi):
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import mathtext
    from matplotlib.font_manager import FontProperties
    matplotlib.rcParams["mathtext.fontset"] = "cm"
    tmp = out + ".tmp.png"
    mathtext.math_to_image("$" + tex + "$", tmp, prop=FontProperties(size=14 if display else 12),
                           dpi=dpi, format="png", color=color)
    os.replace(tmp, out)
    return True


def main():
    out, color, display, dpi = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4])
    tex = (sys.argv[5] if len(sys.argv) > 5 else sys.stdin.read()).strip()
    if not tex:
        return
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        ok = None
        try:
            ok = via_latex(tex, out, color, display, dpi)
        except Exception:
            pass
        if not ok:
            try:
                via_mathtext(tex, out, color, display, dpi)
            except Exception:
                return
    w, h = png_size(out)
    print(w, h)


if __name__ == "__main__":
    main()
