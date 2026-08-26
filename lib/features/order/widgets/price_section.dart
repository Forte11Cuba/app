import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/automation/automation_id.dart';
import 'package:mostro/core/automation/automation_ids.dart';
import 'package:mostro/l10n/app_localizations.dart';

/// Whether Market or Fixed price mode is selected.
final isMarketPriceProvider = StateProvider<bool>((_) => true);

/// Premium slider value. Whole percent only (Mostro rounds the premium to an
/// integer). Default slider range is [-10%, +10%], but the input accepts (and
/// the slider expands to fit) values up to [-999%, +999%].
final premiumValueProvider = StateProvider<double>((_) => 0.0);

/// Default premium slider bound. The slider grows past this to fit a typed value.
const double kPremiumSliderDefault = 10.0;

/// Hard limit for a manually entered premium magnitude.
const double kPremiumMaxMagnitude = 999.0;

/// Fixed sats amount (only used in Fixed price mode).
final fixedSatsProvider = StateProvider<String>((_) => '');

/// Price type toggle + premium/fixed sats input.
class PriceSection extends ConsumerStatefulWidget {
  const PriceSection({super.key});

  @override
  ConsumerState<PriceSection> createState() => _PriceSectionState();
}

class _PriceSectionState extends ConsumerState<PriceSection> {
  late final TextEditingController _premiumController;
  bool _editingPremium = false;

  // Slider bounds captured when a drag starts and held until it ends, so the
  // scale does not shrink under the user's finger while dragging a value that
  // sits outside the default ±10% range back toward zero. Null when idle.
  double? _dragMin;
  double? _dragMax;

  @override
  void initState() {
    super.initState();
    _premiumController = TextEditingController(
      text: ref.read(premiumValueProvider).round().toString(),
    );
  }

  @override
  void dispose() {
    _premiumController.dispose();
    super.dispose();
  }

  void _syncControllerFromProvider(double? prev, double next) {
    if (_editingPremium) return;
    final newText = next.round().toString();
    if (_premiumController.text != newText) {
      _premiumController.text = newText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>();
    final green = colors?.mostroGreen ?? const Color(0xFF8CC63F);
    final purple = colors?.purpleButton ?? const Color(0xFF8359C2);
    final inputBg = colors?.backgroundInput ?? const Color(0xFF252A3A);
    final isMarket = ref.watch(isMarketPriceProvider);
    final premium = ref.watch(premiumValueProvider);
    final l10n = AppLocalizations.of(context);

    // Slider bounds default to ±10% but expand to fit a manually entered value.
    // While a drag is active the frozen bounds win, so the scale stays stable.
    final sliderMin = _dragMin ??
        (premium < -kPremiumSliderDefault ? premium : -kPremiumSliderDefault);
    final sliderMax = _dragMax ??
        (premium > kPremiumSliderDefault ? premium : kPremiumSliderDefault);
    // Whole-percent steps (Mostro rounds the premium to an integer).
    final sliderDivisions =
        (sliderMax - sliderMin).round().clamp(1, 2000);

    // Sync controller from provider via listener (not in build body).
    ref.listen<double>(premiumValueProvider, _syncControllerFromProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with toggle
        Row(
          children: [
            Text(l10n.priceTypeLabel, style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              isMarket ? l10n.priceTypeMarket : l10n.priceTypeFixed,
              style: TextStyle(
                color: colors?.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Switch(
              value: isMarket,
              activeThumbColor: green,
              onChanged: (v) =>
                  ref.read(isMarketPriceProvider.notifier).state = v,
            ).withAutomationId(AutomationIds.orderCreatePriceType),
            IconButton(
              onPressed: () => _showPriceInfo(context),
              icon: const Icon(Icons.info_outline, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: l10n.priceTypeInfoTooltip,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),

        if (isMarket) ...[
          // Premium slider with editable field
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: purple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.premiumSectionLabel,
                      style: TextStyle(
                        color: purple,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 60,
                          child: TextField(
                            controller: _premiumController,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            // Whole percent only: optional sign + up to 3
                            // digits. Blocks '.' / ',' so no decimals slip in.
                            inputFormatters: [
                              TextInputFormatter.withFunction(
                                (oldValue, newValue) {
                                  if (newValue.text.isEmpty) return newValue;
                                  return RegExp(r'^[+-]?\d{0,3}$')
                                          .hasMatch(newValue.text)
                                      ? newValue
                                      : oldValue;
                                },
                              ),
                            ],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: purple,
                              fontWeight: FontWeight.bold,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.xs,
                              ),
                              filled: true,
                              fillColor: purple.withValues(alpha: 0.1),
                              border: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.chip),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onTap: () =>
                                setState(() => _editingPremium = true),
                            onSubmitted: (v) {
                              setState(() => _editingPremium = false);
                              final parsed = int.tryParse(v);
                              if (parsed != null) {
                                ref.read(premiumValueProvider.notifier).state =
                                    parsed
                                        .clamp(
                                          -kPremiumMaxMagnitude.toInt(),
                                          kPremiumMaxMagnitude.toInt(),
                                        )
                                        .toDouble();
                              } else {
                                // Empty or lone sign ('-'/'+'): keep the current
                                // premium and restore the field text from it.
                                _syncControllerFromProvider(
                                  null,
                                  ref.read(premiumValueProvider),
                                );
                              }
                            },
                            onTapOutside: (_) {
                              setState(() => _editingPremium = false);
                              // Sync controller to current provider value.
                              _syncControllerFromProvider(
                                null,
                                ref.read(premiumValueProvider),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '%',
                          style: TextStyle(
                            color: purple,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Icon(Icons.edit, size: 14, color: purple),
                      ],
                    ),
                  ],
                ),
                Slider(
                  value: premium.clamp(sliderMin, sliderMax),
                  min: sliderMin,
                  max: sliderMax,
                  divisions: sliderDivisions,
                  activeColor: purple,
                  label: '${premium >= 0 ? '+' : ''}${premium.round()}%',
                  onChangeStart: (_) => setState(() {
                    _dragMin = sliderMin;
                    _dragMax = sliderMax;
                  }),
                  onChanged: (v) => ref
                      .read(premiumValueProvider.notifier)
                      .state = v.roundToDouble(),
                  onChangeEnd: (_) => setState(() {
                    _dragMin = null;
                    _dragMax = null;
                  }),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${sliderMin.round()}%',
                      style: TextStyle(
                        color: colors?.textSubtle,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '+${sliderMax.round()}%',
                      style: TextStyle(
                        color: colors?.textSubtle,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ] else ...[
          // Fixed sats input
          TextField(
            decoration: InputDecoration(
              hintText: l10n.amountInSatsHint,
              filled: true,
              fillColor: inputBg,
              suffixText: 'sats',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.input),
                borderSide: BorderSide.none,
              ),
            ),
            keyboardType: TextInputType.number,
            style: theme.textTheme.bodyLarge,
            onChanged: (v) =>
                ref.read(fixedSatsProvider.notifier).state = v,
          ).withAutomationId(AutomationIds.orderCreateSatsAmount),
        ],
      ],
    );
  }

  void _showPriceInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.of(context).priceTypesDialogTitle),
        content: Text(AppLocalizations.of(context).priceTypesDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
  }
}
