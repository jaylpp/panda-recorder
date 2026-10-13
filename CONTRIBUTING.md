# 贡献指南

欢迎反馈问题、修复 Bug 和改善体验。较大的功能建议先开 Issue 讨论。

## 从源码构建

需要 Apple Silicon Mac，以及包含 macOS 15 SDK 的 Xcode 16 或更新版本的命令行工具。

```bash
xcode-select --install  # 尚未安装开发工具时执行
git clone https://github.com/jaylpp/panda-recorder.git
cd panda-recorder
bash build.sh
open "build/熊猫录屏.app"
```

生成 DMG 前安装打包依赖：`python3 -m pip install Pillow ds-store mac-alias`，然后运行 `bash package-dmg.sh`，产物位于 `build/release/`。

代码在 `Sources/`：`main.swift` 仅负责启动；`App.swift` 管理应用与录制流程，`App+Interface.swift` 构建界面，`App+Export.swift` 负责预览及导出交互，`Recording.swift` 负责采集与声音，`VideoProcessing.swift` 负责运镜与编码，`Controls.swift` 放自定义控件。图标在 `Assets/`。重新构建后可能需要刷新录屏授权，见 README。

## 提交改动

1. Fork 仓库，从 `main` 创建分支。
2. 运行 `bash build.sh`、`bash scripts/test.sh` 和 `git diff --check`，实际测试改动涉及的功能。
3. 提交 PR，说明解决的问题和测试结果。

录制相关改动请检查开始、停止、重录、取消和视频播放；涉及声音、运镜或多屏时，补测对应开关及设备场景。

反馈 Bug 请提供系统版本、录制模式和复现步骤。附件请脱敏，不要提交私人录制素材、凭据或构建产物。贡献代码按本项目 MIT 许可证分发。

使用 Xcode 自带的 `swift-format` 统一格式：`xcrun swift-format format -i Sources/*.swift Tests/*.swift`。
