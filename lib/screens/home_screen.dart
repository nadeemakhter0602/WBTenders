import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/sms_tender.dart';
import '../services/sms_service.dart';
import '../services/update_service.dart';
import 'tender_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _smsService = SmsService();

  bool _loading = false;
  String? _error;
  List<SmsTender> _tenders = [];
  ({String version, String downloadUrl, String releaseUrl})? _update;
  bool _checkingUpdate = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _load();
    _checkUpdate();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  Future<void> _checkUpdate() async {
    final update = await UpdateService.checkForUpdate();
    if (update != null && mounted) setState(() => _update = update);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tenders = await _smsService.getTenderSms();
      if (!mounted) return;
      setState(() {
        _tenders = tenders;
        if (tenders.isEmpty) _error = 'No tender SMS found in your inbox.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WBTenders'),
        centerTitle: true,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'check_update') {
                final messenger = ScaffoldMessenger.of(context);
                setState(() => _checkingUpdate = true);
                final update = await UpdateService.checkForUpdate();
                if (!mounted) return;
                setState(() {
                  _checkingUpdate = false;
                  if (update != null) _update = update;
                });
                if (update == null) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Already up to date')),
                  );
                }
              } else if (value == 'about') {
                showAboutDialog(
                  context: context,
                  applicationName: 'WBTenders',
                  applicationVersion: _appVersion,
                  applicationIcon: const Icon(Icons.gavel, size: 48, color: Colors.indigo),
                  children: [
                    const Text(
                      'Android app for tracking West Bengal eProcurement tender statuses from wbtenders.gov.in.',
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () => launchUrl(
                        Uri.parse('https://github.com/nadeemakhter0602/WBTenders'),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text(
                        'github.com/nadeemakhter0602/WBTenders',
                        style: TextStyle(
                          color: Colors.indigo,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.indigo,
                        ),
                      ),
                    ),
                  ],
                );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'check_update',
                child: Row(
                  children: [
                    _checkingUpdate
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigo),
                          )
                        : const Icon(Icons.system_update_outlined, size: 20),
                    const SizedBox(width: 12),
                    const Text('Check for Updates'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 20),
                    SizedBox(width: 12),
                    Text('About'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_update != null)
              _UpdateBanner(
                update: _update!,
                onDismiss: () => setState(() => _update = null),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Reading SMS inbox…'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sms_failed_outlined, size: 52, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _tenders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _SmsCard(
          tender: _tenders[i],
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TenderDetailScreen(sms: _tenders[i]),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Chip widgets ──────────────────────────────────────────────────────────────

class _TenderIdChip extends StatelessWidget {
  final String tenderId;
  const _TenderIdChip({required this.tenderId});

  @override
  Widget build(BuildContext context) {
    return _InfoChip(
      icon: Icons.confirmation_number_outlined,
      label: tenderId,
      color: Colors.indigo,
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final MaterialColor color;
  const _InfoChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color.shade700)),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final lower = status.toLowerCase();
    final (color, icon) = lower.contains('evaluat')
        ? (Colors.orange, Icons.assessment_outlined)
        : lower.contains('decrypt')
            ? (Colors.purple, Icons.lock_open_outlined)
            : lower.contains('open')
                ? (Colors.blue, Icons.folder_open_outlined)
                : (Colors.grey, Icons.info_outline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            _capitalise(status),
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _SmsCard extends StatelessWidget {
  final SmsTender tender;
  final VoidCallback onTap;

  const _SmsCard({required this.tender, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final date = tender.date;
    final dateStr = date != null
        ? '${date.day.toString().padLeft(2, '0')}/'
            '${date.month.toString().padLeft(2, '0')}/'
            '${date.year}'
        : '';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sms_outlined, size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(tender.sender,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey)),
                  const Spacer(),
                  if (dateStr.isNotEmpty)
                    Text(dateStr,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tender.smsBody,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _TenderIdChip(tenderId: tender.tenderId),
                  if (tender.bidId != null)
                    _InfoChip(
                      icon: Icons.how_to_vote_outlined,
                      label: 'Bid ${tender.bidId}',
                      color: Colors.teal,
                    ),
                  if (tender.status != null)
                    _StatusChip(status: tender.status!),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  final ({String version, String downloadUrl, String releaseUrl}) update;
  final VoidCallback onDismiss;

  const _UpdateBanner({required this.update, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      backgroundColor: Colors.indigo.withValues(alpha: 0.08),
      leading: const Icon(Icons.system_update_outlined, color: Colors.indigo),
      content: Text(
        'v${update.version} available',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: [
        TextButton(
          onPressed: onDismiss,
          child: const Text('Later'),
        ),
        if (update.releaseUrl.isNotEmpty)
          TextButton(
            onPressed: () {
              onDismiss();
              launchUrl(Uri.parse(update.releaseUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('GitHub'),
          ),
        if (update.downloadUrl.isNotEmpty)
          TextButton(
            onPressed: () {
              onDismiss();
              UpdateService.downloadAndInstall(context, update.downloadUrl, update.version);
            },
            child: const Text('Update'),
          )
        else
          TextButton(
            onPressed: () {
              onDismiss();
              launchUrl(Uri.parse(update.releaseUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('View release'),
          ),
      ],
    );
  }
}
