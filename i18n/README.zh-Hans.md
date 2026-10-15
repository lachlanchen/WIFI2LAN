[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner — apps and four buddies](https://lazying.art/media/brand/lazyingart-intro.gif)](https://lazying.art)

[![WIFI2LAN 横幅](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**为无显示器 Raspberry Pi 打造的可靠 Wi-Fi 转有线网络网关。**

WIFI2LAN 把 Raspberry Pi 的 Wi-Fi 连接转换成受管理的以太网上行链路。项目包含两套
可复现、可恢复的真实部署：位于 `192.168.13.1` 的 Pi 4B 网关，以及可在普通局域网
客户端和保留路由器配置之间安全切换的 Pi 5。

## 核心特点

- `arm` 会等待网线断开后才启动 DHCP，避免污染现有局域网。
- 每次变更前都会在 `/var/backups` 创建带时间戳的备份。
- NAT、DNS、DHCP、转发和开机持久化统一配置。
- 下游网络仍可通过 SSH 和 VNC 管理树莓派。
- 仓库中不保存任何 Wi-Fi 密码。
- 已通过真实下游 DHCP 租约和双向 NAT 流量验证。

## 组件

- [`pi4-router`](../pi4-router/)：Pi 4B 的 Wi-Fi 转 LAN 网关。
- [`pi5-client`](../pi5-client/)：Pi 5 客户端/路由器模式切换。

网络切换可能中断远程连接，操作前请阅读[完整英文文档](../README.md)并保留恢复路径。

## 支持项目

<!-- support:start -->
[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/lachlanchen)
[![LazyingArt Support](https://img.shields.io/badge/LazyingArt-Support-0EA5E9?style=for-the-badge)](https://chat.lazying.art/donate)
[![PayPal Support](https://img.shields.io/badge/PayPal-Support-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen)
[![Stripe Support](https://img.shields.io/badge/Stripe-Support-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400)
<!-- support:end -->
