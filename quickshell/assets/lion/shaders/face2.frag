#version 440
// Q's lion: the default pose, alive (LionAvatar.qml). Nothing here paints a feature: every output pixel is traced back
// to a pixel of Beck's drawing, through small warps of the drawing's own lids, brows, mouth corner and jaw.
//  - the brows: each white brow tuft lifts on a smooth bump (and arches, its outer end higher);
//  - the eyes: each eye's lid lines, measured off the drawing (assets/lion/jaw/default-lids.png), slide across it.
//    The upper liner moves rigidly and the fur above it stretches; the eyeball under it stays put, so a lid coming
//    down covers it and one going up shows a little more of it (a blink is the drawing's own liner closing onto its
//    own lower lid). The iris can glance along the eye while the corners and lids stay put;
//  - the smirk: the far mouth corner drawn up a little;
//  - the ears: each turns a few degrees about a point at its base, the more the further up the ear, and its tip can
//    flick on its own. A turn keeps every pixel's distance from the pivot, so the fur and the stars round the ear only
//    slide along arcs, fading out a little way off: nothing opens, nothing folds, and nothing leaves the disc;
//  - the jaw, while talking: every pixel pulled back through the lower-face and upper-face displacement fields in
//    assets/lion/jaw/ (built from the drawing's own mouth line); the mouth line's signed distance says which face a
//    source pixel belongs to, so the lips part along it while both corners stay joined. Where neither face lands, the
//    lips have parted: the dark inside of the mouth, with the tongue (from Beck's front_talk drawing) lying behind
//    the teeth (his own, from front_talk and laugh): the upper row hangs from the upper lip, the lower row and the
//    tongue ride the jaw. Shut, there is no inside, so no tongue and no teeth.
// Rebuild: qsb --qt6 -o face.frag.qsb face.frag. Qt Quick keeps a shader it has loaded for the life of the process,
// by file name, so a hot reload won't see a rebuilt .qsb: a changed shader gets a new name (this was face.frag, and
// before that mouth.frag).
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float jaw;        // opening (1 = full)
    float shape;      // -1 wide .. +1 round
    float aa;         // antialiasing half-width, 512-frame px
    vec4 pullRound;   // xy: corner pull for a round mouth (px), zw: its extra chin drop (px)
    vec4 frame;       // xy: where the 512 frame starts in the image, zw: the image size (both in 512-frame px)
    vec4 cavTop;      // inside the mouth, under the upper lip
    vec4 cavDeep;     // ... and deeper in
    vec4 teethRect;   // where the teeth and tongue maps lie in the 512 frame: xy corner, zw size
    vec2 drop;        // the jaw's drop direction (unit): the teeth point along it
    vec4 tongue;      // x: the tongue's top above the lower lip (px), y: the part of the map (px from the mouth line,
                      // up -) that shows just over the lower lip, z: foreshortening (1 none, lower more)
    vec4 eyeL;        // the near eye: xy its centre, zw its axis (cos, sin), corner to corner
    vec4 eyeR;        // the far eye
    vec4 eyeSpan;     // xy: the near eye's corners along its axis (px from the centre), zw: the far eye's
    vec4 lookWinL;    // where along the near eye (0..1, corner to corner) the glance moves its content: in from x
                      // to y, out from z to w; past them (the white's far ends, the tear duct) it stays
    vec4 lookWinR;    // the far eye's
    vec2 lidsDec;     // the lid table's values: v = x + texel * y (px across the eye from its centre, down +)
    vec4 lidL;        // the near eye: x the upper lid's travel down (x the eye's height; < 0: up), y the lower lid's
                      // travel up, z: glance along the eye (px), w: glance down (px)
    vec4 lidR;        // the far eye
    vec4 browL;       // the near brow's bump: xy centre, zw its long axis (cos, sin)
    vec4 browR;       // the far brow's
    vec4 browSize;    // the bumps' radii (px): xy the near brow's along / across, zw the far brow's
    vec4 brows;       // x, y: the near and far brow's lift (px), z, w: their arch (extra lift at the outer end, px)
    vec4 smirk;       // xy: the far mouth corner, z: the bump's radius (px), w: its lift (px)
    vec2 smirkDir;    // the corner's way up (unit)
    vec4 earL;        // the near ear: xy its pivot (the middle of its base), zw its axis (unit, base to tip)
    vec4 earR;        // the far ear
    vec4 earSize;     // xy: the near ear's length and half-width at the base (px), zw: the far ear's
    vec4 ears;        // x, y: the near and far ear's turn (rad, + clockwise on screen), z, w: their tips' flicks (rad)
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D mapLow;
layout(binding = 3) uniform sampler2D mapUp;
layout(binding = 4) uniform sampler2D mapShape;
layout(binding = 5) uniform sampler2D mapMask;
layout(binding = 6) uniform sampler2D teethUp;
layout(binding = 7) uniform sampler2D teethLow;
layout(binding = 8) uniform sampler2D tongueMap;
layout(binding = 9) uniform sampler2D lids;

vec2 dec2(vec2 c, float r) { return (c * 255.0 - 128.0) / 127.0 * r; }
float dec(float c, float r) { return (c * 255.0 - 128.0) / 127.0 * r; }

// ---- the brows: a lift along the eye's "up" on a bump round each tuft, full over the tuft, gone at the radii
vec2 browD(vec2 q, vec4 b, vec2 r, float lift, float arch, vec2 up) {
    vec2 d = q - b.xy;
    float al = dot(d, b.zw), ac = dot(d, vec2(-b.w, b.z));
    float w = 1.0 - smoothstep(0.5, 1.0, length(vec2(al / r.x, ac / r.y)));
    return up * (w * (lift + arch * clamp(al / (0.6 * r.x), -1.0, 1.0)));
}
vec2 browsBack(vec2 p) {          // where the drawing's pixel for p is, the brows moved: fixed-point steps
    vec2 upL = vec2(eyeL.w, -eyeL.z), upR = vec2(eyeR.w, -eyeR.z);
    vec2 q = p;
    for (int i = 0; i < 4; i++)
        q = p - browD(q, browL, browSize.xy, brows.x, brows.z, upL) - browD(q, browR, browSize.zw, brows.y, brows.w, upR);
    return q;
}

// ---- the eyes
const float LIDS_N = 128.0;       // the lid table's steps, corner to corner
const float LINER_MAX = 12.0;     // its liner thickness range, px
const float ABOVE = 7.0;          // how far above the liner the fur stretches with the lid
const float LOWER = 1.5;          // the lower lid's line: it moves rigidly with the lower lid's edge
const float BELOW = 7.0;          // and the fur under it stretches

vec3 lidsAt(float s, float row) { // at s (0..1, corner to corner) of one eye: the upper lid's edge (a smooth line at
                                  // or above the liner's lower edge), the lower lid's, the liner's thickness above
    vec3 c = textureLod(lids, vec2((s * (LIDS_N - 1.0) + 0.5) / LIDS_N, row), 0.0).rgb;
    return vec3(lidsDec.x + c.rg * lidsDec.y, c.b * LINER_MAX);
}
vec2 eyeBack(vec2 p, vec4 e, vec2 span, vec4 mv, vec4 win, float row) {
    vec2 ax = e.zw, dn = vec2(-e.w, e.z);
    float u = dot(p - e.xy, ax), v = dot(p - e.xy, dn);
    float s = (u - span.x) / (span.y - span.x);
    if (s <= 0.0 || s >= 1.0) return p;
    vec3 l = lidsAt(s, row);
    float top = l.x, bot = l.y, T = l.z, E = max(bot - top, 0.0);
    float A = top - T - ABOVE, C = bot + BELOW;
    if (v <= A || v >= C) return p;
    float L = top + mv.x * E;     // the upper lid's edge, now
    float B = bot - mv.y * E;     // the lower lid's
    float vs = v, us = u;
    if (v < L - T) vs = A + (v - A) * ABOVE / max(L - T - A, 0.01);                          // the fur above
    else if (v < L) vs = v - (L - top);                                                        // the liner
    else if (v >= B + LOWER) vs = C - (C - v) * (C - bot - LOWER) / max(C - B - LOWER, 0.01); // the fur below
    else if (v >= B) vs = v + (bot - B);                                                       // the lower lid
    else {
        // the eyeball: covered where a lid came down, stretched a little where one went up
        float mid = 0.5 * (top + bot);
        if (v < mid && L < top) vs = mid - (mid - v) * (mid - top) / (mid - L);
        else if (v > mid && B > bot) vs = mid + (v - mid) * (bot - mid) / (B - mid);
        // the glance: the iris slides along the eye (and a hair across) under the still lids
        if (mv.z != 0.0 || mv.w != 0.0) {
            float w = smoothstep(win.x, win.y, s) * (1.0 - smoothstep(win.z, win.w, s));
            float t = clamp((vs - top) / max(E, 0.01), 0.0, 1.0);
            us = u - mv.z * w;
            vec3 l2 = lidsAt(clamp((us - span.x) / (span.y - span.x), 0.0, 1.0), row);
            vs = clamp(vs - mv.w * w * 4.0 * t * (1.0 - t), l2.x + 0.25, max(l2.y - 0.25, l2.x + 0.25));
        }
    }
    return e.xy + us * ax + vs * dn;
}

// ---- the smirk: the far corner of the mouth drawn up on a bump
vec2 smirkBack(vec2 p) {
    vec2 q = p;
    for (int i = 0; i < 3; i++)
        q = p - smirkDir * (smirk.w * (1.0 - smoothstep(0.0, 1.0, length(q - smirk.xy) / smirk.z)));
    return q;
}

// ---- the ears: the turn at q (the whole ear, from nothing at the base; the flick, the top half only), fading out over
// ~16 px round the ear
float earTurn(vec2 q, vec4 e, vec2 size, float turn, float flick) {
    vec2 d = q - e.xy;
    float a = dot(d, e.zw), c = dot(d, vec2(-e.w, e.z));
    float el = length(vec2((a - 0.5 * size.x) / (0.5 * size.x + 16.0), c / (size.y + 16.0)));
    return (1.0 - smoothstep(0.6, 1.0, el)) * (turn * smoothstep(0.0, 0.6 * size.x, a) + flick * smoothstep(0.35 * size.x, 0.9 * size.x, a));
}
vec2 earBack(vec2 p, vec4 e, vec2 size, float turn, float flick) {
    vec2 d = p - e.xy;
    if (dot(d, d) > (size.x + 24.0) * (size.x + 24.0)) return p;
    vec2 q = p;
    for (int i = 0; i < 3; i++) {    // q turned by the turn at q lands on p
        float th = earTurn(q, e, size, turn, flick);
        float cs = cos(th), sn = sin(th);
        q = e.xy + vec2(cs * d.x + sn * d.y, cs * d.y - sn * d.x);
    }
    return q;
}

// ---- the jaw
vec2 dLow(vec2 q) {
    vec2 uv = q / 512.0;
    vec4 s = texture(mapShape, uv);
    return jaw * (dec2(texture(mapLow, uv).xy, 48.0) + shape * (pullRound.xy * dec(s.x, 1.0) + pullRound.zw * dec(s.y, 1.0)));
}
vec2 dUp(vec2 q) {
    vec2 uv = q / 512.0;
    return jaw * (dec2(texture(mapUp, uv).xy, 48.0) + shape * pullRound.xy * dec(texture(mapShape, uv).x, 1.0));
}
float side(vec2 q) { return dec(texture(mapUp, q / 512.0).z, 16.0); }
vec4 src(vec2 q) { return texture(source, (q + frame.xy) / frame.zw); }

const float TONGUE_TOP = 25.5;    // the tongue map's top: px above the mouth line (build_face.py)

void main() {
    vec2 p0 = qt_TexCoord0 * frame.zw - frame.xy;
    // the face first (these barely overlap, and the eyes and brows lie well clear of the jaw's fields)
    vec2 p = p0;
    if (ears.x != 0.0 || ears.z != 0.0) p = earBack(p, earL, earSize.xy, ears.x, ears.z);
    if (ears.y != 0.0 || ears.w != 0.0) p = earBack(p, earR, earSize.zw, ears.y, ears.w);
    if (brows != vec4(0.0)) p = browsBack(p);
    p = eyeBack(p, eyeL, eyeSpan.xy, lidL, lookWinL, 0.25);
    p = eyeBack(p, eyeR, eyeSpan.zw, lidR, lookWinR, 0.75);
    if (smirk.w != 0.0) p = smirkBack(p);
    if (jaw < 0.002) {            // shut: no inside, nothing more to do
        fragColor = src(p) * qt_Opacity;
        return;
    }

    vec2 qL = p, qU = p, qM = p;
    // invert q + d(q) = p: damped fixed point (the jaw stretches the face faster than a plain one converges)
    for (int i = 0; i < 8; i++) {
        qL = mix(qL, p - dLow(qL), 0.75);
        qU = mix(qU, p - dUp(qU), 0.75);
        qM = mix(qM, p - 0.5 * (dLow(qM) + dUp(qM)), 0.75);
    }
    float aL = smoothstep(-aa, aa, side(qL));
    float aU = 1.0 - smoothstep(-aa, aa, side(qU));
    float wU = aU;
    float wL = min(aL, 1.0 - aU);
    float g = clamp(1.0 - wU - wL, 0.0, 1.0);
    float fL = dec(texture(mapMask, qL / 512.0).x, 1.0);
    float fU = dec(texture(mapMask, qU / 512.0).x, 1.0);
    float fM = dec(texture(mapMask, qM / 512.0).x, 1.0);
    // the teeth move in one piece with their lip: by its displacement at the tooth's root, not by the field around
    // the tooth, which fades off towards the eyes and the chin and would stretch them. (Sampled outside the branch:
    // the teeth maps are mipmapped; biased half a level sharper, like the 1.5x layer the face comes from.)
    vec2 rU = p - dUp(qU - side(qU) * drop);
    vec2 rL = p - dLow(qL - side(qL) * drop);
    vec4 tU = texture(teethUp, (rU - teethRect.xy) / teethRect.zw, -0.5);
    vec4 tL = texture(teethLow, (rL - teethRect.xy) / teethRect.zw, -0.5);
    // the tongue rides the jaw too, behind the lower teeth: up = how far above the lower lip (in the jaw's rest
    // frame) this pixel is. Its front (tongue.y in the map) shows just over the teeth and its top contour lands
    // tongue.x above the lip, the back between them foreshortened the more the flatter it lies (tongue.z < 1)
    float up = -side(rL);
    float tt = tongue.y - (TONGUE_TOP + tongue.y) * pow(max(up, 0.0) / tongue.x, tongue.z);
    vec4 tg = texture(tongueMap, (rL + drop * (tt + up) - teethRect.xy) / teethRect.zw, -0.5) * step(up, 15.5);
    // in a crack of an opening they sit in the lips' shadow, and light up as the jaw drops
    float lit = mix(0.3, 1.0, smoothstep(0.02, 0.18, jaw));
    tU.rgb *= lit;
    tL.rgb *= lit;
    tg.rgb *= lit;

    vec4 col = src(qU) * (wU * fU) + src(qL) * (wL * fL);
    float cov = wU * fU + wL * fL;
    if (g > 0.0) {
        vec4 cv = mix(cavTop, cavDeep, smoothstep(-8.0, 8.0, side(qM)));
        cv = tg + cv * (1.0 - tg.a);
        cv = tL + cv * (1.0 - tL.a);
        cv = tU + cv * (1.0 - tU.a);
        float c = dec(texture(mapShape, qM / 512.0).z, 1.0);
        col += mix(src(qM), cv, c) * (g * fM);
        cov += g * fM;
    }
    col += src(p) * max(0.0, 1.0 - cov);
    fragColor = col * qt_Opacity;
}
