class TenderResult {
  final Map<String, String> fields;
  // label → absolute URL extracted from anchor tags in table cells
  final Map<String, String> links;

  TenderResult(this.fields, {this.links = const {}});

  List<MapEntry<String, String>> get allFields =>
      fields.entries.where((e) => e.value.isNotEmpty).toList();
}
