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
  DateTime? _lastProcessTime;
  String _statusMessage = "Position yourself and start detection";
  
  // Performance optimization
 // int _frameSkipCounter = 0;
 // static const int FRAME_SKIP = 1; 
  static const double MIN_CONFIDENCE = 0.2;
  static const double DOWN_ANGLE_THRESHOLD = 90; // degrees
  static const double UP_ANGLE_THRESHOLD = 160; // degrees

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
        _statusMessage = "Detection started. Get into pushup position!";
        _pushupCount = 0;
        _isInDownPosition = false;
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
        _statusMessage = "Detection stopped. Total pushups: $_pushupCount";
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Failed to stop detection: $e";
      });
    }
  }

  void _processCameraImage(CameraImage image) async {
  debugPrint('CameraImage format: ${image.format.group}, raw: ${image.format.raw}, planes: ${image.planes.length}');
    if (_isDetecting || _poseDetector == null) return;
    
    // Frame throttling for performance
    //_frameSkipCounter++;
    //if (_frameSkipCounter % FRAME_SKIP != 0) return;
    
    // Time-based throttling (~10 FPS max)
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

      if (poses.isNotEmpty && poses.first.landmarks.isNotEmpty) {
        debugPrint('Detected ${poses.length} pose(s)');
        for (final landmark in poses.first.landmarks.values) {
          debugPrint('Landmark: ${landmark.type} at (${landmark.x}, ${landmark.y}), confidence: ${landmark.likelihood}');
        }
      }

      if (mounted) {
        if (poses.isNotEmpty && poses.first.landmarks.isNotEmpty) {
          _processPoseForPushups(poses.first);
          _updateCustomPaint(poses.first, image);
        } else {
          setState(() {
            _customPaint = null;
            if (_isStreaming) {
              _statusMessage = "No pose detected. Ensure you're visible in frame.";
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
    debugPrint("InputImage: ${image.width}x${image.height}, bytes: ${bytes.length}");
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
  // Y plane: width * height
  final yPlane = planes[0];
  for (int i = 0; i < height; i++) {
    allBytes.addAll(yPlane.bytes.sublist(i * yPlane.bytesPerRow, i * yPlane.bytesPerRow + width));
  }
  // U and V planes: (width/2) * (height/2)
  final uvWidth = width ~/ 2;
  final uvHeight = height ~/ 2;
  for (final plane in planes.sublist(1)) {
    for (int i = 0; i < uvHeight; i++) {
      allBytes.addAll(plane.bytes.sublist(i * plane.bytesPerRow, i * plane.bytesPerRow + uvWidth));
    }
  }
  debugPrint("Concatenated bytes: ${allBytes.length}");
  return Uint8List.fromList(allBytes);
}

  InputImageRotation _getImageRotation() {
    if (_cameraController == null) return InputImageRotation.rotation0deg;
    
    final sensorOrientation = _cameraController!.description.sensorOrientation;
    debugPrint("Sensor Orientation: $sensorOrientation");
    
    // Adjust based on your device testing
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
    
    // Get key points for pushup detection
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final leftElbow = landmarks[PoseLandmarkType.leftElbow];
    final rightElbow = landmarks[PoseLandmarkType.rightElbow];
    final leftWrist = landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = landmarks[PoseLandmarkType.rightWrist];

    if (leftShoulder == null || rightShoulder == null || 
        leftElbow == null || rightElbow == null ||
        leftWrist == null || rightWrist == null) {
      setState(() {
        _statusMessage = "Position yourself so your arms are fully visible";
      });
      return;
    }

    // Check confidence levels
    if (leftShoulder.likelihood < MIN_CONFIDENCE ||
        rightShoulder.likelihood < MIN_CONFIDENCE ||
        leftElbow.likelihood < MIN_CONFIDENCE ||
        rightElbow.likelihood < MIN_CONFIDENCE) {
      return;
    }

    // Calculate arm angles (using left arm as primary)
    final shoulderElbowAngle = _calculateAngle(
      leftShoulder, leftElbow, leftWrist);
    
    _lastShoulderElbowAngle = shoulderElbowAngle;

    // Pushup counting logic
    if (!_isInDownPosition && shoulderElbowAngle < DOWN_ANGLE_THRESHOLD) {
      _isInDownPosition = true;
      setState(() {
        _statusMessage = "Down position detected. Push up!";
      });
    } else if (_isInDownPosition && shoulderElbowAngle > UP_ANGLE_THRESHOLD) {
      _isInDownPosition = false;
      _pushupCount++;
      HapticFeedback.lightImpact(); // Haptic feedback
      setState(() {
        _statusMessage = "Pushup #$_pushupCount completed! Keep going!";
      });
    } else {
      // Provide guidance
      if (_isInDownPosition) {
        setState(() {
          _statusMessage = "In down position - Push up! (Angle: ${shoulderElbowAngle.toInt()}°)";
        });
      } else {
        setState(() {
          _statusMessage = "Ready position - Go down! (Angle: ${shoulderElbowAngle.toInt()}°)";
        });
      }
    }
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
    
    return angleRad * 180 / pi; // Convert to degrees
  }

  void _updateCustomPaint(Pose pose, CameraImage image) {
    final painter = PosePainter(
      pose,
      Size(image.width.toDouble(), image.height.toDouble()),
      _cameraController!.description.sensorOrientation,
      _lastShoulderElbowAngle,
      _isInDownPosition,
    );
    
    setState(() {
      _customPaint = CustomPaint(painter: painter);
    });
  }

  void _resetCounter() {
    setState(() {
      _pushupCount = 0;
      _isInDownPosition = false;
      _statusMessage = _isStreaming ? "Counter reset. Continue your workout!" : "Counter reset.";
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
        title: Text('Pushup Counter'),
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
        // Camera preview
        CameraPreview(_cameraController!),
        
        // Pose overlay
        if (_customPaint != null) _customPaint!,
        
        // Top info panel
        Positioned(
          top: 20,
          left: 20,
          right: 20,
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  'Pushups: $_pushupCount',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  _statusMessage,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                ),
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
        
        // Instructions overlay
        if (!_isStreaming)
          Positioned(
            bottom: 140,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instructions:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Position phone to see your full upper body\n'
                    '• Start in plank position\n'
                    '• Perform pushups with proper form\n'
                    '• App counts complete up-down movements',
                    style: TextStyle(color: Colors.white, fontSize: 14),
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
  final double armAngle;
  final bool isInDownPosition;

  PosePainter(
    this.pose,
    this.imageSize,
    this.rotation,
    this.armAngle,
    this.isInDownPosition,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final pointPaint = Paint()
      ..color = isInDownPosition ? Colors.red : Colors.green
      ..strokeWidth = 8
      ..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..color = isInDownPosition ? Colors.red.withOpacity(0.8) : Colors.green.withOpacity(0.8)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    // Draw key pose landmarks
    final keyLandmarks = [
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.leftWrist,
      PoseLandmarkType.rightWrist,
    ];

    // Draw landmark points
    for (final landmarkType in keyLandmarks) {
      final landmark = pose.landmarks[landmarkType];
      if (landmark != null && landmark.likelihood > 0.5) {
        final offset = Offset(
          landmark.x * scaleX,
          landmark.y * scaleY,
        );
        canvas.drawCircle(offset, 8, pointPaint);
      }
    }

    // Draw arm connections
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
    _drawConnection(canvas, size, linePaint, PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);

    // Draw angle text
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'Arm Angle: ${armAngle.toInt()}°',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(20, size.height - 100));
  }

  void _drawConnection(Canvas canvas, Size size, Paint paint, 
      PoseLandmarkType from, PoseLandmarkType to) {
    final fromLandmark = pose.landmarks[from];
    final toLandmark = pose.landmarks[to];
    
    if (fromLandmark != null && toLandmark != null &&
        fromLandmark.likelihood > 0.5 && toLandmark.likelihood > 0.5) {
      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;
      
      canvas.drawLine(
        Offset(fromLandmark.x * scaleX, fromLandmark.y * scaleY),
        Offset(toLandmark.x * scaleX, toLandmark.y * scaleY),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}