import 'package:xml/xml.dart';

/// 弹幕筛选模式。
enum DanmakuFilter {
  /// 精选:只保留彩色、顶部/底部、以及 B 站权重最高档(俗称「点赞多」)的弹幕,
  /// 并且**一律改为不飘的固定显示**。实测约保留 21%。
  /// 静止文字不需要逐帧重算位置,外挂播放时比滚动弹幕流畅得多。
  featured,

  /// 全部:在精选的基础上再加回普通滚动弹幕。
  all,
}

/// B 站弹幕权重(p 属性第 9 个字段)的最高档。
/// 该字段取值 1..10,正是 B 站播放器「弹幕屏蔽等级」滑块使用的字段,
/// 官方用它过滤刷屏与低质弹幕。缓存的 XML 里没有点赞数,权重是最接近的信号。
const int kTopWeight = 10;

class DanmakuOptions {
  final int resX;
  final int resY;
  final int fontSize;

  /// 一条「零宽度」弹幕横穿整个画面所需的秒数(已含速度换算)。
  /// 实际弹幕的存活时长按其宽度等比延长,以保证所有滚动弹幕速度一致。
  final double duration;
  final double opacity;
  final bool bold;
  final String fontName;

  /// 弹幕显示区域占画面高度的比例。
  final double area;

  /// 保证弹幕互不重叠。开启后,显示区域内排不下的弹幕会被丢弃而不是叠上去。
  final bool noOverlap;

  /// 筛选模式。
  final DanmakuFilter filter;

  /// 同款去重:内容完全相同的弹幕只保留最早的一条。
  final bool dedupe;

  const DanmakuOptions({
    this.resX = 1920,
    this.resY = 1080,
    this.fontSize = 50,
    this.duration = 10.0,
    this.opacity = 0.7,
    this.bold = false,
    this.fontName = "黑体",
    this.area = 0.5,
    this.noOverlap = true,
    this.filter = DanmakuFilter.all,
    this.dedupe = true,
  });
}

/// 转换结果。除 ASS 正文外附带统计,便于在界面上说明「为什么弹幕变少了」。
class DanmakuResult {
  /// ASS 文件内容。
  final String ass;

  /// 原始弹幕总条数。
  final int total;

  /// 最终写入 ASS 的条数。
  final int kept;

  /// 被筛选模式剔除的条数。
  final int filtered;

  /// 被同款去重剔除的条数。
  final int deduped;

  /// 因显示区域排满、为保证不重叠而丢弃的条数。
  final int overflow;

  const DanmakuResult({
    required this.ass,
    this.total = 0,
    this.kept = 0,
    this.filtered = 0,
    this.deduped = 0,
    this.overflow = 0,
  });

  String get summary =>
      "弹幕 $total 条 → 保留 $kept 条(筛选 -$filtered,去重 -$deduped,超出区域 -$overflow)";
}

/// 解析后的单条弹幕。
class _Danmaku {
  final double time;
  final int mode;
  final int color;
  final int weight;
  final String text;
  final double width;

  _Danmaku(this.time, this.mode, this.color, this.weight, this.text, this.width);

  bool get isRoll => mode == 1 || mode == 2 || mode == 3;
  bool get isReverse => mode == 6;
  bool get isTop => mode == 5;
  bool get isBottom => mode == 4;
  bool get isColored => color != 0xFFFFFF;
}

class XmlToAssConverter {
  /// 行高相对字号的倍率。
  static const double _lineRatio = 1.2;

  /// 同轨道相邻弹幕之间的时间留白(秒)。除了让画面不至于首尾相接,
  /// 也用来吸收 ASS 时间轴只精确到 0.01 秒所带来的取整误差。
  static const double _gapSec = 0.05;

  static DanmakuResult convertWithStats(
    String xmlContent, {
    DanmakuOptions? options,
  }) {
    final opt = options ?? const DanmakuOptions();
    try {
      return _run(xmlContent, opt);
    } catch (_) {
      // 解析失败时返回一个只有头部的合法 ASS,调用方据此写出空弹幕文件。
      return DanmakuResult(ass: _generateHeader(opt));
    }
  }

  // ---------------------------------------------------------------- 主流程

  static DanmakuResult _run(String xmlContent, DanmakuOptions opt) {
    final document = XmlDocument.parse(xmlContent);
    final nodes = document.findAllElements('d').toList();

    int total = 0;
    int filtered = 0;
    int deduped = 0;

    final seen = <String>{};
    final list = <_Danmaku>[];

    for (final node in nodes) {
      final pAttr = node.getAttribute('p');
      if (pAttr == null) continue;
      final raw = node.innerText.trim();
      if (raw.isEmpty) continue;

      final params = pAttr.split(',');
      if (params.length < 4) continue;

      total++;

      final time = double.tryParse(params[0]) ?? 0.0;
      final mode = int.tryParse(params[1]) ?? 1;
      final color = int.tryParse(params[3]) ?? 0xFFFFFF;
      // 第 9 个字段是权重,老弹幕文件可能没有,缺失时按最高档处理以免被误杀。
      final weight = params.length > 8
          ? (int.tryParse(params[8]) ?? kTopWeight)
          : kTopWeight;

      // 只处理普通弹幕的五种模式;高级弹幕(7)、代码弹幕(8)、BAS(9)格式完全不同,跳过。
      const supported = {1, 2, 3, 4, 5, 6};
      if (!supported.contains(mode)) {
        filtered++;
        continue;
      }

      if (!_passesFilter(opt.filter, mode, color, weight)) {
        filtered++;
        continue;
      }

      if (opt.dedupe && !seen.add(raw)) {
        deduped++;
        continue;
      }

      // 精选模式下弹幕不飘:滚动(1/2/3)与逆向(6)一律改为顶部固定显示,
      // 底部弹幕(4)保持在底部。这样既不遮挡画面,也没有滚动的渲染开销。
      final effectiveMode =
          (opt.filter == DanmakuFilter.featured && mode != 4) ? 5 : mode;

      list.add(
        _Danmaku(
          time,
          effectiveMode,
          color,
          weight,
          _escape(raw),
          _textWidth(raw, opt.fontSize),
        ),
      );
    }

    list.sort((a, b) => a.time.compareTo(b.time));

    final layout = _layout(list, opt);

    return DanmakuResult(
      ass: _generateHeader(opt) + layout.events.join('\n'),
      total: total,
      kept: layout.events.length,
      filtered: filtered,
      deduped: deduped,
      overflow: layout.overflow,
    );
  }

  static bool _passesFilter(
    DanmakuFilter filter,
    int mode,
    int color,
    int weight,
  ) {
    if (filter == DanmakuFilter.all) return true;
    // 精选:彩色、或固定位置(顶/底)、或权重最高档。
    return color != 0xFFFFFF ||
        mode == 4 ||
        mode == 5 ||
        weight >= kTopWeight;
  }

  // ---------------------------------------------------------------- 排版

  static _Layout _layout(List<_Danmaku> list, DanmakuOptions opt) {
    final events = <String>[];
    int overflow = 0;

    // 行距取整并向上进位:ASS 的坐标要写成整数,若让 21.6 / 98.4 各自四舍五入,
    // 相邻轨道会凭空丢掉 0.8px 间距而擦边重叠。整数行距能保证间距恒定不小于行高。
    final double lineHeight = opt.fontSize * _lineRatio;
    final int rowH = lineHeight.ceil();
    final int topMargin = (opt.resY * 0.02).round();

    // 整屏最多能排下多少行(上下各留一个边距)。顶部/滚动池自上而下取,
    // 底部池自下而上取,两者从这同一个预算里瓜分,因此几何上必然不相交。
    final int totalRows = ((opt.resY - 2 * topMargin) / rowH).floor().clamp(1, 60);
    final double areaHeight =
        (opt.resY * opt.area).clamp(lineHeight, opt.resY.toDouble());
    int channels = ((areaHeight - topMargin) / rowH).floor().clamp(1, totalRows);
    int bottomChannels = totalRows - channels;
    if (bottomChannels < 1 && channels > 1) {
      // 显示区域占满全屏时,宁可从顶部让出一行也要给底部弹幕留位置。
      channels -= 1;
      bottomChannels = 1;
    }

    // 统一速度:零宽弹幕耗时 duration 走完 resX,因此速度恒定,滚动弹幕永不追尾。
    final double velocity = opt.resX / (opt.duration <= 0 ? 10.0 : opt.duration);
    // 固定弹幕停留时长跟随速度设置,不再写死。
    final double fixedDur = (opt.duration * 0.5).clamp(3.0, 6.0);

    // 顶部弹幕与滚动弹幕共用同一批轨道(都自上而下排),因此必须互相避让。
    // 先排顶部,记录每条轨道被占用的时间段,滚动弹幕再绕开这些时间段。
    final topStarts = List.generate(channels, (_) => <double>[]);
    final topEnds = List.generate(channels, (_) => <double>[]);
    // 底部弹幕自下而上排,轨道数已按上面的剩余空间算好,与顶部池互不相交。
    final bottomFreeAt = List.filled(bottomChannels, double.negativeInfinity);
    // 每条轨道上「上一条滚动弹幕的尾部完全进入画面」的时刻。
    final rollFreeAt = List.filled(channels, double.negativeInfinity);

    // ---- 第一趟:固定弹幕(顶部 / 底部)
    for (final d in list) {
      if (!d.isTop && !d.isBottom) continue;
      final start = d.time;
      final end = d.time + fixedDur;

      String body;
      int? ch;
      if (d.isTop) {
        for (int c = 0; c < channels; c++) {
          // 同一轨道上一条顶部弹幕必须已经消失并留出间隙。
          if (topEnds[c].isEmpty || topEnds[c].last + _gapSec <= start) {
            ch = c;
            break;
          }
        }
        if (ch == null) {
          if (opt.noOverlap) {
            overflow++;
            continue;
          }
          ch = 0;
        }
        topStarts[ch].add(start);
        topEnds[ch].add(end);
        final y = topMargin + ch * rowH;
        body = "{\\an8${_colorTag(d.color)}\\pos(${opt.resX ~/ 2},$y)}${d.text}";
      } else {
        for (int c = 0; c < bottomChannels; c++) {
          if (bottomFreeAt[c] + _gapSec <= start) {
            ch = c;
            break;
          }
        }
        if (ch == null) {
          // 底部轨道可能为 0 条(显示区域占满全屏),此时只能丢弃。
          if (opt.noOverlap || bottomChannels == 0) {
            overflow++;
            continue;
          }
          ch = 0;
        }
        bottomFreeAt[ch] = end;
        final y = opt.resY - topMargin - ch * rowH;
        body = "{\\an2${_colorTag(d.color)}\\pos(${opt.resX ~/ 2},$y)}${d.text}";
      }
      events.add(_dialogue(d.isTop ? "Top" : "Bottom", start, end, body));
    }

    // ---- 第二趟:滚动 / 逆向弹幕
    for (final d in list) {
      if (!d.isRoll && !d.isReverse) continue;

      final travel = opt.resX + d.width;
      final life = travel / velocity;
      final start = d.time;
      final end = d.time + life;
      // 尾部完全进入画面、并再空出一个字宽之后,同轨道才可以放下一条。
      final freeAt = start + (d.width + opt.fontSize) / velocity;

      int? ch;
      for (int c = 0; c < channels; c++) {
        if (rollFreeAt[c] > start) continue;
        // 还要避开这条轨道上停留的顶部弹幕。
        if (_hitsFixed(topStarts[c], topEnds[c], start - _gapSec, end + _gapSec)) {
          continue;
        }
        ch = c;
        break;
      }
      if (ch == null) {
        if (opt.noOverlap) {
          overflow++;
          continue;
        }
        ch = 0;
      }
      rollFreeAt[ch] = freeAt;

      final yStr = (topMargin + ch * rowH).toString();
      // \an7 把锚点设在文字左上角,x 即左边缘,轨道 y 与固定弹幕口径一致。
      final x1 = d.isReverse ? (-d.width).toStringAsFixed(0) : opt.resX.toString();
      final x2 = d.isReverse ? opt.resX.toString() : (-d.width).toStringAsFixed(0);
      events.add(
        _dialogue(
          "Roll",
          start,
          end,
          "{\\an7${_colorTag(d.color)}\\move($x1,$yStr,$x2,$yStr)}${d.text}",
        ),
      );
    }

    // 两趟分别生成,需要按时间重新排好,ASS 才便于阅读和播放器索引。
    events.sort((a, b) => _startOf(a).compareTo(_startOf(b)));

    return _Layout(events, overflow);
  }

  /// 判断 [a,b] 是否与该轨道上任何一条固定弹幕的停留时段相交。
  /// 固定弹幕时长一致,故 ends 与 starts 同序递增,只需检查最后一个 start <= b 的区间。
  static bool _hitsFixed(
    List<double> starts,
    List<double> ends,
    double a,
    double b,
  ) {
    if (starts.isEmpty) return false;
    int lo = 0, hi = starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] <= b) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo > 0 && ends[lo - 1] > a;
  }

  // ---------------------------------------------------------------- 工具

  /// 东亚全角字符按 1 个字号宽,其余按半个 —— 旧实现一律按 0.8,
  /// 导致中文弹幕宽度被低估约 20%,防重叠因此失效。
  static double _textWidth(String s, int fontSize) {
    double units = 0;
    for (final r in s.runes) {
      units += _isWide(r) ? 1.0 : 0.5;
    }
    return units * fontSize;
  }

  static bool _isWide(int r) =>
      (r >= 0x1100 && r <= 0x115F) ||
      (r >= 0x2E80 && r <= 0xA4CF) ||
      (r >= 0xAC00 && r <= 0xD7A3) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0xFE30 && r <= 0xFE6F) ||
      (r >= 0xFF00 && r <= 0xFF60) ||
      (r >= 0xFFE0 && r <= 0xFFE6) ||
      (r >= 0x1F300 && r <= 0x1FAFF) ||
      (r >= 0x20000 && r <= 0x3FFFD);

  /// ASS 用 {} 界定样式块、\ 作转义,弹幕正文里出现这些字符会破坏整行。
  /// 换成全角同形字符,对中文内容视觉上无损。
  static String _escape(String s) => s
      .replaceAll('\\', '＼')
      .replaceAll('{', '｛')
      .replaceAll('}', '｝')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ');

  /// 只覆盖颜色,不动透明度 —— 透明度由样式的 PrimaryColour alpha 提供。
  /// 旧实现写成 8 位的 {\c&H00BBGGRR},那个 00 会被部分渲染器当成 alpha,
  /// 导致彩色弹幕比白色弹幕更不透明。
  static String _colorTag(int color) {
    if (color == 0xFFFFFF) return "";
    final b = ((color) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
    final g = ((color >> 8) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
    final r = ((color >> 16) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
    return "\\c&H$b$g$r&";
  }

  static String _dialogue(String style, double start, double end, String body) =>
      "Dialogue: 0,${_formatTime(start)},${_formatTime(end)},$style,,0,0,0,,$body";

  static double _startOf(String dialogue) {
    // "Dialogue: 0,H:MM:SS.cc,..." —— 取第 2 个字段解析成秒。
    final parts = dialogue.split(',');
    if (parts.length < 2) return 0;
    final t = parts[1].split(':');
    if (t.length != 3) return 0;
    return (double.tryParse(t[0]) ?? 0) * 3600 +
        (double.tryParse(t[1]) ?? 0) * 60 +
        (double.tryParse(t[2]) ?? 0);
  }

  static String _formatTime(double seconds) {
    if (seconds < 0) seconds = 0;
    // 先取整到厘秒再拆分,避免 (s*100)%100 的浮点误差把 0 算成 99。
    int cs = (seconds * 100).round();
    final h = cs ~/ 360000;
    cs %= 360000;
    final m = cs ~/ 6000;
    cs %= 6000;
    final s = cs ~/ 100;
    cs %= 100;
    return "$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}";
  }

  static String _generateHeader(DanmakuOptions options) {
    final alphaHex = ((1 - options.opacity) * 255)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0')
        .toUpperCase();
    final boldVal = options.bold ? "1" : "0";
    const common = "0,0,0,100,100,0,0,1,2,0";

    return """[Script Info]
ScriptType: v4.00+
Collisions: Normal
WrapStyle: 2
ScaledBorderAndShadow: yes
PlayResX: ${options.resX}
PlayResY: ${options.resY}
Timer: 100.0000

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Roll,${options.fontName},${options.fontSize},&H${alphaHex}FFFFFF,&H00FFFFFF,&H00000000,&H00000000,$boldVal,$common,7,0,0,0,1
Style: Top,${options.fontName},${options.fontSize},&H${alphaHex}FFFFFF,&H00FFFFFF,&H00000000,&H00000000,$boldVal,$common,8,0,0,0,1
Style: Bottom,${options.fontName},${options.fontSize},&H${alphaHex}FFFFFF,&H00FFFFFF,&H00000000,&H00000000,$boldVal,$common,2,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""";
  }
}

class _Layout {
  final List<String> events;
  final int overflow;
  const _Layout(this.events, this.overflow);
}
