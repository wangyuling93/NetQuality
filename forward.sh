#!/usr/bin/env bash
# 去程检测：在 macOS / Linux 本机测「你 → VPS」路径，输出风格接近 NetQuality 回程摘要。
# 用法：
#   bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/forward.sh)
#   bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/forward.sh) 1.2.3.4
set -euo pipefail

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_DIM=$'\033[2m'

TARGET="${1:-}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

is_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]
}

ensure_nexttrace() {
  if command -v nexttrace >/dev/null 2>&1; then
    return 0
  fi
  echo -e "${C_YELLOW}未检测到 nexttrace，正在安装…${C_RESET}"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install nexttrace
  else
    curl -fsSL https://nxtrace.org/nt | bash
  fi
  command -v nexttrace >/dev/null 2>&1 || {
    echo -e "${C_RED}安装 nexttrace 失败，请手动：brew install nexttrace${C_RESET}" >&2
    exit 1
  }
}

warn_proxy() {
  if ifconfig 2>/dev/null | grep -Eq 'inet 198\.18\.|inet 198\.19\.'; then
    echo -e "${C_RED}${C_BOLD}警告：检测到 198.18/19 网卡（多半是代理 TUN）。${C_RESET}"
    echo -e "${C_YELLOW}请先在 Shadowrocket 关闭代理 / 全局路由，或把目标 IP 设为直连，再重跑。${C_RESET}"
    echo
  fi
}

prompt_target() {
  if [[ -n "$TARGET" ]]; then
    return 0
  fi
  echo -ne "${C_CYAN}请输入要测去程的机器 IP：${C_RESET}"
  read -r TARGET </dev/tty || true
  TARGET=$(echo "${TARGET:-}" | tr -d '[:space:]')
  if [[ -z "$TARGET" ]]; then
    echo -e "${C_RED}未输入 IP${C_RESET}" >&2
    exit 1
  fi
}

run_trace() {
  local ip="$1"
  local out="$2"
  local err="$3"
  local mode="$4" # tcp|icmp
  local -a args=(-q 3 -g cn --raw -m 30)

  if [[ "$mode" == "tcp" ]]; then
    args+=(-T -p 80 --psize 1400)
  fi
  if [[ "$ip" == *:* ]]; then
    args+=(-6)
  else
    args+=(-4)
  fi
  args+=("$ip")

  echo -e "${C_DIM}模式：${mode}；需要 root 权限（可能提示输入密码）…${C_RESET}"
  if command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
    # 从 /dev/tty 读密码，避免经 curl|bash 时 sudo 无法交互
    sudo nexttrace "${args[@]}" >"$out" 2>"$err" </dev/tty
  else
    nexttrace "${args[@]}" >"$out" 2>"$err"
  fi
}

extract_raw() {
  local src="$1"
  local dst="$2"
  # 兼容 stdout/stderr 混排：两边都扫
  grep -E '^[0-9]+\|' "$src" >"$dst" 2>/dev/null || true
}

classify() {
  local raw_file="$1"
  TARGET_IP="$TARGET" RAW_FILE="$raw_file" python3 - <<'PY'
import os, re, sys

target = os.environ.get("TARGET_IP", "")
path = os.environ["RAW_FILE"]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = [ln.strip() for ln in f if ln.strip()]

hops = []
for ln in lines:
    parts = ln.split("|")
    if len(parts) < 2:
        continue
    hop = parts[0]
    ip = parts[1] if len(parts) > 1 else "*"
    if ip == "*" or not ip:
        hops.append({"hop": hop, "ip": "*", "rtt": "", "asn": "", "where": "", "owner": ""})
        continue
    host = parts[2] if len(parts) > 2 else ""
    rtt = parts[3] if len(parts) > 3 else ""
    asn = re.sub(r"^AS", "", parts[4] if len(parts) > 4 else "", flags=re.I)
    country = parts[5] if len(parts) > 5 else ""
    prov = parts[6] if len(parts) > 6 else ""
    city = parts[7] if len(parts) > 7 else ""
    owner = parts[9] if len(parts) > 9 else ""
    where = " ".join(x for x in (country, prov, city) if x)
    hops.append({
        "hop": hop, "ip": ip, "host": host, "rtt": rtt,
        "asn": asn, "where": where, "owner": owner,
    })

asns = [h["asn"] for h in hops if h.get("asn")]
all_asn = " ".join(f"AS{a}" for a in asns)

def label():
    if "AS58807" in all_asn:
        return "移动CMIN2", "优质线路", "green"
    if "AS9929" in all_asn:
        return "联通9929", "优质线路", "green"
    if "AS10099" in all_asn:
        return "联通10099", "优质线路", "green"
    if "AS4809" in all_asn and "AS4134" in all_asn:
        return "电信CN2GT", "半程/普通偏优", "yellow"
    if "AS4809" in all_asn:
        return "电信CN2GIA", "优质线路", "green"
    if "AS23764" in all_asn:
        return "电信CTGGIA", "优质线路", "green"
    if "AS9808" in all_asn or "AS58453" in all_asn:
        return "移动CMI", "普通线路", "yellow"
    if "AS4837" in all_asn:
        return "联通4837", "普通线路", "yellow"
    if "AS4134" in all_asn:
        return "电信163", "普通线路", "yellow"
    if asns:
        return f"AS{asns[0]}", "未能识别精品网特征", "yellow"
    return "未知", "路径不可见或探测失败", "red"

name, quality, color = label()
color_map = {"green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m"}
c = color_map[color]
bold, cyan, dim, reset, blue = "\033[1m", "\033[36m", "\033[2m", "\033[0m", "\033[34m"

print()
print(f"{bold}{cyan}======== 去程检测摘要（本机 → {target}）========{reset}")
print(f"{bold}判定线路：{c}{name} [{quality}]{reset}")
seen = []
for a in asns:
    if not seen or seen[-1] != a:
        seen.append(a)
asn_path = " → ".join(f"AS{a}" for a in seen) if seen else "(无 ASN)"
print(f"ASN 路径：{blue}{asn_path}{reset}")
print(f"{dim}说明：去程看的是「你当前网络 → 机器」；测前请关闭 Shadowrocket 代理/TUN。{reset}")
print()
print(f"{bold}详细跳数：{reset}")
print(f"{'跳':>3}  {'延迟':>8}  {'IP':<18} {'ASN':<10} 地理位置 / 归属")
print("-" * 78)
for h in hops:
    if h["ip"] == "*":
        print(f"{h['hop']:>3}  {'*':>8}  {'*':<18} {'':<10} {dim}超时{reset}")
        continue
    rtt = f"{h['rtt']}ms" if h["rtt"] else "-"
    asn = f"AS{h['asn']}" if h["asn"] else "-"
    meta = " / ".join(x for x in (h["where"], h["owner"]) if x) or h.get("host", "")
    premium = h["asn"] in {"4809", "58807", "9929", "10099", "23764"}
    asn_s = f"{c}{asn}{reset}" if premium and color == "green" else asn
    print(f"{h['hop']:>3}  {rtt:>8}  {h['ip']:<18} {asn_s:<10} {meta}")
print()
if not hops:
    print(f"{color_map['red']}未拿到任何跳数。请确认：已关代理、IP 正确、并用 sudo 运行。{reset}")
    sys.exit(2)
visible = [h for h in hops if h["ip"] != "*"]
if not visible:
    print(f"{color_map['yellow']}全程超时（*）。目标可能禁 ICMP/TCP80，或本地防火墙拦了探测。{reset}")
    sys.exit(3)
PY
}

main() {
  echo -e "${C_BOLD}${C_CYAN}去程检测（macOS / Linux）${C_RESET}"
  echo -e "${C_DIM}仓库：https://github.com/wangyuling93/NetQuality${C_RESET}"
  echo
  warn_proxy
  prompt_target
  if ! is_ip "$TARGET"; then
    echo -e "${C_YELLOW}输入不是标准 IP，仍将交给 nexttrace 解析：${TARGET}${C_RESET}"
  fi
  ensure_nexttrace
  echo -e "${C_GREEN}正在探测去程：${C_BOLD}${TARGET}${C_RESET}${C_GREEN} …${C_RESET}"
  echo

  local out="$WORKDIR/out.txt"
  local err="$WORKDIR/err.txt"
  local raw="$WORKDIR/raw.txt"
  local combined="$WORKDIR/combined.txt"

  # 先 TCP:80（和回程脚本同类），失败再试 ICMP
  set +e
  run_trace "$TARGET" "$out" "$err" "tcp"
  local rc=$?
  set -e
  cat "$out" "$err" >"$combined" 2>/dev/null || true
  extract_raw "$combined" "$raw"

  if [[ ! -s "$raw" ]]; then
    echo -e "${C_YELLOW}TCP 模式无有效跳数，改试 ICMP …${C_RESET}"
    set +e
    run_trace "$TARGET" "$out" "$err" "icmp"
    rc=$?
    set -e
    cat "$out" "$err" >"$combined" 2>/dev/null || true
    extract_raw "$combined" "$raw"
  fi

  if [[ ! -s "$raw" ]]; then
    echo -e "${C_RED}没有解析到路由数据。${C_RESET}" >&2
    echo -e "${C_YELLOW}--- nexttrace 输出 ---${C_RESET}" >&2
    cat "$combined" >&2 || true
    echo -e "${C_YELLOW}----------------------${C_RESET}" >&2
    echo -e "${C_DIM}可手动验证：sudo nexttrace -T -p 80 -g cn ${TARGET}${C_RESET}" >&2
    exit 1
  fi

  classify "$raw"
}

main "$@"
