import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image_picker/image_picker.dart';

class PoseImageScreen extends StatefulWidget {
  @override
  _PoseImageScreenState createState() => _PoseImageScreenState();
}

class _PoseImageScreenState extends State<PoseImageScreen> {
  File? _imageFile;
  List<PoseLandmark> _landmarks = [];
  int _imageWidth = 1;
  int _imageHeight = 1;

  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.single),
  );

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      final file = File(pickedFile.path);

      // decode image size here (NOT inside painter)
      final decodedImage =
          await decodeImageFromList(await file.readAsBytes());

      setState(() {
        _imageFile = file;
        _imageWidth = decodedImage.width;
        _imageHeight = decodedImage.height;
      });

      await _detectPose(file);
    }
  }

  Future<void> _detectPose(File file) async {
    final inputImage = InputImage.fromFile(file);
    final poses = await _poseDetector.processImage(inputImage);

    if (poses.isNotEmpty) {
      final pose = poses.first;
      setState(() {
        _landmarks = pose.landmarks.values.toList();
      });
    } else {
      setState(() {
        _landmarks = [];
      });
    }
  }

  @override
  void dispose() {
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Pose Detection - Image")),
      body: Center(
        child: Column(
          children: [
            ElevatedButton(
              onPressed: _pickImage,
              child: const Text("Pick Image"),
            ),
            if (_imageFile != null)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        Image.file(
                          _imageFile!,
                          width: constraints.maxWidth,
                          fit: BoxFit.contain,
                        ),
                        CustomPaint(
                          painter: PosePainter(
                            landmarks: _landmarks,
                            imageWidth: _imageWidth.toDouble(),
                            imageHeight: _imageHeight.toDouble(),
                            widgetWidth: constraints.maxWidth,
                          ),
                          child: Container(),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  final List<PoseLandmark> landmarks;
  final double imageWidth;
  final double imageHeight;
  final double widgetWidth;

  PosePainter({
    required this.landmarks,
    required this.imageWidth,
    required this.imageHeight,
    required this.widgetWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    final paint = Paint()
      ..color = Colors.green
      ..strokeWidth = 4
      ..style = PaintingStyle.fill;

    // scale factors
    final scale = widgetWidth / imageWidth;
    final scaledHeight = imageHeight * scale;

    for (var landmark in landmarks) {
      final offset = Offset(
        landmark.x.toDouble() * scale,
        landmark.y.toDouble() * scale,
      );
      canvas.drawCircle(offset, 5, paint);
    }

    void drawLine(PoseLandmarkType a, PoseLandmarkType b) {
      try {
        final l1 = landmarks.firstWhere((lm) => lm.type == a);
        final l2 = landmarks.firstWhere((lm) => lm.type == b);
        canvas.drawLine(
          Offset(l1.x.toDouble() * scale, l1.y.toDouble() * scale),
          Offset(l2.x.toDouble() * scale, l2.y.toDouble() * scale),
          paint,
        );
      } catch (_) {}
    }

    // Skeleton connections
    drawLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
    drawLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
    drawLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
    drawLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
    drawLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
    drawLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);
    drawLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
    drawLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
    drawLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
    drawLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

