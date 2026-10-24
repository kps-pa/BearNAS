# BearNAS

A NAS appliance in a single binary. BearNAS turns a small LXC container into a
home file server: a web dashboard, user management, Samba shares, and optional
plugins for torrents and video downloading — everything is configured from the
browser, in English or Thai.

BearNAS is distributed as a prebuilt Linux binary. This repository holds the
official installer (`setup.sh`) and the latest build (`dist/`); the installer
fetches everything else it needs by itself.

## Requirements

| | |
|---|---|
| Platform | LXC container (Proxmox is the supported setup — the installer checks it is running inside a CT and refuses elsewhere) |
| OS | Debian, 64-bit x86 (amd64) — there is no ARM build |
| Access | root inside the container — from the Proxmox host: `pct enter <CT-ID>` |
| System disk | 100 MB free minimum; 1 GB+ recommended, plugins are installed here (Video Downloader ≈ 200 MB, web-login helper ≈ 500 MB) |
| Data disk | one mounted volume for your files — default `/mnt/disk1` |
| Network | internet access (binary from GitHub, packages via apt) |
| Ports | `8900` web UI (HTTPS) · `8901` plugin gateway |

## Create the container (Proxmox)

BearNAS runs as the only application inside a dedicated LXC container. Create it
once on the Proxmox host; the sizing below is a comfortable start for the plugins.

**From the Proxmox web UI:**

1. Download the Debian 12 template:
   `Datacenter → local → CT Templates → Templates → debian-12-standard → Download`
2. Click **Create CT** (top right) and step through the wizard:
   - **General** — hostname `bearnas`, set the container root password
   - **Template** — Debian 12 standard
   - **Disks** — 8 GB root disk (the binary, settings and plugins all live here)
   - **CPU** — 2 cores
   - **Memory** — 2048 MB (1 GB works, but the video login helper runs a real
     browser, so 2 GB+ is comfortable)
   - **Network** — bridge `vmbr0`, a **static** IPv4 with your gateway
     (DHCP works too, but the IP may change after a reboot — the installer
     warns about it)
   - **DNS** — leave at defaults · **Confirm** — tick *Start after created*
3. Add the data disk: `CT → Resources → Add → Mount point` — pick a storage
   and a size, set the mount point to `/mnt/disk1`.

**Or from the Proxmox shell:**

```sh
pveam update
pveam download local debian-12-standard
pct create 120 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname bearnas --unprivileged 1 \
  --cores 2 --memory 2048 --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.50/24,gw=192.168.1.1 \
  --start 1
pct set 120 --mp0 local-lvm:200,mp=/mnt/disk1
```

The template file name carries the point release — check the exact name with
`pveam list local`. Unprivileged containers are recommended and fully
supported. Bind-mounting a host path (`--mp0 /tank/media,mp=/mnt/disk1`) also
works, but on an unprivileged container files owned on the host show up as
`nobody:nogroup` inside — prefer a storage-backed volume, or look into
`idmap`, when ownership matters.

## GPU passthrough (optional)

If the host has a graphics card (an Intel or AMD iGPU counts), you can pass it
into the container. BearNAS then detects it and shows it on the dashboard
(vendor, render node, VAAPI capability). NVIDIA cards are detected as well, but
making one usable inside a container requires the NVIDIA driver stack and is
out of scope here — Intel/AMD is the straightforward path.

First confirm on the **host** that the render node exists (driver loaded):

```sh
ls -l /dev/dri/
```

Then attach it — Proxmox VE 8.2 or newer:

- **Web UI:** `CT → Resources → Add → Device Passthrough` — path
  `/dev/dri/renderD128`
- **Shell:**

  ```sh
  pct set 120 --dev0 path=/dev/dri/renderD128
  ```

Add `uid=0,gid=0,mode=666` to the `--dev0` line if programs inside an
unprivileged container must open the device itself — BearNAS only reads device
metadata, so the plain form above is enough for the dashboard. The change
applies at the next container start.

On Proxmox VE 8.1 and older there is no Device Passthrough option — add the
device by hand in `/etc/pve/lxc/<CT-ID>.conf` instead:

```
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
```

`226` is the DRI device major and `128` the minor of `renderD128` — a second
card (`renderD129`) would be `c 226:129`.

## Install

Enter the container and run the installer as root:

```sh
pct enter <CT-ID>
curl -fsSL https://raw.githubusercontent.com/kps-pa/BearNAS/main/setup.sh -o setup.sh
bash setup.sh
```

The installer runs six stages — system check, network, base packages, download,
service, health check. Everything is verified first: if any check fails,
nothing on the system is changed. Re-running the installer is always safe and
also serves as an upgrade.

Non-default settings are passed as environment variables:

```sh
BEAR_PORT=9000 BEAR_STORAGE=/mnt/disk2 bash setup.sh --install
```

| Variable | Default | Purpose |
|---|---|---|
| `BEAR_PORT` | `8900` | web UI port (HTTPS) |
| `BEAR_STORAGE` | `/mnt/disk1` | mount point of the data disk |
| `INSTALL_DIR` | `/opt/bearnas` | where the binary and its settings live |
| `DIST_BASE` | `dist/` of this repo on GitHub | download source |

## First run

Open `https://<container-IP>:8900`. The TLS certificate is self-signed — accept
the browser warning on the first visit. A one-time wizard then asks you to
create the first admin account (password of at least 8 characters); the wizard
locks itself permanently once an admin exists. The UI language can be switched
between English and Thai at any time from the top bar.

## Plugins

Installed on demand from the web UI (Plugins page) — only what you need:

- **qBittorrent** — a full torrent client with its own web UI, proxied through
  BearNAS on the gateway port.
- **Video Downloader** — yt-dlp + ffmpeg; downloads from hundreds of sites with
  quality selection and metadata-based file naming. For sites that require a
  login, an optional login helper opens the site inside a browser window in the
  BearNAS UI where you sign in with your own account (OTP and 2FA supported);
  the session is stored encrypted and reused for downloads.

## Update · Repair · Uninstall

```sh
bash setup.sh --update     # download the latest build and restart
bash setup.sh --repair     # check the installation and fix what is broken
bash setup.sh --uninstall  # remove BearNAS — data files are never touched
```

`--update` verifies the download's checksum, restarts the service, and rolls
back to the previous build automatically if the new one fails its health check.
Updates are also available directly from the web UI (Settings page).

Uninstall removes the service, binary, settings database, the Samba accounts
BearNAS created, and its `smb.conf` — files on the data disk are left exactly
as they are.

## Troubleshooting

```sh
systemctl status bearnas        # is the service running?
journalctl -u bearnas -n 50     # recent logs
bash setup.sh --repair          # re-check and fix the installation
```

If the installer reports a checksum error right after a new release, wait a few
minutes and retry — the GitHub CDN can lag behind the repository.
