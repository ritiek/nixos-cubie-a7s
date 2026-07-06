# Radxa Cubie A7S - NixOS

A minimal, standalone NixOS flake for the Radxa Cubie A7S SBC (Allwinner A733).

Tested board: 6GB RAM, **no eMMC** (SD card boot only).

## Status

Confirmed working on real hardware:

- SD card boot
- Serial console (UART, `ttyAS0`)
- Wired Ethernet (RJ45, `end0`, DHCP)
- USB-to-Ethernet adapter (host mode via USB-C)
- USB gadget networking (`g_ether`/`usb0`) - verified end-to-end (ping + SSH)
- WiFi (AIC8800D80/wpa_supplicant) - connects automatically on boot
- FPC/PCIe slot - tested using Pimoroni NVMe Base for Raspberry Pi 5 (https://shop.pimoroni.com/products/nvme-base?variant=41219587178579)

Configured but not yet hardware-verified:

- NTFS/FUSE and USBIP kernel support - enabled in the kernel config, not
  exercised

Untested:

- eMMC (my board lacks eMMC)

Not working:

- GPU - not implemented yet
- NPU - not implemented yet
- MIPI CSI - haven't looked
- Display output (USB-C DisplayPort Alt Mode) - see "Patches" below for why

## Building the SD card image

Before flashing, edit `configuration.nix` and replace the placeholder WiFi
credentials (`networking.wireless.networks."SSID".psk = "PASS_PLAIN";`) with
the real network's SSID/password.

Build:

```
nix build .#packages.aarch64-linux.default
```

Flash `result/sd-image/*.img` to an SD card.

## First Contact

Ways to reach the board on first boot, roughly in order of convenience.
SSH is enabled on every interface below. Login: username `root`, password
`nixos` (change this in `configuration.nix`).

1. **UART / serial console** - most reliable, works even if networking is
   broken. Connect a USB-to-TTL adapter to the board's UART pins
   (`ttyAS0`, 115200 8N1).

   | Cubie A7S pin     | Connection  | USB-to-TTL module pin |
   |-------------------|-------------|------------------------|
   | GND (Pin 6)       | Dupont wire | GND                    |
   | UART0_TX (Pin 8)  | Dupont wire | RXD                    |
   | UART0_RX (Pin 10) | Dupont wire | TXD                    |

   ```
   $ picocom -b 115200 /dev/ttyACM0
   ```

   See also Radxa's own UART login docs:
   https://docs.radxa.com/en/cubie/a7s/system-config/uart-login
2. **USB-to-Ethernet adapter** - plug into the board's USB-C port (host
   mode). Comes up via DHCP - `ssh root@<dhcp-ip>`.
3. **USB gadget (g_ether)** - `usb0` at `10.0.0.3/24` over USB-C -
   `ssh root@10.0.0.3`, no other network needed. Use a second USB-C port
   for this, separate from the power cable - sharing one port for both
   power and data can get stuck negotiating host role, so `g_ether` never
   binds.
4. **WiFi** (AIC8800D80 over USB) - connects automatically once real
   credentials are set (see above) - `ssh root@<dhcp-ip>`.
5. **Ethernet (RJ45)** - onboard `end0`, DHCP - `ssh root@<dhcp-ip>`.

## Reducing kernel log level

`configuration.nix` sets `boot.consoleLogLevel = 8;` (verbose, useful for
debugging). Lower this (e.g. to `4`) for quieter boots.

`cubie-a7s.nix` also adds `initcall_debug` to `boot.kernelParams`, which
logs every driver init/probe call during boot (only visible at
`boot.consoleLogLevel >= 8`). Remove it for quieter/faster boots.

## NixOS / kernel version

NixOS `nixos-26.05` (see `nixpkgs.url` in `flake.nix`) is used for the base
system.

Linux 6.6.98, built by merging Radxa's vendor kernel fork (`radxa/kernel`,
branch `allwinner-aiot-linux-6.6`) with Radxa's `allwinner-bsp` overlay
repo (branch `cubie-aiot-v1.4.8`) - see `linux-cubie-a7s.nix` for the
pinned commits/hashes. There is no mainline Linux support for the A733 SoC
yet (blocked upstream on A733 clock-driver support), so this vendor
kernel+BSP combo is what every working project for this board currently
uses.

This version also determines whether the AIC8800 WiFi driver builds.
`aic8800-usb.nix` builds it out-of-tree against the running kernel, and
`radxa-pkg/aic8800`'s patch set only covers specific kernel version
brackets (`fix-linux-6.1/6.5/6.7/6.9/6.12-build.patch`). 6.6.98 falls in
the 6.5 bracket, so `fix-linux-6.5-build.patch` applies. Check for a
matching bracket patch before bumping the kernel/BSP.

`icefirex`'s Radxa Zero 3W NixOS flake wires up the same AIC8800 driver
(SDIO variant there, USB here) and was a useful reference for the
`boot.extraModulePackages`/`aic_fw_path` approach used here:
https://github.com/icefirex/nixos-radxa-zero3w

Possible future bump: `patryk4815/nixos-cubie-a5e` (Radxa Cubie A5E /
Allwinner A527, same AIC8800D80 chip, SDIO variant) ships an
`aic8800-kernel-7.0.patch` that builds the driver against Linux 7.0,
tested on NixOS 25.11. That board has mainline Linux support, unlike
the A733 here, so it isn't a drop-in fix - but it's a useful reference
patch to adapt from if the vendor kernel+BSP fork this project depends
on is ever rebased past 6.6.98, or once A733 gains mainline
clock-driver support:
https://github.com/patryk4815/nixos-cubie-a5e

## Patches

Patches under `patches/` are applied to the merged kernel+BSP tree by
`linux-cubie-a7s.nix`. What's wired into the build's `patches` list, and
why:

- **0001-cpufreq-sun50i-add-sun60i-a733-match.patch** - adds
  `allwinner,sun60i-a733` to `sun50i-cpufreq-nvmem.c`'s match table so
  cpufreq-dt recognizes this SoC. Without it, cpufreq never loads.
- **1001-drivers-usb-Add-et7304-driver.patch** - Radxa's `et7304` USB-PD/TCPC
  driver, needed for USB-PD negotiation on the board's USB-C port(s).
- **1004-Add-tcpci_husb311.c.patch** - driver for the HUSB311 TypeC PD
  controller actually populated on this board (TWI1 address `0x4e` in the
  DTS). Without it, USB-PD negotiation can get stuck and block the whole
  USB-C port, including `g_ether` and USB-to-Ethernet dongles.
- **1005-tcpm-emit-state-machine-to-kernel-log.patch** - debug aid: makes
  TCPM/USB-PD state transitions print to `dmesg`/serial instead of only
  debugfs, which is hard to reach on a headless board.
- **[NO-OP] 1013-sunxi-drm-skip-commit-init-connecting-when-headless.patch**
  - fixes a vendor BSP bug: `sunxi_drm_bind()` unconditionally calls
  `commit_init_connecting()` even with no display attached, hanging the
  system inside `drm_atomic_commit()` on an empty atomic state. Still
  applied but has no effect - `CONFIG_AW_DRM=n` disables the whole
  DRM/eDP/HDMI subsystem after a second, unrelated DRM bug (an eDP-AUX
  retry hang) turned up right after this one was fixed, so
  `sunxi_drm_drv.c` isn't compiled anymore (display never actually
  worked - see below). Kept in the patch list for whoever re-enables DRM
  later; the eDP hang still needs fixing separately.
- **[NOT APPLIED] 1015-dwmac-sunxi-enable-pclk-gmac0-mbus-clock.patch** and
  **[NOT APPLIED] 1015-dwmac-sunxi-deassert-axi-bus-reset.patch** - not in
  `linux-cubie-a7s.nix`'s `patches` list. Both were tried as fixes for an
  apparent Ethernet-driver boot hang. The first made things worse - the
  board hung earlier, inside the clock-enable call itself (a hardware bus
  stall, not a driver bug). The second's own error path fired at boot
  (the reset framework genuinely failed) before the driver even reached
  the suspected code, yet the system still hung at the same point -
  proving Ethernet was never the actual cause. Kept on disk as a record
  of what was tried and ruled out.

Display output (USB-C DisplayPort Alt Mode) was never implemented - every
attempt to leave DRM/eDP/HDMI enabled hit a real boot hang (see `1013`
above), so `CONFIG_AW_DRM=n` disables that subsystem. USB-C on this board
is data/power only (USB-PD negotiation, `g_ether`, USB-to-Ethernet
dongles) - no video out.
