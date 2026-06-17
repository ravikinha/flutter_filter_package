#include <metal_stdlib>
using namespace metal;

// Mirror of Android filter.frag. Single kernel/fragment that dispatches between
// all 10 filters via uFilter so swapping filters is a uniform update, not a
// pipeline rebuild.

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float  time;
    float2 resolution;
    int    filterIdx;
    float  lutMix;
    float  p0;
    float  p1;
    float  p2;
    // Optional second-stage colour grade (applied after the primary filter).
    int    filterIdx2;
    float  p0b;
    float  p1b;
    float  p2b;
};

vertex VSOut fsq_vs(uint vid [[vertex_id]]) {
    // fullscreen triangle strip: positions in clip space, uv in [0,1].
    const float2 pos[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    VSOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = uvs[vid];
    return o;
}

// helpers ----------------------------------------------------------------
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
inline float3 satAdj(float3 c, float s) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    return mix(float3(l), c, s);
}
inline float3 conAdj(float3 c, float k) {
    return saturate((c - 0.5) * k + 0.5);
}
inline float3 vignette(float3 c, float2 uv, float strength) {
    float d = distance(uv, float2(0.5));
    float v = smoothstep(0.8, 0.2, d);
    return mix(c, c * v, strength);
}
inline float3 sepia(float3 c) {
    return float3(
        dot(c, float3(0.393, 0.769, 0.189)),
        dot(c, float3(0.349, 0.686, 0.168)),
        dot(c, float3(0.272, 0.534, 0.131))
    );
}
inline float3 blur5(texture2d<float> tex, sampler s, float2 uv, float2 res, float radius) {
    float2 px = radius / res * 6.0;
    float3 sum = tex.sample(s, uv).rgb * 0.36;
    sum += tex.sample(s, uv + float2( px.x, 0.0)).rgb * 0.16;
    sum += tex.sample(s, uv + float2(-px.x, 0.0)).rgb * 0.16;
    sum += tex.sample(s, uv + float2(0.0,  px.y)).rgb * 0.16;
    sum += tex.sample(s, uv + float2(0.0, -px.y)).rgb * 0.16;
    return sum;
}

inline float3 fKodak(float3 c, float p0, float p1, float p2) {
    float contrast = 1.0 + p1 * 0.3;
    float sat = 1.0 - p2 * 0.3;
    c = pow(c, float3(0.96, 0.98, 1.05));
    c.r += 0.04 * p0; c.g += 0.025 * p0; c.b -= 0.03 * p0;
    c = conAdj(c, contrast);
    c = satAdj(c, sat);
    return saturate(c);
}
inline float3 fVintage(float3 c, float2 uv, float p0, float p1) {
    float3 s = sepia(c);
    c = mix(c, s, p0);
    c = mix(c, c * 0.92 + 0.06, 0.5);
    c = satAdj(c, 0.75);
    return vignette(c, uv, p1);
}
inline float3 fRetro(float3 c, float2 uv, float p0, float p1, float p2) {
    c.r += 0.08 * p0; c.b += 0.03 * (1.0 - p0);
    c = mix(c, float3(0.55, 0.5, 0.4), p1 * 0.3);
    float l = smoothstep(0.9, 0.0, distance(uv, float2(0.15, 0.85)));
    c += float3(0.45, 0.12, 0.18) * l * p2;
    return saturate(conAdj(c, 0.95));
}
inline float3 fGrain(float3 c, float2 uv, float2 res, float t, float p0) {
    float n = hash21(uv * res + t * 60.0) - 0.5;
    return saturate(c + n * p0 * 0.25);
}
inline float3 fVHS(texture2d<float> tex, sampler s, float2 uv, float2 res, float t,
                   float p0, float p1, float p2) {
    float split = p0 * 0.012;
    float3 col;
    col.r = tex.sample(s, uv + float2( split, 0.0)).r;
    col.g = tex.sample(s, uv).g;
    col.b = tex.sample(s, uv - float2( split, 0.0)).b;
    float scan = sin(uv.y * res.y * 1.8) * 0.5 + 0.5;
    col *= mix(1.0, scan, p1 * 0.45);
    float n = hash21(uv * res + t * 80.0) - 0.5;
    col += n * p2 * 0.25;
    return saturate(col);
}
inline float3 fBWGlitch(texture2d<float> tex, sampler s, float2 uv, float t,
                         float p0, float p1) {
    float amt = p0;     // glitch amount
    float dist = p1;    // distortion amt

    // Layout refreshes ~12x/sec so the effect reads as discrete tears.
    float tSlow = floor(t * 12.0);

    // 1) Thin slice jitter — ~12% of slices active per refresh.
    float bandSeed = hash21(float2(floor(uv.y * 120.0), tSlow));
    float band = step(0.88, bandSeed);
    float jitter = (hash21(float2(floor(uv.y * 200.0), tSlow)) - 0.5)
                    * amt * 0.10 * band;

    // 2) Occasional small block tear.
    float blockRow = floor(uv.y * 8.0);
    float blockSeed = hash21(float2(blockRow, tSlow));
    float blockShift = step(0.95, blockSeed) *
                       (hash21(float2(blockRow, tSlow + 13.0)) - 0.5) * amt * 0.12;

    float2 uvj = uv + float2(jitter + blockShift, 0.0);

    // 3) Chromatic split — moderate.
    float split = (0.010 + dist * 0.015) * (0.5 + 0.5 * amt);
    float r = tex.sample(s, uvj + float2( split, 0.0)).r;
    float g = tex.sample(s, uvj).g;
    float b = tex.sample(s, uvj - float2( split, 0.0)).b;
    float3 col = float3(r, g, b);

    float bw = dot(col, float3(0.299, 0.587, 0.114));
    return float3(bw);
}
inline float3 fCinematic(float3 c, float p0, float p1, float p2) {
    float contrast = 1.0 + p2 * 0.4;
    float l = dot(c, float3(0.299, 0.587, 0.114));
    float3 shadowTint = float3(0.08, 0.30, 0.36);
    float3 highTint   = float3(0.95, 0.62, 0.34);
    float3 graded = mix(
        mix(c, c * shadowTint * 2.0, p0 * (1.0 - l)),
        mix(c, c * highTint * 1.6,   p1 * l),
        l
    );
    return saturate(conAdj(graded, contrast));
}
inline float3 fCoolBlue(float3 c, float p0, float p1) {
    float contrast = 1.0 + p1 * 0.3;
    c.r -= 0.05 * p0; c.b += 0.10 * p0;
    float l = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(c, mix(c * float3(0.6, 0.7, 1.1), c, l), p0);
    return saturate(conAdj(c, contrast));
}

// --- new effect filters --------------------------------------------------

inline float edgeMag(texture2d<float> tex, sampler s, float2 uv, float2 res) {
    float2 px = 1.0 / res;
    float3 cl = tex.sample(s, uv - float2(px.x, 0.0)).rgb;
    float3 cr = tex.sample(s, uv + float2(px.x, 0.0)).rgb;
    float3 cu = tex.sample(s, uv - float2(0.0, px.y)).rgb;
    float3 cd = tex.sample(s, uv + float2(0.0, px.y)).rgb;
    return length(cr - cl) + length(cd - cu);
}

inline float3 fCyberpunkHud(float3 c, float2 uv, texture2d<float> tex, sampler s,
                            float2 res, float p0, float p1, float p2) {
    float e = smoothstep(0.08, 0.45, edgeMag(tex, s, uv, res));
    float3 neon = mix(float3(1.0, 0.10, 0.85), float3(0.0, 0.95, 1.0), uv.y);
    float3 col = mix(c * 0.55, neon, e * p0);
    float scan = sin(uv.y * res.y * 1.5) * 0.5 + 0.5;
    col *= mix(1.0, scan, p1 * 0.45);
    float2 g = fract(uv * 22.0);
    float gridLine = step(0.96, g.x) + step(0.96, g.y);
    col += float3(0.0, 0.85, 1.0) * gridLine * p2 * 0.35;
    return saturate(col);
}

inline float3 fHologram(float3 c, float2 uv, texture2d<float> tex, sampler s,
                        float2 res, float t, float p0, float p1) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    float3 holo = float3(l * 0.30, l * 0.85, l * 1.05);
    float scan = sin(uv.y * res.y * 2.6 + t * 6.0) * 0.5 + 0.5;
    holo *= mix(1.0, scan, p1 * 0.55);
    float tt = floor(t * 30.0);
    float flick = mix(0.85, 1.0, hash21(float2(tt, 0.0)));
    float slip = (hash21(float2(tt, 7.0)) - 0.5) * 0.01;
    float3 shifted = tex.sample(s, float2(uv.x + slip, uv.y)).rgb;
    holo = mix(holo, float3(0.0, 1.0, 1.0) * dot(shifted, float3(0.299, 0.587, 0.114)), 0.15) * flick;
    return saturate(mix(c, holo, p0));
}

inline float3 fMatrix(float3 c, float2 uv, float t, float p0, float p1) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    float3 m = float3(l * 0.05, l * 1.10, l * 0.20);
    float colIdx = floor(uv.x * 48.0);
    float tt = t * (0.5 + p1 * 4.0) + colIdx * 7.3;
    float streak = step(0.55, hash21(float2(colIdx, floor(tt + uv.y * 28.0))));
    m += float3(0.0, streak * 0.55, 0.0) * p1;
    float3 outc = mix(c * 0.18, m, p0);
    return saturate(outc);
}

inline float3 fNeonOutline(float3 c, float2 uv, texture2d<float> tex, sampler s,
                           float2 res, float p0, float p1) {
    float e = smoothstep(0.05, 0.40, edgeMag(tex, s, uv, res));
    float h = p1 * 6.28318;
    float3 neon = 0.5 + 0.5 * cos(h + float3(0.0, 2.094, 4.188));
    float3 outc = neon * e * p0 * 2.2;
    outc += c * 0.15 * (1.0 - e);
    return saturate(outc);
}

inline float3 fThermal(float3 c, float p0) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    float3 thermal;
    if (l < 0.25)       thermal = mix(float3(0.0, 0.0, 0.30), float3(0.0, 0.0, 1.0), l * 4.0);
    else if (l < 0.50)  thermal = mix(float3(0.0, 0.0, 1.0),  float3(1.0, 0.0, 0.0), (l - 0.25) * 4.0);
    else if (l < 0.75)  thermal = mix(float3(1.0, 0.0, 0.0),  float3(1.0, 1.0, 0.0), (l - 0.50) * 4.0);
    else                thermal = mix(float3(1.0, 1.0, 0.0),  float3(1.0, 1.0, 1.0), (l - 0.75) * 4.0);
    return saturate(mix(c, thermal, p0));
}

inline float3 fCrtRetro(float2 uv, texture2d<float> tex, sampler s,
                        float2 res, float p0, float p1, float p2) {
    float2 cuv = uv - 0.5;
    float r2 = dot(cuv, cuv);
    float2 uvd = uv + cuv * r2 * p2 * 0.35;
    float split = p1 * 0.006;
    float r = tex.sample(s, uvd + float2(split, 0.0)).r;
    float g = tex.sample(s, uvd).g;
    float b = tex.sample(s, uvd - float2(split, 0.0)).b;
    float3 col = float3(r, g, b);
    float scan = sin(uvd.y * res.y * 1.8) * 0.5 + 0.5;
    col *= mix(1.0, scan, p0 * 0.50);
    float vig = smoothstep(0.95, 0.45, length(cuv) * 1.35);
    return saturate(col * vig);
}

inline float3 fVhsPro(float2 uv, texture2d<float> tex, sampler s,
                      float2 res, float t, float p0, float p1, float p2) {
    float split = p0 * 0.022;
    float r = tex.sample(s, uv + float2( split, 0.0)).r;
    float g = tex.sample(s, uv).g;
    float b = tex.sample(s, uv - float2( split, 0.0)).b;
    float3 col = float3(r, g, b);
    float tw = sin(uv.y * 24.0 + t * 4.5) * 0.5 + 0.5;
    float band = step(0.93, tw) * p1;
    col.r += band * 0.35; col.b += band * 0.10;
    float scan = sin(uv.y * res.y * 1.4) * 0.5 + 0.5;
    col *= mix(1.0, scan, p2 * 0.55);
    float n = hash21(uv * res + t * 75.0) - 0.5;
    col += n * 0.18;
    float l = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(l), col, 0.78);
    return saturate(col);
}

inline float3 fKaleidoscope(float2 uv, texture2d<float> tex, sampler s,
                            float p0, float p1) {
    float segCount = floor(2.0 + p0 * 8.0);
    float2 cuv = uv - 0.5;
    float r = length(cuv);
    float a = atan2(cuv.y, cuv.x) + p1 * 6.28318;
    float seg = 6.28318 / segCount;
    a = fmod(a, seg);
    a = abs(a - seg * 0.5);
    float2 ruv = float2(cos(a), sin(a)) * r + 0.5;
    return tex.sample(s, clamp(ruv, 0.0, 1.0)).rgb;
}

inline float3 fElectricAura(float3 c, float2 uv, texture2d<float> tex, sampler s,
                            float2 res, float t, float p0) {
    float2 px = 1.0 / res;
    float glow = smoothstep(0.05, 0.40, edgeMag(tex, s, uv, res));
    for (int i = 1; i <= 4; i++) {
        float fi = float(i);
        float2 off = px * fi * 2.0;
        float3 sl = tex.sample(s, uv - float2(off.x, 0.0)).rgb;
        float3 sr = tex.sample(s, uv + float2(off.x, 0.0)).rgb;
        float3 su = tex.sample(s, uv - float2(0.0, off.y)).rgb;
        float3 sd = tex.sample(s, uv + float2(0.0, off.y)).rgb;
        float e = length(sr - sl) + length(sd - su);
        glow += smoothstep(0.05, 0.40, e) / fi;
    }
    float pulse = sin(t * 5.0) * 0.5 + 0.5;
    float3 elec = mix(float3(0.20, 0.60, 1.0), float3(0.65, 0.20, 1.0), pulse);
    return saturate(c * 0.45 + elec * glow * p0);
}

inline float3 fScanner(float3 c, float2 uv, float t, float p0, float p1) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    float3 scan = float3(l * 0.18, l * 0.85, l * 0.40);
    float scanY = fract(t * (0.15 + p0 * 0.6));
    float scanLine = exp(-pow((uv.y - scanY) * 8.0, 2.0));
    scan += float3(0.0, 1.0, 0.45) * scanLine * p1;
    float2 g = fract(uv * 16.0);
    float gridLine = step(0.96, g.x) + step(0.96, g.y);
    scan += float3(0.0, 0.45, 0.25) * gridLine * 0.30;
    return saturate(scan);
}

// --- premium filters ----------------------------------------------------

inline float3 fLiquidChrome(float3 c, float2 uv, texture2d<float> tex, sampler s,
                            float2 res, float t, float p0, float p1, float p2) {
    float ts = t * 0.5;
    float2 d = uv + float2(
        sin(uv.y * 12.0 + ts) * 0.012 * p2,
        cos(uv.x * 12.0 + ts) * 0.012 * p2
    );
    float3 src = tex.sample(s, d).rgb;
    float l = dot(src, float3(0.299, 0.587, 0.114));
    float3 chrome = float3(l * 0.95, l * 0.98, l * 1.05);
    float e = smoothstep(0.0, 0.40, edgeMag(tex, s, d, res));
    chrome += float3(0.60, 0.72, 0.88) * e * p1 * 0.85;
    chrome += pow(max(l - 0.5, 0.0), 2.0) * p1 * 1.6;
    return saturate(mix(c, chrome, p0));
}

inline float3 fGlassMorph(float3 c, float2 uv, texture2d<float> tex, sampler s,
                          float2 res, float t, float p0, float p1, float p2) {
    float ts = t * 0.3;
    float2 d = uv + float2(
        sin(uv.y * 8.0 + ts) * 0.008 * p0,
        cos(uv.x * 8.0 - ts) * 0.008 * p0
    );
    float3 refr = tex.sample(s, d).rgb;
    float3 blurred = blur5(tex, s, d, res, 3.5);
    float3 col = mix(refr, blurred, 0.55);
    col = mix(col, col * float3(0.95, 1.0, 1.08), 0.4);
    col = mix(c, col, p1);
    float e = smoothstep(0.05, 0.40, edgeMag(tex, s, uv, res));
    col += float3(1.0, 1.0, 1.2) * e * p2 * 0.7;
    return saturate(col);
}

inline float3 fPrismLens(float3 c, float2 uv, texture2d<float> tex, sampler s,
                         float2 res, float p0, float p1, float p2) {
    float ss = p0 * 0.03;
    float dd = p2 * 0.025;
    float r = tex.sample(s, uv + float2( ss,  dd)).r;
    float g = tex.sample(s, uv).g;
    float b = tex.sample(s, uv - float2( ss,  dd)).b;
    float3 col = float3(r, g, b);
    float e = smoothstep(0.05, 0.35, edgeMag(tex, s, uv, res));
    float3 rainbow = 0.5 + 0.5 * cos(uv.x * 12.0 + uv.y * 6.0 + float3(0.0, 2.094, 4.188));
    col += rainbow * e * p1 * 0.65;
    return saturate(col);
}

inline float3 fCinematicAnamorphic(float3 c, float2 uv, texture2d<float> tex, sampler s,
                                   float2 res, float t, float p0, float p1, float p2) {
    float3 blurred = blur5(tex, s, uv, res, mix(2.0, 5.0, p1));
    float3 bright = max(blurred - 0.50, float3(0.0));
    float3 col = c + bright * p1 * 1.3;
    float flareLine = exp(-pow((uv.y - 0.5) * 25.0, 2.0)) * p0 * 0.55;
    col += float3(0.80, 0.92, 1.0) * flareLine;
    float l = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col * float3(0.70, 0.85, 0.95),
              col * float3(1.12, 0.85, 0.70), l);
    col = saturate((col - 0.5) * 1.25 + 0.5);
    float n = hash21(uv * res + t * 40.0) - 0.5;
    col += n * p2 * 0.14;
    return saturate(col);
}

inline float3 fDreamLens(float3 c, float2 uv, texture2d<float> tex, sampler s,
                         float2 res, float p0, float p1, float p2) {
    float3 b1 = blur5(tex, s, uv, res, mix(1.5, 5.0,  p1));
    float3 b2 = blur5(tex, s, uv, res, mix(3.0, 10.0, p1));
    float3 bright = max(b1 - 0.55, float3(0.0)) + max(b2 - 0.65, float3(0.0)) * 0.5;
    float3 col = c + bright * p0 * 1.8;
    col = mix(col, col * float3(1.10, 1.02, 0.95), 0.45);
    col += bright * float3(0.90, 0.80, 0.70) * p0 * 0.5;
    float leak = smoothstep(0.7, 0.0, distance(uv, float2(0.15, 0.85)));
    col += float3(1.0, 0.7, 0.5) * leak * p2 * 0.55;
    return saturate(col);
}

inline float3 fAurora(float3 c, float2 uv, float t, float p0, float p1, float p2) {
    float3 col = c;
    float ts = t * (0.30 + p0 * 1.6);
    float w1 = sin(uv.x *  6.0 + ts * 1.2) * 0.04;
    float w2 = sin(uv.x * 12.0 + ts * 0.8) * 0.02;
    float bandY1 = 0.30 + w1 + w2;
    float bandY2 = 0.75 + w1 * 0.5;
    float r1 = exp(-pow((uv.y - bandY1) * 6.0, 2.0));
    float r2 = exp(-pow((uv.y - bandY2) * 8.0, 2.0));
    float3 hueA = mix(float3(0.0, 1.0, 0.5), float3(0.5, 0.0, 1.0), uv.x);
    hueA = mix(hueA, float3(0.0, 0.6, 1.0), sin(ts * 0.7) * 0.5 + 0.5);
    col += hueA * r1 * p1 * 1.5;
    col += float3(0.30, 1.0, 0.60) * r2 * p1 * 0.6;
    col += hueA * r1 * p2 * 0.5;
    return saturate(col);
}

inline float3 fLightRays(float3 c, float2 uv, texture2d<float> tex, sampler s,
                         float2 res, float p0, float p1, float p2) {
    const float2 sunPos = float2(0.72, 0.28);
    float2 dir = uv - sunPos;
    float stepLen = mix(0.015, 0.05, p1);
    float3 rays = float3(0.0);
    for (int i = 0; i < 14; i++) {
        float k = float(i) / 13.0;
        float3 sp = tex.sample(s, uv - dir * k * stepLen * 2.0).rgb;
        float l = dot(sp, float3(0.299, 0.587, 0.114));
        rays += sp * smoothstep(0.55, 1.0, l) * (1.0 - k * 0.5);
    }
    rays /= 14.0;
    float falloff = smoothstep(1.2, 0.0, length(dir));
    float3 col = c + rays * p0 * 2.2 * falloff;
    float3 blurred = blur5(tex, s, uv, res, 4.0);
    col += max(blurred - 0.6, float3(0.0)) * p2 * 1.4;
    col = mix(col, col * float3(1.05, 1.0, 0.95), 0.30);
    return saturate(col);
}

inline float3 fHolographicGlass(float3 c, float2 uv, texture2d<float> tex, sampler s,
                                float2 res, float t, float p0, float p1, float p2) {
    float ss = p0 * 0.012;
    float r = tex.sample(s, uv + float2(ss, 0.0)).r;
    float g = tex.sample(s, uv).g;
    float b = tex.sample(s, uv - float2(ss, 0.0)).b;
    float3 col = float3(r, g, b);
    float ts = t * 0.5;
    float3 rainbow = 0.5 + 0.5 * cos(ts + uv.x * 6.0 + uv.y * 3.0 + float3(0.0, 2.094, 4.188));
    col = mix(col, col * rainbow * 1.5, p1 * 0.5);
    float e = smoothstep(0.05, 0.35, edgeMag(tex, s, uv, res));
    col += rainbow * e * p2 * 0.85;
    col = mix(c, col, p0);
    return saturate(col);
}

inline float3 fPhotonTrails(float3 c, float2 uv, texture2d<float> tex, sampler s,
                            float t, float p0, float p1, float p2) {
    float2 center = float2(0.5);
    float2 dir = normalize(uv - center + float2(0.0001));
    float trailLen = p0 * 0.06;
    float3 trail = float3(0.0);
    for (int i = 0; i < 8; i++) {
        float k = float(i) / 7.0;
        float3 sp = tex.sample(s, uv - dir * k * trailLen).rgb;
        float l = dot(sp, float3(0.299, 0.587, 0.114));
        trail += sp * smoothstep(0.55, 1.0, l) * (1.0 - k * p2);
    }
    trail /= 8.0;
    float3 col = c + trail * p1 * 2.4;
    float3 energy = mix(float3(0.50, 0.70, 1.0), float3(0.90, 0.50, 1.0),
                        sin(t * 3.0) * 0.5 + 0.5);
    col += trail * energy * p1 * 0.6;
    return saturate(col);
}

inline float3 fNeuralGrid(float3 c, float2 uv, texture2d<float> tex, sampler s,
                          float2 res, float t, float p0, float p1, float p2) {
    float e = smoothstep(0.05, 0.35, edgeMag(tex, s, uv, res));
    float density = mix(12.0, 40.0, p0);
    float2 g = fract(uv * density);
    float gridLine = step(0.95, g.x) + step(0.95, g.y);
    float nodes = step(0.92, g.x) * step(0.92, g.y);
    float scanY = fract(t * (0.20 + p1 * 0.60));
    float scan = exp(-pow((uv.y - scanY) * 12.0, 2.0));
    const float3 tech = float3(0.0, 0.90, 0.70);
    float3 col = c * 0.25;
    col += tech * e * 0.85;
    col += tech * gridLine * 0.32;
    col += float3(0.0, 1.0, 0.80) * nodes * 1.15;
    col += float3(0.0, 1.0, 0.50) * scan * 0.70;
    col *= p2 * 1.5 + 0.5;
    return saturate(col);
}

inline float3 fDogpatchPro(float3 c, float2 uv, texture2d<float> tex, sampler s,
                           float2 res, float t, float p0, float p1, float p2) {
    float warmth = p0;
    float bloomAmt = p1;
    float texAmt = p2;
    // 1) warm Kodak grade
    c.r = saturate(c.r + 0.06 * warmth);
    c.g = saturate(c.g + 0.025 * warmth);
    c.b = saturate(c.b - 0.04 * warmth);
    c = saturate((c - 0.5) * (1.0 + 0.18 * warmth) + 0.5);
    float l1 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l1), c, 1.0 - 0.10 * warmth);
    c.r = saturate(c.r * (1.0 + 0.04 * warmth));
    c.g = saturate(c.g * (1.0 - 0.02 * warmth));
    c.b *= mix(1.0, 0.92, warmth * (1.0 - l1));
    // 2) golden highlights
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    float hi = smoothstep(0.65, 1.0, lum);
    c.r = saturate(c.r + 0.14 * hi * warmth);
    c.g = saturate(c.g + 0.11 * hi * warmth);
    c.b = saturate(c.b - 0.07 * hi * warmth);
    // 3) bloom
    float3 blurred = blur5(tex, s, uv, res, mix(3.0, 10.0, bloomAmt));
    float3 bright = max(blurred - 0.55, float3(0.0));
    c += bright * bloomAmt * 1.20;
    // 4) film grain (slow refresh)
    float n = hash21(uv * res + floor(t * 6.0)) - 0.5;
    c += n * texAmt * 0.08;
    // 5) soft vignette
    float2 vUv = uv - 0.5;
    float vig = smoothstep(0.95, 0.30, length(vUv) * 1.15);
    c *= mix(1.0, vig, texAmt * 0.45);
    return saturate(c);
}

fragment float4 filter_fs(VSOut in [[stage_in]],
                          texture2d<float> srcTex [[texture(0)]],
                          texture3d<float> lutTex [[texture(1)]],
                          sampler texSampler [[sampler(0)]],
                          sampler lutSampler [[sampler(1)]],
                          constant Uniforms& U [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 src = srcTex.sample(texSampler, uv).rgb;
    float3 col = src;

    switch (U.filterIdx) {
        case 1:  col = fKodak(src, U.p0, U.p1, U.p2); break;
        case 2:  col = fVintage(src, uv, U.p0, U.p1); break;
        case 3:  col = fRetro(src, uv, U.p0, U.p1, U.p2); break;
        case 4:  col = fGrain(src, uv, U.resolution, U.time, U.p0); break;
        case 5:  col = fVHS(srcTex, texSampler, uv, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 6:  col = fBWGlitch(srcTex, texSampler, uv, U.time, U.p0, U.p1); break;
        case 7:  col = blur5(srcTex, texSampler, uv, U.resolution, mix(0.5, 6.0, U.p0)); break;
        case 8:  col = fCinematic(src, U.p0, U.p1, U.p2); break;
        case 9:  col = fCoolBlue(src, U.p0, U.p1); break;
        case 10: {
            float radius = mix(1.0, 6.0, U.p1);
            float3 blurred = blur5(srcTex, texSampler, uv, U.resolution, radius);
            float3 bright = max(blurred - 0.55, float3(0.0));
            float3 outc = src + bright * U.p0 * 1.8;
            col = saturate(mix(outc, outc * float3(1.05, 1.0, 1.08), 0.4));
            break;
        }
        case 11: col = fCyberpunkHud(src, uv, srcTex, texSampler, U.resolution, U.p0, U.p1, U.p2); break;
        case 12: col = fHologram(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1); break;
        case 13: col = fMatrix(src, uv, U.time, U.p0, U.p1); break;
        case 14: col = fNeonOutline(src, uv, srcTex, texSampler, U.resolution, U.p0, U.p1); break;
        case 15: col = fThermal(src, U.p0); break;
        case 16: col = fCrtRetro(uv, srcTex, texSampler, U.resolution, U.p0, U.p1, U.p2); break;
        case 17: col = fVhsPro(uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 18: col = fKaleidoscope(uv, srcTex, texSampler, U.p0, U.p1); break;
        case 19: col = fElectricAura(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0); break;
        case 20: col = fScanner(src, uv, U.time, U.p0, U.p1); break;
        case 21: col = fLiquidChrome(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 22: col = fGlassMorph(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 23: col = fPrismLens(src, uv, srcTex, texSampler, U.resolution, U.p0, U.p1, U.p2); break;
        case 24: col = fCinematicAnamorphic(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 25: col = fDreamLens(src, uv, srcTex, texSampler, U.resolution, U.p0, U.p1, U.p2); break;
        case 26: col = fAurora(src, uv, U.time, U.p0, U.p1, U.p2); break;
        case 27: col = fLightRays(src, uv, srcTex, texSampler, U.resolution, U.p0, U.p1, U.p2); break;
        case 28: col = fHolographicGlass(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 29: col = fPhotonTrails(src, uv, srcTex, texSampler, U.time, U.p0, U.p1, U.p2); break;
        case 30: col = fNeuralGrid(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        case 31: col = fDogpatchPro(src, uv, srcTex, texSampler, U.resolution, U.time, U.p0, U.p1, U.p2); break;
        default: col = src; break;
    }

    // Optional second-stage colour grade — pure per-pixel, fed the result of
    // the primary filter. Only the colour filters are valid here.
    switch (U.filterIdx2) {
        case 1:  col = fKodak(col, U.p0b, U.p1b, U.p2b); break;
        case 2:  col = fVintage(col, uv, U.p0b, U.p1b); break;
        case 3:  col = fRetro(col, uv, U.p0b, U.p1b, U.p2b); break;
        case 8:  col = fCinematic(col, U.p0b, U.p1b, U.p2b); break;
        case 9:  col = fCoolBlue(col, U.p0b, U.p1b); break;
        case 13: col = fMatrix(col, uv, U.time, U.p0b, U.p1b); break;
        case 15: col = fThermal(col, U.p0b); break;
        default: break;
    }

    if (U.lutMix > 0.001) {
        float3 sampled = lutTex.sample(lutSampler, saturate(col)).rgb;
        col = mix(col, sampled, U.lutMix);
    }
    return float4(col, 1.0);
}
