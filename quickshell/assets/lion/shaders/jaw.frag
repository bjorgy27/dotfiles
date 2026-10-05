#version 440
// Q's lion: the default pose talking (LionAvatar.qml). Every pixel is pulled back through the lower-face and the
// upper-face displacement fields in assets/lion/jaw/ (built from the drawing's own mouth line); the mouth line's
// signed distance says which face a source pixel belongs to, so the lips part along it while both corners stay
// joined and the chin, cheeks and muzzle stretch with it. Where neither face lands, the lips have parted: the dark
// inside of the mouth. The collar stays put behind the chin. Rebuild: qsb --qt6 -o jaw.frag.qsb jaw.frag
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
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D mapLow;
layout(binding = 3) uniform sampler2D mapUp;
layout(binding = 4) uniform sampler2D mapShape;
layout(binding = 5) uniform sampler2D mapMask;

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

    vec4 col = src(qU) * (wU * fU) + src(qL) * (wL * fL);
    float cov = wU * fU + wL * fL;
    if (g > 0.0) {
        vec4 cv = mix(cavTop, cavDeep, smoothstep(-8.0, 8.0, side(qM)));
        float c = dec(texture(mapShape, qM / 512.0).z, 1.0);
        col += mix(src(qM), cv, c) * (g * fM);
        cov += g * fM;
    }
    col += src(p) * max(0.0, 1.0 - cov);
    fragColor = col * qt_Opacity;
}
