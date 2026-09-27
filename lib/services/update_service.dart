import 'dart:convert';
import 'dart:io';

/// 检查更新的结果。
class UpdateResult {
  final bool ok; // 请求是否成功(网络/接口正常)
  final bool hasUpdate; // 是否有比当前更新的版本
  final String latestVersion; // 最新版本号(去掉了前缀 v)
  final String notes; // 更新说明(release body)
  final String pageUrl; // Release 网页地址
  final String? apkUrl; // 直接下载的 apk 资源地址(可能为空)

  const UpdateResult({
    required this.ok,
    required this.hasUpdate,
    this.latestVersion = "",
    this.notes = "",
    this.pageUrl = "",
    this.apkUrl,
  });

  static const UpdateResult failed = UpdateResult(ok: false, hasUpdate: false);
}

class UpdateService {
  /// 查询 GitHub 仓库的最新 Release，并与当前版本比较。
  static Future<UpdateResult> check(String repo, String currentVersion) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      return await _fetch(
        client,
        repo,
        currentVersion,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      return UpdateResult.failed;
    } finally {
      // timeout 不会取消原 Future，必须连同未读完的响应一起关闭。
      client.close(force: true);
    }
  }

  static Future<UpdateResult> _fetch(
    HttpClient client,
    String repo,
    String currentVersion,
  ) async {
    final req = await client.getUrl(
      Uri.parse("https://api.github.com/repos/$repo/releases/latest"),
    );
    // GitHub API 要求带 User-Agent，否则返回 403
    req.headers.set(HttpHeaders.userAgentHeader, "BiliMerger-UpdateChecker");
    req.headers.set(HttpHeaders.acceptHeader, "application/vnd.github+json");
    final resp = await req.close();
    if (resp.statusCode != 200) return UpdateResult.failed;

    final body = await resp.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    final tag = (json['tag_name'] as String?)?.trim() ?? "";
    final latest = tag.replaceAll(RegExp(r'^[vV]'), '');
    final notes = (json['body'] as String?)?.trim() ?? "";
    final pageUrl =
        (json['html_url'] as String?) ?? "https://github.com/$repo/releases";

    String? apkUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final a in assets) {
        final name = (a is Map ? a['name'] as String? : null) ?? "";
        if (name.toLowerCase().endsWith('.apk')) {
          apkUrl = a['browser_download_url'] as String?;
          break;
        }
      }
    }

    return UpdateResult(
      ok: true,
      hasUpdate: _isNewer(latest, currentVersion),
      latestVersion: latest,
      notes: notes,
      pageUrl: pageUrl,
      apkUrl: apkUrl,
    );
  }

  /// 语义化版本比较:latest 是否比 current 新。
  static bool _isNewer(String latest, String current) {
    final a = _parseVersion(latest);
    final b = _parseVersion(current);
    for (var i = 0; i < 3; i++) {
      final order = _compareNumber(a.$1[i], b.$1[i]);
      if (order != 0) return order > 0;
    }
    final preA = a.$2;
    final preB = b.$2;
    if (preA.isEmpty || preB.isEmpty) {
      return preA.isEmpty && preB.isNotEmpty;
    }
    for (var i = 0; i < preA.length && i < preB.length; i++) {
      final x = preA[i];
      final y = preB[i];
      final numericX = _digits.hasMatch(x);
      final numericY = _digits.hasMatch(y);
      final int order;
      if (numericX && numericY) {
        order = _compareNumber(x, y);
      } else if (numericX != numericY) {
        order = numericX ? -1 : 1;
      } else {
        order = x.compareTo(y);
      }
      if (order != 0) return order > 0;
    }
    return preA.length > preB.length;
  }

  static final _digits = RegExp(r'^[0-9]+$');
  static final _version = RegExp(
    r'^[vV]?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  static (List<String>, List<String>) _parseVersion(String value) {
    final match = _version.firstMatch(value.trim());
    if (match == null) throw FormatException('Invalid version', value);
    final pre = match.group(4)?.split('.') ?? <String>[];
    if (pre.any(
      (part) =>
          _digits.hasMatch(part) && part.length > 1 && part.startsWith('0'),
    )) {
      throw FormatException('Invalid prerelease version', value);
    }
    return ([match[1]!, match[2]!, match[3]!], pre);
  }

  // 数字字符串已无前导零；按长度比较可避免超长版本号溢出。
  static int _compareNumber(String a, String b) =>
      a.length == b.length ? a.compareTo(b) : a.length.compareTo(b.length);
}
