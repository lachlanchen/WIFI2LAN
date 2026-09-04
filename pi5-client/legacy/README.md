# Archived static-router implementation

This directory preserves the earlier working implementation that combined
ifupdown, a global dnsmasq service, persistent iptables rules, and a boot-time
oneshot repair service.

It is retained for reference and rollback archaeology. New Raspberry Pi OS and
Debian Bookworm installations should use the single NetworkManager shared
profile in the parent directory.

The deployed script captured on 2026-09-04 had SHA-256
`d0092333f7b1a59ce5f00c83a6895c06270f30c32b4011a746471e21052abe5f`.
The repository copy replaces only its device-specific default Wi-Fi profile
name with `upstream-wifi`; no password or Wi-Fi credential is archived.

The matching service template deliberately uses an environment placeholder.

The still earlier `bridge.sh` and its start/stop unit templates are also kept
here because they explained a reboot-only regression during migration. They
must not be enabled: the script performs package installation, rewrites network
files, and appends firewall rules on every invocation.
