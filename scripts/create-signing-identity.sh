#!/bin/bash
# Creates a persistent self-signed code-signing identity in the login keychain.
# Ad-hoc signatures change every build, so macOS TCC permissions (Screen
# Recording, Accessibility) reset on each rebuild. A stable certificate gives
# the app a stable code requirement, so grants survive rebuilds. The identity
# is self-signed: it stays local and is not trusted by Gatekeeper, which is
# unchanged from the ad-hoc workflow. Re-running is a no-op.
set -euo pipefail

IDENTITY="${BOOX_SIGN_IDENTITY:-BOOX Sidecar Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# `find-identity` without -v lists self-signed identities; -v hides them as
# untrusted, which is expected — codesign can still use them.
if security find-identity "$KEYCHAIN" 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  echo "Signing identity '$IDENTITY' already exists."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/boox-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/req.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = BOOX Sidecar Dev
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/req.cnf" >/dev/null 2>&1

PASS="$(openssl rand -hex 12)"
# macOS `security import` cannot verify the OpenSSL-3 default SHA-256 MAC;
# -legacy (SHA1 MAC, 3DES/RC2 wrapping) is accepted. The wrapper is transport
# packaging only — the certificate itself stays SHA-256/RSA-2048.
if openssl pkcs12 -help 2>&1 | grep -q "legacy"; then
  openssl pkcs12 -export -legacy -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout "pass:$PASS"
else
  openssl pkcs12 -export -macalg sha1 -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout "pass:$PASS"
fi

# -A lets signing tools use the private key without a per-use prompt; the first
# codesign may still show one "Always allow" dialog on newer macOS releases.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -A >/dev/null

security find-identity "$KEYCHAIN" 2>/dev/null | grep -qF "\"$IDENTITY\"" \
  || { echo "Identity '$IDENTITY' did not import for code signing." >&2; exit 1; }
echo "Created self-signed code-signing identity '$IDENTITY' in the login keychain."
