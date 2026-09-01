#!/bin/bash
# ============================================================
#  aic8800.sh — AIC8800 USB WiFi + 蓝牙 驱动一键安装/卸载
#
#  用法：
#    sudo ./aic8800.sh install      安装驱动 + 自动关闭网卡盘功能
#    sudo ./aic8800.sh uninstall    卸载驱动 + 移除自动关闭网卡盘功能
#    ./aic8800.sh help              显示帮助
#
#  驱动来源：https://github.com/radxa-pkg/aic8800
#  关盘功能：基于 ademasi/aic8800d80-wifi-bt-linux 的逆向研究
#  作者：千织羽依-QzyuYi
# ============================================================

set -euo pipefail

# ---- 常量 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_SRC="$SCRIPT_DIR/src/USB/driver_fw/fw"
DRV_DIR="$SCRIPT_DIR/src/USB/driver_fw/drivers"
BT_HEADER="$DRV_DIR/aic_btusb/aic_btusb.h"

KVER="$(uname -r)"
MODDEST="/lib/modules/$KVER/kernel/drivers/net/wireless/aic8800"

# 关盘功能目标路径
UDISK_BIN="/usr/local/bin/aic8800-udisk-off"
UDISK_RULE="/etc/udev/rules.d/40-aic8800-udisk-off.rules"
UDISK_SVC="/etc/systemd/system/aic8800-udisk-off@.service"

# ---- 颜色 / 日志 ----
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log_info()  { echo -e "${GREEN}[+]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[x]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "请用 sudo 运行：sudo $0 install|uninstall"; }

# ============================================================
#  install 子流程
# ============================================================

install_deps() {
    log_info "检查依赖..."
    local missing=()
    local p
    for p in build-essential bc usb-modeswitch bluez "linux-headers-$KVER"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        log_info "依赖已齐全，跳过安装（可离线）"
        return
    fi
    log_info "安装缺失依赖：${missing[*]}"
    apt-get update -qq || log_warn "apt update 失败（离线可忽略）"
    apt-get install -y "${missing[@]}" || log_warn "依赖安装失败，若后续编译报错请检查"
}

clean_old() {
    log_info "清理旧驱动/固件/配置..."
    modprobe -r aic_btusb aic8800_fdrv aic_load_fw 2>/dev/null || true
    modprobe -r aic_btusb_usb aic8800_fdrv_usb aic_load_fw_usb 2>/dev/null || true
    rm -rf "$MODDEST"
    rm -rf /lib/firmware/aic8800*
    rm -f /etc/modules-load.d/aic8800.conf /etc/modules-load.d/aic_bt.conf
    rm -f /etc/systemd/system/aic8800-bluetooth-up.service
    systemctl disable aic8800-bluetooth-up.service 2>/dev/null || true
    depmod -a
}

# 蓝牙头文件置为 BlueZ 模式（幂等）
patch_bt() {
    log_info "配置蓝牙为 BlueZ 模式..."
    if grep -qE '^#define[[:space:]]+CONFIG_BLUEDROID[[:space:]]+0' "$BT_HEADER"; then
        log_info "已是 BlueZ 模式，跳过"
        return
    fi
    [ -f "$BT_HEADER.bak" ] || cp "$BT_HEADER" "$BT_HEADER.bak"
    sed -i 's/^#define[[:space:]]*CONFIG_BLUEDROID[[:space:]]*[0-9]/#define CONFIG_BLUEDROID 0/' "$BT_HEADER"
    log_info "已修改 CONFIG_BLUEDROID=0"
}

install_firmware() {
    log_info "安装固件..."
    [ -d "$FW_SRC" ] || die "未找到固件目录 $FW_SRC"
    cp -r "$FW_SRC"/* /lib/firmware/
    log_info "固件已安装到 /lib/firmware/（含 aic8800D80 等各型号）"
}

# 修复固件选择：88M80 卡 chip_id 误判（IS_CHIP_ID_H 返回 false）导致加载
# standard 固件、WiFi 关联超时连不上。强制加载 H-variant combo 固件（幂等）
patch_fw_select() {
    local fw_file="$DRV_DIR/aic8800/aic_load_fw/aic_compat_8800d80.c"
    if ! grep -q 'IS_CHIP_ID_H()' "$fw_file"; then
        log_info "固件选择已修复（H-variant），跳过"
        return
    fi
    [ -f "$fw_file.bak" ] || cp "$fw_file" "$fw_file.bak"
    sed -i 's/if (IS_CHIP_ID_H()){/if (1){/' "$fw_file"
    log_info "已强制加载 H-variant 固件（修复 88M80 WiFi 连不上）"
}

build_drivers() {
    log_info "编译驱动（可能需要几分钟）..."
    local log
    log=$(mktemp)
    if ! (cd "$DRV_DIR/aic8800" && make clean >/dev/null 2>&1 && make -j"$(nproc)") >>"$log" 2>&1; then
        log_error "aic8800 编译失败："; tail -30 "$log"; rm -f "$log"; return 1
    fi
    if ! (cd "$DRV_DIR/aic_btusb" && make clean >/dev/null 2>&1 && make -j"$(nproc)") >>"$log" 2>&1; then
        log_error "aic_btusb 编译失败："; tail -30 "$log"; rm -f "$log"; return 1
    fi
    rm -f "$log"
    log_info "编译完成"
}

install_modules() {
    log_info "安装内核模块..."
    mkdir -p "$MODDEST"
    install -p -m 644 "$DRV_DIR/aic8800/aic_load_fw/aic_load_fw.ko"     "$MODDEST/"
    install -p -m 644 "$DRV_DIR/aic8800/aic8800_fdrv/aic8800_fdrv.ko"   "$MODDEST/"
    install -p -m 644 "$DRV_DIR/aic_btusb/aic_btusb.ko"                 "$MODDEST/"
    depmod -a
    log_info "模块已安装到 $MODDEST"
}

# 部署隐藏网卡盘功能：1111:1111 虚拟U盘用 UDISKS_IGNORE 忽略（纯配置层，不碰 USB，不干扰 WiFi）
install_udisk_off() {
    log_info "部署隐藏网卡盘功能（1111:1111，不挂载不弹窗，不影响 WiFi）..."
    cat > "$UDISK_RULE" <<'EOF'
# AIC8800：隐藏虚拟 U 盘（1111:1111），不挂载不弹窗，不影响 WiFi
SUBSYSTEM=="block", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", ENV{UDISKS_IGNORE}="1"
EOF
    udevadm control --reload-rules
    log_info "隐藏网卡盘功能已部署"
}

load_modules() {
    log_info "加载模块..."
    modprobe cfg80211 2>/dev/null || true
    modprobe aic_load_fw    || log_warn "aic_load_fw 加载失败"
    modprobe aic8800_fdrv   || log_warn "aic8800_fdrv 加载失败"
    modprobe aic_btusb      || log_warn "aic_btusb 加载失败"
}

setup_autoload() {
    log_info "配置开机自启..."
    cat > /etc/modules-load.d/aic8800.conf <<'EOF'
aic_load_fw
aic8800_fdrv
aic_btusb
EOF
    # 确保蓝牙服务开机自启（防止被禁用后重启蓝牙丢失）
    systemctl enable bluetooth 2>/dev/null || true
}

verify() {
    log_info "验证..."
    local iface=""
    local i
    for i in $(seq 1 15); do
        iface=$(ip -br link 2>/dev/null | grep -oE '(wlx|wlan)[0-9a-f]*' | head -1)
        [ -n "$iface" ] && break
        sleep 1
    done
    if [ -n "$iface" ]; then
        log_info "无线接口：$iface"
        ip link set "$iface" up 2>/dev/null || true
    else
        log_warn "未检测到无线接口，请检查 dmesg"
    fi

    rfkill unblock bluetooth 2>/dev/null || true
    if [ -d /sys/class/bluetooth/hci0 ]; then
        log_info "蓝牙设备 hci0 已识别"
    else
        log_warn "蓝牙 hci0 未出现，可尝试重新插拔网卡"
    fi
}

do_install() {
    require_root
    log_info "AIC8800 驱动安装开始（内核 $KVER）"

    install_deps
    clean_old
    patch_bt
    install_firmware
    patch_fw_select
    build_drivers  || die "编译失败，安装中止"
    install_modules
    install_udisk_off
    load_modules
    setup_autoload
    verify

    log_info "安装完成。WiFi 用 nmcli 连接，蓝牙用 bluetoothctl 配对。"
}

# ============================================================
#  uninstall 子流程
# ============================================================

do_uninstall() {
    require_root
    log_info "AIC8800 驱动卸载开始"

    modprobe -r aic_btusb aic8800_fdrv aic_load_fw 2>/dev/null || true
    modprobe -r aic_btusb_usb aic8800_fdrv_usb aic_load_fw_usb 2>/dev/null || true

    rm -rf "$MODDEST"
    rm -rf /lib/firmware/aic8800*
    rm -f /etc/modules-load.d/aic8800.conf /etc/modules-load.d/aic_bt.conf
    rm -f /etc/systemd/system/aic8800-bluetooth-up.service
    rm -f "$UDISK_BIN" "$UDISK_RULE" "$UDISK_SVC"

    systemctl daemon-reload
    udevadm control --reload-rules

    # 恢复蓝牙头文件
    if [ -f "$BT_HEADER.bak" ]; then
        mv "$BT_HEADER.bak" "$BT_HEADER"
        log_info "已恢复蓝牙头文件"
    fi

    depmod -a
    log_info "卸载完成。建议重启以彻底清除模块。"
}

# ============================================================
#  入口
# ============================================================

usage() {
    cat <<'EOF'
用法：
  sudo ./aic8800.sh install      安装驱动 + 自动关闭网卡盘功能
  sudo ./aic8800.sh uninstall    卸载驱动 + 移除自动关闭网卡盘功能
  ./aic8800.sh help              显示本帮助
EOF
}

case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    help|-h|--help) usage ;;
    "")        usage ;;
    *)         usage; die "未知命令：$1" ;;
esac
