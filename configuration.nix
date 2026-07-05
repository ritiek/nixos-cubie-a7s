# Minimal NixOS configuration for Radxa Cubie A7S
# Phase 3 target: boot + serial console + Ethernet + SSH only.
# WiFi (AIC8800, USB-attached) is deferred to Phase 5 - see plan doc's open
# question about needing the in-tree BSP aic8800 module rather than an
# out-of-tree/DKMS driver (the approach RADXA_ZERO_3_NIXOS/aic8800.nix uses,
# which is NOT reusable here).
{ pkgs, lib, ... }:
{
  imports = [
    ./cubie-a7s.nix
    ./aic8800-usb.nix
  ];

  # nixos-generators' sd-aarch64 format imports
  # nixos/modules/installer/sd-card/sd-image-aarch64.nix, which in turn
  # imports nixos/modules/profiles/base.nix for extra filesystem/tool
  # bundling. That module unconditionally does
  # `lib.meta.availableOn pkgs.stdenv.hostPlatform config.boot.zfs.package`
  # to decide the default for `boot.supportedFilesystems.zfs`, which forces
  # evaluation of the ZFS *kernel module* derivation
  # (`config.boot.kernelPackages.zfs`, built via `linuxPackagesFor`) - that
  # derivation expects a standard nixpkgs multi-output kernel with a `dev`
  # output (`kernel.dev`), which our custom single-output
  # linux-cubie-a7s.nix derivation doesn't provide, causing an
  # "attribute 'dev' missing" eval error. We don't need base.nix's bundled
  # tools/filesystems (btrfs/cifs/f2fs/ntfs/xfs support, fuse, tcpdump,
  # etc.) for this minimal headless image, so simply disable the module
  # entirely rather than trying to make our kernel multi-output-compatible.
  # nixos/modules/tasks/filesystems/ext.nix unconditionally requires BOTH
  # "ext2" and "ext4" as loadable initrd kernel modules whenever any ext*
  # filesystem is in use, regardless of which one is actually mounted (the
  # module's own comment notes ext3 was folded into ext4.ko since kernel
  # 4.3, but treats ext2 the same way without actually checking). Our
  # defconfig builds CONFIG_EXT2_FS=y directly INTO the kernel (verified via
  # modules.builtin listing kernel/fs/ext2/ext2.ko), so there is no separate
  # ext2.ko file to find - the modprobe module-closure script used by the
  # sd-image builder doesn't consult modules.builtin for this check and
  # fails looking for a module file that will never exist for a built-in
  # driver. Our defconfig ALSO builds CONFIG_EXT4_FS=y directly into the
  # kernel (verified in build/.config), so ext4 has no separate .ko either -
  # listing it in availableKernelModules hits the exact same modprobe
  # failure. Since both are built-in, we don't need to list either as an
  # initrd module at all; disable ext.nix entirely and just pull in the
  # e2fsprogs fsck tools it would have added via fsPackages.
  disabledModules = [ "profiles/base.nix" "tasks/filesystems/ext.nix" ];
  system.fsPackages = [ pkgs.e2fsprogs ];

  # nixos/modules/installer/sd-card/sd-image.nix (also pulled in by the
  # sd-aarch64 format) unconditionally sets `hardware.enableAllHardware =
  # true;`, which gates in nixos/modules/hardware/all-hardware.nix - a huge
  # generic "any x86/any storage controller" module list (3w-9xxx,
  # megaraid_sas, aacraid, etc.) meant to make install media boot on
  # arbitrary hardware. Our minimal defconfig doesn't build these, so the
  # initrd modules-closure `modprobe` check fails looking for them. None of
  # this hardware exists on an embedded ARM SBC, so force it off.
  hardware.enableAllHardware = lib.mkForce false;

  # nixos/modules/installer/sd-card/sd-image-aarch64.nix sets
  # `boot.consoleLogLevel = lib.mkDefault 7;`. nixos/modules/system/boot/
  # kernel.nix unconditionally appends its own
  # "loglevel=${toString config.boot.consoleLogLevel}" to boot.kernelParams
  # (after any manually-specified loglevel=N we put in cubie-a7s.nix), and
  # the Linux kernel takes the LAST occurrence of a duplicate cmdline
  # param - so our manual loglevel=N in cubie-a7s.nix was being silently
  # overridden back to 7 by this default. It also sets the POST-BOOT
  # `kernel.printk` sysctl to the same value. This is what let the BSP
  # sunxi-hdmi driver's ~20-50ms HPD-poll info-level "drm hdmi detect:
  # disconnect" spam keep flooding/starving the 115200-baud serial console
  # even after lowering cubie-a7s.nix's kernelParams loglevel. Override the
  # actual NixOS option (not just the raw kernelParam) so both the boot-time
  # and post-boot log levels are consistently quiet.
  #
  # DIAGNOSTIC BUMP (temporary): the offending sunxi-hdmi HPD-poll spam
  # driver no longer even compiles (CONFIG_AW_DRM=n, see
  # linux-defconfig-fragment.config), so it's now safe to raise this back
  # up. We're debugging a boot hang that happens right after the husb311
  # TCPCI driver's benign "failed to find usb power" INFO-adjacent line
  # with total silence for 30-60+s after - at loglevel=4 we only see
  # KERN_ERR(3) and below, so any KERN_INFO(6)/KERN_NOTICE(5) driver-probe
  # messages (including husb311's own "probe success" print, and TCPM
  # state-machine logging added by patch 1005) are being silently dropped,
  # hiding exactly where execution actually stalls. Bump to 8 (print
  # everything) to get full visibility, which found HANG #6 (see
  # cubie-a7s.nix's kernelParams comment and sun60i-a733-cubie-a7s.dts'
  # reg_cldo2 node comment for the full root-cause/fix). Reverted back
  # to 4 now that the real hang location is fixed.
  # TEMPORARY DIAGNOSTIC (2nd round, now resolved): after the cldo2 fix,
  # boot log at loglevel=4 again stopped right after the (benign,
  # one-shot per the loglevel=8 test) "husb311 failed to find usb power"
  # line. Bumping to 8 disambiguated this as a genuine new hang (not just
  # filtered INFO output), and a diagnostic patch (1014, now removed)
  # bracketing phylink_start()'s internal calls proved it completes and
  # returns successfully - so the hang is later, in stmmac_enable_all_dma_irq()'s
  # first DMA-facing MMIO write, root-caused to a missing "pclk"
  # (CLK_GMAC0_MBUS) clock enable in dwmac-sunxi.c - see patch
  # 1015-dwmac-sunxi-enable-pclk-gmac0-mbus-clock.patch for the full
  # writeup and fix. Reverted back to 4 - but that fix (patch 1015) was
  # then ITSELF found to be a red herring: a v2 attempt (AXI bus-reset
  # deassert) made sunxi_dwmac_probe() fail outright (its own error print
  # fired) before ever reaching stmmac_enable_all_dma_irq(), yet the
  # system STILL hung at the same relative point in boot (right after the
  # benign MMC RTO retry-give-up burst) - proving Ethernet/dwmac-sunxi was
  # never the real cause. Both patch-1015 attempts have been reverted.
  # TEMPORARY DIAGNOSTIC (3rd round): bumped back to 8 + added
  # "initcall_debug" to cubie-a7s.nix's kernelParams, expecting to find
  # which driver's initcall/probe never returns after the MMC retry-give-up
  # line.
  #
  # RESOLUTION (2026-07-04): there was no hang at all. With loglevel=8 and
  # patience (waiting several minutes instead of the ~30-60s used in every
  # earlier test), the boot log showed the *entire* dwmac-sunxi/phylink/
  # Ethernet hypothesis chain above (HANG #6 cldo2, pclk clock, AXI reset,
  # "MMC subsystem" red herring) was chasing a non-bug: the board's
  # Ethernet PHY (no dedicated driver exists for its ID, falls back to
  # generic `genphy` in irq=POLL mode) simply takes an unusually long
  # ~315 seconds to complete link autonegotiation on this specific board/
  # switch combination. The kernel prints "configuring for phy/rgmii link
  # mode" then goes quiet (that line itself is loglevel-independent, but
  # everything phylink prints during actual autonegotiation polling is
  # below the loglevel=4 threshold) until ~315s later it prints "Link is
  # Up". Systemd/NetworkManager/DHCP/SSH all come up completely normally
  # after that - confirmed via a full SSH login. This was purely a
  # patience/timeout problem in *manual testing*, not a kernel/driver bug.
  # Kept at loglevel=8 (and initcall_debug kept in cubie-a7s.nix) per
  # explicit user preference, even though neither is strictly needed
  # anymore now that the mystery is solved.
  boot.consoleLogLevel = 8;

  system.stateVersion = "25.11";

  # USB gadget (g_ether) - provides usb0 CDC-ECM/RNDIS networking over the
  # USB-C port for first-boot SSH access when no other network is reachable.
  # Kernel side is CONFIG_USB_ETH=m/CONFIG_USB_LIBCOMPOSITE=m in
  # linux-defconfig-fragment.config, built on the already-enabled
  # USB_GADGET+USB_DWC3_DUAL_ROLE (DWC3 in device mode = a UDC).
  boot.kernelModules = [ "g_ether" ];
  # NOTE: 10.0.0.3, not 10.0.0.2 - some host machines used for first-boot
  # USB-gadget access have their own onboard USB-gadget usb0 interface
  # statically pinned to 10.0.0.2/24, which collides with this address and
  # makes plain IPv4 ping/SSH to the board unreliable (resolved via the
  # host's local route table instead of the real gadget link).
  networking.interfaces.usb0.ipv4.addresses = [
    { address = "10.0.0.3"; prefixLength = 24; }
  ];

  # Good practice for real SBC hardware/firmware blobs (e.g. WiFi/BT
  # firmware, if ever needed via linux-firmware).
  hardware.enableRedistributableFirmware = true;

  # NTFS/FUSE mount support (e.g. sshfs). Kernel side is
  # CONFIG_FUSE_FS=m in linux-defconfig.config; this option only installs
  # the userspace ntfs3g FUSE mount helper.
  boot.supportedFilesystems = [ "ntfs" ];

  # This board has no TPM chip. As of nixos-26.05,
  # boot.initrd.systemd.tpm2.enable defaults to true (tied to the systemd
  # package's withTpm2Units default), which pulls "tpm-crb"/"tpm-tis" into
  # boot.initrd.availableKernelModules. Our kernel has CONFIG_TCG_TPM unset
  # (no TPM hardware to support), so the initrd module-closure computation
  # hard-fails with "modprobe: FATAL: Module tpm-crb not found". Disable
  # the initrd TPM2 unit entirely rather than rebuilding the kernel with
  # TPM drivers we'll never use.
  boot.initrd.systemd.tpm2.enable = false;

  # Filesystem configuration (overridden by nixos-generators for images)
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Needed for the vendor boot0/boot_package U-Boot blobs (uboot-cubie-a7s.nix)
  nixpkgs.config.allowUnfree = true;

  # Hostname
  networking.hostName = "radxa-cubie-a7s";

  # Ethernet (gmac0, RGMII) - DHCP by default via networking.useDHCP.
  #
  # KNOWN ISSUE, UNRESOLVED (2026-07-04): the onboard RJ45 port (kernel
  # interface `end0`, driver `dwmac-sunxi`) is UNRELIABLE - across 4
  # separate reboots (each waited 10+ minutes) with a real cable plugged
  # into the RJ45 port, the link never came up at all. This is DIFFERENT
  # from, and in addition to, an earlier-observed and separately-confirmed
  # real characteristic of this same port: when it DOES come up, initial
  # PHY link autonegotiation can take an unusually long time (~315s
  # observed once) before "Link is Up" appears - see the kernel-build
  # patch/fragment comments and the plan doc's "Ethernet" section for the
  # long investigation trail (multiple now-reverted patch attempts:
  # enabling a CLK_GMAC0_MBUS/"pclk" clock, deasserting an AXI/"stmmaceth"
  # reset - both made things WORSE and were reverted; the true root cause
  # of the *intermittent total failure to link at all* has NOT been found
  # and is still open). A USB-C-to-Ethernet adapter (shows up as a
  # separate `enuN` interface via the generic in-tree `asix`/similar USB
  # network driver, completely unrelated code path to `dwmac-sunxi`) has
  # been used as a reliable workaround in the meantime and is the
  # currently-recommended way to get this board on the network. Do NOT
  # assume `end0` is reliable until this is properly root-caused - always
  # have a USB-C Ethernet adapter as a fallback when testing.
  #
  # Switched from NetworkManager to plain DHCP + wpa_supplicant (below) to
  # allow WiFi to connect automatically on first boot without any
  # interactive nmtui/nmcli step.
  networking.useDHCP = lib.mkDefault true;

  # WiFi (AIC8800D80 over USB) - connects automatically on first boot via
  # networking.wireless (wpa_supplicant), with the SSID/PSK stored in
  # plaintext here since this bare/standalone repo has no
  # secrets-management infrastructure.
  # CHANGE THESE before flashing to a network you don't control:
  networking.wireless = {
    enable = true;
    networks."SSID".psk = "PASS_PLAIN";
    extraConfig = ''
      country=IN
      p2p_disabled=1
    '';
  };

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ]; # SSH
  };

  # SSH
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings.PermitRootLogin = "yes";
  };

  # Root user - set your own password or SSH key
  users.users.root = {
    initialPassword = "nixos"; # Change this!
    # Add your SSH public key(s) here:
    # openssh.authorizedKeys.keys = [
    #   "ssh-ed25519 AAAA..."
    # ];
  };

  # Serial console login shell (USB-TTL adapter on UART0, pins 8/9/10,
  # 115200 baud, /dev/ttyACM0 on the build host, kernel device name
  # /dev/ttyAS0).
  #
  # HANG #7 CONTEXT (2026-07-04) - this is why this line exists at all:
  # for the ENTIRE project up to this point, the serial console only ever
  # showed kernel boot-log output - it NEVER had a working interactive
  # login shell, even though this went completely unnoticed for a long
  # time because kernel log output alone looks like "it's working". Root
  # cause: the wrong BSP UART driver was compiled in (see
  # linux-defconfig-fragment.config's "HANG #7" comment for the full
  # kernel-driver-level story - short version: CONFIG_AW_UART was on by
  # default but doesn't match this SoC's `allwinner,uart-v100` DT
  # compatible string at all, so /dev/ttyAS0 never existed; fixed by
  # switching to CONFIG_AW_UART_NG). That kernel fix alone should make
  # NixOS's systemd-getty-generator automatically wire up a working
  # `serial-getty@ttyAS0.service` (it inspects kernel cmdline `console=`
  # entries against currently-registered tty devices at boot time) -
  # but we ALSO force it explicitly here via `wantedBy`, rather than
  # relying purely on that automatic/dynamic detection, so a login shell
  # on the physical serial console is guaranteed to come up on every
  # single boot regardless of any generator-timing edge case, without
  # needing SSH/network/Ethernet reachability at all. This matters a lot
  # in practice on this board given the still-unresolved Ethernet
  # reliability issue documented above.
  systemd.services."serial-getty@ttyAS0" = {
    wantedBy = [ "getty.target" ];
  };

  # Time sync (needed for SSH key verification)
  services.timesyncd.enable = true;

  # Basic packages
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    iproute2
    curl
    ethtool
    # Added 2026-07-04 to debug the still-unresolved onboard Ethernet
    # (`end0`/dwmac-sunxi) reliability issue documented above: neither
    # tool needs a kernel-driver change, both talk to the PHY over the
    # existing in-kernel MDIO bus via netlink/ioctl, so this is a
    # NixOS-config-only change (fast rebuild, no kernel recompile).
    # `mdio-tools` provides the `mdio` CLI (raw register read/write via
    # the kernel's mdio-netlink interface). `phytool` provides `phytool
    # read`/`phytool write` for the same purpose via a slightly
    # different (ioctl-based) path - having both gives a cross-check in
    # case one tool has issues talking to this particular MDIO bus.
    # Plan: dump BMSR (register 1, bit 2 = link status latched-low, bit
    # 5 = autoneg complete) and the link-partner-ability register (5) to
    # get real electrical-level evidence of whether the PHY ever even
    # sees a valid link pulse from the switch/router, vs. seeing a link
    # but never completing autonegotiation, vs. some other failure mode
    # entirely.
    mdio-tools
    phytool
  ];
}
