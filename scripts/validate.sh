#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v swiftc >/dev/null 2>&1 || { echo "swiftc не найден. Установи Xcode Command Line Tools." >&2; exit 1; }
echo "==> Swift syntax"
swiftc -frontend -parse SnowfallMac/Sources/*.swift
echo "==> Info.plist"
plutil -lint SnowfallMac/Info.plist
echo "==> VS Code tasks"
python3 -m json.tool .vscode/tasks.json >/dev/null
echo "==> Build script"
bash -n build_app.sh
bash -n scripts/create_dev_cert.sh
echo "==> Physics sanity"
python3 scripts/physics_sanity.py
echo "==> Validation passed (syntax/configuration and arithmetic checks only; native build is a separate task)."
