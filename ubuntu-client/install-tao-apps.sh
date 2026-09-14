#!/bin/bash
set -euo pipefail

(( EUID != 0 )) || { echo 'Run as the desktop user, not root.' >&2; exit 2; }
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config=${1:-"$source_dir/tao.json"}
for dependency in /usr/local/libexec/astrill-lazy-netns /usr/bin/busybox \
    /usr/bin/google-chrome-stable /usr/bin/python3; do
    [[ -x $dependency ]] || { echo "Missing dependency: $dependency" >&2; exit 1; }
done
[[ -r $config ]] || { echo "Missing profile: $config" >&2; exit 1; }
python3 "$source_dir/wifi2lan-app-network.py" --validate-config "$config"
sudo -n true
sudo -n install -d -m 755 /etc/wifi2lan-apps
sudo -n install -m 644 "$config" /etc/wifi2lan-apps/tao.json
sudo -n install -m 755 "$source_dir/wifi2lan-app-network.py" /usr/local/libexec/wifi2lan-app-network
sudo -n install -m 755 "$source_dir/tao-run" "$source_dir/chrome-tao" /usr/local/bin/
install -d "$HOME/.local/share/applications"
install -m 644 "$source_dir/chrome-tao.desktop" "$HOME/.local/share/applications/chrome-tao.desktop"
desktop=$(xdg-user-dir DESKTOP)
if [[ -d $desktop && $desktop != "$HOME" ]]; then
    install -m 755 "$source_dir/chrome-tao.desktop" "$desktop/Chrome (Tao).desktop"
    gio set "$desktop/Chrome (Tao).desktop" metadata::trusted true || true
fi
sudo -n /usr/local/libexec/wifi2lan-app-network tao
printf 'Installed chrome-tao and tao-run. The system default route was not changed.\n'
