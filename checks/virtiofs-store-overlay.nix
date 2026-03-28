{ self, nixpkgs, system }:

let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};

  supported =
    pkgs.stdenv.hostPlatform.isLinux &&
    pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform;

  nixos = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.microvm
      ({ config, lib, pkgs, ... }: {
        networking = {
          hostName = "microvm-test";
          useDHCP = false;
        };

        boot.initrd.systemd.enable = true;

        microvm = {
          hypervisor = "qemu";
          shares = [ {
            proto = "virtiofs";
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            readOnly = true;
          } ];
          writableStoreOverlay = "/nix/.rw-store";
          volumes = [
            {
              image = "nix-store-overlay.img";
              label = "nix-store";
              mountPoint = config.microvm.writableStoreOverlay;
              size = 128;
            }
            {
              image = "output.img";
              label = "output";
              mountPoint = "/output";
              size = 32;
            }
          ];
        };

        systemd.services.poweroff-again = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "idle";
          script = ''
            ${pkgs.coreutils}/bin/stat -c '%u:%g' /nix/store > /output/store-owner
            ${pkgs.util-linux}/bin/mountpoint /nix/.ro-store-idmapped > /output/idmapped-mountpoint

            reboot
          '';
        };

        system.stateVersion = lib.mkDefault lib.trivial.release;
      })
    ];
  };
in
lib.optionalAttrs supported {
  "virtiofs-store-overlay" = pkgs.runCommandLocal "microvm-test-virtiofs-store-overlay" {
    nativeBuildInputs = [
      nixos.config.microvm.declaredRunner
      pkgs.p7zip
    ];
    requiredSystemFeatures = [ "kvm" ];
    meta.timeout = 180;
  } ''
    microvm-run

    7z e output.img store-owner idmapped-mountpoint

    if [ "$(cat store-owner)" != "0:0" ]; then
      echo "Expected /nix/store ownership 0:0, got: $(cat store-owner)"
      exit 1
    fi

    if [ "$(cat idmapped-mountpoint)" != "/nix/.ro-store-idmapped is a mountpoint" ]; then
      echo "Expected /nix/.ro-store-idmapped to be mounted"
      cat idmapped-mountpoint
      exit 1
    fi

    mkdir $out
    cp store-owner idmapped-mountpoint $out
  '';
}
