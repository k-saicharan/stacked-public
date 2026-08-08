import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/models.dart';

void main() {
  group('isWithinRosterWindow ±15m grace', () {
    DateTime at(int h, int m) => DateTime(2026, 7, 29, h, m);

    test('morning: 06:50 Regular band, 06:44 outside', () {
      expect(isWithinRosterWindow(ShiftType.morning, at(6, 50)), isTrue);
      expect(isWithinRosterWindow(ShiftType.morning, at(6, 44)), isFalse);
      expect(isWithinRosterWindow(ShiftType.morning, at(15, 15)), isTrue);
      expect(isWithinRosterWindow(ShiftType.morning, at(15, 16)), isFalse);
      expect(isWithinRosterWindow(ShiftType.morning, at(10, 0)), isTrue);
    });

    test('evening: 23:10 inside, 23:20 outside; 14:45 edge', () {
      expect(isWithinRosterWindow(ShiftType.evening, at(23, 10)), isTrue);
      expect(isWithinRosterWindow(ShiftType.evening, at(23, 15)), isTrue);
      expect(isWithinRosterWindow(ShiftType.evening, at(23, 20)), isFalse);
      expect(isWithinRosterWindow(ShiftType.evening, at(14, 45)), isTrue);
      expect(isWithinRosterWindow(ShiftType.evening, at(14, 44)), isFalse);
      expect(isWithinRosterWindow(ShiftType.evening, at(18, 0)), isTrue);
    });

    test('night: wraps midnight; 07:10 inside, 07:20 outside; 22:45 edge', () {
      expect(isWithinRosterWindow(ShiftType.night, at(23, 30)), isTrue);
      expect(isWithinRosterWindow(ShiftType.night, at(2, 0)), isTrue);
      expect(isWithinRosterWindow(ShiftType.night, at(7, 10)), isTrue);
      expect(isWithinRosterWindow(ShiftType.night, at(7, 15)), isTrue);
      expect(isWithinRosterWindow(ShiftType.night, at(7, 20)), isFalse);
      expect(isWithinRosterWindow(ShiftType.night, at(22, 45)), isTrue);
      expect(isWithinRosterWindow(ShiftType.night, at(22, 44)), isFalse);
      expect(isWithinRosterWindow(ShiftType.night, at(12, 0)), isFalse);
    });
  });

  group('suggestedRoleFromWindow', () {
    DateTime at(int h, int m) => DateTime(2026, 7, 29, h, m);

    test('outside window → OT even when on duty', () {
      final role = suggestedRoleFromWindow(
        shift: ShiftType.morning,
        timestamp: at(16, 0),
        onDuty: true,
      );
      expect(role, RotationRole.extra);
    });

    test('inside window + on duty → Regular', () {
      final role = suggestedRoleFromWindow(
        shift: ShiftType.evening,
        timestamp: at(18, 0),
        onDuty: true,
      );
      expect(role, RotationRole.roster);
    });

    test('inside window + off duty → OT', () {
      final role = suggestedRoleFromWindow(
        shift: ShiftType.evening,
        timestamp: at(18, 0),
        onDuty: false,
      );
      expect(role, RotationRole.extra);
    });

    test('spec edges: morning 06:50 on-duty Regular; 06:44 OT', () {
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.morning,
          timestamp: at(6, 50),
          onDuty: true,
        ),
        RotationRole.roster,
      );
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.morning,
          timestamp: at(6, 44),
          onDuty: true,
        ),
        RotationRole.extra,
      );
    });

    test('evening 23:10 Regular; 23:20 OT', () {
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.evening,
          timestamp: at(23, 10),
          onDuty: true,
        ),
        RotationRole.roster,
      );
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.evening,
          timestamp: at(23, 20),
          onDuty: true,
        ),
        RotationRole.extra,
      );
    });

    test('night 07:10 Regular; 07:20 OT', () {
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.night,
          timestamp: at(7, 10),
          onDuty: true,
        ),
        RotationRole.roster,
      );
      expect(
        suggestedRoleFromWindow(
          shift: ShiftType.night,
          timestamp: at(7, 20),
          onDuty: true,
        ),
        RotationRole.extra,
      );
    });
  });
}
