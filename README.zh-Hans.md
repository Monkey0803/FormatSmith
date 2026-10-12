[English](README.md) · **简体中文**

# FormatSmith

[![CI](https://github.com/Monkey0803/FormatSmith/actions/workflows/ci.yml/badge.svg)](https://github.com/Monkey0803/FormatSmith/actions/workflows/ci.yml)
[![发布](https://img.shields.io/github/v/release/Monkey0803/FormatSmith)](https://github.com/Monkey0803/FormatSmith/releases/latest)
[![许可证：MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![平台：macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey)

**一款原生的 macOS 文件转换器。** 把文件拖进来，选一个输出格式，完事。所有处理都在本地通过
Apple 自己的框架完成 —— 不会上传任何内容，应用本身也不依赖任何第三方组件。

> 状态：PDF → 图片、图片 → 图片、图片 → PDF、PDF 工具箱、**文档 → PDF**
> 和**文字导出（OCR）**目前都已可用，
> 应用和 CLI 都支持。后续计划见[路线图](#roadmap)。

## 功能

- **拖放** PDF 和图片，点击选择文件，拖入整个文件夹（其中的受支持文件会自动找出来），或者使用 *打开方式 → FormatSmith*。
- 默认提供**七种输出格式** —— PNG、JPEG、HEIC、AVIF、TIFF、GIF、BMP —— 另有一批少见格式
  （JPEG 2000、Photoshop、Targa、OpenEXR、PBM、Windows Icon）收在一个开关之后。
- **可以用 FormatSmith 打开图片**：图片、PDF、HTML、Markdown 和纯文本都声明为可打开类型
  （等级为 *Alternate*，因此应用会出现在「打开方式」中，却不会去争抢成为你的默认查看器）。
  现在把照片拖到 Dock 图标上也能用了。
- **分辨率名副其实**：PDF 按选定的 DPI 渲染（72–600）；图片以自身像素为基准缩放（1× = 原始尺寸）。
  放大图片需要你主动选择，绝不会是默认行为。
- **背景**：白色、黑色或透明（只有在格式本身能存储透明通道时才支持透明）。
- **页面范围**：全部页面，或类似 `1-3,5,8-10` 的写法。
- **命名由你掌控**：`{name}`、`{page}`、`{total}`、`{date}`、`{time}`，每个源文件单独建子文件夹，
  页码自动补零。已存在的文件绝不会被覆盖。
- 常见需求都有**预设**：网页（2 倍 PNG）、邮件、打印（300 DPI TIFF）、归档、
  扫描成 PDF。点一下就能同时设定格式、分辨率、画质和背景。
- **如实反馈**：逐文件进度、累计统计、随时取消，以及文件完成后的「在访达中显示」。
  失败时会保留完整说明，而不是截断成一句话。
- **并行转换**：多个文件同时转换（默认最多 4 个，可配置），因为渲染受 CPU 限制，
  串行批处理会让大部分核心闲置。
- **图片 → PDF**：每张图片各生成一个 PDF，或把整批选择合并成一个多页文档，
  页面尺寸既可与图片一致，也可加上页边距后适配 A4/Letter。可以无损嵌入，也可以用
  JPEG 压缩图片以减小体积。
- **图片 → 图片**：在格式之间互转，并可放大或缩小（50%–400% 或任意自定义倍数）。
- **每条流程都有实时预览**：导出前，设置面板显示的就是真实结果 ——
  排版好的 PDF 页面、PDF 在所选 DPI 下的第一页、Office/HTML 转换结果、证件照、
  相纸排版。过大的输出会以缩略图绘制，但说明文字始终标注真实的像素尺寸或点（pt）尺寸，以及页数和文件数。
  预览与导出共用同一套排版代码（`PDFComposer.drawPage`），所以你看到的不可能与导出结果不一致。
- **可直接处理的批量结果**：一轮任务结束后会给出汇总 —— 成功多少个、哪些
  文件失败以及原因 —— 并提供一键**重试失败的**，只重跑失败项，还可以从
  结果行直接拖到访达或其他应用中。
- **证件照实时预览**：在导出任何东西之前，设置面板就显示实际结果 —— 抠出的人像、
  新背景、精确的构图和真实的像素尺寸。点击可放大。如果开启了相纸排版，
  也能看到整张相纸。分析结果会缓存，因此修改尺寸或背景可在毫秒内更新。
- **证件照**：把一张人像照变成标准证件照 —— 一寸（25×35mm）、二寸、护照、
  美国签证等，支持白底/蓝底/红底。人像通过系统本地的人像分割抠出（macOS Vision，
  照片不会离开这台机器），再按人脸构图。
  还可以把结果排满 5 寸 / 6 寸相纸，直接打印裁切。
- **证件扫描件**：把身份证正反面放在同一张 A4 页面上（`--pdf-layout two`）。
  文件保持你给定的顺序，队列带有 ↑ ↓ 按钮，所以「正面在上」由你掌控，
  而不是由文件名决定。
- **PDF 工具箱**：合并多个 PDF，每隔 N 页拆分一个 PDF，只提取你列出的页面，
  把每一页旋转 90/180/270°，通过以更低 DPI 重新栅格化来压缩，或者识别文字
  并写入一层看不见的文字层，让扫描件变得可搜索。压缩和识别在设计上就是有损的，
  应用会在执行前明确说明。
- **文字导出（OCR）**：扫描版 PDF**或照片**都能变成 `.txt` 文件（`--to text`）。对 PDF 来说，
  本身就带文字层的页面会原样复用，只有纯图片页面才做识别，所以半打字、半扫描的文档
  能保住它准确的文字。图片没有文字层可复用，因此直接识别。全部处理都在本机完成。
- **文档 → PDF**：Office、OpenDocument 和 RTF 走你机器上已有的 LibreOffice；HTML、
  Markdown 和纯文本走系统 WebKit，无需额外安装。Markdown 在有 pandoc 时用 pandoc，
  没有则回退到内置渲染器。
- **英文和简体中文**，可在应用内切换（设置面板或菜单栏中的*语言*），
  立即生效 —— 无需重启。默认跟随系统语言。
- **同一个可执行文件里就有真正的 CLI**，适合脚本和批处理任务。无论系统语言是什么，
  它的输出都保持英文，因此脚本可以放心依赖。

格式列表不是写死的，而是在运行时从 ImageIO 读取，所以 macOS 更新新增的格式这里也会跟着有 ——
而且当某个格式不可用时，应用会告诉你*为什么*，而不是悄悄失败。例如 WebP 和 JPEG XL，
macOS 能读但不能写，因此它们永远不会作为输出格式提供。

## 系统要求

- macOS 14（Sonoma）或更高版本
- Xcode 15.3 或更高版本（仅构建时需要）

## 快速开始

```bash
git clone https://github.com/Monkey0803/FormatSmith.git
cd FormatSmith
./scripts/build-app.sh --install     # builds, then copies to ~/Applications
```

然后从 `~/Applications`（或 Spotlight）打开 FormatSmith。想直接从构建目录运行？
`./scripts/build-app.sh` 会把 bundle 留在 `dist/FormatSmith.app`。

更想直接下载？从[最新发布](https://github.com/Monkey0803/FormatSmith/releases/latest)获取 DMG，
然后把 FormatSmith 拖进「应用程序」。

由于这些构建只做了 ad-hoc 签名、没有公证，macOS 会在首次启动时给出警告。右键点击
应用，选择**打开**，然后确认。这一步只需做一次。

<details>
<summary>构建通用二进制或 DMG</summary>

```bash
./scripts/build-app.sh --universal   # arm64 + x86_64
./scripts/build-app.sh --dmg         # also produces dist/FormatSmith-<version>.dmg
```

</details>

## 命令行

应用 bundle 里带有一个 CLI 入口，所以可以把转换写进脚本：

```bash
# A 300 DPI PNG of every page
dist/FormatSmith.app/Contents/MacOS/FormatSmith \
    --convert report.pdf --format png --dpi 300 --out ~/Desktop/images

# Batch: pages 1 and 5-8 only, 92% JPEG, no per-file subfolder
dist/FormatSmith.app/Contents/MacOS/FormatSmith \
    --convert a.pdf b.pdf --format jpeg --quality 0.92 --pages 1,5-8 \
    --out ~/Desktop/out --no-subfolder

# What can this Mac write?
dist/FormatSmith.app/Contents/MacOS/FormatSmith --list-formats
```

| 参数 | 含义 |
| --- | --- |
| `--convert <file …>` | 要转换的文件（PDF 或图片） |
| `--to <target>` | 图片格式（`png`、`jpeg`、`heic`……）或 `pdf`（默认 `png`） |
| `--format <name>` | `--to` 的别名 |
| `--quality <0.05-1>` | 有损格式的画质（默认 `0.9`） |
| `--dpi <n>` / `--scale <n>` | PDF 输入用 `--dpi`（默认 200）；图片输入用 `--scale`（1 = 原始尺寸） |
| `--pages <range>` | 例如 `1-3,5,8-10`（默认：全部） |
| `--out <dir>` | 输出目录（默认：当前目录） |
| `--pattern <template>` | 文件名模板，可用 `{name}` `{page}` `{total}` `{date}` `{time}` |
| `--background <c>` | `white`、`black`、`transparent` |
| `--subfolder` | 为每个源文件创建子文件夹（CLI 中默认关闭） |
| `--pdf-page-size <s>` | `fit`、`a4` 或 `letter`（默认 `fit`） |
| `--pdf-margin <pt>` | 固定页面尺寸下的页边距（默认 `24`） |
| `--pdf-compress` | 用 JPEG 压缩内嵌图片以减小 PDF 体积 |
| `--merge` / `--no-merge` | 把多张图片合并成一个 PDF（默认：合并） |
| `--pdf-tool <tool>` | `merge`、`split`、`extract`、`rotate` 或 `compress`（PDF 进，PDF 出） |
| `--id-photo <size>` | `one-inch`、`two-inch`、`id-card`、`large-one-inch`、`three-inch`、`us-visa`…… |
| `--id-bg <colour>` | `white`、`blue`、`red` 或 `keep` |
| `--no-face-crop` | 居中放置照片，而不是按人脸构图 |
| `--sheet <paper>` | `five-inch`、`six-inch` 或 `a4` —— 把照片排到一张可打印的相纸上 |
| `--pdf-layout <n>` | 每页 `one` 或 `two` 张图片（`two` 会强制使用 A4） |
| `--split-every <n>` | 拆分时每个文件包含的页数 |
| `--rotate <deg>` | `90`、`180` 或 `270` |
| `--check-dependencies` | 报告是否找到了 LibreOffice 和 pandoc |
| `--check-localization` | 显示各语言下界面文案的解析结果 |
| `--list-formats` | 列出这台 Mac 上可用的输出格式 |
| `--version`、`--help` | 版本 / 用法 |

退出码：`0` 成功，`1` 有一个或多个文件失败，`2` 参数错误。数据输出到 stdout，
诊断信息输出到 stderr。

设置 `FORMATSMITH_DEBUG=1` 可以追踪文件接收和元数据读取过程。

## 路线图

- [x] PDF → 图片（PNG、JPEG、HEIC、AVIF、TIFF、GIF、BMP……）
- [x] 图片 → 图片，包括 WebP、JPEG XL、HEIC 和 RAW 输入
- [x] 图片 → PDF（把多张图片合并成一个文档）
- [x] PDF 工具箱：合并、拆分、提取页面、旋转、压缩
- [x] 文档 → PDF（Office 走 LibreOffice，HTML 原生转换，Markdown 走 pandoc）
- [x] 文字导出：可搜索的 PDF，以及从扫描件、PDF 和照片中提取文字（本机 OCR）
视频和音频转换明确**不在**范围内 —— 那是另一套技术栈，做了它这就是另一个应用了。

## 项目结构

```
Sources/FormatSmithCore/     Conversion engine and models. No SwiftUI, so it is testable headlessly.
  Formats/                   Format registry, capability detection, input classification.
  Engine/                    Rasterizing, decoding, encoding, orchestration.
  Model/                     Settings, page ranges, output naming, jobs and results.
Sources/FormatSmithApp/      The SwiftUI app and the CLI entry point.
Tests/FormatSmithCoreTests/  Unit tests plus pixel-level integration tests.
Resources/i18n/              Localized strings, copied into the bundle by the build script.
Resources/Info.plist         Bundle metadata (version injected from VERSION at build time).
scripts/                     build-app.sh, make-dmg.sh, make-icon.swift, smoke-test-cli.sh
```

## 工作原理，以及那些锋利边缘

一切都构建在 PDFKit、Core Graphics、ImageIO 和 SwiftUI 之上。如果你打算改动渲染代码，
有几件事值得先了解：

- **`CGContext.drawPDFPage` 不会应用页面的 `/Rotate`。** 你必须自己构造变换。
  `PDFRasterizer.pageTransform(rotation:box:)` 负责处理 0/90/180/270 度的情况，而
  `PageTransformTests` 通过断言各个角的落点把这段数学固定下来。
- **ImageIO 的缩略图 API 只会缩小。** 如果请求的 `maxPixelSize` 比源图更大，
  它会默默返回原始像素，因此 `ImageDecoder` 在放大时会显式重采样。
- **格式之间并不通用。** 只有一部分格式能存储透明通道或接受画质
  参数，而像 ICO 这样的容器格式还会限制尺寸。这些知识由 `FormatRegistry` 承载，
  编码器在写出前会做校验。
- **「透明」遇上不支持透明的格式时，必须退化成一种真实颜色**，否则未绘制的区域
  会变成黑色。
- **图片 → PDF 走的是 `CGPDFContext`，而不是 ImageIO**，因为 ImageIO 会为每张图片写出
  一页、以像素为单位确定尺寸，既无法控制页面尺寸也无法控制页边距。开启 JPEG 压缩时，
  压缩后的图片会被重新导入，让 Core Graphics 以 `DCTDecode` 嵌入它，而不是再无损编码一次 ——
  如果你哪天不信，可以用 `grep -c DCTDecode` 验证。

## 哪个方向走哪条流程

`ConversionRouter` 负责决定，界面读取的是同一张表，因此一条转换路径要么处处可用，
要么处处报告为不可用：

| 输入 | 目标 | 流程 |
| --- | --- | --- |
| PDF | image | 按所选 DPI 栅格化每一页 |
| PDF | PDF | `PDFToolkit`：合并、拆分、提取、旋转、压缩 |
| image | image | 解码、缩放、重新编码 |
| image | PDF | `PDFComposer`，可选择合并多个文件 |
| Office / OpenDocument / RTF | PDF | LibreOffice，以无界面模式配合独立配置文件运行 |
| HTML / Markdown / plain text | PDF | WebKit，渲染为 A4 并分页；Markdown 优先用 pandoc |
| Office / HTML / Markdown | image | 会被拒绝并给出说明 —— 请先转成 PDF |

启用**证件照**后，图片 → 图片流程会变成：抠出人像（Vision 人像分割）→ 按人脸构图 → 填充所选背景 → 可选地排到相纸上。全部处理都在本机完成。

## 参与贡献

欢迎提交 issue 和 pull request —— 参见 [CONTRIBUTING.md](CONTRIBUTING.md)。简而言之：
`swift test` 必须通过，`swift format lint --configuration .swift-format --recursive Sources Tests`
必须没有告警。

## 可选的外部工具

有两项功能可以用上你可能已经装了的工具。它们都没有随应用打包，也都不是必需的：

| 工具 | 用途 | 没有它时 |
| --- | --- | --- |
| [LibreOffice](https://www.libreoffice.org) | Word、Excel、PowerPoint、OpenDocument、RTF | 这些输入会报告需要 LibreOffice，以及如何安装它 |
| [pandoc](https://pandoc.org) | 保真度更高的 Markdown | Markdown 仍可转换，使用内置渲染器 |

`--check-dependencies` 会报告找到了哪些，当队列中的文件需要你尚未安装的东西时，应用会显示一张
**缺少依赖**卡片，并给出一条可复制的 `brew install` 命令。

## 语言

英文是源语言，所有面向用户的文案都以英文撰写。简体中文的译文位于
`Resources/i18n/zh-Hans.lproj/Localizable.strings`。可以在应用的
**语言**卡片或**语言**菜单中选择语言；立即生效，无需重启，并会记住下次的选择。

`swift test` 中有一项检查，确认代码里用到的每一条文案都有中文翻译，因此漏译会让 CI
失败，而不是在中文界面中间悄悄显示英文。

> 翻译成其他语言基本上是机械劳动：复制
> `Resources/i18n/zh-Hans.lproj/Localizable.strings`，翻译其中的值（键就是英文
> 原文，不能改动），把该语言加入 `AppLanguage`，然后构建脚本的
> `Resources/i18n/*.lproj` 通配规则不需要做任何特殊处理 —— 它本来就会复制找到的每一个 `.lproj`。

## 证件照

标准尺寸以毫米定义，再用你选择的 DPI 换算，因为冲印店按毫米裁切，而文件以像素存储。
在惯用的 300 DPI 下，一寸是 295×413 px，二寸是 413×579 px —— 这也是任何证件照服务
都会引用的数字。

预览和导出走的是同一条代码路径（`IDPhotoSession`），所以所见即所得 —— 不是另做一套近似。
解码、人脸检测和分割对每张照片只计算一次并复用，这正是拖动滑块时预览依然跟手的原因。

抠出人像使用 `VNGeneratePersonSegmentationRequest`，构图则使用
`VNDetectFaceRectanglesRequest` 把脸放到标准要求的位置（脸宽约为画面的 55%，
眼睛位置约在距顶部 44% 处）。两者都在本地运行。如果没有检测到人像，会保留原背景
并由应用明确说明，而不是把整张照片替换成一块纯色。

最后这点比看上去更微妙：`VNGeneratePersonSegmentationRequest` 即使什么都没找到也会返回一张
遮罩，所以「有没有遮罩？」是个错误的问题 —— 一张全黑的遮罩（测得前景为 0%）和没有遮罩
是一回事。把它当成抠图成功，结果是照片被抹掉、整页被背景色填满。现在改为检查
覆盖率，低于 0.5% 一律视为「没有人像」。

## 预设是完整的配方

点击一个预设会得到一个确定的状态：它从默认值出发，应用该预设声明的每一项设置。
它没有提到的任何设置都会回到默认值，因此不会从上一次预设中残留下来。
而你的输出偏好 —— 文件夹、文件名模板、子文件夹、并发数、像素上限 ——
会被保留，因为这些属于你，而不是属于预设。

以前的做法不同，而且差别肉眼可见：设置是就地打补丁的，所以之前选过的
证件照模式（蓝底）在你点击*打印*后依然生效，下一张送去转 PDF 的图片就变成了一块蓝色色块。
现在每个预设还会重置它没有设置的项，这意味着将来新增的任何设置默认也会被清掉。

## 把身份证放到一页上

有三种方式，都会生成同样的 A4 页面：正面在上，反面在下：

1. **预设** —— 把两张图片都拖进来，在预设行里点击**证件扫描件**。这一下就把目标设为 PDF、
   每页两张、A4 和 JPEG 压缩全部设好。
2. **手动** —— 添加两张图片，把输出格式设为 **PDF**，然后在 *PDF 页面* 卡片中选择
   **每页两张**。纸张会自动切换到 A4（两张图片需要固定的页面尺寸）。
3. **CLI** —— `formatsmith --convert front.jpg back.jpg --to pdf --pdf-layout two --out ~/Desktop`

顺序由队列决定：第一个文件在上。如果拖入的顺序不对，用行上的
↑ ↓ 按钮调整 —— 拖动文件不会再在你背后按文件名重新排序。尺寸不同的照片会各自
适配到自己的那一半，所以手机拍的正面和扫描仪扫的反面都能看清楚。

## 预设

十个预设覆盖常见需求：网页（2 倍 PNG）、邮件（JPEG）、打印（300 DPI 无损 TIFF）、
归档（原始尺寸 PNG）、**图片合成 PDF**（一个 PDF，每张图片一页）、**PDF 转图片**
（每页一张 PNG，150 DPI）、证件照、相纸排版、证件扫描件（正反面在同一张 A4 页上）和
扫描成 PDF。

## 哪些设置会生效

一个设置可能显示出来却毫无作用，或者更糟：悄悄生效却不可见。这两种情况这里
都发生过 —— 为证件照选择的背景色在证件照控件隐藏之后仍在给 PDF 上色，
而相纸排版的选项也曾出现在根本用不上它们的 PDF 输出里。所以「这个设置是否适用于
当前的输入和目标？」这个问题只在一个地方回答，即 `SettingsScope`，面板也根据同一个答案
推导该显示哪些分区。`SettingsScopeTests` 检查这张矩阵，更重要的是检查它背后的
不变式：**被判定为不生效的设置，改动它时不得影响输出**。还有一项单独的测试会在某条规则
存在、但面板里没有任何地方查询它时失败 —— 「最长边」控件仍然出现在证件照模式里，
就是这样被抓出来的。

## 为什么要有像素上限

每一张输出图片都以 8-bit RGBA 的形式驻留内存，所以 120 百万像素大约是 480 MB 的缓冲区，
还没算上源图。如果有项目就是要刻意产出更大的图片，应该修改
`ConversionSettings.maxPixels`；应用会给出真实数字，而不是一句含糊的警告。

把估算做准很重要，而它以前在两个地方算错过。开启证件照模式
（会把 DPI 设为 300）后，它仍在按「输入尺寸 × 倍数」估算 —— 一张 12 MP 的照片在纸上
变成 212 MP，于是应用拒绝了一个实际输出只有 295×413 的任务。而对于图片，DPI 曾被当作
放大倍数使用（200 DPI = 2.78×），结果一张 48 MP 的手机照片在*默认*设置下就触发了上限。
现在估算是按流程区分的：证件照和相纸排版报告其规格尺寸，图片
报告像素 × 倍数，PDF 报告点（pt）× DPI。

## 已知限制

- **HTML/Markdown 分页在块边界处切分。** 长文档会变成规整的 A4 页面，渲染器也会在
  能避免时尽量不拆开段落，但单个元素如果比一页还高（比如超大代码块、超长表格）
  仍然会被截断。
- **压缩是有损的。** 它会把每一页重新栅格化，因此文字不再可选中，矢量图形也会被
  拍平。应用会把它标注为有损；没有「无损瘦身」模式。
- **WebP 和 JPEG XL 能读不能写**，因为 macOS 本身就不写这两种格式。应用没有选择
  打包第三方编码器，而是把它们排除在输出列表之外，并说明原因。
- **证件照抠图的效果，顶多和 Vision 的分割一样好。** 发丝边缘和杂乱背景可能
  不够完美；开启「保留原背景」即可在不改动背景的前提下裁切和缩放。
- **Office 文档需要 LibreOffice**。它是被检测到的，而不是随应用打包的 —— `--check-dependencies`
  会报告它是否存在。没有它时，Word/Excel/PowerPoint/ODF/RTF 输入会被拒绝并给出这个原因；
  HTML、Markdown 和纯文本仍可转换，因为它们走 WebKit。
- 构建产物只做了 ad-hoc 签名，没有公证，因此首次启动需要右键 → 打开。这是一个
  有意的选择，而不是一件没做完的事：公证需要付费的 Apple Developer 账号，
  而右键这一步就是跳过它的全部代价。

## 许可证

[MIT](LICENSE)。
