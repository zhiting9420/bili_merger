import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/xml_to_ass.dart';

class SettingsService extends ChangeNotifier {
  static const String _keyParseDanmaku = 'parse_danmaku';
  static const String _keyFontSize = 'font_size';
  static const String _keyDuration = 'duration';
  static const String _keyOpacity = 'opacity';
  static const String _keyBold = 'bold';
  static const String _keyFontName = 'font_name';
  static const String _keyArea = 'area';
  static const String _keySpeed = 'danmaku_speed';
  static const String _keyNoOverlap = 'no_overlap';
  static const String _keyFilter = 'danmaku_filter';
  static const String _keyDedupe = 'danmaku_dedupe';
  static const String _keySeedColor = 'seed_color';

  late SharedPreferences _prefs;
  bool _isInitialized = false;

  // Danmaku Toggle
  bool _parseDanmaku = true;
  bool get parseDanmaku => _parseDanmaku;

  // Theme & Font
  int _seedColorValue = 0xFF4CAF50; // Green
  String _fontName = "微软雅黑";

  // Danmaku Parameters
  // 弹幕坐标系固定 1080P。libass 总会把弹幕按比例缩放到视频实际分辨率,
  // 所以这个值只决定「字号相对画面多大」,不影响清晰度 —— 交给字号一个开关控制即可。
  static const int _kResX = 1920;
  static const int _kResY = 1080;
  int _fontSize = 50;
  double _duration = 10.0;
  double _opacity = 0.8;
  bool _bold = false;
  double _area = 0.5;
  double _speed = 1.25;
  bool _noOverlap = true;
  DanmakuFilter _filter = DanmakuFilter.all;
  bool _dedupe = true;

  SettingsService() {
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _parseDanmaku = _prefs.getBool(_keyParseDanmaku) ?? true;
    _seedColorValue = _prefs.getInt(_keySeedColor) ?? 0xFF4CAF50;
    _fontName = _prefs.getString(_keyFontName) ?? "微软雅黑";
    _fontSize = _prefs.getInt(_keyFontSize) ?? 50;
    _duration = _prefs.getDouble(_keyDuration) ?? 10.0;
    _opacity = _prefs.getDouble(_keyOpacity) ?? 0.8;
    _bold = _prefs.getBool(_keyBold) ?? false;
    _area = _prefs.getDouble(_keyArea) ?? 0.5;
    _speed = _prefs.getDouble(_keySpeed) ?? 1.25;
    _noOverlap = _prefs.getBool(_keyNoOverlap) ?? true;
    _filter =
        DanmakuFilter.values[(_prefs.getInt(_keyFilter) ??
                DanmakuFilter.all.index)
            .clamp(0, DanmakuFilter.values.length - 1)];
    _dedupe = _prefs.getBool(_keyDedupe) ?? true;

    _isInitialized = true;
    notifyListeners();
  }

  // Getters
  int get seedColorValue => _seedColorValue;
  String get fontName => _fontName;
  int get resX => _kResX;
  int get resY => _kResY;
  int get fontSize => _fontSize;
  double get duration => _duration;
  double get opacity => _opacity;
  bool get bold => _bold;
  double get area => _area;
  double get speed => _speed;
  bool get noOverlap => _noOverlap;
  DanmakuFilter get filter => _filter;
  bool get dedupe => _dedupe;
  bool get isInitialized => _isInitialized;

  DanmakuOptions get danmakuOptions => DanmakuOptions(
    resX: _kResX,
    resY: _kResY,
    fontSize: _fontSize,
    duration: _duration / _speed,
    opacity: _opacity,
    bold: _bold,
    fontName: _fontName,
    area: _area,
    noOverlap: _noOverlap,
    filter: _filter,
    dedupe: _dedupe,
  );

  /// 弹幕烧录专用参数。除字体必须换成随应用打包的那一份(内置 ffmpeg 没有
  /// fontconfig,只认 fontsdir 里的这一个家族)之外,其余一律沿用用户设置,
  /// 筛选模式也包括在内 —— 设置里选什么,烧进画面的就是什么。
  DanmakuOptions burnDanmakuOptions(String fontFamily) => DanmakuOptions(
    resX: _kResX,
    resY: _kResY,
    fontSize: _fontSize,
    duration: _duration / _speed,
    opacity: _opacity,
    bold: _bold,
    fontName: fontFamily,
    area: _area,
    noOverlap: _noOverlap,
    filter: _filter,
    dedupe: _dedupe,
  );

  void resetToDefaults() {
    _parseDanmaku = true;
    _seedColorValue = 0xFF4CAF50;
    _fontName = "微软雅黑";
    _fontSize = 50;
    _duration = 10.0;
    _opacity = 0.8;
    _bold = false;
    _area = 0.5;
    _speed = 1.25;
    _noOverlap = true;
    _filter = DanmakuFilter.all;
    _dedupe = true;
    _prefs.clear();
    notifyListeners();
  }

  // Setters
  set seedColorValue(int value) {
    _seedColorValue = value;
    _prefs.setInt(_keySeedColor, value);
    notifyListeners();
  }

  set fontName(String value) {
    _fontName = value;
    _prefs.setString(_keyFontName, value);
    notifyListeners();
  }

  set parseDanmaku(bool value) {
    _parseDanmaku = value;
    _prefs.setBool(_keyParseDanmaku, value);
    notifyListeners();
  }

  set fontSize(int value) {
    _fontSize = value;
    _prefs.setInt(_keyFontSize, value);
    notifyListeners();
  }

  set duration(double value) {
    _duration = value;
    _prefs.setDouble(_keyDuration, value);
    notifyListeners();
  }

  set opacity(double value) {
    _opacity = value;
    _prefs.setDouble(_keyOpacity, value);
    notifyListeners();
  }

  set bold(bool value) {
    _bold = value;
    _prefs.setBool(_keyBold, value);
    notifyListeners();
  }

  set area(double value) {
    _area = value;
    _prefs.setDouble(_keyArea, value);
    notifyListeners();
  }

  set speed(double value) {
    _speed = value;
    _prefs.setDouble(_keySpeed, value);
    notifyListeners();
  }

  set noOverlap(bool value) {
    _noOverlap = value;
    _prefs.setBool(_keyNoOverlap, value);
    notifyListeners();
  }

  set filter(DanmakuFilter value) {
    _filter = value;
    _prefs.setInt(_keyFilter, value.index);
    notifyListeners();
  }

  set dedupe(bool value) {
    _dedupe = value;
    _prefs.setBool(_keyDedupe, value);
    notifyListeners();
  }
}
