#!/bin/sh -e
log="generic-board-startup:"
echo "${log} start"

echo "${log} gpio"
if [ -d /sys/class/gpio/ ] ; then
	/bin/chgrp -R gpio /sys/class/gpio/ || true
	/bin/chmod -R g=u /sys/class/gpio/ || true

	/bin/chgrp -R gpio /dev/gpiochip* || true
	/bin/chmod -R g=u /dev/gpiochip* || true
fi

echo "${log} leds"
if [ -d /sys/class/leds ] ; then
	/bin/chgrp -R gpio /sys/class/leds/ || true
	/bin/chmod -R g=u /sys/class/leds/ || true

	if [ -d /sys/devices/platform/leds/leds/ ] ; then
		/bin/chgrp -R gpio /sys/devices/platform/leds/leds/ || true
		/bin/chmod -R g=u  /sys/devices/platform/leds/leds/ || true
	fi
fi


usb_gadget="/sys/kernel/config/usb_gadget"

#  idVendor           0x1d6b Linux Foundation
#  idProduct          0x0104 Multifunction Composite Gadget
#  bcdDevice            4.04
#  bcdUSB               2.00

usb_idVendor="0x1d6b"
usb_idProduct="0x0104"
usb_bcdDevice="0x0404"
usb_bcdUSB="0x0200"
usb_serialnr="000000"
usb_product="USB Device"

#usb0 mass_storage
usb_ms_cdrom=0
usb_ms_ro=1
usb_ms_stall=0
usb_ms_removable=1
usb_ms_nofua=1

usb_image_file="/var/local/bb_usb_mass_storage.img"

wifi_prefix="BeagleBone"

usb_iserialnumber="1234BBBK5678"
usb_imanufacturer="BeagleBoard.org"
usb_iproduct="BeagleBoneBlack"

board=$(cat /proc/device-tree/model | sed "s/ /_/g" | tr -d '\000')

has_wifi="disable"
cleanup_extra_docs
dnsmasq_usb0_usb1="enable"
usb_iproduct="BeagleBone"

if [ ! "x${usb_image_file}" = "x" ] ; then
	echo "${log} usb_image_file=[`readlink -f ${usb_image_file}`]"
fi

#pre nvmem...
eeprom="/sys/bus/i2c/devices/0-0050/eeprom"
if [ -f ${eeprom} ] && [ -f /usr/bin/hexdump ] ; then
	usb_iserialnumber=$(hexdump -e '8/1 "%c"' ${eeprom} -n 28 | cut -b 17-28)
fi


#mac address:
#cpsw_0_mac = eth0 - wlan0 (in eeprom)
#cpsw_1_mac = usb0 (BeagleBone Side) (in eeprom)
#cpsw_2_mac = usb0 (USB host, pc side) ((cpsw_0_mac + cpsw_2_mac) /2 )
#cpsw_3_mac = wl18xx (AP) (cpsw_0_mac + 3)
#cpsw_4_mac = usb1 (BeagleBone Side)
#cpsw_5_mac = usb1 (USB host, pc side)

mac_address="/proc/device-tree/ocp/ethernet@4a100000/slave@4a100200/mac-address"
if [ -f ${mac_address} ] && [ -f /usr/bin/hexdump ] ; then
	mac_addr0=$(hexdump -v -e '1/1 "%02X" ":"' ${mac_address} | sed 's/.$//')

	#Some devices are showing a blank mac_addr0 [00:00:00:00:00:00], let's fix that up...
	if [ "x${mac_addr0}" = "x00:00:00:00:00:00" ] ; then
		mac_addr0="1C:BA:8C:A2:ED:68"
	fi
else
	#todo: generate random mac... (this is a development tre board in the lab...)
	mac_addr0="1C:BA:8C:A2:ED:68"
fi


run_libcomposite () {
	if [ ! -d /sys/kernel/config/usb_gadget/g_multi/ ] ; then
		echo "${log} Creating g_multi"
		mkdir -p /sys/kernel/config/usb_gadget/g_multi || true
		cd /sys/kernel/config/usb_gadget/g_multi

		echo ${usb_bcdUSB} > bcdUSB
		echo ${usb_idVendor} > idVendor # Linux Foundation
		echo ${usb_idProduct} > idProduct # Multifunction Composite Gadget
		echo ${usb_bcdDevice} > bcdDevice

		#0x409 = english strings...
		mkdir -p strings/0x409

		echo ${usb_iserialnumber} > strings/0x409/serialnumber
		echo ${usb_imanufacturer} > strings/0x409/manufacturer
		echo ${usb_iproduct} > strings/0x409/product

		mkdir -p configs/c.1/strings/0x409
		echo "BeagleBone Composite" > configs/c.1/strings/0x409/configuration

		echo 500 > configs/c.1/MaxPower

		if [ ! "x${USB_NETWORK_RNDIS_DISABLED}" = "xyes" ]; then
			mkdir -p functions/rndis.usb0
			# first byte of address must be even
			echo ${cpsw_2_mac} > functions/rndis.usb0/host_addr
			echo ${cpsw_1_mac} > functions/rndis.usb0/dev_addr

			# Starting with kernel 4.14, we can do this to match Microsoft's built-in RNDIS driver.
			# Earlier kernels require the patch below as a work-around instead:
			# https://github.com/beagleboard/linux/commit/e94487c59cec8ba32dc1eb83900297858fdc590b
			if [ -f functions/rndis.usb0/class ]; then
				echo EF > functions/rndis.usb0/class
				echo 04 > functions/rndis.usb0/subclass
				echo 01 > functions/rndis.usb0/protocol
			fi

			# Add OS Descriptors for the latest Windows 10 rndiscmp.inf
			# https://answers.microsoft.com/en-us/windows/forum/windows_10-networking-winpc/windows-10-vs-remote-ndis-ethernet-usbgadget-not/cb30520a-753c-4219-b908-ad3d45590447
			# https://www.spinics.net/lists/linux-usb/msg107185.html
			echo 1 > os_desc/use
			echo CD > os_desc/b_vendor_code || true
			echo MSFT100 > os_desc/qw_sign
			echo "RNDIS" > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
			echo "5162001" > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id

			mkdir -p configs/c.1
			ln -s configs/c.1 os_desc
			mkdir -p functions/rndis.usb0/os_desc/interface.rndis/Icons
			echo 2 > functions/rndis.usb0/os_desc/interface.rndis/Icons/type
			echo "%SystemRoot%\\system32\\shell32.dll,-233" > functions/rndis.usb0/os_desc/interface.rndis/Icons/data
			mkdir -p functions/rndis.usb0/os_desc/interface.rndis/Label
			echo 1 > functions/rndis.usb0/os_desc/interface.rndis/Label/type
			echo "BeagleBone USB Ethernet" > functions/rndis.usb0/os_desc/interface.rndis/Label/data

			ln -s functions/rndis.usb0 configs/c.1/
		fi

		if [ "x${has_img_file}" = "xtrue" ] ; then
			echo "${log} enable USB mass_storage ${usb_image_file}"
			mkdir -p functions/mass_storage.usb0
			echo ${usb_ms_stall} > functions/mass_storage.usb0/stall
			echo ${usb_ms_cdrom} > functions/mass_storage.usb0/lun.0/cdrom
			echo ${usb_ms_nofua} > functions/mass_storage.usb0/lun.0/nofua
			echo ${usb_ms_removable} > functions/mass_storage.usb0/lun.0/removable
			echo ${usb_ms_ro} > functions/mass_storage.usb0/lun.0/ro
			echo ${actual_image_file} > functions/mass_storage.usb0/lun.0/file

			ln -s functions/mass_storage.usb0 configs/c.1/
		fi

		if [ ! "x${USB_NETWORK_RNDIS_DISABLED}" = "xyes" ]; then
			ln -s configs/c.1 os_desc
			mkdir functions/rndis.usb0/os_desc/interface.rndis/Icons
			echo 2 > functions/rndis.usb0/os_desc/interface.rndis/Icons/type
			echo "%SystemRoot%\\system32\\shell32.dll,-233" > functions/rndis.usb0/os_desc/interface.rndis/Icons/data
			mkdir functions/rndis.usb0/os_desc/interface.rndis/Label
			echo 1 > functions/rndis.usb0/os_desc/interface.rndis/Label/type
			echo "BeagleBone USB Ethernet" > functions/rndis.usb0/os_desc/interface.rndis/Label/data

			ln -s functions/rndis.usb0 configs/c.1/
			usb0="enable"
		fi

		if [ ! "x${USB_NETWORK_CDC_DISABLED}" = "xyes" ]; then
			mkdir -p functions/ecm.usb0
			echo ${cpsw_4_mac} > functions/ecm.usb0/host_addr
			echo ${cpsw_5_mac} > functions/ecm.usb0/dev_addr

			ln -s functions/ecm.usb0 configs/c.1/
			usb1="enable"
		fi

		mkdir -p functions/acm.usb0
		ln -s functions/acm.usb0 configs/c.1/

		#ls /sys/class/udc
		#v4.4.x-ti
		if [ -d /sys/class/udc/musb-hdrc.0.auto ] ; then
			echo musb-hdrc.0.auto > UDC
		else
			#v4.9.x-ti
			if [ -d /sys/class/udc/musb-hdrc.0 ] ; then
				echo musb-hdrc.0 > UDC
			fi
		fi

		echo "${log} g_multi Created"
	else
		echo "${log} FIXME: need to bring down g_multi first, before running a second time."
	fi
}

use_libcomposite () {
	echo "${log} use_libcomposite"
	unset has_img_file
	if [ "x${USB_IMAGE_FILE_DISABLED}" = "xyes" ]; then
		echo "${log} usb_image_file disabled by bb-boot config file."
	elif [ -f ${usb_image_file} ] ; then
		actual_image_file=$(readlink -f ${usb_image_file} || true)
		if [ ! "x${actual_image_file}" = "x" ] ; then
			if [ -f ${actual_image_file} ] ; then
				has_img_file="true"
				test_usb_image_file=$(echo ${actual_image_file} | grep .iso || true)
				if [ ! "x${test_usb_image_file}" = "x" ] ; then
					usb_ms_cdrom=1
				fi
			else
				echo "${log} FIXME: no usb_image_file"
			fi
		else
			echo "${log} FIXME: no usb_image_file"
		fi
	else
		#We don't use a physical partition anymore...
		unset root_drive
		root_drive="$(cat /proc/cmdline | sed 's/ /\n/g' | grep root=UUID= | awk -F 'root=' '{print $2}' || true)"
		if [ ! "x${root_drive}" = "x" ] ; then
			root_drive="$(/sbin/findfs ${root_drive} || true)"
		else
			root_drive="$(cat /proc/cmdline | sed 's/ /\n/g' | grep root= | awk -F 'root=' '{print $2}' || true)"
		fi

		if [ "x${root_drive}" = "x/dev/mmcblk0p1" ] || [ "x${root_drive}" = "x/dev/mmcblk1p1" ] ; then
			echo "${log} FIXME: no valid drive to share over usb"
		else
			actual_image_file="${root_drive%?}1"
		fi
	fi

	#ls -lha /sys/kernel/*
	#ls -lha /sys/kernel/config/*
#	if [ ! -d /sys/kernel/config/usb_gadget/ ] ; then

	echo "${log} modprobe libcomposite"
	modprobe libcomposite || true
	if [ -d /sys/module/libcomposite ] ; then
		run_libcomposite
	else
		if [ -f /sbin/depmod ] ; then
			/sbin/depmod -a
		fi
		echo "${log} ERROR: [libcomposite didn't load]"
	fi
}

use_libcomposite

	echo "${log} running interface usb0"
	/sbin/ifup usb0

	echo "${log} running interface usb1"
	/sbin/ifup usb1

if [ ! "x${USB_NETWORK_DISABLED}" = "xyes" ]; then
	if [ -f /var/lib/misc/dnsmasq.leases ] ; then
		systemctl stop dnsmasq || true
		rm -rf /var/lib/misc/dnsmasq.leases || true
	fi


	if [ "x${dnsmasq_usb0_usb1}" = "xenable" ] ; then
		if [ -d /sys/kernel/config/usb_gadget ] ; then
			if [ -f /var/run/udhcpd.pid ] ; then
				/etc/init.d/udhcpd stop || true
			fi

			# do not write if there is a .SoftAp0 file
			if [ -d /etc/dnsmasq.d/ ] ; then
				echo "${log} dnsmasq: setting up for usb0/usb1"
				systemctl restart dnsmasq || true
			else
				echo "${log} ERROR: dnsmasq is not installed"
			fi
		fi
	fi
fi

echo "${log} init completed"
