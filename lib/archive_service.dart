import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_saver/file_saver.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'draft_store.dart';
import 'history_store.dart';
import 'l10n/app_localizations.dart';

const archiveExtension = 'josymbolconverter';
const legacyArchiveExtension = 'joquoteconverter';
const archiveExtensions = <String>[archiveExtension, legacyArchiveExtension];
const archiveMimeType = 'application/x-jo-symbol-converter-archive';

typedef ArchiveFilePicker =
    Future<XFile?> Function(List<XTypeGroup> acceptedTypeGroups);
typedef AndroidArchiveSaver =
    Future<String?> Function(String name, Uint8List bytes);

class ArchiveSnapshot {
  const ArchiveSnapshot({
    required this.draft,
    required this.themeMode,
    required this.palette,
    required this.keyboardShortcutsEnabled,
    required this.history,
    this.locale = 'zh',
  });

  final SavedDraft draft;
  final String themeMode;
  final String palette;
  final bool keyboardShortcutsEnabled;
  final String locale;
  final List<ConversionHistoryEntry> history;
}

class ArchiveDocument {
  const ArchiveDocument({
    required this.appVersion,
    required this.exportedAt,
    required this.snapshot,
  });

  final String appVersion;
  final DateTime exportedAt;
  final ArchiveSnapshot snapshot;
}

class ArchiveFormatException implements Exception {
  const ArchiveFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AutomaticBackup {
  const AutomaticBackup({
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
    this.document,
    this.errorMessage,
  });

  final String fileName;
  final int sizeBytes;
  final DateTime modifiedAt;
  final ArchiveDocument? document;
  final String? errorMessage;

  bool get canRestore => document != null;
}

class ArchiveService {
  static dynamic get _l10n => AppLocalizations.strings;

  ArchiveService({
    Future<Directory> Function()? supportDirectoryProvider,
    ArchiveFilePicker? filePicker,
    AndroidArchiveSaver? androidArchiveSaver,
    bool? isAndroid,
  }) : _filePicker =
           filePicker ??
           ((acceptedTypeGroups) => openFile(
             acceptedTypeGroups: acceptedTypeGroups,
             confirmButtonText: _l10n.archiveImportButton,
           )),
       _androidArchiveSaver =
           androidArchiveSaver ??
           ((name, bytes) => FileSaver.instance.saveAs(
             name: p.basenameWithoutExtension(name),
             bytes: bytes,
             fileExtension: archiveExtension,
             mimeType: MimeType.custom,
             customMimeType: archiveMimeType,
           )),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const formatVersion = 1;
  static const _manifestName = 'manifest.json';
  static const _workspaceName = 'workspace.json';
  static const _historyName = 'history.jsonl';
  static const _checksumsName = 'checksums.json';
  static const _maxArchiveBytes = 256 * 1024 * 1024;
  static const _maxEntryBytes = 128 * 1024 * 1024;

  final Future<Directory> Function() _supportDirectoryProvider;
  final ArchiveFilePicker _filePicker;
  final AndroidArchiveSaver _androidArchiveSaver;
  final bool _isAndroid;

  Uint8List encode({
    required ArchiveSnapshot snapshot,
    required String appVersion,
    DateTime? exportedAt,
  }) {
    final exportTime = (exportedAt ?? DateTime.now()).toUtc();
    final workspaceBytes = _jsonBytes({
      'input': snapshot.draft.input,
      'output': snapshot.draft.output,
      'settings': {
        'excludeMarkdownCode': snapshot.draft.excludeMarkdownCode,
        'useHeuristics': snapshot.draft.useHeuristics,
        'themeMode': snapshot.themeMode,
        'palette': snapshot.palette,
        'locale': snapshot.locale,
        'keyboardShortcutsEnabled': snapshot.keyboardShortcutsEnabled,
      },
    });
    final historyBytes = Uint8List.fromList(
      utf8.encode(
        snapshot.history
            .map(
              (entry) => jsonEncode({
                'input': entry.input,
                'output': entry.output,
                'createdAt': entry.createdAt.toUtc().toIso8601String(),
              }),
            )
            .join('\n'),
      ),
    );
    final manifestBytes = _jsonBytes({
      'format': 'JO-Symbol-Converter',
      'formatVersion': formatVersion,
      'appVersion': appVersion,
      'exportedAt': exportTime.toIso8601String(),
      'historyCount': snapshot.history.length,
      'compressed': true,
      'encrypted': false,
    });
    final dataFiles = <String, Uint8List>{
      _manifestName: manifestBytes,
      _workspaceName: workspaceBytes,
      _historyName: historyBytes,
    };
    final checksumsBytes = _jsonBytes({
      'algorithm': 'SHA-256',
      'files': {
        for (final entry in dataFiles.entries)
          entry.key: sha256.convert(entry.value).toString(),
      },
    });

    final archive = Archive();
    for (final entry in dataFiles.entries) {
      archive.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    archive.add(ArchiveFile.bytes(_checksumsName, checksumsBytes));
    return ZipEncoder().encodeBytes(
      archive,
      level: DeflateLevel.bestCompression,
      modified: exportTime,
    );
  }

  ArchiveDocument decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maxArchiveBytes) {
      throw ArchiveFormatException(_l10n.archiveErrorEmptyOrTooLarge);
    }

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw ArchiveFormatException(_l10n.archiveErrorUnzipFailed);
    }

    final files = <String, Uint8List>{};
    var totalUncompressedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name.contains('/') || file.name.contains('\\')) {
        throw ArchiveFormatException(_l10n.archiveErrorInvalidPath);
      }
      if (files.containsKey(file.name) || file.size > _maxEntryBytes) {
        throw ArchiveFormatException(_l10n.archiveErrorDuplicateFile);
      }
      totalUncompressedBytes += file.size;
      if (totalUncompressedBytes > _maxArchiveBytes) {
        throw ArchiveFormatException(_l10n.archiveErrorTooLargeAfterExtract);
      }
      final content = file.readBytes();
      if (content == null) {
        throw ArchiveFormatException(_l10n.archiveErrorUnreadable);
      }
      files[file.name] = content;
    }
    const requiredNames = {
      _manifestName,
      _workspaceName,
      _historyName,
      _checksumsName,
    };
    if (files.length != requiredNames.length ||
        !files.keys.toSet().containsAll(requiredNames)) {
      throw ArchiveFormatException(_l10n.archiveErrorIncomplete);
    }

    final checksums = _decodeObject(
      files[_checksumsName]!,
      _l10n.archiveLabelChecksums,
    );
    if (checksums['algorithm'] != 'SHA-256') {
      throw ArchiveFormatException(_l10n.archiveErrorUnsupportedChecksum);
    }
    final checksumFiles = checksums['files'];
    if (checksumFiles is! Map<String, dynamic>) {
      throw ArchiveFormatException(_l10n.archiveErrorInvalidChecksumInfo);
    }
    for (final name in requiredNames.where((name) => name != _checksumsName)) {
      final expected = checksumFiles[name];
      final actual = sha256.convert(files[name]!).toString();
      if (expected is! String || expected != actual) {
        throw ArchiveFormatException(_l10n.archiveErrorChecksumFailed(name));
      }
    }

    final manifest = _decodeObject(
      files[_manifestName]!,
      _l10n.archiveLabelManifest,
    );
    final format = manifest['format'];
    if ((format != 'JO-Quote-Converter' && format != 'JO-Symbol-Converter') ||
        manifest['formatVersion'] != formatVersion) {
      throw ArchiveFormatException(_l10n.archiveErrorUnsupportedVersion);
    }
    final appVersion = manifest['appVersion'];
    final exportedAtValue = manifest['exportedAt'];
    final historyCount = manifest['historyCount'];
    if (appVersion is! String ||
        exportedAtValue is! String ||
        historyCount is! int ||
        manifest['encrypted'] != false) {
      throw ArchiveFormatException(_l10n.archiveErrorInvalidManifest);
    }
    final exportedAt = DateTime.tryParse(exportedAtValue);
    if (exportedAt == null) {
      throw ArchiveFormatException(_l10n.archiveErrorInvalidExportTime);
    }

    final workspace = _decodeObject(
      files[_workspaceName]!,
      _l10n.archiveLabelWorkspace,
    );
    final input = workspace['input'];
    final output = workspace['output'];
    final settings = workspace['settings'];
    if (input is! String ||
        output is! String ||
        settings is! Map<String, dynamic>) {
      throw ArchiveFormatException(_l10n.archiveErrorInvalidWorkspace);
    }
    final excludeMarkdownCode = settings['excludeMarkdownCode'];
    final useHeuristics = settings['useHeuristics'];
    final themeMode = settings['themeMode'];
    final palette = settings['palette'];
    final locale = settings['locale'];
    final keyboardShortcutsEnabled = settings['keyboardShortcutsEnabled'];
    if (excludeMarkdownCode is! bool ||
        useHeuristics is! bool ||
        keyboardShortcutsEnabled is! bool ||
        themeMode is! String ||
        !const {'system', 'light', 'dark'}.contains(themeMode) ||
        palette is! String ||
        !const {
          'red',
          'yellow',
          'green',
          'blue',
          'purple',
          'gray',
        }.contains(palette) ||
        (locale != null &&
            (locale is! String || !const {'zh', 'en'}.contains(locale)))) {
      throw ArchiveFormatException(_l10n.archiveErrorInvalidSettings);
    }

    final history = <ConversionHistoryEntry>[];
    final historyText = _decodeUtf8(
      files[_historyName]!,
      _l10n.archiveLabelHistory,
    );
    if (historyText.isNotEmpty) {
      for (final line in const LineSplitter().convert(historyText)) {
        final decoded = _decodeJsonLine(line);
        final historyInput = decoded['input'];
        final historyOutput = decoded['output'];
        final createdAtValue = decoded['createdAt'];
        final createdAt = createdAtValue is String
            ? DateTime.tryParse(createdAtValue)
            : null;
        if (historyInput is! String ||
            historyOutput is! String ||
            createdAt == null) {
          throw ArchiveFormatException(_l10n.archiveErrorInvalidHistory);
        }
        history.add(
          ConversionHistoryEntry(
            input: historyInput,
            output: historyOutput,
            createdAt: createdAt.toLocal(),
          ),
        );
      }
    }
    if (history.length != historyCount) {
      throw ArchiveFormatException(_l10n.archiveErrorHistoryMismatch);
    }

    return ArchiveDocument(
      appVersion: appVersion,
      exportedAt: exportedAt.toLocal(),
      snapshot: ArchiveSnapshot(
        draft: SavedDraft(
          input: input,
          output: output,
          excludeMarkdownCode: excludeMarkdownCode,
          useHeuristics: useHeuristics,
        ),
        themeMode: themeMode,
        palette: palette,
        locale: (locale as String?) ?? 'zh',
        keyboardShortcutsEnabled: keyboardShortcutsEnabled,
        history: history,
      ),
    );
  }

  Future<bool> exportWithPicker({
    required ArchiveSnapshot snapshot,
    required String appVersion,
    DateTime? now,
  }) async {
    final exportTime = now ?? DateTime.now();
    final name =
        '${_l10n.archiveFileNamePrefix}-${_fileTimestamp(exportTime)}.$archiveExtension';
    final data = encode(
      snapshot: snapshot,
      appVersion: appVersion,
      exportedAt: exportTime,
    );
    if (_isAndroid) {
      return await _androidArchiveSaver(name, data) != null;
    }
    final location = await getSaveLocation(
      acceptedTypeGroups: [
        XTypeGroup(
          label: _l10n.archiveTypeLabel,
          extensions: const [archiveExtension],
          mimeTypes: const [archiveMimeType],
        ),
      ],
      suggestedName: name,
      confirmButtonText: _l10n.archiveExportButton,
    );
    if (location == null) return false;
    final archiveFile = XFile.fromData(
      data,
      mimeType: archiveMimeType,
      name: name,
    );
    await archiveFile.saveTo(_ensureExtension(location.path));
    return true;
  }

  Future<ArchiveDocument?> pickAndDecode() async {
    final file = await _filePicker(
      _isAndroid
          ? [XTypeGroup(label: _l10n.archiveTypeLabel)]
          : [
              XTypeGroup(
                label: _l10n.archiveTypeLabel,
                extensions: archiveExtensions,
                mimeTypes: const [archiveMimeType],
              ),
            ],
    );
    if (file == null) return null;
    if (!_isAndroid && !_hasArchiveExtension(file.name)) {
      throw ArchiveFormatException(_l10n.archivePickInvalidFile);
    }
    return decode(await file.readAsBytes());
  }

  Future<ArchiveDocument> decodeFilePath(String path) async {
    if (!_hasArchiveExtension(path)) {
      throw ArchiveFormatException(_l10n.archivePickInvalidFile);
    }
    return decode(await File(path).readAsBytes());
  }

  Future<String> createAutomaticBackup({
    required ArchiveSnapshot snapshot,
    required String appVersion,
    DateTime? now,
  }) async {
    final backupTime = now ?? DateTime.now();
    final supportDirectory = await _supportDirectoryProvider();
    final backupDirectory = Directory(p.join(supportDirectory.path, 'backups'));
    await backupDirectory.create(recursive: true);
    final file = File(
      p.join(
        backupDirectory.path,
        'before-import-${_fileTimestamp(backupTime)}.$archiveExtension',
      ),
    );
    await file.writeAsBytes(
      encode(
        snapshot: snapshot,
        appVersion: appVersion,
        exportedAt: backupTime,
      ),
      flush: true,
    );
    return file.path;
  }

  Future<List<AutomaticBackup>> listAutomaticBackups() async {
    final backupDirectory = await _backupDirectory();
    if (!await backupDirectory.exists()) return const [];

    final backups = <AutomaticBackup>[];
    await for (final entity in backupDirectory.list(followLinks: false)) {
      if (entity is! File || !_hasArchiveExtension(entity.path)) {
        continue;
      }
      final stat = await entity.stat();
      try {
        backups.add(
          AutomaticBackup(
            fileName: p.basename(entity.path),
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            document: decode(await entity.readAsBytes()),
          ),
        );
      } on ArchiveFormatException catch (error) {
        backups.add(
          AutomaticBackup(
            fileName: p.basename(entity.path),
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            errorMessage: error.message,
          ),
        );
      } catch (_) {
        backups.add(
          AutomaticBackup(
            fileName: p.basename(entity.path),
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
            errorMessage: _l10n.archiveErrorBackupUnreadable,
          ),
        );
      }
    }
    backups.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return backups;
  }

  Future<void> deleteAutomaticBackup(AutomaticBackup backup) async {
    final file = await _automaticBackupFile(backup.fileName);
    if (!await file.exists()) throw StateError('备份文件不存在。');
    await file.delete();
  }

  Future<int> clearAutomaticBackups() async {
    final backups = await listAutomaticBackups();
    for (final backup in backups) {
      final file = await _automaticBackupFile(backup.fileName);
      if (await file.exists()) await file.delete();
    }
    return backups.length;
  }

  Future<Directory> _backupDirectory() async {
    final supportDirectory = await _supportDirectoryProvider();
    return Directory(p.join(supportDirectory.path, 'backups'));
  }

  Future<File> _automaticBackupFile(String fileName) async {
    if (fileName != p.basename(fileName) || !_hasArchiveExtension(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', '无效的备份文件名');
    }
    final backupDirectory = await _backupDirectory();
    return File(p.join(backupDirectory.path, fileName));
  }

  static Uint8List _jsonBytes(Map<String, Object?> value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));

  static Map<String, dynamic> _decodeObject(Uint8List bytes, String label) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Converted below to a stable user-facing format error.
    }
    throw ArchiveFormatException(_l10n.archiveErrorLabelInvalid(label));
  }

  static Map<String, dynamic> _decodeJsonLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Converted below to a stable user-facing format error.
    }
    throw ArchiveFormatException(_l10n.archiveErrorInvalidHistory);
  }

  static String _decodeUtf8(Uint8List bytes, String label) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw ArchiveFormatException(_l10n.archiveErrorLabelNotUtf8(label));
    }
  }

  static String _fileTimestamp(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${local.year}${two(local.month)}${two(local.day)}-'
        '${two(local.hour)}${two(local.minute)}${two(local.second)}-'
        '${three(local.millisecond)}';
  }

  static String _ensureExtension(String path) =>
      _hasArchiveExtension(path) ? path : '$path.$archiveExtension';

  static bool _hasArchiveExtension(String path) {
    final lower = path.toLowerCase();
    return archiveExtensions.any((extension) => lower.endsWith('.$extension'));
  }
}
