import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _timezone = 'Europe/Lisbon';
const _utcOffsetSeconds = 3600; // WEST (summer time), 2025-06-15/16
const _captureSeconds = 12 * 60 * 60;
const _sleepOnsetIndex = 60 * 60; // 23:00 local; capture starts 22:00
const _finalWakeIndex = 8 * 60 * 60; // 06:00 local

final _captureStartSec =
    DateTime.utc(2025, 6, 15, 21).millisecondsSinceEpoch ~/ 1000;

enum _Signal { ordinary, quiet, clear }

enum _MovementProfile { sleepLike, wakeLike, mild }

enum _HrProfile { sleepLike, wakeLike, moderate }

enum _ArousalSignal { movementOnly, hrOnly, both }

typedef _ArousalEvent = ({
  int startOffsetSec,
  int durationSec,
  _ArousalSignal signal,
});

typedef _Fixture = ({
  List<AccelSample> accel,
  List<double> hr,
  int confirmedWakeSec,
  int leaveBedSec,
  int trueAwakeInBedMinutes,
  String caseName,
});

_Fixture _build({
  required String caseName,
  required int awakeInBedMinutes,
  required _Signal signal,
  _MovementProfile? movementProfile,
  _HrProfile? hrProfile,
  List<_ArousalEvent> arousals = const [],
  bool continuedSleepTruth = false,
}) {
  final movement =
      movementProfile ??
      switch (signal) {
        _Signal.ordinary => _MovementProfile.sleepLike,
        _Signal.quiet => _MovementProfile.sleepLike,
        _Signal.clear => _MovementProfile.wakeLike,
      };
  final heartRate =
      hrProfile ??
      switch (signal) {
        _Signal.ordinary => _HrProfile.sleepLike,
        _Signal.quiet => _HrProfile.sleepLike,
        _Signal.clear => _HrProfile.wakeLike,
      };
  final wakeSec = _captureStartSec + _finalWakeIndex;
  final leaveBedSec = wakeSec + awakeInBedMinutes * 60;
  final leaveBedIndex = _finalWakeIndex + awakeInBedMinutes * 60;
  final confirmedWakeSec = continuedSleepTruth ? leaveBedSec : wakeSec;
  final accel = <AccelSample>[];
  final hr = <double>[];

  for (var i = 0; i < _captureSeconds; i++) {
    final t = _captureStartSec + i;
    final beforeSleep = i < _sleepOnsetIndex;
    final asleepBySignal = i >= _sleepOnsetIndex && i < _finalWakeIndex;
    final inPostWakeInterval = i >= _finalWakeIndex && i < leaveBedIndex;
    final afterLeaveBed = i >= leaveBedIndex;
    _ArousalEvent? activeArousal;
    for (final arousal in arousals) {
      if (i >= arousal.startOffsetSec &&
          i < arousal.startOffsetSec + arousal.durationSec) {
        activeArousal = arousal;
        break;
      }
    }
    final arousalMoves =
        activeArousal != null &&
        (activeArousal.signal == _ArousalSignal.movementOnly ||
            activeArousal.signal == _ArousalSignal.both);
    final arousalRaisesHr =
        activeArousal != null &&
        (activeArousal.signal == _ArousalSignal.hrOnly ||
            activeArousal.signal == _ArousalSignal.both);

    final double bpm;
    if (beforeSleep) {
      bpm = 74 + 2 * math.sin(i / 90.0);
    } else if (arousalRaisesHr) {
      bpm = 82 + 2 * math.sin(i / 120.0);
    } else if (afterLeaveBed ||
        (inPostWakeInterval && heartRate == _HrProfile.wakeLike)) {
      bpm = 86 + 2 * math.sin(i / 120.0);
    } else if (inPostWakeInterval && heartRate == _HrProfile.moderate) {
      bpm = 69 + 1.5 * math.sin(i / 1800.0);
    } else if (inPostWakeInterval && heartRate == _HrProfile.sleepLike) {
      bpm = 57 + 1.5 * math.sin(i / 1800.0);
    } else {
      bpm = (asleepBySignal ? 52 : 57) + 1.5 * math.sin(i / 1800.0);
    }

    var ax = 0.02;
    var ay = 0.02;
    var az = 1.0;
    if (beforeSleep ||
        afterLeaveBed ||
        (inPostWakeInterval && movement == _MovementProfile.wakeLike) ||
        arousalMoves) {
      final phase = math.sin(i * 0.5);
      ax = 0.3 * phase;
      ay = 0.3;
      az = 0.9 * (1 - 0.2 * phase);
    } else if (inPostWakeInterval && movement == _MovementProfile.sleepLike) {
      // Preserve the Phase 3B2 quiet profile: a tiny wrist adjustment every
      // 15 minutes, independent of the HR profile.
      final pulseSecond = (i - _finalWakeIndex) % 900;
      if (pulseSecond < 5) {
        ax = 0.02 + 0.025 * math.sin(pulseSecond * math.pi / 4);
        ay = 0.02;
        az = math.sqrt(1 - ax * ax - ay * ay);
      }
    } else if (inPostWakeInterval && movement == _MovementProfile.mild) {
      // A modest 10-second adjustment every three minutes.
      final pulseSecond = (i - _finalWakeIndex) % 180;
      if (pulseSecond < 10) {
        ax = 0.02 + 0.08 * math.sin(pulseSecond * math.pi / 5);
        ay = 0.04;
        az = math.sqrt(1 - ax * ax - ay * ay);
      }
    }

    accel.add(AccelSample(t * 1000.0, ax, ay, az));
    hr.add(bpm.roundToDouble());
  }

  return (
    accel: accel,
    hr: hr,
    confirmedWakeSec: confirmedWakeSec,
    leaveBedSec: leaveBedSec,
    trueAwakeInBedMinutes: continuedSleepTruth ? 0 : awakeInBedMinutes,
    caseName: caseName,
  );
}

List<GravTs> _gravity(_Fixture fixture) => [
  for (final sample in fixture.accel)
    GravTs(
      sample.tsMs ~/ 1000,
      sample.x,
      sample.y,
      sample.z,
      valid: sample.valid,
    ),
];

List<HrTs> _heartRate(_Fixture fixture) => [
  for (var i = 0; i < fixture.hr.length; i++)
    if (fixture.hr[i] > 0) HrTs(fixture.accel[i].tsMs ~/ 1000, fixture.hr[i]),
];

List<SleepSession> _detect(_Fixture fixture) => AdvancedSleepStager.detectSleep(
  _gravity(fixture),
  _heartRate(fixture),
  tzOffsetSec: _utcOffsetSeconds,
);

SleepSegmentation _segment(_Fixture fixture, {List<int>? bandSleepState}) =>
    segmentSleep(
      fixture.accel,
      fixture.hr,
      tzOffsetSec: _utcOffsetSeconds,
      bandSleepState: bandSleepState,
    );

String _localTime(int epochSec) => DateTime.fromMillisecondsSinceEpoch(
  (epochSec + _utcOffsetSeconds) * 1000,
  isUtc: true,
).toIso8601String().replaceFirst('Z', '+01:00');

String _windows(List<SleepSession> sessions) => [
  for (final session in sessions)
    '[${_localTime(session.start)}, ${_localTime(session.end)})',
].join('; ');

Map<String, int> _segmentStages(SleepSegmentation result) {
  final counts = <String, int>{};
  for (final stage in result.stages4) {
    counts.update(stage, (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

Map<String, int> _sessionStageOverlap(
  SleepSession session,
  int startSec,
  int endSec,
) {
  final counts = <String, int>{};
  for (final span in session.stages) {
    final seconds = math
        .max(0, math.min(span.end, endSec) - math.max(span.start, startSec))
        .toInt();
    if (seconds > 0) {
      counts.update(span.stage, (n) => n + seconds, ifAbsent: () => seconds);
    }
  }
  return counts;
}

({double? hrMean, double? meanDeltaG}) _wakeSignalStats(_Fixture fixture) {
  final from = fixture.confirmedWakeSec - _captureStartSec;
  final until = fixture.leaveBedSec - _captureStartSec;
  if (until - from < 2) return (hrMean: null, meanDeltaG: null);
  final hrMean =
      fixture.hr.sublist(from, until).reduce((a, b) => a + b) / (until - from);
  var delta = 0.0;
  for (var i = from + 1; i < until; i++) {
    final dx = fixture.accel[i].x - fixture.accel[i - 1].x;
    final dy = fixture.accel[i].y - fixture.accel[i - 1].y;
    final dz = fixture.accel[i].z - fixture.accel[i - 1].z;
    delta += math.sqrt(dx * dx + dy * dy + dz * dz);
  }
  return (hrMean: hrMean, meanDeltaG: delta / (until - from - 1));
}

void _record(_Fixture fixture, {bool banded = false}) {
  final result = _segment(
    fixture,
    bandSleepState: banded ? _gen5BandEnvelope(fixture) : null,
  );
  final sessions = _detect(fixture);
  final offset = result.window?.offsetMs == null
      ? null
      : result.window!.offsetMs!.toInt() ~/ 1000;
  final extensionMinutes = offset == null
      ? null
      : math.max(0, (offset - fixture.confirmedWakeSec) ~/ 60);
  final stats = _wakeSignalStats(fixture);

  // Stage a fixed 23:00–08:00 diagnostic interval, the same for every case.
  // The confirmed wake/leave-bed times are used only afterward to score the
  // returned stage labels; they are never passed to auto window detection.
  final stageDiagnostic = AdvancedSleepStager.stageWindow(
    _captureStartSec + _sleepOnsetIndex,
    _captureStartSec + 10 * 60 * 60,
    _gravity(fixture),
    _heartRate(fixture),
  );
  final postWakeStageCounts = fixture.trueAwakeInBedMinutes == 0
      ? const <String, int>{}
      : _sessionStageOverlap(
          stageDiagnostic,
          fixture.confirmedWakeSec,
          fixture.leaveBedSec,
        );

  // ignore: avoid_print
  print(
    'ANALYTICS ${fixture.caseName}: timezone=$_timezone, '
    'true onset=${_localTime(_captureStartSec + _sleepOnsetIndex)}, '
    'confirmed wake=${_localTime(fixture.confirmedWakeSec)}, '
    'leave bed=${_localTime(fixture.leaveBedSec)}, '
    'awake-in-bed=${fixture.trueAwakeInBedMinutes}m, '
    'detected=[${result.window == null ? 'absent' : _localTime(result.window!.onsetMs!.toInt() ~/ 1000)}, '
    '${offset == null ? 'absent' : _localTime(offset)}), '
    'extension=${extensionMinutes}m, source=segmentSleep/auto, '
    'stager-windows=${_windows(sessions)}, '
    'in-bed=${result.inBedSec}, TST=${result.tstSec}, WASO=${result.wasoSec}, '
    'unobserved=${result.unobservedSec}, stages=${_segmentStages(result)}, '
    'staged-awake-interval=$postWakeStageCounts, '
    'wake-HR-mean=${stats.hrMean?.toStringAsFixed(2) ?? 'n/a'}, '
    'wake-mean-|delta-g|=${stats.meanDeltaG?.toStringAsFixed(5) ?? 'n/a'}, '
    'banded=$banded',
  );
}

List<int> _gen5BandEnvelope(_Fixture fixture) => [
  for (var i = 0; i < fixture.accel.length; i++)
    if (i < _sleepOnsetIndex)
      0
    else if (i < _finalWakeIndex)
      2
    else if (i <
        _finalWakeIndex + (fixture.leaveBedSec - fixture.confirmedWakeSec))
      3
    else
      0,
];

typedef _Observation = ({
  SleepSegmentation segmented,
  List<SleepSession> sessions,
  SleepSession fixedWindowStages,
  Map<String, int> awakeStageSeconds,
});

_Observation _observe(_Fixture fixture) {
  final segmented = _segment(fixture);
  final sessions = _detect(fixture);
  final fixedWindowStages = AdvancedSleepStager.stageWindow(
    _captureStartSec + _sleepOnsetIndex,
    _captureStartSec + 10 * 60 * 60,
    _gravity(fixture),
    _heartRate(fixture),
  );
  final awakeStageSeconds = _sessionStageOverlap(
    fixedWindowStages,
    fixture.confirmedWakeSec,
    fixture.leaveBedSec,
  );
  return (
    segmented: segmented,
    sessions: sessions,
    fixedWindowStages: fixedWindowStages,
    awakeStageSeconds: awakeStageSeconds,
  );
}

bool _sameMotion(List<AccelSample> a, List<AccelSample> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final left = a[i];
    final right = b[i];
    if (left.tsMs != right.tsMs ||
        left.x != right.x ||
        left.y != right.y ||
        left.z != right.z ||
        left.valid != right.valid) {
      return false;
    }
  }
  return true;
}

bool _sameHeartRate(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _samePreAwakeningMotion(List<AccelSample> a, List<AccelSample> b) {
  if (a.length != b.length || a.length < _finalWakeIndex) return false;
  for (var i = 0; i < _finalWakeIndex; i++) {
    final left = a[i];
    final right = b[i];
    if (left.tsMs != right.tsMs ||
        left.x != right.x ||
        left.y != right.y ||
        left.z != right.z ||
        left.valid != right.valid) {
      return false;
    }
  }
  return true;
}

bool _samePreAwakeningHeartRate(List<double> a, List<double> b) {
  if (a.length != b.length || a.length < _finalWakeIndex) return false;
  for (var i = 0; i < _finalWakeIndex; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _outcome(
  SleepSegmentation result,
  List<SleepSession> sessions,
  int wake,
) {
  final window = result.window;
  if (window == null) return 'rejected';
  if (sessions.length > 1) return 'split(${sessions.length})';
  final offset = window.offsetMs?.toInt() ?? 0;
  if (offset < wake * 1000) return 'truncated-before-wake';
  return 'single-window';
}

String _durationMinutes(int? seconds) =>
    seconds == null ? 'n/a' : '${(seconds / 60).toStringAsFixed(1)}m';

void _printPrimaryResult(_Fixture fixture, _Observation observed) {
  final result = observed.segmented;
  final onset = result.window?.onsetMs?.toInt();
  final offset = result.window?.offsetMs?.toInt();
  final durationSec = onset == null || offset == null
      ? null
      : (offset - onset) ~/ 1000;
  final offsetError = offset == null
      ? 'n/a'
      : '${((offset ~/ 1000 - fixture.confirmedWakeSec) / 60).toStringAsFixed(1)}m';
  final awakeEpochs = observed.awakeStageSeconds['wake'] ?? 0;
  // ignore: avoid_print
  print(
    '3B3 ${fixture.caseName}: true-wake=${_localTime(fixture.confirmedWakeSec)}, '
    'offset=${offset == null ? 'absent' : _localTime(offset ~/ 1000)}, '
    'signed-error=${offsetError}, '
    'detected-window=${_durationMinutes(durationSec)}, '
    'in-bed=${result.inBedSec}s, TST=${result.tstSec}s, '
    'WASO=${result.wasoSec}s, unobserved=${result.unobservedSec}s, '
    'auto-segment-stages=${_segmentStages(result)}, '
    'fixed-window-wake-epochs=${awakeEpochs}s/'
    '${fixture.trueAwakeInBedMinutes * 60}s, '
    'window-outcome=${_outcome(result, observed.sessions, fixture.confirmedWakeSec)}, '
    'detector-sessions=${observed.sessions.length}',
  );
}

void _printArousalResult(
  _Fixture fixture,
  _Observation observed,
  _ArousalEvent arousal,
) {
  final result = observed.segmented;
  final eventStart = _captureStartSec + arousal.startOffsetSec;
  final eventEnd = eventStart + arousal.durationSec;
  final eventStages = _sessionStageOverlap(
    observed.fixedWindowStages,
    eventStart,
    eventEnd,
  );
  final offset = result.window?.offsetMs?.toInt();
  // ignore: avoid_print
  print(
    '3B3 AROUSAL ${fixture.caseName}: event='
    '[${_localTime(eventStart)}, ${_localTime(eventEnd)}), '
    'true-wake=${_localTime(fixture.confirmedWakeSec)}, '
    'offset=${offset == null ? 'absent' : _localTime(offset ~/ 1000)}, '
    'in-bed=${result.inBedSec}s, TST=${result.tstSec}s, '
    'WASO=${result.wasoSec}s, unobserved=${result.unobservedSec}s, '
    'auto-segment-stages=${_segmentStages(result)}, '
    'event-stages=${eventStages}, detector-sessions=${observed.sessions.length}, '
    'window-outcome='
    '${_outcome(result, observed.sessions, fixture.confirmedWakeSec)}',
  );
}

void main() {
  test('ordinary, quiet and clear waking characterize the sleep window', () {
    final control = _build(
      caseName: 'CONTROL ordinary waking activity',
      awakeInBedMinutes: 0,
      signal: _Signal.ordinary,
    );
    _record(control);
    final controlResult = _segment(control);
    expect(controlResult.present, isTrue);
    final onset = _captureStartSec + _sleepOnsetIndex;
    expect(controlResult.window!.onsetMs! ~/ 1000, onset + 171);
    expect(
      controlResult.window!.offsetMs! ~/ 1000,
      control.confirmedWakeSec - 171,
    );
    expect(controlResult.inBedSec, 24858);
    expect(controlResult.tstSec, controlResult.inBedSec);
    expect(controlResult.wasoSec, 0);
    expect(controlResult.unobservedSec, 0);
    expect(_segmentStages(controlResult).keys.toSet(), {'light'});
    expect(_detect(control).single.end, control.confirmedWakeSec - 171);
    expect(
      controlResult.window!.onsetMs! ~/ 1000,
      closeTo(_captureStartSec + _sleepOnsetIndex, 15 * 60),
    );
    expect(
      controlResult.window!.offsetMs! ~/ 1000,
      closeTo(control.confirmedWakeSec, 15 * 60),
    );

    for (final minutes in [30, 60, 90]) {
      final quiet = _build(
        caseName: 'QUIET WAKE ${minutes}m',
        awakeInBedMinutes: minutes,
        signal: _Signal.quiet,
      );
      final clear = _build(
        caseName: 'CLEAR WAKE ${minutes}m',
        awakeInBedMinutes: minutes,
        signal: _Signal.clear,
      );
      final continuedSleep = _build(
        caseName: 'SENSOR-INDISTINGUISHABLE continued sleep ${minutes}m',
        awakeInBedMinutes: minutes,
        signal: _Signal.quiet,
        continuedSleepTruth: true,
      );
      _record(quiet);
      _record(clear);
      _record(continuedSleep);

      // The two stories have different confirmed-awakening truth, but exactly
      // the same 1 Hz sensor observations.
      expect(
        quiet.accel.map((x) => [x.tsMs, x.x, x.y, x.z]).toList(),
        continuedSleep.accel.map((x) => [x.tsMs, x.x, x.y, x.z]).toList(),
      );
      expect(quiet.hr, continuedSleep.hr);
      final quietResult = _segment(quiet);
      final continuedResult = _segment(continuedSleep);
      expect(quietResult.toJson(), continuedResult.toJson());
      expect(_windows(_detect(quiet)), _windows(_detect(continuedSleep)));
      final clearResult = _segment(clear);
      final expectedOnset = _captureStartSec + _sleepOnsetIndex + 171;
      expect(quietResult.window!.onsetMs! ~/ 1000, expectedOnset);
      expect(quietResult.window!.offsetMs! ~/ 1000, quiet.leaveBedSec - 171);
      expect(
        clearResult.window!.offsetMs! ~/ 1000,
        clear.confirmedWakeSec - 171,
      );
      expect(_detect(quiet).single.end, quiet.leaveBedSec - 171);
      expect(_detect(clear).single.end, clear.confirmedWakeSec - 171);

      for (final result in [quietResult, clearResult]) {
        expect(
          result.inBedSec,
          result.window!.offsetMs! ~/ 1000 - result.window!.onsetMs! ~/ 1000,
        );
        expect(result.tstSec, result.inBedSec);
        expect(result.wasoSec, 0);
        expect(result.unobservedSec, 0);
        expect(_segmentStages(result).keys.toSet(), {'light'});
      }

      final fixedWindowStages = AdvancedSleepStager.stageWindow(
        expectedOnset,
        _captureStartSec + 10 * 60 * 60,
        _gravity(clear),
        _heartRate(clear),
      );
      expect(
        _sessionStageOverlap(
          fixedWindowStages,
          clear.confirmedWakeSec,
          clear.leaveBedSec,
        ),
        {'light': minutes * 60},
        reason:
            'the current stage classifier labels this clear synthetic wake interval as light',
      );

      expect(quietResult.present, isTrue);
      expect(clearResult.present, isTrue);
    }
  });

  test('3B3 isolates motion and HR across all 15 wake profiles', () {
    const profiles =
        <
          ({
            String id,
            String name,
            _MovementProfile movement,
            _HrProfile heartRate,
          })
        >[
          (
            id: 'A',
            name: 'A sleep-like motion + sleep-like HR',
            movement: _MovementProfile.sleepLike,
            heartRate: _HrProfile.sleepLike,
          ),
          (
            id: 'B',
            name: 'B wake-like motion + sleep-like HR',
            movement: _MovementProfile.wakeLike,
            heartRate: _HrProfile.sleepLike,
          ),
          (
            id: 'C',
            name: 'C sleep-like motion + wake-like HR',
            movement: _MovementProfile.sleepLike,
            heartRate: _HrProfile.wakeLike,
          ),
          (
            id: 'D',
            name: 'D wake-like motion + wake-like HR',
            movement: _MovementProfile.wakeLike,
            heartRate: _HrProfile.wakeLike,
          ),
          (
            id: 'E',
            name: 'E mild motion + moderate HR increase',
            movement: _MovementProfile.mild,
            heartRate: _HrProfile.moderate,
          ),
        ];

    for (final minutes in [30, 60, 90]) {
      final byProfile = <String, _Fixture>{};
      for (final profile in profiles) {
        final fixture = _build(
          caseName: '${profile.name}, awake-in-bed=${minutes}m',
          awakeInBedMinutes: minutes,
          signal: _Signal.quiet,
          movementProfile: profile.movement,
          hrProfile: profile.heartRate,
        );
        byProfile[profile.id] = fixture;

        expect(fixture.accel, hasLength(_captureSeconds));
        expect(fixture.hr, hasLength(_captureSeconds));
        expect(fixture.accel.every((sample) => sample.valid), isTrue);
        expect(
          fixture.accel.every(
            (sample) =>
                sample.x.abs() <= 1.2 &&
                sample.y.abs() <= 1.2 &&
                sample.z.abs() <= 1.2,
          ),
          isTrue,
        );
        expect(
          fixture.hr.every((bpm) => bpm.isFinite && bpm > 0 && bpm < 200),
          isTrue,
        );
        expect(fixture.confirmedWakeSec, _captureStartSec + _finalWakeIndex);
        expect(
          fixture.leaveBedSec,
          _captureStartSec + _finalWakeIndex + minutes * 60,
        );

        final baseline = byProfile['A'];
        if (baseline != null) {
          expect(
            _samePreAwakeningMotion(fixture.accel, baseline.accel),
            isTrue,
            reason: '${profile.id} must share pre-awakening motion with A',
          );
          expect(
            _samePreAwakeningHeartRate(fixture.hr, baseline.hr),
            isTrue,
            reason: '${profile.id} must share pre-awakening HR with A',
          );
          switch (profile.id) {
            case 'B':
              expect(_sameHeartRate(fixture.hr, baseline.hr), isTrue);
              expect(_sameMotion(fixture.accel, baseline.accel), isFalse);
            case 'C':
              expect(_sameMotion(fixture.accel, baseline.accel), isTrue);
              expect(_sameHeartRate(fixture.hr, baseline.hr), isFalse);
            case 'D':
              final wakeMotion = byProfile['B']!;
              final wakeHeartRate = byProfile['C']!;
              expect(_sameMotion(fixture.accel, wakeMotion.accel), isTrue);
              expect(_sameHeartRate(fixture.hr, wakeHeartRate.hr), isTrue);
            case 'E':
              expect(profile.movement, _MovementProfile.mild);
              expect(profile.heartRate, _HrProfile.moderate);
          }
        }
        final observed = _observe(fixture);
        final expectedWindowPresent = profile.id != 'C' || minutes == 30;
        expect(observed.segmented.present, expectedWindowPresent);
        expect(
          observed.sessions,
          expectedWindowPresent ? hasLength(1) : isEmpty,
        );
        if (expectedWindowPresent) {
          final offsetMs = observed.segmented.window!.offsetMs!.toInt();
          final movementProfileEndsEarly =
              profile.id == 'B' || profile.id == 'D';
          expect(
            offsetMs < fixture.confirmedWakeSec * 1000,
            movementProfileEndsEarly,
          );
          expect(observed.awakeStageSeconds['wake'] ?? 0, 0);
        }
        if (profile.id == 'E' && minutes == 60) {
          expect(observed.segmented.wasoSec, greaterThan(0));
        }
        if (profile.id == 'E' && minutes == 90) {
          expect(observed.segmented.wasoSec, 0);
        }
        _printPrimaryResult(fixture, observed);
      }
    }
  });

  test(
    '3B3 reports movement-only, HR-only and combined nighttime arousals',
    () {
      const signals = <({String name, _ArousalSignal signal})>[
        (name: 'movement-only', signal: _ArousalSignal.movementOnly),
        (name: 'HR-only', signal: _ArousalSignal.hrOnly),
        (name: 'movement+HR', signal: _ArousalSignal.both),
      ];

      for (final durationSec in [30, 120, 300]) {
        for (final profile in signals) {
          final arousal = (
            startOffsetSec: 4 * 60 * 60, // 02:00 Lisbon, during the night
            durationSec: durationSec,
            signal: profile.signal,
          );
          final fixture = _build(
            caseName: '${profile.name}, duration=${durationSec}s',
            awakeInBedMinutes: 30,
            signal: _Signal.clear,
            movementProfile: _MovementProfile.wakeLike,
            hrProfile: _HrProfile.wakeLike,
            arousals: [arousal],
          );
          expect(fixture.accel, hasLength(_captureSeconds));
          expect(fixture.hr, hasLength(_captureSeconds));
          expect(fixture.accel.every((sample) => sample.valid), isTrue);
          expect(fixture.hr.every((bpm) => bpm > 0), isTrue);
          final observed = _observe(fixture);
          expect(observed.segmented.present, isTrue);
          expect(observed.sessions, hasLength(1));
          expect(
            observed.segmented.window!.offsetMs!.toInt(),
            lessThan(fixture.confirmedWakeSec * 1000),
          );
          if (durationSec == 300) {
            if (profile.signal == _ArousalSignal.movementOnly) {
              expect(observed.segmented.wasoSec, 0);
            } else {
              expect(observed.segmented.wasoSec, greaterThan(0));
            }
          }
          _printArousalResult(fixture, observed, arousal);
        }
      }
    },
  );
  test('synthetic Gen5/MG band envelope versus sensor-only path', () {
    for (final minutes in [30, 60, 90]) {
      final fixture = _build(
        caseName: 'GEN5/MG-model UP at wake ${minutes}m',
        awakeInBedMinutes: minutes,
        signal: _Signal.quiet,
      );
      final withoutBand = _segment(fixture);
      final withBand = _segment(
        fixture,
        bandSleepState: _gen5BandEnvelope(fixture),
      );
      _record(fixture);
      _record(fixture, banded: true);
      final trimmed = withBand.window!.offsetMs! ~/ 1000;
      // The synthetic envelope uses the existing Gen5/MG API contract; this is
      // not a claim that WHOOP Gen4 supplies the field.
      expect(withBand.bandOffsetTrimSec, isNotNull);
      expect(trimmed, fixture.confirmedWakeSec);
      expect(withBand.bandOffsetTrimSec, minutes * 60 - 171);
      expect(withoutBand.window!.offsetMs! ~/ 1000, fixture.leaveBedSec - 171);
      expect(withoutBand.bandOffsetTrimSec, isNull);
    }
  });
}
