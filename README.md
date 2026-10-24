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

A fixed IP for the container is recommended — the installer warns about DHCP
addresses because they can change after a reboot.

## Install

1. Create a Debian LXC container in Proxmox and mount your data disk into it,
   for example on the host:

   ```sh
   pct set <CT-ID> -mp0 /tank/media,mp=/mnt/disk1
   ```

2. Enter the container and run the installer as root:

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
