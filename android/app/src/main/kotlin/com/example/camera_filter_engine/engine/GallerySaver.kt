package com.example.camera_filter_engine.engine

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * Copies a file from app-private storage into the system gallery via MediaStore
 * so it shows up in Photos / Gallery / Files. On Android 10+ uses the scoped
 * relative path; on older versions falls back to the legacy /Pictures or
 * /Movies directories.
 */
object GallerySaver {
    private const val ALBUM = "CameraFilterEngine"

    fun save(ctx: Context, sourcePath: String, isVideo: Boolean): Boolean {
        val src = File(sourcePath)
        if (!src.exists()) return false
        return try {
            val resolver = ctx.contentResolver
            val collection = if (isVideo) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val mime = if (isVideo) "video/mp4" else "image/jpeg"
            val name = src.name
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val sub = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "$sub/$ALBUM")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
            }
            val uri = resolver.insert(collection, values) ?: return false
            resolver.openOutputStream(uri).use { out ->
                if (out == null) return false
                src.inputStream().use { it.copyTo(out) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            true
        } catch (t: Throwable) {
            t.printStackTrace()
            false
        }
    }
}
