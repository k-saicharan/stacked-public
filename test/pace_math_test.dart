import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/models.dart';

void main() {
  group('ShiftSession pace math', () {
    test('empty session is zero', () {
      final s = ShiftSession(
        dateKey: '2026-07-20',
        shift: ShiftType.evening,
        entries: [],
      );
      expect(s.estimatedHoursWorked, 0);
      expect(s.itemsPerHourPace, 0);
    });

    test('single pallet uses 1.0h placeholder', () {
      final s = ShiftSession(
        dateKey: '2026-07-20',
        shift: ShiftType.evening,
        entries: [
          PalletEntry(
            id: '1',
            timestamp: DateTime(2026, 7, 20, 15, 0),
            itemCount: 100,
            shift: ShiftType.evening,
          ),
        ],
      );
      expect(s.estimatedHoursWorked, 1.0);
      expect(s.itemsPerHourPace, 100);
      expect(s.paceLine, contains('single pallet'));
    });

    test('multi pallet: first to last + 30m pad; pace = items ÷ hours', () {
      // 15:00 → 23:00 = 8.0h raw + 0.5 pad = 8.5h; 850 items → 100/hr
      final s = ShiftSession(
        dateKey: '2026-07-20',
        shift: ShiftType.evening,
        entries: [
          PalletEntry(
            id: '1',
            timestamp: DateTime(2026, 7, 20, 15, 0),
            itemCount: 425,
            shift: ShiftType.evening,
          ),
          PalletEntry(
            id: '2',
            timestamp: DateTime(2026, 7, 20, 23, 0),
            itemCount: 425,
            shift: ShiftType.evening,
          ),
        ],
      );
      expect(s.rawSpanHours, 8.0);
      expect(s.estimatedHoursWorked, 8.5);
      expect(s.totalItems, 850);
      expect(s.itemsPerHourPace, 100); // 850 / 8.5
      expect(s.paceLine, contains('850 items ÷ 8.5h span'));
      expect(s.paceLine, contains('first to last + 30m pad'));
      expect(s.hoursWorkedLabel, '8.5h span');
    });
  });
}
