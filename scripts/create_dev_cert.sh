#!/bin/bash
# Создаёт один раз локальный самоподписанный сертификат для подписи кода.
#
# Зачем: ./build_app.sh подписывает Snowfall.app ad-hoc (`codesign --sign -`).
# У ad-hoc подписи на каждой сборке новая "личность", и macOS связывает
# разрешение в Универсальном доступе (нужное для снега на Dock) именно с этой
# личностью. Поэтому после каждой пересборки разрешение приходится выдавать
# заново — Dock может казаться разрешённым в Настройках, а снег всё равно не
# появляется, потому что текущий бинарник уже не тот, что получил разрешение.
#
# Этот скрипт один раз создаёт стабильный сертификат в связке ключей; дальше
# build_app.sh сам найдёт его и будет подписывать им — личность перестанет
# меняться между сборками, и разрешение Dock перестанет слетать.
set -euo pipefail

NAME="SnowfallMac Local Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Сертификат «$NAME» уже есть в связке ключей — ничего делать не нужно."
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Этот скрипт нужно запускать на Mac." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

echo "==> создаю ключ и сертификат"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.conf" -extensions ext

openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:snowfall -legacy 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:snowfall

echo "==> добавляю в связку ключей (может спросить пароль от связки или подтверждение)"
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P snowfall -T /usr/bin/codesign -A

echo "==> доверяю сертификату для подписи кода"
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo
echo "Готово. Сертификат «$NAME» добавлен и доверен для подписи кода."
echo "Теперь запусти ./build_app.sh заново — он подпишет этим сертификатом,"
echo "и после этого выдай разрешение на Dock в Универсальном доступе один раз."
