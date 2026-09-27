#!/usr/bin/env bash
# Deploy an APP-CORE firmware image to the pendant via the voice-gateway WS DFU pipeline.
#
# Usage: ./deploy_dfu.sh [--dry-run] [--partitions <partitions.yml>] [--key <pem>] [path/to/zephyr.signed.bin]
#
#   --dry-run          validate and describe the image, do not upload
#   --partitions FILE  partitions.yml that defines the app-core slot (default: the one next to
#                      the image, else <build>/partitions.yml for a sysbuild tree; if both exist
#                      they must agree on the app-core slot)
#   --key FILE         MCUboot signing key the pendants trust
#                      (default: omi/firmware/bootloader/mcuboot/root-rsa-2048.pem)
#
# If no image path is given, uses the default sysbuild app-core output.
# Reads VOICE_GATEWAY_SECRET from ~/.config/platform/voice-gateway.env
#
# The phone relay uploads exactly one image, always MCUmgr image 0 (the app core).
# A network-core image sent that way is erased by MCUboot on reboot
# (MCUBOOT_VERIFY_IMG_ADDRESS) while the gateway still reports "complete", so this
# script refuses anything that is not an MCUboot image signed by the trusted key whose
# reset vector lies in the app-core primary slot. Net-core OTA needs relay image-1 support first.
#
# "complete" means uploaded + confirmed + reset. It does not prove the new image
# booted: check the relay-reported firmware_version afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_FIRMWARE="$SCRIPT_DIR/omi/firmware/v2.9.0/build/omi/zephyr/zephyr.signed.bin"
GATEWAY_URL="${VOICE_GATEWAY_URL:-http://127.0.0.1:18790}"
ENV_FILE="$HOME/.config/platform/voice-gateway.env"
POLL_INTERVAL=2
POLL_TIMEOUT="${DFU_POLL_TIMEOUT:-600}"
MAX_SIZE=1048576

dry_run=0
partitions=""
key="$SCRIPT_DIR/omi/firmware/bootloader/mcuboot/root-rsa-2048.pem"
firmware=""
while (( $# > 0 )); do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --partitions) partitions="${2:?--partitions needs a file}"; shift 2 ;;
        --key) key="${2:?--key needs a file}"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
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

# Partition map: --partitions wins. Otherwise use the one next to the image (release
# directories keep .bin, partitions.yml and .config together), else the sysbuild one
# (<build>/omi/zephyr/zephyr.signed.bin -> <build>/partitions.yml). When both exist the
# validator requires them to agree on the app-core slot, so a stale copy cannot widen it.
partitions_alt=""
if [[ -z "$partitions" ]]; then
    image_dir="$(cd "$(dirname "$firmware")" && pwd)"
    adjacent="$image_dir/partitions.yml"
    sysbuild="$(cd "$image_dir/../.." && pwd)/partitions.yml"
    if [[ -f "$adjacent" ]]; then
        partitions="$adjacent"
        if [[ -f "$sysbuild" && "$sysbuild" != "$adjacent" ]]; then
            partitions_alt="$sysbuild"
        fi
    else
        partitions="$sysbuild"
    fi
fi
if [[ ! -f "$partitions" ]]; then
    echo "ERROR: partitions file not found: $partitions (pass --partitions)" >&2
    exit 1
fi
app_config="$(cd "$(dirname "$firmware")" && pwd)/.config"
if [[ ! -f "$key" ]]; then
    echo "ERROR: signing key not found: $key (pass --key)" >&2
    exit 1
fi

# Validate the image and print what is about to be flashed.
python3 - "$firmware" "$partitions" "$app_config" "$key" "$partitions_alt" <<'PY'
import hashlib
import re
import struct
import sys

path, partitions_path, config_path, key_path, alt_partitions_path = sys.argv[1:6]
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
def app_slot(partitions_file):
    text = open(partitions_file).read()
    m = re.search(r"^mcuboot_primary:\n(?:[ \t]+.*\n)*?[ \t]+address:\s*(0x[0-9a-fA-F]+)\n"
                  r"(?:[ \t]+.*\n)*?[ \t]+end_address:\s*(0x[0-9a-fA-F]+)", text, re.M)
    if not m:
        fail(f"no mcuboot_primary partition in {partitions_file}")
    return int(m.group(1), 16), int(m.group(2), 16)


slot_start, slot_end = app_slot(partitions_path)
if alt_partitions_path:
    alt_start, alt_end = app_slot(alt_partitions_path)
    if (alt_start, alt_end) != (slot_start, slot_end):
        fail(f"partition maps disagree on the app-core slot: {partitions_path} says "
             f"0x{slot_start:x}-0x{slot_end:x}, {alt_partitions_path} says "
             f"0x{alt_start:x}-0x{alt_end:x}; pass --partitions")

reset_vector = struct.unpack_from("<I", data, hdr_size + 4)[0]
if not (slot_start <= reset_vector <= slot_end):
    fail(f"reset vector 0x{reset_vector:08x} is outside the app-core slot "
         f"0x{slot_start:x}-0x{slot_end:x}; this is not an app-core image "
         f"(the relay uploads image 0 only, so MCUboot would erase it)")

# Verify the image exactly as MCUboot will: the SHA-256 TLV must match the payload,
# the key-hash TLV must name the trusted key, and the RSA-2048-PSS signature must verify.
payload_end = hdr_size + img_size + prot_tlv_size
if payload_end + 4 > len(data):
    fail("image ends before its TLV area")
tlvs = {}
# TLVs this script checks. MCUboot checks every copy of each, so a repeat would make the
# script's verdict depend on which copy it read; refuse it. Other types (e.g. dependency
# TLVs) may legitimately repeat and are not consulted here.
CHECKED_TLVS = {0x01: "key-hash", 0x10: "SHA-256", 0x20: "signature"}
tlv_magic, tlv_total = struct.unpack_from("<HH", data, payload_end)
if tlv_magic != 0x6907:
    fail(f"bad TLV info magic 0x{tlv_magic:04x}; image is not signed")
end = payload_end + tlv_total
if end > len(data):
    fail("TLV area runs past the end of the file")
pos = payload_end + 4
while pos < end:
    if pos + 4 > end:
        fail("truncated TLV entry")
    tlv_type, tlv_len = struct.unpack_from("<HH", data, pos)
    if pos + 4 + tlv_len > end:
        fail(f"TLV 0x{tlv_type:02x} runs past the TLV area")
    if tlv_type in CHECKED_TLVS and tlv_type in tlvs:
        fail(f"duplicate {CHECKED_TLVS[tlv_type]} TLV (0x{tlv_type:02x}); refusing an ambiguous image")
    tlvs[tlv_type] = data[pos + 4:pos + 4 + tlv_len]
    pos += 4 + tlv_len

payload = data[:payload_end]
digest = tlvs.get(0x10)
if digest is None:
    fail("no SHA-256 TLV found; image is not signed")
if digest != hashlib.sha256(payload).digest():
    fail("SHA-256 TLV does not match the image contents (corrupt or tampered image)")
image_hash = digest.hex()

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
except ImportError:
    fail("python3 'cryptography' is required to verify the image signature")
key = serialization.load_pem_private_key(open(key_path, "rb").read(), password=None)
public = key.public_key()
pub_pkcs1 = public.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.PKCS1)
if tlvs.get(0x01) != hashlib.sha256(pub_pkcs1).digest():
    fail(f"key-hash TLV does not match {key_path}; MCUboot would reject this image")
signature = tlvs.get(0x20)
if signature is None or len(signature) != 256:
    fail("no RSA-2048 signature TLV; MCUboot would reject this image")
try:
    public.verify(signature, payload,
                  padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32),
                  hashes.SHA256())
except Exception:
    fail("RSA-PSS signature does not verify; MCUboot would reject this image")

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
print(f"  image_hash   {image_hash}  (MCUboot SHA-256 TLV, verified)")
print(f"  signature    RSA-2048-PSS verified against {key_path}")
print(f"  mcuboot_ver  {major}.{minor}.{revision}+{build_num}")
print(f"  reset_vector 0x{reset_vector:08x}  app-core slot 0x{slot_start:x}-0x{slot_end:x}")
print(f"  partitions   {partitions_path}")
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

SECRET=$(grep '^VOICE_GATEWAY_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)
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

deploy_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin)['deploy_id'])" 2>/dev/null) || {
    echo "ERROR: gateway response has no deploy_id: $body" >&2
    exit 1
}
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

    parsed=$(echo "$status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['state'], int(d.get('progress', 0)))" 2>/dev/null) || {
        echo ""
        echo "ERROR: unreadable status for deploy $deploy_id: $status" >&2
        echo "  The DFU may still be running; check GET $GATEWAY_URL/api/dfu/status/$deploy_id" >&2
        exit 1
    }
    read -r state progress <<<"$parsed"

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
