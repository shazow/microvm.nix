# Runtime-Resolved `microvm.vcpu` Fresh Attempt Spec

## Purpose

This document captures:

- The recommended fresh-attempt plan after implementing the broader solution currently on branch `qemu-nproc` at commit `beddfe4`
- What the broader diff against `main` taught us
- A phased path that keeps risk and review surface small

The current branch demonstrates that the full end-to-end idea works, but it also shows that generalizing too early creates avoidable complexity. A fresh attempt should start smaller.

## Current Diff Summary

Compared to `main`, the current branch changes:

- `microvm.vcpu` from an integer-only option to an integer-or-special-string option
- Runtime launch plumbing in `lib/runner.nix`
- Host TAP setup in `nixos-modules/microvm/interfaces.nix`
- macvtap FD handling in `lib/macvtap.nix`
- Every major runner:
  - `qemu`
  - `cloud-hypervisor`
  - `firecracker`
  - `crosvm`
  - `kvmtool`
  - `alioth`
  - `stratovirt`
  - `vfkit`
- Docs and tests

That broad scope proved the concept, but it is larger than necessary for a first upstreamable patch.

## Step 1: Minimal QEMU-Only Implementation

This should be the first fresh-attempt patch.

### Goal

Support runtime-resolved `microvm.vcpu` only for:

- `microvm.hypervisor = "qemu"`
- non-`macvtap` qemu configurations

### Behavior

- `microvm.vcpu` accepts either:
  - a positive integer
  - the special string `` `nproc` ``
- The special string is resolved on the runtime host
- The resolved value must be a positive integer

### Implementation boundaries

- Touch only:
  - `nixos-modules/microvm/options.nix`
  - `nixos-modules/microvm/asserts.nix`
  - `nixos-modules/microvm/interfaces.nix`
  - `lib/runner.nix`
  - `lib/runners/qemu.nix`
  - qemu-focused docs/tests
- Do not change:
  - `lib/macvtap.nix`
  - non-qemu runners
  - generalized runtime helper surfaces

### Assertions

Add explicit assertions:

- If `microvm.vcpu` is a string, `microvm.hypervisor` must be `qemu`
- If `microvm.vcpu` is a string, qemu `macvtap` interfaces are unsupported for now

### Runtime plumbing

- Export exactly one runtime value:
  - `MICROVM_VCPU`
- Validate it in `microvm-run`
- Do not add precomputed helper env vars such as:
  - `MICROVM_VCPU_X2`
  - `MICROVM_VCPU_X2_PLUS2`
  - `MICROVM_VCPU_MIN16`

### QEMU-specific handling

- Keep qemu as close to `main` as possible
- Use inline shell arithmetic where needed inside qemu-only runtime code
- Add a short TODO near `vectors=` / queue sizing noting future optimization opportunities

### TAP handling

- For integer `vcpu`, keep current behavior
- For qemu string `vcpu`, resolve at runtime in `tap-up`
- Add `multi_queue` only when the resolved CPU count is greater than 1

### Tests

- One positive qemu test with `` microvm.vcpu = "`nproc`" ``
- One negative restriction test for string `vcpu` on a non-qemu hypervisor
- One negative restriction test for qemu + string `vcpu` + `macvtap`

## Step 2: QEMU `macvtap` Support

Only do this after Step 1 lands cleanly.

### Why this is separate

`macvtap` forces runtime FD layout decisions when queue counts depend on runtime `vcpu`. That pulls `lib/macvtap.nix` into scope and increases risk noticeably.

### Scope

- Update `lib/macvtap.nix` only as needed
- Preserve qemu process naming and existing FD semantics
- Add focused qemu `macvtap` coverage

### Design guidance

- Prefer computing only what qemu needs
- Keep values concrete before they cross any wrapper-shell boundary
- Avoid introducing generic abstractions unless another backend truly needs the same shape

## Step 3: Add Firecracker

Firecracker is the next best candidate after qemu.

### Why

- It has a small CPU surface area
- The main extra work is runtime JSON generation for `vcpu_count`

### Scope

- Limit changes to `lib/runners/firecracker.nix`
- Reuse the same single runtime value, `MICROVM_VCPU`
- Do not generalize other runner plumbing yet

## Step 4: Add Simple CLI Backends

After qemu and firecracker, consider:

- `crosvm`
- `kvmtool`
- `vfkit`

### Why

These are comparatively simple because `vcpu` is mostly a direct CLI argument, but they still need careful treatment of:

- extra args
- process naming
- any runtime shell boundary introduced by implementation choices

## Step 5: Add Complex Queue-Derived Backends

Leave these for last:

- `cloud-hypervisor`
- `alioth`
- `stratovirt`

### Why

These runners use `vcpu` not just for CPU count, but also for:

- queue counts
- vector counts
- other derived runtime settings

This is where generalized helper variables are tempting. The current branch shows that introducing those early increases complexity and review burden.

## Lessons From The Current Broad Implementation

### 1. Generalizing early made the patch much larger than necessary

The current branch touched 15 files and every major runner. That widened the review surface before the qemu-only path was settled.

### 2. Wrapper scripts create hidden boundary problems

Moving command construction into wrapper scripts introduced regressions that had to be fixed later:

- macvtap fd helper functions were no longer visible across the shell boundary
- `prettyProcnames` applied to the wrapper instead of the actual hypervisor process
- runner-specific extras such as `crosvm.extraArgs` were easy to drop accidentally

Fresh attempt guidance:

- Avoid wrapper scripts unless they are clearly required
- If a wrapper is required, preserve:
  - process naming on the final hypervisor process
  - runtime args passthrough
  - shell-boundary-sensitive values such as open FDs

### 3. One runtime value is easier to reason about than many derived env vars

The current branch introduced several precomputed helper values. That works, but it obscures what each backend actually needs.

Fresh attempt guidance:

- Start with `MICROVM_VCPU` only
- Do inline qemu arithmetic where required
- Add derived helpers only when repeated backend usage proves they are worth it

### 4. `virtiofsd.threadPoolSize` already established the `nproc` pattern

The current branch confirmed that `virtiofsd.threadPoolSize` already accepts the special string `\`nproc\``. It works because the string is interpolated directly into a shell command.

Fresh attempt guidance:

- Mirror that behavior deliberately for `microvm.vcpu`
- Still validate the resolved result before passing it to the hypervisor

### 5. Host-side networking is part of the feature

For qemu, this is not only about `-smp`. TAP `multi_queue` behavior must match the resolved CPU count.

Fresh attempt guidance:

- Treat host interface setup as part of the qemu implementation, not as optional follow-up
- Keep `macvtap` out of scope initially to avoid pulling in FD-layout complexity

## Guidance For A Future Fresh Attempt

Start from `main`, not from the broad branch, and keep the first patch intentionally small.

Recommended sequence:

1. Implement qemu-only string `vcpu` support with one runtime value and two explicit restriction assertions.
2. Add qemu TAP runtime handling and the minimal positive/negative tests.
3. Land that first.
4. Add qemu `macvtap` only after the qemu-only core is stable.
5. Expand backend support one hypervisor family at a time.

Code-review guidance:

- Prefer small backend-specific runtime logic over early frameworking
- Keep diffs local to the backend being enabled
- Add TODOs for optimization opportunities instead of solving every derived-value case in v1

Success criteria for the fresh attempt:

- Small diff against `main`
- qemu string `vcpu` works with TAP
- unsupported combinations fail with clear assertions
- no changes to unrelated hypervisors in the first patch
