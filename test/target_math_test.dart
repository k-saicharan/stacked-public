import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pallet_tracker/main.dart';
import 'package:pallet_tracker/models.dart';

/// Reference case supplied by the floor:
///   8h shift, 20m + 30m breaks, 20% miscellaneous dead time, 200 items/hr
///   → (8 − 0.8333) × 0.80 = 5.7333 productive hours → ≈1147 items.
const _ref = TargetSettings(
  shiftHours: 8,
  breakMinutes: 50,
  deadTimePct: 0.20,
  targetRate: 200,
);

ShiftSession _session(List<({DateTime at, int items})> picks) => ShiftSession(
      dateKey: '2026-07-29',
      shift: ShiftType.evening,
      entries: [
        for (var i = 0; i < picks.length; i++)
          PalletEntry(
            id: '$i',
            timestamp: picks[i].at,
            itemCount: picks[i].items,
            shift: ShiftType.evening,
          ),
      ],
    );

void main() {
  group('TargetSettings : target benchmark formula', () {
    test('breaks apply first, followed by operational allowance', () {
      expect(_ref.productiveHours, closeTo(5.7333, 0.001));
      expect(_ref.dailyTargetItems, 1147);
    });

    test('defaults match the reference case', () {
      expect(TargetSettings.defaults.productiveHours, closeTo(5.7333, 0.001));
      expect(TargetSettings.defaults.dailyTargetItems, 1147);
    });

    test('productive fraction scales wall-clock into productive time', () {
      expect(_ref.productiveFraction, closeTo(0.71667, 0.0001));
    });

    test('no dead time → only breaks come off', () {
      const s = TargetSettings(
          shiftHours: 8, breakMinutes: 50, deadTimePct: 0, targetRate: 200);
      expect(s.productiveHours, closeTo(7.1667, 0.001));
      expect(s.dailyTargetItems, 1433);
    });

    test('breaks longer than the shift collapse to zero, never negative', () {
      const s = TargetSettings(shiftHours: 1, breakMinutes: 90);
      expect(s.productiveHours, 0);
      expect(s.dailyTargetItems, 0);
      expect(s.productiveFraction, 0);
    });

    test('formula line states every input', () {
      expect(_ref.formulaLine, contains('8h'));
      expect(_ref.formulaLine, contains('50m breaks'));
      expect(_ref.formulaLine, contains('20% dead time'));
      expect(_ref.formulaLine, contains('200/hr'));
    });

    test('fromJson falls back on garbage instead of throwing', () {
      final s = TargetSettings.fromJson({
        'shiftHours': 'nonsense',
        'breakMinutes': null,
        'deadTimePct': 5.0, // out of range
        'targetRate': -3,
      });
      expect(s.shiftHours, 8.0);
      expect(s.breakMinutes, 50);
      expect(s.deadTimePct, 0.20);
      expect(s.targetRate, 200);
    });

    test('round-trips through json', () {
      const s = TargetSettings(
          shiftHours: 10, breakMinutes: 40, deadTimePct: 0.15, targetRate: 180);
      final back = TargetSettings.fromJson(s.toJson());
      expect(back.shiftHours, 10);
      expect(back.breakMinutes, 40);
      expect(back.deadTimePct, closeTo(0.15, 1e-9));
      expect(back.targetRate, 180);
    });
  });

  group('ShiftSession : speed evaluated against the target goal', () {
    // 6h logged span → 6 × 0.71667 = 4.3 productive hours; 860 items = 200/hr.
    final onPace = _session([
      (at: DateTime(2026, 7, 29, 15, 0), items: 430),
      (at: DateTime(2026, 7, 29, 21, 0), items: 430),
    ]);

    test('elapsed productive hours scale the logged span', () {
      expect(onPace.elapsedProductiveHours(_ref), closeTo(4.3, 0.001));
    });

    test('items per productive hour matches the 200/hr benchmark target', () {
      expect(onPace.itemsPerProductiveHour(_ref), 200);
    });

    test('projection at 200/hr lands on the target', () {
      expect(onPace.projectedItems(_ref), 1147);
      expect(onPace.onTargetPace(_ref), isTrue);
    });

    test('progress and remaining track the target', () {
      expect(onPace.targetProgress(_ref), closeTo(860 / 1147, 0.0001));
      expect(onPace.itemsRemaining(_ref), 287);
      expect(onPace.productiveHoursRemaining(_ref), closeTo(1.4333, 0.001));
      expect(onPace.requiredRate(_ref), 201);
    });

    test('shift below target pace requires higher rate to meet goal', () {
      final paceLag = _session([
        (at: DateTime(2026, 7, 29, 15, 0), items: 200),
        (at: DateTime(2026, 7, 29, 21, 0), items: 200),
      ]);
      expect(paceLag.itemsPerProductiveHour(_ref), 93);
      expect(paceLag.onTargetPace(_ref), isFalse);
      expect(paceLag.requiredRate(_ref)!, greaterThan(_ref.targetRate));
    });

    test('elapsed productive time is capped so remaining never goes negative', () {
      final overrun = _session([
        (at: DateTime(2026, 7, 29, 8, 0), items: 100),
        (at: DateTime(2026, 7, 30, 4, 0), items: 100), // 20h span
      ]);
      expect(overrun.elapsedProductiveHours(_ref), closeTo(_ref.productiveHours, 1e-9));
      expect(overrun.productiveHoursRemaining(_ref), 0);
      // No productive time left to make it up in.
      expect(overrun.requiredRate(_ref), isNull);
      expect(overrun.targetSubline(_ref), contains('used up'));
    });

    test('single pallet has no span yet: rate stays 0, no divide by zero', () {
      final one = _session([(at: DateTime(2026, 7, 29, 15, 0), items: 120)]);
      expect(one.elapsedProductiveHours(_ref), 0);
      expect(one.itemsPerProductiveHour(_ref), 0);
      expect(one.projectedItems(_ref), 120);
      expect(one.requiredRate(_ref), isNotNull);
    });

    test('empty session is all zeroes', () {
      final none = _session([]);
      expect(none.targetProgress(_ref), 0);
      expect(none.itemsPerProductiveHour(_ref), 0);
      expect(none.itemsRemaining(_ref), 1147);
    });

    test('target met reports the overshoot', () {
      final done = _session([
        (at: DateTime(2026, 7, 29, 15, 0), items: 600),
        (at: DateTime(2026, 7, 29, 21, 0), items: 600),
      ]);
      expect(done.itemsRemaining(_ref), 0);
      expect(done.requiredRate(_ref), 0);
      expect(done.targetSubline(_ref), contains('Target met'));
      expect(done.targetSubline(_ref), contains('53')); // 1200 − 1147
    });

    test('zero target never divides by zero', () {
      const broken = TargetSettings(shiftHours: 1, breakMinutes: 90);
      expect(onPace.targetProgress(broken), 0);
      expect(onPace.elapsedProductiveHours(broken), 0);
    });
  });

  group('AppColors.rampColor : continuous amber to green ramp', () {
    test('hits the three stops exactly', () {
      expect(AppColors.rampColor(0), AppColors.targetLow);
      expect(AppColors.rampColor(0.5), AppColors.targetMid);
      expect(AppColors.rampColor(1), AppColors.targetHigh);
    });

    test('clamps out-of-range input instead of throwing', () {
      expect(AppColors.rampColor(-5), AppColors.targetLow);
      expect(AppColors.rampColor(9), AppColors.targetHigh);
      expect(AppColors.rampColor(double.nan), AppColors.targetLow);
    });

    test('is continuous: smooth transition across the ramp', () {
      // Adjacent 1% steps must never jump hard, which is what would make the
      // bar read as three blocks instead of one gradient.
      Color prev = AppColors.rampColor(0);
      for (var i = 1; i <= 100; i++) {
        final c = AppColors.rampColor(i / 100);
        final delta = (c.r - prev.r).abs() +
            (c.g - prev.g).abs() +
            (c.b - prev.b).abs();
        expect(delta, lessThan(0.06), reason: 'hard jump at t=${i / 100}');
        prev = c;
      }
    });

    test('progresses smoothly through target ramp colors', () {
      // Green channel rises monotonically; that is the "getting there" signal.
      var prevG = AppColors.rampColor(0).g;
      for (var i = 1; i <= 100; i++) {
        final g = AppColors.rampColor(i / 100).g;
        expect(g, greaterThanOrEqualTo(prevG - 1e-6));
        prevG = g;
      }
      expect(AppColors.rampColor(1).g, greaterThan(AppColors.rampColor(0).g));
    });
  });
}
