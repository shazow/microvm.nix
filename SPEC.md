# Runtime-Resolved `microvm.vcpu` Next Iteration Spec

## Purpose

This document captures:

- what has already landed for runtime-resolved `microvm.vcpu`
- what the next iteration should implement
- the boundaries that should keep the next patch small and reviewable

This is no longer a "fresh attempt" note. The qemu-only non-`macvtap` path is implemented already. The next patch should extend that work without reopening the broader all-runners design.

## Current Status

The current branch has already landed the minimal qemu-first implementation in:

- `6f31464` `Add qemu runtime support for nproc vcpu`
- `36418fb` `Clarify vcpu string semantics`

That implementation currently provides:

- `microvm.vcpu` as a string-or-int option, matching the `microvm.virtiofsd.threadPoolSize` model
- qemu support for runtime-resolved string `vcpu` values on non-`macvtap` configurations
- one exported runtime value, `MICROVM_VCPU`
- runtime validation of the resolved value in `microvm-run`
- qemu TAP handling that resolves string `vcpu` at runtime and enables `multi_queue` only when the resolved count is greater than 1
- explicit assertions that reject:
  - string `vcpu` on non-qemu hypervisors
  - qemu with string `vcpu` plus `macvtap`
- focused docs and tests for the qemu non-`macvtap` path

## What Remains

The main missing qemu piece is:

- qemu `macvtap` support when `microvm.vcpu` is a string

After that, the next reasonable backend to consider remains:

- firecracker

But the immediate next iteration should be only qemu `macvtap`.

## Next Iteration Goal

Support runtime-resolved string `microvm.vcpu` for:

- `microvm.hypervisor = "qemu"`
- qemu configurations using `type = "macvtap"`

The new work should preserve all behavior already implemented for:

- integer `vcpu`
- qemu + TAP
- qemu process naming
- existing extra-args passthrough
- current open-FD semantics for `macvtap`

## Required Behavior

- `microvm.vcpu` continues to accept:
  - a positive integer
  - a string value such as `` `nproc` ``
- The string continues to be resolved on the runtime host.
- The resolved value must continue to be validated as a positive integer before qemu consumes it.
- qemu `macvtap` must work when the queue count depends on the resolved runtime CPU count.
- Existing integer `vcpu` behavior must remain unchanged.

## Scope

The next patch should touch only what qemu `macvtap` needs:

- `lib/macvtap.nix`
- qemu-specific runtime plumbing where required
- qemu-focused tests
- docs if the user-visible behavior changes

It should not:

- add support for other hypervisors
- introduce generic cross-backend helper env vars unless they are clearly unavoidable
- restructure unrelated runner code just for symmetry

## Design Constraints

### 1. Keep values concrete before shell boundaries

`macvtap` is different from TAP because queue-dependent behavior affects FD layout. The next patch should prefer computing qemu-specific concrete values before they cross any wrapper-shell boundary.

### 2. Preserve final process naming

If a wrapper script becomes necessary, `prettyProcnames` must still apply to the actual qemu process, not just to a wrapper shell.

### 3. Preserve runtime arg passthrough

Any qemu-specific wrapper or command restructuring must continue to preserve runtime extra arguments exactly as today.

### 4. Preserve FD semantics

Open `macvtap` file descriptors must remain visible where qemu needs them. Avoid designs that accidentally hide helper functions or FD state behind an extra shell boundary.

### 5. Keep helper surface minimal

The current design intentionally exports only:

- `MICROVM_VCPU`

The next iteration should continue that approach unless qemu `macvtap` support proves that another concrete runtime value is truly necessary. If another value is needed, keep it qemu-local rather than introducing an early generic abstraction.

## Implementation Guidance

- Start from the current branch state, not from the old broad prototype.
- Update `lib/macvtap.nix` only as far as required to let qemu consume the correct runtime FD layout.
- Prefer qemu-local logic over frameworking.
- Keep the non-`macvtap` qemu path as unchanged as possible.
- Add small qemu-local TODOs instead of over-solving future backend needs.

## Tests

The next patch should add focused coverage for qemu `macvtap` with string `vcpu`.

Minimum test additions:

- one positive qemu + string `vcpu` + `macvtap` test
- coverage that exercises queue-dependent `macvtap` FD behavior

Existing negative coverage for qemu + string `vcpu` + `macvtap` should be updated or replaced once support lands.

## Still Out Of Scope

Do not combine qemu `macvtap` support with:

- firecracker support
- crosvm, kvmtool, or vfkit support
- cloud-hypervisor, alioth, or stratovirt queue-derived support
- generalized helper env var design for all backends

Those can be revisited only after qemu `macvtap` lands cleanly.

## Success Criteria

The next iteration is successful when:

- qemu supports string `microvm.vcpu` with `macvtap`
- integer `vcpu` behavior is unchanged
- qemu TAP behavior remains unchanged
- qemu process naming and runtime arg passthrough remain correct
- `macvtap` FD handling still works with runtime-resolved queue counts
- the patch stays local to qemu `macvtap` concerns rather than reopening the broad all-runners design
