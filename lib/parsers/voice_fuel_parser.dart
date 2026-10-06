class VoiceFuelResult {
  final String? fuelType;
  final double? liters;
  final double? cost;
  final double? odometer;
  final double? tripDistance;

  const VoiceFuelResult({
    this.fuelType,
    this.liters,
    this.cost,
    this.odometer,
    this.tripDistance,
  });

  bool get hasAnyData =>
      fuelType != null || liters != null || cost != null || odometer != null || tripDistance != null;
}

/// Parser wypowiedzi głosowej dla formularza Fuel App.
/// Nie zapisuje danych i nie wykonuje żadnych operacji na bazie.
class VoiceFuelParser {
  static VoiceFuelResult parse(String input) {
    final text = _normalize(input);
    return VoiceFuelResult(
      fuelType: _fuelType(text),
      liters: _findByUnit(text, _literUnits),
      cost: _findLabeledAmount(text, _costLabels) ?? _findAmountBeforeUnit(text, _moneyUnits),
      odometer: _findLabeledNumber(text, _odometerLabels),
      tripDistance: _findLabeledNumber(text, _tripLabels),
    );
  }

  static const _literUnits = ['LITRÓW', 'LITRY', 'LITRA', 'LITR', 'L'];
  static const _moneyUnits = ['ZŁ', 'ZL', 'PLN', 'ZŁOTYCH', 'ZŁOTE'];
  static const _costLabels = [
    'ZAPŁACIŁEM', 'ZAPLACILEM', 'ZAPŁACIŁAM', 'ZAPLACILAM',
    'KOSZT', 'KWOTA', 'SUMA', 'RAZEM', 'DO ZAPŁATY', 'DO ZAPLATY',
  ];
  static const _odometerLabels = ['LICZNIK', 'STAN LICZNIKA', 'PRZEBIEG'];
  static const _tripLabels = ['DYSTANS', 'ODCINEK', 'PRZEJECHAŁEM', 'PRZEJECHALEM'];

  static String _normalize(String input) => input
      .toUpperCase()
      .replaceAll('Ł', 'L')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String? _fuelType(String text) {
    if (RegExp(r'\bLPG\b|AUTO ?GAZ|AUTOGAZ|GAZ').hasMatch(text)) return 'LPG';
    if (RegExp(r'\bPB ?98\b|BENZYNA 98').hasMatch(text)) return 'PB98';
    if (RegExp(r'\bPB ?95\b|BENZYNA 95').hasMatch(text)) return 'PB95';
    if (RegExp(r'\bPB\b|BENZYNA').hasMatch(text)) return 'PB';
    return null;
  }

  static double? _findByUnit(String text, List<String> units) {
    final unitPattern = units.map(RegExp.escape).join('|');
    final patterns = [
      RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:' + unitPattern + r')\b'),
      RegExp(r'(?:' + unitPattern + r')\s*(\d+(?:[.,]\d+)?)\b'),
    ];
    for (final pattern in patterns) {
      final m = pattern.firstMatch(text);
      final value = m == null ? null : _number(m.group(1));
      if (value != null && value > 0 && value < 200) return value;
    }
    return null;
  }

  static double? _findAmountBeforeUnit(String text, List<String> units) {
    final pattern = RegExp(r'(\d{1,6}(?:[.,]\d{1,2})?)\s*(?:' + units.map(RegExp.escape).join('|') + r')\b');
    for (final m in pattern.allMatches(text)) {
      final value = _number(m.group(1));
      if (value != null && value > 0) return value;
    }
    return null;
  }

  static double? _findLabeledAmount(String text, List<String> labels) {
    for (final label in labels) {
      final p = RegExp(RegExp.escape(label) + r'[^0-9]{0,30}(\d{1,6}(?:[.,]\d{1,2})?)');
      final m = p.firstMatch(text);
      if (m != null) {
        final value = _number(m.group(1));
        if (value != null && value > 0) return value;
      }
    }
    return null;
  }

  static double? _findLabeledNumber(String text, List<String> labels) {
    for (final label in labels) {
      final p = RegExp(RegExp.escape(label) + r'[^0-9]{0,30}(\d{2,7}(?:[.,]\d+)?)');
      final m = p.firstMatch(text);
      if (m != null) {
        final value = _number(m.group(1));
        if (value != null && value >= 0) return value;
      }
    }
    return null;
  }

  static double? _number(String? raw) {
    if (raw == null) return null;
    return double.tryParse(raw.replaceAll(',', '.').replaceAll(' ', ''));
  }
}
