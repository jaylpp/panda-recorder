首个预览版，支持全屏、窗口、区域录制，系统声音与麦克风，以及可选的自动运镜。

## 安装

下载 `PandaRecorder-v0.1.0-macOS-arm64.zip`，解压后将「熊猫录屏.app」拖到「应用程序」。

- **要求**：Apple Silicon（M 系列），macOS 15+；macOS 15 尚待实测。
- **未公证**：首次打开可能被系统拦截，确认来源后按「系统设置 → 隐私与安全性」中的提示操作。
- **授权**：在「录屏与系统录音」中允许熊猫录屏，再退出重开；麦克风按需授权。

## 注意

区域不跨屏；窗口录制时请保持目标窗口位置和大小不变。长时间录制和录制中拔屏仍待充分验证。

使用说明及权限排查见 [README](https://github.com/jaylpp/panda-recorder#readme)。

<details>
<summary>校验下载文件（可选）</summary>

将 ZIP 与 `SHA256SUMS.txt` 放在同一目录，运行：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

</details>
