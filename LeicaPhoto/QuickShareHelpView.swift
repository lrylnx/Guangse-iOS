import SwiftUI
import AppIntents

struct QuickShareHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("首次设置一次") {
                    Text("1. 在光色选好 M9 / M9D、滤镜和强度。以后分享生成会沿用最近使用的设置。")
                    Text("2. 打开系统“快捷指令”，新建“光色一键生成”，添加光色的“一键生成并保存到相册”操作。")
                    Text("3. 在快捷指令的详细信息中开启“在共享表单中显示”，输入类型选择“图像”。将操作里的“照片”设为“快捷指令输入”。")
                    ShortcutsLink().frame(minHeight: 44)
                }
                Section("之后这样用") {
                    Text("相册选择一张或多张照片 → 分享 → 光色一键生成。")
                    Text("光色会打开并自动处理、保存 PNG 到相册，不需要再次选图或点保存。完成后显示已保存数量。")
                }
                Section("保留完整画质") {
                    Text("使用与相册导入相同的处理流程，不为分享入口额外缩小照片。M9 经典仍受原模型工作尺寸限制，M9D 保持原图尺寸。")
                    Text("首次运行可能需要确认快捷指令和相册权限。处理时请保持光色在前台；可点“停止”，已保存照片会保留。")
                    Text("此入口是你配置的分享菜单快捷指令，不是原生分享扩展。保持安装时的应用标识，更新后原快捷指令才可继续识别光色。")
                }
            }
            .navigationTitle("相册一键生成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(.orange)
    }
}
