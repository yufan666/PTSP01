#!/bin/sh
# pl7223.sh —— PTSP01 三孔 PL7223 共享协议库（网页 CGI 与 btn_action 共用配方）
#
# 硬件配方来源：btn_action.sh / cs37 系列实证（2026-11-10）
#  - 孔1 CS=GPIO17（与 i2c SDA 共线，devmem OE 位带控制）  spidev0.3
#  - 孔2 CS=GPIO1                                          spidev0.2
#  - 孔3 CS=GPIO26                                         spidev0.1
#  - RST=GPIO14（gpio526），正常工作态为低
#  - PCA9554A@0x38：P0=隔离芯片使能（SPI 通信需 P0=1，GPIO17 须为高）
#  - 写事务需 P0=1；GPIO17 拉低期间禁止内核 i2c 活动（SDA 冲突）→ 全程持锁
#  - 0x380F：写 0x20=ON、0x00=OFF；bit5=0x20 即 ON
#  - RST 脉冲会把 CS 为高的芯片踢出 MCU 模式且三孔 0x380F 复位为 OFF
#    → 唤醒后必须按状态文件重写全部三孔
#
# 状态文件 /tmp/socket_state 内容 "S1 S2 S3"（各 0|1），缺省全 0
# 锁约定：
#  - /tmp/btn_busy（文件）：与 btn_guard/btn_action 共享的"内核 i2c 危险区"标志
#  - /tmp/web_lock（目录）：本库调用方（CGI）之间的串行化锁（mkdir 原子）

OE=0x18040000
OUTR=0x18040008
RSTV=/sys/class/gpio/gpio526/value
STATE=/tmp/socket_state
SNAP=/tmp/socket_data      # status CGI 的快照（"n|on|v|a|w" 三行），网页默认读它
LOCK=/tmp/btn_busy
WEBLOCK=/tmp/web_lock

SPID1=/dev/spidev0.3   # 孔1（GPIO17）
SPID2=/dev/spidev0.2   # 孔2（GPIO1）
SPID3=/dev/spidev0.1   # 孔3（GPIO26）

# 孔1 是否允许走 SPI 事务（默认关）。
# 原因（2026-11-10 真机实测）：当前 DTS 把 spidev0.3 的片选指到 PCA9554 P1，
# 内核每次事务都要经 i2c 写 P1；而孔1 真正的片选是 GPIO17，它同时是 i2c 的 SDA
# —— GPIO17 一拉低，i2c 立刻死，内核 gpiod 操作超时，连带 PCA 的 P0（隔离使能）
# 一起丢，于是后面的孔全部读不到。实测：不碰孔1 时孔2/孔3 读写完全正常；
# 一旦插入孔1 事务，三孔全部返回 0。
# 修复后（DTS 把 cs-gpios[3] 改成 <0>，让内核只写无引脚的 IOC bit19）再置 1。
S1_SPI=${PTSP01_S1_SPI:-0}

ensure_state() { [ -f $STATE ] || echo "0 0 0" > $STATE; }

# ---------- GPIO OE/OUT 位带（孔1 CS=GPIO17 与 孔2/3 CS） ----------
# 注意：自研 /usr/bin/devmem 读**和写**都会打印 "0xADDR = 0xVAL (DEC)"，
# 写操作必须重定向，否则输出会污染调用方（CGI/MQTT 的 JSON 直接崩）
getv() { v=$(devmem $1 2>/dev/null); v=${v#*= }; v=${v%% *}; printf '%s\n' "$v"; }
wrm() { devmem "$1" 32 "$2" >/dev/null 2>&1; }
cs17_hi() { v=$(getv $OE); m=$(( -1 - 0x20000 )); wrm $OE $(( $v & $m )); }
cs17_lo() { v=$(getv $OE); wrm $OE $(( $v | 0x20000 )); }
c23_lo() { v=$(getv $OUTR); m1=$(( -1 - 0x2 )); m2=$(( -1 - 0x4000000 )); wrm $OUTR $(( $v & $m1 & $m2 )); }
c23_hi() { v=$(getv $OUTR); wrm $OUTR $(( $v | 0x2 | 0x4000000 )); }

# ---------- raw i2c 位带写 PCA9554A（SCL=GPIO11 SDA=GPIO17） ----------
oeinit() { v=$(getv $OE); wrm $OE $(( $v | 0x20800 )); }
sclahi() { v=$(getv $OUTR); wrm $OUTR $(( $v | 0x800 )); }
sclalo() { v=$(getv $OUTR); m=$(( -1 - 0x800 )); wrm $OUTR $(( $v & $m )); }
sdahi_o() { v=$(getv $OE); m=$(( -1 - 0x20000 )); wrm $OE $(( $v & $m )); }
sdalo() { v=$(getv $OE); wrm $OE $(( $v | 0x20000 )); }
i2c_start() { sclahi; sdahi_o; sdalo; sclalo; }
i2c_stop() { sclalo; sdalo; sclahi; sdahi_o; }
i2c_bit() { if [ $1 -eq 1 ]; then sdahi_o; else sdalo; fi; sclahi; sclalo; }
i2c_ack() { sdahi_o; sclahi; sclalo; sdalo; }
i2c_byte() { b=$1; k=7; while [ $k -ge 0 ]; do i2c_bit $(( (b >> k) & 1 )); k=$(( k - 1 )); done; i2c_ack; }
pca_wr() { i2c_start; i2c_byte 0x70; i2c_byte 0x01; i2c_byte $1; i2c_stop; }

# ---------- 环境与锁 ----------
prep_env() {
  [ -d /sys/class/gpio/gpio526 ] || echo 526 > /sys/class/gpio/export
  echo out > /sys/class/gpio/gpio526/direction
  echo 0 > $RSTV
  oeinit
}

# ⚠ busybox 的 sleep 只吃整数（`sleep 0.2` 会打 "invalid number" 并立刻返回），
#   所以所有等待一律用整数秒；拿锁先直接抢，抢不到才退避，正常路径零延迟。
web_lock_take() {
  mkdir $WEBLOCK 2>/dev/null && return 0
  i=0
  while [ $i -lt 25 ]; do          # 25s 超时
    i=$(( i + 1 ))
    sleep 1
    mkdir $WEBLOCK 2>/dev/null && return 0
  done
  return 1
}
web_lock_free() { rmdir $WEBLOCK 2>/dev/null; }

btn_lock_take() {   # 等 btn_guard 本轮 i2c 采样结束后占据危险区
  i=0
  while [ -e $LOCK ]; do
    i=$(( i + 1 ))
    [ $i -gt 10 ] && break
    sleep 1
  done
  touch $LOCK
}
btn_lock_free() { rm -f $LOCK; }

# ---------- 隔离与唤醒 ----------
iso_open()  { cs17_hi; pca_wr 0x01; }   # P0=1 打开隔离路径（GPIO17 须为高）
iso_close() { cs17_hi; pca_wr 0x02; }   # P0=0 关闭

# 联合唤醒：P0=1 → 三CS全低 → RST 脉冲 → 释放孔2/3 CS
# 副作用：三孔 0x380F 全部复位为 OFF，调用后必须 rewrite_states
wake_all() {
  cs17_hi
  pca_wr 0x01
  cs17_lo
  c23_lo
  echo 1 > $RSTV; sleep 1
  echo 0 > $RSTV; sleep 1
  c23_hi
}

# ---------- SPI 事务（spidev，125kHz） ----------
spi_rx() {   # $1=dev，其余=cmd 参数；输出 "XX XX ..."（rx 字节），失败输出空
  dev=$1; shift
  # 一次 spitest 会打印多行 rx（写阶段的 rx(n) + 读阶段的 rx(m)），
  # 只取**最后一行**才是真正的读结果；否则字节数翻倍，换算会算出天文数字。
  # sed 剥掉 "rx(n):" 前缀后仍留前导空格，必须 tr 掉，否则 0x$sw → "0x 20" 报错。
  spitest "$dev" 125000 "$@" 2>/dev/null | sed -n 's/^rx([0-9]*)://p' | tail -n 1 | tr -d ' \r\n'
}

rd_id() { spi_rx "$1" w78,60 r1; }        # 0x3860 → 期望 04
rd_sw() { spi_rx "$1" w78,0F r1; }        # 0x380F → bit5(0x20)=ON
rd_u()  { spi_rx "$1" w70,00 r6; }        # 0x3000 电压
rd_i()  { spi_rx "$1" w70,06 r6; }        # 0x3006 电流
rd_p()  { spi_rx "$1" w70,78 r6; }        # 0x3078 功率

wr_sw() {   # $1=dev $2=0|1
  d=00; [ "$2" = "1" ] && d=20
  spi_rx "$1" wB8,0F,$d r1 > /dev/null
}

# 按状态文件重写三孔（唤醒后必调）；顺序 孔3→孔2→孔1（GPIO17 窗口最短）
rewrite_states() {
  ensure_state
  read s1 s2 s3 < $STATE
  wr_sw "$SPID3" "$s3"
  wr_sw "$SPID2" "$s2"
  if [ "$S1_SPI" = "1" ]; then
    cs17_lo; wr_sw "$SPID1" "$s1"; cs17_hi
    pca_wr 0x01
  fi
}

# ---------- 换算（同 decode_plt.py：u48 大端 / 2^n） ----------
# conv <"b0 b1 ... b5"> <shift> → 4 位小数
conv() {
  echo "$1" | awk -v s="$2" '{
    v=0; for(i=1;i<=NF;i++) v=v*256+$i
    printf "%.4f", v/(2^s)
  }'
}

# 孔号 → spidev 设备
spid_of() { case "$1" in 1) echo $SPID1;; 2) echo $SPID2;; 3) echo $SPID3;; esac; }

# ---------- 上层编排（网页 CGI / MQTT 守护共用，单一事实来源） ----------

# 读三孔完整状态（免唤醒优先，ID 校验失败自动唤醒+按状态文件恢复）
# 输出 3 行 "id|on|v|a|w"（on=0|1；on 为空=通信失败；v/a/w 为空=计量读取失败）
read_all_raw() {
  # 结果只从 fd3 输出：内部任何漏网的 stdout（devmem/spitest 残留打印）都进 stderr，
  # 保证调用方拿到的永远是干净的 "n|on|v|a|w" 三行
  exec 3>&1 1>&2
  ensure_state
  if ! web_lock_take; then
    printf '1|||\n2|||\n3|||\n' >&3
    exec 3>&-
    return
  fi
  btn_lock_take
  prep_env

  probe_id() {   # $1=孔号 → ID 字节（孔1 事务须手动包 GPIO17）
    dev=$(spid_of "$1")
    [ "$1" = "1" ] && cs17_lo
    r=$(rd_id "$dev")
    [ "$1" = "1" ] && cs17_hi
    echo "$r"
  }

  reachable=1
  iso_open
  # probe 顺序 3→2→1：GPIO17 窗口最后开（见 do_switch 同理）
  for n in 3 2 1; do
    [ "$n" = "1" ] && [ "$S1_SPI" != "1" ] && continue
    [ "$(probe_id $n)" = "04" ] || reachable=0
  done

  if [ "$reachable" = "0" ] || [ -f /tmp/ptsp01_wake_always ]; then
    wake_all
    rewrite_states
    pca_wr 0x01     # 重开 P0=1（孔1 窗口可能已把它带掉）
  fi

  o1=""; o2=""; o3=""
  for n in 3 2 1; do          # 读顺序同为 3→2→1，输出仍按 1/2/3 归位
    if [ "$n" = "1" ] && [ "$S1_SPI" != "1" ]; then
      o1="1|||"               # 孔1 本版不参与 SPI，按"未知"上报
      continue
    fi
    dev=$(spid_of "$n")
    [ "$n" = "1" ] && cs17_lo
    sw=$(rd_sw "$dev")
    uv=$(rd_u "$dev"); iv=$(rd_i "$dev"); pv=$(rd_p "$dev")
    [ "$n" = "1" ] && cs17_hi

    on=""
    if [ -n "$sw" ]; then
      case "$sw" in
        *[!0-9A-Fa-f]*) ;;                        # 非纯十六进制 → 视为通信失败
        *) [ $(( 0x$sw & 0x20 )) -ne 0 ] && on=1 || on=0 ;;
      esac
    fi
    v=""; a=""; w=""
    if [ -n "$uv" ] && [ -n "$iv" ] && [ -n "$pv" ]; then
      v=$(conv "$uv" 22); a=$(conv "$iv" 24); w=$(conv "$pv" 24)
    fi
    line="$n|$on|$v|$a|$w"
    case "$n" in 1) o1=$line;; 2) o2=$line;; 3) o3=$line;; esac
  done
  printf '%s\n%s\n%s\n' "$o1" "$o2" "$o3" > $SNAP
  printf '%s\n%s\n%s\n' "$o1" "$o2" "$o3" >&3

  iso_close
  btn_lock_free
  web_lock_free
  exec 3>&-
}

# 控制继电器（完整唤醒协议，btn_action.sh 配方：唤醒会把三孔复位 OFF →
# 统一重写三孔 → 回读校验 → 落盘状态文件）
# $1=1|2|3|all  $2=0|1（目标状态）
# 成功输出 "f1 f2 f3"（回读后的真实状态）；web_lock 超时返回 1
do_switch() {
  # 同 read_all_raw：结果只从 fd3 出，内部打印全部改走 stderr
  exec 3>&1 1>&2
  ID=$1; ST=$2
  ensure_state
  web_lock_take || { exec 3>&-; return 1; }
  btn_lock_take
  prep_env

  read s1 s2 s3 < $STATE
  n1=$s1; n2=$s2; n3=$s3
  case "$ID" in
    1) n1=$ST;;
    2) n2=$ST;;
    3) n3=$ST;;
    all) n1=$ST; n2=$ST; n3=$ST;;
  esac

  wake_all
  echo "0 0 0" > $STATE
  cs17_hi
  wr_sw "$SPID3" "$n3"
  wr_sw "$SPID2" "$n2"
  if [ "$S1_SPI" = "1" ]; then
    cs17_lo; wr_sw "$SPID1" "$n1"; cs17_hi
    pca_wr 0x01     # 孔1 窗口用掉了 SDA，P0 隔离使能可能已丢，必须重开再做回读
  fi

  # 回读：孔3/孔2 在前，孔1 最后。
  # ⚠ GPIO17 拉低期间 i2c（SDA）不可用，而 PCA P0=隔离使能要靠 i2c 维持；
  #   所以孔1 的窗口必须最后开，开完立刻恢复，否则后面的孔全部读不到。
  r3v=$(rd_sw "$SPID3")
  r2v=$(rd_sw "$SPID2")
  if [ "$S1_SPI" = "1" ]; then
    cs17_lo; r1v=$(rd_sw "$SPID1"); cs17_hi
    pca_wr 0x01
  else
    r1v=""
  fi
  sw_of() {
    case "$1" in
      ""|*[!0-9A-Fa-f]*) echo "-"; return ;;
    esac
    [ $(( 0x$1 & 0x20 )) -ne 0 ] && echo 1 || echo 0
  }
  f1=$(sw_of "$r1v"); [ "$f1" = "-" ] && f1=$n1   # 孔1 读不到时沿用目标值（本版不参与 SPI）
  f2=$(sw_of "$r2v"); f3=$(sw_of "$r3v")
  [ "$f2" = "-" ] && f2=$n2
  [ "$f3" = "-" ] && f3=$n3
  echo "$f1 $f2 $f3" > $STATE
  # 快照只带开关状态（计量留空 = 前端显示 "--"）：控制路径要快，
  # 真读电压电流还要 9 次 SPI 事务，等用户主动刷新时再取。
  printf '1|%s|||\n2|%s|||\n3|%s|||\n' "$f1" "$f2" "$f3" > $SNAP

  iso_close
  btn_lock_free
  web_lock_free
  printf '%s %s %s\n' "$f1" "$f2" "$f3" >&3
  exec 3>&-
}
