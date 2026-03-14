import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/summary_section.dart';
import '../models/tender_result.dart';
import 'tender_service.dart' show CaptchaRejectedError;

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
    // Scope to the content td — excludes nav sidebar, header, and footer.
    final root = doc.querySelector('td.page_content') ??
        doc.querySelector('.page_content') ??
        doc.body ??
        doc.documentElement!;

    final sections = <SummarySection>[];
    var pendingTitle = '';

    // Recursive element walker.
    void walk(dom.Element el) {
      for (final child in el.children) {
        // ── Section title ─────────────────────────────────────────────────
        if (child.localName == 'td' &&
            child.classes.contains('textbold1')) {
          final t = child.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (t.isNotEmpty) pendingTitle = t;
          continue; // don't recurse into title cells
        }

        // ── KV data table (tablebg) ────────────────────────────────────
        if (child.localName == 'table' &&
            child.classes.contains('tablebg')) {
          final section = _parseTablebg(child, pendingTitle);
          if (section != null) {
            sections.add(section);
            pendingTitle = ''; // consume title
          }
          // Still recurse to pick up nested list_tables
          walk(child);
          continue;
        }

        // ── List / document table (list_table) ────────────────────────
        if (child.localName == 'table' &&
            child.classes.contains('list_table')) {
          final section = _parseListTable(child, pendingTitle);
          if (section != null) {
            sections.add(section);
            pendingTitle = ''; // consume title
          }
          continue; // don't recurse into list tables
        }

        // ── Recurse into everything else ──────────────────────────────
        walk(child);
      }
    }

    walk(root);
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
    return SummarySection(title: title, rows: dataRows, cellLinks: dataLinks);
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

  /// Returns the href of the first anchor in a cell, or null.
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
