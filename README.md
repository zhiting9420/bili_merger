<div align="center">

<img src="assets/icon.png" width="128" alt="BiliMerger Logo：粉色小电视与蓝色合并箭头"/>

# BiliMerger

**把 B 站缓存变成 MP4，把弹幕一起带走。**

[![Release](https://img.shields.io/github/v/release/zhiting9420/bili_merger?color=FB7299)](https://github.com/zhiting9420/bili_merger/releases)
[![Android](https://img.shields.io/badge/Android-7.0%2B%20%7C%20arm64-00A1D6)](https://github.com/zhiting9420/bili_merger/releases/latest)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

一个用于提取哔哩哔哩 Android 客户端缓存的第三方工具。
音视频合并、弹幕转换和烧录均在本地完成，无广告。

[下载最新版](https://github.com/zhiting9420/bili_merger/releases/latest) · [反馈问题](https://github.com/zhiting9420/bili_merger/issues)

</div>

## 两种导出方式

| | 快速合并 | 弹幕烧录 |
|---|---|---|
| 输出 | MP4，可另存同名 ASS 字幕 | 自带弹幕画面的 MP4 |
| 处理 | 音视频流复制，不重新编码 | 将弹幕渲染进画面，重新编码视频 |
| 画质与耗时 | 保留原始音视频质量，通常较快 | 画质和速度取决于编码器、分辨率与设备 |
| 弹幕播放 | 播放器需支持外挂 ASS | 无需加载字幕文件 |

烧录优先使用硬件编码，失败后尝试软件编码。烧录后的弹幕无法单独关闭；只想保留原视频时，选择快速合并。

## 主要功能

- **扫描缓存**：识别 `video.m4s` 与 `audio.m4s`，读取标题、分集、时长并生成缩略图。
- **批量导出**：勾选需要的视频，多 P 按标题和分集命名；已有同名 MP4 或 ASS 时自动追加序号。
- **保护原文件**：视频先写入临时文件，成功后才保存为最终 MP4；失败或中断时清理本次半成品。
- **弹幕设置**：支持精选 / 全部、内容去重、字号、速度、透明度及显示区域；布局会避让同轨弹幕。
- **进度与中断**：整批任务使用前台服务，正常切后台可继续处理；中断后可以重新开始。
- **导出日志**：查看弹幕保留数量、实际编码器、保存路径和失败原因。
- **检查更新**：主动查询 GitHub Releases，不影响离线导出。

## 开始使用

1. 安装 APK。支持 **Android 7.0 及以上的 arm64 设备**。
2. 在 B 站客户端缓存视频，将缓存目录复制到 `Download` 等可访问位置。例如 `Android/data/com.bilibili.app.in/download`，具体路径以客户端为准。Android 新版系统限制第三方应用访问 `Android/data`，需要先通过可用的文件管理方式复制出来。
3. 打开 BiliMerger，授予「所有文件访问」权限（旧版 Android 为存储权限），通过应用内文件夹浏览器选择**输入目录**和**输出目录**。可直接选择 `Download` 或存储根目录；输出目录会先检查是否可写。系统实际禁止读取的 `Android/data` 等位置仍需先复制出来。
4. 勾选视频，点击 **合并选中 N 个**，选择快速合并或弹幕烧录。
5. 导出结果保存在输出目录。遇到问题，可点击列表上方的**日志按钮**查看详情。

支持的缓存结构：

```text
输入目录/
└── 分集目录/
    ├── entry.json       # 标题、分集等信息，可缺省
    ├── danmaku.xml      # 可选弹幕
    └── 清晰度目录/
        ├── video.m4s
        └── audio.m4s
```

## 常见问题

**为什么弹幕变少了？**

筛选、去重和防重叠布局都会减少显示数量。可切换到「全部弹幕」、增大显示区域或提高速度，具体统计见日志。外挂 ASS 的实际布局还受播放器和字体影响。

**精选模式为什么不滚动？**

精选保留彩色、顶部 / 底部及高权重弹幕，并以固定位置显示。想保留滚动效果，选择「全部弹幕」。

**没有弹幕缓存怎么办？**

仍可快速合并视频。批量烧录中没有弹幕缓存的项目，也会按快速合并处理。只有 `danmaku.xml` 可用于本工具的弹幕转换。

**切后台、锁屏或关闭 App 会怎样？**

正常切后台可继续导出，但设备省电策略仍可能限制运行。从最近任务中移除 App 会停止任务。长视频烧录会发热耗电，实际速度以设备为准。

**支持其他缓存格式或平台吗？**

目前仅支持上述 Android `.m4s` 缓存结构，不支持 iOS、电脑端缓存或旧式分段格式。

## 从源码构建

需要 Flutter（Dart ≥ 3.10.4）、Android SDK 和 Java 17。

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

APK 输出：`build/app/outputs/flutter-apk/app-release.apk`。
正式签名读取本地 `android/key.properties`；未配置时使用调试签名。

原生回归测试：

```bash
cd android
./gradlew :app:testDebugUnitTest
```

### FFmpeg 与图标

项目自带精简的 FFmpeg，以 `libffmpeg.so` 存放在 `android/app/src/main/jniLibs/arm64-v8a/`，由 Android 原生层作为子进程运行。无需 `ffmpeg_kit_flutter`。

重新编译 FFmpeg（Linux）：

```bash
export ANDROID_NDK_HOME=/path/to/ndk
bash tools/ffmpeg/build-ffmpeg-slim.sh
cp tools/ffmpeg/out/libffmpeg.so android/app/src/main/jniLibs/arm64-v8a/
```

脚本下载所需源码，并应用 MediaCodec 输入缓冲区 stride 修正补丁。构建还需要 C/C++ 构建工具、Meson、Ninja、pkg-config、curl、Git 和 patch。

Logo 使用粉色小电视与蓝色合并箭头。应用内图标和启动图标源文件位于 `assets/`；修改后运行：

```bash
dart run flutter_launcher_icons
```

## 开源协议

[GNU GPLv3](LICENSE)。第三方组件及其许可证见 [THIRD-PARTY.md](THIRD-PARTY.md)，FFmpeg 构建脚本与补丁见 [tools/ffmpeg/](tools/ffmpeg/)。

用于备份你有权处理的本地缓存内容。
