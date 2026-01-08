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
  static const String _keySpeed = 'danmaku_speed';
  static const String _keyNoOverlap = 'no_overlap';
  static const String _keyShowCritical = 'show_critical';
  static const String _keyShowScroll = 'show_scroll';
  static const String _keyShowFixed = 'show_fixed';
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
  int _resX = 1920;
  int _resY = 1080;
  int _fontSize = 50;
  double _duration = 10.0;
  double _opacity = 0.7;
  bool _bold = false;
  double _area = 0.5;
  double _speed = 1.0; 
  bool _noOverlap = true;
  bool _showCritical = false;
  bool _showScroll = true;
  bool _showFixed = true;

  SettingsService() {
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _parseDanmaku = _prefs.getBool(_keyParseDanmaku) ?? true;
    _seedColorValue = _prefs.getInt(_keySeedColor) ?? 0xFF4CAF50;
    _fontName = _prefs.getString(_keyFontName) ?? "微软雅黑";
    _resX = _prefs.getInt(_keyResX) ?? 1920;
    _resY = _prefs.getInt(_keyResY) ?? 1080;
    _fontSize = _prefs.getInt(_keyFontSize) ?? 50;
    _duration = _prefs.getDouble(_keyDuration) ?? 10.0;
    _opacity = _prefs.getDouble(_keyOpacity) ?? 0.7;
    _bold = _prefs.getBool(_keyBold) ?? false;
    _area = _prefs.getDouble(_keyArea) ?? 0.5;
    _speed = _prefs.getDouble(_keySpeed) ?? 1.0;
    _noOverlap = _prefs.getBool(_keyNoOverlap) ?? true;
    _showCritical = _prefs.getBool(_keyShowCritical) ?? false;
    _showScroll = _prefs.getBool(_keyShowScroll) ?? true;
    _showFixed = _prefs.getBool(_keyShowFixed) ?? true;
    
    _isInitialized = true;
    notifyListeners();
  }

  // Getters
  int get seedColorValue => _seedColorValue;
  String get fontName => _fontName;
  int get resX => _resX;
  int get resY => _resY;
  int get fontSize => _fontSize;
  double get duration => _duration;
  double get opacity => _opacity;
  bool get bold => _bold;
  double get area => _area;
  double get speed => _speed;
  bool get noOverlap => _noOverlap;
  bool get showCritical => _showCritical;
  bool get showScroll => _showScroll;
  bool get showFixed => _showFixed;
  bool get isInitialized => _isInitialized;

  DanmakuOptions get danmakuOptions => DanmakuOptions(
    resX: _resX,
    resY: _resY,
    fontSize: _fontSize,
    duration: _duration / _speed,
    opacity: _opacity,
    bold: _bold,
    fontName: _fontName,
    area: _area,
    noOverlap: _noOverlap,
    showCritical: _showCritical,
    showScroll: _showScroll,
    showFixed: _showFixed,
  );

  void resetToDefaults() {
    _parseDanmaku = true;
    _seedColorValue = 0xFF4CAF50;
    _fontName = "微软雅黑";
    _resX = 1920;
    _resY = 1080;
    _fontSize = 50;
    _duration = 10.0;
    _opacity = 0.7;
    _bold = false;
    _area = 0.5;
    _speed = 1.0;
    _noOverlap = true;
    _showCritical = false;
    _showScroll = true;
    _showFixed = true;
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

  set noOverlap(bool value) {
    _noOverlap = value;
    _prefs.setBool(_keyNoOverlap, value);
    notifyListeners();
  }

  set showCritical(bool value) {
    _showCritical = value;
    _prefs.setBool(_keyShowCritical, value);
    notifyListeners();
  }

  set showScroll(bool value) {
    _showScroll = value;
    _prefs.setBool(_keyShowScroll, value);
    notifyListeners();
  }

  set showFixed(bool value) {
    _showFixed = value;
    _prefs.setBool(_keyShowFixed, value);
    notifyListeners();
  }
}
