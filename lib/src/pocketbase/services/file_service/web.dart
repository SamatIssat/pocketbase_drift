// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../../../pocketbase_drift.dart';

class $FileService extends FileService {
  $FileService(this.client) : super(client);

  @override
  final $PocketBase client;

  /// Gets file data, respecting the specified [RequestPolicy].
  ///
  /// This method centralizes the cache-or-network logic for files.
  /// It follows the principle that stale cached data is better than no data
  /// when the network is unavailable.
  Future<Uint8List> getFileData({
    required String recordId,
    required String recordCollectionName,
    required String filename,
    String? thumb,
    String? token,
    bool autoGenerateToken = false,
    RequestPolicy requestPolicy = RequestPolicy.cacheAndNetwork,
    Duration? expireAfter,
  }) async {
    final record = RecordModel({
      'id': recordId,
      'collectionName': recordCollectionName,
    });

    // Try to get cached file first
    BlobFile? cached;
    bool cacheIsExpired = false;
    if (requestPolicy.isCache) {
      cached = await client.db.getFile(record.id, filename).getSingleOrNull();
      if (cached != null) {
        final now = DateTime.now();
        cacheIsExpired =
            cached.expiration != null && cached.expiration!.isBefore(now);

        // Return valid (non-expired) cache immediately
        if (!cacheIsExpired) {
          return cached.data;
        }

        // For cacheOnly policy, return even expired cache (stale data > no data)
        if (requestPolicy == RequestPolicy.cacheOnly) {
          client.logger.fine(
              'Returning expired cached file (cacheOnly policy): $filename');
          return cached.data;
        }

        client.logger.fine('Cached file expired, will try network: $filename');
      } else if (requestPolicy == RequestPolicy.cacheOnly) {
        // cacheOnly but no cache exists - throw
        throw Exception(
            'File "$filename" not found in cache (cacheOnly policy)');
      }
    }

    // Try network if policy allows
    if (requestPolicy.isNetwork) {
      try {
        String? fileToken = token;
        if (autoGenerateToken && fileToken == null) {
          fileToken = await client.files.getToken();
        }
        final bytes = await _downloadFile(record, filename,
            thumb: thumb, token: fileToken);

        // Save to cache after a successful network download if policy allows
        if (requestPolicy.isCache) {
          await client.db.setFile(record.id, filename, bytes,
              expires:
                  expireAfter != null ? DateTime.now().add(expireAfter) : null);
        }
        return bytes;
      } catch (e) {
        client.logger.warning('Failed to download file "$filename": $e');

        // If network failed but we have expired cache, return stale data
        if (cached != null) {
          client.logger
              .fine('Network failed, returning expired cached file: $filename');
          return cached.data;
        }

        // Network failed and no cache - rethrow
        rethrow;
      }
    }

    throw Exception(
        'Could not get file "$filename" with policy "$requestPolicy"');
  }

  /// Downloads a file using a streaming approach to improve performance for
  /// larger files compared to loading the entire file into memory at once.
  Future<Uint8List> _downloadFile(
    RecordModel record,
    String filename, {
    String? thumb,
    String? token,
  }) async {
    final url = getURL(record, filename, thumb: thumb, token: token);

    final httpClient = client.httpClientFactory();
    final request = http.Request('GET', url);
    final streamedResponse = await httpClient.send(request);

    if (streamedResponse.statusCode != 200) {
      throw ClientException(
        url: url,
        response: {
          'message':
              'Failed to download file. Status code: ${streamedResponse.statusCode}'
        },
      );
    }

    return streamedResponse.stream.toBytes();
  }
}
