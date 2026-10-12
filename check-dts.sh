#!/bin/sh
# Compile the board device tree the same way OpenWrt does, but in seconds and
# without a toolchain. Run this before committing to a build that takes an hour.
#
#   ./check-dts.sh <path-to-linux-src> [path-to-openwrt-src]
#
# <path-to-linux-src> is a checkout of ghahramani/linux at branch
# h3600-linux-rfc (it needs arch/arm/boot/dts/zte/zx279128s.dtsi and
# include/dt-bindings/clock/zte,zx279128s-crm.h). If a second argument is
# given, the file is taken from that OpenWrt checkout instead of this repo.
#
# Needs cpp and dtc. On Debian/Ubuntu: apt-get install device-tree-compiler.

set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LINUX=${1:?usage: check-dts.sh <linux-src> [openwrt-src]}
TREE=${2:-}
DTS=$TOP/overlay/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts
[ -n "$TREE" ] && DTS=$TREE/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts

DTS_DIR=$LINUX/arch/arm/boot/dts

for f in "$DTS" "$DTS_DIR/zte/zx279128s.dtsi" "$LINUX/include/dt-bindings/clock/zte,zx279128s-crm.h"; do
	[ -f "$f" ] || { echo "error: $f not found" >&2; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# This mirrors include/image.mk's Image/BuildDTB: the preprocessor gets the
# kernel dts directory, its include directory and the kernel include directory,
# then dtc runs with -i pointed at the directory holding our source so relative
# includes still resolve.
cpp -nostdinc -x assembler-with-cpp \
	-I"$DTS_DIR" \
	-I"$DTS_DIR/include" \
	-I"$LINUX/include" \
	-undef -D__DTS__ \
	-o "$TMP/board.dts.tmp" "$DTS"

dtc -O dtb -i "$(dirname "$DTS")" -o "$TMP/board.dtb" "$TMP/board.dts.tmp"

echo "ok: $(basename "$DTS") compiles"
echo
echo "verifying the properties that matter for bring-up:"
dtc -I dtb -O dts "$TMP/board.dtb" 2>/dev/null > "$TMP/board.out.dts"

show() {
	printf '%-34s %s\n' "$1" "$(sed -n "$2" "$TMP/board.out.dts" | tr -d '\t' | head -1)"
}
show "compatible"            '/^	compatible = /p'
show "memory reg"            '/memory@40000000/,/^\t\t};/p' | true
grep -A2 'memory@40000000 {' "$TMP/board.out.dts" | sed 's/^/    /'
echo "  enabled peripherals:"
awk '/^	[a-z].*\{/{node=$0} /status = "okay"/{gsub(/^[ \t]+/,"",node); print "    " node}' \
	"$TMP/board.out.dts" | grep -E 'serial|spi|ethernet|mdio|pcie|usb|gpio' || true
echo "  ethernet ports:"
grep -B4 'label = "l' "$TMP/board.out.dts" | grep -E 'port@|label|phy-mode' | sed 's/^/    /' || \
	echo "    (no lan labels found - check &gmac_portN)"
