import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Состояние визуализатора — по аналогии с LiveKit (agent state).
/// listening/speaking реагируют на входной звук, thinking/idle — авто-анимация.
enum LkVisualizerState { idle, listening, speaking, thinking }

/// Bar-визуализатор в стиле LiveKit `SoundWaveformWidget`, но полностью
/// отвязанный от WebRTC/LiveKit-комнаты. Работает офлайн и на десктопе.
///
/// Кормится своими данными:
///  - [levels]  — пер-бар магнитуды 0..1 (например, из FFT/спектра);
///  - [level]   — одиночный RMS-уровень 0..1 (распределяется «колоколом»).
/// Если задан [levels], [level] игнорируется.
class LkBarVisualizer extends StatefulWidget {
  const LkBarVisualizer({
    super.key,
    this.levels,
    this.level,
    this.state = LkVisualizerState.listening,
    this.count = 7,
    this.barWidth = 12,
    this.minHeight = 12,
    this.maxHeight = 120,
    this.spacing = 8,
    this.color = const Color(0xFF7C4DFF),
    this.borderRadius,
    this.attack = 0.45,
    this.decay = 0.16,
    this.centerWeighted = true,
    this.minOpacity = 0.35,
  });

  /// Пер-бар магнитуды 0..1. Если длина != [count] — линейно ресемплится.
  final List<double>? levels;

  /// Одиночный уровень 0..1 (RMS). Используется, если [levels] == null.
  final double? level;

  final LkVisualizerState state;

  /// Кол-во баров (LiveKit `count`).
  final int count;

  /// Ширина бара (LiveKit `width`).
  final double barWidth;

  /// Высота «тихого» бара (LiveKit `minHeight`).
  final double minHeight;

  /// Высота бара на максимуме (LiveKit `maxHeight`).
  final double maxHeight;

  /// Зазор между барами.
  final double spacing;

  final Color color;

  /// Скругление. По умолчанию barWidth/2 → форма «стадиона».
  final double? borderRadius;

  /// Сглаживание нарастания (0..1, больше = быстрее реакция).
  final double attack;

  /// Сглаживание спада (обычно меньше attack — как у реальных VU-метров).
  final double decay;

  /// Распределять одиночный [level] «колоколом» (центр выше краёв).
  final bool centerWeighted;

  /// Минимальная непрозрачность тихого бара.
  final double minOpacity;

  @override
  State<LkBarVisualizer> createState() => _LkBarVisualizerState();
}

class _LkBarVisualizerState extends State<LkBarVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late List<double> _current; // сглаженные высоты 0..1
  late List<double> _target; // целевые высоты 0..1
  double _phase = 0; // фаза авто-анимации (idle/thinking)

  @override
  void initState() {
    super.initState();
    _current = List<double>.filled(widget.count, 0);
    _target = List<double>.filled(widget.count, 0);
    _recomputeTarget();
    // Длительность неважна: контроллер служит покадровым тикером,
    // repaint идёт каждый кадр → плавно на 120/144 Гц.
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat()
      ..addListener(_tick);
  }

  void _tick() {
    _phase += 0.05;
    _recomputeTarget();
    for (var i = 0; i < widget.count; i++) {
      final t = _target[i];
      final k = t > _current[i] ? widget.attack : widget.decay;
      _current[i] += (t - _current[i]) * k;
    }
    // setState не нужен: painter перерисовывается через repaint: _controller.
  }

  void _recomputeTarget() {
    final n = widget.count;
    switch (widget.state) {
      case LkVisualizerState.thinking:
        // Бегущая волна — «загрузка/думает».
        for (var i = 0; i < n; i++) {
          _target[i] = 0.25 + 0.5 * (0.5 + 0.5 * math.sin(_phase * 3 - i * 0.9));
        }
        break;
      case LkVisualizerState.idle:
        // Едва заметное «дыхание».
        for (var i = 0; i < n; i++) {
          _target[i] = 0.06 + 0.05 * (0.5 + 0.5 * math.sin(_phase + i * 0.6));
        }
        break;
      case LkVisualizerState.listening:
      case LkVisualizerState.speaking:
        final bands = _resolveBands(n);
        for (var i = 0; i < n; i++) {
          _target[i] = bands[i].clamp(0.0, 1.0);
        }
        break;
    }
  }

  List<double> _resolveBands(int n) {
    final lv = widget.levels;
    if (lv != null && lv.isNotEmpty) {
      return _resample(lv, n);
    }
    final level = (widget.level ?? 0).clamp(0.0, 1.0);
    if (!widget.centerWeighted) return List<double>.filled(n, level);

    final out = List<double>.filled(n, 0);
    final center = (n - 1) / 2;
    for (var i = 0; i < n; i++) {
      final d = center == 0 ? 0.0 : (i - center).abs() / center; // 0..1
      final w = math.cos(d * math.pi / 2); // 1 в центре → 0 по краям
      out[i] = level * (0.35 + 0.65 * w);
    }
    return out;
  }

  List<double> _resample(List<double> src, int n) {
    if (src.length == n) return List<double>.from(src);
    final out = List<double>.filled(n, 0);
    final denom = (n - 1) == 0 ? 1 : (n - 1);
    for (var i = 0; i < n; i++) {
      final pos = i * (src.length - 1) / denom;
      final lo = pos.floor();
      final hi = math.min(lo + 1, src.length - 1);
      final f = pos - lo;
      out[i] = src[lo] * (1 - f) + src[hi] * f;
    }
    return out;
  }

  @override
  void didUpdateWidget(covariant LkBarVisualizer old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count) {
      _current = List<double>.filled(widget.count, 0);
      _target = List<double>.filled(widget.count, 0);
    }
    _recomputeTarget();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalW =
        widget.count * widget.barWidth + (widget.count - 1) * widget.spacing;
    return SizedBox(
      width: totalW,
      height: widget.maxHeight,
      child: CustomPaint(
        painter: _BarPainter(
          repaint: _controller,
          heights: _current,
          barWidth: widget.barWidth,
          spacing: widget.spacing,
          minHeight: widget.minHeight,
          maxHeight: widget.maxHeight,
          color: widget.color,
          radius: widget.borderRadius ?? widget.barWidth / 2,
          minOpacity: widget.minOpacity,
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required Listenable repaint,
    required this.heights,
    required this.barWidth,
    required this.spacing,
    required this.minHeight,
    required this.maxHeight,
    required this.color,
    required this.radius,
    required this.minOpacity,
  }) : super(repaint: repaint);

  final List<double> heights;
  final double barWidth;
  final double spacing;
  final double minHeight;
  final double maxHeight;
  final Color color;
  final double radius;
  final double minOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;
    final cy = size.height / 2;
    for (var i = 0; i < heights.length; i++) {
      final level = heights[i].clamp(0.0, 1.0);
      final h = minHeight + (maxHeight - minHeight) * level;
      final x = i * (barWidth + spacing);
      // Тихие бары чуть прозрачнее — как в LiveKit. withAlpha не deprecated.
      final a = ((minOpacity + (1 - minOpacity) * level) * 255).round();
      paint.color = color.withAlpha(a);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, cy - h / 2, barWidth, h),
        Radius.circular(radius),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => true;
}

/// Утилита: RMS-уровень 0..1 из PCM16 (моно).
/// Прокидывай результат в `LkBarVisualizer(level: ...)`.
/// [gain] подбери под свой микрофон (Fifine обычно 1.5–2.5).
double computeRmsLevel(List<int> pcm16, {double gain = 1.8}) {
  if (pcm16.isEmpty) return 0;
  var sum = 0.0;
  for (final s in pcm16) {
    final v = s / 32768.0;
    sum += v * v;
  }
  final rms = math.sqrt(sum / pcm16.length);
  return (rms * gain).clamp(0.0, 1.0);
}
