#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

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
}

clean_itself() {
    rm /usr/local/first-boot.sh
}

main() {
    configure_keyboard

    clean_itself
}

main