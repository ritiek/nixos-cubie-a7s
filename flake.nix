{
  description = "NixOS on Radxa Cubie A7S (Allwinner A733 / sun60iw2)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
    let
      system = "aarch64-linux";
      # allowUnfree needed for uboot-cubie-a7s's vendor boot0/boot_package
      # blobs (see that file's meta.license comment for why).
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

      ubootCubieA7S = pkgs.callPackage ./uboot-cubie-a7s.nix { };
    in
    {
      nixosConfigurations.radxa-cubie-a7s = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          {
            system.configurationRevision = self.rev or "dirty";
          }
          ./configuration.nix
        ];
      };

      # Flashable SD card image.
      #
      # The vendor U-Boot blob (boot_package.fex) was verified (via `strings`)
      # to support ext4load/ext4ls/sysboot against a bootable-flagged
      # partition, so the *standard* nixpkgs sd-aarch64 image format works
      # unmodified here (ext4 root partition holds /boot/extlinux/extlinux.conf,
      # same as the Radxa Zero 3W flake) - no custom GPT/FAT32 boot partition
      # layout is required, unlike OctaneOS's Buildroot-based genimage.cfg.
      #
      # boot0/boot_package are NOT part of any partition - they are raw
      # Allwinner BROM-read blobs written before the partition table gap.
      # firmwarePartitionOffset is bumped from the 8MiB default to 20MiB so
      # boot_package (ends at byte 0xC00000 + 1441792 =~ 13.4MiB) can never
      # collide with the (empty/unused, RPi-only by default) FIRMWARE
      # partition that nixpkgs' sd-image module always creates - 20MiB also
      # matches OctaneOS's own genimage.cfg boot partition offset, for
      # whatever that convention-following is worth.
      packages.aarch64-linux.default = nixos-generators.nixosGenerate {
        inherit system;
        format = "sd-aarch64";
        modules = [
          ./configuration.nix
          {
            sdImage.compressImage = false;
            sdImage.firmwarePartitionOffset = 20; # MiB
            sdImage.postBuildCommands = ''
              dd if=${ubootCubieA7S}/boot0_sdcard.fex of=$img \
                bs=1024 seek=${toString (ubootCubieA7S.boot0Offset / 1024)} conv=notrunc
              dd if=${ubootCubieA7S}/boot_package.fex of=$img \
                bs=1M seek=${toString (ubootCubieA7S.bootPackageOffset / 1024 / 1024)} conv=notrunc
            '';
          }
        ];
      };

      packages.aarch64-linux.sdImage = self.packages.aarch64-linux.default;
    };
}
