#!/usr/bin/env python3
"""Package native slices with verified source archives and relinking objects."""
from pathlib import Path
import hashlib, json, tarfile, urllib.request, zipfile
root = Path(__file__).resolve().parents[1]
out = root / 'Artifacts'
framework = out / 'CMVC.xcframework'
if not framework.exists(): raise SystemExit('Run Scripts/build_native.py first')
archive = out / 'CMVC.xcframework.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as target:
    for source in sorted(framework.rglob('*')):
        if source.is_file():
            info = zipfile.ZipInfo(str(source.relative_to(out)), date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(info, source.read_bytes())
dependencies = json.loads((root / 'dependencies.json').read_text())
materials = out / 'CMVC-source-and-relink.tar.gz'
with tarfile.open(materials, 'w:gz') as target:
    # Package pristine, checksum-verified sources rather than local build caches.
    for name, dependency in dependencies.items():
        source = root / '.build/downloads' / (name + '-' + dependency['revision'] + '.tar.gz')
        source.parent.mkdir(parents=True, exist_ok=True)
        if not source.exists():
            urllib.request.urlretrieve('https://codeload.github.com/' + dependency['repository'] + '/tar.gz/' + dependency['revision'], source)
        if hashlib.sha256(source.read_bytes()).hexdigest() != dependency['sha256']:
            raise SystemExit('Source archive checksum mismatch: ' + name)
        with tarfile.open(source) as upstream:
            prefix = upstream.getmembers()[0].name.split('/')[0] + '/'
            for item in upstream:
                if not item.name.startswith(prefix): continue
                suffix = item.name[len(prefix):]
                if not suffix: continue
                stream = upstream.extractfile(item) if item.isfile() else None
                item.name = 'Vendor/' + name + '/' + suffix
                target.addfile(item, stream)
    for name in ['Sources/CMVC', 'Sources/Notices', 'Scripts/build_native.py',
                 'Scripts/package_native.py', 'dependencies.json', 'THIRD_PARTY_NOTICES.md', 'LICENSE']:
        target.add(root / name, arcname=name)
    for platform in ['macos', 'visionos', 'simulator']:
        native = root / '.build/native' / platform
        for source in [native / 'edge.o', native / 'bridge.o', native / 'libCMVC.a']:
            target.add(source, arcname=str(source.relative_to(root)))
        for source in sorted((native / 'ffmpeg/lib').glob('*.a')):
            target.add(source, arcname=str(source.relative_to(root)))
        target.add(native / 'ffmpeg/include', arcname=str((native / 'ffmpeg/include').relative_to(root)))
manifest = {'dependencies': dependencies,
            'sha256': {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in [archive, materials]}}
(out / 'native-artifact.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest['sha256'], indent=2))
