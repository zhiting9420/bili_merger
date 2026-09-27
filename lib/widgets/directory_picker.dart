import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 浏览已获授权的本地目录，不使用限制 Download/存储根目录的 SAF 选择器。
class LocalDirectoryPicker extends StatefulWidget {
  final List<String> roots;
  final String? initialPath;
  final bool writable;
  const LocalDirectoryPicker({
    super.key,
    required this.roots,
    this.initialPath,
    this.writable = false,
  });

  @override
  State<LocalDirectoryPicker> createState() => _LocalDirectoryPickerState();
}

class _LocalDirectoryPickerState extends State<LocalDirectoryPicker> {
  late String _path;
  List<Directory> _directories = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPath;
    _path =
        initial != null &&
            widget.roots.any(
              (root) => p.equals(root, initial) || p.isWithin(root, initial),
            )
        ? initial
        : widget.roots.first;
    _load(_path);
  }

  String get _root => widget.roots.firstWhere(
    (root) => p.equals(root, _path) || p.isWithin(root, _path),
  );

  Future<void> _load(String path) async {
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
      _directories = [];
    });
    try {
      final entries = await Directory(path).list(followLinks: false).toList();
      final directories = entries.whereType<Directory>().toList()
        ..sort(
          (a, b) => p
              .basename(a.path)
              .toLowerCase()
              .compareTo(p.basename(b.path).toLowerCase()),
        );
      if (mounted) setState(() => _directories = directories);
    } on FileSystemException catch (e) {
      if (mounted) {
        setState(
          () => _error =
              '无法读取此文件夹：${e.osError?.message ?? e.message}\nAndroid/data 等受保护位置可能无法访问，请先把缓存复制到 Download 等普通目录。',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select() async {
    setState(() => _loading = true);
    try {
      // 输出目录必须确实可写；只创建并删除本次专用空临时目录。
      if (widget.writable) {
        final probe = await Directory(_path).createTemp('.bilimerger-check-');
        await probe.delete();
      }
      if (mounted) Navigator.pop(context, _path);
    } on FileSystemException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法写入此文件夹：${e.osError?.message ?? e.message}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.writable ? '选择输出文件夹' : '选择缓存文件夹')),
    body: SafeArea(
      child: Column(
        children: [
          if (widget.roots.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButton<String>(
                isExpanded: true,
                value: _root,
                items: widget.roots
                    .map(
                      (root) =>
                          DropdownMenuItem(value: root, child: Text(root)),
                    )
                    .toList(),
                onChanged: _loading
                    ? null
                    : (value) {
                        if (value != null) _load(value);
                      },
              ),
            ),
          ListTile(
            leading: IconButton(
              tooltip: '上一级',
              icon: const Icon(Icons.arrow_upward),
              onPressed: _loading || p.equals(_path, _root)
                  ? null
                  : () => _load(p.dirname(_path)),
            ),
            title: SelectableText(_path),
            trailing: IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _load(_path),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!),
                    ),
                  )
                : _directories.isEmpty
                ? const Center(child: Text('没有子文件夹，可以选择当前文件夹'))
                : ListView.builder(
                    itemCount: _directories.length,
                    itemBuilder: (context, index) {
                      final dir = _directories[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(p.basename(dir.path)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _load(dir.path),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading || _error != null ? null : _select,
                icon: const Icon(Icons.check),
                label: const Text('选择此文件夹'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
