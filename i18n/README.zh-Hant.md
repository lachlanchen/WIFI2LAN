[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner — apps and four buddies](https://lazying.art/media/brand/lazyingart-intro.gif)](https://lazying.art)

[![WIFI2LAN 橫幅](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**為無螢幕 Raspberry Pi 打造的可靠 Wi-Fi 轉有線網路閘道。**

WIFI2LAN 把 Raspberry Pi 的 Wi-Fi 連線轉換成受管理的乙太網路上行鏈路。專案包含兩套
可重現、可復原的真實部署：位於 `192.168.13.1` 的 Pi 4B 閘道，以及可在一般區域網路
用戶端和保留路由器設定之間安全切換的 Pi 5。

## 核心特色

- `arm` 會等待網路線斷開後才啟動 DHCP，避免影響現有區域網路。
- 每次變更前都會在 `/var/backups` 建立帶時間戳記的備份。
- NAT、DNS、DHCP、轉送和開機持久化統一設定。
- 下游網路仍可透過 SSH 和 VNC 管理樹莓派。
- 儲存庫中不保存任何 Wi-Fi 密碼。
- 已透過真實下游 DHCP 租約和雙向 NAT 流量驗證。

## 元件

- [`pi4-router`](../pi4-router/)：Pi 4B 的 Wi-Fi 轉 LAN 閘道。
- [`pi5-client`](../pi5-client/)：Pi 5 用戶端／路由器模式切換。

網路切換可能中斷遠端連線，操作前請閱讀[完整英文文件](../README.md)並保留復原路徑。

## 支持專案

| 捐助 | PayPal | Stripe |
| --- | --- | --- |
| [![捐助](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
