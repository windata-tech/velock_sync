package tech.windata.velock.sync.velock_sync

import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var pendingTreeSelection: MethodChannel.Result? = null
    private val documentExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_TREE_CHANNEL,
        ).setMethodCallHandler { call, result -> handleDocumentTreeCall(call, result) }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DISK_SPACE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "availableBytes") {
                result.notImplemented()
            } else {
                availableBytes(call.arguments, result)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            POWER_STATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "isCharging") {
                result.notImplemented()
            } else {
                result.success(isCharging())
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VELOCK_EXCHANGE_CHANNEL,
        ).setMethodCallHandler { call, result -> handleVelockExchangeCall(call, result) }
    }

    @Deprecated("Deprecated in Android API 30")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_DOCUMENT_TREE) return
        val result = pendingTreeSelection ?: return
        pendingTreeSelection = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val uri = data.data!!
            val flags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("SAF_PERMISSION", "Unable to persist document tree access.", null)
        }
    }

    override fun onDestroy() {
        documentExecutor.shutdown()
        super.onDestroy()
    }

    private fun handleDocumentTreeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "authorizeTree" -> authorizeTree(result)
            "listTree" -> listTree(call.arguments, result)
            "copyFileToCache" -> copyFileToCache(call.arguments, result)
            "createDirectory" -> createDirectory(call.arguments, result)
            "writeFileFromPath" -> writeFileFromPath(call.arguments, result)
            "deleteEntry" -> deleteEntry(call.arguments, result)
            else -> result.notImplemented()
        }
    }

    private fun handleVelockExchangeCall(call: MethodCall, result: MethodChannel.Result) = onVelockExchangeExecutor(result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
        when (call.method) {
            "readyOutboxIds" -> queryReadyOutbox()
            "claimOutbox" -> claimOutbox(
                requireExchangeString(arguments, "batchId"),
                requireExchangeString(arguments, "leaseId"),
            )
            "stageOutboxArtifact" -> stageOutboxArtifact(
                requireExchangeString(arguments, "batchId"),
                requireExchangeString(arguments, "relativePath"),
            )
            "releaseStagedOutbox" -> releaseStagedOutbox(requireExchangeString(arguments, "batchId"))
            "writeOutboxReceipt" -> acknowledgeOutbox(
                requireExchangeString(arguments, "batchId"),
                requireExchangeBytes(arguments, "receipt"),
            )
            "createInbox" -> createInbox(requireExchangeString(arguments, "batchId"))
            "createInboxArtifactSource" -> createInboxArtifactSource(
                requireExchangeString(arguments, "batchId"),
                requireExchangeString(arguments, "relativePath"),
                requireExchangeLong(arguments, "length"),
            )
            "writeInboxArtifactFromPath" -> writeInboxArtifactFromPath(
                requireExchangeString(arguments, "batchId"),
                requireExchangeString(arguments, "relativePath"),
                requireExchangeString(arguments, "sourcePath"),
                requireExchangeLong(arguments, "length"),
            )
            "commitInbox" -> commitInbox(requireExchangeString(arguments, "batchId"))
            "readInboxReceipt" -> queryInboxReceipt(requireExchangeString(arguments, "batchId"))
            "readInboxArtifact" -> readExchangeArtifact(
                "inbox",
                requireExchangeString(arguments, "batchId"),
                requireExchangeString(arguments, "relativePath"),
            )
            "pairingDescriptor" -> pairingDescriptor()
            "submitPairingRequest" -> submitPairingRequest(
                requireExchangeString(arguments, "requestId"),
                requireExchangeBytes(arguments, "request"),
            )
            "queryPairingResponse" ->
                queryPairingResponse(requireExchangeString(arguments, "requestId"))
            "acknowledgePairing" -> acknowledgePairing(
                requireExchangeString(arguments, "requestId"),
            )
            else -> throw UnsupportedOperationException("Unknown Velock exchange call")
        }
    }

    private fun pairingDescriptor(): ByteArray =
        exchangeCall("pairingDescriptor", null, null).getByteArray("descriptor")
            ?: throw IOException("Velock pairing descriptor is unavailable.")

    private fun submitPairingRequest(requestId: String, request: ByteArray): String =
        exchangeCall(
            "submitPairingRequest",
            requireSafeExchangeBatchId(requestId),
            Bundle().apply { putByteArray("request", request) },
        ).getString("status")
            ?: throw IOException("Velock pairing request returned no status.")

    private fun queryPairingResponse(requestId: String): Map<String, Any> {
        val response = exchangeCall(
            "queryPairingResponse",
            requireSafeExchangeBatchId(requestId),
            null,
        )
        val status = response.getString("status")
            ?: throw IOException("Velock pairing response returned no status.")
        return buildMap {
            put("status", status)
            response.getByteArray("response")?.let { put("response", it) }
        }
    }

    private fun acknowledgePairing(requestId: String) {
        exchangeCall(
            "acknowledgePairing",
            requireSafeExchangeBatchId(requestId),
            null,
        )
    }

    private fun queryReadyOutbox(): List<String> {
        contentResolver.query(exchangeUri.buildUpon().appendPath("outbox").appendPath("ready").build(), null, null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex("batchId")
                return buildList {
                    while (cursor.moveToNext()) add(cursor.getString(index))
                }
            }
        return emptyList()
    }

    private fun claimOutbox(batchId: String, leaseId: String): Boolean = exchangeCall(
        "claimOutbox", batchId, Bundle().apply { putString("leaseId", leaseId) },
    ).getBoolean("claimed", false)

    private fun acknowledgeOutbox(batchId: String, receipt: ByteArray) {
        exchangeCall("acknowledgeOutbox", batchId, Bundle().apply { putByteArray("receipt", receipt) })
    }

    private fun createInbox(batchId: String) {
        exchangeCall("createInbox", batchId, null)
    }

    private fun createInboxArtifactSource(
        batchId: String,
        relativePath: String,
        length: Long,
    ): String {
        val safeBatchId = requireSafeExchangeBatchId(batchId)
        safeExchangeArtifactPath(relativePath)
        if (length < 0) throw IllegalArgumentException("Invalid exchange artifact length.")
        val directory = File(File(File(cacheDir, "velock-exchange"), "inbox"), safeBatchId)
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Unable to create inbox artifact staging.")
        }
        return File(directory, "${UUID.randomUUID()}.artifact").absolutePath
    }

    private fun writeInboxArtifactFromPath(
        batchId: String,
        relativePath: String,
        sourcePath: String,
        length: Long,
    ) {
        val safeBatchId = requireSafeExchangeBatchId(batchId)
        val segments = safeExchangeArtifactPath(relativePath)
        val sourceRoot = File(File(cacheDir, "velock-exchange"), "inbox").canonicalFile
        val source = File(sourcePath).canonicalFile
        if (source.parentFile?.parentFile != sourceRoot ||
            source.parentFile?.name != safeBatchId ||
            !source.isFile ||
            source.length() != length
        ) {
            throw SecurityException("Invalid private inbox artifact source.")
        }
        val uri = exchangeUri.buildUpon().appendPath("inbox").appendPath(safeBatchId)
            .apply { segments.forEach(::appendPath) }
            .appendQueryParameter("staging", "1")
            .build()
        try {
            source.inputStream().use { input ->
                contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    input.copyTo(output, DEFAULT_BUFFER_SIZE)
                    if (output is FileOutputStream) output.fd.sync()
                } ?: throw IOException("Exchange inbox artifact is unavailable.")
            }
        } finally {
            source.delete()
        }
    }

    private fun commitInbox(batchId: String) {
        exchangeCall("commitInbox", batchId, null)
    }

    private fun queryInboxReceipt(batchId: String): ByteArray? =
        exchangeCall("queryInboxReceipt", batchId, null).getByteArray("receipt")

    private fun stageOutboxArtifact(batchId: String, relativePath: String): Map<String, Any> {
        val safeBatchId = requireSafeExchangeBatchId(batchId)
        val segments = safeExchangeArtifactPath(relativePath)
        val destination = File(
            File(File(cacheDir, "velock-exchange"), "outbox"),
            "$safeBatchId/${segments.joinToString(File.separator)}",
        )
        destination.parentFile?.mkdirs()
        val partial = File(destination.parentFile, ".${destination.name}.${UUID.randomUUID()}.tmp")
        val uri = exchangeUri.buildUpon().appendPath("outbox").appendPath(safeBatchId)
            .apply { segments.forEach(::appendPath) }.build()
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(partial).use { output ->
                    input.copyTo(output, DEFAULT_BUFFER_SIZE)
                    output.fd.sync()
                }
            } ?: throw IOException("Exchange artifact is unavailable.")
            if (destination.exists() && !destination.delete()) {
                throw IOException("Unable to replace staged exchange artifact.")
            }
            if (!partial.renameTo(destination)) {
                throw IOException("Unable to finalize staged exchange artifact.")
            }
            return mapOf("path" to destination.absolutePath, "length" to destination.length())
        } catch (error: Exception) {
            partial.delete()
            throw error
        }
    }

    private fun releaseStagedOutbox(batchId: String) {
        val directory = File(File(File(cacheDir, "velock-exchange"), "outbox"), requireSafeExchangeBatchId(batchId))
        if (directory.exists() && !directory.deleteRecursively()) {
            throw IOException("Unable to release staged exchange artifacts.")
        }
    }

    private fun readExchangeArtifact(area: String, batchId: String, relativePath: String): ByteArray {
        val safeBatchId = requireSafeExchangeBatchId(batchId)
        val segments = safeExchangeArtifactPath(relativePath)
        val uri = exchangeUri.buildUpon().appendPath(area).appendPath(safeBatchId)
            .apply { segments.forEach(::appendPath) }.build()
        return contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IOException("Exchange artifact is unavailable.")
    }

    private fun exchangeCall(method: String, arg: String?, extras: Bundle?): Bundle =
        contentResolver.call(exchangeUri, method, arg, extras)
            ?: throw IOException("Velock exchange provider returned no result.")

    private val exchangeUri: Uri
        get() {
            val authority = BuildConfig.VELOCK_EXCHANGE_AUTHORITY
            val expectedPackage = BuildConfig.VELOCK_COMPANION_PACKAGE
            val expectedCertificate = BuildConfig.VELOCK_COMPANION_CERT_SHA256
                .replace(":", "")
                .lowercase()
            if (
                !EXCHANGE_AUTHORITY.matches(authority) ||
                !PACKAGE_NAME.matches(expectedPackage) ||
                !CERTIFICATE_SHA256.matches(expectedCertificate)
            ) {
                throw SecurityException("Velock exchange is not configured for this build.")
            }
            val provider = packageManager.resolveContentProvider(
                authority,
                PackageManager.MATCH_DISABLED_COMPONENTS,
            ) ?: throw SecurityException("Configured Velock exchange provider is unavailable.")
            if (provider.packageName != expectedPackage ||
                !packageCertificateDigests(provider.packageName).contains(expectedCertificate)
            ) {
                throw SecurityException("Configured Velock exchange provider is not trusted.")
            }
            return Uri.Builder().scheme("content").authority(authority).build()
        }

    @Suppress("DEPRECATION")
    private fun packageCertificateDigests(packageName: String): Set<String> {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo
                ?: throw SecurityException("Velock exchange provider has no signing identity.")
            // Only the Provider's current signer set is trusted. A rotated
            // historical certificate cannot keep an old release policy alive.
            signingInfo.apkContentsSigners
        } else {
            packageInfo.signatures
        } ?: throw SecurityException("Velock exchange provider has no signing identity.")
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        }
    }

    private fun requireExchangeString(arguments: Map<*, *>, key: String): String =
        arguments[key] as? String ?: throw IllegalArgumentException("Missing $key.")

    private fun requireExchangeBytes(arguments: Map<*, *>, key: String): ByteArray =
        arguments[key] as? ByteArray ?: throw IllegalArgumentException("Missing $key.")

    private fun requireExchangeLong(arguments: Map<*, *>, key: String): Long =
        (arguments[key] as? Number)?.toLong()
            ?: throw IllegalArgumentException("Missing $key.")

    private fun requireSafeExchangeBatchId(value: String): String {
        if (!EXCHANGE_ID.matches(value)) throw IllegalArgumentException("Invalid exchange batch ID.")
        return value
    }

    private fun safeExchangeArtifactPath(value: String): List<String> {
        val segments = value.split('/')
        if (segments.isEmpty() || segments.any { !EXCHANGE_ARTIFACT_SEGMENT.matches(it) }) {
            throw IllegalArgumentException("Invalid exchange artifact path.")
        }
        return segments
    }

    private fun availableBytes(arguments: Any?, result: MethodChannel.Result) {
        try {
            val map = arguments as? Map<*, *> ?: throw IllegalArgumentException("Missing arguments.")
            val path = map["path"] as? String ?: throw IllegalArgumentException("Missing path.")
            val target = File(path).canonicalFile
            if (!target.isDirectory) throw IOException("Storage path is unavailable.")
            result.success(StatFs(target.path).availableBytes)
        } catch (error: Exception) {
            result.error("DISK_SPACE", "Unable to inspect available storage.", null)
        }
    }

    private fun isCharging(): Boolean {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return false
        return battery.getIntExtra("plugged", 0) != 0
    }

    private fun authorizeTree(result: MethodChannel.Result) {
        if (pendingTreeSelection != null) {
            result.error("SAF_BUSY", "A document tree selection is already active.", null)
            return
        }
        pendingTreeSelection = result
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            },
            REQUEST_DOCUMENT_TREE,
        )
    }

    private fun listTree(arguments: Any?, result: MethodChannel.Result) = onDocumentExecutor(result) {
        val root = documentRoot(treeUri(arguments))
        val entries = mutableListOf<Map<String, Any>>()
        listChildren(root, "", entries)
        entries
    }

    private fun copyFileToCache(arguments: Any?, result: MethodChannel.Result) = onDocumentExecutor(result) {
        val (root, parts) = rootAndPath(arguments)
        val source = findEntry(root, parts) ?: throw IOException("Document tree file is unavailable.")
        if (!source.isFile) throw IOException("Document tree entry is not a file.")
        val temporary = File.createTempFile("velock-saf-read-", ".tmp", cacheDir)
        try {
            contentResolver.openInputStream(source.uri)?.use { input ->
                temporary.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IOException("Unable to read document tree file.")
            temporary.absolutePath
        } catch (error: Exception) {
            temporary.delete()
            throw error
        }
    }

    private fun createDirectory(arguments: Any?, result: MethodChannel.Result) = onDocumentExecutor(result) {
        val (root, parts) = rootAndPath(arguments)
        ensureDirectory(root, parts)
        null
    }

    private fun writeFileFromPath(arguments: Any?, result: MethodChannel.Result) = onDocumentExecutor(result) {
        val map = arguments as? Map<*, *> ?: throw IllegalArgumentException("Missing arguments.")
        val localPath = map["localPath"] as? String ?: throw IllegalArgumentException("Missing local path.")
        val source = File(localPath)
        requirePrivateSource(source)
        val (root, parts) = rootAndPath(arguments)
        val parent = ensureDirectory(root, parts.dropLast(1))
        val name = parts.last()
        val existing = childNamed(parent, name)
        if (existing?.isDirectory == true) throw IOException("Cannot replace a directory with a file.")

        val temporaryName = ".velock-tmp-${UUID.randomUUID()}-$name"
        val temporary = parent.createFile("application/octet-stream", temporaryName)
            ?: throw IOException("Unable to create temporary document tree file.")
        try {
            source.inputStream().use { input ->
                contentResolver.openOutputStream(temporary.uri, "wt")?.use { output ->
                    input.copyTo(output)
                } ?: throw IOException("Unable to write document tree file.")
            }
            if (existing != null && !existing.delete()) {
                throw IOException("Unable to replace document tree file.")
            }
            if (!temporary.renameTo(name)) {
                throw IOException("Unable to finalize document tree file.")
            }
        } catch (error: Exception) {
            temporary.delete()
            throw error
        }
        null
    }

    private fun deleteEntry(arguments: Any?, result: MethodChannel.Result) = onDocumentExecutor(result) {
        val (root, parts) = rootAndPath(arguments)
        val entry = findEntry(root, parts)
        if (entry != null && !entry.delete()) throw IOException("Unable to delete document tree entry.")
        null
    }

    private fun onDocumentExecutor(
        result: MethodChannel.Result,
        action: () -> Any?,
    ) {
        documentExecutor.execute {
            try {
                respondSuccess(result, action())
            } catch (error: Exception) {
                respondError(result, "SAF_OPERATION", error)
            }
        }
    }

    private fun onVelockExchangeExecutor(
        result: MethodChannel.Result,
        action: () -> Any?,
    ) {
        documentExecutor.execute {
            try {
                respondSuccess(result, action())
            } catch (error: Exception) {
                val code = when (error) {
                    is UnsupportedOperationException -> "UNSUPPORTED_OPERATION"
                    is SecurityException -> "ACCESS_DENIED"
                    is FileNotFoundException -> "NOT_FOUND"
                    is IllegalArgumentException -> "INVALID_PACKAGE"
                    is IllegalStateException -> when {
                        error.message?.contains("authorization required", ignoreCase = true) == true ->
                            "AUTHORIZATION_REQUIRED"
                        error.message?.contains("authorization denied", ignoreCase = true) == true ->
                            "AUTHORIZATION_DENIED"
                        error.message?.contains("replayed", ignoreCase = true) == true ->
                            "PAIRING_REPLAYED"
                        error.message?.contains("pairing", ignoreCase = true) == true &&
                            error.message?.contains("expired", ignoreCase = true) == true ->
                            "PAIRING_EXPIRED"
                        error.message?.contains("pairing", ignoreCase = true) == true &&
                            error.message?.contains("response", ignoreCase = true) == true ->
                            "INVALID_PAIRING_RESPONSE"
                        error.message?.contains("already exists", ignoreCase = true) == true ->
                            "LEASE_CONFLICT"
                        error.message?.contains("expired", ignoreCase = true) == true ->
                            "LEASE_EXPIRED"
                        error.message?.contains("version", ignoreCase = true) == true ->
                            "UNSUPPORTED_VERSION"
                        error.message?.contains("missing", ignoreCase = true) == true ||
                            error.message?.contains("incomplete", ignoreCase = true) == true ->
                            "INVALID_PACKAGE"
                        else -> "TEMPORARY_UNAVAILABLE"
                    }
                    is IOException -> "TEMPORARY_UNAVAILABLE"
                    else -> "TEMPORARY_UNAVAILABLE"
                }
                runOnUiThread {
                    result.error(code, "Velock Exchange operation failed.", null)
                }
            }
        }
    }

    private fun treeUri(arguments: Any?): String {
        val map = arguments as? Map<*, *> ?: throw IllegalArgumentException("Missing arguments.")
        val treeUri = map["treeUri"] as? String ?: throw IllegalArgumentException("Missing tree URI.")
        if (!treeUri.startsWith("content://")) throw IllegalArgumentException("Invalid tree URI.")
        return treeUri
    }

    private fun rootAndPath(arguments: Any?): Pair<DocumentFile, List<String>> {
        val map = arguments as? Map<*, *> ?: throw IllegalArgumentException("Missing arguments.")
        val relativePath = map["relativePath"] as? String
            ?: throw IllegalArgumentException("Missing relative path.")
        return documentRoot(treeUri(arguments)) to safeParts(relativePath)
    }

    private fun documentRoot(treeUri: String): DocumentFile {
        val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
            ?: throw IOException("Unable to open the selected document tree.")
        if (!root.canRead() || !root.canWrite()) {
            throw SecurityException("Selected document tree permission is unavailable.")
        }
        return root
    }

    private fun listChildren(
        directory: DocumentFile,
        prefix: String,
        output: MutableList<Map<String, Any>>,
    ) {
        val children = directory.listFiles().sortedBy { it.name ?: "" }
        val names = mutableSetOf<String>()
        for (child in children) {
            val name = child.name ?: throw IOException("Document tree item has no name.")
            requireSafeName(name)
            if (!names.add(name)) throw IOException("Document tree contains duplicate names.")
            val relativePath = if (prefix.isEmpty()) name else "$prefix/$name"
            when {
                child.isDirectory -> {
                    output += mapOf(
                        "relativePath" to relativePath,
                        "type" to "directory",
                        "size" to -1,
                        "modifiedAt" to child.lastModified(),
                    )
                    listChildren(child, relativePath, output)
                }
                child.isFile -> output += mapOf(
                    "relativePath" to relativePath,
                    "type" to "file",
                    "size" to child.length(),
                    "modifiedAt" to child.lastModified(),
                )
                else -> throw IOException("Unsupported document tree item.")
            }
        }
    }

    private fun findEntry(root: DocumentFile, parts: List<String>): DocumentFile? {
        var current = root
        for (part in parts) {
            current = childNamed(current, part) ?: return null
        }
        return current
    }

    private fun ensureDirectory(root: DocumentFile, parts: List<String>): DocumentFile {
        var current = root
        for (part in parts) {
            val existing = childNamed(current, part)
            current = when {
                existing == null -> current.createDirectory(part)
                    ?: throw IOException("Unable to create document tree directory.")
                existing.isDirectory -> existing
                else -> throw IOException("Document tree file conflicts with directory path.")
            }
        }
        return current
    }

    private fun childNamed(parent: DocumentFile, name: String): DocumentFile? {
        val matches = parent.listFiles().filter { it.name == name }
        if (matches.size > 1) throw IOException("Document tree contains duplicate names.")
        return matches.singleOrNull()
    }

    private fun safeParts(relativePath: String): List<String> {
        if (relativePath.isEmpty() || relativePath.startsWith('/') || relativePath.contains('\\')) {
            throw IOException("Document tree relative path is unsafe.")
        }
        return relativePath.split('/').onEach(::requireSafeName)
    }

    private fun requireSafeName(name: String) {
        if (name.isEmpty() || name == "." || name == ".." || name.contains('/') || name.contains('\\')) {
            throw IOException("Document tree item name is unsafe.")
        }
    }

    private fun requirePrivateSource(source: File) {
        if (!source.isFile) throw IOException("Local source file is unavailable.")
        val canonical = source.canonicalFile
        val allowedRoots = listOf(cacheDir.canonicalFile, filesDir.canonicalFile)
        if (allowedRoots.none { root -> canonical.path.startsWith(root.path + File.separator) }) {
            throw SecurityException("Local source file is outside app-private storage.")
        }
    }

    private fun respondSuccess(result: MethodChannel.Result, value: Any?) {
        runOnUiThread { result.success(value) }
    }

    private fun respondError(result: MethodChannel.Result, code: String, error: Exception) {
        runOnUiThread { result.error(code, error.message ?: code, null) }
    }

    companion object {
        private const val DOCUMENT_TREE_CHANNEL = "tech.windata.velock.sync/document_tree"
        private const val DISK_SPACE_CHANNEL = "tech.windata.velock.sync/disk_space"
        private const val POWER_STATE_CHANNEL = "tech.windata.velock.sync/power_state"
        private const val VELOCK_EXCHANGE_CHANNEL = "tech.windata.velock.sync/velock_exchange"
        private val EXCHANGE_AUTHORITY = Regex("[A-Za-z][A-Za-z0-9_.-]{0,255}")
        private val PACKAGE_NAME = Regex("[A-Za-z][A-Za-z0-9_.-]{0,255}")
        private val CERTIFICATE_SHA256 = Regex("[0-9a-f]{64}")
        private val EXCHANGE_ID = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
        private val EXCHANGE_ARTIFACT_SEGMENT = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
        private const val REQUEST_DOCUMENT_TREE = 5194
    }
}
