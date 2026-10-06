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
### 07 — data początkowa kalendarza
- Zmieniono najwcześniejszą możliwą datę wyboru w kalendarzu z **01.01.2020** na **01.01.2026**.
- Zmiana dotyczy wyboru daty tankowania oraz własnego zakresu dat w filtrach.
- Data końcowa nadal jest ustawiana na bieżący dzień.
### 08 — priorytet „SUMA PLN” w OCR
- Dodano jawne rozpoznawanie etykiety **SUMA PLN** jako priorytetowej etykiety kwoty końcowej.
- OCR nadal pomija ceny jednostkowe, np. `6,49 zł/l`, przy ustalaniu kosztu całego tankowania.


### 08 — nagłówek aplikacji
- Zmieniono nagłówek górnego paska z **Fuel App - Zarządzanie paliwem** na **Fuel App**.
- Nagłówek jest wyśrodkowany.


### 09 — kolejność filtrów zakładki Wykresy
- W pod-zakładce **Wykresy** kolejność filtrów zmieniono z **Wszystko / Ostatnie 12M** na **Ostatnie 12M / Wszystko**.
- Działanie filtrów pozostaje bez zmian.
- Zaktualizowano nazwę artefaktu APK w workflow GitHub Actions zgodnie z nową numeracją: **09_Fuel_App_WYKRESY_FILTRY_apk.apk**.


## ETAP 09 – Wykresy: kolejność filtrów i nazewnictwo eksportu
- W zakładce Wykresy, dla LPG/Benzyna (PB), kolejność filtrów ustawiono: **Ostatnie 12M / Wszystko**.
- Paczka źródłowa do GitHub: `09_Fuel_App_WYKRESY_FILTRY.zip`.
- APK generowane przez GitHub Actions: `09_Fuel_App_WYKRESY_FILTRY.apk`.
- ZIP zawierający gotowy APK (poza paczką źródłową GitHub): `09_Fuel_App_WYKRESY_FILTRY_apk.zip`.

## ETAP 10 – poprawa wprowadzania głosowego
- Ulepszono parser polskiej mowy dla danych tankowania.
- **Dystans odcinka km**: obsługa liczb zapisanych cyframi, także z odstępami jako separatorami tysięcy, oraz liczb wypowiadanych słownie.
- **Stan licznika km**: obsługa większych wartości, np. „sto pięćdziesiąt tysięcy”, oraz wartości zapisanych cyframi.
- **Litry**: poprawiono rozpoznawanie liczb słownych i dziesiętnych, np. „czterdzieści dwa i pół litra” oraz „42,5 litra”.
- **Koszt całkowity**: poprawiono rozpoznawanie kwot wypowiadanych słownie, np. „sto dwadzieścia pięć złotych”. Nadal używany jest koszt całkowity, a nie cena jednostkowa.
- **Data**: oprócz dat liczbowych obsługiwane są daty z nazwą miesiąca, np. „5 października 2026” oraz typowe formy słowne, np. „piątego października dwa tysiące dwudziestego szóstego”.
- Po rozpoznaniu dane są nadal przekazywane do istniejącego formularza tankowania.
- **Brak automatycznego zapisu** — użytkownik zawsze może sprawdzić i poprawić dane przed ręcznym zatwierdzeniem.
- Pozostała funkcjonalność aplikacji pozostaje bez zmian.
- Paczka źródłowa do GitHub: `10_Fuel_App_GLOS_POPRAWA.zip`.
- APK generowane przez GitHub Actions: `10_Fuel_App_GLOS_POPRAWA.apk`.
- ZIP zawierający gotowy APK: `10_Fuel_App_GLOS_POPRAWA_apk.zip`.
