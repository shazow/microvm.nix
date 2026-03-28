{ config, lib, pkgs, ... }:

let
  interfacesByType = wantedType:
    builtins.filter ({ type, ... }: type == wantedType)
      config.microvm.interfaces;

  tapInterfaces = interfacesByType "tap";
  macvtapInterfaces = interfacesByType "macvtap";
  dynamicQemuVcpu =
    config.microvm.hypervisor == "qemu" &&
    builtins.isString config.microvm.vcpu;

  staticTapFlags = lib.concatStringsSep " " (
    [ "vnet_hdr" ] ++
    lib.optional config.microvm.declaredRunner.passthru.tapMultiQueue "multi_queue"
  );

  # TODO: don't hardcode but obtain from host config
  user = "microvm";
  group = "kvm";
in
{
  microvm.binScripts = lib.mkMerge [ (
    lib.mkIf (tapInterfaces != []) {
      tap-up = ''
        set -eou pipefail
        TAP_FLAGS='${staticTapFlags}'
      '' + lib.optionalString dynamicQemuVcpu ''
        TAP_FLAGS='vnet_hdr'
        MICROVM_TAP_VCPU=${toString config.microvm.vcpu}

        case "$MICROVM_TAP_VCPU" in
          ""|*[!0-9]*)
            echo "tap-up: microvm.vcpu resolved to invalid value: $MICROVM_TAP_VCPU" >&2
            exit 1
            ;;
        esac

        if [ "$MICROVM_TAP_VCPU" -le 0 ]; then
          echo "tap-up: microvm.vcpu must resolve to a positive integer: $MICROVM_TAP_VCPU" >&2
          exit 1
        fi

        if [ "$MICROVM_TAP_VCPU" -gt 1 ]; then
          TAP_FLAGS="$TAP_FLAGS multi_queue"
        fi
      '' + lib.concatMapStrings ({ id, ... }: ''
        if [ -e /sys/class/net/${id} ]; then
          ${lib.getExe' pkgs.iproute2 "ip"} link delete '${id}'
        fi

        ${lib.getExe' pkgs.iproute2 "ip"} tuntap add name '${id}' mode tap user '${user}' $TAP_FLAGS
        ${lib.getExe' pkgs.iproute2 "ip"} link set '${id}' up
      '') tapInterfaces;

      tap-down = ''
        set -ou pipefail
      '' + lib.concatMapStrings ({ id, ... }: ''
        ${lib.getExe' pkgs.iproute2 "ip"} link delete '${id}'
      '') tapInterfaces;
    }
  ) (
    lib.mkIf (macvtapInterfaces != []) {
      macvtap-up = ''
        set -eou pipefail
      '' + lib.concatMapStrings ({ id, mac, macvtap, ... }: ''
        if [ -e /sys/class/net/${id} ]; then
          ${lib.getExe' pkgs.iproute2 "ip"} link delete '${id}'
        fi
        ${lib.getExe' pkgs.iproute2 "ip"} link add link '${macvtap.link}' name '${id}' address '${mac}' type macvtap mode '${macvtap.mode}'
        ${lib.getExe' pkgs.iproute2 "ip"} link set '${id}' allmulticast on
        if [ -f "/proc/sys/net/ipv6/conf/${id}/disable_ipv6" ]; then
          echo 1 > "/proc/sys/net/ipv6/conf/${id}/disable_ipv6"
        fi
        ${lib.getExe' pkgs.iproute2 "ip"} link set '${id}' up
        ${pkgs.coreutils-full}/bin/chown '${user}:${group}' /dev/tap$(< "/sys/class/net/${id}/ifindex")
      '') macvtapInterfaces;

      macvtap-down = ''
        set -ou pipefail
      '' + lib.concatMapStrings ({ id, ... }: ''
        ${lib.getExe' pkgs.iproute2 "ip"} link delete '${id}'
      '') macvtapInterfaces;
    }
  ) ];
}
