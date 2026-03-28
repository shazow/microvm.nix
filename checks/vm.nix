{ self, nixpkgs, system, hypervisor }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  hostNode = {
    imports = [ self.nixosModules.host ];

    virtualisation.qemu.options = [
      "-cpu"
      {
        "aarch64-linux" = "cortex-a72";
        "x86_64-linux" = "kvm64,+svm,+vmx";
      }.${system}
    ];
    virtualisation.cores = 2;
    # Must be big enough for the store overlay volume
    virtualisation.diskSize = 4096;

    environment.etc."microvm-bootstrap.secret".text  = "i am super secret";
  };

  runTest = { name, node, script, timeout ? 1800 }:
    import (nixpkgs + "/nixos/tests/make-test-python.nix") ({ ... }: {
      inherit name;
      nodes.vm = node;
      testScript = script;
      meta.timeout = timeout;
    }) { inherit system pkgs; };

  nprocVmName = "${hypervisor}-nproc";
  nprocMac = {
    qemu = "02:00:00:00:10:01";
    cloud-hypervisor = "02:00:00:00:10:02";
    firecracker = "02:00:00:00:10:03";
  }.${hypervisor};
  nprocIface = {
    qemu = "vm-nproc-qemu";
    cloud-hypervisor = "vm-nproc-ch";
    firecracker = "vm-nproc-fc";
  }.${hypervisor};
  nprocFlake = pkgs.runCommand "${nprocVmName}.flake" {
    passthru.nixosConfigurations.${nprocVmName} = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.microvm
        ({ lib, ... }: {
          networking.hostName = nprocVmName;
          system.stateVersion = lib.trivial.release;
          users.users.root.password = "";
          services.getty.autologinUser = "root";

          microvm = {
            inherit hypervisor;
            vcpu = "`nproc`";
            interfaces = [ {
              type = "tap";
              id = nprocIface;
              mac = nprocMac;
            } ];
          };
        })
      ];
    };
  } "touch $out";

  nprocAssertion = {
    qemu = ''
      vm.succeed("pgrep -af 'qemu-system' | grep -F -- '-smp 2' | grep -F -- 'queues=2' | grep -F -- 'vectors=6'")
    '';
    cloud-hypervisor = ''
      vm.succeed("pgrep -af 'cloud-hypervisor' | grep -F -- '--cpus boot=2' | grep -F -- 'num_queues=4'")
    '';
    firecracker = ''
      vm.succeed("grep -F '\"vcpu_count\": 2' /var/lib/microvms/${nprocVmName}/firecracker-${nprocVmName}.json")
    '';
  }.${hypervisor};
in
{
  # Run a VM with a MicroVM
  "vm-${hypervisor}" = runTest {
    name = "vm-${hypervisor}";
    node = hostNode // {
      microvm.vms."${system}-${hypervisor}-example".flake = self;
    };
    script = ''
      vm.wait_for_unit("microvm@${system}-${hypervisor}-example.service", timeout = 1200)
    '';
  };
}
//
nixpkgs.lib.optionalAttrs (builtins.elem hypervisor [ "qemu" "cloud-hypervisor" "firecracker" ]) {
  "vm-${hypervisor}-nproc" = runTest {
    name = "vm-${hypervisor}-nproc";
    node = hostNode // {
      microvm.vms.${nprocVmName}.flake = nprocFlake;
    };
    script = ''
      vm.wait_for_unit("microvm@${nprocVmName}.service", timeout = 1200)
      ${nprocAssertion}
    '';
  };
}
