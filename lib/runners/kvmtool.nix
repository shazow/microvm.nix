{ pkgs
, microvmConfig
, ...
}:

let
  inherit (pkgs) lib;

  kvmtoolPkg = microvmConfig.kvmtool.package;

  inherit (microvmConfig)
    hostName preStart user
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem interfaces volumes shares devices vsock
    kernel initrdPath credentialFiles
    storeDisk storeOnDisk;
in {
  preStart = ''
    ${preStart}
    export HOME=$PWD
  '';

  command =
    if user != null
    then throw "kvmtool will not change user"
    else if initialBalloonMem != 0
    then throw "kvmtool does not support initialBalloonMem"
    else if hotplugMem != 0
    then throw "kvmtool does not support hotplugMem"
    else if hotpluggedMem != 0
    then throw "kvmtool does not support hotpluggedMem"
    else if credentialFiles != {}
    then throw "kvmtool does not support credentialFiles"
    else pkgs.writeShellScript "microvm-kvmtool-command" ''
      set -e

      ${if microvmConfig.prettyProcnames then ''exec -a "microvm@${hostName}"'' else "exec"} ${kvmtoolPkg}/bin/lkvm run \
        --name ${lib.escapeShellArg hostName} \
        -m ${toString mem} \
        -c "$MICROVM_VCPU" \
        --console serial \
        --rng \
        -k ${lib.escapeShellArg "${kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}"} \
        -i ${lib.escapeShellArg initrdPath} \
        -p ${lib.escapeShellArg "console=ttyS0 reboot=k panic=1 ${toString microvmConfig.kernelParams}"} \
        ${lib.optionalString storeOnDisk "-d ${lib.escapeShellArg "${storeDisk},ro"} \\"}
        ${lib.optionalString balloon "--balloon \\"}
        ${lib.concatMapStrings ({ serial, direct, readOnly, ... }:
          lib.warnIf (serial != null) ''
            Volume serial is not supported for kvmtool
          ''
          ''
            -d ${lib.escapeShellArg "image${lib.optionalString direct ",direct"}${lib.optionalString readOnly ",ro"}"} \
          ''
        ) volumes}
        ${lib.concatMapStrings ({ proto, source, tag, readOnly, ... }:
          if proto == "9p" then
            if readOnly then
              throw "kvmtool does not support readonly 9p share"
            else ''
              --9p ${lib.escapeShellArg "${source},${tag}"} \
            ''
          else
            throw "virtiofs shares not implemented for kvmtool"
        ) shares}
        ${lib.concatMapStrings ({ type, id, mac, ... }:
          if builtins.elem type [ "user" "tap" ] then ''
            -n ${lib.escapeShellArg "mode=${type},tapif=${id},guest_mac=${mac}"} \
          ''
          else if type == "macvtap" then ''
            -n ${lib.escapeShellArg "mode=tap,tapif=/dev/tap"}$(< /sys/class/net/${id}/ifindex)${lib.escapeShellArg ",guest_mac=${mac}"} \
          ''
          else throw "interface type ${type} is not supported by kvmtool"
        ) interfaces}
        ${lib.concatMapStrings ({ bus, path }: {
          pci = "${lib.escapeShellArg "--vfio-pci=${path}"} \\";
          usb = throw "USB passthrough is not supported on kvmtool";
        }.${bus}) devices}
        ${lib.optionalString (vsock.cid != null) "--vsock ${toString vsock.cid} \\"}
        "$@"
    '';

  # `lkvm stop` works but is not graceful.
  canShutdown = false;

  setBalloonScript = ''
    if [[ $SIZE =~ ^-(\d+)$ ]]; then
      ARGS="-d ''${BASH_REMATCH[1]}"
    else
      ARGS="-i $SIZE"
    fi
    HOME=$PWD ${kvmtoolPkg}/bin/lkvm balloon $ARGS -n ${hostName}
  '';
}
