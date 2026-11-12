package dev.exact.canvas

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.ColorSpace
import android.os.ext.SdkExtensions
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream

/** A file input imports copies and releases provider access after copying (LLP 1069.002 D4–D8). */
internal object FilePicker {
    const val FALLBACK = "file picker: photo picker unavailable; using document picker"

    fun show(context: Context, accept: List<String>, multiple: Boolean, answer: (String?) -> Unit) {
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        val photo = Build.VERSION.SDK_INT >= 33 ||
            (Build.VERSION.SDK_INT >= 30 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2)
        fun launch(usePhoto: Boolean) {
            val request = intent(accept, multiple, usePhoto)
            Extensions.start(request, failed = { reason ->
                if (request.action == MediaStore.ACTION_PICK_IMAGES && reason == "NotFoundError") {
                    answer(FALLBACK)
                    launch(false)
                } else answer("file picker: $reason")
            }) { code, data ->
                val uris = chosen(code, data, multiple)
                if (uris.isEmpty()) answer(null)
                else try {
                    val held = retain(app.contentResolver, uris)
                    try {
                        Thread({
                            val result = try {
                                copy(app.cacheDir, open(app.contentResolver, uris), accept)
                            } catch (e: Exception) { failure(e) }
                            main.post {
                                release(app.contentResolver, held)
                                answer(result)
                            }
                        }, "exact-file-picker").start()
                    } catch (e: Exception) {
                        release(app.contentResolver, held)
                        throw e
                    }
                } catch (e: Exception) { answer(failure(e)) }
            }
        }
        try { launch(photo) } catch (e: RuntimeException) { answer(failure(e)) }
    }

    // Both ACTION_OPEN_DOCUMENT and ACTION_PICK_IMAGES offer persistable read grants.
    // Take them before returning to the activity; provider query/open/read run only on the worker.
    // https://developer.android.com/training/data-storage/shared/photo-picker#persist-media-file-access
    private data class Grant(var users: Int, val owned: Boolean)
    private val grants = HashMap<Uri, Grant>() // Main thread, including worker completion.

    private fun retain(resolver: ContentResolver, uris: List<Uri>): List<Uri> {
        val held = ArrayList<Uri>()
        try {
            for (uri in uris) {
                val existing = grants[uri]
                if (existing != null) existing.users++
                else {
                    val owned = resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }
                    if (owned) resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    grants[uri] = Grant(1, owned)
                }
                held.add(uri)
            }
            return held
        } catch (e: Exception) {
            release(resolver, held)
            throw e
        }
    }

    private fun release(resolver: ContentResolver, uris: List<Uri>) {
        for (uri in uris) {
            val grant = grants.getValue(uri)
            if (--grant.users == 0) {
                grants.remove(uri)
                if (grant.owned) runCatching { resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            }
        }
    }

    private fun convertsHeic(accept: List<String>): Boolean {
        val types = mimeTypes(accept)
        return "image/jpeg" in types &&
            accept.none { it.trim().lowercase(java.util.Locale.ROOT) in listOf("*/*", "image/*", "image/heic", "image/heif", ".heic", ".heif") }
    }

    fun mimeTypes(accept: List<String>): List<String> = accept.map { raw ->
        val type = raw.trim().lowercase(java.util.Locale.ROOT)
        if (type.startsWith('.')) MimeTypeMap.getSingleton().getMimeTypeFromExtension(type.drop(1)) ?: "*/*"
        else type
    }.filter { it.isNotEmpty() }.distinct()

    fun intent(accept: List<String>, multiple: Boolean, photoAvailable: Boolean): Intent {
        val types = mimeTypes(accept)
        val visual = types.isNotEmpty() && types.all { it == "image/*" || it == "video/*" }
        if (photoAvailable && visual) return Intent(MediaStore.ACTION_PICK_IMAGES).apply {
            type = types.singleOrNull()
            if (multiple) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
        }
        val offered = if (convertsHeic(accept)) (types + listOf("image/heic", "image/heif")).distinct() else types
        return Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).apply {
            type = if ("*/*" in offered) "*/*" else offered.singleOrNull() ?: "*/*"
            if (offered.size > 1 && "*/*" !in offered) putExtra(Intent.EXTRA_MIME_TYPES, offered.toTypedArray())
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        }
    }

    fun chosen(code: Int, data: Intent?, multiple: Boolean): List<Uri> {
        if (code != Activity.RESULT_OK || data == null) return emptyList()
        val clip = data.clipData
        val uris = if (clip == null) listOfNotNull(data.data)
            else (0 until clip.itemCount).map { clip.getItemAt(it).uri }
        return uris.distinct().let { if (multiple) it else it.take(1) }
    }

    private data class Source(val name: String, val mime: String?, val input: InputStream)

    private fun open(resolver: ContentResolver, uris: List<Uri>): List<Source> {
        val opened = ArrayList<Source>()
        try {
            for ((index, uri) in uris.withIndex()) {
                val name = displayName(resolver, uri, index)
                val mime = resolver.getType(uri)?.takeIf { it.isNotBlank() }
                    ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT))
                val input = resolver.openInputStream(uri) ?: throw IOException("no stream for the chosen file")
                opened.add(Source(name, mime, input))
            }
            return opened
        } catch (e: Exception) {
            opened.forEach { runCatching { it.input.close() } }
            throw e
        }
    }

    fun copy(resolver: ContentResolver, cache: File, uris: List<Uri>): String = try {
        copy(cache, open(resolver, uris), emptyList())
    } catch (e: Exception) { failure(e) }

    /** Each copy has its own directory so equal display names cannot overwrite one another. */
    private fun copy(cache: File, sources: List<Source>, accept: List<String>): String {
        val directories = ArrayList<File>()
        val picked = JSONArray()
        return try {
            for (source in sources) {
                val dir = java.nio.file.Files.createTempDirectory(cache.toPath(), "exact-picked-").toFile()
                directories.add(dir)
                val name = source.name
                var mime = source.mime
                var leaf = name
                if (!leaf.contains('.')) {
                    mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }?.let { leaf += ".$it" }
                }
                var file = File(dir, leaf)
                source.input.use { from -> Files.output(file).use { to -> from.copyTo(to) } }
                if (mime in listOf("image/heic", "image/heif") && convertsHeic(accept)) {
                    val jpeg = File.createTempFile("converted-", ".jpg", dir)
                    transcode(file, jpeg)
                    file.delete()
                    file = jpeg
                    mime = "image/jpeg"
                }
                val extensions = JSONObject()
                for (token in accept.map { it.trim().lowercase(java.util.Locale.ROOT) }.filter { it.startsWith('.') }) {
                    MimeTypeMap.getSingleton().getMimeTypeFromExtension(token.drop(1))?.let { extensions.put(token, it) }
                }
                picked.put(JSONObject().put("path", file.absolutePath).put("name", name)
                    .put("type", mime ?: JSONObject.NULL).put("extensions", extensions)
                    .put("extension", mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) } ?: JSONObject.NULL))
            }
            picked.toString()
        } catch (e: Exception) {
            directories.forEach { it.deleteRecursively() }
            failure(e)
        } catch (_: OutOfMemoryError) {
            directories.forEach { it.deleteRecursively() }
            "file picker: image decode did not fit in memory"
        } finally {
            sources.forEach { runCatching { it.input.close() } }
        }
    }

    private fun transcode(source: File, destination: File) {
        // ImageDecoder applies orientation. Encoding the upright pixels writes none of the provider's EXIF/GPS.
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }
        try {
            Files.output(destination).use {
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) throw IOException("JPEG encode failed")
            }
        } finally { bitmap.recycle() }
    }

    private fun failure(e: Exception) = "file picker: ${e.message ?: e.javaClass.simpleName}"

    private fun displayName(resolver: ContentResolver, uri: Uri, index: Int): String {
        val supplied = try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        } catch (_: Exception) { null }
        return supplied?.substringAfterLast('/')?.substringAfterLast('\\')?.replace("\u0000", "")
            ?.takeIf { it.isNotBlank() && it != "." && it != ".." } ?: "file-$index"
    }
}
