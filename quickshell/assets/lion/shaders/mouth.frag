#version 440
// Q's lion: the default pose talking (LionAvatar.qml). Every pixel is pulled back through the lower-face and the
// upper-face displacement fields in assets/lion/jaw/ (built from the drawing's own mouth line); the mouth line's
// signed distance says which face a source pixel belongs to, so the lips part along it while both corners stay
// joined and the chin, cheeks and muzzle stretch with it. Where neither face lands, the lips have parted: the dark
// inside of the mouth, with the teeth in it (Beck's own, lifted from his drawings into default-teeth-up / -low):
// the upper row is looked up through the upper face's field, so it hangs from the upper lip, the lower row through
// the lower face's, so it rides the jaw. Shut, there is no inside, so no teeth. The collar stays put behind the chin.
// Rebuild: qsb --qt6 -o mouth.frag.qsb mouth.frag. Qt Quick keeps a shader it has loaded for the life of the process,
// by file name, so a hot reload won't see a rebuilt .qsb: a changed shader gets a new name (this was jaw.frag).
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
    vec4 teethRect;   // where the teeth maps lie in the 512 frame: xy corner, zw size
    vec2 drop;        // the jaw's drop direction (unit): the teeth point along it
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D mapLow;
layout(binding = 3) uniform sampler2D mapUp;
layout(binding = 4) uniform sampler2D mapShape;
layout(binding = 5) uniform sampler2D mapMask;
layout(binding = 6) uniform sampler2D teethUp;
layout(binding = 7) uniform sampler2D teethLow;

vec2 dec2(vec2 c, float r) { return (c * 255.0 - 128.0) / 127.0 * r; }
float dec(float c, float r) { return (c * 255.0 - 128.0) / 127.0 * r; }

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

void main() {
    vec2 p = qt_TexCoord0 * frame.zw - frame.xy;
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
    // in a crack of an opening they sit in the lips' shadow, and light up as the jaw drops
    float lit = mix(0.3, 1.0, smoothstep(0.02, 0.18, jaw));
    tU.rgb *= lit;
    tL.rgb *= lit;

    vec4 col = src(qU) * (wU * fU) + src(qL) * (wL * fL);
    float cov = wU * fU + wL * fL;
    if (g > 0.0) {
        vec4 cv = mix(cavTop, cavDeep, smoothstep(-8.0, 8.0, side(qM)));
        cv = tL + cv * (1.0 - tL.a);
        cv = tU + cv * (1.0 - tU.a);
        float c = dec(texture(mapShape, qM / 512.0).z, 1.0);
        col += mix(src(qM), cv, c) * (g * fM);
        cov += g * fM;
    }
    col += src(p) * max(0.0, 1.0 - cov);
    fragColor = col * qt_Opacity;
}
