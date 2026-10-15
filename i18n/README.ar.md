[English](../README.md) · [العربية](README.ar.md) · [Español](README.es.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md) · [中文 (简体)](README.zh-Hans.md) · [中文（繁體）](README.zh-Hant.md) · [Deutsch](README.de.md) · [Русский](README.ru.md)

[![LazyingArt banner — apps and four buddies](https://lazying.art/media/brand/lazyingart-intro.gif)](https://lazying.art)

[![شعار WIFI2LAN](../docs/assets/banner.svg)](../docs/assets/banner.svg)

<div dir="rtl">

# WIFI2LAN

**بوابة موثوقة من Wi-Fi إلى Ethernet لأجهزة Raspberry Pi التي تعمل بلا شاشة.**

يحوّل WIFI2LAN اتصال Wi-Fi في Raspberry Pi إلى اتصال Ethernet مُدار. يحتوي
المشروع على إعدادين قابلين للتكرار والتراجع: بوابة Pi 4B على العنوان
`192.168.13.1`، وPi 5 يمكنه التبديل بأمان بين عميل LAN عادي ووضع الموجّه
المحفوظ.

## المزايا

- ينتظر أمر `arm` فصل كابل Ethernet قبل تشغيل DHCP.
- تُنشأ نسخ احتياطية مؤرخة داخل `/var/backups` قبل كل تغيير.
- يتم إعداد NAT وDNS وDHCP وإعادة التوجيه وخدمة الإقلاع معاً.
- يبقى SSH وVNC متاحين من الشبكة الداخلية.
- لا تُحفظ كلمات مرور Wi-Fi داخل المستودع.

## المكونات

- [`pi4-router`](../pi4-router/): بوابة Wi-Fi إلى LAN لجهاز Pi 4B.
- [`pi5-client`](../pi5-client/): تبديل Pi 5 بين وضع العميل ووضع الموجّه.

راجع [الوثائق الإنجليزية الكاملة](../README.md) قبل تغيير الشبكة، لأن العملية
قد تقطع الوصول البعيد.

## الدعم

<!-- support:start -->
[![GitHub Sponsors](https://img.shields.io/badge/GitHub-Sponsors-EA4AAA?style=for-the-badge&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/lachlanchen)
[![LazyingArt Support](https://img.shields.io/badge/LazyingArt-Support-0EA5E9?style=for-the-badge)](https://chat.lazying.art/donate)
[![PayPal Support](https://img.shields.io/badge/PayPal-Support-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen)
[![Stripe Support](https://img.shields.io/badge/Stripe-Support-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400)
<!-- support:end -->

</div>
