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
import 'package:speech_to_text/speech_to_text.dart' as stt;

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

enum ChartPeriodOption { all, year }

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
              firstDate: DateTime(2026, 1, 1),
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
  late TabController _tabController;

  FuelType _chartFuelType = FuelType.lpg;
  ChartPeriodOption _lpgChartPeriod = ChartPeriodOption.all;
  ChartPeriodOption _pbChartPeriod = ChartPeriodOption.all;
  FuelFilterState _fuelFilterState = FuelFilterState();
  final stt.SpeechToText _speech = stt.SpeechToText();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 0);
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadEntriesFromFile();
    await _checkAndPerformMonthlyBackup();
  }

  @override
  void dispose() {
    _speech.stop();
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

  FilterResult _getFilterResultForType(FuelType type) {
    final typeEntries = _entries.where((e) => e.fuelType == type).toList();
    return applyFuelFilter(typeEntries, _fuelFilterState);
  }

  List<FuelEntry> _entriesForType(FuelType type) {
    return _getFilterResultForType(type).filteredEntries;
  }

  List<FuelEntry> _chartEntriesForType(FuelType type) {
    final allEntries = _entries.where((e) => e.fuelType == type).toList();
    final period = type == FuelType.lpg ? _lpgChartPeriod : _pbChartPeriod;
    if (period == ChartPeriodOption.all) return allEntries;

    final now = _dateOnly(DateTime.now());
    final cutoff = now.subtract(const Duration(days: 365));
    return allEntries.where((entry) => !entry.date.isBefore(cutoff)).toList();
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

    final normalized = text
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
    final upper = normalized.toUpperCase();

    // Typ paliwa: Fuel App ma obecnie dwa typy — LPG oraz PB.
    // PB95/PB98/benzyna są więc mapowane do istniejącego typu PB.
    if (RegExp(r'\b(LPG|AUTOGAZ|GAZ)\b', caseSensitive: false).hasMatch(upper)) {
      detectedType = FuelType.lpg;
    } else if (RegExp(r'\b(PB\s*(?:95|98)?|PB95|PB98|BENZYNA)\b', caseSensitive: false).hasMatch(upper)) {
      detectedType = FuelType.pb;
    }

    double? parseNumber(String raw) {
      final cleaned = raw
          .replaceAll(' ', '')
          .replaceAll(',', '.')
          .replaceAll(RegExp(r'[^0-9.]'), '');
      return double.tryParse(cleaned);
    }

    // Litry: obsługujemy polski przecinek i typowe warianty OCR: L, litr, litry, litra.
    final litersRegex = RegExp(
      r'(\d{1,4}(?:[\.,]\d{1,3})?)\s*(?:l|ltr|litr|litry|litra|litrów)\b',
      caseSensitive: false,
    );
    final litersMatch = litersRegex.firstMatch(normalized);
    if (litersMatch != null) {
      detectedLiters = parseNumber(litersMatch.group(1)!);
    }

    // Kwota końcowa: najpierw szukamy etykiet, które jednoznacznie oznaczają
    // sumę do zapłaty. Dzięki temu cena jednostkowa np. "6,49 zł/l" nie zostanie
    // potraktowana jako koszt całego tankowania.
    final totalLabels = RegExp(
      r'\b(RAZEM|SUMA\s+PLN|SUMA|DO\s+ZAPŁATY|DO\s+ZAPL?ATY|ZAPŁACONO|ZAPLACONO|NALEŻNOŚĆ|NALEZNOSC|KWOTA\s+DO\s+ZAPŁATY|KWOTA\s+DO\s+ZAPL?ATY)\b',
      caseSensitive: false,
    );
    final amountRegex = RegExp(r'(?<!\d)(\d{1,6}[\.,]\d{2})(?!\d)');

    double? labeledTotal;
    for (final line in normalized.split(RegExp(r'[\r\n]+'))) {
      if (!totalLabels.hasMatch(line)) continue;
      final matches = amountRegex.allMatches(line).toList();
      for (final match in matches) {
        final after = line.substring(match.end).toLowerCase();
        // Nie przyjmuj wartości opisanej jako cena za litr / jednostkę.
        if (RegExp(r'(?:/\s*l|za\s*litr|za\s*1\s*l)').hasMatch(after)) continue;
        final value = parseNumber(match.group(1)!);
        if (value != null && value > 0) {
          labeledTotal = value;
        }
      }
      if (labeledTotal != null) break;
    }

    detectedCost = labeledTotal;

    // Drugi poziom: kwota z walutą, ale z pominięciem ceny jednostkowej za litr.
    if (detectedCost == null) {
      final currencyRegex = RegExp(
        r'(?<!\d)(\d{1,6}[\.,]\d{2})\s*(?:PLN|ZŁ|ZL)(?!\s*/\s*L)(?!\s*ZA\s*LITR)',
        caseSensitive: false,
      );
      final candidates = <double>[];
      for (final match in currencyRegex.allMatches(normalized)) {
        final value = parseNumber(match.group(1)!);
        if (value != null && value > 0) candidates.add(value);
      }
      if (candidates.isNotEmpty) {
        // Przy braku jednoznacznej etykiety wybieramy największą kwotę z walutą.
        // Typowy paragon ma cenę jednostkową i kwotę końcową; większa wartość
        // odpowiada wtedy całemu tankowaniu.
        detectedCost = candidates.reduce((a, b) => a > b ? a : b);
      }
    }

    // Trzeci poziom: awaryjnie szukamy kwot przy etykietach "kwota"/"cena",
    // nadal ignorując zapis ceny za litr.
    if (detectedCost == null) {
      final fallbackLabel = RegExp(
        r'\b(KWOTA|KOSZT|WARTOŚĆ|WARTOSC)\b[^\r\n]{0,30}?([0-9]{1,6}[\.,][0-9]{2})',
        caseSensitive: false,
      );
      for (final match in fallbackLabel.allMatches(normalized)) {
        final line = match.group(0)!;
        if (RegExp(r'(?:/\s*l|za\s*litr|za\s*1\s*l)', caseSensitive: false).hasMatch(line)) continue;
        final value = parseNumber(match.group(2)!);
        if (value != null && value > 0) {
          detectedCost = value;
          break;
        }
      }
    }

    // Data: YYYY-MM-DD / YYYY.MM.DD / YYYY/MM/DD albo DD-MM-YYYY itd.
    final regYMD = RegExp(r'\b(20\d{2})[-./](0[1-9]|1[0-2])[-./](0[1-9]|[12]\d|3[01])\b');
    final matchYMD = regYMD.firstMatch(normalized);
    if (matchYMD != null) {
      final year = int.parse(matchYMD.group(1)!);
      final month = int.parse(matchYMD.group(2)!);
      final day = int.parse(matchYMD.group(3)!);
      detectedDate = DateTime(year, month, day);
    } else {
      final regDMY = RegExp(r'\b(0[1-9]|[12]\d|3[01])[-./](0[1-9]|1[0-2])[-./](20\d{2})\b');
      final matchDMY = regDMY.firstMatch(normalized);
      if (matchDMY != null) {
        final day = int.parse(matchDMY.group(1)!);
        final month = int.parse(matchDMY.group(2)!);
        final year = int.parse(matchDMY.group(3)!);
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

  Map<String, dynamic> _parseVoiceFuelData(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll('ł', 'l')
        .replaceAll('ó', 'o')
        .replaceAll('ą', 'a')
        .replaceAll('ę', 'e')
        .replaceAll('ś', 's')
        .replaceAll('ć', 'c')
        .replaceAll('ź', 'z')
        .replaceAll('ż', 'z')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    FuelType? detectedType;
    if (RegExp(r'\b(lpg|gaz|autogaz)\b').hasMatch(normalized)) {
      detectedType = FuelType.lpg;
    } else if (RegExp(r'\b(pb|pb95|pb98|benzyna|95|98)\b').hasMatch(normalized)) {
      detectedType = FuelType.pb;
    }

    double? extractNumber(String value) {
      final cleaned = value
          .replaceAll(RegExp(r'(?<=\d)[\s.](?=\d)', caseSensitive: false), '')
          .replaceAll(' ', '')
          .replaceAll(',', '.');
      return double.tryParse(cleaned);
    }

    double? liters;
    final litersMatch = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(?:l|litrow|litry|litr|litra)\b',
    ).firstMatch(normalized);
    if (litersMatch != null) {
      liters = extractNumber(litersMatch.group(1)!);
    }

    double? cost;
    final costMatch = RegExp(
      r'(?:za|kwota|koszt|razem|suma|zaplacilem|zaplacono|do zaplaty)\s*(?:to|jest)?\s*(\d+(?:[.,]\d+)?)\s*(?:zl|pln|zlotych|zloty)?\b',
    ).firstMatch(normalized);
    if (costMatch != null) {
      cost = extractNumber(costMatch.group(1)!);
    } else {
      final currencyMatch = RegExp(
        r'(\d+(?:[.,]\d+)?)\s*(?:zl|pln|zlotych|zloty)\b',
      ).firstMatch(normalized);
      if (currencyMatch != null) {
        cost = extractNumber(currencyMatch.group(1)!);
      }
    }

    double? odometer;
    final odometerMatch = RegExp(
      r'(?:przebieg|licznik|stan licznika)\s*(?:to|jest)?\s*(\d+(?:[.,]\d+)?)',
    ).firstMatch(normalized);
    if (odometerMatch != null) {
      odometer = extractNumber(odometerMatch.group(1)!);
    }

    double? trip;
    final tripMatch = RegExp(
      r'(?:dystans|odcinek|kilometrow|km)\s*(?:to|jest)?\s*(\d+(?:[.,]\d+)?)',
    ).firstMatch(normalized);
    if (tripMatch != null) {
      trip = extractNumber(tripMatch.group(1)!);
    }

    DateTime? date;
    final dateMatch = RegExp(
      r'\b(\d{1,2})[./-](\d{1,2})(?:[./-](\d{4}))?\b',
    ).firstMatch(normalized);
    if (dateMatch != null) {
      final day = int.tryParse(dateMatch.group(1)!);
      final month = int.tryParse(dateMatch.group(2)!);
      final year = int.tryParse(dateMatch.group(3) ?? '') ?? DateTime.now().year;
      if (day != null && month != null && day >= 1 && day <= 31 && month >= 1 && month <= 12) {
        date = DateTime(year, month, day);
      }
    }

    return {
      'fuelType': detectedType,
      'liters': liters,
      'cost': cost,
      'odometer': odometer,
      'trip': trip,
      'date': date,
    };
  }

  Future<void> _showVoiceEntryDialog() async {
    final available = await _speech.initialize(
      onError: (error) => debugPrint('Błąd rozpoznawania mowy: ${error.errorMsg}'),
      onStatus: (status) => debugPrint('Status rozpoznawania mowy: $status'),
    );

    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rozpoznawanie mowy nie jest dostępne na tym urządzeniu.'),
        ),
      );
      return;
    }

    String recognizedText = '';
    bool isListening = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> listen() async {
              setDialogState(() => isListening = true);
              await _speech.listen(
                localeId: 'pl_PL',
                listenMode: stt.ListenMode.confirmation,
                listenFor: const Duration(seconds: 30),
                pauseFor: const Duration(seconds: 3),
                onResult: (result) {
                  setDialogState(() {
                    recognizedText = result.recognizedWords;
                    isListening = !result.finalResult;
                  });
                },
              );
            }

            Future<void> stopListening() async {
              await _speech.stop();
              if (context.mounted) {
                setDialogState(() => isListening = false);
              }
            }

            final parsed = _parseVoiceFuelData(recognizedText);
            final hasData = parsed['fuelType'] != null ||
                parsed['liters'] != null ||
                parsed['cost'] != null ||
                parsed['odometer'] != null ||
                parsed['trip'] != null ||
                parsed['date'] != null;

            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.mic),
                  SizedBox(width: 8),
                  Expanded(child: Text('Wprowadzanie głosowe')),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isListening
                          ? 'Mów po polsku. Przykład: „Zatankowałem LPG, 42 litry, za 125 zł, przebieg 184500”.'
                          : 'Naciśnij mikrofon i podaj dane tankowania.',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        recognizedText.isEmpty ? 'Tutaj pojawi się rozpoznany tekst.' : recognizedText,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                    if (hasData) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Rozpoznane dane zostaną przekazane do formularza do sprawdzenia. Nic nie zostanie zapisane automatycznie.',
                        style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _speech.stop();
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: const Text('Anuluj'),
                ),
                if (recognizedText.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await _speech.stop();
                      setDialogState(() {
                        recognizedText = '';
                        isListening = false;
                      });
                    },
                    child: const Text('Wyczyść'),
                  ),
                FilledButton.icon(
                  onPressed: isListening ? stopListening : listen,
                  icon: Icon(isListening ? Icons.stop : Icons.mic),
                  label: Text(isListening ? 'Zatrzymaj' : 'Mów'),
                ),
                if (hasData)
                  ElevatedButton(
                    onPressed: () async {
                      await _speech.stop();
                      final data = _parseVoiceFuelData(recognizedText);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      if (!mounted) return;
                      _showEntryFormDialog(
                        initialCost: data['cost'] as double?,
                        initialLiters: data['liters'] as double?,
                        initialType: data['fuelType'] as FuelType?,
                        initialDate: data['date'] as DateTime?,
                        initialTrip: data['trip'] as double?,
                        initialOdometer: data['odometer'] as double?,
                      );
                    },
                    child: const Text('Użyj danych'),
                  ),
              ],
            );
          },
        );
      },
    );

    await _speech.stop();
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
                      firstDate: DateTime(2026, 1, 1),
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
                title: const Text('Wprowadź głosowo'),
                subtitle: const Text('Mów po polsku — dane trafią do formularza do sprawdzenia'),
                onTap: () {
                  Navigator.pop(context);
                  _showVoiceEntryDialog();
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
        title: const Center(child: Text('Fuel App')),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'LPG', icon: Icon(Icons.propane_tank)),
            Tab(text: 'Benzyna (PB)', icon: Icon(Icons.local_gas_station)),
            Tab(text: 'Wykresy', icon: Icon(Icons.bar_chart)),
            Tab(text: 'Stats', icon: Icon(Icons.analytics)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export_json') {
                _exportJson();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'export_json',
                child: Text('Eksportuj kopia zapasowa (JSON)'),
              ),
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
                    const SizedBox.shrink(),
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
    final chartEntries = _chartEntriesForType(_chartFuelType);

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

    final currentPeriod = _chartFuelType == FuelType.lpg
        ? _lpgChartPeriod
        : _pbChartPeriod;

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
          const Text(
            'Zakres danych wykresu',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ChartPeriodOption>(
            segments: const [
              ButtonSegment(value: ChartPeriodOption.year, label: Text('Ostatnie 12M')),
              ButtonSegment(value: ChartPeriodOption.all, label: Text('Wszystko')),
            ],
            selected: {currentPeriod},
            onSelectionChanged: (Set<ChartPeriodOption> newSelection) {
              setState(() {
                if (_chartFuelType == FuelType.lpg) {
                  _lpgChartPeriod = newSelection.first;
                } else {
                  _pbChartPeriod = newSelection.first;
                }
              });
            },
          ),
          const SizedBox(height: 8),
          Text(
            currentPeriod == ChartPeriodOption.all
                ? 'Wszystko — od początku gromadzenia danych.'
                : 'Ostatnie 12M — ostatnie 365 dni liczone od dzisiaj.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
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
                          'Brak wystarczających danych do wygenerowania wykresu dla wybranego zakresu.',
                          style: TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : SizedBox(
                      height: 250,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final chartWidth = monthlyAverages.length * 64.0 > constraints.maxWidth
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
