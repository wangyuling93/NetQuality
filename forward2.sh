#!/usr/bin/env bash
# 去程详细路由：本机 → VPS，输出风格对齐 NetQuality 回程 -R 详情。
# 用法：
#   bash <(curl -Ls https://raw.githubusercontent.com/wangyuling93/NetQuality/main/forward2.sh) 1.2.3.4
#   bash forward2.sh 1.2.3.4
set -euo pipefail

SCRIPT_VERSION="v2026-08-01-fwd3"
REPO_URL="https://github.com/wangyuling93/NetQuality"
CMD_TMPL='bash <(curl -Ls https://raw.githubusercontent.com/wangyuling93/NetQuality/main/forward2.sh)'

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_PURPLE=$'\033[35m'
C_WHITE=$'\033[37m'
C_DIM=$'\033[2m'
C_UNDER=$'\033[4m'
B_CYAN=$'\033[46m'
B_WHITE=$'\033[47m'
B_BLUE=$'\033[44m'

TARGET="${1:-}"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

is_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]
}

mask_display_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip" | awk -F. '{print $1"."$2.".*.*"}'
  elif [[ "$ip" == *:* ]]; then
    echo "$ip" | awk -F: '{
      n=split($0,a,":"); keep=3;
      for(i=1;i<=8;i++){
        if(i<=keep && i<=n && a[i]!="") printf "%s",a[i]; else printf "*";
        if(i<8) printf ":";
      }
    }'
  else
    echo "$ip"
  fi
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
    echo -e "${C_YELLOW}请先关闭代理 / 全局路由，或把目标 IP 设为直连，再重跑。${C_RESET}"
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
  # 与回程详情一致：raw + sakura；国际段易丢包用 -q 3、串行
  local -a args=(-q 3 -g cn --raw -m 30 --timeout 3000 --parallel-requests 1 --pow-provider sakura)

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

# 是否到达目标 IP（仅此才算真正完整；仅看到 CMIN2/香港不够，否则会跳过 ICMP）
path_reached_target() {
  local raw="$1"
  local ip="$2"
  grep -Eq "^[0-9]+\\|${ip//./\\.}\\|" "$raw" 2>/dev/null
}

# 给多次探测打分，保留「最完整」的一条（优先到达目标）
score_raw_path() {
  local raw="$1"
  local ip="$2"
  python3 - "$raw" "$ip" <<'PY'
import sys
raw, target = sys.argv[1], sys.argv[2]
premium = {"58807", "9929", "10099", "4809", "23764"}
score = hops = 0
saw_target = saw_premium = False
for ln in open(raw, encoding="utf-8", errors="replace"):
    p = ln.strip().split("|")
    if len(p) < 2 or p[1] in {"*", ""}:
        continue
    hops += 1
    if p[1] == target:
        saw_target = True
    asn = p[4].lstrip("ASas") if len(p) > 4 else ""
    if asn in premium:
        saw_premium = True
if saw_target:
    score += 1000
if saw_premium:
    score += 50
score += hops
print(score)
PY
}

extract_raw() {
  local src="$1"
  local dst="$2"
  grep -E '^[0-9]+\|' "$src" >"$dst" 2>/dev/null || true
}

print_report() {
  local raw_file="$1"
  local proto="$2"
  local incomplete="$3"
  TARGET_IP="$TARGET" RAW_FILE="$raw_file" PROTO="$proto" INCOMPLETE="$incomplete" \
  SCRIPT_VERSION="$SCRIPT_VERSION" REPO_URL="$REPO_URL" CMD_LINE="${CMD_TMPL} ${TARGET}" \
  python3 - <<'PY'
import os, re, sys
from collections import OrderedDict

target = os.environ.get("TARGET_IP", "")
path = os.environ["RAW_FILE"]
proto = os.environ.get("PROTO", "TCP").upper()
incomplete = os.environ.get("INCOMPLETE", "0") == "1"
script_ver = os.environ.get("SCRIPT_VERSION", "")
repo = os.environ.get("REPO_URL", "")
cmd = os.environ.get("CMD_LINE", "")

R = "\033[0m"
B = "\033[1m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
BLUE = "\033[34m"
PURPLE = "\033[35m"
WHITE = "\033[37m"
DIM = "\033[2m"
U = "\033[4m"
BCYAN = "\033[46m"
BWHITE = "\033[47m"
BBLUE = "\033[44m"

AS_MAP = {
    "174": "Cogent", "1299": "Arelion", "2914": "NTT", "3257": "GTT",
    "3356": "Lumen", "3491": "PCCW", "4637": "Telstra", "6453": "TATA",
    "6939": "HE", "9002": "RETN", "12956": "Telxius", "20473": "Vultr",
    "24940": "Hetzner", "25820": "IT7", "45102": "Alibaba", "132203": "Tencent",
    "13335": "CF", "16509": "Amazon", "15169": "Google", "8075": "MS",
    "51847": "Nearoute", "60068": "Datacamp", "23961": "Misaka",
    "54801": "Zillion",
}

LINE_DB = [
    ("58807", "CMIN2", "优质"),
    ("9929", "9929", "优质"),
    ("10099", "10099", "优质"),
    ("4809", "CN2GIA", "优质"),
    ("23764", "CTGGIA", "优质"),
    ("9808", "CMI", "普通"),
    ("58453", "CMI", "普通"),
    ("4837", "4837", "普通"),
    ("4134", "163", "普通"),
]

def line_tag(asn: str):
    for code, name, q in LINE_DB:
        if asn == code:
            return name, q
    if asn in AS_MAP:
        return AS_MAP[asn], "其他"
    return (f"AS{asn}" if asn else "Unknown"), "其他"

def mask_ip(ip: str) -> str:
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        a, b, *_ = ip.split(".")
        return f"{a}.{b}.*.*"
    if ":" in ip:
        parts = ip.split(":")
        out = []
        for i in range(8):
            if i < 3 and i < len(parts) and parts[i]:
                out.append(parts[i])
            else:
                out.append("*")
        return ":".join(out)
    return ip

def extract_region(desc: str) -> str:
    discard = {"*", "中国", "电信", "联通", "移动", "运营商内网", "RFC1918"}
    suffixes = ("省", "市", "县", "维吾尔自治区", "回族自治区", "壮族自治区", "自治区", "特别行政区")
    for part in desc.split():
        if not part or part in discard:
            continue
        if any(x in part.lower() for x in (".", "rfc", "private", "local", "anycast", "网络故障", "asapi", "运营商")):
            continue
        for suf in suffixes:
            if part.endswith(suf):
                part = part[: -len(suf)]
                break
        if part:
            return part
    return ""

def is_china(country: str, where: str) -> bool:
    blob = f"{country} {where}"
    if any(x in blob for x in ("香港", "澳门", "台湾")):
        return False
    return ("中国" in blob) or country.upper() in {"CN", "CHINA"}

def is_private(ip: str) -> bool:
    return ip.startswith(("10.", "192.168.", "172.", "100.", "127."))

def colorize_latency(ms, width=9):
    if ms is None:
        return " " * width
    text = f"{ms:.2f}ms"
    if ms <= 150:
        colored = f"{GREEN}{text}{R}"
    elif ms <= 240:
        colored = f"{YELLOW}{text}{R}"
    else:
        colored = f"{RED}{text}{R}"
    pad = max(0, width - len(text))
    return (" " * pad) + colored

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = [ln.strip() for ln in f if ln.strip()]

raw_hops = []
for ln in lines:
    parts = ln.split("|")
    if len(parts) < 2:
        continue
    hop = parts[0]
    if not hop.isdigit():
        continue
    ip = parts[1] if len(parts) > 1 else "*"
    if ip in {"*", ""}:
        continue  # 与回程详情一致：不展示无响应跳
    try:
        rtt = float(parts[3]) if len(parts) > 3 and parts[3] else None
    except ValueError:
        rtt = None
    asn = re.sub(r"^AS", "", parts[4] if len(parts) > 4 else "", flags=re.I)
    if asn in {"0", "*", ""}:
        asn = ""
    country = parts[5] if len(parts) > 5 else ""
    prov = parts[6] if len(parts) > 6 else ""
    city = parts[7] if len(parts) > 7 else ""
    owner = parts[9] if len(parts) > 9 else ""
    if ip.startswith("59.43."):
        asn = "4809"
    if "CTGNet" in owner:
        asn = "23764"
    # 地理描述：国家 省/市 owner（对齐回程 * 中国 上海 xxx）
    geo_bits = []
    for x in (country, prov, city):
        if x and x not in geo_bits and "网络故障" not in x:
            geo_bits.append(x)
    if owner and "网络故障" not in owner:
        geo_bits.append(owner)
    geo = " ".join(geo_bits).strip() or "*"
    if geo != "*":
        geo = f"* {geo}"
    if is_private(ip):
        # 已出现公网跳之后的 10/172 多为运营商隧道，不是家用局域网
        saw_pub = any(not is_private(x["ip"]) for x in raw_hops)
        geo = "* 运营商内网" if saw_pub else "* RFC1918"
        owner = ""
        if not saw_pub:
            asn = ""
    # 国内 ASN 补运营商后缀（对齐回程观感）
    isp_suffix = ""
    if asn in {"4134", "4809", "23764"}:
        isp_suffix = " 电信"
    elif asn in {"4837", "9929", "10099"}:
        isp_suffix = " 联通"
    elif asn in {"9808", "58453", "58807"}:
        isp_suffix = " 移动"
    if isp_suffix and isp_suffix.strip() not in geo:
        if geo == "*":
            geo = f"*{isp_suffix}"
        else:
            geo = geo + isp_suffix
    bracket = ""
    if owner and "网络故障" not in owner and "RFC" not in owner.upper():
        bracket = f"[{owner.split()[0]}]"
    raw_hops.append({
        "hop": int(hop), "ip": ip, "rtt": rtt, "asn": asn,
        "country": country, "prov": prov, "city": city,
        "owner": owner, "geo": geo, "bracket": bracket,
        "where": " ".join(x for x in (country, prov, city) if x),
    })

# 同 TTL 多次探测合并
grouped = OrderedDict()
for h in raw_hops:
    grouped.setdefault(h["hop"], []).append(h)

hops = []
for hop, items in grouped.items():
    counts = {}
    for x in items:
        counts[x["ip"]] = counts.get(x["ip"], 0) + 1
    best_ip = max(counts, key=counts.get)
    chosen = [x for x in items if x["ip"] == best_ip]
    rtts = [x["rtt"] for x in chosen if x["rtt"] is not None]
    sample = chosen[0]
    hops.append({
        **sample,
        "hop": hop,
        "ip": best_ip,
        "rtt": sum(rtts) / len(rtts) if rtts else None,
    })

# 截掉尾部连续空洞后的无效延伸（已跳过 *，此处仅保底）
if hops:
    # 若最后若干跳 RTT 异常且未达目标，保留到最后有 ASN/公网的跳
    pass

reached = any(h["ip"] == target for h in hops)

# 地理路径（去重连续）
geo_path = []
for h in hops:
    reg = extract_region(h["geo"].lstrip("* ").strip())
    if not reg:
        continue
    if geo_path and geo_path[-1] == reg:
        continue
    # 回程逻辑：若已出现过则截断重接
    if reg in geo_path:
        geo_path = geo_path[: geo_path.index(reg) + 1]
    else:
        geo_path.append(reg)
geo_str = " -> ".join(geo_path) if geo_path else "Unknown"

# ASN 路径
asn_path = []
for h in hops:
    if not h["asn"]:
        continue
    tag = f"AS{h['asn']}"
    if asn_path and asn_path[-1] == tag:
        continue
    asn_path.append(tag)
asn_str = " -> ".join(asn_path) if asn_path else "Unknown"

# 国内接入 / 出境（去程：国内接入 -> 出境线路，对标回程「对端 -> 回程线路」）
premium = ("58807", "9929", "10099", "4809", "23764")
premium_set = set(premium)
cn_asns = []
abroad_asns = []
for h in hops:
    if not h["asn"] or is_private(h["ip"]):
        continue
    if is_china(h["country"], h["where"]):
        if not cn_asns or cn_asns[-1] != h["asn"]:
            cn_asns.append(h["asn"])
    else:
        if not abroad_asns or abroad_asns[-1] != h["asn"]:
            abroad_asns.append(h["asn"])

# 国内接入：路径上第一个国内公网 ASN（出现顺序）
domestic = cn_asns[0] if cn_asns else ""

# 出境：靠近出国处的精品网；否则首个境外 ASN；全程国内则用末个国内 ASN
exit_asn = ""
for a in reversed(cn_asns):
    if a in premium_set:
        exit_asn = a
        break
if not exit_asn:
    for a in abroad_asns:
        if a in premium_set:
            exit_asn = a
            break
if not exit_asn and abroad_asns:
    exit_asn = abroad_asns[0]
if not exit_asn and cn_asns:
    exit_asn = cn_asns[-1]

peer = ""
for h in reversed(hops):
    if h["asn"] and not is_private(h["ip"]):
        peer = h["asn"]
        break

left = line_tag(domestic)[0] if domestic else "Unknown"
right_asn = exit_asn or peer
right = line_tag(right_asn)[0] if right_asn else "Unknown"
# 左右相同且存在境外对端时，右侧改为对端机房 ASN（如 IT7）
if domestic and peer and right_asn == domestic and peer != domestic:
    right = line_tag(peer)[0]

# 报告头（对齐 net.sh）
try:
    from datetime import datetime
    from zoneinfo import ZoneInfo
    now = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M:%S CST")
except Exception:
    from datetime import datetime, timezone, timedelta
    now = (datetime.now(timezone(timedelta(hours=8)))).strftime("%Y-%m-%d %H:%M:%S CST")

disp_ip = mask_ip(target) if re.match(r"^\d+\.\d+\.\d+\.\d+$", target) or ":" in target else target

def center(s: str, width: int = 80) -> str:
    # 粗略按可见宽度居中（忽略 ANSI）
    plain = re.sub(r"\033\[[0-9;]*m", "", s)
    pad = max(0, (width - len(plain)) // 2)
    return " " * pad + s

print("*" * 80)
print(center(f"{B}去程路由检测报告：{CYAN}{disp_ip}{R}"))
print(center(f"{U}{repo}{R}"))
print(center(cmd))
print(f"            报告时间：{now}  脚本版本：{script_ver}")
print("*" * 80)
print(f"一、去程路由（本机 → 目标；{DIM}线路可能随网络负载动态变化{R}）")

title_left = f"  去程 {proto}  "
print(f"{BCYAN}{WHITE}{B}{title_left}{R}{BWHITE}{CYAN}{B}  {left} -> {right}  {R}")
print(f"{BBLUE}{WHITE}地理路径：{geo_str}    自治系统路径：{asn_str} {R}")

if incomplete:
    print(f"{RED}{B}状态：探测不完整（国际段可能超时，结果仅供参考）{R}")
elif reached:
    print(f"{GREEN}状态：已到达目标{R}")
else:
    print(f"{GREEN}状态：已看到出境段（目标可能禁探测）{R}")

# 合并连续相似跳（对齐回程 show_route）
def similar(a, b):
    if a["asn"] != b["asn"] or a["bracket"] != b["bracket"]:
        return False
    ga = a["geo"].lstrip("* ").split()
    gb = b["geo"].lstrip("* ").split()
    a2 = " ".join(ga[:2]) if ga else ""
    b2 = " ".join(gb[:2]) if gb else ""
    return (a2 and b2 and (a2 in b2 or b2 in a2)) or a["geo"] == b["geo"]

n = len(hops)
i = 0
while i < n:
    h = hops[i]
    end = i
    j = i + 1
    while j < n and similar(h, hops[j]):
        end = j
        j += 1
    merge = f"-{hops[end]['hop']:<2}" if end > i else "   "
    hop_label = f"{h['hop']:>2}{merge}"
    delay = colorize_latency(h["rtt"], 9)
    mip = f"{mask_ip(h['ip']):<13}"
    as_s = f"{('AS' + h['asn']) if h['asn'] else '':<10}"
    br = f"{h['bracket']:<18}"
    print(f"{B}{hop_label}{R} {delay}  {mip}{B}{as_s}{br}{R}{h['geo']}")
    i = end + 1

print("=" * 80)

prem = []
for a in asn_path:
    name, q = line_tag(a[2:])
    if q == "优质" and name not in prem:
        prem.append(name)
if prem:
    print(f"{GREEN}优质线路特征：{' / '.join(prem)}{R}")
elif incomplete:
    print(f"{YELLOW}提示：未完整抓取出境段时，请勿据此判定为普通线路。{R}")
print()
if not hops:
    print(f"{RED}未拿到任何跳数。请确认：已关代理、IP 正确、并用 sudo 运行。{R}")
    sys.exit(2)
PY
}

main() {
  echo -e "${C_BOLD}${C_CYAN}去程详细路由 ${SCRIPT_VERSION}${C_RESET}"
  echo -e "${C_DIM}${REPO_URL}${C_RESET}"
  echo
  warn_proxy
  prompt_target
  if ! is_ip "$TARGET"; then
    echo -e "${C_YELLOW}输入不是标准 IP，仍将交给 nexttrace 解析：${TARGET}${C_RESET}"
  fi
  ensure_nexttrace
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${C_RED}需要 python3${C_RESET}" >&2
    exit 1
  fi

  echo -e "${C_GREEN}正在探测去程：${C_BOLD}${TARGET}${C_RESET}${C_GREEN} …${C_RESET}"
  echo

  local out="$WORKDIR/out.txt"
  local err="$WORKDIR/err.txt"
  local raw="$WORKDIR/raw.txt"
  local best="$WORKDIR/best.txt"
  local combined="$WORKDIR/combined.txt"
  # 多数 VPS 对 TCP/443 traceroute 中途黑洞，ICMP 更能打到终点（如本次新加坡）
  local modes=(icmp tcp icmp)
  local attempt
  local ok=0
  local used_mode="icmp"
  local best_score=-1
  local score=0

  : >"$best"
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
    score=$(score_raw_path "$raw" "$TARGET")
    if ((score > best_score)); then
      best_score=$score
      used_mode="$mode"
      cp "$raw" "$best"
    fi
    if path_reached_target "$raw" "$TARGET"; then
      ok=1
      echo -e "${C_GREEN}已到达目标（${mode}）${C_RESET}"
      break
    fi
    echo -e "${C_YELLOW}尚未到达目标，自动换协议重试…${C_RESET}"
    echo
  done

  if [[ ! -s "$best" ]]; then
    echo -e "${C_RED}没有解析到路由数据。${C_RESET}" >&2
    echo -e "${C_YELLOW}--- nexttrace 输出 ---${C_RESET}" >&2
    cat "$combined" >&2 || true
    echo -e "${C_YELLOW}----------------------${C_RESET}" >&2
    echo -e "${C_DIM}可手动验证：sudo nexttrace -4 -g cn --pow-provider sakura -q 3 -m 30 ${TARGET}${C_RESET}" >&2
    exit 1
  fi
  cp "$best" "$raw"

  local incomplete=0
  if [[ "$ok" -ne 1 ]]; then
    echo -e "${C_YELLOW}已重试仍未到达目标，下面给出目前最完整的一条（仅供参考）。${C_RESET}"
    incomplete=1
  fi

  echo
  print_report "$raw" "$used_mode" "$incomplete"
}

main "$@"
