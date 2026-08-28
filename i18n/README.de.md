[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![WIFI2LAN-Banner](../docs/assets/banner.svg)](../docs/assets/banner.svg)

# WIFI2LAN

**Ein robuster WLAN-zu-Ethernet-Gateway für monitorlose Raspberry Pis.**

WIFI2LAN wandelt die WLAN-Verbindung eines Raspberry Pi in einen verwalteten
Ethernet-Uplink um. Das Projekt enthält zwei reproduzierbare und umkehrbare
Konfigurationen: einen Pi-4B-Gateway unter `192.168.13.1` und einen Pi 5, der
sicher zwischen normalem LAN-Client und erhaltener Routerkonfiguration wechselt.

## Eigenschaften

- `arm` wartet auf die Trennung von Ethernet, bevor DHCP gestartet wird.
- Jede Änderung erzeugt eine datierte Sicherung unter `/var/backups`.
- NAT, DNS, DHCP, Weiterleitung und Startpersistenz werden gemeinsam eingerichtet.
- SSH und VNC bleiben aus dem nachgelagerten Netz erreichbar.
- Im Repository werden keine WLAN-Passwörter gespeichert.

## Komponenten

- [`pi4-router`](../pi4-router/): WLAN-zu-LAN-Gateway für den Pi 4B.
- [`pi5-client`](../pi5-client/): Client-/Router-Umschaltung für den Pi 5.

Lesen Sie vor Netzwerkänderungen die [vollständige englische Dokumentation](../README.md),
da der Fernzugriff unterbrochen werden kann.

## Unterstützen

| Spenden | PayPal | Stripe |
| --- | --- | --- |
| [![Spenden](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |
