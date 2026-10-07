import 'package:flutter/material.dart';

import 'package:mostro/l10n/app_localizations.dart';

/// Deterministic pseudonymous avatar derived from a Nostr public key.
///
/// Renders a colored circle background (HSV hue from [colorHue]) with the
/// animal of [pseudonym] drawn in white. A pseudonym that names no animal (a
/// fallback such as `Trader 1a2b3c`) falls back to the icon of [iconIndex]
/// (0–36).
///
/// **Rendering contract (FR-011c)**: The icon is ALWAYS white regardless of
/// the hue value — v1 had a bug where the icon color matched the background,
/// making it invisible.
class NymAvatar extends StatelessWidget {
  const NymAvatar({
    super.key,
    required this.pseudonym,
    required this.iconIndex,
    required this.colorHue,
    this.size = 40,
  }) : assert(iconIndex >= 0 && iconIndex <= 36, 'iconIndex must be 0–36'),
       assert(colorHue >= 0 && colorHue <= 359, 'colorHue must be 0–359');

  /// The pseudonym, `adjective-animal` (NymIdentity.pseudonym).
  final String pseudonym;

  /// Fallback icon selector (0–36), derived from NymIdentity.icon_index.
  final int iconIndex;

  /// HSV hue (0–359) for the avatar background circle.
  final int colorHue;

  /// Diameter of the avatar circle.
  final double size;

  @override
  Widget build(BuildContext context) {
    final bgColor =
        HSVColor.fromAHSV(1.0, colorHue.toDouble(), 0.65, 0.70).toColor();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
      child: Center(
        child: Icon(
          nymAnimalIcon(pseudonym) ?? _kNymIcons[iconIndex],
          // Icon is ALWAYS white — FR-011c rendering contract.
          color: Colors.white,
          size: size * 0.55,
          semanticLabel: AppLocalizations.of(context).avatarIconLabel,
        ),
      ),
    );
  }
}

/// 37 icon entries (index 0–36). Must not be reordered — the mapping is
/// derived deterministically from public keys.
const List<IconData> _kNymIcons = [
  Icons.pets, // 0
  Icons.forest, // 1
  Icons.waves, // 2
  Icons.bolt, // 3
  Icons.wb_sunny_outlined, // 4
  Icons.nightlight_round, // 5
  Icons.star_border, // 6
  Icons.diamond_outlined, // 7
  Icons.sailing, // 8
  Icons.terrain, // 9
  Icons.local_fire_department, // 10
  Icons.ac_unit, // 11
  Icons.spa, // 12
  Icons.rocket_launch, // 13
  Icons.anchor, // 14
  Icons.whatshot, // 15
  Icons.filter_vintage, // 16
  Icons.emoji_nature, // 17
  Icons.catching_pokemon, // 18
  Icons.cruelty_free, // 19
  Icons.brightness_5, // 20
  Icons.cloud_outlined, // 21
  Icons.water_drop, // 22
  Icons.local_florist, // 23
  Icons.eco, // 24
  Icons.dark_mode_outlined, // 25
  Icons.lens_blur, // 26
  Icons.tornado, // 27
  Icons.thunderstorm_outlined, // 28
  Icons.flare, // 29
  Icons.ac_unit_outlined, // 30
  Icons.circle_outlined, // 31
  Icons.hexagon_outlined, // 32
  Icons.pentagon_outlined, // 33
  Icons.change_history, // 34
  Icons.grade, // 35
  Icons.auto_awesome, // 36
];

/// The animals of `NOUNS` in `rust/src/crypto/nym.rs`, in its order: the
/// animal at index `i` is glyph U+E000 + `i` of the NymAnimals font, which
/// `tool/nym_animals/build_font.py` builds from `tool/nym_animals/svg/`.
const List<String> kNymAnimals = [
  'ant',
  'bird',
  'cat',
  'deer',
  'elk',
  'fox',
  'goat',
  'parrot',
  'flamingo',
  'peacock',
  'dove',
  'leopard',
  'butterfly',
  'turtle',
  'owl',
  'shark',
  'chicken',
  'bat',
  'seal',
  'tiger',
  'ram',
  'mouse',
  'wolf',
  'ox',
  'bear',
  'crab',
  'duck',
  'eagle',
  'frog',
  'zebra',
  'swan',
  'giraffe',
  'dog',
  'koala',
  'lion',
  'otter',
  'whale',
  'horse',
  'kangaroo',
  'penguin',
  'sloth',
  'pig',
  'viper',
  'octopus',
  'chipmunk',
  'skunk',
  'bison',
  'goose',
  'camel',
  'turkey',
  'hedgehog',
  'gecko',
  'hippo',
  'crocodile',
  'elephant',
  'fish',
  'monkey',
  'beaver',
  'dolphin',
  'llama',
  'panda',
  'rabbit',
  'badger',
  'cow',
];

const _kAnimalFont = 'NymAnimals';

/// One glyph per entry of [kNymAnimals], in the same order. Constant, so a
/// release build can still tree-shake the font.
const List<IconData> _kAnimalIcons = [
  IconData(0xE000, fontFamily: _kAnimalFont), // ant
  IconData(0xE001, fontFamily: _kAnimalFont), // bird
  IconData(0xE002, fontFamily: _kAnimalFont), // cat
  IconData(0xE003, fontFamily: _kAnimalFont), // deer
  IconData(0xE004, fontFamily: _kAnimalFont), // elk
  IconData(0xE005, fontFamily: _kAnimalFont), // fox
  IconData(0xE006, fontFamily: _kAnimalFont), // goat
  IconData(0xE007, fontFamily: _kAnimalFont), // parrot
  IconData(0xE008, fontFamily: _kAnimalFont), // flamingo
  IconData(0xE009, fontFamily: _kAnimalFont), // peacock
  IconData(0xE00A, fontFamily: _kAnimalFont), // dove
  IconData(0xE00B, fontFamily: _kAnimalFont), // leopard
  IconData(0xE00C, fontFamily: _kAnimalFont), // butterfly
  IconData(0xE00D, fontFamily: _kAnimalFont), // turtle
  IconData(0xE00E, fontFamily: _kAnimalFont), // owl
  IconData(0xE00F, fontFamily: _kAnimalFont), // shark
  IconData(0xE010, fontFamily: _kAnimalFont), // chicken
  IconData(0xE011, fontFamily: _kAnimalFont), // bat
  IconData(0xE012, fontFamily: _kAnimalFont), // seal
  IconData(0xE013, fontFamily: _kAnimalFont), // tiger
  IconData(0xE014, fontFamily: _kAnimalFont), // ram
  IconData(0xE015, fontFamily: _kAnimalFont), // mouse
  IconData(0xE016, fontFamily: _kAnimalFont), // wolf
  IconData(0xE017, fontFamily: _kAnimalFont), // ox
  IconData(0xE018, fontFamily: _kAnimalFont), // bear
  IconData(0xE019, fontFamily: _kAnimalFont), // crab
  IconData(0xE01A, fontFamily: _kAnimalFont), // duck
  IconData(0xE01B, fontFamily: _kAnimalFont), // eagle
  IconData(0xE01C, fontFamily: _kAnimalFont), // frog
  IconData(0xE01D, fontFamily: _kAnimalFont), // zebra
  IconData(0xE01E, fontFamily: _kAnimalFont), // swan
  IconData(0xE01F, fontFamily: _kAnimalFont), // giraffe
  IconData(0xE020, fontFamily: _kAnimalFont), // dog
  IconData(0xE021, fontFamily: _kAnimalFont), // koala
  IconData(0xE022, fontFamily: _kAnimalFont), // lion
  IconData(0xE023, fontFamily: _kAnimalFont), // otter
  IconData(0xE024, fontFamily: _kAnimalFont), // whale
  IconData(0xE025, fontFamily: _kAnimalFont), // horse
  IconData(0xE026, fontFamily: _kAnimalFont), // kangaroo
  IconData(0xE027, fontFamily: _kAnimalFont), // penguin
  IconData(0xE028, fontFamily: _kAnimalFont), // sloth
  IconData(0xE029, fontFamily: _kAnimalFont), // pig
  IconData(0xE02A, fontFamily: _kAnimalFont), // viper
  IconData(0xE02B, fontFamily: _kAnimalFont), // octopus
  IconData(0xE02C, fontFamily: _kAnimalFont), // chipmunk
  IconData(0xE02D, fontFamily: _kAnimalFont), // skunk
  IconData(0xE02E, fontFamily: _kAnimalFont), // bison
  IconData(0xE02F, fontFamily: _kAnimalFont), // goose
  IconData(0xE030, fontFamily: _kAnimalFont), // camel
  IconData(0xE031, fontFamily: _kAnimalFont), // turkey
  IconData(0xE032, fontFamily: _kAnimalFont), // hedgehog
  IconData(0xE033, fontFamily: _kAnimalFont), // gecko
  IconData(0xE034, fontFamily: _kAnimalFont), // hippo
  IconData(0xE035, fontFamily: _kAnimalFont), // crocodile
  IconData(0xE036, fontFamily: _kAnimalFont), // elephant
  IconData(0xE037, fontFamily: _kAnimalFont), // fish
  IconData(0xE038, fontFamily: _kAnimalFont), // monkey
  IconData(0xE039, fontFamily: _kAnimalFont), // beaver
  IconData(0xE03A, fontFamily: _kAnimalFont), // dolphin
  IconData(0xE03B, fontFamily: _kAnimalFont), // llama
  IconData(0xE03C, fontFamily: _kAnimalFont), // panda
  IconData(0xE03D, fontFamily: _kAnimalFont), // rabbit
  IconData(0xE03E, fontFamily: _kAnimalFont), // badger
  IconData(0xE03F, fontFamily: _kAnimalFont), // cow
];

/// The drawing of the animal [pseudonym] ends with (`lazy-fox` → the fox),
/// or null when its last word names no animal.
IconData? nymAnimalIcon(String pseudonym) {
  final index = kNymAnimals.indexOf(pseudonym.split('-').last);
  return index < 0 ? null : _kAnimalIcons[index];
}
