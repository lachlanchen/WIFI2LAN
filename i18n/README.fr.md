[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![Bannière WIFI2LAN](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**Une passerelle Wi-Fi vers Ethernet fiable pour Raspberry Pi sans écran.**

WIFI2LAN transforme la connexion Wi-Fi d'un Raspberry Pi en liaison Ethernet
gérée. Le projet fournit deux configurations reproductibles et réversibles :
une passerelle Pi 4B sur `192.168.13.1` et un Pi 5 pouvant basculer en sécurité
entre client LAN normal et configuration routeur conservée.

## Points forts

- `arm` attend la déconnexion Ethernet avant de démarrer DHCP.
- Chaque changement crée une sauvegarde horodatée dans `/var/backups`.
- NAT, DNS, DHCP, routage et persistance au démarrage sont configurés ensemble.
- SSH et VNC restent accessibles depuis le réseau aval.
- Aucun mot de passe Wi-Fi n'est stocké dans le dépôt.

## Composants

- [`pi4-router`](../pi4-router/) : passerelle Wi-Fi vers LAN pour Pi 4B.
- [`pi5-client`](../pi5-client/) : bascule client/routeur pour Pi 5.

Consultez la [documentation anglaise complète](../README.md) avant toute
modification réseau, car l'accès distant peut être interrompu.

## Soutenir le projet

| Faire un don | PayPal | Stripe |
| --- | --- | --- |
| [![Don](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
