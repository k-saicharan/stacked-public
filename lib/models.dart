enum ShiftType { morning, evening, night }

/// Whether a work block counts toward schedule rotation.
/// Soft shift labels (morning/evening/night) remain for display/stats only.
enum RotationRole {
  /// Normal rostered day (or default). Schedule-consistent days anchor rotation.
  roster,
  /// Extra hours / cover. Does NOT by itself prevent anchoring: OT on an
  /// on-duty day still anchors as that shift. Only off-rotation cover days
  /// are excluded from moving the schedule (see ShiftPredictor).
  extra,
  /// History default / not yet tagged. Soft; schedule derives Regular vs OT.
  unset,
}

extension RotationRoleX on RotationRole {
  /// UI labels. Never show "Untagged"/"Not set"/"unset" in the product UI.
  String get label {
    switch (this) {
      case RotationRole.roster: return 'Regular';
      case RotationRole.extra: return 'Overtime';
      case RotationRole.unset: return ''; // never surface in UI
    }
  }

  static RotationRole? fromString(String? s) {
    if (s == null) return null;
    for (final r in RotationRole.values) {
      if (r.name == s) return r;
    }
    return null;
  }

  /// Prefer [rotationRole] field; map legacy isExtraShift true → extra, else unset.
  static RotationRole fromStorage(Map<String, dynamic> j) {
    final named = fromString(j['rotationRole'] as String?);
    if (named != null) return named;
    if (j['isExtraShift'] == true) return RotationRole.extra;
    return RotationRole.unset;
  }
}

extension ShiftTypeX on ShiftType {
  String get label {
    switch (this) {
      case ShiftType.morning: return 'Morning';
      case ShiftType.evening: return 'Evening';
      case ShiftType.night: return 'Night';
    }
  }

  String get timeRange {
    switch (this) {
      case ShiftType.morning: return '7am – 3pm';
      case ShiftType.evening: return '3pm – 11pm';
      case ShiftType.night: return '11pm – 7am';
    }
  }

  static ShiftType fromNow() {
    final h = DateTime.now().hour;
    if (h >= 7 && h < 15) return ShiftType.morning;
    if (h >= 15 && h < 23) return ShiftType.evening;
    return ShiftType.night;
  }

  static ShiftType? fromString(String s) {
    for (final t in ShiftType.values) {
      if (t.name == s) return t;
    }
    return null;
  }
}

/// Default grace around each rigid roster window (owner decision 2026-07-29).
const Duration kRosterGrace = Duration(minutes: 15);

/// Minutes since local midnight (0…1439).
int _minutesOfDay(DateTime t) => t.hour * 60 + t.minute;

/// Whether [t] falls inside the official shift window expanded by [grace]
/// on both sides. Night wraps midnight.
///
/// Official windows: Morning 07:00–15:00, Evening 15:00–23:00, Night 23:00–07:00.
/// With 15m grace: Morning 06:45–15:15, Evening 14:45–23:15, Night 22:45–07:15.
bool isWithinRosterWindow(
  ShiftType shift,
  DateTime t, {
  Duration grace = kRosterGrace,
}) {
  final m = _minutesOfDay(t);
  final g = grace.inMinutes;
  switch (shift) {
    case ShiftType.morning:
      // 07:00–15:00 ± grace → inclusive minutes
      final start = 7 * 60 - g;
      final end = 15 * 60 + g;
      return m >= start && m <= end;
    case ShiftType.evening:
      final start = 15 * 60 - g;
      final end = 23 * 60 + g;
      return m >= start && m <= end;
    case ShiftType.night:
      // 23:00–07:00 ± grace wraps midnight
      final start = 23 * 60 - g; // 22:45 with 15m
      final end = 7 * 60 + g; // 07:15 with 15m
      return m >= start || m <= end;
  }
}

/// Auto Regular vs Overtime for a single log entry.
///
/// Order (manual override wins first, checked by caller):
/// 1. Outside window±grace → Overtime
/// 2. Inside window + on rotation duty → Regular
/// 3. Inside window + off-rotation cover day → Overtime
RotationRole suggestedRoleFromWindow({
  required ShiftType shift,
  required DateTime timestamp,
  required bool onDuty,
  Duration grace = kRosterGrace,
}) {
  if (!isWithinRosterWindow(shift, timestamp, grace: grace)) {
    return RotationRole.extra;
  }
  return onDuty ? RotationRole.roster : RotationRole.extra;
}

/// Parse composite log input: 'ITEMS' or 'ITEMS / STOPS'.
/// Returns null if items missing/invalid. Empty/trailing stops → stops = 1.
/// Never returns stops &lt; 1.
({int items, int stops})? parsePalletInput(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.contains('/')) {
    final items = int.tryParse(s);
    if (items == null || items <= 0) return null;
    return (items: items, stops: 1);
  }
  final slash = s.indexOf('/');
  final itemsPart = s.substring(0, slash).trim();
  final stopsPart = s.substring(slash + 1).trim();
  final items = int.tryParse(itemsPart);
  if (items == null || items <= 0) return null;
  if (stopsPart.isEmpty) return (items: items, stops: 1);
  final stops = int.tryParse(stopsPart);
  if (stops == null || stops < 1) return (items: items, stops: 1);
  return (items: items, stops: stops);
}

/// Clamp/default stops for storage and legacy import. Never null, never 0.
int normalizeStops(dynamic value) {
  if (value == null) return 1;
  if (value is int) return value < 1 ? 1 : value;
  if (value is num) {
    final n = value.toInt();
    return n < 1 ? 1 : n;
  }
  final p = int.tryParse(value.toString());
  if (p == null || p < 1) return 1;
  return p;
}

/// Shift productivity target model.
///
/// Target calculation derived from standard shift parameters
/// (8h shift, 20m + 30m breaks, 20% operational allowance):
///
///   productive = (shiftHours - breaks) x (1 - deadTimePct)
///              = (8 - 0.8333) x 0.80 = 5.733 h
///   target     = productive x targetRate = 5.733 x 200 = 1147 items
///
/// Breaks apply first, followed by the operational allowance.
/// This benchmark target allows comparing live picking pace with shift target goals.
class TargetSettings {
  /// Rostered shift length in hours (paid clock, not logged span).
  final double shiftHours;
  /// Total planned break minutes in the shift (e.g. 20 + 30).
  final int breakMinutes;
  /// Operational allowance fraction, e.g. 0.20 for 20%.
  final double deadTimePct;
  /// Target item rate per productive hour (e.g. 200).
  final int targetRate;

  const TargetSettings({
    this.shiftHours = 8.0,
    this.breakMinutes = 50,
    this.deadTimePct = 0.20,
    this.targetRate = 200,
  });

  static const defaults = TargetSettings();

  /// Hours left for picking, after breaks and operational allowance.
  /// Never negative: non-positive values resolve to 0.
  double get productiveHours {
    final afterBreaks = shiftHours - breakMinutes / 60.0;
    if (afterBreaks <= 0) return 0;
    final h = afterBreaks * (1 - deadTimePct);
    return h <= 0 ? 0 : h;
  }

  /// Share of the paid shift that counts as productive (5.733 / 8 = 0.717).
  /// Used to convert an elapsed wall-clock span into elapsed productive time.
  double get productiveFraction =>
      shiftHours <= 0 ? 0 : productiveHours / shiftHours;

  /// The number on the board: productive hours × expected rate.
  int get dailyTargetItems => (productiveHours * targetRate).round();

  /// Transparent one-liner so the target is never a magic number in the UI.
  String get formulaLine {
    final b = breakMinutes;
    final pct = (deadTimePct * 100).round();
    return '${shiftHours.toStringAsFixed(shiftHours % 1 == 0 ? 0 : 1)}h '
        '− ${b}m breaks − $pct% dead time '
        '= ${productiveHours.toStringAsFixed(2)}h × $targetRate/hr';
  }

  TargetSettings copyWith({
    double? shiftHours,
    int? breakMinutes,
    double? deadTimePct,
    int? targetRate,
  }) =>
      TargetSettings(
        shiftHours: shiftHours ?? this.shiftHours,
        breakMinutes: breakMinutes ?? this.breakMinutes,
        deadTimePct: deadTimePct ?? this.deadTimePct,
        targetRate: targetRate ?? this.targetRate,
      );

  Map<String, dynamic> toJson() => {
    'shiftHours': shiftHours,
    'breakMinutes': breakMinutes,
    'deadTimePct': deadTimePct,
    'targetRate': targetRate,
  };

  /// Tolerant of missing/garbage keys: any bad field falls back to its default
  /// so a corrupt prefs blob can never break the Log screen.
  factory TargetSettings.fromJson(Map<String, dynamic> j) {
    double num_(dynamic v, double fallback) {
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? fallback;
    }
    final hours = num_(j['shiftHours'], 8.0);
    final breaks = num_(j['breakMinutes'], 50).round();
    final dead = num_(j['deadTimePct'], 0.20);
    final rate = num_(j['targetRate'], 200).round();
    return TargetSettings(
      shiftHours: hours <= 0 || hours > 24 ? 8.0 : hours,
      breakMinutes: breaks < 0 ? 0 : breaks,
      deadTimePct: dead < 0 || dead >= 1 ? 0.20 : dead,
      targetRate: rate <= 0 ? 200 : rate,
    );
  }
}

class PalletEntry {
  final String id;
  final DateTime timestamp;
  final int itemCount;
  /// Pick stops that built this pallet. Default 1 (legacy / items-only log).
  final int stops;
  final ShiftType shift;
  /// Soft roster category for display. Not the hard identity of the work block.
  final RotationRole rotationRole;

  PalletEntry({
    required this.id,
    required this.timestamp,
    required this.itemCount,
    int stops = 1,
    required this.shift,
    RotationRole rotationRole = RotationRole.unset,
    // Legacy constructor alias (Session 11). Prefer [rotationRole].
    bool isExtraShift = false,
  })  : stops = stops < 1 ? 1 : stops,
        rotationRole = isExtraShift ? RotationRole.extra : rotationRole;

  /// Convenience: true when this entry is marked extra (non-anchor).
  bool get isExtraShift => rotationRole == RotationRole.extra;

  PalletEntry copyWith({
    String? id,
    DateTime? timestamp,
    int? itemCount,
    int? stops,
    ShiftType? shift,
    RotationRole? rotationRole,
    bool? isExtraShift,
  }) {
    var role = this.rotationRole;
    if (isExtraShift == true) {
      role = RotationRole.extra;
    } else if (isExtraShift == false) {
      role = RotationRole.unset;
    } else if (rotationRole != null) {
      role = rotationRole;
    }
    return PalletEntry(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      itemCount: itemCount ?? this.itemCount,
      stops: stops ?? this.stops,
      shift: shift ?? this.shift,
      rotationRole: role,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'itemCount': itemCount,
    'stops': stops,
    'shift': shift.name,
    // Always write both so old and new importers keep the signal.
    'rotationRole': rotationRole.name,
    'isExtraShift': rotationRole == RotationRole.extra,
  };

  factory PalletEntry.fromJson(Map<String, dynamic> j) => PalletEntry(
    id: j['id'],
    timestamp: DateTime.parse(j['timestamp']),
    itemCount: j['itemCount'] as int,
    // Missing key → 1 (old logs / old exports). Never null, never 0.
    stops: j.containsKey('stops') ? normalizeStops(j['stops']) : 1,
    shift: ShiftTypeX.fromString(j['shift']) ?? ShiftType.morning,
    rotationRole: RotationRoleX.fromStorage(j),
  );
}

// Session date grouping:
// - Night: still maps 00:00–11:59 back one day (night OT past 07:00, noon cutoff).
// - Evening: ONLY maps 00:00–06:59 back (true post-midnight OT tail of the prior
//   evening). Hours 07–11 under "evening" stay on the same calendar day so a
//   long OT block that starts mid-morning (e.g. 11am–11pm) is one session, not
//   split across yesterday/today by the old noon-wide evening backshift.
// - Morning: never backshifts.
String shiftDateKey(DateTime timestamp, ShiftType shift) {
  var d = timestamp;
  if (shift == ShiftType.night && d.hour < 12) {
    d = d.subtract(const Duration(days: 1));
  } else if (shift == ShiftType.evening && d.hour < 7) {
    d = d.subtract(const Duration(days: 1));
  }
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// Mirrors shiftDateKey so the log header date matches the key an entry would use.
DateTime shiftDisplayDate(ShiftType shift) {
  final now = DateTime.now();
  if (shift == ShiftType.night && now.hour < 12) {
    return now.subtract(const Duration(days: 1));
  }
  if (shift == ShiftType.evening && now.hour < 7) {
    return now.subtract(const Duration(days: 1));
  }
  return now;
}

class ShiftNote {
  final String id;
  final DateTime timestamp;
  final ShiftType shift;
  final String text;

  ShiftNote({
    required this.id,
    required this.timestamp,
    required this.shift,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'shift': shift.name,
    'text': text,
  };

  factory ShiftNote.fromJson(Map<String, dynamic> j) => ShiftNote(
    id: j['id'],
    timestamp: DateTime.parse(j['timestamp']),
    shift: ShiftTypeX.fromString(j['shift']) ?? ShiftType.morning,
    text: j['text'] as String,
  );
}

class ShiftSession {
  final String dateKey; // yyyy-MM-dd
  final ShiftType shift;
  final List<PalletEntry> entries;

  ShiftSession({required this.dateKey, required this.shift, required this.entries});

  int get totalPallets => entries.length;
  int get totalItems => entries.fold(0, (s, e) => s + e.itemCount);
  int get totalStops => entries.fold(0, (s, e) => s + e.stops);
  double get avgItems => totalPallets == 0 ? 0 : totalItems / totalPallets;
  /// Avg stops per pallet for this session.
  double get avgStopsPerPallet =>
      totalPallets == 0 ? 0 : totalStops / totalPallets;
  /// Pick density: items per stop. totalStops==0 treated as 1 (never divide by 0).
  double get itemsPerStop {
    final st = totalStops <= 0 ? 1 : totalStops;
    return totalItems / st;
  }
  /// Glanceable density line for Stats cards.
  String get densityLine =>
      'Density ${itemsPerStop.toStringAsFixed(1)} items/stop · '
      '${avgStopsPerPallet.toStringAsFixed(1)} stops/pallet';

  /// Aggregated role by majority (not "any extra wins").
  ///
  /// Important after Session 13 dateKey rejoin: two early pallets marked extra under
  /// the old noon-split session must not taint a full day of untagged/roster pallets
  /// once they share one session again.
  RotationRole get rotationRole {
    if (entries.isEmpty) return RotationRole.unset;
    var roster = 0, extra = 0, unset = 0;
    for (final e in entries) {
      switch (e.rotationRole) {
        case RotationRole.roster: roster++;
        case RotationRole.extra: extra++;
        case RotationRole.unset: unset++;
      }
    }
    // Strict majority among all entries.
    final n = entries.length;
    if (roster * 2 > n) return RotationRole.roster;
    if (extra * 2 > n) return RotationRole.extra;
    // Tie / plurality: prefer roster over extra when both present and equal.
    if (roster > extra && roster > unset) return RotationRole.roster;
    if (extra > roster && extra > unset) return RotationRole.extra;
    return RotationRole.unset;
  }

  bool get isExtraShift => rotationRole == RotationRole.extra;

  DateTime? get firstTimestamp {
    if (entries.isEmpty) return null;
    return entries.map((e) => e.timestamp).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  DateTime? get lastTimestamp {
    if (entries.isEmpty) return null;
    return entries.map((e) => e.timestamp).reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Hours used as the **denominator for pace**.
  ///
  /// Formula (always the same):
  /// - 0 pallets → 0
  /// - 1 pallet → 1.0 h (no span yet; placeholder so pace is not infinite)
  /// - 2+ pallets → (last − first) + 30 min pad, clamped 0.25…16 h
  ///
  /// This is **not** clocked in/out, not a fixed 8 h shift, and not pure
  /// active pick time. It is the logged wall-clock span between first and last
  /// pallet, plus half an hour for pre/post logging lag. UI must say that.
  double get estimatedHoursWorked {
    if (entries.isEmpty) return 0;
    if (entries.length == 1) return 1.0;
    final first = firstTimestamp!;
    final last = lastTimestamp!;
    final spanHours = last.difference(first).inMinutes / 60.0;
    final padded = spanHours + 0.5;
    if (padded < 0.25) return 0.25;
    if (padded > 16.0) return 16.0;
    return padded;
  }

  /// Raw first→last span in hours (no pad). Null if fewer than 2 pallets.
  double? get rawSpanHours {
    if (entries.length < 2) return null;
    return lastTimestamp!.difference(firstTimestamp!).inMinutes / 60.0;
  }

  /// Pace = total items ÷ [estimatedHoursWorked]. 0 if hours too small.
  /// Same unit everywhere: **items per hour of logged span**.
  int get itemsPerHourPace {
    final h = estimatedHoursWorked;
    if (h < 0.25) return 0;
    return (totalItems / h).round();
  }

  /// Short label for the hours number (e.g. "8.5h span").
  String get hoursWorkedLabel =>
      '${estimatedHoursWorked.toStringAsFixed(1)}h span';

  // ── Daily target benchmark ────────────────────────────────────
  //
  // The pace above answers "how fast did logged work flow". The block below
  // answers "where am I against the target goal". Both are shown so they can
  // be evaluated together.

  /// Elapsed productive hours so far: the raw logged span scaled by the shift's
  /// productive fraction. Capped at total productive hours so remaining time stays non-negative.
  ///
  /// Spreads break and operational allowances evenly across the logged span.
  double elapsedProductiveHours(TargetSettings s) {
    final span = rawSpanHours;
    if (span == null || span <= 0) return 0;
    final used = span * s.productiveFraction;
    if (used <= 0) return 0;
    return used > s.productiveHours ? s.productiveHours : used;
  }

  /// Items per productive hour restated on the target scale.
  /// 0 while the active span is too short to calculate.
  int itemsPerProductiveHour(TargetSettings s) {
    final h = elapsedProductiveHours(s);
    if (h < 0.05) return 0;
    return (totalItems / h).round();
  }

  /// Fraction of the daily target logged so far. Values over 1.0 indicate exceeding the target.
  double targetProgress(TargetSettings s) {
    final t = s.dailyTargetItems;
    if (t <= 0) return 0;
    return totalItems / t;
  }

  /// Items still needed to reach the target. 0 once met or beaten.
  int itemsRemaining(TargetSettings s) {
    final left = s.dailyTargetItems - totalItems;
    return left < 0 ? 0 : left;
  }

  /// Productive hours still left in the shift.
  double productiveHoursRemaining(TargetSettings s) {
    final left = s.productiveHours - elapsedProductiveHours(s);
    return left < 0 ? 0 : left;
  }

  /// Rate needed from here on to still land on target. 0 when already there;
  /// null when there is no productive time left to do it in.
  int? requiredRate(TargetSettings s) {
    final remaining = itemsRemaining(s);
    if (remaining == 0) return 0;
    final hoursLeft = productiveHoursRemaining(s);
    if (hoursLeft < 0.05) return null; // shift duration reached
    return (remaining / hoursLeft).ceil();
  }

  /// Where the shift lands if the current productive rate holds to the end.
  int projectedItems(TargetSettings s) {
    final rate = itemsPerProductiveHour(s);
    if (rate <= 0) return totalItems;
    return (rate * s.productiveHours).round();
  }

  /// True when the current rate projects at or past the target.
  bool onTargetPace(TargetSettings s) =>
      s.dailyTargetItems > 0 && projectedItems(s) >= s.dailyTargetItems;

  /// Sub-line for the target bar: what the floor actually needs to know.
  String targetSubline(TargetSettings s) {
    if (totalItems >= s.dailyTargetItems && s.dailyTargetItems > 0) {
      final over = totalItems - s.dailyTargetItems;
      return over == 0 ? 'Target met' : 'Target met  ·  +$over over';
    }
    final rate = itemsPerProductiveHour(s);
    final need = requiredRate(s);
    if (rate <= 0) {
      return '${s.targetRate}/hr needed  ·  ${s.productiveHours.toStringAsFixed(2)}h productive';
    }
    if (need == null) return '$rate/hr  ·  shift productive time used up';
    return '$rate/hr now  ·  $need/hr needed to land';
  }

  /// Full transparent pace line for Stats cards.
  /// Example: `Pace 146 items/hr  ·  1240 items ÷ 8.5h span (first→last + 30m)`
  String get paceLine {
    if (totalPallets == 0) return 'Pace -';
    final h = estimatedHoursWorked;
    final pace = itemsPerHourPace;
    if (totalPallets == 1) {
      return 'Pace $pace items/hr  ·  $totalItems items ÷ ${h.toStringAsFixed(1)}h '
          '(single pallet uses 1.0h placeholder)';
    }
    return 'Pace $pace items/hr  ·  $totalItems items ÷ ${h.toStringAsFixed(1)}h span '
        '(first to last + 30m pad)';
  }
}
