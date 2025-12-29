
import 'logger.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lottie/lottie.dart';

import 'voice_call_manager.dart';
import 'voice_mode.dart';

enum AnimationType {
  particleSphere, // Custom 3D particle sphere like Perplexity
  lottie, // Use provided Lottie animation
}

class VoiceCallScreen extends StatefulWidget {
  final String baseUrl;
  final String userId;
  final String email;
  final AnimationType animationType;

  const VoiceCallScreen({
    super.key,
    required this.baseUrl,
    required this.userId,
    required this.email,
    this.animationType = AnimationType.particleSphere, // Default to particle sphere
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with TickerProviderStateMixin {
  late final VoiceCallManager _callManager;
  late final AnimationController _rotationController;
  late final AnimationController _pulseController;
  late final AnimationController _glowController;

  Timer? _durationTimer;
  bool _isInitializing = true;
  String? _initError;

  // Colors matching Perplexity design
  static const Color _backgroundColor = Color(0xFF0D0D0D);
  static const Color _listeningColor = Color(0xFFE8A54B); // Amber/Orange - User speaking/listening
  static const Color _speakingColor = Color(0xFF4ECDC4); // Teal/Cyan - AI speaking
  static const Color _connectingColor = Color(0xFF6B7280); // Gray - Connecting state

  @override
  void initState() {
    super.initState();

    _callManager = VoiceCallManager(baseUrl: widget.baseUrl);

    // Rotation for the sphere/lottie
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    // Pulse animation for breathing effect
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    // Glow animation for ambient effect
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final initialized = await _callManager.initialize();
      if (!initialized) {
        setState(() {
          _initError = _callManager.errorMessage ?? 'Initialization failed';
          _isInitializing = false;
        });
        return;
      }

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

      // Auto-start the call after initialization
      _startCall();
    } catch (e) {
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
    }
  }

  Future<void> _startCall() async {
    _startDurationTimer();
    await _callManager.startCall();
    if (_callManager.state == VoiceCallState.error) {
      _stopDurationTimer();
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
    _rotationController.dispose();
    _pulseController.dispose();
    _glowController.dispose();
    _callManager.dispose();
    super.dispose();
  }

  /// Get the color for the current voice call state
  Color _getStateColor(VoiceCallState state) {
    switch (state) {
      case VoiceCallState.listening:
      case VoiceCallState.connected:
        return _listeningColor;
      case VoiceCallState.aiSpeaking:
        return _speakingColor;
      case VoiceCallState.initializing:
      case VoiceCallState.connecting:
        return _connectingColor;
      default:
        return _connectingColor;
    }
  }

  /// Get the status text for the current state
  String _getStatusText(VoiceCallState state) {
    switch (state) {
      case VoiceCallState.idle:
        return 'Tap to start';
      case VoiceCallState.initializing:
        return 'Initializing...';
      case VoiceCallState.connecting:
        return 'Connecting';
      case VoiceCallState.connected:
      case VoiceCallState.listening:
        return 'Say something...';
      case VoiceCallState.aiSpeaking:
        return '';
      case VoiceCallState.error:
        return 'Error';
      case VoiceCallState.ended:
        return 'Call ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _callManager,
      child: Scaffold(
        backgroundColor: _backgroundColor,
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
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [
            _connectingColor.withOpacity(0.1),
            _backgroundColor,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: AnimatedBuilder(
                animation: _rotationController,
                builder: (context, child) {
                  if (widget.animationType == AnimationType.lottie) {
                    return Lottie.asset(
                      'assets/AI_logo_Foriday.json',
                      fit: BoxFit.contain,
                    );
                  }
                  return CustomPaint(
                    painter: ParticleSpherePainter(
                      rotationX: _rotationController.value * 2 * math.pi,
                      rotationY: _rotationController.value * 2 * math.pi * 0.7,
                      color: _connectingColor,
                      glowIntensity: 0.3,
                    ),
                    size: const Size(150, 150),
                  );
                },
              ),
            ),
            const SizedBox(height: 48),
            const Text(
              'Connecting',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 16,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [
            Colors.red.withOpacity(0.1),
            _backgroundColor,
          ],
        ),
      ),
      child: Center(
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
              const Text(
                'Connection Failed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _initError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isInitializing = true;
                    _initError = null;
                  });
                  _initialize();
                },
                child: const Text(
                  'Retry',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainView() {
    return Consumer<VoiceCallManager>(
      builder: (context, manager, _) {
        final stateColor = _getStateColor(manager.state);
        final isActive = manager.state == VoiceCallState.listening ||
            manager.state == VoiceCallState.aiSpeaking ||
            manager.state == VoiceCallState.connected;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.2,
              colors: [
                stateColor.withOpacity(isActive ? 0.15 : 0.05),
                _backgroundColor,
              ],
            ),
          ),
          child: Stack(
            children: [
              // Settings button (top right)
              Positioned(
                top: 16,
                right: 16,
                child: _buildSettingsButton(manager),
              ),

              // Main content
              Column(
                children: [
                  const SizedBox(height: 80),

                  // Transcript area
                  Expanded(
                    child: _buildTranscriptArea(manager),
                  ),

                  // Animation sphere
                  _buildAnimationSphere(manager),

                  const SizedBox(height: 32),

                  // Bottom controls
                  _buildBottomControls(manager),

                  const SizedBox(height: 40),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsButton(VoiceCallManager manager) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.settings_outlined, color: Colors.white54, size: 24),
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (context) => [
        const PopupMenuItem(
          enabled: false,
          child: Text(
            'Voice',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...VoiceOption.values.map((voice) => PopupMenuItem(
              value: 'voice_${voice.apiName}',
              child: Row(
                children: [
                  Icon(
                    manager.selectedVoice == voice
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 18,
                    color: manager.selectedVoice == voice
                        ? _listeningColor
                        : Colors.white38,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    voice.displayName,
                    style: TextStyle(
                      color: manager.selectedVoice == voice
                          ? Colors.white
                          : Colors.white70,
                    ),
                  ),
                ],
              ),
            )),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          child: Text(
            'Model',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...VoiceModel.values.map((model) => PopupMenuItem(
              value: 'model_${model.apiName}',
              child: Row(
                children: [
                  Icon(
                    manager.selectedModel == model
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 18,
                    color: manager.selectedModel == model
                        ? _listeningColor
                        : Colors.white38,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    model.displayName,
                    style: TextStyle(
                      color: manager.selectedModel == model
                          ? Colors.white
                          : Colors.white70,
                    ),
                  ),
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

  Widget _buildTranscriptArea(VoiceCallManager manager) {
    final hasTranscript = manager.assistantPartialTranscript.isNotEmpty ||
        manager.transcripts.isNotEmpty;

    if (!hasTranscript) {
      return const SizedBox.shrink();
    }

    // Get the current transcript to display
    String displayText = '';
    if (manager.assistantPartialTranscript.isNotEmpty) {
      displayText = manager.assistantPartialTranscript;
    } else if (manager.transcripts.isNotEmpty) {
      // Get the last assistant transcript
      final lastAssistant = manager.transcripts
          .where((t) => !t.isUser)
          .toList();
      if (lastAssistant.isNotEmpty) {
        displayText = lastAssistant.last.text;
      }
    }

    if (displayText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Align(
        alignment: Alignment.topLeft,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 24,
            fontWeight: FontWeight.w400,
            height: 1.4,
            fontFamily: null, // Uses default system font
          ),
          child: Text(
            displayText,
            textAlign: TextAlign.left,
          ),
        ),
      ),
    );
  }

  Widget _buildAnimationSphere(VoiceCallManager manager) {
    final stateColor = _getStateColor(manager.state);
    final isActive = manager.state == VoiceCallState.listening ||
        manager.state == VoiceCallState.aiSpeaking ||
        manager.state == VoiceCallState.connected;

    final hasTranscript = manager.assistantPartialTranscript.isNotEmpty ||
        manager.transcripts.isNotEmpty;

    final sphereSize = hasTranscript ? 120.0 : 220.0;

    return AnimatedBuilder(
      animation: Listenable.merge([_rotationController, _pulseController, _glowController]),
      builder: (context, child) {
        final glowValue = 0.3 + (_glowController.value * 0.4);
        final pulseScale = 1.0 + (_pulseController.value * 0.05);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: sphereSize,
          height: sphereSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow effect
              if (isActive)
                Container(
                  width: sphereSize * 1.5,
                  height: sphereSize * 1.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: stateColor.withOpacity(glowValue * 0.5),
                        blurRadius: 80,
                        spreadRadius: 20,
                      ),
                    ],
                  ),
                ),

              // Main animation (particle sphere or Lottie)
              Transform.scale(
                scale: pulseScale,
                child: SizedBox(
                  width: sphereSize,
                  height: sphereSize,
                  child: widget.animationType == AnimationType.lottie
                      ? ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            stateColor.withOpacity(0.9),
                            BlendMode.modulate,
                          ),
                          child: Lottie.asset(
                            'assets/AI_logo_Foriday.json',
                            fit: BoxFit.contain,
                          ),
                        )
                      : CustomPaint(
                          painter: ParticleSpherePainter(
                            rotationX: _rotationController.value * 2 * math.pi,
                            rotationY: _rotationController.value * 2 * math.pi * 0.7,
                            color: stateColor,
                            glowIntensity: isActive ? glowValue : 0.2,
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomControls(VoiceCallManager manager) {
    final isInCall = manager.state != VoiceCallState.idle &&
        manager.state != VoiceCallState.ended &&
        manager.state != VoiceCallState.error;

    final statusText = _getStatusText(manager.state);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Close button (left)
          _buildCircleButton(
            icon: Icons.close,
            onPressed: () async {
              if (isInCall) {
                await manager.endCall();
              }
              if (mounted) Navigator.pop(context);
            },
            backgroundColor: Colors.white.withOpacity(0.1),
            iconColor: Colors.white70,
          ),

          // Status text (center)
          Expanded(
            child: Center(
              child: Text(
                statusText,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),

          // Microphone button (right)
          _buildCircleButton(
            icon: manager.isMuted ? Icons.mic_off : Icons.mic,
            onPressed: isInCall ? manager.toggleMute : null,
            backgroundColor: manager.isMuted
                ? Colors.red.withOpacity(0.2)
                : Colors.white.withOpacity(0.1),
            iconColor: manager.isMuted ? Colors.red : Colors.white70,
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    VoidCallback? onPressed,
    required Color backgroundColor,
    required Color iconColor,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor,
        ),
        child: Icon(
          icon,
          color: iconColor,
          size: 24,
        ),
      ),
    );
  }
}

/// Custom painter that creates a 3D particle sphere effect like Perplexity
/// 
/// This creates a sphere made of many small particles/dots that rotate
/// and have depth-based opacity and size for a 3D effect.
class ParticleSpherePainter extends CustomPainter {
  final double rotationX;
  final double rotationY;
  final Color color;
  final double glowIntensity;

  ParticleSpherePainter({
    required this.rotationX,
    required this.rotationY,
    required this.color,
    this.glowIntensity = 0.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 * 0.85;

    // Generate points on a sphere using fibonacci spiral for even distribution
    final points = <_Point3D>[];
    const numPoints = 800; // Number of particles
    final goldenRatio = (1 + math.sqrt(5)) / 2;

    for (int i = 0; i < numPoints; i++) {
      final y = 1 - (i / (numPoints - 1)) * 2; // y goes from 1 to -1
      final radiusAtY = math.sqrt(1 - y * y);
      final theta = 2 * math.pi * i / goldenRatio;

      final x = math.cos(theta) * radiusAtY;
      final z = math.sin(theta) * radiusAtY;

      points.add(_Point3D(x, y, z));
    }

    // Apply rotation
    final rotatedPoints = points.map((p) {
      // Rotate around Y axis
      var x = p.x * math.cos(rotationY) - p.z * math.sin(rotationY);
      var z = p.x * math.sin(rotationY) + p.z * math.cos(rotationY);
      var y = p.y;

      // Rotate around X axis
      final newY = y * math.cos(rotationX) - z * math.sin(rotationX);
      final newZ = y * math.sin(rotationX) + z * math.cos(rotationX);

      return _Point3D(x, newY, newZ);
    }).toList();

    // Sort by Z for proper depth rendering (back to front)
    rotatedPoints.sort((a, b) => a.z.compareTo(b.z));

    // Draw particles
    for (final point in rotatedPoints) {
      // Project 3D point to 2D
      final screenX = center.dx + point.x * radius;
      final screenY = center.dy + point.y * radius;

      // Calculate depth-based properties
      final depth = (point.z + 1) / 2; // Normalize to 0-1
      final particleSize = 1.0 + depth * 2.5;
      final opacity = 0.2 + depth * 0.8;

      final paint = Paint()
        ..color = color.withOpacity(opacity * glowIntensity)
        ..style = PaintingStyle.fill;

      // Add glow effect for front particles
      if (depth > 0.6) {
        final glowPaint = Paint()
          ..color = color.withOpacity(0.3 * glowIntensity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        canvas.drawCircle(
          Offset(screenX, screenY),
          particleSize * 1.5,
          glowPaint,
        );
      }

      canvas.drawCircle(
        Offset(screenX, screenY),
        particleSize,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ParticleSpherePainter oldDelegate) {
    return oldDelegate.rotationX != rotationX ||
        oldDelegate.rotationY != rotationY ||
        oldDelegate.color != color ||
        oldDelegate.glowIntensity != glowIntensity;
  }
}

/// Helper class for 3D point representation
class _Point3D {
  final double x;
  final double y;
  final double z;

  _Point3D(this.x, this.y, this.z);
}