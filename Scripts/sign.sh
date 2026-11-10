#!/bin/zsh
# Signs "Velum.app" with a stable, local self-signed identity, so macOS keeps its Accessibility
# permission across rebuilds (ad-hoc signatures change on every build, which voids the permission).
# The identity lives in its own keychain file below, not in the login keychain and not in the keychain
# search list. It is created on first run and never leaves this Mac.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/Velum.app" >&2
  exit 2
fi

APP=$1
IDENTITY="Velum Local Signing"
SIGNING_DIR="${HOME}/Library/Application Support/Velum/Signing"
KEYCHAIN="$SIGNING_DIR/LocalSigning.keychain"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

if [[ ! -f "$KEYCHAIN" ]]; then
  SEARCH_LIST_BEFORE=$(security list-keychains -d user)
  umask 077
  openssl rand -hex 32 > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  printf '%s\n' \
    '[req]' \
    'distinguished_name=dn' \
    'x509_extensions=ext' \
    'prompt=no' \
    '[dn]' \
    "CN=$IDENTITY" \
    'O=Velum (local build)' \
    '[ext]' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=codeSigning' \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid:always' \
    > "$WORK/openssl.cnf"

  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" \
    -out "$WORK/cert.pem" \
    >/dev/null 2>&1
  PASSWORD=$(<"$PASSWORD_FILE")
  # OpenSSL 3+ needs -legacy for a PKCS#12 that `security import` accepts; macOS's own LibreSSL already
  # writes that format and doesn't know the flag.
  LEGACY=()
  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi
  openssl pkcs12 -export "${LEGACY[@]}" \
    -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" \
    -passout "pass:$PASSWORD"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign \
    >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$PASSWORD" \
    "$KEYCHAIN" \
    >/dev/null
  security set-keychain-settings -lut 300 "$KEYCHAIN"

  # Keep the user's keychain search list exactly as it was.
  if [[ "$(security list-keychains -d user)" != "$SEARCH_LIST_BEFORE" ]]; then
    eval "security list-keychains -d user -s $SEARCH_LIST_BEFORE"
  fi
fi

if [[ ! -f "$PASSWORD_FILE" ]]; then
  echo "Missing signing keychain password file: $PASSWORD_FILE" >&2
  exit 1
fi

PASSWORD=$(<"$PASSWORD_FILE")
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
trap 'security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true' EXIT
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier io.github.nafatyuk.velum "$APP"
codesign --verify --strict "$APP"
security lock-keychain "$KEYCHAIN"
trap - EXIT
