#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

# shellcheck source=./common.sh
source "./common.sh"

update_apt_sources() {
    log_info "Updating APT sources…"

    apt update

    log_success "APT sources updated!"
}

configure_locales() {
    log_info "Reconfiguring locales package…"

    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i -e 's/# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
    echo 'LANG="fr_FR.UTF-8"' >/etc/default/locale
    dpkg-reconfigure --frontend=noninteractive locales

    log_success "locales package reconfigured!"
}

# Inspired by https://bugs.launchpad.net/ubuntu/+source/tzdata/+bug/1554806/comments/9
configure_tzdata() {
    log_info "Reconfiguring tzdata package…"

    rm /etc/localtime /etc/timezone
    ln -fs /usr/share/zoneinfo/Europe/Paris /etc/localtime
    dpkg-reconfigure --frontend=noninteractive tzdata

    log_success "tzdata package reconfigured!"
}

configure_keyboard() {
    log_info "Reconfiguring keyboard-configuration package…"

    # Do NOT format code below. Tabs are IMPORTANT. Do not remove any! Do NOT add any!
    cat <<EOT >>/tmp/deb-keyboard.conf
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
    debconf-set-selections </tmp/deb-keyboard.conf
    dpkg-reconfigure --frontend=noninteractive keyboard-configuration
    rm /tmp/deb-keyboard.conf

    sed -i -e 's/XKBLAYOUT="\w*"/XKBLAYOUT="fr"/' /etc/default/keyboard

    log_success "keyboard-configuration package reconfigured!"
}

create_efi_filesystem() {
    log_info "Creating EFI filesystem…"

    apt install -y dosfstools
    mkdosfs -F 32 -s 1 -n EFI "$TARGET_DISK-part1"
    mkdir -p /boot/efi
    echo "/dev/disk/by-uuid/$(blkid -s UUID -o value "$TARGET_DISK-part1")   /boot/efi   vfat    defaults   0   0" >>/etc/fstab
    mount /boot/efi

    mkdir /boot/efi/grub /boot/grub
    echo "/boot/efi/grub   /boot/grub   none    defaults,bind   0   0" >>/etc/fstab
    mount /boot/grub

    log_success "EFI filesystem created!"
}

install_base_packages() {
    log_info "Installing basse packages (GRUB, Linux, ZFS)…"

    apt install -y grub-efi-amd64 grub-efi-amd64-signed linux-image-generic shim-signed zfs-initramfs
    # Not needed as this is not a dual-boot configuration
    apt purge -y os-prober

    log_success "Base packages installed!"
}

configure_tmpfs_for_tmp() {
    log_info "Configures a tmpfs filesystem for /tmp…"

    cp /usr/share/systemd/tmp.mount /etc/systemd/system/
    systemctl enable tmp.mount

    log_success "tmpfs filesystem configured for /tmp!"
}

setup_system_groups() {
    log_info "Adding system groups…"

    addgroup --system lpadmin
    addgroup --system lxd
    addgroup --system sambashare

    log_success "System groups added!"
}

refresh_initrd_files() {
    log_info "Refreshing initrd files…"

    update-initramfs -u -k all

    log_success "initrd files refreshed"
}

update_grub_config() {
    log_info "Updating GRUB configuration…"

    sed -i -e 's/GRUB_TIMEOUT_STYLE=hidden/#GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
    sed -i -e 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
    sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="init_on_alloc=0"/' /etc/default/grub
    sed -i -e 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/' /etc/default/grub

    update-grub

    log_success "GRUB configuration updated!"
}

install_boot_loader() {
    log_info "Installing boot loader…"

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy

    log_success "Boot loader installed!"
}

fix_filesystem_mount_ordering() {

    mkdir /etc/zfs/zfs-list.cache
    touch /etc/zfs/zfs-list.cache/bpool
    touch /etc/zfs/zfs-list.cache/rpool
    zed -F &

    umount /boot/efi

    zfs set mountpoint=legacy bpool/BOOT/ubuntu
    echo "bpool/BOOT/ubuntu /boot   zfs     nodev,relatime,x-systemd.requires=zfs-import-bpool.service  0   0" >>/etc/fstab
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
    cat <<EOT >/etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: NetworkManager
EOT
}

tune_zfs_config() {
    # Memory used by ZFS should be limited
    # see https://www.solaris-cookbook.eu/linux/linux-ubuntu/debian-ubuntu-centos-zfs-on-linux-zfs-limit-arc-cache/

    cat <<EOF >/etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=4294967296
EOF
    # see https://serverfault.com/questions/581669/why-isnt-the-arc-max-setting-honoured-on-zfs-on-linux#comment1108614_602457
    refresh_initrd_files
}

snapshot_initial_installation() {
    zfs snapshot bpool/BOOT/ubuntu@current
    zfs snapshot rpool/ROOT/ubuntu@current
}

main() {

    update_apt_sources

    configure_locales

    configure_tzdata

    configure_keyboard

    create_efi_filesystem

    install_base_packages

    configure_tmpfs_for_tmp

    setup_system_groups

    refresh_initrd_files

    update_grub_config

    install_boot_loader

    #fix_filesystem_mount_ordering

    #create_user

    #full_install

    #clean_some_stuff

    #configure_network

    #tune_zfs_config

    #snapshot_initial_installation
}

main
