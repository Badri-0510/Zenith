import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:flutter/services.dart';

class SitupCounterApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Situp Counter',
      theme: ThemeData(
        primarySwatch: Colors.purple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: SitupCounterScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SitupCounterScreen extends StatefulWidget {
  @override
  _SitupCounterScreenState createState() => _SitupCounterScreenState();
}

class _SitupCounterScreenState extends State<SitupCounterScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  bool _isDetecting = false;
  bool _isStreaming = false;
  bool _isCameraInitialized = false;
  CustomPaint? _customPaint;
  
  // Situp counting variables
  int _situpCount = 0;
  bool _isInUpPosition = false;
  double _lastTorsoAngle = 0;
  double _lastKneeAngle = 0;
  DateTime? _lastProcessTime;
  String _statusMessage = "Position yourself on your side and start detection";
  
  // Form validation flags
  bool _hasProperKneeAngle = false;
  bool _isInStartingPosition = false;
  String _formFeedback = "";
  
  // Performance optimization
  int _frameSkipCounter = 0;
  static const int FRAME_SKIP = 2;
  static const double MIN_CONFIDENCE = 0.3;
  
  // Situp-specific thresholds
  static const double DOWN_TORSO_ANGLE_THRESHOLD = 95; // Lying down position
  static const double UP_TORSO_ANGLE_THRESHOLD = 120; // Sitting up position
  static const double MIN_KNEE_ANGLE_THRESHOLD = 60; // Knees bent properly
  static const double MAX_KNEE_ANGLE_THRESHOLD = 120; // Not too bent
  static const double STARTING_POSITION_THRESHOLD = 30; // Almost flat

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializePoseDetector();
    _initializeCamera();
  }

  void _initializePoseDetector() {
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        mode: PoseDetectionMode.stream,
        model: PoseDetectionModel.accurate,
      ),
    );
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _statusMessage = "No cameras available";
        });
        return;
      }

      final camera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _statusMessage = "Camera ready. Press Start to begin detection.";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Camera initialization failed: $e";
      });
      debugPrint("Camera initialization error: $e");
    }
  }

  void _startDetection() {
    if (!_isCameraInitialized || _isStreaming || _cameraController == null) {
      return;
    }
    
    try {
      _cameraController!.startImageStream(_processCameraImage);
      setState(() {
        _isStreaming = true;
        _statusMessage = "Detection started. Lie on your side with knees bent!";
        _situpCount = 0;
        _isInUpPosition = false;
        _hasProperKneeAngle = false;
        _isInStartingPosition = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Failed to start detection: $e";
      });
    }
  }

  void _stopDetection() {
    if (!_isCameraInitialized || !_isStreaming || _cameraController == null) {
      return;
    }
    
    try {
      _cameraController!.stopImageStream();
      setState(() {
        _isStreaming = false;
        _customPaint = null;
        _statusMessage = "Detection stopped. Total valid situps: $_situpCount";
        _formFeedback = "";
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Failed to stop detection: $e";
      });
    }
  }

  void _processCameraImage(CameraImage image) async {
    if (_isDetecting || _poseDetector == null) return;
    
    final now = DateTime.now();
    if (_lastProcessTime != null && 
        now.difference(_lastProcessTime!).inMilliseconds < 100) {
      return;
    }
    _lastProcessTime = now;

    _isDetecting = true;

    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isDetecting = false;
        return;
      }

      final poses = await _poseDetector!.processImage(inputImage);

      if (mounted) {
        if (poses.isNotEmpty && poses.first.landmarks.isNotEmpty) {
          _processPoseForSitups(poses.first);
          _updateCustomPaint(poses.first, image);
        } else {
          setState(() {
            _customPaint = null;
            if (_isStreaming) {
              _statusMessage = "No pose detected. Ensure your full body is visible from the side.";
              _formFeedback = "";
            }
          });
        }
      }
    } catch (e) {
      debugPrint("Pose detection error: $e");
      if (mounted) {
        setState(() {
          _statusMessage = "Detection error. Please restart.";
        });
      }
    }

    _isDetecting = false;
  }

  InputImage? _buildInputImage(CameraImage image) {
    try {
      final bytes = _concatenatePlanes(image.planes, image.width, image.height);
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: _getImageRotation(),
          format: InputImageFormat.yuv420,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint("Failed to build input image: $e");
      return null;
    }
  }

  Uint8List _concatenatePlanes(List<Plane> planes, int width, int height) {
    final allBytes = <int>[];
    final yPlane = planes[0];
    for (int i = 0; i < height; i++) {
      allBytes.addAll(yPlane.bytes.sublist(i * yPlane.bytesPerRow, i * yPlane.bytesPerRow + width));
    }
    final uvWidth = width ~/ 2;
    final uvHeight = height ~/ 2;
    for (final plane in planes.sublist(1)) {
      for (int i = 0; i < uvHeight; i++) {
        allBytes.addAll(plane.bytes.sublist(i * plane.bytesPerRow, i * plane.bytesPerRow + uvWidth));
      }
    }
    return Uint8List.fromList(allBytes);
  }

  InputImageRotation _getImageRotation() {
    if (_cameraController == null) return InputImageRotation.rotation0deg;
    
    final sensorOrientation = _cameraController!.description.sensorOrientation;
    
    switch (sensorOrientation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  void _processPoseForSitups(Pose pose) {
    final landmarks = pose.landmarks;
    
    // Get all required landmarks for side view situp analysis
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final leftHip = landmarks[PoseLandmarkType.leftHip];
    final rightHip = landmarks[PoseLandmarkType.rightHip];
    final leftKnee = landmarks[PoseLandmarkType.leftKnee];
    final rightKnee = landmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = landmarks[PoseLandmarkType.rightAnkle];
    final nose = landmarks[PoseLandmarkType.nose];

    // Check if all required landmarks are detected
    final requiredLandmarks = [
      leftShoulder, rightShoulder, leftHip, rightHip, 
      leftKnee, rightKnee, nose
    ];
    
    if (requiredLandmarks.any((landmark) => 
        landmark == null || landmark.likelihood < MIN_CONFIDENCE)) {
      setState(() {
        _statusMessage = "Position yourself on your side so your full body is visible";
        _formFeedback = "Need to see: head, shoulders, hips, knees from side view";
      });
      return;
    }

    // Calculate average positions for side view
    final avgShoulder = Offset(
      (leftShoulder!.x + rightShoulder!.x) / 2,
      (leftShoulder.y + rightShoulder.y) / 2
    );
    final avgHip = Offset(
      (leftHip!.x + rightHip!.x) / 2,
      (leftHip.y + rightHip.y) / 2
    );
    final avgKnee = Offset(
      (leftKnee!.x + rightKnee!.x) / 2,
      (leftKnee.y + rightKnee.y) / 2
    );
    final avgAnkle = leftAnkle != null && rightAnkle != null ? Offset(
      (leftAnkle.x + rightAnkle.x) / 2,
      (leftAnkle.y + rightAnkle.y) / 2
    ) : null;

    // Calculate torso angle (shoulder to hip relative to horizontal)
    final torsoVector = avgHip - avgShoulder;
    final horizontalVector = Offset(1, 0);
    final torsoAngle = _calculateAngleFromVectors(torsoVector, horizontalVector);
    
    // Calculate knee angle (hip-knee-ankle)
    double kneeAngle = 90; // Default if ankle not detected
    if (avgAnkle != null) {
      kneeAngle = _calculateAngleFromPoints(avgHip, avgKnee, avgAnkle);
    }
    
    _lastTorsoAngle = torsoAngle;
    _lastKneeAngle = kneeAngle;

    // Validate situp form
    _validateSitupForm(torsoAngle, kneeAngle, avgShoulder, avgHip, nose!);

    // Only count situp if form is proper
    if (_hasProperKneeAngle && _isInStartingPosition) {
      _countSitup(torsoAngle);
    } else {
      _provideSitupFormFeedback(torsoAngle, kneeAngle);
    }
  }

  void _validateSitupForm(double torsoAngle, double kneeAngle, 
                         Offset avgShoulder, Offset avgHip, PoseLandmark nose) {
    List<String> formIssues = [];
    
    // Check knee angle for proper bent knees
    if (kneeAngle < MIN_KNEE_ANGLE_THRESHOLD) {
      _hasProperKneeAngle = false;
      formIssues.add("Bend knees more");
    } else if (kneeAngle > MAX_KNEE_ANGLE_THRESHOLD) {
      _hasProperKneeAngle = false;
      formIssues.add("Don't over-bend knees");
    } else {
      _hasProperKneeAngle = true;
    }

    // Check if person is in starting position (lying down)
    if (torsoAngle > STARTING_POSITION_THRESHOLD) {
      _isInStartingPosition = true;
    } else {
      _isInStartingPosition = false;
      formIssues.add("Lie down more to start position");
    }

    // Check head position relative to shoulders and hips
    final headTorsoAlignment = _checkHeadAlignment(nose, avgShoulder, avgHip);
    if (!headTorsoAlignment) {
      formIssues.add("Keep head aligned with torso");
    }

    setState(() {
      _formFeedback = formIssues.isEmpty ? "✓ Good form!" : formIssues.join(", ");
    });
  }

  bool _checkHeadAlignment(PoseLandmark nose, Offset avgShoulder, Offset avgHip) {
    // Check if head is reasonably aligned with torso line
    final torsoLine = avgHip - avgShoulder;
    final headToShoulder = Offset(nose.x - avgShoulder.dx, nose.y - avgShoulder.dy);
    
    // Calculate if head is within reasonable alignment
    final crossProduct = torsoLine.dx * headToShoulder.dy - torsoLine.dy * headToShoulder.dx;
    final alignmentThreshold = 50; // Adjust based on testing
    
    return crossProduct.abs() < alignmentThreshold;
  }

  void _countSitup(double torsoAngle) {
    if (!_isInUpPosition && torsoAngle > UP_TORSO_ANGLE_THRESHOLD) {
      _isInUpPosition = true;
      setState(() {
        _statusMessage = "Up position - Lower down! ✓ Form good";
      });
    } else if (_isInUpPosition && torsoAngle < DOWN_TORSO_ANGLE_THRESHOLD) {
      _isInUpPosition = false;
      _situpCount++;
      HapticFeedback.lightImpact();
      setState(() {
        _statusMessage = "Situp #$_situpCount completed! Excellent form! 💪";
      });
    } else {
      setState(() {
        if (_isInUpPosition) {
          _statusMessage = "Lower down! (Angle: ${torsoAngle.toInt()}°) ✓ Form good";
        } else {
          _statusMessage = "Sit up! (Angle: ${torsoAngle.toInt()}°) ✓ Form good";
        }
      });
    }
  }

  void _provideSitupFormFeedback(double torsoAngle, double kneeAngle) {
    setState(() {
      _statusMessage = "Fix form before continuing - Torso: ${torsoAngle.toInt()}°, Knee: ${kneeAngle.toInt()}°";
    });
  }

  double _calculateAngleFromVectors(Offset vector1, Offset vector2) {
    final dotProduct = vector1.dx * vector2.dx + vector1.dy * vector2.dy;
    final magnitude1 = sqrt(vector1.dx * vector1.dx + vector1.dy * vector1.dy);
    final magnitude2 = sqrt(vector2.dx * vector2.dx + vector2.dy * vector2.dy);
    
    if (magnitude1 == 0 || magnitude2 == 0) return 0;
    
    final cosAngle = dotProduct / (magnitude1 * magnitude2);
    final clampedCos = cosAngle.clamp(-1.0, 1.0);
    final angleRad = acos(clampedCos);
    
    return angleRad * 180 / pi;
  }

  double _calculateAngleFromPoints(Offset point1, Offset point2, Offset point3) {
    final vector1 = Offset(point1.dx - point2.dx, point1.dy - point2.dy);
    final vector2 = Offset(point3.dx - point2.dx, point3.dy - point2.dy);
    
    final dotProduct = vector1.dx * vector2.dx + vector1.dy * vector2.dy;
    final magnitude1 = sqrt(vector1.dx * vector1.dx + vector1.dy * vector1.dy);
    final magnitude2 = sqrt(vector2.dx * vector2.dx + vector2.dy * vector2.dy);
    
    if (magnitude1 == 0 || magnitude2 == 0) return 0;
    
    final cosAngle = dotProduct / (magnitude1 * magnitude2);
    final clampedCos = cosAngle.clamp(-1.0, 1.0);
    final angleRad = acos(clampedCos);
    
    return angleRad * 180 / pi;
  }

  void _updateCustomPaint(Pose pose, CameraImage image) {
    final painter = SitupPosePainter(
      pose,
      Size(image.width.toDouble(), image.height.toDouble()),
      _cameraController!.description.sensorOrientation,
      _lastTorsoAngle,
      _lastKneeAngle,
      _isInUpPosition,
      _hasProperKneeAngle,
      _isInStartingPosition,
    );
    
    setState(() {
      _customPaint = CustomPaint(painter: painter);
    });
  }

  void _resetCounter() {
    setState(() {
      _situpCount = 0;
      _isInUpPosition = false;
      _hasProperKneeAngle = false;
      _isInStartingPosition = false;
      _formFeedback = "";
      _statusMessage = _isStreaming ? "Counter reset. Get into proper position!" : "Counter reset.";
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _stopDetection();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDetection();
    _poseDetector?.close();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Zenith Situp Counter'),
        backgroundColor: Colors.purple.shade800,
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_isCameraInitialized) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.purple),
            SizedBox(height: 20),
            Text(
              _statusMessage,
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_cameraController!),
        if (_customPaint != null) _customPaint!,
        
        // Top info panel
        Positioned(
          top: 20,
          left: 20,
          right: 20,
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.8),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Valid Situps: $_situpCount',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: (_hasProperKneeAngle && _isInStartingPosition) 
                            ? Colors.green 
                            : Colors.red.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        (_hasProperKneeAngle && _isInStartingPosition) ? 'GOOD FORM' : 'FIX FORM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  _statusMessage,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                ),
                if (_formFeedback.isNotEmpty) ...[
                  SizedBox(height: 8),
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _formFeedback.contains("✓") 
                          ? Colors.green.withOpacity(0.2)
                          : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _formFeedback,
                      style: TextStyle(
                        color: _formFeedback.contains("✓") ? Colors.green : Colors.red,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        
        // Control buttons
        Positioned(
          bottom: 40,
          left: 20,
          right: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                onPressed: _isStreaming ? null : _startDetection,
                icon: Icons.play_arrow,
                label: 'Start',
                color: Colors.green,
              ),
              _buildControlButton(
                onPressed: _isStreaming ? _stopDetection : null,
                icon: Icons.stop,
                label: 'Stop',
                color: Colors.red,
              ),
              _buildControlButton(
                onPressed: _resetCounter,
                icon: Icons.refresh,
                label: 'Reset',
                color: Colors.orange,
              ),
            ],
          ),
        ),
        
        // Instructions
        if (!_isStreaming)
          Positioned(
            bottom: 140,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Smart Situp Form Detection:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Lie on your side with full body visible\n'
                    '• Bend knees at 60-120 degree angle\n'
                    '• Keep head aligned with torso\n'
                    '• Start lying down, sit up to 90+ degrees\n'
                    '• Only proper form situps are counted',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControlButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: onPressed != null ? color : Colors.grey,
            foregroundColor: Colors.white,
            padding: EdgeInsets.all(16),
            shape: CircleBorder(),
            elevation: 4,
          ),
          child: Icon(icon, size: 28),
        ),
        SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class SitupPosePainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  final int rotation;
  final double torsoAngle;
  final double kneeAngle;
  final bool isInUpPosition;
  final bool hasProperKneeAngle;
  final bool isInStartingPosition;

  SitupPosePainter(
    this.pose,
    this.imageSize,
    this.rotation,
    this.torsoAngle,
    this.kneeAngle,
    this.isInUpPosition,
    this.hasProperKneeAngle,
    this.isInStartingPosition,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    // Different colors for different states
    Color pointColor;
    Color lineColor;
    
    if (hasProperKneeAngle && isInStartingPosition) {
      pointColor = isInUpPosition ? Colors.orange : Colors.green;
      lineColor = isInUpPosition ? Colors.orange.withOpacity(0.8) : Colors.green.withOpacity(0.8);
    } else {
      pointColor = Colors.red;
      lineColor = Colors.red.withOpacity(0.8);
    }

    final pointPaint = Paint()
      ..color = pointColor
      ..strokeWidth = 8
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    // Torso line paint (special color for torso angle)
    final torsoLinePaint = Paint()
      ..color = isInStartingPosition ? Colors.green : Colors.red
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;

    // Draw key landmarks for situp analysis
    final keyLandmarks = [
      PoseLandmarkType.nose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightAnkle,
    ];

    // Draw landmark points
    for (final landmarkType in keyLandmarks) {
      final landmark = pose.landmarks[landmarkType];
      if (landmark != null && landmark.likelihood > 0.3) {
        final offset = Offset(
          landmark.x * scaleX,
          landmark.y * scaleY,
        );
        canvas.drawCircle(offset, 6, pointPaint);
      }
    }

    // Draw torso line (shoulder to hip)
    _drawConnection(canvas, size, torsoLinePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
    _drawConnection(canvas, size, torsoLinePaint, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
    
    // Draw leg connections
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
    
    // Draw head to shoulder connection
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.nose, PoseLandmarkType.leftShoulder);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.nose, PoseLandmarkType.rightShoulder);
    
    // Draw hip connection
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);

    // Draw angle information
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      shadows: [Shadow(color: Colors.black, blurRadius: 3)],
    );

    _drawText(canvas, 'Torso: ${torsoAngle.toInt()}°', Offset(20, size.height - 120), textStyle);
    _drawText(canvas, 'Knee: ${kneeAngle.toInt()}°', Offset(20, size.height - 100), textStyle);
    
    // Form status
    final formStatus = (hasProperKneeAngle && isInStartingPosition) ? 'GOOD FORM ✓' : 'FIX FORM ⚠';
    final formColor = (hasProperKneeAngle && isInStartingPosition) ? Colors.green : Colors.red;
    _drawText(canvas, formStatus, Offset(20, size.height - 80), 
        textStyle.copyWith(color: formColor, fontSize: 16));
  }

  void _drawConnection(Canvas canvas, Size size, Paint paint, 
      PoseLandmarkType from, PoseLandmarkType to) {
    final fromLandmark = pose.landmarks[from];
    final toLandmark = pose.landmarks[to];
    
    if (fromLandmark != null && toLandmark != null &&
        fromLandmark.likelihood > 0.3 && toLandmark.likelihood > 0.3) {
      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;
      
      canvas.drawLine(
        Offset(fromLandmark.x * scaleX, fromLandmark.y * scaleY),
        Offset(toLandmark.x * scaleX, toLandmark.y * scaleY),
        paint,
      );
    }
  }

  void _drawText(Canvas canvas, String text, Offset position, TextStyle style) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}