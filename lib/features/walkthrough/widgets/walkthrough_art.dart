import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:mostro/features/walkthrough/walkthrough_slides.dart';

/// A walkthrough illustration: a dark disc with a gold ring, on a lime halo.
///
/// Every layer is a static SVG (flutter_svg runs no CSS animation), and the
/// motion of the handoff is played here: the ring draws itself, the slide's
/// drawing fades in, then a glint keeps running around the ring. With
/// animations disabled the art shows complete and nothing loops (DS-MOT-3).
///
/// Give each slide its own key, so a new slide replays the entrance.
class WalkthroughArt extends StatefulWidget {
  const WalkthroughArt({super.key, required this.asset, required this.size});

  /// The slide's drawing, laid over the disc.
  final String asset;

  /// Diameter of the disc's box; the halo spreads beyond it.
  final double size;

  static const _glow = '$walkthroughArtDir/glow.svg';
  static const _disc = '$walkthroughArtDir/disc.svg';
  static const _ring = '$walkthroughArtDir/ring.svg';
  static const _glint = '$walkthroughArtDir/glint.svg';

  /// The layers every slide shares.
  static const frameAssets = [_glow, _disc, _ring, _glint];

  /// The halo's diameter relative to the disc's box (224 to 184 in the
  /// handoff).
  static const glowScale = 224 / 184;

  @override
  State<WalkthroughArt> createState() => _WalkthroughArtState();
}

// The handoff's timing: the ring draws in 900 ms, the drawing pops in over
// 500 ms from 250 ms, and the glint circles once every 4.2 s, visible for the
// first 42% of each cycle.
const _entranceDuration = Duration(milliseconds: 1150);
const _glintPeriod = Duration(milliseconds: 4200);
const _ringEnd = 900 / 1150;
const _popStart = 250 / 1150;
const _popEnd = 750 / 1150;
const _glintTravel = 0.42;
const _glintFadeIn = 0.04;
const _glintFadeOut = 0.38;
const _popFromScale = 0.92;

class _WalkthroughArtState extends State<WalkthroughArt>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: _entranceDuration,
  )..addStatusListener(_startGlint);
  late final AnimationController _glint = AnimationController(
    vsync: this,
    duration: _glintPeriod,
  );
  late final Animation<double> _ring = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0, _ringEnd, curve: Cubic(0.6, 0.1, 0.2, 1)),
  );
  late final Animation<double> _pop = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(_popStart, _popEnd, curve: Curves.easeOut),
  );
  late final Animation<double> _popScale = Tween<double>(
    begin: _popFromScale,
    end: 1,
  ).animate(_pop);

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      _glint.stop();
      _entrance.value = 1;
    } else if (!_started) {
      _entrance.forward();
    } else if (_entrance.isCompleted && !_glint.isAnimating) {
      // Animations turned back on after the entrance: resume the loop.
      _glint.repeat();
    }
    _started = true;
  }

  void _startGlint(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _glint.repeat();
  }

  @override
  void dispose() {
    _entrance.dispose();
    _glint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final glowSize = size * WalkthroughArt.glowScale;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: glowSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SvgPicture.asset(
              WalkthroughArt._glow,
              width: glowSize,
              height: glowSize,
            ),
            SizedBox.square(
              dimension: size,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SvgPicture.asset(WalkthroughArt._disc),
                  AnimatedBuilder(
                    animation: _ring,
                    builder:
                        (_, ring) => ClipPath(
                          clipper: _SweepClipper(_ring.value),
                          child: ring,
                        ),
                    child: SvgPicture.asset(WalkthroughArt._ring),
                  ),
                  // The glint repaints every frame of its loop: keep that
                  // to its own layer.
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _glint,
                      builder: _buildGlint,
                      child: SvgPicture.asset(WalkthroughArt._glint),
                    ),
                  ),
                  FadeTransition(
                    opacity: _pop,
                    child: ScaleTransition(
                      scale: _popScale,
                      child: SvgPicture.asset(widget.asset),
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

  Widget _buildGlint(BuildContext context, Widget? glint) {
    final t = _glint.value;
    if (!_glint.isAnimating || t >= _glintTravel) return const SizedBox();
    final opacity =
        t < _glintFadeIn
            ? t / _glintFadeIn
            : t > _glintFadeOut
            ? (_glintTravel - t) / (_glintTravel - _glintFadeOut)
            : 1.0;
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.rotate(
        angle: 2 * math.pi * t / _glintTravel,
        child: glint,
      ),
    );
  }
}

/// Clips to a sector that opens clockwise from 12 o'clock, [progress] of a
/// full turn: drawn over the ring, it makes the ring draw itself.
class _SweepClipper extends CustomClipper<Path> {
  const _SweepClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final box = Offset.zero & size;
    if (progress >= 1) return Path()..addRect(box);
    final center = box.center;
    // A circle around the box, so the sector covers its corners too.
    final radius = size.longestSide;
    return Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
      )
      ..close();
  }

  @override
  bool shouldReclip(_SweepClipper old) => old.progress != progress;
}
