
class VoiceSessionConfig {
  final String sessionId;
  final String model;
  final String voice;
  final bool vadEnabled;
  final double vadThreshold;
  const VoiceSessionConfig({
    required this.sessionId,
    required this.model,
    this.voice = 'alloy',
    this.vadEnabled = true,
    this.vadThreshold = 0.6,
  });
  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'model': model,
    'voice': voice,
    'vad_enabled': vadEnabled,
    'vad_threshold': vadThreshold,
  };
}
/// Available voice models
enum VoiceModel {
  gptRealtime('gpt-4o-realtime-preview', 'GPT-4o Realtime'),
  gptRealtimeMini('gpt-4o-mini-realtime-preview', 'GPT-4o Mini Realtime');
  final String apiName;
  final String displayName;
  const VoiceModel(this.apiName, this.displayName);
}
