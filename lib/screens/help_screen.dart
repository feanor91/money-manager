import 'package:flutter/material.dart';

import '../data/user_guide_content.dart';

/// The embedded user guide (Paramètres > Guide d'utilisation) - every
/// section collapsed by default so the whole guide fits on screen at a
/// glance, expand the ones that matter right now. Content lives in
/// user_guide_content.dart, plain Dart so it ships with every build with no
/// separate asset/download step.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Guide d'utilisation")),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: userGuideSections.length,
        itemBuilder: (context, index) {
          final section = userGuideSections[index];
          return ExpansionTile(
            leading: Icon(section.icon),
            title: Text(section.title),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section.body, style: Theme.of(context).textTheme.bodyMedium),
            ],
          );
        },
      ),
    );
  }
}
