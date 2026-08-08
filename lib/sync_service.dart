import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'storage.dart';

class SyncService {
  static const _baseUrl = 'https://YOUR_PROJECT.supabase.co';
  static const _anonKey = 'YOUR_PUBLISHABLE_KEY';
  static const _syncEnabledKey = 'sync_enabled';
  static const _syncedSessionsKey = 'synced_sessions';

  // ── Consent toggle ───────────────────────────────────────────────────────────

  // Returns null if the user has never been asked (show consent prompt).
  static Future<bool?> getSyncPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_syncEnabledKey);
  }

  static Future<bool> isSyncEnabled() async => (await getSyncPreference()) == true;

  static Future<void> setSyncEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, value);
  }

  // ── Synced session tracking ──────────────────────────────────────────────────

  static Future<Set<String>> _getSyncedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_syncedSessionsKey);
    if (raw == null) return {};
    return Set<String>.from(jsonDecode(raw) as List);
  }

  static Future<void> _markSynced(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = await _getSyncedKeys();
    keys.add(key);
    await prefs.setString(_syncedSessionsKey, jsonEncode(keys.toList()));
  }

  // ── Session completeness check ───────────────────────────────────────────────

  // Only sync sessions where the shift has definitely ended.
  static bool _isComplete(ShiftSession session) {
    final now = DateTime.now();
    final d = _parseDate(session.dateKey);
    final shiftEnd = switch (session.shift) {
      ShiftType.morning => DateTime(d.year, d.month, d.day, 15, 0),  // 3pm
      ShiftType.evening => DateTime(d.year, d.month, d.day, 23, 0),  // 11pm
      ShiftType.night   => DateTime(d.year, d.month, d.day + 1, 7, 0), // 7am next day
    };
    return now.isAfter(shiftEnd);
  }

  static DateTime _parseDate(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  /// First/last entry timestamps in a session → rough worked span for rate math.
  static ({DateTime? first, DateTime? last, double durationHours}) _sessionSpan(
    ShiftSession session,
  ) {
    if (session.entries.isEmpty) {
      return (first: null, last: null, durationHours: 0);
    }
    var first = session.entries.first.timestamp;
    var last = first;
    for (final e in session.entries) {
      if (e.timestamp.isBefore(first)) first = e.timestamp;
      if (e.timestamp.isAfter(last)) last = e.timestamp;
    }
    final hours = last.difference(first).inSeconds / 3600.0;
    return (first: first, last: last, durationHours: hours < 0 ? 0 : hours);
  }

  // ── Main sync ────────────────────────────────────────────────────────────────

  static Future<void> syncPendingSessions(List<PalletEntry> entries) async {
    if (!await isSyncEnabled()) return;

    final deviceId = await Storage.getOrCreateDeviceId();
    final syncedKeys = await _getSyncedKeys();
    final sessions = Storage.groupBySessions(entries);

    for (final session in sessions) {
      final key = '${session.dateKey}_${session.shift.name}';
      if (syncedKeys.contains(key)) continue;
      if (!_isComplete(session)) continue;

      // Flat 8h assumption kept for backward-compatible field; prefer duration-based rate when possible.
      final itemsPerHourFlat8 = (session.totalItems / 8).round();
      final span = _sessionSpan(session);
      final durationHours = span.durationHours;
      final itemsPerHourLive = durationHours >= 0.25
          ? (session.totalItems / durationHours).round()
          : itemsPerHourFlat8;

      final payload = {
        'device_id': deviceId,
        'session_date': session.dateKey,
        'shift_type': session.shift.name,
        'pallets': session.totalPallets,
        'total_items': session.totalItems,
        'total_stops': session.totalStops,
        'items_per_stop': double.parse(session.itemsPerStop.toStringAsFixed(2)),
        'avg_stops_per_pallet':
            double.parse(session.avgStopsPerPallet.toStringAsFixed(2)),
        // Summary duration hours only: wall-clock timestamps are not transmitted to preserve user privacy.
        'duration_hours': durationHours > 0
            ? double.parse(durationHours.toStringAsFixed(2))
            : null,
        // Majority role label only: roster | extra | unset (no notes, no name).
        'rotation_role': session.rotationRole.name,
        // Legacy field: items / 8h (kept so old dashboards do not break).
        'items_per_hour': itemsPerHourFlat8,
        // Better rate when span is long enough.
        'items_per_hour_live': itemsPerHourLive,
        'app_version': '1.0.6',
      };

      try {
        final res = await http.post(
          Uri.parse('$_baseUrl/rest/v1/sessions'),
          headers: {
            'apikey': _anonKey,
            'Authorization': 'Bearer $_anonKey',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
          },
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 10));

        if (res.statusCode == 201) await _markSynced(key);
      } catch (_) {
        // Silent fallback: retries on next app session
      }
    }
  }
}
