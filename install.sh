#!/bin/sh
set -eu

DEST="${FIGMENT_INSTALL_DIR:-$HOME/.local/bin}"
DIR="$(cd "$(dirname "$0")" && pwd)"

OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
  echo "figment is macOS-only (needs CGVirtualDisplay), got: $OS" >&2
  exit 1
fi

echo "Building figment..." >&2
make -s -C "$DIR" figment

mkdir -p "$DEST"
install -m 755 "$DIR/figment" "$DEST/figment"
echo "Installed figment to $DEST/figment" >&2

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "Note: $DEST is not in \$PATH. Add it to your shell profile to use figment." >&2 ;;
esac
