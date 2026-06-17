package com.example.camera_filter_engine.engine

import android.app.Activity
import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.view.TextureRegistry

/**
 * Top-level orchestrator. Owns:
 *  - CameraX preview attached to an internal OES SurfaceTexture
 *  - GL render thread that samples the OES texture and writes filtered output
 *    to the Flutter-supplied SurfaceTexture (external Texture widget).
 *  - Recorder (MediaCodec/MediaMuxer) capturing the filtered output.
 */
class FilterEngine(
    private val context: Context,
    private val activity: Activity,
    private val lifecycle: Lifecycle?,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private val targetWidth: Int,
    private val targetHeight: Int,
    startFront: Boolean,
) {
    companion object { private const val TAG = "FilterEngine" }

    // CameraX requires its callbacks on the actual Android main thread.
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private var lensFront = startFront
    private var cameraProvider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var camera: androidx.camera.core.Camera? = null
    private var pendingZoom: Float = 0f   // last requested linear zoom (0..1)

    private val outputSurfaceTexture: SurfaceTexture = textureEntry.surfaceTexture().apply {
        setDefaultBufferSize(targetWidth, targetHeight)
    }
    private val outputSurface = Surface(outputSurfaceTexture)

    private lateinit var renderer: GLRenderer
    private var recorder: VideoRecorder? = null
    private var pendingPhotoPath: String? = null
    private var pendingPhotoCb: ((String) -> Unit)? = null

    fun start() {
        renderer = GLRenderer(
            context = context,
            outputSurface = outputSurface,
            outputWidth = targetWidth,
            outputHeight = targetHeight,
        )
        renderer.onCameraTextureReady = { cameraSurfaceTexture ->
            // Camera frames feed renderer; bind to CameraX on main thread.
            activity.runOnUiThread { bindCameraX(cameraSurfaceTexture) }
        }
        renderer.onFrameRendered = { handlePostFrame() }
        renderer.start()
    }

    private fun bindCameraX(cameraSurfaceTexture: SurfaceTexture) {
        val owner = activity as? LifecycleOwner ?: return
        cameraSurfaceTexture.setDefaultBufferSize(targetWidth, targetHeight)
        val providerFut = ProcessCameraProvider.getInstance(context)
        providerFut.addListener({
            val provider = providerFut.get()
            cameraProvider = provider
            provider.unbindAll()
            val previewBuilder = Preview.Builder()
                .setTargetResolution(Size(targetWidth, targetHeight))
            val p = previewBuilder.build()
            p.setSurfaceProvider { req ->
                val surface = Surface(cameraSurfaceTexture)
                req.provideSurface(surface, mainExecutor) { surface.release() }
            }
            val selector = if (lensFront) CameraSelector.DEFAULT_FRONT_CAMERA
                           else CameraSelector.DEFAULT_BACK_CAMERA
            try {
                val cam = provider.bindToLifecycle(owner, selector, p)
                camera = cam
                preview = p
                // Re-apply any zoom the user set before/while re-binding.
                cam.cameraControl.setLinearZoom(pendingZoom.coerceIn(0f, 1f))
            } catch (e: Exception) {
                Log.e(TAG, "bindToLifecycle failed", e)
            }
        }, mainExecutor)
    }

    fun setZoom(level: Float) {
        pendingZoom = level.coerceIn(0f, 1f)
        activity.runOnUiThread {
            camera?.cameraControl?.setLinearZoom(pendingZoom)
        }
    }

    fun setFilter(id: String, params: Map<String, Float>?) {
        renderer.setFilter(id, params)
    }

    fun setParam(key: String, value: Float) {
        renderer.setParam(key, value)
    }

    fun setLut(path: String?) {
        renderer.setLut(path)
    }

    fun switchCamera(): Boolean {
        lensFront = !lensFront
        cameraProvider?.unbindAll()
        renderer.cameraSurfaceTexture?.let { bindCameraX(it) }
        return lensFront
    }

    fun takePicture(path: String, cb: (String) -> Unit) {
        pendingPhotoPath = path
        pendingPhotoCb = cb
        renderer.requestSnapshot()
    }

    fun startRecording(path: String) {
        val r = VideoRecorder(targetWidth, targetHeight, path)
        r.start { inputSurface ->
            renderer.attachRecorderSurface(inputSurface, targetWidth, targetHeight)
        }
        recorder = r
    }

    fun stopRecording(): String {
        val r = recorder ?: return ""
        renderer.detachRecorderSurface()
        val out = r.stop()
        recorder = null
        return out
    }

    private fun handlePostFrame() {
        recorder?.onFrameAvailable()
        pendingPhotoPath?.let { path ->
            val cb = pendingPhotoCb
            pendingPhotoPath = null
            pendingPhotoCb = null
            // GL thread reads pixels and writes JPEG
            renderer.readPixelsAndSaveJpeg(path) { saved ->
                cb?.invoke(saved)
            }
        }
    }

    fun release() {
        try { recorder?.stop() } catch (_: Throwable) {}
        recorder = null
        try { cameraProvider?.unbindAll() } catch (_: Throwable) {}
        renderer.stop()
        outputSurface.release()
        textureEntry.release()
    }
}
