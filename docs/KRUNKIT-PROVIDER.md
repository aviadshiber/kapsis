# Podman `libkrun`/`krunkit` Machine Provider (Opt-In)

Tracks [Issue #409](https://github.com/aviadshiber/kapsis/issues/409). This document is the
opt-in adoption guide referenced from `docs/STATUS-TRACKING.md`.

## Background

Kapsis's macOS mitigations for virtio-fs mount drops (sleep-prevention `caffeinate`, the
vfkit watchdog, status-volume mirroring — see `CLAUDE.md`'s Mount Failure Detection section)
exist because of a bug in Apple's Virtualization.framework (AVF) virtio-fs implementation,
tracked upstream as Apple Feedback FB16008360. Podman's `libkrun` machine provider (hypervisor
process `krunkit`) bypasses AVF entirely — it talks to `Hypervisor.framework` directly and
implements its own virtio-fs server — so it structurally cannot hit that bug class. Podman
made `libkrun` the **default** macOS provider in v6.0.0 (2026-06-24).

**Kapsis does not default to `libkrun`.** As of this writing the switch is recent, there's an
open filesystem-performance regression report against it
([podman#29087](https://github.com/containers/podman/issues/29087)), and sleep/wake behavior
under `libkrun` is publicly unvalidated. Kapsis's existing mitigation stack keeps working
under either provider (see the table below) — nothing is removed for `libkrun` adopters.

## Requirements

- macOS 14+, **Apple Silicon only** (Intel Macs cannot use `libkrun`)
- `krunkit` >= 1.3.1 (earlier versions had virtio-fs permission-semantics bugs, fixed through
  June 2026 in [libkrun#759](https://github.com/libkrun/libkrun/pull/759),
  [libkrun#734](https://github.com/libkrun/libkrun/pull/734))
- Podman >= 6.0.0

## Installing krunkit

`brew install podman` does **not** bundle `krunkit`. Install it separately:

```bash
brew tap libkrun/krun
brew install krunkit
```

(The Podman GitHub `.pkg` installer bundles `krunkit`, so this step is only needed for
Homebrew-installed Podman.)

## Trying it

There is no in-place conversion — a new machine is required, and Podman machines from
different providers coexist (only one runs at a time):

```bash
podman machine stop                                  # stop the current machine
podman machine init --provider libkrun kapsis-libkrun
podman machine start kapsis-libkrun
```

**Cost of switching:** images and named volumes (including Kapsis's per-agent Maven/Gradle
caches and `kapsis-*-status` volumes) live inside the machine's disk, not shared across
machines. Expect to rebuild the Kapsis base image (`./scripts/build-image.sh`) and warm caches
again on a new `libkrun` machine.

**No Rosetta under `libkrun`** (Rosetta requires AVF). Kapsis builds arch-native arm64 images,
so this has low impact — it would only matter if you deliberately run amd64-only images.

## Verifying detection

Kapsis detects the active provider at launch (macOS + Podman backend only) and records it in
`status.json` as `machine_provider` (see `docs/STATUS-TRACKING.md`):

```bash
./scripts/launch-agent.sh ~/project --agent claude --task "..." &
./scripts/kapsis-status.sh --json | grep machine_provider
```

You can also query it directly:

```bash
podman machine inspect kapsis-libkrun --format '{{.VMType}}'
```

## Mitigation status under `libkrun`

| Mitigation | Under `libkrun` | Status |
|---|---|---|
| vfkit/krunkit watchdog (Issue #303) | Provider-agnostic — matches both `vfkit` and `krunkit` process names | Active |
| Sleep prevention (`caffeinate`, Issue #276) | Root-cause trigger (AVF) doesn't apply, but unvalidated across sleep/wake under `libkrun` | Active (not yet a retirement candidate) |
| Status volume mirroring (Issue #276) | Exists solely for AVF bind-mount drops | Active (not yet a retirement candidate) |
| Pre-launch/entrypoint/liveness mount probes | Provider-agnostic | Active |

None of these are gated on provider today — do not assume a `libkrun` host is exempt from a
mount-failure exit code (4) until there is field evidence, not just theory, that it can't
recur under `libkrun`.

## Known open issues (tracked upstream, not by Kapsis)

- FS-heavy workload performance regression after upgrading to Podman 6.0's `libkrun` default:
  [podman#29087](https://github.com/containers/podman/issues/29087)
- Only one Podman machine runs at a time, complicating A/B testing:
  [podman#26281](https://github.com/containers/podman/issues/26281)

## Recommendation

Treat this as an **opt-in experiment**, not a default. If you try it, watch for the same
symptoms the existing mitigations were built for (spurious `EACCES`/`ENOENT` under load, mount
drops after sleep/wake) and report back on Issue #409 — a multi-week clean run is the bar for
Kapsis to consider retiring any `applehv`-specific mitigation or recommending `libkrun` as the
default on eligible hosts.
