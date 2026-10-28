#!/usr/bin/env python3
"""Run portable range-reader tests without the visionOS UI or native decoder."""
from pathlib import Path
import shutil, subprocess
root = Path(__file__).resolve().parents[1]
stage = root / '.build/transport-validation'
stage.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Validation/Transport/Package.swift', stage / 'Package.swift')
for name in ['Sources', 'Tests', 'Scripts']:
    link = stage / name
    if not link.exists(): link.symlink_to(root / name, target_is_directory=True)
subprocess.run(['swift', 'test', '--package-path', str(stage)], check=True)
