#!/usr/bin/env python3
"""Run host-side regression tests against the production core sources.

Run build_native.py first. Staging avoids adding macOS to the visionOS UI product.
"""
from pathlib import Path
import shutil, subprocess
root = Path(__file__).resolve().parents[1]
stage = root / '.build/core-validation'
stage.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Validation/Package.swift', stage / 'Package.swift')
for name in ['Sources', 'Tests', 'Scripts', 'Vendor', 'Artifacts']:
    link = stage / name
    if not link.exists(): link.symlink_to(root / name, target_is_directory=True)
# SwiftPM uses only the named core target and tests, ignoring visionOS UI sources.
(stage / '.build').mkdir(exist_ok=True)
link = stage / '.build/native'
if not link.exists(): link.symlink_to(root / '.build/native', target_is_directory=True)
subprocess.run(['swift', 'test', '--package-path', str(stage)], check=True)
