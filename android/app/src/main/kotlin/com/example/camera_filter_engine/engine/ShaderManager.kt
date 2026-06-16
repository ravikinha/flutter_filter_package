package com.example.camera_filter_engine.engine

import android.content.Context
import android.opengl.GLES30

object ShaderManager {
    fun readAsset(ctx: Context, name: String): String =
        ctx.assets.open(name).bufferedReader().use { it.readText() }

    fun buildProgram(vsSrc: String, fsSrc: String): Int {
        val vs = compile(GLES30.GL_VERTEX_SHADER, vsSrc)
        val fs = compile(GLES30.GL_FRAGMENT_SHADER, fsSrc)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)
        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        check(status[0] != 0) {
            val log = GLES30.glGetProgramInfoLog(program)
            GLES30.glDeleteProgram(program)
            "Program link failed: $log"
        }
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        return program
    }

    private fun compile(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        check(status[0] != 0) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            "Shader compile failed: $log\n$src"
        }
        return shader
    }
}
