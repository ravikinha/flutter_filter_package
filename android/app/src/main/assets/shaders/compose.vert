#version 300 es
// Emits two UV varyings so the fragment shader can sample:
//   - the source camera-style OES texture with its natural transform applied
//   - the 2D overlay texture in straight 0..1 of the encoder buffer
layout(location = 0) in vec4 aPosition;
layout(location = 1) in vec2 aTexCoord;
uniform mat4 uTexMatrix;
out vec2 vSrcTex;
out vec2 vOvTex;
void main() {
    gl_Position = aPosition;
    vSrcTex = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
    // Overlay PNG is image-Y-down but the encoder Surface reads GL's Y-up
    // framebuffer; flip Y so the overlay's top-left lands on the encoded
    // video's top-left.
    vOvTex = vec2(aTexCoord.x, 1.0 - aTexCoord.y);
}
