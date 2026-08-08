import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/models.dart';
import 'package:pallet_tracker/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsePalletInput', () {
    test("parses '120 / 4' as 120 items and 4 stops", () {
      final p = parsePalletInput('120 / 4');
      expect(p, isNotNull);
      expect(p!.items, 120);
      expect(p.stops, 4);
    });

    test('items-only defaults stops to 1', () {
      final p = parsePalletInput('120');
      expect(p!.items, 120);
      expect(p.stops, 1);
    });

    test('trailing slash or empty stops defaults to 1', () {
      expect(parsePalletInput('120 / ')!.stops, 1);
      expect(parsePalletInput('120/')!.stops, 1);
    });

    test('empty or invalid items is null', () {
      expect(parsePalletInput(''), isNull);
      expect(parsePalletInput(' / 4'), isNull);
      expect(parsePalletInput('0'), isNull);
      expect(parsePalletInput('0 / 2'), isNull);
    });

    test('compact form without spaces works', () {
      final p = parsePalletInput('85/3');
      expect(p!.items, 85);
      expect(p.stops, 3);
    });
  });

  group('PalletEntry stops', () {
    test('missing stops key on import defaults to 1', () {
      final e = PalletEntry.fromJson({
        'id': 'legacy',
        'timestamp': '2026-07-20T10:00:00.000',
        'itemCount': 50,
        'shift': 'morning',
      });
      expect(e.stops, 1);
      expect(e.toJson()['stops'], 1);
    });

    test('stops round-trips in toJson/fromJson', () {
      final e = PalletEntry(
        id: 's1',
        timestamp: DateTime(2026, 7, 20, 10),
        itemCount: 120,
        stops: 4,
        shift: ShiftType.evening,
      );
      final again = PalletEntry.fromJson(e.toJson());
      expect(again.stops, 4);
      expect(again.itemCount, 120);
    });

    test('zero or negative stops normalize to 1', () {
      final e = PalletEntry(
        id: 'z',
        timestamp: DateTime(2026, 7, 20),
        itemCount: 10,
        stops: 0,
        shift: ShiftType.morning,
      );
      expect(e.stops, 1);
      expect(normalizeStops(0), 1);
      expect(normalizeStops(-3), 1);
      expect(normalizeStops(null), 1);
    });
  });

  group('ShiftSession density', () {
    test('items/stop and stops/pallet', () {
      final s = ShiftSession(
        dateKey: '2026-07-20',
        shift: ShiftType.evening,
        entries: [
          PalletEntry(
            id: '1',
            timestamp: DateTime(2026, 7, 20, 15),
            itemCount: 100,
            stops: 4,
            shift: ShiftType.evening,
          ),
          PalletEntry(
            id: '2',
            timestamp: DateTime(2026, 7, 20, 16),
            itemCount: 50,
            stops: 2,
            shift: ShiftType.evening,
          ),
        ],
      );
      expect(s.totalStops, 6);
      expect(s.totalItems, 150);
      expect(s.itemsPerStop, 25.0); // 150/6
      expect(s.avgStopsPerPallet, 3.0); // 6/2
      expect(s.densityLine, contains('items/stop'));
      expect(s.densityLine, contains('stops/pallet'));
    });

    test('itemsPerStop guards divide-by-zero', () {
      final s = ShiftSession(
        dateKey: '2026-07-20',
        shift: ShiftType.morning,
        entries: const [],
      );
      expect(s.totalStops, 0);
      expect(s.itemsPerStop, 0.0); // 0 items / 1
    });
  });

  group('export/import stops', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('export includes stops; legacy import without stops key defaults to 1', () async {
      await Storage.addEntry(PalletEntry(
        id: 'with-stops',
        timestamp: DateTime(2026, 7, 20, 12),
        itemCount: 90,
        stops: 5,
        shift: ShiftType.evening,
      ));
      final exported = await Storage.exportJson();
      final map = jsonDecode(exported) as Map<String, dynamic>;
      final row = (map['entries'] as List).cast<Map<String, dynamic>>().first;
      expect(row['stops'], 5);

      SharedPreferences.setMockInitialValues({});
      final legacy = jsonEncode({
        'exportedAt': '2026-06-01T00:00:00.000',
        'entryCount': 1,
        'entries': [
          {
            'id': 'old',
            'timestamp': '2026-06-01T10:00:00.000',
            'itemCount': 40,
            'shift': 'morning',
          },
        ],
      });
      await Storage.importJson(legacy);
      final loaded = await Storage.loadAll();
      expect(loaded.single.id, 'old');
      expect(loaded.single.stops, 1);
    });
  });
}
