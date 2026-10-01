#!/bin/sh
#
# build-deb.sh — package an already-built Origin.app plus origin-helper into a
# jailbreak .deb.
#
# Usage:
#   Packaging/build-deb.sh --app <Origin.app> --helper <origin-helper> \
#                          [--rootless|--rootful] [--output dist]
#
# The script never builds anything: it takes the bundle `xcodebuild` produced and
# the helper `clang` produced (see .github/workflows/app-build.yml), and turns
# them into something Sileo, Zebra or `dpkg -i` can install.
set -eu

PROG_NAME=$(basename -- "$0")

die() {
    printf '%s: error: %s\n' "$PROG_NAME" "$1" >&2
    exit 1
}

note() {
    printf '%s: %s\n' "$PROG_NAME" "$1" >&2
}

usage() {
    cat <<'USAGE'
Usage: build-deb.sh --app <Origin.app> --helper <origin-helper> [options]

  --app <path>      the .app bundle built by xcodebuild (or APP_PATH=)
  --helper <path>   the compiled origin-helper binary (or HELPER_PATH=)
  --rootless        install to /var/jb/Applications (default, iphoneos-arm64)
  --rootful         install to /Applications      (iphoneos-arm)
  --print-layout    print the file list the package would contain, then exit
  --version <v>     version for the control file (default: from Info.plist)
  --output <dir>    where to write the .deb (default: ./dist)
  -h, --help        this text
USAGE
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

APP_PATH=${APP_PATH:-}
HELPER_PATH=${HELPER_PATH:-}
LAYOUT=rootless
PRINT_LAYOUT=0
VERSION=
OUTPUT_DIR=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)          [ "$#" -ge 2 ] || die "--app needs a value"; APP_PATH=$2; shift ;;
        --app=*)        APP_PATH=${1#--app=} ;;
        --helper)       [ "$#" -ge 2 ] || die "--helper needs a value"; HELPER_PATH=$2; shift ;;
        --helper=*)     HELPER_PATH=${1#--helper=} ;;
        --rootless)     LAYOUT=rootless ;;
        --rootful)      LAYOUT=rootful ;;
        --print-layout) PRINT_LAYOUT=1 ;;
        --version)      [ "$#" -ge 2 ] || die "--version needs a value"; VERSION=$2; shift ;;
        --version=*)    VERSION=${1#--version=} ;;
        --output)       [ "$#" -ge 2 ] || die "--output needs a value"; OUTPUT_DIR=$2; shift ;;
        --output=*)     OUTPUT_DIR=${1#--output=} ;;
        -h|--help)      usage; exit 0 ;;
        -*)             die "unknown option: $1 (try --help)" ;;
        *)              die "unexpected argument: $1" ;;
    esac
    shift
done

[ -n "$APP_PATH" ] || die "no app bundle given; pass --app <Origin.app>"
[ -n "$HELPER_PATH" ] || die "no helper given; pass --helper <origin-helper>"

case "$LAYOUT" in
    rootless)
        DEB_ARCH=iphoneos-arm64
        INSTALL_PREFIX=var/jb
        ;;
    rootful)
        DEB_ARCH=iphoneos-arm
        INSTALL_PREFIX=
        ;;
    *)
        die "internal error: unknown layout '$LAYOUT'"
        ;;
esac

APP_REL="${INSTALL_PREFIX:+$INSTALL_PREFIX/}Applications/Origin.app"
HELPER_REL="${INSTALL_PREFIX:+$INSTALL_PREFIX/}usr/libexec/origin/origin-helper"

[ -d "$APP_PATH" ] || die "app bundle not found at '$APP_PATH'"
[ -f "$APP_PATH/Info.plist" ] || die "'$APP_PATH' does not look like an app bundle"
[ -f "$APP_PATH/Origin" ] || die "'$APP_PATH/Origin' is missing; the package must contain Applications/Origin.app/Origin"
[ -x "$APP_PATH/Origin" ] || die "'$APP_PATH/Origin' is not executable"
[ -f "$HELPER_PATH" ] || die "helper not found at '$HELPER_PATH'"

CONTROL_TEMPLATE="$REPO_ROOT/Packaging/control.template"
[ -f "$CONTROL_TEMPLATE" ] || die "control template not found at '$CONTROL_TEMPLATE'"

if [ -z "$VERSION" ]; then
    VERSION=1.0.0
    if command -v plutil >/dev/null 2>&1; then
        from_plist=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Info.plist" 2>/dev/null || true)
        if [ -n "$from_plist" ]; then
            VERSION=$from_plist
        fi
    fi
fi
VERSION_SAFE=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9.+~' '-')
[ -n "$VERSION_SAFE" ] || die "could not derive a file-name-safe version from '$VERSION'"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$REPO_ROOT/dist"
fi
DEB_NAME="origin_${VERSION_SAFE}_${DEB_ARCH}.deb"

if [ "$PRINT_LAYOUT" != "0" ]; then
    printf './DEBIAN/control\n'
    printf './DEBIAN/postinst\n'
    printf './DEBIAN/postrm\n'
    printf './%s\n' "$(dirname "$APP_REL")"
    (
        cd "$APP_PATH" || exit 1
        find . ! -name . -print
    ) | sed -e 's|^\./||' -e "s|^|./$APP_REL/|"
    printf './%s\n' "$(dirname "$HELPER_REL")"
    printf './%s\n' "$HELPER_REL"
    printf '\n# layout: %s   architecture: %s   version: %s\n' "$LAYOUT" "$DEB_ARCH" "$VERSION" >&2
    printf '# target: %s\n' "$DEB_NAME" >&2
    exit 0
fi

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is not installed; on macOS: brew install dpkg"

supports_flag() {
    help_text=$(dpkg-deb --help 2>&1 || true)
    case "$help_text" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/origin-deb.XXXXXX") || die "could not create a temporary directory"
# shellcheck disable=SC2064
trap "rm -rf '$STAGE'" EXIT INT TERM

mkdir -p "$STAGE/DEBIAN"
mkdir -p "$STAGE/$APP_REL"
mkdir -p "$STAGE/$(dirname "$HELPER_REL")"

note "staging $LAYOUT package in $STAGE"

# `cp -R` keeps symbolic links as links on both BSD and GNU cp, which matters:
# dereferencing a framework symlink would duplicate megabytes.
cp -R "$APP_PATH/." "$STAGE/$APP_REL/"
cp "$HELPER_PATH" "$STAGE/$HELPER_REL"

# macOS leaves quarantine xattrs and AppleDouble `._*` files on anything it did
# not create; both would end up inside the package and confuse dpkg.
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGE/$APP_REL" 2>/dev/null || note "could not clear extended attributes (continuing)"
fi
find "$STAGE/$APP_REL" -name '._*' -type f -exec rm -f {} \; 2>/dev/null || true

control_version=$(printf '%s' "$VERSION" | sed -e 's/[\\&|]/\\&/g')
control_arch=$(printf '%s' "$DEB_ARCH" | sed -e 's/[\\&|]/\\&/g')
sed -e "s|@VERSION@|$control_version|g" -e "s|@ARCH@|$control_arch|g" \
    "$CONTROL_TEMPLATE" > "$STAGE/DEBIAN/control"

case "$(cat "$STAGE/DEBIAN/control")" in
    *@VERSION@*|*@ARCH@*) die "control template still contains placeholders" ;;
esac

installed_size=$(du -sk "$STAGE/$APP_REL" "$STAGE/$(dirname "$HELPER_REL")" | awk '{ total += $1 } END { print total }')
printf 'Installed-Size: %s\n' "$installed_size" >> "$STAGE/DEBIAN/control"

for script in postinst postrm; do
    cp "$REPO_ROOT/Packaging/$script" "$STAGE/DEBIAN/$script"
    chmod 0755 "$STAGE/DEBIAN/$script"
done

# Signing. The signature covers the whole Mach-O, so it has to be written after
# every byte of the binary is final — after the copy, the xattr cleanup and the
# permissions below. Nothing may touch the app after this block.
ENTITLEMENTS="$REPO_ROOT/App/Origin.entitlements"
if command -v ldid >/dev/null 2>&1; then
    rm -rf "$STAGE/$APP_REL/_CodeSignature"
    if [ -f "$ENTITLEMENTS" ]; then
        ldid -S"$ENTITLEMENTS" "$STAGE/$APP_REL/Origin" || die "ldid failed to sign the app"
        note "signed Origin with $(basename -- "$ENTITLEMENTS")"
    else
        note "warning: $ENTITLEMENTS not found; signing the app without entitlements"
        ldid -S "$STAGE/$APP_REL/Origin" || die "ldid failed to sign the app"
    fi
    # The helper is a plain executable: the platform entitlements belong to the
    # app, and the setuid bit comes from the postinst.
    rm -f "$STAGE/$HELPER_REL"
    cp "$HELPER_PATH" "$STAGE/$HELPER_REL"
    ldid -S "$STAGE/$HELPER_REL" || die "ldid failed to sign origin-helper"
else
    note "warning: ldid not found; shipping unsigned binaries"
fi

find "$STAGE/$APP_REL" -type d -exec chmod 0755 {} \;
find "$STAGE/$APP_REL" -type f -perm -u+x -exec chmod 0755 {} \;
find "$STAGE/$APP_REL" -type f ! -perm -u+x -exec chmod 0644 {} \;
chmod 0755 "$STAGE/$APP_REL"
# Setuid root, and set it here as well as in the postinst so a plain
# `dpkg -x` produces a usable helper too.
chmod 4755 "$STAGE/$HELPER_REL"
chmod 0755 "$STAGE" "$STAGE/DEBIAN"
chmod 0644 "$STAGE/DEBIAN/control"

if [ "$(id -u)" = "0" ]; then
    chown -R 0:0 "$STAGE" || note "warning: chown failed"
else
    note "not running as root: relying on dpkg-deb --root-owner-group"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH='' cd -- "$OUTPUT_DIR" && pwd)
DEB_PATH="$OUTPUT_DIR/$DEB_NAME"

set -- --build
if supports_flag 'root-owner-group'; then
    set -- "$@" --root-owner-group
fi
if supports_flag -Z; then
    # gzip is the compressor every jailbreak dpkg can read.
    set -- "$@" -Zgzip
fi

note "building $DEB_PATH"
dpkg-deb "$@" "$STAGE" "$DEB_PATH" || die "dpkg-deb failed"
[ -s "$DEB_PATH" ] || die "dpkg-deb produced no package"

printf '%s\n' "$DEB_PATH"
note "done: $(du -h "$DEB_PATH" | awk '{ print $1 }') $DEB_NAME"
