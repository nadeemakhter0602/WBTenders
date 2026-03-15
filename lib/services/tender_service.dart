import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:excel/excel.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import '../models/summary_section.dart';
import '../models/tender_result.dart';

/// Thrown when the server rejects the submitted captcha.
class CaptchaRejectedError implements Exception {
  const CaptchaRejectedError();
}

/// Holds a live HTTP session (cookies + Tapestry hidden fields).
/// Call [beginSession] to start, then [submitSearch] to query.
class TenderService {
  static const _baseUrl = 'https://wbtenders.gov.in/nicgep/app';
  static const _pageUrl =
      '$_baseUrl?page=WebTenderStatusLists&service=page';

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://wbtenders.gov.in/',
    'Origin': 'https://wbtenders.gov.in',
  };

  late Dio _dio;
  late CookieJar _cookieJar;
  Map<String, String> _hiddenFields = {};

  TenderService() {
    _initDio();
  }

  void _initDio() {
    _cookieJar = CookieJar();
    _dio = Dio(BaseOptions(
      headers: _headers,
      followRedirects: true,
      validateStatus: (s) => s != null && s < 500,
    ))
      ..interceptors.add(CookieManager(_cookieJar));
  }

  /// GETs the search page with a fresh session.
  /// Returns the captcha image bytes to display or OCR.
  Future<Uint8List> beginSession() async {
    _initDio(); // fresh cookies each time
    final resp = await _dio.get(_pageUrl);
    if (resp.statusCode != 200) {
      throw Exception('Page load failed: ${resp.statusCode}');
    }
    final document = html_parser.parse(resp.data as String);
    _hiddenFields = _extractHiddenFields(document);
    return _extractCaptchaBytes(document);
  }

  /// POSTs the search form using the current session's hidden fields.
  /// Throws [CaptchaRejectedError] if the server rejects the captcha.
  /// Returns an empty list if the captcha was accepted but no results found.
  Future<List<TenderResult>> submitSearch(
      String tenderId, String captchaText) async {
    final payload = _buildPayload(_hiddenFields, tenderId, captchaText);
    final resp = await _dio.post(
      _baseUrl,
      data: payload,
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: {
          'Referer': _pageUrl,
          'Sec-Fetch-Dest': 'document',
          'Sec-Fetch-Mode': 'navigate',
          'Sec-Fetch-Site': 'same-origin',
        },
      ),
    );

    if (resp.statusCode != 200) {
      throw Exception('Search failed: ${resp.statusCode}');
    }

    final doc = html_parser.parse(resp.data as String);

    if (_isCaptchaRejected(doc)) throw const CaptchaRejectedError();

    return _parseResultTable(doc);
  }

  /// Full chain: GET detail page → find stage summary link → GET summary page → parse.
  /// Also fetches the BOQ Comparative Chart xlsx if present on the summary page.
  /// [viewUrl] is the href from the search result's "View Tender Status" anchor.
  Future<({List<SummarySection> sections, List<SummarySection> boqSheets})>
      fetchFullSummary(String viewUrl) async {
    // Step 1: detail page
    final detailResp = await _dio.get(
      viewUrl,
      options: Options(headers: {'Referer': _baseUrl}),
    );
    if (detailResp.statusCode != 200) {
      throw Exception('Detail page failed: ${detailResp.statusCode}');
    }
    final detailDoc = html_parser.parse(detailResp.data as String);

    // Step 2: find the "all stage summary" link (id="DirectLink_0")
    final summaryAnchor = detailDoc.querySelector('a#DirectLink_0');
    if (summaryAnchor == null) {
      throw Exception('Stage summary link not found on detail page.');
    }
    String summaryHref = summaryAnchor.attributes['href'] ?? '';
    if (summaryHref.isEmpty) {
      throw Exception('Stage summary link has no href.');
    }
    if (!summaryHref.startsWith('http')) {
      summaryHref = 'https://wbtenders.gov.in$summaryHref';
    }

    // Step 3: summary page
    final summaryResp = await _dio.get(
      summaryHref,
      options: Options(headers: {'Referer': viewUrl}),
    );
    if (summaryResp.statusCode != 200) {
      throw Exception('Summary page failed: ${summaryResp.statusCode}');
    }
    final summaryDoc = html_parser.parse(summaryResp.data as String);
    final sections = _parseSummaryPage(summaryDoc);

    // Step 4: BOQ comparative chart (xlsx download)
    final boqSheets = await _fetchBoqSheets(summaryDoc, summaryHref);

    return (sections: sections, boqSheets: boqSheets);
  }

  Future<List<SummarySection>> _fetchBoqSheets(
      dom.Document summaryDoc, String referer) async {
    dom.Element? boqAnchor;
    for (final a in summaryDoc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      final text = a.text.trim().toLowerCase();
      if (href.contains('component=BOQ') ||
          text.contains('boq') ||
          text.contains('comparative')) {
        boqAnchor = a;
        break;
      }
    }
    if (boqAnchor == null) return [];

    String boqHref = boqAnchor.attributes['href'] ?? '';
    if (boqHref.isEmpty) return [];
    if (!boqHref.startsWith('http')) {
      boqHref = 'https://wbtenders.gov.in$boqHref';
    }

    try {
      final resp = await _dio.get<List<int>>(
        boqHref,
        options: Options(
          headers: {'Referer': referer},
          responseType: ResponseType.bytes,
        ),
      );
      if (resp.statusCode != 200 || resp.data == null) return [];
      // Verify it's a ZIP/xlsx (PK magic bytes)
      final data = resp.data!;
      if (data.length < 2 || data[0] != 0x50 || data[1] != 0x4B) return [];
      return _parseBoqExcel(data);
    } catch (_) {
      return [];
    }
  }

  List<SummarySection> _parseBoqExcel(List<int> bytes) {
    final workbook = Excel.decodeBytes(bytes);
    final sections = <SummarySection>[];

    for (final sheetName in workbook.tables.keys) {
      final sheet = workbook.tables[sheetName]!;

      // Read all non-empty rows as trimmed string lists
      final allRows = <List<String>>[];
      for (final row in sheet.rows) {
        final cells = row.map(_xlCellStr).toList();
        while (cells.isNotEmpty && cells.last.isEmpty) cells.removeLast();
        if (cells.every((c) => c.isEmpty)) continue;
        allRows.add(cells);
      }
      if (allRows.isEmpty) continue;

      final nameLower = sheetName.toLowerCase();
      if (nameLower.contains('summary')) continue;
      final section = _parseBoqBidSheet('BOQ Comparative Chart', allRows);
      if (section != null) sections.add(section);
    }

    return sections;
  }

  /// Parses a BoQ finance bid sheet (e.g. "BoQ1") into a clean table:
  /// columns → [#, Bidder, Quoted %, Amount]
  SummarySection? _parseBoqBidSheet(String name, List<List<String>> allRows) {
    // Find header row: contains both "sl" and "bidder"
    int hdrIdx = -1;
    for (int i = 0; i < allRows.length; i++) {
      final low = allRows[i].map((c) => c.toLowerCase()).toList();
      if (low.any((c) => c.contains('sl')) &&
          low.any((c) => c.contains('bidder'))) {
        hdrIdx = i;
        break;
      }
    }
    if (hdrIdx == -1) return null;

    final hdrLow = allRows[hdrIdx].map((c) => c.toLowerCase()).toList();
    final bidderCol = _xlCol(hdrLow, ['bidder']);
    final pctCol = _xlCol(hdrLow, ['percentage', 'perc', '%']);

    // Check if the next row is a sub-header (contains 'rate' or 'amount')
    int dataStart = hdrIdx + 1;
    int amtCol = pctCol >= 0 ? pctCol + 1 : -1;
    if (dataStart < allRows.length) {
      final subLow = allRows[dataStart].map((c) => c.toLowerCase()).toList();
      if (subLow.any((c) => c == 'rate' || c == 'amount')) {
        final rateIdx = subLow.indexOf('rate');
        if (rateIdx >= 0) amtCol = rateIdx;
        dataStart++;
      }
    }

    // Find the lowest bidder name from the trailing "Lowest Amount Quoted BY: NAME(...)" row
    String lowestName = '';
    for (final row in allRows.reversed) {
      if (row.isNotEmpty && row[0].toLowerCase().contains('lowest')) {
        final m = RegExp(r'BY:\s*([A-Z][A-Z ]+)', caseSensitive: false)
            .firstMatch(row[0]);
        if (m != null) lowestName = m.group(1)!.trim().toUpperCase();
        break;
      }
    }

    // Build output rows
    final outRows = <List<String>>[
      ['#', 'Bidder', 'Quoted %', 'Amount'],
    ];
    for (int i = dataStart; i < allRows.length; i++) {
      final row = allRows[i];
      if (row.isEmpty) continue;
      if (!RegExp(r'^\d').hasMatch(row[0])) continue; // skip non-data rows

      final sl = row[0].replaceAll(RegExp(r'\.0+$'), '');
      final rawBidder =
          (bidderCol >= 0 && bidderCol < row.length) ? row[bidderCol] : '';
      final bidder = _xlCleanBidder(rawBidder);
      final pct =
          (pctCol >= 0 && pctCol < row.length) ? '${row[pctCol]}%' : '';
      final amt = (amtCol >= 0 && amtCol < row.length)
          ? _xlFmtAmount(row[amtCol])
          : '';

      final isLowest = lowestName.isNotEmpty &&
          bidder.toUpperCase().startsWith(lowestName.split(' ').first);
      outRows.add([sl, isLowest ? '$bidder (Lowest)' : bidder, pct, amt]);
    }

    if (outRows.length <= 1) return null;
    return SummarySection(title: name, rows: outRows);
  }

  // ── BOQ helpers ──────────────────────────────────────────────────────────

  String _xlCellStr(Data? cell) {
    final v = cell?.value;
    if (v == null) return '';
    if (v is TextCellValue) return v.value.toString().trim();
    if (v is IntCellValue) return v.value.toString();
    if (v is DoubleCellValue) return v.value.toString();
    return v.toString().trim();
  }

  int _xlCol(List<String> lowerHdrs, List<String> keywords) {
    for (int i = 0; i < lowerHdrs.length; i++) {
      if (keywords.any((k) => lowerHdrs[i].contains(k))) return i;
    }
    return -1;
  }

  String _xlCleanBidder(String raw) {
    return raw
        .replaceAll(RegExp(r'\(GSTN-[^)]*\)', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'\(?\s*BID\s*ID\s*[-:]?\s*\d+\s*\)?',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  /// Formats a numeric string as Indian currency: 5532439.58 → ₹55,32,439.58
  String _xlFmtAmount(String raw) {
    final val = double.tryParse(raw);
    if (val == null) return raw;
    final parts = val.toStringAsFixed(2).split('.');
    String intPart = parts[0];
    final dec = parts[1];
    if (intPart.length <= 3) return '₹$intPart.$dec';
    final last3 = intPart.substring(intPart.length - 3);
    String rest = intPart.substring(0, intPart.length - 3);
    final groups = <String>[];
    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);
    return '₹${groups.join(',')},$last3.$dec';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isCaptchaRejected(dom.Document doc) {
    return doc.querySelector('td.alerttext') != null;
  }

  Map<String, String> _extractHiddenFields(dom.Document document) {
    final form = document.querySelector('form#frmSearchFilter') ??
        document.querySelector('form');
    final fields = <String, String>{};
    for (final input
        in (form ?? document).querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? input.attributes['id'];
      if (name != null && name.isNotEmpty) {
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    return fields;
  }

  Uint8List _extractCaptchaBytes(dom.Document document) {
    for (final img in document.querySelectorAll('img')) {
      final src = img.attributes['src'] ?? '';
      if (src.startsWith('data:image')) {
        final b64 = src.split(',').last.replaceAll(RegExp(r'\s'), '');
        return base64Decode(b64);
      }
    }
    throw Exception('Captcha image not found in page.');
  }

  String _buildPayload(
    Map<String, String> hidden,
    String tenderId,
    String captchaText,
  ) {
    final params = <String, String>{
      ...hidden,
      'tenderStatus': '0',
      'KeyWord': '',
      'fromDate': '',
      'toDate': '',
      'formContract': '0',
      'tenderCategory': '0',
      'TenderType': '0',
      'ProductCategory': '0',
      'OrganName': '0',
      'tenderRefNo': '',
      'Department': '0',
      'publishedFromDate': '',
      'Division': '0',
      'publishedToDate': '',
      'SubDivision': '0',
      'KeyWord2': '',
      'Branch': '0',
      'Block': '0',
      'tenderId': tenderId,
      'captchaText': captchaText,
      'Search': 'Search',
      'component': 'frmSearchFilter',
      'page': 'WebTenderStatusLists',
      'service': 'direct',
      'session': 'T',
      'submitmode': '',
      'submitname': '',
    };
    return params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  List<TenderResult> _parseResultTable(dom.Document document) {
    final results = <TenderResult>[];

    for (final table in document.querySelectorAll('table')) {
      final rows = table.querySelectorAll('tr');
      if (rows.isEmpty) continue;

      final headerCells = rows.first.querySelectorAll('th, td');
      final headers = headerCells.map((e) => e.text.trim()).toList();

      // Skip nav/mega-menu tables: any header cell longer than 40 chars
      if (headers.any((h) => h.length > 40)) continue;

      final headersLower = headers.map((h) => h.toLowerCase()).toList();
      // Must have both 'tender id' and 'tender stage' as exact short cells
      if (!headersLower.contains('tender id') ||
          !headersLower.contains('tender stage')) continue;

      for (final row in rows.skip(1)) {
        final cells = row.querySelectorAll('td');
        if (cells.isEmpty) continue;
        // Skip spacer rows (no text and no links)
        if (cells.every((c) => c.text.trim().isEmpty && c.querySelector('a') == null)) continue;

        final fields = <String, String>{};
        final links = <String, String>{};

        for (var i = 0; i < headers.length && i < cells.length; i++) {
          final cell = cells[i];
          fields[headers[i]] = cell.text.trim();
          for (final anchor in cell.querySelectorAll('a')) {
            final href = anchor.attributes['href'] ?? '';
            if (href.isEmpty) continue;
            final uri = href.startsWith('http')
                ? href
                : 'https://wbtenders.gov.in$href';
            // Use id/title for links with no visible text (e.g. image-only links)
            final id = anchor.attributes['id'] ?? '';
            final title = anchor.attributes['title'] ?? '';
            final label = anchor.text.trim().isNotEmpty
                ? anchor.text.trim()
                : title.isNotEmpty
                    ? title
                    : id.isNotEmpty
                        ? id
                        : headers[i];
            links[label] = uri;
          }
        }

        results.add(TenderResult(fields, links: links));
      }
      break; // only process first matching table
    }

    return results;
  }

  /// Parses WB Tenders detail / summary page using the site's CSS classes:
  ///   content root  : <td class="page_content">
  ///   section titles: <td class="textbold1">
  ///   KV tables     : <table class="tablebg">
  ///   list tables   : <table class="list_table">
  List<SummarySection> _parseSummaryPage(dom.Document doc) {
    final root = doc.querySelector('td.page_content') ??
        doc.querySelector('.page_content') ??
        doc.body ??
        doc.documentElement!;

    final sections = <SummarySection>[];
    var pendingTitle = '';
    var pendingSubTitle = ''; // fallback from td_caption for nested list tables

    void walk(dom.Element el) {
      for (final child in el.children) {
        if (child.localName == 'td' && child.classes.contains('textbold1')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) pendingTitle = t;
          continue;
        }
        if (child.localName == 'td' && child.classes.contains('td_caption')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) pendingSubTitle = t;
          continue;
        }
        if (child.localName == 'table' && child.classes.contains('tablebg')) {
          final section = _parseTablebg(child, pendingTitle);
          if (section != null) {
            sections.add(section);
            pendingTitle = '';
          }
          walk(child);
          continue;
        }
        if (child.localName == 'table' && child.classes.contains('list_table')) {
          final title = pendingTitle.isNotEmpty ? pendingTitle : pendingSubTitle;
          final section = _parseListTable(child, title);
          if (section != null) {
            sections.add(section);
            pendingTitle = '';
            pendingSubTitle = '';
          }
          continue;
        }
        // ── Stage-summary tables (table_list class) ──────────────────────
        if (child.localName == 'table' && child.classes.contains('table_list')) {
          String title = pendingTitle;
          if (title.isEmpty) {
            final sh = child.querySelector('td.section_head');
            if (sh != null) title = sh.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          }
          if (title.isEmpty) title = pendingSubTitle;
          final section = _parseTableList(child, title);
          if (section != null) {
            sections.add(section);
            pendingTitle = '';
            pendingSubTitle = '';
          }
          continue;
        }
        walk(child);
      }
    }

    walk(root);
    return sections;
  }

  SummarySection? _parseTablebg(dom.Element table, String title) {
    final dataRows = <List<String>>[];
    final dataLinks = <List<String?>>[];
    for (final tr in _directRows(table)) {
      final cells = _directCells(tr);
      if (cells.isEmpty) continue;
      final vals = cells.map((c) => _cellText(c)).toList();
      if (vals.every((v) => v.isEmpty)) continue;
      if (vals.length >= 2 && vals.sublist(1).every((v) => v.isEmpty)) continue;
      final links = cells.map((c) => _cellLink(c)).toList();
      dataRows.add(vals);
      dataLinks.add(links);
    }
    if (dataRows.isEmpty) return null;
    if (dataRows.every((r) => r.length <= 1)) return null;
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks);
  }

  SummarySection? _parseListTable(dom.Element table, String title) {
    // If this table has no direct list_header row, check whether it's a
    // wrapper whose real data sits in a nested table (e.g. packetTableView
    // for Covers Information).  Only delegate when such an inner table is
    // actually found; otherwise fall through and parse this table directly.
    final hasHeader =
        _directRows(table).any((r) => r.classes.contains('list_header'));
    if (!hasHeader) {
      var inner = table.querySelector('tr.list_header')?.parent;
      if (inner?.localName == 'tbody') inner = inner?.parent;
      if (inner != null && inner.localName == 'table') {
        return _parseListTable(inner, title);
      }
      // No inner table with list_header found — parse this table directly.
    }

    final dataRows = <List<String>>[];
    final dataLinks = <List<String?>>[];
    for (final tr in _directRows(table)) {
      final cells = tr.querySelectorAll('td, th');
      if (cells.isEmpty) continue;
      final vals = cells
          .map((c) => c.text.trim().replaceAll(RegExp(r'\s+'), ' '))
          .toList();
      if (vals.every((v) => v.isEmpty)) continue;
      final links = cells.map((c) => _cellLink(c)).toList();
      dataRows.add(vals);
      dataLinks.add(links);
    }
    if (dataRows.isEmpty) return null;
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks, isListTable: true);
  }

  /// Parses a <table class="table_list"> (stage-summary page format).
  /// Skips the internal section-title row (td.section_head); remaining rows
  /// are header + data. isListTable is left false so isKeyValue works for
  /// 2-column KV tables.
  SummarySection? _parseTableList(dom.Element table, String title) {
    final dataRows = <List<String>>[];
    final dataLinks = <List<String?>>[];
    for (final tr in _directRows(table)) {
      final cells = tr.querySelectorAll('td, th');
      if (cells.isEmpty) continue;
      if (cells.any((c) => c.classes.contains('section_head'))) continue;
      final vals = cells
          .map((c) => c.text.trim().replaceAll(RegExp(r'\s+'), ' '))
          .toList();
      if (vals.every((v) => v.isEmpty)) continue;
      final links = cells.map((c) => _cellLink(c)).toList();
      dataRows.add(vals);
      dataLinks.add(links);
    }
    if (dataRows.isEmpty) return null;
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks);
  }

  List<dom.Element> _directRows(dom.Element table) {
    final rows = <dom.Element>[];
    for (final child in table.children) {
      if (child.localName == 'tbody' ||
          child.localName == 'thead' ||
          child.localName == 'tfoot') {
        for (final tr in child.children) {
          if (tr.localName == 'tr') rows.add(tr);
        }
      } else if (child.localName == 'tr') {
        rows.add(child);
      }
    }
    return rows;
  }

  List<dom.Element> _directCells(dom.Element tr) {
    final cells = <dom.Element>[];
    void walk(dom.Element el) {
      for (final child in el.children) {
        if (child.localName == 'td' || child.localName == 'th') {
          cells.add(child);
        } else if (child.localName != 'table') {
          walk(child);
        }
      }
    }
    walk(tr);
    return cells;
  }

  String _cellText(dom.Element cell) {
    final buf = StringBuffer();
    void walk(dom.Node node) {
      if (node is dom.Text) {
        buf.write(node.text);
      } else if (node is dom.Element && node.localName != 'table') {
        for (final child in node.nodes) {
          walk(child);
        }
      }
    }
    for (final child in cell.nodes) {
      walk(child);
    }
    return buf.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _cellLink(dom.Element cell) {
    final a = cell.querySelector('a[href]');
    if (a == null) return null;
    final href = a.attributes['href'] ?? '';
    if (href.isEmpty) return null;
    return href.startsWith('http')
        ? href
        : 'https://wbtenders.gov.in$href';
  }
}
