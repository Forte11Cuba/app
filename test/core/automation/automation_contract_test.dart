import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/core/automation/automation_id.dart';
import 'package:mostro/core/automation/automation_ids.dart';
import 'package:mostro/core/test_environment.dart';
import 'package:mostro/features/trades/screens/trade_detail_screen.dart'
    show TradeStatus, TradeStatusMachineName;
import 'package:mostro/shared/widgets/test_environment_banner.dart';

/// Guards the Mortsom automation contract (`docs/automation-contract.md`).
///
/// The contract's failure mode is silent rot: an identifier keeps existing as
/// a constant while the control it named is renamed, removed, or rebuilt
/// without it. A harness then waits for an element the app never renders and
/// times out with no way to say why. These tests make that a build failure.
void main() {
  group('the identifier registry', () {
    test('every identifier is unique, dotted and free of whitespace', () {
      final seen = <String>{};
      for (final id in _declaredIdentifiers()) {
        expect(seen.add(id), isTrue, reason: 'duplicate identifier $id');
        expect(id, contains('.'), reason: '$id is not namespaced');
        expect(id, isNot(contains(' ')), reason: '$id contains whitespace');
        expect(id, equals(id.trim()));
      }
      expect(seen, hasLength(greaterThan(40)),
          reason: 'the parser found almost nothing — has the file moved?');
    });

    test('every declared identifier is attached to a control', () {
      final unattached = _unattached(
        _declaredMembers(),
        _librarySources()
            // The declaration itself lives in automation_ids.dart; a member
            // used nowhere else names nothing.
            .where((f) => !f.path.endsWith('automation_ids.dart'))
            .map((f) => f.readAsStringSync()),
      );
      expect(
        unattached,
        isEmpty,
        reason: 'declared but attached to no control in lib/: $unattached',
      );
    });
  });

  // What the check above counts as a use depends entirely on this, and the
  // two are read apart: a reader that counted prose or text would restore the
  // false negative the whole group exists to prevent.
  group('what counts as a use', () {
    List<String> unattachedIn(String body,
            [List<String> members = const ['tradeRate']]) =>
        _unattached(members, ['void f() {\n$body\n}']);

    test('a member reference or helper call in code', () {
      expect(unattachedIn('tag(AutomationIds.tradeRate);'), isEmpty);
      expect(unattachedIn(r"tag('row-${AutomationIds.tradeRate}');"), isEmpty);
      expect(
        unattachedIn('tag(AutomationIds.tradeRateStar(1));', ['tradeRateStar']),
        isEmpty,
      );
    });

    test('a longer member is not a use of a name it starts with', () {
      expect(
        unattachedIn('tag(AutomationIds.tradeRateSubmit);',
            ['tradeRate', 'tradeRateSubmit']),
        ['tradeRate'],
      );
    });

    test('a name in a comment is not a use, however it is written', () {
      for (final body in [
        'switch (x) { case 1:// AutomationIds.tradeRate\n}',
        '/// AutomationIds.tradeRate\nbuild();',
        '/* AutomationIds.tradeRate */ build();',
        '/* outer /* inner */ AutomationIds.tradeRate */ build();',
        "connect('wss://x'); // AutomationIds.tradeRate",
      ]) {
        expect(unattachedIn(body), ['tradeRate'], reason: body);
      }
    });

    test('a name in a string is not a use', () {
      for (final body in [
        "const note = 'AutomationIds.tradeRate';",
        "const note = '''\nAutomationIds.tradeRate\n''';",
      ]) {
        expect(unattachedIn(body), ['tradeRate'], reason: body);
      }
    });

    test('a url is not a comment, and neither is the code after it', () {
      expect(
        unattachedIn("connect('wss://relay.mostro.network'); "
            'tag(AutomationIds.tradeRate);'),
        isEmpty,
      );
    });
  });

  group('AutomationId', () {
    testWidgets('exposes the identifier and merges the control it names',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElevatedButton(
              onPressed: () {},
              child: const Text('Submit'),
            ).withAutomationId(AutomationIds.orderCreateSubmit),
          ),
        ),
      );

      // The identifier, the visible label, the enabled flag and the tap
      // action all travel on one node — that is what the Android
      // accessibility bridge exposes as a `resource-id`.
      expect(
        tester.getSemantics(find.byType(ElevatedButton)),
        isSemantics(
          identifier: AutomationIds.orderCreateSubmit,
          label: 'Submit',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('an explicit label overrides the visible copy',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const Text('Esperando pago…').withAutomationId(
              AutomationIds.orderStatus,
              label: 'waiting-payment',
            ),
          ),
        ),
      );

      // State readouts are asserted on by machine name, never by the copy,
      // which changes with the locale.
      expect(
        tester.getSemantics(find.text('Esperando pago…')),
        isSemantics(
          identifier: AutomationIds.orderStatus,
          label: 'waiting-payment',
        ),
      );
    });

    testWidgets('merge: false keeps nested controls addressable',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.delete),
                ).withAutomationId(
                  AutomationIds.settingsRelayDelete('ws://10.0.2.2:7000'),
                ),
              ],
            ).withAutomationId(
              AutomationIds.settingsRelayItem('ws://10.0.2.2:7000'),
              merge: false,
              label: 'ws://10.0.2.2:7000',
            ),
          ),
        ),
      );

      // A merged row would swallow the delete button's own node, and
      // automation could no longer choose which relay to remove.
      expect(
        tester.getSemantics(find.byType(IconButton)),
        isSemantics(
          identifier:
              AutomationIds.settingsRelayDelete('ws://10.0.2.2:7000'),
          hasTapAction: true,
        ),
      );
    });
  });

  group('dynamic identifiers', () {
    test('embed the key they are built from', () {
      expect(AutomationIds.orderBookItem('o1'), 'order.book.item.o1');
      expect(AutomationIds.tradesItem('o1'), 'trades.item.o1');
      expect(
        AutomationIds.orderCreateCurrencyOption('USD'),
        'order.create.currency.USD',
      );
      expect(
        AutomationIds.settingsRelayItem('ws://10.0.2.2:7000'),
        'settings.relays.item.ws://10.0.2.2:7000',
      );
    });

    test('a relay keeps one identifier however its url is written', () {
      const canonical = 'settings.relays.item.ws://10.0.2.2:7000';
      for (final written in [
        'ws://10.0.2.2:7000',
        'ws://10.0.2.2:7000/',
        'ws://10.0.2.2:7000//',
        '  ws://10.0.2.2:7000/  ',
      ]) {
        expect(AutomationIds.settingsRelayItem(written), canonical,
            reason: written);
      }
    });
  });

  group('order.status', () {
    test('every trade status has a kebab-case machine name', () {
      final names = {
        for (final status in TradeStatus.values) status: status.machineName,
      };
      expect(names[TradeStatus.waitingInvoice], 'waiting-invoice');
      expect(names[TradeStatus.waitingPayment], 'waiting-payment');
      expect(names[TradeStatus.inProgress], 'in-progress');
      expect(names[TradeStatus.fiatSent], 'fiat-sent');
      expect(names[TradeStatus.pendingRating], 'pending-rating');
      expect(names[TradeStatus.active], 'active');

      for (final name in names.values) {
        expect(name, matches(RegExp(r'^[a-z]+(-[a-z]+)*$')), reason: name);
      }
      expect(names.values.toSet(), hasLength(TradeStatus.values.length));
    });
  });

  group('the test environment', () {
    tearDown(TestEnvironment.disarm);

    test('stays disabled unless the build carries the define', () {
      TestEnvironment.arm();
      expect(TestEnvironment.enabled, TestEnvironment.defineEnabled);
      expect(TestEnvironment.allowInsecureRelays, TestEnvironment.enabled);
    });

    test('is disabled for a build that never armed it', () {
      expect(TestEnvironment.enabled, isFalse);
      expect(TestEnvironment.seedRelays, isEmpty);
      expect(TestEnvironment.allowInsecureRelays, isFalse);
    });

    test('asks for an order expiry only when the define is set', () {
      // The define is absent in this test build, so nothing is asked for
      // whether or not the environment is armed.
      TestEnvironment.arm();
      expect(TestEnvironment.orderExpirySecs, isNull);
      TestEnvironment.disarm();
      expect(TestEnvironment.orderExpirySecs, isNull);
    });

    test('parses a relay seed list, trimming and dropping blanks', () {
      expect(
        TestEnvironment.parseRelays(' ws://a:1 , ,ws://b:2, '),
        ['ws://a:1', 'ws://b:2'],
      );
      expect(TestEnvironment.parseRelays(''), isEmpty);
    });

    testWidgets('the banner renders nothing outside the test environment',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TestEnvironmentBanner(child: Text('app')),
        ),
      );

      expect(find.text(TestEnvironment.markerLabel), findsNothing);
      expect(
        find.bySemanticsLabel(TestEnvironment.markerLabel),
        findsNothing,
      );
      expect(find.text('app'), findsOneWidget);
    });
  });
}

// ── Source scanning ──────────────────────────────────────────────────────────
//
// The contract is a promise about the shipped widget tree, and most of that
// tree needs the Rust bridge to build. Reading the sources checks the one
// thing a unit test can check without it: that nothing is declared and then
// left unattached.

const _registryPath = 'lib/core/automation/automation_ids.dart';

/// Member names declared in the registry (constants and helper methods).
List<String> _declaredMembers() {
  final source = File(_registryPath).readAsStringSync();
  final constants = RegExp(r'static const String (\w+) =')
      .allMatches(source)
      .map((m) => m.group(1)!);
  final helpers = RegExp(r'static String (\w+)\(')
      .allMatches(source)
      .map((m) => m.group(1)!)
      // Private helpers are implementation, not contract.
      .where((name) => !name.startsWith('_'));
  return [...constants, ...helpers];
}

/// Identifier values declared in the registry.
List<String> _declaredIdentifiers() {
  final source = File(_registryPath).readAsStringSync();
  return RegExp(r"static const String \w+ =\s*'([^']+)'")
      .allMatches(source)
      .map((m) => m.group(1)!)
      // The wallet-connection readout values are machine words, not ids.
      .where((id) => id.contains('.'))
      .toList();
}

/// The hand-written sources under lib/.
Iterable<File> _librarySources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    // Generated code never attaches identifiers.
    .where((f) => !f.path.startsWith('lib/src/'))
    .where((f) => !f.path.startsWith('lib/generated/'))
    .where((f) => !f.path.startsWith('lib/l10n/'));

/// The [members] that no source in [sources] references in code.
List<String> _unattached(Iterable<String> members, Iterable<String> sources) {
  final attached = {for (final source in sources) ..._attachedMembers(source)};
  return members.where((m) => !attached.contains(m)).toList();
}

/// The registry members [source] references in code.
///
/// Reads the parsed syntax tree, not the text, so a name mentioned only in a
/// comment or a string is attached to nothing — however the comment nests or
/// whatever the string holds — while one inside an interpolation still counts.
/// A member counts only when its name matches exactly, so
/// `AutomationIds.tradeRateSubmit` is no use of `tradeRate`: a substring
/// search once let `trade.rate` outlive the button it named.
Set<String> _attachedMembers(String source) {
  final references = _RegistryReferences();
  parseString(content: source, throwIfDiagnostics: false)
      .unit
      .accept(references);
  return references.members;
}

class _RegistryReferences extends RecursiveAstVisitor<void> {
  final members = <String>{};

  // `AutomationIds.tradeRate`
  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.prefix.name == 'AutomationIds') {
      members.add(node.identifier.name);
    }
    super.visitPrefixedIdentifier(node);
  }

  // `AutomationIds.tradeRateStar(star)`
  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target is SimpleIdentifier && target.name == 'AutomationIds') {
      members.add(node.methodName.name);
    }
    super.visitMethodInvocation(node);
  }
}
