#!/usr/bin/env bash
#
# Hyprland + Caelestia Shell installer for Ubuntu 26.04 LTS (Resolute Raccoon)
#
# Unlike the 25.10 guide, this installs Hyprland itself - 26.04 packages it in
# universe, so no third-party installer is needed.
#
# https://github.com/IshmamDC217/caelestia-shell-ubuntu
#

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}== $* ==${NC}"; }
die()   { err "$@"; exit 1; }

install_m3shapes() {
    local repo="$BUILD_DIR/m3shapes"
    local commit="32ad9ce328bb77ed349b40a3be10ee9ea610b8ab"

    step "Caelestia dependency: M3Shapes"
    if [[ -d "$repo/.git" ]]; then
        git -C "$repo" fetch --tags origin
    else
        git clone https://github.com/soramanew/m3shapes.git "$repo"
    fi

    git -C "$repo" checkout --detach "$commit"
    cmake -S "$repo" -B "$repo/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/ \
        -DCMAKE_CXX_COMPILER=g++ \
        -DINSTALL_QMLDIR=usr/lib/qt6/qml
    cmake --build "$repo/build" --parallel "$(nproc)"
    sudo cmake --install "$repo/build"

    [[ -f /usr/lib/qt6/qml/M3Shapes/qmldir ]] \
        || die "M3Shapes installation did not create its QML module metadata"
    ok "M3Shapes installed at the Caelestia-pinned revision"
}

apply_qt610_compat() {
    local patch="$SCRIPT_DIR/patches/qt6.10-compat.patch"
    local input="$SHELL_DIR/modules/lock/center/InputField.qml"
    local elevation="$SHELL_DIR/components/controls/Elevation.qml"
    local spinbox="$SHELL_DIR/components/controls/DoubleSpinBox.qml"

    step "Qt 6.10 compatibility"
    [[ -f "$patch" ]] || die "Missing compatibility patch: $patch"

    if git -C "$SHELL_DIR" apply --check "$patch" 2>/dev/null; then
        git -C "$SHELL_DIR" apply "$patch"
        ok "Applied the complete Qt 6.10 compatibility patch"
    elif git -C "$SHELL_DIR" apply --reverse --check "$patch" 2>/dev/null; then
        ok "Qt 6.10 compatibility patch already applied"
    else
        warn "Patch context differs from this Caelestia revision; applying known fixes individually."

        # Qt 6.10 reserves 'char' as a QML identifier.
        if [[ -f "$input" ]] && grep -qw 'char' "$input"; then
            sed -i 's/\bchar\b/charItem/g' "$input"
            ok "Updated reserved QML identifier in InputField.qml"
        fi

        # Extract the compatibility shim from the patch's new-file hunk.
        if [[ ! -f "$spinbox" ]]; then
            awk '
                /^\+\+\+ b\/components\/controls\/DoubleSpinBox.qml/ { found=1; next }
                /^diff --git / && found { exit }
                found && /^\+/ { print substr($0, 2) }
            ' "$patch" > "$spinbox"
            [[ -s "$spinbox" ]] || die "Could not extract DoubleSpinBox.qml from patch"
            ok "Installed DoubleSpinBox Qt 6.10 compatibility shim"
        fi

        if [[ -f "$elevation" ]] && ! grep -q 'property real topLeftRadius' "$elevation"; then
            python3 - "$elevation" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
anchor = "property real dp: [0, 1, 3, 6, 8, 12][level]"
addition = """property real topLeftRadius: radius
    property real topRightRadius: radius
    property real bottomLeftRadius: radius
    property real bottomRightRadius: radius"""
if anchor not in s:
    raise SystemExit(f"Expected insertion point not found in {p}; refusing to edit it.")
s = s.replace(anchor, anchor + "\\n\\n    // Ubuntu 26.04 / Qt 6.10 compatibility\\n    " + addition, 1)
p.write_text(s)
PY
            ok "Added Qt 6.10 per-corner radius compatibility properties"
        fi

        [[ -f "$spinbox" ]] || die "DoubleSpinBox.qml is missing after compatibility handling"
        [[ -f "$input" ]] && grep -q 'charItem' "$input" \
            || warn "InputField.qml may need a manual Qt 6.10 identifier review"
        [[ -f "$elevation" ]] || warn "Elevation.qml was not found at the expected path; verify upstream layout."
    fi
}

[[ "$(id -u)" -eq 0 ]] && die "Do not run this script as root."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HOME/caelestia-build"
SHELL_DIR="$HOME/.config/quickshell/caelestia"

# Sanity: this script only claims to work on 26.04.
if ! grep -q 'VERSION_ID="26.04"' /etc/os-release 2>/dev/null; then
    warn "This script targets Ubuntu 26.04. Detected: $(. /etc/os-release; echo "$PRETTY_NAME")"
    read -rp "Continue anyway? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || exit 1
fi

# ---------------------------------------------------------------- Step 1/8 --
step "Step 1/8: Hyprland and desktop components (from apt)"

sudo apt-get update
sudo apt-get install -y \
    hyprland hyprland-protocols hyprland-qtutils hyprwayland-scanner \
    hypridle hyprlock hyprpaper hyprpicker hyprpolkitagent \
    xdg-desktop-portal-hyprland \
    uwsm \
    waybar dunst fuzzel kitty wlogout swayosd nwg-displays nwg-look \
    qt5ct qt6ct pavucontrol papirus-icon-theme \
    hyprland-plugin-hyprexpo

# `hyprland` ships hyprland-uwsm.desktop but neither Depends nor Recommends
# uwsm, so the "Hyprland (uwsm-managed)" session at GDM fails without it.
ok "Hyprland $(Hyprland --version 2>/dev/null | head -1 | awk '{print $2}') installed"

# ---------------------------------------------------------------- Step 2/8 --
step "Step 2/8: Build dependencies"

# Notes on the non-obvious ones:
#   qt6-shadertools-dev      qt6-shader-baker ships the binary but NOT the
#                            CMake config Quickshell needs.
#   qt6-*-private-dev        Debian/Ubuntu split Qt private headers out.
#   libcli11-dev             new Quickshell dependency since the 25.10 guide.
#   libgbm-dev/libegl-dev    Quickshell's Wayland buffer backend.
#   libsensors-dev           lm-sensors is tools only; Caelestia needs the lib.
#   libiniparser-dev + fftw  required by libcava.
sudo apt-get install -y \
    build-essential cmake ninja-build git pkg-config meson \
    qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-wayland-dev qt6-wayland \
    qt6-shader-baker qt6-shadertools-dev libqt6svg6 qt6-image-formats-plugins \
    qt6-base-private-dev qt6-declarative-private-dev qt6-wayland-private-dev \
    libwayland-dev wayland-protocols libjemalloc-dev \
    libpipewire-0.3-dev libxcb1-dev libdrm-dev \
    libcli11-dev libgbm-dev libegl-dev libegl1-mesa-dev \
    libpolkit-agent-1-dev libpolkit-gobject-1-dev libpam0g-dev \
    libsensors-dev libqalculate-dev libaubio-dev \
    libiniparser-dev libfftw3-dev libasound2-dev libpulse-dev \
    python3-pip python3-build python3-hatchling \
    libnotify-bin grim slurp wl-clipboard fish brightnessctl ddcutil \
    lm-sensors swappy unzip wget

ok "Build dependencies installed"

# ---------------------------------------------------------------- Step 3/8 --
step "Step 3/8: Fonts"

# Caelestia needs THREE font families, not just the Nerd Font:
#   Material Symbols Rounded - every icon in the shell. It renders icons from
#     LIGATURES, so without it you see the literal words ("terminal", "web",
#     "calendar_month") spilling out of the bar instead of glyphs.
#   Rubik                    - clock and workspace labels
#   CaskaydiaCove NF         - monospace
# Ubuntu's fonts-material-design-icons-iconfont is the OLDER Material Design
# Icons: different family name, different ligatures. It will not work.

mkdir -p ~/.local/share/fonts
FONT_TMP="$(mktemp -d)"
trap 'rm -rf "$FONT_TMP"' EXIT

if fc-list | grep -qi "CaskaydiaCove"; then
    ok "CascadiaCode Nerd Font already installed"
else
    wget -q --show-progress -O "$FONT_TMP/CascadiaCode.zip" \
        https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/CascadiaCode.zip
    unzip -qo "$FONT_TMP/CascadiaCode.zip" -d "$FONT_TMP/CascadiaCode"
    cp "$FONT_TMP"/CascadiaCode/*.ttf ~/.local/share/fonts/
    ok "CascadiaCode Nerd Font installed"
fi

if fc-list | grep -qi "Material Symbols Rounded"; then
    ok "Material Symbols Rounded already installed"
else
    wget -q --show-progress -O ~/.local/share/fonts/"MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf" \
        "https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
    ok "Material Symbols Rounded installed"
fi

if fc-list | grep -qi "Rubik"; then
    ok "Rubik already installed"
else
    wget -q --show-progress -O ~/.local/share/fonts/"Rubik[wght].ttf" \
        "https://github.com/googlefonts/rubik/raw/main/fonts/variable/Rubik%5Bwght%5D.ttf"
    wget -q --show-progress -O ~/.local/share/fonts/"Rubik-Italic[wght].ttf" \
        "https://github.com/googlefonts/rubik/raw/main/fonts/variable/Rubik-Italic%5Bwght%5D.ttf"
    ok "Rubik installed"
fi

fc-cache -f >/dev/null

for family in "Material Symbols Rounded" "Rubik" "CaskaydiaCove NF"; do
    if fc-match "$family" | grep -qi "$(echo "$family" | tr -d ' ' | cut -c1-6)"; then
        ok "  $family resolves"
    else
        warn "  $family does NOT resolve - icons or text will look wrong"
    fi
done

# ---------------------------------------------------------------- Step 4/8 --
step "Step 4/8: Build Quickshell (not packaged in 26.04)"

mkdir -p "$BUILD_DIR"; cd "$BUILD_DIR"
if [[ -d quickshell ]]; then
    cd quickshell && git pull --ff-only || true
else
    git clone https://git.outfoxxed.me/quickshell/quickshell.git && cd quickshell
fi

# Upstream renamed CRASH_REPORTER -> CRASH_HANDLER. The old name is silently
# ignored by cmake, which then fails looking for cpptrace (not packaged).
cmake -GNinja -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCRASH_HANDLER=OFF \
    -DINSTALL_QML_PREFIX=lib/qt6/qml

cmake --build build
sudo cmake --install build
ok "Quickshell $(quickshell --version 2>/dev/null | awk '{print $2}') installed"

# ---------------------------------------------------------------- Step 5/8 --
step "Step 5/8: Build libcava (LukashonakV fork)"

# Ubuntu's `cava` package is karlstav's console visualiser and ships no shared
# library, so this fork is still required.
cd "$BUILD_DIR"
if [[ -d libcava ]]; then
    cd libcava && git pull --ff-only || true
else
    git clone https://github.com/LukashonakV/cava.git libcava && cd libcava
fi

meson setup build --buildtype=release -Ddefault_library=shared --wipe 2>/dev/null \
    || meson setup build --buildtype=release -Ddefault_library=shared
meson compile -C build
sudo meson install -C build

echo "/usr/local/lib/x86_64-linux-gnu" | sudo tee /etc/ld.so.conf.d/libcava.conf >/dev/null
sudo ldconfig
ok "libcava installed"

# ---------------------------------------------------------------- Step 6/8 --
step "Step 6/8: Caelestia CLI"

cd "$BUILD_DIR"
if [[ -d caelestia-cli ]]; then
    cd caelestia-cli && git pull --ff-only || true
else
    git clone https://github.com/caelestia-dots/cli.git caelestia-cli && cd caelestia-cli
fi

python3 -m build --wheel
# Note: this replaces the system `pillow` with a newer wheel.
sudo pip3 install dist/*.whl --break-system-packages --force-reinstall
ok "Caelestia CLI installed"

# ---------------------------------------------------------------- Step 7/8 --
step "Step 7/8: Caelestia dependencies and Shell (+ Qt 6.10 compatibility)"

install_m3shapes

mkdir -p ~/.config/quickshell
if [[ -d "$SHELL_DIR/.git" ]]; then
    cd "$SHELL_DIR" && git pull --ff-only || true
else
    # Full clone: a shallow one has no tags, and the build reads VERSION from
    # `git describe`, failing with "VERSION is not set and failed to get from git".
    git clone https://github.com/caelestia-dots/shell.git "$SHELL_DIR"
    cd "$SHELL_DIR"
fi

# Ubuntu 26.04 ships Qt 6.10.2; apply compatibility fixes idempotently.
apply_qt610_compat


PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}" \
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/
cmake --build build
sudo cmake --install build
ok "Caelestia Shell installed"

# ---------------------------------------------------------------- Step 8/8 --
step "Step 8/8: Configuration"

if ! grep -q 'QML_IMPORT_PATH=/usr/lib/qt6/qml' ~/.bashrc 2>/dev/null; then
    echo 'export QML_IMPORT_PATH=/usr/lib/qt6/qml' >> ~/.bashrc
    ok "Added QML_IMPORT_PATH to ~/.bashrc"
fi

mkdir -p ~/.config/caelestia ~/.config/hypr ~/Pictures/Wallpapers

install_config() {
    local src="$1" dst="$2"
    if [[ -e "$dst" ]]; then
        warn "$dst exists, leaving it alone"
    else
        cp "$src" "$dst" && ok "Installed $dst"
    fi
}

install_config "$SCRIPT_DIR/config/26.04/shell.json"  ~/.config/caelestia/shell.json
install_config "$SCRIPT_DIR/config/26.04/quickshell/qml_color.json" ~/.config/quickshell/qml_color.json
install_config "$SCRIPT_DIR/config/26.04/hyprland.conf" ~/.config/hypr/hyprland.conf

# Qt apps under Hyprland do NOT inherit GNOME's icon theme. Without this every
# QIcon::fromTheme lookup falls through to hicolor and the shell logs
# "Could not load icon ..." with blank tray/status icons.
mkdir -p ~/.config/qt6ct
install_config "$SCRIPT_DIR/config/26.04/qt6ct/qt6ct.conf" ~/.config/qt6ct/qt6ct.conf

# Supervise the shell. Upstream's `exec-once = caelestia shell -d` runs once at
# login, so a crash leaves no bar until it is relaunched by hand.
mkdir -p ~/.config/systemd/user
install_config "$SCRIPT_DIR/config/26.04/systemd/caelestia-shell.service" \
    ~/.config/systemd/user/caelestia-shell.service
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable caelestia-shell.service 2>/dev/null \
    && ok "Shell supervised by systemd (auto-restarts on crash)" \
    || warn "Could not enable caelestia-shell.service"

# The laptop backlight node is root:video (0664). Give the installing user
# access so Quickshell can adjust brightness without running as root.
if getent group video >/dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx video; then
        ok "User $USER already belongs to the video group"
    else
        sudo usermod -aG video "$USER"
        warn "Added $USER to the video group. A complete logout/login is required."
    fi
else
    warn "The video group does not exist; brightness permissions may need platform-specific setup."
fi

# Verify the key QML module metadata exists after installation.
[[ -f /usr/lib/qt6/qml/M3Shapes/qmldir ]] \
    || die "M3Shapes QML module is missing after installation."

if Hyprland --verify-config 2>&1 | grep -q "config ok"; then
    ok "Hyprland config verified"
else
    warn "Hyprland reported config errors; run: Hyprland --verify-config"
fi

echo ""
echo -e "${GREEN}${BOLD}=========================================================${NC}"
echo -e "${GREEN}${BOLD}  Done. Log out and pick 'Hyprland' at the login screen.${NC}"
echo -e "${GREEN}${BOLD}=========================================================${NC}"
echo ""
echo -e "  Start the shell manually:  ${CYAN}caelestia shell -d${NC}"
echo -e "  Already autostarted via    ${BOLD}exec-once${NC} in hyprland.conf"
echo -e "  Wallpapers:                ${BOLD}~/Pictures/Wallpapers/${NC}"
echo -e "  Shell config:              ${BOLD}~/.config/caelestia/shell.json${NC}"
echo ""
