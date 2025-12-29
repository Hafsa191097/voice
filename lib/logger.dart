
import 'package:flutter/foundation.dart';

enum VoiceOption {
  alloy('alloy', 'Alloy'),
  ash('ash', 'Ash'),
  ballad('ballad', 'Ballad'),
  coral('coral', 'Coral'),
  echo('echo', 'Echo'),
  sage('sage', 'Sage'),
  shimmer('shimmer', 'Shimmer'),
  verse('verse', 'Verse');
  final String apiName;
  final String displayName;
  const VoiceOption(this.apiName, this.displayName);
}
/// Transcript entry
class TranscriptEntry {
  final String text;
  final bool isUser;
  final bool isFinal;
  final DateTime timestamp;
  TranscriptEntry({
    required this.text,
    required this.isUser,
    this.isFinal = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
/// Voice session statistics
class VoiceSessionStats {
  final int messageCount;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final Duration sessionDuration;
  const VoiceSessionStats({
    this.messageCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.sessionDuration = Duration.zero,
  });
  VoiceSessionStats copyWith({
    int? messageCount,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
    Duration? sessionDuration,
  }) {
    return VoiceSessionStats(
      messageCount: messageCount ?? this.messageCount,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      sessionDuration: sessionDuration ?? this.sessionDuration,
    );
  }
  factory VoiceSessionStats.fromUsage(Map<String, dynamic>? usage) {
    if (usage == null) return const VoiceSessionStats();
    return VoiceSessionStats(
      promptTokens: usage['prompt_tokens'] as int? ?? 0,
      completionTokens: usage['completion_tokens'] as int? ?? 0,
      totalTokens: usage['total_tokens'] as int? ?? 0,
    );
  }
}
/// Session creation request
class CreateSessionRequest {
  final String model;
  final String provider;
  final bool isVoiceSession;
  final String? customGptId;
  const CreateSessionRequest({
    required this.model,
    required this.provider,
    this.isVoiceSession = true,
    this.customGptId,
  });
  Map<String, dynamic> toJson() => {
    'model': model,
    'provider': provider,
    'is_voice_session': isVoiceSession,
    if (customGptId != null) 'custom_gpt_id': customGptId,
  };
}
/// Session response from API
class SessionResponse {
  final String sessionId;
  final String userId;
  final String title;
  final String model;
  final String provider;
  final int messageCount;
  final int tokenCount;
  final bool isVoiceSession;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  SessionResponse({
    required this.sessionId,
    required this.userId,
    required this.title,
    required this.model,
    required this.provider,
    required this.messageCount,
    required this.tokenCount,
    required this.isVoiceSession,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  factory SessionResponse.fromJson(Map<String, dynamic> json) {
    return SessionResponse(
      sessionId: json['session_id'] as String,
      userId: json['user_id'] as String,
      title: json['title'] as String? ?? 'New Chat',
      model: json['model'] as String,
      provider: json['provider'] as String,
      messageCount: json['message_count'] as int? ?? 0,
      tokenCount: json['token_count'] as int? ?? 0,
      isVoiceSession: json['is_voice_session'] as bool? ?? false,
      status: json['status'] as String? ?? 'active',
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}
/// Token request for authentication
class TokenRequest {
  final String userId;
  final String email;
  const TokenRequest({
    required this.userId,
    required this.email,
  });
  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'email': email,
  };
}
/// Token response from API
class TokenResponse {
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  TokenResponse({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
  });
  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    return TokenResponse(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'bearer',
      expiresIn: json['expires_in'] as int? ?? 3600,
    );
  }
}


/// Log levels
enum LogLevel {
  debug,
  info,
  warn,
  error,
}
/// Application logger
class AppLogger {
  static LogLevel _minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;
  static void setMinLevel(LogLevel level) {
    _minLevel = level;
  }
  static void debug(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.debug, message, error, stack);
  }
  static void info(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.info, message, error, stack);
  }
  static void warn(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.warn, message, error, stack);
  }
  static void error(String message, [Object? error, StackTrace? stack]) {
    _log(LogLevel.error, message, error, stack);
  }
  static void _log(LogLevel level, String message, Object? error, StackTrace? stack) {
    if (level.index < _minLevel.index) return;
    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(5);
    final buffer = StringBuffer('[$timestamp] $levelStr: $message');
    if (error != null) {
      buffer.write('\n  Error: $error');
    }
    if (stack != null && level == LogLevel.error) {
      buffer.write('\n  Stack: $stack');
    }
    // Use debugPrint for Flutter compatibility
    debugPrint(buffer.toString());
  }
}

// enum VoiceModel {
//   gptRealtime('gpt-4o-realtime-preview', 'GPT-4o Realtime'),
//   gptRealtimeMini('gpt-4o-mini-realtime-preview', 'GPT-4o Mini Realtime');
// }

// enum VoiceOption {
//   alloy('alloy', 'Alloy'),
//   ash('ash', 'Ash'),
//   ballad('ballad', 'Ballad'),
//   coral('coral', 'Coral'),
//   echo('echo', 'Echo'),
//   sage('sage', 'Sage'),
//   shimmer('shimmer', 'Shimmer'),
//   verse('verse', 'Verse');
// }