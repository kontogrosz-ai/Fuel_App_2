# Fuel App — Etap A: głos

Ta wersja bazuje na działającym repozytorium Fuel App 1:1.

Dodana została wyłącznie funkcja wprowadzania danych głosowo po polsku:
- przycisk „Wprowadź głosowo” w menu dodawania tankowania,
- rozpoznawanie mowy `pl_PL`,
- rozpoznawanie typu paliwa LPG/PB,
- rozpoznawanie litrów,
- rozpoznawanie kosztu,
- rozpoznawanie przebiegu,
- rozpoznawanie dystansu,
- opcjonalne rozpoznawanie daty,
- przekazanie danych do istniejącego formularza tankowania,
- brak automatycznego zapisu — użytkownik zawsze zatwierdza formularz ręcznie.

Pozostała funkcjonalność aplikacji nie została celowo zmieniona.

Zmienione pliki względem wersji bazowej:
- `lib/main.dart`
- `pubspec.yaml`
- `.github/workflows/build_apk.yml`

Dodano zależność:
- `speech_to_text: ^7.0.0`


# Etap B — OCR paragonu

W tej wersji ulepszono wyłącznie odczyt danych z paragonu. OCR uzupełnia istniejący formularz i nie zapisuje tankowania automatycznie.

Obsługiwane priorytety kwoty końcowej: RAZEM, SUMA, SUMA PLN, DO ZAPŁATY, ZAPŁACONO, NALEŻNOŚĆ. Cena jednostkowa nie jest używana jako koszt całkowity. Cena jednostkowa, np. 6,49 zł/l, jest pomijana jako koszt całego tankowania. Obsługiwany jest polski przecinek dziesiętny.
