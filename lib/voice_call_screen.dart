import 'logger.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'voice_call_manager.dart';
import 'voice_mode.dart';



class VoiceCallScreen extends StatefulWidget {
  final String baseUrl;
  final String userId;
  final String email;

  const VoiceCallScreen({
    super.key,
    required this.baseUrl,
    required this.userId,
    required this.email,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with TickerProviderStateMixin {
  late final VoiceCallManager _callManager;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  
  Timer? _durationTimer;
  bool _isInitializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    
    _callManager = VoiceCallManager(baseUrl: widget.baseUrl);
    
    // Setup pulse animation for speaking indicator
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Initialize call manager
      final initialized = await _callManager.initialize();
      if (!initialized) {
        setState(() {
          _initError = _callManager.errorMessage ?? 'Initialization failed';
          _isInitializing = false;
        });
        return;
      }

      // Authenticate
      final authenticated = await _callManager.authenticate(
        userId: widget.userId,
        email: widget.email,
      );
      
      if (!authenticated) {
        setState(() {
          _initError = _callManager.errorMessage ?? 'Authentication failed';
          _isInitializing = false;
        });
        return;
      }

      setState(() {
        _isInitializing = false;
      });
    } catch (e) {
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  @override
  void dispose() {
    _stopDurationTimer();
    _pulseController.dispose();
    _callManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _callManager,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
          child: _isInitializing
              ? _buildLoadingView()
              : _initError != null
                  ? _buildErrorView()
                  : _buildMainView(),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 24),
          Text(
            'Initializing voice service...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.redAccent,
              size: 64,
            ),
            const SizedBox(height: 24),
            Text(
              'Initialization Failed',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 16),
            Text(
              _initError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _isInitializing = true;
                  _initError = null;
                });
                _initialize();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainView() {
    return Consumer<VoiceCallManager>(
      builder: (context, manager, _) {
        return Column(
          children: [
            _buildHeader(manager),
            Expanded(
              child: _buildCenterContent(manager),
            ),
            _buildTranscriptArea(manager),
            _buildControls(manager),
          ],
        );
      },
    );
  }

  Widget _buildHeader(VoiceCallManager manager) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () async {
              if (manager.state != VoiceCallState.idle &&
                  manager.state != VoiceCallState.ended) {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('End Call?'),
                    content: const Text('Are you sure you want to end this call?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('End Call'),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await manager.endCall();
                  if (mounted) Navigator.pop(context);
                }
              } else {
                Navigator.pop(context);
              }
            },
          ),
          const Spacer(),
          if (manager.state != VoiceCallState.idle &&
              manager.state != VoiceCallState.ended)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _getStateColor(manager.state).withOpacity(0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _getStateColor(manager.state),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDuration(manager.callDuration),
                    style: TextStyle(
                      color: _getStateColor(manager.state),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          _buildSettingsButton(manager),
        ],
      ),
    );
  }

  Widget _buildSettingsButton(VoiceCallManager manager) {
    final canChange = manager.state == VoiceCallState.idle ||
        manager.state == VoiceCallState.ended;
        
    return PopupMenuButton<String>(
      icon: const Icon(Icons.settings, color: Colors.white70),
      enabled: canChange,
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            'Model',
            style: TextStyle(
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...VoiceModel.values.map((model) => PopupMenuItem(
              value: 'model_${model.apiName}',
              child: Row(
                children: [
                  Icon(
                    manager.selectedModel == model
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(model.displayName),
                ],
              ),
            )),
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: false,
          child: Text(
            'Voice',
            style: TextStyle(
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...VoiceOption.values.map((voice) => PopupMenuItem(
              value: 'voice_${voice.apiName}',
              child: Row(
                children: [
                  Icon(
                    manager.selectedVoice == voice
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(voice.displayName),
                ],
              ),
            )),
      ],
      onSelected: (value) {
        if (value.startsWith('model_')) {
          final modelName = value.substring(6);
          final model = VoiceModel.values.firstWhere(
            (m) => m.apiName == modelName,
          );
          manager.setCallOptions(model: model);
        } else if (value.startsWith('voice_')) {
          final voiceName = value.substring(6);
          final voice = VoiceOption.values.firstWhere(
            (v) => v.apiName == voiceName,
          );
          manager.setCallOptions(voice: voice);
        }
      },
    );
  }

  Widget _buildCenterContent(VoiceCallManager manager) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStateIndicator(manager),
          const SizedBox(height: 24),
          Text(
            _getStateText(manager.state),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (manager.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              manager.errorMessage!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateIndicator(VoiceCallManager manager) {
    final bool isActive = manager.state == VoiceCallState.listening ||
        manager.state == VoiceCallState.aiSpeaking;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final scale = isActive ? _pulseAnimation.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _getStateColor(manager.state).withOpacity(0.2),
              border: Border.all(
                color: _getStateColor(manager.state),
                width: 3,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: _getStateColor(manager.state).withOpacity(0.4),
                        blurRadius: 20,
                        spreadRadius: 5,
                      )
                    ]
                  : null,
            ),
            child: Icon(
              _getStateIcon(manager.state),
              size: 48,
              color: _getStateColor(manager.state),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTranscriptArea(VoiceCallManager manager) {
    if (manager.state == VoiceCallState.idle ||
        manager.state == VoiceCallState.ended) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 200,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.chat_bubble_outline, color: Colors.white54, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Transcripts',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                '${manager.stats.messageCount} messages',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: manager.transcripts.length +
                  (manager.userPartialTranscript.isNotEmpty ? 1 : 0) +
                  (manager.assistantPartialTranscript.isNotEmpty ? 1 : 0),
              itemBuilder: (context, index) {
                // Show partial transcripts at top (reversed list)
                if (index == 0 && manager.assistantPartialTranscript.isNotEmpty) {
                  return _buildTranscriptBubble(
                    manager.assistantPartialTranscript,
                    isUser: false,
                    isPartial: true,
                  );
                }
                
                int adjustedIndex = index;
                if (manager.assistantPartialTranscript.isNotEmpty) adjustedIndex--;
                
                if (adjustedIndex == 0 && manager.userPartialTranscript.isNotEmpty) {
                  return _buildTranscriptBubble(
                    manager.userPartialTranscript,
                    isUser: true,
                    isPartial: true,
                  );
                }
                
                if (manager.userPartialTranscript.isNotEmpty) adjustedIndex--;
                
                // Reverse index for actual transcripts
                final transcriptIndex = manager.transcripts.length - 1 - adjustedIndex;
                if (transcriptIndex < 0 || transcriptIndex >= manager.transcripts.length) {
                  return const SizedBox.shrink();
                }
                
                final transcript = manager.transcripts[transcriptIndex];
                return _buildTranscriptBubble(
                  transcript.text,
                  isUser: transcript.isUser,
                  isPartial: false,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptBubble(String text, {required bool isUser, required bool isPartial}) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? Colors.blue.withOpacity(isPartial ? 0.3 : 0.5)
              : Colors.grey.withOpacity(isPartial ? 0.2 : 0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withOpacity(isPartial ? 0.7 : 1.0),
            fontStyle: isPartial ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildControls(VoiceCallManager manager) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute button
          _buildControlButton(
            icon: manager.isMuted ? Icons.mic_off : Icons.mic,
            color: manager.isMuted ? Colors.red : Colors.white70,
            onPressed: manager.state == VoiceCallState.connected ||
                    manager.state == VoiceCallState.listening ||
                    manager.state == VoiceCallState.aiSpeaking
                ? manager.toggleMute
                : null,
            label: manager.isMuted ? 'Unmute' : 'Mute',
          ),
          
          // Main call button
          _buildMainCallButton(manager),
          
          // Interrupt button
          _buildControlButton(
            icon: Icons.stop,
            color: Colors.orange,
            onPressed: manager.state == VoiceCallState.aiSpeaking
                ? manager.interrupt
                : null,
            label: 'Stop',
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required Color color,
    VoidCallback? onPressed,
    required String label,
  }) {
    final isEnabled = onPressed != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isEnabled ? color.withOpacity(0.2) : Colors.grey.withOpacity(0.1),
          ),
          child: IconButton(
            icon: Icon(icon),
            color: isEnabled ? color : Colors.grey,
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: isEnabled ? Colors.white70 : Colors.grey,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildMainCallButton(VoiceCallManager manager) {
    final bool isInCall = manager.state != VoiceCallState.idle &&
        manager.state != VoiceCallState.ended &&
        manager.state != VoiceCallState.error;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () async {
            if (isInCall) {
              await manager.endCall();
            } else {
              _startDurationTimer();
              await manager.startCall();
              if (manager.state == VoiceCallState.error) {
                _stopDurationTimer();
              }
            }
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isInCall ? Colors.red : Colors.green,
              boxShadow: [
                BoxShadow(
                  color: (isInCall ? Colors.red : Colors.green).withOpacity(0.4),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              isInCall ? Icons.call_end : Icons.call,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isInCall ? 'End' : 'Start',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Color _getStateColor(VoiceCallState state) {
    switch (state) {
      case VoiceCallState.idle:
      case VoiceCallState.ended:
        return Colors.grey;
      case VoiceCallState.initializing:
      case VoiceCallState.connecting:
        return Colors.amber;
      case VoiceCallState.connected:
        return Colors.green;
      case VoiceCallState.listening:
        return Colors.blue;
      case VoiceCallState.aiSpeaking:
        return Colors.purple;
      case VoiceCallState.error:
        return Colors.red;
    }
  }

  IconData _getStateIcon(VoiceCallState state) {
    switch (state) {
      case VoiceCallState.idle:
      case VoiceCallState.ended:
        return Icons.phone;
      case VoiceCallState.initializing:
      case VoiceCallState.connecting:
        return Icons.sync;
      case VoiceCallState.connected:
        return Icons.headset_mic;
      case VoiceCallState.listening:
        return Icons.mic;
      case VoiceCallState.aiSpeaking:
        return Icons.volume_up;
      case VoiceCallState.error:
        return Icons.error;
    }
  }

  String _getStateText(VoiceCallState state) {
    switch (state) {
      case VoiceCallState.idle:
        return 'Ready to start';
      case VoiceCallState.initializing:
        return 'Initializing...';
      case VoiceCallState.connecting:
        return 'Connecting...';
      case VoiceCallState.connected:
        return 'Connected';
      case VoiceCallState.listening:
        return 'Listening...';
      case VoiceCallState.aiSpeaking:
        return 'AI Speaking...';
      case VoiceCallState.error:
        return 'Error';
      case VoiceCallState.ended:
        return 'Call Ended';
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString();
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}
