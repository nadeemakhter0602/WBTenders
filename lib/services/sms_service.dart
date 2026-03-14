import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/sms_tender.dart';

class SmsService {
  // Matches patterns like: 2026_ZPHD_999969_1
  static final _tenderIdRegex = RegExp(r'\d{4}_[A-Z]+_\d+_\d+');

  // Parses: bid-id :8150437
  static final _bidIdRegex = RegExp(r'bid-id\s*:\s*(\d+)', caseSensitive: false);

  // Parses: has been evaluated / has been opened / has been decrypted ...
  static final _statusRegex = RegExp(r'has been ([^.]+)\.', caseSensitive: false);

  // Keywords that indicate a tender-related SMS
  static const _keywords = [
    'tender',
    'bid',
    'nit',
    'wbtender',
    'e-tender',
    'etender',
    'nicgep',
    'eprocure',
    'nicsi',
  ];

  /// Requests READ_SMS permission and returns whether it was granted.
  Future<bool> requestPermission() async {
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Reads the SMS inbox and returns all tender-related messages,
  /// each as its own entry, ordered by date (newest first).
  Future<List<SmsTender>> getTenderSms() async {
    final granted = await requestPermission();
    if (!granted) {
      throw Exception('SMS permission denied. Please allow it in Settings.');
    }

    final query = SmsQuery();
    final messages = await query.querySms(kinds: [SmsQueryKind.inbox]);

    final results = <SmsTender>[];

    for (final msg in messages) {
      final body = msg.body ?? '';
      final lower = body.toLowerCase();

      // Only process SMS that mention tender-related keywords
      if (!_keywords.any((kw) => lower.contains(kw))) continue;

      final bidId = _bidIdRegex.firstMatch(body)?.group(1);
      final status = _statusRegex.firstMatch(body)?.group(1)?.trim();

      // Use the first tender ID found, or skip if none
      final idMatch = _tenderIdRegex.firstMatch(body);
      if (idMatch == null) continue;

      results.add(SmsTender(
        tenderId: idMatch.group(0)!,
        smsBody: body,
        sender: msg.sender ?? 'Unknown',
        date: msg.date,
        bidId: bidId,
        status: status,
      ));
    }

    results.sort((a, b) {
      if (a.date == null && b.date == null) return 0;
      if (a.date == null) return 1;
      if (b.date == null) return -1;
      return b.date!.compareTo(a.date!);
    });

    return results;
  }
}
