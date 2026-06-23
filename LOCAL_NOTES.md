# Local notes for this vyos-build checkout

This is our fork `rnavarro/vyos-build` (forked from `vyos/vyos-build`). Our
homelab customizations live on the **`homelab`** branch, kept separate from the
upstream branches so we can sync cleanly.

Remotes:
- `origin`   → https://github.com/rnavarro/vyos-build.git (our fork)
- `upstream` → https://github.com/vyos/vyos-build.git (the official repo)

Upstream renamed the rolling-release dev branch `current` → `rolling`
(VyOS task T8943); `current` is frozen, so we track **`rolling`**. The build
uses the matching `vyos/vyos-build:rolling` container.

Sync upstream into our branch:
```
git fetch upstream
git checkout rolling && git merge --ff-only upstream/rolling
git checkout homelab && git rebase rolling   # or merge
```

## What was added
A single custom `rjn` build flavor (`data/build-flavors/rjn.toml`) — our
batteries-included fleet image, deployed on **every** router (KVM/Proxmox and
bare metal alike). It:
- sets `image_format = "iso"`
- installs `tshark` and `bpftrace` (network/kernel observability) plus
  `qemu-guest-agent` (Proxmox/KVM graceful shutdown, reboot, fstrim)
- ships a `default_config` defining the `ansible` user (ed25519 key
  `ansible@rjn_ansible_routers`) and the `vyos` user.

Why one image everywhere: `qemu-guest-agent` is harmless on bare metal — it
talks to the host over a virtio-serial channel that never appears off a KVM
host, so the systemd unit is device-activated and simply never starts (no CPU,
no memory, no network listener). Carrying it fleet-wide beats maintaining a
second flavor and the config drift that comes with it.

⚠️ `default_config` becomes `/opt/vyatta/etc/config.boot.default`, which only
applies on **fresh install / reset system config** — never on in-place image
upgrades. Routers upgraded in place keep their existing `/config/config.boot`.

`build-and-publish.sh` builds the `rjn` ISO inside the upstream vyos-build
container and copies the result to `/tank/ISOs/Iso/` so VyOS routers can pull it
via the upgrade workflow. The stock upstream `generic` flavor is still present
and can be built on demand (`./build-and-publish.sh rjn generic`), but is not
built by default.

## ISO retention
`/tank/ISOs/Iso/` keeps the **2 most recent ISOs per flavor** (current + one
prior for rollback); older ones are pruned after a successful publish.

## Secrets (age encryption)
`rjn.toml` carries the `vyos` user's password hash, so it is **never committed
in plaintext** — the fork is public. Git tracks only the encrypted
`data/build-flavors/rjn.toml.age`; the plaintext path is gitignored.

- Identity (private key): `~/.config/vyos-build/age-identity.txt` (chmod 600).
  **Not in git** — back it up to your secret store; without it you cannot
  decrypt or build.
- Recipient (public key):
  `age1h5yqn8qc35jd04k0htg3dj59828hqc2gwgl99s36ede6mlsmpunsd4kjl0`

`build-and-publish.sh` decrypts the config at the start of every build and
shreds the plaintext on exit. To edit the flavor config:
```
age -d -i ~/.config/vyos-build/age-identity.txt \
    -o data/build-flavors/rjn.toml data/build-flavors/rjn.toml.age
$EDITOR data/build-flavors/rjn.toml
age -r age1h5yqn8qc35jd04k0htg3dj59828hqc2gwgl99s36ede6mlsmpunsd4kjl0 -a \
    -o data/build-flavors/rjn.toml.age data/build-flavors/rjn.toml
git add data/build-flavors/rjn.toml.age   # commit the .age, never the plaintext
```

## Build + publish (normal case)
```
./build-and-publish.sh
```
The script pulls `vyos/vyos-build:rolling`, runs the build (~15 min cold,
~10 min warm), then copies `build/vyos-*-rjn-amd64.iso` to
`/tank/ISOs/Iso/` and prints the URL.

## Manual build (without publish)
First decrypt the flavor config (see Secrets above), since the builder reads the
plaintext `data/build-flavors/rjn.toml`:
```
docker pull vyos/vyos-build:rolling
docker run --rm --privileged -v $(pwd):/vyos -w /vyos \
  vyos/vyos-build:rolling \
  sudo ./build-vyos-image --architecture amd64 \
    --build-by "rnavarro@crshman.info" rjn
```
Resulting ISO is `build/vyos-1.5-rolling-<timestamp>-rjn-amd64.iso`.
A duplicate `build/live-image-amd64.hybrid.iso` is also written; that is
upstream Makefile/CI plumbing and can be ignored.

## Verify our packages are in the build
```
grep -E 'qemu-guest-agent|tshark|bpftrace' build/live-image-amd64.packages
```

## Deploy
Published ISOs land at `https://fileserver.fmt2.crshman.info/ISOs/Iso/`.
Drive the rolling upgrade with `~/workspace/rjn-routing/scripts/vyos-image-upgrade.sh`,
passing `--image-url` for the new ISO.

> **Follow-up:** `vyos-image-upgrade.sh` lives in the separate `rjn-routing`
> repo (not checked out on the fileserver). Any hard-coded `-qemu-amd64`
> filename glob there must be updated to `-rjn-amd64` now that the flavor is
> renamed.

## Signatures (minisign)
We sign every published ISO with our own minisign key so routers verify our
images cryptographically on `add system image` instead of falling back to the
"signature not available" prompt.

- Secret key: `~/.config/vyos-build/rjn-minisign.key` (passwordless, `minisign
  -W`, chmod 600). **Not in git** — back it up to your secret store. Without it
  the build cannot sign and will abort early.
- Public key: baked into the image at `/usr/share/vyos/keys/rjn.minisign.pub`
  via `data/live-build-config/includes.chroot/usr/share/vyos/keys/`. VyOS's
  installer globs `*.minisign.pub` there and accepts any key that validates, so
  ours sits alongside the stock VyOS keys.
  Verify line: `minisign -Vm <iso> -P RWQWZsGTKN9plB9Fp2mrXcYTMYd1N+6wRjHilPmbTKBsrOsp6G7h/vM4`

`build-and-publish.sh` signs the published ISO and drops `<iso>.minisig` beside
it; the router fetches `<url>.minisig` automatically.

⚠️ **Bootstrap ("first hiccup"):** a router only trusts our key once it is
*running* an rjn image that carries it. The very first upgrade onto a
key-carrying image is driven by the *old* image, which lacks our key, so it
still hits the missing-signature prompt — that upgrade needs the upgrade
script's `--no-prompt`. Every upgrade after that verifies cleanly.

⚠️ `--no-prompt` skips only the *missing*-signature prompt. An *invalid*
signature (wrong/corrupt `.minisig`, or a router missing our key encountering a
signed ISO) still prompts and is **not** bypassed by `--no-prompt`. Keep the key
consistent across the fleet.
