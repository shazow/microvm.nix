{ pkgs
, microvmConfig
, macvtapFd
, macvtapFdColonList
, withDriveLetters
, ...
}:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (microvmConfig) vmHostPackages;

  enableLibusb = pkg: pkg.overrideAttrs (oa: {
    configureFlags = oa.configureFlags ++ [
      "--enable-libusb"
    ];
    buildInputs = oa.buildInputs ++ (with pkgs; [
      libusb1
    ]);
  });

  minimizeQemuClosureSize = pkg: pkg.override (oa: {
    # standin for disabling everything guilike by hand
    nixosTestRunner =
      if graphics.enable
      then oa.nixosTestRunner or false
      else true;
  });

  overrideQemu = x: lib.pipe x (
    lib.optional requireUsb enableLibusb
    ++ lib.optional microvmConfig.optimize.enable minimizeQemuClosureSize
  );
  qemu = overrideQemu microvmConfig.qemu.package;

  aioEngine = if vmHostPackages.stdenv.hostPlatform.isLinux
    then "io_uring"
    else "threads";

  inherit (microvmConfig) hostName machineId vcpu mem balloon initialBalloonMem deflateOnOOM hotplugMem hotpluggedMem user interfaces shares socket forwardPorts devices vsock graphics storeOnDisk kernel initrdPath storeDisk credentialFiles;
  inherit (microvmConfig.qemu) machine extraArgs serialConsole pcieRootPorts;

  volumes = withDriveLetters microvmConfig;

  requireUsb =
    graphics.enable ||
    lib.any ({ bus, ... }: bus == "usb") microvmConfig.devices;

  arch = builtins.head (builtins.split "-" system);

  cpuArgs = [
    "-cpu"
    (
      if microvmConfig.cpu != null
      then microvmConfig.cpu
      else if system == "x86_64-linux"
      # qemu crashes when sgx is used on microvm machines: https://gitlab.com/qemu-project/qemu/-/issues/2142
      then "host,+x2apic,-sgx"
      else "host"
    ) ];

  accel = if vmHostPackages.stdenv.hostPlatform.isLinux
    then "kvm:tcg" else
      if vmHostPackages.stdenv.hostPlatform.isDarwin
      then "hvf:tcg" else "tcg";

  # PCI required by vfio-pci for PCI passthrough
  pciInDevices = lib.any ({ bus, ... }: bus == "pci") devices;

  requirePci =
    graphics.enable ||
    (! lib.hasPrefix "microvm" machine) ||
    shares != [] ||
    pciInDevices;

  machineOpts =
    if microvmConfig.qemu.machineOpts != null
    then microvmConfig.qemu.machineOpts
    else {
      x86_64-linux = {
        inherit accel;
        mem-merge = "on";
        acpi = "on";
      } // lib.optionalAttrs (machine == "microvm") {
        pit = "off";
        pic = "off";
        pcie = if requirePci then "on" else "off";
        rtc = "on";
        usb = if requireUsb then "on" else "off";
      };
      aarch64-linux = {
        inherit accel;
        gic-version = "max";
      };
      aarch64-darwin = {
        inherit accel;
      };
    }.${system};

  machineConfig = builtins.concatStringsSep "," (
    [ machine ] ++
    map (name:
      "${name}=${machineOpts.${name}}"
    ) (builtins.attrNames machineOpts)
  );

  devType =
    if requirePci
    then "pci"
    else "device";

  kernelPath = "${kernel.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";

  enumerate = n: xs:
    if xs == []
    then []
    else [
      (builtins.head xs // { index = n; })
    ] ++ (enumerate (n + 1) (builtins.tail xs));

  canSandbox =
    # Don't let qemu sandbox itself if it is going to call qemu-bridge-helper
    (! lib.any ({ type, ... }:
      type == "bridge"
    ) microvmConfig.interfaces) &&
    (builtins.elem "--enable-seccomp" (qemu.configureFlags or []));

  tapMultiQueue = true;

  useHotPlugMemory = hotplugMem > 0;

  forwardingOptions = lib.concatMapStrings ({ proto, from, host, guest }: {
    host = "hostfwd=${proto}:${host.address}:${toString host.port}-" +
           "${guest.address}:${toString guest.port},";
    guest = "guestfwd=${proto}:${guest.address}:${toString guest.port}-" +
            "cmd:${pkgs.netcat}/bin/nc ${host.address} ${toString host.port},";
  }.${from}) forwardPorts;

  writeQmp = data: ''
    echo '${builtins.toJSON data}'
  '';

  kernelConsole =
    if !microvmConfig.qemu.serialConsole
    then ""
    else if system == "x86_64-linux"
    then "earlyprintk=ttyS0 console=ttyS0"
    else if system == "aarch64-linux"
    then "console=ttyAMA0"
    else "";

  systemdCredentialStrings = lib.mapAttrsToList (name: path: "name=opt/io.systemd.credentials/${name},file=${path}" ) credentialFiles;
  fwCfgOptions = systemdCredentialStrings;

in
lib.warnIf (mem == 2048) ''
  QEMU hangs if memory is exactly 2GB

  <https://github.com/microvm-nix/microvm.nix/issues/171>
''
{
  inherit tapMultiQueue;

  command = if initialBalloonMem != 0
  then throw "qemu does not support initialBalloonMem"
  else pkgs.writeShellScript "microvm-qemu-command" ''
    set -e

    args=(
      "${qemu}/bin/qemu-system-${arch}"
      "-name" "${hostName}"
      "-M" "${machineConfig}"
      "-m" "${toString mem}"
      "-smp" "$MICROVM_VCPU"
      "-nodefaults" "-no-user-config"
      "-no-reboot"
      "-kernel" "${kernelPath}"
      "-initrd" "${initrdPath}"
      "-chardev" "stdio,id=stdio,signal=off"
      "-device" "virtio-rng-${devType}"
    )

    ${lib.optionalString (machineId != null) ''
      args+=("-smbios" "type=1,uuid=${machineId}")
    ''}
    ${lib.concatMapStrings ({ id, bus, chassis, slot, addr, ... }: ''
      args+=("-device" "pcie-root-port,id=${id}${
        lib.optionalString (bus != null) ",bus=${bus}" +
        lib.optionalString (chassis != null) ",chassis=${toString chassis}" +
        lib.optionalString (slot != null) ",slot=${slot}" +
        lib.optionalString (addr != null) ",addr=${addr}"
      }")
    '') pcieRootPorts}
    ${lib.concatMapStrings ({ bus, path, qemu, ... }: {
      pci = ''
        args+=("-device" "vfio-pci,host=${path},multifunction=on${
          lib.optionalString (qemu.id != null) ",id=${qemu.id}" +
          lib.optionalString (qemu.bus != null) ",bus=${qemu.bus}" +
          lib.optionalString (qemu.deviceExtraArgs != null) ",${qemu.deviceExtraArgs}"
        }")
      '';
      usb = ''
        args+=("-device" "usb-host,${path}")
      '';
    }.${bus}) devices}
    ${lib.concatMapStrings (fwCfgOption: ''
      args+=("-fw_cfg" "${fwCfgOption}")
    '') fwCfgOptions}
    ${lib.optionalString serialConsole ''
      args+=("-serial" "chardev:stdio")
    ''}
    ${lib.optionalString (vmHostPackages.stdenv.hostPlatform.isLinux && microvmConfig.cpu == null) ''
      args+=("-enable-kvm")
    ''}
    ${lib.concatMapStrings (arg: ''
      args+=(${lib.escapeShellArg arg})
    '') cpuArgs}
    ${lib.optionalString (system == "x86_64-linux") ''
      args+=("-device" "i8042")
      args+=("-append" ${lib.escapeShellArg "${kernelConsole} reboot=t panic=-1 ${toString microvmConfig.kernelParams}"})
    ''}
    ${lib.optionalString (system == "aarch64-linux") ''
      args+=("-append" ${lib.escapeShellArg "${kernelConsole} reboot=t panic=-1 ${toString microvmConfig.kernelParams}"})
    ''}
    ${lib.optionalString storeOnDisk ''
      args+=("-drive" "id=store,format=raw,read-only=on,file=${storeDisk},if=none,aio=${aioEngine}")
      args+=("-device" "virtio-blk-${devType},drive=store${lib.optionalString (devType == "pci") ",disable-legacy=on"}")
    ''}
    ${
      if graphics.enable then
        let
          displayArgs = {
            cocoa = [
              [ "-display" "cocoa" ]
              [ "-device" "virtio-gpu" ]
            ];
            gtk = [
              [ "-display" "gtk,gl=on" ]
              [ "-device" "virtio-vga-gl" ]
            ];
          }.${graphics.backend};
        in
        lib.concatMapStrings (pair: ''
          args+=(${lib.escapeShellArg (builtins.head pair)} ${lib.escapeShellArg (builtins.elemAt pair 1)})
        '') (displayArgs ++ [
          [ "-device" "qemu-xhci" ]
          [ "-device" "usb-tablet" ]
          [ "-device" "usb-kbd" ]
        ])
      else ''
        args+=("-nographic")
      ''
    }
    ${lib.optionalString canSandbox ''
      args+=("-sandbox" "on")
    ''}
    ${lib.optionalString (user != null) ''
      args+=("-user" "${user}")
    ''}
    ${lib.optionalString (socket != null) ''
      args+=("-qmp" "unix:${socket},server,nowait")
    ''}
    ${lib.optionalString balloon ''
      args+=("-device" "virtio-balloon,free-page-reporting=on,id=balloon0${lib.optionalString deflateOnOOM ",deflate-on-oom=on"}")
    ''}
    ${lib.optionalString useHotPlugMemory ''
      args+=("-object" "memory-backend-ram,id=vmem0,size=${toString hotplugMem}M")
      args+=("-device" "virtio-mem-pci,id=vm0,memdev=vmem0,requested-size=${toString hotpluggedMem}M")
    ''}
    ${lib.concatMapStrings ({ image, letter, serial, direct, readOnly, ... }: ''
      args+=("-drive" "id=vd${letter},format=raw,file=${image},if=none,aio=${aioEngine},discard=unmap${lib.optionalString (direct != null) ",cache=none"},read-only=${if readOnly then "on" else "off"}")
      args+=("-device" "virtio-blk-${devType},drive=vd${letter}${lib.optionalString (serial != null) ",serial=${serial}"}")
    '') volumes}
    ${lib.optionalString (shares != []) (
      lib.optionalString vmHostPackages.stdenv.hostPlatform.isLinux ''
        args+=("-numa" "node,memdev=mem")
        args+=("-object" "memory-backend-memfd,id=mem,size=${toString mem}M,share=on")
      '' +
      lib.concatMapStrings ({ proto, index, socket, source, tag, securityModel, readOnly, ... }: {
        "virtiofs" = ''
          args+=("-chardev" "socket,id=fs${toString index},path=${socket}")
          args+=("-device" "vhost-user-fs-${devType},chardev=fs${toString index},tag=${tag}")
        '';
        "9p" = ''
          args+=("-fsdev" "local,id=fs${toString index},path=${source},security_model=${securityModel},readonly=${lib.boolToString readOnly}")
          args+=("-device" "virtio-9p-${devType},fsdev=fs${toString index},mount_tag=${tag}")
        '';
      }.${proto}) (enumerate 0 shares)
    )}
    ${lib.warnIf (
      forwardPorts != [] &&
      ! builtins.any ({ type, ... }: type == "user") interfaces
    ) "${hostName}: forwardPortsOptions only running with user network" (
      lib.concatMapStrings ({ type, id, mac, bridge, tap ? {}, ... }: ''
        netdev="${if type == "macvtap" then "tap" else type},id=${id}"
        ${lib.optionalString (type == "user" && forwardPorts != []) ''
          netdev="$netdev,${forwardingOptions}"
        ''}
        ${lib.optionalString (type == "bridge") ''
          netdev="$netdev,br=${bridge},helper=/run/wrappers/bin/qemu-bridge-helper"
        ''}
        ${lib.optionalString (type == "tap") ''
          netdev="$netdev,ifname=${id},script=no,downscript=no"
        ''}
        ${lib.optionalString (type == "tap" && tap.vhost or false) ''
          netdev="$netdev,vhost=on"
        ''}
        ${lib.optionalString (type == "macvtap") ''
          if [ "$MICROVM_TAP_MULTI_QUEUE" -eq 1 ]; then
            netdev="$netdev,fds=${macvtapFdColonList id}"
          else
            netdev="$netdev,fd=${macvtapFd id}"
          fi
        ''}
        ${lib.optionalString (type == "tap") ''
          if [ "$MICROVM_TAP_MULTI_QUEUE" -eq 1 ]; then
            netdev="$netdev,queues=$MICROVM_VCPU"
          fi
        ''}
        args+=("-netdev" "$netdev")

        device="virtio-net-${devType},netdev=${id},mac=${mac}${
          lib.optionalString (
            requirePci ||
            (microvmConfig.cpu == null && system != "x86_64-linux")
          ) ",romfile="
        }"
        if [ "$MICROVM_TAP_MULTI_QUEUE" -eq 1 ] && [ ${if requirePci then "1" else "0"} -eq 1 ]; then
          device="$device,mq=on,vectors=$MICROVM_VCPU_X2_PLUS2"
        fi
        args+=("-device" "$device")
      '') interfaces
    )}
    ${lib.optionalString requireUsb ''
      args+=("-device" "qemu-xhci")
    ''}
    ${lib.optionalString (vsock.cid != null) ''
      args+=("-device" "vhost-vsock-${devType},guest-cid=${toString vsock.cid}")
    ''}
    ${lib.concatMapStrings (arg: ''
      args+=(${lib.escapeShellArg arg})
    '') extraArgs}

    ${if microvmConfig.prettyProcnames then ''exec -a "microvm@${hostName}"'' else "exec"} "''${args[@]}" "$@"
  '';

  canShutdown = socket != null;

  shutdownCommand =
    if socket != null
    then
      ''
        # Exit gracefully if QEMU is already gone (e.g., killed by machinectl)
        if [ ! -S ${socket} ]; then
          exit 0
        fi

        (
          ${writeQmp { execute = "qmp_capabilities"; }}
          ${writeQmp {
            execute = "input-send-event";
            arguments.events = [ {
              type = "key";
              data = {
                down = true;
                key = {
                  type = "qcode";
                  data = "ctrl";
                };
              };
            } {
              type = "key";
              data = {
                down = true;
                key = {
                  type = "qcode";
                  data = "alt";
                };
              };
            } {
              type = "key";
              data = {
                down = true;
                key = {
                  type = "qcode";
                  data = "delete";
                };
              };
            } ];
          }}
           # wait for exit
          cat
        ) | \
        ${vmHostPackages.socat}/bin/socat STDIO UNIX:${socket},shut-none
    ''
    else throw "Cannot shutdown without socket";

  setBalloonScript =
    if socket != null
    then ''
      VALUE=$(( $SIZE * 1024 * 1024 ))
      SIZE=$( (
        ${writeQmp { execute = "qmp_capabilities"; }}
        ${writeQmp { execute = "balloon"; arguments.value = 987; }}
      ) | sed -e s/987/$VALUE/ | \
        ${vmHostPackages.socat}/bin/socat STDIO UNIX:${socket},shut-none | \
        tail -n 1 | \
        ${vmHostPackages.jq}/bin/jq -r .data.actual \
      )
      echo $(( $SIZE / 1024 / 1024 ))
    ''
    else null;

  requiresMacvtapAsFds = true;
}
