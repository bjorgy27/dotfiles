#version 440
// Orthographic globe: samples the flat Web-Mercator world texture (the map's
// tile stack rendered into a ShaderEffectSource) onto a sphere centred on
// (cLat, cLon). Outside the disc a soft atmosphere rim fades out.
// Source of globe.frag.qsb — recompile after editing:
//   qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o globe.frag.qsb globe.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 rimColor;     // atmosphere glow just outside the disc (alpha = strength)
    float cLat;        // view centre latitude, radians
    float cLon;        // view centre longitude, radians
    float discFrac;    // globe radius / (item half-size); the rest is rim
    float edge;        // anti-alias width in disc units (~1.5px / R)
    float limb;        // limb darkening strength 0..1
};
layout(binding = 1) uniform sampler2D src;

const float PI = 3.14159265358979;
const float MAX_LAT = 1.4844222297453322;   // 85.05112878 deg

void main() {
    // Disc coordinates: x right, y up, unit radius at the globe's edge.
    vec2 p = (qt_TexCoord0 - 0.5) * 2.0 / discFrac;
    p.y = -p.y;
    float r2 = dot(p, p);
    float r = sqrt(r2);

    if (r > 1.0) {
        // Atmosphere rim: quadratic falloff over the space outside the disc.
        float rimW = 1.0 / discFrac - 1.0;
        float t = clamp((r - 1.0) / max(rimW, 1e-4), 0.0, 1.0);
        float a = rimColor.a * (1.0 - t) * (1.0 - t);
        fragColor = vec4(rimColor.rgb * a, a) * qt_Opacity;
        return;
    }

    float z = sqrt(max(0.0, 1.0 - r2));
    float sa = sin(cLat), ca = cos(cLat);
    float yp = p.y * ca + z * sa;
    float zp = z * ca - p.y * sa;
    float lat = asin(clamp(yp, -1.0, 1.0));
    float lon = cLon + atan(p.x, zp);

    // Mercator has no data beyond +-85.05 deg; extend the last row over the
    // poles (Arctic ocean / Antarctic land) instead of painting a cap.
    lat = clamp(lat, -MAX_LAT, MAX_LAT);
    float u = fract((lon + PI) / (2.0 * PI));
    float v = 0.5 - log(tan(PI * 0.25 + lat * 0.5)) / (2.0 * PI);
    vec4 c = texture(src, vec2(u, clamp(v, 0.002, 0.998)));

    // Gentle limb darkening so the sphere reads as a sphere.
    float shade = 1.0 - limb * (1.0 - z);
    c.rgb *= shade;

    // Anti-aliased edge (premultiplied alpha).
    float aa = 1.0 - smoothstep(1.0 - edge, 1.0, r);
    fragColor = c * aa * qt_Opacity;
}
