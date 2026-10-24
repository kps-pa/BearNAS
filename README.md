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
| Platform | LXC container — Proxmox VE 9.x is the tested setup (the installer checks it is running inside a CT and refuses elsewhere) |
| OS | Debian 13 (tested) or Debian 12, 64-bit x86 (amd64) — there is no ARM build |
| Access | root inside the container — from the Proxmox host: `pct enter <CT-ID>` |
| System disk | 100 MB free minimum; 1 GB+ recommended, plugins are installed here (Video Downloader ≈ 200 MB, web-login helper ≈ 500 MB) |
| Data disk | one mounted volume for your files — default `/mnt/disk1` |
| Network | internet access (binary from GitHub, packages via apt) |
| Ports | `8900` web UI (HTTPS) · `8901` plugin gateway |

Proxmox VE 8.x should work too but is untested — the parts that touch Proxmox
are standard LXC features that have not changed. If you run it there, you are
the pioneer.

## Create the container (Proxmox)

BearNAS runs as the only application inside a dedicated LXC container. Create it
once on the Proxmox host; the sizing below is a comfortable start for the plugins.

**From the Proxmox web UI:**

1. Download the Debian 13 template:
   `Datacenter → local → CT Templates → Templates → debian-13-standard → Download`
2. Click **Create CT** (top right) and step through the wizard:
   - **General** — hostname `bearnas`, set the container root password
   - **Template** — Debian 13 standard
   - **Disks** — 8 GB root disk (the binary, settings and plugins all live here)
   - **CPU** — 2 cores
   - **Memory** — 2048 MB (1 GB works, but the video login helper runs a real
     browser, so 2 GB+ is comfortable)
   - **Network** — bridge `vmbr0`, a **static** IPv4 with your gateway
     (DHCP works too, but the IP may change after a reboot — the installer
     warns about it)
   - **DNS** — leave at defaults · **Confirm** — tick *Start after created*
3. Add the data disk — see the next section; the quick way is
   `CT → Resources → Add → Mount point` with a volume from any storage, mount
   point `/mnt/disk1`.

**Or from the Proxmox shell:**

```sh
pveam update
pveam download local debian-13-standard
pct create 120 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname bearnas --unprivileged 1 \
  --cores 2 --memory 2048 --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.50/24,gw=192.168.1.1 \
  --start 1
pct set 120 --mp0 local-lvm:200,mp=/mnt/disk1   # or a dedicated disk — next section
```

`pveam download` accepts the short name `debian-13-standard` and fetches the
current file; the template file name in `pct create` carries the point release,
so check the exact name with `pveam list local`. Unprivileged containers are
recommended and fully supported.

## Prepare the data disk

All files live on data disks mounted inside the container — `/mnt/disk1` by
default, and every `/mnt/disk*` mount shows up on the dashboard. Two ways to
get a disk there.

> A mount point added to a **running** container only appears after the next
> container restart — the verification step below includes it.

### A. A dedicated disk (the usual NAS setup)

Run once on the **Proxmox host**. The example uses `/dev/sdb` — replace it with
your disk, and note that steps 2–3 **erase everything on it**.

1. Find the right disk (match it by size and by what is already mounted):

   ```sh
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
   ```

2. Wipe it, partition, and format as ext4:

   ```sh
   wipefs -a /dev/sdb
   parted --script /dev/sdb mklabel gpt mkpart primary ext4 1MiB 100%
   partprobe /dev/sdb
   mkfs.ext4 -L bearnas-data /dev/sdb1
   ```

3. Mount it on the host, permanently, by label:

   ```sh
   mkdir -p /mnt/pve/bearnas-data
   echo 'LABEL=bearnas-data /mnt/pve/bearnas-data ext4 defaults 0 2' >> /etc/fstab
   mount /mnt/pve/bearnas-data
   ```

4. Bind-mount it into the container:

   ```sh
   pct set 120 -mp0 /mnt/pve/bearnas-data,mp=/mnt/disk1,idmap=passthrough
   ```

`idmap=passthrough` keeps ownership on the mount as it is on the disk —
container root owns its own files, which is what a NAS needs. Without it, an
unprivileged container sees the whole mount as `nobody:nogroup` and cannot
write to it. Bind mounts are configured from the shell — the GUI *Mount point*
dialog only offers storage volumes.

Additional disks: repeat with `-mp1 …,mp=/mnt/disk2`, `-mp2 …,mp=/mnt/disk3`,
and so on.

### B. A volume from an existing storage

No spare disk? Give the container a volume from any Proxmox storage instead —
GUI: `CT → Resources → Add → Mount point` (pick a storage and size, mount
point `/mnt/disk1`), or CLI:

```sh
pct set 120 --mp0 local-lvm:200,mp=/mnt/disk1
```

Proxmox formats the volume automatically and ownership works out of the box —
the data just shares the host's storage pool instead of living on its own disk.

### Verify from inside the container

Restart the container so the new mount point appears, then check:

```sh
pct reboot 120
pct enter 120
df -h /mnt/disk1
```

If your mount point is not `/mnt/disk1`, tell the installer where to look:
`BEAR_STORAGE=/mnt/disk2 bash setup.sh --install`.

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

On the Proxmox side:

- The Debian 13 template is missing or flagged unsupported → update the host
  packages first (`apt update && apt full-upgrade` on the host, then
  `pveam update` and re-download). Older `pve-container` builds predate
  Debian 13.
- The data disk is not visible inside the container → check `pct config 120`
  for the `mp0:` line, and that the container was restarted after adding it.
