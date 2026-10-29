import 'package:flutter/material.dart';

class AdvancedPlayerSettingsSheet extends StatefulWidget {
  const AdvancedPlayerSettingsSheet({super.key});

  @override
  State<AdvancedPlayerSettingsSheet> createState() => _AdvancedPlayerSettingsSheetState();
}

class _AdvancedPlayerSettingsSheetState extends State<AdvancedPlayerSettingsSheet> {
  double _bufferSize = 10.0; 
  String _selectedEq = 'Plano';
  String _selectedAudio = 'Español (Predeterminado)';
  
  final List<String> _eqPresets = ['Plano', 'Cine (Surround)', 'Voz Clara', 'Graves Profundos', 'Música'];
  final List<String> _audioTracks = ['Español (Predeterminado)', 'Inglés (Original)', 'Sin Audio'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      height: MediaQuery.of(context).size.height * 0.65,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0C).withOpacity(0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: Colors.white12, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
          ),
          const SizedBox(height: 20),
          const Text(
            '⚙️ MOTOR DE REPRODUCCIÓN AVANZADO',
            style: TextStyle(color: Color(0xFFC77DFF), fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.2),
          ),
          const Divider(color: Colors.white12, height: 30),

          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              children: [
                _buildSectionTitle(Icons.wifi_tethering, 'Estabilidad de Red (Buffer)'),
                Text('Aumenta para evitar cortes en internet lento. Valor actual: ${_bufferSize.toInt()} MB', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                SliderTheme(
                  data: SliderThemeData(activeTrackColor: const Color(0xFFC77DFF), thumbColor: Colors.white, overlayColor: const Color(0xFFC77DFF).withOpacity(0.2)),
                  child: Slider(
                    value: _bufferSize,
                    min: 1.0,
                    max: 50.0,
                    divisions: 49,
                    onChanged: (val) => setState(() => _bufferSize = val),
                  ),
                ),
                const SizedBox(height: 20),

                _buildSectionTitle(Icons.audiotrack, 'Pista de Audio'),
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedAudio,
                      dropdownColor: const Color(0xFF1E1E24),
                      isExpanded: true,
                      icon: const Icon(Icons.arrow_drop_down, color: Color(0xFFC77DFF)),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      items: _audioTracks.map((track) => DropdownMenuItem(value: track, child: Text(track))).toList(),
                      onChanged: (val) => setState(() => _selectedAudio = val!),
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                _buildSectionTitle(Icons.equalizer, 'Ecualizador Maestro'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _eqPresets.map((preset) {
                    final isSelected = _selectedEq == preset;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedEq = preset),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFC77DFF).withOpacity(0.2) : Colors.transparent,
                          border: Border.all(color: isSelected ? const Color(0xFFC77DFF) : Colors.white24),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          preset,
                          style: TextStyle(color: isSelected ? const Color(0xFFC77DFF) : Colors.white70, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }
}