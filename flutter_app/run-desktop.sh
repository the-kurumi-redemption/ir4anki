#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="dev.ir4anki.ir4anki_desktop"
BUNDLE_DIR="$SCRIPT_DIR/build/linux/x64/release/bundle"
BIN="$BUNDLE_DIR/ir4anki_desktop"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ir4anki-desktop"
ICON_SVG="$SCRIPT_DIR/linux/assets/${APP_ID}.svg"

export PATH="$HOME/.local/bin:$PATH"

build_release() {
  cd "$SCRIPT_DIR"
  flutter build linux --release
}

install_desktop_app() {
  if [[ "${1:-}" == "--rebuild" || ! -x "$BIN" ]]; then
    build_release
  fi

  # 1. Install self-contained release bundle outside the git build/ folder
  local staging="${INSTALL_DIR}.staging.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -a "$BUNDLE_DIR/." "$staging/"
  rm -rf "$INSTALL_DIR"
  mv "$staging" "$INSTALL_DIR"

  # 2. Install CLI launcher symlink (~/.local/bin/ir4anki)
  mkdir -p "$HOME/.local/bin"
  ln -sf "$INSTALL_DIR/ir4anki_desktop" "$HOME/.local/bin/ir4anki"

  # 3. Install SVG + PNG icons into hicolor theme
  local icon_root="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
  mkdir -p "$icon_root/scalable/apps"
  cp -f "$ICON_SVG" "$icon_root/scalable/apps/${APP_ID}.svg"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ICON_SVG" "$icon_root" "$APP_ID" <<'PY' || true
import os, sys
svg_path, icon_root, app_id = sys.argv[1], sys.argv[2], sys.argv[3]
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf

for size in (48, 64, 128, 256):
    out_dir = os.path.join(icon_root, f"{size}x{size}", "apps")
    os.makedirs(out_dir, exist_ok=True)
    pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(svg_path, size, size, True)
    pb.savev(os.path.join(out_dir, f"{app_id}.png"), "png", [], [])
PY
  fi

  # 4. Install Wayland/KDE-aligned .desktop launcher (matching APPLICATION_ID)
  local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  mkdir -p "$apps_dir"
  rm -f "$apps_dir/ir4anki-desktop.desktop"
  local desktop_file="$apps_dir/${APP_ID}.desktop"
  cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=IR4Anki
GenericName=Incremental Reading for Anki
GenericName[zh_CN]=渐进阅读与 Anki 复习
Comment=Incremental Reading & FSRS Spaced Repetition Desktop App
Comment[zh_CN]=基于渐进阅读与 FSRS 间隔重复的原生桌面学习应用
Exec=$INSTALL_DIR/ir4anki_desktop
Path=$INSTALL_DIR
Icon=$APP_ID
Terminal=false
Categories=Education;
Keywords=anki;reading;flashcards;fsrs;notes;markdown;渐进阅读;复习;笔记;卡片;
StartupNotify=true
StartupWMClass=$APP_ID
SingleMainWindow=true
X-GNOME-SingleWindow=true
EOF
  chmod 644 "$desktop_file"

  # 5. Refresh desktop launcher & icon caches (KDE Plasma / XDG)
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps_dir" || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$icon_root" 2>/dev/null || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental 2>/dev/null || true

  echo "✓ Installed standalone desktop app: $INSTALL_DIR"
  echo "✓ Installed launcher entry:         $desktop_file"
  echo "✓ Installed CLI shortcut:           $HOME/.local/bin/ir4anki"
}

case "${1:-}" in
  --build)
    build_release
    shift || true
    ;;
  --install-desktop|--install-app)
    install_desktop_app "${2:-}"
    exit 0
    ;;
  --help|-h)
    echo "Usage: $0 [--build | --install-app [--rebuild]]"
    echo "  (default)                 Launch standalone IR4Anki Linux desktop app"
    echo "  --build                   Rebuild release bundle then launch"
    echo "  --install-app             Install as a native desktop app in system launcher + ~/.local/bin/ir4anki"
    echo "  --install-app --rebuild   Rebuild release bundle first, then install"
    exit 0
    ;;
esac

if [[ ! -x "$BIN" ]]; then
  echo "Release bundle not found — building standalone Linux desktop binary..."
  build_release
fi

exec "$BIN" "$@"
