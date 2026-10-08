#!/usr/bin/env bash
#
# inject-ipa.sh — инъекция твика YouTubePlus.dylib в ваш собственный YouTube.ipa.
#
# ВАЖНО: на вход нужен НЕзашифрованный (decrypted) YouTube.ipa, снятый с вашего
# собственного устройства. Репозиторий не поставляет базовый .ipa.
#
# Использование:
#   ./scripts/inject-ipa.sh YouTube.ipa YouTubePlus.dylib out.ipa
#
set -euo pipefail

BASE_IPA="${1:?usage: inject-ipa.sh <base.ipa> <tweak.dylib> <out.ipa>}"
TWEAK_DYLIB="${2:?missing tweak dylib}"
OUT_IPA="${3:?missing output path}"

[[ -f "$BASE_IPA"   ]] || { echo "no such ipa: $BASE_IPA"; exit 1; }
[[ -f "$TWEAK_DYLIB" ]] || { echo "no such dylib: $TWEAK_DYLIB"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unzip"
unzip -q "$BASE_IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$APP" ]] || { echo "Payload/*.app not found"; exit 1; }
BIN="$APP/$(basename "$APP" .app)"
echo "    app: $APP"
echo "    bin: $BIN"

echo "==> copy dylib"
cp "$TWEAK_DYLIB" "$APP/YouTubePlus.dylib"

echo "==> inject load command"
if command -v optool >/dev/null 2>&1; then
  optool install -c load -p "@executable_path/YouTubePlus.dylib" -t "$BIN"
elif command -v insert_dylib >/dev/null 2>&1; then
  insert_dylib --strip-codesig --inplace "@executable_path/YouTubePlus.dylib" "$BIN"
else
  echo "ERROR: нужен optool или insert_dylib (brew install optool / insert_dylib)." >&2
  exit 1
fi

echo "==> codesign (adhoc, если доступен ldid/codesign)"
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$BIN" || true
  ldid -S "$APP/YouTubePlus.dylib" || true
elif command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP/YouTubePlus.dylib" || true
  codesign --force --sign - "$APP/Frameworks/"* 2>/dev/null || true
  codesign --force --sign - "$APP" || true
fi

echo "==> repack"
( cd "$WORK" && zip -qry "$OLDPWD/$OUT_IPA" Payload )
echo "==> done: $OUT_IPA"
