#!/usr/bin/env bash
# Regression tests for deploy_dfu.sh image validation (dry-run only, no network).
#
# Usage: ./deploy_dfu_test.sh
# Optional real-artifact checks run when REAL_BUILD points at a sysbuild build dir
# (default: omi/firmware/v2.9.0/build).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HERE/deploy_dfu.sh"
REAL_BUILD="${REAL_BUILD:-$HERE/omi/firmware/v2.9.0/build}"
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

# make_image <out> <reset_vector> <with_tlv 0|1> <payload_text> <magic>
make_image() {
    python3 - "$@" <<'PY'
import hashlib, struct, sys
out, reset, with_tlv, text, magic = sys.argv[1], int(sys.argv[2], 16), sys.argv[3] == "1", sys.argv[4], int(sys.argv[5], 16)
hdr_size = 0x200
body = struct.pack("<II", 0x20001000, reset) + text.encode() + b"\0" * 64
hdr = struct.pack("<IIHHII", magic, 0, hdr_size, 0, len(body), 0) + struct.pack("<BBHI", 0, 0, 0, 0) + b"\0" * 4
hdr = hdr.ljust(hdr_size, b"\xff")
img = hdr + body
if with_tlv:
    digest = hashlib.sha256(img).digest()
    tlv = struct.pack("<HH", 0x10, 32) + digest
    img += struct.pack("<HH", 0x6907, 4 + len(tlv)) + tlv
open(out, "wb").write(img)
PY
}

B="$TMP/build"
make_build "$B"
IMG="$B/omi/zephyr/zephyr.signed.bin"

make_image "$IMG" 0x00010a01 1 "fw 9.9.9" 0x96f3b83d
expect "app-core image passes" 0 "Dry run: image valid" "$IMG"
expect "prints image hash TLV" 0 "MCUboot SHA-256 TLV" "$IMG"
expect "prints DIS version from build config" 0 "9.9.9 (present in image)" "$IMG"

make_image "$IMG" 0x01008a01 1 "fw 9.9.9" 0x96f3b83d
expect "net-core image rejected" 1 "outside the app-core slot" "$IMG"

make_image "$IMG" 0x00100004 1 "fw 9.9.9" 0x96f3b83d
expect "reset vector past slot end rejected" 1 "outside the app-core slot" "$IMG"

make_image "$IMG" 0x00010a01 0 "fw 9.9.9" 0x96f3b83d
expect "unsigned image rejected" 1 "no SHA-256 TLV" "$IMG"

make_image "$IMG" 0x00010a01 1 "fw 9.9.9" 0x12345678
expect "bad magic rejected" 1 "not a signed MCUboot image" "$IMG"

make_image "$IMG" 0x00010a01 1 "fw 1.2.3" 0x96f3b83d
expect "stale image (DIS mismatch) rejected" 1 "does not contain it" "$IMG"

printf 'PK\003\004rest-of-zip' > "$IMG"
expect "zip package rejected" 1 "zip package" "$IMG"

rm -f "$B/partitions.yml"
make_image "$IMG" 0x00010a01 1 "fw 9.9.9" 0x96f3b83d
expect "missing partitions file rejected" 1 "partitions file not found" "$IMG"

make_build "$TMP/other"
expect "--partitions override accepted" 0 "Dry run: image valid" --partitions "$TMP/other/partitions.yml" "$IMG"

expect "missing image rejected" 1 "firmware not found" "$TMP/nope.bin"

# Real artifacts: the deployed app image passes; the net-core update image is refused.
if [[ -f "$REAL_BUILD/omi/zephyr/zephyr.signed.bin" ]]; then
    expect "real app-core image passes" 0 "Dry run: image valid" "$REAL_BUILD/omi/zephyr/zephyr.signed.bin"
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
