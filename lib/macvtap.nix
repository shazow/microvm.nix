{ microvmConfig, hypervisorConfig, lib }:

let
  tapMultiQueue = hypervisorConfig.tapMultiQueue or false;
  interfaceFdOffset = 3;
  macvtapInterfaces =
    builtins.filter ({ type, ... }:
      type == "macvtap"
    ) microvmConfig.interfaces;

  macvtapIndices = builtins.listToAttrs (
    lib.imap0 (interfaceIndex: { id, ... }: {
      name = id;
      value = interfaceIndex;
    }) macvtapInterfaces
  );

  sanitizeId = id:
    builtins.replaceStrings [ "-" "." ] [ "_" "_" ] id;

in {
  openMacvtapFds = ''
    MICROVM_MACVTAP_QUEUE_COUNT=${if tapMultiQueue then ''"$MICROVM_VCPU"'' else "1"}

    microvm_macvtap_fd_base() {
      echo $(( ${toString interfaceFdOffset} + $1 * MICROVM_MACVTAP_QUEUE_COUNT ))
    }

    microvm_macvtap_fd_single() {
      microvm_macvtap_fd_base "$1"
    }

    microvm_macvtap_fd_colon_list() {
      local index=$1
      local base
      local fd
      local i=0
      local out=""

      base=$(microvm_macvtap_fd_base "$index")
      while [ "$i" -lt "$MICROVM_MACVTAP_QUEUE_COUNT" ]; do
        fd=$((base + i))
        if [ -n "$out" ]; then
          out="$out:$fd"
        else
          out="$fd"
        fi
        i=$((i + 1))
      done
      printf '%s' "$out"
    }

    microvm_macvtap_fd_csv_list() {
      local index=$1
      local base
      local fd
      local i=0
      local out=""

      base=$(microvm_macvtap_fd_base "$index")
      while [ "$i" -lt "$MICROVM_MACVTAP_QUEUE_COUNT" ]; do
        fd=$((base + i))
        if [ -n "$out" ]; then
          out="$out,$fd"
        else
          out="$fd"
        fi
        i=$((i + 1))
      done
      printf '%s' "$out"
    }

    # Open macvtap interface file descriptors
  '' +
  lib.concatMapStrings (interface:
    let
      inherit (interface) id;
      index = macvtapIndices.${id};
    in ''
      ifindex=$(< /sys/class/net/${id}/ifindex)
      i=0
      while [ "$i" -lt "$MICROVM_MACVTAP_QUEUE_COUNT" ]; do
        fd=$(( $(microvm_macvtap_fd_base ${toString index}) + i ))
        eval "exec $fd<>/dev/tap$ifindex"
        i=$((i + 1))
      done

      MICROVM_MACVTAP_FD_${sanitizeId id}=$(microvm_macvtap_fd_single ${toString index})
      MICROVM_MACVTAP_FDS_COLON_${sanitizeId id}=$(microvm_macvtap_fd_colon_list ${toString index})
      MICROVM_MACVTAP_FDS_CSV_${sanitizeId id}=$(microvm_macvtap_fd_csv_list ${toString index})
      export MICROVM_MACVTAP_FD_${sanitizeId id} MICROVM_MACVTAP_FDS_COLON_${sanitizeId id} MICROVM_MACVTAP_FDS_CSV_${sanitizeId id}
    ''
  ) macvtapInterfaces;

  macvtapFd = id: "$MICROVM_MACVTAP_FD_${sanitizeId id}";
  macvtapFdColonList = id: "$MICROVM_MACVTAP_FDS_COLON_${sanitizeId id}";
  macvtapFdCsvList = id: "$MICROVM_MACVTAP_FDS_CSV_${sanitizeId id}";
}
