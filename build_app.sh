#!/bin/bash
# Собирает Snowfall.app без Xcode-проекта: Swift Package Manager + ad-hoc подпись.
# Нужен Mac с Swift (достаточно Command Line Tools: xcode-select --install).
#
#   ./build_app.sh               сборка под архитектуру этого Mac
#   ./build_app.sh --universal   Apple Silicon + Intel (нужен полный Xcode)
#   ./build_app.sh --run         собрать и сразу запустить
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

UNIVERSAL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --run) RUN=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Неизвестный параметр: $arg" >&2; exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Ошибка: приложение для macOS можно собрать только на Mac." >&2
  echo "Без Mac: GitHub → вкладка Actions → последний запуск → Artifacts → SnowfallMac-universal." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Ошибка: swift не найден. Выполни в Терминале: xcode-select --install" >&2
  exit 1
fi

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build (release)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/SnowfallMac"
[[ -f "$BIN" ]] || { echo "Не найден бинарник: $BIN" >&2; exit 2; }

APP="$ROOT/dist/Snowfall.app"
echo "==> упаковка $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SnowfallMac"
sed 's/\$(EXECUTABLE_NAME)/SnowfallMac/g' "$ROOT/SnowfallMac/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc подпись: аккаунт Apple Developer не нужен.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Архитектуры: $(lipo -archs "$APP/Contents/MacOS/SnowfallMac")"
echo "Готово: $APP"

if [[ "$RUN" == "1" ]]; then
  pkill -x SnowfallMac 2>/dev/null || true
  open "$APP"
fi
