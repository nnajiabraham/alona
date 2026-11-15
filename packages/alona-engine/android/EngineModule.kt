package alona.engine

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import dev.exact.canvas.ExactExtension
import dev.exact.canvas.ExtensionContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class Job(val id: String, val artifact: String, val op: String) {
    val cancelled = AtomicBoolean(false)
    var state = "running"; var progress = 0.0; var text = ""; var error = ""
    val segments = JSONArray()
    @Synchronized fun view() = JSONObject().put("id", id).put("state", state).put("progress", progress)
        .put("text", text).put("error", error).put("segments", JSONArray(segments.toString()))
    fun check() { check(!cancelled.get()) { "Cancelled." } }
}
@androidx.annotation.Keep
internal class Writer(val job: Job) {
    companion object { init { System.loadLibrary("alona_llama") } }
    fun cancelled() = job.cancelled.get()
    fun progress(bytes: ByteArray, fraction: Double) = synchronized(job) { job.text = bytes.toString(Charsets.UTF_8); job.progress = fraction }
    external fun generate(path: String, prompt: ByteArray, limit: Int, threads: Int)
}
class EngineModule(context: ExtensionContext) : ExactExtension(context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val inspector = Executors.newSingleThreadExecutor()
    private val models = ModelStore(File(context.application.noBackupFilesDir, "alona-models"))
    private val jobs = linkedMapOf<String, Job>()
    private val threads = maxOf(1, minOf(8, Runtime.getRuntime().availableProcessors() - 2))
    override fun later(name: String, args: JSONObject, reply: (JSONObject) -> Unit) {
        try {
            require(name == "request")
            val request = JSONObject(args.getString("json"))
            if (request.getString("op") in listOf("installed", "remove")) {
                val op = request.getString("op")
                val artifact = if (op == "remove") Artifact.parse(request.getJSONObject("artifact")) else null
                if (artifact != null) synchronized(this) { jobs.values.filter { it.artifact == artifact.id }.forEach { it.cancelled.set(true) } }
                val executor = if (op == "installed") inspector else worker
                executor.execute {
                    val result = try {
                        if (artifact != null) {
                            require(models.dir(artifact).deleteRecursively()) { "Could not remove model" }
                            synchronized(this) { jobs.entries.removeAll { it.value.artifact == artifact.id && it.value.op == "download" } }
                            JSONObject()
                        } else {
                            val list = request.getJSONArray("artifacts"); val ids = JSONArray()
                            for (i in 0 until list.length()) { val a = Artifact.parse(list.getJSONObject(i)); if (models.installed(a)) ids.put(a.id) }
                            JSONObject().put("ids", ids)
                        }
                    } catch (e: Exception) { JSONObject().put("error", e.message) }
                    main.post { reply(JSONObject().put("json", result.toString())) }
                }
                return
            }
            val result = dispatch(request)
            reply(JSONObject().put("json", result.toString()))
        } catch (e: Exception) { reply(JSONObject().put("json", JSONObject().put("error", e.message ?: "Engine error").toString())) }
    }
    private fun facts(): JSONObject {
        val info = ActivityManager.MemoryInfo()
        (context.application.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
        // totalMem leaves out what the kernel reserves, so a 6 GB phone reports about 5.6. Round it up to
        // the whole gigabyte it is sold as. advertisedMem is not used: where the maker sets no size it
        // rounds up to a power of two, which shows 16 GB for 8.3 and 8 GB for a 6 GB phone.
        val memoryGB = Math.ceil(info.totalMem / 1e9)
        val tablet = context.application.resources.configuration.smallestScreenWidthDp >= 600
        return JSONObject().put("host", "android").put("memoryGB", memoryGB)
            .put("cores", Runtime.getRuntime().availableProcessors()).put("storageFreeGB", StatFs(context.application.filesDir.path).availableBytes / 1e9)
            .put("gpu", false).put("gpuMaxBufferGB", 0).put("formFactor", if (tablet) "desktop" else "phone")
            .put("appleSilicon", false).put("iosBrowser", false).put("description", "${Build.MODEL} · Android ${Build.VERSION.RELEASE}")
            .also { if (context.agent || File(context.data, "demo-engine").exists()) it.put("demo", true).put("demoReason", "Demo engine selected for flow captures.") }
    }
    @Synchronized private fun dispatch(r: JSONObject): JSONObject = when (val op = r.getString("op")) {
        "probe" -> facts()
        "job" -> jobs[r.getString("job")]?.view() ?: JSONObject().put("id", r.getString("job")).put("state", "unknown").put("progress", 0).put("text", "").put("segments", JSONArray()).put("error", "")
        "cancel" -> JSONObject().also { jobs[r.getString("job")]?.cancelled?.set(true) }
        "download", "transcribe", "generate" -> {
            val a = Artifact.parse(r.getJSONObject("artifact")); val id = r.getString("job"); require(id.isNotBlank())
            val existing = jobs[id]
            if (existing != null && existing.view().getString("state") in listOf("running", "done")) existing.view()
            else {
                val job = Job(id, a.id, op); jobs[id] = job
                worker.execute {
                    try {
                        job.check()
                        if (op == "download") models.download(a, job::check) { p -> synchronized(job) { job.progress = p } }
                        else {
                            require(models.installed(a)) { "Model is not installed or its checksum failed" }
                            if (op == "transcribe") Speech.transcribe(a, models, audio(r.getString("audio")), job, threads)
                            else {
                                require(a.runtime == "llama")
                                Writer(job).generate(models.path(a, "model.gguf"), r.getString("prompt").toByteArray(Charsets.UTF_8), r.getInt("maxTokens"), threads)
                            }
                        }
                        job.check(); synchronized(job) { job.state = "done"; job.progress = 1.0 }
                    } catch (e: Throwable) { synchronized(job) { job.state = "failed"; job.error = e.message ?: e.javaClass.simpleName } }
                    synchronized(this) {
                        jobs.entries.filter { it.value.view().getString("state") != "running" }.dropLast(64).forEach { jobs.remove(it.key) }
                    }
                }
                job.view()
            }
        }
        "unload" -> JSONObject() // Each inference call releases its native resources before finishing.
        else -> error("Unknown engine operation: $op")
    }
    private fun audio(path: String): File {
        require(path.startsWith("app:/data/meetings/")) { "Audio must be a meeting file" }
        val file = File(context.data, path.removePrefix("app:/data/")).canonicalFile
        require(file.path.startsWith(File(context.data, "meetings").canonicalPath + File.separator) && file.isFile)
        return file
    }
    override fun destroy(done: () -> Unit) {
        synchronized(this) { jobs.values.forEach { it.cancelled.set(true) } }
        worker.shutdown(); inspector.shutdown(); done()
    }
}
