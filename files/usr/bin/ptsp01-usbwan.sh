#!/bin/sh
# ptsp01-usbwan.sh —— USB 上行守护（随身 WiFi / USB 网卡）
#
# 背景（2026-11-08 原厂内核实测，详见项目记忆）：
#   · 插排 USB 口数据线完好：U盘(high-speed)、CH340(full-speed) 均正常枚举
#   · 随身WiFi 直插失败：高速 chirp 握手瞬间大电流把口电压拉垮（0.16s 内 unable to enumerate）
#     → 必须用有源 USB HUB（实测 Hub 下 中兴 19d2:0536 / RTL8152 / CH340 全部枚举成功）
#   · 原厂 3.3.8 上 usbnet 数据面一 up 就整机失联（EHCI DMA 问题）；
#     新固件 6.12 走 chipidea 栈（完全不同的 DMA 通路），只能上机实测
#
# 配置（/etc/config/ptsp01，uci-defaults 生成骨架）：
#   option usbwan         '1'    -> 0 = 关闭守护
#   option usbwan_metric  '300'  -> 默认路由 metric（比主 WAN 差 = 仅作备份）；0 = 不加默认路由
#   option usbwan_iface   ''     -> 强制指定接口名；留空 = 自动探测
#
# 状态：/tmp/ptsp01-usbwan.json   日志：/tmp/ptsp01-usbwan.log

STATE=/tmp/ptsp01-usbwan.json
LOG=/tmp/ptsp01-usbwan.log

log() {
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
	if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 32768 ]; then
		tail -c 16384 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
}

cfg() { uci -q get "ptsp01.main.$1"; }

write_state() {  # $1=iface $2=ip $3=gw $4=state
	printf '{"iface":"%s","ip":"%s","gw":"%s","state":"%s","ts":%s}\n' \
		"$1" "$2" "$3" "$4" "$(date +%s)" > "$STATE"
}

# 探测“挂在 USB 总线上的网卡”：usbnet 生成的接口，sysfs device 路径必含 /usbN
usb_netdevs() {
	for d in /sys/class/net/*; do
		[ -e "$d/device" ] || continue
		p=$(readlink -f "$d/device" 2>/dev/null) || continue
		case "$p" in
			*/usb*) echo "${d##*/}" ;;
		esac
	done
}

ip4_of() { ip -4 -o addr show dev "$1" 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}'; }
gw_of()  { ip route show dev "$1" 2>/dev/null | awk '/^default/{print $3; exit}'; }

# ---------- 把 USB 上行接口挂进 firewall 的 wan 区 ----------
# 这个接口是本脚本手工配地址的（不走 netifd），firewall4 的 zone 按 network
# 名根本找不到它 —— 不挂进 wan 区就没有 masq，电脑接网口能拿到 IP 却上不了网。
# 按 device 点名挂进去，NAT 才成立。只在设备变化时 reload 一次。
FW_DEV=/tmp/ptsp01-usbwan.fwdev

fw_zone_attach() {   # $1 = 接口名
	[ "$(cat $FW_DEV 2>/dev/null)" = "$1" ] && return 0
	uci -q get firewall >/dev/null 2>&1 || return 0

	idx=""; i=0
	while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
		if [ "$(uci -q get "firewall.@zone[$i].name")" = "wan" ]; then idx=$i; break; fi
		i=$((i + 1))
		[ $i -gt 16 ] && break
	done
	[ -n "$idx" ] || return 0

	uci -q del_list "firewall.@zone[$idx].device=$1"
	uci -q add_list "firewall.@zone[$idx].device=$1"
	uci -q set "firewall.@zone[$idx].masq=1"
	uci -q commit firewall || return 0
	echo "$1" > $FW_DEV
	fw4 reload >/dev/null 2>&1
	log "已把 $1 挂进 wan 区（NAT 生效）"
}

ENABLED=$(cfg usbwan);        ENABLED=${ENABLED:-1}
METRIC=$(cfg usbwan_metric); METRIC=${METRIC:-300}
FORCE=$(cfg usbwan_iface)

log "守护启动 enabled=$ENABLED metric=$METRIC iface=${FORCE:-auto}"

while :; do
	if [ "$ENABLED" = "0" ]; then
		write_state "" "" "" "disabled"
		sleep 15
		continue
	fi

	ifc="$FORCE"
	[ -z "$ifc" ] && ifc=$(usb_netdevs | head -1)

	if [ -z "$ifc" ]; then
		write_state "" "" "" "no-device"
		sleep 6
		continue
	fi

	ip link set "$ifc" up 2>/dev/null

	if [ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)" = "0" ]; then
		write_state "$ifc" "" "" "no-carrier"
		sleep 6
		continue
	fi

	ip4=$(ip4_of "$ifc")
	if [ -z "$ip4" ]; then
		log "$ifc 无地址，发起 DHCP"
		# 用专用回调脚本：只配地址 + 可选低优先级默认路由，绝不抢主 WAN 的 metric 0
		udhcpc -i "$ifc" -q -n -t 4 -T 3 \
			-s /usr/share/ptsp01/udhcpc-usbwan.script >/dev/null 2>&1
		ip4=$(ip4_of "$ifc")
	fi

	if [ -z "$ip4" ]; then
		write_state "$ifc" "" "" "no-ip"
		log "$ifc DHCP 未取到地址"
		sleep 10
		continue
	fi

	gw=$(gw_of "$ifc")
	fw_zone_attach "$ifc"     # 先保证 NAT 通路，再对外报 up
	write_state "$ifc" "$ip4" "$gw" "up"
	sleep 10
done
