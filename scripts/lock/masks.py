#!/usr/bin/env python3
"""Make the lock screen's depth masks for still wallpapers, locally (no uploads).

  masks.py [--model birefnet-general] [--force] [--width 3840] [--holes] [STEM ...]

For each still wallpaper (wallpapers/<stem>.png|jpg|..., all of them when no
STEM is given) this writes meta/<stem>/fg-mask.png: an 8-bit greyscale mask,
same aspect as the image, white = the subject. meta/<stem>.toml's [depth]
foreground = "fg-mask.png" points at it, and
text with depth = "behind" is drawn under the subject (see README.md).

Segmentation is BiRefNet through rembg (open source, CPU, runs offline once the
model is cached in ~/.rembg). The model only ever sees 1024x1024, so its mask is
coarse; it is upsampled to the image (up to --width px) with a colour guided
filter, which moves the edges onto the image's own, and a thin band along the
edge is then alpha-matted (KNN matting, PyMatting) against the image, so the
mask is crisp and 0/1 everywhere else (no haze, no feather).
(Tiling the image for a higher-res pass was tried: the tiles lose the context and
drop or invent subjects.) lockgen.py then sharpens the edge per monitor
([depth] edge_softness).

--holes (or `holes = true` under [depth] in meta/<stem>.toml): BiRefNet
fills see-through gaps (lattices, missing panels, gaps between struts) with the
subject. This pass runs GrabCut (colour models + graph cut, OpenCV) seeded with
the mask and only ever removes: whatever inside the mask matches the sky/ground
around it becomes background.

rembg is not a dependency of the lock itself, and only subject masks need it
(--sky and --invert run on Pillow + numpy). This script re-runs itself with
the venv in ~/.local/share/lockmask when the current Python lacks it. Set that
venv up once with:

  uv venv --python 3.12 ~/.local/share/lockmask/.venv
  uv pip install --python ~/.local/share/lockmask/.venv/bin/python "rembg[cpu]" opencv-python-headless

Background masks (meta/<stem>/bg-mask.png, white = the far plane, the sky) suit
silhouettes against a bright sky, where a subject model finds nothing:
`--sky STEM` marks, per column, everything above the first dark run (skyline,
treeline, a tree) as sky. `--dark 0.22` sets the luminance cut (0-1). `--invert
STEM` instead writes the inverse of STEM's subject mask.

Ported from gagehauptman/dotfiles (bc567de, 73b8c23) to flat wallpaper files.
"""
import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WALLPAPERS = HERE.parent.parent / "wallpapers"
META = HERE / "meta"
VENV_PY = Path.home() / ".local/share/lockmask/.venv/bin/python"
STILLS = {".png", ".jpg", ".jpeg", ".webp"}

NEEDS_MODEL = not {"--sky", "--invert", "-h", "--help"} & set(sys.argv[1:])
try:
    from PIL import Image, ImageFilter, ImageOps
    if NEEDS_MODEL:
        import rembg  # noqa: F401
except ImportError:
    if VENV_PY.is_file() and Path(sys.executable).resolve() != VENV_PY.resolve():
        os.execv(str(VENV_PY), [str(VENV_PY), __file__, *sys.argv[1:]])
    sys.exit(f"masks.py: needs rembg + Pillow (see the docstring for the venv at {VENV_PY.parent.parent})")

Image.MAX_IMAGE_PIXELS = None


def image_of(stem):
    """wallpapers/<stem>.<ext> (flat), or wallpapers/<stem>/<stem>.<ext>."""
    for folder in (WALLPAPERS, WALLPAPERS / stem):
        if folder.is_dir():
            for p in sorted(folder.iterdir()):
                if p.suffix.lower() in STILLS and p.stem == stem and p.is_file():
                    return p
    return None


def box(x, r):
    import cv2
    return cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1), borderType=cv2.BORDER_REFLECT)


def guided_filter(img, p, r, eps):
    """Colour guided filter (He et al.): p smoothed where img is flat, its edges
    moved onto img's edges. img HxWx3 and p HxW, float32 0-1."""
    import numpy as np
    mean_i = box(img, r)
    mean_p = box(p, r)
    cov_ip = box(img * p[..., None], r) - mean_i * mean_p[..., None]
    var = box(np.einsum("hwi,hwj->hwij", img, img).reshape(*p.shape, 9), r).reshape(*p.shape, 3, 3)
    var -= np.einsum("hwi,hwj->hwij", mean_i, mean_i)
    var += eps * np.eye(3, dtype=np.float32)
    a = np.linalg.solve(var, cov_ip[..., None])[..., 0]
    b = mean_p - (a * mean_i).sum(-1)
    return (box(a, r) * img).sum(-1) + box(b, r)


def hole_mask(img, fg):
    """Pixels of the binary subject mask `fg` that GrabCut, seeded with it, puts
    in the background: the gaps the model filled in. img HxWx3 uint8 RGB."""
    import cv2
    import numpy as np
    from scipy import ndimage as ndi
    h, w = fg.shape
    near = ndi.distance_transform_edt(~fg) < w * 0.02
    lab = np.full((h, w), cv2.GC_BGD, np.uint8)
    lab[near] = cv2.GC_PR_BGD
    lab[fg] = cv2.GC_PR_FGD
    ys, xs = np.nonzero(ndi.binary_dilation(near, iterations=round(w * 0.01)))
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crop = lab[y0:y1, x0:x1].copy()
    cv2.grabCut(np.ascontiguousarray(img[y0:y1, x0:x1, ::-1]), crop, None,
                np.zeros((1, 65)), np.zeros((1, 65)), 5, cv2.GC_INIT_WITH_MASK)
    keep = np.zeros((h, w), bool)
    keep[y0:y1, x0:x1] = (crop == cv2.GC_FGD) | (crop == cv2.GC_PR_FGD)
    holes = fg & ~keep                     # only ever remove
    # drop specks (texture GrabCut flips here and there)
    lbl, n = ndi.label(holes)
    if n:
        sizes = ndi.sum(holes, lbl, range(1, n + 1))
        holes = np.isin(lbl, 1 + np.nonzero(sizes >= (w / 1000) ** 2 * 6)[0])
    return holes


def depth_conf(stem):
    """[depth] of meta/<stem>.toml ({} if none)."""
    import tomllib
    try:
        with open(META / f"{stem}.toml", "rb") as fh:
            return tomllib.load(fh).get("depth", {})
    except (OSError, ValueError):
        return {}


def subject_mask(session, src, width, holes=False):
    import numpy as np
    from scipy import ndimage as ndi
    im = Image.open(src).convert("RGB")
    w = min(width, im.width)
    h = round(im.height * w / im.width)
    img = np.asarray(im.resize((w, h), Image.LANCZOS))
    # The model sees 1024x1024 whatever it is given (rembg resizes; a 2560 px
    # input, as the first masks had: BiRefNet's picks change with the resampling).
    # Upsample its answer smoothly, then the guided filter puts the edges on the image's.
    sw = min(2560, im.width)
    small = im.resize((sw, round(im.height * sw / im.width)), Image.LANCZOS)
    pred = session.predict(small)[0].convert("L")
    p = np.asarray(pred.resize((w, h), Image.BICUBIC), dtype=np.float32) / 255
    rgb = img.astype(np.float32) / 255
    fg = guided_filter(rgb, p, max(2, round(w / 1024 * 1.5)), 1e-4) > 0.5
    unknown = np.zeros_like(fg)
    if holes:
        hole = hole_mask(img, fg)
        print(f"  holes: {hole.mean() * 100:.2f}% of the image", flush=True)
        unknown |= ndi.binary_dilation(hole, iterations=2)
    # Matte the edge (a thin band either side) and the holes: KNN matting picks
    # each pixel's alpha from the colours of the sure subject/sure background
    # around it, non-locally, so a strut or wire across a hole stays and the sky
    # between them goes. Everything else is 0 or 1: no haze, no feather.
    band = max(2, round(3 * w / 3840))
    unknown |= ndi.binary_dilation(fg, iterations=band) & ~ndi.binary_erosion(fg, iterations=band)
    # what the model is unsure of (thin wires come out at 0.2-0.6), same treatment
    unknown |= ndi.binary_dilation((p > 0.1) & (p < 0.95), iterations=band)
    alpha = fg.astype(np.float32)
    ys, xs = np.nonzero(unknown)
    if len(ys):
        from pymatting import estimate_alpha_knn
        pad = 8 * band
        y0, y1 = max(0, ys.min() - pad), min(h, ys.max() + pad + 1)
        x0, x1 = max(0, xs.min() - pad), min(w, xs.max() + pad + 1)
        tri = fg[y0:y1, x0:x1].astype(np.float64)
        tri[unknown[y0:y1, x0:x1]] = 0.5
        a = estimate_alpha_knn(rgb[y0:y1, x0:x1].astype(np.float64), tri)
        alpha[y0:y1, x0:x1] = np.clip(a, 0, 1)
        # matting leaves the odd speck on soft, glowy edges: drop tiny islands
        # of subject in the background and of background in the subject
        speck = max(4, round(8 * (w / 3840) ** 2))
        for inside, fill in ((alpha > 0.5, 0.0), (alpha <= 0.5, 1.0)):
            lbl, n = ndi.label(inside)
            if n:
                sizes = ndi.sum(inside, lbl, range(1, n + 1))
                small = 1 + np.nonzero(sizes < speck)[0]
                alpha[np.isin(lbl, small) & unknown] = fill
    # lockgen.py redraws the edge ~1 px wide per monitor ([depth] edge_softness)
    return Image.fromarray((alpha * 255 + 0.5).astype(np.uint8))


def sky_mask(src, width, dark):
    """White above the first dark run of each column (a silhouette's top edge)."""
    import numpy as np
    im = Image.open(src).convert("L")
    w = min(width, im.width)
    h = round(im.height * w / im.width)
    work = im.resize((w // 2, h // 2), Image.LANCZOS).filter(ImageFilter.GaussianBlur(1.5))
    lum = np.asarray(work, dtype=np.float32) / 255
    land = lum < dark
    # a run of 6 dark rows (at half size) is land; stray dark specks are not
    run = land.copy()
    for k in range(1, 6):
        run[:-k] &= land[k:]
        run[-k:] = False
    first = np.where(run.any(axis=0), run.argmax(axis=0), land.shape[0])
    rows = np.arange(land.shape[0])[:, None]
    m = Image.fromarray(((rows < first[None, :]) * 255).astype(np.uint8))
    return m.resize((w, h), Image.BILINEAR).filter(ImageFilter.GaussianBlur(1.2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stems", nargs="*")
    ap.add_argument("--model", default="birefnet-general")
    ap.add_argument("--width", type=int, default=3840, help="max mask width (px), height follows the image")
    ap.add_argument("--holes", action="store_true", help="also clear see-through gaps (GrabCut pass)")
    ap.add_argument("--force", action="store_true", help="remake masks that exist")
    ap.add_argument("--invert", action="store_true", help="write meta/STEM/bg-mask.png = inverse of fg-mask.png")
    ap.add_argument("--sky", action="store_true", help="write meta/STEM/bg-mask.png from the skyline (no model)")
    ap.add_argument("--dark", type=float, default=0.22, help="--sky: luminance below this is land (0-1)")
    a = ap.parse_args()

    stems = a.stems or sorted(p.stem for p in WALLPAPERS.iterdir()
                              if p.is_file() and p.suffix.lower() in STILLS)
    if a.invert:
        for stem in stems:
            fg = META / stem / "fg-mask.png"
            if fg.is_file():
                ImageOps.invert(Image.open(fg).convert("L")).save(META / stem / "bg-mask.png", optimize=True)
                print(f"{stem}: meta/{stem}/bg-mask.png")
        return

    if a.sky:
        for stem in stems:
            src = image_of(stem)
            if src:
                (META / stem).mkdir(parents=True, exist_ok=True)
                sky_mask(src, a.width, a.dark).save(META / stem / "bg-mask.png", optimize=True)
                print(f"{stem}: meta/{stem}/bg-mask.png")
        return

    from rembg import new_session
    session = new_session(a.model)
    for stem in stems:
        src = image_of(stem)
        out = META / stem / "fg-mask.png"
        if not src:
            print(f"{stem}: no still, skipped")
            continue
        if out.is_file() and not a.force:
            print(f"{stem}: exists")
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        holes = a.holes or bool(depth_conf(stem).get("holes"))
        subject_mask(session, src, a.width, holes).save(out, optimize=True)
        print(f"{stem}: meta/{stem}/fg-mask.png ({out.stat().st_size // 1024} KiB)", flush=True)


if __name__ == "__main__":
    main()
