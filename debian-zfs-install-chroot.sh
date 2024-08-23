# Configure basic sytem env
apt update
apt install --yes console-setup locales
#
dpkg-reconfigure locales tzdata keyboard-configuration console-setup

# Installing ZFS in chroot env
apt install --yes dpkg-dev linux-headers-generic linux-image-generic
apt install --yes zfs-initramfs
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf

# Optional
apt install systemd-timesyncd

# Grub for UEFI
apt install dosfstools
mkdosfs -F 32 -s 1 -n EFI ${DISK}-part2
mkdir /boot/efi
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${DISK}-part2) \
   /boot/efi vfat defaults 0 0 >> /etc/fstab
mount /boot/efi
apt install --yes grub-efi-amd64 shim-signed

# clean up
apt purge --yes os-prober
echo "root passwd"
passwd

# Enable importing bpool
cat <<EOF > /etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
# Work-around to preserve zpool cache:
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
EOF
systemctl enable zfs-import-bpool.service

#
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

apt install --yes openssh-server

vi /etc/ssh/sshd_config
# Set: PermitRootLogin yes

# GRUB installation
grub-probe /boot
update-initramfs -c -k all

vi /etc/default/grub
# Set: GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"

vi /etc/default/grub
# Remove quiet from: GRUB_CMDLINE_LINUX_DEFAULT
# Uncomment: GRUB_TERMINAL=console
# Save and quit.

update-grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi \
	     --bootloader-id=debian --recheck --no-floppy
# 
mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
zed -F &

echo "Generating zfs cache. Verify correct"
sleep 3
cat /etc/zfs/zfs-list.cache/bpool
cat /etc/zfs/zfs-list.cache/rpool
echo "Press any key"
read

sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*
cat /etc/zfs/zfs-list.cache/bpool
cat /etc/zfs/zfs-list.cache/rpool
echo "No longer /mnt"
read

# Snapsnot the installation
zfs snapshot bpool/BOOT/debian@install
zfs snapshot rpool/ROOT/debian@install

# exit chroot
exit