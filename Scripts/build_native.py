#!/usr/bin/env python3
"""Pinned, source-built FFmpeg + edge264-mvc + CMVC for macOS and visionOS."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'dependencies.json').read_text())
PLATFORMS = {
    'macos': ('macosx', 'arm64-apple-macos13.0'),
    'visionos': ('xros', 'arm64-apple-xros26.0'),
    'simulator': ('xrsimulator', 'arm64-apple-xros26.0-simulator'),
}

def run(args, cwd=None, log=None):
    print('+', ' '.join(map(str, args)), flush=True)
    if log:
        with open(log, 'w') as stream:
            result = subprocess.run(list(map(str, args)), cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            print(pathlib.Path(log).read_text()[-10000:])
            raise SystemExit(f'Failed; see {log}')
    else:
        subprocess.run(list(map(str, args)), cwd=cwd, check=True)

def source(name, destination):
    info = LOCK[name]
    stamp = destination / '.openimmersive-revision'
    if stamp.exists() and stamp.read_text().strip() == info['revision']:
        return destination
    archive = ROOT / '.build/downloads' / (name + '-' + info['revision'] + '.tar.gz')
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        urllib.request.urlretrieve(f"https://codeload.github.com/{info['repository']}/tar.gz/{info['revision']}", archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if info.get('sha256') and digest != info['sha256']:
        raise SystemExit('Source archive checksum mismatch: ' + name)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        prefix = tar.getmembers()[0].name.split('/')[0] + '/'
        for member in tar.getmembers():
            if not member.name.startswith(prefix):
                continue
            member.name = member.name[len(prefix):]
            if member.name:
                tar.extract(member, destination, filter='data')
    stamp.write_text(info['revision'] + '\n')
    print(f'{name}: {info["revision"]} sha256={digest}', flush=True)
    return destination

def build(platform, deps_only):
    sdk, triple = PLATFORMS[platform]
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    cc = subprocess.check_output(['xcrun', '--sdk', sdk, '--find', 'clang'], text=True).strip()
    out = ROOT / '.build/native' / platform
    out.mkdir(parents=True, exist_ok=True)
    prefix = out / 'ffmpeg'
    config = [
        '--target-os=darwin', '--arch=aarch64', '--enable-cross-compile', f'--cc={cc}',
        f'--sysroot={sdk_path}', f'--extra-cflags=-target {triple}', f'--extra-ldflags=-target {triple}',
        f'--prefix={prefix}', '--disable-autodetect', '--disable-everything', '--disable-programs',
        '--disable-doc', '--disable-debug', '--disable-network', '--disable-avdevice', '--disable-avfilter',
        '--disable-swscale', '--disable-shared', '--enable-static', '--enable-pic', '--enable-small',
        '--disable-gpl', '--disable-nonfree', '--enable-zlib', '--enable-demuxer=matroska',
        '--enable-decoder=ac3,eac3,dca,truehd,mlp,aac,flac,mp3,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_bluray',
        '--enable-parser=aac,ac3,dca,mlp,flac,mpegaudio', '--enable-swresample',
    ]
    if not (prefix / 'lib/libavformat.a').exists():
        work = out / 'ffmpeg-build'
        work.mkdir(exist_ok=True)
        run([ROOT / 'Vendor/ffmpeg/configure'] + config, cwd=work, log=out / 'configure.log')
        run(['make', '-j', str(min(8, os.cpu_count() or 4))], cwd=work, log=out / 'ffmpeg.log')
        run(['make', 'install'], cwd=work, log=out / 'install.log')
    if deps_only:
        return
    flags = ['-target', triple, '-isysroot', sdk_path, '-O3', '-std=gnu11', '-fwrapv',
             '-flax-vector-conversions', '-Wno-override-init', '-fvisibility=hidden',
             '-I' + str(ROOT / 'Vendor/edge264-mvc'), '-I' + str(prefix / 'include'),
             '-I' + str(ROOT / 'Sources/CMVC/include')]
    edge = out / 'edge.o'
    bridge = out / 'bridge.o'
    run([cc] + flags + ['-c', ROOT / 'Vendor/edge264-mvc/src/edge264mvc.c', '-o', edge], log=out / 'edge.log')
    run([cc] + flags + ['-Wall', '-Wextra', '-Werror=return-type', '-c', ROOT / 'Sources/CMVC/mvc.c', '-o', bridge], log=out / 'bridge.log')
    lib = out / 'libCMVC.a'
    run(['xcrun', 'libtool', '-static', '-o', lib, edge, bridge] + sorted((prefix / 'lib').glob('*.a')), log=out / 'archive.log')
    headers = out / 'Headers'
    headers.mkdir(exist_ok=True)
    shutil.copy(ROOT / 'Sources/CMVC/include/CMVC.h', headers)
    (headers / 'module.modulemap').write_text('module CMVC { header "CMVC.h" export * link "z" link "iconv" }\n')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--platform', choices=['all'] + list(PLATFORMS), default='all')
    p.add_argument('--deps-only', action='store_true')
    a = p.parse_args()
    source('edge264-mvc', ROOT / 'Vendor/edge264-mvc')
    source('ffmpeg', ROOT / 'Vendor/ffmpeg')
    platforms = list(PLATFORMS) if a.platform == 'all' else [a.platform]
    for platform in platforms:
        build(platform, a.deps_only)
    if a.platform == 'all' and not a.deps_only:
        artifact = ROOT / 'Artifacts/CMVC.xcframework'
        if artifact.exists():
            shutil.rmtree(artifact)
        artifact.parent.mkdir(exist_ok=True)
        args = ['xcodebuild', '-create-xcframework']
        for platform in platforms:
            out = ROOT / '.build/native' / platform
            args += ['-library', out / 'libCMVC.a', '-headers', out / 'Headers']
        run(args + ['-output', artifact])

if __name__ == '__main__':
    main()
