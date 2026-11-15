package alona.engine

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.k2fsa.sherpa.onnx.*
import org.json.JSONObject
import java.io.File
import java.nio.ByteOrder

internal object Speech {
    fun transcribe(a: Artifact, store: ModelStore, audio: File, job: Job, threads: Int) {
        val config = OfflineModelConfig(tokens = store.path(a, "tokens.txt"), numThreads = threads, provider = "cpu")
        when (a.runtime) {
            "sherpa-moonshine" -> config.moonshine = OfflineMoonshineModelConfig(encoder = store.path(a, "encoder_model.ort"), mergedDecoder = store.path(a, "decoder_model_merged.ort"))
            "sherpa-transducer" -> {
                config.transducer = OfflineTransducerModelConfig(encoder = store.path(a, "encoder.int8.onnx"), decoder = store.path(a, "decoder.int8.onnx"), joiner = store.path(a, "joiner.int8.onnx"))
                config.modelType = "nemo_transducer"
            }
            else -> error("Unsupported speech runtime")
        }
        val recognizer = OfflineRecognizer(config = OfflineRecognizerConfig(modelConfig = config))
        try {
            val vad = Vad(config = VadModelConfig(sileroVadModelConfig = SileroVadModelConfig(model = store.path(a, "silero_vad.onnx"), minSilenceDuration = 0.4f, minSpeechDuration = 0.25f, maxSpeechDuration = 20f), sampleRate = 16000, numThreads = 1))
            try {
                fun drain() {
                    while (!vad.empty()) {
                        job.check(); val segment = vad.front(); vad.pop()
                        val stream = recognizer.createStream()
                        val text = try { stream.acceptWaveform(segment.samples, 16000); recognizer.decode(stream); recognizer.getResult(stream).text.trim() } finally { stream.release() }
                        if (text.isNotEmpty()) synchronized(job) {
                            job.segments.put(JSONObject().put("start", segment.start / 16000.0).put("end", (segment.start + segment.samples.size) / 16000.0).put("text", text))
                            job.text = if (job.text.isEmpty()) text else job.text + " " + text
                        }
                    }
                }
                val window = FloatArray(512); var count = 0
                decode(audio, job) { sample ->
                    window[count++] = sample
                    if (count == window.size) { vad.acceptWaveform(window); count = 0; drain() }
                }
                if (count > 0) { java.util.Arrays.fill(window, count, window.size, 0f); vad.acceptWaveform(window) }
                vad.flush(); drain()
            } finally { vad.release() }
        } finally { recognizer.release() }
    }

    private fun decode(file: File, job: Job, sample: (Float) -> Unit) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true } ?: error("No audio track")
            extractor.selectTrack(track); val input = extractor.getTrackFormat(track)
            val decoder = MediaCodec.createDecoderByType(input.getString(MediaFormat.KEY_MIME)!!); codec = decoder
            decoder.configure(input, null, null, 0); decoder.start()
            val duration = if (input.containsKey(MediaFormat.KEY_DURATION)) input.getLong(MediaFormat.KEY_DURATION) else 0L
            var channels = input.getInteger(MediaFormat.KEY_CHANNEL_COUNT); var rate = input.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var inputDone = false; var outputDone = false
            var sourceFrame = 0L; var targetFrame = 0L; var previous = 0f
            val info = MediaCodec.BufferInfo()
            while (!outputDone) {
                job.check()
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)!!; val n = extractor.readSampleData(buffer, 0)
                        if (n < 0) { decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { decoder.queueInputBuffer(index, 0, n, extractor.sampleTime, 0); extractor.advance() }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val format = decoder.outputFormat
                    rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE); channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) format.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                    require(encoding == AudioFormat.ENCODING_PCM_16BIT || encoding == AudioFormat.ENCODING_PCM_FLOAT) { "Unsupported PCM encoding" }
                } else if (index >= 0) {
                    try {
                        val buffer = decoder.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                        buffer.position(info.offset); buffer.limit(info.offset + info.size)
                        val frameBytes = channels * if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                        while (buffer.remaining() >= frameBytes) {
                            var mono = 0f
                            repeat(channels) { mono += if (encoding == AudioFormat.ENCODING_PCM_FLOAT) buffer.float else buffer.short / 32768f }
                            mono /= channels
                            // Carry interpolation phase across codec buffers to avoid dropped boundary samples.
                            while (targetFrame * rate.toDouble() / 16000 <= sourceFrame) {
                                val pos = targetFrame * rate.toDouble() / 16000
                                sample(if (sourceFrame == 0L) mono else previous + (mono - previous) * (pos - (sourceFrame - 1)).toFloat())
                                targetFrame++
                            }
                            previous = mono; sourceFrame++
                        }
                        if (duration > 0) synchronized(job) { job.progress = minOf(0.99, info.presentationTimeUs.toDouble() / duration) }
                        outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    } finally { decoder.releaseOutputBuffer(index, false) }
                }
            }
        } finally { codec?.let { try { it.stop() } finally { it.release() } }; extractor.release() }
    }
}
