import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/sms_tender.dart';
import '../models/summary_section.dart';
import '../models/tender_result.dart';
import '../services/captcha_service.dart';
import '../services/tender_service.dart';

const _maxAutoRetries = 10;

class TenderDetailScreen extends StatefulWidget {
  final SmsTender sms;

  const TenderDetailScreen({super.key, required this.sms});

  @override
  State<TenderDetailScreen> createState() => _TenderDetailScreenState();
}

class _TenderDetailScreenState extends State<TenderDetailScreen> {
  final _service = TenderService();
  final _captchaController = TextEditingController();

  _Phase _phase = const _PhaseAutoRetry(attempt: 0);

  @override
  void initState() {
    super.initState();
    _autoRetry(0);
  }

  @override
  void dispose() {
    _captchaController.dispose();
    super.dispose();
  }

  // ── Auto-retry loop ────────────────────────────────────────────────────────

  Future<void> _autoRetry(int attempt) async {
    if (!mounted) return;
    setState(() => _phase = _PhaseAutoRetry(attempt: attempt));

    try {
      final captchaBytes = await _service.beginSession();
      final captchaText = await CaptchaService.solve(captchaBytes);

      if (captchaText.length < 4 || captchaText.length > 9) {
        if (attempt + 1 < _maxAutoRetries) return _autoRetry(attempt + 1);
        return _showManualCaptcha();
      }

      final results =
          await _service.submitSearch(widget.sms.tenderId, captchaText);

      if (results.isEmpty) {
        if (mounted) setState(() => _phase = const _PhaseDone(sections: [], boqSheets: [], result: null));
        return;
      }

      final result = results.first;
      final viewUrl = result.links['View Tender Status'];
      if (viewUrl == null) {
        if (mounted) setState(() => _phase = _PhaseDone(sections: const [], boqSheets: const [], result: result));
        return;
      }

      if (mounted) setState(() => _phase = const _PhaseLoading());
      final summary = await _service.fetchFullSummary(viewUrl);
      if (mounted) setState(() => _phase = _PhaseDone(sections: summary.sections, boqSheets: summary.boqSheets, result: result));
    } on CaptchaRejectedError {
      if (attempt + 1 < _maxAutoRetries) {
        _autoRetry(attempt + 1);
      } else {
        _showManualCaptcha();
      }
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(message: e.toString()));
    }
  }

  Future<void> _showManualCaptcha() async {
    if (!mounted) return;
    try {
      final bytes = await _service.beginSession();
      setState(() => _phase = _PhaseManualInput(captchaBytes: bytes));
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(message: e.toString()));
    }
  }

  Future<void> _submitManual() async {
    final text = _captchaController.text.trim();
    if (text.isEmpty) return;
    if (!mounted) return;
    setState(() => _phase = const _PhaseLoading());
    try {
      final results = await _service.submitSearch(widget.sms.tenderId, text);

      if (results.isEmpty) {
        if (mounted) setState(() => _phase = const _PhaseDone(sections: [], boqSheets: [], result: null));
        return;
      }

      final result = results.first;
      final viewUrl = result.links['View Tender Status'];
      if (viewUrl == null) {
        if (mounted) setState(() => _phase = _PhaseDone(sections: const [], boqSheets: const [], result: result));
        return;
      }

      final summary = await _service.fetchFullSummary(viewUrl);
      if (mounted) setState(() => _phase = _PhaseDone(sections: summary.sections, boqSheets: summary.boqSheets, result: result));
    } on CaptchaRejectedError {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wrong captcha — please try again.')),
      );
      _captchaController.clear();
      _showManualCaptcha();
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(message: e.toString()));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sms.tenderId,
            style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          if (_phase is _PhaseDone || _phase is _PhaseError)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _autoRetry(0),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SmsSnippet(sms: widget.sms),
              const SizedBox(height: 16),
              _buildPhaseWidget(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseWidget() {
    final p = _phase;

    if (p is _PhaseAutoRetry) {
      return _StatusBox(
        icon: const CircularProgressIndicator(strokeWidth: 2),
        text: 'Auto-solving captcha… (attempt ${p.attempt + 1}/$_maxAutoRetries)',
      );
    }

    if (p is _PhaseLoading) {
      return const _StatusBox(
        icon: CircularProgressIndicator(strokeWidth: 2),
        text: 'Fetching tender details…',
      );
    }

    if (p is _PhaseManualInput) {
      return _ManualCaptchaCard(
        captchaBytes: p.captchaBytes,
        controller: _captchaController,
        onSubmit: _submitManual,
      );
    }

    if (p is _PhaseError) {
      return _ErrorBox(message: p.message, onRetry: () => _autoRetry(0));
    }

    if (p is _PhaseDone) {
      final hasResult = p.result != null && p.result!.allFields.isNotEmpty;
      final hasSections = p.sections.isNotEmpty;
      final hasBoq = p.boqSheets.isNotEmpty;

      if (!hasResult && !hasSections && !hasBoq) {
        return const _StatusBox(
          icon: Icon(Icons.search_off, size: 40, color: Colors.grey),
          text: 'No tender details found.',
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasResult) ...[
            _ResultFieldsCard(result: p.result!),
            const SizedBox(height: 12),
          ],
          ...p.sections.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SummarySectionCard(section: s),
              )),
          if (hasBoq) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.table_chart_outlined,
                    size: 16, color: Colors.teal),
                const SizedBox(width: 6),
                Text(
                  'BOQ Comparative Chart',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal.shade700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...p.boqSheets.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SummarySectionCard(
                      section: s, headerColor: Colors.teal),
                )),
          ],
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

// ── Phase classes ─────────────────────────────────────────────────────────────

sealed class _Phase {
  const _Phase();
}

class _PhaseAutoRetry extends _Phase {
  final int attempt;
  const _PhaseAutoRetry({required this.attempt});
}

class _PhaseLoading extends _Phase {
  const _PhaseLoading();
}

class _PhaseManualInput extends _Phase {
  final Uint8List captchaBytes;
  const _PhaseManualInput({required this.captchaBytes});
}

class _PhaseDone extends _Phase {
  final List<SummarySection> sections;
  final List<SummarySection> boqSheets;
  final TenderResult? result;
  const _PhaseDone(
      {required this.sections,
      required this.boqSheets,
      required this.result});
}

class _PhaseError extends _Phase {
  final String message;
  const _PhaseError({required this.message});
}

// ── Manual captcha card ───────────────────────────────────────────────────────

class _ManualCaptchaCard extends StatelessWidget {
  final Uint8List captchaBytes;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  const _ManualCaptchaCard({
    required this.captchaBytes,
    required this.controller,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Auto-solve failed. Please enter the captcha:',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.all(8),
                child: Image.memory(
                  captchaBytes,
                  scale: 0.5,
                  filterQuality: FilterQuality.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: 'Captcha text',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: controller.clear,
                ),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onSubmit,
              child: const Text('Search'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status / error boxes ──────────────────────────────────────────────────────

class _StatusBox extends StatelessWidget {
  final Widget icon;
  final String text;
  const _StatusBox({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(height: 14),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 52, color: Colors.red),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ── SMS snippet ───────────────────────────────────────────────────────────────

class _SmsSnippet extends StatelessWidget {
  final SmsTender sms;
  const _SmsSnippet({required this.sms});

  @override
  Widget build(BuildContext context) {
    final date = sms.date;
    final dateStr = date != null
        ? '${date.day.toString().padLeft(2, '0')}/'
            '${date.month.toString().padLeft(2, '0')}/'
            '${date.year}'
        : '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sms_outlined, size: 14, color: Colors.grey),
              const SizedBox(width: 5),
              Text(sms.sender,
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
          const SizedBox(height: 6),
          Text(sms.smsBody,
              style:
                  const TextStyle(fontSize: 13, color: Colors.black87)),
        ],
      ),
    );
  }
}

// ── Result fields card ────────────────────────────────────────────────────────

class _ResultFieldsCard extends StatelessWidget {
  final TenderResult result;
  const _ResultFieldsCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Colors.indigo,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: const Text(
              'Search Result',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: result.allFields.map((e) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(e.key,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.indigo)),
                      ),
                      Expanded(
                        child: Text(e.value,
                            style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Summary section card ──────────────────────────────────────────────────────

class _SummarySectionCard extends StatelessWidget {
  final SummarySection section;
  final Color headerColor;
  const _SummarySectionCard(
      {required this.section, this.headerColor = Colors.indigo});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (section.title.isNotEmpty)
            Container(
              color: headerColor,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                section.title,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: section.isKeyValue
                ? _buildKeyValue()
                : section.isKeyValueLike
                    ? _buildKeyValueLike()
                    : _buildTable(),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyValue() {
    return Column(
      children: section.rows.map((row) {
        final label = row[0];
        final value = row.length > 1 ? row[1] : '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: headerColor)),
              ),
              Expanded(
                child: Text(value,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _kvRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: headerColor)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child:
                  Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _buildKeyValueLike() {
    final widgets = <Widget>[];
    for (final row in section.rows) {
      if (row.length == 4) {
        if (row[0].isNotEmpty || row[1].isNotEmpty) widgets.add(_kvRow(row[0], row[1]));
        if (row[2].isNotEmpty || row[3].isNotEmpty) widgets.add(_kvRow(row[2], row[3]));
      } else if (row.length == 2) {
        widgets.add(_kvRow(row[0], row[1]));
      } else if (row.length == 1 && row[0].isNotEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(row[0],
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: headerColor.withValues(alpha: 0.6))),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
  }

  Widget _cellWidget(String text, String? url) {
    if (url != null && url.isNotEmpty) {
      return GestureDetector(
        onTap: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                color: Colors.teal,
                decoration: TextDecoration.underline)),
      );
    }
    return Text(text,
        style: TextStyle(fontSize: 12, color: _cellColor(text)));
  }

  Widget _buildTable() {
    final headers = section.headers;
    final dataRows = section.dataRows;
    final dataRowLinks = section.dataRowLinks;
    if (headers.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: Colors.grey.shade200, width: 1),
        children: [
          // Header row
          TableRow(
            decoration: BoxDecoration(color: headerColor.withValues(alpha: 0.08)),
            children: headers
                .map((h) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      child: Text(h,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: headerColor)),
                    ))
                .toList(),
          ),
          // Data rows
          ...List.generate(dataRows.length, (ri) {
            final row = dataRows[ri];
            final links = ri < dataRowLinks.length ? dataRowLinks[ri] : <String?>[];
            final padded = List.generate(
                headers.length,
                (i) => i < row.length ? row[i] : '');
            return TableRow(
              children: List.generate(padded.length, (ci) {
                final url = ci < links.length ? links[ci] : null;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: _cellWidget(padded[ci], url),
                );
              }),
            );
          }),
        ],
      ),
    );
  }

  /// Colour-codes status/rank values for quick scanning.
  Color _cellColor(String text) {
    final t = text.toLowerCase();
    if (t.contains('reject')) return Colors.red.shade700;
    if (t.contains('accept') || t.contains('lowest')) return Colors.green.shade700;
    if (t == 'l1') return Colors.green.shade700;
    if (t == 'l2' || t == 'l3') return Colors.orange.shade700;
    return Colors.black87;
  }
}
