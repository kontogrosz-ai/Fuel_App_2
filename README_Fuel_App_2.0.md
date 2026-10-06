# Fuel App 2.0

Baza aplikacji Fuel App w Flutter/Dart rozszerzona o:

- wprowadzanie danych tankowania głosem po polsku,
- uzupełnianie istniejącego formularza głosem bez automatycznego zapisu,
- import i eksport XLSX,
- zachowany JSON jako kopia zapasowa/import/eksport,
- OCR paragonów.

## Głos

Rozpoznawanie korzysta z `speech_to_text`, z językiem `pl_PL`, wynikami częściowymi i ponawianiem nasłuchiwania po krótkiej pauzie. Rozpoznany tekst jest analizowany przez `VoiceFuelParser` i przekazywany do istniejącego formularza tankowania.

## XLSX

Eksport tworzy arkusze `LPG` i `Benzyna PB`. Import pozwala zastąpić bazę lub scalić dane.

## Budowanie

Projekt zawiera workflow GitHub Actions `.github/workflows/build_apk.yml`, który tworzy brakującą strukturę Androida, dodaje zgodę mikrofonu, uruchamia analyze/test i buduje APK release.
