import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/playlist_item.dart';
import '../services/reminder_service.dart';
import 'active_reminders_dialog.dart';

class EpgModal extends StatefulWidget {
  final PlaylistItem channel;
  final VoidCallback onPlay;

  const EpgModal({super.key, required this.channel, required this.onPlay});

  @override
  State<EpgModal> createState() => _EpgModalState();
}

class _EpgModalState extends State<EpgModal> {
  final ReminderService _reminderService = ReminderService();
  int _activeRemindersCount = 0;
  final Set<int> _activeIds = {};

  @override
  void initState() {
    super.initState();
    _refreshReminders();
  }

  Future<void> _refreshReminders() async {
    final list = await _reminderService.getActiveReminders();
    if (mounted) {
      setState(() {
        _activeRemindersCount = list.length;
        _activeIds.clear();
        for (var r in list) {
          _activeIds.add(r.id);
        }
      });
    }
  }

  void _openActiveRemindersDialog() {
    showDialog(
      context: context,
      builder: (context) => ActiveRemindersDialog(
        onRemindersChanged: _refreshReminders,
      ),
    );
  }

  void _toggleReminder({
    required int id,
    required String programTitle,
    required DateTime time,
    required String timeRange,
  }) async {
    if (_activeIds.contains(id)) {
      await _reminderService.cancelReminder(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Alarma cancelada: $programTitle'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      await _reminderService.scheduleProgramReminder(
        id: id,
        channelName: widget.channel.name,
        channelLogo: widget.channel.logoUrl,
        programTitle: programTitle,
        programStartTime: time,
        timeRange: timeRange,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡Alarma activada para $programTitle!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    await _refreshReminders();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeFormat = DateFormat('HH:mm');

    // Generación dinámica de la guía para el canal
    final programs = [
      {
        'id': widget.channel.name.hashCode ^ 1,
        'title': 'Magacín de Entretenimiento de la Tarde',
        'start': now.subtract(const Duration(minutes: 20)),
        'end': now.add(const Duration(minutes: 40)),
        'isLive': true,
      },
      {
        'id': widget.channel.name.hashCode ^ 2,
        'title': 'Serie Exclusiva: Temporada Estelar',
        'start': now.add(const Duration(minutes: 40)),
        'end': now.add(const Duration(minutes: 100)),
        'isLive': false,
      },
      {
        'id': widget.channel.name.hashCode ^ 3,
        'title': 'Documental: Grandes Misterios del Planeta',
        'start': now.add(const Duration(minutes: 100)),
        'end': now.add(const Duration(minutes: 160)),
        'isLive': false,
      },
    ];

    return Dialog(
      backgroundColor: const Color(0xFF101026),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Colors.deepPurpleAccent, width: 1.5),
      ),
      child: Container(
        padding: const EdgeInsets.all(18),
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header del canal
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.channel.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Text(
                            'Guía EPG en Tiempo Real',
                            style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.access_time, color: Colors.cyanAccent, size: 13),
                          const SizedBox(width: 4),
                          Text(
                            DateFormat('HH:mm:ss').format(now),
                            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Barra de estado de recordatorios
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Programas y Recordatorios:',
                  style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                // Botón interactivo "X activas" que abre el gestor
                GestureDetector(
                  onTap: _openActiveRemindersDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.amber, width: 1.2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.notifications_active, color: Colors.amber, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          '$_activeRemindersCount activas',
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Lista de programas
            Expanded(
              child: ListView.separated(
                itemCount: programs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final p = programs[index];
                  final isLive = p['isLive'] as bool;
                  final pId = p['id'] as int;
                  final start = p['start'] as DateTime;
                  final end = p['end'] as DateTime;
                  final timeRange = '${timeFormat.format(start)} - ${timeFormat.format(end)}';
                  final isAlarmSet = _activeIds.contains(pId);

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isLive ? const Color(0xFF231B45) : const Color(0xFF16162D),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isLive ? Colors.deepPurpleAccent : Colors.white10,
                        width: isLive ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        if (isLive)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'EN VIVO',
                              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              timeFormat.format(start),
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p['title'] as String,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: isLive ? FontWeight.bold : FontWeight.w500,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                timeRange,
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        if (isLive)
                          IconButton(
                            icon: const Icon(Icons.play_circle_fill, color: Colors.cyanAccent, size: 30),
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onPlay();
                            },
                          )
                        else
                          IconButton(
                            tooltip: isAlarmSet ? 'Desactivar recordatorio' : 'Activar recordatorio',
                            icon: Icon(
                              isAlarmSet ? Icons.alarm_on : Icons.alarm_add,
                              color: isAlarmSet ? Colors.amber : Colors.white54,
                              size: 26,
                            ),
                            onPressed: () => _toggleReminder(
                              id: pId,
                              programTitle: p['title'] as String,
                              time: start,
                              timeRange: timeRange,
                            ),
                          ),
                      ],
                    ),
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