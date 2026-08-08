import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pallet_tracker/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('exportJson includes notes; importJson merges notes by id (idempotent)', () async {
    final entry = PalletEntry(
      id: 'e1',
      timestamp: DateTime(2026, 7, 20, 10),
      itemCount: 12,
      shift: ShiftType.evening,
    );
    final note = ShiftNote(
      id: 'n1',
      timestamp: DateTime(2026, 7, 20, 11),
      shift: ShiftType.evening,
      text: 'belt jam',
    );
    await Storage.addEntry(entry);
    await Storage.addNote(note);

    final exported = await Storage.exportJson();
    final map = jsonDecode(exported) as Map<String, dynamic>;
    expect(map['entries'], isA<List>());
    expect(map['notes'], isA<List>());
    expect(map['noteCount'], 1);
    expect((map['notes'] as List).length, 1);
    expect((map['notes'] as List).first['id'], 'n1');
    expect((map['notes'] as List).first['text'], 'belt jam');

    // Wipe local storage, re-import once
    SharedPreferences.setMockInitialValues({});
    final first = await Storage.importJson(exported);
    expect(first.entries, 1);
    expect(first.notes, 1);
    expect((await Storage.loadNotes()).map((n) => n.id), ['n1']);
    expect((await Storage.loadAll()).map((e) => e.id), ['e1']);

    // Re-import same file: still one note, not duplicated
    final second = await Storage.importJson(exported);
    expect(second.entries, 1);
    expect(second.notes, 1);
    final notes = await Storage.loadNotes();
    expect(notes.length, 1);
    expect(notes.first.id, 'n1');
    expect(notes.first.text, 'belt jam');
  });

  test('importJson accepts legacy exports without notes key', () async {
    final legacy = jsonEncode({
      'exportedAt': '2026-06-21T21:00:00.000',
      'deviceId': 'dev',
      'entryCount': 1,
      'entries': [
        {
          'id': 'legacy1',
          'timestamp': '2026-06-19T10:00:00.000',
          'itemCount': 10,
          'shift': 'morning',
        },
      ],
    });
    final counts = await Storage.importJson(legacy);
    expect(counts.entries, 1);
    expect(counts.notes, 0);
    expect((await Storage.loadAll()).single.id, 'legacy1');
    expect(await Storage.loadNotes(), isEmpty);
  });

  test('importJson merges notes without dropping existing different ids', () async {
    await Storage.addNote(ShiftNote(
      id: 'local-only',
      timestamp: DateTime(2026, 7, 1),
      shift: ShiftType.morning,
      text: 'kept',
    ));
    final payload = jsonEncode({
      'entries': <dynamic>[],
      'notes': [
        {
          'id': 'imported',
          'timestamp': '2026-07-02T12:00:00.000',
          'shift': 'night',
          'text': 'from file',
        },
      ],
    });
    await Storage.importJson(payload);
    final ids = (await Storage.loadNotes()).map((n) => n.id).toSet();
    expect(ids, {'local-only', 'imported'});
  });

  test('inspectExport flags legacy files without notes key', () {
    final legacy = jsonEncode({
      'entryCount': 1,
      'entries': [
        {
          'id': 'e',
          'timestamp': '2026-06-19T10:00:00.000',
          'itemCount': 1,
          'shift': 'morning',
        },
      ],
    });
    final peek = Storage.inspectExport(legacy);
    expect(peek.hasNotesKey, isFalse);
    expect(peek.noteCount, 0);
    expect(peek.entryCount, 1);
  });

  test('inspectExport reports notes when present', () {
    final modern = jsonEncode({
      'entries': <dynamic>[],
      'notes': [
        {
          'id': 'n',
          'timestamp': '2026-07-01T12:00:00.000',
          'shift': 'evening',
          'text': 'hi',
        },
      ],
    });
    final peek = Storage.inspectExport(modern);
    expect(peek.hasNotesKey, isTrue);
    expect(peek.noteCount, 1);
  });

  test('isExtraShift round-trips export/import merge-by-id', () async {
    final entry = PalletEntry(
      id: 'extra1',
      timestamp: DateTime(2026, 7, 18, 10),
      itemCount: 5,
      shift: ShiftType.morning,
      isExtraShift: true,
    );
    await Storage.addEntry(entry);
    final exported = await Storage.exportJson();
    final map = jsonDecode(exported) as Map<String, dynamic>;
    final row = (map['entries'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['id'] == 'extra1');
    expect(row['isExtraShift'], isTrue);

    SharedPreferences.setMockInitialValues({});
    await Storage.importJson(exported);
    final loaded = await Storage.loadAll();
    expect(loaded.single.id, 'extra1');
    expect(loaded.single.isExtraShift, isTrue);

    // Re-import does not duplicate
    await Storage.importJson(exported);
    expect((await Storage.loadAll()).length, 1);
  });

  test('setSessionExtraShift marks all entries in session', () async {
    await Storage.addEntry(PalletEntry(
      id: 'a',
      timestamp: DateTime(2026, 7, 18, 8),
      itemCount: 1,
      shift: ShiftType.morning,
    ));
    await Storage.addEntry(PalletEntry(
      id: 'b',
      timestamp: DateTime(2026, 7, 18, 9),
      itemCount: 2,
      shift: ShiftType.morning,
    ));
    await Storage.setSessionExtraShift('2026-07-18', ShiftType.morning, true);
    final all = await Storage.loadAll();
    expect(all.every((e) => e.isExtraShift), isTrue);
    await Storage.setSessionExtraShift('2026-07-18', ShiftType.morning, false);
    expect((await Storage.loadAll()).every((e) => !e.isExtraShift), isTrue);
  });

  test('setSessionRotationRole roster round-trips on export', () async {
    await Storage.addEntry(PalletEntry(
      id: 'r',
      timestamp: DateTime(2026, 7, 10, 10),
      itemCount: 3,
      shift: ShiftType.morning,
      rotationRole: RotationRole.roster,
    ));
    final map = jsonDecode(await Storage.exportJson()) as Map<String, dynamic>;
    final row = (map['entries'] as List).cast<Map<String, dynamic>>().single;
    expect(row['rotationRole'], 'roster');
    expect(row['isExtraShift'], isFalse);
  });
}
