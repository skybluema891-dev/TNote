import 'dart:math';

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';

class NoteTab {
  NoteTab({
    required this.id,
    required this.name,
    this.text = '',
    List<dynamic>? delta,
    required this.createdAt,
    required this.updatedAt,
  }) : delta = _systemFontDelta(delta ?? _plainDelta(text));
  factory NoteTab.create(String name) {
    final now = DateTime.now().toUtc().toIso8601String();
    return NoteTab(id: newId(), name: name, createdAt: now, updatedAt: now);
  }
  final String id;
  String name;
  String text;
  List<dynamic> delta;
  final String createdAt;
  String updatedAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'text': text,
    'delta': delta,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };
  factory NoteTab.fromJson(Map<String, dynamic> json) => NoteTab(
    id: json['id'] as String,
    name: json['name'] as String,
    text: json['text'] as String? ?? '',
    delta: (json['delta'] as List?)?.cast<dynamic>(),
    createdAt: json['createdAt'] as String,
    updatedAt: json['updatedAt'] as String,
  );
}

List<dynamic> _plainDelta(String text) => [
  {'insert': text.endsWith('\n') ? text : '$text\n'},
];

List<dynamic> _systemFontDelta(List<dynamic> delta) => delta.map((item) {
  final operation = Map<String, dynamic>.from(item as Map);
  final rawAttributes = operation['attributes'];
  if (rawAttributes is Map) {
    final attributes = Map<String, dynamic>.from(rawAttributes)..remove('font');
    if (attributes.isEmpty) {
      operation.remove('attributes');
    } else {
      operation['attributes'] = attributes;
    }
  }
  return operation;
}).toList();

class NoteDocument {
  NoteDocument({
    required this.id,
    required this.temporaryName,
    required this.tabs,
    required this.activeTabId,
    this.path,
    this.customName,
    this.fingerprint,
    this.revision = 0,
    this.savedRevision = -1,
    this.readOnly = false,
  });
  factory NoteDocument.create(int number) {
    final tab = NoteTab.create('メモ');
    return NoteDocument(
      id: newId(),
      temporaryName: '無題$number',
      tabs: [tab],
      activeTabId: tab.id,
    );
  }
  final String id;
  final String temporaryName;
  final List<NoteTab> tabs;
  String activeTabId;
  String? path;
  String? customName;
  String? fingerprint;
  int revision;
  int savedRevision;
  bool readOnly;
  String? error;
  bool saving = false;
  bool externallyModified = false;
  bool get dirty => revision != savedRevision;
  bool get requiresSaveConfirmation => path == null || dirty || error != null;
  String get name => customName ?? temporaryName;
  NoteTab get activeTab => tabs.firstWhere((tab) => tab.id == activeTabId);
  void changed() {
    revision++;
    error = null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'temporaryName': temporaryName,
    'tabs': tabs.map((tab) => tab.toJson()).toList(),
    'activeTabId': activeTabId,
    'path': path,
    'customName': customName,
    'fingerprint': fingerprint,
    'revision': revision,
    'savedRevision': savedRevision,
  };
  factory NoteDocument.fromJson(Map<String, dynamic> json) => NoteDocument(
    id: json['id'] as String,
    temporaryName: json['temporaryName'] as String,
    tabs: (json['tabs'] as List)
        .map((e) => NoteTab.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    activeTabId: json['activeTabId'] as String,
    path: json['path'] as String?,
    customName: json['customName'] as String?,
    fingerprint: json['fingerprint'] as String?,
    revision: json['revision'] as int,
    savedRevision: json['savedRevision'] as int,
  );
}
