# ZTE ZXHN E2631 — OpenWrt stage 1 (RAM only)

A fork-and-build package that adds the **ZXHN E2631** (Sanechips ZX279128S,
2x ARM Cortex-A9) to the `sanechips` target from
[openwrt/openwrt#25469](https://github.com/openwrt/openwrt/pull/25469), and
produces **an image that only ever runs from RAM**.

This is stage 1. Its single job is to answer the questions that make stage 2
possible: what the flash layout is, whether this board shares the H3600's boot
image format, and where the PHYs, LEDs and MAC address actually live.

```
It cannot write to flash. That is not a missing feature.
```

`IMAGES` is left empty in the device definition, so `make` never emits a
`sysupgrade.bin`, and the CI fails the build if one appears anyway. Three things
stood between this board and a writable image; two of them were answered on
2026-10-12 and the third was narrowed in scope.

1. ~~**The partition layout is unpublished.**~~ **Answered.** The vendor kernel
   carries its own table: `vmlinux` @ 0x432358, 15 entries, 0x20 bytes apart,
   `{char *name; u32 pad; u64 size; u64 offset; u64 pad;}`. It is *not* in
   `/proc/cmdline` and *not* in the device tree. Cross-checked against the raw
   128 MiB dump: cspboot's 32-byte slot marker reads back at 0x700000 and
   0x2300000 - exactly the two addresses the table calls `kernel1`/`kernel2`,
   each 28 MiB - and `flash@0x6E00000` matches `mtdblock13` byte for byte. The
   whole table is transcribed into the device tree's `flash@0` node.
2. ~~**The boot image format is unconfirmed.**~~ **Answered, structurally.**
   This board uses the same 32-byte slot marker as the H3600
   (`33 33 33 33 CC CC CC CC 88 88 88 88 DD DD DD DD`), found at both slot
   bases, so it is the same bootloader family and the second slot is still there
   to fall back to. What is *not* proven is that cspboot boots a **plaintext**
   slot - see point 3.
3. **AES-128-ECB transparent decryption is real, and it is scoped.** The key
   `E263111559d0dfde` decrypts the dump at 0xA40000 to a valid JFFS2 node that
   matches the live `/dev/mtd8` byte for byte, and the same block reappears at
   0x2640000 as slot B's copy. So the vendor write path does encrypt. What this
   does *not* reach is a RAM image: nothing here reads a filesystem through
   those partitions. The remaining question is narrower - whether a plaintext
   kernel in a slot is bootable at all - and that is a stage 2 write-path
   question, not a stage 1 one.

The recovery path still depends on an intact second slot, and both slots are now
located. `tools/probe-e2631.sh` is still how everything else gets confirmed on
the box.

### This revision: peripherals first

With the flash questions closed off, the work turned to driving the board's
peripherals — the one thing both persistence routes have in common, since each
needs a running kernel, a self-consistent device tree and the same measured
values. The device tree now enables everything that needs no board wiring
(UART, SPI-NAND, both PCIe controllers with a starting guess at their reset
lines, USB) and stages the two blocks that can only be filled in on the box,
the LED/button nodes and the MAC address. `docs/peripherals-matrix.txt` lists
every peripheral with its status and what is still missing. No driver had to
be written: the upstream target already covers the whole SoC as built-ins.


## Contents

| Path | What it is |
|---|---|
| `overlay/target/linux/sanechips/dts/zx279128s-zte-zxhn-e2631.dts` | the board device tree, with every unverified value marked `TODO-*` |
| `fragments/device-e2631.mk` | the device definition inserted into `image/Makefile` |
| `apply.sh` | overlays both onto an OpenWrt checkout, idempotent |
| `seed/e2631.config` | build configuration that selects this one device |
| `check-dts.sh` | compiles the device tree in seconds, no toolchain needed |
| `tools/probe-e2631.sh` | read-only evidence collector, run it on the box |
| `tools/PROBE.md` | how to read its output, per `TODO-*` ID |
| `docs/peripherals-matrix.txt` | every peripheral on the SoC, sorted into ready / needs a measurement / not needed |
| `.github/workflows/build-initramfs.yml` | CI: check the device tree, then build |

Nothing here replaces an existing file in the target, so the H3600 build is
unaffected. Revert is two commands (`apply.sh` prints them).


## Build

Push this directory as a repository and let Actions do the work; a full OpenWrt
build needs Linux and roughly 25 GB, which this machine has neither of.

The workflow clones `ghahramani/openwrt` at `pr-zte-zxhn-h3600`, runs
`apply.sh`, and uploads
`openwrt-sanechips-generic-zte_zxhn-e2631-initramfs.uImage` as an artifact. To
build against your own branch, change `OPENWRT_REPO` / `OPENWRT_REF` at the top
of the workflow.

The `dts` job finishes in seconds and is the one to watch: it compiles the
device tree against the kernel's `zte/zx279128s.dtsi` and catches a typo without
costing an hour.

Locally, on any Linux box:

```sh
git clone --depth 1 -b pr-zte-zxhn-h3600 https://github.com/ghahramani/openwrt
./apply.sh "$PWD/openwrt"
cp seed/e2631.config openwrt/.config
cd openwrt && make defconfig && make -j$(nproc)
```


## Boot it

Console is at **0x94404000**, 3.3 V TTL, 115200 8N1 — the same address and
settings on all three ZX279128S boards examined so far. Wire TX/RX crossed,
connect ground, and leave VCC alone.

1. Serve the `.uImage` over TFTP.
2. Interrupt `cspboot` at power-on, enter the boot-mode password, and get a
   U-Boot prompt. The password for this firmware is published in the
   `Zlion-Y/e2631-mainline-zx279128s` README, section on booting over TFTP.
3. From the prompt:

```
setenv ipaddr 192.168.10.66
setenv serverip 192.168.10.1
tftp 0x43000000 openwrt-sanechips-generic-zte_zxhn-e2631-initramfs.uImage
bootm 0x43000000
```

**Load at 0x43000000.** Loading the image onto its own entry address makes
`bootm` take the execute-in-place path and leaves the 64-byte uImage header on
top of the kernel entry point, which dies silently. `bootm` copies it to
0x40008000 itself, which is the flow that has been proven on this board.

Note that this differs from the H3600, whose RAM image is addressed at
0x48008000 — an address that is outside DRAM entirely on a part described as
0x40000000 plus 128 MiB. That is why the device definition replaces the
target's `KERNEL_INITRAMFS` instead of inheriting it.

### Milestones to look for in the log

| Line | Confirms |
|---|---|
| `earlycon` or `console [ttyAMA0] enabled` | the PL011 quirk and peripheral ID are right |
| `SMP: Total of 2 processors activated` | `zx279128s.dtsi`'s second CPU and the platform SMP code work on this board |
| `l2c: ... CACHE_ID 0x410000c9` | outer cache came up |
| `spi-zx279128s-spifc ... : probe successful` and an `mtd0` of 128 MiB | **TODO-F1** and the flash half of the job |
| `ZX279128S_MDIO` / `mdio_bus` registration | **TODO-N1** begins |
| a PCIe link, and a `14c3:xxxx` device in `lspci` | **TODO-W1** — the radio is on the bus |
| a shell prompt | stage 1 passed |

If it stops after `Starting kernel ...`, the first thing to change is the memory
size (**TODO-M1**); the second is that `earlycon` needs to be on the kernel
command line, which the device tree sets only as `stdout-path`.


## Run the probe

From the shell, put `tools/probe-e2631.sh` in `/tmp` and run it:

```sh
sh /tmp/probe-e2631.sh > /tmp/out/console.txt 2>&1
```

It writes nothing. Expect roughly three minutes for the 128 MiB signature scan.
It ends by serving its log over `uhttpd` so you can pull the evidence off with
`curl` instead of scrolling it through a serial line.

`tools/PROBE.md` explains what each `TODO-*` needs from that output. The single
most valuable line used to be whether the ZTE slot marker appears in the scan;
that one is already answered off-board - the marker sits at 0x700000 and
0x2300000 in a raw dump - so the probe is now really for the items that can only
be measured on the box: the MDIO/PHY address table, the MAC address location,
the LED and button GPIOs, and the true memory size.


## What stage 2 will need

Ordered by how much they block a writable image:

1. the slot-header and partition findings from the flash scan,
2. evidence about the transparent decryption,
3. the MDIO address table (**TODO-N1**),
4. the MAC address location (**TODO-A1**) — until then the interfaces use a
   random locally administered address, which must not ship,
5. the LED and button GPIO numbers (**TODO-L1**), whose nodes are staged but
   left disabled until the sweep names them,
6. the MT7916 calibration offset; the PCIe reset and enable lines (**TODO-W1**)
   now ship as a starting guess, with a documented way back if the guess hangs
   the controller.

The driver work is already done upstream: the MDIO controller, GMAC, SPIFC, CRM
clocks, GPIO and PCIe host are all `=y` in the target's `config-6.18` and are
SoC-level, so stage 2 is a device tree and board-file exercise, not a driver
exercise.


## Status of what is in here

Real caveats, so you know what you are holding:

- **The device tree has never been compiled.** `check-dts.sh` runs the same
  preprocessor and `dtc` invocation OpenWrt uses; it will report an error on the
  first CI run if there is a mistake in it. Its ten labels were checked against
  the ones the upstream SoC file defines, but nothing beyond that has been
  verified.
- **The five-port block is a hypothesis** copied from the H3600, not measured.
  Both are Ethernet-WAN gateways on the same silicon with the same four internal
  GbPHY blocks, which is the entire basis for it.
- **128 MiB of memory is the conservative value** and is likely wrong in the
  safe direction; U-Boot says 256 MiB.
- Nothing has been run against an E2631, so none of this is a measurement of one.

Sources for the values that are not inherited from the upstream SoC file: the
vendor U-Boot description of firmware `V1.0.0.6B5.8000` as transcribed in
[Zlion-Y/e2631-mainline-zx279128s](https://github.com/Zlion-Y/e2631-mainline-zx279128s),
the live `/sys/firmware/fdt` dump of a ZXHN F670L in
[cubingmucus998/zte-zx279128s-recon](https://github.com/cubingmucus998/zte-zx279128s-recon),
and the H3600 board file at `arch/arm/boot/dts/zte/` in
[ghahramani/linux](https://github.com/ghahramani/linux) branch
`h3600-linux-rfc`.

Device tree: `GPL-2.0-only OR BSD-2-Clause`, matching the upstream SoC file it
includes. Build and probe scripts: `GPL-2.0-only`, in keeping with the OpenWrt
tree they patch.
