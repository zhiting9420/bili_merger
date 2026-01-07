import 'dart:math';
import 'package:xml/xml.dart';

class DanmakuOptions {
  final int resX;
  final int resY;
  final int fontSize;
  final double duration;
  final double opacity; // 0.0 to 1.0
  final bool bold;
  final String fontName;
  final double area; // 0.0 to 1.0 (screen coverage)

  DanmakuOptions({
    this.resX = 1920,
    this.resY = 1080,
    this.fontSize = 50,
    this.duration = 10.0,
    this.opacity = 0.7,
    this.bold = false,
    this.fontName = "Heiti",
    this.area = 0.5,
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
      int rollChannel = 0;

      final dNodes = document.findAllElements('d');
      
      // Calculate layout parameters
      final int maxChannels = ((opt.resY * opt.area) / (opt.fontSize * 1.2)).floor();
      final double lineSpacing = opt.fontSize * 1.2;

      for (var node in dNodes) {
        final pAttr = node.getAttribute('p');
        final text = node.innerText;

        if (pAttr == null) continue;

        final params = pAttr.split(',');
        if (params.length < 4) continue;

        final startSec = double.tryParse(params[0]) ?? 0.0;
        final mode = int.tryParse(params[1]) ?? 1;
        final colorDec = int.tryParse(params[3]) ?? 16777215;

        // Color conversion Decimal -> ASS Hex (BBGGRR)
        final blue = colorDec & 0xFF;
        final green = (colorDec >> 8) & 0xFF;
        final red = (colorDec >> 16) & 0xFF;
        final assColor = "&H00${blue.toRadixString(16).padLeft(2, '0').toUpperCase()}${green.toRadixString(16).padLeft(2, '0').toUpperCase()}${red.toRadixString(16).padLeft(2, '0').toUpperCase()}";
        
        final colorTag = (colorDec != 16777215) ? "{\\c$assColor}" : "";

        double duration = (mode == 1 || mode == 2 || mode == 3) ? opt.duration : 4.0;
        final endSec = startSec + duration;

        final tStart = _formatTime(startSec);
        final tEnd = _formatTime(endSec);

        String line = "";

        if (mode == 1 || mode == 2 || mode == 3) {
           // Roll
           final yPos = (opt.resY * 0.05) + (rollChannel % maxChannels) * lineSpacing;
           rollChannel++;

           final textLenEst = text.length * opt.fontSize;
           final xStart = opt.resX + 100;
           final xEnd = -100 - textLenEst;
           
           line = "Dialogue: 0,$tStart,$tEnd,Roll,,0,0,0,,$colorTag{\\move($xStart,$yPos,$xEnd,$yPos)}$text";
        } else if (mode == 5) {
          // Top
           line = "Dialogue: 0,$tStart,$tEnd,Top,,0,0,0,,$colorTag$text";
        } else {
          // Bottom (and others fallback)
           line = "Dialogue: 0,$tStart,$tEnd,Bottom,,0,0,0,,$colorTag$text";
        }
        events.add(line);
      }

      return _generateHeader(opt) + events.join('\n');

    } catch (e) {
      print("Error parsing XML: $e");
      return _generateHeader(opt);
    }
  }
}
