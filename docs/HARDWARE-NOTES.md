# Hardware notes

Everything here was measured on a real machine, not inferred. Where a number
comes from one specific NAS it says so, because the point of this document is to
help you tell which findings should generalise and which should not.

Reference machine: QNAP TS-855X, Intel Atom C5125 (8 cores), 62.5 GB RAM,
NVIDIA RTX A2000 12GB (GA106, sm_86, 70 W), driver 575.64.05 / CUDA 12.9,
QTS 6.0.2, Container Station 3.1.2 (3.1.4 from ComfyUI v0.35.1 on), storage on
a tiered ZFS pool.

## 1. CPUs without AVX2 crash, and the traceback points at the wrong file

The Atom C5125 is a Tremont core. Its `/proc/cpuinfo` flags stop at `sse4_2`:
no AVX at all, let alone AVX2. The `kornia_rs` wheels from 0.1.13 onward contain
instructions it cannot execute.

The failure is `Fatal Python error: Illegal instruction`. It has three layers of
disguise:

- `pip install` completes normally.
- The reported crash site is `comfy_extras/nodes_post_processing.py`, which
  simply imports `kornia`. The actual fault is inside the `kornia_rs` native
  extension, several imports deeper.
- The output is a fatal interpreter dump rather than a Python exception, so it
  reads like a GPU or memory problem.

Versions 0.1.10 and older are fine, and `kornia` 0.8.3 accepts 0.1.10 without a
dependency conflict. The Dockerfile checks for `avx2` in `/proc/cpuinfo` at
build time and only pins when it is absent. Container builds see the host CPU
flags, so the check is accurate.

If your NAS has a modern Intel Core or AMD Ryzen part this does not apply and
the pin is skipped automatically.

## 2. CUDA can stop initialising after long uptime

Symptom: inside the container `cuInit()` returns `CUDA_ERROR_NOT_INITIALIZED`,
while `nvidia-smi -L` correctly lists the GPU, all `/dev/nvidia*` nodes are
present, and `libcuda.so.1` is injected. It looks exactly like a container
configuration problem, and it is not.

The kernel log gives it away:

```
NVRM: sysmemConstruct_IMPL: *** Cannot allocate sysmem through fb heap
NVRM: Out of memory [NV_ERR_NO_MEMORY] @ mem_desc.c:1353
```

This is fragmentation, not exhaustion. At the time of the failure `MemFree` was
15.8 GB, but `/proc/buddyinfo` showed zero free blocks at order 7 and above in
the Normal zone, and unreclaimable slab held 6.5 GB. The driver could not get
the physically contiguous allocation it needs.

The timeline confirms it. The driver loaded 362 seconds after boot; the first
allocation failure was at 50107 seconds, so roughly the first 14 hours were
healthy. After a reboot, order-10 blocks went from 0 to 14261 and CUDA worked
immediately.

Diagnose with `/proc/buddyinfo`, not `free`. The fix is a reboot, or
`vm.compact_memory` if you have root. This is a host condition and will affect
any GPU workload on the machine, not just this package.

Related: on this machine the NVIDIA kernel modules load **345 seconds after
boot**. Checking earlier than that shows no driver at all. Container Station
can also come up after this package: on one boot the service script found no
docker binary at all, gave up, and ComfyUI stayed down until started by hand.
The service script now waits up to 600 seconds for the docker binary, the
device node and the runtime registration together.

## 3. GPU passthrough details that are not optional

Container Station registers the runtime as **`nvidia-runtime`**, not the usual
`nvidia`. Confirm with `docker info | grep Runtimes`.

Do not use `deploy.resources.reservations.devices`. Compose translates it into a
device request carrying `Driver: "nvidia"`, which does not match the registered
name, and Compose v2 support for `deploy` outside swarm is limited anyway.

Both of these environment variables are required:

- `NVIDIA_VISIBLE_DEVICES=all`. The runtime config leaves
  `accept-nvidia-visible-devices-envvar-when-unprivileged` at its default of
  true, so the hook reads the variable to decide what to expose. Unset behaves
  as `void` and the container sees no GPU.
- `NVIDIA_DRIVER_CAPABILITIES=compute,utility`. With only `utility` you get a
  working `nvidia-smi` but no `libcuda.so.1`, and PyTorch quietly reports CUDA
  as unavailable. This is the most misleading failure of the set, which is why
  the entrypoint refuses to start rather than falling back to CPU.

If the runtime approach fails entirely, raw device passthrough works as a
fallback. Mount the driver's user-space libraries and set `LD_LIBRARY_PATH` to
`<NVIDIA_GPU_DRV>/usr/nvidia`. Note that QNAP's own Jellyfin package points at
`/usr/local/nvidia/lib64`, and there is no `lib64` directory under that QPKG, so
do not copy that configuration.

## 4. Fitting in VRAM beats native quantized kernels

Measured on the A2000 12GB with a 12.9B parameter model, 1024x1024, 8 steps,
same seed:

| Weight format | File size | Cold | Warm | Peak VRAM | Kernels |
| --- | ---: | ---: | ---: | ---: | --- |
| int8 with rotation | 12.57 GiB | 228 s | 100 s | 7725 MiB | native |
| nvfp4 | 7.15 GiB | 84 s | **56 s** | 9227 MiB | emulated |

The emulated format is 1.79 times faster than the native one, with no visible
quality difference at the same seed.

The cause is capacity, not kernel efficiency. ComfyUI prints which paths it
takes at startup:

```
Native ops: int8_tensorwise, asym_w4a8_int8, convrot_w4a4
emulated ops: float8_e4m3fn, nvfp4, mxfp8, float8_e5m2
```

Note that fp8 is emulated on sm_86 as well. The int8 file at 12.57 GiB does not
fit in 11.9 GiB of VRAM, so DynamicVRAM streams weights every step. **The larger
model showing lower peak VRAM is the evidence for streaming**: 7725 MiB against
9227 MiB. The PCIe round trips cost far more than dequantization.

So on a 12 GB card the first criterion when choosing a quantization is whether
the weights plus activations fit in the available VRAM, and only then the
efficiency of the format. This is the opposite of the intuition that holds on
large-VRAM cards.

## 5. Model path resolution has three silent traps

From `folder_paths.py` in ComfyUI:

1. `diffusion_models` searches both `models/diffusion_models` and `models/unet`
   by default.
2. `text_encoders` is bound to both `models/text_encoders` and `models/clip`,
   and `map_legacy` maps the `clip` key onto `text_encoders`. Two keys in your
   YAML therefore merge into one namespace rather than staying separate.
3. `is_default: true` makes the loader `insert(0, ...)` for every path, so a
   multi-line block ends up searched in **reverse** order. The last line wins.

`get_full_path` returns the first hit with no warning, and the dropdown
deduplicates by filename, so a name collision between two roots is invisible.
The common real case is `clip_l.safetensors` existing in both `clip/` and
`text_encoders/` at different sizes.

Verify by asking ComfyUI itself rather than reading the UI:

```python
import sys; sys.path.insert(0, "/opt/ComfyUI")
import folder_paths
from utils.extra_config import load_extra_path_config
load_extra_path_config("/opt/ComfyUI/extra_model_paths.yaml")
print(folder_paths.get_full_path("text_encoders", "clip_l.safetensors"))
```

A bare import is not enough; the extra paths only exist after
`load_extra_path_config`.

## 6. Command line flags to avoid

| Flag | Why not |
| --- | --- |
| `--lowvram` | A no-op while DynamicVRAM is enabled, as its own help text says |
| `--highvram`, `--gpu-only`, `--novram`, `--cpu` | Each one disables DynamicVRAM |
| `--fast-disk` | Streams weights from disk every step. Cold reads on the reference machine measured 145.9 MB/s against 4.9 GB/s warm |
| `--supports-fp8-compute` | Claims a capability sm_86 does not have |

`comfy-aimdo` and `comfy-kitchen` are upstream dependencies, not optional
extras. `comfy-aimdo` implements DynamicVRAM and is what makes models larger
than VRAM work at all. Do not strip them from `requirements.txt`.

## 7. QTS shell environment gaps

Scripts written for a normal Linux box fail here in quiet ways.

| Expected | Reality on QTS 6.0.2 (busybox 1.24.1) |
| --- | --- |
| `git` | Absent. Fetch tarballs from `codeload.github.com` |
| `nohup` | Absent. Use `setsid cmd > log 2>&1 < /dev/null &` |
| `scp`, `sftp` | Absent. Use `ssh host 'cat > file' < localfile` |
| `/bin/readlink` | It is `/usr/bin/readlink`. A wrong path plus `2>/dev/null` silently takes your fallback branch |
| `curl` | In `/sbin`, not `/usr/bin` |
| `arch`, `nproc`, `free -h` | Absent or unsupported. Use `free -m` |
| `jq` | Absent, which breaks QNAP's own `container-station.sh status` |

The Docker CLI needs a writable home, otherwise it fails with
`mkdir .../container-station/homes/<user>: permission denied`:

```sh
export HOME=/share/Container/comfyui
export DOCKER_CONFIG=$HOME/.docker
```

`qpkg_cli` run as a non-root user **returns 0 and does nothing**. Installation
needs root or App Center.

## 8. Containers on the NAS cannot reach the NAS LAN address

A bridge-network container on the NAS cannot open a TCP connection to the NAS's
own LAN IP. It times out rather than being refused, and ICMP still works, so it
looks like the service is down. The bridge gateway address does not work either.

If another container needs to call ComfyUI, put both on the same Docker network
and use the container name:

```sh
docker network connect <other_stack>_default comfyui
# then reach it at http://comfyui:8188
```

Note that `docker network connect` applied to a running container is lost on the
next `compose up`. To make it permanent, add the network to
`docker-compose.yml`.

## 9. Storage layout assumptions that do not travel

`/share` is a tmpfs. `/share/Container` and `/share/Public` are symlinks into
`<pool>_DATA/<folder>`, and the pool name differs per machine: `CACHEDEV1_DATA`
on many models, `ZFS<n>_DATA` on QuTS hero. Never hard code either form.
`package_routines` resolves them at install time and writes the result to
`.env`.

Container Station keeps its Docker data root on a fixed-size volume, 99 GB on
the reference machine. The image alone is around 9 GB, so keep model weights on
bind mounts and out of image layers.

## 10. Building from a pasted compose file

Two things block the obvious approaches to a paste-and-run compose file on
QNAP, and both fail in ways that point somewhere else.

A **git URL build context** does not work. BuildKit shells out to the host's
git binary, and QTS does not ship one:

```
failed to init repo: exec: "git": executable file not found in $PATH
```

A **tarball URL build context** does work with `docker build -f`, but Compose
mishandles the `dockerfile` key alongside a URL context. It concatenates the
two into a path and reports:

```
open https:/github.com/.../main.tar.gz/subdir/Dockerfile: no such file
```

That leaves `dockerfile_inline`, which is what the standalone file uses. One
trap comes with it: **Compose performs variable substitution across the whole
compose file, including inside `dockerfile_inline`.** An unescaped `$PATH` or
`${TORCH_INDEX}` in the embedded Dockerfile is replaced with an empty string
before Docker ever sees it. The symptom is remote from the cause:

```
process "/bin/sh -c python -m venv /opt/venv" did not complete successfully: exit code: 127
```

Every dollar sign in the embedded Dockerfile therefore has to be doubled.
`standalone/make-compose.py` regenerates the file and does the escaping, so
edit `standalone/Dockerfile` and run that rather than hand editing the
generated compose.

One more constraint shapes the standalone file: **bind mounting a file that
does not exist on the host makes Docker create a directory in its place**, and
the container then fails to start. Every mount in the standalone compose is
therefore a directory, and `extra_model_paths.yaml` is seeded into a mounted
`/config` directory by the entrypoint on first run instead of being mounted
directly.

## 11. From v0.35 the container memory limit becomes the RAM ComfyUI plans with

Up to v0.34, `mem_limit` in compose was only a guard rail: ComfyUI sized
everything from the host's RAM through `psutil`, and cgroup reclaim kept page
cache in check. ComfyUI v0.35.0 (upstream PR #15927) reads the cgroup limit
instead, for both cgroup v1 (`memory.limit_in_bytes`) and v2 (`memory.max`),
and treats it as total RAM. Available RAM becomes the limit minus the cgroup's
working set, and swap is ignored for the pinned memory pool once a limit exists.

The pinned memory ceiling on Linux is

```
max(0.40 x RAM, min(0.90 x RAM, RAM - 4 GB, RAM + swap - 16 GB))
```

On the reference machine (62.5 GB RAM, 61 GB swap) that works out as follows:

| `mem_limit` | RAM ComfyUI sees | Pinned memory ceiling |
| --- | --- | --- |
| none, or v0.34 | 62.5 GB | about 56 GB |
| `56g` | 56 GB | 40 GB, measured |
| `42g` (what install now writes here) | 42 GB | about 26 GB |
| `40g` (what the reference machine runs) | 40 GB | 24 GB, measured |
| `26g` (the old default) | 26 GB | about 10 GB |

Qwen-Image 2512 fp8 on the 12 GB card dropped host `MemAvailable` from 55 GB to
6.4 GB, so its weights stream from RAM, not VRAM. A 10 GB pool pushes most of
that back to disk. Check what your container ended up with in the startup log.
The reference machine with `mem_limit: 40g` shows:

```
RAM limited by cgroup to 40960 MB (host has 63985 MB)
Enabled pinned memory 24576
```

### Higher is not better on QuTS hero

The obvious fix, a limit close to physical RAM, backfires on QuTS hero. The ZFS
ARC lives outside the page cache, so it appears in neither `Cached` nor
`MemAvailable`. On the reference machine after a day of uptime:

| | Value |
| --- | --- |
| `kstat.zfs.misc.arcstats.size` | 46.7 GB |
| `vfs.zfs.arc_max` | 50.2 GB |
| `vfs.zfs.arc_min` | 12.5 GB |
| `MemAvailable` | 5 to 8 GB |
| Container working set | about 9 GB, far below its 56 GB limit |

The ARC does shrink under pressure, but not fast enough for a model load. The
host swapped heavily, 96% of compaction attempts failed, and physical memory
fragmented to the state described in section 2. In that state a Krea 2 Turbo
job with one LoRA took 357 seconds.

After a reboot, with `mem_limit: 40g`, the same Krea 2 Turbo nvfp4 workflow
(1024x1024, 8 steps, one LoRA) measured:

| Run | Time | Note |
| --- | --- | --- |
| First run after boot | 197 s | ARC empty, weights read from disk. ARC grew from 18 to 34 GB |
| Models unloaded, files still in ARC | 66 s | Close to the 70 s measured on v0.34.3 |
| Models loaded, new seed | 50 s | Peak VRAM 8949 MiB, no swap used |

So on this machine the first job after a reboot is disk bound, and ComfyUI
v0.35.1 itself is not slower than v0.34.3.

The ARC cannot be capped from userland. `vfs.zfs.arc_max` and `arc_min` are
read-only in both `/proc/sys/vfs/zfs` and `/sys/module/zfs/parameters`, even for
root; `zfs.ko` is loaded without parameters by QTS's own init script; and the
root file system is a RAM disk, so boot-time changes do not persist. Note too
that `/sbin/sysctl` is BusyBox, which needs `-w` to write and otherwise reports
`key=value` as an unknown key.

So the ARC floor has to come out of the limit instead. Install now writes
physical RAM minus `vfs.zfs.arc_min` minus 8 GB, which is 42g on the reference
machine (0 for the ARC on QTS). The reference machine runs 40g because it only
serves mid-size models such as Krea 2 and Flux, whose weights fit in the 24 GB
pinned pool. Rebooting before long runs also resets both the ARC and
fragmentation.

Installs made before v0.35.1 keep their `.env`, so set the value by hand before
upgrading.
