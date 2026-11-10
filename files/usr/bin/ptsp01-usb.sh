#!/bin/sh
# ptsp01-usb.sh —— USB 子系统状态（网页 CGI 与命令行共用）
#
# 用法：
#   ptsp01-usb.sh status   -> JSON：{wan, storage, serial, devices}
#   ptsp01-usb.sh list     -> 人类可读清单（SSH 里看）
#
# 数据来源（全部实时读，无状态文件，除了 USB 上行的守护输出 /tmp/ptsp01-usbwan.json）：
#   · USB 上网：ptsp01-usbwan.sh 写的 /tmp/ptsp01-usbwan.json
#   · U 盘：/proc/mounts 里挂载点以 /mnt/usb 开头的项 + df
#   · 串口：/sys/class/tty/ttyUSB* / ttyACM* 及其 driver
#   · 设备：/sys/bus/usb/devices/* 的 idVendor/idProduct/product/speed

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n' | cut -c1-64; }

wan_key() {
	[ -f /tmp/ptsp01-usbwan.json ] || return 0
	sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' /tmp/ptsp01-usbwan.json | head -1
}

collect_wan() {
	W_IF=$(wan_key iface); W_IP=$(wan_key ip); W_GW=$(wan_key gw); W_ST=$(wan_key state)
	[ -n "$W_ST" ] || W_ST="unknown"
}

collect_storage() {
	ST=""
	for m in $(awk '$2 ~ /^\/mnt\/usb/ {print $2}' /proc/mounts); do
		dev=$(awk -v m="$m" '$2==m{print $1; exit}' /proc/mounts)
		fs=$(awk -v m="$m" '$2==m{print $3; exit}' /proc/mounts)
		set -- $(df -k "$m" 2>/dev/null | awk 'NR==2{print $2, $3}')
		ST="$ST${ST:+,}{\"dev\":\"$(jesc "$dev")\",\"mnt\":\"$(jesc "$m")\",\"fs\":\"$(jesc "$fs")\",\"size_kb\":${1:-0},\"used_kb\":${2:-0}}"
	done
}

collect_serial() {
	SE=""
	for t in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
		[ -e "$t" ] || continue
		n=${t##*/}
		drv=$(readlink -f "$t/device/driver" 2>/dev/null); drv=${drv##*/}
		SE="$SE${SE:+,}{\"dev\":\"/dev/$n\",\"driver\":\"$(jesc "$drv")\"}"
	done
}

collect_devices() {
	DV=""
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		vid=$(cat "$d/idVendor" 2>/dev/null)
		pid=$(cat "$d/idProduct" 2>/dev/null)
		prod=$(cat "$d/product" 2>/dev/null)
		spd=$(cat "$d/speed" 2>/dev/null)
		DV="$DV${DV:+,}{\"id\":\"$(jesc "$vid:$pid")\",\"name\":\"$(jesc "$prod")\",\"speed\":\"$(jesc "$spd")\",\"port\":\"$(jesc "${d##*/}")\"}"
	done
}

cmd_status() {
	collect_wan; collect_storage; collect_serial; collect_devices
	printf '{"wan":{"iface":"%s","ip":"%s","gw":"%s","state":"%s"},"storage":[%s],"serial":[%s],"devices":[%s]}\n' \
		"$(jesc "$W_IF")" "$(jesc "$W_IP")" "$(jesc "$W_GW")" "$(jesc "$W_ST")" \
		"$ST" "$SE" "$DV"
}

cmd_list() {
	collect_wan; collect_storage; collect_serial; collect_devices
	echo "USB 上行 : ${W_ST:-unknown} ${W_IF:+iface=$W_IF} ${W_IP:+ip=$W_IP} ${W_GW:+gw=$W_GW}"
	echo "U 盘/存储:"
	[ -n "$ST" ] || echo "  （无）"
	for m in $(awk '$2 ~ /^\/mnt\/usb/ {print $2}' /proc/mounts); do
		dev=$(awk -v m="$m" '$2==m{print $1; exit}' /proc/mounts)
		fs=$(awk -v m="$m" '$2==m{print $3; exit}' /proc/mounts)
		info=$(df -h "$m" 2>/dev/null | awk 'NR==2{print $2" 总 / "$4" 可用"}')
		echo "  $dev -> $m ($fs, $info)"
	done
	echo "串口:"
	[ -n "$SE" ] || echo "  （无）"
	for t in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
		[ -e "$t" ] || continue
		drv=$(readlink -f "$t/device/driver" 2>/dev/null); drv=${drv##*/}
		echo "  /dev/${t##*/}  ($drv)"
	done
	echo "USB 设备:"
	[ -n "$DV" ] || echo "  （无）"
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		echo "  $(cat "$d/idVendor"):$(cat "$d/idProduct")  $(cat "$d/product" 2>/dev/null)"
	done
}

case "$1" in
	status) cmd_status ;;
	list|"") cmd_list ;;
	*) echo "用法: $0 {status|list}"; exit 1 ;;
esac
