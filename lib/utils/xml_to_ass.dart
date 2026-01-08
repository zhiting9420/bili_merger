import 'dart:math';
import 'package:xml/xml.dart';

class DanmakuOptions {
  final int resX;
  final int resY;
  final int fontSize;
  final double duration;
  final double opacity;
  final bool bold;
  final String fontName;
  final double area;
  final bool noOverlap;
  final bool showCritical;
  final bool showScroll;
  final bool showFixed;

  DanmakuOptions({
    this.resX = 1920,
    this.resY = 1080,
    this.fontSize = 50,
    this.duration = 10.0,
    this.opacity = 0.7,
    this.bold = false,
    this.fontName = "黑体",
    this.area = 0.5,
    this.noOverlap = true,
    this.showCritical = false,
    this.showScroll = true,
    this.showFixed = true,
  });
}

class XmlToAssConverter {
  static String _generateHeader(DanmakuOptions options) {
    final alphaHex = ((1 - options.opacity) * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
    final boldVal = options.bold ? "1" : "0";
    
    return """[Script Info]
ScriptType: v4.00+
Collisions: Normal
PlayResX: ${options.resX}
PlayResY: ${options.resY}
Timer: 100.0000

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Roll,${options.fontName},${options.fontSize},&H$alphaHex\FFFFFF,&H00000000,&H00000000,&H00000000,$boldVal,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1
Style: Top,${options.fontName},${options.fontSize},&H$alphaHex\FFFFFF,&H00000000,&H00000000,&H00000000,$boldVal,0,0,0,100,100,0,0,1,2,0,8,20,20,20,1
Style: Bottom,${options.fontName},${options.fontSize},&H$alphaHex\FFFFFF,&H00000000,&H00000000,&H00000000,$boldVal,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""";
  }

  static String _formatTime(double seconds) {
    if (seconds < 0) seconds = 0;
    int h = (seconds / 3600).floor();
    int m = ((seconds % 3600) / 60).floor();
    int s = (seconds % 60).floor();
    int cs = ((seconds * 100) % 100).floor();
    return "$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}";
  }

  static String convert(String xmlContent, {DanmakuOptions? options}) {
    final opt = options ?? DanmakuOptions();
    try {
      final document = XmlDocument.parse(xmlContent);
      final events = <String>[];
      int rollChannelCounter = 0;

      final dNodes = document.findAllElements('d').toList();
      
      // Sort nodes by start time
      dNodes.sort((a, b) {
         final pa = (a.getAttribute('p') ?? "0").split(',');
         final pb = (b.getAttribute('p') ?? "0").split(',');
         return (double.tryParse(pa[0]) ?? 0).compareTo(double.tryParse(pb[0]) ?? 0);
      });

      // Layout parameters
      final double lineSpacing = opt.fontSize * 1.3;
      final int maxChannels = ((opt.resY * opt.area) / lineSpacing).floor().clamp(1, 30);
      
      for (var node in dNodes) {
        final pAttr = node.getAttribute('p');
        final text = node.innerText.trim();
        if (pAttr == null || text.isEmpty) continue;

        final params = pAttr.split(',');
        if (params.length < 4) continue;

        final startSec = double.tryParse(params[0]) ?? 0.0;
        final mode = int.tryParse(params[1]) ?? 1;
        final colorDec = int.tryParse(params[3]) ?? 16777215;

        // Filtering
        if (mode == 1 || mode == 2 || mode == 3) {
          if (!opt.showScroll) continue;
        } else if (mode == 4 || mode == 5) {
          if (!opt.showFixed) continue;
        } else {
          continue; // Filter unknown modes
        }

        // Color
        final blue = colorDec & 0xFF;
        final green = (colorDec >> 8) & 0xFF;
        final red = (colorDec >> 16) & 0xFF;
        final assColor = "&H00${blue.toRadixString(16).padLeft(2, '0').toUpperCase()}${green.toRadixString(16).padLeft(2, '0').toUpperCase()}${red.toRadixString(16).padLeft(2, '0').toUpperCase()}";
        final colorTag = (colorDec != 16777215) ? "{\\c$assColor}" : "";

        double duration = (mode <= 3) ? opt.duration : 4.0;
        final tStart = _formatTime(startSec);
        final tEnd = _formatTime(startSec + duration);

        if (mode <= 3) {
           // Roll
           final channel = rollChannelCounter % maxChannels;
           rollChannelCounter++;
           
           final yPos = (opt.resY * 0.05) + (channel * lineSpacing);
           final xStart = opt.resX + 50;
           // Estimate width: characters * fontSize * modifier
           final textWidth = text.length * opt.fontSize * 0.8;
           final xEnd = -50 - textWidth;

           events.add("Dialogue: 0,$tStart,$tEnd,Roll,,0,0,0,,$colorTag{\\move($xStart,$yPos,$xEnd,$yPos)}$text");
        } else if (mode == 5) {
           events.add("Dialogue: 0,$tStart,$tEnd,Top,,0,0,0,,$colorTag$text");
        } else if (mode == 4) {
           events.add("Dialogue: 0,$tStart,$tEnd,Bottom,,0,0,0,,$colorTag$text");
        }
      }

      return _generateHeader(opt) + events.join('\n');
    } catch (e) {
      print("Error converting danmaku: $e");
      return _generateHeader(opt);
    }
  }
}
