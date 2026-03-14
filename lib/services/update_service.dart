import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateService {
  static const _owner = 'nadeemakhter0602';
  static const _repo = 'WBTenders';
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Returns the latest release info if a newer version is available, else null.
  static Future<({String version, String downloadUrl, String releaseUrl})?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _parseVersion(info.version);

      final resp = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').replaceFirst('v', '');
      final latest = _parseVersion(tag);
      if (!_isNewer(latest, current)) return null;

      final assets = json['assets'] as List<dynamic>? ?? [];
      final apk = assets
          .whereType<Map<String, dynamic>>()
          .firstWhere(
            (a) => (a['name'] as String).endsWith('.apk'),
            orElse: () => {},
          );
      final downloadUrl = apk['browser_download_url'] as String? ?? '';
      final releaseUrl = json['html_url'] as String? ?? '';

      return (version: tag, downloadUrl: downloadUrl, releaseUrl: releaseUrl);
    } catch (_) {
      return null;
    }
  }

  /// Downloads the APK with progress and launches the installer.
  static Future<void> downloadAndInstall(
    BuildContext context,
    String downloadUrl,
    String version,
  ) async {
    if (downloadUrl.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final progressNotifier = ValueNotifier<double>(0);
    bool cancelled = false;
    BuildContext? dialogCtx;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return ValueListenableBuilder<double>(
          valueListenable: progressNotifier,
          builder: (_, progress, __) => AlertDialog(
            title: Text('Downloading v$version'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress == 0 ? null : progress),
                const SizedBox(height: 12),
                Text(progress == 0
                    ? 'Starting…'
                    : '${(progress * 100).toStringAsFixed(0)}%'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.pop(ctx);
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );

    void closeDialog() {
      if (dialogCtx != null && dialogCtx!.mounted) {
        Navigator.of(dialogCtx!).pop();
      }
    }

    try {
      final tmpDir = await getTemporaryDirectory();
      final file = File('${tmpDir.path}/wbtenders-v$version.apk');

      final req = http.Request('GET', Uri.parse(downloadUrl));
      final resp = await req.send();
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = file.openWrite();

      await for (final chunk in resp.stream) {
        if (cancelled) {
          await sink.close();
          await file.delete();
          progressNotifier.dispose();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progressNotifier.value = received / total;
      }
      await sink.close();
      progressNotifier.dispose();

      if (cancelled) return;
      closeDialog();

      const channel = MethodChannel('wbtenders/install');
      final result = await OpenFile.open(file.path);
      if (result.type == ResultType.permissionDenied) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Permission needed to install updates'),
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Allow',
              onPressed: () => channel.invokeMethod<void>('openInstallSettings'),
            ),
          ),
        );
      } else if (result.type != ResultType.done) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not open installer: ${result.message}')),
        );
      }
    } catch (e) {
      progressNotifier.dispose();
      closeDialog();
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  static List<int> _parseVersion(String v) {
    return v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  }

  static bool _isNewer(List<int> latest, List<int> current) {
    for (var i = 0; i < 3; i++) {
      final l = i < latest.length ? latest[i] : 0;
      final c = i < current.length ? current[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
