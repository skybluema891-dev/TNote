import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';

import '../screens/workspace_screen.dart';
import '../services/document_controller.dart';

class TNoteApp extends StatelessWidget {
  const TNoteApp({
    super.key,
    required this.controller,
    this.desktop = false,
    this.version = '1.3.4',
    this.buildNumber = '12',
  });
  final DocumentController controller;
  final bool desktop;
  final String version;
  final String buildNumber;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.settings]),
    builder: (context, _) => ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        title: 'TNote',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        themeMode: controller.settings.themeMode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff26645d)),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff72b9ab),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: WorkspaceScreen(
          desktop: desktop,
          version: version,
          buildNumber: buildNumber,
        ),
      ),
    ),
  );
}

