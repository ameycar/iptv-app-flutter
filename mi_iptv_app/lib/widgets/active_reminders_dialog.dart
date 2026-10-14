import 'package:flutter/material.dart';
import '../services/reminder_service.dart';

class ActiveRemindersDialog extends StatefulWidget {
  final VoidCallback onRemindersChanged;

  const ActiveRemindersDialog({super.key, required this.onRemindersChanged});

  @override
  State<ActiveRemindersDialog> createState() => _ActiveRemindersDialogState();
}

class _ActiveRemindersDialogState extends State<ActiveRemindersDialog> {
  final ReminderService _reminderService = ReminderService();
  List<ReminderItem> _reminders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadReminders();
  }

  Future<void> _loadReminders() async {
    final list = await _reminderService.getActiveReminders();
    if (mounted) {
      setState(() {
        _reminders = list;
        _loading = false;
      });
    }
  }

  Future<void> _deleteReminder(int id) async {
    await _reminderService.cancelReminder(id);
    await _loadReminders();
    widget.onRemindersChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Alarma desactivada correctamente'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.deepPurple,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF13132B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Colors.amber, width: 1.5),
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 550),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.notifications_active, color: Colors.amber, size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Alarmas Activas',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Toca el cesto para desactivar cualquier recordatorio',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
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
            const Divider(color: Colors.white12, height: 24),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Colors.amber))
                  : _reminders.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.alarm_off, color: Colors.white24, size: 48),
                              SizedBox(height: 12),
                              Text(
                                'No tienes alarmas programadas',
                                style: TextStyle(color: Colors.white60, fontSize: 14),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _reminders.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _reminders[index];
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E38),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.amber.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 26),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.programTitle,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          'Canal: ${item.channelName}',
                                          style: const TextStyle(
                                            color: Colors.cyanAccent,
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'Horario: ${item.timeRange}',
                                          style: const TextStyle(
                                            color: Colors.amber,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Desactivar Alarma',
                                    icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 26),
                                    onPressed: () => _deleteReminder(item.id),
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