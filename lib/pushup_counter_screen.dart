import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:flutter/services.dart';

class PushupCounterApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pushup Counter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: PushupCounterScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class PushupCounterScreen extends StatefulWidget {
  @override
  _PushupCounterScreenState createState() => _PushupCounterScreenState();
}

class _PushupCounterScreenState extends State<PushupCounterScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  bool _isDetecting = false;
  bool _isStreaming = false;
  bool _isCameraInitialized = false;
  CustomPaint? _customPaint;
  
  // Pushup counting variables
  int _pushupCount = 0;
  bool _isInDownPosition = false;
  double _lastShoulderElbowAngle = 0;
  double _lastHipAngle = 0;
  double _lastBodyVerticalPosition = 0;
  DateTime? _lastProcessTime;
  String _statusMessage = "Position yourself and start detection";
  
  // Form validation flags
  bool _hasProperHipAngle = false;
  bool _isInPlankPosition = false;
  String _formFeedback = "";
  
  // Performance optimization
  int _frameSkipCounter = 0;
  static const int FRAME_SKIP = 2;
  static const double MIN_CONFIDENCE = 0.3;
  
  // Enhanced thresholds
  static const double DOWN_ELBOW_ANGLE_THRESHOLD = 90;
  static const double UP_ELBOW_ANGLE_THRESHOLD = 160;
  static const double MIN_HIP_ANGLE_THRESHOLD = 150; // Straight body line
  static const double MAX_HIP_SAG_THRESHOLD = 210; // Hip sagging too much
  static const double GROUND_PROXIMITY_THRESHOLD = 50; // Distance from ground check

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
        _statusMessage = "Detection started. Get into proper plank position!";
        _pushupCount = 0;
        _isInDownPosition = false;
        _hasProperHipAngle = false;
        _isInPlankPosition = false;
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
        _statusMessage = "Detection stopped. Total valid pushups: $_pushupCount";
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
    
    _frameSkipCounter++;
    if (_frameSkipCounter % FRAME_SKIP != 0) return;
    
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
          _processPoseForPushups(poses.first);
          _updateCustomPaint(poses.first, image);
        } else {
          setState(() {
            _customPaint = null;
            if (_isStreaming) {
              _statusMessage = "No pose detected. Ensure your full body is visible.";
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

  void _processPoseForPushups(Pose pose) {
    final landmarks = pose.landmarks;
    
    // Get all required landmarks
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final leftElbow = landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = landmarks[PoseLandmarkType.rightElbow];
    final leftWrist = landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = landmarks[PoseLandmarkType.rightWrist];
    final leftHip = landmarks[PoseLandmarkType.leftHip];
    final rightHip = landmarks[PoseLandmarkType.rightHip];
    final leftKnee = landmarks[PoseLandmarkType.leftKnee];
    final rightKnee = landmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = landmarks[PoseLandmarkType.rightAnkle];

    // Check if all required landmarks are detected
    final requiredLandmarks = [
      leftShoulder, rightShoulder, leftElbow, rightElbow,
      leftWrist, rightWrist, leftHip, rightHip, leftKnee, rightKnee
    ];
    
    if (requiredLandmarks.any((landmark) => 
        landmark == null || landmark.likelihood < MIN_CONFIDENCE)) {
      setState(() {
        _statusMessage = "Position yourself so your full body is visible";
        _formFeedback = "Need to see: shoulders, elbows, wrists, hips, and knees";
      });
      return;
    }

    // Calculate angles
    final leftElbowAngle = _calculateAngle(leftShoulder!, leftElbow!, leftWrist!);
    final rightElbowAngle = _calculateAngle(rightShoulder!, rightElbow!, rightWrist!);
    final avgElbowAngle = (leftElbowAngle + rightElbowAngle) / 2;
    
    // Calculate hip angle (shoulder-hip-knee angle for body straightness)
    final leftHipAngle = _calculateAngle(leftShoulder, leftHip!, leftKnee!);
    final rightHipAngle = _calculateAngle(rightShoulder, rightHip!, rightKnee!);
    final avgHipAngle = (leftHipAngle + rightHipAngle) / 2;
    
    _lastShoulderElbowAngle = avgElbowAngle;
    _lastHipAngle = avgHipAngle;

    // Check body position and form
    _validatePushupForm(avgHipAngle, leftHip, rightHip, leftAnkle, rightAnkle);

    // Only count pushup if form is proper
    if (_hasProperHipAngle && _isInPlankPosition) {
      _countPushup(avgElbowAngle);
    } else {
      _providePushupFormFeedback(avgElbowAngle, avgHipAngle);
    }
  }

  void _validatePushupForm(double hipAngle, PoseLandmark leftHip, PoseLandmark rightHip, 
                          PoseLandmark? leftAnkle, PoseLandmark? rightAnkle) {
    List<String> formIssues = [];
    
    // Check hip angle for straight body line
    if (hipAngle < MIN_HIP_ANGLE_THRESHOLD) {
      _hasProperHipAngle = false;
      formIssues.add("Hips too low (piking)");
    } else if (hipAngle > MAX_HIP_SAG_THRESHOLD) {
      _hasProperHipAngle = false;
      formIssues.add("Hips sagging");
    } else {
      _hasProperHipAngle = true;
    }

    // Check if person is in plank position (not lying down)
    final avgHipY = (leftHip.y + rightHip.y) / 2;
    
    if (leftAnkle != null && rightAnkle != null) {
      final avgAnkleY = (leftAnkle.y + rightAnkle.y) / 2;
      final hipToAnkleDistance = (avgHipY - avgAnkleY).abs();
      
      _isInPlankPosition = hipToAnkleDistance > GROUND_PROXIMITY_THRESHOLD;
      
      if (!_isInPlankPosition) {
        formIssues.add("Too close to ground - maintain plank position");
      }
    } else {
      // Fallback: use hip position relative to image height
      _isInPlankPosition = avgHipY < 0.8; // Hip should be in upper portion of image
      if (!_isInPlankPosition) {
        formIssues.add("Maintain elevated plank position");
      }
    }

    setState(() {
      _formFeedback = formIssues.isEmpty ? "✓ Good form!" : formIssues.join(", ");
    });
  }

  void _countPushup(double elbowAngle) {
    if (!_isInDownPosition && elbowAngle < DOWN_ELBOW_ANGLE_THRESHOLD) {
      _isInDownPosition = true;
      setState(() {
        _statusMessage = "Down position - Push up! ✓ Form good";
      });
    } else if (_isInDownPosition && elbowAngle > UP_ELBOW_ANGLE_THRESHOLD) {
      _isInDownPosition = false;
      _pushupCount++;
      HapticFeedback.lightImpact();
      setState(() {
        _statusMessage = "Pushup #$_pushupCount completed! Excellent form! 💪";
      });
    } else {
      setState(() {
        if (_isInDownPosition) {
          _statusMessage = "Push up! (Angle: ${elbowAngle.toInt()}°) ✓ Form good";
        } else {
          _statusMessage = "Go down! (Angle: ${elbowAngle.toInt()}°) ✓ Form good";
        }
      });
    }
  }

  void _providePushupFormFeedback(double elbowAngle, double hipAngle) {
    setState(() {
      _statusMessage = "Fix form before continuing - Hip: ${hipAngle.toInt()}°, Elbow: ${elbowAngle.toInt()}°";
    });
  }

  double _calculateAngle(PoseLandmark point1, PoseLandmark point2, PoseLandmark point3) {
    final vector1 = Offset(point1.x - point2.x, point1.y - point2.y);
    final vector2 = Offset(point3.x - point2.x, point3.y - point2.y);
    
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
    final painter = PosePainter(
      pose,
      Size(image.width.toDouble(), image.height.toDouble()),
      _cameraController!.description.sensorOrientation,
      _lastShoulderElbowAngle,
      _lastHipAngle,
      _isInDownPosition,
      _hasProperHipAngle,
      _isInPlankPosition,
    );
    
    setState(() {
      _customPaint = CustomPaint(painter: painter);
    });
  }

  void _resetCounter() {
    setState(() {
      _pushupCount = 0;
      _isInDownPosition = false;
      _hasProperHipAngle = false;
      _isInPlankPosition = false;
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
        title: Text('Smart Pushup Counter'),
        backgroundColor: Colors.blue.shade800,
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
            CircularProgressIndicator(color: Colors.blue),
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
        
        // Enhanced top info panel
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
                      'Valid Pushups: $_pushupCount',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Form status indicator
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: (_hasProperHipAngle && _isInPlankPosition) 
                            ? Colors.green 
                            : Colors.red.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        (_hasProperHipAngle && _isInPlankPosition) ? 'GOOD FORM' : 'FIX FORM',
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
        
        // Enhanced instructions
        if (!_isStreaming)
          Positioned(
            bottom: 140,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Smart Form Detection:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Position phone to see full body (head to feet)\n'
                    '• Maintain straight plank position\n'
                    '• Keep hips aligned (no sagging or piking)\n'
                    '• Only proper form pushups are counted\n'
                    '• Follow real-time form feedback',
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

class PosePainter extends CustomPainter {
  final Pose pose;
  final Size imageSize;
  final int rotation;
  final double elbowAngle;
  final double hipAngle;
  final bool isInDownPosition;
  final bool hasProperHipAngle;
  final bool isInPlankPosition;

  PosePainter(
    this.pose,
    this.imageSize,
    this.rotation,
    this.elbowAngle,
    this.hipAngle,
    this.isInDownPosition,
    this.hasProperHipAngle,
    this.isInPlankPosition,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    // Different colors for different states
    Color pointColor;
    Color lineColor;
    
    if (hasProperHipAngle && isInPlankPosition) {
      pointColor = isInDownPosition ? Colors.orange : Colors.green;
      lineColor = isInDownPosition ? Colors.orange.withOpacity(0.8) : Colors.green.withOpacity(0.8);
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

    // Hip line paint (special color for hip alignment)
    final hipLinePaint = Paint()
      ..color = hasProperHipAngle ? Colors.green : Colors.red
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;

    // Draw all key landmarks
    final keyLandmarks = [
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.leftWrist,
      PoseLandmarkType.rightWrist,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
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

    // Draw arm connections
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);

    // Draw body line (shoulder-hip-knee) with special hip line coloring
    _drawConnection(canvas, size, hipLinePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
    _drawConnection(canvas, size, hipLinePaint, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
    _drawConnection(canvas, size, hipLinePaint, PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    _drawConnection(canvas, size, hipLinePaint, PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);

    // Draw angle information
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      shadows: [Shadow(color: Colors.black, blurRadius: 3)],
    );

    _drawText(canvas, 'Elbow: ${elbowAngle.toInt()}°', Offset(20, size.height - 120), textStyle);
    _drawText(canvas, 'Hip: ${hipAngle.toInt()}°', Offset(20, size.height - 100), textStyle);
    
    // Form status
    final formStatus = hasProperHipAngle ? 'GOOD FORM ✓' : 'FIX FORM ⚠';
    final formColor = hasProperHipAngle ? Colors.green : Colors.red;
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