package com.example.camera_filter_engine.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns the EGL context and runs the render loop on a dedicated thread.
 *
 *   Camera OES SurfaceTexture  ──▶  filter.frag (sampling samplerExternalOES)
 *                                       │
 *           ┌───────────────────────────┼───────────────────────────┐
 *           ▼                           ▼                           ▼
 *      Flutter Surface             Recorder Surface (opt)      Snapshot FBO
 *
 * Each downstream surface gets its own EGLSurface; the same draw call is
 * blitted to whichever surfaces are currently attached, so adding/removing
 * the recorder is zero-cost in the steady state.
 */
class GLRenderer(
    private val context: Context,
    private val outputSurface: Surface,
    private val outputWidth: Int,
    private val outputHeight: Int,
) {
    companion object {
        private const val TAG = "GLRenderer"
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private val POS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val TEX = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
        val FSQ_POS: FloatBuffer = ByteBuffer.allocateDirect(POS.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(POS).apply { rewind() }
        val FSQ_TEX: FloatBuffer = ByteBuffer.allocateDirect(TEX.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(TEX).apply { rewind() }
    }

    var onCameraTextureReady: ((SurfaceTexture) -> Unit)? = null
    var onFrameRendered: (() -> Unit)? = null
    var cameraSurfaceTexture: SurfaceTexture? = null
        private set

    private val thread = HandlerThread("CFE-GL")
    private lateinit var handler: Handler

    private var eglDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var eglSurfaceOut = EGL14.EGL_NO_SURFACE
    private var eglSurfaceRec = EGL14.EGL_NO_SURFACE
    private var recorderSurface: Surface? = null
    private var recorderWidth = 0
    private var recorderHeight = 0

    private var oesTextureId = 0
    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uTexLoc = 0
    private var uLutLoc = 0
    private var uLutMixLoc = 0
    private var uTexMatrixLoc = 0
    private var uTimeLoc = 0
    private var uResolutionLoc = 0
    private var uFilterLoc = 0
    private var uP0Loc = 0
    private var uP1Loc = 0
    private var uP2Loc = 0
    private var uFilter2Loc = 0
    private var uP0bLoc = 0
    private var uP1bLoc = 0
    private var uP2bLoc = 0

    private var lutTextureId = 0
    private var lutMix = 0f

    private val texMatrix = FloatArray(16)
    private val startNanos = System.nanoTime()
    private val frameAvailable = AtomicBoolean(false)
    private var running = false

    // Snapshots are queued so a second request fired before the first frame
    // renders doesn't silently overwrite the first. Each pending entry is
    // drained on the next rendered frame.
    private val snapshotQueue = java.util.concurrent.ConcurrentLinkedQueue<Pair<String, (String) -> Unit>>()

    // current filter state
    private var currentFilterIdx = 0
    private val params = FloatArray(3) // p0, p1, p2

    fun start() {
        thread.start()
        handler = Handler(thread.looper)
        handler.post {
            initEgl()
            initGl()
            scheduleNextFrame()
        }
    }

    fun stop() {
        running = false
        handler.post {
            releaseGl()
            releaseEgl()
            thread.quitSafely()
        }
    }

    fun setFilter(id: String, p: Map<String, Float>?) {
        handler.post {
            currentFilterIdx = filterIdToIndex(id)
            p?.let { applyParams(id, it) }
        }
    }

    fun setParam(key: String, value: Float) {
        handler.post {
            when (key) {
                // p0 — primary intensity / amount
                "warmth", "sepiaStrength", "rgbOffset", "glitchAmount",
                "blurRadius", "tealStrength", "coolness", "glowIntensity",
                "grainIntensity",
                "edgeStrength", "holoIntensity", "matrixGreen",
                "outlineStrength", "heatIntensity", "crtScan", "tapeWear",
                "kaleidoSegments", "auraIntensity", "scanSpeed",
                "chromeIntensity", "glassRefraction", "prismStrength",
                "anamorphicFlare", "dreamLensGlow", "auroraSpeed",
                "rayIntensity", "holoGlassStrength", "trailLength",
                "neuralDensity",
                "dogpatchWarmth" -> params[0] = value
                // p1 — secondary modifier (often scanlines / hue / contrast)
                "contrast", "vignetteStrength", "fade", "scanlineIntensity",
                "distortionAmount", "orangeStrength", "bloomRadius",
                "cyberScan", "holoScan", "matrixStreak", "neonHue",
                "crtChroma", "trackingError", "kaleidoRotation",
                "scannerGlow",
                "chromeReflection", "glassTransparency", "prismRainbow",
                "anamorphicBloom", "dreamLensBloom", "auroraStrength",
                "rayLength", "holoGlassRainbow", "trailBrightness",
                "neuralSpeed",
                "dogpatchBloom" -> params[1] = value
                // p2 — tertiary (overlays / extras)
                "saturation", "lightLeakStrength", "noiseIntensity",
                "gridIntensity", "crtBarrel", "vhsProScan",
                "chromeDistortion", "glassEdge", "prismDispersion",
                "anamorphicGrain", "dreamLensLeak", "auroraGlow",
                "rayBloom", "holoGlassGlow", "trailFade",
                "neuralGlow",
                "dogpatchTexture" -> params[2] = value
            }
        }
    }

    fun setLut(path: String?) {
        handler.post {
            // Always release any existing LUT before loading a new one so that
            // a failed parse can't leak the previous texture and a successful
            // parse can't double-bind.
            if (lutTextureId != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                lutTextureId = 0
            }
            lutMix = 0f
            if (path != null) {
                val tex = LutLoader.load(context, path)
                if (tex != 0) {
                    lutTextureId = tex
                    lutMix = 1f
                }
            }
        }
    }

    fun attachRecorderSurface(surface: Surface, w: Int, h: Int) {
        handler.post {
            recorderSurface = surface
            recorderWidth = w
            recorderHeight = h
            eglSurfaceRec = createWindowSurface(surface, recordable = true)
        }
    }

    fun detachRecorderSurface() {
        handler.post {
            if (eglSurfaceRec != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, eglSurfaceRec)
                eglSurfaceRec = EGL14.EGL_NO_SURFACE
            }
            recorderSurface = null
        }
    }

    fun requestSnapshot() {
        // taken on next render
    }

    fun readPixelsAndSaveJpeg(path: String, cb: (String) -> Unit) {
        snapshotQueue.offer(path to cb)
    }

    // ----------------- EGL/GL setup -------------------------------------

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val ver = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, ver, 0, ver, 1)) { "eglInitialize failed" }

        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val num = IntArray(1)
        check(EGL14.eglChooseConfig(eglDisplay, attribs, 0, cfgs, 0, 1, num, 0) && num[0] > 0) {
            "eglChooseConfig failed"
        }
        eglConfig = cfgs[0]

        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

        eglSurfaceOut = createWindowSurface(outputSurface, recordable = false)
        makeCurrent(eglSurfaceOut)
    }

    private fun createWindowSurface(surface: Surface, recordable: Boolean): EGLSurface {
        // EGL_RECORDABLE_ANDROID is a *config* attribute, not a *surface* attribute.
        // It was already requested in initEgl(), so every window surface from this
        // config inherits it. Passing it here makes Adreno drivers reject the call.
        val attribs = intArrayOf(EGL14.EGL_NONE)
        val s = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, attribs, 0)
        check(s != EGL14.EGL_NO_SURFACE) {
            "eglCreateWindowSurface failed (error=0x${Integer.toHexString(EGL14.eglGetError())})"
        }
        return s
    }

    private fun makeCurrent(surface: EGLSurface) {
        EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)
    }

    private fun initGl() {
        // OES camera texture
        val tex = IntArray(1)
        GLES30.glGenTextures(1, tex, 0)
        oesTextureId = tex[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR.toFloat())
        GLES30.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR.toFloat())
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        cameraSurfaceTexture = SurfaceTexture(oesTextureId).also {
            it.setOnFrameAvailableListener { frameAvailable.set(true) }
        }
        onCameraTextureReady?.invoke(cameraSurfaceTexture!!)

        // shaders
        val vsSrc = ShaderManager.readAsset(context, "shaders/oes.vert")
        val fsSrc = ShaderManager.readAsset(context, "shaders/filter.frag")
        program = ShaderManager.buildProgram(vsSrc, fsSrc)
        aPositionLoc = GLES30.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES30.glGetAttribLocation(program, "aTexCoord")
        uTexLoc = GLES30.glGetUniformLocation(program, "uTex")
        uLutLoc = GLES30.glGetUniformLocation(program, "uLut")
        uLutMixLoc = GLES30.glGetUniformLocation(program, "uLutMix")
        uTexMatrixLoc = GLES30.glGetUniformLocation(program, "uTexMatrix")
        uTimeLoc = GLES30.glGetUniformLocation(program, "uTime")
        uResolutionLoc = GLES30.glGetUniformLocation(program, "uResolution")
        uFilterLoc = GLES30.glGetUniformLocation(program, "uFilter")
        uP0Loc = GLES30.glGetUniformLocation(program, "uP0")
        uP1Loc = GLES30.glGetUniformLocation(program, "uP1")
        uP2Loc = GLES30.glGetUniformLocation(program, "uP2")
        uFilter2Loc = GLES30.glGetUniformLocation(program, "uFilter2")
        uP0bLoc = GLES30.glGetUniformLocation(program, "uP0b")
        uP1bLoc = GLES30.glGetUniformLocation(program, "uP1b")
        uP2bLoc = GLES30.glGetUniformLocation(program, "uP2b")

        running = true
    }

    private fun releaseGl() {
        if (program != 0) GLES30.glDeleteProgram(program)
        if (oesTextureId != 0) GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
        if (lutTextureId != 0) GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
        cameraSurfaceTexture?.release()
        cameraSurfaceTexture = null
    }

    private fun releaseEgl() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurfaceOut != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurfaceOut)
            if (eglSurfaceRec != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurfaceRec)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurfaceOut = EGL14.EGL_NO_SURFACE
    }

    // ----------------- render loop --------------------------------------

    private fun scheduleNextFrame() {
        if (!running) return
        handler.post {
            try {
                if (frameAvailable.compareAndSet(true, false)) {
                    cameraSurfaceTexture?.updateTexImage()
                    cameraSurfaceTexture?.getTransformMatrix(texMatrix)
                    drawTo(eglSurfaceOut, outputWidth, outputHeight, presentationTimeNs = -1L)
                    if (eglSurfaceRec != EGL14.EGL_NO_SURFACE) {
                        drawTo(
                            eglSurfaceRec, recorderWidth, recorderHeight,
                            presentationTimeNs = cameraSurfaceTexture!!.timestamp,
                        )
                    }
                    onFrameRendered?.invoke()
                    // Drain any pending snapshot requests against this frame.
                    while (true) {
                        val req = snapshotQueue.poll() ?: break
                        savePixelsAsJpeg(req.first, outputWidth, outputHeight)
                        req.second(req.first)
                    }
                }
            } catch (e: Throwable) {
                Log.e(TAG, "render error", e)
            }
            scheduleNextFrame()
        }
    }

    private fun drawTo(surface: EGLSurface, w: Int, h: Int, presentationTimeNs: Long) {
        makeCurrent(surface)
        GLES30.glViewport(0, 0, w, h)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        GLES30.glUseProgram(program)
        // OES sampler bound to unit 0
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glUniform1i(uTexLoc, 0)
        // LUT bound to unit 1 (even if unused)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        if (lutTextureId != 0) {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTextureId)
        }
        GLES30.glUniform1i(uLutLoc, 1)
        GLES30.glUniform1f(uLutMixLoc, lutMix)

        GLES30.glUniformMatrix4fv(uTexMatrixLoc, 1, false, texMatrix, 0)
        val tSec = (System.nanoTime() - startNanos) / 1e9f
        GLES30.glUniform1f(uTimeLoc, tSec)
        GLES30.glUniform2f(uResolutionLoc, w.toFloat(), h.toFloat())
        GLES30.glUniform1i(uFilterLoc, currentFilterIdx)
        GLES30.glUniform1f(uP0Loc, params[0])
        GLES30.glUniform1f(uP1Loc, params[1])
        GLES30.glUniform1f(uP2Loc, params[2])
        // Live camera path uses a single filter — no second-stage grade.
        GLES30.glUniform1i(uFilter2Loc, 0)
        GLES30.glUniform1f(uP0bLoc, 0f)
        GLES30.glUniform1f(uP1bLoc, 0f)
        GLES30.glUniform1f(uP2bLoc, 0f)

        // fullscreen quad
        GLES30.glEnableVertexAttribArray(aPositionLoc)
        GLES30.glVertexAttribPointer(aPositionLoc, 2, GLES30.GL_FLOAT, false, 0, FSQ_POS)
        GLES30.glEnableVertexAttribArray(aTexCoordLoc)
        GLES30.glVertexAttribPointer(aTexCoordLoc, 2, GLES30.GL_FLOAT, false, 0, FSQ_TEX)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glDisableVertexAttribArray(aPositionLoc)
        GLES30.glDisableVertexAttribArray(aTexCoordLoc)

        if (presentationTimeNs > 0) {
            EGLExt.eglPresentationTimeANDROID(eglDisplay, surface, presentationTimeNs)
        }
        EGL14.eglSwapBuffers(eglDisplay, surface)
    }

    private fun savePixelsAsJpeg(path: String, w: Int, h: Int) {
        val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf)
        buf.rewind()
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(buf)
        // GL origin is bottom-left; flip vertically for JPEG.
        val matrix = android.graphics.Matrix().apply { postScale(1f, -1f) }
        val flipped = Bitmap.createBitmap(bmp, 0, 0, w, h, matrix, true)
        bmp.recycle()
        File(path).parentFile?.mkdirs()
        FileOutputStream(path).use { os ->
            flipped.compress(Bitmap.CompressFormat.JPEG, 92, os)
        }
        flipped.recycle()
    }

    // ----------------- helpers ------------------------------------------

    private fun applyParams(id: String, p: Map<String, Float>) {
        // Reset slots; map per-filter key to fixed positional uniforms.
        params[0] = 0f; params[1] = 0f; params[2] = 0f
        when (id) {
            "kodak" -> { params[0] = p["warmth"] ?: 0f; params[1] = p["contrast"] ?: 0f; params[2] = p["saturation"] ?: 0f }
            "vintage" -> { params[0] = p["sepiaStrength"] ?: 0f; params[1] = p["vignetteStrength"] ?: 0f }
            "retro" -> { params[0] = p["warmth"] ?: 0f; params[1] = p["fade"] ?: 0f; params[2] = p["lightLeakStrength"] ?: 0f }
            "grain" -> { params[0] = p["grainIntensity"] ?: 0f }
            "vhs" -> { params[0] = p["rgbOffset"] ?: 0f; params[1] = p["scanlineIntensity"] ?: 0f; params[2] = p["noiseIntensity"] ?: 0f }
            "bwGlitch" -> { params[0] = p["glitchAmount"] ?: 0f; params[1] = p["distortionAmount"] ?: 0f }
            "blur" -> { params[0] = p["blurRadius"] ?: 0f }
            "cinematic" -> { params[0] = p["tealStrength"] ?: 0f; params[1] = p["orangeStrength"] ?: 0f; params[2] = p["contrast"] ?: 0f }
            "coolBlue" -> { params[0] = p["coolness"] ?: 0f; params[1] = p["contrast"] ?: 0f }
            "dreamGlow" -> { params[0] = p["glowIntensity"] ?: 0f; params[1] = p["bloomRadius"] ?: 0f }
            "cyberpunkHud" -> {
                params[0] = p["edgeStrength"] ?: 0f
                params[1] = p["cyberScan"] ?: 0f
                params[2] = p["gridIntensity"] ?: 0f
            }
            "hologram" -> {
                params[0] = p["holoIntensity"] ?: 0f
                params[1] = p["holoScan"] ?: 0f
            }
            "matrixVision" -> {
                params[0] = p["matrixGreen"] ?: 0f
                params[1] = p["matrixStreak"] ?: 0f
            }
            "neonOutline" -> {
                params[0] = p["outlineStrength"] ?: 0f
                params[1] = p["neonHue"] ?: 0f
            }
            "thermal" -> { params[0] = p["heatIntensity"] ?: 0f }
            "crtRetro" -> {
                params[0] = p["crtScan"] ?: 0f
                params[1] = p["crtChroma"] ?: 0f
                params[2] = p["crtBarrel"] ?: 0f
            }
            "vhsPro" -> {
                params[0] = p["tapeWear"] ?: 0f
                params[1] = p["trackingError"] ?: 0f
                params[2] = p["vhsProScan"] ?: 0f
            }
            "kaleidoscope" -> {
                params[0] = p["kaleidoSegments"] ?: 0f
                params[1] = p["kaleidoRotation"] ?: 0f
            }
            "electricAura" -> { params[0] = p["auraIntensity"] ?: 0f }
            "scannerVision" -> {
                params[0] = p["scanSpeed"] ?: 0f
                params[1] = p["scannerGlow"] ?: 0f
            }
            "liquidChrome" -> {
                params[0] = p["chromeIntensity"] ?: 0f
                params[1] = p["chromeReflection"] ?: 0f
                params[2] = p["chromeDistortion"] ?: 0f
            }
            "glassMorph" -> {
                params[0] = p["glassRefraction"] ?: 0f
                params[1] = p["glassTransparency"] ?: 0f
                params[2] = p["glassEdge"] ?: 0f
            }
            "prismLens" -> {
                params[0] = p["prismStrength"] ?: 0f
                params[1] = p["prismRainbow"] ?: 0f
                params[2] = p["prismDispersion"] ?: 0f
            }
            "cinematicAnamorphic" -> {
                params[0] = p["anamorphicFlare"] ?: 0f
                params[1] = p["anamorphicBloom"] ?: 0f
                params[2] = p["anamorphicGrain"] ?: 0f
            }
            "dreamLens" -> {
                params[0] = p["dreamLensGlow"] ?: 0f
                params[1] = p["dreamLensBloom"] ?: 0f
                params[2] = p["dreamLensLeak"] ?: 0f
            }
            "aurora" -> {
                params[0] = p["auroraSpeed"] ?: 0f
                params[1] = p["auroraStrength"] ?: 0f
                params[2] = p["auroraGlow"] ?: 0f
            }
            "lightRays" -> {
                params[0] = p["rayIntensity"] ?: 0f
                params[1] = p["rayLength"] ?: 0f
                params[2] = p["rayBloom"] ?: 0f
            }
            "holographicGlass" -> {
                params[0] = p["holoGlassStrength"] ?: 0f
                params[1] = p["holoGlassRainbow"] ?: 0f
                params[2] = p["holoGlassGlow"] ?: 0f
            }
            "photonTrails" -> {
                params[0] = p["trailLength"] ?: 0f
                params[1] = p["trailBrightness"] ?: 0f
                params[2] = p["trailFade"] ?: 0f
            }
            "neuralGrid" -> {
                params[0] = p["neuralDensity"] ?: 0f
                params[1] = p["neuralSpeed"] ?: 0f
                params[2] = p["neuralGlow"] ?: 0f
            }
            "dogpatchPro" -> {
                params[0] = p["dogpatchWarmth"] ?: 0f
                params[1] = p["dogpatchBloom"] ?: 0f
                params[2] = p["dogpatchTexture"] ?: 0f
            }
        }
    }

    private fun filterIdToIndex(id: String) = when (id) {
        "kodak" -> 1; "vintage" -> 2; "retro" -> 3; "grain" -> 4; "vhs" -> 5
        "bwGlitch" -> 6; "blur" -> 7; "cinematic" -> 8; "coolBlue" -> 9
        "dreamGlow" -> 10
        "cyberpunkHud" -> 11; "hologram" -> 12; "matrixVision" -> 13
        "neonOutline" -> 14; "thermal" -> 15; "crtRetro" -> 16
        "vhsPro" -> 17; "kaleidoscope" -> 18; "electricAura" -> 19
        "scannerVision" -> 20
        "liquidChrome" -> 21; "glassMorph" -> 22; "prismLens" -> 23
        "cinematicAnamorphic" -> 24; "dreamLens" -> 25; "aurora" -> 26
        "lightRays" -> 27; "holographicGlass" -> 28; "photonTrails" -> 29
        "neuralGrid" -> 30
        "dogpatchPro" -> 31
        else -> 0
    }

}
