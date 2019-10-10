#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

symlink_mtab() {
    ln -s /proc/self/mounts /etc/mtab
}

update_configured_sources() {
    apt update
}

configure_locales() {
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i -e 's/# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
    echo 'LANG="fr_FR.UTF-8"' > /etc/default/locale
    dpkg-reconfigure --frontend=noninteractive locales
}

# Inspired by https://bugs.launchpad.net/ubuntu/+source/tzdata/+bug/1554806/comments/9
configure_tzdata() {
    rm /etc/localtime /etc/timezone
    ln -fs /usr/share/zoneinfo/Europe/Paris /etc/localtime
    dpkg-reconfigure --frontend=noninteractive tzdata
}

install_zfs() {
    apt install --yes --no-install-recommends linux-image-generic
    apt install --yes zfs-initramfs
}

install_grub() {
    apt install dosfstools
    mkdosfs -F 32 -s 1 -n EFI "$TARGET_DISK-part2"
    mkdir /boot/efi
    echo "PARTUUID=$(blkid -s PARTUUID -o value "$TARGET_DISK-part2")   /boot/efi   vfat    nofail,x-systemd.device-timeout=1   0   1" >> /etc/fstab
    mount /boot/efi
    apt install --yes grub-efi-amd64-signed shim-signed
}

set_root_password() {
    echo "root:$ROOT_PASSWORD" | chpasswd
}

enable_importing_bpool() {
    cat <<EOT >> /etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool

[Install]
WantedBy=zfs-import.target
EOT

    systemctl enable zfs-import-bpool.service
}

mount_tmp_in_tmpfs() {
    cp /usr/share/systemd/tmp.mount /etc/systemd/system/
    systemctl enable tmp.mount
}

setup_system_groups() {
    addgroup --system lpadmin
    addgroup --system sambashare
}

refresh_initrd_files() {
    update-initramfs -u -k all
}

update_grub_config() {
    sed -i -e 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="root=ZFS=rpool\/ROOT\/ubuntu"/' /etc/default/grub
    sed -i -e 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
    sed -i -e 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
    sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
    sed -i -e 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/' /etc/default/grub

    update-grub
}

install_boot_loader() {
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
}

fix_filesystem_mount_ordering() {
    umount /boot/efi

    zfs set mountpoint=legacy bpool/BOOT/ubuntu
    echo "bpool/BOOT/ubuntu /boot   zfs     nodev,relatime,x-systemd.requires=zfs-import-bpool.service  0   0" >> /etc/fstab
}

prepare_first_boot_service() {
    cat <<EOT >> /etc/systemd/system/first-boot.service
[Unit]
Description=first-boot
ConditionPathExists=/usr/local/first-boot.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/first-boot.sh

[Install]
WantedBy=multi-user.target

EOT
    systemctl enable first-boot.service
}

install_additional_packages() {
    apt install -y vim bash-completion
}

snapshot_initial_installation() {
    zfs snapshot bpool/BOOT/ubuntu@install
    zfs snapshot rpool/ROOT/ubuntu@install
}

main() {

    symlink_mtab

    update_configured_sources

    configure_locales

    configure_tzdata

    install_zfs

    install_grub

    set_root_password

    enable_importing_bpool

    mount_tmp_in_tmpfs

    setup_system_groups

    refresh_initrd_files

    update_grub_config

    install_boot_loader

    fix_filesystem_mount_ordering

    prepare_first_boot_service

    install_additional_packages

    snapshot_initial_installation
}

main