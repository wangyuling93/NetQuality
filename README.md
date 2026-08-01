# 网络质量体检脚本（湖南 / 江西增强版）

基于 [xykt/NetQuality](https://github.com/xykt/NetQuality) 修改。

## 相对上游的改动

- **三网回程路由摘要**（默认模式第五节）：在北京 / 上海 / 广州之外，新增 **湖南、江西**
- **完整路由模式** `-R`（不指定省份时）：默认同时测北京、上海、广东、湖南、江西
- 指定省份时仍可单独测湖南 / 江西，例如 `-R 湖南`、`-R 赣`、`-R JX`

## 去程检测（macOS / 本机 → VPS）

在 **Mac 上**跑（测「你 → 机器」）。运行前请关闭 Shadowrocket 代理 / TUN，或把目标 IP 设为直连。

### 详细版（推荐，`forward2.sh`）

输出风格对齐回程 `-R`：报告头、`国内接入 -> 出境线路`、地理路径 / ASN 路径、逐跳详情（掩码 IP、ASN、`[owner]`、地理）。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wangyuling93/NetQuality/main/forward2.sh) 1.2.3.4
```

版本号：`v2026-08-01-fwd3`。默认 ICMP 优先（许多 VPS 对 TCP traceroute 中途黑洞），未到终点再试 TCP；需要 `sudo` + `python3` + NextTrace。

### 摘要版（`forward.sh`）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wangyuling93/NetQuality/main/forward.sh) 1.2.3.4
```

标题里带 **去程检测 v4** 为摘要版。会安装/调用 NextTrace，输出线路判定表格。需要 sudo。

## 使用方法（回程，在 VPS 上）

```bash
# 默认双栈（回程含湖南、江西）
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh)

# 仅 IPv4 / IPv6
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -4
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -6

# 延迟模式
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -P

# 完整路由：默认北上广 + 湖南 + 江西
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -R

# 完整路由：只测湖南 / 江西
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -R 湖南
bash <(curl -Ls https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh) -R 江西
```

GitHub：https://github.com/wangyuling93/NetQuality  
jsDelivr：`https://cdn.jsdelivr.net/gh/wangyuling93/NetQuality@main/net.sh`

## 致谢

原作者与上游项目：[xykt/NetQuality](https://github.com/xykt/NetQuality)
