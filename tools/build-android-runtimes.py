#!/usr/bin/env python3
"""Fetch pinned upstream sources and assemble arm64 AARs into .exact/android-maven."""
import hashlib, os, pathlib, subprocess, tarfile, urllib.request, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
work = root / '.exact/android-runtimes'; work.mkdir(parents=True, exist_ok=True)
repo = root / '.exact/android-maven'
def fetch(name, url, sha):
    p = work / name
    if not p.exists(): urllib.request.urlretrieve(url, p)
    if hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() != sha: raise RuntimeError('Checksum mismatch: ' + name)
    return p
def publish(name, version, aar):
    dest = repo / 'com/alona/local' / name / version; dest.mkdir(parents=True, exist_ok=True)
    (dest / f'{name}-{version}.aar').write_bytes(aar.read_bytes())
    (dest / f'{name}-{version}.pom').write_text(f'<project><modelVersion>4.0.0</modelVersion><groupId>com.alona.local</groupId><artifactId>{name}</artifactId><version>{version}</version><packaging>aar</packaging></project>')
sherpa = fetch('sherpa.aar', 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar', 'a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7')
publish('sherpa', '2.0.1', sherpa)
archive = fetch('llama.tar.gz', 'https://github.com/ggml-org/llama.cpp/archive/refs/tags/b12383.tar.gz', '20566a281df9047ea6c8d96213c6da8e225fb30d7fb32c00208531da9a13ddb6')
source = work / 'llama.cpp-b12383'
if not source.exists():
    with tarfile.open(archive) as t: t.extractall(work, filter='data')
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', pathlib.Path.home() / 'Library/Android/sdk'))
cmake = sorted((sdk / 'cmake').glob('*/bin/cmake'))[-1]
build = work / 'build'
subprocess.run([str(cmake), '-S', str(root / 'packages/alona-engine/native'), '-B', str(build), '-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM='+str(cmake.parent/'ninja'), '-DCMAKE_TOOLCHAIN_FILE='+str(sdk/'ndk/27.1.12297006/build/cmake/android.toolchain.cmake'), '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-31', '-DANDROID_STL=c++_static', '-DCMAKE_BUILD_TYPE=Release', '-DLLAMA_SOURCE='+str(source)], check=True)
subprocess.run([str(cmake), '--build', str(build), '--target', 'alona_llama', '-j', '6'], check=True)
aar = work / 'llama.aar'
with zipfile.ZipFile(aar, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('AndroidManifest.xml', '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.alona.llama"/>')
    z.write(build/'libalona_llama.so', 'jni/arm64-v8a/libalona_llama.so')
publish('llama', 'b12383', aar)
print(repo)
