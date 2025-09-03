#!/bin/bash
set -Eeuo pipefail

cleanup_stty() { stty echo || true; }
trap cleanup_stty EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (sudo or root shell)."
  exit 1
fi

[ ! -d /sys/firmware/efi ] && echo "System not booted in UEFI mode." && exit 1

# Detect CPU vendor for microcode
UCODE=""
if grep -m1 -Eiq '^vendor_id\s+:\s+GenuineIntel' /proc/cpuinfo; then
  UCODE="linux-firmware-intel"
elif grep -m1 -Eiq '^vendor_id\s+:\s+AuthenticAMD' /proc/cpuinfo; then
  UCODE="linux-firmware-amd"
fi

confirm_password() {
  local prompt="$1" pass1="" pass2=""
  while :; do
    printf "\n%s\n> " "$prompt" >&2
    read -r -s pass1
    printf "\nRe-type %s\n> " "$prompt" >&2
    read -r -s pass2
    [ -n "$pass1" ] && [ "$pass1" = "$pass2" ] && break
    echo -e "\nPasswords did not match or were empty. Try again." >&2
  done
  printf "%s" "$pass2"
}

# Ask user settings
while [ -z "${KEYMAP:-}" ]; do
  clear
  printf "Keyboard layout (default: us)\n> "
  read -r KEYMAP
  [ -z "$KEYMAP" ] && KEYMAP="us"
  loadkeys "$KEYMAP" 2>/dev/null || true
done

while [ -z "${REGION_CITY:-}" ]; do
  clear
  printf "Timezone (default: Europe/Berlin)\n> "
  read -r REGION_CITY
  [ -z "$REGION_CITY" ] && REGION_CITY="Europe/Berlin"
done

while [ -z "${HOST:-}" ]; do
  clear
  printf "Hostname (default: voidbox)\n> "
  read -r HOST
  [ -z "$HOST" ] && HOST="voidbox"
done

while [ -z "${USERNAME:-}" ]; do
  clear
  printf "Username (default: void)\n> "
  read -r USERNAME
  [ -z "$USERNAME" ] && USERNAME="void"
done

[ -z "${ROOT_PASSWORD:-}" ] && ROOT_PASSWORD=$(confirm_password "Password for root")
[ -z "${USER_PASSWORD:-}" ] && USER_PASSWORD=$(confirm_password "Password for user $USERNAME")

# Choose disk
until [ -e "${DISK:-}" ]; do
  clear
  lsblk -dpno NAME,SIZE
  echo ""
  echo "WARNING: The selected disk will be erased!"
  printf "Disk to install (e.g. /dev/sda or /dev/nvme0n1)\n> "
  read -r DISK
done

case "$DISK" in
  *"nvme"*) PART1="${DISK}p1"; PART2="${DISK}p2" ;;
  *)        PART1="${DISK}1";  PART2="${DISK}2" ;;
esac

ROOT_PART=$PART2

# Encrypt?
while [ -z "${ENCRYPTED:-}" ]; do
  clear
  printf "Encrypt root partition? (y/n, default: n)\n> "
  read -r ENCRYPTED
  [ -z "$ENCRYPTED" ] && ENCRYPTED="n"
  if [ "$ENCRYPTED" = "y" ]; then
    CRYPTPASS=$(confirm_password "Password for disk encryption")
  fi
done

# Partition disk
swapoff -a || true
umount -AR /mnt || true
cryptsetup close root || true

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 512MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 512MiB 100%

if [ "$ENCRYPTED" = "y" ]; then
  printf "%s" "$CRYPTPASS" | cryptsetup luksFormat "$ROOT_PART" -
  printf "%s" "$CRYPTPASS" | cryptsetup open "$ROOT_PART" root -
  ROOT_PART="/dev/mapper/root"
fi

mkfs.vfat -F32 -n ESP "$PART1"
mkfs.ext4 -L root "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$PART1" /mnt/boot/efi

# Create swapfile
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
SWAP_SIZE=$(( RAM_GB * 2 + 2 ))
install -d -m 0755 /mnt/swap
fallocate -l "${SWAP_SIZE}G" /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# Base install
XBPS_REPO="https://repo-default.voidlinux.org/current"
xbps-install -Sy -R "$XBPS_REPO" -r /mnt base-system grub-x86_64-efi $UCODE linux linux-firmware vim

# fstab
mount -v | awk '{ if ($1 ~ /^\//) print $1" "$3" "$5" defaults 0 1" }' > /mnt/etc/fstab
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# Configure inside chroot
cat <<EOF | chroot /mnt /bin/bash -eux
echo "$HOST" > /etc/hostname
ln -sf /usr/share/zoneinfo/$REGION_CITY /etc/localtime
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# Root password
echo "root:$ROOT_PASSWORD" | chpasswd

# User
useradd -m -G wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/99_wheel

# Initramfs (with encryption support if needed)
if [ "$ENCRYPTED" = "y" ]; then
  sed -i 's/^#BOOTLOADER=.*$/BOOTLOADER=grub/' /etc/default/cryptsetup
  echo "CRYPTTAB_OPTS=keyscript=/lib/cryptsetup/scripts/decrypt_keyctl" >> /etc/default/cryptsetup
fi
xbps-reconfigure -fa

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
grub-mkconfig -o /boot/grub/grub.cfg
EOF

swapoff -a
umount -R /mnt
[ "$ENCRYPTED" = "y" ] && cryptsetup close root

echo "Installation finished! Reboot into Void Linux."
