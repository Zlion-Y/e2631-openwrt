#!/bin/sh
# Overlay the E2631 stage-1 port onto a checkout of the sanechips branch.
#
#   ./apply.sh [path-to-openwrt]      (default: ./openwrt)
#
# Only two things are added to the tree:
#   1. one new board dts under target/linux/sanechips/dts/
#   2. one Device block inserted into target/linux/sanechips/image/Makefile
# No existing file is replaced, so the H3600 build is untouched.
#
# Revert with:
#   rm <tree>/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts
#   git -C <tree> checkout -- target/linux/sanechips/image/Makefile

set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TREE=${1:-$TOP/openwrt}
MK=$TREE/target/linux/sanechips/image/Makefile
DTS_SRC=$TOP/overlay/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts

if [ ! -f "$MK" ]; then
	echo "error: $MK not found." >&2
	echo "       is '$TREE' a checkout of ghahramani/openwrt branch pr-zte-zxhn-h3600?" >&2
	exit 1
fi

if [ ! -f "$DTS_SRC" ]; then
	echo "error: $DTS_SRC missing - run this from the repo root." >&2
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

echo
echo "result:"
if (cd "$TREE" && git status --short target/linux/sanechips 2>/dev/null); then
	:
else
	echo "  (not a git checkout; listing instead)"
	ls -1 "$TREE/target/linux/sanechips/dts/"
fi
