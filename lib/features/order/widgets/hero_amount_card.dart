import 'package:flutter/material.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/automation/automation_id.dart';
import 'package:mostro/features/order/widgets/order_detail_cards.dart';

/// The amount a screen is about (DS-CMP-23): a sentence-case label over the
/// figure, its unit on the figure's baseline, left-aligned on a card. The
/// take-order screen, the invoice screens and the bond screens all build it,
/// so the step that shows an amount looks the same wherever it falls.
class HeroAmountCard extends StatelessWidget {
  const HeroAmountCard({
    super.key,
    required this.label,
    required this.figure,
    required this.unit,
    this.semanticsLabel,
    this.automationId,
    this.automationLabel,
    this.second,
    this.footer,
    this.child,
    this.fit = true,
  });

  /// `You pay`, `To pay`: what the figure is, in sentence case.
  final String label;

  /// `1,000`, `500 – 2,500`, `252`.
  final String figure;

  /// `ARS`, `sats`.
  final String unit;

  /// Announces the figure and its unit as one label (`252 satoshis to pay`).
  final String? semanticsLabel;
  final String? automationId;
  final String? automationLabel;

  /// The amount traded for this one, stacked under a divider.
  final HeroAmountSecond? second;

  /// The context line closing the card ([HeroContextLine], or a line of
  /// the screen's own with a styled figure in it).
  final Widget? footer;

  /// A QR, under everything else in the same card.
  final Widget? child;

  /// Drops the figure from 38 to 26 when it does not fit at 38. That needs
  /// the card's width, which a card inside an `IntrinsicHeight` (the invoice
  /// screens) cannot measure; there a sats figure fits at 38 anyway, and one
  /// that would not wraps instead.
  final bool fit;

  static const double _full = 38;
  static const double _compact = 26;
  static const double _unitGap = 6;

  TextStyle _figureStyle(double size, Color color) => TextStyle(
    fontFamily: AppFonts.figures,
    fontSize: size,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02 * size,
    height: 1.1,
    color: color,
  );

  @override
  Widget build(BuildContext context) {
    final book = OrderBookPalette.of(context);
    final unitStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: book.textSecondary,
    );

    Widget row(double size) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(figure, style: _figureStyle(size, book.textPrimary)),
        ),
        const SizedBox(width: _unitGap),
        Text(unit, style: unitStyle),
      ],
    );

    Widget amount =
        fit
            ? LayoutBuilder(
              builder: (context, constraints) {
                final scaler = MediaQuery.textScalerOf(context);
                final direction = Directionality.of(context);
                double width(String text, TextStyle style) {
                  final painter = TextPainter(
                    text: TextSpan(text: text, style: style),
                    textDirection: direction,
                    textScaler: scaler,
                    maxLines: 1,
                  )..layout();
                  final w = painter.width;
                  painter.dispose();
                  return w;
                }

                final needed =
                    width(figure, _figureStyle(_full, book.textPrimary)) +
                    _unitGap +
                    width(unit, unitStyle);
                return row(needed <= constraints.maxWidth ? _full : _compact);
              },
            )
            : row(_full);
    final announced = semanticsLabel;
    if (announced != null) {
      amount = Semantics(
        label: announced,
        excludeSemantics: true,
        child: amount,
      );
    }
    final id = automationId;
    if (id != null) {
      amount = amount.withAutomationId(id, label: automationLabel);
    }

    final next = second;
    return OrderDetailCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroLabel(label),
          const SizedBox(height: 6),
          amount,
          if (next != null) ...[
            const SizedBox(height: 12),
            Divider(height: 1, thickness: 1, color: book.border),
            const SizedBox(height: 12),
            _HeroLabel(next.label),
            const SizedBox(height: 4),
            next.value,
          ],
          if (footer != null) ...[const SizedBox(height: 8), footer!],
          if (child != null) ...[
            const SizedBox(height: 14),
            Center(child: child),
          ],
        ],
      ),
    );
  }
}

/// The second amount of a hero: what the first is traded for.
class HeroAmountSecond {
  const HeroAmountSecond({required this.label, required this.value});

  /// `You receive`, in sentence case.
  final String label;

  /// Usually a [HeroSecondFigure].
  final Widget value;
}

/// `≈ 8,420 sats` under the first amount: [figure] at 19 in lime, the rest
/// of [sentence] (the unit, a `from`) at 13. The figure is found inside the
/// localized sentence, so each locale keeps its own word order.
class HeroSecondFigure extends StatelessWidget {
  const HeroSecondFigure({
    super.key,
    required this.sentence,
    required this.figure,
  });

  final String sentence;
  final String figure;

  @override
  Widget build(BuildContext context) {
    final book = OrderBookPalette.of(context);
    return Text.rich(
      TextSpan(
        children: figureSpans(
          sentence,
          figure,
          TextStyle(
            fontFamily: AppFonts.figures,
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: book.limeInk,
          ),
        ),
      ),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: book.textSecondary,
      ),
    );
  }
}

/// A plain context line closing a hero: `≈ 312 ARS · Bitcoin Bolivia`.
class HeroContextLine extends StatelessWidget {
  const HeroContextLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: OrderBookPalette.of(context).textSecondary,
      ),
    );
  }
}

class _HeroLabel extends StatelessWidget {
  const _HeroLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: OrderBookPalette.of(context).textSecondary,
      ),
    );
  }
}
