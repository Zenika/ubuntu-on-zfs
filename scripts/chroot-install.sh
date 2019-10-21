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

configure_keyboard() {
    # Do NOT format code below. Tabs are IMPORTANT. Do not remove any! Do NOT add any!
    cat <<EOT >> /tmp/deb-keyboard.conf
keyboard-configuration	console-setup/ask_detect	boolean	false
keyboard-configuration	keyboard-configuration/model	select	PC générique 105 touches (internat.)
keyboard-configuration	keyboard-configuration/layoutcode	string	fr
keyboard-configuration	keyboard-configuration/variant	select	Français
keyboard-configuration	keyboard-configuration/unsupported_layout	boolean	true
keyboard-configuration	keyboard-configuration/xkb-keymap	select
keyboard-configuration	keyboard-configuration/ctrl_alt_bksp	boolean	false
keyboard-configuration	keyboard-configuration/unsupported_options	boolean	true
keyboard-configuration	keyboard-configuration/optionscode	string
keyboard-configuration	keyboard-configuration/unsupported_config_layout	boolean	true
keyboard-configuration	keyboard-configuration/modelcode	string	pc105
keyboard-configuration	keyboard-configuration/store_defaults_in_debconf_db	boolean	true
keyboard-configuration	keyboard-configuration/variantcode	string
keyboard-configuration	console-setup/detected	note
keyboard-configuration	keyboard-configuration/compose	select	No compose key
keyboard-configuration	keyboard-configuration/switch	select	No temporary switch
keyboard-configuration	keyboard-configuration/unsupported_config_options	boolean	true
keyboard-configuration	keyboard-configuration/layout	select	Français
keyboard-configuration	keyboard-configuration/altgr	select	The default for the keyboard layout
keyboard-configuration	keyboard-configuration/toggle	select	No toggling
EOT
    debconf-set-selections < /tmp/deb-keyboard.conf
    dpkg-reconfigure --frontend=noninteractive keyboard-configuration
    rm /tmp/deb-keyboard.conf

    sed -i -e 's/XKBLAYOUT="\w*"/XKBLAYOUT="fr"/' /etc/default/keyboard
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

create_user() {
    local username=user
    local password
    apt install -y whois
    password=$(mkpasswd -m sha-512 "$USER_PASSWORD")
    useradd -m -p "$password" -s /bin/bash "$username"
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$username"
}

full_install() {
    apt update
    apt full-upgrade -y
    apt install -y ubuntu-desktop vim bash-completion
}

clean_some_stuff() {
    # Get rid of the amazon shortcut in favourites
    rm -f /usr/share/applications/ubuntu-amazon-default.desktop
}

configure_network() {
    cat <<EOT > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: NetworkManager
EOT
}

tune_zfs_config() {
    # Memory used by ZFS should be limited
    # see https://www.solaris-cookbook.eu/linux/linux-ubuntu/debian-ubuntu-centos-zfs-on-linux-zfs-limit-arc-cache/

    cat <<EOF > /etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=4294967296
EOF
    # see https://serverfault.com/questions/581669/why-isnt-the-arc-max-setting-honoured-on-zfs-on-linux#comment1108614_602457
    refresh_initrd_files
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

    configure_keyboard

    install_zfs

    install_grub

    enable_importing_bpool

    mount_tmp_in_tmpfs

    setup_system_groups

    refresh_initrd_files

    update_grub_config

    install_boot_loader

    fix_filesystem_mount_ordering

    create_user

    full_install

    clean_some_stuff

    configure_network

    tune_zfs_config

    snapshot_initial_installation
}

main