import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException, PlatformInt64Util;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/services/identity_service.dart';
import 'package:mostro/src/rust/api/types.dart';
import 'package:mostro/src/rust/frb_generated.dart';

const _old =
    'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _new =
    'prefer olympic float negative alarm mechanic '
    'capital because sausage struggle travel trade';

/// The identity slot as Rust keeps it: `delete_identity` fails on an empty
/// slot, and the import is refused while [refuseImports] holds, the way a
/// pending wipe that fails again refuses it (issue #555).
class _Api implements RustLibApi {
  bool loaded = true;
  bool refuseImports = false;
  Object? deleteError;
  int deletes = 0;
  int imports = 0;

  @override
  Future<void> crateApiIdentityDeleteIdentity() async {
    deletes++;
    if (deleteError case final error?) throw error;
    if (!loaded) throw AnyhowException('NoIdentity');
    loaded = false;
  }

  @override
  Future<IdentityInfo> crateApiIdentityImportFromMnemonic({
    required List<String> words,
    required bool recover,
  }) async {
    imports++;
    if (refuseImports) throw AnyhowException('PendingWipeFailed');
    loaded = true;
    return IdentityInfo(
      publicKey: 'imported',
      privacyMode: false,
      tradeKeyIndex: 0,
      createdAt: PlatformInt64Util.from(0),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // The bridge initializes once per isolate; each test resets the slot.
  late _Api api;
  setUpAll(() => RustLib.initMock(api: _Delegate(() => api)));
  setUp(() => api = _Api());

  // The release UI used to call the second attempt an invalid mnemonic: it
  // failed on `NoIdentity` before the import, and its pending-wipe gate, ran.
  test('an import refused for a pending wipe can be retried', () async {
    FlutterSecureStorage.setMockInitialValues({
      'mostro_identity_mnemonic': _old,
    });
    api.refuseImports = true;

    await expectLater(
      IdentityService.importAndStore(_new.split(' ')),
      throwsA(
        isA<AnyhowException>().having(
          (e) => e.message,
          'message',
          'PendingWipeFailed',
        ),
      ),
    );
    expect(
      await IdentityService.getMnemonicWords(),
      _old.split(' '),
      reason: 'a refused import keeps the stored identity',
    );

    // The storage recovered: the retry reaches the import and lands.
    api.refuseImports = false;
    await IdentityService.importAndStore(_new.split(' '));

    expect(api.deletes, 2);
    expect(api.imports, 2);
    expect(await IdentityService.getMnemonicWords(), _new.split(' '));
  });

  test('any other deletion failure still stops the import', () async {
    FlutterSecureStorage.setMockInitialValues({});
    api.deleteError = StateError('bridge down');

    await expectLater(
      IdentityService.importAndStore(_new.split(' ')),
      throwsA(isA<StateError>()),
    );
    expect(api.imports, 0);
  });
}

/// Forwards to the current test's [_Api].
class _Delegate implements RustLibApi {
  _Delegate(this._api);

  final _Api Function() _api;

  @override
  Future<void> crateApiIdentityDeleteIdentity() =>
      _api().crateApiIdentityDeleteIdentity();

  @override
  Future<IdentityInfo> crateApiIdentityImportFromMnemonic({
    required List<String> words,
    required bool recover,
  }) =>
      _api().crateApiIdentityImportFromMnemonic(words: words, recover: recover);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
