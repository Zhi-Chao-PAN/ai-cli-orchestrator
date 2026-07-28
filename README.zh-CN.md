# AI CLI Orchestrator

aiw 是一个 Windows PowerShell 调度器：它把已经登录的 Gemini、
MiniMax、方舟 Coding 和方舟 Agent CLI 作为有边界的 worker 使用，
而 Codex 或人工始终负责拆分任务、审查改动和最终验收。

它不保存 API Key、Token 或 OAuth 凭据；各官方 CLI 继续使用自己的
认证存储。

## 快速安装

~~~powershell
Set-Location path\to\ai-cli-orchestrator
.\install.ps1 -AddToPath -InstallCodexSkill
~~~

安装后重开终端，再检查本机状态：

~~~powershell
aiw status -Json
aiw doctor -Json
~~~

如果不想修改 PATH，可直接调用：

~~~powershell
& (Join-Path $env:LOCALAPPDATA 'aiw\bin\aiw.ps1') doctor -Json
~~~

## 默认路由

1. google：Gemini / Antigravity，适合独立审查和长上下文分析。
2. minimax：无状态文本与推理；不提供仓库写入能力。
3. ark：方舟 Coding，默认 glm-5.2；只读失败时可由 Kimi-K2.7-Code
   作为受控备选。
4. agent：方舟 Agent 的独立配置与额度。
5. 单独配置且明确授权后，才使用按量模型。

能力和安全边界优先于路由顺序。任务很小、强依赖持续判断、涉及敏感内容、
破坏性操作，或验收成本高于直接完成时，应由 Codex 直接处理。

## 使用示例

~~~powershell
aiw google -PromptFile 'C:\tmp\review.md' -Mode read -WorkingDirectory 'C:\repo' -Json
aiw minimax -PromptFile 'C:\tmp\design.md' -Mode read -Json
aiw ark -PromptFile 'C:\tmp\implementation.md' -Mode write -WorkingDirectory 'C:\repo' -Json
aiw agent -PromptFile 'C:\tmp\agent.md' -Mode read -Json
~~~

复杂任务始终使用 UTF-8 的 PromptFile。可从 WORK_ORDER_TEMPLATE.md
开始，明确目标、允许改动的路径、禁止项和验收命令。

外层调用的超时必须至少比 TimeoutSeconds 多 30 秒，才能让 aiw 正常终止
进程树并返回结构化超时结果。

## 配置

复制 config.example.json 到用户配置目录后再改模型或可执行文件路径：

~~~powershell
$configDirectory = Join-Path $env:USERPROFILE '.aiw'
New-Item -ItemType Directory -Force $configDirectory
Copy-Item .\config.example.json (Join-Path $configDirectory 'config.json')
~~~

配置优先级：显式 -ConfigPath、AIW_CONFIG_PATH、用户配置文件。
也可通过 AIW_ARK_PATH、AIW_AGENT_PATH、AIW_GOOGLE_PATH、AIW_MINIMAX_PATH
覆盖可执行文件。配置文件中绝不能放入密钥。

## 安全与验收

- 默认只读；写入必须显式指定 Mode write。
- 方舟和 Agent 工作单经标准输入传递；MiniMax 使用短生命周期 UTF-8 JSON 消息文件；
  Google 使用立即清理的临时工作单目录。任务正文不会出现在 provider
  进程参数中。
- stdout 与 stderr 分开处理，只有 stdout 尝试按 JSON 解析；stderr 经
  脱敏后作为 diagnostics。
- Google 保留目录白名单与终端沙箱；不要以全局文件权限或绕过权限作为修复。
- 多个写 worker 必须各自使用 Git worktree；禁止在同一工作区并发写入。
- worker 的成功文本只是传输证据，必须由 Codex 审查 diff 并执行本地验收。

开发与安全报告请分别查看 CONTRIBUTING.md 和 SECURITY.md；许可证为 MIT。
