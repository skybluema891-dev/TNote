import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/document.dart';
import '../services/document_controller.dart';

Future<({SearchHit hit, int length})?> showDocumentSearch(
  BuildContext context,
  NoteDocument doc,
) {
  var query = '';
  var allTabs = true;
  return showDialog<({SearchHit hit, int length})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final hits = context.read<DocumentController>().search(
          doc,
          query,
          allTabs: allTabs,
        );
        return AlertDialog(
          title: const Text('検索'),
          content: SizedBox(
            width: 620,
            height: 430,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: '日本語を含む検索語',
                  ),
                  onChanged: (value) => setDialogState(() => query = value),
                ),
                SwitchListTile(
                  title: const Text('すべてのタブを検索'),
                  value: allTabs,
                  onChanged: (value) => setDialogState(() => allTabs = value),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (context, index) {
                      final hit = hits[index];
                      return ListTile(
                        title: Text(hit.tab.name),
                        subtitle: Text(hit.excerpt),
                        trailing: Text('${hit.position + 1}文字目'),
                        onTap: () {
                          Navigator.pop(context, (
                            hit: hit,
                            length: query.length,
                          ));
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    ),
  );
}
