import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class Storage {
  static const _key = 'pallet_entries';
  static const _notesKey = 'shift_notes';
  static const _setupKey = 'user_setup_cycle';
  static const _deviceIdKey = 'device_id';
  /// Continuous local snapshot (survives more failure modes than manual export).
  /// Still wiped on full uninstall of the app sandbox: but catches
  /// accidental clears when the file is also shared out.
  static const autoBackupFileName = 'stacked_auto_backup.json';

  static Future<List<PalletEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => PalletEntry.fromJson(e)).toList();
  }

  static Future<void> saveAll(List<PalletEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  static Future<void> addEntry(PalletEntry entry) async {
    final all = await loadAll();
    all.add(entry);
    await saveAll(all);
    await writeAutoBackup();
  }

  static Future<void> deleteEntry(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await saveAll(all);
    await writeAutoBackup();
  }

  /// Sets rotationRole for every pallet in a dateKey+shift session.
  /// Does not change shift labels: only roster/extra/unset for schedule anchors.
  static Future<void> setSessionRotationRole(
    String dateKey,
    ShiftType shift,
    RotationRole role,
  ) async {
    final all = await loadAll();
    final updated = all.map((e) {
      if (e.shift == shift && shiftDateKey(e.timestamp, e.shift) == dateKey) {
        return e.copyWith(rotationRole: role);
      }
      return e;
    }).toList();
    await saveAll(updated);
    await writeAutoBackup();
  }

  /// Legacy helper: true → extra, false → unset (not roster).
  static Future<void> setSessionExtraShift(
    String dateKey,
    ShiftType shift,
    bool isExtra,
  ) =>
      setSessionRotationRole(
        dateKey,
        shift,
        isExtra ? RotationRole.extra : RotationRole.unset,
      );

  static const _lastRotationRoleKey = 'last_rotation_role_choice';

  static Future<RotationRole?> loadLastRotationRoleChoice() async {
    final prefs = await SharedPreferences.getInstance();
    return RotationRoleX.fromString(prefs.getString(_lastRotationRoleKey));
  }

  static Future<void> saveLastRotationRoleChoice(RotationRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastRotationRoleKey, role.name);
  }

  // Persists the active shift for the current shift-date so OT re-opens correctly
  static Future<void> saveActiveShift(ShiftType shift) async {
    final prefs = await SharedPreferences.getInstance();
    final dk = shiftDateKey(DateTime.now(), shift);
    await prefs.setString('active_shift', '$dk|${shift.name}');
  }

  static Future<ShiftType?> loadActiveShift() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('active_shift');
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length != 2) return null;
    final shift = ShiftTypeX.fromString(parts[1]);
    if (shift == null) return null;
    // The saved shift always wins. No date or time expiry: overtime means a
    // shift legitimately runs past its own window, and only the user can tell
    // overtime apart from a genuinely new shift. LogScreen surfaces a banner
    // when the clock disagrees and lets the user decide.
    return shift;
  }

  // ── Device identity (anonymous, generated on first launch) ────────────────────

  static String _generateUuid() {
    final rand = Random.secure();
    final b = List<int>.generate(16, (_) => rand.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int x) => x.toRadixString(16).padLeft(2, '0');
    return '${h(b[0])}${h(b[1])}${h(b[2])}${h(b[3])}'
        '-${h(b[4])}${h(b[5])}'
        '-${h(b[6])}${h(b[7])}'
        '-${h(b[8])}${h(b[9])}'
        '-${h(b[10])}${h(b[11])}${h(b[12])}${h(b[13])}${h(b[14])}${h(b[15])}';
  }

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null) return existing;
    final id = _generateUuid();
    await prefs.setString(_deviceIdKey, id);
    return id;
  }

  // ── Export / import ────────────────────────────────────────────────────────────

  static Future<String> exportJson() async {
    final entries = await loadAll();
    final notes = await loadNotes();
    final deviceId = await getOrCreateDeviceId();
    final data = {
      'exportedAt': DateTime.now().toIso8601String(),
      'deviceId': deviceId,
      'entryCount': entries.length,
      'noteCount': notes.length,
      'entries': entries.map((e) => e.toJson()).toList(),
      // Notes used to live only under SharedPreferences `shift_notes` and were
      // omitted from export: included now so exports contain complete history.
      'notes': notes.map((n) => n.toJson()).toList(),
    };
    return jsonEncode(data);
  }

  // ── Notes ──────────────────────────────────────────────────────────────────

  static Future<List<ShiftNote>> loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_notesKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => ShiftNote.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> _saveNotes(List<ShiftNote> notes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_notesKey, jsonEncode(notes.map((n) => n.toJson()).toList()));
  }

  static Future<void> addNote(ShiftNote note) async {
    final all = await loadNotes();
    all.add(note);
    await _saveNotes(all);
    await writeAutoBackup();
  }

  static Future<void> deleteNote(String id) async {
    final all = await loadNotes();
    all.removeWhere((n) => n.id == id);
    await _saveNotes(all);
    await writeAutoBackup();
  }

  // ── Continuous auto-backup (app documents dir) ─────────────────────────────

  static Future<File> _autoBackupFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$autoBackupFileName');
  }

  /// Writes a full export snapshot. Best-effort; never throws to callers.
  static Future<void> writeAutoBackup() async {
    try {
      final json = await exportJson();
      final file = await _autoBackupFile();
      await file.writeAsString(json);
    } catch (_) {
      // Silent: backup must never break logging.
    }
  }

  static Future<bool> autoBackupExists() async {
    try {
      return await (await _autoBackupFile()).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> readAutoBackup() async {
    try {
      final file = await _autoBackupFile();
      if (!await file.exists()) return null;
      return file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Peek at an export envelope without writing. Used to warn when a file has
  /// no notes (pre-notes-support export or empty notes list).
  static ({bool hasNotesKey, int entryCount, int noteCount}) inspectExport(String jsonStr) {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final hasNotesKey = data.containsKey('notes');
    final entries = data['entries'] as List? ?? const [];
    final notes = data['notes'] as List? ?? const [];
    return (
      hasNotesKey: hasNotesKey,
      entryCount: entries.length,
      noteCount: notes.length,
    );
  }

  // ── Setup (shift rotation cycle) ────────────────────────────────────────────

  static Future<List<ShiftType>?> loadSetupCycle() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_setupKey);
    if (raw == null) return null;
    final parsed = raw.split(',').map(ShiftTypeX.fromString).whereType<ShiftType>().toList();
    return (parsed.length == 1 || parsed.length == 3) ? parsed : null;
  }

  static Future<void> saveSetupCycle(List<ShiftType> cycle) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_setupKey, cycle.map((s) => s.name).join(','));
  }

  // ── Daily target settings (shift length / breaks / dead time / rate) ───────

  static const _targetKey = 'target_settings';

  /// Never throws and never returns null: a corrupt blob falls back to the
  /// documented defaults (8h, 50m breaks, 20% dead time, 200/hr).
  static Future<TargetSettings> loadTargetSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_targetKey);
    if (raw == null) return TargetSettings.defaults;
    try {
      return TargetSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return TargetSettings.defaults;
    }
  }

  static Future<void> saveTargetSettings(TargetSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_targetKey, jsonEncode(s.toJson()));
  }

  // First-run Log coach marks (3 tips). Once done/skipped, never again.
  static const _coachMarksDoneKey = 'log_coach_marks_done';

  static Future<bool> loadCoachMarksDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_coachMarksDoneKey) ?? false;
  }

  static Future<void> saveCoachMarksDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_coachMarksDoneKey, true);
  }

  // Merges entries and notes by id so re-importing the same export twice is
  // harmless (no duplicates). Older exports without a `notes` key still load.
  // Returns (entryCount, noteCount) for the imported payload sizes.
  static Future<({int entries, int notes})> importJson(String jsonStr) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    final importedEntries =
        (data['entries'] as List? ?? const []).map((e) => PalletEntry.fromJson(e as Map<String, dynamic>)).toList();
    final existingEntries = await loadAll();
    final entriesById = {for (final e in existingEntries) e.id: e};
    for (final e in importedEntries) {
      entriesById[e.id] = e;
    }
    await saveAll(entriesById.values.toList());

    final rawNotes = data['notes'] as List? ?? const [];
    final importedNotes =
        rawNotes.map((e) => ShiftNote.fromJson(e as Map<String, dynamic>)).toList();
    final existingNotes = await loadNotes();
    final notesById = {for (final n in existingNotes) n.id: n};
    for (final n in importedNotes) {
      notesById[n.id] = n;
    }
    await _saveNotes(notesById.values.toList());
    await writeAutoBackup();

    return (entries: importedEntries.length, notes: importedNotes.length);
  }

  static List<ShiftSession> groupBySessions(List<PalletEntry> entries) {
    final map = <String, Map<String, dynamic>>{};
    for (final e in entries) {
      final dk = shiftDateKey(e.timestamp, e.shift);
      final key = '${dk}_${e.shift.name}';
      map.putIfAbsent(key, () => {'date': dk, 'shift': e.shift, 'entries': <PalletEntry>[]});
      (map[key]!['entries'] as List<PalletEntry>).add(e);
    }
    return map.values.map((v) => ShiftSession(
      dateKey: v['date'],
      shift: v['shift'],
      entries: v['entries'],
    )).toList()..sort((a, b) => b.dateKey.compareTo(a.dateKey));
  }
}
