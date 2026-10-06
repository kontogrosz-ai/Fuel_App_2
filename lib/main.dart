import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:excel/excel.dart';
import 'parsers/voice_fuel_parser.dart';
import 'services/voice_input_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FuelApp());
}

// --- AUTOMATYCZNY BACKUP RAZ W MIESIĄCU ---
Future<void> _checkAndPerformMonthlyBackup() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final lastBackupString = prefs.getString('last_auto_backup');
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month);

    DateTime? lastBackup;
    if (lastBackupString != null) {
      lastBackup = DateTime.tryParse(lastBackupString);
    }

    final shouldBackup = lastBackup == null ||
        DateTime(lastBackup.year, lastBackup.month).isBefore(currentMonth);
    if (!shouldBackup) return;

    final directory = await getApplicationDocumentsDirectory();
    final source = File('${directory.path}/Dane_Tankowania.json');

    if (await source.exists()) {
      final backupDirectory = Directory('${directory.path}/backups');
      await backupDirectory.create(recursive: true);
      final dateText =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await source.copy(
        '${backupDirectory.path}/fuel_app_backup_$dateText.json',
      );
      debugPrint('Automatyczny miesięczny backup wykonany pomyślnie.');
    }

    await prefs.setString('last_auto_backup', now.toIso8601String());
  } catch (error, stackTrace) {
    debugPrint('Błąd automatycznego backupu: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

enum FuelType { pb, lpg }

extension FuelTypeExtension on FuelType {
  String get label {
    switch (this) {
      case FuelType.pb:
        return 'Benzyna (PB)';
      case FuelType.lpg:
        return 'LPG';
    }
  }
}

// --- DEFINICJE MODELI I STANU FILTROWANIA ---
enum FilterMainMode { time, count, distance, custom }
enum TimeFilterOption { month1, months3, months6, year1, all }
enum CountFilterOption { c5, c10, c20, cAll }
enum DistanceFilterOption { km500, km1000, km5000, kmAll }

@immutable
class FuelFilterState {
  const FuelFilterState({
    this.mainMode = FilterMainMode.time,
    this.timeOption = TimeFilterOption.months6,
    this.countOption = CountFilterOption.c10,
    this.distanceOption = DistanceFilterOption.km1000,
    this.customDateRange,
  });

  final FilterMainMode mainMode;
  final TimeFilterOption timeOption;
  final CountFilterOption countOption;
  final DistanceFilterOption distanceOption;
  final DateTimeRange? customDateRange;

  FuelFilterState copyWith({
    FilterMainMode? mainMode,
    TimeFilterOption? timeOption,
    CountFilterOption? countOption,
    DistanceFilterOption? distanceOption,
    DateTimeRange? customDateRange,
  }) {
    return FuelFilterState(
      mainMode: mainMode ?? this.mainMode,
      timeOption: timeOption ?? this.timeOption,
      countOption: countOption ?? this.countOption,
      distanceOption: distanceOption ?? this.distanceOption,
      customDateRange: customDateRange ?? this.customDateRange,
    );
  }
}

class FilterResult {
  final List<FuelEntry> filteredEntries;
  final bool isDataLimited;
  final String infoMessage;

  FilterResult({
    required this.filteredEntries,
    required this.isDataLimited,
    required this.infoMessage,
  });
}

// --- ALGORYTM FILTRUJĄCY DANE ---
DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _subtractMonths(DateTime value, int months) {
  final firstDayOfTargetMonth = DateTime(value.year, value.month - months);
  final lastDay = DateTime(
    firstDayOfTargetMonth.year,
    firstDayOfTargetMonth.month + 1,
    0,
  ).day;
  final safeDay = value.day > lastDay ? lastDay : value.day;
  return DateTime(
    firstDayOfTargetMonth.year,
    firstDayOfTargetMonth.month,
    safeDay,
  );
}

FilterResult applyFuelFilter(
  List<FuelEntry> allEntries,
  FuelFilterState filterState,
) {
  final sorted = List<FuelEntry>.from(allEntries)
    ..sort((a, b) => b.date.compareTo(a.date));
  if (sorted.isEmpty) {
    return FilterResult(
      filteredEntries: const [],
      isDataLimited: false,
      infoMessage: 'Brak wpisów w bazie danych.',
    );
  }

  List<FuelEntry> result = [];
  String info = '';
  bool limited = false;

  switch (filterState.mainMode) {
    case FilterMainMode.time:
      final now = _dateOnly(DateTime.now());
      if (filterState.timeOption == TimeFilterOption.all) {
        result = sorted;
        info = 'Filtrowanie: Cała historia czasowa';
        break;
      }

      late DateTime cutoffDate;
      switch (filterState.timeOption) {
        case TimeFilterOption.month1:
          cutoffDate = _subtractMonths(now, 1);
          info = 'Filtrowanie: Ostatni miesiąc';
          break;
        case TimeFilterOption.months3:
          cutoffDate = _subtractMonths(now, 3);
          info = 'Filtrowanie: Ostatnie 3 miesiące';
          break;
        case TimeFilterOption.months6:
          cutoffDate = _subtractMonths(now, 6);
          info = 'Filtrowanie: Ostatnie 6 miesięcy';
          break;
        case TimeFilterOption.year1:
          cutoffDate = DateTime(now.year - 1, now.month, now.day);
          info = 'Filtrowanie: Ostatni rok';
          break;
        case TimeFilterOption.all:
          throw StateError('Opcja obsłużona wcześniej.');
      }
      result = sorted.where((entry) => !entry.date.isBefore(cutoffDate)).toList();
      break;

    case FilterMainMode.count:
      final targetCount = switch (filterState.countOption) {
        CountFilterOption.c5 => 5,
        CountFilterOption.c10 => 10,
        CountFilterOption.c20 => 20,
        CountFilterOption.cAll => sorted.length,
      };
      info = switch (filterState.countOption) {
        CountFilterOption.c5 => 'Ostatnie 5 tankowań',
        CountFilterOption.c10 => 'Ostatnie 10 tankowań',
        CountFilterOption.c20 => 'Ostatnie 20 tankowań',
        CountFilterOption.cAll => 'Wszystkie tankowania',
      };
      result = sorted.take(targetCount).toList();
      if (filterState.countOption != CountFilterOption.cAll &&
          sorted.length < targetCount) {
        limited = true;
        info +=
            ' (Dostępne tylko ${sorted.length} z żądanych $targetCount tankowań)';
      }
      break;

    case FilterMainMode.distance:
      final targetKm = switch (filterState.distanceOption) {
        DistanceFilterOption.km500 => 500.0,
        DistanceFilterOption.km1000 => 1000.0,
        DistanceFilterOption.km5000 => 5000.0,
        DistanceFilterOption.kmAll => double.infinity,
      };
      info = switch (filterState.distanceOption) {
        DistanceFilterOption.km500 => 'Ostatnie 500 km',
        DistanceFilterOption.km1000 => 'Ostatnie 1000 km',
        DistanceFilterOption.km5000 => 'Ostatnie 5000 km',
        DistanceFilterOption.kmAll => 'Cały dystans',
      };
      double accumulatedKm = 0;
      for (final entry in sorted) {
        result.add(entry);
        accumulatedKm += entry.tripDistance ?? 0;
        if (accumulatedKm >= targetKm) break;
      }
      if (targetKm.isFinite && accumulatedKm < targetKm) {
        limited = true;
        info +=
            ' (Osiągnięto maksymalny dostępny dystans: ${accumulatedKm.toStringAsFixed(0)} km)';
      }
      break;

    case FilterMainMode.custom:
      final range = filterState.customDateRange;
      if (range == null) {
        result = sorted;
        info = 'Własny zakres: Brak wybranego okresu';
        break;
      }
      final start = _dateOnly(range.start);
      final endExclusive = _dateOnly(range.end).add(const Duration(days: 1));
      result = sorted.where((entry) {
        return !entry.date.isBefore(start) && entry.date.isBefore(endExclusive);
      }).toList();
      info =
          'Zakres: ${start.day}.${start.month}.${start.year} - ${range.end.day}.${range.end.month}.${range.end.year}';
      break;
  }

  return FilterResult(
    filteredEntries: result,
    isDataLimited: limited,
    infoMessage: info,
  );
}

// --- KOMPONENT UI FILTRA (UKŁAD 2x2) ---
class FuelFilterWidget extends StatefulWidget {
  final FuelFilterState initialFilterState;
  final ValueChanged<FuelFilterState> onFilterChanged;

  const FuelFilterWidget({
    super.key,
    required this.initialFilterState,
    required this.onFilterChanged,
  });

  @override
  State<FuelFilterWidget> createState() => _FuelFilterWidgetState();
}

class _FuelFilterWidgetState extends State<FuelFilterWidget> {
  late FuelFilterState _currentFilter;

  @override
  void initState() {
    super.initState();
    _currentFilter = widget.initialFilterState;
  }

  @override
  void didUpdateWidget(covariant FuelFilterWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilterState != widget.initialFilterState) {
      _currentFilter = widget.initialFilterState;
    }
  }

  void _update(FuelFilterState value) {
    setState(() => _currentFilter = value);
    widget.onFilterChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.8,
              children: [
                _buildFilterTile(
                  mode: FilterMainMode.time,
                  label: 'Czas',
                  icon: Icons.access_time,
                ),
                _buildFilterTile(
                  mode: FilterMainMode.count,
                  label: 'Ilość',
                  icon: Icons.format_list_numbered,
                ),
                _buildFilterTile(
                  mode: FilterMainMode.distance,
                  label: 'Dystans',
                  icon: Icons.map,
                ),
                _buildFilterTile(
                  mode: FilterMainMode.custom,
                  label: 'Własny',
                  icon: Icons.date_range,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _buildSubOptionsChips(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterTile({
    required FilterMainMode mode,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _currentFilter.mainMode == mode;
    final theme = Theme.of(context);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => _update(_currentFilter.copyWith(mainMode: mode)),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSubOptionsChips() {
    List<Widget> chips = [];

    if (_currentFilter.mainMode == FilterMainMode.time) {
      for (var option in TimeFilterOption.values) {
        String label = '';
        switch (option) {
          case TimeFilterOption.month1: label = '1 miesiąc'; break;
          case TimeFilterOption.months3: label = '3 miesiące'; break;
          case TimeFilterOption.months6: label = '6 miesięcy'; break;
          case TimeFilterOption.year1: label = '1 rok'; break;
          case TimeFilterOption.all: label = 'Wszystko'; break;
        }
        chips.add(Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: ChoiceChip(
            label: Text(label),
            selected: _currentFilter.timeOption == option,
            onSelected: (selected) {
              if (selected) _update(_currentFilter.copyWith(timeOption: option));
            },
          ),
        ));
      }
    } else if (_currentFilter.mainMode == FilterMainMode.count) {
      for (var option in CountFilterOption.values) {
        String label = '';
        switch (option) {
          case CountFilterOption.c5: label = 'Ostatnie 5'; break;
          case CountFilterOption.c10: label = 'Ostatnie 10'; break;
          case CountFilterOption.c20: label = 'Ostatnie 20'; break;
          case CountFilterOption.cAll: label = 'Wszystkie'; break;
        }
        chips.add(Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: ChoiceChip(
            label: Text(label),
            selected: _currentFilter.countOption == option,
            onSelected: (selected) {
              if (selected) _update(_currentFilter.copyWith(countOption: option));
            },
          ),
        ));
      }
    } else if (_currentFilter.mainMode == FilterMainMode.distance) {
      for (var option in DistanceFilterOption.values) {
        String label = '';
        switch (option) {
          case DistanceFilterOption.km500: label = '500 km'; break;
          case DistanceFilterOption.km1000: label = '1000 km'; break;
          case DistanceFilterOption.km5000: label = '5000 km'; break;
          case DistanceFilterOption.kmAll: label = 'Cały dystans'; break;
        }
        chips.add(Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: ChoiceChip(
            label: Text(label),
            selected: _currentFilter.distanceOption == option,
            onSelected: (selected) {
              if (selected) _update(_currentFilter.copyWith(distanceOption: option));
            },
          ),
        ));
      }
    } else if (_currentFilter.mainMode == FilterMainMode.custom) {
      chips.add(
        ActionChip(
          avatar: const Icon(Icons.calendar_today, size: 16),
          label: Text(_currentFilter.customDateRange == null
              ? 'Wybierz daty z kalendarza'
              : '${_currentFilter.customDateRange!.start.day}.${_currentFilter.customDateRange!.start.month}.${_currentFilter.customDateRange!.start.year} - ${_currentFilter.customDateRange!.end.day}.${_currentFilter.customDateRange!.end.month}.${_currentFilter.customDateRange!.end.year}'),
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
              initialDateRange: _currentFilter.customDateRange,
            );
            if (picked != null) {
              _update(_currentFilter.copyWith(customDateRange: picked));
            }
          },
        ),
      );
    }

    return chips;
  }
}

class FuelEntry {
  final String id;
  final FuelType fuelType;
  final double cost;
  final double liters;
  final double? odometer;
  final double? tripDistance;
  final DateTime date;
  final bool isFullTank;

  FuelEntry({
    String? id,
    required this.fuelType,
    required this.cost,
    required this.liters,
    this.odometer,
    this.tripDistance,
    DateTime? date,
    this.isFullTank = true,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        date = date ?? DateTime.now();

  double get pricePerLiter => liters > 0 ? cost / liters : 0.0;

  double? get singleConsumption {
    if (tripDistance != null && tripDistance! > 0) {
      return (liters / tripDistance!) * 100;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fuelType': fuelType.name,
        'cost': cost,
        'liters': liters,
        'odometer': odometer,
        'tripDistance': tripDistance,
        'date': date.toIso8601String(),
        'isFullTank': isFullTank,
      };

  factory FuelEntry.fromJson(Map<String, dynamic> json) {
    return FuelEntry(
      id: json['id'] as String?,
      fuelType: FuelType.values.firstWhere(
        (e) => e.name == json['fuelType'],
        orElse: () => FuelType.lpg,
      ),
      cost: (json['cost'] as num).toDouble(),
      liters: (json['liters'] as num).toDouble(),
      odometer: json['odometer'] != null ? (json['odometer'] as num).toDouble() : null,
      tripDistance: json['tripDistance'] != null ? (json['tripDistance'] as num).toDouble() : null,
      date: DateTime.parse(json['date']),
      isFullTank: json['isFullTank'] as bool? ?? true,
    );
  }
}

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fuel App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  List<FuelEntry> _entries = [];
  bool _isScanning = false;
  bool _isLoading = true;
  bool _isVoiceListening = false;
  final VoiceInputService _voiceService = VoiceInputService();
  late TabController _tabController;

  FuelType _chartFuelType = FuelType.lpg;
  FuelFilterState _fuelFilterState = FuelFilterState();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 0);
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadEntriesFromFile();
    await _checkAndPerformMonthlyBackup();
  }

  @override
  void dispose() {
    _voiceService.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<File> _getJsonFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/Dane_Tankowania.json');
  }

  Future<void> _loadEntriesFromFile() async {
    try {
      final file = await _getJsonFile();
      final loaded = <FuelEntry>[];
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! List) {
          throw const FormatException('Główny element JSON nie jest listą.');
        }
        for (final item in decoded) {
          if (item is! Map) continue;
          try {
            loaded.add(FuelEntry.fromJson(Map<String, dynamic>.from(item)));
          } catch (error) {
            debugPrint('Pominięto uszkodzony rekord JSON: $error');
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = loaded;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Błąd wczytywania danych: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nie udało się wczytać zapisanych danych.')),
      );
    }
  }

  Future<bool> _saveEntriesToFile() async {
    try {
      final file = await _getJsonFile();
      final temporaryFile = File('${file.path}.tmp');
      final jsonList = _entries.map((entry) => entry.toJson()).toList();
      await temporaryFile.writeAsString(jsonEncode(jsonList), flush: true);
      if (await file.exists()) await file.delete();
      await temporaryFile.rename(file.path);
      return true;
    } catch (error, stackTrace) {
      debugPrint('Błąd zapisu danych: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nie udało się zapisać zmian.')),
        );
      }
      return false;
    }
  }

  Future<void> _exportJson() async {
    try {
      final file = await _getJsonFile();
      if (!await file.exists() || _entries.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brak danych do wyeksportowania.')),
        );
        return;
      }
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Kopia zapasowa - Fuel App',
        text: 'Plik kopii zapasowej bazy danych JSON.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd eksportu JSON: $e')),
      );
    }
  }

  Future<void> _importJson() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final contents = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(contents);
        final importedEntries = jsonList.map((e) => FuelEntry.fromJson(e)).toList();

        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import danych (JSON)'),
            content: Text('Wczytano ${importedEntries.length} wpisów z pliku. Co chcesz zrobić?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _entries = importedEntries;
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Zastąpiono bazę nowymi danymi.')),
                    );
                  }
                },
                child: const Text('Zastąp obecne'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    for (var entry in importedEntries) {
                      if (!_entries.any((e) => e.id == entry.id)) {
                        _entries.add(entry);
                      }
                    }
                  });
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Połączono dane pomyślnie.')),
                    );
                  }
                },
                child: const Text('Połącz (Scal)'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas importu pliku: $e')),
      );
    }
  }

  Future<Directory> _getExportDirectory() async {
    return getApplicationDocumentsDirectory();
  }

  Future<void> _exportXlsx() async {
    try {
      if (_entries.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Brak danych do wyeksportowania.')),
          );
        }
        return;
      }
      final workbook = Excel.createExcel();
      final defaultSheet = workbook.getDefaultSheet();
      if (defaultSheet != null && workbook.sheets.containsKey(defaultSheet)) {
        workbook.delete(defaultSheet);
      }

      void fillSheet(String name, List<FuelEntry> entries) {
        final sheet = workbook[name];
        sheet.appendRow([
          TextCellValue('Data'),
          TextCellValue('Paliwo'),
          TextCellValue('Koszt PLN'),
          TextCellValue('Litry'),
          TextCellValue('Cena/l PLN'),
          TextCellValue('Licznik km'),
          TextCellValue('Dystans km'),
          TextCellValue('Do pełna'),
        ]);
        for (final e in entries..sort((a, b) => a.date.compareTo(b.date))) {
          sheet.appendRow([
            TextCellValue(e.date.toIso8601String()),
            TextCellValue(e.fuelType.label),
            DoubleCellValue(e.cost),
            DoubleCellValue(e.liters),
            DoubleCellValue(e.pricePerLiter),
            e.odometer == null ? TextCellValue('') : DoubleCellValue(e.odometer!),
            e.tripDistance == null ? TextCellValue('') : DoubleCellValue(e.tripDistance!),
            TextCellValue(e.isFullTank ? 'TAK' : 'NIE'),
          ]);
        }
      }

      fillSheet('LPG', _entries.where((e) => e.fuelType == FuelType.lpg).toList());
      fillSheet('Benzyna PB', _entries.where((e) => e.fuelType == FuelType.pb).toList());

      final bytes = workbook.encode();
      if (bytes == null) throw StateError('Nie udało się utworzyć pliku XLSX.');
      final directory = await _getExportDirectory();
      final file = File('${directory.path}/Fuel_App_export.xlsx');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Fuel App - eksport XLSX',
        text: 'Eksport danych tankowań z Fuel App.',
      );
    } catch (e, stackTrace) {
      debugPrint('Błąd eksportu XLSX: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd eksportu XLSX: $e')),
        );
      }
    }
  }

  Future<void> _importXlsx() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (result == null || result.files.single.path == null) return;

      final bytes = await File(result.files.single.path!).readAsBytes();
      final workbook = Excel.decodeBytes(bytes);
      final imported = <FuelEntry>[];

      for (final sheet in workbook.tables.values) {
        if (sheet.maxRows <= 1) continue;
        for (var rowIndex = 1; rowIndex < sheet.maxRows; rowIndex++) {
          final row = sheet.rows[rowIndex];
          if (row.length < 4) continue;
          final date = _xlsxDate(_xlsxText(row[0]?.value));
          final fuelText = _xlsxText(row[1]?.value).toUpperCase();
          final cost = _xlsxNumber(row[2]?.value);
          final liters = _xlsxNumber(row[3]?.value);
          if (date == null || cost == null || liters == null || cost <= 0 || liters <= 0) continue;
          final fuelType = fuelText.contains('LPG') ? FuelType.lpg : FuelType.pb;
          imported.add(FuelEntry(
            id: _xlsxText(row[0]?.value) + '-' + rowIndex.toString() + '-' + sheet.sheetName,
            fuelType: fuelType,
            cost: cost,
            liters: liters,
            odometer: row.length > 5 ? _xlsxNumber(row[5]?.value) : null,
            tripDistance: row.length > 6 ? _xlsxNumber(row[6]?.value) : null,
            date: date,
            isFullTank: row.length > 7 ? _xlsxText(row[7]?.value).toUpperCase() != 'NIE' : true,
          ));
        }
      }

      if (!mounted) return;
      if (imported.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nie znaleziono poprawnych wpisów w pliku XLSX.')),
        );
        return;
      }
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import danych (XLSX)'),
          content: Text('Wczytano ${imported.length} wpisów. Co chcesz zrobić?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
            OutlinedButton(
              onPressed: () {
                setState(() => _entries = imported);
                _saveEntriesToFile();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Zastąpiono bazę danymi XLSX.')));
              },
              child: const Text('Zastąp obecne'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  for (final entry in imported) {
                    if (!_entries.any((e) => e.id == entry.id)) _entries.add(entry);
                  }
                });
                _saveEntriesToFile();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Połączono dane XLSX.')));
              },
              child: const Text('Połącz'),
            ),
          ],
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('Błąd importu XLSX: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Błąd importu XLSX: $e')));
    }
  }

  String _xlsxText(CellValue? value) {
    if (value == null) return '';
    if (value is TextCellValue) return value.value.text ?? '';
    if (value is IntCellValue) return value.value.toString();
    if (value is DoubleCellValue) return value.value.toString();
    if (value is BoolCellValue) return value.value.toString();
    return value.toString();
  }

  double? _xlsxNumber(CellValue? value) {
    if (value == null) return null;
    if (value is IntCellValue) return value.value.toDouble();
    if (value is DoubleCellValue) return value.value;
    return double.tryParse(_xlsxText(value).replaceAll(',', '.'));
  }

  DateTime? _xlsxDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
    final m = RegExp(r'^(\d{1,2})[./-](\d{1,2})[./-](\d{4})').firstMatch(value);
    if (m == null) return null;
    return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
  }

  Future<void> _startVoiceEntry() async {
    if (_isVoiceListening) {
      await _voiceService.stop();
      if (mounted) setState(() => _isVoiceListening = false);
      return;
    }

    final available = await _voiceService.initialize(onStatus: (_) {});
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rozpoznawanie mowy nie jest dostępne na tym urządzeniu.')),
        );
      }
      return;
    }

    final textNotifier = ValueNotifier<String>('');
    if (mounted) setState(() => _isVoiceListening = true);

    await _voiceService.start(
      onStatus: (_) {},
      onText: (text) => textNotifier.value = text,
    );

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [Icon(Icons.mic), SizedBox(width: 8), Text('Wprowadzanie głosowe')],
        ),
        content: ValueListenableBuilder<String>(
          valueListenable: textNotifier,
          builder: (context, text, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Mów po polsku. Możesz podać paliwo, litry, koszt, licznik i dystans.'),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black12,
                ),
                child: Text(text.isEmpty ? 'Słucham…' : text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await _voiceService.cancel();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Anuluj'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              await _voiceService.stop();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            icon: const Icon(Icons.check),
            label: const Text('Zakończ'),
          ),
        ],
      ),
    );

    await _voiceService.stop();
    final currentText = textNotifier.value;
    textNotifier.dispose();
    if (mounted) setState(() => _isVoiceListening = false);

    final parsed = VoiceFuelParser.parse(currentText);
    if (!mounted || !parsed.hasAnyData) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nie udało się rozpoznać danych tankowania.')),
        );
      }
      return;
    }

    FuelType? type;
    if (parsed.fuelType == 'LPG') {
      type = FuelType.lpg;
    } else if (parsed.fuelType != null) {
      type = FuelType.pb;
    }

    _showEntryFormDialog(
      initialCost: parsed.cost,
      initialLiters: parsed.liters,
      initialType: type,
      initialOdometer: parsed.odometer,
      initialTrip: parsed.tripDistance,
    );
  }

  FilterResult _getFilterResultForType(FuelType type) {
    final typeEntries = _entries.where((e) => e.fuelType == type).toList();
    return applyFuelFilter(typeEntries, _fuelFilterState);
  }

  List<FuelEntry> _entriesForType(FuelType type) {
    return _getFilterResultForType(type).filteredEntries;
  }

  double? _calculateConsumptionForList(List<FuelEntry> list) {
    if (list.isEmpty) return null;

    double totalDistance = 0.0;
    double totalLitersUsed = 0.0;
    bool hasTrip = false;

    for (var entry in list) {
      if (entry.tripDistance != null && entry.tripDistance! > 0) {
        totalDistance += entry.tripDistance!;
        totalLitersUsed += entry.liters;
        hasTrip = true;
      }
    }

    if (hasTrip && totalDistance > 0 && totalLitersUsed > 0) {
      return (totalLitersUsed / totalDistance) * 100;
    }

    final listWithOdo = list.where((e) => e.odometer != null).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (listWithOdo.length < 2) return null;

    double cumulativeOdoDiff = 0.0;
    double cumulativeLiters = 0.0;
    int validCyclesCount = 0;

    int startIndex = 0;
    for (int i = 1; i < listWithOdo.length; i++) {
      if (listWithOdo[i].isFullTank) {
        double odoDiff = listWithOdo[i].odometer! - listWithOdo[startIndex].odometer!;
        if (odoDiff > 0) {
          double litersInCycle = 0.0;
          for (int j = startIndex + 1; j <= i; j++) {
            litersInCycle += listWithOdo[j].liters;
          }
          cumulativeOdoDiff += odoDiff;
          cumulativeLiters += litersInCycle;
          validCyclesCount++;
        }
        startIndex = i;
      }
    }

    if (validCyclesCount > 0 && cumulativeOdoDiff > 0 && cumulativeLiters > 0) {
      return (cumulativeLiters / cumulativeOdoDiff) * 100;
    }

    final newest = listWithOdo.last;
    final oldest = listWithOdo.first;
    double odoDiff = newest.odometer! - oldest.odometer!;
    if (odoDiff > 0) {
      double litersDrawn = 0.0;
      for (int i = 1; i < listWithOdo.length; i++) {
        litersDrawn += listWithOdo[i].liters;
      }
      return (litersDrawn / odoDiff) * 100;
    }

    return null;
  }

  void _deleteEntry(FuelEntry entry) {
    final index = _entries.indexWhere((e) => e.id == entry.id);
    if (index == -1) return;

    setState(() {
      _entries.removeAt(index);
    });
    _saveEntriesToFile();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Usunięto wpis tankowania.'),
        action: SnackBarAction(
          label: 'COFNIJ',
          onPressed: () {
            setState(() {
              _entries.insert(index, entry);
            });
            _saveEntriesToFile();
          },
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _scanReceipt(ImageSource source) async {
    TextRecognizer? recognizer;
    Map<String, dynamic>? parsedData;
    try {
      final image = await ImagePicker().pickImage(source: source);
      if (image == null || !mounted) return;
      setState(() => _isScanning = true);

      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognizedText = await recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      parsedData = _extractFuelData(recognizedText.text);
    } catch (error, stackTrace) {
      debugPrint('Błąd skanowania paragonu: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nie udało się odczytać paragonu.')),
        );
      }
    } finally {
      await recognizer?.close();
      if (mounted) setState(() => _isScanning = false);
    }

    if (!mounted || parsedData == null) return;
    _showEntryFormDialog(
      initialCost: parsedData['cost'] as double?,
      initialLiters: parsedData['liters'] as double?,
      initialType: parsedData['detectedType'] as FuelType?,
      initialDate: parsedData['date'] as DateTime?,
    );
  }

  Map<String, dynamic> _extractFuelData(String text) {
    double? detectedLiters;
    double? detectedCost;
    FuelType detectedType = FuelType.lpg;
    DateTime? detectedDate;

    if (text.toUpperCase().contains('LPG') || text.toUpperCase().contains('AUTOGAZ')) {
      detectedType = FuelType.lpg;
    } else if (text.toUpperCase().contains('PB') || text.toUpperCase().contains('BENZYNA') || text.toUpperCase().contains('95') || text.toUpperCase().contains('98')) {
      detectedType = FuelType.pb;
    }

    final RegExp litersRegex = RegExp(r'(\d+[\.,]\d{1,2})\s*(l|litr|litry|ltr)\b', caseSensitive: false);
    final litersMatch = litersRegex.firstMatch(text);
    if (litersMatch != null) {
      String rawLiters = litersMatch.group(1)!.replaceAll(',', '.');
      detectedLiters = double.tryParse(rawLiters);
    }

    final RegExp costRegex = RegExp(
      r'(?:suma|razem|kwota|suma\s+pln)(?:\s+(?:pln|zł|zl))?\s*[:=]?\s*(\d+[\.,]\d{2})',
      caseSensitive: false,
    );
    
    final costMatch = costRegex.firstMatch(text);
    if (costMatch != null) {
      String rawCost = costMatch.group(1)!.replaceAll(',', '.');
      detectedCost = double.tryParse(rawCost);
    } else {
      final RegExp plnRegex = RegExp(r'(\d+[\.,]\d{2})\s*(?:pln|zł)', caseSensitive: false);
      final plnMatch = plnRegex.firstMatch(text);
      if (plnMatch != null) {
        String rawCost = plnMatch.group(1)!.replaceAll(',', '.');
        detectedCost = double.tryParse(rawCost);
      }
    }

    final regYMD = RegExp(r'\b(20\d{2})[-./](0[1-9]|1[0-2])[-./](0[1-9]|[12]\d|3[01])\b');
    final matchYMD = regYMD.firstMatch(text);

    if (matchYMD != null) {
      int year = int.parse(matchYMD.group(1)!);
      int month = int.parse(matchYMD.group(2)!);
      int day = int.parse(matchYMD.group(3)!);
      detectedDate = DateTime(year, month, day);
    } else {
      final regDMY = RegExp(r'\b(0[1-9]|[12]\d|3[01])[-./](0[1-9]|1[0-2])[-./](20\d{2})\b');
      final matchDMY = regDMY.firstMatch(text);
      if (matchDMY != null) {
        int day = int.parse(matchDMY.group(1)!);
        int month = int.parse(matchDMY.group(2)!);
        int year = int.parse(matchDMY.group(3)!);
        detectedDate = DateTime(year, month, day);
      }
    }

    return {
      'cost': detectedCost,
      'liters': detectedLiters,
      'detectedType': detectedType,
      'date': detectedDate,
    };
  }

  void _showEntryFormDialog({
    FuelEntry? entryToEdit,
    double? initialCost,
    double? initialLiters,
    FuelType? initialType,
    DateTime? initialDate,
    double? initialTrip,
    double? initialOdometer,
  }) {
    final bool isEditing = entryToEdit != null;

    final costController = TextEditingController(
      text: isEditing ? entryToEdit.cost.toStringAsFixed(2) : initialCost?.toStringAsFixed(2) ?? '',
    );
    final litersController = TextEditingController(
      text: isEditing ? entryToEdit.liters.toStringAsFixed(2) : initialLiters?.toStringAsFixed(2) ?? '',
    );
    final tripController = TextEditingController(
      text: isEditing && entryToEdit.tripDistance != null
          ? entryToEdit.tripDistance!.toStringAsFixed(1)
          : (initialTrip != null ? initialTrip.toStringAsFixed(1) : ''),
    );
    final odometerController = TextEditingController(
      text: isEditing && entryToEdit.odometer != null
          ? entryToEdit.odometer!.toStringAsFixed(0)
          : (initialOdometer != null ? initialOdometer.toStringAsFixed(0) : ''),
    );
    
    FuelType selectedType = isEditing ? entryToEdit.fuelType : (initialType ?? FuelType.lpg);
    DateTime selectedDate = isEditing ? entryToEdit.date : (initialDate ?? DateTime.now());
    bool isFullTank = isEditing ? entryToEdit.isFullTank : true;

    double? previousOdometer(DateTime before) {
      final candidates = _entries
          .where((entry) =>
              entry.id != entryToEdit?.id &&
              entry.odometer != null &&
              entry.date.isBefore(before))
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return candidates.isEmpty ? null : candidates.first.odometer;
    }

    double? lastOdometer = previousOdometer(selectedDate);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edytuj wpis' : (initialCost != null ? 'Zweryfikuj dane' : 'Dodaj wpis')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isEditing && initialCost != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.orange),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Popraw wartości w polach, jeśli odczyt zawiera błędy.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!isEditing && initialCost != null) const SizedBox(height: 16),

                SegmentedButton<FuelType>(
                  segments: const [
                    ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
                    ButtonSegment(value: FuelType.pb, label: Text('PB'), icon: Icon(Icons.local_gas_station)),
                  ],
                  selected: {selectedType},
                  onSelectionChanged: (Set<FuelType> newSelection) {
                    setDialogState(() => selectedType = newSelection.first);
                  },
                ),
                const SizedBox(height: 12),
                
                OutlinedButton.icon(
                  onPressed: () async {
                    final pickedDate = await showDatePicker(
                      context: context,
                      initialDate: selectedDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (pickedDate != null) {
                      setDialogState(() {
                        selectedDate = pickedDate;
                        lastOdometer = previousOdometer(selectedDate);
                      });
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text('Data: ${selectedDate.day}.${selectedDate.month}.${selectedDate.year}'),
                ),
                const SizedBox(height: 8),

                SwitchListTile(
                  title: const Text('Tankowanie do pełna', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    isFullTank ? 'Pełny bak (zamknięcie cyklu)' : 'Częściowe (dolewka / nie do pełna)',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  value: isFullTank,
                  onChanged: (bool value) {
                    setDialogState(() => isFullTank = value);
                  },
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),

                TextField(
                  controller: costController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Całkowity koszt (PLN)*', prefixIcon: Icon(Icons.attach_money)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: litersController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Zatankowane litry (L)*', prefixIcon: Icon(Icons.opacity)),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const Text(
                  'Podaj jedno z poniższych, aby liczyć spalanie:',
                  style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: tripController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Dystans odcinka (km)',
                    hintText: 'np. 420 km',
                    prefixIcon: Icon(Icons.add_road),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: odometerController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Stan licznika (km)',
                    hintText: (() {
                      final localOdo = lastOdometer;
                      return (!isEditing && localOdo != null)
                          ? 'Ostatnio: ${localOdo.toStringAsFixed(0)} km'
                          : 'np. 150000 km';
                    })(),
                    prefixIcon: const Icon(Icons.speed),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                double? cost = double.tryParse(costController.text.replaceAll(',', '.'));
                double? liters = double.tryParse(litersController.text.replaceAll(',', '.'));

                if (cost == null || cost <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Koszt musi być większy od zera.')),
                  );
                  return;
                }
                if (liters == null || liters <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Liczba litrów musi być większa od zera.')),
                  );
                  return;
                }

                double? odo = odometerController.text.trim().isNotEmpty
                    ? double.tryParse(odometerController.text.replaceAll(',', '.'))
                    : null;

                double? trip = tripController.text.trim().isNotEmpty
                    ? double.tryParse(tripController.text.replaceAll(',', '.'))
                    : null;

                if (odo != null && odo < 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Stan licznika nie może być ujemny.')),
                  );
                  return;
                }
                if (trip != null && trip <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Dystans musi być większy od zera.')),
                  );
                  return;
                }
                
                lastOdometer = previousOdometer(selectedDate);
                final localOdo = lastOdometer;

                if (odo == null && trip != null && localOdo != null) {
                  odo = localOdo + trip;
                }

                if (trip == null && odo != null && localOdo != null && odo > localOdo) {
                  trip = odo - localOdo;
                }

                final newEntry = FuelEntry(
                  id: isEditing ? entryToEdit.id : null,
                  fuelType: selectedType,
                  cost: cost,
                  liters: liters,
                  odometer: odo,
                  tripDistance: trip,
                  date: selectedDate,
                  isFullTank: isFullTank,
                );

                setState(() {
                  if (isEditing) {
                    final index = _entries.indexWhere((e) => e.id == entryToEdit.id);
                    if (index != -1) {
                      _entries[index] = newEntry;
                    }
                  } else {
                    _entries.add(newEntry);
                  }
                });
                _saveEntriesToFile();
                Navigator.pop(ctx);
              },
              child: const Text('Zatwierdź'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      costController.dispose();
      litersController.dispose();
      tripController.dispose();
      odometerController.dispose();
    });
  }

  void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Dodaj nowe tankowanie',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Skanuj paragon (Aparat)'),
                onTap: () {
                  Navigator.pop(context);
                  _scanReceipt(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Wybierz paragon z galerii'),
                onTap: () {
                  Navigator.pop(context);
                  _scanReceipt(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.mic),
                title: const Text('Wprowadź głosem'),
                onTap: () {
                  Navigator.pop(context);
                  _startVoiceEntry();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Dodaj ręcznie'),
                onTap: () {
                  Navigator.pop(context);
                  _showEntryFormDialog();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.file_upload),
                title: const Text('Importuj z JSON'),
                onTap: () {
                  Navigator.pop(context);
                  _importJson();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fuel App - Zarządzanie paliwem'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'LPG', icon: Icon(Icons.propane_tank)),
            Tab(text: 'Benzyna (PB)', icon: Icon(Icons.local_gas_station)),
            Tab(text: 'Wykresy', icon: Icon(Icons.bar_chart)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export_json') {
                _exportJson();
              } else if (value == 'export_xlsx') {
                _exportXlsx();
              } else if (value == 'import_xlsx') {
                _importXlsx();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(value: 'export_json', child: Text('Eksportuj kopia zapasowa (JSON)')),
              const PopupMenuItem(value: 'export_xlsx', child: Text('Eksportuj do XLSX')),
              const PopupMenuItem(value: 'import_xlsx', child: Text('Importuj z XLSX')),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isScanning
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Skanowanie paragonu przez ML Kit...'),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildFuelTab(FuelType.lpg),
                    _buildFuelTab(FuelType.pb),
                    _buildChartsTab(),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddOptions,
        tooltip: 'Dodaj tankowanie',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildFuelTab(FuelType type) {
    final filterResult = _getFilterResultForType(type);
    final entries = filterResult.filteredEntries;
    final avgConsumption = _calculateConsumptionForList(entries);

    return Column(
      children: [
        FuelFilterWidget(
          initialFilterState: _fuelFilterState,
          onFilterChanged: (newState) {
            setState(() {
              _fuelFilterState = newState;
            });
          },
        ),
        if (filterResult.infoMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
            child: Row(
              children: [
                Icon(
                  filterResult.isDataLimited ? Icons.info_outline : Icons.check_circle_outline,
                  size: 14,
                  color: filterResult.isDataLimited ? Colors.orange : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    filterResult.infoMessage,
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: filterResult.isDataLimited ? Colors.orange.shade800 : Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Card(
          margin: const EdgeInsets.all(12),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStatItem(
                  'Średnie spalanie (${type.label})',
                  avgConsumption != null ? '${avgConsumption.toStringAsFixed(2)} L/100km' : 'Brak danych',
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'Brak wpisów dla ${type.label.toLowerCase()}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Dismissible(
                      key: Key(entry.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red,
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Potwierdzenie'),
                            content: const Text('Czy na pewno chcesz usunąć ten wpis?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Anuluj'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Usuń', style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                        );
                      },
                      onDismissed: (direction) {
                        _deleteEntry(entry);
                      },
                      child: Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: type == FuelType.lpg ? Colors.amber.shade700 : Colors.blue.shade700,
                            child: Icon(
                              type == FuelType.lpg ? Icons.propane_tank : Icons.local_gas_station,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            '${entry.cost.toStringAsFixed(2)} PLN (${entry.liters.toStringAsFixed(2)} L)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'Data: ${entry.date.day}.${entry.date.month}.${entry.date.year}'
                            '${!entry.isFullTank ? ' • [Nie do pełna]' : ''}'
                            '${entry.tripDistance != null ? ' • Dystans: ${entry.tripDistance} km' : ''}'
                            '${entry.odometer != null ? ' • Licznik: ${entry.odometer} km' : ''}'
                            '${entry.singleConsumption != null ? '\nSpalanie: ${entry.singleConsumption!.toStringAsFixed(2)} L/100km' : ''}',
                          ),
                          isThreeLine: entry.singleConsumption != null || entry.odometer != null || !entry.isFullTank,
                          trailing: IconButton(
                            icon: const Icon(Icons.edit, color: Colors.grey),
                            onPressed: () => _showEntryFormDialog(entryToEdit: entry),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildChartsTab() {
    List<FuelEntry> chartEntries = _entriesForType(_chartFuelType);

    final Map<String, List<FuelEntry>> monthlyGroups = {};
    for (var entry in chartEntries) {
      final monthKey = '${entry.date.year}-${entry.date.month.toString().padLeft(2, '0')}';
      monthlyGroups.putIfAbsent(monthKey, () => []).add(entry);
    }

    final Map<String, double> monthlyAverages = {};
    monthlyGroups.forEach((month, list) {
      final avg = _calculateConsumptionForList(list);
      if (avg != null) {
        monthlyAverages[month] = avg;
      }
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<FuelType>(
            segments: const [
              ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
              ButtonSegment(value: FuelType.pb, label: Text('Benzyna (PB)'), icon: Icon(Icons.local_gas_station)),
            ],
            selected: {_chartFuelType},
            onSelectionChanged: (Set<FuelType> newSelection) {
              setState(() => _chartFuelType = newSelection.first);
            },
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.filter_list, size: 18, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Wykres korzysta z aktywnego filtra z zakładek paliwowych.',
                    style: TextStyle(fontSize: 12, color: Colors.teal.shade800),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Średnie miesięczne spalanie (${_chartFuelType.label})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: monthlyAverages.isEmpty
                  ? const SizedBox(
                      height: 200,
                      child: Center(
                        child: Text(
                          'Brak wystarczających danych do wygenerowania wykresu dla wybranych kryteriów.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : SizedBox(
                      height: 250,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final chartWidth = monthlyAverages.length * 64.0 >
                                  constraints.maxWidth
                              ? monthlyAverages.length * 64.0
                              : constraints.maxWidth;
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: chartWidth,
                              child: CustomPaint(
                                painter: MonthlyChartPainter(monthlyAverages),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          if (monthlyAverages.isNotEmpty) ...[
            const Text(
              'Szczegóły miesięczne:',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...monthlyAverages.entries.map((entry) {
              final parts = entry.key.split('-');
              final yearMonthStr = '${parts[1]}.${parts[0]}';
              return ListTile(
                dense: true,
                title: Text('Miesiąc: $yearMonthStr'),
                trailing: Text(
                  '${entry.value.toStringAsFixed(2)} L/100km',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              );
            }),
          ]
        ],
      ),
    );
  }

  Widget _buildStatItem(String title, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class MonthlyChartPainter extends CustomPainter {
  final Map<String, double> monthlyData;

  MonthlyChartPainter(this.monthlyData);

  @override
  void paint(Canvas canvas, Size size) {
    if (monthlyData.isEmpty) return;

    final sortedKeys = monthlyData.keys.toList()..sort();
    final count = sortedKeys.length;
    if (count == 0) return;

    double maxVal = 0;
    for (var val in monthlyData.values) {
      if (val > maxVal) maxVal = val;
    }
    if (maxVal == 0) maxVal = 10;
    maxVal = maxVal * 1.25;

    final double chartWidth = size.width - 40;
    final double chartHeight = size.height - 40;
    final double barWidth = (chartWidth / count) * 0.55;
    final double spacing = (chartWidth / count) * 0.45;

    final paint = Paint()..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;

    canvas.drawLine(Offset(30, chartHeight), Offset(size.width - 10, chartHeight), axisPaint);

    for (int i = 0; i < count; i++) {
      final key = sortedKeys[i];
      final val = monthlyData[key] ?? 0.0;

      final double barHeight = (val / maxVal) * chartHeight;
      final double x = 35 + i * (barWidth + spacing);
      final double y = chartHeight - barHeight;

      paint.color = Colors.teal.shade400;
      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), paint);

      final textSpanVal = TextSpan(
        text: val.toStringAsFixed(1),
        style: const TextStyle(fontSize: 10, color: Colors.black87),
      );
      final tpVal = TextPainter(text: textSpanVal, textDirection: TextDirection.ltr);
      tpVal.layout();
      tpVal.paint(canvas, Offset(x + (barWidth - tpVal.width) / 2, y - 14));

      final parts = key.split('-');
      final label = '${parts[1]}.${parts[0].substring(2)}';
      final textSpanLabel = TextSpan(
        text: label,
        style: const TextStyle(fontSize: 9, color: Colors.grey),
      );
      final tpLabel = TextPainter(text: textSpanLabel, textDirection: TextDirection.ltr);
      tpLabel.layout();
      tpLabel.paint(canvas, Offset(x + (barWidth - tpLabel.width) / 2, chartHeight + 6));
    }
  }

  @override
  bool shouldRepaint(covariant MonthlyChartPainter oldDelegate) {
    return !mapEquals(oldDelegate.monthlyData, monthlyData);
  }
}
