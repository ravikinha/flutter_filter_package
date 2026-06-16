package com.example.camera_filter_engine.engine

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer

/**
 * Encodes the filtered GL output to an H.264 MP4 file.
 * The recorder owns a MediaCodec surface input which the GL renderer draws into.
 */
class VideoRecorder(
    private val width: Int,
    private val height: Int,
    private val outputPath: String,
    private val bitrateBps: Int = 6_000_000,
    private val frameRate: Int = 30,
    private val iFrameIntervalSec: Int = 1,
) {
    companion object { private const val TAG = "VideoRecorder" }

    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var trackIndex = -1
    private var inputSurface: Surface? = null
    private val bufferInfo = MediaCodec.BufferInfo()

    fun start(onSurfaceReady: (Surface) -> Unit) {
        File(outputPath).parentFile?.mkdirs()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameIntervalSec)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = enc.createInputSurface()
        enc.start()
        encoder = enc

        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        onSurfaceReady(inputSurface!!)
    }

    /** Called on the GL thread after each filtered frame is presented to the recorder surface. */
    fun onFrameAvailable() {
        drainEncoder(endOfStream = false)
    }

    fun stop(): String {
        try {
            drainEncoder(endOfStream = true)
        } catch (_: Throwable) {}
        try { encoder?.stop() } catch (_: Throwable) {}
        try { encoder?.release() } catch (_: Throwable) {}
        encoder = null
        if (muxerStarted) {
            try { muxer?.stop() } catch (_: Throwable) {}
        }
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        inputSurface?.release()
        inputSurface = null
        return outputPath
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        if (endOfStream) {
            enc.signalEndOfInputStream()
        }
        while (true) {
            val outIdx = enc.dequeueOutputBuffer(bufferInfo, if (endOfStream) 10_000L else 0L)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (muxerStarted) throw IllegalStateException("Format changed twice")
                    trackIndex = muxer!!.addTrack(enc.outputFormat)
                    muxer!!.start()
                    muxerStarted = true
                }
                outIdx >= 0 -> {
                    val outBuf: ByteBuffer = enc.getOutputBuffer(outIdx)
                        ?: throw RuntimeException("encoder output buffer was null")
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0
                    }
                    if (bufferInfo.size != 0 && muxerStarted) {
                        outBuf.position(bufferInfo.offset)
                        outBuf.limit(bufferInfo.offset + bufferInfo.size)
                        muxer!!.writeSampleData(trackIndex, outBuf, bufferInfo)
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
                else -> Log.w(TAG, "unexpected dequeueOutputBuffer $outIdx")
            }
        }
    }
}
