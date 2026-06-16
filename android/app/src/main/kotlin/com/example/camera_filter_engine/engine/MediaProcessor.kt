package com.example.camera_filter_engine.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLUtils
import android.os.Build
import android.util.Log
import android.view.Surface
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Standalone GPU-shader pipeline for offline media. Doesn't touch the live
 * camera renderer — its own EGL context is created and torn down per-job.
 *
 *   Image: Bitmap → GL_TEXTURE_2D → filter2d.frag → FBO → JPEG
 *   Video: MediaExtractor → MediaCodec decoder → SurfaceTexture(OES)
 *          → filter.frag (camera-pipeline shader) → MediaCodec encoder Surface
 *          → MediaMuxer (audio track copied through unchanged)
 */
object MediaProcessor {
    private const val TAG = "MediaProcessor"
    private const val EGL_RECORDABLE_ANDROID = 0x3142

    // ---------------- IMAGE ----------------------------------------------

    fun processImage(
        ctx: Context,
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: Map<String, Float>?,
        lutPath: String?,
    ): String {
        val rawBmp = BitmapFactory.decodeFile(inputPath)
            ?: throw IllegalArgumentException("cannot decode $inputPath")
        val bmp = applyExifOrientation(inputPath, rawBmp)
        val w = bmp.width
        val h = bmp.height

        val egl = EglPbuffer(w, h)
        try {
            egl.makeCurrent()

            val program = ShaderManager.buildProgram(
                ShaderManager.readAsset(ctx, "shaders/common.vert"),
                ShaderManager.readAsset(ctx, "shaders/filter2d.frag"),
            )
            val locs = ProgramLocs(program)

            // Source 2D texture
            val srcTex = IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTex)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bmp, 0)
            bmp.recycle()

            // LUT (optional)
            val lutTex = lutPath?.let { LutLoader.load(ctx, it) } ?: 0

            // Render to default pbuffer FBO
            GLES30.glViewport(0, 0, w, h)
            GLES30.glClearColor(0f, 0f, 0f, 1f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            GLES30.glUseProgram(program)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTex)
            GLES30.glUniform1i(locs.uTex, 0)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
            if (lutTex != 0) GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTex)
            GLES30.glUniform1i(locs.uLut, 1)
            GLES30.glUniform1f(locs.uLutMix, if (lutTex != 0) 1f else 0f)
            GLES30.glUniform1f(locs.uTime, 0f)
            GLES30.glUniform2f(locs.uResolution, w.toFloat(), h.toFloat())
            val (filterIdx, p) = mapFilter(filterId, params)
            GLES30.glUniform1i(locs.uFilter, filterIdx)
            GLES30.glUniform1f(locs.uP0, p[0])
            GLES30.glUniform1f(locs.uP1, p[1])
            GLES30.glUniform1f(locs.uP2, p[2])

            GLES30.glEnableVertexAttribArray(locs.aPosition)
            GLES30.glVertexAttribPointer(locs.aPosition, 2, GLES30.GL_FLOAT, false, 0, FSQ_POS)
            GLES30.glEnableVertexAttribArray(locs.aTexCoord)
            // For image processing we want texture Y oriented top-down to match
            // bitmap layout; common.vert just passes UVs through unchanged so
            // we feed flipped Y coords here.
            GLES30.glVertexAttribPointer(locs.aTexCoord, 2, GLES30.GL_FLOAT, false, 0, FSQ_TEX_FLIPY)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

            // Read pixels back
            val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buf)
            buf.rewind()
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            out.copyPixelsFromBuffer(buf)
            // GL framebuffer Y is bottom-up; flip vertically.
            val flipped = Bitmap.createBitmap(out, 0, 0, w, h,
                Matrix().apply { postScale(1f, -1f) }, true)
            out.recycle()

            File(outputPath).parentFile?.mkdirs()
            FileOutputStream(outputPath).use { os ->
                flipped.compress(Bitmap.CompressFormat.JPEG, 92, os)
            }
            flipped.recycle()

            GLES30.glDeleteTextures(1, intArrayOf(srcTex), 0)
            if (lutTex != 0) GLES30.glDeleteTextures(1, intArrayOf(lutTex), 0)
            GLES30.glDeleteProgram(program)
            return outputPath
        } finally {
            egl.release()
        }
    }

    private fun applyExifOrientation(path: String, bmp: Bitmap): Bitmap {
        return try {
            val exif = ExifInterface(path)
            val ori = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
            val matrix = Matrix()
            when (ori) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
                else -> return bmp
            }
            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
            bmp.recycle()
            rotated
        } catch (_: Throwable) { bmp }
    }

    // ---------------- PREVIEW (single frame, shader-accurate) ------------

    /**
     * For images: same as [processImage]. For videos: extract a representative
     * frame near [atSeconds] and run it through the shader, so blur/glitch/
     * grain/scanlines preview the way they will actually look in the export.
     */
    fun previewFilter(
        ctx: Context,
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: Map<String, Float>?,
        lutPath: String?,
        isVideo: Boolean,
        atSeconds: Double,
    ): String {
        if (!isVideo) {
            return processImage(ctx, inputPath, outputPath, filterId, params, lutPath)
        }
        val retriever = MediaMetadataRetriever()
        val bmp: Bitmap = try {
            retriever.setDataSource(inputPath)
            val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val durMs = durStr?.toLongOrNull() ?: 0L
            val timeUs = (atSeconds * 1_000_000.0).toLong()
                .coerceAtLeast(0L)
                .coerceAtMost(durMs * 1000L - 100_000L)
            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: throw IllegalStateException("could not extract frame")
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
        // Write the frame to a temp jpeg next to the output so the existing
        // image pipeline can pick it up via BitmapFactory.
        val tmp = File(outputPath).parentFile?.let {
            File(it, File(outputPath).nameWithoutExtension + ".frame.jpg")
        } ?: File("${outputPath}.frame.jpg")
        try {
            tmp.parentFile?.mkdirs()
            FileOutputStream(tmp).use { os ->
                bmp.compress(Bitmap.CompressFormat.JPEG, 92, os)
            }
            bmp.recycle()
            return processImage(ctx, tmp.absolutePath, outputPath, filterId, params, lutPath)
        } finally {
            try { tmp.delete() } catch (_: Throwable) {}
        }
    }

    // ---------------- VIDEO ----------------------------------------------

    /**
     * Throws [CancelledException] when [cancel] becomes true. Partial output
     * file is removed on cancel so the user never sees a half-rendered video.
     */
    class CancelledException : RuntimeException("processVideo cancelled")

    fun processVideo(
        ctx: Context,
        inputPath: String,
        outputPath: String,
        filterId: String,
        params: Map<String, Float>?,
        lutPath: String?,
        progress: (Float) -> Unit,
        cancel: AtomicBoolean = AtomicBoolean(false),
    ): String {
        File(outputPath).parentFile?.mkdirs()
        File(outputPath).takeIf { it.exists() }?.delete()

        // Probe the input video & audio tracks.
        val probeEx = MediaExtractor().apply { setDataSource(inputPath) }
        var videoIdx = -1; var audioIdx = -1
        var videoFormat: MediaFormat? = null
        var audioFormat: MediaFormat? = null
        for (i in 0 until probeEx.trackCount) {
            val f = probeEx.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (videoIdx < 0 && mime.startsWith("video/")) { videoIdx = i; videoFormat = f }
            else if (audioIdx < 0 && mime.startsWith("audio/")) { audioIdx = i; audioFormat = f }
        }
        val vf = videoFormat ?: throw IllegalArgumentException("no video track")
        val sourceW = vf.getInteger(MediaFormat.KEY_WIDTH)
        val sourceH = vf.getInteger(MediaFormat.KEY_HEIGHT)
        val durationUs = if (vf.containsKey(MediaFormat.KEY_DURATION))
            vf.getLong(MediaFormat.KEY_DURATION) else 1L
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                            vf.containsKey(MediaFormat.KEY_ROTATION)) {
            vf.getInteger(MediaFormat.KEY_ROTATION)
        } else 0
        probeEx.release()

        // Don't transform orientation at all. Encode at the source's raw
        // buffer size and carry its rotation flag straight through to the
        // output file (see muxer.setOrientationHint below). This is how the
        // stock Android camera app records video — landscape buffer with a
        // rotation hint that the player applies on playback — and means the
        // filter's job is purely "apply pixels", never "rotate pixels".
        val outW = sourceW
        val outH = sourceH

        // Encoder + input Surface
        val outFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder.configure(outFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val encoderInputSurface = encoder.createInputSurface()
        encoder.start()

        // EGL on encoder surface
        val egl = EglWindow(encoderInputSurface, recordable = true)
        egl.makeCurrent()

        // OES texture + SurfaceTexture for decoder output
        val oesTex = IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES30.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR.toFloat())
        GLES30.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR.toFloat())
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        val surfaceTexture = SurfaceTexture(oesTex).apply { setDefaultBufferSize(sourceW, sourceH) }
        val decoderOutputSurface = Surface(surfaceTexture)
        // Pair the flag with a monitor so we can wait without spin-sleeping.
        // Updating both happens under the same lock so we never miss a signal
        // that arrives between the test and the wait.
        val frameAvailable = AtomicBoolean(false)
        val frameLock = Object()
        surfaceTexture.setOnFrameAvailableListener {
            synchronized(frameLock) {
                frameAvailable.set(true)
                frameLock.notifyAll()
            }
        }

        // Reuse the camera-pipeline OES shader (oes.vert + filter.frag). Its
        // texture matrix is fed from the SurfaceTexture after each frame and
        // already handles flipping/rotation correctly.
        val program = ShaderManager.buildProgram(
            ShaderManager.readAsset(ctx, "shaders/oes.vert"),
            ShaderManager.readAsset(ctx, "shaders/filter.frag"),
        )
        val locs = ProgramLocs(program, hasTexMatrix = true)
        val lutTex = lutPath?.let { LutLoader.load(ctx, it) } ?: 0

        val texMatrix = FloatArray(16)
        // No UV-space rotation. Whatever the SurfaceTexture's natural
        // transform matrix says is what the shader samples.

        // Decoder
        val extractor = MediaExtractor().apply {
            setDataSource(inputPath)
            selectTrack(videoIdx)
        }
        val decoder = MediaCodec.createDecoderByType(vf.getString(MediaFormat.KEY_MIME)!!)
        decoder.configure(vf, decoderOutputSurface, null, 0)
        decoder.start()

        // Muxer — copy the source's rotation flag to the output. Must be set
        // before muxer.start(); MediaMuxer encodes it into the MP4's track
        // header matrix and every Android player honours it on playback.
        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        if (rotation != 0) muxer.setOrientationHint(rotation)
        var videoMuxIdx = -1
        var muxerStarted = false

        var inputDone = false
        var encodeDone = false
        val bi = MediaCodec.BufferInfo()
        val startNanos = System.nanoTime()

        try {
            while (!encodeDone) {
                if (cancel.get()) throw CancelledException()
                // 1. Feed decoder
                if (!inputDone) {
                    val inIdx = decoder.dequeueInputBuffer(10_000L)
                    if (inIdx >= 0) {
                        val inBuf = decoder.getInputBuffer(inIdx)!!
                        val sz = extractor.readSampleData(inBuf, 0)
                        if (sz < 0) {
                            decoder.queueInputBuffer(inIdx, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val pts = extractor.sampleTime
                            decoder.queueInputBuffer(inIdx, 0, sz, pts, 0)
                            extractor.advance()
                        }
                    }
                }

                // 2. Drain decoder → push to OES surface → render
                var decoderDone = false
                drainDecoder@ while (true) {
                    val outIdx = decoder.dequeueOutputBuffer(bi, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> break@drainDecoder
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue@drainDecoder
                        outIdx >= 0 -> {
                            val render = bi.size != 0
                            decoder.releaseOutputBuffer(outIdx, render)
                            if (render) {
                                awaitFrame(frameAvailable, frameLock)
                                surfaceTexture.updateTexImage()
                                surfaceTexture.getTransformMatrix(texMatrix)
                                // No further transform — feed the texMatrix
                                // through unchanged.

                                drawFrame(
                                    program, locs, oesTex, lutTex,
                                    outW, outH,
                                    timeSec = (System.nanoTime() - startNanos) / 1e9f,
                                    filterId, params, texMatrix,
                                )
                                egl.setPresentationTime(bi.presentationTimeUs * 1000)
                                egl.swapBuffers()
                                val p = (bi.presentationTimeUs.toFloat() /
                                        durationUs.toFloat()).coerceIn(0f, 1f)
                                progress(p)
                            }
                            if ((bi.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                decoderDone = true
                                encoder.signalEndOfInputStream()
                                break@drainDecoder
                            }
                        }
                    }
                }

                // 3. Drain encoder
                drainEnc@ while (true) {
                    val outIdx = encoder.dequeueOutputBuffer(bi, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> break@drainEnc
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            check(!muxerStarted) { "format changed twice" }
                            videoMuxIdx = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                        outIdx >= 0 -> {
                            val buf = encoder.getOutputBuffer(outIdx)!!
                            if ((bi.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                bi.size = 0
                            }
                            if (bi.size > 0 && muxerStarted) {
                                buf.position(bi.offset)
                                buf.limit(bi.offset + bi.size)
                                muxer.writeSampleData(videoMuxIdx, buf, bi)
                            }
                            encoder.releaseOutputBuffer(outIdx, false)
                            if ((bi.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                encodeDone = true
                                break@drainEnc
                            }
                        }
                    }
                }
                if (decoderDone && !inputDone) break
            }
        } finally {
            val wasCancelled = cancel.get()
            try { decoder.stop() } catch (_: Throwable) {}
            try { decoder.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}

            // Skip audio passthrough on cancel — the muxer's video track is
            // mid-stream and writing more samples now would just produce a
            // larger broken file we're about to delete.
            if (!wasCancelled && muxerStarted && audioIdx >= 0 && audioFormat != null) {
                try { passthroughAudio(inputPath, audioIdx, audioFormat!!, muxer) }
                catch (t: Throwable) { Log.w(TAG, "audio passthrough failed", t) }
            }

            try { encoder.stop() } catch (_: Throwable) {}
            try { encoder.release() } catch (_: Throwable) {}
            if (muxerStarted) { try { muxer.stop() } catch (_: Throwable) {} }
            try { muxer.release() } catch (_: Throwable) {}
            try { GLES30.glDeleteTextures(1, intArrayOf(oesTex), 0) } catch (_: Throwable) {}
            if (lutTex != 0) GLES30.glDeleteTextures(1, intArrayOf(lutTex), 0)
            try { GLES30.glDeleteProgram(program) } catch (_: Throwable) {}
            surfaceTexture.release()
            decoderOutputSurface.release()
            encoderInputSurface.release()
            egl.release()
            if (wasCancelled) {
                try { File(outputPath).delete() } catch (_: Throwable) {}
            }
        }
        if (cancel.get()) throw CancelledException()
        progress(1f)
        return outputPath
    }

    private fun passthroughAudio(
        inputPath: String,
        audioIdx: Int,
        audioFormat: MediaFormat,
        muxer: MediaMuxer,
    ) {
        val ex = MediaExtractor().apply {
            setDataSource(inputPath)
            selectTrack(audioIdx)
        }
        try {
            val muxAudio = muxer.addTrack(audioFormat)
            val bufSize = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            else 256 * 1024
            val buf = ByteBuffer.allocate(bufSize)
            val bi = MediaCodec.BufferInfo()
            while (true) {
                buf.clear()
                val sz = ex.readSampleData(buf, 0)
                if (sz < 0) break
                bi.offset = 0
                bi.size = sz
                bi.presentationTimeUs = ex.sampleTime
                bi.flags = ex.sampleFlags
                muxer.writeSampleData(muxAudio, buf, bi)
                ex.advance()
            }
        } finally {
            ex.release()
        }
    }

    private fun awaitFrame(flag: AtomicBoolean, lock: Object, timeoutMs: Long = 2000) {
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (!flag.get()) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                try { (lock as java.lang.Object).wait(remaining) }
                catch (_: InterruptedException) { Thread.currentThread().interrupt(); break }
            }
            flag.set(false)
        }
    }

    private fun drawFrame(
        program: Int, locs: ProgramLocs,
        oesTex: Int, lutTex: Int,
        w: Int, h: Int,
        timeSec: Float,
        filterId: String, params: Map<String, Float>?,
        texMatrix: FloatArray,
    ) {
        GLES30.glViewport(0, 0, w, h)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glUseProgram(program)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES30.glUniform1i(locs.uTex, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        if (lutTex != 0) GLES30.glBindTexture(GLES30.GL_TEXTURE_3D, lutTex)
        GLES30.glUniform1i(locs.uLut, 1)
        GLES30.glUniform1f(locs.uLutMix, if (lutTex != 0) 1f else 0f)
        if (locs.uTexMatrix >= 0) {
            GLES30.glUniformMatrix4fv(locs.uTexMatrix, 1, false, texMatrix, 0)
        }
        GLES30.glUniform1f(locs.uTime, timeSec)
        GLES30.glUniform2f(locs.uResolution, w.toFloat(), h.toFloat())
        val (idx, p) = mapFilter(filterId, params)
        GLES30.glUniform1i(locs.uFilter, idx)
        GLES30.glUniform1f(locs.uP0, p[0])
        GLES30.glUniform1f(locs.uP1, p[1])
        GLES30.glUniform1f(locs.uP2, p[2])

        GLES30.glEnableVertexAttribArray(locs.aPosition)
        GLES30.glVertexAttribPointer(locs.aPosition, 2, GLES30.GL_FLOAT, false, 0, FSQ_POS)
        GLES30.glEnableVertexAttribArray(locs.aTexCoord)
        GLES30.glVertexAttribPointer(locs.aTexCoord, 2, GLES30.GL_FLOAT, false, 0, FSQ_TEX)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
    }

    // ---------------- shared utilities -----------------------------------

    private class ProgramLocs(program: Int, hasTexMatrix: Boolean = false) {
        val aPosition = GLES30.glGetAttribLocation(program, "aPosition")
        val aTexCoord = GLES30.glGetAttribLocation(program, "aTexCoord")
        val uTex = GLES30.glGetUniformLocation(program, "uTex")
        val uLut = GLES30.glGetUniformLocation(program, "uLut")
        val uLutMix = GLES30.glGetUniformLocation(program, "uLutMix")
        val uTime = GLES30.glGetUniformLocation(program, "uTime")
        val uResolution = GLES30.glGetUniformLocation(program, "uResolution")
        val uFilter = GLES30.glGetUniformLocation(program, "uFilter")
        val uP0 = GLES30.glGetUniformLocation(program, "uP0")
        val uP1 = GLES30.glGetUniformLocation(program, "uP1")
        val uP2 = GLES30.glGetUniformLocation(program, "uP2")
        val uTexMatrix = if (hasTexMatrix) GLES30.glGetUniformLocation(program, "uTexMatrix") else -1
    }

    private fun mapFilter(id: String, p: Map<String, Float>?): Pair<Int, FloatArray> {
        val out = FloatArray(3)
        val params = p ?: emptyMap()
        when (id) {
            "kodak" -> { out[0] = params["warmth"] ?: 0f; out[1] = params["contrast"] ?: 0f; out[2] = params["saturation"] ?: 0f }
            "vintage" -> { out[0] = params["sepiaStrength"] ?: 0f; out[1] = params["vignetteStrength"] ?: 0f }
            "retro" -> { out[0] = params["warmth"] ?: 0f; out[1] = params["fade"] ?: 0f; out[2] = params["lightLeakStrength"] ?: 0f }
            "grain" -> { out[0] = params["grainIntensity"] ?: 0f }
            "vhs" -> { out[0] = params["rgbOffset"] ?: 0f; out[1] = params["scanlineIntensity"] ?: 0f; out[2] = params["noiseIntensity"] ?: 0f }
            "bwGlitch" -> { out[0] = params["glitchAmount"] ?: 0f; out[1] = params["distortionAmount"] ?: 0f }
            "blur" -> { out[0] = params["blurRadius"] ?: 0f }
            "cinematic" -> { out[0] = params["tealStrength"] ?: 0f; out[1] = params["orangeStrength"] ?: 0f; out[2] = params["contrast"] ?: 0f }
            "coolBlue" -> { out[0] = params["coolness"] ?: 0f; out[1] = params["contrast"] ?: 0f }
            "dreamGlow" -> { out[0] = params["glowIntensity"] ?: 0f; out[1] = params["bloomRadius"] ?: 0f }
        }
        val idx = when (id) {
            "kodak" -> 1; "vintage" -> 2; "retro" -> 3; "grain" -> 4; "vhs" -> 5
            "bwGlitch" -> 6; "blur" -> 7; "cinematic" -> 8; "coolBlue" -> 9
            "dreamGlow" -> 10; else -> 0
        }
        return idx to out
    }

    /**
     * Builds a 4×4 column-major matrix that maps an output-quad UV (u,v) to
     * the corresponding *source-texture* UV after applying the MP4 rotation
     * flag's display rotation. Composed with the SurfaceTexture's own
     * transform matrix so the shader sees the final, upright sampling coord.
     *
     * Forward (source → displayed) and the inverse we feed to the shader:
     *   90°  CW :  src(x,y) ends at (y, 1-x)        => src = (1-v, u)
     *   180°    :  src(x,y) ends at (1-x, 1-y)      => src = (1-u, 1-v)
     *   270° CW :  src(x,y) ends at (1-y, x)        => src = (v, 1-u)
     */
    private fun uvRotationMatrix(deg: Int): FloatArray {
        val m = FloatArray(16)
        android.opengl.Matrix.setIdentityM(m, 0)
        when (deg) {
            90 -> {
                // M * (u,v,0,1) = (1-v, u, 0, 1)
                // col0=(0,1,0,0)  col1=(-1,0,0,0)  col3=(1,0,0,1)
                m[0] = 0f;  m[1] = 1f;  m[2] = 0f; m[3] = 0f
                m[4] = -1f; m[5] = 0f;  m[6] = 0f; m[7] = 0f
                m[8] = 0f;  m[9] = 0f;  m[10] = 1f; m[11] = 0f
                m[12] = 1f; m[13] = 0f; m[14] = 0f; m[15] = 1f
            }
            180 -> {
                // M * (u,v,0,1) = (1-u, 1-v, 0, 1)
                m[0] = -1f; m[1] = 0f;  m[2] = 0f; m[3] = 0f
                m[4] = 0f;  m[5] = -1f; m[6] = 0f; m[7] = 0f
                m[8] = 0f;  m[9] = 0f;  m[10] = 1f; m[11] = 0f
                m[12] = 1f; m[13] = 1f; m[14] = 0f; m[15] = 1f
            }
            270 -> {
                // M * (u,v,0,1) = (v, 1-u, 0, 1)
                // col0=(0,-1,0,0)  col1=(1,0,0,0)  col3=(0,1,0,1)
                m[0] = 0f;  m[1] = -1f; m[2] = 0f; m[3] = 0f
                m[4] = 1f;  m[5] = 0f;  m[6] = 0f; m[7] = 0f
                m[8] = 0f;  m[9] = 0f;  m[10] = 1f; m[11] = 0f
                m[12] = 0f; m[13] = 1f; m[14] = 0f; m[15] = 1f
            }
        }
        return m
    }

    private fun multiply(a: FloatArray, b: FloatArray) {
        val out = FloatArray(16)
        android.opengl.Matrix.multiplyMM(out, 0, a, 0, b, 0)
        System.arraycopy(out, 0, a, 0, 16)
    }

    // ---------------- EGL helpers ---------------------------------------

    private val POS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val TEX = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
    private val TEX_FLIP_Y = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
    private val FSQ_POS: FloatBuffer = ByteBuffer.allocateDirect(POS.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(POS).apply { rewind() }
    private val FSQ_TEX: FloatBuffer = ByteBuffer.allocateDirect(TEX.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(TEX).apply { rewind() }
    private val FSQ_TEX_FLIPY: FloatBuffer = ByteBuffer.allocateDirect(TEX_FLIP_Y.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(TEX_FLIP_Y).apply { rewind() }

    /** Offscreen EGL context backed by a pbuffer (for image processing). */
    private class EglPbuffer(width: Int, height: Int) {
        val display: EGLDisplay
        val context: EGLContext
        val surface: EGLSurface
        init {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val ver = IntArray(2)
            check(EGL14.eglInitialize(display, ver, 0, ver, 1))
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_NONE
            )
            val cfgs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            check(EGL14.eglChooseConfig(display, attribs, 0, cfgs, 0, 1, n, 0) && n[0] > 0)
            val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(display, cfgs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            val pAttribs = intArrayOf(
                EGL14.EGL_WIDTH, width, EGL14.EGL_HEIGHT, height, EGL14.EGL_NONE
            )
            surface = EGL14.eglCreatePbufferSurface(display, cfgs[0], pAttribs, 0)
        }
        fun makeCurrent() {
            EGL14.eglMakeCurrent(display, surface, surface, context)
        }
        fun release() {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }

    /** EGL window surface bound to an Android Surface (for encoder input). */
    private class EglWindow(target: Surface, recordable: Boolean) {
        val display: EGLDisplay
        val context: EGLContext
        val surface: EGLSurface
        init {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val ver = IntArray(2)
            check(EGL14.eglInitialize(display, ver, 0, ver, 1))
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE
            )
            val cfgs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            check(EGL14.eglChooseConfig(display, attribs, 0, cfgs, 0, 1, n, 0) && n[0] > 0)
            val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(display, cfgs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            // EGL_RECORDABLE_ANDROID is a config attribute (already set above),
            // not a surface attribute — Adreno rejects it in the surface list.
            val sAttribs = intArrayOf(EGL14.EGL_NONE)
            surface = EGL14.eglCreateWindowSurface(display, cfgs[0], target, sAttribs, 0)
            check(surface != EGL14.EGL_NO_SURFACE) {
                "eglCreateWindowSurface failed (0x${Integer.toHexString(EGL14.eglGetError())})"
            }
        }
        fun makeCurrent() {
            EGL14.eglMakeCurrent(display, surface, surface, context)
        }
        fun setPresentationTime(ns: Long) {
            EGLExt.eglPresentationTimeANDROID(display, surface, ns)
        }
        fun swapBuffers() {
            EGL14.eglSwapBuffers(display, surface)
        }
        fun release() {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }
}
