#!/bin/sh
set -eu

REPO="algedonia/algedonia"
BIN="ag"

fail() {
  echo "Error: $*" 1>&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

os=$(uname -s)
arch=$(uname -m)

case "$os" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  *) fail "Unsupported OS: $os" ;;
esac

case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) fail "Unsupported arch: $arch" ;;
esac

if have curl; then
  fetch() { curl -fsSL "$1"; }
elif have wget; then
  fetch() { wget -qO- "$1"; }
else
  fail "curl or wget is required"
fi

tag=$(fetch "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -n 1)

[ -n "$tag" ] || fail "Unable to determine latest release tag"
version=${tag#v}

archive="${BIN}_${version}_${os}_${arch}.tar.gz"
checksums="checksums.txt"
base_url="https://github.com/$REPO/releases/download/$tag"

tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fetch "$base_url/$archive" > "$tmpdir/$archive"
fetch "$base_url/$checksums" > "$tmpdir/$checksums"

expected=$(awk -v file="$archive" '$2==file {print $1}' "$tmpdir/$checksums")
[ -n "$expected" ] || fail "Checksum not found for $archive"

if have shasum; then
  actual=$(shasum -a 256 "$tmpdir/$archive" | awk '{print $1}')
elif have sha256sum; then
  actual=$(sha256sum "$tmpdir/$archive" | awk '{print $1}')
else
  fail "shasum or sha256sum is required for checksum verification"
fi

[ "$expected" = "$actual" ] || fail "Checksum mismatch"

( cd "$tmpdir" && tar -xzf "$archive" )

src=""
if [ -f "$tmpdir/$BIN" ]; then
  src="$tmpdir/$BIN"
else
  src=$(find "$tmpdir" -maxdepth 2 -type f -name "$BIN" | head -n 1)
fi

[ -n "$src" ] || fail "Binary not found in archive"

install_dir="/usr/local/bin"
if [ "$(id -u)" -ne 0 ] && [ ! -w "$install_dir" ]; then
  install_dir="$HOME/.local/bin"
fi

mkdir -p "$install_dir"
install_path="$install_dir/$BIN"

if have install; then
  install -m 0755 "$src" "$install_path"
else
  cp "$src" "$install_path"
  chmod 0755 "$install_path"
fi

echo "Installed $BIN to $install_path"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    echo "Note: $install_dir is not in your PATH."
    echo "Add it to your shell profile to use '$BIN' without a full path."
    ;;
esac

config="$HOME/.config/ag/config.json"
if [ ! -f "$config" ]; then
  echo "Config not found at $config."
  echo "Run '$BIN login' to create it, then re-run this installer to enable auto-start."
  exit 0
fi

if [ "$os" = "darwin" ]; then
  plist="$HOME/Library/LaunchAgents/com.algedonia.ag.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.algedonia.ag</string>
  <key>ProgramArguments</key>
  <array>
    <string>$install_path</string>
    <string>connect</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
PLIST
  if have launchctl; then
    launchctl load "$plist"
    echo "LaunchAgent installed and loaded."
  else
    echo "launchctl not found; install the LaunchAgent manually at $plist."
  fi
elif [ "$os" = "linux" ]; then
  unit="$HOME/.config/systemd/user/ag.service"
  mkdir -p "$(dirname "$unit")"
  cat > "$unit" <<UNIT
[Unit]
Description=Algedonia daemon agent

[Service]
ExecStart=$install_path connect
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT
  if have systemctl; then
    systemctl --user daemon-reload
    systemctl --user enable --now ag
    echo "Systemd user service installed and started."
  else
    echo "systemctl not found; install the systemd unit manually at $unit."
  fi
fi
