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
        default: col = src; break;
    }

    if (U.lutMix > 0.001) {
        float3 sampled = lutTex.sample(lutSampler, saturate(col)).rgb;
        col = mix(col, sampled, U.lutMix);
    }
    return float4(col, 1.0);
}
