import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_app/parsers/voice_fuel_parser.dart';

void main() {
  test('rozpoznaje LPG, litry, koszt i licznik', () {
    final r = VoiceFuelParser.parse(
      'zatankowałem LPG 32,5 litra, zapłaciłem 210,50 zł, stan licznika 125430',
    );
    expect(r.fuelType, 'LPG');
    expect(r.liters, 32.5);
    expect(r.cost, 210.50);
    expect(r.odometer, 125430);
  });

  test('rozpoznaje benzynę PB95', () {
    final r = VoiceFuelParser.parse('PB95, 40 litrów, razem 260 zł');
    expect(r.fuelType, 'PB95');
    expect(r.liters, 40);
    expect(r.cost, 260);
  });

  test('nie zapisuje ani nie wymaga wszystkich pól', () {
    final r = VoiceFuelParser.parse('zatankowałem 25 litrów');
    expect(r.liters, 25);
    expect(r.cost, isNull);
  });
}
