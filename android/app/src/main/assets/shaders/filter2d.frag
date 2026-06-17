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

// Second-stage colour grade (see filter.frag for rationale).
uniform int uFilter2;
uniform float uP0b;
uniform float uP1b;
uniform float uP2b;

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

// --- new effect filters --------------------------------------------------

float edgeMag(vec2 uv) {
    vec2 px = 1.0 / uResolution;
    vec3 cl = texture(uTex, uv - vec2(px.x, 0.0)).rgb;
    vec3 cr = texture(uTex, uv + vec2(px.x, 0.0)).rgb;
    vec3 cu = texture(uTex, uv - vec2(0.0, px.y)).rgb;
    vec3 cd = texture(uTex, uv + vec2(0.0, px.y)).rgb;
    return length((cr - cl)) + length((cd - cu));
}

vec3 fCyberpunkHud(vec3 c, vec2 uv) {
    float e = smoothstep(0.08, 0.45, edgeMag(uv));
    vec3 neon = mix(vec3(1.0, 0.10, 0.85), vec3(0.0, 0.95, 1.0), uv.y);
    vec3 col = mix(c * 0.55, neon, e * uP0);
    float scan = sin(uv.y * uResolution.y * 1.5) * 0.5 + 0.5;
    col *= mix(1.0, scan, uP1 * 0.45);
    vec2 g = fract(uv * 22.0);
    float gridLine = step(0.96, g.x) + step(0.96, g.y);
    col += vec3(0.0, 0.85, 1.0) * gridLine * uP2 * 0.35;
    return clamp(col, 0.0, 1.0);
}

vec3 fHologram(vec3 c, vec2 uv) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 holo = vec3(l * 0.30, l * 0.85, l * 1.05);
    float scan = sin(uv.y * uResolution.y * 2.6 + uTime * 6.0) * 0.5 + 0.5;
    holo *= mix(1.0, scan, uP1 * 0.55);
    float t = floor(uTime * 30.0);
    float flick = mix(0.85, 1.0, hash(vec2(t, 0.0)));
    float slip = (hash(vec2(t, 7.0)) - 0.5) * 0.01;
    vec3 shifted = texture(uTex, vec2(uv.x + slip, uv.y)).rgb;
    holo = mix(holo, vec3(0.0, 1.0, 1.0) * dot(shifted, vec3(0.299, 0.587, 0.114)), 0.15) * flick;
    return clamp(mix(c, holo, uP0), 0.0, 1.0);
}

vec3 fMatrix(vec3 c, vec2 uv) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 m = vec3(l * 0.05, l * 1.10, l * 0.20);
    float col = floor(uv.x * 48.0);
    float t = uTime * (0.5 + uP1 * 4.0) + col * 7.3;
    float streak = step(0.55, hash(vec2(col, floor(t + uv.y * 28.0))));
    m += vec3(0.0, streak * 0.55, 0.0) * uP1;
    vec3 outc = mix(c * 0.18, m, uP0);
    return clamp(outc, 0.0, 1.0);
}

vec3 fNeonOutline(vec3 c, vec2 uv) {
    float e = smoothstep(0.05, 0.40, edgeMag(uv));
    float h = uP1 * 6.28318;
    vec3 neon = 0.5 + 0.5 * cos(h + vec3(0.0, 2.094, 4.188));
    vec3 outc = neon * e * uP0 * 2.2;
    outc += c * 0.15 * (1.0 - e);
    return clamp(outc, 0.0, 1.0);
}

vec3 fThermal(vec3 c, vec2 uv) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 thermal;
    if (l < 0.25)       thermal = mix(vec3(0.0, 0.0, 0.30), vec3(0.0, 0.0, 1.0), l * 4.0);
    else if (l < 0.50)  thermal = mix(vec3(0.0, 0.0, 1.0),  vec3(1.0, 0.0, 0.0), (l - 0.25) * 4.0);
    else if (l < 0.75)  thermal = mix(vec3(1.0, 0.0, 0.0),  vec3(1.0, 1.0, 0.0), (l - 0.50) * 4.0);
    else                thermal = mix(vec3(1.0, 1.0, 0.0),  vec3(1.0, 1.0, 1.0), (l - 0.75) * 4.0);
    return clamp(mix(c, thermal, uP0), 0.0, 1.0);
}

vec3 fCrtRetro(vec3 c, vec2 uv) {
    vec2 cuv = uv - 0.5;
    float r2 = dot(cuv, cuv);
    vec2 uvd = uv + cuv * r2 * uP2 * 0.35;
    float split = uP1 * 0.006;
    float r = texture(uTex, uvd + vec2(split, 0.0)).r;
    float g = texture(uTex, uvd).g;
    float b = texture(uTex, uvd - vec2(split, 0.0)).b;
    vec3 col = vec3(r, g, b);
    float scan = sin(uvd.y * uResolution.y * 1.8) * 0.5 + 0.5;
    col *= mix(1.0, scan, uP0 * 0.50);
    float vig = smoothstep(0.95, 0.45, length(cuv) * 1.35);
    return clamp(col * vig, 0.0, 1.0);
}

vec3 fVhsPro(vec3 c, vec2 uv) {
    float split = uP0 * 0.022;
    float r = texture(uTex, uv + vec2( split, 0.0)).r;
    float g = texture(uTex, uv).g;
    float b = texture(uTex, uv - vec2( split, 0.0)).b;
    vec3 col = vec3(r, g, b);
    float t = sin(uv.y * 24.0 + uTime * 4.5) * 0.5 + 0.5;
    float band = step(0.93, t) * uP1;
    col.r += band * 0.35; col.b += band * 0.10;
    float scan = sin(uv.y * uResolution.y * 1.4) * 0.5 + 0.5;
    col *= mix(1.0, scan, uP2 * 0.55);
    float n = hash(uv * uResolution + uTime * 75.0) - 0.5;
    col += n * 0.18;
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(l), col, 0.78);
    return clamp(col, 0.0, 1.0);
}

vec3 fKaleidoscope(vec3 c, vec2 uv) {
    float segCount = floor(2.0 + uP0 * 8.0);
    vec2 cuv = uv - 0.5;
    float r = length(cuv);
    float a = atan(cuv.y, cuv.x) + uP1 * 6.28318;
    float seg = 6.28318 / segCount;
    a = mod(a, seg);
    a = abs(a - seg * 0.5);
    vec2 ruv = vec2(cos(a), sin(a)) * r + 0.5;
    return texture(uTex, clamp(ruv, 0.0, 1.0)).rgb;
}

vec3 fElectricAura(vec3 c, vec2 uv) {
    vec2 px = 1.0 / uResolution;
    float glow = smoothstep(0.05, 0.40, edgeMag(uv));
    for (int i = 1; i <= 4; i++) {
        float fi = float(i);
        vec2 off = px * fi * 2.0;
        vec3 sl = texture(uTex, uv - vec2(off.x, 0.0)).rgb;
        vec3 sr = texture(uTex, uv + vec2(off.x, 0.0)).rgb;
        vec3 su = texture(uTex, uv - vec2(0.0, off.y)).rgb;
        vec3 sd = texture(uTex, uv + vec2(0.0, off.y)).rgb;
        float e = length(sr - sl) + length(sd - su);
        glow += smoothstep(0.05, 0.40, e) / fi;
    }
    float pulse = sin(uTime * 5.0) * 0.5 + 0.5;
    vec3 elec = mix(vec3(0.20, 0.60, 1.0), vec3(0.65, 0.20, 1.0), pulse);
    return clamp(c * 0.45 + elec * glow * uP0, 0.0, 1.0);
}

vec3 fScanner(vec3 c, vec2 uv) {
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 scan = vec3(l * 0.18, l * 0.85, l * 0.40);
    float scanY = fract(uTime * (0.15 + uP0 * 0.6));
    float scanLine = exp(-pow((uv.y - scanY) * 8.0, 2.0));
    scan += vec3(0.0, 1.0, 0.45) * scanLine * uP1;
    vec2 g = fract(uv * 16.0);
    float gridLine = step(0.96, g.x) + step(0.96, g.y);
    scan += vec3(0.0, 0.45, 0.25) * gridLine * 0.30;
    return clamp(scan, 0.0, 1.0);
}

// --- premium filters ----------------------------------------------------

vec3 fLiquidChrome(vec3 c, vec2 uv) {
    float t = uTime * 0.5;
    vec2 d = uv + vec2(
        sin(uv.y * 12.0 + t) * 0.012 * uP2,
        cos(uv.x * 12.0 + t) * 0.012 * uP2
    );
    vec3 s = texture(uTex, d).rgb;
    float l = dot(s, vec3(0.299, 0.587, 0.114));
    vec3 chrome = vec3(l * 0.95, l * 0.98, l * 1.05);
    float e = smoothstep(0.0, 0.40, edgeMag(d));
    chrome += vec3(0.60, 0.72, 0.88) * e * uP1 * 0.85;
    chrome += pow(max(l - 0.5, 0.0), 2.0) * uP1 * 1.6;
    return clamp(mix(c, chrome, uP0), 0.0, 1.0);
}

vec3 fGlassMorph(vec3 c, vec2 uv) {
    float t = uTime * 0.3;
    vec2 d = uv + vec2(
        sin(uv.y * 8.0 + t) * 0.008 * uP0,
        cos(uv.x * 8.0 - t) * 0.008 * uP0
    );
    vec3 refr = texture(uTex, d).rgb;
    vec3 blurred = sampleBlur(d, 3.5);
    vec3 col = mix(refr, blurred, 0.55);
    col = mix(col, col * vec3(0.95, 1.0, 1.08), 0.4);
    col = mix(c, col, uP1);
    float e = smoothstep(0.05, 0.40, edgeMag(uv));
    col += vec3(1.0, 1.0, 1.2) * e * uP2 * 0.7;
    return clamp(col, 0.0, 1.0);
}

vec3 fPrismLens(vec3 c, vec2 uv) {
    float s = uP0 * 0.03;
    float d = uP2 * 0.025;
    float r = texture(uTex, uv + vec2( s,  d)).r;
    float g = texture(uTex, uv).g;
    float b = texture(uTex, uv - vec2( s,  d)).b;
    vec3 col = vec3(r, g, b);
    float e = smoothstep(0.05, 0.35, edgeMag(uv));
    vec3 rainbow = 0.5 + 0.5 * cos(uv.x * 12.0 + uv.y * 6.0 + vec3(0.0, 2.094, 4.188));
    col += rainbow * e * uP1 * 0.65;
    return clamp(col, 0.0, 1.0);
}

vec3 fCinematicAnamorphic(vec3 c, vec2 uv) {
    vec3 blurred = sampleBlur(uv, mix(2.0, 5.0, uP1));
    vec3 bright = max(blurred - 0.50, vec3(0.0));
    vec3 col = c + bright * uP1 * 1.3;
    float flareLine = exp(-pow((uv.y - 0.5) * 25.0, 2.0)) * uP0 * 0.55;
    col += vec3(0.80, 0.92, 1.0) * flareLine;
    float l = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(col * vec3(0.70, 0.85, 0.95),
              col * vec3(1.12, 0.85, 0.70), l);
    col = clamp((col - 0.5) * 1.25 + 0.5, 0.0, 1.0);
    float n = hash(uv * uResolution + uTime * 40.0) - 0.5;
    col += n * uP2 * 0.14;
    return clamp(col, 0.0, 1.0);
}

vec3 fDreamLens(vec3 c, vec2 uv) {
    vec3 b1 = sampleBlur(uv, mix(1.5, 5.0,  uP1));
    vec3 b2 = sampleBlur(uv, mix(3.0, 10.0, uP1));
    vec3 bright = max(b1 - 0.55, vec3(0.0)) + max(b2 - 0.65, vec3(0.0)) * 0.5;
    vec3 col = c + bright * uP0 * 1.8;
    col = mix(col, col * vec3(1.10, 1.02, 0.95), 0.45);
    col += bright * vec3(0.90, 0.80, 0.70) * uP0 * 0.5;
    float leak = smoothstep(0.7, 0.0, distance(uv, vec2(0.15, 0.85)));
    col += vec3(1.0, 0.7, 0.5) * leak * uP2 * 0.55;
    return clamp(col, 0.0, 1.0);
}

vec3 fAurora(vec3 c, vec2 uv) {
    vec3 col = c;
    float t = uTime * (0.30 + uP0 * 1.6);
    float w1 = sin(uv.x *  6.0 + t * 1.2) * 0.04;
    float w2 = sin(uv.x * 12.0 + t * 0.8) * 0.02;
    float bandY1 = 0.30 + w1 + w2;
    float bandY2 = 0.75 + w1 * 0.5;
    float r1 = exp(-pow((uv.y - bandY1) * 6.0, 2.0));
    float r2 = exp(-pow((uv.y - bandY2) * 8.0, 2.0));
    vec3 hueA = mix(vec3(0.0, 1.0, 0.5), vec3(0.5, 0.0, 1.0), uv.x);
    hueA = mix(hueA, vec3(0.0, 0.6, 1.0), sin(t * 0.7) * 0.5 + 0.5);
    col += hueA * r1 * uP1 * 1.5;
    col += vec3(0.30, 1.0, 0.60) * r2 * uP1 * 0.6;
    col += hueA * r1 * uP2 * 0.5;
    return clamp(col, 0.0, 1.0);
}

vec3 fLightRays(vec3 c, vec2 uv) {
    const vec2 sunPos = vec2(0.72, 0.28);
    vec2 dir = uv - sunPos;
    float stepLen = mix(0.015, 0.05, uP1);
    vec3 rays = vec3(0.0);
    for (int i = 0; i < 14; i++) {
        float k = float(i) / 13.0;
        vec3 s = texture(uTex, uv - dir * k * stepLen * 2.0).rgb;
        float l = dot(s, vec3(0.299, 0.587, 0.114));
        rays += s * smoothstep(0.55, 1.0, l) * (1.0 - k * 0.5);
    }
    rays /= 14.0;
    float falloff = smoothstep(1.2, 0.0, length(dir));
    vec3 col = c + rays * uP0 * 2.2 * falloff;
    vec3 blurred = sampleBlur(uv, 4.0);
    col += max(blurred - 0.6, vec3(0.0)) * uP2 * 1.4;
    col = mix(col, col * vec3(1.05, 1.0, 0.95), 0.30);
    return clamp(col, 0.0, 1.0);
}

vec3 fHolographicGlass(vec3 c, vec2 uv) {
    float s = uP0 * 0.012;
    float r = texture(uTex, uv + vec2(s, 0.0)).r;
    float g = texture(uTex, uv).g;
    float b = texture(uTex, uv - vec2(s, 0.0)).b;
    vec3 col = vec3(r, g, b);
    float t = uTime * 0.5;
    vec3 rainbow = 0.5 + 0.5 * cos(t + uv.x * 6.0 + uv.y * 3.0 + vec3(0.0, 2.094, 4.188));
    col = mix(col, col * rainbow * 1.5, uP1 * 0.5);
    float e = smoothstep(0.05, 0.35, edgeMag(uv));
    col += rainbow * e * uP2 * 0.85;
    col = mix(c, col, uP0);
    return clamp(col, 0.0, 1.0);
}

vec3 fPhotonTrails(vec3 c, vec2 uv) {
    vec2 center = vec2(0.5);
    vec2 dir = normalize(uv - center + vec2(0.0001));
    float trailLen = uP0 * 0.06;
    vec3 trail = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        float k = float(i) / 7.0;
        vec3 s = texture(uTex, uv - dir * k * trailLen).rgb;
        float l = dot(s, vec3(0.299, 0.587, 0.114));
        trail += s * smoothstep(0.55, 1.0, l) * (1.0 - k * uP2);
    }
    trail /= 8.0;
    vec3 col = c + trail * uP1 * 2.4;
    vec3 energy = mix(vec3(0.50, 0.70, 1.0), vec3(0.90, 0.50, 1.0),
                      sin(uTime * 3.0) * 0.5 + 0.5);
    col += trail * energy * uP1 * 0.6;
    return clamp(col, 0.0, 1.0);
}

vec3 fNeuralGrid(vec3 c, vec2 uv) {
    float e = smoothstep(0.05, 0.35, edgeMag(uv));
    float density = mix(12.0, 40.0, uP0);
    vec2 g = fract(uv * density);
    float gridLine = step(0.95, g.x) + step(0.95, g.y);
    float nodes = step(0.92, g.x) * step(0.92, g.y);
    float scanY = fract(uTime * (0.20 + uP1 * 0.60));
    float scan = exp(-pow((uv.y - scanY) * 12.0, 2.0));
    const vec3 tech = vec3(0.0, 0.90, 0.70);
    vec3 col = c * 0.25;
    col += tech * e * 0.85;
    col += tech * gridLine * 0.32;
    col += vec3(0.0, 1.0, 0.80) * nodes * 1.15;
    col += vec3(0.0, 1.0, 0.50) * scan * 0.70;
    col *= uP2 * 1.5 + 0.5;
    return clamp(col, 0.0, 1.0);
}

vec3 fDogpatchPro(vec3 c, vec2 uv) {
    float warmth = uP0;
    float bloomAmt = uP1;
    float tex = uP2;
    c.r = clamp(c.r + 0.06 * warmth, 0.0, 1.0);
    c.g = clamp(c.g + 0.025 * warmth, 0.0, 1.0);
    c.b = clamp(c.b - 0.04 * warmth, 0.0, 1.0);
    c = clamp((c - 0.5) * (1.0 + 0.18 * warmth) + 0.5, 0.0, 1.0);
    float l1 = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(vec3(l1), c, 1.0 - 0.10 * warmth);
    c.r = clamp(c.r * (1.0 + 0.04 * warmth), 0.0, 1.0);
    c.g = clamp(c.g * (1.0 - 0.02 * warmth), 0.0, 1.0);
    c.b *= mix(1.0, 0.92, warmth * (1.0 - l1));
    float lum = dot(c, vec3(0.299, 0.587, 0.114));
    float hi = smoothstep(0.65, 1.0, lum);
    c.r = clamp(c.r + 0.14 * hi * warmth, 0.0, 1.0);
    c.g = clamp(c.g + 0.11 * hi * warmth, 0.0, 1.0);
    c.b = clamp(c.b - 0.07 * hi * warmth, 0.0, 1.0);
    vec3 blurred = sampleBlur(uv, mix(3.0, 10.0, bloomAmt));
    vec3 bright = max(blurred - 0.55, vec3(0.0));
    c += bright * bloomAmt * 1.20;
    float n = hash(uv * uResolution + floor(uTime * 6.0)) - 0.5;
    c += n * tex * 0.08;
    vec2 vUv = uv - 0.5;
    float vigShape = smoothstep(0.95, 0.30, length(vUv) * 1.15);
    c *= mix(1.0, vigShape, tex * 0.45);
    return clamp(c, 0.0, 1.0);
}

vec3 colorGrade(int which, vec3 c, vec2 uv, float p0, float p1, float p2) {
    if (which == 1) {
        c = pow(c, vec3(0.96, 0.98, 1.05));
        c.r += 0.04 * p0; c.g += 0.025 * p0; c.b -= 0.03 * p0;
        c = contrastAdj(c, 1.0 + p1 * 0.3);
        c = saturationAdj(c, 1.0 - p2 * 0.3);
        return clamp(c, 0.0, 1.0);
    } else if (which == 2) {
        c = mix(c, sepia(c), p0);
        c = mix(c, c * 0.92 + 0.06, 0.5);
        c = saturationAdj(c, 0.75);
        return vignette(c, uv, p1);
    } else if (which == 3) {
        c.r += 0.08 * p0;
        c.b += 0.03 * (1.0 - p0);
        c = mix(c, vec3(0.55, 0.5, 0.4), p1 * 0.3);
        float l = smoothstep(0.9, 0.0, distance(uv, vec2(0.15, 0.85)));
        c += vec3(0.45, 0.12, 0.18) * l * p2;
        return clamp(contrastAdj(c, 0.95), 0.0, 1.0);
    } else if (which == 8) {
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        vec3 graded = mix(
            mix(c, c * vec3(0.08, 0.30, 0.36) * 2.0, p0 * (1.0 - l)),
            mix(c, c * vec3(0.95, 0.62, 0.34) * 1.6, p1 * l),
            l
        );
        return clamp(contrastAdj(graded, 1.0 + p2 * 0.4), 0.0, 1.0);
    } else if (which == 9) {
        c.r -= 0.05 * p0; c.b += 0.10 * p0;
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        c = mix(c, mix(c * vec3(0.6, 0.7, 1.1), c, l), p0);
        return clamp(contrastAdj(c, 1.0 + p1 * 0.3), 0.0, 1.0);
    } else if (which == 13) {
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        vec3 m = vec3(l * 0.05, l * 1.10, l * 0.20);
        float colx = floor(uv.x * 48.0);
        float t = uTime * (0.5 + p1 * 4.0) + colx * 7.3;
        float streak = step(0.55, hash(vec2(colx, floor(t + uv.y * 28.0))));
        m += vec3(0.0, streak * 0.55, 0.0) * p1;
        return clamp(mix(c * 0.18, m, p0), 0.0, 1.0);
    } else if (which == 15) {
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        vec3 th;
        if (l < 0.25)      th = mix(vec3(0.0, 0.0, 0.30), vec3(0.0, 0.0, 1.0), l * 4.0);
        else if (l < 0.50) th = mix(vec3(0.0, 0.0, 1.0),  vec3(1.0, 0.0, 0.0), (l - 0.25) * 4.0);
        else if (l < 0.75) th = mix(vec3(1.0, 0.0, 0.0),  vec3(1.0, 1.0, 0.0), (l - 0.50) * 4.0);
        else               th = mix(vec3(1.0, 1.0, 0.0),  vec3(1.0, 1.0, 1.0), (l - 0.75) * 4.0);
        return clamp(mix(c, th, p0), 0.0, 1.0);
    }
    return c;
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
    else if (uFilter == 11) col = fCyberpunkHud(src, vTex);
    else if (uFilter == 12) col = fHologram(src, vTex);
    else if (uFilter == 13) col = fMatrix(src, vTex);
    else if (uFilter == 14) col = fNeonOutline(src, vTex);
    else if (uFilter == 15) col = fThermal(src, vTex);
    else if (uFilter == 16) col = fCrtRetro(src, vTex);
    else if (uFilter == 17) col = fVhsPro(src, vTex);
    else if (uFilter == 18) col = fKaleidoscope(src, vTex);
    else if (uFilter == 19) col = fElectricAura(src, vTex);
    else if (uFilter == 20) col = fScanner(src, vTex);
    else if (uFilter == 21) col = fLiquidChrome(src, vTex);
    else if (uFilter == 22) col = fGlassMorph(src, vTex);
    else if (uFilter == 23) col = fPrismLens(src, vTex);
    else if (uFilter == 24) col = fCinematicAnamorphic(src, vTex);
    else if (uFilter == 25) col = fDreamLens(src, vTex);
    else if (uFilter == 26) col = fAurora(src, vTex);
    else if (uFilter == 27) col = fLightRays(src, vTex);
    else if (uFilter == 28) col = fHolographicGlass(src, vTex);
    else if (uFilter == 29) col = fPhotonTrails(src, vTex);
    else if (uFilter == 30) col = fNeuralGrid(src, vTex);
    else if (uFilter == 31) col = fDogpatchPro(src, vTex);
    if (uFilter2 != 0) col = colorGrade(uFilter2, col, vTex, uP0b, uP1b, uP2b);
    col = applyLut(col);
    fragColor = vec4(col, 1.0);
}
