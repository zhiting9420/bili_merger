# 第三方组件与许可证

BiliMerger 随应用分发一个自行交叉编译的 FFmpeg 可执行文件
(`android/app/src/main/jniLibs/arm64-v8a/libffmpeg.so`),以及一份中文字体。
本文件列出其中包含的第三方组件及其许可证。

## ⚠️ 关于分发许可

随应用分发的 FFmpeg 二进制在编译时启用了 `--enable-gpl --enable-libx264`,
因此**该二进制及包含它的 APK 整体受 GPLv2 或更高版本约束**。
本仓库中 BiliMerger 自身的源代码依 `LICENSE` 授权,但**二进制分发物按 GPL 提供**。

对应源码与完整构建方式已随仓库提供:

- 构建脚本:`tools/ffmpeg/build-ffmpeg-slim.sh`(一键拉取全部源码并编译)
- 本地补丁:`tools/ffmpeg/patches/`
- 完整 configure 参数可从二进制中读出:
  `strings libffmpeg.so | grep -m1 -- '--prefix='`

## 包含的组件

| 组件 | 版本 | 许可证 | 用途 |
|---|---|---|---|
| [FFmpeg](https://ffmpeg.org/) | 8.1.2 | GPLv2+(因启用 libx264) | 音视频解封装、解码、编码、滤镜 |
| [x264](https://www.videolan.org/developers/x264.html) | stable | GPLv2+ | H.264 软件编码(硬件编码失败时的兜底) |
| [libass](https://github.com/libass/libass) | 0.17.3 | ISC | 把 ASS 弹幕渲染进画面 |
| [FreeType](https://freetype.org/) | 2.13.3 | FTL / GPLv2 双授权 | 字形光栅化 |
| [FriBidi](https://github.com/fribidi/fribidi) | 1.0.16 | LGPLv2.1+ | 双向文本处理 |
| [HarfBuzz](https://harfbuzz.github.io/) | 10.4.0 | MIT | 文字整形(libass 的硬依赖) |
| [dav1d](https://code.videolan.org/videolan/dav1d) | 1.5.1 | BSD-2-Clause | AV1 解码(B 站 AV1 缓存) |
| [Noto Sans CJK SC](https://github.com/notofonts/noto-cjk) | 2.004 | SIL OFL 1.1 | 弹幕烧录字体(子集,见 `assets/fonts/OFL.txt`) |

字体经过子集化(属于 OFL 允许的修改),家族名已改为 `BiliDanmaku`。
OFL 1.1 全文随字体一并分发于 `assets/fonts/OFL.txt`。

## Flutter 依赖

`pubspec.yaml` 中的 Dart 包各自遵循其在 pub.dev 上声明的许可证,
绝大多数为 BSD-3-Clause 或 MIT。
