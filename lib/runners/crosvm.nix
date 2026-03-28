{ pkgs
, microvmConfig
, macvtapFd
, ...
}:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (microvmConfig)
    hostName
    vcpu mem balloon initialBalloonMem hotplugMem hotpluggedMem user volumes shares
    socket devices vsock graphics credentialFiles
    kernel initrdPath storeDisk storeOnDisk;
  inherit (microvmConfig.crosvm) pivotRoot extraArgs;

  crosvmPkg = microvmConfig.crosvm.package;

  kernelPath = {
    x86_64-linux = "${kernel.dev}/vmlinux";
    aarch64-linux = "${kernel.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
  }.${system};

  gpuParams = {
    context-types = "virgl:virgl2:cross-domain";
    egl = true;
    vulkan = true;
  };

in {

  preStart = ''
    rm -f ${socket}
    ${microvmConfig.preStart}
    ${lib.optionalString (pivotRoot != null) ''
      mkdir -p ${pivotRoot}
    ''}
  '' + lib.optionalString graphics.enable ''
    rm -f ${graphics.socket}
    ${crosvmPkg}/bin/crosvm device gpu \
      --socket ${graphics.socket} \
      --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY\
      --params '${builtins.toJSON gpuParams}' \
      &
    while ! [ -S ${graphics.socket} ]; do
      sleep .1
    done
  '';

  command =
    if user != null
    then throw "crosvm will not change user"
    else if initialBalloonMem != 0
    then throw "crosvm does not support initialBalloonMem"
    else if hotplugMem != 0
    then throw "crosvm does not support hotplugMem"
    else if hotpluggedMem != 0
    then throw "crosvm does not support hotpluggedMem"
    else if credentialFiles != {}
    then throw "crosvm does not support credentialFiles"
    else pkgs.writeShellScript "microvm-crosvm-command" ''
      set -e

      ${if microvmConfig.prettyProcnames then ''exec -a "microvm@${hostName}"'' else "exec"} ${crosvmPkg}/bin/crosvm run \
        -m ${toString mem} \
        -c "$MICROVM_VCPU" \
        --serial type=stdout,console=true,stdin=true \
        -p ${lib.escapeShellArg "console=ttyS0 reboot=k panic=1 ${toString microvmConfig.kernelParams}"} \
        ${lib.optionalString (!balloon) "--no-balloon \\"}
        ${lib.optionalString storeOnDisk "-r ${lib.escapeShellArg storeDisk} \\"}
        ${lib.optionalString graphics.enable "--vhost-user ${lib.escapeShellArg "gpu,socket=${graphics.socket}"} \\"}
        ${lib.optionalString (builtins.compareVersions crosvmPkg.version "107.1" < 0) "--seccomp-log-failures \\"}
        ${lib.optionalString (pivotRoot != null) "--pivot-root ${lib.escapeShellArg pivotRoot} \\"}
        ${lib.optionalString (socket != null) "-s ${lib.escapeShellArg socket} \\"}
        ${lib.concatMapStrings ({ image, direct, serial, readOnly, ... }: ''
          --block ${lib.escapeShellArg "${image},o_direct=${lib.boolToString direct},ro=${lib.boolToString readOnly}${lib.optionalString (serial != null) ",id=${serial}"}"} \
        '') volumes}
        ${lib.concatMapStrings ({ proto, tag, source, socket, readOnly, ... }: {
          "virtiofs" = ''
            --vhost-user ${lib.escapeShellArg "type=fs,socket=${socket}"} \
          '';
          "9p" = if readOnly then
            throw "Readonly 9p share is not supported"
          else ''
            --shared-dir ${lib.escapeShellArg "${source}:${tag}:type=p9"} \
          '';
        }.${proto}) shares}
        ${lib.concatMapStrings ({ id, type, mac, ... }: ''
          --net ${
            if type == "tap"
            then lib.escapeShellArg "tap-name=${id},mac=${mac}"
            else if type == "macvtap"
            then lib.escapeShellArg "tap-fd="
              + "${macvtapFd id}"
              + lib.escapeShellArg ",mac=${mac}"
            else throw "Unsupported interface type ${type} for crosvm"
          } \
        '') microvmConfig.interfaces}
        ${lib.optionalString (vsock.cid != null) "--vsock ${toString vsock.cid} \\"}
        --initrd ${lib.escapeShellArg initrdPath} \
        ${lib.concatMapStrings ({ bus, path, ... }: {
          pci = "--vfio ${lib.escapeShellArg "/sys/bus/pci/devices/${path},iommu=viommu"} \\";
          usb = throw "USB passthrough is not supported on crosvm";
        }.${bus}) devices}
        ${lib.escapeShellArg kernelPath} \
        ${lib.optionalString (extraArgs != []) "${lib.escapeShellArgs extraArgs} \\"}
        "$@"
    '';

  canShutdown = socket != null;

  shutdownCommand =
    if socket != null
    then ''
        ${crosvmPkg}/bin/crosvm powerbtn ${socket}
      ''
    else throw "Cannot shutdown without socket";

  setBalloonScript =
    if socket != null
    then ''
      VALUE=$(( $SIZE * 1024 * 1024 ))
      ${crosvmPkg}/bin/crosvm balloon $VALUE ${socket}
      SIZE=$( ${crosvmPkg}/bin/crosvm balloon_stats ${socket} | \
        ${pkgs.jq}/bin/jq -r .BalloonStats.balloon_actual \
      )
      echo $(( $SIZE / 1024 / 1024 ))
    ''
    else null;

  requiresMacvtapAsFds = true;
}
