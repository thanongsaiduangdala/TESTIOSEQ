import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'eq_script.dart';

void main() => runApp(const YtSoundApp());

const _safariUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

const _bands = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const _presets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Vocal': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  'Treble': [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
  'Rock': [4, 3, 2, -1, -2, -1, 2, 4, 5, 5],
  'Loudness': [5, 3, 0, -1, -1, 0, -1, 0, 3, 4],
};

class YtSoundApp extends StatelessWidget {
  const YtSoundApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'YT Sound',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.redAccent, brightness: Brightness.dark),
        ),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final WebViewController _web;
  Timer? _poll;
  int _tab = 0;
  bool _engineOn = true; // inject the audio engine at all
  bool _armed = false; // user has touched a control => engine may hook the player
  bool _fxOn = true; // effects bypass
  double _boost = 1.0;
  List<double> _gains = List.filled(10, 0.0);
  Map<String, dynamic> _diag = {'status': 'idle'};

  String get _status => (_diag['status'] ?? 'none').toString();

  @override
  void initState() {
    super.initState();
    PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        // Lets the Web Audio context start without a tap inside the page.
        mediaTypesRequiringUserAction: const {},
      );
    }
    _web = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_safariUa) // Google sign-in rejects the default WKWebView UA
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => _inject()))
      ..loadRequest(Uri.parse('https://music.youtube.com'));
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _inject() async {
    if (!_engineOn) return;
    await _web.runJavaScript(eqScript);
    await _push();
  }

  Future<void> _push() => _web.runJavaScript(
      'window.__ytEQ&&window.__ytEQ.set(${jsonEncode({'gains': _gains, 'boost': _boost, 'on': _fxOn, 'arm': _armed})})');

  /// Every user-driven change goes through here: update UI, arm the engine, push.
  void _change(VoidCallback fn) {
    setState(() {
      fn();
      _armed = true;
    });
    _push();
  }

  Future<void> _refreshStatus() async {
    if (_tab != 1 || !_engineOn) return;
    try {
      final r = await _web.runJavaScriptReturningResult(
          "window.__ytEQ ? window.__ytEQ.diag() : '{\"status\":\"none\"}'");
      dynamic j = jsonDecode(r.toString());
      if (j is String) j = jsonDecode(j);
      if (mounted && j is Map) setState(() => _diag = Map<String, dynamic>.from(j));
    } catch (_) {}
  }

  void _setEngine(bool on) {
    setState(() {
      _engineOn = on;
      _diag = {'status': on ? 'idle' : 'off'};
    });
    _web.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The WebView stays in the tree and on screen at all times (the sound page
      // is drawn on top of it), so iOS never treats the player as hidden/paused.
      body: Stack(children: [
        SafeArea(bottom: false, child: WebViewWidget(controller: _web)),
        if (_tab == 1)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _soundPage(context),
            ),
          ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _refreshStatus();
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'YT Music'),
          NavigationDestination(
              icon: Icon(Icons.equalizer), label: 'Personalize Sound'),
        ],
      ),
    );
  }

  Widget _soundPage(BuildContext context) {
    final t = Theme.of(context);
    final small = t.textTheme.labelSmall;
    final (icon, color, text) = switch (_status) {
      'active' => (Icons.check_circle, Colors.greenAccent, 'Connected to the player'),
      'idle' => (Icons.touch_app, Colors.lightBlueAccent, 'Ready. Move a slider or pick a preset'),
      'waiting' => (Icons.hourglass_empty, Colors.amber, 'Play a song in YT Music'),
      'blocked' => (Icons.lock_outline, Colors.amber, 'Audio engine waiting. Tap play in YT Music'),
      'silent' => (Icons.volume_off, Colors.redAccent, 'No signal. This stream can\'t be processed on this iPhone'),
      'off' => (Icons.power_settings_new, Colors.grey, 'Audio engine is off'),
      'none' => (Icons.hourglass_empty, Colors.amber, 'Loading…'),
      final s => (Icons.error_outline, Colors.redAccent, 'Error: $s'),
    };
    final d = _diag;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Personalize Sound', style: t.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(leading: Icon(icon, color: color), title: Text(text)),
            if (_status == 'silent')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FilledButton(
                  onPressed: () => _setEngine(false),
                  child: const Text('Restore audio (reloads YT Music)'),
                ),
              ),
            if (_engineOn && d.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SelectableText(
                  'ctx ${d['ctx']} · hooked ${d['hooked']} · media ${d['media']} · '
                  'paused ${d['paused']} · src ${d['src']}'
                  '${(d['err'] ?? '').toString().isEmpty ? '' : ' · err ${d['err']}'}',
                  style: small?.copyWith(color: Colors.grey),
                ),
              ),
          ]),
        ),
        SwitchListTile(
          title: const Text('Sound effects'),
          subtitle: const Text('Turn off to hear the original sound'),
          value: _fxOn,
          onChanged: (v) => _change(() => _fxOn = v),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Volume boost: ${(_boost * 100).round()}%',
                  style: t.textTheme.titleMedium),
              Slider(
                min: 1,
                max: 3,
                divisions: 20,
                value: _boost,
                label: '${(_boost * 100).round()}%',
                onChanged: (v) => _change(() => _boost = v),
              ),
              Text('Above ~200% can sound harsh. A limiter is applied to reduce clipping.',
                  style: small),
            ]),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < _bands.length; i++)
                  Expanded(
                    child: Column(children: [
                      Text('${_gains[i].round()}', style: small),
                      SizedBox(
                        height: 170,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            min: -12,
                            max: 12,
                            value: _gains[i],
                            onChanged: (v) => _change(() => _gains[i] = v),
                          ),
                        ),
                      ),
                      Text(_bands[i] >= 1000 ? '${_bands[i] ~/ 1000}k' : '${_bands[i]}',
                          style: small),
                    ]),
                  ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final e in _presets.entries)
                  ActionChip(
                    label: Text(e.key),
                    onPressed: () => _change(() => _gains = List.of(e.value)),
                  ),
              ]),
            ]),
          ),
        ),
        SwitchListTile(
          title: const Text('Audio engine'),
          subtitle: const Text('Turning this off reloads YT Music and restores untouched audio'),
          value: _engineOn,
          onChanged: _setEngine,
        ),
      ]),
    );
  }
}
