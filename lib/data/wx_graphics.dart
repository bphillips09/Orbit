class WxGraphicalProduct {
  final int productType;
  final int productCode;
  final int size;
  final List<int> bytes;
  final DateTime timestamp;

  WxGraphicalProduct({
    required this.productType,
    required this.productCode,
    required this.size,
    required this.bytes,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'productType': productType,
      'productCode': productCode,
      'size': size,
      'bytes': bytes,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  static WxGraphicalProduct fromMap(Map<String, dynamic> map) {
    return WxGraphicalProduct(
      productType: map['productType'] as int,
      productCode: map['productCode'] as int,
      size: map['size'] as int,
      bytes: List<int>.from(map['bytes'] as List),
      timestamp:
          DateTime.fromMillisecondsSinceEpoch((map['timestamp'] as int?) ?? 0),
    );
  }
}
