import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceInputService {
  final SpeechToText _speech = SpeechToText();
  bool _available = false;
  bool _shouldListen = false;
  String _text = '';
  String _finalText = '';

  bool get isListening => _speech.isListening;
  bool get isAvailable => _available;
  String get text => _text;

  Future<bool> initialize({required void Function(String) onStatus}) async {
    _available = await _speech.initialize(
      onStatus: onStatus,
      onError: (_) {},
      debugLogging: false,
    );
    return _available;
  }

  Future<void> start({required void Function(String) onText, required void Function(String) onStatus}) async {
    _shouldListen = true;
    _text = '';
    _finalText = '';
    if (!_available) {
      final ok = await initialize(onStatus: onStatus);
      if (!ok) return;
    }
    await _listen(onText: onText, onStatus: onStatus);
  }

  Future<void> _listen({required void Function(String) onText, required void Function(String) onStatus}) async {
    if (!_shouldListen) return;
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'pl_PL',
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (result) {
        final recognized = result.recognizedWords.trim();
        if (recognized.isNotEmpty) {
          if (result.finalResult) {
            if (_finalText.isEmpty) {
              _finalText = recognized;
            } else {
              _finalText = '$_finalText $recognized';
            }
            _text = _finalText;
          } else {
            _text = _finalText.isEmpty ? recognized : '$_finalText $recognized';
          }
          onText(_text);
        }
        if (result.finalResult && _shouldListen) {
          Future<void>.delayed(const Duration(milliseconds: 250), () async {
            if (_shouldListen && !_speech.isListening) {
              await _listen(onText: onText, onStatus: onStatus);
            }
          });
        }
      },
    );
  }

  Future<void> stop() async {
    _shouldListen = false;
    await _speech.stop();
  }

  Future<void> cancel() async {
    _shouldListen = false;
    await _speech.cancel();
  }

  void dispose() {
    _shouldListen = false;
    _speech.cancel();
  }
}
