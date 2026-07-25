# Clash 订阅脚本使用注意事项

本脚本用于在 VPS 上部署 `subconverter + Caddy`，生成可直接添加到 **Mihomo / Clash Meta** 的 HTTPS 订阅链接。

## 使用前

- VPS 需要公网 IPv4。
- 在 VPS 厂商安全组和本机防火墙中放行 TCP `80`、`443`。
- Hysteria2 使用的 UDP 端口继续保留；UDP `443` 与 HTTPS 的 TCP `443` 不冲突。
- TCP `80`、`443` 不能被 Nginx、Apache 等其他服务占用。
- 不要开放 TCP `25500`、`8080` 或旧的 `18080`。

## 部署

使用一键安装命令时，Hysteria2 安装完成后会询问是否生成 HTTPS 订阅。输入 `y` 或 `yes` 即可继续：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sunshinecoolme-gif/vpn-optimizer/master/install.sh)
```

也可以安装完成后单独执行订阅脚本。脚本默认读取 `/etc/hysteria/config.yaml`：

```bash
cd /opt/vpn-optimizer
sudo bash setup-clash-subscription.sh --yes
```

也可以使用已有链接：

```bash
sudo bash setup-clash-subscription.sh \
  --link 'hysteria2://密码@服务器:端口?sni=域名&insecure=1#节点名称' \
  --yes
```

链接必须使用单引号包裹。部署成功后，将脚本输出的 HTTPS 地址添加到 Mihomo 或 Clash Meta。

## 链接复用与轮换

重复运行默认复用原令牌。只要公网 IP 或自定义域名不变，订阅链接就不会改变：

```bash
sudo bash setup-clash-subscription.sh --yes
```

只有链接泄露或需要主动更换时才生成新令牌：

```bash
sudo bash setup-clash-subscription.sh \
  --yes \
  --token "$(openssl rand -hex 24)"
```

轮换后旧链接立即失效，需要更新客户端订阅地址。

## 更新脚本

```bash
cd /opt/vpn-optimizer
git pull --ff-only origin master
sudo bash setup-clash-subscription.sh --yes
```

不传 `--token` 就不会主动轮换订阅令牌。

## 查看状态

```bash
cd /etc/subconverter-stack
docker compose ps
docker compose logs --tail=100
```

读取当前订阅地址：

```bash
HOST=$(sed -n 's/^SUBSCRIPTION_HOST=//p' /etc/subconverter-stack/install.env)
TOKEN=$(sed -n 's/^SUBSCRIPTION_TOKEN=//p' /etc/subconverter-stack/install.env)
echo "https://${HOST}/${TOKEN}.yaml"
```

## 常见报错

出现以下错误：

```text
[ERROR] check DNS resolution, provider firewall/security group, and TCP 80/443
```

请检查：

- 厂商安全组是否放行 TCP `80`、`443`。
- UFW 或 firewalld 是否放行 TCP `80`、`443`。
- 域名是否解析到当前 VPS 公网 IPv4。
- TCP `80`、`443` 是否被其他程序占用。
- 容器日志：`cd /etc/subconverter-stack && docker compose logs --tail=200`。

如果出现 HTTP 400 或“没有有效节点”，先拉取最新代码并重新运行脚本。不要手工修改 `/etc/subconverter-stack/source.txt`。

## 安全提醒

- 随机订阅 URL 相当于密码，请勿公开或提交到 Git。
- `/etc/subconverter-stack/` 中的配置文件只应由 root 读取。
- 本服务只用于 Mihomo / Clash Meta，不要对公网开放 subconverter 通用 API。
