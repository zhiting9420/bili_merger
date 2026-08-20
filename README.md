<div align="center">

<img src="assets/icon.png" width="96" alt="BiliMerger"/>

# BiliMerger

**哔哩哔哩缓存视频和弹幕提取工具**

[![Release](https://img.shields.io/github/v/release/zhiting9420/bili_merger?color=FB7299)](https://github.com/zhiting9420/bili_merger/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Platform](https://img.shields.io/badge/Platform-Android%20arm64-3DDC84?logo=android)](https://www.android.com/)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

把 B 站客户端缓存的分离音视频流(`.m4s`)还原成完整 MP4,
并且能**把弹幕直接烧进画面** —— 一个文件走天下,发给谁都带弹幕。

全程本地离线完成,不联网、不上传、无广告。安装包 15.7 MB。

</div>

## 两种导出方式

勾选视频后点导出,会让你二选一:

|  | 快速合并 | 弹幕烧录 |
|---|---|---|
| 原理 | `-c copy` 流复制,不重编码 | 弹幕渲染进画面像素,重新编码 |
| 耗时 | 秒级(受磁盘 IO 限制) | 约实时的 1/9 ~ 1/2(优先用手机硬件编码器) |
| 画质 | 完全无损 | 重编码,肉眼几乎无差别 |
| 弹幕 | 另存同名 `.ass`,要播放器支持外挂字幕 | 烧进画面,**任何播放器、任何平台都能看到** |
| 适合 | 自己收藏、要保原画质 | 转发分享、上传到别的平台 |

外挂 `.ass` 在手机上限制很多:系统相册、微信、抖音都不认,发给别人弹幕就丢了,
MX Player 之类实时渲染弹幕还容易掉帧。烧录就是为了解决这些。

## ✨ 功能特性

- 🔥 **弹幕烧录** —— 弹幕烧进画面输出单个 MP4。优先调用手机硬件编码器(实测约 9~11 倍实时速度),
  失败自动回退软件编码。逐帧离线渲染,再多弹幕也不会卡。
- ⭐ **精选 / 全部两档筛选** —— 精选只留彩色、顶部/底部、以及 B 站权重最高档(≈"高赞")的弹幕,
  并全部静止显示,画面清爽;全部则还原 B 站观感。支持同款弹幕去重。
- 🧯 **零重叠布局** —— 滚动弹幕统一速度不会追尾,顶部/底部各自分配轨道,
  显示区域排不下时**宁可舍弃也绝不叠字**。
- 🔍 **智能扫描** —— 自动识别缓存目录,读取标题、分集、时长,列表直接显示缩略图。
- 📁 **多 P / 合集** —— 按「标题 + 分集名」命名并自动去重,不会互相覆盖。
- ☑️ **逐项勾选 / 随时中断** —— 默认全选,可单独取消;导出中点按钮即停,半成品文件自动删除。
- 🔔 **后台不中断** —— 烧录走前台服务并在通知栏显示进度,切到别的 App 也不会被系统冻结。
- 🎨 **个性化** —— 弹幕字号 / 速度 / 透明度 / 显示区域可调,应用主题四种配色。
- 🔄 **检查更新** —— 内置 GitHub Releases 版本检查。

## 📲 安装

前往 [Releases](https://github.com/zhiting9420/bili_merger/releases) 下载最新 APK。

仅支持 **arm64 设备**(2015 年后的手机基本都是),不再提供 32 位包。

## 📋 使用方法

1. 打开 App,授予「所有文件访问」权限。
2. 用 MT 管理器等工具把 `Android/data/com.bilibili.app.in/download`
   整个复制到 `Download` 之类的普通目录 —— 安卓 11 起 `Android/data` 不允许第三方应用直接读取。
3. 点 **输入目录** 选刚才复制出来的文件夹,点 **输出目录** 选保存位置。
4. 勾选要处理的视频(默认全选),点 **合并选中 N 个**,选择快速合并或弹幕烧录。

## ❓ 常见问题

**弹幕怎么比 B 站少了很多?**
这是刻意的。为了保证弹幕互不遮挡,显示区域内排不下的弹幕会被舍弃而不是硬叠上去。
嫌少就去设置里把「显示区域」调大、「弹幕速度」调快,或者把筛选切到「全部弹幕」。
合并日志里会写明这一条视频保留了多少、舍弃了多少。

**精选模式为什么弹幕不飘了?**
精选模式下弹幕一律静止显示。B 站的弹幕 93% 都是滚动的,飘起来必然遮挡画面;
静止显示既不挡画面,渲染开销也低得多。想要飘的就切「全部弹幕」。

**烧录要多久?**
取决于机型和视频时长。硬件编码可用时约 9~11 倍实时速度(20 分钟的视频约 2 分钟),
回退到软件编码约 2~4 倍。会明显发热耗电,建议插着电。

**支持鸿蒙 / iOS / 电脑端缓存吗?**
不支持,本项目只做 Android 客户端缓存。跨平台需求可以看
[hlbmerge_flutter](https://github.com/molihuan/hlbmerge_flutter)。

## 🔨 从源码构建

需要 [Flutter SDK](https://docs.flutter.dev/get-started/install) 与 Android 开发环境。

```bash
flutter pub get
flutter build apk --release   # 产物为单一 arm64-v8a APK
```

FFmpeg 是本项目**自行交叉编译**的精简二进制(9.3 MB,原来用通用构建要 45 MB),
以 `libffmpeg.so` 的名字放在 `android/app/src/main/jniLibs/`,运行时由原生层当子进程调起。
要重新编译它:

```bash
export ANDROID_NDK_HOME=/path/to/ndk
bash tools/ffmpeg/build-ffmpeg-slim.sh
```

脚本会自动拉取 FFmpeg / x264 / libass / dav1d 等全部源码并打上本地补丁,
其中包含一个让 `h264_mediacodec` 向编码器查询真实输入缓冲区 stride 的修正 ——
不打这个补丁,部分机型的硬件编码画面会错切并出现绿边。

## 🛠️ 技术栈

- **框架**:Flutter / Dart,状态管理 Provider
- **音视频**:自编译 FFmpeg 8.1.2(**不是** `ffmpeg_kit_flutter`),经 MethodChannel + `ProcessBuilder` 以子进程方式调用
- **弹幕**:自研 XML → ASS 转换器,含轨道分配与防重叠布局
- **字体**:内置 Noto Sans CJK SC 子集,因为编译的 FFmpeg 不带 fontconfig,libass 找不到系统字体

## 🔒 隐私

完全本地运行,不收集、不上传任何信息,无广告、无第三方追踪。
唯一的联网行为是「关于 → 检查更新」访问 GitHub Releases API。

## 📄 开源协议

[GNU GPLv3](LICENSE)。

之所以是 GPL 而非更宽松的协议:随应用分发的 FFmpeg 启用了 `--enable-gpl --enable-libx264`,
分发物整体受 GPL 约束。对应的完整构建脚本与补丁已随仓库提供(`tools/ffmpeg/`),
第三方组件及各自许可证见 [THIRD-PARTY.md](THIRD-PARTY.md)。

本工具仅供备份你自己缓存的内容,请勿用于侵犯版权的用途。
