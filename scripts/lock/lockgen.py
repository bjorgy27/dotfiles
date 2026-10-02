#!/usr/bin/env python3
"""Resolve the lock screen's settings for the current wallpaper, as JSON for
the Quickshell lock (qs/shell.qml).

Placement and text style come from meta/<stem>.toml (see README.md), layered
over meta/default.toml, so every wallpaper can be tuned on its own. The
background is per monitor: the wallpaper (or a live wallpaper's still) cover-
cropped to the monitor, or a flat colour.

Ported from gagehauptman/dotfiles (e6f2eee, bc567de, 73b8c23). Upstream keeps
each wallpaper in its own folder (wallpapers/<stem>/lock.toml + lock/*.png) and
draws live wallpapers with its Bevy renderer; here wallpapers are flat files,
so a wallpaper's lock settings live in meta/<stem>.toml and its depth masks in
meta/<stem>/. A wallpapers/<stem>/lock.toml is still honoured if one appears.

  lockgen.py [--wallpaper PATH] [--out FILE] [--monitors NAME:WxH,...] [--check]

--wallpaper  use this instead of the saved selection (wpsave.txt)
--out        write the JSON here instead of stdout
--monitors   pretend these monitors are connected (e.g. no compositor running)
--check      also print a one-line summary per monitor to stderr
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent            # dotfiles/scripts/lock
HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
STATE = RUNTIME / "lockscreen"
META = HERE / "meta"
WALLPAPERS = CONFIG / "wallpapers"
SAVE_FILE = CONFIG / "scripts/wallpaper/wpsave.txt"
# wallpaper_select.sh --warm keeps screen-sized copies of every still here.
SCALED = RUNTIME / "wallpaper_select/scaled"

ELEMENTS = ("clock", "date", "greeting", "input")
TEXT_ELEMENTS = ("clock", "date", "greeting")
COLOR_KEYS = {"color", "font_color", "outer_color", "inner_color", "check_color", "fail_color",
              "capslock_color", "shadow_color", "accent_color", "success_color", "caps_color"}
STILL_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".jxl"}


def log(*a):
    print("lockgen:", *a, file=sys.stderr)


def merge(base, over):
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_toml(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as e:
        log(f"{path}: {e}; ignoring it")
        return {}


# ---------------------------------------------------------------- inputs

def current_wallpaper():
    try:
        p = SAVE_FILE.read_text().strip()
    except OSError:
        p = ""
    return Path(p) if p else None


def monitors(spec=None):
    """[(name, width, height)] in physical pixels, as the monitor is oriented."""
    if spec:
        out = []
        for item in spec.split(","):
            name, size = item.split(":")
            w, h = size.lower().split("x")
            out.append((name, int(w), int(h)))
        return out
    try:
        mons = json.loads(subprocess.run(["hyprctl", "-j", "monitors"], capture_output=True,
                                         text=True, timeout=3).stdout)
        out = []
        for m in mons:
            if m.get("disabled"):
                continue
            w, h = m["width"], m["height"]
            if m.get("transform", 0) % 2:
                w, h = h, w
            out.append((m["name"], w, h))
        if out:
            return out
    except Exception as e:
        log(f"hyprctl monitors failed ({e}); one generic output")
    return [("", 1920, 1080)]


def lock_dir(stem):
    """Where a wallpaper's lock files (masks, poster) live: its own folder in
    upstream's layout, else meta/<stem>/ (flat wallpapers)."""
    folder = WALLPAPERS / stem
    return folder if (folder / "lock.toml").is_file() else META / stem


def meta_for(stem, monitor):
    """Resolved settings for one monitor: default < layouts/<base> < <stem>,
    then each of those files' [monitor."<name>"] overrides in the same order."""
    own = {}
    if stem:
        folder = WALLPAPERS / stem / "lock.toml"      # a wallpaper folder wins
        own = load_toml(folder if folder.is_file() else META / f"{stem}.toml")
    layers = [load_toml(META / "default.toml")]
    if own.get("base"):
        layers.append(load_toml(META / "layouts" / f"{own['base']}.toml"))
    layers.append(own)
    m = {}
    for layer in layers:
        m = merge(m, layer)
    for layer in layers:
        m = merge(m, layer.get("monitor", {}).get(monitor, {}))
    m.pop("monitor", None)
    m.pop("base", None)
    return m


# ---------------------------------------------------------------- backgrounds

def scaled_cache_path(src, w, h):
    """The copy wallpaper_select.sh --warm makes (same key as its scaled_path)."""
    real = os.path.realpath(src)
    st = os.stat(real)
    key = hashlib.md5(f"{real}|{st.st_size}-{int(st.st_mtime)}".encode()).hexdigest()
    return SCALED / f"{w}x{h}" / f"{key}.png"


def still_background(src, w, h):
    """A WxH cover-cropped copy of a still (cached), else the original."""
    try:
        cached = scaled_cache_path(src, w, h)
    except OSError:
        return None
    if cached.is_file() and cached.stat().st_size:
        return cached
    own = STATE / "bg" / f"{w}x{h}" / cached.name
    if own.is_file() and own.stat().st_size:
        return own
    own.parent.mkdir(parents=True, exist_ok=True)
    tmp = own.with_suffix(f".tmp{os.getpid()}.png")
    try:
        subprocess.run(["vips", "thumbnail", str(src),
                        f"{tmp}[compression=1,strip]", str(w), "--height", str(h),
                        "--crop", "centre", "--size", "both"],
                       check=True, capture_output=True, timeout=15)
        tmp.replace(own)
        return own
    except Exception as e:
        log(f"scaling {src} failed ({e})")
        tmp.unlink(missing_ok=True)
    return src if src.suffix.lower() in STILL_EXTS else None


def background(wall, mon, meta):
    """{"kind": "still"|"color", ...} for one monitor. "own": the still is
    the wallpaper itself (so its depth masks fit it)."""
    _, w, h = mon
    bgm = meta.get("background", {})
    out = {"kind": "color"}
    poster = bgm.get("image")
    if poster:
        p = Path(os.path.expanduser(poster))
        p = p if p.is_absolute() else lock_dir(wall.stem if wall else "") / p
        if p.is_file():
            img = still_background(p, w, h)
            if img:
                return {"kind": "still", "image": str(img)}
        else:
            log(f"background.image {p} not found")
    if not wall:
        return out
    if wall.suffix == ".live":
        # No Bevy renderer here: a still of the scene next to its descriptor
        # (wallpapers/<stem>.png, as hyprlock's wallpaper.sh uses), else the colour.
        for ext in STILL_EXTS:
            p = wall.with_suffix(ext)
            if p.is_file():
                img = still_background(p, w, h)
                if img:
                    return {"kind": "still", "image": str(img)}
        return out
    if wall.is_file():
        img = still_background(wall, w, h)
        if img:
            return {"kind": "still", "image": str(img), "own": True}
    else:
        log(f"{wall} not found")
    return out


# ---------------------------------------------------------------- depth

# The shade LockSurface.qml draws over the background (top/bottom falloff, as
# (colour, alpha at the edge, fraction of the height)); baked into the cut-outs.
SHADE_RGB = (0x11, 0x11, 0x1b)
SHADE_TOP = (0.9 * 0x59 / 255, 0.40)
SHADE_BOTTOM = (0.9 * 0x66 / 255, 0.45)


def crisp_edge(m, soft):
    """Re-draw a soft 8-bit mask's edge `soft` px wide (at screen resolution).
    (a - 0.5) / |grad a| is roughly the signed distance (px) to the mask's 50%
    contour, so this keeps the outline where it is and only tightens the ramp
    across it: a resampled/feathered edge several px wide becomes a ~1 px
    antialiased one. Flat areas (0/1) stay as they are."""
    import numpy as np
    from PIL import Image, ImageFilter
    # a touch of blur first, so the gradient is not pixel noise (jaggies, specks)
    a = np.asarray(Image.fromarray(m).filter(ImageFilter.GaussianBlur(0.6)), dtype=np.float32) / 255
    gy, gx = np.gradient(a)
    d = (a - 0.5) / np.maximum(np.hypot(gx, gy), 1e-3)
    out = np.clip(0.5 + d / soft, 0, 1)
    return (out * 255 + 0.5).astype(np.uint8)


def depth_layers(wall, bg, meta, w, h):
    """[depth] foreground/background masks -> per-monitor RGBA cut-outs of the
    background (same cover crop, brightness and shade baked in) and the
    subject's box (fractions of the screen). {} when there is nothing to do."""
    dm = meta.get("depth", {})
    if not dm or bg.get("kind") != "still" or not bg.get("own") or not wall:
        return {}
    folder = lock_dir(wall.stem)
    masks = {}
    for key in ("foreground", "background"):
        if dm.get(key):
            p = Path(os.path.expanduser(dm[key]))
            p = p if p.is_absolute() else folder / p
            if p.is_file():
                masks[key] = p
            else:
                log(f"depth.{key} {p} not found")
    if not masks:
        return {}
    try:
        import numpy as np
        from PIL import Image, ImageOps
    except ImportError:
        log("depth masks need python-pillow and python-numpy; drawing without depth")
        return {}
    Image.MAX_IMAGE_PIXELS = None
    bright = max(0.0, min(1.0, float(meta.get("background", {}).get("brightness", 1.0))))
    soft = max(0.0, float(dm.get("edge_softness", 1.0)))
    src = Path(bg["image"])
    stamp = "|".join(f"{p}:{p.stat().st_mtime_ns}" for p in [src, *masks.values()])
    key = hashlib.md5(f"{stamp}|{w}x{h}|{bright}|{soft}|v2".encode()).hexdigest()[:16]
    outdir = STATE / "depth"
    outdir.mkdir(parents=True, exist_ok=True)
    out = {}
    names = {"foreground": "foreground", "background": "midground"}
    todo = {k: outdir / f"{key}-{names[k]}.png" for k in masks}
    fits = {}

    def fit(p):
        if p not in fits:
            m = np.asarray(ImageOps.fit(Image.open(p).convert("L"), (w, h), Image.LANCZOS))
            fits[p] = crisp_edge(m, soft) if soft > 0 else m
        return fits[p]

    if not all(p.is_file() for p in todo.values()):
        rgb = np.asarray(ImageOps.fit(Image.open(src).convert("RGB"), (w, h), Image.LANCZOS), dtype=np.float32)
        rgb = rgb * bright
        y = (np.arange(h, dtype=np.float32) + 0.5) / h
        top_a, top_f = SHADE_TOP
        bot_a, bot_f = SHADE_BOTTOM
        a = np.clip(top_a * (1 - y / top_f), 0, None) + np.clip(bot_a * (y - (1 - bot_f)) / bot_f, 0, None)
        a = a[:, None, None]
        rgb = rgb * (1 - a) + np.array(SHADE_RGB, dtype=np.float32) * a
        rgb = np.clip(rgb + 0.5, 0, 255).astype(np.uint8)
        for k, dst in todo.items():
            alpha = fit(masks[k])
            if k == "background":          # the far plane is white: cut out the rest
                alpha = 255 - alpha
            tmp = dst.with_suffix(f".tmp{os.getpid()}.png")
            Image.fromarray(np.dstack([rgb, alpha])).save(tmp, compress_level=1)
            tmp.replace(dst)
    for k, dst in todo.items():
        out[names[k]] = str(dst)
    if "foreground" in masks:
        ys, xs = np.nonzero(fit(masks["foreground"]) > 127)
        if len(xs):
            out["subject"] = [float(round(v, 4)) for v in (xs.min() / w, ys.min() / h,
                              (xs.max() + 1 - xs.min()) / w, (ys.max() + 1 - ys.min()) / h)]
    return out


# ---------------------------------------------------------------- output

def qcolor(c):
    """rgb(1b1923) / rgba(1b192380) / 0xAARRGGBB / #rrggbb -> Qt's #AARRGGBB."""
    s = str(c).strip()
    if s.startswith("rgba(") and s.endswith(")") and "," not in s:
        hx = s[5:-1]
        return f"#{hx[6:8] or 'ff'}{hx[:6]}" if len(hx) >= 6 else s
    if s.startswith("rgb(") and s.endswith(")") and "," not in s:
        return f"#ff{s[4:-1]}"
    if s.startswith("0x") and len(s) == 10:      # hyprlang 0xAARRGGBB
        return "#" + s[2:]
    return s


def parse_pos(v):
    """"x%, y%" or [x, y] -> [[value, is_percent], ...] (+y up)."""
    if isinstance(v, list):
        v = ", ".join(map(str, v))
    out = []
    for p in str(v).split(",")[:2]:
        p = p.strip()
        out.append([float(p[:-1] or 0), True] if p.endswith("%") else [float(p or 0), False])
    while len(out) < 2:
        out.append([0.0, False])
    return out


def element(meta, key):
    """[text] is the shared style; labels and the input field inherit from it
    (`accent` becomes the field's accent_color). Each element's own table wins:
    font_family, font_weight, font_size, letter_spacing, uppercase, color, opacity,
    shadow_size/shadow_color/shadow_strength."""
    text = meta.get("text", {})
    opts = {}
    if key in TEXT_ELEMENTS:
        opts.update({k: v for k, v in text.items() if k != "accent"})
    elif key == "input":
        for src, dst in (("color", "font_color"), ("font_family", "font_family"),
                         ("font_weight", "font_weight"), ("font_style", "font_style"),
                         ("accent", "accent_color")):
            if src in text:
                opts[dst] = text[src]
        for k in ("shadow_passes", "shadow_size", "shadow_color"):
            if k in text:
                opts[k] = text[k]
    opts.update(meta.get(key, {}))
    for k in COLOR_KEYS & opts.keys():
        opts[k] = qcolor(opts[k])
    for k in ("position", "offset"):
        if k in opts:
            opts[k] = parse_pos(opts[k])
    return opts


def build(wall, mons):
    stem = wall.stem if wall else ""
    metas = {name: meta_for(stem, name) for name, _, _ in mons}

    def one(mon):
        name, w, h = mon
        meta = metas[name]
        bg = background(wall, mon, meta)
        bgm = meta.get("background", {})
        bg["color"] = qcolor(bgm.get("color", "rgb(1b1923)"))
        # brightness/blur dim and soften stills
        bg["brightness"] = float(bgm.get("brightness", 1.0))
        bg["blur"] = int(bgm.get("blur_passes", 0)) * int(bgm.get("blur_size", 6)) if bg["kind"] == "still" else 0
        depth = depth_layers(wall, bg, meta, w, h)
        if depth:
            # baked into the cut-outs; the background gets the same in QML
            bg["brightness"] = float(bgm.get("brightness", 1.0))
        bg.pop("own", None)
        out = {"name": name, "width": w, "height": h, "background": bg, "depth": depth,
               "elements": {k: element(meta, k) for k in ELEMENTS}}
        if meta.get("text", {}).get("ui_scale"):
            out["ui_scale"] = float(meta["text"]["ui_scale"])
        return out

    with ThreadPoolExecutor(max_workers=len(mons)) as ex:
        screens = list(ex.map(one, mons))
    return {"wallpaper": str(wall) if wall else "", "stem": stem, "screens": screens}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wallpaper")
    ap.add_argument("--out")
    ap.add_argument("--monitors")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    wall = Path(a.wallpaper).expanduser() if a.wallpaper else current_wallpaper()
    cfg = build(wall, monitors(a.monitors))
    text = json.dumps(cfg, indent=1)
    if a.out:
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(f".tmp{os.getpid()}")
        tmp.write_text(text + "\n")
        tmp.replace(out)
    else:
        print(text)
    if a.check:
        for s in cfg["screens"]:
            b = s["background"]
            d = s.get("depth") or {}
            log(f"{s['name'] or 'all'} {s['width']}x{s['height']}: {b['kind']} "
                f"{b.get('image') or b['color']}"
                + (f" depth={'+'.join(k for k in ('midground', 'foreground') if k in d)} subject={d.get('subject')}" if d else ""))


if __name__ == "__main__":
    main()
