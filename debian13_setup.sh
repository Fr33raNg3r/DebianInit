#!/usr/bin/env bash
#
# Debian 13 (Trixie) 系统初始化脚本
# 使用方法：chmod +x debian13_setup.sh && sudo ./debian13_setup.sh
#

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exit 1
fi

SCRIPT_VERSION="1.0.1"

. /etc/os-release
CODENAME="${VERSION_CODENAME:-trixie}"
if [ "$ID" != "debian" ]; then
    echo "警告：当前系统 ID=$ID，非 Debian 系统，脚本可能无法正常工作"
fi

# apt 全程非交互，避免升级时卡在 debconf 对话框
export DEBIAN_FRONTEND=noninteractive
# 配置文件冲突时保留本地修改，同时不再询问
APT_KEEP_CONF=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 本脚本自身的配置目录（防火墙端口等）
SETUP_DIR="/etc/debian13-setup"

# 全部输出同时写入日志，便于事后排查
LOGFILE="/var/log/debian13_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== 脚本启动 $(date '+%F %T')，日志文件: $LOGFILE ==="

# 临时文件统一登记，脚本退出时清理
TMPFILES=()
cleanup() {
    [ "${#TMPFILES[@]}" -gt 0 ] && rm -f "${TMPFILES[@]}"
}
trap cleanup EXIT

pause() {
    read -rp "按回车键继续..." _
}

# 子菜单选择“返回”时置 1，上级菜单据此跳过“按回车键继续”
MENU_BACK=0

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

# 确保指定的软件包已安装，缺失则自动安装
ensure_pkgs() {
    local pkg missing=()
    for pkg in "$@"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "缺少依赖: ${missing[*]}，正在安装..."
        apt update
        if ! apt install -y "${missing[@]}"; then
            echo "依赖安装失败: ${missing[*]}"
            return 1
        fi
    fi
    return 0
}

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    for octet in ${ip//./ }; do
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

valid_cidr() {
    local addr bits
    [[ "$1" == */* ]] || return 1
    addr="${1%%/*}"
    bits="${1##*/}"
    valid_ipv4 "$addr" || return 1
    [[ "$bits" =~ ^[0-9]{1,2}$ ]] && [ "$bits" -ge 1 ] && [ "$bits" -le 32 ]
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 单个端口或端口范围，如 8000-8100
valid_port_or_range() {
    if [[ "$1" == *-* ]]; then
        valid_port "${1%%-*}" && valid_port "${1##*-}" && [ "${1%%-*}" -lt "${1##*-}" ]
    else
        valid_port "$1"
    fi
}

# ---------------------------------------------------------
# 1. 更换软件源
# 最小化安装的 Debian 默认没有 ca-certificates，直接写 https 源会报
# "Certificate verification failed"，而此时又没法通过 https 源安装证书。
# 因此缺证书时先用 http 源装好 ca-certificates，再切换为 https。
# ---------------------------------------------------------

# 检查 APT 走 HTTPS 所需的条件是否满足
https_ready() {
    dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q "ok installed" || return 1
    [ -s /etc/ssl/certs/ca-certificates.crt ] || return 1
    # apt 1.5 起内置 https 传输方法，更老的系统需要 apt-transport-https
    [ -e /usr/lib/apt/methods/https ] || return 1
    return 0
}

DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"

debian_keyring() {
    local f
    for f in /usr/share/keyrings/debian-archive-keyring.pgp /usr/share/keyrings/debian-archive-keyring.gpg; do
        if [ -f "$f" ]; then
            echo "$f"
            return
        fi
    done
}

# 以 Debian 12 起推荐的 deb822 格式写入 debian.sources
write_sources() {
    local base="$1" secbase="$2" comps="$3" keyring signed=""
    keyring=$(debian_keyring)
    [ -n "$keyring" ] && signed="Signed-By: $keyring"
    {
        echo "# 由 debian13_setup.sh 生成"
        echo "Types: deb"
        echo "URIs: $base/debian/"
        echo "Suites: $CODENAME $CODENAME-updates $CODENAME-backports"
        echo "Components: $comps"
        [ -n "$signed" ] && echo "$signed"
        echo ""
        echo "Types: deb"
        echo "URIs: $secbase/debian-security/"
        echo "Suites: $CODENAME-security"
        echo "Components: $comps"
        [ -n "$signed" ] && echo "$signed"
    } > "$DEBIAN_SOURCES"
}

# 询问是否回滚到切换前的软件源配置
rollback_sources() {
    local bkdir="$1" rollback
    read -rp "是否恢复切换前的软件源配置？[Y/n]: " rollback
    if [[ "$rollback" =~ ^[Nn]$ ]]; then
        echo "保留新的软件源配置，原配置备份在: $bkdir"
        return
    fi

    rm -f "$DEBIAN_SOURCES"
    [ -f "$bkdir/sources.list" ] && cp -a "$bkdir/sources.list" /etc/apt/sources.list
    [ -f "$bkdir/debian.sources" ] && cp -a "$bkdir/debian.sources" "$DEBIAN_SOURCES"
    apt update
    echo "已回滚到原软件源"
}

change_source() {
    echo "当前系统代号: $CODENAME"
    echo "1) 清华大学镜像源 (TUNA)"
    echo "2) 华为云镜像源 (HUAWEI Cloud)"
    echo "3) 网易镜像源 (163)"
    echo "4) 教育网联合镜像 (CERNET)"
    echo "0) 返回主菜单"
    read -rp "请选择: " opt

    # 只记录域名，协议在后面单独决定
    local host=""
    case "$opt" in
        1) host="mirrors.tuna.tsinghua.edu.cn" ;;
        2) host="mirrors.huaweicloud.com" ;;
        3) host="mirrors.163.com" ;;
        4) host="mirrors.cernet.edu.cn" ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项"; return ;;
    esac

    local proto="https" use_http
    read -rp "是否改用 HTTP 协议？(默认 HTTPS，证书异常时可选 HTTP) [y/N]: " use_http
    [[ "$use_http" =~ ^[Yy]$ ]] && proto="http"

    read -rp "是否启用 contrib non-free non-free-firmware 组件？[y/N]: " extra
    local comps="main"
    if [[ "$extra" =~ ^[Yy]$ ]]; then
        comps="main contrib non-free non-free-firmware"
    fi

    # 部分镜像的安全更新同步有延迟，可选择 security 仍走官方源
    local sechost="$host" use_official
    read -rp "安全更新 (security) 是否使用官方源 security.debian.org？(更及时，但国内访问可能较慢) [y/N]: " use_official
    [[ "$use_official" =~ ^[Yy]$ ]] && sechost="security.debian.org"

    # 备份放在独立目录，避免 .bak 文件留在 sources.list.d 里引起 apt 警告
    local ts bkdir
    ts=$(date +%Y%m%d%H%M%S)
    bkdir="/etc/apt/sources-backup-$ts"
    mkdir -p "$bkdir"
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$bkdir/"
    [ -f "$DEBIAN_SOURCES" ] && cp -a "$DEBIAN_SOURCES" "$bkdir/"
    # 统一改用 debian.sources，旧的 sources.list 移走以免条目重复
    rm -f /etc/apt/sources.list
    echo "原软件源配置已备份到 $bkdir"

    if [ "$proto" = "https" ]; then
        # 系统时间偏差过大会导致证书被判定为“尚未生效/已过期”
        if [ "$(date +%Y)" -lt 2025 ]; then
            echo "警告：系统时间疑似不正确 ($(date '+%F %T'))，HTTPS 证书校验可能失败"
        fi

        if ! https_ready; then
            echo "系统缺少 HTTPS 所需的 CA 证书，先通过 HTTP 源安装 ca-certificates ..."
            local boot_pkgs=(ca-certificates)
            [ -e /usr/lib/apt/methods/https ] || boot_pkgs+=(apt-transport-https)

            write_sources "http://$host" "http://$sechost" "$comps"
            if ! apt update; then
                echo "apt update 执行失败，该镜像源通过 HTTP 也无法访问"
                rollback_sources "$bkdir"
                return
            fi
            if ! apt install -y "${boot_pkgs[@]}" || ! https_ready; then
                echo "CA 证书安装失败，暂时保留 HTTP 协议的软件源"
                echo "软件源切换完成 (HTTP)，可稍后重新执行本菜单切换为 HTTPS"
                return
            fi
            echo "CA 证书已就绪，切换为 HTTPS 协议"
        fi
    fi

    write_sources "$proto://$host" "$proto://$sechost" "$comps"

    echo "软件源已切换，正在执行 apt update ..."
    if apt update; then
        echo "软件源切换完成 ($proto)，配置文件: $DEBIAN_SOURCES"
        return
    fi

    echo "apt update 执行失败，该镜像源可能不可用"
    if [ "$proto" = "https" ]; then
        echo "若报错为证书校验失败，请检查系统时间，或重新执行本菜单改用 HTTP 协议"
    fi
    rollback_sources "$bkdir"
}

# ---------------------------------------------------------
# 2. 更新系统
# ---------------------------------------------------------
update_system() {
    if apt update && apt "${APT_KEEP_CONF[@]}" full-upgrade -y && apt autoremove -y && apt clean; then
        echo "系统更新完成"
        [ -f /run/reboot-required ] && echo "提示：部分更新需要重启系统才能生效"
    else
        echo "系统更新失败，请查看上方输出或日志 $LOGFILE"
    fi
}

# ---------------------------------------------------------
# 3. 修改时区
# ---------------------------------------------------------
change_timezone() {
    echo "1) 中国上海   (Asia/Shanghai)"
    echo "2) 中国香港   (Asia/Hong_Kong)"
    echo "3) 中国乌鲁木齐 (Asia/Urumqi)"
    echo "4) 日本东京   (Asia/Tokyo)"
    echo "5) 美国加州   (America/Los_Angeles)"
    echo "6) 德国柏林   (Europe/Berlin)"
    echo "7) 英国伦敦   (Europe/London)"
    echo "8) UTC"
    echo "9) 手动输入"
    echo "0) 返回主菜单"
    read -rp "请选择: " opt

    local tz=""
    case "$opt" in
        1) tz="Asia/Shanghai" ;;
        2) tz="Asia/Hong_Kong" ;;
        3) tz="Asia/Urumqi" ;;
        4) tz="Asia/Tokyo" ;;
        5) tz="America/Los_Angeles" ;;
        6) tz="Europe/Berlin" ;;
        7) tz="Europe/London" ;;
        8) tz="UTC" ;;
        9) read -rp "请输入 IANA 时区名称 (如 Asia/Seoul): " tz ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项"; return ;;
    esac

    # 写入前先校验时区是否存在，避免设置成无效值
    if ! timedatectl list-timezones | grep -qx "$tz"; then
        echo "时区名称无效: $tz"
        return
    fi

    if timedatectl set-timezone "$tz"; then
        echo "时区已设置为 $tz"
        timedatectl
    else
        echo "设置失败，请检查系统时间服务是否正常"
    fi
}

# ---------------------------------------------------------
# 4. 更换系统内核
# ---------------------------------------------------------
detect_x86_64_level() {
    if grep -q avx512f /proc/cpuinfo; then
        echo 4
    elif grep -q avx2 /proc/cpuinfo && grep -q bmi2 /proc/cpuinfo && grep -qw fma /proc/cpuinfo; then
        echo 3
    elif grep -q sse4_2 /proc/cpuinfo && grep -q popcnt /proc/cpuinfo; then
        echo 2
    else
        echo 1
    fi
}

install_zabbly_kernel() {
    if [[ "$CODENAME" != "trixie" && "$CODENAME" != "bookworm" ]]; then
        echo "zabbly 官方仅支持 bookworm / trixie，当前系统代号: $CODENAME，可能不兼容"
        read -rp "是否继续？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    ensure_pkgs curl ca-certificates || return

    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL --connect-timeout 15 https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc; then
        echo "zabbly GPG 密钥下载失败，操作取消"
        return
    fi

    local arch
    arch=$(dpkg --print-architecture)
    cat <<EOF > /etc/apt/sources.list.d/zabbly-kernel-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/kernel/stable
Suites: $CODENAME
Components: main
Architectures: $arch
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

    apt update
    if apt install -y linux-zabbly; then
        echo "zabbly 内核安装完成，需要重启系统才能生效"
    else
        echo "zabbly 内核安装失败，请查看上方输出"
    fi
}

xanmod_menu() {
    if [ "$(dpkg --print-architecture)" != "amd64" ]; then
        echo "xanmod 仅提供 amd64 架构的内核，当前架构不支持"
        return
    fi

    local lvl c
    lvl=$(detect_x86_64_level)
    echo "检测到 CPU 支持的微架构等级: x86-64-v$lvl"
    read -rp "使用检测到的 v$lvl 等级吗？[Y/n，输入 n 可手动指定 1-4]: " c
    if [[ "$c" =~ ^[Nn]$ ]]; then
        read -rp "请输入微架构等级(1-4): " lvl
        if [[ ! "$lvl" =~ ^[1-4]$ ]]; then
            echo "等级无效，只能是 1-4"
            return
        fi
    fi

    echo "1) Stable"
    echo "2) LTS"
    echo "3) Edge"
    echo "0) 返回"
    read -rp "请选择分支: " opt

    local prefix=""
    case "$opt" in
        1) prefix="linux-xanmod-x64v" ;;
        2) prefix="linux-xanmod-lts-x64v" ;;
        3) prefix="linux-xanmod-edge-x64v" ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项"; return ;;
    esac

    ensure_pkgs wget gnupg ca-certificates || return

    mkdir -p /etc/apt/keyrings
    local keytmp="/tmp/xanmod-key.$$"
    TMPFILES+=("$keytmp")
    if ! wget -qO "$keytmp" https://dl.xanmod.org/archive.key; then
        echo "xanmod GPG 密钥下载失败，操作取消"
        return
    fi
    # --yes：重复执行时直接覆盖旧密钥，否则 gpg 会停下来询问
    if ! gpg --batch --yes --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg "$keytmp"; then
        echo "xanmod GPG 密钥导入失败，操作取消"
        return
    fi

    cat <<EOF > /etc/apt/sources.list.d/xanmod-release.list
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $CODENAME main
EOF

    apt update

    # xanmod 目前不提供 v4，v1 也仅 LTS 分支有；从检测等级往下找第一个存在的包
    local l pkg=""
    for ((l = lvl; l >= 1; l--)); do
        if apt-cache show "$prefix$l" >/dev/null 2>&1; then
            pkg="$prefix$l"
            break
        fi
    done
    if [ -z "$pkg" ]; then
        echo "软件源中找不到适用于 v$lvl 及以下等级的 ${prefix%x64v} 内核包"
        echo "可执行 apt search linux-xanmod 查看当前提供的包"
        return
    fi
    [ "$pkg" != "$prefix$lvl" ] && echo "xanmod 未提供 ${prefix}$lvl，改用兼容的 $pkg"

    if apt install -y "$pkg"; then
        echo "xanmod 内核 ($pkg) 安装完成，需要重启系统才能生效"
    else
        echo "xanmod 内核安装失败，请查看上方输出"
    fi
}

change_kernel() {
    echo "1) 安装 zabbly 内核 (stable)"
    echo "2) 安装 xanmod 内核"
    echo "0) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
        1) install_zabbly_kernel ;;
        2) xanmod_menu ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

# ---------------------------------------------------------
# 5. 清理未使用的旧内核 (ii 已安装 / rc 残留配置，均清理)
# ---------------------------------------------------------
# 取内核版本的基础部分，用于把 image / headers / headers-common 等包归为同一版本：
#   6.12.38+deb13-amd64 -> 6.12.38+deb13    6.1.0-18-cloud-amd64 -> 6.1.0-18
#   6.15.7-x64v3-xanmod1 -> 6.15.7          6.16.0-zabbly+       -> 6.16.0
kernel_base() {
    sed -E 's/-[A-Za-z].*$//' <<<"$1"
}

clean_old_kernels() {
    local current cur_base
    current=$(uname -r)
    cur_base=$(kernel_base "$current")
    echo "当前运行内核: $current"

    # 按版本分组；只统计 ii(已安装) 和 rc(残留配置) 状态的包
    local name status rest b
    declare -A groups=() has_image=()
    while read -r name status; do
        [[ "$status" == "ii" || "$status" == "rc" ]] || continue
        rest=$(sed -E 's/^linux-(image|headers|modules)-//' <<<"$name")
        b=$(kernel_base "$rest")
        [ "$b" = "$cur_base" ] && continue
        groups[$b]+="$name "
        [[ "$name" == linux-image-* && "$status" == "ii" ]] && has_image[$b]=1
    done < <(
        dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 2>/dev/null \
            | grep -E '^linux-(image|headers|modules)-[0-9]'
    )

    if [ "${#groups[@]}" -eq 0 ]; then
        echo "没有找到可清理的旧内核"
        return
    fi

    # 比当前运行内核更新的版本一律保留（可能是刚安装、尚未重启生效的新内核）
    local newest
    for b in "${!groups[@]}"; do
        newest=$(printf '%s\n%s\n' "$b" "$cur_base" | sort -V | tail -1)
        if [ "$newest" = "$b" ]; then
            echo "保留比当前内核更新的版本: $b (可能尚未重启生效)"
            unset "groups[$b]"
        fi
    done

    # 保留一个最新的旧内核，新内核有问题时还能从 GRUB 回退
    local keep keep_ver
    read -rp "是否保留一个最新的旧内核作为回退备用？[Y/n]: " keep
    if [[ ! "$keep" =~ ^[Nn]$ ]]; then
        # 只考虑内核镜像仍处于已安装状态的版本，仅剩残留配置的保留也没意义
        keep_ver=$(for b in "${!groups[@]}"; do [ -n "${has_image[$b]:-}" ] && echo "$b"; done | sort -V | tail -1)
        if [ -n "$keep_ver" ]; then
            echo "保留备用内核版本: $keep_ver"
            unset "groups[$keep_ver]"
        fi
    fi

    local pkgs=() part
    for b in "${!groups[@]}"; do
        read -ra part <<<"${groups[$b]}"
        pkgs+=("${part[@]}")
    done

    if [ "${#pkgs[@]}" -eq 0 ]; then
        echo "除保留的内核外，没有需要清理的内核"
        return
    fi

    echo "以下内核包将被清理 (含 ii 已安装 / rc 残留配置 状态):"
    printf '  %s\n' "${pkgs[@]}"
    read -rp "确认清理以上内核？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apt purge -y "${pkgs[@]}"
        apt autoremove -y
        update-grub
        echo "旧内核清理完成"
    else
        echo "已取消"
    fi
}

# ---------------------------------------------------------
# 6. 系统优化
# ---------------------------------------------------------
install_common_packages() {
    declare -A pkg_map=(
        [1]="curl"
        [2]="wget"
        [3]="sudo"
        [4]="git"
        [5]="unzip"
        [6]="htop"
        [7]="rsync"
        [8]="net-tools"
        [9]="dnsutils"
        [10]="iproute2"
        [11]="mtr"
        [12]="traceroute"
        [13]="nodejs npm"
    )
    local all_pkgs="curl wget sudo git unzip htop rsync net-tools dnsutils iproute2 mtr traceroute nodejs npm"

    echo "请选择要安装的软件包 (可多选，用空格分隔编号，输入 a 全选):"
    echo "   1) curl            2) wget            3) sudo"
    echo "   4) git             5) unzip           6) htop"
    echo "   7) rsync           8) net-tools       9) dnsutils"
    echo "  10) iproute2       11) mtr            12) traceroute"
    echo "  13) nodejs (含 npm)"
    read -rp "请输入选项: " choices

    local selected=""
    if [[ "$choices" =~ ^[Aa]$ ]]; then
        selected="$all_pkgs"
    else
        for c in $choices; do
            [ -n "${pkg_map[$c]:-}" ] && selected="$selected ${pkg_map[$c]}"
        done
    fi

    if [ -z "$selected" ]; then
        echo "未选择任何软件包"
        return
    fi

    echo "即将安装:$selected"
    apt update
    apt install -y $selected
}

detect_netmgr() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "networkmanager"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "networkd"
    else
        echo "ifupdown"
    fi
}

cidr_to_netmask() {
    local cidr=$1 mask="" full_octets partial i
    full_octets=$((cidr / 8))
    partial=$((cidr % 8))
    for ((i = 0; i < 4; i++)); do
        if [ "$i" -lt "$full_octets" ]; then
            mask+="255"
        elif [ "$i" -eq "$full_octets" ]; then
            mask+=$((256 - 2 ** (8 - partial)))
        else
            mask+="0"
        fi
        [ "$i" -lt 3 ] && mask+="."
    done
    echo "$mask"
}

# 询问网卡名，留空则取默认路由网卡；提示信息走 stderr 以免混入返回值
ask_iface() {
    local iface
    read -rp "网卡名称 (留空自动检测默认路由网卡): " iface
    [ -z "$iface" ] && iface=$(ip route show default | awk '{print $5; exit}')
    if [ -z "$iface" ]; then
        echo "未能检测到网卡，操作取消" >&2
        return 1
    fi
    echo "使用网卡: $iface" >&2
    echo "$iface"
}

get_nm_conn() {
    local iface="$1" conn
    conn=$(nmcli -t -f NAME,DEVICE con show --active | grep ":$iface$" | cut -d: -f1)
    [ -z "$conn" ] && conn="$iface"
    echo "$conn"
}

# 删除 /etc/network/interfaces 中该网卡原有的配置段，避免重复叠加
strip_iface_stanza() {
    local ifn="$1" newconf="/tmp/interfaces.$$"
    if awk -v ifn="$ifn" '
        $1 == "auto" && $2 == ifn { next }
        $1 == "iface" && $2 == ifn { skip = 1; next }
        skip && /^[^[:space:]]/ { skip = 0 }
        !skip { print }
    ' /etc/network/interfaces > "$newconf"; then
        mv "$newconf" /etc/network/interfaces
        return 0
    fi
    rm -f "$newconf"
    echo "处理 /etc/network/interfaces 失败"
    return 1
}

NET_CONFIRM_FLAG="/run/net-setup-confirmed"
RESOLVED_DNS_DROPIN="/etc/systemd/resolved.conf.d/10-debian13-setup.conf"

# ifupdown 的 dns-nameservers 只有装了 resolvconf/openresolv 才会生效，
# 否则需要根据实际的 DNS 管理方式另行写入
apply_ifupdown_dns() {
    local dns="$1" d
    [ -z "$dns" ] && return
    if pkg_installed resolvconf || pkg_installed openresolv; then
        return
    fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNS=%s\n' "$dns" > "$RESOLVED_DNS_DROPIN"
        systemctl restart systemd-resolved
        echo "DNS 已写入 systemd-resolved: $RESOLVED_DNS_DROPIN"
    elif [ ! -L /etc/resolv.conf ]; then
        {
            echo "# 由 debian13_setup.sh 写入"
            for d in $dns; do
                echo "nameserver $d"
            done
        } > /etc/resolv.conf
        echo "DNS 已写入 /etc/resolv.conf"
    else
        echo "警告：/etc/resolv.conf 是符号链接且无法识别其管理方式，DNS 需要手动配置"
    fi
}

# 备份当前网络配置并生成回滚脚本，成功时把脚本路径输出到 stdout
prepare_net_rollback() {
    local method="$1" conn="$2" ts bkdir rb
    ts=$(date +%Y%m%d%H%M%S)
    bkdir="/root/net-backup-$ts"
    rb="/run/net-rollback-$ts.sh"
    mkdir -p "$bkdir"

    case "$method" in
        networkmanager)
            cp -a /etc/NetworkManager/system-connections "$bkdir/" 2>/dev/null
            [ -d "$bkdir/system-connections" ] || return 1
            cat <<EOF > "$rb"
rm -f /etc/NetworkManager/system-connections/*
cp -a "$bkdir/system-connections/." /etc/NetworkManager/system-connections/
nmcli connection reload
nmcli connection up "$conn" || systemctl restart NetworkManager
EOF
            ;;
        networkd)
            cp -a /etc/systemd/network "$bkdir/" 2>/dev/null
            [ -d "$bkdir/network" ] || return 1
            cat <<EOF > "$rb"
rm -f /etc/systemd/network/*
cp -a "$bkdir/network/." /etc/systemd/network/
systemctl restart systemd-networkd
EOF
            ;;
        ifupdown)
            cp -a /etc/network/interfaces "$bkdir/" 2>/dev/null
            [ -f "$bkdir/interfaces" ] || return 1
            # DNS 可能写在 resolv.conf 或 resolved drop-in 中，一并备份
            [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && cp -a /etc/resolv.conf "$bkdir/"
            [ -f "$RESOLVED_DNS_DROPIN" ] && cp -a "$RESOLVED_DNS_DROPIN" "$bkdir/"
            cat <<EOF > "$rb"
cp -a "$bkdir/interfaces" /etc/network/interfaces
[ -f "$bkdir/resolv.conf" ] && cp -a "$bkdir/resolv.conf" /etc/resolv.conf
if [ -f "$bkdir/${RESOLVED_DNS_DROPIN##*/}" ]; then
    cp -a "$bkdir/${RESOLVED_DNS_DROPIN##*/}" "$RESOLVED_DNS_DROPIN"
else
    rm -f "$RESOLVED_DNS_DROPIN"
fi
systemctl is-active --quiet systemd-resolved && systemctl restart systemd-resolved
systemctl restart networking
EOF
            ;;
        *)
            return 1
            ;;
    esac

    echo "原网络配置已备份到 $bkdir" >&2
    echo "$rb"
}

# 应用网络改动后限时确认：超时或 SSH 断开都会自动回滚
apply_with_rollback() {
    local rb="$1" timeout=60 ok

    rm -f "$NET_CONFIRM_FLAG"
    # 后台任务独立于本脚本存活，SSH 断开导致脚本被杀时仍能回滚
    nohup bash -c "sleep $timeout; [ -f '$NET_CONFIRM_FLAG' ] || bash '$rb'" >/dev/null 2>&1 &
    disown 2>/dev/null

    echo "--------------------------------------------------"
    echo "配置已应用，请【立即在新终端】验证连通性。"
    echo "$timeout 秒内未确认将自动回滚到修改前的配置。"
    echo "--------------------------------------------------"
    if read -t "$timeout" -rp "确认网络正常，保留新配置？[y/N]: " ok && [[ "$ok" =~ ^[Yy]$ ]]; then
        touch "$NET_CONFIRM_FLAG"
        echo "已保留新配置"
    else
        echo ""
        echo "未确认，正在回滚..."
        touch "$NET_CONFIRM_FLAG"
        bash "$rb"
        echo "已回滚到修改前的配置"
    fi
    rm -f "$rb"
}

configure_network() {
    local method iface ipaddr gateway dns conn="" rb d
    method=$(detect_netmgr)
    echo "检测到网络管理方式: $method"

    iface=$(ask_iface) || return

    read -rp "IP 地址(含掩码位数，如 192.168.1.100/24): " ipaddr
    if ! valid_cidr "$ipaddr"; then
        echo "IP 地址格式不正确: $ipaddr"
        return
    fi
    read -rp "网关地址: " gateway
    if ! valid_ipv4 "$gateway"; then
        echo "网关地址格式不正确: $gateway"
        return
    fi
    read -rp "DNS 地址(可多个，空格分隔): " dns
    for d in $dns; do
        if ! valid_ipv4 "$d"; then
            echo "DNS 地址格式不正确: $d"
            return
        fi
    done

    [ "$method" = "networkmanager" ] && conn=$(get_nm_conn "$iface")

    rb=$(prepare_net_rollback "$method" "$conn")
    if [ -z "$rb" ]; then
        echo "警告：未能备份原网络配置，将没有自动回滚保护"
        read -rp "仍要继续吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    case "$method" in
        networkmanager)
            # nmcli 的 ipv4.dns 需要逗号分隔
            nmcli con mod "$conn" ipv4.addresses "$ipaddr" ipv4.gateway "$gateway" ipv4.dns "${dns// /,}" ipv4.method manual
            nmcli con up "$conn"
            ;;
        networkd)
            cat <<EOF > "/etc/systemd/network/10-$iface.network"
[Match]
Name=$iface

[Network]
Address=$ipaddr
Gateway=$gateway
DNS=$dns
EOF
            systemctl restart systemd-networkd
            ;;
        ifupdown)
            local ip_only netmask
            ip_only="${ipaddr%%/*}"
            netmask=$(cidr_to_netmask "${ipaddr##*/}")
            strip_iface_stanza "$iface" || return
            cat <<EOF >> /etc/network/interfaces

auto $iface
iface $iface inet static
    address $ip_only
    netmask $netmask
    gateway $gateway
    dns-nameservers $dns
EOF
            systemctl restart networking
            apply_ifupdown_dns "$dns"
            ;;
    esac

    if [ -n "$rb" ]; then
        apply_with_rollback "$rb"
    else
        echo "网络配置已写入，请自行确认连通性"
    fi
}

restore_dhcp() {
    local method iface conn=""
    method=$(detect_netmgr)
    echo "检测到网络管理方式: $method"

    iface=$(ask_iface) || return

    read -rp "确认将 $iface 恢复为 DHCP 自动获取？(远程操作可能导致断连) [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        return
    fi

    [ "$method" = "networkmanager" ] && conn=$(get_nm_conn "$iface")

    # DHCP 分到的 IP 若与当前不同，SSH 会立即断开并在超时后回滚；
    # 通过 VNC/控制台操作时可以关闭保护
    local protect rb=""
    echo "提示：如果 DHCP 分配的 IP 与当前不同，SSH 会断开，开启保护时会在 60 秒后自动回滚"
    read -rp "是否启用 60 秒自动回滚保护？(通过控制台操作可选 n) [Y/n]: " protect
    if [[ ! "$protect" =~ ^[Nn]$ ]]; then
        rb=$(prepare_net_rollback "$method" "$conn")
        if [ -z "$rb" ]; then
            echo "警告：未能备份原网络配置，将没有自动回滚保护"
            read -rp "仍要继续吗？[y/N]: " c
            [[ "$c" =~ ^[Yy]$ ]] || return
        fi
    fi

    case "$method" in
        networkmanager)
            nmcli con mod "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
            nmcli con up "$conn"
            ;;
        networkd)
            cat <<EOF > "/etc/systemd/network/10-$iface.network"
[Match]
Name=$iface

[Network]
DHCP=ipv4
EOF
            systemctl restart systemd-networkd
            ;;
        ifupdown)
            local ts
            ts=$(date +%Y%m%d%H%M%S)
            cp /etc/network/interfaces "/etc/network/interfaces.bak.$ts"
            strip_iface_stanza "$iface" || return
            cat <<EOF >> /etc/network/interfaces

auto $iface
iface $iface inet dhcp
EOF
            # 去掉静态配置时写入的 DNS，交还给 DHCP
            if [ -f "$RESOLVED_DNS_DROPIN" ]; then
                rm -f "$RESOLVED_DNS_DROPIN"
                systemctl is-active --quiet systemd-resolved && systemctl restart systemd-resolved
            fi
            systemctl restart networking
            ;;
    esac
    echo "已恢复为 DHCP 自动获取，当前地址:"
    ip -4 addr show "$iface"

    if [ -n "$rb" ]; then
        apply_with_rollback "$rb"
    fi
}

# 主机名规则 (RFC 1123)：每段 1-63 位字母、数字、连字符，不能以连字符开头或结尾，总长不超过 253
valid_hostname() {
    local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    [ "${#1}" -le 253 ] && [[ "$1" =~ ^$label(\.$label)*$ ]]
}

set_hostname() {
    local newhost short entry
    read -rp "请输入新的主机名 (可为 FQDN，如 web1.example.com): " newhost
    if [ -z "$newhost" ]; then
        echo "主机名不能为空，操作取消"
        return
    fi
    if ! valid_hostname "$newhost"; then
        echo "主机名不合法: $newhost"
        echo "只能包含字母、数字、连字符和点，每段不能以连字符开头或结尾（下划线、空格均不允许）"
        return
    fi
    if ! hostnamectl set-hostname "$newhost"; then
        echo "主机名设置失败"
        return
    fi

    # FQDN 时 hosts 中同时写全名和短名
    short="${newhost%%.*}"
    entry="$newhost"
    [ "$short" != "$newhost" ] && entry="$newhost $short"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$entry/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$entry" >> /etc/hosts
    fi
    echo "主机名已修改为: $newhost"
}

disable_ipv6() {
    cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system
    echo "IPv6 已关闭"
}

restore_ipv6() {
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null
    sysctl --system >/dev/null

    # 其它位置可能也写了禁用配置，提示用户自行处理
    local leftover
    leftover=$(grep -rl 'disable_ipv6' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null)
    if [ -n "$leftover" ]; then
        echo "注意：以下文件仍包含 disable_ipv6 配置，如仍未生效请手动检查:"
        echo "$leftover"
    fi

    echo "IPv6 已恢复，当前 IPv6 地址:"
    ip -6 addr show scope global
}

# ---------------------------------------------------------
# SSH 相关：统一写 drop-in 配置文件
# sshd 采用“先出现的值生效”，drop-in 目录按文件名排序读取，
# 因此编号要小于 cloud-init 等已有配置(如 50-cloud-init.conf)才能覆盖它们
# ---------------------------------------------------------
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-debian13-setup.conf"

ensure_sshd_include() {
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        echo "已在 sshd_config 顶部补充 Include 指令"
    fi
}

write_dropin() {
    local key="$1" value="$2"
    touch "$SSHD_DROPIN"
    if grep -qE "^[[:space:]]*$key[[:space:]]" "$SSHD_DROPIN"; then
        sed -i "s|^[[:space:]]*$key[[:space:]].*|$key $value|" "$SSHD_DROPIN"
    else
        echo "$key $value" >> "$SSHD_DROPIN"
    fi
}

remove_dropin_key() {
    [ -f "$SSHD_DROPIN" ] && sed -i "/^[[:space:]]*$1[[:space:]]/d" "$SSHD_DROPIN"
}

restore_dropin() {
    local backup="$1"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp -a "$backup" "$SSHD_DROPIN"
    else
        rm -f "$SSHD_DROPIN"
    fi
}

# 当前 sshd 实际生效的监听端口（每行一个）
sshd_ports() {
    # sshd -t / -T 需要特权分离目录，ssh 走 socket 激活时它可能不存在
    mkdir -p /run/sshd
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un
}

SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/00-debian13-setup.conf"

restart_sshd() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        # socket 激活模式下监听端口由 ssh.socket 决定，sshd_config 中的 Port 不起作用，需要同步过去
        local p
        mkdir -p "${SSH_SOCKET_DROPIN%/*}"
        {
            echo "[Socket]"
            echo "ListenStream="
            for p in $(sshd_ports); do
                echo "ListenStream=$p"
            done
        } > "$SSH_SOCKET_DROPIN"
        systemctl daemon-reload
        # 已建立的 SSH 会话由独立进程服务，重启 socket 不会断开
        systemctl restart ssh.socket
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
    fi
}

# 校验并重启 sshd；校验不通过就还原改动，避免重启后远程失联
sshd_apply() {
    local backup="$1" testlog="/tmp/sshd-test.$$"
    TMPFILES+=("$testlog")
    mkdir -p /run/sshd
    if sshd -t 2>"$testlog"; then
        restart_sshd
        return 0
    fi

    echo "sshd 配置校验失败，未重启服务:"
    cat "$testlog"
    restore_dropin "$backup"
    echo "已还原本次改动"
    return 1
}

backup_dropin() {
    local bk=""
    if [ -f "$SSHD_DROPIN" ]; then
        bk="/root/sshd-dropin.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SSHD_DROPIN" "$bk"
    fi
    echo "$bk"
}

enable_root_ssh() {
    ensure_sshd_include
    local bk
    bk=$(backup_dropin)
    write_dropin PermitRootLogin yes
    if sshd_apply "$bk"; then
        echo "已开启 root 用户 SSH 登录 (配置位于 $SSHD_DROPIN)"
        # 云镜像常锁定 root 密码，这种情况下开了也登不进去
        if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|NP)$'; then
            echo "注意: root 当前没有可用密码，请执行 passwd root 设置密码后再用密码登录"
        fi
    fi
}

ssh_key_only() {
    local sshuser homedir
    read -rp "为哪个用户配置密钥登录 [默认 root]: " sshuser
    sshuser=${sshuser:-root}

    if [ "$sshuser" = "root" ]; then
        homedir="/root"
    else
        homedir=$(getent passwd "$sshuser" | cut -d: -f6)
    fi
    if [ -z "$homedir" ] || [ ! -d "$homedir" ]; then
        echo "用户不存在，操作取消"
        return
    fi

    mkdir -p "$homedir/.ssh"
    chmod 700 "$homedir/.ssh"
    touch "$homedir/.ssh/authorized_keys"

    echo "请粘贴公钥内容 (可粘贴多行/多个公钥，每行一个；粘贴完成后单独一行输入 END 结束):"
    local keys=() line added=0
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        [ -z "$line" ] && continue
        # 逐行校验格式，避免把无效内容写进 authorized_keys
        if ! printf '%s\n' "$line" | ssh-keygen -l -f - >/dev/null 2>&1; then
            echo "已忽略无效公钥: ${line:0:40}..."
            continue
        fi
        keys+=("$line")
    done

    if [ "${#keys[@]}" -eq 0 ]; then
        echo "未输入任何有效公钥，操作取消"
        return
    fi

    for line in "${keys[@]}"; do
        if grep -qxF "$line" "$homedir/.ssh/authorized_keys"; then
            echo "已存在，跳过: ${line:0:40}..."
            continue
        fi
        printf '%s\n' "$line" >> "$homedir/.ssh/authorized_keys"
        added=$((added + 1))
    done
    chmod 600 "$homedir/.ssh/authorized_keys"
    chown -R "$sshuser:" "$homedir/.ssh"
    echo "新增 $added 个公钥到 $homedir/.ssh/authorized_keys"

    read -rp "请【新开一个终端窗口】确认密钥登录正常后再继续。确认要禁用密码登录了吗？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已跳过禁用密码登录，可稍后再手动执行本菜单项"
        return
    fi

    ensure_sshd_include
    local bk
    bk=$(backup_dropin)
    write_dropin PubkeyAuthentication yes
    write_dropin PasswordAuthentication no
    if sshd_apply "$bk"; then
        echo "已切换为仅密钥登录 (配置位于 $SSHD_DROPIN)"
    fi
}

restore_ssh_password() {
    local confirm
    read -rp "确认恢复 SSH 密码登录？(将同时保留密钥登录) [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        return
    fi

    ensure_sshd_include
    local bk
    bk=$(backup_dropin)
    write_dropin PasswordAuthentication yes
    if sshd_apply "$bk"; then
        echo "已恢复 SSH 密码登录 (配置位于 $SSHD_DROPIN)，密钥登录仍然可用"
        # PermitRootLogin 默认是 prohibit-password，只开密码认证不代表 root 能用密码登录
        local permitrootlogin
        permitrootlogin=$(mkdir -p /run/sshd; sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')
        if [ "$permitrootlogin" != "yes" ]; then
            echo "注意: PermitRootLogin 当前为 $permitrootlogin，root 仍无法使用密码登录；如需允许，请执行菜单 7「开启 root 用户 SSH 登录」"
        fi
        echo "提示: 如目标用户密码已被锁定或未设置，请先执行 passwd <用户名> 设置密码"
    fi
}

# ---------------------------------------------------------
# NTP 时间同步 (chrony)：进入系统优化菜单时自动执行，已配置则跳过
# ---------------------------------------------------------
CHRONY_CONF="/etc/chrony/conf.d/10-debian13-setup.conf"
NTP_SERVERS=(ntp.aliyun.com ntp.tencent.com ntp.ntsc.ac.cn cn.pool.ntp.org)

auto_sync_time() {
    # 已由本脚本配置、服务在运行且开机自启、默认池已去掉，无需重复处理
    if [ -f "$CHRONY_CONF" ] \
        && systemctl is-active --quiet chrony 2>/dev/null \
        && systemctl is-enabled --quiet chrony 2>/dev/null \
        && ! grep -qE '^[[:space:]]*pool[[:space:]]' /etc/chrony/chrony.conf 2>/dev/null; then
        return
    fi

    echo "--------------------------------------------------"
    echo "正在自动配置 NTP 时间同步 (chrony)..."

    if ! ensure_pkgs chrony; then
        echo "警告：chrony 安装失败，已跳过时间同步"
        return
    fi

    # timesyncd 与 chrony 都会调整系统时间，同时运行会冲突
    if systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null \
        || systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        systemctl disable --now systemd-timesyncd >/dev/null 2>&1
        echo "已停用 systemd-timesyncd，避免与 chrony 冲突"
    fi

    # Debian 的 chrony.conf 默认包含 conf.d/*.conf；iburst 加快首次同步
    mkdir -p "${CHRONY_CONF%/*}"
    {
        echo "# 由 debian13_setup.sh 生成"
        local s
        for s in "${NTP_SERVERS[@]}"; do
            echo "server $s iburst"
        done
        # 偏差大于 1 秒时，前 3 次更新允许直接跳变校准
        echo "makestep 1.0 3"
    } > "$CHRONY_CONF"

    # 去掉 Debian 默认的 pool 行（注释掉而非删除，首次修改前备份）
    if grep -qE '^[[:space:]]*pool[[:space:]]' /etc/chrony/chrony.conf; then
        [ -f /etc/chrony/chrony.conf.orig ] || cp -a /etc/chrony/chrony.conf /etc/chrony/chrony.conf.orig
        sed -i -E 's/^([[:space:]]*pool[[:space:]].*)$/# 已由 debian13_setup.sh 禁用: \1/' /etc/chrony/chrony.conf
        echo "已禁用 Debian 默认 NTP 池 (原配置备份: /etc/chrony/chrony.conf.orig)"
    fi

    # enable 设置开机自启，restart 让新配置立即生效
    if ! systemctl enable chrony >/dev/null 2>&1 || ! systemctl restart chrony; then
        echo "警告：chrony 服务启动失败，请执行 systemctl status chrony 查看原因"
        return
    fi

    # 最多等待约 30 秒完成首次同步，成功后再强制校准一次
    if chronyc waitsync 3 0.5 >/dev/null 2>&1; then
        chronyc makestep >/dev/null 2>&1
        echo "时间同步成功:"
    else
        echo "警告：暂未同步成功 (网络可能不通)，chrony 会在后台持续重试，当前状态:"
    fi
    chronyc tracking
    echo "--------------------------------------------------"
}

# ---------------------------------------------------------
# journald 日志限额：进入系统优化菜单时自动执行，已配置则跳过
# ---------------------------------------------------------
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/10-debian13-setup.conf"

auto_limit_journal() {
    [ -f "$JOURNALD_DROPIN" ] && return

    mkdir -p "${JOURNALD_DROPIN%/*}"
    cat <<EOF > "$JOURNALD_DROPIN"
# 由 debian13_setup.sh 生成
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
MaxFileSec=1week
EOF
    if systemctl restart systemd-journald; then
        echo "已限制 journald 日志占用: 持久化 200M / 内存 50M / 单文件 1 周 ($JOURNALD_DROPIN)"
    else
        echo "警告：systemd-journald 重启失败，日志限额可能未生效"
    fi
}

# ---------------------------------------------------------
# 内核参数调优 (网络吞吐 + Samba 文件共享)：进入系统优化菜单时自动执行
# 只写入已查证的参数，其余保持 Debian 默认值；配置无变化则跳过
# ---------------------------------------------------------
SYSCTL_TUNE="/etc/sysctl.d/99-debian13-setup.conf"
MODULES_TUNE="/etc/modules-load.d/debian13-setup.conf"

auto_tune_kernel() {
    # BBR 可能是未加载的模块，先尝试加载，再确认内核确实提供
    local bbr_ok=0 content
    modprobe tcp_bbr 2>/dev/null
    modprobe sch_fq 2>/dev/null
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && bbr_ok=1

    local lines=("# 由 debian13_setup.sh 生成")
    if [ "$bbr_ok" -eq 1 ]; then
        lines+=(
            "# BBR 需配合 fq"
            "net.core.default_qdisc = fq"
            "net.ipv4.tcp_congestion_control = bbr"
        )
    fi
    lines+=(
        "# 连接空闲后不重置拥塞窗口，利于 SMB 等突发传输"
        "net.ipv4.tcp_slow_start_after_idle = 0"
        "# 检测到 ICMP 黑洞时启用 MTU 探测"
        "net.ipv4.tcp_mtu_probing = 1"
        "# 脏页后台刷盘 64MB、上限 256MB，避免大文件写入时长时间卡顿"
        "vm.dirty_background_bytes = 67108864"
        "vm.dirty_bytes = 268435456"
        "# 多保留目录和 inode 缓存，浏览大目录更快"
        "vm.vfs_cache_pressure = 50"
        "vm.swappiness = 10"
    )
    content=$(printf '%s\n' "${lines[@]}")

    # 配置与上次完全一致则跳过 (换内核后 BBR 可用性变化时会自动重写)
    if [ -f "$SYSCTL_TUNE" ] && [ "$(cat "$SYSCTL_TUNE")" = "$content" ]; then
        return
    fi

    echo "--------------------------------------------------"
    echo "正在写入内核参数调优 ($SYSCTL_TUNE)..."
    if systemd-detect-virt -c -q 2>/dev/null; then
        echo "提示：当前运行在容器中，部分内核参数可能被宿主机限制而无法修改"
    fi

    mkdir -p "${SYSCTL_TUNE%/*}"
    printf '%s\n' "$content" > "$SYSCTL_TUNE"

    if [ "$bbr_ok" -eq 1 ]; then
        # 开机自动加载 BBR 与 fq 模块
        mkdir -p "${MODULES_TUNE%/*}"
        printf 'tcp_bbr\nsch_fq\n' > "$MODULES_TUNE"
    else
        echo "提示：当前内核不提供 BBR，已跳过 BBR 与 fq 配置"
    fi

    if sysctl -p "$SYSCTL_TUNE"; then
        echo "内核参数已生效"
    else
        echo "警告：部分参数写入失败 (见上方输出)，其余参数不受影响"
    fi
    [ "$bbr_ok" -eq 1 ] && echo "当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "说明：fq 对已存在的网卡需重启后才会成为其队列规则"
    echo "--------------------------------------------------"
}

optimize_menu() {
    auto_sync_time
    auto_limit_journal
    auto_tune_kernel
    while true; do
        cat <<'MENU_EOF'
--------------------------------------------------
  1) 安装常用软件包 (勾选式多选)
  2) 修改 IP/网关/DNS (静态)
  3) 恢复 DHCP (自动获取)
  4) 设置主机名
  5) 关闭 IPv6
  6) 恢复 IPv6
  7) 开启 root 用户 SSH 登录
  8) SSH 改为仅密钥登录
  9) 恢复 SSH 密码登录
 10) BBR 拥塞控制
 11) swap 虚拟内存
 12) 限制 journald 日志大小
 13) 系统语言 (locale)
  0) 返回主菜单
--------------------------------------------------
MENU_EOF
        read -rp "请选择: " opt
        MENU_BACK=0
        case "$opt" in
            1) install_common_packages ;;
            2) configure_network ;;
            3) restore_dhcp ;;
            4) set_hostname ;;
            5) disable_ipv6 ;;
            6) restore_ipv6 ;;
            7) enable_root_ssh ;;
            8) ssh_key_only ;;
            9) restore_ssh_password ;;
            10) bbr_menu ;;
            11) swap_menu ;;
            12) limit_journald ;;
            13) set_locale ;;
            0) MENU_BACK=1; return ;;
            *) echo "无效选项" ;;
        esac
        [ "$opt" != "0" ] && [ "$MENU_BACK" -eq 0 ] && pause
    done
}

# ---------------------------------------------------------
# 7. 安装 Docker / Docker Compose
# 参考 linuxmirrors.cn 的 Docker 脚本做法，此处只保留 Debian 所需逻辑
# ---------------------------------------------------------
DOCKER_REGISTRY_MIRRORS='["https://docker.1ms.run", "https://docker.m.daocloud.io", "https://docker.1panel.live", "https://dockerproxy.net"]'

install_docker_engine() {
    echo "请选择 Docker CE 软件源:"
    echo "1) 阿里云   (mirrors.aliyun.com)"
    echo "2) 腾讯云   (mirrors.tencent.com)"
    echo "3) 华为云   (mirrors.huaweicloud.com)"
    echo "4) 清华大学 (mirrors.tuna.tsinghua.edu.cn)"
    echo "5) 教育网联合镜像 (mirrors.cernet.edu.cn)"
    echo "6) 官方源   (download.docker.com)"
    echo "0) 返回"
    read -rp "请选择 [默认 1]: " opt
    opt=${opt:-1}

    local src=""
    case "$opt" in
        1) src="mirrors.aliyun.com/docker-ce" ;;
        2) src="mirrors.tencent.com/docker-ce" ;;
        3) src="mirrors.huaweicloud.com/docker-ce" ;;
        4) src="mirrors.tuna.tsinghua.edu.cn/docker-ce" ;;
        5) src="mirrors.cernet.edu.cn/docker-ce" ;;
        6) src="download.docker.com" ;;
        0) return ;;
        *) echo "无效选项"; return ;;
    esac

    ensure_pkgs ca-certificates curl gnupg || return

    # 部分镜像站同步较慢，本系统代号不可用时回退到 bookworm 分支
    local docker_codename="$CODENAME"
    if ! curl -fsSL -o /dev/null --max-time 20 -A "Debian APT-HTTP/1.3" "https://$src/linux/debian/dists/$CODENAME/Release"; then
        echo "该源暂未同步 $CODENAME，回退使用 bookworm 分支"
        docker_codename="bookworm"
    fi

    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "https://$src/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc; then
        echo "GPG 密钥下载失败，操作取消"
        return
    fi
    chmod a+r /etc/apt/keyrings/docker.asc

    cat <<EOF > /etc/apt/sources.list.d/docker.list
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://$src/linux/debian $docker_codename stable
EOF

    apt update
    if ! apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "Docker 安装失败"
        return
    fi

    systemctl enable --now docker
    echo "--------------------------------------------------"
    docker --version
    docker compose version
    echo "--------------------------------------------------"

    read -rp "是否同时配置国内镜像仓库加速器？[Y/n]: " c
    [[ "$c" =~ ^[Nn]$ ]] || configure_docker_registry
}

configure_docker_registry() {
    mkdir -p /etc/docker
    if [ -s /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
        # 已有其它配置项，用 jq 只替换 registry-mirrors，避免整体覆盖
        ensure_pkgs jq || return
        local tmp="/tmp/daemon.json.$$"
        TMPFILES+=("$tmp")
        if jq --argjson v "$DOCKER_REGISTRY_MIRRORS" '.["registry-mirrors"] = $v' /etc/docker/daemon.json > "$tmp"; then
            mv "$tmp" /etc/docker/daemon.json
        else
            echo "daemon.json 不是合法 JSON，请手动检查后重试"
            return
        fi
    else
        cat <<EOF > /etc/docker/daemon.json
{
  "registry-mirrors": $DOCKER_REGISTRY_MIRRORS
}
EOF
    fi

    if systemctl is-active --quiet docker; then
        systemctl restart docker && echo "镜像加速器已配置并重启 Docker"
    else
        echo "镜像加速器已写入，Docker 服务当前未运行"
    fi
}

add_user_to_docker_group() {
    local u
    read -rp "要加入 docker 组的用户名: " u
    if [ -z "$u" ] || ! id "$u" >/dev/null 2>&1; then
        echo "用户不存在，操作取消"
        return
    fi
    usermod -aG docker "$u"
    echo "$u 已加入 docker 组，需要重新登录后生效"
}

install_docker() {
    echo "1) 安装 Docker + Docker Compose"
    echo "2) 仅配置国内镜像仓库加速器"
    echo "3) 将某个用户加入 docker 组 (免 sudo 使用)"
    echo "0) 返回主菜单"
    read -rp "请选择: " opt
    case "$opt" in
        1) install_docker_engine ;;
        2) configure_docker_registry ;;
        3) add_user_to_docker_group ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

# ---------------------------------------------------------
# 8. 安全加固
# ---------------------------------------------------------

# 修改 SSH 端口：先新旧端口同时监听，确认新端口能登录后再关闭旧端口
change_ssh_port() {
    local cur newport bk p c now
    cur=$(sshd_ports | paste -sd' ' -)
    if [ -z "$cur" ]; then
        echo "无法读取当前 sshd 配置，请先执行 sshd -t 检查"
        return
    fi
    echo "当前 SSH 端口: $cur"
    read -rp "请输入新的 SSH 端口 (建议 1024-65535): " newport
    if ! valid_port "$newport"; then
        echo "端口号无效: $newport"
        return
    fi
    if [[ " $cur " == *" $newport "* ]]; then
        echo "SSH 已在使用端口 $newport"
        return
    fi
    if ss -Hltn "sport = :$newport" 2>/dev/null | grep -q .; then
        echo "端口 $newport 已被其它程序占用"
        return
    fi

    ensure_sshd_include
    # 主配置中的 Port 统一迁移到 drop-in，之后只需维护 drop-in 一处
    if grep -qE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config; then
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        sed -i -E 's/^([[:space:]]*Port[[:space:]])/# \1/' /etc/ssh/sshd_config
    fi
    remove_dropin_key Port
    touch "$SSHD_DROPIN"
    for p in $cur; do
        echo "Port $p" >> "$SSHD_DROPIN"
    done
    # 此时的 drop-in 与原先生效的端口一致，作为回退基准
    bk=$(backup_dropin)

    echo "Port $newport" >> "$SSHD_DROPIN"
    sshd_apply "$bk" || return
    fw_refresh
    f2b_refresh

    echo "--------------------------------------------------"
    echo "SSH 现在同时监听: $cur $newport"
    echo "请【新开终端】测试新端口: ssh -p $newport 用户名@服务器IP"
    echo "云服务器还需要在控制台安全组中放行 TCP $newport"
    echo "--------------------------------------------------"
    read -rp "新端口登录正常，关闭旧端口？(输入 n 恢复为原端口) [y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        remove_dropin_key Port
        echo "Port $newport" >> "$SSHD_DROPIN"
        sshd_apply "$bk"
    else
        restore_dropin "$bk"
        sshd_apply "$bk"
        echo "已恢复为原端口"
    fi
    fw_refresh
    f2b_refresh

    now=$(sshd_ports | paste -sd' ' -)
    echo "当前 SSH 端口: $now"
    if [[ "$c" =~ ^[Yy]$ ]] && [ "$now" != "$newport" ]; then
        echo "注意：仍有其它端口在监听，可能是 /etc/ssh/sshd_config.d/ 下其它文件设置了 Port"
    fi
}

F2B_JAIL="/etc/fail2ban/jail.d/00-debian13-setup.local"

# 端口变化后同步 fail2ban 的 sshd 监控端口
f2b_refresh() {
    [ -f "$F2B_JAIL" ] || return 0
    sed -i "s/^port = .*/port = $(sshd_ports | paste -sd, -)/" "$F2B_JAIL"
    systemctl is-active --quiet fail2ban && fail2ban-client reload >/dev/null 2>&1
    return 0
}

setup_fail2ban() {
    ensure_pkgs fail2ban python3-systemd nftables || return

    local maxretry bantime client c ignore="127.0.0.1/8 ::1"
    read -rp "最大失败次数 [默认 5]: " maxretry
    maxretry=${maxretry:-5}
    if [[ ! "$maxretry" =~ ^[1-9][0-9]*$ ]]; then
        echo "失败次数无效: $maxretry"
        return
    fi
    read -rp "封禁时长 (如 30m、1h、1d，-1 为永久) [默认 1h]: " bantime
    bantime=${bantime:-1h}
    if [[ ! "$bantime" =~ ^(-1|[0-9]+[smhdw]?)$ ]]; then
        echo "封禁时长格式无效: $bantime"
        return
    fi

    # sudo 会清掉 SSH_CLIENT，取不到时再从 who -m 里取来源地址
    client="${SSH_CLIENT%% *}"
    [ -z "$client" ] && client=$(who -m 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F.:]*\)).*/\1/p')
    if [ -n "$client" ]; then
        read -rp "是否把当前登录 IP $client 加入白名单 (永不封禁)？[Y/n]: " c
        [[ "$c" =~ ^[Nn]$ ]] || ignore="$ignore $client"
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat <<EOF > "$F2B_JAIL"
# 由 debian13_setup.sh 生成
[DEFAULT]
# Debian 13 默认使用 nftables
banaction = nftables-multiport
banaction_allports = nftables-allports
ignoreip = $ignore

[sshd]
enabled = true
# Debian 13 默认不装 rsyslog，没有 /var/log/auth.log，需要从 journal 读取
backend = systemd
# OpenSSH 10 起认证日志由 sshd-session 进程输出
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session
port = $(sshd_ports | paste -sd, -)
maxretry = $maxretry
findtime = 10m
bantime = $bantime
EOF

    if ! fail2ban-client -t >/dev/null 2>&1; then
        echo "fail2ban 配置校验失败:"
        fail2ban-client -t
        return
    fi
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    sleep 2
    echo "fail2ban 已启用，配置文件: $F2B_JAIL"
    fail2ban-client status sshd
}

fail2ban_menu() {
    echo "1) 安装 / 重新配置 fail2ban (保护 SSH)"
    echo "2) 查看 SSH 封禁状态"
    echo "3) 解封指定 IP"
    echo "0) 返回"
    read -rp "请选择: " opt
    case "$opt" in
        1) setup_fail2ban ;;
        2|3)
            if ! command -v fail2ban-client >/dev/null 2>&1; then
                echo "fail2ban 未安装，请先选择 1"
                return
            fi
            if [ "$opt" = "2" ]; then
                fail2ban-client status sshd
            else
                local ip
                read -rp "要解封的 IP: " ip
                [ -n "$ip" ] && fail2ban-client set sshd unbanip "$ip"
            fi
            ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

# ---------- 防火墙 (nftables) ----------
# 只维护自己的 inet debian13_fw 表，不 flush ruleset，
# 以免清掉 Docker、fail2ban 写入的规则
FW_CONF="$SETUP_DIR/firewall.conf"
FW_ORIG="/etc/nftables.conf.debian13-orig"
FW_TABLE_NAME="debian13_fw"

fw_enabled() {
    command -v nft >/dev/null 2>&1 && nft list table inet "$FW_TABLE_NAME" >/dev/null 2>&1
}

fw_load_conf() {
    FW_TCP=""
    FW_UDP=""
    FW_PING=1
    # shellcheck disable=SC1090
    [ -f "$FW_CONF" ] && . "$FW_CONF"
}

fw_save_conf() {
    mkdir -p "$SETUP_DIR"
    cat <<EOF > "$FW_CONF"
# 防火墙额外放行的端口，SSH 端口会自动放行，无需写在这里
FW_TCP="$FW_TCP"
FW_UDP="$FW_UDP"
FW_PING=$FW_PING
EOF
}

# 端口列表转成 nft 集合写法，如 "22 80" -> "22, 80"
fw_join() {
    printf '%s\n' "$@" | sed '/^$/d' | sort -u | paste -sd, - | sed 's/,/, /g'
}

fw_render() {
    local tcp udp
    # 此处需要按空格拆分端口列表，故意不加引号
    tcp=$(fw_join $(sshd_ports) $FW_TCP)
    udp=$(fw_join $FW_UDP)
    cat <<EOF
#!/usr/sbin/nft -f
# 由 debian13_setup.sh 生成，请通过脚本菜单修改
# 未使用 flush ruleset，以免清掉 Docker / fail2ban 的规则
table inet $FW_TABLE_NAME
delete table inet $FW_TABLE_NAME

table inet $FW_TABLE_NAME {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        # 允许 Docker 容器访问宿主机上的服务
        iifname "docker0" accept
        iifname "br-*" accept
EOF
    if [ "$FW_PING" != "1" ]; then
        echo '        icmp type echo-request drop'
        echo '        icmpv6 type echo-request drop'
    fi
    echo '        meta l4proto icmp accept'
    echo '        # IPv6 邻居发现等依赖 ICMPv6，必须放行'
    echo '        meta l4proto ipv6-icmp accept'
    echo '        # DHCPv6 客户端'
    echo '        udp dport 546 ip6 saddr fe80::/10 accept'
    [ -n "$tcp" ] && echo "        tcp dport { $tcp } accept"
    [ -n "$udp" ] && echo "        udp dport { $udp } accept"
    echo '    }'
    echo '}'
}

# 生成并加载规则；参数为 1 时需要在 60 秒内确认，否则自动回滚
fw_apply() {
    local confirm="${1:-0}" newconf="/tmp/nftables.conf.$$" ts bkdir rb
    ensure_pkgs nftables || return 1
    fw_load_conf
    TMPFILES+=("$newconf")
    fw_render > "$newconf"
    if ! nft -c -f "$newconf"; then
        echo "防火墙规则校验失败，未做任何修改（端口范围是否有重叠？）"
        return 1
    fi

    ts=$(date +%Y%m%d%H%M%S)
    bkdir="/root/fw-backup-$ts"
    mkdir -p "$bkdir"
    [ -f /etc/nftables.conf ] && cp -a /etc/nftables.conf "$bkdir/"
    fw_enabled && nft list table inet "$FW_TABLE_NAME" > "$bkdir/prev_table.nft"
    # 首次启用时保留系统原始配置，关闭防火墙时还原
    if [ ! -f "$FW_ORIG" ] && [ -f /etc/nftables.conf ] && ! grep -q 'debian13_setup.sh' /etc/nftables.conf; then
        cp -a /etc/nftables.conf "$FW_ORIG"
    fi

    rb="/run/fw-rollback-$ts.sh"
    cat <<EOF > "$rb"
nft delete table inet $FW_TABLE_NAME 2>/dev/null
[ -s "$bkdir/prev_table.nft" ] && nft -f "$bkdir/prev_table.nft"
if [ -f "$bkdir/nftables.conf" ]; then
    cp -a "$bkdir/nftables.conf" /etc/nftables.conf
else
    rm -f /etc/nftables.conf
fi
EOF

    install -m 0755 "$newconf" /etc/nftables.conf
    if ! nft -f /etc/nftables.conf; then
        bash "$rb"
        rm -f "$rb"
        echo "防火墙规则加载失败，已还原"
        return 1
    fi
    # 只设置开机加载；不要 restart nftables 服务，它的 stop 动作会 flush 全部规则
    systemctl enable nftables >/dev/null 2>&1
    echo "防火墙规则已加载，放行 TCP: $(fw_join $(sshd_ports) $FW_TCP)  UDP: $(fw_join $FW_UDP)"

    if [ "$confirm" = "1" ]; then
        apply_with_rollback "$rb"
    else
        rm -f "$rb"
    fi
}

# SSH 端口等变化后，防火墙已启用时同步规则
fw_refresh() {
    fw_enabled || return 0
    echo "正在同步防火墙规则..."
    fw_apply 0
}

fw_enable() {
    ensure_pkgs nftables || return
    fw_load_conf

    local tcp udp p c
    echo "SSH 端口 ($(sshd_ports | paste -sd' ' -)) 会自动放行"
    read -rp "额外放行的 TCP 端口 (空格分隔，支持范围如 8000-8100；直接回车保持 [${FW_TCP:-无}]): " tcp
    read -rp "额外放行的 UDP 端口 (直接回车保持 [${FW_UDP:-无}]): " udp
    for p in $tcp $udp; do
        if ! valid_port_or_range "$p"; then
            echo "端口格式无效: $p"
            return
        fi
    done
    # 此处用 echo 顺便去掉多余空格
    [ -n "$tcp" ] && FW_TCP=$(echo $tcp)
    [ -n "$udp" ] && FW_UDP=$(echo $udp)
    read -rp "是否允许 ping？[Y/n]: " c
    if [[ "$c" =~ ^[Nn]$ ]]; then FW_PING=0; else FW_PING=1; fi
    fw_save_conf

    echo "提示：Docker 映射出去的容器端口走 forward 链，不受本防火墙控制"
    fw_apply 1
}

# 参数：add 放行 / del 移除
fw_edit_ports() {
    local action="$1" proto input list p ssh_ports
    read -rp "协议 [tcp/udp，默认 tcp]: " proto
    proto=${proto:-tcp}
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        echo "协议无效: $proto"
        return
    fi
    read -rp "端口 (空格分隔，支持范围如 8000-8100): " input
    [ -z "$input" ] && { echo "未输入端口"; return; }

    fw_load_conf
    if [ "$proto" = "tcp" ]; then list="$FW_TCP"; else list="$FW_UDP"; fi
    ssh_ports=" $(sshd_ports | paste -sd' ' -) "
    for p in $input; do
        if ! valid_port_or_range "$p"; then
            echo "端口格式无效，已跳过: $p"
            continue
        fi
        if [ "$action" = "add" ]; then
            [[ " $list " == *" $p "* ]] || list="$list $p"
        else
            if [ "$proto" = "tcp" ] && [[ "$ssh_ports" == *" $p "* ]]; then
                echo "$p 是 SSH 端口，会始终放行，无法移除"
                continue
            fi
            list=$(printf '%s\n' $list | grep -vxF "$p" | paste -sd' ' -)
        fi
    done
    list=$(echo $list)
    if [ "$proto" = "tcp" ]; then FW_TCP="$list"; else FW_UDP="$list"; fi
    fw_save_conf

    if fw_enabled; then
        fw_apply 0
    else
        echo "已保存，防火墙当前未启用，启用后生效"
    fi
}

fw_disable() {
    local c
    read -rp "确认关闭防火墙？[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
    nft delete table inet "$FW_TABLE_NAME" 2>/dev/null
    if [ -f "$FW_ORIG" ]; then
        mv "$FW_ORIG" /etc/nftables.conf
    else
        printf '#!/usr/sbin/nft -f\n# 防火墙已通过 debian13_setup.sh 关闭\n' > /etc/nftables.conf
    fi
    echo "防火墙已关闭（端口配置保留在 $FW_CONF，重新启用时沿用）"
}

firewall_menu() {
    if fw_enabled; then echo "防火墙状态: 已启用"; else echo "防火墙状态: 未启用"; fi
    echo "1) 启用 / 重新配置防火墙"
    echo "2) 放行端口"
    echo "3) 移除已放行的端口"
    echo "4) 查看当前规则"
    echo "5) 关闭防火墙"
    echo "0) 返回"
    read -rp "请选择: " opt
    case "$opt" in
        1) fw_enable ;;
        2) fw_edit_ports add ;;
        3) fw_edit_ports del ;;
        4)
            if fw_enabled; then
                nft list table inet "$FW_TABLE_NAME"
            else
                echo "防火墙未启用"
            fi
            ;;
        5) fw_disable ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

# ---------- 自动安全更新 ----------
AUTO_UPGRADE_CONF="/etc/apt/apt.conf.d/20auto-upgrades"
UU_LOCAL_CONF="/etc/apt/apt.conf.d/52debian13-setup-unattended"

enable_auto_update() {
    ensure_pkgs unattended-upgrades || return

    local reboot="false" rtime="04:00" c
    read -rp "需要重启的更新 (如内核) 安装后是否自动重启？[y/N]: " c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        reboot="true"
        read -rp "自动重启时间 (HH:MM) [默认 04:00]: " rtime
        rtime=${rtime:-04:00}
        if [[ ! "$rtime" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            echo "时间格式无效: $rtime"
            return
        fi
    fi

    cat <<EOF > "$AUTO_UPGRADE_CONF"
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    cat <<EOF > "$UU_LOCAL_CONF"
// 由 debian13_setup.sh 生成
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "$rtime";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1

    if [ "$reboot" = "true" ]; then
        echo "自动更新已启用，需要重启时将在 $rtime 自动重启"
    else
        echo "自动更新已启用，不会自动重启（可用 [ -f /run/reboot-required ] 检查是否需要重启）"
    fi
    echo "按 Debian 默认策略只自动安装安全更新和稳定版小版本更新"
    echo "(更新范围见 /etc/apt/apt.conf.d/50unattended-upgrades，日志在 /var/log/unattended-upgrades/)"
}

auto_update_menu() {
    echo "1) 启用自动安全更新"
    echo "2) 关闭自动更新"
    echo "3) 试运行 (查看会自动更新哪些包，不实际安装)"
    echo "0) 返回"
    read -rp "请选择: " opt
    case "$opt" in
        1) enable_auto_update ;;
        2)
            cat <<EOF > "$AUTO_UPGRADE_CONF"
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
            echo "自动更新已关闭"
            ;;
        3)
            if command -v unattended-upgrade >/dev/null 2>&1; then
                unattended-upgrade --dry-run -v
            else
                echo "unattended-upgrades 未安装，请先选择 1"
            fi
            ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

security_menu() {
    while true; do
        cat <<'MENU_EOF'
--------------------------------------------------
  1) 修改 SSH 端口
  2) fail2ban 防 SSH 暴力破解
  3) 防火墙 (nftables)
  4) 自动安全更新 (unattended-upgrades)
  0) 返回主菜单
--------------------------------------------------
MENU_EOF
        read -rp "请选择: " opt
        MENU_BACK=0
        case "$opt" in
            1) change_ssh_port ;;
            2) fail2ban_menu ;;
            3) firewall_menu ;;
            4) auto_update_menu ;;
            0) MENU_BACK=1; return ;;
            *) echo "无效选项" ;;
        esac
        [ "$opt" != "0" ] && [ "$MENU_BACK" -eq 0 ] && pause
    done
}

# ---------------------------------------------------------
# BBR / swap / journald 日志 / locale (入口在系统优化菜单 10-13 项)
# ---------------------------------------------------------
BBR_CONF="/etc/sysctl.d/99-debian13-bbr.conf"
BBR_MODULE_CONF="/etc/modules-load.d/debian13-bbr.conf"

bbr_menu() {
    echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)，队列算法: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "1) 开启 BBR + fq"
    echo "2) 关闭 BBR (恢复 cubic + fq_codel)"
    echo "0) 返回"
    read -rp "请选择: " opt
    case "$opt" in
        1)
            modprobe tcp_bbr 2>/dev/null
            if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                echo "当前内核不支持 BBR（OpenVZ / LXC 容器通常无法修改），操作取消"
                return
            fi
            printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$BBR_CONF"
            echo "tcp_bbr" > "$BBR_MODULE_CONF"
            sysctl -p "$BBR_CONF"
            echo "BBR 已开启（对新建立的连接生效）"
            ;;
        2)
            rm -f "$BBR_CONF" "$BBR_MODULE_CONF"
            sysctl -w net.core.default_qdisc=fq_codel >/dev/null
            sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
            echo "BBR 已关闭，恢复为 cubic + fq_codel"
            ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

SWAPFILE="/swapfile"
SWAPPINESS_CONF="/etc/sysctl.d/99-debian13-swappiness.conf"

remove_swapfile() {
    if grep -q "^${SWAPFILE}[[:space:]]" /proc/swaps; then
        swapoff "$SWAPFILE" || return 1
    fi
    rm -f "$SWAPFILE"
    sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
}

create_swap() {
    local mem_mb def_mb size avail fstype old_mb=0
    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    # 建议值：内存 ≤2G 取 2 倍，≤8G 取等量，更大时固定 8G
    if [ "$mem_mb" -le 2048 ]; then
        def_mb=$((mem_mb * 2))
    elif [ "$mem_mb" -le 8192 ]; then
        def_mb=$mem_mb
    else
        def_mb=8192
    fi
    echo "物理内存: ${mem_mb}MB"
    read -rp "swap 大小，单位 MB [建议 $def_mb]: " size
    size=${size:-$def_mb}
    if [[ ! "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 64 ]; then
        echo "大小无效，至少 64MB"
        return
    fi

    fstype=$(findmnt -no FSTYPE / 2>/dev/null)
    case "$fstype" in
        zfs|overlay|tmpfs|nfs*)
            echo "根分区文件系统为 $fstype，不支持 swap 文件"
            return
            ;;
    esac

    [ -f "$SWAPFILE" ] && old_mb=$(( $(stat -c %s "$SWAPFILE") / 1024 / 1024 ))
    avail=$(df -Pm / | awk 'NR == 2 {print $4}')
    # 至少再留 512MB 余量，避免把根分区写满
    if [ $((avail + old_mb)) -lt $((size + 512)) ]; then
        echo "磁盘空间不足：可用 $((avail + old_mb))MB，需要 $((size + 512))MB（含 512MB 余量）"
        return
    fi

    if [ -f "$SWAPFILE" ]; then
        echo "正在移除旧的 $SWAPFILE ..."
        remove_swapfile || { echo "旧 swap 关闭失败（内存可能不足以容纳 swap 中的数据）"; return; }
    fi

    echo "正在创建 ${size}MB 的 $SWAPFILE ..."
    if [ "$fstype" = "btrfs" ]; then
        # btrfs 的 swap 文件必须关闭写时复制，用专用命令创建
        btrfs filesystem mkswapfile --size "${size}m" "$SWAPFILE" || { echo "创建失败"; return; }
    else
        if ! fallocate -l "${size}M" "$SWAPFILE" 2>/dev/null; then
            dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size" status=progress || { rm -f "$SWAPFILE"; echo "创建失败"; return; }
        fi
        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null || { rm -f "$SWAPFILE"; echo "mkswap 失败"; return; }
    fi

    if ! swapon "$SWAPFILE"; then
        rm -f "$SWAPFILE"
        echo "swapon 失败（OpenVZ / LXC 容器通常不允许使用 swap）"
        return
    fi
    grep -q "^${SWAPFILE}[[:space:]]" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "swap 已创建并设置为开机自动启用"
    swapon --show
}

swap_menu() {
    echo "当前 swap:"
    swapon --show 2>/dev/null | sed 's/^/  /'
    [ -z "$(swapon --show 2>/dev/null)" ] && echo "  (无)"
    echo "当前 swappiness: $(sysctl -n vm.swappiness)"
    echo "1) 创建 / 调整 swap 文件 ($SWAPFILE)"
    echo "2) 删除 swap 文件"
    echo "3) 设置 swappiness (使用 swap 的积极程度)"
    echo "0) 返回"
    read -rp "请选择: " opt
    case "$opt" in
        1) create_swap ;;
        2)
            if [ ! -f "$SWAPFILE" ]; then
                echo "$SWAPFILE 不存在"
                return
            fi
            if remove_swapfile; then
                echo "swap 文件已删除"
            else
                echo "swap 关闭失败（内存可能不足以容纳 swap 中的数据）"
            fi
            ;;
        3)
            local v
            read -rp "swappiness 值 0-100 (服务器建议 10) [默认 10]: " v
            v=${v:-10}
            if [[ ! "$v" =~ ^[0-9]+$ ]] || [ "$v" -gt 100 ]; then
                echo "数值无效"
                return
            fi
            echo "vm.swappiness = $v" > "$SWAPPINESS_CONF"
            sysctl -p "$SWAPPINESS_CONF"
            ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项" ;;
    esac
}

JOURNALD_CONF="/etc/systemd/journald.conf.d/99-debian13-setup.conf"

limit_journald() {
    echo "当前日志占用: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | tail -1)"
    local size
    read -rp "日志最大占用空间 (如 200M、1G) [默认 200M]: " size
    size=${size:-200M}
    size=${size^^}
    if [[ ! "$size" =~ ^[0-9]+[KMG]$ ]]; then
        echo "格式无效，请使用数字加 K/M/G，如 200M"
        return
    fi
    mkdir -p "${JOURNALD_CONF%/*}"
    printf '[Journal]\nSystemMaxUse=%s\nRuntimeMaxUse=%s\n' "$size" "$size" > "$JOURNALD_CONF"
    systemctl restart systemd-journald
    journalctl --vacuum-size="$size" >/dev/null 2>&1
    echo "journald 日志上限已设为 $size，当前占用: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | tail -1)"
}

# 在 locale.gen 中启用指定 locale
enable_locale() {
    local l="$1"
    if grep -qE "^#?[[:space:]]*$l UTF-8" /etc/locale.gen; then
        sed -i -E "s/^#?[[:space:]]*($l UTF-8)/\1/" /etc/locale.gen
    else
        echo "$l UTF-8" >> /etc/locale.gen
    fi
}

set_locale() {
    ensure_pkgs locales || return
    echo "当前系统语言: $(grep -s '^LANG=' /etc/default/locale | cut -d= -f2 | tr -d '"')"
    echo "1) en_US.UTF-8 (英文，推荐服务器使用)"
    echo "2) zh_CN.UTF-8 (中文)"
    echo "3) 默认英文，同时生成中文 locale (可按用户切换)"
    echo "0) 返回"
    read -rp "请选择: " opt

    local def gens=()
    case "$opt" in
        1) def="en_US.UTF-8"; gens=(en_US.UTF-8) ;;
        2) def="zh_CN.UTF-8"; gens=(en_US.UTF-8 zh_CN.UTF-8) ;;
        3) def="en_US.UTF-8"; gens=(en_US.UTF-8 zh_CN.UTF-8) ;;
        0) MENU_BACK=1; return ;;
        *) echo "无效选项"; return ;;
    esac

    local l
    for l in "${gens[@]}"; do
        enable_locale "$l"
    done
    if ! locale-gen; then
        echo "locale 生成失败"
        return
    fi
    update-locale LANG="$def"
    echo "系统默认语言已设为 $def，重新登录后生效"
    [ "$def" = "zh_CN.UTF-8" ] && echo "注意：物理控制台 / VNC 的纯文本终端无法显示中文，会出现乱码；SSH 客户端显示正常"
    [ "$opt" = "3" ] && echo "某个用户需要中文时，可在其 ~/.bashrc 中加入: export LANG=zh_CN.UTF-8"
}

# ---------------------------------------------------------
# 9. 查看当前系统状态
# ---------------------------------------------------------
show_status() {
    echo "=================== 系统状态 ==================="
    printf "%-10s %s\n" "主机名"   "$(hostname)"
    printf "%-10s %s\n" "系统"     "${PRETTY_NAME:-$ID $VERSION_ID}"
    printf "%-10s %s\n" "内核"     "$(uname -r)"
    printf "%-10s %s\n" "架构"     "$(dpkg --print-architecture)"
    printf "%-10s %s\n" "时区"     "$(timedatectl show -p Timezone --value 2>/dev/null)"
    printf "%-10s %s\n" "运行时长" "$(uptime -p 2>/dev/null || uptime)"
    printf "%-10s %s\n" "内存"     "$(free -h | awk '/^Mem:/{print $3" / "$2}')"
    printf "%-10s %s\n" "根分区"   "$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    printf "%-10s %s\n" "网络管理" "$(detect_netmgr)"
    printf "%-10s %s\n" "IP 地址"  "$(ip -4 -o addr show scope global | awk '{print $2"="$4}' | tr '\n' ' ')"
    printf "%-10s %s\n" "默认网关" "$(ip route show default | awk '{print $3; exit}')"
    printf "%-10s %s\n" "DNS"      "$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
    printf "%-10s %s\n" "IPv6"     "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | sed 's/^1$/已禁用/; s/^0$/已启用/')"
    printf "%-10s %s\n" "Docker"   "$(docker --version 2>/dev/null || echo '未安装')"
    printf "%-10s %s\n" "SSH 端口" "$(sshd_ports | paste -sd' ' -)"
    printf "%-10s %s\n" "防火墙"   "$(fw_enabled && echo '已启用' || echo '未启用')"
    printf "%-10s %s\n" "fail2ban" "$(systemctl is-active --quiet fail2ban 2>/dev/null && echo '运行中' || echo '未运行')"
    printf "%-10s %s\n" "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf "%-10s %s\n" "Swap"     "$(free -h | awk '/^Swap:/{print $3" / "$2}')"
    printf "%-10s %s\n" "自动更新" "$(grep -qs 'Unattended-Upgrade "1"' "$AUTO_UPGRADE_CONF" && echo '已启用' || echo '未启用')"
    echo "----------------- 当前软件源 -------------------"
    grep -hE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | head -6
    grep -hE '^URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null | head -6
    echo "==============================================="
}

# ---------------------------------------------------------
# 10. 一键重装系统 (调用 bin456789/reinstall)
# ---------------------------------------------------------
REINSTALL_URLS=(
    "https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
    "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
)

reinstall_system() {
    cat <<'WARN_EOF'
!!!!!!!!!!!!!!!!!!!! 危 险 操 作 !!!!!!!!!!!!!!!!!!!!
本功能调用 bin456789/reinstall 脚本重装系统，将【清空整块硬盘的全部数据】。
执行前请确认：
  1) 重要数据已经备份，且确认不再需要当前系统
  2) 你能通过 VNC / IPMI / 救援模式访问这台机器（重装失败时无法远程恢复）
  3) 该机器为独立服务器或 KVM 架构 VPS，NAT / OpenVZ / LXC 不支持
  4) 重装过程约需 5-30 分钟，期间不要断电或手动重启
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARN_EOF
    read -rp "确认继续请输入大写 REINSTALL (其它任意输入取消): " c
    if [ "$c" != "REINSTALL" ]; then
        echo "已取消"
        return
    fi

    echo "请选择要安装的系统:"
    echo "1) Debian 13"
    echo "2) Debian 12"
    echo "3) Ubuntu 24.04"
    echo "4) Ubuntu 22.04"
    echo "5) Alpine 3.22"
    echo "6) 手动输入 (格式: 系统名 版本号，如 centos 10)"
    echo "0) 返回"
    read -rp "请选择: " opt

    local target=""
    case "$opt" in
        1) target="debian 13" ;;
        2) target="debian 12" ;;
        3) target="ubuntu 24.04" ;;
        4) target="ubuntu 22.04" ;;
        5) target="alpine 3.22" ;;
        6) read -rp "请输入 (系统名 版本号): " target ;;
        0) return ;;
        *) echo "无效选项"; return ;;
    esac
    if [ -z "$target" ]; then
        echo "未指定系统，操作取消"
        return
    fi

    local pw pw2
    read -rsp "请设置新系统的 root 密码: " pw
    echo ""
    read -rsp "请再次输入确认: " pw2
    echo ""
    if [ -z "$pw" ] || [ "$pw" != "$pw2" ]; then
        echo "两次输入不一致或为空，操作取消"
        return
    fi

    local sshport extra=""
    read -rp "新系统 SSH 端口 [默认 22，直接回车跳过]: " sshport
    if [ -n "$sshport" ]; then
        if [[ ! "$sshport" =~ ^[0-9]+$ ]] || [ "$sshport" -lt 1 ] || [ "$sshport" -gt 65535 ]; then
            echo "端口号无效，操作取消"
            return
        fi
        extra="--ssh-port $sshport"
    fi

    echo "--------------------------------------------------"
    echo "即将执行: bash reinstall.sh $target --password ****** $extra"
    echo "执行后机器会自动重启进入安装环境"
    echo "--------------------------------------------------"
    read -rp "最后确认，输入 yes 开始重装: " c2
    if [ "$c2" != "yes" ]; then
        echo "已取消"
        return
    fi

    ensure_pkgs curl ca-certificates || return

    local url tmp="/root/reinstall.sh"
    for url in "${REINSTALL_URLS[@]}"; do
        echo "正在下载重装脚本: $url"
        if curl -fsSL --connect-timeout 15 "$url" -o "$tmp"; then
            break
        fi
        echo "下载失败，尝试下一个地址..."
        rm -f "$tmp"
    done

    if [ ! -s "$tmp" ]; then
        echo "重装脚本下载失败，请检查网络后重试"
        return
    fi
    echo "脚本已保存到 $tmp (可自行审阅)"

    # target 和 extra 需要按空格拆成多个参数，此处故意不加引号
    bash "$tmp" $target --password "$pw" $extra
}

# ---------------------------------------------------------
# 主菜单
# ---------------------------------------------------------
main_menu() {
    while true; do
        echo "=================================================="
        echo "        Debian 13 (Trixie) 系统初始化脚本  v${SCRIPT_VERSION}"
        cat <<'MENU_EOF'
==================================================
  1. 更换软件源 (APT Source)
  2. 更新系统及所有软件包 (Update & Full-Upgrade)
  3. 修改时区 (Timezone)
  4. 更换系统内核 (Kernel)
  5. 清理未使用的旧内核
  6. 系统优化
  7. 安装 Docker / Docker Compose
  8. 安全加固 (SSH 端口 / fail2ban / 防火墙 / 自动更新)
  9. 查看当前系统状态
 10. 一键重装系统 (DD，危险操作)
  0. 退出脚本
==================================================
MENU_EOF
        read -rp "请输入选项编号: " choice
        MENU_BACK=0
        case "$choice" in
            1) change_source ;;
            2) update_system ;;
            3) change_timezone ;;
            4) change_kernel ;;
            5) clean_old_kernels ;;
            6) optimize_menu ;;
            7) install_docker ;;
            8) security_menu ;;
            9) show_status ;;
            10) reinstall_system ;;
            0) echo "退出脚本"; exit 0 ;;
            *) echo "无效选项" ;;
        esac
        [ "$choice" != "0" ] && [ "$MENU_BACK" -eq 0 ] && pause
    done
}

main_menu
