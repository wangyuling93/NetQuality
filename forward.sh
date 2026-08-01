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
  # -q 3：国际链路易丢包，多测几次再合并显示；拉长单跳超时
  local -a args=(-q 3 -g cn --raw -m 20 --timeout 3000 --parallel-requests 1)

  if [[ "$mode" == "tcp" ]]; then
    args+=(-T -p 443 --psize 64)
  fi
  if [[ "$ip" == *:* ]]; then
    args+=(-6)
  else
    args+=(-4)
  fi
  args+=("$ip")

  echo -e "${C_DIM}模式：${mode}；需要 root 权限（可能提示输入密码）…${C_RESET}"
  if command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
    sudo nexttrace "${args[@]}" >"$out" 2>"$err" </dev/tty
  else
    nexttrace "${args[@]}" >"$out" 2>"$err"
  fi
}

# 路径是否足够完整：到达目标，或已看到精品网/境外 ASN
path_complete_enough() {
  local raw="$1"
  local ip="$2"
  python3 - "$raw" "$ip" <<'PY'
import sys
raw, target = sys.argv[1], sys.argv[2]
premium = {"58807", "9929", "10099", "4809", "23764"}
saw_target = saw_premium = saw_abroad = False
for ln in open(raw, encoding="utf-8", errors="replace"):
    p = ln.strip().split("|")
    if len(p) < 2 or p[1] in {"*", ""}:
        continue
    if p[1] == target:
        saw_target = True
    asn = p[4].lstrip("ASas") if len(p) > 4 else ""
    if asn in premium:
        saw_premium = True
    country = p[5] if len(p) > 5 else ""
    where = " ".join(p[5:8]) if len(p) > 7 else country
    if country and ("中国" not in country) and country.upper() not in {"CN", "CHINA", ""}:
        # 排除空；RFC1918 一般 country 为空
        if not p[1].startswith(("10.", "192.168.", "172.")):
            saw_abroad = True
    if "中国" not in where and where and not p[1].startswith(("10.", "192.168.", "172.")):
        if any(x in where for x in ("德国", "美国", "英国", "日本", "香港", "韩国", "法国", "荷兰", "新加坡")):
            saw_abroad = True
sys.exit(0 if (saw_target or saw_premium or saw_abroad) else 1)
PY
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
from collections import OrderedDict

target = os.environ.get("TARGET_IP", "")
path = os.environ["RAW_FILE"]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = [ln.strip() for ln in f if ln.strip()]

raw_hops = []
for ln in lines:
    parts = ln.split("|")
    if len(parts) < 2:
        continue
    hop = parts[0]
    ip = parts[1] if len(parts) > 1 else "*"
    if ip == "*" or not ip:
        raw_hops.append({"hop": hop, "ip": "*", "rtt": None, "asn": "", "country": "", "where": "", "owner": ""})
        continue
    try:
        rtt = float(parts[3]) if len(parts) > 3 and parts[3] else None
    except ValueError:
        rtt = None
    asn = re.sub(r"^AS", "", parts[4] if len(parts) > 4 else "", flags=re.I)
    country = parts[5] if len(parts) > 5 else ""
    prov = parts[6] if len(parts) > 6 else ""
    city = parts[7] if len(parts) > 7 else ""
    owner = parts[9] if len(parts) > 9 else ""
    where = " ".join(x for x in (country, prov, city) if x)
    raw_hops.append({
        "hop": hop, "ip": ip, "rtt": rtt, "asn": asn,
        "country": country, "where": where, "owner": owner,
    })

# 合并同一跳的多次探测：取出现最多的 IP，RTT 取平均
grouped = OrderedDict()
for h in raw_hops:
    grouped.setdefault(h["hop"], []).append(h)

hops = []
for hop, items in grouped.items():
    visible = [x for x in items if x["ip"] != "*"]
    if not visible:
        hops.append({"hop": hop, "ip": "*", "rtt": None, "asn": "", "country": "", "where": "", "owner": "", "loss": len(items)})
        continue
    # 多数表决 IP
    counts = {}
    for x in visible:
        counts[x["ip"]] = counts.get(x["ip"], 0) + 1
    best_ip = max(counts, key=counts.get)
    chosen = [x for x in visible if x["ip"] == best_ip]
    rtts = [x["rtt"] for x in chosen if x["rtt"] is not None]
    sample = chosen[0]
    hops.append({
        "hop": hop,
        "ip": best_ip,
        "rtt": sum(rtts) / len(rtts) if rtts else None,
        "asn": sample["asn"],
        "country": sample["country"],
        "where": sample["where"],
        "owner": sample["owner"],
        "loss": len(items) - len(visible),
        "probes": len(items),
    })

LINE_DB = [
    ("58807", "移动CMIN2", "优质", "green", "国际"),
    ("9929", "联通9929", "优质", "green", "国际"),
    ("10099", "联通10099", "优质", "green", "国际"),
    ("4809", "电信CN2", "优质", "green", "国际"),
    ("23764", "电信CTGGIA", "优质", "green", "国际"),
    ("9808", "移动CMI", "普通", "yellow", "国内/国际"),
    ("58453", "移动CMI", "普通", "yellow", "国内/国际"),
    ("4837", "联通4837", "普通", "yellow", "国内/国际"),
    ("4134", "电信163", "普通", "yellow", "国内/国际"),
]

def asn_name(asn):
    for code, name, quality, color, _ in LINE_DB:
        if asn == code:
            return name, quality, color
    return (f"AS{asn}" if asn else "未知"), "未知", "yellow"

def is_china(h):
    c = h.get("country") or ""
    w = h.get("where") or ""
    return ("中国" in c) or ("中国" in w) or c.upper() in {"CN", "CHINA"}

def is_cn_mainland_public(h):
    # 国内公网跳（排除私网）
    if h["ip"] == "*" or not h.get("asn"):
        return False
    if h["ip"].startswith(("10.", "192.168.", "172.")) or h["ip"].startswith("100."):
        return False
    return is_china(h)

cn_hops = [h for h in hops if is_cn_mainland_public(h)]
intl_hops = [h for h in hops if h["ip"] != "*" and h.get("asn") and not is_china(h) and not h["ip"].startswith(("10.", "192.168.", "172."))]

cn_asns = []
for h in cn_hops:
    if h["asn"] and (not cn_asns or cn_asns[-1] != h["asn"]):
        cn_asns.append(h["asn"])
intl_asns = []
for h in intl_hops:
    if h["asn"] and (not intl_asns or intl_asns[-1] != h["asn"]):
        intl_asns.append(h["asn"])

# 国际出境线路：优先看出国后的 ASN，再看全程精品网特征
exit_asn = ""
for pref in ("58807", "9929", "10099", "4809", "23764"):
    if pref in intl_asns or any(h.get("asn") == pref for h in hops):
        # 若精品 ASN 出现在国外跳，或出现在路径中靠近出境处
        if pref in intl_asns:
            exit_asn = pref
            break
        # 精品 ASN 在国内最后几跳也算（有时 geo 仍标中国）
        for h in reversed(hops):
            if h.get("asn") == pref:
                exit_asn = pref
                break
        if exit_asn:
            break
if not exit_asn and intl_asns:
    exit_asn = intl_asns[0]
if not exit_asn and cn_asns:
    exit_asn = cn_asns[-1]

domestic_asn = ""
for pref in ("9808", "58453", "4837", "4134", "4809", "58807"):
    if pref in cn_asns:
        domestic_asn = pref
        break
if not domestic_asn and cn_asns:
    domestic_asn = cn_asns[0]

exit_name, exit_q, exit_color = asn_name(exit_asn)
dom_name, dom_q, dom_color = asn_name(domestic_asn)

# 是否到达目标 / 是否看到境外
reached = any(h["ip"] == target for h in hops)
saw_abroad = any(
    h["ip"] != "*" and h.get("asn") and not is_china(h)
    and not h["ip"].startswith(("10.", "192.168.", "172."))
    for h in hops
)
incomplete = not reached and not saw_abroad

# 总判定：以国际出境为准；不完整时不要误判成「普通线路」
name, quality, color = exit_name, exit_q + "线路", exit_color
if not exit_asn:
    name, quality, color = "未知", "路径不可见或探测失败", "red"
elif incomplete:
    name, quality, color = "探测不完整", "未出国/未达目标，结果不可靠", "red"

color_map = {"green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m"}
c = color_map[color]
dc = color_map.get(dom_color, color_map["yellow"])
bold, cyan, dim, reset, blue = "\033[1m", "\033[36m", "\033[2m", "\033[0m", "\033[34m"
purple = "\033[35m"

# 连续同线路段：[(start, end, asn, name, quality)]
segments = []
for h in hops:
    if h["ip"] == "*" or not h.get("asn"):
        continue
    ln, lq, _ = asn_name(h["asn"])
    try:
        hop_n = int(h["hop"])
    except ValueError:
        continue
    if segments and segments[-1][2] == h["asn"]:
        segments[-1][1] = hop_n
    else:
        segments.append([hop_n, hop_n, h["asn"], ln, lq])

# 截掉尾部连续超时（避免 10~30 全是 *）
trim = len(hops)
streak = 0
for i in range(len(hops) - 1, -1, -1):
    if hops[i]["ip"] == "*":
        streak += 1
        if streak >= 2:
            trim = i
    else:
        break
if streak >= 2:
    hops = hops[:trim]

print()
print(f"{bold}{cyan}======== 去程检测摘要 v4（本机 → {target}）========{reset}")
if incomplete:
    print(f"{bold}{color_map['red']}状态：探测不完整（国际段超时，请重试）{reset}")
else:
    print(f"{bold}状态：{color_map['green']}完整{reset}" + (f"  已到达目标" if reached else f"  已看到出境段"))
print(f"{bold}国际出境：{c}{name} [{quality}]{reset}  {dim}← 看这个判断出国是否精品网{reset}")
if domestic_asn:
    print(f"{bold}国内接入：{dc}{dom_name} [{dom_q}线路]{reset}  AS{domestic_asn}")
else:
    print(f"{bold}国内接入：{dim}未识别到国内公网 ASN{reset}")

prem_segs = [s for s in segments if s[4] == "优质"]
norm_segs = [s for s in segments if s[4] == "普通"]
if prem_segs:
    bits = [f"第{a}-{b}跳 {n}(AS{asn})" if a != b else f"第{a}跳 {n}(AS{asn})" for a,b,asn,n,_ in prem_segs]
    print(f"{bold}{color_map['green']}优质段：{'；'.join(bits)}{reset}")
if norm_segs:
    bits = [f"第{a}-{b}跳 {n}(AS{asn})" if a != b else f"第{a}跳 {n}(AS{asn})" for a,b,asn,n,_ in norm_segs]
    print(f"{bold}{color_map['yellow']}普通段：{'；'.join(bits)}{reset}")
if incomplete and not prem_segs:
    print(f"{color_map['yellow']}提示：本次没抓到出境跳（CMIN2/CN2 等），不能据此判断是普通线。{reset}")

exit_hop = next((h for h in hops if h.get("asn") == exit_asn and h["ip"] != "*"), None)
if exit_hop and not is_china(exit_hop):
    rtt_s = f"  ~{exit_hop['rtt']:.0f}ms" if exit_hop["rtt"] is not None else ""
    print(f"出境位置：{purple}{exit_hop['where'] or '境外'}{reset}  AS{exit_asn}{rtt_s}")

seen = []
for h in hops:
    a = h.get("asn")
    if a and (not seen or seen[-1] != a):
        seen.append(a)
asn_path = " → ".join(f"AS{a}({asn_name(a)[0]})" for a in seen) if seen else "(无 ASN)"
print(f"ASN 路径：{blue}{asn_path}{reset}")
print(f"{dim}CMIN2/CN2/9929=优质；CMI/163/4837=普通。下面每跳「质量」列可直接看。{reset}")
print()
print(f"{bold}详细跳数：{reset}")
print(f"{'跳':>3}  {'延迟':>8}  {'质量':<6} {'线路':<10} {'IP':<18} {'ASN':<10} 位置")
print("-" * 86)
prev_q = None
for h in hops:
    if h["ip"] == "*":
        print(f"{h['hop']:>3}  {'*':>8}  {'':6} {'':10} {'*':<18} {'':10} {dim}超时{reset}")
        prev_q = None
        continue
    rtt = f"{h['rtt']:.1f}ms" if h["rtt"] is not None else "-"
    if h.get("asn"):
        ln, lq, lc = asn_name(h["asn"])
        if lq == "优质":
            q_s = f"{color_map['green']}优质{reset}"
            ln_s = f"{color_map['green']}{ln}{reset}"
        elif lq == "普通":
            q_s = f"{color_map['yellow']}普通{reset}"
            ln_s = f"{color_map['yellow']}{ln}{reset}"
        else:
            q_s = "其他"
            ln_s = ln
        # 线路切换时加分隔提示
        if prev_q is not None and lq != prev_q and lq in ("优质", "普通"):
            print(f"{dim}      ↓ 进入{lq}段 {ln}{reset}")
        prev_q = lq
    else:
        q_s, ln_s, prev_q = "-", "-", prev_q
    asn = f"AS{h['asn']}" if h["asn"] else "-"
    meta = h["where"] or h.get("owner") or ""
    if len(meta) > 40:
        meta = meta[:39] + "…"
    # 宽度按可见字符近似（颜色码不影响阅读）
    print(f"{h['hop']:>3}  {rtt:>8}  {q_s:<15} {ln_s:<19} {h['ip']:<18} {asn:<10} {meta}")
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
  echo -e "${C_BOLD}${C_CYAN}去程检测 v4（macOS / Linux）${C_RESET}"
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
  local modes=(tcp icmp tcp)
  local attempt
  local ok=0

  for attempt in 1 2 3; do
    local mode="${modes[$((attempt - 1))]}"
    echo -e "${C_CYAN}第 ${attempt}/3 次探测（${mode}）…${C_RESET}"
    set +e
    run_trace "$TARGET" "$out" "$err" "$mode"
    set -e
    cat "$out" "$err" >"$combined" 2>/dev/null || true
    extract_raw "$combined" "$raw"
    if [[ ! -s "$raw" ]]; then
      echo -e "${C_YELLOW}本次无有效跳数，准备重试…${C_RESET}"
      continue
    fi
    if path_complete_enough "$raw" "$TARGET"; then
      ok=1
      break
    fi
    echo -e "${C_YELLOW}路径不完整（国际段可能超时），自动重试…${C_RESET}"
    echo
  done

  if [[ ! -s "$raw" ]]; then
    echo -e "${C_RED}没有解析到路由数据。${C_RESET}" >&2
    echo -e "${C_YELLOW}--- nexttrace 输出 ---${C_RESET}" >&2
    cat "$combined" >&2 || true
    echo -e "${C_YELLOW}----------------------${C_RESET}" >&2
    echo -e "${C_DIM}可手动验证：sudo nexttrace -T -p 443 -g cn -q 3 ${TARGET}${C_RESET}" >&2
    exit 1
  fi

  if [[ "$ok" -ne 1 ]]; then
    echo -e "${C_YELLOW}已重试仍不完整，下面给出目前抓到的结果（仅供参考）。${C_RESET}"
  fi

  classify "$raw"
}

main "$@"
