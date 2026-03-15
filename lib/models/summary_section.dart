class SummarySection {
  final String title;

  /// All data rows. For key-value sections each row has 2 cells [label, value].
  /// For table sections the first row is the column headers.
  final List<List<String>> rows;

  /// Parallel to [rows]: URL for each cell, or null if the cell has no link.
  final List<List<String?>> cellLinks;

  /// True when parsed from a <table class="list_table"> — always render as
  /// a columnar table regardless of column count.
  final bool isListTable;

  const SummarySection({
    required this.title,
    required this.rows,
    this.cellLinks = const [],
    this.isListTable = false,
  });

  /// True when every row has exactly 2 cells → render as label/value pairs.
  bool get isKeyValue => !isListTable && rows.isNotEmpty && rows.every((r) => r.length == 2);

  /// True when rows are a mix of 2- and 4-column KV rows (label,value,label,value).
  /// The original site uses 4-column tables for "Basic Details" etc.
  /// Never true for list tables (they must render as columnar tables).
  bool get isKeyValueLike =>
      !isListTable &&
      rows.isNotEmpty &&
      rows.every((r) => r.length == 2 || r.length == 4) &&
      rows.any((r) => r.length == 4) &&
      rows.any((r) => r.length == 2); // must have BOTH 2-col and 4-col rows

  /// For multi-column tables: first row is headers, rest is data.
  List<String> get headers =>
      (!isKeyValue && !isKeyValueLike && rows.isNotEmpty) ? rows.first : [];
  List<List<String>> get dataRows =>
      (!isKeyValue && !isKeyValueLike && rows.length > 1)
          ? rows.skip(1).toList()
          : [];

  List<List<String?>> get dataRowLinks =>
      (!isKeyValue && !isKeyValueLike && cellLinks.length > 1)
          ? cellLinks.skip(1).toList()
          : [];
}
