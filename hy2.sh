#!/bin/bash
#
# Hysteria 2 one-click installer (hardened)

# Bash-specific features such as [[ ]] and ${var,,} cause errors in sh or dash.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Run this script with Bash: bash hy2.sh" >&2
    exit 1
fi

set -uo pipefail

CONFIG_DIR=/etc/hysteria
CONFIG_FILE=$CONFIG_DIR/config.yaml
ACME_DIR=$CONFIG_DIR/acme
MASQ_DIR=$CONFIG_DIR/masq
SERVICE=hysteria-server.service
INSTALLER_URL=https://get.hy2.sh/

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info() { printf '%s[+]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash hy2.sh"
}

need_deps() {
    has_cmd curl || die "curl is required. Install it first: apt -y install curl"
    has_cmd systemctl || die "This script requires systemd. OpenWrt, Alpine, and NixOS are unsupported."
}

# Return 0 if the port is in use, 1 if it is free, or 2 if no check tool is available.
port_in_use() {
    local pat="[:.]$1[[:space:]]"
    if has_cmd ss; then
        ss -H -tuln 2>/dev/null | grep -qE "$pat" && return 0
        return 1
    fi
    if has_cmd netstat; then
        netstat -tuln 2>/dev/null | grep -qE "$pat" && return 0
        return 1
    fi
    return 2
}

gen_password() {
    if has_cmd openssl; then
        openssl rand -base64 32 | tr -d '/+=' | cut -c1-20
    else
        tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20
    fi
}

valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_email()  { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
valid_speed()  { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# Generate the bandwidth section. Server upload is client download, and vice versa.
# Omit the section when both values are 0 to leave bandwidth unlimited.
# Hysteria then uses its own congestion control (congestion.type, defaults to bbr).
# Hysteria implements BBR in userspace over QUIC/UDP, independently of kernel TCP BBR.
bandwidth_block() {
    local up=$1 down=$2
    if [ "$up" = "0" ] && [ "$down" = "0" ]; then
        return 0
    fi
    printf '\nbandwidth:\n'
    [ "$up" != "0" ]   && printf '  up: %s mbps\n' "$up"
    [ "$down" != "0" ] && printf '  down: %s mbps\n' "$down"
    return 0
}

# Escape double quotes and backslashes in passwords for YAML.
yaml_quote() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

confirm() {
    local ans
    read -rp "$1 [y/N]: " ans || return 1
    [[ $ans =~ ^[Yy]$ ]]
}

firewall_hint() {
    local port=$1
    warn "Clients connect over QUIC on ${port}/udp. ACME certificate issuance also requires 80/tcp."
    if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        warn "ufw is active. Allow the required ports: ufw allow 80/tcp && ufw allow ${port}/udp"
    elif has_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
        warn "firewalld is active. Allow the required ports:"
        warn "  firewall-cmd --permanent --add-port=80/tcp --add-port=${port}/udp && firewall-cmd --reload"
    elif has_cmd iptables && iptables -S INPUT 2>/dev/null | grep -qE -- '-j (DROP|REJECT)'; then
        warn "iptables has drop or reject rules. Allow 80/tcp and ${port}/udp."
    fi
}

# Read the service user from the systemd unit. The official installer defaults to hysteria and supports --user.
service_user() {
    local u
    u=$(sed -n 's/^User=//p' "/etc/systemd/system/$SERVICE" 2>/dev/null | tail -n1)
    printf '%s' "${u:-hysteria}"
}

# Download and run the official installer.
# With bash <(curl ...), a failed download can leave Bash with an empty script.
# Bash returns success on empty input, silently hiding the download failure.
run_official_installer() {
    local tmp rc
    tmp=$(mktemp) || { err "Could not create a temporary file"; return 1; }
    if ! curl -fsSL "$INSTALLER_URL" -o "$tmp"; then
        rm -f "$tmp"
        err "Could not download the official installer from $INSTALLER_URL. Check your network or DNS."
        return 1
    fi
    bash "$tmp" "$@"
    rc=$?
    rm -f "$tmp"
    return $rc
}

do_install() {
    local port domain email password bw_up bw_down bak st i ok=0 svcuser

    echo
    info "Installation wizard (press Enter to accept the defaults)"

    read -rp "UDP port (default 8443): " port || return 0
    port=${port:-8443}
    [[ $port =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) \
        || { err "Invalid port: $port"; return 1; }

    read -rp "Domain name (must resolve to this server's IP with the CDN disabled): " domain || return 0
    domain=${domain#http://}; domain=${domain#https://}; domain=${domain%%/*}
    domain=${domain%.}; domain=${domain,,}
    valid_domain "$domain" \
        || { err "Invalid domain: $domain. Enter a hostname such as us.example.com."; return 1; }

    read -rp "ACME email address (default admin@$domain): " email || return 0
    email=${email:-admin@$domain}
    valid_email "$email" || { err "Invalid email address: $email"; return 1; }

    read -rp "Password (leave blank to generate a strong random password): " password || return 0
    if [ -z "$password" ]; then
        password=$(gen_password)
        info "Generated password: $password"
    fi

    read -rp "Server upload / client download (Mbps, default 0 for unlimited): " bw_up || return 0
    bw_up=${bw_up:-0}
    valid_speed "$bw_up" || { err "Invalid bandwidth: $bw_up. Enter a number such as 100 or 50.5."; return 1; }

    read -rp "Server download / client upload (Mbps, default 0 for unlimited): " bw_down || return 0
    bw_down=${bw_down:-0}
    valid_speed "$bw_down" || { err "Invalid bandwidth: $bw_down. Enter a number such as 100 or 50.5."; return 1; }

    port_in_use 80; st=$?
    case $st in
        0) warn "Port 80 is already in use. The ACME HTTP challenge will fail."
           confirm "Continue anyway?" || return 0 ;;
        2) warn "Neither ss nor netstat is available. Skipping the port check." ;;
    esac
    if [ "$port" != 443 ]; then
        port_in_use "$port"; st=$?
        if [ $st -eq 0 ]; then
            warn "Port $port is already in use. This is expected if an existing Hysteria service uses it."
            confirm "Continue anyway?" || return 0
        fi
    fi

    if [ -s "$CONFIG_FILE" ]; then
        bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" && info "Backed up the previous configuration to $bak"
    fi

    info "Running the official Hysteria 2 installer ..."
    run_official_installer || die "The official installer failed. Installation aborted."

    # Store certificates under CONFIG_DIR for easier troubleshooting.
    svcuser=$(service_user)
    mkdir -p "$ACME_DIR"
    chown -R "$svcuser" "$ACME_DIR" 2>/dev/null \
        || warn "Could not set the owner of $ACME_DIR to $svcuser. ACME may fail."
    chmod 700 "$ACME_DIR"
    mkdir -p "$CONFIG_DIR"
    install -m 600 /dev/null "$CONFIG_FILE"

    cat > "$CONFIG_FILE" <<EOF
listen: :$port
$(bandwidth_block "$bw_up" "$bw_down")

acme:
  domains:
    - $domain
  email: $email
  dir: $ACME_DIR

auth:
  type: password
  password: $(yaml_quote "$password")

masquerade:
  type: file
  file:
    dir: $MASQ_DIR
EOF

    # Serve a static masquerade page with no external resources.
    mkdir -p "$MASQ_DIR"
    cat > "$MASQ_DIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$domain</title>
<style>
  html { color-scheme: light dark; }
  body { max-width: 34rem; margin: 12vh auto; padding: 0 1.5rem;
         font: 16px/1.7 system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
  h1 { font-size: 1.15rem; font-weight: 600; margin: 0 0 1.25rem; }
  p { margin: 0 0 .85rem; }
  footer { margin-top: 3.5rem; font-size: .78rem; opacity: .55; }
</style>
</head>
<body>
<h1>$domain</h1>
<p>This domain is reserved for future use.</p>
<p>Nothing is currently hosted here.</p>
<footer>&copy; $(date +%Y) $domain &middot; All rights reserved.</footer>
</body>
</html>
HTML

    # The service user ($svcuser) needs read access to the config and masquerade page.
    chown "$svcuser" "$CONFIG_FILE" 2>/dev/null \
        || { chmod 644 "$CONFIG_FILE"; warn "Could not set the configuration owner to $svcuser. Permissions were set to 644."; }
    chown -R "$svcuser" "$MASQ_DIR" 2>/dev/null || true
    chmod 755 "$CONFIG_DIR" "$MASQ_DIR"
    chmod 644 "$MASQ_DIR/index.html"

    systemctl enable "$SERVICE" >/dev/null 2>&1
    info "Starting the service and waiting up to 60 seconds for certificate issuance ..."
    systemctl restart "$SERVICE"

    for i in $(seq 1 30); do
        if systemctl is-active --quiet "$SERVICE" \
            && [ -n "$(find "$ACME_DIR" -name '*.crt' -size +0c 2>/dev/null | head -n1)" ]; then
            ok=1
            break
        fi
        systemctl is-failed --quiet "$SERVICE" && break
        sleep 2
    done

    echo
    if [ "$ok" = 1 ]; then
        info "Installation complete. The service is running and the certificate has been issued."
        printf '  Domain         : %s\n  Port           : %s/udp\n  Password       : %s\n  Email          : %s\n' \
            "$domain" "$port" "$password" "$email"
        printf '  Config         : %s\n' "$CONFIG_FILE"
        printf '  Masquerade page: %s\n' "$MASQ_DIR/index.html"
        if [ "$bw_up" = "0" ] && [ "$bw_down" = "0" ]; then
            printf '  Bandwidth      : Unlimited (no bandwidth section, Brutal disabled)\n'
        else
            printf '  Bandwidth      : %s Mbps server upload (client download) / %s Mbps server download (client upload)\n' \
                "$bw_up" "$bw_down"
        fi
        if [[ $password =~ ^[A-Za-z0-9._~-]+$ ]]; then
            printf '  Client URL     : hysteria2://%s@%s:%s/?sni=%s#%s\n' \
                "$password" "$domain" "$port" "$domain" "$domain"
        else
            warn "The password contains special characters. Enter the domain, port, and password manually in your client."
        fi
    else
        err "The service failed to start or get a certificate within 60 seconds. Recent logs:"
        journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || true
        echo
        warn "Check DNS, TCP port 80 reachability, Cloudflare CDN settings, and firewall rules."
        warn "Configuration saved to $CONFIG_FILE. After fixing the issue, run: systemctl restart $SERVICE"
    fi
    firewall_hint "$port"
    echo
}

do_uninstall() {
    local svcuser
    svcuser=$(service_user)
    confirm "Uninstall Hysteria 2? This will delete the binary, $CONFIG_DIR, and the $svcuser user and its data." \
        || { warn "Uninstall canceled"; return 0; }

    info "Running the official uninstaller ..."
    run_official_installer --remove || warn "The official uninstaller returned a nonzero exit status. Continuing cleanup."

    rm -rf "$CONFIG_DIR"
    id "$svcuser" >/dev/null 2>&1 && userdel -r "$svcuser" 2>/dev/null
    rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE" \
          /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
    systemctl daemon-reload
    info "Uninstall complete"
}

print_menu() {
    echo "Hysteria 2 one-click installer (hardened)"
    echo "==================================="
    echo "1. Install Hysteria 2"
    echo "2. Uninstall Hysteria 2"
    echo "3. Stop Hysteria 2"
    echo "4. Start Hysteria 2"
    echo "5. Restart Hysteria 2"
    echo "6. Enable startup at boot"
    echo "7. Disable startup at boot"
    echo "8. Upgrade Hysteria 2"
    echo "9. Exit"
}

main() {
    need_root
    need_deps
    [ -t 0 ] || warn "The interactive menu requires terminal input. If using curl | bash, use bash <(curl ...) instead."
    local choice
    while true; do
        print_menu
        read -rp "Select an option [1-9]: " choice || exit 0
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) systemctl stop "$SERVICE" ;;
            4) systemctl start "$SERVICE" ;;
            5) systemctl restart "$SERVICE" ;;
            6) systemctl enable "$SERVICE" ;;
            7) systemctl disable "$SERVICE" ;;
            8) run_official_installer ;;
            9) echo "Exiting"; exit 0 ;;
            *) warn "Invalid option: $choice" ;;
        esac
        echo
    done
}

main
