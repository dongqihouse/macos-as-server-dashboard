# macOS as Server Dashboard

一个贴在 macOS 桌面上的轻量服务观测面板，用来快速查看本机容器服务、Docker 容器和本机状态。

## 功能

- 桌面贴附：窗口默认放在桌面层级，并出现在所有 Space。
- 本机状态：展示存储已用/总量、CPU 占用、内存已用/总量和网络连通性。
- 服务区分：本机容器服务、Docker 容器分区展示。
- 端口连通性：用 `nc` 检测 TCP 端口是否可连接。
- 端口备注：每个端口都可以写备注，保存到配置文件。
- 开机自启：支持通过 LaunchAgent 自动打开 dashboard。
- 服务自启动：dashboard 启动时可自动执行配置里的本机服务命令。
- GUI 管理：可以在面板里新增、编辑、启动、停止、删除本机容器服务。
- 日志查看：本机容器服务可在 dashboard 内查看最近日志，也可以打开原始日志文件。
- 应用内更新：可以从 GitHub Release 检查新版本，校验 SHA256 后安装更新包。
- 配置热更新：外部修改配置文件后，dashboard 会自动重新读取并刷新 UI。
- 错误提示：启动失败、服务异常退出、配置读写失败会弹窗提示，服务错误可直接查看日志。

## 运行

```bash
swift run MacServerDashboard
```

首次运行会创建配置文件：

```text
~/Library/Application Support/MacServerDashboard/config.json
```

也可以参考仓库里的 `config.sample.json`。

## 构建 Release

```bash
scripts/package-release.sh v0.1.5
```

生成的安装包在：

```text
dist/MacServerDashboard-v0.1.5-macos-<arch>.dmg
```

打开 DMG 后，将 `MacServerDashboard.app` 拖到 `Applications`。

当前发布包会做 ad-hoc codesign，避免 macOS 将 app bundle 识别为损坏。若需要完全消除 Gatekeeper 提示，需要使用 Apple Developer ID 证书签名并 notarize。

## 发布 GitHub Release

发布采用 tag 触发 GitHub Actions 的方式：本地只创建并推送版本 tag，GitHub Actions 在 macOS runner 上构建包、生成 SHA256 校验文件，并用 GitHub CLI 创建 Release 和上传资产。

1. 更新 `Sources/MacServerDashboard/AppVersion.swift` 里的 `AppVersion.current`。
2. 确认工作区干净并提交所有变更。
3. 创建并推送版本 tag：

```bash
scripts/release.sh v0.1.0
```

4. GitHub Actions 会生成并上传：

```text
MacServerDashboard-v0.1.0-macos-<arch>.dmg
MacServerDashboard-v0.1.0-checksums.txt
```

也可以只在本机打包验证：

```bash
scripts/package-release.sh v0.1.0
```

生成的文件会放在 `dist/`。应用内置更新可以读取 GitHub latest release，选择 `MacServerDashboard-*-macos-*.dmg` 资产下载，并用同版本 `checksums.txt` 校验 SHA256。

## 应用内更新

右上角菜单里点击“检查更新”，dashboard 会读取 GitHub latest release。发现新版本后，用户确认安装即可自动下载当前架构的 DMG、校验 SHA256，并替换当前 `MacServerDashboard.app`。安装过程会显示进度，安装完成后 dashboard 会自动重启。

## 安装开机自启

可以在 dashboard 右上角点击闪电图标安装，也可以运行：

```bash
chmod +x scripts/install-launch-agent.sh scripts/uninstall-launch-agent.sh
scripts/install-launch-agent.sh
```

卸载：

```bash
scripts/uninstall-launch-agent.sh
```

## 配置本机服务

点击“本机容器服务”分组右侧的加号，可以在 GUI 中新增服务。表单里的“监控端口（可选）”只用于连通性检测和备注，不会改变启动命令。`localServices` 也可以手动声明需要展示和可自启动的本机服务：

```json
{
  "id": "homepage",
  "name": "Homepage",
  "command": "npm run dev -- --host 0.0.0.0 --port 3000",
  "workingDirectory": "~/Sites/homepage",
  "autoStart": true,
  "note": "本机 Node 服务",
  "ports": [
    {
      "host": "127.0.0.1",
      "port": 3000,
      "protocolName": "tcp",
      "note": "Homepage HTTP"
    }
  ]
}
```

服务自身 `autoStart` 为 `true` 时，dashboard 启动会执行对应命令。服务输出写入：

```text
~/Library/Logs/MacServerDashboard/
```

服务启动时会优先解析 NVM Node 路径：先使用服务工作目录下的 `.nvmrc`，其次使用 `~/.nvm/alias/default`，最后使用已安装的最高 Node 版本，并只把选中的 `~/.nvm/versions/node/<version>/bin` 放进 `PATH`。同时会补充 `~/.bun/bin`、`~/.local/bin`、`~/.cargo/bin`、Docker Desktop CLI 路径，避免 macOS GUI 启动环境找不到 Node、Bun、Docker、`lark-cli` 等工具。

Python/FastAPI 服务会额外优先使用工作目录下的 `.venv/bin` 或 `venv/bin`，也会补充 `~/.pyenv/shims`、`~/.asdf/shims`、`~/Library/Python/*/bin` 等常见路径。如果仍提示 `uvicorn: command not found`，建议把命令写成 `./.venv/bin/uvicorn ...` 或 `python -m uvicorn ...`。

## 日志

App 自身日志写入：

```text
~/Library/Logs/MacServerDashboard/app.log
```

本机服务日志也在同一目录。右上角菜单可以打开日志目录或直接打开 App 日志。

如果启动失败日志显示配置端口已被占用，dashboard 会只针对该服务配置的监控端口查找监听进程，先发送 `TERM`，端口仍未释放时再发送 `KILL`，然后重试启动一次。

## Docker 端口备注

Docker 容器端口的备注会写入 `portNotes`，key 格式是：

```text
host:port/protocol
```

例如：

```json
{
  "portNotes": {
    "127.0.0.1:8080/tcp": "Docker nginx"
  }
}
```
