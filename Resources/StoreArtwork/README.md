# 插件商店图像素材

四个插件的图标和宣传图均于 2026-11-15 使用 Codex 内置 `image_gen` 工具生成，每张图片单独生成；未使用 CLI 或符号绘制脚本替代图片。完整提示词见 [prompts.json](prompts.json)。

`Sources/` 保留生成原图；插件目录中的 `Icon.png` 和 `Preview.jpg` 是为原生界面制作的缩略资源。原图不随应用包加载。文字标题、功能说明和状态由 SwiftUI 绘制，宣传图是生成的产品插画，不作为真实界面截图或功能验收证据。

| 插件 | 原图 | 应用资源 |
| --- | --- | --- |
| 快捷键 | `Sources/shortcuts-icon.png`、`Sources/shortcuts-preview.png` | `Plugins/global-shortcuts/Icon.png`、`Preview.jpg` |
| 语音输入 | `Sources/speech-icon.png`、`Sources/speech-preview.png` | `Plugins/doubao-speech-input/Icon.png`、`Preview.jpg` |
| 截图 | `Sources/capture-icon.png`、`Sources/capture-preview.png` | `Plugins/screenshot/Icon.png`、`Preview.jpg` |
| 外设共享 | `Sources/sharing-icon.png`、`Sources/sharing-preview.png` | `Plugins/peripheral-sharing/Icon.png`、`Preview.jpg` |

更新流程：通过内置图像工具生成并检查新图片，把选中的原图保存到这里；将图标缩至 128 × 128 PNG，将宣传图缩至最长边 960 像素、质量约 72 的 JPEG。使用 `sips` 只做缩略和编码，不绘制或替换生成内容。确认图标不超过 64 KiB、宣传图不超过 96 KiB 后运行：

```bash
python3 scripts/prepare-plugin-resources.py --embed-artwork
python3 scripts/prepare-plugin-resources.py --check
python3 scripts/package-plugins.py --tag v0.12.0
```

打包继续只包含 `manifest.json`、`README.md`、`LICENSE` 三个文件；图片以 base64 嵌入清单。只在图片公开发布并验证下载后更新在线商店目录。界面不自动生成图片、不自动访问图像服务，也不在用户设备上保留生成服务的凭据。
