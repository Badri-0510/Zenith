# Project Zenith – AI-Powered Form Tester (Prototype for SIH)

Zenith Fitness is a **Flutter-based prototype** developed for the **Smart India Hackathon (SIH)**.  
This is a **tester prototype**, not a trainer or production-ready fitness app.

---

## Features
- Real-time pose detection  
- Form validation with instant visual feedback  
- Rep counting logic (only valid reps are counted)  
- Pose overlay with color indicators  
- Two tester modes: **push-ups** and **sit-ups**

---

## Push-up Logic

### Setup
- Front-facing camera  
- Full body visibility required  

### Key Landmarks
- Shoulders, elbows, wrists, hips, knees, ankles  
- Confidence threshold: **30%**

### Angles
- **Elbow angle (Shoulder–Elbow–Wrist):**  
  - Down: `< 90°`  
  - Up: `> 160°`  
- **Hip angle (Shoulder–Hip–Knee):**  
  - Valid range: `150° – 210°`

### Validation
- Straight body line (hip angle in range)  
- Hips elevated  
- Full range of elbow motion  

### Counting
1. Start in up position (`>160°`)  
2. Move to down position (`<90°`)  
3. Return to up position (`>160°`) → **rep counted**

---

## Sit-up Logic

### Setup
- Side-facing camera  
- Profile view of body required  

### Key Landmarks
- Nose, shoulders, hips, knees, ankles  
- Confidence threshold: **30%**

### Angles
- **Torso angle (Shoulder–Hip line vs ground):**  
  - Down: `< 45°`  
  - Up: `> 90°`  
- **Knee angle (Hip–Knee–Ankle):**  
  - Valid range: `60° – 120°`

### Validation
- Proper knee bend  
- Head aligned with torso  
- Full torso range of motion  

### Counting
1. Start in down position (`<45°`)  
2. Move to up position (`>90°`)  
3. Return to down position (`<45°`) → **rep counted**

---

## Technical Implementation
- **Flutter** for app development  
- **Google ML Kit** for pose detection  
- **Camera plugin** for live feed  
- **Custom painter** for pose overlay  

### Angle Calculation
```dart
double calculateAngle(Point p1, Point p2, Point p3) {
  Vector v1 = p1 - p2;
  Vector v2 = p3 - p2;
  double dot = v1.dot(v2);
  double magnitude = v1.magnitude * v2.magnitude;
  return acos((dot / magnitude).clamp(-1, 1)) * 180 / pi;
}
