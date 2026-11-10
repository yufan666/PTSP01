#!/bin/sh
# ptsp01-mqtt.sh —— MQTT 守护：Home Assistant 自动发现 + 命令订阅 + 周期状态上报
#
# 配置 /etc/config/ptsp01（uci-defaults 首次生成）：
#   option server   'MQTT broker IP（如 HA 所在主机，必填，未配则 init 跳过启动）'
#   option port     '1883'
#   option base     'ptsp01'
#   option interval '60'        # 状态上报周期（秒），每轮持锁约 3~4s
#   option username '可选'
#   option password '可选（注意：含空格的密码不支持）'
#
# Topic 布局：
#   <base>/socketN/set     ← 命令 ON/OFF/1/0
#   <base>/socketN/state   → {"state":"ON","v":..,"a":..,"w":..} (retained)
#   <base>/total/state     → {"w":..} (retained)
#   <base>/available       → online/offline
#   homeassistant/{switch,sensor}/ptsp01_*/config → HA 自动发现 (retained)
#
# 并发安全：命令执行与状态读取均走 pl7223.sh 的 web_lock/btn_busy 锁，
# 与网页 CGI、按键守护（btn_guard）互斥排队，不会撞 SPI/i2c。

. /usr/lib/ptsp01/pl7223.sh

HOST=$(uci -q get ptsp01.main.server)
PORT=$(uci -q get ptsp01.main.port); PORT=${PORT:-1883}
BASE=$(uci -q get ptsp01.main.base); BASE=${BASE:-ptsp01}
INTERVAL=$(uci -q get ptsp01.main.interval); INTERVAL=${INTERVAL:-60}
MQUSER=$(uci -q get ptsp01.main.username)
MQPASS=$(uci -q get ptsp01.main.password)

AUTH=""
[ -n "$MQUSER" ] && AUTH="-u $MQUSER -P $MQPASS"

mq_pub() {   # $1=topic $2=payload $3=非空则 retained
  if [ -n "$3" ]; then
    mosquitto_pub -h "$HOST" -p "$PORT" $AUTH -t "$1" -m "$2" -r
  else
    mosquitto_pub -h "$HOST" -p "$PORT" $AUTH -t "$1" -m "$2"
  fi
}

DEV='{"identifiers":["ptsp01"],"name":"PTSP01 插排","manufacturer":"8devices","model":"Carambola2"}'
AVL="\"availability_topic\":\"$BASE/available\""

send_discovery() {
  i=1
  while [ $i -le 3 ]; do
    mq_pub "homeassistant/switch/ptsp01_socket$i/config" \
      "{\"name\":\"插排孔$i\",\"unique_id\":\"ptsp01_socket$i\",\"command_topic\":\"$BASE/socket$i/set\",\"state_topic\":\"$BASE/socket$i/state\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\",\"state_value_template\":\"{{ value_json.state }}\",$AVL,\"device\":$DEV}" r
    mq_pub "homeassistant/sensor/ptsp01_socket${i}_v/config" \
      "{\"name\":\"插排孔$i 电压\",\"unique_id\":\"ptsp01_socket${i}_v\",\"state_topic\":\"$BASE/socket$i/state\",\"value_template\":\"{{ value_json.v }}\",\"unit_of_measurement\":\"V\",\"device_class\":\"voltage\",\"state_class\":\"measurement\",$AVL,\"device\":$DEV}" r
    mq_pub "homeassistant/sensor/ptsp01_socket${i}_a/config" \
      "{\"name\":\"插排孔$i 电流\",\"unique_id\":\"ptsp01_socket${i}_a\",\"state_topic\":\"$BASE/socket$i/state\",\"value_template\":\"{{ value_json.a }}\",\"unit_of_measurement\":\"A\",\"device_class\":\"current\",\"state_class\":\"measurement\",$AVL,\"device\":$DEV}" r
    mq_pub "homeassistant/sensor/ptsp01_socket${i}_w/config" \
      "{\"name\":\"插排孔$i 功率\",\"unique_id\":\"ptsp01_socket${i}_w\",\"state_topic\":\"$BASE/socket$i/state\",\"value_template\":\"{{ value_json.w }}\",\"unit_of_measurement\":\"W\",\"device_class\":\"power\",\"state_class\":\"measurement\",$AVL,\"device\":$DEV}" r
    i=$(( i + 1 ))
  done
  mq_pub "homeassistant/sensor/ptsp01_total/config" \
    "{\"name\":\"插排总功率\",\"unique_id\":\"ptsp01_total_w\",\"state_topic\":\"$BASE/total/state\",\"value_template\":\"{{ value_json.w }}\",\"unit_of_measurement\":\"W\",\"device_class\":\"power\",\"state_class\":\"measurement\",$AVL,\"device\":$DEV}" r
}

publish_states() {
  LINES=$(read_all_raw)
  echo "$LINES" | while IFS='|' read n on v a w; do
    st=OFF; [ "$on" = "1" ] && st=ON
    mq_pub "$BASE/socket$n/state" \
      "{\"state\":\"$st\",\"v\":${v:-null},\"a\":${a:-null},\"w\":${w:-null}}" r
  done
  T=$(echo "$LINES" | awk -F'|' '$3 != "" { t += $5 } END { printf "%.2f", t }')
  mq_pub "$BASE/total/state" "{\"w\":$T}" r
}

handle_cmd() {   # $1=topic $2=payload
  case "$1" in
    "$BASE/socket1/set") n=1 ;;
    "$BASE/socket2/set") n=2 ;;
    "$BASE/socket3/set") n=3 ;;
    *) return ;;
  esac
  case "$2" in
    ON|On|on|1) st=1 ;;
    OFF|Off|off|0) st=0 ;;
    *) return ;;
  esac
  do_switch "$n" "$st" > /dev/null || return
  publish_states
}

subscribe_loop() {
  while :; do
    mosquitto_sub -h "$HOST" -p "$PORT" $AUTH \
      -t "$BASE/socket1/set" -t "$BASE/socket2/set" -t "$BASE/socket3/set" -v 2>/dev/null |
    while read -r topic payload; do
      handle_cmd "$topic" "$payload"
    done
    sleep 5    # 断线后 5s 重连
  done
}

# ---------- 主流程 ----------
mq_pub "$BASE/available" online r
send_discovery
publish_states

subscribe_loop &
SUB_PID=$!
trap 'kill $SUB_PID 2>/dev/null' TERM INT

while :; do
  sleep "$INTERVAL"
  kill -0 $SUB_PID 2>/dev/null || { subscribe_loop & SUB_PID=$!; }
  publish_states
done
