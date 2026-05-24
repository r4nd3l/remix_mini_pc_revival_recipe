#!/bin/bash
#
# Flash a TOC0-wrapped U-Boot SPL to an SD card for cold-booting
# a Jide Remix Mini PC.
#
# Usage: sudo ./flash-toc0-to-sd.sh /dev/sdX [/path/to/u-boot-sunxi-with-spl.bin]
#
# This writes the SPL at sector 16 (offset 0x2000) of the target device,
# which is where the Allwinner A64 BROM looks for boot code on SD cards.
# Existing partition data starting at sector 8192 (offset 4 MiB) is
# preserved, so this works on top of an existing Armbian SD image.
#
# WARNING: Specify the correct /dev/sdX. Writing to the wrong device
# will destroy data. Run "lsblk" first to confirm.

set -euo pipefail

DEV="${1:-}"
SPL="${2:-$(dirname "$0")/../precompiled/u-boot-sunxi-with-spl.bin}"

if [[ -z "$DEV" || ! -b "$DEV" ]]; then
  echo "Usage: $0 /dev/sdX [path-to-u-boot-sunxi-with-spl.bin]"
  echo "Available block devices:"
  lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "disk"
  exit 1
fi

if [[ ! -f "$SPL" ]]; then
  echo "SPL file not found: $SPL"
  exit 1
fi

# Sanity check: confirm the SPL is TOC0
MAGIC=$(head -c 8 "$SPL")
if [[ "$MAGIC" != "TOC0.GLH" ]]; then
  echo "ERROR: $SPL does not start with TOC0.GLH magic. Wrong file?"
  exit 1
fi

echo "About to write:"
echo "  source : $SPL ($(stat -c '%s' "$SPL") bytes, TOC0 verified)"
echo "  target : $DEV at sector 16 (offset 8 KiB)"
echo ""
read -p "Proceed? (yes/NO) " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 0; }

dd if="$SPL" of="$DEV" bs=512 seek=16 conv=fsync status=progress
sync

echo ""
echo "Done. First bytes of $DEV at offset 0x2000:"
dd if="$DEV" bs=512 skip=16 count=1 2>/dev/null | hexdump -C | head -2
