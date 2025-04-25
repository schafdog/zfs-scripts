#!/bin/sh

# Assumptions and requirements
# - All drives will be formatted. These instructions are not suitable for dual-boot
# - No hardware or software RAID is to be used, these would keep ZFS from detecting disk errors and correcting them. In UEFI settings, set controller mode to AHCI, not RAID
# - These instructions are specific to UEFI systems and GPT. If you have an older BIOS/MBR system, please use https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2020.04%20Root%20on%20ZFS.html

# change the these disks variables to your disks paths (check with lsblk)
DISK1="nvme0n1"
DISK2="sda"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script with sudo:"
    echo "sudo $0 $*"
    exit 1
fi

echo "Installing dependencies"
apt install -y gdisk mdadm grub-efi-amd64

echo "-- Create partitions on second drive"

echo "Change swap partition type"

#sgdisk -t2:FD00 $DISK1

echo "Copy partition table from disk 1 to disk 2? "
read answer
if [ "$answer" == "Y" ] ; then
    sgdisk -R $DISK2 $DISK1
    echo "Change GUID of second disk"
    sgdisk -G $DISK2
fi

# this change seems to take a while to propagate :/
sleep 3

echo "-- Replace disk of boot pool"

echo "Get ID of partition 3 on disk 2"
DISK1_PART2_ID=$(ls -l /dev/disk/by-id/* |grep -v wwn- | grep ${DISK1}2 | cut -b 56- | cut -f 1 -d ' ')
DISK2_PART2_ID=$(ls -l /dev/disk/by-id/* |grep -v wwn- | grep ${DISK2}2 | cut -b 56- | cut -f 1 -d ' ')
echo "DISK 1 PART 2 ID"
echo $DISK1_PART2_ID
echo "DISK 2 PART 2 ID"
echo $DISK2_PART2_ID
if [ -z  $DISK1_PART2_ID ]; then
    echo "error: failed to get the disk1 part 2 guid"
    exit 1
fi

if [ -z  $DISK2_PART2_ID ]; then
    echo "error: failed to get the disk2 part 2 guid"
    exit 1
fi
echo "zpool replace bpool $DISK1_PART2_ID /dev/disk/by-partuuid/$DISK2_PART2_ID || exit 1"
echo "Continue?" 
read 

echo "replace partition to bpool"
#zpool replace bpool $DISK1_PART2_ID /dev/disk/by-partuuid/$DISK2_PART2_ID || exit 1

# TODO: check for failure here by the zpool status not showing the mirror

echo "-- replace disk in root pool"

DISK1_PART4_ID=$(ls -1 /dev/disk/by-id/ata-* |  grep "${DISK1}4" | awk '{print tolower($4)}')
DISK2_PART4_ID=$(ls -1 /dev/disk/by-id/ata-* |  grep "${DISK2}4" | awk '{print tolower($4)}')

if [ -z  $DISK1_PART4_ID ]; then
    echo "error: failed to get the disk1 part 4 guid"
    exit 1
fi

if [ -z  $DISK2_PART4_ID ]; then
    echo "error: failed to get the disk2 part 4 guid"
    exit 1
fi
echo "zpool replace rpool $DISK1_PART4_ID /dev/disk/by-partuuid/$DISK2_PART4_ID || exit 1"
echo "Continue?"
read

echo "replace partition to rpool"
# zpool replace rpool $DISK1_PART4_ID /dev/disk/by-partuuid/$DISK2_PART4_ID || exit 1

# TODO: check for failure here by the zpool status not showing the mirror
exit

echo "-- Mirror Swap"
echo "Continue with swap?"
read

echo "remove existing swap"
swapoff -a || exit 1

echo "remove the swap mount line in /etc/fstab"
sed -i '/swap/d' /etc/fstab

echo "create software mirror drive for swap"
mdadm --create /dev/md0 --metadata=1.2 --level=mirror --raid-devices=2 ${DISK1}p3 ${DISK2}p3 || exit 1

echo "configure mirror drive for swap"
mkswap -f /dev/md0 || exit 1

echo "place mirror swap in fstab"
sh -c "echo UUID=$(sudo blkid -s UUID -o value /dev/md0) none swap discard 0 0 >> /etc/fstab"

# TODO: verify that line is in fstab cat /etc/fstab

echo "use the new swap"
swapon -a || exit 1

echo "-- Move grub menu to ZFS"

# TODO: verify that grub can  see the ZFS boot pool grub-probe /boot

echo "create EFI file system on second disk"
mkdosfs -F 32 -s 1 -n EFI ${DISK2}p1

echo "Continue with grub?"
read

# Create grub
echo "remove /boot/grub from fstab"
sed -i '/grub/d' /etc/fstab

echo "umount /boot/grub"
umount /boot/grub

# TODO: Verify with df -h, /boot should be mounted on bpool/BOOT/ubuntu_UID, /boot/efi on /dev/sda1 or similar depending on device name of your first disk, and no /boot/grub

echo "remove /boot/grub"
rm -rf /boot/grub

echo "create ZFS datatset for grub"
zfs create -o com.ubuntu.zsys:bootfs=no bpool/grub

echo "refresh initrd files"
update-initramfs -c -k all

echo "disable memory zeroing to address a performance regression of ZFS on linux"
sed -i.bak "s/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash init_on_alloc=0\"/g" /etc/default/grub

echo "update grub"
update-grub

echo "reload daemon"
systemctl daemon-reload

echo "install grub to the esp"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy

echo "disable grub-initrd-fallback.service"
systemctl mask grub-initrd-fallback.service

echo "DONE without errors"

dpkg-reconfigure grub-efi-amd64
