import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/models.dart';
import 'package:pallet_tracker/shift_predictor.dart';

PalletEntry entry(DateTime ts, ShiftType shift, {int items = 10}) => PalletEntry(
      id: '${ts.millisecondsSinceEpoch}_${shift.name}',
      timestamp: ts,
      itemCount: items,
      shift: shift,
    );

void main() {
  group('ShiftPredictor.predictNext', () {
    test('from last morning 2026-06-19, Jul 20 is Evening (horizon covers gap)', () {
      // Matches real backup anchor: morning week ending Fri 19 Jun.
      // Correct rotation: N 21-25 Jun, E 29 Jun-3 Jul, M 6-10 Jul, N 12-16 Jul, E 20-24 Jul.
      final entries = [entry(DateTime(2026, 6, 19, 10), ShiftType.morning)];
      final now = DateTime(2026, 7, 20, 15, 0);
      final preds = ShiftPredictor.predictNext(entries, weeks: 4, now: now);

      expect(preds, isNotEmpty, reason: 'must not go empty after a multi-week logging gap');

      final jul20 = preds.where((p) =>
          p.date.year == 2026 && p.date.month == 7 && p.date.day == 20);
      expect(jul20, isNotEmpty);
      expect(jul20.first.shift, ShiftType.evening);

      // Surrounding block is a full evening week, then morning: not scrambled day-by-day.
      final lateJul = preds
          .where((p) => p.date.month == 7 && p.date.day >= 20 && p.date.day <= 24)
          .toList();
      expect(lateJul.every((p) => p.shift == ShiftType.evening), isTrue);
    });

    test('default cycle order after evening week is Morning then Night', () {
      final entries = [entry(DateTime(2026, 7, 3, 16), ShiftType.evening)];
      final now = DateTime(2026, 7, 6, 8, 0);
      final preds = ShiftPredictor.predictNext(entries, weeks: 4, now: now);

      ShiftType? shiftOn(int month, int day) {
        final m = preds.where((p) => p.date.month == month && p.date.day == day);
        return m.isEmpty ? null : m.first.shift;
      }

      expect(shiftOn(7, 6), ShiftType.morning);
      expect(shiftOn(7, 12), ShiftType.night);
      expect(shiftOn(7, 20), ShiftType.evening);
    });

    test('userCycle reverse order is honoured for shift sequence', () {
      // Evening → Night → Morning (user-defined)
      final cycle = [ShiftType.evening, ShiftType.night, ShiftType.morning];
      final entries = [entry(DateTime(2026, 7, 3, 16), ShiftType.evening)];
      final now = DateTime(2026, 7, 6, 8, 0);
      final preds = ShiftPredictor.predictNext(
        entries,
        weeks: 3,
        userCycle: cycle,
        now: now,
      );

      final mon = preds.where((p) => p.date.month == 7 && p.date.day == 6);
      expect(mon, isNotEmpty);
      expect(mon.first.shift, ShiftType.night);
    });

    test('night OT dated Friday does not jump weekEnd forward a week', () {
      // Thursday night week ends 16 Jul. Friday-dated night is off-calendar for
      // night (not a work date) and must not become the anchor / extend the block.
      final entries = [
        // 23:00 on Thu stays on 16 Jul night dateKey (3am would backshift to 15th).
        entry(DateTime(2026, 7, 16, 23), ShiftType.night),
        entry(DateTime(2026, 7, 17, 14), ShiftType.night), // Friday garbage OT
      ];
      final now = DateTime(2026, 7, 20, 15, 0);
      final f = ShiftPredictor.forecast(entries, weeks: 4, now: now);

      expect(f.anchorDateKey, '2026-07-16');
      expect(f.anchorShift, ShiftType.night);
      final jul20 = f.days.where((p) =>
          p.date.year == 2026 && p.date.month == 7 && p.date.day == 20);
      expect(jul20, isNotEmpty);
      expect(jul20.first.shift, ShiftType.evening);
    });

    test('in-progress week fill includes remaining days of last shift', () {
      final entries = [entry(DateTime(2026, 7, 6, 10), ShiftType.morning)]; // Monday
      final now = DateTime(2026, 7, 6, 12, 0);
      final preds = ShiftPredictor.predictNext(entries, weeks: 2, now: now);

      final mornings = preds
          .where((p) => p.shift == ShiftType.morning && p.date.month == 7 && p.date.day <= 10)
          .map((p) => p.date.day)
          .toList();
      expect(mornings, containsAll([6, 7, 8, 9, 10]));
    });

    test('fixed single-shift cycle returns no predictions', () {
      final entries = [entry(DateTime(2026, 7, 6, 10), ShiftType.morning)];
      final preds = ShiftPredictor.predictNext(
        entries,
        userCycle: [ShiftType.morning],
        now: DateTime(2026, 7, 6),
      );
      expect(preds, isEmpty);
    });

    test('setup cycle alone drives schedule with zero logs (not low confidence)', () {
      // Setup stores [current, third, previous]. Zero entries must still fill days.
      final cycle = [ShiftType.evening, ShiftType.morning, ShiftType.night];
      final now = DateTime(2026, 7, 20, 15, 0); // Monday evening-capable
      final f = ShiftPredictor.forecast(
        const [],
        weeks: 4,
        userCycle: cycle,
        now: now,
      );
      expect(f.days, isNotEmpty, reason: 'setup alone must populate Schedule');
      expect(f.fromSetup, isTrue);
      expect(f.confidence, AnchorConfidence.roster);
      expect(f.isLowConfidence, isFalse);
      expect(f.anchorShift, ShiftType.evening);
      // Remaining evening block (Mon–Fri) should include Jul 20–24.
      final eve = f.days
          .where((p) => p.shift == ShiftType.evening && p.date.month == 7 && p.date.day >= 20 && p.date.day <= 24)
          .map((p) => p.date.day)
          .toList();
      expect(eve, containsAll([20, 21, 22, 23, 24]));
    });

    test('zero logs and no setup stays empty (none confidence)', () {
      final f = ShiftPredictor.forecast(const [], now: DateTime(2026, 7, 20));
      expect(f.days, isEmpty);
      expect(f.confidence, AnchorConfidence.none);
      expect(f.isLowConfidence, isTrue);
    });

    test('(a) OT before rostered Morning still anchors as Morning', () {
      // Came in 3am, labeled Morning, tagged Overtime: still a Mon Morning roster day.
      final entries = [
        PalletEntry(
          id: 'ot1',
          timestamp: DateTime(2026, 7, 20, 3, 15), // Mon 3am OT before 7am
          itemCount: 10,
          shift: ShiftType.morning,
          rotationRole: RotationRole.extra,
        ),
        PalletEntry(
          id: 'ot2',
          timestamp: DateTime(2026, 7, 20, 8, 0),
          itemCount: 12,
          shift: ShiftType.morning,
          rotationRole: RotationRole.extra,
        ),
      ];
      final f = ShiftPredictor.forecast(
        entries,
        weeks: 4,
        now: DateTime(2026, 7, 20, 12),
      );
      expect(f.anchorDateKey, '2026-07-20');
      expect(f.anchorShift, ShiftType.morning);
      expect(f.confidence, AnchorConfidence.roster);
      expect(f.days, isNotEmpty);
    });

    test('(b) pure OT on a normally-off day does NOT move the rotation', () {
      // Saturday morning is never a Morning work date; prior Fri Morning is the anchor.
      final entries = [
        PalletEntry(
          id: 'fri',
          timestamp: DateTime(2026, 7, 17, 10), // Friday morning roster
          itemCount: 10,
          shift: ShiftType.morning,
          rotationRole: RotationRole.roster,
        ),
        PalletEntry(
          id: 'sat-ot',
          timestamp: DateTime(2026, 7, 18, 9), // Saturday cover OT
          itemCount: 8,
          shift: ShiftType.morning,
          rotationRole: RotationRole.extra,
        ),
      ];
      final f = ShiftPredictor.forecast(
        entries,
        weeks: 4,
        now: DateTime(2026, 7, 20, 12),
      );
      expect(f.anchorDateKey, isNot('2026-07-18'));
      expect(f.anchorDateKey, '2026-07-17');
      expect(f.anchorShift, ShiftType.morning);
      expect(f.confidence, AnchorConfidence.roster);
    });

    test('filter uses date-only cutoff so yesterday is kept', () {
      final entries = [entry(DateTime(2026, 7, 20, 16), ShiftType.evening)];
      // Late evening "now": time-bearing cutoff used to drop same-calendar-day-1 midnight.
      final now = DateTime(2026, 7, 21, 22, 0);
      final preds = ShiftPredictor.predictNext(entries, weeks: 2, now: now);
      final jul20 = preds.where((p) => p.date.day == 20 && p.date.month == 7);
      expect(jul20, isNotEmpty);
    });
  });
}
