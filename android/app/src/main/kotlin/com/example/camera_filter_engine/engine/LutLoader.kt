package com.example.camera_filter_engine.engine

import android.content.Context
import android.opengl.GLES30
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Loads a .cube LUT file (3D LUT) into a GL_TEXTURE_3D, returning the texture id.
 * Supports the standard Adobe .cube format with LUT_3D_SIZE up to 64.
 * Path can be either an absolute filesystem path or an asset key under assets/.
 */
object LutLoader {
    fun load(ctx: Context, path: String): Int {
        val raw: String = if (File(path).exists()) {
            File(path).readText()
        } else {
            runCatching { ctx.assets.open(path).bufferedReader().use { it.readText() } }
                .getOrElse { return 0 }
        }
        val size = parseSize(raw) ?: return 0
        val values = parseEntries(raw, size) ?: return 0

        val bytes = ByteBuffer.allocateDirect(values.size).order(ByteOrder.nativeOrder())
        bytes.put(values)
        bytes.rewind()

        val tex = IntArray(1)
        GLES30.glGenTextures(1, tex, 0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, tex[0])
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_3D, GLES30.GL_TEXTURE_WRAP_R, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage3D(
            GLES30.GL_TEXTURE_3D, 0, GLES30.GL_RGB8,
            size, size, size, 0,
            GLES30.GL_RGB, GLES30.GL_UNSIGNED_BYTE, bytes,
        )
        return tex[0]
    }

    private fun parseSize(text: String): Int? {
        val m = Regex("(?m)^\\s*LUT_3D_SIZE\\s+(\\d+)").find(text) ?: return null
        return m.groupValues[1].toInt()
    }

    private fun parseEntries(text: String, size: Int): ByteArray? {
        val expected = size * size * size
        val out = ByteArray(expected * 3)
        var i = 0
        for (line in text.lineSequence()) {
            val s = line.trim()
            if (s.isEmpty() || s.startsWith("#") || s.startsWith("TITLE") ||
                s.startsWith("LUT_3D_SIZE") || s.startsWith("DOMAIN_")) continue
            val parts = s.split(Regex("\\s+"))
            if (parts.size < 3) continue
            val r = parts[0].toFloatOrNull() ?: continue
            val g = parts[1].toFloatOrNull() ?: continue
            val b = parts[2].toFloatOrNull() ?: continue
            out[i * 3 + 0] = (r.coerceIn(0f, 1f) * 255f).toInt().toByte()
            out[i * 3 + 1] = (g.coerceIn(0f, 1f) * 255f).toInt().toByte()
            out[i * 3 + 2] = (b.coerceIn(0f, 1f) * 255f).toInt().toByte()
            i++
            if (i == expected) break
        }
        if (i != expected) return null
        return out
    }
}
