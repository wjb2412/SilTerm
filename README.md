# SilTerm

**macOS 原生终端，Warp 的轻量化实现。**

纯 Swift + AppKit 构建，终端仿真内核为内置的 [libvterm](https://github.com/neovim/libvterm)（唯一外部依赖），
不使用 Electron / CEF / WebView，不引入任何运行时框架。目标是：**启动快、内存小、Pane 操作顺手**。

- 版本：1.0.0
- 系统要求：macOS 13 Ventura 及以上（推荐 14+），Apple Silicon 原生
- 语言 / 工具链：Swift 5.9+，Swift Package Manager

---

## 特性

### Pane 与 Tab

- **分片**：`⌘D` 垂直分割、`⇧⌘D` 水平分割，任意层级嵌套，`⌘[` / `⌘]` 循环聚焦
- **拖拽**：Pane 可拖到其他 Tab、拖出窗口创建新窗口，全程保留 PTY 进程与工作目录
- **右键菜单**：分割、关闭、聚焦、重命名
- **会话持久化**：全部窗口 / Tab / Pane 布局与各自 CWD 写入 `session.json`，重启自动重建 PTY

### 终端能力

- **中文输入法**：完整实现 `NSTextInputClient`，支持拼音 / 双拼 / 五笔等，组字期间下划线预览、候选窗锚定光标
- **精确网格渲染**：按单元格网格锚定绘制，宽字符单独定位，光标与文字严格对齐
- **回滚缓冲**：默认 10,000 行，独立于 libvterm 屏幕缓冲
- **选择与复制**：鼠标拖选、双击选词、`⌘C` / `⌘V`；可选「选中即复制」
- **命令历史搜索**：`⌘R` 本地检索 zsh / bash / fish 历史，回车直接插入
- **路径预览**：鼠标悬停文件路径时通过 QuickLook 弹出缩略图（可关闭）
- **字体缩放**：`⌘=` / `⌘-` 实时调整

### 外观

- 主题：暗黑 / 浅色 / 高对比 / 自定义（`.toml` 导入导出）
- 字体、字号、行高倍数、背景不透明度
- 光标样式（方块 / 竖线 / 下划线）与闪烁开关
- 窗口使用 `NSVisualEffectView` 毛玻璃背景

### 访达互通

| 方向 | 能力 |
|---|---|
| 终端 → 访达 | 右键「在访达中打开当前路径」 |
| 访达 → 终端 | 服务菜单「在此文件夹打开 SilTerm（新 Pane / 新 Tab）」 |
| 访达 → 终端 | 对**文件**右键「在 SilTerm 中打开所在目录（新 Pane / 新 Tab）」 |
| 访达 → 终端 | 文件夹直接拖到 Dock 图标打开 |

服务菜单首次使用需在 **系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹** 中勾选。

### 设置面板

7 个分类：通用 / 外观 / Pane / 快捷键 / 剪贴板 / 集成 / 高级。
配置文件为纯文本 JSON：

```
~/.config/SilTerm/settings.json   # 设置
~/.config/SilTerm/session.json    # 会话快照
```

---

## 性能实测

| 指标 | 目标 | 实测 |
|---|---|---|
| 启动到 shell 就绪 | < 0.5s | **0.186s** |
| 单 Pane 应用私有内存 | ≤ 20MB | **14MB** |
| 4 Pane 应用私有内存 | 每 Pane +5~8MB | **15MB（增量 < 1MB）** |
| 空闲 RSS | ≤ 30MB | 约 94MB（见下方说明） |

> **关于内存口径**：macOS 会把 Metal / WindowServer 的图形内存（IOSurface、graphics footprint）计入进程 footprint，
> 这部分与业务代码无关，且随显示环境浮动。因此本项目以「应用私有 malloc」作为主口径：
> 单 Pane 14MB，4 Pane 15MB。若按 `footprint` 口径，图形记账约 51MB、IOSurface 约 35MB，30MB 目标在该环境下不可达。

复测方式见 [`scripts/measure-memory.sh`](scripts/measure-memory.sh)。

---

## 快速开始

### 环境

- macOS 13+（推荐 14+）
- Xcode Command Line Tools 或 Xcode 15+（`xcode-select --install`）
- 无需 Homebrew，libvterm 源码已内置

### 构建与运行

```bash
git clone <仓库地址>
cd SilTerm

# 构建 release + 组装 .app（产物：build/SilTerm.app）
bash scripts/build-app.sh

open build/SilTerm.app
```

需要同时产出 Intel 版本时：

```bash
bash scripts/build-app.sh --universal
```

打包脚本会完成：`swift build -c release` → 组装 `.app` → 拷贝图标与 Info.plist → ad-hoc 签名 → 注册 LaunchServices。

### 直接编译

```bash
swift build -c release
.build/release/SilTerm
```

---

## 快捷键（Warp 预设）

| 操作 | 快捷键 |
|---|---|
| 垂直分割 Pane | `⌘D` |
| 水平分割 Pane | `⇧⌘D` |
| 关闭 Pane | `⌘W` |
| 上一个 / 下一个 Pane | `⌘[` / `⌘]` |
| 新建 Tab | `⌘T` |
| 恢复关闭的 Tab | `⇧⌘T` |
| 关闭 Tab | `⇧⌘W` |
| 上一个 / 下一个 Tab | `⇧⌘[` / `⇧⌘]` |
| 搜索命令历史 | `⌘R` |
| 放大 / 缩小字体 | `⌘=` / `⌘-` |
| 打开设置 | `⌘,` |
| 新建窗口 | `⌘N` |
| 关闭窗口 | `⌥⌘W` |

所有键位均可在设置 → 快捷键中修改，修改后立即生效。

---

## 目录结构

```
Sources/
  CVTerm/         内置 libvterm（C 源码）+ C bridge
  CShim/          forkpty / TIOCSWINSZ / proc_pidinfo（C）
  SilTermCore/    TerminalEmulator、PTYProcess、TerminalSession、
                  TerminalTheme、AppSettings、SessionStore、PathResolver
  SilTerm/        AppDelegate、MainWindowController、TerminalView、
                  PaneContainerView、PaneTree、TabBarView、TabContentController、
                  SettingsWindow、MainMenu、FinderBridge、PathPreviewController、
                  CommandHistoryPanel
Resources/
  Info.plist      应用元信息 + 4 项访达服务声明
  AppIcon.icns    应用图标
scripts/
  build-app.sh    构建 + 打包
  make-icon.sh    由一张方形插画生成 AppIcon.icns
  make-icon.swift 图标生成核心逻辑（去水印 / 圆角 / 全尺寸）
  measure-memory.sh 内存采样
```

---

## 实现要点

### libvterm 回调生命周期

`vterm_screen_set_callbacks(screen, callbacks, user)` **只保存结构体指针、不拷贝内容**。
若在 Swift 栈上声明 `var callbacks`，函数返回后即悬垂，resize 时会 SIGSEGV。
本项目将回调结构体用 `UnsafeMutablePointer` 堆分配，与 `TerminalEmulator` 同生命周期释放。

### CWD 查询

使用 `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, ...)` 直接读取 shell 进程的 vnode 路径，
无需向 shell 注入任何 hook，因此对 zsh / bash 均生效，且不会污染命令历史。

### 渲染

- `NSView` + `isFlipped`，CoreGraphics 绘制单元格背景，文本按网格分段锚定绘制
- 样式（前景色 / 加粗 / 斜体 / 下划线 / 删除线）去重缓存，避免逐字符创建属性字典
- 宽字符按两格定位，光标与文字共用同一套网格坐标

### 输入

- 方向键 / 回车 / 退格 / 功能键直接编码为 VT 序列发往 PTY
- `Option` 作为 Meta 发送 ESC 前缀，`Ctrl` 组合生成控制码
- 普通可打印字符交给 `interpretKeyEvents`，由输入法决定提交或进入组字状态

---

## 明确不做

AI / LLM 能力、WebView、云同步、独立 SSH 面板、图片渲染与 kitty 协议、插件市场、远程协作。

---
