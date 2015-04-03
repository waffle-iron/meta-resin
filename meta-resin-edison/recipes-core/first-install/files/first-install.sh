#!/bin/bash
# first install script to do post flash install

# global variable set to 1 if output is systemd journal
fi_journal_out=0

export PATH="$PATH:/usr/sbin/"

# handle argument, if first-install is called from systemd service
# arg1 is "systemd-service"
if [ "$1" == "systemd-service" ]; then fi_journal_out=1; fi;

#echo function to output to journal system or in colored terminal
#arg $1 message
#arg $2 log level
fi_echo () {
    lg_lvl=${2:-"log"}
    msg_prefix=""
    msg_suffix=""
    case "$lg_lvl" in
        log) if [ $fi_journal_out -eq 1 ]; then msg_prefix="<5>"; else msg_prefix="\033[1m"; msg_suffix="\033[0m"; fi;;
        err) if [ $fi_journal_out -eq 1 ]; then msg_prefix="<1>"; else msg_prefix="\033[31;40m\033[1m"; msg_suffix="\033[0m"; fi;;
    esac
    printf "${msg_prefix}${1}${msg_suffix}\n"
}

# set_retry_count to failure file
# arg $1 new retry count
set_retry_count () {
    fw_setenv first_install_retry $1
}

# get_retry_count from failure from bootloader
get_retry_count () {
    retry_count=$(fw_printenv first_install_retry | tr -d "first_install_retry=")
    [ -z $retry_count ] && { set_retry_count 0; retry_count=0;}
    return $retry_count
}

# exit first_install by rebooting and handling the failure by setting
# the firmware target according to failure or success
# on failure increment fail count and reboot
# on success reboot in multi-user target
# arg $1 exit code
exit_first_install () {
    if [ $1 -eq 0 ]; then
        # reset failure count
        set_retry_count 0
        # update firmware target
        # next reboot will be on multi-user target
        fw_setenv bootargs_target multi-user
    fi

    fi_echo "Rebooting...."
    # dump journal to log file
    journalctl -u first-install -o short-iso >> /first-install.log
    reboot
}

# continue normal flow or exit on error code
# arg $1 : return code to check
# arg $2 : string resuming the action
fi_assert () {
    if [ $1 -ne 0 ]; then
        fi_echo "${2} : Failed ret($1)" err;
        exit_first_install $1;
    else
        fi_echo "${2} : Success";
    fi
}

factory_partition () {
    mkdir -p /factory
    mount /dev/disk/by-partlabel/factory /factory
    # test can fail if done during manufacturing
    if [ $? -ne 0 ];
    then
        mkfs.ext4 /dev/disk/by-partlabel/factory
        mount /dev/disk/by-partlabel/factory /factory
        echo "00:11:22:33:55:66" > /factory/bluetooth_address
        echo "VSPPYWWDXXXXXNNN" > /factory/serial_number
    fi
}

# generate sshd keys
sshd_init () {
    rm -rf  /etc/dropbear/dropbear_rsa_host_key
    systemctl start dropbearkey
}

# script main part

# print to journal the current retry count
get_retry_count
retry_count=$?
set_retry_count $((${retry_count} + 1))
fi_echo "Starting First Install (try: ${retry_count})"

mount /dev/disk/by-partlabel/data_disk /mnt/data-disk
fi_echo "Expanding data_disk to use the entire disk"
btrfs filesystem resize max /mnt/data-disk

mkfs.ext4 -m0 /dev/disk/by-partlabel/update
fi_assert $? "Formatting update-disk for first boot."

# handle factory partition
factory_partition

# ssh
sshd_init
fi_assert $? "Generating sshd keys"

# update entry in /etc/fstab to enable auto mount
sed -i 's/#//g' /etc/fstab
fi_assert $? "Update file system table /etc/fstab"

# Remove the g_multi and kvm-amd modules
rm -rf /etc/modules-load.d/g_multi.conf
rm -rf /etc/modules-load.d/kvm-amd.conf
rm -rf /etc/modprobe.d/g_multi.conf

# Disable busybox service
systemctl disable busybox-syslog.service
# Enable connman service
systemctl enable connman.service

# set API_ENDPOINT and CONFIG_PATH
# file generated by supervisor-init(-dev) recipe
source /etc/resin.conf
export API_ENDPOINT CONFIG_PATH

mount /dev/disk/by-partlabel/boot /boot
cp /boot/config.json $CONFIG_PATH
uuid=$(openssl rand -hex 31)
config_json=`cat $CONFIG_PATH`
echo $config_json | jq ".uuid=\"$uuid\"" > $CONFIG_PATH

#Handle config.json - network config
resin-net-config
sync && sync

fi_echo "First install success"

# end main part
exit_first_install 0
