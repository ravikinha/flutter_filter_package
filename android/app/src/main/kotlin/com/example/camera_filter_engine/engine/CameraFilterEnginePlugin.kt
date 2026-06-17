package com.example.camera_filter_engine.engine

import android.app.Activity
import android.content.Context
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

class CameraFilterEnginePlugin(private val initialActivity: Activity? = null)
    : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: Activity? = initialActivity
    private var lifecycle: Lifecycle? = null

    private var engine: FilterEngine? = null
    private var progressSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()
    // Flag for the currently running processVideo job; flipping it to true
    // tells the GL/MediaCodec loop to bail out early.
    private var currentVideoCancel: java.util.concurrent.atomic.AtomicBoolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "camera_filter_engine")
        channel.setMethodCallHandler(this)
        progressChannel = EventChannel(binding.binaryMessenger, "camera_filter_engine/progress")
        progressChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        engine?.release()
        engine = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        lifecycle = (binding.activity as? LifecycleOwner)?.lifecycle
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> initialize(call, result)
                "dispose" -> { engine?.release(); engine = null; result.success(null) }
                "setFilter" -> {
                    val id = call.argument<String>("id") ?: "none"
                    @Suppress("UNCHECKED_CAST")
                    val params = call.argument<Map<String, Any?>>("params")
                            ?.mapValues { (it.value as Number).toFloat() }
                    engine?.setFilter(id, params)
                    result.success(null)
                }
                "setParam" -> {
                    val k = call.argument<String>("key")!!
                    val v = (call.argument<Number>("value") ?: 0.0).toFloat()
                    engine?.setParam(k, v)
                    result.success(null)
                }
                "setLut" -> {
                    val path = call.argument<String>("path")
                    engine?.setLut(path)
                    result.success(null)
                }
                "switchCamera" -> {
                    val front = engine?.switchCamera() ?: false
                    result.success(if (front) "front" else "back")
                }
                "setZoom" -> {
                    val level = (call.argument<Number>("level") ?: 0.0).toFloat()
                    engine?.setZoom(level)
                    result.success(null)
                }
                "takePicture" -> {
                    val path = call.argument<String>("path")!!
                    engine?.takePicture(path) { p -> result.success(p) }
                        ?: result.success(null)
                }
                "startRecording" -> {
                    val path = call.argument<String>("path")!!
                    engine?.startRecording(path)
                    result.success(null)
                }
                "stopRecording" -> {
                    val path = engine?.stopRecording()
                    result.success(path)
                }
                "saveToGallery" -> {
                    val path = call.argument<String>("path")!!
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val ok = GallerySaver.save(context, path, isVideo)
                    result.success(ok)
                }
                "processImage" -> handleProcessImage(call, result)
                "processVideo" -> handleProcessVideo(call, result)
                "previewFilter" -> handlePreviewFilter(call, result)
                "cropImage" -> handleCropImage(call, result)
                "cropVideo" -> handleCropVideo(call, result)
                "composeVideo" -> handleComposeVideo(call, result)
                "trimVideo" -> handleTrimVideo(call, result)
                "cancelProcessing" -> {
                    currentVideoCancel?.set(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("CFE_ERROR", e.message, e.stackTraceToString())
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val act = activity ?: throw IllegalStateException("Activity not attached")
        val width = call.argument<Int>("width") ?: 1280
        val height = call.argument<Int>("height") ?: 720
        val lensStr = call.argument<String>("lens") ?: "back"

        val entry = textures.createSurfaceTexture()
        val e = FilterEngine(
            context = context,
            activity = act,
            lifecycle = lifecycle,
            textureEntry = entry,
            targetWidth = width,
            targetHeight = height,
            startFront = lensStr == "front",
        )
        e.start()
        engine = e

        result.success(mapOf(
            "textureId" to entry.id(),
            "width" to width,
            "height" to height,
        ))
    }

    private fun handleProcessImage(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val filterId = call.argument<String>("filterId") ?: "none"
        val params = floatParams(call, "params")
        val lutPath = call.argument<String>("lutPath")
        val filterId2 = call.argument<String>("filterId2")
        val params2 = floatParams(call, "params2")
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.processImage(context, input, output, filterId, params,
                    lutPath, filterId2, params2)
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("PROC", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun handleCropImage(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val left = (call.argument<Number>("left") ?: 0.0).toDouble()
        val top = (call.argument<Number>("top") ?: 0.0).toDouble()
        val right = (call.argument<Number>("right") ?: 1.0).toDouble()
        val bottom = (call.argument<Number>("bottom") ?: 1.0).toDouble()
        val flipH = call.argument<Boolean>("flipH") ?: false
        val flipV = call.argument<Boolean>("flipV") ?: false
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.cropImage(context, input, output,
                    left, top, right, bottom, flipH, flipV)
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("CROP", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun handleCropVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val left = (call.argument<Number>("left") ?: 0.0).toDouble()
        val top = (call.argument<Number>("top") ?: 0.0).toDouble()
        val right = (call.argument<Number>("right") ?: 1.0).toDouble()
        val bottom = (call.argument<Number>("bottom") ?: 1.0).toDouble()
        val flipH = call.argument<Boolean>("flipH") ?: false
        val flipV = call.argument<Boolean>("flipV") ?: false
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.cropVideo(context, input, output,
                    left, top, right, bottom, flipH, flipV)
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("CROP", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun handleComposeVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val overlay = call.argument<String>("overlayPngPath")!!
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.composeVideo(context, input, output, overlay)
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("COMPOSE", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun handleTrimVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val startMs = (call.argument<Number>("startMs") ?: 0).toLong()
        val endMs = (call.argument<Number>("endMs") ?: Long.MAX_VALUE).toLong()
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.trimVideo(input, output, startMs, endMs)
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("TRIM", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun floatParams(call: MethodCall, key: String): Map<String, Float>? {
        @Suppress("UNCHECKED_CAST")
        return call.argument<Map<String, Any?>>(key)
            ?.mapValues { (it.value as Number).toFloat() }
    }

    private fun handlePreviewFilter(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val filterId = call.argument<String>("filterId") ?: "none"
        val isVideo = call.argument<Boolean>("isVideo") ?: false
        val atSeconds = (call.argument<Number>("atSeconds") ?: 1.0).toDouble()
        val params = floatParams(call, "params")
        val lutPath = call.argument<String>("lutPath")
        val filterId2 = call.argument<String>("filterId2")
        val params2 = floatParams(call, "params2")
        ioExecutor.execute {
            try {
                val saved = MediaProcessor.previewFilter(
                    context, input, output, filterId, params, lutPath,
                    isVideo, atSeconds, filterId2, params2,
                )
                mainHandler.post { result.success(saved) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("PROC", t.message, t.stackTraceToString()) }
            }
        }
    }

    private fun handleProcessVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("inputPath")!!
        val output = call.argument<String>("outputPath")!!
        val filterId = call.argument<String>("filterId") ?: "none"
        val params = floatParams(call, "params")
        val lutPath = call.argument<String>("lutPath")
        val filterId2 = call.argument<String>("filterId2")
        val params2 = floatParams(call, "params2")

        // Tell any in-flight processVideo job to stop, then own the new flag.
        currentVideoCancel?.set(true)
        val cancel = java.util.concurrent.atomic.AtomicBoolean(false)
        currentVideoCancel = cancel

        ioExecutor.execute {
            try {
                val saved = MediaProcessor.processVideo(
                    context, input, output, filterId, params, lutPath,
                    progress = { p ->
                        val pd = p.toDouble()
                        mainHandler.post { progressSink?.success(pd) }
                    },
                    cancel = cancel,
                    filterId2 = filterId2,
                    params2 = params2,
                )
                mainHandler.post { result.success(saved) }
            } catch (_: MediaProcessor.CancelledException) {
                // Cancelled — return null path so Dart can ignore quietly.
                mainHandler.post { result.success(null) }
            } catch (t: Throwable) {
                mainHandler.post { result.error("PROC", t.message, t.stackTraceToString()) }
            } finally {
                // Drop the flag if it's still the one we owned; new callers
                // will have replaced it already if they raced in.
                if (currentVideoCancel === cancel) currentVideoCancel = null
            }
        }
    }
}
