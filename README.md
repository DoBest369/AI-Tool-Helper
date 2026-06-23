# AI工具助手

多功能本地 macOS AI 工具助手（纯 AppKit · 单文件 Swift · 无第三方依赖）。Mac App Store / 系统设置风格的侧边栏界面，集成用量统计、项目管理、AI 提示词工作台、语音输入与 CLI 版本/配置管理。

## 模块总览

左侧边栏分三组切换，全部内嵌同一窗口：

### 工作区
- **用量统计**：离线统计 Claude Code / Codex / Gemini / OpenCode 的 token 用量与成本估算（趋势图柱 hover、来源占比堆叠条、分组占比 %、较昨日方向箭头、排序、多维筛选持久化与一键重置、CSV / JSON 导出、复制今日摘要 / 当前范围报告、扫描范围说明、打开数据文件夹）。
- **项目管理**（Cmd+J）：管理多个项目的「背景信息」「项目资料」与「提示词库」。SQLite 持久化（可导出 / 导入 JSON）；提示词可收藏 / 复制 / 编辑 / 删除 / AI 处理；项目可**另存副本**、**复制为 Markdown**；项目列表过滤、背景 / 资料字数、提示词库计数；空状态引导；顶部「跨项目搜索历史提示词」检索并复用到当前项目。

### AI 助手（独立于 cvm，单独配置 API Key）
- **语音输入**（全局快捷键 **默认 ⌥⌘Space，可自定义录制**）：悬浮玻璃面板，按麦克风录音 → SFSpeechRecognizer 实时转写（**语言可选**：中/英/日/韩/粤）→ 可编辑 → AI 矫正（可设为停止后自动）/ 复制 / 粘贴到前台输入框 / 送入工作台。**非输入法**。侧边栏「语音输入」为配置页（快捷键/权限状态+引导/识别语言/AI 矫正开关）。
- **AI 提示词工作台**（Cmd+I）：输入 → **AI 优化 / 中译英·英译中（双向）/ 扩写 / 缩写 / 总结 / 改语气（正式·口语）/ 自定义指令** → 可编辑结果 → 复制 / 存为项目提示词 / **存入项目资料**（追加，构建「AI 产出→项目上下文」知识闭环）。可关联项目读背景+资料作上下文（**持久上下文徽标** + 记忆上次项目）；「搜索历史提示词复用」跨项目检索；「剪贴板历史」回取最近复制；结果「替换输入」继续迭代、「**重新生成 ⌘R**」重跑同动作、「**新会话 ⌘N**」一键清空重来；**输入/结果草稿持久化**（关窗/重启不丢）；开窗即聚焦输入、按内容智能禁用按钮、字数统计与占位提示；快捷键 ⌘↩ 优化 / ⌘T 中译英 / ⌘S 存为提示词 / ⌘R 重新生成 / ⌘N 新会话。
- **AI 设置**：配置 **提供商（Anthropic /v1/messages 或 OpenAI 兼容 /v1/chat/completions）** + API 端点 / Key / 模型（独立于 cvm）。含 provider 切换提示、模型下拉预设、端点「恢复默认」、provider 感知的「获取 API Key」链接、「已配置」状态指示、「测试连接」（spinner + 端点容错 + 错误友好化，端点/Key 齐全才可点）。

### CLI 管理（基于 cvm — Claude/Codex 版本管理器；未安装时显示友好引导）
- **版本管理**（Cmd+M）：列出/安装/切换/卸载/更新 Claude、Codex CLI 版本（GUI 原生行内操作，无需输命令）；含「诊断（doctor）」「更新 cvm（self-update）」。
- **配置管理**（Cmd+K）：读写 Claude/Codex 的 API URL / Key / 模型（字段行 + 行内编辑/清除，密钥显隐）。
- **供应商管理**（Cmd+G）：按工具（Claude Code / Codex / Gemini）分 Tab 管理多套供应商 API 配置（名称 / 端点 / Key / 模型，协议随工具固定，单独卡片添加）；一键「切换」把某供应商写入对应工具配置文件（Claude `~/.claude/settings.json`、Codex `~/.codex/config.toml` + `auth.json`、Gemini `~/.gemini/.env`，写前自动备份）。可在「数据」菜单导出 / 导入配置 JSON。
- **中枢网关**：本地通用 API 网关——聚合多供应商，自动**协议互转（Anthropic ↔ OpenAI）+ 模型名映射 + 按优先级故障转移**，让一个工具透明调用任意供应商 / 模型（如 Claude Code 调 OpenAI 模型、Codex 调 Claude 模型）。启停 / 配端口 / 勾选故障转移链与优先级 / 实时请求日志 / 一键复制网关地址；空链与端口占用有清晰提示。
- **代理配置**：管理 SOCKS5 / HTTP 代理节点，TCP 延迟测速、「测速并选最低」自动切换，写入工具代理环境变量（HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）。可导出 / 导入。

> 「数据」菜单还含：**定价配置**（可视化编辑每百万 token 价格规则，保存即重算成本）、扫描范围说明、打开数据文件夹、导出 CSV/JSON、供应商/代理配置导出导入等。

> 菜单栏状态项：sparkles 图标 + 今日 token 总量，下拉含「今日 tokens · 约 $成本」概览 + 「复制今日摘要」+ 快捷入口（主窗 / 工作台 / 语音 / 项目 / AI 设置）。应用菜单含「快捷键参考（⌘/）」。

### 中枢网关使用示例

让 Claude Code 透明调用 OpenAI / DeepSeek 等模型（或 Codex 调 Claude）：

1. **供应商管理**：按工具添加好供应商（端点 / Key / 模型），例如在 Codex tab 加 DeepSeek、在 Claude tab 加官方。
2. **中枢网关**：勾选要纳入故障转移链的供应商、用 ↑↓ 调优先级，点「启动网关」（默认 `http://127.0.0.1:8787`，可改端口），「复制地址」拿到网关 URL。
3. **把工具指向网关**：将工具的 API 端点设为网关地址即可——
   - Claude Code：`ANTHROPIC_BASE_URL=http://127.0.0.1:8787`
   - OpenAI 兼容工具：`base_url=http://127.0.0.1:8787`

网关按优先级把请求转发到供应商，**自动协议互转（Anthropic ↔ OpenAI）+ 模型名映射 + 失败故障转移**；运行状态行实时显示「已转发 N 请求 / M tokens」。

> 流式：同协议的 `stream:true` 请求支持 **SSE 流式透传**（边收边发），适配 Claude Code / Codex 等默认流式的工具；跨协议（如 Anthropic 进、OpenAI 出）目前走非流式，流式转换在路线图上。

## 构建

```sh
chmod +x build.sh
./build.sh                     # 产物：dist/AI工具助手.app
```

### 签名（语音/麦克风权限所需，推荐）
非语音功能可直接运行二进制；但**语音功能必须用 `open dist/AI工具助手.app` 或访达双击启动**——直接执行二进制（或从 VSCode 终端启动）时责任进程不是 App 自身，TCC 找不到麦克风/语音用途说明会导致崩溃。
有 Apple 开发者证书时可正式签名（hardened runtime + entitlements 自动附带），则任意方式启动语音权限都稳：

```sh
security find-identity -v -p codesigning           # 查看可用证书名
CODESIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)" ./build.sh
```

未设 `CODESIGN_IDENTITY` 时为 ad-hoc 签名（本机可运行，语音权限在正式签名下最稳）。

## CLI 验证（用量统计）

```sh
"dist/AI工具助手.app/Contents/MacOS/ClaudeTokenUsage" --cli
"dist/AI工具助手.app/Contents/MacOS/ClaudeTokenUsage" --cli --json
"dist/AI工具助手.app/Contents/MacOS/ClaudeTokenUsage" --cli --rescan
```

## 用量统计扫描范围

- `~/.claude/projects/**/*.jsonl`
- `~/.codex/sessions/**/*.jsonl`（含 `event_msg / token_count` 累计差分去重）
- `~/.gemini/tmp/*/chats/session-*.json`
- `~/.local/share/opencode/storage/message/**/*.json`
- 按 `message.id` / `requestId` / usage 签名分层去重；支持今天/近7天/本月/全部、来源筛选、按日期/项目/模型/会话/来源分组、搜索、导出。

## 数据位置

```text
~/Library/Application Support/AI工具助手/
├── usage-cache.sqlite      # 用量缓存
├── projects.sqlite         # 项目/提示词库
└── pricing.json            # 成本估算定价规则（缺失自动写默认模板）
```

UserDefaults（独立于 cvm）：AI 配置 `ai.provider` / `ai.baseURL` / `ai.apiKey` / `ai.model`；工作台 `ai.inputDraft` / `ai.resultDraft`（输入/结果草稿）/ `ai.lastProjectId`（上次关联项目）；用量筛选 `filter.source` / `filter.scope` / `filter.grouping`；语音 `voice.hotKeyCode/Mods/Label`（自定义快捷键）/ `voice.locale`（识别语言）/ `voice.autoCorrect`；`clipboard.history`（剪贴板历史，最近 20 条）。

## 设计与架构

- 风格：iOS 26 / macOS Tahoe Liquid Glass 液态玻璃，随系统深浅外观自适应；侧边栏 vibrant + 内容区卡片（App Store 式投影）。
- 单 Swift 文件 `Sources/ClaudeUsageApp.swift`，swiftc 编译，链接 Cocoa / Carbon / AVFoundation / Speech / sqlite3。
- 详见 `CLAUDE.md`（架构与约定）与 `ITERATION_LOG.md`（迭代日志）。
