#!/bin/bash
#
# Hysteria 2 一键安装脚本（加固版）

# bash 特性（[[ ]]、${var,,} 等）本脚本用了不少，被 sh/dash 执行会报难懂的错误
if [ -z "${BASH_VERSION:-}" ]; then
    echo "请用 bash 运行本脚本：bash hy2.sh" >&2
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
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash hy2.sh"
}

need_deps() {
    has_cmd curl || die "缺少 curl，请先安装：apt -y install curl"
    has_cmd systemctl || die "本脚本需要 systemd（不支持 OpenWrt / Alpine / NixOS）"
}

# 端口占用检查。返回 0 = 被占用，1 = 空闲，2 = 系统里没有工具、判断不了
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

# 生成 bandwidth 片段。up = 服务器上行 = 客户端下载，down = 服务器下行 = 客户端上传。
# 两个方向都填 0 时不写这一段，也就是不设限：
# 此时用 Hysteria 自带的拥塞控制（congestion.type，默认 bbr），而不是 Brutal 限速。
# 注意这里的 bbr 是 Hysteria 在 QUIC/UDP 上的用户态实现，跟内核 TCP BBR 无关。
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

# YAML 双引号转义，避免密码里的引号或反斜杠破坏配置文件
yaml_quote() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

confirm() {
    local ans
    read -rp "$1 [y/N]: " ans || return 1
    [[ $ans =~ ^[Yy]$ ]]
}

firewall_hint() {
    local port=$1
    warn "客户端连的是 ${port}/udp（Hysteria 走 QUIC），ACME 签证书还需要 80/tcp"
    if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        warn "检测到 ufw 已启用，请放行：ufw allow 80/tcp && ufw allow ${port}/udp"
    elif has_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
        warn "检测到 firewalld 已启用，请放行："
        warn "  firewall-cmd --permanent --add-port=80/tcp --add-port=${port}/udp && firewall-cmd --reload"
    elif has_cmd iptables && iptables -S INPUT 2>/dev/null | grep -qE -- '-j (DROP|REJECT)'; then
        warn "iptables 存在默认拒绝规则，请自行放行 80/tcp 与 ${port}/udp"
    fi
}

# 从 systemd unit 里读服务运行用户（官方安装器默认是 hysteria，可用 --user 改）
service_user() {
    local u
    u=$(sed -n 's/^User=//p' "/etc/systemd/system/$SERVICE" 2>/dev/null | tail -n1)
    printf '%s' "${u:-hysteria}"
}

# 下载并执行官方安装器。
# 直接写 bash <(curl ...) 有个坑：curl 失败时会得到一个"空脚本"，
# 而 bash 执行空输入返回 0，于是下载失败被静默吞掉，后面一路错下去。
run_official_installer() {
    local tmp rc
    tmp=$(mktemp) || { err "无法创建临时文件"; return 1; }
    if ! curl -fsSL "$INSTALLER_URL" -o "$tmp"; then
        rm -f "$tmp"
        err "下载官方安装器失败：$INSTALLER_URL（检查网络或 DNS）"
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
    info "安装向导（直接回车使用默认值）"

    read -rp "端口 (默认 8443): " port || return 0
    port=${port:-8443}
    [[ $port =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) \
        || { err "端口不合法：$port"; return 1; }

    read -rp "域名 (已解析到本机 IP，且未开启 CDN): " domain || return 0
    domain=${domain#http://}; domain=${domain#https://}; domain=${domain%%/*}
    domain=${domain%.}; domain=${domain,,}
    valid_domain "$domain" \
        || { err "域名不合法：$domain（应为形如 us.example.com 的域名，不能是 IP）"; return 1; }

    read -rp "ACME 邮箱 (留空使用 admin@$domain): " email || return 0
    email=${email:-admin@$domain}
    valid_email "$email" || { err "邮箱不合法：$email"; return 1; }

    read -rp "密码 (留空自动生成随机强密码): " password || return 0
    if [ -z "$password" ]; then
        password=$(gen_password)
        info "已自动生成密码：$password"
    fi

    read -rp "服务器上行 = 客户端下载 (Mbps，默认 0 不限速): " bw_up || return 0
    bw_up=${bw_up:-0}
    valid_speed "$bw_up" || { err "速度值不合法：$bw_up（只能是数字，例如 100 或 50.5）"; return 1; }

    read -rp "服务器下行 = 客户端上传 (Mbps，默认 0 不限速): " bw_down || return 0
    bw_down=${bw_down:-0}
    valid_speed "$bw_down" || { err "速度值不合法：$bw_down（只能是数字，例如 100 或 50.5）"; return 1; }

    port_in_use 80; st=$?
    case $st in
        0) warn "80 端口已被占用，ACME 的 HTTP 校验会失败"
           confirm "仍要继续？" || return 0 ;;
        2) warn "系统里没有 ss/netstat，跳过端口占用检查" ;;
    esac
    if [ "$port" != 443 ]; then
        port_in_use "$port"; st=$?
        if [ $st -eq 0 ]; then
            warn "$port 端口已被占用（如果是本机已装好的 Hysteria 在占用，属正常）"
            confirm "仍要继续？" || return 0
        fi
    fi

    if [ -s "$CONFIG_FILE" ]; then
        bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" && info "原配置已备份至 $bak"
    fi

    info "调用官方安装器安装 Hysteria 2 ..."
    run_official_installer || die "官方安装器执行失败，已中止"

    # 证书固定放在 CONFIG_DIR 下，默认位置在 hysteria 用户家目录里，不好排查
    svcuser=$(service_user)
    mkdir -p "$ACME_DIR"
    chown -R "$svcuser" "$ACME_DIR" 2>/dev/null \
        || warn "无法把 $ACME_DIR 归属给 $svcuser 用户，ACME 可能失败"
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

    # 伪装页：一个纯静态占位页，不引用任何外部资源，别人来探测只会看到这个
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

    # 服务以 $svcuser 运行，配置和伪装页都必须让它能读，否则起不来
    chown "$svcuser" "$CONFIG_FILE" 2>/dev/null \
        || { chmod 644 "$CONFIG_FILE"; warn "无法把配置归属给 $svcuser，已放宽权限为 644"; }
    chown -R "$svcuser" "$MASQ_DIR" 2>/dev/null || true
    chmod 755 "$CONFIG_DIR" "$MASQ_DIR"
    chmod 644 "$MASQ_DIR/index.html"

    systemctl enable "$SERVICE" >/dev/null 2>&1
    info "启动服务并等待证书签发（最多 60 秒）..."
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
        info "安装完成：服务运行中，证书已签发"
        printf '  域名   : %s\n  端口   : %s/udp\n  密码   : %s\n  邮箱   : %s\n' \
            "$domain" "$port" "$password" "$email"
        printf '  配置   : %s\n' "$CONFIG_FILE"
        printf '  伪装页 : %s\n' "$MASQ_DIR/index.html"
        if [ "$bw_up" = "0" ] && [ "$bw_down" = "0" ]; then
            printf '  带宽   : 不限速（未设 bandwidth，不启用 Brutal）\n'
        else
            printf '  带宽   : 上行 %s Mbps（客户端下载）/ 下行 %s Mbps（客户端上传）\n' \
                "$bw_up" "$bw_down"
        fi
        if [[ $password =~ ^[A-Za-z0-9._~-]+$ ]]; then
            printf '  客户端 : hysteria2://%s@%s:%s/?sni=%s#%s\n' \
                "$password" "$domain" "$port" "$domain" "$domain"
        else
            warn "密码含特殊字符，客户端请按上面的域名/端口/密码手动填写"
        fi
    else
        err "60 秒内服务未就绪或证书未签发，最近日志："
        journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || true
        echo
        warn "常见原因：域名没解析到本机 / 80 端口不通 / Cloudflare 开了 CDN / 防火墙没放行"
        warn "配置已写入 $CONFIG_FILE，修好后执行：systemctl restart $SERVICE"
    fi
    firewall_hint "$port"
    echo
}

do_uninstall() {
    local svcuser
    svcuser=$(service_user)
    confirm "确认卸载 Hysteria 2？将删除二进制、$CONFIG_DIR 和 $svcuser 用户及其数据" \
        || { warn "已取消"; return 0; }

    info "调用官方卸载器 ..."
    run_official_installer --remove || warn "官方卸载器返回非零，继续清理残留"

    rm -rf "$CONFIG_DIR"
    id "$svcuser" >/dev/null 2>&1 && userdel -r "$svcuser" 2>/dev/null
    rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE" \
          /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
    systemctl daemon-reload
    info "已卸载"
}

print_menu() {
    echo "Hysteria 2 一键脚本（加固版）"
    echo "==================================="
    echo "1. 安装 Hysteria 2"
    echo "2. 卸载 Hysteria 2"
    echo "3. 停止 Hysteria 2"
    echo "4. 启动 Hysteria 2"
    echo "5. 重启 Hysteria 2"
    echo "6. 设置开机自启"
    echo "7. 关闭开机自启"
    echo "8. 升级 Hysteria 2"
    echo "9. 退出"
}

main() {
    need_root
    need_deps
    [ -t 0 ] || warn "stdin 不是终端（例如 curl | bash），交互菜单会读不了输入，建议改用 bash <(curl ...)"
    local choice
    while true; do
        print_menu
        read -rp "请选择 [1-9]: " choice || exit 0
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) systemctl stop "$SERVICE" ;;
            4) systemctl start "$SERVICE" ;;
            5) systemctl restart "$SERVICE" ;;
            6) systemctl enable "$SERVICE" ;;
            7) systemctl disable "$SERVICE" ;;
            8) run_official_installer ;;
            9) echo "退出"; exit 0 ;;
            *) warn "无效选项：$choice" ;;
        esac
        echo
    done
}

main
