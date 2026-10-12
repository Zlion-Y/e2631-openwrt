#!/bin/sh
# Overlay the E2631 stage-1 port onto a checkout of the sanechips branch.
#
#   ./apply.sh [path-to-openwrt]      (default: ./openwrt)
#
# Three things are added to the tree. No existing file is replaced, so a
# checkout of the branch stays intact - but note that (3) is tree-global:
#   1. one new board dts under target/linux/sanechips/dts/
#   2. one Device block inserted into target/linux/sanechips/image/Makefile
#   3. env/kernel-config, which turns USB off for the whole tree. The E2631
#      must not bring a USB controller up (it hangs, and the watchdog then
#      loops); see the header of overlay/env/kernel-config. Building the H3600
#      from this same tree would now fail on its USB packages.
#
# Revert with:
#   rm <tree>/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts
#   rm <tree>/env/kernel-config
#   git -C <tree> checkout -- target/linux/sanechips/image/Makefile

set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TREE=${1:-$TOP/openwrt}
MK=$TREE/target/linux/sanechips/image/Makefile
DTS_SRC=$TOP/overlay/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts
KC_SRC=$TOP/overlay/env/kernel-config

if [ ! -f "$MK" ]; then
	echo "error: $MK not found." >&2
	echo "       is '$TREE' a checkout of ghahramani/openwrt branch pr-zte-zxhn-h3600?" >&2
	exit 1
fi

if [ ! -f "$DTS_SRC" ]; then
	echo "error: $DTS_SRC missing - run this from the repo root." >&2
	exit 1
fi

if [ ! -f "$KC_SRC" ]; then
	echo "error: $KC_SRC missing - run this from the repo root." >&2
	exit 1
fi

# 1. board device tree
mkdir -p "$TREE/target/linux/sanechips/dts"
cp "$DTS_SRC" "$TREE/target/linux/sanechips/dts/"
echo "added  target/linux/sanechips/dts/$(basename "$DTS_SRC")"

# 2. device definition, injected above the BuildImage call
if grep -q 'zte_zxhn-e2631' "$MK"; then
	echo "keep   target/linux/sanechips/image/Makefile (E2631 device already present)"
else
	awk -v frag="$TOP/fragments/device-e2631.mk" '
		/^\$\(eval \$\(call BuildImage\)\)/ && !inserted {
			while ((getline line < frag) > 0)
				print line
			close(frag)
			print ""
			inserted = 1
		}
		{ print }
	' "$MK" > "$MK.new"

	if ! grep -q 'zte_zxhn-e2631' "$MK.new"; then
		rm -f "$MK.new"
		echo "error: could not find '\$(eval \$(call BuildImage))' in $MK." >&2
		echo "       the target layout changed; insert fragments/device-e2631.mk by hand" >&2
		echo "       before that line." >&2
		exit 1
	fi

	mv "$MK.new" "$MK"
	echo "patched target/linux/sanechips/image/Makefile"
fi

# 3. kernel config fragment. Merged into the kernel config after the target's
#    own config-<ver>, and last, so it can take USB back out. Read the header
#    of the file before touching it.
mkdir -p "$TREE/env"
cp "$KC_SRC" "$TREE/env/kernel-config"
echo "added  env/kernel-config (CONFIG_USB off; see the file header)"

echo
echo "result:"
if (cd "$TREE" && git status --short target/linux/sanechips 2>/dev/null); then
	:
else
	echo "  (not a git checkout; listing instead)"
	ls -1 "$TREE/target/linux/sanechips/dts/"
fi
