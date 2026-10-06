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


## Historia zmian

### 05 — zakładka Stats
- Dodano czwartą zakładkę **Stats**.
- Zakładka jest obecnie celowo pusta.
- Nie dodano żadnych obliczeń ani statystyk.
- Pozostałe zakładki i ich działanie pozostają bez zmian.

### 06 — własne filtry zakładki Wykresy
- Zakładka **Wykresy** nie korzysta już z aktywnego filtra zakładek LPG/PB.
- Dodano osobne filtry zakresu danych dla **LPG** i **Benzyna (PB)**.
- Dostępne zakresy: **Wszystko** oraz **Ostatnie 12M**.
- **Wszystko** oznacza dane od początku gromadzenia danych.
- **Ostatnie 12M** oznacza ostatnie **365 dni** liczone wstecz od bieżącego dnia.
- Ustawienie zakresu dla LPG jest niezależne od ustawienia zakresu dla PB.
