# ComfyUI QPKG for QNAP NAS with an NVIDIA GPU

Install [ComfyUI](https://github.com/comfyanonymous/ComfyUI) on a QNAP NAS as an
App Center package, running on Container Station with an NVIDIA RTX GPU passed
through.

The package is a thin wrapper around a Docker Compose stack. The image is built
in place on first start, ComfyUI itself is a bind mount that
[one command upgrades](#upgrading-comfyui), and your models live on a shared
folder that other machines can use over SMB or NFS at the same time.

## Status

Working, but validated on exactly one machine so far. **If you have a QNAP NAS
with an NVIDIA card, hardware reports are the main thing this project needs.**
See [Reporting your hardware](#reporting-your-hardware).

| NAS | CPU | GPU | Driver / CUDA | QTS | ComfyUI | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Reference machine | x86, 8 cores, no AVX | 12 GB, sm_86 | 575.64.05 / 12.9 | 6.0.2 | v0.34.3 to v0.37.0 | Works |

QNAP ships very different CPUs across its range, from Annapurna ARM parts to
low-power Intel parts, newer Intel Core, and AMD Ryzen. Container Station and the NVIDIA driver
package behave the same way underneath, so this should port, but the CPU
instruction set and the storage pool naming both differ enough to break naive
assumptions. Both are handled explicitly here. See
[docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md).

## Requirements

- QTS or QuTS hero 5.0 or later
- Container Station 3.0 or later
- The **NVIDIA GPU Driver** QPKG, installed and enabled
- An NVIDIA GPU the driver recognises
- Roughly 15 GB free in the Container Station Docker volume for the image
- Internet access on first start, to download Python packages

Check the GPU is visible before you begin. `nvidia-smi` is not on `PATH` and
needs its own library path:

```sh
DRV=$(getcfg NVIDIA_GPU_DRV Install_Path -f /etc/config/qpkg.conf)
LD_LIBRARY_PATH=$DRV/usr/nvidia $DRV/usr/bin/nvidia-smi
```

Note the reported **CUDA Version**. You need it in the next section.

## Two ways to install

**As an App Center package.** Gives you a start and stop button, a tile that
opens the web UI, and automatic start after a reboot. See below.

**As a Container Station application.** Paste
[standalone/docker-compose.yml](standalone/docker-compose.yml) into Container
Station under Applications, Create. Nothing has to be prepared on the NAS
first: the image builds on first start, and the directories and the default
`extra_model_paths.yaml` are created for you. Edit the storage pool path, the
CUDA wheel index and the GPU runtime name at the top of the file before you
start. This route has no App Center integration, so you start and stop it in
Container Station instead.

## Install as a package

1. Download the `.qpkg` from [Releases](../../releases), or build it yourself
   on the NAS with `sh build.sh` (requires the QDK package).
2. In App Center, choose **Install Manually** and upload the file. Pick a volume
   with room to spare.
3. Wait. The first start builds a roughly 9 GB image and takes 15 to 30 minutes.
   Watch progress in `<Container>/comfyui/logs/qpkg.log`.
4. Open `http://<nas>:8188`.

### Matching the CUDA wheels to your driver

Installation creates `<Container>/comfyui/.env`. The PyTorch wheel index there
must not be newer than the CUDA version your driver reports.

| Driver reports | Use |
| --- | --- |
| CUDA 12.1 to 12.5 | `cu121` |
| CUDA 12.6 to 12.8 | `cu126` |
| CUDA 12.9 or newer | `cu128` (the default) |
| CUDA 13.0 or newer, driver 580+ | `cu130` |

Edit `TORCH_INDEX` and the three version pins together, then restart the
package. Keep `torch`, `torchvision` and `torchaudio` on matching releases; a
mismatch fails at runtime with `undefined symbol: torch_library_impl` and not at
install time.

## Layout (package install)

Everything lives under the **Container** shared folder, resolved at install time
so it does not matter what your storage pool is called.

```
<Container>/comfyui/
├── .env                     all machine-specific settings
├── docker-compose.yml
├── Dockerfile
├── entrypoint.sh
├── extra_model_paths.yaml
├── ComfyUI/                 source checkout, bind mounted
├── custom_nodes/
├── user/                    settings, workflows, comfyui.db
├── pip-extra/               dependencies for custom nodes, on PYTHONPATH
├── models-local/            writable model area
├── input/  output/  temp/
└── logs/
```

Models are read from `<Public>/models` read-only. Point `COMFY_MODELS_SHARED`
in `.env` somewhere else if you keep them elsewhere.

Removing the package deletes neither your models nor `output`, `user`,
`models-local` or `custom_nodes`.

## Configuration

All of `.env` takes effect on package restart.

| Key | Default | Notes |
| --- | --- | --- |
| `COMFY_PORT` | `8188` | Host port |
| `COMFY_GPU_RUNTIME` | `nvidia-runtime` | Verify with `docker info \| grep Runtimes` |
| `COMFY_RESERVE_VRAM` | `0.5` | GB held back from ComfyUI. Raise if you hit OOM |
| `COMFY_MEM_LIMIT` | RAM minus ZFS ARC floor minus 8 GB | From v0.35 ComfyUI treats this as total RAM. Too low makes big models slow, too high makes QuTS hero swap |
| `COMFY_MODELS_SHARED` | `<Public>/models` | Read-only model root |
| `PUID` / `PGID` | resolved at install | Ownership of generated files |
| `TORCH_*` | cu128 set | Must match your driver |

## Upgrading ComfyUI

Reinstalling the package does **not** change the ComfyUI version, because
`.env` is never overwritten. Upgrade from an SSH session instead:

```sh
QPKG=$(getcfg ComfyUI Install_Path -f /etc/config/qpkg.conf)
sh $QPKG/ComfyUI.sh upgrade v0.37.0
```

Pick the tag from the upstream
[releases](https://github.com/Comfy-Org/ComfyUI/releases). The command:

1. Downloads the new source next to the current one.
2. Builds a new image, tagged with the new version, while the running version
   keeps serving. This takes 15 to 30 minutes, because the Python dependencies
   change between releases.
3. Stops the container, swaps the source tree, updates `COMFY_REF` in `.env`
   and starts again, then waits for ComfyUI to answer.
4. If the new version does not come up, it swaps back and starts the old one.

A failed download or build changes nothing. Progress goes to
`<Container>/comfyui/logs/qpkg.log`. The session has to stay open for the whole
build; if yours might drop, run it detached:

```sh
setsid sh $QPKG/ComfyUI.sh upgrade v0.37.0 > /dev/null 2>&1 < /dev/null &
```

The previous version stays on disk as `ComfyUI.prev-<tag>` plus its image, so
going back is quick and needs no rebuild:

```sh
sh $QPKG/ComfyUI.sh rollback
```

Once you are happy with the new version, reclaim the space:

```sh
rm -rf <Container>/comfyui/ComfyUI.prev-v0.34.3
docker rmi comfyui-nas:v0.34.3
```

Check the host before upgrading. Every upgrade and rollback restarts the
container, and after days of uptime the GPU can fail to initialise on restart
for reasons unrelated to the version (see section 2 of
[docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md)). If
`grep Normal /proc/buddyinfo` shows zeros in the last two columns, reboot
first.

**Known issue in v0.37.0:** any node that generates text with a Qwen text
encoder, such as `TextGenerate` for prompt expansion in the Krea 2 workflow,
fails with `CUDA error: CUDA driver version is insufficient for CUDA runtime
version`. Image generation alone is not affected. ComfyUI disables the
comfy-kitchen CUDA backend on PyTorch builds older than cu130, which is what
this package installs, but the new decode path in
`comfy/text_encoders/llama.py` uses the backend anyway. Until upstream fixes
it, change line 882 of `<Container>/comfyui/ComfyUI/comfy/text_encoders/llama.py`
from

```python
        flash_kv = self.fixed_kv and flash is not None and flash(device)
```

to

```python
        flash_kv = self.fixed_kv and flash is not None and flash(device) and torch.version.cuda is not None and int(str(torch.version.cuda).split(".")[0]) >= 13
```

and restart the package. Text generation then takes the same path as in
v0.36.0. The next `upgrade` replaces the file with upstream's version.

**Going from v0.36.0 to v0.37.0:** no database migration, so rolling back is
a plain directory swap. v0.37.0 can turn on fast disk by itself, but not on
ZFS; check for `fast_disk=False` in the log. See section 6 of
[docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md).

**Going from v0.35.x to v0.36.0:** upstream migration
`0007_record_content_split` rebuilds the asset database in `user/comfyui.db`
from scratch. ComfyUI keeps the old file as `user/comfyui.db.bkp`. This package
does not enable `--enable-assets`, so nothing visible is lost, but copy
`comfyui.db` somewhere safe first if you use the assets feature yourself.

Rolling back to v0.35.x afterwards still works. The older release does not know
the new database revision, logs `Error upgrading database ... Can't locate
revision identified by '0007_record_content_split'` and starts anyway, because
the database is optional without `--enable-assets`. Measured on the reference
machine: rollback 92 s, upgrading again 50 s, neither rebuilding anything.

Your `output`, `user`, `models-local` and `custom_nodes` are separate
directories and are never touched. Custom nodes can still break on a new
ComfyUI release, so check theirs before upgrading.

**Coming from v0.34.x:** raise `COMFY_MEM_LIMIT` in `.env` first. Older
installs wrote `26g`, and from v0.35 on ComfyUI reads that back as the total RAM.
On a 64 GB NAS it cuts the pinned memory pool from about 56 GB to about 10 GB.
A sensible value is physical RAM minus 8 GB, and on QuTS hero minus the ZFS ARC
floor as well (`sysctl -n vfs.zfs.arc_min`), with `COMFY_MEMSWAP_LIMIT` 24 GB
above it. Do not simply remove the limit on QuTS hero: the ARC can hold most of
the RAM without showing up in `MemAvailable`, and the host starts swapping.

## Reporting your hardware

Open an issue using the **Hardware report** template. The useful fields are the
NAS model, the CPU (`grep -m1 'model name' /proc/cpuinfo`), whether it has AVX2
(`grep -o avx2 /proc/cpuinfo | head -1`), the GPU and driver version, the QTS
version, and whether it worked. Failures are more useful than successes.

## Known behaviour worth reading before you file a bug

Five things bite people, and all five look like something else. They are
documented with evidence in [docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md):

- CPUs without AVX2 crash on import with `Illegal instruction`, in a file that
  has nothing to do with the real cause.
- After long uptime the NVIDIA driver can fail to initialise CUDA because host
  physical memory is too fragmented, while `nvidia-smi` keeps working.
- The GPU runtime is registered as `nvidia-runtime`, and two environment
  variables are mandatory, not optional.
- A larger model showing *lower* peak VRAM means it is being streamed, not that
  it is more efficient.
- From ComfyUI v0.35 the container memory limit becomes the RAM ComfyUI plans
  with, so an old, low limit quietly makes large models slower.

## License

Apache-2.0. This repository contains packaging and deployment scripts only.
ComfyUI itself is GPL-3.0 and is downloaded at install time from upstream.
