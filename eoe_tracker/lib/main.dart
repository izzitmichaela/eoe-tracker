// EoE food & symptom tracker (Flutter)
//
// Setup:
//   flutter create eoe_tracker
//   cd eoe_tracker
//   flutter pub add path_provider share_plus
//   # replace lib/main.dart with this file, then:
//   flutter run
//
// All data lives in ONE file, eoe_log.json. Every save overwrites it with the
// full current state (written to a temp file first, then renamed into place).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const EoeApp());

// ---------------------------------------------------------------------------
// Ingredients, grouped. Edit freely. Whole ingredients only, no prepared meals.
// ---------------------------------------------------------------------------
const Map<String, List<String>> kFoodGroups = {
  'Grains': [
    'wheat',
    'oats',
    'rice',
    'corn',
    'barley',
    'rye',
    'quinoa',
    'buckwheat',
    'millet',
    'amaranth',
  ],
  'Dairy & eggs': ['milk', 'cheese', 'yogurt', 'butter', 'cream', 'eggs'],
  'Meat & poultry': [
    'beef',
    'pork',
    'chicken',
    'turkey',
    'lamb',
    'duck',
    'venison',
  ],
  'Fish & shellfish': [
    'salmon',
    'tuna',
    'cod',
    'tilapia',
    'sardines',
    'shrimp',
    'crab',
    'lobster',
    'clams',
    'mussels',
    'scallops',
  ],
  'Legumes': [
    'soy',
    'peanuts',
    'black beans',
    'kidney beans',
    'chickpeas',
    'lentils',
    'peas',
    'green beans',
  ],
  'Nuts & seeds': [
    'almonds',
    'walnuts',
    'cashews',
    'pecans',
    'pistachios',
    'hazelnuts',
    'sesame',
    'sunflower seeds',
    'pumpkin seeds',
    'flax',
    'chia',
  ],
  'Vegetables': [
    'potatoes',
    'sweet potatoes',
    'tomatoes',
    'carrots',
    'broccoli',
    'cauliflower',
    'spinach',
    'kale',
    'lettuce',
    'cabbage',
    'celery',
    'cucumber',
    'zucchini',
    'squash',
    'onions',
    'garlic',
    'bell peppers',
    'chili peppers',
    'mushrooms',
    'asparagus',
    'beets',
    'eggplant',
  ],
  'Fruits': [
    'apples',
    'bananas',
    'oranges',
    'lemons',
    'limes',
    'grapes',
    'strawberries',
    'blueberries',
    'raspberries',
    'peaches',
    'pears',
    'cherries',
    'mango',
    'pineapple',
    'melon',
    'kiwi',
    'avocado',
  ],
  'Oils & fats': [
    'olive oil',
    'coconut oil',
    'canola oil',
    'sunflower oil',
    'sesame oil',
    'lard',
  ],
  'Herbs & spices': [
    'salt',
    'black pepper',
    'basil',
    'oregano',
    'parsley',
    'cilantro',
    'cinnamon',
    'ginger',
    'cumin',
    'paprika',
    'turmeric',
  ],
  'Sweeteners & drinks': [
    'sugar',
    'honey',
    'maple syrup',
    'cocoa',
    'coffee',
    'tea',
  ],
};

// Foods in the six common EoE trigger groups (milk, wheat, egg, soy,
// peanut/tree nut, fish/shellfish). Shown with a small dot.
const Set<String> kTriggers = {
  'wheat',
  'milk',
  'cheese',
  'yogurt',
  'butter',
  'cream',
  'eggs',
  'soy',
  'peanuts',
  'almonds',
  'walnuts',
  'cashews',
  'pecans',
  'pistachios',
  'hazelnuts',
  'salmon',
  'tuna',
  'cod',
  'tilapia',
  'sardines',
  'shrimp',
  'crab',
  'lobster',
  'clams',
  'mussels',
  'scallops',
};

const List<Color> kScaleColors = [
  Color(0xFF4F9A78), // 0
  Color(0xFF8AA84A), // 1
  Color(0xFFC9A62F), // 2
  Color(0xFFDB8431), // 3
  Color(0xFFCF5A38), // 4
  Color(0xFFAD2F36), // 5
];
const Color kTriggerColor = Color(0xFFD08A14);

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------
String _two(int n) => n.toString().padLeft(2, '0');

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

String cleanName(String s) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  return t.length > 60 ? t.substring(0, 60) : t;
}

String isoNow() {
  final n = DateTime.now();
  final o = n.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final a = o.abs();
  return '${dateKey(n)}T${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}'
      '$sign${_two(a.inHours)}:${_two(a.inMinutes.remainder(60))}';
}

class DayEntry {
  DayEntry({this.score, List<String>? foods}) : foods = foods ?? <String>[];
  int? score;
  final List<String> foods;
  bool get isEmpty => score == null && foods.isEmpty;
}

class LogData {
  LogData({List<String>? customFoods, Map<String, DayEntry>? days})
    : customFoods = customFoods ?? <String>[],
      days = days ?? <String, DayEntry>{};

  final List<String> customFoods;
  final Map<String, DayEntry> days;

  factory LogData.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('Top level must be an object');

    final custom = <String>[];
    final c = raw['custom_foods'];
    if (c is List) {
      for (final v in c) {
        if (v is String) {
          final n = cleanName(v);
          if (n.isNotEmpty && !custom.contains(n)) custom.add(n);
        }
      }
    }

    final days = <String, DayEntry>{};
    final d = raw['days'];
    if (d is Map) {
      d.forEach((k, v) {
        if (k is! String || v is! Map) return;
        int? score;
        final s = v['symptom_score'];
        if (s is int && s >= 0 && s <= 5) score = s;
        final foods = <String>[];
        final f = v['foods'];
        if (f is List) {
          for (final item in f) {
            if (item is String) {
              final n = cleanName(item);
              if (n.isNotEmpty && !foods.contains(n)) foods.add(n);
            }
          }
        }
        days[k] = DayEntry(score: score, foods: foods);
      });
    }
    return LogData(customFoods: custom, days: days);
  }

  Map<String, dynamic> toJson() {
    final keys = days.keys.where((k) => !days[k]!.isEmpty).toList()..sort();
    return {
      'version': 1,
      'updated_at': isoNow(),
      'custom_foods': customFoods,
      'days': {
        for (final k in keys)
          k: {'symptom_score': days[k]!.score, 'foods': days[k]!.foods},
      },
    };
  }
}

// ---------------------------------------------------------------------------
// Storage: one JSON file in the app's folder on the phone
// ---------------------------------------------------------------------------
class LogStore {
  static const fileName = 'eoe_log.json';
  late File file;
  String? recoveredBackup;

  Future<void> init() async {
    Directory? dir;
    if (Platform.isAndroid) {
      // App-specific external storage: no permissions needed, and reachable
      // from a computer over USB at Android/data/<package>/files.
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
    }
    dir ??= await getApplicationDocumentsDirectory();
    await dir.create(recursive: true);
    file = File('${dir.path}/$fileName');
  }

  Future<LogData> load() async {
    if (!await file.exists()) return LogData();
    try {
      return LogData.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // Never let a bad file be silently overwritten by the next save.
      final now = DateTime.now();
      final stamp =
          '${dateKey(now)}-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final name = 'eoe_log.unreadable-$stamp.json';
      await file.rename('${file.parent.path}/$name');
      recoveredBackup = name;
      return LogData();
    }
  }

  Future<void> save(LogData data) async {
    final tmp = File('${file.path}.tmp');
    final text = const JsonEncoder.withIndent('  ').convert(data.toJson());
    await tmp.writeAsString('$text\n', flush: true);
    await tmp.rename(file.path); // replaces the old file in one step
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
class EoeApp extends StatelessWidget {
  const EoeApp({super.key});

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E5A5F),
      brightness: b,
    );
    return ThemeData(useMaterial3: true, colorScheme: scheme);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EoE log',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

enum StatusKind { info, dirty, error }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final LogStore store = LogStore();
  final TextEditingController _customCtrl = TextEditingController();

  LogData data = LogData();
  DateTime current = DateUtils.dateOnly(DateTime.now());
  bool loaded = false;
  bool saving = false;
  bool dirty = false;
  String? loadError;
  String status = '';
  StatusKind kind = StatusKind.info;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => loadError = null);
    try {
      await store.init();
      final d = await store.load();
      if (!mounted) return;
      setState(() {
        data = d;
        loaded = true;
        if (store.recoveredBackup != null) {
          status =
              'Saved file was unreadable; kept as ${store.recoveredBackup}';
          kind = StatusKind.error;
        } else {
          status = d.days.isEmpty ? 'No saved log yet' : 'Loaded saved log';
          kind = StatusKind.info;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loadError = '$e');
    }
  }

  String get _key => dateKey(current);
  DayEntry get _read => data.days[_key] ?? DayEntry();
  DayEntry get _write => data.days.putIfAbsent(_key, () => DayEntry());

  void _touch() {
    dirty = true;
    status = 'Unsaved changes';
    kind = StatusKind.dirty;
  }

  void _toggleFood(String name) {
    final e = _write;
    setState(() {
      if (!e.foods.remove(name)) e.foods.add(name);
      _touch();
    });
  }

  void _setScore(int n) {
    final e = _write;
    setState(() {
      e.score = e.score == n ? null : n; // tap again to clear
      _touch();
    });
  }

  void _addCustom() {
    final name = cleanName(_customCtrl.text);
    if (name.isEmpty) return;
    final builtIn = kFoodGroups.values.any((l) => l.contains(name));
    final e = _write;
    setState(() {
      if (!builtIn && !data.customFoods.contains(name)) {
        data.customFoods.add(name);
      }
      if (!e.foods.contains(name)) e.foods.add(name);
      _customCtrl.clear();
      _touch();
    });
  }

  Future<void> _save() async {
    if (!loaded) return;
    setState(() {
      saving = true;
      status = 'Saving...';
      kind = StatusKind.info;
    });
    try {
      await store.save(data);
      if (!mounted) return;
      data.days.removeWhere((_, e) => e.isEmpty);
      setState(() {
        dirty = false;
        status =
            'Saved ${TimeOfDay.fromDateTime(DateTime.now()).format(context)}';
        kind = StatusKind.info;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Not saved: $e';
        kind = StatusKind.error;
      });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _goTo(DateTime d) => setState(() => current = DateUtils.dateOnly(d));
  void _shift(int days) =>
      _goTo(DateTime(current.year, current.month, current.day + days));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) _goTo(picked);
  }

  Future<bool> _confirmLeave() async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('You have changes that are not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // Sends eoe_log.json through the system share sheet (Drive, email, Files...).
  // Unsaved changes are saved first so the shared file is never stale.
  Future<void> _share(BuildContext buttonContext) async {
    if (saving) return;
    // iPad needs an on-screen anchor for the share popover.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : null;

    if (dirty) {
      await _save();
      if (dirty) return; // save failed; the error is shown in the bar
    }
    try {
      if (!await store.file.exists()) {
        if (!mounted) return;
        setState(() {
          status = 'Nothing to share yet. Log something and save first.';
          kind = StatusKind.info;
        });
        return;
      }
      // Share a copy from the temp folder so any app can read it.
      final tmp = await getTemporaryDirectory();
      final copy = await store.file.copy('${tmp.path}/${LogStore.fileName}');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(copy.path, mimeType: 'application/json')],
          subject: 'EoE log',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Could not share: $e';
        kind = StatusKind.error;
      });
    }
  }

  void _showFileInfo() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Data file'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Every day is stored in this one file. Each save overwrites it.',
            ),
            const SizedBox(height: 12),
            SelectableText(store.file.path),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String get _dateLabel =>
      '${_weekdays[current.weekday - 1]}, ${_months[current.month - 1]} ${current.day}, ${current.year}';

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave()) SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('EoE log'),
          actions: [
            if (loaded)
              Builder(
                builder: (btnContext) => IconButton(
                  tooltip: 'Share log file',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => _share(btnContext),
                ),
              ),
            if (loaded)
              IconButton(
                tooltip: 'Data file',
                icon: const Icon(Icons.folder_outlined),
                onPressed: _showFileInfo,
              ),
          ],
        ),
        body: _body(scheme),
        bottomNavigationBar: _saveBar(scheme),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not open the data folder:\n$loadError',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _init, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (!loaded) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dateRow(),
          const SizedBox(height: 16),
          _symptomCard(scheme),
          const SizedBox(height: 16),
          _foodsCard(scheme),
        ],
      ),
    );
  }

  Widget _dateRow() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          onPressed: () => _shift(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: OutlinedButton(
            onPressed: _pickDate,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            child: Text(_dateLabel),
          ),
        ),
        IconButton(
          tooltip: 'Next day',
          onPressed: () => _shift(1),
          icon: const Icon(Icons.chevron_right),
        ),
        TextButton(
          onPressed: () => _goTo(DateTime.now()),
          child: const Text('Today'),
        ),
      ],
    );
  }

  Widget _card(ColorScheme scheme, Widget child) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  Widget _symptomCard(ColorScheme scheme) {
    final score = _read.score;
    final small = Theme.of(context).textTheme.bodySmall;
    return _card(
      scheme,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Symptoms today',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var n = 0; n <= 5; n++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _scoreButton(n, score == n),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text('0 = no symptoms', style: small)),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '5 = severe food impaction',
                  style: small,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreButton(int n, bool selected) {
    final c = kScaleColors[n];
    final radius = BorderRadius.circular(10);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Symptom score $n',
      child: Material(
        color: selected ? c : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: c, width: 2),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () => _setScore(n),
          child: SizedBox(
            height: 58,
            child: Center(
              child: Text(
                '$n',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : c,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _foodsCard(ColorScheme scheme) {
    final entry = _read;
    final theme = Theme.of(context);
    final groups = <MapEntry<String, List<String>>>[
      ...kFoodGroups.entries,
      if (data.customFoods.isNotEmpty) MapEntry('Custom', data.customFoods),
    ];

    return _card(
      scheme,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Foods eaten', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              if (entry.foods.isNotEmpty)
                Text(
                  '(${entry.foods.length} today)',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tap to add, tap again to remove.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: _Dot(color: kTriggerColor),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Common EoE trigger groups: milk, wheat, egg, soy, nuts, fish and shellfish',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final g in groups) _group(g.key, g.value, entry, scheme),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customCtrl,
                  maxLength: 60,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addCustom(),
                  decoration: const InputDecoration(
                    hintText: 'Add your own ingredient',
                    counterText: '',
                    border: OutlineInputBorder(),
                    isDense: false,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addCustom,
                style: FilledButton.styleFrom(minimumSize: const Size(64, 52)),
                child: const Text('Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _group(
    String name,
    List<String> items,
    DayEntry entry,
    ColorScheme scheme,
  ) {
    final n = items.where(entry.foods.contains).length;
    return ExpansionTile(
      key: ValueKey(name),
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      shape: const Border(),
      collapsedShape: const Border(),
      title: Row(
        children: [
          Text(name, style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          if (n > 0)
            Text('$n selected', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in items) _chip(f, entry.foods.contains(f), scheme),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(String name, bool selected, ColorScheme scheme) {
    return FilterChip(
      label: Text(name),
      selected: selected,
      showCheckmark: false,
      avatar: kTriggers.contains(name)
          ? _Dot(color: selected ? scheme.onPrimary : kTriggerColor)
          : null,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
      ),
      onSelected: (_) => _toggleFood(name),
    );
  }

  Widget _saveBar(ColorScheme scheme) {
    final color = switch (kind) {
      StatusKind.dirty => kTriggerColor,
      StatusKind.error => scheme.error,
      StatusKind.info => scheme.onSurfaceVariant,
    };
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontWeight: kind == StatusKind.info
                        ? FontWeight.w400
                        : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: (!loaded || saving) ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(110, 48),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
                child: Text(saving ? 'Saving...' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 8,
        height: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
