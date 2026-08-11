# OpenAI用量

一个原生的 macOS 菜单栏用量监控工具。它定时读取指定账号的每周订阅用量和 API Key 用量，并用菜单栏环形图展示整体进度。

> [!IMPORTANT]
> 这是第三方开源项目，与 OpenAI, L.L.C. 没有隶属、授权或背书关系。OpenAI 名称及标志属于其各自权利人。

![应用图标](Assets/AppIcon-1024.png)

## 功能

- 菜单栏环形图展示每周已用额度 / 每周总额度
- 弹窗展示订阅合计及每个启用 API Key 的当日用量
- API Key 按当日实际用量从高到低排列
- 刷新频率可设置为 5-3600 秒
- 账号和密码保存在 macOS 钥匙串
- 支持使用 macOS 原生登录项开机启动
- 提供独立偏好设置窗口

## 数据来源与隐私

本项目目前不是直接连接 OpenAI 官方 API。应用会连接以下后端：

```text
https://sub2apis.ruobin.dev
```

用户在设置中填写的是该后端的账号和密码，不应填写 OpenAI、ChatGPT 或其他服务的账号密码。登录时，凭据会通过 HTTPS 发送到该后端的 `/api/v1/auth/login`；随后应用使用短期访问令牌读取：

- `/api/v1/subscriptions?timezone=Asia/Shanghai`：每周已用额度和每周总额度
- `/api/v1/keys`：API Key 名称和启用状态
- `/api/v1/usage/dashboard/api-keys-usage`：启用 API Key 的当日实际用量

macOS 版本将账号和密码保存在系统钥匙串，不写入源码或 `UserDefaults`；访问令牌仅保存在应用进程内存中。源码没有集成额外的分析或遥测服务。

公开部署或分发前，请自行评估并信任该后端。若要连接其他服务，需要修改源码中的 API 地址及接口协议。

## macOS 构建

要求：

- macOS 14 或更高版本
- Swift 6.2 工具链
- Xcode Command Line Tools

运行测试并构建：

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
zsh scripts/build-dmg.sh
```

构建产物会写入本地 `outputs/` 目录，该目录不会提交到 Git。

## 项目结构

```text
Sources/OpenAIUsageBar/   macOS 应用源码
Tests/                    macOS 自检
Assets/                   macOS 图标资源
scripts/                  macOS 构建与打包脚本
```

## 分发说明

本地脚本生成的 macOS 应用当前采用 ad-hoc 签名，并未包含 Apple Developer ID 签名或公证。面向他人分发时，建议使用自己的 Developer ID 对应用签名并提交 Apple notarization，以减少 Gatekeeper 警告。

## 许可证

项目源码采用 [MIT License](LICENSE) 发布。

图标素材的来源与商标限制见 [Third-Party Notices](THIRD_PARTY_NOTICES.md)。
