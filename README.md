<div align="center">

<img src="assets/icon.png" width="96" alt="BiliMerger"/>

# BiliMerger

**哔哩哔哩缓存视频和弹幕提取工具**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Platform](https://img.shields.io/badge/Platform-Android%20arm64-3DDC84?logo=android)](https://www.android.com/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

BiliMerger 是一款用于把哔哩哔哩手机客户端缓存的分离音视频流（`.m4s`）**无损合并**为完整的 MP4，并支持把弹幕（XML）转换为 ASS 字幕。全程在本地离线完成，不上传任何数据。

## ✨ 功能特性

- 🔍 **智能扫描**：自动识别所选缓存目录，读取标题、分集与时长信息。
- 🖼️ **缩略图预览**：列表直接显示视频缩略图与时长。
- 🛠️ **无损合并**：内置 FFmpeg 以 `-c copy` 流复制方式合并音视频，不重编码，速度受限于磁盘 IO（约 10GB/分钟）。
- 📁 **多 P / 合集**：自动按「标题 + 分集名」命名并去重，避免同名文件互相覆盖。
- 💬 **弹幕转换**：XML → ASS，可调透明度、字体、大小、速度、显示区域与渲染画质（720P/1080P/2K/4K）。
- 🧯 **防重叠布局**：滚动弹幕按轨道空闲情况智能分配，避免同屏叠字。
- 🎨 **个性化主题**：粉 / 蓝 / 紫 / 绿多种配色。
- 🔄 **检查更新**：内置 GitHub Releases 版本检查。

## 📲 安装

前往 [Releases](https://github.com/zhiting9420/bili_merger/releases) 下载最新的 `arm64-v8a` APK 安装即可（仅支持 64 位设备，现代手机均为 64 位）。

## 📋 使用方法

1. 打开 App，授予「所有文件访问 / 存储」权限。
2. 点击 **输入目录**，选择 B 站缓存目录（需要使用MT管理器把 `Android/data/com.bilibili.app.in/download` 缓存复制到非data目录）。
3. 点击 **输出目录**，选择合并后视频的保存位置。
4. 在列表中确认待合并的视频，点击 **开始合并**。
5. 合并完成后，可在输出目录查看 MP4（含弹幕时会同时生成同名 `.ass`，用支持外挂字幕的播放器如 MX Player 加载即可看弹幕）。


## 🔨 从源码构建

需要 [Flutter SDK](https://docs.flutter.dev/get-started/install) 与 Android 环境。

```bash
flutter pub get
flutter build apk --release   # 产物为单一 arm64-v8a APK
```

> FFmpeg 为预编译的原生二进制（`android/app/src/main/jniLibs/arm64-v8a/libffmpeg.so`），已随仓库提供，运行时经原生层以子进程方式调用。

## 🛠️ 技术栈

- **框架**：Flutter / Dart（状态管理 Provider）
- **合并核心**：预编译 FFmpeg 二进制（原生 `ProcessBuilder` 调用，非 ffmpeg_kit）
- **弹幕**：自研 XML → ASS 转换器

## 🔒 隐私

本应用完全在本地运行，不收集、不上传任何个人信息或使用数据，不含广告与第三方追踪。详见 App 内「关于 → 隐私协议」。

## 📄 开源协议

本项目采用 [MIT License](LICENSE)。仅供个人学习与备份自己缓存的内容使用，请勿用于侵犯版权的用途。
