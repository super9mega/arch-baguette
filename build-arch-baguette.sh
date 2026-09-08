#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-$PWD/build}"
OUTDIR="${OUTDIR:-$PWD/out}"

ROOTFS="${WORKDIR}/rootfs"
TOOLS="${WORKDIR}/cros-container-guest-tools"

IMAGE_SIZE="${IMAGE_SIZE:-20G}"
TARGET_USER="${TARGET_USER:-chronos}"
TARGET_PASSWORD="${TARGET_PASSWORD:-12345687}"

IMG="${WORKDIR}/baguette_arch_rootfs.img"
OUT="${OUTDIR}/baguette_arch_rootfs.img.zst"

MNT=""

cleanup() {
    if [ -n "${MNT:-}" ] && mountpoint -q "${MNT}"; then
        sudo umount "${MNT}" || true
    fi
}
trap cleanup EXIT

mkdir -p "${WORKDIR}" "${OUTDIR}"

if [ -d "${ROOTFS}" ] || [ -f "${IMG}" ] || [ -f "${OUT}" ]; then
    echo "Existing build output found."
    echo "Remove these directories/files first, or set another WORKDIR/OUTDIR:"
    echo "  ${ROOTFS}"
    echo "  ${IMG}"
    echo "  ${OUT}"
    exit 1
fi

echo "[1/10] Prepare host pacman keyring with latest Arch keyring"

KEYRING_TMP="${WORKDIR}/archlinux-keyring-bootstrap"
mkdir -p "${KEYRING_TMP}"

KEYRING_PKG_URL="$(
    curl -fsSL "https://archlinux.org/packages/core/any/archlinux-keyring/download/" \
        -o /dev/null \
        -w "%{url_effective}"
)"

curl -fL "${KEYRING_PKG_URL}" \
    -o "${KEYRING_TMP}/archlinux-keyring.pkg.tar.zst"

rm -rf "${KEYRING_TMP}/extract"
mkdir -p "${KEYRING_TMP}/extract"

tar --zstd -xf "${KEYRING_TMP}/archlinux-keyring.pkg.tar.zst" \
    -C "${KEYRING_TMP}/extract"

sudo mkdir -p /etc/pacman.d/gnupg

# pacman-key import path differs by pacman version:
#   pacman 6.x: /usr/share/keyrings
#   pacman 7.x: /usr/share/pacman/keyrings
for KEYRING_DIR in /usr/share/keyrings /usr/share/pacman/keyrings; do
    sudo install -Dm644 \
        "${KEYRING_TMP}/extract/usr/share/pacman/keyrings/archlinux.gpg" \
        "${KEYRING_DIR}/archlinux.gpg"
    sudo install -Dm644 \
        "${KEYRING_TMP}/extract/usr/share/pacman/keyrings/archlinux-trusted" \
        "${KEYRING_DIR}/archlinux-trusted"
    sudo install -Dm644 \
        "${KEYRING_TMP}/extract/usr/share/pacman/keyrings/archlinux-revoked" \
        "${KEYRING_DIR}/archlinux-revoked"
done
unset KEYRING_DIR

sudo rm -rf /etc/pacman.d/gnupg
sudo pacman-key --init
sudo pacman-key --populate archlinux

echo "[2/10] Write pacman config"

cat >"${WORKDIR}/mirrorlist" <<'EOF'
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
EOF

cat >"${WORKDIR}/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
HoldPkg = pacman glibc

[core]
Include = ${WORKDIR}/mirrorlist

[extra]
Include = ${WORKDIR}/mirrorlist
EOF

echo "[3/10] Bootstrap Arch rootfs"

ARCH_PACKAGES=(
    base
    archlinux-keyring
    systemd-sysvcompat
    sudo
    btrfs-progs
    dbus
    openssh
    acl
    bash-completion
    curl
    wget
    git
    vim
    nano
    xz
    gnupg
    tpm2-tools
    usbutils
    pciutils
    alsa-utils
    pipewire
    pipewire-pulse
    wireplumber
    xdg-utils
    xdg-desktop-portal-gtk
    gsettings-desktop-schemas
    wayland
    xorg-xwayland
    xorg-xauth
    xorg-xrdb
    xorg-xset
    xkeyboard-config
    wl-clipboard
)

sudo mkdir -p "${ROOTFS}"

sudo pacstrap \
    -C "${WORKDIR}/pacman.conf" \
    -M \
    "${ROOTFS}" \
    "${ARCH_PACKAGES[@]}"

echo "[4/10] Configure Arch rootfs"

sudo arch-chroot "${ROOTFS}" /usr/bin/env \
    TARGET_USER="${TARGET_USER}" \
    TARGET_PASSWORD="${TARGET_PASSWORD}" \
    /bin/bash -eux <<'CHROOT'
echo penguin > /etc/hostname

cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 penguin
100.115.92.2 arc
EOF

# arch-chroot bind-mounts host /etc/resolv.conf; create final link outside.

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF

for g in sudo netdev plugdev tss audio cdrom dialout disk floppy kvm video; do
  getent group "${g}" >/dev/null || groupadd "${g}"
done

if id -u "${TARGET_USER}" >/dev/null 2>&1; then
  usermod -aG wheel,sudo,audio,cdrom,dialout,disk,floppy,kvm,netdev,plugdev,tss,video "${TARGET_USER}"
else
  useradd -m -s /bin/bash \
    -G wheel,sudo,audio,cdrom,dialout,disk,floppy,kvm,netdev,plugdev,tss,video \
    "${TARGET_USER}"
fi

echo "${TARGET_USER}:${TARGET_PASSWORD}" | chpasswd

cat > /etc/sudoers.d/10-cros-nopasswd <<'EOF'
%sudo  ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/10-cros-nopasswd

mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/${TARGET_USER}"

if [ ! -e /usr/sbin/usermod ]; then
  mkdir -p /usr/sbin
  ln -s /usr/bin/usermod /usr/sbin/usermod
fi

mkdir -p /usr/lib/openssh
if [ -e /usr/lib/ssh/sftp-server ]; then
  ln -sf /usr/lib/ssh/sftp-server /usr/lib/openssh/sftp-server
fi

pacman-key --init
pacman-key --populate archlinux

: > /etc/machine-id
CHROOT

sudo ln -sfnT /run/resolv.conf "${ROOTFS}/etc/resolv.conf"

echo "[5/10] Clone ChromeOS guest tools"

git clone --depth=1 \
    https://chromium.googlesource.com/chromiumos/containers/cros-container-guest-tools \
    "${TOOLS}"

echo "[6/10] Install ChromeOS guest integration files"

sudo install -Dm755 \
    "${TOOLS}/cros-garcon/garcon-url-handler" \
    "${ROOTFS}/usr/bin/garcon-url-handler"

sudo install -Dm755 \
    "${TOOLS}/cros-garcon/garcon-terminal-handler" \
    "${ROOTFS}/usr/bin/garcon-terminal-handler"

sudo install -Dm644 \
    "${TOOLS}/cros-garcon/garcon_host_browser.desktop" \
    "${ROOTFS}/usr/share/applications/garcon_host_browser.desktop"

sudo install -Dm644 \
    "${TOOLS}/cros-garcon/cros-garcon.service" \
    "${ROOTFS}/usr/lib/systemd/user/cros-garcon.service"

sudo install -Dm644 \
    "${TOOLS}/cros-sommelier/sommelier@.service" \
    "${ROOTFS}/usr/lib/systemd/user/sommelier@.service"

sudo install -Dm644 \
    "${TOOLS}/cros-sommelier/sommelier-x@.service" \
    "${ROOTFS}/usr/lib/systemd/user/sommelier-x@.service"

sudo install -Dm644 \
    "${TOOLS}/cros-sommelier/sommelier.sh" \
    "${ROOTFS}/etc/profile.d/sommelier.sh"

sudo install -Dm644 \
    "${TOOLS}/cros-sommelier/sommelierrc" \
    "${ROOTFS}/etc/sommelierrc"

sudo install -Dm644 \
    "${TOOLS}/cros-notificationd/cros-notificationd.service" \
    "${ROOTFS}/usr/lib/systemd/user/cros-notificationd.service"

sudo install -Dm644 \
    "${TOOLS}/cros-notificationd/org.freedesktop.Notifications.service" \
    "${ROOTFS}/usr/share/dbus-1/services/org.freedesktop.Notifications.service"

sudo install -Dm644 \
    "${TOOLS}/cros-wayland/10-cros-virtwl.rules" \
    "${ROOTFS}/usr/lib/udev/rules.d/10-cros-virtwl.rules"

sudo install -Dm644 \
    "${TOOLS}/cros-port-listener/10-cros-port-listener.rules" \
    "${ROOTFS}/usr/lib/udev/rules.d/10-cros-port-listener.rules"

sudo install -Dm644 \
    "${TOOLS}/cros-port-listener/cros-port-listener.service" \
    "${ROOTFS}/usr/lib/systemd/system/cros-port-listener.service"

sudo ln -sf /opt/google/cros-containers/bin/sommelier \
    "${ROOTFS}/usr/bin/sommelier"

sudo ln -sf /opt/google/cros-containers/bin/sommelier.elf \
    "${ROOTFS}/usr/bin/sommelier.elf"

echo "[7/10] Install Baguette systemd units"

sudo mkdir -p \
    "${ROOTFS}/etc/systemd/system" \
    "${ROOTFS}/etc/systemd/user/default.target.wants" \
    "${ROOTFS}/etc/maitred" \
    "${ROOTFS}/etc/profile.d" \
    "${ROOTFS}/opt/google/cros-containers" \
    "${ROOTFS}/mnt/chromeos/fonts" \
    "${ROOTFS}/mnt/shared" \
    "${ROOTFS}/usr/local/bin"

sudo tee "${ROOTFS}/etc/systemd/system/opt-google-cros\\x2dcontainers.mount" >/dev/null <<'EOF'
[Unit]
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target

[Mount]
What=LABEL=cros-vm-tools
Where=/opt/google/cros-containers
Options=ro
TimeoutSec=10

[Install]
WantedBy=local-fs.target
EOF

sudo tee "${ROOTFS}/etc/systemd/system/maitred.service" >/dev/null <<'EOF'
[Unit]
Description=maitred
Requires=opt-google-cros\x2dcontainers.mount
After=opt-google-cros\x2dcontainers.mount

[Service]
Environment="PATH=/opt/google/cros-containers/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/google/cros-containers/bin/maitred

[Install]
WantedBy=basic.target
EOF

sudo tee "${ROOTFS}/etc/systemd/system/vshd.service" >/dev/null <<'EOF'
[Unit]
Description=vshd
Requires=opt-google-cros\x2dcontainers.mount
After=opt-google-cros\x2dcontainers.mount

[Service]
ExecStart=/opt/google/cros-containers/bin/vshd

[Install]
WantedBy=basic.target
EOF

sudo tee "${ROOTFS}/usr/local/bin/first-boot-cros" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

btrfs filesystem resize max / || true
rm -f /etc/ssh/ssh_host_* || true
ssh-keygen -A || true
sync
EOF
sudo chmod +x "${ROOTFS}/usr/local/bin/first-boot-cros"

sudo tee "${ROOTFS}/etc/systemd/system/first-boot-cros.service" >/dev/null <<'EOF'
[Unit]
Description=First boot script

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/first-boot-cros
ExecStartPost=/usr/bin/systemctl disable first-boot-cros.service
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=local-fs.target
EOF

sudo tee "${ROOTFS}/etc/maitred/50-mount-fonts.textproto" >/dev/null <<'EOF'
argv: "mount"
argv: "--type"
argv: "virtiofs"
argv: "--options"
argv: "ro,nosuid,nodev,noexec"
argv: "fonts"
argv: "/mnt/chromeos/fonts"
respawn: false
wait_for_exit: true
EOF

sudo tee "${ROOTFS}/etc/profile.d/10-baguette-envs.sh" >/dev/null <<'EOF'
IDU_RESULT=$(id -u)
IDUN_RESULT=$(id -un)

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${IDU_RESULT}/bus"
fi

if [[ -z "${XDG_SESSION_TYPE:-}" ]]; then
  export XDG_SESSION_TYPE="wayland"
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/${IDU_RESULT}"
fi

if [[ -z "${USER:-}" ]]; then
  export USER="${IDUN_RESULT}"
fi

SECONDS=0
while ! pgrep -f "sommelier" > /dev/null; do
  sleep 1
  SECONDS=$((SECONDS+1))
  if [[ ${SECONDS} -ge 4 ]]; then
    break
  fi
done

sleep 0.2

unset IDU_RESULT
unset IDUN_RESULT
unset SECONDS
EOF

sudo tee "${ROOTFS}/etc/fstab" >/dev/null <<'EOF'
LABEL=arch-baguette / btrfs defaults 0 0
EOF

echo "[8/10] Enable services"

sudo systemctl --root="${ROOTFS}" enable \
    'opt-google-cros\x2dcontainers.mount' \
    maitred.service \
    vshd.service \
    first-boot-cros.service \
    cros-port-listener.service \
    dbus.service \
    systemd-timesyncd.service

sudo ln -sf /usr/lib/systemd/user/sommelier@.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/sommelier@0.service"

sudo ln -sf /usr/lib/systemd/user/sommelier-x@.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/sommelier-x@0.service"

sudo ln -sf /usr/lib/systemd/user/sommelier@.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/sommelier@1.service"

sudo ln -sf /usr/lib/systemd/user/sommelier-x@.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/sommelier-x@1.service"

sudo ln -sf /usr/lib/systemd/user/cros-garcon.service \
    "${ROOTFS}/etc/systemd/user/default.target.wants/cros-garcon.service"

echo "[9/10] Create BTRFS raw image"

truncate -s "${IMAGE_SIZE}" "${IMG}"
sudo mkfs.btrfs -f -L arch-baguette "${IMG}"

MNT="$(mktemp -d)"
sudo mount -o loop "${IMG}" "${MNT}"

sudo btrfs subvolume create "${MNT}/rootfs_subvol"

sudo rsync -aHAX --numeric-ids \
    "${ROOTFS}/" \
    "${MNT}/rootfs_subvol/"

SUBVOL_ID="$(
    sudo btrfs subvolume list "${MNT}" |
        awk '/path rootfs_subvol/ {print $2; exit}'
)"

sudo btrfs subvolume set-default "${SUBVOL_ID}" "${MNT}"

sync
sudo umount "${MNT}"
rmdir "${MNT}"
MNT=""

echo "[10/10] Compress image"

zstd -T0 -3 "${IMG}" -o "${OUT}"

sha256sum "${OUT}" | tee "${OUT}.sha256"

echo
echo "Done."
echo "Output:"
echo "  ${OUT}"
echo "  ${OUT}.sha256"
echo
echo "Target user:"
echo "  ${TARGET_USER}"
echo
echo "Initial password:"
echo "  ${TARGET_PASSWORD}"
