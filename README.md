<div align="center">

# 📡 AIC8800 USB WiFi + 蓝牙 驱动

AICSemi **AIC8800D80** 系列 USB 网卡（WiFi 6 + Bluetooth 5.x）的一键安装/卸载脚本

[![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu-orange.svg)](#-支持平台)
[![Kernel](https://img.shields.io/badge/Kernel-5.15~7.x-brightgreen.svg)](#-支持平台)

</div>

## ✨ 特性

- **单脚本**：`install` / `uninstall` 两个子命令，无需交互
- **WiFi + 蓝牙**：自动编译并加载 `aic8800_fdrv`（WiFi）、`aic_btusb`（蓝牙）
- **自动关盘**：自动关闭网卡自带的虚拟 U 盘，插上不再弹「WIFI driver」磁盘
- **幂等安全**：重复安装/卸载安全，卸载时自动恢复被修改的源码
- **离线友好**：依赖齐全时全程离线运行

## 🔌 支持的硬件

| 芯片 | USB ID（WiFi 模式） | 常见型号 |
|------|--------------------|----------|
| AIC8800D80 | `a69c:8d80` / `a69c:8d81` | 88M80、AX900 类 USB 网卡 |

## 🚀 快速开始

### 安装

```bash
git clone https://github.com/Sakurashiling/aic8800-usb-wifi-bt.git
cd aic8800-usb-wifi-bt
sudo ./aic8800.sh install
```

### 卸载

```bash
sudo ./aic8800.sh uninstall
```

### 连接 WiFi / 蓝牙

```bash
# WiFi
nmcli device wifi connect 'SSID' password '密码'

# 蓝牙
bluetoothctl
```

## 🗂️ 目录结构

```
.
├── aic8800.sh          # 一键安装/卸载脚本（核心）
├── src/                # 驱动源码 + 固件
│   └── USB/driver_fw/  #   aic8800 WiFi 驱动、aic_btusb 蓝牙驱动、固件
├── debian/             # Debian 打包相关
├── LICENSE             # GPL v3
└── README.md
```

## 🛡️ 关盘功能说明

AIC8800 网卡插入后会额外暴露一个 USB 存储设备（`1111:1111`）——即网卡自带的「盘」，里面装着 Windows 驱动 `Wifi6_install.exe`。

标准 `eject` 关不掉它。本脚本通过两个 vendor SCSI 命令（`0xF3` GetHippo → `0xF2` Set_CS1_0）隐藏该盘，并部署 udev 规则 + systemd 服务，**插上即自动关盘**。

## 🔧 固件选择修复（88M80 WiFi 连不上）

88M80 这类带 MCU 的 AIC8800D80 网卡，驱动源码里 `IS_CHIP_ID_H()` 判断会误判
（chip_id 的 H 位未设置），导致加载错误的 standard 固件
（`fmacfw_8800d80_u02.bin`），表现为 **WiFi 关联超时连不上**（5G/2.4G 都卡
`associating`）。安装脚本会在编译前自动把该判断改成 `if (1)`，强制加载
**H-variant combo 固件**（`fmacfw_8800d80_h_u02.bin`）。

## 📋 支持平台

| 项目 | 要求 |
|------|------|
| 系统 | Ubuntu 22.04 / 24.04（其他 Debian 系通常可用） |
| 内核 | 5.15 ~ 7.x（源码含 6.1 ~ 6.19 编译 patch） |
| 架构 | x86_64 / aarch64 |
| 依赖 | build-essential、linux-headers-$(uname -r)、bc、usb-modeswitch、bluez |

> 实测环境：Ubuntu 24.04 + Linux 7.0.0-30-generic + AIC8800D80

## 📄 许可证

[GPL v3](LICENSE)

## 🙏 致谢

- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) — 驱动源码
- [ademasi/aic8800d80-wifi-bt-linux](https://github.com/ademasi/aic8800d80-wifi-bt-linux) — 关盘逆向研究
