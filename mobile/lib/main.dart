import 'package:flutter/material.dart';

import 'app/controller.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await ScanController.load();
  runApp(FppFinderApp(controller: controller));
}

class FppFinderApp extends StatelessWidget {
  const FppFinderApp({super.key, required this.controller});
  final ScanController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FPP Finder',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: HomePage(controller: controller),
      );
}
