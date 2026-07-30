import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/storage/app_data_dir.dart';

void main() {
  group('resolveLinuxDataDir', () {
    test('uses XDG_DATA_HOME when it is set to an absolute path', () {
      // Arrange
      final env = {'XDG_DATA_HOME': '/home/u/.local/share', 'HOME': '/home/u'};

      // Act
      final dir = resolveLinuxDataDir(env);

      // Assert
      expect(dir, '/home/u/.local/share/mostro');
    });

    test('honours an XDG_DATA_HOME pointing outside ~/.local/share', () {
      final dir =
          resolveLinuxDataDir({'XDG_DATA_HOME': '/data/xdg', 'HOME': '/home/u'});

      expect(dir, '/data/xdg/mostro');
    });

    test('falls back to \$HOME/.local/share when XDG_DATA_HOME is unset', () {
      final dir = resolveLinuxDataDir({'HOME': '/home/u'});

      expect(dir, '/home/u/.local/share/mostro');
    });

    test('falls back to \$HOME when XDG_DATA_HOME is empty', () {
      // The XDG spec treats an empty value exactly like an unset one.
      final dir =
          resolveLinuxDataDir({'XDG_DATA_HOME': '', 'HOME': '/home/u'});

      expect(dir, '/home/u/.local/share/mostro');
    });

    test('ignores a relative XDG_DATA_HOME, as the XDG spec requires', () {
      // A relative value would resolve against the process working directory,
      // putting the database somewhere unpredictable.
      final dir =
          resolveLinuxDataDir({'XDG_DATA_HOME': '.share', 'HOME': '/home/u'});

      expect(dir, '/home/u/.local/share/mostro');
    });

    test('returns null when neither XDG_DATA_HOME nor HOME is usable', () {
      // The caller must fall back to path_provider rather than guess a path.
      expect(resolveLinuxDataDir(const {}), isNull);
      expect(resolveLinuxDataDir(const {'HOME': ''}), isNull);
      expect(resolveLinuxDataDir(const {'HOME': 'relative/home'}), isNull);
    });

    test('never resolves inside the user-visible Documents folder', () {
      // Regression: the database used to live in getApplicationDocumentsDirectory(),
      // i.e. XDG_DOCUMENTS_DIR — a folder users tidy up, deleting their identity
      // and trade history by accident.
      final dir = resolveLinuxDataDir({
        'HOME': '/home/u',
        'XDG_DOCUMENTS_DIR': '/home/u/Documentos',
      });

      expect(dir, isNot(contains('Documentos')));
      expect(dir, isNot(contains('Documents')));
    });
  });
}
