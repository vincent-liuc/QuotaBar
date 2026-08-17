# QuotaBar

一个原生的 macOS 菜单栏用量监控工具。它可以保存和切换多个 Sub2API 或 New API / One API 站点，定时读取额度、API Key 用量和使用记录，并用菜单栏小猫的填充高度展示整体进度。

> [!IMPORTANT]
> 这是第三方开源项目，与 Sub2API 及其部署方没有隶属、授权或背书关系。

![应用图标](Assets/AppIcon-1024.png)

## 功能

- 菜单栏动态小猫展示当前站点已用额度 / 总额度，液面从下向上填充并带轻微水波：低于 70% 为绿色，达到 70% 为橙色，达到 90% 为红色，尾巴会轻柔摆动
- 毛玻璃弹窗展示周订阅或 New API 账户总量、余额、Token、请求次数与消费金额
- 展示除 `inactive` 外所有 API Key 的当日用量和可选额度进度；有请求运行时同步显示当前并发
- API Key 按当日实际用量从高到低排列
- 在固定高度内滚动展示站点时区内最近两天的最新 50 条使用记录
- 周额度环形图显示距离下次重置的时间
- 可为每个站点单独开启周期重置联动（默认关闭）：检测到周重置时间向后跳变后，将所有非 `inactive` API Key 的已用额度清零
- 可在设置中分别隐藏累计指标卡片、API Key 明细和使用记录
- 设置项实时生效，文本输入在失焦后保存
- 账户设置支持密码显隐，并可只调用登录接口验证账号密码
- 菜单栏小猫以从下到上的彩色水波填充表示已用比例，并与弹窗中的绿色、橙色、红色阈值保持一致
- 刷新频率可设置为 5-3600 秒
- 账号和密码保存在 `~/Library/Application Support/QuotaBar/credentials.json`
- 应用支持目录权限为 `700`、凭据文件权限为 `600`，应用不访问 macOS 钥匙串
- 支持使用 macOS 原生登录项开机启动
- 设置内支持立即更新：下载最新 universal DMG、校验 SHA-256、自动替换应用并重新启动
- 默认每天本地时间 12:00 自动检查并安装更新，可在“设置 → 更新”中关闭自动更新
- 更新下载通过 GitHub Asset API 获取，并为慢速网络保留最长 10 分钟下载时间与断线重试
- 当前版本：1.11.12
- 提供独立偏好设置窗口

## 数据来源与隐私

本项目目前不是直接连接 OpenAI 官方 API。应用会连接以下后端：

应用默认迁移并使用 `https://sub2apis.ruobin.dev`，也可以在“设置 → 站点”中添加其他站点，并选择 `Sub2API` 或 `New API / One API` 类型。

用户在设置中填写的是对应 Sub2API 站点的账号和密码，不应填写 OpenAI、ChatGPT 或其他服务的账号密码。每个站点的凭据在本机应用支持目录中独立保存。登录时，凭据会通过 HTTPS 发送到该站点的 `/api/v1/auth/login`；随后应用使用短期访问令牌读取：

- `/api/v1/subscriptions?timezone=<站点时区>`：选中订阅的每日/每周已用额度、额度上限和重置窗口
- `/api/v1/keys`：API Key 名称、启用状态和当前并发
- `PUT /api/v1/keys/{id}`：仅在站点开启周期重置联动且检测到新周期时，以 `reset_quota` 清零 API Key 已用额度
- `/api/v1/usage/dashboard/stats`：累计 Token 和累计实际消费金额
- `/api/v1/usage/dashboard/api-keys-usage`：启用 API Key 的当日实际用量
- `/api/v1/usage`：API Key、模型、推理强度、实际费用和时间

New API 站点使用账号密码登录 `/api/user/login`，兼容站点返回的 Cookie 会话或 Bearer Token；后续请求携带 `New-API-User: <用户 ID>`，并在可用时携带 Bearer Token，读取：

- `/api/status`：`quota_per_unit`、人机验证开关和额度展示规则
- `/api/user/self`：账户余额 `quota`、历史消耗 `used_quota` 和请求次数 `request_count`；账户总量按 `(quota + used_quota) / quota_per_unit` 计算
- `/api/token`：令牌状态、剩余额度 `remain_quota`、已用额度 `used_quota`、无限额度和分组
- `/api/data/self`：当天 Token 统计
- `/api/log/self/stat`：按令牌查询当天 quota；应用按 `quota / quota_per_unit` 换算为美元
- `/api/log/self`：当天最近使用记录，并从 `other.reasoning_effort` 映射推理强度

macOS 版本不访问系统钥匙串，也不把账号密码写入源码或 `UserDefaults`。凭据文件未加密，但仅授予当前 macOS 用户读写权限；同一用户权限下运行的其他进程仍可能读取。访问令牌仅保存在应用进程内存中。源码没有集成额外的分析或遥测服务。

应用支持保存多个站点、切换当前站点、配置反向代理路径与时区，并通过“测试连接”检测接口能力。New API 的 `quota_per_unit` 必须可读取；启用 Turnstile 或 2FA 的站点无法由桌面应用自动完成登录。可选接口缺失时，对应内容会隐藏或显示 `--`，不会把缺失数据解释为零。

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
