# Compositor

Compositor 是一款完全免费开源的全功能图像编辑器，围绕合成（compositing）与照片后期处理的工作流打造，目标是做出像素级完美的最终成品。相比 Photoshop 的高昂价格和 GIMP 的割裂手感，它让熟悉 Photoshop 的人能一直保持在创作状态中。

本项目基于 [Robbie Tilton 的 Compositor](https://github.com/robbietilton/Compositor) 扩展：在原有 macOS 应用之上，把核心模型层（像素、渲染、滤镜、文字、文件格式）抽成跨平台的 SwiftPM 包，使同一套引擎可以在 Windows 与 Linux 上以无界面的 MCP 服务器形态运行。

## 安装（macOS）

### 下载
从 [robbietilton.com/compositor](https://robbietilton.com/compositor) 获取 Compositor，或直接从 [GitHub Releases](https://github.com/robbietilton/Compositor/releases/latest) 下载最新版本。

### Homebrew

```sh
brew install --cask robbietilton-compositor
```

## 功能特性

### 图层
- 图层与图层组，带不透明度和 Photoshop 全套混合模式（按 PS 菜单顺序排列）——组不透明度会整体压暗组内所有内容
- 图层蒙版：可绘制、填充、反相、模糊和羽化，覆盖范围可以超出图层自身像素；可链接/解链，单独变换蒙版
- 剪贴蒙版与组蒙版
- 调整图层：色相/饱和度、色阶、曲线、曝光、渐变映射、颗粒、黑白、色彩平衡、反相、高斯模糊、动感模糊和杂色
- 图层效果：描边、投影、颜色叠加、内阴影、外发光和内发光，GPU 渲染且随时可编辑
- 向下合并、合并图层与合并组（⌘E）
- 复制、行内重命名、拖拽排序与嵌套；Option 拖拽复制；图层面板右键菜单
- 整层与整组复制粘贴（⌘C/⌘V 无选区时），项目内或跨项目，也可在项目之间拖拽

### 变换
- 非破坏性移动、缩放、旋转和翻转——图缩小到多小都保留原始分辨率
- 自由扭曲（⌘ 拖动手柄），Shift 锁定轴向
- 多个图层或整个图层组一起变换
- 吸附到画布、图层边缘与中心，配合参考线
- 位置、尺寸、缩放与角度的精确数值，方向键微调
- 水平/垂直翻转图层与翻转画布

### 选区
- 矩形与椭圆选框、自由与多边形套索、魔棒/对象工具——魔棒按颜色选取，对象工具沿点击目标描边（Tab 切换）
- 主体选择，以及任意选区的扩展、收缩和羽化
- 选区加减、移动轮廓、移动或复制选区内像素
- 载入图层像素或蒙版作为选区
- 内容识别填充，也可以向图像边缘外扩展

### 绘画与修饰
- 画笔，带大小、硬度、不透明度与平滑，绘画/擦除两种模式（B 和 E），Shift 画直线
- 污点修复画笔（内容识别）
- 仿制图章，对齐与否可选，取样单层或全部图层
- 模糊工具，可用于像素或蒙版
- 渐变工具与形状工具（矩形、圆角矩形、椭圆、直线），形状保持可编辑而不会栅格化
- 文字工具（T）：可拖拽缩放的段落框内多行编辑；工具头部设置字体、字号、颜色、对齐与间距；文字可变换、可作剪贴蒙版
- 吸管与完整取色器

### 调整与滤镜
- Camera Raw 滤镜：光、颜色、曲线、颜色混合器、颜色分级、细节、光学与几何，画布旁独立面板
- 色阶（含自动）、曲线、色相/饱和度、曝光、渐变映射、颗粒、黑白、色彩平衡、反相
- 可超出图层边缘扩散的高斯模糊与动感模糊
- 添加杂色、晕影、辉光、色调对比、镜头校正与移除背景
- 实时预览，有选区时只作用于选区

### 画布与文件
- 多项目标签页
- 标尺（⌘R）、从标尺拖出的参考线、间距与细分可调的布局网格，以及针对参考线、网格、图层与文档边界的吸附
- 裁剪带吸附、比例（含 3:4 和 9:16）、Option 对称裁剪；有选区时从选区开始
- 画布大小、图像大小与修边
- 缩小时高质量锐利降采样，放大到像素级时显示像素网格
- 导入 JPEG、PNG、HEIC、TIFF、SVG、相机 RAW（先经 develop 步骤）以及 Photoshop PSD/PSB（8 位 RGB；不支持 CMYK）。Photoshop 的图层组、蒙版、混合模式、填充矩形/椭圆和简单横排文字保持可编辑；其余矢量与竖排文字转为像素。应用前会展示转换报告。
- 大文档：内存预算随 Mac 配置伸缩，超出预算的 PSD 会把图层裁到画布范围
- JPEG 导出带实时预览（⇧⌥⌘S）；合并拷贝
- 项目保存时不阻塞编辑
- 全程 Photoshop 风格快捷键，可在"编辑 > 键盘快捷键"中自定义
- 拖动数值标签即可滑动调值，和 Photoshop 一致
- 自动更新，已签名并公证

### 与 AI 协作
- AI 代理与脚本可以直接构建和编辑项目：`.comp` 是一个由 PNG 图层与清单文件组成的文件夹，打开的项目会随写入实时刷新。参见[编写 .comp 项目](docs/writing-comp-files.md)
- 或通过 Model Context Protocol：`compositor-mcp` 命令行服务器（以及应用内置的 MCP Server 开关）在本地 HTTP 上暴露创建、编辑、滤镜与导出工具。参见 [MCP 服务器](docs/mcp-server.md)

## 跨平台核心

`Core/` 目录是一个独立的 SwiftPM 包（`CompositorCore`），在 macOS、Windows 和 Linux 上编译并通过同一套测试（CI 三平台验证；Windows/Linux 下 `build.bat`/`build.sh` 封装构建，产物都在 `output/` 下）。它包含：

- `PixelBuffer` 像素栅格、`Renderer` 协议与纯 Swift 的 `SoftwareRenderer`（24 种混合模式的 `BlendMath` 公式实现）
- 便携滤镜：高斯模糊、动感模糊、辉光（纯 Swift）+ 加噪、晕影、色调对比、镜头校正（可移植 C 内核）
- 文字渲染：stb_truetype 字形栅格化 + 纯 Swift 排版（含三平台字体扫描与别名匹配）
- PNG 编解码（swift-png）、图层树校验与 headless 文档引擎 `HeadlessProject`
- 无界面 MCP 服务器：22 个工具与 macOS 版同名同参，任意平台 `swift run compositor-mcp` 即可启动

详细的能力边界与降级清单见 [docs/cross-platform.md](docs/cross-platform.md)。

## 环境要求

- macOS 26.0 或 later，Apple silicon Mac（应用本体）
- Xcode 26 或 later（从源码构建 macOS 应用）
- Swift 6.0 工具链（跨平台核心与 headless 服务器）

## 构建

**macOS 应用**：打开 `Compositor.xcodeproj`，运行 **Compositor** scheme。

**跨平台核心与 headless MCP 服务器**（三平台通用）：

```sh
swift build && swift test          # macOS / Linux
build.bat                          # Windows（封装 swift build，产物在 output/）
swift run compositor-mcp --token <你的令牌>   # 启动 headless MCP 服务器
```

## 发布

`scripts/release.sh` 构建 Release 版本，用 Developer ID 签名、公证并装订，打包为 `dist/Compositor-<version>.dmg`。

需要以下全部条件（都保存在本仓库之外）：

- 登录钥匙串中的 **Developer ID Application** 证书
- 用 `xcrun notarytool store-credentials "compositor-notary" …` 保存的公证凭据
- [`create-dmg`](https://github.com/create-dmg/create-dmg)（`brew install create-dmg`）

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
