#!/bin/zsh
set -euo pipefail

identity="FluidVoice Local Development"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -Fq '"'$identity'"'; then
    echo "Signing identity already installed: $identity"
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -subj "/CN=$identity/O=FluidVoice Development" \
    -keyout "$workdir/key.pem" \
    -out "$workdir/cert.pem" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export \
    -inkey "$workdir/key.pem" \
    -in "$workdir/cert.pem" \
    -out "$workdir/identity.p12" \
    -passout pass:fluidvoice-dev

security import "$workdir/identity.p12" \
    -k "$keychain" \
    -P fluidvoice-dev \
    -T /usr/bin/codesign

security add-trusted-cert -r trustRoot -k "$keychain" "$workdir/cert.pem"

echo "Installed signing identity: $identity"
