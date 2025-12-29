import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:audio_session/audio_session.dart';

import 'logger.dart';

class AudioConfig {
  static const int sampleRate = 24000;
  static const int channels = 1;
  static const int bitsPerSample = 16;
  static const int bytesPerSample = bitsPerSample ~/ 8;
}

enum AudioProcessorState {
  idle,
  initializing,
  recording,
  buffering,
  playing,
  error,
}

class AudioProcessor {
  AudioProcessorState _state = AudioProcessorState.idle;
  AudioProcessorState get state => _state;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordingSubscription;
  bool _isRecordingActive = false;

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerSubscription;

  final List<int> _audioBuffer = [];
  bool _isBuffering = false;
  bool _waitingForPlayback = false;

  void Function(Uint8List)? onAudioRecorded;
  void Function()? onPlaybackComplete;
  void Function(String)? onError;

  final _stateController = StreamController<AudioProcessorState>.broadcast();
  Stream<AudioProcessorState> get stateStream => _stateController.stream;

  bool get isRecording => _isRecordingActive;
  bool get isPlaying => _waitingForPlayback;

  Future<bool> initialize() async {
    _updateState(AudioProcessorState.initializing);

    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetoothA2dp,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
      await session.setActive(true);

      final status = await Permission.microphone.request();
      if (!status.isGranted) return false;

      _player = AudioPlayer();
      _playerSubscription = _player!.playerStateStream.listen(
        _onPlayerStateChanged,
        onError: (e) => AppLogger.error('Player error: $e'),
      );

      _updateState(AudioProcessorState.idle);
      return true;
    } catch (e) {
      _handleError('Audio initialization failed: $e');
      return false;
    }
  }

  void _onPlayerStateChanged(PlayerState playerState) {
    if (playerState.processingState == ProcessingState.completed &&
        _waitingForPlayback) {
      _waitingForPlayback = false;
      _forceRestartRecording();
    }
  }

  Future<void> _forceRestartRecording() async {
    if (_isRecordingActive) await _stopRecordingInternal();
    await Future.delayed(const Duration(milliseconds: 200));
    await _startRecordingInternal();
    onPlaybackComplete?.call();
  }

  Future<bool> startRecording() async {
    if (_isRecordingActive) return true;
    return await _startRecordingInternal();
  }

  Future<bool> _startRecordingInternal() async {
    try {
      final config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AudioConfig.sampleRate,
        numChannels: AudioConfig.channels,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      );
      final stream = await _recorder.startStream(config);
      _recordingSubscription = stream.listen(
        (data) {
          if (data.isNotEmpty && _isRecordingActive) {
            onAudioRecorded?.call(data);
          }
        },
        onError: (e) {
          _isRecordingActive = false;
          _handleError('Recording stream error: $e');
        },
      );
      _isRecordingActive = true;
      _updateState(AudioProcessorState.recording);
      return true;
    } catch (e) {
      _isRecordingActive = false;
      return false;
    }
  }

  Future<void> stopRecording() async => await _stopRecordingInternal();

  Future<void> _stopRecordingInternal() async {
    if (!_isRecordingActive) return;
    _isRecordingActive = false;
    await _recordingSubscription?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  void addToPlaybackBuffer(Uint8List audioData) {
    if (audioData.isEmpty) return;
    if (!_isBuffering) {
      _isBuffering = true;
      _audioBuffer.clear();
      _updateState(AudioProcessorState.buffering);
    }
    _audioBuffer.addAll(audioData);
  }

  Future<void> signalResponseComplete() async {
    if (!_isBuffering || _audioBuffer.isEmpty) {
      _isBuffering = false;
      if (!_isRecordingActive) await _forceRestartRecording();
      return;
    }
    _isBuffering = false;
    await _playBuffer();
  }

  Future<void> _playBuffer() async {
    if (_player == null || _audioBuffer.isEmpty) return;
    _updateState(AudioProcessorState.playing);
    _waitingForPlayback = true;

    try {
      final pcm = Uint8List.fromList(_audioBuffer);
      _audioBuffer.clear();
      final wav = _pcmToWav(pcm);
      await _player!.setAudioSource(_WavAudioSource(wav));
      await _player!.setVolume(1.0);
      await _player!.seek(Duration.zero);
      await _player!.play();
    } catch (e) {
      _audioBuffer.clear();
      _waitingForPlayback = false;
      await _forceRestartRecording();
    }
  }

  Future<void> interruptPlayback() async {
    _audioBuffer.clear();
    _isBuffering = false;
    _waitingForPlayback = false;
    await _player?.stop();
    await _forceRestartRecording();
  }

  void clearPlaybackBuffer() {
    _audioBuffer.clear();
    _isBuffering = false;
    _waitingForPlayback = false;
    _player?.stop();
    _updateState(
      _isRecordingActive
          ? AudioProcessorState.recording
          : AudioProcessorState.idle,
    );
  }

  Uint8List _pcmToWav(Uint8List pcm) {
    final dataSize = pcm.length;
    final header = ByteData(44);
    header.setUint32(0, 0x46464952, Endian.little);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint32(8, 0x45564157, Endian.little);
    header.setUint32(12, 0x20746d66, Endian.little);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 24000, Endian.little);
    header.setUint32(28, 48000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(36, 0x61746164, Endian.little);
    header.setUint32(40, dataSize, Endian.little);
    final result = Uint8List(44 + dataSize);
    result.setRange(0, 44, header.buffer.asUint8List());
    result.setRange(44, 44 + dataSize, pcm);
    return result;
  }

  void _handleError(String message) {
    _updateState(AudioProcessorState.error);
    onError?.call(message);
  }

  void _updateState(AudioProcessorState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateController.add(newState);
  }

  Future<void> dispose() async {
    await stopRecording();
    clearPlaybackBuffer();
    await _recordingSubscription?.cancel();
    await _playerSubscription?.cancel();
    _recorder.dispose();
    await _player?.dispose();
    await _stateController.close();

    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }
}

class _WavAudioSource extends StreamAudioSource {
  final Uint8List _data;
  _WavAudioSource(this._data);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _data.length;
    return StreamAudioResponse(
      sourceLength: _data.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_data.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
