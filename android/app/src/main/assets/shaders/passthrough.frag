#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp samplerExternalOES;

// Plain pass-through sampler for the OES camera-style texture. Used by the
// video-crop pipeline so we don't drag along filter.frag's LUT sampler3D
// uniform (which causes green-screen output on some Adreno drivers when no
// 3D LUT is bound).
uniform samplerExternalOES uTex;
in vec2 vTex;
out vec4 fragColor;

void main() {
    fragColor = vec4(texture(uTex, vTex).rgb, 1.0);
}
