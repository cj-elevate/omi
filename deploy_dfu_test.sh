#!/usr/bin/env bash
# Regression tests for deploy_dfu.sh (no network: dry-run validation, and the upload path
# against a fake curl with canned gateway replies).
#
# Usage: ./deploy_dfu_test.sh
# Real-artifact checks use REAL_BUILD, a sysbuild build dir (default: omi/firmware/v2.9.0/build,
# falling back to the main checkout when run from a git worktree), and RELEASE_IMG, the retained
# 3.0.22 release image. DEPLOY overrides the script under test.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="${DEPLOY:-$HERE/deploy_dfu.sh}"
# In a git worktree the NCS workspace, builds and dfu_images/ live in the main checkout.
main_root="$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
REAL_BUILD="${REAL_BUILD:-$HERE/omi/firmware/v2.9.0/build}"
if [[ ! -d "$REAL_BUILD" ]]; then
    REAL_BUILD="$main_root/omi/firmware/v2.9.0/build"
fi
RELEASE_IMG="${RELEASE_IMG:-$main_root/dfu_images/3.0.22/app_3.0.22_zephyr.signed.bin}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# judge <name> <expected-exit> <expected-output-substring> <rc> <output>
judge() {
    local name="$1" want_rc="$2" want_text="$3" rc="$4" out="$5"
    if [[ "$rc" == "$want_rc" && "$out" == *"$want_text"* ]]; then
        pass=$((pass + 1))
        echo "ok   $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name (rc=$rc, want $want_rc; want text: $want_text)"
        echo "$out" | sed 's/^/     /'
    fi
}

# expect <name> <expected-exit> <expected-output-substring> <args...>
expect() {
    local name="$1" want_rc="$2" want_text="$3"
    shift 3
    local out rc
    out="$("$DEPLOY" --dry-run "$@" 2>&1)"
    rc=$?
    judge "$name" "$want_rc" "$want_text" "$rc" "$out"
}

# expect_live <name> <expected-exit> <expected-output-substring> <home> <args...>
# Runs WITHOUT --dry-run, with HOME=<home> and the gateway URL on the discard port, so nothing
# can be uploaded even if the check under test regressed.
expect_live() {
    local name="$1" want_rc="$2" want_text="$3" home="$4"
    shift 4
    local out rc
    out="$(HOME="$home" VOICE_GATEWAY_URL=http://127.0.0.1:9 "$DEPLOY" "$@" 2>&1)"
    rc=$?
    judge "$name" "$want_rc" "$want_text" "$rc" "$out"
}

# Fake curl for the upload path: canned gateway replies from SHIM_* variables, no network.
# It exits 99 if the gateway secret appears on its command line (the script must pass it via
# a process-substitution header file), and 98 on an unexpected URL.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == *"$SHIM_SECRET"* ]]; then echo "secret on curl argv" >&2; exit 99; fi
done
case "${!#}" in
    */api/dfu/deploy) printf '%s\n%s' "$SHIM_DEPLOY_BODY" "$SHIM_DEPLOY_CODE" ;;
    */api/dfu/status/*) printf '%s' "$SHIM_STATUS_BODY" ;;
    *) echo "unexpected URL: ${!#}" >&2; exit 98 ;;
esac
EOF
chmod +x "$SHIM/curl"
GW_SECRET="shim-secret-4d1f"
GW_HOME="$TMP/gwhome"
mkdir -p "$GW_HOME/.config/platform"
printf 'VOICE_GATEWAY_SECRET=%s\n' "$GW_SECRET" > "$GW_HOME/.config/platform/voice-gateway.env"

# expect_gateway <name> <expected-exit> <expected-output-substring> <deploy_body> <deploy_http_code>
#                <status_body> <args...>
# Full upload path against the fake curl (PATH prefix for this one command only).
expect_gateway() {
    local name="$1" want_rc="$2" want_text="$3"
    local out rc
    out="$(HOME="$GW_HOME" VOICE_GATEWAY_URL=http://127.0.0.1:9 PATH="$SHIM:$PATH" \
        SHIM_SECRET="$GW_SECRET" SHIM_DEPLOY_BODY="$4" SHIM_DEPLOY_CODE="$5" SHIM_STATUS_BODY="$6" \
        "$DEPLOY" "${@:7}" 2>&1)"
    rc=$?
    judge "$name" "$want_rc" "$want_text" "$rc" "$out"
}

# write_partitions <file> [mcuboot_primary end_address]
write_partitions() {
    local end="${2:-0x100000}"
    cat > "$1" <<EOF
mcuboot_pad:
  address: 0x10000
  end_address: 0x10200
  region: flash_primary
  size: 0x200
mcuboot_primary:
  address: 0x10000
  end_address: $end
  orig_span: &id001
  - app
  region: flash_primary
  size: 0xf0000
EOF
}

# Sysbuild-shaped fixture: <build>/partitions.yml + <build>/omi/zephyr/{zephyr.signed.bin,.config}
make_build() {
    local dir="$1"
    mkdir -p "$dir/omi/zephyr"
    write_partitions "$dir/partitions.yml"
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
# mode: good | nosig | badhash | tamper | truncated | notlv | dupsha | dupkey | dupother
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
if mode == "dupkey":
    # A key-hash TLV naming some other key ahead of the right one.
    tlv = struct.pack("<HH", 0x01, 32) + hashlib.sha256(b"other key").digest() + tlv
if mode == "dupother":
    # Two copies of a TLV type the script does not check, in the unprotected trailer. Shaped
    # like dependency TLVs, but real images put those in the protected area; this only proves
    # that repeats of unchecked types are tolerated.
    dep = struct.pack("<BBHBBHI", 1, 0, 0, 0, 0, 0, 0)
    tlv += (struct.pack("<HH", 0x40, len(dep)) + dep) * 2
if mode == "dupsha":
    # A wrong SHA-256 TLV ahead of the right one; last-wins parsing would accept the image.
    tlv += struct.pack("<HH", 0x10, 32) + hashlib.sha256(b"fabricated").digest()
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

expect "prints the partition map used" 0 "partitions   $B/partitions.yml" --key "$KEY" "$IMG"

# Upload path: a missing gateway secret must be reported, not a silent exit.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.config/platform"
printf 'OTHER_VAR=1\n' > "$FAKE_HOME/.config/platform/voice-gateway.env"
expect_live "missing gateway secret reported" 1 "VOICE_GATEWAY_SECRET not found" "$FAKE_HOME" --key "$KEY" "$IMG"

# Upload path against canned gateway replies (deploy ids are 16 lowercase hex, as issued).
DID="0123456789abcdef"
expect_gateway "upload: complete status ends the poll with success" 0 "DFU complete" \
    "{\"deploy_id\": \"$DID\", \"state\": \"queued\"}" 202 '{"state": "complete", "progress": 100}' --key "$KEY" "$IMG"
expect_gateway "upload: error status reported" 1 "DFU ERROR: relay lost" \
    "{\"deploy_id\": \"$DID\"}" 202 '{"state": "error", "progress": 40, "error": "relay lost"}' --key "$KEY" "$IMG"
expect_gateway "upload: non-2xx gateway reply reported" 1 "gateway returned HTTP 409" \
    '{"code": "deploy_in_progress"}' 409 '' --key "$KEY" "$IMG"
expect_gateway "upload: reply without deploy_id reported" 1 "gateway response has no valid deploy_id" \
    '{"state": "queued"}' 202 '' --key "$KEY" "$IMG"
expect_gateway "upload: null deploy_id reported" 1 "gateway response has no valid deploy_id" \
    '{"deploy_id": null}' 202 '' --key "$KEY" "$IMG"
expect_gateway "upload: unreadable poll status reported" 1 "unreadable status for deploy $DID" \
    "{\"deploy_id\": \"$DID\"}" 202 '<html>502 Bad Gateway</html>' --key "$KEY" "$IMG"

# Release directory: image, partitions.yml and .config side by side, no --partitions needed.
R="$TMP/release"
mkdir -p "$R"
write_partitions "$R/partitions.yml"
printf 'CONFIG_BT_DIS_FW_REV_STR="9.9.9"\n' > "$R/.config"
make_image "$R/app.signed.bin" 0x00010a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
expect "release dir: partitions.yml next to the image used" 0 "partitions   $R/partitions.yml" --key "$KEY" "$R/app.signed.bin"

# A map that widens the app slot past app-core flash is refused wherever it comes from, so a
# net-core image cannot pass on a bad release-dir or --partitions map.
make_image "$R/app.signed.bin" 0x01008a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
write_partitions "$R/partitions.yml" 0x2000000
expect "release-dir map past app-core flash rejected (net-core vector)" 1 "outside nRF5340 app-core flash" \
    --key "$KEY" "$R/app.signed.bin"
expect "--partitions map past app-core flash rejected" 1 "outside nRF5340 app-core flash" \
    --partitions "$R/partitions.yml" --key "$KEY" "$R/app.signed.bin"

# A partitions.yml next to a sysbuild image must agree with <build>/partitions.yml.
cp "$B/partitions.yml" "$B/omi/zephyr/partitions.yml"
expect "agreeing adjacent and sysbuild partition maps accepted" 0 "Dry run: image valid" --key "$KEY" "$IMG"
write_partitions "$B/omi/zephyr/partitions.yml" 0xf8000
expect "conflicting adjacent and sysbuild partition maps rejected" 1 "partition maps disagree" --key "$KEY" "$IMG"
rm -f "$B/omi/zephyr/partitions.yml"

make_image "$IMG" 0x00010a01 dupsha "fw 9.9.9" 0x96f3b83d "$KEY"
expect "duplicate SHA-256 TLV rejected (wrong copy first)" 1 "duplicate SHA-256 TLV" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 dupkey "fw 9.9.9" 0x96f3b83d "$KEY"
expect "duplicate key-hash TLV rejected (wrong copy first)" 1 "duplicate key-hash TLV" --key "$KEY" "$IMG"

make_image "$IMG" 0x00010a01 dupother "fw 9.9.9" 0x96f3b83d "$KEY"
expect "repeated unchecked TLV type tolerated" 0 "Dry run: image valid" --key "$KEY" "$IMG"

# A relative image path still resolves when the caller exports CDPATH (cd would echo the path).
make_image "$IMG" 0x00010a01 good "fw 9.9.9" 0x96f3b83d "$KEY"
pushd "$TMP" >/dev/null
out="$(CDPATH="$TMP" "$DEPLOY" --dry-run --key "$KEY" build/omi/zephyr/zephyr.signed.bin 2>&1)"
rc=$?
popd >/dev/null
judge "relative image path with CDPATH exported" 0 "partitions   $B/partitions.yml" "$rc" "$out"

# With no image argument the default build output resolves from the script dir, not the CWD.
default_img="$(cd "$(dirname "$DEPLOY")" && pwd)/omi/firmware/v2.9.0/build/omi/zephyr/zephyr.signed.bin"
pushd "$TMP" >/dev/null
if [[ -f "$default_img" ]]; then
    expect "default image resolved from the script dir" 0 "image        $default_img"
else
    expect "default image resolved from the script dir" 1 "firmware not found: $default_img"
fi
popd >/dev/null

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

# The retained 3.0.22 release image (the one F1 DFUs) passes from its release dir, and its
# verified MCUboot image hash is the one recorded in docs/fleet_inventory.md.
if [[ -f "$RELEASE_IMG" ]]; then
    expect "real 3.0.22 release image passes without --partitions" 0 \
        "5b9b276cc504cd58775d6782cf596ee7246b49f44c631949169fadd88f3ea2a5  (MCUboot SHA-256 TLV, verified)" \
        "$RELEASE_IMG"
else
    echo "skip release-image check (no image at $RELEASE_IMG)"
fi

echo "passed=$pass failed=$fail"
(( fail == 0 ))
