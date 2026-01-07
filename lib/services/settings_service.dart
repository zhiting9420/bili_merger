import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/xml_to_ass.dart';

class SettingsService extends ChangeNotifier {
  static const String _keyParseDanmaku = 'parse_danmaku';
  static const String _keyResX = 'res_x';
  static const String _keyResY = 'res_y';
  static const String _keyFontSize = 'font_size';
  static const String _keyDuration = 'duration';
  static const String _keyOpacity = 'opacity';
  static const String _keyBold = 'bold';
  static const String _keyFontName = 'font_name';
  static const String _keyArea = 'area';

  late SharedPreferences _prefs;
  bool _isInitialized = false;

  // Danmaku Toggle
  bool _parseDanmaku = true;
  bool get parseDanmaku => _parseDanmaku;

  // Danmaku Parameters
  int _resX = 1280;
  int _resY = 720;
  int _fontSize = 36;
  double _duration = 10.0;
  double _opacity = 0.7;
  bool _bold = false;
  String _fontName = "黑体";
  double _area = 0.5;

  SettingsService() {
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _parseDanmaku = _prefs.getBool(_keyParseDanmaku) ?? true;
    _resX = _prefs.getInt(_keyResX) ?? 1280;
    _resY = _prefs.getInt(_keyResY) ?? 1080;
    _fontSize = _prefs.getInt(_keyFontSize) ?? 36;
    _duration = _prefs.getDouble(_keyDuration) ?? 10.0;
    _opacity = _prefs.getDouble(_keyOpacity) ?? 0.7;
    _bold = _prefs.getBool(_keyBold) ?? false;
    _fontName = _prefs.getString(_keyFontName) ?? "黑体";
    _area = _prefs.getDouble(_keyArea) ?? 0.5;
    
    _isInitialized = true;
    notifyListeners();
  }

  // Getters
  int get resX => _resX;
  int get resY => _resY;
  int get fontSize => _fontSize;
  double get duration => _duration;
  double get opacity => _opacity;
  bool get bold => _bold;
  String get fontName => _fontName;
  double get area => _area;
  bool get isInitialized => _isInitialized;

  DanmakuOptions get danmakuOptions => DanmakuOptions(
    resX: _resX,
    resY: _resY,
    fontSize: _fontSize,
    duration: _duration,
    opacity: _opacity,
    bold: _bold,
    fontName: _fontName,
    area: _area,
  );

  // Setters
  set parseDanmaku(bool value) {
    _parseDanmaku = value;
    _prefs.setBool(_keyParseDanmaku, value);
    notifyListeners();
  }

  set resX(int value) {
    _resX = value;
    _prefs.setInt(_keyResX, value);
    notifyListeners();
  }

  set resY(int value) {
    _resY = value;
    _prefs.setInt(_keyResY, value);
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

  set fontName(String value) {
    _fontName = value;
    _prefs.setString(_keyFontName, value);
    notifyListeners();
  }

  set area(double value) {
    _area = value;
    _prefs.setDouble(_keyArea, value);
    notifyListeners();
  }
}
