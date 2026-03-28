{ pkgs
, microvmConfig
, macvtapFd
, withDriveLetters
, ...
}:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  stratovirtPkg = microvmConfig.stratovirt.package;

  inherit (microvmConfig)
    hostName
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem interfaces shares socket forwardPorts devices
    kernel initrdPath credentialFiles
    storeOnDisk storeDisk;

  tapMultiQueue = true;

  volumes = withDriveLetters microvmConfig;

  # PCI required by vfio-pci for PCI passthrough
  pciInDevices = lib.any ({ bus, ... }: bus == "pci") devices;
  requirePci = pciInDevices;
  machine = {
    x86_64-linux =
      if requirePci
      then throw "PCI configuration for stratovirt is non-functional" "q35"
      else "microvm";
    aarch64-linux = "virt";
  }.${system};

  console = {
    x86_64-linux = "ttyS0";
    aarch64-linux = "ttyAMA0";
  }.${system};

  devType = addr:
    if requirePci
    then
      if addr < 32
      then "pci,bus=pcie.0,addr=0x${lib.toHexString addr}"
      else throw "Too big PCI addr: ${lib.toHexString addr}"
    else "device";

  enumerate = n: xs:
    if xs == []
    then []
    else [
      (builtins.head xs // { index = n; })
    ] ++ (enumerate (n + 1) (builtins.tail xs));

  virtioblkOffset = 4;
  virtiofsOffset = virtioblkOffset + builtins.length microvmConfig.volumes;

  forwardPortsOptions =
      let
        forwardingOptions = lib.flip lib.concatMapStrings forwardPorts
          ({ proto, from, host, guest }:
            if from == "host"
              then "hostfwd=${proto}:${host.address}:${toString host.port}-" +
                "${guest.address}:${toString guest.port},"
              else "guestfwd=${proto}:${guest.address}:${toString guest.port}-" +
                "cmd:${pkgs.netcat}/bin/nc ${host.address} ${toString host.port},"
          );
      in
      [ forwardingOptions ];

  writeQmp = data: ''
    echo '${builtins.toJSON data}' | nc -U "${socket}"
  '';
in {
  inherit tapMultiQueue;

  command = if balloon
    then throw "balloon not implemented for stratovirt"
    else if initialBalloonMem != 0
    then throw "initialBalloonMem not implemented for stratovirt"
    else if hotplugMem != 0
    then throw "stratovirt does not support hotplugMem"
    else if hotpluggedMem != 0
    then throw "stratovirt does not support hotpluggedMem"
    else if credentialFiles != {}
    then throw "stratovirt does not support credentialFiles"
    else pkgs.writeShellScript "microvm-stratovirt-command" ''
      set -e

      args=(
        "${pkgs.expect}/bin/unbuffer"
        "${stratovirtPkg}/bin/stratovirt"
        "-name" "${hostName}"
        "-machine" "${machine}"
        "-m" "${toString mem}"
        "-smp" "$MICROVM_VCPU"
        "-kernel" "${kernel}/bzImage"
        "-initrd" "${initrdPath}"
        "-append" "console=${console} edd=off reboot=t panic=-1 ${toString microvmConfig.kernelParams}"
        "-serial" "stdio"
        "-object" "rng-random,id=rng,filename=/dev/random"
        "-device" "virtio-rng-${devType 1},rng=rng,id=rng_dev"
      )

      ${lib.optionalString storeOnDisk ''
        args+=("-drive" "id=store,format=raw,readonly=on,file=${storeDisk},if=none,aio=io_uring,direct=false")
        args+=("-device" "virtio-blk-${devType 2},drive=store,id=blk_store")
      ''}
      ${lib.optionalString (socket != null) ''
        args+=("-qmp" "unix:${socket},server,nowait")
      ''}
      ${lib.concatMapStrings ({ index, image, letter, serial, direct, readOnly, ... }: ''
        args+=("-drive" "id=vd${letter},format=raw,if=none,aio=io_uring,file=${image},direct=${if direct then "on" else "off"},readonly=${if readOnly then "on" else "off"}")
        args+=("-device" "virtio-blk-${devType (virtioblkOffset + index)},drive=vd${letter},id=blk_vd${letter}${lib.optionalString (serial != null) ",serial=${serial}"}")
      '') (enumerate 0 volumes)}
      ${lib.optionalString (shares != []) (
        lib.concatMapStrings ({ proto, index, socket, tag, ... }: {
          "virtiofs" = ''
            args+=("-chardev" "socket,id=fs${toString index},path=${socket}")
            args+=("-device" "vhost-user-fs-${devType (virtiofsOffset + index)},chardev=fs${toString index},tag=${tag},id=fs${toString index}")
          '';
        }.${proto}) (enumerate 0 shares)
      )}
      ${lib.warnIf (
        forwardPorts != [] &&
        ! builtins.any ({ type, ... }: type == "user") interfaces
      ) "${hostName}: forwardPortsOptions only running with user network" (
        lib.concatMapStrings ({ type, id, mac, bridge, ... }: ''
          netdev="${if type == "macvtap" then "tap" else type},id=${id},queues=$MICROVM_VCPU_MIN16"
          ${lib.optionalString (type == "user" && forwardPortsOptions != []) ''
            netdev="$netdev,${builtins.head forwardPortsOptions}"
          ''}
          ${lib.optionalString (type == "bridge") ''
            netdev="$netdev,br=${bridge},helper=/run/wrappers/bin/qemu-bridge-helper"
          ''}
          ${lib.optionalString (type == "tap") ''
            netdev="$netdev,ifname=${id}"
          ''}
          ${lib.optionalString (type == "macvtap") ''
            netdev="$netdev,fd=${macvtapFd id}"
          ''}
          if [ "$MICROVM_TAP_MULTI_QUEUE" -eq 1 ]; then
            netdev="$netdev,queues=$MICROVM_VCPU"
          fi
          args+=("-netdev" "$netdev")

          device="virtio-net-${devType 30},id=net_${id},netdev=${id},mac=${mac}"
          if [ "$MICROVM_TAP_MULTI_QUEUE" -eq 1 ]; then
            device="$device,mq=on"
          else
            device="$device,mq=off"
          fi
          args+=("-device" "$device")
        '') interfaces
      )}
      ${lib.concatMapStrings ({ bus, path, ... }: {
        pci = ''
          args+=("-device" "vfio-pci,host=${path}")
        '';
        usb = ''
          args+=("-device" "usb-host,${path}")
        '';
      }.${bus}) devices}
      ${lib.optionalString (lib.hasPrefix "q35" machine) ''
        args+=("-drive" "file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd,if=pflash,unit=0,readonly=true")
        args+=("-drive" "file=${pkgs.OVMF.fd}/FV/OVMF_VARS.fd,if=pflash,unit=1,readonly=true")
      ''}

      ${if microvmConfig.prettyProcnames then ''exec -a "microvm@${hostName}"'' else "exec"} "''${args[@]}" "$@"
    '';

  # Not supported for the `microvm` machine model
  canShutdown = false;

  shutdownCommand =
    if socket != null
    then
      ''
        # ${writeQmp { execute = "qmp_capabilities"; }}
        # ${writeQmp { execute = "system_powerdown"; }}
        ${writeQmp {
          execute = "input_event";
          arguments = {
            key = "keyboard";
            value = "ctrl, 1";
          };
        }}
        ${writeQmp {
          execute = "input_event";
          arguments = {
            key = "keyboard";
            value = "alt, 1";
          };
        }}
        ${writeQmp {
          execute = "input_event";
          arguments = {
            key = "keyboard";
            value = "delete, 1";
          };
        }}
        # wait for exit
        cat "${socket}"
      ''
    else throw "Cannot shutdown without socket";

  requiresMacvtapAsFds = true;
}
