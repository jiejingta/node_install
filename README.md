# HY2 节点一键部署

在新机器上一行命令完成 Hysteria2 节点部署，开箱即用。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/jiejingta/node_install/main/hy2-node-setup.sh)
```

需要 root 权限，适用于 Ubuntu 20.04 / 22.04 / 24.04。

## 脚本做了什么

| 步骤 | 说明 |
|------|------|
| 安装 Hysteria2 | 使用官方脚本安装二进制，生成自签证书，写入配置并启动 systemd 服务 |
| 端口跳跃 | 安装 nftables，配置 UDP 50001-53999 转发到 54000，持久化重启不丢失 |
| fail2ban | 安装并配置 SSH 防爆破，连续失败 5 次封禁 1 小时 |
| 防火墙放行 | 自动放行 UDP 端口范围（ufw 或 iptables） |
| 输出配置 | 安装完成后打印 sing-box outbound 配置和通用 hy2:// URI |

## 默认参数

| 参数 | 值 |
|------|-----|
| HY2 监听端口 | 54000 |
| 端口跳跃范围 | 50001-53999 |
| 密码 | RkMi0BPuVz |
| TLS SNI | www.bing.com |
| 证书 | 自签，有效期 10 年 |

如需修改，编辑脚本顶部的配置区域即可。

## 安装后的客户端配置

脚本运行结束会自动输出两种格式：

**sing-box outbound（用于加速器客户端）：**

```json
{
  "type": "hysteria2",
  "tag": "hy2-xxx",
  "server": "服务器IP",
  "server_ports": ["50001:53999"],
  "hop_interval": "30s",
  "up_mbps": 20,
  "down_mbps": 20,
  "password": "RkMi0BPuVz",
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "insecure": true,
    "alpn": ["h3"]
  }
}
```

**通用 URI（可导入 Shadowrocket / Hiddify 等客户端）：**

```
hy2://RkMi0BPuVz@服务器IP:50001?insecure=1&sni=www.bing.com&mport=50001-53999#hy2-xxx
```

## 常用运维命令

```bash
# Hysteria2
systemctl status hysteria-server      # 查看状态
systemctl restart hysteria-server     # 重启
journalctl -u hysteria-server -f      # 实时日志

# 端口跳跃
nft list table ip hysteria_hop        # 查看规则
nft list ruleset | grep counter       # 查看转发计数

# fail2ban
fail2ban-client status sshd           # 查看 SSH 封禁状态
fail2ban-client unban <IP>            # 手动解封
```

## 卸载

```bash
# 停止并卸载 Hysteria2
systemctl stop hysteria-server
bash <(curl -fsSL https://get.hy2.sh/) --remove
rm -rf /etc/hysteria

# 清理端口跳跃
nft delete table ip hysteria_hop
rm -f /etc/nftables.d/hysteria-hop.conf

# 卸载 fail2ban
apt-get remove -y fail2ban
```

## 注意事项

- 如果机器上已有 Hysteria2，脚本会自动卸载旧版本再重新安装
- 云服务器需要在安全组中手动放行 UDP 50001-53999
- 此脚本安装的是**官方 Hysteria2 二进制**，不是 sing-box 的 HY2 实现（实测官方版本在游戏场景下更稳定）
- 脚本可重复执行，会自动清理旧配置
