import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'models.dart';
import 'storage.dart';
import 'shift_predictor.dart';
import 'sync_service.dart';

// Cyan-refined flat palette (pre-launch UX). No glow/gradients.
class AppColors {
  static const bg = Color(0xFF0B0E14);
  static const surface = Color(0xFF141A24);
  static const card = Color(0xFF1C2433);
  static const elevated = Color(0xFF243044);
  static const border = Color(0xFF2E3A4F);
  static const primary = Color(0xFF3DDCFF);
  static const onPrimary = Color(0xFF041018);
  static const text = Color(0xFFE8EEF7);
  static const muted = Color(0xFF8B9BB0);
  static const success = Color(0xFF3DDB8A);
  static const warning = Color(0xFFFFB020);
  static const warningSurface = Color(0xFF2A2110);
  static const destructive = Color(0xFFFF5C5C);
  // Shift accents (semantic, not brand CTA)
  static const shiftNight = Color(0xFF9575CD);

  // Daily-target ramp. One continuous gradient, three stops: never rendered
  // as discrete jump steps.
  static const targetLow = Color(0xFF9A5B00);  // dark amber: just started
  static const targetMid = Color(0xFFFFB020);  // soft amber: closing in
  static const targetHigh = Color(0xFF3DDB8A); // green: at/over target

  /// Smooth dark amber → soft amber → green across t ∈ [0,1].
  /// Continuous (no banding): the midpoint hands off between the two lerps.
  static Color rampColor(double t) {
    final p = t.isNaN ? 0.0 : t.clamp(0.0, 1.0).toDouble();
    if (p <= 0.5) return Color.lerp(targetLow, targetMid, p / 0.5)!;
    return Color.lerp(targetMid, targetHigh, (p - 0.5) / 0.5)!;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PalletApp());
}

class PalletApp extends StatelessWidget {
  const PalletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stacked',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          onPrimary: AppColors.onPrimary,
          surface: AppColors.surface,
          onSurface: AppColors.text,
          error: AppColors.destructive,
          onError: AppColors.text,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        cardColor: AppColors.card,
        dividerColor: AppColors.border,
        // Elevated chrome (app bar / nav) vs card vs bg so tiers actually read.
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.elevated,
          foregroundColor: AppColors.text,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.elevated,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.muted,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.card,
          surfaceTintColor: Colors.transparent,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.onPrimary,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.onPrimary,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.muted),
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  List<PalletEntry> _entries = [];
  List<ShiftNote> _notes = [];
  List<ShiftType>? _userCycle;
  TargetSettings _target = TargetSettings.defaults;
  /// 0..2 while first-run coach is active; null when hidden.
  int? _coachStep;
  final GlobalKey _noteIconKey = GlobalKey();
  final GlobalKey _listAreaKey = GlobalKey();
  final GlobalKey _backupKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
    _loadNotes();
    _loadTarget();
    _initSetup();
  }

  Future<void> _loadTarget() async {
    final t = await Storage.loadTargetSettings();
    if (mounted) setState(() => _target = t);
  }

  Future<void> _saveTarget(TargetSettings t) async {
    setState(() => _target = t);
    await Storage.saveTargetSettings(t);
  }

  // First-run surfaces must run in sequence, never stacked: consent sheet, then
  // coach marks. (Setup, when shown, chains into this on completion.)
  Future<void> _initConsentThenCoach() async {
    await _initConsent();
    await _maybeShowCoach();
  }

  Future<void> _load() async {
    final entries = await Storage.loadAll();
    setState(() => _entries = entries);
    SyncService.syncPendingSessions(entries); // fire-and-forget, silent fail
  }

  Future<void> _loadNotes() async {
    final notes = await Storage.loadNotes();
    setState(() => _notes = notes);
  }

  Future<void> _initSetup() async {
    final cycle = await Storage.loadSetupCycle();
    if (cycle != null) {
      // Returning user: no setup screen, go straight to consent → coach.
      setState(() => _userCycle = cycle);
      WidgetsBinding.instance.addPostFrameCallback((_) => _initConsentThenCoach());
    } else {
      // Fresh install: setup first; it chains into consent → coach on completion.
      WidgetsBinding.instance.addPostFrameCallback((_) => _showSetup());
    }
  }

  Future<void> _maybeShowCoach() async {
    if (await Storage.loadCoachMarksDone()) return;
    if (await Storage.loadSetupCycle() == null) return;
    if (!mounted) return;
    setState(() {
      _tab = 0;
      _coachStep = 0;
    });
  }

  Future<void> _finishCoach() async {
    await Storage.saveCoachMarksDone();
    if (mounted) setState(() => _coachStep = null);
  }

  void _coachNext() {
    if (_coachStep == null) return;
    if (_coachStep! >= 2) {
      _finishCoach();
    } else {
      setState(() => _coachStep = _coachStep! + 1);
    }
  }

  Future<void> _initConsent() async {
    final pref = await SyncService.getSyncPreference();
    if (pref != null) return; // already answered; never re-ask after answer/import/export
    if (!mounted) return;
    // Honest opt-in, designed so the easy/default path is Yes:
    // large primary CTA, "Recommended" chip, benefit-first copy, quiet secondary.
    // Still requires an explicit tap; never pre-enables sync (Setup never calls setSyncEnabled).
    await showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: AppColors.border, width: 1),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.45)),
              ),
              child: const Text(
                'RECOMMENDED',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Help the floor get better tools',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Join the pilot. Share anonymous shift totals (pallets, items, shift type) '
              'over a secure connection so we can improve Stacked. Your logs always stay on this phone first.',
              style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Never leaves this phone',
                    style: TextStyle(
                      color: AppColors.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Notes · name · email · exact clock times',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () async {
                  await SyncService.setSyncEnabled(true);
                  if (mounted) Navigator.pop(context);
                  SyncService.syncPendingSessions(_entries);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Yes, I\'m in',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: TextButton(
                onPressed: () async {
                  await SyncService.setSyncEnabled(false);
                  if (mounted) Navigator.pop(context);
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Keep everything private',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSetup() {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SetupScreen(onComplete: (cycle) async {
          await Storage.saveSetupCycle(cycle);
          setState(() => _userCycle = cycle);
          WidgetsBinding.instance.addPostFrameCallback((_) => _initConsentThenCoach());
        }),
      ),
    );
  }

  Future<void> _export() async {
    final json = await Storage.exportJson();
    final dir = await getTemporaryDirectory();
    final stamp = DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now());
    final file = File('${dir.path}/tracker_export_$stamp.json');
    await file.writeAsString(json);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'Tracker data export $stamp',
    );
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final content = await File(path).readAsString();

    // Guard: pre-notes-support exports (and empty-notes files) used to import
    // silently with 0 notes after uninstall wiped shift_notes. Make that loud.
    final peek = Storage.inspectExport(content);
    if (!peek.hasNotesKey || peek.noteCount == 0) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.card,
          title: const Text('No notes in this backup'),
          content: Text(
            !peek.hasNotesKey
                ? 'This file was exported before notes support (or has no notes field). '
                    'Importing will restore ${peek.entryCount} pallet entries but cannot restore any notes. '
                    'Notes already on this phone are kept if present; a wiped install has nothing to keep.'
                : 'This backup contains ${peek.entryCount} entries and 0 notes. '
                    'Import will not add any notes.',
            style: const TextStyle(height: 1.35),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Import anyway')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final counts = await Storage.importJson(content);
    await _load();
    await _loadNotes();
    if (!mounted) return;
    final noteBit = counts.notes > 0
        ? ', ${counts.notes} notes'
        : (peek.hasNotesKey ? ', 0 notes' : ', 0 notes (file predates notes)');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported ${counts.entries} entries$noteBit')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Stacked'),
        backgroundColor: AppColors.elevated,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_outlined),
            tooltip: 'Shift setup',
            onPressed: _showSetup,
          ),
          // Export/import grouped so coach mark 3 can highlight both.
          KeyedSubtree(
            key: _backupKey,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.file_upload_outlined),
                  tooltip: 'Import data',
                  onPressed: _import,
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: 'Export data',
                  onPressed: _export,
                ),
              ],
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          IndexedStack(
            index: _tab,
            children: [
              LogScreen(
                entries: _entries,
                notes: _notes,
                onUpdate: _load,
                onNotesUpdate: _loadNotes,
                userCycle: _userCycle,
                noteIconKey: _noteIconKey,
                listAreaKey: _listAreaKey,
                target: _target,
                onTargetChanged: _saveTarget,
              ),
              AnalyticsScreen(
                entries: _entries,
                notes: _notes,
                onUpdate: _load,
                target: _target,
              ),
              ScheduleScreen(entries: _entries, userCycle: _userCycle),
            ],
          ),
          if (_coachStep != null)
            _CoachMarksOverlay(
              step: _coachStep!,
              noteKey: _noteIconKey,
              listKey: _listAreaKey,
              backupKey: _backupKey,
              onNext: _coachNext,
              onSkip: _finishCoach,
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        // Lock navigation while the first-run coach is active so its bubble
        // can't be orphaned onto the wrong tab.
        onTap: _coachStep != null ? null : (i) => setState(() => _tab = i),
        backgroundColor: AppColors.elevated,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.muted,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.add_box_outlined), label: 'Log'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Stats'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'Schedule'),
        ],
      ),
    );
  }
}

// ─── LOG SCREEN ──────────────────────────────────────────────────────────────

class LogScreen extends StatefulWidget {
  final List<PalletEntry> entries;
  final List<ShiftNote> notes;
  final VoidCallback onUpdate;
  final VoidCallback onNotesUpdate;
  final List<ShiftType>? userCycle;
  final GlobalKey? noteIconKey;
  final GlobalKey? listAreaKey;
  final TargetSettings target;
  final ValueChanged<TargetSettings> onTargetChanged;
  const LogScreen({
    super.key,
    required this.entries,
    required this.notes,
    required this.onUpdate,
    required this.onNotesUpdate,
    required this.target,
    required this.onTargetChanged,
    this.userCycle,
    this.noteIconKey,
    this.listAreaKey,
  });

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String _input = '';
  late ShiftType _shift;
  /// Rare manual override. Null = derive Regular/Overtime from window±15m + duty.
  RotationRole? _roleOverride;
  Timer? _clockTicker;

  @override
  void initState() {
    super.initState();
    _shift = ShiftTypeX.fromNow();
    _loadPersistedShift();
    // Re-evaluate the shift mismatch as the clock moves, so the banner appears
    // when a shift boundary passes with the app sitting open.
    _clockTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTicker?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(LogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Entries are loaded async in HomeShell; when they arrive, infer shift if no
    // persisted shift was found (fixes the race in initState).
    if (oldWidget.entries != widget.entries && widget.entries.isNotEmpty) {
      _inferShiftFromEntries();
    }
  }

  // The persisted shift always wins: never silently switch on the user. The
  // picker explicitly picked a shift chip on this screen.
  Future<void> _loadPersistedShift() async {
    final saved = await Storage.loadActiveShift();
    if (saved != null && mounted) { setState(() => _shift = saved); return; }
    // Fallback to entry inference: entries may not be loaded yet; didUpdateWidget handles that.
    _inferShiftFromEntries();
  }


  void _inferShiftFromEntries() async {
    // Already have a persisted shift; don't override it.
    final saved = await Storage.loadActiveShift();
    if (saved != null) return;
    final now = DateTime.now();
    for (final t in ShiftType.values) {
      final key = shiftDateKey(now, t);
      if (widget.entries.any((e) => e.shift == t && shiftDateKey(e.timestamp, e.shift) == key)) {
        if (mounted) setState(() => _shift = t);
        return;
      }
    }
  }

  List<PalletEntry> get _todayEntries {
    final activeKey = shiftDateKey(DateTime.now(), _shift);
    return widget.entries.where((e) =>
      e.shift == _shift &&
      shiftDateKey(e.timestamp, e.shift) == activeKey,
    ).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  /// Current shift block as a session, for pace / target maths.
  ShiftSession get _session => ShiftSession(
        dateKey: shiftDateKey(DateTime.now(), _shift),
        shift: _shift,
        entries: _todayEntries,
      );

  List<ShiftNote> get _todayNotes {
    final activeKey = shiftDateKey(DateTime.now(), _shift);
    return widget.notes.where((n) =>
      n.shift == _shift &&
      shiftDateKey(n.timestamp, n.shift) == activeKey,
    ).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> _addNote() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Add note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Task change, observation, note...',
            hintStyle: TextStyle(color: AppColors.muted),
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    final note = ShiftNote(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      shift: _shift,
      text: text,
    );
    await Storage.addNote(note);
    widget.onNotesUpdate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Note saved. View history in Stats (session cards).'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  Future<void> _deleteNote(String id) async {
    await Storage.deleteNote(id);
    widget.onNotesUpdate();
  }

  Future<bool> _confirmDeleteNote(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Delete this note?'),
        content: const Text('This note will be permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.destructive)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Digit or '/' separator. Composite: ITEMS / STOPS (one slash max).
  void _tap(String v) {
    setState(() {
      if (v == '/') {
        if (_input.contains('/')) return; // only one separator
        if (_input.trim().isEmpty) return; // need items first
        // Pretty separator for display + char-by-char backspace.
        final base = _input.trimRight();
        _input = '$base / ';
        return;
      }
      // Allow up to 4 item digits + separator + 3 stop digits.
      if (_input.length >= 12) return;
      final afterSlash = _input.contains('/');
      if (!afterSlash) {
        final digits = _input.replaceAll(RegExp(r'\D'), '');
        if (digits.length >= 4) return;
      } else {
        final stopDigits = _input.split('/').last.replaceAll(RegExp(r'\D'), '');
        if (stopDigits.length >= 3) return;
      }
      _input += v;
    });
  }

  void _backspace() => setState(() {
    if (_input.isNotEmpty) _input = _input.substring(0, _input.length - 1);
  });

  /// Live confirmation line once a '/' is present, e.g. "4 stops" or
  /// "stops" (empty part → will default to 1 on ADD).
  String _stopsHint(String input) {
    final stopsPart = input.split('/').last.trim();
    if (stopsPart.isEmpty) return 'stops (defaults to 1)';
    final n = int.tryParse(stopsPart);
    if (n == null) return 'stops';
    return '$n ${n == 1 ? 'stop' : 'stops'}';
  }

  /// Derive Regular vs Overtime for the next log at [at] (default now).
  ///
  /// Manual chip override wins. Else rigid window ±15m grace, then rotation duty.
  /// Per entry (not session lock): outside window → Overtime even on a roster day.
  /// Never blocks logging.
  RotationRole _roleForCurrentBlock([DateTime? at]) {
    if (_roleOverride != null) return _roleOverride!;
    final t = at ?? DateTime.now();
    final dk = shiftDateKey(t, _shift);
    final onDuty = ShiftPredictor.isOnRotationDuty(
      dk,
      _shift,
      entries: widget.entries,
      userCycle: widget.userCycle,
    );
    return suggestedRoleFromWindow(
      shift: _shift,
      timestamp: t,
      onDuty: onDuty,
    );
  }

  Future<void> _pickBlockRole() async {
    final current = _roleForCurrentBlock();
    final ans = await showDialog<RotationRole>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Override day type'),
        content: const Text(
          'Default (no override):\n'
          '• Inside shift window ±15 min + on rotation → Regular\n'
          '• Outside window, or off-rotation cover → Overtime\n\n'
          'Regular = anchors schedule. Overtime = stats only.\n'
          'This override applies to new logs (and rewrites this session if it already has pallets).',
          style: TextStyle(height: 1.4, color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, RotationRole.extra),
            child: Text(
              current == RotationRole.extra ? 'Overtime ✓' : 'Overtime',
              style: TextStyle(
                color: current == RotationRole.extra ? AppColors.warning : AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, RotationRole.roster),
            child: Text(
              current == RotationRole.roster ? 'Regular ✓' : 'Regular',
              style: TextStyle(
                color: current == RotationRole.roster ? AppColors.primary : AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (ans == null || !mounted) return;
    setState(() => _roleOverride = ans);
    await Storage.saveLastRotationRoleChoice(ans);
    final dk = shiftDateKey(DateTime.now(), _shift);
    final existing = widget.entries
        .where((e) => e.shift == _shift && shiftDateKey(e.timestamp, e.shift) == dk)
        .toList();
    if (existing.isNotEmpty) {
      await Storage.setSessionRotationRole(dk, _shift, ans);
      widget.onUpdate();
    }
  }

  Future<void> _add() async {
    final parsed = parsePalletInput(_input);
    if (parsed == null) return;
    final now = DateTime.now();

    // Per-entry role: override chip, else window±15m + on-duty.
    // No modal. Outside grace → Overtime; does not inherit whole-session lock.
    final role = _roleForCurrentBlock(now);

    final entry = PalletEntry(
      id: now.millisecondsSinceEpoch.toString(),
      timestamp: now,
      itemCount: parsed.items,
      stops: parsed.stops,
      shift: _shift,
      rotationRole: role,
    );
    await Storage.addEntry(entry);
    await Storage.saveActiveShift(_shift);
    setState(() => _input = '');
    widget.onUpdate();
  }

  Future<void> _delete(String id) async {
    await Storage.deleteEntry(id);
    widget.onUpdate();
  }

  Future<void> _editTarget() async {
    final updated = await showModalBottomSheet<TargetSettings>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _TargetSettingsSheet(initial: widget.target),
    );
    if (updated != null) widget.onTargetChanged(updated);
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Delete this entry?'),
        content: const Text('This pallet entry will be removed for good.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.destructive)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final today = _todayEntries;
    final totalItems = today.fold(0, (s, e) => s + e.itemCount);

    final notes = _todayNotes;

    return SafeArea(
      child: Column(
        children: [
          _ShiftMismatchBanner(
            selected: _shift,
            onSwitch: (s) {
              setState(() => _shift = s);
              Storage.saveActiveShift(s);
            },
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(DateFormat('EEE, MMM d').format(shiftDisplayDate(_shift)),
                        style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      key: widget.noteIconKey,
                      onTap: _addNote,
                      child: const Icon(Icons.note_add_outlined, color: AppColors.success, size: 20),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _ShiftPicker(
                        value: _shift,
                        onChanged: (s) {
                          setState(() {
                            _shift = s;
                            // Clear override so new block derives from schedule again.
                            _roleOverride = null;
                          });
                          Storage.saveActiveShift(s);
                        },
                      ),
                      const SizedBox(width: 8),
                      _RoleChip(
                        role: _roleForCurrentBlock(),
                        onTap: _pickBlockRole,
                      ),
                    ],
                  ),
                ]),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${today.length}', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: AppColors.primary)),
                  Text('pallets  ·  $totalItems items', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                ]),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Daily target: live pace evaluated against shift target goal.
          _DailyTargetBar(
            items: totalItems,
            settings: widget.target,
            subline: _session.targetSubline(widget.target),
            paceMarker: paceMarkerFor(_session, widget.target),
            onTap: _editTarget,
          ),

          const SizedBox(height: 10),

          // Today's pallet + notes list (merged, newest first)
          Expanded(
            key: widget.listAreaKey,
            child: () {
              // Merge pallets and notes, sorted newest first
              final items = <_LogItem>[
                ...today.asMap().entries.map((e) => _LogItem.pallet(e.value, today.length - e.key)),
                ...notes.map(_LogItem.note),
              ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

              if (items.isEmpty) {
                return const Center(child: Text('No pallets yet this shift', style: TextStyle(color: AppColors.muted)));
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: items.length,
                itemBuilder: (ctx, i) {
                  final item = items[i];
                  if (item.isNote) {
                    final n = item.note!;
                    return Dismissible(
                      key: Key('note_${n.id}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        color: AppColors.destructive.withValues(alpha: 0.25),
                        child: const Icon(Icons.delete, color: AppColors.destructive),
                      ),
                      confirmDismiss: (_) => _confirmDeleteNote(context),
                      onDismissed: (_) => _deleteNote(n.id),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border, width: 1),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2, right: 10),
                              child: Icon(Icons.notes, color: AppColors.muted, size: 14),
                            ),
                            Expanded(
                              child: Text(n.text,
                                  style: const TextStyle(fontSize: 14, color: AppColors.muted)),
                            ),
                            const SizedBox(width: 8),
                            Text(DateFormat('HH:mm').format(n.timestamp),
                                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                    );
                  } else {
                    final e = item.entry!;
                    final palletNum = item.palletNum!;
                    return Dismissible(
                      key: Key(e.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        color: AppColors.destructive.withValues(alpha: 0.25),
                        child: const Icon(Icons.delete, color: AppColors.destructive),
                      ),
                      confirmDismiss: (_) => _confirmDelete(context),
                      onDismissed: (_) => _delete(e.id),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border, width: 1),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('#$palletNum', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                            Text(
                              e.stops > 1
                                  ? '${e.itemCount} items · ${e.stops} stops'
                                  : '${e.itemCount} items',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text),
                            ),
                            Text(DateFormat('HH:mm').format(e.timestamp),
                                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                    );
                  }
                },
              );
            }(),
          ),

          // Input Panel Card (Display + Numpad) with distinct surface container, border & shadow
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                top: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Display
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _input.isEmpty ? '0' : _input,
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w300,
                          color: _input.isEmpty ? AppColors.muted : AppColors.text,
                        ),
                      ),
                      // Discoverability for the '/' stops separator
                      if (_input.isEmpty)
                        const Text(
                          'tip: 120 / 4 = 4 stops (optional)',
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.muted, fontSize: 12),
                        )
                      else if (_input.contains('/'))
                        Text(
                          _stopsHint(_input),
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.primary, fontSize: 12),
                        ),
                    ],
                  ),
                ),

                // Numpad
                _Numpad(onTap: _tap, onBack: _backspace, onAdd: _add),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Union type for the merged pallet + note list
class _LogItem {
  final PalletEntry? entry;
  final int? palletNum;
  final ShiftNote? note;

  const _LogItem._({this.entry, this.palletNum, this.note});
  factory _LogItem.pallet(PalletEntry e, int num) => _LogItem._(entry: e, palletNum: num);
  factory _LogItem.note(ShiftNote n) => _LogItem._(note: n);

  bool get isNote => note != null;
  DateTime get timestamp => entry?.timestamp ?? note!.timestamp;
}

/// Small tappable role chip beside the shift label (Regular ▾ / Overtime ▾).
class _RoleChip extends StatelessWidget {
  final RotationRole role;
  final VoidCallback onTap;
  const _RoleChip({required this.role, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOt = role == RotationRole.extra;
    final color = isOt ? AppColors.warning : AppColors.primary;
    final label = isOt ? 'Overtime' : 'Regular';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.elevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

/// Where the target bar *should* be by now: the share of the shift's productive
/// hours already spent. Null before there is a span to measure, so no
/// misleading tick appears on the first pallet of a shift.
double? paceMarkerFor(ShiftSession s, TargetSettings t) {
  if (t.productiveHours <= 0) return null;
  final elapsed = s.elapsedProductiveHours(t);
  if (elapsed <= 0) return null;
  return elapsed / t.productiveHours;
}

/// Daily target as a single compact strip: one bar, not three blocks.
///
/// The fill length and its colour animate together along one continuous
/// dark amber → soft amber → green ramp, and the fill carries that ramp as a
/// gradient along its own length so the journey is visible at a glance. A thin
/// tick marks where the shift *should* be by now, which is what ties the app's
/// measured speed to the target goal.
class _DailyTargetBar extends StatelessWidget {
  final int items;
  final TargetSettings settings;
  final String subline;
  /// 0..1 position of the "expected by now" tick. Null hides it.
  final double? paceMarker;
  /// Null makes the strip read-only (no tap, no tune affordance).
  final VoidCallback? onTap;

  const _DailyTargetBar({
    required this.items,
    required this.settings,
    required this.subline,
    this.onTap,
    this.paceMarker,
  });

  @override
  Widget build(BuildContext context) {
    final target = settings.dailyTargetItems;
    final raw = target <= 0 ? 0.0 : items / target;
    final progress = raw.clamp(0.0, 1.0).toDouble();
    final pct = (raw * 100).round();

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: progress),
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeOutCubic,
          builder: (ctx, t, _) {
            final c = AppColors.rampColor(t);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text(
                      'DAILY TARGET',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 10,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$items',
                      style: TextStyle(
                        color: c,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      ' / $target',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$pct%',
                      style: TextStyle(
                        color: c,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                LayoutBuilder(
                  builder: (ctx, cons) {
                    final w = cons.maxWidth;
                    return SizedBox(
                      height: 9,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Track
                          Container(
                            decoration: BoxDecoration(
                              color: AppColors.elevated,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                          // Fill: gradient runs the ramp along its own length.
                          if (t > 0)
                            Container(
                              width: w * t,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                gradient: LinearGradient(
                                  colors: [AppColors.rampColor(0), c],
                                ),
                              ),
                            ),
                          // "Expected by now" tick.
                          if (paceMarker != null && w > 4)
                            Positioned(
                              left: (w * paceMarker!.clamp(0.0, 1.0) - 1)
                                  .clamp(0.0, w - 2)
                                  .toDouble(),
                              top: -2,
                              child: Container(
                                width: 2,
                                height: 13,
                                decoration: BoxDecoration(
                                  color: AppColors.text.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        subline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    ),
                    if (onTap != null)
                      const Icon(Icons.tune, size: 12, color: AppColors.muted),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Edits the four inputs behind the daily target, with a live preview of the
/// resulting productive hours + item target so the maths is never hidden.
class _TargetSettingsSheet extends StatefulWidget {
  final TargetSettings initial;
  const _TargetSettingsSheet({required this.initial});

  @override
  State<_TargetSettingsSheet> createState() => _TargetSettingsSheetState();
}

class _TargetSettingsSheetState extends State<_TargetSettingsSheet> {
  late TargetSettings _s = widget.initial;

  Widget _stepper({
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: AppColors.text, fontSize: 14)),
            ),
            IconButton(
              onPressed: onMinus,
              icon: const Icon(Icons.remove_circle_outline),
              color: AppColors.muted,
              visualDensity: VisualDensity.compact,
            ),
            SizedBox(
              width: 62,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              onPressed: onPlus,
              icon: const Icon(Icons.add_circle_outline),
              color: AppColors.muted,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Daily target',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
              )),
          const SizedBox(height: 6),
          const Text(
            'Breaks come off the shift first, then the dead-time cut applies to '
            'what is left. Matches how the floor number is set.',
            style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 12),
          _stepper(
            label: 'Shift length',
            value: '${_s.shiftHours.toStringAsFixed(_s.shiftHours % 1 == 0 ? 0 : 1)}h',
            onMinus: () => setState(() {
              final v = _s.shiftHours - 0.5;
              if (v >= 1) _s = _s.copyWith(shiftHours: v);
            }),
            onPlus: () => setState(() {
              final v = _s.shiftHours + 0.5;
              if (v <= 24) _s = _s.copyWith(shiftHours: v);
            }),
          ),
          _stepper(
            label: 'Breaks (total)',
            value: '${_s.breakMinutes}m',
            onMinus: () => setState(() {
              final v = _s.breakMinutes - 5;
              if (v >= 0) _s = _s.copyWith(breakMinutes: v);
            }),
            onPlus: () => setState(() {
              final v = _s.breakMinutes + 5;
              if (v / 60.0 < _s.shiftHours) _s = _s.copyWith(breakMinutes: v);
            }),
          ),
          _stepper(
            label: 'Dead time',
            value: '${(_s.deadTimePct * 100).round()}%',
            onMinus: () => setState(() {
              final v = _s.deadTimePct - 0.05;
              if (v >= -0.001) _s = _s.copyWith(deadTimePct: v < 0 ? 0 : v);
            }),
            onPlus: () => setState(() {
              final v = _s.deadTimePct + 0.05;
              if (v <= 0.9) _s = _s.copyWith(deadTimePct: v);
            }),
          ),
          _stepper(
            label: 'Target rate',
            value: '${_s.targetRate}/hr',
            onMinus: () => setState(() {
              final v = _s.targetRate - 10;
              if (v >= 10) _s = _s.copyWith(targetRate: v);
            }),
            onPlus: () => setState(() {
              final v = _s.targetRate + 10;
              if (v <= 2000) _s = _s.copyWith(targetRate: v);
            }),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${_s.dailyTargetItems}',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('items',
                        style: TextStyle(color: AppColors.muted, fontSize: 13)),
                    const Spacer(),
                    Text(
                      '${_s.productiveHours.toStringAsFixed(2)}h productive',
                      style: const TextStyle(color: AppColors.text, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _s.formulaLine,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () =>
                    setState(() => _s = TargetSettings.defaults),
                child: const Text('Reset',
                    style: TextStyle(color: AppColors.muted, fontSize: 13)),
              ),
              const Spacer(),
              SizedBox(
                height: 46,
                child: Material(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () => Navigator.pop(context, _s),
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 30),
                      child: Center(
                        child: Text(
                          'SAVE',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: AppColors.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShiftPicker extends StatelessWidget {
  final ShiftType value;
  final ValueChanged<ShiftType> onChanged;
  const _ShiftPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final result = await showModalBottomSheet<ShiftType>(
          context: context,
          backgroundColor: AppColors.card,
          builder: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            children: ShiftType.values.map((s) => ListTile(
              title: Text(s.label),
              subtitle: Text(s.timeRange, style: const TextStyle(color: AppColors.muted)),
              trailing: s == value ? const Icon(Icons.check, color: AppColors.primary) : null,
              onTap: () => Navigator.pop(context, s),
            )).toList(),
          ),
        );
        if (result != null) onChanged(result);
      },
      child: Row(children: [
        Text(value.label,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.primary)),
        const SizedBox(width: 4),
        const Icon(Icons.expand_more, color: AppColors.primary, size: 18),
      ]),
    );
  }
}

// Wall-clock window vs selected soft label. Never auto-switches; never reads
// the Schedule predictor. For straddling OT (e.g. 11am start, clock Morning,
// logging Evening): emphasize continuing this work block.
class _ShiftMismatchBanner extends StatelessWidget {
  final ShiftType selected;
  final void Function(ShiftType) onSwitch;

  const _ShiftMismatchBanner({required this.selected, required this.onSwitch});

  static bool _selectedIsLaterInDay(ShiftType selected, ShiftType clock) {
    const order = [ShiftType.morning, ShiftType.evening, ShiftType.night];
    return order.indexOf(selected) > order.indexOf(clock);
  }

  @override
  Widget build(BuildContext context) {
    final clockWindow = ShiftTypeX.fromNow();
    if (clockWindow == selected) return const SizedBox.shrink();

    final earlyOrStraddle = _selectedIsLaterInDay(selected, clockWindow);
    final title = earlyOrStraddle
        ? 'Logging under ${selected.label} : wall clock is still ${clockWindow.label}'
        : 'Logging under ${selected.label} : wall clock is ${clockWindow.label}';
    final subtitle = earlyOrStraddle
        ? 'Continue this work block if you are on a long / OT day. '
            'Logs outside ${selected.label} ±15m grace auto-tag Overtime. '
            'Tap only to change the soft label to ${clockWindow.label} (${clockWindow.timeRange}).'
        : 'Past ${selected.label} window (±15m grace) → Overtime on each log. '
            'Tap to switch the soft label to ${clockWindow.label} (${clockWindow.timeRange}).';

    return GestureDetector(
      onTap: () => onSwitch(clockWindow),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: earlyOrStraddle ? AppColors.elevated : AppColors.primary,
          borderRadius: BorderRadius.circular(12),
          border: earlyOrStraddle
              ? Border.all(color: AppColors.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          children: [
            Icon(
              earlyOrStraddle ? Icons.schedule : Icons.warning_amber_rounded,
              color: earlyOrStraddle ? AppColors.primary : AppColors.onPrimary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: earlyOrStraddle ? AppColors.text : AppColors.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: earlyOrStraddle ? AppColors.muted : AppColors.onPrimary.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Numpad extends StatefulWidget {
  final void Function(String) onTap;
  final VoidCallback onBack;
  final VoidCallback onAdd;

  const _Numpad({required this.onTap, required this.onBack, required this.onAdd});

  @override
  State<_Numpad> createState() => _NumpadState();
}

class _NumpadState extends State<_Numpad> {
  // Lazy player; fail silent if package/asset missing.
  AudioPlayer? _eggPlayer;

  Future<void> _playEasterEgg() async {
    try {
      _eggPlayer ??= AudioPlayer();
      final player = _eggPlayer!;
      // audioplayers AssetSource is relative to the assets/ dir (no 'assets/' prefix).
      for (final path in const [
        'audio/Ahoy.mp3',
        'audio/easter_egg.mp3',
        'audio/easter_egg.wav',
      ]) {
        try {
          await player.stop();
          await player.play(AssetSource(path));
          return;
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      // Missing asset or audio backend: do nothing.
    }
  }

  @override
  void dispose() {
    try {
      _eggPlayer?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        _row(['7', '8', '9']),
        _row(['4', '5', '6']),
        _row(['1', '2', '3']),
        // Bottom row: backspace, 0, '/' separator (long-press = easter egg).
        Row(children: [
          _btn('⌫', widget.onBack, color: AppColors.elevated, labelColor: AppColors.muted),
          _btn('0', () => widget.onTap('0')),
          _btn(
            '/',
            () => widget.onTap('/'),
            color: AppColors.card,
            labelColor: AppColors.muted,
            subtitle: 'STOPS',
            onLongPress: _playEasterEgg,
          ),
        ]),
        const SizedBox(height: 8),
        // True electric #3DDCFF: raw Material fill, no M3 surface tint / elevation mix.
        SizedBox(
          width: double.infinity,
          height: 56,
          child: Material(
            color: const Color(0xFF3DDCFF),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: widget.onAdd,
              borderRadius: BorderRadius.circular(12),
              child: const Center(
                child: Text(
                  'ADD PALLET',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Color(0xFF041018),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _row(List<String> keys) => Row(
    children: keys.map((k) => _btn(k, () => widget.onTap(k))).toList(),
  );

  Widget _btn(
    String label,
    VoidCallback action, {
    Color? color,
    Color? labelColor,
    String? subtitle,
    VoidCallback? onLongPress,
  }) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 56,
            child: TextButton(
              onPressed: action,
              onLongPress: onLongPress,
              style: TextButton.styleFrom(
                backgroundColor: color ?? AppColors.card,
                foregroundColor: labelColor ?? AppColors.text,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppColors.border, width: 1),
                ),
              ),
              child: subtitle == null
                  ? Text(label, style: TextStyle(fontSize: 22, color: labelColor ?? AppColors.text))
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(label, style: TextStyle(fontSize: 20, color: labelColor ?? AppColors.text)),
                        Text(subtitle,
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 0.5,
                              color: (labelColor ?? AppColors.text).withValues(alpha: 0.7),
                            )),
                      ],
                    ),
            ),
          ),
        ),
      );
}

// ─── ANALYTICS SCREEN ────────────────────────────────────────────────────────

class AnalyticsScreen extends StatefulWidget {
  final List<PalletEntry> entries;
  final List<ShiftNote> notes;
  final VoidCallback onUpdate;
  final TargetSettings target;
  const AnalyticsScreen({
    super.key,
    required this.entries,
    required this.notes,
    required this.onUpdate,
    required this.target,
  });

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  int _period = 0;
  int _weekOffset = 0;
  int _monthOffset = 0;

  // ── helpers ──────────────────────────────────────────────────────────────

  static DateTime _parse(String key) {
    final p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  DateTime get _weekStart {
    final now = DateTime.now();
    // Start on Sunday so night-shift Sunday sessions (Sun 23:00–) are captured
    // in the same week as Mon–Thu night sessions.
    // Dart weekday: Mon=1 … Sun=7; (weekday % 7) gives days since last Sunday.
    final daysFromSunday = now.weekday % 7;
    final sunday = now.subtract(Duration(days: daysFromSunday));
    final base = DateTime(sunday.year, sunday.month, sunday.day);
    return base.add(Duration(days: _weekOffset * 7));
  }

  DateTime get _monthStart {
    final now = DateTime.now();
    int m = now.month + _monthOffset;
    int y = now.year;
    while (m <= 0) { m += 12; y--; }
    while (m > 12) { m -= 12; y++; }
    return DateTime(y, m, 1);
  }

  List<ShiftSession> get _daySessions {
    final now = DateTime.now();
    return Storage.groupBySessions(widget.entries).where((s) {
      final activeKey = shiftDateKey(now, s.shift);
      return s.dateKey == activeKey;
    }).toList();
  }

  // Recent sessions for the Day-tab list (summary cards stay on _daySessions).
  // Session 6 wired notes into session cards, but the list only showed *today*,
  // so past notes stayed unreachable. Include entry sessions + note-only days.
  List<ShiftSession> get _historySessions {
    final byKey = <String, ShiftSession>{};
    for (final s in Storage.groupBySessions(widget.entries)) {
      byKey['${s.dateKey}_${s.shift.name}'] = s;
    }
    for (final n in widget.notes) {
      final dk = shiftDateKey(n.timestamp, n.shift);
      final key = '${dk}_${n.shift.name}';
      byKey.putIfAbsent(
        key,
        () => ShiftSession(dateKey: dk, shift: n.shift, entries: []),
      );
    }
    return byKey.values.toList()
      ..sort((a, b) => b.dateKey.compareTo(a.dateKey));
  }

  List<ShiftSession> get _weekSessions {
    final ws = _weekStart;
    final we = ws.add(const Duration(days: 7));
    return Storage.groupBySessions(widget.entries).where((s) {
      final d = _parse(s.dateKey);
      return !d.isBefore(ws) && d.isBefore(we);
    }).toList()..sort((a, b) => a.dateKey.compareTo(b.dateKey));
  }

  List<ShiftSession> get _monthSessions {
    final ms = _monthStart;
    final me = DateTime(
      ms.month == 12 ? ms.year + 1 : ms.year,
      ms.month == 12 ? 1 : ms.month + 1,
      1,
    );
    return Storage.groupBySessions(widget.entries).where((s) {
      final d = _parse(s.dateKey);
      return !d.isBefore(ms) && d.isBefore(me);
    }).toList()..sort((a, b) => a.dateKey.compareTo(b.dateKey));
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Stats', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Day')),
                  ButtonSegment(value: 1, label: Text('Week')),
                  ButtonSegment(value: 2, label: Text('Month')),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.first),
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected) ? AppColors.primary : null),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_period == 1) _NavRow(
          label: _weekLabel,
          onPrev: () => setState(() => _weekOffset--),
          onNext: _weekOffset < 0 ? () => setState(() => _weekOffset++) : null,
        ),
        if (_period == 2) _NavRow(
          label: DateFormat('MMMM yyyy').format(_monthStart),
          onPrev: () => setState(() => _monthOffset--),
          onNext: _monthOffset < 0 ? () => setState(() => _monthOffset++) : null,
        ),
        const SizedBox(height: 8),
        _buildSummaryCards(
          _period == 0 ? _daySessions : _period == 1 ? _weekSessions : _monthSessions,
        ),
        // Target only makes sense per-day: it is a single-shift number.
        if (_period == 0) ...[
          const SizedBox(height: 10),
          Builder(builder: (_) {
            final s = _dayTargetSession;
            return _DailyTargetBar(
              items: s.totalItems,
              settings: widget.target,
              subline: s.targetSubline(widget.target),
              paceMarker: paceMarkerFor(s, widget.target),
            );
          }),
        ],
        const SizedBox(height: 12),
        Expanded(child: _buildBody()),
      ]),
    );
  }

  /// All of today's entries as one session, so the target bar reads the whole
  /// day even when a long block straddles two shift labels.
  ShiftSession get _dayTargetSession {
    final sessions = _daySessions;
    final entries = [for (final s in sessions) ...s.entries];
    return ShiftSession(
      dateKey: sessions.isEmpty ? '' : sessions.first.dateKey,
      shift: sessions.isEmpty ? ShiftTypeX.fromNow() : sessions.first.shift,
      entries: entries,
    );
  }

  String get _weekLabel {
    final ws = _weekStart;
    final we = ws.add(const Duration(days: 6)); // Sun → Sat
    final fmt = DateFormat('MMM d');
    return '${fmt.format(ws)} – ${fmt.format(we)}';
  }

  Widget _buildSummaryCards(List<ShiftSession> sessions) {
    final pallets = sessions.fold(0, (s, e) => s + e.totalPallets);
    final items = sessions.fold(0, (s, e) => s + e.totalItems);
    final stops = sessions.fold(0, (s, e) => s + e.totalStops);
    final nSessions = sessions.where((s) => s.totalPallets > 0).length;
    final totalHours = sessions.fold<double>(0, (s, e) => s + e.estimatedHoursWorked);
    final itemsPerHour = totalHours < 0.25 ? 0 : (items / totalHours).round();
    final avgPalletsPerShift =
        nSessions == 0 ? 0.0 : pallets / nSessions;
    final avgItemsPerPallet = pallets == 0 ? 0.0 : items / pallets;
    final density = (stops <= 0 ? items.toDouble() : items / stops);
    final stopsPerPallet = pallets == 0 ? 0.0 : stops / pallets;
    final densityLine =
        'Density ${density.toStringAsFixed(1)} items/stop · ${stopsPerPallet.toStringAsFixed(1)} stops/pallet';

    // Day: Total Pallets | Total Items | Pace (items ÷ logged span hours)
    // Week/Month: Total Pallets | Total Items | Avg Pallets/Shift
    // Density is a secondary line under the row (not stops/hr).
    //
    // Pace is NEVER a mystery "speed": always items ÷ sum(session span hours).
    // Span hour = first→last pallet + 30m pad (see ShiftSession.estimatedHoursWorked).
    Widget cards;
    if (_period == 0) {
      cards = Row(children: [
        _StatCard('Total Pallets', '$pallets', Icons.inventory_2_outlined),
        const SizedBox(width: 10),
        _StatCard('Total Items', '$items', Icons.widgets_outlined),
        const SizedBox(width: 10),
        _StatCard(
          'Pace',
          '$itemsPerHour',
          Icons.speed_outlined,
          unit: totalHours < 0.25
              ? 'items/hr'
              : 'items ÷ ${totalHours.toStringAsFixed(1)}h span',
        ),
      ]);
    } else {
      cards = Row(children: [
        _StatCard('Total Pallets', '$pallets', Icons.inventory_2_outlined),
        const SizedBox(width: 10),
        _StatCard('Total Items', '$items', Icons.widgets_outlined),
        const SizedBox(width: 10),
        _StatCard(
          'Avg Pallets/Shift',
          avgPalletsPerShift.toStringAsFixed(1),
          Icons.trending_up,
          unit: '${avgItemsPerPallet.toStringAsFixed(0)} items/pallet',
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cards,
          if (pallets > 0) ...[
            const SizedBox(height: 8),
            Text(
              densityLine,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            if (_period == 0 && totalHours >= 0.25) ...[
              const SizedBox(height: 4),
              Text(
                'Pace $itemsPerHour items/hr = $items items ÷ ${totalHours.toStringAsFixed(1)}h '
                '(each session: first to last pallet + 30m pad, not clock-in/out)',
                style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.35),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_period) {
      case 0: return _buildSessionList(_historySessions);
      case 1: return _buildWeekView();
      case 2: return _buildMonthView();
      default: return const SizedBox();
    }
  }

  // Notes belonging to one shift session, oldest first so they read in the order
  // they were written.
  List<ShiftNote> _notesFor(ShiftSession s) =>
      widget.notes
          .where((n) =>
              n.shift == s.shift && shiftDateKey(n.timestamp, n.shift) == s.dateKey)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  Future<void> _cycleRotationRole(ShiftSession s) async {
    // Cycle: clear → Regular → Overtime → clear (never show "untagged" in UI)
    final next = switch (s.rotationRole) {
      RotationRole.unset => RotationRole.roster,
      RotationRole.roster => RotationRole.extra,
      RotationRole.extra => RotationRole.unset,
    };
    await Storage.setSessionRotationRole(s.dateKey, s.shift, next);
    widget.onUpdate();
    if (!mounted) return;
    final msg = switch (next) {
      RotationRole.roster => '${s.dateKey} ${s.shift.label}: Regular',
      RotationRole.extra =>
        '${s.dateKey} ${s.shift.label}: Overtime (off-rotation days stay stats-only)',
      RotationRole.unset => '${s.dateKey} ${s.shift.label}: tag cleared',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildSessionList(List<ShiftSession> sessions) {
    if (sessions.isEmpty) {
      return const Center(child: Text('No data for this period', style: TextStyle(color: AppColors.muted)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: sessions.length,
      itemBuilder: (ctx, i) {
        final s = sessions[i];
        final sessionNotes = _notesFor(s);
        final hasPallets = s.totalPallets > 0;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onLongPress: hasPallets ? () => _cycleRotationRole(s) : null,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
                border: s.rotationRole == RotationRole.extra
                    ? Border.all(color: AppColors.warning.withValues(alpha: 0.45))
                    : s.rotationRole == RotationRole.roster
                        ? Border.all(color: AppColors.primary.withValues(alpha: 0.35))
                        : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.dateKey, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                          const SizedBox(height: 2),
                          Row(children: [
                            Text(s.shift.label,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            if (s.rotationRole != RotationRole.unset) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: s.rotationRole == RotationRole.extra
                                      ? AppColors.warning.withValues(alpha: 0.2)
                                      : AppColors.primary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  s.rotationRole == RotationRole.extra ? 'OVERTIME' : 'REGULAR',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: s.rotationRole == RotationRole.extra
                                        ? AppColors.warning
                                        : AppColors.primary,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ]),
                        ]),
                      ),
                      if (hasPallets)
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text('${s.totalPallets} pallets',
                              style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
                          Text(
                            s.hoursWorkedLabel,
                            style: const TextStyle(color: AppColors.muted, fontSize: 12),
                          ),
                        ])
                      else if (sessionNotes.isNotEmpty)
                        Text('${sessionNotes.length} note${sessionNotes.length == 1 ? '' : 's'}',
                            style: const TextStyle(color: AppColors.success, fontSize: 12)),
                    ],
                  ),
                  if (hasPallets) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Items: ${s.totalItems}  ·  '
                      'Avg stack: ${s.avgItems.toStringAsFixed(0)} items/pallet',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.paceLine,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.densityLine,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => _cycleRotationRole(s),
                      child: Text(
                        s.rotationRole == RotationRole.unset
                            ? 'Tap: set Regular / Overtime'
                            : 'Tap: Regular / Overtime / clear (now: ${s.rotationRole.label})',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    ),
                  ],
                  if (sessionNotes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Divider(height: 1, color: AppColors.border),
                    const SizedBox(height: 8),
                    const Text('NOTES',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: AppColors.success,
                          letterSpacing: 1.2,
                        )),
                    const SizedBox(height: 8),
                    ...sessionNotes.map((n) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 8),
                            child: Icon(Icons.notes, color: AppColors.success, size: 13),
                          ),
                          Expanded(
                            child: Text(n.text,
                                style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                          ),
                          const SizedBox(width: 8),
                          Text(DateFormat('HH:mm').format(n.timestamp),
                              style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                        ],
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWeekView() {
    final sessions = _weekSessions;
    final ws = _weekStart;
    // Multiple sessions can share a calendar dateKey (different soft labels).
    final sessionsByDay = <String, List<ShiftSession>>{};
    for (final s in sessions) {
      sessionsByDay.putIfAbsent(s.dateKey, () => []).add(s);
    }
    final dayFmt = DateFormat('EEE, MMM d');
    final dayKeyFmt = DateFormat('yyyy-MM-dd');

    final notesByDay = <String, List<ShiftNote>>{};
    for (final n in widget.notes) {
      final dk = shiftDateKey(n.timestamp, n.shift);
      notesByDay.putIfAbsent(dk, () => []).add(n);
    }
    for (final list in notesByDay.values) {
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 7,
      itemBuilder: (ctx, i) {
        final day = ws.add(Duration(days: i));
        final key = dayKeyFmt.format(day);
        final daySessions = sessionsByDay[key] ?? const <ShiftSession>[];
        final dayNotes = notesByDay[key] ?? const <ShiftNote>[];
        final isToday = key == dayKeyFmt.format(DateTime.now());
        final isWeekend = day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
        final empty = daySessions.isEmpty && dayNotes.isEmpty;
        final pallets = daySessions.fold(0, (a, s) => a + s.totalPallets);
        final items = daySessions.fold(0, (a, s) => a + s.totalItems);
        final stops = daySessions.fold(0, (a, s) => a + s.totalStops);
        final hours = daySessions.fold<double>(0, (a, s) => a + s.estimatedHoursWorked);
        final avgStack = pallets == 0 ? 0.0 : items / pallets;
        final density = stops <= 0 ? items.toDouble() : items / stops;
        final spp = pallets == 0 ? 0.0 : stops / pallets;
        final shiftLabels = daySessions.map((s) {
          final role = s.rotationRole == RotationRole.extra
              ? ' (overtime)'
              : s.rotationRole == RotationRole.roster
                  ? ' (regular)'
                  : '';
          return '${s.shift.label}$role';
        }).join(' · ');

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isToday ? AppColors.elevated : AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: isToday ? Border.all(color: AppColors.primary.withValues(alpha: 0.5)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(dayFmt.format(day),
                          style: TextStyle(
                            fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                            color: isWeekend && empty ? AppColors.elevated : null,
                          )),
                      if (daySessions.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(shiftLabels,
                            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                      ],
                    ]),
                  ),
                  if (daySessions.isNotEmpty)
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('$pallets pallets',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.primary)),
                      Text(
                        '$items items · ${avgStack.toStringAsFixed(0)} items/pallet · ${hours.toStringAsFixed(1)}h span',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                      Text(
                        hours < 0.25
                            ? 'Pace -'
                            : 'Pace ${(items / hours).round()} items/hr (items ÷ span)',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                      Text(
                        'Density ${density.toStringAsFixed(1)} items/stop · ${spp.toStringAsFixed(1)} stops/pallet',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    ])
                  else if (dayNotes.isEmpty)
                    Text(isWeekend ? 'off' : '-',
                        style: TextStyle(color: AppColors.elevated, fontSize: 13)),
                ],
              ),
              if (dayNotes.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 8),
                ...dayNotes.map((n) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2, right: 8),
                        child: Icon(Icons.notes, color: AppColors.success, size: 13),
                      ),
                      Expanded(
                        child: Text(n.text,
                            style: const TextStyle(fontSize: 13, color: AppColors.muted)),
                      ),
                      const SizedBox(width: 8),
                      Text(DateFormat('HH:mm').format(n.timestamp),
                          style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                    ],
                  ),
                )),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildMonthView() {
    final sessions = _monthSessions;
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No data for this month.\nTap ← to view previous months.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted)),
        ),
      );
    }

    // Soft-label buckets for charts (may include long OT blocks labeled evening
    // even if they started in the morning window: label is display-only).
    final byShift = <ShiftType, ({int pallets, int items, int stops, int sessions, double hours})>{};
    for (final s in sessions) {
      if (s.totalPallets == 0) continue;
      final c = byShift[s.shift] ?? (pallets: 0, items: 0, stops: 0, sessions: 0, hours: 0.0);
      byShift[s.shift] = (
        pallets: c.pallets + s.totalPallets,
        items: c.items + s.totalItems,
        stops: c.stops + s.totalStops,
        sessions: c.sessions + 1,
        hours: c.hours + s.estimatedHoursWorked,
      );
    }
    final totalPallets = byShift.values.fold(0, (a, b) => a + b.pallets);

    // Week totals include hours (Session 13 span, not flat 8h).
    final weekMap = <String, ({DateTime ws, int pallets, int items, int stops, double hours, List<ShiftType> shifts})>{};
    for (final s in sessions) {
      final d = _parse(s.dateKey);
      final ws = d.subtract(Duration(days: d.weekday - 1));
      final wsKey = DateFormat('yyyy-MM-dd').format(ws);
      final c = weekMap[wsKey] ??
          (ws: ws, pallets: 0, items: 0, stops: 0, hours: 0.0, shifts: <ShiftType>[]);
      if (!c.shifts.contains(s.shift)) c.shifts.add(s.shift);
      weekMap[wsKey] = (
        ws: c.ws,
        pallets: c.pallets + s.totalPallets,
        items: c.items + s.totalItems,
        stops: c.stops + s.totalStops,
        hours: c.hours + s.estimatedHoursWorked,
        shifts: c.shifts,
      );
    }
    final weeks = weekMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        const Text('BY SHIFT TYPE (soft label)',
            style: TextStyle(color: AppColors.muted, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'Groups by the label used when logging. Long OT may sit under one label (e.g. Evening) even if it started earlier.',
          style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
        ),
        const SizedBox(height: 8),
        ...ShiftType.values.where((t) => byShift.containsKey(t)).map((t) {
          final d = byShift[t]!;
          final pct = totalPallets > 0 ? d.pallets / totalPallets : 0.0;
          final avgStack = d.pallets > 0 ? d.items / d.pallets : 0.0;
          final avgPerSession = d.sessions > 0 ? d.pallets / d.sessions : 0.0;
          final rate = d.hours < 0.25 ? 0 : (d.items / d.hours).round();
          final dens = d.stops <= 0 ? d.items.toDouble() : d.items / d.stops;
          final spp = d.pallets == 0 ? 0.0 : d.stops / d.pallets;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('${t.label.toUpperCase()} SHIFT',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                        color: _shiftColor(t), letterSpacing: 1.2)),
                Text(t.timeRange, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ]),
              const SizedBox(height: 8),
              Text('${d.pallets} pallets  ·  ${d.items} items',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '${avgStack.toStringAsFixed(0)} items/pallet  ·  '
                '${avgPerSession.toStringAsFixed(1)} pallets/shift  ·  '
                'Pace $rate items/hr  ·  ${d.hours.toStringAsFixed(1)}h span',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                'Density ${dens.toStringAsFixed(1)} items/stop · ${spp.toStringAsFixed(1)} stops/pallet',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: pct, minHeight: 5,
                      backgroundColor: AppColors.border,
                      valueColor: AlwaysStoppedAnimation(_shiftColor(t)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(pct * 100).toStringAsFixed(0)}% of month',
                    style: TextStyle(color: AppColors.muted, fontSize: 11)),
              ]),
            ]),
          );
        }),

        const SizedBox(height: 16),

        const Text('WEEK BY WEEK',
            style: TextStyle(color: AppColors.muted, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...weeks.map((e) {
          final we = e.value.ws.add(const Duration(days: 6));
          final fmt = DateFormat('MMM d');
          final shiftLabels = e.value.shifts.map((s) => s.label).join(', ');
          final avgStack = e.value.pallets == 0 ? 0.0 : e.value.items / e.value.pallets;
          final rate = e.value.hours < 0.25 ? 0 : (e.value.items / e.value.hours).round();
          final dens = e.value.stops <= 0 ? e.value.items.toDouble() : e.value.items / e.value.stops;
          final spp = e.value.pallets == 0 ? 0.0 : e.value.stops / e.value.pallets;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${fmt.format(e.value.ws)} – ${fmt.format(we)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('Worked: $shiftLabels', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                  child: Text(
                    'Output: ${e.value.pallets} pallets · ${e.value.items} items\n'
                    'Avg stack: ${avgStack.toStringAsFixed(0)} items/pallet\n'
                    'Density ${dens.toStringAsFixed(1)} items/stop · ${spp.toStringAsFixed(1)} stops/pallet',
                    style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                  ),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${e.value.hours.toStringAsFixed(1)}h span',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.primary)),
                  Text('Pace $rate items/hr', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
                ]),
              ]),
            ]),
          );
        }),
      ],
    );
  }

  Color _shiftColor(ShiftType s) {
    switch (s) {
      case ShiftType.morning: return AppColors.warning;
      case ShiftType.evening: return AppColors.primary;
      case ShiftType.night:   return AppColors.shiftNight;
    }
  }
}

class _NavRow extends StatelessWidget {
  final String label;
  final VoidCallback onPrev;
  final VoidCallback? onNext;
  const _NavRow({required this.label, required this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: onPrev,
            color: AppColors.primary),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        IconButton(icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
            color: onNext != null ? AppColors.primary : AppColors.border),
      ],
    ),
  );
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? unit;
  const _StatCard(this.label, this.value, this.icon, {this.unit});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 10)),
        if (unit != null)
          Text(unit!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 9)),
      ]),
    ),
  );
}

// ─── SCHEDULE SCREEN ─────────────────────────────────────────────────────────

class ScheduleScreen extends StatelessWidget {
  final List<PalletEntry> entries;
  final List<ShiftType>? userCycle;
  const ScheduleScreen({super.key, required this.entries, this.userCycle});

  @override
  Widget build(BuildContext context) {
    final isFixed = userCycle != null && userCycle!.length == 1;
    final forecast = isFixed
        ? const ScheduleForecast(days: [])
        : ShiftPredictor.forecast(entries, weeks: 4, userCycle: userCycle);
    final predictions = forecast.days;
    final today = DateTime.now();

    final title = isFixed
        ? 'Your Shift'
        : forecast.confidence == AnchorConfidence.roster
            ? 'Rotation estimate'
            : 'Rotation estimate (low confidence)';
    final subtitle = isFixed
        ? 'Fixed schedule; no rotation'
        : forecast.fromSetup
            ? 'From setup · ${forecast.anchorShift?.label ?? ''} (no logs yet)'
            : forecast.anchorDateKey != null
                ? forecast.confidence == AnchorConfidence.roster
                    ? 'From Regular day ${forecast.anchorDateKey} · ${forecast.anchorShift?.label ?? ''}'
                    : 'Estimated from older logs · ${forecast.anchorDateKey} ${forecast.anchorShift?.label ?? ''}'
                : 'Complete shift setup to build a schedule';

    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              subtitle,
              style: TextStyle(
                color: forecast.isLowConfidence
                    ? AppColors.warning
                    : AppColors.muted,
                fontSize: 12,
              ),
            ),
          ),
        ),
        if (forecast.warning != null) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warningSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
              ),
              child: Text(
                forecast.warning!,
                style: const TextStyle(color: AppColors.warning, fontSize: 12, height: 1.35),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: isFixed
              ? _buildFixedShiftView(userCycle!.first)
              : predictions.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Complete rotating-shift setup to enable prediction',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted),
                        ),
                      ),
                    )
                  : _buildCalendar(predictions, today),
        ),
      ]),
    );
  }

  Widget _buildFixedShiftView(ShiftType shift) {
    final color = _shiftColor(shift);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
                border: Border.all(color: color, width: 2),
              ),
              child: Icon(Icons.schedule, color: color, size: 36),
            ),
            const SizedBox(height: 20),
            Text(shift.label,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 6),
            Text(shift.timeRange,
                style: TextStyle(color: AppColors.muted, fontSize: 15)),
            const SizedBox(height: 16),
            Text('You\'re on a fixed shift.\nNo rotation to predict.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar(List<({DateTime date, ShiftType shift})> predictions, DateTime today) {
    String? lastShift;
    final rows = <Widget>[];

    for (final p in predictions) {
      if (p.shift.name != lastShift) {
        lastShift = p.shift.name;
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 6));
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(p.shift.label.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _shiftColor(p.shift),
                letterSpacing: 1.5,
              )),
        ));
      }

      final isToday = p.date.year == today.year &&
          p.date.month == today.month &&
          p.date.day == today.day;

      rows.add(Container(
        margin: const EdgeInsets.fromLTRB(16, 2, 16, 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isToday ? _shiftColor(p.shift).withValues(alpha: 0.2) : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: isToday ? Border.all(color: _shiftColor(p.shift), width: 1) : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              if (isToday)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _shiftColor(p.shift),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('TODAY', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: AppColors.onPrimary)),
                ),
              Text(DateFormat('EEE, MMM d').format(p.date),
                  style: TextStyle(fontWeight: isToday ? FontWeight.bold : FontWeight.normal)),
            ]),
            Text(p.shift.timeRange, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ],
        ),
      ));
    }

    return ListView(children: rows);
  }

  Color _shiftColor(ShiftType s) {
    switch (s) {
      case ShiftType.morning: return AppColors.warning;
      case ShiftType.evening: return AppColors.primary;
      case ShiftType.night: return AppColors.shiftNight;
    }
  }
}

// ─── SETUP SCREEN ─────────────────────────────────────────────────────────────

class SetupScreen extends StatefulWidget {
  final Future<void> Function(List<ShiftType> cycle) onComplete;
  const SetupScreen({super.key, required this.onComplete});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  // step 0 = fixed/rotating, step 1 = which shift, step 2 = previous shift (rotating only)
  // Consent is NOT part of setup; only the load-time bottom sheet asks once.
  int _step = 0;
  bool? _isRotating;
  ShiftType? _currentShift;
  ShiftType? _previousShift;

  List<ShiftType> get _remainingShifts =>
      ShiftType.values.where((s) => s != _currentShift).toList();

  List<ShiftType> _deriveCycle(ShiftType current, ShiftType previous) {
    final third = ShiftType.values.firstWhere((s) => s != current && s != previous);
    return [current, third, previous];
  }

  Future<void> _finish() async {
    final cycle = _isRotating == false
        ? [_currentShift!]                              // fixed: single element
        : _deriveCycle(_currentShift!, _previousShift!); // rotating: 3 elements
    await widget.onComplete(cycle);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              const Text('Setup',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  )),
              const SizedBox(height: 6),
              const Text(
                'Help Stacked understand your shift pattern.',
                style: TextStyle(color: AppColors.muted, fontSize: 14),
              ),
              const SizedBox(height: 40),

              // ── Step 0: Fixed or rotating? ────────────────────────────────
              if (_step == 0) ...[
                const Text('How does your shift work?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    )),
                const SizedBox(height: 20),
                _optionCard(
                  icon: Icons.schedule,
                  title: 'Fixed shift',
                  subtitle: 'Same shift every week: no rotation',
                  onTap: () => setState(() { _isRotating = false; _step = 1; }),
                ),
                const SizedBox(height: 12),
                _optionCard(
                  icon: Icons.loop,
                  title: 'Rotating shifts',
                  subtitle: 'Cycle through morning, evening, and night',
                  onTap: () => setState(() { _isRotating = true; _step = 1; }),
                ),
              ],

              // ── Step 1: Which shift? ───────────────────────────────────────
              if (_step == 1) ...[
                Text(
                  _isRotating == true
                      ? 'What shift are you currently working?'
                      : 'Which shift do you work?',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 20),
                ...ShiftType.values.map((s) => _shiftButton(
                  shift: s,
                  selected: _currentShift == s,
                  onTap: () {
                    setState(() { _currentShift = s; _previousShift = null; });
                    if (_isRotating == false) _finish(); // fixed shift: done immediately
                  },
                )),
                const Spacer(),
                if (_isRotating == true) ...[
                  Row(children: [
                    TextButton(
                      onPressed: () => setState(() { _step = 0; _currentShift = null; }),
                      child: const Text('Back'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _currentShift != null ? () => setState(() => _step = 2) : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: AppColors.onPrimary,
                            elevation: 0,
                            disabledBackgroundColor: AppColors.elevated,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: AppColors.border, width: 1),
                            ),
                          ),
                          child: const Text('Next', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ]),
                ],
              ],

              // ── Step 2: Previous shift (rotating only) ────────────────────
              if (_step == 2) ...[
                const Text('What shift did you work before this one?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    )),
                const SizedBox(height: 20),
                ..._remainingShifts.map((s) => _shiftButton(
                  shift: s,
                  selected: _previousShift == s,
                  onTap: () => setState(() => _previousShift = s),
                )),
                if (_previousShift != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border, width: 1),
                    ),
                    child: Row(children: [
                      const Icon(Icons.loop, color: AppColors.primary, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'Your rotation: ${_deriveCycle(_currentShift!, _previousShift!).map((s) => s.label).join(' → ')} → ...',
                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                      )),
                    ]),
                  ),
                ],
                const Spacer(),
                Row(children: [
                  TextButton(
                    onPressed: () => setState(() { _step = 1; _previousShift = null; }),
                    child: const Text('Back'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _previousShift != null ? _finish : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.onPrimary,
                          elevation: 0,
                          disabledBackgroundColor: AppColors.elevated,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: AppColors.border, width: 1),
                          ),
                        ),
                        child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionCard({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 1),
        ),
        child: Row(children: [
          Icon(icon, color: AppColors.primary, size: 28),
          const SizedBox(width: 16),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text)),
              const SizedBox(height: 3),
              Text(subtitle, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
            ],
          )),
          const Icon(Icons.chevron_right, color: AppColors.muted),
        ]),
      ),
    );
  }

  Widget _shiftButton({required ShiftType shift, required bool selected, required VoidCallback onTap}) {
    final color = switch (shift) {
      ShiftType.morning => AppColors.warning,
      ShiftType.evening => AppColors.primary,
      ShiftType.night   => AppColors.shiftNight,
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : AppColors.border, width: 1),
        ),
        child: Row(children: [
          Text(shift.label,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600,
                  color: selected ? color : AppColors.text)),
          const SizedBox(width: 10),
          Text(shift.timeRange,
              style: TextStyle(fontSize: 13, color: selected ? color.withValues(alpha: 0.8) : AppColors.muted)),
          const Spacer(),
          if (selected) Icon(Icons.check_circle, color: color, size: 20),
        ]),
      ),
    );
  }
}

// ─── FIRST-RUN COACH MARKS ───────────────────────────────────────────────────

class _CoachMarksOverlay extends StatelessWidget {
  final int step; // 0 note, 1 swipe, 2 backup
  final GlobalKey noteKey;
  final GlobalKey listKey;
  final GlobalKey backupKey;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _CoachMarksOverlay({
    required this.step,
    required this.noteKey,
    required this.listKey,
    required this.backupKey,
    required this.onNext,
    required this.onSkip,
  });

  // Compact bubbles: optional pun title + one short line, anchored to the target.
  static const _titles = ['Ahoy!', null, null];
  static const _bodies = [
    'Add notes',
    'Swipe left to delete',
    'Back up or restore here',
  ];

  Rect? _targetRect(BuildContext overlayContext) {
    final key = switch (step) {
      0 => noteKey,
      1 => listKey,
      _ => backupKey,
    };
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final overlayBox = overlayContext.findRenderObject() as RenderBox?;
    if (overlayBox == null) return null;
    final global = box.localToGlobal(Offset.zero);
    final local = overlayBox.globalToLocal(global);
    return local & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final target = _targetRect(context);
    final title = _titles[step];
    final body = _bodies[step];

    // Anchor the bubble tail to the target. For a big target (the list area on
    // step 1) sit just inside its top so the bubble never shoves the keypad;
    // for small icon targets, sit just below.
    final Offset anchor;
    if (target != null) {
      final y = target.height > 120 ? target.top + 44 : target.bottom;
      anchor = Offset(target.center.dx, y);
    } else {
      anchor = Offset(media.size.width - 60, media.padding.top + 52);
    }

    const maxW = 230.0;
    final bubbleLeft = (anchor.dx - 26).clamp(12.0, media.size.width - maxW - 12);
    final tailLeft = (anchor.dx - bubbleLeft - 8).clamp(14.0, maxW - 26);
    final bubbleTop = (anchor.dy + 8).clamp(media.padding.top + 8, media.size.height - 150);

    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      child: Stack(
        children: [
          if (target != null)
            Positioned(
              left: (target.left - 6).clamp(4.0, media.size.width - 40),
              top: target.top - 6,
              child: IgnorePointer(
                child: Container(
                  width: target.width + 12,
                  height: target.height + 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.primary, width: 2),
                    color: AppColors.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
          Positioned(
            left: bubbleLeft,
            top: bubbleTop,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxW),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: tailLeft),
                    child: CustomPaint(size: const Size(16, 8), painter: _TailPainter()),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border, width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (title != null) ...[
                          Text(
                            title,
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                        ],
                        Text(
                          body,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${step + 1}/3',
                              style: const TextStyle(color: AppColors.muted, fontSize: 11),
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: onSkip,
                              child: const Text('Skip',
                                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: onNext,
                              child: Text(
                                step >= 2 ? 'Done' : 'Next',
                                style: const TextStyle(
                                    color: AppColors.primary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Small upward-pointing triangle that visually ties the bubble to its target.
class _TailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = AppColors.card
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawLine(Offset(0, size.height), Offset(size.width / 2, 0), stroke);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width, size.height), stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
