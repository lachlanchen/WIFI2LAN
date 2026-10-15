[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner — apps and four buddies](https://lazying.art/media/brand/lazyingart-intro.gif)](https://lazying.art)

[![WIFI2LAN 배너](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**화면 없는 Raspberry Pi를 위한 안정적인 Wi-Fi → Ethernet 게이트웨이.**

WIFI2LAN은 Raspberry Pi의 Wi-Fi 연결을 관리되는 Ethernet 업링크로 바꿉니다.
`192.168.13.1`의 Pi 4B 게이트웨이와 일반 LAN 클라이언트/보존된 라우터 구성을
안전하게 전환하는 Pi 5, 두 가지 재현 가능하고 되돌릴 수 있는 구성을 제공합니다.

## 핵심 기능

- `arm`은 Ethernet 연결이 끊어진 뒤에만 DHCP를 시작합니다.
- 변경할 때마다 `/var/backups`에 시간 표시 백업을 만듭니다.
- NAT, DNS, DHCP, 포워딩, 부팅 지속성을 함께 구성합니다.
- 다운스트림 네트워크에서 SSH와 VNC를 계속 사용할 수 있습니다.
- Wi-Fi 암호를 저장소에 보관하지 않습니다.

## 구성 요소

- [`pi4-router`](../pi4-router/): Pi 4B용 Wi-Fi → LAN 게이트웨이.
- [`pi5-client`](../pi5-client/): Pi 5용 클라이언트/라우터 모드 전환.

네트워크 변경으로 원격 연결이 끊길 수 있으므로 실행 전에
[전체 영문 문서](../README.md)를 읽어 주세요.

## 후원

<!-- support:start -->
[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/lachlanchen)
[![LazyingArt Support](https://img.shields.io/badge/LazyingArt-Support-0EA5E9?style=for-the-badge)](https://chat.lazying.art/donate)
[![PayPal Support](https://img.shields.io/badge/PayPal-Support-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen)
[![Stripe Support](https://img.shields.io/badge/Stripe-Support-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400)
<!-- support:end -->
