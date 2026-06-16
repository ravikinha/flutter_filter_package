#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp sampler3D;
precision highp samplerExternalOES;

// Single fragment shader that dispatches between all 10 filters via uFilter.
// Keeps shader-program switching to one swap, so filter changes are instant.
// Uses samplerExternalOES for camera output (Android OES texture).

uniform samplerExternalOES uTex;
uniform sampler3D uLut;
uniform float uLutMix;
uniform float uTime;
uniform vec2 uResolution;
uniform int uFilter;
// generic params
uniform float uP0;
uniform float uP1;
uniform float uP2;

in vec2 vTex;
out vec4 fragColor;

// --- helpers ------------------------------------------------------------
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

// 5-tap separable-ish gaussian blur (cheap, preview-quality)
vec3 sampleBlur(vec2 uv, float radius) {
    vec2 px = radius / uResolution * 6.0;
    vec3 sum = texture(uTex, uv).rgb * 0.36;
    sum += texture(uTex, uv + vec2( px.x,  0.0)).rgb * 0.16;
    sum += texture(uTex, uv + vec2(-px.x,  0.0)).rgb * 0.16;
    sum += texture(uTex, uv + vec2( 0.0,  px.y)).rgb * 0.16;
    sum += texture(uTex, uv + vec2( 0.0, -px.y)).rgb * 0.16;
    return sum;
}

// --- filters ------------------------------------------------------------
vec3 fKodak(vec3 c, vec2 uv) {
    // Warm highlights + yellow tint, contrast, low saturation, soft shadows.
    float warmth = uP0;
    float contrast = 1.0 + uP1 * 0.3;          // up to +30%
    float sat = 1.0 - uP2 * 0.3;               // down to -30%
    c = pow(c, vec3(0.96, 0.98, 1.05));        // lift blacks of channels
    c.r += 0.04 * warmth;
    c.g += 0.025 * warmth;
    c.b -= 0.03 * warmth;
    c = contrastAdj(c, contrast);
    c = saturationAdj(c, sat);
    return clamp(c, 0.0, 1.0);
}

vec3 fVintage(vec3 c, vec2 uv) {
    vec3 s = sepia(c);
    c = mix(c, s, uP0);
    // faded blacks
    c = mix(c, c * 0.92 + 0.06, 0.5);
    c = saturationAdj(c, 0.75);
    c = vignette(c, uv, uP1);
    return c;
}

vec3 fRetro(vec3 c, vec2 uv) {
    float warmth = uP0;
    float fade = uP1;
    float leak = uP2;
    c.r += 0.08 * warmth;
    c.b += 0.03 * (1.0 - warmth);
    c = mix(c, vec3(0.55, 0.5, 0.4), fade * 0.3);
    // light leak: red-pink glow from top-left
    float l = smoothstep(0.9, 0.0, distance(uv, vec2(0.15, 0.85)));
    c += vec3(0.45, 0.12, 0.18) * l * leak;
    c = contrastAdj(c, 0.95);
    return clamp(c, 0.0, 1.0);
}

vec3 fGrain(vec3 c, vec2 uv) {
    float n = hash(uv * uResolution + uTime * 60.0) - 0.5;
    c += n * uP0 * 0.25;
    return clamp(c, 0.0, 1.0);
}

vec3 fVHS(vec3 c, vec2 uv) {
    float split = uP0 * 0.012;
    float scan = uP1;
    float noise = uP2;
    vec3 col;
    col.r = texture(uTex, uv + vec2( split, 0.0)).r;
    col.g = texture(uTex, uv).g;
    col.b = texture(uTex, uv - vec2( split, 0.0)).b;
    // scanlines
    float s = sin(uv.y * uResolution.y * 1.8) * 0.5 + 0.5;
    col *= mix(1.0, s, scan * 0.45);
    // noise
    float n = hash(uv * uResolution + uTime * 80.0) - 0.5;
    col += n * noise * 0.25;
    return clamp(col, 0.0, 1.0);
}

vec3 fBWGlitch(vec3 c, vec2 uv) {
    float amt = uP0;     // glitch amount  (0..1)
    float dist = uP1;    // distortion amt (0..1)

    // Layout updates ~12x/sec so the effect looks like film tearing, not
    // continuous shimmer.
    float tSlow = floor(uTime * 12.0);

    // 1) Thin slice jitter — present often enough to read as a glitch but
    // not on every band. Threshold 0.88 → ~12% of slices active at a time.
    float bandSeed = hash(vec2(floor(uv.y * 120.0), tSlow));
    float band = step(0.88, bandSeed);
    float jitter = (hash(vec2(floor(uv.y * 200.0), tSlow)) - 0.5)
                   * amt * 0.10 * band;

    // 2) Occasional small block tear — modest displacement, rare.
    float blockRow = floor(uv.y * 8.0);
    float blockSeed = hash(vec2(blockRow, tSlow));
    float blockShift = step(0.95, blockSeed) *
                       (hash(vec2(blockRow, tSlow + 13.0)) - 0.5) * amt * 0.12;

    vec2 uvj = uv + vec2(jitter + blockShift, 0.0);

    // 3) Chromatic split — stronger than the original (0.008) but tame
    // compared to the over-the-top pass (up to 0.058).
    float split = (0.010 + dist * 0.015) * (0.5 + 0.5 * amt);
    float r = texture(uTex, uvj + vec2( split, 0.0)).r;
    float g = texture(uTex, uvj).g;
    float b = texture(uTex, uvj - vec2( split, 0.0)).b;
    vec3 col = vec3(r, g, b);

    // B&W with normal contrast — no invert flashes, no vertical tears.
    float bw = dot(col, vec3(0.299, 0.587, 0.114));
    return vec3(bw);
}

vec3 fBlur(vec3 c, vec2 uv) {
    return sampleBlur(uv, mix(0.5, 6.0, uP0));
}

vec3 fCinematic(vec3 c, vec2 uv) {
    float teal = uP0;
    float orange = uP1;
    float contrast = 1.0 + uP2 * 0.4;
    // luma-driven teal/orange split
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 shadowTint = vec3(0.08, 0.30, 0.36);
    vec3 highTint   = vec3(0.95, 0.62, 0.34);
    vec3 graded = mix(
        mix(c, c * shadowTint * 2.0, teal * (1.0 - l)),
        mix(c, c * highTint * 1.6,   orange * l),
        l
    );
    graded = contrastAdj(graded, contrast);
    return clamp(graded, 0.0, 1.0);
}

vec3 fCoolBlue(vec3 c, vec2 uv) {
    float cool = uP0;
    float contrast = 1.0 + uP1 * 0.3;
    c.r -= 0.05 * cool;
    c.b += 0.10 * cool;
    // shadows shifted toward blue
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(c, mix(c * vec3(0.6, 0.7, 1.1), c, l), cool);
    c = contrastAdj(c, contrast);
    return clamp(c, 0.0, 1.0);
}

vec3 fDreamGlow(vec3 c, vec2 uv) {
    float glow = uP0;
    float radius = mix(1.0, 6.0, uP1);
    vec3 blurred = sampleBlur(uv, radius);
    vec3 bright = max(blurred - 0.55, vec3(0.0));
    vec3 outc = c + bright * glow * 1.8;
    // soft tint
    outc = mix(outc, outc * vec3(1.05, 1.0, 1.08), 0.4);
    return clamp(outc, 0.0, 1.0);
}

// ------------------------------------------------------------------------
void main() {
    vec3 src = texture(uTex, vTex).rgb;
    vec3 col = src;

    if      (uFilter == 1)  col = fKodak(src, vTex);
    else if (uFilter == 2)  col = fVintage(src, vTex);
    else if (uFilter == 3)  col = fRetro(src, vTex);
    else if (uFilter == 4)  col = fGrain(src, vTex);
    else if (uFilter == 5)  col = fVHS(src, vTex);
    else if (uFilter == 6)  col = fBWGlitch(src, vTex);
    else if (uFilter == 7)  col = fBlur(src, vTex);
    else if (uFilter == 8)  col = fCinematic(src, vTex);
    else if (uFilter == 9)  col = fCoolBlue(src, vTex);
    else if (uFilter == 10) col = fDreamGlow(src, vTex);

    col = applyLut(col);
    fragColor = vec4(col, 1.0);
}
