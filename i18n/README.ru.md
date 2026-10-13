[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner](https://github.com/lachlanchen/lachlanchen/raw/main/figs/banner.png)](https://lazying.art)

[![Баннер WIFI2LAN](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**Надёжный шлюз Wi-Fi → Ethernet для Raspberry Pi без монитора.**

WIFI2LAN превращает Wi-Fi-соединение Raspberry Pi в управляемый Ethernet-канал.
Проект содержит две воспроизводимые и обратимые конфигурации: шлюз Pi 4B по
адресу `192.168.13.1` и Pi 5, безопасно переключаемый между обычным LAN-клиентом
и сохранённой конфигурацией маршрутизатора.

## Особенности

- `arm` ждёт отключения Ethernet и только затем запускает DHCP.
- Перед каждым изменением создаётся резервная копия в `/var/backups`.
- NAT, DNS, DHCP, пересылка и автозапуск настраиваются совместно.
- SSH и VNC остаются доступны из нижестоящей сети.
- Пароли Wi-Fi не хранятся в репозитории.

## Компоненты

- [`pi4-router`](../pi4-router/): шлюз Wi-Fi → LAN для Pi 4B.
- [`pi5-client`](../pi5-client/): переключение клиент/маршрутизатор для Pi 5.

Перед изменением сети прочитайте [полную документацию на английском](../README.md):
операция может прервать удалённый доступ.

## Поддержать проект

| Пожертвование | PayPal | Stripe |
| --- | --- | --- |
| [![Пожертвовать](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
