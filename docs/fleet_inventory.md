---
type: reference
project: omi-firmware
updated: 2026-09-27
---

# Pendant fleet inventory

Source of truth for which firmware build runs on which pendant. Update it on every DFU.
Every DFU'd build must carry a unique DIS firmware revision string (`CONFIG_BT_DIS_FW_REV_STR`
in `omi/firmware/omi/omi.conf`). The relay reads that string after reconnect and reports it
as `firmware_version` in its `health_snapshot`; that is the only remote proof of what booted.
The 2026-09-12, 09-14, and 09-21 builds all said "3.0.21", so none of them can be told apart
remotely. 3.0.22 is the first build with a unique string.

## Devices

| Device | MAC | Pre-F1 version (live) | Pre-F1 app build | Post-F1 version | F1 DFU record(s) |
|---|---|---|---|---|---|
| Dev1 | C2:F5:BE:21:77:D4 | not yet observed (powered off at F1 start) | unknown | pending | pending |
| Dev2 | EB:D8:FA:1D:DF:0F | 3.0.21 (relay health_snapshot, 2026-09-27 01:06 AM ET) | most likely 2026-09-21 (last app DFU); not provable remotely | pending | pending |

Net core, both devices: never updated OTA by this project (see "Network core" below). Whatever
network-core image each pendant shipped or was last flashed with over J-Link is still running.

## Builds

All builds: NCS v2.9.0, toolchain `b77d8c1312`, sysbuild, board `omi/nrf5340/cpuapp`,
MCUboot key `omi/firmware/bootloader/mcuboot/root-rsa-2048.pem` (RSA-2048, RSA-PSS), MCUboot
image version 0.0.0+0 for every build.

| Version | Source | App unsigned `zephyr.bin` sha256 | App MCUboot image hash (SHA-256 TLV) | Deployed signed .bin sha256 | Partition layout |
|---|---|---|---|---|---|
| 3.0.22 | ws/F1-fleet-dfu (see git log) | ffd9c17d11f61469947e43bf4f87a57989e1c98529e41f0dc8a54136b74fcdd1 | caff399f4ac0e4a96d3fc7bb5e3c06b8836465cfcfb2738a986291896bb51232 | ca35cc8c1d32282d19e0a5410dc2ed853f77562ddb1f87e03aaf9cdafaed8741 | A (pinned) |
| 3.0.21 (09-21) | e7de9bde44 | 6bb9a8db16b5f0bf5ab1bdee458f4a740e28ba5acdd794ce729ce676ace37c6d (reproduced byte-for-byte) | 3f6aaa68267a189e58af8c2b7aea7e2dda8eb844d5e2b31ee8366a3d3046a24c | 1eebeed92d618bac48fe6c40216dcd5531e3e022f66b371a26ca1e1940d825b0 | A |
| 3.0.21 (09-14) | unknown | -- | e2321211ce509877ac6b76d2e0dbd145fcfde416905872db4ba728691bd62c0e | db6a9c4e62d11879c179f8aea2fd9f5ee36be59e4a05547e00fba44c3db35ae7 | B |
| 3.0.21 (09-12) | unknown | -- | a489363a29d22619d397992962523da1f65728ccb7ba612e71f91e9b641d6bfc | 4fa73422ff3d2841735823564a5878102af854b3dd3cd6a099fce10cb4e86324 | A |

Network core (`ipc_radio/zephyr/zephyr.bin`, unsigned) is identical for 3.0.21 (09-21) and
3.0.22: a39b873816811699abe114a3af2ff32a52955b3b83049b6bebae288b36d0b227. F1 therefore
updates the app core only.

Signed `.bin` files differ on every signing because RSA-PSS uses a random salt. Compare the
unsigned `zephyr.bin` or the MCUboot image hash TLV (`./deploy_dfu.sh --dry-run <image>` prints it).

### Reproducibility (F1 evidence)

- Two pristine builds of 3.0.22 from the same commit: identical unsigned app and net images,
  identical image hash TLV.
- A pristine rebuild of e7de9bde44 with the pinned layout reproduces the deployed 09-21 app image
  byte-for-byte, from a different source path. So the build is path-independent and the deployed
  09-21 image is exactly e7de9bde44.
- The only differences between 3.0.21 (09-21) and 3.0.22 are the `transport.c` functions changed
  by 6b80a845bb and ddd5827722 (`restore_telemetry_ccc`, `_security_changed`,
  `_transport_connected`, heartbeat uptime math) and the DIS string.

Build command (from `omi/firmware/v2.9.0`, after `cp omi.conf prj.conf` in the app dir):

```
nrfutil toolchain-manager launch --ncs-version v2.9.0 -- west build -d <dir> \
  -b omi/nrf5340/cpuapp <repo>/omi/firmware/omi --sysbuild --pristine always \
  -- -DBOARD_ROOT=<repo>/omi/firmware
```

## Partition layout

Without `pm_static.yml` the partition manager placed `settings_storage` and `littlefs_storage`
differently from build to build with identical Kconfig:

| Layout | settings_storage | littlefs_storage | EMPTY_0 | Builds |
|---|---|---|---|---|
| A | 0xfc000-0xfe000 | 0xf6000-0xfc000 | 0xfe000-0x100000 | 07-31 06:20 J-Link, 09-12, 09-21 |
| B | 0xf8000-0xfa000 | 0xfa000-0x100000 | none | 07-31 06:07 J-Link, 09-14, unpinned rebuilds |

A DFU that switches layout moves the settings area (bond, stored CCC state) and the littlefs area
on the device. `omi/firmware/omi/pm_static.yml` now freezes layout A, the one the most recent
DFU installed. A pendant still on a layout-B build (for example the 09-14 image) switches to A
once when it takes 3.0.22.

## Network core

The phone relay DFU sends one image, which MCUmgr treats as image 0 (app core). With
`NRF53_MULTI_IMAGE_UPDATE=y` the network core is image 1, and MCUboot
(`MCUBOOT_VERIFY_IMG_ADDRESS=y`) erases an image-0 candidate whose reset vector is outside the
app slot. The 2026-09-21 network-core deploy (gateway record `e775246002e1c9a1`, state
`complete`) was erased that way, so the Phase 1 network-core change (TX power +3 dBm in
`sysbuild/ipc_radio.conf`) has never run on either pendant.

A network-core update also has to pass the network-core bootloader (b0n) signature check.
`SB_CONFIG_SECURE_BOOT_SIGNING_KEY_FILE` is unset, so every pristine build generates a new b0n key
(provisioned key hash in the build's `merged_CPUNET.hex`: 09-12 `b7d45a15...`, 09-21
`cd7afd7e...`; factory 3.0.8 kit `bbb0e71c...`). The pendants most likely carry the factory hash,
for which no private key is held here. b0n validates before it copies, so a mismatched image is
rejected without touching the running network core.

`deploy_dfu.sh` refuses network-core images. Network-core OTA needs relay image-1 support and a
resolved b0n key first (follow-up task under epic D-3790, input to the M1 radio decision).

## Rollback

MCUboot runs overwrite-only with no revert. Every image is version 0.0.0+0, so downgrade
prevention allows re-flashing an older app image, but only while the pendant still has a working
BLE link to the relay. Retained app images (untracked, `dfu_images/rollback/`; also in the
voice-gateway `data/dfu/` spool):

| Image | For |
|---|---|
| `app_3.0.21_20260921_34364c34.signed.bin` | layout A devices (09-21 build) |
| `app_3.0.21_20260914_4e8ecf3c.signed.bin` | layout B devices (09-14 build) |
| `app_3.0.21_20260912_4709812a.signed.bin` | layout A devices (09-12 build) |

The 3.0.22 release artifacts (signed, unsigned, ELF, partitions.yml) are in `dfu_images/3.0.22/`.
