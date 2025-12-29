/// API Service for REST endpoints
/// Handles authentication and session management
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'logger.dart';

/// API client for REST endpoints
class ApiService {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  String? _token;
  DateTime? _tokenExpiry;
  String? _userId;
  String? _email;

  ApiService({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 30),
    http.Client? client,
  }) : _client = client ?? http.Client();

  // ============================================================
  // Token Management
  // ============================================================

  /// Set authentication token
  void setToken(String token, {int expiresIn = 3600}) {
    _token = token;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    AppLogger.debug('Token set, expires in $expiresIn seconds');
  }

  /// Clear authentication token
  void clearToken() {
    _token = null;
    _tokenExpiry = null;
    _userId = null;
    _email = null;
    AppLogger.debug('Token cleared');
  }

  /// Check if token is valid
  bool get hasValidToken {
    if (_token == null || _tokenExpiry == null) return false;
    // Add 30 second buffer before expiry
    return DateTime.now().isBefore(_tokenExpiry!.subtract(const Duration(seconds: 30)));
  }

  /// Get current token
  String? get token => hasValidToken ? _token : null;

  /// Get current user ID
  String? get userId => _userId;

  /// Get current email
  String? get email => _email;

  /// Get time until token expires
  Duration? get tokenExpiresIn {
    if (_tokenExpiry == null) return null;
    final remaining = _tokenExpiry!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ============================================================
  // Headers
  // ============================================================

  /// Get authentication headers
  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (hasValidToken) {
      headers['Authorization'] = 'Bearer $_token';
    }

    return headers;
  }

  /// Get headers without auth (for public endpoints)
  Map<String, String> get _publicHeaders => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  // ============================================================
  // Authentication Endpoints
  // ============================================================

  /// Create authentication token
  /// This is used for initial authentication
  Future<TokenResponse> createToken({
    required String userId,
    required String email,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/auth/token');

    final body = jsonEncode({
      'user_id': userId,
      'email': email,
    });

    AppLogger.info('Creating token for user: $userId');

    try {
      final response = await _client
          .post(
            url,
            headers: _publicHeaders,
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tokenResponse = TokenResponse.fromJson(data);

        // Auto-set token and user info
        setToken(tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn);
        _userId = userId;
        _email = email;

        AppLogger.info('Token created successfully');
        return tokenResponse;
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }
    } on TimeoutException {
      AppLogger.error('Token creation timeout');
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      AppLogger.error('Network error during token creation', e);
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      AppLogger.error('Token creation failed', e);
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  /// Refresh the current token
  /// Call this before token expires to maintain session
  Future<TokenResponse> refreshToken() async {
    if (_userId == null || _email == null) {
      throw ApiException(
        statusCode: 401,
        message: 'No user credentials available for refresh',
      );
    }

    AppLogger.info('Refreshing token...');
    return createToken(userId: _userId!, email: _email!);
  }

  /// Validate current token with server
  Future<bool> validateToken() async {
    if (!hasValidToken) return false;

    try {
      final url = Uri.parse('$baseUrl/api/v1/auth/validate');
      final response = await _client
          .get(url, headers: _headers)
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      AppLogger.warn('Token validation failed', e);
      return false;
    }
  }

  // ============================================================
  // Session Endpoints
  // ============================================================

  /// Create a new voice session
  Future<SessionResponse> createSession({
    required String model,
    required String provider,
    String? customGptId,
    bool isVoiceSession = true,
  }) async {
    _ensureAuthenticated();

    final url = Uri.parse('$baseUrl/api/v1/sessions');

    final body = jsonEncode({
      'model': model,
      'provider': provider,
      'is_voice_session': isVoiceSession,
      if (customGptId != null) 'custom_gpt_id': customGptId,
    });

    AppLogger.info('Creating session: model=$model, provider=$provider');

    try {
      final response = await _client
          .post(
            url,
            headers: _headers,
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        AppLogger.info('Session created: ${data['session_id']}');
        return SessionResponse.fromJson(data);
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }
    } on TimeoutException {
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  /// Get session details by ID
  Future<SessionResponse> getSession(String sessionId) async {
    _ensureAuthenticated();

    final url = Uri.parse('$baseUrl/api/v1/sessions/$sessionId');

    AppLogger.debug('Getting session: $sessionId');

    try {
      final response = await _client
          .get(
            url,
            headers: _headers,
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return SessionResponse.fromJson(data);
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }
    } on TimeoutException {
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  /// List user sessions with pagination
  Future<PaginatedResponse<SessionResponse>> listSessions({
    int page = 1,
    int pageSize = 20,
    bool? isVoiceSession,
    String? status,
  }) async {
    _ensureAuthenticated();

    final queryParams = {
      'page': page.toString(),
      'page_size': pageSize.toString(),
      if (isVoiceSession != null) 'is_voice_session': isVoiceSession.toString(),
      if (status != null) 'status': status,
    };

    final url = Uri.parse('$baseUrl/api/v1/sessions')
        .replace(queryParameters: queryParams);

    AppLogger.debug('Listing sessions: page=$page, pageSize=$pageSize');

    try {
      final response = await _client
          .get(
            url,
            headers: _headers,
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final items = (data['items'] as List<dynamic>)
            .map((item) => SessionResponse.fromJson(item as Map<String, dynamic>))
            .toList();

        return PaginatedResponse(
          items: items,
          total: data['total'] as int? ?? items.length,
          page: data['page'] as int? ?? page,
          pageSize: data['page_size'] as int? ?? pageSize,
          hasMore: data['has_more'] as bool? ?? false,
        );
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }
    } on TimeoutException {
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  /// Update session (e.g., title, model)
  Future<SessionResponse> updateSession(
    String sessionId, {
    String? title,
    String? model,
    String? status,
  }) async {
    _ensureAuthenticated();

    final url = Uri.parse('$baseUrl/api/v1/sessions/$sessionId');

    final updates = <String, dynamic>{};
    if (title != null) updates['title'] = title;
    if (model != null) updates['model'] = model;
    if (status != null) updates['status'] = status;

    if (updates.isEmpty) {
      throw ApiException(statusCode: 400, message: 'No updates provided');
    }

    final body = jsonEncode(updates);

    AppLogger.debug('Updating session: $sessionId');

    try {
      final response = await _client
          .patch(
            url,
            headers: _headers,
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        AppLogger.info('Session updated: $sessionId');
        return SessionResponse.fromJson(data);
      } else {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }
    } on TimeoutException {
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  /// Delete session and all its messages
  Future<void> deleteSession(String sessionId) async {
    _ensureAuthenticated();

    final url = Uri.parse('$baseUrl/api/v1/sessions/$sessionId');

    AppLogger.info('Deleting session: $sessionId');

    try {
      final response = await _client
          .delete(
            url,
            headers: _headers,
          )
          .timeout(timeout);

      if (response.statusCode != 204 && response.statusCode != 200) {
        throw ApiException(
          statusCode: response.statusCode,
          message: _parseErrorMessage(response.body),
        );
      }

      AppLogger.info('Session deleted: $sessionId');
    } on TimeoutException {
      throw ApiException(statusCode: 0, message: 'Request timeout');
    } on SocketException catch (e) {
      throw ApiException(statusCode: 0, message: 'Network error: ${e.message}');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(statusCode: 0, message: 'Network error: $e');
    }
  }

  // ============================================================
  // Health & Utility Endpoints
  // ============================================================

  /// Health check - returns true if API is reachable
  Future<bool> healthCheck() async {
    try {
      final url = Uri.parse('$baseUrl/api/v1/health');
      final response = await _client
          .get(url, headers: _publicHeaders)
          .timeout(const Duration(seconds: 5));

      final isHealthy = response.statusCode == 200;
      AppLogger.debug('Health check: ${isHealthy ? 'OK' : 'FAILED'}');
      return isHealthy;
    } catch (e) {
      AppLogger.warn('Health check failed', e);
      return false;
    }
  }

  /// Detailed health check with component status
  Future<Map<String, dynamic>> detailedHealthCheck() async {
    try {
      final url = Uri.parse('$baseUrl/api/v1/health/detailed');
      final response = await _client
          .get(url, headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'status': 'error', 'message': 'Health check failed'};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  // ============================================================
  // Helper Methods
  // ============================================================

  /// Ensure user is authenticated before making request
  void _ensureAuthenticated() {
    if (!hasValidToken) {
      throw ApiException(
        statusCode: 401,
        message: 'Not authenticated or token expired',
      );
    }
  }

  /// Parse error message from response body
  String _parseErrorMessage(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        // Try common error field names
        return data['detail'] as String? ??
            data['message'] as String? ??
            data['error'] as String? ??
            'Unknown error';
      }
    } catch (_) {}
    return body.isNotEmpty ? body : 'Unknown error';
  }

  /// Dispose resources
  void dispose() {
    _client.close();
    clearToken();
    AppLogger.debug('ApiService disposed');
  }
}

// ============================================================
// Data Classes
// ============================================================

/// API Exception with status code and message
class ApiException implements Exception {
  final int statusCode;
  final String message;
  final Map<String, dynamic>? details;

  ApiException({
    required this.statusCode,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'ApiException($statusCode): $message';

  /// Check if this is an authentication error
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  /// Check if this is a not found error
  bool get isNotFound => statusCode == 404;

  /// Check if this is a validation error
  bool get isValidationError => statusCode == 422;

  /// Check if this is a rate limit error
  bool get isRateLimitError => statusCode == 429;

  /// Check if this is a server error
  bool get isServerError => statusCode >= 500;

  /// Check if this is a network error (no response)
  bool get isNetworkError => statusCode == 0;

  /// Get user-friendly error message
  String get userMessage {
    if (isNetworkError) return 'Unable to connect. Please check your internet connection.';
    if (isAuthError) return 'Authentication failed. Please sign in again.';
    if (isNotFound) return 'The requested resource was not found.';
    if (isRateLimitError) return 'Too many requests. Please try again later.';
    if (isServerError) return 'Server error. Please try again later.';
    return message;
  }
}

/// Paginated response wrapper
class PaginatedResponse<T> {
  final List<T> items;
  final int total;
  final int page;
  final int pageSize;
  final bool hasMore;

  const PaginatedResponse({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  /// Check if this is the first page
  bool get isFirstPage => page == 1;

  /// Check if this is empty
  bool get isEmpty => items.isEmpty;

  /// Get total pages
  int get totalPages => (total / pageSize).ceil();
}
