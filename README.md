<div align="center">

<img src="assets/icon.png" width="96" alt="BiliMerger"/>

# BiliMerger

**哔哩哔哩缓存视频和弹幕提取工具**

[![Release](https://img.shields.io/github/v/release/zhiting9420/bili_merger?color=FB7299)](https://github.com/zhiting9420/bili_merger/releases)
[![Platform](https://img.shields.io/badge/Android-arm64-3DDC84?logo=android)](https://www.android.com/)
[![Size](https://img.shields.io/badge/APK-15.7%20MB-blue)](https://github.com/zhiting9420/bili_merger/releases)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

把 B 站客户端缓存的 `.m4s` 还原成完整 MP4,并能**把弹幕烧进画面**。
本地离线运行,无广告。

</div>

## 两种导出方式

|  | 快速合并 | 弹幕烧录 |
|---|---|---|
| 原理 | `-c copy` 流复制 | 弹幕渲染进画面,重新编码 |
| 耗时 | 秒级 | 视频时长的 1/9 ~ 1/2 |
| 画质 | 无损 | 重编码,肉眼几乎无差 |
| 弹幕 | 另存 `.ass`,需播放器支持外挂字幕 | 烧进画面,**任何播放器都能看** |
| 适合 | 自己收藏 | 转发分享、传到别的平台 |

外挂 `.ass` 在手机上处处受限:系统相册、微信、抖音都不认,发给别人弹幕就丢。烧录解决的就是这个。

## ✨ 特性

- 🔥 **弹幕烧录** —— 优先用手机硬件编码器(实测 9~11 倍实时速度),失败自动回退软件编码
- ⭐ **精选 / 全部两档筛选** —— 精选只留彩色、顶部/底部与 B 站权重最高档的弹幕,并静止显示
- 🧯 **零重叠布局** —— 滚动弹幕统一速度不追尾,排不下的宁可舍弃也不叠字
- 🔍 **智能扫描** —— 自动读取标题、分集、时长,列表显示缩略图
- 📁 **多 P / 合集** —— 按「标题 + 分集名」命名去重,不会互相覆盖
- ☑️ **勾选 / 中断** —— 逐项勾选,导出中随时可停,半成品自动删除
- 🔔 **后台不中断** —— 前台服务 + 通知栏进度,切走也不会被系统冻结
- 🔄 **检查更新** —— 内置 GitHub Releases 版本检查

## 📲 安装

[**下载最新版**](https://github.com/zhiting9420/bili_merger/releases/latest) · 仅支持 arm64 设备

## 📋 使用

1. 打开 App,授予「所有文件访问」权限
2. 用 MT 管理器把 `Android/data/com.bilibili.app.in/download` 复制到 `Download` 等普通目录
   *(安卓 11 起 `Android/data` 不允许第三方应用直接读取)*
3. 选好 **输入目录** 和 **输出目录**
4. 勾选视频 → 点 **合并选中 N 个** → 选快速合并或弹幕烧录

## ❓ 常见问题

#### 弹幕怎么比 B 站少很多?

为了保证互不遮挡,显示区域内排不下的弹幕会被舍弃,而不是硬叠上去。

嫌少就调大「显示区域」、调快「弹幕速度」,或切到「全部弹幕」。合并日志会写明保留和舍弃了多少条。

#### 精选模式的弹幕为什么不飘?

精选模式一律静止显示。B 站 93% 的弹幕是滚动的,飘起来必然遮挡画面;静止既不挡画面,渲染开销也低得多。要飘的就切「全部弹幕」。

#### 烧录要多久?

硬件编码可用时约 9~11 倍实时速度,20 分钟的视频约 2 分钟;回退到软件编码约 2~4 倍。会发热耗电,建议插着电。

#### 支持鸿蒙 / iOS / 电脑端缓存吗?

不支持,本项目只做 Android 客户端缓存。跨平台需求可以看 [hlbmerge_flutter](https://github.com/molihuan/hlbmerge_flutter)。

## 🔨 从源码构建

```bash
flutter pub get
flutter build apk --release   # 单一 arm64-v8a APK
```

FFmpeg 是本项目**自行交叉编译**的精简二进制(9.3 MB,通用构建要 45 MB),
以 `libffmpeg.so` 的名字放在 `android/app/src/main/jniLibs/`,运行时由原生层当子进程调起
(**不是** `ffmpeg_kit_flutter`)。重新编译:

```bash
export ANDROID_NDK_HOME=/path/to/ndk
bash tools/ffmpeg/build-ffmpeg-slim.sh
```

脚本会拉取 FFmpeg / x264 / libass / dav1d 等全部源码并打上本地补丁,其中包含一个让
`h264_mediacodec` 向编码器查询真实输入缓冲区 stride 的修正 —— 不打这个补丁,
部分机型硬件编码的画面会错切并出现绿边。

## 📄 开源协议

[GNU GPLv3](LICENSE)。内置 FFmpeg 启用了 `--enable-gpl --enable-libx264`,分发物整体受 GPL 约束;
对应构建脚本见 `tools/ffmpeg/`,第三方组件许可证见 [THIRD-PARTY.md](THIRD-PARTY.md)。

仅供备份你自己缓存的内容,请勿用于侵犯版权的用途。
