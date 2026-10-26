#!/usr/bin/env python3
"""Package the built native slices with matching source and relinking objects."""
from pathlib import Path
import hashlib, json, tarfile, zipfile
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
materials = out / 'CMVC-source-and-relink.tar.gz'
with tarfile.open(materials, 'w:gz') as target:
    for name in ['Vendor/edge264-mvc', 'Vendor/ffmpeg', 'Sources/CMVC', 'Sources/Notices',
                 'Scripts/build_native.py', 'Scripts/package_native.py', 'dependencies.json',
                 'THIRD_PARTY_NOTICES.md', 'LICENSE']:
        target.add(root / name, arcname=name)
    for platform in ['macos', 'visionos', 'simulator']:
        native = root / '.build/native' / platform
        for source in sorted(native.iterdir()):
            if source.suffix in ['.o', '.a'] or source.name == 'ffmpeg':
                target.add(source, arcname=str(source.relative_to(root)))
manifest = {'dependencies': json.loads((root / 'dependencies.json').read_text()),
            'sha256': {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in [archive, materials]}}
(out / 'native-artifact.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest['sha256'], indent=2))
