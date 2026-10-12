# Stage 1 bring-up image for the ZTE ZXHN E2631.
#
# Only a RAM image is produced on purpose. IMAGES is empty by default, and
# nothing is set here, so the build emits
# openwrt-sanechips-generic-zte_zxhn-e2631-initramfs.uImage and no
# sysupgrade.bin at all. There cannot be an accidental flash write from an
# image that does not exist.
#
# That is deliberate: the flash layout, the cspboot slot-trailer format and
# the MT7916 calibration offset of this board are all still unknown, and the
# E2631's own vendor tree describes an AES-128-ECB transparent decryption
# layer over its partitions that the H3600 line never mentions.
#
# KERNEL_INITRAMFS uses the plain uImage and 0x40008000 rather than the
# target's uImage-ramboot. That is a choice between two addresses that are both
# valid, not the correction of a wrong one:
#
#   0x40008000  what this board's own kernel uses. cspboot loads the stock
#               kernel from flash with load = entry = 0x40008000, and it is
#               Device/Default's KERNEL_LOADADDR/KERNEL_ENTRY, which
#               include/image-commands.mk passes straight through to mkimage.
#   0x48008000  what uImage-ramboot uses, to keep a TFTP-booted kernel clear of
#               the U-Boot that started it. U-Boot leaves its Ethernet running,
#               with packet buffers at 0x41000000 and a free-buffer list at
#               0x41800000; a kernel unpacked on top of those makes the buffer
#               manager read kernel bytes as buffer numbers, which locks the
#               network up and lets the hardware write packet data into the
#               kernel.
#
# Neither address is outside DRAM. The part has 256 MiB (0x40000000 to
# 0x50000000) and both sit inside it. An earlier revision of this file said
# 0x48008000 was past the end of DRAM, on the belief that the board had 128 MiB.
# It does not, the claim was wrong, and it is withdrawn.
#
# 0x40008000 is kept because it is the address this board is known to boot at,
# and that outweighs a hazard which needs a frame to arrive during early boot.
# The hazard is real, though, and it fails silently. If a TFTP boot stops with
# no output after the U-Boot hand-off, this is the first thing to change: delete
# the KERNEL_INITRAMFS line below and the target's own definition takes over,
# moving the kernel to 0x48008000 and out of the buffer list's way. One line to
# undo, and nothing else in the image depends on it.
#
# No zte-slot-marker, either: that is for a kernel cspboot reads out of flash.
# This image is only ever started from RAM, so it must not carry a slot header.
define Device/zte_zxhn-e2631
  DEVICE_MODEL := ZXHN E2631
  DEVICE_DTS := zx279128s-zte-zxhn-e2631
  KERNEL_INITRAMFS := kernel-bin | append-dtb | uImage none
endef
TARGET_DEVICES += zte_zxhn-e2631
