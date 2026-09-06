# ComfyUI QPKG for QNAP NAS with an NVIDIA GPU

Install [ComfyUI](https://github.com/comfyanonymous/ComfyUI) on a QNAP NAS as an
App Center package, running on Container Station with an NVIDIA RTX GPU passed
through.

The package is a thin wrapper around a Docker Compose stack. The image is built
in place on first start, ComfyUI itself is a bind mount so upgrades do not
require a rebuild, and your models live on a shared folder that other machines
can use over SMB or NFS at the same time.

## Status

Working, but validated on exactly one machine so far. **If you have a QNAP NAS
with an NVIDIA card, hardware reports are the main thing this project needs.**
See [Reporting your hardware](#reporting-your-hardware).

| NAS | CPU | GPU | Driver / CUDA | QTS | Result |
| --- | --- | --- | --- | --- | --- |
| TS-855X | Atom C5125 (no AVX) | RTX A2000 12GB (sm_86) | 575.64.05 / 12.9 | 6.0.2 | Works |

QNAP ships very different CPUs across its range, from Annapurna ARM parts to
Atom, newer Intel Core, and AMD Ryzen. Container Station and the NVIDIA driver
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

## Install

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

## Layout

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
| `COMFY_MEM_LIMIT` | `26g` | A guard rail, not a tuning knob. See notes |
| `COMFY_MODELS_SHARED` | `<Public>/models` | Read-only model root |
| `PUID` / `PGID` | resolved at install | Ownership of generated files |
| `TORCH_*` | cu128 set | Must match your driver |

## Reporting your hardware

Open an issue using the **Hardware report** template. The useful fields are the
NAS model, the CPU (`grep -m1 'model name' /proc/cpuinfo`), whether it has AVX2
(`grep -o avx2 /proc/cpuinfo | head -1`), the GPU and driver version, the QTS
version, and whether it worked. Failures are more useful than successes.

## Known behaviour worth reading before you file a bug

Four things bite people, and all four look like something else. They are
documented with evidence in [docs/HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md):

- CPUs without AVX2 crash on import with `Illegal instruction`, in a file that
  has nothing to do with the real cause.
- After long uptime the NVIDIA driver can fail to initialise CUDA because host
  physical memory is too fragmented, while `nvidia-smi` keeps working.
- The GPU runtime is registered as `nvidia-runtime`, and two environment
  variables are mandatory, not optional.
- A larger model showing *lower* peak VRAM means it is being streamed, not that
  it is more efficient.

## License

Apache-2.0. This repository contains packaging and deployment scripts only.
ComfyUI itself is GPL-3.0 and is downloaded at install time from upstream.
