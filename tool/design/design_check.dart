/// The rules of `.specify/DESIGN_SYSTEM.md` a machine can check, run on the
/// lines a pull request adds or changes under `lib/` (the "Design guide" CI
/// job). Older code that breaks them is the guide's §14 debt: it is reported
/// only once a pull request touches the line.
///
/// Pure: `tool/design_check.dart` collects the diff and the files.
///
/// It reads source, not an AST, so it only judges literal values: a size
/// computed from a token (`AppRadius.bubble - 4`, `base * 0.8`) is left to
/// review. Comments and string contents are blanked before any rule runs.
library;

/// Font sizes of the type scale (guide §3.2).
const fontSizes = <num>{10, 11, 12, 13, 14, 15, 17, 19, 22, 26, 38};

/// Corner radii (guide §4), plus 0 for a square corner.
const radii = <num>{0, 8, 12, 14, 16, 18, 24, 999};

/// The 2-pt spacing scale (DS-SPC-2), plus 0 and the 1-px hairline.
const spacing = <num>{0, 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32};

/// Icon sizes (DS-ICO-3).
const iconSizes = <num>{12, 14, 16, 18, 20, 22, 24, 32, 44, 48};

/// One break of a rule.
class Violation {
  const Violation({
    required this.path,
    required this.line,
    required this.rule,
    required this.message,
  });

  final String path;

  /// 1-based.
  final int line;

  /// The guide's rule ID, e.g. `DS-SPC-2`.
  final String rule;
  final String message;

  @override
  String toString() => '$path:$line: $rule $message';
}

/// Whether [path] is UI source the guide governs. `lib/core/` is where the
/// tokens are defined, so literals belong there; generated code is not
/// written by hand.
bool isChecked(String path) {
  if (!path.startsWith('lib/') || !path.endsWith('.dart')) return false;
  const skipped = ['lib/core/', 'lib/src/rust/', 'lib/l10n/'];
  if (skipped.any(path.startsWith)) return false;
  return !path.endsWith('.g.dart') && !path.endsWith('.freezed.dart');
}

/// The new-side line numbers each file gains in [diff], the output of
/// `git diff --unified=0`. Deleted files are left out.
Map<String, Set<int>> addedLines(String diff) {
  final result = <String, Set<int>>{};
  final hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@');
  Set<int>? current;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+++ ')) {
      final target = line.substring(4);
      current =
          target.startsWith('b/')
              ? result.putIfAbsent(target.substring(2), () => <int>{})
              : null;
      continue;
    }
    final m = hunk.firstMatch(line);
    if (m == null || current == null) continue;
    final start = int.parse(m[1]!);
    final count = m[2] == null ? 1 : int.parse(m[2]!);
    for (var i = 0; i < count; i++) {
      current.add(start + i);
    }
  }
  result.removeWhere((_, lines) => lines.isEmpty);
  return result;
}

/// The breaks in [source], the content of [path]. With [lines], only those
/// (1-based) lines are reported.
List<Violation> scan(String path, String source, {Set<int>? lines}) {
  final views = _mask(source);
  final code = views.code;
  final lineStarts = [
    0,
    for (var i = 0; i < source.length; i++)
      if (source.codeUnitAt(i) == 0x0A) i + 1,
  ];
  int lineOf(int offset) {
    var lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }

  final ignored = _ignores(source, code, lineStarts);
  final found = <Violation>[];
  void report(int offset, String rule, String message) {
    final line = lineOf(offset);
    if (lines != null && !lines.contains(line)) return;
    if (ignored[line]?.contains(rule) ?? false) return;
    found.add(Violation(path: path, line: line, rule: rule, message: message));
  }

  void checkLiterals(
    int from,
    int to,
    Set<num> allowed,
    String rule,
    String what,
  ) {
    for (final (value, offset) in _literals(code, from, to)) {
      if (!allowed.contains(value)) {
        report(
          offset,
          rule,
          '$what ${_fmt(value)} is not on the scale '
          '(${allowed.map(_fmt).join(', ')})',
        );
      }
    }
  }

  // DS-COL-1: no color literal outside lib/core/.
  for (final re in [
    RegExp(r'\bColor\s*\(\s*0[xX]'),
    RegExp(r'\bColor\.from(?:ARGB|RGBO)\s*\('),
    RegExp(r'(?<![\w$])Colors\.(?!transparent\b)[a-z]\w*'),
  ]) {
    for (final m in re.allMatches(code)) {
      report(
        m.start,
        'DS-COL-1',
        'color literal `${_snippet(code, m)}`: use a palette token from lib/core/',
      );
    }
  }

  // DS-TYP-1: families through AppFonts; 'monospace' for machine strings.
  for (final m in RegExp(
    r'''\bfontFamily\s*:\s*(['"])([^'"\n]*)\1''',
  ).allMatches(views.noComments)) {
    if (code.codeUnitAt(m.start) == 0x20 || m[2] == 'monospace') continue;
    report(
      m.start,
      'DS-TYP-1',
      "font family '${m[2]}' named as a string: use AppFonts.ui or AppFonts.figures",
    );
  }
  for (final m in RegExp(r'\bGoogleFonts\.').allMatches(code)) {
    report(
      m.start,
      'DS-TYP-1',
      'Google Fonts: the app bundles Outfit and Manrope (AppFonts)',
    );
  }

  // DS-TYP-4: literal font sizes on the scale.
  for (final m in RegExp(r'\bfontSize\s*:').allMatches(code)) {
    checkLiterals(
      m.end,
      _exprEnd(code, m.end),
      fontSizes,
      'DS-TYP-4',
      'font size',
    );
  }

  // DS-TYP-7: text scaling is never turned off or clamped.
  for (final m in RegExp(
    r'\bTextScaler\.noScaling\b|\bMediaQuery\.with(?:No|Clamped)TextScaling\b'
    r'|\b(?:textScaleFactor|maxScaleFactor)(?=\s*:)',
  ).allMatches(code)) {
    report(
      m.start,
      'DS-TYP-7',
      '`${m[0]}` turns off or clamps text scaling; let the layout wrap or scale down instead',
    );
  }
  // Replacing the scaler a subtree inherits overrides the user's setting,
  // whatever it is replaced with. Reading it (`TextPainter(textScaler:
  // MediaQuery.textScalerOf(c))`) is fine.
  for (final m in RegExp(
    r'(?:\.copyWith|\bMediaQueryData)\s*\(',
  ).allMatches(code)) {
    for (final (from, to) in _args(code, m.end - 1)) {
      final arg = code.substring(from, to);
      // `TextScaler.noScaling` is already reported above.
      if (RegExp(r'^\s*textScaler\s*:').hasMatch(arg) &&
          !arg.contains('TextScaler.noScaling')) {
        report(
          from + arg.indexOf('textScaler'),
          'DS-TYP-7',
          'replaces the inherited text scaler, overriding the user\'s text size',
        );
      }
    }
  }

  // DS-SHP-1: radii on the scale.
  for (final m in RegExp(
    r'\b(?:BorderRadius|Radius)\.circular\s*\(',
  ).allMatches(code)) {
    checkLiterals(m.end, _close(code, m.end - 1), radii, 'DS-SHP-1', 'radius');
  }

  // DS-SPC-2: paddings, gaps and spacing on the 2-pt scale.
  for (final m in RegExp(
    r'\bEdgeInsets(?:Directional)?\.(?:all|symmetric|only|fromLTRB|fromSTEB)\s*\(',
  ).allMatches(code)) {
    checkLiterals(
      m.end,
      _close(code, m.end - 1),
      spacing,
      'DS-SPC-2',
      'spacing',
    );
  }
  for (final m in RegExp(r'\bSizedBox\s*\(').allMatches(code)) {
    final args = _args(code, m.end - 1);
    // One side only: a gap. With a child, or both sides, it is a size.
    if (args.length != 1) continue;
    final (from, to) = args.single;
    final gap = RegExp(
      r'^\s*(?:height|width)\s*:',
    ).firstMatch(code.substring(from, to));
    if (gap == null) continue;
    checkLiterals(from + gap.end, to, spacing, 'DS-SPC-2', 'gap');
  }
  for (final m in RegExp(
    r'\b(?:spacing|runSpacing|mainAxisSpacing|crossAxisSpacing|gap)\s*:',
  ).allMatches(code)) {
    checkLiterals(m.end, _exprEnd(code, m.end), spacing, 'DS-SPC-2', 'spacing');
  }

  // DS-SPC-4: width thresholds through AppBreakpoints.
  for (final re in [
    RegExp(r'\b\w*[wW]idth\s*(?:<=|>=|<|>)\s*(\d+(?:\.\d+)?)\b'),
    RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)\s*(?:<=|>=|<|>)\s*[\w.()]*[wW]idth\b'),
  ]) {
    for (final m in re.allMatches(code)) {
      if (num.parse(m[1]!) == 0) continue;
      report(
        m.start,
        'DS-SPC-4',
        'width compared with ${m[1]}: use AppBreakpoints.tablet or AppBreakpoints.desktop',
      );
    }
  }

  // DS-ICO-3: icon sizes.
  for (final m in RegExp(r'\bIcon\s*\(').allMatches(code)) {
    for (final (from, to) in _args(code, m.end - 1)) {
      final size = RegExp(r'^\s*size\s*:').firstMatch(code.substring(from, to));
      if (size != null) {
        checkLiterals(from + size.end, to, iconSizes, 'DS-ICO-3', 'icon size');
      }
    }
  }
  for (final m in RegExp(r'\biconSize\s*:').allMatches(code)) {
    checkLiterals(
      m.end,
      _exprEnd(code, m.end),
      iconSizes,
      'DS-ICO-3',
      'icon size',
    );
  }

  found.sort(
    (a, b) => a.line != b.line ? a.line - b.line : a.rule.compareTo(b.rule),
  );
  return found;
}

/// The rules silenced per line by `// design-check: ignore DS-XXX-N — reason`.
/// A trailing comment silences its own line; a comment alone on its line
/// silences the next. Without a reason it silences nothing.
Map<int, Set<String>> _ignores(
  String source,
  String code,
  List<int> lineStarts,
) {
  final directive = RegExp(
    r'design-check:\s*ignore\s+(DS-[A-Z0-9]+-\d+)\s*(?:—|–|-|:)\s*\S',
  );
  final result = <int, Set<String>>{};
  for (var i = 0; i < lineStarts.length; i++) {
    final end = i + 1 < lineStarts.length ? lineStarts[i + 1] : source.length;
    final m = directive.firstMatch(source.substring(lineStarts[i], end));
    if (m == null) continue;
    final alone = code.substring(lineStarts[i], end).trim().isEmpty;
    result.putIfAbsent(alone ? i + 2 : i + 1, () => <String>{}).add(m[1]!);
  }
  return result;
}

/// Numeric literals in `code[from, to)` that stand alone: an operand of
/// arithmetic is a derived value and left to review.
Iterable<(num, int)> _literals(String code, int from, int to) sync* {
  final number = RegExp(r'(?<![\w.$])\d+(?:\.\d+)?(?![\w.])');
  for (final m in number.allMatches(code.substring(from, to))) {
    final start = from + m.start, end = from + m.end;
    var before = start - 1;
    while (before >= from && code[before].trim().isEmpty) {
      before--;
    }
    var after = end;
    while (after < to && code[after].trim().isEmpty) {
      after++;
    }
    const arithmetic = '+-*/%';
    if (before >= from && arithmetic.contains(code[before])) continue;
    if (after < to && arithmetic.contains(code[after])) continue;
    yield (num.parse(m[0]!), start);
  }
}

/// The index of the bracket that closes the one at [open], or the end of
/// [code] when it is unbalanced.
int _close(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return code.length;
}

/// Where the expression starting at [from] ends: the first `,`, `;` or
/// closing bracket outside any bracket it opens.
int _exprEnd(String code, int from) {
  var depth = 0;
  for (var i = from; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return i;
      depth--;
    } else if ((c == ',' || c == ';') && depth == 0) {
      return i;
    }
  }
  return code.length;
}

/// The top-level arguments of the call whose `(` is at [open], as ranges.
List<(int, int)> _args(String code, int open) {
  final close = _close(code, open);
  final result = <(int, int)>[];
  var start = open + 1;
  while (start < close) {
    final end = _exprEnd(code, start);
    final stop = end < close ? end : close;
    if (code.substring(start, stop).trim().isNotEmpty) {
      result.add((start, stop));
    }
    start = stop + 1;
  }
  return result;
}

/// [source] twice, with the same offsets: `noComments` with comments
/// blanked, and `code` with string contents blanked too. Newlines are kept.
({String code, String noComments}) _mask(String source) {
  final code = source.codeUnits.toList();
  final noComments = source.codeUnits.toList();
  const space = 0x20, newline = 0x0A;
  void blank(List<int> target, int from, int to) {
    for (var i = from; i < to && i < target.length; i++) {
      if (target[i] != newline) target[i] = space;
    }
  }

  final identifier = RegExp(r'[\w$]');
  bool isIdent(int i) => i >= 0 && identifier.hasMatch(source[i]);

  var i = 0;
  final n = source.length;
  while (i < n) {
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      final stop = end == -1 ? n : end;
      blank(code, i, stop);
      blank(noComments, i, stop);
      i = stop;
    } else if (source.startsWith('/*', i)) {
      var depth = 0, j = i;
      while (j < n) {
        if (source.startsWith('/*', j)) {
          depth++;
          j += 2;
        } else if (source.startsWith('*/', j)) {
          depth--;
          j += 2;
          if (depth == 0) break;
        } else {
          j++;
        }
      }
      blank(code, i, j);
      blank(noComments, i, j);
      i = j;
    } else {
      final raw =
          (source[i] == 'r' || source[i] == 'R') &&
          i + 1 < n &&
          (source[i + 1] == "'" || source[i + 1] == '"') &&
          !isIdent(i - 1);
      final q = raw ? i + 1 : i;
      if (source[q] != "'" && source[q] != '"') {
        i++;
        continue;
      }
      final quote = source[q];
      final delimiter = source.startsWith(quote * 3, q) ? quote * 3 : quote;
      final contentStart = q + delimiter.length;
      var j = contentStart;
      while (j < n) {
        if (!raw && source[j] == r'\') {
          j += 2;
          continue;
        }
        if (source.startsWith(delimiter, j)) break;
        if (delimiter.length == 1 && source[j] == '\n') break;
        j++;
      }
      blank(code, contentStart, j);
      i = j + (source.startsWith(delimiter, j) ? delimiter.length : 0);
    }
  }
  return (
    code: String.fromCharCodes(code),
    noComments: String.fromCharCodes(noComments),
  );
}

String _fmt(num value) =>
    value == value.truncate() ? value.truncate().toString() : value.toString();

/// The literal [m] starts, through its closing parenthesis when it has one.
String _snippet(String code, Match m) {
  final paren = code.indexOf('(', m.start);
  if (paren != -1 && paren < m.end) {
    return code.substring(m.start, _close(code, paren) + 1);
  }
  final end = RegExp(r'[^\w.]').firstMatch(code.substring(m.end))?.start ?? 0;
  return code.substring(m.start, m.end + end);
}
