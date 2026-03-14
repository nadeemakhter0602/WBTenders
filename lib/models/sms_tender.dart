class SmsTender {
  final String tenderId;
  final String smsBody;
  final String sender;
  final DateTime? date;
  final String? bidId;
  final String? status;

  const SmsTender({
    required this.tenderId,
    required this.smsBody,
    required this.sender,
    this.date,
    this.bidId,
    this.status,
  });
}
