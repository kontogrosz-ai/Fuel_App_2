import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as material;
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:excel/excel.dart' hide Border, TextSpan;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FuelApp());
}

// Kompatybilność z domyślnym testem Fluttera, który oczekuje MyApp.
class MyApp extends FuelApp {
  const MyApp({super.key});
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
        return 'PB';
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
DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

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
  final sorted = List<FuelEntry>.from(allEntries)..sort((a, b) => b.date.compareTo(a.date));
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
      if (filterState.countOption != CountFilterOption.cAll && sorted.length < targetCount) {
        limited = true;
        info += ' (Dostępne tylko ${sorted.length} z żądanych $targetCount tankowań)';
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
        info += ' (Osiągnięto maksymalny dostępny dystans: ${accumulatedKm.toStringAsFixed(0)} km)';
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
      info = 'Zakres: ${start.day}.${start.month}.${start.year} - ${range.end.day}.${range.end.month}.${range.end.year}';
      break;
  }

  return FilterResult(
    filteredEntries: result,
    isDataLimited: limited,
    infoMessage: info,
  );
}

// --- KOMPONENT UI FILTRA ---
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
                _buildFilterTile(mode: FilterMainMode.time, label: 'Czas', icon: Icons.access_time),
                _buildFilterTile(mode: FilterMainMode.count, label: 'Ilość', icon: Icons.format_list_numbered),
                _buildFilterTile(mode: FilterMainMode.distance, label: 'Dystans', icon: Icons.map),
                _buildFilterTile(mode: FilterMainMode.custom, label: 'Własny', icon: Icons.date_range),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _buildSubOptionsChips()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterTile({required FilterMainMode mode, required String label, required IconData icon}) {
    final isSelected = _currentFilter.mainMode == mode;
    final theme = Theme.of(context);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
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
                color: isSelected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface,
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

    Widget buildChip<T>(String label, T option, T currentOption, void Function(T) onSelected) {
      return Padding(
        padding: const EdgeInsets.only(right: 8.0),
        child: ChoiceChip(
          label: Text(label),
          selected: currentOption == option,
          onSelected: (selected) {
            if (selected) onSelected(option);
          },
        ),
      );
    }

    if (_currentFilter.mainMode == FilterMainMode.time) {
      final labels = {
        TimeFilterOption.month1: '1 miesiąc',
        TimeFilterOption.months3: '3 miesiące',
        TimeFilterOption.months6: '6 miesięcy',
        TimeFilterOption.year1: '1 rok',
        TimeFilterOption.all: 'Wszystko',
      };
      for (var option in TimeFilterOption.values) {
        chips.add(buildChip(labels[option]!, option, _currentFilter.timeOption, 
            (val) => _update(_currentFilter.copyWith(timeOption: val))));
      }
    } else if (_currentFilter.mainMode == FilterMainMode.count) {
      final labels = {
        CountFilterOption.c5: 'Ostatnie 5',
        CountFilterOption.c10: 'Ostatnie 10',
        CountFilterOption.c20: 'Ostatnie 20',
        CountFilterOption.cAll: 'Wszystkie',
      };
      for (var option in CountFilterOption.values) {
        chips.add(buildChip(labels[option]!, option, _currentFilter.countOption, 
            (val) => _update(_currentFilter.copyWith(countOption: val))));
      }
    } else if (_currentFilter.mainMode == FilterMainMode.distance) {
      final labels = {
        DistanceFilterOption.km500: '500 km',
        DistanceFilterOption.km1000: '1000 km',
        DistanceFilterOption.km5000: '5000 km',
        DistanceFilterOption.kmAll: 'Cały dystans',
      };
      for (var option in DistanceFilterOption.values) {
        chips.add(buildChip(labels[option]!, option, _currentFilter.distanceOption, 
            (val) => _update(_currentFilter.copyWith(distanceOption: val))));
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
      title: 'Fuel_App_2.0',
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
  final ValueNotifier<List<FuelEntry>> _entriesNotifier = ValueNotifier([]);
  final ValueNotifier<FuelFilterState> _fuelFilterNotifier = ValueNotifier(FuelFilterState());
  final ValueNotifier<FuelFilterState> _chartsFilterNotifier = ValueNotifier(FuelFilterState());
  final ValueNotifier<FuelType> _chartFuelTypeNotifier = ValueNotifier(FuelType.lpg);

  bool _isScanning = false;
  bool _isLoading = true;
  late TabController _tabController;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;

  FilterResult? _lpgFuelTabCache;
  FilterResult? _pbFuelTabCache;
  double? _lpgFuelTabAvg;
  double? _pbFuelTabAvg;

  FilterResult? _chartFilterCache;
  Map<String, double> _chartDataCache = {};

  double _statsTotalCostAll = 0.0;
  double _statsTotalLpgCost = 0.0;
  double _statsTotalPbCost = 0.0;
  double _statsTotalLpgLiters = 0.0;
  double _statsTotalPbLiters = 0.0;
  double? _statsAvgLpgCons;
  double? _statsAvgPbCons;
  int _statsLpgCount = 0;
  int _statsPbCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 0);
    
    _entriesNotifier.addListener(_onEntriesChanged);
    _fuelFilterNotifier.addListener(_updateFuelTabCache);
    _chartsFilterNotifier.addListener(_updateChartCache);
    _chartFuelTypeNotifier.addListener(_updateChartCache);
    
    _initialize();
  }

  void _onEntriesChanged() {
    _updateFuelTabCache();
    _updateChartCache();
    _updateGlobalStatsCache();
  }

  void _updateFuelTabCache() {
    final entries = _entriesNotifier.value;
    final lpgEntries = entries.where((e) => e.fuelType == FuelType.lpg).toList();
    final pbEntries = entries.where((e) => e.fuelType == FuelType.pb).toList();

    _lpgFuelTabCache = applyFuelFilter(lpgEntries, _fuelFilterNotifier.value);
    _pbFuelTabCache = applyFuelFilter(pbEntries, _fuelFilterNotifier.value);
    
    _lpgFuelTabAvg = _calculateConsumptionForList(_lpgFuelTabCache!.filteredEntries);
    _pbFuelTabAvg = _calculateConsumptionForList(_pbFuelTabCache!.filteredEntries);
  }

  void _updateChartCache() {
    final entries = _entriesNotifier.value;
    final type = _chartFuelTypeNotifier.value;
    final typeEntries = entries.where((e) => e.fuelType == type).toList();
    
    _chartFilterCache = applyFuelFilter(typeEntries, _chartsFilterNotifier.value);
    
    final Map<String, List<FuelEntry>> monthlyGroups = {};
    for (var entry in _chartFilterCache!.filteredEntries) {
      final monthKey = '${entry.date.year}-${entry.date.month.toString().padLeft(2, '0')}';
      monthlyGroups.putIfAbsent(monthKey, () => []).add(entry);
    }

    final Map<String, double> newAverages = {};
    monthlyGroups.forEach((month, list) {
      final avg = _calculateConsumptionForList(list);
      if (avg != null) {
        newAverages[month] = avg;
      }
    });
    _chartDataCache = newAverages;
  }

  void _updateGlobalStatsCache() {
    final entries = _entriesNotifier.value;
    final lpgEntries = entries.where((e) => e.fuelType == FuelType.lpg).toList();
    final pbEntries = entries.where((e) => e.fuelType == FuelType.pb).toList();

    _statsTotalLpgCost = lpgEntries.fold(0.0, (sum, e) => sum + e.cost);
    _statsTotalPbCost = pbEntries.fold(0.0, (sum, e) => sum + e.cost);
    _statsTotalCostAll = _statsTotalLpgCost + _statsTotalPbCost;

    _statsTotalLpgLiters = lpgEntries.fold(0.0, (sum, e) => sum + e.liters);
    _statsTotalPbLiters = pbEntries.fold(0.0, (sum, e) => sum + e.liters);

    _statsAvgLpgCons = _calculateConsumptionForList(lpgEntries);
    _statsAvgPbCons = _calculateConsumptionForList(pbEntries);

    _statsLpgCount = lpgEntries.length;
    _statsPbCount = pbEntries.length;
  }

  Future<void> _initialize() async {
    await _loadEntriesFromFile();
    await _checkAndPerformMonthlyBackup();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _entriesNotifier.dispose();
    _fuelFilterNotifier.dispose();
    _chartsFilterNotifier.dispose();
    _chartFuelTypeNotifier.dispose();
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
      _entriesNotifier.value = loaded; 
      setState(() => _isLoading = false);
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
      final jsonList = _entriesNotifier.value.map((entry) => entry.toJson()).toList();
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
      if (!await file.exists() || _entriesNotifier.value.isEmpty) {
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
                  _entriesNotifier.value = importedEntries;
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
                  final newList = List<FuelEntry>.from(_entriesNotifier.value);
                  for (var entry in importedEntries) {
                    if (!newList.any((e) => e.id == entry.id)) {
                      newList.add(entry);
                    }
                  }
                  _entriesNotifier.value = newList;
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

  Future<void> _importExcel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();
        final excel = Excel.decodeBytes(bytes);

        List<FuelEntry> importedEntries = [];

        for (var tableKey in excel.tables.keys) {
          final table = excel.tables[tableKey];
          if (table == null) continue;

          FuelType type = FuelType.lpg;
          if (tableKey.toUpperCase().contains('PB') || tableKey.toUpperCase().contains('BENZYNA')) {
            type = FuelType.pb;
          }

          for (int i = 1; i < table.rows.length; i++) {
            final row = table.rows[i];
            if (row.isEmpty || row[0] == null) continue;

            final firstCellVal = row[0]?.value?.toString() ?? '';
            if (firstCellVal.isEmpty || firstCellVal == 'PODSUMOWANIE' || firstCellVal == '-') {
              continue;
            }

            DateTime? entryDate;
            final cleanStr = firstCellVal.trim();
            if (cleanStr.contains('.')) {
              final parts = cleanStr.split('.');
              if (parts.length == 3) {
                final day = int.tryParse(parts[0]);
                final month = int.tryParse(parts[1]);
                final year = int.tryParse(parts[2]);
                if (day != null && month != null && year != null) {
                  entryDate = DateTime(year, month, day);
                }
              }
            } else if (cleanStr.contains('-')) {
              entryDate = DateTime.tryParse(cleanStr);
            } else if (cleanStr.contains('/')) {
              final parts = cleanStr.split('/');
              if (parts.length == 3) {
                final day = int.tryParse(parts[0]);
                final month = int.tryParse(parts[1]);
                final year = int.tryParse(parts[2]);
                if (day != null && month != null && year != null) {
                  entryDate = DateTime(year, month, day);
                }
              }
            }

            if (entryDate == null) continue;

            double? tripDistance;
            if (row.length > 1 && row[1]?.value != null) {
              final valStr = row[1]!.value.toString();
              if (valStr != '-' && valStr.isNotEmpty) {
                tripDistance = double.tryParse(valStr.replaceAll(',', '.'));
              }
            }

            double? odometer;
            if (row.length > 2 && row[2]?.value != null) {
              final valStr = row[2]!.value.toString();
              if (valStr != '-' && valStr.isNotEmpty) {
                odometer = double.tryParse(valStr.replaceAll(',', '.'));
              }
            }

            double cost = 0.0;
            if (row.length > 3 && row[3]?.value != null) {
              final valStr = row[3]!.value.toString();
              cost = double.tryParse(valStr.replaceAll(',', '.')) ?? 0.0;
            }

            double liters = 0.0;
            if (row.length > 4 && row[4]?.value != null) {
              final valStr = row[4]!.value.toString();
              liters = double.tryParse(valStr.replaceAll(',', '.')) ?? 0.0;
            }

            if (cost > 0 && liters > 0) {
              importedEntries.add(FuelEntry(
                fuelType: type,
                cost: cost,
                liters: liters,
                odometer: odometer,
                tripDistance: tripDistance,
                date: entryDate,
                isFullTank: true,
              ));
            }
          }
        }

        if (importedEntries.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nie znaleziono poprawnych danych w pliku Excel.')),
          );
          return;
        }

        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import danych z Excela'),
            content: Text('Wczytano ${importedEntries.length} wpisów z pliku Excel. Co chcesz zrobić?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
              ),
              OutlinedButton(
                onPressed: () {
                  _entriesNotifier.value = importedEntries;
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Zastąpiono bazę danymi z pliku Excel.')),
                    );
                  }
                },
                child: const Text('Zastąp obecne'),
              ),
              ElevatedButton(
                onPressed: () {
                  final newList = List<FuelEntry>.from(_entriesNotifier.value);
                  for (var entry in importedEntries) {
                    // Zastosowana poprawka z poprawną nazwą zmiennej exists[cite: 6]
                    bool exists = newList.any((e) => 
                      e.date.year == entry.date.year &&
                      e.date.month == entry.date.month &&
                      e.date.day == entry.date.day &&
                      e.cost == entry.cost &&
                      e.liters == entry.liters
                    );
                    if (!exists) {
                      newList.add(entry);
                    }
                  }
                  _entriesNotifier.value = newList;
                  _saveEntriesToFile();
                  Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Połączono dane z pliku Excel pomyślnie.')),
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
        SnackBar(content: Text('Błąd podczas importu pliku Excel: $e')),
      );
    }
  }

  Map<String, dynamic> _extractFuelDataFromSpeech(String text) {
    double? detectedLiters;
    double? detectedCost;
    FuelType detectedType = FuelType.lpg;
    double? tripDistance;
    double? odometer;

    final lowerText = text.toLowerCase();

    if (lowerText.contains('pb') || lowerText.contains('benzyn') || lowerText.contains('95') || lowerText.contains('98')) {
      detectedType = FuelType.pb;
    } else if (lowerText.contains('lpg') || lowerText.contains('gaz') || lowerText.contains('autogaz')) {
      detectedType = FuelType.lpg;
    }

    final costMatch = RegExp(r'(\d+[\.,]?\d*)\s*(?:zł|złotych|pln)', caseSensitive: false).firstMatch(lowerText) ??
                      RegExp(r'(?:koszt|kwota|cena)\s*(\d+[\.,]?\d*)', caseSensitive: false).firstMatch(lowerText);
    if (costMatch != null) {
      detectedCost = double.tryParse(costMatch.group(1)!.replaceAll(',', '.'));
    }

    final litersMatch = RegExp(r'(\d+[\.,]?\d*)\s*(?:l|litr|litry|litrów)', caseSensitive: false).firstMatch(lowerText) ??
                        RegExp(r'(?:litry|litrów|zatankowane)\s*(\d+[\.,]?\d*)', caseSensitive: false).firstMatch(lowerText);
    if (litersMatch != null) {
      detectedLiters = double.tryParse(litersMatch.group(1)!.replaceAll(',', '.'));
    }

    final tripMatch = RegExp(r'(?:dystans|przejechane|odcinek)\s*(\d+[\.,]?\d*)', caseSensitive: false).firstMatch(lowerText) ??
                      RegExp(r'(\d+[\.,]?\d*)\s*km', caseSensitive: false).firstMatch(lowerText);
    if (tripMatch != null) {
      tripDistance = double.tryParse(tripMatch.group(1)!.replaceAll(',', '.'));
    }

    final odoMatch = RegExp(r'(?:licznik|stan licznika)\s*(\d+[\.,]?\d*)', caseSensitive: false).firstMatch(lowerText);
    if (odoMatch != null) {
      odometer = double.tryParse(odoMatch.group(1)!.replaceAll(',', '.'));
    }

    if (detectedCost == null || detectedLiters == null) {
      final matches = RegExp(r'\b\d+[\.,]?\d*\b')
          .allMatches(text)
          .map((m) => double.tryParse(m.group(0)!.replaceAll(',', '.')))
          .whereType<double>()
          .toList();

      if (matches.isNotEmpty && detectedCost == null) {
        detectedCost = matches[0];
      }
      if (matches.length > 1 && detectedLiters == null) {
        detectedLiters = matches[1];
      }
    }

    return {
      'cost': detectedCost,
      'liters': detectedLiters,
      'detectedType': detectedType,
      'tripDistance': tripDistance,
      'odometer': odometer,
    };
  }

  Future<void> _startVoiceInput({
    Function(Map<String, dynamic>)? onRecognized,
  }) async {
    StateSetter? dialogSetState;
    String recognizedText = '';

    bool available = await _speech.initialize(
      onStatus: (val) {
        debugPrint('onStatus: $val');
        if (val == 'done' || val == 'notListening') {
          if (dialogSetState != null) {
            dialogSetState!(() {
              _isListening = false;
            });
          } else {
            _isListening = false;
          }
        }
      },
      onError: (val) => debugPrint('onError: $val'),
    );

    if (!available) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rozpoznawanie mowy jest niedostępne lub brak uprawnień do mikrofonu.')),
      );
      return;
    }

    _isListening = true;

    _speech.listen(
      localeId: 'pl_PL',
      onResult: (val) {
        if (dialogSetState != null) {
          dialogSetState!(() {
            recognizedText = val.recognizedWords;
          });
        }
      },
    );

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          dialogSetState = setDialogState;

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.mic, color: _isListening ? Colors.red : Colors.grey),
                const SizedBox(width: 8),
                Text(_isListening ? 'Mów teraz...' : 'Zakończono'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Mów np.: "Koszt 150 złotych, 25 litrów, dystans 400 km, gaz"',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    recognizedText.isEmpty
                        ? (_isListening ? 'Słucham...' : 'Nie rozpoznano mowy.')
                        : recognizedText,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _speech.stop();
                  _isListening = false;
                  Navigator.pop(ctx);
                },
                child: const Text('Anuluj', style: TextStyle(color: Colors.red)),
              ),
              ElevatedButton(
                onPressed: () {
                  _speech.stop();
                  _isListening = false;
                  Navigator.pop(ctx);

                  final parsed = _extractFuelDataFromSpeech(recognizedText);
                  if (onRecognized != null) {
                    onRecognized(parsed);
                  } else {
                    _showEntryFormDialog(
                      initialCost: parsed['cost'],
                      initialLiters: parsed['liters'],
                      initialType: parsed['detectedType'],
                      initialTrip: parsed['tripDistance'],
                      initialOdometer: parsed['odometer'],
                    );
                  }
                },
                child: const Text('Zatwierdź'),
              ),
            ],
          );
        },
      ),
    );

    _speech.stop();
    _isListening = false;
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
    final newList = List<FuelEntry>.from(_entriesNotifier.value);
    final index = newList.indexWhere((e) => e.id == entry.id);
    if (index == -1) return;

    newList.removeAt(index);
    _entriesNotifier.value = newList;
    _saveEntriesToFile();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Usunięto wpis tankowania.'),
        action: SnackBarAction(
          label: 'COFNIJ',
          onPressed: () {
            final restoreList = List<FuelEntry>.from(_entriesNotifier.value);
            restoreList.insert(index, entry);
            _entriesNotifier.value = restoreList;
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
    final normalized = text
        .replaceAll('O', '0')
        .replaceAll('o', '0')
        .replaceAll('l.', '1.')
        .replaceAll('L.', '1.');
    double? detectedLiters;
    double? detectedCost;
    FuelType detectedType = FuelType.lpg;
    DateTime? detectedDate;

    // Typ paliwa: tylko LPG / PB (PB95, PB98, benzyna). Nieobsługiwany typ paliwa jest pomijany.
    if (RegExp(r'\bLPG\b|AUTOGAZ|GAZ', caseSensitive: false).hasMatch(normalized)) {
      detectedType = FuelType.lpg;
    } else if (RegExp(r'PB\s*9?5|PB\s*9?8|BENZYNA|BEZNYNA|95|98', caseSensitive: false)
        .hasMatch(normalized)) {
      detectedType = FuelType.pb;
    }

    double? parseNumber(String value) => double.tryParse(
          value.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.'),
        );

    // Ilość paliwa. Szukamy wartości występującej przy L / LITR / LTR.
    final litersPatterns = <RegExp>[
      RegExp(r'(\d{1,4}[\.,]\d{1,3})\s*(?:l|ltr|lit(?:r|ry|rów)?)\b', caseSensitive: false),
      RegExp(r'(?:ilo(?:ś|s)c|ilosc|zatankowano|tankowanie)\s*[:=]?\s*(\d{1,4}[\.,]\d{1,3})', caseSensitive: false),
    ];

    for (final regex in litersPatterns) {
      final match = regex.firstMatch(normalized);
      if (match != null) {
        final value = parseNumber(match.group(1)!);
        if (value != null && value > 0 && value <= 200) {
          detectedLiters = value;
          break;
        }
      }
    }

    // Kandydaci na kwotę całkowitą. Cena jednostkowa (np. 6,49 zł/l) jest odrzucana.
    final candidates = <Map<String, dynamic>>[];
    final amountRegex = RegExp(r'(\d{1,6}[\.,]\d{2})\s*(?:zł|zl|pln)?', caseSensitive: false);

    for (final match in amountRegex.allMatches(normalized)) {
      final value = parseNumber(match.group(1)!);
      if (value == null || value <= 0 || value > 100000) continue;

      final start = match.start;
      final end = match.end;
      final before = normalized.substring(start > 45 ? start - 45 : 0, start).toLowerCase();
      final after = normalized.substring(end, end + 35 > normalized.length ? normalized.length : end + 35).toLowerCase();
      final context = '$before $after';

      // Cena za litr / jednostkowa: nie jest kosztem tankowania.
      if (RegExp(r'/\s*l\b|\bza\s*litr|\bcena\s*(?:za)?\s*litr|\bpln\s*/\s*l|\bzł\s*/\s*l', caseSensitive: false)
          .hasMatch(context)) {
        continue;
      }

      double score = 0;
      if (RegExp(r'razem|suma|do\s*zapłaty|do\s*zaplacenia|zapłacono|zaplacono|należność|naleznosc|total|kwota\s*do\s*zapłaty|kwota\s*do\s*zaplacenia', caseSensitive: false)
          .hasMatch(context)) {
        score += 100;
      }
      if (RegExp(r'zł|zl|pln', caseSensitive: false).hasMatch(match.group(0)!)) {
        score += 35;
      }
      if (detectedLiters != null) {
        final impliedUnitPrice = value / detectedLiters;
        if (impliedUnitPrice >= 2.0 && impliedUnitPrice <= 15.0) {
          score += 25;
        }
        if ((impliedUnitPrice - 6.0).abs() < 0.5 ||
            (impliedUnitPrice - 7.0).abs() < 0.5 ||
            (impliedUnitPrice - 8.0).abs() < 0.5) {
          score += 10;
        }
      }
      // Małe wartości są częściej ceną jednostkową lub numerem pomocniczym.
      if (value >= 20) score += 10;
      if (value >= 50) score += 5;

      candidates.add({'value': value, 'score': score, 'position': start});
    }

    if (candidates.isNotEmpty) {
      candidates.sort((a, b) {
        final scoreCompare = (b['score'] as double).compareTo(a['score'] as double);
        if (scoreCompare != 0) return scoreCompare;
        return (b['position'] as int).compareTo(a['position'] as int);
      });
      detectedCost = candidates.first['value'] as double;
    }

    // Daty: YYYY-MM-DD / YYYY.MM.DD oraz DD-MM-YYYY / DD.MM.YYYY / DD/MM/YYYY.
    final ymd = RegExp(r'\b(20\d{2})[-./](0[1-9]|1[0-2])[-./](0[1-9]|[12]\d|3[01])\b');
    final dmy = RegExp(r'\b(0[1-9]|[12]\d|3[01])[-./](0[1-9]|1[0-2])[-./](20\d{2})\b');

    final matchYmd = ymd.firstMatch(normalized);
    if (matchYmd != null) {
      detectedDate = DateTime(
        int.parse(matchYmd.group(1)!),
        int.parse(matchYmd.group(2)!),
        int.parse(matchYmd.group(3)!),
      );
    } else {
      final matchDmy = dmy.firstMatch(normalized);
      if (matchDmy != null) {
        detectedDate = DateTime(
          int.parse(matchDmy.group(3)!),
          int.parse(matchDmy.group(2)!),
          int.parse(matchDmy.group(1)!),
        );
      }
    }

    debugPrint('OCR: typ=${detectedType.label}, litry=$detectedLiters, koszt=$detectedCost, data=$detectedDate');

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
      final candidates = _entriesNotifier.value
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
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(isEditing ? 'Edytuj wpis' : (initialCost != null ? 'Zweryfikuj dane' : 'Dodaj wpis')),
              IconButton(
                icon: const Icon(Icons.mic, color: Colors.teal),
                tooltip: 'Podyktuj dane głosowo',
                onPressed: () {
                  _startVoiceInput(onRecognized: (parsed) {
                    setDialogState(() {
                      if (parsed['cost'] != null) {
                        costController.text = (parsed['cost'] as double).toStringAsFixed(2);
                      }
                      if (parsed['liters'] != null) {
                        litersController.text = (parsed['liters'] as double).toStringAsFixed(2);
                      }
                      if (parsed['tripDistance'] != null) {
                        tripController.text = (parsed['tripDistance'] as double).toStringAsFixed(1);
                      }
                      if (parsed['odometer'] != null) {
                        odometerController.text = (parsed['odometer'] as double).toStringAsFixed(0);
                      }
                      if (parsed['detectedType'] != null) {
                        selectedType = parsed['detectedType'] as FuelType;
                      }
                    });
                  });
                },
              ),
            ],
          ),
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

                final newList = List<FuelEntry>.from(_entriesNotifier.value);
                if (isEditing) {
                  final index = newList.indexWhere((e) => e.id == entryToEdit.id);
                  if (index != -1) {
                    newList[index] = newEntry;
                  }
                } else {
                  newList.add(newEntry);
                }
                
                _entriesNotifier.value = newList;
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

  Future<void> _exportToExcel() async {
    if (_entriesNotifier.value.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brak danych do wyeksportowania.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generowanie pliku Excel...')),
    );

    try {
      var excel = Excel.createExcel();
      excel.rename('Sheet1', 'LPG');

      void createSheetForType(String sheetName, FuelType type) {
        Sheet sheetObject = excel[sheetName];
        final list = _entriesNotifier.value.where((e) => e.fuelType == type).toList()
          ..sort((a, b) => b.date.compareTo(a.date));

        sheetObject.appendRow([
          TextCellValue('Data'),
          TextCellValue('Dystans (km)'),
          TextCellValue('Stan licznika (km)'),
          TextCellValue('Koszt (PLN)'),
          TextCellValue('Paliwo (L)'),
          TextCellValue('Pełny bak?'),
          TextCellValue('Spalanie (L/100km)'),
        ]);

        for (var entry in list) {
          sheetObject.appendRow([
            TextCellValue('${entry.date.day.toString().padLeft(2, '0')}.${entry.date.month.toString().padLeft(2, '0')}.${entry.date.year}'),
            entry.tripDistance != null ? DoubleCellValue(entry.tripDistance!) : TextCellValue('-'),
            entry.odometer != null ? DoubleCellValue(entry.odometer!) : TextCellValue('-'),
            DoubleCellValue(entry.cost),
            DoubleCellValue(entry.liters),
            TextCellValue(entry.isFullTank ? 'Tak' : 'Nie'),
            entry.singleConsumption != null
                ? DoubleCellValue(double.parse(entry.singleConsumption!.toStringAsFixed(2)))
                : TextCellValue('-'),
          ]);
        }

        double totalCost = list.fold(0.0, (sum, e) => sum + e.cost);
        double totalLiters = list.fold(0.0, (sum, e) => sum + e.liters);
        double? avgCons = _calculateConsumptionForList(list);

        sheetObject.appendRow([]);
        sheetObject.appendRow([
          TextCellValue('PODSUMOWANIE'),
          TextCellValue('-'),
          TextCellValue('-'),
          DoubleCellValue(double.parse(totalCost.toStringAsFixed(2))),
          DoubleCellValue(double.parse(totalLiters.toStringAsFixed(2))),
          TextCellValue('-'),
          avgCons != null
              ? DoubleCellValue(double.parse(avgCons.toStringAsFixed(2)))
              : TextCellValue('-'),
        ]);
      }

      createSheetForType('LPG', FuelType.lpg);
      createSheetForType('PB', FuelType.pb);

      final directory = await getTemporaryDirectory();
      final dateStr = '${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}';
      final filePath = '${directory.path}/Raport_Paliwa_$dateStr.xlsx';
      final fileBytes = excel.save();

      if (fileBytes != null) {
        File(filePath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes);

        if (!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        await Share.shareXFiles(
          [XFile(filePath)],
          subject: 'Raport z aplikacji Fuel App',
          text: 'Rozdzielony raport zużycia paliwa LPG i PB z aplikacji.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Błąd podczas eksportu: $e')),
      );
    }
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
                leading: const Icon(Icons.mic, color: Colors.deepOrange),
                title: const Text('Głosowe wprowadzanie (Speech-to-Text)'),
                onTap: () {
                  Navigator.pop(context);
                  _startVoiceInput();
                },
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
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: const Text('Importuj z Excela (.xlsx)'),
                onTap: () {
                  Navigator.pop(context);
                  _importExcel();
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
            Tab(text: 'PB', icon: Icon(Icons.local_gas_station)),
            Tab(text: 'Wykresy', icon: Icon(Icons.bar_chart)),
            Tab(text: 'Stats', icon: Icon(Icons.analytics)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'export_excel') {
                _exportToExcel();
              } else if (value == 'export_json') {
                _exportJson();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'export_excel',
                child: Text('Eksportuj do Excela (.xlsx)'),
              ),
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
                    _buildStatsTab(),
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
    return ListenableBuilder(
      listenable: Listenable.merge([_entriesNotifier, _fuelFilterNotifier]),
      builder: (context, child) {
        final filterResult = type == FuelType.lpg ? _lpgFuelTabCache! : _pbFuelTabCache!;
        final entries = filterResult.filteredEntries;
        final avgConsumption = type == FuelType.lpg ? _lpgFuelTabAvg : _pbFuelTabAvg;

        return Column(
          children: [
            FuelFilterWidget(
              initialFilterState: _fuelFilterNotifier.value,
              onFilterChanged: (newState) => _fuelFilterNotifier.value = newState,
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
                          onDismissed: (direction) => _deleteEntry(entry),
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
      },
    );
  }

  Widget _buildChartsTab() {
    return ListenableBuilder(
      listenable: Listenable.merge([_entriesNotifier, _chartsFilterNotifier, _chartFuelTypeNotifier]),
      builder: (context, child) {
        final chartFilterResult = _chartFilterCache!;
        final monthlyAverages = _chartDataCache;
        final currentType = _chartFuelTypeNotifier.value;

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<FuelType>(
                      segments: const [
                        ButtonSegment(value: FuelType.lpg, label: Text('LPG'), icon: Icon(Icons.propane_tank)),
                        ButtonSegment(value: FuelType.pb, label: Text('PB'), icon: Icon(Icons.local_gas_station)),
                      ],
                      selected: {currentType},
                      onSelectionChanged: (Set<FuelType> newSelection) {
                        _chartFuelTypeNotifier.value = newSelection.first;
                      },
                    ),
                  ],
                ),
              ),
              FuelFilterWidget(
                initialFilterState: _chartsFilterNotifier.value,
                onFilterChanged: (newState) => _chartsFilterNotifier.value = newState,
              ),
              if (chartFilterResult.infoMessage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 2.0),
                  child: Row(
                    children: [
                      Icon(
                        chartFilterResult.isDataLimited ? Icons.info_outline : Icons.check_circle_outline,
                        size: 14,
                        color: chartFilterResult.isDataLimited ? Colors.orange : Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          chartFilterResult.infoMessage,
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: chartFilterResult.isDataLimited ? Colors.orange.shade800 : Colors.grey.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      'Średnie miesięczne spalanie (${currentType.label})',
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
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatsTab() {
    return ValueListenableBuilder<List<FuelEntry>>(
      valueListenable: _entriesNotifier,
      builder: (context, entries, child) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Podsumowanie ogólne statystyk',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text('Całkowite koszty paliwa', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 4),
                      Text(
                        '${_statsTotalCostAll.toStringAsFixed(2)} PLN',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal),
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('LPG Koszt', '${_statsTotalLpgCost.toStringAsFixed(2)} PLN'),
                          _buildStatItem('PB Koszt', '${_statsTotalPbCost.toStringAsFixed(2)} PLN'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text('Zużycie paliwa', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('LPG Litry', '${_statsTotalLpgLiters.toStringAsFixed(1)} L'),
                          _buildStatItem('PB Litry', '${_statsTotalPbLiters.toStringAsFixed(1)} L'),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('Śr. spalanie LPG', _statsAvgLpgCons != null ? '${_statsAvgLpgCons!.toStringAsFixed(2)} L/100' : 'Brak'),
                          _buildStatItem('Śr. spalanie PB', _statsAvgPbCons != null ? '${_statsAvgPbCons!.toStringAsFixed(2)} L/100' : 'Brak'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text('Liczba wpisów', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatItem('Tankowania LPG', '$_statsLpgCount'),
                          _buildStatItem('Tankowania PB', '$_statsPbCount'),
                          _buildStatItem('Razem', '${entries.length}'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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

      final textSpanVal = material.TextSpan(
        text: val.toStringAsFixed(1),
        style: const TextStyle(fontSize: 10, color: Colors.black87),
      );
      final tpVal = TextPainter(text: textSpanVal, textDirection: TextDirection.ltr);
      tpVal.layout();
      tpVal.paint(canvas, Offset(x + (barWidth - tpVal.width) / 2, y - 14));

      final parts = key.split('-');
      final label = '${parts[1]}.${parts[0].substring(2)}';
      final textSpanLabel = material.TextSpan(
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
