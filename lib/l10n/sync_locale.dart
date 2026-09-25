import 'package:flutter/widgets.dart';

/// Presentation only: follows the effective locale supplied by the app.
/// Chinese remains the fallback for languages outside the supported pair.
String syncText(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'en' ? en : zh;
