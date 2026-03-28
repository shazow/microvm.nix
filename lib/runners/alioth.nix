{ pkgs
, microvmConfig
, ...
}:

let
  inherit (pkgs) lib;

  aliothPkg = microvmConfig.alioth.package;

  inherit (microvmConfig)
    hostName
    user
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem interfaces volumes shares devices vsock
    kernel initrdPath
    storeDisk storeOnDisk credentialFiles;
in {
  command =
    if user != null
    then throw "alioth will not change user"
    else if balloon
    then throw "balloon not implemented for alioth"
    else if initialBalloonMem != 0
    then throw "initialBalloonMem not implemented for alioth"
    else if hotplugMem != 0
    then throw "alioth does not support hotplugMem"
    else if hotpluggedMem != 0
    then throw "alioth does not support hotpluggedMem"
    else if credentialFiles != {}
    then throw "alioth does not support credentialFiles"
    else pkgs.writeShellScript "microvm-alioth-command" ''
      set -e

      ${if microvmConfig.prettyProcnames then ''exec -a "microvm@${hostName}"'' else "exec"} ${aliothPkg}/bin/alioth run \
        --memory size=${toString mem}M,backend=memfd \
        --num-cpu "$MICROVM_VCPU" \
        -k ${lib.escapeShellArg "${kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}"} \
        -i ${lib.escapeShellArg initrdPath} \
        -c ${lib.escapeShellArg "console=ttyS0 reboot=k panic=1 ${toString microvmConfig.kernelParams}"} \
        --entropy \
        ${lib.optionalString storeOnDisk "--blk ${lib.escapeShellArg "path=${storeDisk},readonly=true"} \\"}
        ${lib.concatMapStrings ({ image, serial, direct, readOnly, ... }:
          lib.warnIf (serial != null) ''
            Volume serial is not supported for alioth
          ''
          lib.warnIf direct ''
            Volume direct IO is not supported for alioth
          ''
          ''
            --blk ${lib.escapeShellArg "path=${image},readOnly=${lib.boolToString readOnly}"} \
          ''
        ) volumes}
        ${lib.concatMapStrings ({ proto, socket, tag, ... }:
          if proto == "virtiofs" then ''
            --fs ${lib.escapeShellArg "vu,socket=${socket},tag=${tag}"} \
          '' else throw "9p shares not implemented for alioth"
        ) shares}
        ${lib.concatMapStrings ({ type, id, mac, ... }:
          if type == "tap" then
            lib.escapeShellArg "--net" + " " +
            lib.escapeShellArg "if_name=${id},mac=${mac},queue_pairs=" + ''"$MICROVM_VCPU"'' + lib.escapeShellArg ",mtu=1500" + " \\\n"
          else throw "interface type ${type} is not supported by alioth"
        ) interfaces}
        ${lib.concatMapStrings ({ ... }:
          throw "PCI/USB passthrough is not supported on alioth"
        ) devices}
        ${lib.optionalString (vsock.cid != null) "--vsock vhost,cid=${toString vsock.cid} \\"}
        "$@"
    '';

  # TODO:
  canShutdown = false;
}
