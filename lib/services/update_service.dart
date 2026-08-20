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
      final req = await client.getUrl(
        Uri.parse("https://api.github.com/repos/$repo/releases/latest"),
      );
      // GitHub API 要求带 User-Agent，否则返回 403
      req.headers.set(HttpHeaders.userAgentHeader, "BiliMerger-UpdateChecker");
      req.headers.set(HttpHeaders.acceptHeader, "application/vnd.github+json");
      final resp = await req.close().timeout(const Duration(seconds: 15));
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
    } catch (_) {
      return UpdateResult.failed;
    } finally {
      client.close();
    }
  }

  /// 语义化版本比较:latest 是否比 current 新。
  static bool _isNewer(String latest, String current) {
    List<int> parse(String v) => v
        .split('.')
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final a = parse(latest);
    final b = parse(current);
    final n = a.length > b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
