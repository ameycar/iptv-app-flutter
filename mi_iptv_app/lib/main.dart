import 'package:flutter/material.dart';
import 'package:mi_iptv_app/screens/home_screen.dart';

void main() {
  runApp(const AmeycarTVApp());
}

class AmeycarTVApp extends StatelessWidget {
  const AmeycarTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AmeycarTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
        primaryColor: Colors.deepPurpleAccent,
      ),
      home: const HomeScreen(),
    );
  }
}
