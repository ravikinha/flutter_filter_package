#version 300 es
layout(location = 0) in vec4 aPosition;
layout(location = 1) in vec2 aTexCoord;
uniform mat4 uTexMatrix;
out vec2 vTex;
void main() {
    gl_Position = aPosition;
    vTex = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
}
