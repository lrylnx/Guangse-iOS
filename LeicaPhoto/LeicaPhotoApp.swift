import SwiftUI
import PhotosUI

@main
struct LeicaPhotoApp: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark).tint(.orange) }
    }
}

struct ContentView: View {
    @StateObject private var model = PhotoEditorModel.shared
    @State private var selection: [PhotosPickerItem] = []
    @State private var advanced = false
    @State private var showingQuickHelp = false
    @GestureState private var holdingComparison = false
    @State private var showingCamera = false
    @State private var recoveredCameraOriginals = false
    private let panel = Color(red: 0.105, green: 0.11, blue: 0.13)
    private var selectedFilter: PhotoFilter? { PhotoFilter.all.first { $0.id == model.settings.filterID } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        if let status = model.quickStatus {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bolt.circle.fill").foregroundStyle(.orange)
                                Text(status).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.quickStatus = nil } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("关闭一键生成提示")
                            }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        photoPreview(height: min(480, max(240, geometry.size.height * 0.48)))
                        if !model.photos.isEmpty {
                            photoStrip
                            controls
                            Text("同一组设置应用于全部照片 · 原图保持不变")
                                .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
                        } else { emptyDescription }
                    }.padding(.horizontal, 16).padding(.top, 8)
                }.scrollIndicators(.hidden)
            }
            .background(Color(red: 0.045, green: 0.05, blue: 0.065))
            .navigationTitle("光色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.photos.isEmpty {
                        Button("清空") { model.clear() }.font(.subheadline).disabled(model.busy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showingQuickHelp = true } label: {
                            Image(systemName: "bolt.circle").font(.title3).accessibilityLabel("相册一键生成设置")
                        }.disabled(model.busy)
                        Button { openCamera() } label: {
                            Image(systemName: "camera").font(.title3).accessibilityLabel("拍照并生成效果")
                        }.disabled(model.busy)
                    if !model.photos.isEmpty {
                        PhotosPicker(selection: $selection, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                            Image(systemName: "plus.circle").font(.title3).accessibilityLabel("添加更多照片")
                        }.disabled(model.busy)
                    }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $showingQuickHelp) { QuickShareHelpView() }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                model.cameraActive = false
                if !model.busy { model.schedulePreview() }
            }) {
                CameraView { data in
                    showingCamera = false
                    model.cameraActive = false
                    model.acceptCapture(data)
                }
            }
            .onAppear { recoverCameraIfNeeded() }
            .onChange(of: model.busy) { _, busy in if !busy { recoverCameraIfNeeded() } }
            .onChange(of: model.quickRunning) { _, running in if running { showingQuickHelp = false } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.releasePreviewMemory()
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                model.importPhotos(items)
                selection = []
            }
            .alert("光色", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("好", role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }

    private func photoPreview(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(panel)
            if let preview = model.preview {
                PhotoPreviewImage(image: preview).frame(maxWidth: .infinity, maxHeight: .infinity).padding(5)
                    .overlay { comparisonOverlay }
                VStack {
                    HStack {
                        Text(holdingComparison ? "左原图 · 右效果" : (model.previewing ? "生成预览中" : (model.previewIsHDR ? "效果预览 · HDR" : "效果预览 · SDR")))
                            .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.65), in: Capsule())
                        Spacer()
                        Text(model.selectedPosition).font(.caption.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.65), in: Capsule())
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        if model.previewing {
                            VStack(spacing: 7) {
                                HStack(spacing: 8) {
                                    Text(model.stage).font(.caption).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(model.progress, format: .percent.precision(.fractionLength(0)))
                                        .font(.caption.monospacedDigit())
                                }
                                ProgressView(value: model.progress).tint(.orange)
                                    .accessibilityLabel("预览生成进度")
                            }.padding(12).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                        }
                        HStack {
                            Spacer()
                            Label("按住对比", systemImage: "rectangle.lefthalf.inset.filled")
                                .font(.caption.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 12)
                                .background(.black.opacity(0.7), in: Capsule())
                                .contentShape(Capsule())
                                .gesture(DragGesture(minimumDistance: 0).updating($holdingComparison) { _, held, _ in held = true })
                                .allowsHitTesting(!model.busy && model.comparisonOriginal != nil)
                                .opacity(model.comparisonOriginal == nil ? 0.5 : 1)
                                .accessibilityLabel("按住显示左侧原图、右侧效果，松开恢复效果")
                        }
                    }
                }.padding(12)
            } else {
                VStack(spacing: 15) {
                    ZStack {
                        Circle().fill(.orange.opacity(0.1)).frame(width: 90, height: 90)
                        Image(systemName: "camera.filters").font(.system(size: 40, weight: .light)).foregroundStyle(.orange)
                    }
                    Text("把喜欢的色彩，留在照片里").font(.headline)
                    Text("拍摄后自动生成效果，也可从相册批量选图")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24)
            }
        }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var comparisonOverlay: some View {
        GeometryReader { geometry in
            if holdingComparison, let original = model.comparisonOriginal {
                PhotoPreviewImage(image: original)
                    .padding(5).frame(width: geometry.size.width, height: geometry.size.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width / 2) }
                Rectangle().fill(.white.opacity(0.9)).frame(width: 1)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }.allowsHitTesting(false)
    }

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("已选择 \(model.photos.count) 张").font(.subheadline.weight(.semibold))
                Spacer()
                if model.completedCount > 0 { Text("已保存 \(model.completedCount) 张").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 9) {
                    ForEach(model.photos) { photo in
                        Button { model.select(photo.id) } label: {
                            Image(uiImage: photo.thumbnail).resizable().scaledToFill()
                                .frame(width: 65, height: 76).clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if photo.savedSettings == model.settings && photo.cameraBackup == nil {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(4)
                                    } else if photo.failure != nil {
                                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).padding(4)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(photo.id == model.selectedID ? .orange : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).disabled(model.busy)
                            .contextMenu {
                                Button(role: .destructive) { model.remove(photo.id) } label: {
                                    Label("移除此照片", systemImage: "minus.circle")
                                }.disabled(model.busy)
                            }
                            .accessibilityLabel("照片 \((model.photos.firstIndex(where: { $0.id == photo.id }) ?? 0) + 1)")
                    }
                }.padding(2)
            }.scrollIndicators(.hidden)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("保留原图 HDR", isOn: $model.settings.preserveHDR)
                .font(.subheadline)
            Text("原图含 HDR 时输出 16 位 HDR PNG；普通照片不强行提亮。HDR 亮度按原片重新匹配，文件会更大。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label("AI 风格", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("AI 风格", isOn: $model.settings.useAI).labelsHidden()
            }
            if model.settings.useAI {
                Picker("AI 风格", selection: $model.settings.mode) {
                    ForEach(M9AIMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                Text(model.settings.mode.detail).font(.caption).foregroundStyle(.secondary)
                strengthRow("AI 强度", value: $model.settings.aiStrength)
            }
            Divider().opacity(0.5)
            HStack {
                Label("色彩滤镜", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("色彩滤镜", selection: $model.settings.filterID) {
                    Text("不叠加").tag("none")
                    Section("调色滤镜") {
                        ForEach(PhotoFilter.all.filter { $0.kind == "lut" }) { Text($0.name).tag($0.id) }
                    }
                    Section("相机影调") {
                        ForEach(PhotoFilter.all.filter { $0.kind == "clu1" }) { Text($0.name).tag($0.id) }
                    }
                }.labelsHidden().pickerStyle(.menu)
            }
            if selectedFilter != nil { strengthRow("滤镜强度", value: $model.settings.filterStrength) }
            if model.settings.useAI && selectedFilter != nil {
                Text("AI 已包含调色；叠加滤镜会进一步改变色彩。").font(.caption2).foregroundStyle(.secondary)
            }
            if model.settings.useAI && model.settings.mode == .full {
                DisclosureGroup("场景设置", isExpanded: $advanced) {
                    VStack(spacing: 12) {
                        Toggle("根据每张照片的曝光参数估算", isOn: $model.settings.autoScene).font(.caption)
                        Text("白平衡缺少厂商数据时使用 5000K；可关闭自动估算后手动设置。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !model.settings.autoScene {
                            HStack { Text("亮度指数"); Slider(value: $model.settings.lux, in: 0...999, step: 1); Text("\(Int(model.settings.lux))").monospacedDigit().frame(width: 35) }
                            HStack { Text("白平衡"); Slider(value: $model.settings.cct, in: 2000...9000, step: 100); Text("\(Int(model.settings.cct))K").monospacedDigit().frame(width: 55) }
                            Picker("镜头参数", selection: $model.settings.zoom) {
                                Text("0.6×").tag(0.6); Text("1×").tag(1.0); Text("3×").tag(3.0); Text("4.3×").tag(4.3); Text("10×").tag(10.0)
                            }
                        }
                        Toggle("场景调色与暗角", isOn: $model.settings.parameters)
                    }.font(.caption).padding(.top, 10)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18)).disabled(model.busy)
    }

    private var emptyDescription: some View {
        HStack(spacing: 22) {
            Label("批量调色", systemImage: "square.stack")
            Label("无损保存", systemImage: "checkmark.seal")
            Label("本地处理", systemImage: "iphone")
        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    private func strengthRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }

    private func recoverCameraIfNeeded() {
        guard !recoveredCameraOriginals, !model.busy else { return }
        recoveredCameraOriginals = true
        model.recoverCameraOriginals()
    }

    private func openCamera() {
        Task { if await model.prepareForCamera() { model.cameraActive = true; showingCamera = true } }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if model.busy {
                ProgressView(value: model.progress).tint(.orange)
                HStack {
                    Text(model.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(model.progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                    Button("停止") { model.cancel() }.font(.caption)
                }
            }
            if model.photos.isEmpty {
                Button { openCamera() } label: {
                    Label("拍照并生成效果", systemImage: "camera")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.busy)
                PhotosPicker(selection: $selection, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                    Label("选择照片 · 支持多选", systemImage: "photo.on.rectangle.angled")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.bordered).disabled(model.busy)
            } else {
                Button { model.saveAll() } label: {
                    Label(model.pendingCount == 0 ? "本组设置已全部保存" : (model.photos.count == 1 ? "保存到相册" : "保存 \(model.pendingCount) 张到相册"), systemImage: model.pendingCount == 0 ? "checkmark.circle" : "square.and.arrow.down")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.pendingCount == 0)
            }
            Text(model.settings.preserveHDR ? "PNG 无损 · 自动保留源 HDR · 文件会更大" : "PNG 无损 · sRGB / SDR")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 8).background(.ultraThinMaterial)
    }
}
