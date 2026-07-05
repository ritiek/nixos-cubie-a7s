# Radxa Cubie A7S - NixOS

A minimal, standalone NixOS flake for the Radxa Cubie A7S SBC (Allwinner A733).

Tested board: 6GB RAM, **no eMMC** (SD card boot only).

## Status

Confirmed working on real hardware:

- Serial console (UART, `ttyAS0`)
- Wired Ethernet (RJ45, `end0`, DHCP)
- USB-to-Ethernet adapter (host mode via USB-C)
- USB gadget networking (`g_ether`/`usb0`) - verified end-to-end (ping + SSH)
- WiFi (AIC8800D80/wpa_supplicant) - connects automatically on boot

Configured but not yet hardware-verified:

- NTFS/FUSE and USBIP kernel support - enabled in the kernel config, not
  exercised

Untested:

- eMMC (as my board lacks eMMC)
- FPC/PCIe slot
- GPU (Mali) - not enabled/tested
- NPU - not enabled/tested

## Building the SD card image

```
nix build '.#packages.aarch64-linux.default' -o result-sdimage
```

Flash `result-sdimage/sd-image/*.img` to an SD card (e.g. `dd ... of=/dev/sdX`).

Before flashing, edit `configuration.nix` and replace the placeholder WiFi
credentials (`networking.wireless.networks."SSID".psk = "PASS_PLAIN";`) with
your real network's SSID/password.

## First Contact

How to reach the board on first boot, roughly in order of convenience:

1. **UART / serial console** - most reliable, works even if networking is
   broken. Connect a USB-to-TTL adapter to the board's UART pins
   (`ttyAS0`, 115200 8N1). Has a working login shell.
2. **USB-to-Ethernet adapter** - plug a USB-to-Ethernet dongle into the
   board's USB-C port (host mode). Comes up via DHCP like any other
   Ethernet interface.
3. **USB gadget (g_ether)** - the board exposes `usb0` at `10.0.0.3/24`
   over USB-C for direct SSH access with no other network needed. **Use
   the spare/second USB-C port for this, not the one supplying power** -
   sharing one port for power+data was observed to get stuck negotiating
   host role (no USB-PD contract completes), so no UDC registers and
   `g_ether` never binds. Two separate cables (one power, one data) works
   reliably.
4. **WiFi** (AIC8800D80 over USB) - connects automatically on boot once
   you've set real credentials in `configuration.nix` (see above).
5. **Ethernet (RJ45)** - onboard `end0`, DHCP by default.

## Reducing kernel log level

`configuration.nix` sets `boot.consoleLogLevel = 8;` (verbose, useful for
debugging). Lower this (e.g. to `4`) for quieter boots once things are
working.

`cubie-a7s.nix` also adds `initcall_debug` to `boot.kernelParams`, which
prints a "calling ..." / "initcall ... returned ..." line for every driver
init/probe call during boot. It's kept enabled for easier debugging,
but only shows up at `boot.consoleLogLevel >= 8`. Remove it from
`boot.kernelParams` for quieter/faster boots.
