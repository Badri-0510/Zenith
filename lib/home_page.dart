import 'package:flutter/material.dart';
import 'pushup_counter_screen.dart';

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Fitness Tracker")),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PushupCounterScreen()),
            );
          },
          child: Text("Count Pushups"),
        ),
      ),
    );
  }
}
