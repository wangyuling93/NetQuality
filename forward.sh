#!/usr/bin/env bash
# 去程检测摘要：在 macOS / Linux 本机测「你 → VPS」。
# 默认 ICMP → TCP 递进（打到目标即停）；不必三协议全跑。
#   bash forward.sh 1.2.3.4
#   bash forward.sh --all 1.2.3.4          # 同时对比 ICMP / TCP / UDP
#   bash <(curl -Ls https://raw.githubusercontent.com/wangyuling93/NetQuality/main/forward.sh) 1.2.3.4
set -euo pipefail

SCRIPT_VERSION="v2026-08-02-fwd5"
REPO_URL="https://github.com/wangyuling93/NetQuality"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_DIM=$'\033[2m'

TARGET=""
MODE_ALL=0
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

usage() {
  cat <<EOF
用法: bash forward.sh [--all|-a] [目标IP]
  默认: ICMP → TCP 递进（打到目标即停；不必三协议全跑）
  --all: 依次跑 ICMP / TCP / UDP 并分别出摘要（对比用，更慢）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -a | --all)
    MODE_ALL=1
    shift
    ;;
  -*)
    echo -e "${C_RED}未知参数: $1${C_RESET}" >&2
    usage >&2
    exit 1
    ;;
  *)
    TARGET="$1"
    shift
    ;;
  esac
done

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
  local mode="$4" # icmp|tcp|udp
  local -a args=(-q 3 -g cn --raw -m 30 --timeout 3000 --parallel-requests 1 --pow-provider sakura)

  case "$mode" in
  tcp) args+=(-T -p 443 --psize 64) ;;
  udp) args+=(-U -p 53 --psize 64) ;;
  icmp) ;;
  *)
    echo -e "${C_RED}内部错误：未知 mode=$mode${C_RESET}" >&2
    return 1
    ;;
  esac
  if [[ "$ip" == *:* ]]; then
    args+=(-6)
  else
    args+=(-4)
  fi
  args+=("$ip")

  echo -e "${C_DIM}模式：${mode}；需要 root（可能提示输入密码）…${C_RESET}"
  if command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
    sudo nexttrace "${args[@]}" >"$out" 2>"$err" </dev/tty
  else
    nexttrace "${args[@]}" >"$out" 2>"$err"
  fi
}

path_reached_target() {
  local raw="$1"
  local ip="$2"
  grep -Eq "^[0-9]+\\|${ip//./\\.}\\|" "$raw" 2>/dev/null
}

score_raw_path() {
  local raw="$1"
  local ip="$2"
  python3 - "$raw" "$ip" <<'PY'
import sys
raw, target = sys.argv[1], sys.argv[2]
premium = {"58807", "9929", "10099", "4809", "23764"}
score = hops = 0
saw_target = saw_premium = saw_abroad = False
for ln in open(raw, encoding="utf-8", errors="replace"):
    p = ln.strip().split("|")
    if len(p) < 2 or p[1] in {"*", ""}:
        continue
    hops += 1
    if p[1] == target:
        saw_target = True
    asn = p[4].lstrip("ASas") if len(p) > 4 else ""
    if p[1].startswith("59.43."):
        asn = "4809"
    if asn in premium:
        saw_premium = True
    country = p[5] if len(p) > 5 else ""
    where = " ".join(p[5:8]) if len(p) > 7 else country
    if country and ("中国" not in country) and country.upper() not in {"CN", "CHINA", ""}:
        if not p[1].startswith(("10.", "192.168.", "172.", "100.")):
            saw_abroad = True
    if any(x in where for x in ("德国", "美国", "英国", "日本", "香港", "韩国", "法国", "荷兰", "新加坡")):
        if not p[1].startswith(("10.", "192.168.", "172.", "100.")):
            saw_abroad = True
if saw_target:
    score += 1000
if saw_premium:
    score += 50
if saw_abroad:
    score += 30
score += hops
print(score)
PY
}

extract_raw() {
  local src="$1"
  local dst="$2"
  grep -E '^[0-9]+\|' "$src" >"$dst" 2>/dev/null || true
}

classify() {
  local raw_file="$1"
  local proto="$2"
  local incomplete="$3"
  TARGET_IP="$TARGET" RAW_FILE="$raw_file" PROTO="$proto" INCOMPLETE="$incomplete" \
    SCRIPT_VERSION="$SCRIPT_VERSION" REPO_URL="$REPO_URL" python3 - <<'PY'
import os, re, sys
from collections import OrderedDict

target = os.environ.get("TARGET_IP", "")
path = os.environ["RAW_FILE"]
proto = os.environ.get("PROTO", "icmp").upper()
incomplete = os.environ.get("INCOMPLETE", "0") == "1"
script_ver = os.environ.get("SCRIPT_VERSION", "")
repo = os.environ.get("REPO_URL", "")

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
    if ip == "*" or not ip:
        raw_hops.append({"hop": hop, "ip": "*", "rtt": None, "asn": "", "country": "", "where": "", "owner": ""})
        continue
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
    if "CTGNet" in (owner or ""):
        asn = "23764"
    where = " ".join(x for x in (country, prov, city) if x)
    raw_hops.append({
        "hop": hop, "ip": ip, "rtt": rtt, "asn": asn,
        "country": country, "where": where, "owner": owner,
    })

grouped = OrderedDict()
for h in raw_hops:
    grouped.setdefault(h["hop"], []).append(h)

hops = []
for hop, items in grouped.items():
    visible = [x for x in items if x["ip"] != "*"]
    if not visible:
        hops.append({"hop": hop, "ip": "*", "rtt": None, "asn": "", "country": "", "where": "", "owner": "", "loss": len(items)})
        continue
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

# 截掉尾部连续超时
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

LINE_DB = [
    ("58807", "移动CMIN2", "优质", "green"),
    ("9929", "联通9929", "优质", "green"),
    ("10099", "联通10099", "优质", "green"),
    ("4809", "电信CN2GIA", "优质", "green"),
    ("23764", "电信CTGGIA", "优质", "green"),
    ("9808", "移动CMI", "普通", "yellow"),
    ("58453", "移动CMI", "普通", "yellow"),
    ("4837", "联通4837", "普通", "yellow"),
    ("4134", "电信163", "普通", "yellow"),
]

def asn_name(asn, path_asns=None):
    path_asns = path_asns or set()
    # 路径同时含 163 + CN2 → 混合（对齐回程 CN2GT）
    if asn == "4809" and "4134" in path_asns:
        return "电信CN2GT", "混合", "cyan"
    if asn == "4134" and "4809" in path_asns:
        return "电信163", "普通", "yellow"
    for code, name, quality, color in LINE_DB:
        if asn == code:
            return name, quality, color
    return (f"AS{asn}" if asn else "未知"), "未知", "yellow"

def is_china(h):
    c = h.get("country") or ""
    w = h.get("where") or ""
    blob = f"{c} {w}"
    if any(x in blob for x in ("香港", "澳门", "台湾")):
        return False
    return ("中国" in blob) or c.upper() in {"CN", "CHINA"}

def is_private(ip):
    return ip.startswith(("10.", "192.168.", "172.", "100.", "127."))

def is_cn_mainland_public(h):
    if h["ip"] == "*" or not h.get("asn") or is_private(h["ip"]):
        return False
    return is_china(h)

path_asns = []
for h in hops:
    if h.get("asn") and (not path_asns or path_asns[-1] != h["asn"]):
        path_asns.append(h["asn"])
path_asn_set = set(path_asns)

cn_hops = [h for h in hops if is_cn_mainland_public(h)]
intl_hops = [
    h for h in hops
    if h["ip"] != "*" and h.get("asn") and not is_china(h) and not is_private(h["ip"])
]

cn_asns = []
for h in cn_hops:
    if h["asn"] and (not cn_asns or cn_asns[-1] != h["asn"]):
        cn_asns.append(h["asn"])
intl_asns = []
for h in intl_hops:
    if h["asn"] and (not intl_asns or intl_asns[-1] != h["asn"]):
        intl_asns.append(h["asn"])

premium = ("58807", "9929", "10099", "4809", "23764")
exit_asn = ""
for pref in premium:
    if pref in intl_asns:
        exit_asn = pref
        break
if not exit_asn:
    for pref in premium:
        if any(h.get("asn") == pref for h in hops):
            for h in reversed(hops):
                if h.get("asn") == pref:
                    exit_asn = pref
                    break
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

exit_name, exit_q, exit_color = asn_name(exit_asn, path_asn_set)
dom_name, dom_q, dom_color = asn_name(domestic_asn, path_asn_set)

reached = any(h["ip"] == target for h in hops)
saw_abroad = any(
    h["ip"] != "*" and h.get("asn") and not is_china(h) and not is_private(h["ip"])
    for h in hops
)
if not incomplete:
    incomplete = not reached and not saw_abroad

name, quality, color = exit_name, exit_q + "线路", exit_color
if not exit_asn:
    name, quality, color = "未知", "路径不可见或探测失败", "red"
elif incomplete:
    name, quality, color = "探测不完整", "未出国/未达目标，结果不可靠", "red"

color_map = {
    "green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m", "cyan": "\033[36m",
}
c = color_map.get(color, color_map["yellow"])
dc = color_map.get(dom_color, color_map["yellow"])
bold, cyan, dim, reset, blue = "\033[1m", "\033[36m", "\033[2m", "\033[0m", "\033[34m"
purple = "\033[35m"

segments = []
for h in hops:
    if h["ip"] == "*" or not h.get("asn"):
        continue
    ln, lq, _ = asn_name(h["asn"], path_asn_set)
    try:
        hop_n = int(h["hop"])
    except ValueError:
        continue
    if segments and segments[-1][2] == h["asn"]:
        segments[-1][1] = hop_n
    else:
        segments.append([hop_n, hop_n, h["asn"], ln, lq])

print()
print(f"{bold}{cyan}======== 去程检测摘要 {script_ver}（本机 → {target}）========{reset}")
print(f"{dim}{repo}{reset}")
print(f"{bold}探测协议：{cyan}{proto}{reset}  {dim}← ICMP/TCP/UDP 去程可能不同{reset}")
if incomplete:
    print(f"{bold}{color_map['red']}状态：探测不完整（国际段超时，请重试或换协议）{reset}")
else:
    print(f"{bold}状态：{color_map['green']}完整{reset}" + (f"  已到达目标" if reached else f"  已看到出境段"))
print(f"{bold}国际出境：{c}{name} [{quality}]{reset}  {dim}← 看这个判断出国是否精品网{reset}")
if domestic_asn:
    print(f"{bold}国内接入：{dc}{dom_name} [{dom_q}线路]{reset}  AS{domestic_asn}")
else:
    print(f"{bold}国内接入：{dim}未识别到国内公网 ASN{reset}")
if "4809" in path_asn_set and "4134" in path_asn_set:
    print(f"{color_map['cyan']}混合特征：路径同时含 AS4134(163) 与 AS4809(CN2) → 标 CN2GT，非纯 GIA{reset}")

prem_segs = [s for s in segments if s[4] == "优质"]
mix_segs = [s for s in segments if s[4] == "混合"]
norm_segs = [s for s in segments if s[4] == "普通"]
if prem_segs:
    bits = [f"第{a}-{b}跳 {n}(AS{asn})" if a != b else f"第{a}跳 {n}(AS{asn})" for a, b, asn, n, _ in prem_segs]
    print(f"{bold}{color_map['green']}优质段：{'；'.join(bits)}{reset}")
if mix_segs:
    bits = [f"第{a}-{b}跳 {n}(AS{asn})" if a != b else f"第{a}跳 {n}(AS{asn})" for a, b, asn, n, _ in mix_segs]
    print(f"{bold}{color_map['cyan']}混合段：{'；'.join(bits)}{reset}")
if norm_segs:
    bits = [f"第{a}-{b}跳 {n}(AS{asn})" if a != b else f"第{a}跳 {n}(AS{asn})" for a, b, asn, n, _ in norm_segs]
    print(f"{bold}{color_map['yellow']}普通段：{'；'.join(bits)}{reset}")
if incomplete and not prem_segs and not mix_segs:
    print(f"{color_map['yellow']}提示：本次没抓到出境跳（CMIN2/CN2 等），不能据此判断是普通线。{reset}")

exit_hop = next((h for h in hops if h.get("asn") == exit_asn and h["ip"] != "*"), None)
if exit_hop and not is_china(exit_hop):
    rtt_s = f"  ~{exit_hop['rtt']:.0f}ms" if exit_hop["rtt"] is not None else ""
    print(f"出境位置：{purple}{exit_hop['where'] or '境外'}{reset}  AS{exit_asn}{rtt_s}")

asn_path = " → ".join(f"AS{a}({asn_name(a, path_asn_set)[0]})" for a in path_asns) if path_asns else "(无 ASN)"
print(f"ASN 路径：{blue}{asn_path}{reset}")
print(f"{dim}CMIN2/CN2GIA/9929=优质；CN2GT=混合；CMI/163/4837=普通。{reset}")
print(f"{dim}延迟=本机到「这一跳」的往返时间；中间路由常限速回 TTL，后面跳延迟可能更低，属正常。{reset}")
print()
print(f"{bold}详细跳数：{reset}")
print(f"{'跳':>3}  {'延迟':>8}  {'质量':<6} {'线路':<12} {'IP':<18} {'ASN':<10} 位置")
print("-" * 88)
prev_q = None
for h in hops:
    if h["ip"] == "*":
        print(f"{h['hop']:>3}  {'*':>8}  {'':6} {'':12} {'*':<18} {'':10} {dim}超时{reset}")
        prev_q = None
        continue
    rtt = f"{h['rtt']:.1f}ms" if h["rtt"] is not None else "-"
    if h.get("asn"):
        ln, lq, lc = asn_name(h["asn"], path_asn_set)
        col = color_map.get(lc, "")
        if lq in ("优质", "混合", "普通"):
            q_s = f"{col}{lq}{reset}"
            ln_s = f"{col}{ln}{reset}"
        else:
            q_s = "其他"
            ln_s = ln
        if prev_q is not None and lq != prev_q and lq in ("优质", "混合", "普通"):
            print(f"{dim}      ↓ 进入{lq}段 {ln}{reset}")
        prev_q = lq
    else:
        q_s, ln_s, prev_q = "-", "-", prev_q
    asn = f"AS{h['asn']}" if h["asn"] else "-"
    meta = h["where"] or h.get("owner") or ""
    if len(meta) > 40:
        meta = meta[:39] + "…"
    print(f"{h['hop']:>3}  {rtt:>8}  {q_s:<15} {ln_s:<21} {h['ip']:<18} {asn:<10} {meta}")
print()
if not hops:
    print(f"{color_map['red']}未拿到任何跳数。请确认：已关代理、IP 正确、并用 sudo 运行。{reset}")
    sys.exit(2)
visible = [h for h in hops if h["ip"] != "*"]
if not visible:
    print(f"{color_map['yellow']}全程超时（*）。目标可能禁 ICMP/TCP/UDP 探测，或本地防火墙拦截。{reset}")
    sys.exit(3)
PY
}

probe_one() {
  local mode="$1"
  local out="$WORKDIR/${mode}.out"
  local err="$WORKDIR/${mode}.err"
  local raw="$WORKDIR/${mode}.raw"
  local combined="$WORKDIR/${mode}.combined"

  echo -e "${C_CYAN}探测（${mode}）…${C_RESET}"
  set +e
  run_trace "$TARGET" "$out" "$err" "$mode"
  set -e
  cat "$out" "$err" >"$combined" 2>/dev/null || true
  extract_raw "$combined" "$raw"
  if [[ ! -s "$raw" ]]; then
    echo 0
    return 0
  fi
  score_raw_path "$raw" "$TARGET"
}

main() {
  echo -e "${C_BOLD}${C_CYAN}去程检测摘要 ${SCRIPT_VERSION}${C_RESET}"
  echo -e "${C_DIM}${REPO_URL}${C_RESET}"
  if [[ "$MODE_ALL" -eq 1 ]]; then
    echo -e "${C_DIM}模式：--all（ICMP / TCP / UDP 全对比）${C_RESET}"
  else
    echo -e "${C_DIM}模式：递进 ICMP→TCP（打到目标即停；UDP 仅 --all）${C_RESET}"
  fi
  echo
  warn_proxy
  prompt_target
  if ! is_ip "$TARGET"; then
    echo -e "${C_YELLOW}输入不是标准 IP，仍将交给 nexttrace 解析：${TARGET}${C_RESET}"
  fi
  ensure_nexttrace
  echo -e "${C_GREEN}正在探测去程：${C_BOLD}${TARGET}${C_RESET}${C_GREEN} …${C_RESET}"
  echo

  local modes=()
  if [[ "$MODE_ALL" -eq 1 ]]; then
    modes=(icmp tcp udp)
  else
    modes=(icmp tcp)
  fi

  local best_score=-1
  local best_mode=""
  local mode score raw
  local -a ran_modes=()

  for mode in "${modes[@]}"; do
    score=$(probe_one "$mode")
    raw="$WORKDIR/${mode}.raw"
    ran_modes+=("$mode")
    if [[ ! -s "$raw" ]]; then
      echo -e "${C_YELLOW}${mode}：无有效跳数${C_RESET}"
      echo
      continue
    fi
    echo -e "${C_DIM}${mode} 得分：${score}${C_RESET}"

    if [[ "$score" -gt "$best_score" ]]; then
      best_score=$score
      best_mode=$mode
      cp "$raw" "$WORKDIR/best.raw"
    fi

    if [[ "$MODE_ALL" -eq 1 ]]; then
      # 是否「不完整」交给 classify 按是否出国自行判断
      classify "$raw" "$mode" 0
      echo
      continue
    fi

    if path_reached_target "$raw" "$TARGET"; then
      echo -e "${C_GREEN}已到达目标（${mode}），跳过后续协议。${C_RESET}"
      break
    fi
    echo -e "${C_YELLOW}${mode} 未到目标，尝试下一协议…${C_RESET}"
    echo
  done

  if [[ "$MODE_ALL" -eq 1 ]]; then
    if [[ "$best_score" -lt 0 ]]; then
      echo -e "${C_RED}各协议均无有效数据。${C_RESET}" >&2
      exit 1
    fi
    echo -e "${C_BOLD}${C_GREEN}对比结束。得分最高：${best_mode}（${best_score}）${C_RESET}"
    exit 0
  fi

  if [[ "$best_score" -lt 0 || ! -s "$WORKDIR/best.raw" ]]; then
    echo -e "${C_RED}没有解析到路由数据。${C_RESET}" >&2
    echo -e "${C_DIM}可手动：sudo nexttrace -g cn -q 3 ${TARGET}${C_RESET}" >&2
    exit 1
  fi

  if ! path_reached_target "$WORKDIR/best.raw" "$TARGET"; then
    echo -e "${C_YELLOW}已尝试 ${ran_modes[*]}，仍未打到目标；下面为得分最高的 ${best_mode}（有出境段仍可参考）。${C_RESET}"
    echo -e "${C_DIM}若要对比 UDP：bash forward.sh --all ${TARGET}${C_RESET}"
  fi
  # incomplete=0：由 classify 根据是否出国决定状态文案
  classify "$WORKDIR/best.raw" "$best_mode" 0
}

main "$@"
