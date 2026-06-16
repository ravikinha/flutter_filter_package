#version 300 es
precision highp float;
precision highp sampler3D;

// Image-processing variant of filter.frag. Identical to the live-camera path
// except the input texture is a plain sampler2D (not an external-OES camera
// texture). The filter dispatch logic is the same so the look matches.

uniform sampler2D uTex;
uniform sampler3D uLut;
uniform float uLutMix;
uniform float uTime;
uniform vec2 uResolution;
uniform int uFilter;
uniform float uP0;
uniform float uP1;
uniform float uP2;

in vec2 vTex;
out vec4 fragColor;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
vec3 saturationAdj(vec3 c, float s) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    return mix(vec3(l), c, s);
}
vec3 contrastAdj(vec3 c, float k) {
    return clamp((c - 0.5) * k + 0.5, 0.0, 1.0);
}
vec3 vignette(vec3 c, vec2 uv, float strength) {
    float d = distance(uv, vec2(0.5));
    float v = smoothstep(0.8, 0.2, d);
    return mix(c, c * v, strength);
}
vec3 sepia(vec3 c) {
    return vec3(
        dot(c, vec3(0.393, 0.769, 0.189)),
        dot(c, vec3(0.349, 0.686, 0.168)),
        dot(c, vec3(0.272, 0.534, 0.131))
    );
}
vec3 applyLut(vec3 c) {
    if (uLutMix <= 0.001) return c;
    vec3 sampled = texture(uLut, clamp(c, 0.0, 1.0)).rgb;
    return mix(c, sampled, uLutMix);
}
vec3 sampleBlur(vec2 uv, float radius) {
    vec2 px = radius / uResolution * 6.0;
    vec3 sum = texture(uTex, uv).rgb * 0.36;
    sum += texture(uTex, uv + vec2( px.x,  0.0)).rgb * 0.16;
    sum += texture(uTex, uv + vec2(-px.x,  0.0)).rgb * 0.16;
    sum += texture(uTex, uv + vec2( 0.0,  px.y)).rgb * 0.16;
    sum += texture(uTex, uv + vec2( 0.0, -px.y)).rgb * 0.16;
    return sum;
}

vec3 fKodak(vec3 c) {
    float contrast = 1.0 + uP1 * 0.3;
    float sat = 1.0 - uP2 * 0.3;
    c = pow(c, vec3(0.96, 0.98, 1.05));
    c.r += 0.04 * uP0; c.g += 0.025 * uP0; c.b -= 0.03 * uP0;
    c = contrastAdj(c, contrast);
    c = saturationAdj(c, sat);
    return clamp(c, 0.0, 1.0);
}
vec3 fVintage(vec3 c, vec2 uv) {
    vec3 s = sepia(c);
    c = mix(c, s, uP0);
    c = mix(c, c * 0.92 + 0.06, 0.5);
    c = saturationAdj(c, 0.75);
    c = vignette(c, uv, uP1);
    return c;
}
vec3 fRetro(vec3 c, vec2 uv) {
    c.r += 0.08 * uP0;
    c.b += 0.03 * (1.0 - uP0);
    c = mix(c, vec3(0.55, 0.5, 0.4), uP1 * 0.3);
    float l = smoothstep(0.9, 0.0, distance(uv, vec2(0.15, 0.85)));
    c += vec3(0.45, 0.12, 0.18) * l * uP2;
    return clamp(contrastAdj(c, 0.95), 0.0, 1.0);
}
vec3 fGrain(vec3 c, vec2 uv) {
    float n = hash(uv * uResolution + uTime * 60.0) - 0.5;
    return clamp(c + n * uP0 * 0.25, 0.0, 1.0);
}
vec3 fVHS(vec2 uv) {
    float split = uP0 * 0.012;
    vec3 col;
    col.r = texture(uTex, uv + vec2( split, 0.0)).r;
    col.g = texture(uTex, uv).g;
    col.b = texture(uTex, uv - vec2( split, 0.0)).b;
    float s = sin(uv.y * uResolution.y * 1.8) * 0.5 + 0.5;
    col *= mix(1.0, s, uP1 * 0.45);
    float n = hash(uv * uResolution + uTime * 80.0) - 0.5;
    col += n * uP2 * 0.25;
    return clamp(col, 0.0, 1.0);
}
vec3 fBWGlitch(vec2 uv) {
    float amt = uP0;
    float dist = uP1;
    float tSlow = floor(uTime * 12.0);
    float bandSeed = hash(vec2(floor(uv.y * 120.0), tSlow));
    float band = step(0.88, bandSeed);
    float jitter = (hash(vec2(floor(uv.y * 200.0), tSlow)) - 0.5) * amt * 0.10 * band;
    float blockRow = floor(uv.y * 8.0);
    float blockSeed = hash(vec2(blockRow, tSlow));
    float blockShift = step(0.95, blockSeed) *
                       (hash(vec2(blockRow, tSlow + 13.0)) - 0.5) * amt * 0.12;
    vec2 uvj = uv + vec2(jitter + blockShift, 0.0);
    float split = (0.010 + dist * 0.015) * (0.5 + 0.5 * amt);
    float r = texture(uTex, uvj + vec2( split, 0.0)).r;
    float g = texture(uTex, uvj).g;
    float b = texture(uTex, uvj - vec2( split, 0.0)).b;
    vec3 col = vec3(r, g, b);
    float bw = dot(col, vec3(0.299, 0.587, 0.114));
    return vec3(bw);
}
vec3 fBlur(vec2 uv) {
    return sampleBlur(uv, mix(0.5, 6.0, uP0));
}
vec3 fCinematic(vec3 c) {
    float contrast = 1.0 + uP2 * 0.4;
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 shadowTint = vec3(0.08, 0.30, 0.36);
    vec3 highTint   = vec3(0.95, 0.62, 0.34);
    vec3 graded = mix(
        mix(c, c * shadowTint * 2.0, uP0 * (1.0 - l)),
        mix(c, c * highTint * 1.6,   uP1 * l),
        l
    );
    return clamp(contrastAdj(graded, contrast), 0.0, 1.0);
}
vec3 fCoolBlue(vec3 c) {
    float contrast = 1.0 + uP1 * 0.3;
    c.r -= 0.05 * uP0; c.b += 0.10 * uP0;
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(c, mix(c * vec3(0.6, 0.7, 1.1), c, l), uP0);
    return clamp(contrastAdj(c, contrast), 0.0, 1.0);
}
vec3 fDreamGlow(vec3 c, vec2 uv) {
    float radius = mix(1.0, 6.0, uP1);
    vec3 blurred = sampleBlur(uv, radius);
    vec3 bright = max(blurred - 0.55, vec3(0.0));
    vec3 outc = c + bright * uP0 * 1.8;
    outc = mix(outc, outc * vec3(1.05, 1.0, 1.08), 0.4);
    return clamp(outc, 0.0, 1.0);
}

void main() {
    vec3 src = texture(uTex, vTex).rgb;
    vec3 col = src;
    if      (uFilter == 1)  col = fKodak(src);
    else if (uFilter == 2)  col = fVintage(src, vTex);
    else if (uFilter == 3)  col = fRetro(src, vTex);
    else if (uFilter == 4)  col = fGrain(src, vTex);
    else if (uFilter == 5)  col = fVHS(vTex);
    else if (uFilter == 6)  col = fBWGlitch(vTex);
    else if (uFilter == 7)  col = fBlur(vTex);
    else if (uFilter == 8)  col = fCinematic(src);
    else if (uFilter == 9)  col = fCoolBlue(src);
    else if (uFilter == 10) col = fDreamGlow(src, vTex);
    col = applyLut(col);
    fragColor = vec4(col, 1.0);
}
