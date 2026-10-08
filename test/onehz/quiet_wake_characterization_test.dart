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
  bool continuedSleepTruth = false,
}) {
  final wakeSec = _captureStartSec + _finalWakeIndex;
  final leaveBedSec = wakeSec + awakeInBedMinutes * 60;
  final confirmedWakeSec = continuedSleepTruth ? leaveBedSec : wakeSec;
  final accel = <AccelSample>[];
  final hr = <double>[];

  for (var i = 0; i < _captureSeconds; i++) {
    final t = _captureStartSec + i;
    final beforeSleep = i < _sleepOnsetIndex;
    final asleepBySignal = i >= _sleepOnsetIndex && i < _finalWakeIndex;
    final inPostWakeInterval =
        i >= _finalWakeIndex && i < _finalWakeIndex + awakeInBedMinutes * 60;
    final sleepingLike =
        asleepBySignal || (inPostWakeInterval && signal == _Signal.quiet);
    final clearlyAwake =
        (inPostWakeInterval && signal == _Signal.clear) ||
        i >= _finalWakeIndex + awakeInBedMinutes * 60;

    final bpm = beforeSleep
        ? 74 + 2 * math.sin(i / 90.0)
        : (sleepingLike
              ? (i < _finalWakeIndex ? 52 : 57) + 1.5 * math.sin(i / 1800.0)
              : (clearlyAwake ? 86 : 72) + 2 * math.sin(i / 120.0));

    var ax = 0.02;
    var ay = 0.02;
    var az = 1.0;
    if (beforeSleep || clearlyAwake) {
      final phase = math.sin(i * 0.5);
      ax = 0.3 * phase;
      ay = 0.3;
      az = 0.9 * (1 - 0.2 * phase);
    } else if (inPostWakeInterval && signal == _Signal.quiet) {
      // A short, low-amplitude wrist adjustment every 15 minutes. HR remains
      // sleep-like. This is movement only; phone use is not a sensor input.
      final pulseSecond = (i - _finalWakeIndex) % 900;
      if (pulseSecond < 5) {
        ax = 0.02 + 0.025 * math.sin(pulseSecond * math.pi / 4);
        ay = 0.02;
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
