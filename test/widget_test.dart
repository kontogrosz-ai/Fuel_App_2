import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_app/main.dart';

void main() {
  testWidgets('Fuel App uruchamia główny interfejs', (tester) async {
    await tester.pumpWidget(const FuelApp());
    expect(find.text('Fuel App - Zarządzanie paliwem'), findsOneWidget);
  });
}
