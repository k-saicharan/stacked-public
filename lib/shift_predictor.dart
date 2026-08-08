import 'models.dart';
import 'storage.dart';

// Policy: Morning → Night → Afternoon → repeat (3-week counter-clockwise rotation)
// Morning:   Mon–Fri 07:00–15:00
// Night:     Sun 23:00 – Fri 07:00  (shift dates: Sun, Mon, Tue, Wed, Thu)
// Afternoon: Mon–Fri 15:00–23:00
//
// Transitions:
//   M → N : off Sat; Night starts Sunday 23:00
//   N → A : long weekend (Fri + Sat + Sun off); Afternoon starts Monday 15:00
//   A → M : off Sat–Sun; Morning starts Monday 07:00
//
// Overtime (RotationRole.extra): EXTRA HOURS on a day, not "this day isn't my shift".
// A block still anchors when (dateKey, shift) is on the person's rotation schedule.
// Extra only blocks anchoring on a normally-OFF day or wrong shift for that date
// (genuine cover / one-off) so pure off-day OT cannot slide the predicted rotation.

/// How much trust the UI should put in the schedule strip.
enum AnchorConfidence {
  /// Anchored on a schedule-consistent work day (incl. OT hours on that day), or setup.
  roster,
  /// Anchored via heuristic when schedule consistency is weak.
  estimated,
  /// No usable history and no setup cycle.
  none,
}

/// Result of schedule prediction, including anchor and confidence.
class ScheduleForecast {
  final List<({DateTime date, ShiftType shift})> days;
  final String? anchorDateKey;
  final ShiftType? anchorShift;
  final AnchorConfidence confidence;
  final bool anchorTimestampMismatch;
  final bool skippedNewerInconsistent;
  final String? warning;
  /// True when days come from setup answers with zero (or unused) logs.
  final bool fromSetup;

  const ScheduleForecast({
    required this.days,
    this.anchorDateKey,
    this.anchorShift,
    this.confidence = AnchorConfidence.none,
    this.anchorTimestampMismatch = false,
    this.skippedNewerInconsistent = false,
    this.warning,
    this.fromSetup = false,
  });

  bool get isEmpty => days.isEmpty;
  bool get isLowConfidence =>
      confidence == AnchorConfidence.estimated || confidence == AnchorConfidence.none;
}

class ShiftPredictor {
  static const _defaultCycle = [ShiftType.morning, ShiftType.night, ShiftType.evening];

  /// Predict upcoming shift-dates from logged sessions and/or setup cycle.
  ///
  /// Anchoring (2026-07 fluid-OT rules):
  /// 1. Schedule is source of truth: (date D, shift S) anchors when D is an
  ///    on-duty day for S under the rotation (setup cycle + projection math).
  /// 2. [RotationRole.extra] does NOT by itself prevent anchoring: OT before/
  ///    after the rostered window on a normal work day still anchors as S.
  /// 3. Extra (or any log) on a normally-OFF day / wrong shift for that date
  ///    does NOT move the rotation (stats only).
  /// 4. Zero logs + 3-shift setup: drive schedule from setup (current = cycle[0]).
  /// Never rewrites stored shift labels.
  static ScheduleForecast forecast(
    List<PalletEntry> entries, {
    int weeks = 4,
    List<ShiftType>? userCycle,
    DateTime? now,
  }) {
    if (userCycle != null && userCycle.length == 1) {
      return const ScheduleForecast(days: []);
    }
    final cycle = (userCycle != null && userCycle.length == 3) ? userCycle : _defaultCycle;
    final nowDt = now ?? DateTime.now();
    final sessions = Storage.groupBySessions(entries);

    // Setup alone must drive the schedule with zero logs (incl. fresh install).
    if (sessions.isEmpty) {
      if (userCycle != null && userCycle.length == 3) {
        return _forecastFromAnchor(
          lastDate: _nearestWorkDate(_dateOnly(nowDt), userCycle.first),
          lastShift: userCycle.first,
          cycle: cycle,
          weeks: weeks,
          now: nowDt,
          confidence: AnchorConfidence.roster,
          fromSetup: true,
        );
      }
      return const ScheduleForecast(
        days: [],
        confidence: AnchorConfidence.none,
        warning: 'Complete shift setup to build a schedule.',
      );
    }

    final pick = _pickAnchor(
      sessions,
      cycle: cycle,
      userCycle: userCycle,
      now: nowDt,
    );

    // No session is on-duty / plausible → fall back to setup, not a cover day.
    if (pick == null) {
      if (userCycle != null && userCycle.length == 3) {
        return _forecastFromAnchor(
          lastDate: _nearestWorkDate(_dateOnly(nowDt), userCycle.first),
          lastShift: userCycle.first,
          cycle: cycle,
          weeks: weeks,
          now: nowDt,
          confidence: AnchorConfidence.roster,
          fromSetup: true,
          warning: 'Logged days are off-rotation (cover/OT). Schedule from setup.',
        );
      }
      return const ScheduleForecast(
        days: [],
        confidence: AnchorConfidence.none,
        warning: 'No on-rotation days logged yet.',
      );
    }

    final last = pick.session;
    final lastDate = _parse(last.dateKey);
    final lastShift = last.shift;

    String? warning;
    if (pick.confidence == AnchorConfidence.estimated) {
      warning =
          'Estimated from older logs (not an affirmed Regular day). '
          'Anchored on ${last.dateKey} ${last.shift.label}. '
          'Mark days as Regular or Overtime from Stats so the schedule can be confident.';
    } else if (pick.skippedOffRotation || pick.skippedNewerInconsistent) {
      final parts = <String>[];
      if (pick.skippedOffRotation) {
        parts.add('skipped off-rotation / cover days (stats only, not rotation)');
      }
      if (pick.skippedNewerInconsistent) {
        parts.add('skipped logs that look inconsistent');
      }
      warning =
          '${parts.join('; ')}. '
          'Schedule from ${last.dateKey} ${last.shift.label}.';
    } else if (pick.anchorTimestampMismatch) {
      warning =
          'Most recent usable log (${last.dateKey} ${last.shift.label}) has unusual timestamps. '
          'Treat the schedule as an estimate.';
    }

    return _forecastFromAnchor(
      lastDate: lastDate,
      lastShift: lastShift,
      cycle: cycle,
      weeks: weeks,
      now: nowDt,
      confidence: pick.confidence,
      anchorTimestampMismatch: pick.anchorTimestampMismatch,
      skippedNewerInconsistent:
          pick.skippedNewerInconsistent || pick.skippedOffRotation,
      warning: warning,
    );
  }

  /// Whether (dateKey, shift) is an on-duty day for the person given [userCycle]
  /// and logged history. Used by UI to derive Regular vs Overtime.
  ///
  /// Returns true when the day is on the projected rotation (or, with no setup
  /// and thin history, when it is a plausible work date for that shift type).
  static bool isOnRotationDuty(
    String dateKey,
    ShiftType shift, {
    List<PalletEntry> entries = const [],
    List<ShiftType>? userCycle,
    DateTime? now,
  }) {
    if (userCycle != null && userCycle.length == 1) {
      return userCycle.first == shift && isPlausibleWorkDateKey(dateKey, shift);
    }
    final cycle = (userCycle != null && userCycle.length == 3) ? userCycle : _defaultCycle;
    final sessions = Storage.groupBySessions(entries);
    final duty = _buildDutyKeys(
      sessions: sessions,
      cycle: cycle,
      userCycle: userCycle,
      now: now ?? DateTime.now(),
    );
    if (duty.isEmpty) {
      return isPlausibleWorkDateKey(dateKey, shift);
    }
    return duty.contains(_dutyKey(dateKey, shift));
  }

  /// Build rotation days from a known anchor date + shift and cycle order.
  static ScheduleForecast _forecastFromAnchor({
    required DateTime lastDate,
    required ShiftType lastShift,
    required List<ShiftType> cycle,
    required int weeks,
    required DateTime now,
    required AnchorConfidence confidence,
    bool anchorTimestampMismatch = false,
    bool skippedNewerInconsistent = false,
    String? warning,
    bool fromSetup = false,
  }) {
    final weekEnd = _weekEnd(lastDate, lastShift);

    int idx = cycle.indexOf(lastShift);
    if (idx == -1) idx = 0;
    final result = <({DateTime date, ShiftType shift})>[];
    var blockEnd = weekEnd;

    var fill = lastDate;
    while (!fill.isAfter(weekEnd)) {
      result.add((date: fill, shift: lastShift));
      fill = fill.add(const Duration(days: 1));
    }

    final today = _dateOnly(now);
    final horizonEnd = today.add(Duration(days: weeks * 7));
    const maxBlocks = 52;
    var blocks = 0;

    while (blocks < maxBlocks && (result.isEmpty || !result.last.date.isAfter(horizonEnd))) {
      final nextShift = cycle[(idx + 1) % 3];
      final nextStart = _nextStart(blockEnd, cycle[idx % 3]);
      final workDates = _workDates(nextStart, nextShift);

      for (final d in workDates) {
        result.add((date: d, shift: nextShift));
      }

      blockEnd = workDates.last;
      idx++;
      blocks++;
    }

    final cutoff = today.subtract(const Duration(days: 1));
    final days = result
        .where((p) => !p.date.isBefore(cutoff))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    return ScheduleForecast(
      days: days,
      anchorDateKey: _formatKey(lastDate),
      anchorShift: lastShift,
      confidence: confidence,
      anchorTimestampMismatch: anchorTimestampMismatch,
      skippedNewerInconsistent: skippedNewerInconsistent,
      warning: warning,
      fromSetup: fromSetup,
    );
  }

  /// Nearest plausible work date on or before [from] for [shift].
  static DateTime _nearestWorkDate(DateTime from, ShiftType shift) {
    var d = _dateOnly(from);
    for (var i = 0; i < 14; i++) {
      if (isPlausibleWorkDateKey(_formatKey(d), shift)) return d;
      d = d.subtract(const Duration(days: 1));
    }
    return _dateOnly(from);
  }

  static String _formatKey(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  static String _dutyKey(String dateKey, ShiftType shift) =>
      '$dateKey|${shift.name}';

  static List<({DateTime date, ShiftType shift})> predictNext(
    List<PalletEntry> entries, {
    int weeks = 4,
    List<ShiftType>? userCycle,
    DateTime? now,
  }) =>
      forecast(entries, weeks: weeks, userCycle: userCycle, now: now).days;

  /// Pick the newest session that may move the rotation, or null if none.
  static ({
    ShiftSession session,
    bool anchorTimestampMismatch,
    bool skippedNewerInconsistent,
    bool skippedOffRotation,
    AnchorConfidence confidence,
  })? _pickAnchor(
    List<ShiftSession> sessions, {
    required List<ShiftType> cycle,
    List<ShiftType>? userCycle,
    required DateTime now,
  }) {
    final duty = _buildDutyKeys(
      sessions: sessions,
      cycle: cycle,
      userCycle: userCycle,
      now: now,
    );

    var skippedOffRotation = false;
    var skippedNewerInconsistent = false;

    // Sessions are newest-first by dateKey.
    final candidates = <ShiftSession>[];
    for (final s in sessions) {
      final onDuty = _sessionIsOnDuty(s, duty);
      if (!onDuty) {
        if (s.rotationRole == RotationRole.extra || !isPlausibleWorkDate(s)) {
          skippedOffRotation = true;
        } else {
          skippedNewerInconsistent = true;
        }
        continue;
      }
      if (!_labelMatchesTimestamps(s) && s.entries.length >= 2) {
        // Still allow but prefer better matches later.
      }
      candidates.add(s);
    }

    if (candidates.isEmpty) {
      // No on-duty day: last-resort estimated from newest plausible session
      // (never off-calendar pure OT alone: that returns null, triggering setup fallback).
      for (final s in sessions) {
        if (isPlausibleWorkDate(s)) {
          return (
            session: s,
            anchorTimestampMismatch: !_labelMatchesTimestamps(s),
            skippedNewerInconsistent: true,
            skippedOffRotation: skippedOffRotation,
            confidence: AnchorConfidence.estimated,
          );
        }
      }
      return null;
    }

    // Newest on-duty wins. Soft shift labels are user intent (OT may start
    // before the official window); do not demote them for hour mismatch.
    final best = candidates.first;
    final mismatch = !_labelMatchesTimestamps(best);

    // On-duty (schedule-consistent) → roster confidence, even if tagged Overtime.
    final confidence = duty.isNotEmpty || best.rotationRole == RotationRole.roster
        ? AnchorConfidence.roster
        : best.rotationRole == RotationRole.unset
            ? AnchorConfidence.estimated
            : AnchorConfidence.roster;

    return (
      session: best,
      anchorTimestampMismatch: mismatch,
      skippedNewerInconsistent: skippedNewerInconsistent,
      skippedOffRotation: skippedOffRotation,
      confidence: confidence,
    );
  }

  /// True when this session should move the rotation (on-duty day for its shift).
  static bool _sessionIsOnDuty(ShiftSession s, Set<String> duty) {
    // Calendar rule: night not Fri/Sat; M/E not weekend.
    if (!isPlausibleWorkDate(s)) return false;

    if (duty.isEmpty) {
      // Thin history / no setup: plausible work date is enough so OT-on-Morning
      // still anchors; pure weekend OT already failed plausible.
      return true;
    }

    final key = _dutyKey(s.dateKey, s.shift);
    if (duty.contains(key)) return true;

    // Date has a different on-duty shift, or is between blocks (off) → cover.
    return false;
  }

  /// Project on-duty (dateKey|shift) pairs from the best seed (setup and/or logs).
  static Set<String> _buildDutyKeys({
    required List<ShiftSession> sessions,
    required List<ShiftType> cycle,
    List<ShiftType>? userCycle,
    required DateTime now,
  }) {
    DateTime? seedDate;
    ShiftType? seedShift;

    // 1) Prefer newest roster-tagged plausible session as seed.
    for (final s in sessions) {
      if (s.rotationRole == RotationRole.roster && isPlausibleWorkDate(s)) {
        seedDate = _parse(s.dateKey);
        seedShift = s.shift;
        break;
      }
    }
    // 2) Else newest unset plausible.
    if (seedDate == null) {
      for (final s in sessions) {
        if (s.rotationRole == RotationRole.unset && isPlausibleWorkDate(s)) {
          seedDate = _parse(s.dateKey);
          seedShift = s.shift;
          break;
        }
      }
    }
    // 3) Setup current shift (cycle[0]) near now.
    if (seedDate == null && userCycle != null && userCycle.length == 3) {
      seedDate = _nearestWorkDate(_dateOnly(now), userCycle.first);
      seedShift = userCycle.first;
    }
    // 4) Any plausible session (incl. extra on a work day): bootstrap fluid OT.
    if (seedDate == null) {
      for (final s in sessions) {
        if (isPlausibleWorkDate(s)) {
          seedDate = _parse(s.dateKey);
          seedShift = s.shift;
          break;
        }
      }
    }
    // 5) Default cycle near now (no logs of use).
    if (seedDate == null) {
      seedDate = _nearestWorkDate(_dateOnly(now), cycle.first);
      seedShift = cycle.first;
    }

    return _projectDutyKeys(
      seedDate: seedDate,
      seedShift: seedShift!,
      cycle: cycle,
      weeks: 52,
    );
  }

  /// Project ~[weeks] of rotation duty keys around [seedDate]/[seedShift].
  static Set<String> _projectDutyKeys({
    required DateTime seedDate,
    required ShiftType seedShift,
    required List<ShiftType> cycle,
    int weeks = 52,
  }) {
    final keys = <String>{};
    int idx = cycle.indexOf(seedShift);
    if (idx == -1) idx = 0;

    // Current block containing seed.
    final start = _weekStart(seedDate, seedShift);
    final work = _workDates(start, seedShift);
    for (final d in work) {
      keys.add(_dutyKey(_formatKey(d), seedShift));
    }
    var blockEnd = work.last;
    var curIdx = idx;

    // Forward.
    final horizonEnd = _dateOnly(seedDate).add(Duration(days: weeks * 7));
    var blocks = 0;
    while (blocks < 60 && !blockEnd.isAfter(horizonEnd)) {
      final nextShift = cycle[(curIdx + 1) % 3];
      final nextStart = _nextStart(blockEnd, cycle[curIdx % 3]);
      final wd = _workDates(nextStart, nextShift);
      for (final d in wd) {
        keys.add(_dutyKey(_formatKey(d), nextShift));
      }
      blockEnd = wd.last;
      curIdx++;
      blocks++;
    }

    // Backward from seed block.
    var blockStart = start;
    curIdx = idx;
    final horizonStart = _dateOnly(seedDate).subtract(Duration(days: weeks * 7));
    blocks = 0;
    while (blocks < 60 && !blockStart.isBefore(horizonStart)) {
      final prevShift = cycle[(curIdx + 2) % 3]; // previous in cycle
      final prevEnd = _prevBlockEnd(blockStart, prevShift);
      final prevStart = _weekStart(prevEnd, prevShift);
      final wd = _workDates(prevStart, prevShift);
      for (final d in wd) {
        keys.add(_dutyKey(_formatKey(d), prevShift));
      }
      blockStart = prevStart;
      curIdx = (curIdx + 2) % 3;
      blocks++;
    }

    return keys;
  }

  static DateTime _weekStart(DateTime date, ShiftType shift) {
    var d = _dateOnly(date);
    if (shift == ShiftType.night) {
      while (d.weekday != DateTime.sunday) {
        d = d.subtract(const Duration(days: 1));
      }
      return d;
    }
    while (d.weekday != DateTime.monday) {
      d = d.subtract(const Duration(days: 1));
    }
    return d;
  }

  /// Last work date of the block that ends just before [nextBlockStart].
  static DateTime _prevBlockEnd(DateTime nextBlockStart, ShiftType prevShift) {
    var d = _dateOnly(nextBlockStart).subtract(const Duration(days: 1));
    // Walk back to a plausible end for prevShift (Thu night / Fri M-E).
    if (prevShift == ShiftType.night) {
      while (d.weekday != DateTime.thursday) {
        d = d.subtract(const Duration(days: 1));
      }
      return d;
    }
    while (d.weekday != DateTime.friday) {
      d = d.subtract(const Duration(days: 1));
    }
    return d;
  }

  static bool _labelMatchesTimestamps(ShiftSession s) {
    if (s.entries.length < 2) return true;
    final scores = <ShiftType, int>{
      for (final t in ShiftType.values) t: 0,
    };
    for (final e in s.entries) {
      for (final t in ShiftType.values) {
        if (_hourFitsShift(e.timestamp.hour, t)) {
          scores[t] = scores[t]! + 1;
        }
      }
    }
    final labelScore = scores[s.shift]!;
    final best = scores.values.fold<int>(0, (a, b) => a > b ? a : b);
    return labelScore > 0 && labelScore == best;
  }

  static bool isPlausibleWorkDate(ShiftSession s) =>
      isPlausibleWorkDateKey(s.dateKey, s.shift);

  static bool isPlausibleWorkDateKey(String dateKey, ShiftType shift) {
    final d = _parse(dateKey);
    if (shift == ShiftType.night) {
      return d.weekday != DateTime.friday && d.weekday != DateTime.saturday;
    }
    return d.weekday >= DateTime.monday && d.weekday <= DateTime.friday;
  }

  static bool _hourFitsShift(int hour, ShiftType shift) {
    switch (shift) {
      case ShiftType.morning:
        return hour >= 7 && hour < 15;
      case ShiftType.evening:
        return (hour >= 15 && hour < 23) || hour < 7;
      case ShiftType.night:
        return hour >= 23 || hour < 12;
    }
  }

  static DateTime _weekEnd(DateTime date, ShiftType shift) {
    var d = _dateOnly(date);
    if (shift == ShiftType.night) {
      if (d.weekday == DateTime.friday || d.weekday == DateTime.saturday) {
        while (d.weekday != DateTime.thursday) {
          d = d.subtract(const Duration(days: 1));
        }
        return d;
      }
      while (d.weekday != DateTime.thursday) {
        d = d.add(const Duration(days: 1));
      }
      return d;
    }
    if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      while (d.weekday != DateTime.friday) {
        d = d.subtract(const Duration(days: 1));
      }
      return d;
    }
    while (d.weekday != DateTime.friday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  static DateTime _nextStart(DateTime blockEnd, ShiftType currentShift) {
    var d = _dateOnly(blockEnd).add(const Duration(days: 1));
    switch (currentShift) {
      case ShiftType.morning:
        while (d.weekday != DateTime.sunday) {
          d = d.add(const Duration(days: 1));
        }
      case ShiftType.night:
        while (d.weekday != DateTime.monday) {
          d = d.add(const Duration(days: 1));
        }
      case ShiftType.evening:
        while (d.weekday != DateTime.monday) {
          d = d.add(const Duration(days: 1));
        }
    }
    return d;
  }

  static List<DateTime> _workDates(DateTime start, ShiftType shift) {
    final dates = <DateTime>[];
    var d = _dateOnly(start);
    for (int i = 0; i < 5; i++) {
      dates.add(d);
      d = d.add(const Duration(days: 1));
    }
    return dates;
  }

  static DateTime _parse(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
