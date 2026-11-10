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

# 同一寄存器连读 3 次取众数（3 次都不一致时取第 1 次）。
# 为什么需要：插排没接市电时芯片不进计量，MISO 上是浮空噪声 ——
# 单次读会在 000000000000 和 409500080000 之间乱跳，画面就会忽而 0.00 忽而天文数字。
# 3 次里两次一致才算可信，能把绝大多数毛刺压掉。
rd_mode3() {   # $1=dev $2=cmd（如 w70,00）
  a=$(spi_rx "$1" "$2" r6); b=$(spi_rx "$1" "$2" r6); c=$(spi_rx "$1" "$2" r6)
  if [ "$a" = "$b" ] || [ "$a" = "$c" ]; then printf '%s\n' "$a"
  elif [ "$b" = "$c" ]; then printf '%s\n' "$b"
  else printf '%s\n' "$a"; fi
}

wr_sw() {   # $1=dev $2=0|1
  # ⚠ 极性是**反的**（2026-11-10 真机实测，与反汇编注释相反）：
  #   0x380F=0x00 → 继电器闭合（RST 后的默认态，实测输出端 225V）
  #   0x380F=0x20 → 继电器断开（实测输出端 0V）
  # 所以"开"写 00、"关"写 20。
  d=20; [ "$2" = "1" ] && d=00
  # ⚠ 末尾绝对不能带 r1！写事务后面再挂一个读阶段，会把刚写进去的值冲掉
  #   （实测「wB8,0F,20 r1」写完回读恒为 00）。
  spitest "$1" 125000 "wB8,0F,$d" > /dev/null 2>&1
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

# ---------- 换算（原厂 pl7223_calcuate_value：u48 小端 / 2^n） ----------
# conv <hex串> <shift> → 4 位小数
# ⚠ 两个坑都在这一行里（2026-11-10 真机踩实）：
#  1) 字节序是**小端**，末字节才是 MSB。按大端算会把 224V 算成 3400 万伏，
#     再被量程检查一挡，网页上就只剩 "--"。实测 `830800380000` → 0x000038000883
#     ÷ 2^22 = 224.0V ✓（11-09 的 cs7 实测表也是小端）。
#  2) spi_rx 已把字节间空格 tr 掉，进来的是一个 12 字符整串。旧实现
#     `for(i=1;i<=NF;i++) v=v*256+$i` 对整串做十进制转换 → 值完全错，大数还出 inf。
# 所以改为逐字符取 nibble、从串尾往前按 2 位一组累加。u48 只有 48 位，
# double 的 53 位尾数装得下，不丢精度，也不依赖 shell 的整数宽度（ar9331 是 32 位 MIPS）。
conv() {
  printf '%s' "$1" | awk -v s="$2" '
    { gsub(/[ \t\r\n]/, ""); h = tolower($0) }
    END {
      L = length(h)
      if (L != 12 && L != 8) { print "0.0000"; exit }   # 只接受 6 字节 / 4 字节
      n = 0
      for (i = L - 2; i >= 0; i -= 2) {         # 从末字节（MSB）开始往前
        d1 = index("0123456789abcdef", substr(h, i + 1, 1)) - 1
        d2 = index("0123456789abcdef", substr(h, i + 2, 1)) - 1
        if (d1 < 0 || d2 < 0) { print "0.0000"; exit }
        n = n * 256 + (d1 * 16 + d2)
      }
      printf "%.4f", n / (2 ^ s)
    }'
}

# 量程合理性检查：0 ≤ 值 ≤ 上限
in_range() { awk -v x="$1" -v hi="$2" 'BEGIN { exit !(x + 0 >= 0 && x + 0 <= hi) }'; }

# 三个原始读数 → "v|a|w"；任一超量程或缺失则整孔作废（"||"）
# 为什么要卡量程：芯片没接市电时 MISO 上是噪声，会读出 10^7 V 这种值，
# 直接显示会变成一串天文数字。卡掉后前端按"未知"显示 "--"，语义更诚实。
calc3() {   # $1=电压原始 $2=电流原始 $3=功率原始
  if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then printf '||\n'; return; fi
  v=$(conv "$1" 22); a=$(conv "$2" 24); w=$(conv "$3" 24)
  # 超量程时改用「低 4 字节」重算：实测 6 字节读的第 5/6 字节经常是读残渣
  # （例如电流读出 200000008000，第 5 字节 0x80 把它顶成 10^12 级），
  # 而低 4 字节是干净的。小端串的低 4 字节就是前 8 个字符。
  if ! ( in_range "$v" 400 && in_range "$a" 100 && in_range "$w" 22000 ); then
    v=$(conv "${1%????}" 22); a=$(conv "${2%????}" 24); w=$(conv "${3%????}" 24)
  fi
  ok=1
  in_range "$v" 400 || ok=0
  in_range "$a" 100 || ok=0
  in_range "$w" 22000 || ok=0
  if [ "$ok" = "1" ]; then
    printf '%s|%s|%s\n' "$v" "$a" "$w"
  else
    printf '||\n'
  fi
}

# 孔号 → spidev 设备
spid_of() { case "$1" in 1) echo $SPID1;; 2) echo $SPID2;; 3) echo $SPID3;; esac; }

# 读一个孔的计量 → "v|a|w"（失败为 "||"）
# 调用方负责持锁与 iso（P0）状态；孔1 的 CS 窗口在本函数内部自管。
measure1() {   # $1=孔号
  d=$(spid_of "$1")
  [ "$1" = "1" ] && cs17_lo
  calc3 "$(rd_u "$d")" "$(rd_i "$d")" "$(rd_p "$d")"
  [ "$1" = "1" ] && cs17_hi
}

# 一个完整的「RST + 读某孔计量」：这是唯一能拿到真实 V/A/W 的路径。
# ⚠ 读之前**不要**写 0x380F —— 写事务会把计量寄存器打成 0.8A/16W 这种假值
#   （实测：只 RST 读到 I≈0/P=1.8W；RST 后再写一次 0x380F 就变成 I=0.8A/P=16W）。
#   所以调用方必须「先读、读完再 rewrite_states 恢复开关状态」。
read_one() {   # $1=孔号
  wake_all
  pca_wr 0x01
  measure1 "$1"
}

# 从旧快照里取某孔的计量列（"v|a|w"，没有则 "||"）
old_meas() {   # $1=孔号
  awk -F'|' -v n="$1" '$1 == n { printf "%s|%s|%s\n", $3, $4, $5 }' $SNAP 2>/dev/null
}

# 0x380F 回读值 → 0/1；读不到返回 "-"（极性反：bit5=0 才是 ON）
sw_of() {
  case "$1" in
    ""|*[!0-9A-Fa-f]*) echo "-"; return ;;
  esac
  [ $(( 0x$1 & 0x20 )) -eq 0 ] && echo 1 || echo 0
}

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

  # 真实开关状态以状态文件为准：0x380F 写不进"开"（回读恒 00），只能当断开用。
  read s1 s2 s3 < $STATE 2>/dev/null
  [ -n "$s1" ] || s1=0; [ -n "$s2" ] || s2=0; [ -n "$s3" ] || s3=0

  o1=""; o2=""; o3=""
  # ⚠ 每个孔都必须单独 RST 一次 —— 这是最反直觉但实测唯一有效的做法：
  #   芯片在一次 SPI 事务（CS 拉高）后就进待机，0x3000/0x3006/0x3078 立刻读回 0
  #   或浮空噪声。所以「RST 一次连读三孔」只有第一孔是真的，后面两孔全是假的
  #   （网页上"空载却有 0.8A/16W"就是这么来的）。
  #   代价：live 读要 3 次 RST（约 7 秒），期间三个继电器都会闭合一下，
  #   读完立刻 rewrite_states 恢复目标状态。
  for n in 3 2 1; do
    if [ "$n" = "1" ] && [ "$S1_SPI" != "1" ]; then
      o1="1|$s1|||"   # 孔1 本版不参与 SPI：开关态照状态文件，计量未知
      continue
    fi
    dev=$(spid_of "$n")
    case "$n" in 1) on=$s1;; 2) on=$s2;; 3) on=$s3;; esac
    # 关着的孔不读：继电器断开 → 输出端确实没电，读也只能读到
    # 「RST 把它打开的那一瞬间」的 225V，显示出来反而误导。
    if [ "$on" = "1" ]; then
      mw=$(read_one "$n")
    else
      mw="0.0000|0.0000|0.0000"
    fi
    v=${mw%%|*}; rest=${mw#*|}; a=${rest%%|*}; w=${rest#*|}
    line="$n|$on|$v|$a|$w"
    case "$n" in 1) o1=$line;; 2) o2=$line;; 3) o3=$line;; esac
  done
  rewrite_states        # 读完把该关的孔关回去（RST 会把它们全开）
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

  # —— 控制路径只碰开关，绝不读计量 ——
  # 原因：读计量必须先 RST，而 RST 会把三孔全部复位为闭合，
  # 与"关某个孔"的目标直接冲突；反过来写 0x380F 又会把计量打成假值。
  # 两条路分开走：这里只改开关，计量留给 status?live=1（每孔 RST 一次读完就恢复）。
  echo "$n1 $n2 $n3" > $STATE
  wake_all              # RST → 三孔复位为闭合(00)
  rewrite_states        # 按目标状态写：开=00、关=20
  cs17_hi
  pca_wr 0x01

  # 回读校验（写入已修复 r1 问题，回读值可信；极性反：bit5=0 才是 ON）
  f3=$(sw_of "$(rd_sw "$SPID3")"); [ "$f3" = "-" ] && f3=$n3
  f2=$(sw_of "$(rd_sw "$SPID2")"); [ "$f2" = "-" ] && f2=$n2
  if [ "$S1_SPI" = "1" ]; then
    cs17_lo; f1=$(sw_of "$(rd_sw "$SPID1")"); cs17_hi
    [ "$f1" = "-" ] && f1=$n1
    pca_wr 0x01
  else
    f1=$n1             # 孔1 读写都不通，状态只能记目标值
  fi
  echo "$f1 $f2 $f3" > $STATE

  # 计量沿用旧快照，不在控制路径里现读（现读要么假值要么被 RST 打断）
  ov3=$(old_meas 3); [ -n "$ov3" ] || ov3="||"
  ov2=$(old_meas 2); [ -n "$ov2" ] || ov2="||"
  ov1="||"
  printf '1|%s|%s\n2|%s|%s\n3|%s|%s\n' "$f1" "$ov1" "$f2" "$ov2" "$f3" "$ov3" > $SNAP

  iso_close
  btn_lock_free
  web_lock_free
  printf '%s %s %s\n' "$f1" "$f2" "$f3" >&3
  exec 3>&-
}
