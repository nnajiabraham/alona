#!/usr/bin/env python3
"""Build the runtime AARs in two independent paths and compare their bytes."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
out = root / 'docs/media/android-real'
out.mkdir(parents=True, exist_ok=True)
artifacts = ['com/alona/local/llama/b12383/llama-b12383.aar', 'com/alona/local/sherpa/2.0.1/sherpa-2.0.1.aar']
with (out / 'runtime-repro.log').open('w') as log:
    subprocess.run(['python3', str(root / 'tools/build-android-runtimes.py')], stdout=log, stderr=subprocess.STDOUT, check=True)
    with tempfile.TemporaryDirectory(prefix='alona-runtime-repro-') as temporary:
        other = pathlib.Path(temporary)
        (other / 'tools').mkdir()
        (other / 'packages/alona-engine').mkdir(parents=True)
        shutil.copyfile(root / 'tools/build-android-runtimes.py', other / 'tools/build-android-runtimes.py')
        shutil.copytree(root / 'packages/alona-engine/native', other / 'packages/alona-engine/native')
        cache = other / '.exact/android-runtimes'
        cache.mkdir(parents=True)
        for name in ['sherpa.aar', 'llama.tar.gz']:
            shutil.copyfile(root / '.exact/android-runtimes' / name, cache / name)
        subprocess.run(['python3', str(other / 'tools/build-android-runtimes.py')], stdout=log, stderr=subprocess.STDOUT, check=True)
        results = []
        for name in artifacts:
            def digest(base):
                with (base / '.exact/android-maven' / name).open('rb') as source:
                    return hashlib.file_digest(source, 'sha256').hexdigest()
            original, independent = digest(root), digest(other)
            results.append({'artifact': name, 'checkoutSha256': original, 'independentPathSha256': independent, 'match': original == independent})
(out / 'runtime-repro.json').write_text(json.dumps(results, indent=2) + '\n')
for result in results:
    print(result['artifact'], result['checkoutSha256'], 'MATCH' if result['match'] else 'MISMATCH')
if not all(result['match'] for result in results):
    raise SystemExit(1)
