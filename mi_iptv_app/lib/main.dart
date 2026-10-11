import 'package:flutter/material.dart';
import 'models/channel_model.dart';
import 'services/m3u_sanitizer_service.dart';

void main() {
  runApp(const AmeycarTVApp());
}

class AmeycarTVApp extends StatelessWidget {
  const AmeycarTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMEYCAR TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F141C),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  List<ChannelModel> _channels = [];
  int _selectedChannelIndex = 0;

  final String _defaultM3uList = '''
#EXTM3U
#EXTINF:-1 tvg-logo="" group-title="Noticias",NEWS HEVC FHD
https://sample-videos.com/video123/mp4/720/big_buck_bunny_720p_1mb.mp4
#EXTINF:-1 tvg-logo="" group-title="Deportes",ESPN Live HD
https://sample-videos.com/video123/mp4/720/big_buck_bunny_720p_1mb.mp4
''';

  @override
  void initState() {
    super.initState();
    _channels = M3USanitizerService.parseAndSanitize(_defaultM3uList);
  }

  @override
  Widget build(BuildContext context) {
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F141C),
      body: Row(
        children: [
          Container(
            width: 180,
            color: const Color(0xFF161C26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16, top: 24, bottom: 20),
                  child: Text('AMEYCAR TV', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                _buildNavItem(Icons.tv, 'En Vivo', isSelected: true),
                _buildNavItem(Icons.auto_fix_high, 'Sanitizador IA'),
                _buildNavItem(Icons.settings, 'Ajustes'),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFF121822),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Pega tu enlace M3U aquí...',
                            hintStyle: const TextStyle(color: Colors.white38),
                            filled: true,
                            fillColor: const Color(0xFF1C2738),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {},
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                        child: const Text('Cargar', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _channels.length,
                    itemBuilder: (context, index) {
                      final channel = _channels[index];
                      return ListTile(
                        title: Text(channel.name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(channel.groupCategory, style: const TextStyle(color: Colors.white54)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, {bool isSelected = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: isSelected ? Colors.blueAccent.withOpacity(0.2) : Colors.transparent,
      child: Row(
        children: [
          Icon(icon, color: isSelected ? Colors.blueAccent : Colors.white54, size: 18),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white54, fontSize: 13)),
        ],
      ),
    );
  }
}
