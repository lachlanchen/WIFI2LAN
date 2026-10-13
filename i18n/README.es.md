[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner](https://github.com/lachlanchen/lachlanchen/raw/main/figs/banner.png)](https://lazying.art)

[![Banner de WIFI2LAN](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**Una puerta de enlace Wi-Fi a Ethernet resistente para Raspberry Pi sin monitor.**

WIFI2LAN convierte la conexión Wi-Fi de una Raspberry Pi en una salida Ethernet
gestionada. Incluye dos configuraciones reproducibles y reversibles: una puerta
de enlace Pi 4B en `192.168.13.1` y una Pi 5 que puede alternar con seguridad
entre cliente LAN normal y su configuración de router conservada.

## Puntos clave

- `arm` espera a que se desconecte Ethernet antes de iniciar DHCP.
- Cada cambio crea una copia fechada en `/var/backups`.
- NAT, DNS, DHCP, reenvío y persistencia al arranque se configuran juntos.
- SSH y VNC siguen disponibles desde la red descendente.
- El repositorio no almacena contraseñas Wi-Fi.

## Componentes

- [`pi4-router`](../pi4-router/): puerta de enlace Wi-Fi a LAN para Pi 4B.
- [`pi5-client`](../pi5-client/): cambio de modo cliente/router para Pi 5.

Lee la [documentación completa en inglés](../README.md) antes de cambiar la red,
ya que la operación puede interrumpir el acceso remoto.

## Apoyo

| Donar | PayPal | Stripe |
| --- | --- | --- |
| [![Donar](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
