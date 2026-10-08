#!/bin/bash
# Build one or more custom VyOS ISO flavors and publish them to the fileserver
# ISO share. See LOCAL_NOTES.md for what each flavor adds.
#
# 'rjn' is our single, batteries-included fleet image: it carries all our
# customizations (ansible user + key, vyos user hash, SSH/NTP/syslog, tshark,
# bpftrace) plus qemu-guest-agent. The guest agent is harmless on bare metal
# (its virtio-serial channel never appears, so the unit stays idle), so we
# deploy one image everywhere instead of maintaining a separate flavor.
#
# Usage:  ./build-and-publish.sh [flavor ...]
#   e.g.  ./build-and-publish.sh                # builds the default flavor (rjn)
#         ./build-and-publish.sh rjn generic    # rjn plus stock upstream generic
#         ./build-and-publish.sh --no-prune     # publish without pruning older ISOs
#
# --no-prune skips the retention step, so every older ISO of the built
# flavor(s) stays in the publish dir (e.g. to keep an extra rollback image).
#
# Run as rnavarro on fileserver.fmt2.crshman.info.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_DIR="/tank/ISOs/Iso"
PUBLISH_URL_BASE="https://fileserver.fmt2.crshman.info/ISOs/Iso"
IMAGE="vyos/vyos-build:rolling"
VERSION="$(date +%Y.%m.%d)-$(date +%H%M)-rolling"
BUILD_BY="rnavarro@crshman.info"
AGE_IDENTITY="${AGE_IDENTITY:-$HOME/.config/vyos-build/age-identity.txt}"
# minisign secret key used to sign published ISOs. The matching public key is
# baked into the image at /usr/share/vyos/keys/rjn.minisign.pub (via
# data/live-build-config/includes.chroot/...), so a router already running an
# rjn image verifies our ISOs cryptographically on `add system image` — no
# "signature not available" prompt. Passwordless (minisign -W) for unattended
# signing; keep it secret and out of git, like the age identity.
SIGN_KEY="${SIGN_KEY:-$HOME/.config/vyos-build/rjn-minisign.key}"

# Flavors to build: CLI args, else the default (our single fleet image).
PRUNE=1
FLAVORS=()
for ARG in "$@"; do
    case "$ARG" in
        --no-prune) PRUNE=0 ;;
        -*) echo "ERROR: unknown option '$ARG'" >&2; exit 1 ;;
        *) FLAVORS+=("$ARG") ;;
    esac
done
if [[ ${#FLAVORS[@]} -eq 0 ]]; then
    FLAVORS=(rjn)
fi

cd "$REPO_DIR"

# Any flavor config decrypted below is plaintext holding secrets (the vyos user
# password hash). Shred every decrypted plaintext on exit so it can never linger
# or be committed (the plaintext paths are gitignored).
DECRYPTED=()
cleanup() { [[ ${#DECRYPTED[@]} -gt 0 ]] && rm -f "${DECRYPTED[@]}"; }
trap cleanup EXIT

# A flavor config lives in git as either plaintext ${flavor}.toml (no secrets,
# e.g. generic) or age-encrypted ${flavor}.toml.age (has secrets, e.g. qemu).
# Decrypt the .age form to the plaintext path the builder reads.
for FLAVOR in "${FLAVORS[@]}"; do
    FLAVOR_CFG="data/build-flavors/${FLAVOR}.toml"
    if [[ -f "${FLAVOR_CFG}.age" ]]; then
        if [[ ! -f "$AGE_IDENTITY" ]]; then
            echo "ERROR: age identity not found at $AGE_IDENTITY" >&2
            echo "       (needed to decrypt ${FLAVOR_CFG}.age; restore it from your secret store)" >&2
            exit 1
        fi
        echo "[$(date +%H:%M:%S)] decrypting $FLAVOR_CFG from ${FLAVOR_CFG}.age"
        age -d -i "$AGE_IDENTITY" -o "$FLAVOR_CFG" "${FLAVOR_CFG}.age"
        DECRYPTED+=("$FLAVOR_CFG")
    elif [[ ! -f "$FLAVOR_CFG" ]]; then
        echo "ERROR: no flavor config for '$FLAVOR' ($FLAVOR_CFG or ${FLAVOR_CFG}.age)" >&2
        exit 1
    fi
done

# Signing prerequisites: fail early rather than after a ~15 min build.
if ! command -v minisign >/dev/null; then
    echo "ERROR: minisign not installed (apt-get install minisign)" >&2
    exit 1
fi
if [[ ! -f "$SIGN_KEY" ]]; then
    echo "ERROR: signing key not found at $SIGN_KEY" >&2
    echo "       (restore it from your secret store, or regenerate with 'minisign -G -W')" >&2
    exit 1
fi

echo "[$(date +%H:%M:%S)] pulling $IMAGE"
docker pull --quiet "$IMAGE" >/dev/null

RESULTS=()
for FLAVOR in "${FLAVORS[@]}"; do
    echo "[$(date +%H:%M:%S)] building $FLAVOR flavor (this takes ~15 min cold, ~10 warm)"
    docker run --rm --privileged \
        -v "$(pwd):/vyos" -w /vyos \
        "$IMAGE" \
        sudo ./build-vyos-image --architecture amd64 --build-by "$BUILD_BY" --version "$VERSION" "$FLAVOR"

    ISO_PATH=$(ls -1t build/vyos-*-${FLAVOR}-amd64.iso 2>/dev/null | head -1)
    if [[ -z "$ISO_PATH" || ! -f "$ISO_PATH" ]]; then
        echo "ERROR: no ISO found in build/ after building $FLAVOR" >&2
        exit 1
    fi
    ISO_NAME=$(basename "$ISO_PATH")

    echo "[$(date +%H:%M:%S)] publishing $ISO_NAME to $PUBLISH_DIR"
    cp --update=none "$ISO_PATH" "$PUBLISH_DIR/$ISO_NAME"

    # Sign the published ISO. The router fetches <url>.minisig automatically on
    # `add system image` and verifies it against the baked-in rjn public key.
    echo "[$(date +%H:%M:%S)] signing $ISO_NAME"
    minisign -S -s "$SIGN_KEY" -m "$PUBLISH_DIR/$ISO_NAME" \
        -c "VyOS $FLAVOR image $VERSION" \
        -t "rjn-built $FLAVOR $VERSION" >/dev/null
    # Sanity: verify the signature we just produced against our public key.
    minisign -V -q -p data/live-build-config/includes.chroot/usr/share/vyos/keys/rjn.minisign.pub \
        -m "$PUBLISH_DIR/$ISO_NAME" >/dev/null

    RESULTS+=("$FLAVOR|$REPO_DIR/$ISO_PATH|$PUBLISH_URL_BASE/$ISO_NAME|$(md5sum "$PUBLISH_DIR/$ISO_NAME" | cut -d" " -f1)")

    # Retention: keep the KEEP most recent ISOs of THIS flavor (current + one
    # prior for rollback), plus their .minisig; prune older ones. Only touches
    # the flavor just built, so other flavors' images (e.g. an old rollback of a
    # retired flavor) stay.
    # Skipped entirely with --no-prune.
    KEEP=2
    if [[ $PRUNE -eq 1 ]]; then
        mapfile -t OLD < <(ls -1t "$PUBLISH_DIR"/vyos-*-${FLAVOR}-amd64.iso 2>/dev/null | tail -n +$((KEEP + 1)))
        for OLD_ISO in "${OLD[@]}"; do
            echo "[$(date +%H:%M:%S)] pruning old $FLAVOR ISO $(basename "$OLD_ISO")"
            rm -f "$OLD_ISO" "$OLD_ISO.minisig"
        done
    else
        echo "[$(date +%H:%M:%S)] --no-prune: keeping all older $FLAVOR ISOs"
    fi
done

echo
echo "Build done."
for R in "${RESULTS[@]}"; do
    IFS='|' read -r FLAVOR LOCAL URL MD5 <<< "$R"
    echo "  [$FLAVOR]"
    echo "    Local: $LOCAL"
    echo "    URL:   $URL"
    echo "    sig:   $URL.minisig"
    echo "    md5:   $MD5"
done
