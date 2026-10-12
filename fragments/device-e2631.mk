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
# KERNEL_INITRAMFS drops the target's uImage-ramboot step and uses the plain
# uImage one. uImage-ramboot is H3600-specific: it loads at 0x48008000 to keep
# the kernel clear of that bootloader's RX buffers, and 0x48008000 is outside
# DRAM entirely on a part described as 0x40000000 + 128 MiB. Device/Default
# already sets KERNEL_LOADADDR and KERNEL_ENTRY to 0x40008000, and
# include/image-commands.mk passes both straight through to mkimage, which is
# precisely the flow that has been proven to boot this board from U-Boot.
define Device/zte_zxhn-e2631
  DEVICE_MODEL := ZXHN E2631
  DEVICE_DTS := zx279128s-zte-zxhn-e2631
  KERNEL_INITRAMFS := kernel-bin | append-dtb | uImage none
endef
TARGET_DEVICES += zte_zxhn-e2631
