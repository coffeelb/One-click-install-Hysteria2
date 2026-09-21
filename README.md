# One-click install Hysteria2

A one-click install script for Hysteria 2. It gives you a 9-item menu: install / uninstall / stop / start / restart / enable autostart / disable autostart / upgrade / exit.

Installing calls the official Hysteria installer (`get.hy2.sh`) to install the binary and the systemd service, then writes a config with ACME certificates, password authentication and a static masquerade page.

## Usage

```bash
bash <(curl -Ls https://raw.githubusercontent.com/coffeelb/One-click-install-Hysteria2/main/hy2.sh)
```

Or download and run it:

```bash
curl -LO https://raw.githubusercontent.com/coffeelb/One-click-install-Hysteria2/main/hy2.sh
sudo bash hy2.sh
```

systemd is required, so OpenWrt / Alpine / NixOS are not supported. Run it with `bash`, not `sh` (on Debian `sh` is dash and will fail).

## Requirements

- root, on a systemd-based distribution (Debian 11+, Ubuntu 22.04 LTS+, Rocky Linux 8+, CentOS Stream 8+, ...)
- a domain that resolves to this server — **do not enable the Cloudflare CDN**
- port 80 free and reachable from the internet (ACME uses it for the HTTP challenge)
- the firewall must allow the **UDP** port you pick, since Hysteria clients speak QUIC over UDP, not TCP

## Notes

`index.html` is a copy of the masquerade page the script generates at install time, kept here for previewing and customizing; a real install regenerates it using the domain you enter.
