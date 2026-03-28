{ self, nixpkgs, system, ... }:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  guestSystem = lib.replaceString "-darwin" "-linux" system;

  mkConfig = modules:
    nixpkgs.lib.nixosSystem {
      system = guestSystem;
      modules = [
        self.nixosModules.microvm
        ({ lib, ... }: {
          networking.hostName = "vcpu-test";
          system.stateVersion = lib.trivial.release;
        })
      ] ++ modules;
    };

  forceRunnerEval = nixos:
    builtins.tryEval (builtins.deepSeq nixos.config.microvm.declaredRunner.drvPath true);
in
lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
  let
    qemuDynamic = mkConfig [
      {
        microvm = {
          hypervisor = "qemu";
          vcpu = "`nproc`";
          interfaces = [
            {
              type = "tap";
              id = "vcputest0";
              mac = "02:00:00:00:00:01";
            }
          ];
        };
      }
    ];

    invalidNonQemu = forceRunnerEval (mkConfig [
      {
        microvm = {
          hypervisor = "firecracker";
          vcpu = "`nproc`";
        };
      }
    ]);

    invalidMacvtap = forceRunnerEval (mkConfig [
      {
        microvm = {
          hypervisor = "qemu";
          vcpu = "`nproc`";
          interfaces = [
            {
              type = "macvtap";
              id = "vcputest0";
              mac = "02:00:00:00:00:01";
              macvtap = {
                link = "eth0";
                mode = "bridge";
              };
            }
          ];
        };
      }
    ]);
  in
  {
    vcpu-qemu-runtime = pkgs.runCommandLocal "microvm-vcpu-qemu-runtime" {
      nativeBuildInputs = [ qemuDynamic.config.microvm.declaredRunner ];
    } ''
      set -euo pipefail

      microvm_run=$(command -v microvm-run)
      tap_up=$(command -v tap-up)

      grep -F 'MICROVM_VCPU=`nproc`' "$microvm_run"
      grep -F 'case "$MICROVM_VCPU" in' "$microvm_run"
      grep -F -- '-smp "$MICROVM_VCPU"' "$microvm_run"
      grep -F "printf ',queues=%s' \"\$MICROVM_VCPU\"" "$microvm_run"

      grep -F 'MICROVM_TAP_VCPU=`nproc`' "$tap_up"
      grep -F 'case "$MICROVM_TAP_VCPU" in' "$tap_up"
      grep -F 'TAP_FLAGS="$TAP_FLAGS multi_queue"' "$tap_up"

      mkdir "$out"
    '';

    vcpu-non-qemu-restriction = pkgs.runCommandLocal "microvm-vcpu-non-qemu-restriction" { } ''
      set -euo pipefail

      if [ "${if invalidNonQemu.success then "1" else "0"}" -ne 0 ]; then
        echo "expected string microvm.vcpu on a non-qemu hypervisor to fail evaluation"
        exit 1
      fi

      mkdir "$out"
    '';

    vcpu-qemu-macvtap-restriction = pkgs.runCommandLocal "microvm-vcpu-qemu-macvtap-restriction" { } ''
      set -euo pipefail

      if [ "${if invalidMacvtap.success then "1" else "0"}" -ne 0 ]; then
        echo "expected qemu macvtap with string microvm.vcpu to fail evaluation"
        exit 1
      fi

      mkdir "$out"
    '';
  }
)
