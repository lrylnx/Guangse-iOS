# 光色 0.5.0 · M9 AI 照片移植实验版

从用户提供的 `1.0.40.apk` 恢复滤镜和 M9 模型，为 iPhone 实现批量相册选图、本地处理和无损保存到相册。对应包内 fullm9 路径与 770 蒸馏路径；不是把 Android 可执行文件改后缀，也不能称为整套原厂算法完全一致的成品。

## 使用

1. 桌面 `光色-0.5.0-M9AI-待签名.ipa` 为 iPhone/iPad ARM64 待签名包，用自己的 p12 和匹配描述文件重签安装。iOS 17+，继续沿用 Bundle ID `local.guangse.photo` 和同一签名身份覆盖更新。
2. 点“选择照片”一次多选；右上角加号可追加，重复选同一相册项目会跳过。点缩略图切换预览，长按可移除；“清空”仅移除本应用的临时副本，不会删除系统相册照片。
3. 默认 M9D 蒸馏模式，保持原图尺寸；关闭 AI 可仅使用49款滤镜。三网络“M9经典”保持原有最多4096×3072的模型画布。
4. 选择 AI/滤镜强度，预览自动更新；同一组设置应用于全部照片。经典模式可以按每张原图的曝光信息估算场景指数，白平衡仍为默认5000K，或关闭自动后手动调整。
5. 点“保存 N 张到相册”。逐张读取、处理、写入，每张输出为 PNG，无文件导出/分享菜单。可停止；本次会话内已成功保存的同一组设置不会重复保存。失败或停止后再点保存，只重试未完成照片；修改设置后可重新保存新效果。
6. 原图对比只影响预览，不会把“查看原图”的状态当作导出效果。

## 0.5.0 拍照与自动保存

- 首页“拍照并生成效果”，或右上角相机按钮进入拍摄。首次需要相机及“添加照片”权限，不请求麦克风。
- 先在编辑页选择需要的 AI/滤镜设置，再拍照。取景显示原始画面，支持点按对焦、设备可用的前置/主摄/超广角/长焦和闪光灯；完整AI在拍摄后运行。
- 使用 AVFoundation 画质优先模式，申请当前镜头活动格式支持的最大照片尺寸；实际尺寸由设备与系统拍摄流程决定。优先 HEIC，不支持时 JPEG；目前不拍摄 RAW、Live Photo 或视频。
- 按快门后回到编辑页，自动先将未改写的拍摄原片保存到相册，再用相册导入共用的 PhotoProcessor 生成并保存 PNG 效果照。一次拍摄保存两张；效果照以本次保存时间加入相册。
- 原片资源按拍摄返回的原始字节添加到 Photos，不经预览图转码。系统确认保存前会保留在应用支持目录；保存失败/停止后可重试，重启应用会恢复尚未确认保存的原片。不要卸载应用来恢复尚未保存的文件。
- 拍摄后只自动处理本次照片；相册批量选择、已有预览缓存及进度条继续保留。
- `Checks/camera-import/results.log`：原片字节不变、重启可发现暂存、缓存清理不删除暂存、保存确认清理、不删除其他文件、无效输入拒绝，以及同一JPEG原片两入口的M9D预览/完整PNG像素一致均通过。这里验证的是处理管线，不是模拟真实拍照。
- iPhoneOS Release及Simulator Debug编译通过，但本机没有可用相机硬件/模拟器运行时。镜头切换、闪光灯、横竖屏方向、真实Photos保存和实拍画质仍待iPhone验证。
- 与苹果自带相机拍摄不能承诺相同底片：系统相机可能使用不同的多帧融合、HDR和镜头策略。相同源文件、同样参数才可比较处理结果；相册若导出调整后的版本或转码，也可能不是同一份输入。

## 0.4.0 检查与修正

- 接手版本的 M9D 模型与分块接入符合已有的 APK 取证；未发现可以把它称为完整原生后处理的依据。保持该限制，未使用单张样本拟合替代算法。
- 原 PhotoExport 色彩/EXIF 导出器未接入界面保存逻辑。现在统一经 PhotoExport 输出 PNG，嵌入 sRGB ICC、正确方向、基本拍摄信息；不复制已经失效的 HDR 增益图、GPS、MakerNote。
- 从单张内存状态改成磁盘临时源文件 + 串行处理队列。AI结果以无损文件缓存，预览、强度调整和保存可复用；内存预览预算64MB；磁盘为每张所选照片保留最新AI配置，不同时运行多张网络。
- M9D 移除旧4K缩图限制，完整原图分块推理；PNG直接写文件，减少一份内存中的编码副本。
- 界面改为大图预览、可切换缩略图、分组调色面板、固定底部保存按钮与批量进度；不展示文件保存、格式选择或分享入口。

## 0.4.1 预览与保存修复

- 已完成的照片按“照片 + 当前设置 + 原图/效果”缓存最终1600像素预览。切换先直接读取内存，内存回收后读取磁盘；命中缓存不启动AI、LUT或生成指示。
- 移除完整AI结果“只保留四张”的跨照片淘汰规则。每张所选照片保留最新AI配置；清空或移除时清理该照片的临时缓存。
- 批量保存时同步生成显示预览，因此保存后首次切换也不重复处理。修改滤镜强度只更新最终预览，复用未变的AI结果。
- 生成指示统一改为确定进度条，显示阶段和百分比；模型、滤镜、缓存和保存分阶段计量，不用计时器伪造进度。单次模型预测/文件编码内部没有细分回调时，进度会暂留在当前阶段。
- 相册创建请求明确设置creationDate为本次保存时间，同批次单调递增，避免系统按原图拍摄日期排列。PNG内仍保留基本拍摄EXIF；原图和过去已保存照片不修改。
- `Checks/preview-cache/results.log`：6张照片反复切换、内存缓存直接复用、磁盘命中不触发生成、超过4张AI不淘汰、修改滤镜复用AI、原图对比缓存、批量导出预览、清理与0–100%单调进度检查通过。iPhoneOS Release和Simulator Debug编译通过。
- 未连接iPhone，进度条交互与相册实际排序还需实机验证。旧版已保存照片可在系统照片里按“最近添加”查找，新时间逻辑只影响本版新保存的照片。

## PNG 与画质

本版选择无损 PNG，以满足优先画质的要求。PNG 不引入 JPEG 的有损编码/色度压缩，但照片文件通常更大。已经被 JPEG 编码、被模型裁剪的高光或缺失的细节，不会因为转 PNG 恢复。

当前模型流程仍是 **8位 sRGB/SDR**，PNG忠实保存的是这个处理结果；不是RAW、16位高精度或原始HDR完整保留。PNG也不能自动解决M9D后处理与安卓的色彩差异。原版HDR需要重新构建经过处理的HDR/SDR配对，不能直接复制旧增益图。

## 实际移植内容

- **完整 M9 AI 模型三份**：low、high、colorfix。解包后的 ONNX 与原容器 SHA-256 完全一致，再构建等价 Core ML 图；没有使用缩小蒸馏网络代替它们。
- **770 蒸馏模型一份**：`donor120/m9_distill.onnx`（12 层卷积，667,114 字节，SHA-256 与包内一致）转成等价 Core ML 图，含 96 像素 clamp-edge 光晕、字节域 2×2 取整下采样、1024 核心分块与“后块覆盖前块”、输出 strip 与取整、竖图反向旋转。数值与原 ONNX Runtime 一致到 1e-6 量级。
- **原生输入和后处理**：照片旋转、4096×3072 居中画布、reflect101 边界、4×4 均值与 round-even、风格输入 symmetric48 边界、4 通道归一化、512 分块/16 边界色彩修正、输出解码、恢复尺寸和方向。
- **M9 场景调色与暗角**：114 份 17³ BGR LUT、55 组暗角参数，保留场景亮度/白平衡插值和镜头区间选择，输出转回原方向后再处理。
- **26 份 PLUT 调色资源**：徕卡 M9、ETN、黑白及原包其他照片滤镜。
- **23 份 CameraLook 影调**：原始 CLU1 表、四面体插值、RGB/亮度曲线、原始非线性强度，以及 ToneMath 的颗粒、彩噪、暗角、负清晰度，保留固定 seed 和参数。
- **导入导出**：系统相册批量导入、本地处理、直接保存为新PNG照片，sRGB/SDR。预览在处理之后缩小，保持颗粒坐标与导出一致。

## 仍未移植 / 不能承诺的部分

- 原 Android/Qualcomm MINN 容器、DSP 运行时及人物分割模型未移植。本版恢复并验证的是同一 APK 的 fullm9 ONNX 路径和 770 蒸馏路径。
- **770 的原厂后处理没还原**。Java 侧 warm 参数被 JNI 包装层丢弃，native 核心实际用 s4=−1、s5=−0.35、s6=0.025 走 LUT 插值加一段含 sRGB 线性化的 shading。本版用同一份 M9 snapshot 表在包装层透传的固定 200/5500/1 上近似，不能声称与 `libd12ase.so` 逐像素一致。
- 用参考图实测，770 与安卓原片的 8 位平均差 8.96/255，和现有 high/low 方案（9.42 / 8.51）在同一档位：它是“这张安卓图实际用的模式”，不是“更接近安卓”的修复。
- 原版 QualityPass 的自适应降噪、低光/阴影清理、ChromaPass、纹理/细节恢复、ProfessionalSession 仍未可靠复现。已经保存原生汇编和调用链，没有以普通锐化冒充。
- RAW 的 OEM ISP、AE/IPE 处理、HDR gainmap、实时AI取景、视频、水印、云服务、裁切/美学评分模型不属于当前照片输出流程。
- 已比较用户提供的一组安卓/iOS照片，但只有一组样本，且HDR和模式前后处理尚未完全对齐，不能保证最终像素一致。Core ML 网络验证仅证明网络转换精度，不能替代缺失前后处理的验证。
- M9经典工作画布最多4096×3072；M9D和普通滤镜按原图尺寸输出。PNG导出保留基本拍摄EXIF，不保留Live Photo、HDR、GPS或RAW。超大图和长批次的iPhone内存/性能仍需实机验证。
- 没有可用 iOS 模拟器运行时或连接 iPhone；尚未实际验证 iPhone 交互、相册权限、签名安装、速度和内存。测试的耗时与内存来自本机 Mac。首版选择数值已验证且首次运行更稳定的 CPU 路径，避免未经实机验证的 GPU 初始化开销。

## 已完成验证

- 完整原始 ONNX vs Core ML：low 最大绝对误差5.05e-6、high3.61e-6、colorfix1.97e-6；均使用原版完整输入尺寸。
- 770 蒸馏 ONNX vs Core ML：7 组尺寸（含非 16 倍数与奇数 lowres）最大绝对误差 ≤7.2e-7，见 `Investigation/distill-parity.json`。
- 独立 C++ 原生指令推导 oracle vs Swift：完整4096×3072画布、风格张量、三个角落/中间 colorfix 张量逐字节一致。
- 五组 LUT/暗角选择指纹与独立原始 BIN 解析器一致。
- 115000 次真实 CLU1 采样、2944 个影调公式样本、23 款完整图像处理及取消测试通过。
- 770 集成检查（`Checks/distill-smoke/main.swift`）：分块偏移含尾块重叠、字节取整、尺寸/不透明/确实改变像素、后处理等于显式 200/5500/1、两次运行逐字节相同、1200×800 双块路径、取消能抛出 `CancellationError`。
- 集成测试：49 款滤镜能渲染、CGImage 上下行顺序、横竖图、AI 两分支、完整1200万像素/48分块处理、JPEG 导出及重读尺寸通过。当前 Mac 的1200万像素单张全量 AI 集成测试约8.5秒、770 约1.7秒（12 块，CPU）；这是本机测量，不能代表 iPhone。
- 0.4.0 新验证（`Checks/quality-batch/results.log`）：PNG重读像素逐字节一致、色彩描述、方向/尺寸、两张顺序处理、缓存复用、预览与保存一致、小图M9D尺寸、取消及缓存清理均通过。
- `Checks/full-resolution/results.log`：4608×3072 M9D实际推理及PNG重读尺寸通过；本机约1.8秒，内存测量来自Mac，不是iPhone实测。
- 0.4.0 iPhoneOS Release 与 iOS Simulator Debug 编译通过；IPA固定ID/ARM64/4模型/49滤镜/ZIP完整性检查通过。
- 未连接iPhone、无模拟器运行时，因此实际多选交互、Photos写入、系统权限提示、中止后续保存和大批次性能，仍需安装到手机后验证。

证据和复现脚本见 `Investigation/model-findings.md`、`Investigation/pipeline-findings.md`、`Investigation/distill-findings.md`、`Investigation/optimization-mode770.md`、`Investigation/tone-validation/FINDINGS.md` 和 `Checks/smoke.log`。静态 DEX/ELF 分析不代表执行过原 APK。

## 构建

打开 `LeicaPhoto.xcodeproj`，选择自己的 Apple 开发 Team 即可走正常签名构建。现有 macOS 本地证书不能替代 iOS 开发签名。通过外部 p12 签名时：

```sh
python3 scripts/build_ipa.py
```

该脚本仅构建待外部重签名的 iPhoneOS 包，不创建证书、不导出私钥，也不使用临时 ad-hoc 签名。固定身份为 `local.guangse.photo`、版本0.5.0、构建6。它先用 `scripts/generate_project.py` 从 `LeicaPhoto/` 重新生成工程，所以新增 Swift 文件或模型只要放进目录就会自动进 target。

770 的 Mac 侧复现：

```sh
xcrun swiftc -O -Xfrontend -disable-sandbox -o Checks/DistillSmoke.app/Contents/MacOS/DistillSmoke \
  LeicaPhoto/{FilterEngine,M9Models,M9Parameters,M9Pipeline,M9DistillModel,M9DistillPipeline,M9DistillPost,ToneEffects,ToneLUT,PhotoExport}.swift \
  Checks/distill-smoke/main.swift -framework CoreML -framework CoreImage
Checks/DistillSmoke.app/Contents/MacOS/DistillSmoke "$PWD/Checks" "$PWD/Checks/sample.jpg"
```

参考图对比用 `Investigation/.venv/bin/python3 Comparison/compare-distill.py`（读原有的 iOS/原图/安卓三张参考图，输出 `Comparison/distill-candidate.json`）。

模型转换和反编译依赖只装在 `Investigation/.venv`，不进入 IPA。原包资源存在不等于已证明官方身份或再分发授权；当前为用户本地验证原型。
