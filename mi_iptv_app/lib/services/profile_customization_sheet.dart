import 'package:flutter/material.dart';
import '../services/user_customization_service.dart';

class ProfileCustomizationSheet extends StatefulWidget {
  final VoidCallback onThemeChanged;
  const ProfileCustomizationSheet({super.key, required this.onThemeChanged});

  @override
  State<ProfileCustomizationSheet> createState() => _ProfileCustomizationSheetState();
}

class _ProfileCustomizationSheetState extends State<ProfileCustomizationSheet> {
  final List<Color> _colors = [
    const Color(0xFF00E5FF),
    const Color(0xFF7B2CBF),
    const Color(0xFFFFD600),
    const Color(0xFFFF1744),
    const Color(0xFF00E676),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Color(0xFF161F36),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Color de Acento', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _colors.map((c) => GestureDetector(
              onTap: () async {
                await UserCustomizationService.setAccentColor(c);
                widget.onThemeChanged();
                if (mounted) Navigator.pop(context);
              },
              child: CircleAvatar(backgroundColor: c, radius: 20),
            )).toList(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}