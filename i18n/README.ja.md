[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner — apps and four buddies](https://lazying.art/media/brand/lazyingart-intro.gif)](https://lazying.art)

[![WIFI2LAN バナー](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**ヘッドレス Raspberry Pi のための、堅牢な Wi-Fi → Ethernet ゲートウェイ。**

WIFI2LAN は Raspberry Pi の Wi-Fi 接続を管理された Ethernet 回線へ変換します。
`192.168.13.1` で動作する Pi 4B ゲートウェイと、通常の LAN クライアント／保存済み
ルータ構成を安全に切り替えられる Pi 5 の、再現可能で元に戻せる二つの構成を収録しています。

## 特長

- `arm` は Ethernet が切断されてから DHCP を開始します。
- 変更前に `/var/backups` へ時刻付きバックアップを作成します。
- NAT、DNS、DHCP、転送、起動時の永続化をまとめて設定します。
- 下流ネットワークから SSH と VNC を引き続き利用できます。
- Wi-Fi パスワードをリポジトリへ保存しません。

## 構成

- [`pi4-router`](../pi4-router/)：Pi 4B 用 Wi-Fi → LAN ゲートウェイ。
- [`pi5-client`](../pi5-client/)：Pi 5 用クライアント／ルータモード切替。

ネットワーク変更はリモート接続を中断する可能性があります。実行前に
[英語版の完全なドキュメント](../README.md)を確認してください。

## サポート

| 寄付 | PayPal | Stripe |
| --- | --- | --- |
| [![寄付](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
