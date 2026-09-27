#!/usr/bin/env bash
# Deploy an APP-CORE firmware image to the pendant via the voice-gateway WS DFU pipeline.
#
# Usage: ./deploy_dfu.sh [--dry-run] [--partitions <partitions.yml>] [path/to/zephyr.signed.bin]
#
#   --dry-run          validate and describe the image, do not upload
#   --partitions FILE  sysbuild partitions.yml that defines the app-core slot
#                      (default: <build>/partitions.yml derived from the image path)
#
# If no image path is given, uses the default sysbuild app-core output.
# Reads VOICE_GATEWAY_SECRET from ~/.config/platform/voice-gateway.env
#
# The phone relay uploads exactly one image, always MCUmgr image 0 (the app core).
# A network-core image sent that way is erased by MCUboot on reboot
# (MCUBOOT_VERIFY_IMG_ADDRESS) while the gateway still reports "complete", so this
# script refuses anything that is not a signed MCUboot image whose reset vector lies
# in the app-core primary slot. Net-core OTA needs relay image-1 support first.
#
# "complete" means uploaded + confirmed + reset. It does not prove the new image
# booted: check the relay-reported firmware_version afterwards.

set -euo pipefail

DEFAULT_FIRMWARE="omi/firmware/v2.9.0/build/omi/zephyr/zephyr.signed.bin"
GATEWAY_URL="${VOICE_GATEWAY_URL:-http://127.0.0.1:18790}"
ENV_FILE="$HOME/.config/platform/voice-gateway.env"
POLL_INTERVAL=2
POLL_TIMEOUT="${DFU_POLL_TIMEOUT:-600}"
MAX_SIZE=1048576

dry_run=0
partitions=""
firmware=""
while (( $# > 0 )); do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --partitions) partitions="${2:?--partitions needs a file}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
        *) firmware="$1"; shift ;;
    esac
done
firmware="${firmware:-$DEFAULT_FIRMWARE}"

if [[ ! -f "$firmware" ]]; then
    echo "ERROR: firmware not found: $firmware" >&2
    exit 1
fi

size=$(stat -c%s "$firmware")
if (( size > MAX_SIZE )); then
    echo "ERROR: firmware too large: $size bytes (max 1MiB)" >&2
    exit 1
fi

# Sysbuild layout: <build>/omi/zephyr/zephyr.signed.bin -> <build>/partitions.yml
if [[ -z "$partitions" ]]; then
    partitions="$(cd "$(dirname "$firmware")/../.." && pwd)/partitions.yml"
fi
if [[ ! -f "$partitions" ]]; then
    echo "ERROR: partitions file not found: $partitions (pass --partitions)" >&2
    exit 1
fi
app_config="$(cd "$(dirname "$firmware")" && pwd)/.config"

# Validate the image and print what is about to be flashed.
python3 - "$firmware" "$partitions" "$app_config" <<'PY'
import hashlib
import re
import struct
import sys

path, partitions_path, config_path = sys.argv[1:4]
data = open(path, "rb").read()


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


if data[:4] == b"PK\x03\x04":
    fail("this is a zip package; upload the raw signed app-core .bin, not dfu_application.zip")

IMAGE_MAGIC = 0x96F3B83D
if len(data) < 32:
    fail("file too small for an MCUboot header")
magic, load_addr, hdr_size, prot_tlv_size, img_size, flags = struct.unpack_from("<IIHHII", data, 0)
major, minor, revision, build_num = struct.unpack_from("<BBHI", data, 20)
if magic != IMAGE_MAGIC:
    fail(f"not a signed MCUboot image (magic 0x{magic:08x})")
if hdr_size < 32 or hdr_size + img_size > len(data):
    fail(f"inconsistent MCUboot header (hdr_size={hdr_size} img_size={img_size} file={len(data)})")

# The app-core slot, exactly as MCUboot bounds it: [mcuboot_primary.address, end_address].
text = open(partitions_path).read()
m = re.search(r"^mcuboot_primary:\n(?:[ \t]+.*\n)*?[ \t]+address:\s*(0x[0-9a-fA-F]+)\n"
              r"(?:[ \t]+.*\n)*?[ \t]+end_address:\s*(0x[0-9a-fA-F]+)", text, re.M)
if not m:
    fail(f"no mcuboot_primary partition in {partitions_path}")
slot_start, slot_end = int(m.group(1), 16), int(m.group(2), 16)

reset_vector = struct.unpack_from("<I", data, hdr_size + 4)[0]
if not (slot_start <= reset_vector <= slot_end):
    fail(f"reset vector 0x{reset_vector:08x} is outside the app-core slot "
         f"0x{slot_start:x}-0x{slot_end:x}; this is not an app-core image "
         f"(the relay uploads image 0 only, so MCUboot would erase it)")

# SHA-256 TLV: the digest MCUboot verifies, stable across re-signing.
image_hash = None
off = hdr_size + img_size
if prot_tlv_size:
    off += prot_tlv_size
if off + 4 <= len(data):
    tlv_magic, tlv_total = struct.unpack_from("<HH", data, off)
    if tlv_magic == 0x6907:
        pos, end = off + 4, off + tlv_total
        while pos + 4 <= end:
            tlv_type, tlv_len = struct.unpack_from("<HH", data, pos)
            if tlv_type == 0x10:
                image_hash = data[pos + 4:pos + 4 + tlv_len].hex()
            pos += 4 + tlv_len
if image_hash is None:
    fail("no SHA-256 TLV found; image is not signed")

dis = None
try:
    cfg = open(config_path).read()
    mm = re.search(r'^CONFIG_BT_DIS_FW_REV_STR="([^"]*)"', cfg, re.M)
    if mm:
        dis = mm.group(1)
except OSError:
    pass
if dis is None:
    dis_note = "unknown (no build .config next to the image)"
elif dis.encode() in data:
    dis_note = f"{dis} (present in image)"
else:
    fail(f"build .config says DIS version {dis!r} but the image does not contain it; stale image?")

print(f"  image        {path}")
print(f"  sha256       {hashlib.sha256(data).hexdigest()}")
print(f"  image_hash   {image_hash}  (MCUboot SHA-256 TLV)")
print(f"  mcuboot_ver  {major}.{minor}.{revision}+{build_num}")
print(f"  reset_vector 0x{reset_vector:08x}  app-core slot 0x{slot_start:x}-0x{slot_end:x}")
print(f"  dis_version  {dis_note}")
PY

if (( dry_run )); then
    echo "Dry run: image valid, not uploaded."
    exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE" >&2
    exit 1
fi

SECRET=$(grep '^VOICE_GATEWAY_SECRET=' "$ENV_FILE" | cut -d= -f2-)
if [[ -z "$SECRET" ]]; then
    echo "ERROR: VOICE_GATEWAY_SECRET not found in $ENV_FILE" >&2
    exit 1
fi
# Header via process substitution keeps the secret out of the process list.
auth_header() { printf 'X-Voice-Secret: %s\n' "$SECRET"; }

sha256=$(sha256sum "$firmware" | cut -d' ' -f1)
echo "Deploying: $firmware ($size bytes, sha256=${sha256:0:12}...)"

response=$(curl -sS \
    -X POST \
    -H @<(auth_header) \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$firmware" \
    -w '\n%{http_code}' \
    "$GATEWAY_URL/api/dfu/deploy") || {
    echo "ERROR: deploy request failed" >&2
    exit 1
}
http_code="${response##*$'\n'}"
body="${response%$'\n'*}"
if [[ "$http_code" != 2* ]]; then
    echo "ERROR: gateway returned HTTP $http_code: $body" >&2
    exit 1
fi

deploy_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['deploy_id'])")
echo "Deploy ID: $deploy_id"
echo "Polling status..."

state="unknown"
elapsed=0
while (( elapsed < POLL_TIMEOUT )); do
    status=$(curl -sf \
        -H @<(auth_header) \
        "$GATEWAY_URL/api/dfu/status/$deploy_id") || {
        echo "  (poll failed, retrying...)"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        continue
    }

    state=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
    progress=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('progress', 0))")

    case "$state" in
        complete)
            echo ""
            echo "  DFU complete (uploaded, confirmed, reset)."
            echo "  Verify the pendant now reports the new firmware_version before calling it installed."
            exit 0
            ;;
        error)
            error_msg=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', 'unknown'))")
            echo ""
            echo "  DFU ERROR: $error_msg" >&2
            exit 1
            ;;
        *)
            printf "\r  %-20s %3d%%" "$state" "$progress"
            ;;
    esac

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done

echo ""
echo "ERROR: timed out after ${POLL_TIMEOUT}s (last state: $state)" >&2
exit 1
