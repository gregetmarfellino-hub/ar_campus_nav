import 'package:flutter/services.dart';

/// Android's system document picker and share sheet, without a server or
/// broad storage permissions. The receiving device imports the same JSON.
class VenueProjectTransfer {
  const VenueProjectTransfer();

  static const _channel = MethodChannel('ar_campus_nav/native');

  Future<String?> pickFile() =>
      _channel.invokeMethod<String>('importVenueProjectFile');

  Future<String?> saveFile({
    required String name,
    required String content,
  }) => _channel.invokeMethod<String>('exportVenueProjectFile', {
        'name': name,
        'json': content,
      });

  Future<bool> shareFile({
    required String name,
    required String content,
  }) async {
    return await _channel.invokeMethod<bool>('shareVenueProjectFile', {
          'name': name,
          'json': content,
        }) ??
        false;
  }
}
