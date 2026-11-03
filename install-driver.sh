#!/bin/zsh
# Installs (or with --uninstall removes) the Audio Router virtual device. Run with sudo.
set -euo pipefail
cd "$(dirname "$0")"
DEST=/Library/Audio/Plug-Ins/HAL/AudioRouterDriver.driver
rm -rf "$DEST"
if [[ "${1:-}" != "--uninstall" ]]; then
    cp -R build.nosync/AudioRouterDriver.driver "$DEST"
    chown -R root:wheel "$DEST"
fi
killall coreaudiod   # launchd restarts it and (un)loads the driver
echo done
