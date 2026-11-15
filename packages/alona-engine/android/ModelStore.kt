package alona.engine

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection

internal data class Pin(val name: String, val url: String, val bytes: Long, val sha: String)
internal data class Artifact(val id: String, val runtime: String, val files: List<Pin>) {
    companion object {
        fun component(s: String): String {
            require(s.matches(Regex("[A-Za-z0-9_.-]+")) && s != "." && s != "..") { "Invalid model path" }
            return s
        }
        fun parse(j: JSONObject): Artifact {
            val list = j.getJSONArray("files")
            require(list.length() > 0) { "Model requires pinned files" }
            val files = (0 until list.length()).map { i ->
                val f = list.getJSONObject(i)
                val url = f.getString("url"); require(URL(url).protocol == "https")
                val size = f.getLong("bytes"); require(size > 0)
                val sha = f.getString("sha256"); require(sha.matches(Regex("[a-f0-9]{64}")))
                Pin(component(f.getString("name")), url, size, sha)
            }
            require(files.map { it.name }.distinct().size == files.size)
            return Artifact(component(j.getString("id")), j.getString("runtime"), files)
        }
    }
}
internal class ModelStore(val root: File) {
    fun dir(a: Artifact) = File(root, a.id)
    fun path(a: Artifact, name: String) = File(dir(a), name).path
    fun verified(f: File, pin: Pin): Boolean {
        if (!f.isFile || f.length() != pin.bytes) return false
        val digest = MessageDigest.getInstance("SHA-256")
        f.inputStream().buffered().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } == pin.sha
    }
    fun installed(a: Artifact) = a.files.all { verified(File(dir(a), it.name), it) }
    fun download(a: Artifact, check: () -> Unit, progress: (Double) -> Unit) {
        dir(a).mkdirs()
        var before = 0L; val total = a.files.sumOf { it.bytes }.toDouble()
        for (pin in a.files) {
            check()
            val dest = File(dir(a), pin.name); val part = File(dir(a), pin.name + ".part")
            if (!verified(dest, pin)) {
                if (part.length() > pin.bytes) part.delete()
                var have = part.length()
                if (have < pin.bytes) {
                    var url = URL(pin.url); var redirects = 0
                    var connection: HttpsURLConnection
                    while (true) {
                        require(url.protocol == "https") { "Insecure model redirect" }
                        connection = url.openConnection() as HttpsURLConnection
                        connection.connectTimeout = 30000; connection.readTimeout = 30000
                        connection.instanceFollowRedirects = false
                        if (have > 0) connection.setRequestProperty("Range", "bytes=$have-")
                        val code = connection.responseCode
                        if (code in listOf(301, 302, 303, 307, 308)) {
                            val location = connection.getHeaderField("Location"); connection.disconnect()
                            require(++redirects <= 10 && location != null) { "Invalid model redirect" }
                            url = URL(url, location); continue
                        }
                        require(code == 200 || code == 206) { "Model download HTTP $code" }
                        if (code == 206) require(connection.getHeaderField("Content-Range")?.startsWith("bytes $have-") == true) { "Invalid resumed range" }
                        else have = 0
                        break
                    }
                    try {
                        connection.inputStream.use { input -> FileOutputStream(part, have > 0).use { out ->
                            val buffer = ByteArray(256 * 1024)
                            while (true) {
                                check(); val n = input.read(buffer); if (n < 0) break
                                require(have + n <= pin.bytes) { "Model exceeds pinned size" }
                                out.write(buffer, 0, n); have += n; progress((before + have) / total)
                            }
                            out.fd.sync()
                        } }
                    } finally { connection.disconnect() }
                }
                if (!verified(part, pin)) { part.delete(); error("Model checksum mismatch") }
                require(part.renameTo(dest)) { "Could not install model" }
            }
            before += pin.bytes; progress(before / total)
        }
    }
}
