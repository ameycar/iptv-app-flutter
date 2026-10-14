import 'package:flutter/material.dart';
import '../models/playlist_item.dart';
import 'add_playlist_screen.dart';
import 'video_player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<PlaylistItem> _channels = [];

  void _navigateToAddPlaylist() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddPlaylistScreen()),
    );

    if (!mounted) return;

    if (result != null && result is List<PlaylistItem>) {
      setState(() {
        _channels = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Map<String, List<PlaylistItem>> categorized = {};
    for (var item in _channels) {
      categorized.putIfAbsent(item.category, () => []).add(item);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        title: const Text(
          'AMEYCAR TV',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.deepPurpleAccent,
            letterSpacing: 1.2,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add, color: Colors.white),
            onPressed: _navigateToAddPlaylist,
          ),
        ],
      ),
      body: _channels.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.tv_off_rounded, size: 80, color: Colors.white24),
                  const SizedBox(height: 16),
                  const Text(
                    'No hay canales cargados',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Agrega una lista M3U para que la IA la procese.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _navigateToAddPlaylist,
                    icon: const Icon(Icons.add, color: Colors.white),
                    label: const Text(
                      'Agregar Lista M3U',
                      style: TextStyle(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurpleAccent,
                    ),
                  )
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: categorized.entries.map((entry) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        entry.key,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 140,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: entry.value.length,
                        itemBuilder: (context, index) {
                          final channel = entry.value[index];
                          return GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => VideoPlayerScreen(item: channel),
                                ),
                              );
                            },
                            child: Container(
                              width: 120,
                              margin: const EdgeInsets.only(right: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E2E),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  channel.logoUrl != null && channel.logoUrl!.isNotEmpty
                                      ? Image.network(
                                          channel.logoUrl!,
                                          height: 50,
                                          errorBuilder: (context, error, stackTrace) =>
                                              const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 40),
                                        )
                                      : const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 40),
                                  const SizedBox(height: 8),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                                    child: Text(
                                      channel.name,
                                      style: const TextStyle(color: Colors.white, fontSize: 12),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                );
              }).toList(),
            ),
    );
  }
}