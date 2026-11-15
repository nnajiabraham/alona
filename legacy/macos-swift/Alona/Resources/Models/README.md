# Whisper Model Files

Alona expects the Whisper `ggml-base.en.bin` checkpoint to be bundled inside the app so offline transcription works out of the box. The weights are fairly large (~142 MB), so we do not commit them to the repository.

## Download

Use the Makefile helper to download/update the model into `Alona/Resources/Models/`:

```bash
make download-model
```

This runs `curl` against the official Hugging Face mirror and writes the file to:

```
Alona/Resources/Models/ggml-base.en.bin
```

## Build Integration

The entire `Resources/Models` folder is copied into the final app bundle as part of the Xcode build, so any `.bin` dropped here will automatically be accessible via:

```swift
Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin")
```

If the file is missing at runtime, the transcription engine reports a clear error and suggests running `make download-model`.
