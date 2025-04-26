#!/bin/bash
set -euo pipefail

# 1. List disks
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -Ev 'loop|sr'
read -p "Enter target disk (e.g. sda): " d
disk="/dev/$d"
[[ -b $disk ]] || { echo "$disk not found."; exit 1; }

# 2. Confirm wipe
echo "!!! All partitions on $disk will be ERASED !!!"
read -p "Type 'yes' to continue: " c
[[ $c == yes ]] || { echo "Aborted."; exit 1; }

# 3. Disable swap & unmount
swapoff -a
echo "Unmounting any partitions on $disk..."
for p in $(lsblk -ln -o NAME "$disk" | tail -n+2); do
  mp=$(lsblk -ln -o MOUNTPOINT "/dev/$p")
  [[ -n $mp ]] && { echo " → umount /dev/$p ($mp)"; umount "/dev/$p"; }
done

# 4. Wipe disk
echo "Wiping $disk..."
wipefs --all --force "$disk"

# 5. Detect boot mode
if [[ -d /sys/firmware/efi/efivars ]]; then
  mode=UEFI; echo "Boot mode: UEFI"
else
  mode=BIOS; echo "Boot mode: BIOS"
fi

# 6. Ask for swap size
read -p "Swap size (e.g. 2G or 2048M): " swapsize

# 7. Partition
echo "Partitioning $disk..."
if [[ $mode == UEFI ]]; then
  parted -s "$disk" \
    mklabel gpt \
    mkpart primary fat32   1MiB   513MiB \
    set 1 esp on \
    mkpart primary linux-swap 513MiB "$swapsize" \
    mkpart primary ext4       "$swapsize" 100%
  esp="${disk}1"; swap="${disk}2"; root="${disk}3"
else
  parted -s "$disk" \
    mklabel msdos \
    mkpart primary ext4       1MiB   513MiB \
    set 1 boot on \
    mkpart primary linux-swap 513MiB "$swapsize" \
    mkpart primary ext4       "$swapsize" 100%
  bootp="${disk}1"; swap="${disk}2"; root="${disk}3"
fi

partprobe "$disk"; sleep 1

# 8. Format + mount
echo "Formatting..."
if [[ $mode == UEFI ]]; then
  mkfs.fat -F32 "$esp"
else
  mkfs.ext4 -F "$bootp"
fi
mkfs.ext4 -F "$root"
mkswap "$swap"

echo "Mounting..."
mount "$root" /mnt
if [[ $mode == UEFI ]]; then
  mkdir -p /mnt/boot/efi
  mount "$esp" /mnt/boot/efi
else
  mkdir -p /mnt/boot
  mount "$bootp" /mnt/boot
fi
swapon "$swap"

# 9. Generate base fstab
echo "Writing /mnt/etc/fstab..."
mkdir -p /mnt/etc
: > /mnt/etc/fstab
echo "UUID=$(blkid -s UUID -o value "$root") / ext4 defaults 0 1" >> /mnt/etc/fstab
if [[ $mode == UEFI ]]; then
  echo "UUID=$(blkid -s UUID -o value "$esp") /boot/efi vfat defaults 0 2" >> /mnt/etc/fstab
else
  echo "UUID=$(blkid -s UUID -o value "$bootp") /boot ext4 defaults 0 2" >> /mnt/etc/fstab
fi
echo "UUID=$(blkid -s UUID -o value "$swap") none swap sw 0 0" >> /mnt/etc/fstab

# 10. Install base system (now including tzdata)
echo "Installing base system..."
pacstrap -K /mnt base linux linux-firmware tzdata vim sudo fish curl networkmanager grub efibootmgr os-prober

# 11. Regenerate full fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 12. Create chroot setup script
cat > /mnt/root/setup.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# 1. US keyboard
localectl set-keymap us

# 2. Timezone prompt
echo "Timezones under /usr/share/zoneinfo"
read -p "Enter timezone (e.g. Europe/Warsaw): " tz
timedatectl set-timezone "$tz"
timedatectl set-ntp true

# 3. Hostname
read -p "Enter hostname: " hn
echo "$hn" > /etc/hostname
cat > /etc/hosts << H
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hn.localdomain $hn
H

# 4. Root password loop
while true; do
  read -s -p "New root password: " p1; echo
  read -s -p "Retype root password: " p2; echo
  [[ "$p1" == "$p2" ]] && { echo "root:$p1" | chpasswd; break; }
  echo "Passwords do not match, try again."
done

# 5. Create user + wheel group
read -p "Enter new username: " un
useradd -m -G wheel "$un"

# 6. New user password loop
while true; do
  read -s -p "Password for $un: " q1; echo
  read -s -p "Retype password for $un: " q2; echo
  [[ "$q1" == "$q2" ]] && { echo "$un:$q1" | chpasswd; break; }
  echo "Passwords do not match, try again."
done

# 7. Sudoers: wheel NOPASSWD
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers

# 8. Init keyring & install autojump and neofetch
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm autojump neofetch || echo "Some packages not found, skipping"

# 9. Enable NetworkManager
systemctl enable NetworkManager

# 10. Static IPv4 via .nmconnection
read -p "Configure static IPv4? (y/N): " stat
if [[ $stat =~ ^[Yy]$ ]]; then
  dev=$(ls /sys/class/net | grep -Ev 'lo|wlan' | head -n1)
  echo "Interface: $dev"
  read -p "Enter IP (e.g. 192.168.1.10/24): " ip4
  read -p "Enter gateway (e.g. 192.168.1.1): " gw
  read -p "Enter DNS (e.g. 8.8.8.8): " dns

  mkdir -p /etc/NetworkManager/system-connections
  cat > /etc/NetworkManager/system-connections/${dev}-static.nmconnection << NM
[connection]
id=static-${dev}
uuid=$(uuidgen)
type=ethernet
interface-name=${dev}
autoconnect=true

[ipv4]
address1=${ip4},${gw}
dns=${dns};
method=manual

[ipv6]
method=ignore
NM
  chmod 600 /etc/NetworkManager/system-connections/${dev}-static.nmconnection
fi

# 11. Fish in .bashrc
bashrc_snip='
# Start fish unless already in fish
if [[ $(ps --no-header --pid=$PPID --format=comm) != "fish" && -z ${BASH_EXECUTION_STRING} ]]; then
  exec fish
fi
source /usr/share/autojump/autojump.bash
source ~/.config/at-login.sh
source ~/.config/aliases.sh
[ -f ~/.config/.bash-preexec.sh ] && source ~/.config/.bash-preexec.sh
eval "$(atuin init bash)"
_doas_func() { if [[ "$1" =~ ^(su|bash|fish)$ ]]; then echo no; else doas "$@"; fi; }
alias doas="_doas_func"
'
echo "$bashrc_snip" >> /root/.bashrc
echo "$bashrc_snip" >> /home/"$un"/.bashrc
chown "$un":"$un" /home/"$un"/.bashrc

# 12. Install GRUB
if [[ -d /sys/firmware/efi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  grub-install --target=i386-pc "$disk"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# 13. Final message
clear
neofetch || echo "neofetch missing"
echo -e "\nInstallation complete. You can now type 'exit' and then reboot."

# Delete this script after running
rm -- "$0"
EOF

chmod +x /mnt/root/setup.sh

# 13. Enter chroot and run setup
echo "Entering chroot..."
arch-chroot /mnt /root/setup.sh

clear 
neofetch

echo "Installation finished. You can now exit and reboot."
