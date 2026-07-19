package tech.windata.velock.sync.velock_sync

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

class ProtocolV1VectorsTest {
    private val vaultId = "vault-vector-1"
    private val blobId = "blob-vector-1"

    @Test
    fun acceptsCanonicalProtocolVector() {
        val document = ProtocolV1VectorVerifier.parseProtocol(vectorBytes("valid/protocol.utf8.json", wrappedUtf8 = true))
        assertEquals(vaultId, document.vaultId)
        assertEquals("2026-07-15T00:00:00.000Z", document.createdAt)
    }

    @Test
    fun rejectsUnsupportedProtocolVersion() {
        assertFails { ProtocolV1VectorVerifier.parseProtocol(vectorBytes("unsupported_version/protocol.json")) }
    }

    @Test
    fun rejectsTraversalAndReplayVectors() {
        val identifiers = JSONObject(vectorBytes("path_traversal/identifiers.json").toString(StandardCharsets.UTF_8))
        assertFalse(ProtocolV1VectorVerifier.isOpaqueId(identifiers.getString("vaultId")))
        assertFalse(ProtocolV1VectorVerifier.isOpaqueId(identifiers.getString("blobId")))
        assertFails { ProtocolV1VectorVerifier.validateOperations(vectorBytes("replay/operations.json")) }
    }

    @Test
    fun rejectsForgedAndTruncatedBlobVectors() {
        listOf("invalid_authentication/blob.hex", "corrupted_blob/blob.hex").forEach { path ->
            assertFails { ProtocolV1VectorVerifier.decryptBlob(hexBytes(path), vaultId, blobId, "key-1") }
        }
    }

    @Test
    fun acceptsRfc8032Ed25519SignatureVector() {
        val vector = JSONObject(vectorBytes("valid/ed25519_signature.json").toString(StandardCharsets.UTF_8))
        val publicKey = hexString(vector.getString("publicKeyHex"))
        val signature = hexString(vector.getString("signatureHex"))
        val message = hexString(vector.getString("messageHex"))
        val encodedPublicKey = hexString("302a300506032b6570032100") + publicKey
        val verifier = Signature.getInstance("Ed25519")
        verifier.initVerify(KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(encodedPublicKey)))
        verifier.update(message)
        assertEquals(true, verifier.verify(signature))
    }

    @Test
    fun rejectsTamperedRfc8032Ed25519Signature() {
        val vector = JSONObject(vectorBytes("valid/ed25519_signature.json").toString(StandardCharsets.UTF_8))
        val publicKey = hexString(vector.getString("publicKeyHex"))
        val signature = hexString(vector.getString("signatureHex")).also { it[0] = (it[0].toInt() xor 1).toByte() }
        val encodedPublicKey = hexString("302a300506032b6570032100") + publicKey
        val verifier = Signature.getInstance("Ed25519")
        verifier.initVerify(KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(encodedPublicKey)))
        verifier.update(hexString(vector.getString("messageHex")))
        assertEquals(false, verifier.verify(signature))
    }

    private fun vectorBytes(path: String, wrappedUtf8: Boolean = false): ByteArray {
        val bytes = File(vectorRoot(), path).readBytes()
        if (!wrappedUtf8) return bytes
        return JSONObject(bytes.toString(StandardCharsets.UTF_8)).getString("value").toByteArray(StandardCharsets.UTF_8)
    }

    private fun hexBytes(path: String): ByteArray = File(vectorRoot(), path).readText().trim().chunked(2)
        .map { it.toInt(16).toByte() }.toByteArray()

    private fun hexString(value: String): ByteArray = value.chunked(2)
        .map { it.toInt(16).toByte() }.toByteArray()

    private fun vectorRoot(): File {
        val workingDirectory = requireNotNull(System.getProperty("user.dir"))
        var current: File? = File(workingDirectory).canonicalFile
        while (current != null) {
            val candidate = File(current, "test_vectors/protocol_v1")
            if (candidate.isDirectory) return candidate
            current = current.parentFile
        }
        error("Protocol V1 vectors are not available")
    }

    private fun assertFails(action: () -> Unit) {
        try {
            action()
            fail("Expected Protocol V1 validation to fail")
        } catch (_: Exception) {
            // Expected: every negative fixture must be rejected before import.
        }
    }
}

private object ProtocolV1VectorVerifier {
    data class ProtocolDocument(
        val vaultId: String,
        val createdAt: String,
        val minimumReaderVersion: Int,
        val minimumWriterVersion: Int,
        val cryptoSuite: String,
    )

    fun parseProtocol(bytes: ByteArray): ProtocolDocument {
        val source = bytes.toString(StandardCharsets.UTF_8)
        require(source.toByteArray(StandardCharsets.UTF_8).contentEquals(bytes)) { "Protocol is not UTF-8" }
        val json = JSONObject(source)
        require(json.optString("protocol") == "velock-sync" && json.optInt("protocolVersion", -1) == 1) {
            "Unsupported protocol document"
        }
        val document = ProtocolDocument(
            vaultId = nonEmpty(json, "vaultId"),
            createdAt = nonEmpty(json, "createdAt"),
            minimumReaderVersion = positive(json, "minimumReaderVersion"),
            minimumWriterVersion = positive(json, "minimumWriterVersion"),
            cryptoSuite = nonEmpty(json, "cryptoSuite"),
        )
        require(source == canonicalProtocol(document)) { "Protocol document is not canonical" }
        return document
    }

    fun isOpaqueId(value: String): Boolean = value.isNotEmpty() &&
        !value.contains('/') && !value.contains('\\') && !value.contains("..")

    fun validateOperations(bytes: ByteArray) {
        val json = JSONObject(bytes.toString(StandardCharsets.UTF_8))
        require(json.optInt("protocolVersion", -1) == 1) { "Unsupported operations document" }
        val operations = json.get("operations") as? JSONArray ?: error("Invalid operations")
        val seen = mutableSetOf<String>()
        for (index in 0 until operations.length()) {
            val operation = operations.getJSONObject(index)
            require(seen.add(nonEmpty(operation, "operationId"))) { "Duplicate operation ID" }
        }
    }

    fun decryptBlob(bytes: ByteArray, vaultId: String, blobId: String, keyId: String): ByteArray {
        require(bytes.size >= 28 && bytes.copyOfRange(0, 4).toString(StandardCharsets.UTF_8) == "VLSB") {
            "Missing VLSB magic"
        }
        require(bytes[4].toInt() == 1 && bytes[5].toInt() == 0 && readUInt32(bytes, 6) == 4 * 1024 * 1024L) {
            "Unsupported VLSB header"
        }
        val plaintextLength = readUInt64(bytes, 10).toInt()
        val headerLength = 28 + readUInt16(bytes, 26)
        require(headerLength <= bytes.size && bytes.copyOfRange(28, headerLength).toString(StandardCharsets.UTF_8) == keyId) {
            "Invalid VLSB key ID"
        }
        var offset = headerLength
        var chunkIndex = 0
        val cleartext = ByteArrayOutputStream()
        while (cleartext.size() < plaintextLength) {
            require(offset + 4 <= bytes.size) { "Truncated chunk length" }
            val chunkLength = readUInt32(bytes, offset).toInt()
            offset += 4
            require(chunkLength > 0 && offset + chunkLength + 16 <= bytes.size) { "Truncated VLSB chunk" }
            val ciphertextWithTag = bytes.copyOfRange(offset, offset + chunkLength + 16)
            val nonce = bytes.copyOfRange(18, 26) + uint32(chunkIndex)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(blobKey(vaultId, blobId), "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(blobAad(vaultId, blobId, chunkIndex, plaintextLength, chunkLength))
            cleartext.write(cipher.doFinal(ciphertextWithTag))
            offset += chunkLength + 16
            chunkIndex += 1
        }
        require(cleartext.size() == plaintextLength && offset == bytes.size) { "Unexpected VLSB trailing data" }
        return cleartext.toByteArray()
    }

    private fun canonicalProtocol(document: ProtocolDocument): String =
        "{\"createdAt\":${JSONObject.quote(document.createdAt)},\"cryptoSuite\":${JSONObject.quote(document.cryptoSuite)}," +
            "\"minimumReaderVersion\":${document.minimumReaderVersion},\"minimumWriterVersion\":${document.minimumWriterVersion}," +
            "\"protocol\":\"velock-sync\",\"protocolVersion\":1,\"vaultId\":${JSONObject.quote(document.vaultId)}}"

    private fun nonEmpty(json: JSONObject, key: String): String = json.optString(key).also { require(it.isNotEmpty()) { "Invalid $key" } }

    private fun positive(json: JSONObject, key: String): Int = json.optInt(key, 0).also { require(it > 0) { "Invalid $key" } }

    private fun blobKey(vaultId: String, blobId: String): ByteArray {
        val vault = vaultId.toByteArray(StandardCharsets.UTF_8)
        val blobRoot = hkdf(ByteArray(32), vault, "velock-sync/v1/blob-root".toByteArray(StandardCharsets.UTF_8))
        return hkdf(blobRoot, vault, "velock-sync/v1/blob/$blobId".toByteArray(StandardCharsets.UTF_8))
    }

    private fun hkdf(input: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(input)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        return mac.doFinal(info + byteArrayOf(1)).copyOf(32)
    }

    private fun blobAad(vaultId: String, blobId: String, index: Int, total: Int, length: Int): ByteArray {
        val vault = vaultId.toByteArray(StandardCharsets.UTF_8)
        val blob = blobId.toByteArray(StandardCharsets.UTF_8)
        return "VLSA".toByteArray(StandardCharsets.UTF_8) + byteArrayOf(1) + uint16(vault.size) + vault +
            uint16(blob.size) + blob + uint32(index) + uint64(total) + uint32(length)
    }

    private fun readUInt16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun readUInt32(bytes: ByteArray, offset: Int): Long = (0 until 4).fold(0L) { value, index ->
        (value shl 8) or (bytes[offset + index].toLong() and 0xff)
    }

    private fun readUInt64(bytes: ByteArray, offset: Int): Long = (0 until 8).fold(0L) { value, index ->
        (value shl 8) or (bytes[offset + index].toLong() and 0xff)
    }

    private fun uint16(value: Int): ByteArray = byteArrayOf((value ushr 8).toByte(), value.toByte())

    private fun uint32(value: Int): ByteArray = ByteArray(4) { index -> (value ushr ((3 - index) * 8)).toByte() }

    private fun uint64(value: Int): ByteArray = ByteArray(8) { index -> (value.toLong() ushr ((7 - index) * 8)).toByte() }
}
