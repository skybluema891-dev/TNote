import 'dart:convert';
import 'dart:typed_data';

import 'package:loro_crdt/loro_crdt.dart';

import '../models/document.dart';
import 'document_store.dart';

/// Each running editor uses Loro's fresh random peer ID, including after a
/// profile restore. Only note IDs and the immutable update history are shared.
class CollaborationReplica {
  CollaborationReplica() {
    document.configTextStyle({
      'link': ExpandType.none,
    }, defaultStyle: ExpandType.after);
  }
  final document = LoroDoc();
  LoroMovableList get titles => document.getMovableList('titles');
  String _key(String kind, String id) =>
      '${kind}_${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';
  LoroMovableList tabs(String title) =>
      document.getMovableList(_key('tabs', title));
  LoroMap meta(String id) => document.getMap(_key('meta', id));
  LoroText body(String tab) => document.getText(_key('body', tab));

  List<String> ids(LoroMovableList list, {bool deleted = false}) => list
      .toList()
      .cast<String>()
      .where((id) => (meta(id)['deleted'] == true) == deleted)
      .toList();

  void seed(StoredWorkspace workspace) {
    if (titles.isNotEmpty) throw StateError('この共同編集メモには既に内容があります。');
    // Validate the entire workspace before making any changes. Keep embeds
    // in the source and refuse conversion if this binding cannot encode them.
    for (final doc in workspace.documents) {
      for (final tab in doc.tabs) {
        if (tab.delta.any((op) => op['insert'] is! String)) {
          throw const FormatException(
            '埋め込みを含むため、このファイルを共同編集に取り込めません。元のファイルにはすべての内容が残っています。',
          );
        }
      }
    }
    for (final doc in workspace.documents) {
      add(titles, doc.id, doc.name);
      meta(doc.id)['active'] = doc.activeTabId;
      for (final tab in doc.tabs) {
        add(tabs(doc.id), tab.id, tab.name);
        meta(tab.id)['created'] = tab.createdAt;
        meta(tab.id)['modified'] = tab.updatedAt;
        applyText(tab.id, tab.delta);
      }
    }
    document.getMap('workspace')['active'] = workspace.activeDocumentId;
  }

  void add(LoroMovableList list, String id, String name) {
    list.push(id);
    meta(id)['name'] = name;
  }

  void move(LoroMovableList list, String id, String target) {
    final order = list.toList();
    list.move(order.indexOf(id), order.indexOf(target));
  }

  void applyText(String tab, List<dynamic> operations) {
    body(tab).applyDelta([
      for (final op in operations)
        TextDelta.fromJson(Map<String, Object?>.from(op as Map)),
    ]);
  }

  List<dynamic> content(String id) => [
    for (final op in body(id).toDelta()) op.toJson(),
  ];

  StoredWorkspace workspace() {
    final docs = <NoteDocument>[];
    for (final id in ids(titles)) {
      final items = <NoteTab>[];
      for (final tab in ids(tabs(id))) {
        final data = meta(tab);
        items.add(
          NoteTab(
            id: tab,
            name: data['name'] as String,
            delta: content(tab),
            text: body(tab).toString(),
            createdAt: data['created'] as String? ?? '',
            updatedAt: data['modified'] as String? ?? '',
          ),
        );
      }
      if (items.isEmpty) continue;
      final active = meta(id)['active'];
      docs.add(
        NoteDocument(
          id: id,
          temporaryName: meta(id)['name'] as String,
          tabs: items,
          activeTabId:
              items.where((t) => t.id == active).firstOrNull?.id ??
              items.first.id,
        ),
      );
    }
    if (docs.isEmpty) throw StateError('書き出せるタイトルとタブがありません。');
    final active = document.getMap('workspace')['active'];
    return StoredWorkspace(
      documents: docs,
      activeDocumentId:
          docs.where((d) => d.id == active).firstOrNull?.id ?? docs.first.id,
    );
  }

  Uint8List change(void Function() edit) {
    final from = document.oplogVersion;
    edit();
    document.commit();
    return document.exportUpdates(from: from);
  }

  void receive(Uint8List packet) => document.import(packet);
  void close() => document.dispose();
}
