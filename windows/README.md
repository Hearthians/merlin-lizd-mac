# TmuxHub for Windows

Windows 版是仅远程客户端：它使用 Windows 自带的 OpenSSH 连接 Linux/Unix 主机上的
tmux 会话，并在独立控制台中打开交互终端。不安装本机 tmux，不依赖兼容层，也不在
应用内嵌终端。

## 要求

- Windows 10 19041 或更新版本，x64。
- 从源码构建或运行安装脚本需要
  [.NET 8 SDK x64](https://dotnet.microsoft.com/download/dotnet/8.0)；仅运行已发布程序需要
  .NET 8 Desktop Runtime x64。
- Windows “OpenSSH Client” 可选功能，默认程序路径为
  `C:\Windows\System32\OpenSSH\ssh.exe`。
- 远端已安装 tmux；如使用 Herdr 页面，远端还需已有可连接的 Herdr 服务。
- 建议先在普通控制台运行一次 `ssh <目标>`，完成主机密钥确认与密钥/Agent 认证。

主机库读取 `%USERPROFILE%\.ssh\config` 以及其中的 `Include`。端口、用户名、私钥、
ProxyJump 等连接细节继续由 OpenSSH 配置管理。

## 构建和测试

在 `D:\lizd` 下的仓库根目录运行：

```powershell
.\windows\build.ps1
```

脚本还会运行 `TmuxHub.Windows.Tests` 中的离线测试。只构建时可使用：

```powershell
.\windows\build.ps1 -SkipTests
```

也可直接运行测试程序：

```powershell
dotnet run --project .\windows\TmuxHub.Windows.Tests\TmuxHub.Windows.Tests.csproj
```

测试不连接真实 SSH 主机，覆盖目标与 tmux 标识校验、稳定会话名哈希、tmux 列表解析、
Windows SSH `Include`、状态持久化，以及本地/远端参数边界。

## 安装

```powershell
.\windows\install.ps1
```

安装脚本先构建并测试，然后将 framework-dependent `win-x64` 版本发布到
`windows\publish`，并生成固定入口：

```text
D:\lizd\app\TmuxHub.lnk
```

它不会向桌面、开始菜单或系统目录写入文件。已单独运行过测试时，可以执行：

```powershell
.\windows\install.ps1 -SkipTests
```

发布为 framework-dependent，目标机器必须安装 .NET 8 Desktop Runtime x64。

## 使用

1. 从左侧选择 SSH config 中的主机，或添加 `host`、`user@host`、IPv4/IPv6 目标。
2. 刷新远端 tmux 会话，或输入安全的会话名后创建/接入。
3. “打开会话”会启动独立的 `ssh.exe` 控制台；关闭 TmuxHub 不会终止远端 tmux。
4. 重命名和终止属于显式远端操作；普通关闭只断开 SSH。

应用状态保存在 `%LOCALAPPDATA%\TmuxHub\state.json`。私钥、密码、SSH 配置内容和
远端命令输出不会写入该状态文件。

## 安全边界和限制

- `ssh.exe` 使用绝对路径启动，参数保持独立，不经过 `cmd.exe` 或 PowerShell。
- 后台查询使用 `BatchMode=yes` 和超时；交互认证只出现在独立 SSH 控制台。
- SSH 目标拒绝前导 `-`、空白、控制字符和 shell 元字符；tmux 会话名限制为
  1–64 个安全字符。
- Windows 版不保存 SSH 密码。使用 OpenSSH 私钥、配置和 Windows ssh-agent。
- 当前每次操作建立独立 SSH 连接，不依赖 ControlMaster。
- 用户的 SSH config 是受信任的 OpenSSH 配置边界；其中的 `ProxyCommand`、
  `Match exec` 等规则可能启动用户配置的本地程序。
- 当前版本不提供本机 shell、本机 tmux 或内嵌 PTY。
