import 'logger.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;



/// Voice connection states
enum VoiceConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  active,
  error,
  reconnecting,
}

/// Voice service events
abstract class VoiceEvent {}

class VoiceStateChanged extends VoiceEvent {
  final VoiceConnectionState state;
  final String? message;
  VoiceStateChanged(this.state, [this.message]);
}

class VoiceAudioReceived extends VoiceEvent {
  final Uint8List audioData;
  final String? messageId;
  VoiceAudioReceived(this.audioData, this.messageId);
}

class VoiceTranscriptReceived extends VoiceEvent {
  final String text;
  final bool isUser;
  final bool isFinal;
  VoiceTranscriptReceived(this.text, {required this.isUser, required this.isFinal});
}

class VoiceSpeechStarted extends VoiceEvent {}

class VoiceSpeechEnded extends VoiceEvent {}

class VoiceResponseInterrupted extends VoiceEvent {
  final String reason;
  VoiceResponseInterrupted(this.reason);
}

class VoiceResponseComplete extends VoiceEvent {
  final String? transcript;
  final String? audioUrl;
  final Map<String, dynamic>? usage;
  VoiceResponseComplete({this.transcript, this.audioUrl, this.usage});
}

class VoiceError extends VoiceEvent {
  final String code;
  final String message;
  VoiceError(this.code, this.message);
}

/// Main voice service class
class VoiceService {
  // Configuration
  final String baseUrl;
  final Duration connectionTimeout;
  final Duration authTimeout;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;

  // WebSocket
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  // State
  VoiceConnectionState _state = VoiceConnectionState.disconnected;
  String? _sessionId;
  String? _userId;
  String? _token;
  String? _model;
  String? _voice;
  
  // Response tracking - CRITICAL for handling stale audio
  String? _currentResponseId;
  bool _isResponseInProgress = false;
  bool _isInterrupted = false;
  
  // Reconnection
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  
  // Ping/Pong for connection health
  Timer? _pingTimer;
  DateTime? _lastPongReceived;
  static const Duration _pingInterval = Duration(seconds: 15);
  static const Duration _pongTimeout = Duration(seconds: 10);

  // Event stream
  final _eventController = StreamController<VoiceEvent>.broadcast();
  Stream<VoiceEvent> get events => _eventController.stream;

  // Getters
  VoiceConnectionState get state => _state;
  bool get isConnected => _state == VoiceConnectionState.connected || 
                          _state == VoiceConnectionState.active;
  String? get sessionId => _sessionId;

  VoiceService({
    required this.baseUrl,
    this.connectionTimeout = const Duration(seconds: 30),
    this.authTimeout = const Duration(seconds: 10),
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(seconds: 2),
  });

  /// Connect to voice WebSocket
  Future<bool> connect({
    required String token,
    required String sessionId,
    required String model,
    String voice = 'alloy',
  }) async {
    if (_state == VoiceConnectionState.connecting || 
        _state == VoiceConnectionState.authenticating) {
      AppLogger.warn('Connection already in progress');
      return false;
    }

    _token = token;
    _sessionId = sessionId;
    _model = model;
    _voice = voice;
    _reconnectAttempts = 0;

    return _establishConnection();
  }

  Future<bool> _establishConnection() async {
    _updateState(VoiceConnectionState.connecting);
    
    try {
      // Build WebSocket URL
      final wsUrl = _buildWebSocketUrl();
      AppLogger.info('Connecting to: $wsUrl');

      // Create WebSocket connection
      _channel = WebSocketChannel.connect(
        Uri.parse(wsUrl),
        protocols: ['websocket'],
      );

      // Wait for connection with timeout
      await _channel!.ready.timeout(
        connectionTimeout,
        onTimeout: () {
          throw TimeoutException('Connection timeout');
        },
      );

      // Setup message listener
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
        cancelOnError: false,
      );

      // Send authentication
      _updateState(VoiceConnectionState.authenticating);
      await _authenticate();

      return true;

    } catch (e, stack) {
      AppLogger.error('Connection failed', e, stack);
      _updateState(VoiceConnectionState.error, e.toString());
      _emitEvent(VoiceError('CONNECTION_FAILED', e.toString()));
      return false;
    }
  }

  String _buildWebSocketUrl() {
    // Convert http(s) to ws(s)
    String wsBase = baseUrl.replaceFirst('http://', 'ws://');
    wsBase = wsBase.replaceFirst('https://', 'wss://');
    
    // Remove trailing slash if present
    if (wsBase.endsWith('/')) {
      wsBase = wsBase.substring(0, wsBase.length - 1);
    }
    
    return '$wsBase/api/v1/voice';
  }

  Future<void> _authenticate() async {
    final authMessage = {
      'type': 'auth',
      'token': _token,
      'session_id': _sessionId,
      'model': _model,
      'voice': _voice,
    };

    _sendMessage(authMessage);

    // Auth response handled in _handleMessage
    // Timeout handled by caller
  }

  /// Send audio data to server
  void sendAudio(Uint8List audioData) {
    if (!isConnected) {
      AppLogger.warn('Cannot send audio - not connected');
      return;
    }

    if (audioData.isEmpty) {
      return;
    }

    // Convert to base64
    final base64Audio = base64Encode(audioData);
    
    // Skip very short audio (likely silence)
    if (base64Audio.length < 100) {
      return;
    }

    final message = {
      'type': 'audio',
      'data': base64Audio,
    };

    _sendMessage(message);
  }

  /// Request interruption of current response
  void interrupt() {
    if (!isConnected) return;
    
    if (_isResponseInProgress && !_isInterrupted) {
      AppLogger.info('Sending interrupt request');
      _isInterrupted = true;
      
      final message = {'type': 'interrupt'};
      _sendMessage(message);
    }
  }

  /// Update voice configuration
  void updateConfig({String? voice, double? vadThreshold}) {
    if (!isConnected) return;

    final config = <String, dynamic>{'type': 'config'};
    if (voice != null) config['voice'] = voice;
    if (vadThreshold != null) config['vad_threshold'] = vadThreshold;

    _sendMessage(config);
  }

  /// Disconnect from voice service
  Future<void> disconnect() async {
    AppLogger.info('Disconnecting voice service');
    
    _cancelTimers();
    _reconnectAttempts = maxReconnectAttempts; // Prevent auto-reconnect
    
    await _subscription?.cancel();
    _subscription = null;
    
    if (_channel != null) {
      try {
        await _channel!.sink.close(ws_status.normalClosure);
      } catch (e) {
        AppLogger.debug('Close exception: $e');
      }
      _channel = null;
    }

    _resetState();
    _updateState(VoiceConnectionState.disconnected);
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_channel == null) {
      AppLogger.warn('Cannot send - channel is null');
      return;
    }

    try {
      final jsonStr = jsonEncode(message);
      _channel!.sink.add(jsonStr);
      
      // Log non-audio messages
      if (message['type'] != 'audio') {
        AppLogger.debug('Sent: ${message['type']}');
      }
    } catch (e) {
      AppLogger.error('Send failed', e);
    }
  }

  void _handleMessage(dynamic rawMessage) {
    try {
      final data = jsonDecode(rawMessage as String) as Map<String, dynamic>;
      final type = data['type'] as String?;

      // Log non-audio messages
      if (type != 'audio') {
        AppLogger.debug('Received: $type');
      }

      switch (type) {
        case 'auth_success':
          _handleAuthSuccess(data);
          break;
        case 'audio':
          _handleAudio(data);
          break;
        case 'user_transcript':
          _handleUserTranscript(data);
          break;
        case 'assistant_transcript':
          _handleAssistantTranscript(data);
          break;
        case 'speech_started':
          _handleSpeechStarted();
          break;
        case 'speech_ended':
          _handleSpeechEnded();
          break;
        case 'response_interrupted':
          _handleResponseInterrupted(data);
          break;
        case 'response_complete':
          _handleResponseComplete(data);
          break;
        case 'error':
          _handleServerError(data);
          break;
        case 'pong':
          _handlePong();
          break;
        default:
          AppLogger.debug('Unhandled message type: $type');
      }
    } catch (e, stack) {
      AppLogger.error('Message handling error', e, stack);
    }
  }

  void _handleAuthSuccess(Map<String, dynamic> data) {
    _userId = data['user_id'] as String?;
    _sessionId = data['session_id'] as String?;
    
    final model = data['model'] as String?;
    final voice = data['voice'] as String?;
    
    AppLogger.info('Authenticated: user=$_userId, session=$_sessionId, model=$model, voice=$voice');
    
    _updateState(VoiceConnectionState.connected);
    _startPingTimer();
    _reconnectAttempts = 0;
  }

  void _handleAudio(Map<String, dynamic> data) {
    // CRITICAL: Check if this audio belongs to current response
    final responseId = data['response_id'] as String?;
    if (responseId != null && responseId != _currentResponseId) {
      AppLogger.debug('Dropping stale audio from old response: $responseId');
      return;
    }
    
    // Check interruption state
    if (_isInterrupted || !_isResponseInProgress) {
      AppLogger.debug('Dropping audio - interrupted or no response in progress');
      return;
    }

    final audioBase64 = data['data'] as String?;
    if (audioBase64 == null || audioBase64.isEmpty) return;

    try {
      final audioBytes = base64Decode(audioBase64);
      final messageId = data['message_id'] as String?;
      
      _emitEvent(VoiceAudioReceived(audioBytes, messageId));
    } catch (e) {
      AppLogger.error('Audio decode error', e);
    }
  }

  void _handleUserTranscript(Map<String, dynamic> data) {
    final text = data['text'] as String? ?? '';
    final isFinal = data['is_final'] as bool? ?? false;
    
    _emitEvent(VoiceTranscriptReceived(text, isUser: true, isFinal: isFinal));
  }

  void _handleAssistantTranscript(Map<String, dynamic> data) {
    // Check interruption
    if (_isInterrupted) return;
    
    final text = data['text'] as String? ?? '';
    final isFinal = data['is_final'] as bool? ?? false;
    
    _emitEvent(VoiceTranscriptReceived(text, isUser: false, isFinal: isFinal));
  }

  void _handleSpeechStarted() {
    _updateState(VoiceConnectionState.active);
    _emitEvent(VoiceSpeechStarted());
    
    // If response is in progress, this indicates user interruption
    if (_isResponseInProgress && !_isInterrupted) {
      AppLogger.info('User speech detected during response - expecting interruption');
    }
  }

  void _handleSpeechEnded() {
    _emitEvent(VoiceSpeechEnded());
    
    // Response will start soon - prepare for it
    if (!_isInterrupted) {
      _isResponseInProgress = true;
      _currentResponseId = null; // Will be set when response.created arrives
    }
  }

  void _handleResponseInterrupted(Map<String, dynamic> data) {
    final reason = data['reason'] as String? ?? 'unknown';
    AppLogger.info('Response interrupted: $reason');
    
    _isResponseInProgress = false;
    _isInterrupted = false; // Reset for next response
    _currentResponseId = null;
    
    _emitEvent(VoiceResponseInterrupted(reason));
  }

  void _handleResponseComplete(Map<String, dynamic> data) {
    final transcript = data['transcript'] as String?;
    final audioUrl = data['audio_url'] as String?;
    final usage = data['usage'] as Map<String, dynamic>?;
    
    AppLogger.info('Response complete: ${transcript?.substring(0, transcript.length.clamp(0, 50))}...');
    
    _isResponseInProgress = false;
    _isInterrupted = false;
    _currentResponseId = null;
    
    _updateState(VoiceConnectionState.connected);
    _emitEvent(VoiceResponseComplete(
      transcript: transcript,
      audioUrl: audioUrl,
      usage: usage,
    ));
  }

  void _handleServerError(Map<String, dynamic> data) {
    final code = data['code'] as String? ?? 'UNKNOWN';
    final message = data['message'] as String? ?? 'Unknown error';
    
    AppLogger.error('Server error: $code - $message');
    _emitEvent(VoiceError(code, message));
    
    // Determine if error is fatal
    if (_isFatalError(code)) {
      _updateState(VoiceConnectionState.error, message);
    }
  }

  bool _isFatalError(String code) {
    return [
      'AUTH_FAILED',
      'SESSION_NOT_FOUND',
      'INVALID_TOKEN',
      'SESSION_EXPIRED',
    ].contains(code);
  }

  void _handlePong() {
    _lastPongReceived = DateTime.now();
  }

  void _handleError(dynamic error) {
    AppLogger.error('WebSocket error', error);
    _emitEvent(VoiceError('WEBSOCKET_ERROR', error.toString()));
    _attemptReconnect();
  }

  void _handleDone() {
    AppLogger.info('WebSocket connection closed');
    
    if (_state != VoiceConnectionState.disconnected) {
      _attemptReconnect();
    }
  }

  void _attemptReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      AppLogger.warn('Max reconnection attempts reached');
      _updateState(VoiceConnectionState.error, 'Connection lost');
      return;
    }

    _reconnectAttempts++;
    _updateState(VoiceConnectionState.reconnecting);
    
    AppLogger.info('Reconnection attempt $_reconnectAttempts/$maxReconnectAttempts');

    _cancelTimers();
    _subscription?.cancel();
    _channel = null;

    final delay = reconnectDelay * _reconnectAttempts; // Exponential backoff
    _reconnectTimer = Timer(delay, () {
      if (_token != null && _sessionId != null && _model != null) {
        _establishConnection();
      }
    });
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (isConnected) {
        _sendMessage({'type': 'ping'});
        
        // Check for pong timeout
        if (_lastPongReceived != null) {
          final elapsed = DateTime.now().difference(_lastPongReceived!);
          if (elapsed > _pongTimeout) {
            AppLogger.warn('Pong timeout - connection may be stale');
            _attemptReconnect();
          }
        }
      }
    });
  }

  void _cancelTimers() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _resetState() {
    _isResponseInProgress = false;
    _isInterrupted = false;
    _currentResponseId = null;
    _lastPongReceived = null;
  }

  void _updateState(VoiceConnectionState newState, [String? message]) {
    if (_state != newState) {
      _state = newState;
      _emitEvent(VoiceStateChanged(newState, message));
    }
  }

  void _emitEvent(VoiceEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Dispose resources
  void dispose() {
    disconnect();
    _eventController.close();
  }
}
