import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'audio_processor.dart';
import 'logger.dart';
import 'voice_mode.dart';
import 'voice_service.dart';

enum VoiceCallState {
  idle,
  initializing,
  connecting,
  connected,
  listening,
  aiSpeaking,
  error,
  ended,
}

class VoiceCallManager extends ChangeNotifier {
  final ApiService _apiService;
  final VoiceService _voiceService;
  final AudioProcessor _audioProcessor;

  StreamSubscription? _voiceEventSub;
  StreamSubscription? _audioStateSub;

  VoiceCallState _state = VoiceCallState.idle;
  VoiceCallState get state => _state;

  String? _sessionId;
  String? get sessionId => _sessionId;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  final List<TranscriptEntry> _transcripts = [];
  List<TranscriptEntry> get transcripts => List.unmodifiable(_transcripts);

  String _userPartialTranscript = '';
  String get userPartialTranscript => _userPartialTranscript;

  String _assistantPartialTranscript = '';
  String get assistantPartialTranscript => _assistantPartialTranscript;

  VoiceSessionStats _stats = const VoiceSessionStats();
  VoiceSessionStats get stats => _stats;

  DateTime? _callStartTime;
  Duration get callDuration => _callStartTime == null
      ? Duration.zero
      : DateTime.now().difference(_callStartTime!);

  VoiceModel _selectedModel = VoiceModel.gptRealtime;
  VoiceModel get selectedModel => _selectedModel;

  VoiceOption _selectedVoice = VoiceOption.alloy;
  VoiceOption get selectedVoice => _selectedVoice;

  int _audioChunksSent = 0;

  VoiceCallManager({required String baseUrl})
    : _apiService = ApiService(baseUrl: baseUrl),
      _voiceService = VoiceService(baseUrl: baseUrl),
      _audioProcessor = AudioProcessor();

  Future<bool> initialize() async {
    _updateState(VoiceCallState.initializing);

    try {
      final audioInitialized = await _audioProcessor.initialize();
      if (!audioInitialized) {
        _setError('Failed to initialize audio');
        return false;
      }

      final apiHealthy = await _apiService.healthCheck();
      if (!apiHealthy) AppLogger.warn('API health check failed');

      _audioProcessor.onAudioRecorded = _handleRecordedAudio;
      _audioProcessor.onPlaybackComplete = _handlePlaybackComplete;
      _audioProcessor.onError = _handleAudioError;

      _voiceEventSub = _voiceService.events.listen(_handleVoiceEvent);
      _audioStateSub = _audioProcessor.stateStream.listen(
        _handleAudioStateChange,
      );

      _updateState(VoiceCallState.idle);
      AppLogger.info('VoiceCallManager initialized');
      return true;
    } catch (e, stack) {
      AppLogger.error('Initialization failed', e, stack);
      _setError('Initialization failed: $e');
      return false;
    }
  }

  Future<bool> authenticate({
    required String userId,
    required String email,
  }) async {
    try {
      await _apiService.createToken(userId: userId, email: email);
      AppLogger.info('Authenticated as $userId');
      return true;
    } catch (e) {
      AppLogger.error('Authentication failed', e);
      _setError('Authentication failed: $e');
      return false;
    }
  }

  void setCallOptions({VoiceModel? model, VoiceOption? voice}) {
    if (model != null) _selectedModel = model;
    if (voice != null) _selectedVoice = voice;
    notifyListeners();
  }

  Future<bool> startCall() async {
    if (!_apiService.hasValidToken) {
      _setError('Not authenticated');
      return false;
    }

    if (_state != VoiceCallState.idle && _state != VoiceCallState.ended) {
      AppLogger.warn('Cannot start call - invalid state: $_state');
      return false;
    }

    _updateState(VoiceCallState.connecting);
    _clearTranscripts();
    _errorMessage = null;
    _audioChunksSent = 0;

    try {
      AppLogger.info('Creating voice session...');
      final session = await _apiService.createSession(
        model: _selectedModel.apiName,
        provider: 'openai',
      );
      _sessionId = session.sessionId;
      AppLogger.info('Session created: $_sessionId');

      AppLogger.info('Connecting to voice service...');
      final connected = await _voiceService.connect(
        token: _apiService.token!,
        sessionId: _sessionId!,
        model: _selectedModel.apiName,
        voice: _selectedVoice.apiName,
      );

      if (!connected) {
        _setError('Failed to connect to voice service');
        return false;
      }

      AppLogger.info('Starting audio recording...');
      final recordingStarted = await _audioProcessor.startRecording();
      if (!recordingStarted) {
        _setError('Failed to start recording');
        await _voiceService.disconnect();
        return false;
      }

      _callStartTime = DateTime.now();
      _updateState(VoiceCallState.connected);
      AppLogger.info('Voice call started successfully');
      return true;
    } catch (e, stack) {
      AppLogger.error('Failed to start call', e, stack);
      _setError('Failed to start call: $e');
      return false;
    }
  }

  Future<void> endCall() async {
    AppLogger.info('Ending voice call...');
    await _audioProcessor.stopRecording();
    _audioProcessor.clearPlaybackBuffer();
    await _voiceService.disconnect();

    _callStartTime = null;
    _updateState(VoiceCallState.ended);

    AppLogger.info(
      'Voice call ended. Total audio chunks sent: $_audioChunksSent',
    );
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    notifyListeners();
    AppLogger.info('Mute toggled: $_isMuted');
  }

  void interrupt() {
    if (_state == VoiceCallState.aiSpeaking) {
      AppLogger.info('Manual interrupt requested');
      _performInterrupt();
    }
  }

  Future<void> _performInterrupt() async {
    AppLogger.info('>>> Performing interrupt');

    await _audioProcessor.interruptPlayback();
    _voiceService.interrupt();

    _assistantPartialTranscript = '';
    _updateState(VoiceCallState.listening);
    notifyListeners();
  }

  // New state
  int _vadCounter = 0;
  static const int _vadFramesThreshold =
      3; 
  static const double _vadRmsThreshold = 0.05;

  // Called when audio is recorded
  void _handleRecordedAudio(Uint8List audioData) {
    if (_isMuted) return;

    // Active states
    final activeStates = [
      VoiceCallState.connected,
      VoiceCallState.listening,
      VoiceCallState.aiSpeaking,
    ];

    if (!activeStates.contains(_state)) return;

    if (_state == VoiceCallState.aiSpeaking) {
      // Only check after a short grace period after last AI chunk
      if (_isAudioAboveThreshold(audioData)) {
        _vadCounter++;
        if (_vadCounter >= _vadFramesThreshold) {
          AppLogger.info('User speech detected, performing interrupt');
          _performInterrupt();
          _vadCounter = 0; // reset
        }
      } else {
        _vadCounter = 0;
      }
      return; // Don't send AI playback audio to backend
    }

    if (!_voiceService.isConnected) return;

    _audioChunksSent++;
    _voiceService.sendAudio(audioData);
  }

  bool _isAudioAboveThreshold(Uint8List data) {
    if (data.length < 2) return false;

    double sumSq = 0.0;
    int count = 0;
    for (int i = 0; i < data.length - 1; i += 2) {
      int sample = data[i] | (data[i + 1] << 8);
      if (sample >= 32768) sample -= 65536;
      double norm = sample / 32768.0;
      sumSq += norm * norm;
      count++;
    }

    if (count == 0) return false;

    double rms = sqrt(sumSq / count);
    const double threshold = 0.05;
    return rms > threshold;
  }

  void _handlePlaybackComplete() {
    if (_state == VoiceCallState.aiSpeaking) {
      _updateState(VoiceCallState.connected);
    }
  }

  void _handleAudioError(String error) {
    _setError(error);
  }

  void _handleAudioStateChange(AudioProcessorState audioState) {
    if (audioState == AudioProcessorState.buffering ||
        audioState == AudioProcessorState.playing) {
      if (_state == VoiceCallState.connected ||
          _state == VoiceCallState.listening) {
        _updateState(VoiceCallState.aiSpeaking);
      }
    }
  }

  void _handleVoiceEvent(VoiceEvent event) {
    switch (event) {
      case VoiceStateChanged e:
        _handleVoiceStateChanged(e);
      case VoiceAudioReceived e:
        _handleAudioReceived(e);
      case VoiceTranscriptReceived e:
        _handleTranscript(e);
      case VoiceSpeechStarted _:
        _handleSpeechStarted();
      case VoiceSpeechEnded _:
        _handleSpeechEnded();
      case VoiceResponseInterrupted e:
        _handleResponseInterrupted(e);
      case VoiceResponseComplete e:
        _handleResponseComplete(e);
      case VoiceError e:
        _handleVoiceError(e);
    }
  }

  void _handleVoiceStateChanged(VoiceStateChanged event) {
    switch (event.state) {
      case VoiceConnectionState.connected:
        if (_state == VoiceCallState.connecting) {
          _updateState(VoiceCallState.connected);
        }
      case VoiceConnectionState.error:
        _setError(event.message ?? 'Connection error');
      case VoiceConnectionState.disconnected:
        if (_state != VoiceCallState.ended && _state != VoiceCallState.idle) {
          _setError('Connection lost');
        }
      default:
        break;
    }
  }

  void _handleAudioReceived(VoiceAudioReceived event) {
    _audioProcessor.addToPlaybackBuffer(event.audioData);
    _vadCounter = 0; 
    if (_state == VoiceCallState.connected ||
        _state == VoiceCallState.listening) {
      _updateState(VoiceCallState.aiSpeaking);
    }
  }

  void _handleTranscript(VoiceTranscriptReceived event) {
    if (event.isUser) {
      if (event.isFinal) {
        _transcripts.add(
          TranscriptEntry(text: event.text, isUser: true, isFinal: true),
        );
        _userPartialTranscript = '';
      } else {
        _userPartialTranscript = event.text;
      }
    } else {
      if (event.isFinal) {
        _assistantPartialTranscript = '';
      } else {
        _assistantPartialTranscript += event.text;
      }
    }
    notifyListeners();
  }

  void _handleSpeechStarted() {
    if (_state == VoiceCallState.aiSpeaking || _audioProcessor.isPlaying) {
      _performInterrupt();
    } else {
      _updateState(VoiceCallState.listening);
    }
  }

  void _handleSpeechEnded() {
    if (_state == VoiceCallState.listening) {
      _updateState(VoiceCallState.connected);
    }
  }

  void _handleResponseInterrupted(VoiceResponseInterrupted event) {
    _assistantPartialTranscript = '';
    notifyListeners();
  }

  void _handleResponseComplete(VoiceResponseComplete event) {
    if (event.transcript != null && event.transcript!.isNotEmpty) {
      _transcripts.add(
        TranscriptEntry(text: event.transcript!, isUser: false, isFinal: true),
      );
    }
    _assistantPartialTranscript = '';

    if (event.usage != null) {
      _stats = _stats.copyWith(
        messageCount: _stats.messageCount + 1,
        promptTokens:
            _stats.promptTokens + (event.usage!['prompt_tokens'] as int? ?? 0),
        completionTokens:
            _stats.completionTokens +
            (event.usage!['completion_tokens'] as int? ?? 0),
        totalTokens:
            _stats.totalTokens + (event.usage!['total_tokens'] as int? ?? 0),
      );
    }

    notifyListeners();
    _audioProcessor.signalResponseComplete();
  }

  void _handleVoiceError(VoiceError event) {
    if ([
      'AUTH_FAILED',
      'SESSION_NOT_FOUND',
      'INVALID_TOKEN',
    ].contains(event.code)) {
      _setError('${event.code}: ${event.message}');
    }
  }

  void _clearTranscripts() {
    _transcripts.clear();
    _userPartialTranscript = '';
    _assistantPartialTranscript = '';
    _stats = const VoiceSessionStats();
    notifyListeners();
  }

  void _updateState(VoiceCallState newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }

  void _setError(String message) {
    _errorMessage = message;
    _updateState(VoiceCallState.error);
  }

  @override
  void dispose() {
    endCall();
    _voiceEventSub?.cancel();
    _audioStateSub?.cancel();
    _voiceService.dispose();
    _audioProcessor.dispose();
    super.dispose();
  }
}
