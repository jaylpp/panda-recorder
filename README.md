<p align="center"><img src="Assets/panda-recorder.png" width="96" alt="熊猫录屏图标"></p>
<h1 align="center">熊猫录屏 · Panda Recorder</h1>
<p align="center">一个简洁的 macOS 录屏工具，录下操作，自动聚焦重点。</p>
<p align="center">
<a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License"></a>
<img src="https://img.shields.io/badge/platform-macOS-blue" alt="macOS">
<a href="https://github.com/jaylpp"><img src="https://img.shields.io/badge/Made_by-Panda_Jay-blue" alt="Made by Panda Jay"></a>
</p>

## 缘由

写技术文章、演示软件时，我希望录屏能自动放大操作重点，少一些后期剪辑。受到 Screen Studio 的启发，我借助 Codex 和 REA 做了这个小工具。

**选好范围，开始录制，停止后就能拿到视频。** 这是熊猫录屏想做好的事。

## 功能

- **录制范围**：全屏、窗口、矩形区域，支持外接屏选择。
- **自动运镜**：根据鼠标点击平滑聚焦，支持 1.5×、1.75×、2×，可关闭。
- **声音**：系统声音与麦克风分别开关。
- **录制控制**：悬浮计时、停止、重录、取消。
- **预览与保存**：停止后自动显示预览，支持切换原片与运镜成片，MP4 保存在本机。

无需账号或 API Key。

## 下载安装

前往 [Releases](https://github.com/jaylpp/panda-recorder/releases) 下载 ZIP，解压后将「熊猫录屏.app」拖到「应用程序」。

- **系统要求**：Apple Silicon（M 系列），macOS 15 或更新版本；macOS 15 尚待实测，暂无 Intel 安装包。
- **首次打开**：预览版未经 Apple 公证，可能被系统拦截。确认来源后，可按「系统设置 → 隐私与安全性」中的提示打开。
- **授权**：点击「授权录屏」，在系统设置中开启熊猫录屏；列表中没有时，用「＋」添加「应用程序」里的熊猫录屏，再按提示退出重开。麦克风单独按提示授权。

更新或重新构建后若权限失效，请退出应用，在上述设置中移除旧条目，重新添加当前应用并开启权限。

## 怎么使用

1. 选择录制范围：全屏在目标显示器点击确认；窗口从列表选择；区域在目标显示器拖选。
2. 按需设置声音和自动运镜，点击「开始录制」。框选时可按 `Esc` 取消。
3. 通过悬浮条或菜单栏停止，等待视频生成后预览。重录沿用当前来源，取消则丢弃本轮录制。
4. 点击「打开文件夹」获取视频。关闭运镜时仅保存原片。

默认目录为 `~/Movies/REA-MotionRecorder/`，其中 `original.mp4` 为原片，`motion.mp4` 为运镜成片。

## 使用提示

- 区域不跨屏、不随窗口移动；窗口录制时请保持目标窗口位置和大小不变。
- 运镜由有效鼠标点击触发，接近录制结尾的点击可能不会放大。
- 麦克风使用系统默认输入设备；同时录制系统声音时建议佩戴耳机。
- 当前为早期版本，长时间录制和录制中拔屏仍待充分验证，暂不提供时间轴剪辑。

## 贡献

欢迎提交 [Issue](https://github.com/jaylpp/panda-recorder/issues) 或 Pull Request。构建方法与测试建议见 [贡献指南](CONTRIBUTING.md)。

## 许可证

采用 [MIT License](LICENSE)。功能研究的简要说明见 [来源说明](docs/PROVENANCE.md)。

## 链接作者

Made by **[🐼 熊猫 Jay](https://github.com/jaylpp)**。
