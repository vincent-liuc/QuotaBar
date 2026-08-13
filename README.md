# QuotaBar

一个原生的 macOS 菜单栏用量监控工具。它可以保存和切换多个 Sub2API 兼容站点，定时读取每周订阅用量、API Key 用量和使用记录，并用菜单栏小猫的填充高度展示整体进度。

> [!IMPORTANT]
> 这是第三方开源项目，与 Sub2API 及其部署方没有隶属、授权或背书关系。

![应用图标](Assets/AppIcon-1024.png)

## 功能

- 菜单栏动态猫头展示每周已用额度 / 每周总额度，绿色液面从下向上填充并带轻微水波
- 毛玻璃弹窗展示订阅合计、累计 Token 与累计消费金额
- 展示每个启用 API Key 的当日用量和可选额度进度；有请求运行时同步显示当前并发
- API Key 按当日实际用量从高到低排列
- 在固定高度内滚动展示站点时区内最近两天的最新 50 条使用记录
- 周额度环形图显示距离下次重置的时间
- 可在设置中分别隐藏累计指标卡片、API Key 明细和使用记录
- 设置项实时生效，文本输入在失焦后保存
- 账户设置支持密码显隐，并可只调用登录接口验证账号密码
- 菜单栏小猫以从下到上的绿色填充表示已用比例
- 刷新频率可设置为 5-3600 秒
- 账号和密码保存在 `~/Library/Application Support/QuotaBar/credentials.json`
- 应用支持目录权限为 `700`、凭据文件权限为 `600`，应用不访问 macOS 钥匙串
- 支持使用 macOS 原生登录项开机启动
- 设置内支持检查 GitHub Releases，下载最新 universal DMG，校验 SHA-256 后打开安装镜像
- 更新下载通过 GitHub Asset API 获取，并为慢速网络保留最长 10 分钟下载时间与断线重试
- 当前版本：1.11.3
- 提供独立偏好设置窗口

## 数据来源与隐私

本项目目前不是直接连接 OpenAI 官方 API。应用会连接以下后端：

应用默认迁移并使用 `https://sub2apis.ruobin.dev`，也可以在“设置 → 站点”中添加其他 Sub2API 兼容站点。

用户在设置中填写的是对应 Sub2API 站点的账号和密码，不应填写 OpenAI、ChatGPT 或其他服务的账号密码。每个站点的凭据在本机应用支持目录中独立保存。登录时，凭据会通过 HTTPS 发送到该站点的 `/api/v1/auth/login`；随后应用使用短期访问令牌读取：

- `/api/v1/subscriptions?timezone=<站点时区>`：每周已用额度和每周总额度
- `/api/v1/keys`：API Key 名称、启用状态和当前并发
- `/api/v1/usage/dashboard/stats`：累计 Token 和累计实际消费金额
- `/api/v1/usage/dashboard/api-keys-usage`：启用 API Key 的当日实际用量
- `/api/v1/usage`：API Key、模型、推理强度、实际费用和时间

macOS 版本不访问系统钥匙串，也不把账号密码写入源码或 `UserDefaults`。凭据文件未加密，但仅授予当前 macOS 用户读写权限；同一用户权限下运行的其他进程仍可能读取。访问令牌仅保存在应用进程内存中。源码没有集成额外的分析或遥测服务。

应用支持保存多个站点、切换当前站点、配置反向代理路径与时区，并通过“测试连接”检测接口能力。首版兼容范围是 Sub2API 及其保持接口契约的部署，不承诺兼容 One API、New API 或私有中转系统。累计指标、API Key 当日用量或使用记录等可选接口缺失时，对应内容会隐藏或显示 `--`，不会把缺失数据解释为零。

公开部署或分发前，请自行评估并信任所配置的后端。

## macOS 构建

要求：

- macOS 14 或更高版本
- Swift 6.2 工具链
- Xcode Command Line Tools

运行测试并构建：

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
zsh scripts/install-app.sh
zsh scripts/build-dmg.sh
```

构建产物会写入本地 `outputs/` 目录，该目录不会提交到 Git。

## 项目结构

```text
Sources/QuotaBar/         macOS 应用源码
Tests/                    macOS 自检
Assets/                   macOS 图标资源
scripts/                  macOS 构建与打包脚本
```

## 分发说明

本地脚本生成的 macOS 应用当前采用 ad-hoc 签名，并未包含 Apple Developer ID 签名或公证。面向他人分发时，建议使用自己的 Developer ID 对应用签名并提交 Apple notarization，以减少 Gatekeeper 警告。

## 许可证

项目源码采用 [MIT License](LICENSE) 发布。
