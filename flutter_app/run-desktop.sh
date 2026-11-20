#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/build/linux/x64/release/bundle"
BIN="$BUNDLE_DIR/ir4anki_desktop"

export PATH="$HOME/.local/bin:$PATH"

case "${1:-}" in
  --build)
    cd "$SCRIPT_DIR"
    flutter build linux --release
    shift || true
    ;;
  --install-desktop)
    if [[ ! -x "$BIN" ]]; then
      cd "$SCRIPT_DIR"
      flutter build linux --release
    fi
    DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$DESKTOP_DIR"
    DESKTOP_FILE="$DESKTOP_DIR/ir4anki-desktop.desktop"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=IR4Anki
Comment=Incremental Reading for Anki (Material Design 3 Expressive Native Desktop)
Exec=$BIN
Path=$BUNDLE_DIR
Terminal=false
Categories=Education;Office;Utility;
StartupWMClass=ir4anki_desktop
EOF
    chmod 644 "$DESKTOP_FILE"
    echo "Installed desktop launcher: $DESKTOP_FILE"
    exit 0
    ;;
  --help|-h)
    echo "Usage: $0 [--build | --install-desktop]"
    echo "  (default)          Launch standalone IR4Anki Linux desktop app (builds if missing)"
    echo "  --build            Rebuild release bundle then launch"
    echo "  --install-desktop  Install ~/.local/share/applications/ir4anki-desktop.desktop"
    exit 0
    ;;
esac

if [[ ! -x "$BIN" ]]; then
  echo "Release bundle not found — building standalone Linux desktop binary..."
  cd "$SCRIPT_DIR"
  flutter build linux --release
fi

exec "$BIN" "$@"
