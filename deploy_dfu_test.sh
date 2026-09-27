#!/usr/bin/env bash
# Regression tests for deploy_dfu.sh image validation (dry-run only, no network).
#
# Usage: ./deploy_dfu_test.sh
# Real-artifact checks use REAL_BUILD, a sysbuild build dir (default: omi/firmware/v2.9.0/build,
# falling back to the main checkout when run from a git worktree).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HERE/deploy_dfu.sh"
REAL_BUILD="${REAL_BUILD:-$HERE/omi/firmware/v2.9.0/build}"
if [[ ! -d "$REAL_BUILD" ]]; then
    # In a git worktree the NCS workspace and builds live in the main checkout.
    main_root="$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
    REAL_BUILD="$main_root/omi/firmware/v2.9.0/build"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# expect <name> <expected-exit> <expected-output-substring> <args...>
expect() {
    local name="$1" want_rc="$2" want_text="$3"
    shift 3
    local out rc
    out="$("$DEPLOY" --dry-run "$@" 2>&1)"
    rc=$?
    if [[ "$rc" == "$want_rc" && "$out" == *"$want_text"* ]]; then
        pass=$((pass + 1))
        echo "ok   $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name (rc=$rc, want $want_rc; want text: $want_text)"
        echo "$out" | sed 's/^/     /'
    fi
}

# Sysbuild-shaped fixture: <build>/partitions.yml + <build>/omi/zephyr/{zephyr.signed.bin,.config}
make_build() {
    local dir="$1"
    mkdir -p "$dir/omi/zephyr"
    cat > "$dir/partitions.yml" <<'EOF'
mcuboot_pad:
  address: 0x10000
  end_address: 0x10200
  region: flash_primary
  size: 0x200
mcuboot_primary:
  address: 0x10000
  end_address: 0x100000
  orig_span: &id001
  - app
  region: flash_primary
  size: 0xf0000
EOF
    printf 'CONFIG_BT_DIS_FW_REV_STR="9.9.9"\n' > "$dir/omi/zephyr/.config"
}

# Throwaway signing keys: KEY is "trusted" (passed via --key), OTHER_KEY is not.
KEY="$TMP/trusted.pem"
OTHER_KEY="$TMP/other.pem"
python3 - "$KEY" "$OTHER_KEY" <<'PY'
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
for out in sys.argv[1:]:
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    open(out, "wb").write(k.private_bytes(serialization.Encoding.PEM,
                                          serialization.PrivateFormat.TraditionalOpenSSL,
                                          serialization.NoEncryption()))
PY

# make_image <out> <reset_vector> <mode> <payload_text> <magic> [signing_key]
# mode: good | nosig | badhash | tamper | truncated | notlv
make_image() {
    python3 - "$@" <<'PY'
import hashlib, struct, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
out, reset, mode, text, magic = sys.argv[1], int(sys.argv[2], 16), sys.argv[3], sys.argv[4], int(sys.argv[5], 16)
key_path = sys.argv[6] if len(sys.argv) > 6 else None
hdr_size = 0x200
body = struct.pack("<II", 0x20001000, reset) + text.encode() + b"\0" * 64
hdr = struct.pack("<IIHHII", magic, 0, hdr_size, 0, len(body), 0) + struct.pack("<BBHI", 0, 0, 0, 0) + b"\0" * 4
payload = hdr.ljust(hdr_size, b"\xff") + body
if mode == "notlv":
    open(out, "wb").write(payload); sys.exit(0)
key = serialization.load_pem_private_key(open(key_path, "rb").read(), password=None)
pub = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.PKCS1)
digest = hashlib.sha256(payload).digest()
if mode == "badhash":
    digest = hashlib.sha256(b"fabricated").digest()
tlv = struct.pack("<HH", 0x01, 32) + hashlib.sha256(pub).digest()
tlv += struct.pack("<HH", 0x10, 32) + digest
if mode != "nosig":
    sig = key.sign(payload, padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32), hashes.SHA256())
    tlv += struct.pack("<HH", 0x20, len(sig)) + sig
if mode == "tamper":
    payload = payload[:-1] + b"X"
img = payload + struct.pack("<HH", 0x6907, 4 + len(tlv)) + tlv
if mode == "truncated":
    img = img[:-10]
open(out, "wb").write(img)
PY
}

B="$TMP/build"
make_build "$B"
IMG="$B/omi/zephyr/zephyr.signed.bin"

make_image "$IMG" 0x00010a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
expect "signed app-core image passes" 0 "Dry run: image valid" --key "$KEY" "$IMG"
expect "prints verified image hash" 0 "MCUboot SHA-256 TLV, verified" --key "$KEY" "$IMG"
expect "prints verified signature" 0 "RSA-2048-PSS verified" --key "$KEY" "$IMG"
expect "prints DIS version from build config" 0 "9.9.9 (present in image)" --key "$KEY" "$IMG"
expect "image signed by an untrusted key rejected" 1 "key-hash TLV does not match" --key "$OTHER_KEY" "$IMG"

make_image "$IMG" 0x00010a01 good "fw 9.9.9" 0x96f3b83d "$OTHER_KEY"
expect "untrusted key with trusted key-hash check rejected" 1 "key-hash TLV does not match" --key "$KEY" "$IMG"

make_image "$IMG" 0x01008a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
expect "net-core image rejected" 1 "outside the app-core slot" --key "$KEY" "$IMG"

make_image "$IMG" 0x00100004 good "fw 9.9.9" 0x96f3b83d "$KEY"
expect "reset vector past slot end rejected" 1 "outside the app-core slot" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 notlv "fw 9.9.9" 0x96f3b83d
expect "image without TLVs rejected" 1 "image ends before its TLV area" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 nosig "fw 9.9.9" 0x96f3b83d "$KEY"
expect "image without signature rejected" 1 "no RSA-2048 signature TLV" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 badhash "fw 9.9.9" 0x96f3b83d "$KEY"
expect "fabricated hash TLV rejected" 1 "does not match the image contents" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 tamper "fw 9.9.9" 0x96f3b83d "$KEY"
expect "body tampered after signing rejected" 1 "does not match the image contents" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 truncated "fw 9.9.9" 0x96f3b83d "$KEY"
expect "truncated TLV area rejected" 1 "runs past the end of the file" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 good "fw 9.9.9" 0x12345678 "$KEY"
expect "bad magic rejected" 1 "not a signed MCUboot image" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 good "fw 1.2.3" 0x96f3b83d "$KEY"
expect "stale image (DIS mismatch) rejected" 1 "does not contain it" --key "$KEY" "$IMG"

printf 'PK\003\004rest-of-zip' > "$IMG"
expect "zip package rejected" 1 "zip package" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
expect "missing signing key rejected" 1 "signing key not found" --key "$TMP/nokey.pem" "$IMG"

rm -f "$B/partitions.yml"
expect "missing partitions file rejected" 1 "partitions file not found" --key "$KEY" "$IMG"

make_build "$TMP/other"
expect "--partitions override accepted" 0 "Dry run: image valid" --partitions "$TMP/other/partitions.yml" --key "$KEY" "$IMG"

expect "missing image rejected" 1 "firmware not found" --key "$KEY" "$TMP/nope.bin"

# Real artifacts: the deployed app image passes; the net-core update image is refused.
if [[ -f "$REAL_BUILD/omi/zephyr/zephyr.signed.bin" ]]; then
    expect "real app-core image passes (repo MCUboot key)" 0 "RSA-2048-PSS verified" "$REAL_BUILD/omi/zephyr/zephyr.signed.bin"
    if [[ -f "$REAL_BUILD/signed_by_mcuboot_and_b0_ipc_radio.bin" ]]; then
        expect "real net-core image refused" 1 "outside the app-core slot" \
            --partitions "$REAL_BUILD/partitions.yml" "$REAL_BUILD/signed_by_mcuboot_and_b0_ipc_radio.bin"
    fi
    if [[ -f "$REAL_BUILD/dfu_application.zip" ]]; then
        expect "real dfu zip refused" 1 "zip package" \
            --partitions "$REAL_BUILD/partitions.yml" "$REAL_BUILD/dfu_application.zip"
    fi
else
    echo "skip real-artifact checks (no build at $REAL_BUILD)"
fi

echo "passed=$pass failed=$fail"
(( fail == 0 ))
