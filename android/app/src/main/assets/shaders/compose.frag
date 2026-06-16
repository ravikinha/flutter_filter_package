#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
precision highp sampler2D;
precision highp samplerExternalOES;

uniform samplerExternalOES uTex;
uniform sampler2D uOverlay;

in vec2 vSrcTex;
in vec2 vOvTex;
out vec4 fragColor;

void main() {
    vec3 src = texture(uTex, vSrcTex).rgb;
    vec4 ov = texture(uOverlay, vOvTex);
    // Premultiplied source-over: out = src*(1-a) + ov.rgb*a
    fragColor = vec4(src * (1.0 - ov.a) + ov.rgb * ov.a, 1.0);
}
