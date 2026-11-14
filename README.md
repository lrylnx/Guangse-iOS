# 光色 · Guangse iOS

在 iPhone / iPad 本地运行的 M9 AI 照片处理实验项目。当前版本 **0.5.0（build 6）**，要求 **iOS 17+**。

[下载待签名 IPA（Releases）](https://github.com/lrylnx/Guangse-iOS/releases) · [v0.5.0](https://github.com/lrylnx/Guangse-iOS/releases/tag/v0.5.0)

## 功能

- 4 个 Core ML 模型：M9 low、high、colorfix，以及 M9D 蒸馏模型。
- 49 款滤镜，支持 AI 与滤镜强度调节、原图对比。
- 相册多选、顺序批量处理、生成阶段与百分比进度。
- 内存及磁盘预览缓存，同一照片和设置切换时复用结果。
- 直接将效果照保存到相册，输出无损 PNG。
- 画质优先拍照，支持设备可用的镜头、闪光灯及点按对焦。
- 拍照后自动保存未改写的原片，再运行与相册导入共用的处理管线并保存效果照。
- 未确认保存的拍摄原片在应用内暂存，重启可恢复。

相机取景显示原始画面，完整 AI 在拍摄后运行。

## 构建与安装

需要 macOS、Xcode（本项目在 Xcode 27.2 编译验证）及 Python 3。模型和滤镜资源已放入工程。

```sh
python3 scripts/generate_project.py
open LeicaPhoto.xcodeproj
```

在 Xcode 中选择自己的 Apple 开发 Team 和设备进行签名构建。固定 Bundle ID 为 `local.guangse.photo`；覆盖更新应保持同一 Bundle ID 和签名身份。

生成供外部重签的设备 IPA：

```sh
python3 scripts/build_ipa.py /tmp/Guangse-0.5.0-unsigned.ipa
```

不传输出路径时，IPA 写入当前用户的桌面。该脚本验证 ARM64、版本、权限说明、4 个编译模型、49 款滤镜及 ZIP 完整性，不导出私钥、不创建证书。安装需要自己的 p12 和匹配描述文件。

首次拍照需要相机和“添加照片”权限；相册导入使用系统照片选择器。不需要麦克风权限。

## 使用

1. 从相册批量选图，或先调整 AI / 滤镜设置后点相机拍照。
2. 点击缩略图切换预览，查看原图或调整效果。
3. 相册照片点底部按钮批量保存；拍摄照片自动保存原片及效果照。
4. 可中止批量保存；同一会话再次保存会跳过同一设置下已经成功的照片。

## 画质与实现边界

- PNG 无损保存的是当前 **8 位 sRGB / SDR** 处理结果，不代表 RAW、16 位或完整 HDR；不能恢复源 JPEG 已损失的信息。
- M9D 按原图尺寸分块处理；M9经典模型画布最多 4096×3072。
- 相机优先使用 HEIC，必要时 JPEG。原片按相机返回的字节保存，效果照为 PNG。
- 相同原片与设置共用同一处理流程；不能保证应用拍摄的底片与苹果自带相机相同。
- 原 APK 的部分原厂 native 后处理、降噪、HDR 及 DSP 流程尚未完整复现，不能声称与 Android 原版逐像素一致。
- 不支持实时 AI 取景、RAW、Live Photo 或视频。

## 验证状态

iPhoneOS Release 与 Simulator Debug 编译通过。模型转换精度、PNG 像素保真、批量与预览缓存等已在 Mac 侧验证；同一 JPEG 原片的拍摄/相册两入口 M9D 预览和完整 PNG 像素一致性检查通过。

尚未连接 iPhone 做实拍测试；镜头、闪光灯、方向、Photos 写入、性能和内存仍需实机验证。编译通过不代表这些交互已经实际验证。

测试源码见 `Checks/`，详细移植记录见 [移植说明](docs/PORTING-NOTES.md)。历史记录中提到的本地取证工具、参考照片及部分中间产物不包含在公开仓库内。

## 资源来源

本项目为独立实验项目，与 Leica、华为、小米或 Apple 无隶属或背书关系。模型与滤镜来源于用于移植分析的 `1.0.40.apk`；源文件哈希与资源来源记录见 [resource-provenance.json](resource-provenance.json)。第三方模型、滤镜及商标的权利归各自权利人所有；本仓库没有为其额外授予许可证。

公开内容包括应用源码、模型、滤镜和构建脚本。签名证书、描述文件、个人照片、原始 APK、构建缓存及本机凭据不在仓库内。
