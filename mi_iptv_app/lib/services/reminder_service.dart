import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class ReminderItem {
	final int id;
	final String channelName;
	final String? channelLogo;
	final String programTitle;
	final DateTime scheduledTime;
	final String timeRange;

	ReminderItem({
		required this.id,
		required this.channelName,
		this.channelLogo,
		required this.programTitle,
		required this.scheduledTime,
		required this.timeRange,
	});

	Map<String, dynamic> toMap() => {
				'id': id,
				'channelName': channelName,
				'channelLogo': channelLogo,
				'programTitle': programTitle,
				'scheduledTime': scheduledTime.toIso8601String(),
				'timeRange': timeRange,
			};

	factory ReminderItem.fromMap(Map<String, dynamic> map) => ReminderItem(
				id: map['id'],
				channelName: map['channelName'],
				channelLogo: map['channelLogo'],
				programTitle: map['programTitle'],
				scheduledTime: DateTime.parse(map['scheduledTime']),
				timeRange: map['timeRange'] ?? '',
			);
}

class ReminderService {
	static final ReminderService _instance = ReminderService._internal();
	factory ReminderService() => _instance;
	ReminderService._internal();

	final FlutterLocalNotificationsPlugin _notificationsPlugin =
			FlutterLocalNotificationsPlugin();

	static const String _storageKey = 'ameycar_active_reminders';

	Future<void> initialize() async {
		tz.initializeTimeZones();

		const AndroidInitializationSettings initializationSettingsAndroid =
				AndroidInitializationSettings('@mipmap/ic_launcher');

		const InitializationSettings initializationSettings =
				InitializationSettings(android: initializationSettingsAndroid);

		await _notificationsPlugin.initialize(initializationSettings);
	}

	Future<List<ReminderItem>> getActiveReminders() async {
		final prefs = await SharedPreferences.getInstance();
		final String? rawData = prefs.getString(_storageKey);
		if (rawData == null || rawData.isEmpty) return [];

		try {
			final List<dynamic> list = jsonDecode(rawData);
			final now = DateTime.now();
			// Filtrar recordatorios que aún no hayan vencido hace más de 10 minutos
			final validReminders = list
					.map((item) => ReminderItem.fromMap(item))
					.where((item) =>
							item.scheduledTime.isAfter(now.subtract(const Duration(minutes: 10))))
					.toList();

			// Guardar lista limpia
			await _saveReminders(validReminders);
			return validReminders;
		} catch (e) {
			return [];
		}
	}

	Future<void> _saveReminders(List<ReminderItem> reminders) async {
		final prefs = await SharedPreferences.getInstance();
		final list = reminders.map((r) => r.toMap()).toList();
		await prefs.setString(_storageKey, jsonEncode(list));
	}

	Future<bool> isReminderActive(int id) async {
		final active = await getActiveReminders();
		return active.any((r) => r.id == id);
	}

	Future<void> scheduleProgramReminder({
		required int id,
		required String channelName,
		String? channelLogo,
		required String programTitle,
		required DateTime programStartTime,
		required String timeRange,
	}) async {
		final scheduledDate = tz.TZDateTime.from(programStartTime, tz.local);

		const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
			'ameycar_epg_channel',
			'Recordatorios Ameycar TV',
			channelDescription:
					'Alarmas para tus programas y eventos deportivos favoritos',
			importance: Importance.max,
			priority: Priority.high,
			showWhen: true,
			enableVibration: true,
			playSound: true,
		);

		const NotificationDetails platformDetails =
				NotificationDetails(android: androidDetails);

		// Si ya pasó o está a punto de empezar en menos de 5 seg, notificar en 5 seg de prueba
		final targetDate = scheduledDate.isBefore(tz.TZDateTime.now(tz.local))
				? tz.TZDateTime.now(tz.local).add(const Duration(seconds: 5))
				: scheduledDate;

		await _notificationsPlugin.zonedSchedule(
			id,
			'⏰ ¡Comienza $programTitle!',
			'En sintonía por $channelName ($timeRange). Toca para abrir AmeycarTV.',
			targetDate,
			platformDetails,
			androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
			uiLocalNotificationDateInterpretation:
					UILocalNotificationDateInterpretation.absoluteTime,
		);

		// Guardar en persistencia
		final reminders = await getActiveReminders();
		reminders.removeWhere((r) => r.id == id);
		reminders.add(
			ReminderItem(
				id: id,
				channelName: channelName,
				channelLogo: channelLogo,
				programTitle: programTitle,
				scheduledTime: programStartTime,
				timeRange: timeRange,
			),
		);
		await _saveReminders(reminders);
	}

	Future<void> cancelReminder(int id) async {
		await _notificationsPlugin.cancel(id);
		final reminders = await getActiveReminders();
		reminders.removeWhere((r) => r.id == id);
		await _saveReminders(reminders);
	}

	Future<void> cancelAllReminders() async {
		await _notificationsPlugin.cancelAll();
		final prefs = await SharedPreferences.getInstance();
		await prefs.remove(_storageKey);
	}
}
