import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';

import '../models/summary_section.dart';
import '../models/tender_result.dart';
import 'tender_service.dart' show CaptchaRejectedError;

/// Thrown when a document download requires solving a DocDownCaptcha challenge.
class DocCaptchaRequired implements Exception {
  final Uint8List captchaBytes;
  final Map<String, String> hiddenFields;
  const DocCaptchaRequired(
      {required this.captchaBytes, required this.hiddenFields});
}

class SearchPageResult {
  final List<TenderResult> results;
  final String? firstPageUrl;
  final String? prevPageUrl;
  final String? nextPageUrl;
  final String? lastPageUrl;
  final List<MapEntry<String, String>> pageLinks; // label → url (numbered pages)
  final String pageInfo; // e.g. "1 to 20 of 150"

  const SearchPageResult({
    required this.results,
    this.firstPageUrl,
    this.prevPageUrl,
    this.nextPageUrl,
    this.lastPageUrl,
    this.pageLinks = const [],
    this.pageInfo = '',
  });
}

class AdvSelectOption {
  final String value;
  final String label;
  const AdvSelectOption(this.value, this.label);
}

class AdvancedSearchFormMeta {
  final Uint8List captchaBytes;
  final List<AdvSelectOption> orgOptions;
  final List<AdvSelectOption> productCategoryOptions;

  const AdvancedSearchFormMeta({
    required this.captchaBytes,
    required this.orgOptions,
    required this.productCategoryOptions,
  });
}

class AdvancedSearchService {
  static const _baseUrl = 'https://wbtenders.gov.in/nicgep/app';
  static const _pageUrl =
      '$_baseUrl?page=FrontEndAdvancedSearch&service=page';

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

  AdvancedSearchService() {
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

  /// GETs the advanced search page. Returns captcha bytes + static dropdown
  /// options. Hidden fields (tokenSecret, seedids, If_* tokens) are stored for
  /// all subsequent POSTs.
  Future<AdvancedSearchFormMeta> beginSession() async {
    _initDio();
    final resp = await _dio.get(_pageUrl);
    if (resp.statusCode != 200) {
      throw Exception('Page load failed: ${resp.statusCode}');
    }
    final doc = html_parser.parse(resp.data as String);
    _hiddenFields = _extractHiddenFields(doc);

    final captchaBytes = _extractCaptchaBytes(doc);
    final orgOptions = _extractSelectOptions(doc, 'OrganisationName');
    final productOptions = _extractSelectOptions(doc, 'ProductCategory');
    return AdvancedSearchFormMeta(
      captchaBytes: captchaBytes,
      orgOptions: orgOptions,
      productCategoryOptions: productOptions,
    );
  }

  // ── Cascade dropdown fetchers (Dojo AJAX) ──────────────────────────────────
  // The site uses Dojo's XHR with component=TenderAdvancedSearch and bevent*
  // parameters to identify which field changed. The response is full-page HTML
  // containing the updated <select> elements.

  Future<List<AdvSelectOption>> fetchDepartments(String orgValue) =>
      _fetchCascade(
        overrides: {'OrganisationName': orgValue},
        triggerField: 'OrganisationName',
        targetField: 'Department',
      );

  Future<List<AdvSelectOption>> fetchDivisions(
          String orgValue, String deptValue) =>
      _fetchCascade(
        overrides: {'OrganisationName': orgValue, 'Department': deptValue},
        triggerField: 'Department',
        targetField: 'Division',
      );

  Future<List<AdvSelectOption>> fetchSubDivisions(
          String orgValue, String deptValue, String divValue) =>
      _fetchCascade(
        overrides: {
          'OrganisationName': orgValue,
          'Department': deptValue,
          'Division': divValue,
        },
        triggerField: 'Division',
        targetField: 'SubDivision',
      );

  Future<List<AdvSelectOption>> fetchBranches(String orgValue,
          String deptValue, String divValue, String subDivValue) =>
      _fetchCascade(
        overrides: {
          'OrganisationName': orgValue,
          'Department': deptValue,
          'Division': divValue,
          'SubDivision': subDivValue,
        },
        triggerField: 'SubDivision',
        targetField: 'Branch',
      );

  /// Dojo AJAX cascade request — mirrors the XHR the browser sends when a
  /// cascading dropdown changes. Header `dojo-ajax-request: true` is required.
  Future<List<AdvSelectOption>> _fetchCascade({
    required Map<String, String> overrides,
    required String triggerField,
    required String targetField,
  }) async {
    final payload = <String, String>{
      ..._hiddenFields,
      'TenderType': '0',
      'tenderId': '',
      'OrganisationName': '0',
      'tenderRefNo': '',
      'workItemTitle': '',
      'Department': '0',
      'tenderCategory': '0',
      'Division': '0',
      'SubDivision': '0',
      'ProductCategory': '0',
      'Branch': '0',
      'formContract': '0',
      'Block': '0',
      'pinCode': '',
      'PaymentMode': '0',
      'valueCriteria': '0',
      'valueParameter': '0',
      'FromValue': '',
      'ToValue': '',
      'dateCriteria': '0',
      'fromDate': '',
      'toDate': '',
      ...overrides, // applied after defaults so they override
      'captchaText': '',
      'captcha': '',
      'methodArguments': '[]',
      'component': 'TenderAdvancedSearch',
      'page': 'FrontEndAdvancedSearch',
      'service': 'direct',
      'session': 'T',
      'submitmode': '',
      'submitname': '',
      'beventtarget.id': triggerField,
      'beventtype': 'change',
      'bcomponentid': triggerField,
      'bcomponentidpath': 'FrontEndAdvancedSearch/$triggerField',
      'beventname': 'onchange',
    };
    try {
      final resp = await _dio.post(
        _baseUrl,
        data: _encodePayload(payload),
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          headers: {
            'Referer': _pageUrl,
            'dojo-ajax-request': 'true',
            'Sec-Fetch-Dest': 'empty',
            'Sec-Fetch-Mode': 'cors',
            'Sec-Fetch-Site': 'same-origin',
          },
        ),
      );
      if (resp.statusCode != 200) return [];
      final doc = html_parser.parse(resp.data as String);
      return _extractSelectOptions(doc, targetField);
    } catch (_) {
      return [];
    }
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  /// POSTs the advanced search form.
  Future<SearchPageResult> submitSearch(
    Map<String, String> params,
    String captchaText,
  ) async {
    final payload = _encodePayload({
      ..._hiddenFields,
      ...params,
      'captchaText': captchaText,
      'submit': 'Search',
      'component': 'TenderAdvancedSearch',
      'page': 'FrontEndAdvancedSearch',
      'service': 'direct',
      'session': 'T',
      'submitmode': '',
      'submitname': '',
    });
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
    final results = _parseResultTable(doc);
    final pg = _parsePagination(doc);
    return SearchPageResult(
      results: results,
      firstPageUrl: pg.firstUrl,
      prevPageUrl: pg.prevUrl,
      nextPageUrl: pg.nextUrl,
      lastPageUrl: pg.lastUrl,
      pageLinks: pg.pageLinks,
      pageInfo: pg.pageInfo,
    );
  }

  /// GETs a paginated result page (next/prev/numbered links from Tapestry).
  Future<SearchPageResult> fetchPage(String url) async {
    final resp = await _dio.get(
      url,
      options: Options(headers: {'Referer': _pageUrl}),
    );
    if (resp.statusCode != 200) {
      throw Exception('Page load failed: ${resp.statusCode}');
    }
    final doc = html_parser.parse(resp.data as String);
    final results = _parseResultTable(doc);
    final pg = _parsePagination(doc);
    return SearchPageResult(
      results: results,
      firstPageUrl: pg.firstUrl,
      prevPageUrl: pg.prevUrl,
      nextPageUrl: pg.nextUrl,
      lastPageUrl: pg.lastUrl,
      pageLinks: pg.pageLinks,
      pageInfo: pg.pageInfo,
    );
  }

  /// GETs any URL and parses its tables into sections (for row link rendering).
  Future<List<SummarySection>> fetchPageSections(String url) async {
    final resp = await _dio.get(
      url,
      options: Options(headers: {'Referer': _baseUrl}),
    );
    if (resp.statusCode != 200) {
      throw Exception('Page load failed: ${resp.statusCode}');
    }
    final doc = html_parser.parse(resp.data as String);
    return _parseSummaryPage(doc);
  }

  // ── Stage summary ──────────────────────────────────────────────────────────

  /// Follows the "View Tender Status" link → stage summary page.
  /// Returns sections from both the detail page and the summary sub-page.
  Future<({List<SummarySection> sections})> fetchFullSummary(
      String viewUrl) async {
    final detailResp = await _dio.get(
      viewUrl,
      options: Options(headers: {'Referer': _baseUrl}),
    );
    if (detailResp.statusCode != 200) {
      throw Exception('Detail page failed: ${detailResp.statusCode}');
    }
    final detailDoc = html_parser.parse(detailResp.data as String);
    final detailSections = _parseSummaryPage(detailDoc);

    final summaryAnchor = detailDoc.querySelector('a#DirectLink_0');
    if (summaryAnchor == null) return (sections: detailSections);

    String summaryHref = summaryAnchor.attributes['href'] ?? '';
    if (summaryHref.isEmpty) return (sections: detailSections);
    if (!summaryHref.startsWith('http')) {
      summaryHref = 'https://wbtenders.gov.in$summaryHref';
    }

    final summaryResp = await _dio.get(
      summaryHref,
      options: Options(headers: {'Referer': viewUrl}),
    );
    if (summaryResp.statusCode != 200) return (sections: detailSections);
    final summaryDoc = html_parser.parse(summaryResp.data as String);
    final summarySections = _parseSummaryPage(summaryDoc);
    return (sections: [...detailSections, ...summarySections]);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Map<String, String> _extractHiddenFields(dom.Document doc) {
    final form = doc.querySelector('form#TenderAdvancedSearch') ??
        doc.querySelector('form');
    final fields = <String, String>{};
    for (final input
        in (form ?? doc).querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? input.attributes['id'];
      if (name != null && name.isNotEmpty) {
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    return fields;
  }

  Uint8List _extractCaptchaBytes(dom.Document doc) {
    for (final img in doc.querySelectorAll('img')) {
      final src = img.attributes['src'] ?? '';
      if (src.startsWith('data:image')) {
        final b64 = src.split(',').last.replaceAll(RegExp(r'\s'), '');
        return base64Decode(b64);
      }
    }
    throw Exception('Captcha image not found in page.');
  }

  List<AdvSelectOption> _extractSelectOptions(
      dom.Document doc, String name) {
    final select = doc.querySelector('select[name="$name"]');
    if (select == null) return [];
    final opts = <AdvSelectOption>[];
    for (final opt in select.querySelectorAll('option')) {
      final value = opt.attributes['value'] ?? '';
      final label = opt.text.trim();
      if (label.startsWith('-') || label.isEmpty) continue;
      opts.add(AdvSelectOption(value, label));
    }
    return opts;
  }

  bool _isCaptchaRejected(dom.Document doc) {
    return doc.querySelector('td.alerttext') != null;
  }

  String _encodePayload(Map<String, String> params) {
    return params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  List<TenderResult> _parseResultTable(dom.Document doc) {
    final results = <TenderResult>[];

    for (final table in doc.querySelectorAll('table')) {
      final rows = table.querySelectorAll('tr');
      if (rows.isEmpty) continue;

      final headerCells = rows.first.querySelectorAll('th, td');
      final headers = headerCells.map((e) => e.text.trim()).toList();
      if (headers.any((h) => h.length > 40)) continue;

      final headersLower = headers.map((h) => h.toLowerCase()).toList();
      if (!headersLower.any((h) => h.contains('tender id'))) continue;

      for (final row in rows.skip(1)) {
        final cells = row.querySelectorAll('td');
        if (cells.isEmpty) continue;
        if (cells.every(
            (c) => c.text.trim().isEmpty && c.querySelector('a') == null)) {
          continue;
        }
        // Skip pagination rows: a single cell spanning multiple columns, or
        // a cell whose text contains navigation keywords / count pattern.
        if (cells.length == 1) {
          final cellText = cells.first.text.trim().toLowerCase();
          if (cells.first.attributes.containsKey('colspan') ||
              RegExp(r'\d+\s+to\s+\d+\s+of\s+\d+').hasMatch(cellText) ||
              cellText.contains('next') ||
              cellText.contains('previous') ||
              cellText.contains('last') ||
              cellText.contains('first')) {
            continue;
          }
        }

        final fields = <String, String>{};
        final links = <String, String>{};
        for (var i = 0; i < headers.length && i < cells.length; i++) {
          final cell = cells[i];
          fields[headers[i]] =
              cell.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          for (final anchor in cell.querySelectorAll('a')) {
            final href = anchor.attributes['href'] ?? '';
            if (href.isEmpty) continue;
            final uri = href.startsWith('http')
                ? href
                : 'https://wbtenders.gov.in$href';
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
      break;
    }

    return results;
  }

  ({
    String? firstUrl,
    String? prevUrl,
    String? nextUrl,
    String? lastUrl,
    List<MapEntry<String, String>> pageLinks,
    String pageInfo,
  }) _parsePagination(dom.Document doc) {
    String? firstUrl, prevUrl, nextUrl, lastUrl;
    final pageLinks = <MapEntry<String, String>>[];
    String pageInfo = '';

    // Extract "X to Y of Z" count text
    final bodyText = doc.body?.text ?? '';
    final countMatch =
        RegExp(r'(\d+)\s+to\s+(\d+)\s+of\s+(\d+)', caseSensitive: false)
            .firstMatch(bodyText);
    if (countMatch != null) {
      pageInfo =
          '${countMatch.group(1)} to ${countMatch.group(2)} of ${countMatch.group(3)}';
    }

    // Find the pagination container — the element that contains the count text.
    // Walk up until we find a parent that has anchor children (the nav links).
    dom.Element? paginationRoot;
    for (final el in doc.querySelectorAll('td, div, span, p')) {
      if (!RegExp(r'\d+\s+to\s+\d+\s+of\s+\d+').hasMatch(el.text)) continue;
      // If this element already has anchors, use it directly.
      if (el.querySelectorAll('a').isNotEmpty) {
        paginationRoot = el;
        break;
      }
      // Otherwise walk up to find the nearest ancestor with anchors.
      var parent = el.parent;
      while (parent != null) {
        if (parent.querySelectorAll('a').isNotEmpty) {
          paginationRoot = parent;
          break;
        }
        parent = parent.parent;
      }
      if (paginationRoot != null) break;
    }

    // Scan anchors — within the pagination container if found, else whole body.
    final anchors =
        (paginationRoot ?? doc.body)?.querySelectorAll('a') ?? [];

    for (final anchor in anchors) {
      final text = anchor.text.trim();
      final href = anchor.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      final uri =
          href.startsWith('http') ? href : 'https://wbtenders.gov.in$href';
      final lower = text.toLowerCase();

      if (lower == 'first' ||
          lower == '<<' ||
          lower == '|<' ||
          lower == 'first page') {
        firstUrl ??= uri;
      } else if (lower == 'previous' ||
          lower == 'prev' ||
          lower == '< previous' ||
          lower == 'previous <' ||
          lower == '<' ||
          lower == '«' ||
          lower == 'prev page') {
        prevUrl ??= uri;
      } else if (lower == 'next' ||
          lower == 'next >' ||
          lower == '>' ||
          lower == '»' ||
          lower == 'next page') {
        nextUrl ??= uri;
      } else if (lower == 'last' ||
          lower == '>>' ||
          lower == '>|' ||
          lower == 'last page') {
        lastUrl ??= uri;
      } else if (RegExp(r'^\d+$').hasMatch(text)) {
        final n = int.tryParse(text);
        if (n != null && n >= 1 && n <= 9999) {
          pageLinks.add(MapEntry(text, uri));
        }
      }
    }

    return (
      firstUrl: firstUrl,
      prevUrl: prevUrl,
      nextUrl: nextUrl,
      lastUrl: lastUrl,
      pageLinks: pageLinks,
      pageInfo: pageInfo,
    );
  }

  /// Parses the WB Tenders detail / summary page by targeting the specific CSS
  /// classes used by the site:
  ///   • Content root  : <td class="page_content">
  ///   • Section titles: <td class="textbold1">
  ///   • KV data tables: <table class="tablebg">
  ///   • List tables   : <table class="list_table">
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
        // ── Section title (textbold1) ──────────────────────────────────
        if (child.localName == 'td' &&
            child.classes.contains('textbold1')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) pendingTitle = t;
          continue;
        }

        // ── Sub-section label (td_caption) used as fallback title ─────
        if (child.localName == 'td' &&
            child.classes.contains('td_caption')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) pendingSubTitle = t;
          continue;
        }

        // ── Notice / error message box ────────────────────────────────
        if (child.localName == 'td' &&
            child.classes.contains('message_box')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) {
            sections.add(SummarySection(title: t, rows: []));
          }
          continue;
        }

        // ── KV data table (tablebg) ────────────────────────────────────
        if (child.localName == 'table' &&
            child.classes.contains('tablebg')) {
          final section = _parseTablebg(child, pendingTitle);
          if (section != null) {
            sections.add(section);
            pendingTitle = '';
          }
          walk(child);
          continue;
        }

        // ── List / document table (list_table) ────────────────────────
        if (child.localName == 'table' &&
            child.classes.contains('list_table')) {
          final title = pendingTitle.isNotEmpty ? pendingTitle : pendingSubTitle;
          final section = _parseListTable(child, title);
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

    // "Download as zip file" (a#DirectLink_8) lives in a <span>-wrapped <tr>
    // (invalid HTML) — the parser foster-parents it outside td.page_content so
    // walk() never sees it. Query the full document by known id.
    // Find by the static zipicon.png image inside the anchor — more stable than
    // the DirectLink_N id which can vary between tenders.
    final zipImg = doc.querySelector('img[src*="zipicon"]');
    dom.Element? zipAnchor;
    if (zipImg != null) {
      dom.Element? p = zipImg.parent;
      while (p != null && p.localName != 'a') {
        p = p.parent;
      }
      if (p != null && p.localName == 'a') zipAnchor = p;
    }
    if (zipAnchor != null) {
      final href = zipAnchor.attributes['href'] ?? '';
      if (href.isNotEmpty) {
        final url =
            href.startsWith('http') ? href : 'https://wbtenders.gov.in$href';
        final zipSection = SummarySection(
          title: '',
          rows: [
            [''],
            ['Download as zip file'],
          ],
          cellLinks: [
            [null],
            [url],
          ],
          isListTable: true,
        );
        // Insert after the Tender Documents (NIT docs) list_table — identified
        // as the last list_table section containing a docDownoad link.
        final nitIdx = sections.lastIndexWhere((s) =>
            s.isListTable &&
            s.cellLinks.any((row) => row.any((u) =>
                u != null && u.toLowerCase().contains('docdownoad'))));
        if (nitIdx >= 0) {
          sections.insert(nitIdx + 1, zipSection);
        } else {
          sections.add(zipSection);
        }
      }
    }

    return sections;
  }

  /// Parses a <table class="tablebg"> as a key-value section.
  /// Uses direct-children traversal so nested list_table content is excluded.
  SummarySection? _parseTablebg(dom.Element table, String title) {
    final dataRows = <List<String>>[];
    final dataLinks = <List<String?>>[];

    for (final tr in _directRows(table)) {
      final cells = _directCells(tr);
      if (cells.isEmpty) continue;
      final vals =
          cells.map((c) => _cellText(c)).toList();
      if (vals.every((v) => v.isEmpty)) continue;
      // Skip rows where label exists but ALL value cells are empty
      // (these are wrapper rows whose value is a nested list_table).
      if (vals.length >= 2 && vals.sublist(1).every((v) => v.isEmpty)) continue;
      final links = cells.map((c) => _cellLink(c)).toList();
      dataRows.add(vals);
      dataLinks.add(links);
    }

    if (dataRows.isEmpty) return null;
    if (dataRows.every((r) => r.length <= 1)) return null;
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks);
  }

  /// Parses a <table class="list_table"> as a columnar table section.
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

      // Fix attribution: the download icon cell carries the docDownoad URL but
      // has no visible text. Move that URL to the document-name cell so the
      // filename is the tappable element.
      const docExts = ['.pdf', '.xls', '.xlsx', '.doc', '.docx', '.zip', '.rar'];
      final dlIdx = links.indexWhere(
          (u) => u != null && u.toLowerCase().contains('component=docdownoad'));
      if (dlIdx >= 0) {
        final nameIdx = vals.indexWhere(
            (v) => docExts.any(v.toLowerCase().endsWith));
        if (nameIdx >= 0 && nameIdx != dlIdx) {
          links[nameIdx] = links[dlIdx];
          links[dlIdx] = null;
        }
      }

      dataRows.add(vals);
      dataLinks.add(links);
    }

    if (dataRows.isEmpty) return null;
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks, isListTable: true);
  }

  // ── DOM helpers ──────────────────────────────────────────────────────────

  /// Returns the direct <tr> children of a table (via implicit tbody/thead).
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

  /// Returns td/th cells within a <tr>, including those inside <span> wrappers,
  /// but NOT cells from nested <table> elements.
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

  /// Returns the text content of a cell, excluding text inside nested tables.
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

  // ── Document download ────────────────────────────────────────────────────

  /// Returns true for URLs that should be downloaded as files rather than
  /// opened in a browser.
  ///
  /// [text] is the visible link text. Signature/DSC links have no visible text
  /// (image-only anchors) so [text] will be blank — those are excluded.
  static bool isDownloadableLink(String url, String text) {
    final urlLower = url.toLowerCase();
    // Zip bundle download
    if (urlLower.contains('component=zipdownload')) return true;
    // Direct file by extension (no captcha needed)
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.pdf') ||
        path.endsWith('.xls') ||
        path.endsWith('.xlsx') ||
        path.endsWith('.doc') ||
        path.endsWith('.docx') ||
        path.endsWith('.zip')) {
      return true;
    }
    // For opaque Tapestry $DirectLink URLs, use link text to distinguish
    // document/zip links from image-only signature (certificate) links.
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false; // image-only = signature link
    final textLower = trimmed.toLowerCase();
    if (textLower.contains('download')) return true;
    const docExts = ['.pdf', '.xls', '.xlsx', '.doc', '.docx', '.zip', '.rar'];
    if (docExts.any(textLower.endsWith)) return true;
    return false;
  }


  /// GETs the document URL.
  /// - Returns the local file path if the server sends the file directly.
  /// - Throws [DocCaptchaRequired] if the server shows a DocDownCaptcha page.
  Future<String> fetchDocument(String url) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': _baseUrl},
      ),
    );
    final ct = resp.headers.value('content-type') ?? '';
    if (!ct.startsWith('text/html')) {
      return await _saveToTempAsync(resp.data!, ct, url);
    }
    final doc = html_parser.parse(utf8.decode(resp.data!));
    throw _docCaptchaFromPage(doc) ??
        Exception('Unexpected HTML response when downloading document.');
  }

  /// POSTs the DocDownCaptcha form.
  /// - Returns the local file path on success.
  /// - Throws [DocCaptchaRequired] (with a fresh challenge) if captcha was wrong.
  Future<String> submitDocCaptcha(
      Map<String, String> hiddenFields, String captchaText, String originalUrl) async {
    final payload = _encodePayload({
      ...hiddenFields,
      'captchaText': captchaText,
      'Submit': 'Submit',
    });
    final postResp = await _dio.post<List<int>>(
      _baseUrl,
      data: payload,
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        responseType: ResponseType.bytes,
        headers: {
          'Referer': originalUrl,
          'Sec-Fetch-Dest': 'document',
          'Sec-Fetch-Mode': 'navigate',
          'Sec-Fetch-Site': 'same-origin',
        },
      ),
    );
    final postCt = postResp.headers.value('content-type') ?? '';
    if (!postCt.startsWith('text/html')) {
      return await _saveToTempAsync(postResp.data!, postCt, originalUrl);
    }
    final postDoc = html_parser.parse(utf8.decode(postResp.data!));
    final challenge = _docCaptchaFromPage(postDoc);
    if (challenge != null) throw challenge;

    // Captcha accepted. The server returns an HTML page that contains a fresh
    // download link (with a new sp= token). Extract that link and fetch it.
    // Falling back to originalUrl would re-trigger the captcha (old sp token).
    //
    // When the original request was for the zip bundle (not an individual
    // docDownoad PDF), prefer the zip anchor from the success page rather than
    // the first docDownoad individual-file link.
    String? downloadUrl;
    if (originalUrl.toLowerCase().contains('component=docdownoad')) {
      downloadUrl = _extractDownloadLink(postDoc) ?? originalUrl;
    } else {
      final zipImg = postDoc.querySelector('img[src*="zipicon"]');
      if (zipImg != null) {
        dom.Element? p = zipImg.parent;
        while (p != null && p.localName != 'a') {
          p = p.parent;
        }
        if (p != null && p.localName == 'a') {
          final href = p.attributes['href'] ?? '';
          if (href.isNotEmpty) {
            downloadUrl =
                href.startsWith('http') ? href : 'https://wbtenders.gov.in$href';
          }
        }
      }
      downloadUrl ??= originalUrl;
    }
    return await fetchDocument(downloadUrl);
  }

  /// Finds the first downloadable link in a page (used after captcha success).
  /// Uses URL-based criteria only — avoids matching the site's navigation
  /// "Downloads" link (page=StandardBiddingDocuments) via text.
  String? _extractDownloadLink(dom.Document doc) {
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      final url =
          href.startsWith('http') ? href : 'https://wbtenders.gov.in$href';
      final urlLower = url.toLowerCase();
      if (urlLower.contains('component=docdownoad')) return url;
      if (urlLower.contains('component=zipdownload')) return url;
      final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
      if (path.endsWith('.pdf') || path.endsWith('.xls') ||
          path.endsWith('.xlsx') || path.endsWith('.doc') ||
          path.endsWith('.docx') || path.endsWith('.zip')) {
        return url;
      }
      final text = a.text.replaceAll('\u00a0', ' ').trim();
      if (text.isNotEmpty) {
        final textLower = text.toLowerCase();
        const exts = ['.pdf', '.xls', '.xlsx', '.doc', '.docx', '.zip', '.rar'];
        if (exts.any(textLower.endsWith)) return url;
      }
    }
    return null;
  }

  /// Builds a [DocCaptchaRequired] from a DocDownCaptcha HTML page, or null.
  DocCaptchaRequired? _docCaptchaFromPage(dom.Document doc) {
    final captchaImg = doc.querySelector('img#captchaImage');
    if (captchaImg == null) return null;
    final src = captchaImg.attributes['src'] ?? '';
    if (!src.startsWith('data:image')) return null;
    final captchaBytes =
        base64Decode(src.split(',').last.replaceAll(RegExp(r'\s'), ''));
    final hidden = <String, String>{};
    for (final input
        in doc.querySelectorAll('form#frmCaptcha input[type="hidden"]')) {
      final name = input.attributes['name'] ?? input.attributes['id'];
      if (name != null && name.isNotEmpty) {
        hidden[name] = input.attributes['value'] ?? '';
      }
    }
    return DocCaptchaRequired(captchaBytes: captchaBytes, hiddenFields: hidden);
  }

  Future<String> _saveToTempAsync(
      List<int> bytes, String contentType, String url) async {
    String ext = '';
    final uriPath = Uri.parse(url).path;
    final dot = uriPath.lastIndexOf('.');
    if (dot >= 0 && uriPath.length - dot <= 5) {
      ext = uriPath.substring(dot).toLowerCase();
    }
    if (ext.isEmpty) {
      final ct = contentType.toLowerCase();
      if (ct.contains('pdf')) {
        ext = '.pdf';
      } else if (ct.contains('spreadsheetml') || ct.contains('excel')) {
        ext = '.xlsx';
      } else if (ct.contains('wordprocessingml') || ct.contains('word')) {
        ext = '.docx';
      } else if (ct.contains('zip')) {
        ext = '.zip';
      } else {
        ext = '.bin';
      }
    }
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/tender_${DateTime.now().millisecondsSinceEpoch}$ext');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Returns the href of the most relevant anchor in a cell, or null.
  /// Prefers anchors with visible text (skips image-only certificate/DSC links).
  String? _cellLink(dom.Element cell) {
    dom.Element? fallback;
    for (final a in cell.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty) continue;
      final text = a.text.replaceAll('\u00a0', ' ').trim();
      if (text.isNotEmpty) {
        // First text-bearing anchor wins.
        return href.startsWith('http')
            ? href
            : 'https://wbtenders.gov.in$href';
      }
      fallback ??= a; // keep first image-only anchor as last resort
    }
    if (fallback == null) return null;
    final href = fallback.attributes['href'] ?? '';
    if (href.isEmpty) return null;
    return href.startsWith('http')
        ? href
        : 'https://wbtenders.gov.in$href';
  }
}
