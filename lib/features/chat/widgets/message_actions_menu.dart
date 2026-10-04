import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mostro/core/order_book_palette.dart';
import 'package:mostro/l10n/app_localizations.dart';

/// How long a chat message is held before its menu opens.
const messageMenuHoldDuration = Duration(seconds: 1);

/// What the user picked in a message's menu.
enum MessageAction { copy }

/// Where a message is on screen, in global coordinates, or null once it is
/// gone (scrolled out of a list and disposed).
typedef MessageAnchor = Rect? Function();

/// Opens the menu of the chat message drawn by [bubble], which [anchor]
/// locates, and resolves to the action picked, or null when the user
/// dismissed it.
///
/// The message stays lit above the scrim and the menu opens under it, or
/// above it when there is no room below. Both follow the message when it
/// moves — a new message scrolls the chat, the keyboard closes, the screen
/// turns — and the menu closes if it disappears. [alignEnd] lines the menu
/// up with the message's side: the right for one's own, the left for the
/// counterpart's.
Future<MessageAction?> showMessageActionsMenu({
  required BuildContext context,
  required MessageAnchor anchor,
  required Widget bubble,
  required bool alignEnd,
}) async {
  final bubbleRect = anchor();
  if (bubbleRect == null) return null;
  final book = OrderBookPalette.of(context);
  // Root navigator: the route places the message by global coordinates, so
  // its overlay must cover the whole screen.
  return Navigator.of(context, rootNavigator: true).push(
    _MessageActionsRoute(
      anchor: anchor,
      bubbleRect: bubbleRect,
      bubble: bubble,
      alignEnd: alignEnd,
      scrim: book.scrim,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      animate: !MediaQuery.disableAnimationsOf(context),
    ),
  );
}

class _MessageActionsRoute extends PopupRoute<MessageAction> {
  _MessageActionsRoute({
    required this.anchor,
    required this.bubbleRect,
    required this.bubble,
    required this.alignEnd,
    required this.scrim,
    required this.barrierLabel,
    required this.animate,
  });

  final MessageAnchor anchor;

  /// Where the message was when the menu opened.
  final Rect bubbleRect;
  final Widget bubble;
  final bool alignEnd;
  final Color scrim;
  final bool animate;

  @override
  final String barrierLabel;

  @override
  Color get barrierColor => scrim;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration =>
      animate ? const Duration(milliseconds: 200) : Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _FollowAnchor(
      anchor: anchor,
      initial: bubbleRect,
      builder: (context, rect) => Stack(
        children: [
          // Taps on the message fall through to the barrier and close the
          // menu; a screen reader already reads the original underneath.
          Positioned.fromRect(
            rect: rect,
            child: IgnorePointer(child: ExcludeSemantics(child: bubble)),
          ),
          CustomSingleChildLayout(
            delegate: _MenuPosition(
              bubbleRect: rect,
              alignEnd: alignEnd,
              safeArea: MediaQuery.paddingOf(context),
            ),
            child: const _ActionsCard(),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

/// Rebuilds the menu where the message is after every frame that moved it,
/// and closes the menu once the message is gone.
///
/// Checking after each frame costs one rectangle comparison and schedules
/// nothing: a still screen draws no frame, so the check waits with it.
class _FollowAnchor extends StatefulWidget {
  const _FollowAnchor({
    required this.anchor,
    required this.initial,
    required this.builder,
  });

  final MessageAnchor anchor;
  final Rect initial;
  final Widget Function(BuildContext context, Rect rect) builder;

  @override
  State<_FollowAnchor> createState() => _FollowAnchorState();
}

class _FollowAnchorState extends State<_FollowAnchor> {
  late Rect _rect = widget.initial;

  @override
  void initState() {
    super.initState();
    _checkAfterFrame();
  }

  void _checkAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rect = widget.anchor();
      if (rect == null) {
        Navigator.of(context).maybePop();
        return;
      }
      if (rect != _rect) setState(() => _rect = rect);
      _checkAfterFrame();
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _rect);
}

/// Places the menu under the message, or above it when it does not fit,
/// kept inside the safe area, cutouts on the sides included, with [_margin]
/// to spare.
class _MenuPosition extends SingleChildLayoutDelegate {
  const _MenuPosition({
    required this.bubbleRect,
    required this.alignEnd,
    required this.safeArea,
  });

  final Rect bubbleRect;
  final bool alignEnd;
  final EdgeInsets safeArea;

  static const double _margin = 16;
  static const double _gap = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(
      Size(
        math.max(0, constraints.maxWidth - safeArea.horizontal - 2 * _margin),
        math.max(0, constraints.maxHeight - safeArea.vertical - 2 * _margin),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = safeArea.top + _margin;
    final bottom = size.height - safeArea.bottom - _margin;

    final below = bubbleRect.bottom + _gap;
    final above = bubbleRect.top - _gap - childSize.height;
    final y = below + childSize.height <= bottom ? below : above;

    final left = safeArea.left + _margin;
    final right = size.width - safeArea.right - _margin;
    final x = alignEnd ? bubbleRect.right - childSize.width : bubbleRect.left;
    return Offset(
      _clamp(x, left, right - childSize.width),
      _clamp(y, top, bottom - childSize.height),
    );
  }

  /// [value] within [min]..[max], [min] winning when they cross.
  static double _clamp(double value, double min, double max) =>
      math.max(min, math.min(value, max));

  @override
  bool shouldRelayout(_MenuPosition oldDelegate) =>
      bubbleRect != oldDelegate.bubbleRect ||
      alignEnd != oldDelegate.alignEnd ||
      safeArea != oldDelegate.safeArea;
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard();

  @override
  Widget build(BuildContext context) {
    final book = OrderBookPalette.of(context);
    final l10n = AppLocalizations.of(context);
    return Material(
      color: book.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: book.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 200),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ActionItem(
                icon: Icons.copy_rounded,
                label: l10n.copyButtonLabel,
                onTap: () => Navigator.of(context).pop(MessageAction.copy),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final book = OrderBookPalette.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: book.textBody),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: book.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
