#!/bin/sh
# E2631 stage-1 evidence collector. Run it inside the initramfs image over the
# serial console. It is read-only: it never opens anything for writing and
# never calls mtd write / sysupgrade / firstboot.
#
#   sh /tmp/probe-e2631.sh              # everything
#   sh /tmp/probe-e2631.sh flash 0 64   # only the flash marker scan, MiB 0-64
#   sh /tmp/probe-e2631.sh mdio         # PHY address table only
#   sh /tmp/probe-e2631.sh gpio         # LED sweep only (watch the panel)
#   sh /tmp/probe-e2631.sh pcie         # PCIe enumeration only
#   sh /tmp/probe-e2631.sh usb          # USB enumeration only
#   sh /tmp/probe-e2631.sh net          # interface / carrier map only
#   sh /tmp/probe-e2631.sh buses        # thermal / watchdog / interrupts
#
# Output goes to stdout and to /tmp/out/probe-<epoch>.txt. Fetch the bundle
# afterwards with the URL printed at the end.

set -u

MDIO_BASE=0x9a101000
FLASH=$(ls /dev/mtd0 2>/dev/null || true)
OUTDIR=/tmp/out
LOG=$OUTDIR/probe-$(date +%s 2>/dev/null || echo 0).txt
PORT=${PROBE_PORT:-81}

mkdir -p "$OUTDIR" 2>/dev/null || OUTDIR=/tmp
LOG=$OUTDIR/probe-$(date +%s).txt

say() { printf '%s\n' "$@" | tee -a "$LOG"; }
hdr() { say ""; say "===== $* ====="; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -w /dev/kmsg ] || say "warning: not running as root"

# --------------------------------------------------------------------------
# printf helpers, because busybox ash expands arithmetic to decimal and
# devmem reads its value with base 0, so a negative mask such as ~0x4000
# would arrive as "-16384" and be rejected. Every mask below is written out
# as an explicit positive 32-bit constant instead.
MASK_NOSTART=0xffffbfff	# ~bit14
MASK_NOADDRREG=0xfffffc00	# ~bits 9:0
CMD_RD=0x800		# bit11

hx() { printf '0x%x' $(($1)); }
hex() { hx "$1"; }		# takes a value rather than an expression
add() { hx "$(($1 + $2))"; }

# --------------------------------------------------------------------------
# MDIO, two ways.
#
# A) through phylib, if the device tree's PHY addresses were right
# B) by poking the controller registers directly, which answers "what is
#    actually on this bus" independent of the device tree
#
# The register map is the one the ZX279128S MDIO driver uses:
#   +0x04 data write   +0x08 data read   +0x0c cfg
#   +0x10 status (bit0 = done)
#   +0x14 command: reg 4:0, phy addr 9:5, write bit10, read bit11,
#                  clock divide bit12, start bit14
# Because phylib drives the very same block, stop the network config first or
# the two will interleave transactions.
mdio_r() {
	_phy=$1
	_reg=$2
	_cmd=$(add $MDIO_BASE 0x14)
	_sts=$(add $MDIO_BASE 0x10)
	_dat=$(add $MDIO_BASE 0x08)

	# drop START, acknowledge the previous transfer
	devmem $_cmd 32 "$(hx "$(devmem $_cmd) & $MASK_NOSTART")" >/dev/null 2>&1
	devmem $_sts 32 0 >/dev/null 2>&1

	_c=$(devmem $_cmd)
	_c=$(hx "($_c & $MASK_NOADDRREG) | $CMD_RD | ($_phy << 5) | $_reg")
	devmem $_cmd 32 "$_c" >/dev/null 2>&1
	devmem $_cmd 32 "$(hx "$_c | 0x4000")" >/dev/null 2>&1

	_i=0
	_s=0
	while [ $_i -lt 200000 ]; do
		_s=$(devmem $_sts)
		[ $((_s & 1)) -eq 1 ] && break
		_i=$((_i + 1))
	done

	if [ $((_s & 1)) -ne 1 ]; then
		devmem $_cmd 32 "$(hx "$(devmem $_cmd) & $MASK_NOSTART")" >/dev/null 2>&1
		return 1
	fi
	_v=$(devmem $_dat)
	devmem $_cmd 32 "$(hx "$(devmem $_cmd) & $MASK_NOSTART")" >/dev/null 2>&1
	devmem $_sts 32 0 >/dev/null 2>&1
	printf '0x%x' $((_v & 0xffff))
}

probe_mdio() {
	hdr "MDIO via phylib (what the device tree claimed)"
	if [ -d /sys/bus/mdio_bus/devices ]; then
		for d in /sys/bus/mdio_bus/devices/*; do
			[ -e "$d" ] || continue
		 say "  ${d#/sys/bus/mdio_bus/devices/}  phy_id=$(cat "$d/phy_id" 2>/dev/null || echo -)"
		done
	else
		say "  no mdio_bus device - is &mdio enabled and did mdio-zx279128s bind?"
	fi
	dmesg | grep -iE 'mdio|phy|phylink|zte.*eth|gmac' | tail -40 | sed 's/^/    /' >>"$LOG"
	say "  (recent kernel messages copied to the log)"

	hdr "MDIO raw controller scan (independent of the device tree)"
	if ! have devmem; then
		say "  busybox devmem missing; apk add kmod-mtd-rw? no - rebuild with"
		say "  CONFIG_BUSYBOX_DEFAULT_DEVMEM=y and try again."
		return
	fi
	if [ -d /etc/init.d ] && [ -x /etc/init.d/network ]; then
		say "  stopping network so phylink does not interleave with these reads"
		/etc/init.d/network stop >/dev/null 2>&1
	fi
	say "  CTRL@0x0c = $(devmem $(add $MDIO_BASE 0x0c))  CMD@0x14 = $(devmem $(add $MDIO_BASE 0x14))"
	say "  addr  ID1(reg2)  ID2(reg3)     BMSR(reg0)   -> guess"
	_a=0
	while [ $_a -lt 32 ]; do
		id1=$(mdio_r $_a 2) || { _a=$((_a + 1)); continue; }
		id2=$(mdio_r $_a 3)
		bmsr=$(mdio_r $_a 0)
		# 0xffff means no PHY drove the data line
		if [ "$id1" = "0xffff" ]; then
			_a=$((_a + 1))
			continue
		fi
		_og=$(printf '%s' "$id1" | cut -c3-6)
		say "  $(printf %2d $_a)  $id1  $id2  $bmsr  OUI/codec 0x$_og"
		_a=$((_a + 1))
	done
	say ""
	say "  OUI 0x04b9 + model 0x501 would read as the Sanechips ZX5201, whose"
	say "  full ID the H3600 PHY driver matches as 0x84b95011. Internal PHYs on"
	say "  the H3600 answer on 10, 11, 12, 13 and the WAN PHY on 8."
}

# --------------------------------------------------------------------------
# Flash. Two questions: where does the boot loader put its slots, and does the
# E2631 share the H3600's 32-byte slot marker and header layout.
MARKERS="
33333333cccccccc88888888dddddddd
333333336666666699999999cccccccc
27051956
d00dfeed
55424923
716e73786863
85190320
20031985
"

u32le() {
	# little-endian 32-bit value at an offset inside the header. Returns 0 when
	# the read comes back empty, which happens on a false-positive marker hit:
	# an unset field is information, an arithmetically invalid one is not.
	v=$(dd if="$FLASH" bs=1 skip=$(($1 + $2)) count=4 2>/dev/null | od -An -tu4 2>/dev/null | tr -d ' \n')
	[ -n "$v" ] || v=0
	printf '%s' "$v"
}

slot_fields() {
	# Decode the 512-byte version header.
	#
	# Field positions come from the SR1010 analysis at
	# cnjn/immortalwrt target/linux/zte/docs/vendor-slots.md, which documents
	# the same 512-byte structure the H3600's upgrade script reads, and adds
	# the fields the H3600 script never touches. Two of those positions are
	# shared verbatim across both boards, which is why they are worth printing
	# here: the inner magic at +0xf4, and the header CRC1 at +0xa4 whose range
	# is [0x00:0xa4].
	_off=$1

	printf '%s\n' "      --- version header at $(hex $_off) ---"

	# The printable strings are the fastest read on whether this really is a
	# header for *this* board: the version string at +0x10 (32 bytes) and the
	# product name at +0x6c (52 bytes) are plain text.
	vs=$(dd if="$FLASH" bs=1 skip=$(($_off + 0x10)) count=32 2>/dev/null | tr -cd '[:print:]')
	pn=$(dd if="$FLASH" bs=1 skip=$(($_off + 0x6c)) count=52 2>/dev/null | tr -cd '[:print:]')
	bt=$(dd if="$FLASH" bs=1 skip=$(($_off + 0xa8)) count=16 2>/dev/null | tr -cd '[:print:]')
	printf '%s\n' "      +0x10 version   : ${vs:-<empty>}"
	printf '%s\n' "      +0x6c product   : ${pn:-<empty>}"
	printf '%s\n' "      +0xa8 buildtime : ${bt:-<empty>}"

	printf '%s\n' "      +0x30 body total      : $(u32le $_off 0x30)"
	printf '%s\n' "      +0x34 kernel size      : $(u32le $_off 0x34)"
	printf '%s\n' "      +0x38 kernel pkg offset: $(u32le $_off 0x38)"
	printf '%s\n' "      +0x3c kernel crc32     : $(u32le $_off 0x3c)"
	printf '%s\n' "      +0x40 rootfs size      : $(u32le $_off 0x40)"
	printf '%s\n' "      +0x44 rootfs pkg offset: $(u32le $_off 0x44)"
	printf '%s\n' "      +0x48 rootfs crc32     : $(u32le $_off 0x48)"
	printf '%s\n' "      +0x8c also-upgrade-bootloader: $(u32le $_off 0x8c)  (0 = package carries no U-Boot)"
	printf '%s\n' "      +0x98 uboot crc32      : $(u32le $_off 0x98)"
	printf '%s\n' "      +0xa4 CRC1 [0:0xa4]    : $(u32le $_off 0xa4)   <- the only CRC U-Boot checks"
	printf '%s\n' "      +0xb8 integrality      : $(u32le $_off 0xb8)   <- must be 0 for the OEM switch tool"
	printf '%s\n' "      +0x1f0 this slot start : $(hex $(u32le $_off 0x1f0))"
	printf '%s\n' "      +0x1f4 serial          : $(u32le $_off 0x1f4)"
	printf '%s\n' "      +0x1f8 new-version flag: $(u32le $_off 0x1f8)"
	printf '%s\n' "      +0x1fc CRC2 [0:0x1fc]  : $(u32le $_off 0x1fc)"
	printf '%s\n' "      +0x1e0..0x1ec slot address table:"
	printf '%s\n' "         [0] $(hex $(u32le $_off 0x1e0))  [1] $(hex $(u32le $_off 0x1e4))"
	printf '%s\n' "         [2] $(hex $(u32le $_off 0x1e8))  [3] $(hex $(u32le $_off 0x1ec))"
	printf '%s\n' "      first 0x40 bytes: $(dd if="$FLASH" bs=1 skip=$_off count=64 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
	printf '%s\n' "      raw hex of the whole 512-byte header follows in the log"
	dd if="$FLASH" bs=1 skip=$_off count=512 2>/dev/null | hexdump -C | sed 's/^/        /' >>"$LOG"
}

probe_flash() {
	hdr "SPI-NAND"
	if [ -z "$FLASH" ]; then
		say "  no /dev/mtd0 - &spifc did not come up. Check dmesg for the"
		say "  spi-zx279128s-spifc driver and try spi-max-frequency 10 MHz."
		dmesg | grep -iE 'spi|nand|mtd|ubi|ecc|denali' | tail -30 | sed 's/^/    /' >>"$LOG"
		return
	fi
	for m in /sys/class/mtd/mtd*; do
		[ -e "$m" ] || continue
		say "  ${m#/sys/class/mtd/} name=$(cat "$m/name") size=0x$(printf %x $(cat "$m/size")) erasesize=0x$(printf %x $(cat "$m/erasesize")) type=$(cat "$m/type")"
	done
	say "  /proc/mtd:"
	sed 's/^/    /' /proc/mtd >>"$LOG"
	dmesg | grep -iE 'spi|nand|mtd|ubi|ecc|bad|denali' | tail -40 | sed 's/^/    /' >>"$LOG"

	_size=$(cat /sys/class/mtd/"${FLASH#/dev\/}"/size 2>/dev/null || echo 0)
	_es=$(cat /sys/class/mtd/"${FLASH#/dev\/}"/erasesize 2>/dev/null || echo 0)
	_from=$((${1:-0}))
	_to=$((${2:-0}))
	[ $_to -eq 0 ] && _to=$(( (_size + 1048575) / 1048576 ))
	_to=$((_to * 1048576))
	[ $_to -gt $_size ] && _to=$_size
	say ""
	say "  scanning $((_to / 1048576)) MiB of $_FLASH for signatures, 1 MiB at a time"
	say "  (erasesize 0x$(printf %x $_es))"

	_off=$_from
	while [ $_off -lt $_to ]; do
		if ! dd if="$FLASH" of=/tmp/chunk.bin bs=1M skip=$((_off / 1048576)) count=1 2>/dev/null; then
			say "    read failed at $(hx _off), stopping scan"
			break
		fi
		hexdump -v -e '1/1 "%02x"' /tmp/chunk.bin > /tmp/chunk.hex 2>/dev/null
		for m in $MARKERS; do
			grep -o -b "$m" /tmp/chunk.hex 2>/dev/null | while IFS=: read -r hp _rest; do
				co=$((_off + hp / 2))
				# report only 4K-aligned hits: a random byte sequence that
				# happens to match a signature anywhere else is noise
				[ $((co % 4096)) -eq 0 ] || continue
				printf '    0x%08x  %s\n' "$co" "$m"
			done >>"$LOG"
		done
		rm -f /tmp/chunk.bin /tmp/chunk.hex
		_off=$((_off + 1048576))
		[ $(($_off % 0x800000)) -eq 0 ] && say "      ... reached $(hx _off)"
	done

	say ""
	say "  hits (offset -> signature), whole scan:"
	grep -E '^    0x' "$LOG" | sort -u | tail -60

	# If the ZTE slot marker shows up, read the header fields next to it and
	# compare them against what cspboot on the H3600 expects. That single
	# comparison decides whether platform.sh can be reused as-is or has to be
	# reverse-engineered from scratch for this board.
	say ""
	say "  slot-marker hits, with the H3600 header fields decoded beside them:"
	_i=0
	for o in $(grep -E '^    0x' "$LOG" | grep 33333333cccccccc | awk '{print $1}'); do
		[ $_i -ge 4 ] && break
		say "    at $o :"
		slot_fields "$o"
		_i=$((_i + 1))
	done
	[ $_i -eq 0 ] && say "    none found - the boot loader on this board does not use the"
	[ $_i -eq 0 ] && say "    H3600 slot marker. Do not assume a flash write is recoverable."
}

# --------------------------------------------------------------------------
# LEDs and buttons. There is no device tree entry for them yet, so this walks
# every line of all six GPIO controllers and you read the panel.
probe_gpio() {
	hdr "GPIO chips"
	for c in /sys/class/gpio/gpiochip*; do
		[ -e "$c" ] || continue
		say "  ${c#/sys/class/gpio/} base=$(cat "$c/base") ngpio=$(cat "$c/ngpio") label=$(cat "$c/label")"
	done
	if [ ! -d /sys/class/gpio/gpiochip0 ]; then
		say "  no gpiochip exposed - is CONFIG_GPIO_ZX279128S bound? The SoC file"
		say "  declares six banks at 0x94407000 + 0x40 * n, without a status property."
	fi
	cat /sys/kernel/debug/gpio 2>/dev/null | sed 's/^/    /' >>"$LOG"

	say ""
	say "  LED SWEEP: each number below is driven high for 0.4 s."
	say "  Watch the front panel and note which number lit which LED."
	say "  Press Ctrl-C as soon as the log gets long enough, or set LINES."
	_bases=$(for c in /sys/class/gpio/gpiochip*; do [ -e "$c" ] && cat "$c/base"; done)
	[ -z "$_bases" ] && { say "  nothing to sweep"; return; }
	for b in $_bases; do
		_l=0
		while [ $_l -lt 32 ]; do
			n=$((b + _l))
			echo "$n" >/sys/class/gpio/export 2>/dev/null || { _l=$((_l + 1)); continue; }
			echo out >/sys/class/gpio/gpio"$n"/direction 2>/dev/null
			echo 1 >/sys/class/gpio/gpio"$n"/value 2>/dev/null
			say "    gpio $n (bank $b + $_l) = HIGH"
			sleep 1
			echo 0 >/sys/class/gpio/gpio"$n"/value 2>/dev/null
			echo "$n" >/sys/class/gpio/unexport 2>/dev/null
			_l=$((_l + 1))
		done
	done
	say "  sweep finished"
}

# --------------------------------------------------------------------------
# PCIe. The controller itself is not in question - the SoC file describes both
# of them completely. What is unknown is whether the board's reset and enable
# lines are the ones the device tree claims, and what sits on the other end.
probe_pcie() {
	hdr "PCIe"
	if have lspci; then
		lspci -nn | sed 's/^/  /' >>"$LOG"
		say "  first devices (full list in the log):"
		lspci -nn | head -12 | sed 's/^/    /'
	else
		say "  lspci missing - install pciutils, or read the sysfs list below"
	fi

	say ""
	say "  /sys/bus/pci/devices:"
	if [ -d /sys/bus/pci/devices ]; then
		for d in /sys/bus/pci/devices/*; do
			[ -e "$d" ] || continue
			say "    ${d#/sys/bus/pci/devices/}  $(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null)  class $(cat "$d/class" 2>/dev/null)"
		done
	else
		say "    none - neither controller came up"
	fi

	say ""
	say "  controllers bound:"
	for c in /sys/bus/platform/devices/*pcie*; do
		[ -e "$c" ] || continue
		say "    ${c##*/}"
	done

	say "  dmesg (pcie / link / bar / aspm), in the log:"
	dmesg | grep -iE 'pcie|link up|link down|bar [0-9]|aspm' | tail -40 | sed 's/^/    /' >>"$LOG"

	say ""
	say "  Reading: vendor 14c3 is MediaTek - an MT7916 shows up there. If the"
	say "  list is empty the reset/enable GPIOs in the device tree are likely"
	say "  wrong: run the gpio3 sweep while watching this list."
}

# --------------------------------------------------------------------------
# USB. Two questions: did the controller bind at all, and is a socket wired.
probe_usb() {
	hdr "USB"
	if have lsusb; then
		lsusb | sed 's/^/  /' >>"$LOG"
		say "  lsusb output copied to the log"
	else
		say "  lsusb missing - the sysfs list below is the fallback"
	fi
	say "  root hubs and devices:"
	for d in /sys/bus/usb/devices/*; do
		[ -e "$d" ] || continue
		say "    ${d##*/}  speed=$(cat "$d/speed" 2>/dev/null || echo -)"
	done
	[ -e /sys/bus/usb/devices/usb1 ] || \
		say "    no root hub - the DWC3 driver did not bind (is kmod-usb-dwc3 in the image?)"
	dmesg | grep -iE 'dwc3|xhci|new .*USB device' | tail -25 | sed 's/^/    /' >>"$LOG"
}

# --------------------------------------------------------------------------
# Board health: the bits of the SoC that are present with no board wiring at
# all, so their absence is a real finding rather than a missing measurement.
probe_buses() {
	hdr "thermal / watchdog / interrupts"
	_found=0
	for z in /sys/class/thermal/thermal_zone*; do
		[ -e "$z" ] || continue
		_found=1
		say "  ${z##*/}  type=$(cat "$z/type" 2>/dev/null)  temp=$(cat "$z/temp" 2>/dev/null)"
	done
	[ $_found -eq 0 ] && say "  no thermal zone"
	say "  watchdogs : $(ls /dev/watchdog* 2>/dev/null | tr '\n' ' ')"
	say "  /proc/interrupts tail (full table in the log):"
	tail -16 /proc/interrupts 2>/dev/null | sed 's/^/    /' >>"$LOG"
}

# --------------------------------------------------------------------------
# Interfaces, and the panel-to-port map that the device tree needs.
probe_net() {
	hdr "network interfaces"
	say "  name / operstate / carrier:"
	for i in /sys/class/net/*; do
		[ -e "$i" ] || continue
		n=${i##*/}
		say "    $n  operstate=$(cat "$i/operstate" 2>/dev/null)  carrier=$(cat "$i/carrier" 2>/dev/null)"
	done
	ip -o link 2>/dev/null | sed 's/^/  /' >>"$LOG"
	ip -o addr 2>/dev/null | sed 's/^/  /' >>"$LOG"
	say ""
	say "  Plug a cable into each front-panel port in turn: the name whose"
	say "  carrier flips to 1 is that port, which is what gmac_portN needs."
	if have ethtool; then
		for i in /sys/class/net/*; do
			n=${i##*/}
			[ "$n" = "lo" ] && continue
			ethtool "$n" 2>/dev/null | \
				grep -iE 'speed|duplex|link detected|supported ports' | sed "s/^/    $n: /" >>"$LOG"
		done
		say "  (ethtool details are in the log)"
	fi
}

# --------------------------------------------------------------------------
everything() {
	hdr "identity"
	say "  uname   : $(uname -a)"
	say "  cmdline : $(cat /proc/cmdline)"
	say "  model   : $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')"
	say "  compat  : $(cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr '\0' ' ')"
	say "  memory  : $(grep -E 'MemTotal|MemFree' /proc/meminfo | tr '\n' ' ')"
	say "  dts reg : $(od -An -tx1 -N8 /sys/firmware/devicetree/base/memory@40000000/reg 2>/dev/null | tr -s ' ')"
	hdr "cpus"
	grep -E 'processor|model name|BogoMIPS|Features' /proc/cpuinfo | sed 's/^/  /' >>"$LOG"
	say "  online  : $(cat /sys/devices/system/cpu/online 2>/dev/null)"
	say "  possible: $(cat /sys/devices/system/cpu/possible 2>/dev/null)"
	say "  (cpuinfo in the log file)"
	hdr "partitions as the kernel sees them"
	cat /proc/devices >>"$LOG" 2>/dev/null
	dmesg | tail -60 >>"$LOG"
	hdr "dmesg tail copied above"
	probe_mdio
	probe_flash "$@"
	probe_gpio
	probe_pcie
	probe_usb
	probe_buses
	probe_net
}

serve() {
	if have uhttpd; then
		uhttpd -p "$PORT" -h "$OUTDIR" -r "probe-e2631" >/dev/null 2>&1 &
		_ip=$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
		say ""
		say "  evidence bundle: $LOG"
		say "  fetch from your PC:  curl -o $(basename "$LOG") 'http://${_ip:-<router-ip>}:$PORT/$(basename "$LOG")'"
	else
		say ""
		say "  evidence bundle: $LOG  (uhttpd not present, copy it out by hand)"
	fi
}

case ${1:-all} in
flash)
	probe_flash "${2:-0}" "${3:-0}"
	serve
	;;
mdio)
	probe_mdio
	;;
gpio)
	probe_gpio
	;;
pcie)
	probe_pcie
	serve
	;;
usb)
	probe_usb
	;;
net)
	probe_net
	;;
buses)
	probe_buses
	;;
*)
	everything "$@"
	serve
	;;
esac
