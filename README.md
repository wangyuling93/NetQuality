# 网络质量体检脚本（湖南 / 江西增强版）

基于 [xykt/NetQuality](https://github.com/xykt/NetQuality) 修改。

## 相对上游的改动

- **三网回程路由摘要**（默认模式第五节）：在北京 / 上海 / 广州之外，新增 **湖南、江西**
- **完整路由模式** `-R`（不指定省份时）：默认同时测北京、上海、广东、湖南、江西
- 指定省份时仍可单独测湖南 / 江西，例如 `-R 湖南`、`-R 赣`、`-R JX`

## 使用方法

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
